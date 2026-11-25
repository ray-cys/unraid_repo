#!/bin/bash
# Isolated policy, schedules, lock and journal fixtures. No installers/containers.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d);trap 'rm -rf "$fixture"' EXIT
source "$repo/user_script/system_update_coordinator.sh"
TMP_DIR="$fixture";STATE_FILE="$fixture/state.json";STATE_EXPORT_LOCK="$fixture/export.lock";POLICY_FILE="$fixture/policy.json"
BACKUP_SCHEDULE_FILE="$fixture/schedule.json"
printf '{"/boot/config/plugins/user.scripts/scripts/backup_cache_appdata/script":{"frequency":"custom","custom":"38 5 * * 2,4,6"},"/boot/config/plugins/user.scripts/scripts/backup_boot_disk/script":{"frequency":"custom","custom":"0 19 * * 1,3,6"}}' >"$BACKUP_SCHEDULE_FILE"
mkdir -p "$fixture/scripts/backup_cache_appdata" "$fixture/scripts/backup_boot_disk" "$fixture/scripts/system_update_coordinator"
for name in backup_cache_appdata backup_boot_disk system_update_coordinator;do printf '#!/bin/bash\n' >"$fixture/scripts/$name/script";done
jq '.["/boot/config/plugins/user.scripts/scripts/system_update_coordinator/script"]={frequency:"custom",custom:"*/15 * * * *"}' "$BACKUP_SCHEDULE_FILE" >"$fixture/seed";mv "$fixture/seed" "$BACKUP_SCHEDULE_FILE"
cp "$BACKUP_SCHEDULE_FILE" "$fixture/good-schedule"
if command -v php >/dev/null;then
  now=$(TZ=Asia/Singapore date -d '2026-11-26 13:15:00' +%s)
  result=$(backup_schedule_window docker "$now")
  expected=$(TZ=Asia/Singapore date -d '2026-11-21 05:38:00' +%s)
  [[ $(jq -r .cutoff <<<"$result") == "$expected" ]]
  # After Thursday finish grace, Tuesday must have completed (one miss allowed).
  later=$(TZ=Asia/Singapore date -d '2026-11-26 18:00:00' +%s)
  expected=$(TZ=Asia/Singapore date -d '2026-11-24 05:38:00' +%s)
  [[ $(backup_schedule_window docker "$later" | jq -r .cutoff) == "$expected" ]]
  jq '.["/boot/config/plugins/user.scripts/scripts/backup_cache_appdata/script"].custom="not a cron"' "$BACKUP_SCHEDULE_FILE" >"$fixture/next";mv "$fixture/next" "$BACKUP_SCHEDULE_FILE"
  if backup_schedule_window docker "$now" >/dev/null;then echo 'Invalid cron accepted';exit 1;fi
  cp "$fixture/good-schedule" "$BACKUP_SCHEDULE_FILE"
  printf 'Actual backup schedule, one missed run, finish grace and invalid-schedule protection passed\n'
