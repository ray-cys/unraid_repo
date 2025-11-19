#!/bin/bash
set -euo pipefail
LOCKFILE="/tmp/appdata_backup.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Another appdata_backup.sh run is active, exiting (lock: $LOCKFILE)"
  exit 1
fi

noParity=true
clearLog=false

# --------------------------------------------------------------------------------
# Configuration section
# Adjust the settings below to configure the backup behavior.

SRC_DIR="/mnt/cache/appdata"                              # Source directory
DEST_DIR="/mnt/user/node/cache"                           # Destination directory
SKIP_CONTAINERS=()                                        # Containers to skip (e.g. SKIP_CONTAINERS=("plex-media-server"))
MAX_BACKUPS=3                                             # Number of backups to keep   
MAX_LOGS=3                                                # Number of logs to keep 
PARALLEL_JOBS=${PARALLEL_JOBS-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)}            # Number of parallel compression jobs. Defaults to CPU cores. Lower to reduce IO.
if command -v pigz >/dev/null 2>&1; then                  # Use pigz (parallel gzip) when available for faster compression
  USE_PIGZ=1
else
  USE_PIGZ=0
fi
if command -v pv >/dev/null 2>&1; then
  PV_AVAILABLE=1
else
  PV_AVAILABLE=0
fi
SRC_DIR_NAME="$(basename "$SRC_DIR")"                      # Name of source dir for logging
DATETIME="$(date +%Y%m%d_%H%M%S)"                          # Timestamp for this run
LOG_FILE_SUBDIR="/mnt/cache/system/logs/${SRC_DIR_NAME}_logs" # Log file directory
LOG_FILE="$LOG_FILE_SUBDIR/$SRC_DIR_NAME-$DATETIME.log"    # Log file path
ERR_EXCERPT_LINES=${ERR_EXCERPT_LINES:-20}                 # Number of stderr lines to include in notification on failure
KEEP_PARTIAL=${KEEP_PARTIAL:-true}                         # Keep partial backups 
RETRIES=${RETRIES:-3}                                      # Number of attempts
RETRY_DELAY=${RETRY_DELAY:-5}                              # Delay between attempts (seconds)
TARBALL_PROGRESS_TO_LOG=${TARBALL_PROGRESS_TO_LOG:-true}   # Append tar/pv progress to the main logfile
LOW_SPACE_ACTION=${LOW_SPACE_ACTION:-abort}                # LOW_SPACE_ACTION: abort|warn|partial  (default: abort)
LOW_SPACE_MARGIN=${LOW_SPACE_MARGIN:-0}                    # Extra margin (bytes) to add to required space calculation
LOW_SPACE_FAIL_IF_UNDETERMINED=${LOW_SPACE_FAIL_IF_UNDETERMINED:-false}                                     # If df/du cannot determine size, fail when true, otherwise proceed with a warning
LOW_SPACE_IGNORE_ZERO_FS_TYPES=${LOW_SPACE_IGNORE_ZERO_FS_TYPES:-"fuse.rclone fuse.mergerfs fuse.unionfs"}  # Filesystem types whose zero-free-space df output should be treated as unknown/unlimited.
LOW_SPACE_ENABLE_STAT_FALLBACK=${LOW_SPACE_ENABLE_STAT_FALLBACK:-true}                                      # When true, attempt a stat(2)-based fallback if df reports 0 bytes free.
UTIL_WARN_THRESHOLD=${UTIL_WARN_THRESHOLD:-15}             # Warning threshold (percent)
UTIL_ALERT_THRESHOLD=${UTIL_ALERT_THRESHOLD:-5}            # Alert threshold (percent)
PIGZ_THREADS=${PIGZ_THREADS:-0}.                           # Pigz threads per compression job (0 lets pigz auto-detect). Set to 1..N to limit per-job threads
TAR_OPTIONS=()                                             # Extra tar options (array)
NOTIFY_TITLE="Docker Backup"                               # Notification title prefix
NOTIFY_LEVEL_ON_SUCCESS="normal"                           # Notification level on success: normal|warning|alert
NOTIFY_LEVEL_ON_FAILURE="alert"                            # Notification level on failure: normal|warning|alert
TMP_DIR=""                                                 # e.g., /tmp/docker_backup_tmp (default: inside the run backup dir if TMP_DIR empty)
KEEP_TEMP_ERR=${KEEP_TEMP_ERR:-false}                      # Keep per-container .err files after a successful run

