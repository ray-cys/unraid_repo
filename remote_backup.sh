#!/bin/bash
set -euo pipefail
LOCKFILE="/tmp/remote_backup.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Another remote_backup.sh run is active, exiting (lock: $LOCKFILE)"
  exit 1
fi

noParity=true
clearLog=false

pidof -o %PPID -x "$0" >/dev/null && \
logger -p err "Error: Script $0 already running, exiting!" && \
exit 1

# --------------------------------------------------------------------------------
# SETTINGS

# --- General ---
src_nas="Hubble NAS"
dest_nas="ISS NAS"

# --- Paths ---
media_src="/mnt/user/media"
secure_src="/mnt/user/secure"
media_dest="/mnt/user/media"
secure_dest="/mnt/user/secure"

log_file_subdir="/boot/logs/remote-logs"
preserved_raw_log_dir="$log_file_subdir/rsync_raw"
preserved_raw_log_keep=5
max_logs=2

# --- Remote & SSH ---
remote="root@192.168.50.3"
remote_mac="9C:6B:00:4B:BB:EE"    # Wake-on-LAN MAC for the remote
ssh_port=22                        # SSH port used to contact remote

# --- Rsync defaults & excludes ---
# Default rsync arguments.
rsync_default_args=("-ah" "-p" "--times" "--cvs-exclude" "--delete-during" "--partial" "--protect-args" "--itemize-changes" "--stats")
rsync_partial_dir=".rsync-partial"
default_excludes=(--exclude='*.sock' --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' --exclude='*/.cache/*')

# --- Snapshots ---
enable_snapshots=false
snapshot_root="/mnt/user/backup/snapshots"
snapshot_keep=7
manifest_keep=2

# --- Retry / Backoff / IO niceness ---
max_retries=3
retry_backoff=30
retry_on_codes="23 24 10 11 12 20 30"
enable_exponential_backoff=true
max_backoff=600
enable_per_attempt_notify=false
use_ionice=true
default_fail_code=50
df_retry_count=20
df_retry_sleep=6

# --- Preflight / safety / behavior ---
preflight_mode="metadata"   # one of: estimate|metadata|total
shutdown_on_failure=false

# --- Notifications & Logging ---
notify_bin="/usr/local/emhttp/webGui/scripts/notify"
notif_condensed_max_labels=3
notif_excerpt_lines=8
log_tail_lines=100

# --- SSH wait / timing ---
max_ssh_wait=180
ssh_wait_interval=5
ssh_connect_timeout=5      # seconds used for ssh -o ConnectTimeout
stabilize_wait=60          # seconds to wait after SSH is reachable for remote services/filesystems to stabilize
stabilize_interval=3       # poll interval during stabilization

# --- Runtime flags ---
dry_run=false

# --- Which labels to back up (order matters; arrays must match) ---
# Place or remove entries here to change which datasets are backed up.
labels_array=("Media" "Secure")
srcs_array=("$media_src" "$secure_src")
dests_array=("$media_dest" "$secure_dest")

# Ensure runtime dirs exist
mkdir -p "$log_file_subdir" 2>/dev/null || true
mkdir -p "$preserved_raw_log_dir" 2>/dev/null || true
mkdir -p "$log_file_subdir/manifests" 2>/dev/null || true

# Auto-created logfile name
log_file="$log_file_subdir/remote_backup_$(date +%Y%m%d_%H%M%S).log"
# --------------------------------------------------------------------------------

# Logging function
log() {
  local msg="$1"
  echo "$(date "+%Y/%m/%d %T") : $msg" | tee -a "$log_file"
}

syslog() {
  local level="$1"; shift || true
  local msg="$*"
  local prio
  case "$level" in
    debug) prio="user.debug" ;;
    info) prio="user.info" ;;
    notice) prio="user.notice" ;;
    warning|warn) prio="user.warning" ;;
    err|error) prio="user.err" ;;
    crit) prio="user.crit" ;;
    *) prio="user.notice" ;;
  esac
  logger -i -t "Remote Backup" -p "$prio" "$msg"
}

# Convert a bytes integer into a human-readable string using binary units
bytes_human() {
  local bytes=${1:-0}
  local TB=1099511627776
  local GB=1073741824
  local MB=1048576
  local KB=1024
  if [ "$bytes" -ge "$TB" ]; then
    awk "BEGIN{printf \"%.2f TB\", $bytes/$TB}"
  elif [ "$bytes" -ge "$GB" ]; then
    awk "BEGIN{printf \"%.2f GB\", $bytes/$GB}"
  elif [ "$bytes" -ge "$MB" ]; then
    awk "BEGIN{printf \"%.2f MB\", $bytes/$MB}"
  elif [ "$bytes" -ge "$KB" ]; then
    awk "BEGIN{printf \"%.2f KB\", $bytes/$KB}"
  else
    printf "%d B" "$bytes"
  fi
}

# Returns human runtime string computed from start time
format_runtime() {
  if [ -z "${start_time:-}" ]; then
    echo "0h:0m:0s"
    return
  fi
  local secs=$(( $(date +%s) - start_time ))
  printf '%dh:%dm:%ds' $((secs/3600)) $((secs%3600/60)) $((secs%60))
}

# Centralized wrapper around the Unraid notify command to ensure consistent
notify_send() {
  local level="$1"; shift
  local subject="$1"; shift
  local detail="$1"; shift
  local body="$1"; shift || true
  "$notify_bin" -i "$level" -b -s "$subject" -d "$detail" -m "$body"
  local nrc=$?
  if [ $nrc -ne 0 ]; then
    log_error "Notification command failed with exit code $nrc for subject: $subject"
  fi
  return $nrc
}

# Map notification semantic to chosen emoji buttons
notif_emoji() {
  case "${1:-ok}" in
    ok) printf '🟢' ;;
    fail) printf '🔴' ;;
    nospace) printf '🔵' ;;
    *) printf '🔵' ;;
  esac
}

# Conservative per-label preflight: compute source size and check available
preflight_disk_check() {
  local src="$1"
  local remote_dest="$2"
  local label="$3"
  local min_buffer=$((1024 * 1024 * 1024))

  local src_bytes
  if src_bytes=$(du -sb "$src" 2>/dev/null | cut -f1); then
    :
  else
    local src_kb
    src_kb=$(du -s "$src" 2>/dev/null | cut -f1 || echo 0)
    src_bytes=$((src_kb * 1024))
  fi
  src_bytes=${src_bytes:-0}

  local dest_avail
  if dest_avail=$(ssh -p "$ssh_port" "$remote" df --output=avail -B1 "$remote_dest" 2>/dev/null | tail -n1); then
    :
  else
    local dest_avail_kb
  dest_avail_kb=$(ssh -p "$ssh_port" "$remote" df -k "$remote_dest" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
    dest_avail=$((dest_avail_kb * 1024))
  fi
  dest_avail=${dest_avail:-0}

  human_src=$(bytes_human "$src_bytes")
  human_dest_avail=$(bytes_human "$dest_avail")

  local pct_buffer=$(( (src_bytes * 5) / 100 ))
  if [ "$pct_buffer" -lt "$min_buffer" ]; then
    safety_buffer=$min_buffer
  else
    safety_buffer=$pct_buffer
  fi
  human_buffer=$(bytes_human "$safety_buffer")
  log "Preflight $label: source=$human_src dest_avail=$human_dest_avail buffer=$human_buffer"

  if [ "$dest_avail" -lt $((src_bytes + safety_buffer)) ]; then
    need_bytes=$((src_bytes + safety_buffer))
    human_need=$(bytes_human "$need_bytes")
    log "Insufficient space for $label: need at least $human_need but only $human_dest_avail available on $remote:$remote_dest"
    total_required=$(( src_bytes + safety_buffer ))
    shortfall=0
    if [ "$total_required" -gt "$dest_avail" ]; then
      shortfall=$(( total_required - dest_avail ))
    fi
    human_required=$(bytes_human "$total_required")
    human_shortfall=$(bytes_human "$shortfall")
    runtime_now=$(format_runtime)
    body="$label backup aborted: required ${human_required} (source ${human_src} + buffer ${human_buffer}); available ${human_dest_avail}; shortfall ${human_shortfall}\n\nRuntime: ${runtime_now}\nSee log: $log_file"
  esub=$(notif_emoji nospace)
  notify_send alert "${esub} Scheduled Remote Backup - NO SPACE" "${esub} $label backup aborted: insufficient space" "$body"
    return 2
  fi

  return 0
}

# Aggregates space requirements for multiple labels that may target the
aggregate_preflight_check() {
  declare -A src_by_device
  declare -A remote_used
  declare -A remote_avail
  declare -A device_mount
  local min_buffer=$((1024 * 1024 * 1024))

  for i in "${!labels_array[@]}"; do
    local label=${labels_array[i]}
    local src=${srcs_array[i]}
    local dest=${dests_array[i]}

    local src_bytes=0
    if src_bytes=$(du -sb "$src" 2>/dev/null | cut -f1); then
      :
    else
      local src_kb
      src_kb=$(du -s "$src" 2>/dev/null | cut -f1 || echo 0)
      src_bytes=$((src_kb * 1024))
    fi

    local estimated_changed=0
    if [ "$preflight_mode" = "estimate" ]; then
      local tmp_est=$(mktemp /tmp/rsync_est.XXXXXX)
      if command -v stdbuf >/dev/null 2>&1; then
        est_cmd=(stdbuf -oL rsync "${rsync_default_args[@]:-}" --itemize-changes --stats --dry-run --delete "${src}/" "$remote:$dest")
      else
        est_cmd=(rsync "${rsync_default_args[@]:-}" --itemize-changes --stats --dry-run --delete "${src}/" "$remote:$dest")
      fi
      ( "${est_cmd[@]}" 2>&1 | tee "$tmp_est" ) >/dev/null 2>&1 || true
      estimated_changed=$(grep -i 'Total transferred file size' "$tmp_est" | tail -n1 | awk -F: '{gsub(/[^0-9]/,"",$2); print $2}' || echo 0)
      rm -f "$tmp_est" 2>/dev/null || true
    else
      estimated_changed=$src_bytes
    fi

    if [ "$preflight_mode" = "metadata" ]; then
      estimated_changed=$(manifest_diff_bytes "$label" "$src" 2>/dev/null || echo 0)
    fi

    local df_out
    df_out=""
    local df_try=0
    while [ $df_try -lt ${df_retry_count:-3} ]; do
      df_out=$(ssh -o BatchMode=yes -o ConnectTimeout="$ssh_connect_timeout" -p "$ssh_port" "$remote" df -P -B1 "$dest" 2>/dev/null | awk 'NR==2{print $1"|"$3"|"$4"|"$6}' || true)
      if [ -n "$df_out" ]; then
        break
      fi
      df_try=$((df_try+1))
      sleep ${df_retry_sleep:-2}
    done
    if [ -z "$df_out" ]; then
      log "Aggregate preflight: failed to query remote df for $dest after ${df_try} tries"
      syslog err "Aggregate preflight failed: could not query remote df for $dest"
      echo "Failed to query remote disk usage for $dest" >&2
      return ${default_fail_code:-2}
    fi
    local device=$(printf '%s' "$df_out" | cut -d'|' -f1)
    local used=$(printf '%s' "$df_out" | cut -d'|' -f2)
    local avail=$(printf '%s' "$df_out" | cut -d'|' -f3)
    local mountp=$(printf '%s' "$df_out" | cut -d'|' -f4)

    device_mount["$device"]="$mountp"
    remote_used["$device"]=$(( ${remote_used["$device"]:-0} + used ))
    remote_avail["$device"]=$avail
    src_by_device["$device"]=$(( ${src_by_device["$device"]:-0} + estimated_changed ))
  done

  local fail_msg=""
  for device in "${!src_by_device[@]}"; do
    local src_sum=${src_by_device[$device]}
    local used=${remote_used[$device]:-0}
    local avail=${remote_avail[$device]:-0}
    local mountp=${device_mount[$device]:-/}

    local needed=$(( src_sum - used ))
    if [ "$needed" -lt 0 ]; then
      needed=0
    fi

    src_sum=${src_sum:-0}
    used=${used:-0}
    avail=${avail:-0}

    local pct_buffer=$(( (src_sum * 5) / 100 ))
    local safety_buffer
    if [ "$pct_buffer" -lt "$min_buffer" ]; then
      safety_buffer=$min_buffer
    else
      safety_buffer=$pct_buffer
    fi

    local human_src_sum=$(bytes_human "$src_sum")
    local human_needed=$(bytes_human "$needed")
    local human_avail=$(bytes_human "$avail")
    local human_buffer=$(bytes_human "$safety_buffer")

    log "Aggregate preflight for device $device mount $mountp: total_src=$human_src_sum used=$used avail=$human_avail buffer=$human_buffer"

    if [ "$avail" -lt $(( needed + safety_buffer )) ]; then
      fail_msg+="Device $device mounted on $mountp: need ~$human_needed + buffer $human_buffer, available $human_avail\n"
    fi
  done

  if [ -n "$fail_msg" ]; then
    printf '%b' "$fail_msg"
    return 2
  fi

  return 0
}

# Parse an rsync --stats block captured in a raw rsync log file
parse_rsync_stats() {
  local file="$1"
  local label="$2"
  local num_files_transferred=0
  local total_file_size=0
  local total_transferred_size=0
  local total_bytes_sent=0
  local deletes=0

  num_files_transferred=$(grep -i 'Number of files transferred' "$file" | tail -n1 | awk -F: '{gsub(/[^0-9]/,"",$2); print $2}' || echo 0)
  total_file_size=$(grep -i 'Total file size' "$file" | tail -n1 | awk -F: '{gsub(/[^0-9]/,"",$2); print $2}' || echo 0)
  total_transferred_size=$(grep -i 'Total transferred file size' "$file" | tail -n1 | awk -F: '{gsub(/[^0-9]/,"",$2); print $2}' || echo 0)
  total_bytes_sent=$(grep -i 'Total bytes sent' "$file" | tail -n1 | awk -F: '{gsub(/[^0-9]/,"",$2); print $2}' || echo 0)
  deletes=$(grep -E '^[[:space:]]*deleting ' "$file" | wc -l || echo 0)

  num_files_transferred=${num_files_transferred:-0}
  total_file_size=${total_file_size:-0}
  total_transferred_size=${total_transferred_size:-0}
  total_bytes_sent=${total_bytes_sent:-0}
  deletes=${deletes:-0}

  local human_total=$(bytes_human "$total_file_size")
  local human_transferred=$(bytes_human "$total_transferred_size")
  local human_sent=$(bytes_human "$total_bytes_sent")

  rsync_total_bytes["$label"]="$total_file_size"
  rsync_transferred_bytes["$label"]="$total_transferred_size"
  rsync_files["$label"]="$num_files_transferred"
  rsync_deletes["$label"]="$deletes"
  rsync_bytes_sent["$label"]="$total_bytes_sent"

  if [ "$total_transferred_size" -gt 0 ] || [ "$num_files_transferred" -gt 0 ] || [ "$deletes" -gt 0 ]; then
    printf '%s: %s sent %s, del %s' "$label" "$human_transferred" "$num_files_transferred" "$deletes"
  else
    printf '%s: no stats' "$label"
  fi
}

# Map a numeric rsync exit code to a short, human-friendly description used
rsync_exit_description() {
  local code=${1:-0}
  case "$code" in
    0) echo "Success" ;;
    1) echo "Syntax or usage error" ;;
    2) echo "Protocol incompatibility" ;;
    3) echo "Errors selecting input/output files, dirs" ;;
    4) echo "Requested action not supported: an attempt was made to manipulate
a file/directory etc that is not supported by rsync" ;;
    5) echo "Error starting client-server protocol" ;;
    6) echo "Daemon unable to append to log-file" ;;
    10) echo "Error in socket I/O" ;;
    11) echo "Error in file I/O" ;;
    12) echo "Error in rsync protocol data stream" ;;
    13) echo "Errors with program diagnostics" ;;
    14) echo "Error in IPC code" ;;
    20) echo "Received SIGUSR1 or SIGINT" ;;
    21) echo "Some error returned by waitpid()" ;;
    22) echo "SIGPIPE (broken pipe)" ;;
    23) echo "Partial transfer due to error (files/attrs not transferred)" ;;
    24) echo "Partial transfer due to vanished source files" ;;
    30) echo "Timeout in data send/receive" ;;
    *) echo "Unknown rsync exit code $code" ;;
  esac
}

# Returns a concise excerpt from a preserved raw rsync log
extract_rsync_errors() {
  local file="$1"
  local max_lines=${2:-10}
  if [ ! -f "$file" ]; then
    echo "(no rsync raw log)"
    return 0
  fi

  local excerpt
  excerpt=$(grep -iE "error|warning|failed|permission denied|permission" "$file" 2>/dev/null | tail -n "$max_lines" || true)
  if [ -n "$excerpt" ]; then
    echo "$excerpt"
    return 0
  fi
  tail -n "$max_lines" "$file" 2>/dev/null || echo "(no rsync output)"
}

# Create a compact manifest for `src` containing lines of the form:
write_manifest() {
  local label="$1"
  local src="$2"
  local dest="$log_file_subdir/manifests"
  mkdir -p "$dest" 2>/dev/null || true
  local out="$dest/${label// /_}_manifest_$(date +%Y%m%d_%H%M%S).txt"
  (cd "$src" && find . -type f -printf '%P\t%s\t%T@\n') > "$out" 2>/dev/null || true
  if [ -f "$out" ]; then
    log "Wrote manifest for $label: $out"
  else
    log "Warning: manifest write failed for $label (attempted $out)"
  fi
  mapfile -t mlist < <(ls -1t "$dest/${label// /_}_manifest_"*.txt 2>/dev/null || true)
  if [ "${#mlist[@]}" -gt "$manifest_keep" ]; then
    for ((i=manifest_keep;i<${#mlist[@]};i++)); do
      rm -f "${mlist[$i]}" 2>/dev/null || true
    done
  fi
}

# Print the content of the latest manifest for `label` (if any) to stdout.
load_latest_manifest() {
  local label="$1"
  local dest="$log_file_subdir/manifests"
  local latest
  latest=$(ls -1t "$dest/${label// /_}_manifest_"*.txt 2>/dev/null | head -n1 || true)
  if [ -n "$latest" ] && [ -f "$latest" ]; then
    cat "$latest"
    return 0
  fi
  return 1
}

# Compare the current set of files under `src` to the latest stored manifest
manifest_diff_bytes() {
  local label="$1"
  local src="$2"
  local manifest_file
  manifest_file=$(ls -1t "$log_file_subdir/manifests/${label// /_}_manifest_"*.txt 2>/dev/null | head -n1 || true)
  if [ -z "$manifest_file" ] || [ ! -f "$manifest_file" ]; then
    du -sb "$src" 2>/dev/null | cut -f1 || echo 0
    return 0
  fi
  declare -A man
  while IFS=$'\t' read -r path size mtime; do
    man["$path"]=$size
  done < "$manifest_file"

  local sum=0
  while IFS= read -r -d '' f; do
    rel=${f#./}
    if [ -z "$rel" ]; then
      rel="$f"
    fi
    if [ -f "$f" ]; then
      s=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
      old=${man["$rel"]:-0}
      if [ "$s" -gt "$old" ]; then
        sum=$((sum + (s - old)))
      fi
    fi
  done < <(cd "$src" && find . -type f -print0)

  echo "$sum"
}

# For metadata preflight mode, ensure at least one manifest exists for each configured label
ensure_manifests_for_labels() {
  if [ "${preflight_mode:-}" != "metadata" ]; then
    return 0
  fi
  local dest="$log_file_subdir/manifests"
  mkdir -p "$dest" 2>/dev/null || true
  for idx in "${!labels_array[@]}"; do
    label=${labels_array[$idx]}
    safe_label=${label// /_}
    latest=$(ls -1t "$dest/${safe_label}_manifest_"*.txt 2>/dev/null | head -n1 || true)
    if [ -z "$latest" ] || [ ! -f "$latest" ]; then
      log "No manifest found for $label; creating baseline manifest"
      write_manifest "$label" "${srcs_array[$idx]}"
    else
      log "Found existing manifest for $label: $latest"
    fi
  done
}

# Wrapper around rsync that builds command line, captures raw output for diagnostics, parses --stats, and implements retry logic
run_rsync() {
  local src="$1"
  local dest="$2"
  shift 2
  local label="${!#}"
  local opts=()
  if [ "$#" -gt 1 ]; then
    opts=("${@:1:$#-1}")
  fi

  log "Initialize backup ($label --> $dest_nas) == $(date)"
  local -a default_excludes_local=("${default_excludes[@]:-}")

  local -a rsync_args=("${rsync_default_args[@]:-}")
  rsync_args+=("--partial-dir=${rsync_partial_dir}")
  rsync_args+=("${default_excludes_local[@]:-}")
  if [ "$dry_run" = true ]; then
    rsync_args+=("--dry-run")
  fi
  if [ "${#opts[@]}" -ne 0 ]; then
    rsync_args+=("${opts[@]}")
  fi

  set +e
    local attempt=1
    local last_status=0
    local tmp_rslog=$(mktemp /tmp/rsync_raw.XXXXXX)

    while :; do
      log "RSYNC attempt $attempt/$max_retries for $label"

    if command -v stdbuf >/dev/null 2>&1; then
      rsync_bin=(stdbuf -oL rsync)
    else
      rsync_bin=(rsync)
    fi

    # Build a per-attempt copy of rsync args so retries don't accumulate
    local cur_rsync_args=("${rsync_args[@]:-}")
    if [ "$enable_snapshots" = true ]; then
      safe_label=${label// /_}
      latest_link="$snapshot_root/$safe_label/latest"
      cur_rsync_args+=("--link-dest=$latest_link")
    fi

    rsync_cmd=("${rsync_bin[@]}" "${cur_rsync_args[@]}" "$src/" "$remote:$dest")

    if [ "$use_ionice" = true ] && command -v ionice >/dev/null 2>&1; then
      exec_cmd=(ionice -c2 -n7 nice -n 10 "${rsync_cmd[@]}")
    else
      exec_cmd=("${rsync_cmd[@]}")
    fi

    # Log the exact command for debugging
    log "Running: $(printf '%q ' "${exec_cmd[@]}")"

    ( "${exec_cmd[@]}" 2>&1 | tee "$tmp_rslog" ) | while IFS= read -r line; do
        printf '%s : %s\n' "$(date '+%Y/%m/%d %T')" "$line"
      done | tee -a "$log_file"
    last_status=${PIPESTATUS[0]}

    if [ -f "$tmp_rslog" ]; then
      tmp_summary_file=$(mktemp /tmp/rsync_summary.XXXXXX)
      if parse_rsync_stats "$tmp_rslog" "$label" > "$tmp_summary_file" 2>/dev/null; then
        rsync_summaries["$label"]="$(cat "$tmp_summary_file")"
      else
        rsync_summaries["$label"]="$label: no stats"
      fi
      rm -f "$tmp_summary_file" 2>/dev/null || true
      ts=$(date +%Y%m%d_%H%M%S)
      safe_label=${label// /_}
      saved_copy="$preserved_raw_log_dir/rsync_raw_${safe_label}_${ts}"
      if [ "$last_status" -ne 0 ]; then
        saved_copy+="_fail.log"
        rsync_raw_failed["$label"]="$saved_copy"
      else
        saved_copy+="_success.log"
      fi
      cp "$tmp_rslog" "$saved_copy" 2>/dev/null || true
      mapfile -t old_logs < <(ls -1t "$preserved_raw_log_dir"/rsync_raw_${safe_label}_*.log 2>/dev/null || true)
      if [ "${#old_logs[@]}" -gt "$preserved_raw_log_keep" ]; then
        for ((i=preserved_raw_log_keep;i<${#old_logs[@]};i++)); do
          rm -f "${old_logs[$i]}" 2>/dev/null || true
        done
      fi
      rm -f "$tmp_rslog"
    else
      rsync_summaries["$label"]="$label: no stats"
    fi

    if [ "$last_status" -eq 0 ]; then
      if [ "$enable_snapshots" = true ]; then
        safe_label=${label// /_}
        now=$(date +%Y%m%d_%H%M%S)
        snap_dest="$snapshot_root/$safe_label/$now"
        if [ "$dry_run" = false ]; then
          ssh -p "$ssh_port" "$remote" "mkdir -p '$snap_dest'" 2>/dev/null || true
        else
          log "Dry-run: would create remote snapshot dir $snap_dest"
        fi
        if [ "$dry_run" = false ]; then
          write_manifest "$label" "$src"
        else
          log "Dry-run: skipping manifest write for $label"
        fi
      fi
      set -e
      return 0
    fi

    local should_retry=0
    if [ -z "$retry_on_codes" ]; then
      should_retry=1
    else
      for code in $retry_on_codes; do
        if [ "$last_status" -eq "$code" ]; then
          should_retry=1
          break
        fi
      done
    fi

    if [ "$should_retry" -eq 0 ] || [ "$attempt" -ge "$max_retries" ]; then
      log "rsync final failure for $label with exit=$last_status after attempt $attempt"
      syslog err "rsync final failure: $label exit=$last_status after attempt $attempt"
      log "Recent rsync output (last 100 lines):"
      tail -n 100 "$log_file" | sed -n '1,200p' | tee -a "$log_file"
      set -e
      return $last_status
    fi

    if [ "$enable_exponential_backoff" = true ]; then
      backoff=$(( retry_backoff * (2 ** (attempt - 1)) ))
      if [ "$backoff" -gt "$max_backoff" ]; then
        backoff=$max_backoff
      fi
      jitter=$(( RANDOM % ( (backoff / 2) + 1 ) ))
      sleep_sec=$(( backoff + jitter ))
    else
      sleep_sec=$retry_backoff
    fi

    log "rsync returned $last_status for $label; will retry in ${sleep_sec}s (attempt $attempt/$max_retries)"
    if [ "$enable_per_attempt_notify" = true ]; then
      desc=$(rsync_exit_description "$last_status")
      # preserve a short excerpt from the tmp rsync log if present
      excerpt=""
      if [ -f "$tmp_rslog" ]; then
        excerpt=$(extract_rsync_errors "$tmp_rslog" ${notif_excerpt_lines:-8} 2>/dev/null || true)
      fi
      runtime_now=$(format_runtime)
      body="Label: $label\nAttempt: ${attempt}/${max_retries}\nLast exit: ${last_status} -> ${desc}\nBackoff: ${sleep_sec}s\n\nExcerpt:\n${excerpt}\n\nRuntime: ${runtime_now}\nSee log: $log_file"
      notify_send warning "Remote Backup - RETRY" "$label: retrying (attempt $((attempt+1))/$max_retries) in ${sleep_sec}s" "$body"
    fi

    sleep "$sleep_sec"
    attempt=$((attempt + 1))
  done
  set -e
  return $last_status
}

# Simple utility to keep at most `max` most-recent files in `dir`.
remove_old_logs() {
  local dir="$1"
  local max="$2"
  logs=($(find "$dir" -mindepth 1 -maxdepth 1 -type f -printf '%T+\t%p\n' | sort | cut -f2))
  while [ "${#logs[@]}" -gt "$max" ]; do
    rm -rf "${logs[0]}"
    logs=("${logs[@]:1}")
  done
}

# Gather small read-only remote artifacts (df, snapshot listings) used by notifications. 
collect_notification_artifacts() {
  local outdir="$preserved_raw_log_dir/notify_artifacts"
  mkdir -p "$outdir" 2>/dev/null || true
  local ts
  ts=$(date +%Y%m%d_%H%M%S)
  notify_df_file="$outdir/remote_df_${ts}.txt"
  notify_snap_file="$outdir/snapshots_${ts}.txt"

  if ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$ssh_port" "$remote" "df -h" > "$notify_df_file" 2>/dev/null; then
    :
  else
    echo "(remote df unavailable)" > "$notify_df_file"
  fi

  : > "$notify_snap_file"
  for lbl in "${labels_array[@]}"; do
    safe_label=${lbl// /_}
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$ssh_port" "$remote" "readlink -f '$snapshot_root/$safe_label/latest' 2>/dev/null || echo '(no latest)'" >> "$notify_snap_file" 2>/dev/null; then
      :
    else
      echo "${lbl}: (snapshot info unavailable)" >> "$notify_snap_file"
    fi
  done

  return 0
}

# Main flow entry
# 1) record start time
# 2) wake remote with Wake-on-LAN
# 3) wait for SSH to become available (with timeout)
# 4) run aggregate preflight to determine if remote has enough space
# 5) execute per-label rsync runs (supports optional snapshot/link-dest)
# 6) collect results, notify (PASS/FAIL), optionally shut down remote, rotate logs
#
# Record script start time
start_time=$(date +%s)
log "$src_nas --> $dest_nas start: $(date)"

# Wake-on-LAN
etherwake 9C:6B:00:4B:BB:EE
log "Sent Wake-on-LAN to $dest_nas"

## Wait loop for SSH readiness
start_wait_ts=$(date +%s)
log "Waiting up to ${max_ssh_wait}s for $dest_nas SSH to become available..."
ssh_reachable=0
while :; do
  now=$(date +%s)
  elapsed=$(( now - start_wait_ts ))
  if ssh -o BatchMode=yes -o ConnectTimeout="$ssh_connect_timeout" -p "$ssh_port" "$remote" true >/dev/null 2>&1; then
    remaining=$(( max_ssh_wait - elapsed ))
    if [ "$remaining" -lt 0 ]; then remaining=0; fi
    log "$dest_nas SSH is reachable after ${elapsed}s (timeout in ${remaining}s)"

    stab_start_ts=$(date +%s)
    log "Waiting up to ${stabilize_wait}s for remote filesystem readiness..."
    stabilized=0
    while :; do
      stab_now=$(date +%s)
      stab_elapsed=$(( stab_now - stab_start_ts ))
      if ssh -o BatchMode=yes -o ConnectTimeout="$ssh_connect_timeout" -p "$ssh_port" "$remote" df -P -B1 / >/dev/null 2>&1; then
        log "Remote filesystem responded to df after ${stab_elapsed}s; proceeding"
        stabilized=1
        break
      fi
      if [ "$stab_elapsed" -ge "$stabilize_wait" ]; then
        log "Remote filesystem did not stabilize within ${stabilize_wait}s; proceeding anyway (df may fail)"
        break
      fi
      sleep "$stabilize_interval"
    done

    ssh_reachable=1
    break
  fi
  if [ "$elapsed" -ge "$max_ssh_wait" ]; then
    log "Timeout waiting for SSH on $dest_nas after ${elapsed}s"
    break
  fi
  remaining=$(( max_ssh_wait - elapsed ))
  log "$dest_nas SSH not available yet; sleeping ${ssh_wait_interval}s (remaining ${remaining}s)"
  sleep "$ssh_wait_interval"
done
if [ "$ssh_reachable" -eq 1 ]; then
  :
else
  log "Proceeding despite SSH not being reachable; Disk check may fail"
fi

## Per-label backup execution
declare -A rsync_results
failed_labels=()
declare -A rsync_summaries
declare -A rsync_total_bytes
declare -A rsync_transferred_bytes
declare -A rsync_files
declare -A rsync_deletes
declare -A rsync_bytes_sent

# Prepare arrays for aggregated preflight (dynamic labels)
labels_array=("Media" "Secure")
srcs_array=("$media_src" "$secure_src")
dests_array=("$media_dest" "$secure_dest")

# Run aggregate preflight across all labels targeting the remote
agg_msg=""

# If using metadata preflight, ensure manifests exist for all configured labels
ensure_manifests_for_labels || true

# Runs `aggregate_preflight_check` which sums estimated changed bytes per remote device and compares against available space
if ! agg_msg=$(aggregate_preflight_check 2>&1); then
  log "Aggregate preflight failed: $agg_msg"
  runtime_now=$(format_runtime)
  body="$agg_msg\n\nRuntime: ${runtime_now}\nSee log: $log_file"
  notify_send alert "Scheduled Remote Backup - NO SPACE" "Aggregate preflight failed: insufficient remote space" "$body"
  for lbl in "${labels_array[@]}"; do
    rsync_results["$lbl"]=2
    failed_labels+=("$lbl")
  done
else
  log "Aggregate preflight passed: proceeding with per-label rsyncs"

  if [ "$enable_snapshots" = true ]; then
    now=$(date +%Y%m%d_%H%M%S)
    snapdir="$snapshot_root/Media/$now"
  ssh -p "$ssh_port" "$remote" "mkdir -p '$snapdir'" 2>/dev/null || true
    run_rsync "$media_src" "$snapdir" --exclude=net/ "Media"
  else
    run_rsync "$media_src" "$media_dest" --exclude=net/ "Media"
  fi
  rsync_results[Media]=$?
  log "Result: Media rsync exit=${rsync_results[Media]}"
  if [ "$enable_snapshots" = true ] && [ "${rsync_results[Media]:-1}" -eq 0 ] && [ "$dry_run" = false ]; then
  ssh -p "$ssh_port" "$remote" "ln -snf '$snapdir' '$snapshot_root/Media/latest'"
  ssh -p "$ssh_port" "$remote" "ls -1dt '$snapshot_root/Media'/*/ 2>/dev/null | tail -n +$((snapshot_keep+1)) | xargs -r rm -rf --" || true
  fi
  if [ "${rsync_results[Media]}" -ne 0 ]; then
    failed_labels+=("Media")
  fi

  if [ "$enable_snapshots" = true ]; then
    now=$(date +%Y%m%d_%H%M%S)
    snapdir="$snapshot_root/Secure/$now"
  ssh -p "$ssh_port" "$remote" "mkdir -p '$snapdir'" 2>/dev/null || true
    run_rsync "$secure_src" "$snapdir" --exclude=torrent/ "Secure"
  else
    run_rsync "$secure_src" "$secure_dest" --exclude=torrent/ "Secure"
  fi
  rsync_results[Secure]=$?
  log "Result: Secure rsync exit=${rsync_results[Secure]}"
  if [ "$enable_snapshots" = true ] && [ "${rsync_results[Secure]:-1}" -eq 0 ] && [ "$dry_run" = false ]; then
  ssh -p "$ssh_port" "$remote" "ln -snf '$snapdir' '$snapshot_root/Secure/latest'"
  ssh -p "$ssh_port" "$remote" "ls -1dt '$snapshot_root/Secure'/*/ 2>/dev/null | tail -n +$((snapshot_keep+1)) | xargs -r rm -rf --" || true
  fi
  if [ "${rsync_results[Secure]}" -ne 0 ]; then
    failed_labels+=("Secure")
  fi
fi

# Aggregate overall status: 0 OK, 1 failure
if [ "${#failed_labels[@]}" -eq 0 ]; then
  backup_status=0
else
  backup_status=1
fi

## Verification, notification and (optional) shutdown
collect_notification_artifacts || true

if [ "$backup_status" -eq 0 ]; then
  log "$src_nas backup complete: Status $backup_status"
else
  failed_summary=""
  notify_detail=""
  for lbl in "${failed_labels[@]}"; do
    code=${rsync_results[$lbl]:-${default_fail_code:-2}}
    desc=$(rsync_exit_description "$code")
    transferred=${rsync_transferred_bytes[$lbl]:-0}
    total_bytes=${rsync_total_bytes[$lbl]:-0}
    human_trans=$(bytes_human "$transferred")
    human_total=$(bytes_human "$total_bytes")
    failed_summary+="$lbl: exit=${code} (${desc}); transferred ${human_trans} of ${human_total}; "
    notify_detail+="$lbl: exit=${code} -> ${desc}\nTransferred: ${human_trans} of ${human_total}\n"
    raw=${rsync_raw_failed[$lbl]:-}
    if [ -n "$raw" ] && [ -f "$raw" ]; then
      notify_detail+=$'--- recent rsync output ---\n'
      notify_detail+="$(extract_rsync_errors "$raw" ${notif_excerpt_lines:-8})"$'\n\n'
    fi
  done
  logger -p crit "$src_nas backup failed: Errors: $failed_summary"
  log "$src_nas backup failed: Errors: $failed_summary"
  runtime_now=$(format_runtime)
  notify_detail+="Runtime: ${runtime_now}\nSee log: $log_file"
  esub=$(notif_emoji fail)
  notify_send alert "${esub} Scheduled Remote Backup - FAIL" "${esub} Backup FAIL: $failed_summary" "$notify_detail"
fi

# Record end time
runtime_converted=$(format_runtime)

# Log status and send notification
log "$src_nas --> $dest_nas complete == Runtime: $runtime_converted"
 condensed_parts=()
detailed_body=$'Runtime: '
detailed_body+="$runtime_converted"$'\n'
 for lbl in "${!rsync_summaries[@]}"; do
   condensed_parts+=("${rsync_summaries[$lbl]}")

   total=${rsync_total_bytes[$lbl]:-0}
   transferred=${rsync_transferred_bytes[$lbl]:-0}
   files=${rsync_files[$lbl]:-0}
   deletes=${rsync_deletes[$lbl]:-0}
   sent=${rsync_bytes_sent[$lbl]:-0}

   human_total=$(bytes_human "$total")
   human_transferred=$(bytes_human "$transferred")
   human_sent=$(bytes_human "$sent")

   if [ "$total" -gt 0 ] && [ "$transferred" -ge 0 ]; then
     percent=$(awk "BEGIN{ if ($total>0) printf \"%.1f\", ($transferred / $total) * 100; else print 0 }")
  detailed_body+="$lbl: $human_total total, transferred $human_transferred ($percent%), files $files, deleted $deletes, sent $human_sent"$'\n'
   else
  detailed_body+="$lbl: transferred $human_transferred, files $files, deleted $deletes, sent $human_sent"$'\n'
   fi
 done

max_labels_in_d=${notif_condensed_max_labels:-3}
condensed_show=()
idx=0
for part in "${condensed_parts[@]}"; do
  if [ $idx -ge $max_labels_in_d ]; then
    break
  fi
  condensed_show+=("$part")
  idx=$((idx + 1))
done
extra_count=$(( ${#condensed_parts[@]} - ${#condensed_show[@]} ))

condensed_line=$(IFS=' | '; printf '%s' "${condensed_show[*]}")
if [ "$extra_count" -gt 0 ]; then
  condensed_line+=" | +${extra_count} more"
fi

if [ "${#failed_labels[@]}" -eq 0 ]; then
  body="${detailed_body}"
  esub=$(notif_emoji ok)
  notify_send normal "${esub} Scheduled Remote Backup - OK" "${esub} Backup. OK: $condensed_line" "$body"
  if [ "$dry_run" = false ]; then
    log "Shutting down remote after successful backup"
    if ! ssh -p "$ssh_port" "$remote" "df --type=xfs -h && powerdown" 2>/dev/null; then
      log "Remote shutdown command failed"
      syslog err "Remote shutdown command failed on $remote"
    fi
    sleep 5s
  else
    log "Dry-run: skipping remote powerdown after success"
  fi
else
  if [ "$shutdown_on_failure" = true ]; then
    log "Shutdown_on_failure=true; requesting remote powerdown despite failures"
  if ! ssh -p "$ssh_port" "$remote" "df --type=xfs -h && powerdown" 2>/dev/null; then
    log "Remote shutdown command failed"
    syslog err "Remote shutdown command failed on $remote"
  fi
  else
    log "Not shutting down remote because shutdown_on_failure=false"
  fi
fi

# Remove old logs
remove_old_logs "$log_file_subdir" "$max_logs"

exit 0