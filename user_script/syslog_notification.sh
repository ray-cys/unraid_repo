#!/bin/bash

###############################################################################
# Syslog Notification Monitor
#
# PURPOSE
# -------
# Monitor new Unraid syslog entries for configured error keywords and notify
# only when new, non-ignored matching entries are detected.
#
# The script also monitors /var/log filesystem utilization and sends a separate
# alert if log usage becomes critically high.
#
#
# WORKFLOW
# --------
#   1. Acquire single-instance lock
#   2. Validate /var/log/syslog
#   3. Determine new syslog lines since the previous run
#   4. Recover across normal syslog rotation when possible
#   5. Filter configured error keywords
#   6. Remove known benign patterns
#   7. Send one grouped Unraid notification for new matches
#   8. Advance the syslog cursor
#   9. Check /var/log filesystem utilization
#
#
# STATE
# -----
# Runtime state is stored under /tmp and is intentionally non-persistent.
#
# After an Unraid reboot, the first run scans STARTUP_LOOKBACK_LINES from the
# current syslog before establishing a new cursor.
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
# Syslog
# ---------------------------------------------------------------------------

SYSLOG_FILE="/var/log/syslog"

# Keywords are matched case-insensitively using extended regular expressions.
#
# "fail" intentionally also matches:
#
#   fail
#   failed
#   failure
#
ERROR_REGEX="corrupt|error|fail|tainted"


# ---------------------------------------------------------------------------
# Ignore patterns
# ---------------------------------------------------------------------------

# Known benign or unwanted syslog messages.
#
# Each entry is an extended regular expression.
#
LOG_IGNORED_LINES=false
IGNORE_REGEX=(
    # -----------------------------------------------------------------------
    # CIFS / SMB benign messages
    # -----------------------------------------------------------------------

    '^.*kernel:[[:space:]]+CIFS:[[:space:]]+VFS:[[:space:]].*error[[:space:]]+-9[[:space:]]+on[[:space:]]+ioctl[[:space:]]+to[[:space:]]+get[[:space:]]+interface[[:space:]]+list.*$'

    '^.*smbd[^:]*:[[:space:]]+sys_path_to_bdev\(\)[[:space:]]+failed[[:space:]]+for[[:space:]]+path[[:space:]]+\[.*\]!.*$'


    # -----------------------------------------------------------------------
    # SSH benign disconnects
    # -----------------------------------------------------------------------

    '^.*sshd[^:]*:[[:space:]]+Read[[:space:]]+error[[:space:]]+from[[:space:]]+remote[[:space:]]+host[[:space:]].*[[:space:]]+port[[:space:]].*:[[:space:]].*$'


    # -----------------------------------------------------------------------
    # Nginx / Unraid WebGUI benign messages
    # -----------------------------------------------------------------------

    # Missing Ace editor mode-log.js asset.
    '^.*nginx[^:]*:.*ace/mode-log\.js"?[[:space:]]+failed[[:space:]].*[[:space:]]+while[[:space:]]+sending[[:space:]]+to[[:space:]]+client.*$'

    # Temporary unavailable Unix socket/upstream.
    '^.*nginx[^:]*:.*connect\(\)[[:space:]]+to[[:space:]]+unix:[^[:space:]]+[[:space:]]+failed[[:space:]].*[[:space:]]+while[[:space:]]+connecting[[:space:]]+to[[:space:]]+upstream.*$'

    # Browser requests for optional Apple/favicon assets not present in WebGUI.
    '^.*nginx[^:]*:.*open\(\)[[:space:]]+"[^"]*/(apple-touch-icon(-precomposed)?(-[0-9]+x[0-9]+)?\.png|favicon\.ico)"[[:space:]]+failed[[:space:]]+\(2:[[:space:]]+No[[:space:]]+such[[:space:]]+file[[:space:]]+or[[:space:]]+directory\)[[:space:]]+while[[:space:]]+sending[[:space:]]+to[[:space:]]+client.*$'
)


# ---------------------------------------------------------------------------
# Initial scan / rotation recovery
# ---------------------------------------------------------------------------

