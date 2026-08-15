#!/bin/bash

###############################################################################
# Appdata + Optional Shares Backup v2.0
#
# PURPOSE
# -------
# Create a verified backup of Docker appdata and optionally mirror additional
# shares with rsync.
#
# Appdata workflow:
#
#   1. Validate source/destination and available space
#   2. Record currently-running Docker containers
#   3. Stop selected running containers
#   4. Compress each top-level appdata directory
#   5. Verify every archive
#   6. Promote the .partial backup only when the entire appdata backup succeeds
#   7. Restart only containers that were running before the backup
#   8. Optionally mirror additional shares with rsync
#   9. Prune old successful backups/logs
#  10. Send one consolidated Unraid notification
#
#
# SAFETY
# ------
# - Only containers that were running before the backup are restarted.
# - A failed container stop aborts the appdata backup.
# - An EXIT/signal trap attempts to restart containers if the script exits
#   unexpectedly after stopping them.
# - Existing successful backups are pruned only AFTER a new backup succeeds.
# - New backups remain ".partial" until all archives pass verification.
# - Individual archives are written to ".tmp" first and promoted only after
#   gzip/tar integrity checks pass.
#
#
# SCHEDULING
# ----------
# Scheduling is managed externally by Unraid User Scripts.
# This script does not create or modify its own schedule.
#
###############################################################################

set -uo pipefail


###############################################################################
# CONFIGURATION
###############################################################################

# ---------------------------------------------------------------------------
# Appdata paths
# ---------------------------------------------------------------------------

SRC_DIR="/mnt/cache/appdata"
DEST_DIR="/mnt/vault/backup/cache"

LOG_DIR="/mnt/vault/cloud/logs/appdata_logs"


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
# The previous successful backup is not removed until the replacement backup
# has completed successfully.
#
MAX_BACKUPS=1

# Number of failed/incomplete ".partial" backup directories to retain.
#
MAX_PARTIAL_BACKUPS=1

# Number of per-run log files to retain.
#
MAX_LOGS=2

# Keep successfully-created archives from a failed/incomplete backup.
#
# true  = retain backup_TIMESTAMP.partial
# false = remove the incomplete backup directory
#
KEEP_PARTIAL=true

# Keep individual compression stderr files after the final report is built.
#
KEEP_TEMP_ERR=false


# ---------------------------------------------------------------------------
# Compression
# ---------------------------------------------------------------------------

# Number of compression attempts for each appdata directory.
#
RETRIES=3

# Delay between retries.
#
RETRY_DELAY=5

# pigz worker threads.
#
# 0 = allow pigz to choose automatically.
#
# If pigz is unavailable, gzip is used automatically.
#
PIGZ_THREADS=0

# Optional additional GNU tar arguments.
#
# Example:
#
# TAR_OPTIONS=(
#     "--exclude=cache"
# )
#
TAR_OPTIONS=()


# ---------------------------------------------------------------------------
# Process priority
# ---------------------------------------------------------------------------

# Apply nice/ionice to compression and rsync operations when available.
#
USE_LOW_PRIORITY_IO=true

IONICE_CLASS=2
IONICE_PRIORITY=7
NICE_LEVEL=10


# ---------------------------------------------------------------------------
# Destination-space estimation
# ---------------------------------------------------------------------------

# Estimated compressed size:
#
#     raw appdata size × REQUIRED_RATIO
#
# This is an estimate only. Actual compression ratio varies between apps.
#
REQUIRED_RATIO=0.60

# Additional number of bytes added to the preflight requirement.
#
# Examples:
#
#   0              = no margin
#   10737418240    = 10 GiB
#   21474836480    = 20 GiB
#
LOW_SPACE_MARGIN=0

# Behavior if estimated required space exceeds currently available space.
#
#   abort = do not stop containers; terminate before backup begins
#   warn  = log warning and continue
#
LOW_SPACE_ACTION="abort"


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

NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
NOTIFY_SUBJECT="Scheduled Backup"


# ---------------------------------------------------------------------------
# Lock
# ---------------------------------------------------------------------------

LOCK_FILE="/tmp/appdata_backup.lock"


###############################################################################
# RUNTIME STATE
#
# Internal values below this point should not normally be modified.
###############################################################################

SRC_NAME="$(basename "${SRC_DIR%/}")"
RUN_STAMP="$(date '+%Y%m%d_%H%M%S')"

LOG_FILE="${LOG_DIR}/${SRC_NAME}-${RUN_STAMP}.log"

WORK_DIR="${DEST_DIR}/backup_${RUN_STAMP}.partial"
FINAL_DIR="${DEST_DIR}/backup_${RUN_STAMP}"

START_TIME=0

declare -a APPDATA_DIRS=()

declare -a RUNNING_CONTAINERS=()
declare -a TARGET_CONTAINERS=()
declare -a PRIORITY_PREFIX=()

CONTAINERS_NEED_RESTART=false

RAW_TOTAL_BYTES=0
ESTIMATED_REQUIRED_BYTES=0

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
APPDATA_REPORT=""
APPDATA_BACKUP_PATH=""

RESTART_FAILED=0

SHARES_TOTAL=0
SHARES_OK=0
SHARES_FAILED=0
SHARES_SKIPPED=0
SHARES_TOTAL_BYTES=0
SHARES_REPORT=""


###############################################################################
# LOCKING
###############################################################################

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    printf '%s %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "Another appdata_backup.sh run is active, exiting (lock: $LOCK_FILE)"
    exit 1
fi


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


log() {
    local category="$1"
    local level="$2"
    shift 2

    local message="$*"

    printf '%s [%s][%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$category" \
        "$level" \
        "$message" |
        tee -a "$LOG_FILE"
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

    if [[ "$size" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$size"
    else
        printf '0\n'
    fi
}


###############################################################################
# CONFIGURATION / PREFLIGHT
###############################################################################

validate_configuration() {
    if [ ! -d "$SRC_DIR" ]; then
        log "PREFLIGHT" "ERROR" "Source directory does not exist: $SRC_DIR"
        return 1
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
    local size=0

    APPDATA_DIRS=()

    RAW_TOTAL_BYTES=0
    APPDATA_TOTAL=0
    APPDATA_ELIGIBLE=0

    while IFS= read -r -d '' directory; do
        APPDATA_DIRS+=("$directory")
        APPDATA_TOTAL=$((APPDATA_TOTAL + 1))

        name="$(basename "$directory")"

        if array_contains "$name" "${SKIP_APPDATA_DIRS[@]}"; then
            continue
        fi

        APPDATA_ELIGIBLE=$((APPDATA_ELIGIBLE + 1))

        size="$(safe_size_bytes "$directory")"

        if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ]; then
            RAW_TOTAL_BYTES=$((RAW_TOTAL_BYTES + size))
        else
            log "PREFLIGHT" "WARN" \
                "Unable to determine size for appdata directory: $directory"
        fi

    done < <(
        find "$SRC_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -print0
    )

    log "PREFLIGHT" "INFO" \
        "Found ${APPDATA_TOTAL} top-level appdata directories; ${APPDATA_ELIGIBLE} eligible for backup"

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


assess_destination_space() {
    local free_human=""
    local required_human=""

    ESTIMATED_REQUIRED_BYTES="$(
        awk \
            -v raw="$RAW_TOTAL_BYTES" \
            -v ratio="$REQUIRED_RATIO" \
            -v margin="$LOW_SPACE_MARGIN" \
            'BEGIN { printf "%.0f", (raw * ratio) + margin }'
    )"

    if ! refresh_destination_space; then
        log "SPACE" "ERROR" \
            "Unable to determine filesystem capacity for: $DEST_DIR"
        return 1
    fi

    free_human="$(bytes_to_human "$DEST_FREE_BYTES")"
    required_human="$(bytes_to_human "$ESTIMATED_REQUIRED_BYTES")"

    log "SPACE" "INFO" \
        "Raw=$(bytes_to_human "$RAW_TOTAL_BYTES"), ratio=${REQUIRED_RATIO}, estimated required=${required_human}, available=${free_human}"

    if [ "$DEST_FREE_BYTES" -ge "$ESTIMATED_REQUIRED_BYTES" ]; then
        return 0
    fi

    case "$LOW_SPACE_ACTION" in
        abort)
            log "SPACE" "ERROR" \
                "Insufficient estimated space: required=${required_human}, available=${free_human}"
            return 1
            ;;

        warn)
            log "SPACE" "WARN" \
                "Estimated space is insufficient, but LOW_SPACE_ACTION=warn; continuing"
            return 0
            ;;
    esac
}


