#!/usr/bin/env bash
# Inert notification/lease/coverage tests; no live email, Docker or API writes.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/arr-monitor-reliability.XXXXXX);fixture=$(realpath "$fixture")
trap 'rm -rf -- "$fixture"' EXIT
export repo fixture
bash <<'OUTBOX'
set -euo pipefail
source <(awk '/^# LOCK$/{exit}{print}' "$repo/user_script/arr_health_activity.sh")
trap - EXIT INT TERM HUP
log(){ :; };persistent_log(){ :; }
TMP_DIR="$fixture/outbox";mkdir "$TMP_DIR"
STATE_FILE="$TMP_DIR/state.json";NOTIFICATION_BATCH="$TMP_DIR/batch.jsonl";: >"$NOTIFICATION_BATCH"
printf '{"issues":{"issue":{"active":false,"lastNotifiedAt":1}},"monitor":{"notification":{}}}' >"$STATE_FILE"
save_state(){ mv -f "$1" "$STATE_FILE"; }
commit_state_transaction(){ cp "$STATE_FILE" "$TMP_DIR/disk.json"; }
MONITOR_OUTBOX_ACTIVE=true;SEND_NOTIFICATIONS=true
queue_group_notification issue resolved-signature Sonarr Title IMPORT_MISSING INFO 1 'Verified exact import; closed original warning' resolved
# Failed delivery preserves a durable resolution even though issue is inactive.
NOTIFY="$TMP_DIR/notify";printf '#!/bin/bash\nexit 1\n' >"$NOTIFY";chmod +x "$NOTIFY"
if send_grouped_notification;then exit 1;fi
jq -e '.monitor.notification.outbox|length==1' "$TMP_DIR/disk.json" >/dev/null
# Simulate restart with an empty RAM batch and the durable state only.
cp "$TMP_DIR/disk.json" "$STATE_FILE";: >"$NOTIFICATION_BATCH"
STATE_EXPORT_LOCK="$TMP_DIR/export.lock";exec {STATE_EXPORT_FD}>"$STATE_EXPORT_LOCK";flock -s "$STATE_EXPORT_FD"
MONITOR_STATE_LEASE_HELD=true
printf '#!/bin/bash\nflock -x -n %q -c true || exit 9\njq -e '\''.monitor.notification.outbox|length==1'\'' %q >/dev/null || exit 8\nprintf "accepted\\n" >>%q\n' "$STATE_EXPORT_LOCK" "$TMP_DIR/disk.json" "$TMP_DIR/mail" >"$NOTIFY"
send_grouped_notification
[[ $(wc -l <"$TMP_DIR/mail") == 1 && "$MONITOR_STATE_LEASE_HELD" == true ]]
jq -e '(.monitor.notification.outbox|length)==0 and .issues.issue.notifiedSignature=="resolved-signature"' "$TMP_DIR/disk.json" >/dev/null
# Timeout cannot consume an unsent issue or mark it delivered.
jq '.issues.issue.active=true' "$STATE_FILE" >"$TMP_DIR/next";mv "$TMP_DIR/next" "$STATE_FILE"
queue_group_notification issue new-signature Sonarr Title IMPORT_MISSING ERROR 0 'New error' new
MONITOR_NOTIFY_TIMEOUT_SECONDS=1
printf '#!/bin/bash\nsleep 5\n' >"$NOTIFY"
start=$(date +%s)
if send_grouped_notification;then exit 1;fi
(( $(date +%s)-start<5 ))
jq -e '(.monitor.notification.outbox|length)==1 and .issues.issue.notifiedSignature=="resolved-signature"' "$TMP_DIR/disk.json" >/dev/null
# An undelivered initial alert that has since resolved is removed, not emailed.
jq '.issues.issue.active=false' "$STATE_FILE" >"$TMP_DIR/next";mv "$TMP_DIR/next" "$STATE_FILE"
monitor_outbox_load
[[ ! -s "$NOTIFICATION_BATCH" ]]
printf 'Durable inactive-resolution replay, export lease release/reacquire, accepted ack, timeout retention and obsolete-alert coalescing passed\n'
OUTBOX
bash <<'GATES'
set -euo pipefail
source <(awk '/^# LOCK$/{exit}{print}' "$repo/user_script/arr_health_activity.sh")
trap - EXIT INT TERM HUP
TMP_DIR="$fixture/gates";mkdir "$TMP_DIR";ARR_MUTATION_LOCK_DIR="$TMP_DIR"
MONITOR_COORDINATION_ACTIVE=true
exec {held}>"$TMP_DIR/arr-mutations-Sonarr.lock";flock -x "$held"
if monitor_mutation_gate Sonarr;then exit 1;fi
monitor_mutation_gate Radarr
[[ -n "$MONITOR_RADARR_MUTATION_FD" && -z "$MONITOR_SONARR_MUTATION_FD" ]]
monitor_release_mutation_gates
exec {held}>&-
monitor_mutation_gate Sonarr
monitor_release_mutation_gates
# Deadline gate bounds new requests, records deferral and never calls curl.
MONITOR_RUN_ACTIVE=true;START_TIME=$(( $(date +%s)-1000 ));HTTP_REQUEST_TIMEOUT_SECONDS=30
curl(){ touch "$fixture/unexpected-curl";exit 1; }
if http_json_get "$TMP_DIR/response" "$SONARR_URL/api/v3/health";then exit 1;fi
[[ ! -e "$fixture/unexpected-curl" && "$HTTP_LAST_ERROR" == 'runtime budget deferred'* ]]
monitor_service_deferred Sonarr
[[ "$(append_api_failure '' health "$HTTP_LAST_ERROR")" == '' ]]
printf 'Per-app mutation exclusion, independent other-app progress and HTTP deadline/deferral semantics passed\n'
GATES
bash <<'SCHEMA'
set -euo pipefail
source <(awk '/^# LOCK$/{exit}{print}' "$repo/user_script/arr_health_activity.sh")
trap - EXIT INT TERM HUP
file="$fixture/receipts.json"
printf '{"version":1,"receipts":{"Radarr:download":{"app":"Radarr","downloadId":"download","targets":{"movie:1:2":{"kind":"movie","targetId":1,"parentId":1,"fileId":2,"pathAtImport":"/media/movie.mkv"}}}}}' >"$file"
arr_import_receipt_document_valid "$file"
jq '.receipts["Radarr:download"].targets["movie:1:2"].fileId="2"' "$file" >"$fixture/bad.json"
if arr_import_receipt_document_valid "$fixture/bad.json";then exit 1;fi
jq '.version=2' "$file" >"$fixture/bad.json"
if arr_import_receipt_document_valid "$fixture/bad.json";then exit 1;fi
# Rediscover only a unique exact native command within the original POST window.
TMP_DIR="$fixture/match";mkdir "$TMP_DIR"
printf '{"startedAt":100,"command":{"name":"MoviesSearch","movieIds":[7]}}' >"$TMP_DIR/action"
api_get(){ printf '[{"id":9,"name":"MoviesSearch","body":{"name":"MoviesSearch","movieIds":[7]},"queued":"1970-01-01T00:01:41Z","status":"completed"}]' >"$3"; }
automation_find_existing_command "$TMP_DIR/action" root key "$TMP_DIR/matched"
jq -e '.id==9' "$TMP_DIR/matched" >/dev/null
api_get(){ printf '[{"id":9,"name":"MoviesSearch","body":{"name":"MoviesSearch","movieIds":[7]},"queued":"1970-01-01T00:01:41Z"},{"id":10,"name":"MoviesSearch","body":{"name":"MoviesSearch","movieIds":[7]},"queued":"1970-01-01T00:01:42Z"}]' >"$3"; }
if automation_find_existing_command "$TMP_DIR/action" root key "$TMP_DIR/matched";then exit 1;fi
printf 'Typed receipt/version rejection and unique exact command rediscovery with ambiguous-match veto passed\n'
SCHEMA
bash <<'INACTIVE'
set -euo pipefail
source <(awk '/^# LOCK$/{exit}{print}' "$repo/user_script/arr_health_activity.sh")
trap - EXIT INT TERM HUP
log(){ :; };debug_log(){ :; }
TMP_DIR="$fixture/inactive";mkdir "$TMP_DIR";STATE_FILE="$TMP_DIR/state";DOWNLOAD_LEDGER_RECONCILIATION_RESULTS_FILE="$TMP_DIR/results"
printf '{"issues":{"FLOW:DOWNLOAD:old":{"classification":"DOWNLOAD_FLOW_REVIEW_REQUIRED"}}}' >"$STATE_FILE"
SAB_HISTORY_OK=true;SAB_QUEUE_OK=true;SAB_HISTORY="$TMP_DIR/history";SAB_QUEUE="$TMP_DIR/queue"
printf '{"history":{"slots":[]}}' >"$SAB_HISTORY";printf '{"queue":{"slots":[]}}' >"$SAB_QUEUE"
download_ledger_can_evaluate(){ return 0; };download_ledger_arr_queue_contains(){ return 1; }
arr_reconciliation_connection(){ printf 'root\tkey\n'; }
runtime_budget_allows_optional_phase(){ return 0; }
api_get(){ printf '{"id":7,"monitored":false}' >"$3";API_LAST_HTTP_CODE=200; }
record='{"targets":{"movie:7":{"type":"movie","movieId":7}}}'
record_inactive_target_reconciliation old Radarr "$record"
jq -e '.scanOk==true and .evidenceFound==true and .kind=="inactive_target" and (.detail|contains("Import/download cancellation was not inferred"))' "$DOWNLOAD_LEDGER_RECONCILIATION_RESULTS_FILE" >/dev/null
# A live SAB record or an actively monitored target prevents this closure.
printf '{"history":{"slots":[{"nzo_id":"old"}]}}' >"$SAB_HISTORY"
if record_inactive_target_reconciliation old Radarr "$record";then exit 1;fi
printf '{"history":{"slots":[]}}' >"$SAB_HISTORY"
api_get(){ printf '{"id":7,"monitored":true}' >"$3";API_LAST_HTTP_CODE=200; }
if record_inactive_target_reconciliation old Radarr "$record";then exit 1;fi
# Sonarr episode 404 alone never proves full parent removal.
record='{"targets":{"episode:7":{"type":"episode","episodeId":7,"seriesId":8,"seasonNumber":1,"episodeNumber":2}}}'
api_get(){ if [[ "$1" == root/episode/7 ]];then API_LAST_HTTP_CODE=404;return 1;fi;printf '{"id":8}' >"$3";API_LAST_HTTP_CODE=200; }
if record_inactive_target_reconciliation old Sonarr "$record";then exit 1;fi
api_get(){ API_LAST_HTTP_CODE=404;return 1; }
: >"$DOWNLOAD_LEDGER_RECONCILIATION_RESULTS_FILE"
record_inactive_target_reconciliation old Sonarr "$record"
jq -e '.evidenceFound==true' "$DOWNLOAD_LEDGER_RECONCILIATION_RESULTS_FILE" >/dev/null
printf 'Exact inactive-target closure, active-job/monitoring veto and Sonarr parent-deletion proof passed\n'
INACTIVE
bash <<'COVERAGE'
set -euo pipefail
source <(awk '/^# LOCK$/{exit}{print}' "$repo/user_script/arr_health_activity.sh")
trap - EXIT INT TERM HUP
TMP_DIR="$fixture/coverage";mkdir "$TMP_DIR";STATE_FILE="$TMP_DIR/state"
printf '{"issues":{},"monitor":{}}' >"$STATE_FILE"
save_state(){ mv "$1" "$STATE_FILE"; }
SONARR_ENABLED=true;RADARR_ENABLED=false;SAB_ENABLED=false;ACTIVITY_AUDIT_ENABLED=false
SONARR_QUEUE_OK=true;SONARR_HEALTH_OK=true;SONARR_STATUS_OK=true;SONARR_AUDIT_OK=false
monitor_persist_coverage
jq -e '.monitor.operationalSummary.collectionComplete==true and .monitor.collectionCoverage["Sonarr.history"].enabled==false' "$STATE_FILE" >/dev/null
last=$(jq -r '.monitor.collectionCoverage["Sonarr.queue"].lastSuccessfulAt' "$STATE_FILE")
SONARR_QUEUE_OK=false
monitor_persist_coverage
jq -e --argjson last "$last" '.monitor.operationalSummary.collectionComplete==false and .monitor.collectionCoverage["Sonarr.queue"].lastSuccessfulAt==$last' "$STATE_FILE" >/dev/null
printf 'Enabled collector coverage, stale-success preservation and partial status passed\n'
COVERAGE
bash <<'AUTOMATION'
set -euo pipefail
source <(awk '/^# LOCK$/{exit}{print}' "$repo/user_script/arr_health_activity.sh")
trap - EXIT INT TERM HUP
log(){ :; };debug_log(){ :; }
TMP_DIR="$fixture/actions";mkdir "$TMP_DIR";AUTOMATION_STATE_FILE="$TMP_DIR/actions.json";START_TIME=10000
runtime_budget_allows_optional_phase(){ return 0; }
printf '{"version":1,"actions":{},"observations":{},"profiles":{},"events":{},"missing":{}}' >"$AUTOMATION_STATE_FILE"
printf '{"key":"request","app":"Radarr","kind":"missing-search","mediaKind":"movie","targetId":7,"parentId":7,"command":{"name":"MoviesSearch","movieIds":[7]}}' >"$TMP_DIR/candidate"
automation_window_open(){ return 0; };automation_action_budget(){ return 0; };automation_no_active_command(){ return 0; };automation_last_moment_guard(){ return 0; }
policy_mutate(){ return 75; }
automation_submit_command "$TMP_DIR/candidate" root key
jq -e '(.actions|length)==0 and any(.deferred[];.outcome=="not_dispatched")' "$AUTOMATION_STATE_FILE" >/dev/null
# Reconcile an actual uncertain POST without repeating it; exceptions may be strings.
jq --slurpfile c "$TMP_DIR/candidate" '.actions.request=$c[0]+{status:"intent",outcome:"pending",startedAt:100}' "$AUTOMATION_STATE_FILE" >"$TMP_DIR/next";mv "$TMP_DIR/next" "$AUTOMATION_STATE_FILE"
arr_reconciliation_connection(){ printf 'root\tkey\n'; }
api_get(){ case "$1" in
 root/command) printf '[{"id":9,"name":"MoviesSearch","body":{"name":"MoviesSearch","movieIds":[7]},"queued":"1970-01-01T00:01:41Z","status":"failed","exception":"native failure detail"}]' >"$3";;
 root/command/9) printf '{"id":9,"name":"MoviesSearch","body":{"name":"MoviesSearch","movieIds":[7]},"status":"failed","exception":"native failure detail"}' >"$3";;
 *) return 1;;esac; }
