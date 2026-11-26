"""Exact-policy fast eligibility and monitor handoff; isolated files/API stubs only."""
from pathlib import Path
import subprocess,tempfile,shutil
R=Path(__file__).resolve().parents[1];BASH=shutil.which('bash')
s=(R/'user_script/media_cleanup.sh').read_text();a=s.index('mc_sab() (\n')+len('mc_sab() (\n');b=s.index('\nmain "$@"\n',a)
with tempfile.TemporaryDirectory(prefix='policy-handoff.') as d:
 t=Path(d).resolve();lib=t/'sab.sh';lib.write_text(s[:s.index('\n# MODULE: ARR')]+'\n'+s[a:b])
 code=r'''
 source "$3"
 trap - EXIT INT TERM HUP
 TMP_DIR="$2";LOG_DIR="$2";POLICY_DISPOSITION_FILE="$2/policy.json";DRY_RUN=false;RUN_ID=fixture
 MIN_COMPLETED_AGE_HOURS=336;MIN_POLICY_REJECTION_AGE_HOURS=6
 SONARR_ENABLED=true;SAB_HISTORY_FILE="$2/sab-history.json";source_path="$2/payload";mkdir "$source_path";printf media >"$source_path/video.mkv"
 item=$(jq -nc --argjson now "$(date +%s)" '{nzo_id:"exact",name:"Show.S01E01",storage:"/native/Show",completed:($now-7*3600),status:"Completed",category:"tv"}')
 jq -n --argjson sab "$item" '{version:1,observations:{},actions:{exact:{queueId:5,startedAt:100,queue:{id:5,downloadId:"exact"},command:{name:"EpisodeSearch",episodeIds:[11]},profile:{},parent:{},downloadId:"exact",app:"Sonarr",status:"done",queueVerified:true,mode:"redundant",kind:"episode",targetId:11,parentId:1,fileId:21,filePath:"/library/show.mkv",target:{seasonNumber:1,episodeNumber:1},sab:($sab|{nzo_id,name,storage,completed,category})}}}' >"$POLICY_DISPOSITION_FILE"
 printf '[]' >"$2/profiles";printf '[]' >"$2/formats"
 signature=$(jq -nSc '{profiles:[],formats:[]}'|sha256sum|cut -d ' ' -f1)
 jq --arg signature "$signature" '.actions.exact.profileSignature=$signature' "$POLICY_DISPOSITION_FILE" >"$2/next";mv "$2/next" "$POLICY_DISPOSITION_FILE"
 log(){ :; };owner_for_category(){ printf Sonarr; };root_for_owner(){ printf '%s' "$TMP_DIR"; }
 resolve_sab_path(){ printf '%s' "$TMP_DIR/payload"; };path_is_stable(){ return 0; };download_is_active_anywhere(){ [[ "${active:-false}" == true ]]; }
 verify_download_cleanup_proof(){ printf '{"verifiedImportedPaths":1,"remainingSourceMediaFiles":1}' >"$4";return "${proof_status_fixture:-0}"; }
 proof_paths_still_valid(){ return 0; };refresh_active_state(){ return 0; };path_is_below(){ return 0; }
 quarantine_payload(){ printf moved >>"$TMP_DIR/calls";LAST_QUARANTINE_DESTINATION="$TMP_DIR/quarantine/payload"; }
 arr_get(){ case "$1" in */qualityprofile) cp "$TMP_DIR/profiles" "$3";;*/customformat) cp "$TMP_DIR/formats" "$3";;*) return 1;;esac; }
 SONARR_URL=http://fixture;SONARR_API_KEY=fixture
 run_case(){ printf '[%s]' "$item" >"$SAB_HISTORY_FILE";rm -f "$TMP_DIR/calls";if process_completed_jobs;then :;else return 1;fi; }
 run_case;[[ -s "$TMP_DIR/calls" ]]
 active=true;run_case;[[ ! -f "$TMP_DIR/calls" ]];active=false
 jq -e '.actions.exact.status=="blocked" and (.actions.exact.reason|contains("active queue"))' "$LOG_DIR/policy-cleanup.json" >/dev/null
 proof_status_fixture=13;run_case;[[ ! -f "$TMP_DIR/calls" ]];proof_status_fixture=0
 printf '[{"id":99}]' >"$TMP_DIR/formats";run_case;[[ ! -f "$TMP_DIR/calls" ]];printf '[]' >"$TMP_DIR/formats"
 # Even a valid rejection cannot use the fast path until six hours.
 item=$(jq --argjson now "$(date +%s)" '.completed=($now-5*3600)' <<<"$item")
 jq --argjson sab "$item" '.actions.exact.sab=($sab|{nzo_id,name,storage,completed,category})' "$POLICY_DISPOSITION_FILE" >"$TMP_DIR/next";mv "$TMP_DIR/next" "$POLICY_DISPOSITION_FILE"
 run_case;[[ ! -f "$TMP_DIR/calls" ]]
 # Restore intent remains a manual hold even beyond the ordinary age gate.
 item=$(jq --argjson now "$(date +%s)" '.completed=($now-400*3600)' <<<"$item")
 jq --argjson sab "$item" '.actions.exact.sab=($sab|{nzo_id,name,storage,completed,category})' "$POLICY_DISPOSITION_FILE" >"$TMP_DIR/next";mv "$TMP_DIR/next" "$POLICY_DISPOSITION_FILE"
 jq -n --argjson sab "$item" '{schema:1,records:{one:{app:"Sonarr",downloadId:"exact",policyStartedAt:100,action:"restore_requested",sab:($sab|{nzo_id,name,storage,completed,category})}}}' >"$LOG_DIR/source-removals.json"
 run_case;[[ ! -f "$TMP_DIR/calls" ]]
 printf 'Six-hour fast gate, current policy, active queue, source-proof and manual-restore protection passed\n'
 '''
 subprocess.run([BASH,'-eu','-c',code,'fixture',str(R),str(t),str(lib)],check=True)
 code=r'''
 source <(awk '/^# LOCK$/{exit}{print}' "$1/user_script/media_health_monitor.sh")
 trap - INT TERM HUP
 TMP_DIR="$2";STATE_DIR="$2";POLICY_STATE_FILE="$2/policy.json";START_TIME=$(date +%s)
 MEDIA_POLICY_CLEANUP_RECEIPT="$2/policy-cleanup.json";MEDIA_CLEANUP_SOURCE_RECEIPTS="$2/source-removals.json"
 # Old/unmatched receipts cannot mark a current action resolved.
 policy_reconcile_cleanup
 jq -e '.actions.exact.workflow=="manual_hold" and .actions.exact.cleanup.status=="manual_restore"' "$POLICY_STATE_FILE" >/dev/null
 jq '.actions.exact as $p|{schema:1,records:{one:{app:$p.app,downloadId:$p.downloadId,policyStartedAt:$p.startedAt,targetId:$p.targetId,sab:$p.sab,at:200,action:"quarantined",sourceAbsent:true,proofKind:"policy-disposition",originalPath:"/source",destination:"/quarantine"}}}' "$POLICY_STATE_FILE" >"$MEDIA_CLEANUP_SOURCE_RECEIPTS"
 policy_reconcile_cleanup
 jq -e '.actions.exact.workflow=="resolved" and .actions.exact.cleanup.status=="quarantined"' "$POLICY_STATE_FILE" >/dev/null
 jq '.actions.exact.mode="replace"|.actions.exact.replacementState="waiting"' "$POLICY_STATE_FILE" >"$2/next";mv "$2/next" "$POLICY_STATE_FILE"
 policy_reconcile_cleanup;jq -e '.actions.exact.workflow=="replacement_import_pending"' "$POLICY_STATE_FILE" >/dev/null
 jq '.actions.exact.replacementState="import_verified"' "$POLICY_STATE_FILE" >"$2/next";mv "$2/next" "$POLICY_STATE_FILE"
 policy_reconcile_cleanup;jq -e '.actions.exact.workflow=="resolved"' "$POLICY_STATE_FILE" >/dev/null
 before=$(sha256sum "$POLICY_STATE_FILE"|cut -d ' ' -f1);policy_reconcile_cleanup;[[ "$before" == $(sha256sum "$POLICY_STATE_FILE"|cut -d ' ' -f1) ]]
 jq '.actions.exact.startedAt=101|del(.actions.exact.cleanup)' "$POLICY_STATE_FILE" >"$2/next";mv "$2/next" "$POLICY_STATE_FILE"
 policy_reconcile_cleanup;jq -e '.actions.exact.workflow!="resolved" and .actions.exact.cleanup.status=="pending"' "$POLICY_STATE_FILE" >/dev/null

 # Outcome events remain progress until both disposal and import are proven.
 STATE_FILE="$2/monitor.json";printf '{"monitor":{"policyNotifications":{}}}' >"$STATE_FILE"
 queue_group_notification(){ jq -nc --arg key "$1" --arg signature "$2" --arg detail "$8" --arg event "$9" '{key:$key,signature:$signature,detail:$detail,event:$event}' >>"$TMP_DIR/queued.jsonl"; }
 record_normalized_issue(){ :; }
 jq '.actions.exact.startedAt=100|.actions.exact.replacementState="waiting"' "$POLICY_STATE_FILE" >"$2/next";mv "$2/next" "$POLICY_STATE_FILE"
 policy_report_actions
 jq -e '.event=="progress" and (.detail|contains("/source -> /quarantine"))' "$TMP_DIR/queued.jsonl" >/dev/null
 jq '.actions.exact.replacementState="import_verified"' "$POLICY_STATE_FILE" >"$2/next";mv "$2/next" "$POLICY_STATE_FILE"
 policy_report_actions
 tail -n 1 "$TMP_DIR/queued.jsonl"|jq -e '.event=="completed" and (.detail|contains("Workflow: resolved"))' >/dev/null
 signature=$(tail -n 1 "$TMP_DIR/queued.jsonl"|jq -r .signature)
 jq --arg signature "$signature" '.monitor.policyNotifications.exact=$signature' "$STATE_FILE" >"$2/next";mv "$2/next" "$STATE_FILE"
 policy_report_actions
 [[ $(wc -l <"$TMP_DIR/queued.jsonl") == 2 ]]
 notification_record_text '{"event":"progress","source":"Sonarr","title":"Show","classification":"ARR_POLICY_AUTOMATION","severity":"INFO","detail":"Waiting for import"}' >"$2/rendered"
 grep -q '\[PROGRESS\]' "$2/rendered"
 printf 'Exact handoff, pending/imported outcomes, progress/completed mail and duplicate suppression passed\n' 
 '''
 subprocess.run([BASH,'-eu','-c',code,'fixture',str(R),str(t)],check=True)
