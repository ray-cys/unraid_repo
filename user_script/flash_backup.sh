#!/bin/bash

###############################################################################
# Unraid Boot Device Backup
#
# Designed for Unraid 7.3+
#
# Uses Unraid's native boot-device backup helper, verifies the generated ZIP,
# copies it safely to the configured SSD backup directory, verifies the copied
# archive, then removes the temporary source archive.
###############################################################################

set -uo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

BACKUP_DIR="/mnt/vault/backup/flash"
POOL_PATH="/mnt/vault"

MAX_BACKUPS=3

HELPER="/usr/local/emhttp/webGui/scripts/flash_backup"
NOTIFY="/usr/local/emhttp/webGui/scripts/notify"

LOCKFILE="/tmp/flash_backup.lock"

###############################################################################
# INITIALIZATION
###############################################################################

START_TIME=$(date +%s)

MARKER=""
HELPER_LOG=""
TEMP_FILE=""

###############################################################################
# FUNCTIONS
###############################################################################

log() {

    printf '%s : %s\n' "$(date '+%Y/%m/%d %T')" "$*"

}

syslog() {

    local level="$1"

    shift

    logger \
        -t flash_backup \
        -p "user.${level}" \
        -- "$*"

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

cleanup() {

    if [ -n "$MARKER" ]; then

        rm -f -- "$MARKER" 2>/dev/null || true

    fi

    if [ -n "$HELPER_LOG" ]; then

        rm -f -- "$HELPER_LOG" 2>/dev/null || true

    fi

    if [ -n "$TEMP_FILE" ] && [ -f "$TEMP_FILE" ]; then

        rm -f -- "$TEMP_FILE" 2>/dev/null || true

    fi

}

cleanup_webgui_symlinks() {

    [ -d /usr/local/emhttp ] || return 0

    while IFS= read -r -d '' link; do

        log "Removing WebGUI backup symlink: $link"

        if ! rm -f -- "$link"; then

            syslog warning \
                "Unable to remove WebGUI backup symlink: $link"

        fi

    done < <(

        find /usr/local/emhttp \
            -maxdepth 1 \
            -type l \
            \( \
                -name '*-boot-backup-*.zip' \
                -o -name '*-flash-backup-*.zip' \
            \) \
            -print0 2>/dev/null
    )

}

verify_zip() {

    local file="$1"

    [ -f "$file" ] || return 1
    [ -s "$file" ] || return 1

    #
    # Prefer a full ZIP integrity test.
    #

    if command -v unzip >/dev/null 2>&1; then

        unzip -tq "$file" >/dev/null 2>&1
        return $?

    fi

    #
    # Fallback to ZIP signature verification.
    #

    local sig

    sig=$(head -c 4 "$file" 2>/dev/null || true)

    case "$sig" in
        $'PK\003\004'|$'PK\005\006'|$'PK\007\008')
            return 0
            ;;

    esac

    return 1

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
        
            syslog warning \
                "Unable to delete old boot backup: ${files[$i]}"

        fi
    done
}

###############################################################################
# LOCK
###############################################################################

exec 9>"$LOCKFILE"

if ! flock -n 9; then

    log "Another boot-device backup is already running."

    syslog warning \
        "Backup skipped because another instance is running"

    exit 1

fi

###############################################################################
# CLEANUP TRAP
###############################################################################

trap 'cleanup' EXIT

###############################################################################
# PRE-FLIGHT CHECKS
###############################################################################

log "Starting Unraid boot-device backup"

#
# Ensure the destination pool exists.
#
# This protects against accidentally creating /mnt/vault in RAM if the pool
# disappears or fails to mount.
#

if [ ! -d "$POOL_PATH" ]; then

    log "ERROR: Pool path does not exist: $POOL_PATH"

    syslog err \
        "Boot backup aborted: pool unavailable: $POOL_PATH"

    notify alert \
        "🔴 Backup - POOL UNAVAILABLE" \
        "Destination pool is unavailable."$'\n\n'"Pool: $POOL_PATH"$'\n'"Runtime: $(runtime)"

    exit 2

fi

#
# Verify that POOL_PATH itself is an active mount point.
#

