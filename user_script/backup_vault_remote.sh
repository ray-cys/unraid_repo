#!/bin/bash
clearLog=true

###############################################################################
# Hubble -> ISS: completion-driven vault backup consumer
#
# GitHub source: user_script/backup_vault_remote.sh
# Installed Unraid User Scripts entry: backup_vault_remote (its file is "script").
#
# PURPOSE
# Keep a separately restorable copy on ISS if Hubble or its local vault fails.
# Back up the newest completed appdata generation, flash backup, User Scripts,
# GitHub working directories, photos and compact operational state. This script
# transfers existing backups; backup_cache_appdata.sh remains the appdata producer.
#
# WHY IT IS SCHEDULED HOURLY
# Use 10 * * * * (hourly at minute 10, Singapore time). Each invocation is a short
# queue check, not a resident daemon or an unconditional hourly full backup.
# backup_cache_appdata.sh publishes iss-backup-request.json only after completing and
# verifying a local generation and checking container restart requirements.
# With no request, or an already acknowledged generation, exit before transport,
# WOL, backup log creation, payload enumeration, pruning or notifications.
#
# REAL BACKUP WORKFLOW (only for a new, valid, fresh request)
# 1. Validate the exact producer generation/manifest; acquire producer/state
#    locks and prepare the compact operational-state export.
# 2. Wake ISS if needed; wait for SSH/array readiness and acquire the shared ISS
#    backup lease, also used by the separate backup_media_remote.sh media mirror.
# 3. Transfer every configured BACKUP_JOBS source into a hidden .partial remote
#    generation; verify regular files against the expected SHA-256 manifest.
# 4. Atomically promote the verified generation and acknowledge its request.
# 5. Prune only after success (REMOTE_KEEP=3); perform a bounded restore drill on
#    ISS when its seven-day interval is due, then request guarded clean shutdown.
# 6. Retain bounded logs/status and send the operational result notification.
# Generations are independent: no Btrfs snapshot or cross-generation hard-link
# dependency. Existing source hard links may be preserved within one generation.
#
# RETRIES AND LIMITS
# An undelivered request is checked again next hour after a producer/transport/
# verification failure. Malformed, changed, future-dated or >72-hour-old requests
# require investigation/a fresh successful producer run; they are not bypassed.
# Acknowledgement occurs BEFORE retention/drill/shutdown. Those later warnings do
# not automatically recopy an already verified generation on the next poll.
# GitHub/photos/flash changes alone do not trigger a new generation in this mode;
# their current contents are included with the next appdata completion request.
#
# CLI (help/version do not acquire locks, contact ISS or start backup work)
#   bash script             Consume a new completion request, otherwise no-op.
#   bash script --help      Explain scheduling, triggers and operational limits.
#   bash script --version   Show this script version.
#   bash script --force     Repeat delivery of the current valid request even if
#                           acknowledged; still enforce freshness/integrity.
# --force may wake ISS and transfer all jobs. It cannot manufacture a request.
# Repository DRY_RUN defaults to true for review; preserve the installed value.
###############################################################################

# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="backup_vault_remote"
# Embedded operations contract v1; generated into standalone User Scripts.
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
    "${args[@]}"
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
# END EMBEDDED OPERATIONS CONTRACT
set -uo pipefail
export LC_ALL=C
umask 077

readonly SCRIPT_VERSION="1.20"

###############################################################################
# CONFIGURATION
###############################################################################

SRC_NAS="Hubble NAS"
DEST_NAS="ISS NAS"
REMOTE="root@192.168.50.3"
REMOTE_MAC="9C:6B:00:4B:BB:EE"
SSH_PORT=22

# This root must already exist on ISS. The script never creates it implicitly.
REMOTE_VERSION_ROOT="/mnt/user/backup/vault_versions"

# label|local source
BACKUP_JOBS=(
    "appdata|/mnt/vault/backup/cache"
    "flash|/mnt/vault/backup/flash"
    "user_scripts|/boot/config/plugins/user.scripts"
    "github|/mnt/vault/cloud/github"
    "photos|/mnt/vault/cloud/photos"
    "operations_state|/mnt/vault/backup/operations_state"
)

# Each generation is a complete independent copy.
REMOTE_KEEP=3
ENABLE_WOL=true
MAX_SSH_WAIT=420
SSH_WAIT_INTERVAL=15
ARRAY_READY_WAIT=180
ARRAY_READY_INTERVAL=6
SHUTDOWN_REMOTE_ON_SUCCESS=true

# Independent remote-activity shutdown guards. Ordinary read/correcting parity
# checks may be interrupted by the clean shutdown after backup. More critical
# parity sync, rebuild, and disk-clear operations remain protected.
DEFER_REMOTE_SHUTDOWN_WHILE_MOVER=true
DEFER_REMOTE_SHUTDOWN_DURING_PARITY_CHECK=false
DEFER_REMOTE_SHUTDOWN_DURING_CRITICAL_ARRAY_OPERATION=true

# Keep true for the first manually reviewed run.
DRY_RUN=true
# Schedule: 10 * * * *. Poll for a producer request, not an hourly full copy.
# Same delivered identity/no request -> local no-op; no SSH/WOL or backup log.
# --force bypasses delivery deduplication only; a valid fresh request is required.
COMPLETION_DRIVEN=true
ISS_REQUEST_FILE="${ISS_REQUEST_FILE:-/mnt/vault/cloud/logs/script/user_scripts_status/iss-backup-request.json}"
ISS_DELIVERED_FILE="${ISS_DELIVERED_FILE:-/mnt/vault/cloud/logs/script/user_scripts_status/iss-backup-delivered.json}"
MAX_PRODUCER_AGE_SECONDS=$((72 * 3600))
ISS_REQUEST_ID=""
ISS_REQUEST_GENERATION=""
# Run a bounded drill on ISS itself once weekly, while it is already awake.
# The local User Scripts entry supplies the reviewed standalone drill script.
RUN_REMOTE_RESTORE_DRILL=true
RESTORE_DRILL_SCRIPT="${RESTORE_DRILL_SCRIPT:-/boot/config/plugins/user.scripts/scripts/backup_restore_drill/script}"
RESTORE_DRILL_INTERVAL_SECONDS=604800
# Compact operational state plus private recovery configuration (may contain
# credentials). No bulk logs/cache, databases or transient leases. Standalone.
OPERATIONS_STATE_ROOT="${OPERATIONS_STATE_ROOT:-/mnt/vault/backup/operations_state}"
OPERATIONS_STATE_MAX_BYTES=$((128 * 1024 * 1024))
OPERATIONS_STATE_MOUNT_ROOT="${OPERATIONS_STATE_MOUNT_ROOT:-/mnt/vault}"
OPERATIONS_SCRIPT_ROOT="${OPERATIONS_SCRIPT_ROOT:-/mnt/vault/cloud/logs/script}"
OPERATIONS_EXPORT_TEMP=""
# Required state for this personal installation; missing/renamed state must not
# become a silently empty "successful" export after an OS/path change.
OPERATIONS_REQUIRED_STATE_FILES=(
    media_health_monitor/state.json
    media_cleanup/arr/sonarr-state.json
    media_cleanup/arr/radarr-state.json
    media_cleanup/arr/pending-actions.json
    media_cleanup/sab/pending-operations.json
    media_cleanup/quarantine/pending-operations.json
    media_cleanup/notification-outbox.json
    docker_service_watchdog/state.json
    system_update_coordinator/state.json
    system_update_coordinator/policy.json
    dns_redundancy_watchdog/state.json
)
RESTORE_DRILL_RESULT="not_due"
RESTORE_DRILL_EPOCH=0
RESTORE_DRILL_SUMMARY=""

USE_LOW_PRIORITY_IO=true
IONICE_CLASS=2
IONICE_PRIORITY=7
NICE_LEVEL=10

LOG_DIR="/mnt/vault/cloud/logs/script/backup_vault_remote"
MAX_LOGS=5
STATUS_DIR="/mnt/vault/cloud/logs/script/user_scripts_status"
NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
# Same pending generation + failure reason: initial alert, then one reminder/day.
# New generations/reasons/severity notify immediately; verified completion includes
# recovery in its normal report. Failed sends never consume the reminder budget.
VAULT_FAILURE_REMINDER_SECONDS=86400
VAULT_NOTIFICATION_STATE=""
VAULT_NOTIFICATION_REASON=""
LOCK_FILE="/run/backup_vault_remote.lock"

# Existing ISS generation .owner values are the stable vault_backup v1 format.
# Script/state names changed; verified remote archive ownership is preserved.
readonly SCRIPT_ID="backup_vault_remote"
readonly NOTIFY_SUBJECT="Backup Vault Remote"

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
    tail --bytes="$limit" -- "$file" >"$temp" && mv -f -- "$temp" "$file" || { rm -f -- "$temp"; return 1; }
}
backup_phase() {
    local now
    now=$(date +%s)
    printf '%s [PHASE] %s: %ss elapsed\n' "$(date '+%F %T')" "$BACKUP_PHASE" "$((now-BACKUP_PHASE_STARTED))" >>"$LOG_FILE"
    BACKUP_PHASE="$1"; BACKUP_PHASE_STARTED="$now"
}
BACKUP_PHASE_STARTED=$BACKUP_STARTED
backup_finish() {
    local rc=$? status=OK temp summary
    trap - EXIT INT TERM PIPE
    (( rc == 0 )) || status=FAILED
    [[ "$BACKUP_RESULT" != OK || "$status" != FAILED ]] || status=WARNING
    [[ "${DRY_RUN:-false}" != true || "$status" != OK ]] || status=WARNING
    [[ "$RETENTION_RESULT" != FAILED || "$status" != OK ]] || status=WARNING
    case "$RESTORE_DRILL_RESULT" in FAILED|WARNING) [[ "$status" != OK ]] || status=WARNING;; esac
    [[ "$SHUTDOWN_RESULT" == deferred || ( -z "${REMOTE_SHUTDOWN_SKIPPED_REASON:-}" && "${REMOTE_SHUTDOWN_FAILED:-0}" == 0 ) ]] || { [[ "$status" != OK ]] || status=WARNING; }
    [[ "$SHUTDOWN_RESULT" == deferred || -z "${REMOTE_SHUTDOWN_SKIPPED_REASON:-}" ]] || SHUTDOWN_RESULT=skipped
    if (( rc == 0 )); then BACKUP_PHASE=completed; fi
    summary="${SCRIPT_ID} v${SCRIPT_VERSION}; copy=$BACKUP_RESULT; verify=$VERIFICATION_RESULT; retention=$RETENTION_RESULT; phase=$BACKUP_PHASE; duration=$(( $(date +%s)-BACKUP_STARTED ))s; shutdown=$SHUTDOWN_RESULT ${REMOTE_SHUTDOWN_SKIPPED_REASON:-}"
    if (( rc != 0 )) && [[ "$BACKUP_NOTIFIED" != true && -x "${NOTIFY_BIN:-}" ]]; then
        local last_error
        last_error=$(awk '/\[ERROR\]/ {last=$0} END {sub(/^.*\[ERROR\] /,"",last); print last}' "$LOG_FILE" 2>/dev/null)
        VAULT_NOTIFICATION_REASON="$BACKUP_PHASE|$BACKUP_RESULT|$VERIFICATION_RESULT|$RETENTION_RESULT|$last_error"
        notify_unraid alert 'Backup failed' "$summary
