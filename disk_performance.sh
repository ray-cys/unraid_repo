#!/usr/bin/env bash
# Improved disk_performance.sh for unRAID
# Goals: earlier, less-noisy alerts for IO degradation and SMART anomalies
# - dependency checks
# - persistent baseline under /boot/config by default
# - dry-run and test-notify flags
# - notification rate limiting
# - small log rotation

set -euo pipefail

# Config (tune these as needed)
SCRIPT_NAME="disk_performance.sh"
LOG="/var/log/disk_perf_watch.log"
# Persist baseline across reboots by default
BASE="/boot/config/disk_perf_baseline.json"
NOTIFY="/usr/local/emhttp/webGui/scripts/notify"
SAMPLE_COUNT=3          # iostat samples averaged
IOSTAT_INTERVAL=1       # seconds between iostat samples

# Thresholds
ABS_LATENCY_MS_HDD=40       # HDD absolute latency (ms)
ABS_LATENCY_MS_NVME=5       # NVMe absolute latency (ms)
RELATIVE_INCREASE_FACTOR=2  # trigger when > baseline * factor
TEMP_THRESHOLD=55           # C
SATA_CRC_DELTA=5

# Action toggles (safe defaults)
AUTO_STOP_MOVER=false
SMART_EXTEND_ON_CRITICAL=false

ALERT_LEVEL_CRITICAL="critical"
ALERT_LEVEL_WARN="normal"

# Notification rate limit: minimum seconds between notifies per device
NOTIFY_RATE_LIMIT=3600  # 1 hour

# Rotation: max log size before rotate (bytes)
LOG_MAX_BYTES=$((5 * 1024 * 1024))

dry_run=false
test_notify=false

timestamp(){ date '+%F %T'; }
log(){ echo "$(timestamp) $*" >> "$LOG"; }

rotate_log_if_needed(){
  if [ -f "$LOG" ] && [ $(stat -f%z "$LOG") -ge $LOG_MAX_BYTES ]; then
    mv "$LOG" "$LOG.$(date +%s)" || true
    gzip -f "$LOG."* 2>/dev/null || true
    touch "$LOG"
  fi
}

send_notify(){
  local title="$1"; local message="$2"; local level="${3:-normal}"; local device="${4:-}";
  # Rate limit per device by storing a timestamp file
  if [ -n "$device" ]; then
    local tsfile="/var/local/disk_perf_notify_${device}.ts"
    if [ -f "$tsfile" ]; then
      last=$(cat "$tsfile" 2>/dev/null || echo 0)
    else
      last=0
    fi
    now=$(date +%s)
    if [ $((now - last)) -lt $NOTIFY_RATE_LIMIT ]; then
      log "Skipping notify for $device due to rate limit ($((now-last))s since last)"
      return 0
    fi
    echo "$now" > "$tsfile" || true
  fi

  if [ "$dry_run" = true ]; then
    log "DRY-RUN NOTIFY: $title - $message"
    return 0
  fi

  if [ "$test_notify" = true ]; then
    # only send a simple test notification and stop
    if [ -x "$NOTIFY" ]; then
      "$NOTIFY" -e "Disk Watch (test)" -s "$title" -d "$message" -i "$level"
    else
      log "NOTIFY MISSING (test): $title - $message"
    fi
    return 0
  fi

  if [ -x "$NOTIFY" ]; then
    "$NOTIFY" -e "Disk Watch" -s "$title" -d "$message" -i "$level"
  else
    log "NOTIFY MISSING: $title - $message"
  fi
}

usage(){
  cat <<EOF
$SCRIPT_NAME [--dry-run] [--test-notify] [--help]
  --dry-run       : don't send notifications or perform actions; logs only
  --test-notify   : send a single test notification and exit (requires notify helper)
  --help          : show this help
EOF
}

