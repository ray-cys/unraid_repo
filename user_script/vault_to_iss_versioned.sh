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
umask 077

readonly SCRIPT_VERSION="1.1.1"

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
SHUTDOWN_REMOTE_ON_SUCCESS=true

# Keep true for the first manually reviewed run.
DRY_RUN=true

USE_LOW_PRIORITY_IO=true
IONICE_CLASS=2
IONICE_PRIORITY=7
NICE_LEVEL=10

LOG_DIR="/mnt/vault/cloud/logs/vault_to_iss"
MAX_LOGS=5
STATUS_DIR="/mnt/vault/cloud/logs/user_scripts_status"
NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
LOCK_FILE="/run/vault_to_iss_versioned.lock"

###############################################################################
# RUNTIME
###############################################################################

RUN_STAMP="$(date '+%Y%m%d_%H%M%S')"
GENERATION_NAME="hubble-${RUN_STAMP}"
REMOTE_PARTIAL="${REMOTE_VERSION_ROOT}/.${GENERATION_NAME}.partial"
REMOTE_FINAL="${REMOTE_VERSION_ROOT}/${GENERATION_NAME}"
LOG_FILE="${LOG_DIR}/vault-to-iss-${RUN_STAMP}.log"

TMP_DIR=""
START_EPOCH="$(date +%s)"
RESULT_STATUS="FAILED"
RESULT_SUMMARY="Script exited before completion"
RECEIPT_WRITTEN=0
REMOTE_READY=0
FILES_VERIFIED=0
BYTES_TRANSFERRED=0

SSH_OPTIONS=(
    -p "$SSH_PORT"
    -o BatchMode=yes
    -o ConnectTimeout=8
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
)

RSYNC_ARGS=(
    -aH
    --delete-delay
    --partial
    --protect-args
    --stats
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
        printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
}

notify_unraid() {
    local importance="$1" description="$2" message="$3"
    [[ -x "$NOTIFY_BIN" ]] || return 0
    "$NOTIFY_BIN" -i "$importance" -s "Vault to ISS Backup" \
        -d "$description" -m "$message" >/dev/null 2>&1 || true
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
    ssh "${SSH_OPTIONS[@]}" "$REMOTE" "$1"
}

write_receipt() {
    local status="$1" summary="$2" now tmp
    now="$(date +%s)"
    mkdir -p -- "$STATUS_DIR" 2>/dev/null || return 0
    command -v jq >/dev/null 2>&1 || return 0
    tmp="$(mktemp "${STATUS_DIR}/.vault_to_iss_versioned.XXXXXX")" || return 0
    if jq -n \
        --arg name "vault_to_iss_versioned" \
        --arg status "$status" \
        --arg summary "$summary" \
        --arg log "$LOG_FILE" \
        --argjson epoch "$now" \
        --argjson duration "$((now - START_EPOCH))" \
        '{name:$name,status:$status,summary:$summary,log:$log,epoch:$epoch,duration_seconds:$duration}' \
        >"$tmp"
    then
        mv -f -- "$tmp" "${STATUS_DIR}/vault_to_iss_versioned.json"
        RECEIPT_WRITTEN=1
    else
        rm -f -- "$tmp"
    fi
}

