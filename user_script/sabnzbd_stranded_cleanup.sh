#!/bin/bash

###############################################################################
# SABnzbd Stranded Completed Download Cleanup v1.1
#
# PURPOSE
# -------
# Safely reclaim completed SABnzbd download folders after Sonarr or Radarr has
# already imported the payload, while leaving SABnzbd history untouched.
#
# This is designed for the Unraid User Scripts plugin. A nightly schedule is
# recommended after the configuration and dry-run output have been reviewed.
#
# A completed path is eligible only when all of the following are true:
#
#   - SABnzbd reports the job as Completed.
#   - The SAB category maps explicitly to Sonarr or Radarr.
#   - The job is older than MIN_COMPLETED_AGE_HOURS.
#   - The path has not changed for MIN_PATH_STABLE_HOURS.
#   - The download ID is absent from both Arr Activity queues.
#   - The owning Arr has a matching grabbed history event.
#   - The owning Arr has a later downloadFolderImported history event.
#   - Every distinct importedPath still exists as a non-empty library file.
#   - The number of verified imported paths accounts for all remaining source
#     media files. Ambiguous season packs are skipped, not guessed.
#   - Every resolved source/destination path remains below an explicit root.
#   - Unraid Mover is not running at startup, before a quarantine move, or
#     before quarantine purge.
#
# SAFETY MODEL
# ------------
#   - DRY_RUN defaults to true.
#   - Eligible payloads are moved into a manifest-backed quarantine first.
#   - Quarantine is purged only after QUARANTINE_RETENTION_DAYS.
#   - MAX_QUARANTINES_PER_RUN limits the impact of any one run.
#   - Any API, pagination, path, history, or filesystem ambiguity is a skip.
#   - An active Unraid Mover stops the run successfully before further writes.
#   - SAB history is never deleted, archived, or modified.
#   - The script never removes Arr queue/history records or library files.
#
# USAGE
# -----
#   1. Fill in all API keys and confirm every path/path mapping below.
#   2. Run with DRY_RUN=true until every candidate is expected.
#   3. Set DRY_RUN=false to enable quarantine moves.
#   4. Keep PURGE_QUARANTINE=false initially if you want manual review.
#   5. When satisfied, set PURGE_QUARANTINE=true for delayed space recovery.
#
# Optional command-line overrides:
#
#   sabnzbd_stranded_cleanup.sh --dry-run
#   sabnzbd_stranded_cleanup.sh --execute
#   sabnzbd_stranded_cleanup.sh --execute --no-purge
#
###############################################################################

set -uo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

VERSION="1.1"

# ---------------------------------------------------------------------------
# Execution behavior
# ---------------------------------------------------------------------------

DRY_RUN="${DRY_RUN:-true}"
PURGE_QUARANTINE="${PURGE_QUARANTINE:-true}"

# A conservative grace period. Radarr/Sonarr also regard aggressive SAB
# history retention (less than 14 days) as unsafe.
MIN_COMPLETED_AGE_HOURS="${MIN_COMPLETED_AGE_HOURS:-336}"

# Even an old job is protected if anything below its path changed recently.
MIN_PATH_STABLE_HOURS="${MIN_PATH_STABLE_HOURS:-24}"

# Quarantine retention starts when this script moves the payload.
QUARANTINE_RETENTION_DAYS="${QUARANTINE_RETENTION_DAYS:-14}"

# Limit real quarantine moves per run. Zero means unlimited.
MAX_QUARANTINES_PER_RUN="${MAX_QUARANTINES_PER_RUN:-10}"

# Refuse to overlap Unraid Mover. The process pattern matches current and
# legacy Unraid mover entry points and is shared with mover_audit.sh.
MOVER_GUARD_ENABLED="${MOVER_GUARD_ENABLED:-true}"
MOVER_PROCESS_PATTERN="${MOVER_PROCESS_PATTERN:-(^|/)(mover|mover\.old)( |$)|mover\.php}"

# Send a normal Unraid notification when a scheduled cleanup is skipped because
# Mover is still active. The script exits successfully so User Scripts does not
# report the deliberate skip as a failure.
NOTIFY_MOVER_SKIP="${NOTIFY_MOVER_SKIP:-true}"

# ---------------------------------------------------------------------------
# Sonarr
# ---------------------------------------------------------------------------

SONARR_ENABLED="${SONARR_ENABLED:-true}"
SONARR_URL="${SONARR_URL:-http://192.168.50.4:8989}"
SONARR_API_KEY="${SONARR_API_KEY:-PUT_YOUR_SONARR_API_KEY_HERE}"

# Semicolon-separated container-prefix|host-prefix mappings. The script first
# tries importedPath exactly as Arr reports it, then tries each mapping.
SONARR_IMPORT_PATH_MAPS="${SONARR_IMPORT_PATH_MAPS:-/media/series|/mnt/user/media/series;/data/media/series|/mnt/user/media/series;/tv|/mnt/user/media/series}"

# Semicolon-separated host roots. Every verified Sonarr importedPath must
# resolve below one of these roots.
SONARR_LIBRARY_ROOTS="${SONARR_LIBRARY_ROOTS:-/mnt/user/media/series}"

# ---------------------------------------------------------------------------
# Radarr
# ---------------------------------------------------------------------------

RADARR_ENABLED="${RADARR_ENABLED:-true}"
RADARR_URL="${RADARR_URL:-http://192.168.50.4:7878}"
RADARR_API_KEY="${RADARR_API_KEY:-PUT_YOUR_RADARR_API_KEY_HERE}"

RADARR_IMPORT_PATH_MAPS="${RADARR_IMPORT_PATH_MAPS:-/media/movies|/mnt/user/media/movies;/data/media/movies|/mnt/user/media/movies;/movies|/mnt/user/media/movies}"
RADARR_LIBRARY_ROOTS="${RADARR_LIBRARY_ROOTS:-/mnt/user/media/movies}"

# ---------------------------------------------------------------------------
# SABnzbd
# ---------------------------------------------------------------------------

SAB_URL="${SAB_URL:-http://192.168.50.4:8080}"
SAB_API_KEY="${SAB_API_KEY:-PUT_YOUR_SABNZBD_API_KEY_HERE}"

# Host-visible completed download layout. These defaults match the repository's
# arr_health_activity.sh configuration.
SAB_COMPLETE_ROOT="${SAB_COMPLETE_ROOT:-/mnt/user/media/net/complete}"

SAB_MOVIE_CATEGORY="${SAB_MOVIE_CATEGORY:-movie}"
SAB_MOVIE_DIR="${SAB_MOVIE_DIR:-${SAB_COMPLETE_ROOT}/movies}"

SAB_TV_CATEGORY="${SAB_TV_CATEGORY:-tv}"
SAB_TV_DIR="${SAB_TV_DIR:-${SAB_COMPLETE_ROOT}/series}"

# SAB may return its container-side path. Configure the completed root exactly
# as SAB sees it. Leave empty to disable prefix mapping; basename fallback under
# the category root remains available and is still root-validated.
SAB_CONTAINER_COMPLETE_ROOT="${SAB_CONTAINER_COMPLETE_ROOT:-}"

# ---------------------------------------------------------------------------
# Quarantine, logs, notifications, and APIs
# ---------------------------------------------------------------------------

# Keep quarantine outside SAB_COMPLETE_ROOT but preferably on the same Unraid
# share/filesystem so the move is fast and recoverable.
QUARANTINE_DIR="${QUARANTINE_DIR:-/mnt/user/media/net/sabnzbd_cleanup_quarantine}"

