#!/bin/bash
# Isolated policy/report/outbox fixtures; no registry or installer actions.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/system_update_coordinator.sh"
fixture=$(mktemp -d /tmp/update-report.XXXXXX);trap 'rm -rf -- "$fixture"' EXIT
TMP_DIR="$fixture";STATE_DIR="$fixture/state";mkdir "$STATE_DIR"
LOG_FILE="$STATE_DIR/log";STATE_FILE="$STATE_DIR/state.json";POLICY_FILE="$STATE_DIR/policy.json";STATE_EXPORT_LOCK="$fixture/export.lock"
now=$(date +%s)
jq -n --argjson now "$now" '{schema:1,items:{"docker:current":{kind:"docker",name:"current",identity:"repo:latest",checkStatus:"VERIFIED",available:false,checkedAt:$now},"docker:held":{kind:"docker",name:"held",identity:"repo:latest",checkStatus:"VERIFIED",available:true,candidate:"new",candidateSeenAt:$now,checkedAt:$now},"docker:unknown":{kind:"docker",name:"unknown",identity:"repo:latest",checkStatus:"UNVERIFIED",available:false,checkedAt:$now},"plugin:unRAIDServer.plg":{kind:"plugin",name:"unRAIDServer.plg",checkStatus:"VERIFIED",available:true,checkedAt:$now}},jobs:{done:{item:"docker:finished",kind:"docker",name:"finished",status:"COMPLETED",previous:"old",candidate:"new",verifiedAt:$now,recoveryPath:"/owned/recovery"}},outbox:[],delivered:{}}' >"$STATE_FILE"
jq -n '{schema:1,enabled:true,window:{start:"13:15",end:"15:30"},reportTime:"00:00",limits:{dailyTotal:3,dailyPlugins:1,candidateHoldHours:24},docker:{held:{identity:"repo:latest",allow:true,candidateHoldHours:12}},plugins:{}}' >"$POLICY_FILE"
render_update_report >"$fixture/report"
grep -q 'old -> new' "$fixture/report"
grep -q 'Up to date at last successful check' "$fixture/report"
grep -q 'Candidate stability hold: 0/12h' "$fixture/report"
grep -q 'Update status unverified: UNVERIFIED' "$fixture/report"
grep -q 'OS update is manual' "$fixture/report"
daily_update_report;first=$(jq '.outbox|length' "$STATE_FILE");daily_update_report
[[ $(jq '.outbox|length' "$STATE_FILE") == "$first" && "$first" -gt 0 ]]
# Verify no record is lost/truncated across multi-email UTF-8 pagination.
mutate '.outbox=[] | .delivered={} | .normalDeliveryIds=[]'
long=$(for ((i=1;i<=400;i++));do printf 'record-%04d 日本語 metadata and verified action details retained in report\n' "$i";done)
event normal 'Large report' "$long" pagination
mutate '.normalDeliveryIds=[.outbox[].id]'
jq -e '[.outbox[].detail|utf8bytelength]|all(.<=11000)' "$STATE_FILE" >/dev/null
jq -r '.outbox[].detail' "$STATE_FILE" >"$fixture/combined"
for n in 0001 0100 0200 0300 0400;do grep -q "record-$n" "$fixture/combined";done
NOTIFY_BIN="$fixture/notify";printf '#!/bin/bash\nexit 1\n' >"$NOTIFY_BIN";chmod +x "$NOTIFY_BIN"
first=$(jq '.outbox|length' "$STATE_FILE")
if flush_notifications;then exit 1;fi
[[ $(jq '.outbox|length' "$STATE_FILE") == "$first" ]]
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s/mail"\n' "$fixture" >"$NOTIFY_BIN"
for ((i=0;i<20;i++));do [[ $(jq '.outbox|length' "$STATE_FILE") -gt 0 ]] || break;flush_notifications;done
[[ $(jq '.outbox|length' "$STATE_FILE") == 0 ]]
for n in 0001 0100 0200 0300 0400;do grep -q "record-$n" "$fixture/mail";done
# Future daily cutoff suppresses normal events, while urgent attention bypasses.
policy_update '.reportTime="23:59"'
mutate '.outbox=[] | .delivered={} | .normalDeliveryIds=[]'
event normal 'Routine action' 'Retain until daily cutoff' routine
# A local clock before the cutoff makes this assertion deterministic on Hubble
# and elsewhere without modifying the execution host clock.
date(){ case "${*: -1}" in +%H:%M) printf '12:00\n';;*) command date "$@";;esac; }
flush_notifications
[[ $(jq '.outbox|length' "$STATE_FILE") == 1 ]]
event alert 'Failed native result' 'Outcome unverified; further updates held' urgent
flush_notifications
[[ $(jq '.outbox|length' "$STATE_FILE") == 0 ]]
grep -q 'Failed native result' "$fixture/mail"
# A normal receipt after today's already sealed/sent summary must not make
# another routine email; tomorrow's daily batch will include it.
mutate '.outbox=[] | .delivered={} | .normalDeliveryIds=[]'
policy_update '.reportTime="00:00"'
event normal 'Late verification completed' 'Include in the next daily summary' late
count=$(wc -l <"$fixture/mail");daily_update_report;flush_notifications
[[ $(jq '.outbox|length' "$STATE_FILE") == 1 && $(wc -l <"$fixture/mail") == "$count" ]]
mutate 'del(.lastDailyReportDay)'
daily_update_report;flush_notifications
[[ $(jq '.outbox|length' "$STATE_FILE") == 0 ]]
grep -q 'Late verification completed' "$fixture/mail"
printf 'Daily updated/deferred/current/unknown classification, single report, UTF-8 pagination, failure retry and urgent bypass passed\n'
