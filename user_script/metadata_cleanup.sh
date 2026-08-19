#!/bin/bash

###############################################################################
# Orphaned Metadata Cleanup v3.0
#
# PURPOSE
# -------
# Quarantine orphaned movie, TV season, and TV show directory trees which
# contain metadata / sidecar files but no media files.
#
# SAFETY
# ------
# - DRY_RUN defaults to true so the first run cannot move anything.
# - Candidates are moved to quarantine instead of being permanently deleted.
# - Media files and directories containing unknown/non-metadata entries are
#   preserved.
# - Candidates must be unchanged for MIN_AGE_HOURS before they are eligible.
# - Every candidate is revalidated immediately before it is moved.
# - All source and destination paths are validated against configured roots.
#
###############################################################################

set -uo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

VERSION="3.0"

# ---------------------------------------------------------------------------
# Media paths
# ---------------------------------------------------------------------------

MOVIES_DIR="/mnt/user/media/movies"
TV_DIR="/mnt/user/media/series"

# ---------------------------------------------------------------------------
# Cleanup behavior
# ---------------------------------------------------------------------------

# Keep this enabled until at least one complete run has been reviewed.
DRY_RUN=true

# A candidate and every entry below it must be at least this old. This gives
# Plex and the *arr applications time to finish scans/imports before cleanup.
MIN_AGE_HOURS=24

# Must be outside MOVIES_DIR and TV_DIR. Quarantine is intentionally not
# removed automatically; inspect it and apply your own retention policy.
QUARANTINE_DIR="/mnt/user/metadata_cleanup_quarantine"

# ---------------------------------------------------------------------------
# Logging
#
# LOG_KEEP=1 means:
#
#   metadata_cleanup.log
#   metadata_cleanup.log.1
#
# Therefore at most two rolling log files are retained.
# ---------------------------------------------------------------------------

LOG_DIR="/mnt/user/cloud/logs/metadata_cleanup"
LOG_FILE="${LOG_DIR}/metadata_cleanup.log"

LOG_MAX_BYTES=$((1 * 1024 * 1024))
LOG_KEEP=1

# ---------------------------------------------------------------------------
# Locking
# ---------------------------------------------------------------------------

LOCK_FILE="/tmp/metadata_cleanup.lock"

# Unique destination for this run. Including the PID avoids collisions if two
# runs start during the same second (the lock still prevents overlap).
RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"
RUN_EPOCH="$(date '+%s')"

###############################################################################
# INTERNAL COUNTERS
###############################################################################

MOVIE_SCANNED=0
MOVIE_CANDIDATES=0

TV_SEASON_SCANNED=0
TV_SEASON_CANDIDATES=0

TV_SHOW_SCANNED=0
TV_SHOW_CANDIDATES=0

MEDIA_PROTECTED_COUNT=0
OTHER_PROTECTED_COUNT=0
RECENT_PROTECTED_COUNT=0
REVALIDATION_PROTECTED_COUNT=0

QUARANTINED_COUNT=0
ERROR_COUNT=0
LEGACY_LOGS_REMOVED=0

QUARANTINE_PLANNED_OR_MOVED=()

###############################################################################
# GENERAL HELPERS
###############################################################################

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

is_true() {
  case "$1" in
    1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn])
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_false() {
  case "$1" in
    0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff])
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

log() {
  local level="$1"
  shift

  printf '%s [%s] %s\n' \
    "$(timestamp)" \
    "$level" \
    "$*" | tee -a "$LOG_FILE"
}

die() {
  log "ERROR" "$*"
  exit 1
}

###############################################################################
# LOCKING
###############################################################################

acquire_lock() {
  exec 9>"$LOCK_FILE"

  if ! flock -n 9; then
    printf '%s [INFO] Another metadata cleanup run is active; exiting.\n' \
      "$(timestamp)"
    exit 0
  fi
}

###############################################################################
# DEPENDENCY / PATH VALIDATION
###############################################################################

require_commands() {
  local cmd
  local missing=0

  for cmd in basename date dirname find flock mkdir mv readlink rm stat tee; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log "ERROR" "Required command not found: $cmd"
      missing=1
    fi
  done

  if (( missing != 0 )); then
    die "One or more required commands are unavailable."
  fi
}

