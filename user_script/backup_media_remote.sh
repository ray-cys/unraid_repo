#!/bin/bash
# Release version: bump for every deployed code change; descriptions stay user-owned.
readonly SCRIPT_VERSION="2.9.2"
# Version lookup exits before logging, locks, state, Docker or network activity.
if [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" == --version ]]; then
    printf 'backup_media_remote.sh %s\n' "$SCRIPT_VERSION"
    exit 0
fi
# BEGIN CURRENT OPERATIONAL PURPOSE
# PURPOSE: Maintain a remote mirror of configured media shares on ISS for recovery after loss of
#   Hubble.
# WORKFLOW: Check local/remote mounts, paths, space and rsync capabilities; wake ISS if needed,
#   transfer under a shared remote-use lease, publish completion evidence and request shutdown
#   when safe.
# COORDINATION: Shares ISS coordination with backup_vault_remote; backup_health_audit reads its
#   completion/verification receipt.
# LIMITS: This is a mirror: source removals can propagate. Compatibility uses available features
#   rather than requiring identical rsync versions. Shutdown acknowledgement and observed
#   shutdown are separate results.
# REPORTING: Report transfer, verification and shutdown outcomes; retain failed delivery
#   evidence for retry.
# Commands and side effects: docs/user-scripts-cli.md in ray-cys/unraid_repo.
# END CURRENT OPERATIONAL PURPOSE
# COMPLETION EVIDENCE: schema-2 last-success and last-attempt receipts retain per-job
# outcomes/policy identity. Success is published before shutdown/mail; unchanged
# files use rsync size/mtime selection, not a full mirror rehash. --evidence-status
# reads receipts without SSH or waking ISS. Missing statistics/read-back fail proof.
clearLog=true

###############################################################################
# Media Remote Backup
#
# PURPOSE
# -------
# Mirror selected local Unraid shares to a remote Unraid server using rsync.
#
# Workflow:
#
#   1. Validate local configuration and source paths
#   2. Wake the remote NAS using Wake-on-LAN
#   3. Wait for SSH availability
#   4. Confirm the remote /mnt/user filesystem is actually mounted
#   5. Confirm configured remote destination directories exist
#   6. Estimate changed data and verify aggregate remote free space
#   7. Rsync each configured backup job serially
#   8. Retry eligible failures with exponential backoff
#   9. Collect transfer statistics and preserve raw rsync logs
#  10. Optionally shut down the remote NAS
#  11. Send one consolidated Unraid notification
#  12. Prune old logs
#
#
# SAFETY
# ------
# - The remote backup is a MIRROR.
# - Files removed from the source may also be removed from the destination.
# - Deletions use --delete-delay so removals occur after the transfer phase.
# - Remote /mnt/user MUST be confirmed mounted before any rsync is allowed.
# - Remote destination directories are NEVER auto-created.
# - A failed preflight prevents rsync from starting.
# - Backup failures return a non-zero script exit status.
#
#
# SCHEDULING
# ----------
# Scheduling is managed externally by Unraid User Scripts.
# This script does not create or modify its own schedule.
#
###############################################################################

# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="backup_media_remote"
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
    usr_ops_delivery_record "$delivery_rc" "$importance" "$summary" "$message" "${args[@]}" || printf 'Notification delivery evidence could not be queued; producer failure remains active.\n' >&2
    return "$delivery_rc"
}

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
export LC_ALL=C


###############################################################################
# CONFIGURATION
###############################################################################

# ---------------------------------------------------------------------------
# Identification
# ---------------------------------------------------------------------------

SRC_NAS="Hubble NAS"
DEST_NAS="ISS NAS"


# ---------------------------------------------------------------------------
# Remote NAS / SSH
# ---------------------------------------------------------------------------

REMOTE="root@192.168.50.3"
REMOTE_MAC="9C:6B:00:4B:BB:EE"

SSH_PORT=22
SSH_CONNECT_TIMEOUT=5


# ---------------------------------------------------------------------------
# Wake-on-LAN
# ---------------------------------------------------------------------------

ENABLE_WOL=true


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

LOG_DIR="/mnt/user/cloud/logs/script/backup_media_remote"
RAW_LOG_DIR="${LOG_DIR}/rsync_raw"

MAX_LOGS=2
MAX_RAW_LOGS=2


# ---------------------------------------------------------------------------
# Backup jobs
# ---------------------------------------------------------------------------

# Format:
#
#   "Label|Local source|Remote destination|Comma-separated excludes|Bandwidth"
#
# Bandwidth is in KiB/s.
#
#   0 = unlimited
#
# Examples:
#
#   20480 = approximately 20 MiB/s
#
# Paths can contain spaces.
#
BACKUP_JOBS=(
    "Media|/mnt/user/media|/mnt/user/media|/net/|0"
    "Secure|/mnt/user/secure|/mnt/user/secure|/torrent/|0"
)


# ---------------------------------------------------------------------------
# Rsync
# ---------------------------------------------------------------------------

# NOTE:
#
# --delete-delay means this remains a MIRROR backup.
# Files deleted from the source can also be deleted from the destination.
#
# -a already includes:
#
#   recursion
#   permissions
#   timestamps
#   symlinks
#   ownership/group preservation
#
RSYNC_BASE_ARGS=(
    "-a"
    "--delete-delay"
    "--partial"
    "--partial-dir=.rsync-partial"
    "--protect-args"
    "--stats"
)

# Default exclusions applied to every backup job.
#
DEFAULT_EXCLUDES=(
    "--exclude=/.hubble-backup-identity"
    "--exclude=*.sock"
    "--exclude=*/.cache/*"
)

# Include rsync itemized file changes in the run log.
#
LOG_ITEMIZED_CHANGES=false


# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------

# true:
#   Rsync performs a complete comparison but does not modify the destination.
#
# false:
#   Normal live backup.
#
DRY_RUN=false


# ---------------------------------------------------------------------------
# Retry / backoff
# ---------------------------------------------------------------------------

# Total rsync attempts per backup job.
#
MAX_RETRIES=3

# Initial retry delay in seconds.
#
RETRY_BACKOFF=30

# Exponential delays:
#
#   Attempt 1 failure -> 30s
#   Attempt 2 failure -> 60s
#   Attempt 3 failure -> stop
#
ENABLE_EXPONENTIAL_BACKOFF=true

MAX_BACKOFF=600

# Rsync exit codes eligible for retry.
#
# 255 represents SSH failure. Permanent SSH failures such as authentication or
# host-key errors are detected separately and are not repeatedly retried.
#
RETRY_CODES=(
    10
    11
    12
    20
    23
    24
    30
    255
)


# ---------------------------------------------------------------------------
# Process priority
# ---------------------------------------------------------------------------

USE_LOW_PRIORITY_IO=true

IONICE_CLASS=2
IONICE_PRIORITY=7
NICE_LEVEL=10


# ---------------------------------------------------------------------------
# Remote-space preflight
# ---------------------------------------------------------------------------

# estimate:
#   Perform an rsync --dry-run and use "Total transferred file size".
#
# total:
#   Conservatively assume the entire local source needs to fit.
#
PREFLIGHT_MODE="estimate"

# Minimum free-space safety buffer.
#
# 1 GiB:
#
PREFLIGHT_MIN_BUFFER_BYTES=1073741824

# Additional buffer as percentage of estimated changed bytes.
#
# The larger of:
#
#   PREFLIGHT_MIN_BUFFER_BYTES
#
# or:
#
#   estimated transfer × PREFLIGHT_BUFFER_PERCENT
#
# is used.
#
PREFLIGHT_BUFFER_PERCENT=5

REMOTE_DF_RETRIES=3
REMOTE_DF_RETRY_SLEEP=3


# ---------------------------------------------------------------------------
# Remote readiness
# ---------------------------------------------------------------------------

# Maximum time to wait for SSH after Wake-on-LAN.
#
MAX_SSH_WAIT=420
SSH_WAIT_INTERVAL=20

# Once SSH is available, maximum time to wait for /mnt/user to become mounted.
#
ARRAY_READY_WAIT=180
ARRAY_READY_INTERVAL=6


# ---------------------------------------------------------------------------
# Remote shutdown
# ---------------------------------------------------------------------------

# Successful backup -> shut remote NAS down.
SHUTDOWN_REMOTE_ON_SUCCESS=true

# Failed backup -> leave remote NAS running unless explicitly enabled.
#
SHUTDOWN_REMOTE_ON_FAILURE=false

# Independent remote-activity shutdown guards. Ordinary read/correcting parity
# checks may be interrupted by the clean shutdown after backup. More critical
# parity sync, rebuild, and disk-clear operations remain protected.
#
DEFER_REMOTE_SHUTDOWN_WHILE_MOVER=true
DEFER_REMOTE_SHUTDOWN_DURING_PARITY_CHECK=false
DEFER_REMOTE_SHUTDOWN_DURING_CRITICAL_ARRAY_OPERATION=true


# ---------------------------------------------------------------------------
# Notification
# ---------------------------------------------------------------------------

NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
NOTIFY_SUBJECT="Backup Media Remote"

NOTIFY_EXCERPT_LINES=8


# ---------------------------------------------------------------------------
# Lock
# ---------------------------------------------------------------------------

LOCK_FILE="/tmp/backup_media_remote.lock"


readonly SCRIPT_ID="backup_media_remote"

###############################################################################
# SHARED ISS COORDINATION AND TRANSPORT (embedded; standalone User Script)
###############################################################################
# Both scripts must use the same remote lock. It is held by a live SSH process,
# not a stale PID file. Only the owner may request ISS shutdown.
REMOTE_BACKUP_LOCK="/run/hubble-iss-backup.lock"
REMOTE_LEASE_WAIT_SECONDS=1800
RSYNC_IO_TIMEOUT=300
MAX_MAIN_LOG_BYTES=$((1024 * 1024))
MAX_RAW_LOG_BYTES=$((2 * 1024 * 1024))
PRESERVE_HARD_LINKS=true
STATUS_DIR="/mnt/vault/cloud/logs/script/user_scripts_status"
BACKUP_RESULT=not_started
RETENTION_RESULT=not_started
VERIFICATION_RESULT=not_started
BACKUP_PHASE=startup
BACKUP_NOTIFIED=false
NOTIFICATION_RESULT=not_attempted
SHUTDOWN_RESULT=not_requested
BACKUP_STARTED=$(date +%s)
BACKUP_TMP=""
LEASE_PID=""
LEASE_INPUT=""
LEASE_TOKEN=""
TRANSPORT_OPTIONS=()

