#!/bin/bash

###############################################################################
# Appdata + Optional Shares Backup v3.2
#
# PURPOSE
# -------
# Create a verified backup of Docker appdata and optionally mirror additional
# shares with rsync.
#
# Appdata workflow:
#
#   1. Validate source/destination
#   2. Estimate compressed size from the last verified generation, measuring
#      only applications that do not have usable archive history
#   3. Select the vault or an alternate verified staging location
#   4. Record currently-running Docker containers
#   5. Stop selected running containers
#   6. Compress each top-level appdata directory
#   7. Verify every archive and write a checksum-protected size manifest
#   8. Promote the .partial backup only when the entire generation succeeds
#   9. If staged, retain it while retiring the old vault generation, then copy
#      it to the vault and verify the vault copy again
#  10. Prune the previous successful backup only after a verified replacement
#  11. Restart only containers that were running before the backup
#  12. Optionally mirror additional shares with rsync
#  13. Prune logs and send one consolidated Unraid notification
#
#
# SAFETY
# ------
# - Only containers that were running before the backup are restarted.
# - A failed container stop aborts the appdata backup.
# - An EXIT/signal trap attempts to restart containers if the script exits
#   unexpectedly after stopping them.
# - The previous successful backup is retained until the new backup has been
#   completely created and verified. In staging mode, the verified staged copy
#   becomes the safety generation before the old vault generation is removed.
# - If there is not enough free space to hold both generations temporarily,
#   the run aborts without deleting the previous successful backup.
# - New backups remain ".partial" until all archives pass verification.
# - Individual archives are written to ".tmp" first and promoted only after
#   gzip/tar integrity checks pass.
# - A checksum manifest is verified before promotion and again after a staged
#   generation is copied to the vault.
# - Compression diagnostics are held under /tmp so a full vault cannot erase
#   the failure reason.
#
#
# SCHEDULING
# ----------
# Scheduling is managed externally by Unraid User Scripts.
# This script does not create or modify its own schedule.
#
###############################################################################

set -uo pipefail

readonly SCRIPT_VERSION="3.2"


###############################################################################
# CONFIGURATION
###############################################################################

# ---------------------------------------------------------------------------
# Appdata paths
# ---------------------------------------------------------------------------

SRC_DIR="${SRC_DIR:-/mnt/cache/appdata}"
DEST_DIR="${DEST_DIR:-/mnt/vault/backup/cache}"
DEST_MOUNT_ROOT="${DEST_MOUNT_ROOT:-/mnt/vault}"

LOG_DIR="${LOG_DIR:-/mnt/vault/cloud/logs/script/appdata_backup}"

# When the vault cannot safely hold the old and new generations together, the
# replacement is built and verified here first. The staged generation remains
# a valid recovery copy until the final vault copy has also been verified.
# The default uses the cache pool selected by the latest repository setting.
# Choose another mounted device if independent staging failure protection is
# required in addition to temporary capacity relief.
STAGING_DIR="${STAGING_DIR:-/mnt/user/staging}"
STAGING_MOUNT_ROOT="${STAGING_MOUNT_ROOT:-/mnt/user}"

# Prevent an unavailable mount from being replaced by an ordinary directory on
# the Unraid root filesystem. Fixture tests may explicitly disable this guard.
REQUIRE_MOUNT_GUARDS="${REQUIRE_MOUNT_GUARDS:-true}"

# auto        = use the vault when it fits, otherwise use verified staging
# destination = require the vault to fit both generations
# staging     = always build through STAGING_DIR
BACKUP_STORAGE_MODE="${BACKUP_STORAGE_MODE:-auto}"


# ---------------------------------------------------------------------------
# Docker / appdata exclusions
# ---------------------------------------------------------------------------

# Containers listed here remain running during the backup.
#
# Exact Docker container-name match.
#
SKIP_CONTAINERS=(
    # "example-container"
)

# Appdata directories listed here are not included in the backup.
#
# Exact top-level directory-name match under SRC_DIR.
#
SKIP_APPDATA_DIRS=(
    # "example-appdata"
)


# ---------------------------------------------------------------------------
# Retention
# ---------------------------------------------------------------------------

# Number of VERIFIED successful backup directories to retain.
#
# Successful backups are pruned to this count only after a new verified backup
# has been promoted. With MAX_BACKUPS=1, the previous generation remains
# available for the entire backup operation.
#
MAX_BACKUPS="${MAX_BACKUPS:-1}"

# Number of failed/incomplete ".partial" backup directories to retain.
#
MAX_PARTIAL_BACKUPS="${MAX_PARTIAL_BACKUPS:-0}"

# Number of per-run log files to retain.
#
MAX_LOGS="${MAX_LOGS:-2}"

# Keep successfully-created archives from a failed/incomplete backup.
#
# true  = retain backup_TIMESTAMP.partial
# false = remove the incomplete backup directory
#
KEEP_PARTIAL="${KEEP_PARTIAL:-false}"

# Keep individual compression stderr files after the final report is built.
#
KEEP_TEMP_ERR="${KEEP_TEMP_ERR:-false}"


# ---------------------------------------------------------------------------
# Compression
# ---------------------------------------------------------------------------

# Number of compression attempts for each appdata directory.
#
RETRIES="${RETRIES:-3}"

# Delay between retries.
#
RETRY_DELAY="${RETRY_DELAY:-5}"

# pigz worker threads. Six is a balanced default for an idle backup window;
# lower this if the server has fewer CPU cores or must remain responsive.
#
# 0 = allow pigz to choose automatically.
#
# If pigz is unavailable, gzip is used automatically.
#
PIGZ_THREADS="${PIGZ_THREADS:-6}"

# Compression level used by both pigz and the gzip fallback.
# Level 3 favors backup speed while retaining useful compression.
PIGZ_LEVEL="${PIGZ_LEVEL:-3}"

# Optional additional GNU tar arguments.
#
# Example:
#
# TAR_OPTIONS=(
#     "--exclude=cache"
# )
#
TAR_OPTIONS=()

# Exact, per-application regenerable paths to exclude.
#
# Format: "top-level-appdata-directory|relative/path"
#
# Application names are exact and paths deliberately do not support wildcards.
# Databases, configuration, queue state, torrent state, and backup folders are
# not excluded. Add or remove entries to match locally-installed applications.
APPDATA_EXCLUDES=(
    "sonarr|logs"
    "sonarr|MediaCover"
    "sonarr|logs.db"
    "sonarr|logs.db-shm"
    "sonarr|logs.db-wal"
    "radarr|logs"
    "radarr|MediaCover"
    "radarr|logs.db"
    "radarr|logs.db-shm"
    "radarr|logs.db-wal"
    "prowlarr|logs"
    "prowlarr|MediaCover"
    "prowlarr|logs.db"
    "prowlarr|logs.db-shm"
    "prowlarr|logs.db-wal"
    "lidarr|logs"
    "lidarr|MediaCover"
    "lidarr|logs.db"
    "lidarr|logs.db-shm"
    "lidarr|logs.db-wal"
    "readarr|logs"
    "readarr|MediaCover"
    "readarr|logs.db"
    "readarr|logs.db-shm"
    "readarr|logs.db-wal"
    "sabnzbd|logs"
    "kometa|logs"
    "kometa|cache"
    "qbittorrent|qBittorrent/logs"
)


# ---------------------------------------------------------------------------
# Process priority
# ---------------------------------------------------------------------------

# Apply nice/ionice to compression and rsync operations when available.
#
USE_LOW_PRIORITY_IO="${USE_LOW_PRIORITY_IO:-false}"

IONICE_CLASS="${IONICE_CLASS:-2}"
IONICE_PRIORITY="${IONICE_PRIORITY:-7}"
NICE_LEVEL="${NICE_LEVEL:-10}"


# ---------------------------------------------------------------------------
# Destination-space estimation
# ---------------------------------------------------------------------------

# Estimated compressed size:
#
#     raw appdata size × REQUIRED_RATIO
#
# This is an estimate only. Actual compression ratio varies between apps.
#
REQUIRED_RATIO="${REQUIRED_RATIO:-0.60}"

# Historical estimates receive this growth allowance. Full inventory mode may
# additionally raise the estimate when measured raw-size growth is larger.
ESTIMATE_GROWTH_PERCENT="${ESTIMATE_GROWTH_PERCENT:-20}"

# Source-size inventory mode:
#
#   history = use each application's last verified compressed archive size,
#             plus ESTIMATE_GROWTH_PERCENT. Only new/history-less applications
#             receive a recursive source-size scan.
#   full    = recursively measure every application and scale historical
#             archive sizes by the measured raw-size change.
#
# History mode avoids repeatedly walking large application trees such as Plex
# metadata. Runtime free-space checks still run before every archive.
PREFLIGHT_SIZE_MODE="${PREFLIGHT_SIZE_MODE:-history}"

# Preserve this much usable space after the replacement is written.
MIN_FREE_RESERVE_BYTES="${MIN_FREE_RESERVE_BYTES:-10737418240}"

# Additional number of bytes added to the preflight requirement.
#
# Examples:
#
#   0              = no margin
#   10737418240    = 10 GiB
#   21474836480    = 20 GiB
#
LOW_SPACE_MARGIN="${LOW_SPACE_MARGIN:-0}"

# Behavior if estimated required space exceeds currently available space.
#
#   abort = do not stop containers; terminate before backup begins
#   warn  = log warning and continue
#
LOW_SPACE_ACTION="${LOW_SPACE_ACTION:-abort}"

# Exclude only regenerable Plex data. Databases, Metadata, Media artwork, and
# preferences remain in the backup.
EXCLUDE_REGENERABLE_PLEX_DATA="${EXCLUDE_REGENERABLE_PLEX_DATA:-true}"
PLEX_APPDATA_DIR="${PLEX_APPDATA_DIR:-plex-media-server}"


# ---------------------------------------------------------------------------
# Optional additional share mirrors
# ---------------------------------------------------------------------------

# Format:
#
#   "name|source|destination|exclude1,exclude2|exclude_file"
#
# Paths may contain spaces.
#
# Leave the exclude and/or exclude-file fields empty when unused.
#
# IMPORTANT:
# "--delete-delay" makes these destinations MIRRORS. Files deleted from the
# source can therefore also be deleted from the destination.
#
ADD_SHARES=(
    # "system|/mnt/cache/system|/mnt/user/node/shares/system||"
)

ADD_RSYNC_BASE_ARGS=(
    "-aH"
    "--delete-delay"
    "--stats"
    "--protect-args"
    "--partial"
)


# ---------------------------------------------------------------------------
# Notification
# ---------------------------------------------------------------------------

NOTIFY_BIN="${NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify}"
NOTIFY_SUBJECT="${NOTIFY_SUBJECT:-Scheduled Backup}"


# ---------------------------------------------------------------------------
# Lock
# ---------------------------------------------------------------------------

LOCK_FILE="${LOCK_FILE:-/tmp/appdata_backup.lock}"


###############################################################################
# RUNTIME STATE
#
# Internal values below this point should not normally be modified.
###############################################################################

SRC_NAME="$(basename "${SRC_DIR%/}")"
RUN_STAMP="$(date '+%Y%m%d_%H%M%S')"

LOG_FILE="${LOG_DIR}/${SRC_NAME}-${RUN_STAMP}.log"

WORK_ROOT=""
WORK_DIR=""
FINAL_DIR="${DEST_DIR}/backup_${RUN_STAMP}"
STAGED_DIR="${STAGING_DIR}/backup_${RUN_STAMP}.staged"
BACKUP_MODE="destination"
TEMP_DIR=""
MANIFEST_DATA_FILE=""

START_TIME=0

declare -a APPDATA_DIRS=()

