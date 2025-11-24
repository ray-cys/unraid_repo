#!/bin/bash
LOCKFILE="/tmp/appdata_backup.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Another appdata_backup.sh run is active, exiting (lock: $LOCKFILE)"
  exit 1
fi
################################################################################
# ---------------- Configuration ----------------
# Docker Appdata Backup & Additional Shares Settings
################################################################################

# === Core Paths & Identification ===
SRC_DIR="/mnt/cache/appdata"                                  # Source (Docker appdata) directory
DEST_DIR="/mnt/user/node/cache"                               # Destination directory (contains dated backup subdir)
SRC_DIR_NAME="$(basename "$SRC_DIR")"                         # Derived name for logging & log path prefix
DATETIME="$(date +%Y%m%d_%H%M%S)"                             # Run timestamp
TMP_DIR=""                                                    # Optional temp staging dir (empty -> inside backup_dir)
LOG_FILE_SUBDIR="/mnt/cache/system/logs/${SRC_DIR_NAME}_logs" # Directory for run logs
LOG_FILE="$LOG_FILE_SUBDIR/$SRC_DIR_NAME-$DATETIME.log"       # Per-run log file

# === Container Selection ===
SKIP_CONTAINERS=()                                            # Array: container names to skip (exact match)

# === Backup Retention ===
MAX_BACKUPS=3                                                 # Max dated backup directories to retain
MAX_LOGS=3                                                    # Max log files to retain
KEEP_PARTIAL=${KEEP_PARTIAL:-true}                            # Keep failed/partial backup directory (true/false)
KEEP_TEMP_ERR=${KEEP_TEMP_ERR:-false}                         # Keep individual .err files after success (true/false)

# === Compression & Performance ===
PARALLEL_JOBS=${PARALLEL_JOBS-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)}  # Concurrent compression jobs
if command -v pigz >/dev/null 2>&1; then USE_PIGZ=1; else USE_PIGZ=0; fi                        # pigz faster parallel gzip
if command -v pv   >/dev/null 2>&1; then PV_AVAILABLE=1; else PV_AVAILABLE=0; fi                # pv for progress
PIGZ_THREADS=${PIGZ_THREADS:-0}                                                                 # pigz threads (0=auto)
TARBALL_PROGRESS_TO_LOG=${TARBALL_PROGRESS_TO_LOG:-true}                                        # Append live progress to log when pv used
TAR_OPTIONS=()                                                                                  # Extra tar options array (e.g., ("--exclude=foo"))
DF_REFRESH_INTERVAL=${DF_REFRESH_INTERVAL:-3}                                                   # Refresh cadence for df free-space checks

# === Reliability / Retry ===
RETRIES=${RETRIES:-3}                                          # Compression retry attempts per directory
RETRY_DELAY=${RETRY_DELAY:-5}                                  # Seconds between retries
ERR_EXCERPT_LINES=${ERR_EXCERPT_LINES:-20}                     # Lines of stderr excerpt in failure notification

# === Space / Capacity Thresholds ===
LOW_SPACE_ACTION=${LOW_SPACE_ACTION:-abort}                    # Behavior when space low (abort|warn|partial)
LOW_SPACE_MARGIN=${LOW_SPACE_MARGIN:-0}                        # Extra bytes added to required size estimate
UTIL_WARN_THRESHOLD=${UTIL_WARN_THRESHOLD:-15}                 # Percent free below -> warning note
UTIL_ALERT_THRESHOLD=${UTIL_ALERT_THRESHOLD:-5}                # Percent free below -> alert notification

# === Notifications ===
NOTIFY_TITLE="Docker Backup"                                  # Notification title prefix
NOTIFY_LEVEL_ON_SUCCESS="normal"                              # Level for overall success
NOTIFY_LEVEL_ON_FAILURE="alert"                               # Level for overall failure

# === Shares Backup (Rsync) ===
# Extend arrays to add more non-appdata shares. Each mirrors src -> dest via rsync.
ADD_NAMES=("cloud" "system")                                                  # Names for each additional share
ADD_SRCS=("/mnt/user/cloud" "/mnt/cache/system")                              # Mirror source directories
ADD_DESTS=("/mnt/user/node/shares/cloud" "/mnt/user/node/shares/system")      # Mirror destination directories
ADD_EXCLUDES=("" "")                                                          # Space-separated patterns per position (empty => none)
ADD_RSYNC_BASE_ARGS=("-aH" "--delete" "--stats" "--protect-args" "--partial") # Base rsync args
ADD_USE_IONICE=true                                                           # Ionice/nice wrappers for rsync if available
ADD_SECTION_HEADER="Shares Backup"                                            # Heading used in final notification

