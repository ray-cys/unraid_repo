#!/bin/bash
LOCKFILE="/tmp/metadata_cleanup.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Another metadata_cleanup.sh run is active, exiting"
  exit 1
fi
############################################
# Configuration
############################################
MOVIES_DIR="/mnt/user/media/movies"
TV_DIR="/mnt/user/media/series"
LOG_FILE="/mnt/user/cloud/logs/metadata_cleanup.log"
DRY_RUN=false   # true = safe, false = delete
############################################

# Logging
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S')  $1" | tee -a "$LOG_FILE"
}

# Media Detection
contains_media() {
  local dir="$1"
  find "$dir" -maxdepth 1 -type f \( \
    -iname "*.mkv" -o \
    -iname "*.mp4" -o \
    -iname "*.avi" -o \
    -iname "*.mov" -o \
    -iname "*.wmv" -o \
    -iname "*.iso" -o \
    -iname "*.m2ts" -o \
    -iname "*.mpg" -o \
    -iname "*.mpeg" -o \
    -iname "*.ts" -o \
    -iname "*.rmvb" -o \
    -iname "*.divx" \
  \) -print -quit | read -r _
}

# Metadata-Only Check
contains_only_metadata() {
  local dir="$1"
  # Reject if subdirectories exist
  find "$dir" -mindepth 1 -maxdepth 1 -type d -print -quit | read -r _ && return 1
  # Reject if ANY non-metadata file exists
  find "$dir" -maxdepth 1 -type f ! \( \
    -iname "*.nfo" -o \
    -iname "*.jpg" -o \
    -iname "*.jpeg" -o \
    -iname "*.png" -o \
    -iname "*.webp" -o \
    -iname "*.tbn" -o \
    -iname "*.srt" -o \
    -iname "*.sdh" -o \
    -iname "*.ass" -o \
    -iname "*.sub" -o \
    -iname "*.idx" \
  \) -print -quit | read -r _ && return 1
  # Must contain at least ONE metadata file
  find "$dir" -maxdepth 1 -type f \( \
    -iname "*.nfo" -o \
    -iname "*.jpg" -o \
    -iname "*.srt" \
  \) -print -quit | read -r _ || return 1
  return 0
}

# Movies Cleanup (Depth-Limited)
cleanup_movies() {
  log "Scanning Movies for metadata-only directories..."
  while IFS= read -r movie_dir; do
    contains_media "$movie_dir" && continue
    if contains_only_metadata "$movie_dir"; then
      if $DRY_RUN; then
        log "[DRY-RUN] Would delete Movies metadata-only directory: $movie_dir"
      else
        log "[DELETE] Movies metadata-only directory removed: $movie_dir"
        rm -rf "$movie_dir"
      fi
    fi
  done < <(find "$MOVIES_DIR" -mindepth 1 -maxdepth 1 -type d)
}

# TV Seasons Cleanup (Second Level)
cleanup_empty_tv_seasons() {
  log "Scanning TV Seasons for metadata-only directories..."
  while IFS= read -r season_dir; do
    contains_media "$season_dir" && continue
    if contains_only_metadata "$season_dir"; then
      if $DRY_RUN; then
        log "[DRY-RUN] Would delete TV metadata-only season directory: $season_dir"
      else
        log "[DELETE] TV metadata-only season directory removed: $season_dir"
        rm -rf "$season_dir"
      fi
    fi
  done < <(find "$TV_DIR" -mindepth 2 -maxdepth 2 -type d)
}

# TV Shows Cleanup (Root Level)
cleanup_empty_tv_shows() {
  log "Scanning TV Shows for metadata-only directories..."
  while IFS= read -r show_dir; do
    # Skip if seasons still exist
    find "$show_dir" -mindepth 1 -maxdepth 1 -type d -print -quit | read -r _ && continue
    contains_media "$show_dir" && continue
    if contains_only_metadata "$show_dir"; then
      if $DRY_RUN; then
        log "[DRY-RUN] Would delete TV metadata-only show directory: $show_dir"
      else
        log "[DELETE] TV metadata-only show directory removed: $show_dir"
        rm -rf "$show_dir"
      fi
    fi
  done < <(find "$TV_DIR" -mindepth 1 -maxdepth 1 -type d)
}

# Main Execution
log "===== Orphaned Metadata Cleanup START ====="
log "Dry-run mode: $DRY_RUN"

cleanup_movies
cleanup_empty_tv_seasons
cleanup_empty_tv_shows

log "===== Cleanup COMPLETE ====="