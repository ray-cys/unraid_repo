#!/bin/bash

###############################################################################
# Unraid Boot Device Backup v2.0
#
# Designed for Unraid 7.4+
#
# Unraid 7.4 changed its native flash_backup helper to stream ZIP data to
# standard output. This script writes that stream directly into a hidden file
# on the configured SSD pool, verifies the completed ZIP, and atomically
# publishes it. Previous backups are pruned only after a new backup succeeds.
###############################################################################

set -uo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

BACKUP_DIR="/mnt/vault/backup/flash"
POOL_PATH="/mnt/vault"

MAX_BACKUPS=2
COMPRESSION_LEVEL=6

HELPER="/usr/local/emhttp/webGui/scripts/flash_backup"
NOTIFY="/usr/local/emhttp/webGui/scripts/notify"

LOCKFILE="/tmp/flash_backup.lock"

LOG_DIR="/mnt/user/cloud/logs/script/flash_backup"
LOG_FILE="${LOG_DIR}/flash_backup.log"
LOG_MAX_BYTES=$((2 * 1024 * 1024))
LOG_KEEP=3

###############################################################################
# INITIALIZATION
###############################################################################

START_TIME=$(date +%s)

HELPER_LOG=""
TEMP_FILE=""
WRITE_TEST=""

LOG_READY=false
LOG_FAILURE_REPORTED=false

###############################################################################
# GENERAL HELPERS
###############################################################################

log() {

    local line

    line="$(date '+%Y/%m/%d %T') : $*"

    printf '%s\n' "$line"

    if [ "$LOG_READY" = true ]; then

        if ! printf '%s\n' "$line" >>"$LOG_FILE"; then

            LOG_READY=false

            if [ "$LOG_FAILURE_REPORTED" = false ]; then

                LOG_FAILURE_REPORTED=true

                printf '%s : WARNING: Persistent log became unavailable: %s\n' \
                    "$(date '+%Y/%m/%d %T')" \
                    "$LOG_FILE" \
                    >&2

            fi
        fi
    fi

}

rotate_logs() {

    [ -f "$LOG_FILE" ] || return 0

    local size
    local i

    size=$(stat -c '%s' "$LOG_FILE" 2>/dev/null || echo 0)

    [[ "$size" =~ ^[0-9]+$ ]] || size=0

    (( size >= LOG_MAX_BYTES )) || return 0

    if (( LOG_KEEP <= 0 )); then

        : >"$LOG_FILE"
        return $?

    fi

    rm -f -- "${LOG_FILE}.${LOG_KEEP}" 2>/dev/null || return 1

    for ((i=LOG_KEEP-1; i>=1; i--)); do

        if [ -f "${LOG_FILE}.${i}" ]; then

            mv -f -- \
                "${LOG_FILE}.${i}" \
                "${LOG_FILE}.$((i + 1))" || return 1

        fi
    done

    mv -f -- "$LOG_FILE" "${LOG_FILE}.1"

}

initialize_logging() {

    local rotation_ok=true

    if ! [[ "$LOG_MAX_BYTES" =~ ^[0-9]+$ ]] ||
       ! [[ "$LOG_KEEP" =~ ^[0-9]+$ ]] ||
       (( LOG_MAX_BYTES <= 0 ))
    then

        log "WARNING: Invalid log rotation configuration; persistent logging disabled"
        return 0

    fi

    if ! mkdir -p -- "$LOG_DIR" 2>/dev/null; then

        log "WARNING: Persistent log directory unavailable: $LOG_DIR"
        return 0

    fi

    rotate_logs || rotation_ok=false

    if ! : >>"$LOG_FILE"; then

        log "WARNING: Persistent log is not writable: $LOG_FILE"
        return 0

    fi

    LOG_READY=true

    if [ "$rotation_ok" = false ]; then

        log "WARNING: Log rotation failed; continuing with the current log"

    fi

    log "Persistent log: $LOG_FILE"

}

