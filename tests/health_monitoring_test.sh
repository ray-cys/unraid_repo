#!/bin/bash
# Fixtures source the monitor's functions and use temporary paths and mock commands.
# shellcheck disable=SC2034,SC2155
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../user_script/health_monitoring.sh
source "$REPO_ROOT/user_script/health_monitoring.sh"

readonly REGRESSION_FIXTURE_COUNT=99

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
          "$HEAVY_WRITER_ALERTS_ENABLED" == "1" &&
          "$ARRAY_WRITER_ALERTS_ENABLED" == "1" &&
          "$POOL_WRITER_ALERTS_ENABLED" == "0" &&
          "$SHOW_STORAGE_DEVICE_DETAILS" == "0" &&
          "$NOTIFICATION_OK_REMINDER_HOURS" == "0" &&
          "$NOTIFICATION_RECOVERY_CONFIRM_RUNS" == "2" &&
          "$HEAVY_WRITER_RECENT_DAYS" == "3" &&
          "$SOAK_TELEMETRY_ENABLED" == "1" ]]
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
    RISK_MAP=()
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
          -n "${EXTERNAL_CONFIG_ALLOWED[SOAK_MIN_RUNS]+present}" &&
          -n "${EXTERNAL_CONFIG_ALLOWED[TREND_NOTIFICATION_MODE]+present}" &&
          -n "${EXTERNAL_CONFIG_ALLOWED[TREND_NOTIFICATION_TOP_N]+present}" &&
          -n "${EXTERNAL_CONFIG_ALLOWED[POOL_WRITER_POLICY]+present}" &&
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
        'SHOW_COLLECTOR_STATUS="always"' \
        'SOAK_MIN_RUNS=20' \
        'POOL_EXCLUDES=ramtmp, user0' > "$EXTERNAL_CONFIG_FILE"
    # This is deliberately inert parser input, not a command to expand here.
    # shellcheck disable=SC2016
    printf -v inert_config_value '$(touch %s/executed)' "$config_fixture_dir"
    printf 'XFS_PROC_KEYS=%s\n' "$inert_config_value" >> "$EXTERNAL_CONFIG_FILE"
    chmod 600 "$EXTERNAL_CONFIG_FILE"
    # shellcheck disable=SC2030
    SMART_ALLOW_SPINUP=0
    WARN_THRESHOLD_PERCENT=96
    SHOW_COLLECTOR_STATUS="auto"
    SOAK_MIN_RUNS=14
    POOL_EXCLUDES=(original)
    if load_external_configuration &&
       [[ "$EXTERNAL_CONFIG_STATUS" == "LOADED" &&
          "$EXTERNAL_CONFIG_OVERRIDE_COUNT" == "6" &&
          "$SMART_ALLOW_SPINUP" == "1" &&
          "$WARN_THRESHOLD_PERCENT" == "95" &&
          "$SHOW_COLLECTOR_STATUS" == "always" &&
          "$SOAK_MIN_RUNS" == "20" &&
          "${POOL_EXCLUDES[*]}" == "ramtmp user0" &&
          "$XFS_PROC_KEYS" == "$inert_config_value" &&
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
       grep -Fq '# SOAK_MIN_RUNS=14' "$EXTERNAL_CONFIG_FILE" &&
       ! grep -Eq '^# (TREND_NOTIFICATION_MODE|SHOW_STORAGE_DEVICE_DETAILS)=' "$EXTERNAL_CONFIG_FILE" &&
       grep -Fq '# HEAVY_WRITER_ALERTS_ENABLED=1' "$EXTERNAL_CONFIG_FILE" &&
       grep -Fq '# POOL_WRITER_POLICY=cache:100:350,data:500:1000' "$EXTERNAL_CONFIG_FILE" &&
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
    SHOW_COLLECTOR_STATUS="auto"
    POOL_EXCLUDES=(ramtmp user0)
    XFS_PROC_KEYS=""
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

    (
        local alerts=0
        record_alert() { alerts=$((alerts+1)); }
        lsblk_rota_cached() { printf '1\n'; }
        TEMP_RATE_ALERT_ENABLED=1; HDD_TEMP_WARNING=45
        RUN_EPOCH=123456; FRESH_SMART[/dev/sdz]=1
        record_temperature_approach /dev/sdz 30 "$RUN_EPOCH" 10 2 HIGH
        (( alerts==0 ))
    ) && self_test_result 1 "Cool drives do not raise temperature-rate warnings" || self_test_result 0 "Cool drives do not raise temperature-rate warnings"
    (
        local alerts=0
        record_alert() { alerts=$((alerts+1)); }
        lsblk_rota_cached() { printf '1\n'; }
        TEMP_RATE_ALERT_ENABLED=1; HDD_TEMP_WARNING=45
        RUN_EPOCH=123456; FRESH_SMART[/dev/sdz]=1
        record_temperature_approach /dev/sdz 42 "$RUN_EPOCH" 10 2 HIGH
        (( alerts==1 ))
    ) && self_test_result 1 "Fresh hot drives retain temperature approach warnings" || self_test_result 0 "Fresh hot drives retain temperature approach warnings"
    (
        local alerts=0
        record_alert() { alerts=$((alerts+1)); }
        lsblk_rota_cached() { printf '1\n'; }
        TEMP_RATE_ALERT_ENABLED=1; HDD_TEMP_WARNING=45
        RUN_EPOCH=123456; FRESH_SMART[/dev/sdz]=1
        record_temperature_approach /dev/sdz 42 100000 10 2 HIGH
        record_temperature_approach /dev/sdz 42 "$RUN_EPOCH" 10 2 STALE
        (( alerts==0 ))
    ) && self_test_result 1 "Stale readings cannot raise temperature approach warnings" || self_test_result 0 "Stale readings cannot raise temperature approach warnings"

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
            [[ "${SMART_STATE[$device]}" == OK && "${#FINDING_IDS[@]}" == 0 ]] &&
            grep -Fq 'replacement-planning threshold' "$MASTER_LOG" || exit 1
        evaluate_scsi_smart "$device" "${age_only_sas_fixture/34 C/70 C}" &&
            [[ "${SMART_STATE[$device]}" == CRITICAL &&
               "${FINDING_SEVERITY["device:$device|temp"]:-}" == critical ]]
    ); then
        self_test_result 1 "Drive age is advisory while actual overheating stays critical"
    else
        self_test_result 0 "Drive age is advisory while actual overheating stays critical"
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

    local xfs_fixture
    xfs_fixture=$'extent_alloc 17 2 3 4\ndir_lookup malformed\nxs_xstrat 23 0 0 0'
    actual="$(xfs_stat_value_from_text "$xfs_fixture" extent_alloc)|$(xfs_stat_value_from_text "$xfs_fixture" dir_lookup)|$(xfs_stat_value_from_text "$xfs_fixture" xs_xstrat)"
    if [[ "$actual" == "17||23" ]]; then
        self_test_result 1 "XFS counter parser fixtures"
    else
        self_test_result 0 "XFS counter parser fixtures" "found '$actual'"
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
    RISK_SPIKE_TS=()
    MOUNT_TO_DEV=([/mnt/disk1]="/dev/sda")
    POOL_MEMBER_MAP=([/dev/nvme0n1]="cache" [/dev/nvme1n1]="data")
    HEAVY_WRITER_ALERTS_ENABLED=1
    ARRAY_WRITER_ALERTS_ENABLED=1
    POOL_WRITER_ALERTS_ENABLED=0
    record_writer_workload_alert /dev/nvme0n1 600 880000000000 RISING 25.0 3 2
    record_writer_workload_alert /dev/sda 6 30000000000 RISING 40.0 3 2
    local workload_gated_count=${#FINDING_IDS[@]}
    record_writer_workload_alert /dev/sda 6 30000000000 RISING 60.0 3 2
    local workload_finding_id="${FINDING_IDS[0]:-}"
    set_writer_policy_for_device /dev/nvme0n1
    classify_writer_tier 89.3 "$WRITER_POLICY_MODERATE_PCT" \
        "$WRITER_POLICY_WARN_PCT" "$WRITER_POLICY_CRIT_PCT"
    local cache_workload_tier="$WRITER_TIER_RESULT"
    set_writer_policy_for_device /dev/nvme1n1
    classify_writer_tier 617.7 "$WRITER_POLICY_MODERATE_PCT" \
        "$WRITER_POLICY_WARN_PCT" "$WRITER_POLICY_CRIT_PCT"
    local download_workload_tier="$WRITER_TIER_RESULT"
    if (( workload_gated_count == 0 && ${#FINDING_IDS[@]} == 1 )) &&
       [[ -n "$workload_finding_id" &&
          "${FINDING_SEVERITY[$workload_finding_id]:-}" == "warning" &&
          "${FINDING_SIGNAL[$workload_finding_id]:-}" == "workload.write_rate" &&
          "$cache_workload_tier" == "M" && "$download_workload_tier" == "H" &&
          -z "${RISK_SPIKE_TS[/dev/sda]:-}" ]]
    then
        self_test_result 1 "Role-aware workload policy and sustained array anomaly gates"
    else
        self_test_result 0 "Role-aware workload policy and sustained array anomaly gates" \
            "gated_count=$workload_gated_count enabled_count=${#FINDING_IDS[@]} cache=$cache_workload_tier data=$download_workload_tier"
    fi
    HEAVY_WRITER_ALERTS_ENABLED=1
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
    RISK_SPIKE_TS=()

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
    RISK_MAP=()
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
    RISK_MAP['/dev/sda']=90
    RISK_MAP['/dev/sdc']=40
    RISK_MAP['/dev/sdb']=20

    local risk_sort_stderr="$fixture_dir/risk-sort.stderr"
    actual=$(emit_sorted_finding_ids 2> "$risk_sort_stderr" | awk '{printf "%s%s", separator, $0; separator="|"}')
    if [[ "$actual" == 'device:/dev/sda|pending_sectors|device:/dev/sda|command_timeout|device:/dev/sdc|selftest_failed|device:/dev/sdb|capacity_warning|mount:/mnt/disk2|storage_warning' &&
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
    RISK_MAP=()
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
    SUBJECT="Disks Health - WARNING (1)"
    NOTIFY_MAX_BODY_CHARS=12000
    NOTIFY_MAX_BODY_LINES=180
    SHOW_STORAGE_DEVICE_DETAILS=1
    TREND_NOTIFICATION_MODE="detailed"
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
               "${FRESH_STORAGE[$storage_fixture/disk1]:-}" == 1 && "$alerts" == 3 ]]
    ); then
        self_test_result 1 "One capacity sample drives per-mount alerts, totals, and recovery"
    else
        self_test_result 0 "One capacity sample drives per-mount alerts, totals, and recovery"
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
    RISK_MAP=()
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
          "$SUBJECT" == "Disks Health - RECOVERED (1)" ]]
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
          "$NOTIFICATION_JOURNAL_COMMIT_ALLOWED" == "0" ]]
    then
        self_test_result 1 "Incomplete collector blocks false recovery"
    else
        self_test_result 0 "Incomplete collector blocks false recovery" \
            "decision=$NOTIFICATION_DECISION resolved=$NOTIFICATION_RESOLVED_COUNT deferred=$NOTIFICATION_RECOVERY_DEFERRED_COUNT"
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
        local -A TBW_DAYS_LEFT=([/dev/nvme0n1]=500)
        local -A TBW_DAILY=([/dev/nvme0n1]=1000000000)
        local -A TBW_FORECAST_CONFIDENCE=([/dev/nvme0n1]=HIGH)
        local -A NVME_WEAR_DAYS_LEFT=([/dev/nvme2n1]=INF)
        local -A NVME_WEAR_CONFIDENCE=([/dev/nvme2n1]=RESET)
        local -A NVME_WEAR_RATE=([/dev/nvme2n1]=0)
        TREND_DIAGNOSTIC_ITEMS=()
        log_health_trends &&
            grep -Fq 'Diagnostic TBW endurance: device=nvme0n1 bytes_per_day=1000000000 days_left=500 confidence=HIGH' "$MASTER_LOG" &&
            grep -Fq 'Diagnostic NVMe wear: device=nvme2n1 days_left=INF rate_percent_per_day=0 confidence=RESET' "$MASTER_LOG"
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

    if soak_record_is_valid \
           v1 1780000000 1780000030 30 0 boot-a 12 0 0 0 0 30 0 0 \
           SEND delivered 0 1 0 0 initial_lookback 5 disk_health_fixture.log 2.15 &&
       ! soak_record_is_valid \
           v1 1780000000 1780000030 30 0 boot-a 12 0 0 0 0 30 0 0 \
           SEND delivered 0 1 2 0 initial_lookback 5 disk_health_fixture.log 2.15
    then
        self_test_result 1 "Soak evidence schema validation"
    else
        self_test_result 0 "Soak evidence schema validation"
    fi

    # Emits one complete v1 fixture record to the requested file. It is local
    # to the self-test subshell and never touches live monitoring state.
    fixture_soak_record() {
        local target="$1" start_epoch="$2" end_epoch="$3" exit_status="$4"
        local boot_id="$5" outcome="$6" parity_active="$7" standby_count="$8"
        local syslog_mode="$9" log_file="${10}"
        local duration=$((end_epoch - start_epoch)) decision="SEND" rc=0 attempts=1

        if [[ "$outcome" == "suppressed" ]]; then
            decision="SUPPRESS"
            attempts=0
        elif [[ "$outcome" == "failed" ]]; then
            rc=1
        fi
        printf 'v1\t%s\t%s\t%s\t%s\t%s\t12\t0\t0\t0\t0\t%s\t0\t0\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t5\t%s\t2.15\n' \
            "$start_epoch" "$end_epoch" "$duration" "$exit_status" "$boot_id" \
            "$duration" "$decision" "$outcome" "$rc" "$attempts" \
            "$parity_active" "$standby_count" "$syslog_mode" "$log_file" \
            >> "$target"
    }

    local soak_now soak_old soak_persist_file
    soak_now=$(date +%s)
    soak_old=$((soak_now - 172800))
    soak_persist_file="$fixture_dir/soak-persist.tsv"
    : > "$soak_persist_file"
    fixture_soak_record "$soak_persist_file" "$soak_old" "$((soak_old + 30))" \
        0 boot-old delivered 0 0 initial_lookback disk_health_old.log
    printf 'malformed evidence row\n' >> "$soak_persist_file"
    SOAK_RUN_HISTORY_FILE="$soak_persist_file"
    SOAK_TELEMETRY_ENABLED=1
    SOAK_RUN_STARTED=1
    SOAK_RETENTION_DAYS=1
    SOAK_MAX_RECORDS=2
    COLLECTOR_ORDER=(soak_ok soak_deferred)
    COLLECTOR_STATUS=([soak_ok]="OK" [soak_deferred]="DEFERRED")
    COLLECTOR_DURATION=([soak_ok]=2 [soak_deferred]=1)
    COLLECTOR_DETAIL=([soak_ok]="" [soak_deferred]="deferred=1")
    SMART_DEFERRED=([/dev/sda]="standby")
    DISCOVERED_DISKS=(/dev/sda /dev/nvme0n1)
    NOTIFICATION_PHASE_REACHED=0
    PARITY_ACTIVE=0
    SYSLOG_CURSOR_MODE="cursor_continuation"
    MASTER_LOG="$fixture_dir/disk_health_soak.log"
    RUN_EPOCH=$((soak_now - 20))
    persist_soak_observation 0
    RUN_EPOCH=$((soak_now - 10))
    persist_soak_observation 0
    RUN_EPOCH="$soak_now"
    persist_soak_observation 0
    local soak_persist_lines soak_persist_invalid=0
    soak_persist_lines=$(wc -l < "$soak_persist_file" | tr -d ' ')
    while IFS= read -r line; do
        IFS=$'\t' read -r -a fields <<< "$line"
        soak_record_is_valid "${fields[@]}" || soak_persist_invalid=$((soak_persist_invalid + 1))
    done < "$soak_persist_file"
    if [[ "$soak_persist_lines" == "2" && "$soak_persist_invalid" == "0" ]] &&
       ! grep -Fq 'boot-old' "$soak_persist_file"
    then
        self_test_result 1 "Atomic bounded soak evidence persistence"
    else
        self_test_result 0 "Atomic bounded soak evidence persistence" \
            "lines=$soak_persist_lines invalid=$soak_persist_invalid"
    fi

    local soak_collecting_file="$fixture_dir/soak-collecting.tsv"
    : > "$soak_collecting_file"
    fixture_soak_record "$soak_collecting_file" 1780000000 1780000030 \
        0 boot-a delivered 0 0 initial_lookback disk_health_collecting.log
    SOAK_RUN_HISTORY_FILE="$soak_collecting_file"
    SOAK_MIN_RUNS=2
    SOAK_MIN_DAYS=2
    SOAK_REQUIRE_REBOOT=1
    SOAK_REQUIRE_STANDBY=1
    SOAK_REQUIRE_SYSLOG_ROTATION=1
    SOAK_REQUIRE_NOTIFICATION_DELIVERY=1
    SOAK_REQUIRE_NOTIFICATION_SUPPRESSION=1
    SOAK_REQUIRE_PARITY=0
    analyze_soak_history
    if [[ "$SOAK_ANALYSIS_STATUS" == "COLLECTING" &&
          "$SOAK_ANALYSIS_VALID_RUNS" == "1" &&
          "$SOAK_ANALYSIS_MISSING" == *reboot* &&
          "$SOAK_ANALYSIS_MISSING" == *"standby deferral"* ]]
    then
        self_test_result 1 "Soak readiness remains collecting until coverage completes"
    else
        self_test_result 0 "Soak readiness remains collecting until coverage completes" \
            "$SOAK_ANALYSIS_STATUS: $SOAK_ANALYSIS_DETAIL"
    fi

    local soak_ready_file="$fixture_dir/soak-ready.tsv"
    : > "$soak_ready_file"
    fixture_soak_record "$soak_ready_file" 1780000000 1780000030 \
        0 boot-a delivered 1 1 rotation_recovery disk_health_ready_a.log
    fixture_soak_record "$soak_ready_file" 1780172800 1780172830 \
        0 boot-b suppressed 0 0 cursor_continuation disk_health_ready_b.log
    SOAK_RUN_HISTORY_FILE="$soak_ready_file"
    SOAK_REQUIRE_PARITY=1
    analyze_soak_history
    if [[ "$SOAK_ANALYSIS_STATUS" == "READY" &&
          "$SOAK_ANALYSIS_CLEAN_RUNS" == "2" &&
          "$SOAK_ANALYSIS_BOOT_COUNT" == "2" &&
          "$SOAK_ANALYSIS_SYSLOG_ROTATION_RUNS" == "1" &&
          "$SOAK_ANALYSIS_NOTIFICATION_DELIVERED" == "1" &&
          "$SOAK_ANALYSIS_NOTIFICATION_SUPPRESSED" == "1" ]]
    then
        self_test_result 1 "Complete soak coverage reaches readiness"
    else
        self_test_result 0 "Complete soak coverage reaches readiness" \
            "$SOAK_ANALYSIS_STATUS: $SOAK_ANALYSIS_DETAIL"
    fi

    local soak_attention_file="$fixture_dir/soak-attention.tsv"
    : > "$soak_attention_file"
    fixture_soak_record "$soak_attention_file" 1780000000 1780000030 \
        1 boot-a failed 0 0 initial_lookback disk_health_failed.log
    printf 'broken\n' >> "$soak_attention_file"
    SOAK_RUN_HISTORY_FILE="$soak_attention_file"
    SOAK_REQUIRE_REBOOT=0
    SOAK_REQUIRE_STANDBY=0
    SOAK_REQUIRE_SYSLOG_ROTATION=0
    SOAK_REQUIRE_NOTIFICATION_DELIVERY=0
    SOAK_REQUIRE_NOTIFICATION_SUPPRESSION=0
    SOAK_REQUIRE_PARITY=0
    analyze_soak_history
    if [[ "$SOAK_ANALYSIS_STATUS" == "ATTENTION" &&
          "$SOAK_ANALYSIS_ATTENTION_RUNS" == "1" &&
          "$SOAK_ANALYSIS_INVALID_RUNS" == "1" &&
          "$SOAK_ANALYSIS_NOTIFICATION_FAILED" == "1" ]]
    then
        self_test_result 1 "Soak failures and malformed evidence require attention"
    else
        self_test_result 0 "Soak failures and malformed evidence require attention" \
            "$SOAK_ANALYSIS_STATUS: $SOAK_ANALYSIS_DETAIL"
    fi

    local soak_status_output="$fixture_dir/soak-status.txt"
    SOAK_RUN_HISTORY_FILE="$soak_ready_file"
    SOAK_MIN_RUNS=2
    SOAK_MIN_DAYS=2
    SOAK_REQUIRE_REBOOT=1
    SOAK_REQUIRE_STANDBY=1
    SOAK_REQUIRE_SYSLOG_ROTATION=1
    SOAK_REQUIRE_NOTIFICATION_DELIVERY=1
    SOAK_REQUIRE_NOTIFICATION_SUPPRESSION=1
    SOAK_REQUIRE_PARITY=1
    print_soak_status > "$soak_status_output"
    if grep -Fq 'Readiness: READY' "$soak_status_output" &&
       grep -Fq 'Notification suppression: PASS; observed=1' "$soak_status_output" &&
       grep -Fq 'Parity activity: PASS; observed=1' "$soak_status_output"
    then
        self_test_result 1 "Human-readable soak readiness report"
    else
        self_test_result 0 "Human-readable soak readiness report"
    fi

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
