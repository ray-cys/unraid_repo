#!/usr/bin/env bash
# disk_health_enterprise.sh
# Unraid Enterprise Disk Health & Parity Degradation Monitor (Bash)
# - Full SMART, NVMe wear/TBW, UDMA CRC, POH, SATA link speed checks
# - btrfs device stats & scrub checks
# - xfs dmesg/XFS repair dry-run checks
# - Parity detection (disks.cfg / disks.ini), mdState, parity-valid flag
# - Logging, JSON state, diffs, severity aggregation (INFO/WARN/CRITICAL)
#
# Usage:
#   ./disk_health_enterprise.sh            # normal run
#   ./disk_health_enterprise.sh --test     # test alert
#   ./disk_health_enterprise.sh --debug    # verbose debug output
#
# Author: generated for Ray (customized)
set -euo pipefail
IFS=$'\n\t'

# ---------------------------
# CONFIGURE: thresholds, paths
# ---------------------------
LOGDIR="/var/log"
LOGFILE="${LOGDIR}/disk-health-enterprise.log"
STATEFILE="${LOGDIR}/disk-health-enterprise-last.json"
TMPSTATE="${LOGDIR}/disk-health-enterprise-current.json"
ROTATE_LINES=10000       # rotate log if larger than this (lines)
RETENTION=7              # keep N rotated logs

# Commands (auto-detect)
NOTIFY_CLI="/usr/local/emhttp/webGui/scripts/notify"
SMARTCTL="$(command -v smartctl || true)"
LSBLK="$(command -v lsblk || true)"
BTRFS="$(command -v btrfs || true)"
XFS_REPAIR="$(command -v xfs_repair || true)"
XFS_INFO="$(command -v xfs_info || true)"
MDCMD="$(command -v mdcmd || true)"       # optional Unraid helper
JQ="$(command -v jq || true)"

# Email fallback
FALLBACK_EMAIL="your.email@example.com"   # change if you want mail fallback

# Thresholds (tweak as needed)
HDD_PENDING_WARN=1
HDD_PENDING_CRIT=3
HDD_REALLOC_WARN=1
HDD_REALLOC_CRIT=10
UDMA_CRC_WARN_INCREASE=1    # any increase is suspicious; use delta over last run
POH_WARN_HOURS= (  # specify per-drive policy via age in hours (optional)
)
SSD_PERCENT_USED_WARN=60
SSD_PERCENT_USED_CRIT=85
NVME_PERCENT_USED_WARN=50
NVME_PERCENT_USED_CRIT=80
TEMP_WARN=50
TEMP_CRIT=60
TBW_WARN_PERCENT=80         # if we can estimate percent TBW used (best-effort)
SATA_SPEED_DOWN_SHIFT_WARN=1  # detect change from expected speed (6.0Gb -> lower)
# end config

# ---------------------------
# Utility: simple logger & rotation
# ---------------------------
log() {
  local lvl="$1"; shift
  local payload="$*"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "${ts} [${lvl}] ${payload}" | tee -a "$LOGFILE"
}
rotate_logs() {
  if [[ -f "$LOGFILE" ]]; then
    local lines
    lines=$(wc -l < "$LOGFILE" || echo 0)
    if (( lines > ROTATE_LINES )); then
      for i in $(seq $RETENTION -1 1); do
        [[ -f "${LOGFILE}.${i}" ]] && mv "${LOGFILE}.${i}" "${LOGFILE}.$((i+1))"
      done
      mv "$LOGFILE" "${LOGFILE}.1"
      touch "$LOGFILE"
    fi
  fi
}
rotate_logs