# --------------------------------------------------------------------------------

# Ensure logs are group-writable and owned by nobody:users on Unraid
LOG_USER="${LOG_USER:-nobody}"
LOG_GROUP="${LOG_GROUP:-users}"
LOG_DIR_MODE="${LOG_DIR_MODE:-0775}"
LOG_FILE_MODE="${LOG_FILE_MODE:-0664}"
LOG_UMASK="${LOG_UMASK:-0002}"
umask "$LOG_UMASK"

# Ensure runtime log directory exists with correct ownership/permissions and pre-create log file
mkdir -p "$LOG_FILE_SUBDIR" 2>/dev/null || true
chown "$LOG_USER:$LOG_GROUP" "$LOG_FILE_SUBDIR" 2>/dev/null || true
chmod "$LOG_DIR_MODE" "$LOG_FILE_SUBDIR" 2>/dev/null || true
: > "$LOG_FILE"
chown "$LOG_USER:$LOG_GROUP" "$LOG_FILE" 2>/dev/null || true
chmod "$LOG_FILE_MODE" "$LOG_FILE" 2>/dev/null || true

# Check if a container/dir is in the skip list (exact match). Empty skip list -> skip none.
is_skipped() {
  local target="$1"
  local item
  [ "${#SKIP_CONTAINERS[@]}" -eq 0 ] && return 1
  for item in "${SKIP_CONTAINERS[@]}"; do
    [[ "$item" == "$target" ]] && return 0
  done
  return 1
}

# Report of backups (populated later)
backup_report=""

# Log messages to logfile and stdout
log() {
  local msg="$1"
  echo "$(date "+%Y/%m/%d %T") : $msg" | tee -a "$LOG_FILE"
}

# Log error messages to syslog (logger), logfile and stdout
log_error() {
  local msg="$1"
  logger -p err "ERROR: $msg"
  log "ERROR: $msg"
}

# Immediate notification for early abort scenarios
notify_abort() {
  local reason="$1"
  local detail="${2:-}"
  local subj="${NOTIFY_TITLE} - FAILED"
  local short="🔴 Backup aborted"
  local body="Reason: ${reason}"
  if [ -n "$detail" ]; then
    body+=$'\n'"$detail"
  fi
  /usr/local/emhttp/webGui/scripts/notify -i alert -b -s "$subj" -d "$short" -m "$body" || true
}

# Convert bytes to human-readable form using KB/MB/GB/TB labels (1024 base)
bytes_to_human() {
  local bytes=${1:-0}
  awk -v b="$bytes" 'BEGIN{
    u[0]="B"; u[1]="KB"; u[2]="MB"; u[3]="GB"; u[4]="TB"; u[5]="PB";
    i=0;
    while(b>=1024 && i<5){ b=b/1024; i++ }
    if(b>=100) printf("%.0f%s", b, u[i]); else printf("%.1f%s", b, u[i]);
  }'
}

# Record start time and announce start
start_time=$(date +%s)
log_msg="Docker $SRC_DIR_NAME backup start: $(date)"
log "$log_msg"

