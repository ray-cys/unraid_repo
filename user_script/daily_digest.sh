#!/bin/bash

###############################################################################
# Daily Unraid Operations Digest
#
# Aggregates receipts from the personal operational scripts plus freshness
# checks for the existing appdata, boot, disk-health, and Arr monitoring jobs.
###############################################################################

set -uo pipefail
umask 077

readonly SCRIPT_VERSION="1.0"

###############################################################################
# CONFIGURATION
###############################################################################

STATUS_DIR="/mnt/vault/cloud/logs/user_scripts_status"

# receipt name|max age hours|required (0/1)
RECEIPT_RULES=(
    "vault_to_iss_versioned|192|1"
    "backup_restore_drill|192|1"
    "mover_audit|30|1"
    "docker_service_watchdog|1|1"
    "quarantine_lifecycle|30|1"
    "pre_post_reboot_audit|720|0"
)

# label|root|entry type (f/d)|name pattern|max age hours
ARTIFACT_RULES=(
    "Appdata backup|/mnt/vault/backup/cache|d|backup_[0-9]*_[0-9]*|192"
    "Boot-device backup|/mnt/vault/backup/flash|f|*.zip|192"
    "Disk health monitor|/mnt/vault/cloud/logs/disk_health|f|*.log|30"
    "Arr import monitor|/mnt/vault/cloud/logs/arr_import_monitor|f|arr_import_monitor.log|2"
)

SEND_NOTIFICATION=true
MAX_DETAIL_ITEMS=30

LOG_DIR="/mnt/vault/cloud/logs/daily_digest"
LOG_FILE="${LOG_DIR}/daily-digest.log"
LOG_MAX_BYTES=$((5 * 1024 * 1024))
NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
LOCK_FILE="/run/daily_digest.lock"

###############################################################################
# RUNTIME
###############################################################################

START_EPOCH="$(date +%s)"
RESULT_STATUS="FAILED"
RESULT_SUMMARY="Daily digest exited before completion"
RECEIPT_WRITTEN=0

OK_ITEMS=()
WARNING_ITEMS=()
CRITICAL_ITEMS=()

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
    [[ "$SEND_NOTIFICATION" == true && -x "$NOTIFY_BIN" ]] || return 0
    "$NOTIFY_BIN" -i "$importance" -s "Daily Unraid Digest" \
        -d "$description" -m "$message" >/dev/null 2>&1 || true
}

human_age() {
    local seconds="$1"
    if (( seconds < 3600 )); then
        printf '%dm' "$((seconds / 60))"
    elif (( seconds < 86400 )); then
        printf '%dh' "$((seconds / 3600))"
    else
        printf '%dd %dh' "$((seconds / 86400))" "$(((seconds % 86400) / 3600))"
    fi
}

write_receipt() {
    local status="$1" summary="$2" now tmp
    now="$(date +%s)"
    mkdir -p -- "$STATUS_DIR" 2>/dev/null || return 0
    tmp="$(mktemp "${STATUS_DIR}/.daily_digest.XXXXXX")" || return 0
    if jq -n \
        --arg name "daily_digest" \
        --arg status "$status" \
        --arg summary "$summary" \
        --arg log "$LOG_FILE" \
        --argjson epoch "$now" \
        --argjson duration "$((now - START_EPOCH))" \
        '{name:$name,status:$status,summary:$summary,log:$log,epoch:$epoch,duration_seconds:$duration}' \
        >"$tmp"
    then
        mv -f -- "$tmp" "${STATUS_DIR}/daily_digest.json"
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

add_item() {
    local severity="$1"
    shift
    case "$severity" in
        OK) OK_ITEMS+=("$*") ;;
        WARNING) WARNING_ITEMS+=("$*") ;;
        CRITICAL) CRITICAL_ITEMS+=("$*") ;;
    esac
}

###############################################################################
# CHECKS
###############################################################################

check_receipt() {
    local rule="$1" name max_hours required file
    local status summary epoch age
    IFS='|' read -r name max_hours required <<<"$rule"
    file="${STATUS_DIR}/${name}.json"

    if [[ ! -s "$file" ]] || ! jq -e . "$file" >/dev/null 2>&1; then
        if [[ "$required" == 1 ]]; then
            add_item CRITICAL "$name: receipt missing or invalid"
        fi
        return
    fi

    status="$(jq -r '.status // "FAILED"' "$file")"
    summary="$(jq -r '.summary // "no summary"' "$file")"
    epoch="$(jq -r '.epoch // 0' "$file")"
    [[ "$epoch" =~ ^[0-9]+$ ]] || epoch=0
    age=$((START_EPOCH - epoch))
    (( age < 0 )) && age=0

    if (( max_hours > 0 && age > max_hours * 3600 )); then
        add_item CRITICAL "$name: stale ($(human_age "$age")); $summary"
        return
    fi

    case "$status" in
        OK)
            add_item OK "$name ($(human_age "$age")): $summary"
            ;;
        WARNING)
            add_item WARNING "$name ($(human_age "$age")): $summary"
            ;;
        CRITICAL|FAILED)
            add_item CRITICAL "$name ($(human_age "$age")): $summary"
            ;;
        *)
            add_item WARNING "$name: unknown status '$status'; $summary"
            ;;
    esac
}