Last error: $last_error
ISS shutdown was not forced after this failure; any undelivered appdata request remains eligible for retry.
Log: $LOG_FILE"
    fi
    [[ "$NOTIFICATION_RESULT" != failed && "$NOTIFICATION_RESULT" != unavailable || "$status" != OK ]] || status=WARNING
    if mountpoint -q /mnt/vault && command -v jq >/dev/null; then
        mkdir -p -- "$STATUS_DIR"
        temp=$(mktemp "$STATUS_DIR/.${SCRIPT_ID}.XXXXXX") &&
            jq -n --argjson drillEpoch "$RESTORE_DRILL_EPOCH" --arg drill "$RESTORE_DRILL_RESULT" --arg drillSummary "$RESTORE_DRILL_SUMMARY" --arg name "$SCRIPT_ID" --arg status "$status" --arg summary "$summary" --arg phase "$BACKUP_PHASE" --arg copy "$BACKUP_RESULT" --arg verification "$VERIFICATION_RESULT" --arg retention "$RETENTION_RESULT" --arg notification "$NOTIFICATION_RESULT" --arg shutdown "$SHUTDOWN_RESULT" --arg shutdown_reason "${REMOTE_SHUTDOWN_SKIPPED_REASON:-}" --arg version "$SCRIPT_VERSION" --arg log "$LOG_FILE" --argjson duration "$(( $(date +%s)-BACKUP_STARTED ))" --argjson epoch "$(date +%s)" \
            '{restoreDrillEpoch:$drillEpoch,restoreDrill:$drill,restoreDrillSummary:$drillSummary,name:$name,status:$status,summary:$summary,phase:$phase,copy:$copy,verification:$verification,retention:$retention,notification:$notification,shutdown:$shutdown,shutdown_reason:$shutdown_reason,scriptVersion:$version,duration_seconds:$duration,log:$log,epoch:$epoch}' >"$temp" && mv -f -- "$temp" "$STATUS_DIR/$SCRIPT_ID.json"
    fi
    [[ -z "$LEASE_INPUT" ]] || exec {LEASE_INPUT}>&-
    [[ -z "$LEASE_PID" ]] || { kill "$LEASE_PID" 2>/dev/null || true; wait "$LEASE_PID" 2>/dev/null || true; }
    [[ ${#TRANSPORT_OPTIONS[@]} == 0 ]] || ssh "${TRANSPORT_OPTIONS[@]}" -O exit "$REMOTE" >/dev/null 2>&1 || true
    [[ -z "$BACKUP_TMP" ]] || rm -rf -- "$BACKUP_TMP"
    [[ -z "${TMP_DIR:-}" ]] || rm -rf -- "$TMP_DIR"
    if [[ -n "$OPERATIONS_EXPORT_TEMP" && "$OPERATIONS_EXPORT_TEMP" == "${OPERATIONS_STATE_ROOT%/*}"/.operations-state.*.partial ]]; then rm -rf -- "$OPERATIONS_EXPORT_TEMP"; fi
    [[ ! -f "${LOG_FILE:-}" ]] || backup_bound_log "$LOG_FILE" "$MAX_MAIN_LOG_BYTES" || true
    exit "$rc"
}

###############################################################################
# RUNTIME
###############################################################################

RUN_STAMP="$(date '+%Y%m%d_%H%M%S')"
GENERATION_NAME="hubble-${RUN_STAMP}"
REMOTE_PARTIAL="${REMOTE_VERSION_ROOT}/.${GENERATION_NAME}.partial"
REMOTE_FINAL="${REMOTE_VERSION_ROOT}/${GENERATION_NAME}"
LOG_FILE="${LOG_DIR}/backup_vault_remote-${RUN_STAMP}.log"

TMP_DIR=""

RESULT_SUMMARY="Script exited before completion"
FILES_VERIFIED=0
BYTES_TRANSFERRED=0
REMOTE_SHUTDOWN_FAILED=0
REMOTE_SHUTDOWN_SKIPPED_REASON=""



RSYNC_ARGS=(
    -a
    --delete-delay
    --delete-excluded
    --partial
    --partial-dir=.rsync-partial
    --protect-args
    --stats
    --exclude=*.partial
    --exclude=.rsync-partial
    --exclude=*.tmp
    --exclude=*.sock
)

PRIORITY_PREFIX=()

###############################################################################
# HELPERS
###############################################################################

log() {
    local level="$1"
    shift
    local line
    line=$(usr_ops_log_line "$level" MAIN "$*")
    printf '%s\n' "$line"
    [[ -n "$LOG_FILE" && -d "$LOG_DIR" ]] &&
        { backup_bound_log "$LOG_FILE" "$MAX_MAIN_LOG_BYTES" && printf '%s\n' "$line" >>"$LOG_FILE"; } 2>/dev/null || true
}

# Durable across hourly invocations. The outer vault lock serializes this state;
# only accepted notifications advance its clock. No log or request-age counter is
# used as an incident identity, so an unchanged failure cannot become new hourly.
vault_notification_state_ready() {
    [[ -n "${VAULT_NOTIFICATION_STATE:-}" ]] || VAULT_NOTIFICATION_STATE="$LOG_DIR/notification-state.json"
    [[ "$VAULT_NOTIFICATION_STATE" != /mnt/vault/* ]] || mountpoint -q /mnt/vault || return 1
    [[ ! -L "$VAULT_NOTIFICATION_STATE" && ! -L "${VAULT_NOTIFICATION_STATE%/*}" ]] || return 1
    mkdir -p -- "${VAULT_NOTIFICATION_STATE%/*}" || return 1
    [[ ! -f "$VAULT_NOTIFICATION_STATE" ]] || jq -e '
      .schema==1 and (.activeFailure==null or
        ((.activeFailure.signature|test("^[a-f0-9]{64}$")) and
         (.activeFailure.description|type)=="string" and
         (.activeFailure.firstReportedAt|type)=="number" and
         (.activeFailure.lastSentAt|type)=="number" and
         .activeFailure.firstReportedAt>=0 and .activeFailure.lastSentAt>=0))
      ' "$VAULT_NOTIFICATION_STATE" >/dev/null 2>&1
}

notify_unraid() {
    BACKUP_NOTIFIED=true
    local importance="$1" description="$2" message="$3"
    local state_ready=false incident=false signature="" identity="${ISS_REQUEST_ID:-}" old="" now first=0 last=0 tmp reason=""
    now=$(date +%s)
    vault_notification_state_ready && state_ready=true
    case "$description" in 'ISS handoff unavailable'|'Backup failed') incident=true;; esac
    if [[ "$incident" == true ]]; then
        if [[ -z "$identity" && -f "$ISS_REQUEST_FILE" ]]; then identity=$(sha256sum -- "$ISS_REQUEST_FILE" | cut -d ' ' -f1);fi
        [[ -n "$identity" ]] || identity=no-request
        reason="${VAULT_NOTIFICATION_REASON:-$BACKUP_PHASE|$BACKUP_RESULT|$VERIFICATION_RESULT|$RETENTION_RESULT}"
        signature=$(printf '%s\0' "$identity" "$importance" "$description" "$reason" | sha256sum | cut -d ' ' -f1)
        if [[ "$state_ready" == true && -f "$VAULT_NOTIFICATION_STATE" ]]; then
            IFS=$'\t' read -r old first last < <(jq -r '[.activeFailure.signature//"",.activeFailure.firstReportedAt//0,.activeFailure.lastSentAt//0]|@tsv' "$VAULT_NOTIFICATION_STATE")
            if [[ "$old" == "$signature" ]] && (( now>=last && now-last<VAULT_FAILURE_REMINDER_SECONDS )); then
                NOTIFICATION_RESULT=suppressed
                log INFO "Repeated ISS failure notification suppressed; same request/reason, reminder interval=${VAULT_FAILURE_REMINDER_SECONDS}s. $description: $reason"
                return 0
            fi
        fi
        [[ "$old" == "$signature" ]] || first="$now"
    elif [[ "$state_ready" == true && -f "$VAULT_NOTIFICATION_STATE" && "$description" == 'Backup completed'* ]]; then
        old=$(jq -r '.activeFailure.description // ""' "$VAULT_NOTIFICATION_STATE")
        [[ -z "$old" ]] || message+=$'\n'"Recovery: previously reported $old is cleared; this generation passed transfer and SHA-256 verification."
    fi
    [[ -x "$NOTIFY_BIN" ]] || { NOTIFICATION_RESULT=unavailable; return 0; }
    if usr_ops_notify timeout --kill-after=5 30 "$NOTIFY_BIN" -i "$importance" -s "$NOTIFY_SUBJECT" -d "$description" -m "$message" >/dev/null 2>&1; then
        NOTIFICATION_RESULT=sent
        if [[ "$state_ready" == true && ( "$incident" == true || "$description" == 'Backup completed'* ) ]]; then
            tmp=$(mktemp "${VAULT_NOTIFICATION_STATE}.XXXXXX") || { NOTIFICATION_RESULT=failed;log WARN 'Notification accepted but receipt could not be saved; retry deduplication unavailable';return 0; }
            if jq -n --arg signature "$signature" --arg request "$identity" --arg description "$description" --arg reason "$reason" \
                --argjson incident "$incident" --argjson first "$first" --argjson now "$now" \
                '{schema:1,lastAcceptedAt:$now,activeFailure:(if $incident then
                  {signature:$signature,requestId:$request,description:$description,reason:$reason,firstReportedAt:$first,lastSentAt:$now}
                  else null end)}' >"$tmp" && sync -- "$tmp" && mv -f -- "$tmp" "$VAULT_NOTIFICATION_STATE"; then :
            else rm -f -- "$tmp";NOTIFICATION_RESULT=failed;log WARN 'Notification accepted but durable receipt failed; retry deduplication unavailable';fi
        fi
    else
        NOTIFICATION_RESULT=failed
        log WARN 'Notification delivery failed; cooldown was not advanced and the next retry can notify'
    fi
}

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " ")
        i=1
        while (b >= 1024 && i < 5) { b/=1024; i++ }
        printf "%.2f %s", b, u[i]
    }'
}

shell_quote() {
    printf '%q' "$1"
}

ssh_exec() {
    backup_ssh "$1"
}

prune_local_logs() {
    local -a logs=()
    local file
    mapfile -t logs < <(
        find "$LOG_DIR" -maxdepth 1 -type f -name 'backup_vault_remote-*.log' \
            -printf '%T@|%p\n' 2>/dev/null | sort -rn | cut -d'|' -f2-
    )
    for ((i=MAX_LOGS; i<${#logs[@]}; i++)); do
        file="${logs[$i]}"
        rm -f -- "$file" 2>/dev/null || true
    done
    for file in "${logs[@]:0:MAX_LOGS}"; do backup_bound_log "$file" "$MAX_MAIN_LOG_BYTES" || return 1; done
}

build_priority_prefix() {
    PRIORITY_PREFIX=()
    [[ "$USE_LOW_PRIORITY_IO" == true ]] || return 0
    command -v nice >/dev/null 2>&1 &&
        PRIORITY_PREFIX+=(nice -n "$NICE_LEVEL")
    command -v ionice >/dev/null 2>&1 &&
        PRIORITY_PREFIX+=(ionice -c "$IONICE_CLASS" -n "$IONICE_PRIORITY")
}

validate_configuration() {
    local job label source command boolean_name boolean_value
    local -A seen_labels=()
    [[ "$REMOTE_VERSION_ROOT" == /mnt/user/* &&
       "$REMOTE_VERSION_ROOT" != "/mnt/user/" &&
       "$REMOTE_VERSION_ROOT" != *$'\n'* ]] || {
        log ERROR "Unsafe REMOTE_VERSION_ROOT: $REMOTE_VERSION_ROOT"
        return 1
    }
    [[ "$VAULT_RESERVE_BYTES" =~ ^[0-9]+$ && "$PARTIAL_RETENTION_DAYS" =~ ^[0-9]+$ && "$VAULT_MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$REMOTE_KEEP" =~ ^[1-9][0-9]*$ ]] || {
        log ERROR "REMOTE_KEEP must be at least 1"
        return 1
    }
    [[ "$MAX_SSH_WAIT" =~ ^[1-9][0-9]*$ &&
       "$SSH_WAIT_INTERVAL" =~ ^[1-9][0-9]*$ &&
       "$ARRAY_READY_WAIT" =~ ^[1-9][0-9]*$ &&
       "$ARRAY_READY_INTERVAL" =~ ^[1-9][0-9]*$ ]] || {
        log ERROR "Remote readiness timeouts and intervals must be positive integers"
        return 1
    }
    (( SSH_WAIT_INTERVAL <= MAX_SSH_WAIT &&
       ARRAY_READY_INTERVAL <= ARRAY_READY_WAIT )) || {
        log ERROR "Remote readiness intervals must not exceed their timeouts"
        return 1
    }
    (( ${#BACKUP_JOBS[@]} > 0 )) || {
        log ERROR "No BACKUP_JOBS are configured"
        return 1
    }

    for boolean_name in \
        SHUTDOWN_REMOTE_ON_SUCCESS \
        DEFER_REMOTE_SHUTDOWN_WHILE_MOVER \
        DEFER_REMOTE_SHUTDOWN_DURING_PARITY_CHECK \
        DEFER_REMOTE_SHUTDOWN_DURING_CRITICAL_ARRAY_OPERATION
    do
        boolean_value="${!boolean_name}"
        case "$boolean_value" in
            true|false)
                ;;
            *)
                log ERROR "${boolean_name} must be true or false"
                return 1
                ;;
        esac
    done

    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r label source <<<"$job"
        [[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$label" != manifests && "$label" != completed.txt && -z "${seen_labels[$label]:-}" ]] || {
            log ERROR "Unsafe backup label: $label"
            return 1
        }
        seen_labels[$label]=1
        backup_source_ready "$source" || {
            log ERROR "Backup source is unavailable or unsafe: $source"
            return 1
        }
    done

    for command in ssh rsync sha256sum find sort xargs flock jq; do
        command -v "$command" >/dev/null 2>&1 || {
            log ERROR "Required command not found: $command"
            return 1
        }
    done
}

send_wol() {
    [[ "$ENABLE_WOL" == true ]] || return 0
    if command -v etherwake >/dev/null 2>&1; then
        etherwake "$REMOTE_MAC" >/dev/null 2>&1 || true
    elif command -v wakeonlan >/dev/null 2>&1; then
        wakeonlan "$REMOTE_MAC" >/dev/null 2>&1 || true
    else
        log WARN "Wake-on-LAN tool not found; continuing with SSH readiness checks"
    fi
}

wait_for_remote() {
    local ssh_waited=0 array_waited=0 root_q wait_started error_output
    local ssh_ready=0 array_ready=0
    root_q="$(shell_quote "$REMOTE_VERSION_ROOT")"
    send_wol

    wait_started=$(date +%s)
    log INFO "Waiting up to ${MAX_SSH_WAIT}s for $DEST_NAS SSH"
    while (( ssh_waited <= MAX_SSH_WAIT )); do
        if error_output=$(BACKUP_SSH_COMMAND_TIMEOUT=20 ssh_exec "true" 2>&1); then
            ssh_ready=1
            break
        fi
        if grep -qiE 'permission denied|host key verification failed|identification has changed' <<<"$error_output"; then
            log ERROR 'Permanent SSH authentication/host-key failure; readiness retries stopped'
            return 1
        fi
        ssh_waited=$(( $(date +%s)-wait_started ))
        (( ssh_waited >= MAX_SSH_WAIT )) && break
        sleep "$SSH_WAIT_INTERVAL"
        ssh_waited=$(( $(date +%s)-wait_started ))
    done

    (( ssh_ready == 1 )) || {
        log ERROR "$DEST_NAS did not become reachable within ${MAX_SSH_WAIT}s"
        return 1
    }
    log INFO "$DEST_NAS SSH is reachable after ${ssh_waited}s"

    wait_started=$(date +%s)
    log INFO "Waiting up to ${ARRAY_READY_WAIT}s for $DEST_NAS /mnt/user mount"
    while (( array_waited <= ARRAY_READY_WAIT )); do
        if BACKUP_SSH_COMMAND_TIMEOUT=20 ssh_exec 'mountpoint -q /mnt/user 2>/dev/null || grep -qsE "[[:space:]]/mnt/user[[:space:]]" /proc/mounts' \
            >/dev/null 2>&1; then
            array_ready=1
            break
        fi
        (( array_waited >= ARRAY_READY_WAIT )) && break
        sleep "$ARRAY_READY_INTERVAL"
        array_waited=$(( $(date +%s)-wait_started ))
    done

    (( array_ready == 1 )) || {
        log ERROR "$DEST_NAS /mnt/user was not mounted within ${ARRAY_READY_WAIT}s"
        return 1
    }
    log INFO "$DEST_NAS /mnt/user is mounted after ${array_waited}s"

    if ! ssh_exec "test -d $root_q && test ! -L $root_q"; then
        log ERROR "Remote version root is missing, unavailable, or a symlink: $REMOTE_VERSION_ROOT"
        return 1
    fi
}


# Resumable staging is never restore-ready until promoted with completed.txt.
PARTIAL_RETENTION_DAYS=14
VAULT_RESERVE_BYTES=$((10 * 1024 * 1024 * 1024))
VAULT_MAX_ATTEMPTS=3
PRODUCER_LOCK_FDS=()
declare -A MANIFEST_FILES=() MANIFEST_BYTES=() SOURCE_FINGERPRINT=()
vault_producer_locks() {
    local file fd
    for file in /tmp/backup_cache_appdata.lock /tmp/backup_boot_disk.lock; do
        exec {fd}>"$file" || return 1
        flock -s -n "$fd" || { log ERROR "Backup producer is active: $file; retry this vault run later"; return 1; }
        PRODUCER_LOCK_FDS+=("$fd")
    done
}
vault_select_sources() {
    local job label source latest root
    local -a selected=()
    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r label source <<<"$job"
        backup_source_ready "$source" || { log ERROR "Source mount/identity failed: $source"; return 1; }
        if [[ "$label" == appdata ]]; then
            root="$source"
            latest=$(find "$source" -mindepth 1 -maxdepth 1 -type d -name 'backup_[0-9]*_[0-9]*' ! -name '*.partial' -printf '%f\n' | sort | tail -n 1)
            [[ -n "$latest" ]] || { log ERROR "No completed appdata generation exists in $source"; return 1; }
            [[ "$latest" =~ ^backup_[0-9]{8}_[0-9]{6}$ ]] || return 1
            source="$root/$latest"
            [[ -f "$source/backup_manifest.tsv" && -f "$source/backup_manifest.tsv.sha256" ]] &&
                (cd "$source" && sha256sum -c -- backup_manifest.tsv.sha256 >/dev/null) || { log ERROR "Appdata generation manifest is missing or invalid"; return 1; }
            log INFO "Selected completed appdata generation: $source"
        fi
        selected+=("$label|$source")
    done
    BACKUP_JOBS=("${selected[@]}")
}
# Return 10 for a harmless no-op. Malformed/stale requests fail visibly.
vault_pending_request() {
    local digest completed now delivered="" root="" job label source
    VAULT_NOTIFICATION_REASON="request-schema"
    [[ -f "$ISS_REQUEST_FILE" ]] || return 10
    jq -e '.schema==1 and (.generation|type=="string") and
      (.manifestSha256|test("^[a-f0-9]{64}$")) and
      (.completedAt|type=="number" and .==floor and .>0)' "$ISS_REQUEST_FILE" >/dev/null || return 1
    ISS_REQUEST_GENERATION=$(jq -r .generation "$ISS_REQUEST_FILE") || return 1
    digest=$(jq -r .manifestSha256 "$ISS_REQUEST_FILE") || return 1
    completed=$(jq -r .completedAt "$ISS_REQUEST_FILE") || return 1
    now=$(date +%s)
    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r label source <<<"$job"
        [[ "$label" != appdata ]] || root="$source"
    done
    VAULT_NOTIFICATION_REASON="generation-path-unavailable"
    [[ -n "$root" && "$ISS_REQUEST_GENERATION" == "$root"/backup_* &&
       "${ISS_REQUEST_GENERATION##*/}" =~ ^backup_[0-9]{8}_[0-9]{6}$ &&
       -d "$ISS_REQUEST_GENERATION" && ! -L "$ISS_REQUEST_GENERATION" &&
       $(realpath -e -- "$ISS_REQUEST_GENERATION") == "$ISS_REQUEST_GENERATION" ]] || return 1
    ISS_REQUEST_ID="${ISS_REQUEST_GENERATION##*/}:$digest"
    VAULT_NOTIFICATION_REASON="delivery-receipt-invalid"
    if [[ -f "$ISS_DELIVERED_FILE" ]]; then delivered=$(jq -r '.requestId // ""' "$ISS_DELIVERED_FILE") || return 1; fi
    [[ "$ISS_REQUEST_ID" != "$delivered" || "${1:-}" == --force ]] || return 10
    VAULT_NOTIFICATION_REASON="request-stale-or-future-dated"
    (( completed <= now && now-completed <= MAX_PRODUCER_AGE_SECONDS )) || {
        printf 'Pending ISS request is stale/future-dated; source backup must succeed again\n' >&2; return 1;
    }
    VAULT_NOTIFICATION_REASON="producer-manifest-changed"
    [[ $(sha256sum "$ISS_REQUEST_GENERATION/backup_manifest.tsv" | awk '{print $1}') == "$digest" ]] || return 1
    VAULT_NOTIFICATION_REASON=""
}
vault_acknowledge_request() {
    [[ -n "$ISS_REQUEST_ID" ]] || return 0
    local tmp
    mkdir -p -- "${ISS_DELIVERED_FILE%/*}" || return 1
    tmp=$(mktemp "${ISS_DELIVERED_FILE}.XXXXXX") || return 1
    if jq -n --arg requestId "$ISS_REQUEST_ID" --arg source "$ISS_REQUEST_GENERATION" \
      --arg remote "$REMOTE_FINAL" --argjson verifiedAt "$(date +%s)" \
      '{schema:1,requestId:$requestId,source:$source,remote:$remote,verifiedAt:$verifiedAt,verification:"sha256"}' >"$tmp" &&
      mv -f -- "$tmp" "$ISS_DELIVERED_FILE"; then return 0; fi
    rm -f -- "$tmp"; return 1
}
# Reuse the producer's expected archive digests in the transfer manifest. The
# existing remote SHA pass then proves the original backup, with no second full
# read of every local archive or repeated remote payload checksum pass.
vault_appdata_manifest() {
    local source="$1" manifest="$2" raw bytes hash name path rows=0 expected
    local -A hashes=()
    expected=$(sed -n 's/^# archive_count=//p' "$source/backup_manifest.tsv")
    [[ "$expected" =~ ^[1-9][0-9]*$ ]] || return 1
    while IFS=$'\t' read -r raw bytes hash name; do
        [[ "$raw" == \#* ]] && continue
        [[ "$raw" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ && "$hash" =~ ^[a-f0-9]{64}$ &&
           "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && -z "${hashes[$name]+present}" ]] || return 1
        hashes[$name]="$hash"; rows=$((rows+1))
        [[ -f "$source/$name.tar.gz" && ! -L "$source/$name.tar.gz" &&
           $(stat -c %s "$source/$name.tar.gz") == "$bytes" ]] || return 1
    done <"$source/backup_manifest.tsv"
    (( rows == expected )) || return 1
    : >"$manifest"
    while IFS= read -r -d '' path; do
        if [[ "$path" == ./*.tar.gz && "${path#./}" != */* ]]; then
            name="${path#./}"; name="${name%.tar.gz}"
            [[ -n "${hashes[$name]:-}" ]] || return 1
            printf '%s  %s\n' "${hashes[$name]}" "$path" >>"$manifest"
        else
            (cd "$source" && sha256sum -- "$path") >>"$manifest" || return 1
        fi
    done <"$manifest.files"
}

vault_remote_restore_drill() {
    [[ "$RUN_REMOTE_RESTORE_DRILL" == true ]] || { RESTORE_DRILL_RESULT=disabled; return 0; }
    local root="$REMOTE_VERSION_ROOT/restore_drill" last digest remote_script output rc=0
    [[ -f "$RESTORE_DRILL_SCRIPT" && ! -L "$RESTORE_DRILL_SCRIPT" ]] || {
        RESTORE_DRILL_SUMMARY="Restore drill script is missing on Hubble; no drill performed"; return 1;
    }
    last=$(ssh_exec "if test -f $(shell_quote "$root/status/backup_restore_drill.json"); then jq -r 'if .status==\"OK\" or .status==\"WARNING\" then .epoch else 0 end' $(shell_quote "$root/status/backup_restore_drill.json"); else printf 0; fi") || return 1
    [[ "$last" =~ ^[0-9]+$ ]] || return 1
    RESTORE_DRILL_EPOCH=$last
    if (( last <= $(date +%s) && $(date +%s)-last < RESTORE_DRILL_INTERVAL_SECONDS )); then
        RESTORE_DRILL_SUMMARY="Weekly ISS restore drill not due; last completed epoch=$last"; return 0
    fi
    backup_phase restore-drill
    remote_script="$REMOTE_VERSION_ROOT/.hubble-restore-drill.sh"
    digest=$(sha256sum "$RESTORE_DRILL_SCRIPT" | awk '{print $1}') || return 1
    rsync -a --protect-args "$RESTORE_DRILL_SCRIPT" "$REMOTE:$remote_script" || return 1
    output="$TMP_DIR/remote-drill.log"
    # No second email from ISS: its detailed receipt joins the vault notification.
    # A timeout is a drill failure, not permission to invalidate/delete a backup.
    ssh_exec "test \"\$(sha256sum $(shell_quote "$remote_script") | awk '{print \$1}')\" = '$digest' && VAULT_MOUNT=/mnt/user DRILL_ROOT=$(shell_quote "$root") LOG_DIR=$(shell_quote "$root/logs") STATUS_DIR=$(shell_quote "$root/status") NOTIFY_BIN=/nonexistent timeout --signal=TERM --kill-after=15 7200 bash $(shell_quote "$remote_script") --generation-root $(shell_quote "$REMOTE_FINAL")" >"$output" 2>&1 || rc=$?
    tail -n 20 "$output" >>"$LOG_FILE"
    if (( rc != 0 )); then
        RESTORE_DRILL_SUMMARY="ISS extraction/database drill failed (exit=$rc); verified backup retained. Evidence: $root/logs"; return 1
    fi
    RESTORE_DRILL_EPOCH=$(ssh_exec "jq -r '.epoch' $(shell_quote "$root/status/backup_restore_drill.json")") || return 1
    RESTORE_DRILL_SUMMARY=$(ssh_exec "jq -r '.summary' $(shell_quote "$root/status/backup_restore_drill.json")") || return 1
    RESTORE_DRILL_RESULT=$(ssh_exec "jq -r '.status' $(shell_quote "$root/status/backup_restore_drill.json")") || return 1
    [[ "$RESTORE_DRILL_RESULT" == OK || "$RESTORE_DRILL_RESULT" == WARNING ]]
}

# Read-only control-plane capture. Private Docker inspect output can contain
# credentials; never print it or publish it to GitHub. No container is changed.
RECOVERY_SUMMARY="not captured"
RECOVERY_CAPTURE_WARNING=false
RECOVERY_BOOT_ROOT="${RECOVERY_BOOT_ROOT:-/boot}"
recovery_docker() { timeout 30 docker "$@"; }
vault_capture_recovery() {
    local root="$1" boot="$RECOVERY_BOOT_ROOT" file rel before after size total=0
    local status=complete spec label source container_count=0 uncovered=0
    mkdir -m 700 "$root" "$root/boot-config" || return 1
    printf '[]\n' >"$root/files.json"
    # Explicit control files only: omit plugin binaries, logs and backup ZIPs.
    if [[ -d "$boot/config" && ! -L "$boot/config" ]]; then
        while IFS= read -r -d '' file; do
            rel=${file#"$boot/"}
            case "$rel" in
                config/docker.cfg|config/network.cfg|config/network-rules.cfg|config/ident.cfg|config/shares/*.cfg|config/plugins/dockerMan/templates-user/*.xml|config/plugins/user.scripts/schedule.json|config/plugins/user.scripts/customSchedule.cron|config/plugins/user.scripts/media_integrity_audit_sunday.cron|config/plugins/user.scripts/scripts/*/script|config/plugins/user.scripts/scripts/*/name|config/plugins/user.scripts/scripts/*/description) ;;
                *) continue;;
            esac
            [[ "$rel" != *$'\n'* && "$rel" != *$'\r'* && $(realpath -e "$file") == "$file" ]] || return 1
            size=$(stat -c %s "$file") || return 1
            total=$((total+size)); ((total <= OPERATIONS_STATE_MAX_BYTES)) || return 1
            before=$(sha256sum "$file" | awk '{print $1}') || return 1
            mkdir -p -- "$root/boot-config/${rel%/*}" || return 1
            cp -p -- "$file" "$root/boot-config/$rel" || return 1
            after=$(sha256sum "$file" | awk '{print $1}') || return 1
            [[ "$before" == "$after" && "$before" == "$(sha256sum "$root/boot-config/$rel" | awk '{print $1}')" ]] || return 1
            jq --arg path "$rel" --arg hash "$before" --argjson bytes "$size" \
                --arg owner "$(stat -c '%u:%g:%a' "$file")" \
                '. + [{path:$path,sha256:$hash,bytes:$bytes,originalOwnerGroupMode:$owner}]' \
                "$root/files.json" >"$root/files.next" && mv "$root/files.next" "$root/files.json" || return 1
        done < <(find "$boot/config" -type f -print0)
    else
        status=partial
    fi
    for file in containers images networks volumes; do printf '[]\n' >"$root/$file.json"; done
    # Lists are stored in files, not expanded into one enormous argv.
    if recovery_docker ps -aq --no-trunc >"$root/container-ids.txt" 2>/dev/null; then
        while IFS= read -r file; do
            [[ "$file" =~ ^[a-f0-9]{12,64}$ ]] || { status=partial; continue; }
            if recovery_docker inspect "$file" >"$root/inspect.tmp" 2>/dev/null && jq -e 'type=="array" and length==1' "$root/inspect.tmp" >/dev/null; then
                jq -s '.[0]+.[1]' "$root/containers.json" "$root/inspect.tmp" >"$root/merge.tmp" && mv "$root/merge.tmp" "$root/containers.json" || return 1
            else status=partial; fi
        done <"$root/container-ids.txt"
        if recovery_docker ps -aq --no-trunc >"$root/container-ids-after.txt" 2>/dev/null; then
            sort "$root/container-ids.txt" >"$root/ids-before.tmp"
            sort "$root/container-ids-after.txt" >"$root/ids-after.tmp"
            cmp -s "$root/ids-before.tmp" "$root/ids-after.tmp" || status=partial
        else status=partial; fi
        jq -r '.[].Image' "$root/containers.json" | sort -u >"$root/image-ids.txt"
        for spec in images networks volumes; do
            case "$spec" in
                images) source="$root/image-ids.txt";;
                networks) source="$root/network-ids.txt"; recovery_docker network ls -q >"$source" 2>/dev/null || status=partial;;
                volumes) source="$root/volume-names.txt"; recovery_docker volume ls -q >"$source" 2>/dev/null || status=partial;;
            esac
            while IFS= read -r file; do
                [[ -n "$file" && "$file" != -* ]] || continue
                case "$spec" in images) label=image;; networks) label=network;; volumes) label=volume;; esac
                if recovery_docker "$label" inspect "$file" >"$root/inspect.tmp" 2>/dev/null && jq -e 'type=="array" and length==1' "$root/inspect.tmp" >/dev/null; then
                    jq -s '.[0]+.[1]' "$root/$spec.json" "$root/inspect.tmp" >"$root/merge.tmp" && mv "$root/merge.tmp" "$root/$spec.json" || return 1
                else status=partial; fi
            done <"$source"
        done
    else status=unavailable; fi
    # Policies are evidence, not a claim of payload verification. Never source
    # another script or infer /mnt/user aliases or named-volume data coverage.
    printf '[]\n' >"$root/policies.json"
    for spec in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r label source <<<"$spec"
        jq --arg label "$label" --arg source "$source" '.+[{label:$label,source:$source,evidence:"configured ISS source; transfer verification occurs later"}]' \
            "$root/policies.json" >"$root/merge.tmp" && mv "$root/merge.tmp" "$root/policies.json" || return 1
    done
    if [[ -f "${ISS_REQUEST_GENERATION:-}/backup_manifest.tsv" ]]; then
        cp -- "$ISS_REQUEST_GENERATION/backup_manifest.tsv" "$root/appdata-producer-manifest.tsv" || return 1
    fi
    jq --slurpfile policies "$root/policies.json" '
        [.[] | .Name as $name | .Mounts[]? | . as $m |
        {container:$name,type:.Type,source:.Source,destination:.Destination,readWrite:.RW,
         matchingConfiguredSources:[$policies[0][] | select(.source as $s | $m.Source==$s or ($m.Source|startswith($s+"/"))) | .label],
         payloadStatus:(if .Type=="volume" then "named-volume contents require explicit backup"
           elif (.Source|test("^/(dev|proc|sys|run|tmp)(/|$)")) then "system or transient mount; review dependency"
           else "unverified: check appdata manifest, exclusions and media mirror separately" end)}]' \
        "$root/containers.json" >"$root/coverage.json" || return 1
    if [[ -f "$root/appdata-producer-manifest.tsv" ]]; then
        source=$(sed -n 's/^# source=//p' "$root/appdata-producer-manifest.tsv")
        jq -n --arg source "$source" --rawfile manifest "$root/appdata-producer-manifest.tsv" \
            '{source:$source,archivedNames:[$manifest|split("\n")[]|select(length>0 and (startswith("#")|not))|split("\t")|.[3]],scope:"producer archive names only; per-path exclusions still apply"}' \
            >"$root/appdata-coverage.json" || return 1
    fi
    container_count=$(jq length "$root/containers.json")
    uncovered=$(jq '[.[]|select(.payloadStatus|startswith("named-volume"))]|length' "$root/coverage.json")
    jq -n --arg status "$status" --arg host "$(hostname)" --arg kernel "$(uname -r)" \
        --arg generation "${ISS_REQUEST_GENERATION:-}" --argjson epoch "$(date +%s)" \
        --argjson containers "$container_count" --argjson namedVolumes "$uncovered" \
        '{schema:1,capturedAt:$epoch,host:$host,kernel:$kernel,producerGeneration:$generation,
          runtimeStatus:$status,containerCount:$containers,namedVolumeMounts:$namedVolumes,
          scope:"read-only configuration capture; not an application startup test or proof of mount payload coverage"}' >"$root/inventory.json" || return 1
    cat >"$root/RESTORE.md" <<'RUNBOOK'