automation_reconcile_commands
jq -e '.actions.request.status=="failed" and .actions.request.commandId==9 and .actions.request.nativeMessage=="native failure detail"' "$AUTOMATION_STATE_FILE" >/dev/null
printf 'Known non-dispatch clears only its unapplied intent; uncertain POST adopts exact native command and reports string exception without replay\n'
AUTOMATION
bash <<'REPLACEMENT'
set -euo pipefail
source <(awk '/^# LOCK$/{exit}{print}' "$repo/user_script/arr_health_activity.sh")
trap - EXIT INT TERM HUP
log(){ :; };debug_log(){ :; }
TMP_DIR="$fixture/replacement";mkdir "$TMP_DIR";POLICY_STATE_FILE="$TMP_DIR/policy.json";START_TIME=10000
printf '{"version":1,"observations":{},"actions":{"download":{"downloadId":"download","app":"Radarr","mode":"replace","status":"queue_verified","queueVerified":true,"targetId":7,"parentId":7,"queueId":9,"startedAt":100,"kind":"movie","queue":{"id":9,"downloadId":"download"},"sab":{"nzo_id":"download"},"command":{"name":"MoviesSearch","movieIds":[7]},"profile":{},"parent":{},"target":{}}}}' >"$POLICY_STATE_FILE"
arr_reconciliation_connection(){ printf 'root\tkey\n'; };date_to_epoch(){ printf 200; }
api_get(){ case "$1" in
 root/movie/7) printf '{"id":7,"hasFile":true,"monitored":true,"movieFileId":8,"qualityProfileId":1}' >"$3";;
 root/moviefile/8) printf '{"id":8,"movieId":7,"size":10,"path":"/media/movie.mkv","dateAdded":"native-date","customFormatScore":0,"quality":{"quality":{"id":1}}}' >"$3";;
 root/qualityprofile/1) printf '{"minFormatScore":0,"items":[{"allowed":true,"quality":{"id":1},"items":[]}]}' >"$3";;
 *) return 1;;esac; }
