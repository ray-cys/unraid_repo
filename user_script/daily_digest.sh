#!/bin/bash
# Weekly Unraid Operations Audit v2.0
# Retains the historical daily_digest.sh filename. Repository storage does not
# install or schedule this script. If enabled later, run weekly after backups
# (example: 0 12 * * 1). Adjust rules to match your actual job schedules first.
#
# Reads local completion evidence; never starts jobs, contacts a remote server,
# changes backups, or reads full archive payloads. Notification occurs only on
# a finding change or recovery. Unchanged findings have no reminder emails.

set -uo pipefail
umask 077
readonly SCRIPT_VERSION="2.0"

###############################################################################
# CONFIGURATION
###############################################################################

VAULT_MOUNT="/mnt/vault"
STATUS_DIR="/mnt/vault/cloud/logs/script/user_scripts_status"

# name|absolute receipt path|max age hours|required (0/1)
# Paths intentionally match each producer; older scripts still use logs/ without
# script/. Missing optional receipts are ignored, but failures are not ignored.
# An age of 0 disables age checking for event-driven jobs such as reboot audits.
# Remove rules for jobs you do not run. 192h allows an 8-day weekly backup window.
RECEIPT_RULES=(
    "backup_vault_remote|/mnt/vault/cloud/logs/script/user_scripts_status/backup_vault_remote.json|192|1"
    "backup_restore_drill|/mnt/vault/cloud/logs/user_scripts_status/backup_restore_drill.json|192|1"
    "mover_audit|/mnt/vault/cloud/logs/user_scripts_status/mover_audit.json|30|1"
    "docker_service_watchdog|/mnt/vault/cloud/logs/user_scripts_status/docker_service_watchdog.json|1|1"
    "dns_redundancy_watchdog|/mnt/vault/cloud/logs/script/user_scripts_status/dns_redundancy_watchdog.json|1|1"
    "media_cleanup|/mnt/vault/cloud/logs/script/user_scripts_status/media_cleanup.json|30|1"
    "media_plex_dbrepair|/mnt/vault/cloud/logs/script/user_scripts_status/media_plex_dbrepair.json|192|1"
    "pre_post_reboot_audit|/mnt/vault/cloud/logs/user_scripts_status/pre_post_reboot_audit.json|0|0"
)

APPDATA_BACKUP_ROOT="/mnt/vault/backup/cache"
FLASH_BACKUP_ROOT="/mnt/vault/backup/flash"
FLASH_STATE_FILE="${FLASH_BACKUP_ROOT}/.backup_boot_disk_state.json"
BACKUP_MAX_AGE_HOURS=192

# Check monitor execution, not the active Sonarr/Radarr/SAB issue inventory.
# Those applications' health findings remain owned by media_health_monitor.sh.
# A recent start alone is insufficient: successful completion must be recent.
ARR_STATE_FILE="/mnt/vault/cloud/logs/script/media_health_monitor/state.json"
ARR_MAX_AGE_MINUTES=15

# Disk-health logs and backup_media_remote.sh have no compatible completion receipt;
# log freshness is deliberately not treated as proof of successful execution.
SEND_NOTIFICATION=true
MAX_DETAIL_ITEMS=30
LOG_DIR="/mnt/vault/cloud/logs/script/daily_digest"
LOG_FILE="${LOG_DIR}/weekly-audit.log"
LOG_MAX_BYTES=$((1024 * 1024))
NOTIFICATION_STATE_FILE="${LOG_DIR}/notification-state.json"
NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
LOCK_FILE="/run/daily_digest.lock"

###############################################################################
# RUNTIME AND REPORTING
###############################################################################

START_EPOCH="$(date +%s)"
OK_ITEMS=()
WARNING_ITEMS=()
CRITICAL_ITEMS=()
ISSUE_KEYS=()

