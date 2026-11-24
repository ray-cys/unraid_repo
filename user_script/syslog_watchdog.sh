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
readonly SCRIPT_VERSION="1.3"


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
ERROR_REGEX="corrupt|error|fail|tainted|out of memory|oom-kill|invoked oom-killer|killed process|blocked for more than|soft lockup|hard lockup|NETDEV WATCHDOG|transmit queue.*timed out|reset adapter|resetting (chip|adapter)"
STORAGE_MATCH_REGEX='XFS.*(shutdown|shut down|shutting down)'
# Use the deployed User Scripts directory, not the generated execution copy.
XFS_INCIDENT_FILE="/boot/config/plugins/user.scripts/scripts/syslog_watchdog/xfs_faults.tsv"
# Event deduplication; repeats after this interval are reminders, not new faults.
# Silence is not proof of recovery from an OOM or hardware fault.
INCIDENT_REMINDER_SECONDS=86400
INCIDENT_RETENTION_SECONDS=604800
INCIDENT_MAX_ENTRIES=2000


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

    # Browser requests for optional Nginx asset not present in WebGUI.
    '^.*nginx[^:]*:.*open\(\)[[:space:]]+"[^"]*/plugins/prometheus_node_exporter/images/prometheus_node_exporter\.png"[[:space:]]+failed[[:space:]]+\(2:[[:space:]]+No[[:space:]]+such[[:space:]]+file[[:space:]]+or[[:space:]]+directory\)[[:space:]]+while[[:space:]]+sending[[:space:]]+to[[:space:]]+client.*$'
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

STATE_DIR="/tmp/syslog_watchdog_state"

CURSOR_FILE="${STATE_DIR}/cursor"
USAGE_ALERT_FILE="${STATE_DIR}/usage_alerted"


# ---------------------------------------------------------------------------
# Lock
# ---------------------------------------------------------------------------

LOCK_FILE="/tmp/syslog_watchdog.lock"


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
        if [ "$SAVED_LINE_COUNT" -le "$CURRENT_LINE_COUNT" ] &&
           { (( SAVED_LINE_COUNT == 0 )) ||
             [[ -n "$SAVED_LAST_LINE_HASH" &&
                "$(hash_log_line "$SYSLOG_FILE" "$SAVED_LINE_COUNT")" == "$SAVED_LAST_LINE_HASH" ]]; }; then
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
        printf '%s\n' 'Syslog coverage error: active log was rewritten; unread older lines may be lost.' >>"$output_file"

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

            if [ -z "$rotated_file" ]; then
                printf '%s\n' "Syslog coverage error: missing rotated generation $generation." >>"$output_file"
                continue
            fi

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
    printf '%s\n' "Syslog coverage error: previous cursor log is unavailable; using bounded lookback." >>"$output_file"

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


xfs_fault_source() {
    local prefix='^[^ ]+ +([0-9]+ [0-9:]+ +)?[^ ]+ +kernel: +XFS +\(([[:alnum:]_.-]+)\):'
    [[ "$1" =~ $prefix ]] || return 1
    local source="${BASH_REMATCH[2]}"
    case "${1,,}" in
        *corrupt*|*shutdown*|*"shut down"*|*"shutting down"*) printf '%s\n' "$source" ;;
        *) return 1 ;;
    esac
}

