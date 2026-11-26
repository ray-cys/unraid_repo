#!/bin/bash
# FRESHNESS: successful scan/delivery publishes a current-boot receipt to the
# central status directory. The hourly backup audit checks enabled dynamic cadence;
# a failed invocation cannot advance that successful-scan timestamp.
clearLog=true

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

# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="syslog_watchdog"
# shellcheck shell=bash
# Embedded operations contract v2; generated into standalone User Scripts.
# Millisecond timing without spawning date on supported Bash; GNU fallback.
usr_ops_now_ms() {
    local stamp="${EPOCHREALTIME:-}"
    if [[ "$stamp" =~ ^[0-9]+\.[0-9]{6}$ ]];then stamp=${stamp/./};printf '%s\n' "${stamp:0:${#stamp}-3}"
    else stamp=$(date +%s%N) || return 1;printf '%s\n' "${stamp:0:${#stamp}-6}";fi
}

usr_ops_log_line() {
    local level="${1^^}" phase="$2" message="$3" line LC_ALL=C
    case "$level" in WARN) level=WARNING;; ERR|FATAL) level=ERROR;; NOTICE) level=INFO;; esac
    message=${message//$'\r'/};message=${message//$'\n'/ | }
    printf -v line '%s | %s | %s | run=%s | phase=%s | %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$OPS_SCRIPT_ID" "${OPS_RUN_ID:-$$}" "$phase" "$message"
    if ((${#line}>4096));then line="${line:0:4050} ... [truncated]";fi
    printf '%s\n' "$line"
}

# Accept the original command, including its timeout, so producer-specific
# delivery/cooldown/acknowledgement semantics stay with the owning script.
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
    usr_ops_delivery_record "$delivery_rc" "$importance" "$summary" "$message" "${args[@]}" || printf 'Notification delivery evidence could not be queued; producer failure remains active.\n' >&2
    return "$delivery_rc"
}

# Bounded local history for scripts previously dependent on the plugin console.
usr_ops_append_log() {
    local file="$1" line="$2" max="${3:-2097152}" i
    [[ -d "${file%/*}" && ! -L "$file" ]] || return 1
    for i in 1 2;do [[ ! -L "$file.$i" ]] || return 1;done
    find "${file%/*}" -maxdepth 1 -type f \( -name "${file##*/}.1" -o -name "${file##*/}.2" \) -mtime +29 -delete || return 1
    if [[ -f "$file" ]] && (( $(stat -c %s "$file")+${#line}+1>max ));then
        rm -f "$file.2";[[ ! -f "$file.1" ]] || mv "$file.1" "$file.2";mv "$file" "$file.1" || return 1
    fi
    printf '%s\n' "$line" >>"$file"
}


# Durable failed-delivery evidence for producers without their own outbox.
# Existing media/DNS/watchdog outboxes keep ownership of their delivery policy.
usr_ops_delivery_record() (
    local rc="$1" importance="$2" summary="$3" message="$4" subject='' i key root fd tmp
    shift 4
    case "${OPS_SCRIPT_ID:-}" in backup_boot_disk|backup_cache_appdata|backup_media_remote|backup_vault_remote|backup_restore_drill|media_plex_dbrepair) ;; *) return 0;; esac
    local -a original=("$@")
    local native_delivery=false arg export_fd ram="${USR_OPS_DELIVERY_RAM_ROOT:-/run/user-script-notification-outbox}"
    for arg in "${original[@]}";do [[ "$arg" != /usr/local/emhttp/webGui/scripts/notify ]] || native_delivery=true;done
    [[ "$native_delivery" == true || -n "${USR_OPS_DELIVERY_ROOT:-}" ]] || return 0
    for ((i=0;i<${#original[@]};i++));do [[ "${original[$i]}" != -s ]] || subject="${original[$((i+1))]:-}";done
    root="${USR_OPS_DELIVERY_ROOT:-/mnt/vault/cloud/logs/script/user_scripts_status/notification-outbox}"
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}"
    if ! mountpoint -q "${USR_OPS_VAULT_MOUNT:-/mnt/vault}" || ! flock -s -n "$export_fd";then root="$ram";fi
    [[ ! -L "$root" && $(realpath -m "$root") == "$root" ]] || return 1
    mkdir -p "$root" || return 1;chmod 700 "$root" || return 1
    exec {fd}>"${USR_OPS_DELIVERY_LOCK:-/run/user-script-delivery.lock}";flock -w 3 "$fd" || return 1
    key=$(printf '%s\0' "$OPS_SCRIPT_ID" "$importance" "$subject" "$summary" "$message"|sha256sum|cut -d ' ' -f1)
    if ((rc==0));then
        if [[ "$OPS_SCRIPT_ID" == backup_vault_remote && -n "${USR_OPS_DELIVERY_CONTEXT:-}" ]];then
            mkdir -p "$root/.delivery-receipts" || return 1
            tmp=$(mktemp "$root/.delivery-receipts/.accepted.XXXXXX") || return 1
            jq -n --arg context "$USR_OPS_DELIVERY_CONTEXT" --argjson at "$(date +%s)" '{schema:1,context:$context,acceptedAt:$at}' >"$tmp" && chmod 600 "$tmp" && mv "$tmp" "$root/.delivery-receipts/backup_vault_remote.json" || return 1
        fi
        rm -f -- "$root/$OPS_SCRIPT_ID.$key.json" "$ram/$OPS_SCRIPT_ID.$key.json";return
    fi
    (( $(find "$root" -maxdepth 1 -type f -name '*.json'|wc -l)<100 )) || [[ -f "$root/$OPS_SCRIPT_ID.$key.json" ]] || return 1
    tmp=$(mktemp "$root/.delivery.XXXXXX") || return 1
    trap 'rm -f -- "$tmp"' EXIT
    jq -n --arg context "${USR_OPS_DELIVERY_CONTEXT:-}" --arg id "$key" --arg script "$OPS_SCRIPT_ID" --arg importance "$importance" --arg subject "$subject" --arg summary "$summary" --arg message "$message" --argjson at "$(date +%s)" \
      '{schema:1,context:$context,id:$id,script:$script,importance:$importance,subject:$subject,summary:$summary,message:$message,queuedAt:$at}' >"$tmp" && chmod 600 "$tmp" && mv "$tmp" "$root/$OPS_SCRIPT_ID.$key.json"
)

usr_ops_vault_delivery_seen() {
    local context="$1" cutoff="${2:-0}" root file
    [[ -n "$context" ]] || return 1
    for root in "${USR_OPS_DELIVERY_ROOT:-/mnt/vault/cloud/logs/script/user_scripts_status/notification-outbox}" "${USR_OPS_DELIVERY_RAM_ROOT:-/run/user-script-notification-outbox}";do
        file="$root/.delivery-receipts/backup_vault_remote.json"
        [[ -f "$file" && ! -L "$file" ]] || continue
        jq -e --arg context "$context" --argjson cutoff "$cutoff" --argjson now "$(date +%s)" '.schema==1 and .context==$context and .acceptedAt>=$cutoff and .acceptedAt<=$now+300' "$file" >/dev/null 2>&1 && return 0
    done
    return 1
}

usr_ops_retry_deliveries() {
    local root="${USR_OPS_DELIVERY_ROOT:-/mnt/vault/cloud/logs/script/user_scripts_status/notification-outbox}" file count=0 subject summary message importance owner old_owner="${OPS_SCRIPT_ID:-}" rc=0
    local ram="${USR_OPS_DELIVERY_RAM_ROOT:-/run/user-script-notification-outbox}" digest old_context="${USR_OPS_DELIVERY_CONTEXT:-}" context
    [[ ! -L "$root" && ! -L "$ram" ]] || return 1
    [[ -d "$root" || -d "$ram" ]] || return 0
    while IFS= read -r -d '' file;do
        ((count<3)) || break
        jq -e '(.schema==1) and (.script|test("^(backup_(boot_disk|cache_appdata|media_remote|vault_remote|restore_drill)|media_plex_dbrepair)$")) and (.importance|IN("normal","warning","alert")) and all(.subject,.summary,.message;type=="string")' "$file" >/dev/null 2>&1 || continue
        owner=$(jq -r .script "$file");subject=$(jq -r .subject "$file");summary=$(jq -r .summary "$file");message=$(jq -r .message "$file");importance=$(jq -r .importance "$file")
        context=$(jq -r '.context // ""' "$file")
        if [[ "$owner" == backup_vault_remote ]] && usr_ops_vault_delivery_seen "$context" "$(jq -r .queuedAt "$file")";then rm -f -- "$file";continue;fi
        USR_OPS_DELIVERY_CONTEXT="$context"
        digest=$(sha256sum "$file"|cut -d ' ' -f1)
        OPS_SCRIPT_ID="$owner";count=$((count+1))
        if usr_ops_notify "${NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify}" -i "$importance" -s "$subject" -d "$summary" -m "$message";then
            if [[ -f "$file" && $(sha256sum "$file"|cut -d ' ' -f1) == "$digest" ]];then rm -f -- "$file";fi
        else rc=1;fi
        OPS_SCRIPT_ID="$old_owner";USR_OPS_DELIVERY_CONTEXT="$old_context"
    done < <(find "$root" "$ram" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null|sort -zu)
    return "$rc"
}

# Scheduled executions have an independent parent recording the final exit,
# after producer EXIT traps. CLI operations and sourced libraries are unchanged.
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

# Network observation after an accepted shutdown, never a power-state claim.
# No WOL or second poweroff is issued. Native maintenance checks remain upstream.
usr_ops_observe_shutdown() {
    local BACKUP_SSH_COMMAND_TIMEOUT=6
    local host="${REMOTE#*@}" deadline=$(( $(date +%s)+${REMOTE_SHUTDOWN_OBSERVE_SECONDS:-90} )) misses=0
    [[ "${REMOTE_SHUTDOWN_OBSERVE_SECONDS:-90}" != 0 ]] || { SHUTDOWN_RESULT=requested_observation_disabled;return 0; }
    while (( $(date +%s)<deadline ));do
        if timeout --kill-after=1 5 ping -c 1 -W 2 "$host" >/dev/null 2>&1 || backup_ssh true >/dev/null 2>&1;then misses=0
        else misses=$((misses+1));fi
        if ((misses>=3));then SHUTDOWN_RESULT=offline_observed;return 0;fi
        sleep 5
    done
    SHUTDOWN_RESULT=requested_still_reachable;REMOTE_SHUTDOWN_FAILED=1
    return 1
}
# END EMBEDDED OPERATIONS CONTRACT
# BEGIN SCHEDULED EXECUTION SUPERVISOR
if [[ "${BASH_SOURCE[0]}" == "$0" && $# == 0 && "${USR_OPS_SUPERVISED:-}" != "$OPS_SCRIPT_ID" ]];then
    usr_ops_supervise "$0";exit $?
fi
# END SCHEDULED EXECUTION SUPERVISOR
set -uo pipefail
readonly SCRIPT_VERSION="1.6.0"


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
NOTIFY_SUBJECT="Syslog Watchdog"

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
    if mountpoint -q "${SYSLOG_VAULT_MOUNT:-/mnt/vault}";then root="${SYSLOG_INCIDENT_ROOT:-/mnt/vault/cloud/logs/script/syslog_watchdog}";fi
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
Incident JSON: ${SYSLOG_INCIDENT_ROOT:-/mnt/vault/cloud/logs/script/syslog_watchdog}/incidents.json
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

    critical=$(grep -Eic "${CRITICAL_REGEX}|${STORAGE_MATCH_REGEX}" "$match_file" || true)
    (( critical==0 )) || importance=alert
    body+="Incident JSON: ${SYSLOG_INCIDENT_ROOT:-/mnt/vault/cloud/logs/script/syslog_watchdog}/incidents.json (new matches recorded automatically; critical incidents require review)"$'\n'
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

    if ! syslog_critical_tail;then final_exit=1;fi
    if ! check_log_usage; then
        final_exit=1
    fi


    # -----------------------------------------------------------------------
    # Exit status
    # -----------------------------------------------------------------------

    if ((final_exit==0)) && mountpoint -q /mnt/vault;then
        local receipt_root="${STATUS_DIR:-/mnt/vault/cloud/logs/script/user_scripts_status}" receipt
        mkdir -p "$receipt_root" || return 1
        receipt=$(mktemp "$receipt_root/.syslog-watchdog.XXXXXX") || return 1
        jq -n --arg boot "$(cat /proc/sys/kernel/random/boot_id)" --argjson at "$(date +%s)" '{schema:1,name:"syslog_watchdog",bootId:$boot,lastSuccessfulScanAt:$at,epoch:$at,status:"OK",scope:"New syslog entries and log filesystem utilization checked; notification delivery completed"}' >"$receipt" && chmod 600 "$receipt" && mv "$receipt" "$receipt_root/syslog_watchdog.json" || return 1
    fi
    [[ "${SYSLOG_BACKLOG:-false}" != true ]] || log SYSLOG INFO 'Bounded scan completed with unread backlog; next scheduled pass resumes from the last consumed line'
    return "$final_exit"
}


###############################################################################
# ENTRY POINT
###############################################################################

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