# Compression function (runs in background). Streams tar -> pv -> pigz/gzip -> out
compress_job() {
  local dname="$1"; shift
  local out="$1"; shift
  local efile="$1"; shift
  local sfile="$1"; shift || true
  local attempt=1
  local ok=0
  local dir_size=0
  dir_size=$(du -sb "${SRC_DIR}/${dname}" 2>/dev/null | awk '{print $1}' || echo 0)
  while [ $attempt -le $RETRIES ]; do
    log "[${dname}] compress attempt $attempt"
    if [ "$PV_AVAILABLE" -eq 1 ] && [ "$dir_size" -gt 0 ]; then
      if [ "$TARBALL_PROGRESS_TO_LOG" = "true" ]; then
        if ( set -o pipefail; \
             tar cPf - -C "${SRC_DIR}" "${dname}" "${TAR_OPTIONS[@]}" "${exclude_opts[@]}" 2>>"$efile" | \
             pv -s "$dir_size" 2> >(tee -a "$LOG_FILE" >>"$efile") | \
             ( if [ "$USE_PIGZ" -eq 1 ]; then \
                 if [ "$PIGZ_THREADS" -gt 0 ]; then pigz -p "$PIGZ_THREADS" -c; else pigz -p 0 -c; fi; \
               else \
                 gzip -c; \
               fi ) > "$out" ); then
          ok=1
          break
        else
          log "[${dname}] compress (pv) attempt $attempt failed (see $efile)"
        fi
      else
          if ( set -o pipefail; \
               tar cPf - -C "${SRC_DIR}" "${dname}" "${TAR_OPTIONS[@]}" "${exclude_opts[@]}" 2>>"$efile" | \
               pv -s "$dir_size" 2>>"$efile" | \
               ( if [ "$USE_PIGZ" -eq 1 ]; then \
                   if [ "$PIGZ_THREADS" -gt 0 ]; then pigz -p "$PIGZ_THREADS" -c; else pigz -p 0 -c; fi; \
                 else \
                   gzip -c; \
                 fi ) > "$out" ); then
          ok=1
          break
        else
          log "[${dname}] compress (pv) attempt $attempt failed (see $efile)"
        fi
      fi
    else
        if ( set -o pipefail; \
             tar cPf - -C "${SRC_DIR}" "${dname}" "${TAR_OPTIONS[@]}" "${exclude_opts[@]}" 2>>"$efile" | \
             ( if [ "$USE_PIGZ" -eq 1 ]; then \
                 if [ "$PIGZ_THREADS" -gt 0 ]; then pigz -p "$PIGZ_THREADS" -c; else pigz -p 0 -c; fi; \
               else \
                 gzip -c; \
               fi ) > "$out" ); then
        ok=1
        break
      else
        log "[${dname}] compress attempt $attempt failed (see $efile)"
      fi
    fi
    attempt=$((attempt+1))
    sleep $RETRY_DELAY
  done
  if [ $ok -eq 1 ]; then
    size_bytes=$(du -sb "$out" 2>/dev/null | awk '{print $1}' || echo 0)
      if ! [[ "$size_bytes" =~ ^[0-9]+$ ]] || [ "$size_bytes" -eq 0 ]; then
          kb=$(du -k "$out" 2>/dev/null | awk '{print $1}' || echo 0)
          if [[ "$kb" =~ ^[0-9]+$ ]] && [ "$kb" -gt 0 ]; then
            size_bytes=$((kb * 1024))
          else
            size_bytes=0
          fi
      fi
      if ! [[ "$size_bytes" =~ ^[0-9]+$ ]] || [ "$size_bytes" -eq 0 ]; then
          size_human="0B"
          log "[${dname}] compressed to $out (size unknown)"
          if [[ -n "${sfile:-}" ]]; then
            printf "%s: %s|%s\n" "$dname" "$size_human" "$size_bytes" >"$sfile"
          else
            printf "%s: %s|%s\n" "$dname" "$size_human" "$size_bytes"
          fi
      else
          size_human=$(bytes_to_human "$size_bytes")
          log "[${dname}] compressed to $out (${size_human} (${size_bytes} bytes))"
          if [[ -n "${sfile:-}" ]]; then
            printf "%s: %s|%s\n" "$dname" "$size_human" "$size_bytes" >"$sfile"
          else
            printf "%s: %s|%s\n" "$dname" "$size_human" "$size_bytes"
          fi
      fi
  else
      if [[ -n "${sfile:-}" ]]; then
        printf "%s: FAILED|0\n" "$dname" >"$sfile"
      else
        printf "%s: FAILED|0\n" "$dname"
      fi
      log_error "${dname} compression failed after ${RETRIES} attempts (see ${efile})"
  fi
}

# Compute subtotal of only the non-skipped directories to get a tighter upfront estimate
subtotal=0
subtotal_unknown=0
while IFS= read -r -d '' d; do
  name="$(basename "$d")"
  if is_skipped "$name"; then
    continue
  fi
  bytes=$(du -sb "$d" 2>/dev/null | awk '{print $1}' || echo 0)
  if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
    log "WARN: could not determine size of $d; value='$bytes'"
    subtotal_unknown=1
  else
    subtotal=$((subtotal + bytes))
  fi