xfs_incident_state() {
    local operation="$1" source="${2:-}" now="${3:-}" temp
    local parent="${XFS_INCIDENT_FILE%/*}"
    [[ -d "$parent" && ! -L "$parent" && -O "$parent" ]] || return 1
    # Unraid boot storage is usually FAT and cannot enforce POSIX write bits.
    # Do not read or replace symlinks (including the ledger itself).
    [[ ! -L "$XFS_INCIDENT_FILE" ]] || return 1
    if [[ -e "$XFS_INCIDENT_FILE" ]]; then
        [[ -f "$XFS_INCIDENT_FILE" && -O "$XFS_INCIDENT_FILE" ]] || return 1
    fi
    if [[ "$operation" == list ]]; then
        if [[ -f "$XFS_INCIDENT_FILE" ]]; then cat -- "$XFS_INCIDENT_FILE"; fi
        return
    fi
    [[ "$source" =~ ^[[:alnum:]_.-]+$ ]] || return 2
    case "$operation" in
        open)
            if [[ -f "$XFS_INCIDENT_FILE" ]] &&
               awk -F '\t' -v source="$source" '$1==source { found=1 } END { exit !found }' "$XFS_INCIDENT_FILE"; then
                return 0
            fi ;;
        ack) [[ -f "$XFS_INCIDENT_FILE" ]] || return 0 ;;
        *) return 2 ;;
    esac
    temp=$(mktemp "$parent/.xfs_faults.XXXXXX") || return 1
    TEMP_FILES+=("$temp")
    if [[ -f "$XFS_INCIDENT_FILE" ]]; then
        awk -F '\t' -v source="$source" '$1!=source' "$XFS_INCIDENT_FILE" >"$temp" || return 1
    fi
    if [[ "$operation" == open ]]; then
        printf '%s\t%s\n' "$source" "$now" >>"$temp" || return 1
    fi
    mv -f -- "$temp" "$XFS_INCIDENT_FILE"
}

