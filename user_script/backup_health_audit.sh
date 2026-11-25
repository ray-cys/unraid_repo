#!/bin/bash
# shellcheck disable=SC2034
clearLog=true
arrayStarted=true
# Backup freshness, delivery and runtime-compatibility audit v1.11.
# Schedule: 20 * * * *. Reads local receipts/manifests only: no WOL, remote
# connection, media hashing, container actions or cleanup. One lifecycle email
# for changed findings, recovery, or a 24-hour reminder. Failed delivery retries.
# CLI: bash script [--help|--version]. No CLI modifies backup or application data.
# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="backup_health_audit"
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
readonly SCRIPT_VERSION="1.11"
STATUS_DIR="${STATUS_DIR:-/mnt/vault/cloud/logs/script/user_scripts_status}"
STATE_DIR="${STATE_DIR:-/mnt/vault/cloud/logs/script/backup_health_audit}"
APPDATA_ROOT="${APPDATA_ROOT:-/mnt/vault/backup/cache}"
FLASH_ROOT="${FLASH_ROOT:-/mnt/vault/backup/flash}"
REMOTE_LOG_ROOT="${REMOTE_LOG_ROOT:-/mnt/vault/cloud/logs/script/backup_media_remote}"
UNRAID_VERSION_FILE="${UNRAID_VERSION_FILE:-/etc/unraid-version}"
DISK_HEALTH_RECEIPT="${DISK_HEALTH_RECEIPT:-/mnt/vault/cloud/logs/script/health_monitoring/state/monitor_receipt.json}"
DISK_HEALTH_MAX_AGE_SECONDS=$((30*3600))
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
audit_log() { local line;line=$(usr_ops_log_line INFO audit "$*");printf '%s\n' "$line";usr_ops_append_log "$STATE_DIR/audit.log" "$line" "$LOG_MAX_BYTES"; }
latest_path() {
    find "$1" -mindepth 1 -maxdepth 1 -type "$2" -name "$3" ! -name '*.partial' ! -name '*.failed' -printf '%f\n' 2>/dev/null | sort | tail -n 1
}
check_age() {
    local label="$1" epoch="$2" limit="$3"
    if ! [[ "$epoch" =~ ^[0-9]+$ ]] || (( epoch==0 )); then finding "$label: no successful completion evidence"; return; fi
    if (( epoch>NOW+300 )); then finding "$label: future-dated receipt; clock/evidence review required"
    elif (( NOW-epoch>limit )); then finding "$label: completion is overdue (limit=$((limit/3600)) hours)"; ACTIONS+=("$label: last completion $(((NOW-epoch)/3600)) hours ago."); fi
}
audit_disk_health_monitor() {
    local epoch
    epoch=$(jq -er 'select(.schema == 1) | .lastCompleteEpoch | numbers' "$DISK_HEALTH_RECEIPT" 2>/dev/null) || epoch=0
    check_age 'Disk health monitor' "$epoch" "$DISK_HEALTH_MAX_AGE_SECONDS"
    if jq -e '.schema == 1 and .notification == "failed"' "$DISK_HEALTH_RECEIPT" >/dev/null 2>&1; then
        finding 'Disk health monitor: the latest notification could not be delivered'
    fi
}
audit_media_integrity_monitor() {
    local receipt="$STATUS_DIR/media_integrity_audit.json" completed first max_gap progress
    if ! jq -e '.schema==1 and (.lastCompletedScanAt|type)=="number" and (.firstScheduledAt|type)=="number"' "$receipt" >/dev/null 2>&1; then
        finding 'Media integrity audit: completion/schedule receipt missing or invalid';return
    fi
    completed=$(jq -r .lastCompletedScanAt "$receipt");first=$(jq -r .firstScheduledAt "$receipt")
    progress=$(jq -r --argjson now "$NOW" '.lastProgressScanAt as $p | if ($p|type)=="number" and $p>0 and $p<=$now+300 then $p else 0 end' "$receipt")
    ((progress<=completed)) || completed="$progress"
    max_gap=$(jq -r '.schedule.maxGapSeconds // 691200' "$receipt")
    [[ "$max_gap" =~ ^[1-9][0-9]*$ ]] && ((max_gap>=86400 && max_gap<=1382400)) || max_gap=691200
    if (( completed>0 )); then check_age 'Media integrity audit completion/progress' "$completed" "$max_gap"
    elif (( first<=0 || NOW>first+86400 )); then finding 'Media integrity audit: first scheduled scan has not completed within its grace period';fi
    if jq -e '.notification=="failed"' "$receipt" >/dev/null; then finding 'Media integrity audit: grouped notification delivery failed; pending report retained';fi
    # Individual media findings remain owned by the scheduled audit, not repeated
    # in this hourly backup/runtime notification stream.
}