backup_transport_init() {
    local value flag
    [[ "$SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( SSH_PORT <= 65535 )) || return 1
    [[ "$REMOTE_LEASE_WAIT_SECONDS" =~ ^(0|[1-9][0-9]*)$ ]] && (( REMOTE_LEASE_WAIT_SECONDS <= 86400 )) || return 1
    for value in "$RSYNC_IO_TIMEOUT" "$MAX_MAIN_LOG_BYTES" "$MAX_RAW_LOG_BYTES"; do [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1; done
    for flag in "$PRESERVE_HARD_LINKS" "$DRY_RUN" "$ENABLE_WOL" "$USE_LOW_PRIORITY_IO"; do [[ "$flag" == true || "$flag" == false ]] || return 1; done
    BACKUP_TMP=$(mktemp -d /tmp/iss-backup.XXXXXX) || return 1
    chmod 700 "$BACKUP_TMP" || return 1
    TRANSPORT_OPTIONS=(-p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-8}"
        -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o Compression=no
        -o ControlMaster=auto -o ControlPersist=60 -o "ControlPath=$BACKUP_TMP/ssh")
    printf -v RSYNC_RSH '%q ' ssh "${TRANSPORT_OPTIONS[@]}"
    export RSYNC_RSH
}
backup_ssh() {
    local command
    if (( $# == 1 )); then command="$1"; else printf -v command '%q ' "$@"; fi
    if (( ${BACKUP_SSH_COMMAND_TIMEOUT:-0} > 0 )); then
        timeout --signal=TERM --kill-after=5 "$BACKUP_SSH_COMMAND_TIMEOUT" ssh "${TRANSPORT_OPTIONS[@]}" "$REMOTE" "export LC_ALL=C; $command"
    else
        ssh "${TRANSPORT_OPTIONS[@]}" "$REMOTE" "export LC_ALL=C; $command"
    fi
}
backup_source_ready() {
    local source="$1" mount canonical
    [[ "$source" == /* && "$source" != / && "$source" != *$'\n'* && "$source" != *$'\t'* && -d "$source" && ! -L "$source" ]] || return 1
    case "$source" in /mnt/user/*) mount=/mnt/user;; /mnt/vault/*) mount=/mnt/vault;; /boot/*) mount=/boot;; *) return 1;; esac
    mountpoint -q "$mount" || return 1
    canonical=$(realpath -e -- "$source") || return 1
    [[ "$canonical" == "$source" ]] || return 1
    [[ -n "$(find "$source" -mindepth 1 -maxdepth 1 -print -quit)" ]] || return 1
}
# Feature probe, deliberately independent of package/Unraid version numbers.
# Only private /tmp fixtures are touched; configured backup paths are not used.
backup_rsync_probe() (
    local side="$1" links="$2" probe result a b
    export LC_ALL=C
    probe=$(mktemp -d /tmp/hubble-rsync-capability.XXXXXX) || return 1
    trap 'rm -rf -- "$probe"' EXIT
    mkdir "$probe/source" "$probe/destination" || return 1
    printf 'Hubble ISS rsync capability fixture\n' >"$probe/source/file with spaces [1].txt"
    printf '%s: %s\n' "$side" "$(rsync --version | sed -n '1p')"
    local -a options=(-a --delete-delay --delete-excluded --partial --partial-dir=.rsync-partial --protect-args --stats --timeout=15 --max-delete=1 '--filter=P /.hubble-backup-identity')
    [[ "$links" != true ]] || options+=(-H)
    if ! rsync "${options[@]}" "$probe/source/" "$probe/destination/" >"$probe/result" 2>&1; then
        printf '%s rsync required-feature probe failed:\n' "$side" >&2
        tail -n 12 "$probe/result" >&2
        return 1
    fi
    a=$(sha256sum "$probe/source/file with spaces [1].txt");b=$(sha256sum "$probe/destination/file with spaces [1].txt")
    [[ "${a%% *}" == "${b%% *}" ]] || { printf '%s rsync probe content verification failed\n' "$side" >&2;return 1; }
    # Resumption/checksum repair is also used by the vault workflow.
    rsync "${options[@]}" --checksum --dry-run "$probe/source/" "$probe/destination/" >"$probe/result" 2>&1 || { printf '%s checksum probe failed\n' "$side" >&2;tail -n 12 "$probe/result" >&2;return 1; }
    printf '%s rsync required features and temporary copy verified\n' "$side"
)
backup_capabilities() {
    local cmd value
    for value in "$RSYNC_IO_TIMEOUT" "$MAX_MAIN_LOG_BYTES" "$MAX_RAW_LOG_BYTES"; do [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1; done
    [[ "$PRESERVE_HARD_LINKS" == true || "$PRESERVE_HARD_LINKS" == false ]] || return 1
    [[ "$SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( SSH_PORT <= 65535 )) || return 1
    for cmd in ssh rsync jq timeout flock realpath sha256sum stat find sort awk sed tail head tee date mktemp xargs grep cat du mountpoint; do command -v "$cmd" >/dev/null || return 1; done
    # Version banners are diagnostic only. Native Unraid packages may differ
    # between Hubble and ISS; negotiate protocols normally and test real flags.
    if ! backup_rsync_probe Hubble "$PRESERVE_HARD_LINKS" >>"$LOG_FILE" 2>&1;then
        printf 'Hubble rsync feature validation failed; see %s\n' "$LOG_FILE" >&2;return 1
    fi
    local remote_boot
    remote_boot=$(BACKUP_SSH_COMMAND_TIMEOUT=30 backup_ssh 'cat /proc/sys/kernel/random/boot_id') || return 1
    [[ -n "$remote_boot" && "$remote_boot" != "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" ]] || return 1
    {
        declare -f backup_rsync_probe
        cat <<'CAPABILITIES'
set -euo pipefail
export LC_ALL=C
for cmd in bash rsync flock realpath sha256sum stat find sort awk sed df mktemp du mv cat tail mkdir rm;do
    command -v "$cmd" >/dev/null || { printf 'ISS missing required command: %s\n' "$cmd" >&2;exit 1; }
done
CAPABILITIES
        printf 'backup_rsync_probe ISS %q\n' "$PRESERVE_HARD_LINKS"
    } | BACKUP_SSH_COMMAND_TIMEOUT=45 backup_ssh bash -s >>"$LOG_FILE" 2>&1 || {
        printf 'ISS command/rsync feature validation failed; see %s\n' "$LOG_FILE" >&2;return 1
    }

}
backup_acquire_lease() {
    local ready output_fd remote_script original_input original_output
    [[ "$REMOTE_BACKUP_LOCK" =~ ^/run/[A-Za-z0-9_.-]+$ && "$REMOTE_LEASE_WAIT_SECONDS" =~ ^[0-9]+$ ]] || return 1
    remote_script=$(cat <<'LEASE'
set -euo pipefail
exec 9>"$1"
printf '%s\n' "$BASHPID" >"$1.waiter.$3"
trap 'rm -f -- "$1.waiter.$3"' EXIT
flock -w "$2" 9 || exit 75
rm -f -- "$1.waiter.$3"
printf '%s\n' "$3" >"$1.owner"
trap 'rm -f -- "$1.owner"' EXIT
# A recently accepted shutdown must finish before another job starts. /run is
# cleared on reboot; failed shutdown reservations expire after fifteen minutes.
if [[ -f /run/hubble-iss-shutdown.pending ]]; then
    read -r stamp </run/hubble-iss-shutdown.pending
    [[ "$stamp" =~ ^[0-9]+$ ]] || exit 75
    (( $(date +%s) - stamp > 900 )) || exit 75
    rm -f /run/hubble-iss-shutdown.pending
fi
printf 'ISS_BACKUP_READY\n'
while IFS= read -r line; do :; done
LEASE
) || return 1
    LEASE_TOKEN="$SCRIPT_ID-$$-$RANDOM-$RANDOM"
    coproc ISS_LEASE { backup_ssh bash -c "$remote_script" -- "$REMOTE_BACKUP_LOCK" "$REMOTE_LEASE_WAIT_SECONDS" "$LEASE_TOKEN"; }
    LEASE_PID=${ISS_LEASE_PID:-}
    original_input=${ISS_LEASE[1]:-}; original_output=${ISS_LEASE[0]:-}
    [[ -n "$LEASE_PID" && -n "$original_input" && -n "$original_output" ]] || return 1
    exec {LEASE_INPUT}>&"$original_input"
    exec {output_fd}<&"$original_output"
    exec {original_input}>&-
    exec {original_output}<&-
    if ! IFS= read -r -t "$((REMOTE_LEASE_WAIT_SECONDS+15))" ready <&"$output_fd" || [[ "$ready" != ISS_BACKUP_READY ]]; then
        exec {output_fd}<&-
        return 1
    fi
    exec {output_fd}<&-
}
backup_lease_alive() {
    [[ -n "$LEASE_PID" && -n "$LEASE_INPUT" ]] && kill -0 "$LEASE_PID" 2>/dev/null &&
        (trap - PIPE; printf 'active\n' >&"$LEASE_INPUT") &&
        BACKUP_SSH_COMMAND_TIMEOUT=15 backup_ssh "test -f $REMOTE_BACKUP_LOCK.owner && test \"\$(cat $REMOTE_BACKUP_LOCK.owner)\" = '$LEASE_TOKEN'"
}
backup_shutdown_handoff() {
    local waiters
    if ! waiters=$(BACKUP_SSH_COMMAND_TIMEOUT=30 backup_ssh bash -s -- "$REMOTE_BACKUP_LOCK" "$REMOTE_LEASE_WAIT_SECONDS" <<'WAITERS'
set -euo pipefail
for file in "$1".waiter.*; do
    [[ -f "$file" ]] || continue
    read -r pid <"$file"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || exit 3
    age=$(( $(date +%s)-$(stat -c %Y -- "$file") ))
    (( age >= 0 )) || exit 3
    # Dead/reused PIDs cannot leave a permanent shutdown blocker behind.
    if (( age <= $2+60 )) && kill -0 "$pid" 2>/dev/null; then printf 'waiting\n'; else rm -f -- "$file"; fi
done
WAITERS
); then
        REMOTE_SHUTDOWN_SKIPPED_REASON="Queued backup status could not be verified"
        return 1
    fi
    if [[ -n "$waiters" ]]; then
        SHUTDOWN_RESULT=deferred
        REMOTE_SHUTDOWN_SKIPPED_REASON="Another backup is waiting for ISS; leaving it running for handoff"
        return 1
    fi
}
backup_request_shutdown() {
    backup_lease_alive || return 1
    BACKUP_SSH_COMMAND_TIMEOUT=30 backup_ssh bash -s <<'SHUTDOWN'
set -euo pipefail
if [[ -x /usr/local/sbin/powerdown ]]; then command=/usr/local/sbin/powerdown
elif command -v powerdown >/dev/null; then command=$(command -v powerdown)
elif command -v poweroff >/dev/null; then command=$(command -v poweroff)
else exit 3; fi
date +%s >/run/hubble-iss-shutdown.pending
nohup "$command" >/run/hubble-iss-shutdown.log 2>&1 </dev/null &
printf 'Clean shutdown queued; pid=%s\n' "$!"
SHUTDOWN
}
backup_bound_log() {
    local file="$1" limit="$2" temp
    [[ -f "$file" ]] || return 0
    (( $(stat -c %s "$file") > limit )) || return 0
    temp=$(mktemp "${file}.bounded.XXXXXX") || return 1
    tail -c "$limit" -- "$file" >"$temp" && mv -f -- "$temp" "$file" || { rm -f -- "$temp"; return 1; }
}
backup_phase() {
    local now
    now=$(date +%s)
    printf '%s [PHASE] %s: %ss elapsed\n' "$(date '+%F %T')" "$BACKUP_PHASE" "$((now-BACKUP_PHASE_STARTED))" >>"$LOG_FILE"
    BACKUP_PHASE="$1"; BACKUP_PHASE_STARTED="$now"
}
BACKUP_PHASE_STARTED=$BACKUP_STARTED
# Versioned producer evidence: publish data-copy success before shutdown/mail.
# Rsync validates transferred data; unchanged files retain its size/mtime check.
media_completion_evidence() {
    local status="$1" phase="$2" now temp data='[]' descriptor label src dest excludes bw policy run
    mountpoint -q "${MEDIA_EVIDENCE_MOUNT:-/mnt/vault}" || return 1
    mkdir -p "$STATUS_DIR" || return 1
    policy=$(printf '%s\0' "$REMOTE" "${BACKUP_JOBS[@]}" "${DEFAULT_EXCLUDES[@]}" "${RSYNC_BASE_ARGS[@]}"|sha256sum|cut -d ' ' -f1)
    run="${RUN_STAMP:-$BACKUP_STARTED}-$BACKUP_STARTED";now=$(date +%s)
    for descriptor in "${BACKUP_JOBS[@]}";do
        IFS='|' read -r label src dest excludes bw <<<"$descriptor"
        [[ -n "$label" ]] || continue
        data=$(jq -nc --argjson data "$data" --arg name "$label" --arg source "$src" --arg destination "$dest" --arg reason "${RESULT_REASON[$label]:-Not run}" \
          --argjson code "${RESULT_CODE[$label]:-1}" --argjson sent "${BYTES_SENT[$label]:-0}" --argjson bytes "${TRANSFERRED_BYTES[$label]:-0}" --argjson files "${FILES_TRANSFERRED[$label]:-0}" --argjson deleted "${DELETED_FILES[$label]:-0}" \
          '$data+[{name:$name,source:$source,destination:$destination,exitCode:$code,reason:$reason,bytesSent:$sent,transferredBytes:$bytes,filesTransferred:$files,deletedFiles:$deleted}]') || return 1
    done
    temp=$(mktemp "$STATUS_DIR/.media-completion.XXXXXX") || return 1
    jq -n --arg run "$run" --arg status "$status" --arg phase "$phase" --arg policy "$policy" --arg remote "$REMOTE" --arg version "$SCRIPT_VERSION" --arg error "${BACKUP_LAST_ERROR:-}" \
      --argjson jobs "$data" --argjson epoch "$now" --argjson started "$BACKUP_STARTED" \
      '{schema:2,name:"backup_media_remote",runId:$run,status:$status,phase:$phase,epoch:$epoch,startedAt:$started,policySha256:$policy,remote:$remote,scriptVersion:$version,lastError:$error,jobs:$jobs,
        copy:(if $status=="OK" then "OK" else "UNVERIFIED" end),verification:(if $status=="OK" then "rsync_transfer_verified" else "not_verified" end),
        scope:"Rsync exit zero with complete statistics and stable source/lease read-back; transferred data checksums, unchanged files size/mtime; not a full mirror rehash"}' >"$temp" || { rm -f "$temp";return 1; }
    if [[ "$status" == OK ]];then
        jq -e '(.jobs|length)>0 and all(.jobs[];.exitCode==0)' "$temp" >/dev/null || { rm -f "$temp";return 1; }
        chmod 600 "$temp";sync -f "$temp" || return 1
        mv "$temp" "$STATUS_DIR/backup_media_remote.last-success.json" || return 1
    else chmod 600 "$temp";mv "$temp" "$STATUS_DIR/backup_media_remote.last-attempt.json" || return 1;fi
}

backup_finish() {
    local rc=$? status=OK temp summary
    trap - EXIT INT TERM PIPE
    (( rc == 0 )) || status=FAILED
    [[ "$BACKUP_RESULT" != OK || "$status" != FAILED ]] || status=WARNING
    [[ "${DRY_RUN:-false}" != true || "$status" != OK ]] || status=WARNING
    [[ "$RETENTION_RESULT" != FAILED || "$status" != OK ]] || status=WARNING
    [[ "$SHUTDOWN_RESULT" == deferred || ( -z "${REMOTE_SHUTDOWN_SKIPPED_REASON:-}" && "${REMOTE_SHUTDOWN_FAILED:-0}" == 0 ) ]] || { [[ "$status" != OK ]] || status=WARNING; }
    [[ "$SHUTDOWN_RESULT" == deferred || -z "${REMOTE_SHUTDOWN_SKIPPED_REASON:-}" ]] || SHUTDOWN_RESULT=skipped
    if (( rc == 0 )); then BACKUP_PHASE=completed; fi
    summary="${SCRIPT_ID} v${SCRIPT_VERSION}; copy=$BACKUP_RESULT; verify=$VERIFICATION_RESULT; retention=$RETENTION_RESULT; phase=$BACKUP_PHASE; duration=$(( $(date +%s)-BACKUP_STARTED ))s; shutdown=$SHUTDOWN_RESULT ${REMOTE_SHUTDOWN_SKIPPED_REASON:-}"
    if (( rc != 0 )) && [[ "$BACKUP_NOTIFIED" != true && -x "${NOTIFY_BIN:-}" ]]; then
        if usr_ops_notify timeout 30 "$NOTIFY_BIN" -i alert -s "$NOTIFY_SUBJECT" -d 'Backup failed' -m "$summary
Failure detail: ${BACKUP_LAST_ERROR:-No detailed error recorded; inspect the failed phase above.}
Log: $LOG_FILE" >/dev/null 2>&1; then NOTIFICATION_RESULT=sent; else NOTIFICATION_RESULT=failed; fi
    fi
    [[ "$NOTIFICATION_RESULT" != failed && "$NOTIFICATION_RESULT" != unavailable || "$status" != OK ]] || status=WARNING
    if mountpoint -q /mnt/vault && command -v jq >/dev/null; then
        mkdir -p -- "$STATUS_DIR"
        temp=$(mktemp "$STATUS_DIR/.${SCRIPT_ID}.XXXXXX") &&
            jq -n --arg name "$SCRIPT_ID" --arg status "$status" --arg summary "$summary" --arg phase "$BACKUP_PHASE" --arg copy "$BACKUP_RESULT" --arg verification "$VERIFICATION_RESULT" --arg retention "$RETENTION_RESULT" --arg notification "$NOTIFICATION_RESULT" --arg shutdown "$SHUTDOWN_RESULT" --arg shutdown_reason "${REMOTE_SHUTDOWN_SKIPPED_REASON:-}" --arg version "$SCRIPT_VERSION" --arg log "$LOG_FILE" --argjson duration "$(( $(date +%s)-BACKUP_STARTED ))" --argjson epoch "$(date +%s)" \
            '{name:$name,status:$status,summary:$summary,phase:$phase,copy:$copy,verification:$verification,retention:$retention,notification:$notification,shutdown:$shutdown,shutdown_reason:$shutdown_reason,scriptVersion:$version,duration_seconds:$duration,log:$log,epoch:$epoch}' >"$temp" && mv -f -- "$temp" "$STATUS_DIR/$SCRIPT_ID.json"
    fi
    [[ "$BACKUP_RESULT" == OK && "$VERIFICATION_RESULT" == rsync_transfer_verified ]] || media_completion_evidence UNVERIFIED "$BACKUP_PHASE" || true
    [[ -z "$LEASE_INPUT" ]] || exec {LEASE_INPUT}>&-
    [[ -z "$LEASE_PID" ]] || { kill "$LEASE_PID" 2>/dev/null || true; wait "$LEASE_PID" 2>/dev/null || true; }
    [[ ${#TRANSPORT_OPTIONS[@]} == 0 ]] || ssh "${TRANSPORT_OPTIONS[@]}" -O exit "$REMOTE" >/dev/null 2>&1 || true
    [[ -z "$BACKUP_TMP" ]] || rm -rf -- "$BACKUP_TMP"
    [[ -z "${TMP_DIR:-}" ]] || rm -rf -- "$TMP_DIR"
    [[ ! -f "${LOG_FILE:-}" ]] || backup_bound_log "$LOG_FILE" "$MAX_MAIN_LOG_BYTES" || true
    exit "$rc"
}

# A deletion ceiling is deliberately not a transaction: hitting it fails the
# run, and some deletions may already have occurred. Review before raising it.
MAX_DELETIONS=10000
backup_destination() {
    local label="$1" source="$2" destination="$3" identity expected actual dest_q
    [[ "$destination" == /mnt/user/* && "$destination" != *'/../'* && "$destination" != *$'\n'* ]] || return 1
    dest_q=$(printf '%q' "$destination")
    actual=$(backup_ssh "test -d $dest_q && test ! -L $dest_q && realpath -e -- $dest_q") || return 1
    [[ "$actual" == "$destination" ]] || return 1
    identity=$(printf '%s\n' "$SCRIPT_ID" "$REMOTE" "$label" "$source" "$destination" | sha256sum); identity=${identity%% *}
    expected=$(backup_ssh "if test -f $dest_q/.hubble-backup-identity; then cat $dest_q/.hubble-backup-identity; fi") || return 1
    [[ -z "$expected" || "$expected" == "$identity" ]] || return 1
    [[ "$DRY_RUN" == true || -n "$expected" ]] || backup_ssh "printf '%s\\n' '$identity' > $dest_q/.hubble-backup-identity"
}

###############################################################################
# RUNTIME STATE
#
# Internal values below this point should not normally be modified.
###############################################################################

RUN_STAMP="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE="${LOG_DIR}/backup_media_remote_${RUN_STAMP}.log"

START_TIME=0

REMOTE_READY=0

REMOTE_WAIT_ERROR=""
REMOTE_VALIDATION_ERROR=""
PREFLIGHT_FAILURE_DETAIL=""

REMOTE_SHUTDOWN_REQUESTED=0
REMOTE_SHUTDOWN_FAILED=0
REMOTE_SHUTDOWN_SKIPPED_REASON=""

declare -a PRIORITY_PREFIX=()
declare -a FAILED_LABELS=()

declare -A RESULT_CODE=()
declare -A RESULT_REASON=()

declare -A TOTAL_BYTES=()
declare -A TRANSFERRED_BYTES=()
declare -A FILES_TRANSFERRED=()
declare -A DELETED_FILES=()
declare -A BYTES_SENT=()

declare -A ESTIMATED_BYTES=()
declare -A RAW_LOG_BY_LABEL=()

declare -A DEST_FREE_BYTES=()


###############################################################################
# LOCKING
###############################################################################



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
    [[ "$level" != ERROR ]] || BACKUP_LAST_ERROR="$category: $message"
    backup_bound_log "$LOG_FILE" "$MAX_MAIN_LOG_BYTES" || return 1

    usr_ops_log_line "$level" "$category" "$message" |
        tee -a "$LOG_FILE"
}


notify_unraid() {
    BACKUP_NOTIFIED=true
    local importance="$1"
    local description="$2"
    local message="$3"

    if [ ! -x "$NOTIFY_BIN" ]; then
        NOTIFICATION_RESULT=unavailable
        log "NOTIFY" "WARN" \
            "Unraid notification helper unavailable: $NOTIFY_BIN"

        return 0
    fi

    NOTIFICATION_RESULT=sent
    if ! usr_ops_notify timeout 30 "$NOTIFY_BIN" \
        -i "$importance" \
        -b \
        -s "$NOTIFY_SUBJECT" \
        -d "$description" \
        -m "$message"
    then
        NOTIFICATION_RESULT=failed
        log "NOTIFY" "WARN" \
            "Failed to send Unraid notification"
    fi
}


bytes_to_human() {
    local bytes="${1:-0}"

    awk -v b="$bytes" '
        BEGIN {
            unit[0]="B"
            unit[1]="KB"
            unit[2]="MB"
            unit[3]="GB"
            unit[4]="TB"
            unit[5]="PB"

            i=0

            while (b >= 1024 && i < 5) {
                b=b/1024
                i++
            }

            if (b >= 100)
                printf "%.0f%s", b, unit[i]
            else
                printf "%.1f%s", b, unit[i]
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


safe_size_bytes() {
    local path="$1"
    local size=""
    local blocks=""

    size="$(
        du -sb -- "$path" 2>/dev/null |
            awk 'NR == 1 {print $1}'
    )"

    if [[ "$size" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$size"
        return 0
    fi

    blocks="$(
        du -sk -- "$path" 2>/dev/null |
            awk 'NR == 1 {print $1}'
    )"

    if [[ "$blocks" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$((blocks * 1024))"
        return 0
    fi

    printf '0\n'
    return 1
}


safe_name() {
    local name="$1"

    printf '%s' "$name" |
        tr ' ' '_' |
        tr -cs '[:alnum:]_.-' '_'
}


array_contains() {
    local needle="$1"
    shift

    local value=""

    for value in "$@"; do
        if [ "$value" = "$needle" ]; then
            return 0
        fi
    done

    return 1
}


###############################################################################
# CONFIGURATION VALIDATION
###############################################################################

validate_configuration() {
    local descriptor=""
    local label=""
    local src=""
    local dest=""
    local extra_excludes=""
    local bwlimit=""
    local boolean_name=""
    local boolean_value=""

    local -A seen_labels=()

    if ! command -v rsync >/dev/null 2>&1; then
        log "PREFLIGHT" "ERROR" "rsync is not available"
        return 1
    fi

    if ! command -v ssh >/dev/null 2>&1; then
        log "PREFLIGHT" "ERROR" "ssh is not available"
        return 1
    fi

    if [ "${#BACKUP_JOBS[@]}" -eq 0 ]; then
        log "PREFLIGHT" "ERROR" "No backup jobs are configured"
        return 1
    fi

    case "$PREFLIGHT_MODE" in
        estimate|total)
            ;;
        *)
            log "PREFLIGHT" "ERROR" \
                "PREFLIGHT_MODE must be 'estimate' or 'total'"
            return 1
            ;;
    esac

    [[ "$MAX_DELETIONS" =~ ^[0-9]+$ ]] || return 1

    if ! [[ "$MAX_RETRIES" =~ ^[0-9]+$ ]] ||
       [ "$MAX_RETRIES" -lt 1 ]
    then
        log "PREFLIGHT" "ERROR" \
            "MAX_RETRIES must be an integer >= 1"
        return 1
    fi

    if ! [[ "$RETRY_BACKOFF" =~ ^[0-9]+$ ]] ||
       ! [[ "$MAX_BACKOFF" =~ ^[0-9]+$ ]]
    then
        log "PREFLIGHT" "ERROR" \
            "Retry backoff values must be non-negative integers"
        return 1
    fi

    if ! [[ "$PREFLIGHT_MIN_BUFFER_BYTES" =~ ^[0-9]+$ ]] ||
       ! [[ "$PREFLIGHT_BUFFER_PERCENT" =~ ^[0-9]+$ ]]
    then
        log "PREFLIGHT" "ERROR" \
            "Preflight buffer settings must be non-negative integers"
        return 1
    fi

    if ! [[ "$REMOTE_DF_RETRIES" =~ ^[0-9]+$ ]] ||
       [ "$REMOTE_DF_RETRIES" -lt 1 ]
    then
        log "PREFLIGHT" "ERROR" \
            "REMOTE_DF_RETRIES must be an integer >= 1"
        return 1
    fi

    for boolean_name in \
        SHUTDOWN_REMOTE_ON_SUCCESS \
        SHUTDOWN_REMOTE_ON_FAILURE \
        DEFER_REMOTE_SHUTDOWN_WHILE_MOVER \
        DEFER_REMOTE_SHUTDOWN_DURING_PARITY_CHECK \
        DEFER_REMOTE_SHUTDOWN_DURING_CRITICAL_ARRAY_OPERATION
    do
        boolean_value="${!boolean_name}"
        case "$boolean_value" in
            true|false)
                ;;
            *)
                log "PREFLIGHT" "ERROR" \
                    "${boolean_name} must be true or false"
                return 1
                ;;
        esac
    done

    for descriptor in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r \
            label \
            src \
            dest \
            extra_excludes \
            bwlimit \
            <<<"$descriptor"

        if [ -z "$label" ] ||
           [ -z "$src" ] ||
           [ -z "$dest" ]
        then
            log "PREFLIGHT" "ERROR" \
                "Invalid backup descriptor: $descriptor"
            return 1
        fi

        if [ -n "${seen_labels[$label]:-}" ]; then
            log "PREFLIGHT" "ERROR" \
                "Duplicate backup label: $label"
            return 1
        fi

        seen_labels["$label"]=1

        if ! backup_source_ready "$src"; then
            log "PREFLIGHT" "ERROR" \
                "Local source does not exist for ${label}: $src"
            return 1
        fi

        bwlimit="${bwlimit:-0}"

        if ! [[ "$bwlimit" =~ ^[0-9]+$ ]]; then
            log "PREFLIGHT" "ERROR" \
                "Invalid bandwidth limit for ${label}: $bwlimit"
            return 1
        fi
    done

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
# SSH HELPERS
###############################################################################

ssh_run() { local command_string; printf -v command_string '%q ' "$@"; BACKUP_SSH_COMMAND_TIMEOUT=30 backup_ssh "$command_string"; }
ssh_raw() { BACKUP_SSH_COMMAND_TIMEOUT=30 backup_ssh "$1"; }


classify_ssh_error() {
    local stderr="$1"
    local lower=""

    lower="$(
        printf '%s' "$stderr" |
            tr '[:upper:]' '[:lower:]'
    )"

    if printf '%s' "$lower" |
        grep -q 'permission denied'
    then
        printf 'Permission denied (authentication failed)'

    elif printf '%s' "$lower" |
        grep -q 'host key verification failed'
    then
        printf 'Host key verification failed'

    elif printf '%s' "$lower" |
        grep -q 'remote host identification has changed'
    then
        printf 'Remote host key changed'

    elif printf '%s' "$lower" |
        grep -q 'authenticity of host'
    then
        printf 'Host key is not trusted'

    elif printf '%s' "$lower" |
        grep -q 'connection refused'
    then
        printf 'Connection refused'

    elif printf '%s' "$lower" |
        grep -q 'no route to host'
    then
        printf 'No route to host'

    elif printf '%s' "$lower" |
        grep -q 'connection timed out'
    then
        printf 'Connection timed out'

    elif printf '%s' "$lower" |
        grep -q 'could not resolve hostname'
    then
        printf 'Hostname resolution failed'

    elif printf '%s' "$lower" |
        grep -q 'too many authentication failures'
    then
        printf 'Too many authentication failures'

    else
        printf 'SSH connection failure'
    fi
}


is_permanent_ssh_error() {
    local stderr="$1"
    local lower=""

    lower="$(
        printf '%s' "$stderr" |
            tr '[:upper:]' '[:lower:]'
    )"

    printf '%s' "$lower" |
        grep -Eq \
            'permission denied|host key verification failed|remote host identification has changed|authenticity of host|too many authentication failures'
}


###############################################################################
# WAKE / REMOTE READINESS
###############################################################################

wake_remote() {
    if [ "$ENABLE_WOL" != "true" ]; then
        log "REMOTE" "INFO" "Wake-on-LAN disabled"
        return 0
    fi

    if command -v etherwake >/dev/null 2>&1; then
        if etherwake "$REMOTE_MAC" >/dev/null 2>&1; then
            log "REMOTE" "INFO" \
                "Wake-on-LAN sent to ${DEST_NAS} (${REMOTE_MAC})"
        else
            log "REMOTE" "WARN" \
                "etherwake failed for ${REMOTE_MAC}; continuing with readiness checks"
        fi

    elif command -v wakeonlan >/dev/null 2>&1; then
        if wakeonlan "$REMOTE_MAC" >/dev/null 2>&1; then
            log "REMOTE" "INFO" \
                "Wake-on-LAN sent to ${DEST_NAS} (${REMOTE_MAC})"
        else
            log "REMOTE" "WARN" \
                "wakeonlan failed for ${REMOTE_MAC}; continuing with readiness checks"
        fi

    else
        log "REMOTE" "WARN" \
            "No Wake-on-LAN utility available; continuing without WOL"
    fi
}


remote_array_ready() {
    ssh_raw \
        'mountpoint -q /mnt/user 2>/dev/null || grep -qsE "[[:space:]]/mnt/user[[:space:]]" /proc/mounts'
}


wait_for_remote_ready() {
    local start=0
    local elapsed=0
    local array_start=0
    local ssh_error=""

    start="$(date +%s)"

    log "REMOTE" "INFO" \
        "Waiting up to ${MAX_SSH_WAIT}s for ${DEST_NAS} SSH"

    while :; do
        ssh_error=""

        if ssh_error="$(ssh_run true 2>&1)"; then
            elapsed=$(($(date +%s) - start))

            log "REMOTE" "INFO" \
                "SSH reachable after ${elapsed}s"

            break
        fi

        if is_permanent_ssh_error "$ssh_error"; then
            REMOTE_WAIT_ERROR="$(
                classify_ssh_error "$ssh_error"
            )"

            log "REMOTE" "ERROR" \
                "Permanent SSH failure: ${REMOTE_WAIT_ERROR}"

            return 1
        fi

        elapsed=$(($(date +%s) - start))

        if [ "$elapsed" -ge "$MAX_SSH_WAIT" ]; then
            REMOTE_WAIT_ERROR="$(
                classify_ssh_error "$ssh_error"
            )"

            log "REMOTE" "ERROR" \
                "SSH did not become reachable within ${MAX_SSH_WAIT}s"

            return 1
        fi

        sleep "$SSH_WAIT_INTERVAL"
    done

    array_start="$(date +%s)"

    log "REMOTE" "INFO" \
        "Waiting up to ${ARRAY_READY_WAIT}s for remote /mnt/user mount"

    while :; do
        if remote_array_ready >/dev/null 2>&1; then
            elapsed=$(($(date +%s) - array_start))

            log "REMOTE" "INFO" \
                "Remote /mnt/user confirmed mounted after ${elapsed}s"

            REMOTE_READY=1
            return 0
        fi

        elapsed=$(($(date +%s) - array_start))

        if [ "$elapsed" -ge "$ARRAY_READY_WAIT" ]; then
            REMOTE_WAIT_ERROR="Remote /mnt/user was not confirmed mounted"

            log "REMOTE" "ERROR" \
                "${REMOTE_WAIT_ERROR}; backup will NOT proceed"

            return 1
        fi

        sleep "$ARRAY_READY_INTERVAL"
    done
}


validate_remote_destinations() {
    local descriptor=""
    local label=""
    local src=""
    local dest=""
    local extra_excludes=""
    local bwlimit=""

    for descriptor in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r \
            label \
            src \
            dest \
            extra_excludes \
            bwlimit \
            <<<"$descriptor"

        if ! backup_destination "$label" "$src" "$dest"; then
            REMOTE_VALIDATION_ERROR="Remote destination missing for ${label}: ${dest}"

            log "REMOTE" "ERROR" \
                "$REMOTE_VALIDATION_ERROR"

            return 1
        fi

        log "REMOTE" "INFO" \
            "[${label}] destination confirmed: $dest"
    done

    return 0
}


###############################################################################
# RSYNC ARGUMENT CONSTRUCTION
###############################################################################

build_rsync_args() {
    local output_name="$1"
    local extra_excludes="$2"
    local bwlimit="${3:-0}"
    local mode="${4:-actual}"

    local -n output="$output_name"

    local pattern=""
    local -a extra_array=()

    local rsync_ssh_command="$RSYNC_RSH"

    output=(
        "${RSYNC_BASE_ARGS[@]}"
        "--timeout=$RSYNC_IO_TIMEOUT"
        "--max-delete=$MAX_DELETIONS"
        "--filter=P /.hubble-backup-identity"
        "--rsync-path=LC_ALL=C rsync"
        "${DEFAULT_EXCLUDES[@]}"
        -e "$rsync_ssh_command"
    )

    [[ "$PRESERVE_HARD_LINKS" != true ]] || output+=(-H)

    if [ -n "$extra_excludes" ]; then
        IFS=',' read -r -a extra_array <<<"$extra_excludes"

        for pattern in "${extra_array[@]}"; do
            [ -n "$pattern" ] || continue

            output+=(
                "--exclude=${pattern}"
            )
        done
    fi

    if [[ "$bwlimit" =~ ^[0-9]+$ ]] &&
       [ "$bwlimit" -gt 0 ]
    then
        output+=(
            "--bwlimit=${bwlimit}"
        )
    fi

    if [ "$mode" = "actual" ] &&
       [ "$LOG_ITEMIZED_CHANGES" = "true" ]
    then
        output+=(
            "--itemize-changes"
        )
    fi

    if [ "$mode" = "actual" ] &&
       [ "$DRY_RUN" = "true" ]
    then
        output+=(
            "--dry-run"
        )
    fi
}


###############################################################################
# RSYNC STATISTICS
###############################################################################

rsync_stat_number() {
    local file="$1"
    local heading="$2"
    local value=""

    value="$(
        grep -F "$heading" "$file" 2>/dev/null |
            tail -n 1 -- - |
            sed -E \
                's/^[^:]*:[[:space:]]*([0-9,]+).*/\1/' |
            tr -d ','
    )"

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$value"
    else
        printf '\n'
    fi
}


parse_rsync_stats() {
    local file="$1"
    local label="$2"

    local total=""
    local transferred=""
    local files=""
    local deleted=""
    local sent=""

    total="$(
        rsync_stat_number \
            "$file" \
            "Total file size"
    )"

    transferred="$(
        rsync_stat_number \
            "$file" \
            "Total transferred file size"
    )"

    files="$(
        rsync_stat_number \
            "$file" \
            "Number of regular files transferred"
    )"

    if [ -z "$files" ]; then
        files="$(
            rsync_stat_number \
                "$file" \
                "Number of files transferred"
        )"
    fi

    deleted="$(
        rsync_stat_number \
            "$file" \
            "Number of deleted files"
    )"

    sent="$(
        rsync_stat_number \
            "$file" \
            "Total bytes sent"
    )"

    TOTAL_BYTES["$label"]="${total:-0}"
    TRANSFERRED_BYTES["$label"]="${transferred:-0}"
    FILES_TRANSFERRED["$label"]="${files:-0}"
    DELETED_FILES["$label"]="${deleted:-0}"
    BYTES_SENT["$label"]="${sent:-0}"
}