# Number of recent lines to inspect when no previous state exists.
#
STARTUP_LOOKBACK_LINES=100

# Number of rotated syslog generations to inspect when recovering a cursor
# after log rotation.
#
# Example files:
#
#   /var/log/syslog.1
#   /var/log/syslog.1.gz
#   /var/log/syslog.2.gz
#
ROTATION_SCAN_DEPTH=5


# ---------------------------------------------------------------------------
# Notification
# ---------------------------------------------------------------------------

NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
NOTIFY_SUBJECT="Syslog Monitor"

# Maximum number of matching syslog lines included in one notification.
#
# All matches are still counted, but very large bursts will not create an
# excessively large Unraid notification.
#
MAX_NOTIFY_LINES=20


# ---------------------------------------------------------------------------
# /var/log utilization
# ---------------------------------------------------------------------------

# Send one alert when /var/log reaches this percentage.
#
SYSLOG_USAGE_ALERT_PERCENT=90

# Clear the alert latch only when usage falls to or below this percentage.
#
# The gap between ALERT and RECOVER prevents repeated notifications when usage
# fluctuates around the alert threshold.
#
SYSLOG_USAGE_RECOVER_PERCENT=85

# Number of largest /var/log entries to include in a usage alert.
#
SYSLOG_USAGE_TOP_ENTRIES=10


# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------

STATE_DIR="/tmp/syslog_notify_state"

CURSOR_FILE="${STATE_DIR}/cursor"
USAGE_ALERT_FILE="${STATE_DIR}/usage_alerted"


# ---------------------------------------------------------------------------
# Lock
# ---------------------------------------------------------------------------

LOCK_FILE="/tmp/syslog_notification.lock"


###############################################################################
# RUNTIME STATE
#
# Internal values below this point should not normally be modified.
###############################################################################

CURRENT_FILE_ID=""
CURRENT_LINE_COUNT=0
CURRENT_LAST_LINE_HASH=""

SAVED_FILE_ID=""
SAVED_LINE_COUNT=0
SAVED_LAST_LINE_HASH=""

TEMP_FILES=()


###############################################################################
# LOCKING
###############################################################################

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    printf '%s %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "Another syslog_notification.sh run is active, exiting (lock: $LOCK_FILE)"

    exit 1
fi


###############################################################################
# GENERIC HELPERS
###############################################################################

log() {
    local category="$1"
    local level="$2"
    shift 2

    printf '%s [%s][%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$category" \
        "$level" \
        "$*"
}


ensure_dir() {
    local path="$1"

    if [ -d "$path" ]; then
        return 0
    fi

    mkdir -p -- "$path"
}


notify_unraid() {
    local importance="$1"
    local description="$2"
    local message="$3"

    if [ ! -x "$NOTIFY_BIN" ]; then
        log "NOTIFY" "ERROR" \
            "Unraid notification helper unavailable: $NOTIFY_BIN"

        return 1
    fi

    if ! "$NOTIFY_BIN" \
        -i "$importance" \
        -b \
        -s "$NOTIFY_SUBJECT" \
        -d "$description" \
        -m "$message"
    then
        log "NOTIFY" "ERROR" \
            "Failed to send Unraid notification"

        return 1
    fi

    return 0
}


cleanup_temp_files() {
    local file=""

    for file in "${TEMP_FILES[@]}"; do
        [ -n "$file" ] || continue

        rm -f -- "$file" 2>/dev/null || true
    done
}


###############################################################################
# HASH / FILE HELPERS
###############################################################################

hash_text() {
    sha256sum |
        awk '{print $1}'
}


get_file_id() {
    local file="$1"

    stat \
        -Lc '%d:%i' \
        "$file" \
        2>/dev/null
}


get_plain_line_count() {
    local file="$1"

    wc -l <"$file" 2>/dev/null |
        tr -d '[:space:]'
}


read_log_all() {
    local file="$1"

    if [[ "$file" == *.gz ]]; then
        gzip -cd -- "$file"
    else
        cat -- "$file"
    fi
}


