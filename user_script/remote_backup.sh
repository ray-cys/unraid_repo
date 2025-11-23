#!/bin/bash
LOCKFILE="/tmp/remote_backup.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Another remote_backup.sh run is active, exiting (lock: $LOCKFILE)"
  exit 1
fi
################################################################################
# ---------------- Configuration ----------------
# Remote Shares Backup Settings
################################################################################

# === General ===
SRC_NAS="Hubble NAS"                                                  # Source NAS name for logging/notifications
DEST_NAS="ISS NAS"                                                    # Destination NAS name for logging/notifications

# === Paths ===
MEDIA_SRC="/mnt/user/media"                                           # Source path for "Media" label
SECURE_SRC="/mnt/user/secure"                                         # Source path for "Secure" label
MEDIA_DEST="/mnt/user/media"                                          # Destination path for "Media" label
SECURE_DEST="/mnt/user/secure"                                        # Destination path for "Secure" label
LOG_FILE_SUBDIR="/mnt/cache/system/logs/remote_logs"                  # Directory to store log files
LOG_FILE="$LOG_FILE_SUBDIR/remote_backup_$(date +%Y%m%d_%H%M%S).log"  # Log file path
PRESERVED_RAW_LOG_DIR="$LOG_FILE_SUBDIR/rsync_raw"                    # Directory to store preserved raw rsync logs

# === Logs Settings ===
MAX_LOGS=2                                                            # Maximum number of dated log files to keep
MAX_MANIFEST=1                                                        # Maximum number of manifest files to keep (set 1 to keep only latest)

# === Remote & SSH ===
REMOTE="root@192.168.50.3"                                            # SSH user and hostname/IP of the remote
REMOTE_MAC="9C:6B:00:4B:BB:EE"                                        # Wake-on-LAN MAC for the remote
SSH_PORT=22                                                           # SSH port used to contact remote