validate_environment() {
  if ! is_true "$DRY_RUN" && ! is_false "$DRY_RUN"; then
    die "DRY_RUN must be true/false, yes/no, on/off, or 1/0."
  fi

  [[ -d "$MOVIES_DIR" ]] || die "Movies directory does not exist: $MOVIES_DIR"
  [[ -d "$TV_DIR" ]] || die "TV directory does not exist: $TV_DIR"

  MOVIES_DIR="$(readlink -f -- "$MOVIES_DIR")" || \
    die "Unable to resolve movies directory: $MOVIES_DIR"
  TV_DIR="$(readlink -f -- "$TV_DIR")" || \
    die "Unable to resolve TV directory: $TV_DIR"
  QUARANTINE_DIR="$(readlink -m -- "$QUARANTINE_DIR")" || \
    die "Unable to resolve quarantine directory: $QUARANTINE_DIR"

  case "$MOVIES_DIR" in
    /|/mnt|/mnt/user)
      die "Movies directory is dangerously broad: $MOVIES_DIR"
      ;;
  esac

  case "$TV_DIR" in
    /|/mnt|/mnt/user)
      die "TV directory is dangerously broad: $TV_DIR"
      ;;
  esac

  case "$QUARANTINE_DIR" in
    /|/mnt|/mnt/user)
      die "Quarantine directory is dangerously broad: $QUARANTINE_DIR"
      ;;
  esac

  [[ "$MOVIES_DIR" != "$TV_DIR" ]] || \
    die "Movies and TV directories must be different."

  if [[ "$MOVIES_DIR" == "$TV_DIR"/* ||
        "$TV_DIR" == "$MOVIES_DIR"/* ]]; then
    die "Movies and TV directories must not overlap."
  fi

  if [[ "$QUARANTINE_DIR" == "$MOVIES_DIR" ||
        "$QUARANTINE_DIR" == "$MOVIES_DIR"/* ||
        "$MOVIES_DIR" == "$QUARANTINE_DIR"/* ]]; then
    die "Quarantine and movies directories must not overlap."
  fi

  if [[ "$QUARANTINE_DIR" == "$TV_DIR" ||
        "$QUARANTINE_DIR" == "$TV_DIR"/* ||
        "$TV_DIR" == "$QUARANTINE_DIR"/* ]]; then
    die "Quarantine and TV directories must not overlap."
  fi

  [[ "$MIN_AGE_HOURS" =~ ^[0-9]+$ ]] || \
    die "MIN_AGE_HOURS must be a non-negative integer."

  if ! is_true "$DRY_RUN"; then
    mkdir -p -- "$QUARANTINE_DIR" || \
      die "Unable to create quarantine directory: $QUARANTINE_DIR"
  fi
}

###############################################################################
# LOG MAINTENANCE
###############################################################################

rotate_log() {
  [[ -f "$LOG_FILE" ]] || return 0

  local size
  size="$(stat -c '%s' "$LOG_FILE" 2>/dev/null || printf '0')"

  (( size >= LOG_MAX_BYTES )) || return 0

  if (( LOG_KEEP <= 0 )); then
    : > "$LOG_FILE"
    return 0
  fi

  rm -f -- "${LOG_FILE}.${LOG_KEEP}" 2>/dev/null || true

  local i

  for ((i=LOG_KEEP-1; i>=1; i--)); do
    if [[ -f "${LOG_FILE}.${i}" ]]; then
      mv -f -- \
        "${LOG_FILE}.${i}" \
        "${LOG_FILE}.$((i + 1))"
    fi
  done

  mv -f -- "$LOG_FILE" "${LOG_FILE}.1"
}

cleanup_legacy_logs() {
  local old_log

  while IFS= read -r -d '' old_log; do
    if rm -f -- "$old_log"; then
      ((LEGACY_LOGS_REMOVED+=1))
    else
      ((ERROR_COUNT+=1))
    fi
  done < <(
    find "$LOG_DIR" \
      -mindepth 1 \
      -maxdepth 1 \
      -type f \
      \( \
        -name 'metadata_[0-9]*_[0-9]*.log' \
        -o \
        -name 'metadata_cleanup_[0-9]*_[0-9]*.log' \
      \) \
      -print0 2>/dev/null
  )
}

###############################################################################
# DIRECTORY CLASSIFICATION
###############################################################################

contains_media() {
  local dir="$1"

  find "$dir" \
    -type f \
    \( \
      -iname "*.mkv" \
      -o -iname "*.mp4" \
      -o -iname "*.m4v" \
      -o -iname "*.avi" \
      -o -iname "*.mov" \
      -o -iname "*.wmv" \
      -o -iname "*.webm" \
      -o -iname "*.vob" \
      -o -iname "*.ogm" \
      -o -iname "*.ogv" \
      -o -iname "*.flv" \
      -o -iname "*.asf" \
      -o -iname "*.iso" \
      -o -iname "*.m2ts" \
      -o -iname "*.mts" \
      -o -iname "*.mpg" \
      -o -iname "*.mpeg" \
      -o -iname "*.ts" \
      -o -iname "*.rmvb" \
      -o -iname "*.divx" \
      -o -iname "*.strm" \
    \) \
    -print \
    -quit 2>/dev/null | read -r _
}

contains_only_metadata() {
  local dir="$1"

  # Reject symlinks, devices, sockets, and other special entries. Directories
  # are allowed so layouts such as Season 01/Subtitles can be quarantined as a
  # single tree when every contained file is recognized metadata.
  if find "$dir" \
      -mindepth 1 \
      ! -type d \
      ! -type f \
      -print \
      -quit 2>/dev/null | read -r _; then
    return 1
  fi

  # Reject the directory if ANY regular file is not one of our recognized
  # metadata / artwork / subtitle sidecar formats.
  if find "$dir" \
      -type f \
      ! \( \
        -iname "*.nfo" \
        -o -iname "*.jpg" \
        -o -iname "*.jpeg" \
        -o -iname "*.png" \
        -o -iname "*.webp" \
        -o -iname "*.tbn" \
        -o -iname "*.srt" \
        -o -iname "*.sdh" \
        -o -iname "*.smi" \
        -o -iname "*.ssa" \
        -o -iname "*.ass" \
        -o -iname "*.vtt" \
        -o -iname "*.sub" \
        -o -iname "*.idx" \
        -o -iname "*.sup" \
        -o -iname "*.mks" \
        -o -iname "*.usf" \
        -o -iname "*.ttml" \
        -o -iname "*.dfxp" \
      \) \
      -print \
      -quit 2>/dev/null | read -r _; then
    return 1
  fi

  # It must contain at least one recognized metadata / sidecar file.
  if ! find "$dir" \
      -type f \
      \( \
        -iname "*.nfo" \
        -o -iname "*.jpg" \
        -o -iname "*.jpeg" \
        -o -iname "*.png" \
        -o -iname "*.webp" \
        -o -iname "*.tbn" \
        -o -iname "*.srt" \
        -o -iname "*.sdh" \
        -o -iname "*.smi" \
        -o -iname "*.ssa" \
        -o -iname "*.ass" \
        -o -iname "*.vtt" \
        -o -iname "*.sub" \
        -o -iname "*.idx" \
        -o -iname "*.sup" \
        -o -iname "*.mks" \
        -o -iname "*.usf" \
        -o -iname "*.ttml" \
        -o -iname "*.dfxp" \
      \) \
      -print \
      -quit 2>/dev/null | read -r _; then
    return 1
  fi

  return 0
}

directory_tree_old_enough() {
  local dir="$1"
  local cutoff
  local entry
  local modified
  local changed

  cutoff=$((RUN_EPOCH - (MIN_AGE_HOURS * 60 * 60)))

  while IFS= read -r -d '' entry; do
    if ! modified="$(stat -c '%Y' -- "$entry" 2>/dev/null)"; then
      return 1
    fi

    if ! changed="$(stat -c '%Z' -- "$entry" 2>/dev/null)"; then
      return 1
    fi

    if (( modified > cutoff || changed > cutoff )); then
      return 1
    fi
  done < <(find "$dir" -print0 2>/dev/null)

  return 0
}

is_tv_season_directory() {
  local name
  name="$(basename -- "$1")"

  [[ "$name" =~ ^[Ss][Pp][Ee][Cc][Ii][Aa][Ll][Ss]$ ||
     "$name" =~ ^[Ss][Ee][Aa][Ss][Oo][Nn][[:space:]]+[0-9]+$ ]]
}

mark_quarantine_planned_or_moved() {
  QUARANTINE_PLANNED_OR_MOVED[${#QUARANTINE_PLANNED_OR_MOVED[@]}]="$1"
}

was_quarantine_planned_or_moved() {
  local expected="$1"
  local candidate
  local i

  for ((i=0; i<${#QUARANTINE_PLANNED_OR_MOVED[@]}; i++)); do
    candidate="${QUARANTINE_PLANNED_OR_MOVED[$i]}"
    [[ "$candidate" == "$expected" ]] && return 0
  done

  return 1
}

###############################################################################
# QUARANTINE ACTION
###############################################################################

candidate_location_is_valid() {
  local kind="$1"
  local target="$2"
  local parent
  local grandparent

  [[ -d "$target" && ! -L "$target" ]] || return 1

  parent="$(dirname -- "$target")"

  case "$kind" in
    movie)
      [[ "$parent" == "$MOVIES_DIR" ]]
      ;;
    show)
      [[ "$parent" == "$TV_DIR" ]]
      ;;
    season)
      grandparent="$(dirname -- "$parent")"
      [[ "$grandparent" == "$TV_DIR" ]] && is_tv_season_directory "$target"
      ;;
    *)
      return 1
      ;;
  esac
}

candidate_is_still_safe() {
  local kind="$1"
  local target="$2"

  if ! candidate_location_is_valid "$kind" "$target"; then
    log "WARN" "Candidate disappeared or failed location validation: $target"
    return 1
  fi

  if ! directory_tree_old_enough "$target"; then
    log "WARN" "Candidate changed inside the ${MIN_AGE_HOURS}-hour grace period: $target"
    return 1
  fi

  if contains_media "$target"; then
    log "WARN" "Candidate now contains media and will be preserved: $target"
    return 1
  fi

  if ! contains_only_metadata "$target"; then
    log "WARN" "Candidate now contains unknown content and will be preserved: $target"
    return 1
  fi

  return 0
}

quarantine_directory() {
  local kind="$1"
  local label="$2"
  local target="$3"
  local bucket
  local relative
  local destination

  if ! candidate_is_still_safe "$kind" "$target"; then
    ((REVALIDATION_PROTECTED_COUNT+=1))
    return 0
  fi

  case "$target" in
    "$MOVIES_DIR"/*)
      bucket="movies"
      relative="${target#"$MOVIES_DIR"/}"
      ;;
    "$TV_DIR"/*)
      bucket="series"
      relative="${target#"$TV_DIR"/}"
      ;;
    *)
      log "ERROR" "Refusing quarantine outside configured media roots: $target"
      ((ERROR_COUNT+=1))
      return 1
      ;;
  esac

  destination="${QUARANTINE_DIR}/${RUN_ID}/${bucket}/${relative}"

  case "$destination" in
    "$QUARANTINE_DIR"/*)
      ;;
    *)
      log "ERROR" "Refusing invalid quarantine destination: $destination"
      ((ERROR_COUNT+=1))
      return 1
      ;;
  esac

  if is_true "$DRY_RUN"; then
    log "INFO" "[DRY-RUN] Would quarantine ${label}: $target -> $destination"
    mark_quarantine_planned_or_moved "$target"
    return 0
  fi

  if [[ -e "$destination" || -L "$destination" ]]; then
    log "ERROR" "Quarantine destination already exists: $destination"
    ((ERROR_COUNT+=1))
    return 1
  fi

  if ! mkdir -p -- "$(dirname -- "$destination")"; then
    log "ERROR" "Unable to create quarantine destination parent: $destination"
    ((ERROR_COUNT+=1))
    return 1
  fi

  if mv -- "$target" "$destination"; then
    log "INFO" "[QUARANTINE] Moved ${label}: $target -> $destination"
    mark_quarantine_planned_or_moved "$target"
    ((QUARANTINED_COUNT+=1))
    return 0
  fi

  log "ERROR" "Failed to quarantine ${label}: $target"
  ((ERROR_COUNT+=1))
  return 1
}

###############################################################################
# MOVIE CLEANUP
###############################################################################

cleanup_movies() {
  log "INFO" "Scanning movie directories..."

  while IFS= read -r -d '' movie_dir; do
    ((MOVIE_SCANNED+=1))

    if contains_media "$movie_dir"; then
      ((MEDIA_PROTECTED_COUNT+=1))
      continue
    fi

    if contains_only_metadata "$movie_dir"; then
      if ! directory_tree_old_enough "$movie_dir"; then
        ((RECENT_PROTECTED_COUNT+=1))
        continue
      fi

      ((MOVIE_CANDIDATES+=1))

      quarantine_directory \
        "movie" \
        "movie metadata-only directory" \
        "$movie_dir"

      continue
    fi

    ((OTHER_PROTECTED_COUNT+=1))

  done < <(
    find "$MOVIES_DIR" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d \
      -print0
  )
}

###############################################################################
# TV SEASON CLEANUP
###############################################################################

cleanup_empty_tv_seasons() {
  log "INFO" "Scanning TV season directories..."

  while IFS= read -r -d '' season_dir; do
    local show_dir
    show_dir="$(dirname -- "$season_dir")"

    # A whole-show quarantine already includes this season. This primarily
    # prevents duplicate dry-run entries; live runs no longer see moved shows.
    if was_quarantine_planned_or_moved "$show_dir"; then
      continue
    fi

    if ! is_tv_season_directory "$season_dir"; then
      continue
    fi

    ((TV_SEASON_SCANNED+=1))

    if contains_media "$season_dir"; then
      ((MEDIA_PROTECTED_COUNT+=1))
      continue
    fi

    if contains_only_metadata "$season_dir"; then
      if ! directory_tree_old_enough "$season_dir"; then
        ((RECENT_PROTECTED_COUNT+=1))
        continue
      fi

      ((TV_SEASON_CANDIDATES+=1))

      quarantine_directory \
        "season" \
        "TV metadata-only season directory" \
        "$season_dir"

      continue
    fi

    ((OTHER_PROTECTED_COUNT+=1))

  done < <(
    find "$TV_DIR" \
      -mindepth 2 \
      -maxdepth 2 \
      -type d \
      -print0
  )
}

###############################################################################
# TV SHOW CLEANUP
###############################################################################

cleanup_empty_tv_shows() {
  log "INFO" "Scanning TV show directories..."

  while IFS= read -r -d '' show_dir; do
    ((TV_SHOW_SCANNED+=1))

    if contains_media "$show_dir"; then
      ((MEDIA_PROTECTED_COUNT+=1))
      continue
    fi

    if contains_only_metadata "$show_dir"; then
      if ! directory_tree_old_enough "$show_dir"; then
        ((RECENT_PROTECTED_COUNT+=1))
        continue
      fi

      ((TV_SHOW_CANDIDATES+=1))

      quarantine_directory \
        "show" \
        "TV metadata-only show directory" \
        "$show_dir"

      continue
    fi

    ((OTHER_PROTECTED_COUNT+=1))

  done < <(
    find "$TV_DIR" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d \
      -print0
  )
}

###############################################################################
# MAIN
###############################################################################

main() {
  umask 022

  if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    printf '%s [ERROR] Unable to create log directory: %s\n' \
      "$(timestamp)" \
      "$LOG_DIR" >&2
    return 1
  fi

  require_commands
  acquire_lock

  # Perform log maintenance BEFORE generating this run's log entries.
  rotate_log
  cleanup_legacy_logs

  log "INFO" "===== Orphaned Metadata Cleanup START ====="
  log "INFO" "Version: v${VERSION}"
  log "INFO" "Dry-run mode: ${DRY_RUN}"

  if (( LEGACY_LOGS_REMOVED > 0 )); then
    log "INFO" "Removed ${LEGACY_LOGS_REMOVED} legacy timestamp log file(s)."
  fi

  validate_environment

  log "INFO" "Movies root: ${MOVIES_DIR}"
  log "INFO" "TV root: ${TV_DIR}"
  log "INFO" "Quarantine root: ${QUARANTINE_DIR}"
  log "INFO" "Minimum unchanged age: ${MIN_AGE_HOURS} hour(s)"
  log "INFO" "Run ID: ${RUN_ID}"

  cleanup_movies
  cleanup_empty_tv_shows
  cleanup_empty_tv_seasons

  local candidate_total
  local dry_run_candidates=0

  candidate_total=$(( \
    MOVIE_CANDIDATES + \
    TV_SEASON_CANDIDATES + \
    TV_SHOW_CANDIDATES \
  ))

  if is_true "$DRY_RUN"; then
    dry_run_candidates="$candidate_total"
  fi

  log "INFO" \
    "Run summary: movies_scanned=${MOVIE_SCANNED} movie_candidates=${MOVIE_CANDIDATES} tv_seasons_scanned=${TV_SEASON_SCANNED} tv_season_candidates=${TV_SEASON_CANDIDATES} tv_shows_scanned=${TV_SHOW_SCANNED} tv_show_candidates=${TV_SHOW_CANDIDATES} protected_media=${MEDIA_PROTECTED_COUNT} protected_other=${OTHER_PROTECTED_COUNT} protected_recent=${RECENT_PROTECTED_COUNT} protected_revalidation=${REVALIDATION_PROTECTED_COUNT} quarantined=${QUARANTINED_COUNT} dry_run_candidates=${dry_run_candidates} errors=${ERROR_COUNT}"

  if (( ERROR_COUNT > 0 )); then
    log "ERROR" "===== Cleanup COMPLETE WITH ERRORS ====="
    return 1
  fi

  log "INFO" "===== Cleanup COMPLETE ====="
  return 0
}

main "$@"