###############################################################################
# REMOTE SPACE
###############################################################################

remote_df() {
    local dest="$1"

    local attempt=1
    # shellcheck disable=SC2178
    local output=""

    while [ "$attempt" -le "$REMOTE_DF_RETRIES" ]; do
        # shellcheck disable=SC2178
        output="$(
            ssh_run \
                df \
                -P \
                -B1 \
                -- \
                "$dest" \
                2>/dev/null |
                awk \
                    'NR == 2 {print $1 "|" $4 "|" $6}'
        )"

        # shellcheck disable=SC2128
        if [ -n "$output" ]; then
            printf '%s\n' "$output"
            return 0
        fi

        if [ "$attempt" -lt "$REMOTE_DF_RETRIES" ]; then
            sleep "$REMOTE_DF_RETRY_SLEEP"
        fi

        attempt=$((attempt + 1))
    done

    return 1
}


estimate_job_change() {
    local label="$1"
    local src="$2"
    local dest="$3"
    local extra_excludes="$4"
    local bwlimit="$5"

    local tmp_log=""
    local status=0
    local estimated=""
    local excerpt=""

    local -a rsync_args=()
    local -a command=()

    tmp_log="$(mktemp /tmp/backup_media_remote_estimate.XXXXXX)"

    build_rsync_args \
        rsync_args \
        "$extra_excludes" \
        "$bwlimit" \
        "preflight"

    rsync_args+=(
        "--dry-run"
    )

    command=(
        "${PRIORITY_PREFIX[@]}"
        rsync
        "${rsync_args[@]}"
        "${src%/}/"
        "${REMOTE}:${dest%/}/"
    )

    log "PREFLIGHT" "INFO" \
        "[${label}] estimating changed data with rsync dry-run"

    "${command[@]}" >"$tmp_log" 2>&1
    status=$?

    if [ "$status" -ne 0 ]; then
        excerpt="$(
            extract_rsync_errors \
                "$tmp_log" \
                "$NOTIFY_EXCERPT_LINES"
        )"

        PREFLIGHT_FAILURE_DETAIL="Rsync estimate failed for ${label}: exit ${status}