runtime() {

    local seconds=$(( $(date +%s) - START_TIME ))

    printf '%dh:%dm:%ds' \
        $((seconds / 3600)) \
        $(((seconds % 3600) / 60)) \
        $((seconds % 60))

}

bytes_human() {

    local bytes="${1:-0}"

    awk -v b="$bytes" '
        BEGIN {
            if (b >= 1099511627776)
                printf "%.2f TB", b / 1099511627776
            else if (b >= 1073741824)
                printf "%.2f GB", b / 1073741824
            else if (b >= 1048576)
                printf "%.2f MB", b / 1048576
            else if (b >= 1024)
                printf "%.2f KB", b / 1024
            else
                printf "%d B", b
        }
    '

}

notify() {

    local importance="$1"
    local description="$2"
    local message="$3"

    if [ "$LOG_READY" = true ]; then

        message+=$'\n\n'"Log: $LOG_FILE"

    else

        message+=$'\n\n'"Persistent log unavailable; see the User Scripts output or Unraid system log."

    fi

    if [ ! -x "$NOTIFY" ]; then

        log "WARNING: Unraid notify command not found"
        return 0

    fi

    "$NOTIFY" \
        -i "$importance" \
        -s "Boot Device Backup" \
        -d "$description" \
        -m "$message" \
        >/dev/null 2>&1 || \
        log "WARNING: Notification command failed"

}

# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
cleanup() {

    local exit_code=$?
    local file

    trap - EXIT

    for file in "$HELPER_LOG" "$TEMP_FILE" "$WRITE_TEST"; do

        [ -n "$file" ] || continue
        [ -e "$file" ] || continue

        if ! rm -f -- "$file"; then

            log "WARNING: Unable to remove temporary file: $file"

        fi
    done

    return "$exit_code"

}

log_helper_diagnostics() {

    [ -s "$HELPER_LOG" ] || return 0

    log "Native helper diagnostics follow:"

    while IFS= read -r line; do

        log "HELPER: $line"

    done <"$HELPER_LOG"

}

read_unraid_value() {

    local key="$1"
    local fallback="$2"
    local value

    value=$(
        awk -v wanted="$key" '
            {
                separator = index($0, "=")

                if (separator <= 1)
                    next

                name = substr($0, 1, separator - 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)

                if (name != wanted)
                    next

                result = substr($0, separator + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", result)

                if (result ~ /^".*"$/)
                    result = substr(result, 2, length(result) - 2)

                print result
                exit
            }
        ' /var/local/emhttp/var.ini 2>/dev/null
    )

    printf '%s' "${value:-$fallback}"

}

filename_component() {

    printf '%s' "$1" |
        tr '[:upper:] ' '[:lower:]_' |
        sed -E \
            's/[^a-z0-9._-]+/_/g; s/^[_ .-]+//; s/[_ .-]+$//'

}

verify_zip() {

    local file="$1"

    [ -f "$file" ] || return 1
    [ -s "$file" ] || return 1

    if command -v unzip >/dev/null 2>&1; then

        unzip -tq "$file" >/dev/null 2>&1
        return $?

    fi

    local sig

    sig=$(head -c 4 "$file" 2>/dev/null || true)

    case "$sig" in
        $'PK\003\004'|$'PK\005\006'|$'PK\007\008')
            return 0
            ;;
    esac

    return 1

}

available_bytes() {

    local value

    value=$(
        df -B1 --output=avail "$BACKUP_DIR" 2>/dev/null |
        tail -n 1 |
        tr -d ' '
    )

    if [[ "$value" =~ ^[0-9]+$ ]]; then

        printf '%s' "$value"

    else

        printf '0'

    fi

}

