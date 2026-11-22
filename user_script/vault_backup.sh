#!/bin/bash

###############################################################################
# Hubble -> ISS Versioned Backup
#
# Creates independent timestamped generations on ISS without Btrfs snapshots
# or hard links. A generation is built in a hidden .partial directory, every
# regular file is verified against a SHA-256 manifest, and only then is the
# generation atomically promoted. Previous generations are pruned after a new
# generation succeeds.
###############################################################################

set -uo pipefail
export LC_ALL=C
umask 077

readonly SCRIPT_VERSION="1.5"

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

USE_LOW_PRIORITY_IO=true
IONICE_CLASS=2
IONICE_PRIORITY=7
NICE_LEVEL=10

LOG_DIR="/mnt/vault/cloud/logs/script/vault_backup"
MAX_LOGS=5
STATUS_DIR="/mnt/vault/cloud/logs/script/user_scripts_status"
NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
LOCK_FILE="/run/vault_backup.lock"

readonly SCRIPT_ID="vault_backup"

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
backup_capabilities() {
    local cmd value
    for value in "$RSYNC_IO_TIMEOUT" "$MAX_MAIN_LOG_BYTES" "$MAX_RAW_LOG_BYTES"; do [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1; done
    [[ "$PRESERVE_HARD_LINKS" == true || "$PRESERVE_HARD_LINKS" == false ]] || return 1
    [[ "$SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( SSH_PORT <= 65535 )) || return 1
    for cmd in ssh rsync jq timeout flock realpath sha256sum stat find sort awk tail head tee date mktemp xargs grep cat du mountpoint; do command -v "$cmd" >/dev/null || return 1; done
    # The options used here are supported by rsync >= 3.1, on BOTH ends.
    printf 'Local: %s\n' "$(rsync --version | head -n 1)" >>"$LOG_FILE"
    rsync --version | awk 'NR==1 {split($3,v,"."); exit !(v[1]>3 || (v[1]==3 && v[2]>=1))}' || return 1
    local remote_boot
    remote_boot=$(BACKUP_SSH_COMMAND_TIMEOUT=30 backup_ssh 'cat /proc/sys/kernel/random/boot_id') || return 1
    [[ -n "$remote_boot" && "$remote_boot" != "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" ]] || return 1
    BACKUP_SSH_COMMAND_TIMEOUT=30 backup_ssh bash -s <<'CAPABILITIES'
set -euo pipefail
export LC_ALL=C
for cmd in bash rsync flock realpath sha256sum stat find sort awk df mktemp du mv cat; do command -v "$cmd" >/dev/null; done
rsync --version | awk 'NR==1 {split($3,v,"."); exit !(v[1]>3 || (v[1]==3 && v[2]>=1))}'
rsync --version | head -n 1
CAPABILITIES
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
        if timeout 30 "$NOTIFY_BIN" -i alert -s "${SCRIPT_ID}" -d 'Backup failed' -m "$summary
Log: $LOG_FILE" >/dev/null 2>&1; then NOTIFICATION_RESULT=sent; else NOTIFICATION_RESULT=failed; fi
    fi
    [[ "$NOTIFICATION_RESULT" != failed && "$NOTIFICATION_RESULT" != unavailable || "$status" != OK ]] || status=WARNING
    if mountpoint -q /mnt/vault && command -v jq >/dev/null; then
        mkdir -p -- "$STATUS_DIR"
        temp=$(mktemp "$STATUS_DIR/.${SCRIPT_ID}.XXXXXX") &&
            jq -n --arg name "$SCRIPT_ID" --arg status "$status" --arg summary "$summary" --arg phase "$BACKUP_PHASE" --arg copy "$BACKUP_RESULT" --arg verification "$VERIFICATION_RESULT" --arg retention "$RETENTION_RESULT" --arg notification "$NOTIFICATION_RESULT" --arg shutdown "$SHUTDOWN_RESULT" --arg shutdown_reason "${REMOTE_SHUTDOWN_SKIPPED_REASON:-}" --arg version "$SCRIPT_VERSION" --arg log "$LOG_FILE" --argjson duration "$(( $(date +%s)-BACKUP_STARTED ))" --argjson epoch "$(date +%s)" \
            '{name:$name,status:$status,summary:$summary,phase:$phase,copy:$copy,verification:$verification,retention:$retention,notification:$notification,shutdown:$shutdown,shutdown_reason:$shutdown_reason,scriptVersion:$version,duration_seconds:$duration,log:$log,epoch:$epoch}' >"$temp" && mv -f -- "$temp" "$STATUS_DIR/$SCRIPT_ID.json"
    fi
    [[ -z "$LEASE_INPUT" ]] || exec {LEASE_INPUT}>&-
    [[ -z "$LEASE_PID" ]] || { kill "$LEASE_PID" 2>/dev/null || true; wait "$LEASE_PID" 2>/dev/null || true; }
    [[ ${#TRANSPORT_OPTIONS[@]} == 0 ]] || ssh "${TRANSPORT_OPTIONS[@]}" -O exit "$REMOTE" >/dev/null 2>&1 || true
    [[ -z "$BACKUP_TMP" ]] || rm -rf -- "$BACKUP_TMP"
    [[ -z "${TMP_DIR:-}" ]] || rm -rf -- "$TMP_DIR"
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
LOG_FILE="${LOG_DIR}/vault-to-iss-${RUN_STAMP}.log"

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
    printf -v line '%s [%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
    printf '%s\n' "$line"
    [[ -n "$LOG_FILE" && -d "$LOG_DIR" ]] &&
        { backup_bound_log "$LOG_FILE" "$MAX_MAIN_LOG_BYTES" && printf '%s\n' "$line" >>"$LOG_FILE"; } 2>/dev/null || true
}

notify_unraid() {
    BACKUP_NOTIFIED=true
    local importance="$1" description="$2" message="$3"
    [[ -x "$NOTIFY_BIN" ]] || { NOTIFICATION_RESULT=unavailable; return 0; }
    if timeout 30 "$NOTIFY_BIN" -i "$importance" -s "Vault to ISS Backup" -d "$description" -m "$message" >/dev/null 2>&1; then
        NOTIFICATION_RESULT=sent
    else
        NOTIFICATION_RESULT=failed
        log WARN 'Notification delivery failed; backup outcome remains in the status receipt'
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
        find "$LOG_DIR" -maxdepth 1 -type f -name 'vault-to-iss-*.log' \
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
        [[ "$label" != . && "$label" != .. && -z "${seen_labels[$label]:-}" && "$label" =~ ^[A-Za-z0-9._-]+$ ]] || {
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
    for file in /tmp/appdata_backup.lock /tmp/flash_backup.lock; do
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
    (cd "$source" && sort -z "$manifest.files" | xargs -0 -r sha256sum) >"$manifest" || return 1
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
        "${PRIORITY_PREFIX[@]}" rsync "${args[@]}" "$source/" "$REMOTE:$destination/" 2>&1 | tail -c "$MAX_RAW_LOG_BYTES" >"$output"
        rc=${PIPESTATUS[0]}; elapsed=$(( $(date +%s)-started ))
        tail -n 30 -- "$output" >>"$LOG_FILE"
        log INFO "$label attempt=$attempt duration=${elapsed}s rsync_exit=$rc"
        if (( rc == 0 )); then
            after=$(vault_inventory "$source") || return 1
            if [[ "$before" != "$after" ]]; then
                log WARN "Source changed during $label transfer; rebuilding manifest and retrying"
            else
                ssh_exec "find $(shell_quote "$destination") -type d -name .rsync-partial -prune -exec rm -rf -- {} +" || return 1
                rsync -a --protect-args "--timeout=$RSYNC_IO_TIMEOUT" "$manifest" "$REMOTE:$manifest_remote" || return 1
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

main() {
    local job label source manifest notification_message
    exec 9>"$LOCK_FILE" || return 1
    flock -n 9 || { printf 'Another vault backup is active\n' >&2; return 1; }
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
    TMP_DIR="$(mktemp -d /tmp/vault-to-iss.XXXXXX)" || return 1
    wait_for_remote || return 1
    backup_phase capabilities
    backup_capabilities || return 1
    backup_acquire_lease || { log ERROR "ISS is already in use by another backup, or lease acquisition failed"; return 1; }
    [[ "$PRESERVE_HARD_LINKS" != true ]] || RSYNC_ARGS+=(-H)
    RSYNC_ARGS+=("--timeout=$RSYNC_IO_TIMEOUT")
    vault_producer_locks || return 1
    vault_select_sources || return 1

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
    if ! prune_remote_generations; then
        RETENTION_RESULT=FAILED

        RESULT_SUMMARY="Generation verified, but retention pruning failed"
        notify_unraid warning "Backup completed with warning" \
            "$RESULT_SUMMARY"$'\n'"Generation: $REMOTE_FINAL"

        return 1
    fi

    RETENTION_RESULT=OK

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
    local importance=normal
    if [[ -n "$REMOTE_SHUTDOWN_SKIPPED_REASON" && "$SHUTDOWN_RESULT" != deferred ]] || (( REMOTE_SHUTDOWN_FAILED != 0 )); then importance=warning; fi
    notify_unraid "$importance" "Backup completed" "$notification_message"

}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