latest_artifact() {
    local root="$1" type="$2" pattern="$3"
    find "$root" -mindepth 1 -maxdepth 1 -type "$type" -name "$pattern" \
        ! -name '*.partial' ! -name '*.failed' \
        -printf '%T@|%p\n' 2>/dev/null |
        sort -rn |
        head -n 1
}

check_artifact() {
    local rule="$1" label root type pattern max_hours
    local latest timestamp path epoch age
    IFS='|' read -r label root type pattern max_hours <<<"$rule"

    if [[ ! -d "$root" ]]; then
        add_item CRITICAL "$label: root unavailable ($root)"
        return
    fi
    latest="$(latest_artifact "$root" "$type" "$pattern")"
    if [[ -z "$latest" ]]; then
        add_item CRITICAL "$label: no matching artifact"
        return
    fi

    timestamp="${latest%%|*}"
    path="${latest#*|}"
    epoch="${timestamp%%.*}"
    [[ "$epoch" =~ ^[0-9]+$ ]] || epoch=0
    age=$((START_EPOCH - epoch))
    (( age < 0 )) && age=0

    if (( age > max_hours * 3600 )); then
        add_item CRITICAL "$label: stale ($(human_age "$age")); $(basename "$path")"
    else
        add_item OK "$label ($(human_age "$age")): $(basename "$path")"
    fi
}

###############################################################################
# REPORTING
###############################################################################

append_section() {
    local title="$1" marker="$2"
    shift 2
    local item count=0 output=""
    (( $# > 0 )) || return 0
    output+="$title"$'\n'
    for item in "$@"; do
        (( count >= MAX_DETAIL_ITEMS )) && {
            output+="  ... additional items omitted"$'\n'
            break
        }
        output+="  $marker $item"$'\n'
        count=$((count + 1))
    done
    output+=$'\n'
    printf '%s' "$output"
}

build_body() {
    local body=""
    body+="Generated: $(date '+%Y-%m-%d %H:%M:%S')"$'\n'
    body+="Script version: $SCRIPT_VERSION"$'\n'
    body+="OK: ${#OK_ITEMS[@]}  Warnings: ${#WARNING_ITEMS[@]}  Critical: ${#CRITICAL_ITEMS[@]}"$'\n\n'
    body+="$(append_section "Critical" "!" "${CRITICAL_ITEMS[@]}")"
    body+="$(append_section "Warnings" "-" "${WARNING_ITEMS[@]}")"
    body+="$(append_section "Healthy / current" "+" "${OK_ITEMS[@]}")"
    printf '%s' "$body"
}

###############################################################################
# MAIN
###############################################################################

main() {
    local rule body importance description

    if ! mountpoint -q /mnt/vault; then
        printf 'Vault pool is not mounted: /mnt/vault\n' >&2
        return 1
    fi
    mkdir -p -- "$LOG_DIR" "$STATUS_DIR" || return 1
    rotate_log
    touch "$LOG_FILE" || return 1

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        RESULT_SUMMARY="Another daily digest run is active"
        log ERROR "$RESULT_SUMMARY"
        return 1
    fi

    command -v jq >/dev/null 2>&1 || {
        log ERROR "jq is required"
        return 1
    }

    for rule in "${RECEIPT_RULES[@]}"; do
        check_receipt "$rule"
    done
    for rule in "${ARTIFACT_RULES[@]}"; do
        check_artifact "$rule"
    done

    body="$(build_body)"
    printf '%s\n' "$body" | tee -a "$LOG_FILE"

    if (( ${#CRITICAL_ITEMS[@]} > 0 )); then
        RESULT_STATUS="CRITICAL"
        importance="alert"
        description="Critical operational findings"
    elif (( ${#WARNING_ITEMS[@]} > 0 )); then
        RESULT_STATUS="WARNING"
        importance="warning"
        description="Operational warnings"
    else
        RESULT_STATUS="OK"
        importance="normal"
        description="All monitored operations healthy"
    fi

    RESULT_SUMMARY="ok=${#OK_ITEMS[@]}, warnings=${#WARNING_ITEMS[@]}, critical=${#CRITICAL_ITEMS[@]}"
    notify_unraid "$importance" "$description" "$body"
    write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
    (( ${#CRITICAL_ITEMS[@]} == 0 ))
}

main "$@"