# === Rsync defaults & excludes ===
# Default rsync arguments.
RSYNC_DEFAULT_ARGS=("-ah" "-p" "--times" "--cvs-exclude" "--delete-during" "--partial" "--protect-args" "--itemize-changes" "--stats")  # Add or remove default rsync args as needed
RSYNC_PARTIAL_DIR=".rsync-partial"                                                                                  # Partial directory name
DEFAULT_EXCLUDES=(--exclude='*.sock' --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' --exclude='*/.cache/*') # Default excludes for all labels
RSYNC_EXTRA_EXCLUDES=("net/" "torrent/")                                                                            # Per-label additional excludes matching LABELS_ARRAY order
RSYNC_STREAM_TIMESTAMPED_LOG=${RSYNC_STREAM_TIMESTAMPED_LOG:-true}                                                  # true -> timestamp each rsync output line, false -> raw output only

# === Snapshots ===
ENABLE_SNAPSHOTS=false                                                                                              # Enable snapshot creation on source after successful backup
SNAPSHOT_ROOT="/mnt/user/backup/snapshots"                                                                          # Snapshot root directory
SNAPSHOT_KEEP=7                                                                                                     # Number of snapshots to keep

# === Retry / Backoff / IO niceness ===
MAX_RETRIES=3                                                          # Maximum number of rsync retries
RETRY_BACKOFF=30                                                       # Base backoff time in seconds
RETRY_ON_CODES="23 24 10 11 12 20 30"                                  # Rsync exit codes that trigger a retry
ENABLE_EXPONENTIAL_BACKOFF=true                                        # Enable exponential backoff for retries
MAX_BACKOFF=600                                                        # Maximum backoff time in seconds
ENABLE_PER_ATTEMPT_NOTIFY=false                                        # Enable per-attempt notifications
USE_IONICE=true                                                        # Use ionice with rsync
DEFAULT_FAIL_CODE=50                                                   # Default failure exit code
DF_RETRY_COUNT=20                                                      # Number of df retries
DF_RETRY_SLEEP=6                                                       # Sleep time between df retries

# === Preflight / Safety / Behavior ===
PREFLIGHT_MODE="metadata"                                              # Use one of: estimate|metadata|total
SHUTDOWN_ON_FAILURE=false                                              # Shutdown source NAS on failure

# === Notifications & Logging ===
NOTIF_CONDENSED_MAX_LABELS=3                                           # Maximum number of labels to include in condensed notifications
NOTIF_EXCERPT_LINES=8                                                  # Number of lines to include in notification excerpts

# === Log Ownership & Permissions ===
LOG_USER="${LOG_USER:-nobody}"                                         # Log file owner user
LOG_DIR_MODE="${LOG_DIR_MODE:-0775}"                                   # Log directory mode
LOG_FILE_MODE="${LOG_FILE_MODE:-0664}"                                 # Log file mode

# === SSH wait / Timings ===
MAX_SSH_WAIT=420                                                       # Total seconds to wait for SSH to become reachable
SSH_WAIT_INTERVAL=20                                                   # Sleep interval between SSH reachability checks
SSH_CONNECT_TIMEOUT=5                                                  # Seconds used for ssh -o ConnectTimeout per attempt
STABILIZE_WAIT=90                                                      # Seconds to wait after SSH is reachable for remote services/filesystems to stabilize
STABILIZE_INTERVAL=3                                                   # Poll interval during stabilization
ARRAY_READY_WAIT=180                                                   # Additional wait for Unraid array (/mnt/user) readiness
ARRAY_READY_INTERVAL=6                                                 # Poll interval for array readiness check

# === Runtime Flags ===
DRY_RUN=false                                                          # When true, perform a dry run without actual data transfer

# === Labels to backup (arrays must match) ===
LABELS_ARRAY=("Media" "Secure")                                        # Labels for datasets to back up
SRCS_ARRAY=("$MEDIA_SRC" "$SECURE_SRC")                                # Source paths for datasets
DESTS_ARRAY=("$MEDIA_DEST" "$SECURE_DEST")                             # Destination paths for datasets

# === Directory setup ===
ensure_dir() { # path mode user
  local p="$1" m="${2:-$LOG_DIR_MODE}" u="${3:-$LOG_USER}"
  mkdir -p "$p" 2>/dev/null || true
  chown "$u" "$p" 2>/dev/null || true
  chmod "$m" "$p" 2>/dev/null || true
}
ensure_file() { # file mode user
  local f="$1" m="${2:-$LOG_FILE_MODE}" u="${3:-$LOG_USER}"
  : > "$f"
  chown "$u" "$f" 2>/dev/null || true
  chmod "$m" "$f" 2>/dev/null || true
}
ensure_dir "$LOG_FILE_SUBDIR"
ensure_dir "$PRESERVED_RAW_LOG_DIR"
ensure_dir "$LOG_FILE_SUBDIR/manifests"
ensure_file "$LOG_FILE"

# === Logging ===
log() {
  local msg="$1"
  echo "$(date "+%Y/%m/%d %T") : $msg" | tee -a "$LOG_FILE"
}
syslog() {
  local level="$1"; shift || true
  local msg="$*"
  ssh_run() { # ssh with batch + ConnectTimeout handling
    ssh -o BatchMode=yes -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -p "$SSH_PORT" "$REMOTE" "$@"
  }
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

################################################################################

# --- Helpers Functions ---
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

# --- Helpers Functions ---
# Convert a human-readable size like "54.34T" or "18.74G bytes" -> integer bytes
human_to_bytes() {
  local s="$1"
  s=$(printf '%s' "$s" | sed -E 's/[[:space:]]*bytes$//I' | tr -d ',')
  awk 'BEGIN{IGNORECASE=1}
  {
    if (match($0, /([0-9]+(\.[0-9]+)?)\s*([KMGTPE]?)/, a)) {
      v = a[1] + 0
      u = toupper(a[3])
      mult = 1
      if (u == "K") mult = 1024
      else if (u == "M") mult = 1024^2
      else if (u == "G") mult = 1024^3
      else if (u == "T") mult = 1024^4
      else if (u == "P") mult = 1024^5
      printf("%.0f", v * mult)
    } else if (match($0, /([0-9]+)/, b)) {
      printf("%s", b[1])
    } else {
      print 0
    }
  }' <<<"$s"
}

# --- Helpers Functions ---
# Returns human runtime string computed from start time
format_runtime() {
  if [ -z "${start_time:-}" ]; then
    echo "0h:0m:0s"
    return
  fi
  local secs
  secs=$(( $(date +%s) - start_time ))
  printf '%dh:%dm:%ds' $((secs/3600)) $((secs%3600/60)) $((secs%60))
}
now_s() { date +%s; }
elapsed_since() { local _s="$1"; echo $(( $(now_s) - _s )); }

# --- Helpers Functions ---
# Centralized wrapper around the Unraid notify command to ensure consistent
notify_send() {
  local level="$1"; shift
  local subject="$1"; shift
  local detail="$1"; shift
  local body="$1"; shift || true
  /usr/local/emhttp/webGui/scripts/notify -i "$level" -b -s "$subject" -d "$detail" -m "$body"
  local nrc=$?
  if [ $nrc -ne 0 ]; then
    log "Notification command failed with exit code $nrc for subject: $subject"
  fi
  return $nrc
}

# --- Helpers Functions ---
# Map notification semantic to chosen emoji buttons
notif_emoji() {
  case "${1:-ok}" in
    ok) printf '🟢' ;;
    fail) printf '🔴' ;;
    nospace) printf '🔵' ;;
    *) printf '🔵' ;;
  esac
}

# --- Helpers Functions ---
# Classify SSH stderr into a concise reason for failure (password/host key/etc)
classify_ssh_error() {
  local stderr="$1"
  # Normalize line endings and lowercase copy for pattern matching while preserving original for detail
  local lower
  lower=$(printf '%s' "$stderr" | tr '[:upper:]' '[:lower:]')
  if printf '%s' "$lower" | grep -q 'permission denied'; then
    echo 'Permission denied (auth failed)'
  elif printf '%s' "$lower" | grep -q 'host key verification failed'; then
    echo 'Host key verification failed'
  elif printf '%s' "$lower" | grep -q 'authenticity of host'; then
    echo 'Host key unknown (needs trust confirmation)'
  elif printf '%s' "$lower" | grep -q 'remote host identification has changed'; then
    echo 'Host key changed (possible MITM)'
  elif printf '%s' "$lower" | grep -q 'connection refused'; then
    echo 'Connection refused (SSH service down)'
  elif printf '%s' "$lower" | grep -q 'no route to host'; then
    echo 'No route to host (network unreachable)'
  elif printf '%s' "$lower" | grep -q 'connection timed out'; then
    echo 'Connection timed out'
  elif printf '%s' "$lower" | grep -q 'could not resolve hostname'; then
    echo 'Hostname resolution failed'
  elif printf '%s' "$lower" | grep -q 'too many authentication failures'; then
    echo 'Too many authentication failures'
  elif printf '%s' "$lower" | grep -q 'handshake failed'; then
    echo 'SSH handshake failed'
  else
    echo 'SSH connection/auth failure'
  fi
}

# --- Main Functions ---
# Aggregates space requirements for multiple labels that may target the same remote destination
aggregate_preflight_check() {
  declare -A src_by_device
  declare -A remote_used
  declare -A remote_avail
  declare -A device_mount
  local min_buffer=$((1024 * 1024 * 1024))
  # Ensure manifests if metadata mode
  ensure_manifests_for_labels || true
  for i in "${!LABELS_ARRAY[@]}"; do
    local label=${LABELS_ARRAY[i]}
    local src=${SRCS_ARRAY[i]}
    local dest=${DESTS_ARRAY[i]}

    local src_bytes=0
    if src_bytes=$(du -sb "$src" 2>/dev/null | cut -f1); then
      :
    else
      local src_kb
      src_kb=$(du -s "$src" 2>/dev/null | cut -f1 || echo 0)
      src_bytes=$((src_kb * 1024))
    fi

    local estimated_changed=0
    if [ "$PREFLIGHT_MODE" = "metadata" ]; then
      estimated_changed=$(manifest_diff_bytes "$label" "$src" 2>/dev/null || echo 0)
    elif [ "$PREFLIGHT_MODE" = "estimate" ]; then
      local tmp_est
      tmp_est=$(mktemp /tmp/rsync_est.XXXXXX)
      if command -v stdbuf >/dev/null 2>&1; then
        est_cmd=(stdbuf -oL rsync "${RSYNC_DEFAULT_ARGS[@]:-}" --itemize-changes --stats --dry-run --delete "${src}/" "$REMOTE:$dest")
      else
        est_cmd=(rsync "${RSYNC_DEFAULT_ARGS[@]:-}" --itemize-changes --stats --dry-run --delete "${src}/" "$REMOTE:$dest")
      fi
      ( "${est_cmd[@]}" 2>&1 | tee "$tmp_est" ) >/dev/null 2>&1 || true
      estimated_changed=$(grep -i 'Total transferred file size' "$tmp_est" | tail -n1 | awk -F: '{gsub(/[^0-9]/,"",$2); print $2}' || echo 0)
      rm -f "$tmp_est" 2>/dev/null || true
    else
      estimated_changed=$src_bytes
    fi
    # Populate per-label changed bytes array
    estimated_changed_bytes["$label"]=$estimated_changed

    local df_out
    df_out=""
    local df_try=0
    while [ $df_try -lt ${DF_RETRY_COUNT:-3} ]; do
      df_out=$(ssh -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" -p "$SSH_PORT" "$REMOTE" df -P -B1 "$dest" 2>/dev/null | awk 'NR==2{print $1"|"$3"|"$4"|"$6}' || true)
      if [ -n "$df_out" ]; then
        break
      fi
      df_try=$((df_try+1))
      sleep ${DF_RETRY_SLEEP:-2}
    done
    if [ -z "$df_out" ]; then
      log "Aggregate preflight: failed to query remote df for $dest after ${df_try} tries"
      syslog err "Aggregate preflight failed: could not query remote df for $dest"
      echo "Failed to query remote disk usage for $dest" >&2
      return "${default_fail_code:-2}"
    fi
    local device used avail mountp
    device=$(printf '%s' "$df_out" | cut -d'|' -f1)
    used=$(printf '%s' "$df_out" | cut -d'|' -f2)
    avail=$(printf '%s' "$df_out" | cut -d'|' -f3)
    mountp=$(printf '%s' "$df_out" | cut -d'|' -f4)

    if ! [[ "$avail" =~ ^[0-9]+$ ]]; then avail=0; fi

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
    local needed=$src_sum

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

    local human_src_sum human_needed human_avail human_buffer
    human_src_sum=$(bytes_human "$src_sum")
    human_needed=$(bytes_human "$needed")
    human_avail=$(bytes_human "$avail")
    human_buffer=$(bytes_human "$safety_buffer")
    log "Aggregate preflight for device $device mount $mountp: est_change=$human_src_sum avail=$human_avail buffer=$human_buffer"

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

# --- Main Functions ---
# Parse an rsync --stats block captured in a raw rsync log file
parse_rsync_stats() {
  local file="$1"
  local label="$2"
  local num_files_transferred=0
  local total_file_size=0
  local total_transferred_size=0
  local total_bytes_sent=0
  local deletes=0

  total_file_size_raw=$(grep -i 'Total file size' "$file" | tail -n1 | sed -E 's/^[^:]*:[[:space:]]*//')
  total_file_size=$(human_to_bytes "$total_file_size_raw")
  total_transferred_raw=$(grep -i 'Total transferred file size' "$file" | tail -n1 | sed -E 's/^[^:]*:[[:space:]]*//')
  total_transferred_size=$(human_to_bytes "$total_transferred_raw")
  total_bytes_sent_raw=$(grep -i 'Total bytes sent' "$file" | tail -n1 | sed -E 's/^[^:]*:[[:space:]]*//')
  total_bytes_sent=$(human_to_bytes "$total_bytes_sent_raw")

  num_files_transferred=$(grep -i -E 'Number of (regular )?files transferred' "$file" | tail -n1 | sed -E 's/^[^:]*:[[:space:]]*([0-9,]+).*/\1/' | tr -d ',' )
  if [ -z "$num_files_transferred" ]; then
    line=$(grep -i '^Number of files:' "$file" | tail -n1 || true)
    if [ -n "$line" ]; then
      if echo "$line" | grep -qi 'reg:'; then
        num_files_transferred=$(echo "$line" | sed -E 's/.*reg:[[:space:]]*([0-9,]+).*/\1/' | tr -d ',')
      else
        num_files_transferred=$(echo "$line" | sed -E 's/^[^:]*:[[:space:]]*([0-9,]+).*/\1/' | tr -d ',')
      fi
    fi
  fi

  deletes=$(grep -i 'Number of deleted files' "$file" | tail -n1 | sed -E 's/^[^:]*:[[:space:]]*([0-9,]+).*/\1/' | tr -d ',' )
  if [ -z "$deletes" ]; then
    deletes=$(grep -c -E '^[[:space:]]*deleting ' "$file" 2>/dev/null || echo 0)
  fi

  num_files_transferred=${num_files_transferred:-0}
  total_file_size=${total_file_size:-0}
  total_transferred_size=${total_transferred_size:-0}
  total_bytes_sent=${total_bytes_sent:-0}
  deletes=${deletes:-0}

  local human_total human_transferred human_sent
  human_total=$(bytes_human "$total_file_size")
  human_transferred=$(bytes_human "$total_transferred_size")
  human_sent=$(bytes_human "$total_bytes_sent")

  rsync_total_bytes["$label"]="$total_file_size"
  rsync_transferred_bytes["$label"]="$total_transferred_size"
  rsync_files["$label"]="$num_files_transferred"
  rsync_deletes["$label"]="$deletes"
  rsync_bytes_sent["$label"]="$total_bytes_sent"

  if [ "$total_transferred_size" -gt 0 ] || [ "$num_files_transferred" -gt 0 ] || [ "$deletes" -gt 0 ]; then
    printf '%s: %s transferred, files %s, del %s, sent %s' "$label" "$human_transferred" "$num_files_transferred" "$deletes" "$human_sent"
  else
    printf '%s: no stats' "$label"
  fi
}

