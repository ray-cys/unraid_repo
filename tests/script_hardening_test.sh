#!/bin/bash
# Isolated supervision, delivery-failure and bounded Plex restore regressions.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/script-hardening.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
export ROOT fixture
export USR_OPS_EXECUTION_ROOT="$fixture/execution" USR_OPS_EXECUTION_PERSISTENT_ROOT="$fixture/persistent" USR_OPS_VAULT_MOUNT="$fixture/no-mount"
cat >"$fixture/worker" <<'WORKER'
#!/bin/bash
source "$ROOT/tools/operations_contract.sh"
OPS_SCRIPT_ID=fixture
if [[ "${USR_OPS_SUPERVISED:-}" != fixture ]];then usr_ops_supervise "$0";exit $?;fi
trap 'printf finalized >"$fixture/finalized"; exit 7' EXIT
exit 0
WORKER
if bash "$fixture/worker";then echo 'Finalizer failure was hidden';exit 1;else [[ $? == 7 ]];fi
[[ -f "$fixture/finalized" ]]
jq -e '.executionStatus=="FAILED" and .lastExitCode==7' "$USR_OPS_EXECUTION_ROOT/fixture.json" >/dev/null
printf 'Execution receipt reflects the final producer EXIT trap\n'
cat >"$fixture/worker" <<'SIGNAL'
#!/bin/bash
source "$ROOT/tools/operations_contract.sh"
OPS_SCRIPT_ID=fixture
if [[ "${USR_OPS_SUPERVISED:-}" != fixture ]];then usr_ops_supervise "$0";exit $?;fi
trap 'printf reconciled >"$fixture/interrupted";exit 143' TERM
for ((i=0;i<100;i++));do sleep 0.05;done
SIGNAL
bash "$fixture/worker" & parent=$!
for ((i=0;i<30;i++));do [[ -s "$USR_OPS_EXECUTION_ROOT/fixture.json" ]] && jq -e '.executionStatus=="RUNNING"' "$USR_OPS_EXECUTION_ROOT/fixture.json" >/dev/null && break;sleep 0.05;done
kill -TERM "$parent"
if wait "$parent";then exit 1;else [[ $? == 143 ]];fi
[[ $(cat "$fixture/interrupted") == reconciled ]]
jq -e '.executionStatus=="FAILED" and .lastExitCode==143' "$USR_OPS_EXECUTION_ROOT/fixture.json" >/dev/null
printf 'Supervisor forwards termination and records completion after producer reconciliation\n'
cat >"$fixture/worker" <<'ISOLATION'
#!/bin/bash
source "$ROOT/tools/operations_contract.sh"
OPS_SCRIPT_ID=fixture
usr_ops_execution_record(){ touch "$fixture/contaminated"; }
if [[ "${USR_OPS_SUPERVISED:-}" != fixture ]];then usr_ops_supervise "$0";exit $?;fi
exit 0
ISOLATION
env -u USR_OPS_EXECUTION_ROOT bash "$fixture/worker"
[[ ! -e "$fixture/contaminated" ]]
printf 'Repository/fixture execution cannot publish production completion records\n'