# === Ownership / Permissions ===
LOG_OWNER="${LOG_OWNER:-nobody}"                               # Owner user for log directory and files
LOG_DIR_PERMS="${LOG_DIR_PERMS:-0775}"                         # Directory permissions (keep group write if share exported)
LOG_FILE_PERMS="${LOG_FILE_PERMS:-0664}"                       # File permissions

# === Runtime State (internal; do not modify) ===
# Metrics and transient status values collected during execution.
dest_dir_was_missing=0                                         # Flag if destination was auto-created
low_space_note=""                                              # Warning/partial note when space low
util_alert_note=""                                             # Critical utilization alert message
util_warn_note=""                                              # Utilization warning message
pct_free_int=-1                                                # Percent free (integer) on destination FS
required=0                                                     # Estimated required bytes for all containers
free_human="" req_human=""                                     # Human-readable free/required strings
dest_dir_free_bytes=0                                          # Free bytes (post fallback logic)
dest_dir_total_bytes=0                                         # Total bytes of destination filesystem
dest_dir_used_bytes=0                                          # Used bytes of destination filesystem
declare -A DIR_SIZES=()                                        # Per-container size cache (bytes)

################################################################################
# Helper Functions
################################################################################

# Helper: ensure_dir - create directory if missing; apply owner & perms
# Ensure runtime log directory exists
ensure_dir() {
  local path="$1" perm="${2:-$LOG_DIR_PERMS}" owner="${3:-$LOG_OWNER}"
  if [ ! -d "$path" ]; then mkdir -p "$path" 2>/dev/null || return 1; fi
  chown "$owner" "$path" 2>/dev/null || true
  chmod "$perm" "$path" 2>/dev/null || true
}
ensure_dir "$LOG_FILE_SUBDIR" "$LOG_DIR_PERMS" "$LOG_OWNER"
: > "$LOG_FILE"
chown "$LOG_OWNER" "$LOG_FILE" 2>/dev/null || true
chmod "$LOG_FILE_PERMS" "$LOG_FILE" 2>/dev/null || true
# Build skip map & tar exclude array
declare -A SKIP_MAP=()
exclude_opts=()
for _skip in "${SKIP_CONTAINERS[@]}"; do
  SKIP_MAP["$_skip"]=1
  exclude_opts+=( --exclude="$_skip" )
done
is_skipped() { [[ -n "${SKIP_MAP[$1]:-}" ]]; }
# Report of backups (populated later)
backup_report=""

# Helper: log - messages to logfile and stdout
log() {
  local msg="$1"
  echo "$(date "+%Y/%m/%d %T") : $msg" | tee -a "$LOG_FILE"
}

# Helper: log_error - errors to syslog + logfile
log_error() {
  local msg="$1"
  logger -p err "ERROR: $msg"
  log "ERROR: $msg"
}

# Helper: notify_abort - early failure notification
notify_abort() {
  local reason="$1"
  local detail="${2:-}"
  local subj="${NOTIFY_TITLE} - FAILED"
  local short="Backup aborted"
  local body="Reason: ${reason}"
  if [ -n "$detail" ]; then
    body+=$'\n'"$detail"
  fi
  /usr/local/emhttp/webGui/scripts/notify -i "$NOTIFY_LEVEL_ON_FAILURE" -b -s "$subj" -d "$short" -m "$body" || true
}

# Helper: bytes_to_human - format byte counts
bytes_to_human() {
  local bytes=${1:-0}
  awk -v b="$bytes" 'BEGIN{
    u[0]="B"; u[1]="KB"; u[2]="MB"; u[3]="GB"; u[4]="TB"; u[5]="PB";
    i=0;
    while(b>=1024 && i<5){ b=b/1024; i++ }
    if(b>=100) printf("%.0f%s", b, u[i]); else printf("%.1f%s", b, u[i]);
  }'
}

