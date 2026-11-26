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
