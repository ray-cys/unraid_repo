#!/bin/bash
# Only owned temporary recovery fixtures; no Docker or native plugin commands.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/system_update_coordinator.sh"
fixture=$(mktemp -d /tmp/update-retention.XXXXXX);trap 'rm -rf -- "$fixture"' EXIT
TMP_DIR="$fixture/tmp";STATE_DIR="$fixture/state";mkdir "$TMP_DIR" "$STATE_DIR"
STATE_FILE="$STATE_DIR/state.json";STATE_EXPORT_LOCK="$fixture/export.lock"
ROLLBACK_ROOT="$fixture/vault/backup/system_updates";mkdir -p "$ROLLBACK_ROOT"
printf 'system_update_coordinator\n' >"$ROLLBACK_ROOT/.owner"
for id in old1 old2 new3 pending4;do
 mkdir "$ROLLBACK_ROOT/$id";printf '%s\n' "$id" >"$ROLLBACK_ROOT/$id/.owner"
 printf 'owned recovery payload\n' >"$ROLLBACK_ROOT/$id/image.tar.gz"
done
printf 'old plugin definition\n' >"$ROLLBACK_ROOT/old2/installed.plg"
jq -n --arg root "$ROLLBACK_ROOT" '{schema:1,items:{},outbox:[],delivered:{},jobs:{old1:{kind:"docker",status:"COMPLETED",verifiedAt:1,recoveryPath:($root+"/old1")},old2:{kind:"plugin",status:"COMPLETED",verifiedAt:2,recoveryPath:($root+"/old2")},new3:{kind:"docker",status:"COMPLETED",verifiedAt:3,recoveryPath:($root+"/new3")},pending4:{kind:"docker",status:"ATTENTION",startedAt:4,recoveryPath:($root+"/pending4")}}}' >"$STATE_FILE"
clean_recovery_sets
[[ ! -e "$ROLLBACK_ROOT/old1" && -f "$ROLLBACK_ROOT/old2/installed.plg" && -f "$ROLLBACK_ROOT/new3/image.tar.gz" && -f "$ROLLBACK_ROOT/pending4/image.tar.gz" ]]
jq -e '.jobs.old1.recoveryPrunedAt>0 and .jobs.pending4.recoveryPrunedAt==null' "$STATE_FILE" >/dev/null
# An unexpected/unowned path cannot be deleted by retention.
mkdir "$ROLLBACK_ROOT/unowned";printf 'retain\n' >"$ROLLBACK_ROOT/unowned/image.tar.gz"
mutate --arg path "$ROLLBACK_ROOT/unowned" '.jobs.unowned={kind:"docker",status:"COMPLETED",verifiedAt:0,recoveryPath:$path}'
clean_recovery_sets
[[ -f "$ROLLBACK_ROOT/unowned/image.tar.gz" ]]
printf 'Latest two completed recovery sets retained globally; unresolved and unowned data preserved\n'
