#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/arr-automation-test.XXXXXX)
source <(awk '/^# LOCK$/{exit} {print}' "$repo/user_script/arr_health_activity.sh")
trap - EXIT INT TERM HUP
trap 'rm -rf -- "$fixture"' EXIT
TMP_DIR="$fixture"; STATE_DIR="$fixture"; STATE_FILE="$fixture/monitor.json"; AUTOMATION_STATE_FILE="$fixture/actions.json"
SONARR_API_ROOT=http://sonarr/api/v3; RADARR_API_ROOT=http://radarr/api/v3
SONARR_API_KEY=fixture; RADARR_API_KEY=fixture
SONARR_QUEUE="$fixture/sonarr-queue.json"; RADARR_QUEUE="$fixture/radarr-queue.json"
SAB_HISTORY="$fixture/sab.json"; SAB_QUEUE="$fixture/sab-queue.json"
SONARR_HEALTH="$fixture/sonarr-health.json"; RADARR_HEALTH="$fixture/radarr-health.json"
SONARR_AUDIT_HISTORY="$fixture/history.json"; RADARR_AUDIT_HISTORY="$fixture/radarr-history.json"
SONARR_AUDIT_OK=true; RADARR_AUDIT_OK=false
SONARR_API_OK=true; RADARR_API_OK=true; SONARR_QUEUE_OK=true; RADARR_QUEUE_OK=true; SAB_API_OK=true; SAB_HISTORY_OK=true; SAB_QUEUE_OK=true
sync() { :; }; log() { :; }; debug_log() { :; }; persistent_log() { :; }
save_state() { cp "$1" "$STATE_FILE"; }
runtime_budget_allows_optional_phase() { return 0; }
record_normalized_issue() { printf '%s\n' "$1" >>"$fixture/issues"; }
queue_group_notification() { printf '%s\n' "$1" >>"$fixture/notifications"; }
reset_state() {
 printf '{"version":1,"actions":{},"observations":{},"profiles":{},"events":{},"missing":{}}' >"$AUTOMATION_STATE_FILE"
 printf '{"issues":{},"monitor":{},"downloadLedger":{}}' >"$STATE_FILE"
 printf '{"records":[],"totalRecords":0}' >"$SONARR_QUEUE"; cp "$SONARR_QUEUE" "$RADARR_QUEUE"
 printf '[]' >"$SONARR_HEALTH"; cp "$SONARR_HEALTH" "$RADARR_HEALTH"
 printf '{"queue":{"slots":[]}}' >"$SAB_QUEUE"
 : >"$fixture/requests"; : >"$fixture/issues"; : >"$fixture/notifications"
}
START_TIME=$(TZ=Asia/Singapore date -d '2026-11-23 00:05:00' +%s)
fixture_now="$START_TIME"
fixture_profiles='[{"id":2,"name":"HD","minFormatScore":10,"cutoff":7,"items":[{"allowed":true,"quality":{"id":7}}],"formatItems":[{"format":1,"score":100}]}]'
fixture_formats='[{"id":1,"specifications":[]}]'
fixture_file='{}'
fixture_episode='{"id":11,"seriesId":1,"seasonNumber":1,"episodeNumber":1,"title":"Episode One","monitored":true,"hasFile":false,"episodeFileId":0,"airDateUtc":"2026-11-01T00:00:00Z"}'
fixture_series='{"id":1,"title":"Show","monitored":true,"qualityProfileId":2,"tags":[],"seasons":[{"seasonNumber":1,"monitored":true}]}'
fixture_movie='{"id":31,"title":"Movie","monitored":true,"hasFile":false,"movieFileId":0,"isAvailable":true,"added":"2026-11-01T00:00:00Z","tags":[],"qualityProfileId":2}'
fixture_history='{"records":[],"totalRecords":0}'
fixture_commands='[]'
fixture_command='{"id":42,"name":"EpisodeSearch","status":"completed","body":{"name":"EpisodeSearch","episodeIds":[11]}}'
fixture_wanted='{"records":[],"totalRecords":0}'
api_get() {
 printf '%s\n' "$1" >>"$fixture/requests"
 [ "${fixture_api_failure:-false}" != true ] || return 1
 case "$1" in
  */qualityprofile) printf '%s' "$fixture_profiles" >"$3";;
  */qualityprofile/2) jq '.[0]' <<<"$fixture_profiles" >"$3";;
  */episodefile/21) printf '%s' "$fixture_file" >"$3";;
  */customformat) printf '%s' "$fixture_formats" >"$3";;
  */episode/11) printf '%s' "$fixture_episode" >"$3";;
  */series/1) printf '%s' "$fixture_series" >"$3";;
  */movie/31) printf '%s' "$fixture_movie" >"$3";;
  */command/42) printf '%s' "$fixture_command" >"$3";;
  */command) printf '%s' "$fixture_commands" >"$3";;
  */wanted/missing*) printf '%s' "$fixture_wanted" >"$3";;
  */history*) printf '%s' "$fixture_history" >"$3";;
  *) printf 'Unexpected fixture request: %s\n' "$1" >&2; return 1;;
 esac
}
fetch_arr_queue() { cp "$SONARR_QUEUE" "$4"; }
fetch_sab_queue() { cp "$SAB_QUEUE" "$1"; }
policy_mutate() { printf '%s %s\n' "$1" "$2" >>"$fixture/mutations"; printf '%s' '{"id":42}' >"$5"; }
reset_state
# Approved Singapore windows, not host timezone.
automation_window_open
START_TIME=$((fixture_now+5*60)); if automation_window_open; then exit 1; fi
START_TIME=$((fixture_now+4*3600)); automation_window_open
START_TIME=$((fixture_now+3600)); if automation_window_open; then exit 1; fi
START_TIME="$fixture_now"
automation_prepare
[[ "$AUTOMATION_CONTROLS_OK" == true ]]
# Profile changes freeze new mutations; impossible score is explicitly reported.
START_TIME=$((START_TIME+3600))
fixture_profiles=$(jq '.[0].minFormatScore=20' <<<"$fixture_profiles")
automation_profile_audit Sonarr
jq -e --argjson now "$START_TIME" '.profiles.Sonarr.holdUntil==$now+14400 and (.events|length)==1' "$AUTOMATION_STATE_FILE" >/dev/null
START_TIME=$((START_TIME+3600)); fixture_profiles=$(jq '.[0].minFormatScore=101' <<<"$fixture_profiles")
automation_profile_audit Sonarr
jq -e '.profiles.Sonarr.issues|any(.[];.id=="2:minimum")' "$AUTOMATION_STATE_FILE" >/dev/null
# Exact missing target is eligible only with complete, clean history and no
# existing files, deletion events, monitoring holds, tags, queued downloads.
START_TIME="$fixture_now"; reset_state
printf '{"history":{"slots":[]}}' >"$SAB_HISTORY"
missing_candidate() { automation_build_missing_candidate Sonarr 11 1 episode "$SONARR_API_ROOT" fixture "$fixture/candidate.json"; }
missing_hold() { if missing_candidate; then echo 'Protected missing item admitted' >&2; exit 1; fi; }
missing_candidate
fixture_series=$(jq '.tags=[9]' <<<"$fixture_series"); missing_hold
fixture_series=$(jq '.tags=[]|.seasons[0].monitored=false' <<<"$fixture_series"); missing_hold
fixture_series=$(jq '.seasons[0].monitored=true' <<<"$fixture_series")
fixture_episode=$(jq '.episodeFileId=21|.hasFile=true' <<<"$fixture_episode"); missing_hold
fixture_episode=$(jq '.episodeFileId=0|.hasFile=false|.seriesId=2' <<<"$fixture_episode"); missing_hold
fixture_episode=$(jq '.seriesId=1' <<<"$fixture_episode")
fixture_history='{"totalRecords":1,"records":[{"episodeId":11,"eventType":"episodeFileDeleted","date":"2020-01-01T00:00:00Z"}]}'
missing_hold
fixture_history=$(jq '.totalRecords=2' <<<"$fixture_history"); missing_hold
fixture_history='{"totalRecords":0,"records":[]}'
printf '{"records":[{"seriesId":1,"episodeId":12}],"totalRecords":1}' >"$SONARR_QUEUE"; missing_hold
printf '{"records":[],"totalRecords":0}' >"$SONARR_QUEUE"
missing_candidate
# A native search is journaled and read back against the exact requested IDs.
automation_submit_command "$fixture/candidate.json" "$SONARR_API_ROOT" fixture
[[ "$(wc -l <"$fixture/mutations"|tr -d ' ')" = 1 ]]
jq -e 'any(.actions[];.status=="completed" and .outcome=="pending")' "$AUTOMATION_STATE_FILE" >/dev/null
# Readback of a different episode does not establish command acceptance.
fixture_command=$(jq '.body.episodeIds=[12]' <<<"$fixture_command")
if automation_command_readback "$fixture/candidate.json" "$SONARR_API_ROOT" fixture 42; then exit 1; fi
fixture_command=$(jq '.body.episodeIds=[11]' <<<"$fixture_command")
# A timeout after POST never causes a second POST on reconciliation.
reset_state; : >"$fixture/mutations"
policy_mutate() { printf 'POST\n' >>"$fixture/mutations"; return 1; }
if automation_submit_command "$fixture/candidate.json" "$SONARR_API_ROOT" fixture; then exit 1; fi
automation_reconcile_commands
[[ "$(wc -l <"$fixture/mutations"|tr -d ' ')" = 1 ]]
jq -e 'any(.actions[];.status=="intent" and (.commandId // 0)==0)' "$AUTOMATION_STATE_FILE" >/dev/null
# Unknown manual SAB jobs veto a speculative duplicate search.
reset_state
printf '{"queue":{"slots":[{"nzo_id":"manual-job","cat":"tv"}]}}' >"$SAB_QUEUE"
if automation_last_moment_guard "$fixture/candidate.json" "$SONARR_API_ROOT" fixture; then exit 1; fi
printf '{"queue":{"slots":[]}}' >"$SAB_QUEUE"
# First survey records a legacy backlog and emits NO search for it.
fixture_wanted='{"totalRecords":1,"records":[{"id":11,"seriesId":1}]}'
: >"$fixture/mutations"
automation_missing_searches
jq -e '.missing.Sonarr.baselineIds==[11] and .missing.Radarr.baselineIds==[11]' "$AUTOMATION_STATE_FILE" >/dev/null
[[ ! -s "$fixture/mutations" ]]
# Receipt capture consumes real native fileId/event identity, including fractional
# timestamps; it binds the immutable SAB job and does not inspect media paths.
reset_state
SAB_TV_CATEGORY=tv; SAB_MOVIE_CATEGORY=movies
printf '{"history":{"slots":[{"nzo_id":"abc-123","name":"Show.S01E01","storage":"/data/net/complete/series/show","completed":1795300000,"category":"tv","status":"Completed"}]}}' >"$SAB_HISTORY"
printf '[{"id":123,"downloadId":"abc-123","eventType":"downloadFolderImported","episodeId":11,"seriesId":1,"date":"2026-11-22T08:00:00.123Z","sourceTitle":"Show.S01E01","data":{"fileId":"21","downloadClient":"SABnzbd","importedPath":"/data/series/show/old-name.mkv"},"episode":{"seasonNumber":1,"episodeNumber":1}}]' >"$SONARR_AUDIT_HISTORY"
fixture_history='{"totalRecords":0,"records":[]}'
capture_durable_import_receipts
jq -e '.receipts["Sonarr:abc-123"].targets["episode:11:21"].fileId==21 and .receipts["Sonarr:abc-123"].conflict==false' "$STATE_DIR/import-receipts.json" >/dev/null
# Once a target is known to have imported, do not resurrect it through search
# when its file later goes missing and native deletion history has aged out.
missing_hold
# Cache projections lacking parent resources are safely enriched from exact
# current object/file/path identity, then retained on subsequent compact events.
fixture_episode=$(jq '.hasFile=true|.episodeFileId=21' <<<"$fixture_episode")
fixture_series=$(jq '.tvdbId=1001' <<<"$fixture_series")
fixture_file='{"id":21,"seriesId":1,"path":"/data/series/show/old-name.mkv","size":1000}'
START_TIME=$((START_TIME+86401))
capture_durable_import_receipts
jq -e '.receipts["Sonarr:abc-123"].targets["episode:11:21"].parentExternalId==1001' "$STATE_DIR/import-receipts.json" >/dev/null
capture_durable_import_receipts
jq -e '.receipts["Sonarr:abc-123"].targets["episode:11:21"].parentExternalId==1001' "$STATE_DIR/import-receipts.json" >/dev/null
fixture_episode=$(jq '.hasFile=false|.episodeFileId=0' <<<"$fixture_episode")
# Receipt conflicts never overwrite original payload ownership evidence.
jq '.history.slots[0].storage="/data/net/complete/series/different"' "$SAB_HISTORY" >"$fixture/new"; mv "$fixture/new" "$SAB_HISTORY"
capture_durable_import_receipts
jq -e '.receipts["Sonarr:abc-123"].conflict==true and .receipts["Sonarr:abc-123"].sab.storage=="/data/net/complete/series/show"' "$STATE_DIR/import-receipts.json" >/dev/null
printf 'Approved windows, profile drift, missing/deletion guards, exact command readback, unknown outcomes, baseline and durable receipt tests passed\n'
# A real transient-lock workflow observes twice before an Auto scan and still
# respects the four-hour retry cooldown, deletion veto and permanent reasons.
reset_state; rm -f "$STATE_DIR/import-receipts.json"
START_TIME=$((fixture_now-300))
fixture_history='{"records":[{"downloadId":"abc-123","episodeId":11,"seriesId":1,"eventType":"grabbed","date":"2026-11-20T00:00:00Z"}],"totalRecords":1}'
fixture_retry=$(jq -nc '{id:9,downloadId:"abc-123",protocol:"usenet",status:"completed",trackedDownloadState:"importPending",trackedDownloadStatus:"warning",added:"2026-11-20T00:00:00Z",episodeId:11,seriesId:1,seasonNumber:1,title:"Show.S01E01",outputPath:"/data/net/complete/series/show",statusMessages:[{messages:["File is being used by another process"]}]}')
jq -n --argjson item "$fixture_retry" '{records:[$item],totalRecords:1}' >"$SONARR_QUEUE"
jq -n --argjson completed "$((START_TIME-8*3600))" '{history:{slots:[{nzo_id:"abc-123",name:"Show.S01E01",storage:"/data/net/complete/series/show",completed:$completed,category:"tv",status:"Completed"}]}}' >"$SAB_HISTORY"
fixture_command='{"id":42,"name":"DownloadedEpisodesScan","status":"completed","body":{"name":"DownloadedEpisodesScan","path":"/data/net/complete/series/show","downloadClientId":"abc-123","importMode":"auto"}}'
policy_mutate() { printf 'POST\n' >>"$fixture/mutations"; printf '{"id":42}' >"$5"; }
: >"$fixture/mutations"
automation_import_retries
[[ ! -s "$fixture/mutations" ]]
START_TIME=$((START_TIME+300)); automation_import_retries
[[ "$(wc -l <"$fixture/mutations"|tr -d ' ')" = 1 ]]
jq -e 'any(.actions[];.kind=="import-retry" and .command.importMode=="Auto" and .command.downloadClientId=="abc-123")' "$AUTOMATION_STATE_FILE" >/dev/null
# Four-hour boundary observations are allowed before cooldown elapses, but the
# next mutation waits until the same +5-minute slot as the prior attempt.
START_TIME=$((START_TIME+4*3600-300)); automation_import_retries
[[ "$(wc -l <"$fixture/mutations"|tr -d ' ')" = 1 ]]
START_TIME=$((START_TIME+300)); automation_import_retries
[[ "$(wc -l <"$fixture/mutations"|tr -d ' ')" = 2 ]]
# Mixing a policy/permission warning into a busy-file warning forbids retry.
jq '.records[0].statusMessages[0].messages += ["Permission denied"]' "$SONARR_QUEUE" >"$fixture/new"; mv "$fixture/new" "$SONARR_QUEUE"
START_TIME=$((START_TIME+4*3600-300)); automation_import_retries
START_TIME=$((START_TIME+300)); automation_import_retries
[[ "$(wc -l <"$fixture/mutations"|tr -d ' ')" = 2 ]]
printf 'Transient lock retries retain Auto import, stable scans, exact download/path proof, cooldown and mixed-warning protection\n'