LOG_DIR="${LOG_DIR:-/mnt/user/cloud/logs/sabnzbd_stranded_cleanup}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/sabnzbd_stranded_cleanup.log}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-2097152}"
LOG_KEEP="${LOG_KEEP:-2}"

SEND_NOTIFICATIONS="${SEND_NOTIFICATIONS:-true}"
NOTIFY_DRY_RUN="${NOTIFY_DRY_RUN:-false}"
NOTIFY="${NOTIFY:-/usr/local/emhttp/webGui/scripts/notify}"

LOCK_FILE="${LOCK_FILE:-/tmp/sabnzbd_stranded_cleanup.lock}"

SAB_HISTORY_PAGE_SIZE="${SAB_HISTORY_PAGE_SIZE:-500}"
SAB_HISTORY_MAX_PAGES="${SAB_HISTORY_MAX_PAGES:-100}"
ARR_QUEUE_PAGE_SIZE="${ARR_QUEUE_PAGE_SIZE:-10000}"
ARR_HISTORY_PAGE_SIZE="${ARR_HISTORY_PAGE_SIZE:-1000}"

CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-10}"
CURL_MAX_TIME="${CURL_MAX_TIME:-60}"
TLS_VERIFY="${TLS_VERIFY:-true}"

###############################################################################
# INTERNAL STATE
###############################################################################

START_EPOCH="$(date '+%s')"
RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"
TMP_DIR=""

SAB_HISTORY_FILE=""
SAB_QUEUE_FILE=""
SONARR_QUEUE_FILE=""
RADARR_QUEUE_FILE=""

SAB_MOVIE_DIR_REAL=""
SAB_TV_DIR_REAL=""
QUARANTINE_DIR_REAL=""

SCANNED=0
COMPLETED_SCANNED=0
TOO_YOUNG=0
QUEUE_PROTECTED=0
PATH_MISSING=0
PATH_UNSTABLE=0
HISTORY_UNPROVEN=0
DESTINATION_UNVERIFIED=0
SOURCE_UNACCOUNTED=0
SAFETY_SKIPPED=0
MOVER_PROTECTED=0
ELIGIBLE=0
QUARANTINED=0
PURGED=0
ERRORS=0
BYTES_ELIGIBLE=0
BYTES_QUARANTINED=0
BYTES_PURGED=0

QUARANTINE_DETAILS=()
PURGE_DETAILS=()

MOVER_GUARD_TRIGGERED=false
MOVER_GUARD_CONTEXT=""

###############################################################################
# GENERAL HELPERS
###############################################################################

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

is_true() {
  case "${1:-}" in
    1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]) return 0 ;;
    *) return 1 ;;
  esac
}

is_false() {
  case "${1:-}" in
    0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff]) return 0 ;;
    *) return 1 ;;
  esac
}

log() {
  local level="$1"
  shift

  local line
  line="$(timestamp) [$level] $*"

  if [[ -n "$LOG_FILE" && -d "${LOG_FILE%/*}" ]]; then
    printf '%s\n' "$line" | tee -a "$LOG_FILE"
  else
    printf '%s\n' "$line"
  fi
}

die() {
  ((ERRORS++)) || true
  log "ERROR" "$*"
  exit 1
}

runtime() {
  local seconds=$(( $(date '+%s') - START_EPOCH ))
  printf '%dh:%dm:%ds' \
    $((seconds / 3600)) \
    $(((seconds % 3600) / 60)) \
    $((seconds % 60))
}

bytes_human() {
  local bytes="${1:-0}"

  awk -v b="$bytes" '
    BEGIN {
      if (b >= 1099511627776) printf "%.2f TB", b / 1099511627776
      else if (b >= 1073741824) printf "%.2f GB", b / 1073741824
      else if (b >= 1048576) printf "%.2f MB", b / 1048576
      else if (b >= 1024) printf "%.2f KB", b / 1024
      else printf "%d B", b
    }
  '
}

stat_size() {
  stat -c '%s' -- "$1" 2>/dev/null || stat -f '%z' -- "$1" 2>/dev/null || printf '0'
}

stat_mtime() {
  stat -c '%Y' -- "$1" 2>/dev/null || stat -f '%m' -- "$1" 2>/dev/null || printf '0'
}

stat_device() {
  stat -c '%d' -- "$1" 2>/dev/null || stat -f '%d' -- "$1" 2>/dev/null || printf ''
}

sanitize_component() {
  printf '%s' "$1" |
    tr '/\n\r\t' '____' |
    sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^[_ .-]+//; s/[_ .-]+$//' |
    cut -c 1-120
}

cleanup_tmp() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}

on_exit() {
  local exit_code=$?
  cleanup_tmp
  return "$exit_code"
}

trap on_exit EXIT
trap 'exit 130' INT TERM

###############################################################################
# COMMAND-LINE OVERRIDES
###############################################################################

usage() {
  cat <<'EOF'
Usage: sabnzbd_stranded_cleanup.sh [options]

Options:
  --dry-run     Report eligible payloads without moving or purging anything.
  --execute     Enable quarantine moves (subject to every safety check).
  --purge       Enable delayed quarantine purge.
  --no-purge    Disable delayed quarantine purge.
  --help        Show this help.
EOF
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      --execute) DRY_RUN=false ;;
      --purge) PURGE_QUARANTINE=true ;;
      --no-purge) PURGE_QUARANTINE=false ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
    shift
  done
}

###############################################################################
# INITIALIZATION / VALIDATION
###############################################################################

rotate_logs() {
  [[ -f "$LOG_FILE" ]] || return 0

  local size
  size="$(stat_size "$LOG_FILE")"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  (( size >= LOG_MAX_BYTES )) || return 0

  if (( LOG_KEEP <= 0 )); then
    : > "$LOG_FILE"
    return 0
  fi

  rm -f -- "${LOG_FILE}.${LOG_KEEP}" 2>/dev/null || true

  local i
  for ((i=LOG_KEEP-1; i>=1; i--)); do
    if [[ -f "${LOG_FILE}.${i}" ]]; then
      mv -f -- "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
    fi
  done

  mv -f -- "$LOG_FILE" "${LOG_FILE}.1"
}

require_commands() {
  local command_name
  local missing=0

  for command_name in awk basename curl cut date dirname find flock jq mkdir mktemp mv realpath sed sort stat tee tr wc; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      log "ERROR" "Required command not found: $command_name"
      missing=1
    fi
  done

  if is_true "$MOVER_GUARD_ENABLED" && ! command -v pgrep >/dev/null 2>&1; then
    log "ERROR" "Required Mover guard command not found: pgrep"
    missing=1
  fi

  (( missing == 0 )) || die "One or more required commands are unavailable."
}

validate_boolean() {
  local name="$1"
  local value="$2"
  if ! is_true "$value" && ! is_false "$value"; then
    die "$name must be true/false, yes/no, on/off, or 1/0."
  fi
}

validate_integer() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be a non-negative integer."
}

validate_api_key() {
  local app="$1"
  local key="$2"

  [[ -n "$key" ]] || die "$app API key is empty."
  [[ "$key" != PUT_YOUR_* ]] || die "$app API key still contains its placeholder value."
}