done < <(find "$SRC_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

# Ensure destination directory exists before assessing free space; notify if missing and cannot be created
dest_dir_was_missing=0
if [ ! -d "$DEST_DIR" ]; then
  if mkdir -p "$DEST_DIR" 2>/dev/null; then
    dest_dir_was_missing=1
    log "Destination directory was missing; created: $DEST_DIR"
  else
    log_error "destination directory missing and cannot be created: $DEST_DIR"
    notify_abort "Destination directory missing" "Path: $DEST_DIR (mkdir failed)"
    exit 1
  fi
fi

dest_dir_free_bytes=$(df -B1 "$DEST_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
dest_dir_total_bytes=$(df -B1 "$DEST_DIR" 2>/dev/null | awk 'NR==2 {print $2}' || echo 0)
dest_dir_used_bytes=$(df -B1 "$DEST_DIR" 2>/dev/null | awk 'NR==2 {print $3}' || echo 0)
df_device=$(df -P "$DEST_DIR" 2>/dev/null | awk 'NR==2 {print $1}' || echo "")
fs_type=$(stat -f -c %T "$DEST_DIR" 2>/dev/null || echo "")

if ! [[ "$dest_dir_free_bytes" =~ ^[0-9]+$ ]]; then
  log "WARN: could not determine free space on destination ($DEST_DIR); value='$dest_dir_free_bytes'"
  dest_unknown=1
else
  dest_unknown=0
  # Fallback: if reported free space is 0, try stat-based calculation
  if [ "$dest_dir_free_bytes" -eq 0 ] && [ "$LOW_SPACE_ENABLE_STAT_FALLBACK" = "true" ]; then
    stat_vals=$(stat -f --format '%a %s' "$DEST_DIR" 2>/dev/null || echo "")
    stat_free=""
    if [[ "$stat_vals" =~ ^[0-9]+\ [0-9]+$ ]]; then
      stat_free=$(awk '{print $1 * $2}' <<< "$stat_vals")
    fi
    if [[ "$stat_free" =~ ^[0-9]+$ ]] && [ "$stat_free" -gt 0 ]; then
      log "INFO: df reported 0 free; stat fallback detected ${stat_free} bytes free on $DEST_DIR"
      dest_dir_free_bytes="$stat_free"
    fi
  fi
  # If still zero, and filesystem type matches ignore list, treat as unknown/unlimited
  if [ "$dest_dir_free_bytes" -eq 0 ]; then
    for _fst in $LOW_SPACE_IGNORE_ZERO_FS_TYPES; do
      if [ "$fs_type" = "$_fst" ]; then
        log "INFO: filesystem type '$fs_type' reports 0 free; treating as unknown/unlimited (skip strict low-space abort)"
        dest_unknown=1
        break
      fi
    done
  fi
fi

required=$((subtotal + LOW_SPACE_MARGIN))
if [ $subtotal_unknown -eq 1 ] || [ $dest_unknown -eq 1 ]; then
  if [ "${LOW_SPACE_FAIL_IF_UNDETERMINED}" = "true" ]; then
    log_error "unable to determine required/available sizes and LOW_SPACE_FAIL_IF_UNDETERMINED=true; aborting"
    notify_abort "Size determination failure" "Cannot determine required or free space (LOW_SPACE_FAIL_IF_UNDETERMINED=true)."
    exit 1
  else
    log "Proceeding despite unknown sizes (LOW_SPACE_FAIL_IF_UNDETERMINED=false)"
  fi
fi

if [ $dest_unknown -eq 0 ] && [ "$dest_dir_free_bytes" -lt "$required" ]; then
  case "$LOW_SPACE_ACTION" in
    abort)
      free_human=$(bytes_to_human "$dest_dir_free_bytes")
      req_human=$(bytes_to_human "$required")
      log_error "not enough free space on $DEST_DIR: available=${dest_dir_free_bytes} bytes, required=${required} bytes; aborting as LOW_SPACE_ACTION=abort"
      notify_abort "Low disk space" "Free: ${free_human}\nRequired: ${req_human}\nAction: abort"
      exit 1
      ;;
    warn)
      free_human=$(bytes_to_human "$dest_dir_free_bytes")
      req_human=$(bytes_to_human "$required")
      log "WARNING: not enough free space on $DEST_DIR: available=${dest_dir_free_bytes} bytes, required=${required} bytes; continuing because LOW_SPACE_ACTION=warn"
      low_space_note="Low space warning: Free=${free_human}, Required=${req_human}, continuing (warn)"
      ;;
    partial)
      free_human=$(bytes_to_human "$dest_dir_free_bytes")
      req_human=$(bytes_to_human "$required")
      log "NOTICE: insufficient free space on $DEST_DIR (available=${dest_dir_free_bytes}, required=${required}); proceeding in partial mode"
      low_space_note="Partial mode (space constrained): Free=${free_human}, Required=${req_human}"
      ;;
    *)
      log_error "unknown LOW_SPACE_ACTION='${LOW_SPACE_ACTION}' - aborting"
      notify_abort "Unknown LOW_SPACE_ACTION" "Value: ${LOW_SPACE_ACTION}"
      exit 1
      ;;
  esac