policy_mutate(){ touch "$fixture/unexpected-replacement-search";return 1; }
action=$(jq -c '.actions.download' "$POLICY_STATE_FILE")
policy_finish_tracking "$action" || true
jq -e '.actions.download.replacementProofRuns==1 and .actions.download.status=="queue_verified"' "$POLICY_STATE_FILE" >/dev/null
# A failed intermediate collection must break the confirmation pair.
START_TIME=10300;action=$(jq -c '.actions.download' "$POLICY_STATE_FILE")
eval "$(declare -f api_get | sed '1s/api_get/api_get_ok/')"
api_get(){ return 1; }
policy_finish_tracking "$action" || true
jq -e '.actions.download.replacementProofRuns==0' "$POLICY_STATE_FILE" >/dev/null
api_get(){ api_get_ok "$@"; }
START_TIME=14000;action=$(jq -c '.actions.download' "$POLICY_STATE_FILE")
policy_finish_tracking "$action" || true
jq -e '.actions.download.replacementProofRuns==1 and .actions.download.status=="queue_verified"' "$POLICY_STATE_FILE" >/dev/null
START_TIME=14300;action=$(jq -c '.actions.download' "$POLICY_STATE_FILE")
policy_finish_tracking "$action"
jq -e '.actions.download.status=="done" and .actions.download.replacementState=="import_verified" and .actions.download.resolutionSource=="verified-current-file"' "$POLICY_STATE_FILE" >/dev/null
[[ ! -e "$fixture/unexpected-replacement-search" ]]
printf 'Two fresh policy-compliant native file scans close an obsolete replacement search without another request\n'
REPLACEMENT
bash <<'SHARED'
set -euo pipefail
source "$repo/user_script/media_cleanup.sh"
ARR_MUTATION_LOCK_DIR="$fixture/shared";mkdir "$ARR_MUTATION_LOCK_DIR"
MC_GUARDS_ACTIVE=true;MC_DRY_RUN=false
mc_defer_work(){ printf '%s\n' "$*" >"$fixture/cleanup-deferred"; }
exec {held}>"$ARR_MUTATION_LOCK_DIR/arr-mutations-Sonarr.lock";flock -x "$held"
if mc_app_mutation_gate Sonarr;then exit 1;fi
[[ -s "$fixture/cleanup-deferred" ]]
exec {held}>&-
mc_app_mutation_gate Sonarr
# The integrity executor must use that same lease, not a parallel lock namespace.
source "$repo/user_script/media_integrity_audit.sh"
ARR_MUTATION_COORDINATION_ACTIVE=true;RECOVERY_FILE="$fixture/shared-recovery.json"
printf '{"actions":{"job":{"app":"Sonarr"}}}' >"$RECOVERY_FILE"
recovery_resume_core(){ touch "$fixture/shared-executed"; }
recovery_resume job
[[ ! -e "$fixture/shared-executed" ]]
exec {ARR_MUTATION_FD}>&-
recovery_resume job
[[ -e "$fixture/shared-executed" ]]
printf 'Cleanup and integrity recovery share the same per-application mutation lease\n'
SHARED
