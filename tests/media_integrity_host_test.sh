#!/bin/bash
# shellcheck disable=SC2034
# Temporary host-state and notification fixtures; no Docker/library actions.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/media_integrity_audit.sh"
fixture=$(mktemp -d /tmp/media-integrity-host-test.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
STATE_DIR="$fixture/state";STATUS_DIR="$fixture/status";TMP_DIR="$fixture/tmp"
mkdir -p "$STATE_DIR" "$STATUS_DIR" "$TMP_DIR"
STATE_FILE="$STATE_DIR/state.json.gz";PREVIOUS_STATE_FILE="$STATE_DIR/state.previous.json.gz"
LOG_FILE="$STATE_DIR/audit.log";STATE_EXPORT_LOCK="$fixture/export.lock"
NOTIFY_BIN="$fixture/notify"
printf '{"schema":1,"files":{}}' | gzip -c >"$PREVIOUS_STATE_FILE"
printf corrupt >"$STATE_FILE"
load_state
[[ "$RECOVERY_NOTE" == *'previous validated'* ]]
gzip -dc "$PREVIOUS_STATE_FILE" | jq -e '.schema==1' >/dev/null
# JSON payload beyond exec argument limits travels through files/stdin only.
head -c 250000 /dev/urandom | base64 >"$fixture/blob"
jq -n --rawfile blob "$fixture/blob" '{schema:1,files:{},padding:$blob}' >"$fixture/large.json"
gzip -c "$fixture/large.json" | base64 | tr -d '\n' >"$fixture/payload"
jq -n --rawfile payload "$fixture/payload" '{type:"checkpoint",payload:$payload,stats:{inventoryFiles:0,inventoryComplete:true,quickPassed:0,segmentsPassed:0,cyclesCompleted:0}}' >"$fixture/event.json"
event=$(cat "$fixture/event.json")
save_checkpoint "$event"
unpack_state "$STATE_FILE"
[[ $(jq -r '.padding|length' "$TMP_DIR/state.json") -gt 200000 ]]
printf '#!/bin/sh\nexit 1\n' >"$NOTIFY_BIN";chmod 755 "$NOTIFY_BIN"
WORKER_FINISHED=true;MODE=scan
write_report OK fixture
[[ -f "$STATE_DIR/pending-notification.json" ]]
jq -e '.notification=="failed"' "$STATUS_DIR/media_integrity_audit.json" >/dev/null
printf '#!/bin/sh\nprintf "sent\\n" >>"%s/calls"\n' "$fixture" >"$NOTIFY_BIN"
write_report OK fixture
[[ ! -e "$STATE_DIR/pending-notification.json" ]]
write_report OK fixture
[[ $(wc -l <"$fixture/calls") == 1 ]]
MODE=inventory;write_report INVENTORY_ONLY fixture
[[ $(wc -l <"$fixture/calls") == 1 ]]
# Routine healthy work and healthy recovery transitions remain silent.
RECOVERY_NOTE="";MODE=scan
write_report OK 'Healthy ordinary scan'
jq -e '.notification=="suppressed"' "$STATUS_DIR/media_integrity_audit.json" >/dev/null
[[ $(wc -l <"$fixture/calls") == 1 ]]
# Progress changes alone never generate a healthy email.
printf '{"inventoryComplete":true,"quickPassed":99,"segmentsPassed":42}' >"$TMP_DIR/stats.json"
write_report OK 'More healthy progress'
[[ $(wc -l <"$fixture/calls") == 1 ]]
# An actual worker failure still notifies with operational detail.
write_report FAILED 'Decoder worker unexpectedly exited'
[[ $(wc -l <"$fixture/calls") == 2 ]]
# Resolving the failure does not produce a success email.
write_report OK 'Recovered worker'
[[ $(wc -l <"$fixture/calls") == 2 ]]
# Findings and recovery failures must contain useful actions/evidence, while
# changed progress alone must not resend the same incident.
RECOVERY_FILE="$STATE_DIR/recovery.json"
jq '.files["series/Example/episode.mkv"]={identity:["1","2","3","4","5"],issue:{id:"finding",kind:"decode_error",confirmed:true,confirmedRuns:2,evidence:"Invalid NAL unit",offset:600}}' "$TMP_DIR/state.json" >"$fixture/new-state"
gzip -c "$fixture/new-state" >"$STATE_FILE"
jq -n --argjson now "$(date +%s)" '{schema:1,workflow:"arr-native",actions:{("a"*64):{app:"Sonarr",parentId:20,fileId:31,targets:[32],path:"series/Example/episode.mkv",identity:["1","2","3","4","5"],events:[],status:"review",startedAt:$now,updatedAt:$now,reason:"Search response unavailable; no retry"}}}' >"$RECOVERY_FILE"
write_report WARNING 'Recovery needs review'
jq -e '.status=="WARNING" and .recoveryAttention==1 and (.body|contains("Search response unavailable; no retry")) and (.body|contains("Invalid NAL unit")) and (.body|contains("Next action:"))' "$STATUS_DIR/media_integrity_audit.json" >/dev/null
[[ $(wc -l <"$fixture/calls") == 3 ]]
printf '{"inventoryComplete":true,"quickPassed":100,"segmentsPassed":99}' >"$TMP_DIR/stats.json"
write_report WARNING 'More progress with unchanged finding'
[[ $(wc -l <"$fixture/calls") == 3 ]]
# Verified replacements generate one grouped completion email, then deduplicate.
jq '.actions[].status="recovered"' "$RECOVERY_FILE" >"$fixture/new-recovery";mv "$fixture/new-recovery" "$RECOVERY_FILE"
jq '.files[].issue=null' "$fixture/new-state" | gzip -c >"$STATE_FILE"
write_report OK 'Recovery verified'
[[ $(wc -l <"$fixture/calls") == 4 ]]
write_report OK 'Repeated verified observation'
[[ $(wc -l <"$fixture/calls") == 4 ]]
# Completion delivery failure remains pending until acknowledged by notify;
# successful retry produces one completion message, then remains quiet.
jq '.actions[("b"*64)]=(.actions[("a"*64)]+{reason:"Another verified native replacement"})' "$RECOVERY_FILE" >"$fixture/new-recovery";mv "$fixture/new-recovery" "$RECOVERY_FILE"
printf '#!/bin/sh\nexit 1\n' >"$NOTIFY_BIN"
write_report OK 'Completion delivery failure'
[[ -f "$STATE_DIR/pending-notification.json" ]]
printf '#!/bin/sh\nprintf "sent\\n" >>"%s/calls"\n' "$fixture" >"$NOTIFY_BIN"
write_report OK 'Completion delivery retry'
[[ $(wc -l <"$fixture/calls") == 5 && ! -e "$STATE_DIR/pending-notification.json" ]]
write_report OK 'Duplicate completion poll'
[[ $(wc -l <"$fixture/calls") == 5 ]]
# A guard probe must release its shared lock immediately, never for the scan.
lock="$fixture/backup.lock";touch "$lock"
probe_lock "$lock"
flock -n "$lock" true
printf 'Previous-state recovery, file-backed large checkpoints, notification retry/dedup, inventory silence and short backup-lock checks passed\n'
