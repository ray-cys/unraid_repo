#!/bin/bash
# Fake calendars, schedules and journals only. No native update or app mutation.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d);trap 'rm -rf "$fixture"' EXIT
source "$repo/user_script/system_update_coordinator.sh"
POLICY_FILE="$fixture/policy.json";BACKUP_SCHEDULE_FILE="$fixture/scripts.json";TMP_DIR="$fixture";STATE_FILE="$fixture/state.json";STATE_EXPORT_LOCK="$fixture/export.lock";LOG_FILE="$fixture/log";RUN_ID=fixture
printf '{}' >"$BACKUP_SCHEDULE_FILE"
jq -n '{schema:1,enabled:true,window:{start:"13:15",end:"15:30"},windows:[{start:"13:15",end:"15:30"},{start:"21:15",end:"23:00"}],limits:{dailyDocker:6,dailyPlugins:2,dailyTotal:8},docker:{kometa:{identity:"kometa",allow:true,candidateHoldHours:1}},plugins:{}}' >"$POLICY_FILE"
policy_valid "$POLICY_FILE"
epoch(){ TZ=Asia/Singapore date -d "$1" +%s; }
now=$(epoch '2026-11-26 15:30:00')
[[ $(next_update_attempt "$now") == "$(epoch '2026-11-26 21:15:00')" ]]
[[ $(next_update_attempt "$(epoch '2026-11-26 23:00:00')") == "$(epoch '2026-11-27 13:15:00')" ]]
empty='{"verified":true,"events":[]}'
utc='{"verified":true,"events":[{"label":"Kometa UTC run","cron":"0 8 * * *","timezone":"UTC","durationSeconds":0}]}'
calendar_eval guard "$(epoch '2026-11-26 13:15:00')" 1200 kometa docker "$utc" | jq -e --argjson at "$(epoch '2026-11-26 16:00:00')" '.ready==true and .nextEvent.at==$at' >/dev/null

calendar_eval guard "$(epoch '2026-11-26 13:15:00')" 1200 seerr docker "$empty" | jq -e .ready >/dev/null
calendar_eval guard "$(epoch '2026-11-26 15:15:00')" 1200 seerr docker "$empty" | jq -e '.ready==false' >/dev/null
sab='{"verified":true,"events":[{"label":"SAB resume_post","cron":"30 15 * * *","timezone":"Asia/Singapore","durationSeconds":0}]}'
calendar_eval guard "$(epoch '2026-11-26 15:10:00')" 1200 sabnzbd docker "$sab" | jq -e '.ready==false and any(.holds[];.label|contains("SAB"))' >/dev/null
meta='{"verified":true,"events":[{"label":"MetaFusion scheduled run","cron":"35 23 * * *","timezone":"Asia/Singapore","durationSeconds":0}]}'
calendar_eval guard "$(epoch '2026-11-26 22:30:00')" 1200 metafusion docker "$meta" | jq -e .ready >/dev/null
photo='{"verified":true,"events":[{"label":"PhotoPrism backup","cron":"0 15 */2 * *","timezone":"Asia/Singapore","durationSeconds":3600}]}'
calendar_eval guard "$(epoch '2026-11-27 14:45:00')" 1200 photoprism docker "$photo" | jq -e '.ready==false' >/dev/null
calendar_eval guard "$(epoch '2026-11-27 15:05:00')" 780 photoprism docker "$photo" | jq -e 'any(.holds[];.label|contains("Protected scheduled interval"))' >/dev/null
calendar_eval guard "$(epoch '2026-11-26 14:45:00')" 1200 photoprism docker "$photo" | jq -e .ready >/dev/null
calendar_eval guard "$(epoch '2026-11-26 13:15:00')" 1200 seerr docker '{"verified":false,"events":[]}' | jq -e '.ready==false' >/dev/null
jq '.windows[1].start="15:00"' "$POLICY_FILE" >"$fixture/bad"
if policy_valid "$fixture/bad";then echo 'Overlapping windows accepted';exit 1;fi
# Routine monitors must not make a 20-minute quiet interval impossible.
jq -n '{"/boot/config/plugins/user.scripts/scripts/media_health_monitor/script":{frequency:"custom",custom:"*/5 * * * *"},"/boot/config/plugins/user.scripts/scripts/media_torrent_management/script":{frequency:"custom",custom:"0 */2 * * *"}}' >"$BACKUP_SCHEDULE_FILE"
calendar_eval guard "$(epoch '2026-11-26 13:15:00')" 1200 radarr docker "$empty" | jq -e .ready >/dev/null
calendar_eval guard "$(epoch '2026-11-26 13:45:00')" 1200 radarr docker "$empty" | jq -e '.ready==false' >/dev/null
calendar_eval guard "$(epoch '2026-11-26 13:45:00')" 1200 test.plg plugin "$empty" | jq -e '.ready==false' >/dev/null
printf 'Both windows, finish-by budgets, native boundaries, odd-day backups, overlap rejection and monitor exclusion passed\n'
# One miss per observed window, not once per 15-minute invocation.
jq -n '{schema:1,items:{"docker:kometa":{kind:"docker",name:"kometa",identity:"kometa",candidate:"new",candidateSeenAt:0,available:true,checkStatus:"VERIFIED",missingScans:0}},jobs:{},outbox:[],delivered:{}}' >"$STATE_FILE"
track_update_windows "$(epoch '2026-11-26 13:15:00')"
track_update_windows "$(epoch '2026-11-26 13:30:00')"
track_update_windows "$(epoch '2026-11-26 15:30:00')"
jq -e '.items["docker:kometa"].missedUpdateWindows==1' "$STATE_FILE" >/dev/null
track_update_windows "$(epoch '2026-11-26 15:45:00')"
jq -e '.items["docker:kometa"].missedUpdateWindows==1' "$STATE_FILE" >/dev/null
track_update_windows "$(epoch '2026-11-26 21:15:00')"
track_update_windows "$(epoch '2026-11-26 23:00:00')"
jq -e '.items["docker:kometa"].missedUpdateWindows==2' "$STATE_FILE" >/dev/null
warn_starved_updates;warn_starved_updates
jq -e '.outbox|length==1' "$STATE_FILE" >/dev/null
jq -e '.outbox[0].importance=="normal" and (.outbox[0].detail|contains("queue priority"))' "$STATE_FILE" >/dev/null
printf 'Two observed misses raise priority with one grouped warning; repeated scans do not inflate counts\n'
