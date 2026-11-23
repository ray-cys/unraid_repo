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
# A guard probe must release its shared lock immediately, never for the scan.
lock="$fixture/backup.lock";touch "$lock"
probe_lock "$lock"
flock -n "$lock" true
printf 'Previous-state recovery, file-backed large checkpoints, notification retry/dedup, inventory silence and short backup-lock checks passed\n'
