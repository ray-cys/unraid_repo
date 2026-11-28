#!/bin/bash
# Release version: bump for every deployed code change; descriptions stay user-owned.
readonly SCRIPT_VERSION="1.10.3"
# Version lookup exits before logging, locks, state, Docker or network activity.
if [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" == --version ]]; then
    printf 'host_health_watchdog.sh %s\n' "$SCRIPT_VERSION"
    exit 0
fi
# BEGIN CURRENT OPERATIONAL PURPOSE
# PURPOSE: Monitor fast-changing host conditions and syslog without repeating daily SMART
#   maintenance or waking disks solely for temperature checks.
# WORKFLOW: Process bounded resumable syslog input and probe mounts, memory, capacity/inodes,
#   native temperatures, LAN and monitoring freshness; persist confirmed findings and shared
#   host status.
# COORDINATION: Shares lifecycle evidence with host_health_monitor, checks external Raspberry Pi
#   observer freshness and consumes central execution/checkpoint evidence.
# LIMITS: Distinguish unavailable collectors from confirmed faults. Critical conditions notify
#   promptly; ordinary warnings and recovery require the configured observations. No automatic
#   remount, filesystem repair or forced reboot.
# REPORTING: Group actionable host findings and restoration with shared deduplication; expose
#   all probe results in console/status output.
# Commands and side effects: docs/user-scripts-cli.md in ray-cys/unraid_repo.
# END CURRENT OPERATIONAL PURPOSE
# Purpose: Frequent syslog, CPU/disk temperature, memory, mount, capacity,
# LAN and monitoring-freshness checks with grouped actionable notifications.
# Native Unraid temperature readings do not poll SMART or wake sleeping disks.
# Missing evidence cannot clear an incident; recovery needs healthy confirmation.
# The daily monitor owns SMART, endurance, disk tests and scrub verification.
# Host lifecycle state is RAM-first and mirrored to the vault; syslog incident
# history and review markers retain their existing durable storage and policies.
# Bounded chronological syslog processing resumes from its cursor. A separate
# critical-tail check protects urgent events when an ordinary backlog remains.
# --health-status reads the coordinated receipt. --help lists supported read-only
# status and incident-review commands. Scheduling remains in Unraid User Scripts.

# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="host_health_watchdog"
# shellcheck shell=bash
# Shared operational logs, notifications and execution receipts.
usr_ops_log_line() {
    local level="${1^^}" phase="$2" message="$3" line LC_ALL=C
    case "$level" in WARN) level=WARNING;; ERR|FATAL) level=ERROR;; NOTICE) level=INFO;; esac
    message=${message//$'\r'/};message=${message//$'\n'/ | }
    printf -v line '%s | %s | %s | run=%s | phase=%s | %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$OPS_SCRIPT_ID" "${OPS_RUN_ID:-$$}" "$phase" "$message"
    if ((${#line}>4096));then line="${line:0:4050} ... [truncated]";fi
    printf '%s\n' "$line"
}

usr_ops_notify() {
    local -a args=("$@")
    local i importance=normal summary='' message='' index=-1 status=UPDATE
    for ((i=0;i<${#args[@]};i++));do
        case "${args[$i]}" in
          -i) importance="${args[$((i+1))]:-normal}";;
          -d) summary="${args[$((i+1))]:-}";;
          -m) index=$((i+1));message="${args[$index]:-}";;
        esac
    done
    case "$importance" in alert|warning) status=ATTENTION;;esac
    if [[ "$message" != 'Status: '* ]];then
        message="Status: $status"$'\n'"Summary: $summary"$'\n\n'"Actions and findings:"$'\n'"${message:-$summary}"
        if ((index>=0));then args[$index]="$message";else args+=(-m "$message");fi
    fi
    # Every notifier has a termination escalation, including legacy callers.
    if [[ "${args[0]##*/}" == timeout ]];then
        if [[ " ${args[*]} " != *' --kill-after'* ]];then args=("${args[0]}" --kill-after=5 "${args[@]:1}");fi
    else args=(timeout --signal=TERM --kill-after=5 30 "${args[@]}");fi
    local delivery_rc=0
    "${args[@]}" || delivery_rc=$?
    return "$delivery_rc"
}

usr_ops_execution_record() (
    local phase="$1" started="$2" pid="$3" rc="${4:-0}" process_start root="${USR_OPS_EXECUTION_ROOT:-/run/user-script-execution}" file tmp now boot old='{}' status
    [[ "${OPS_SCRIPT_ID:-}" =~ ^[a-z0-9_]+$ && ! -L "$root" ]] || return 1
    mkdir -p "$root" || return 1;file="$root/$OPS_SCRIPT_ID.json"
    [[ ! -L "$file" ]] || return 1
    if [[ -f "$file" ]];then old=$(jq -c 'select(.schema==1)' "$file") || old='{}';fi
    [[ -n "$old" ]] || old='{}'
    now=$(date +%s);boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)
    process_start=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')
    [[ "$phase" != finish ]] || process_start=$(jq -r '.processStart // ""' <<<"$old")
    status=RUNNING;[[ "$phase" != finish ]] || { status=COMPLETED;((rc==0)) || status=FAILED; }
    tmp=$(mktemp "$root/.execution.XXXXXX") || return 1;trap 'rm -f -- "$tmp"' EXIT
    jq -n --argjson old "$old" --arg processStart "$process_start" --arg name "$OPS_SCRIPT_ID" --arg boot "$boot" --arg status "$status" --argjson started "$started" --argjson at "$now" --argjson pid "$pid" --argjson rc "$rc" \
      '$old+{schema:1,name:$name,boot:$boot,executionStatus:$status,startedAt:$started,observedAt:$at,pid:$pid,processStart:$processStart,lastExitCode:$rc} |
       if $status!="RUNNING" then .finishedAt=$at|.durationSeconds=($at-$started)|.lastCompletedAt=$at|if $rc==0 then .lastSuccessAt=$at else . end
       else .previousRun={startedAt:$old.startedAt,finishedAt:$old.finishedAt,status:$old.executionStatus,exitCode:$old.lastExitCode,durationSeconds:$old.durationSeconds}|.finishedAt=null|.durationSeconds=null|.lastExitCode=null end' >"$tmp" && chmod 600 "$tmp" && mv "$tmp" "$file" || return 1
    local persistent="${USR_OPS_EXECUTION_PERSISTENT_ROOT:-/mnt/vault/cloud/logs/script/user_scripts_status/execution}" fd export_fd
    mountpoint -q "${USR_OPS_VAULT_MOUNT:-/mnt/vault}" || return 0
    [[ ! -L "$persistent" && $(realpath -m "$persistent") == "$persistent" ]] || return 1
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}";flock -s -n "$export_fd" || return 0
    mkdir -p "$persistent" || return 1
    tmp=$(mktemp "$persistent/.execution.XXXXXX") || return 1
    cp "$file" "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$persistent/$OPS_SCRIPT_ID.json"
)

usr_ops_supervise() {
    local script="$1" started pid='' interrupted='' rc=0 receipt_fd record_owner=false
    # Repository/fixture executions must never publish production evidence.
    # Explicit test roots opt into supervision for isolated regression checks.
    case "$script" in
      /boot/config/plugins/user.scripts/scripts/*/script|/tmp/user.scripts/tmpScripts/*/script) ;;
      *) if [[ -z "${USR_OPS_EXECUTION_ROOT:-}" ]];then USR_OPS_SUPERVISED="$OPS_SCRIPT_ID" /bin/bash "$script";return $?;fi;;
    esac
    local execution_root="${USR_OPS_EXECUTION_ROOT:-/run/user-script-execution}"
    if [[ ! -L "$execution_root" ]] && mkdir -p "$execution_root";then
        exec {receipt_fd}>"$execution_root/$OPS_SCRIPT_ID.lock"
        flock -n "$receipt_fd" && record_owner=true
    fi
    # Register forwarding before launch or receipt I/O. Background Bash may
    # inherit ignored SIGINT, so interactive cancellation uses its TERM cleanup.
    trap 'interrupted=TERM;[[ -z "$pid" ]] || kill -TERM "$pid" 2>/dev/null || true' TERM HUP
    trap 'interrupted=INT;[[ -z "$pid" ]] || kill -TERM "$pid" 2>/dev/null || true' INT
    started=$(date +%s)
    USR_OPS_SUPERVISED="$OPS_SCRIPT_ID" OPS_RUN_ID="${OPS_RUN_ID:-${started}_$$}" /bin/bash "$script" &
    pid=$!
    [[ -z "$interrupted" ]] || kill -TERM "$pid" 2>/dev/null || true
    [[ "$record_owner" != true ]] || usr_ops_execution_record start "$started" "$pid" || printf 'Execution receipt unavailable for %s; workflow continues.\n' "$OPS_SCRIPT_ID" >&2
    wait "$pid" || rc=$?
    # A signal can interrupt wait while the producer is still restoring state.
    if kill -0 "$pid" 2>/dev/null;then wait "$pid" || rc=$?;fi
    if [[ "$interrupted" == INT ]];then rc=130;elif [[ "$interrupted" == TERM ]];then rc=143;fi
    [[ "$record_owner" != true ]] || usr_ops_execution_record finish "$started" "$pid" "$rc" || printf 'Completion receipt unavailable for %s (exit=%s).\n' "$OPS_SCRIPT_ID" "$rc" >&2
    trap - TERM HUP INT
    return "$rc"
}
# END EMBEDDED OPERATIONS CONTRACT
# BEGIN SCHEDULED EXECUTION SUPERVISOR
if [[ "${BASH_SOURCE[0]}" == "$0" && $# == 0 && "${USR_OPS_SUPERVISED:-}" != "$OPS_SCRIPT_ID" ]];then
    usr_ops_supervise "$0";exit $?
fi
# END SCHEDULED EXECUTION SUPERVISOR
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
ERROR_REGEX="corrupt|error|fail|tainted|out of memory|oom-kill|invoked oom-killer|killed process|blocked for more than|soft lockup|hard lockup|NETDEV WATCHDOG|transmit queue.*timed out|reset adapter|resetting (chip|adapter)"
STORAGE_MATCH_REGEX='XFS.*(shutdown|shut down|shutting down)'
# Use the deployed User Scripts directory, not the generated execution copy.
XFS_INCIDENT_FILE="/boot/config/plugins/user.scripts/scripts/host_health_watchdog/xfs_faults.tsv"
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
NOTIFY_SUBJECT="Host Health Watchdog"

# Maximum number of matching syslog lines included in one notification.
#
# All matches are still counted, but very large bursts will not create an
# excessively large Unraid notification.
#
MAX_NOTIFY_LINES=20
SYSLOG_BATCH_MAX_LINES=500
SYSLOG_BATCH_MAX_BYTES=1048576
SYSLOG_FILTER_BUDGET_SECONDS=30
CRITICAL_REGEX='out of memory|oom-kill|killed process|kernel panic|BUG:|soft lockup|hard lockup|blocked for more than|corrupt|I/O error|input/output error|read-only file system|XFS.*(shutdown|error)|BTRFS.*(error|critical)|EXT4-fs error|nvme.*(timeout|reset controller)|Syslog coverage error'
# Observed incidents are dynamic; detection/ignore rules are never auto-edited.
# JSON is bounded to 2,000 incidents / 90 days; repeats use observations, not
# an invented count of distinct kernel events. A quiet log does not prove repair.


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

STATE_DIR="/tmp/host_health_watchdog_state"

CURSOR_FILE="${STATE_DIR}/cursor"
USAGE_ALERT_FILE="${STATE_DIR}/usage_alerted"


# ---------------------------------------------------------------------------
# Lock
# ---------------------------------------------------------------------------

LOCK_FILE="/tmp/host_health_watchdog.lock"


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

    usr_ops_log_line "$level" "$category" "$*"
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

    local host_attached=0 peer_context
    peer_context=$(hc_peer_context watchdog "$(date +%s)") || peer_context="Daily disk context unavailable; no healthy state assumed."
    message+=$'\n\n'"$peer_context"
    if [[ "${HH_PREPARED:-0}" == 1 && -n "${HH_PENDING_BODY:-}" ]];then
        message+=$'\n\nHost conditions:\n'"$HH_PENDING_BODY"
        host_attached=1
        case "$HH_PENDING_IMPORTANCE" in alert) importance=alert;; warning) [[ "$importance" == alert ]] || importance=warning;;esac
    fi
    if [ ! -x "$NOTIFY_BIN" ]; then
        log "NOTIFY" "ERROR" \
            "Unraid notification helper unavailable: $NOTIFY_BIN"

        return 1
    fi

    if ! usr_ops_notify "$NOTIFY_BIN" \
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

    if ((host_attached));then hh_delivered || return 1;fi
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

    local plain="${SYSLOG_FILE}.${generation}"
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