${excerpt}"

        log "PREFLIGHT" "ERROR" \
            "[${label}] rsync estimate failed with exit=${status}"

        rm -f -- "$tmp_log"
        return 1
    fi

    estimated="$(
        rsync_stat_number \
            "$tmp_log" \
            "Total transferred file size"
    )"

    estimated="${estimated:-0}"

    ESTIMATED_BYTES["$label"]="$estimated"

    log "PREFLIGHT" "INFO" \
        "[${label}] estimated transfer: $(bytes_to_human "$estimated")"

    rm -f -- "$tmp_log"

    return 0
}


preflight_space() {
    local descriptor=""
    local label=""
    local src=""
    local dest=""
    local extra_excludes=""
    local bwlimit=""

    local estimated=0

    local df_output=""
    local device=""
    local available=0
    local mountpoint=""

    local needed=0
    local percentage_buffer=0
    local safety_buffer=0

    local -A required_by_device=()
    local -A available_by_device=()
    local -A mount_by_device=()

    PREFLIGHT_FAILURE_DETAIL=""

    for descriptor in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r \
            label \
            src \
            dest \
            extra_excludes \
            bwlimit \
            <<<"$descriptor"

        bwlimit="${bwlimit:-0}"

        case "$PREFLIGHT_MODE" in
            estimate)
                if ! estimate_job_change \
                    "$label" \
                    "$src" \
                    "$dest" \
                    "$extra_excludes" \
                    "$bwlimit"
                then
                    return 1
                fi

                estimated="${ESTIMATED_BYTES[$label]:-0}"
                ;;

            total)
                estimated="$(safe_size_bytes "$src")"
                ESTIMATED_BYTES["$label"]="$estimated"

                log "PREFLIGHT" "INFO" \
                    "[${label}] conservative total-size estimate: $(bytes_to_human "$estimated")"
                ;;
        esac

        if ! df_output="$(remote_df "$dest")"; then
            PREFLIGHT_FAILURE_DETAIL="Unable to query remote filesystem space for ${label}: ${dest}"

            log "PREFLIGHT" "ERROR" \
                "$PREFLIGHT_FAILURE_DETAIL"

            return 1
        fi

        IFS='|' read -r \
            device \
            available \
            mountpoint \
            <<<"$df_output"

        if ! [[ "$available" =~ ^[0-9]+$ ]]; then
            PREFLIGHT_FAILURE_DETAIL="Invalid remote free-space value for ${label}: ${available}"

            log "PREFLIGHT" "ERROR" \
                "$PREFLIGHT_FAILURE_DETAIL"

            return 1
        fi

        DEST_FREE_BYTES["$dest"]="$available"

        required_by_device["$device"]=$(( ${required_by_device["$device"]:-0} + estimated ))

        available_by_device["$device"]="$available"
        mount_by_device["$device"]="$mountpoint"
    done

    for device in "${!required_by_device[@]}"; do
        needed="${required_by_device[$device]:-0}"
        available="${available_by_device[$device]:-0}"
        mountpoint="${mount_by_device[$device]:-unknown}"

        percentage_buffer=$(( needed * PREFLIGHT_BUFFER_PERCENT / 100 ))

        if [ "$percentage_buffer" -lt "$PREFLIGHT_MIN_BUFFER_BYTES" ]; then
            safety_buffer="$PREFLIGHT_MIN_BUFFER_BYTES"
        else
            safety_buffer="$percentage_buffer"
        fi

        log "PREFLIGHT" "INFO" \
            "Filesystem ${device} (${mountpoint}): estimated=$(bytes_to_human "$needed"), buffer=$(bytes_to_human "$safety_buffer"), available=$(bytes_to_human "$available")"

        if [ "$available" -lt $((needed + safety_buffer)) ]; then
            PREFLIGHT_FAILURE_DETAIL="Insufficient remote space on ${device} (${mountpoint})
