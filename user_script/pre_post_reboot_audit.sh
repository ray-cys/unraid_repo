#!/bin/bash

###############################################################################
# Pre/Post Reboot Audit
#
# Capture a stable Unraid configuration and service inventory before shutdown,
# then compare it after the next boot.
#
# Usage:
#   pre_post_reboot_audit.sh capture
#   pre_post_reboot_audit.sh compare
#   pre_post_reboot_audit.sh auto
#
# "auto" captures when the baseline belongs to the current boot and compares
# when the baseline belongs to a previous boot.
###############################################################################

set -uo pipefail
umask 077

readonly SCRIPT_VERSION="1.0"

###############################################################################
# CONFIGURATION
###############################################################################

# Stored on the boot device so it is available before the array starts.
STATE_ROOT="/boot/config/plugins/user.scripts/pre_post_reboot_audit"
BASELINE_DIR="${STATE_ROOT}/baseline"
HISTORY_DIR="${STATE_ROOT}/history"
REPORT_FILE="${STATE_ROOT}/last-compare.txt"
LOG_FILE="${STATE_ROOT}/pre-post-reboot-audit.log"

MAX_HISTORY=5
WAIT_FOR_ARRAY_SECONDS=300
WAIT_INTERVAL_SECONDS=10
POST_ARRAY_SETTLE_SECONDS=30

STATUS_DIR="/mnt/vault/cloud/logs/user_scripts_status"
NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
LOCK_FILE="/run/pre_post_reboot_audit.lock"

###############################################################################
# RUNTIME
###############################################################################

START_EPOCH="$(date +%s)"
RUN_STAMP="$(date '+%Y%m%d_%H%M%S')"
CURRENT_BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)"

RESULT_STATUS="FAILED"
RESULT_SUMMARY="Reboot audit exited before completion"
RECEIPT_WRITTEN=0
TMP_DIR=""

CRITICAL_CHANGES=0
WARNING_CHANGES=0

###############################################################################
# HELPERS
###############################################################################

log() {
    local level="$1"
    shift
    local line
    printf -v line '%s [%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
    printf '%s\n' "$line"
    [[ -d "$STATE_ROOT" ]] && printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
}

notify_unraid() {
    local importance="$1" description="$2" message="$3"
    [[ -x "$NOTIFY_BIN" ]] || return 0
    "$NOTIFY_BIN" -i "$importance" -s "Pre/Post Reboot Audit" \
        -d "$description" -m "$message" >/dev/null 2>&1 || true
}