# --- Helpers Functions ---
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
    255) echo "SSH connection/auth failure" ;;
    *) echo "Unknown rsync exit code $code" ;;
  esac
}

# --- Helpers Functions ---
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

# --- Main Functions ---
# Create a compact manifest for `src` containing lines of the form:
write_manifest() {
  local label="$1"
  local src="$2"
  local dest="$LOG_FILE_SUBDIR/manifests"
  mkdir -p "$dest" 2>/dev/null || true
  chown "$LOG_USER" "$dest" 2>/dev/null || true
  chmod "$LOG_DIR_MODE" "$dest" 2>/dev/null || true
  local out
  out="$dest/${label// /_}_manifest_$(date +%Y%m%d_%H%M%S).txt"
  (cd "$src" && find . -type f -printf '%P\t%s\t%T@\n') > "$out" 2>/dev/null || true
  if [ -f "$out" ]; then
    chown "$LOG_USER" "$out" 2>/dev/null || true
    chmod "$LOG_FILE_MODE" "$out" 2>/dev/null || true
    log "Wrote manifest for $label: $out"
  else
    log "Warning: manifest write failed for $label (attempted $out)"
  fi
  mapfile -t mlist < <(find "$dest" -maxdepth 1 -type f -name "${label// /_}_manifest_*.txt" -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{print $2}' || true)
  if [ "${#mlist[@]}" -gt "$MAX_MANIFEST" ]; then
    for ((i=MAX_MANIFEST;i<${#mlist[@]};i++)); do
      rm -f "${mlist[$i]}" 2>/dev/null || true
    done
  fi
}

# --- Main Functions ---
# Compare the current set of files under `src` to the latest stored manifest
manifest_diff_bytes() {
  local label="$1"
  local src="$2"
  local manifest_file
  manifest_file=$(find "$LOG_FILE_SUBDIR/manifests" -maxdepth 1 -type f -name "${label// /_}_manifest_*.txt" -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{print $2}' || true)
  if [ -z "$manifest_file" ] || [ ! -f "$manifest_file" ]; then
    du -sb "$src" 2>/dev/null | cut -f1 || echo 0
    return 0
  fi
  declare -A man
  while IFS=$'\t' read -r path size; do
    man["$path"]=$size
  done < <(awk -F'\t' '{print $1"\t"$2}' "$manifest_file")

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

# --- Main Functions ---
# For metadata preflight mode, ensure at least one manifest exists for each configured label
ensure_manifests_for_labels() {
  if [ "${PREFLIGHT_MODE:-}" != "metadata" ]; then
    return 0
  fi
  local dest="$LOG_FILE_SUBDIR/manifests"
  mkdir -p "$dest" 2>/dev/null || true
  for idx in "${!LABELS_ARRAY[@]}"; do
    label=${LABELS_ARRAY[$idx]}
    safe_label=${label// /_}
    latest=$(find "$dest" -maxdepth 1 -type f -name "${safe_label}_manifest_*.txt" -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{print $2}' || true)
    if [ -z "$latest" ] || [ ! -f "$latest" ]; then
      log "No manifest found for $label; creating baseline manifest"
      write_manifest "$label" "${SRCS_ARRAY[$idx]}"
    else
      log "Found existing manifest for $label: $latest"
    fi
  done
}

# --- Main Functions ---
# Rsync wrapper to captures raw output for diagnostics, parses --stats, and retry logic
run_rsync() {
  local src="$1"
  local dest="$2"
  shift 2
  local label="${!#}"
  local opts=()
  if [ "$#" -gt 1 ]; then
    opts=("${@:1:$#-1}")
  fi

  log "Initialize backup ($label --> $DEST_NAS) == $(date)"
  local -a rsync_args=("${RSYNC_DEFAULT_ARGS[@]:-}" "--partial-dir=${RSYNC_PARTIAL_DIR}")
  rsync_args+=("${DEFAULT_EXCLUDES[@]:-}")
  if [ "$DRY_RUN" = true ]; then
    rsync_args+=("--dry-run")
  fi
  if [ "${#opts[@]}" -ne 0 ]; then
    rsync_args+=("${opts[@]}")
  fi

  set +e
    local attempt=1
    local last_status=0
    local tmp_rslog
    tmp_rslog=$(mktemp /tmp/rsync_raw.XXXXXX)

    while :; do
      log "RSYNC attempt $attempt/$MAX_RETRIES for $label"

    if command -v stdbuf >/dev/null 2>&1; then
      rsync_bin=(stdbuf -oL rsync)
    else
      rsync_bin=(rsync)
    fi

    # Build a per-attempt copy of rsync args so retries don't accumulate
    local cur_rsync_args=("${rsync_args[@]:-}")
    if [ "$ENABLE_SNAPSHOTS" = true ]; then
      safe_label=${label// /_}
      latest_link="$SNAPSHOT_ROOT/$safe_label/latest"
      cur_rsync_args+=("--link-dest=$latest_link")
    fi

    rsync_cmd=("${rsync_bin[@]}" "${cur_rsync_args[@]}" "$src/" "$REMOTE:$dest")

    if [ "$USE_IONICE" = true ] && command -v ionice >/dev/null 2>&1; then
      exec_cmd=(ionice -c2 -n7 nice -n 10 "${rsync_cmd[@]}")
    else
      exec_cmd=("${rsync_cmd[@]}")
    fi

    # Log the exact command for debugging
    log "Running: $(printf '%q ' "${exec_cmd[@]}")"

    if [ "$RSYNC_STREAM_TIMESTAMPED_LOG" = true ]; then
      ( "${exec_cmd[@]}" 2>&1 | tee "$tmp_rslog" ) | while IFS= read -r line; do
        printf '%s : %s\n' "$(date '+%Y/%m/%d %T')" "$line"
      done | tee -a "$LOG_FILE"
      last_status=${PIPESTATUS[0]}
    else
      ( "${exec_cmd[@]}" 2>&1 | tee "$tmp_rslog" ) >> "$LOG_FILE"
      last_status=${PIPESTATUS[0]}
    fi

    if [ -f "$tmp_rslog" ]; then
      # Parse stats to populate arrays
      parse_rsync_stats "$tmp_rslog" "$label" >/dev/null 2>&1 || true
      ts=$(date +%Y%m%d_%H%M%S)
      safe_label=${label// /_}
      saved_copy="$PRESERVED_RAW_LOG_DIR/rsync_raw_${safe_label}_${ts}"
      if [ "$last_status" -ne 0 ]; then
        saved_copy+="_fail.log"
        rsync_raw_failed["$label"]="$saved_copy"
      else
        saved_copy+="_success.log"
      fi
      cp "$tmp_rslog" "$saved_copy" 2>/dev/null || true
      chown "$LOG_USER" "$saved_copy" 2>/dev/null || true
      chmod "$LOG_FILE_MODE" "$saved_copy" 2>/dev/null || true
      rm -f "$tmp_rslog"
    else
      :
    fi

    if [ "$last_status" -eq 0 ]; then
      if [ "$ENABLE_SNAPSHOTS" = true ]; then
        safe_label=${label// /_}
        now=$(date +%Y%m%d_%H%M%S)
        snap_dest="$SNAPSHOT_ROOT/$safe_label/$now"
        if [ "$DRY_RUN" = false ]; then
          ssh -p "$SSH_PORT" "$REMOTE" "mkdir -p '$snap_dest'" 2>/dev/null || true
        else
          log "Dry-run: would create remote snapshot dir $snap_dest"
        fi
        if [ "$DRY_RUN" = false ]; then
          write_manifest "$label" "$src"
        else
          log "Dry-run: skipping manifest write for $label"
        fi
      fi
      set -e
      return 0
    fi
    # Capture SSH/auth style failures distinctly (rsync commonly returns 255)
    if [ "$last_status" -eq 255 ]; then
      # Extract a probable reason line
      local reason
      reason=$(grep -Ei 'ssh:|permission denied|host key|connection refused|no route to host|timeout' "$tmp_rslog" | tail -n1 || true)
      rsync_ssh_fail["$label"]=1
      rsync_ssh_fail_reason["$label"]=${reason:-"SSH failure"}
    fi

    local should_retry=0
    if [ -z "${RETRY_ON_CODES:-}" ]; then
      should_retry=1
    else
      for code in $RETRY_ON_CODES; do
        if [ "$last_status" -eq "$code" ]; then
          should_retry=1
          break
        fi
      done
    fi

    if [ "$should_retry" -eq 0 ] || [ "$attempt" -ge "${MAX_RETRIES}" ]; then
      log "rsync final failure for $label with exit=$last_status after attempt $attempt"
      syslog err "rsync final failure: $label exit=$last_status after attempt $attempt"
      log "Recent rsync output (tail excerpt):"
      tail -n 100 "$LOG_FILE" | sed -n '1,200p' | tee -a "$LOG_FILE"
      set -e
      return "$last_status"
    fi

    if [ "$ENABLE_EXPONENTIAL_BACKOFF" = true ]; then
      backoff=$(( RETRY_BACKOFF * (2 ** (attempt - 1)) ))
      if [ "$backoff" -gt "$MAX_BACKOFF" ]; then
        backoff=$MAX_BACKOFF
      fi
      jitter=$(( RANDOM % ( (backoff / 2) + 1 ) ))
      sleep_sec=$(( backoff + jitter ))
    else
      sleep_sec=$RETRY_BACKOFF
    fi

    log "rsync returned $last_status for $label; will retry in ${sleep_sec}s (attempt $attempt/$MAX_RETRIES)"
    if [ "$ENABLE_PER_ATTEMPT_NOTIFY" = true ]; then
      desc=$(rsync_exit_description "$last_status")
      excerpt=""
      if [ -f "$tmp_rslog" ]; then
        excerpt=$(extract_rsync_errors "$tmp_rslog" ${NOTIF_EXCERPT_LINES:-8} 2>/dev/null || true)
      fi
      runtime_now=$(format_runtime)
      body="Label: $label\nAttempt: ${attempt}/${MAX_RETRIES}\nLast exit: ${last_status} -> ${desc}\nBackoff: ${sleep_sec}s\n\nExcerpt:\n${excerpt}\n\nRuntime: ${runtime_now}\nSee log: $LOG_FILE"
      notify_send warning "Remote Backup - RETRY" "$label: retrying (attempt $((attempt+1))/$MAX_RETRIES) in ${sleep_sec}s" "$body"
    fi

    sleep "$sleep_sec"
    attempt=$((attempt + 1))
  done
  set -e
  return "$last_status"
}

# --- Main Functions ---
# Unified label backup (snapshot optional) with extra exclude
run_label_backup() {
  local label="$1" src="$2" dest="$3" extra_exclude="$4"
  local exclude_arg=()
  if [ -n "$extra_exclude" ]; then
    exclude_arg=("--exclude=$extra_exclude")
  fi
  if [ "$ENABLE_SNAPSHOTS" = true ]; then
    local now
    now=$(date '+%Y%m%d_%H%M%S')
    local safe_label=${label// /_}
    local snapdir="$SNAPSHOT_ROOT/$safe_label/$now"
    if [ "$DRY_RUN" = false ]; then
      ssh_run "mkdir -p '$snapdir'" 2>/dev/null || true
    else
      log "Dry-run: would create remote snapshot dir $snapdir"
    fi
    run_rsync "$src" "$snapdir" "${exclude_arg[@]}" "$label"
    rsync_results[$label]=$?
    log "Result: $label rsync exit=${rsync_results[$label]}"
    if [ "${rsync_results[$label]}" -eq 0 ] && [ "$DRY_RUN" = false ]; then
      ssh_run "ln -snf '$snapdir' '$SNAPSHOT_ROOT/$safe_label/latest'"
      ssh_run "ls -1dt '$SNAPSHOT_ROOT/$safe_label'/*/ 2>/dev/null | tail -n +$((SNAPSHOT_KEEP+1)) | xargs -r rm -rf --" || true
    fi
  else
    run_rsync "$src" "$dest" "${exclude_arg[@]}" "$label"
    rsync_results[$label]=$?
    log "Result: $label rsync exit=${rsync_results[$label]}"
  fi
  if [ "${rsync_results[$label]}" -ne 0 ]; then
    failed_labels+=("$label")
  fi
}

# --- Main Functions ---
# Compose final notification (success or failure) and set COMPOSE_* variables
compose_notification() {
  local status="$1" # 0 success, 1 failure
  local runtime_now
  runtime_now=$(format_runtime)
  local esub level detail body

  if [ "$status" -ne 0 ]; then
    esub=$(notif_emoji fail)
    level=alert
    local failed_summary="" notify_detail=""
    local ssh_fail_section=""
    local ssh_reason_summary=""
    declare -A ssh_reason_counts
    for lbl in "${failed_labels[@]}"; do
      local code desc transferred total human_trans human_total raw
      code=${rsync_results[$lbl]:-${DEFAULT_FAIL_CODE:-50}}
      desc=$(rsync_exit_description "$code")
      transferred=${rsync_transferred_bytes[$lbl]:-0}
      total=${rsync_total_bytes[$lbl]:-0}
      human_trans=$(bytes_human "$transferred")
      human_total=$(bytes_human "$total")
      failed_summary+="$lbl: exit=${code} (${desc}); transferred ${human_trans} of ${human_total}; "
      notify_detail+="$lbl: exit=${code} -> ${desc}\nTransferred: ${human_trans} of ${human_total}\n"
      raw=${rsync_raw_failed[$lbl]:-}
      if [ -n "$raw" ] && [ -f "$raw" ]; then
        notify_detail+=$'--- recent rsync output ---\n'
        notify_detail+="$(extract_rsync_errors "$raw" ${NOTIF_EXCERPT_LINES:-8})"$'\n\n'
      fi
      if [ "${rsync_ssh_fail[$lbl]:-0}" -eq 1 ]; then
        ssh_fail_section+="$lbl: ${rsync_ssh_fail_reason[$lbl]:-SSH failure}\n"
        # Increment aggregated reason count
        rkey="${rsync_ssh_fail_reason[$lbl]:-SSH failure}"
        ssh_reason_counts["$rkey"]=$(( ${ssh_reason_counts["$rkey"]:-0} + 1 ))
      fi
    done
    if [ -n "$ssh_fail_section" ]; then
      # Build summary line of counts per distinct reason
      for rkey in "${!ssh_reason_counts[@]}"; do
        ssh_reason_summary+="$rkey=${ssh_reason_counts[$rkey]} "
      done
      ssh_reason_summary=${ssh_reason_summary%% }
      notify_detail+=$'--- SSH Failure Summary ---\n'
      notify_detail+="$ssh_reason_summary"$'\n\n'
      notify_detail+=$'--- SSH Failures Detected ---\n'
      notify_detail+="$ssh_fail_section"$'\n'
    fi
    notify_detail+="Runtime: ${runtime_now}\nSee log: $LOG_FILE"
    detail="${esub} Backup FAIL: $failed_summary"
    body="$notify_detail"
  else
    esub=$(notif_emoji ok)
    level=normal
    local condensed_parts=() detailed_body
    detailed_body=$'Runtime: '"${runtime_now}"$'\n'
    for lbl in "${LABELS_ARRAY[@]}"; do
      local transferred files deletes sent total est human_transferred human_total human_est human_sent percent_total
      transferred=${rsync_transferred_bytes[$lbl]:-0}
      files=${rsync_files[$lbl]:-0}
      deletes=${rsync_deletes[$lbl]:-0}
      sent=${rsync_bytes_sent[$lbl]:-0}
      total=${rsync_total_bytes[$lbl]:-0}
      est=${estimated_changed_bytes[$lbl]:-0}
      human_transferred=$(bytes_human "$transferred")
      human_total=$(bytes_human "$total")
      human_est=$(bytes_human "$est")
      human_sent=$(bytes_human "$sent")
      percent_total=0
      if [ "$total" -gt 0 ] && [ "$transferred" -gt 0 ]; then
        percent_total=$(awk -v t="$total" -v tr="$transferred" 'BEGIN{printf "%.1f", (tr/t)*100}')
      fi
      if [ "$est" -gt 0 ]; then
        detailed_body+="$lbl: $human_total total, $human_est est_changed, transferred $human_transferred (${percent_total}%), files $files, deleted $deletes, sent $human_sent"$'\n'
      else
        detailed_body+="$lbl: $human_total total, no changes, transferred $human_transferred (${percent_total}%), files $files, deleted $deletes, sent $human_sent"$'\n'
      fi
      condensed_parts+=("$lbl: $human_transferred (${percent_total}%)")
    done
    local max_labels_in_d condensed_show extra_count condensed_line idx
    max_labels_in_d=${NOTIF_CONDENSED_MAX_LABELS:-3}
    condensed_show=()
    idx=0
    for part in "${condensed_parts[@]}"; do
      if [ "$idx" -ge "$max_labels_in_d" ]; then
        break
      fi
      condensed_show+=("$part")
      idx=$((idx+1))
    done
    extra_count=$(( ${#condensed_parts[@]} - ${#condensed_show[@]} ))
    condensed_line=$(IFS=$'\n'; printf '%s' "${condensed_show[*]}")
    if [ "$extra_count" -gt 0 ]; then
      condensed_line+=" | +${extra_count} more"
    fi

    # Space summary per label (simplified)
    for idx in "${!LABELS_ARRAY[@]}"; do
      local lbl=${LABELS_ARRAY[$idx]} dest=${DESTS_ARRAY[$idx]} req_bytes req_human df_avail free_bytes free_human req_pct_of_free
      req_bytes=${rsync_transferred_bytes[$lbl]:-0}
      req_human=$(bytes_human "$req_bytes")
      df_avail=$(ssh -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" -p "$SSH_PORT" "$REMOTE" df -P -B1 "$dest" 2>/dev/null | awk 'NR==2{print $4}' || true)
      [[ ! "$df_avail" =~ ^[0-9]+$ ]] && df_avail=0
      free_bytes=$df_avail
      free_human=$(bytes_human "$free_bytes")
      req_pct_of_free=0
      if [ "$free_bytes" -gt 0 ] && [ "$req_bytes" -gt 0 ]; then
        req_pct_of_free=$(awk -v r="$req_bytes" -v f="$free_bytes" 'BEGIN{printf "%d", (r*100)/f}')
      fi
      detailed_body+="Space ($lbl): Free = $free_human Required = $req_human"$'\n'
      detailed_body+="Required vs Free ($lbl): $req_pct_of_free%"$'\n'
    done
    detail="${esub} Backup OK"$'\n'"${condensed_line}"
    body="$detailed_body"
  fi

  COMPOSE_LEVEL="$level"
  COMPOSE_DETAIL="$detail"
  COMPOSE_BODY="$body"
  return 0
}

# --- Main Functions ---
# Prune old log files to retention aligned with MAX_LOGS
prune_old_logs() {
  local keep="$MAX_LOGS"
  local base_dir="$LOG_FILE_SUBDIR"
  mapfile -t logs < <(find "$base_dir" -maxdepth 1 -type f -name 'remote_backup_*.log' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{print $2}' || true)
  if [ "${#logs[@]}" -gt "$keep" ]; then
    for ((i=keep;i<${#logs[@]};i++)); do
      rm -f "${logs[$i]}" 2>/dev/null || true
    done
    log "Pruned dated logs to $keep (was ${#logs[@]})"
  fi

  local raw_dir="$PRESERVED_RAW_LOG_DIR"
  for lbl in "${LABELS_ARRAY[@]}"; do
    local safe_label=${lbl// /_}
    mapfile -t rlist < <(find "$raw_dir" -maxdepth 1 -type f -name "rsync_raw_${safe_label}_*.log" -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{print $2}' || true)
    if [ "${#rlist[@]}" -gt "$keep" ]; then
      for ((i=keep;i<${#rlist[@]};i++)); do
        rm -f "${rlist[$i]}" 2>/dev/null || true
      done
      log "Pruned rsync_raw logs for $lbl to $keep (was ${#rlist[@]})"
    fi
  done

  local nadir="$PRESERVED_RAW_LOG_DIR/notify_artifacts"
  mapfile -t df_files < <(find "$nadir" -maxdepth 1 -type f -name 'remote_df_*.txt' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{print $2}' || true)
  if [ "${#df_files[@]}" -gt "$keep" ]; then
    for ((i=keep;i<${#df_files[@]};i++)); do
      rm -f "${df_files[$i]}" 2>/dev/null || true
    done
  fi
  mapfile -t snap_files < <(find "$nadir" -maxdepth 1 -type f -name 'snapshots_*.txt' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{print $2}' || true)
  if [ "${#snap_files[@]}" -gt "$keep" ]; then
    for ((i=keep;i<${#snap_files[@]};i++)); do
      rm -f "${snap_files[$i]}" 2>/dev/null || true
    done
  fi
}

# --- Main Functions ---
# Gather small read-only remote artifacts (df, snapshot listings) used by notifications. 
collect_notification_artifacts() {
  local outdir="$PRESERVED_RAW_LOG_DIR/notify_artifacts"
  mkdir -p "$outdir" 2>/dev/null || true
  chown "$LOG_USER" "$outdir" 2>/dev/null || true
  chmod "$LOG_DIR_MODE" "$outdir" 2>/dev/null || true
  local ts
  ts=$(date +%Y%m%d_%H%M%S)
  notify_df_file="$outdir/remote_df_${ts}.txt"
  notify_snap_file="$outdir/snapshots_${ts}.txt"

  if ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$SSH_PORT" "$REMOTE" "df -h" > "$notify_df_file" 2>/dev/null; then
    :
  else
    echo "(remote df unavailable)" > "$notify_df_file"
  fi
  chown "$LOG_USER" "$notify_df_file" 2>/dev/null || true
  chmod "$LOG_FILE_MODE" "$notify_df_file" 2>/dev/null || true

  : > "$notify_snap_file"
  for lbl in "${LABELS_ARRAY[@]}"; do
    safe_label=${lbl// /_}
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$SSH_PORT" "$REMOTE" "readlink -f '$SNAPSHOT_ROOT/$safe_label/latest' 2>/dev/null || echo '(no latest)'" >> "$notify_snap_file" 2>/dev/null; then
      :
    else
      echo "${lbl}: (snapshot info unavailable)" >> "$notify_snap_file"
    fi
  done
  chown "$LOG_USER" "$notify_snap_file" 2>/dev/null || true
  chmod "$LOG_FILE_MODE" "$notify_snap_file" 2>/dev/null || true

  return 0
}

# --- Main Entry Point ---
# Main script logic
main() {
  # Record script start time
  start_time=$(date +%s)
  log "$SRC_NAS --> $DEST_NAS start: $(date)"

# Wake-on-LAN
if command -v etherwake >/dev/null 2>&1; then
  etherwake "$REMOTE_MAC" || true
  log "Sent Wake-on-LAN to $DEST_NAS (MAC: $REMOTE_MAC)"
elif command -v wakeonlan >/dev/null 2>&1; then
  wakeonlan "$REMOTE_MAC" || true
  log "Sent Wake-on-LAN via wakeonlan to $DEST_NAS (MAC: $REMOTE_MAC)"
else
  log "Wake-on-LAN tool not found (etherwake/wakeonlan). Skipping WOL for $DEST_NAS (MAC: $REMOTE_MAC)"
fi

## Wait loop for SSH readiness
start_wait_ts=$(now_s)
log "Waiting up to ${MAX_SSH_WAIT}s for $DEST_NAS SSH to become available..."
ssh_reachable=0
while :; do
  elapsed=$(elapsed_since "$start_wait_ts")
  if ssh_stderr=$(ssh -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" -p "$SSH_PORT" "$REMOTE" true 2>&1 >/dev/null); then
    remaining=$(( MAX_SSH_WAIT - elapsed ))
    (( remaining < 0 )) && remaining=0
    log "$DEST_NAS SSH is reachable after ${elapsed}s (timeout in ${remaining}s)"

    stab_start_ts=$(now_s)
    log "Waiting up to ${STABILIZE_WAIT}s for remote filesystem readiness..."
    while :; do
      stab_elapsed=$(elapsed_since "$stab_start_ts")
      if ssh -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" -p "$SSH_PORT" "$REMOTE" df -P -B1 / >/dev/null 2>&1; then
        log "Remote filesystem responded to df after ${stab_elapsed}s; proceeding"
        break
      fi
      if (( stab_elapsed >= STABILIZE_WAIT )); then
        log "Remote filesystem did not stabilize within ${STABILIZE_WAIT}s; proceeding anyway (df may fail)"
        break
      fi
      sleep "$STABILIZE_INTERVAL"
    done

    arr_start_ts=$(now_s)
    log "Waiting up to ${ARRAY_READY_WAIT}s for remote array (/mnt/user) readiness..."
    while :; do
      arr_elapsed=$(elapsed_since "$arr_start_ts")
      if ssh -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" -p "$SSH_PORT" "$REMOTE" '[ -d /mnt/user ] && { [ -d /mnt/user/media ] || [ -d /mnt/user/secure ]; }'; then
        log "Remote array appears online after ${arr_elapsed}s; proceeding to backup operations."
        break
      fi
      if (( arr_elapsed >= ARRAY_READY_WAIT )); then
        log "Remote array not confirmed online within ${ARRAY_READY_WAIT}s; proceeding anyway (rsync may encounter missing shares)."
        break
      fi
      sleep "$ARRAY_READY_INTERVAL"
    done
    ssh_reachable=1
    break
  fi
  if (( elapsed >= MAX_SSH_WAIT )); then
    log "Timeout waiting for SSH on $DEST_NAS after ${elapsed}s"
    break
  fi
  remaining=$(( MAX_SSH_WAIT - elapsed ))
  log "$DEST_NAS SSH not available yet; sleeping ${SSH_WAIT_INTERVAL}s (remaining ${remaining}s)"
  sleep "$SSH_WAIT_INTERVAL"
done
if [ "$ssh_reachable" -eq 0 ]; then
  log "SSH not reachable on $DEST_NAS after ${MAX_SSH_WAIT}s; aborting backup"
  syslog crit "Remote SSH unreachable on $DEST_NAS after ${MAX_SSH_WAIT}s; aborting"
  runtime_now=$(format_runtime)
  esub=$(notif_emoji fail)
  local reason=""
  if [ -n "${ssh_stderr:-}" ]; then
    reason=$(classify_ssh_error "$ssh_stderr")
  fi
  body="Waited ${MAX_SSH_WAIT}s for SSH on ${DEST_NAS} (host: ${REMOTE}).\n"
  if [ -n "$reason" ]; then
    body+="Reason: ${reason}\n\n"
  else
    body+=$'Reason: (generic unreachable)\n\n'
  fi
  if [ -n "${REMOTE_MAC:-}" ]; then
    body+="WOL MAC: ${REMOTE_MAC}\n"
  fi
  body+=$'Suggested checks:\n- Network connectivity and firewall\n- Remote host power state\n- SSH service status on remote\n\n'
  body+="Runtime: ${runtime_now}\nSee log: ${LOG_FILE}"
  notify_send alert "Remote Backup - SSH UNREACHABLE" "${esub} Remote ${DEST_NAS}: SSH unreachable; backup aborted" "$body"
  exit ${DEFAULT_FAIL_CODE:-50}
fi

## Per-label backup execution
declare -A rsync_results
failed_labels=()
declare -A rsync_total_bytes
declare -A rsync_transferred_bytes
declare -A rsync_files
declare -A rsync_deletes
declare -A rsync_bytes_sent
declare -A estimated_changed_bytes 
declare -A rsync_ssh_fail
declare -A rsync_ssh_fail_reason

agg_msg=""

# Ensure manifests exist for all labels
ensure_manifests_for_labels || true

if ! agg_msg=$(aggregate_preflight_check 2>&1); then
  log "Aggregate preflight failed: $agg_msg"
  runtime_now=$(format_runtime)
  body="$agg_msg\n\nRuntime: ${runtime_now}\nSee log: $LOG_FILE"
  notify_send alert "Remote Backup - NO SPACE" "Aggregate preflight failed: insufficient remote space" "$body"
  for lbl in "${LABELS_ARRAY[@]}"; do
    rsync_results["$lbl"]=2
    failed_labels+=("$lbl")
  done
else
  log "Aggregate preflight passed: proceeding with per-label rsyncs"
  for idx in "${!LABELS_ARRAY[@]}"; do
    lbl=${LABELS_ARRAY[$idx]}
    src=${SRCS_ARRAY[$idx]}
    dest=${DESTS_ARRAY[$idx]}
    extra_excl=${RSYNC_EXTRA_EXCLUDES[$idx]:-}
    # Preflight SSH accessibility (auth/path) for this destination to catch auth issues early
    preflight_stderr=""
    if ! preflight_stderr=$(ssh -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" -p "$SSH_PORT" "$REMOTE" "mkdir -p '$dest' && test -d '$dest'" 2>&1 >/dev/null); then
      local p_reason
      p_reason=$(classify_ssh_error "$preflight_stderr")
      log "Preflight SSH/path check failed for $lbl dest $dest (${p_reason})"
      failed_labels+=("$lbl")
      rsync_results["$lbl"]=255
      rsync_ssh_fail["$lbl"]=1
      rsync_ssh_fail_reason["$lbl"]="$p_reason"
      continue
    fi
    run_label_backup "$lbl" "$src" "$dest" "$extra_excl"
  done
fi

# Aggregate overall status: 0 OK, 1 failure
if [ "${#failed_labels[@]}" -eq 0 ]; then
  backup_status=0
else
  backup_status=1
fi

## Verification, notification and (optional) shutdown
collect_notification_artifacts || true
compose_notification "$backup_status"
log "$SRC_NAS --> $DEST_NAS complete == $(format_runtime)"
notify_send "$COMPOSE_LEVEL" "Remote Backup - $( [ "$backup_status" -eq 0 ] && echo OK || echo FAIL)" "$COMPOSE_DETAIL" "$COMPOSE_BODY"
if [ "$backup_status" -eq 0 ]; then
  if [ "$DRY_RUN" = false ]; then
    log "Shutting down remote after successful backup"
    if ! ssh -p "$SSH_PORT" "$REMOTE" "df --type=xfs -h && powerdown" 2>/dev/null; then
      log "Remote shutdown command failed"
      syslog err "Remote shutdown command failed on $REMOTE"
    fi
    sleep 5s
  else
    log "Dry-run: skipping remote powerdown after success"
  fi
else
  if [ "$SHUTDOWN_ON_FAILURE" = true ]; then
    log "Shutdown_on_failure=true; requesting remote powerdown despite failures"
    if ! ssh -p "$SSH_PORT" "$REMOTE" "df --type=xfs -h && powerdown" 2>/dev/null; then
      log "Remote shutdown command failed"
      syslog err "Remote shutdown command failed on $REMOTE"
    fi
  else
    log "Not shutting down remote because SHUTDOWN_ON_FAILURE=false"
  fi
fi
prune_old_logs || true
exit 0
}

# Entry Point
main "$@"