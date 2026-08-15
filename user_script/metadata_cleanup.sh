#!/bin/bash

###############################################################################
# Orphaned Metadata Cleanup v2.0
#
# PURPOSE
# -------
# Remove orphaned movie, TV season, and TV show directories which contain
# metadata / sidecar files but no media files.
#
# SAFETY
# ------
# - Media files are never intentionally removed.
# - Directories containing unknown/non-metadata files are preserved.
# - Directories containing child directories are preserved.
# - All deletion targets are validated against the configured media roots.
# - DRY_RUN can be used to verify candidates without deleting anything.
#
###############################################################################

set -uo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

VERSION="2.0"

# ---------------------------------------------------------------------------
# Media paths
# ---------------------------------------------------------------------------

MOVIES_DIR="/mnt/user/media/movies"
TV_DIR="/mnt/user/media/series"

# ---------------------------------------------------------------------------
# Cleanup behavior
# ---------------------------------------------------------------------------

DRY_RUN=false

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

DELETED_COUNT=0
ERROR_COUNT=0
LEGACY_LOGS_REMOVED=0

###############################################################################
# GENERAL HELPERS
###############################################################################

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

is_true() {
  case "${1,,}" in
    1|true|yes|on)
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

  for cmd in find flock stat rm mv tee; do
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
  [[ -d "$MOVIES_DIR" ]] || die "Movies directory does not exist: $MOVIES_DIR"
  [[ -d "$TV_DIR" ]] || die "TV directory does not exist: $TV_DIR"
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
    -maxdepth 1 \
    -type f \
    \( \
      -iname "*.mkv" \
      -o -iname "*.mp4" \
      -o -iname "*.m4v" \
      -o -iname "*.avi" \
      -o -iname "*.mov" \
      -o -iname "*.wmv" \
      -o -iname "*.iso" \
      -o -iname "*.m2ts" \
      -o -iname "*.mpg" \
      -o -iname "*.mpeg" \
      -o -iname "*.ts" \
      -o -iname "*.rmvb" \
      -o -iname "*.divx" \
    \) \
    -print \
    -quit 2>/dev/null | read -r _
}

contains_only_metadata() {
  local dir="$1"

  # A metadata-only directory must not contain child directories.
  if find "$dir" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d \
      -print \
      -quit 2>/dev/null | read -r _; then
    return 1
  fi

  # Reject the directory if ANY regular file is not one of our recognized
  # metadata / artwork / subtitle sidecar formats.
  if find "$dir" \
      -maxdepth 1 \
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
        -o -iname "*.ass" \
        -o -iname "*.sub" \
        -o -iname "*.idx" \
      \) \
      -print \
      -quit 2>/dev/null | read -r _; then
    return 1
  fi

  # It must contain at least one recognized metadata / sidecar file.
  if ! find "$dir" \
      -maxdepth 1 \
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
        -o -iname "*.ass" \
        -o -iname "*.sub" \
        -o -iname "*.idx" \
      \) \
      -print \
      -quit 2>/dev/null | read -r _; then
    return 1
  fi

  return 0
}

###############################################################################
# CLEANUP ACTION
###############################################################################

remove_directory() {
  local label="$1"
  local target="$2"

  # Defensive protection against an unexpected path reaching rm -rf.
  case "$target" in
    "$MOVIES_DIR"/*|"$TV_DIR"/*)
      ;;
    *)
      log "ERROR" "Refusing deletion outside configured media roots: $target"
      ((ERROR_COUNT+=1))
      return 1
      ;;
  esac

  if is_true "$DRY_RUN"; then
    log "INFO" "[DRY-RUN] Would remove ${label}: $target"
    return 0
  fi

  if rm -rf -- "$target"; then
    log "INFO" "[DELETE] Removed ${label}: $target"
    ((DELETED_COUNT+=1))
    return 0
  fi

  log "ERROR" "Failed to remove ${label}: $target"
  ((ERROR_COUNT+=1))
  return 1
}

###############################################################################
# MOVIE CLEANUP
###############################################################################

cleanup_movies() {
  log "INFO" "Scanning movie directories..."

  while IFS= read -r movie_dir; do
    ((MOVIE_SCANNED+=1))

    if contains_media "$movie_dir"; then
      ((MEDIA_PROTECTED_COUNT+=1))
      continue
    fi

    if contains_only_metadata "$movie_dir"; then
      ((MOVIE_CANDIDATES+=1))

      remove_directory \
        "movie metadata-only directory" \
        "$movie_dir"

      continue
    fi

    ((OTHER_PROTECTED_COUNT+=1))

  done < <(
    find "$MOVIES_DIR" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d
  )
}

###############################################################################
# TV SEASON CLEANUP
###############################################################################

cleanup_empty_tv_seasons() {
  log "INFO" "Scanning TV season directories..."

  while IFS= read -r season_dir; do
    ((TV_SEASON_SCANNED+=1))

    if contains_media "$season_dir"; then
      ((MEDIA_PROTECTED_COUNT+=1))
      continue
    fi

    if contains_only_metadata "$season_dir"; then
      ((TV_SEASON_CANDIDATES+=1))

      remove_directory \
        "TV metadata-only season directory" \
        "$season_dir"

      continue
    fi

    ((OTHER_PROTECTED_COUNT+=1))

  done < <(
    find "$TV_DIR" \
      -mindepth 2 \
      -maxdepth 2 \
      -type d
  )
}

###############################################################################
# TV SHOW CLEANUP
###############################################################################

cleanup_empty_tv_shows() {
  log "INFO" "Scanning TV show directories..."

  while IFS= read -r show_dir; do
    ((TV_SHOW_SCANNED+=1))

    # A show containing season/subdirectories must never be removed here.
    if find "$show_dir" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -print \
        -quit 2>/dev/null | read -r _; then

      ((OTHER_PROTECTED_COUNT+=1))
      continue
    fi

    if contains_media "$show_dir"; then
      ((MEDIA_PROTECTED_COUNT+=1))
      continue
    fi

    if contains_only_metadata "$show_dir"; then
      ((TV_SHOW_CANDIDATES+=1))

      remove_directory \
        "TV metadata-only show directory" \
        "$show_dir"

      continue
    fi

    ((OTHER_PROTECTED_COUNT+=1))

  done < <(
    find "$TV_DIR" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d
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

  acquire_lock

  require_commands

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

  cleanup_movies
  cleanup_empty_tv_seasons
  cleanup_empty_tv_shows

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
    "Run summary: movies_scanned=${MOVIE_SCANNED} movie_candidates=${MOVIE_CANDIDATES} tv_seasons_scanned=${TV_SEASON_SCANNED} tv_season_candidates=${TV_SEASON_CANDIDATES} tv_shows_scanned=${TV_SHOW_SCANNED} tv_show_candidates=${TV_SHOW_CANDIDATES} protected_media=${MEDIA_PROTECTED_COUNT} protected_other=${OTHER_PROTECTED_COUNT} deleted=${DELETED_COUNT} dry_run_candidates=${dry_run_candidates} errors=${ERROR_COUNT}"

  if (( ERROR_COUNT > 0 )); then
    log "ERROR" "===== Cleanup COMPLETE WITH ERRORS ====="
    return 1
  fi

  log "INFO" "===== Cleanup COMPLETE ====="
  return 0
}

main "$@"