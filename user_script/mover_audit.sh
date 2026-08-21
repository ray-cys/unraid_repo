#!/bin/bash

###############################################################################
# Unraid Mover Audit
#
# Read-only audit of share placement across the array and configured pools.
# It never invokes Mover and never moves or deletes data.
###############################################################################

set -uo pipefail
umask 077

readonly SCRIPT_VERSION="1.0"

###############################################################################
# CONFIGURATION
###############################################################################

SHARE_CONFIG_DIR="/boot/config/shares"
USER_ROOT="/mnt/user"
ARRAY_ONLY_ROOT="/mnt/user0"

# Personal pools to inspect.
POOL_NAMES=("cache" "vault")

POOL_WARNING_PERCENT=85
STALE_FILE_HOURS=48
CHECK_DUPLICATE_PATHS=true
CHECK_OPEN_FILES=false
MAX_EXAMPLES_PER_SHARE=10

LOG_DIR="/mnt/vault/cloud/logs/mover_audit"
MAX_LOGS=7
STATUS_DIR="/mnt/vault/cloud/logs/user_scripts_status"
NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
LOCK_FILE="/run/mover_audit.lock"

###############################################################################
# RUNTIME
###############################################################################

RUN_STAMP="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE="${LOG_DIR}/mover-audit-${RUN_STAMP}.log"
REPORT_FILE="${LOG_DIR}/mover-audit-latest.txt"
START_EPOCH="$(date +%s)"

RESULT_STATUS="FAILED"
RESULT_SUMMARY="Mover audit exited before completion"
RECEIPT_WRITTEN=0
TMP_DIR=""

SHARES_SCANNED=0
WARNING_COUNT=0
POOL_WARNING_COUNT=0
STALE_FILE_COUNT=0
DUPLICATE_PATH_COUNT=0
OPEN_FILE_COUNT=0

REPORT=""

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

notify_unraid() {
    local importance="$1" description="$2" message="$3"
    [[ -x "$NOTIFY_BIN" ]] || return 0
    "$NOTIFY_BIN" -i "$importance" -s "Mover Audit" \
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
    local path="$1"
    [[ -d "$path" ]] || {
        printf 0
        return
    }
    find "$path" -type f -printf '%s\n' 2>/dev/null |
        awk '{s+=$1} END {printf "%.0f", s+0}'
}

file_count() {
    local path="$1"
    [[ -d "$path" ]] || {
        printf 0
        return
    }
    find "$path" -type f -printf '.' 2>/dev/null | wc -c
}