declare -a RUNNING_CONTAINERS=()
declare -a TARGET_CONTAINERS=()
declare -a PRIORITY_PREFIX=()
declare -A CURRENT_RAW_BYTES=()
declare -A PREVIOUS_RAW_BYTES=()
declare -A PREVIOUS_ARCHIVE_BYTES=()
declare -A PREDICTED_ARCHIVE_BYTES=()

CONTAINERS_NEED_RESTART=false

RAW_TOTAL_BYTES=0
RAW_MEASURED_COUNT=0
HISTORY_ESTIMATE_COUNT=0
ESTIMATED_BACKUP_BYTES=0
ESTIMATED_REQUIRED_BYTES=0
REMAINING_ESTIMATED_BYTES=0
ESTIMATE_METHOD="fallback ratio"
LATEST_SUCCESS_DIR=""

DEST_TOTAL_BYTES=0
DEST_USED_BYTES=0
DEST_FREE_BYTES=0
DEST_FREE_PERCENT=-1

APPDATA_TOTAL=0
APPDATA_ELIGIBLE=0
APPDATA_OK=0
APPDATA_FAILED=0
APPDATA_SKIPPED=0
APPDATA_TOTAL_BYTES=0
APPDATA_FINALIZE_FAILED=0
RETENTION_FAILED=0
APPDATA_REPORT=""
APPDATA_BACKUP_PATH=""
LAST_COMPRESSION_REASON=""
LAST_COMPRESSION_FATAL=false
LAST_COMPRESSION_ATTEMPTS=0
STAGED_RECOVERY_PENDING=false

RESTART_FAILED=0

SHARES_TOTAL=0
SHARES_OK=0
SHARES_FAILED=0
SHARES_SKIPPED=0
SHARES_TOTAL_BYTES=0
SHARES_REPORT=""


###############################################################################
# GENERIC HELPERS
###############################################################################

ensure_dir() {
    local path="$1"

    if [ -d "$path" ]; then
        return 0
    fi

    mkdir -p -- "$path"
}


path_is_within_root() {
    local path="${1%/}/"
    local root="${2%/}/"

    [[ "$path" == "$root"* ]]
}


is_exact_mountpoint() {
    local path="${1%/}"

    [ -d "$path" ] && mountpoint -q -- "$path" 2>/dev/null
}


log() {
    local category="$1"
    local level="$2"
    shift 2

    local message="$*"

    local line=""

    printf -v line '%s [%s][%s] %s' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$category" \
        "$level" \
        "$message"

    printf '%s\n' "$line"
    [ -n "$LOG_FILE" ] &&
        printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
}


notify_unraid() {
    local importance="$1"
    local description="$2"
    local message="$3"

    if [ ! -x "$NOTIFY_BIN" ]; then
        log "NOTIFY" "WARN" "Unraid notification helper unavailable: $NOTIFY_BIN"
        return 0
    fi

    "$NOTIFY_BIN" \
        -i "$importance" \
        -b \
        -s "$NOTIFY_SUBJECT" \
        -d "$description" \
        -m "$message" ||
        log "NOTIFY" "WARN" "Failed to send Unraid notification"
}


bytes_to_human() {
    local bytes="${1:-0}"

    awk -v b="$bytes" '
        BEGIN {
            units[0]="B"
            units[1]="KB"
            units[2]="MB"
            units[3]="GB"
            units[4]="TB"
            units[5]="PB"

            i=0

            while (b >= 1024 && i < 5) {
                b=b/1024
                i++
            }

            if (b >= 100)
                printf "%.0f%s", b, units[i]
            else
                printf "%.1f%s", b, units[i]
        }
    '
}


format_duration() {
    local seconds="${1:-0}"

    printf '%dh:%02dm:%02ds' \
        $((seconds / 3600)) \
        $(((seconds % 3600) / 60)) \
        $((seconds % 60))
}


array_contains() {
    local needle="$1"
    shift

    local item

    for item in "$@"; do
        if [ "$item" = "$needle" ]; then
            return 0
        fi
    done

    return 1
}


configured_exclusions_for_app() {
    local name="$1"
    local rule=""
    local exclusion_app=""
    local exclusion_path=""

    if [ "$EXCLUDE_REGENERABLE_PLEX_DATA" = "true" ] &&
       [ "$name" = "$PLEX_APPDATA_DIR" ]
    then
        printf '%s\0' \
            "Library/Application Support/Plex Media Server/Cache" \
            "Library/Application Support/Plex Media Server/Codecs" \
            "Library/Application Support/Plex Media Server/Crash Reports" \
            "Library/Application Support/Plex Media Server/Logs" \
            "Library/Application Support/Plex Media Server/Updates" \
            "Library/Application Support/Plex Media Server/Plug-in Support/Caches"
    fi

    for rule in "${APPDATA_EXCLUDES[@]}"; do
        IFS='|' read -r exclusion_app exclusion_path <<<"$rule"
        [ "$exclusion_app" = "$name" ] || continue
        printf '%s\0' "$exclusion_path"
    done
}


