#!/bin/bash

###############################################################################
# Metadata Quarantine Lifecycle Manager
#
# Audits, restores, and optionally expires run directories created by
# metadata_cleanup.sh and arr_delete_sync_tag.sh under /mnt/user/media/bin.
#
# Usage:
#   quarantine_lifecycle.sh audit
#   quarantine_lifecycle.sh purge
#   quarantine_lifecycle.sh restore RUN_ID movies|series RELATIVE_PATH
###############################################################################

set -uo pipefail
umask 077

readonly SCRIPT_VERSION="1.1"
readonly REQUIRED_PURGE_CONFIRMATION="DELETE_EXPIRED_QUARANTINE"

###############################################################################
# CONFIGURATION
###############################################################################

QUARANTINE_ROOT="/mnt/user/media/bin"
MOVIES_ROOT="/mnt/user/media/movies"
SERIES_ROOT="/mnt/user/media/series"

RETENTION_DAYS=45
WARNING_TOTAL_BYTES=$((500 * 1024 * 1024 * 1024))

# Unraid User Scripts normally invokes scheduled scripts without arguments.
# Keep purge as the default so expired runs are handled automatically; use an
# explicit "audit" argument for report-only runs.
DEFAULT_MODE="purge"

# Both positive gates must match before purge can delete anything.
PURGE_ENABLED=true
PURGE_CONFIRMATION="DELETE_EXPIRED_QUARANTINE"

# Bound each scheduled deletion pass. Oldest runs are processed first and any
# remainder is retried by the next scheduled run.
MAX_PURGE_RUNS_PER_EXECUTION=25
MAX_PURGE_BYTES_PER_EXECUTION=$((10 * 1024 * 1024 * 1024))

# Purging through /mnt/user is safe during parity checks, but defer while Mover
# is actively changing user-share placement.
DEFER_PURGE_WHILE_MOVER=true

LOG_DIR="/mnt/vault/cloud/logs/script/quarantine_lifecycle"
LOG_FILE="${LOG_DIR}/quarantine-lifecycle.log"
INDEX_FILE="${LOG_DIR}/quarantine-index.tsv"
NOTIFICATION_STATE_FILE="${LOG_DIR}/notification-state.json"
LOG_MAX_BYTES=$((5 * 1024 * 1024))

STATUS_DIR="/mnt/vault/cloud/logs/script/user_scripts_status"
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
UNMANAGED_ENTRIES=0
SCAN_ERRORS=0
PURGE_LIMIT_REACHED=0
PURGE_DEFERRED_REASON=""
REMAINING_EXPIRED_RUNS=0

QUARANTINE_REAL=""
MOVIES_REAL=""
SERIES_REAL=""

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

