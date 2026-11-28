#!/bin/bash
# Isolated formatting, notifier and cross-owner action-budget checks.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/tools/operations_contract.sh"
source "$repo/tools/media_action_budget.sh"
fixture=$(mktemp -d /tmp/operations-contract.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
OPS_SCRIPT_ID=contract_test;OPS_RUN_ID=test_run
line=$(usr_ops_log_line WARN phase $'First\nSecond')
[[ "$line" == *' | WARNING | contract_test | run=test_run | phase=phase | First | Second' ]]
long=$(printf '%5000s' x);line=$(usr_ops_log_line ERROR test "$long");((${#line}<=4096))
cat >"$fixture/notify" <<'NOTIFY'
#!/bin/bash
printf '%s\n' "$@" >"$CAPTURE"
exit "${NOTIFY_RC:-0}"
NOTIFY
chmod +x "$fixture/notify";export CAPTURE="$fixture/email"
usr_ops_notify timeout 3 "$fixture/notify" -i warning -s 'Contract' -d 'Replacement deferred' -m 'Original retained; no download sent.'
grep -q '^Status: ATTENTION$' "$CAPTURE";grep -q '^Actions and findings:$' "$CAPTURE";grep -q 'Original retained' "$CAPTURE"
export NOTIFY_RC=7
if usr_ops_notify "$fixture/notify" -i normal -d Check -m Evidence;then exit 1;else [[ $? == 7 ]];fi
unset NOTIFY_RC
USR_OPS_SHARED_BUDGET_ACTIVE=true;MEDIA_ACTION_BUDGET_ROOT="$fixture/budget";mkdir "$MEDIA_ACTION_BUDGET_ROOT"
MEDIA_ACTION_BUDGET_LOCK="$fixture/budget.lock";STATE_EXPORT_LOCK="$fixture/export.lock"
MEDIA_AUTOMATION_RUN_ID=health-run
usr_ops_arr_reserve command:one Sonarr 1;usr_ops_arr_reserve policy:two Radarr 2
if usr_ops_arr_reserve integrity:three Sonarr 3;then exit 1;fi
# Only an explicitly proven pre-HTTP refusal releases a reservation.
usr_ops_arr_release_undispatched policy:two
usr_ops_arr_reserve integrity:three Sonarr 3
MEDIA_AUTOMATION_RUN_ID=next-run
usr_ops_arr_reserve command:four Radarr 4;usr_ops_arr_reserve integrity:five Sonarr 5
MEDIA_AUTOMATION_RUN_ID=third-run
if usr_ops_arr_reserve command:six Radarr 6;then exit 1;fi
[[ $(jq '.actions|length' "$MEDIA_ACTION_BUDGET_ROOT/action-budget.json") == 4 ]]
printf 'invalid' >"$MEDIA_ACTION_BUDGET_ROOT/action-budget.json"
if usr_ops_arr_reserve command:seven Sonarr 7;then exit 1;fi
[[ $(cat "$MEDIA_ACTION_BUDGET_ROOT/action-budget.json") == invalid ]]
printf 'Common log vocabulary, notification evidence/exit status, shared per-run/day limits, known non-dispatch release and corrupt-budget preservation passed\n'
while IFS= read -r name;do
    script="$repo/user_script/$name.sh"
    awk '/^# BEGIN EMBEDDED OPERATIONS CONTRACT$/{on=1;next}/^# END EMBEDDED OPERATIONS CONTRACT$/{exit} on{print}' "$script" >"$fixture/embedded"
    cp "$repo/tools/operations_contract.sh" "$fixture/expected"
    case "$name" in
      backup_boot_disk|backup_cache_appdata|backup_media_remote|backup_vault_remote|backup_restore_drill|media_plex_dbrepair|backup_health_audit) ;;
      *) sed '/^    usr_ops_delivery_record /d' "$fixture/expected" >"$fixture/next";mv "$fixture/next" "$fixture/expected";;
    esac
    # Projection may omit unreachable helpers. Every retained function must
    # still have the exact shared implementation (comments are not behaviour).
    while IFS= read -r helper;do
        cmp <(bash -c 'source "$1";declare -f "$2"' bash "$fixture/embedded" "$helper") \
            <(bash -c 'source "$1";declare -f "$2"' bash "$fixture/expected" "$helper")
    done < <(bash -c 'source "$1";declare -F' bash "$fixture/embedded" | awk '{print $3}')
done < <(jq -r '.scripts|keys[]' "$repo/user_script/versions.json")
printf 'Every retained standalone operational helper matches the shared implementation\n'
