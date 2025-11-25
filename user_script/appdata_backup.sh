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
COMP_USE_IONICE=${COMP_USE_IONICE:-true}                                                        # Ionice/nice wrapper for compression pipeline

# === Reliability / Retry ===
RETRIES=${RETRIES:-3}                                          # Compression retry attempts per directory
RETRY_DELAY=${RETRY_DELAY:-5}                                  # Seconds between retries
ERR_EXCERPT_LINES=${ERR_EXCERPT_LINES:-20}                     # Lines of stderr excerpt in failure notification

# === Space / Capacity Thresholds ===
LOW_SPACE_ACTION=${LOW_SPACE_ACTION:-abort}                    # Behavior when space low (abort|warn|partial)
LOW_SPACE_MARGIN=${LOW_SPACE_MARGIN:-0}                        # Extra bytes added to required size estimate
UTIL_WARN_THRESHOLD=${UTIL_WARN_THRESHOLD:-15}                 # Percent free below -> warning note
UTIL_ALERT_THRESHOLD=${UTIL_ALERT_THRESHOLD:-5}                # Percent free below -> alert notification
REQUIRED_RATIO=${REQUIRED_RATIO:-0.6}                          # Estimated compression ratio (0<r<=1)

# === Shares Backup (Rsync) ===
# Descriptor-based: "name=<n> src=<path> dest=<path> excludes=<p1,p2> excludes_file=/path/to/file"
ADD_SHARES=(
  "name=system src=/mnt/cache/system dest=/mnt/user/node/shares/system excludes="
)
ADD_RSYNC_BASE_ARGS=("-aH" "--delete-delay" "--stats" "--protect-args" "--partial") # Base rsync args
ADD_USE_IONICE=true                                                           # Ionice/nice wrappers for rsync if available
RSYNC_IONICE_CLASS=${RSYNC_IONICE_CLASS:-2}                                   # ionice class (2=best-effort)
RSYNC_IONICE_PRIO=${RSYNC_IONICE_PRIO:-7}                                     # ionice priority (0-7 lower is higher priority)
RSYNC_NICE=${RSYNC_NICE:-10}                                                  # nice adjustment for rsync

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
STOP_CONTAINERS=()                                             # Containers selected to stop
raw_uncompressed_total=0                                       # Raw summed bytes of all directories
estimated_compressed_total=0                                   # Estimated compressed bytes using REQUIRED_RATIO

################################################################################