validate_library_roots() {
  local app="$1"
  local roots="$2"
  local root_list=()
  local root
  local valid=0

  IFS=';' read -r -a root_list <<<"$roots"

  for root in "${root_list[@]}"; do
    [[ -n "$root" ]] || continue

    if [[ -d "$root" ]]; then
      root="$(realpath -- "$root")" || continue
      dangerously_broad_path "$root" && \
        die "$app library root is dangerously broad: $root"
      ((valid++)) || true
    else
      log "WARNING" "$app library root does not exist and cannot verify imports: $root"
    fi
  done

  (( valid > 0 )) || die "$app has no accessible library root for import verification."
}

dangerously_broad_path() {
  case "$1" in
    /|/mnt|/mnt/user|/mnt/user/media) return 0 ;;
    *) return 1 ;;
  esac
}

canonicalize_target() {
  local target="$1"
  local cursor="$target"
  local suffix=""
  local component
  local parent
  local resolved

  while [[ ! -e "$cursor" ]]; do
    component="$(basename -- "$cursor")"
    parent="$(dirname -- "$cursor")"

    [[ "$parent" != "$cursor" ]] || return 1
    suffix="/${component}${suffix}"
    cursor="$parent"
  done

  resolved="$(realpath -- "$cursor")" || return 1
  printf '%s%s' "$resolved" "$suffix"
}

