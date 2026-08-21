#!/bin/bash

###############################################################################
# Metadata Quarantine Lifecycle Manager
#
# Audits, restores, and optionally expires run directories created by
# metadata_cleanup.sh under /mnt/user/media/bin.
#
# Usage:
#   quarantine_lifecycle.sh audit
#   quarantine_lifecycle.sh purge
#   quarantine_lifecycle.sh restore RUN_ID movies|series RELATIVE_PATH
###############################################################################

set -uo pipefail
umask 077

readonly SCRIPT_VERSION="1.0"

###############################################################################
# CONFIGURATION
###############################################################################

QUARANTINE_ROOT="/mnt/user/media/bin"
MOVIES_ROOT="/mnt/user/media/movies"
SERIES_ROOT="/mnt/user/media/series"

RETENTION_DAYS=45
WARNING_TOTAL_BYTES=$((500 * 1024 * 1024 * 1024))

# Both gates must be changed before purge can delete expired run directories.
ALLOW_PURGE=false
PURGE_DRY_RUN=true

LOG_DIR="/mnt/vault/cloud/logs/quarantine_lifecycle"
LOG_FILE="${LOG_DIR}/quarantine-lifecycle.log"
INDEX_FILE="${LOG_DIR}/quarantine-index.tsv"
LOG_MAX_BYTES=$((5 * 1024 * 1024))

STATUS_DIR="/mnt/vault/cloud/logs/user_scripts_status"
NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
LOCK_FILE="/run/quarantine_lifecycle.lock"

###############################################################################
# RUNTIME
###############################################################################

START_EPOCH="$(date +%s)"
RESULT_STATUS="FAILED"
RESULT_SUMMARY="Quarantine lifecycle exited before completion"
RECEIPT_WRITTEN=0

RUNS_SCANNED=0
EXPIRED_RUNS=0
FILES_SCANNED=0
TOTAL_BYTES=0
PURGED_RUNS=0
PURGED_BYTES=0

###############################################################################
# HELPERS
###############################################################################

log() {
    local level="$1"
    shift
    local line
    printf -v line '%s [%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
    printf '%s\n' "$line"
    [[ -d "$LOG_DIR" ]] && printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
}

rotate_log() {
    local size
    [[ -f "$LOG_FILE" ]] || return 0
    size="$(stat -c '%s' "$LOG_FILE" 2>/dev/null || printf 0)"
    (( size < LOG_MAX_BYTES )) || mv -f -- "$LOG_FILE" "${LOG_FILE}.1"
}