read_log_from_line() {
    local file="$1"
    local start_line="$2"

    if [[ "$file" == *.gz ]]; then
        gzip -cd -- "$file" |
            tail -n +"$start_line"
    else
        tail -n +"$start_line" "$file"
    fi
}


read_log_line() {
    local file="$1"
    local line_number="$2"

    if [[ "$file" == *.gz ]]; then
        gzip -cd -- "$file" |
            sed -n "${line_number}p"
    else
        sed -n "${line_number}p" "$file"
    fi
}


hash_log_line() {
    local file="$1"
    local line_number="$2"
    local line=""

    if [ "$line_number" -le 0 ]; then
        printf '\n'
        return 0
    fi

    line="$(
        read_log_line \
            "$file" \
            "$line_number" \
            2>/dev/null ||
            true
    )"

    if [ -z "$line" ]; then
        printf '\n'
        return 0
    fi

    printf '%s' "$line" |
        hash_text
}


###############################################################################
# CURSOR STATE
###############################################################################

load_cursor() {
    SAVED_FILE_ID=""
    SAVED_LINE_COUNT=0
    SAVED_LAST_LINE_HASH=""

    if [ ! -f "$CURSOR_FILE" ]; then
        return 1
    fi

    IFS='|' read -r \
        SAVED_FILE_ID \
        SAVED_LINE_COUNT \
        SAVED_LAST_LINE_HASH \
        <"$CURSOR_FILE"

    if [ -z "$SAVED_FILE_ID" ] ||
       ! [[ "$SAVED_LINE_COUNT" =~ ^[0-9]+$ ]]
    then
        SAVED_FILE_ID=""
        SAVED_LINE_COUNT=0
        SAVED_LAST_LINE_HASH=""

        return 1
    fi

    return 0
}


capture_current_syslog_state() {
    CURRENT_FILE_ID="$(
        get_file_id "$SYSLOG_FILE"
    )"

    CURRENT_LINE_COUNT="$(
        get_plain_line_count "$SYSLOG_FILE"
    )"

    if ! [[ "$CURRENT_LINE_COUNT" =~ ^[0-9]+$ ]]; then
        CURRENT_LINE_COUNT=0
    fi

    if [ "$CURRENT_LINE_COUNT" -gt 0 ]; then
        CURRENT_LAST_LINE_HASH="$(
            hash_log_line \
                "$SYSLOG_FILE" \
                "$CURRENT_LINE_COUNT"
        )"
    else
        CURRENT_LAST_LINE_HASH=""
    fi

    if [ -z "$CURRENT_FILE_ID" ]; then
        return 1
    fi

    return 0
}


write_cursor() {
    local tmp_file=""

    tmp_file="${CURSOR_FILE}.tmp"

    if ! printf '%s|%s|%s\n' \
        "$CURRENT_FILE_ID" \
        "$CURRENT_LINE_COUNT" \
        "$CURRENT_LAST_LINE_HASH" \
        >"$tmp_file"
    then
        log "STATE" "ERROR" \
            "Unable to write temporary cursor file"

        return 1
    fi

    if ! mv -f -- "$tmp_file" "$CURSOR_FILE"; then
        log "STATE" "ERROR" \
            "Unable to promote cursor file"

        rm -f -- "$tmp_file" 2>/dev/null || true

        return 1
    fi

    return 0
}


###############################################################################
# SYSLOG ROTATION HELPERS
###############################################################################

get_rotated_syslog() {
    local generation="$1"

    local plain="/var/log/syslog.${generation}"
    local compressed="${plain}.gz"

    if [ -f "$plain" ]; then
        printf '%s\n' "$plain"
        return 0
    fi

    if [ -f "$compressed" ]; then
        printf '%s\n' "$compressed"
        return 0
    fi

    return 1
}