check_deps(){
  local miss=()
  for cmd in iostat jq smartctl lsblk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      miss+=("$cmd")
    fi
  done
  if [ ${#miss[@]} -gt 0 ]; then
    echo "Missing required commands: ${miss[*]}. Install via Nerd Tools/Community Apps or package manager." >&2
    return 1
  fi
  return 0
}

get_disks(){
  # prefer by-id (stable), fall back to lsblk
  if [ -d /dev/disk/by-id ]; then
    (cd /dev/disk/by-id && for f in *; do [ -L "$f" ] || continue; readlink -f "$f"; done) | xargs -n1 basename | sort -u
  else
    lsblk -nd -o NAME
  fi
}

get_iostat_for_device(){
  local dev="$1"
  # iostat -x -p ALL interval count -> parse device lines
  out=$(iostat -x -p ALL $IOSTAT_INTERVAL $SAMPLE_COUNT 2>/dev/null || true)
  if [ -z "$out" ]; then
    echo "NA NA"
    return 0
  fi
  # extract lines that start with device name
  # fields vary; attempt to find avg r_await and w_await by column position
  echo "$out" | awk -v dev="$dev" 'BEGIN{collect=0} /Device:/ {collect=1; next} collect && NF && $1==dev {print $0}' \
    | awk '{r+=$10; w+=$11; c++} END{if(c>0) printf("%.3f %.3f\n", r/c, w/c); else print "NA NA"}'
}

get_smart_temp_crc(){
  local dev="$1"
  # Improve parsing robustness across devices
  smartctl -A "/dev/$dev" 2>/dev/null | awk '
    /Temperature_Celsius/ {t=$10}
    /Temperature/ && !t && $NF ~ /C/ {t=$(NF-1)}
    /UDMA_CRC_Error_Count/ {crc=$10}
    /SATA_Error_Counter|CRC error/ {crc=$NF}
    END{ if(t=="") t=0; if(crc=="") crc=0; print t,crc }' || echo "0 0"
}

main(){
  rotate_log_if_needed

  if ! check_deps; then
    log "Dependency check failed"
    exit 2
  fi

  # ensure baseline exists
  if [ ! -f "$BASE" ]; then
    echo "{}" > "$BASE"
    log "Created baseline file skeleton at $BASE"
  fi

  for dev in $(get_disks); do
    [[ "$dev" =~ loop ]] && continue

    io=$(get_iostat_for_device "$dev")
    if [[ "$io" == "NA NA" ]]; then
      log "No iostat data for $dev; skipping"
      continue
    fi
    read -r rlat wlat <<< "$io"
    # choose the larger of read/write await
    maxlat=$(awk -v r="$rlat" -v w="$wlat" 'BEGIN{print (r>w? r:w)}')

    read tmp crc <<< $(get_smart_temp_crc "$dev")
    tmp=${tmp:-0}; crc=${crc:-0}

    bl_lat=$(jq -r --arg d "$dev" '.[$d].latency // "null"' "$BASE")
    bl_temp=$(jq -r --arg d "$dev" '.[$d].temp // "null"' "$BASE")
    bl_crc=$(jq -r --arg d "$dev" '.[$d].crc // "null"' "$BASE")

    if [ "$bl_lat" == "null" ]; then
      # initialize baseline with measured values
      jq --arg d "$dev" --argjson lat "$maxlat" --argjson tmp "$tmp" --argjson crc "$crc" '.[$d] = {latency:$lat, temp:$tmp, crc:$crc, first_seen:now}' "$BASE" > "$BASE.tmp" && mv "$BASE.tmp" "$BASE"
      log "Baseline created for $dev latency=${maxlat} temp=${tmp} crc=${crc}"
      continue
    fi

    # choose absolute threshold by transport
    if lsblk -dn -o TRAN "/dev/$dev" 2>/dev/null | grep -qi nvme; then
      abs_thr=$ABS_LATENCY_MS_NVME
    else
      abs_thr=$ABS_LATENCY_MS_HDD
    fi

    warn_msgs=""
    # absolute latency
    if (( $(awk -v a="$maxlat" -v t="$abs_thr" 'BEGIN{print (a>t)}') )); then
      warn_msgs+="Absolute latency high: ${maxlat}ms (> ${abs_thr}ms). "
    fi
    # relative increase
    if (( $(awk -v a="$maxlat" -v b="$bl_lat" -v f="$RELATIVE_INCREASE_FACTOR" 'BEGIN{print (a>(b*f))}')) ); then
      warn_msgs+="Latency > ${RELATIVE_INCREASE_FACTOR}x baseline (${bl_lat}ms -> ${maxlat}ms). "
    fi
    # temp
    if (( $(awk -v t="$tmp" -v thr="$TEMP_THRESHOLD" 'BEGIN{print (t>thr)}') )); then
      warn_msgs+="Temp high: ${tmp}C. "
    fi
    # CRC delta
    if [ "$bl_crc" != "null" ] && [ "$crc" != "" ]; then
      delta_crc=$((crc - bl_crc))
      if [ "$delta_crc" -gt "$SATA_CRC_DELTA" ]; then
        warn_msgs+="SATA CRC errors increased by ${delta_crc}. "
      fi
    fi

    if [ -n "$warn_msgs" ]; then
      title="Disk performance warning: $dev"
      body="Device: $dev\nLatency (ms): ${maxlat}\nBaseline latency: ${bl_lat}\nTemp: ${tmp}C\nCRC: ${crc} (baseline ${bl_crc})\nNotes: $warn_msgs\nSee $LOG"
      log "$title - $warn_msgs"
      send_notify "$title" "$body" "$ALERT_LEVEL_WARN" "$dev"

      # determine critical
      is_critical=0
      if (( $(awk -v a="$maxlat" -v t="$((abs_thr*2))" 'BEGIN{print (a>t)}') )); then is_critical=1; fi
      if (( $(awk -v a="$maxlat" -v b="$bl_lat" -v f="4.0" 'BEGIN{print (a>b*f)}') )); then is_critical=1; fi

      if [ "$is_critical" -eq 1 ]; then
        log "CRITICAL condition for $dev"
        send_notify "Disk critical: $dev" "Disk $dev hit critical thresholds. Recommend: STOP mover, run extended SMART long test, inspect cabling/HBA." "$ALERT_LEVEL_CRITICAL" "$dev"

        if [ "$AUTO_STOP_MOVER" = true ]; then
          if [ "$dry_run" = false ]; then
            if [ -x /usr/local/sbin/mover ]; then
              log "Stopping mover as AUTO_STOP_MOVER=true"
              /usr/local/sbin/mover stop 2>/dev/null || true
              send_notify "Mover stopped (auto)" "Mover was stopped automatically due to critical disk alert for $dev" "$ALERT_LEVEL_CRITICAL" "$dev"
            fi
          else
            log "DRY-RUN: would stop mover for $dev"
          fi
        fi

        if [ "$SMART_EXTEND_ON_CRITICAL" = true ]; then
          if [ "$dry_run" = false ]; then
            smartctl -t long "/dev/$dev" >/dev/null 2>&1 || log "Failed to start SMART long test on $dev"
            send_notify "SMART long test triggered" "Started SMART long test on $dev (best-effort)." "$ALERT_LEVEL_CRITICAL" "$dev"
          else
            log "DRY-RUN: would start SMART long test on $dev"
          fi
        fi
      fi
    fi

    # slow baseline update (exponential smoothing)
    alpha=0.02
    new_lat=$(awk -v b="$bl_lat" -v m="$maxlat" -v a="$alpha" 'BEGIN{print (b*(1-a)+m*a)}')
    new_temp=$(awk -v b="$bl_temp" -v t="$tmp" -v a="$alpha" 'BEGIN{print (b*(1-a)+t*a)}')
    jq --arg d "$dev" --argjson lat "$new_lat" --argjson tmp "$new_temp" --argjson crc "$crc" '.[$d].latency=$lat | .[$d].temp=$tmp | .[$d].crc=$crc' "$BASE" > "$BASE.tmp" && mv "$BASE.tmp" "$BASE"
  done

  log "Disk perf check complete."
}

# argument parsing
while [ ${#-} -ge 0 ] 2>/dev/null; do
  case "${1:-}" in
    --dry-run) dry_run=true; shift;;
    --test-notify) test_notify=true; shift;;
    --help|-h) usage; exit 0;;
    "") break;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

if [ "$test_notify" = true ]; then
  send_notify "Disk watch test" "This is a test notification from $SCRIPT_NAME" "$ALERT_LEVEL_WARN"
  exit 0
fi

main

exit 0