# Helper: safe_size_bytes - robust size retrieval
safe_size_bytes() {
  local path="$1"
  local size
  size=$(du -sb "$path" 2>/dev/null | awk '{print $1}' || echo 0)
  if ! [[ "$size" =~ ^[0-9]+$ ]] || [ "$size" -eq 0 ]; then
    local kb
    kb=$(du -k "$path" 2>/dev/null | awk '{print $1}' || echo 0)
    if [[ "$kb" =~ ^[0-9]+$ ]] && [ "$kb" -gt 0 ]; then
      size=$((kb*1024))
    else
      size=0
    fi
  fi
  echo "$size"
}

# Helper: write_status - standardized status line
write_status() {
  local name="$1" label="$2" bytes="$3" sfile="${4:-}"
  if [ -n "$sfile" ]; then
    printf "%s: %s|%s\n" "$name" "$label" "$bytes" >"$sfile"
  else
    printf "%s: %s|%s\n" "$name" "$label" "$bytes"
  fi
}

# Helper: compress_job - Streams tar -> (optional pv) -> pigz/gzip with retries
compress_job() {
  local dname="$1"; shift
  local out="$1"; shift
  local efile="$1"; shift
  local sfile="$1"; shift || true
  local attempt=1 ok=0
  local dir_size
  dir_size=$(safe_size_bytes "${SRC_DIR}/${dname}")

  local comp_cmd
  if [ "$USE_PIGZ" -eq 1 ]; then
    if [ "$PIGZ_THREADS" -gt 0 ]; then
      comp_cmd="pigz -p $PIGZ_THREADS -c"
    else
      comp_cmd="pigz -p 0 -c"
    fi
  else
    comp_cmd="gzip -c"
  fi

  while [ $attempt -le "$RETRIES" ]; do
    log "[${dname}] compress attempt $attempt"
    if [ "$PV_AVAILABLE" -eq 1 ] && [ "$dir_size" -gt 0 ]; then
      if [ "$TARBALL_PROGRESS_TO_LOG" = "true" ]; then
        if ( set -o pipefail; tar cPf - -C "${SRC_DIR}" "${dname}" "${TAR_OPTIONS[@]}" "${exclude_opts[@]}" 2>>"$efile" | pv -s "$dir_size" 2> >(tee -a "$LOG_FILE" >>"$efile") | eval "$comp_cmd" >"$out" ); then
          ok=1; break
        else
          log "[${dname}] pv+progress pipeline failed (attempt $attempt)"
        fi
      else
        if ( set -o pipefail; tar cPf - -C "${SRC_DIR}" "${dname}" "${TAR_OPTIONS[@]}" "${exclude_opts[@]}" 2>>"$efile" | pv -s "$dir_size" 2>>"$efile" | eval "$comp_cmd" >"$out" ); then
          ok=1; break
        else
          log "[${dname}] pv pipeline failed (attempt $attempt)"
        fi
      fi
    else
      if ( set -o pipefail; tar cPf - -C "${SRC_DIR}" "${dname}" "${TAR_OPTIONS[@]}" "${exclude_opts[@]}" 2>>"$efile" | eval "$comp_cmd" >"$out" ); then
        ok=1; break
      else
        log "[${dname}] basic pipeline failed (attempt $attempt)"
      fi
    fi
    attempt=$((attempt+1))
    sleep "$RETRY_DELAY"
  done

  if [ $ok -eq 1 ]; then
    local size_bytes size_human
    size_bytes=$(safe_size_bytes "$out")
    if [[ "$size_bytes" =~ ^[0-9]+$ ]] && [ "$size_bytes" -gt 0 ]; then
      size_human=$(bytes_to_human "$size_bytes")
      log "[${dname}] compressed -> ${size_human} (${size_bytes} bytes)"
    else
      size_human="0B"
      log "[${dname}] compressed size unknown (0B)"
    fi
    write_status "$dname" "$size_human" "$size_bytes" "$sfile"
  else
    write_status "$dname" FAILED 0 "$sfile"
    log_error "${dname} compression failed after ${RETRIES} attempts (see ${efile})"
  fi
}