bash <<'DELIVERY'
set -euo pipefail
source "$ROOT/tools/operations_contract.sh"
OPS_SCRIPT_ID=backup_restore_drill
export USR_OPS_DELIVERY_ROOT="$fixture/outbox" USR_OPS_DELIVERY_LOCK="$fixture/delivery.lock"
mountpoint(){ return 0; }
export -f mountpoint
cat >"$fixture/notify" <<'MOCK'
#!/bin/bash
exit "${MOCK_RC:-0}"
MOCK
chmod +x "$fixture/notify"
NOTIFY_BIN="$fixture/notify"
export MOCK_RC=1
if usr_ops_notify "$NOTIFY_BIN" -i alert -s Fixture -d Failure -m 'Exact evidence';then exit 1;fi
[[ $(find "$USR_OPS_DELIVERY_ROOT" -name '*.json'|wc -l) == 1 ]]
export MOCK_RC=0
usr_ops_retry_deliveries
[[ $(find "$USR_OPS_DELIVERY_ROOT" -name '*.json'|wc -l) == 0 ]]
printf 'Failed notification retained exactly and removed only after successful retry\n'
OPS_SCRIPT_ID=backup_vault_remote;USR_OPS_DELIVERY_CONTEXT=fixture_signature;export MOCK_RC=1
if usr_ops_notify "$NOTIFY_BIN" -i alert -s Fixture -d Failure -m 'ISS exact failure';then exit 1;fi
export MOCK_RC=0
usr_ops_retry_deliveries
usr_ops_vault_delivery_seen fixture_signature 0
if usr_ops_vault_delivery_seen different_request 0;then exit 1;fi
printf 'ISS retry delivery records exact incident cooldown without suppressing a different request\n
' 
DELIVERY
bash <<'DB'
set -euo pipefail
source "$ROOT/user_script/media_plex_dbrepair.sh"
LOG_DIR="$fixture/db";mkdir "$LOG_DIR"
LOG_FILE="$LOG_DIR/log";NOTIFICATION_STATE_FILE="$LOG_DIR/state.json"
printf '{"version":1,"attention":{}}' >"$NOTIFICATION_STATE_FILE"
issue_signature_text(){ printf issue; }
build_summary_text(){ printf details; }
notify_unraid(){ NOTIFICATION_FAILED=1;return 1; }
RUN_HAS_REPAIR=0;RUN_HIGHEST_SEVERITY=warning
if update_notifications;then exit 1;fi
jq -e '.attention.lastNotifiedEpoch==0' "$NOTIFICATION_STATE_FILE" >/dev/null
issue_signature_text(){ :; }
if update_notifications;then exit 1;fi
jq -e '.attention.signature!=""' "$NOTIFICATION_STATE_FILE" >/dev/null
printf 'Failed DBRepair raise/resolution delivery cannot advance or clear lifecycle state\n'
DB
bash <<'RESTORE'
set -euo pipefail
source "$ROOT/user_script/backup_restore_drill.sh"
APPDATA_BACKUP="$fixture/backup";WORK_DIR="$fixture/drill";LOG_DIR="$fixture/restore-logs"
mkdir -p "$APPDATA_BACKUP" "$WORK_DIR" "$LOG_DIR"
LOG_FILE="$LOG_DIR/log";CHECK_SQLITE_DATABASES=false;MAX_EXTRACT_BYTES=32768
base="$fixture/input/plex-media-server/Library/Application Support/Plex Media Server"
mkdir -p "$base/Plug-in Support/Databases" "$base/Media"
printf 'preferences' >"$base/Preferences.xml"
printf 'fixture-db' >"$base/Plug-in Support/Databases/com.plexapp.plugins.library.db"
dd if=/dev/zero of="$base/Media/large.bin" bs=65536 count=1 status=none
tar -czf "$APPDATA_BACKUP/plex-media-server.tar.gz" -C "$fixture/input" plex-media-server
hash=$(sha256sum "$APPDATA_BACKUP/plex-media-server.tar.gz"|cut -d ' ' -f1)
bytes=$(stat -c %s "$APPDATA_BACKUP/plex-media-server.tar.gz")
printf '# archive_count=1\n0\t%s\t%s\tplex-media-server\n' "$bytes" "$hash" >"$APPDATA_BACKUP/backup_manifest.tsv"
(cd "$APPDATA_BACKUP" && sha256sum backup_manifest.tsv >backup_manifest.tsv.sha256)
select_appdata_archives
[[ "${PLEX_SELECTIVE[plex-media-server]}" == true ]]
drill_appdata
jq -e '.archives["plex-media-server"].scope=="databases_and_preferences"' "$LOG_DIR/restore-coverage.json" >/dev/null
[[ "${SELECTIVE_CHECKED[*]}" == plex-media-server ]]
printf 'Legacy unknown-size Plex archive receives bounded critical-file restore, not full Media extraction\n'
RESTORE