validate_appdata_exclusions() {
    local rule=""
    local remainder=""
    local exclusion_app=""
    local exclusion_path=""

    for rule in "${APPDATA_EXCLUDES[@]}"; do
        remainder="${rule#*|}"

        if [ "$remainder" = "$rule" ] || [[ "$remainder" == *"|"* ]]; then
            log "PREFLIGHT" "ERROR" \
                "Invalid APPDATA_EXCLUDES entry; expected app|relative/path: $rule"
            return 1
        fi

        IFS='|' read -r exclusion_app exclusion_path <<<"$rule"

        if [ -z "$exclusion_app" ] || [ -z "$exclusion_path" ] ||
           [[ "$exclusion_app" == */* ]] ||
           [[ "$exclusion_app" == *$'\t'* ]] ||
           [[ "$exclusion_app" == *$'\n'* ]] ||
           [[ "$exclusion_path" == *$'\t'* ]] ||
           [[ "$exclusion_path" == *$'\n'* ]]
        then
            log "PREFLIGHT" "ERROR" \
                "Unsafe APPDATA_EXCLUDES entry: $rule"
            return 1
        fi

        case "$exclusion_path" in
            /*|.|..|./*|../*|*/.|*/..|*/./*|*/../*|*'*'*|*'?'*|*'['*)
                log "PREFLIGHT" "ERROR" \
                    "APPDATA_EXCLUDES paths must be exact, relative, and traversal-free: $rule"
                return 1
                ;;
        esac
    done

    return 0
}


safe_size_bytes() {
    local path="$1"
    local size=""
    local blocks=""

    size="$(du -sb -- "$path" 2>/dev/null | awk 'NR == 1 {print $1}')"

    if [[ "$size" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$size"
        return 0
    fi

    blocks="$(du -sk -- "$path" 2>/dev/null | awk 'NR == 1 {print $1}')"

    if [[ "$blocks" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$((blocks * 1024))"
        return 0
    fi

    printf '0\n'
    return 1
}


file_size_bytes() {
    local path="$1"
    local size=""

    size="$(stat -c '%s' -- "$path" 2>/dev/null || true)"

    if ! [[ "$size" =~ ^[0-9]+$ ]]; then
        size="$(stat -f '%z' "$path" 2>/dev/null || true)"
    fi

    if [[ "$size" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$size"
    else
        printf '0\n'
    fi
}


file_mtime_epoch() {
    local path="$1"
    local value=""

    value="$(stat -c '%Y' -- "$path" 2>/dev/null || true)"

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        value="$(stat -f '%m' "$path" 2>/dev/null || true)"
    fi

    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    printf '%s\n' "$value"
}


filesystem_device_id() {
    local path="$1"
    local value=""

    value="$(stat -c '%d' -- "$path" 2>/dev/null || true)"

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        value="$(stat -f '%d' "$path" 2>/dev/null || true)"
    fi

    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$value"
}


list_paths_by_mtime() {
    local root="$1"
    local entry_type="$2"
    local pattern="$3"
    local exclude_suffix="${4:-}"
    local path=""
    local base=""

    [ -d "$root" ] || return 0

    while IFS= read -r -d '' path; do
        base="$(basename "$path")"

        if [ -n "$exclude_suffix" ] && [[ "$base" == *"$exclude_suffix" ]]; then
            continue
        fi

        printf '%s\t%s\n' "$(file_mtime_epoch "$path")" "$path"
    done < <(
        find "$root" \
            -mindepth 1 \
            -maxdepth 1 \
            -type "$entry_type" \
            -name "$pattern" \
            -print0 2>/dev/null
    ) | sort -n | cut -f2-
}


available_bytes_for_path() {
    local path="$1"
    local available=""

    available="$(
        df -P -B1 -- "$path" 2>/dev/null |
            awk 'NR == 2 {print $4}'
    )"

    if ! [[ "$available" =~ ^[0-9]+$ ]]; then
        available="$(
            df -Pk -- "$path" 2>/dev/null |
                awk 'NR == 2 {printf "%.0f", $4 * 1024}'
        )"
    fi

    if [[ "$available" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$available"
        return 0
    fi

    printf '0\n'
    return 1
}


exit_status_description() {
    local status="${1:-1}"
    local signal_number=0
    local signal_name=""

    if [ "$status" -ge 128 ] && [ "$status" -le 255 ]; then
        signal_number=$((status - 128))
        signal_name="$(kill -l "$signal_number" 2>/dev/null || true)"

        if [ -n "$signal_name" ]; then
            printf '%s (signal %s/%s)' "$status" "$signal_number" "$signal_name"
            return 0
        fi
    fi

    printf '%s' "$status"
}


acquire_lock() {
    exec 9>"$LOCK_FILE"

    if flock -n 9; then
        return 0
    fi

    printf '%s %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "Another appdata_backup.sh run is active, exiting (lock: $LOCK_FILE)"
    return 1
}


###############################################################################
# CONFIGURATION / PREFLIGHT
###############################################################################

validate_configuration() {
    local required_command=""

    for required_command in \
        awk df du find flock gzip rsync sha256sum sort stat tar
    do
        if ! command -v "$required_command" >/dev/null 2>&1; then
            log "PREFLIGHT" "ERROR" \
                "Required command is unavailable: $required_command"
            return 1
        fi
    done

    if [ ! -d "$SRC_DIR" ]; then
        log "PREFLIGHT" "ERROR" "Source directory does not exist: $SRC_DIR"
        return 1
    fi

    case "$REQUIRE_MOUNT_GUARDS" in
        true|false)
            ;;
        *)
            log "PREFLIGHT" "ERROR" \
                "REQUIRE_MOUNT_GUARDS must be true or false"
            return 1
            ;;
    esac

    if [ "$REQUIRE_MOUNT_GUARDS" = "true" ]; then
        if ! command -v mountpoint >/dev/null 2>&1; then
            log "PREFLIGHT" "ERROR" \
                "mountpoint is required while mount guards are enabled"
            return 1
        fi

        if ! path_is_within_root "$DEST_DIR" "$DEST_MOUNT_ROOT"; then
            log "PREFLIGHT" "ERROR" \
                "Destination is outside DEST_MOUNT_ROOT: $DEST_DIR"
            return 1
        fi

        if ! is_exact_mountpoint "$DEST_MOUNT_ROOT"; then
            log "PREFLIGHT" "ERROR" \
                "Vault mount is not active at: $DEST_MOUNT_ROOT"
            return 1
        fi
    fi

    if ! ensure_dir "$DEST_DIR"; then
        log "PREFLIGHT" "ERROR" "Unable to create destination directory: $DEST_DIR"
        return 1
    fi

    if ! [[ "$MAX_BACKUPS" =~ ^[0-9]+$ ]] || [ "$MAX_BACKUPS" -lt 1 ]; then
        log "PREFLIGHT" "ERROR" "MAX_BACKUPS must be an integer >= 1"
        return 1
    fi

    if ! [[ "$MAX_PARTIAL_BACKUPS" =~ ^[0-9]+$ ]]; then
        log "PREFLIGHT" "ERROR" "MAX_PARTIAL_BACKUPS must be an integer >= 0"
        return 1
    fi

    if ! [[ "$MAX_LOGS" =~ ^[0-9]+$ ]] || [ "$MAX_LOGS" -lt 1 ]; then
        log "PREFLIGHT" "ERROR" "MAX_LOGS must be an integer >= 1"
        return 1
    fi

    if ! [[ "$RETRIES" =~ ^[0-9]+$ ]] || [ "$RETRIES" -lt 1 ]; then
        log "PREFLIGHT" "ERROR" "RETRIES must be an integer >= 1"
        return 1
    fi

    if ! [[ "$RETRY_DELAY" =~ ^[0-9]+$ ]]; then
        log "PREFLIGHT" "ERROR" "RETRY_DELAY must be a non-negative integer"
        return 1
    fi

    if ! [[ "$PIGZ_THREADS" =~ ^[0-9]+$ ]]; then
        log "PREFLIGHT" "ERROR" "PIGZ_THREADS must be a non-negative integer"
        return 1
    fi

    if ! [[ "$PIGZ_LEVEL" =~ ^[1-9]$ ]]; then
        log "PREFLIGHT" "ERROR" \
            "PIGZ_LEVEL must be an integer from 1 through 9"
        return 1
    fi

    if ! [[ "$ESTIMATE_GROWTH_PERCENT" =~ ^[0-9]+$ ]]; then
        log "PREFLIGHT" "ERROR" \
            "ESTIMATE_GROWTH_PERCENT must be a non-negative integer"
        return 1
    fi

    case "$PREFLIGHT_SIZE_MODE" in
        history|full)
            ;;
        *)
            log "PREFLIGHT" "ERROR" \
                "PREFLIGHT_SIZE_MODE must be 'history' or 'full'"
            return 1
            ;;
    esac

    if ! [[ "$MIN_FREE_RESERVE_BYTES" =~ ^[0-9]+$ ]]; then
        log "PREFLIGHT" "ERROR" \
            "MIN_FREE_RESERVE_BYTES must be specified in bytes"
        return 1
    fi

    if ! [[ "$LOW_SPACE_MARGIN" =~ ^[0-9]+$ ]]; then
        log "PREFLIGHT" "ERROR" "LOW_SPACE_MARGIN must be specified in bytes"
        return 1
    fi

    if ! awk -v ratio="$REQUIRED_RATIO" \
        'BEGIN { exit !(ratio > 0 && ratio <= 1) }'
    then
        log "PREFLIGHT" "ERROR" \
            "REQUIRED_RATIO must be greater than 0 and less than or equal to 1"
        return 1
    fi

    case "$LOW_SPACE_ACTION" in
        abort|warn)
            ;;
        *)
            log "PREFLIGHT" "ERROR" \
                "LOW_SPACE_ACTION must be 'abort' or 'warn'"
            return 1
            ;;
    esac

    case "$BACKUP_STORAGE_MODE" in
        auto|destination|staging)
            ;;
        *)
            log "PREFLIGHT" "ERROR" \
                "BACKUP_STORAGE_MODE must be 'auto', 'destination', or 'staging'"
            return 1
            ;;
    esac

    if [ "$BACKUP_STORAGE_MODE" != "destination" ]; then
        if [ -z "$STAGING_DIR" ] || [ "$STAGING_DIR" = "/" ]; then
            log "PREFLIGHT" "ERROR" "STAGING_DIR is unsafe or empty"
            return 1
        fi

        case "${STAGING_DIR%/}/" in
            "${DEST_DIR%/}/"*|"${SRC_DIR%/}/"*)
                log "PREFLIGHT" "ERROR" \
                    "STAGING_DIR must not be inside the source or vault destination"
                return 1
                ;;
        esac

        case "${DEST_DIR%/}/" in
            "${STAGING_DIR%/}/"*)
                log "PREFLIGHT" "ERROR" \
                    "Vault destination must not be inside STAGING_DIR"
                return 1
                ;;
        esac
    fi

    case "$EXCLUDE_REGENERABLE_PLEX_DATA" in
        true|false)
            ;;
        *)
            log "PREFLIGHT" "ERROR" \
                "EXCLUDE_REGENERABLE_PLEX_DATA must be true or false"
            return 1
            ;;
    esac

    if ! validate_appdata_exclusions; then
        return 1
    fi

    return 0
}


build_priority_prefix() {
    PRIORITY_PREFIX=()

    if [ "$USE_LOW_PRIORITY_IO" != "true" ]; then
        return 0
    fi

    if command -v ionice >/dev/null 2>&1; then
        PRIORITY_PREFIX+=(
            ionice
            "-c${IONICE_CLASS}"
            "-n${IONICE_PRIORITY}"
        )
    fi

    if command -v nice >/dev/null 2>&1; then
        PRIORITY_PREFIX+=(
            nice
            -n "$NICE_LEVEL"
        )
    fi
}


###############################################################################
# DESTINATION SPACE
###############################################################################

refresh_destination_space() {
    local values=""

    values="$(
        df -P -B1 -- "$DEST_DIR" 2>/dev/null |
            awk 'NR == 2 {print $2, $3, $4}'
    )"

    if [ -z "$values" ]; then
        values="$(
            df -Pk -- "$DEST_DIR" 2>/dev/null |
                awk 'NR == 2 {
                    printf "%.0f %.0f %.0f", $2 * 1024, $3 * 1024, $4 * 1024
                }'
        )"
    fi

    if [ -z "$values" ]; then
        DEST_TOTAL_BYTES=0
        DEST_USED_BYTES=0
        DEST_FREE_BYTES=0
        DEST_FREE_PERCENT=-1
        return 1
    fi

    read -r \
        DEST_TOTAL_BYTES \
        DEST_USED_BYTES \
        DEST_FREE_BYTES <<<"$values"

    if ! [[ "$DEST_TOTAL_BYTES" =~ ^[0-9]+$ ]] ||
       ! [[ "$DEST_USED_BYTES" =~ ^[0-9]+$ ]] ||
       ! [[ "$DEST_FREE_BYTES" =~ ^[0-9]+$ ]] ||
       [ "$DEST_TOTAL_BYTES" -le 0 ]
    then
        DEST_FREE_PERCENT=-1
        return 1
    fi

    DEST_FREE_PERCENT="$(
        awk \
            -v free="$DEST_FREE_BYTES" \
            -v total="$DEST_TOTAL_BYTES" \
            'BEGIN { printf "%d", (free * 100) / total }'
    )"

    return 0
}


collect_appdata_directories() {
    local directory=""
    local name=""

    APPDATA_DIRS=()
    CURRENT_RAW_BYTES=()

    RAW_TOTAL_BYTES=0
    RAW_MEASURED_COUNT=0
    HISTORY_ESTIMATE_COUNT=0
    APPDATA_TOTAL=0
    APPDATA_ELIGIBLE=0

    while IFS= read -r -d '' directory; do
        APPDATA_DIRS+=("$directory")
        APPDATA_TOTAL=$((APPDATA_TOTAL + 1))

        name="$(basename "$directory")"

        if [[ "$name" == *$'\t'* || "$name" == *$'\n'* ]]; then
            log "PREFLIGHT" "ERROR" \
                "Appdata directory names containing tabs or newlines are unsupported: $directory"
            return 1
        fi

        if array_contains "$name" "${SKIP_APPDATA_DIRS[@]}"; then
            continue
        fi

        APPDATA_ELIGIBLE=$((APPDATA_ELIGIBLE + 1))
    done < <(
        find "$SRC_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -print0
    )

    log "PREFLIGHT" "INFO" \
        "Found ${APPDATA_TOTAL} top-level appdata directories; ${APPDATA_ELIGIBLE} eligible for backup; size mode=${PREFLIGHT_SIZE_MODE}"

    if [ "$APPDATA_TOTAL" -eq 0 ]; then
        log "PREFLIGHT" "ERROR" \
            "No top-level directories found under $SRC_DIR"
        return 1
    fi

    if [ "$APPDATA_ELIGIBLE" -eq 0 ]; then
        log "PREFLIGHT" "ERROR" \
            "All appdata directories are excluded; nothing remains to back up"
        return 1
    fi

    return 0
}


find_latest_successful_backup() {
    list_paths_by_mtime \
        "$DEST_DIR" \
        d \
        'backup_[0-9]*_[0-9]*' \
        '.partial' |
        tail -n 1
}


manifest_checksum_valid() {
    local directory="$1"

    [ -f "${directory}/backup_manifest.tsv" ] &&
        [ -f "${directory}/backup_manifest.tsv.sha256" ] &&
        (
            cd "$directory" &&
                sha256sum -c -- backup_manifest.tsv.sha256 >/dev/null 2>&1
        )
}


load_previous_backup_metrics() {
    local raw_bytes=""
    local archive_bytes=""
    local checksum=""
    local name=""
    local archive=""
    local loaded=0

    PREVIOUS_RAW_BYTES=()
    PREVIOUS_ARCHIVE_BYTES=()
    LATEST_SUCCESS_DIR="$(find_latest_successful_backup)"
    ESTIMATE_METHOD="fallback ratio"

    [ -n "$LATEST_SUCCESS_DIR" ] || return 0

    if manifest_checksum_valid "$LATEST_SUCCESS_DIR"; then
        while IFS=$'\t' read -r raw_bytes archive_bytes checksum name; do
            [[ "$raw_bytes" == \#* ]] && continue
            [ -n "$name" ] || continue

            if [[ "$raw_bytes" =~ ^[0-9]+$ ]] &&
               [[ "$archive_bytes" =~ ^[0-9]+$ ]] &&
               [[ "$checksum" =~ ^[[:xdigit:]]{64}$ ]]
            then
                PREVIOUS_RAW_BYTES["$name"]="$raw_bytes"
                PREVIOUS_ARCHIVE_BYTES["$name"]="$archive_bytes"
                loaded=$((loaded + 1))
            fi
        done <"${LATEST_SUCCESS_DIR}/backup_manifest.tsv"

        if [ "$loaded" -gt 0 ]; then
            ESTIMATE_METHOD="verified manifest history"
            return 0
        fi
    fi

    for archive in "$LATEST_SUCCESS_DIR"/*.tar.gz; do
        [ -f "$archive" ] || continue
        name="$(basename "$archive" .tar.gz)"
        PREVIOUS_ARCHIVE_BYTES["$name"]="$(file_size_bytes "$archive")"
        loaded=$((loaded + 1))
    done

    if [ "$loaded" -gt 0 ]; then
        ESTIMATE_METHOD="archive-size history"
    fi
}


calculate_space_estimate() {
    local directory=""
    local name=""
    local current_raw=0
    local previous_raw=0
    local previous_archive=0
    local predicted=0
    local measure_started=0
    local measure_elapsed=0
    local history_source="fallback ratio"

    PREDICTED_ARCHIVE_BYTES=()
    ESTIMATED_BACKUP_BYTES=0
    RAW_TOTAL_BYTES=0
    RAW_MEASURED_COUNT=0
    HISTORY_ESTIMATE_COUNT=0

    load_previous_backup_metrics
    history_source="$ESTIMATE_METHOD"

    log "PREFLIGHT" "INFO" \
        "Preparing capacity estimate for ${APPDATA_ELIGIBLE} application(s)"

    for directory in "${APPDATA_DIRS[@]}"; do
        name="$(basename "$directory")"

        if array_contains "$name" "${SKIP_APPDATA_DIRS[@]}"; then
            continue
        fi

        previous_raw="${PREVIOUS_RAW_BYTES[$name]:-0}"
        previous_archive="${PREVIOUS_ARCHIVE_BYTES[$name]:-0}"

        if [ "$PREFLIGHT_SIZE_MODE" = "history" ] &&
           [ "$previous_archive" -gt 0 ]
        then
            # Retain the last measured raw size for diagnostics without
            # traversing the source tree again. Capacity estimation is based
            # on the immediately previous verified archive, not this value.
            CURRENT_RAW_BYTES["$name"]="$previous_raw"
            predicted=$((
                previous_archive * (100 + ESTIMATE_GROWTH_PERCENT) / 100
            ))
            HISTORY_ESTIMATE_COUNT=$((HISTORY_ESTIMATE_COUNT + 1))
        else
            measure_started="$(date +%s)"
            log "PREFLIGHT" "INFO" \
                "[${name}] Measuring source size (no usable archive history or full scan requested)"

            current_raw="$(safe_size_bytes "$directory")"
            measure_elapsed=$(($(date +%s) - measure_started))

            if [[ "$current_raw" =~ ^[0-9]+$ ]] &&
               [ "$current_raw" -gt 0 ]
            then
                CURRENT_RAW_BYTES["$name"]="$current_raw"
                RAW_TOTAL_BYTES=$((RAW_TOTAL_BYTES + current_raw))
                RAW_MEASURED_COUNT=$((RAW_MEASURED_COUNT + 1))
                log "PREFLIGHT" "INFO" \
                    "[${name}] Source size $(bytes_to_human "$current_raw") measured in $(format_duration "$measure_elapsed")"
            else
                CURRENT_RAW_BYTES["$name"]=0
                current_raw=0
                log "PREFLIGHT" "WARN" \
                    "[${name}] Unable to determine source size after $(format_duration "$measure_elapsed")"
            fi

            if [ "$previous_archive" -gt 0 ] &&
               [ "$previous_raw" -gt 0 ] &&
               [ "$current_raw" -gt 0 ]
            then
                predicted="$(
                    awk \
                        -v old_archive="$previous_archive" \
                        -v old_raw="$previous_raw" \
                        -v current_raw="$current_raw" \
                        -v growth="$ESTIMATE_GROWTH_PERCENT" \
                        'BEGIN {
                            scaled = old_archive * (current_raw / old_raw)
                            printf "%.0f", scaled * ((100 + growth) / 100)
                        }'
                )"
            elif [ "$previous_archive" -gt 0 ]; then
                predicted=$((
                    previous_archive * (100 + ESTIMATE_GROWTH_PERCENT) / 100
                ))
            else
                predicted="$(
                    awk \
                        -v raw="$current_raw" \
                        -v ratio="$REQUIRED_RATIO" \
                        'BEGIN { printf "%.0f", raw * ratio }'
                )"
            fi
        fi

        [ "$predicted" -gt 0 ] || predicted=1
        PREDICTED_ARCHIVE_BYTES["$name"]="$predicted"
        ESTIMATED_BACKUP_BYTES=$((ESTIMATED_BACKUP_BYTES + predicted))
    done

    if [ "$HISTORY_ESTIMATE_COUNT" -gt 0 ] &&
       [ "$RAW_MEASURED_COUNT" -gt 0 ]
    then
        ESTIMATE_METHOD="${history_source} + measured new/history-less applications"
    elif [ "$HISTORY_ESTIMATE_COUNT" -gt 0 ]; then
        ESTIMATE_METHOD="$history_source"
    elif [ "$RAW_MEASURED_COUNT" -gt 0 ]; then
        ESTIMATE_METHOD="measured fallback ratio"
    else
        ESTIMATE_METHOD="fallback ratio"
    fi

    ESTIMATED_REQUIRED_BYTES=$((
        ESTIMATED_BACKUP_BYTES + LOW_SPACE_MARGIN + MIN_FREE_RESERVE_BYTES
    ))
    REMAINING_ESTIMATED_BYTES="$ESTIMATED_BACKUP_BYTES"

    log "SPACE" "INFO" \
        "Measured raw=$(bytes_to_human "$RAW_TOTAL_BYTES") across ${RAW_MEASURED_COUNT} app(s), history=${HISTORY_ESTIMATE_COUNT} app(s), estimate=$(bytes_to_human "$ESTIMATED_BACKUP_BYTES"), reserve=$(bytes_to_human "$MIN_FREE_RESERVE_BYTES"), required=$(bytes_to_human "$ESTIMATED_REQUIRED_BYTES"), method=${ESTIMATE_METHOD}"

    if [ -n "$LATEST_SUCCESS_DIR" ]; then
        log "SPACE" "INFO" \
            "Estimate baseline: $LATEST_SUCCESS_DIR"
    fi
}


validate_staging_location() {
    if [ "$REQUIRE_MOUNT_GUARDS" = "true" ]; then
        if ! path_is_within_root "$STAGING_DIR" "$STAGING_MOUNT_ROOT"; then
            log "SPACE" "ERROR" \
                "Staging path is outside STAGING_MOUNT_ROOT: $STAGING_DIR"
            return 1
        fi

        if ! is_exact_mountpoint "$STAGING_MOUNT_ROOT"; then
            log "SPACE" "ERROR" \
                "Staging mount is not active at: $STAGING_MOUNT_ROOT"
            return 1
        fi
    fi

    if ! ensure_dir "$STAGING_DIR"; then
        log "SPACE" "ERROR" \
            "Unable to create staging directory: $STAGING_DIR"
        return 1
    fi

    return 0
}


select_backup_workspace() {
    local destination_free=0
    local staging_free=0
    local destination_device=""
    local staging_device=""

    destination_free="$(available_bytes_for_path "$DEST_DIR")" || return 1
    DEST_FREE_BYTES="$destination_free"

    if [ "$BACKUP_STORAGE_MODE" != "staging" ] &&
       [ "$destination_free" -ge "$ESTIMATED_REQUIRED_BYTES" ]
    then
        BACKUP_MODE="destination"
        WORK_ROOT="$DEST_DIR"
        WORK_DIR="${DEST_DIR}/backup_${RUN_STAMP}.partial"

        log "SPACE" "INFO" \
            "Using vault directly: available=$(bytes_to_human "$destination_free")"
        return 0
    fi

    if [ "$BACKUP_STORAGE_MODE" = "destination" ]; then
        if [ "$LOW_SPACE_ACTION" = "warn" ]; then
            BACKUP_MODE="destination"
            WORK_ROOT="$DEST_DIR"
            WORK_DIR="${DEST_DIR}/backup_${RUN_STAMP}.partial"
            log "SPACE" "WARN" \
                "Vault estimate exceeds available space, but LOW_SPACE_ACTION=warn"
            return 0
        fi

        log "SPACE" "ERROR" \
            "Vault cannot safely fit the replacement: required=$(bytes_to_human "$ESTIMATED_REQUIRED_BYTES"), available=$(bytes_to_human "$destination_free")"
        return 1
    fi

    validate_staging_location || return 1

    destination_device="$(filesystem_device_id "$DEST_DIR" || true)"
    staging_device="$(filesystem_device_id "$STAGING_DIR" || true)"

    if [ -n "$destination_device" ] &&
       [ "$destination_device" = "$staging_device" ]
    then
        log "SPACE" "WARN" \
            "Staging and vault report the same filesystem device; staging will not provide independent capacity protection"
    fi

    staging_free="$(available_bytes_for_path "$STAGING_DIR")" || return 1

    if [ "$staging_free" -lt "$ESTIMATED_REQUIRED_BYTES" ]; then
        log "SPACE" "ERROR" \
            "Neither vault nor staging has sufficient estimated space: vault=$(bytes_to_human "$destination_free"), staging=$(bytes_to_human "$staging_free"), required=$(bytes_to_human "$ESTIMATED_REQUIRED_BYTES")"
        return 1
    fi

    BACKUP_MODE="staging"
    WORK_ROOT="$STAGING_DIR"
    WORK_DIR="${STAGING_DIR}/backup_${RUN_STAMP}.partial"

    if [ "$BACKUP_STORAGE_MODE" = "staging" ]; then
        log "SPACE" "INFO" \
            "Verified staging was explicitly selected with $(bytes_to_human "$staging_free") available"
    else
        log "SPACE" "WARN" \
            "Vault has $(bytes_to_human "$destination_free"); using verified staging with $(bytes_to_human "$staging_free") available"
    fi

    return 0
}


###############################################################################
# RETENTION
###############################################################################

prune_logs() {
    local -a logs=()
    local removed=0

    [ -d "$LOG_DIR" ] || return 0

    mapfile -t logs < <(
        list_paths_by_mtime \
            "$LOG_DIR" \
            f \
            "${SRC_NAME}-*.log"
    )

    while [ "${#logs[@]}" -gt "$MAX_LOGS" ]; do
        rm -f -- "${logs[0]}"
        logs=("${logs[@]:1}")
        removed=$((removed + 1))
    done

    if [ "$removed" -gt 0 ]; then
        log "CLEANUP" "INFO" "Removed ${removed} old backup log(s)"
    fi
}


prune_successful_backups() {
    local keep_count="${1:-$MAX_BACKUPS}"
    local -a backups=()
    local removed=0

    [ -d "$DEST_DIR" ] || return 0

    mapfile -t backups < <(
        list_paths_by_mtime \
            "$DEST_DIR" \
            d \
            'backup_[0-9]*_[0-9]*' \
            '.partial'
    )

    while [ "${#backups[@]}" -gt "$keep_count" ]; do
        if ! rm -rf -- "${backups[0]}"; then
            log "CLEANUP" "ERROR" \
                "Unable to remove old successful backup: ${backups[0]}"
            return 1
        fi

        backups=("${backups[@]:1}")
        removed=$((removed + 1))
    done

    log "CLEANUP" "INFO" \
        "Successful-backup retention (keep=${keep_count}) removed ${removed} old backup(s)"

    return 0
}


prune_partial_backups() {
    local root="${1:-$DEST_DIR}"
    local keep_count="${2:-$MAX_PARTIAL_BACKUPS}"
    local -a partials=()
    local removed=0
    local reclaimed=0
    local partial_size=0

    [ -d "$root" ] || return 0

    mapfile -t partials < <(
        list_paths_by_mtime \
            "$root" \
            d \
            'backup_*.partial'
    )

    while [ "${#partials[@]}" -gt "$keep_count" ]; do
        partial_size="$(safe_size_bytes "${partials[0]}")"

        if ! rm -rf -- "${partials[0]}"; then
            log "CLEANUP" "ERROR" \
                "Unable to remove old partial backup: ${partials[0]}"
            return 1
        fi

        reclaimed=$((reclaimed + partial_size))
        partials=("${partials[@]:1}")
        removed=$((removed + 1))
    done

    if [ "$removed" -gt 0 ]; then
        log "CLEANUP" "INFO" \
            "Partial-backup retention removed ${removed} old partial backup(s), approximately $(bytes_to_human "$reclaimed")"
    fi

    return 0
}


###############################################################################
# DOCKER CONTAINER CONTROL
###############################################################################

discover_target_containers() {
    local docker_output=""
    local container=""

    RUNNING_CONTAINERS=()
    TARGET_CONTAINERS=()

    if ! docker_output="$(docker ps --format '{{.Names}}' 2>/dev/null)"; then
        log "DOCKER" "WARN" \
            "Docker ps failed; Assuming Docker service has no running containers"
        return 0
    fi

    while IFS= read -r container; do
        [ -n "$container" ] || continue

        RUNNING_CONTAINERS+=("$container")

        if array_contains "$container" "${SKIP_CONTAINERS[@]}"; then
            log "DOCKER" "INFO" \
                "Leaving container running due to SKIP_CONTAINERS: $container"
            continue
        fi

        TARGET_CONTAINERS+=("$container")

    done <<<"$docker_output"

    log "DOCKER" "INFO" \
        "Running containers=${#RUNNING_CONTAINERS[@]}, containers to stop=${#TARGET_CONTAINERS[@]}"
}


stop_target_containers() {
    local container=""
    local running_state=""
    local failed=0

    if [ "${#TARGET_CONTAINERS[@]}" -eq 0 ]; then
        log "DOCKER" "INFO" "No running containers need to be stopped"
        return 0
    fi

    # Set before the first stop so the EXIT trap can recover from interruption
    # during the stop sequence itself.
    CONTAINERS_NEED_RESTART=true

    for container in "${TARGET_CONTAINERS[@]}"; do
        log "DOCKER" "INFO" "Stopping container: $container"

        docker stop "$container" >/dev/null 2>&1 || true

        running_state="$(
            docker inspect \
                -f '{{.State.Running}}' \
                "$container" \
                2>/dev/null ||
                true
        )"

        if [ "$running_state" = "false" ]; then
            log "DOCKER" "INFO" "Stopped container: $container"
        else
            log "DOCKER" "ERROR" \
                "Container did not stop successfully: $container"
            failed=1
        fi
    done

    return "$failed"
}


emergency_restart_containers() {
    local container=""

    [ "$CONTAINERS_NEED_RESTART" = "true" ] || return 0

    for container in "${TARGET_CONTAINERS[@]}"; do
        docker start "$container" >/dev/null 2>&1 || true
    done
}


restart_target_containers() {
    local container=""
    local running_state=""
    local attempt=0
    local started=0

    RESTART_FAILED=0

    if [ "${#TARGET_CONTAINERS[@]}" -eq 0 ]; then
        CONTAINERS_NEED_RESTART=false
        return 0
    fi

    log "DOCKER" "INFO" \
        "Restarting ${#TARGET_CONTAINERS[@]} previously-running container(s)"

    for container in "${TARGET_CONTAINERS[@]}"; do
        started=0

        for attempt in 1 2; do
            docker start "$container" >/dev/null 2>&1 || true

            running_state="$(
                docker inspect \
                    -f '{{.State.Running}}' \
                    "$container" \
                    2>/dev/null ||
                    true
            )"

            if [ "$running_state" = "true" ]; then
                started=1
                break
            fi

            if [ "$attempt" -lt 2 ]; then
                sleep 2
            fi
        done

        if [ "$started" -eq 1 ]; then
            log "DOCKER" "INFO" "Started container: $container"
        else
            RESTART_FAILED=$((RESTART_FAILED + 1))
            log "DOCKER" "ERROR" \
                "Failed to restart container: $container"
        fi
    done

    # Explicit recovery has completed. Unexpected exits before this function
    # are handled by the EXIT trap.
    CONTAINERS_NEED_RESTART=false

    [ "$RESTART_FAILED" -eq 0 ]
}


###############################################################################
# EXIT / SIGNAL SAFETY
###############################################################################

handle_signal() {
    local signal_name="$1"

    log "BACKUP" "ERROR" \
        "Received ${signal_name}; terminating backup"

    notify_unraid \
        "alert" \
        "Backup interrupted" \
        "Signal: ${signal_name}
Containers will be restarted by the cleanup handler.
Log: ${LOG_FILE}"

    exit 130
}


handle_exit() {
    local exit_code="$1"

    if [ "$CONTAINERS_NEED_RESTART" = "true" ]; then
        log "DOCKER" "WARN" \
            "Unexpected exit detected while containers may be stopped; attempting emergency restart"

        emergency_restart_containers
    fi

    if [ "$exit_code" -ne 0 ] &&
       [ "$KEEP_PARTIAL" != "true" ] &&
       [ -n "$WORK_DIR" ] &&
       [ -d "$WORK_DIR" ]
    then
        rm -rf -- "$WORK_DIR" 2>/dev/null || true
    fi

    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf -- "$TEMP_DIR" 2>/dev/null || true
    fi
}


###############################################################################
# ARCHIVE CREATION / VERIFICATION
###############################################################################

verify_archive() {
    local archive="$1"
    local error_file="$2"

    # A successful compressed tar listing reads the complete gzip stream,
    # validates its checksum, and confirms that tar can parse the archive.
    # A separate pigz/gzip test would repeat the same full decompression.
    if ! tar -tzf "$archive" >/dev/null 2>>"$error_file"; then
        return 1
    fi

    return 0
}


check_remaining_capacity() {
    local name="$1"
    local error_file="$2"
    local available=0
    local required=0

    available="$(available_bytes_for_path "$WORK_ROOT")" || available=0
    required=$((
        REMAINING_ESTIMATED_BYTES +
        LOW_SPACE_MARGIN +
        MIN_FREE_RESERVE_BYTES
    ))

    if [ "$available" -ge "$required" ]; then
        return 0
    fi

    LAST_COMPRESSION_REASON="capacity guard: remaining estimate $(bytes_to_human "$REMAINING_ESTIMATED_BYTES") plus reserve $(bytes_to_human "$MIN_FREE_RESERVE_BYTES") exceeds $(bytes_to_human "$available") available"
    LAST_COMPRESSION_FATAL=true

    printf 'Capacity guard stopped [%s]: %s\n' \
        "$name" \
        "$LAST_COMPRESSION_REASON" \
        >>"$error_file"

    log "SPACE" "ERROR" "[${name}] ${LAST_COMPRESSION_REASON}"
    return 1
}


create_backup_manifest() {
    local manifest="${WORK_DIR}/backup_manifest.tsv"
    local checksum_file="${WORK_DIR}/backup_manifest.tsv.sha256"
    local archive_count=0

    [ -s "$MANIFEST_DATA_FILE" ] || return 1

    archive_count="$(wc -l <"$MANIFEST_DATA_FILE" | tr -d '[:space:]')"

    {
        printf '# schema=1\n'
        printf '# script_version=%s\n' "$SCRIPT_VERSION"
        printf '# created=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
        printf '# source=%s\n' "$SRC_DIR"
        printf '# archive_count=%s\n' "$archive_count"
        printf '# raw_bytes_note=last measured source size; may be carried forward in history mode\n'
        printf '# fields=raw_bytes\\tarchive_bytes\\tsha256\\tname\n'
        LC_ALL=C sort -t $'\t' -k4,4 "$MANIFEST_DATA_FILE"
    } >"$manifest" || return 1

    (
        cd "$WORK_DIR" &&
            sha256sum -- backup_manifest.tsv >backup_manifest.tsv.sha256
    ) || return 1

    [ -s "$checksum_file" ]
}


verify_backup_directory() {
    local directory="$1"
    local error_file="${2:-${TEMP_DIR}/generation-verify.err}"
    local expected_count=""
    local raw_bytes=""
    local archive_bytes=""
    local expected_checksum=""
    local name=""
    local archive=""
    local actual_bytes=0
    local actual_checksum=""
    local verified_count=0
    local archive_count=0

    : >"$error_file"

    if ! manifest_checksum_valid "$directory"; then
        printf 'Manifest checksum is missing or invalid\n' >>"$error_file"
        return 1
    fi

    if find "$directory" \
        -mindepth 1 \
        -maxdepth 1 \
        -type l \
        -print -quit 2>/dev/null |
        grep -q .
    then
        printf 'Generation contains an unexpected symbolic link\n' \
            >>"$error_file"
        return 1
    fi

    expected_count="$(
        sed -n 's/^# archive_count=//p' \
            "${directory}/backup_manifest.tsv" |
            tail -n 1
    )"

    if ! [[ "$expected_count" =~ ^[0-9]+$ ]] || [ "$expected_count" -lt 1 ]; then
        printf 'Manifest archive count is invalid: %s\n' "$expected_count" \
            >>"$error_file"
        return 1
    fi

    while IFS=$'\t' read -r raw_bytes archive_bytes expected_checksum name; do
        [[ "$raw_bytes" == \#* ]] && continue
        [ -n "$name" ] || continue

        if [ "$name" = "." ] || [ "$name" = ".." ] || [[ "$name" == */* ]]; then
            printf 'Unsafe archive name in manifest: %s\n' "$name" \
                >>"$error_file"
            return 1
        fi

        if ! [[ "$raw_bytes" =~ ^[0-9]+$ ]] ||
           ! [[ "$archive_bytes" =~ ^[0-9]+$ ]] ||
           ! [[ "$expected_checksum" =~ ^[[:xdigit:]]{64}$ ]]
        then
            printf 'Invalid manifest row for: %s\n' "$name" >>"$error_file"
            return 1
        fi

        archive="${directory}/${name}.tar.gz"

        if [ ! -f "$archive" ] || [ -L "$archive" ]; then
            printf 'Archive is missing or is a symlink: %s\n' "$archive" \
                >>"$error_file"
            return 1
        fi

        actual_bytes="$(file_size_bytes "$archive")"
        if [ "$actual_bytes" -ne "$archive_bytes" ]; then
            printf 'Archive size mismatch for %s: expected=%s actual=%s\n' \
                "$name" "$archive_bytes" "$actual_bytes" >>"$error_file"
            return 1
        fi

        actual_checksum="$(sha256sum -- "$archive" | awk '{print $1}')"
        if [ "$actual_checksum" != "$expected_checksum" ]; then
            printf 'Archive checksum mismatch for: %s\n' "$name" \
                >>"$error_file"
            return 1
        fi

        verified_count=$((verified_count + 1))
    done <"${directory}/backup_manifest.tsv"

    archive_count=0
    while IFS= read -r -d '' archive; do
        archive_count=$((archive_count + 1))
    done < <(
        find "$directory" \
            -mindepth 1 \
            -maxdepth 1 \
            -type f \
            -name '*.tar.gz' \
            -print0 2>/dev/null
    )

    if [ "$verified_count" -ne "$expected_count" ] ||
       [ "$archive_count" -ne "$expected_count" ]
    then
        printf 'Archive count mismatch: manifest=%s verified=%s present=%s\n' \
            "$expected_count" "$verified_count" "$archive_count" \
            >>"$error_file"
        return 1
    fi

    return 0
}