# Read bounded chronological slices. The cursor always names the last consumed
# source/line, including rotated files; unread bytes are never acknowledged.
syslog_append_segment() {
    local source="$1" start="$2" output="$3" remain_lines remain_bytes meta="$STATE_DIR/slice.meta" slice="$STATE_DIR/slice.data" rc=0 count full source_id
    source_id=$(get_file_id "$source") || return 1
    remain_lines=$((SYSLOG_BATCH_MAX_LINES-$(wc -l <"$output")))
    remain_bytes=$((SYSLOG_BATCH_MAX_BYTES-$(stat -c %s "$output")))
    ((remain_lines>0 && remain_bytes>0)) || { SYSLOG_BACKLOG=true;return 10; }
    # A partial final line is not acknowledged; the captured newline boundary
    # also prevents concurrent writers advancing this batch beyond its snapshot.
    if [[ "$source" == "$SYSLOG_FILE" && ${SYSLOG_CAPTURED_ACTIVE_LINES:-} =~ ^[0-9]+$ ]];then
        local captured_remaining=$((SYSLOG_CAPTURED_ACTIVE_LINES-start+1))
        ((captured_remaining>0)) || return 0
        ((remain_lines<=captured_remaining)) || remain_lines=$captured_remaining
    fi
    read_log_from_line "$source" "$start" | awk -v lines="$remain_lines" -v bytes="$remain_bytes" -v meta="$meta" '
      NR>lines || used+length($0)+1>bytes {full=1;exit} {print;used+=length($0)+1;n++}
      END{print n+0,full+0 >meta}' >"$slice"
    local -a codes=("${PIPESTATUS[@]}")
    ((codes[1]==0 && (codes[0]==0 || codes[0]==141))) || return 1
    [[ $(get_file_id "$source") == "$source_id" ]] || { log SYSLOG WARNING "Syslog rotated during bounded read; cursor retained for retry";return 1; }
    IFS=' ' read -r count full <"$meta"
    if ((count==0 && full==1));then
        notify_unraid alert 'Syslog processing requires attention' "A syslog record exceeds the $SYSLOG_BATCH_MAX_BYTES-byte batch limit. Cursor retained; inspect $source at line $start. No log was deleted or acknowledged." || true
        return 1
    fi
    if ((count>0));then
        printf '%s\t%s\t%s\t%s\t%s\n' "$(( $(wc -l <"$output")+1 ))" "$count" "$start" "$source" "$source_id" >>"$STATE_DIR/slice-map.tsv" || return 1
        cat "$slice" >>"$output" || return 1
        CURRENT_FILE_ID="$source_id"
        CURRENT_LINE_COUNT=$((start+count-1))
        CURRENT_LAST_LINE_HASH=$(hash_log_line "$slice" "$count") || return 1
    fi
    ((full==0)) || { SYSLOG_BACKLOG=true;return 10; }
}

syslog_cursor_after_processed() {
    local processed="$1" first count start source source_id found=false
    while IFS=$'\t' read -r first count start source source_id;do
        ((processed>=first)) || break
        local consumed=$((processed-first+1));((consumed<=count)) || consumed=$count
        CURRENT_FILE_ID="$source_id"
        CURRENT_LINE_COUNT=$((start+consumed-1))
        CURRENT_LAST_LINE_HASH=$(hash_log_line "$SYSLOG_CURRENT_CHUNK" "$((first+consumed-1))") || return 1
        found=true
    done <"$STATE_DIR/slice-map.tsv"
    [[ "$found" == true ]] || { CURRENT_FILE_ID="$SAVED_FILE_ID";CURRENT_LINE_COUNT="$SAVED_LINE_COUNT";CURRENT_LAST_LINE_HASH="$SAVED_LAST_LINE_HASH"; }
}

build_new_syslog_chunk() {
    local output="$1" active_id="$CURRENT_FILE_ID" active_count="$CURRENT_LINE_COUNT" active_hash="$CURRENT_LAST_LINE_HASH" previous generation file start=1 rc
    SYSLOG_CURRENT_CHUNK="$output"
    SYSLOG_CAPTURED_ACTIVE_LINES="$active_count"
    : >"$output";: >"$STATE_DIR/slice-map.tsv";SYSLOG_BACKLOG=false
    if ! load_cursor;then
        start=$((active_count-STARTUP_LOOKBACK_LINES+1));((start>0)) || start=1
        rc=0;syslog_append_segment "$SYSLOG_FILE" "$start" "$output" || rc=$?;((rc==0 || rc==10));return
    fi
    if [[ "$SAVED_FILE_ID" == "$active_id" ]] && ((SAVED_LINE_COUNT<=active_count)) && { ((SAVED_LINE_COUNT==0)) || [[ $(hash_log_line "$SYSLOG_FILE" "$SAVED_LINE_COUNT") == "$SAVED_LAST_LINE_HASH" ]]; };then
        rc=0;syslog_append_segment "$SYSLOG_FILE" "$((SAVED_LINE_COUNT+1))" "$output" || rc=$?;((rc==0 || rc==10));return
    fi
    previous=$(find_previous_cursor_log || true)
    if [[ -n "$previous" ]];then
        IFS='|' read -r generation file <<<"$previous"
        rc=0;syslog_append_segment "$file" "$((SAVED_LINE_COUNT+1))" "$output" || rc=$?
        ((rc!=10)) || return 0;((rc==0)) || return 1
        for ((generation--;generation>=1;generation--));do
            file=$(get_rotated_syslog "$generation" || true)
            if [[ -z "$file" ]];then printf 'Syslog coverage error: missing rotated generation %s.\n' "$generation" >>"$output";continue;fi
            rc=0;syslog_append_segment "$file" 1 "$output" || rc=$?;((rc!=10)) || return 0;((rc==0)) || return 1
        done
        rc=0;syslog_append_segment "$SYSLOG_FILE" 1 "$output" || rc=$?;((rc==0 || rc==10));return
    fi
    printf '%s\n' 'Syslog coverage error: previous cursor was rewritten/unavailable; bounded lookback follows.' >>"$output"
    start=$((active_count-STARTUP_LOOKBACK_LINES+1));((start>0)) || start=1
    rc=0;syslog_append_segment "$SYSLOG_FILE" "$start" "$output" || rc=$?;((rc==0 || rc==10))
}

syslog_incident_severity() {
    if grep -Eiq "$CRITICAL_REGEX" <<<"$1";then printf CRITICAL;else printf WARNING;fi
}

