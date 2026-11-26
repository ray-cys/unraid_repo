#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/media-reporting-contract.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
export fixture repo
bash <<'INTEGRITY'
set -euo pipefail
source "$repo/user_script/media_integrity_audit.sh"
TMP_DIR="$fixture/work";STATE_DIR="$fixture/state";STATUS_DIR="$fixture/status";mkdir -p "$TMP_DIR" "$STATE_DIR" "$STATUS_DIR"
: >"$STATE_DIR/state.json.gz"
STATE_FILE="$STATE_DIR/state.json.gz";LOG_FILE="$STATE_DIR/log";RECOVERY_FILE="$STATE_DIR/recovery.json"
printf '{"schema":1,"workflow":"arr-native","actions":{}}' >"$RECOVERY_FILE"
printf '{"schema":1,"files":{"movie.mkv":{"observedAt":1000,"verifiedAt":0,"issue":{"id":"fault","kind":"decode_error","confirmed":true,"confirmedRuns":2,"evidence":"repeatable decode fixture"}}}}' >"$fixture/input-state"
unpack_state(){ cp "$fixture/input-state" "$TMP_DIR/state.json"; }
STATE_EXPORT_LOCK="$fixture/export.lock";NOTIFY_BIN="$fixture/notify";export STATE_EXPORT_LOCK
cat >"$NOTIFY_BIN" <<'NOTIFY'
#!/bin/bash
flock -x -n "$STATE_EXPORT_LOCK" -c true || exit 9
printf 'accepted\n' >"$fixture/accepted"
NOTIFY
chmod +x "$NOTIFY_BIN";MODE=scan;WORKER_FINISHED=false;RECOVERY_NOTE=''
write_report WARNING 'Fixture repeatable corruption; no media action performed' >"$fixture/console"
[[ -s "$fixture/accepted" && ! -e "$STATE_DIR/pending-notification.json" ]]
jq -e '.coverage.knownFiles==1 and .coverage.pendingVerification==1 and .coverage.oldestPendingObservedAt==1000 and .recoveryEnabled==false and .notification=="sent"' "$STATUS_DIR/media_integrity_audit.json" >/dev/null
printf 'Integrity notification releases export lease; real report records coverage and keeps recovery disabled\n'
INTEGRITY
bash <<'METADATA'
set -euo pipefail
source "$repo/user_script/media_metadata_audit.sh"
STATE_EXPORT_LOCK="$fixture/metadata-export.lock";export STATE_EXPORT_LOCK
exec {METADATA_EXPORT_FD}>"$STATE_EXPORT_LOCK";flock -s "$METADATA_EXPORT_FD"
metadata_notify "$fixture/notify" -i warning -d 'Metadata fixture' -m 'Retained exact evidence'
flock -s -n "$METADATA_EXPORT_FD"
STATE_DIR="$fixture/metadata";STATUS_DIR="$fixture/status";mkdir "$STATE_DIR"
METADATA_STATUS=DEFERRED;METADATA_SUMMARY='MetaFusion active; no configuration changes';METADATA_WEEKLY_STATUS=FAILED;METADATA_STARTED=100;METADATA_PHASE=reconciliation
metadata_finish 0 >"$fixture/metadata-console"
jq -e '.status=="DEFERRED" and .weeklyReportStatus=="FAILED" and (.summary|contains("no configuration changes"))' "$STATUS_DIR/media_metadata_audit.json" >/dev/null
printf 'Metadata notification releases/reacquires export lease and deferred run preserves separate reporting failure\n'
METADATA
bash <<'MAINTENANCE'
set -euo pipefail
source "$repo/user_script/media_metadata_audit.sh"
STATE_DIR="$fixture/maintenance-state";STATUS_DIR="$fixture/maintenance-status";mkdir "$STATE_DIR" "$STATUS_DIR"
STATE_EXPORT_LOCK="$fixture/maintenance-export.lock";ARR_BACKUP_GATE="$fixture/appdata.lock"
mountpoint(){ return 0; };docker(){ touch "$fixture/unexpected-docker";return 1; }
exec {held}>"$ARR_BACKUP_GATE";flock -x "$held"
(main --weekly-report) >"$fixture/maintenance-console"
[[ ! -e "$fixture/unexpected-docker" ]]
jq -e '.status=="DEFERRED" and .weeklyReportStatus=="DEFERRED"' "$STATUS_DIR/media_metadata_audit.json" >/dev/null
printf 'Planned appdata downtime defers metadata reporting before Docker access and creates no false report failure\n'
MAINTENANCE
bash <<'PARENT'
set -euo pipefail
source <(awk '/^# LOCK$/{exit}{print}' "$repo/user_script/media_health_monitor.sh")
trap - EXIT INT TERM HUP
TMP_DIR="$fixture/parent";mkdir "$TMP_DIR"
STATE_EXPORT_LOCK="$fixture/parent-export.lock";export STATE_EXPORT_LOCK
exec {STATE_EXPORT_FD}>"$STATE_EXPORT_LOCK";flock -s "$STATE_EXPORT_FD"
MONITOR_STATE_LEASE_HELD=true;MONITOR_EXPORT_LEASE_LOST=false
START_TIME=$(date +%s);ARR_AUTOMATION_ENABLED=false
commit_state_transaction(){ touch "$fixture/parent-checkpoint"; }
MEDIA_INTEGRITY_SCRIPT="$fixture/child"
cat >"$MEDIA_INTEGRITY_SCRIPT" <<'CHILD'
#!/bin/bash
flock -x -n "$STATE_EXPORT_LOCK" -c true || exit 9
touch "$fixture/child-export-unblocked"
CHILD
process_media_integrity_recovery
[[ -f "$fixture/parent-checkpoint" && -f "$fixture/child-export-unblocked" && "$MONITOR_STATE_LEASE_HELD" == true ]]
printf 'Health parent releases its own export lease before the integrity child and reacquires before continuing state writes\n'
PARENT