record_archive_manifest_row() {
    local name="$1"
    local archive="$2"
    local raw_bytes="${CURRENT_RAW_BYTES[$name]:-0}"
    local archive_bytes=0
    local checksum=""

    archive_bytes="$(file_size_bytes "$archive")"
    checksum="$(sha256sum -- "$archive" | awk '{print $1}')"

    [[ "$checksum" =~ ^[[:xdigit:]]{64}$ ]] || return 1

    printf '%s\t%s\t%s\t%s\n' \
        "$raw_bytes" \
        "$archive_bytes" \
        "$checksum" \
        "$name" \
        >>"$MANIFEST_DATA_FILE"
}


compress_directory() {
    local name="$1"

    local archive="${WORK_DIR}/${name}.tar.gz"
    local archive_tmp="${archive}.tmp"
    local error_file="${TEMP_DIR}/${name}.err"

    local attempt=0
    local tar_status=0
    local compressor_status=0
    local available_after=0
    local temp_bytes=0
    local non_retryable=false
    local verification_failed=false
    local manifest_record_failed=false
    local exclusion_path=""
    local exclusion_summary=""

    local -a compressor=()
    local -a exclusion_paths=()
    local -a pipeline_status=()
    local -a effective_tar_options=("${TAR_OPTIONS[@]}")

    LAST_COMPRESSION_REASON=""
    LAST_COMPRESSION_FATAL=false
    LAST_COMPRESSION_ATTEMPTS=0

    while IFS= read -r -d '' exclusion_path; do
        effective_tar_options+=("--exclude=${name}/${exclusion_path}")
        exclusion_paths+=("$exclusion_path")
    done < <(configured_exclusions_for_app "$name")

    if [ "${#exclusion_paths[@]}" -gt 0 ]; then
        for exclusion_path in "${exclusion_paths[@]}"; do
            exclusion_summary+="${exclusion_summary:+, }${exclusion_path}"
        done

        log "BACKUP" "INFO" \
            "[${name}] Excluding ${#exclusion_paths[@]} regenerable path(s): ${exclusion_summary}"
    fi

    if command -v pigz >/dev/null 2>&1; then
        if [ "$PIGZ_THREADS" -gt 0 ]; then
            compressor=(
                pigz
                -p "$PIGZ_THREADS"
                -"$PIGZ_LEVEL"
                -c
            )
        else
            compressor=(
                pigz
                -"$PIGZ_LEVEL"
                -c
            )
        fi
    else
        compressor=(
            gzip
            -"$PIGZ_LEVEL"
            -c
        )
    fi

    : >"$error_file"

    if ! check_remaining_capacity "$name" "$error_file"; then
        return 1
    fi

    for ((attempt = 1; attempt <= RETRIES; attempt++)); do
        LAST_COMPRESSION_ATTEMPTS="$attempt"
        rm -f -- "$archive_tmp"
        verification_failed=false
        manifest_record_failed=false

        printf '\n=== Compression attempt %d/%d ===\n' \
            "$attempt" \
            "$RETRIES" \
            >>"$error_file"

        log "DOCKER" "INFO" \
            "[${name}] Compression attempt ${attempt}/${RETRIES}"

        "${PRIORITY_PREFIX[@]}" \
            tar \
            -C "$SRC_DIR" \
            -cf - \
            "${effective_tar_options[@]}" \
            -- "$name" \
            2>>"$error_file" |
            "${PRIORITY_PREFIX[@]}" \
                "${compressor[@]}" \
                2>>"$error_file" \
                >"$archive_tmp"

        pipeline_status=("${PIPESTATUS[@]}")
        tar_status="${pipeline_status[0]:-1}"
        compressor_status="${pipeline_status[1]:-1}"

        temp_bytes="$(file_size_bytes "$archive_tmp")"
        available_after="$(available_bytes_for_path "$WORK_ROOT")" || available_after=0

        printf 'Pipeline status: tar=%s, compressor=%s, temporary=%s, available=%s\n' \
            "$(exit_status_description "$tar_status")" \
            "$(exit_status_description "$compressor_status")" \
            "$(bytes_to_human "$temp_bytes")" \
            "$(bytes_to_human "$available_after")" \
            >>"$error_file"

        if [ "$tar_status" -eq 0 ] && [ "$compressor_status" -eq 0 ]; then
            if verify_archive "$archive_tmp" "$error_file"; then
                if mv -f -- "$archive_tmp" "$archive"; then
                    log "VERIFY" "INFO" \
                        "[${name}] Archive passed compressed tar structure verification"
                    if record_archive_manifest_row "$name" "$archive"; then
                        return 0
                    fi

                    manifest_record_failed=true
                    printf 'Failed to record archive in the generation manifest\n' \
                        >>"$error_file"
                else
                    printf 'Failed to promote temporary archive to final archive\n' \
                        >>"$error_file"
                fi
            else
                verification_failed=true
                log "VERIFY" "ERROR" \
                    "[${name}] Archive verification failed on attempt ${attempt}"
            fi
        else
            log "DOCKER" "ERROR" \
                "[${name}] Compression pipeline failed on attempt ${attempt}: tar=$(exit_status_description "$tar_status"), compressor=$(exit_status_description "$compressor_status")"
        fi

        non_retryable=false

        if grep -Eqi 'no space left|disk quota exceeded' "$error_file" ||
           [ "$available_after" -lt "$MIN_FREE_RESERVE_BYTES" ]
        then
            LAST_COMPRESSION_REASON="destination capacity exhausted while creating ${name}"
            LAST_COMPRESSION_FATAL=true
            non_retryable=true
        elif [ "$tar_status" -eq 137 ] || [ "$compressor_status" -eq 137 ]; then
            LAST_COMPRESSION_REASON="compression was killed by SIGKILL; probable memory pressure"
            LAST_COMPRESSION_FATAL=true
            non_retryable=true
        elif [ "$tar_status" -ge 128 ] || [ "$compressor_status" -ge 128 ]; then
            LAST_COMPRESSION_REASON="compression process terminated by a signal"
            non_retryable=true
        elif [ "$manifest_record_failed" = "true" ]; then
            LAST_COMPRESSION_REASON="archive succeeded but its checksum manifest could not be updated"
            LAST_COMPRESSION_FATAL=true
            non_retryable=true
        elif [ "$verification_failed" = "true" ]; then
            LAST_COMPRESSION_REASON="temporary archive failed gzip or tar verification"
        else
            LAST_COMPRESSION_REASON="tar or compressor returned a non-zero status"
        fi

        printf 'Classified failure: %s\n' "$LAST_COMPRESSION_REASON" \
            >>"$error_file"

        rm -f -- "$archive_tmp"

        if [ "$non_retryable" = "true" ]; then
            log "BACKUP" "ERROR" \
                "[${name}] Non-retryable failure: $LAST_COMPRESSION_REASON"
            break
        fi

        if [ "$attempt" -lt "$RETRIES" ]; then
            sleep "$RETRY_DELAY"
        fi
    done

    return 1
}