fi
jq -n '{schema:1,items:{},jobs:{failed:{kind:"docker",name:"radarr",identity:"radarr:nightly",status:"ATTENTION",installerFinishedVerified:true}},outbox:[]}' >"$STATE_FILE"
pending_update_guard docker photoprism photoprism
if pending_update_guard docker sonarr sonarr;then exit 1;fi
if pending_update_guard plugin test.plg '';then exit 1;fi
jq '.jobs.failed.installerFinishedVerified=false' "$STATE_FILE" >"$fixture/next";mv "$fixture/next" "$STATE_FILE"
if pending_update_guard docker photoprism photoprism;then echo 'Uncertain installer bypassed';exit 1;fi
jq '.jobs.failed.kind="plugin" | .jobs.failed.installerFinishedVerified=true' "$STATE_FILE" >"$fixture/next";mv "$fixture/next" "$STATE_FILE"
if pending_update_guard docker photoprism photoprism;then echo 'Uncertain host plugin bypassed';exit 1;fi
printf 'Finished Docker failure isolates its dependency group; uncertain installer/plugin remains global\n'
array_values=$'mdState=STARTED\nmdResync=100\nmdResyncAction=check P\nmdResyncCorr=0'
bounded(){ printf '%s\n' "$array_values"; }
array_update_guard
array_values=$'mdState=STARTED\nmdResync=100\nmdResyncAction=recon D1\nmdResyncCorr=0'
if array_update_guard;then exit 1;fi
array_values=$'mdState=STARTED\nmdResync=100\nmdResyncAction=check P\nmdResyncCorr=1'
if array_update_guard;then exit 1;fi
array_values=$'mdState=STARTED\nmdResync=0\nmdResyncAction=check P'
array_update_guard
printf 'Ordinary parity check allowed; rebuild/correction deferred; stale idle action ignored\n'
jq -n '{window:{start:"13:15",end:"15:30"}}' >"$POLICY_FILE"
epoch=$(TZ=Asia/Singapore date -d '2026-11-26 15:30:00' +%s)
expected=$(TZ=Asia/Singapore date -d '2026-11-27 13:15:00' +%s)
[[ $(next_update_attempt "$epoch") == "$expected" ]]
printf 'Next reassessment follows the existing Singapore update window\n'
# A report shows all simultaneous observed holds, not merely the first failure.
jq -n --argjson now "$(date +%s)" '{schema:1,items:{"docker:radarr":{name:"radarr",kind:"docker",identity:"radarr",candidate:"new",candidateSeenAt:0,available:true,missingScans:0,checkStatus:"VERIFIED",checkedAt:$now}},inventory:{docker:{radarr:{running:true,managed:"dockerman"}}},jobs:{},outbox:[]}' >"$STATE_FILE"
jq -n '{schema:1,enabled:true,window:{start:"13:15",end:"15:30"},limits:{dailyDocker:6,dailyPlugins:2,dailyTotal:8},docker:{radarr:{allow:true,identity:"radarr",candidateHoldHours:1}},plugins:{}}' >"$POLICY_FILE"
MAX_RUNTIME_SECONDS=840;START_EPOCH=$(date +%s);VAULT_MOUNT="$fixture";ARR_BACKUP_GATE="$fixture/gate"
array_update_guard(){ SUMMARY='Fixture rebuild';return 1; }
adapter_compatible(){ return 0; };native_installer_idle(){ return 0; }
backup_evidence(){ BACKUP_REASON='Fixture backup overdue';return 1; }
readiness(){ printf '{"ready":true,"detail":"Fixture idle"}' >"$TMP_DIR/readiness.json"; }
collect_update_holds
jq -e '.items["docker:radarr"].holds|(.nextAttemptAt>0) and any(.reasons[];.code=="array") and any(.reasons[];.code=="backup")' "$STATE_FILE" >/dev/null
render_update_report >"$fixture/report"
grep -q 'Fixture rebuild' "$fixture/report";grep -q 'Fixture backup overdue' "$fixture/report";grep -q 'Next reassessment:' "$fixture/report"
printf 'Multiple simultaneous holds and next reassessment retained in grouped report\n'
# Known non-dispatch deferral has a short retry and releases only owned leases.
ROLLBACK_ROOT="$fixture/recovery";mkdir -p "$ROLLBACK_ROOT"
defer_prepared fixture-deferred 'Fixture app became busy before dispatch'
jq -e --argjson now "$(date +%s)" '.jobs["fixture-deferred"]|.status=="DEFERRED" and .retryAt>$now and .retryAt<=$now+300' "$STATE_FILE" >/dev/null
RUN_ID=fixture;LEASE_FILE="$fixture/foreign.json";CURRENT_REQUEST='';REQUEST_KEEP=false;MAINT_FD=''
printf '{"owner":"another-producer","runId":"other"}' >"$LEASE_FILE"
release_pre_dispatch
[[ -f "$fixture/foreign.json" ]]
LEASE_FILE="$fixture/own.json";printf '{"owner":"system_update_coordinator","runId":"fixture"}' >"$LEASE_FILE"
release_pre_dispatch
[[ ! -e "$fixture/own.json" ]]
printf 'Known non-dispatch retries promptly and preserves foreign maintenance leases\n'