cleanup() {
    local rc=$?
    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf -- "$TMP_DIR"
    if (( RECEIPT_WRITTEN == 0 )); then
        write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
    fi
    trap - EXIT
    exit "$rc"
}
trap cleanup EXIT

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
    local job label source command
    [[ "$REMOTE_VERSION_ROOT" == /mnt/user/* &&
       "$REMOTE_VERSION_ROOT" != "/mnt/user/" &&
       "$REMOTE_VERSION_ROOT" != *$'\n'* ]] || {
        log ERROR "Unsafe REMOTE_VERSION_ROOT: $REMOTE_VERSION_ROOT"
        return 1
    }
    [[ "$REMOTE_KEEP" =~ ^[1-9][0-9]*$ ]] || {
        log ERROR "REMOTE_KEEP must be at least 1"
        return 1
    }
    (( ${#BACKUP_JOBS[@]} > 0 )) || {
        log ERROR "No BACKUP_JOBS are configured"
        return 1
    }

    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r label source <<<"$job"
        [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || {
            log ERROR "Unsafe backup label: $label"
            return 1
        }
        [[ "$source" == /* && "$source" != "/" && -d "$source" ]] || {
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
    local waited=0 root_q
    root_q="$(shell_quote "$REMOTE_VERSION_ROOT")"
    send_wol

    while (( waited <= MAX_SSH_WAIT )); do
        if ssh_exec "true" >/dev/null 2>&1; then
            REMOTE_READY=1
            break
        fi
        (( waited == 0 )) && log INFO "Waiting for $DEST_NAS SSH"
        sleep "$SSH_WAIT_INTERVAL"
        waited=$((waited + SSH_WAIT_INTERVAL))
    done

    (( REMOTE_READY == 1 )) || {
        log ERROR "$DEST_NAS did not become reachable within ${MAX_SSH_WAIT}s"
        return 1
    }

    ssh_exec "mountpoint -q /mnt/user && test -d $root_q && test ! -L $root_q" ||
    {
        log ERROR "Remote /mnt/user or version root is not ready: $REMOTE_VERSION_ROOT"
        return 1
    }
}

build_manifest() {
    local label="$1" source="$2" manifest="$3"
    log INFO "Building SHA-256 manifest for $label"
    (
        cd "$source" || exit 1
        find . -type f -print0 | sort -z | xargs -0 -r sha256sum
    ) >"$manifest"
}

remote_prepare() {
    local partial_q final_q manifests_q
    partial_q="$(shell_quote "$REMOTE_PARTIAL")"
    final_q="$(shell_quote "$REMOTE_FINAL")"
    manifests_q="$(shell_quote "${REMOTE_PARTIAL}/manifests")"
    ssh_exec "test ! -e $partial_q && test ! -e $final_q && mkdir -p -- $manifests_q"
}

transfer_job() {
    local label="$1" source="$2" manifest="$3"
    local destination="${REMOTE_PARTIAL}/${label}"
    local destination_q manifest_remote manifest_remote_q
    local local_files local_bytes

    destination_q="$(shell_quote "$destination")"
    manifest_remote="${REMOTE_PARTIAL}/manifests/${label}.sha256"
    manifest_remote_q="$(shell_quote "$manifest_remote")"
    local_files="$(find "$source" -type f -printf '.' 2>/dev/null | wc -c)"
    local_bytes="$(find "$source" -type f -printf '%s\n' 2>/dev/null |
        awk '{s+=$1} END {printf "%.0f", s+0}')"

    log INFO "Transferring $label: $local_files files, $(human_bytes "$local_bytes")"

    if [[ "$DRY_RUN" == true ]]; then
        log INFO "[DRY RUN] Would transfer and verify $source -> ${REMOTE}:${destination}/"
        return 0
    fi

    ssh_exec "mkdir -p -- $destination_q" || return 1
    "${PRIORITY_PREFIX[@]}" rsync "${RSYNC_ARGS[@]}" \
        "$source/" "${REMOTE}:${destination}/" || return 1
    rsync -a --protect-args "$manifest" "${REMOTE}:${manifest_remote}" || return 1

    log INFO "Verifying remote SHA-256 manifest for $label"
    ssh_exec "cd $destination_q && sha256sum -c -- $manifest_remote_q >/dev/null" ||
        return 1

    FILES_VERIFIED=$((FILES_VERIFIED + local_files))
    BYTES_TRANSFERRED=$((BYTES_TRANSFERRED + local_bytes))
}

promote_generation() {
    local partial_q final_q marker_q
    partial_q="$(shell_quote "$REMOTE_PARTIAL")"
    final_q="$(shell_quote "$REMOTE_FINAL")"
    marker_q="$(shell_quote "${REMOTE_PARTIAL}/completed.txt")"
    ssh_exec "printf '%s\n' 'source=$SRC_NAS' 'destination=$DEST_NAS' 'completed=$(date -Iseconds)' 'script_version=$SCRIPT_VERSION' > $marker_q && mv -- $partial_q $final_q"
}

prune_remote_generations() {
    local root_q entry path path_q
    local -a generations=()
    root_q="$(shell_quote "$REMOTE_VERSION_ROOT")"

    mapfile -t generations < <(
        ssh_exec "find $root_q -mindepth 1 -maxdepth 1 -type d -name 'hubble-[0-9]*_[0-9]*' -printf '%f\n' | sort -r"
    )

    for ((i=REMOTE_KEEP; i<${#generations[@]}; i++)); do
        entry="${generations[$i]}"
        [[ "$entry" =~ ^hubble-[0-9]{8}_[0-9]{6}$ ]] || {
            log WARN "Refusing to prune unexpected remote entry: $entry"
            continue
        }
        path="${REMOTE_VERSION_ROOT}/${entry}"
        path_q="$(shell_quote "$path")"
        log INFO "Pruning old complete generation: $path"
        ssh_exec "rm -rf -- $path_q" || return 1
    done
}

shutdown_remote() {
    [[ "$SHUTDOWN_REMOTE_ON_SUCCESS" == true ]] || return 0
    log INFO "Requesting clean shutdown of $DEST_NAS"
    ssh_exec "/usr/local/sbin/powerdown" >/dev/null 2>&1 ||
        ssh_exec "poweroff" >/dev/null 2>&1 ||
        log WARN "Remote shutdown request failed"
}

###############################################################################
# MAIN
###############################################################################

main() {
    local job label source manifest

    if ! mountpoint -q /mnt/vault || ! mountpoint -q /boot; then
        printf 'Required local mounts are unavailable: /mnt/vault and/or /boot\n' >&2
        return 1
    fi
    mkdir -p -- "$LOG_DIR" || return 1
    : >"$LOG_FILE" || return 1
    prune_local_logs

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        RESULT_SUMMARY="Another vault-to-ISS run is already active"
        log ERROR "$RESULT_SUMMARY"
        return 1
    fi

    log INFO "Starting $SRC_NAS -> $DEST_NAS versioned backup (dry_run=$DRY_RUN)"
    validate_configuration || return 1
    build_priority_prefix
    TMP_DIR="$(mktemp -d /tmp/vault-to-iss.XXXXXX)" || return 1
    wait_for_remote || return 1

    if [[ "$DRY_RUN" != true ]]; then
        remote_prepare || {
            log ERROR "Unable to create remote partial generation"
            return 1
        }
    fi

    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r label source <<<"$job"
        manifest="${TMP_DIR}/${label}.sha256"
        build_manifest "$label" "$source" "$manifest" || return 1
        transfer_job "$label" "$source" "$manifest" || {
            log ERROR "Transfer or verification failed for $label"
            return 1
        }
    done

    if [[ "$DRY_RUN" == true ]]; then
        RESULT_STATUS="WARNING"
        RESULT_SUMMARY="Dry run completed; no remote generation was created"
        log INFO "$RESULT_SUMMARY"
        notify_unraid normal "Dry run completed" "$RESULT_SUMMARY"$'\n'"Log: $LOG_FILE"
        write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
        return 0
    fi

    promote_generation || {
        log ERROR "Remote generation promotion failed; partial data was retained"
        return 1
    }

    if ! prune_remote_generations; then
        RESULT_STATUS="WARNING"
        RESULT_SUMMARY="Generation verified, but retention pruning failed"
        notify_unraid warning "Backup completed with warning" \
            "$RESULT_SUMMARY"$'\n'"Generation: $REMOTE_FINAL"
        write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
        return 1
    fi

    RESULT_STATUS="OK"
    RESULT_SUMMARY="Verified ${GENERATION_NAME}: ${FILES_VERIFIED} files, $(human_bytes "$BYTES_TRANSFERRED")"
    log INFO "$RESULT_SUMMARY"
    notify_unraid normal "Backup completed" \
        "$RESULT_SUMMARY"$'\n'"Destination: $REMOTE_FINAL"
    write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
    shutdown_remote
}

main "$@"
