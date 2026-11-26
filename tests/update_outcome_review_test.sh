#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/system_update_coordinator.sh"
fixture=$(mktemp -d /tmp/update-outcome-test.XXXXXX);fixture=$(realpath "$fixture")
trap 'rm -rf -- "$fixture"' EXIT
TMP_DIR="$fixture";STATE_FILE="$fixture/state.json"
printf '{"templateHash":"same","definition":{"host":{"Binds":["/first:/config:rw","/second:/data:ro"],"Dns":["one","two"],"Memory":123},"userEnv":{"PRIVATE":"retained"}}}' >"$fixture/before"
jq '.definition.host.Binds|=reverse' "$fixture/before" >"$fixture/after"
update_definition_preserved "$fixture/before" "$fixture/after"
for filter in '.definition.host.Binds[0]="/other:/data:ro"' '.definition.host.Binds[0]="/second:/data:rw"' '.definition.host.Memory=456' '.definition.userEnv.PRIVATE="changed"' '.definition.host.Dns|=reverse' '.definition.host.Binds += ["/first:/config:rw"]';do
 jq "$filter" "$fixture/after" >"$fixture/drift"
 if update_definition_preserved "$fixture/before" "$fixture/drift";then printf 'Real settings drift accepted: %s\n' "$filter";exit 1;fi
done
printf '{"schema":1,"jobs":{"job":{"name":"metafusion","status":"COMPLETED","startedAt":100,"verifiedAt":200}},"items":{},"delivered":{},"outbox":[],"normalDeliveryIds":[]}' >"$STATE_FILE"
publish(){ mv "$1" "$2"; }
NOTIFY_BIN="$fixture/notify";LOG_FILE="$fixture/log"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/mail"\n' "$fixture" >"$NOTIFY_BIN";chmod +x "$NOTIFY_BIN"
event normal 'Removed application/plugin retired from updates' 'prowlarr: absent on complete inventory observations' retired-update:docker:prowlarr:1
event normal 'Update installed; startup verification pending' 'metafusion: application startup pending' startup:job
event alert 'Update outcome requires attention' 'metafusion: previous mismatch' attention:job
flush_notifications
# Resolved warning is presented as historical. Unrelated routine notices remain.
grep -q 'Historical update condition; now verified' "$fixture/mail"
if grep -q 'prowlarr:' "$fixture/mail";then echo 'Unrelated retirement mixed into urgent delivery';exit 1;fi
jq -e '(.outbox|length)==2 and all(.outbox[];.importance=="normal")' "$STATE_FILE" >/dev/null
mutate '.normalDeliveryIds=[.outbox[].id]'
flush_notifications
[[ $(jq '.outbox|length' "$STATE_FILE") == 0 ]]
event normal 'Update verification recovered' 'metafusion: verified after earlier warning' recovered:job
flush_notifications
[[ $(jq '.outbox|length' "$STATE_FILE") == 0 ]]
printf 'Mount-order equivalence, real drift refusal, resolved history, urgent/daily separation and recovery delivery passed\n'
# Completing an install retires the matching cached candidate, not a newer one.
jq -n '{schema:1,items:{"docker:sonarr":{kind:"docker",name:"sonarr",identity:"repo:develop",candidate:"approved",available:true,checkStatus:"VERIFIED"}},jobs:{done:{item:"docker:sonarr",kind:"docker",name:"sonarr",identity:"repo:develop",candidate:"approved",verifiedAt:200,status:"COMPLETED"}},outbox:[],delivered:{}}' >"$STATE_FILE"
record_verified_installation done
jq -e '.items["docker:sonarr"].available==false and .items["docker:sonarr"].refreshAfterInstall==true' "$STATE_FILE" >/dev/null
mutate '.items["docker:sonarr"].candidate="newer"|.items["docker:sonarr"].available=true'
record_verified_installation done
jq -e '.items["docker:sonarr"].available==true and .items["docker:sonarr"].candidate=="newer"' "$STATE_FILE" >/dev/null
mutate '.items["docker:qbittorrent"]={kind:"docker",name:"qbittorrent",identity:"repo",candidate:"next",available:true,checkStatus:"VERIFIED"}|.jobs.bazarr={item:"docker:bazarr",name:"bazarr",status:"ATTENTION"}'
summary=$(update_queue_summary)
[[ "$summary" == *sonarr* && "$summary" == *qbittorrent* && "$summary" == *bazarr* ]]
printf 'Verified installs clear only matching candidates; newer candidates and full multi-app queue remain visible\n'
log(){ printf '%s\n' "$*" >>"$TMP_DIR/queue-log"; }
log_update_queue_changes;count=$(wc -l <"$TMP_DIR/queue-log")
log_update_queue_changes
[[ $(wc -l <"$TMP_DIR/queue-log") == "$count" ]]
grep -q docker:sonarr "$TMP_DIR/queue-log";grep -q docker:qbittorrent "$TMP_DIR/queue-log"
printf 'Changed per-app holds are logged once without hiding other queued applications\n'