assess_space() {
  local _subtotal=0 _subtotal_unknown=0 _dest_unknown=0
  while IFS= read -r -d '' d; do
    local name
    name="$(basename "$d")"
    if is_skipped "$name"; then continue; fi
    local bytes
    bytes=$(safe_size_bytes "$d")
    if [[ "$bytes" =~ ^[0-9]+$ ]] && [ "$bytes" -gt 0 ]; then
      _subtotal=$((_subtotal + bytes))
      DIR_SIZES["$name"]="$bytes"
    else
      log "WARN: size unknown for $d"
      _subtotal_unknown=1
      DIR_SIZES["$name"]=0
    fi
  done < <(find "$SRC_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

  if [ ! -d "$DEST_DIR" ]; then
    if mkdir -p "$DEST_DIR" 2>/dev/null; then
      dest_dir_was_missing=1
      log "Created destination: $DEST_DIR"
    else
      log_error "Cannot create destination: $DEST_DIR"
      notify_abort "Destination directory missing" "Path: $DEST_DIR (mkdir failed)"
      exit 1
    fi
  fi

  dest_dir_free_bytes=$(df -B1 "$DEST_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
  dest_dir_total_bytes=$(df -B1 "$DEST_DIR" 2>/dev/null | awk 'NR==2 {print $2}' || echo 0)
  dest_dir_used_bytes=$(df -B1 "$DEST_DIR" 2>/dev/null | awk 'NR==2 {print $3}' || echo 0)
  if ! [[ "$dest_dir_free_bytes" =~ ^[0-9]+$ ]]; then
    log "WARN: free space unknown on $DEST_DIR"
    _dest_unknown=1
  fi

  required=$((_subtotal + LOW_SPACE_MARGIN))
  if [ $_subtotal_unknown -eq 1 ] || [ $_dest_unknown -eq 1 ]; then
    log "Proceeding despite undetermined required or free space (local destination)"
  fi

  if [ $_dest_unknown -eq 0 ] && [ "$dest_dir_free_bytes" -lt "$required" ]; then
    case "$LOW_SPACE_ACTION" in
      abort)
        free_human=$(bytes_to_human "$dest_dir_free_bytes"); req_human=$(bytes_to_human "$required")
        log_error "Insufficient free space (need=$required have=$dest_dir_free_bytes)"
        notify_abort "Low disk space" "Free = ${free_human}\nRequired = ${req_human}\nAction = abort"; exit 1 ;;
      warn)
        free_human=$(bytes_to_human "$dest_dir_free_bytes"); req_human=$(bytes_to_human "$required")
        low_space_note="Low space warning: Free = ${free_human} Required = ${req_human}" ;;
      partial)
        free_human=$(bytes_to_human "$dest_dir_free_bytes"); req_human=$(bytes_to_human "$required")
        low_space_note="Partial mode: Free = ${free_human} Required = ${req_human}" ;;
      *)
        log_error "Unknown LOW_SPACE_ACTION='$LOW_SPACE_ACTION'"; notify_abort "Unknown LOW_SPACE_ACTION" "$LOW_SPACE_ACTION"; exit 1 ;;
    esac
  else
    free_human=$(bytes_to_human "$dest_dir_free_bytes")
    req_human=$(bytes_to_human "$required")
    log "Free space OK: Free = ${free_human} Required = ${req_human}"
  fi

  if [[ "$dest_dir_total_bytes" =~ ^[0-9]+$ ]] && [ "$dest_dir_total_bytes" -gt 0 ] && [[ "$dest_dir_free_bytes" =~ ^[0-9]+$ ]]; then
    pct_free_int=$(awk -v f="$dest_dir_free_bytes" -v t="$dest_dir_total_bytes" 'BEGIN{printf "%d", (f*100)/t}')
    if [ "$pct_free_int" -lt "$UTIL_ALERT_THRESHOLD" ]; then
      util_alert_note="ALERT: Free space critically low (${pct_free_int}% < ${UTIL_ALERT_THRESHOLD}%)"
      /usr/local/emhttp/webGui/scripts/notify -i "$NOTIFY_LEVEL_ON_FAILURE" -b -s "${NOTIFY_TITLE} - Low Space" -d "🔴 Critical free space" -m "$util_alert_note\nPath: $DEST_DIR" || true
    elif [ "$pct_free_int" -lt "$UTIL_WARN_THRESHOLD" ]; then
      util_warn_note="Warning: Free space low (${pct_free_int}% < ${UTIL_WARN_THRESHOLD}%)"
    fi
  fi
}

# Helper: cleanup_old_artifacts - prune old backups & logs
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