path_is_below() {
  local child="$1"
  local root="$2"
  [[ "$child" == "$root"/* && "$child" != "$root" ]]
}

paths_overlap() {
  local first="$1"
  local second="$2"

  [[ "$first" == "$second" || "$first" == "$second"/* || "$second" == "$first"/* ]]
}

validate_environment() {
  validate_boolean "DRY_RUN" "$DRY_RUN"
  validate_boolean "PURGE_QUARANTINE" "$PURGE_QUARANTINE"
  validate_boolean "MOVER_GUARD_ENABLED" "$MOVER_GUARD_ENABLED"
  validate_boolean "NOTIFY_MOVER_SKIP" "$NOTIFY_MOVER_SKIP"
  validate_boolean "SONARR_ENABLED" "$SONARR_ENABLED"
  validate_boolean "RADARR_ENABLED" "$RADARR_ENABLED"
  validate_boolean "SEND_NOTIFICATIONS" "$SEND_NOTIFICATIONS"
  validate_boolean "NOTIFY_DRY_RUN" "$NOTIFY_DRY_RUN"
  validate_boolean "TLS_VERIFY" "$TLS_VERIFY"

  validate_integer "MIN_COMPLETED_AGE_HOURS" "$MIN_COMPLETED_AGE_HOURS"
  validate_integer "MIN_PATH_STABLE_HOURS" "$MIN_PATH_STABLE_HOURS"
  validate_integer "QUARANTINE_RETENTION_DAYS" "$QUARANTINE_RETENTION_DAYS"
  validate_integer "MAX_QUARANTINES_PER_RUN" "$MAX_QUARANTINES_PER_RUN"
  validate_integer "SAB_HISTORY_PAGE_SIZE" "$SAB_HISTORY_PAGE_SIZE"
  validate_integer "SAB_HISTORY_MAX_PAGES" "$SAB_HISTORY_MAX_PAGES"
  validate_integer "ARR_QUEUE_PAGE_SIZE" "$ARR_QUEUE_PAGE_SIZE"
  validate_integer "ARR_HISTORY_PAGE_SIZE" "$ARR_HISTORY_PAGE_SIZE"

  (( SAB_HISTORY_PAGE_SIZE > 0 )) || die "SAB_HISTORY_PAGE_SIZE must be greater than zero."
  (( SAB_HISTORY_MAX_PAGES > 0 )) || die "SAB_HISTORY_MAX_PAGES must be greater than zero."
  (( ARR_QUEUE_PAGE_SIZE > 0 )) || die "ARR_QUEUE_PAGE_SIZE must be greater than zero."
  (( ARR_HISTORY_PAGE_SIZE > 0 )) || die "ARR_HISTORY_PAGE_SIZE must be greater than zero."

  validate_api_key "SABnzbd" "$SAB_API_KEY"

  if is_true "$SONARR_ENABLED"; then
    validate_api_key "Sonarr" "$SONARR_API_KEY"
    validate_library_roots "Sonarr" "$SONARR_LIBRARY_ROOTS"
  fi

  if is_true "$RADARR_ENABLED"; then
    validate_api_key "Radarr" "$RADARR_API_KEY"
    validate_library_roots "Radarr" "$RADARR_LIBRARY_ROOTS"
  fi

  [[ -d "$SAB_MOVIE_DIR" ]] || die "SAB movie directory does not exist: $SAB_MOVIE_DIR"
  [[ -d "$SAB_TV_DIR" ]] || die "SAB TV directory does not exist: $SAB_TV_DIR"

  SAB_MOVIE_DIR_REAL="$(realpath -- "$SAB_MOVIE_DIR")" || die "Unable to resolve: $SAB_MOVIE_DIR"
  SAB_TV_DIR_REAL="$(realpath -- "$SAB_TV_DIR")" || die "Unable to resolve: $SAB_TV_DIR"
  QUARANTINE_DIR_REAL="$(canonicalize_target "$QUARANTINE_DIR")" || die "Unable to resolve quarantine target: $QUARANTINE_DIR"

  dangerously_broad_path "$SAB_MOVIE_DIR_REAL" && die "SAB movie directory is dangerously broad: $SAB_MOVIE_DIR_REAL"
  dangerously_broad_path "$SAB_TV_DIR_REAL" && die "SAB TV directory is dangerously broad: $SAB_TV_DIR_REAL"
  dangerously_broad_path "$QUARANTINE_DIR_REAL" && die "Quarantine directory is dangerously broad: $QUARANTINE_DIR_REAL"

  paths_overlap "$SAB_MOVIE_DIR_REAL" "$SAB_TV_DIR_REAL" && die "SAB movie and TV roots must not overlap."
  paths_overlap "$QUARANTINE_DIR_REAL" "$SAB_MOVIE_DIR_REAL" && die "Quarantine and SAB movie roots must not overlap."
  paths_overlap "$QUARANTINE_DIR_REAL" "$SAB_TV_DIR_REAL" && die "Quarantine and SAB TV roots must not overlap."

  if [[ "${SAB_MOVIE_CATEGORY,,}" == "${SAB_TV_CATEGORY,,}" ]]; then
    die "SAB movie and TV categories must be different."
  fi

  if is_true "$MOVER_GUARD_ENABLED" && [[ -z "$MOVER_PROCESS_PATTERN" ]]; then
    die "MOVER_PROCESS_PATTERN cannot be empty while the Mover guard is enabled."
  fi

  if ! is_true "$DRY_RUN"; then
    mkdir -p -- "$QUARANTINE_DIR_REAL/items/Sonarr" "$QUARANTINE_DIR_REAL/items/Radarr" || \
      die "Unable to create quarantine directories."

    QUARANTINE_DIR_REAL="$(realpath -- "$QUARANTINE_DIR_REAL")" || \
      die "Unable to resolve created quarantine directory."
  fi
}

initialize() {
  mkdir -p -- "$LOG_DIR" || {
    printf 'Unable to create log directory: %s\n' "$LOG_DIR" >&2
    exit 1
  }

  rotate_logs
  require_commands

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "INFO" "Another SABnzbd stranded cleanup run is active; exiting."
    exit 0
  fi

  TMP_DIR="$(mktemp -d '/tmp/sabnzbd_stranded_cleanup.XXXXXX')" || \
    die "Unable to create temporary directory."

  SAB_HISTORY_FILE="$TMP_DIR/sab_history.json"
  SAB_QUEUE_FILE="$TMP_DIR/sab_queue.json"
  SONARR_QUEUE_FILE="$TMP_DIR/sonarr_queue.json"
  RADARR_QUEUE_FILE="$TMP_DIR/radarr_queue.json"

  validate_environment
}

###############################################################################
# UNRAID MOVER GUARD
###############################################################################

mover_is_running() {
  is_true "$MOVER_GUARD_ENABLED" || return 1
  pgrep -f "$MOVER_PROCESS_PATTERN" >/dev/null 2>&1
}

notify_mover_skip() {
  local context="$1"

  is_true "$SEND_NOTIFICATIONS" || return 0
  is_true "$NOTIFY_MOVER_SKIP" || return 0
  [[ -x "$NOTIFY" ]] || return 0

  "$NOTIFY" \
    -i normal \
    -s "SABnzbd Stranded Cleanup" \
    -d "Cleanup skipped while Unraid Mover is active" \
    -m "Guard point: ${context}. No further cleanup writes were attempted; the next scheduled run will retry." \
    >/dev/null 2>&1 || true
}

check_mover_guard() {
  local context="$1"

  mover_is_running || return 0

  MOVER_GUARD_TRIGGERED=true
  MOVER_GUARD_CONTEXT="$context"
  ((MOVER_PROTECTED++)) || true

  log "WARNING" "Unraid Mover is running at guard point '$context'."
  log "WARNING" "Stopping cleanup successfully; no further cleanup writes will be attempted."
  notify_mover_skip "$context"

  return 20
}

###############################################################################
# API HELPERS
###############################################################################

curl_common_args() {
  printf '%s\0' \
    --silent \
    --show-error \
    --fail \
    --retry 2 \
    --retry-delay 1 \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time "$CURL_MAX_TIME"

  if ! is_true "$TLS_VERIFY"; then
    printf '%s\0' --insecure
  fi
}

run_curl() {
  local args=()
  while IFS= read -r -d '' arg; do
    args+=("$arg")
  done < <(curl_common_args)

  curl "${args[@]}" "$@"
}

sab_get() {
  local mode="$1"
  local output="$2"
  shift 2

  local query_args=(
    --get
    --data-urlencode "mode=$mode"
    --data-urlencode "output=json"
    --data-urlencode "apikey=$SAB_API_KEY"
  )

  local parameter
  for parameter in "$@"; do
    query_args+=(--data-urlencode "$parameter")
  done

  if ! run_curl "${query_args[@]}" "${SAB_URL%/}/api" -o "$output"; then
    return 1
  fi

  jq empty "$output" >/dev/null 2>&1
}

arr_get() {
  local url="$1"
  local api_key="$2"
  local output="$3"
  shift 3

  local query_args=(--get -H "X-Api-Key: $api_key")
  local parameter

  for parameter in "$@"; do
    query_args+=(--data-urlencode "$parameter")
  done

  if ! run_curl "${query_args[@]}" "$url" -o "$output"; then
    return 1
  fi

  jq empty "$output" >/dev/null 2>&1
}

fetch_sab_history() {
  local slots_file="$TMP_DIR/sab_history_slots.jsonl"
  : > "$slots_file"

  local start=0
  local page=0
  local count
  local output

  while (( page < SAB_HISTORY_MAX_PAGES )); do
    output="$TMP_DIR/sab_history_page_${page}.json"

    if ! sab_get history "$output" "start=$start" "limit=$SAB_HISTORY_PAGE_SIZE"; then
      return 1
    fi

    count="$(jq '.history.slots // [] | length' "$output" 2>/dev/null)" || return 1
    [[ "$count" =~ ^[0-9]+$ ]] || return 1

    jq -c '.history.slots[]?' "$output" >> "$slots_file" || return 1

    (( count == 0 )) && break

    start=$((start + count))
    page=$((page + 1))

    (( count < SAB_HISTORY_PAGE_SIZE )) && break
  done

  if (( page >= SAB_HISTORY_MAX_PAGES && count >= SAB_HISTORY_PAGE_SIZE )); then
    log "ERROR" "SAB history exceeded the configured pagination safety limit."
    return 1
  fi

  jq -s '.' "$slots_file" > "$SAB_HISTORY_FILE" || return 1
}

fetch_sab_queue() {
  sab_get queue "$SAB_QUEUE_FILE" "start=0" "limit=0"
}

fetch_arr_queue() {
  local app="$1"
  local output="$2"
  local base_url
  local api_key
  local unknown_parameter

  case "$app" in
    Sonarr)
      base_url="$SONARR_URL"
      api_key="$SONARR_API_KEY"
      unknown_parameter="includeUnknownSeriesItems=true"
      ;;
    Radarr)
      base_url="$RADARR_URL"
      api_key="$RADARR_API_KEY"
      unknown_parameter="includeUnknownMovieItems=true"
      ;;
    *) return 1 ;;
  esac

  if ! arr_get \
    "${base_url%/}/api/v3/queue" \
    "$api_key" \
    "$output" \
    "page=1" \
    "pageSize=$ARR_QUEUE_PAGE_SIZE" \
    "$unknown_parameter"
  then
    return 1
  fi

  local loaded
  local total
  loaded="$(jq '.records // [] | length' "$output" 2>/dev/null)" || return 1
  total="$(jq '.totalRecords // (.records // [] | length)' "$output" 2>/dev/null)" || return 1

  [[ "$loaded" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || return 1

  if (( loaded < total )); then
    log "ERROR" "$app queue has $total records but only $loaded were loaded; refusing cleanup."
    return 1
  fi
}

fetch_arr_history_for_download() {
  local app="$1"
  local download_id="$2"
  local output="$3"
  local base_url
  local api_key

  case "$app" in
    Sonarr)
      base_url="$SONARR_URL"
      api_key="$SONARR_API_KEY"
      ;;
    Radarr)
      base_url="$RADARR_URL"
      api_key="$RADARR_API_KEY"
      ;;
    *) return 1 ;;
  esac

  if ! arr_get \
    "${base_url%/}/api/v3/history" \
    "$api_key" \
    "$output" \
    "page=1" \
    "pageSize=$ARR_HISTORY_PAGE_SIZE" \
    "sortKey=date" \
    "sortDirection=descending" \
    "downloadId=$download_id"
  then
    return 1
  fi

  local loaded
  local total
  loaded="$(jq '.records // [] | length' "$output" 2>/dev/null)" || return 1
  total="$(jq '.totalRecords // (.records // [] | length)' "$output" 2>/dev/null)" || return 1

  [[ "$loaded" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || return 1

  if (( loaded < total )); then
    log "WARNING" "$app history for download ID '$download_id' was truncated ($loaded/$total)."
    return 1
  fi
}

fetch_required_state() {
  log "INFO" "Fetching SABnzbd history and queue."
  fetch_sab_history || die "Unable to fetch complete SABnzbd history. No cleanup was attempted."
  fetch_sab_queue || die "Unable to fetch SABnzbd queue. No cleanup was attempted."

  if is_true "$SONARR_ENABLED"; then
    log "INFO" "Fetching Sonarr Activity queue."
    fetch_arr_queue Sonarr "$SONARR_QUEUE_FILE" || \
      die "Unable to fetch complete Sonarr queue. No cleanup was attempted."
  else
    printf '{"records":[],"totalRecords":0}\n' > "$SONARR_QUEUE_FILE"
  fi

  if is_true "$RADARR_ENABLED"; then
    log "INFO" "Fetching Radarr Activity queue."
    fetch_arr_queue Radarr "$RADARR_QUEUE_FILE" || \
      die "Unable to fetch complete Radarr queue. No cleanup was attempted."
  else
    printf '{"records":[],"totalRecords":0}\n' > "$RADARR_QUEUE_FILE"
  fi
}

refresh_active_state() {
  fetch_sab_queue || return 1

  if is_true "$SONARR_ENABLED"; then
    fetch_arr_queue Sonarr "$SONARR_QUEUE_FILE" || return 1
  fi

  if is_true "$RADARR_ENABLED"; then
    fetch_arr_queue Radarr "$RADARR_QUEUE_FILE" || return 1
  fi
}

###############################################################################
# TIME / QUEUE HELPERS
###############################################################################

date_to_epoch() {
  local value="$1"
  local normalized

  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
    return 0
  fi

  if date -d "$value" '+%s' >/dev/null 2>&1; then
    date -d "$value" '+%s'
    return 0
  fi

  normalized="${value%%.*}"
  normalized="${normalized%Z}"

  date -j -u -f '%Y-%m-%dT%H:%M:%S' "$normalized" '+%s' 2>/dev/null || printf '0'
}

sab_completed_epoch() {
  local item="$1"
  local value

  value="$(jq -r '.completed // .completed_time // .completedTime // .completionTime // ""' <<<"$item")"
  date_to_epoch "$value"
}

queue_contains_download() {
  local queue_file="$1"
  local download_id="$2"

  jq -e \
    --arg id "$download_id" \
    'any(.records[]?; ((.downloadId // "") | ascii_downcase) == ($id | ascii_downcase))' \
    "$queue_file" >/dev/null 2>&1
}

sab_queue_contains_download() {
  local download_id="$1"

  jq -e \
    --arg id "$download_id" \
    'any(.queue.slots[]?; ((.nzo_id // "") | ascii_downcase) == ($id | ascii_downcase))' \
    "$SAB_QUEUE_FILE" >/dev/null 2>&1
}

download_is_active_anywhere() {
  local download_id="$1"

  sab_queue_contains_download "$download_id" || \
    queue_contains_download "$SONARR_QUEUE_FILE" "$download_id" || \
    queue_contains_download "$RADARR_QUEUE_FILE" "$download_id"
}

###############################################################################
# PATH HELPERS
###############################################################################

owner_for_category() {
  local category="${1,,}"

  if [[ "$category" == "${SAB_TV_CATEGORY,,}" ]]; then
    printf 'Sonarr'
  elif [[ "$category" == "${SAB_MOVIE_CATEGORY,,}" ]]; then
    printf 'Radarr'
  fi
}

root_for_owner() {
  case "$1" in
    Sonarr) printf '%s' "$SAB_TV_DIR_REAL" ;;
    Radarr) printf '%s' "$SAB_MOVIE_DIR_REAL" ;;
  esac
}

library_roots_for_owner() {
  case "$1" in
    Sonarr) printf '%s' "$SONARR_LIBRARY_ROOTS" ;;
    Radarr) printf '%s' "$RADARR_LIBRARY_ROOTS" ;;
  esac
}

path_maps_for_owner() {
  case "$1" in
    Sonarr) printf '%s' "$SONARR_IMPORT_PATH_MAPS" ;;
    Radarr) printf '%s' "$RADARR_IMPORT_PATH_MAPS" ;;
  esac
}

resolve_sab_path() {
  local item="$1"
  local root="$2"
  local storage
  local name
  local candidate=""
  local relative
  local resolved

  storage="$(jq -r '.storage // .path // ""' <<<"$item")"
  name="$(jq -r '.name // .nzb_name // ""' <<<"$item")"

  if [[ -n "$storage" && -e "$storage" ]]; then
    candidate="$storage"
  elif [[ -n "$storage" && -n "$SAB_CONTAINER_COMPLETE_ROOT" && \
          ( "$storage" == "$SAB_CONTAINER_COMPLETE_ROOT" || "$storage" == "$SAB_CONTAINER_COMPLETE_ROOT"/* ) ]]; then
    relative="${storage#"$SAB_CONTAINER_COMPLETE_ROOT"}"
    candidate="${SAB_COMPLETE_ROOT%/}${relative}"
  elif [[ -n "$storage" ]]; then
    candidate="${root%/}/$(basename -- "${storage%/}")"
  elif [[ -n "$name" ]]; then
    candidate="${root%/}/$name"
  else
    return 1
  fi

  [[ -e "$candidate" ]] || return 1
  [[ ! -L "$candidate" ]] || return 1

  resolved="$(realpath -- "$candidate")" || return 1
  path_is_below "$resolved" "$root" || return 1

  printf '%s' "$resolved"
}

resolve_imported_path() {
  local owner="$1"
  local reported="$2"
  local candidate=""
  local resolved
  local mappings
  local mapping
  local from
  local to
  local roots
  local root
  local allowed=false

  if [[ -e "$reported" ]]; then
    candidate="$reported"
  else
    mappings="$(path_maps_for_owner "$owner")"
    local mapping_list=()
    IFS=';' read -r -a mapping_list <<<"$mappings"

    for mapping in "${mapping_list[@]}"; do
      [[ "$mapping" == *'|'* ]] || continue
      from="${mapping%%|*}"
      to="${mapping#*|}"
      [[ -n "$from" && -n "$to" ]] || continue

      if [[ "$reported" == "$from" || "$reported" == "$from"/* ]]; then
        candidate="${to%/}${reported#"$from"}"
        [[ -e "$candidate" ]] && break
        candidate=""
      fi
    done
  fi

  [[ -n "$candidate" && -f "$candidate" ]] || return 1

  resolved="$(realpath -- "$candidate")" || return 1
  roots="$(library_roots_for_owner "$owner")"

  local root_list=()
  IFS=';' read -r -a root_list <<<"$roots"

  for root in "${root_list[@]}"; do
    [[ -d "$root" ]] || continue
    root="$(realpath -- "$root")" || continue
    if path_is_below "$resolved" "$root"; then
      allowed=true
      break
    fi
  done

  is_true "$allowed" || return 1

  local size
  size="$(stat_size "$resolved")"
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  (( size > 0 )) || return 1

  printf '%s' "$resolved"
}

newest_path_mtime() {
  local path="$1"
  local newest=0
  local item
  local mtime

  while IFS= read -r -d '' item; do
    mtime="$(stat_mtime "$item")"
    [[ "$mtime" =~ ^[0-9]+$ ]] || continue
    (( mtime > newest )) && newest="$mtime"
  done < <(find "$path" -print0 2>/dev/null)

  printf '%s' "$newest"
}

path_is_stable() {
  local path="$1"
  local newest
  local cutoff

  newest="$(newest_path_mtime "$path")"
  [[ "$newest" =~ ^[0-9]+$ ]] || return 1
  (( newest > 0 )) || return 1

  cutoff=$(( $(date '+%s') - MIN_PATH_STABLE_HOURS * 3600 ))
  (( newest <= cutoff ))
}

path_size() {
  local path="$1"
  local total=0
  local item
  local size

  if [[ -f "$path" ]]; then
    stat_size "$path"
    return
  fi

  while IFS= read -r -d '' item; do
    size="$(stat_size "$item")"
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    ((total += size)) || true
  done < <(find "$path" -type f -print0 2>/dev/null)

  printf '%s' "$total"
}

source_media_count() {
  local path="$1"
  local count=0
  local file
  local base

  while IFS= read -r -d '' file; do
    base="${file##*/}"
    base="${base,,}"

    case "$base" in
      *.mkv|*.mp4|*.m4v|*.avi|*.mov|*.ts|*.m2ts|*.wmv|*.webm)
        if [[ "$base" =~ (^|[._\ -])(sample|trailer)([._\ -]|$) ]]; then
          continue
        fi
        ((count++)) || true
        ;;
    esac
  done < <(
    if [[ -f "$path" ]]; then
      printf '%s\0' "$path"
    else
      find "$path" -type f -print0 2>/dev/null
    fi
  )

  printf '%s' "$count"
}