# Eventual success requires fresh exact-file evidence and two positive scans;
# a negative hasFile observation resets grace instead of closing stale issues.
START_TIME=$((START_TIME+3600))
fixture_episode=$(jq '.hasFile=true|.episodeFileId=21' <<<"$fixture_episode")
fixture_profiles=$(jq '.[0].minFormatScore=10' <<<"$fixture_profiles")
fixture_added=$(date -u -d "@$START_TIME" +%Y-%m-%dT%H:%M:%SZ)
fixture_file=$(jq -nc --arg added "$fixture_added" '{id:21,seriesId:1,path:"/library/show.mkv",size:1000,dateAdded:$added,customFormatScore:100,quality:{quality:{id:7}}}')
jq -n --argjson job '{"nzo_id":"abc-123"}' --argjson epoch "$START_TIME" '{version:1,receipts:{"Sonarr:abc-123":{app:"Sonarr",downloadId:"abc-123",conflict:false,sab:$job,targets:{one:{kind:"episode",targetId:11,parentId:1,fileId:21,importedAt:$epoch,pathAtImport:"/library/show.mkv"}}}}}' >"$STATE_DIR/import-receipts.json"
automation_followup_imports
jq -e 'all(.actions[];.proofRuns==1 and .outcome=="pending")' "$AUTOMATION_STATE_FILE" >/dev/null
fixture_episode=$(jq '.hasFile=false|.episodeFileId=0' <<<"$fixture_episode")
START_TIME=$((START_TIME+300)); automation_followup_imports
jq -e 'all(.actions[];.proofRuns==0 and .outcome=="pending")' "$AUTOMATION_STATE_FILE" >/dev/null
fixture_episode=$(jq '.hasFile=true|.episodeFileId=21' <<<"$fixture_episode")
START_TIME=$((START_TIME+3600)); automation_followup_imports
START_TIME=$((START_TIME+300)); automation_followup_imports
jq -e 'all(.actions[];.outcome=="import_verified" and .verifiedFileId==21)' "$AUTOMATION_STATE_FILE" >/dev/null
printf 'Fresh exact native file, matching download receipt and two positive scans required for action recovery\n'
# A newly missing item beyond the baseline gets one exact native search only
# after two independent approved-window scans. Legacy baseline IDs stay held.
reset_state; rm -f "$STATE_DIR/import-receipts.json"
START_TIME=$(TZ=Asia/Singapore date -d '2026-11-30 00:00:00' +%s)
fixture_episode=$(jq '.hasFile=false|.episodeFileId=0' <<<"$fixture_episode")
fixture_history='{"records":[],"totalRecords":0}'
fixture_wanted='{"records":[{"id":11,"seriesId":1}],"totalRecords":1}'
fixture_command='{"id":42,"name":"EpisodeSearch","status":"completed","body":{"name":"EpisodeSearch","episodeIds":[11]}}'
automation_state_update '.missing.Sonarr={baselineAt:1,baselineIds:[99],surveyedAt:1,window:"old",cursor:0,selected:[]} |
 .missing.Radarr={baselineAt:1,baselineIds:[31],surveyedAt:$now,window:"other",cursor:0,selected:[]}' --argjson now "$START_TIME"
: >"$fixture/mutations"
automation_missing_searches
[[ ! -s "$fixture/mutations" ]]
START_TIME=$((START_TIME+300)); automation_missing_searches
[[ "$(wc -l <"$fixture/mutations"|tr -d ' ')" = 1 ]]
jq -e 'any(.actions[];.kind=="missing-search" and .command.name=="EpisodeSearch" and .command.episodeIds==[11])' "$AUTOMATION_STATE_FILE" >/dev/null
# Failed native command identifiers cannot be reinterpreted as an import or
# replayed; acceptance and bare command completion share one notification.
printf 'Native weekly survey dispatches only exact new missing targets after grace\n'