initialize_notification_state() {
    local tmp
    if [[ -f "$NOTIFICATION_STATE_FILE" ]] &&
       jq -e '
           type == "object"
           and ((.attention // {}) | type == "object")
       ' "$NOTIFICATION_STATE_FILE" >/dev/null 2>&1; then
        return 0
    fi

    tmp="$(mktemp "${LOG_DIR}/.notification-state.XXXXXX")" || return 1
    printf '%s\n' '{"version":1,"attention":{}}' >"$tmp" || {
        rm -f -- "$tmp"
        return 1
    }
    mv -f -- "$tmp" "$NOTIFICATION_STATE_FILE"
}

set_attention_state() {
    local signature="$1" now tmp
    now="$(date -Iseconds)"
    tmp="$(mktemp "${LOG_DIR}/.notification-state.XXXXXX")" || return 1
    if ! jq \
        --arg signature "$signature" \
        --arg now "$now" '
        .version = 1
        | .attention = {
            signature: $signature,
            raisedAt: (.attention.raisedAt // $now),
            updatedAt: $now
          }
        ' "$NOTIFICATION_STATE_FILE" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    mv -f -- "$tmp" "$NOTIFICATION_STATE_FILE"
}

clear_attention_state() {
    local send_resolution="${1:-true}" previous tmp
    previous="$(jq -r '.attention.signature // ""' \
        "$NOTIFICATION_STATE_FILE" 2>/dev/null || true)"
    [[ -n "$previous" ]] || return 0

    if [[ "$send_resolution" == true ]]; then
        notify_unraid normal "Quarantine healthy" \
            "Previously reported quarantine lifecycle attention items are resolved."
    fi

    tmp="$(mktemp "${LOG_DIR}/.notification-state.XXXXXX")" || return 1
    if ! jq '.attention = {}' "$NOTIFICATION_STATE_FILE" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    mv -f -- "$tmp" "$NOTIFICATION_STATE_FILE"
}

notify_attention_once() {
    local signature="$1" description="$2" message="$3" previous
    previous="$(jq -r '.attention.signature // ""' \
        "$NOTIFICATION_STATE_FILE" 2>/dev/null || true)"
    [[ "$signature" != "$previous" ]] || return 0
    notify_unraid warning "$description" "$message"
    set_attention_state "$signature"
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
    find "$1" -xdev -type f -printf '%s\n' 2>/dev/null |
        awk '{s+=$1} END {printf "%.0f", s+0}'
}

tree_files() {
    find "$1" -xdev -type f -printf '.' 2>/dev/null | wc -c
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

validate_configuration() {
    local command boolean_name boolean_value

    for command in awk basename date dirname find flock jq mkdir mktemp \
        mountpoint mv pgrep readlink realpath rm sort stat touch wc; do
        command -v "$command" >/dev/null 2>&1 || {
            log ERROR "Required command not found: $command"
            return 1
        }
    done

    [[ "$DEFAULT_MODE" == audit || "$DEFAULT_MODE" == purge ]] || {
        log ERROR "DEFAULT_MODE must be audit or purge"
        return 1
    }
    if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || (( RETENTION_DAYS < 7 )); then
        log ERROR "RETENTION_DAYS must be an integer of at least 7"
        return 1
    fi
    [[ "$WARNING_TOTAL_BYTES" =~ ^[1-9][0-9]*$ ]] || {
        log ERROR "WARNING_TOTAL_BYTES must be a positive integer"
        return 1
    }
    [[ "$MAX_PURGE_RUNS_PER_EXECUTION" =~ ^[1-9][0-9]*$ ]] || {
        log ERROR "MAX_PURGE_RUNS_PER_EXECUTION must be a positive integer"
        return 1
    }
    [[ "$MAX_PURGE_BYTES_PER_EXECUTION" =~ ^[1-9][0-9]*$ ]] || {
        log ERROR "MAX_PURGE_BYTES_PER_EXECUTION must be a positive integer"
        return 1
    }
    [[ "$LOG_MAX_BYTES" =~ ^[1-9][0-9]*$ ]] || {
        log ERROR "LOG_MAX_BYTES must be a positive integer"
        return 1
    }

    for boolean_name in PURGE_ENABLED DEFER_PURGE_WHILE_MOVER; do
        boolean_value="${!boolean_name}"
        [[ "$boolean_value" == true || "$boolean_value" == false ]] || {
            log ERROR "${boolean_name} must be true or false"
            return 1
        }
    done
}

paths_overlap() {
    local left="${1%/}" right="${2%/}"
    [[ "$left" == "$right" || "$left" == "$right"/* || "$right" == "$left"/* ]]
}

validate_roots() {
    [[ "$QUARANTINE_ROOT" == /mnt/user/* &&
       "$MOVIES_ROOT" == /mnt/user/* &&
       "$SERIES_ROOT" == /mnt/user/* &&
       "$QUARANTINE_ROOT" != "/mnt/user/" &&
       "$MOVIES_ROOT" != "/mnt/user/" &&
       "$SERIES_ROOT" != "/mnt/user/" &&
       "$QUARANTINE_ROOT" != *$'\n'* &&
       "$MOVIES_ROOT" != *$'\n'* &&
       "$SERIES_ROOT" != *$'\n'* ]] || {
        log ERROR "Unsafe quarantine or media root configuration"
        return 1
    }
    [[ ! -L "$QUARANTINE_ROOT" &&
       ! -L "$MOVIES_ROOT" &&
       ! -L "$SERIES_ROOT" ]] || {
        log ERROR "Quarantine and media roots must not be symbolic links"
        return 1
    }
    [[ -d "$MOVIES_ROOT" && -d "$SERIES_ROOT" ]] || {
        log ERROR "Configured media roots must exist"
        return 1
    }
    mkdir -p -- "$QUARANTINE_ROOT" || {
        log ERROR "Unable to create quarantine root: $QUARANTINE_ROOT"
        return 1
    }

    QUARANTINE_REAL="$(realpath -e -- "$QUARANTINE_ROOT")" || return 1
    MOVIES_REAL="$(realpath -e -- "$MOVIES_ROOT")" || return 1
    SERIES_REAL="$(realpath -e -- "$SERIES_ROOT")" || return 1
    [[ "$QUARANTINE_REAL" == /mnt/user/* &&
       "$MOVIES_REAL" == /mnt/user/* &&
       "$SERIES_REAL" == /mnt/user/* ]] || {
        log ERROR "Canonical quarantine or media root escaped /mnt/user"
        return 1
    }
    if paths_overlap "$QUARANTINE_REAL" "$MOVIES_REAL" ||
       paths_overlap "$QUARANTINE_REAL" "$SERIES_REAL" ||
       paths_overlap "$MOVIES_REAL" "$SERIES_REAL"; then
        log ERROR "Quarantine and media roots must not overlap"
        return 1
    fi
}

valid_run_id() {
    [[ "$1" =~ ^[0-9]{8}_[0-9]{6}_[0-9]+$ ]]
}

run_id_epoch() {
    local run_id="$1" date_part time_and_pid time_part formatted normalized
    valid_run_id "$run_id" || return 1
    date_part="${run_id%%_*}"
    time_and_pid="${run_id#*_}"
    time_part="${time_and_pid%%_*}"
    formatted="${date_part:0:4}-${date_part:4:2}-${date_part:6:2} ${time_part:0:2}:${time_part:2:2}:${time_part:4:2}"
    normalized="$(date -d "$formatted" '+%Y%m%d_%H%M%S' 2>/dev/null)" || return 1
    [[ "$normalized" == "${date_part}_${time_part}" ]] || return 1
    date -d "$formatted" '+%s'
}

validate_managed_run_path() {
    local run="$1" run_id="$2" run_real parent_real child child_name
    valid_run_id "$run_id" || return 1
    [[ -d "$run" && ! -L "$run" ]] || return 1
    run_real="$(realpath -e -- "$run" 2>/dev/null)" || return 1
    parent_real="$(realpath -e -- "$(dirname -- "$run")" 2>/dev/null)" || return 1
    [[ "$parent_real" == "$QUARANTINE_REAL" &&
       "$run_real" == "${QUARANTINE_REAL}/${run_id}" ]] || return 1
    ! mountpoint -q -- "$run" || return 1

    while IFS= read -r -d '' child; do
        child_name="$(basename -- "$child")"
        case "$child_name" in
            movies|series)
                [[ -d "$child" && ! -L "$child" ]] || return 1
                ! mountpoint -q -- "$child" || return 1
                ;;
            *)
                return 1
                ;;
        esac
    done < <(find "$run" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

unraid_mover_running() {
    pgrep -f '(^|/)(mover|mover\.old)( |$)|mover\.php' >/dev/null 2>&1
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
    local tmp run run_id created age_days files bytes expired
    log INFO "Starting quarantine lifecycle audit v$SCRIPT_VERSION"
    tmp="$(mktemp "${LOG_DIR}/.quarantine-index.XXXXXX")" || return 1
    printf 'run_id\tcreated_epoch\tage_days\tfiles\tbytes\texpired\n' >"$tmp"

    while IFS= read -r -d '' run; do
        run_id="$(basename "$run")"
        valid_run_id "$run_id" || {
            log WARN "Ignoring non-managed quarantine entry: $run_id"
            UNMANAGED_ENTRIES=$((UNMANAGED_ENTRIES + 1))
            continue
        }
        if ! validate_managed_run_path "$run" "$run_id"; then
            log ERROR "Unsafe managed quarantine run was not scanned: $run"
            SCAN_ERRORS=$((SCAN_ERRORS + 1))
            continue
        fi
        if ! created="$(run_id_epoch "$run_id")"; then
            log ERROR "Managed quarantine run has an invalid calendar timestamp: $run_id"
            SCAN_ERRORS=$((SCAN_ERRORS + 1))
            continue
        fi
        if (( created > START_EPOCH + 300 )); then
            log ERROR "Managed quarantine run is dated in the future: $run_id"
            SCAN_ERRORS=$((SCAN_ERRORS + 1))
            continue
        fi
        age_days=$(((START_EPOCH - created) / 86400))
        (( age_days < 0 )) && age_days=0
        if ! files="$(tree_files "$run")" ||
           ! bytes="$(tree_bytes "$run")" ||
           ! [[ "$files" =~ ^[[:space:]]*[0-9]+$ && "$bytes" =~ ^[0-9]+$ ]]; then
            log ERROR "Unable to inventory managed quarantine run: $run_id"
            SCAN_ERRORS=$((SCAN_ERRORS + 1))
            continue
        fi
        files="${files//[[:space:]]/}"
        expired=false
        if (( age_days >= RETENTION_DAYS )); then
            expired=true
            EXPIRED_RUNS=$((EXPIRED_RUNS + 1))
        fi
        RUNS_SCANNED=$((RUNS_SCANNED + 1))
        FILES_SCANNED=$((FILES_SCANNED + files))
        TOTAL_BYTES=$((TOTAL_BYTES + bytes))
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$run_id" "$created" "$age_days" "$files" "$bytes" "$expired" >>"$tmp"
    done < <(
        find "$QUARANTINE_REAL" -mindepth 1 -maxdepth 1 -print0 \
            2>/dev/null | sort -z
    )

    mv -f -- "$tmp" "$INDEX_FILE"
    REMAINING_EXPIRED_RUNS="$EXPIRED_RUNS"
    log INFO "Audit: $RUNS_SCANNED managed runs, $FILES_SCANNED files, $(human_bytes "$TOTAL_BYTES"), $EXPIRED_RUNS expired, $UNMANAGED_ENTRIES unmanaged, $SCAN_ERRORS scan errors"
}

###############################################################################
# RESTORE
###############################################################################

restore_item() {
    local run_id="$1" bucket="$2" relative="$3"
    local run source destination root source_resolved destination_resolved

    valid_run_id "$run_id" || {
        log ERROR "Invalid run ID: $run_id"
        return 1
    }
    valid_relative_path "$relative" || {
        log ERROR "Unsafe relative restore path: $relative"
        return 1
    }
    case "$bucket" in
        movies) root="$MOVIES_REAL" ;;
        series) root="$SERIES_REAL" ;;
        *)
            log ERROR "Restore bucket must be movies or series"
            return 1
            ;;
    esac

    run="${QUARANTINE_REAL}/${run_id}"
    validate_managed_run_path "$run" "$run_id" || {
        log ERROR "Unsafe or unavailable managed quarantine run: $run_id"
        return 1
    }
    source="${run}/${bucket}/${relative}"
    destination="${root}/${relative}"
    source_resolved="$(readlink -m -- "$source")" || return 1
    destination_resolved="$(readlink -m -- "$destination")" || return 1

    [[ "$source_resolved" == "$run"/* &&
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
    find "$run" -xdev -depth -type d -empty -delete \
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
    local run run_id created age_days bytes

    [[ "$PURGE_ENABLED" == true ]] || {
        log ERROR "Purge is disabled; set PURGE_ENABLED=true after reviewing $INDEX_FILE"
        return 1
    }
    [[ "$PURGE_CONFIRMATION" == "$REQUIRED_PURGE_CONFIRMATION" ]] || {
        log ERROR "PURGE_CONFIRMATION does not match the required confirmation phrase"
        return 1
    }
    if (( EXPIRED_RUNS == 0 )); then
        RESULT_STATUS="OK"
        RESULT_SUMMARY="No quarantine runs have reached ${RETENTION_DAYS}-day retention"
        log INFO "$RESULT_SUMMARY"
        return 0
    fi
    if [[ "$DEFER_PURGE_WHILE_MOVER" == true ]] && unraid_mover_running; then
        PURGE_DEFERRED_REASON="Unraid Mover is active"
        RESULT_STATUS="WARNING"
        RESULT_SUMMARY="Purge deferred: $PURGE_DEFERRED_REASON; $EXPIRED_RUNS expired run(s) remain"
        log WARN "$RESULT_SUMMARY"
        return 0
    fi

    while IFS= read -r -d '' run; do
        run_id="$(basename "$run")"
        valid_run_id "$run_id" || continue
        validate_managed_run_path "$run" "$run_id" || {
            log ERROR "Refusing purge of unsafe managed run path: $run"
            return 1
        }
        created="$(run_id_epoch "$run_id")" || {
            log ERROR "Refusing purge of run with invalid timestamp: $run_id"
            return 1
        }
        (( created <= START_EPOCH + 300 )) || continue
        age_days=$(((START_EPOCH - created) / 86400))
        (( age_days >= RETENTION_DAYS )) || continue
        bytes="$(tree_bytes "$run")" || {
            log ERROR "Unable to size expired quarantine run: $run_id"
            return 1
        }
        [[ "$bytes" =~ ^[0-9]+$ ]] || {
            log ERROR "Invalid byte count for expired quarantine run: $run_id"
            return 1
        }

        if (( PURGED_RUNS >= MAX_PURGE_RUNS_PER_EXECUTION ||
              PURGED_BYTES + bytes > MAX_PURGE_BYTES_PER_EXECUTION )); then
            PURGE_LIMIT_REACHED=1
            log WARN "Per-run purge limit reached before $run_id; remaining expired runs will be retried"
            break
        fi

        log WARN "Purging expired quarantine run: $run_id"
        rm -rf -- "$run" || {
            log ERROR "Failed to purge: $run"
            return 1
        }
        [[ ! -e "$run" && ! -L "$run" ]] || {
            log ERROR "Expired quarantine run still exists after purge: $run_id"
            return 1
        }
        PURGED_RUNS=$((PURGED_RUNS + 1))
        PURGED_BYTES=$((PURGED_BYTES + bytes))
    done < <(
        find "$QUARANTINE_REAL" -mindepth 1 -maxdepth 1 -type d -print0 \
            2>/dev/null | sort -z
    )

    REMAINING_EXPIRED_RUNS=$((EXPIRED_RUNS - PURGED_RUNS))
    (( REMAINING_EXPIRED_RUNS < 0 )) && REMAINING_EXPIRED_RUNS=0
    TOTAL_BYTES=$((TOTAL_BYTES - PURGED_BYTES))
    (( TOTAL_BYTES < 0 )) && TOTAL_BYTES=0
    if (( PURGE_LIMIT_REACHED == 1 )); then
        RESULT_STATUS="WARNING"
        RESULT_SUMMARY="Purged $PURGED_RUNS run(s) and $(human_bytes "$PURGED_BYTES"); $REMAINING_EXPIRED_RUNS expired run(s) remain after reaching the execution limit"
    else
        RESULT_STATUS="OK"
        RESULT_SUMMARY="Purged $PURGED_RUNS run(s) and $(human_bytes "$PURGED_BYTES")"
    fi
    log INFO "$RESULT_SUMMARY"
}

update_lifecycle_notifications() {
    local signature="" detail="" importance="warning"

    if (( REMAINING_EXPIRED_RUNS > 0 )); then
        signature+="expired;"
        detail+="Expired runs remaining: $REMAINING_EXPIRED_RUNS"$'\n'
    fi
    if (( UNMANAGED_ENTRIES > 0 )); then
        signature+="unmanaged;"
        detail+="Unmanaged entries preserved: $UNMANAGED_ENTRIES"$'\n'
    fi
    if (( SCAN_ERRORS > 0 )); then
        signature+="scan-errors;"
        detail+="Managed runs preserved after scan errors: $SCAN_ERRORS"$'\n'
    fi
    if (( TOTAL_BYTES >= WARNING_TOTAL_BYTES )); then
        signature+="capacity;"
        detail+="Quarantine usage warning: $(human_bytes "$TOTAL_BYTES")"$'\n'
    fi
    if [[ -n "$PURGE_DEFERRED_REASON" ]]; then
        signature+="mover-deferred;"
        detail+="Purge deferred: $PURGE_DEFERRED_REASON"$'\n'
    fi
    if (( PURGE_LIMIT_REACHED == 1 )); then
        signature+="purge-limit;"
        detail+="Per-execution purge limit reached; remaining runs will be retried."$'\n'
    fi
    detail+="Index: $INDEX_FILE"

    if (( PURGED_RUNS > 0 )); then
        [[ -z "$signature" ]] && importance="normal"
        notify_unraid "$importance" "Quarantine purge completed" \
            "$RESULT_SUMMARY"$'\n'"$detail"
        if [[ -n "$signature" ]]; then
            set_attention_state "$signature"
        else
            clear_attention_state false
        fi
    elif [[ -n "$signature" ]]; then
        notify_attention_once "$signature" "Quarantine review required" "$detail"
    else
        clear_attention_state true
    fi
}

###############################################################################
# MAIN
###############################################################################

main() {
    local mode="${1:-$DEFAULT_MODE}"
    if ! mountpoint -q /mnt/vault || ! mountpoint -q /mnt/user; then
        printf 'Required mounts are unavailable: /mnt/vault and/or /mnt/user\n' >&2
        return 1
    fi
    mkdir -p -- "$LOG_DIR" || return 1
    rotate_log
    touch "$LOG_FILE" || return 1
    validate_configuration || return 1

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        RESULT_SUMMARY="Another quarantine lifecycle run is active"
        log ERROR "$RESULT_SUMMARY"
        return 1
    fi
    initialize_notification_state || {
        log ERROR "Unable to initialize notification state"
        return 1
    }
    validate_roots || return 1

    case "$mode" in
        audit)
            audit_quarantine || return 1
            if (( TOTAL_BYTES >= WARNING_TOTAL_BYTES ||
                  EXPIRED_RUNS > 0 ||
                  UNMANAGED_ENTRIES > 0 ||
                  SCAN_ERRORS > 0 )); then
                RESULT_STATUS="WARNING"
                RESULT_SUMMARY="$EXPIRED_RUNS expired, $UNMANAGED_ENTRIES unmanaged, $SCAN_ERRORS scan errors; quarantine uses $(human_bytes "$TOTAL_BYTES")"
            else
                RESULT_STATUS="OK"
                RESULT_SUMMARY="$RUNS_SCANNED runs, $FILES_SCANNED files, $(human_bytes "$TOTAL_BYTES")"
            fi
            update_lifecycle_notifications || return 1
            ;;
        purge)
            audit_quarantine || return 1
            if ! purge_expired; then
                RESULT_STATUS="FAILED"
                RESULT_SUMMARY="Quarantine purge failed; no unsafe fallback was attempted"
                notify_attention_once "purge-failed;" \
                    "Quarantine purge failed" \
                    "$RESULT_SUMMARY"$'\n'"Log: $LOG_FILE" || true
                return 1
            fi
            update_lifecycle_notifications || return 1
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
