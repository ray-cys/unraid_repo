#!/bin/bash
# Isolated receipt and coverage fixtures: no disk probes, maintenance or email.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/user_script/host_health_monitor.sh"
source "$root/tools/host_health_coordination.sh"
work=$(mktemp -d /tmp/host-evidence-test.XXXXXX);trap 'rm -rf "$work"' EXIT
MONITOR_RECEIPT_FILE="$work/receipt.json";HC_DAILY_RECEIPT="$MONITOR_RECEIPT_FILE"
HC_SCHEDULE_FILE="$work/schedule.json"
printf '{"/boot/config/plugins/user.scripts/scripts/host_health_monitor/script":{"frequency":"custom","custom":"30 6 * * *"}}' > "$HC_SCHEDULE_FILE"
fixture_now=$(command date -d '2026-11-28 12:00:00 +0800' +%s)
date(){ if [[ "$*" == +%s ]];then printf '%s\n' "$fixture_now";else command date "$@";fi; }
set_notification_outcome(){ RECEIPT_NOTIFICATION_OUTCOME_RESULT=suppressed; }
atomic_write_text(){ printf '%s' "$2" > "$1"; }
hc_export_daily_evidence(){ jq -nc --argjson at "$1" --arg boot "$(cat /proc/sys/kernel/random/boot_id)" --argjson coverage "$HOST_HEALTH_COVERAGE" '{schema:1,observedAt:$at,bootId:$boot,findings:[],coverage:$coverage}'; }
HOST_HEALTH_COVERAGE='{"scrubs":[{"mount":"/mnt/cache","clean":true,"live":true,"start":100}],"inventory":2}'
MAINTENANCE_ACTIONS_ALLOWED=1;RUN_EPOCH=$((fixture_now-10));MONITOR_LAST_COMPLETE_EPOCH=0
write_monitor_receipt running 0;write_monitor_receipt complete 0
operational=$fixture_now
jq -e --argjson at "$fixture_now" '.runPurpose=="operational" and .maintenance.lastOperationalCompleteEpoch==$at and (.maintenance.verifiedScrubResults|length)==1' "$MONITOR_RECEIPT_FILE" >/dev/null
fixture_now=$((fixture_now+86400));RUN_EPOCH=$fixture_now;MAINTENANCE_ACTIONS_ALLOWED=0
write_monitor_receipt running 0;fixture_now=$((fixture_now+10));write_monitor_receipt complete 0
jq -e --argjson at "$operational" --argjson fixture_now "$fixture_now" '.runPurpose=="diagnostic" and .maintenance.lastOperationalCompleteEpoch==$at and .lastCompleteEpoch==$fixture_now and .maintenance.lastAttemptEpoch==($at-10)' "$MONITOR_RECEIPT_FILE" >/dev/null
snapshot=$(hc_daily_snapshot "$fixture_now")
jq -e '.freshness=="CURRENT" and .maintenance.freshness=="STALE" and .runPurpose=="diagnostic"' <<< "$snapshot" >/dev/null
MAINTENANCE_ACTIONS_ALLOWED=1;RUN_EPOCH=$fixture_now
write_monitor_receipt running 0;write_monitor_receipt incomplete 1
jq -e --argjson at "$operational" '.maintenance.status=="incomplete" and .maintenance.lastOperationalCompleteEpoch==$at' "$MONITOR_RECEIPT_FILE" >/dev/null
printf 'PASS: diagnostic collection cannot refresh operational assessment; incomplete operational run retains last complete proof\n'
# Current inventory controls coverage: retired IDs must not inflate counts.
DISCOVERED_DISKS=(/dev/fresh /dev/sleeping);FRESH_SMART=([/dev/fresh]=yes);SMART_DEFERRED=([/dev/sleeping]=standby)
SMART_TEST_DEFERRALS=([/dev/sleeping]='Disk sleeping');SMART_COVERAGE_FILE="$work/coverage.tsv";POOL_HEALTH_FILE="$work/no-pools"
printf 'id-/dev/fresh\t100\t200\nid-/dev/sleeping\t100\t0\nretired-device\t100\t0\n' > "$SMART_COVERAGE_FILE"
persistent_device_key(){ printf 'id-%s' "$1"; };test_track_get(){ printf '0'; };hm_observed_epoch(){ printf '%s' "$fixture_now"; };log(){ :; }
hm_build_coverage_summary
jq -e '.inventory==2 and (.devices|length)==2 and .smart.fresh==1 and .smart.deferred==1 and .smart.neverSampled==1 and any(.devices[];.device=="/dev/sleeping" and .neverSampled and (.reason|contains("standby")))' <<< "$HOST_HEALTH_COVERAGE" >/dev/null
jq -e '.devices[1].nextEligibleAttempt|contains("awake")' <<< "$HOST_HEALTH_COVERAGE" >/dev/null
# Presentation uses readable timestamps and never calls collectors.
HC_FAST_RECEIPT="$work/fast.json"
jq -nc --arg boot "$(cat /proc/sys/kernel/random/boot_id)" --argjson at "$fixture_now" --argjson coverage "$HOST_HEALTH_COVERAGE" '{schema:1,bootId:$boot,observedAt:$at,health:{schema:1,healthStatus:"OK",daily:{freshness:"CURRENT",observedAt:$at,maintenance:{freshness:"STALE",lastOperationalCompleteEpoch:0},coverage:$coverage,findings:[]},coverage:{partial:true,unverified:0,deferred:1},fastFindings:[],storage:{executionStatus:"COMPLETED",fresh:true,openXfsSources:[]}}}' > "$HC_FAST_RECEIPT"
output=$(hc_print_status)
grep -q 'no detected faults; coverage partial' <<< "$output"
grep -q 'never sampled' <<< "$output"
grep -q 'Maintenance assessment: STALE' <<< "$output"
grep -Eq 'Fast probes observed: [0-9]{4}-[0-9]{2}-[0-9]{2}' <<< "$output"
printf 'PASS: exact current-device coverage, explicit retry conditions and readable partial-health status\n'
