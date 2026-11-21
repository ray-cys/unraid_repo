#!/bin/bash
# Pre/Post Reboot Audit v2.0 -- report-only, event-driven Unraid inventory audit.
# Capture while the array/services are still running, BEFORE shutdown teardown.
# Compare after boot. No hooks or schedules are installed by this script.
set -uo pipefail
umask 077
readonly SCRIPT_VERSION="2.0"

###############################################################################
# CONFIGURATION
###############################################################################
# Only the durable baseline, lifecycle checkpoint and bounded log live on flash.
# Detailed comparisons/history go to vault after readiness. A failed capture
# preserves the previous baseline; compare never replaces the baseline.
STATE_ROOT="/boot/config/plugins/user.scripts/pre_post_reboot_audit"
BASELINE_DIR="$STATE_ROOT/baseline"
CHECKPOINT_FILE="$STATE_ROOT/completed.json"
DEFERRED_FILE="$STATE_ROOT/deferred.json"
BOOT_CONFIG_ROOT="/boot/config"
UNRAID_VERSION_FILE="/etc/unraid-version"
LOG_FILE="$STATE_ROOT/pre-post-reboot-audit.log"
LOG_MAX_BYTES=65536
VAULT_MOUNT="/mnt/vault"
HISTORY_DIR="/mnt/vault/cloud/logs/script/pre_post_reboot_audit/history"
REPORT_FILE="/mnt/vault/cloud/logs/script/pre_post_reboot_audit/last-compare.txt"
STATUS_DIR="/mnt/vault/cloud/logs/user_scripts_status"
MAX_HISTORY=5
WAIT_FOR_ARRAY_SECONDS=300
WAIT_INTERVAL_SECONDS=10
POST_ARRAY_SETTLE_SECONDS=30
COMMAND_TIMEOUT_SECONDS=30
CHECK_DOCKER=true
# Enable only when VM service is expected to be running before/after reboot.
CHECK_VMS=false
IGNORE_RUNNING_CONTAINERS=(kometa recyclarr)
SEND_SUCCESS_NOTIFICATION=false
NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
LOCK_FILE="/run/pre_post_reboot_audit.lock"

NOW="$(date +%s)"
RUN_STAMP="$(date '+%Y%m%d_%H%M%S')_$$"
CURRENT_BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)"
TMP_DIR=""
CRITICAL_CHANGES=0
WARNING_CHANGES=0
INFO_CHANGES=0
EXPECTED_UPGRADE=false
FORCE_COMPARE=false
RESULT_STATUS=FAILED
RESULT_SUMMARY="Audit incomplete"