# Hubble recovery runbook

This private bundle contains credentials in Docker environment/template settings.
Keep it off public repositories. Inventory commands never modify Docker.

1. Keep the original failed disks and backups intact. Install a compatible Unraid
   release on replacement flash; restore flash configuration deliberately. Confirm
   disk serials and assignments before starting the array; never blindly apply
   super.dat to different disks. Restore network access and licensing as required.
2. Disable Docker autostart, User Scripts schedules and automatic download/import,
   metadata and cleanup jobs until paths and restored data have been checked.
3. Choose a completed SHA-verified backup generation. Restore appdata, flash
   control files, User Scripts, GitHub, photos and operational state from compatible
   times. The media/secure mirror is separate from vault generations. Check its
   exclusions and latest transfer result; deleted mirrored data is not versioned.
4. Review files.json for original owner/group/mode. boot-config contains a compact
   control-plane copy, not a complete flash backup. Docker templates and schedules
   supplement the full flash ZIP. Restore only the selected settings you need.
5. Review containers.json, images.json, networks.json and volumes.json. Recreate
   required network drivers/IPAM and mount paths first. Inspect recorded image IDs,
   RepoDigests and architecture; tags can change and digests may become unavailable.
   This bundle contains no image layers and no named-volume contents. Do not
   automatically execute captured environment values or blindly replay inspect.
