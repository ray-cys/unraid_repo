#!/bin/bash
# Release version: bump for every deployed code change; descriptions stay user-owned.
readonly SCRIPT_VERSION="3.3.3"
# Version lookup exits before logging, locks, state, Docker or network activity.
if [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" == --version ]]; then
    printf 'backup_boot_disk.sh %s\n' "$SCRIPT_VERSION"
    exit 0
fi
clearLog=true

###############################################################################
# Unraid Boot Device Backup v3.3.3
#
# Designed for Unraid 7.4+ while remaining resilient to future changes in the
# private WebGUI backup helper.
#
# BACKENDS
# --------
#   auto    Prefer the native streaming helper when its current capabilities
#           are detected. Fall back to a direct /boot ZIP when the helper is
#           missing, incompatible, times out, or produces an invalid archive.
#   native  Require the native streaming helper and never fall back.
#   direct  Build the ZIP directly from the boot device.
#
# Every backend uses the same safety gates: destination mount validation,
# timeout protection, full ZIP verification, archive-path validation, minimum
# content checks, SHA-256 sidecar creation, atomic publication, and retention
# only after the new generation and persistent state are complete.
###############################################################################

# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="backup_boot_disk"
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


###############################################################################
# CONFIGURATION
###############################################################################

BACKUP_DIR="${BACKUP_DIR:-/mnt/vault/backup/flash}"
POOL_PATH="${POOL_PATH:-/mnt/vault}"
BOOT_SOURCE="${BOOT_SOURCE:-/boot}"

# auto, native, or direct
BACKUP_BACKEND="${BACKUP_BACKEND:-auto}"

MAX_BACKUPS="${MAX_BACKUPS:-2}"
COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-6}"
MIN_ARCHIVE_FILES="${MIN_ARCHIVE_FILES:-10}"

SIZE_TIMEOUT_SECONDS="${SIZE_TIMEOUT_SECONDS:-300}"
BACKUP_TIMEOUT_SECONDS="${BACKUP_TIMEOUT_SECONDS:-3600}"

HELPER="${HELPER:-/usr/local/emhttp/webGui/scripts/flash_backup}"
NOTIFY="${NOTIFY:-/usr/local/emhttp/webGui/scripts/notify}"
TIMEOUT_BIN="${TIMEOUT_BIN:-timeout}"

LOCKFILE="${LOCKFILE:-/tmp/backup_boot_disk.lock}"

LOG_DIR="${LOG_DIR:-/mnt/user/cloud/logs/script/backup_boot_disk}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/backup_boot_disk.log}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-$((256 * 1024))}"
LOG_KEEP="${LOG_KEEP:-1}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
LOG_LINE_MAX_BYTES="${LOG_LINE_MAX_BYTES:-4096}"
LOG_RUNAWAY_MULTIPLIER="${LOG_RUNAWAY_MULTIPLIER:-4}"

# Backend stderr is drained completely so the helper cannot block, but only a
# small prefix is retained for failure diagnosis. This is especially important
# on Unraid because /tmp is RAM-backed and a misbehaving helper may emit binary
# or archive-sized data on stderr.
BACKEND_DIAGNOSTIC_MAX_BYTES="${BACKEND_DIAGNOSTIC_MAX_BYTES:-$((64 * 1024))}"
BACKEND_DIAGNOSTIC_MAX_LINES="${BACKEND_DIAGNOSTIC_MAX_LINES:-100}"

STATE_FILE="${STATE_FILE:-${BACKUP_DIR}/.backup_boot_disk_state.json}"

RECOMMENDED_ARCHIVE_PATHS=(
    "config/super.dat"
    "config/ident.cfg"
)

###############################################################################
# RUNTIME STATE
###############################################################################

START_TIME=$(date +%s)

HELPER_LOG=""
HELPER_LOG_META=""
HELPER_LOGGED_MARKER=""
DIAGNOSTIC_FIFO=""
DIAGNOSTIC_CAPTURE_PID=""
ARCHIVE_LIST_FILE=""
TEMP_FILE=""
TEMP_CHECKSUM=""
WRITE_TEST=""

LOG_READY=false
LOG_FAILURE_REPORTED=false
LOG_CLEANED_FILES=0
LOG_CLEANED_BYTES=0

SELECTED_BACKEND=""
ESTIMATED_SOURCE_BYTES=0
GENERATED_SIZE=0
ARCHIVE_FILE_COUNT=0
ARCHIVE_SHA256=""
ARCHIVE_WARNING_TEXT=""
BACKEND_FAILURE_REASON=""
NATIVE_FAILURE_REASON=""

FALLBACK_USED=false
PLATFORM_CHANGE_DETECTED=false
PLATFORM_CHANGE_SUMMARY=""

SERVER_NAME=""
OS_VERSION=""
SERVER_SLUG=""
VERSION_SLUG=""
HELPER_SHA256="missing"

BACKUP_NAME=""
BACKUP_FILE=""
CHECKSUM_FILE=""

DIRECT_ITEMS=()
ARCHIVE_WARNINGS=()
PLATFORM_CHANGES=()

###############################################################################
# GENERAL HELPERS
###############################################################################