# === Helper Functions ===
# Create directory and log file if missing; apply owner & perms
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
is_skipped() {
  local k="$1"
  [[ -n "$k" && -n "${SKIP_MAP[$k]:-}" ]]
}
# Report of backups (populated later)
backup_report=""
# Log messages to logfile and stdout
log() {
  local msg="$1"
  local category level body
  if [[ "$msg" =~ ^([A-Z]+)\|([A-Z]+)\|[[:space:]]?(.*)$ ]]; then
    category="${BASH_REMATCH[1]}"
    level="${BASH_REMATCH[2]}"
    body="${BASH_REMATCH[3]}"
  else
    # Fallback: treat unprefixed messages as BACKUP|INFO
    category="BACKUP"
    level="INFO"
    body="$msg"
  fi
  echo "$(date "+%Y/%m/%d %T") : [${category}][${level}] ${body}" | tee -a "$LOG_FILE"
}
# Notification helper
send_notify() {
  local mode="$1"; shift
  local subj="Scheduled Backup"
  case "$mode" in
    final)
      local failed_count="$1" additional_fail="$2" docker_counts="$3" shares_counts="$4" body="$5"
      local level desc status_text counts
      if [ "${failed_count:-0}" -eq 0 ] && [ "${additional_fail:-0}" -eq 0 ]; then
        level="normal"; status_text="OK"
      else
        level="alert"
        if [ "${failed_count:-0}" -gt 0 ] && [ "${additional_fail:-0}" -gt 0 ]; then
          status_text="FAILED (Docker & Shares)"
        elif [ "${failed_count:-0}" -gt 0 ]; then
          status_text="FAILED (Docker)"
        else
          status_text="FAILED (Shares)"
        fi
      fi
      if [ -n "$shares_counts" ]; then
        counts="D ${docker_counts}; S ${shares_counts}"
      else
        counts="D ${docker_counts}"
      fi
      desc="Docker Appdata & Shares - ${status_text} ${counts}"
      /usr/local/emhttp/webGui/scripts/notify -i "$level" -b -s "$subj" -d "$desc" -m "$body" || true
      ;;
    abort)
      local reason="$1" detail="${2:-}"
      local short="🔴 Backup FAILED"
      local body="Reason: ${reason}"
      local level="alert"
      if [ -n "$detail" ]; then body+=$'\n'"$detail"; fi
      /usr/local/emhttp/webGui/scripts/notify -i "$level" -b -s "$subj" -d "$short" -m "$body" || true
      ;;
    lowspace)
      local alert_msg="$1"
      local level="alert"
      local short="🔴 Low Disk Space"
      /usr/local/emhttp/webGui/scripts/notify -i "$level" -b -s "$subj" -d "$short" -m "$alert_msg" || true
      ;;
    *)
  esac
}
# Human readable byte formatting
bytes_to_human() {
  local bytes=${1:-0}
  awk -v b="$bytes" 'BEGIN{
    u[0]="B"; u[1]="KB"; u[2]="MB"; u[3]="GB"; u[4]="TB"; u[5]="PB";
    i=0;
    while(b>=1024 && i<5){ b=b/1024; i++ }
    if(b>=100) printf("%.0f%s", b, u[i]); else printf("%.1f%s", b, u[i]);
  }'
}
# Format seconds to H:M:S (e.g. 1h:02m:09s)
format_duration() {
  local secs=${1:-0}
  printf '%dh:%dm:%ds' $((secs / 3600)) $((secs % 3600 / 60)) $((secs % 60))
}
# Robust size retrieval
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
# Standardized status line
write_status() {
  local name="$1" label="$2" bytes="$3" sfile="${4:-}"
  if [ -n "$sfile" ]; then
    printf "%s: %s|%s\n" "$name" "$label" "$bytes" >"$sfile"
  else
    printf "%s: %s|%s\n" "$name" "$label" "$bytes"
  fi
}
# Disk and concurrency helpers
disk_refresh_state() {
  dest_dir_free_bytes=$(df -B1 "$DEST_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
  dest_dir_total_bytes=$(df -B1 "$DEST_DIR" 2>/dev/null | awk 'NR==2 {print $2}' || echo 0)
  dest_dir_used_bytes=$(df -B1 "$DEST_DIR" 2>/dev/null | awk 'NR==2 {print $3}' || echo 0)
  if [[ "$dest_dir_total_bytes" =~ ^[0-9]+$ ]] && [ "$dest_dir_total_bytes" -gt 0 ] && [[ "$dest_dir_free_bytes" =~ ^[0-9]+$ ]]; then
    pct_free_int=$(awk -v f="$dest_dir_free_bytes" -v t="$dest_dir_total_bytes" 'BEGIN{printf "%d", (f*100)/t}')
  else
    pct_free_int=-1
  fi
}
# Wait for a free job slot
wait_for_slot() {
  while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL_JOBS" ]; do
    sleep 0.5
  done
}
# Compress directory with retries
compress_job() {
  local dname="$1"; shift
  local out="$1"; shift
  local efile="$1"; shift
  local sfile="$1"; shift || true
  local attempt=1 ok=0
  local dir_size
  dir_size=$(safe_size_bytes "${SRC_DIR}/${dname}")

  local comp_cmd base_comp
  if [ "$USE_PIGZ" -eq 1 ]; then
    if [ "$PIGZ_THREADS" -gt 0 ]; then
      base_comp="pigz -p $PIGZ_THREADS -c"
    else
      base_comp="pigz -p 0 -c"
    fi
  else
    base_comp="gzip -c"
  fi
  local IO_PREFIX=""
  if [ "$COMP_USE_IONICE" = true ] && command -v ionice >/dev/null 2>&1; then
    IO_PREFIX="ionice -c2 -n7 nice -n 10"
  fi
  if [ -n "$IO_PREFIX" ]; then
    comp_cmd="$IO_PREFIX $base_comp"
  else
    comp_cmd="$base_comp"
  fi

  while [ $attempt -le "$RETRIES" ]; do
    log "DOCKER|INFO|[${dname}] compress attempt $attempt (ionice=${COMP_USE_IONICE} prefix='${IO_PREFIX}')"
    if [ "$PV_AVAILABLE" -eq 1 ] && [ "$dir_size" -gt 0 ]; then
      if [ "$TARBALL_PROGRESS_TO_LOG" = "true" ]; then
        if ( set -o pipefail; ${IO_PREFIX:+$IO_PREFIX }tar cPf - -C "${SRC_DIR}" "${dname}" "${TAR_OPTIONS[@]}" "${exclude_opts[@]}" 2>>"$efile" | pv -s "$dir_size" 2> >(tee -a "$LOG_FILE" >>"$efile") | eval "$comp_cmd" >"$out" ); then
          ok=1; break
        else
          log "DOCKER|ERROR|[${dname}] pv+progress pipeline failed (attempt $attempt)"
        fi
      else
        if ( set -o pipefail; ${IO_PREFIX:+$IO_PREFIX }tar cPf - -C "${SRC_DIR}" "${dname}" "${TAR_OPTIONS[@]}" "${exclude_opts[@]}" 2>>"$efile" | pv -s "$dir_size" 2>>"$efile" | eval "$comp_cmd" >"$out" ); then
          ok=1; break
        else
          log "DOCKER|ERROR|[${dname}] pv pipeline failed (attempt $attempt)"
        fi
      fi
    else
      if ( set -o pipefail; ${IO_PREFIX:+$IO_PREFIX }tar cPf - -C "${SRC_DIR}" "${dname}" "${TAR_OPTIONS[@]}" "${exclude_opts[@]}" 2>>"$efile" | eval "$comp_cmd" >"$out" ); then
        ok=1; break
      else
        log "DOCKER|ERROR|[${dname}] basic pipeline failed (attempt $attempt)"
      fi
    fi
    attempt=$((attempt+1))
    sleep "$RETRY_DELAY"
  done
  # Finalize status
  if [ $ok -eq 1 ]; then
    local size_bytes size_human
    size_bytes=$(safe_size_bytes "$out")
    if [[ "$size_bytes" =~ ^[0-9]+$ ]] && [ "$size_bytes" -gt 0 ]; then
      size_human=$(bytes_to_human "$size_bytes")
      log "DOCKER|INFO|[${dname}] compressed -> ${size_human} (${size_bytes} bytes)"
    else
      size_human="0B"
      log "DOCKER|WARN|[${dname}] compressed size unknown (0B)"
    fi
    write_status "$dname" "$size_human" "$size_bytes" "$sfile"
  else
    write_status "$dname" FAILED 0 "$sfile"
    log "DOCKER|ERROR|${dname} compression failed after ${RETRIES} attempts (see ${efile})"
  fi
}
# Evaluate required & free space
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
      log "SPACE|WARN|Size unknown for $d"
      _subtotal_unknown=1
      DIR_SIZES["$name"]=0
    fi
  done < <(find "$SRC_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

  if [ ! -d "$DEST_DIR" ]; then
    if mkdir -p "$DEST_DIR" 2>/dev/null; then
      dest_dir_was_missing=1
      log "SPACE|INFO|Created destination: $DEST_DIR"
    else
      log "SPACE|ERROR|Cannot create destination: $DEST_DIR"
      send_notify abort "Destination directory missing" "Path: $DEST_DIR (failed)"
      exit 1
    fi
  fi
# Refresh disk space information
disk_refresh_state
  if ! [[ "$dest_dir_free_bytes" =~ ^[0-9]+$ ]]; then
    log "SPACE|WARN|Free space unknown on $DEST_DIR"
    _dest_unknown=1
  fi

  raw_uncompressed_total=$_subtotal
  # Validate REQUIRED_RATIO numeric
  if ! [[ "$REQUIRED_RATIO" =~ ^[0-9]*\.?[0-9]+$ ]]; then
    log "SPACE|WARN|REQUIRED_RATIO '$REQUIRED_RATIO' invalid; falling back to 1.0"
    REQUIRED_RATIO=1.0
  fi
  # Clamp ratio bounds
  awk_ratio_clamped=$(awk -v r="$REQUIRED_RATIO" 'BEGIN{ if(r<=0) r=1; if(r>1) r=1; printf "%f", r }')
  REQUIRED_RATIO="$awk_ratio_clamped"
  estimated_compressed_total=$(awk -v s="$_subtotal" -v r="$REQUIRED_RATIO" 'BEGIN{printf "%d", s*r}')
  required=$((estimated_compressed_total + LOW_SPACE_MARGIN))
  if [ $_subtotal_unknown -eq 1 ] || [ $_dest_unknown -eq 1 ]; then
    log "SPACE|WARN|Proceeding despite undetermined required or free space (local destination)"
  fi

  log "SPACE|INFO|Estimation: raw=$_subtotal bytes ratio=${REQUIRED_RATIO} -> estimated=${estimated_compressed_total} required=${required} (margin=${LOW_SPACE_MARGIN})"
  if [ $_dest_unknown -eq 0 ] && [ "$dest_dir_free_bytes" -lt "$required" ]; then
    case "$LOW_SPACE_ACTION" in
      abort)
        free_human=$(bytes_to_human "$dest_dir_free_bytes"); req_human=$(bytes_to_human "$required")
        log "SPACE|ERROR|Insufficient free space (need=$required have=$dest_dir_free_bytes)"
        send_notify lowspace "Free = ${free_human}\nRequired = ${req_human}\nAction = abort\nPath: $DEST_DIR"; exit 1 ;;
      warn)
        free_human=$(bytes_to_human "$dest_dir_free_bytes"); req_human=$(bytes_to_human "$required")
        low_space_note="Low space warning: Free = ${free_human}, Required = ${req_human}" ;;
      partial)
        free_human=$(bytes_to_human "$dest_dir_free_bytes"); req_human=$(bytes_to_human "$required")
        low_space_note="Partial mode: Free = ${free_human}, Required = ${req_human}" ;;
      *)
        log "SPACE|ERROR|Unknown LOW_SPACE_ACTION='$LOW_SPACE_ACTION'"; send_notify lowspace "Unknown LOW_SPACE_ACTION" "$LOW_SPACE_ACTION"; exit 1 ;;
    esac
  else
    free_human=$(bytes_to_human "$dest_dir_free_bytes")
    req_human=$(bytes_to_human "$required")
    log "SPACE|INFO|Free space OK: Free = ${free_human}, Required = ${req_human}"
  fi
}
# Prune old backups & logs
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
  log "CLEANUP|INFO|Cleanup removed ${removed_backups} old backups and ${removed_logs} old logs"
}
# Assemble space/utilization summary
build_space_block() {
  [[ -z "${free_human:-}" ]] && free_human=$( [[ "$dest_dir_free_bytes" =~ ^[0-9]+$ ]] && bytes_to_human "$dest_dir_free_bytes" || echo "Unknown" )
  [[ -z "${req_human:-}" ]] && req_human=$( [[ "$required" =~ ^[0-9]+$ ]] && bytes_to_human "$required" || echo "Unknown" )
  local out="Space: Free = ${free_human}, Required = ${req_human}"$'\n'
  if [[ "$raw_uncompressed_total" =~ ^[0-9]+$ ]] && [[ "$estimated_compressed_total" =~ ^[0-9]+$ ]]; then
    out+="Compression Estimation: Raw = $(bytes_to_human "$raw_uncompressed_total"), Ratio = ${REQUIRED_RATIO}, Estimated = $(bytes_to_human "$estimated_compressed_total")"$'\n'
  fi
  if [ "$pct_free_int" -ge 0 ]; then
    out+="Utilization: Total = $(bytes_to_human "$dest_dir_total_bytes"), Used = $(bytes_to_human "$dest_dir_used_bytes"), Free = $(bytes_to_human "$dest_dir_free_bytes"), Free % = ${pct_free_int}%"$'\n'
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

# == Main Execution ===
main() {
  # Record start time and announce start
  start_time=$(date +%s)
  log "BACKUP|INFO|Scheduled $SRC_DIR_NAME backup start: $(date)"
  # Pruning of old backups/logs
  cleanup_old_artifacts
  assess_space
# Set directory for appdata backup
  backup_dir="${DEST_DIR}/backup_${DATETIME}"
  if [ ! -d "$backup_dir" ]; then
    ensure_dir "$backup_dir" 775 "$LOG_OWNER"
  fi
  # Location for transient status/error artifacts
  STATUS_DIR="${TMP_DIR:-$backup_dir}"
# Stop containers except those in skip list
  log "DOCKER|INFO|Docker $SRC_DIR_NAME backup, stopping containers"
# Get list of running container names directly
  mapfile -t CONTAINERS < <(docker ps --format '{{.Names}}' 2>/dev/null | sort || true)
  if [ ${#CONTAINERS[@]} -eq 0 ]; then
    CONTAINERS=()
  fi
  STOP_CONTAINERS=()
  for container in "${CONTAINERS[@]}"; do
    [[ -z "$container" ]] && continue
    if is_skipped "$container"; then
      log "DOCKER|INFO|Skip ${container} (user skip list)"
      continue
    fi
    log "DOCKER|INFO|Queue stop ${container}"
    STOP_CONTAINERS+=("$container")
  done
  log "DOCKER|INFO|Containers to stop: ${#STOP_CONTAINERS[@]} (of ${#CONTAINERS[@]} running)"
# Stop all target containers
  if [ "${#STOP_CONTAINERS[@]}" -gt 0 ]; then
    docker stop "${STOP_CONTAINERS[@]}" >/dev/null 2>&1 || true
  fi
    log "DOCKER|INFO|Compressing Docker $SRC_DIR_NAME for backup"
# Directories checks before starting
  if [ ! -d "$SRC_DIR" ]; then
    log "DOCKER|ERROR|Source directory does not exist: $SRC_DIR"
    send_notify abort "Source directory missing" "Path: $SRC_DIR"
    exit 1
  fi
  child_count=$(find "$SRC_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || true)
    log "DOCKER|INFO|Found $child_count subdirectories in $SRC_DIR"
  if [ "$child_count" -eq 0 ]; then
    log "DOCKER|WARN|No containers/subdirectories found in $SRC_DIR; nothing to back up"
    exit 0
  fi
# Processing backups
  while IFS= read -r -d '' file; do
    dir_name="$(basename "$file")"
    log "DOCKER|INFO|Processing directory: $dir_name"
    err_file="${STATUS_DIR}/${dir_name}.err"
    status_file="${STATUS_DIR}/${dir_name}.status"
    rm -f -- "$err_file" "$status_file"
    # Check skip list
    if is_skipped "$dir_name"; then
      log "DOCKER|INFO|Skipping backup for $dir_name (user specified)"
      printf "%s: SKIPPED(User specified)|0\n" "$dir_name" >"$status_file"
      continue
    fi
    archive_name="${dir_name}.tar.gz"
    archive_path="${backup_dir}/${archive_name}"
    log "DOCKER|INFO|Compress $file to $archive_path..."
# Job concurrency control
  wait_for_slot
  # Per-container free-space check using precomputed size
  dir_size_bytes="${DIR_SIZES[$dir_name]:-0}"
  if ! [[ "$dir_size_bytes" =~ ^[0-9]+$ ]] || [ "$dir_size_bytes" -eq 0 ]; then
    dir_size_bytes=$(safe_size_bytes "${SRC_DIR}/${dir_name}")
  fi
  # Refresh free space only every N containers to reduce df calls
  container_index=${container_index:-0}
  if (( container_index % DF_REFRESH_INTERVAL == 0 )) || [ -z "${cached_dest_free:-}" ]; then
    disk_refresh_state
    cached_dest_free="$dest_dir_free_bytes"
  fi
  dest_free_now="$cached_dest_free"
  container_index=$((container_index+1))
  if [[ "$dir_size_bytes" =~ ^[0-9]+$ ]] && [[ "$dest_free_now" =~ ^[0-9]+$ ]]; then
    need=$(awk -v s="$dir_size_bytes" -v r="$REQUIRED_RATIO" -v m="$LOW_SPACE_MARGIN" 'BEGIN{printf "%d", s*r + m}')
    if [ "$dest_free_now" -lt "$need" ]; then
      need_human=$(bytes_to_human "$need")
      avail_human=$(bytes_to_human "$dest_free_now")
      log "SPACE|WARN|Insufficient free space (ratio ${REQUIRED_RATIO}) for ${dir_name}: need=${need_human} (${need}), available=${avail_human} (${dest_free_now}); skipping"
      printf "%s: SKIPPED(Disk space low)|0\n" "$dir_name" >"$status_file"
      continue
    fi
  else
    log "SPACE|ERROR|could not determine size/free-space for ${dir_name}; proceeding (may fail)"
  fi
# Run compress_job in background
  compress_job "$dir_name" "$archive_path" "$err_file" "$status_file" &
  done < <(find "${SRC_DIR}" -type d -maxdepth 1 -mindepth 1 -print0)
# Wait for background compression jobs to finish
  wait
  # Post-compression integrity checks to catch silent corruption
  shopt -s nullglob
  for sf in "${STATUS_DIR}"/*.status; do
    [ -s "$sf" ] || continue
    line=$(head -n1 "$sf")
    name=$(printf "%s" "$line" | cut -d: -f1)
    rest=$(printf "%s" "$line" | cut -d: -f2- | sed 's/^ //')
    label=$(printf "%s" "$rest" | cut -d'|' -f1)
    # Skip verification for already FAILED or SKIPPED entries
    if [[ "$label" == FAILED ]] || [[ "$label" == SKIPPED* ]]; then
      continue
    fi
    archive_path="${backup_dir}/${name}.tar.gz"
    err_file="${STATUS_DIR}/${name}.err"
    # gzip/pigz integrity test
    verifier="gzip -t"
    if command -v pigz >/dev/null 2>&1; then verifier="pigz -t"; fi
    if ! $verifier "$archive_path" >/dev/null 2>>"$err_file"; then
      log "VERIFY|ERROR|Integrity check failed (gzip test): ${name}"
      printf "%s: FAILED|0\n" "$name" >"$sf"
      continue
    fi
    # Tar readability sanity check (list first entry)
    if ! ( set -o pipefail; tar -tzf "$archive_path" 2>>"$err_file" | head -n 1 >/dev/null ); then
      log "VERIFY|ERROR|Integrity check failed (tar list): ${name}"
      printf "%s: FAILED|0\n" "$name" >"$sf"
      continue
    fi
  done
  shopt -u nullglob
# == Aggregate per-job status -> report ===
  backup_report=""
  shopt -s nullglob
  status_files=()
  for f in "${STATUS_DIR}"/*.status; do [ -e "$f" ] && status_files+=("$f"); done
# Initialize counts
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
          err_file="${STATUS_DIR}/${name}.err"
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
# Summarize results
  total_count=$((ok_count + failed_count + skipped_count))
  total_human=$(bytes_to_human "$total_bytes")
  summary_header="Docker: Total ${total_count}, OK ${ok_count}, FAILED ${failed_count}, SKIPPED ${skipped_count} — Size: ${total_human}"
    log "DOCKER|INFO|Backup report: ${summary_header}"
  while IFS= read -r _l; do 
    [[ -z "$_l" ]] && continue
    if [[ "$_l" =~ FAILED ]]; then
      log "DOCKER|ERROR|$_l"
    elif [[ "$_l" =~ SKIPPED ]]; then
      log "DOCKER|WARN|$_l"
    else
      log "DOCKER|INFO|$_l"
    fi
  done <<< "$backup_report"
# Start containers again
  if [ "$failed_count" -eq 0 ]; then
    log "DOCKER|INFO|Docker $SRC_DIR_NAME backup OK, restarting containers"
  else
    log "DOCKER|ERROR|Docker $SRC_DIR_NAME backup FAILED"
  fi
# Start containers in batch then verify
if [ "${#STOP_CONTAINERS[@]}" -gt 0 ]; then
  docker start "${STOP_CONTAINERS[@]}" >/dev/null 2>&1 || true
  for container in "${STOP_CONTAINERS[@]}"; do
    running=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo false)
    if [[ "$running" != "true" ]]; then
      log "DOCKER|ERROR|Start container fail: ${container}"
    else
      log "DOCKER|INFO|Started ${container}"
    fi
  done
fi
  log "DOCKER|INFO|Docker backup files are in $backup_dir"

# == Shares Backup Rsync ===
  additional_lines=""
  additional_ok=0
  additional_fail=0
  additional_skip=0
  additional_total=0
  shares_total_bytes=0
# Rsync shares backup
  log "SHARES|INFO|Starting Shares backup phase with ${#ADD_SHARES[@]} shares defined"
  if [ ${#ADD_SHARES[@]} -gt 0 ]; then
    for desc in "${ADD_SHARES[@]}"; do
      share_name=""; share_src=""; share_dest=""; share_excludes=""; share_excludes_file=""
      for kv in $desc; do
        key="${kv%%=*}"; val="${kv#*=}"
        case "$key" in
          name) share_name="$val";;
          src) share_src="$val";;
          dest) share_dest="$val";;
          excludes) share_excludes="$val";;
          excludes_file) share_excludes_file="$val";;
        esac
      done
      [ -z "$share_name" ] && share_name="share_$additional_total"
      additional_total=$((additional_total+1))
      if [ ! -d "$share_src" ]; then
        log "SHARES|WARN|[share: $share_name] source missing: $share_src (skipping)"
        additional_lines+="🔵 $share_name: SKIPPED (missing source)"$'\n'
        additional_skip=$((additional_skip+1))
        continue
      fi
      if [ ! -d "$share_dest" ]; then
        if ensure_dir "$share_dest" 775 "$LOG_OWNER"; then
          log "SHARES|INFO|[share: $share_name] created destination: $share_dest"
        else
          log "SHARES|ERROR|[share: $share_name] cannot create destination: $share_dest"
          additional_lines+="🔴 $share_name: FAILED (dest create)"$'\n'
          additional_fail=$((additional_fail+1))
          continue
        fi
      fi
      tmp_rsync_log=$(mktemp /tmp/add_rsync_"${share_name}".XXXXXX)
      rsync_excludes=()
      if [ -n "$share_excludes" ]; then
        IFS=', ' read -r -a _exarr <<< "$share_excludes"
        for pat in "${_exarr[@]}"; do [ -n "$pat" ] && rsync_excludes+=("--exclude=$pat"); done
      fi
      if [ -n "$share_excludes_file" ]; then
        if [ -f "$share_excludes_file" ]; then
          rsync_excludes+=("--exclude-from=$share_excludes_file")
          log "SHARES|INFO|[share: $share_name] using excludes_file: $share_excludes_file"
        else
          log "SHARES|WARN|[share: $share_name] excludes_file missing: $share_excludes_file (ignored)"
        fi
      fi
      rsync_cmd=(rsync "${ADD_RSYNC_BASE_ARGS[@]}" "${rsync_excludes[@]}" "$share_src/" "$share_dest/")
      RSYNC_IO_PREFIX=""
      if [ "$ADD_USE_IONICE" = true ]; then
        if command -v ionice >/dev/null 2>&1; then
          RSYNC_IO_PREFIX="ionice -c${RSYNC_IONICE_CLASS} -n${RSYNC_IONICE_PRIO} nice -n ${RSYNC_NICE}"
        else
          RSYNC_IO_PREFIX="nice -n ${RSYNC_NICE}"
        fi
      fi
      if [ -n "$RSYNC_IO_PREFIX" ]; then
        rsync_cmd=(bash -c "$RSYNC_IO_PREFIX $(printf '%q ' rsync) $(printf '%q ' "${ADD_RSYNC_BASE_ARGS[@]}") $(printf '%q ' "${rsync_excludes[@]}") $(printf '%q' "$share_src/") $(printf '%q' "$share_dest/")")
      fi
      log "SHARES|INFO|[share: $share_name] Running (io_prefix='${RSYNC_IO_PREFIX:-none}'): $(printf '%q ' "${rsync_cmd[@]}")"
      set +e
      set -o pipefail
      "${rsync_cmd[@]}" 2>&1 | tee "$tmp_rsync_log" | while IFS= read -r line; do
        [ -n "$line" ] && log "SHARES|INFO|[rsync: $share_name] $line"
      done
      rstat=${PIPESTATUS[0]}
      set -e
      if [ "$rstat" -ne 0 ]; then
        case $rstat in
          23) rdesc="Partial transfer";;
          24) rdesc="Source vanished";;
          10) rdesc="Socket I/O";;
          11) rdesc="File I/O";;
          12) rdesc="Protocol stream";;
          30) rdesc="Timeout";;
          *) rdesc="Exit $rstat";;
        esac
        additional_lines+="🔴 $share_name: FAILED ($rdesc)"$'\n'
        additional_fail=$((additional_fail+1))
        log "SHARES|ERROR|[share: $share_name] rsync failed code=$rstat desc=$rdesc (see $tmp_rsync_log)"
        continue
      fi
      declare -A RSYNC_PATTERNS=(
        ["Total transferred file size"]=total_tx_bytes
        ["Number of regular files transferred"]=files_tx
        ["Number of deleted files"]=del_count
        ["Total bytes sent"]=bytes_sent
      )
      total_tx_bytes=0 files_tx=0 del_count=0 bytes_sent=0
      for pat in "${!RSYNC_PATTERNS[@]}"; do
        raw=$(grep -i "$pat" "$tmp_rsync_log" | tail -n1 | sed -E 's/^[^:]*:[[:space:]]*([0-9,]+).*/\1/' | tr -d ',' || echo 0)
        [[ "$raw" =~ ^[0-9]+$ ]] || raw=0
        var_name="${RSYNC_PATTERNS[$pat]}"
        printf -v "$var_name" '%s' "$raw"
      done
      shares_total_bytes=$((shares_total_bytes + total_tx_bytes))
      human_tx=$(bytes_to_human "${total_tx_bytes:-0}")
      human_sent=$(bytes_to_human "${bytes_sent:-0}")
      additional_lines+="🟢 $share_name: transferred ${human_tx}, files ${files_tx}, deleted ${del_count}, sent ${human_sent}"$'\n'
      additional_ok=$((additional_ok+1))
      rm -f "$tmp_rsync_log" 2>/dev/null || true
    done
  fi
# Record runtime AFTER both Docker compression and Shares rsync phases
  full_runtime_secs=$(($(date +%s) - start_time))
  full_runtime_hms=$(format_duration "$full_runtime_secs")
  log "BACKUP|INFO|Scheduled backup end runtime: ${full_runtime_hms}"
# Build notification body
  final_body="Runtime: ${full_runtime_hms}"$'\n\n'
  final_body+="${summary_header}"$'\n'"${backup_report}"$'\n'
  if [ ${additional_total} -gt 0 ]; then
    shares_total_human=$(bytes_to_human "${shares_total_bytes:-0}")
    shares_summary_header="Shares: Total ${additional_total}, OK ${additional_ok}, FAILED ${additional_fail}, SKIPPED ${additional_skip} — Size: ${shares_total_human}"
    final_body+="${shares_summary_header}"$'\n'
    final_body+="${additional_lines}"$'\n'
  fi
  final_body+=$(build_space_block)
# Compute combined counts (Docker + Shares) and overall status
  docker_counts="${ok_count}/${total_count}"
  if [ ${additional_total} -gt 0 ]; then
    shares_counts="${additional_ok}/${additional_total}"
    counts="D ${docker_counts}; S ${shares_counts}"
  else
    counts="D ${docker_counts}"
  fi
# Compute overall status for both Docker and Shares failures
  if [ "$failed_count" -eq 0 ] && [ "${additional_fail:-0}" -eq 0 ]; then
    status_text="OK"
  else
    if [ "$failed_count" -gt 0 ] && [ "${additional_fail:-0}" -gt 0 ]; then
      status_text="FAILED (Docker & Shares)"
    elif [ "$failed_count" -gt 0 ]; then
      status_text="FAILED (Docker)"
    else
      status_text="FAILED (Shares)"
    fi
  fi
# Send consolidated final notification
  send_notify final "$failed_count" "${additional_fail:-0}" "$docker_counts" "${shares_counts:-}" "$final_body"
# Remove backup_dir if failed and KEEP_PARTIAL is false, otherwise keep as before
  if [ "$failed_count" -gt 0 ]; then
    if [ "${KEEP_PARTIAL}" != "true" ]; then
      rm -r "$backup_dir"
    else
      log "DOCKER|INFO|Keeping partial backup artifacts in $backup_dir for inspection"
    fi
  fi
# Cleanup temporary .err files
  if [ "$KEEP_TEMP_ERR" != "true" ]; then
    find "${backup_dir}" -type f -name '*.err' -delete 2>/dev/null || true
  fi
  exit 0
}
# Main Entry Point
main "$@"