6. Check coverage.json, policies.json and the producer manifest. Configured paths
   do not prove payload coverage. Appdata exclusions, external mounts, named
   volumes and the separate remote media mirror need individual review. Do not
   assume /mnt/user and pool paths are aliases without checking the restored layout.
7. Restore databases and configuration before starting one service at a time.
   Validate application access and actual media paths; the bounded restore drill
   does not start containers or certify a complete working system.
8. Restore script state with its matching application state. Let mutation journals
   reconcile exact API/file IDs; do not blindly replay actions or restore /run
   locks, PIDs, heartbeats or maintenance leases. Verify a new backup and monitor
   baseline, then deliberately re-enable schedules, imports and cleanup policies.
RUNBOOK
    rm -f -- "$root/"*.tmp "$root/container-ids-after.txt"
    # Secure copied files beneath a private parent. Original modes are recorded.
    find "$root" -type d -exec chmod 700 {} + || return 1
    find "$root" -type f -exec chmod 600 {} + || return 1
    (cd "$root" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS) || return 1
    chmod 600 "$root/SHA256SUMS"
    [[ "$status" == complete && "$uncovered" == 0 ]] || RECOVERY_CAPTURE_WARNING=true
    RECOVERY_SUMMARY="runtime=$status; containers=$container_count; named-volume mounts needing payload review=$uncovered; mount coverage requires policy review"
    log INFO "Recovery inventory: $RECOVERY_SUMMARY"
}