if command -v findmnt >/dev/null 2>&1; then

    mount_target=$(
        findmnt -rn -T "$POOL_PATH" -o TARGET 2>/dev/null || true
    )

    if [ "$mount_target" != "$POOL_PATH" ]; then

        log "ERROR: $POOL_PATH is not an active mount point"
        log "Detected mount target: ${mount_target:-<none>}"

        syslog err \
            "Boot backup aborted because $POOL_PATH is not mounted"

        notify alert \
            "🔴 Backup - POOL NOT MOUNTED" \
            "$POOL_PATH is not mounted."$'\n\n'"Backup aborted to prevent writing into RAM."$'\n'"Runtime: $(runtime)"

        exit 2

    fi

fi

#
# Native Unraid helper must exist.
#

if [ ! -x "$HELPER" ]; then

    log "ERROR: Native Unraid backup helper not found: $HELPER"

    syslog err \
        "Native Unraid boot backup helper missing"

    notify alert \
        "🔴 Backup - HELPER MISSING" \
        "Unable to locate:"$'\n'"$HELPER"$'\n\n'"Runtime: $(runtime)"

    exit 127

fi

###############################################################################
# DESTINATION
###############################################################################

if [ ! -d "$BACKUP_DIR" ]; then

    log "Creating backup directory: $BACKUP_DIR"

    if ! mkdir -p -- "$BACKUP_DIR"; then

        log "ERROR: Unable to create $BACKUP_DIR"

        notify alert \
            "🔴 Backup - DIRECTORY ERROR" \
            "Unable to create:"$'\n'"$BACKUP_DIR"$'\n\n'"Runtime: $(runtime)"

        exit 3

    fi
fi

chmod 0775 "$BACKUP_DIR" 2>/dev/null || true

#
# Verify actual destination write access.
#

WRITE_TEST="$BACKUP_DIR/.flash_backup_write_test.$$"

if ! touch "$WRITE_TEST" 2>/dev/null; then

    log "ERROR: Destination is not writable: $BACKUP_DIR"

    notify alert \
        "🔴 Backup - NOT WRITABLE" \
        "Backup destination is not writable:"$'\n'"$BACKUP_DIR"$'\n\n'"Runtime: $(runtime)"

    exit 3

fi

rm -f -- "$WRITE_TEST"

###############################################################################
# DESTINATION SPACE
###############################################################################

AVAILABLE_BYTES=$(
    df -B1 --output=avail "$BACKUP_DIR" 2>/dev/null |
    tail -n 1 |
    tr -d ' '
)

AVAILABLE_BYTES="${AVAILABLE_BYTES:-0}"

if ! [[ "$AVAILABLE_BYTES" =~ ^[0-9]+$ ]]; then
    AVAILABLE_BYTES=0
fi

log "Destination free space: $(bytes_human "$AVAILABLE_BYTES")"

###############################################################################
# CREATE MARKER
###############################################################################

MARKER=$(mktemp /tmp/flash_backup_marker.XXXXXX) || {
    log "ERROR: Unable to create backup marker"

    exit 4

}

HELPER_LOG=$(mktemp /tmp/flash_backup_helper.XXXXXX) || {
    log "ERROR: Unable to create helper log"

    exit 4

}

###############################################################################
# RUN UNRAID BACKUP HELPER
###############################################################################

log "Running native Unraid backup helper"

if "$HELPER" >"$HELPER_LOG" 2>&1; then

    log "Native backup helper completed successfully"

else

    RC=$?

    log "ERROR: Native backup helper exited with code $RC"

    while IFS= read -r line; do

        log "HELPER: $line"

    done < "$HELPER_LOG"

    syslog err \
        "Native boot backup helper failed with exit code $RC"
    HELPER_EXCERPT=$(
        tail -n 20 "$HELPER_LOG" 2>/dev/null || true
    )

    notify alert \
        "🔴 Backup - FAILED" \
        "Native Unraid backup helper failed."$'\n\n'"Exit code: $RC"$'\n\n'"${HELPER_EXCERPT}"$'\n\n'"Runtime: $(runtime)"

    exit "$RC"

fi

###############################################################################
# LOCATE NEW ARCHIVE
###############################################################################

#
# Unraid 7.3 creates a boot-backup ZIP and may expose a WebGUI symlink.
#
# Do not assume a specific hostname/prefix such as "unraid-".
# Identify only backup ZIPs created after this run started.
#