log() {
    local level="$1" line size
    local LC_ALL=C
    shift
    printf -v line '%s [%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
    if (( ${#line} > 4096 )); then line="${line:0:4070} ... [line truncated]"; fi
    printf '%s\n' "$line"
    size="$(stat -c %s "$LOG_FILE" 2>/dev/null || printf 0)"
    if (( size + ${#line} + 1 > LOG_MAX_BYTES )); then
        mv -f -- "$LOG_FILE" "${LOG_FILE}.1" || return 1
    fi
    printf '%s\n' "$line" >>"$LOG_FILE"
}

# The key identifies the condition, not its changing age or run-specific summary.
# This prevents weekly duplicate emails for an unchanged failure.
add_item() {
    local severity="$1" key="$2" message="$3"
    case "$severity" in
        OK) OK_ITEMS+=("$message") ;;
        WARNING) WARNING_ITEMS+=("$message"); ISSUE_KEYS+=("WARNING:$key") ;;
        CRITICAL) CRITICAL_ITEMS+=("$message"); ISSUE_KEYS+=("CRITICAL:$key") ;;
    esac
}

human_age() {
    local seconds="$1"
    if (( seconds < 3600 )); then printf '%sm' "$((seconds / 60))"
    elif (( seconds < 86400 )); then printf '%sh %sm' "$((seconds / 3600))" "$((seconds % 3600 / 60))"
    else printf '%sd %sh' "$((seconds / 86400))" "$((seconds % 86400 / 3600))"; fi
}

check_age() {
    local key="$1" label="$2" epoch="$3" max_seconds="$4" age
    if [[ ! "$epoch" =~ ^[1-9][0-9]*$ ]] || (( epoch > START_EPOCH + 300 )); then
        add_item CRITICAL "$key:timestamp" "$label: completion timestamp missing, invalid, or in the future"
        return 1
    fi
    age=$((START_EPOCH - epoch))
    if (( max_seconds > 0 && age > max_seconds )); then
        add_item CRITICAL "$key:overdue" "$label: completion overdue (age=$(human_age "$age"); limit=$(human_age "$max_seconds"))"
        return 1
    fi
}

check_receipt() {
    local name file max_hours required status summary epoch fresh=true
    IFS='|' read -r name file max_hours required <<<"$1"
    if [[ ! -e "$file" && "$required" == 0 ]]; then return 0; fi
    if ! jq -e 'type == "object" and (.status | type == "string") and
        (.epoch | type == "number" and . == floor)' "$file" >/dev/null 2>&1; then
        add_item CRITICAL "$name:receipt" "$name: completion receipt missing or invalid ($file)"
        return 0
    fi
    status="$(jq -r '.status' "$file")"
    summary="$(jq -r '.summary // "No summary recorded"' "$file")"
    epoch="$(jq -r '.epoch' "$file")"
    check_age "$name" "$name" "$epoch" "$((max_hours * 3600))" || fresh=false
    case "$status" in
        OK) [[ "$fresh" != true ]] || add_item OK "$name" "$name: last receipt OK; $summary" ;;
        WARNING) add_item WARNING "$name:status:$status" "$name: WARNING; $summary" ;;
        FAILED|CRITICAL) add_item CRITICAL "$name:status:$status" "$name: $status; $summary" ;;
        *) add_item WARNING "$name:status:$status" "$name: unrecognized status '$status'; $summary" ;;
    esac
}

###############################################################################
# BACKUP COMPLETION EVIDENCE
###############################################################################

