#!/bin/bash
# shellcheck disable=SC2034
# Export only temporary optional audit state; no ISS connection or Docker call.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/vault_backup.sh"
fixture=$(mktemp -d /tmp/media-integrity-export.XXXXXX);fixture=$(realpath "$fixture")
trap 'rm -rf -- "$fixture"' EXIT
OPERATIONS_STATE_MOUNT_ROOT="$fixture/vault"
OPERATIONS_STATE_ROOT="$OPERATIONS_STATE_MOUNT_ROOT/backup/operations_state"
OPERATIONS_SCRIPT_ROOT="$fixture/scripts"
OPERATIONS_REQUIRED_STATE_FILES=(arr_health_activity/state.json)
STATE_EXPORT_LOCK="$fixture/export.lock"
mkdir -p "${OPERATIONS_STATE_ROOT%/*}" "$OPERATIONS_SCRIPT_ROOT/arr_health_activity" "$OPERATIONS_SCRIPT_ROOT/media_integrity_audit"
printf '{}' >"$OPERATIONS_SCRIPT_ROOT/arr_health_activity/state.json"
printf '{"schema":1,"files":{}}' | gzip -c >"$OPERATIONS_SCRIPT_ROOT/media_integrity_audit/state.json.gz"
printf '{"sentAt":0}' >"$OPERATIONS_SCRIPT_ROOT/media_integrity_audit/notified.json"
# A dated previous checkpoint is deliberately not exported.
printf old >"$OPERATIONS_SCRIPT_ROOT/media_integrity_audit/state.previous.json.gz"
vault_capture_recovery() { mkdir "$1";printf '{}' >"$1/inventory.json"; }
log() { :; }
vault_export_operations_state
[[ -f "$OPERATIONS_STATE_ROOT/media_integrity_audit/state.json.gz" && ! -e "$OPERATIONS_STATE_ROOT/media_integrity_audit/state.previous.json.gz" ]]
gzip -t "$OPERATIONS_STATE_ROOT/media_integrity_audit/state.json.gz"
printf corrupt >"$OPERATIONS_SCRIPT_ROOT/media_integrity_audit/state.json.gz"
vault_export_operations_state
[[ ! -e "$OPERATIONS_STATE_ROOT/media_integrity_audit/state.json.gz" && -f "$OPERATIONS_STATE_ROOT/arr_health_activity/state.json" ]]
printf '{"schema":1,"files":{}}' | gzip -c >"$OPERATIONS_SCRIPT_ROOT/media_integrity_audit/state.json.gz"
queue_bytes=$(stat -c %s "$OPERATIONS_SCRIPT_ROOT/media_integrity_audit/state.json.gz")
notify_bytes=$(stat -c %s "$OPERATIONS_SCRIPT_ROOT/media_integrity_audit/notified.json")
OPERATIONS_STATE_MAX_BYTES=$((2+queue_bytes+notify_bytes+1))
vault_export_operations_state
[[ ! -d "$OPERATIONS_STATE_ROOT/media_integrity_audit" && -f "$OPERATIONS_STATE_ROOT/arr_health_activity/state.json" ]]
printf 'Optional compressed queue exports safely; previous snapshots/logs excluded; invalid queue does not block data-backup state export\n'