log() {
    local message="$*" line

    if [[ "$LOG_LINE_MAX_BYTES" =~ ^[0-9]+$ ]] &&
       (( LOG_LINE_MAX_BYTES > 0 )) &&
       (( ${#message} > LOG_LINE_MAX_BYTES ))
    then
        message="${message:0:LOG_LINE_MAX_BYTES} ... [line truncated]"
    fi

    local level=INFO;case "$message" in ERROR:*|*"[ERROR]"*) level=ERROR;;WARNING:*|WARN:*) level=WARNING;;esac
    line=$(usr_ops_log_line "$level" MAIN "$message")
    printf '%s\n' "$line"

    if [ "$LOG_READY" = true ]; then
        if ! append_persistent_log "$line"; then
            LOG_READY=false
            if [ "$LOG_FAILURE_REPORTED" = false ]; then
                LOG_FAILURE_REPORTED=true
                printf '%s : WARNING: Persistent log became unavailable: %s\n' \
                    "$(date '+%Y/%m/%d %T')" "$LOG_FILE" >&2
            fi
        fi
    fi
}

append_persistent_log() {
    local line="$1" current_size line_size

    current_size=$(stat -c '%s' "$LOG_FILE" 2>/dev/null || echo 0)
    line_size=$(printf '%s\n' "$line" | wc -c | tr -d ' ')
    [[ "$current_size" =~ ^[0-9]+$ ]] || current_size=0
    [[ "$line_size" =~ ^[0-9]+$ ]] || line_size=0

    if (( current_size > 0 && current_size + line_size > LOG_MAX_BYTES )); then
        rotate_logs || return 1
        : >>"$LOG_FILE" || return 1
    fi

    printf '%s\n' "$line" >>"$LOG_FILE"
}

rotate_logs() {
    [ -f "$LOG_FILE" ] || return 0

    local size i
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
            mv -f -- "${LOG_FILE}.${i}" \
                "${LOG_FILE}.$((i + 1))" || return 1
        fi
    done
    mv -f -- "$LOG_FILE" "${LOG_FILE}.1"
}

record_removed_log() {
    local file="$1" size
    size=$(stat -c '%s' "$file" 2>/dev/null || echo 0)
    [[ "$size" =~ ^[0-9]+$ ]] || size=0

    if rm -f -- "$file"; then
        ((LOG_CLEANED_FILES++)) || true
        ((LOG_CLEANED_BYTES+=size)) || true
        return 0
    fi

    return 1
}

cleanup_existing_logs() {
    local file suffix size modified now cutoff runaway_limit

    now=$(date +%s)
    cutoff=$((now - LOG_RETENTION_DAYS * 86400))
    runaway_limit=$((LOG_MAX_BYTES * LOG_RUNAWAY_MULTIPLIER))

    if [ -f "$LOG_FILE" ]; then
        size=$(stat -c '%s' "$LOG_FILE" 2>/dev/null || echo 0)
        [[ "$size" =~ ^[0-9]+$ ]] || size=0

        if (( size > runaway_limit )); then
            if : >"$LOG_FILE"; then
                ((LOG_CLEANED_FILES++)) || true
                ((LOG_CLEANED_BYTES+=size)) || true
            fi
        fi
    fi

    shopt -s nullglob
    for file in "${LOG_FILE}".*; do
        [ -f "$file" ] || continue
        suffix=${file##*.}
        [[ "$suffix" =~ ^[0-9]+$ ]] || continue

        size=$(stat -c '%s' "$file" 2>/dev/null || echo 0)
        modified=$(stat -c '%Y' "$file" 2>/dev/null || echo 0)
        [[ "$size" =~ ^[0-9]+$ ]] || size=0
        [[ "$modified" =~ ^[0-9]+$ ]] || modified=0

        if (( suffix > LOG_KEEP ||
              size > runaway_limit ||
              (LOG_RETENTION_DAYS > 0 && modified > 0 && modified <= cutoff) ));
        then
            record_removed_log "$file" || true
        fi
    done
    shopt -u nullglob
}

initialize_logging() {
    local rotation_ok=true

    if ! [[ "$LOG_MAX_BYTES" =~ ^[0-9]+$ ]] ||
       ! [[ "$LOG_KEEP" =~ ^[0-9]+$ ]] ||
       ! [[ "$LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]] ||
       ! [[ "$LOG_LINE_MAX_BYTES" =~ ^[0-9]+$ ]] ||
       ! [[ "$LOG_RUNAWAY_MULTIPLIER" =~ ^[0-9]+$ ]] ||
       (( LOG_MAX_BYTES <= 0 || LOG_LINE_MAX_BYTES <= 0 ||
          LOG_RUNAWAY_MULTIPLIER < 2 ))
    then
        log "WARNING: Invalid log rotation configuration; persistent logging disabled"
        return 0
    fi

    if ! mkdir -p -- "$LOG_DIR" 2>/dev/null; then
        log "WARNING: Persistent log directory unavailable: $LOG_DIR"
        return 0
    fi

    cleanup_existing_logs
    rotate_logs || rotation_ok=false
    if ! : >>"$LOG_FILE"; then
        log "WARNING: Persistent log is not writable: $LOG_FILE"
        return 0
    fi

    LOG_READY=true
    [ "$rotation_ok" = true ] || \
        log "WARNING: Log rotation failed; continuing with the current log"
    log "Persistent log: $LOG_FILE"

    if (( LOG_CLEANED_FILES > 0 )); then
        log "Removed ${LOG_CLEANED_FILES} oversized, expired, or obsolete log file(s); reclaimed $(bytes_human "$LOG_CLEANED_BYTES")"
    fi
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
    local importance="$1" description="$2" message="$3"

    if [ "$LOG_READY" = true ]; then
        message+=$'\n\n'"Log: $LOG_FILE"
    else
        message+=$'\n\n'"Persistent log unavailable; see the User Scripts output."
    fi

    if [ ! -x "$NOTIFY" ]; then
        log "WARNING: Unraid notify command not found"
        return 0
    fi

    usr_ops_notify "$NOTIFY" -i "$importance" -s "Backup Boot Disk" \
        -d "$description" -m "$message" >/dev/null 2>&1 || \
        log "WARNING: Notification command failed"
}

# shellcheck disable=SC2329
cleanup() {
    local exit_code=$? file
    trap - EXIT

    if [ -n "$DIAGNOSTIC_CAPTURE_PID" ] &&
       kill -0 "$DIAGNOSTIC_CAPTURE_PID" 2>/dev/null;
    then
        kill "$DIAGNOSTIC_CAPTURE_PID" 2>/dev/null || true
        wait "$DIAGNOSTIC_CAPTURE_PID" 2>/dev/null || true
    fi
    DIAGNOSTIC_CAPTURE_PID=""

    [ -z "$DIAGNOSTIC_FIFO" ] || rm -f -- "$DIAGNOSTIC_FIFO" 2>/dev/null || true

    for file in \
        "$HELPER_LOG" \
        "$HELPER_LOG_META" \
        "$HELPER_LOGGED_MARKER" \
        "$ARCHIVE_LIST_FILE" \
        "$TEMP_FILE" \
        "$TEMP_CHECKSUM" \
        "$WRITE_TEST"
    do
        [ -n "$file" ] || continue
        [ -e "$file" ] || continue
        rm -f -- "$file" || \
            log "WARNING: Unable to remove temporary file: $file"
    done

    return "$exit_code"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        log "ERROR: Required command not found: $1"
        return 1
    }
}

run_with_timeout() {
    local seconds="$1"
    shift
    "$TIMEOUT_BIN" --signal=TERM --kill-after=30s "${seconds}s" "$@"
}

capture_bounded_diagnostics() {
    local output_file="$1" meta_file="$2" limit="$3"
    local captured limit_reached=false

    # head retains only the bounded prefix. cat continues draining the pipe so
    # a noisy helper cannot block or receive SIGPIPE after the limit is reached.
    head -c "$limit" >"$output_file" 2>/dev/null || true
    cat >/dev/null 2>&1 || true

    captured=$(stat -c '%s' "$output_file" 2>/dev/null || echo 0)
    [[ "$captured" =~ ^[0-9]+$ ]] || captured=0
    (( captured >= limit )) && limit_reached=true

    printf '%s\t%s\n' "$captured" "$limit_reached" >"$meta_file"
}

start_diagnostic_capture() {
    DIAGNOSTIC_FIFO="${HELPER_LOG}.fifo.$$.$RANDOM"
    rm -f -- "$DIAGNOSTIC_FIFO" "$HELPER_LOG_META" \
        "$HELPER_LOGGED_MARKER" 2>/dev/null || true
    : >"$HELPER_LOG" || return 1
    mkfifo "$DIAGNOSTIC_FIFO" || return 1

    capture_bounded_diagnostics \
        "$HELPER_LOG" \
        "$HELPER_LOG_META" \
        "$BACKEND_DIAGNOSTIC_MAX_BYTES" \
        <"$DIAGNOSTIC_FIFO" &
    DIAGNOSTIC_CAPTURE_PID=$!
}

finish_diagnostic_capture() {
    local capture_rc=0

    if [ -n "$DIAGNOSTIC_CAPTURE_PID" ]; then
        wait "$DIAGNOSTIC_CAPTURE_PID" || capture_rc=$?
    fi

    DIAGNOSTIC_CAPTURE_PID=""
    rm -f -- "$DIAGNOSTIC_FIFO" 2>/dev/null || true
    DIAGNOSTIC_FIFO=""
    return "$capture_rc"
}

run_with_bounded_diagnostics() {
    local rc

    if ! start_diagnostic_capture; then
        : >"$HELPER_LOG" 2>/dev/null || true
        printf 'Backend diagnostic capture could not be initialized.\n' \
            >"$HELPER_LOG" 2>/dev/null || true
        "$@" 2>/dev/null
        return $?
    fi

    "$@" 2>"$DIAGNOSTIC_FIFO"
    rc=$?
    finish_diagnostic_capture || true
    return "$rc"
}

log_helper_diagnostics() {
    local captured=0 limit_reached=false total_lines=0 shown=0 line

    [ -e "$HELPER_LOGGED_MARKER" ] && return 0
    [ -s "$HELPER_LOG" ] || return 0

    : >"$HELPER_LOGGED_MARKER" 2>/dev/null || true

    if [ -s "$HELPER_LOG_META" ]; then
        IFS=$'\t' read -r captured limit_reached <"$HELPER_LOG_META" || true
    fi
    [[ "$captured" =~ ^[0-9]+$ ]] || \
        captured=$(stat -c '%s' "$HELPER_LOG" 2>/dev/null || echo 0)

    if ! LC_ALL=C grep -Iq '' "$HELPER_LOG"; then
        log "Backend diagnostics omitted because the captured output is binary (${captured} bytes retained)"
        [ "$limit_reached" != true ] || \
            log "Backend diagnostic output reached the ${BACKEND_DIAGNOSTIC_MAX_BYTES}-byte capture limit; additional data was discarded"
        return 0
    fi

    total_lines=$(awk 'END {print NR+0}' "$HELPER_LOG" 2>/dev/null || echo 0)
    [[ "$total_lines" =~ ^[0-9]+$ ]] || total_lines=0

    log "Backend diagnostics follow (bounded excerpt):"
    while IFS= read -r line || [ -n "$line" ]; do
        ((shown++)) || true
        log "BACKEND: $line"
        (( shown >= BACKEND_DIAGNOSTIC_MAX_LINES )) && break
    done < <(LC_ALL=C tr -cd '\11\12\15\40-\176' <"$HELPER_LOG")

    if [ "$limit_reached" = true ] || (( total_lines > shown )); then
        log "Backend diagnostics truncated after ${shown} line(s) and ${captured} captured byte(s)"
    fi
}

read_unraid_value() {
    local key="$1" fallback="$2" value
    value=$(
        awk -v wanted="$key" '
            {
                separator = index($0, "=")
                if (separator <= 1) next
                name = substr($0, 1, separator - 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
                if (name != wanted) next
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
        sed -E 's/[^a-z0-9._-]+/_/g; s/^[_ .-]+//; s/[_ .-]+$//'
}

available_bytes() {
    local value
    value=$(
        df -B1 --output=avail "$BACKUP_DIR" 2>/dev/null |
        tail -n 1 | tr -d ' '
    )
    [[ "$value" =~ ^[0-9]+$ ]] && printf '%s' "$value" || printf '0'
}

join_array() {
    local separator="$1"
    shift
    local result="" value
    for value in "$@"; do
        [ -n "$result" ] && result+="$separator"
        result+="$value"
    done
    printf '%s' "$result"
}

###############################################################################
# PLATFORM AND STATE
###############################################################################

initialize_identity() {
    local host_fallback
    host_fallback=$(hostname -s 2>/dev/null || printf 'tower')
    SERVER_NAME=$(read_unraid_value "NAME" "$host_fallback")
    OS_VERSION=$(read_unraid_value "version" "unknown")
    SERVER_SLUG=$(filename_component "$SERVER_NAME")
    VERSION_SLUG=$(filename_component "$OS_VERSION")
    [ -n "$SERVER_SLUG" ] || SERVER_SLUG="tower"
    [ -n "$VERSION_SLUG" ] || VERSION_SLUG="unknown"

    if [ -f "$HELPER" ]; then
        HELPER_SHA256=$(sha256sum "$HELPER" 2>/dev/null | awk '{print $1}')
        [ -n "$HELPER_SHA256" ] || HELPER_SHA256="unreadable"
    fi
}

detect_platform_changes() {
    [ -f "$STATE_FILE" ] || return 0

    if ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
        PLATFORM_CHANGE_DETECTED=true
        PLATFORM_CHANGES+=("previous state file is unreadable")
        PLATFORM_CHANGE_SUMMARY=$(join_array "; " "${PLATFORM_CHANGES[@]}")
        return 0
    fi

    local old_version old_helper_hash
    old_version=$(jq -r '.unraidVersion // ""' "$STATE_FILE")
    old_helper_hash=$(jq -r '.helperSha256 // ""' "$STATE_FILE")

    if [ -n "$old_version" ] && [ "$old_version" != "$OS_VERSION" ]; then
        PLATFORM_CHANGES+=("Unraid ${old_version} -> ${OS_VERSION}")
    fi
    if [ -n "$old_helper_hash" ] && [ "$old_helper_hash" != "$HELPER_SHA256" ]; then
        PLATFORM_CHANGES+=("native helper changed")
    fi

    if (( ${#PLATFORM_CHANGES[@]} > 0 )); then
        PLATFORM_CHANGE_DETECTED=true
        PLATFORM_CHANGE_SUMMARY=$(join_array "; " "${PLATFORM_CHANGES[@]}")
        log "Platform change detected: $PLATFORM_CHANGE_SUMMARY"
        log "Full integrity and archive-content validation will be required"
    fi
}

write_state() {
    local now tmp
    now=$(date +%s)
    tmp="${STATE_FILE}.tmp.$$"

    if ! jq -n \
        --argjson schemaVersion 1 \
        --arg scriptVersion "$SCRIPT_VERSION" \
        --arg unraidVersion "$OS_VERSION" \
        --arg helperPath "$HELPER" \
        --arg helperSha256 "$HELPER_SHA256" \
        --arg backend "$SELECTED_BACKEND" \
        --argjson fallbackUsed "$FALLBACK_USED" \
        --arg backupFile "$BACKUP_FILE" \
        --arg archiveSha256 "$ARCHIVE_SHA256" \
        --arg archiveWarnings "$ARCHIVE_WARNING_TEXT" \
        --arg platformChange "$PLATFORM_CHANGE_SUMMARY" \
        --argjson archiveBytes "$GENERATED_SIZE" \
        --argjson archiveFiles "$ARCHIVE_FILE_COUNT" \
        --argjson successfulAt "$now" \
        '{
            schemaVersion: $schemaVersion,
            scriptVersion: $scriptVersion,
            unraidVersion: $unraidVersion,
            helperPath: $helperPath,
            helperSha256: $helperSha256,
            backend: $backend,
            fallbackUsed: $fallbackUsed,
            backupFile: $backupFile,
            archiveSha256: $archiveSha256,
            archiveBytes: $archiveBytes,
            archiveFiles: $archiveFiles,
            archiveWarnings: $archiveWarnings,
            platformChange: $platformChange,
            successfulAt: $successfulAt
        }' >"$tmp"
    then
        rm -f -- "$tmp"
        return 1
    fi

    chmod 0644 "$tmp" 2>/dev/null || true
    if ! mv -f -- "$tmp" "$STATE_FILE"; then
        rm -f -- "$tmp"
        return 1
    fi
}

###############################################################################
# BACKEND CAPABILITY AND GENERATION
###############################################################################

native_size_estimate() {
    local output rc
    [ -x "$HELPER" ] || {
        NATIVE_FAILURE_REASON="native helper is missing or not executable"
        return 1
    }

    output=$(run_with_bounded_diagnostics \
        run_with_timeout "$SIZE_TIMEOUT_SECONDS" \
        "$HELPER" size)
    rc=$?
    output=${output//[[:space:]]/}

    if (( rc == 124 || rc == 137 )); then
        NATIVE_FAILURE_REASON="native size query timed out"
        return 1
    fi
    if (( rc != 0 )); then
        NATIVE_FAILURE_REASON="native size query failed with exit code $rc"
        return 1
    fi
    if ! [[ "$output" =~ ^[0-9]+$ ]] || (( output <= 0 )); then
        NATIVE_FAILURE_REASON="native helper does not support a numeric size query"
        return 1
    fi

    ESTIMATED_SOURCE_BYTES="$output"
    return 0
}

build_direct_items() {
    local path base
    DIRECT_ITEMS=()

    [ -d "$BOOT_SOURCE" ] && [ -r "$BOOT_SOURCE" ] || {
        BACKEND_FAILURE_REASON="boot source is unavailable: $BOOT_SOURCE"
        return 1
    }

    shopt -s nullglob dotglob
    for path in "$BOOT_SOURCE"/*; do
        base=${path##*/}
        case "$base" in
            prev|previous|System\ Volume\ Information|.Trash-0|.Trashes|\
            .Spotlight-V100|.fseventsd|.TemporaryItems)
                continue
                ;;
            *-boot-backup-*.zip|*-flash-backup-*.zip)
                continue
                ;;
        esac
        DIRECT_ITEMS+=("./$base")
    done
    shopt -u dotglob

    if (( ${#DIRECT_ITEMS[@]} == 0 )); then
        BACKEND_FAILURE_REASON="boot source contains no eligible backup content"
        return 1
    fi
}

direct_size_estimate() {
    local output rc
    build_direct_items || return 1
    require_command zip || {
        BACKEND_FAILURE_REASON="zip is unavailable for the direct backend"
        return 1
    }
    require_command du || {
        BACKEND_FAILURE_REASON="du is unavailable for the direct backend"
        return 1
    }

    output=$(
        cd "$BOOT_SOURCE" || exit 1
        run_with_bounded_diagnostics \
            run_with_timeout "$SIZE_TIMEOUT_SECONDS" \
            du -sbc "${DIRECT_ITEMS[@]}" |
            awk 'END {print $1}'
    )
    rc=$?
    output=${output//[[:space:]]/}

    if (( rc == 124 || rc == 137 )); then
        BACKEND_FAILURE_REASON="direct size query timed out"
        return 1
    fi
    if (( rc != 0 )) || ! [[ "$output" =~ ^[0-9]+$ ]] || (( output <= 0 )); then
        BACKEND_FAILURE_REASON="direct backend could not calculate source size"
        return 1
    fi

    ESTIMATED_SOURCE_BYTES="$output"
    return 0
}

select_backend() {
    case "$BACKUP_BACKEND" in
        native)
            native_size_estimate || {
                BACKEND_FAILURE_REASON="$NATIVE_FAILURE_REASON"
                return 1
            }
            SELECTED_BACKEND="native"
            ;;

        direct)
            direct_size_estimate || return 1
            SELECTED_BACKEND="direct"
            ;;

        auto)
            if native_size_estimate; then
                SELECTED_BACKEND="native"
            else
                FALLBACK_USED=true
                log "WARNING: $NATIVE_FAILURE_REASON"
                log "Switching to the self-contained direct ZIP backend"
                log_helper_diagnostics
                direct_size_estimate || return 1
                SELECTED_BACKEND="direct"
            fi
            ;;

        *)
            BACKEND_FAILURE_REASON="BACKUP_BACKEND must be auto, native, or direct"
            return 1
            ;;
    esac
}

create_native_archive() {
    local rc
    run_with_bounded_diagnostics \
        run_with_timeout "$BACKUP_TIMEOUT_SECONDS" \
        "$HELPER" "$COMPRESSION_LEVEL" \
        >"$TEMP_FILE"
    rc=$?

    if (( rc == 124 || rc == 137 )); then
        BACKEND_FAILURE_REASON="native backup generation timed out"
        return 1
    fi
    if (( rc != 0 )); then
        BACKEND_FAILURE_REASON="native helper exited with code $rc"
        return 1
    fi
}

create_direct_archive() {
    local rc
    local -a zip_command=(
        zip "-${COMPRESSION_LEVEL}" -qr - "${DIRECT_ITEMS[@]}"
    )

    if command -v ionice >/dev/null 2>&1; then
        zip_command=(ionice -c2 -n7 "${zip_command[@]}")
    fi
    if command -v nice >/dev/null 2>&1; then
        zip_command=(nice -n 19 "${zip_command[@]}")
    fi

    (
        cd "$BOOT_SOURCE" || exit 1
        run_with_bounded_diagnostics \
            run_with_timeout "$BACKUP_TIMEOUT_SECONDS" "${zip_command[@]}"
    ) >"$TEMP_FILE"
    rc=$?

    if (( rc == 124 || rc == 137 )); then
        BACKEND_FAILURE_REASON="direct backup generation timed out"
        return 1
    fi
    if (( rc != 0 )); then
        BACKEND_FAILURE_REASON="direct ZIP backend exited with code $rc"
        return 1
    fi
}

create_selected_archive() {
    case "$SELECTED_BACKEND" in
        native) create_native_archive ;;
        direct) create_direct_archive ;;
        *)
            BACKEND_FAILURE_REASON="no backup backend was selected"
            return 1
            ;;
    esac
}

###############################################################################
# ARCHIVE VALIDATION
###############################################################################

archive_has_path() {
    local wanted="$1"
    awk -v wanted="$wanted" '
        {
            value=$0
            sub(/^\.\//, "", value)
            sub(/\/$/, "", value)
            if (value == wanted) found=1
        }
        END { exit(found ? 0 : 1) }
    ' "$ARCHIVE_LIST_FILE"
}

validate_archive() {
    local file="$1" recommended
    ARCHIVE_WARNINGS=()
    ARCHIVE_WARNING_TEXT=""

    [ -s "$file" ] || {
        BACKEND_FAILURE_REASON="$SELECTED_BACKEND backend produced an empty archive"
        return 1
    }

    if ! unzip -tq "$file" >/dev/null 2>&1; then
        BACKEND_FAILURE_REASON="$SELECTED_BACKEND backend produced an invalid ZIP"
        return 1
    fi

    if ! run_with_bounded_diagnostics \
        unzip -Z1 "$file" >"$ARCHIVE_LIST_FILE";
    then
        BACKEND_FAILURE_REASON="unable to list the generated ZIP"
        return 1
    fi

    if ! awk '
        {
            path=$0
            gsub(/\\/, "/", path)
            if (path ~ /^\// || path ~ /^[A-Za-z]:\// ||
                path ~ /(^|\/)\.\.(\/|$)/) bad=1
        }
        END { exit(bad ? 1 : 0) }
    ' "$ARCHIVE_LIST_FILE"
    then
        BACKEND_FAILURE_REASON="generated ZIP contains an unsafe path"
        return 1
    fi

    ARCHIVE_FILE_COUNT=$(
        awk 'substr($0, length($0), 1) != "/" {count++}
             END {print count+0}' "$ARCHIVE_LIST_FILE"
    )
    if ! [[ "$ARCHIVE_FILE_COUNT" =~ ^[0-9]+$ ]] ||
       (( ARCHIVE_FILE_COUNT < MIN_ARCHIVE_FILES ))
    then
        BACKEND_FAILURE_REASON="generated ZIP contains only ${ARCHIVE_FILE_COUNT:-0} files; minimum is $MIN_ARCHIVE_FILES"
        return 1
    fi

    if ! awk '
        {
            path=$0
            sub(/^\.\//, "", path)
            if (path == "config" || path ~ /^config\//) found=1
        }
        END {exit(found ? 0 : 1)}
    ' "$ARCHIVE_LIST_FILE"
    then
        BACKEND_FAILURE_REASON="generated ZIP does not contain the config tree"
        return 1
    fi

    for recommended in "${RECOMMENDED_ARCHIVE_PATHS[@]}"; do
        archive_has_path "$recommended" || \
            ARCHIVE_WARNINGS+=("missing recommended path: $recommended")
    done

    if ! awk '
        {
            path=$0
            sub(/^\.\//, "", path)
            if (path ~ /^config\/[^/]+\.key$/) found=1
        }
        END {exit(found ? 0 : 1)}
    ' "$ARCHIVE_LIST_FILE"
    then
        ARCHIVE_WARNINGS+=("no config/*.key license file found; this can be normal with TPM or internal-boot licensing")
    fi

    if (( ${#ARCHIVE_WARNINGS[@]} > 0 )); then
        ARCHIVE_WARNING_TEXT=$(join_array "; " "${ARCHIVE_WARNINGS[@]}")
        log "Archive content warning: $ARCHIVE_WARNING_TEXT"
    fi

    GENERATED_SIZE=$(stat -c '%s' "$file" 2>/dev/null || echo 0)
    if ! [[ "$GENERATED_SIZE" =~ ^[0-9]+$ ]] || (( GENERATED_SIZE <= 0 )); then
        BACKEND_FAILURE_REASON="unable to read generated archive size"
        return 1
    fi

    ARCHIVE_SHA256=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
    [[ "$ARCHIVE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || {
        BACKEND_FAILURE_REASON="unable to calculate archive SHA-256"
        return 1
    }

    log "Archive integrity and content validation passed"
    log "Archive files: $ARCHIVE_FILE_COUNT"
    log "Archive SHA-256: $ARCHIVE_SHA256"
}

check_destination_space() {
    local available required
    available=$(available_bytes)
    required=$((
        ESTIMATED_SOURCE_BYTES +
        ESTIMATED_SOURCE_BYTES / 10 +
        1048576
    ))

    log "Estimated source content: $(bytes_human "$ESTIMATED_SOURCE_BYTES")"
    log "Destination free space: $(bytes_human "$available")"
    log "Conservative required space: $(bytes_human "$required")"

    if (( available < required )); then
        BACKEND_FAILURE_REASON="insufficient destination space: required $(bytes_human "$required"), available $(bytes_human "$available")"
        return 1
    fi
}

generate_with_fallback() {
    log "Selected backend: $SELECTED_BACKEND"
    check_destination_space || return 1

    rm -f -- "$TEMP_FILE"
    if create_selected_archive && validate_archive "$TEMP_FILE"; then
        return 0
    fi

    log "WARNING: $BACKEND_FAILURE_REASON"
    log_helper_diagnostics

    if [ "$BACKUP_BACKEND" != "auto" ] || [ "$SELECTED_BACKEND" != "native" ]; then
        return 1
    fi

    NATIVE_FAILURE_REASON="$BACKEND_FAILURE_REASON"
    FALLBACK_USED=true
    rm -f -- "$TEMP_FILE"

    log "Retrying with the self-contained direct ZIP backend"
    direct_size_estimate || return 1
    SELECTED_BACKEND="direct"
    check_destination_space || return 1

    if ! create_direct_archive || ! validate_archive "$TEMP_FILE"; then
        return 1
    fi

    return 0
}

###############################################################################
# FINALIZATION AND RETENTION
###############################################################################

prepare_checksum_sidecar() {
    TEMP_CHECKSUM="$BACKUP_DIR/.${BACKUP_NAME}.sha256.tmp.$$"
    printf '%s  %s\n' "$ARCHIVE_SHA256" "$BACKUP_NAME" \
        >"$TEMP_CHECKSUM" || return 1
    chmod 0644 "$TEMP_CHECKSUM" 2>/dev/null || true
}

finalize_backup() {
    prepare_checksum_sidecar || {
        BACKEND_FAILURE_REASON="unable to prepare SHA-256 sidecar"
        return 1
    }

    if ! mv -f -- "$TEMP_FILE" "$BACKUP_FILE"; then
        BACKEND_FAILURE_REASON="unable to atomically publish the backup ZIP"
        return 1
    fi
    TEMP_FILE=""

    if ! mv -f -- "$TEMP_CHECKSUM" "$CHECKSUM_FILE"; then
        BACKEND_FAILURE_REASON="backup ZIP was published but its SHA-256 sidecar could not be finalized"
        rm -f -- "$BACKUP_FILE" || true
        return 1
    fi
    TEMP_CHECKSUM=""

    chown nobody:users "$BACKUP_FILE" "$CHECKSUM_FILE" 2>/dev/null || \
        log "WARNING: Unable to set backup ownership"
    chmod 0644 "$BACKUP_FILE" "$CHECKSUM_FILE" 2>/dev/null || \
        log "WARNING: Unable to set backup permissions"

    log "Backup and SHA-256 sidecar finalized successfully"
}

prune_backups() {
    local -a files=()
    local entry count i checksum

    while IFS= read -r -d '' entry; do
        files+=("${entry#*|}")
    done < <(
        find "$BACKUP_DIR" -maxdepth 1 -type f \
            \( -name '*-boot-backup-*.zip' -o -name '*-flash-backup-*.zip' \) \
            -printf '%T@|%p\0' 2>/dev/null |
            sort -z -t'|' -k1,1nr
    )

    count=${#files[@]}
    if (( count <= MAX_BACKUPS )); then
        log "Backup retention: ${count}/${MAX_BACKUPS}; nothing to prune"
        return 0
    fi

    for ((i=MAX_BACKUPS; i<count; i++)); do
        checksum="${files[$i]}.sha256"
        log "Deleting old backup: ${files[$i]}"
        if rm -f -- "${files[$i]}"; then
            [ ! -e "$checksum" ] || rm -f -- "$checksum" || \
                log "WARNING: Unable to delete old checksum: $checksum"
        else
            log "WARNING: Unable to delete old boot backup: ${files[$i]}"
        fi
    done
}

###############################################################################
# VALIDATION
###############################################################################

validate_configuration() {
    local value

    for value in \
        "$MAX_BACKUPS" \
        "$COMPRESSION_LEVEL" \
        "$MIN_ARCHIVE_FILES" \
        "$SIZE_TIMEOUT_SECONDS" \
        "$BACKUP_TIMEOUT_SECONDS" \
        "$LOG_MAX_BYTES" \
        "$LOG_KEEP" \
        "$LOG_RETENTION_DAYS" \
        "$LOG_LINE_MAX_BYTES" \
        "$LOG_RUNAWAY_MULTIPLIER" \
        "$BACKEND_DIAGNOSTIC_MAX_BYTES" \
        "$BACKEND_DIAGNOSTIC_MAX_LINES"
    do
        [[ "$value" =~ ^[0-9]+$ ]] || {
            BACKEND_FAILURE_REASON="numeric configuration contains an invalid value: $value"
            return 1
        }
    done

    (( MAX_BACKUPS >= 1 )) || return 1
    (( COMPRESSION_LEVEL >= 0 && COMPRESSION_LEVEL <= 9 )) || return 1
    (( MIN_ARCHIVE_FILES >= 1 )) || return 1
    (( SIZE_TIMEOUT_SECONDS >= 1 && BACKUP_TIMEOUT_SECONDS >= 1 )) || return 1
    (( LOG_MAX_BYTES >= 4096 && LOG_LINE_MAX_BYTES >= 256 )) || return 1
    (( LOG_LINE_MAX_BYTES < LOG_MAX_BYTES )) || return 1
    (( LOG_RUNAWAY_MULTIPLIER >= 2 )) || return 1
    (( BACKEND_DIAGNOSTIC_MAX_BYTES >= 1024 )) || return 1
    (( BACKEND_DIAGNOSTIC_MAX_LINES >= 1 )) || return 1
    case "$BACKUP_BACKEND" in auto|native|direct) ;; *) return 1 ;; esac
}

validate_environment() {
    local required
    for required in \
        awk cat df find findmnt flock grep head jq mkfifo sed sha256sum \
        sort stat tail tr unzip wc "$TIMEOUT_BIN"
    do
        require_command "$required" || return 1
    done

    [ -d "$POOL_PATH" ] || {
        BACKEND_FAILURE_REASON="pool path does not exist: $POOL_PATH"
        return 1
    }

    local mount_target
    mount_target=$(findmnt -rn -T "$POOL_PATH" -o TARGET 2>/dev/null || true)
    [ "$mount_target" = "$POOL_PATH" ] || {
        BACKEND_FAILURE_REASON="$POOL_PATH is not an active mount point; detected ${mount_target:-none}"
        return 1
    }

    case "$BACKUP_DIR" in
        "$POOL_PATH"|"$POOL_PATH"/*) ;;
        *)
            BACKEND_FAILURE_REASON="backup directory is outside the protected pool path"
            return 1
            ;;
    esac
}

prepare_destination() {
    [ -d "$BACKUP_DIR" ] || mkdir -p -- "$BACKUP_DIR" || return 1
    chmod 0775 "$BACKUP_DIR" 2>/dev/null || true

    WRITE_TEST="$BACKUP_DIR/.backup_boot_disk_write_test.$$"
    touch "$WRITE_TEST" 2>/dev/null || return 1
    rm -f -- "$WRITE_TEST"
    WRITE_TEST=""
}

###############################################################################
# MAIN
###############################################################################

main() {
    local available runtime_value notification_message notification_description

    exec 9>"$LOCKFILE"
    if ! flock -n 9; then
        log "Another boot-device backup is already running"
        return 1
    fi

    initialize_logging
    trap cleanup EXIT
    log "Starting Unraid boot-device backup v$SCRIPT_VERSION"

    if ! validate_configuration; then
        log "ERROR: ${BACKEND_FAILURE_REASON:-Invalid backup configuration}"
        notify alert "Backup - CONFIGURATION ERROR" \
            "${BACKEND_FAILURE_REASON:-Invalid backup configuration}."$'\n'"Runtime: $(runtime)"
        return 2
    fi

    if ! validate_environment; then
        log "ERROR: $BACKEND_FAILURE_REASON"
        notify alert "Backup - ENVIRONMENT ERROR" \
            "$BACKEND_FAILURE_REASON"$'\n'"Runtime: $(runtime)"
        return 2
    fi

    if ! prepare_destination; then
        log "ERROR: Backup destination is unavailable or not writable: $BACKUP_DIR"
        notify alert "Backup - DESTINATION ERROR" \
            "Backup destination is unavailable or not writable:"$'\n'"$BACKUP_DIR"$'\n'"Runtime: $(runtime)"
        return 3
    fi

    HELPER_LOG=$(mktemp /tmp/backup_boot_disk_backend.XXXXXX) || return 4
    HELPER_LOG_META="${HELPER_LOG}.meta"
    HELPER_LOGGED_MARKER="${HELPER_LOG}.logged"
    ARCHIVE_LIST_FILE=$(mktemp /tmp/backup_boot_disk_archive.XXXXXX) || return 4

    initialize_identity
    detect_platform_changes

    BACKUP_NAME="${SERVER_SLUG}-v${VERSION_SLUG}-boot-backup-$(date '+%Y%m%d-%H%M%S').zip"
    BACKUP_FILE="$BACKUP_DIR/$BACKUP_NAME"
    CHECKSUM_FILE="${BACKUP_FILE}.sha256"
    TEMP_FILE="$BACKUP_DIR/.${BACKUP_NAME}.tmp.$$"

    log "Unraid version: $OS_VERSION"
    log "Configured backend: $BACKUP_BACKEND"
    log "Compression level: $COMPRESSION_LEVEL"

    if ! select_backend; then
        log "ERROR: $BACKEND_FAILURE_REASON"
        log_helper_diagnostics
        notify alert "Backup - BACKEND ERROR" \
            "$BACKEND_FAILURE_REASON"$'\n'"Runtime: $(runtime)"
        return 5
    fi

    if ! generate_with_fallback; then
        log "ERROR: $BACKEND_FAILURE_REASON"
        log_helper_diagnostics
        notify alert "Backup - GENERATION FAILED" \
            "$BACKEND_FAILURE_REASON"$'\n\n'"Backend: $SELECTED_BACKEND"$'\n'"Runtime: $(runtime)"
        return 6
    fi

    if ! finalize_backup; then
        log "ERROR: $BACKEND_FAILURE_REASON"
        notify alert "Backup - FINALIZE FAILED" \
            "$BACKEND_FAILURE_REASON"$'\n'"Runtime: $(runtime)"
        return 7
    fi

    if ! write_state; then
        log "ERROR: Backup is valid, but persistent compatibility state could not be updated"
        notify warning "Backup - STATE WARNING" \
            "Backup and checksum were created, but compatibility state could not be updated."$'\n\n'"File: $BACKUP_FILE"$'\n'"No older backup was pruned."$'\n'"Runtime: $(runtime)"
        return 8
    fi

    prune_backups

    available=$(available_bytes)
    runtime_value=$(runtime)

    log "Boot-device backup completed successfully"
    log "File: $BACKUP_NAME"
    log "Backend: $SELECTED_BACKEND"
    log "Size: $(bytes_human "$GENERATED_SIZE")"
    log "Runtime: $runtime_value"

    notification_description="Backup - OK"
    notification_message="Boot-device backup completed successfully."
    notification_message+=$'\n\n'"File: $BACKUP_NAME"
    notification_message+=$'\n'"Backend: $SELECTED_BACKEND"
    notification_message+=$'\n'"Size: $(bytes_human "$GENERATED_SIZE")"
    notification_message+=$'\n'"Files verified: $ARCHIVE_FILE_COUNT"
    notification_message+=$'\n'"SHA-256: $ARCHIVE_SHA256"
    notification_message+=$'\n'"Destination: $BACKUP_DIR"
    notification_message+=$'\n'"Free space: $(bytes_human "$available")"
    notification_message+=$'\n'"Retention: $MAX_BACKUPS backups"
    notification_message+=$'\n'"Runtime: $runtime_value"

    if [ "$FALLBACK_USED" = true ]; then
        notification_description="Backup - OK WITH FALLBACK"
        notification_message+=$'\n\n'"Native backend fallback: ${NATIVE_FAILURE_REASON:-native helper was unavailable or incompatible}"
    fi
    if [ "$PLATFORM_CHANGE_DETECTED" = true ]; then
        notification_message+=$'\n\n'"Platform change verified: $PLATFORM_CHANGE_SUMMARY"
    fi
    if [ -n "$ARCHIVE_WARNING_TEXT" ]; then
        notification_message+=$'\n\n'"Content warning: $ARCHIVE_WARNING_TEXT"
    fi

    notify normal "$notification_description" "$notification_message"
    return 0
}

main "$@"