###############################################################################
# ARR IMPORT PROOF
###############################################################################

verify_arr_import() {
  local owner="$1"
  local download_id="$2"
  local source_path="$3"
  local proof_file="$4"

  local history_file="$TMP_DIR/history_${SCANNED}.json"
  local imported_paths_file="$TMP_DIR/imported_paths_${SCANNED}.txt"
  local imported_paths_unique="$TMP_DIR/imported_paths_unique_${SCANNED}.txt"
  : > "$imported_paths_file"

  if ! fetch_arr_history_for_download "$owner" "$download_id" "$history_file"; then
    log "WARNING" "$owner history lookup failed for download ID: $download_id"
    return 10
  fi

  local latest_grab_epoch=0
  local record
  local record_id
  local event_type
  local event_date
  local event_epoch

  while IFS= read -r record; do
    record_id="$(jq -r '.downloadId // ""' <<<"$record")"
    [[ "${record_id,,}" == "${download_id,,}" ]] || continue

    event_type="$(jq -r '.eventType // ""' <<<"$record")"
    [[ "$event_type" == "grabbed" ]] || continue

    event_date="$(jq -r '.date // ""' <<<"$record")"
    event_epoch="$(date_to_epoch "$event_date")"
    [[ "$event_epoch" =~ ^[0-9]+$ ]] || event_epoch=0

    (( event_epoch > latest_grab_epoch )) && latest_grab_epoch="$event_epoch"
  done < <(jq -c '.records[]?' "$history_file")

  (( latest_grab_epoch > 0 )) || return 11

  local reported_path
  local resolved_path
  local import_events=0

  while IFS= read -r record; do
    record_id="$(jq -r '.downloadId // ""' <<<"$record")"
    [[ "${record_id,,}" == "${download_id,,}" ]] || continue

    event_type="$(jq -r '.eventType // ""' <<<"$record")"
    [[ "$event_type" == "downloadFolderImported" ]] || continue

    event_date="$(jq -r '.date // ""' <<<"$record")"
    event_epoch="$(date_to_epoch "$event_date")"
    [[ "$event_epoch" =~ ^[0-9]+$ ]] || event_epoch=0
    (( event_epoch >= latest_grab_epoch )) || continue

    ((import_events++)) || true
    reported_path="$(jq -r '.data.importedPath // ""' <<<"$record")"
    [[ -n "$reported_path" ]] || return 12

    resolved_path="$(resolve_imported_path "$owner" "$reported_path" || true)"
    [[ -n "$resolved_path" ]] || return 12
    printf '%s\n' "$resolved_path" >> "$imported_paths_file"
  done < <(jq -c '.records[]?' "$history_file")

  (( import_events > 0 )) || return 11

  sort -u -- "$imported_paths_file" > "$imported_paths_unique"

  local imported_count
  local source_count
  imported_count="$(wc -l < "$imported_paths_unique" | tr -d ' ')"
  source_count="$(source_media_count "$source_path")"

  [[ "$imported_count" =~ ^[0-9]+$ && "$source_count" =~ ^[0-9]+$ ]] || return 13
  (( imported_count > 0 )) || return 12
  (( imported_count >= source_count )) || return 13

  local imported_paths_json
  imported_paths_json="$(jq -R -s 'split("\n") | map(select(length > 0))' "$imported_paths_unique")" || return 12

  jq -n \
    --arg owner "$owner" \
    --arg downloadId "$download_id" \
    --argjson latestGrabEpoch "$latest_grab_epoch" \
    --argjson importEvents "$import_events" \
    --argjson verifiedImportedPaths "$imported_count" \
    --argjson remainingSourceMediaFiles "$source_count" \
    --argjson importedPaths "$imported_paths_json" \
    '{
      owner: $owner,
      downloadId: $downloadId,
      latestGrabEpoch: $latestGrabEpoch,
      importEvents: $importEvents,
      verifiedImportedPaths: $verifiedImportedPaths,
      remainingSourceMediaFiles: $remainingSourceMediaFiles,
      importedPaths: $importedPaths
    }' > "$proof_file"
}