BACKUP_SOURCE=$(
    find / \
        -maxdepth 1 \
        -type f \
        \( \
            -name '*-boot-backup-*.zip' \
            -o -name '*-flash-backup-*.zip' \
        \) \
        -newer "$MARKER" \
        -printf '%T@|%p\n' 2>/dev/null |
        sort -t'|' -k1,1nr |
        head -n 1 |
        cut -d'|' -f2-
)

if [ -z "$BACKUP_SOURCE" ] || [ ! -f "$BACKUP_SOURCE" ]; then

    log "No new backup archive detected directly in /"
    log "Checking WebGUI backup symlinks"

    #
    # Unraid may expose the generated archive through a symlink in
    # /usr/local/emhttp. Resolve that symlink to the actual file.
    #

    WEBGUI_LINK=$(
        find /usr/local/emhttp \
            -maxdepth 1 \
            -type l \
            \( \
                -name '*-boot-backup-*.zip' \
                -o -name '*-flash-backup-*.zip' \
            \) \
            -printf '%T@|%p\n' 2>/dev/null |
            sort -t'|' -k1,1nr |
            head -n 1 |
            cut -d'|' -f2-
    )

    if [ -n "$WEBGUI_LINK" ]; then

        log "Found WebGUI backup symlink: $WEBGUI_LINK"

        RESOLVED_SOURCE=$(
            readlink -f "$WEBGUI_LINK" 2>/dev/null || true
        )

        if [ -n "$RESOLVED_SOURCE" ] && [ -f "$RESOLVED_SOURCE" ]; then

            BACKUP_SOURCE="$RESOLVED_SOURCE"

            log "Resolved backup source: $BACKUP_SOURCE"

        else

            log "WARNING: WebGUI symlink could not be resolved to a regular file"
            log "Symlink target: $(readlink "$WEBGUI_LINK" 2>/dev/null || echo '<unknown>')"
        fi

    fi

fi

###############################################################################
# FALLBACK SEARCH
###############################################################################

#
# If neither / nor the WebGUI symlink revealed the source, perform a limited
# search of locations Unraid may use for temporary files.
#
# Avoid scanning /mnt so we cannot accidentally select one of our existing
# destination backups.
#

if [ -z "${BACKUP_SOURCE:-}" ] || [ ! -f "${BACKUP_SOURCE:-}" ]; then

    log "Backup source still not located; performing limited fallback search"

    BACKUP_SOURCE=$(
        {
            find /tmp \
                -maxdepth 3 \
                -type f \
                \( \
                    -name '*-boot-backup-*.zip' \
                    -o -name '*-flash-backup-*.zip' \
                \) \
                -newer "$MARKER" \
                -printf '%T@|%p\n' 2>/dev/null

            find /var/tmp \
                -maxdepth 3 \
                -type f \
                \( \
                    -name '*-boot-backup-*.zip' \
                    -o -name '*-flash-backup-*.zip' \
                \) \
                -newer "$MARKER" \
                -printf '%T@|%p\n' 2>/dev/null

            find /boot \
                -maxdepth 2 \
                -type f \
                \( \
                    -name '*-boot-backup-*.zip' \
                    -o -name '*-flash-backup-*.zip' \
                \) \
                -newer "$MARKER" \
                -printf '%T@|%p\n' 2>/dev/null
        } |
        sort -t'|' -k1,1nr |
        head -n 1 |
        cut -d'|' -f2-
    )

fi

###############################################################################
# CONFIRM SOURCE
###############################################################################

if [ -z "${BACKUP_SOURCE:-}" ] || [ ! -f "$BACKUP_SOURCE" ]; then

    log "ERROR: Helper completed successfully but no new boot backup archive could be located"

    #
    # Print helper output into the User Scripts log for diagnosis.
    #

    if [ -s "$HELPER_LOG" ]; then

        log "Native helper output follows:"

        while IFS= read -r line; do
            log "HELPER: $line"
        done < "$HELPER_LOG"

    else
        log "Native helper produced no stdout/stderr output"
    fi

    #
    # Show any matching WebGUI entries, even if they could not be resolved.
    #

    while IFS= read -r entry; do

        [ -n "$entry" ] || continue

        log "WEBGUI BACKUP ENTRY: $entry"

    done < <(
        find /usr/local/emhttp \
            -maxdepth 1 \
            \( \
                -name '*-boot-backup-*.zip' \
                -o -name '*-flash-backup-*.zip' \
            \) \
            -exec ls -la {} \; 2>/dev/null
    )

    syslog err \
        "Backup helper completed but generated archive could not be located"

    notify alert \
        "🔴 Backup - NO ARCHIVE" \
        "The native Unraid helper completed successfully but the generated boot-backup ZIP could not be located."$'\n\n'"Check the User Scripts log for helper and WebGUI details."$'\n\n'"Runtime: $(runtime)"

    exit 5
