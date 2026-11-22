#!/bin/bash
# shellcheck disable=SC2034
arrayStarted=true
# Backup freshness, delivery and runtime-compatibility audit v1.0.
# Schedule: 20 * * * *. Reads local receipts/manifests only: no WOL, remote
# connection, media hashing, container actions or cleanup. One lifecycle email
# for changed findings, recovery, or a 24-hour reminder. Failed delivery retries.
# CLI: bash script [--help|--version]. No CLI modifies backup or application data.
set -uo pipefail
readonly SCRIPT_VERSION="1.0"
STATUS_DIR="${STATUS_DIR:-/mnt/vault/cloud/logs/script/user_scripts_status}"
STATE_DIR="${STATE_DIR:-/mnt/vault/cloud/logs/script/backup_health_audit}"
APPDATA_ROOT="${APPDATA_ROOT:-/mnt/vault/backup/cache}"
FLASH_ROOT="${FLASH_ROOT:-/mnt/vault/backup/flash}"
REMOTE_LOG_ROOT="${REMOTE_LOG_ROOT:-/mnt/vault/cloud/logs/script/remote_backup}"
UNRAID_VERSION_FILE="${UNRAID_VERSION_FILE:-/etc/unraid-version}"
NOTIFY_BIN="${NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify}"
APPDATA_MAX_AGE_SECONDS=$((80*3600))
FLASH_MAX_AGE_SECONDS=$((80*3600))
MIRROR_MAX_AGE_SECONDS=$((8*86400))
DRILL_MAX_AGE_SECONDS=$((8*86400))
ISS_PENDING_MAX_AGE_SECONDS=$((6*3600))
REMINDER_SECONDS=86400
LOG_MAX_BYTES=262144
NOW=$(date +%s)
FINDINGS=()
ACTIONS=()
RUNTIME_SAFE=true
PLATFORM_VERSION=unknown