proof_paths_still_valid() {
  local proof_file="$1"
  local imported_path
  local size

  while IFS= read -r imported_path; do
    [[ -n "$imported_path" && -f "$imported_path" ]] || return 1
    size="$(stat_size "$imported_path")"
    [[ "$size" =~ ^[0-9]+$ ]] || return 1
    (( size > 0 )) || return 1
  done < <(jq -r '.importedPaths[]?' "$proof_file")

  jq -e '.importedPaths | length > 0' "$proof_file" >/dev/null 2>&1
}

###############################################################################
# QUARANTINE / PURGE
###############################################################################

quarantine_payload() {
  local owner="$1"
  local category="$2"
  local download_id="$3"
  local job_name="$4"
  local completed_epoch="$5"
  local source_path="$6"
  local size="$7"
  local proof_file="$8"

  local safe_id
  local safe_name
  local wrapper
  local payload_name
  local manifest

  safe_id="$(sanitize_component "$download_id")"
  safe_name="$(sanitize_component "$job_name")"
  [[ -n "$safe_id" ]] || safe_id="unknown-id"
  [[ -n "$safe_name" ]] || safe_name="unnamed-job"

  wrapper="${QUARANTINE_DIR_REAL}/items/${owner}/${safe_id}__${safe_name}"
  if [[ -e "$wrapper" ]]; then
    wrapper="${wrapper}__${RUN_ID}"
  fi

  payload_name="$(basename -- "$source_path")"
  manifest="${wrapper}/.sabnzbd-cleanup-manifest.json"

  if is_true "$DRY_RUN"; then
    log "INFO" "[DRY RUN] Would quarantine: $source_path"
    log "INFO" "[DRY RUN] Destination wrapper: $wrapper"
    return 0
  fi

  # This is deliberately the last check before the first quarantine write.
  # If Mover started after the initial scan, stop the entire run here.
  check_mover_guard "before quarantine move for ${download_id}" || return $?

  mkdir -p -- "$wrapper" || return 1

  local wrapper_real
  wrapper_real="$(realpath -- "$wrapper")" || return 1
  path_is_below "$wrapper_real" "${QUARANTINE_DIR_REAL}/items/${owner}" || return 1

  local source_device
  local destination_device
  source_device="$(stat_device "$source_path")"
  destination_device="$(stat_device "$wrapper")"

  if [[ -z "$source_device" || -z "$destination_device" || "$source_device" != "$destination_device" ]]; then
    log "ERROR" "Source and quarantine are not on the same filesystem: $source_path"
    rmdir -- "$wrapper" 2>/dev/null || true
    return 1
  fi

  if ! mv -- "$source_path" "$wrapper/payload"; then
    rmdir -- "$wrapper" 2>/dev/null || true
    return 1
  fi

  local proof_json
  proof_json="$(cat "$proof_file")"

  if ! jq -n \
    --arg version "$VERSION" \
    --arg runId "$RUN_ID" \
    --arg quarantinedAt "$(timestamp)" \
    --arg owner "$owner" \
    --arg category "$category" \
    --arg downloadId "$download_id" \
    --arg jobName "$job_name" \
    --arg originalPath "$source_path" \
    --arg payloadName "$payload_name" \
    --argjson completedEpoch "$completed_epoch" \
    --argjson bytes "$size" \
    --argjson proof "$proof_json" \
    '{
      scriptVersion: $version,
      runId: $runId,
      quarantinedAt: $quarantinedAt,
      owner: $owner,
      category: $category,
      downloadId: $downloadId,
      jobName: $jobName,
      originalPath: $originalPath,
      payloadName: $payloadName,
      completedEpoch: $completedEpoch,
      bytes: $bytes,
      importProof: $proof
    }' > "$manifest"
  then
    log "ERROR" "Payload moved but manifest creation failed: $wrapper"
    return 1
  fi

  return 0
}

