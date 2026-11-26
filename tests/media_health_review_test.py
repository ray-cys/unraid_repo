"""Read-only historical review: exact file policy, unknown archival and durable weekly reports."""
from pathlib import Path
import shutil,subprocess,tempfile,json
R=Path(__file__).resolve().parents[1]
s=(R/'user_script/media_health_monitor.sh').read_text();library=s[:s.index('\n# LOCK\n')]
with tempfile.TemporaryDirectory(prefix='media-review.') as d:
 t=Path(d).resolve();(t/'monitor.sh').write_text(library)
 def put(name,data):(t/name).write_text(json.dumps(data))
 profiles=[{'id':1,'minFormatScore':100,'upgradeAllowed':True,'cutoffFormatScore':100,'items':[{'allowed':True,'quality':{'id':4}}],'formatItems':[]}]
 put('profiles',profiles);put('formats',[])
 put('movie',{'id':1,'tmdbId':999,'qualityProfileId':1,'hasFile':True,'movieFileId':55,'monitored':True,'tags':[]})
 put('file',{'id':55,'movieId':1,'size':1234,'path':'/library/movie.mkv','customFormatScore':200,'qualityCutoffNotMet':False,'quality':{'quality':{'id':4}},'dateAdded':'2020-01-01T00:00:00Z'})
 put('series',{'id':3,'tvdbId':888,'qualityProfileId':1,'monitored':True,'tags':[],'seasons':[{'seasonNumber':1,'monitored':True}]})
 for i in [1,2]:
  put(f'episode{i}',{'id':i,'seriesId':3,'seasonNumber':1,'episodeNumber':i,'monitored':True,'hasFile':True,'episodeFileId':55+i})
  put(f'episodefile{55+i}',{'id':55+i,'seriesId':3,'seasonNumber':1,'size':1234,'path':f'/library/episode{i}.mkv','customFormatScore':200,'qualityCutoffNotMet':False,'quality':{'quality':{'id':4}},'dateAdded':'2020-01-01T00:00:00Z'})
 for name in ['sonarr-health','radarr-health']:put(name,[])
 for name in ['sonarr-queue','radarr-queue']:put(name,{'records':[]})
 put('sab-queue',{'queue':{'slots':[]}});put('sab-history',{'history':{'slots':[]}})
 code=r'''
set -euo pipefail
trap 'printf "Review fixture failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
source "$2/monitor.sh";trap - EXIT INT TERM HUP
TMP_DIR="$2";STATE_DIR="$2";STATE_FILE="$2/state";AUTOMATION_STATE_FILE="$2/automation";START_TIME=2000000000
SONARR_QUEUE="$2/sonarr-queue";RADARR_QUEUE="$2/radarr-queue";SONARR_HEALTH="$2/sonarr-health";RADARR_HEALTH="$2/radarr-health";SAB_QUEUE="$2/sab-queue";SAB_HISTORY="$2/sab-history"
SONARR_QUEUE_OK=true;RADARR_QUEUE_OK=true;SAB_QUEUE_OK=true;SAB_HISTORY_OK=true;SONARR_AUDIT_OK=true;RADARR_AUDIT_OK=true;SONARR_HEALTH_OK=true;RADARR_HEALTH_OK=true;SAB_API_OK=true
DOWNLOAD_LEDGER_RECONCILIATION_RESULTS_FILE="$2/results";: >"$2/results"
sig=$(pack_profile_signature "$2/profiles" "$2/formats")
jq -n --arg sig "$sig" --argjson now "$START_TIME" '{actions:{},profiles:{Radarr:{signature:$sig,holdUntil:0,checkedAt:$now}}}' >"$AUTOMATION_STATE_FILE"
save_state(){ mv "$1" "$STATE_FILE"; }
log(){ :; };persistent_log(){ :; };runtime_budget_allows_optional_phase(){ return 0; };media_recovery_app_held(){ [[ "${repair:-false}" == true ]]; }
arr_reconciliation_connection(){ printf 'http://fixture/api/v3\tfixture\n'; }
api_get(){ case "$1" in */qualityprofile) cp "$TMP_DIR/profiles" "$3";;*/customformat) cp "$TMP_DIR/formats" "$3";;*/movie/1) cp "$TMP_DIR/movie" "$3";;*/moviefile/55) cp "$TMP_DIR/file" "$3";;*/series/3) cp "$TMP_DIR/series" "$3";;*/episode/1) cp "$TMP_DIR/episode1" "$3";;*/episode/2) cp "$TMP_DIR/episode2" "$3";;*/episodefile/56) cp "$TMP_DIR/episodefile56" "$3";;*/episodefile/57) cp "$TMP_DIR/episodefile57" "$3";;*) return 1;;esac; }
queue_group_notification(){
 jq -nc --arg key "$1" --arg sig "$2" --arg detail "$8" --arg event "$9" '{key:$key,signature:$sig,detail:$detail,event:$event}' >>"$TMP_DIR/queued"
 jq --arg key "$1" --arg sig "$2" --arg detail "$8" --arg event "$9" '.monitor.notification.outbox[$key]={issueKey:$key,signature:$sig,detail:$detail,event:$event}' "$STATE_FILE" >"$TMP_DIR/next";mv "$TMP_DIR/next" "$STATE_FILE"
}
# Current acceptable files close a requirement but never claim an import.
jq -n '{monitor:{notification:{outbox:{}}},issues:{"FLOW:DOWNLOAD:known":{active:true,app:"Radarr",title:"Movie",classification:"DOWNLOAD_FLOW_REVIEW_REQUIRED",severity:"WARNING",message:"Old outcome unknown",firstSeen:1900000000,lastSeen:2000000000}},downloadLedger:{known:{id:"known",app:"Radarr",title:"Movie",release:"Movie",targets:{"movie:1":{type:"movie",movieId:1,preFileKnown:true,preFileId:55}},arrImportedAt:0}}}' >"$STATE_FILE"
record=$(jq -c .downloadLedger.known "$STATE_FILE")
review_current_targets_satisfied known Radarr "$record"
update_download_reconciliation_state
jq -e '.downloadLedger.known.arrImportedAt==0 and (.downloadLedger.known.arrReconciledAt // 0)==0 and .downloadLedger.known.reconciliationCandidateRuns==1' "$STATE_FILE" >/dev/null
# Same-invocation repeated checking cannot count as an independent scan.
review_current_targets_satisfied known Radarr "$record";update_download_reconciliation_state
jq -e '.downloadLedger.known.reconciliationCandidateRuns==1' "$STATE_FILE" >/dev/null
START_TIME=$((START_TIME+300));review_current_targets_satisfied known Radarr "$record";update_download_reconciliation_state
jq -e '.downloadLedger.known.arrImportedAt==0 and .downloadLedger.known.arrReconciledAt>0 and .downloadLedger.known.reconciliationKind=="target-satisfied"' "$STATE_FILE" >/dev/null
# Bad score, a protected tag, an active parent download or repair hold veto closure.
cp "$2/file" "$2/file.saved";jq '.customFormatScore=0' "$2/file.saved" >"$2/file"
if review_current_targets_satisfied known Radarr "$record";then exit 1;fi;cp "$2/file.saved" "$2/file"
cp "$2/movie" "$2/movie.saved";jq '.tags=[1]' "$2/movie.saved" >"$2/movie"
if review_current_targets_satisfied known Radarr "$record";then exit 1;fi;cp "$2/movie.saved" "$2/movie"
repair=true;if review_current_targets_satisfied known Radarr "$record";then exit 1;fi;repair=false
printf '{"records":[{"movieId":1,"downloadId":"another","title":"Different"}]}' >"$RADARR_QUEUE"
if review_current_targets_satisfied known Radarr "$record";then exit 1;fi;printf '{"records":[]}' >"$RADARR_QUEUE"
# Native quality cutoff and custom-format upgrade goals must both be met.
jq '.qualityCutoffNotMet=true' "$2/file.saved" >"$2/file"
if review_current_targets_satisfied known Radarr "$record";then exit 1;fi;cp "$2/file.saved" "$2/file"
cp "$2/profiles" "$2/profiles.saved";jq '.[0].cutoffFormatScore=300' "$2/profiles.saved" >"$2/profiles"
sig=$(pack_profile_signature "$2/profiles" "$2/formats")
jq --arg sig "$sig" '.profiles.Radarr.signature=$sig' "$AUTOMATION_STATE_FILE" >"$2/next";mv "$2/next" "$AUTOMATION_STATE_FILE"
if review_current_targets_satisfied known Radarr "$record";then exit 1;fi;cp "$2/profiles.saved" "$2/profiles"
# Unknown IDs are not reconciled by release-title similarity.
if review_current_targets_satisfied known Radarr '{"title":"Movie","targets":{}}';then exit 1;fi
# Sonarr packs require every exact native series/season/episode/file identity.
sig=$(pack_profile_signature "$2/profiles" "$2/formats")
jq --arg sig "$sig" --argjson now "$START_TIME" '.profiles.Sonarr={signature:$sig,holdUntil:0,checkedAt:$now}' "$AUTOMATION_STATE_FILE" >"$2/next";mv "$2/next" "$AUTOMATION_STATE_FILE"
jq '.issues["FLOW:DOWNLOAD:known"].app="Sonarr"|.downloadLedger.known.app="Sonarr"|.downloadLedger.known.targets={a:{type:"episode",seriesId:3,episodeId:1,seasonNumber:1,episodeNumber:1},b:{type:"episode",seriesId:3,episodeId:2,seasonNumber:1,episodeNumber:2}}' "$STATE_FILE" >"$2/next";mv "$2/next" "$STATE_FILE"
record=$(jq -c .downloadLedger.known "$STATE_FILE")
review_current_targets_satisfied known Sonarr "$record"
cp "$2/episode2" "$2/episode2.saved";jq '.hasFile=false|.episodeFileId=0' "$2/episode2.saved" >"$2/episode2"
if review_current_targets_satisfied known Sonarr "$record";then exit 1;fi
jq '.seasonNumber=2' "$2/episode2.saved" >"$2/episode2"
if review_current_targets_satisfied known Sonarr "$record";then exit 1;fi;cp "$2/episode2.saved" "$2/episode2"
printf 'All-target native policy proof, independent scans and non-import outcome; tag/repair/queue/quality vetoes passed\n'
# Administrative archival: exact 20-day boundary, two healthy absences, unknown identities only.
START_TIME=2000000000
jq -n --argjson now "$START_TIME" '{monitor:{notification:{outbox:{}}},issues:{"FLOW:DOWNLOAD:old":{active:true,app:"Sonarr",title:"Old release",classification:"DOWNLOAD_FLOW_REVIEW_REQUIRED",severity:"WARNING",message:"Outcome unknown",ackId:"abc",firstSeen:($now-25*86400),lastSeen:$now}},downloadLedger:{old:{id:"old",app:"Sonarr",title:"Old release",release:"Old release",flowEnrolled:true,targets:{},firstSeen:($now-25*86400),sabQueuedAt:($now-20*86400),reconciliationLastScanOk:true,reconciliationLastCheckedAt:$now,reconciliationCandidateRuns:0}}}' >"$STATE_FILE"
# A younger attempt and an identified missing target must remain active.
jq '.downloadLedger.young=(.downloadLedger.old|.id="young"|.firstSeen=2000000000|.sabQueuedAt=2000000000)|.issues["FLOW:DOWNLOAD:young"]=(.issues["FLOW:DOWNLOAD:old"]|.firstSeen=2000000000)|.downloadLedger.identified=(.downloadLedger.old|.id="identified"|.targets={a:{type:"episode",episodeId:100,seriesId:3}})|.issues["FLOW:DOWNLOAD:identified"]=.issues["FLOW:DOWNLOAD:old"]' "$STATE_FILE" >"$2/next";mv "$2/next" "$STATE_FILE"
process_historical_review_archive
jq -e '(.downloadLedger.old.historicalArchivedAt // 0)==0' "$STATE_FILE" >/dev/null
START_TIME=$((START_TIME+300));process_historical_review_archive
jq -e '.monitor.historicalReviewArchive.old.outcome=="UNKNOWN" and .issues["FLOW:DOWNLOAD:old"].active==false and (.downloadLedger.old.arrImportedAt // 0)==0 and (.downloadLedger.old.arrReconciledAt // 0)==0' "$STATE_FILE" >/dev/null
jq -e '(.downloadLedger.young.historicalArchivedAt // 0)==0 and (.downloadLedger.identified.historicalArchivedAt // 0)==0 and .issues["FLOW:DOWNLOAD:young"].active and .issues["FLOW:DOWNLOAD:identified"].active' "$STATE_FILE" >/dev/null
# A reappearing attempt reopens even after the old ledger was pruned.
jq 'del(.downloadLedger.old)' "$STATE_FILE" >"$TMP_DIR/next";mv "$TMP_DIR/next" "$STATE_FILE"
printf '{"queue":{"slots":[{"nzo_id":"old","filename":"Old release"}]}}' >"$SAB_QUEUE"
process_historical_review_archive
jq -e '.monitor.historicalReviewArchive.old.reopenedAt>0' "$STATE_FILE" >/dev/null
printf '{"queue":{"slots":[]}}' >"$SAB_QUEUE"
# Outage invalidates absence observations instead of confirming archival.
jq '.monitor.reviewAbsence.test={runs:1,at:2000000000}' "$STATE_FILE" >"$TMP_DIR/next";mv "$TMP_DIR/next" "$STATE_FILE"
SAB_QUEUE_OK=false;process_historical_review_archive
jq -e '.monitor.reviewAbsence==null' "$STATE_FILE" >/dev/null;SAB_QUEUE_OK=true
printf '20-day unknown archival, no false success, positive reappearance and outage reset passed\n'
# Weekly reports include exhausted/acknowledged warnings and group display only.
START_TIME=$(TZ=Asia/Singapore date -d '2026-11-29 19:05:00' +%s)
jq -n --argjson now "$START_TIME" '{monitor:{weeklyReview:{enrolledAt:($now-86400)},notification:{outbox:{}}},issues:{a:{active:true,app:"Sonarr",title:"Same release",classification:"DOWNLOAD_FLOW_REVIEW_REQUIRED",severity:"WARNING",message:"Unknown attempt A",ackId:"one",firstSeen:($now-86400),lastSeen:$now,reminderCount:3,signature:"same",acknowledgedSignature:"same"},b:{active:true,app:"Sonarr",title:"Same release",classification:"DOWNLOAD_FLOW_REVIEW_REQUIRED",severity:"WARNING",message:"Unknown attempt B",ackId:"two",firstSeen:($now-86400),lastSeen:$now,reminderCount:3}},downloadLedger:{}}' >"$STATE_FILE"
review_report_build "$2/report.json" "$2/report.txt"
jq -e '.activeWarnings==2 and (.groups|length)==1 and (.groups[0].attempts|length)==2 and .groups[0].attempts[0].acknowledged==true' "$2/report.json" >/dev/null
# Long details must survive numbered email parts without truncation.
jq --arg long "$(printf 'Detailed reason %.0s' {1..800})" '.issues.a.message=$long' "$STATE_FILE" >"$TMP_DIR/next";mv "$TMP_DIR/next" "$STATE_FILE"
: >"$2/queued";process_weekly_media_review
file="$STATE_DIR/weekly-reports/media-health-review-2026-11-29.txt"
[[ -f "$file" ]]
jq -jrs '[.[]|select(.event=="weekly")|.detail]|join("")' "$2/queued" >"$2/joined"
# Reassembled delivery must reproduce every report byte exactly.
cmp "$file" "$2/joined" || { wc -c "$file" "$2/joined"; diff -u "$file" "$2/joined" | tail -n 30; exit 1; }
# Existing pending delivery prevents another report or repeat enqueue.
count=$(wc -l <"$2/queued");process_weekly_media_review;[[ $(wc -l <"$2/queued") == "$count" ]]
# Simulate an interruption after the first accepted part; resume only missing parts.
first=$(jq -sc 'map(select(.event=="weekly"))[0]' "$2/queued")
mark_notified "$(jq -r .key <<<"$first")" "$(jq -r .signature <<<"$first")" weekly
jq '.monitor.notification.outbox={}' "$STATE_FILE" >"$TMP_DIR/next";mv "$TMP_DIR/next" "$STATE_FILE"
: >"$2/queued";process_weekly_media_review
jq -se --arg first "$(jq -r .key <<<"$first")" 'all(.[];.key!=$first)' "$2/queued" >/dev/null
# Acknowledge through the real mark_notified callback, then drain the fixture outbox.
while IFS= read -r row;do mark_notified "$(jq -r .key <<<"$row")" "$(jq -r .signature <<<"$row")" weekly;done < <(jq -c 'select(.event=="weekly")' "$2/queued")
jq '.monitor.notification.outbox={}' "$STATE_FILE" >"$TMP_DIR/next";mv "$TMP_DIR/next" "$STATE_FILE"
process_weekly_media_review
jq -e '.monitor.weeklyReview.lastDeliveredPeriod=="2026-11-29"' "$STATE_FILE" >/dev/null
# Keep exactly two weekly report files over successive weeks.
for date in '2026-12-06 19:05:00' '2026-12-13 19:05:00';do
 START_TIME=$(TZ=Asia/Singapore date -d "$date" +%s);: >"$2/queued";process_weekly_media_review
 while IFS= read -r row;do mark_notified "$(jq -r .key <<<"$row")" "$(jq -r .signature <<<"$row")" weekly;done < <(jq -c 'select(.event=="weekly")' "$2/queued")
 jq '.monitor.notification.outbox={}' "$STATE_FILE" >"$TMP_DIR/next";mv "$TMP_DIR/next" "$STATE_FILE";process_weekly_media_review
done
[[ $(find "$STATE_DIR/weekly-reports" -maxdepth 1 -name '*.txt'|wc -l) == 2 ]]
[[ ! -f "$file" ]]
# Healthy empty weeks are quiet and create no report file.
START_TIME=$(TZ=Asia/Singapore date -d '2026-12-20 19:05:00' +%s)
jq '.issues={}|.downloadLedger={}|.monitor.historicalReviewArchive={}' "$STATE_FILE" >"$2/next";mv "$2/next" "$STATE_FILE"
: >"$2/queued";process_weekly_media_review
[[ ! -s "$2/queued" && ! -f "$STATE_DIR/weekly-reports/media-health-review-2026-12-20.txt" ]]
jq -e '.monitor.weeklyReview.skippedEmpty==true' "$STATE_FILE" >/dev/null
printf 'Weekly grouping, acknowledged/exhausted backlog, complete email parts, durable acknowledgement and two-report retention passed\n'
'''
 result=subprocess.run([shutil.which('bash'),'-c',code,'fixture',str(R),str(t)],capture_output=True,text=True)
 print(result.stdout,end='');print(result.stderr,end='');assert result.returncode==0, f'Review fixtures failed: {result.returncode}'
