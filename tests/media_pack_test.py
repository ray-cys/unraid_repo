"""Native pack fixtures: exact identities, complete accounting, journaling and disposal guards."""
import importlib.util,json,os,shutil,subprocess,tempfile,time
from pathlib import Path
R=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('pack_inventory',R/'tools/media_pack_inventory.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
with tempfile.TemporaryDirectory(prefix='media-pack.') as d:
 t=Path(d).resolve();payload=t/'complete'/'Show.S01';payload.mkdir(parents=True)
 for name in ['Show.S01E01.mkv','Show.S01E02.mkv','poster.jpg']:(payload/name).write_bytes(b'fixture')
 inv=m.inventory(str(payload),str(payload.parent));assert len(inv['files'])==3
 (t/'inventory.json').write_text(json.dumps(inv));assert inv==m.inventory(str(payload),str(payload.parent))
 (payload/'link').symlink_to(payload/'poster.jpg')
 try:m.inventory(str(payload),str(payload.parent));raise AssertionError('symlink accepted')
 except ValueError:pass
 (payload/'link').unlink()
 os.link(payload/'poster.jpg',payload/'hardlink.jpg')
 try:m.inventory(str(payload),str(payload.parent));raise AssertionError('hardlink accepted')
 except ValueError:pass
 (payload/'hardlink.jpg').unlink()
 # Update the baseline after restoring link metadata.
 dump_inventory=m.inventory(str(payload),str(payload.parent));(t/'inventory.json').write_text(json.dumps(dump_inventory))
 try:m.inventory(str(payload),str(t/'elsewhere'));raise AssertionError('outside root accepted')
 except ValueError:pass
 now=2000000000
 def dump(name,obj):(t/name).write_text(json.dumps(obj))
 profiles=[{'id':1,'minFormatScore':100,'items':[{'allowed':True,'quality':{'id':4}}],'formatItems':[]}]
 dump('profiles',profiles);dump('formats',[])
 series={'id':1,'tvdbId':123,'qualityProfileId':1,'monitored':True,'tags':[],'seasons':[{'seasonNumber':1,'monitored':True}]};dump('series',series)
 for e in [11,12]:dump(f'ep{e}',{'id':e,'seriesId':1,'seasonNumber':1,'episodeNumber':e-10,'monitored':True,'hasFile':False,'episodeFileId':0})
 for e in [11,12]:dump(f'file{e+10}',{'id':e+10,'seriesId':1,'size':50,'path':f'/library/Show/{e}.mkv','dateAdded':'2033-05-16T00:00:00Z','quality':{'quality':{'id':4}},'customFormatScore':200})
 queue={'totalRecords':2,'records':[{'id':e,'episodeId':e,'seriesId':1,'downloadId':'exact','protocol':'usenet','status':'completed','outputPath':str(payload),'added':'2033-05-17T00:00:00Z','title':'Show.S01'} for e in [11,12]]}
 dump('queue',queue);dump('radarr',{'records':[]})
 dump('sab-history',{'history':{'slots':[{'nzo_id':'exact','name':'Show.S01','status':'Completed','completed':now-25000,'storage':str(payload),'category':'tv'}]}})
 dump('sab-queue',{'queue':{'slots':[]}})
 history={'totalRecords':2,'records':[{'downloadId':'exact','eventType':'grabbed','seriesId':1,'episodeId':e,'sourceTitle':'Show.S01','quality':{'quality':{'id':4}}} for e in [11,12]]};dump('history',history)
 preview=[{'series':{'id':1},'episodes':[{'id':e,'seriesId':1,'seasonNumber':1,'episodeNumber':e-10}], 'downloadId':'exact','size':7,'path':str(payload/f'Show.S01E0{e-10}.mkv'),'relativePath':f'Show.S01E0{e-10}.mkv','quality':{'quality':{'id':4}},'customFormatScore':0,'rejections':[{'reason':'Custom Formats score 0 is below profile minimum 100'}]} for e in [11,12]];dump('preview',preview)
 code=r'''
set -euo pipefail
source "$1/tools/media_pack_contract.sh"
source "$1/tools/media_pack_monitor.sh"
source "$1/tools/media_pack_cleanup.sh"
TMP_DIR="$2";STATE_DIR="$2";LOG_DIR="$2";START_TIME=2000000000;SONARR_API_ROOT=http://sonarr/api/v3;SONARR_API_KEY=fixture
AUTOMATION_STATE_FILE="$2/automation.json";STATE_FILE="$2/state.json";PACK_STATE_FILE="$2/pack-actions.json"
SONARR_QUEUE="$2/queue";RADARR_QUEUE="$2/radarr";SAB_HISTORY="$2/sab-history";SAB_QUEUE="$2/sab-queue";AUTOMATION_SONARR_COMPLETE_ROOT="$2/complete"
MEDIA_INTEGRITY_RECOVERY_FILE="$2/recovery.json";printf '{"schema":1,"workflow":"arr-native","actions":{}}' >"$MEDIA_INTEGRITY_RECOVERY_FILE"
printf '{"downloadLedger":{},"monitor":{"packNotifications":{}}}' >"$STATE_FILE"
sig=$(pack_profile_signature "$2/profiles" "$2/formats")
jq -n --arg sig "$sig" '{version:1,actions:{},profiles:{Sonarr:{signature:$sig,holdUntil:0,checkedAt:2000000000}}}' >"$AUTOMATION_STATE_FILE"
fetch_arr_queue(){ cp "$TMP_DIR/queue" "$4"; }
fetch_arr_history_by_download_id(){ cp "$TMP_DIR/history" "$3"; }
automation_target_history(){ printf '{"totalRecords":0,"records":[]}' >"$5"; }
runtime_budget_allows_optional_phase(){ return 0; }
api_get(){
 case "$1" in
 */series/1) cp "$TMP_DIR/series" "$3";;
 */qualityprofile) cp "$TMP_DIR/profiles" "$3";;
 */customformat) cp "$TMP_DIR/formats" "$3";;
 */episode/11) cp "$TMP_DIR/ep11" "$3";;
 */episode/12) cp "$TMP_DIR/ep12" "$3";;
 */episodefile/21) cp "$TMP_DIR/file21" "$3";;
 */episodefile/22) cp "$TMP_DIR/file22" "$3";;
 */manualimport\?*) cp "$TMP_DIR/preview" "$3";;
 *) return 1;;esac
}
pack_source_inventory(){ cp "$TMP_DIR/inventory.json" "$3"; }
pack_snapshot exact "$2/plan"
pack_plan_valid "$2/plan"
jq -e '.accounted==true and .unknown==false and all(.files[];.disposition=="rejected")' "$2/plan" >/dev/null
# Existing acceptable native episode files prove redundancy; stale/low-score files do not.
cp "$2/ep11" "$2/ep11.saved";cp "$2/ep12" "$2/ep12.saved";cp "$2/preview" "$2/preview.saved"
for e in 11 12;do jq '.hasFile=true|.episodeFileId=(.id+10)' "$2/ep$e.saved" >"$2/ep$e";done
jq 'map(.rejections=[{reason:"Not an upgrade for existing episode file(s)"}])' "$2/preview.saved" >"$2/preview"
pack_snapshot exact "$2/redundant"
jq -e '.accounted and (.unknown|not) and all(.files[];.disposition=="redundant")' "$2/redundant" >/dev/null
cp "$2/file21" "$2/file21.saved";jq '.customFormatScore=0' "$2/file21.saved" >"$2/file21"
pack_snapshot exact "$2/stale-existing";jq -e '.unknown and (.accounted|not)' "$2/stale-existing" >/dev/null
cp "$2/file21.saved" "$2/file21";cp "$2/ep11.saved" "$2/ep11";cp "$2/ep12.saved" "$2/ep12";cp "$2/preview.saved" "$2/preview"
# A partial pack with a required video may be Auto-scanned, never rejected.
cp "$2/preview" "$2/preview.saved"
jq '.[0].rejections=[]|.[0].customFormatScore=200' "$2/preview.saved" >"$2/preview"
pack_snapshot exact "$2/partial"
jq -e '.accounted==false and .unknown==false and .files[0].disposition=="required"' "$2/partial" >/dev/null
# Unknown/mixed reasons protect the entire job.
jq '.[0].rejections=[{reason:"Permission denied"}]' "$2/preview.saved" >"$2/preview"
pack_snapshot exact "$2/mixed"
jq -e '.accounted==false and .unknown==true' "$2/mixed" >/dev/null
# A native ID mismatch, omitted video or deleted target cannot qualify.
jq '.[0].episodes[0].id=999' "$2/preview.saved" >"$2/preview"
if pack_snapshot exact "$2/bad-id";then exit 1;fi
jq '.[1:]' "$2/preview.saved" >"$2/preview"
if pack_snapshot exact "$2/omitted";then exit 1;fi
cp "$2/preview.saved" "$2/preview"
automation_target_history(){ printf '{"totalRecords":1,"records":[{"eventType":"episodeFileDeleted"}]}' >"$5"; }
if pack_snapshot exact "$2/deleted";then exit 1;fi
automation_target_history(){ printf '{"totalRecords":0,"records":[]}' >"$5"; }
# Required source file is accounted only by native Auto processing.
cp "$2/partial" "$2/plan-partial"
AUTOMATION_IMPORT_RETRY_MAX_ATTEMPTS=3
automation_submit_command(){ cp "$1" "$TMP_DIR/command-candidate"; }
pack_submit_import exact "$2/partial"
jq -e '.command.name=="DownloadedEpisodesScan" and .command.importMode=="Auto" and .packId=="exact"' "$2/command-candidate" >/dev/null
# Journal disposal plan is frozen before any queue mutation; a refused local gate releases it.
fp=$(jq -Sc . "$2/plan"|sha256sum|cut -d ' ' -f1)
jq -n --arg fp "$fp" --slurpfile p "$2/plan" '{schema:1,jobs:{exact:{app:"Sonarr",downloadId:"exact",createdAt:1999999990,status:"observing",plan:$p[0],observation:{fingerprint:$fp,at:1999999700,runs:2}}}}' >"$PACK_STATE_FILE"
automation_window_open(){ return 0; };automation_action_budget(){ return 0; };monitor_mutation_gate(){ return 0; };automation_no_active_command(){ return 0; }
usr_ops_arr_reserve(){ return 0; };usr_ops_arr_release_undispatched(){ printf release >"$TMP_DIR/released"; }
policy_mutate(){
 jq -e '.jobs.exact.status=="queue_intent" and .jobs.exact.disposalPlan.accounted' "$PACK_STATE_FILE" >/dev/null
 printf '%s' "$2" >"$TMP_DIR/delete-url";return 75
}
pack_update '.jobs.exact.observation.runs=1'
pack_dispatch exact "$2/plan";[[ ! -f "$2/delete-url" ]]
pack_update '.jobs.exact.observation.runs=2'
pack_dispatch exact "$2/partial";[[ ! -f "$2/delete-url" ]]
pack_dispatch exact "$2/plan";[[ -f "$2/released" ]]
jq -e '.jobs.exact.status=="observing" and .jobs.exact.queueIntentAt==null' "$PACK_STATE_FILE" >/dev/null
# Exact disposition verification. Unknown response is retained and never replayed.
policy_mutate(){ printf '%s' "$2" >"$TMP_DIR/delete-url";return 1; }
pack_dispatch exact "$2/plan"
jq -e '.jobs.exact.status=="queue_intent"' "$PACK_STATE_FILE" >/dev/null
# Reconcile requires every target and the exact matching blocklist identity.
fetch_arr_queue(){ printf '{"records":[]}' >"$4"; }
fetch_arr_history_by_download_id(){ jq '.records|=map(.eventType="downloadFailed")' "$TMP_DIR/history" >"$3"; }
api_get_saved=$(declare -f api_get)
api_get(){
 if [[ "$1" == */blocklist\?* ]];then jq '{records:[{seriesId:1,sourceTitle:"Show.S01",episodeIds:[11,12],quality:{quality:{id:4}},date:"2033-05-18T03:33:20Z"}]}' <<< '{}' >"$3";else return 1;fi
}
pack_verify_queue_removal exact
jq -e '.jobs.exact.status=="queue_verified"' "$PACK_STATE_FILE" >/dev/null
# Search only the exact fileless target; no season search or replay on a second invocation.
eval "$api_get_saved"
SAB_TV_CATEGORY=tv
fetch_sab_queue(){ cp "$TMP_DIR/sab-queue" "$1"; }
automation_submit_command(){
 jq --slurpfile candidate "$1" --argjson now "$START_TIME" '.actions[$candidate[0].key]=$candidate[0]+{status:"completed",startedAt:$now,commandId:1}' "$AUTOMATION_STATE_FILE" >"$TMP_DIR/next";mv "$TMP_DIR/next" "$AUTOMATION_STATE_FILE"
}
pack_submit_searches exact
jq -e '(.actions|length)==2 and all(.actions[];.kind=="missing-search" and .command.name=="EpisodeSearch" and (.command.episodeIds|length)==1 and .targetId==.command.episodeIds[0])' "$AUTOMATION_STATE_FILE" >/dev/null
pack_submit_searches exact
jq -e '(.actions|length)==2' "$AUTOMATION_STATE_FILE" >/dev/null
jq '.monitored=false' "$2/ep11" >"$2/next";mv "$2/next" "$2/ep11"
if pack_missing_guard exact 11;then exit 1;fi
jq '.monitored=true' "$2/ep11" >"$2/next";mv "$2/next" "$2/ep11"
# Committed cleanup + two-scan per-target replacement proof is required to resolve.
MEDIA_PACK_CLEANUP_RECEIPT="$2/pack-cleanup.json"
jq '.jobs.exact|{schema:1,jobs:{exact:{createdAt:.createdAt,planFingerprint:.planFingerprint,files:(.disposalPlan.files|map({key:.relative,value:{status:"quarantined",identity:.identity}})|from_entries)}}}' "$PACK_STATE_FILE" >"$MEDIA_PACK_CLEANUP_RECEIPT"
pack_reconcile_receipts;jq -e '.jobs.exact.status=="queue_verified"' "$PACK_STATE_FILE" >/dev/null
pack_update '.jobs.exact.proofs={"11":{verified:true,at:1999999700},"12":{verified:true,at:2000000000}}'
pack_reconcile_receipts;jq -e '.jobs.exact.status=="queue_verified"' "$PACK_STATE_FILE" >/dev/null
pack_update '.jobs.exact.proofs["11"].at=2000000000' 
pack_reconcile_receipts;jq -e '.jobs.exact.status=="resolved"' "$PACK_STATE_FILE" >/dev/null
jq '.jobs.exact.files["Show.S01E02.mkv"].status="manual_restore"' "$MEDIA_PACK_CLEANUP_RECEIPT" >"$2/next";mv "$2/next" "$MEDIA_PACK_CLEANUP_RECEIPT"
pack_reconcile_receipts;jq -e '.jobs.exact.status=="manual_hold"' "$PACK_STATE_FILE" >/dev/null
# One pack-level completion with no repeated stable result. Historical command failure
# does not remain active after exact cleanup/replacement proof.
pack_update '.jobs.exact.status="resolved"'
jq '.actions.old={packId:"exact",kind:"missing-search",targetId:11,status:"failed",startedAt:1,commandId:5}' "$AUTOMATION_STATE_FILE" >"$2/next";mv "$2/next" "$AUTOMATION_STATE_FILE"
queue_group_notification(){
 printf '%s\n' "$9" >>"$TMP_DIR/pack-mails"
 jq --arg id exact --arg sig "$2" '.monitor.packNotifications[$id]=$sig' "$STATE_FILE" >"$TMP_DIR/next";mv "$TMP_DIR/next" "$STATE_FILE"
}
record_normalized_issue(){ printf '%s\n' "$*" >>"$TMP_DIR/pack-warnings"; }
pack_report;pack_report
[[ $(wc -l <"$2/pack-mails") == 1 ]];grep -q completed "$2/pack-mails";[[ ! -f "$2/pack-warnings" ]]
# Source identity must still match immediately before a move.
jq -n --arg identity "$(pack_host_identity "$2/complete/Show.S01/Show.S01E01.mkv")" '{sourceIdentity:$identity}' >"$2/move-proof"
pack_file_move_guard "$2/complete/Show.S01/Show.S01E01.mkv" "$2/move-proof"
printf changed >>"$2/complete/Show.S01/Show.S01E01.mkv"
if pack_file_move_guard "$2/complete/Show.S01/Show.S01E01.mkv" "$2/move-proof";then exit 1;fi
printf 'Complete native mapping, partial/unknown pack protection, exact disposition, durable uncertainty, receipts and final file identity passed\n'
'''
 result=subprocess.run([shutil.which('bash'),'-c',code,'fixture',str(R),str(t)],capture_output=True,text=True)
 print(result.stdout,end='');print(result.stderr,end='');assert result.returncode==0, f'Pack fixtures failed ({result.returncode})'
 # Test the real cleanup planner with a temporary quarantine adapter; no production paths.
 for name in ['Show.S01E01.mkv','Show.S01E02.mkv']:(payload/name).write_bytes(b'fixture')
 dump('consumer-inventory',m.inventory(str(payload),str(payload.parent)))
 cleanup=(R/'user_script/media_cleanup.sh').read_text();a=cleanup.index('mc_sab() (\n')+len('mc_sab() (\n');b=cleanup.index('\nmain "$@"\n',a)
 (t/'sab-library.sh').write_text(cleanup[:cleanup.index('\n# MODULE: ARR')]+'\n'+cleanup[a:b])
 consumer=r'''
set -euo pipefail
source "$2/sab-library.sh";trap - EXIT INT TERM HUP
TMP_DIR="$2";LOG_DIR="$2";DRY_RUN=false;RUN_ID=fixture
MEDIA_PACK_STATE_FILE="$2/consumer-state";SAB_HISTORY_FILE="$2/consumer-history";SAB_TV_DIR_REAL="$2/complete";SAB_CONTAINER_COMPLETE_ROOT="$2/complete"
SONARR_URL=http://sonarr;SONARR_API_KEY=fixture;MEDIA_INTEGRITY_RECOVERY_FILE="$2/recovery.json"
QUARANTINED=0;BYTES_QUARANTINED=0;MAX_QUARANTINES_PER_RUN=1;QUARANTINE_DETAILS=()
rm -f "$2/pack-cleanup.json"
jq --slurpfile inv "$2/consumer-inventory" '.source=$inv[0]|.files|=map(. as $f|.identity=([$inv[0].files[]|select(.relative==$f.relative)][0].identity))' "$2/plan" >"$2/consumer-plan"
fp=$(jq -Sc . "$2/consumer-plan"|sha256sum|cut -d ' ' -f1)
jq -n --arg fp "$fp" --slurpfile p "$2/consumer-plan" '{schema:1,jobs:{exact:{app:"Sonarr",downloadId:"exact",createdAt:2000000000,status:"queue_verified",planFingerprint:$fp,disposalPlan:$p[0]}}}' >"$MEDIA_PACK_STATE_FILE"
jq '.history.slots' "$2/sab-history" >"$SAB_HISTORY_FILE"
mc_work_allowed(){ return 0; };path_is_stable(){ return 0; };check_mover_guard(){ return 0; }
resolve_sab_path(){ printf '%s' "$TMP_DIR/complete/Show.S01"; }
refresh_active_state(){ return 0; };download_is_active_anywhere(){ [[ "${active:-false}" == true ]]; };orphan_has_live_reference(){ return 1; }
log(){ :; }
arr_get(){ case "$1" in */series/1) cp "$TMP_DIR/series" "$3";;*/qualityprofile) cp "$TMP_DIR/profiles" "$3";;*/customformat) cp "$TMP_DIR/formats" "$3";;*/episode/11) cp "$TMP_DIR/ep11" "$3";;*/episode/12) cp "$TMP_DIR/ep12" "$3";;*) return 1;;esac; }
pack_source_inventory(){ jq -n --arg folder "$1" --arg root "$2" '{folder:$folder,root:$root}'|python3 "$repo/tools/media_pack_inventory.py" >"$3"; }
ops_publish_checkpoint(){ mv "$1" "$2"; }
quarantine_payload(){
 pack_file_move_guard "$6" "$8" || return 1
 LAST_QUARANTINE_DESTINATION="$TMP_DIR/quarantine/$9/payload";mkdir -p "${LAST_QUARANTINE_DESTINATION%/*}"
 mv "$6" "$LAST_QUARANTINE_DESTINATION";printf '%s\n' "$6" >>"$TMP_DIR/moves"
}
# A manual restore on a later file holds the entire job, including earlier files.
jq --arg fp "$fp" '{schema:1,jobs:{exact:{createdAt:2000000000,planFingerprint:$fp,files:{"Show.S01E02.mkv":{status:"manual_restore"}}}}}' <<< '{}' >"$2/pack-cleanup.json"
process_pack_cleanup;[[ ! -f "$2/moves" ]];rm "$2/pack-cleanup.json"
active=true;process_pack_cleanup;[[ ! -f "$2/moves" ]];active=false
# An unexpected file invalidates full inventory even when all planned media are unchanged.
printf other >"$2/complete/Show.S01/unaccounted.mkv"
process_pack_cleanup;[[ ! -f "$2/moves" ]];rm "$2/complete/Show.S01/unaccounted.mkv"
process_pack_cleanup
[[ $(wc -l <"$2/moves") == 1 ]];[[ -f "$2/complete/Show.S01/poster.jpg" ]]
jq -e '[.jobs.exact.files[]|select(.status=="quarantined")]|length==1' "$2/pack-cleanup.json" >/dev/null
QUARANTINED=0
process_pack_cleanup
[[ $(wc -l <"$2/moves") == 2 ]];[[ -f "$2/complete/Show.S01/poster.jpg" ]]
jq -e 'all(.jobs.exact.files[];.status=="quarantined")' "$2/pack-cleanup.json" >/dev/null
printf 'Pack cleanup: whole-job manual-restore hold, active queue protection, unknown-entry veto, per-file cap/resume and retained metadata passed\n'
'''
 consumer='repo="'+str(R)+'"\n'+consumer
 result=subprocess.run([shutil.which('bash'),'-c',consumer,'fixture',str(R),str(t)],capture_output=True,text=True)
 print(result.stdout,end='');print(result.stderr,end='');assert result.returncode==0, f'Pack consumer fixtures failed ({result.returncode})'
 # Recreating the shared budget ledger must seed uncertain pack DELETE intents.
 budget=t/'budget';budget.mkdir();now=int(time.time())
 (budget/'pack-actions.json').write_text(json.dumps({'schema':1,'jobs':{str(i):{'downloadId':str(i),'queueIntentAt':now,'disposalPlan':{'targets':{'1':{'id':1}}}} for i in range(4)}}))
 code=r'''
set -euo pipefail
source "$1/tools/media_action_budget.sh"
USR_OPS_SHARED_BUDGET_ACTIVE=true;MEDIA_ACTION_BUDGET_ROOT="$2";MEDIA_ACTION_BUDGET_LOCK="$2/budget.lock";STATE_EXPORT_LOCK="$2/export.lock";OPS_SCRIPT_ID=fixture
if usr_ops_arr_reserve new Sonarr 1;then exit 1;fi
[[ ! -e "$2/action-budget.json" ]]
printf 'Pack intents retain the shared daily action allowance on ledger initialization\n'
'''
 subprocess.run([shutil.which('bash'),'-c',code,'fixture',str(R),str(budget)],check=True)
print('Read-only inventory and unsafe-path protection passed')