fi

log "Found source archive: $BACKUP_SOURCE"

###############################################################################
# VERIFY SOURCE ARCHIVE
###############################################################################

SOURCE_SIZE=$(
    stat -c '%s' "$BACKUP_SOURCE" 2>/dev/null || echo 0
)

log "Source size: $(bytes_human "$SOURCE_SIZE")"
log "Verifying source ZIP archive"

if ! verify_zip "$BACKUP_SOURCE"; then

    log "ERROR: Source ZIP verification failed"

    syslog err \
        "Boot backup source archive failed ZIP verification: $BACKUP_SOURCE"

    notify alert \
        "🔴 Backup - CORRUPT ARCHIVE" \
        "Unraid created a backup archive but ZIP integrity verification failed."$'\n\n'"File: $(basename "$BACKUP_SOURCE")"$'\n'"Size: $(bytes_human "$SOURCE_SIZE")"$'\n'"Runtime: $(runtime)"

    exit 6

fi

log "Source ZIP verification passed"

###############################################################################
# CHECK DESTINATION SPACE
###############################################################################

#
# Re-read free space now that we know the actual archive size.
#
# Keep 1 MiB extra safety margin.
#

AVAILABLE_BYTES=$(
    df -B1 --output=avail "$BACKUP_DIR" 2>/dev/null |
    tail -n 1 |
    tr -d ' '
)

AVAILABLE_BYTES="${AVAILABLE_BYTES:-0}"

if ! [[ "$AVAILABLE_BYTES" =~ ^[0-9]+$ ]]; then

    AVAILABLE_BYTES=0

fi

REQUIRED_BYTES=$(( SOURCE_SIZE + 1048576 ))

if (( AVAILABLE_BYTES < REQUIRED_BYTES )); then

    log "ERROR: Insufficient destination space"
    log "Required: $(bytes_human "$REQUIRED_BYTES")"
    log "Available: $(bytes_human "$AVAILABLE_BYTES")"

    syslog err \
        "Insufficient space for boot backup"

    notify alert \
        "🔵 Backup - NO SPACE" \
        "Insufficient destination space."$'\n\n'"Required: $(bytes_human "$REQUIRED_BYTES")"$'\n'"Available: $(bytes_human "$AVAILABLE_BYTES")"$'\n'"Destination: $BACKUP_DIR"$'\n'"Runtime: $(runtime)"

    exit 7

fi

###############################################################################
# COPY TO SSD
###############################################################################

BACKUP_NAME=$(basename "$BACKUP_SOURCE")
BACKUP_FILE="$BACKUP_DIR/$BACKUP_NAME"

#
# Copy to a hidden temporary file first.
#
# If the copy is interrupted, it cannot be mistaken for a valid completed
# backup by the retention logic.
#

TEMP_FILE="$BACKUP_DIR/.${BACKUP_NAME}.tmp.$$"

log "Copying backup to SSD"
log "Destination: $BACKUP_FILE"

if ! cp -- "$BACKUP_SOURCE" "$TEMP_FILE"; then

    log "ERROR: Failed to copy backup to destination"

    syslog err \
        "Unable to copy boot backup to $BACKUP_DIR"

    notify alert \
        "🔴 Backup - COPY FAILED" \
        "Unable to copy boot backup to:"$'\n'"$BACKUP_DIR"$'\n\n'"Runtime: $(runtime)"

    exit 8

fi

###############################################################################
# VERIFY DESTINATION COPY
###############################################################################

DEST_SIZE=$(
    stat -c '%s' "$TEMP_FILE" 2>/dev/null || echo 0
)

