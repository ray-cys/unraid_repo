#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/watchdog-retirement.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
source "$repo/user_script/docker_service_watchdog.sh"
STATE_DIR="$fixture";STATE_WORK="$fixture/state";STATE_FILE="$fixture/saved-state";TMP_DIR="$fixture/tmp";mkdir "$TMP_DIR"
LOG_FILE="$fixture/log";NOW=$(date +%s)
UPDATE_COORDINATOR_STATE_FILE="$fixture/update-journal"
SERVICE_SPECS=('seerr||always|1');CONTAINER_ALIASES=();EXTERNAL_SERVICES=();DISABLED_SERVICES=();DISCOVER_UNCLASSIFIED=true
jq -n '{version:2,services:{seerr:{id:"old",oom:false,restartCount:0,failures:3}},recovery:{seerr:{attempts:1,last:0,window:0}},jobs:{},observations:{"seerr:availability":{active:true,bad:3,good:0,first:0,severity:"CRITICAL",message:"old error"}},notification:{issues:{"seerr:availability":"CRITICAL"}}}' >"$STATE_WORK"
inventory_present=false;inventory_failure=false
docker_cmd(){ [[ "$inventory_failure" != true ]] || return 1;[[ "$inventory_present" != true ]] || printf 'seerr\n'; }
resolve_inventory
jq -e '.inventory.seerr.missing==1 and .observations["seerr:availability"].active==true' "$STATE_WORK" >/dev/null
[[ ${#EFFECTIVE_SPECS[@]} == 0 ]]
NOW=$((NOW+300));resolve_inventory
jq -e '.inventory.seerr.retiredAt>0 and .services.seerr==null and .recovery.seerr==null and .observations["seerr:availability"].active==false and (.inventoryOutbox|length)==1' "$STATE_WORK" >/dev/null
NOTIFY_BIN="$fixture/notify";printf '#!/bin/bash\nexit 1\n' >"$NOTIFY_BIN";chmod +x "$NOTIFY_BIN"
if notify_changes;then exit 1;fi
jq -e '.inventoryOutbox.seerr!=null' "$STATE_WORK" >/dev/null
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >"%s/mail"\n' "$fixture" >"$NOTIFY_BIN"
notify_changes
grep -q 'Retired monitoring: seerr' "$fixture/mail"
if grep -q 'Resolved: seerr' "$fixture/mail";then exit 1;fi
jq -e '(.inventoryOutbox|length)==0' "$STATE_WORK" >/dev/null
NOW=$((NOW+300));resolve_inventory
jq -e '(.inventoryOutbox|length)==0' "$STATE_WORK" >/dev/null
before=$(sha256sum "$STATE_WORK")
inventory_failure=true
if resolve_inventory;then exit 1;fi
[[ "$before" == "$(sha256sum "$STATE_WORK")" ]]
inventory_failure=false;inventory_present=true;resolve_inventory
[[ ${#EFFECTIVE_SPECS[@]} == 1 ]]
jq -e '.inventory.seerr.missing==0 and .inventory.seerr.retiredAt==null' "$STATE_WORK" >/dev/null
printf 'Confirmed removal retires monitoring once, delivery is durable, outage cannot retire, and reinstallation reactivates its existing profile\n'
# Durable coordinator intents also prohibit recovery after a killed updater,
# independently of a temporary maintenance lease expiring.
printf '{"schema":1,"jobs":{"one":{"kind":"docker","name":"seerr","status":"INTENT"}}}' >"$UPDATE_COORDINATOR_STATE_FILE"
maintenance_active seerr
printf '{"schema":1,"jobs":{"one":{"kind":"docker","name":"seerr","status":"COMPLETED"}}}' >"$UPDATE_COORDINATOR_STATE_FILE"
if maintenance_active seerr;then exit 1;fi
printf 'Pending native-update journal suppresses watchdog recovery; completed update releases that protection\n'

printf '{"schema":1,"jobs":{"plugin":{"kind":"plugin","name":"tailscale.plg","status":"INTENT"}}}' >"$UPDATE_COORDINATOR_STATE_FILE"
maintenance_active seerr
printf '{"schema":1,"jobs":{"plugin":{"kind":"plugin","name":"tailscale.plg","status":"VERIFYING"}}}' >"$UPDATE_COORDINATOR_STATE_FILE"
if maintenance_active seerr;then exit 1;fi
printf '{"schema":1,"jobs":{"plugin":{"kind":"plugin","name":"tailscale.plg","status":"ATTENTION"}}}' >"$UPDATE_COORDINATOR_STATE_FILE"
maintenance_active seerr
printf 'Host-plugin dispatch/uncertainty protects unrelated Docker apps without suppressing normal post-install monitoring\n'