syslog_record_incidents() {
    local rows="$STATE_DIR/incident-observations.jsonl" root="$STATE_DIR" target temp now
    [[ -s "$rows" ]] || return 0
    if mountpoint -q "${SYSLOG_VAULT_MOUNT:-/mnt/vault}";then root="${SYSLOG_INCIDENT_ROOT:-/mnt/vault/cloud/logs/script/host_health_watchdog}";fi
    [[ ! -L "$root" && $(realpath -m "$root") == "$root" ]] || return 1
    mkdir -p "$root" || return 1
    target="$root/incidents.json";[[ ! -L "$target" ]] || return 1
    [[ -f "$target" ]] || printf '{"schema":1,"incidents":{}}' >"$target"
    jq -e '.schema==1 and (.incidents|type)=="object"' "$target" >/dev/null || return 1
    # Merge a RAM spool after the vault returns. Remove it only after the
    # persistent atomic commit, so an interrupted migration retains evidence.
    local spool="$STATE_DIR/incidents.json" merge="$STATE_DIR/incidents.merge.json"
    if [[ "$target" != "$spool" && -f "$spool" && ! -L "$spool" ]];then
        jq -e '.schema==1 and (.incidents|type)=="object"' "$spool" >/dev/null || return 1
        jq -s '.[0] as $a | .[1] as $b | $a | .incidents=($a.incidents as $x | reduce ($b.incidents|to_entries[]) as $e ($x; .[$e.key]=(
          if .[$e.key]==null then $e.value else .[$e.key] as $old |
          (if $old.lastSeen>$e.value.lastSeen then $old else $e.value end)+
          {firstSeen:([$old.firstSeen,$e.value.firstSeen]|min),observations:([$old.observations,$e.value.observations]|max)} end)))' "$target" "$spool" >"$merge" || return 1
    else cp "$target" "$merge" || return 1;fi
    temp=$(mktemp "$root/.incidents.XXXXXX") || return 1;now=$(date +%s)
    jq --slurpfile rows "$rows" --argjson now "$now" --argjson max "$INCIDENT_MAX_ENTRIES" '
      reduce $rows[] as $r (.;.incidents[$r.id]=((.incidents[$r.id] // {firstSeen:$r.at,observations:0})+
        {lastSeen:$r.at,severity:$r.severity,example:$r.example,source:"Unraid syslog",observations:((.incidents[$r.id].observations // 0)+1),requiresAttention:($r.severity=="CRITICAL")})) |
      .updatedAt=$now|.incidents|=with_entries(select(.value.lastSeen>=$now-90*86400)) |
      .incidents|=(to_entries|sort_by(.value.lastSeen)|reverse|.[:$max]|from_entries)' "$merge" >"$temp" && chmod 600 "$temp" && mv "$temp" "$target" || return 1
    if [[ "$target" != "$spool" ]];then rm -f -- "$spool";fi
    rm -f -- "$merge"
}

# Independent bounded tail check prevents a large ordinary backlog delaying
# attention for a current kernel/storage/OOM event. It never advances the cursor.
syslog_critical_tail() {
    [[ "${SYSLOG_BACKLOG:-false}" == true ]] || return 0
    local chunk="$STATE_DIR/critical-tail.chunk" matches="$STATE_DIR/critical-tail.matches" bounded="$STATE_DIR/critical-tail.ledger"
    tail -n 2000 -- "$SYSLOG_FILE"|grep -Ei "$CRITICAL_REGEX"|tail -n "$MAX_NOTIFY_LINES" -- - >"$chunk" || true
    [[ -s "$chunk" ]] || return 0
    filter_matching_errors "$chunk" "$matches" || return 1
    [[ -s "$matches" ]] || return 0
    if notify_unraid alert 'Critical Unraid syslog events require attention' "Critical kernel/storage/system events detected beyond the chronological scan slice. No automatic repair, log deletion or service restart was attempted.
$(cat "$matches")
Incident JSON: ${SYSLOG_INCIDENT_ROOT:-/mnt/vault/cloud/logs/script/host_health_watchdog}/incidents.json
Repeated identical incidents retain the normal daily reminder limit; unread normal backlog is preserved.";then
        awk -F '\t' '{seen[$1]=$2}END{for(key in seen)print key "\t" seen[key]}' "$INCIDENT_NEXT"|sort -k2,2n|tail -n "$INCIDENT_MAX_ENTRIES" -- - >"$bounded" && mv "$bounded" "$STATE_DIR/incidents.tsv" || return 1
    else return 1;fi
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

    local line="" scrubbed key now previous xfs_source xfs_opened severity raw_number
    local deadline=$(( $(date +%s)+SYSLOG_FILTER_BUDGET_SECONDS ))
    : >"$STATE_DIR/incident-observations.jsonl"
    now=$(date +%s)
    INCIDENT_NEXT="${STATE_DIR}/incidents.pending"
    local history="${STATE_DIR}/incidents.tsv"
    : >"$INCIDENT_NEXT"
    if [ -f "$history" ]; then
        awk -F '\t' -v cutoff="$((now-INCIDENT_RETENTION_SECONDS))" '$2>=cutoff' "$history" | tail -n "$INCIDENT_MAX_ENTRIES" >"$INCIDENT_NEXT"
    fi
    : >"$match_file"

    while IFS= read -r line; do
        raw_number=${line%%:*};line=${line#*:}
        if (( $(date +%s)>=deadline ));then SYSLOG_BACKLOG=true;if [[ "$chunk_file" == "${SYSLOG_CURRENT_CHUNK:-}" ]];then syslog_cursor_after_processed "$((raw_number-1))" || return 1;fi;break;fi
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
            printf '%s\n' "$scrubbed" | grep -Eiq "($ERROR_REGEX|$CRITICAL_REGEX)" || continue
            # Daily health owns link-instability trends, but not actual I/O failures.
            if [[ "$line" =~ kernel:[[:space:]]+ata[0-9]+ ]] &&
               [[ "${line,,}" =~ hard\ resetting\ link|link\ is\ slow\ to\ respond|exception\ emask ]] &&
               [[ ! "${line,,}" =~ i/o\ error|read\ error|write\ error|failed\ command ]]; then
                continue
            fi
            key=""
        fi
        severity=$(syslog_incident_severity "$scrubbed")
        if [[ -z "$xfs_source" && "$severity" != CRITICAL ]] && is_ignored_line "$line"; then
            if [ "$LOG_IGNORED_LINES" = "true" ]; then
                log "SYSLOG" "INFO" \
                    "Ignored matching line: $line"
            fi

            continue
        fi

        [[ -n "$key" ]] || key=$(printf '%s\n' "$line" | sed -E \
          's/^[A-Z][a-z]{2} +[0-9]+ [0-9:]+ [^ ]+ //; s/^[0-9]{4}-[0-9T:.+-]+ [^ ]+ //; s/\[[0-9]+\]/[PID]/g; s/Killed process [0-9]+/Killed process PID/g; s/task [^ ]+:[0-9]+/task PROCESS:PID/g' | sha256sum | awk '{print $1}')
        key="$severity:$key"
        jq -nc --arg id "$key" --arg severity "$severity" --arg example "${line:0:2048}" --argjson at "$now" '{id:$id,at:$at,severity:$severity,example:$example}' >>"$STATE_DIR/incident-observations.jsonl" || return 1
        previous=$(awk -F '\t' -v key="$key" '$1==key {v=$2} END {print v+0}' "$INCIDENT_NEXT")
        if (( previous>0 && now-previous<INCIDENT_REMINDER_SECONDS )); then continue; fi
        printf '%s\t%s\n' "$key" "$now" >>"$INCIDENT_NEXT"
        printf '%s\n' "$line" >>"$match_file"

    done < <(
        grep \
            -nEi \
            "(${ERROR_REGEX}|${STORAGE_MATCH_REGEX}|${CRITICAL_REGEX})" \
            "$chunk_file" \
            2>/dev/null ||
            true
    )
    syslog_record_incidents || return 1
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
        mktemp /tmp/host_health_watchdog_chunk.XXXXXX
    )"

    match_file="$(
        mktemp /tmp/host_health_watchdog_matches.XXXXXX
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

    critical=$(grep -Eic "${CRITICAL_REGEX}|${STORAGE_MATCH_REGEX}" "$match_file" || true)
    (( critical==0 )) || importance=alert
    body+="Incident JSON: ${SYSLOG_INCIDENT_ROOT:-/mnt/vault/cloud/logs/script/host_health_watchdog}/incidents.json (new matches recorded automatically; critical incidents require review)"$'\n'
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

# BEGIN HOST HEALTH COMMON
# shellcheck shell=bash
# Shared read-only host/storage parsers. Embedded in standalone User Scripts.
HH_TIMEZONE="${HH_TIMEZONE:-Asia/Singapore}"
hh_mount_info() {
    local mount="$1" value fs options
    value=$(timeout --kill-after=1 4 findmnt -rn -M "$mount" -o FSTYPE,OPTIONS 9>&- 2>/dev/null) || value=''
    read -r fs options <<< "$value"
    if [[ -z "$fs" ]];then printf '{"mounted":false,"readOnly":false,"type":""}\n';return;fi
    jq -nc --arg fs "$fs" --arg options "$options" '{mounted:true,type:$fs,readOnly:($options|split(",")|index("ro")!=null)}'
}

hh_array_state() {
    awk -F= 'tolower($1)=="mdstate" {gsub(/[" \r]/,"",$2);print tolower($2);exit}' "${HH_VAR_INI:-/var/local/emhttp/var.ini}" 2>/dev/null
}

hh_expected_mounts() {
    printf '/boot\n'
    [[ "$(hh_array_state)" == started ]] || return 0
    # Native Unraid shareUser=e enables the /mnt/user FUSE share mount.
    if grep -Eq '^shareUser="?e"?[[:space:]]*$' "${HH_VAR_INI:-/var/local/emhttp/var.ini}" 2>/dev/null;then printf '/mnt/user\n';fi
    awk -F= '
      function emit(){if(slot ~ /^[A-Za-z0-9_.-]+$/ && (type=="Data" || type=="Cache") && fs!="" && (device!="" || identity!="" || assigned!="" || status=="DISK_DSBL" || status=="DISK_MISSING"))print "/mnt/"slot}
      /^\[/{emit();slot=$0;gsub(/[\[\]"\r]/,"",slot);type=fs=device=status=identity=assigned="";next}
      {v=$2;gsub(/["\r]/,"",v)} $1=="type"{type=v} $1=="fsType"{fs=v} $1=="device"{device=v} $1=="status"{status=v} $1=="id"{identity=v} $1=="idSb"{assigned=v} END{emit()}
    ' "${HH_DISKS_INI:-/var/local/emhttp/disks.ini}" 2>/dev/null
    if grep -Eqi '^DOCKER_ENABLED="?(yes|true|1)"?$' "${HH_DOCKER_CFG:-/boot/config/docker.cfg}" 2>/dev/null;then printf '/var/lib/docker\n';fi
}

hh_btrfs_metrics() {
    local usage="$1" show="${2:-}" parsed missing=false
    grep -qiE 'Some devices missing|path[[:space:]]+missing' <<< "$show" && missing=true
    parsed=$(awk '
      function number(s){gsub(/[^0-9]/,"",s);return s+0}
      /^ *Device size:/{size=number($3);gotSize=1}
      /^ *Device unallocated:/{unallocated=number($3);gotUnallocated=1}
      /^ *Device missing:/{missing=number($3);gotMissing=1}
      /^ *Free \(estimated\):/{free=number($3);gotFree=1}
      /^ *Global reserve:/{reserve=number($5)}
      /^Metadata,/{split($2,a,":");split($3,b,":");meta+=number(a[2]);used+=number(b[2]);gotMeta=1}
      END{printf "{\"valid\":%s,\"deviceBytes\":%.0f,\"unallocatedBytes\":%.0f,\"missingBytes\":%.0f,\"estimatedFreeBytes\":%.0f,\"metadataBytes\":%.0f,\"metadataUsedBytes\":%.0f,\"reserveUsedBytes\":%.0f}",
        (gotSize&&gotUnallocated&&gotMissing&&gotFree&&gotMeta&&meta>0?"true":"false"),size,unallocated,missing,free,meta,used,reserve}
    ' <<< "$usage") || return 1
    jq -c --argjson absent "$missing" '.+{missingMembers:$absent,metadataPercent:(if .metadataBytes>0 then 100*.metadataUsedBytes/.metadataBytes else null end)} |
      .+{severity:(if (.missingBytes>0 or .missingMembers) then "critical"
         elif .valid!=true then "unknown"
         elif (.metadataPercent>=95 and .unallocatedBytes<([1073741824,2*.metadataBytes]|max)) then
           (if .metadataPercent>=99 and .reserveUsedBytes>0 then "critical" else "warning" end)
         else "ok" end)}' <<< "$parsed"
}

hh_cron_last_due() {
    local expression="$1" now="$2"
    php /dev/stdin "$expression" "$now" "$HH_TIMEZONE" <<'PHP'
<?php
function field($s,$min,$max,$dow=false){$out=[];foreach(explode(',',$s)as$p){$parts=explode('/',$p);if(count($parts)>2)return null;$step=$parts[1]??'1';if(!ctype_digit($step)||intval($step)<1)return null;$base=$parts[0];
if($base==='*'){ $a=$min;$b=$max; }elseif(preg_match('/^(\d+)-(\d+)$/',$base,$m)){ $a=intval($m[1]);$b=intval($m[2]); }elseif(ctype_digit($base)){ $a=intval($base);$b=count($parts)>1?$max:$a; }else return null;
if($a<$min||$b>$max||$a>$b)return null;for($i=$a;$i<=$b;$i+=intval($step))$out[$dow&&$i===7?0:$i]=true;}return $out;}
$e=preg_split('/\s+/',trim($argv[1]));$now=intval($argv[2]);try{$tz=new DateTimeZone($argv[3]);}catch(Throwable $x){echo '{"valid":false}';exit;}
if(count($e)!==5){echo '{"valid":false}';exit;}$bounds=[[0,59],[0,23],[1,31],[1,12],[0,7]];$f=[];foreach($e as$i=>$s){$v=field($s,$bounds[$i][0],$bounds[$i][1],$i===4);if($v===null){echo '{"valid":false}';exit;}$f[]=$v;}
$base=(new DateTimeImmutable('@'.$now))->setTimezone($tz)->setTime(0,0);$hours=array_keys($f[1]);$minutes=array_keys($f[0]);rsort($hours);rsort($minutes);
for($d=0;$d<=400;$d++){$day=$base->modify('-'.$d.' days');if(!isset($f[3][intval($day->format('n'))]))continue;
$dom=isset($f[2][intval($day->format('j'))]);$dow=isset($f[4][intval($day->format('w'))]);$domStar=str_starts_with($e[2],'*');$dowStar=str_starts_with($e[4],'*');
$match=$domStar&&$dowStar?($dom&&$dow):($domStar?$dow:($dowStar?$dom:($dom||$dow)));if(!$match)continue;
foreach($hours as$h)foreach($minutes as$m){$t=$day->setTime($h,$m)->getTimestamp();if($t<=$now){echo json_encode(['valid'=>true,'dueEpoch'=>$t,'dueLocal'=>$day->setTime($h,$m)->format('Y-m-d H:i:s T')]);exit;}}}
echo '{"valid":true,"dueEpoch":0}';
PHP
}
# END HOST HEALTH COMMON

# BEGIN HOST HEALTH PROBES
# shellcheck shell=bash
# Fast host checks: read-only, every existing watchdog invocation. No disk tests,
# network restarts, balancing, filesystem repair, or application changes.
# Warning conditions require three samples; recoveries require two good samples.
# Unknown/unsupported results never clear a known incident. Delivery is journaled.
HH_RAM_ROOT="${HH_RAM_ROOT:-/run}"
HH_PROC_ROOT="${HH_PROC_ROOT:-/proc}"
HH_SYS_ROOT="${HH_SYS_ROOT:-/sys}"
HH_MIRROR="${HH_MIRROR:-/mnt/vault/cloud/logs/script/host_health_watchdog/host-health.json}"
HH_PENDING_BODY='' HH_PENDING_IMPORTANCE=normal HH_PREPARED=0 HH_DIRTY=0
hh_atomic() {
    local target="$1" value="$2" temp
    [[ -d "${target%/*}" && ! -L "$target" ]] || return 1
    if [[ -e "$target" ]];then [[ -f "$target" && $(stat -c %u "$target") == "$EUID" && $(stat -c %h "$target") == 1 ]] || return 1;fi
    temp=$(mktemp "${target%/*}/.host-health.XXXXXX") || return 1
    if printf '%s\n' "$value" > "$temp" && chmod 600 "$temp" && mv -f -- "$temp" "$target";then return 0;fi
    rm -f -- "$temp";return 1
}
hh_observe() {
    local id="$1" severity="$2" title="$3" detail="$4" confirmations="${5:-3}" action
    action=$(hc_probe_action "$id")
    HH_OBSERVATIONS=$(jq -c --arg id "$id" --arg severity "$severity" --arg title "$title" --arg detail "$detail" --argjson confirmations "$confirmations" --arg action "$action" '.+[{id:$id,severity:$severity,title:$title,detail:$detail,confirmations:$confirmations,action:$action}]' <<< "$HH_OBSERVATIONS")
}
hh_usage() {
    local path="$1" numbers total avail inode_total inode_free used severity=ok
    numbers=$(timeout --kill-after=1 4 stat -f -c '%b %a %c %d' "$path" 9>&- 2>/dev/null) || { hh_observe "space:$path" unknown "Capacity $path" 'Filesystem capacity could not be read';return; }
    read -r total avail inode_total inode_free <<< "$numbers"
    [[ "$total" =~ ^[0-9]+$ && "$avail" =~ ^[0-9]+$ && "$total" -gt 0 ]] || return
    used=$((100*(total-avail)/total));((used>=90)) && severity=warning;((used>=97)) && severity=critical
    # Capacity hysteresis: do not clear a previous finding until below 85%.
    if ((used>=85 && used<90)) && jq -e --arg id "space:$path" '.conditions[$id].active==true' <<< "$HH_STATE" >/dev/null;then severity=warning;fi
    hh_observe "space:$path" "$severity" "Capacity $path" "Used ${used}%; warning 90%, critical 97%, recovery below 85%." 2
    if [[ "$inode_total" =~ ^[0-9]+$ && "$inode_total" -gt 0 && "$inode_free" =~ ^[0-9]+$ ]];then
        used=$((100*(inode_total-inode_free)/inode_total));severity=ok
        ((used>=90)) && severity=warning;((used>=97)) && severity=critical
        hh_observe "inodes:$path" "$severity" "Inodes $path" "Allocated inode use ${used}%." 3
    fi
}
hh_cpu() {
    local sensor name input label current maximum critical severity id previous found=0
    for sensor in "$HH_SYS_ROOT"/class/hwmon/hwmon*;do
        [[ -r "$sensor/name" ]] || continue;read -r name < "$sensor/name"
        case "$name" in coretemp|k10temp|zenpower) ;; *) continue;;esac
        for input in "$sensor"/temp*_input;do
            [[ -r "$input" ]] || continue;label=$(cat "${input%_input}_label" 2>/dev/null)
            case "$label" in 'Package id '*|Tctl|Tdie) ;; *) continue;;esac
            current=$(cat "$input");maximum=$(cat "${input%_input}_max" 2>/dev/null);critical=$(cat "${input%_input}_crit" 2>/dev/null)
            [[ "$current" =~ ^[0-9]+$ && "$maximum" =~ ^[0-9]+$ && "$critical" =~ ^[0-9]+$ ]] || continue
            ((maximum>0 && critical>=maximum && current<200000)) || continue
            id="cpu:$name:$label";found=1;severity=ok
            ((current>=maximum)) && severity=warning;((current>=critical)) && severity=critical
            previous=$(jq -r --arg id "$id" '.conditions[$id].active//false' <<< "$HH_STATE")
            if [[ "$severity" == ok && "$previous" == true ]] && ((current>maximum-5000));then severity=warning;fi
            hh_observe "$id" "$severity" 'CPU temperature' "$label $((current/1000))C; driver limit $((maximum/1000))C, critical $((critical/1000))C." 1
        done
    done
    if ((found==0));then
        if jq -e 'any(.conditions|keys[];startswith("cpu:") and .!="cpu:coverage")' <<< "$HH_STATE" >/dev/null;then
            hh_observe cpu:coverage warning 'CPU temperature sensor unavailable' 'A previously observed CPU sensor is unavailable; previous incidents are retained and no healthy temperature inferred.' 3
        else hh_observe cpu:coverage unsupported 'CPU temperature coverage' 'No trusted package sensor with firmware limits; no guessed limit applied.';fi
    else hh_observe cpu:coverage ok 'CPU temperature coverage' 'Trusted CPU package sensors were collected.';fi
}
hh_network() {
    local iface base carrier speed supported max_speed expected mac old previous_at delta_e delta_p errors packets severity detail flags
    # Only physical interfaces participating in an active default-route bridge,
    # bond or direct route. Excludes Docker/veth/Tailscale and unused adapters.
    local route interfaces=''
    route=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<NF;i++)if($i=="dev")print $(i+1)}' | sort -u)
    for iface in $route;do
        if [[ -d "$HH_SYS_ROOT/class/net/$iface/device" ]];then interfaces+="$iface ";fi
        for base in "$HH_SYS_ROOT/class/net/$iface/brif/"* "$HH_SYS_ROOT/class/net/$iface/lower_"*;do
            [[ -e "$base" ]] || continue
            local member;member=${base##*/};member=${member#lower_}
            if [[ -d "$HH_SYS_ROOT/class/net/$member/device" ]];then interfaces+="$member ";fi
            if [[ -r "$HH_SYS_ROOT/class/net/$member/bonding/slaves" ]];then interfaces+="$(cat "$HH_SYS_ROOT/class/net/$member/bonding/slaves") ";fi
        done
        [[ ! -r "$HH_SYS_ROOT/class/net/$iface/bonding/slaves" ]] || interfaces+="$(cat "$HH_SYS_ROOT/class/net/$iface/bonding/slaves") "
    done
    for iface in $(tr ' ' '\n' <<< "$interfaces" | sort -u);do
        base="$HH_SYS_ROOT/class/net/$iface";[[ -d "$base/device" ]] || continue
        flags=$(cat "$base/flags" 2>/dev/null);[[ "$flags" =~ ^0x[0-9a-fA-F]+$ ]] || continue
        (( (flags&1)==1 )) || continue
        carrier=$(cat "$base/carrier" 2>/dev/null);speed=$(cat "$base/speed" 2>/dev/null);mac=$(cat "$base/address")
        old=$(jq -c --arg id "$iface:$mac" '.baselines.network[$id]//{}' <<< "$HH_STATE")
        previous_at=$(jq -r '.at//0' <<< "$old");max_speed=$(jq -r '.maxSpeed//0' <<< "$old")
        [[ "$speed" =~ ^[0-9]+$ ]] || speed=0
        supported=$(timeout --kill-after=1 3 ethtool "$iface" 9>&- 2>/dev/null | sed -n '/Supported link modes:/,/Supported pause frame use:/p' | grep -oE '[0-9]+base' | sed 's/base//' | sort -nr | head -n1) || supported=''
        if [[ "$supported" =~ ^[0-9]+$ ]];then expected=$((supported<2500?supported:2500));else expected=$max_speed;fi
        severity=ok;detail="Link ${speed}Mb/s; expected at least ${expected}Mb/s."
        if [[ "$carrier" == 0 ]];then severity=critical;detail='Active LAN carrier is down.'
        elif [[ "$carrier" != 1 ]];then severity=unknown
        elif ((expected>0 && speed<expected));then severity=warning;fi
        hh_observe "network:link:$iface:$mac" "$severity" "LAN link $iface" "$detail" 2
        errors=0;packets=0
        local metric value valid=true
        for metric in rx_errors tx_errors rx_packets tx_packets;do
            value=$(cat "$base/statistics/$metric" 2>/dev/null)
            [[ "$value" =~ ^[0-9]+$ ]] || { valid=false;break; }
            case "$metric" in *_errors) errors=$((errors+value));; *) packets=$((packets+value));;esac
        done
        severity=unknown;detail='New baseline or sampling gap; lifetime counters are not treated as current errors.'
        if [[ "$valid" == true ]] && ((previous_at>0 && HH_NOW>previous_at && HH_NOW-previous_at<=1200));then
            delta_e=$((errors-$(jq -r '.errors//0' <<< "$old")));delta_p=$((packets-$(jq -r '.packets//0' <<< "$old")))
            if ((delta_e>=0 && delta_p>=0));then
                severity=ok;((delta_e>=5 && delta_e*1000>=delta_p)) && severity=warning
                detail="New RX/TX errors=$delta_e; packets=$delta_p since previous sample. Drops alone are excluded."
            fi
        fi
        hh_observe "network:errors:$iface:$mac" "$severity" "LAN errors $iface" "$detail" 3
        if [[ "$valid" == true ]];then
            ((speed>max_speed)) && max_speed=$speed
            HH_STATE=$(jq -c --arg id "$iface:$mac" --argjson at "$HH_NOW" --argjson errors "$errors" --argjson packets "$packets" --argjson speed "$max_speed" '.baselines.network[$id]={at:$at,errors:$errors,packets:$packets,maxSpeed:$speed}' <<< "$HH_STATE")
        fi
    done
}
# Optional external-observer enrollment. Read the Pi's atomic runtime state with
# the existing management SSH identity; never invoke a repair or expose mail keys.
hh_external_observer() {
    local config="${HH_EXTERNAL_OBSERVER_CONFIG:-/boot/config/plugins/user.scripts/scripts/host_health_watchdog/external-observer.json}" target installed raw now="$HH_NOW" severity=ok detail
    [[ -e "$config" ]] || return 0
    if [[ -L "$config" || $(stat -c %u "$config") != "$EUID" ]] ||
       ! jq -e '.schema==1 and (.enabled|type)=="boolean"' "$config" >/dev/null 2>&1;then
        hh_observe monitor:external-observer warning 'External observer enrollment' 'External observer configuration is unsafe or invalid; no remote command was attempted.' 3;return
    fi
    [[ $(jq -r '.enabled' "$config") == true ]] || return 0
    target=$(jq -r '.sshTarget' "$config");installed=$(jq -r '.installedAt//0' "$config")
    [[ "$target" =~ ^[a-zA-Z0-9_-]+@[0-9.]+$ && "$installed" =~ ^[0-9]+$ ]] || { hh_observe monitor:external-observer warning 'External observer enrollment' 'Enrollment target or timestamp is invalid.' 3;return; }
    if ! raw=$(timeout --kill-after=1 8 ssh -n -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ConnectTimeout=4 -o ConnectionAttempts=1 "$target" 'sudo -n /bin/cat /var/lib/hubble_availability_watchdog/state.json' 9>&- 2>/dev/null | head -c 65537) ||
       (( ${#raw}>65536 )) || ! jq -e '.schema==1 and (.lastRun.epoch|type)=="number" and (.delivery|type)=="object"' <<< "$raw" >/dev/null 2>&1;then
        severity=warning;detail='Pi observer state could not be read or validated; its execution/mail coverage is unverified. No Pi or DNS restart was attempted.'
        ((now-installed>=900)) || severity=unknown
    elif ! jq -e --argjson now "$now" '.lastRun.epoch<=$now+300 and .lastRun.epoch>=$now-600' <<< "$raw" >/dev/null;then
        severity=warning;detail='Pi observer execution is stale (over ten minutes) or its clock disagrees; inspect its cron/service. No stale result was declared current.'
    elif jq -e '(.delivery.failures//0)>0' <<< "$raw" >/dev/null;then
        severity=warning;detail='Pi observer is running but independent SMTP delivery is failing; pending outage/recovery events remain queued for retry.'
    else detail='Pi observer has a recent completed scan; no outstanding SMTP delivery failure is recorded.';fi
    hh_observe monitor:external-observer "$severity" 'External Hubble observer' "$detail" 3
}
hh_collect() {
    local path info severity type uptime available total percent emergency metrics usage show uuid member rotational all_ssd
    HH_OBSERVATIONS='[]';uptime=${HH_UPTIME:-$(cut -d. -f1 "$HH_PROC_ROOT/uptime")}
    local array_state
    array_state=$(hh_array_state)
    case "$array_state" in
      started|stopped|stopping|starting) hh_observe monitor:mount-inventory ok 'Native mount inventory' "Unraid array state=$array_state; stopped storage is intentionally excluded.";; *)
        hh_observe monitor:mount-inventory warning 'Native mount inventory unavailable' 'Unraid array state could not be read; assigned mount coverage is unverified.' 3;;esac
    while IFS= read -r path;do
        info=$(hh_mount_info "$path");severity=ok
        if [[ $(jq -r '.mounted' <<< "$info") != true ]];then
            severity=critical;((uptime<600)) && severity=unknown
        elif [[ $(jq -r '.readOnly' <<< "$info") == true ]];then severity=critical;fi
        hh_observe "mount:$path" "$severity" "Required mount $path" "Mount evidence: $info. No repair or remount attempted." 1
        [[ "$severity" == ok ]] || continue
        case "$path" in /boot|/var/lib/docker) hh_usage "$path";; /mnt/*)
            # Never poll rotating array disks for capacity or Btrfs pressure.
            [[ "$path" == /mnt/disk[0-9]* ]] && continue
            type=$(jq -r '.type' <<< "$info");[[ "$type" == btrfs ]] || continue
            uuid=$(findmnt -rn -M "$path" -o UUID);all_ssd=true
            [[ -n "$uuid" && -d "$HH_SYS_ROOT/fs/btrfs/$uuid/devices" ]] || all_ssd=false
            for member in "$HH_SYS_ROOT/fs/btrfs/$uuid/devices/"*;do
                [[ -e "$member" ]] || { all_ssd=false;break; }
                rotational=$(lsblk -ndo ROTA "/dev/${member##*/}" 2>/dev/null)
                [[ "$rotational" == 0 ]] || all_ssd=false
            done
            [[ "$all_ssd" == true ]] || continue
            usage=$(timeout --kill-after=1 5 btrfs filesystem usage -b "$path" 9>&- 2>/dev/null) || usage=''
            show=$(timeout --kill-after=1 5 btrfs filesystem show "$path" 9>&- 2>/dev/null) || show=''
            metrics=$(hh_btrfs_metrics "$usage" "$show")
            hh_observe "btrfs:$path" "$(jq -r '.severity' <<< "$metrics")" "Btrfs pool $path" "$(jq -r '"Metadata use=\((.metadataPercent//0)*10|round|./10)%; unallocated=\(.unallocatedBytes/1073741824|floor)GiB; missing device bytes=\(.missingBytes); missing members=\(.missingMembers); reserve used=\(.reserveUsedBytes)B. Metadata pressure requires low unallocated headroom. No balance or repair was attempted."' <<< "$metrics")" 2
            ;;
        esac
    done < <(hh_expected_mounts | sort -u)
    hc_daily_probe || return 1
    hc_disk_temperatures
    hh_usage /
    read -r total available < <(awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}END{print t+0,a+0}' "$HH_PROC_ROOT/meminfo")
    if ((total>0));then
        percent=$((100*available/total));severity=ok;((percent<10)) && severity=warning;((percent<3)) && severity=critical
        hh_observe memory "$severity" 'Available memory' "MemAvailable=${percent}% (${available}KiB of ${total}KiB); reclaimable cache is included." 2
    else hh_observe memory unknown 'Available memory' 'MemAvailable could not be read.';fi
    hh_cpu;hh_network;hh_external_observer
    emergency="$HH_RAM_ROOT/host-health-monitor-emergency.json"
    if [[ -f "$emergency" && ! -L "$emergency" ]] && jq -e --arg boot "$HH_BOOT" '.bootId==$boot and (.healthy|type)=="boolean"' "$emergency" >/dev/null 2>&1;then
        severity=$(jq -r 'if .healthy then "ok" else "critical" end' "$emergency")
        hh_observe monitor:disk-state "$severity" 'Daily disk monitor state access' "$(jq -r '.detail' "$emergency")" 1
    fi
}
hh_lifecycle() {
    # Keep delivery state separate from observations. A failed notification never
    # consumes an event. Consecutive samples must be close enough to be sustained.
    HH_STATE=$(jq -c --argjson observations "$HH_OBSERVATIONS" --argjson now "$HH_NOW" '
      .conditions //= {} | . as $root |
      reduce $observations[] as $o (. ; .conditions[$o.id] as $previous |
        ($previous//{active:false,bad:0,good:0,notifiedAt:0}) as $p |
        ($p + {title:$o.title,detail:$o.detail,action:($o.action//"Review reported evidence; no repair was attempted."),lastSeen:$now}) as $c |
        (if (($p.lastSeen//0)<$now-1200) then $c+{bad:0,good:0} else $c end) as $c |
        if ($o.delegated//false) then .conditions[$o.id]=($c+{active:false,pending:"",bad:0,good:0,delegatedTo:"host_health_monitor"})
        elif ($o.severity=="warning" or $o.severity=="critical") then
          ($c+{bad:($c.bad+1),good:0}) as $c |
          (if $o.severity=="critical" then $o.confirmations else 3 end) as $required |
          if $c.bad >= $required then
            .conditions[$o.id]=($c+{active:true,severity:$o.severity} |
              if ($p.active!=true or $p.severity!=$o.severity or ($now-($p.notifiedAt//0)>=86400 and ($p.pending//"")==""))
              then .pending=(if $p.active!=true then "RAISED" elif $p.severity!=$o.severity then "SEVERITY CHANGED" else "REMINDER" end) else . end)
          else .conditions[$o.id]=$c end
        elif $o.severity=="ok" then
          ($c+{bad:0,good:($c.good+1)}) as $c |
          .conditions[$o.id]=(if $p.active==true and $c.good>=2 then $c+{active:false,pending:"RECOVERED"} else $c end)
        else .conditions[$o.id]=($c+{bad:0,good:0}) end) |
      # Removed hardware is retired, never described as a proven recovery.
      .conditions |= with_entries(select(.value.active==true or (.value.pending//"")!="" or .value.lastSeen >= $now-604800)) |
      .baselines.network |= with_entries(select(.value.at >= $now-604800)) |
      .lastSampleAt=$now' <<< "$HH_STATE") || return 1
    HH_PENDING_BODY=$(jq -r '.conditions|to_entries|map(select((.value.pending//"")!=""))|sort_by(if .value.severity=="critical" then 0 else 1 end,.key)|.[0:24][]|"- [\(.value.pending)] \(.value.title) [\(.value.severity//"info")]\n  \(.value.detail)\n  Action: \(.value.action//"Review reported evidence; no automatic repair was attempted.")"' <<< "$HH_STATE")
    HH_PENDING_IMPORTANCE=$(jq -r 'if any(.conditions[];(.pending//"")!="" and .active==true and .severity=="critical") then "alert" elif any(.conditions[];(.pending//"")!="" and .active==true) then "warning" else "normal" end' <<< "$HH_STATE")
}
hh_save() {
    local receipt info mirror_at combined
    combined=$(hc_combined_health "$HH_OBSERVATIONS" "$HH_STATE" "$HH_NOW") || return 1
    hh_atomic "$HH_RAM_ROOT/host-health-state.json" "$HH_STATE" || return 1
    receipt=$(jq -nc --arg boot "$HH_BOOT" --argjson now "$HH_NOW" --argjson observations "$HH_OBSERVATIONS" --argjson state "$HH_STATE" --argjson combined "$combined" '{health:$combined,schema:1,bootId:$boot,observedAt:$now,status:"COMPLETE",activeConditions:([$state.conditions[]|select(.active)]|length),observations:$observations}')
    hh_atomic "$HH_RAM_ROOT/host-health-receipt.json" "$receipt" || return 1
    info=$(hh_mount_info /mnt/vault)
    if jq -e '.mounted and (.readOnly|not)' <<< "$info" >/dev/null;then
        mirror_at=$(jq -r '.lastSampleAt//0' "$HH_MIRROR" 2>/dev/null) || mirror_at=0
        if [[ "$mirror_at" =~ ^[0-9]+$ ]] && { ((HH_NOW-mirror_at>=3600)) || [[ -n "$HH_PENDING_BODY" || "${HH_DIRTY:-0}" == 1 ]]; };then
            [[ -d "${HH_MIRROR%/*}" && ! -L "${HH_MIRROR%/*}" ]] || mkdir -p -- "${HH_MIRROR%/*}" || return 1
            hh_atomic "$HH_MIRROR" "$HH_STATE" || return 1
        fi
    fi
}
hh_prepare() {
    HH_NOW=${HH_NOW:-$(date +%s)};HH_BOOT=${HH_BOOT:-$(cat "$HH_PROC_ROOT/sys/kernel/random/boot_id")};HH_STATE='{}'
    local source
    for source in "$HH_RAM_ROOT/host-health-state.json" "$HH_MIRROR";do
        [[ -f "$source" && ! -L "$source" && $(stat -c %u "$source") == "$EUID" ]] || continue
        if jq -e '.schema==1 and (.conditions|type)=="object" and (.baselines.network|type)=="object"' "$source" >/dev/null 2>&1;then HH_STATE=$(cat "$source");break;fi
    done
    HH_STATE=$(jq -c --arg boot "$HH_BOOT" '.conditions //= {} | .baselines.network //= {} | if .bootId!=$boot then .baselines={network:{}}|.conditions|=with_entries(.value.bad=0|.value.good=0) else . end | .schema=1 | .bootId=$boot | .baselines.network //= {}' <<< "$HH_STATE") || return 1
    hh_collect && hh_lifecycle && hh_save || return 1
    HH_PREPARED=1
}
# Console presentation only: consume this scan's saved observations, never
# re-probe hardware, change confirmation state or enqueue an email here.
hh_log_observations() {
    local category level message id observed title detail active bad good pending required summary
    while IFS=$'\t' read -r id observed title detail active bad good pending required;do
        [[ -n "$id" ]] || continue
        category=HOST
        case "$id" in
          mount:*|monitor:mount-inventory) category=MOUNTS;;
          space:*) category=CAPACITY;; inodes:*) category=INODES;;
          disk-temperature:*|monitor:disk-temperatures) category=TEMPERATURE;;
          memory) category=MEMORY;; cpu:*) category=CPU;; network:*) category=LAN;;
          btrfs:*) category=BTRFS;; monitor:external-observer) category=OBSERVER;;
          monitor:disk-state) category=DISK_STATE;;
        esac
        case "$observed" in
          ok) level=INFO;; warning) level=WARNING;; critical) level=CRITICAL;;
          unknown) level=WARNING;; *) level=INFO;;
        esac
        message="$title: observed=${observed^^}; $detail"
        if [[ "$active" == true ]];then
            message+=" Active incident retained"
            [[ "$observed" != ok ]] || message+="; recovery confirmation $good/2"
            message+="."
        elif [[ "$observed" == warning || "$observed" == critical ]];then
            message+=" Confirmation pending $bad/$required; no confirmed incident yet."
        fi
        [[ "$pending" == none ]] || message+=" Lifecycle event=$pending."
        log "$category" "$level" "$message"
    done < <(jq -r --argjson state "$HH_STATE" '.[] | . as $o | ($state.conditions[$o.id] // {}) as $c |
      [$o.id,$o.severity,$o.title,$o.detail,($c.active // false),($c.bad // 0),($c.good // 0),($c.pending // "" | if .=="" then "none" else . end),
       (if $o.severity=="critical" then $o.confirmations else 3 end)] |
      map(tostring|gsub("[\\t\\r\\n]";" ")) | @tsv' <<< "$HH_OBSERVATIONS")
    if ! jq -e 'any(.[]; .id|startswith("network:"))' <<< "$HH_OBSERVATIONS" >/dev/null;then
        log LAN INFO 'LAN coverage: not collected; no eligible active physical default-route interface was observed. No healthy link result inferred.'
    fi
    if ! jq -e 'any(.[]; .id|startswith("btrfs:"))' <<< "$HH_OBSERVATIONS" >/dev/null;then
        log BTRFS INFO 'Btrfs pressure coverage: not collected; only mounted, verified all-SSD Btrfs pools are eligible. Rotating array disks remain excluded.'
    fi
    summary=$(jq -nr --argjson observations "$HH_OBSERVATIONS" --argjson state "$HH_STATE" '
      "Host probes completed: observations=\($observations|length); OK=\([$observations[]|select(.severity=="ok")]|length); warning=\([$observations[]|select(.severity=="warning")]|length); critical=\([$observations[]|select(.severity=="critical")]|length); unverified=\([$observations[]|select(.severity=="unknown")]|length); deferred=\([$observations[]|select(.severity=="deferred")]|length); unsupported=\([$observations[]|select(.severity=="unsupported")]|length); active incidents=\([$state.conditions[]|select(.active==true)]|length). RAM receipt saved; notifications follow the existing lifecycle policy."') || return 1
    log HOST INFO "$summary"
    log HOST INFO "Coordinated health=$(jq -r .health.healthStatus "$HH_RAM_ROOT/host-health-receipt.json"); daily freshness=$(jq -r .freshness <<< "$HC_DAILY_SNAPSHOT"). Scan completion and condition health are separate."
}
hh_delivered() {
    HH_STATE=$(jq -c --argjson now "$HH_NOW" '([.conditions|to_entries[]|select((.value.pending//"")!="")]|sort_by(if .value.severity=="critical" then 0 else 1 end,.key)|.[0:24]|map(.key)) as $ids | reduce $ids[] as $id (. ; .conditions[$id].pending=""|.conditions[$id].notifiedAt=$now)' <<< "$HH_STATE") || return 1
    HH_PENDING_BODY='';HH_DIRTY=1;hh_save
}
hh_flush() {
    [[ "$HH_PREPARED" == 1 && -n "$HH_PENDING_BODY" ]] || return 0
    notify_unraid "$HH_PENDING_IMPORTANCE" 'Host health conditions changed' 'Read-only host checks; no repair, restart or configuration change was performed.'
}
# END HOST HEALTH PROBES


# Restricted SSH endpoint for the Pi. Reads only RAM/native status; does not
# initialize state, take the producer lock, acknowledge incidents or notify.
host_external_status() {
    local now boot uptime receipt='{}' file="${HH_FAST_RECEIPT:-/run/host-health-receipt.json}"
    now=$(date +%s);boot=$(cat /proc/sys/kernel/random/boot_id);uptime=$(cut -d. -f1 /proc/uptime)
    if [[ -f "$file" && ! -L "$file" && $(stat -c %u "$file") == "$EUID" && $(stat -c %h "$file") == 1 ]] &&
       jq -e '.schema==1 and (.observedAt|type)=="number"' "$file" >/dev/null 2>&1;then
        receipt=$(jq -c '{bootId,observedAt,status,activeConditions}' "$file") || receipt='{}'
    fi
    jq -nc --arg name "$(hostname)" --arg boot "$boot" --arg array "$(hh_array_state)" \
        --arg version "$SCRIPT_VERSION" --argjson epoch "$now" --argjson uptime "$uptime" --argjson receipt "$receipt" \
        '{schema:1,name:$name,bootId:$boot,epoch:$epoch,uptimeSeconds:$uptime,arrayState:$array,probeVersion:$version,fastWatchdog:$receipt}'
}

# BEGIN HOST HEALTH COORDINATION
# shellcheck shell=bash
# Coordinated health evidence; each producer retains incident ownership.
hc_owned_json() {
    local file="$1"
    [[ -f "$file" && ! -L "$file" && $(stat -c %u "$file" 2>/dev/null) == "$EUID" && $(stat -c %h "$file" 2>/dev/null) == 1 ]] || return 1
    (( $(stat -c %s "$file" 2>/dev/null || echo 9999999) <= 2097152 )) || return 1
    jq -e 'type=="object"' "$file" >/dev/null 2>&1
}

hc_daily_snapshot() {
    local now="$1" file="${HC_DAILY_RECEIPT:-/mnt/vault/cloud/logs/script/host_health_monitor/state/monitor_receipt.json}" schedule="${HC_SCHEDULE_FILE:-/boot/config/plugins/user.scripts/schedule.json}"
    local old='{}' evidence='{}' plan=unknown cron='' due='{"valid":false}' boot
    boot=$(cat "${HH_PROC_ROOT:-/proc}/sys/kernel/random/boot_id") || return 1
    if hc_owned_json "$schedule";then
        plan=$(jq -r '[to_entries[]|select(.key|endswith("/host_health_monitor/script"))][0].value.frequency // "absent"' "$schedule")
        if [[ "$plan" == custom ]];then
            cron=$(jq -r '[to_entries[]|select(.key|endswith("/host_health_monitor/script"))][0].value.custom // ""' "$schedule")
            due=$(hh_cron_last_due "$cron" "$now") || due='{"valid":false}'
            plan=enabled
        elif [[ "$plan" == absent || "$plan" == never || "$plan" == disabled || "$plan" == manual ]];then plan=disabled
        else plan=unknown;fi
    fi
    if hc_owned_json "$file";then
        old=$(cat "$file")
        if jq -e --argjson now "$now" '.healthEvidence.schema==1 and (.healthEvidence.observedAt|type)=="number" and .healthEvidence.observedAt>0 and .healthEvidence.observedAt<=$now+60 and (.healthEvidence.bootId|type)=="string" and (.healthEvidence.findings|type)=="array" and (.healthEvidence.findings|length)<=256 and all(.healthEvidence.findings[];(.id|type)=="string" and (.severity|IN("warning","critical")) and (.title|type)=="string" and (.detail|type)=="string" and (.action|type)=="string")' <<< "$old" >/dev/null;then
            evidence=$(jq -c .healthEvidence <<< "$old")
        fi
    fi
    jq -nc --argjson evidence "$evidence" --argjson producer "$old" --argjson due "$due" --arg plan "$plan" --arg boot "$boot" --argjson now "$now" '
      ($evidence.observedAt//0) as $at | ($due.dueEpoch//0) as $deadline |
      (if $plan=="disabled" then "NOT_SCHEDULED"
       elif $plan!="enabled" or ($due.valid//false)!=true then "UNVERIFIED"
       elif ($at>0 and $evidence.bootId==$boot and $at >= $deadline and $now-$at<=129600) then "CURRENT"
       elif $now<=$deadline+7200 then "AWAITING_SCHEDULED_COMPLETION" else "STALE" end) as $freshness |
      {freshness:$freshness,schedule:$plan,dueEpoch:$deadline,observedAt:$at,executionStatus:($producer.status//"unknown"),
       findings:(if $freshness=="NOT_SCHEDULED" then [] else ($evidence.findings//[]) end),coverage:($evidence.coverage//null),thresholds:($evidence.thresholds//{}),
       delivery:($producer.notification//"unknown")}'
}

hc_probe_action() {
    case "$1" in
      cpu:*|disk-temperature:*) printf 'Inspect cooling and airflow; reduce load if overheating persists. No cooling or hardware settings were changed.';;
      mount:*) printf 'Check native Unraid device and mount status. No remount or repair was attempted.';;
      btrfs:*) printf 'Check pool capacity, member availability and filesystem errors. No balance or repair was attempted.';;
      space:*|inodes:*) printf 'Review the affected filesystem and free space deliberately. No files were deleted.';;
      memory) printf 'Identify sustained memory consumers and check recent OOM events. No application was restarted.';;
      network:*) printf 'Check the LAN interface, cable and switch. No network settings were changed.';;
      monitor:daily-health) printf 'Check the daily User Script execution and retained completion evidence. No disk test or backup was forced.';;
      *) printf 'Review the reported evidence and restore the affected collector or service. No automatic repair was attempted.';;
    esac
}

hc_daily_probe() {
    HC_DAILY_SNAPSHOT=$(hc_daily_snapshot "$HH_NOW") || HC_DAILY_SNAPSHOT='{"freshness":"UNVERIFIED","executionStatus":"unverified","findings":[],"thresholds":{}}'
    local freshness severity=ok detail
    freshness=$(jq -r .freshness <<< "$HC_DAILY_SNAPSHOT")
    case "$freshness" in
      STALE|UNVERIFIED) severity=warning;;
      AWAITING_SCHEDULED_COMPLETION) severity=unknown;;
      NOT_SCHEDULED) severity=deferred;;
    esac
    if [[ "$freshness" == CURRENT ]] && jq -e '.executionStatus=="incomplete"' <<< "$HC_DAILY_SNAPSHOT" >/dev/null;then severity=warning;fi
    detail=$(jq -r '"Daily collector freshness=\(.freshness); latest execution=\(.executionStatus); retained disk findings=\(.findings|length). Last completed evidence="+(.observedAt|tostring)+". Findings remain owned by the daily monitor; schedule grace=2h."' <<< "$HC_DAILY_SNAPSHOT")
    hh_observe monitor:daily-health "$severity" 'Daily disk monitoring' "$detail" 2
}

hc_disk_temperatures() {
    local file="${HH_DISKS_INI:-/var/local/emhttp/disks.ini}" stamp slot dev native_id temp rota kind warn crit severity id count=0
    stamp=$(stat -c %Y "$file" 2>/dev/null) || stamp=0
    if [[ ! "$stamp" =~ ^[0-9]+$ ]] || ((stamp>HH_NOW+60 || HH_NOW-stamp>900));then
        hh_observe monitor:disk-temperatures warning 'Native disk temperatures unavailable' 'Unraid disk metadata is missing or older than 15 minutes; no SMART read or disk wake was performed.' 3
        return
    fi
    local limits='{}'
    if [[ ${HC_DAILY_SNAPSHOT:-} != '' ]];then limits=$(jq -c '.thresholds//{}' <<< "$HC_DAILY_SNAPSHOT");fi
    while IFS=$'\t' read -r slot dev native_id temp;do
        [[ "$dev" =~ ^(sd[a-z]+|nvme[0-9]+n[0-9]+)$ && -n "$native_id" && "$native_id" != none ]] || continue
        id="disk-temperature:$(printf '%s' "$native_id"|sha256sum|cut -c1-24)";count=$((count+1))
        if [[ "$dev" == nvme* ]];then kind=nvme;warn=70;crit=80
        else
            rota=$(cat "${HH_SYS_ROOT:-/sys}/class/block/$dev/queue/rotational" 2>/dev/null) || rota=''
            case "$rota" in 0) kind=ssd;warn=65;crit=70;;1) kind=hdd;warn=55;crit=60;;*) hh_observe "$id" unknown "Disk temperature $slot" 'Device type could not be verified; no threshold guessed.';continue;;esac
        fi
        local w c
        w=$(jq -r --arg kind "$kind" '.[$kind].warning//empty' <<< "$limits");c=$(jq -r --arg kind "$kind" '.[$kind].critical//empty' <<< "$limits")
        if [[ "$w" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ ]] && ((w>=20 && c>=w && c<=120));then warn=$w;crit=$c;fi
        if [[ ! "$temp" =~ ^[0-9]+$ ]] || ((temp<=0 || temp>=150));then
            hh_observe "$id" deferred "Disk temperature $slot" 'No current native temperature, commonly because the disk is sleeping. No healthy sample inferred and no disk woken.'
            continue
        fi
        severity=ok;((temp>=warn)) && severity=warning;((temp>=crit)) && severity=critical
        if [[ "$severity" == ok ]] && jq -e --arg id "$id" '.conditions[$id].active==true' <<< "$HH_STATE" >/dev/null && ((temp>warn-3));then severity=warning;fi
        hh_observe "$id" "$severity" "Disk temperature $slot" "$dev: ${temp}C; warning=${warn}C, critical=${crit}C; source=Unraid native metadata; no SMART polling or disk wake." 1
        HH_OBSERVATIONS=$(jq -c --arg id "$id" --arg device "/dev/$dev" 'map(if .id==$id then .+{device:$device} else . end)' <<< "$HH_OBSERVATIONS")
        # A daily fallback incident keeps its recovery ownership until confirmed.
        if [[ ${HC_DAILY_SNAPSHOT:-} != '' ]] && jq -e --arg device "/dev/$dev" '.freshness=="CURRENT" and any(.findings[]?;.device==$device and (.id|endswith("|temp")))' <<< "$HC_DAILY_SNAPSHOT" >/dev/null;then
            HH_OBSERVATIONS=$(jq -c --arg id "$id" 'map(if .id==$id then .+{delegated:true} else . end)' <<< "$HH_OBSERVATIONS")
        fi
    done < <(awk -F= '
      function emit(){if(dev!="" && slot!="flash")print slot"\t"dev"\t"(id==""?"none":id)"\t"(temp==""?"*":temp)}
      /^\[/{emit();slot=$0;gsub(/[\[\]"]/,"",slot);dev=id=temp="";next}
      {v=substr($0,index($0,"=")+1);gsub(/^"|"$/,"",v)} $1=="device"{dev=v}$1=="id"{id=v}$1=="temp"{temp=v} END{emit()}' "$file")
    if ((count==0));then hh_observe monitor:disk-temperatures unknown 'Native disk temperature coverage' 'No eligible device identities found in current Unraid metadata.'
    else hh_observe monitor:disk-temperatures ok 'Native disk temperature coverage' "$count device(s) inventoried; sleeping/unverified readings are deferred explicitly.";fi
}

hc_combined_health() {
    local observations="$1" state="$2" now="$3" daily active storage
    daily=${HC_DAILY_SNAPSHOT:-};[[ -n "$daily" ]] || daily=$(hc_daily_snapshot "$now") || daily='{"freshness":"UNVERIFIED","executionStatus":"unverified","findings":[]}'
    active=$(jq -c '[.conditions|to_entries[]|select(.value.active)|{id:.key,severity:.value.severity,title:.value.title,detail:.value.detail,pending:(.value.pending//""),source:"host_health_watchdog"}]' <<< "$state") || return 1
    local previous="${HC_FAST_RECEIPT:-${HH_RAM_ROOT:-/run}/host-health-receipt.json}" cached='[]'
    if jq -e '.freshness|IN("UNVERIFIED","STALE")' <<< "$daily" >/dev/null && hc_owned_json "$previous";then
        cached=$(jq -c --arg boot "$(cat /proc/sys/kernel/random/boot_id)" 'if .bootId==$boot then (.health.daily.findings//[]) else [] end' "$previous") || cached='[]'
        daily=$(jq -c --argjson cached "$cached" 'if (.findings|length)==0 and ($cached|type)=="array" then .findings=$cached|.cachedUnverified=true else . end' <<< "$daily") || return 1
    fi
    storage=$(hc_storage_snapshot "$now") || return 1
    jq -nc --argjson storage "$storage" --argjson daily "$daily" --argjson active "$active" --argjson observations "$observations" --argjson now "$now" '
      {schema:1,observedAt:$now,daily:$daily,fastFindings:$active,storage:$storage,
       healthStatus:(if any($active[];.severity=="critical") or any($daily.findings[];.severity=="critical") then "CRITICAL"
        elif ($active|length)>0 or ($daily.findings|length)>0 or ($storage.openXfsSources|length)>0 then "ATTENTION"
        elif ($storage.evidenceVerified|not) or $storage.executionStatus=="FAILED" or ($storage.fresh|not) or ($daily.freshness|IN("STALE","UNVERIFIED")) or any($observations[];.severity=="unknown") then "UNVERIFIED" elif any($observations[];(.severity|IN("warning","critical")) and (.delegated//false|not)) then "CONFIRMING" else "OK" end),
       coverage:{observations:($observations|length),unverified:([$observations[]|select(.severity=="unknown")]|length),deferred:([$observations[]|select(.severity=="deferred")]|length),unsupported:([$observations[]|select(.severity=="unsupported")]|length)}}'
}

hc_peer_context() {
    local role="$1" now="$2" daily fast='{}' file="${HC_FAST_RECEIPT:-/run/host-health-receipt.json}"
    if [[ "$role" == watchdog ]];then
        daily=${HC_DAILY_SNAPSHOT:-};[[ -n "$daily" ]] || daily=$(hc_daily_snapshot "$now") || return 1
        jq -r '"Daily disk context (existing findings; not additional notification events): freshness=\(.freshness); execution=\(.executionStatus).", (.findings|sort_by(if .severity=="critical" then 0 else 1 end)|.[0:24][]|"- [\(.severity|ascii_upcase)] \(.title): \(.detail|.[0:1200])\n  Action: \(.action|.[0:500])"), (if (.findings|length)>24 then "Additional existing disk findings: \((.findings|length)-24); retained in daily findings and their original notifications. Peer context does not acknowledge them." else empty end)' <<< "$daily"
    else
        if hc_owned_json "$file" && jq -e --argjson now "$now" --arg boot "$(cat /proc/sys/kernel/random/boot_id)" '.schema==1 and .bootId==$boot and .observedAt<=$now+60 and .observedAt>=$now-900' "$file" >/dev/null;then
            jq -r '"Fast host context (existing findings; watchdog owns notification/recovery): active incidents=\(.health.fastFindings//[]|length); observed epoch=\(.observedAt).",(.health.fastFindings[]?|"- [\(.severity|ascii_upcase)] \(.title): \(.detail)")' "$file"
        else printf 'Fast host context: UNVERIFIED; recent same-boot watchdog evidence unavailable. Daily disk findings remain independently reported.\n';fi
    fi
}

hc_storage_snapshot() {
    local now="$1" file="${SYSLOG_INCIDENT_ROOT:-/mnt/vault/cloud/logs/script/host_health_watchdog}/incidents.json" events='[]' xfs='[]' heartbeat=0
    local ledger="${XFS_INCIDENT_FILE:-/boot/config/plugins/user.scripts/scripts/host_health_watchdog/xfs_faults.tsv}" verified=true
    if hc_owned_json "$file";then
        events=$(jq -ce --argjson now "$now" '[.incidents|to_entries[]?|select(.value.severity=="CRITICAL" and .value.lastSeen>=$now-86400 and .value.lastSeen<=$now+60)|{id:.key,observedAt:.value.lastSeen,evidence:.value.example,kind:"historical_event_not_proof_of_current_fault"}]|sort_by(.observedAt)|reverse|.[0:24]' "$file") || { events='[]';verified=false; }
    elif [[ -e "$file" ]];then verified=false
    fi
    if [[ -f "$ledger" && ! -L "$ledger" && -O "$ledger" ]];then
        xfs=$(jq -Rn '[inputs|split("\t")|select((.[0]|test("^[A-Za-z0-9_.-]+$")) and (.[1]|test("^[0-9]+$")))|{source:.[0],firstObserved:(.[1]|tonumber),action:"Review XFS shutdown/corruption evidence; --ack-xfs clears a reviewed marker and does not repair the filesystem."}]' "$ledger") || { xfs='[]';verified=false; }
    fi
    file="${HC_SYSLOG_HEARTBEAT:-${STATE_DIR:-/tmp/host_health_watchdog_state}/storage-watch.epoch}"
    if [[ -f "$file" && ! -L "$file" && -O "$file" ]];then read -r heartbeat < "$file" || heartbeat=0;fi
    [[ "$heartbeat" =~ ^[0-9]+$ ]] || heartbeat=0
    jq -nc --argjson verified "$verified" --argjson events "$events" --argjson xfs "$xfs" --argjson heartbeat "$heartbeat" --argjson now "$now" --arg execution "${HC_SYSLOG_RUN_STATUS:-NOT_COLLECTED_THIS_INVOCATION}" '{evidenceVerified:$verified,executionStatus:$execution,lastSuccessfulScanEpoch:$heartbeat,fresh:($heartbeat>0 and $heartbeat<=$now+60 and $heartbeat>=$now-1200),recentCriticalEvents:$events,openXfsSources:$xfs}'
}

hc_print_status() {
    local file="${HC_FAST_RECEIPT:-/run/host-health-receipt.json}" now boot
    now=$(date +%s);boot=$(cat /proc/sys/kernel/random/boot_id)
    if ! hc_owned_json "$file" || ! jq -e --arg boot "$boot" --argjson now "$now" '.bootId==$boot and .observedAt<=$now+60 and .observedAt>=$now-900 and .health.schema==1' "$file" >/dev/null;then
        printf 'Host health: UNVERIFIED\nNo current same-boot coordinated receipt. No probes, state changes or notifications performed.\n';return 0
    fi
    jq -r '"Host health: \(.health.healthStatus)\nFast probes observed: \(.observedAt)\nDaily disk evidence: \(.health.daily.freshness); execution=\(.health.daily.executionStatus)\nFast active incidents: \(.health.fastFindings|length); disk findings: \(.health.daily.findings|length)\nCoverage: unverified=\(.health.coverage.unverified), deferred=\(.health.coverage.deferred), unsupported=\(.health.coverage.unsupported//0)\nSyslog scan: \(.health.storage.executionStatus); freshness=\(.health.storage.fresh)\nOpen XFS review markers: \(.health.storage.openXfsSources|length)",(.health.fastFindings[]?|"- [\(.severity|ascii_upcase)] \(.title): \(.detail)"),(.health.daily.findings[]?|"- [\(.severity|ascii_upcase)] \(.title): \(.detail)\n  Action: \(.action)")' "$file"
}
# END HOST HEALTH COORDINATION

main() {
    local final_exit=0
    case "${1:-}" in
      --version) printf 'host_health_watchdog.sh %s\n' "$SCRIPT_VERSION"; return 0 ;;
      --help|-h) printf '%s\n' 'Usage: /bin/bash SCRIPT [--version|--help|--health-status|--external-status|--open-xfs|--ack-xfs SOURCE]' \
        'No arguments: collect host probes, print each observation and scan summary, process new syslog and log capacity, then deliver existing lifecycle notifications when due.' \
        '--health-status reads the current coordinated health receipt; no scan, state change or notification.' \
        '--external-status reads native/RAM freshness for the external observer; no scan, state update or notification.' \
        '--open-xfs lists retained XFS incidents. --ack-xfs SOURCE removes one reviewed incident marker; it does not repair a filesystem.' \
        'Console output includes healthy, unverified and unsupported probes without changing email policy. See docs/user-scripts-cli.md in GitHub for all 18 scripts.';return 0;;
      --health-status) [[ $# == 1 ]] || return 2;hc_print_status;return;;
      --external-status) [[ $# == 1 ]] || return 2; host_external_status;return ;;
      ''|--open-xfs|--ack-xfs) ;;
      *) return 2 ;;
    esac
    exec 9>"$LOCK_FILE" || return 1
    flock -n 9 || { printf 'Another host health watchdog run is active; scan deferred.\n'; return 0; }

    # -----------------------------------------------------------------------
    # State initialization
    # -----------------------------------------------------------------------

    if ! ensure_dir "$STATE_DIR"; then
        printf '%s ERROR: Unable to create state directory: %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$STATE_DIR"

        return 1
    fi

    trap 'rc=$?; if ! hh_flush;then rc=1;fi; cleanup_temp_files; exit "$rc"' EXIT
    case "${1:-}" in
        --open-xfs) xfs_incident_state list; return ;;
        --ack-xfs) [[ $# == 2 ]] || return 2; xfs_incident_state ack "$2"; return ;;
    esac


    if ! hh_prepare;then
        log HOST ERROR 'Fast host checks or their RAM receipt failed; scan freshness will not advance'
        return 1
    fi
    hh_log_observations || return 1

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

    if ! syslog_critical_tail;then final_exit=1;fi
    if ! check_log_usage; then
        final_exit=1
    fi


    # -----------------------------------------------------------------------
    # Exit status
    # -----------------------------------------------------------------------

    HC_SYSLOG_RUN_STATUS=COMPLETED;((final_exit==0)) || HC_SYSLOG_RUN_STATUS=FAILED
    hh_save || final_exit=1
    hh_flush || final_exit=1
    if ((final_exit==0)) && hh_mount_info /mnt/vault | jq -e '.mounted and (.readOnly|not)' >/dev/null;then
        local receipt_root="${STATUS_DIR:-/mnt/vault/cloud/logs/script/user_scripts_status}" receipt
        mkdir -p "$receipt_root" || return 1
        receipt=$(mktemp "$receipt_root/.syslog-watchdog.XXXXXX") || return 1
        jq -n --arg boot "$(cat /proc/sys/kernel/random/boot_id)" --argjson at "$(date +%s)" --argjson host "$(jq '[.conditions[]|select(.active)]|length' <<< "$HH_STATE")" --argjson health "$(hc_combined_health "$HH_OBSERVATIONS" "$HH_STATE" "$(date +%s)")" '{health:$health,schema:1,name:"host_health_watchdog",activeHostConditions:$host,bootId:$boot,lastSuccessfulScanAt:$at,epoch:$at,status:"OK",scope:"Syslog, log capacity and fast host conditions checked; condition state is separate from successful scan freshness"}' >"$receipt" && chmod 600 "$receipt" && mv "$receipt" "$receipt_root/host_health_watchdog.json" || return 1
    fi
    [[ "${SYSLOG_BACKLOG:-false}" != true ]] || log SYSLOG INFO 'Bounded scan completed with unread backlog; next scheduled pass resumes from the last consumed line'
    return "$final_exit"
}


###############################################################################
# ENTRY POINT
###############################################################################

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