successful_backup_bytes() {
    local directory=""
    local total=0
    local size=0

    while IFS= read -r -d '' directory; do
        size="$(safe_size_bytes "$directory")"
        total=$((total + size))
    done < <(
        find "$DEST_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -name 'backup_[0-9]*_[0-9]*' \
            ! -name '*.partial' \
            -print0 2>/dev/null
    )

    printf '%s\n' "$total"
}


transfer_staged_backup() {
    local staged_directory="$1"
    local generation_name=""
    local destination_partial=""
    local destination_final=""
    local staged_bytes=0
    local destination_free=0
    local reclaimable_bytes=0
    local required_bytes=0
    local transfer_log="${TEMP_DIR}/staging-transfer.log"
    local verify_log="${TEMP_DIR}/staging-transfer-verify.err"

    generation_name="$(basename "$staged_directory" .staged)"
    destination_partial="${DEST_DIR}/${generation_name}.partial"
    destination_final="${DEST_DIR}/${generation_name}"

    if ! verify_backup_directory \
        "$staged_directory" \
        "${TEMP_DIR}/staged-generation-verify.err"
    then
        log "STAGING" "ERROR" \
            "Staged generation failed verification and was preserved: $staged_directory"
        return 1
    fi

    staged_bytes="$(safe_size_bytes "$staged_directory")"
    destination_free="$(available_bytes_for_path "$DEST_DIR")" || destination_free=0
    reclaimable_bytes="$(successful_backup_bytes)"
    required_bytes=$((staged_bytes + MIN_FREE_RESERVE_BYTES))

    if [ $((destination_free + reclaimable_bytes)) -lt "$required_bytes" ]; then
        log "STAGING" "ERROR" \
            "Verified staged backup cannot fit on vault even after retiring the old generation: staged=$(bytes_to_human "$staged_bytes"), current free=$(bytes_to_human "$destination_free"), reclaimable=$(bytes_to_human "$reclaimable_bytes"), reserve=$(bytes_to_human "$MIN_FREE_RESERVE_BYTES")"
        APPDATA_BACKUP_PATH="$staged_directory"
        STAGED_RECOVERY_PENDING=true
        return 1
    fi

    # A complete, checksum-verified replacement now exists on staging. It is
    # safe to retire the old vault generation while this copy remains intact.
    if ! prune_successful_backups 0; then
        RETENTION_FAILED=1
        APPDATA_BACKUP_PATH="$staged_directory"
        STAGED_RECOVERY_PENDING=true
        return 1
    fi

    destination_free="$(available_bytes_for_path "$DEST_DIR")" || destination_free=0
    if [ "$destination_free" -lt "$required_bytes" ]; then
        log "STAGING" "ERROR" \
            "Vault still lacks room after old-generation cleanup; verified staged backup was preserved: required=$(bytes_to_human "$required_bytes"), available=$(bytes_to_human "$destination_free")"
        APPDATA_BACKUP_PATH="$staged_directory"
        STAGED_RECOVERY_PENDING=true
        return 1
    fi

    if [ -e "$destination_partial" ] || [ -e "$destination_final" ]; then
        log "STAGING" "ERROR" \
            "Destination generation path already exists: $destination_partial or $destination_final"
        APPDATA_BACKUP_PATH="$staged_directory"
        STAGED_RECOVERY_PENDING=true
        return 1
    fi

    if ! mkdir -p -- "$destination_partial"; then
        log "STAGING" "ERROR" \
            "Unable to create vault transfer directory: $destination_partial"
        APPDATA_BACKUP_PATH="$staged_directory"
        STAGED_RECOVERY_PENDING=true
        return 1
    fi

    if ! "${PRIORITY_PREFIX[@]}" \
        rsync \
        -aH \
        --delete-delay \
        -- \
        "${staged_directory}/" \
        "${destination_partial}/" \
        >"$transfer_log" 2>&1
    then
        log "STAGING" "ERROR" \
            "Copy to vault failed; staged generation remains verified at: $staged_directory"
        APPDATA_BACKUP_PATH="$staged_directory"
        STAGED_RECOVERY_PENDING=true
        return 1
    fi

    if ! verify_backup_directory "$destination_partial" "$verify_log"; then
        log "STAGING" "ERROR" \
            "Vault copy failed checksum or manifest verification; staged generation was preserved"
        APPDATA_BACKUP_PATH="$staged_directory"
        STAGED_RECOVERY_PENDING=true
        return 1
    fi

    if ! mv -- "$destination_partial" "$destination_final"; then
        log "STAGING" "ERROR" \
            "Verified vault copy could not be promoted: $destination_partial"
        APPDATA_BACKUP_PATH="$staged_directory"
        STAGED_RECOVERY_PENDING=true
        return 1
    fi

    FINAL_DIR="$destination_final"
    APPDATA_BACKUP_PATH="$destination_final"
    STAGED_RECOVERY_PENDING=false

    if ! rm -rf -- "$staged_directory"; then
        log "STAGING" "WARN" \
            "Vault backup is valid, but the redundant staged generation could not be removed: $staged_directory"
    fi

    log "STAGING" "INFO" \
        "Verified staged generation copied, re-verified, and promoted on vault: $destination_final"

    return 0
}