vault_export_operations_state() {
    local fd spec name source file base size total=0 temp previous current_hash copied_hash optional_media_bytes=0
    local scripts="$OPERATIONS_SCRIPT_ROOT"
    local -a sources=(
        "backup_vault_remote|$scripts/backup_vault_remote"
        "media_health_monitor|$scripts/media_health_monitor"
        "media_cleanup|$scripts/media_cleanup"
        "media_cleanup/arr|$scripts/media_cleanup/arr"
        "media_cleanup/sab|$scripts/media_cleanup/sab"
        "media_cleanup/quarantine|$scripts/media_cleanup/quarantine"
        "media_cleanup/sab/purge-receipts|$scripts/media_cleanup/sab/purge-receipts"
        "media_cleanup/quarantine/purge-receipts|$scripts/media_cleanup/quarantine/purge-receipts"
        "docker_service_watchdog|$scripts/docker_service_watchdog"
        "system_update_coordinator|$scripts/system_update_coordinator"
        "dns_redundancy_watchdog|$scripts/dns_redundancy_watchdog"
        "media_plex_dbrepair|$scripts/media_plex_dbrepair"
        "media_metadata_audit|$scripts/media_metadata_audit"
        "imagemaid_restore_archive|$scripts/imagemaid_restore_archive"
        "backup_health_audit|$scripts/backup_health_audit"
        "media_torrent_management|$scripts/media_torrent_management/state"
        "media_integrity_audit|$scripts/media_integrity_audit"
    )
    [[ "$OPERATIONS_STATE_ROOT" == "$OPERATIONS_STATE_MOUNT_ROOT"/backup/* && ! -L "$OPERATIONS_STATE_ROOT" &&
       $(realpath -m "$OPERATIONS_STATE_ROOT") == "$OPERATIONS_STATE_ROOT" ]] || return 1
    if [[ -e "$OPERATIONS_STATE_ROOT" ]]; then
        [[ -d "$OPERATIONS_STATE_ROOT" && -f "$OPERATIONS_STATE_ROOT/.owner" && $(cat "$OPERATIONS_STATE_ROOT/.owner") == vault_operations_state ]] || {
            log ERROR 'Existing operational-state directory is unowned; preserved without changes'; return 1;
        }
    fi
    exec {fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || return 1
    if ! flock -x -w 600 "$fd"; then exec {fd}>&-; log ERROR 'Operational-state writers did not quiesce; no ISS wake performed'; return 1; fi
    temp=$(mktemp -d "${OPERATIONS_STATE_ROOT%/*}/.operations-state.XXXXXX.partial") || { exec {fd}>&-; return 1; }
    OPERATIONS_EXPORT_TEMP="$temp"
    chmod 700 "$temp"
    printf 'vault_operations_state\n' >"$temp/.owner" || { exec {fd}>&-; return 1; }
    for spec in "${sources[@]}"; do
        IFS='|' read -r name source <<<"$spec"
        [[ -d "$source" && ! -L "$source" ]] || continue
        mkdir -p "$temp/$name" || { exec {fd}>&-; return 1; }
        while IFS= read -r -d '' file; do
            base=${file##*/}
            # Explicit current files, never dated backup snapshots or generic logs.
            case "$base" in
                recovery.json|recovery.previous.json)
                    [[ "$name" == media_integrity_audit ]] || continue
                    # Recovery intents/holds are required control-plane material,
                    # unlike the optional bulk read-only verification queue.
                    jq -e '.schema==1 and (.actions|type)=="object"' "$file" >/dev/null || { log ERROR 'Media recovery journal invalid; control-plane export stopped';exec {fd}>&-;return 1; };;
                state.json.gz|notified.json|pending-notification.json)
                    [[ "$name" == media_integrity_audit ]] || continue
                    # Read-only audit progress is optional recovery material.
                    # A damaged queue must not block the actual data backup.
                    if [[ "$base" == *.gz ]]; then
                        if ! gzip -t "$file" 2>/dev/null; then log WARNING 'Optional media integrity queue invalid; excluded from state export';continue;fi
                    elif ! jq -e . "$file" >/dev/null 2>&1; then log WARNING 'Optional media integrity delivery state invalid; excluded from export';continue;fi;;
                *.jsonl|*.tsv)
                    [[ "$name" == media_cleanup/*/purge-receipts || "$base" == action-receipts.jsonl || "$base" == pending-notifications.jsonl || "$base" == operation-recovery.jsonl || "$base" == quarantine-index.tsv || "$base" == transfer-manifest.tsv ]] || continue;;
                notification-outbox.json|latest-run.json)
                    [[ "$name" == media_cleanup || "$name" == media_cleanup/quarantine ]] || continue;;
                policy.json) [[ "$name" == system_update_coordinator ]] || continue;;
                state.json|notification-state.json|import-receipts.json|automation-actions.json|policy-actions.json|sonarr-state.json|radarr-state.json|pending-actions.json|pending-operations.json|action-receipts.jsonl|pending-notifications.jsonl|operation-recovery.jsonl|quarantine-index.tsv|transfer-manifest.tsv) ;;
                *) continue;;
            esac
            size=$(stat -c %s "$file") || { exec {fd}>&-; return 1; }
            if [[ "$name" == media_integrity_audit && "$base" != recovery.json && "$base" != recovery.previous.json ]] && (( total+size>OPERATIONS_STATE_MAX_BYTES )); then
                log WARNING 'Optional media integrity queue exceeds export budget; omitted without blocking data backup';continue
            fi
            total=$((total+size))
            [[ "$name" != media_integrity_audit || ( "$base" == recovery.json || "$base" == recovery.previous.json ) ]] || optional_media_bytes=$((optional_media_bytes+size))
            if [[ "$name" == media_integrity_audit && ( "$base" == recovery.json || "$base" == recovery.previous.json ) ]] && ((total>OPERATIONS_STATE_MAX_BYTES && optional_media_bytes>0)); then
                rm -f -- "$temp/media_integrity_audit/state.json.gz" "$temp/media_integrity_audit/notified.json" "$temp/media_integrity_audit/pending-notification.json"
                total=$((total-optional_media_bytes));optional_media_bytes=0
                log WARNING 'Optional integrity progress omitted to retain required media recovery journal'
            fi
            (( total<=OPERATIONS_STATE_MAX_BYTES )) || { exec {fd}>&-; log ERROR 'Operational state exceeds export budget; previous snapshot retained'; return 1; }
            [[ "$base" != *.json ]] || jq -e . "$file" >/dev/null || { exec {fd}>&-; return 1; }
            cp -p -- "$file" "$temp/$name/$base" || { exec {fd}>&-; return 1; }
            chmod 600 "$temp/$name/$base"
            current_hash=$(sha256sum "$file" | awk '{print $1}')
            copied_hash=$(sha256sum "$temp/$name/$base" | awk '{print $1}')
            [[ "$current_hash" == "$copied_hash" ]] || { exec {fd}>&-; return 1; }
        done < <(find "$source" -maxdepth 1 -type f -print0)
    done
    local required
    for required in "${OPERATIONS_REQUIRED_STATE_FILES[@]}"; do
        if [[ ! -f "$temp/$required" ]]; then
            exec {fd}>&-
            log ERROR "Required operational state is missing: $required; previous export retained"
            return 1
        fi
    done
    (( total>0 )) || { exec {fd}>&-; log ERROR 'No current operational state found; empty export refused'; return 1; }
    # Point 7 remains excluded: do not change disk-health scheduling/code. Its
    # private config is copied under its existing lock, independently of logs.
    local health_source="$scripts/health_monitoring/state/health_monitoring.conf" health_fd
    if [[ -f "$health_source" && ! -L "$health_source" ]]; then
        exec {health_fd}>/run/health_monitoring.lock || { exec {fd}>&-; return 1; }
        if ! flock -n "$health_fd"; then exec {health_fd}>&-; exec {fd}>&-; return 1; fi
        mkdir "$temp/health_monitoring" && cp -p "$health_source" "$temp/health_monitoring/health_monitoring.conf" || { exec {health_fd}>&-; exec {fd}>&-; return 1; }
        exec {health_fd}>&-
    fi
    cat >"$temp/RESTORE.txt" <<'RESTORE'
Operational state export; bulk logs and volatile locks/leases are excluded.
Stop the corresponding User Script before restoring its matching state files.
Keep restored Sonarr/Radarr/SAB app state and script state from compatible times.
Do not replay pending mutations or clear ambiguous journals: existing scripts
must reconcile them against current exact API/file IDs. Restoring state does not
prove actions were completed. Preserve owner/mode and review paths first.
Never restore /run heartbeats, process IDs or maintenance leases across boots.
Private disk-health configuration is included; keep this snapshot access private.
RESTORE
    vault_capture_recovery "$temp/recovery" || { exec {fd}>&-; log ERROR 'Recovery capture failed; previous export retained'; return 1; }
    local recovery_bytes=0
    while IFS= read -r -d '' file; do
        size=$(stat -c %s "$file") || { exec {fd}>&-; return 1; }
        recovery_bytes=$((recovery_bytes+size))
    done < <(find "$temp/recovery" -type f -print0)
    if (( total+recovery_bytes>OPERATIONS_STATE_MAX_BYTES && optional_media_bytes>0 )); then
        rm -f -- "$temp/media_integrity_audit/state.json.gz" "$temp/media_integrity_audit/notified.json" "$temp/media_integrity_audit/pending-notification.json"
        rmdir -- "$temp/media_integrity_audit" 2>/dev/null || true
        total=$((total-optional_media_bytes))
        log WARNING 'Optional media integrity queue omitted to preserve recovery-bundle export capacity'
    fi
    (( total+recovery_bytes <= OPERATIONS_STATE_MAX_BYTES )) || { exec {fd}>&-; log ERROR 'State and recovery capture exceed export budget; previous export retained'; return 1; }
    jq -n --argjson createdAt "$(date +%s)" --argjson bytes "$total" --argjson recoveryBytes "$recovery_bytes" '{schema:2,createdAt:$createdAt,stateBytes:$bytes,recoveryBytes:$recoveryBytes,totalBytes:($bytes+$recoveryBytes),scope:"quiescent script state plus private recovery inventory; no application databases or logs"}' >"$temp/export.json" || { exec {fd}>&-; return 1; }
    previous="${OPERATIONS_STATE_ROOT}.previous"
    [[ ! -L "$previous" ]] || { exec {fd}>&-; return 1; }
    if [[ -e "$previous" ]]; then
        [[ -d "$previous" && -f "$previous/.owner" && $(cat "$previous/.owner") == vault_operations_state ]] || { exec {fd}>&-; return 1; }
    fi
    # Recover only our known previous rename after interruption. Never delete
    # the sole usable export merely to make room for a replacement.
    if [[ ! -e "$OPERATIONS_STATE_ROOT" && -d "$previous" ]]; then mv "$previous" "$OPERATIONS_STATE_ROOT" || { exec {fd}>&-; return 1; }; fi
    if [[ -e "$previous" ]]; then rm -rf -- "$previous" || { exec {fd}>&-; return 1; }; fi
    if [[ -d "$OPERATIONS_STATE_ROOT" ]]; then mv "$OPERATIONS_STATE_ROOT" "$previous" || { exec {fd}>&-; return 1; }; fi
    if ! mv "$temp" "$OPERATIONS_STATE_ROOT"; then
        [[ ! -d "$previous" ]] || mv "$previous" "$OPERATIONS_STATE_ROOT"
        exec {fd}>&-; return 1
    fi
    rm -rf -- "$previous"
    OPERATIONS_EXPORT_TEMP=""
    exec {fd}>&-
    log INFO "Exported $total state bytes and $recovery_bytes recovery bytes; bulk logs excluded"
}

vault_inventory() {
    (cd "$1" && find . \( -name '*.partial' -o -name .rsync-partial -o -name '*.tmp' -o -name '*.sock' \) -prune -o -printf '%y:%s:%T@:%l:%p\0' | sort -z | sha256sum)
}
vault_space_preflight() {
    local job label source required=0 estimated output available
    backup_phase capacity
    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r label source <<<"$job"
        output="$TMP_DIR/$label.estimate"
        rsync "${RSYNC_ARGS[@]}" --dry-run "$source/" "$REMOTE:$REMOTE_PARTIAL/$label/" >"$output" 2>&1 || { log ERROR "Capacity estimate failed for $label"; return 1; }
        estimated=$(awk -F': ' '/^Total transferred file size:/ {gsub(/[^0-9]/,"",$2); print $2}' "$output")
        [[ "$estimated" =~ ^[0-9]+$ ]] || return 1
        required=$((required+estimated))
    done
    available=$(ssh_exec "df -P -B1 -- $(shell_quote "$REMOTE_VERSION_ROOT")" | awk 'NR==2 {print $4}') || return 1
    [[ "$available" =~ ^[0-9]+$ ]] || return 1
    log INFO "ISS capacity: estimated additional transfer=$required bytes; available=$available; reserve=$VAULT_RESERVE_BYTES"
    (( available >= required+VAULT_RESERVE_BYTES )) || { log ERROR 'Insufficient ISS capacity; completed generations were retained'; return 1; }
}

build_manifest() {
    local label="$1" source="$2" manifest="$3" row size path files=0 bytes=0 before after
    backup_phase "manifest-$label"
    backup_source_ready "$source" || return 1
    before=$(vault_inventory "$source") || return 1
    (cd "$source" && find . \( -name '*.partial' -o -name .rsync-partial -o -name '*.tmp' -o -name '*.sock' \) -prune -o -type f -printf '%s\t%p\0') >"$manifest.inventory" || return 1
    : >"$manifest.files"
    while IFS= read -r -d '' row; do
        size=${row%%$'\t'*}; path=${row#*$'\t'}
        [[ "$size" =~ ^[0-9]+$ ]] || return 1
        files=$((files+1)); bytes=$((bytes+size))
        printf '%s\0' "$path" >>"$manifest.files"
    done <"$manifest.inventory"
    (( files > 0 )) || { log ERROR "Refusing an empty source for $label"; return 1; }
    if [[ "$label" == appdata ]]; then
        vault_appdata_manifest "$source" "$manifest" || return 1
    else
        (cd "$source" && sort -z "$manifest.files" | xargs -0 -r sha256sum) >"$manifest" || return 1
    fi
    after=$(vault_inventory "$source") || return 1
    [[ "$before" == "$after" ]] || { log WARN "Source changed while hashing $label; run will be retried"; return 1; }
    MANIFEST_FILES[$label]=$files; MANIFEST_BYTES[$label]=$bytes; SOURCE_FINGERPRINT[$label]=$after
    log INFO "Manifest $label: $files files, $bytes bytes"
}

remote_prepare() {
    local signature job label source
    signature=$(printf '%s\n' "$REMOTE" "$REMOTE_VERSION_ROOT" "${BACKUP_JOBS[@]}" | sha256sum); signature=${signature%% *}
    REMOTE_FINAL="$REMOTE_VERSION_ROOT/$GENERATION_NAME"
    REMOTE_PARTIAL="$REMOTE_VERSION_ROOT/.hubble-resume.partial"
    # All mutations are under the shared ISS lease. Unknown staging is not deleted.
    backup_ssh bash -s -- "$REMOTE_VERSION_ROOT" "$signature" "$GENERATION_NAME" <<'PREPARE'
set -euo pipefail
root=$1 signature=$2 generation=$3
[[ $(realpath -e -- "$root") == "$root" && ! -L "$root" ]]
partial="$root/.hubble-resume.partial"
if [[ -e "$partial" ]]; then
    [[ -d "$partial" && ! -L "$partial" && -f "$partial/.owner" && $(cat "$partial/.owner") == vault_backup ]] || exit 1
    if [[ ! -f "$partial/.config.sha256" || $(cat "$partial/.config.sha256") != "$signature" ]]; then
        mv -T -- "$partial" "$root/.$generation.incompatible.partial"
    fi
fi
mkdir -p -- "$partial/manifests"
printf '%s\n' vault_backup >"$partial/.owner"
printf '%s\n' "$signature" >"$partial/.config.sha256"
[[ ! -L "$partial/manifests" && $(realpath -e -- "$partial/manifests") == "$partial/manifests" ]]
PREPARE
    local rc=$?
    (( rc == 0 )) || return "$rc"
    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r label source <<<"$job"
        ssh_exec "test ! -L $(shell_quote "$REMOTE_PARTIAL/$label") && mkdir -p -- $(shell_quote "$REMOTE_PARTIAL/$label") && test \"\$(realpath -e -- $(shell_quote "$REMOTE_PARTIAL/$label"))\" = $(shell_quote "$REMOTE_PARTIAL/$label")" || return 1
    done
}

transfer_job() {
    local label="$1" source="$2" manifest="$3" attempt rc output before after elapsed started force_checksum=false
    local destination="$REMOTE_PARTIAL/$label" manifest_remote="$REMOTE_PARTIAL/manifests/$label.sha256"
    local -a args=()
    output="$TMP_DIR/$label.rsync"
    for ((attempt=1; attempt<=VAULT_MAX_ATTEMPTS; attempt++)); do
        backup_lease_alive && backup_source_ready "$source" || return 1
        # Rebuild after an interruption/source change, never verify against a stale manifest.
        build_manifest "$label" "$source" "$manifest" || { (( attempt < VAULT_MAX_ATTEMPTS )) && { sleep 5; continue; }; return 1; }
        before=${SOURCE_FINGERPRINT[$label]}
        if [[ "$DRY_RUN" == true ]]; then log INFO "[DRY RUN] Would transfer ${MANIFEST_FILES[$label]} files from $source"; return 0; fi
        backup_phase "transfer-$label"
        started=$(date +%s); args=("${RSYNC_ARGS[@]}")
        [[ "$force_checksum" != true ]] || args+=(--checksum)
        "${PRIORITY_PREFIX[@]}" rsync "${args[@]}" "$source/" "$REMOTE:$destination/" 2>&1 | tail --bytes="$MAX_RAW_LOG_BYTES" >"$output"
        rc=${PIPESTATUS[0]}; elapsed=$(( $(date +%s)-started ))
        tail -n 30 -- "$output" >>"$LOG_FILE"
        log INFO "$label attempt=$attempt duration=${elapsed}s rsync_exit=$rc"
        if (( rc == 0 )); then
            after=$(vault_inventory "$source") || return 1
            if [[ "$before" != "$after" ]]; then
                log WARN "Source changed during $label transfer; rebuilding manifest and retrying"
            else
                ssh_exec "find $(shell_quote "$destination") -type d -name .rsync-partial -prune -exec rm -rf -- {} +" || return 1
                rsync -a --checksum --protect-args "--timeout=$RSYNC_IO_TIMEOUT" "$manifest" "$REMOTE:$manifest_remote" || return 1
                backup_phase "verify-$label"
                if ssh_exec "cd $(shell_quote "$destination") && sha256sum -c -- $(shell_quote "$manifest_remote") >/dev/null"; then
                    FILES_VERIFIED=$((FILES_VERIFIED+MANIFEST_FILES[$label]))
                    BYTES_TRANSFERRED=$((BYTES_TRANSFERRED+MANIFEST_BYTES[$label]))
                    return 0
                fi
                force_checksum=true
                log WARN "Checksum mismatch for $label; retry will compare source and staged file contents"
            fi
        else
            case "$rc" in 10|12|23|24|30|35) ;; 255) grep -qiE 'permission denied|host key verification failed|identification has changed' "$output" && return 1;; *) return 1;; esac
        fi
        (( attempt < VAULT_MAX_ATTEMPTS )) && sleep "$((15*attempt))"
    done
    log ERROR "Transfer/source-stability/verification attempts exhausted for $label"
    return 1
}

promote_generation() {
    local job label source map="$TMP_DIR/restore-sources.tsv"
    printf 'label\tsource_path\tgeneration_path\n' >"$map"
    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r label source <<<"$job"
        printf '%s\t%s\t%s/\n' "$label" "$source" "$label" >>"$map"
    done
    rsync -a --protect-args "--timeout=$RSYNC_IO_TIMEOUT" "$map" "$REMOTE:$REMOTE_PARTIAL/manifests/restore-sources.tsv" || return 1
    backup_ssh bash -s -- "$REMOTE_PARTIAL" "$REMOTE_FINAL" "$SRC_NAS" "$DEST_NAS" "$SCRIPT_VERSION" <<'PROMOTE'
set -euo pipefail
partial=$1 final=$2
[[ -d "$partial" && ! -L "$partial" && ! -e "$final" && ! -L "$final" ]]
printf '%s\n' "source=$3" "destination=$4" "completed=$(date -Iseconds)" "script_version=$5" >"$partial/completed.txt"
mv -T -- "$partial" "$final"
PROMOTE
}

prune_remote_generations() {
    backup_phase retention
    backup_lease_alive || return 1
    backup_ssh bash -s -- "$REMOTE_VERSION_ROOT" "$REMOTE_KEEP" "$PARTIAL_RETENTION_DAYS" <<'RETENTION'
set -euo pipefail
root=$1 keep=$2 days=$3
[[ $(realpath -e -- "$root") == "$root" && ! -L "$root" ]]
list=$(mktemp /tmp/vault-retention.XXXXXX)
trap 'rm -f -- "$list" "$list.partial"' EXIT
find "$root" -mindepth 1 -maxdepth 1 -type d -name 'hubble-*' -printf '%f\n' | sort -r >"$list"
mapfile -t entries <"$list"
count=0
for entry in "${entries[@]}"; do
    [[ "$entry" =~ ^hubble-[0-9]{8}_[0-9]{6}$ ]] || continue
    [[ -f "$root/$entry/completed.txt" && ! -L "$root/$entry" ]] || continue
    count=$((count+1))
    (( count <= keep )) || rm -rf -- "$root/$entry"
done
# Only script-owned abandoned staging is eligible. Current resumable staging
# and unmarked historical partials are deliberately retained.
find "$root" -mindepth 1 -maxdepth 1 -type d -name '.hubble-*.partial' -mtime "+$days" -print0 >"$list.partial"
while IFS= read -r -d '' path; do
    [[ "$path" != "$root/.hubble-resume.partial" && ! -L "$path" ]] || continue
    [[ -f "$path/.owner" && $(cat "$path/.owner") == vault_backup ]] || continue
    printf 'Removing expired owned partial: %s\n' "$path"
    rm -rf -- "$path"
done <"$list.partial"
find "$root" -mindepth 1 -maxdepth 1 -type d -name '*.partial' -exec du -sh -- {} \;
RETENTION
}

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
    local blockers=""
    local blocker_status=0

    [[ "$SHUTDOWN_REMOTE_ON_SUCCESS" == true ]] || return 0
    backup_lease_alive || { REMOTE_SHUTDOWN_SKIPPED_REASON="Shared ISS lease is not held"; return 0; }

    if ! backup_shutdown_handoff; then log INFO "$REMOTE_SHUTDOWN_SKIPPED_REASON"; return 0; fi
    blockers="$(remote_shutdown_blockers 2>/dev/null)"
    blocker_status=$?

    if (( blocker_status != 0 )); then
        REMOTE_SHUTDOWN_SKIPPED_REASON="Mover/parity status could not be verified"
        log WARN "Remote shutdown skipped: ${REMOTE_SHUTDOWN_SKIPPED_REASON}. $DEST_NAS will remain powered on."
        return 0
    fi

    if [[ -n "$blockers" ]]; then
        REMOTE_SHUTDOWN_SKIPPED_REASON="${blockers//$'\n'/; }"
        log WARN "Remote shutdown skipped: ${REMOTE_SHUTDOWN_SKIPPED_REASON}. $DEST_NAS will remain powered on."
        return 0
    fi

    log INFO "Requesting clean shutdown of $DEST_NAS"
    if backup_request_shutdown; then SHUTDOWN_RESULT=requested; return 0; fi

    REMOTE_SHUTDOWN_FAILED=1
    SHUTDOWN_RESULT=failed_or_unconfirmed
    log WARN "Remote shutdown request failed"
    return 1
}

###############################################################################
# MAIN
###############################################################################

vault_usage() {
    cat <<'HELP'
Usage: bash script [--help|--version|--force]
Installed Unraid entry: backup_vault_remote; GitHub source: backup_vault_remote.sh.

Schedule: 10 * * * * (hourly at minute 10, Singapore time).
This is a scheduled completion-request check, not a continuously running daemon.
No request/already delivered: local no-op; no ISS SSH/WOL, new backup log or email.

A successful backup_cache_appdata publishes a request for its verified local generation.
A new valid request causes all configured jobs (appdata, flash, User Scripts,
GitHub, photos and operational state) to be copied into a new ISS generation.
Verify SHA-256, promote atomically, acknowledge delivery, retain three successful
remote generations, run the weekly drill when due, then request guarded shutdown.

Undelivered requests retry on later checks. Identical request/failure notifications
are limited to one per 24 hours; new reasons notify immediately. Verified success
reports recovery, and failed notification sends remain eligible for retry.
Requests older than 72 hours, changed
sources or invalid manifests fail safely. Retention/drill/shutdown warnings after
delivery acknowledgement do not automatically trigger another full copy.
Photos/GitHub/flash changes alone do not trigger delivery in completion-driven mode.

--force repeats the current request despite delivery acknowledgement, while keeping
source/freshness/integrity checks. It may wake ISS and transfer every backup job.
Help/version perform no backup work. Preserve the installed DRY_RUN setting.
HELP
}
main() {
    local job label source manifest notification_message
    case "${1:-}" in
        --help|-h) vault_usage; return 0;;
        --version) printf 'backup_vault_remote.sh %s (Unraid entry: backup_vault_remote)\n' "$SCRIPT_VERSION"; return 0;;
        ""|--force) ;;
        *) vault_usage >&2; return 2;;
    esac
    exec 9>"$LOCK_FILE" || return 1
    flock -n 9 || { printf 'Another vault backup is active\n' >&2; return 1; }
    local pending_rc=0
    if [[ "$COMPLETION_DRIVEN" == true ]]; then
        vault_pending_request "${1:-}" || pending_rc=$?
        if (( pending_rc == 10 )); then printf 'No new completed appdata generation; ISS remains undisturbed\n'; return 0; fi
        if (( pending_rc != 0 )); then
            notify_unraid warning "ISS handoff unavailable" "Reason: $VAULT_NOTIFICATION_REASON. Pending appdata request is malformed, stale, or its source changed. No ISS wake or transfer was attempted. A fresh successful appdata backup is required."
            return 1
        fi
    fi
    trap backup_finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 141' PIPE
    backup_transport_init || return 1

    if ! mountpoint -q /mnt/vault || ! mountpoint -q /boot; then
        printf 'Required local mounts are unavailable: /mnt/vault and/or /boot\n' >&2
        return 1
    fi
    mkdir -p -- "$LOG_DIR" || return 1
    : >"$LOG_FILE" || return 1
    prune_local_logs


    log INFO "Starting $SRC_NAS -> $DEST_NAS versioned backup (dry_run=$DRY_RUN)"
    validate_configuration || return 1
    build_priority_prefix
    TMP_DIR="$(mktemp -d /tmp/backup_vault_remote.XXXXXX)" || return 1
    vault_producer_locks || return 1
    for job in "${BACKUP_JOBS[@]}"; do
        if [[ "$job" == "operations_state|$OPERATIONS_STATE_ROOT" ]]; then
            # Dry run also captures local state consistently; remote remains read-only.
            vault_export_operations_state || return 1
        fi
    done
    vault_select_sources || return 1
    if [[ -n "$ISS_REQUEST_ID" ]]; then
        local matched=false
        for job in "${BACKUP_JOBS[@]}"; do
            [[ "$job" != "appdata|$ISS_REQUEST_GENERATION" ]] || matched=true
        done
        [[ "$matched" == true ]] || { log ERROR "Producer advanced; pending request will be retried on the next check"; return 1; }
    fi
    wait_for_remote || return 1
    backup_phase capabilities
    backup_capabilities || { log ERROR "Local/ISS capability validation failed; no backup was published. ISS is left available for retry."; return 1; }
    backup_acquire_lease || { log ERROR "ISS is already in use by another backup, or lease acquisition failed"; return 1; }
    [[ "$PRESERVE_HARD_LINKS" != true ]] || RSYNC_ARGS+=(-H)
    RSYNC_ARGS+=("--timeout=$RSYNC_IO_TIMEOUT")
    RSYNC_ARGS+=("--rsync-path=LC_ALL=C rsync")
    backup_phase prepare
    if [[ "$DRY_RUN" != true ]]; then
        remote_prepare || {
            log ERROR "Unable to create remote partial generation"
            return 1
        }
    fi

    if [[ "$DRY_RUN" != true ]]; then vault_space_preflight || return 1; fi
    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r label source <<<"$job"
        manifest="${TMP_DIR}/${label}.sha256"
        transfer_job "$label" "$source" "$manifest" || {
            log ERROR "Transfer or verification failed for $label"
            return 1
        }
    done

    if [[ "$DRY_RUN" == true ]]; then
        BACKUP_RESULT=DRY_RUN; VERIFICATION_RESULT=not_performed

        RESULT_SUMMARY="Dry run completed; no remote generation was created"
        log INFO "$RESULT_SUMMARY"
        notify_unraid normal "Dry run completed" "$RESULT_SUMMARY"$'\n'"Log: $LOG_FILE"

        return 0
    fi

    backup_phase promotion
    backup_lease_alive || return 1
    promote_generation || {
        log ERROR "Remote generation promotion failed; partial data was retained"
        return 1
    }

    BACKUP_RESULT=OK; VERIFICATION_RESULT=sha256_verified
    vault_acknowledge_request || { log ERROR "Remote generation verified but local handoff acknowledgement failed; retry remains pending"; return 1; }
    if ! prune_remote_generations; then
        RETENTION_RESULT=FAILED

        RESULT_SUMMARY="Generation verified, but retention pruning failed"
        notify_unraid warning "Backup completed with warning" \
            "$RESULT_SUMMARY"$'\n'"Generation: $REMOTE_FINAL"

        return 1
    fi

    RETENTION_RESULT=OK
    if ! vault_remote_restore_drill; then
        RESTORE_DRILL_RESULT=FAILED
        [[ -n "$RESTORE_DRILL_SUMMARY" ]] || RESTORE_DRILL_SUMMARY="ISS restore drill unavailable; verified backup retained. Review remote drill prerequisites/logs."
    fi

    RESULT_SUMMARY="Verified ${GENERATION_NAME}: ${FILES_VERIFIED} files, $(human_bytes "$BYTES_TRANSFERRED")"
    log INFO "$RESULT_SUMMARY"
    backup_phase shutdown
    shutdown_remote || true
    notification_message="$RESULT_SUMMARY"$'\n'"Destination: $REMOTE_FINAL"
    if [[ -n "$REMOTE_SHUTDOWN_SKIPPED_REASON" ]]; then
        notification_message+=$'\n'"Remote shutdown: skipped (${REMOTE_SHUTDOWN_SKIPPED_REASON}); $DEST_NAS left powered on"
    elif (( REMOTE_SHUTDOWN_FAILED == 1 )); then
        notification_message+=$'\n'"Remote shutdown: request failed"
    fi
    notification_message+=$'\n'"Recovery inventory: $RECOVERY_SUMMARY"
    notification_message+=$'\n'"Restore drill: $RESTORE_DRILL_RESULT. $RESTORE_DRILL_SUMMARY"
    local importance=normal
    [[ "$RECOVERY_CAPTURE_WARNING" != true ]] || importance=warning
    case "$RESTORE_DRILL_RESULT" in FAILED|WARNING) importance=warning;; esac
    if [[ -n "$REMOTE_SHUTDOWN_SKIPPED_REASON" && "$SHUTDOWN_RESULT" != deferred ]] || (( REMOTE_SHUTDOWN_FAILED != 0 )); then importance=warning; fi
    notify_unraid "$importance" "Backup completed" "$notification_message"

}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