Estimated transfer: $(bytes_to_human "$needed")
Safety buffer: $(bytes_to_human "$safety_buffer")
Available: $(bytes_to_human "$available")"

            log "PREFLIGHT" "ERROR" \
                "Insufficient space on ${device}: need $(bytes_to_human "$((needed + safety_buffer))"), available $(bytes_to_human "$available")"

            return 1
        fi
    done

    log "PREFLIGHT" "INFO" \
        "Aggregate remote-space preflight passed"

    return 0
}


###############################################################################
# RETRY HELPERS
###############################################################################

rsync_should_retry() {
    local code="$1"

    array_contains \
        "$code" \
        "${RETRY_CODES[@]}"
}


compute_backoff() {
    local failed_attempt="$1"

    local seconds="$RETRY_BACKOFF"

    if [ "$ENABLE_EXPONENTIAL_BACKOFF" = "true" ]; then
        seconds=$(( RETRY_BACKOFF * (2 ** (failed_attempt - 1)) ))
    fi

    if [ "$seconds" -gt "$MAX_BACKOFF" ]; then
        seconds="$MAX_BACKOFF"
    fi

    printf '%s\n' "$seconds"
}


###############################################################################
# RSYNC ERROR HANDLING
###############################################################################

rsync_exit_description() {
    local code="${1:-0}"

    case "$code" in
        0)   printf 'Success' ;;
        1)   printf 'Syntax or usage error' ;;
        2)   printf 'Protocol incompatibility' ;;
        3)   printf 'Input/output selection error' ;;
        4)   printf 'Requested action not supported' ;;
        5)   printf 'Client/server protocol startup error' ;;
        6)   printf 'Daemon log-file error' ;;
        10)  printf 'Socket I/O error' ;;
        11)  printf 'File I/O error' ;;
        12)  printf 'Protocol data-stream error' ;;
        13)  printf 'Program diagnostics error' ;;
        14)  printf 'IPC error' ;;
        20)  printf 'Interrupted by signal' ;;
        21)  printf 'waitpid error' ;;
        22)  printf 'SIGPIPE / broken pipe' ;;
        23)  printf 'Partial transfer due to error' ;;
        24)  printf 'Partial transfer due to vanished source files' ;;
        30)  printf 'Data-transfer timeout' ;;
        74)  printf 'Completion evidence or diagnostics unavailable' ;;
        255) printf 'SSH connection failure' ;;
        *)   printf 'Unknown rsync exit code %s' "$code" ;;
    esac
}


