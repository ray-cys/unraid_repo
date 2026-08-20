#!/bin/bash

###############################################################################
# One-time NFO and Sonarr episode-thumbnail cleanup
#
# Movies:
#   - Removes *.nfo
#
# Series:
#   - Removes *.nfo
#   - Removes *-thumb.jpg
#
# "Remove" means move to quarantine. No files are permanently deleted.
###############################################################################

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Change these paths if your Unraid media shares use different locations.
MOVIES_ROOT="/mnt/user/media/movies"
SERIES_ROOT="/mnt/user/media/series"

# Files are moved here while preserving their original directory structure.
QUARANTINE_ROOT="/mnt/user/nfo_cleanup_quarantine"

# Keep this true for the first run.
# After reviewing the output, change it to false and run the script again.
DRY_RUN=true

# ---------------------------------------------------------------------------
# Runtime variables
# ---------------------------------------------------------------------------

RUN_ID="$(date '+%Y-%m-%d_%H-%M-%S')_$$"
RUN_QUARANTINE="${QUARANTINE_ROOT}/${RUN_ID}"

FOUND=0
MOVED=0
SKIPPED=0
ERRORS=0

log() {
    printf '%s\n' "$*"
}

validate_path() {
    local path="$1"
    local description="$2"

    if [[ -z "$path" || "$path" != /* ]]; then
        log "ERROR: ${description} must be an absolute path: ${path}"
        exit 1
    fi

    if [[ "$path" == "/" || "$path" == "/mnt" || "$path" == "/mnt/user" ]]; then
        log "ERROR: ${description} is too broad: ${path}"
        exit 1
    fi
}

path_is_inside() {
    local child="${1%/}/"
    local parent="${2%/}/"

    [[ "$child" == "$parent"* ]]
}

move_metadata_file() {
    local source="$1"
    local media_root="$2"
    local category="$3"
    local relative_path
    local destination
    local destination_directory

    relative_path="${source#"${media_root}/"}"
    destination="${RUN_QUARANTINE}/${category}/${relative_path}"
    destination_directory="$(dirname -- "$destination")"

    FOUND=$((FOUND + 1))

    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY RUN] Move:"
        log "  From: ${source}"
        log "  To:   ${destination}"
        return
    fi

    if [[ -e "$destination" ]]; then
        log "SKIPPED: Quarantine destination already exists:"
        log "  ${destination}"
        SKIPPED=$((SKIPPED + 1))
        return
    fi

    if ! mkdir -p -- "$destination_directory"; then
        log "ERROR: Could not create quarantine directory:"
        log "  ${destination_directory}"
        ERRORS=$((ERRORS + 1))
        return
    fi

    if mv -- "$source" "$destination"; then
        log "MOVED: ${source}"
        MOVED=$((MOVED + 1))
    else
        log "ERROR: Could not move:"
        log "  ${source}"
        ERRORS=$((ERRORS + 1))
    fi
}

process_media_root() {
    local category="$1"
    local media_root="${2%/}"
    local source

    if [[ ! -d "$media_root" ]]; then
        log "SKIPPED: Media directory does not exist:"
        log "  ${media_root}"
        SKIPPED=$((SKIPPED + 1))
        return
    fi

    log ""
    log "Scanning ${category}:"
    log "  ${media_root}"

    if [[ "$category" == "series" ]]; then
        while IFS= read -r -d '' source; do
            move_metadata_file "$source" "$media_root" "$category"
        done < <(
            find "$media_root" \
                -type f \
                \( \
                    -iname '*.nfo' \
                    -o -iname '*-thumb.jpg' \
                \) \
                -print0
        )
    else
        while IFS= read -r -d '' source; do
            move_metadata_file "$source" "$media_root" "$category"
        done < <(
            find "$media_root" \
                -type f \
                -iname '*.nfo' \
                -print0
        )
    fi
}

# ---------------------------------------------------------------------------
# Safety validation
# ---------------------------------------------------------------------------

MOVIES_ROOT="${MOVIES_ROOT%/}"
SERIES_ROOT="${SERIES_ROOT%/}"
QUARANTINE_ROOT="${QUARANTINE_ROOT%/}"

validate_path "$MOVIES_ROOT" "MOVIES_ROOT"
validate_path "$SERIES_ROOT" "SERIES_ROOT"
validate_path "$QUARANTINE_ROOT" "QUARANTINE_ROOT"

if [[ "$DRY_RUN" != true && "$DRY_RUN" != false ]]; then
    log "ERROR: DRY_RUN must be either true or false."
    exit 1
fi

if path_is_inside "$QUARANTINE_ROOT" "$MOVIES_ROOT"; then
    log "ERROR: Quarantine cannot be inside the Movies directory."
    exit 1
fi

if path_is_inside "$QUARANTINE_ROOT" "$SERIES_ROOT"; then
    log "ERROR: Quarantine cannot be inside the Series directory."
    exit 1
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

log "============================================================"
log "One-time media metadata cleanup"
log "============================================================"
log "Dry run:          ${DRY_RUN}"
log "Movies:           ${MOVIES_ROOT}"
log "Series:           ${SERIES_ROOT}"
log "Quarantine run:   ${RUN_QUARANTINE}"
log ""
log "Movie match:      *.nfo"
log "Series matches:   *.nfo and *-thumb.jpg"

process_media_root "movies" "$MOVIES_ROOT"
process_media_root "series" "$SERIES_ROOT"

log ""
log "============================================================"
log "Cleanup summary"
log "============================================================"
log "Files found:      ${FOUND}"
log "Files moved:      ${MOVED}"
log "Files skipped:    ${SKIPPED}"
log "Errors:           ${ERRORS}"

if [[ "$DRY_RUN" == true ]]; then
    log ""
    log "This was a dry run. Nothing was changed."
    log "Review the results, change DRY_RUN=false, and run it again."
elif [[ "$MOVED" -gt 0 ]]; then
    log ""
    log "Files were moved to:"
    log "  ${RUN_QUARANTINE}"
    log ""
    log "After confirming everything is working, you may manually delete"
    log "that quarantine run directory."
fi

if [[ "$ERRORS" -gt 0 ]]; then
    exit 1
fi