audit_media_coordination() {
    local receipt="$STATUS_DIR/media_metadata_audit.json" epoch
    if jq -e '(.epoch|type)=="number"' "$receipt" >/dev/null 2>&1;then
      epoch=$(jq -r .epoch "$receipt");check_age 'Media metadata audit invocation' "$epoch" "$((8*3600))"
      [[ $(jq -r '.weeklyReportStatus // "OK"' "$receipt") != FAILED ]] || finding 'Media metadata weekly reporting failed; exact pending report retained for retry'
    else finding 'Media metadata audit: valid run receipt missing';fi
    receipt="$STATUS_DIR/media_integrity_audit.json"
    if jq -e '(.stalledCompletedRuns // 0)>=3 and (.progress.capacity.attention // false)!=true' "$receipt" >/dev/null 2>&1;then finding 'Media integrity audit: three completed scans made no measurable coverage progress; review resource holds and scan budget';fi
}

audit_update_coordinator() {
    local state="${UPDATE_COORDINATOR_STATE_FILE:-/mnt/vault/cloud/logs/script/system_update_coordinator/state.json}" epoch installed
    if ! jq -e '.schema==1 and (.jobs|type)=="object" and (.installedAt|type)=="number"' "$state" >/dev/null 2>&1;then
      finding 'System update coordinator: valid journal missing; automatic-update supervision unavailable';return
    fi
    epoch=$(jq -r '.lastAutomaticRunAt // 0' "$state");installed=$(jq -r .installedAt "$state")
    if ((epoch>0));then check_age 'System update coordinator scheduled run' "$epoch" 10800
    elif ((NOW>installed+10800));then finding 'System update coordinator: first automatic run overdue; CLI inspection does not count as scheduled execution';fi
    if jq -e --argjson now "$NOW" 'any(.jobs[];.status=="ATTENTION" or (.status=="INTENT" and (.dispatchedAt // 0)<$now-1200))' "$state" >/dev/null;then
      finding 'System update coordinator: unresolved installation outcome; further updates and affected watchdog recovery held for review'
    fi
    # Only sealed report pages and urgent events are due for delivery. Normal
    # late receipts wait for the next daily summary without becoming a failure.
    if jq -e --argjson now "$NOW" '(.normalDeliveryIds // []) as $batch | any(.outbox[]; . as $event | (.at // 0)<$now-1800 and (.importance!="normal" or ($batch|index($event.id))!=null))' "$state" >/dev/null;then
      finding 'System update coordinator: action report pending delivery; exact evidence remains queued'
    fi
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
    # GNU find version is a standalone option, without a starting path.
    # shellcheck disable=SC2185
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
    for path in backup_cache_appdata backup_boot_disk backup_media_remote backup_vault_remote media_health_monitor media_cleanup docker_service_watchdog dns_redundancy_watchdog ram_logs_watchdog media_torrent_management backup_health_audit media_metadata_audit media_integrity_audit system_update_coordinator; do
        if [[ ! -f "/boot/config/plugins/user.scripts/scripts/$path/script" ]] ||
           ! grep -Fq "/scripts/$path/script" <<<"$cron"; then
            finding "Scheduling: required User Script missing or not scheduled: $path"; missing=true
        fi
    done
    [[ "$missing" != true ]] || RUNTIME_SAFE=false
}
# Only inspect metadata after the first recovery-enabled export. Old snapshots
# are not retroactively treated as broken, and this audit never wakes ISS.
audit_recovery_inventory() {
    local root="${RECOVERY_BUNDLE_ROOT:-/mnt/vault/backup/operations_state/recovery}" status volumes
    [[ -e "$root" ]] || return 0
    if [[ -L "$root" ]] || ! jq -e '.schema==1 and (.runtimeStatus|type=="string") and (.namedVolumeMounts|type=="number")' "$root/inventory.json" >/dev/null 2>&1; then
        finding 'Recovery inventory: missing or invalid metadata; previous data backups are not reclassified'; return
    fi
    status=$(jq -r .runtimeStatus "$root/inventory.json")
    volumes=$(jq -r .namedVolumeMounts "$root/inventory.json")
    [[ "$status" == complete ]] || finding "Recovery inventory: Docker capture $status; runtime reconstruction evidence incomplete"
    (( volumes==0 )) || finding "Recovery inventory: $volumes named-volume mount(s) need explicit payload-backup review"
    ACTIONS+=("Recovery inventory: runtime=$status; named-volume mounts=$volumes. Metadata read only; payload checks remain the producer/restore drill responsibility.")
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
    if [[ -f "$STATUS_DIR/backup_media_remote.json" ]] && jq -e '.copy=="OK" and .verification=="rsync_transfer_verified"' "$STATUS_DIR/backup_media_remote.json" >/dev/null; then
        copy_epoch=$(jq -r .epoch "$STATUS_DIR/backup_media_remote.json")
    else
        # Cutover compatibility: the previous successful mirror predates atomic
        # receipts. A bounded, anchored success line is legacy log evidence only.
        log=$(latest_path "$REMOTE_LOG_ROOT" f 'backup_media_remote_*.log')
        if [[ -n "$log" ]]; then
            created=$(tail -n 80 "$REMOTE_LOG_ROOT/$log" | sed -n '/Remote backup completed successfully/s/^\(.\{19\}\).*/\1/p' | tail -n 1)
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
    if [[ -f "$STATUS_DIR/backup_vault_remote.json" ]]; then
        [[ $(jq -r '.restoreDrill // "not_observed"' "$STATUS_DIR/backup_vault_remote.json") != FAILED ]] || finding 'ISS restore drill failed after a verified copy; backup retained; inspect the vault drill summary'
        epoch=$(jq -r '.restoreDrillEpoch // 0' "$STATUS_DIR/backup_vault_remote.json")
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
    audit_runtime; audit_backups; audit_recovery_inventory; audit_disk_health_monitor; audit_media_integrity_monitor; audit_media_coordination; audit_update_coordinator
    fingerprint=$(printf '%s\n' "${FINDINGS[@]}" | sort | sha256sum | awk '{print $1}')
    if [[ -f "$STATE_DIR/state.json" ]]; then
        jq -e '.fingerprint|type=="string"' "$STATE_DIR/state.json" >/dev/null || { printf 'Invalid audit state preserved.\n' >&2; return 1; }
        previous=$(jq -r .fingerprint "$STATE_DIR/state.json"); last=$(jq -r '.notifiedAt // 0' "$STATE_DIR/state.json")
        [[ "$last" =~ ^[0-9]+$ ]] || return 1
    fi
    if (( ${#FINDINGS[@]}>0 )); then status=WARNING; importance=warning; fi
    body="Backup audit: $status; Unraid $PLATFORM_VERSION; findings=${#FINDINGS[@]}."$'\n'"$(printf '%s\n' "${FINDINGS[@]}" "${ACTIONS[@]}")"$'\n''Actions: local backup evidence and host capabilities checked. No backup, remote wake, media scan, restart or cleanup was performed.'
    if [[ "$fingerprint" != "$previous" && ( -n "$previous" || "$status" != OK ) ]] || { [[ "$status" != OK ]] && (( NOW-last>=REMINDER_SECONDS )); }; then
        if [[ ! -x "$NOTIFY_BIN" ]] || ! usr_ops_notify timeout 30 "$NOTIFY_BIN" -i "$importance" -s 'Backup Health Audit' -d "Backup audit: $status" -m "$body"; then
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