###############################################################################
# RETENTION
###############################################################################

prune_logs() {
    local -a logs=()
    local removed=0

    [ -d "$LOG_DIR" ] || return 0

    mapfile -t logs < <(
        find "$LOG_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            -type f \
            -name "${SRC_NAME}-*.log" \
            -printf '%T@\t%p\n' 2>/dev/null |
            sort -n |
            cut -f2-
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
    local -a backups=()
    local removed=0

    [ -d "$DEST_DIR" ] || return 0

    mapfile -t backups < <(
        find "$DEST_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -name 'backup_[0-9]*_[0-9]*' \
            ! -name '*.partial' \
            -printf '%T@\t%p\n' 2>/dev/null |
            sort -n |
            cut -f2-
    )

    while [ "${#backups[@]}" -gt "$MAX_BACKUPS" ]; do
        rm -rf -- "${backups[0]}"
        backups=("${backups[@]:1}")
        removed=$((removed + 1))
    done

    log "CLEANUP" "INFO" \
        "Successful-backup retention removed ${removed} old backup(s)"
}


prune_partial_backups() {
    local -a partials=()
    local removed=0

    [ -d "$DEST_DIR" ] || return 0

    mapfile -t partials < <(
        find "$DEST_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -name 'backup_*.partial' \
            -printf '%T@\t%p\n' 2>/dev/null |
            sort -n |
            cut -f2-
    )

    while [ "${#partials[@]}" -gt "$MAX_PARTIAL_BACKUPS" ]; do
        rm -rf -- "${partials[0]}"
        partials=("${partials[@]:1}")
        removed=$((removed + 1))
    done

    if [ "$removed" -gt 0 ]; then
        log "CLEANUP" "INFO" \
            "Partial-backup retention removed ${removed} old partial backup(s)"
    fi
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
            "docker ps failed; assuming Docker service has no running containers"
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
       [ -d "$WORK_DIR" ]
    then
        rm -rf -- "$WORK_DIR" 2>/dev/null || true
    fi
}


###############################################################################
# ARCHIVE CREATION / VERIFICATION
###############################################################################

verify_archive() {
    local archive="$1"
    local error_file="$2"

    if command -v pigz >/dev/null 2>&1; then
        if ! pigz -t "$archive" >/dev/null 2>>"$error_file"; then
            return 1
        fi
    else
        if ! gzip -t "$archive" >/dev/null 2>>"$error_file"; then
            return 1
        fi
    fi

    if ! tar -tzf "$archive" >/dev/null 2>>"$error_file"; then
        return 1
    fi

    return 0
}


compress_directory() {
    local name="$1"

    local archive="${WORK_DIR}/${name}.tar.gz"
    local archive_tmp="${archive}.tmp"
    local error_file="${WORK_DIR}/${name}.err"

    local attempt=0

    local -a compressor=()

    if command -v pigz >/dev/null 2>&1; then
        if [ "$PIGZ_THREADS" -gt 0 ]; then
            compressor=(
                pigz
                -p "$PIGZ_THREADS"
                -c
            )
        else
            compressor=(
                pigz
                -c
            )
        fi
    else
        compressor=(
            gzip
            -c
        )
    fi

    : >"$error_file"

    for ((attempt = 1; attempt <= RETRIES; attempt++)); do
        rm -f -- "$archive_tmp"

        printf '\n=== Compression attempt %d/%d ===\n' \
            "$attempt" \
            "$RETRIES" \
            >>"$error_file"

        log "DOCKER" "INFO" \
            "[${name}] compression attempt ${attempt}/${RETRIES}"

        if "${PRIORITY_PREFIX[@]}" \
                tar \
                -C "$SRC_DIR" \
                -cf - \
                "${TAR_OPTIONS[@]}" \
                -- "$name" \
                2>>"$error_file" |
           "${PRIORITY_PREFIX[@]}" \
                "${compressor[@]}" \
                2>>"$error_file" \
                >"$archive_tmp"
        then
            if verify_archive "$archive_tmp" "$error_file"; then
                if mv -f -- "$archive_tmp" "$archive"; then
                    log "VERIFY" "INFO" \
                        "[${name}] archive passed gzip and tar verification"
                    return 0
                fi

                printf 'Failed to promote temporary archive to final archive\n' \
                    >>"$error_file"
            else
                log "VERIFY" "ERROR" \
                    "[${name}] archive verification failed on attempt ${attempt}"
            fi
        else
            log "DOCKER" "ERROR" \
                "[${name}] compression pipeline failed on attempt ${attempt}"
        fi

        rm -f -- "$archive_tmp"

        if [ "$attempt" -lt "$RETRIES" ]; then
            sleep "$RETRY_DELAY"
        fi
    done

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

    APPDATA_OK=0
    APPDATA_FAILED=0
    APPDATA_SKIPPED=0
    APPDATA_TOTAL_BYTES=0
    APPDATA_FINALIZE_FAILED=0
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
                "[${name}] skipped due to SKIP_APPDATA_DIRS"

            continue
        fi

        log "DOCKER" "INFO" \
            "[${name}] creating archive"

        if compress_directory "$name"; then
            archive="${WORK_DIR}/${name}.tar.gz"
            archive_bytes="$(file_size_bytes "$archive")"
            archive_human="$(bytes_to_human "$archive_bytes")"

            APPDATA_OK=$((APPDATA_OK + 1))
            APPDATA_TOTAL_BYTES=$((APPDATA_TOTAL_BYTES + archive_bytes))

            APPDATA_REPORT+="[OK] [${name}] ${archive_human}"$'\n'

            log "DOCKER" "INFO" \
                "[${name}] backup complete: ${archive_human}"

            if [ "$KEEP_TEMP_ERR" != "true" ]; then
                rm -f -- "${WORK_DIR}/${name}.err"
            fi
        else
            APPDATA_FAILED=$((APPDATA_FAILED + 1))

            error_file="${WORK_DIR}/${name}.err"

            excerpt="$(
                tail \
                    -n 20 \
                    "$error_file" \
                    2>/dev/null ||
                    true
            )"

            APPDATA_REPORT+="[FAILED] [${name}]"$'\n'

            if [ -n "$excerpt" ]; then
                APPDATA_REPORT+="---- stderr excerpt ----"$'\n'
                APPDATA_REPORT+="${excerpt}"$'\n'
                APPDATA_REPORT+="------------------------"$'\n'
            fi

            log "DOCKER" "ERROR" \
                "[${name}] backup failed after ${RETRIES} attempt(s)"
        fi
    done

    if [ "$APPDATA_FAILED" -eq 0 ]; then
        if mv -- "$WORK_DIR" "$FINAL_DIR"; then
            APPDATA_BACKUP_PATH="$FINAL_DIR"

            log "BACKUP" "INFO" \
                "Appdata backup verified and finalized: $FINAL_DIR"

            # Important: old successful backups are pruned only AFTER this
            # replacement has completed successfully.
            prune_successful_backups

            return 0
        fi

        APPDATA_FINALIZE_FAILED=1

        log "BACKUP" "ERROR" \
            "Unable to promote partial backup directory to final backup directory"

        APPDATA_BACKUP_PATH="$WORK_DIR"

        return 1
    fi

    if [ "$KEEP_PARTIAL" = "true" ]; then
        APPDATA_BACKUP_PATH="$WORK_DIR"

        log "BACKUP" "WARN" \
            "Keeping incomplete appdata backup for inspection: $WORK_DIR"
    else
        rm -rf -- "$WORK_DIR"
        APPDATA_BACKUP_PATH="Removed"

        log "BACKUP" "INFO" \
            "Removed incomplete appdata backup because KEEP_PARTIAL=false"
    fi

    prune_partial_backups

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
                "[${share_name}] source missing: $share_src"

            continue
        fi

        if ! ensure_dir "$share_dest"; then
            SHARES_FAILED=$((SHARES_FAILED + 1))

            SHARES_REPORT+="[FAILED] ${share_name}: unable to create destination"$'\n'

            log "SHARES" "ERROR" \
                "[${share_name}] unable to create destination: $share_dest"

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
                    "[${share_name}] using exclude file: $share_excludes_file"
            else
                log "SHARES" "WARN" \
                    "[${share_name}] exclude file missing and will be ignored: $share_excludes_file"
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
            "[${share_name}] running: ${command_string}"

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
                "[${share_name}] rsync failed: ${status_description}"

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

        SHARES_REPORT+="[OK] ${share_name}: transferred ${human_tx}, files ${files_tx}, deleted ${deleted_count}, sent ${human_sent}"$'\n'

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
        output+="  Estimated appdata requirement: $(bytes_to_human "$ESTIMATED_REQUIRED_BYTES")"$'\n'
        output+="  Raw appdata measured: $(bytes_to_human "$RAW_TOTAL_BYTES")"$'\n'
        output+="  Estimated compression ratio: ${REQUIRED_RATIO}"$'\n'
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

    if [ -n "$APPDATA_BACKUP_PATH" ]; then
        body+="  Path: ${APPDATA_BACKUP_PATH}"$'\n'
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
    prune_logs
    prune_partial_backups


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

    if ! collect_appdata_directories; then
        notify_unraid \
            "alert" \
            "Backup FAILED" \
            "No eligible appdata directories were found.
Source:
${SRC_DIR}"

        return 1
    fi

    if ! assess_destination_space; then
        notify_unraid \
            "alert" \
            "Backup FAILED - Low Space" \
            "Available: $(bytes_to_human "$DEST_FREE_BYTES")
Estimated required: $(bytes_to_human "$ESTIMATED_REQUIRED_BYTES")
Destination: ${DEST_DIR}"

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
       [ "$SHARES_FAILED" -gt 0 ] ||
       [ "$RESTART_FAILED" -gt 0 ]
    then
        final_exit=1
    fi

    send_final_notification "$runtime_human"


    # -----------------------------------------------------------------------
    # Temporary error-file cleanup
    # -----------------------------------------------------------------------

    if [ "$KEEP_TEMP_ERR" != "true" ]; then
        if [ -d "$FINAL_DIR" ]; then
            find "$FINAL_DIR" \
                -maxdepth 1 \
                -type f \
                -name '*.err' \
                -delete \
                2>/dev/null ||
                true
        fi

        if [ -d "$WORK_DIR" ]; then
            find "$WORK_DIR" \
                -maxdepth 1 \
                -type f \
                -name '*.err' \
                -delete \
                2>/dev/null ||
                true
        fi
    fi

    prune_partial_backups
    prune_logs

    return "$final_exit"
}


###############################################################################
# ENTRY POINT
###############################################################################

main "$@"