notify_unraid() {
    local importance="$1" description="$2" message="$3"
    [[ -x "$NOTIFY_BIN" ]] || return 0
    "$NOTIFY_BIN" -i "$importance" -s "Quarantine Lifecycle" \
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

tree_bytes() {
    find "$1" -type f -printf '%s\n' 2>/dev/null |
        awk '{s+=$1} END {printf "%.0f", s+0}'
}

tree_files() {
    find "$1" -type f -printf '.' 2>/dev/null | wc -c
}

write_receipt() {
    local status="$1" summary="$2" now tmp
    now="$(date +%s)"
    mkdir -p -- "$STATUS_DIR" 2>/dev/null || return 0
    command -v jq >/dev/null 2>&1 || return 0
    tmp="$(mktemp "${STATUS_DIR}/.quarantine_lifecycle.XXXXXX")" || return 0
    if jq -n \
        --arg name "quarantine_lifecycle" \
        --arg status "$status" \
        --arg summary "$summary" \
        --arg log "$LOG_FILE" \
        --argjson epoch "$now" \
        --argjson duration "$((now - START_EPOCH))" \
        '{name:$name,status:$status,summary:$summary,log:$log,epoch:$epoch,duration_seconds:$duration}' \
        >"$tmp"
    then
        mv -f -- "$tmp" "${STATUS_DIR}/quarantine_lifecycle.json"
        RECEIPT_WRITTEN=1
    else
        rm -f -- "$tmp"
    fi
}

cleanup() {
    local rc=$?
    if (( RECEIPT_WRITTEN == 0 )); then
        write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
    fi
    trap - EXIT
    exit "$rc"
}
trap cleanup EXIT

validate_roots() {
    [[ "$QUARANTINE_ROOT" == /mnt/user/* &&
       "$QUARANTINE_ROOT" != "/mnt/user/" &&
       "$QUARANTINE_ROOT" != "$MOVIES_ROOT" &&
       "$QUARANTINE_ROOT" != "$SERIES_ROOT" ]] || {
        log ERROR "Unsafe quarantine root: $QUARANTINE_ROOT"
        return 1
    }
    [[ "$MOVIES_ROOT" == /mnt/user/* && "$SERIES_ROOT" == /mnt/user/* ]] || {
        log ERROR "Unsafe media roots"
        return 1
    }
    mkdir -p -- "$QUARANTINE_ROOT" || {
        log ERROR "Unable to create quarantine root: $QUARANTINE_ROOT"
        return 1
    }
}

valid_run_id() {
    [[ "$1" =~ ^[0-9]{8}_[0-9]{6}_[0-9]+$ ]]
}

valid_relative_path() {
    local relative="$1"
    [[ -n "$relative" &&
       "$relative" != /* &&
       "$relative" != ".." &&
       "$relative" != ../* &&
       "$relative" != */../* &&
       "$relative" != */.. &&
       "$relative" != *$'\n'* ]]
}

###############################################################################
# AUDIT
###############################################################################

audit_quarantine() {
    local tmp run run_id modified age_days files bytes expired
    log INFO "Starting quarantine lifecycle audit v$SCRIPT_VERSION"
    tmp="$(mktemp "${LOG_DIR}/.quarantine-index.XXXXXX")" || return 1
    printf 'run_id\tmodified_epoch\tage_days\tfiles\tbytes\texpired\n' >"$tmp"

    while IFS= read -r -d '' run; do
        run_id="$(basename "$run")"
        valid_run_id "$run_id" || {
            log WARN "Ignoring non-managed quarantine entry: $run_id"
            continue
        }
        modified="$(stat -c '%Y' "$run" 2>/dev/null || printf 0)"
        age_days=$(((START_EPOCH - modified) / 86400))
        (( age_days < 0 )) && age_days=0
        files="$(tree_files "$run")"
        bytes="$(tree_bytes "$run")"
        expired=false
        if (( age_days >= RETENTION_DAYS )); then
            expired=true
            EXPIRED_RUNS=$((EXPIRED_RUNS + 1))
        fi
        RUNS_SCANNED=$((RUNS_SCANNED + 1))
        FILES_SCANNED=$((FILES_SCANNED + files))
        TOTAL_BYTES=$((TOTAL_BYTES + bytes))
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$run_id" "$modified" "$age_days" "$files" "$bytes" "$expired" >>"$tmp"
    done < <(
        find "$QUARANTINE_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 \
            2>/dev/null | sort -z
    )

    mv -f -- "$tmp" "$INDEX_FILE"
    log INFO "Audit: $RUNS_SCANNED runs, $FILES_SCANNED files, $(human_bytes "$TOTAL_BYTES"), $EXPIRED_RUNS expired"
}

###############################################################################
# RESTORE
###############################################################################

restore_item() {
    local run_id="$1" bucket="$2" relative="$3"
    local source destination root source_resolved destination_resolved

    valid_run_id "$run_id" || {
        log ERROR "Invalid run ID: $run_id"
        return 1
    }
    valid_relative_path "$relative" || {
        log ERROR "Unsafe relative restore path: $relative"
        return 1
    }
    case "$bucket" in
        movies) root="$MOVIES_ROOT" ;;
        series) root="$SERIES_ROOT" ;;
        *)
            log ERROR "Restore bucket must be movies or series"
            return 1
            ;;
    esac

    source="${QUARANTINE_ROOT}/${run_id}/${bucket}/${relative}"
    destination="${root}/${relative}"
    source_resolved="$(readlink -m -- "$source")" || return 1
    destination_resolved="$(readlink -m -- "$destination")" || return 1

    [[ "$source_resolved" == "$QUARANTINE_ROOT"/* &&
       "$destination_resolved" == "$root"/* ]] || {
        log ERROR "Resolved restore path escaped its configured root"
        return 1
    }
    [[ -e "$source" || -L "$source" ]] || {
        log ERROR "Quarantined item does not exist: $source"
        return 1
    }
    [[ ! -e "$destination" && ! -L "$destination" ]] || {
        log ERROR "Restore destination already exists: $destination"
        return 1
    }

    mkdir -p -- "$(dirname "$destination")" || return 1
    mv -- "$source" "$destination" || return 1
    find "${QUARANTINE_ROOT}/${run_id}" -depth -type d -empty -delete \
        2>/dev/null || true

    RESULT_STATUS="OK"
    RESULT_SUMMARY="Restored $bucket/$relative from $run_id"
    log INFO "$RESULT_SUMMARY -> $destination"
    notify_unraid normal "Quarantined item restored" "$RESULT_SUMMARY"
}

###############################################################################
# PURGE
###############################################################################

purge_expired() {
    local run run_id modified age_days bytes

    [[ "$ALLOW_PURGE" == true ]] || {
        log ERROR "Purge is disabled; set ALLOW_PURGE=true after reviewing $INDEX_FILE"
        return 1
    }

    while IFS= read -r -d '' run; do
        run_id="$(basename "$run")"
        valid_run_id "$run_id" || continue
        modified="$(stat -c '%Y' "$run" 2>/dev/null || printf 0)"
        age_days=$(((START_EPOCH - modified) / 86400))
        (( age_days >= RETENTION_DAYS )) || continue
        bytes="$(tree_bytes "$run")"

        if [[ "$PURGE_DRY_RUN" == true ]]; then
            log INFO "[DRY RUN] Would purge $run_id (${age_days}d, $(human_bytes "$bytes"))"
            continue
        fi

        log WARN "Purging expired quarantine run: $run_id"
        rm -rf -- "$run" || {
            log ERROR "Failed to purge: $run"
            return 1
        }
        PURGED_RUNS=$((PURGED_RUNS + 1))
        PURGED_BYTES=$((PURGED_BYTES + bytes))
    done < <(
        find "$QUARANTINE_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 \
            2>/dev/null
    )

    if [[ "$PURGE_DRY_RUN" == true ]]; then
        RESULT_STATUS="WARNING"
        RESULT_SUMMARY="Purge dry run completed; no data deleted"
    else
        RESULT_STATUS="OK"
        RESULT_SUMMARY="Purged $PURGED_RUNS runs and $(human_bytes "$PURGED_BYTES")"
    fi
    log INFO "$RESULT_SUMMARY"
}

###############################################################################
# MAIN
###############################################################################

main() {
    local mode="${1:-audit}"
    if ! mountpoint -q /mnt/vault || ! mountpoint -q /mnt/user; then
        printf 'Required mounts are unavailable: /mnt/vault and/or /mnt/user\n' >&2
        return 1
    fi
    mkdir -p -- "$LOG_DIR" || return 1
    rotate_log
    touch "$LOG_FILE" || return 1

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        RESULT_SUMMARY="Another quarantine lifecycle run is active"
        log ERROR "$RESULT_SUMMARY"
        return 1
    fi
    validate_roots || return 1

    case "$mode" in
        audit)
            audit_quarantine || return 1
            if (( TOTAL_BYTES >= WARNING_TOTAL_BYTES || EXPIRED_RUNS > 0 )); then
                RESULT_STATUS="WARNING"
                RESULT_SUMMARY="$EXPIRED_RUNS expired runs; quarantine uses $(human_bytes "$TOTAL_BYTES")"
                notify_unraid warning "Quarantine review required" \
                    "$RESULT_SUMMARY"$'\n'"Index: $INDEX_FILE"
            else
                RESULT_STATUS="OK"
                RESULT_SUMMARY="$RUNS_SCANNED runs, $FILES_SCANNED files, $(human_bytes "$TOTAL_BYTES")"
            fi
            ;;
        purge)
            audit_quarantine || return 1
            purge_expired || return 1
            notify_unraid warning "Quarantine purge completed" "$RESULT_SUMMARY"
            ;;
        restore)
            (( $# == 4 )) || {
                log ERROR "Usage: $0 restore RUN_ID movies|series RELATIVE_PATH"
                return 2
            }
            restore_item "$2" "$3" "$4" || return 1
            ;;
        *)
            log ERROR "Unknown mode: $mode"
            return 2
            ;;
    esac

    write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
}

main "$@"