extract_rsync_errors() {
    local file="$1"
    local max_lines="${2:-8}"

    local excerpt=""

    if [ ! -f "$file" ]; then
        printf '(no rsync raw log)'
        return 0
    fi

    excerpt="$(
        grep -iE \
            'error|warning|failed|permission denied|host key|connection refused|no route|timed out|timeout' \
            "$file" \
            2>/dev/null |
            tail -n "$max_lines" -- - ||
            true
    )"

    if [ -n "$excerpt" ]; then
        printf '%s\n' "$excerpt"
    else
        tail \
            -n "$max_lines" \
            "$file" \
            2>/dev/null ||
            printf '(no rsync output)'
    fi
}


###############################################################################
# RAW RSYNC LOGGING
###############################################################################

preserve_raw_log() {
    local label="$1"
    local attempt="$2"
    local status="$3"
    local source_file="$4"

    local safe_label=""
    local result=""
    local destination=""

    safe_label="$(safe_name "$label")"

    if [ "$status" -eq 0 ]; then
        result="success"
    else
        result="fail"
    fi

    destination="${RAW_LOG_DIR}/rsync_${safe_label}_${RUN_STAMP}_attempt${attempt}_${result}.log"

    if cp -- "$source_file" "$destination" 2>/dev/null; then
        printf '%s\n' "$destination"
        return 0
    fi

    printf '\n'
    return 1
}


###############################################################################
# RSYNC BACKUP
###############################################################################

rsync_label() {
    local label="$1"
    local src="$2"
    local dest="$3"
    local extra_excludes="$4"
    local bwlimit="${5:-0}"

    local attempt=1
    local status=0
    local description=""
    local sleep_seconds=0

    local tmp_log=""
    local saved_log=""
    local command_string=""

    local -a rsync_args=()
    local -a command=()

    RESULT_CODE["$label"]=1
    RESULT_REASON["$label"]="Not run"

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        tmp_log="$(mktemp /tmp/backup_media_remote_rsync.XXXXXX)"

        build_rsync_args \
            rsync_args \
            "$extra_excludes" \
            "$bwlimit" \
            "actual"

        command=(
            "${PRIORITY_PREFIX[@]}"
            rsync
            "${rsync_args[@]}"
            "${src%/}/"
            "${REMOTE}:${dest%/}/"
        )

        printf -v command_string '%q ' "${command[@]}"

        log "RSYNC" "INFO" \
            "[${label}] attempt ${attempt}/${MAX_RETRIES}"

        log "RSYNC" "INFO" \
            "[${label}] running: ${command_string}"

        if ! backup_source_ready "$src" || ! backup_lease_alive; then
            RESULT_REASON[$label]="Source mount/identity changed or ISS lease lost"
            FAILED_LABELS+=("$label")
            return 1
        fi
        local job_started job_elapsed
        job_started=$(date +%s)
        LC_ALL=C "${command[@]}" 2>&1 | tail -c "$MAX_RAW_LOG_BYTES" -- - >"$tmp_log"
        local -a transfer_status=("${PIPESTATUS[@]}")
        status="${transfer_status[0]}"
        if ((transfer_status[1]!=0));then status=74;BACKUP_LAST_ERROR="[$label] Transfer diagnostics could not be written; completion evidence unavailable";fi
        job_elapsed=$(( $(date +%s)-job_started ))
        tail -n 35 -- "$tmp_log" >>"$LOG_FILE"
        log RSYNC INFO "[$label] attempt duration=${job_elapsed}s"

        parse_rsync_stats \
            "$tmp_log" \
            "$label"
        log RSYNC INFO "[$label] measured network average=$(bytes_to_human "$(( ${BYTES_SENT[$label]:-0} / (job_elapsed > 0 ? job_elapsed : 1) ))")/s"

        saved_log="$(
            preserve_raw_log \
                "$label" \
                "$attempt" \
                "$status" \
                "$tmp_log"
        )"

        if [ -n "$saved_log" ]; then
            RAW_LOG_BY_LABEL["$label"]="$saved_log"
        fi

        if ((status==0));then
            if ! grep -q '^Total bytes sent:' "$tmp_log" || ! grep -q '^Number of files:' "$tmp_log" || ! backup_source_ready "$src" || ! backup_lease_alive;then
                status=74;BACKUP_LAST_ERROR="[$label] Transfer returned zero but statistics or final source/lease evidence is incomplete"
            fi
        fi
        if [ "$status" -eq 0 ]; then
            RESULT_CODE["$label"]=0
            RESULT_REASON["$label"]="Success"

            log "RSYNC" "INFO" \
                "[${label}] completed successfully"

            rm -f -- "$tmp_log"

            return 0
        fi

        description="$(rsync_exit_description "$status")"

        RESULT_CODE["$label"]="$status"
        RESULT_REASON["$label"]="$description"

        log "RSYNC" "ERROR" \
            "[${label}] attempt ${attempt} failed: exit=${status} (${description})"

        # Authentication / host-key problems will not be fixed by retrying.
        if [ "$status" -eq 255 ] &&
           is_permanent_ssh_error "$(cat "$tmp_log" 2>/dev/null)"
        then
            RESULT_REASON["$label"]="$(
                classify_ssh_error \
                    "$(cat "$tmp_log" 2>/dev/null)"
            )"

            log "RSYNC" "ERROR" \
                "[${label}] permanent SSH failure; retries stopped"

            rm -f -- "$tmp_log"
            break
        fi

        if ! rsync_should_retry "$status"; then
            log "RSYNC" "ERROR" \
                "[${label}] exit=${status} is not retryable"

            rm -f -- "$tmp_log"
            break
        fi

        if [ "$attempt" -ge "$MAX_RETRIES" ]; then
            rm -f -- "$tmp_log"
            break
        fi

        sleep_seconds="$(
            compute_backoff "$attempt"
        )"

        log "RSYNC" "WARN" \
            "[${label}] retrying in ${sleep_seconds}s"

        rm -f -- "$tmp_log"

        sleep "$sleep_seconds"

        attempt=$((attempt + 1))
    done

    FAILED_LABELS+=("$label")

    log "RSYNC" "ERROR" \
        "[${label}] final failure: exit=${RESULT_CODE[$label]} (${RESULT_REASON[$label]})"

    return 1
}