cfg_value() {
    local key="$1" file="$2"
    awk -v key="$key" '
        index($0, key "=") == 1 {
            value=substr($0, length(key)+2)
            sub(/^"/, "", value)
            sub(/"$/, "", value)
            print value
            exit
        }
    ' "$file" 2>/dev/null
}

write_receipt() {
    local status="$1" summary="$2" now tmp
    now="$(date +%s)"
    mkdir -p -- "$STATUS_DIR" 2>/dev/null || return 0
    command -v jq >/dev/null 2>&1 || return 0
    tmp="$(mktemp "${STATUS_DIR}/.mover_audit.XXXXXX")" || return 0
    if jq -n \
        --arg name "mover_audit" \
        --arg status "$status" \
        --arg summary "$summary" \
        --arg log "$LOG_FILE" \
        --argjson epoch "$now" \
        --argjson duration "$((now - START_EPOCH))" \
        '{name:$name,status:$status,summary:$summary,log:$log,epoch:$epoch,duration_seconds:$duration}' \
        >"$tmp"
    then
        mv -f -- "$tmp" "${STATUS_DIR}/mover_audit.json"
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

prune_logs() {
    local -a entries=()
    mapfile -t entries < <(
        find "$LOG_DIR" -maxdepth 1 -type f -name 'mover-audit-*.log' \
            -printf '%T@|%p\n' 2>/dev/null | sort -rn | cut -d'|' -f2-
    )
    for ((i=MAX_LOGS; i<${#entries[@]}; i++)); do
        rm -f -- "${entries[$i]}" 2>/dev/null || true
    done
}

append_report() {
    REPORT+="$*"$'\n'
}

###############################################################################
# AUDIT PHASES
###############################################################################

validate_environment() {
    local pool command
    [[ -d "$SHARE_CONFIG_DIR" ]] || {
        log ERROR "Share configuration directory unavailable: $SHARE_CONFIG_DIR"
        return 1
    }
    [[ -d "$USER_ROOT" && -d "$ARRAY_ONLY_ROOT" ]] || {
        log ERROR "Array/user share roots are unavailable"
        return 1
    }
    for pool in "${POOL_NAMES[@]}"; do
        [[ "$pool" =~ ^[A-Za-z0-9._-]+$ ]] || {
            log ERROR "Unsafe pool name: $pool"
            return 1
        }
    done
    for command in find sort awk comm flock df; do
        command -v "$command" >/dev/null 2>&1 || {
            log ERROR "Required command not found: $command"
            return 1
        }
    done
}

detect_mover() {
    if pgrep -f '(^|/)(mover|mover\.old)( |$)|mover\.php' >/dev/null 2>&1; then
        append_report "Mover state: RUNNING"
    else
        append_report "Mover state: idle"
    fi
}

audit_pool_capacity() {
    local pool path _total _used available percent
    append_report ""
    append_report "Pool capacity"
    append_report "-------------"

    for pool in "${POOL_NAMES[@]}"; do
        path="/mnt/$pool"
        if ! mountpoint -q "$path"; then
            append_report "$pool: NOT MOUNTED"
            WARNING_COUNT=$((WARNING_COUNT + 1))
            POOL_WARNING_COUNT=$((POOL_WARNING_COUNT + 1))
            continue
        fi
        read -r _total _used available percent < <(
            df -B1 --output=size,used,avail,pcent "$path" |
                awk 'NR==2 {gsub(/%/,"",$4); print $1,$2,$3,$4}'
        )
        append_report "$pool: ${percent}% used; $(human_bytes "$available") free"
        if (( percent >= POOL_WARNING_PERCENT )); then
            WARNING_COUNT=$((WARNING_COUNT + 1))
            POOL_WARNING_COUNT=$((POOL_WARNING_COUNT + 1))
            log WARN "Pool $pool is ${percent}% full"
        fi
    done
}

duplicate_paths_for_share() {
    local share="$1" pool="$2"
    local pool_path="/mnt/${pool}/${share}"
    local array_path="${ARRAY_ONLY_ROOT}/${share}"
    local pool_list="${TMP_DIR}/${share}.${pool}.pool"
    local array_list="${TMP_DIR}/${share}.${pool}.array"
    local duplicate_list="${TMP_DIR}/${share}.${pool}.duplicates"
    local count

    [[ "$CHECK_DUPLICATE_PATHS" == true ]] || return 0
    [[ -d "$pool_path" && -d "$array_path" ]] || return 0

    (
        cd "$pool_path" || exit 1
        find . -type f -printf '%P\n' 2>/dev/null | sort -u
    ) >"$pool_list" || return 1
    (
        cd "$array_path" || exit 1
        find . -type f -printf '%P\n' 2>/dev/null | sort -u
    ) >"$array_list" || return 1

    comm -12 "$pool_list" "$array_list" >"$duplicate_list"
    count="$(wc -l <"$duplicate_list" | tr -d '[:space:]')"
    (( count > 0 )) || return 0

    DUPLICATE_PATH_COUNT=$((DUPLICATE_PATH_COUNT + count))
    WARNING_COUNT=$((WARNING_COUNT + 1))
    append_report "  Duplicate relative paths on $pool and array: $count"
    while IFS= read -r duplicate; do
        append_report "    - $duplicate"
    done < <(head -n "$MAX_EXAMPLES_PER_SHARE" "$duplicate_list")
}

stale_files_for_share() {
    local share="$1" pool="$2" use_cache="$3"
    local pool_path="/mnt/${pool}/${share}"
    local stale_file="${TMP_DIR}/${share}.${pool}.stale"
    local count

    # Legacy shareUseCache=yes maps to pool -> array Mover behavior.
    [[ "$use_cache" == "yes" && -d "$pool_path" ]] || return 0
    find "$pool_path" -type f -mmin "+$((STALE_FILE_HOURS * 60))" \
        -printf '%P\n' 2>/dev/null >"$stale_file"
    count="$(wc -l <"$stale_file" | tr -d '[:space:]')"
    (( count > 0 )) || return 0

    STALE_FILE_COUNT=$((STALE_FILE_COUNT + count))
    WARNING_COUNT=$((WARNING_COUNT + 1))
    append_report "  Files older than ${STALE_FILE_HOURS}h on $pool: $count"
    while IFS= read -r stale; do
        append_report "    - $stale"
    done < <(head -n "$MAX_EXAMPLES_PER_SHARE" "$stale_file")
}

open_files_for_share() {
    local share="$1" path output count
    path="${USER_ROOT}/${share}"
    [[ "$CHECK_OPEN_FILES" == true ]] || return 0
    command -v lsof >/dev/null 2>&1 || return 0
    output="$(timeout 30 lsof +D "$path" 2>/dev/null | tail -n +2 || true)"
    [[ -n "$output" ]] || return 0
    count="$(printf '%s\n' "$output" | wc -l)"
    OPEN_FILE_COUNT=$((OPEN_FILE_COUNT + count))
    append_report "  Open files that may block Mover: $count"
}

audit_share() {
    local cfg="$1" share
    local use_cache primary secondary action
    local array_bytes array_files pool pool_bytes pool_files

    share="$(basename "$cfg" .cfg)"
    [[ -n "$share" && "$share" != */* && "$share" != *$'\n'* ]] || {
        log WARN "Skipping unexpected share config name: $share"
        return 0
    }

    use_cache="$(cfg_value shareUseCache "$cfg")"
    primary="$(cfg_value shareCachePool "$cfg")"
    secondary="$(cfg_value shareCachePool2 "$cfg")"
    action="$(cfg_value shareMoverAction "$cfg")"

    SHARES_SCANNED=$((SHARES_SCANNED + 1))
    append_report ""
    append_report "Share: $share"
    append_report "  Config: use_cache=${use_cache:-unset}, primary=${primary:-unset}, secondary=${secondary:-array/unset}, mover_action=${action:-unset}"

    array_bytes="$(tree_bytes "${ARRAY_ONLY_ROOT}/${share}")"
    array_files="$(file_count "${ARRAY_ONLY_ROOT}/${share}")"
    append_report "  Array: $array_files files, $(human_bytes "$array_bytes")"

    for pool in "${POOL_NAMES[@]}"; do
        pool_bytes="$(tree_bytes "/mnt/${pool}/${share}")"
        pool_files="$(file_count "/mnt/${pool}/${share}")"
        (( pool_files > 0 || pool_bytes > 0 )) &&
            append_report "  $pool: $pool_files files, $(human_bytes "$pool_bytes")"
        stale_files_for_share "$share" "$pool" "$use_cache"
        duplicate_paths_for_share "$share" "$pool" || {
            log WARN "Duplicate-path scan failed for $share on $pool"
            WARNING_COUNT=$((WARNING_COUNT + 1))
        }
    done
    open_files_for_share "$share"
}

audit_shares() {
    local cfg
    append_report ""
    append_report "Share placement"
    append_report "---------------"
    while IFS= read -r -d '' cfg; do
        audit_share "$cfg"
    done < <(
        find "$SHARE_CONFIG_DIR" -maxdepth 1 -type f -name '*.cfg' \
            -print0 2>/dev/null | sort -z
    )
}

###############################################################################
# MAIN
###############################################################################

main() {
    if ! mountpoint -q /mnt/vault || ! mountpoint -q /mnt/user; then
        printf 'Required mounts are unavailable: /mnt/vault and/or /mnt/user\n' >&2
        return 1
    fi
    mkdir -p -- "$LOG_DIR" || return 1
    : >"$LOG_FILE" || return 1
    prune_logs

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        RESULT_SUMMARY="Another Mover audit is already active"
        log ERROR "$RESULT_SUMMARY"
        return 1
    fi

    validate_environment || return 1
    TMP_DIR="$(mktemp -d /tmp/mover-audit.XXXXXX)" || return 1

    append_report "Unraid Mover Audit"
    append_report "Generated: $(date -Iseconds)"
    append_report "Script version: $SCRIPT_VERSION"
    detect_mover
    audit_pool_capacity
    audit_shares

    {
        printf '%s\n' "$REPORT"
        printf '\nSummary\n-------\n'
        printf 'Shares scanned: %s\n' "$SHARES_SCANNED"
        printf 'Pool warnings: %s\n' "$POOL_WARNING_COUNT"
        printf 'Stale pool files: %s\n' "$STALE_FILE_COUNT"
        printf 'Duplicate paths: %s\n' "$DUPLICATE_PATH_COUNT"
        printf 'Open files: %s\n' "$OPEN_FILE_COUNT"
    } >"$REPORT_FILE"

    if (( WARNING_COUNT > 0 )); then
        RESULT_STATUS="WARNING"
        RESULT_SUMMARY="${WARNING_COUNT} findings; stale=${STALE_FILE_COUNT}, duplicates=${DUPLICATE_PATH_COUNT}, pool_warnings=${POOL_WARNING_COUNT}"
        log WARN "$RESULT_SUMMARY"
        notify_unraid warning "Mover audit found issues" \
            "$RESULT_SUMMARY"$'\n'"Report: $REPORT_FILE"
    else
        RESULT_STATUS="OK"
        RESULT_SUMMARY="${SHARES_SCANNED} shares audited; no placement warnings"
        log INFO "$RESULT_SUMMARY"
    fi

    write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
}

main "$@"