find_previous_cursor_log() {
    local generation=0
    local file=""
    local candidate_hash=""

    if [ "$SAVED_LINE_COUNT" -le 0 ] ||
       [ -z "$SAVED_LAST_LINE_HASH" ]
    then
        return 1
    fi

    for ((generation = 1; generation <= ROTATION_SCAN_DEPTH; generation++)); do
        file="$(
            get_rotated_syslog "$generation" ||
            true
        )"

        [ -n "$file" ] || continue

        candidate_hash="$(
            hash_log_line \
                "$file" \
                "$SAVED_LINE_COUNT"
        )"

        if [ -n "$candidate_hash" ] &&
           [ "$candidate_hash" = "$SAVED_LAST_LINE_HASH" ]
        then
            printf '%s|%s\n' \
                "$generation" \
                "$file"

            return 0
        fi
    done

    return 1
}


###############################################################################
# BUILD NEW SYSLOG CHUNK
###############################################################################

build_new_syslog_chunk() {
    local output_file="$1"

    local start_line=1
    local previous=""
    local previous_generation=0
    local previous_file=""
    local generation=0
    local rotated_file=""

    : >"$output_file"

    # -----------------------------------------------------------------------
    # First execution
    # -----------------------------------------------------------------------

    if ! load_cursor; then
        if [ "$CURRENT_LINE_COUNT" -gt "$STARTUP_LOOKBACK_LINES" ]; then
            start_line=$(( CURRENT_LINE_COUNT - STARTUP_LOOKBACK_LINES + 1 ))
        else
            start_line=1
        fi

        log "STATE" "INFO" \
            "No existing cursor; scanning last ${STARTUP_LOOKBACK_LINES} syslog line(s)"

        read_log_from_line \
            "$SYSLOG_FILE" \
            "$start_line" \
            >>"$output_file"

        return 0
    fi


    # -----------------------------------------------------------------------
    # Same active syslog file
    # -----------------------------------------------------------------------

    if [ "$SAVED_FILE_ID" = "$CURRENT_FILE_ID" ]; then
        if [ "$SAVED_LINE_COUNT" -le "$CURRENT_LINE_COUNT" ]; then
            start_line=$((SAVED_LINE_COUNT + 1))

            if [ "$start_line" -le "$CURRENT_LINE_COUNT" ]; then
                read_log_from_line \
                    "$SYSLOG_FILE" \
                    "$start_line" \
                    >>"$output_file"
            fi

            return 0
        fi

        # Same inode but file became shorter: likely truncation.
        log "STATE" "WARN" \
            "Syslog appears to have been truncated; scanning current file from beginning"

        read_log_all \
            "$SYSLOG_FILE" \
            >>"$output_file"

        return 0
    fi


    # -----------------------------------------------------------------------
    # Syslog rotation detected
    # -----------------------------------------------------------------------

    log "STATE" "INFO" \
        "Syslog rotation detected; attempting cursor recovery"

    previous="$(
        find_previous_cursor_log ||
        true
    )"

    if [ -n "$previous" ]; then
        IFS='|' read -r \
            previous_generation \
            previous_file \
            <<<"$previous"

        log "STATE" "INFO" \
            "Recovered previous cursor in ${previous_file}"

        # Finish unread portion of the old active syslog.
        read_log_from_line \
            "$previous_file" \
            "$((SAVED_LINE_COUNT + 1))" \
            >>"$output_file"

        # If more than one rotation occurred, append every newer rotated log
        # in chronological order.
        for ((generation = previous_generation - 1; generation >= 1; generation--)); do
            rotated_file="$(
                get_rotated_syslog "$generation" ||
                true
            )"

            [ -n "$rotated_file" ] || continue

            read_log_all \
                "$rotated_file" \
                >>"$output_file"
        done

        # Finally append the current active syslog.
        read_log_all \
            "$SYSLOG_FILE" \
            >>"$output_file"

        return 0
    fi


    # -----------------------------------------------------------------------
    # Rotation recovery failed
    # -----------------------------------------------------------------------

    log "STATE" "WARN" \
        "Previous cursor could not be located in rotated logs; using startup lookback"

    if [ "$CURRENT_LINE_COUNT" -gt "$STARTUP_LOOKBACK_LINES" ]; then
        start_line=$(( CURRENT_LINE_COUNT - STARTUP_LOOKBACK_LINES + 1 ))
    else
        start_line=1
    fi

    read_log_from_line \
        "$SYSLOG_FILE" \
        "$start_line" \
        >>"$output_file"

    return 0
}