find_pending_staged_backup() {
    [ -d "$STAGING_DIR" ] || return 0

    list_paths_by_mtime \
        "$STAGING_DIR" \
        d \
        'backup_*.staged' |
        tail -n 1
}


recover_pending_staged_backup() {
    local pending=""

    pending="$(find_pending_staged_backup)"
    [ -n "$pending" ] || return 2

    log "STAGING" "WARN" \
        "Found a completed staged generation from an earlier run: $pending"

    if transfer_staged_backup "$pending"; then
        log "STAGING" "INFO" \
            "Earlier staged generation was recovered to the vault; no new archive run is needed"
        return 0
    fi

    return 1
}


###############################################################################
# APPDATA BACKUP
###############################################################################

run_appdata_backup() {
    local directory=""
    local name=""
    local archive=""
    local archive_bytes=0
    local archive_human=""
    local error_file=""
    local excerpt=""
    local predicted_bytes=0
    local generation_error="${TEMP_DIR}/generation-verify.err"

    APPDATA_OK=0
    APPDATA_FAILED=0
    APPDATA_SKIPPED=0
    APPDATA_TOTAL_BYTES=0
    APPDATA_FINALIZE_FAILED=0
    RETENTION_FAILED=0
    APPDATA_REPORT=""
    APPDATA_BACKUP_PATH=""

    log "BACKUP" "INFO" \
        "Starting appdata archive phase"

    for directory in "${APPDATA_DIRS[@]}"; do
        name="$(basename "$directory")"

        if array_contains "$name" "${SKIP_APPDATA_DIRS[@]}"; then
            APPDATA_SKIPPED=$((APPDATA_SKIPPED + 1))

            APPDATA_REPORT+="[SKIPPED] [${name}] User exclusion"$'\n'

            log "DOCKER" "INFO" \
                "[${name}] Skipped due to SKIP_APPDATA_DIRS"

            continue
        fi

        log "DOCKER" "INFO" \
            "[${name}] Creating archive"

        if compress_directory "$name"; then
            archive="${WORK_DIR}/${name}.tar.gz"
            archive_bytes="$(file_size_bytes "$archive")"
            archive_human="$(bytes_to_human "$archive_bytes")"

            APPDATA_OK=$((APPDATA_OK + 1))
            APPDATA_TOTAL_BYTES=$((APPDATA_TOTAL_BYTES + archive_bytes))

            APPDATA_REPORT+="[OK] [${name}] ${archive_human}"$'\n'

            log "DOCKER" "INFO" \
                "[${name}] Backup complete: ${archive_human}"

            predicted_bytes="${PREDICTED_ARCHIVE_BYTES[$name]:-0}"
            REMAINING_ESTIMATED_BYTES=$((
                REMAINING_ESTIMATED_BYTES - predicted_bytes
            ))
            [ "$REMAINING_ESTIMATED_BYTES" -ge 0 ] ||
                REMAINING_ESTIMATED_BYTES=0

            if [ "$KEEP_TEMP_ERR" = "true" ]; then
                cp -f -- "${TEMP_DIR}/${name}.err" \
                    "${WORK_DIR}/${name}.err" 2>/dev/null || true
            fi
        else
            APPDATA_FAILED=$((APPDATA_FAILED + 1))

            error_file="${TEMP_DIR}/${name}.err"

            excerpt="$(
                tail \
                    -n 20 \
                    "$error_file" \
                    2>/dev/null ||
                    true
            )"

            APPDATA_REPORT+="[FAILED] [${name}] ${LAST_COMPRESSION_REASON:-unclassified compression failure}"$'\n'

            if [ -n "$excerpt" ]; then
                APPDATA_REPORT+="---- stderr excerpt ----"$'\n'
                APPDATA_REPORT+="${excerpt}"$'\n'
                APPDATA_REPORT+="------------------------"$'\n'
            fi

            log "DOCKER" "ERROR" \
                "[${name}] Backup failed after ${LAST_COMPRESSION_ATTEMPTS} attempt(s)"

            if [ "$KEEP_TEMP_ERR" = "true" ]; then
                cp -f -- "$error_file" "${WORK_DIR}/${name}.err" \
                    2>/dev/null || true
            fi

            if [ "$LAST_COMPRESSION_FATAL" = "true" ]; then
                log "BACKUP" "ERROR" \
                    "Stopping the archive phase after a fatal capacity or process failure"
                break
            fi
        fi
    done

    if [ "$APPDATA_FAILED" -eq 0 ]; then
        if ! create_backup_manifest; then
            APPDATA_FINALIZE_FAILED=1
            log "VERIFY" "ERROR" \
                "Unable to create the checksum-protected backup manifest"
        elif [ "$BACKUP_MODE" = "destination" ]; then
            if ! verify_backup_directory "$WORK_DIR" "$generation_error"; then
                APPDATA_FINALIZE_FAILED=1
                excerpt="$(tail -n 20 "$generation_error" 2>/dev/null || true)"
                APPDATA_REPORT+="[FAILED] Generation checksum verification"$'\n'
                [ -n "$excerpt" ] && APPDATA_REPORT+="${excerpt}"$'\n'
                log "VERIFY" "ERROR" \
                    "Completed generation failed checksum or manifest verification"
            elif mv -- "$WORK_DIR" "$FINAL_DIR"; then
                APPDATA_BACKUP_PATH="$FINAL_DIR"

                log "BACKUP" "INFO" \
                    "Appdata backup verified and finalized: $FINAL_DIR"

                # The previous successful generation is deliberately retained
                # until this new verified generation has been promoted.
                if ! prune_successful_backups; then
                    RETENTION_FAILED=1
                    log "BACKUP" "ERROR" \
                        "New backup is valid, but old successful backup pruning failed"
                fi

                return 0
            else
                APPDATA_FINALIZE_FAILED=1
                log "BACKUP" "ERROR" \
                    "Unable to promote partial backup directory to final backup directory"
            fi
        else
            if mv -- "$WORK_DIR" "$STAGED_DIR"; then
                APPDATA_BACKUP_PATH="$STAGED_DIR"
                log "STAGING" "INFO" \
                    "Replacement completed and archive-tested on staging: $STAGED_DIR"

                # transfer_staged_backup performs the one complete staged
                # checksum pass before the previous vault generation is
                # retired, then verifies the copied vault generation once.
                if transfer_staged_backup "$STAGED_DIR"; then
                    return 0
                fi

                APPDATA_FINALIZE_FAILED=1
                return 1
            fi

            APPDATA_FINALIZE_FAILED=1
            log "STAGING" "ERROR" \
                "Unable to promote partial staging directory: $WORK_DIR"
        fi
    fi

    if [ "$KEEP_PARTIAL" = "true" ] && [ -d "$WORK_DIR" ]; then
        APPDATA_BACKUP_PATH="$WORK_DIR"

        log "BACKUP" "WARN" \
            "Keeping incomplete appdata backup for inspection: $WORK_DIR"
    elif [ -d "$WORK_DIR" ]; then
        rm -rf -- "$WORK_DIR"
        APPDATA_BACKUP_PATH="Removed"

        log "BACKUP" "INFO" \
            "Removed incomplete appdata backup because KEEP_PARTIAL=false"
    fi

    prune_partial_backups "$WORK_ROOT"

    return 1
}