filter_matching_errors() {
    local chunk_file="$1"
    local match_file="$2"

    local line="" scrubbed key now previous xfs_source xfs_opened
    now=$(date +%s)
    INCIDENT_NEXT="${STATE_DIR}/incidents.pending"
    local history="${STATE_DIR}/incidents.tsv"
    : >"$INCIDENT_NEXT"
    if [ -f "$history" ]; then
        awk -F '\t' -v cutoff="$((now-INCIDENT_RETENTION_SECONDS))" '$2>=cutoff' "$history" | tail -n "$INCIDENT_MAX_ENTRIES" >"$INCIDENT_NEXT"
    fi
    : >"$match_file"

    while IFS= read -r line; do
        [ -n "$line" ] || continue

        # Remove only explicit zero-valued counters, then re-evaluate. An OOM
        # on a line also containing failures=0 must still alert.
        scrubbed=$(printf '%s\n' "$line" | sed -E 's/(errors?|failures?|failed)[=:][[:space:]]*0([^0-9]|$)/ /gI')
        xfs_source=$(xfs_fault_source "$line") || xfs_source=""
        if [[ -n "$xfs_source" ]]; then
            xfs_incident_state open "$xfs_source" "$now" || return 1
            # Group corruption/shutdown lines for the same XFS source.
            xfs_opened=$(awk -F '\t' -v source="$xfs_source" '$1==source {print $2; exit}' "$XFS_INCIDENT_FILE") || return 1
            [[ "$xfs_opened" =~ ^[1-9][0-9]{0,11}$ ]] || return 1
            key="xfs:$xfs_source:$xfs_opened"
        else
            printf '%s\n' "$scrubbed" | grep -Eiq "$ERROR_REGEX" || continue
            # Daily health owns link-instability trends, but not actual I/O failures.
            if [[ "$line" =~ kernel:[[:space:]]+ata[0-9]+ ]] &&
               [[ "${line,,}" =~ hard\ resetting\ link|link\ is\ slow\ to\ respond|exception\ emask ]] &&
               [[ ! "${line,,}" =~ i/o\ error|read\ error|write\ error|failed\ command ]]; then
                continue
            fi
            key=""
        fi
        if [[ -z "$xfs_source" ]] && is_ignored_line "$line"; then
            if [ "$LOG_IGNORED_LINES" = "true" ]; then
                log "SYSLOG" "INFO" \
                    "Ignored matching line: $line"
            fi

            continue
        fi

        [[ -n "$key" ]] || key=$(printf '%s\n' "$line" | sed -E \
          's/^[A-Z][a-z]{2} +[0-9]+ [0-9:]+ [^ ]+ //; s/^[0-9]{4}-[0-9T:.+-]+ [^ ]+ //; s/\[[0-9]+\]/[PID]/g; s/Killed process [0-9]+/Killed process PID/g; s/task [^ ]+:[0-9]+/task PROCESS:PID/g' | sha256sum | awk '{print $1}')
        previous=$(awk -F '\t' -v key="$key" '$1==key {v=$2} END {print v+0}' "$INCIDENT_NEXT")
        if (( previous>0 && now-previous<INCIDENT_REMINDER_SECONDS )); then continue; fi
        printf '%s\t%s\n' "$key" "$now" >>"$INCIDENT_NEXT"
        printf '%s\n' "$line" >>"$match_file"

    done < <(
        grep \
            -Ei \
            "(${ERROR_REGEX}|${STORAGE_MATCH_REGEX})" \
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
    local body="" importance=warning critical=0

    chunk_file="$(
        mktemp /tmp/syslog_watchdog_chunk.XXXXXX
    )"

    match_file="$(
        mktemp /tmp/syslog_watchdog_matches.XXXXXX
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
        "$match_file" || return 1

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
            "(${ERROR_REGEX}|${STORAGE_MATCH_REGEX})" \
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

    critical=$(grep -Eic "out of memory|oom-kill|killed process|blocked for more than|soft lockup|hard lockup|corrupt|${STORAGE_MATCH_REGEX}" "$match_file" || true)
    (( critical==0 )) || importance=alert
    body+="Host events: ${match_count}; critical matches: ${critical}"$'\n'
    body+="Action: new syslog events detected and grouped; no process, container or network settings were changed."$'\n'
    body+="Repeated identical events are limited to one reminder per 24 hours. Absence of new log entries does not establish recovery."$'\n'
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
        "$importance" \
        "${match_count} new/reminder syslog event(s): ${keyword_summary}" \
        "$body"
    then
        # Do NOT advance the cursor if notification delivery failed.
        #
        # This allows the same lines to be retried on the next run.
        return 1
    fi

    # Commit event delivery only after notification succeeds. A failed send
    # keeps the old cursor and old incident ledger for a safe retry.
    local bounded="${STATE_DIR}/incidents.bounded"
    if ! awk -F '\t' '{seen[$1]=$2} END {for (key in seen) print key "\t" seen[key]}' "$INCIDENT_NEXT" | \
      sort -k2,2n | tail -n "$INCIDENT_MAX_ENTRIES" >"$bounded"; then return 1; fi
    if ! mv -f -- "$bounded" "${STATE_DIR}/incidents.tsv"; then return 1; fi
    rm -f -- "$INCIDENT_NEXT"
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
        if ! notify_unraid normal "/var/log utilization recovered (${usage}%)" \
          "Current /var/log usage: ${usage}%. Recovery threshold: ${SYSLOG_USAGE_RECOVER_PERCENT}%. The utilization incident is cleared; no files were deleted by this monitor."; then return 1; fi
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
    case "${1:-}" in
      --version) printf 'syslog_watchdog.sh %s\n' "$SCRIPT_VERSION"; return 0 ;;
      ''|--open-xfs|--ack-xfs) ;;
      *) return 2 ;;
    esac
    exec 9>"$LOCK_FILE" || return 1
    flock -n 9 || { printf 'Another syslog monitor is running; scan deferred.\n'; return 0; }

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
    case "${1:-}" in
        --open-xfs) xfs_incident_state list; return ;;
        --ack-xfs) [[ $# == 2 ]] || return 2; xfs_incident_state ack "$2"; return ;;
    esac


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

    if check_syslog_errors; then
        local heartbeat
        heartbeat=$(mktemp "$STATE_DIR/.storage-watch.XXXXXX") || return 1
        TEMP_FILES+=("$heartbeat")
        if ! date +%s >"$heartbeat" || ! mv -f -- "$heartbeat" "$STATE_DIR/storage-watch.epoch"; then
            final_exit=1
        fi
    else
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