###############################################################################
# ERROR FILTERING
###############################################################################

is_ignored_line() {
    local line="$1"
    local regex=""

    for regex in "${IGNORE_REGEX[@]}"; do
        if printf '%s\n' "$line" |
            grep -Eq "$regex"
        then
            return 0
        fi
    done

    return 1
}


filter_matching_errors() {
    local chunk_file="$1"
    local match_file="$2"

    local line=""

    : >"$match_file"

    while IFS= read -r line; do
        [ -n "$line" ] || continue

        if is_ignored_line "$line"; then
            if [ "$LOG_IGNORED_LINES" = "true" ]; then
                log "SYSLOG" "INFO" \
                    "Ignored matching line: $line"
            fi

            continue
        fi

        printf '%s\n' "$line" \
            >>"$match_file"

    done < <(
        grep \
            -Ei \
            "(${ERROR_REGEX})" \
            "$chunk_file" \
            2>/dev/null ||
            true
    )
}


###############################################################################
# SYSLOG ERROR CHECK
###############################################################################

check_syslog_errors() {
    local chunk_file=""
    local match_file=""

    local match_count=0
    local omitted_count=0

    local keyword_summary=""
    local body=""

    chunk_file="$(
        mktemp /tmp/syslog_notification_chunk.XXXXXX
    )"

    match_file="$(
        mktemp /tmp/syslog_notification_matches.XXXXXX
    )"

    TEMP_FILES+=(
        "$chunk_file"
        "$match_file"
    )

    if ! build_new_syslog_chunk "$chunk_file"; then
        log "SYSLOG" "ERROR" \
            "Unable to build new syslog chunk"

        return 1
    fi

    filter_matching_errors \
        "$chunk_file" \
        "$match_file"

    match_count="$(
        wc -l <"$match_file" |
            tr -d '[:space:]'
    )"

    if ! [[ "$match_count" =~ ^[0-9]+$ ]]; then
        match_count=0
    fi

    # No relevant new errors.
    if [ "$match_count" -eq 0 ]; then
        log "SYSLOG" "INFO" \
            "No new matching syslog errors"

        if ! write_cursor; then
            return 1
        fi

        return 0
    fi

    keyword_summary="$(
        grep \
            -Eio \
            "(${ERROR_REGEX})" \
            "$match_file" \
            2>/dev/null |
            tr '[:upper:]' '[:lower:]' |
            sort -u |
            xargs ||
            true
    )"

    log "SYSLOG" "WARN" \
        "Detected ${match_count} new matching syslog line(s): ${keyword_summary}"

    while IFS= read -r line; do
        [ -n "$line" ] || continue

        log "SYSLOG" "WARN" "$line"

    done <"$match_file"

    body+="Keywords: ${keyword_summary}"$'\n'
    body+="New matches: ${match_count}"$'\n'
    body+=$'\n'

    body+="$(
        head \
            -n "$MAX_NOTIFY_LINES" \
            "$match_file"
    )"

    if [ "$match_count" -gt "$MAX_NOTIFY_LINES" ]; then
        omitted_count=$(( match_count - MAX_NOTIFY_LINES ))

        body+=$'\n'
        body+=$'\n'
        body+="... ${omitted_count} additional matching line(s) omitted"
    fi

    if ! notify_unraid \
        "alert" \
        "${match_count} new syslog alert(s): ${keyword_summary}" \
        "$body"
    then
        # Do NOT advance the cursor if notification delivery failed.
        #
        # This allows the same lines to be retried on the next run.
        return 1
    fi

    # Advance to the exact point captured before scanning.
    #
    # Lines written after CURRENT_LINE_COUNT will therefore still be processed
    # on the next run instead of being accidentally skipped.
    if ! write_cursor; then
        return 1
    fi

    return 0
}


###############################################################################
# /VAR/LOG UTILIZATION
###############################################################################