write_receipt() {
    local status="$1" summary="$2" now tmp
    now="$(date +%s)"
    [[ -d /mnt/vault ]] || return 0
    mkdir -p -- "$STATUS_DIR" 2>/dev/null || return 0
    command -v jq >/dev/null 2>&1 || return 0
    tmp="$(mktemp "${STATUS_DIR}/.pre_post_reboot_audit.XXXXXX")" || return 0
    if jq -n \
        --arg name "pre_post_reboot_audit" \
        --arg status "$status" \
        --arg summary "$summary" \
        --arg log "$LOG_FILE" \
        --argjson epoch "$now" \
        --argjson duration "$((now - START_EPOCH))" \
        '{name:$name,status:$status,summary:$summary,log:$log,epoch:$epoch,duration_seconds:$duration}' \
        >"$tmp"
    then
        mv -f -- "$tmp" "${STATUS_DIR}/pre_post_reboot_audit.json"
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

manifest_tree() {
    local root="$1" output="$2"
    if [[ ! -d "$root" ]]; then
        printf 'MISSING %s\n' "$root" >"$output"
        return 0
    fi
    find "$root" -type f -print0 2>/dev/null |
        sort -z |
        xargs -0 -r sha256sum >"$output"
}

prune_history() {
    local -a entries=()
    local path
    mapfile -t entries < <(
        find "$HISTORY_DIR" -mindepth 1 -maxdepth 1 -type d \
            \( -name 'baseline-*' -o -name 'post-boot-*' \) \
            -printf '%T@|%p\n' 2>/dev/null | sort -rn | cut -d'|' -f2-
    )
    for ((i=MAX_HISTORY; i<${#entries[@]}; i++)); do
        path="${entries[$i]}"
        [[ "$path" == "$HISTORY_DIR"/baseline-* ||
           "$path" == "$HISTORY_DIR"/post-boot-* ]] || continue
        rm -rf -- "$path"
    done
}

###############################################################################
# INVENTORY
###############################################################################

capture_inventory() {
    local destination="$1"
    mkdir -p -- "$destination" || return 1

    printf '%s\n' "$CURRENT_BOOT_ID" >"$destination/boot_id"
    {
        printf 'captured=%s\n' "$(date -Iseconds)"
        printf 'hostname=%s\n' "$(hostname)"
        printf 'kernel=%s\n' "$(uname -r)"
        printf 'script_version=%s\n' "$SCRIPT_VERSION"
        [[ -f /etc/unraid-version ]] && sed 's/^/unraid_/' /etc/unraid-version
    } >"$destination/metadata"

    if command -v mdcmd >/dev/null 2>&1; then
        mdcmd status 2>/dev/null |
            awk -F= '
                $1 ~ /^(rdevName|rdevId|diskName|diskId|diskSize)\.[0-9]+$/ {
                    print
                }
            ' |
            sort >"$destination/array_assignments"
    else
        printf 'mdcmd unavailable\n' >"$destination/array_assignments"
    fi

    lsblk -dn -o NAME,SERIAL,SIZE,MODEL 2>/dev/null |
        sed -E 's/[[:space:]]+/ /g' |
        sort >"$destination/block_devices"

    manifest_tree /boot/config/shares "$destination/shares.sha256"
    manifest_tree /boot/config/plugins/dockerMan/templates-user \
        "$destination/docker_templates.sha256"

    find /boot/config/plugins -maxdepth 1 -type f -name '*.plg' \
        -printf '%f\n' 2>/dev/null |
        sort >"$destination/plugins"

    if command -v docker >/dev/null 2>&1 &&
       docker info >/dev/null 2>&1; then
        docker ps -a --format '{{.Names}}|{{.Image}}' |
            sort >"$destination/containers"
        docker ps --format '{{.Names}}' |
            sort >"$destination/containers_running"
    else
        printf 'DOCKER_UNAVAILABLE\n' >"$destination/containers"
        : >"$destination/containers_running"
    fi

    if command -v virsh >/dev/null 2>&1; then
        virsh list --all --name 2>/dev/null |
            sed '/^$/d' |
            sort >"$destination/vms"
        virsh list --name 2>/dev/null |
            sed '/^$/d' |
            sort >"$destination/vms_running"
    else
        : >"$destination/vms"
        : >"$destination/vms_running"
    fi

    if command -v ip >/dev/null 2>&1; then
        ip -brief address 2>/dev/null >"$destination/network_addresses"
        ip route show 2>/dev/null >"$destination/network_routes"
    else
        : >"$destination/network_addresses"
        : >"$destination/network_routes"
    fi

    findmnt -rn -o TARGET,SOURCE,FSTYPE 2>/dev/null |
        awk '$1 ~ /^\/mnt\// {print}' |
        sort >"$destination/mounts"
}

###############################################################################
# CAPTURE
###############################################################################

capture_baseline() {
    local new_baseline old_baseline
    new_baseline="$(mktemp -d "${STATE_ROOT}/.baseline.XXXXXX")" || return 1
    TMP_DIR="$new_baseline"
    capture_inventory "$new_baseline" || return 1

    if [[ -d "$BASELINE_DIR" ]]; then
        old_baseline="${HISTORY_DIR}/baseline-${RUN_STAMP}"
        mv -- "$BASELINE_DIR" "$old_baseline" || return 1
    fi
    mv -- "$new_baseline" "$BASELINE_DIR" || return 1
    TMP_DIR=""
    prune_history

    RESULT_STATUS="OK"
    RESULT_SUMMARY="Pre-reboot baseline captured for boot $CURRENT_BOOT_ID"
    log INFO "$RESULT_SUMMARY"
    write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
}

###############################################################################
# COMPARE
###############################################################################

wait_for_array() {
    local waited=0
    while (( waited <= WAIT_FOR_ARRAY_SECONDS )); do
        if mountpoint -q /mnt/user; then
            sleep "$POST_ARRAY_SETTLE_SECONDS"
            return 0
        fi
        sleep "$WAIT_INTERVAL_SECONDS"
        waited=$((waited + WAIT_INTERVAL_SECONDS))
    done
    log WARN "Array did not become ready within ${WAIT_FOR_ARRAY_SECONDS}s"
    return 1
}

compare_file() {
    local severity="$1" label="$2" filename="$3"
    local before="${BASELINE_DIR}/${filename}"
    local after="${TMP_DIR}/${filename}"
    local diff_output

    if [[ ! -f "$before" || ! -f "$after" ]]; then
        diff_output="Required inventory file is missing"
    else
        diff_output="$(diff -u -- "$before" "$after" 2>/dev/null | head -n 120 || true)"
    fi
    [[ -n "$diff_output" ]] || return 0

    {
        printf '\n[%s] %s changed\n' "$severity" "$label"
        printf '%s\n' "$diff_output"
    } >>"$REPORT_FILE"

    if [[ "$severity" == CRITICAL ]]; then
        CRITICAL_CHANGES=$((CRITICAL_CHANGES + 1))
    else
        WARNING_CHANGES=$((WARNING_CHANGES + 1))
    fi
}

compare_after_reboot() {
    local baseline_boot post_history
    [[ -d "$BASELINE_DIR" && -f "$BASELINE_DIR/boot_id" ]] || {
        log ERROR "No pre-reboot baseline exists"
        return 1
    }
    baseline_boot="$(cat "$BASELINE_DIR/boot_id")"
    wait_for_array || true

    TMP_DIR="$(mktemp -d "${STATE_ROOT}/.post-boot.XXXXXX")" || return 1
    capture_inventory "$TMP_DIR" || return 1

    {
        printf 'Pre/Post Reboot Audit\n'
        printf 'Generated: %s\n' "$(date -Iseconds)"
        printf 'Baseline boot: %s\n' "$baseline_boot"
        printf 'Current boot:  %s\n' "$CURRENT_BOOT_ID"
    } >"$REPORT_FILE"

    compare_file CRITICAL "Array assignments" array_assignments
    compare_file CRITICAL "Physical block devices" block_devices
    compare_file CRITICAL "Share configuration" shares.sha256
    compare_file CRITICAL "Docker templates" docker_templates.sha256

    compare_file WARNING "Installed plugins" plugins
    compare_file WARNING "Configured containers" containers
    compare_file WARNING "Previously running containers" containers_running
    compare_file WARNING "Configured virtual machines" vms
    compare_file WARNING "Previously running virtual machines" vms_running
    compare_file WARNING "Network addresses" network_addresses
    compare_file WARNING "Network routes" network_routes
    compare_file WARNING "Storage mounts" mounts

    {
        printf '\nSummary\n'
        printf 'Critical changes: %s\n' "$CRITICAL_CHANGES"
        printf 'Warnings: %s\n' "$WARNING_CHANGES"
    } >>"$REPORT_FILE"

    post_history="${HISTORY_DIR}/post-boot-${RUN_STAMP}"
    mv -- "$TMP_DIR" "$post_history" || return 1
    TMP_DIR=""
    prune_history

    if (( CRITICAL_CHANGES > 0 )); then
        RESULT_STATUS="CRITICAL"
        RESULT_SUMMARY="$CRITICAL_CHANGES critical and $WARNING_CHANGES warning-level post-reboot changes"
        notify_unraid alert "Critical post-reboot drift detected" \
            "$RESULT_SUMMARY"$'\n'"Report: $REPORT_FILE"
    elif (( WARNING_CHANGES > 0 )); then
        RESULT_STATUS="WARNING"
        RESULT_SUMMARY="$WARNING_CHANGES warning-level post-reboot changes"
        notify_unraid warning "Post-reboot differences detected" \
            "$RESULT_SUMMARY"$'\n'"Report: $REPORT_FILE"
    else
        RESULT_STATUS="OK"
        RESULT_SUMMARY="Post-reboot inventory matches the pre-reboot baseline"
        notify_unraid normal "Post-reboot audit passed" "$RESULT_SUMMARY"
    fi
    log INFO "$RESULT_SUMMARY"
    write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
    (( CRITICAL_CHANGES == 0 ))
}

###############################################################################
# MAIN
###############################################################################

main() {
    local mode="${1:-auto}" baseline_boot=""

    if ! mountpoint -q /boot; then
        printf 'Boot device is not mounted: /boot\n' >&2
        return 1
    fi
    [[ "$STATE_ROOT" == /boot/config/plugins/user.scripts/* ]] || {
        printf 'Unsafe STATE_ROOT: %s\n' "$STATE_ROOT" >&2
        return 1
    }
    mkdir -p -- "$STATE_ROOT" "$HISTORY_DIR" || return 1
    touch "$LOG_FILE" || return 1

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        RESULT_SUMMARY="Another reboot audit run is active"
        log ERROR "$RESULT_SUMMARY"
        return 1
    fi

    case "$mode" in
        capture)
            capture_baseline
            ;;
        compare)
            compare_after_reboot
            ;;
        auto)
            [[ -f "$BASELINE_DIR/boot_id" ]] &&
                baseline_boot="$(cat "$BASELINE_DIR/boot_id")"
            if [[ -z "$baseline_boot" || "$baseline_boot" == "$CURRENT_BOOT_ID" ]]; then
                capture_baseline
            else
                compare_after_reboot
            fi
            ;;
        *)
            log ERROR "Usage: $0 capture|compare|auto"
            return 2
            ;;
    esac
}

main "$@"
