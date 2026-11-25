#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/media_integrity_audit.sh"
fixture=$(mktemp -d);trap 'rm -rf "$fixture"' EXIT
mkfifo "$fixture/events"
{ printf '{"type":';sleep .15;printf '"heartbeat"}\n'; } >"$fixture/events" &
exec {fd}<"$fixture/events"
WORKER_EVENT_PARTIAL='';event='';waits=0
while :;do
 rc=0;read_worker_event event "$fd" .03 || rc=$?
 if ((rc==0));then break;fi
 [[ "$rc" == 75 ]];waits=$((waits+1))
done
[[ "$event" == '{"type":"heartbeat"}' && "$waits" -gt 0 ]]
exec {fd}<&-;wait
printf '{"unfinished":' >"$fixture/input"
exec {fd}<"$fixture/input";WORKER_EVENT_PARTIAL='';rc=0
read_worker_event event "$fd" .1 || rc=$?
[[ "$rc" == 2 ]];exec {fd}<&-
head -c 262145 /dev/zero | tr '\0' x >"$fixture/input"
exec {fd}<"$fixture/input";WORKER_EVENT_PARTIAL='';rc=0
read_worker_event event "$fd" .1 || rc=$?
[[ "$rc" == 2 ]];exec {fd}<&-
printf 'Fragmented timeout frames retained; incomplete/oversized frames rejected safely\n'