# Validate only the small manifest checksum and archive metadata. Full payload
# hashes and extraction are the restore drill's responsibility. Exact finalized
# directory names exclude .partial, .failed, and .staged generations.
appdata_metadata_valid() {
    local directory="$1" manifest count raw bytes hash name actual seen=0
    local -A names=()
    manifest="$directory/backup_manifest.tsv"
    [[ -f "$manifest" && ! -L "$manifest" && -f "$manifest.sha256" && ! -L "$manifest.sha256" ]] || return 1
    # Do not let a modified checksum sidecar name arbitrary paths to read.
    [[ "$(wc -l <"$manifest.sha256")" -eq 1 ]] || return 1
    read -r hash name <"$manifest.sha256"
    [[ "$hash" =~ ^[[:xdigit:]]{64}$ && "$name" == backup_manifest.tsv ]] || return 1
    actual="$(sha256sum -- "$manifest")"
    [[ "${actual%% *}" == "$hash" ]] || return 1
    count="$(sed -n 's/^# archive_count=//p' "$manifest")"
    [[ "$count" =~ ^[1-9][0-9]*$ ]] || return 1
    while IFS=$'\t' read -r raw bytes hash name; do
        [[ "$raw" == \#* ]] && continue
        [[ "$raw" =~ ^[0-9]+$ && "$bytes" =~ ^[1-9][0-9]*$ && "$hash" =~ ^[[:xdigit:]]{64}$ &&
           -n "$name" && "$name" != */* && "$name" != . && "$name" != .. ]] || return 1
        [[ -z "${names[$name]+present}" ]] || return 1
        names["$name"]=1
        [[ -f "$directory/$name.tar.gz" && ! -L "$directory/$name.tar.gz" ]] || return 1
        actual="$(stat -c %s "$directory/$name.tar.gz")" || return 1
        [[ "$actual" == "$bytes" ]] || return 1
        seen=$((seen + 1))
    done <"$manifest"
    (( seen == count ))
}

check_appdata() {
    local directory newest="" epoch created
    if [[ ! -d "$APPDATA_BACKUP_ROOT" ]]; then
        add_item CRITICAL appdata:root "Appdata backup: root unavailable ($APPDATA_BACKUP_ROOT)"
        return
    fi
    # Fixed-width generation names sort chronologically without directory mtimes
    # changing the outcome when files are inspected or retention runs.
    while IFS= read -r -d '' directory; do
        [[ "${directory##*/}" =~ ^backup_[0-9]{8}_[0-9]{6}$ ]] || continue
        [[ "$directory" > "$newest" ]] && newest="$directory"
    done < <(find "$APPDATA_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -print0)
    if [[ -z "$newest" ]]; then
        add_item CRITICAL appdata:missing "Appdata backup: no finalized generation"
        return
    fi
    if ! appdata_metadata_valid "$newest"; then
        add_item CRITICAL appdata:metadata "Appdata backup: latest finalized generation has invalid manifest or missing/size-mismatched archives ($newest)"
        return
    fi
    created="$(sed -n 's/^# created=//p' "$newest/backup_manifest.tsv")"
    if [[ ! "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}$ ]]; then
        add_item CRITICAL appdata:timestamp "Appdata backup: manifest completion timestamp missing or invalid"
        return
    fi
    epoch="$(date -d "$created" +%s 2>/dev/null || printf 0)"
    if check_age appdata "Appdata backup" "$epoch" "$((BACKUP_MAX_AGE_HOURS * 3600))"; then
        add_item OK appdata "Appdata backup: finalized manifest and archive sizes valid (${newest##*/}); payload integrity not rechecked"
    fi
}

check_flash() {
    local path epoch bytes actual hash
    if ! jq -e 'type == "object" and (.successfulAt | type == "number" and . == floor) and
        (.archiveBytes | type == "number" and . > 0 and . == floor) and
        (.archiveSha256 | type == "string" and test("^[a-fA-F0-9]{64}$")) and
        (.backupFile | type == "string")' "$FLASH_STATE_FILE" >/dev/null 2>&1; then
        add_item CRITICAL flash:state "Flash backup: verified-success state missing or invalid ($FLASH_STATE_FILE)"
        return
    fi
    path="$(jq -r '.backupFile' "$FLASH_STATE_FILE")"
    bytes="$(jq -r '.archiveBytes' "$FLASH_STATE_FILE")"
    epoch="$(jq -r '.successfulAt' "$FLASH_STATE_FILE")"
    hash="$(jq -r '.archiveSha256' "$FLASH_STATE_FILE")"
    if [[ "${path%/*}" != "$FLASH_BACKUP_ROOT" || "$path" != *.zip || ! -f "$path" || -L "$path" ]]; then
        add_item CRITICAL flash:archive "Flash backup: recorded successful archive missing or outside backup root ($path)"
        return
    fi
    actual="$(stat -c %s "$path" 2>/dev/null || printf 0)"
    if [[ "$actual" != "$bytes" ]]; then
        add_item CRITICAL flash:size "Flash backup: recorded archive size mismatch ($path)"
        return
    fi
    if [[ ! -f "$path.sha256" || -L "$path.sha256" ]] || ! grep -Fq "$hash" "$path.sha256"; then
        add_item CRITICAL flash:sidecar "Flash backup: checksum sidecar missing or inconsistent with verified-success state"
        return
    fi
    if check_age flash "Flash backup" "$epoch" "$((BACKUP_MAX_AGE_HOURS * 3600))"; then
        add_item OK flash "Flash backup: recorded successful archive present; size and checksum record consistent; payload integrity not rechecked"
    fi
}

check_arr_execution() {
    local started completed exit_code status
    if ! jq -e '.monitor | type == "object" and
        (.lastStartedAt | type == "number" and . == floor) and
        (.lastCompletedAt | type == "number" and . == floor) and
        (.lastExitCode | type == "number" and . == floor) and
        (.lastStatus | type == "string")' "$ARR_STATE_FILE" >/dev/null 2>&1; then
        add_item CRITICAL arr:state "Arr monitor: execution state missing or invalid ($ARR_STATE_FILE)"
        return
    fi
    started="$(jq -r '.monitor.lastStartedAt' "$ARR_STATE_FILE")"
    completed="$(jq -r '.monitor.lastCompletedAt' "$ARR_STATE_FILE")"
    exit_code="$(jq -r '.monitor.lastExitCode' "$ARR_STATE_FILE")"
    status="$(jq -r '.monitor.lastStatus' "$ARR_STATE_FILE")"
    if [[ "$status" == failed || "$status" == interrupted ]] || (( exit_code != 0 )); then
        add_item CRITICAL arr:failed "Arr monitor: last execution failed (status=$status; exit=$exit_code)"
    fi
    if check_age arr "Arr monitor" "$completed" "$((ARR_MAX_AGE_MINUTES * 60))"; then
        if [[ "$status" != failed && "$status" != interrupted ]] && (( exit_code == 0 )); then
            add_item OK arr "Arr monitor: recent completed execution; pipeline status=$status (application findings handled by Arr monitor)"
        fi
    fi
    # A currently running five-minute scan is normal. A run with no completed
    # checkpoint inside the grace window is detected by completion age above.
    if [[ ! "$started" =~ ^[1-9][0-9]*$ ]] || (( started > START_EPOCH + 300 )); then
        add_item CRITICAL arr:start "Arr monitor: invalid run-start timestamp"
    fi
}

build_body() {
    local item count title limit="${1:-$MAX_DETAIL_ITEMS}"
    printf 'Weekly Unraid Operations Audit v%s\nGenerated: %s\n' "$SCRIPT_VERSION" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'Current findings: %s critical; %s warning; %s evidence checks current\n\n' "${#CRITICAL_ITEMS[@]}" "${#WARNING_ITEMS[@]}" "${#OK_ITEMS[@]}"
    for title in Critical Warnings Current; do
        local -a items=()
        case "$title" in
            Critical) items=("${CRITICAL_ITEMS[@]}") ;;
            Warnings) items=("${WARNING_ITEMS[@]}") ;;
            Current) items=("${OK_ITEMS[@]}") ;;
        esac
        (( ${#items[@]} > 0 )) || continue
        printf '%s:\n' "$title"
        count=0
        for item in "${items[@]}"; do
            if (( limit > 0 && count >= limit )); then
                printf '  Additional items omitted; consult the local audit log.\n'
                break
            fi
            printf '  - %s\n' "$item"
            count=$((count + 1))
        done
        printf '\n'
    done
    printf 'Scope: local completion evidence and backup metadata; no full archive verification or remote checks.\n'
}

###############################################################################
# NOTIFICATION LIFECYCLE
###############################################################################

update_notifications() {
    local current previous='[]' tmp importance=normal description body
    current="$(printf '%s\n' "${ISSUE_KEYS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')" || return 1
    if [[ -e "$NOTIFICATION_STATE_FILE" ]]; then
        if ! jq -e '.version == 1 and (.issues | type == "array" and all(.[]; type == "string"))' "$NOTIFICATION_STATE_FILE" >/dev/null 2>&1; then
            log ERROR "Notification state invalid: $NOTIFICATION_STATE_FILE"
            return 1
        fi
        previous="$(jq -c '.issues | unique' "$NOTIFICATION_STATE_FILE")" || return 1
    fi
    if [[ "$current" == "$previous" ]]; then
        log INFO "No finding transitions; notification suppressed"
        return 0
    fi
    if [[ "$SEND_NOTIFICATION" != true ]]; then
        log INFO "Notification disabled; delivered-state checkpoint unchanged"
        return 0
    fi
    if [[ "$current" == '[]' ]]; then
        description="Audit RESOLVED - no active findings"
    elif (( ${#CRITICAL_ITEMS[@]} > 0 )); then
        importance=alert
        description="Audit UPDATED - critical operational findings"
    else
        importance=warning
        description="Audit UPDATED - operational warnings"
    fi
    body="$(build_body)"$'\n'"Finding transitions:"$'\n'
    body+="$(jq -nr --argjson current "$current" --argjson previous "$previous" '
        (($current - $previous)[] | "  Raised: " + .),
        (($previous - $current)[] | "  Cleared: " + .)')"
    # Advance state only after delivery succeeds, allowing retries next run.
    if [[ ! -x "$NOTIFY_BIN" ]] || ! "$NOTIFY_BIN" -i "$importance" -s "Weekly Unraid Operations Audit" -d "$description" -m "$body"; then
        log ERROR "Notification delivery failed; finding transitions remain pending"
        return 1
    fi
    tmp="$(mktemp "${LOG_DIR}/.notification-state.XXXXXX")" || return 1
    if ! jq -n --argjson issues "$current" '{version:1,issues:$issues}' >"$tmp" ||
       ! mv -f -- "$tmp" "$NOTIFICATION_STATE_FILE"; then
        rm -f -- "$tmp"
        return 1
    fi
}

write_receipt() {
    local status="$1" summary="$2" tmp now
    now="$(date +%s)"
    tmp="$(mktemp "${STATUS_DIR}/.daily_digest.XXXXXX")" || return 1
    if ! jq -n --arg name daily_digest --arg version "$SCRIPT_VERSION" --arg status "$status" \
        --arg summary "$summary" --arg log "$LOG_FILE" --argjson epoch "$now" \
        --argjson duration "$((now - START_EPOCH))" \
        '{name:$name,scriptVersion:$version,status:$status,summary:$summary,log:$log,epoch:$epoch,duration_seconds:$duration}' >"$tmp" ||
       ! mv -f -- "$tmp" "${STATUS_DIR}/daily_digest.json"; then
        rm -f -- "$tmp"
        return 1
    fi
}

main() {
    local rule line status=OK rc=0 summary command
    case "${1:-}" in
        --version) printf 'daily_digest.sh %s\n' "$SCRIPT_VERSION"; return 0 ;;
        --help|-h)
            printf '%s\n' 'Usage: bash daily_digest.sh [--help|--version]' \
                'Default: audit local job receipts, backup completion evidence, and Arr execution.' \
                'Optional schedule: weekly after backups (example: 0 12 * * 1).' \
                'Configure paths and freshness windows before enabling on Unraid.' \
                'Alerts: new/changed findings and recovery only; healthy and unchanged runs are silent.' \
                'No automatic installation, scheduling, repair, or full archive verification.'
            return 0 ;;
        '') ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; return 2 ;;
    esac
    for command in jq mountpoint flock find stat sha256sum date mktemp sed grep wc; do
        command -v "$command" >/dev/null 2>&1 || { printf 'Required command missing: %s\n' "$command" >&2; return 1; }
    done
    # Do not create log/state directories on the root filesystem if vault is absent.
    mountpoint -q "$VAULT_MOUNT" || { printf 'Vault mount unavailable: %s\n' "$VAULT_MOUNT" >&2; return 1; }
    exec 9>"$LOCK_FILE" || return 1
    flock -n 9 || { printf 'Another operations audit is active\n'; return 0; }
    mkdir -p -- "$LOG_DIR" "$STATUS_DIR" || return 1
    touch "$LOG_FILE" || return 1
    for rule in "${RECEIPT_RULES[@]}"; do check_receipt "$rule"; done
    check_appdata
    check_flash
    check_arr_execution
    while IFS= read -r line; do log INFO "$line" || return 1; done < <(build_body 0)
    if (( ${#CRITICAL_ITEMS[@]} > 0 )); then status=CRITICAL; rc=1
    elif (( ${#WARNING_ITEMS[@]} > 0 )); then status=WARNING; fi
    if ! update_notifications; then status=FAILED; rc=1; fi
    summary="critical=${#CRITICAL_ITEMS[@]}, warnings=${#WARNING_ITEMS[@]}, evidence_current=${#OK_ITEMS[@]}"
    write_receipt "$status" "$summary" || return 1
    return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
