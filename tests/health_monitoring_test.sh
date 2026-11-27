#!/bin/bash
# Fixtures source the monitor's functions and use temporary paths and mock commands.
# shellcheck disable=SC2034,SC2155
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../user_script/health_monitoring.sh
source "$REPO_ROOT/user_script/health_monitoring.sh"

readonly REGRESSION_FIXTURE_COUNT=118

self_test_result() {
    local passed="$1" name="$2" detail="${3:-}"

    SELF_TEST_TOTAL=$((SELF_TEST_TOTAL + 1))
    if (( passed == 1 )); then
        SELF_TEST_PASSED=$((SELF_TEST_PASSED + 1))
        printf '[PASS] %s\n' "$name"
    else
        SELF_TEST_FAILED=$((SELF_TEST_FAILED + 1))
        printf '[FAIL] %s%s\n' "$name" "${detail:+ - $detail}"
    fi
}

# The whole suite and its nested cases intentionally isolate fixture globals.
# shellcheck disable=SC2030,SC2031
run_regression_tests() (
    local fixture_dir="" history_file source_file chunk_file actual count
    SELF_TEST_TOTAL=0
    SELF_TEST_PASSED=0
    SELF_TEST_FAILED=0

    fixture_dir=$(mktemp -d /tmp/health_monitoring.selftest.XXXXXX) || {
        printf '[FAIL] Unable to create self-test fixture directory\n'
        return 1
    }
    trap '[[ -z "$fixture_dir" || "$fixture_dir" != /tmp/health_monitoring.selftest.* ]] || rm -rf -- "$fixture_dir"' EXIT

    printf 'Disk Health Monitor for Unraid v%s - isolated regression tests\n' \
        "$SCRIPT_VERSION"
    printf '%d fixtures are isolated under %s and removed automatically.\n\n' \
        "$REGRESSION_FIXTURE_COUNT" "$fixture_dir"

    if (
        local RUN_DIR="$fixture_dir/new-baselines" disk=/dev/sdz
        mkdir "$RUN_DIR"
        local SMART_BASELINES_FILE="$RUN_DIR/baselines.json" PREV_ATTR_FILE="$RUN_DIR/old-smart"
        local NVME_STATE_FILE="$RUN_DIR/old-nvme" CMD_TIMEOUT_LAST_FILE="$RUN_DIR/old-timeout"
        DEVICE_ID_BY_PATH=([$disk]=fixture_disk)
        DEVICE_PATH_BY_ID=([fixture_disk]=$disk)
        printf 'fixture_disk state=WARNING pending=2\n' > "$PREV_ATTR_FILE"
        printf 'fixture_disk unsafe=4 therm_t1=3\n' > "$NVME_STATE_FILE"
        printf 'fixture_disk 7\n' > "$CMD_TIMEOUT_LAST_FILE"
        load_persistent_state || exit 1
        SMART_STATE[$disk]="${PREV_ATTR["$disk|state"]}"
        CUR_ATTR["$disk|pending"]="${PREV_ATTR["$disk|pending"]}"
        persist_smart_baselines || exit 1
        PREV_ATTR=(); NVME_LAST_UNSAFE=(); CMD_TIMEOUT_LAST=(); NVME_LAST_THERM_T1=()
        printf 'fixture_disk state=OK pending=0\n' > "$PREV_ATTR_FILE"
        load_persistent_state &&
            [[ "${PREV_ATTR["$disk|pending"]}" == 2 && "${NVME_LAST_UNSAFE[$disk]}" == 4 &&
               "${NVME_LAST_THERM_T1[$disk]}" == 3 && "${CMD_TIMEOUT_LAST[$disk]}" == 7 ]] || exit 1
        printf '{"schema":2}\n' > "$SMART_BASELINES_FILE"
        ! load_persistent_state
    ); then
        self_test_result 1 "SMART baseline migration preserves stable keys and rejects incompatible JSON"
    else
        self_test_result 0 "SMART baseline migration preserves stable keys and rejects incompatible JSON"
    fi

    if (
        local COLLECTOR_EVENT_FILE="$fixture_dir/essential-write-events"
        local COLLECTOR_FAILURE_NOTIFICATIONS=0
        : > "$COLLECTOR_EVENT_FILE"
        # These fixtures replace callbacks invoked by the sourced monitor.
        # shellcheck disable=SC2329
        persist_smart_baselines() { return 1; }
        # shellcheck disable=SC2329
        save_long_last_poh() { return 0; }
        # shellcheck disable=SC2329
        save_last_test() { return 0; }
        # shellcheck disable=SC2329
        save_risk_spikes() { return 0; }
        # shellcheck disable=SC2329
        persist_new_seen() { return 0; }
        # shellcheck disable=SC2329
        persist_risk_scores() { return 0; }
        COLLECTOR_ORDER=(smart)
        COLLECTOR_STATUS=([smart]=OK)
        run_collector state "Essential state" persist_all_state
        [[ "${COLLECTOR_STATUS[state]}" == FAILED ]] && ! all_collectors_state_safe
    ); then
        self_test_result 1 "Essential baseline write failure blocks a successful completion receipt"
    else
        self_test_result 0 "Essential baseline write failure blocks a successful completion receipt"
    fi

    if (
        local RUN_DIR="$fixture_dir/old-io-events"
        mkdir "$RUN_DIR"
        local IO_ERROR_HISTORY_FILE="$RUN_DIR/history" SYSLOG_CURSOR_STATE_FILE="$RUN_DIR/cursor"
        local SYSLOG_CHUNK_FILE="$RUN_DIR/input" COLLECTOR_EVENT_FILE="$RUN_DIR/events"
        local IO_ERROR_WARN_THRESHOLD=2 IO_ERROR_CRIT_THRESHOLD=4 SYSLOG_FAST_STORAGE_OWNER=0
        local timestamp
        timestamp=$(LC_ALL=C date -d '12 hours ago' '+%b %e %T')
        printf '%s\n' "$timestamp host kernel: I/O error on dev sda, sector 1" \
            "$timestamp host kernel: I/O error on dev sda, sector 2" \
            "$timestamp host kernel: I/O error on dev sda, sector 2" \
            "$timestamp host kernel: XFS (md1p1): metadata corruption detected" > "$SYSLOG_CHUNK_FILE"
        build_new_syslog_chunk() { SYSLOG_CURSOR_MODE=cursor_continuation; }
        findmnt_bounded() { printf '/dev/md1p1 /mnt/disk1 xfs\n/dev/md2p1 /mnt/disk2 xfs\n'; }
        DEVICE_ID_BY_PATH=([/dev/sda]=fixture_sda)
        DEVICE_PATH_BY_ID=([fixture_sda]=/dev/sda)
        scan_syslog_disk_errors &&
            [[ "${FINDING_EVIDENCE['device:/dev/sda|disk_i_o_alert']:-}" == *'peak 2'* &&
               "${FINDING_SEVERITY['mount:/mnt/disk1|xfs_kernel_error']:-}" == critical &&
               -z "${FINDING_SEVERITY['mount:/mnt/disk2|xfs_kernel_error']:-}" &&
               ! -e "$SYSLOG_CURSOR_STATE_FILE" && ! -s "$IO_ERROR_HISTORY_FILE" ]]
    ); then
        self_test_result 1 "Daily scan catches an older burst and attributes XFS errors to one mount"
    else
        self_test_result 0 "Daily scan catches an older burst and attributes XFS errors to one mount"
    fi

    if (
        local BTRFS_SCRUB_STATE_DIR="$fixture_dir/scrub-state"
        local ENABLE_BTRFS_SCRUB=0 FIRST_RUN_FORCE=0
        mkdir "$BTRFS_SCRUB_STATE_DIR"
        mount() { printf '/dev/sda on /mnt/cache type btrfs (rw)\n'; }
        btrfs_df_cached() { :; }
        btrfs_bounded() { printf 'no stats available\n'; return 1; }
        btrfs_bounded_optional() { printf 'no stats available\n'; return 1; }
        local snapshot="$BTRFS_SCRUB_STATE_DIR/$(safe_state_name /mnt/cache).status"
        local old=$'Saved: original\nStatus: finished\nError summary: no errors found'
        printf '%s' "$old" > "$snapshot"
        monitor_btrfs &&
            [[ "$(<"$snapshot")" == "$old" && -z "${FRESH_FILESYSTEM[scrub:/mnt/cache]:-}" ]]
    ); then
        self_test_result 1 "Btrfs fallback leaves the last completed scrub timestamp untouched"
    else
        self_test_result 0 "Btrfs fallback leaves the last completed scrub timestamp untouched"
    fi

    if (
        local retired state_file
        for retired in capacity_history.log disk_cap_history.log heavy_writer_history.log \
            parity_progress.state poh_history.log risk_scores_history.log risk_tier_history.log \
            share_usage_history.log storage_discrepancy_streak.log tbw_daysleft_history.log; do
            for state_file in "${STATE_FILES_ALERT_RUNTIME[@]}" "${STATE_FILES_TREND_HISTORY[@]}"; do
                [[ "${state_file##*/}" != "$retired" ]] || exit 1
            done
        done
    ); then
        self_test_result 1 "The monitor no longer initializes retired report files"
    else
        self_test_result 0 "The monitor no longer initializes retired report files"
    fi

    if (
        local RUN_EPOCH=100 NVME_TEMP_WARNING=70
        local -A FRESH_SMART=([/dev/nvme9n1]=1)
        local alerts=0
        record_alert() { [[ "$1" == warning ]] && alerts=$((alerts + 1)); }
        record_temperature_approach /dev/nvme9n1 60 100 8 2 HIGH
        record_temperature_approach /dev/nvme9n1 67 99 8 2 HIGH
        record_temperature_approach /dev/nvme9n1 67 100 8 2 LOW
        record_temperature_approach /dev/nvme9n1 67 100 2 2 HIGH
        record_temperature_approach /dev/nvme9n1 70 100 8 2 HIGH
        [[ "$alerts" == 0 ]] || exit 1
        record_temperature_approach /dev/nvme9n1 67 100 8 2 HIGH
        [[ "$alerts" == 1 ]]
    ); then
        self_test_result 1 "Temperature trend alerts require a fresh fast rise near the warning limit"
    else
        self_test_result 0 "Temperature trend alerts require a fresh fast rise near the warning limit"
    fi

    if (
        local HEALTH_ALERTS_SECTION="" NOTIFICATION_RECOVERY_SECTION="Recovered: cache temperature"
        local STORAGE_TOP_LINES="Pool usage context"
        compose_notification && [[ "$NOTIFY_BODY" == "$NOTIFICATION_RECOVERY_SECTION" ]]
    ); then
        self_test_result 1 "Recovery-only emails omit routine storage totals"
    else
        self_test_result 0 "Recovery-only emails omit routine storage totals"
    fi

    local topology_fixture="$fixture_dir/disks.ini" parity_fixture="$fixture_dir/parity-checks.log"
    printf '%s\n' '["disk1"]' 'type="Data"' 'status="DISK_OK"' 'device="sda"' 'fsType="xfs"' \
        '["disk2"]' 'type="Data"' 'status="DISK_NP"' 'device=""' 'idSb=""' \
        '["vault2"]' 'type="Cache"' 'status="DISK_DSBL"' 'device=""' 'idSb="assigned"' > "$topology_fixture"
    if [[ "$(unraid_assigned_slots "$topology_fixture")" == $'disk1|Data|DISK_OK|sda|xfs\nvault2|Cache|DISK_DSBL||' ]]; then
        self_test_result 1 "Quoted Unraid slots preserve missing assigned members and exclude unused slots"
    else
        self_test_result 0 "Quoted Unraid slots preserve missing assigned members and exclude unused slots"
    fi
    if (
        # shellcheck disable=SC2329
        log() { :; }
        printf '%s\n' '2026 Nov 21 00:00:00|100|200|0|12|check P|400' \
            '2026 Nov 22 00:00:00|10|0|-4|0|check P|400' > "$parity_fixture"
        check_completed_parity "$parity_fixture" &&
            [[ "${FINDING_SEVERITY['global|completed_parity_check']:-}" == critical ]] &&
            (( PARITY_HISTORY_OBSERVED == 1 ))
    ); then
        self_test_result 1 "Completed parity errors survive a newer cancelled check"
    else
        self_test_result 0 "Completed parity errors survive a newer cancelled check"
    fi
    if (
        local fixture_id='device:/dev/sda|pending_sectors'
        NOTIFY_PREV_DEVICE_ID[$fixture_id]=fixture-disk
        FRESH_SMART[/dev/sda]=1
        ! finding_has_fresh_recovery_evidence "$fixture_id" || exit 1
        DEVICE_PATH_BY_ID[fixture-disk]=/dev/sdb
        ! finding_has_fresh_recovery_evidence "$fixture_id" || exit 1
        FRESH_SMART[/dev/sdb]=1
        finding_has_fresh_recovery_evidence "$fixture_id" || exit 1
        local -A NOTIFY_CURRENT_FINGERPRINT=(['device:/dev/sdb|pending_sectors']=active)
        ! finding_has_fresh_recovery_evidence "$fixture_id"
    ); then
        self_test_result 1 "Recovery requires fresh evidence from the original disk after device renumbering"
    else
        self_test_result 0 "Recovery requires fresh evidence from the original disk after device renumbering"
    fi
    if (
        local MONITOR_RECEIPT_FILE="$fixture_dir/monitor-receipt.json"
        local RUN_EPOCH=100 MONITOR_LAST_COMPLETE_EPOCH=90
        write_monitor_receipt running 0 &&
            [[ "$(<"$MONITOR_RECEIPT_FILE")" == *'"lastCompleteEpoch":90'* ]] &&
        write_monitor_receipt incomplete 1 &&
            [[ "$(<"$MONITOR_RECEIPT_FILE")" == *'"lastCompleteEpoch":90'* ]] &&
        write_monitor_receipt complete 0 &&
            [[ "$(<"$MONITOR_RECEIPT_FILE")" != *'"lastCompleteEpoch":90'* ]]
    ); then
        self_test_result 1 "Receipt keeps last completed run across start and failure"
    else
        self_test_result 0 "Receipt keeps last completed run across start and failure"
    fi

    actual=$(safe_state_name '/dev/disk/by-id/ata-Test Drive')
    if [[ "$actual" == "disk_by-id_ata-Test_Drive" ]]; then
        self_test_result 1 "Stable state filename sanitization"
    else
        self_test_result 0 "Stable state filename sanitization" "found '$actual'"
    fi

    if declare -F load_builtin_defaults >/dev/null 2>&1 &&
       [[ "$SCRIPT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ &&
          "$STATE_SCHEMA_VERSION" == "2" &&
          "$HISTORY_SCHEMA_VERSION" == "3" &&
          "$DEVICE_ID_SCHEMA_VERSION" == "2" &&
          "$SMART_ALLOW_SPINUP" == "0" &&
          "$NOTIFICATION_OK_REMINDER_HOURS" == "0" &&
          "$NOTIFICATION_RECOVERY_CONFIRM_RUNS" == "2" &&
          "$HEAVY_WRITER_RECENT_DAYS" == "3" ]]
    then
        self_test_result 1 "Built-in defaults and schema constants"
    else
        self_test_result 0 "Built-in defaults and schema constants"
    fi

    if [[ "$EXTERNAL_CONFIG_FILE" == "$STATE_DIR/health_monitoring.conf" &&
          "$LEGACY_EXTERNAL_CONFIG_FILE" == "$LOG_DIR/health_monitoring.conf" &&
          "$EXTERNAL_CONFIG_FILE" != "$LEGACY_EXTERNAL_CONFIG_FILE" ]]
    then
        self_test_result 1 "External configuration uses private state directory"
    else
        self_test_result 0 "External configuration uses private state directory" \
            "active=$EXTERNAL_CONFIG_FILE legacy=$LEGACY_EXTERNAL_CONFIG_FILE"
    fi

    if validate_secure_absolute_path "$fixture_dir/safe/state" &&
       ! validate_secure_absolute_path '/tmp/../etc/state' &&
       ! validate_secure_absolute_path '/tmp//state' &&
       ! validate_secure_absolute_path $'/tmp/state\nunsafe'
    then
        self_test_result 1 "Secure absolute-path lexical validation"
    else
        self_test_result 0 "Secure absolute-path lexical validation" \
            "$PATH_VALIDATION_REASON"
    fi

    local path_real="$fixture_dir/path-real" path_link="$fixture_dir/path-link"
    mkdir -p "$path_real"
    ln -s "$path_real" "$path_link"
    if validate_symlink_free_path "$path_real/state" &&
       ! validate_symlink_free_path "$path_link/state"
    then
        self_test_result 1 "Symbolic-link path component rejection"
    else
        self_test_result 0 "Symbolic-link path component rejection" \
            "$PATH_VALIDATION_REASON"
    fi

    local exclusive_root="$fixture_dir/exclusive-mnt"
    local exclusive_target="$exclusive_root/vault/cloud"
    mkdir -p "$exclusive_root/user" "$exclusive_target/logs/disk_health"
    ln -s "$exclusive_target" "$exclusive_root/user/cloud"
    if resolve_unraid_exclusive_share_path \
           "$exclusive_root/user/cloud/logs/disk_health" \
           "$exclusive_root/user" "$exclusive_root" &&
       [[ "$UNRAID_EXCLUSIVE_PATH_STATUS" == "RESOLVED" &&
          "$UNRAID_EXCLUSIVE_PATH_RESULT" == \
          "$exclusive_target/logs/disk_health" ]]
    then
        self_test_result 1 "Constrained Unraid exclusive-share resolution"
    else
        self_test_result 0 "Constrained Unraid exclusive-share resolution" \
            "$UNRAID_EXCLUSIVE_PATH_REASON"
    fi

    mkdir -p "$exclusive_root/vault/other"
    ln -s "$exclusive_root/vault/other" "$exclusive_root/user/mismatch"
    if ! resolve_unraid_exclusive_share_path \
           "$exclusive_root/user/mismatch/logs" \
           "$exclusive_root/user" "$exclusive_root" &&
       [[ "$UNRAID_EXCLUSIVE_PATH_REASON" == \
          *"does not target the same share"* ]]
    then
        self_test_result 1 "Mismatched exclusive-share redirect rejection"
    else
        self_test_result 0 "Mismatched exclusive-share redirect rejection" \
            "$UNRAID_EXCLUSIVE_PATH_REASON"
    fi

    SMART_DEFERRED=()
    DISCOVERED_DISKS=()
    declare -A RISK_MAP=()
    if (( ${#SMART_DEFERRED[@]} == 0 &&
          ${#DISCOVERED_DISKS[@]} == 0 &&
          ${#RISK_MAP[@]} == 0 ))
    then
        self_test_result 1 "Empty global arrays remain safe under nounset"
    else
        self_test_result 0 "Empty global arrays remain safe under nounset"
    fi

    local schema_dir="$fixture_dir/schema" current_manifest future_manifest malformed_manifest
    mkdir -p "$schema_dir"
    current_manifest="$schema_dir/current.manifest"
    printf 'format=%s\nstate_schema=2\nhistory_schema=3\nidentity_schema=2\nwriter_version=%s\nupdated_epoch=1\n' \
        "$STATE_SCHEMA_FORMAT" "$SCRIPT_VERSION" > "$current_manifest"
    if inspect_state_schema_manifest "$current_manifest" &&
       [[ "$STATE_SCHEMA_STATUS" == "CURRENT" &&
          "$(state_manifest_value "$current_manifest" identity_schema)" == "2" ]]
    then
        self_test_result 1 "Current state-schema manifest parsing"
    else
        self_test_result 0 "Current state-schema manifest parsing" \
            "$STATE_SCHEMA_STATUS: $STATE_SCHEMA_DETAIL"
    fi

    future_manifest="$schema_dir/future.manifest"
    printf 'format=%s\nstate_schema=3\nhistory_schema=3\nidentity_schema=2\nwriter_version=future\nupdated_epoch=1\n' \
        "$STATE_SCHEMA_FORMAT" > "$future_manifest"
    local future_rc=0
    if inspect_state_schema_manifest "$future_manifest"; then
        future_rc=0
    else
        future_rc=$?
    fi
    if [[ "$future_rc" == "30" && "$STATE_SCHEMA_STATUS" == "FUTURE" ]]; then
        self_test_result 1 "Future state-schema refusal"
    else
        self_test_result 0 "Future state-schema refusal" \
            "rc=$future_rc status=$STATE_SCHEMA_STATUS"
    fi

    malformed_manifest="$schema_dir/malformed.manifest"
    printf 'format=%s\nstate_schema=1\nstate_schema=1\nhistory_schema=3\nidentity_schema=2\n' \
        "$STATE_SCHEMA_FORMAT" > "$malformed_manifest"
    local malformed_rc=0
    if inspect_state_schema_manifest "$malformed_manifest"; then
        malformed_rc=0
    else
        malformed_rc=$?
    fi
    if [[ "$malformed_rc" == "20" && "$STATE_SCHEMA_STATUS" == "INVALID" ]]; then
        self_test_result 1 "Malformed state-schema manifest rejection"
    else
        self_test_result 0 "Malformed state-schema manifest rejection" \
            "rc=$malformed_rc status=$STATE_SCHEMA_STATUS"
    fi

    STATE_SCHEMA_MANIFEST_FILE="$schema_dir/generated.manifest"
    DEVICE_ID_SCHEMA_FILE="$schema_dir/device_identity_schema.version"
    printf '%s\n' "$DEVICE_ID_SCHEMA_VERSION" > "$DEVICE_ID_SCHEMA_FILE"
    if ensure_state_schema_manifest &&
       inspect_state_schema_manifest "$STATE_SCHEMA_MANIFEST_FILE" &&
       [[ "$(state_manifest_value "$STATE_SCHEMA_MANIFEST_FILE" identity_schema)" == \
          "$DEVICE_ID_SCHEMA_VERSION" ]]
    then
        self_test_result 1 "Atomic state-schema manifest initialization"
    else
        self_test_result 0 "Atomic state-schema manifest initialization" \
            "$STATE_SCHEMA_STATUS: $STATE_SCHEMA_DETAIL"
    fi

    local atomic_victim="$schema_dir/victim.state" atomic_link="$schema_dir/link.state"
    printf 'known-good\n' > "$atomic_victim"
    ln -s "$atomic_victim" "$atomic_link"
    if ! atomic_write_text "$atomic_link" $'replacement\n' &&
       [[ "$(<"$atomic_victim")" == "known-good" ]]
    then
        self_test_result 1 "Atomic write rejects symbolic-link targets"
    else
        self_test_result 0 "Atomic write rejects symbolic-link targets"
    fi

    if [[ -n "${EXTERNAL_CONFIG_ALLOWED[SMART_ALLOW_SPINUP]+present}" &&
          -n "${EXTERNAL_CONFIG_ALLOWED[HISTORY_WINDOW_DAYS]+present}" &&
          -z "${EXTERNAL_CONFIG_ALLOWED[TREND_NOTIFICATION_MODE]+present}" &&
          -z "${EXTERNAL_CONFIG_ALLOWED[TREND_NOTIFICATION_TOP_N]+present}" &&
          -n "${EXTERNAL_CONFIG_ALLOWED[HEAVY_WRITER_RECENT_DAYS]+present}" &&
          -n "${EXTERNAL_CONFIG_ALLOWED[NOTIFICATION_RECOVERY_CONFIRM_RUNS]+present}" &&
          -n "${EXTERNAL_CONFIG_ALLOWED[POOL_EXCLUDES]+present}" &&
          -n "${EXTERNAL_CONFIG_ALLOWED[LOG_DIR]+present}" &&
          -z "${EXTERNAL_CONFIG_ALLOWED[SCRIPT_VERSION]+present}" ]]
    then
        self_test_result 1 "Derived external-configuration setting allowlist"
    else
        self_test_result 0 "Derived external-configuration setting allowlist"
    fi

    local legacy_config_dir="$fixture_dir/legacy-shared-config"
    local private_config_dir="$fixture_dir/private-state-config"
    mkdir -p "$legacy_config_dir" "$private_config_dir"
    chmod 2775 "$legacy_config_dir"
    chmod 700 "$private_config_dir"
    LEGACY_EXTERNAL_CONFIG_FILE="$legacy_config_dir/health_monitoring.conf"
    # These fixture-only mutations are isolated by run_regression_tests().
    # shellcheck disable=SC2030
    EXTERNAL_CONFIG_FILE="$private_config_dir/health_monitoring.conf"
    printf 'SMART_ALLOW_SPINUP=1\n' > "$LEGACY_EXTERNAL_CONFIG_FILE"
    # shellcheck disable=SC2030
    SMART_ALLOW_SPINUP=0
    if load_external_configuration &&
       [[ "$EXTERNAL_CONFIG_STATUS" == "ABSENT" &&
          "$EXTERNAL_CONFIG_LOAD_FAILED" == "0" &&
          "$EXTERNAL_CONFIG_OVERRIDE_COUNT" == "0" &&
          "$SMART_ALLOW_SPINUP" == "0" ]]
    then
        self_test_result 1 "Legacy shared-directory configuration is safely ignored"
    else
        self_test_result 0 "Legacy shared-directory configuration is safely ignored" \
            "$EXTERNAL_CONFIG_STATUS: $EXTERNAL_CONFIG_DETAIL"
    fi

    local fixture_real
    fixture_real=$(cd "$fixture_dir" && pwd -P)
    local config_repair_state="$fixture_real/config-repair-state"
    STATE_DIR="$config_repair_state"
    EXTERNAL_CONFIG_FILE="$STATE_DIR/health_monitoring.conf"
    mkdir -p "$STATE_DIR"
    printf 'SMART_ALLOW_SPINUP=0\n' > "$EXTERNAL_CONFIG_FILE"
    chmod 2775 "$STATE_DIR"
    chmod 0664 "$EXTERNAL_CONFIG_FILE"
    if (( EUID == 0 )); then
        chown 99 -- "$STATE_DIR" "$EXTERNAL_CONFIG_FILE"
    fi
    if harden_existing_external_config_path &&
       validate_secure_owned_directory "$STATE_DIR" &&
       validate_secure_owned_file "$EXTERNAL_CONFIG_FILE"
    then
        self_test_result 1 "Existing Unraid state configuration ownership repair"
    else
        self_test_result 0 "Existing Unraid state configuration ownership repair" \
            "$PATH_VALIDATION_REASON"
    fi

    local config_link_real="$fixture_real/config-link-real"
    local config_link_state="$fixture_real/config-link-state"
    mkdir -p "$config_link_real"
    ln -s "$config_link_real" "$config_link_state"
    STATE_DIR="$config_link_state"
    EXTERNAL_CONFIG_FILE="$STATE_DIR/health_monitoring.conf"
    if ! harden_existing_external_config_path &&
       [[ "$PATH_VALIDATION_REASON" == *"symbolic-link component"* ]]
    then
        self_test_result 1 "External configuration state-link rejection"
    else
        self_test_result 0 "External configuration state-link rejection" \
            "$PATH_VALIDATION_REASON"
    fi

    local config_fixture_dir="$fixture_dir/external-config" inert_config_value
    mkdir -p "$config_fixture_dir"
    chmod 700 "$config_fixture_dir"
    # These fixture-only mutations are isolated by run_regression_tests().
    # shellcheck disable=SC2030
    EXTERNAL_CONFIG_FILE="$config_fixture_dir/health_monitoring.conf"
    printf '%s\n' \
        'SMART_ALLOW_SPINUP=1' \
        'WARN_THRESHOLD_PERCENT=95' \
        'TEMP_RATE_ALERT_ENABLED=1' \
        'HISTORY_WINDOW_DAYS=20' \
        'POOL_EXCLUDES=ramtmp, user0' > "$EXTERNAL_CONFIG_FILE"
    # This is deliberately inert parser input, not a command to expand here.
    # shellcheck disable=SC2016
    printf -v inert_config_value '$(touch %s/executed)' "$config_fixture_dir"
    printf 'IO_ERROR_LOG_FILE=%s\n' "$inert_config_value" >> "$EXTERNAL_CONFIG_FILE"
    chmod 600 "$EXTERNAL_CONFIG_FILE"
    # shellcheck disable=SC2030
    SMART_ALLOW_SPINUP=0
    WARN_THRESHOLD_PERCENT=96
    TEMP_RATE_ALERT_ENABLED=0
    HISTORY_WINDOW_DAYS=14
    POOL_EXCLUDES=(original)
    if load_external_configuration &&
       [[ "$EXTERNAL_CONFIG_STATUS" == "LOADED" &&
          "$EXTERNAL_CONFIG_OVERRIDE_COUNT" == "6" &&
          "$SMART_ALLOW_SPINUP" == "1" &&
          "$WARN_THRESHOLD_PERCENT" == "95" &&
          "$TEMP_RATE_ALERT_ENABLED" == "1" &&
          "$HISTORY_WINDOW_DAYS" == "20" &&
          "${POOL_EXCLUDES[*]}" == "ramtmp user0" &&
          "$IO_ERROR_LOG_FILE" == "$inert_config_value" &&
          ! -e "$config_fixture_dir/executed" ]]
    then
        self_test_result 1 "Transactional external configuration overrides"
    else
        self_test_result 0 "Transactional external configuration overrides" \
            "$EXTERNAL_CONFIG_STATUS: $EXTERNAL_CONFIG_DETAIL"
    fi

    printf '%s\n' \
        'SMART_ALLOW_SPINUP=0' \
        'LOG_DIR=/tmp/redirected' \
        'UNKNOWN_PHASE12_SETTING=1' > "$EXTERNAL_CONFIG_FILE"
    chmod 600 "$EXTERNAL_CONFIG_FILE"
    SMART_ALLOW_SPINUP=1
    if ! load_external_configuration &&
       [[ "$EXTERNAL_CONFIG_STATUS" == "INVALID" &&
          "$SMART_ALLOW_SPINUP" == "1" &&
          "$EXTERNAL_CONFIG_OVERRIDE_COUNT" == "0" ]]
    then
        self_test_result 1 "Invalid configuration rejects all partial overrides"
    else
        self_test_result 0 "Invalid configuration rejects all partial overrides" \
            "$EXTERNAL_CONFIG_STATUS: spinup=$SMART_ALLOW_SPINUP"
    fi

    printf '%s\n' 'SMART_ALLOW_SPINUP=0' > "$EXTERNAL_CONFIG_FILE"
    chmod 644 "$EXTERNAL_CONFIG_FILE"
    if ! load_external_configuration &&
       [[ "$EXTERNAL_CONFIG_STATUS" == "UNSAFE" &&
          "$EXTERNAL_CONFIG_DETAIL" == *"accessible by group or others"* ]]
    then
        self_test_result 1 "Insecure external configuration permission rejection"
    else
        self_test_result 0 "Insecure external configuration permission rejection" \
            "$EXTERNAL_CONFIG_STATUS: $EXTERNAL_CONFIG_DETAIL"
    fi

    EXTERNAL_CONFIG_FILE="$config_fixture_dir/generated.conf"
    if ensure_external_config_template &&
       [[ -f "$EXTERNAL_CONFIG_FILE" && ! -L "$EXTERNAL_CONFIG_FILE" &&
          "$(stat -c '%a' "$EXTERNAL_CONFIG_FILE")" == "600" ]] &&
       grep -Fq 'parsed as data, not sourced' "$EXTERNAL_CONFIG_FILE" &&
       grep -Fq '# HISTORY_WINDOW_DAYS=14' "$EXTERNAL_CONFIG_FILE" &&
       ! grep -Eq '^# (TREND_NOTIFICATION_MODE|SHOW_STORAGE_DEVICE_DETAILS)=' "$EXTERNAL_CONFIG_FILE" &&
       grep -Fq '# POOL_EXCLUDES=ramtmp,user0' "$EXTERNAL_CONFIG_FILE"
    then
        self_test_result 1 "Protected state-directory configuration template"
    else
        self_test_result 0 "Protected state-directory configuration template"
    fi

    local hardlink_source="$config_fixture_dir/hardlink-source"
    local hardlink_alias="$config_fixture_dir/hardlink-alias"
    printf 'fixture\n' > "$hardlink_source"
    chmod 600 "$hardlink_source"
    ln "$hardlink_source" "$hardlink_alias"
    if ! validate_secure_owned_file "$hardlink_source" &&
       [[ "$PATH_VALIDATION_REASON" == *"hard links"* ]]
    then
        self_test_result 1 "Managed-file hard-link rejection"
    else
        self_test_result 0 "Managed-file hard-link rejection" \
            "$PATH_VALIDATION_REASON"
    fi

    local lock_fixture_dir="$fixture_dir/secure-lock"
    local lock_fixture_passed=0
    mkdir -p "$lock_fixture_dir"
    chmod 700 "$lock_fixture_dir"
    LOCK_FILE="$lock_fixture_dir/health_monitoring.lock"
    if acquire_lock; then
        if ! flock -n "$LOCK_FILE" true 2>/dev/null; then
            lock_fixture_passed=1
        fi
        flock -u 9 || true
        exec 9>&-
    fi
    if (( lock_fixture_passed == 1 )) &&
       [[ "$(stat -c '%a' "$LOCK_FILE")" == "600" ]]
    then
        self_test_result 1 "Secure lock creation and contention"
    else
        self_test_result 0 "Secure lock creation and contention"
    fi

    local migration_dir="$fixture_dir/state-migration"
    local migration_backup_id backup_output backup_count
    STATE_DIR="$migration_dir/state"
    STATE_BACKUP_DIR="$STATE_DIR/backups"
    EXTERNAL_CONFIG_FILE="$STATE_DIR/health_monitoring.conf"
    STATE_SCHEMA_MANIFEST_FILE="$STATE_DIR/state_schema.manifest"
    DEVICE_ID_SCHEMA_FILE="$STATE_DIR/device_identity_schema.version"
    mkdir -p "$STATE_BACKUP_DIR"
    chmod 700 "$STATE_DIR" "$STATE_BACKUP_DIR"
    printf 'known-v1-state\n' > "$STATE_DIR/known.state"
    chmod 600 "$STATE_DIR/known.state"
    printf '%s\n' "$DEVICE_ID_SCHEMA_VERSION" > "$DEVICE_ID_SCHEMA_FILE"
    chmod 600 "$DEVICE_ID_SCHEMA_FILE"
    printf 'format=%s\nstate_schema=1\nhistory_schema=3\nidentity_schema=2\nwriter_version=2.14\nupdated_epoch=1\n' \
        "$STATE_SCHEMA_FORMAT" > "$STATE_SCHEMA_MANIFEST_FILE"
    chmod 600 "$STATE_SCHEMA_MANIFEST_FILE"
    RUN_EPOCH=1787200000
    if ensure_state_schema_manifest; then
        migration_backup_id="$STATE_BACKUP_RESULT_ID"
    else
        migration_backup_id=""
    fi
    if validate_state_backup_id "$migration_backup_id" &&
       [[ "$(state_manifest_value "$STATE_SCHEMA_MANIFEST_FILE" state_schema)" == "2" &&
          "$(<"$STATE_BACKUP_DIR/$migration_backup_id/state/known.state")" == \
          "known-v1-state" ]]
    then
        self_test_result 1 "Schema-v1 migration with pre-migration backup"
    else
        self_test_result 0 "Schema-v1 migration with pre-migration backup" \
            "backup=$migration_backup_id status=$STATE_SCHEMA_STATUS"
    fi

    backup_output="$(list_state_backups)"
    if [[ "$backup_output" == *"$migration_backup_id"* &&
          "$backup_output" == *"reason=migration-v1-to-v2"* &&
          "$(backup_metadata_value \
              "$STATE_BACKUP_DIR/$migration_backup_id/backup.meta" \
              source_state_schema)" == "1" ]]
    then
        self_test_result 1 "State backup metadata and deterministic listing"
    else
        self_test_result 0 "State backup metadata and deterministic listing"
    fi

    printf 'modified-v2-state\n' > "$STATE_DIR/known.state"
    printf 'SMART_ALLOW_SPINUP=1\n' > "$EXTERNAL_CONFIG_FILE"
    chmod 600 "$EXTERNAL_CONFIG_FILE"
    if rollback_state_backup "$migration_backup_id" > "$migration_dir/rollback.out" &&
       [[ "$(<"$STATE_DIR/known.state")" == "known-v1-state" &&
          "$(state_manifest_value "$STATE_SCHEMA_MANIFEST_FILE" state_schema)" == "1" &&
          ! -e "$EXTERNAL_CONFIG_FILE" ]]
    then
        backup_count="$(find "$STATE_BACKUP_DIR" -mindepth 1 -maxdepth 1 \
            -type d ! -name '.*' -print | awk 'END {print NR+0}')"
        if [[ "$backup_count" == "2" ]]; then
            self_test_result 1 "Explicit rollback with pre-rollback safety backup"
        else
            self_test_result 0 "Explicit rollback with pre-rollback safety backup" \
                "backup_count=$backup_count"
        fi
    else
        self_test_result 0 "Explicit rollback with pre-rollback safety backup"
    fi

    backup_count="$(find "$STATE_BACKUP_DIR" -mindepth 1 -maxdepth 1 \
        -type d ! -name '.*' -print | awk 'END {print NR+0}')"
    if ! rollback_state_backup '../invalid' >/dev/null 2>&1 &&
       ! rollback_state_backup 'missing-valid-backup' >/dev/null 2>&1 &&
       [[ "$(find "$STATE_BACKUP_DIR" -mindepth 1 -maxdepth 1 \
           -type d ! -name '.*' -print | awk 'END {print NR+0}')" == "$backup_count" ]]
    then
        self_test_result 1 "Rollback invalid/missing backup rejection without side effects"
    else
        self_test_result 0 "Rollback invalid/missing backup rejection without side effects"
    fi

    SMART_ALLOW_SPINUP=0
    WARN_THRESHOLD_PERCENT=96
    TEMP_RATE_ALERT_ENABLED=0
    POOL_EXCLUDES=(ramtmp user0)
    IO_ERROR_LOG_FILE=""
    EXTERNAL_CONFIG_LOAD_FAILED=0
    # shellcheck disable=SC2030
    EXTERNAL_CONFIG_STATUS="ABSENT"
    EXTERNAL_CONFIG_DETAIL="using built-in defaults"

    actual=$(history_field_value 'temp=31 captured_epoch=1786800000 schema=3' temp 2>/dev/null || true)
    if [[ "$actual" == "31" ]]; then
        self_test_result 1 "Normalized history field parsing"
    else
        self_test_result 0 "Normalized history field parsing" "found '$actual'"
    fi

    actual=$(history_record_epoch '2026-08-16' 'temp=31 captured_epoch=1786800000 schema=3' 2>/dev/null || true)
    if [[ "$actual" == "1786800000" ]]; then
        self_test_result 1 "Captured history timestamp parsing"
    else
        self_test_result 0 "Captured history timestamp parsing" "found '$actual'"
    fi

    local confidence_cases=(
        '2 10 0 1|INSUFFICIENT'
        '3 2 4 1|STALE'
        '3 2 0 15|LOW'
        '3 2 0 1|MEDIUM'
        '7 7 0 1|HIGH'
    ) case_data expected
    local confidence_failures=0
    local -a confidence_args=()
    for case_data in "${confidence_cases[@]}"; do
        expected="${case_data#*|}"
        read -r -a confidence_args <<< "${case_data%%|*}"
        actual=$(forecast_confidence "${confidence_args[@]}")
        [[ "$actual" == "$expected" ]] || confidence_failures=$((confidence_failures + 1))
    done
    if (( confidence_failures == 0 )); then
        self_test_result 1 "Forecast confidence classification"
    else
        self_test_result 0 "Forecast confidence classification" "$confidence_failures case(s) failed"
    fi

    if forecast_confidence_is_actionable MEDIUM &&
       forecast_confidence_is_actionable HIGH &&
       ! forecast_confidence_is_actionable LOW
    then
        self_test_result 1 "Forecast actionability gate"
    else
        self_test_result 0 "Forecast actionability gate"
    fi

    actual="$(forecast_confidence_description HIGH)|$(forecast_confidence_description MEDIUM)|$(forecast_confidence_description RESET)"
    if [[ "$actual" == \
          'high forecast confidence|medium forecast confidence|counter reset detected; forecast rebuilding' ]]
    then
        self_test_result 1 "Human-readable forecast confidence descriptions"
    else
        self_test_result 0 "Human-readable forecast confidence descriptions" \
            "found '$actual'"
    fi

    actual="$(format_bytes_per_day 1230000000)"
    if [[ "$actual" == '1.23 GB/day' ]]; then
        self_test_result 1 "Explicit daily byte-rate units"
    else
        self_test_result 0 "Explicit daily byte-rate units" "found '$actual'"
    fi

    local writer_base_epoch=1787000000 writer_day=86400
    local writer_sequence writer_recent_rate writer_previous_rate
    writer_sequence=$(printf '%s\n' \
        "$writer_base_epoch 0" \
        "$((writer_base_epoch + writer_day)) 100" \
        "$((writer_base_epoch + writer_day * 2)) 200" \
        "$((writer_base_epoch + writer_day * 3)) 300" \
        "$((writer_base_epoch + writer_day * 4)) 340" \
        "$((writer_base_epoch + writer_day * 5)) 380" \
        "$((writer_base_epoch + writer_day * 6)) 420")
    if calculate_counter_window_rate "$writer_sequence" \
        "$((writer_base_epoch + writer_day * 3))" \
        "$((writer_base_epoch + writer_day * 6))" 2
    then
        writer_recent_rate="$COUNTER_WINDOW_RATE"
    else
        writer_recent_rate="invalid"
    fi
    if calculate_counter_window_rate "$writer_sequence" \
        "$writer_base_epoch" "$((writer_base_epoch + writer_day * 3))" 2
    then
        writer_previous_rate="$COUNTER_WINDOW_RATE"
    else
        writer_previous_rate="invalid"
    fi
    if [[ "$writer_recent_rate" == "40" && "$writer_previous_rate" == "100" ]]
    then
        self_test_result 1 "Separate recent and previous writer-rate windows"
    else
        self_test_result 0 "Separate recent and previous writer-rate windows" \
            "recent=$writer_recent_rate previous=$writer_previous_rate"
    fi

    classify_writer_direction "$writer_recent_rate" "$writer_previous_rate" 20
    if [[ "$WRITER_DIRECTION_RESULT" == "IMPROVING" &&
          "$WRITER_CHANGE_RESULT" == "-60.0" ]]
    then
        self_test_result 1 "Writer-rate improvement classification"
    else
        self_test_result 0 "Writer-rate improvement classification" \
            "direction=$WRITER_DIRECTION_RESULT change=$WRITER_CHANGE_RESULT"
    fi

    writer_sequence+=$'\n'"$((writer_base_epoch + writer_day * 7)) 10"
    if ! calculate_counter_window_rate "$writer_sequence" \
        "$((writer_base_epoch + writer_day * 4))" \
        "$((writer_base_epoch + writer_day * 7))" 2
    then
        self_test_result 1 "Writer-rate counter reset rejection"
    else
        self_test_result 0 "Writer-rate counter reset rejection" \
            "unexpected rate=$COUNTER_WINDOW_RATE"
    fi

    if (
        local alerts=0
        record_alert() { alerts=$((alerts+1)); }
        lsblk_rota_cached() { printf '1\n'; }
        TEMP_RATE_ALERT_ENABLED=1; HDD_TEMP_WARNING=45
        RUN_EPOCH=123456; FRESH_SMART[/dev/sdz]=1
        record_temperature_approach /dev/sdz 30 "$RUN_EPOCH" 10 2 HIGH
        (( alerts==0 ))
    ); then
        self_test_result 1 "Cool drives do not raise temperature-rate warnings"
    else
        self_test_result 0 "Cool drives do not raise temperature-rate warnings"
    fi
    if (
        local alerts=0
        record_alert() { alerts=$((alerts+1)); }
        lsblk_rota_cached() { printf '1\n'; }
        TEMP_RATE_ALERT_ENABLED=1; HDD_TEMP_WARNING=45
        RUN_EPOCH=123456; FRESH_SMART[/dev/sdz]=1
        record_temperature_approach /dev/sdz 42 "$RUN_EPOCH" 10 2 HIGH
        (( alerts==1 ))
    ); then
        self_test_result 1 "Fresh hot drives retain temperature approach warnings"
    else
        self_test_result 0 "Fresh hot drives retain temperature approach warnings"
    fi
    if (
        local alerts=0
        record_alert() { alerts=$((alerts+1)); }
        lsblk_rota_cached() { printf '1\n'; }
        TEMP_RATE_ALERT_ENABLED=1; HDD_TEMP_WARNING=45
        RUN_EPOCH=123456; FRESH_SMART[/dev/sdz]=1
        record_temperature_approach /dev/sdz 42 100000 10 2 HIGH
        record_temperature_approach /dev/sdz 42 "$RUN_EPOCH" 10 2 STALE
        (( alerts==0 ))
    ); then
        self_test_result 1 "Stale readings cannot raise temperature approach warnings"
    else
        self_test_result 0 "Stale readings cannot raise temperature approach warnings"
    fi

    local temperature_quality_history="$fixture_dir/temperature-quality.log"
    local temperature_quality_run="$fixture_dir/temperature-quality-run"
    local stale_date_one stale_date_two stale_date_three stale_epoch
    stale_date_one=$(date -d '-8 days' '+%Y-%m-%d')
    stale_date_two=$(date -d '-7 days' '+%Y-%m-%d')
    stale_date_three=$(date -d '-6 days' '+%Y-%m-%d')
    stale_epoch=$(date -d "$stale_date_three 12:00:00" +%s)
    printf '%s\n' \
        "$stale_date_one temp_fixture temp=30 captured_epoch=$(date -d "$stale_date_one 12:00:00" +%s) schema=3" \
        "$stale_date_two temp_fixture temp=31 captured_epoch=$(date -d "$stale_date_two 12:00:00" +%s) schema=3" \
        "$stale_date_three temp_fixture temp=32 captured_epoch=$stale_epoch schema=3" \
        > "$temperature_quality_history"
    mkdir -p "$temperature_quality_run"
    DEVICE_ID_BY_PATH=()
    DEVICE_PATH_BY_ID=()
    DEVICE_ID_BY_PATH[/dev/sdy]="temp_fixture"
    DEVICE_PATH_BY_ID[temp_fixture]="/dev/sdy"
    TEMP_HISTORY_FILE="$temperature_quality_history"
    RUN_DIR="$temperature_quality_run"
    RUN_EPOCH=$(date +%s)
    TREND_HISTORY_CACHE=()
    TEMP_RATE_ALERT_ENABLED=0
    TEMP_FORECAST_CONFIDENCE_LINE=""
    analyze_temperature_trends
    if [[ "$TEMP_FORECAST_CONFIDENCE_LINE" == \
          'Temperature history is stale for 1 disk, likely because it is sleeping' ]]
    then
        self_test_result 1 "Human-readable stale temperature explanation"
    else
        self_test_result 0 "Human-readable stale temperature explanation" \
            "found '$TEMP_FORECAST_CONFIDENCE_LINE'"
    fi
    DEVICE_ID_BY_PATH=()
    DEVICE_PATH_BY_ID=()

    local trend_history="$fixture_dir/trend-history.log"
    printf '%s\n' \
        'corrupted row' \
        '2026-08-18 disk_a value=8' \
        '2026-08-14 disk_a value=1' \
        '2026-08-16 disk_a value=2' \
        'not-a-date disk_a value=9' > "$trend_history"
    actual=$(stream_trend_history_window "$trend_history" 2026-08-15 |
        awk '{printf "%s%s", separator, $0; separator="|"}')
    if [[ "$actual" == '2026-08-16 disk_a value=2|2026-08-18 disk_a value=8' ]]; then
        self_test_result 1 "Normalized bounded trend-history streaming"
    else
        self_test_result 0 "Normalized bounded trend-history streaming" "found '$actual'"
    fi

    local trend_cache_source="$fixture_dir/trend-cache-source.log"
    RUN_DIR="$fixture_dir/trend-run"
    mkdir -p "$RUN_DIR"
    TREND_HISTORY_CACHE=()
    printf '2026-08-16 disk_a value=1\n' > "$trend_cache_source"
    local cached_before cached_after cached_refresh
    if prepare_trend_history_cache fixture-cache "$trend_cache_source" 100; then
        cached_before=$(awk 'END { print NR+0 }' "$TREND_CACHE_RESULT")
    else
        cached_before=0
    fi
    printf '2026-08-17 disk_a value=2\n' >> "$trend_cache_source"
    prepare_trend_history_cache fixture-cache "$trend_cache_source" 100 || true
    cached_after=$(awk 'END { print NR+0 }' "$TREND_CACHE_RESULT")
    TREND_HISTORY_CACHE=()
    prepare_trend_history_cache fixture-cache "$trend_cache_source" 100 || true
    cached_refresh=$(awk 'END { print NR+0 }' "$TREND_CACHE_RESULT")
    if [[ "$cached_before" == "1" && "$cached_after" == "1" &&
          "$cached_refresh" == "2" ]]
    then
        self_test_result 1 "Single-read per-run trend-history cache"
    else
        self_test_result 0 "Single-read per-run trend-history cache" \
            "before=$cached_before cached=$cached_after refresh=$cached_refresh"
    fi

    history_file="$fixture_dir/daily.log"
    printf 'malformed legacy row\n2026-08-15 disk_a temp=29 captured_epoch=1 schema=3\n' > "$history_file"
    if atomic_replace_daily_history "$history_file" 2026-08-15 \
           '2026-08-15 disk_a temp=30 captured_epoch=2 schema=3' \
           '2026-08-15 disk_b temp=32 captured_epoch=2 schema=3' &&
       atomic_upsert_daily_history "$history_file" 2026-08-15 disk_a \
           '2026-08-15 disk_a temp=31 captured_epoch=3 schema=3'
    then
        count=$(awk '$1=="2026-08-15" && $2=="disk_a" {count++} END {print count+0}' "$history_file")
        if [[ "$count" == "1" ]] &&
           grep -q '^2026-08-15 disk_a temp=31 ' "$history_file" &&
           ! grep -q '^malformed ' "$history_file"
        then
            self_test_result 1 "Atomic daily history replacement and upsert"
        else
            self_test_result 0 "Atomic daily history replacement and upsert" "unexpected fixture contents"
        fi
    else
        self_test_result 0 "Atomic daily history replacement and upsert" "helper returned failure"
    fi

    source_file="$fixture_dir/source.log"
    chunk_file="$fixture_dir/chunk.log"
    printf 'one\ntwo\nthree\nfour\n' > "$source_file"
    : > "$chunk_file"
    if append_syslog_line_range "$source_file" 2 3 "$chunk_file" &&
       [[ "$(awk '{printf "%s|", $0}' "$chunk_file")" == "two|three|" ]]
    then
        self_test_result 1 "Bounded syslog line-range extraction"
    else
        self_test_result 0 "Bounded syslog line-range extraction"
    fi

    local ata_fixture ata_malformed
    ata_fixture=$'ID# ATTRIBUTE_NAME FLAG VALUE WORST THRESH TYPE UPDATED WHEN_FAILED RAW_VALUE\n  5 Reallocated_Sector_Ct 0x0033 100 100 010 Pre-fail Always - 7\n  9 Power_On_Hours 0x0032 091 091 000 Old_age Always - 12345\n194 Temperature_Celsius 0x0022 063 050 000 Old_age Always - 37\n197 Current_Pending_Sector 0x0012 100 100 000 Old_age Always - 2\n199 UDMA_CRC_Error_Count 0x003e 200 200 000 Old_age Always - 4\n233 Media_Wearout_Indicator 0x0032 095 095 000 Old_age Always - 5\n241 Total_LBAs_Written 0x0032 099 099 000 Old_age Always - 123456789'
    actual="$(ata_smart_attribute_value "$ata_fixture" Reallocated_Sector_Ct)|$(ata_smart_attribute_value "$ata_fixture" Current_Pending_Sector)|$(ata_smart_attribute_value "$ata_fixture" Temperature_Celsius)|$(ata_smart_attribute_value "$ata_fixture" Power_On_Hours)|$(ata_smart_attribute_value "$ata_fixture" Media_Wearout_Indicator normalized)|$(ata_smart_attribute_value "$ata_fixture" 241)"
    if [[ "$actual" == "7|2|37|12345|95|123456789" ]]; then
        self_test_result 1 "ATA/USB-bridge SMART attribute parser fixtures"
    else
        self_test_result 0 "ATA/USB-bridge SMART attribute parser fixtures" "found '$actual'"
    fi

    ata_malformed=$'  5 Reallocated_Sector_Ct 0x0033 100 100 010 Pre-fail Always - not-a-number\ntruncated attribute row'
    actual=$(ata_smart_attribute_value "$ata_malformed" Reallocated_Sector_Ct)
    if [[ -z "$actual" ]] && ! ata_smart_output_is_complete "$ata_malformed"; then
        self_test_result 1 "ATA malformed attribute rejection"
    else
        self_test_result 0 "ATA malformed attribute rejection" "found '$actual'"
    fi

    local scsi_fixture
    scsi_fixture=$'SMART Health Status: OK\nCurrent Drive Temperature: 34 C\nAccumulated power on time, hours:minutes 12345:12\nElements in grown defect list: 2\nread: 10 0 0 0 0 0 0\nwrite: 20 0 0 0 0 0 1\nNon-medium error count: 3'
    actual="$(scsi_smart_field_value "$scsi_fixture" health)|$(scsi_smart_field_value "$scsi_fixture" temperature)|$(scsi_smart_field_value "$scsi_fixture" poh)|$(scsi_smart_field_value "$scsi_fixture" grown_defects)|$(scsi_smart_field_value "$scsi_fixture" read_uncorrected)|$(scsi_smart_field_value "$scsi_fixture" write_uncorrected)|$(scsi_smart_field_value "$scsi_fixture" non_medium)"
    if [[ "$actual" == "OK|34|12345|2|0|1|3" ]] &&
       scsi_smart_output_is_complete "$scsi_fixture"
    then
        self_test_result 1 "SCSI/SAS SMART parser fixture"
    else
        self_test_result 0 "SCSI/SAS SMART parser fixture" "found '$actual'"
    fi

    if (
        local MASTER_LOG="$fixture_dir/age-advisory.log"
        local device=/dev/sdz
        local age_only_sas_fixture=$'SMART Health Status: OK\nCurrent Drive Temperature: 34 C\nAccumulated power on time, hours:minutes 12345:12\nElements in grown defect list: 0'
        poh_thresholds_for_device() { printf '1000 2000\n'; }
        collector_upsert_daily_history() { return 0; }
        get_latest_selftest_info() { printf 'short|0|Completed without error\n'; }
        FINDING_IDS=()
        FINDING_SEEN=()
        evaluate_scsi_smart "$device" "$age_only_sas_fixture" &&
            [[ "${SMART_STATE[$device]}" == OK && "${#FINDING_IDS[@]}" == 0 ]] || exit 1
        evaluate_scsi_smart "$device" "${age_only_sas_fixture/34 C/70 C}" &&
            [[ "${SMART_STATE[$device]}" == CRITICAL &&
               "${FINDING_SEVERITY["device:$device|temp"]:-}" == critical ]]
    ); then
        self_test_result 1 "Drive age alone stays healthy while actual overheating stays critical"
    else
        self_test_result 0 "Drive age alone stays healthy while actual overheating stays critical"
    fi

    if (
        smartctl_cached() {
            printf '%s\n' 'Model Family: Generic array' 'Device Model: Fixture Storage'
            printf '%131072s\n' end || return 141
        }
        local model=""
        model=$(get_device_model /dev/sdz) &&
            [[ "$model" == 'Fixture Storage' ]]
    ); then
        self_test_result 1 "SMART model parsing reads full output and prefers the exact model"
    else
        self_test_result 0 "SMART model parsing reads full output and prefers the exact model"
    fi

    local nvme_fixture nvme_ext_fixture
    nvme_fixture=$'Critical Warning:                   0x04\nTemperature:                        41 Celsius\nAvailable Spare:                    99%\nAvailable Spare Threshold:          10%\nPercentage Used:                    12%\nData Units Written:                 1,234,567 [632 GB]\nPower On Hours:                     12,345\nUnsafe Shutdowns:                   7\nMedia and Data Integrity Errors:    8\nError Information Log Entries:      9'
    nvme_ext_fixture=$'PCIe Correctable Error Count:        2\nPCIe Uncorrectable Error Count:      1\nThermal Management T1 Transitions:  3\nThermal Management T2 Transitions:  4\nWarning  Comp. Temperature Time:     5\nCritical Comp. Temperature Time:     6'
    actual="$(smart_labeled_field_value "$nvme_fixture" "Critical Warning" scalar)|$(smart_labeled_field_value "$nvme_fixture" "Percentage Used" number)|$(smart_labeled_field_value "$nvme_fixture" "Power On Hours" number)|$(smart_labeled_field_value "$nvme_fixture" "Data Units Written" number)|$(smart_labeled_field_value "$nvme_fixture" "Available Spare" number)|$(smart_labeled_field_value "$nvme_fixture" "Temperature" number)|$(smart_labeled_field_value "$nvme_ext_fixture" "Warning Comp. Temperature Time" number)"
    if [[ "$actual" == "0x04|12|12345|1234567|99|41|5" ]] &&
       nvme_smart_output_is_complete "$nvme_fixture"
    then
        self_test_result 1 "NVMe SMART and extended parser fixtures"
    else
        self_test_result 0 "NVMe SMART and extended parser fixtures" "found '$actual'"
    fi

    actual=$(smart_labeled_field_value $'Available Spare Threshold: 10%\ntruncated' "Available Spare" number)
    if [[ -z "$actual" ]] &&
       ! nvme_smart_output_is_complete $'Available Spare Threshold: 10%\ntruncated'
    then
        self_test_result 1 "NVMe exact-label and truncated-output rejection"
    else
        self_test_result 0 "NVMe exact-label and truncated-output rejection" "found '$actual'"
    fi

    local ata_selftest nvme_selftest failed_selftest parsed_status parsed_class
    ata_selftest=$'SMART Self-test log structure revision number 1\n# 1 Short offline Completed without error 00% 1234 -\n# 2 Extended offline Completed without error 00% 1200 -'
    actual=$(parse_smart_selftest_output "$ata_selftest")
    local latest_long_parsed
    latest_long_parsed=$(parse_smart_selftest_output "$(select_latest_long_selftest_line "$ata_selftest")")
    if [[ "$actual" == "1|Short offline|Completed without error|1234|00%" &&
          "$latest_long_parsed" == "2|Extended offline|Completed without error|1200|00%" ]]
    then
        self_test_result 1 "ATA self-test log parser fixture"
    else
        self_test_result 0 "ATA self-test log parser fixture" "found '$actual'"
    fi

    nvme_selftest=$'Self-test Log\n# 2 Short Self-test routine in progress 90% 234 -'
    failed_selftest=$'# 3 Extended offline Completed: read failure 90% 100 -'
    actual=$(parse_smart_selftest_output "$nvme_selftest")
    parsed_status=$(printf '%s' "$actual" | awk -F'|' '{print $3}')
    parsed_class=$(classify_selftest_status "$parsed_status")
    if [[ "$actual" == "2|Short|Self-test routine in progress|234|90%" &&
          "$parsed_class" == INPROGRESS\|* &&
          "$(classify_selftest_status "$(parse_smart_selftest_output "$failed_selftest" | awk -F'|' '{print $3}')")" == CRITICAL\|* ]]
    then
        self_test_result 1 "NVMe and failed self-test classification fixtures"
    else
        self_test_result 0 "NVMe and failed self-test classification fixtures" "parsed '$actual' class '$parsed_class'"
    fi

    local btrfs_fixture
    btrfs_fixture=$'[/dev/sda1].write_io_errs    3\n/dev/nvme0n1p1: corruption_errs 2\n[/dev/sdb1].read_io_errs -1\nmalformed'
    actual=$(parse_btrfs_device_stats_text "$btrfs_fixture" | awk -F'\t' '{printf "%s%s:%s:%s", separator, $1, $2, $3; separator="|"}')
    if [[ "$actual" == "/dev/sda1:write_io_errs:3|/dev/nvme0n1p1:corruption_errs:2" ]]; then
        self_test_result 1 "Btrfs device-stat format and malformed-row fixtures"
    else
        self_test_result 0 "Btrfs device-stat format and malformed-row fixtures" "found '$actual'"
    fi


    local io_fixture ignored_io_fixture
    io_fixture='Aug 16 12:00:00 kernel: blk_update_request: I/O error, dev sda, sector 8; nvme0n1 reset'
    ignored_io_fixture='Aug 16 12:00:01 host: Disk I/O Alert for sdb I/O error'
    actual=$(extract_syslog_device_paths "$io_fixture" | awk '{printf "%s%s", separator, $0; separator="|"}')
    if syslog_line_is_disk_io_error "$io_fixture" &&
       ! syslog_line_is_disk_io_error "$ignored_io_fixture" &&
       [[ "$actual" == "/dev/nvme0n1|/dev/sda" ]]
    then
        self_test_result 1 "Syslog I/O classification and device parser fixtures"
    else
        self_test_result 0 "Syslog I/O classification and device parser fixtures" "found '$actual'"
    fi

    local disks_ini_fixture="$fixture_dir/disks.ini"
    printf '[parity]\ndevice="sda"\n[disk1]\n device = "/dev/sdb"\n[cache]\nDEVICE="nvme0n1"\ndevice="sda1"\n' > "$disks_ini_fixture"
    actual=$(parse_unraid_disk_devices_file "$disks_ini_fixture" | awk '{printf "%s%s", separator, $0; separator="|"}')
    if [[ "$actual" == "sda|sdb|nvme0n1" ]]; then
        self_test_result 1 "Unraid disks.ini device parser fixture"
    else
        self_test_result 0 "Unraid disks.ini device parser fixture" "found '$actual'"
    fi

    local smartctl_rc bitmask_failures=0
    for smartctl_rc in 0 4 8 16 32 64 128; do
        smartctl_exit_has_operational_failure "$smartctl_rc" && bitmask_failures=$((bitmask_failures + 1))
    done
    for smartctl_rc in 1 2 3 5 6 7; do
        smartctl_exit_has_operational_failure "$smartctl_rc" || bitmask_failures=$((bitmask_failures + 1))
    done
    if (( bitmask_failures == 0 )); then
        self_test_result 1 "smartctl exit-bitmask operational classification"
    else
        self_test_result 0 "smartctl exit-bitmask operational classification" "$bitmask_failures case(s) failed"
    fi

    DEVICE_ID_BY_PATH=()
    DEVICE_PATH_BY_ID=()
    DEVICE_ID_SOURCE=()
    DEVICE_ID_BY_PATH[/dev/sda]="wwn_fixture"
    DEVICE_PATH_BY_ID[wwn_fixture]="/dev/sda"
    local stable_partition_key renamed_partition
    stable_partition_key=$(persistent_device_key /dev/sda1)
    DEVICE_ID_BY_PATH=()
    DEVICE_PATH_BY_ID=()
    DEVICE_ID_BY_PATH[/dev/sdz]="wwn_fixture"
    DEVICE_PATH_BY_ID[wwn_fixture]="/dev/sdz"
    renamed_partition=$(runtime_device_path "$stable_partition_key" 2>/dev/null || true)
    if [[ "$stable_partition_key" == "wwn_fixture@1" && "$renamed_partition" == "/dev/sdz1" ]]; then
        self_test_result 1 "Stable identity survives runtime device renaming"
    else
        self_test_result 0 "Stable identity survives runtime device renaming" "key=$stable_partition_key path=$renamed_partition"
    fi
    DEVICE_ID_BY_PATH=()
    DEVICE_PATH_BY_ID=()
    DEVICE_ID_SOURCE=()

    local cursor_source="$fixture_dir/syslog.fixture" cursor_metadata cursor_device cursor_inode cursor_size cursor_anchor
    RUN_DIR="$fixture_dir/syslog_run"
    mkdir -p "$RUN_DIR"
    SYSLOG_CURSOR_STATE_FILE="$fixture_dir/syslog.cursor"
    IO_ERROR_LOG_FILE="$cursor_source"
    printf 'old-one\nold-two\n' > "$cursor_source"
    cursor_metadata=$(stat -c '%d %i %s' -- "$cursor_source")
    read -r cursor_device cursor_inode cursor_size <<< "$cursor_metadata"
    cursor_anchor=$(sed -n '2p' "$cursor_source" | sha1sum | awk '{print $1}')
    printf 'v2 %s %s %s 2 %s %s\n' "$cursor_source" "$cursor_device" "$cursor_inode" "$cursor_size" "$cursor_anchor" > "$SYSLOG_CURSOR_STATE_FILE"
    printf 'old-three\n' >> "$cursor_source"
    mv "$cursor_source" "${cursor_source}.1"
    printf 'new-one\nnew-two\n' > "$cursor_source"
    if build_new_syslog_chunk; then
        actual=$(awk '{printf "%s|", $0}' "$SYSLOG_CHUNK_FILE")
    else
        actual="build-failed"
    fi
    if [[ "$actual" == "old-three|new-one|new-two|" &&
          "$SYSLOG_CURSOR_READY" == "1" &&
          "$SYSLOG_CURSOR_MODE" == "rotation_recovery" ]]
    then
        self_test_result 1 "Persistent syslog cursor rotation recovery fixture"
    else
        self_test_result 0 "Persistent syslog cursor rotation recovery fixture" \
            "found '$actual' ready=$SYSLOG_CURSOR_READY mode=$SYSLOG_CURSOR_MODE"
    fi

    FINDING_IDS=(
        'device:/dev/sdb|capacity_warning'
        'device:/dev/sda|pending_sectors'
        'device:/dev/sdc|selftest_failed'
        'device:/dev/sda|command_timeout'
        'mount:/mnt/disk2|storage_warning'
    )
    FINDING_SEVERITY=()
    FINDING_CATEGORY=()
    FINDING_SIGNAL=()
    FINDING_DEVICE=()
    FINDING_SCOPE=()
    FINDING_TITLE=()
    FINDING_EVIDENCE=()
    FINDING_ACTION=()
    declare -A RISK_MAP=()
    MOUNT_TO_DEV=()
    POOL_MEMBER_MAP=()

    local test_id
    for test_id in "${FINDING_IDS[@]}"; do
        FINDING_SEVERITY[$test_id]="warning"
        FINDING_CATEGORY[$test_id]="capacity"
        FINDING_SIGNAL[$test_id]="capacity.space"
        FINDING_SCOPE[$test_id]="${test_id%%|*}"
        FINDING_TITLE[$test_id]="Capacity"
        FINDING_EVIDENCE[$test_id]="Fixture evidence for $test_id"
        FINDING_ACTION[$test_id]="Review capacity."
    done
    FINDING_DEVICE['device:/dev/sdb|capacity_warning']='/dev/sdb'
    FINDING_DEVICE['device:/dev/sda|pending_sectors']='/dev/sda'
    FINDING_DEVICE['device:/dev/sdc|selftest_failed']='/dev/sdc'
    FINDING_DEVICE['device:/dev/sda|command_timeout']='/dev/sda'
    FINDING_SEVERITY['device:/dev/sda|pending_sectors']='critical'
    FINDING_SEVERITY['device:/dev/sdc|selftest_failed']='critical'
    FINDING_SEVERITY['device:/dev/sda|command_timeout']='critical'
    FINDING_CATEGORY['device:/dev/sda|pending_sectors']='smart'
    FINDING_CATEGORY['device:/dev/sdc|selftest_failed']='smart'
    FINDING_CATEGORY['device:/dev/sda|command_timeout']='io'
    FINDING_SIGNAL['device:/dev/sda|pending_sectors']='smart.media'
    FINDING_SIGNAL['device:/dev/sdc|selftest_failed']='smart.selftest'
    FINDING_SIGNAL['device:/dev/sda|command_timeout']='io.command_timeout'
    FINDING_TITLE['device:/dev/sda|pending_sectors']='Pending sectors'
    FINDING_TITLE['device:/dev/sda|command_timeout']='Command timeout'
    FINDING_ACTION['device:/dev/sda|pending_sectors']='Inspect now.'
    FINDING_ACTION['device:/dev/sda|command_timeout']='Inspect now.'

    local risk_sort_stderr="$fixture_dir/risk-sort.stderr"
    actual=$(emit_sorted_finding_ids 2> "$risk_sort_stderr" | awk '{printf "%s%s", separator, $0; separator="|"}')
    if [[ "$actual" == 'device:/dev/sda|pending_sectors|device:/dev/sdc|selftest_failed|device:/dev/sda|command_timeout|device:/dev/sdb|capacity_warning|mount:/mnt/disk2|storage_warning' &&
          ! -s "$risk_sort_stderr" ]]
    then
        self_test_result 1 "Deterministic structured finding ordering"
    else
        self_test_result 0 "Deterministic structured finding ordering" \
            "found '$actual'; stderr=$(tr '\n' ' ' < "$risk_sort_stderr")"
    fi

    MOUNT_TO_DEV['/mnt/disk1']='/dev/sda'
    ENABLE_MODEL_IN_ALERTS=0
    finalize_finding_counts
    build_health_alerts
    count=$(printf '%s\n' "$HEALTH_ALERTS_SECTION" | grep -F -c 'Action: Inspect now.' || true)
    if (( FINDING_CRITICAL_COUNT == 3 && FINDING_WARNING_COUNT == 2 )) &&
       [[ "$count" == "1" ]] &&
       printf '%s\n' "$HEALTH_ALERTS_SECTION" |
           grep -Fq -- '- [CRITICAL] disk1 [sda] - 2 findings'
    then
        self_test_result 1 "Grouped finding rendering and action de-duplication"
    else
        self_test_result 0 "Grouped finding rendering and action de-duplication" "unexpected structured report"
    fi

    FINDING_IDS=()
    FINDING_SEEN=()
    FINDING_SEVERITY=()
    FINDING_CATEGORY=()
    FINDING_SIGNAL=()
    FINDING_DEVICE=()
    FINDING_SCOPE=()
    FINDING_TITLE=()
    FINDING_EVIDENCE=()
    FINDING_ACTION=()
    declare -A RISK_MAP=()
    LOG_MIRROR_STDOUT=0
    record_finding warning monitoring monitoring.timeout "" \
        "Collector timeout" "Fixture collector exceeded deadline." \
        "Review the fixture log." "fixture_timeout"
    finalize_finding_counts
    build_health_alerts
    local golden_health_alerts=$'Health Alerts:\n - [WARNING] Monitoring - 1 finding\n   - Collector timeout: Fixture collector exceeded deadline.\n     Action: Review the fixture log.'
    if [[ "$HEALTH_ALERTS_SECTION" == "$golden_health_alerts" &&
          "$FINDING_WARNING_COUNT" == "1" && "$FINDING_CRITICAL_COUNT" == "0" ]]
    then
        self_test_result 1 "Golden global notification rendering fixture"
    else
        self_test_result 0 "Golden global notification rendering fixture" \
            "unexpected rendered health-alert block"
    fi

    STORAGE_TOP_LINES=$'Array: 50.0% used (5.00 TB of 10.00 TB)\nPools: 25.0% used (250.00 GB of 1.00 TB)'
    NOTIFICATION_RECOVERY_SECTION=$'Resolved Since Last Successful Notification:\n - [WARNING] Earlier finding'
    SUBJECT="Disk Health Monitor - WARNING (1)"
    NOTIFY_MAX_BODY_CHARS=12000
    NOTIFY_MAX_BODY_LINES=180
    compose_notification
    if [[ "$NOTIFY_BODY" == "$golden_health_alerts"$'\n\n'"$NOTIFICATION_RECOVERY_SECTION"$'\n\n'"$STORAGE_TOP_LINES" &&
          "$NOTIFICATION_DESCRIPTION" == 'Monitoring - Collector timeout' ]]; then
        self_test_result 1 "Notification prioritizes findings and recovery over capacity"
    else
        self_test_result 0 "Notification prioritizes findings and recovery over capacity" "unexpected body or description"
    fi

    if (
        local storage_fixture="$fixture_dir/storage-fixture"
        mkdir -p "$storage_fixture"/{disk1,cache,user,user0,ramlogs}
        mountpoint() { return 0; }
        df_bounded() { printf '1000 960 96%%\n'; }
        findmnt_bounded() {
            case "$*" in
                *FSTYPE*ramlogs) printf 'tmpfs\n' ;;
                *FSTYPE*) printf 'xfs\n' ;;
                *) printf '/dev/nvme0n1p1\n' ;;
            esac
        }
        local alerts=0
        record_alert() { alerts=$((alerts+1)); }
        collect_storage_usage "$storage_fixture" &&
            [[ "$ARRAY_TOTAL_BYTES" == 1000 && "$POOLS_TOTAL_BYTES" == 1000 &&
               "${POOL_MEMBER_MAP[/dev/nvme0n1]:-}" == cache &&
               "${FRESH_STORAGE[$storage_fixture/disk1]:-}" == 1 && "$alerts" == 2 && -z "${FRESH_STORAGE[$storage_fixture/ramlogs]:-}" ]]
    ); then
        self_test_result 1 "One capacity sample drives disk/pool alerts and excludes RAM-log capacity owned by its watchdog"
    else
        self_test_result 0 "One capacity sample drives disk/pool alerts and excludes RAM-log capacity owned by its watchdog"
    fi

    # shellcheck disable=SC2030
    NOTIFY_BODY=""
    for (( count=1; count<=30; count++ )); do
        NOTIFY_BODY+="line-${count}: 123456789012345678901234567890"
        (( count == 30 )) || NOTIFY_BODY+=$'\n'
    done
    MASTER_LOG="$fixture_dir/notification.log"
    : > "$MASTER_LOG"
    NOTIFY_MAX_BODY_CHARS=512
    NOTIFY_MAX_BODY_LINES=20
    LOG_FULL_NOTIFICATION_ON_TRUNCATION=1
    LOG_MIRROR_STDOUT=0
    limit_notification_body
    actual=${#NOTIFY_BODY}
    count=$(printf '%s\n' "$NOTIFY_BODY" | awk 'END {print NR+0}')
    if (( NOTIFICATION_TRUNCATED == 1 && actual <= 512 && count <= 20 )) &&
       grep -Fq 'line-30:' "$MASTER_LOG" &&
       [[ "$NOTIFY_BODY" == *'[Report shortened:'* ]]
    then
        self_test_result 1 "Bounded notification with complete log preservation"
    else
        self_test_result 0 "Bounded notification with complete log preservation" \
            "truncated=$NOTIFICATION_TRUNCATED chars=$actual lines=$count"
    fi

    local notification_dir="$fixture_dir/notification-lifecycle"
    local notification_id="global|fixture_notification"
    local notification_fingerprint journal_before journal_after
    mkdir -p "$notification_dir"
    NOTIFICATION_JOURNAL_FILE="$notification_dir/lifecycle.state"
    NOTIFICATION_RECOVERY_STATE_FILE="$notification_dir/recovery.state"
    COLLECTOR_ORDER=()
    COLLECTOR_STATUS=()
    declare -A RISK_MAP=()
    NOTIFICATION_LIFECYCLE_ENABLED=1
    NOTIFICATION_WARNING_REMINDER_HOURS=24
    NOTIFICATION_CRITICAL_REMINDER_HOURS=6
    NOTIFICATION_OK_REMINDER_HOURS=168
    NOTIFICATION_RECOVERY_CONFIRM_RUNS=2
    NOTIFICATION_DRY_RUN=0
    NOTIFY_CARRY_IDS=()

    fixture_notification_finding() {
        local severity="$1"

        FINDING_IDS=("$notification_id")
        FINDING_SEEN=()
        FINDING_SEVERITY=()
        FINDING_CATEGORY=()
        FINDING_SIGNAL=()
        FINDING_DEVICE=()
        FINDING_SCOPE=()
        FINDING_TITLE=()
        FINDING_EVIDENCE=()
        FINDING_ACTION=()
        FINDING_SEEN[$notification_id]=1
        FINDING_SEVERITY[$notification_id]="$severity"
        FINDING_CATEGORY[$notification_id]="monitoring"
        FINDING_SIGNAL[$notification_id]="monitoring.fixture"
        FINDING_DEVICE[$notification_id]=""
        FINDING_SCOPE[$notification_id]="global"
        FINDING_TITLE[$notification_id]="Fixture notification"
        FINDING_EVIDENCE[$notification_id]="volatile counter=1"
        FINDING_ACTION[$notification_id]="Review the fixture."
        finalize_finding_counts
    }

    fixture_clear_notification_findings() {
        FINDING_IDS=()
        FINDING_SEEN=()
        FINDING_SEVERITY=()
        FINDING_CATEGORY=()
        FINDING_SIGNAL=()
        FINDING_DEVICE=()
        FINDING_SCOPE=()
        FINDING_TITLE=()
        FINDING_EVIDENCE=()
        FINDING_ACTION=()
        finalize_finding_counts
    }

    fixture_notification_finding warning
    RUN_EPOCH=1787000000
    build_current_notification_state
    notification_fingerprint="${NOTIFY_CURRENT_FINGERPRINT[$notification_id]:-}"
    if persist_notification_journal && load_notification_journal &&
       (( NOTIFICATION_JOURNAL_LOADED == 1 )) &&
       [[ "${NOTIFY_PREV_FINGERPRINT[$notification_id]:-}" == \
          "$notification_fingerprint" &&
          "${NOTIFY_PREV_LABEL[$notification_id]:-}" == \
          "Monitoring - Fixture notification" ]]
    then
        self_test_result 1 "Atomic notification journal round-trip"
    else
        self_test_result 0 "Atomic notification journal round-trip"
    fi

    if (
        local NOTIFICATION_JOURNAL_FILE="$fixture_dir/retired-findings.tsv"
        printf 'meta\t1\t1787000000\twarning\n' > "$NOTIFICATION_JOURNAL_FILE"
        local code
        for code in poh_age_hdd load_cycle_count smart_scheduling pending_sectors; do
            printf 'finding\tdevice:/dev/sda|%s\twarning\t%s\tFixture\n' "$code" "$notification_fingerprint" >> "$NOTIFICATION_JOURNAL_FILE"
        done
        load_notification_journal &&
            [[ "${#NOTIFY_PREV_IDS[@]}" == 1 && "${NOTIFY_PREV_IDS[0]}" == 'device:/dev/sda|pending_sectors' ]]
    ); then
        self_test_result 1 "Retired advisories leave the notification journal without false recoveries"
    else
        self_test_result 0 "Retired advisories leave the notification journal without false recoveries"
    fi

    printf 'meta\t1\tinvalid\twarning\n' > "$NOTIFICATION_JOURNAL_FILE"
    load_notification_journal
    if (( NOTIFICATION_JOURNAL_LOADED == 0 &&
          ${#NOTIFY_PREV_FINGERPRINT[@]} == 0 )); then
        self_test_result 1 "Malformed notification journal rejection"
    else
        self_test_result 0 "Malformed notification journal rejection"
    fi

    : > "$NOTIFICATION_JOURNAL_FILE"
    RUN_EPOCH=1787000100
    prepare_notification_lifecycle
    if [[ "$NOTIFICATION_DECISION" == "SEND" &&
          "$NOTIFICATION_REASON" == "initial notification baseline" &&
          "$NOTIFICATION_JOURNAL_COMMIT_ALLOWED" == "1" ]]
    then
        self_test_result 1 "Initial notification lifecycle baseline"
    else
        self_test_result 0 "Initial notification lifecycle baseline" \
            "decision=$NOTIFICATION_DECISION reason=$NOTIFICATION_REASON"
    fi

    RUN_EPOCH=1787000200
    build_current_notification_state
    persist_notification_journal
    RUN_EPOCH=$((RUN_EPOCH + 3600))
    prepare_notification_lifecycle
    if [[ "$NOTIFICATION_DECISION" == "SUPPRESS" &&
          "$NOTIFICATION_NEW_COUNT" == "0" &&
          "$NOTIFICATION_CHANGED_COUNT" == "0" ]]
    then
        self_test_result 1 "Unchanged warning cooldown suppression"
    else
        self_test_result 0 "Unchanged warning cooldown suppression" \
            "decision=$NOTIFICATION_DECISION reason=$NOTIFICATION_REASON"
    fi

    fixture_notification_finding critical
    RUN_EPOCH=1787000300
    build_current_notification_state
    persist_notification_journal
    RUN_EPOCH=$((RUN_EPOCH + NOTIFICATION_CRITICAL_REMINDER_HOURS * 3600))
    prepare_notification_lifecycle
    if [[ "$NOTIFICATION_DECISION" == "SEND" &&
          "$NOTIFICATION_REASON" == *"critical reminder is due"* ]]
    then
        self_test_result 1 "Critical finding reminder deadline"
    else
        self_test_result 0 "Critical finding reminder deadline" \
            "decision=$NOTIFICATION_DECISION reason=$NOTIFICATION_REASON"
    fi

    fixture_notification_finding warning
    RUN_EPOCH=1787000400
    build_current_notification_state
    persist_notification_journal
    fixture_clear_notification_findings
    RUN_EPOCH=$((RUN_EPOCH + 60))
    prepare_notification_lifecycle
    if [[ "$NOTIFICATION_DECISION" == "SUPPRESS" &&
          "$NOTIFICATION_RESOLVED_COUNT" == "0" &&
          "$NOTIFICATION_RECOVERY_PENDING_COUNT" == "1" &&
          "$NOTIFICATION_REASON" == *"awaiting 2 consecutive safe runs"* ]]
    then
        self_test_result 1 "Recovery hysteresis first safe observation"
    else
        self_test_result 0 "Recovery hysteresis first safe observation" \
            "decision=$NOTIFICATION_DECISION resolved=$NOTIFICATION_RESOLVED_COUNT pending=$NOTIFICATION_RECOVERY_PENDING_COUNT"
    fi
    if persist_notification_journal && load_notification_journal &&
       [[ -n "${NOTIFY_PREV_FINGERPRINT[$notification_id]:-}" ]]
    then
        self_test_result 1 "Pending recovery survives journal advancement"
    else
        self_test_result 0 "Pending recovery survives journal advancement"
    fi
    RUN_EPOCH=$((RUN_EPOCH + 60))
    prepare_notification_lifecycle
    build_subject
    if [[ "$NOTIFICATION_DECISION" == "SEND" &&
          "$NOTIFICATION_RESOLVED_COUNT" == "1" &&
          "$NOTIFICATION_RECOVERY_SECTION" == *"Fixture notification"* &&
          "$SUBJECT" == "Disk Health Monitor - RECOVERED (1)" ]]
    then
        self_test_result 1 "Resolved finding notification rendering"
    else
        self_test_result 0 "Resolved finding notification rendering" \
            "decision=$NOTIFICATION_DECISION resolved=$NOTIFICATION_RESOLVED_COUNT subject=$SUBJECT"
    fi

    fixture_notification_finding warning
    RUN_EPOCH=1787000500
    build_current_notification_state
    persist_notification_journal
    fixture_clear_notification_findings
    COLLECTOR_ORDER=(fixture_incomplete)
    COLLECTOR_STATUS=([fixture_incomplete]="FAILED")
    RUN_EPOCH=$((RUN_EPOCH + 60))
    prepare_notification_lifecycle
    if [[ "$NOTIFICATION_DECISION" == "SUPPRESS" &&
          "$NOTIFICATION_RESOLVED_COUNT" == "0" &&
          "$NOTIFICATION_RECOVERY_DEFERRED_COUNT" == "1" &&
          "$NOTIFICATION_JOURNAL_COMMIT_ALLOWED" == "1" ]]
    then
        self_test_result 1 "Incomplete collector blocks false recovery"
    else
        self_test_result 0 "Incomplete collector blocks false recovery" \
            "decision=$NOTIFICATION_DECISION resolved=$NOTIFICATION_RESOLVED_COUNT deferred=$NOTIFICATION_RECOVERY_DEFERRED_COUNT"
    fi

    if (
        deliver_notification_with_retry() { return 0; }
        local notification_id="global|fixture_new_incident"
        fixture_notification_finding warning
        prepare_notification_lifecycle &&
            [[ "$NOTIFICATION_DECISION" == SEND && "$NOTIFICATION_RECOVERY_DEFERRED_COUNT" == 1 ]] &&
            process_notification_delivery fixture fixture warning || exit 1
        prepare_notification_lifecycle &&
            [[ "$NOTIFICATION_DECISION" == SUPPRESS && "$NOTIFICATION_RECOVERY_DEFERRED_COUNT" == 1 ]]
    ); then
        self_test_result 1 "Delivered findings deduplicate through failures without clearing other incidents"
    else
        self_test_result 0 "Delivered findings deduplicate through failures without clearing other incidents"
    fi

    local fake_bin_dir="$notification_dir/bin"
    local retry_notify="$fake_bin_dir/retry-notify"
    local failed_notify="$fake_bin_dir/failed-notify"
    local dry_notify="$fake_bin_dir/dry-notify"
    mkdir -p "$fake_bin_dir"
    # These single-quoted strings deliberately create a child-shell fixture.
    # shellcheck disable=SC2016
    printf '%s\n' \
        '#!/bin/bash' \
        'counter="${0}.count"' \
        'count=0' \
        '[[ -f "$counter" ]] && read -r count < "$counter"' \
        'count=$((count + 1))' \
        'printf "%s\\n" "$count" > "$counter"' \
        '(( count >= 2 ))' > "$retry_notify"
    printf '%s\n' '#!/bin/bash' 'exit 9' > "$failed_notify"
    # shellcheck disable=SC2016
    printf '%s\n' \
        '#!/bin/bash' \
        'printf "called\\n" >> "${0}.count"' \
        'exit 0' > "$dry_notify"
    printf '%s\n' '#!/bin/bash' 'exit 0' > "$fake_bin_dir/logger"
    chmod 700 "$retry_notify" "$failed_notify" "$dry_notify" "$fake_bin_dir/logger"
    PATH="$fake_bin_dir:$PATH"
    NOTIFICATION_MAX_ATTEMPTS=3
    NOTIFICATION_RETRY_INITIAL_DELAY_SECONDS=0
    NOTIFICATION_RETRY_MAX_DELAY_SECONDS=0
    NOTIFY_BIN="$retry_notify"
    if deliver_notification_with_retry "Fixture retry" "Fixture body" warning &&
       [[ "$NOTIFICATION_DELIVERY_ATTEMPTS" == "2" &&
          "$(<"${retry_notify}.count")" == "2" ]]
    then
        self_test_result 1 "Bounded notification retry recovery"
    else
        self_test_result 0 "Bounded notification retry recovery" \
            "attempts=$NOTIFICATION_DELIVERY_ATTEMPTS rc=$NOTIFICATION_DELIVERY_RC"
    fi

    printf 'known-good-journal\n' > "$NOTIFICATION_JOURNAL_FILE"
    journal_before="$(sha1sum "$NOTIFICATION_JOURNAL_FILE" | awk '{print $1}')"
    NOTIFY_BIN="$failed_notify"
    NOTIFICATION_MAX_ATTEMPTS=2
    # This fixture runs inside run_regression_tests()' isolated subshell.
    # shellcheck disable=SC2030
    NOTIFICATION_DECISION="SEND"
    NOTIFICATION_JOURNAL_COMMIT_ALLOWED=1
    NOTIFICATION_DRY_RUN=0
    local fixture_delivery_rc=0
    process_notification_delivery "Fixture failure" "Fixture body" warning || fixture_delivery_rc=$?
    journal_after="$(sha1sum "$NOTIFICATION_JOURNAL_FILE" | awk '{print $1}')"
    local failure_preserved=0 dry_run_preserved=0
    [[ "$fixture_delivery_rc" == 1 && "$journal_before" == "$journal_after" &&
       "$NOTIFICATION_DELIVERY_ATTEMPTS" == "2" ]] && failure_preserved=1

    NOTIFY_BIN="$dry_notify"
    NOTIFICATION_DRY_RUN=1
    process_notification_delivery "Fixture dry run" "Fixture body" warning
    journal_after="$(sha1sum "$NOTIFICATION_JOURNAL_FILE" | awk '{print $1}')"
    [[ ! -e "${dry_notify}.count" && "$journal_before" == "$journal_after" ]] &&
        dry_run_preserved=1
    if (( failure_preserved == 1 && dry_run_preserved == 1 )); then
        self_test_result 1 "Failed/dry-run delivery preserves notification journal"
    else
        self_test_result 0 "Failed/dry-run delivery preserves notification journal" \
            "failure_preserved=$failure_preserved dry_run_preserved=$dry_run_preserved"
    fi
    NOTIFICATION_DRY_RUN=0

    COLLECTOR_EVENT_FILE="$fixture_dir/collector_events.tsv"
    : > "$COLLECTOR_EVENT_FILE"
    CURRENT_COLLECTOR="timeout_fixture"
    COMMAND_KILL_GRACE_SECONDS=1
    local timeout_rc=0
    if run_bounded 1 "intentional timeout fixture" sleep 2; then
        timeout_rc=0
    else
        timeout_rc=$?
    fi
    actual=$(collector_event_count timeout_fixture TIMEOUT)
    if [[ "$timeout_rc" == "124" && "$actual" == "1" ]]; then
        self_test_result 1 "Bounded command timeout classification"
    else
        self_test_result 0 "Bounded command timeout classification" \
            "rc=$timeout_rc timeout_events=$actual"
    fi

    local protected_state="$fixture_dir/protected.state" protected_temp
    printf 'known-good\n' > "$protected_state"
    protected_temp="$(state_temp_file "$protected_state")"
    printf 'incomplete-replacement\n' > "$protected_temp"
    collector_atomic_commit "$protected_temp" "$protected_state"
    actual=$(<"$protected_state")
    if [[ "$actual" == "known-good" && ! -e "$protected_temp" ]]; then
        self_test_result 1 "Failed collector baseline preservation"
    else
        self_test_result 0 "Failed collector baseline preservation" "found '$actual'"
    fi

    local protected_history="$fixture_dir/protected.history"
    local protected_scalar="$fixture_dir/protected.scalar"
    printf '2026-08-15 disk_a temp=30 captured_epoch=1 schema=3\n' > "$protected_history"
    printf 'known-scalar\n' > "$protected_scalar"
    collector_replace_daily_history "$protected_history" 2026-08-15 \
        '2026-08-15 disk_a temp=99 captured_epoch=2 schema=3'
    collector_atomic_write_text "$protected_scalar" $'replacement-scalar\n'
    if grep -Fq 'temp=30 ' "$protected_history" &&
       [[ "$(<"$protected_scalar")" == "known-scalar" ]]
    then
        self_test_result 1 "Multi-file fault-injection baseline preservation"
    else
        self_test_result 0 "Multi-file fault-injection baseline preservation"
    fi

    printf 'smart\tFAILED\tsmartctl /dev/sdaa\trc=2\n' > "$COLLECTOR_EVENT_FILE"
    if ! collector_device_has_blocking_event smart /dev/sda &&
       collector_device_has_blocking_event smart /dev/sdaa
    then
        self_test_result 1 "Exact per-device collector failure isolation"
    else
        self_test_result 0 "Exact per-device collector failure isolation"
    fi

    : > "$COLLECTOR_EVENT_FILE"
    COLLECTOR_ORDER=()
    COLLECTOR_LABEL=()
    COLLECTOR_STATUS=()
    COLLECTOR_DURATION=()
    COLLECTOR_DETAIL=()
    COLLECTOR_FAILURE_NOTIFICATIONS=0
    COLLECTOR_SLOW_SECONDS=0
    # Invoked indirectly through run_collector.
    # shellcheck disable=SC2329
    fixture_deferred_collector() {
        record_collector_event DEFERRED "fixture device" "standby"
        return 0
    }
    # Invoked indirectly through run_collector.
    # shellcheck disable=SC2329
    fixture_failed_collector() {
        return 7
    }
    run_collector deferred_fixture "Deferred fixture" fixture_deferred_collector
    run_collector failed_fixture "Failed fixture" fixture_failed_collector
    if [[ "${COLLECTOR_STATUS[deferred_fixture]:-}" == "DEFERRED" &&
          "${COLLECTOR_STATUS[failed_fixture]:-}" == "FAILED" &&
          "$LAST_COLLECTOR_RC" == "7" ]]
    then
        self_test_result 1 "Collector deferred and failed status aggregation"
    else
        self_test_result 0 "Collector deferred and failed status aggregation" \
            "deferred=${COLLECTOR_STATUS[deferred_fixture]:-unset} failed=${COLLECTOR_STATUS[failed_fixture]:-unset} rc=$LAST_COLLECTOR_RC"
    fi

    if (
        local MASTER_LOG="$fixture_dir/trend-render.log"
        local -A WRITER_DAILY=([/dev/nvme0n1]=1000000000)
        local -A WRITER_DIRECTION=([/dev/nvme0n1]=COLLECTING)
        TREND_DIAGNOSTIC_ITEMS=()
        log_health_trends &&
            grep -Fq 'phase=TREND | write workload: device=nvme0n1 bytes_per_day=1000000000' "$MASTER_LOG" &&
            ! grep -Fq 'days_left=' "$MASTER_LOG"
    ); then
        self_test_result 1 "Raw trend diagnostics retained in run log"
    else
        self_test_result 0 "Raw trend diagnostics retained in run log"
    fi

    if (
        local SATA_LINK_HISTORY_FILE="$fixture_dir/sata-link-alert.log"
        local day
        local emitted=""
        record_alert() { emitted="$1 $2 $3"; }
        SATA_LINK_INSTABILITY_ENABLED=1
        SATA_LINK_INSTABILITY_STREAK_WARN=2
        SATA_LINK_INSTABILITY_STREAK_CRIT=5
        DEVICE_PATH_BY_ID=([fixture_sata]=/dev/sdz)
        TREND_HISTORY_CACHE=()
        for day in "$(date -d yesterday +%F)" "$(date +%F)"; do
            printf '%s fixture_sata max=6 current=3\n' "$day"
        done > "$SATA_LINK_HISTORY_FILE"
        analyze_sata_link_trends &&
            [[ "$emitted" == 'warning SATA Link Instability Disk /dev/sdz link downshift streak 2 days'* ]]
    ); then
        self_test_result 1 "SATA link streak still raises an actionable finding"
    else
        self_test_result 0 "SATA link streak still raises an actionable finding"
    fi

    if (
        local attrs=$'241 Host_Writes_GiB 0x0032 100 100 000 Old_age Always - 66351\n242 Host_Reads_GiB 0x0032 100 100 000 Old_age Always - 67905'
        [[ "$(ata_host_counter_bytes "$attrs" writes)" == 71243843764224 &&
           "$(ata_host_counter_bytes "$attrs" reads)" == 72912438558720 ]] &&
        ! ata_host_counter_bytes '241 Unknown_Attribute 0x0032 100 100 000 Old_age Always - 66351' writes &&
        ! ata_host_counter_bytes '233 NAND_GB_Written_TLC 0x0032 100 100 000 Old_age Always - 61796' writes
    ); then self_test_result 1 "WD host GiB units and unknown/NAND counters remain distinct"
    else self_test_result 0 "WD host GiB units and unknown/NAND counters remain distinct"; fi

    if (
        [[ "$(tbw_threshold_tb_for_device 'WDC WDS500G1R0A-68A4W0' .500107862016)" == 350 &&
           "$(tbw_threshold_tb_for_device CT1000T500SSD5 1.000204886)" == 600 &&
           "$(tbw_threshold_tb_for_device CT1000T500SSD8 1.000204886)" == 600 &&
           "$(tbw_threshold_tb_for_device CT1000P5PSSD8 1.000204886)" == 600 &&
           -z "$(tbw_threshold_tb_for_device UnknownSSD 1)" ]]
    ); then self_test_result 1 "Native WD and Crucial model numbers select rated TBW"
    else self_test_result 0 "Native WD and Crucial model numbers select rated TBW"; fi

    if (
        local SHORT_TEST_INTERVAL_DAYS=7 disk=/dev/sdz
        LAST_TEST_EPOCH[$disk]=$(date -d '7 days ago 23:59' +%s)
        short_test_is_due "$disk" && [[ "$(short_test_next_date "$disk")" == "$(date +%F) 00:00" ]]
    ); then self_test_result 1 "Weekly self-test eligibility tolerates daily start-time jitter"
    else self_test_result 0 "Weekly self-test eligibility tolerates daily start-time jitter"; fi

    if (
        local STATE_DIR="$fixture_dir/units" TBW_HISTORY_FILE="$fixture_dir/units/tbw_history.log" disk=/dev/sdz
        mkdir -m 700 "$STATE_DIR"
        DEVICE_ID_BY_PATH[$disk]=fixture_units
        PREV_ATTR["$disk|udma"]=12
        PREV_ATTR["$disk|pending"]=2
        PREV_ATTR["$disk|tbw_bytes"]=100
        printf '2026-11-26 fixture_units tbw=100\n2026-11-26 unrelated tbw=200\n' > "$TBW_HISTORY_FILE"
        rebaseline_ata_host_writes "$disk" &&
        [[ "${CUR_ATTR["$disk|host_write_units_revision"]}" == 2 &&
           "${PREV_ATTR["$disk|udma"]}" == 12 && "${PREV_ATTR["$disk|pending"]}" == 2 &&
           -z "${PREV_ATTR["$disk|tbw_bytes"]:-}" && "$(wc -l < "$TBW_HISTORY_FILE")" == 1 ]]
    ); then self_test_result 1 "Unit migration resets only affected write history, retaining fault counters"
    else self_test_result 0 "Unit migration resets only affected write history, retaining fault counters"; fi

    if (
        local SMART_LONG_STARTED=1 SMART_FLEET_LONG_RUNNING=0
        mdcmd() { printf 'mdResync=0\nmdResyncAction=\n'; }
        timeout() { shift; "$@"; }
        pgrep() { return 1; }
        findmnt() { :; }
        flock() { return 0; }
        ! smart_test_start_allowed long && smart_test_start_allowed short
    ); then self_test_result 1 "Only one new long self-test; short collection remains independently eligible"
    else self_test_result 0 "Only one new long self-test; short collection remains independently eligible"; fi

    if (
        flock() { return 0; }
        timeout() { shift; "$@"; }
        findmnt() { :; }
        pgrep() { return 1; }
        mdcmd() { printf 'mdResync=123\nmdResyncAction=check\n'; }
        ! smart_test_start_allowed short &&
        mdcmd() { printf 'mdResync=0\nmdResyncAction=check\n'; } &&
        smart_test_start_allowed short &&
        pgrep() { return 0; } && ! smart_test_start_allowed short
    ); then self_test_result 1 "Active parity and Mover defer new tests; stale action text does not"
    else self_test_result 0 "Active parity and Mover defer new tests; stale action text does not"; fi

    if (
        local disk=/dev/sdz fixture_overall=PASSED fixture_crc=12 fixture_pending=0
        get_sata_raw() { printf '%s\n' \
            '5 Reallocated_Sector_Ct 0x0033 100 100 010 Pre-fail Always - 0' \
            '9 Power_On_Hours 0x0032 095 095 000 Old_age Always - 7000' \
            '194 Temperature_Celsius 0x0022 068 050 000 Old_age Always - 32' \
            "197 Current_Pending_Sector 0x0012 100 100 000 Old_age Always - $fixture_pending" \
            '198 Offline_Uncorrectable 0x0030 100 100 000 Old_age Offline - 0' \
            "199 UDMA_CRC_Error_Count 0x003e 200 200 000 Old_age Always - $fixture_crc" \
            '230 Media_Wearout_Indicator 0x0032 004 004 000 Old_age Always - 1040' \
            '241 Host_Writes_GiB 0x0032 100 100 000 Old_age Always - 27187'; }
        smartctl_cached() { printf 'SMART overall-health self-assessment test result: %s\n' "$fixture_overall"; }
        get_sata_info() { :; }
        get_device_model() { printf 'WDC WDS500G1R0A-68A4W0'; }
        get_device_capacity_tb() { printf '0.500'; }
        lsblk_rota_cached() { printf 0; }
        get_latest_selftest_info() { printf '1|Short|Completed without error|7000|0%%'; }
        collector_upsert_daily_history() { :; }
        rebaseline_ata_host_writes() { :; }
        PREV_ATTR["$disk|udma"]=12
        evaluate_smart "$disk" && [[ "${SMART_STATE[$disk]}" == OK && -z "${CUR_ATTR["$disk|life_remain"]:-}" ]] || exit 1
        fixture_crc=13
        evaluate_smart "$disk" && [[ "${SMART_STATE[$disk]}" == WARNING ]] || exit 1
        fixture_crc=12; fixture_pending=2
        evaluate_smart "$disk" && [[ "${SMART_STATE[$disk]}" == CRITICAL ]] || exit 1
        fixture_pending=0; fixture_overall=FAILED
        evaluate_smart "$disk" && [[ "${SMART_STATE[$disk]}" == CRITICAL && "${SMART_MSGS[$disk]}" == *'overall health FAILED'* ]]
    ); then self_test_result 1 "Historic CRC and ambiguous wear stay informational; CRC growth, pending sectors and native SMART failure remain actionable"
    else self_test_result 0 "Historic CRC and ambiguous wear stay informational; CRC growth, pending sectors and native SMART failure remain actionable"; fi

    if (
        [[ "$(selftest_current_operation /dev/nvme0n1 '' 'Self-test status: No self-test in progress')" == idle &&
           "$(selftest_current_operation /dev/nvme0n1 '' 'Self-test status: Short self-test in progress (10% completed)')" == short &&
           "$(selftest_current_operation /dev/nvme0n1 '' 'Self-test status: Extended self-test in progress (10% completed)')" == long &&
           "$(selftest_current_operation /dev/nvme0n1 '' 'garbled response')" == unknown &&
           "$(selftest_current_operation /dev/sdz 'Self-test execution status: ( 249) Self-test routine in progress...' '')" == running &&
           "$(selftest_current_operation /dev/sdz 'Self-test execution status: ( 0) The previous self-test routine completed' '')" == idle ]]
    ); then self_test_result 1 "Explicit current-operation parsing separates idle, running and unknown status"
    else self_test_result 0 "Explicit current-operation parsing separates idle, running and unknown status"; fi

    if (
        local disk=/dev/sdz RUN_EPOCH=1795750200 id=fixture_calendar
        DEVICE_ID_BY_PATH[$disk]="$id"
        TEST_TRACK=()
        LAST_TEST_EPOCH[$disk]="$RUN_EPOCH"
        ensure_test_tracking_device "$disk" &&
        [[ "$(test_track_get "$id" longObserved)" == 0 ]] &&
        ! calendar_test_due "$disk" long 120 &&
        RUN_EPOCH=$((RUN_EPOCH+8*86400)) && calendar_test_due "$disk" long 120
    ); then self_test_result 1 "Long baseline adoption has bounded grace and never fabricates success"
    else self_test_result 0 "Long baseline adoption has bounded grace and never fabricates success"; fi

    if (
        local disk=/dev/sdz RUN_EPOCH id=fixture_calendar
        RUN_EPOCH=$(date -d 'today 06:30' +%s)
        DEVICE_ID_BY_PATH[$disk]="$id"
        TEST_TRACK=()
        TEST_TRACK["$id|shortAnchor"]=$(date -d '7 days ago 06:32' +%s)
        calendar_test_due "$disk" short 7
    ); then self_test_result 1 "Successful-result calendar scheduling tolerates daily run jitter"
    else self_test_result 0 "Successful-result calendar scheduling tolerates daily run jitter"; fi

    if (
        local disk=/dev/nvme9n1 id=fixture_observation RUN_EPOCH=1795750200
        local first=$'Self-test status: No self-test in progress\n 0 Short Completed without error 100 - - - - -'
        local second=${first/100/110}
        DEVICE_ID_BY_PATH[$disk]="$id"
        TEST_TRACK=(); SMART_OPERATION[$disk]=idle
        ensure_test_tracking_device "$disk"
        observe_test_results "$disk" "$first" 120 && [[ "$(test_track_get "$id" shortObserved)" == 0 ]] || exit 1
        observe_test_results "$disk" "$second" 120 && [[ "$(test_track_get "$id" shortObserved)" == "$RUN_EPOCH" ]]
    ); then self_test_result 1 "Historical log adoption is not fresh success; a changed native success is"
    else self_test_result 0 "Historical log adoption is not fresh success; a changed native success is"; fi

    if (
        local disk=/dev/nvme9n1 id=fixture_pending RUN_EPOCH=1795750200
        local history=$'Self-test status: No self-test in progress\n 0 Extended Completed without error 110 - - - - -'
        DEVICE_ID_BY_PATH[$disk]="$id"; TEST_TRACK=(); SMART_OPERATION[$disk]=idle
        TEST_TRACK["$id|pending"]=1; TEST_TRACK["$id|startEpoch"]=$((RUN_EPOCH-86400))
        TEST_TRACK["$id|startPOH"]=105; TEST_TRACK["$id|startKind"]=long; TEST_TRACK["$id|startToken"]=none
        observe_test_results "$disk" "$history" 120 &&
        [[ "$(test_track_get "$id" pending)" == 0 && "$(test_track_get "$id" longObserved)" == "$RUN_EPOCH" ]]
    ); then self_test_result 1 "Pending long start reconciles only with a matching newer successful result"
    else self_test_result 0 "Pending long start reconciles only with a matching newer successful result"; fi

    if (
        local disk=/dev/nvme9n1 id=fixture_failure RUN_EPOCH=1795750200
        local history=$'Self-test status: No self-test in progress\n 0 Extended Aborted: Controller Reset 110 - - - - -'
        DEVICE_ID_BY_PATH[$disk]="$id"; TEST_TRACK=(); SMART_OPERATION[$disk]=idle
        TEST_TRACK["$id|pending"]=1; TEST_TRACK["$id|startEpoch"]=$((RUN_EPOCH-86400))
        TEST_TRACK["$id|startPOH"]=105; TEST_TRACK["$id|startKind"]=long; TEST_TRACK["$id|startToken"]=none
        observe_test_results "$disk" "$history" 120 &&
        [[ "$(test_track_get "$id" pending)" == 0 && "$(test_track_get "$id" longObserved)" == 0 ]]
    ); then self_test_result 1 "An aborted test never advances successful coverage"
    else self_test_result 0 "An aborted test never advances successful coverage"; fi

    if (
        local disk=/dev/nvme9n1 id=fixture_unverified RUN_EPOCH=1795750200 emitted=''
        DEVICE_ID_BY_PATH[$disk]="$id"; TEST_TRACK=(); SMART_OPERATION[$disk]=idle
        TEST_TRACK["$id|pending"]=1; TEST_TRACK["$id|startEpoch"]=$((RUN_EPOCH-4*86400))
        TEST_TRACK["$id|startKind"]=short; TEST_TRACK["$id|startPOH"]=105
        record_finding() { emitted="$*"; }
        observe_test_results "$disk" 'Self-test status: No self-test in progress' 120 &&
        [[ "$(test_track_get "$id" pending)" == 0 && "$(test_track_get "$id" unverified)" == 1 && "$emitted" == *'result overdue'* ]] || exit 1
        emitted=''
        observe_test_results "$disk" 'Self-test status: No self-test in progress' 120 && [[ "$emitted" == *'result overdue'* ]]
    ); then self_test_result 1 "Missing completion stays unverified across retries instead of falsely recovering"
    else self_test_result 0 "Missing completion stays unverified across retries instead of falsely recovering"; fi

    if (
        local STATE_DIR="$fixture_dir/tracker" RUN_DIR="$fixture_dir/tracker/run" RUN_EPOCH=1795750200
        local SMART_TEST_TRACKING_FILE="$STATE_DIR/tracking.json"
        mkdir -m 700 "$STATE_DIR" "$RUN_DIR"
        TEST_TRACK=([fixture_id\|firstSeen]=1795750200 [fixture_id\|shortToken]=none)
        SMART_TEST_TRACKING_READY=1
        persist_test_tracking && TEST_TRACK=() && load_test_tracking && [[ "$(test_track_get fixture_id firstSeen)" == 1795750200 ]] || exit 1
        printf '{"schema":99,"devices":{}}' > "$SMART_TEST_TRACKING_FILE"
        ! load_test_tracking
    ); then self_test_result 1 "Atomic calendar receipts round-trip; future schemas withhold maintenance"
    else self_test_result 0 "Atomic calendar receipts round-trip; future schemas withhold maintenance"; fi

    if (
        local RUN_EPOCH=1795750200 SMART_FLEET_TEST_RUNNING=0 SMART_FLEET_STATUS_UNKNOWN=0
        local wakes=0 disk=/dev/sdy other=/dev/sdz
        DEVICE_ID_BY_PATH[$disk]=wake_a; DEVICE_ID_BY_PATH[$other]=wake_b
        TEST_TRACK=([wake_a\|shortAnchor]=$((RUN_EPOCH-40*86400)) [wake_b\|shortAnchor]=$((RUN_EPOCH-39*86400)))
        SATA_POWER_STATE=([$disk]=standby [$other]=standby)
        maintenance_window_open() { return 0; }; smart_test_start_allowed() { return 0; }
        lsblk_rota_cached() { printf 1; }
        run_bounded_checked() { wakes=$((wakes+1)); return 0; }
        refresh_sata_power_state() { SATA_POWER_STATE[$1]=active; }
        select_overdue_wake "$disk" "$other"
        [[ "$wakes" == 1 && "$SMART_WAKE_SELECTED" == "$disk" && "${SATA_POWER_STATE[$other]}" == standby ]]
    ); then self_test_result 1 "Controlled overdue maintenance wakes at most one oldest eligible sleeping disk"
    else self_test_result 0 "Controlled overdue maintenance wakes at most one oldest eligible sleeping disk"; fi

    if (
        local RUN_EPOCH=1795750200 SMART_FLEET_TEST_RUNNING=1 wakes=0
        maintenance_window_open() { return 0; }
        run_bounded_checked() { wakes=$((wakes+1)); }
        select_overdue_wake /dev/sdz && [[ "$wakes" == 0 ]]
    ); then self_test_result 1 "Existing self-tests prevent overdue wake work"
    else self_test_result 0 "Existing self-tests prevent overdue wake work"; fi

    if (
        local RUN_EPOCH=1795750200 DOCKER_SCRUB_TRACKING_FILE="$fixture_dir/docker-scrub.json"
        local dispatched='' journalled=false SMART_FLEET_TEST_RUNNING=0 SMART_FLEET_STATUS_UNKNOWN=0
        findmnt() { case "$*" in *FSTYPE*) printf btrfs;; *UUID*) printf '11111111-2222-3333-4444-555555555555';; esac; }
        date() { case "$*" in +%Y-%m) printf 2026-11;; +%d) printf 27;; *) command date "$@";; esac; }
        btrfs_bounded_optional() {
            if [[ "$*" == 'scrub status /var/lib/docker' ]]; then printf 'no stats available\n'; return 1; fi
            dispatched="$*"; [[ "$journalled" == true ]] || return 1
        }
        maintenance_window_open() { return 0; }; smart_test_start_allowed() { return 0; }
        atomic_write_text() { printf '%s' "$2" > "$1"; journalled=true; }
        maintain_docker_scrub && [[ "$dispatched" == 'scrub start -r /var/lib/docker' && "$DOCKER_SCRUB_STARTED" == 1 ]] &&
        jq -e '.pending and .requests==1' "$DOCKER_SCRUB_TRACKING_FILE" >/dev/null
    ); then self_test_result 1 "Docker scrub is read-only and journaled before dispatch"
    else self_test_result 0 "Docker scrub is read-only and journaled before dispatch"; fi

    if (
        local RUN_EPOCH=1795750200 DOCKER_SCRUB_TRACKING_FILE="$fixture_dir/docker-verified.json" dispatched=0
        printf '{"schema":1,"uuid":"11111111-2222-3333-4444-555555555555","pending":false,"requests":1,"requestedEpoch":0,"requestMonth":"2026-11","lastSuccessEpoch":1795740000}' > "$DOCKER_SCRUB_TRACKING_FILE"
        findmnt() { case "$*" in *FSTYPE*) printf btrfs;; *UUID*) printf '11111111-2222-3333-4444-555555555555';; esac; }
        btrfs_bounded_optional() { if [[ "$2" == status ]]; then printf 'no stats available\n'; return 1; fi; dispatched=$((dispatched+1)); }
        maintain_docker_scrub && [[ "$dispatched" == 0 ]]
    ); then self_test_result 1 "Reboot-cleared native scrub status does not repeat a verified monthly scrub"
    else self_test_result 0 "Reboot-cleared native scrub status does not repeat a verified monthly scrub"; fi

    if (
        local DOCKER_SCRUB_TRACKING_FILE="$fixture_dir/docker-retry-cap.json" RUN_EPOCH=1795750200 dispatched=0
        printf '{"schema":1,"uuid":"11111111-2222-3333-4444-555555555555","pending":true,"requests":3,"requestedEpoch":1795400000,"requestMonth":"2026-11","lastSuccessEpoch":0}' > "$DOCKER_SCRUB_TRACKING_FILE"
        findmnt() { case "$*" in *FSTYPE*) printf btrfs;; *UUID*) printf '11111111-2222-3333-4444-555555555555';; esac; }
        btrfs_bounded_optional() { if [[ "$2" == status ]]; then printf 'no stats available\n'; return 1; fi; dispatched=$((dispatched+1)); }
        record_finding() { :; }
        maintain_docker_scrub && [[ "$dispatched" == 0 ]]
    ); then self_test_result 1 "Monthly scrub retries remain capped after interrupted requests"
    else self_test_result 0 "Monthly scrub retries remain capped after interrupted requests"; fi

    if (
        local disk=/dev/nvme9n1 id=fixture_start RUN_EPOCH=1795750200
        local STATE_DIR="$fixture_dir/start-journal" RUN_DIR="$fixture_dir/start-journal/run"
        local SMART_TEST_TRACKING_FILE="$STATE_DIR/tracking.json" trace="$STATE_DIR/dispatch"
        mkdir -m 700 "$STATE_DIR" "$RUN_DIR"
        DEVICE_ID_BY_PATH[$disk]="$id"; TEST_TRACK=(); SMART_TEST_TRACKING_READY=1
        SMART_OPERATION[$disk]=idle
        LAST_TEST_EPOCH[$disk]=$((RUN_EPOCH-8*86400))
        ensure_test_tracking_device "$disk"
        smartctl_bounded() {
            case "$*" in
                '-t short -d nvme /dev/nvme9n1')
                    jq -e '.devices.fixture_start|.pending=="1" and .startKind=="short" and .startPOH=="120"' "$SMART_TEST_TRACKING_FILE" >/dev/null || return 2
                    printf accepted > "$trace"; printf 'Self-test has begun\n' ;;
                *) printf 'Self-test status: No self-test in progress\n 0 Short Completed without error 100 - - - - -\n' ;;
            esac
        }
        smartctl_cached() { printf 'Power On Hours: 120\n'; }
        nvme_smart_output_is_complete() { return 0; }
        collector_device_has_blocking_event() { return 1; }
        evaluate_smart() { SMART_STATE[$1]=OK; SMART_MSGS[$1]=''; }
        smart_test_start_allowed() { return 0; }
        save_selftest_snapshot() { :; }; invalidate_smart_cache() { :; }
        run_smart_test "$disk" && [[ "$(cat "$trace")" == accepted && "$(test_track_get "$id" pending)" == 1 && "$(test_track_get "$id" shortObserved)" == 0 ]]
    ); then self_test_result 1 "Actual test dispatch requires a durable pre-start journal and never immediately claims success"
    else self_test_result 0 "Actual test dispatch requires a durable pre-start journal and never immediately claims success"; fi

    if (
        local disk=/dev/nvme9n1 id=fixture_unrelated RUN_EPOCH=1795750200
        DEVICE_ID_BY_PATH[$disk]="$id"; SMART_OPERATION[$disk]=idle; TEST_TRACK=()
        TEST_TRACK["$id|unverified"]=1; TEST_TRACK["$id|unverifiedKind"]=long
        TEST_TRACK["$id|unverifiedSince"]=$((RUN_EPOCH-86400))
        TEST_TRACK["$id|shortToken"]=$(printf 'short|Completed without error|100' | sha256sum | cut -d' ' -f1)
        record_finding() { :; }
        observe_test_results "$disk" $'Self-test status: No self-test in progress\n 0 Short Completed without error 110 - - - - -' 120 &&
        [[ "$(test_track_get "$id" shortObserved)" == "$RUN_EPOCH" && "$(test_track_get "$id" unverified)" == 1 ]]
    ); then self_test_result 1 "Unrelated short success cannot clear an unverified long test"
    else self_test_result 0 "Unrelated short success cannot clear an unverified long test"; fi

    if (( SELF_TEST_TOTAL != REGRESSION_FIXTURE_COUNT )); then
        SELF_TEST_FAILED=$((SELF_TEST_FAILED + 1))
        printf '[FAIL] Fixture manifest count - expected=%d actual=%d\n' \
            "$REGRESSION_FIXTURE_COUNT" "$SELF_TEST_TOTAL"
    fi
    printf '\nSelf-test summary: passed=%d failed=%d total=%d\n' \
        "$SELF_TEST_PASSED" "$SELF_TEST_FAILED" "$SELF_TEST_TOTAL"
    (( SELF_TEST_FAILED == 0 ))
)

validate_configuration || exit 1
validate_runtime_dependencies self-test || exit 1
run_regression_tests