###############################################################################
# OPTIONAL SHARES BACKUP
###############################################################################

rsync_exit_description() {
    local code="$1"

    case "$code" in
        10) printf 'Socket I/O error' ;;
        11) printf 'File I/O error' ;;
        12) printf 'Protocol stream error' ;;
        23) printf 'Partial transfer' ;;
        24) printf 'Source vanished' ;;
        30) printf 'Timeout' ;;
        *)  printf 'Exit %s' "$code" ;;
    esac
}


rsync_stat_value() {
    local log_file="$1"
    local label="$2"
    local value=""

    value="$(
        grep -F -i "$label" "$log_file" 2>/dev/null |
            tail -n 1 |
            sed -E \
                's/^[^:]*:[[:space:]]*([0-9,]+).*/\1/' |
            tr -d ','
    )"

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$value"
    else
        printf '0\n'
    fi
}


run_shares_backup() {
    local descriptor=""
    local share_name=""
    local share_src=""
    local share_dest=""
    local share_excludes=""
    local share_excludes_file=""

    local pattern=""
    local tmp_log=""
    local status=0
    local status_description=""

    local total_tx_bytes=0
    local files_tx=0
    local deleted_count=0
    local bytes_sent=0

    local human_tx=""
    local human_sent=""

    local command_string=""

    local -a excludes=()
    local -a exclude_list=()
    local -a rsync_command=()

    SHARES_TOTAL=0
    SHARES_OK=0
    SHARES_FAILED=0
    SHARES_SKIPPED=0
    SHARES_TOTAL_BYTES=0
    SHARES_REPORT=""

    log "SHARES" "INFO" \
        "Starting optional share backup phase with ${#ADD_SHARES[@]} configured descriptor(s)"

    if [ "${#ADD_SHARES[@]}" -eq 0 ]; then
        log "SHARES" "INFO" "No additional shares configured"
        return 0
    fi

    for descriptor in "${ADD_SHARES[@]}"; do
        [ -n "$descriptor" ] || continue

        share_name=""
        share_src=""
        share_dest=""
        share_excludes=""
        share_excludes_file=""

        IFS='|' read -r \
            share_name \
            share_src \
            share_dest \
            share_excludes \
            share_excludes_file \
            <<<"$descriptor"

        SHARES_TOTAL=$((SHARES_TOTAL + 1))

        if [ -z "$share_name" ]; then
            share_name="share_${SHARES_TOTAL}"
        fi

        if [ ! -d "$share_src" ]; then
            SHARES_SKIPPED=$((SHARES_SKIPPED + 1))

            SHARES_REPORT+="[SKIPPED] ${share_name}: source missing"$'\n'

            log "SHARES" "WARN" \
                "[${share_name}] Source missing: $share_src"

            continue
        fi

        if ! ensure_dir "$share_dest"; then
            SHARES_FAILED=$((SHARES_FAILED + 1))

            SHARES_REPORT+="[FAILED] ${share_name}: Unable to create destination"$'\n'

            log "SHARES" "ERROR" \
                "[${share_name}] Unable to create destination: $share_dest"

            continue
        fi

        excludes=()

        if [ -n "$share_excludes" ]; then
            IFS=',' read -r -a exclude_list <<<"$share_excludes"

            for pattern in "${exclude_list[@]}"; do
                [ -n "$pattern" ] || continue
                excludes+=("--exclude=${pattern}")
            done
        fi

        if [ -n "$share_excludes_file" ]; then
            if [ -f "$share_excludes_file" ]; then
                excludes+=("--exclude-from=${share_excludes_file}")

                log "SHARES" "INFO" \
                    "[${share_name}] Using exclude file: $share_excludes_file"
            else
                log "SHARES" "WARN" \
                    "[${share_name}] Exclude file missing and will be ignored: $share_excludes_file"
            fi
        fi

        tmp_log="$(mktemp /tmp/appdata_backup_rsync.XXXXXX)"

        rsync_command=(
            "${PRIORITY_PREFIX[@]}"
            rsync
            "${ADD_RSYNC_BASE_ARGS[@]}"
            "${excludes[@]}"
            "${share_src}/"
            "${share_dest}/"
        )

        printf -v command_string '%q ' "${rsync_command[@]}"

        log "SHARES" "INFO" \
            "[${share_name}] Running: ${command_string}"

        "${rsync_command[@]}" >"$tmp_log" 2>&1
        status=$?

        while IFS= read -r line; do
            [ -n "$line" ] || continue

            log "SHARES" "INFO" \
                "[rsync:${share_name}] $line"
        done <"$tmp_log"

        if [ "$status" -ne 0 ]; then
            status_description="$(rsync_exit_description "$status")"

            SHARES_FAILED=$((SHARES_FAILED + 1))

            SHARES_REPORT+="[FAILED] ${share_name}: ${status_description}"$'\n'

            log "SHARES" "ERROR" \
                "[${share_name}] Rsync failed: ${status_description}"

            rm -f -- "$tmp_log"
            continue
        fi

        total_tx_bytes="$(
            rsync_stat_value \
                "$tmp_log" \
                "Total transferred file size"
        )"

        files_tx="$(
            rsync_stat_value \
                "$tmp_log" \
                "Number of regular files transferred"
        )"

        deleted_count="$(
            rsync_stat_value \
                "$tmp_log" \
                "Number of deleted files"
        )"

        bytes_sent="$(
            rsync_stat_value \
                "$tmp_log" \
                "Total bytes sent"
        )"

        SHARES_TOTAL_BYTES=$((SHARES_TOTAL_BYTES + total_tx_bytes))
        SHARES_OK=$((SHARES_OK + 1))

        human_tx="$(bytes_to_human "$total_tx_bytes")"
        human_sent="$(bytes_to_human "$bytes_sent")"

        SHARES_REPORT+="[OK] ${share_name}: Transferred ${human_tx}, files ${files_tx}, deleted ${deleted_count}, sent ${human_sent}"$'\n'

        rm -f -- "$tmp_log"
    done

    [ "$SHARES_FAILED" -eq 0 ]
}


###############################################################################
# FINAL REPORTING
###############################################################################

build_space_block() {
    local output=""

    if refresh_destination_space; then
        output+="Destination space:"$'\n'
        output+="  Total: $(bytes_to_human "$DEST_TOTAL_BYTES")"$'\n'
        output+="  Used:  $(bytes_to_human "$DEST_USED_BYTES")"$'\n'
        output+="  Free:  $(bytes_to_human "$DEST_FREE_BYTES") (${DEST_FREE_PERCENT}%)"$'\n'
        output+="  Estimated archive size: $(bytes_to_human "$ESTIMATED_BACKUP_BYTES")"$'\n'
        output+="  Reserved free space: $(bytes_to_human "$MIN_FREE_RESERVE_BYTES")"$'\n'
        output+="  Estimated total requirement: $(bytes_to_human "$ESTIMATED_REQUIRED_BYTES")"$'\n'
        output+="  Raw source measured: $(bytes_to_human "$RAW_TOTAL_BYTES") across ${RAW_MEASURED_COUNT} app(s)"$'\n'
        output+="  History-based estimates: ${HISTORY_ESTIMATE_COUNT} app(s)"$'\n'
        output+="  Estimate method: ${ESTIMATE_METHOD}"$'\n'
        output+="  Backup path mode: ${BACKUP_MODE}"$'\n'
    else
        output+="Destination space: unavailable"$'\n'
    fi

    printf '%s' "$output"
}