else
  free_human=$(bytes_to_human "$dest_dir_free_bytes")
  req_human=$(bytes_to_human "$required")
  log "Destination free space: ${free_human} (${dest_dir_free_bytes} bytes) (required: ${req_human} (${required} bytes))"
fi

# Compute utilization percentages and apply threshold notifications
pct_free_int=-1
if [[ "$dest_dir_total_bytes" =~ ^[0-9]+$ ]] && [ "$dest_dir_total_bytes" -gt 0 ] && [[ "$dest_dir_free_bytes" =~ ^[0-9]+$ ]]; then
  pct_free_int=$(awk -v f="$dest_dir_free_bytes" -v t="$dest_dir_total_bytes" 'BEGIN{printf "%d", (f*100)/t}')
fi
if [ "$pct_free_int" -ge 0 ]; then
  if [ "$pct_free_int" -lt "$UTIL_ALERT_THRESHOLD" ]; then
    util_alert_note="ALERT: Free space critically low (${pct_free_int}% < ${UTIL_ALERT_THRESHOLD}%)"
    /usr/local/emhttp/webGui/scripts/notify -i alert -b -s "${NOTIFY_TITLE} - Low Space" -d "🔴 Critical free space" -m "$util_alert_note\nPath: $DEST_DIR" || true
  elif [ "$pct_free_int" -lt "$UTIL_WARN_THRESHOLD" ]; then
    util_warn_note="Warning: Free space low (${pct_free_int}% < ${UTIL_WARN_THRESHOLD}%)"
  fi
fi

# Set directory for backup
backup_dir="${DEST_DIR}/backup_${DATETIME}"
if [ ! -d "$backup_dir" ]; then
  mkdir -p "$backup_dir"
  chown -R nobody:users "$backup_dir"
  chmod -R 775 "$backup_dir"
fi

# Stop containers except those in skip list
log "Docker $SRC_DIR_NAME backup, stopping containers"

container_ids=$(docker ps -q --no-trunc 2>/dev/null || true)
if [[ -n "$container_ids" ]]; then
  mapfile -t CONTAINERS < <(docker inspect --format='{{.Name}}' $container_ids | cut -c2- | sort)
else
  CONTAINERS=()
fi
STOP_CONTAINERS=()
for container in "${CONTAINERS[@]}"; do
  if is_skipped "$container"; then
  log "Skip ${container} for backup"
  else
  log "Stopping ${container} for backup"
    STOP_CONTAINERS+=("$container")
  fi
done

# Stop all target containers
if [ "${#STOP_CONTAINERS[@]}" -gt 0 ]; then
  docker stop "${STOP_CONTAINERS[@]}" >/dev/null 2>&1 || true
fi

# Build exclude options for tar (only if skip list set)
exclude_opts=()
if [ "${#SKIP_CONTAINERS[@]}" -gt 0 ]; then
  for item in "${SKIP_CONTAINERS[@]}"; do
    exclude_opts+=( --exclude="$item" )
  done
fi

# Create tar.gz directly in backup_dir
log "Compressing Docker $SRC_DIR_NAME for backup"

# Sanity checks before starting
if [ ! -d "$SRC_DIR" ]; then
  log_error "source directory does not exist: $SRC_DIR"
  notify_abort "Source directory missing" "Path: $SRC_DIR"
  exit 1
