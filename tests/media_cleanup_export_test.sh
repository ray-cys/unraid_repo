#!/usr/bin/env bash
# Merged control-plane state and receipts survive restore export; no live calls.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/vault_backup.sh"
fixture=$(mktemp -d /tmp/media-cleanup-export.XXXXXX); fixture=$(realpath "$fixture")
trap 'rm -rf -- "$fixture"' EXIT
OPERATIONS_STATE_MOUNT_ROOT="$fixture/vault"
OPERATIONS_STATE_ROOT="$OPERATIONS_STATE_MOUNT_ROOT/backup/operations_state"
OPERATIONS_SCRIPT_ROOT="$fixture/live"
STATE_EXPORT_LOCK="$fixture/export.lock"
OPERATIONS_REQUIRED_STATE_FILES=(media_cleanup/arr/sonarr-state.json media_cleanup/arr/radarr-state.json)
mkdir -p "${OPERATIONS_STATE_ROOT%/*}" "$OPERATIONS_SCRIPT_ROOT/media_cleanup/arr" "$OPERATIONS_SCRIPT_ROOT/media_cleanup/sab/purge-receipts" "$OPERATIONS_SCRIPT_ROOT/media_cleanup/quarantine/purge-receipts"
for file in arr/sonarr-state.json arr/radarr-state.json arr/pending-actions.json sab/pending-operations.json quarantine/pending-operations.json notification-outbox.json latest-run.json; do
 printf '{"preserved":true}' >"$OPERATIONS_SCRIPT_ROOT/media_cleanup/$file"
done
printf '{"proof":"exact payload"}\n' >"$OPERATIONS_SCRIPT_ROOT/media_cleanup/sab/purge-receipts/run.jsonl"
printf 'path\tbytes\nExample/poster.jpg\t1024\n' >"$OPERATIONS_SCRIPT_ROOT/media_cleanup/quarantine/purge-receipts/run.tsv"
mkdir -p "$OPERATIONS_SCRIPT_ROOT/vault_backup"
printf '{"schema":1,"activeFailure":{"signature":"preserved"}}' >"$OPERATIONS_SCRIPT_ROOT/vault_backup/notification-state.json"
printf 'not exported' >"$OPERATIONS_SCRIPT_ROOT/media_cleanup/media-cleanup.log"
vault_capture_recovery() { mkdir "$1";printf '{}' >"$1/inventory.json"; }
log() { :; }
vault_export_operations_state
for file in arr/sonarr-state.json arr/radarr-state.json arr/pending-actions.json sab/pending-operations.json quarantine/pending-operations.json notification-outbox.json latest-run.json sab/purge-receipts/run.jsonl quarantine/purge-receipts/run.tsv; do
 cmp "$OPERATIONS_SCRIPT_ROOT/media_cleanup/$file" "$OPERATIONS_STATE_ROOT/media_cleanup/$file"
done
[[ ! -e "$OPERATIONS_STATE_ROOT/media_cleanup/media-cleanup.log" ]]
[[ ! -e "$OPERATIONS_STATE_ROOT/arr_delete_sync_tag" ]]
cmp "$OPERATIONS_SCRIPT_ROOT/vault_backup/notification-state.json" "$OPERATIONS_STATE_ROOT/vault_backup/notification-state.json"
printf 'Merged nested state, pending operations, unsent notification and purge receipts exported; logs excluded\n'
