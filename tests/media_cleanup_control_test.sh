#!/usr/bin/env bash
# Fault tests use temporary files and mock modules; never live cleanup/services.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/media_cleanup.sh"
fixture=$(mktemp -d /tmp/media-cleanup-control.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
MC_ROOT="$fixture/state";mkdir "$MC_ROOT"
MC_LOCK="$fixture/run.lock";MC_LOG_LOCK="$fixture/log.lock";MC_NOTIFY_LOCK="$fixture/notify.lock"
STATE_EXPORT_LOCK="$fixture/export.lock";MC_STATUS_DIR="$fixture/status";MC_EMERGENCY_MARKER="$fixture/emergency"
MC_NOTIFY_BIN="$fixture/notify";MC_NOTIFY_TIMEOUT_SECONDS=1;MC_LOCK_WAIT_SECONDS=1
mc_state_ready() { return 0; }
printf '#!/bin/bash\nflock -x -n %q -c true || exit 9\nprintf "sent\\n" >>%q\n' "$STATE_EXPORT_LOCK" "$fixture/mail" >"$MC_NOTIFY_BIN"
chmod +x "$MC_NOTIFY_BIN"
mc_parse_cli all --dry-run;[[ "$MC_ROUTE" == all && "$MC_EFFECTIVE_DRY" == true ]]
if mc_parse_cli --execute --dry-run;then exit 1;fi
if mc_parse_cli all --execute --dry-run;then exit 1;fi
if mc_parse_cli all unexpected;then exit 1;fi
MC_DRY_RUN=true;mc_parse_cli quarantine purge;[[ "${MC_ARGS[0]}" == audit ]]
if mc_parse_cli quarantine restore RUN movies file;then exit 1;fi
mc_parse_cli quarantine --execute restore RUN movies file;[[ "$MC_EFFECTIVE_DRY" == false && "${MC_ARGS[0]}" == restore ]]
MC_DRY_RUN=false
mc_parse_cli sab --recover-orphan ExactFolder;[[ "$MC_EFFECTIVE_DRY" == true ]]
mc_parse_cli sab --recover-orphan ExactFolder --execute;[[ "$MC_EFFECTIVE_DRY" == false ]]
# Central structured reconciliation and replay receipts.
jq -n '{events:[{nativeId:"fixed-source-id",module:"sab",kind:"action",topic:"sab:sample",eventGroup:"x",importance:"normal",subject:"Action",description:"Action performed",message:"Moved named payload to quarantine",epoch:1}],topics:{}}' >"$fixture/event.json"
mc_accept_records "$fixture/event.json"
mc_flush
[[ $(wc -l <"$fixture/mail") == 1 ]]
mc_accept_records "$fixture/event.json"
jq -e '.events|length==0' "$MC_ROOT/notification-outbox.json" >/dev/null
# Native topics still hand off on a day the actual email was already sent.
MC_BRIDGE_ACTIVE=true;MC_MODULE=sab;LOG_DIR="$fixture/producer";mkdir "$LOG_DIR"
OPS_NOTIFICATION_STATE="$LOG_DIR/notification-state.json";LOG_LEVEL=INFO
OPS_SCRIPT_NAME=arr_sabnzbd_cleanup;OPS_SCRIPT_VERSION=2.8;OPS_RUN_ID=fixture;OPS_ATTENTION_DETAILS=''
ops_set_topic sample attention 'API check unavailable'
ops_notify warning Fixture 'API check failed' 'Payloads preserved' sample attention
jq -e 'any(.events[];.topic=="sab:sample" and .kind=="attention")' "$MC_ROOT/notification-outbox.json" >/dev/null
ops_set_topic sample healthy 'API check restored'
jq -e 'all(.events[];.kind!="attention") and any(.events[];.kind=="resolved")' "$MC_ROOT/notification-outbox.json" >/dev/null
# A timed out notification preserves pending data and the daily acceptance date.
jq '.lastSentDate=""' "$MC_ROOT/notification-outbox.json" >"$fixture/next";mv "$fixture/next" "$MC_ROOT/notification-outbox.json"
printf '#!/bin/bash\nsleep 10\n' >"$MC_NOTIFY_BIN"
if mc_flush;then exit 1;fi
jq -e '.lastSentDate=="" and (.events|length)>0' "$MC_ROOT/notification-outbox.json" >/dev/null
# Mover skips and backup-stage stops have explicit structured outcomes.
MC_TMP="$fixture/work";mkdir "$MC_TMP"
RUN_INITIALIZED=true;ERRORS=0;MOVER_GUARD_TRIGGERED=true
BACKUP_CLEANUP_STATUS=MOVER_SKIPPED;STRANDED_CLEANUP_STATUS=MOVER_SKIPPED;QUARANTINE_PURGE_STATUS=MOVER_SKIPPED
mc_finish_module sab 0
jq -e '.status=="DEFERRED"' "$MC_TMP/sab.result.json" >/dev/null
MOVER_GUARD_TRIGGERED=false;BACKUP_CLEANUP_STATUS=SKIPPED_CONFIGURATION;STRANDED_CLEANUP_STATUS=DISABLED;QUARANTINE_PURGE_STATUS=DISABLED
mc_finish_module sab 0
jq -e '.status=="WARNING"' "$MC_TMP/sab.result.json" >/dev/null
# Read-only listing is successful even though no purge result is initialized.
(
 RESULT_STATUS=FAILED;RESULT_SUMMARY='Not a purge run'
 mc_finish_module quarantine 0 --pending-operations
 jq -e '.status=="COMPLETED"' "$MC_TMP/quarantine.result.json" >/dev/null
 LOG_READY=true;MC_MODULE_STATUS=DEFERRED;MC_MODULE_REASON='Producer lock active'
 mc_finish_module arr 0
 jq -e '.status=="DEFERRED"' "$MC_TMP/arr.result.json" >/dev/null
)
# A real child group cancellation stops its descendants before temp cleanup.
(
 MC_CHILD_PID='';MC_CHILDREN_UNREAPED=false
 set -m
 (trap - EXIT INT TERM;set +m;sleep 3;touch "$fixture/should-not-exist") &
 MC_CHILD_PID=$!;set +m
 mc_stop_child
 [[ "$MC_CHILDREN_UNREAPED" == false ]]
)
[[ ! -e "$fixture/should-not-exist" ]]
# File-backed Arr handoff retains all detail parts of one keyed condition.
jq -nc '[range(0;2)|{runId:"fixture",queuedAt:"2026-11-24T00:00:00+0800",event:"attention",severity:"WARNING",app:"Sonarr",key:"folder:1",signature:"same",title:("Example (detail part "+((.+1)|tostring)+")"),detail:("detail-"+tostring),chunkOffset:(.*600)}]|.[]' >"$fixture/arr-events"
mc_handoff_arr "$fixture/arr-events"
jq -e '[.events[]|select(.topic=="arr:folder:1")]|length==2' "$MC_ROOT/notification-outbox.json" >/dev/null
# Timing wrappers preserve both output and exit status, including Arr's IFS.
(
 APP_CONTEXT=SONARR;MC_COMPONENT_STARTED=$(date +%s)
 fake_api() { printf '{"verified":true}';return 7; }
 result=0;output=$(mc_timed_call api fake_api) || result=$?
 [[ "$result" == 7 && "$output" == '{"verified":true}' ]]
 log() { printf '%s\n' "$*" >"$fixture/timing-report"; }
 IFS=$'\n\t';mc_arr_metrics
 grep -Eq 'api=[0-9]+ms sidecar-capture=[0-9]+ms' "$fixture/timing-report"
)
# A failed final receipt must produce attention and a nonzero exit, never OK.
(
 trap - EXIT INT TERM
 printf '#!/bin/bash\nprintf "sent\\n" >>%q\n' "$fixture/mail" >"$MC_NOTIFY_BIN"
 eval "$(declare -f mc_record_status | sed '1s/mc_record_status/original_mc_record_status/')"
 mc_record_status() { [[ "${MC_RESULT:-}" != OK && "${MC_RESULT:-}" != ATTENTION ]] || return 1;original_mc_record_status; }
 mc_arr() { LOG_READY=true;mc_finish_module arr 0; }
 mc_sab() { RUN_INITIALIZED=true;MOVER_GUARD_TRIGGERED=false;ERRORS=0;BACKUP_CLEANUP_STATUS=COMPLETED;STRANDED_CLEANUP_STATUS=COMPLETED;QUARANTINE_PURGE_STATUS=COMPLETED;mc_finish_module sab 0; }
 mc_quarantine() { RESULT_STATUS=OK;mc_finish_module quarantine 0; }
 result=0;mc_main all || result=$?
 [[ "$result" != 0 && "$MC_RESULT" == ATTENTION ]]
 trap - EXIT INT TERM
 rm -rf -- "$MC_TMP"
)
# Exercise the real top-level TERM trap, using an inert sleeping module.
cat >"$fixture/cancel-driver" <<'DRIVER'
#!/usr/bin/env bash
source "$1"
MC_ROOT="$2";mkdir -p "$MC_ROOT"
MC_LOCK="$MC_ROOT/run.lock";MC_NOTIFY_LOCK="$MC_ROOT/notify.lock";MC_LOG_LOCK="$MC_ROOT/log.lock"
STATE_EXPORT_LOCK="$MC_ROOT/export.lock";MC_STATUS_DIR="$MC_ROOT/status";MC_NOTIFY_BIN=/bin/true
mc_state_ready() { return 0; }
mc_arr() { sleep 20;touch "$MC_ROOT/unsafe-late-write"; }
mc_main all
DRIVER
bash "$fixture/cancel-driver" "$repo/user_script/media_cleanup.sh" "$fixture/cancel" >"$fixture/cancel-output" 2>&1 & driver=$!
for ((n=0;n<100;n++));do [[ ! -f "$fixture/cancel/media-cleanup.log" ]] || { grep -q 'Starting module=arr' "$fixture/cancel/media-cleanup.log" && break; };sleep .03;done
kill -TERM "$driver"
code=0;wait "$driver" || code=$?
[[ "$code" == 143 && ! -e "$fixture/cancel/unsafe-late-write" ]]
jq -e '.status=="FAILED" and .phase=="arr"' "$fixture/cancel/latest-run.json" >/dev/null
flock -x -n "$fixture/cancel/run.lock" -c true
printf 'Strict previews, topic reconciliation, replay receipts, notification timeout/export lease, skip statuses and child-group cancellation passed\n'