# ---------------------------
# Notification wrapper
# ---------------------------
send_unraid_notify() {
  # usage: send_unraid_notify <severity> <subject> <body>
  local sev="$1"; shift
  local subj="$1"; shift
  local body="$*"

  # Map severity to notify icon types (if notify script supports -i)
  if [[ -x "$NOTIFY_CLI" ]]; then
    # many Unraid notify wrappers accept: notify "<subj>" "<message>" or -s, -d flags
    # We'll attempt several invocation forms.
    if "$NOTIFY_CLI" -h >/dev/null 2>&1; then
      # try known form (some Unraid scripts use -s subject -d body -i icon)
      "$NOTIFY_CLI" -s "$subj" -d "$body" -i "$sev" || \
      "$NOTIFY_CLI" "$subj" "$body" || \
      logger -t disk-health-enterprise "$subj: $body"
    else
      # fallback simple
      "$NOTIFY_CLI" "$subj" "$body" || logger -t disk-health-enterprise "$subj: $body"
    fi
    return $?
  fi

  # fallback to mail if installed
  if command -v mail >/dev/null 2>&1; then
    echo -e "$body" | mail -s "$subj" "$FALLBACK_EMAIL"
    return $?
  fi

  # last resort: syslog
  logger -t disk-health-enterprise "$subj: $body"
  return 1
}