finding() { FINDINGS+=("$*"); }
audit_log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$STATE_DIR/audit.log"; }
latest_path() {
    find "$1" -mindepth 1 -maxdepth 1 -type "$2" -name "$3" ! -name '*.partial' ! -name '*.failed' -printf '%f\n' 2>/dev/null | sort | tail -n 1
}
check_age() {
    local label="$1" epoch="$2" limit="$3"
    if ! [[ "$epoch" =~ ^[0-9]+$ ]] || (( epoch==0 )); then finding "$label: no successful completion evidence"; return; fi
    if (( epoch>NOW+300 )); then finding "$label: future-dated receipt; clock/evidence review required"
    elif (( NOW-epoch>limit )); then finding "$label: completion is overdue (limit=$((limit/3600)) hours)"; ACTIONS+=("$label: last completion $(((NOW-epoch)/3600)) hours ago."); fi
}
audit_runtime() {
    local command version major missing=false
    for command in bash curl jq flock timeout rsync tar unzip sha256sum find sort stat df realpath docker smartctl findmnt mountpoint; do
        if ! command -v "$command" >/dev/null; then finding "Compatibility: required host command unavailable: $command"; missing=true; fi
    done
    PLATFORM_VERSION=$(sed -n 's/^version="\([^"]*\)"/\1/p' "$UNRAID_VERSION_FILE" 2>/dev/null)
    [[ -n "$PLATFORM_VERSION" ]] || PLATFORM_VERSION=unknown
    major=${PLATFORM_VERSION%%.*}
    if [[ "$major" != 7 ]]; then
        finding "Compatibility: Unraid $PLATFORM_VERSION is outside the validated 7.x family. Validate User Scripts scheduling, notification/boot hooks, Docker permissions and Mover interfaces before destructive automation. No compatibility approval inferred."
        missing=true
    fi
    if ! find --version 2>/dev/null | head -n 1 | grep -q GNU; then finding 'Compatibility: GNU find interface unavailable'; missing=true; fi
    if ! stat --version 2>/dev/null | head -n 1 | grep -q GNU; then finding 'Compatibility: GNU stat interface unavailable'; missing=true; fi
    version=$(rsync --version 2>/dev/null | head -n 1)
    if ! awk '{split($3,v,".");exit !(v[1]>3 || (v[1]==3 && v[2]>=1))}' <<<"$version"; then finding 'Compatibility: rsync >=3.1 required on Hubble; ISS is checked during transfers'; missing=true; fi
    [[ -x "$NOTIFY_BIN" ]] || { finding 'Compatibility: Unraid notification helper unavailable; notifications cannot be delivered'; missing=true; }
    if ! timeout 15 docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then finding 'Compatibility: Docker daemon/API unavailable'; missing=true; fi
    local path cron
    for path in /mnt/user /mnt/cache /mnt/data /mnt/vault /mnt/ramlogs; do
        mountpoint -q "$path" || { finding "Compatibility: required filesystem is not mounted: $path"; missing=true; }
    done
    cron=$(timeout 8 crontab -c /etc/cron.d -l 2>/dev/null) || { cron=""; finding 'Compatibility: active Unraid cron inventory unavailable'; missing=true; }
    for path in appdata_backup flash_disk_backup remote_backup vault_remote_backup arr_health_activity arr_delete_sync_tag arr_sabnzbd_cleanup quarantine_lifecycle docker_service_watchdog dns_redundancy_watchdog ramlog_monitor torrent_download_complete backup_health_audit kometa_preflight imagemaid_restore_archive; do
        if [[ ! -f "/boot/config/plugins/user.scripts/scripts/$path/script" ]] ||
           ! grep -Fq "/scripts/$path/script" <<<"$cron"; then
            finding "Scheduling: required User Script missing or not scheduled: $path"; missing=true
        fi
    done
    [[ "$missing" != true ]] || RUNTIME_SAFE=false
}
audit_backups() {
    local latest path created epoch=0 request delivered requested source manifest old_digest new_digest log copy_epoch=0
    latest=$(latest_path "$APPDATA_ROOT" d 'backup_[0-9]*_[0-9]*')
    path="$APPDATA_ROOT/$latest"
    if [[ -n "$latest" && -f "$path/backup_manifest.tsv" && -f "$path/backup_manifest.tsv.sha256" ]]; then
        old_digest=$(awk 'NR==1 {print $1}' "$path/backup_manifest.tsv.sha256")
        new_digest=$(sha256sum "$path/backup_manifest.tsv" | awk '{print $1}')
        [[ "$old_digest" == "$new_digest" && "$old_digest" =~ ^[a-f0-9]{64}$ ]] || finding 'Appdata: current generation manifest checksum mismatch; archive payloads were not rehashed by this audit'
        created=$(sed -n 's/^# created=//p' "$path/backup_manifest.tsv")
        epoch=$(date -d "$created" +%s 2>/dev/null || printf 0)
        ACTIONS+=("Appdata generation: $latest; manifest checked, archive payload verification remains the producer/ISS/drill responsibility.")
    fi
    check_age Appdata "$epoch" "$APPDATA_MAX_AGE_SECONDS"
    latest=$(latest_path "$FLASH_ROOT" f '*-boot-backup-*.zip')
    epoch=0
    if [[ -n "$latest" && -f "$FLASH_ROOT/$latest.sha256" ]]; then epoch=$(stat -c %Y "$FLASH_ROOT/$latest"); ACTIONS+=("Flash generation: $latest; checksum sidecar present (ZIP payload not rehashed)."); fi
    check_age Flash "$epoch" "$FLASH_MAX_AGE_SECONDS"
    if [[ -f "$STATUS_DIR/remote_backup.json" ]] && jq -e '.copy=="OK" and .verification=="rsync_transfer_verified"' "$STATUS_DIR/remote_backup.json" >/dev/null; then
        copy_epoch=$(jq -r .epoch "$STATUS_DIR/remote_backup.json")
    else
        # Cutover compatibility: the previous successful mirror predates atomic
        # receipts. A bounded, anchored success line is legacy log evidence only.
        log=$(latest_path "$REMOTE_LOG_ROOT" f 'remote_backup_*.log')
        if [[ -n "$log" ]]; then
            created=$(tail -n 80 "$REMOTE_LOG_ROOT/$log" | sed -n '/\[BACKUP\]\[INFO\] Remote backup completed successfully/s/^\(.\{19\}\).*/\1/p' | tail -n 1)
            [[ -z "$created" ]] || copy_epoch=$(date -d "$created" +%s 2>/dev/null || printf 0)
            (( copy_epoch==0 )) || ACTIONS+=('Mirror freshness obtained from legacy completion log; next successful mirror should publish its verification receipt.')
        fi
    fi
    check_age 'Media/Secure mirror' "$copy_epoch" "$MIRROR_MAX_AGE_SECONDS"
    request="$STATUS_DIR/iss-backup-request.json"; delivered="$STATUS_DIR/iss-backup-delivered.json"
    if [[ -f "$request" ]]; then
        if jq -e '.schema==1 and (.completedAt|type)=="number" and (.manifestSha256|type)=="string"' "$request" >/dev/null; then
            requested=$(jq -r .completedAt "$request")
            source=$(jq -r .generation "$request"); manifest=$(jq -r .manifestSha256 "$request")
            if [[ -f "$delivered" ]] && jq -e --arg id "${source##*/}:$manifest" '.requestId==$id and .verification=="sha256"' "$delivered" >/dev/null; then
                ACTIONS+=("ISS acknowledged appdata generation ${source##*/}; remote SHA verification recorded.")
                [[ -f /mnt/vault/backup/operations_state/export.json ]] || finding 'Operational-state export missing after ISS delivery; check the vault script version and source map'
            else
                check_age 'Pending ISS completion request' "$requested" "$ISS_PENDING_MAX_AGE_SECONDS"
                ACTIONS+=("ISS request pending for ${source##*/}; hourly transfer retry remains responsible. ISS was not contacted by this audit.")
            fi
        else finding 'ISS request: invalid completion receipt; existing file preserved'; fi
    else
        ACTIONS+=('ISS handoff: awaiting the first successful appdata producer request after cutover.')
    fi
    if [[ -f "$STATUS_DIR/vault_backup.json" ]]; then
        [[ $(jq -r '.restoreDrill // "not_observed"' "$STATUS_DIR/vault_backup.json") != FAILED ]] || finding 'ISS restore drill failed after a verified copy; backup retained; inspect the vault drill summary'
        epoch=$(jq -r '.restoreDrillEpoch // 0' "$STATUS_DIR/vault_backup.json")
    else epoch=0; fi
    if [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch>0 )); then check_age 'ISS rotating restore drill' "$epoch" "$DRILL_MAX_AGE_SECONDS"
    elif [[ -f "$STATUS_DIR/backup_restore_drill.json" ]]; then
        epoch=$(jq -r 'if .status=="OK" or .status=="WARNING" then .epoch else 0 end' "$STATUS_DIR/backup_restore_drill.json")
        check_age 'Local rotating restore drill' "$epoch" "$DRILL_MAX_AGE_SECONDS"
        ACTIONS+=('ISS drill execution has not yet been recorded by the new vault workflow; local drill evidence is labelled separately.')
    else finding 'Restore drill: no successful local or ISS completion evidence'; fi
}
main() {
    case "${1:-}" in --version) printf 'backup_health_audit.sh %s\n' "$SCRIPT_VERSION"; return;; --help) printf 'Usage: bash script\nHourly read-only backup freshness/runtime audit; never wakes ISS or starts backups.\n'; return;; '') ;; *) return 2;; esac
    for command in jq flock timeout date find stat sha256sum; do command -v "$command" >/dev/null || return 1; done
    if ! mountpoint -q /mnt/vault; then printf 'Vault unavailable; no shadow audit state created.\n' >&2; return 1; fi
    mkdir -p "$STATE_DIR" "$STATUS_DIR" || return 1
    exec 9>"$STATE_DIR/audit.lock" || return 1
    flock -n 9 || return 0
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || return 1
    flock -s -n "$export_fd" || return 0
    local previous='' last=0 fingerprint temp status=OK importance=normal body
    audit_runtime; audit_backups
    fingerprint=$(printf '%s\n' "${FINDINGS[@]}" | sort | sha256sum | awk '{print $1}')
    if [[ -f "$STATE_DIR/state.json" ]]; then
        jq -e '.fingerprint|type=="string"' "$STATE_DIR/state.json" >/dev/null || { printf 'Invalid audit state preserved.\n' >&2; return 1; }
        previous=$(jq -r .fingerprint "$STATE_DIR/state.json"); last=$(jq -r '.notifiedAt // 0' "$STATE_DIR/state.json")
        [[ "$last" =~ ^[0-9]+$ ]] || return 1
    fi
    if (( ${#FINDINGS[@]}>0 )); then status=WARNING; importance=warning; fi
    body="Backup audit: $status; Unraid $PLATFORM_VERSION; findings=${#FINDINGS[@]}."$'\n'"$(printf '%s\n' "${FINDINGS[@]}" "${ACTIONS[@]}")"$'\n''Actions: local backup evidence and host capabilities checked. No backup, remote wake, media scan, restart or cleanup was performed.'
    if [[ "$fingerprint" != "$previous" && ( -n "$previous" || "$status" != OK ) ]] || { [[ "$status" != OK ]] && (( NOW-last>=REMINDER_SECONDS )); }; then
        if [[ ! -x "$NOTIFY_BIN" ]] || ! timeout 30 "$NOTIFY_BIN" -i "$importance" -s 'Backup Health Audit' -d "Backup audit: $status" -m "$body"; then
            printf 'Audit notification failed; transition remains pending.\n' >&2; return 1
        fi
        last=$NOW
    fi
    temp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 1
    jq -n --arg fingerprint "$fingerprint" --argjson notifiedAt "$last" --argjson epoch "$NOW" '{fingerprint:$fingerprint,notifiedAt:$notifiedAt,epoch:$epoch}' >"$temp" && mv "$temp" "$STATE_DIR/state.json" || return 1
    temp=$(mktemp "$STATUS_DIR/.backup-audit.XXXXXX") || return 1
    jq -n --arg name backup_health_audit --arg status "$status" --arg summary "$body" --arg version "$PLATFORM_VERSION" --argjson safe "$RUNTIME_SAFE" --argjson epoch "$NOW" '{name:$name,status:$status,summary:$summary,platformVersion:$version,runtimeCapabilitiesPassed:$safe,epoch:$epoch}' >"$temp" && mv "$temp" "$STATUS_DIR/backup_health_audit.json" || return 1
    if [[ -f "$STATE_DIR/audit.log" ]] && (( $(stat -c %s "$STATE_DIR/audit.log")>=LOG_MAX_BYTES )); then mv -f "$STATE_DIR/audit.log" "$STATE_DIR/audit.log.1"; fi
    audit_log "Audit complete: $status; findings=${#FINDINGS[@]}; platform=$PLATFORM_VERSION"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