purge_quarantine() {
  is_true "$PURGE_QUARANTINE" || {
    log "INFO" "Quarantine purge is disabled."
    return 0
  }

  [[ -d "$QUARANTINE_DIR_REAL/items" ]] || return 0

  check_mover_guard "before quarantine purge" || return $?

  local cutoff_minutes=$((QUARANTINE_RETENTION_DAYS * 1440))
  local wrapper
  local wrapper_real
  local manifest
  local size
  local owner

  log "INFO" "Checking quarantine entries older than ${QUARANTINE_RETENTION_DAYS} days."

  while IFS= read -r -d '' wrapper; do
    manifest="$wrapper/.sabnzbd-cleanup-manifest.json"
    [[ -f "$manifest" ]] || {
      log "WARNING" "Skipping unmarked quarantine directory: $wrapper"
      continue
    }

    jq empty "$manifest" >/dev/null 2>&1 || {
      log "WARNING" "Skipping quarantine directory with invalid manifest: $wrapper"
      continue
    }

    wrapper_real="$(realpath -- "$wrapper")" || continue
    owner="$(basename -- "$(dirname -- "$wrapper_real")")"
    [[ "$owner" == "Sonarr" || "$owner" == "Radarr" ]] || continue
    path_is_below "$wrapper_real" "${QUARANTINE_DIR_REAL}/items/${owner}" || continue

    size="$(jq -r '.bytes // 0' "$manifest")"
    [[ "$size" =~ ^[0-9]+$ ]] || size=0

    if is_true "$DRY_RUN"; then
      log "INFO" "[DRY RUN] Would purge quarantine: $wrapper"
      ((PURGED++)) || true
      ((BYTES_PURGED += size)) || true
      PURGE_DETAILS+=("$wrapper")
      continue
    fi

    # Recheck for every destructive purge so a Mover that starts during a
    # longer cleanup stops all remaining writes immediately.
    check_mover_guard "before purging ${wrapper}" || return $?

    if rm -rf -- "$wrapper"; then
      log "INFO" "Purged quarantine: $wrapper"
      ((PURGED++)) || true
      ((BYTES_PURGED += size)) || true
      PURGE_DETAILS+=("$wrapper")
    else
      ((ERRORS++)) || true
      log "ERROR" "Failed to purge quarantine: $wrapper"
    fi
  done < <(
    find "$QUARANTINE_DIR_REAL/items" \
      -mindepth 2 \
      -maxdepth 2 \
      -type d \
      -mmin "+${cutoff_minutes}" \
      -print0 2>/dev/null
  )
}

###############################################################################
# MAIN CANDIDATE PROCESSING
###############################################################################

process_completed_jobs() {
  local item
  local status
  local category
  local owner
  local enabled
  local root
  local download_id
  local job_name
  local completed_epoch
  local age_hours
  local source_path
  local size
  local proof_file
  local proof_status
  local verified_paths
  local source_media
  local quarantine_status

  log "INFO" "Evaluating completed SABnzbd jobs."

  while IFS= read -r item; do
    ((SCANNED++)) || true

    status="$(jq -r '.status // ""' <<<"$item")"
    [[ "${status,,}" == "completed" ]] || continue
    ((COMPLETED_SCANNED++)) || true

    category="$(jq -r '.category // ""' <<<"$item")"
    owner="$(owner_for_category "$category")"
    [[ -n "$owner" ]] || continue

    case "$owner" in
      Sonarr) enabled="$SONARR_ENABLED" ;;
      Radarr) enabled="$RADARR_ENABLED" ;;
      *) enabled=false ;;
    esac

    if ! is_true "$enabled"; then
      ((SAFETY_SKIPPED++)) || true
      log "INFO" "Skipping $owner category because that integration is disabled: $category"
      continue
    fi

    download_id="$(jq -r '.nzo_id // ""' <<<"$item")"
    job_name="$(jq -r '.name // .nzb_name // "Unknown"' <<<"$item")"

    if [[ -z "$download_id" ]]; then
      ((SAFETY_SKIPPED++)) || true
      log "WARNING" "Skipping completed job without a download ID: $job_name"
      continue
    fi

    completed_epoch="$(sab_completed_epoch "$item")"
    [[ "$completed_epoch" =~ ^[0-9]+$ ]] || completed_epoch=0

    if (( completed_epoch <= 0 )); then
      ((SAFETY_SKIPPED++)) || true
      log "WARNING" "Skipping job with unknown completion time: $job_name"
      continue
    fi

    age_hours=$(( ($(date '+%s') - completed_epoch) / 3600 ))
    (( age_hours >= 0 )) || age_hours=0

    if (( age_hours < MIN_COMPLETED_AGE_HOURS )); then
      ((TOO_YOUNG++)) || true
      continue
    fi

    if download_is_active_anywhere "$download_id"; then
      ((QUEUE_PROTECTED++)) || true
      log "INFO" "Queue-protected completed job: $job_name [$download_id]"
      continue
    fi

    root="$(root_for_owner "$owner")"
    source_path="$(resolve_sab_path "$item" "$root" || true)"

    if [[ -z "$source_path" || ! -e "$source_path" ]]; then
      ((PATH_MISSING++)) || true
      continue
    fi

    if ! path_is_stable "$source_path"; then
      ((PATH_UNSTABLE++)) || true
      log "INFO" "Recently changed path remains protected: $source_path"
      continue
    fi

    proof_file="$TMP_DIR/proof_${SCANNED}.json"
    verify_arr_import "$owner" "$download_id" "$source_path" "$proof_file"
    proof_status=$?

    case "$proof_status" in
      0) ;;
      10|11)
        ((HISTORY_UNPROVEN++)) || true
        log "INFO" "Import history not proven; preserving: $job_name [$download_id]"
        continue
        ;;
      12)
        ((DESTINATION_UNVERIFIED++)) || true
        log "WARNING" "Imported library destination not verified; preserving: $job_name [$download_id]"
        continue
        ;;
      13)
        ((SOURCE_UNACCOUNTED++)) || true
        log "WARNING" "Remaining source media not fully accounted for; preserving: $job_name [$download_id]"
        continue
        ;;
      *)
        ((SAFETY_SKIPPED++)) || true
        log "WARNING" "Unexpected import-proof result $proof_status; preserving: $job_name [$download_id]"
        continue
        ;;
    esac

    # Recheck mutable filesystem state immediately before declaring
    # eligibility. Execute mode also refreshes all live queues so an API
    # snapshot cannot become stale during a long run.
    if ! proof_paths_still_valid "$proof_file"; then
      ((DESTINATION_UNVERIFIED++)) || true
      log "WARNING" "Imported destination changed during validation; preserving: $job_name [$download_id]"
      continue
    fi

    if ! is_true "$DRY_RUN" && ! refresh_active_state; then
      ((ERRORS++)) || true
      ((SAFETY_SKIPPED++)) || true
      log "ERROR" "Unable to refresh active queues; preserving: $job_name [$download_id]"
      continue
    fi

    if download_is_active_anywhere "$download_id" || \
       [[ ! -e "$source_path" || -L "$source_path" ]] || \
       ! path_is_below "$(realpath -- "$source_path" 2>/dev/null || true)" "$root" || \
       ! path_is_stable "$source_path"
    then
      ((QUEUE_PROTECTED++)) || true
      log "INFO" "Candidate changed during validation; preserving: $job_name [$download_id]"
      continue
    fi

    verified_paths="$(jq -r '.verifiedImportedPaths' "$proof_file")"
    source_media="$(jq -r '.remainingSourceMediaFiles' "$proof_file")"
    size="$(path_size "$source_path")"
    [[ "$size" =~ ^[0-9]+$ ]] || size=0

    ((ELIGIBLE++)) || true
    ((BYTES_ELIGIBLE += size)) || true

    log "INFO" "------------------------------------------------------------"
    log "INFO" "Verified stranded completed download"
    log "INFO" "Owner: $owner"
    log "INFO" "Category: $category"
    log "INFO" "Release: $job_name"
    log "INFO" "Download ID: $download_id"
    log "INFO" "Completed age: ${age_hours}h"
    log "INFO" "Source path: $source_path"
    log "INFO" "Source size: $(bytes_human "$size")"
    log "INFO" "Verified imported paths: $verified_paths"
    log "INFO" "Remaining source media files: $source_media"

    if (( MAX_QUARANTINES_PER_RUN > 0 && QUARANTINED >= MAX_QUARANTINES_PER_RUN )) && ! is_true "$DRY_RUN"; then
      log "WARNING" "Per-run quarantine limit reached; preserving remaining candidates."
      continue
    fi

    quarantine_payload \
      "$owner" \
      "$category" \
      "$download_id" \
      "$job_name" \
      "$completed_epoch" \
      "$source_path" \
      "$size" \
      "$proof_file"
    quarantine_status=$?

    if (( quarantine_status == 0 )); then
      ((QUARANTINED++)) || true
      ((BYTES_QUARANTINED += size)) || true
      QUARANTINE_DETAILS+=("$owner | $job_name | $(bytes_human "$size")")

      if is_true "$DRY_RUN"; then
        log "INFO" "Action: dry-run candidate only"
      else
        log "INFO" "Action: moved to quarantine"
      fi
    elif (( quarantine_status == 20 )); then
      return 20
    else
      ((ERRORS++)) || true
      log "ERROR" "Failed to quarantine: $source_path"
    fi
  done < <(jq -c '.[]?' "$SAB_HISTORY_FILE")
}