fi
child_count=$(find "$SRC_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || true)
log "Found $child_count subdirectories in $SRC_DIR"
if [ "$child_count" -eq 0 ]; then
  log "No containers/subdirectories found in $SRC_DIR; nothing to back up"
  exit 0
fi

while IFS= read -r -d '' file; do
  dir_name="$(basename "$file")"
  log "Processing directory: $dir_name"
  if [[ -n "$TMP_DIR" ]]; then
    err_file="${TMP_DIR}/${dir_name}.err"
    status_file="${TMP_DIR}/${dir_name}.status"
  else
    err_file="${backup_dir}/${dir_name}.err"
    status_file="${backup_dir}/${dir_name}.status"
  fi
  rm -f -- "$err_file" "$status_file"

  if is_skipped "$dir_name"; then
    log "Skipping backup for $dir_name (user specified)"
    printf "%s: SKIPPED(User specified)|0\n" "$dir_name" >"$status_file"
    continue
  fi

  archive_name="${dir_name}.tar.gz"
  archive_path="${backup_dir}/${archive_name}"
  log "Compress $file to $archive_path..."

# Job concurrency control: wait when too many jobs
while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL_JOBS" ]; do
  sleep 0.5
done

# Per-container free-space pre-check
dir_size_bytes=$(du -sb "${SRC_DIR}/${dir_name}" 2>/dev/null | awk '{print $1}' || echo 0)
dest_free_now=$(df -B1 "$DEST_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
if ! [[ "$dir_size_bytes" =~ ^[0-9]+$ ]] || ! [[ "$dest_free_now" =~ ^[0-9]+$ ]]; then
  log "WARN: could not determine size/free-space for ${dir_name}; proceeding (may fail)"
else
  need=$((dir_size_bytes + LOW_SPACE_MARGIN))
  if [ "$dest_free_now" -lt "$need" ]; then
    need_human=$(bytes_to_human "$need")
    avail_human=$(bytes_to_human "$dest_free_now")
    log "Insufficient free space for ${dir_name}: need=${need_human} (${need}), available=${avail_human} (${dest_free_now}); skipping"
    printf "%s: SKIPPED(Disk space low)|0\n" "$dir_name" >"$status_file"
    continue
  fi
fi

# Run compress_job in background
compress_job "$dir_name" "$archive_path" "$err_file" "$status_file" &
done < <(find "${SRC_DIR}" -type d -maxdepth 1 -mindepth 1 -print0)

# Wait for background compression jobs to finish
wait

# Aggregate per-job status files into backup_report
backup_report=""
shopt -s nullglob
status_files=()
for f in "${backup_dir}"/*.status; do
  [ -e "$f" ] && status_files+=("$f")
done
if [[ -n "$TMP_DIR" ]]; then
  for f in "${TMP_DIR}"/*.status; do
    [ -e "$f" ] && status_files+=("$f")
  done
fi

if [ ${#status_files[@]} -gt 0 ]; then
  for sf in "${status_files[@]}"; do
    if [ -s "$sf" ]; then
      while IFS= read -r line; do
        if [[ "$line" =~ ^[^[:space:]]+:[[:space:]].* ]]; then
              backup_report+="${line}"$'\n'
            fi
      done < "$sf"
    fi
  done
  for f in "${status_files[@]}"; do
    rm -f -- "$f" 2>/dev/null || true
  done
fi
shopt -u nullglob

# Determine overall status from backup_report
backup_status=0
if [[ "$backup_report" == *"FAILED"* ]]; then
  backup_status=1
fi

# Build per-container summary (header + per-container lines)
notify_body=""
if [[ -n "$backup_report" ]]; then
  total=0
  ok_count=0
  failed_count=0
  skipped_count=0
  lines_formatted=""
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    name=$(printf "%s" "$_line" | cut -d: -f1)
    rest=$(printf "%s" "$_line" | cut -d: -f2- | sed 's/^ //')
    label=$(printf "%s" "$rest" | cut -d'|' -f1)
    bytes_field=$(printf "%s" "$rest" | cut -d'|' -f2)
    if [[ "$label" == SKIPPED* ]]; then
      skipped_count=$((skipped_count+1))
      if [[ "$label" =~ ^SKIPPED\((.*)\)$ ]]; then
        skip_reason="${BASH_REMATCH[1]}"
        lines_formatted+="[${name}] Backup SKIPPED: ${skip_reason}"$'\n'
      else
        lines_formatted+="[${name}] Backup SKIPPED"$'\n'
      fi
    elif [[ "$label" == "FAILED" ]]; then
      failed_count=$((failed_count+1))
      lines_formatted+="[${name}] Backup FAILED"$'\n'
    else
      ok_count=$((ok_count+1))
      size_str="$label"
      size_str=$(sed -E 's/([0-9.]+)M$/\\1MB/; s/([0-9.]+)G$/\\1GB/; s/([0-9.]+)T$/\\1TB/; s/([0-9.]+)K$/\\1KB/' <<< "$size_str")
      lines_formatted+="[${name}] Backup OK:  ${size_str}"$'\n'
      if [[ "$bytes_field" =~ ^[0-9]+$ ]]; then
        total=$((total + bytes_field))
      fi
    fi
  done <<< "$backup_report"

  total_count=$((ok_count + failed_count + skipped_count))
  total_human=$(bytes_to_human "$total")
  header_line="Docker: Total ${total_count} Backups, OK ${ok_count}, FAILED ${failed_count}, SKIPPED ${skipped_count} — Backup Size: ${total_human}"

  # Build notify_body with real newline separators so downstream parsing/logging works
  notify_body="${header_line}"$'\n'"${lines_formatted}"
  log "Backup report: ${header_line}"
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    log "$_line"
  done <<< "$lines_formatted"
fi

if [ "$backup_status" -eq 0 ]; then
  log_msg="Docker $SRC_DIR_NAME backup OK, starting containers"
  log "$log_msg"
else
  log_error "Docker $SRC_DIR_NAME backup FAILED! == Error: $backup_status"
  error_summary=""
  while IFS= read -r line; do
    name=$(printf "%s" "$line" | cut -d: -f1)
    rest=$(printf "%s" "$line" | cut -d: -f2- | sed 's/^ //')
    label=$(printf "%s" "$rest" | cut -d'|' -f1)
    if [[ "$label" == "FAILED" ]]; then
      err_file="${backup_dir}/${name}.err"
      if [[ -f "$err_file" ]]; then
  excerpt=$(tail -n "$ERR_EXCERPT_LINES" "$err_file" | sed ':a;N;$!ba;s/\r$//')
  error_summary+="$name: FAILED"$'\n'"Reason:"$'\n'"$excerpt"$'\n\n'
      else
  error_summary+="$name: FAILED"$'\n'"Reason: unknown (no stderr)"$'\n\n'
      fi
    fi
  done < <(printf "%s\n" "$backup_report")
fi

# Start containers in batch then verify
if [ "${#STOP_CONTAINERS[@]}" -gt 0 ]; then
  docker start "${STOP_CONTAINERS[@]}" >/dev/null 2>&1 || true
  for container in "${STOP_CONTAINERS[@]}"; do
    running=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo false)
    if [[ "$running" != "true" ]]; then
      log_msg="Start container fail: ${container}"
      log_error "$log_msg"
    else
      log_msg="Started ${container}"
  log "$log_msg"
    fi
  done
fi

# Consolidated cleanup of old backups and logs
log_msg="Docker backup files are in $backup_dir"
log "$log_msg"

cleanup_old_artifacts() {
  local removed_backups=0 removed_logs=0

  if [ -d "${DEST_DIR}" ]; then
    mapfile -t bks < <(find "${DEST_DIR}/" -mindepth 1 -maxdepth 1 -type d -printf '%T+\t%p\n' 2>/dev/null | sort | cut -f2)
    while [ "${#bks[@]}" -gt "${MAX_BACKUPS}" ]; do
      rm -rf -- "${bks[0]}"
      removed_backups=$((removed_backups+1))
      bks=("${bks[@]:1}")
    done
  fi

  if [ -d "${LOG_FILE_SUBDIR}" ]; then
    mapfile -t lgs < <(find "${LOG_FILE_SUBDIR}/" -mindepth 1 -maxdepth 1 -type f -printf '%T+\t%p\n' 2>/dev/null | sort | cut -f2)
    while [ "${#lgs[@]}" -gt "${MAX_LOGS}" ]; do
      rm -rf -- "${lgs[0]}"
      removed_logs=$((removed_logs+1))
      lgs=("${lgs[@]:1}")
    done
  fi
  log "Cleanup removed ${removed_backups} old backups and ${removed_logs} old logs"
}

cleanup_old_artifacts

# Record end time and log runtime
runtime=$(($(date +%s) - start_time))
runtime_converted=$(printf '%dh:%dm:%ds' $((runtime / 3600)) $((runtime % 3600 / 60)) $((runtime % 60)))
log_msg="Docker $SRC_DIR_NAME backup end == Runtime: ${runtime_converted}"
log "$log_msg"
if [ $backup_status -eq 0 ]; then
  notify_level="$NOTIFY_LEVEL_ON_SUCCESS"
  notify_short="Docker $SRC_DIR_NAME backup OK!"
else
  notify_level="$NOTIFY_LEVEL_ON_FAILURE"
  notify_short="Docker $SRC_DIR_NAME backup FAILED!"
fi

# Build final notify message: runtime + summary (emoji-prefixed)
if [ "${backup_status:-0}" -eq 0 ]; then
  overall_emoji="🟢"
else
  overall_emoji="🔴"
fi

# Build per-container lines with emoji
per_lines_with_emoji=""
if [[ -n "${lines_formatted:-}" ]]; then
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    if [[ "$l" == *"Backup OK"* ]]; then
      per_lines_with_emoji+="🟢 ${l}"$'\n'
    elif [[ "$l" == *"Backup FAILED"* ]]; then
      per_lines_with_emoji+="🔴 ${l}"$'\n'
    else
      per_lines_with_emoji+="🔵 ${l}"$'\n'
    fi
  done <<< "${lines_formatted}"
fi

# Emoji-prefixed short detail
if [ "${backup_status:-0}" -eq 0 ]; then
  status_text="OK"
else
  status_text="FAILED"
fi
if [[ -n "${ok_count:-}" && -n "${total_count:-}" ]]; then
  counts="(${ok_count}/${total_count})"
else
  counts=""
fi
notify_subject="${NOTIFY_TITLE} - ${status_text} ${counts}"
emoji_short="${overall_emoji} ${notify_short}"

final_body="Runtime: ${runtime_converted}"$'\n\n'
if [[ -n "${notify_body:-}" ]]; then
  header_line=$(printf "%s\n" "${notify_body}" | head -n1)
  final_body+="${header_line}"$'\n'"${per_lines_with_emoji}"
else
  final_body+="${backup_report}"$'\n'
fi
# Append space metrics and optional low-space note
if [[ -z "${free_human:-}" ]]; then
  if [[ "$dest_dir_free_bytes" =~ ^[0-9]+$ ]]; then
    free_human=$(bytes_to_human "$dest_dir_free_bytes")
  else
    free_human="Unknown"
  fi
fi
if [[ -z "${req_human:-}" ]]; then
  if [[ "$required" =~ ^[0-9]+$ ]]; then
    req_human=$(bytes_to_human "$required")
  else
    req_human="Unknown"
  fi
fi
space_line="Space: Free=${free_human} Required=${req_human}"
final_body+=$'\n'"${space_line}"
if [ "$pct_free_int" -ge 0 ]; then
  util_line="Utilization: Total=$(bytes_to_human $dest_dir_total_bytes) Used=$(bytes_to_human $dest_dir_used_bytes) Free=$(bytes_to_human $dest_dir_free_bytes) Free%=${pct_free_int}%"
  final_body+=$'\n'"${util_line}"
fi
# Percent required vs free
req_pct_of_free=-1
if [[ "$required" =~ ^[0-9]+$ ]] && [[ "$dest_dir_free_bytes" =~ ^[0-9]+$ ]] && [ "$dest_dir_free_bytes" -gt 0 ]; then
  req_pct_of_free=$(awk -v r="$required" -v f="$dest_dir_free_bytes" 'BEGIN{printf "%d", (r*100)/f}')
fi
if [ "$req_pct_of_free" -ge 0 ]; then
  final_body+=$'\n'"Required vs Free: ${req_pct_of_free}%"
else
  final_body+=$'\n'"Required vs Free: Unknown"
fi
if [[ -n "${low_space_note:-}" ]]; then
  final_body+=$'\n'"${low_space_note}"
fi
if [[ -n "${util_alert_note:-}" ]]; then
  final_body+=$'\n'"${util_alert_note}"
fi
if [[ -n "${util_warn_note:-}" ]]; then
  final_body+=$'\n'"${util_warn_note}"
fi
if [ "${dest_dir_was_missing}" -eq 1 ]; then
  final_body+=$'\n'"Destination directory was missing and created: $DEST_DIR"
fi
if [ $backup_status -ne 0 ]; then
  final_body+=$'\n'"${error_summary}"
fi

# Send notify with emoji-prefixed title and short message
/usr/local/emhttp/webGui/scripts/notify -i "$notify_level" -b -s "$notify_subject" \
  -d "$emoji_short" -m "$final_body"
notify_exit=$?
if [ $notify_exit -ne 0 ]; then
  log_error "Notification command failed with exit code $notify_exit"
fi

# Remove backup_dir if failed and KEEP_PARTIAL is false, otherwise keep as before
if [ $backup_status -ne 0 ]; then
  if [ "${KEEP_PARTIAL}" != "true" ]; then
    rm -r "$backup_dir"
  else
    log "Keeping partial backup artifacts in $backup_dir for inspection"
  fi
fi

# Cleanup temporary .err files if requested and run was successful
if [ "$KEEP_TEMP_ERR" != "true" ]; then
  find "${backup_dir}" -type f -name '*.err' -delete 2>/dev/null || true
fi

exit 0