get_log_usage_percent() {
    local usage=""

    usage="$(
        df \
            -P \
            /var/log \
            2>/dev/null |
            awk '
                NR == 2 {
                    gsub(/%/, "", $5)
                    print $5
                }
            '
    )"

    if [[ "$usage" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$usage"
        return 0
    fi

    return 1
}


build_log_usage_detail() {
    du \
        -ah \
        /var/log \
        2>/dev/null |
        sort -h |
        tail -n "$SYSLOG_USAGE_TOP_ENTRIES"
}


check_log_usage() {
    local usage=0
    local body=""

    if ! usage="$(
        get_log_usage_percent
    )"
    then
        log "SPACE" "ERROR" \
            "Unable to determine /var/log utilization"

        return 1
    fi

    log "SPACE" "INFO" \
        "/var/log utilization: ${usage}%"

    # -----------------------------------------------------------------------
    # Alert threshold reached
    # -----------------------------------------------------------------------

    if [ "$usage" -ge "$SYSLOG_USAGE_ALERT_PERCENT" ]; then
        if [ -f "$USAGE_ALERT_FILE" ]; then
            log "SPACE" "INFO" \
                "/var/log remains above alert threshold; notification already sent"

            return 0
        fi

        body+="Current /var/log usage: ${usage}%"$'\n'
        body+="Alert threshold: ${SYSLOG_USAGE_ALERT_PERCENT}%"$'\n'
        body+="Recovery threshold: ${SYSLOG_USAGE_RECOVER_PERCENT}%"$'\n'
        body+=$'\n'
        body+="Largest log entries:"$'\n'
        body+="$(build_log_usage_detail)"

        if ! notify_unraid \
            "alert" \
            "/var/log utilization ${usage}%" \
            "$body"
        then
            return 1
        fi

        if ! touch "$USAGE_ALERT_FILE"; then
            log "STATE" "ERROR" \
                "Unable to create /var/log utilization alert latch"

            return 1
        fi

        log "SPACE" "WARN" \
            "/var/log utilization alert sent at ${usage}%"

        return 0
    fi


    # -----------------------------------------------------------------------
    # Recovery
    # -----------------------------------------------------------------------

    if [ -f "$USAGE_ALERT_FILE" ] &&
       [ "$usage" -le "$SYSLOG_USAGE_RECOVER_PERCENT" ]
    then
        rm -f -- "$USAGE_ALERT_FILE"

        log "SPACE" "INFO" \
            "/var/log usage recovered to ${usage}%; alert latch cleared"
    fi

    return 0
}


###############################################################################
# MAIN
###############################################################################

main() {
    local final_exit=0

    # -----------------------------------------------------------------------
    # State initialization
    # -----------------------------------------------------------------------

    if ! ensure_dir "$STATE_DIR"; then
        printf '%s ERROR: Unable to create state directory: %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$STATE_DIR"

        return 1
    fi

    trap cleanup_temp_files EXIT


    # -----------------------------------------------------------------------
    # Syslog validation
    # -----------------------------------------------------------------------

    if [ ! -f "$SYSLOG_FILE" ]; then
        log "PREFLIGHT" "ERROR" \
            "Syslog file does not exist: $SYSLOG_FILE"

        return 1
    fi

    if [ ! -r "$SYSLOG_FILE" ]; then
        log "PREFLIGHT" "ERROR" \
            "Syslog file is not readable: $SYSLOG_FILE"

        return 1
    fi

    if ! capture_current_syslog_state; then
        log "PREFLIGHT" "ERROR" \
            "Unable to capture syslog file state"

        return 1
    fi


    # -----------------------------------------------------------------------
    # New syslog errors
    # -----------------------------------------------------------------------

    if ! check_syslog_errors; then
        final_exit=1
    fi


    # -----------------------------------------------------------------------
    # /var/log utilization
    #
    # This deliberately runs even if a syslog error notification was sent.
    # -----------------------------------------------------------------------

    if ! check_log_usage; then
        final_exit=1
    fi


    # -----------------------------------------------------------------------
    # Exit status
    # -----------------------------------------------------------------------

    return "$final_exit"
}


###############################################################################
# ENTRY POINT
###############################################################################

main "$@"