run_all_backups() {
    local descriptor=""
    local label=""
    local src=""
    local dest=""
    local extra_excludes=""
    local bwlimit=""

    local failed=0

    for descriptor in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r \
            label \
            src \
            dest \
            extra_excludes \
            bwlimit \
            <<<"$descriptor"

        bwlimit="${bwlimit:-0}"

        log "BACKUP" "INFO" \
            "Starting ${label}: ${src} -> ${DEST_NAS}:${dest}"

        if ! rsync_label \
            "$label" \
            "$src" \
            "$dest" \
            "$extra_excludes" \
            "$bwlimit"
        then
            failed=1
        fi
    done

    return "$failed"
}


###############################################################################
# REPORT SPACE REFRESH
###############################################################################

refresh_remote_space_for_report() {
    local descriptor=""
    local label=""
    local src=""
    local dest=""
    local extra_excludes=""
    local bwlimit=""

    local df_output=""
    local device=""
    local available=""
    local mountpoint=""

    for descriptor in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r \
            label \
            src \
            dest \
            extra_excludes \
            bwlimit \
            <<<"$descriptor"

        if df_output="$(remote_df "$dest")"; then
            IFS='|' read -r \
                device \
                available \
                mountpoint \
                <<<"$df_output"

            if [[ "$available" =~ ^[0-9]+$ ]]; then
                DEST_FREE_BYTES["$dest"]="$available"
            fi
        fi
    done
}


###############################################################################
# REMOTE SHUTDOWN
###############################################################################

remote_shutdown_blockers() {
    BACKUP_SSH_COMMAND_TIMEOUT=30 backup_ssh \
        bash -s -- \
        "$DEFER_REMOTE_SHUTDOWN_WHILE_MOVER" \
        "$DEFER_REMOTE_SHUTDOWN_DURING_PARITY_CHECK" \
        "$DEFER_REMOTE_SHUTDOWN_DURING_CRITICAL_ARRAY_OPERATION" \
        <<'REMOTE_ACTIVITY_PROBE'
defer_mover="$1"
defer_parity_check="$2"
defer_critical_operation="$3"

case "${defer_mover}:${defer_parity_check}:${defer_critical_operation}" in
    true:true:true|true:true:false|true:false:true|true:false:false|\
    false:true:true|false:true:false|false:false:true|false:false:false)
        ;;
    *)
        exit 3
        ;;
esac

if [ "$defer_mover" = true ]; then
    command -v pgrep >/dev/null 2>&1 || exit 3
    if pgrep -f '(^|/)(mover|mover\.old)( |$)|mover\.php' >/dev/null 2>&1; then
        printf '%s\n' 'Mover is active'
    fi
fi

if [ "$defer_parity_check" != true ] &&
   [ "$defer_critical_operation" != true ]; then
    exit 0
fi

if [ -x /usr/local/sbin/mdcmd ]; then
    mdcmd_bin=/usr/local/sbin/mdcmd
elif command -v mdcmd >/dev/null 2>&1; then
    mdcmd_bin=mdcmd
else
    exit 3
fi

md_status="$($mdcmd_bin status 2>/dev/null)" || exit 3
printf '%s\n' "$md_status" | awk -F= '
    function clean(value) {
        gsub(/^[[:space:]"\r]+|[[:space:]"\r]+$/, "", value)
        return value
    }
    tolower($1) == "mdresyncaction" { action=clean($2) }
    tolower($1) == "mdresync"       { resync=clean($2) }
    tolower($1) == "mdresyncpos"    { pos=clean($2) }
    END {
        if (!(resync ~ /^[0-9]+$/) || !(pos ~ /^[0-9]+$/)) exit 3

        action_lc=tolower(action)
        active=(resync + 0 > 0 || pos + 0 > 0)
        if (!active) exit

        state=(resync + 0 > 0 ? "active" : "paused")
        if (action_lc ~ /^check([[:space:]]|$)/) {
            if (defer_parity_check == "true")
                printf "Parity check is %s (%s)\n", state, action
        } else if (defer_critical_operation == "true") {
            if (action != "")
                printf "Critical array operation is %s (%s)\n", state, action
            else
                printf "Critical array operation is %s\n", state
        }
    }
' \
    defer_parity_check="$defer_parity_check" \
    defer_critical_operation="$defer_critical_operation"
REMOTE_ACTIVITY_PROBE
}

shutdown_remote() {
    local backup_failed="$1"
    local should_shutdown=false
    local blockers=""
    local blocker_status=0

    backup_lease_alive || { REMOTE_SHUTDOWN_SKIPPED_REASON="Shared ISS lease is not held"; return 0; }
    if [ "$REMOTE_READY" -ne 1 ]; then
        return 0
    fi

    if [ "$DRY_RUN" = "true" ]; then
        log "REMOTE" "INFO" \
            "DRY_RUN=true; remote shutdown skipped"

        return 0
    fi

    if [ "$backup_failed" -eq 0 ] &&
       [ "$SHUTDOWN_REMOTE_ON_SUCCESS" = "true" ]
    then
        should_shutdown=true
    fi

    if [ "$backup_failed" -ne 0 ] &&
       [ "$SHUTDOWN_REMOTE_ON_FAILURE" = "true" ]
    then
        should_shutdown=true
    fi

    if [ "$should_shutdown" != "true" ]; then
        if [ "$backup_failed" -ne 0 ]; then
            log "REMOTE" "INFO" \
                "Remote NAS left running because backup failed and SHUTDOWN_REMOTE_ON_FAILURE=false"
        fi

        return 0
    fi

    if ! backup_shutdown_handoff; then log REMOTE INFO "$REMOTE_SHUTDOWN_SKIPPED_REASON"; return 0; fi
    blockers="$(remote_shutdown_blockers 2>/dev/null)"
    blocker_status=$?

    if [ "$blocker_status" -ne 0 ]; then
        REMOTE_SHUTDOWN_SKIPPED_REASON="Mover/parity status could not be verified"
        log "REMOTE" "WARN" \
            "Remote shutdown skipped: ${REMOTE_SHUTDOWN_SKIPPED_REASON}. ${DEST_NAS} will remain powered on."
        return 0
    fi

    if [ -n "$blockers" ]; then
        REMOTE_SHUTDOWN_SKIPPED_REASON="${blockers//$'\n'/; }"
        log "REMOTE" "WARN" \
            "Remote shutdown skipped: ${REMOTE_SHUTDOWN_SKIPPED_REASON}. ${DEST_NAS} will remain powered on."
        return 0
    fi

    REMOTE_SHUTDOWN_REQUESTED=1

    log "REMOTE" "INFO" \
        "Requesting shutdown of ${DEST_NAS}"

    backup_phase shutdown
    if backup_request_shutdown
    then
        SHUTDOWN_RESULT=requested
        log "REMOTE" "INFO" "Shutdown request accepted; observing remote network reachability"
        usr_ops_observe_shutdown || log REMOTE WARNING 'ISS still answers after the bounded shutdown allowance; no second shutdown was sent'
        log REMOTE INFO "Remote shutdown evidence: $SHUTDOWN_RESULT (network reachability, not physical power telemetry)"
    else
        REMOTE_SHUTDOWN_FAILED=1
        SHUTDOWN_RESULT=failed_or_unconfirmed

        log "REMOTE" "ERROR" \
            "Failed to send shutdown command to ${DEST_NAS}"

        return 1
    fi

    return 0
}


###############################################################################
# RETENTION
###############################################################################

prune_main_logs() {
    local -a logs=()
    local removed=0

    mapfile -t logs < <(
        find "$LOG_DIR" \
            -maxdepth 1 \
            -type f \
            -name 'backup_media_remote_*.log' \
            -printf '%T@\t%p\n' \
            2>/dev/null |
            sort -nr |
            cut -f2-
    )

    while [ "${#logs[@]}" -gt "$MAX_LOGS" ]; do
        rm -f -- "${logs[-1]}"
        unset 'logs[-1]'
        logs=("${logs[@]}")
        removed=$((removed + 1))
    done

    if [ "$removed" -gt 0 ]; then
        log "CLEANUP" "INFO" \
            "Removed ${removed} old main log(s)"
    fi
}


prune_raw_logs() {
    local descriptor=""
    local label=""
    local src=""
    local dest=""
    local extra_excludes=""
    local bwlimit=""

    local safe_label=""
    local removed=0

    local -a logs=()

    for descriptor in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r \
            label \
            src \
            dest \
            extra_excludes \
            bwlimit \
            <<<"$descriptor"

        safe_label="$(safe_name "$label")"

        logs=()

        mapfile -t logs < <(
            find "$RAW_LOG_DIR" \
                -maxdepth 1 \
                -type f \
                -name "rsync_${safe_label}_*.log" \
                -printf '%T@\t%p\n' \
                2>/dev/null |
                sort -nr |
                cut -f2-
        )

        while [ "${#logs[@]}" -gt "$MAX_RAW_LOGS" ]; do
            rm -f -- "${logs[-1]}"
            unset 'logs[-1]'
            logs=("${logs[@]}")
            removed=$((removed + 1))
        done
    done

    if [ "$removed" -gt 0 ]; then
        log "CLEANUP" "INFO" \
            "Removed ${removed} old raw rsync log(s)"
    fi
}


prune_old_artifacts() {
    local file
    prune_main_logs && prune_raw_logs || { RETENTION_RESULT=FAILED; return 1; }
    while IFS= read -r -d '' file; do backup_bound_log "$file" "$MAX_MAIN_LOG_BYTES" || return 1; done < <(find "$LOG_DIR" -maxdepth 1 -type f -name 'backup_media_remote_*.log' -print0)
    while IFS= read -r -d '' file; do backup_bound_log "$file" "$MAX_RAW_LOG_BYTES" || return 1; done < <(find "$RAW_LOG_DIR" -maxdepth 1 -type f -name 'rsync_*.log' -print0)
    RETENTION_RESULT=OK
}


###############################################################################
# FINAL NOTIFICATION
###############################################################################