###############################################################################
# NOTIFICATION / SUMMARY
###############################################################################

notify_summary() {
  is_true "$SEND_NOTIFICATIONS" || return 0
  [[ -x "$NOTIFY" ]] || return 0

  if is_true "$DRY_RUN" && ! is_true "$NOTIFY_DRY_RUN"; then
    return 0
  fi

  (( QUARANTINED > 0 || PURGED > 0 || ERRORS > 0 )) || return 0

  local importance="normal"
  (( ERRORS > 0 )) && importance="warning"

  local mode="EXECUTE"
  is_true "$DRY_RUN" && mode="DRY RUN"

  local message
  message="Mode=${mode}; eligible=${ELIGIBLE}; quarantined=${QUARANTINED} ($(bytes_human "$BYTES_QUARANTINED")); purged=${PURGED} ($(bytes_human "$BYTES_PURGED")); errors=${ERRORS}"

  "$NOTIFY" \
    -i "$importance" \
    -s "SABnzbd Stranded Cleanup" \
    -d "Completed download cleanup summary" \
    -m "$message" >/dev/null 2>&1 || true
}

print_summary() {
  log "INFO" "============================================================"
  log "INFO" "SABnzbd stranded cleanup v${VERSION} summary"
  log "INFO" "Mode: $(is_true "$DRY_RUN" && printf 'DRY RUN' || printf 'EXECUTE')"
  log "INFO" "Runtime: $(runtime)"
  log "INFO" "SAB records scanned: $SCANNED"
  log "INFO" "Completed records scanned: $COMPLETED_SCANNED"
  log "INFO" "Too young: $TOO_YOUNG"
  log "INFO" "Queue protected: $QUEUE_PROTECTED"
  log "INFO" "Completed path already absent: $PATH_MISSING"
  log "INFO" "Recently changed path protected: $PATH_UNSTABLE"
  log "INFO" "Import history unproven: $HISTORY_UNPROVEN"
  log "INFO" "Imported destination unverified: $DESTINATION_UNVERIFIED"
  log "INFO" "Source media unaccounted: $SOURCE_UNACCOUNTED"
  log "INFO" "Other safety skips: $SAFETY_SKIPPED"
  log "INFO" "Mover guard stops: $MOVER_PROTECTED"
  if is_true "$MOVER_GUARD_TRIGGERED"; then
    log "INFO" "Mover guard context: $MOVER_GUARD_CONTEXT"
  fi
  log "INFO" "Eligible: $ELIGIBLE ($(bytes_human "$BYTES_ELIGIBLE"))"
  log "INFO" "Quarantined/planned: $QUARANTINED ($(bytes_human "$BYTES_QUARANTINED"))"
  log "INFO" "Purged/planned: $PURGED ($(bytes_human "$BYTES_PURGED"))"
  log "INFO" "Errors: $ERRORS"

  if (( ${#QUARANTINE_DETAILS[@]} > 0 )); then
    log "INFO" "Quarantine details:"
    local detail
    for detail in "${QUARANTINE_DETAILS[@]}"; do
      log "INFO" "  - $detail"
    done
  fi
}

###############################################################################
# ENTRY POINT
###############################################################################

main() {
  local operation_status

  parse_args "$@"
  initialize

  log "INFO" "Starting SABnzbd stranded completed download cleanup v${VERSION}."
  log "INFO" "DRY_RUN=$DRY_RUN | PURGE_QUARANTINE=$PURGE_QUARANTINE"
  log "INFO" "Minimum completed age: ${MIN_COMPLETED_AGE_HOURS}h"
  log "INFO" "Minimum path stability: ${MIN_PATH_STABLE_HOURS}h"
  log "INFO" "Quarantine retention: ${QUARANTINE_RETENTION_DAYS}d"
  log "INFO" "Mover guard enabled: $MOVER_GUARD_ENABLED"

  check_mover_guard "startup"
  operation_status=$?
  if (( operation_status == 20 )); then
    print_summary
    return 0
  fi

  fetch_required_state
  process_completed_jobs
  operation_status=$?
  if (( operation_status == 20 )); then
    print_summary
    return 0
  elif (( operation_status != 0 )); then
    die "Completed-job processing failed with status $operation_status."
  fi

  purge_quarantine
  operation_status=$?
  if (( operation_status == 20 )); then
    print_summary
    return 0
  elif (( operation_status != 0 )); then
    die "Quarantine purge failed with status $operation_status."
  fi

  print_summary
  notify_summary

  (( ERRORS == 0 ))
}

main "$@"