# Helper: build_space_block - assemble space/utilization summary
build_space_block() {
  [[ -z "${free_human:-}" ]] && free_human=$( [[ "$dest_dir_free_bytes" =~ ^[0-9]+$ ]] && bytes_to_human "$dest_dir_free_bytes" || echo "Unknown" )
  [[ -z "${req_human:-}" ]] && req_human=$( [[ "$required" =~ ^[0-9]+$ ]] && bytes_to_human "$required" || echo "Unknown" )
  local out="Space: Free = ${free_human} Required = ${req_human}"$'\n'
  if [ "$pct_free_int" -ge 0 ]; then
    out+="Utilization: Total = $(bytes_to_human "$dest_dir_total_bytes") Used = $(bytes_to_human "$dest_dir_used_bytes") Free = $(bytes_to_human "$dest_dir_free_bytes") Free% = ${pct_free_int}%"$'\n'
  fi
  local req_pct_of_free=-1
  if [[ "$required" =~ ^[0-9]+$ ]] && [[ "$dest_dir_free_bytes" =~ ^[0-9]+$ ]] && [ "$dest_dir_free_bytes" -gt 0 ]; then
    req_pct_of_free=$(awk -v r="$required" -v f="$dest_dir_free_bytes" 'BEGIN{printf "%d", (r*100)/f}')
  fi
  if [ "$req_pct_of_free" -ge 0 ]; then out+="Required vs Free: ${req_pct_of_free}%"$'\n'; else out+="Required vs Free: Unknown"$'\n'; fi
  [[ -n "${low_space_note:-}" ]] && out+="${low_space_note}"$'\n'
  [[ -n "${util_alert_note:-}" ]] && out+="${util_alert_note}"$'\n'
  [[ -n "${util_warn_note:-}" ]] && out+="${util_warn_note}"$'\n'
  [ "$dest_dir_was_missing" -eq 1 ] && out+="Destination directory was missing and created: $DEST_DIR"$'\n'
  printf '%s' "$out"
}