with tempfile.TemporaryDirectory(prefix='retry-exhaustion.') as d:
 t=Path(d).resolve()
 code=r'''
 source <(awk '/^# LOCK$/{exit}{print}' "$1/user_script/media_health_monitor.sh")
 trap - INT TERM HUP
 TMP_DIR="$2";STATE_DIR="$2";AUTOMATION_STATE_FILE="$2/actions.json";SONARR_QUEUE="$2/sonarr.json";RADARR_QUEUE="$2/radarr.json";START_TIME=100000
 runtime_budget_allows_optional_phase(){ return 0; }
 automation_state_update(){ local filter="$1";shift;jq "$@" "$filter" "$AUTOMATION_STATE_FILE" >"$TMP_DIR/next";mv "$TMP_DIR/next" "$AUTOMATION_STATE_FILE"; }
 record_normalized_issue(){ printf '%s\n' "$*" >>"$TMP_DIR/issues"; }
 jq -n '{actions:([range(1;4)|{key:(tostring),value:{app:"Sonarr",kind:"import-retry",downloadId:"exact",status:"failed",startedAt:(1000*.),reason:["busy"]}}]|from_entries)}' >"$AUTOMATION_STATE_FILE"
 printf '{"records":[{"id":1,"downloadId":"exact","statusMessages":[{"messages":["Access denied"]}]}]}' >"$SONARR_QUEUE"
 printf '{"records":[]}' >"$RADARR_QUEUE"
 automation_retry_exhaustion
 jq -e '.retryExhaustions["Sonarr:exact"].cause=="underlying_service_or_storage" and (.actions|length)==3' "$AUTOMATION_STATE_FILE" >/dev/null
 grep -q 'ARR_IMPORT_RETRY_EXHAUSTED' "$TMP_DIR/issues"
 jq '.records[0].statusMessages[0].messages=["Not a Custom Format upgrade for existing file"]' "$SONARR_QUEUE" >"$TMP_DIR/next";mv "$TMP_DIR/next" "$SONARR_QUEUE"
 automation_retry_exhaustion
 jq -e '.retryExhaustions["Sonarr:exact"].cause=="policy_reassessment"' "$AUTOMATION_STATE_FILE" >/dev/null
 jq '.actions["3"].outcome="import_verified"' "$AUTOMATION_STATE_FILE" >"$TMP_DIR/next";mv "$TMP_DIR/next" "$AUTOMATION_STATE_FILE"
 automation_retry_exhaustion
 jq -e '.retryExhaustions["Sonarr:exact"].status=="resolved"' "$AUTOMATION_STATE_FILE" >/dev/null
 # An uncertain command or a still-running final command gets no exhaustion action.
 jq 'del(.retryExhaustions)|del(.actions["3"].outcome)|.actions["3"].status="intent"' "$AUTOMATION_STATE_FILE" >"$TMP_DIR/next";mv "$TMP_DIR/next" "$AUTOMATION_STATE_FILE"
 automation_retry_exhaustion
 jq -e '.retryExhaustions==null' "$AUTOMATION_STATE_FILE" >/dev/null
 printf 'Retry exhaustion reclassifies without mutation; exact import resolves it; uncertainty stays protected\n'
 '''
 subprocess.run([BASH,'-eu','-c',code,'fixture',str(R),str(t)],check=True)
