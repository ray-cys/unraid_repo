#!/bin/bash
# Native fixtures only; never query live disks, mutate production state or notify.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/user_script/host_health_monitor.sh"
work=$(mktemp -d /tmp/host-warm-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
STATE_DIR="$work";RUN_DIR="$work";MASTER_LOG="$work/log";LOG_MIRROR_STDOUT=0
fail(){ printf 'FAIL: %s\n' "$*";exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }
atomic_write_text(){ printf '%s' "$2" > "$1"; }
collector_atomic_commit(){ mv "$1" "$2"; }
RUN_EPOCH=$(date -d '2026-11-28 06:30:03 +0800' +%s)
fixture_observed=$((RUN_EPOCH+12));hm_observed_epoch(){ printf '%s' "$fixture_observed"; }
status=$'Scrub started: Sat Nov 28 06:30:05 2026\nStatus: finished\nError summary: no errors found'
start=$(hm_scrub_start_epoch "$status")
((start>RUN_EPOCH)) || fail 'fixture did not start after monitor'
hm_scrub_clean "$status" "$start" "$fixture_observed" || fail 'same-run clean scrub rejected'
if hm_scrub_clean "$status" "$start" "$RUN_EPOCH";then fail 'future start accepted';fi
if hm_scrub_clean "$status"$'\nUncorrectable: 1' "$start" "$fixture_observed";then fail 'scrub error accepted as clean';fi
pass 'Observation timestamp accepts same-run results and rejects future/uncorrectable evidence'
DOCKER_SCRUB_TRACKING_FILE="$work/docker.json"
fixture_uuid=11111111-2222-3333-4444-555555555555
jq -nc --arg uuid "$fixture_uuid" --argjson at "$RUN_EPOCH" '{schema:1,uuid:$uuid,pending:true,requests:1,requestedEpoch:$at,requestMonth:"2026-11",lastSuccessEpoch:0,lastSuccessfulStartEpoch:0}' > "$DOCKER_SCRUB_TRACKING_FILE"
timeout(){ printf '%s\n' "$fixture_uuid"; }
hm_reconcile_docker_scrub /var/lib/docker "$status" 0 || fail 'cached no-op failed'
jq -e '.pending' "$DOCKER_SCRUB_TRACKING_FILE" >/dev/null || fail 'cached evidence closed request'
hm_reconcile_docker_scrub /var/lib/docker "$status" 1 || fail 'native completion not reconciled'
jq -e --argjson now "$fixture_observed" --argjson start "$start" '.pending==false and .lastSuccessEpoch==$now and .lastSuccessfulStartEpoch==$start' "$DOCKER_SCRUB_TRACKING_FILE" >/dev/null || fail 'completion receipt wrong'
# Wrong UUID cannot close a matching-looking request; a newer request cannot use an old scrub.
jq --argjson at "$RUN_EPOCH" '.pending=true|.requestedEpoch=$at|.uuid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"' "$DOCKER_SCRUB_TRACKING_FILE" > "$work/changed";mv "$work/changed" "$DOCKER_SCRUB_TRACKING_FILE"
if hm_reconcile_docker_scrub /var/lib/docker "$status" 1;then fail 'wrong filesystem proof accepted';fi
jq --arg uuid "$fixture_uuid" --argjson at "$((start+10))" '.uuid=$uuid|.requestedEpoch=$at' "$DOCKER_SCRUB_TRACKING_FILE" > "$work/changed";mv "$work/changed" "$DOCKER_SCRUB_TRACKING_FILE"
hm_reconcile_docker_scrub /var/lib/docker "$status" 1 || fail 'older result no-op failed'
jq -e '.pending' "$DOCKER_SCRUB_TRACKING_FILE" >/dev/null || fail 'older scrub closed newer request'
pass 'Matching same-run native completion closes request without dispatch or cached proof'
unset -f timeout
# Real cache, mocked native smartctl: count actual reads across subshell calls.
SMART_CACHE_DIR="$work/cache";mkdir "$SMART_CACHE_DIR"
smartctl_bounded(){ printf 'read\n' >> "$work/reads";printf 'Self-test status: No self-test in progress\n'; }
smartctl_cached -l selftest -d nvme /dev/nvme0n1 >/dev/null
get_selftest_live /dev/nvme0n1 >/dev/null
[[ $(wc -l < "$work/reads") == 1 ]] || fail 'self-test log not reused'
invalidate_smart_cache /dev/nvme0n1
get_selftest_live /dev/nvme0n1 >/dev/null
[[ $(wc -l < "$work/reads") == 2 ]] || fail 'post-start invalidation lost'
pass 'Repeated self-test observations reuse cache; invalidation forces fresh native read'
SMART_TEST_CANDIDATE=/dev/fixture;TEST_TRACK=([fixture\|shortAnchor]=100)
MAINTENANCE_ACTIONS_ALLOWED=1;DOCKER_SCRUB_STARTED=1;SMART_FLEET_STATUS_UNKNOWN=0
if smart_test_start_allowed short;then fail 'scrub blocker ignored';fi
[[ ${SMART_TEST_DEFERRALS[/dev/fixture]} == *'scrub started'* && ${TEST_TRACK[fixture\|shortAnchor]} == 100 ]] || fail 'reason/deadline lost'
DOCKER_SCRUB_STARTED=0;SMART_FLEET_STATUS_UNKNOWN=1
if smart_test_start_allowed short;then fail 'unknown fleet ignored';fi
[[ ${SMART_TEST_DEFERRALS[/dev/fixture]} == *unverified* ]] || fail 'fleet reason absent'
pass 'SMART blockers have precise reasons and preserve calendar anchor'
# Loop2 -> loop9 retains counters for the same filesystem and devid.
BTRFS_DEV_PREV_FILE="$work/counters";BTRFS_DEV_HIST_FILE="$work/history";touch "$BTRFS_DEV_HIST_FILE"
ENABLE_BTRFS_DEVICE_STATS=1;loop=/dev/loop2;value=0
mount(){ printf 'fixture on /var/lib/docker type btrfs (rw)\nfixture on /var/lib/docker/duplicate type btrfs (rw)\n'; }
btrfs_bounded(){
 case "$1 $2" in
 'device stats') printf '[%s].read_io_errs %s\n' "$loop" "$value";;
 'filesystem show') printf 'Label: none uuid: %s\n devid 1 size 100 used 10 path %s\n' "$fixture_uuid" "$loop";;
 *) return 1;;esac
}
record_alert(){ printf '%s\n' "$*" >> "$work/alerts"; }
collect_btrfs_device_stats
[[ $(grep -c '^btrfs:' "$BTRFS_DEV_PREV_FILE") == 1 ]] || fail 'duplicate mount not deduplicated'
loop=/dev/loop9;value=1
collect_btrfs_device_stats
[[ $(grep -c 'delta=1' "$BTRFS_DEV_HIST_FILE") == 1 ]] || fail 'loop renumbering discarded delta or counted twice'
fixture_uuid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee;value=25
collect_btrfs_device_stats
[[ $(grep -c 'delta=' "$BTRFS_DEV_HIST_FILE") == 1 ]] || fail 'new filesystem inherited old image counter'
pass 'Filesystem/devid loop identity survives renumbering, deduplicates mounts and isolates new images'
# Summary must distinguish unobserved devices from current healthy measurements.
DISCOVERED_DISKS=(/dev/nvme0n1 /dev/sdz)
DEVICE_ID_BY_PATH[/dev/nvme0n1]=fixture_nvme;DEVICE_ID_BY_PATH[/dev/sdz]=fixture_sleep
FRESH_SMART=([/dev/nvme0n1]=1);SMART_DEFERRED=([/dev/sdz]=standby)
TEST_TRACK=([fixture_nvme\|pending]=1)
SMART_COVERAGE_FILE="$work/coverage.tsv";printf 'fixture_nvme\t%s\t%s\nfixture_sleep\t%s\t0\n' "$RUN_EPOCH" "$RUN_EPOCH" "$RUN_EPOCH" > "$SMART_COVERAGE_FILE"
POOL_HEALTH_FILE="$work/pool.json";jq -nc --argjson now "$fixture_observed" '{pools:{docker:{mount:"/var/lib/docker",observedAt:$now,recordedClean:true,liveStatus:true,lastRecordedStart:$now}}}' > "$POOL_HEALTH_FILE"
SMART_TEST_STARTED_THIS_RUN=1;SMART_TEST_OVERDUE_COUNT=2
hm_build_coverage_summary || fail 'coverage generation failed'
jq -e '.inventory==2 and .smart.fresh==1 and .smart.deferred==1 and .smart.neverSampled==1 and .tests.started==1 and .tests.pending==1 and .tests.overdue==2 and .scrubs[0].clean' <<< "$HOST_HEALTH_COVERAGE" >/dev/null || fail 'coverage not truthful'
MONITOR_RECEIPT_FILE="$work/receipt.json"
set_notification_outcome(){ RECEIPT_NOTIFICATION_OUTCOME_RESULT=suppressed; }
write_monitor_receipt complete 0 || fail 'receipt write failed'
jq -e '.status=="complete" and .coverage.smart.neverSampled==1' "$MONITOR_RECEIPT_FILE" >/dev/null || fail 'receipt coverage missing'
HEALTH_ALERTS_SECTION='';NOTIFICATION_RECOVERY_SECTION='';STORAGE_TOP_LINES=''
compose_notification
[[ "$NOTIFY_BODY" == *'SMART fresh=1'* ]] || fail 'notification lacks coverage'
pass 'Compact log/notification and existing receipt carry truthful SMART/test/scrub coverage'