# =============================
# Main Execution
# =============================
main() {
  # Record start time and announce start
  start_time=$(date +%s)
  log_msg="Docker $SRC_DIR_NAME backup start: $(date)"
  log "$log_msg"
  assess_space

# Set directory for appdata backup
  backup_dir="${DEST_DIR}/backup_${DATETIME}"
  if [ ! -d "$backup_dir" ]; then
    ensure_dir "$backup_dir" 775 "$LOG_OWNER"
  fi

# Stop containers except those in skip list
  log "Docker $SRC_DIR_NAME backup, stopping containers"

container_ids=$(docker ps -q --no-trunc 2>/dev/null || true)
if [[ -n "$container_ids" ]]; then
  mapfile -t CONTAINERS < <(docker inspect --format='{{.Name}}' "$container_ids" | cut -c2- | sort)
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

  # Per-container free-space check using precomputed size (fallback to runtime du if missing)
  dir_size_bytes="${DIR_SIZES[$dir_name]:-0}"
  if ! [[ "$dir_size_bytes" =~ ^[0-9]+$ ]] || [ "$dir_size_bytes" -eq 0 ]; then
    dir_size_bytes=$(safe_size_bytes "${SRC_DIR}/${dir_name}")
  fi
  # Refresh free space only every N containers to reduce df calls
  container_index=${container_index:-0}
  if (( container_index % DF_REFRESH_INTERVAL == 0 )) || [ -z "${cached_dest_free:-}" ]; then
    cached_dest_free=$(df -B1 "$DEST_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
  fi
  dest_free_now="$cached_dest_free"
  container_index=$((container_index+1))
  if [[ "$dir_size_bytes" =~ ^[0-9]+$ ]] && [[ "$dest_free_now" =~ ^[0-9]+$ ]]; then
    need=$((dir_size_bytes + LOW_SPACE_MARGIN))
    if [ "$dest_free_now" -lt "$need" ]; then
      need_human=$(bytes_to_human "$need")
      avail_human=$(bytes_to_human "$dest_free_now")
      log "Insufficient free space for ${dir_name}: need=${need_human} (${need}), available=${avail_human} (${dest_free_now}); skipping"
      printf "%s: SKIPPED(Disk space low)|0\n" "$dir_name" >"$status_file"
      continue
    fi
  else
    log "WARN: could not determine size/free-space for ${dir_name}; proceeding (may fail)"
  fi

# Run compress_job in background
  compress_job "$dir_name" "$archive_path" "$err_file" "$status_file" &
done < <(find "${SRC_DIR}" -type d -maxdepth 1 -mindepth 1 -print0)

# Wait for background compression jobs to finish
  wait

#############################################
# Aggregate per-job status -> report + emojis
#############################################
backup_report=""
shopt -s nullglob
status_files=()
for f in "${backup_dir}"/*.status; do [ -e "$f" ] && status_files+=("$f"); done
if [[ -n "$TMP_DIR" ]]; then for f in "${TMP_DIR}"/*.status; do [ -e "$f" ] && status_files+=("$f"); done; fi

ok_count=0 failed_count=0 skipped_count=0 total_bytes=0
if [ ${#status_files[@]} -gt 0 ]; then
  for sf in "${status_files[@]}"; do
    [ -s "$sf" ] || continue
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "$line" =~ ^[^[:space:]]+:[[:space:]].* ]] || continue
      name=$(printf "%s" "$line" | cut -d: -f1)
      rest=$(printf "%s" "$line" | cut -d: -f2- | sed 's/^ //')
      label=$(printf "%s" "$rest" | cut -d'|' -f1)
      bytes_field=$(printf "%s" "$rest" | cut -d'|' -f2)
      emoji=""
      if [[ "$label" == SKIPPED* ]]; then
        skipped_count=$((skipped_count+1))
        emoji="🔵"
        if [[ "$label" =~ ^SKIPPED\((.*)\)$ ]]; then
          skip_reason="${BASH_REMATCH[1]}"
          backup_report+="${emoji} [${name}] SKIPPED: ${skip_reason}"$'\n'
        else
          backup_report+="${emoji} [${name}] SKIPPED"$'\n'
        fi
      elif [[ "$label" == FAILED ]]; then
        failed_count=$((failed_count+1))
        emoji="🔴"
        err_file="${backup_dir}/${name}.err"
        if [[ -f "$err_file" ]]; then
          excerpt=$(tail -n "$ERR_EXCERPT_LINES" "$err_file" | sed ':a;N;$!ba;s/\r$//')
          backup_report+="${emoji} [${name}] FAILED"$'\n'"---- excerpt ----"$'\n'"${excerpt}"$'\n'"-----------------"$'\n'
        else
          backup_report+="${emoji} [${name}] FAILED (no stderr)"$'\n'
        fi
      else
        ok_count=$((ok_count+1))
        emoji="🟢"
        size_str="$label"
        size_str=$(sed -E 's/([0-9.]+)M$/\\1MB/; s/([0-9.]+)G$/\\1GB/; s/([0-9.]+)T$/\\1TB/; s/([0-9.]+)K$/\\1KB/' <<< "$size_str")
        backup_report+="${emoji} [${name}] OK: ${size_str}"$'\n'
        if [[ "$bytes_field" =~ ^[0-9]+$ ]]; then total_bytes=$((total_bytes + bytes_field)); fi
      fi
    done < "$sf"
  done
  for f in "${status_files[@]}"; do rm -f -- "$f" 2>/dev/null || true; done
fi
shopt -u nullglob

total_count=$((ok_count + failed_count + skipped_count))
total_human=$(bytes_to_human "$total_bytes")
backup_status=0; [[ $failed_count -gt 0 ]] && backup_status=1
summary_header="Docker: Total ${total_count} Backups, OK ${ok_count}, FAILED ${failed_count}, SKIPPED ${skipped_count} — Size: ${total_human}"
  log "Backup report: ${summary_header}"
while IFS= read -r _l; do [[ -z "$_l" ]] && continue; log "$_l"; done <<< "$backup_report"

if [ "$backup_status" -eq 0 ]; then
  log "Docker $SRC_DIR_NAME backup OK, starting containers"
else
  log_error "Docker $SRC_DIR_NAME backup FAILED"
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

if [ "${backup_status:-0}" -eq 0 ]; then status_text="OK"; else status_text="FAILED"; fi
counts="(${ok_count}/${total_count})"
notify_subject="${NOTIFY_TITLE} - ${status_text} ${counts}"
notify_short="Docker $SRC_DIR_NAME backup ${status_text}!"

  final_body="Runtime: ${runtime_converted}"$'\n\n'

#############################################
# Additional Shares Backup Rsync Phase
#############################################
additional_lines=""
additional_ok=0
additional_fail=0
additional_total=0
if [ ${#ADD_NAMES[@]} -gt 0 ]; then
  for idx in "${!ADD_NAMES[@]}"; do
    name="${ADD_NAMES[$idx]}"
    src="${ADD_SRCS[$idx]}"
    dest="${ADD_DESTS[$idx]}"
    excl_raw="${ADD_EXCLUDES[$idx]}"
    additional_total=$((additional_total+1))
    if [ ! -d "$src" ]; then
      log "[share:$name] source missing: $src (skipping)"
      additional_lines+="🔵 $name: SKIPPED (missing source)"$'\n'
      continue
    fi
    if [ ! -d "$dest" ]; then
      if ensure_dir "$dest" 775 "$LOG_OWNER"; then
        log "[share:$name] created destination: $dest"
      else
        log "[share:$name] cannot create destination: $dest"
        additional_lines+="🔴 $name: FAILED (dest create)"$'\n'
        additional_fail=$((additional_fail+1))
        continue
      fi
    fi
    tmp_rsync_log=$(mktemp /tmp/add_rsync_"${name}".XXXXXX)
    rsync_excludes=()
    if [ -n "$excl_raw" ]; then
      # Split on spaces; expansion already handled when reading config
      for pat in $excl_raw; do
        rsync_excludes+=("--exclude=$pat")
      done
    fi
    rsync_cmd=(rsync "${ADD_RSYNC_BASE_ARGS[@]}" "${rsync_excludes[@]}" "$src/" "$dest/")
    if [ "$ADD_USE_IONICE" = true ] && command -v ionice >/dev/null 2>&1; then
      rsync_cmd=(ionice -c2 -n7 nice -n 10 "${rsync_cmd[@]}")
    fi
    log "[share:$name] Running: $(printf '%q ' "${rsync_cmd[@]}")"
    set +e
    ("${rsync_cmd[@]}" 2>&1 | tee "$tmp_rsync_log") >> "$LOG_FILE" 2>&1
    rstat=${PIPESTATUS[0]}
    set -e
    if [ "$rstat" -ne 0 ]; then
      # Map rsync code to brief description
      case $rstat in
        23) rdesc="Partial transfer";;
        24) rdesc="Source vanished";;
        10) rdesc="Socket I/O";;
        11) rdesc="File I/O";;
        12) rdesc="Protocol stream";;
        30) rdesc="Timeout";;
        *) rdesc="Exit $rstat";;
      esac
      additional_lines+="🔴 $name: FAILED ($rdesc)"$'\n'
      additional_fail=$((additional_fail+1))
      log "[share:$name] rsync failed code=$rstat desc=$rdesc (see $tmp_rsync_log)"
      continue
    fi
    declare -A RSYNC_PATTERNS=(
      ["Total transferred file size"]="total_tx_bytes"
      ["Number of regular files transferred"]="files_tx"
      ["Number of deleted files"]="del_count"
      ["Total bytes sent"]="bytes_sent"
    )
    total_tx_bytes=0 files_tx=0 del_count=0 bytes_sent=0
    for pat in "${!RSYNC_PATTERNS[@]}"; do
      raw=$(grep -i "$pat" "$tmp_rsync_log" | tail -n1 | sed -E 's/^[^:]*:[[:space:]]*([0-9,]+).*/\1/' | tr -d ',' || echo 0)
      [[ "$raw" =~ ^[0-9]+$ ]] || raw=0
      var_name="${RSYNC_PATTERNS[$pat]}"
      printf -v "$var_name" '%s' "$raw"
    done
    human_tx=$(bytes_to_human "${total_tx_bytes:-0}")
    human_sent=$(bytes_to_human "${bytes_sent:-0}")
    additional_lines+="🟢 $name: transferred ${human_tx}, files ${files_tx}, deleted ${del_count}, sent ${human_sent}"$'\n'
    additional_ok=$((additional_ok+1))
    rm -f "$tmp_rsync_log" 2>/dev/null || true
  done
fi

  if [ ${additional_total} -gt 0 ]; then
    final_body+="${ADD_SECTION_HEADER}: Total ${additional_total} OK ${additional_ok} FAILED ${additional_fail}"$'\n'
    final_body+="${additional_lines}"$'\n'
  fi
  final_body+="${summary_header}"$'\n'"${backup_report}"$'\n'
  final_body+=$(build_space_block)

# Send notify with emoji-prefixed title and short message
  /usr/local/emhttp/webGui/scripts/notify -i "$notify_level" -b -s "$notify_subject" \
    -d "$notify_short" -m "$final_body"
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
}

# Main Entry Point
main "$@"