send_final_notification() {
    local backup_failed="$1"
    local runtime_human="$2"

    local level="normal"
    local overall_status="OK"

    local descriptor=""
    local label=""
    local src=""
    local dest=""
    local extra_excludes=""
    local bwlimit=""

    local code=0
    local total=0
    local transferred=0
    local files=0
    local deleted=0
    local sent=0
    local estimated=0
    local free=0

    local raw_log=""
    local excerpt=""

    local body=""

    if [ "$backup_failed" -ne 0 ]; then
        level="alert"
        overall_status="FAILED"

    elif [ "$REMOTE_SHUTDOWN_FAILED" -ne 0 ] || { [ -n "$REMOTE_SHUTDOWN_SKIPPED_REASON" ] && [ "$SHUTDOWN_RESULT" != deferred ]; } || [ "$RETENTION_RESULT" = FAILED ]; then
        level="warning"
        overall_status="OK - shutdown or retention requires review"
    fi

    body+="Mode: "

    if [ "$DRY_RUN" = "true" ]; then
        body+="DRY RUN"
    else
        body+="LIVE"
    fi

    body+=$'\n'
    body+="Version: ${SCRIPT_VERSION}; retention: ${RETENTION_RESULT}"$'\n'
    body+="Runtime: ${runtime_human}"$'\n'
    body+="Route: ${SRC_NAS} -> ${DEST_NAS}"$'\n'
    body+=$'\n'

    for descriptor in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r \
            label \
            src \
            dest \
            extra_excludes \
            bwlimit \
            <<<"$descriptor"

        code="${RESULT_CODE[$label]:-1}"

        total="${TOTAL_BYTES[$label]:-0}"
        transferred="${TRANSFERRED_BYTES[$label]:-0}"
        files="${FILES_TRANSFERRED[$label]:-0}"
        deleted="${DELETED_FILES[$label]:-0}"
        sent="${BYTES_SENT[$label]:-0}"

        estimated="${ESTIMATED_BYTES[$label]:-0}"
        free="${DEST_FREE_BYTES[$dest]:-0}"

        if [ "$code" -eq 0 ]; then
            body+="[OK] ${label}"$'\n'
        else
            body+="[FAILED] ${label}: exit=${code} (${RESULT_REASON[$label]:-Unknown failure})"$'\n'
        fi

        body+="  Total source:      $(bytes_to_human "$total")"$'\n'
        body+="  Estimated change:  $(bytes_to_human "$estimated")"$'\n'
        body+="  Transferred:       $(bytes_to_human "$transferred")"$'\n'
        body+="  Files transferred: ${files}"$'\n'
        body+="  Files deleted:     ${deleted}"$'\n'
        body+="  Network sent:      $(bytes_to_human "$sent")"$'\n'

        if [ "$free" -gt 0 ]; then
            body+="  Remote free:       $(bytes_to_human "$free")"$'\n'
        fi

        if [ "$code" -ne 0 ]; then
            raw_log="${RAW_LOG_BY_LABEL[$label]:-}"

            if [ -n "$raw_log" ] &&
               [ -f "$raw_log" ]
            then
                excerpt="$(
                    extract_rsync_errors \
                        "$raw_log" \
                        "$NOTIFY_EXCERPT_LINES"
                )"

                body+="  Recent error output:"$'\n'
                body+="${excerpt}"$'\n'
            fi
        fi

        body+=$'\n'
    done

    if [ "$REMOTE_SHUTDOWN_REQUESTED" -eq 1 ]; then
        if [ "$REMOTE_SHUTDOWN_FAILED" -eq 0 ]; then
            body+="Remote shutdown: $SHUTDOWN_RESULT; network observation does not prove physical power state"$'\n'
        else
            body+="Remote shutdown: FAILED"$'\n'
        fi
    elif [ -n "$REMOTE_SHUTDOWN_SKIPPED_REASON" ]; then
        body+="Remote shutdown: skipped (${REMOTE_SHUTDOWN_SKIPPED_REASON}); ${DEST_NAS} left powered on"$'\n'
    elif [ "$DRY_RUN" = "true" ]; then
        body+="Remote shutdown: skipped for dry run"$'\n'
    elif [ "$backup_failed" -ne 0 ]; then
        body+="Remote shutdown: skipped after backup failure"$'\n'
    fi

    body+="Log: ${LOG_FILE}"

    notify_unraid \
        "$level" \
        "${SRC_NAS} -> ${DEST_NAS} - ${overall_status}" \
        "$body"
}


###############################################################################
# ABORT NOTIFICATION
###############################################################################

send_abort_notification() {
    local description="$1"
    local detail="$2"

    local runtime_seconds=0
    local runtime_human=""

    runtime_seconds=$(($(date +%s) - START_TIME))
    runtime_human="$(format_duration "$runtime_seconds")"

    notify_unraid \
        "alert" \
        "$description" \
        "${detail}

Runtime: ${runtime_human}
Log: ${LOG_FILE}"
}


###############################################################################
# MAIN
###############################################################################

main() {
    case "${1:-}" in
      --evidence-status) jq -n --arg scope 'Producer receipts only; no transfer, SSH or wake performed' \
        --slurpfile success <(if [[ -f "$STATUS_DIR/backup_media_remote.last-success.json" ]];then cat "$STATUS_DIR/backup_media_remote.last-success.json";else printf null;fi) \
        --slurpfile attempt <(if [[ -f "$STATUS_DIR/backup_media_remote.last-attempt.json" ]];then cat "$STATUS_DIR/backup_media_remote.last-attempt.json";else printf null;fi) \
        '{scope:$scope,lastVerifiedSuccess:$success[0],lastFailedAttempt:$attempt[0]}';return $?;;
      --version) printf 'backup_media_remote.sh %s\n' "$SCRIPT_VERSION";return 0;;
      '') ;; *) printf 'Usage: bash script [--evidence-status|--version]\n';return 2;;
    esac
    exec 9>"$LOCK_FILE"

    if ! flock -n 9; then
        printf '%s %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "Another backup_media_remote.sh run is active, exiting (lock: $LOCK_FILE)"

        exit 1
    fi

    trap backup_finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 141' PIPE
    backup_transport_init || return 1
    local backup_failed=0

    local runtime_seconds=0
    local runtime_human=""

    # -----------------------------------------------------------------------
    # Logging initialization
    # -----------------------------------------------------------------------

    mountpoint -q /mnt/user || { printf 'Local /mnt/user is not mounted\n' >&2; return 1; }
    if ! ensure_dir "$LOG_DIR"; then
        printf '%s ERROR: Unable to create log directory: %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$LOG_DIR"

        return 1
    fi

    if ! ensure_dir "$RAW_LOG_DIR"; then
        printf '%s ERROR: Unable to create raw log directory: %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$RAW_LOG_DIR"

        return 1
    fi

    if ! : >"$LOG_FILE"; then
        printf '%s ERROR: Unable to create log file: %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$LOG_FILE"

        return 1
    fi

    START_TIME="$(date +%s)"

    log "BACKUP" "INFO" \
        "Remote backup started"

    log "BACKUP" "INFO" \
        "Source NAS: ${SRC_NAS}"

    log "BACKUP" "INFO" \
        "Destination NAS: ${DEST_NAS}"

    if [ "$DRY_RUN" = "true" ]; then
        log "BACKUP" "WARN" \
            "DRY_RUN=true; no destination files will be modified"
    fi


    # -----------------------------------------------------------------------
    # Local preflight
    # -----------------------------------------------------------------------

    if ! validate_configuration; then
        send_abort_notification \
            "Remote Backup - Configuration FAILED" \
            "Local configuration or source-path validation failed."

        prune_old_artifacts

        return 1
    fi

    build_priority_prefix

    prune_old_artifacts


    # -----------------------------------------------------------------------
    # Wake remote
    # -----------------------------------------------------------------------

    wake_remote


    # -----------------------------------------------------------------------
    # Wait for SSH + array mount
    # -----------------------------------------------------------------------

    if ! wait_for_remote_ready; then
        send_abort_notification \
            "Remote Backup - Remote Unavailable" \
            "${DEST_NAS} did not become ready.

Reason: ${REMOTE_WAIT_ERROR}"

        prune_old_artifacts

        return 1
    fi


    backup_phase capabilities
    backup_capabilities || { log REMOTE ERROR "Local/ISS capability validation failed; no backup was published. ISS is left available for retry."; return 1; }
    backup_acquire_lease || { log REMOTE ERROR "ISS is already in use by another backup, or lease acquisition failed"; return 1; }

    # -----------------------------------------------------------------------
    # Validate configured remote destinations
    # -----------------------------------------------------------------------

    if ! validate_remote_destinations; then
        shutdown_remote 1 || true

        send_abort_notification \
            "Remote Backup - Destination FAILED" \
            "${REMOTE_VALIDATION_ERROR}

No rsync was started."

        prune_old_artifacts

        return 1
    fi


    # -----------------------------------------------------------------------
    # Aggregate space preflight
    # -----------------------------------------------------------------------

    backup_phase preflight
    if ! preflight_space; then
        shutdown_remote 1 || true

        send_abort_notification \
            "Remote Backup - Preflight FAILED" \
            "${PREFLIGHT_FAILURE_DETAIL}

No live rsync was started."

        prune_old_artifacts

        return 1
    fi


    # -----------------------------------------------------------------------
    # Rsync backup jobs
    # -----------------------------------------------------------------------

    backup_phase transfer
    if ! run_all_backups; then
        backup_failed=1
        BACKUP_RESULT=FAILED; VERIFICATION_RESULT=FAILED
    else
        if [[ "$DRY_RUN" == true ]]; then BACKUP_RESULT=DRY_RUN; VERIFICATION_RESULT=not_performed
        else
            BACKUP_RESULT=OK; VERIFICATION_RESULT=rsync_transfer_verified
            if ! media_completion_evidence OK transfer;then
                backup_failed=1;BACKUP_RESULT=FAILED;VERIFICATION_RESULT=not_verified
                log EVIDENCE ERROR 'Copy completed but durable completion evidence could not be published; previous verified receipt retained'
            fi
        fi
    fi


    # -----------------------------------------------------------------------
    # Refresh remote free-space information before optional shutdown
    # -----------------------------------------------------------------------

    refresh_remote_space_for_report || true


    # -----------------------------------------------------------------------
    # Optional remote shutdown
    # -----------------------------------------------------------------------

    shutdown_remote "$backup_failed" || true


    # -----------------------------------------------------------------------
    # Runtime / final notification
    # -----------------------------------------------------------------------

    runtime_seconds=$(($(date +%s) - START_TIME))
    runtime_human="$(format_duration "$runtime_seconds")"

    if [ "$backup_failed" -eq 0 ]; then
        log "BACKUP" "INFO" \
            "Remote backup completed successfully in ${runtime_human}"
    else
        log "BACKUP" "ERROR" \
            "Remote backup completed with failures in ${runtime_human}"
    fi

    prune_old_artifacts || RETENTION_RESULT=FAILED
    backup_phase notification
    send_final_notification \
        "$backup_failed" \
        "$runtime_human"


    # -----------------------------------------------------------------------
    # Retention
    # -----------------------------------------------------------------------



    # -----------------------------------------------------------------------
    # Exit status
    # -----------------------------------------------------------------------

    if [ "$backup_failed" -ne 0 ] ||
       [ "$REMOTE_SHUTDOWN_FAILED" -ne 0 ]
    then
        return 1
    fi

    return 0
}


###############################################################################
# ENTRY POINT
###############################################################################

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