if [ "$SOURCE_SIZE" -ne "$DEST_SIZE" ]; then

    log "ERROR: Source and destination sizes differ"
    log "Source: $SOURCE_SIZE bytes"
    log "Destination: $DEST_SIZE bytes"

    syslog err \
        "Boot backup copy size mismatch"

    notify alert \
        "🔴 Backup - SIZE MISMATCH" \
        "Backup copy verification failed."$'\n\n'"Source: $(bytes_human "$SOURCE_SIZE")"$'\n'"Destination: $(bytes_human "$DEST_SIZE")"$'\n'"Runtime: $(runtime)"

    exit 9

fi

log "Destination size matches source"
log "Verifying copied ZIP archive"

if ! verify_zip "$TEMP_FILE"; then

    log "ERROR: Destination ZIP verification failed"

    syslog err \
        "Copied boot backup failed ZIP verification"

    notify alert \
        "🔴 Backup - COPY CORRUPT" \
        "The backup was copied to the SSD but failed ZIP integrity verification."$'\n\n'"Runtime: $(runtime)"

    exit 10

fi

log "Copied ZIP verification passed"

###############################################################################
# FINALIZE DESTINATION
###############################################################################

#
# TEMP_FILE and BACKUP_FILE live on the same filesystem, so rename is atomic.
#

if ! mv -f -- "$TEMP_FILE" "$BACKUP_FILE"; then

    log "ERROR: Unable to finalize destination archive"

    syslog err \
        "Unable to finalize boot backup at destination"

    notify alert \
        "🔴 Backup - FINALIZE FAILED" \
        "Backup was copied but could not be finalized."$'\n\n'"Destination: $BACKUP_FILE"$'\n'"Runtime: $(runtime)"

    exit 11

fi

TEMP_FILE=""

log "Backup finalized successfully"

###############################################################################
# DESTINATION OWNERSHIP
###############################################################################

#
# Only adjust the newly created backup file.
#

chown nobody:users "$BACKUP_FILE" 2>/dev/null || \
    syslog warning "Unable to chown $BACKUP_FILE"

chmod 0644 "$BACKUP_FILE" 2>/dev/null || \
    syslog warning "Unable to chmod $BACKUP_FILE"

###############################################################################
# REMOVE SOURCE ARCHIVE
###############################################################################

#
# Only delete the helper-created source after:
#
#   - source ZIP passed verification
#   - destination copy completed
#   - destination size matched
#   - destination ZIP passed verification
#   - destination was finalized
#

if rm -f -- "$BACKUP_SOURCE"; then

    log "Removed temporary Unraid source archive: $BACKUP_SOURCE"

else

    log "WARNING: Unable to remove source archive: $BACKUP_SOURCE"

    syslog warning \
        "Unable to remove temporary boot backup source: $BACKUP_SOURCE"

fi

###############################################################################
# CLEAN WEBGUI SYMLINK
###############################################################################

cleanup_webgui_symlinks

###############################################################################
# RETENTION
###############################################################################

prune_backups

###############################################################################
# FINAL INFORMATION
###############################################################################

BACKUP_SIZE=$(
    stat -c '%s' "$BACKUP_FILE" 2>/dev/null || echo 0
)

AVAILABLE_BYTES=$(
    df -B1 --output=avail "$BACKUP_DIR" 2>/dev/null |
    tail -n 1 |
    tr -d ' '
)

AVAILABLE_BYTES="${AVAILABLE_BYTES:-0}"

if ! [[ "$AVAILABLE_BYTES" =~ ^[0-9]+$ ]]; then

    AVAILABLE_BYTES=0
    
fi

RUNTIME=$(runtime)

###############################################################################
# SUCCESS
###############################################################################

log "Boot-device backup completed successfully"
log "File: $(basename "$BACKUP_FILE")"
log "Size: $(bytes_human "$BACKUP_SIZE")"
log "Destination: $BACKUP_DIR"
log "Runtime: $RUNTIME"

syslog info \
    "Boot device backup successful: $(basename "$BACKUP_FILE"), size $(bytes_human "$BACKUP_SIZE"), runtime $RUNTIME"

notify normal \
    "🟢 Backup - OK" \
    "Boot-device backup completed successfully."$'\n\n'"File: $(basename "$BACKUP_FILE")"$'\n'"Size: $(bytes_human "$BACKUP_SIZE")"$'\n'"Destination: $BACKUP_DIR"$'\n'"Free space: $(bytes_human "$AVAILABLE_BYTES")"$'\n'"Retention: $MAX_BACKUPS backups"$'\n'"Runtime: $RUNTIME"

exit 0