prune_backups() {

    local -a files=()
    local entry
    local count
    local i

    while IFS= read -r -d '' entry; do

        files+=("${entry#*|}")

    done < <(
        find "$BACKUP_DIR" \
            -maxdepth 1 \
            -type f \
            \( \
                -name '*-boot-backup-*.zip' \
                -o -name '*-flash-backup-*.zip' \
            \) \
            -printf '%T@|%p\0' 2>/dev/null |
            sort -z -t'|' -k1,1nr
    )

    count=${#files[@]}

    if (( count <= MAX_BACKUPS )); then

        log "Backup retention: ${count}/${MAX_BACKUPS}; nothing to prune"
        return 0

    fi

    for ((i=MAX_BACKUPS; i<count; i++)); do

        log "Deleting old backup: ${files[$i]}"

        if ! rm -f -- "${files[$i]}"; then

            log "WARNING: Unable to delete old boot backup: ${files[$i]}"

        fi
    done

}

###############################################################################
# LOCK AND LOGGING
###############################################################################

exec 9>"$LOCKFILE"

if ! flock -n 9; then

    log "Another boot-device backup is already running."
    exit 1

fi

initialize_logging
trap cleanup EXIT

###############################################################################
# PRE-FLIGHT CHECKS
###############################################################################

log "Starting Unraid boot-device backup"

if [ ! -d "$POOL_PATH" ]; then

    log "ERROR: Pool path does not exist: $POOL_PATH"

    notify alert \
        "Backup - POOL UNAVAILABLE" \
        "Destination pool is unavailable."$'\n\n'"Pool: $POOL_PATH"$'\n'"Runtime: $(runtime)"

    exit 2

fi

if command -v findmnt >/dev/null 2>&1; then

    MOUNT_TARGET=$(
        findmnt -rn -T "$POOL_PATH" -o TARGET 2>/dev/null || true
    )

    if [ "$MOUNT_TARGET" != "$POOL_PATH" ]; then

        log "ERROR: $POOL_PATH is not an active mount point"
        log "Detected mount target: ${MOUNT_TARGET:-<none>}"

        notify alert \
            "Backup - POOL NOT MOUNTED" \
            "$POOL_PATH is not mounted."$'\n\n'"Backup aborted to prevent writing into RAM."$'\n'"Runtime: $(runtime)"

        exit 2

    fi

fi

case "$BACKUP_DIR" in
    "$POOL_PATH"|"$POOL_PATH"/*)
        ;;

    *)
        log "ERROR: Backup directory is outside the protected pool path"
        log "Pool: $POOL_PATH"
        log "Backup directory: $BACKUP_DIR"

        notify alert \
            "Backup - CONFIGURATION ERROR" \
            "Backup directory is outside the configured pool."$'\n\n'"Pool: $POOL_PATH"$'\n'"Directory: $BACKUP_DIR"$'\n'"Runtime: $(runtime)"

        exit 2
        ;;
esac

if [ ! -x "$HELPER" ]; then

    log "ERROR: Native Unraid backup helper not found: $HELPER"

    notify alert \
        "Backup - HELPER MISSING" \
        "Unable to locate:"$'\n'"$HELPER"$'\n\n'"Runtime: $(runtime)"

    exit 127

fi

if ! [[ "$COMPRESSION_LEVEL" =~ ^[0-9]+$ ]] ||
   (( COMPRESSION_LEVEL < 0 || COMPRESSION_LEVEL > 9 ))
then

    log "ERROR: Compression level must be an integer from 0 through 9"
    log "Configured value: $COMPRESSION_LEVEL"

    notify alert \
        "Backup - CONFIGURATION ERROR" \
        "Invalid compression level: $COMPRESSION_LEVEL"$'\n\n'"Use a value from 0 through 9."$'\n'"Runtime: $(runtime)"

    exit 2

fi

if ! [[ "$MAX_BACKUPS" =~ ^[0-9]+$ ]] || (( MAX_BACKUPS < 1 )); then

    log "ERROR: MAX_BACKUPS must be a positive integer"
    exit 2

fi

###############################################################################
# DESTINATION
###############################################################################

if [ ! -d "$BACKUP_DIR" ]; then

    log "Creating backup directory: $BACKUP_DIR"

    if ! mkdir -p -- "$BACKUP_DIR"; then

        log "ERROR: Unable to create $BACKUP_DIR"

        notify alert \
            "Backup - DIRECTORY ERROR" \
            "Unable to create:"$'\n'"$BACKUP_DIR"$'\n\n'"Runtime: $(runtime)"

        exit 3

    fi
fi

chmod 0775 "$BACKUP_DIR" 2>/dev/null || true

WRITE_TEST="$BACKUP_DIR/.flash_backup_write_test.$$"

if ! touch "$WRITE_TEST" 2>/dev/null; then

    log "ERROR: Destination is not writable: $BACKUP_DIR"

    notify alert \
        "Backup - NOT WRITABLE" \
        "Backup destination is not writable:"$'\n'"$BACKUP_DIR"$'\n\n'"Runtime: $(runtime)"

    exit 3

fi

rm -f -- "$WRITE_TEST"
WRITE_TEST=""

###############################################################################
# BACKUP IDENTITY AND SPACE ESTIMATE
###############################################################################

HELPER_LOG=$(mktemp /tmp/flash_backup_helper.XXXXXX) || {

    log "ERROR: Unable to create helper diagnostics file"
    exit 4

}

HOST_FALLBACK=$(hostname -s 2>/dev/null || printf 'tower')
SERVER_NAME=$(read_unraid_value "NAME" "$HOST_FALLBACK")
OS_VERSION=$(read_unraid_value "version" "unknown")

SERVER_SLUG=$(filename_component "$SERVER_NAME")
VERSION_SLUG=$(filename_component "$OS_VERSION")

[ -n "$SERVER_SLUG" ] || SERVER_SLUG="tower"
[ -n "$VERSION_SLUG" ] || VERSION_SLUG="unknown"

BACKUP_NAME="${SERVER_SLUG}-v${VERSION_SLUG}-boot-backup-$(date '+%Y%m%d-%H%M%S').zip"
BACKUP_FILE="$BACKUP_DIR/$BACKUP_NAME"
TEMP_FILE="$BACKUP_DIR/.${BACKUP_NAME}.tmp.$$"

log "Compression level: $COMPRESSION_LEVEL"
log "Reading native backup size estimate"

ESTIMATED_SOURCE_BYTES=$("$HELPER" size 2>"$HELPER_LOG")
SIZE_RC=$?
ESTIMATED_SOURCE_BYTES=${ESTIMATED_SOURCE_BYTES//[[:space:]]/}

if (( SIZE_RC != 0 )) ||
   ! [[ "$ESTIMATED_SOURCE_BYTES" =~ ^[0-9]+$ ]] ||
   (( ESTIMATED_SOURCE_BYTES <= 0 ))
then

    log "ERROR: Native helper could not calculate the backup size"
    log "Exit code: $SIZE_RC"
    log_helper_diagnostics

    notify alert \
        "Backup - SIZE CHECK FAILED" \
        "The native Unraid helper could not calculate the boot-device backup size."$'\n\n'"Exit code: $SIZE_RC"$'\n'"Runtime: $(runtime)"

    exit 5

fi

log "Estimated uncompressed content: $(bytes_human "$ESTIMATED_SOURCE_BYTES")"

AVAILABLE_BYTES=$(available_bytes)
REQUIRED_BYTES=$((
    ESTIMATED_SOURCE_BYTES +
    ESTIMATED_SOURCE_BYTES / 10 +
    1048576
))

log "Destination free space: $(bytes_human "$AVAILABLE_BYTES")"
log "Conservative required space: $(bytes_human "$REQUIRED_BYTES")"

if (( AVAILABLE_BYTES < REQUIRED_BYTES )); then

    log "ERROR: Insufficient destination space"

    notify alert \
        "Backup - NO SPACE" \
        "Insufficient destination space."$'\n\n'"Required: $(bytes_human "$REQUIRED_BYTES")"$'\n'"Available: $(bytes_human "$AVAILABLE_BYTES")"$'\n'"Destination: $BACKUP_DIR"$'\n'"Runtime: $(runtime)"

    exit 7

fi

###############################################################################
# STREAM UNRAID 7.4 BACKUP
###############################################################################

: >"$HELPER_LOG"

log "Streaming native Unraid backup to the SSD"
log "Temporary destination: $TEMP_FILE"

"$HELPER" "$COMPRESSION_LEVEL" >"$TEMP_FILE" 2>"$HELPER_LOG"
HELPER_RC=$?

if (( HELPER_RC != 0 )); then

    log "ERROR: Native backup helper exited with code $HELPER_RC"
    log_helper_diagnostics

    HELPER_EXCERPT=$(tail -n 20 "$HELPER_LOG" 2>/dev/null || true)
    [ -n "$HELPER_EXCERPT" ] || HELPER_EXCERPT="No helper diagnostics were produced."

    notify alert \
        "Backup - FAILED" \
        "Native Unraid backup helper failed."$'\n\n'"Exit code: $HELPER_RC"$'\n\n'"${HELPER_EXCERPT}"$'\n\n'"Runtime: $(runtime)"

    exit 6

fi

if [ -s "$HELPER_LOG" ]; then

    log "WARNING: Native helper completed with diagnostic output"
    log_helper_diagnostics

fi

GENERATED_SIZE=$(stat -c '%s' "$TEMP_FILE" 2>/dev/null || echo 0)

if ! [[ "$GENERATED_SIZE" =~ ^[0-9]+$ ]] || (( GENERATED_SIZE <= 0 )); then

    log "ERROR: Native helper produced an empty backup stream"

    notify alert \
        "Backup - EMPTY ARCHIVE" \
        "The native Unraid helper completed without producing backup data."$'\n\n'"Runtime: $(runtime)"

    exit 8

fi

log "Generated archive size: $(bytes_human "$GENERATED_SIZE")"
log "Verifying generated ZIP archive"

if ! verify_zip "$TEMP_FILE"; then

    log "ERROR: Generated ZIP verification failed"

    notify alert \
        "Backup - CORRUPT ARCHIVE" \
        "Unraid created a backup stream that failed ZIP integrity verification."$'\n\n'"File: $BACKUP_NAME"$'\n'"Size: $(bytes_human "$GENERATED_SIZE")"$'\n'"Runtime: $(runtime)"

    exit 9

fi

log "Generated ZIP verification passed"

###############################################################################
# ATOMIC FINALIZATION
###############################################################################

if ! mv -f -- "$TEMP_FILE" "$BACKUP_FILE"; then

    log "ERROR: Unable to finalize destination archive"

    notify alert \
        "Backup - FINALIZE FAILED" \
        "Backup was generated but could not be finalized."$'\n\n'"Destination: $BACKUP_FILE"$'\n'"Runtime: $(runtime)"

    exit 10

fi

TEMP_FILE=""

log "Backup finalized successfully"

chown nobody:users "$BACKUP_FILE" 2>/dev/null || \
    log "WARNING: Unable to set backup ownership: $BACKUP_FILE"

chmod 0644 "$BACKUP_FILE" 2>/dev/null || \
    log "WARNING: Unable to set backup permissions: $BACKUP_FILE"

###############################################################################
# RETENTION
###############################################################################

# This deliberately runs only after generation, integrity verification, and
# finalization have all succeeded.
prune_backups

###############################################################################
# SUCCESS
###############################################################################

BACKUP_SIZE=$(stat -c '%s' "$BACKUP_FILE" 2>/dev/null || echo 0)
AVAILABLE_BYTES=$(available_bytes)
RUNTIME=$(runtime)

log "Boot-device backup completed successfully"
log "File: $BACKUP_NAME"
log "Size: $(bytes_human "$BACKUP_SIZE")"
log "Destination: $BACKUP_DIR"
log "Runtime: $RUNTIME"

notify normal \
    "Backup - OK" \
    "Boot-device backup completed successfully."$'\n\n'"File: $BACKUP_NAME"$'\n'"Size: $(bytes_human "$BACKUP_SIZE")"$'\n'"Destination: $BACKUP_DIR"$'\n'"Free space: $(bytes_human "$AVAILABLE_BYTES")"$'\n'"Retention: $MAX_BACKUPS backups"$'\n'"Runtime: $RUNTIME"

exit 0