# ---------------------------
# Device discovery
# ---------------------------
discover_devices() {
  # prefer Unraid mapping file if exists
  local ini="/var/local/emhttp/disks.ini"
  declare -A device_role
  if [[ -f "$ini" ]]; then
    # parse lines like: device="/dev/sdf" type="parity" status="VALID"
    # We'll read any 'device="..."' entries together with type=
    while read -r line; do
      if [[ "$line" =~ device=\"(/dev/[a-z0-9]+)\" ]]; then
        local dev="${BASH_REMATCH[1]}"
        if [[ "$line" =~ type=\"([^\"]+)\" ]]; then
          device_role["$dev"]="${BASH_REMATCH[1]}"
        fi
      fi
    done < <(grep -E 'device=|type=' "$ini" || true)
  fi

  # fallback: enumerate block devices
  local devs=()
  if [[ -n "$LSBLK" ]]; then
    while read -r l; do
      devs+=("/dev/$l")
    done < <(lsblk -nd -o NAME | tr -d ' ')
  else
    # naive: include /dev/sd* and /dev/nvme*n1
    devs=(/dev/sd? /dev/nvme?n1 2>/dev/null || true)
  fi

  # Print results as: device|role
  for d in "${devs[@]}"; do
    [[ -b "$d" ]] || continue
    local role="${device_role[$d]:-unknown}"
    echo "${d}|${role}"
  done
}

# ---------------------------
# Read previous numeric attributes (for deltas)
# ---------------------------
read_prev_attr() {
  # $1 = device, $2 = attribute_name (e.g., udma_crc)
  if [[ -f "$STATEFILE" && -n "$JQ" ]]; then
    jq -r --arg dev "$1" --arg key "$2" '.[] | select(.device==$dev) | .[$key] // empty' "$STATEFILE" || echo ""
  else
    echo ""
  fi
}

# ---------------------------
# Collect SMART & device-level metrics
# ---------------------------
collect_smart_metrics() {
  local devnode="$1"  # /dev/sdX or /dev/nvme0n1
  local devname
  devname="$(basename "$devnode")"

  # Identify if NVMe
  local is_nvme=0
  if [[ "$devnode" =~ nvme ]]; then is_nvme=1; fi

  # call smartctl appropriately
  local smart_out
  if (( is_nvme )); then
    smart_out="$($SMARTCTL -a -d nvme "$devnode" 2>/dev/null || $SMARTCTL -a "$devnode" 2>/dev/null || true)"
  else
    smart_out="$($SMARTCTL -a "$devnode" 2>/dev/null || true)"
  fi

  # If smartctl missing or no output
  if [[ -z "$smart_out" ]]; then
    log "WARN" "SMART data not available for $devnode"
  fi

  # parse common fields (best-effort)
  local overall="UNKNOWN"
  if echo "$smart_out" | grep -qi "SMART overall-health self-assessment test result: PASSED"; then overall="PASSED"; fi
  if echo "$smart_out" | grep -qi "SMART overall-health self-assessment test result: FAILED"; then overall="FAILED"; fi
  if echo "$smart_out" | grep -qi "SMART Health Status: OK"; then overall="PASSED"; fi

  # parse attributes robustly
  local reallocated pending offline_unc udma_crc temp pow_on_hours percent_used avail_spare tbw_lbas_written nvme_data_units_written
  reallocated="$(echo "$smart_out" | awk '/Reallocated_Sector_Ct|Reallocated_Event_Count/ {print $10; exit}')"
  pending="$(echo "$smart_out" | awk '/Current_Pending_Sector/ {print $10; exit}')"
  offline_unc="$(echo "$smart_out" | awk '/Offline_Uncorrectable/ {print $10; exit}')"
  udma_crc="$(echo "$smart_out" | awk '/UDMA_CRC_Error_Count/ {print $10; exit}')"
  temp="$(echo "$smart_out" | awk '/Temperature_Celsius/ {print $10; exit}')"
  pow_on_hours="$(echo "$smart_out" | awk '/Power_On_Hours/ {print $10; exit}')"
  percent_used="$(echo "$smart_out" | awk '/Percent_Used|Percentage Used/ {print $10; exit}')"
  avail_spare="$(echo "$smart_out" | awk '/Available Spare:/ {print $3; exit}')"
  tbw_lbas_written="$(echo "$smart_out" | awk '/Total_LBAs_Written|Total_LBAs_Written:/ {print $NF; exit}')"
  nvme_data_units_written="$(echo "$smart_out" | awk '/Data Units Written/ {print $NF; exit}')"

  # sanitize numeric defaults
  reallocated=${reallocated:-0}
  pending=${pending:-0}
  offline_unc=${offline_unc:-0}
  udma_crc=${udma_crc:-0}
  temp=${temp:-0}
  pow_on_hours=${pow_on_hours:-0}
  percent_used=${percent_used:-0}
  avail_spare=${avail_spare:-0}

  # Calculate TBW percent if possible (very best-effort):
  # Many SMART outputs don't expose nominal TBW. We attempt to estimate using vendor fields if present.
  tbw_percent=""  # optional string
  if [[ -n "$tbw_lbas_written" ]]; then
    # Convert LBAs to GiB: LBAs * 512 / (1024^3)
    # This is rough and not all SSDs report nominal TBW.
    local written_gib
    written_gib=$(awk -v l="$tbw_lbas_written" 'BEGIN{printf "%.0f", (l * 512) / (1024^3)}' 2>/dev/null || echo "")
    if [[ -n "$written_gib" && "$written_gib" -gt 0 ]]; then
      tbw_percent="${written_gib}GiB_written"
    fi
  fi

  # Compose JSON object per device (simple)
  cat <<EOF
{
  "device":"$devnode",
  "devname":"$devname",
  "is_nvme":${is_nvme},
  "overall":"$overall",
  "reallocated":$reallocated,
  "pending":$pending,
  "offline_unc":$offline_unc,
  "udma_crc":$udma_crc,
  "temp":$temp,
  "power_on_hours":$pow_on_hours,
  "percent_used":$percent_used,
  "avail_spare":$avail_spare,
  "tbw_info":"$tbw_percent",
  "raw_smart": $(jq -Rs '.' <<< "$smart_out" 2>/dev/null || echo "\"(smart output omitted)\"")
}
EOF
}

# ---------------------------
# btrfs checks
# ---------------------------
check_btrfs() {
  local mp="$1"
  # device stats
  if [[ -n "$BTRFS" && -x "$BTRFS" ]]; then
    local stats
    stats="$($BTRFS device stats "$mp" 2>/dev/null || true)"
    # simple test: any non-zero lines
    if echo "$stats" | grep -q -v ": 0"; then
      log "WARN" "BTRFS device stats show non-zero errors on $mp: $(echo "$stats" | tr '\n' ' | ')"
      ALERTS+=("CRITICAL|BTRFS device stats non-zero on $mp: $(echo "$stats" | tr '\n' ' | ')")
    fi
    # scrub status
    local scrub
    scrub="$($BTRFS scrub status "$mp" 2>/dev/null || true)"
    if echo "$scrub" | grep -qi "error"; then
      log "WARN" "BTRFS scrub shows errors on $mp: $(echo "$scrub" | tr '\n' ' | ')"
      ALERTS+=("WARN|BTRFS scrub issues on $mp: $(echo "$scrub" | head -n4 | tr '\n' ' | ')")
    fi
  fi
}

# ---------------------------
# xfs checks
# ---------------------------
check_xfs() {
  local dev="$1"
  local mp="$2"

  # Inspect dmesg for XFS errors related to the device or mountpoint
  if dmesg | egrep -i "(XFS|xfs)" | egrep -i "error|corrupt|I/O|ioctl" >/tmp/xfs-dmesg.log 2>/dev/null; then
    if [[ -s /tmp/xfs-dmesg.log ]]; then
      log "WARN" "XFS kernel messages present for $mp: $(head -n3 /tmp/xfs-dmesg.log | tr '\n' ' | ')"
      ALERTS+=("WARN|XFS kernel messages on $mp: $(head -n3 /tmp/xfs-dmesg.log | tr '\n' ' | ')")
    fi
  fi
  rm -f /tmp/xfs-dmesg.log || true

  # Non-destructive xfs_repair check (dry-run)
  if [[ -x "$XFS_REPAIR" ]]; then
    $XFS_REPAIR -n "$dev" >/tmp/xfs-check.log 2>&1 || true
    if grep -qi "would be modified" /tmp/xfs-check.log || grep -qi "metadata" /tmp/xfs-check.log ; then
      log "WARN" "xfs_repair (dry-run) indicates issues on $dev ($mp)"
      ALERTS+=("CRITICAL|XFS metadata issues on $mp ($dev): $(grep -i 'would be modified' /tmp/xfs-check.log | head -n1 || true)")
    fi
    rm -f /tmp/xfs-check.log
  fi
}

# ---------------------------
# parity & md checks
# ---------------------------
check_parity() {
  # parity detection: disks.cfg or disks.ini
  local cfg="/boot/config/disks.cfg"
  local ini="/var/local/emhttp/disks.ini"
  local parity_devs=()
  # disks.cfg older style parity="sdf"
  if [[ -f "$cfg" ]]; then
    local p1 p2
    p1=$(grep -Po '^parity="[^"]+"' "$cfg" 2>/dev/null | cut -d'"' -f2 || true)
    p2=$(grep -Po '^parity2="[^"]+"' "$cfg" 2>/dev/null | cut -d'"' -f2 || true)
    [[ -n "$p1" && "$p1" != "disabled" ]] && parity_devs+=("/dev/$p1")
    [[ -n "$p2" && "$p2" != "disabled" ]] && parity_devs+=("/dev/$p2")
  fi
  # disks.ini style
  if [[ -f "$ini" ]]; then
    # look for type="parity" entries
    while read -r line; do
      if [[ "$line" =~ device=\"(/dev/[a-z0-9]+)\" && "$line" =~ type=\"parity\" ]]; then
        parity_devs+=("${BASH_REMATCH[1]}")
      fi
    done < <(grep -E 'device=|type=' "$ini" || true)
  fi

  # uniq
  parity_devs=($(printf "%s\n" "${parity_devs[@]}" | sort -u))

  # Check mdstat for sync/rebuild/progress and speed
  if [[ -f /proc/mdstat ]]; then
    local mdtext
    mdtext=$(cat /proc/mdstat)
    if echo "$mdtext" | grep -qiE "(resync|recovery|recover)"; then
      local pct
      pct=$(echo "$mdtext" | grep -oP '\d+(\.\d+)?(?=%)' | head -n1 || true)
      local speed
      speed=$(echo "$mdtext" | grep -oP 'speed=\K[0-9A-Za-z/]+|finish=\K[^ ]+' | head -n1 || true)
      for pd in "${parity_devs[@]}"; do
        ALERTS+=("WARN|Parity sync in progress ($pct% done, speed=$speed) on $pd")
      done
    fi
  fi

  # parity valid flag via mdcmd (if available) or disks.ini
  local parity_valid="UNKNOWN"
  if [[ -n "$MDCMD" ]]; then
    # mdcmd get parityValid (best-effort)
    if "$MDCMD" status >/dev/null 2>&1; then
      parity_valid=$("$MDCMD" status | grep -Po 'parityValid="\K[^"]+' || true)
    fi
  fi
  if [[ "$parity_valid" == "UNKNOWN" && -f "$ini" ]]; then
    parity_valid=$(grep -Po 'parityStatus=\K[^ ]+' "$ini" 2>/dev/null || true)
  fi

  # attach results to ALERTS if invalid
  if [[ -n "$parity_valid" ]]; then
    if echo "$parity_valid" | grep -qiE 'invalid|false|no'; then
      ALERTS+=("CRITICAL|Parity INVALID or not valid: [$parity_valid]")
    else
      log "INFO" "Parity valid flag: $parity_valid"
    fi
  fi

  # parity sync errors via mdcmd or disks.ini
  if [[ -n "$MDCMD" && "$MDCMD" status >/dev/null 2>&1 ]]; then
    local sync_errs
    sync_errs=$("$MDCMD" status | grep -Po 'sync_errs="\K[0-9]+' || echo 0)
    if [[ -n "$sync_errs" && "$sync_errs" -gt 0 ]]; then
      ALERTS+=("CRITICAL|Parity sync errors: $sync_errs")
    fi
  else
    # try disks.ini parsing for errors
    if [[ -f "$ini" ]]; then
      local perr
      perr=$(grep -Po 'parityErrors=\K[0-9]+' "$ini" 2>/dev/null || true)
      if [[ -n "$perr" && "$perr" -gt 0 ]]; then
        ALERTS+=("CRITICAL|Parity errors reported in disks.ini: $perr")
      fi
    fi
  fi

  # For parity devices, collect SMART and check for high temps / reallocated
  for pdev in "${parity_devs[@]}"; do
    if [[ -b "$pdev" ]]; then
      # reuse smart collector
      collect_smart_metrics "$pdev" | tee -a /tmp/parity_smart.json >/dev/null
      # quick parse to add alerts: check reallocated > threshold, temp > threshold
      # (we can parse via jq if present)
      if [[ -n "$JQ" ]]; then
        local r p t
        r=$(jq -r '.[0].reallocated' /tmp/parity_smart.json 2>/dev/null || echo "")
        p=$(jq -r '.[0].pending' /tmp/parity_smart.json 2>/dev/null || echo "")
        t=$(jq -r '.[0].temp' /tmp/parity_smart.json 2>/dev/null || echo "")
        [[ -n "$r" && "$r" -gt 0 ]] && ALERTS+=("WARN|Parity device $pdev has reallocated sectors=$r")
        [[ -n "$p" && "$p" -gt 0 ]] && ALERTS+=("WARN|Parity device $pdev has pending sectors=$p")
        [[ -n "$t" && "$t" -gt $TEMP_WARN ]] && ALERTS+=("WARN|Parity device $pdev temp=${t}C")
      fi
      rm -f /tmp/parity_smart.json || true
    fi
  done
}

# ---------------------------
# SATA link speed and UDMA CRC checks
# ---------------------------
check_link_and_crc() {
  local dev="$1"  # e.g., /dev/sda
  # Search dmesg for link speed or sata link messages for that device (best-effort)
  # Examples: "sda: SATA link up 6.0 Gbps (SStatus 133 SControl 300)" or "link is up at 6.0 Gbps"
  local devbase
  devbase=$(basename "$dev")
  local dlines
  dlines=$(dmesg | grep -i "$devbase" | tail -n 200 || true)
  if echo "$dlines" | grep -qiE 'link up|SATA link up|speed='; then
    # parse numeric speed token (6.0,3.0,1.5)
    local speed
    speed=$(echo "$dlines" | grep -oE '[0-9]\.[0-9] Gbps|[0-9]\.[0-9]Gbps|[0-9]\.[0-9] Gbit' | head -n1 || true)
    if [[ -n "$speed" ]]; then
      # normalize to numeric
      local spn
      spn=$(echo "$speed" | grep -oE '[0-9]\.[0-9]' || echo "")
      if [[ -n "$spn" && "$(echo "$spn < 6.0" | bc -l 2>/dev/null || echo 0)" -eq 1 ]]; then
        ALERTS+=("WARN|SATA link speed downshift detected for $dev ($speed)")
      fi
    fi
  fi

  # UDMA CRC via SMART attribute
  if [[ -n "$SMARTCTL" ]]; then
    local udma
    udma=$($SMARTCTL -a "$dev" 2>/dev/null | awk '/UDMA_CRC_Error_Count/ {print $10; exit}')
    udma=${udma:-0}
    # Read previous udma count
    prev_udma=$(read_prev_attr "$dev" "udma_crc" || echo "")
    if [[ -n "$prev_udma" ]]; then
      # if increase, alert
      if [[ "$udma" -gt "$prev_udma" ]]; then
        ALERTS+=("WARN|UDMA CRC error count increased on $dev: was $prev_udma now $udma (check cable/SATA port)")
      fi
    fi
  fi
}

# ---------------------------
# SMART self-test history check
# ---------------------------
check_smart_selftest() {
  local dev="$1"
  if [[ -n "$SMARTCTL" ]]; then
    local st
    st=$($SMARTCTL -l selftest "$dev" 2>/dev/null || true)
    if echo "$st" | grep -qi "Completed: read failure"; then
      ALERTS+=("CRITICAL|SMART self-test read failure on $dev: $(echo "$st" | head -n4 | tr '\n' ' | ')")
    fi
    if echo "$st" | grep -qi "Self-test routine in progress"; then
      ALERTS+=("INFO|SMART self-test in progress on $dev")
    fi
  fi
}

# ---------------------------
# Persist and diff state
# ---------------------------
write_state_and_diff() {
  # $1 contains the generated JSON array already written to $TMPSTATE
  # This function will compare with $STATEFILE and add an ALERT if changed (non-trivial)
  if [[ -f "$STATEFILE" && -f "$TMPSTATE" && -n "$JQ" ]]; then
    # compare device statuses (reallocated,pending,udma_crc,percent_used,temp)
    local diffs
    diffs=$($JQ -n --argfile a "$STATEFILE" --argfile b "$TMPSTATE" '
      ($a | fromjson) as $prev |
      ($b | fromjson) as $cur |
      [ $cur[] as $c | $prev[]? | select(.device==$c.device) as $p |
        {device:$c.device,
         prev:{reallocated:$p.reallocated, pending:$p.pending, udma_crc:$p.udma_crc, percent_used:$p.percent_used, temp:$p.temp},
         curr:{reallocated:$c.reallocated, pending:$c.pending, udma_crc:$c.udma_crc, percent_used:$c.percent_used, temp:$c.temp}
        } ] | map(select(.prev != .curr))' 2>/dev/null || true)
    if [[ -n "$diffs" && "$diffs" != "null" && "$diffs" != "[]" ]]; then
      ALERTS+=("WARN|State changes detected: $diffs")
    fi
  else
    # no previous state or jq not present; treat as informational run
    log "INFO" "No previous state or jq unavailable; create baseline at $STATEFILE"
  fi

  # rotate state: we keep only the latest copy
  mv -f "$TMPSTATE" "$STATEFILE" || cp -f "$TMPSTATE" "$STATEFILE"
}

# ---------------------------
# Main control flow
# ---------------------------
ALERTS=()
DEBUG=0
TESTMODE=0
if [[ "${1:-}" == "--debug" ]]; then DEBUG=1; fi
if [[ "${1:-}" == "--test" ]]; then TESTMODE=1; fi

if (( TESTMODE )); then
  send_unraid_notify "normal" "Disk monitor test" "This is a test alert from disk_health_enterprise on $(hostname -s) at $(date)"
  log "INFO" "Test alert sent"
  exit 0
fi

log "INFO" "Starting enterprise disk health run on $(hostname -s)"

# Build current state JSON
echo "[" > "$TMPSTATE"
first=1
while IFS="|" read -r dev role; do
  [[ -b "$dev" ]] || continue
  if [[ $first -eq 0 ]]; then echo "," >> "$TMPSTATE"; fi
  first=0
  # gather smart metrics
  collect_smart_metrics "$dev" >> "$TMPSTATE"
done < <(discover_devices)
echo "]" >> "$TMPSTATE"

# loop through mountpoints for fs checks
while read -r _mp; do
  # mount returns lines like: /dev/sda1 on /mnt/disk1 type xfs (rw,relatime,...)
  # Use mount output to find fstype/mountpoint and underlying device
  while read -r line; do
    # Extract device, mountpoint, fstype
    dev=$(echo "$line" | awk '{print $1}')
    mp=$(echo "$line" | awk '{print $3}')
    fstype=$(echo "$line" | awk '{print $5}')
    # Only check xfs or btrfs (skip rootfs/system)
    if [[ "$fstype" == "xfs" ]]; then
      check_xfs "$dev" "$mp"
    elif [[ "$fstype" == "btrfs" ]]; then
      check_btrfs "$mp"
    fi
  done < <(mount | grep -E ' type (xfs|btrfs) ' || true)
done < <(echo)

# parity checks
check_parity

# extra per-device checks for link speed / udma / smart self-test
while IFS="|" read -r dev role; do
  [[ -b "$dev" ]] || continue
  check_link_and_crc "$dev"
  check_smart_selftest "$dev"
done < <(discover_devices)

# write state and detect diffs
write_state_and_diff

# Aggregate ALERTS and send single composed notification (group severities)
if (( ${#ALERTS[@]} > 0 )); then
  # Compose summary and classify worst severity
  worst="INFO"
  body="Disk Health Enterprise report for $(hostname -s)\n\n"
  for a in "${ALERTS[@]}"; do
    # format: SEV|message
    sev="${a%%|*}"
    msg="${a#*|}"
    body+="${sev}: ${msg}\n"
    # escalate worst
    if [[ "$sev" == "CRITICAL" ]]; then worst="CRITICAL"; fi
    if [[ "$sev" == "WARN" && "$worst" != "CRITICAL" ]]; then worst="WARN"; fi
  done
  body+="\nFull state: $(cat "$STATEFILE" | head -c 10000)\n"
  # send via notify
  if [[ "$worst" == "CRITICAL" ]]; then
    log "CRITICAL" "Alerting: critical issues found"
    send_unraid_notify "error" "[CRITICAL] Unraid Disk Health" "$body"
  elif [[ "$worst" == "WARN" ]]; then
    log "WARN" "Alerting: warnings found"
    send_unraid_notify "warning" "[WARN] Unraid Disk Health" "$body"
  else
    log "INFO" "Alerting: informational items"
    send_unraid_notify "normal" "[INFO] Unraid Disk Health" "$body"
  fi
else
  log "INFO" "No alerts generated. Normal state."
  # Optionally send unobtrusive info once per day — commented out by default
  # send_unraid_notify "normal" "Daily disk health OK" "No issues found."
fi

# done
log "INFO" "Run completed"
exit 0