send_final_notification() {
    local runtime_human="$1"

    local appdata_size_human=""
    local shares_size_human=""

    local appdata_status="OK"
    local shares_status="OK"
    local restart_status="OK"
    local retention_status="OK"
    local overall_status="OK"

    local importance="normal"
    local description=""
    local body=""

    appdata_size_human="$(bytes_to_human "$APPDATA_TOTAL_BYTES")"
    shares_size_human="$(bytes_to_human "$SHARES_TOTAL_BYTES")"

    if [ "$APPDATA_FAILED" -gt 0 ] ||
       [ "$APPDATA_FINALIZE_FAILED" -gt 0 ]
    then
        appdata_status="FAILED"
        overall_status="FAILED"
    fi

    if [ "$RETENTION_FAILED" -gt 0 ]; then
        retention_status="FAILED"
        if [ "$overall_status" = "OK" ]; then
            overall_status="WARNING"
        fi
    fi

    if [ "$SHARES_FAILED" -gt 0 ]; then
        shares_status="FAILED"
        overall_status="FAILED"
    fi

    if [ "$RESTART_FAILED" -gt 0 ]; then
        restart_status="FAILED"
        overall_status="FAILED"
    fi

    if [ "$overall_status" = "FAILED" ]; then
        importance="alert"
    elif [ "$overall_status" = "WARNING" ]; then
        importance="warning"
    fi

    description="Appdata & Shares - ${overall_status}"

    body+="Runtime: ${runtime_human}"$'\n'
    body+=$'\n'

    body+="Appdata: ${appdata_status}"$'\n'
    body+="  Total:   ${APPDATA_TOTAL}"$'\n'
    body+="  OK:      ${APPDATA_OK}"$'\n'
    body+="  Failed:  ${APPDATA_FAILED}"$'\n'
    body+="  Skipped: ${APPDATA_SKIPPED}"$'\n'
    body+="  Size:    ${appdata_size_human}"$'\n'

    if [ "$APPDATA_FINALIZE_FAILED" -gt 0 ]; then
        body+="  Finalize: FAILED"$'\n'
    fi

    if [ "$RETENTION_FAILED" -gt 0 ]; then
        body+="  Retention cleanup: ${retention_status} (new backup remains valid)"$'\n'
    fi

    if [ -n "$APPDATA_BACKUP_PATH" ]; then
        body+="  Path: ${APPDATA_BACKUP_PATH}"$'\n'
    fi

    if [ "$STAGED_RECOVERY_PENDING" = "true" ]; then
        body+="  Recovery: verified staged generation preserved for the next run"$'\n'
    fi

    body+=$'\n'
    body+="${APPDATA_REPORT}"

    body+=$'\n'
    body+="Container restart: ${restart_status}"$'\n'

    if [ "$RESTART_FAILED" -gt 0 ]; then
        body+="  Failed: ${RESTART_FAILED}"$'\n'
    fi

    if [ "$SHARES_TOTAL" -gt 0 ]; then
        body+=$'\n'
        body+="Shares: ${shares_status}"$'\n'
        body+="  Total:   ${SHARES_TOTAL}"$'\n'
        body+="  OK:      ${SHARES_OK}"$'\n'
        body+="  Failed:  ${SHARES_FAILED}"$'\n'
        body+="  Skipped: ${SHARES_SKIPPED}"$'\n'
        body+="  Size:    ${shares_size_human}"$'\n'
        body+=$'\n'
        body+="${SHARES_REPORT}"
    fi

    body+=$'\n'
    body+="$(build_space_block)"

    notify_unraid \
        "$importance" \
        "$description" \
        "$body"
}


###############################################################################
# MAIN
###############################################################################

main() {
    local runtime_seconds=0
    local runtime_human=""
    local final_exit=0
    local recovery_status=0

    if ! acquire_lock; then
        return 1
    fi

    # -----------------------------------------------------------------------
    # Logging initialization
    # -----------------------------------------------------------------------

    if ! ensure_dir "$LOG_DIR"; then
        printf '%s ERROR: Unable to create log directory: %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$LOG_DIR"
        return 1
    fi

    if ! : >"$LOG_FILE"; then
        printf '%s ERROR: Unable to create log file: %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$LOG_FILE"
        return 1
    fi

    TEMP_DIR="$(mktemp -d "/tmp/appdata_backup.${RUN_STAMP}.XXXXXX")" || {
        printf '%s ERROR: Unable to create runtime diagnostic directory\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')"
        return 1
    }
    MANIFEST_DATA_FILE="${TEMP_DIR}/manifest.data"
    : >"$MANIFEST_DATA_FILE"

    trap 'exit_code=$?; handle_exit "$exit_code"' EXIT
    trap 'handle_signal INT' INT
    trap 'handle_signal TERM' TERM

    START_TIME="$(date +%s)"

    log "BACKUP" "INFO" \
        "Scheduled appdata backup started"

    log "BACKUP" "INFO" \
        "Source: $SRC_DIR"

    log "BACKUP" "INFO" \
        "Destination: $DEST_DIR"

    # Keep log retention independent from successful-backup retention.
    # Backup pruning is deferred until configuration and source validation
    # have succeeded.
    prune_logs


    # -----------------------------------------------------------------------
    # Preflight
    # -----------------------------------------------------------------------

    if ! validate_configuration; then
        notify_unraid \
            "alert" \
            "Backup FAILED" \
            "Configuration or path validation failed.
See log:
${LOG_FILE}"

        return 1
    fi

    build_priority_prefix

    # Incomplete directories never compete with a new backup. Diagnostics are
    # held under /tmp, so failed partial data can be reclaimed immediately.
    if ! prune_partial_backups "$DEST_DIR" 0; then
        notify_unraid \
            "alert" \
            "Backup FAILED - Cleanup" \
            "Unable to remove an old vault partial backup.
Destination: ${DEST_DIR}
See log:
${LOG_FILE}"
        return 1
    fi

    if [ "$BACKUP_STORAGE_MODE" != "destination" ] &&
       [ -e "$STAGING_DIR" ] &&
       ! validate_staging_location
    then
        notify_unraid \
            "alert" \
            "Backup FAILED - Staging" \
            "The alternate staging location is unavailable or unsafe.
Staging: ${STAGING_DIR}
Mount root: ${STAGING_MOUNT_ROOT}
See log:
${LOG_FILE}"
        return 1
    fi

    if [ -d "$STAGING_DIR" ] &&
       ! prune_partial_backups "$STAGING_DIR" 0
    then
        notify_unraid \
            "alert" \
            "Backup FAILED - Cleanup" \
            "Unable to remove an old staging partial backup.
Staging: ${STAGING_DIR}
See log:
${LOG_FILE}"
        return 1
    fi

    # A .staged directory is not partial data: it is a completed, verified
    # generation retained because an earlier vault transfer could not finish.
    if [ "$BACKUP_STORAGE_MODE" != "destination" ]; then
        recover_pending_staged_backup
        recovery_status=$?

        if [ "$recovery_status" -eq 0 ]; then
            notify_unraid \
                "normal" \
                "Backup staging recovery complete" \
                "A previously verified appdata generation was copied to the vault and verified again.
Path: ${APPDATA_BACKUP_PATH}"
            prune_logs
            return 0
        fi

        if [ "$recovery_status" -eq 1 ]; then
            notify_unraid \
                "alert" \
                "Backup FAILED - Staging Recovery" \
                "A verified or pending staged generation could not be finalized.
It was preserved at:
${APPDATA_BACKUP_PATH:-${STAGING_DIR}}
See log:
${LOG_FILE}"
            return 1
        fi
    fi

    if ! collect_appdata_directories; then
        notify_unraid \
            "alert" \
            "Backup FAILED" \
            "No eligible appdata directories were found.
Source:
${SRC_DIR}"

        return 1
    fi

    calculate_space_estimate

    if ! select_backup_workspace; then
        notify_unraid \
            "alert" \
            "Backup FAILED - Low Space" \
            "Vault available: $(bytes_to_human "$DEST_FREE_BYTES")
Estimated backup: $(bytes_to_human "$ESTIMATED_BACKUP_BYTES")
Reserve: $(bytes_to_human "$MIN_FREE_RESERVE_BYTES")
Estimated total required: $(bytes_to_human "$ESTIMATED_REQUIRED_BYTES")
Vault: ${DEST_DIR}
Staging: ${STAGING_DIR}"

        return 1
    fi

    if [ -e "$WORK_DIR" ]; then
        log "PREFLIGHT" "ERROR" \
            "Partial working directory already exists: $WORK_DIR"

        notify_unraid \
            "alert" \
            "Backup FAILED" \
            "Working backup directory already exists:
${WORK_DIR}"

        return 1
    fi

    if ! mkdir -p -- "$WORK_DIR"; then
        log "PREFLIGHT" "ERROR" \
            "Unable to create working backup directory: $WORK_DIR"

        notify_unraid \
            "alert" \
            "Backup FAILED" \
            "Unable to create:
${WORK_DIR}"

        return 1
    fi


    # -----------------------------------------------------------------------
    # Stop Docker containers
    # -----------------------------------------------------------------------

    discover_target_containers

    if ! stop_target_containers; then
        log "DOCKER" "ERROR" \
            "One or more containers failed to stop; appdata backup will not continue"

        # Do an explicit restart before returning. The EXIT trap remains as a
        # secondary safety mechanism.
        restart_target_containers || true

        rm -rf -- "$WORK_DIR" 2>/dev/null || true

        notify_unraid \
            "alert" \
            "Backup FAILED - Docker Stop" \
            "One or more Docker containers could not be stopped safely.
Appdata backup was not started.
See log:
${LOG_FILE}"

        return 1
    fi


    # -----------------------------------------------------------------------
    # Appdata backup
    # -----------------------------------------------------------------------

    run_appdata_backup || final_exit=1


    # -----------------------------------------------------------------------
    # Restart Docker containers
    # -----------------------------------------------------------------------

    if ! restart_target_containers; then
        final_exit=1
    fi


    # -----------------------------------------------------------------------
    # Optional share backup
    # -----------------------------------------------------------------------

    if ! run_shares_backup; then
        final_exit=1
    fi


    # -----------------------------------------------------------------------
    # Final status
    # -----------------------------------------------------------------------

    runtime_seconds=$(($(date +%s) - START_TIME))
    runtime_human="$(format_duration "$runtime_seconds")"

    log "BACKUP" "INFO" \
        "Scheduled backup finished in ${runtime_human}"

    if [ "$APPDATA_FAILED" -gt 0 ] ||
       [ "$APPDATA_FINALIZE_FAILED" -gt 0 ] ||
       [ "$RETENTION_FAILED" -gt 0 ] ||
       [ "$SHARES_FAILED" -gt 0 ] ||
       [ "$RESTART_FAILED" -gt 0 ]
    then
        final_exit=1
    fi

    send_final_notification "$runtime_human"


    # -----------------------------------------------------------------------
    # Temporary error-file cleanup
    # -----------------------------------------------------------------------

    prune_partial_backups "$DEST_DIR"
    [ -d "$STAGING_DIR" ] && prune_partial_backups "$STAGING_DIR"
    prune_logs

    return "$final_exit"
}


###############################################################################
# ENTRY POINT
###############################################################################

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