log() {
    local size line
    line="$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"
    (( ${#line} <= 4096 )) || line="${line:0:4070} ... [line truncated]"
    printf '%s\n' "$line"
    size="$(stat -c %s "$LOG_FILE" 2>/dev/null || printf 0)"
    if (( size + ${#line} + 1 > LOG_MAX_BYTES )); then mv -f -- "$LOG_FILE" "$LOG_FILE.1" || return 1; fi
    printf '%s\n' "$line" >>"$LOG_FILE"
}
bounded() { timeout --signal=TERM --kill-after=5 "$COMMAND_TIMEOUT_SECONDS" "$@"; }
cleanup() { [[ -z "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"; }

bound_existing_logs() {
    local file size tmp
    for file in "$LOG_FILE" "$LOG_FILE.1"; do
        [[ -f "$file" ]] || continue
        size="$(stat -c %s "$file")" || return 1
        if (( size > LOG_MAX_BYTES )); then
            tmp="$(mktemp "$STATE_ROOT/.log-tail.XXXXXX")" || return 1
            tail -c "$LOG_MAX_BYTES" -- "$file" >"$tmp" && mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
        fi
    done
}

write_receipt() {
    local tmp
    mountpoint -q "$VAULT_MOUNT" || return 0
    mkdir -p -- "$STATUS_DIR" || return 1
    tmp="$(mktemp "$STATUS_DIR/.reboot-audit.XXXXXX")" || return 1
    jq -n --arg name pre_post_reboot_audit --arg status "$RESULT_STATUS" --arg summary "$RESULT_SUMMARY" \
        --arg version "$SCRIPT_VERSION" --arg log "$LOG_FILE" --argjson epoch "$(date +%s)" \
        '{name:$name,status:$status,summary:$summary,scriptVersion:$version,log:$log,epoch:$epoch}' >"$tmp" &&
        mv -f -- "$tmp" "$STATUS_DIR/pre_post_reboot_audit.json"
}

manifest_tree() {
    local root="$1" output="$2" file hash
    [[ -d "$root" ]] || return 1
    : >"$output"
    # Paths in the manifest are relative and deterministic. A read failure
    # aborts capture rather than producing a falsely comparable empty file.
    bounded find "$root" -type f -print0 | sort -z >"$TMP_DIR/paths" || return 1
    while IFS= read -r -d '' file; do
        hash="$(bounded sha256sum "$file")" || return 1
        printf '%s  %s\n' "${hash%% *}" "${file#"$root"/}" >>"$output"
    done <"$TMP_DIR/paths"
}

plugin_inventory() {
    local file version hash
    : >"$1"
    bounded find "$BOOT_CONFIG_ROOT/plugins" -maxdepth 1 -type f -name '*.plg' -print0 | sort -z >"$TMP_DIR/plugin-paths" || return 1
    while IFS= read -r -d '' file; do
        version="$(sed -nE 's/.*<!ENTITY[[:space:]]+version[[:space:]]+"([^"]+)".*/\1/p' "$file" | head -n 1)"
        if [[ -z "$version" ]]; then
            version="$(sed -nE 's/.*<PLUGIN[^>]*[[:space:]]version="([^"]+)".*/\1/p' "$file" | head -n 1)"
        fi
        hash="$(bounded sha256sum "$file")" || return 1
        printf '%s|%s|%s\n' "${file##*/}" "${version:-unknown}" "${hash%% *}" >>"$1"
    done <"$TMP_DIR/plugin-paths"
}

capture_inventory() {
    local dest="$1" data name digest ignored
    mkdir -p -- "$dest" || return 1
    # Require stable serial/WWN identity, never Linux enumeration names (sdX).
    data="$(bounded lsblk -J -b -d -o TYPE,SERIAL,WWN,SIZE,MODEL)" || return 1
    jq -e '[.blockdevices[] | select(.type == "disk")] | length > 0 and all(.[];
        ((.serial // "") | length) > 0 or ((.wwn // "") | length) > 0)' <<<"$data" >/dev/null || return 1
    jq -r '.blockdevices[] | select(.type == "disk") |
        [(if (.serial // "") != "" then .serial else .wwn end), .size, .model] | @tsv' <<<"$data" | sort >"$dest/block_devices" || return 1
    bounded mdcmd status >"$TMP_DIR/md-status" || return 1
    grep -q '^mdState=STARTED' "$TMP_DIR/md-status" || return 1
    awk -F= '$1 ~ /^(rdevId|diskId|diskSize)\.[0-9]+$/ {print}' "$TMP_DIR/md-status" | sort >"$dest/array_assignments"
    [[ -s "$dest/array_assignments" ]] || return 1
    manifest_tree "$BOOT_CONFIG_ROOT/shares" "$dest/shares" || return 1
    if [[ "$CHECK_DOCKER" == true ]]; then
        manifest_tree "$BOOT_CONFIG_ROOT/plugins/dockerMan/templates-user" "$dest/docker_templates" || return 1
    else printf 'DISABLED\n' >"$dest/docker_templates"; fi
    plugin_inventory "$dest/plugins" || return 1
    cut -d '|' -f1 "$dest/plugins" >"$dest/plugin_names"
    [[ -r "$UNRAID_VERSION_FILE" ]] || return 1
    { cat "$UNRAID_VERSION_FILE"; uname -r; } >"$dest/os_versions" || return 1
    if [[ "$CHECK_DOCKER" == true ]]; then
        bounded docker info >/dev/null 2>&1 || return 1
        bounded docker ps -a --format '{{.Names}}' | sort >"$TMP_DIR/container-names" || return 1
        : >"$dest/containers"; : >"$dest/images"
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            data="$(bounded docker inspect "$name")" || return 1
            jq -er '.[0] | [.Name,.Config.Image] | @tsv' <<<"$data" >>"$dest/containers" || return 1
            digest="$(jq -er '.[0].Image' <<<"$data")" || return 1
            data="$(bounded docker image inspect "$digest")" || return 1
            jq -er --arg name "$name" '.[0] | [$name,.Id,((.RepoDigests // []) | sort | join(","))] | @tsv' <<<"$data" >>"$dest/images" || return 1
        done <"$TMP_DIR/container-names"
        bounded docker ps --format '{{.Names}}' | sort >"$TMP_DIR/running" || return 1
        : >"$dest/containers_running"
        while IFS= read -r name; do
            ignored=false
            for data in "${IGNORE_RUNNING_CONTAINERS[@]}"; do [[ "$name" != "$data" ]] || ignored=true; done
            [[ "$ignored" == true ]] || printf '%s\n' "$name" >>"$dest/containers_running"
        done <"$TMP_DIR/running"
    else
        printf 'DISABLED\n' >"$dest/containers"; printf 'DISABLED\n' >"$dest/images"; printf 'DISABLED\n' >"$dest/containers_running"
    fi
    if [[ "$CHECK_VMS" == true ]]; then
        bounded virsh list --all --uuid | sed '/^$/d' | sort >"$dest/vms" || return 1
        bounded virsh list --uuid | sed '/^$/d' | sort >"$dest/vms_running" || return 1
        : >"$dest/vm_config"
        while IFS= read -r name; do
            # Inactive XML avoids volatile runtime device addresses. Canonical
            # XML is compared via a hash; libvirt-generated changes may warn.
            bounded virsh dumpxml --inactive "$name" >"$TMP_DIR/vm.xml" || return 1
            bounded xmllint --c14n "$TMP_DIR/vm.xml" >"$TMP_DIR/vm.canonical.xml" || return 1
            data="$(sha256sum "$TMP_DIR/vm.canonical.xml")" || return 1
            printf '%s|%s\n' "$name" "${data%% *}" >>"$dest/vm_config"
        done <"$dest/vms"
    else
        printf 'DISABLED\n' >"$dest/vms"; printf 'DISABLED\n' >"$dest/vms_running"; printf 'DISABLED\n' >"$dest/vm_config"
    fi
    bounded ip -j address >"$TMP_DIR/ip.json" || return 1
    # Ignore dynamic lifetimes, interface indices, link-local and temporary IPv6.
    jq -er '.[] | .ifname as $name | .addr_info[] | select(.scope == "global" and (.temporary // false | not)) |
        [$name,.family,.local,.prefixlen] | @tsv' "$TMP_DIR/ip.json" | sort >"$dest/network_addresses" || return 1
    bounded ip -j route >"$TMP_DIR/routes.json" || return 1
    jq -r '.[] | select(.protocol != "kernel" and .protocol != "ra") | [.dst,.gateway,.dev,.table] | @tsv' "$TMP_DIR/routes.json" | sort >"$dest/network_routes" || return 1
    bounded findmnt -J -l -o TARGET,SOURCE,FSTYPE,UUID >"$TMP_DIR/mounts.json" || return 1
    jq -r '.filesystems[] | select(.target | startswith("/mnt/")) |
        [.target,((.uuid // "") | if length > 0 then . else null end) // .source,.fstype] | @tsv' "$TMP_DIR/mounts.json" | sort >"$dest/mounts" || return 1
    jq -n --arg boot "$CURRENT_BOOT_ID" --argjson captured "$NOW" --argjson docker "$CHECK_DOCKER" --argjson vms "$CHECK_VMS" \
        '{version:2,boot:$boot,captured:$captured,docker:$docker,vms:$vms}' >"$dest/metadata.json" || return 1
    (cd "$dest" && sha256sum array_assignments block_devices shares docker_templates plugins plugin_names os_versions containers images containers_running vms vms_running vm_config network_addresses network_routes mounts metadata.json >inventory.sha256)
}

inventory_valid() {
    local dir="$1" expected
    jq -e '.version == 2 and (.boot | type == "string") and (.captured | type == "number")' "$dir/metadata.json" >/dev/null 2>&1 || return 1
    expected="$(awk '{print $2}' "$dir/inventory.sha256" 2>/dev/null | sort)"
    [[ "$expected" == "$(printf '%s\n' array_assignments block_devices shares docker_templates plugins plugin_names os_versions containers images containers_running vms vms_running vm_config network_addresses network_routes mounts metadata.json | sort)" ]] || return 1
    (cd "$dir" && sha256sum -c inventory.sha256 >/dev/null 2>&1)
}

ready() {
    mountpoint -q /mnt/user && mountpoint -q "$VAULT_MOUNT" || return 1
    bounded mdcmd status >"$TMP_DIR/ready-md" || return 1
    grep -q '^mdState=STARTED' "$TMP_DIR/ready-md" || return 1
    [[ "$CHECK_DOCKER" != true ]] || bounded docker info >/dev/null 2>&1 || return 1
    [[ "$CHECK_VMS" != true ]] || bounded virsh list --all >/dev/null 2>&1 || return 1
}

wait_for_readiness() {
    local deadline=$(( $(date +%s) + WAIT_FOR_ARRAY_SECONDS ))
    while :; do
        if ready; then sleep "$POST_ARRAY_SETTLE_SECONDS"; ready && return 0; fi
        (( $(date +%s) < deadline )) || return 1
        sleep "$WAIT_INTERVAL_SECONDS"
    done
}

capture_baseline() {
    local new="$STATE_ROOT/.new-baseline" old="$STATE_ROOT/.previous-baseline"
    # Recover an interrupted baseline replacement before beginning a new one.
    if [[ ! -e "$BASELINE_DIR" && -d "$old" ]]; then mv -- "$old" "$BASELINE_DIR" || return 1; fi
    [[ ! -e "$new" && ! -e "$old" ]] || { log ERROR 'Incomplete baseline transaction requires review'; return 1; }
    capture_inventory "$TMP_DIR/inventory" && inventory_valid "$TMP_DIR/inventory" || { log ERROR 'Capture incomplete; baseline preserved'; return 1; }
    cp -a -- "$TMP_DIR/inventory" "$new" || return 1
    inventory_valid "$new" || return 1
    if [[ -d "$BASELINE_DIR" ]]; then mv -- "$BASELINE_DIR" "$old" || return 1; fi
    if ! mv -- "$new" "$BASELINE_DIR"; then [[ ! -d "$old" ]] || mv -- "$old" "$BASELINE_DIR"; return 1; fi
    if [[ -d "$old" ]]; then
        if mountpoint -q "$VAULT_MOUNT"; then
            mkdir -p -- "$HISTORY_DIR" && cp -a -- "$old" "$HISTORY_DIR/baseline-$RUN_STAMP" || return 1
        fi
        rm -rf -- "$old"
    fi
    if mountpoint -q "$VAULT_MOUNT" && [[ -d "$HISTORY_DIR" ]]; then prune_history || return 1; fi
    RESULT_STATUS=OK; RESULT_SUMMARY="Baseline captured; boot=$CURRENT_BOOT_ID; source inventory verified"
    log INFO "$RESULT_SUMMARY"
}

record_difference() {
    local severity="$1" label="$2" details="$3"
    printf '\n[%s] %s\n%s\n' "$severity" "$label" "$details" >>"$TMP_DIR/report"
    case "$severity" in CRITICAL) CRITICAL_CHANGES=$((CRITICAL_CHANGES + 1));; WARNING) WARNING_CHANGES=$((WARNING_CHANGES + 1));; INFO) INFO_CHANGES=$((INFO_CHANGES + 1));; esac
}

compare_file() {
    local severity="$1" label="$2" file="$3" detail rc
    detail="$(diff -u -- "$BASELINE_DIR/$file" "$TMP_DIR/post/$file")"; rc=$?
    (( rc <= 1 )) || return 1
    [[ -z "$detail" ]] || record_difference "$severity" "$label" "$detail"
}

compare_presence() {
    local severity="$1" label="$2" file="$3" removed added
    removed="$(comm -23 "$BASELINE_DIR/$file" "$TMP_DIR/post/$file")" || return 1
    added="$(comm -13 "$BASELINE_DIR/$file" "$TMP_DIR/post/$file")" || return 1
    [[ -z "$removed" ]] || record_difference "$severity" "$label: missing baseline entries" "$removed"
    [[ -z "$added" ]] || record_difference INFO "$label: added entries" "$added"
}

prune_history() {
    local path record i=0
    while IFS= read -r -d '' record; do
        path="${record#*|}"
        i=$((i + 1))
        (( i <= MAX_HISTORY )) || rm -rf -- "$path"
    done < <(
        while IFS= read -r -d '' path; do printf '%s|%s\0' "$(stat -c %Y "$path")" "$path"; done < <(
            find "$HISTORY_DIR" -mindepth 1 -maxdepth 1 -type d \( -name 'baseline-*' -o -name 'post-boot-*' \) -print0
        ) | sort -zrn
    )
}

compare_after_reboot() {
    local baseline_boot captured checkpoint_key severity tmp description importance=normal need_notify=false
    inventory_valid "$BASELINE_DIR" || { log ERROR 'Baseline missing, legacy or invalid; capture a valid baseline first'; return 1; }
    baseline_boot="$(jq -r .boot "$BASELINE_DIR/metadata.json")"
    captured="$(jq -r .captured "$BASELINE_DIR/metadata.json")"
    checkpoint_key="$baseline_boot:$captured:$CURRENT_BOOT_ID"
    if [[ "$FORCE_COMPARE" != true && -f "$CHECKPOINT_FILE" ]] && jq -e --arg key "$checkpoint_key" '.key == $key and .delivered == true' "$CHECKPOINT_FILE" >/dev/null; then
        RESULT_STATUS="$(jq -r .status "$CHECKPOINT_FILE")"
        RESULT_SUMMARY="Comparison already completed for this baseline and boot; duplicate notification suppressed"
        log INFO "$RESULT_SUMMARY"
        return 0
    fi
    if ! wait_for_readiness; then
        RESULT_STATUS=WARNING; RESULT_SUMMARY="Audit deferred: array, vault, Docker or VM readiness incomplete; rerun compare after startup"
        log WARNING "$RESULT_SUMMARY"
        notify_deferred "$checkpoint_key" || return 1
        # No checkpoint: retry is allowed, no missing-service comparison occurs.
        return 0
    fi
    if ! capture_inventory "$TMP_DIR/post" || ! inventory_valid "$TMP_DIR/post"; then
        RESULT_STATUS=WARNING; RESULT_SUMMARY='Audit deferred: post-boot inventory incomplete; baseline retained; rerun compare'
        log WARNING "$RESULT_SUMMARY"
        notify_deferred "$checkpoint_key" || return 1
        return 0
    fi
    printf 'Pre/Post Reboot Audit v%s\nBaseline boot: %s\nCurrent boot: %s\nBaseline age: %sh\nExpected upgrade: %s\n' \
        "$SCRIPT_VERSION" "$baseline_boot" "$CURRENT_BOOT_ID" "$(((NOW - captured) / 3600))" "$EXPECTED_UPGRADE" >"$TMP_DIR/report"
    compare_file CRITICAL 'Array assignment IDs or sizes changed' array_assignments || return 1
    compare_presence CRITICAL 'Physical disks (stable identity, size, model)' block_devices || return 1
    compare_file WARNING 'Share configuration modified' shares || return 1
    compare_file WARNING 'Docker templates modified' docker_templates || return 1
    severity=WARNING; [[ "$EXPECTED_UPGRADE" != true ]] || severity=INFO
    compare_file "$severity" 'Unraid/kernel versions changed' os_versions || return 1
    compare_file "$severity" 'Plugin versions or package manifests changed' plugins || return 1
    compare_presence WARNING 'Installed plugins' plugin_names || return 1
    compare_file WARNING 'Container configuration/image references changed' containers || return 1
    compare_file "$severity" 'Docker image IDs/digests changed' images || return 1
    compare_presence WARNING 'Previously running containers' containers_running || return 1
    compare_presence WARNING 'Configured VMs (UUID)' vms || return 1
    compare_presence WARNING 'Previously running VMs' vms_running || return 1
    compare_file WARNING 'VM inactive configuration changed (canonical XML)' vm_config || return 1
    compare_file WARNING 'Global network addresses changed' network_addresses || return 1
    compare_file WARNING 'Persistent network routes changed' network_routes || return 1
    compare_file WARNING 'Storage mounts changed (UUID preferred)' mounts || return 1
    if [[ "$(jq -c '[.docker,.vms]' "$BASELINE_DIR/metadata.json")" != "$(jq -c '[.docker,.vms]' "$TMP_DIR/post/metadata.json")" ]]; then
        record_difference WARNING 'Audit coverage changed' 'Docker/VM check configuration differs from baseline; capture a new baseline after review.'
    fi
    if (( NOW - captured > 30 * 86400 )); then record_difference WARNING 'Baseline older than 30 days' 'Review whether the baseline still reflects the intended pre-reboot configuration.'; fi
    if (( CRITICAL_CHANGES > 0 )); then RESULT_STATUS=CRITICAL; importance=alert
    elif (( WARNING_CHANGES > 0 )); then RESULT_STATUS=WARNING; importance=warning
    else RESULT_STATUS=OK; fi
    RESULT_SUMMARY="critical=$CRITICAL_CHANGES; warnings=$WARNING_CHANGES; informational=$INFO_CHANGES"
    printf '\nResult: %s; %s\n' "$RESULT_STATUS" "$RESULT_SUMMARY" >>"$TMP_DIR/report"
    mkdir -p -- "$HISTORY_DIR" "${REPORT_FILE%/*}" || return 1
    cp -a -- "$TMP_DIR/post" "$HISTORY_DIR/post-boot-$RUN_STAMP" || return 1
    cp -- "$TMP_DIR/report" "$HISTORY_DIR/post-boot-$RUN_STAMP/report.txt" || return 1
    tmp="$(mktemp "${REPORT_FILE%/*}/.report.XXXXXX")" || return 1
    cp -- "$TMP_DIR/report" "$tmp" && mv -f -- "$tmp" "$REPORT_FILE" || return 1
    prune_history || return 1
    (( CRITICAL_CHANGES + WARNING_CHANGES + INFO_CHANGES == 0 )) && [[ "$SEND_SUCCESS_NOTIFICATION" != true ]] || need_notify=true
    [[ ! -e "$DEFERRED_FILE" ]] || need_notify=true
    description="Reboot audit $RESULT_STATUS"
    if [[ "$need_notify" == true ]]; then
        [[ -x "$NOTIFY_BIN" ]] && timeout 30 "$NOTIFY_BIN" -i "$importance" -s 'Pre/Post Reboot Audit' -d "$description" \
            -m "$RESULT_SUMMARY"$'\n'"$(head -c 12000 "$TMP_DIR/report")"$'\n'"Report: $REPORT_FILE" || { log ERROR 'Notification failed; comparison remains retryable'; return 1; }
    fi
    tmp="$(mktemp "$STATE_ROOT/.completed.XXXXXX")" || return 1
    jq -n --arg key "$checkpoint_key" --arg status "$RESULT_STATUS" '{key:$key,status:$status,delivered:true}' >"$tmp" && mv -f -- "$tmp" "$CHECKPOINT_FILE" || return 1
    rm -f -- "$DEFERRED_FILE"
    log INFO "$RESULT_SUMMARY"
    (( CRITICAL_CHANGES == 0 ))
}

notify_deferred() {
    local key="$1" tmp
    if [[ -f "$DEFERRED_FILE" ]] && jq -e --arg key "$key" '.key == $key' "$DEFERRED_FILE" >/dev/null 2>&1; then return 0; fi
    [[ -x "$NOTIFY_BIN" ]] && timeout 30 "$NOTIFY_BIN" -i warning -s 'Pre/Post Reboot Audit' -d 'Reboot audit DEFERRED' \
        -m "$RESULT_SUMMARY" || return 1
    tmp="$(mktemp "$STATE_ROOT/.deferred.XXXXXX")" || return 1
    jq -n --arg key "$key" '{key:$key}' >"$tmp" && mv -f -- "$tmp" "$DEFERRED_FILE"
}

main() {
    local mode="${1:-auto}" command rc=0 boot=""
    case "$mode" in
        --help|-h) printf '%s\n' 'Usage: bash pre_post_reboot_audit.sh capture|compare|auto [--expected-upgrade] [--force]' \
            'Capture BEFORE shutdown stops array/services. Compare after boot; rerun if readiness is deferred.' \
            'auto: capture only if no baseline exists; otherwise compare on a different boot.' \
            'Capture explicitly to accept a new baseline. compare never advances the baseline.' \
            '--expected-upgrade: OS/plugin/image changes informational; configuration and missing services still warn.' \
            '--force: rerun an already completed comparison. Successful audits are silent by default.' \
            'VM checks require CHECK_VMS=true, virsh and xmllint. No schedule/hooks installed.'; return 0 ;;
        --version) printf 'pre_post_reboot_audit.sh %s\n' "$SCRIPT_VERSION"; return 0 ;;
        capture|compare|auto) ;;
        *) return 2 ;;
    esac
    if (( $# > 0 )); then shift; fi
    while (( $# > 0 )); do case "$1" in --expected-upgrade) EXPECTED_UPGRADE=true;; --force) FORCE_COMPARE=true;; *) return 2;; esac; shift; done
    for command in jq flock timeout sha256sum mdcmd lsblk findmnt ip diff comm; do command -v "$command" >/dev/null || return 1; done
    if [[ "$CHECK_VMS" == true ]]; then command -v xmllint >/dev/null && command -v virsh >/dev/null || return 1; fi
    [[ "$CURRENT_BOOT_ID" != unknown && "$STATE_ROOT" == /boot/config/plugins/user.scripts/* ]] || return 1
    mountpoint -q /boot || return 1
    exec 9>"$LOCK_FILE" || return 1
    flock -n 9 || return 0
    mkdir -p -- "$STATE_ROOT" || return 1
    bound_existing_logs || return 1
    TMP_DIR="$(mktemp -d /tmp/reboot-audit.XXXXXX)" || return 1
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ "$mode" == auto ]]; then
        if [[ ! -e "$BASELINE_DIR" && ! -e "$STATE_ROOT/.previous-baseline" ]]; then mode=capture
        else
            boot="$(jq -r '.boot // "unknown"' "$BASELINE_DIR/metadata.json" 2>/dev/null || printf unknown)"
            if [[ "$boot" == "$CURRENT_BOOT_ID" ]]; then
                inventory_valid "$BASELINE_DIR" || { log ERROR 'Current-boot baseline invalid; recapture explicitly'; return 1; }
                log INFO 'Baseline already captured for this boot; preserving it'; return 0
            fi
            mode=compare
        fi
    fi
    if [[ "$mode" == capture ]]; then capture_baseline || rc=1
    else compare_after_reboot || rc=1; fi
    if (( rc != 0 )) && [[ "$RESULT_STATUS" != CRITICAL ]]; then RESULT_STATUS=FAILED; RESULT_SUMMARY='Audit incomplete; inspect bounded audit log; baseline retained'; fi
    write_receipt || rc=1
    return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
