#!/usr/bin/env bash
# Native replacement fixtures: no real Arr, Docker, library or download calls.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/media_integrity_audit.sh"
fixture=$(mktemp -d /tmp/arr-native-fixture.XXXXXX)
trap 'rm -rf "$fixture"' EXIT
STATE_DIR="$fixture/state";TMP_DIR="$fixture/tmp";MEDIA_HOST_ROOT="$fixture/media";STATE_EXPORT_LOCK="$fixture/export.lock";ARR_BACKUP_GATE="$fixture/backup.lock"
mkdir -p "$STATE_DIR" "$TMP_DIR" "$MEDIA_HOST_ROOT/movies/Example" "$MEDIA_HOST_ROOT/series/Example"
RECOVERY_FILE="$STATE_DIR/recovery.json";SONARR_API_KEY=fixture;RADARR_API_KEY=fixture;RECOVERY_ALLOW_GRAB=true
workload_guard() { return 0; };recovery_window_open() { return 0; };recovery_new_window_open() { return 0; };recovery_capacity_ready() { return 0; };recovery_platform_ready() { return 0; };recovery_runtime_matches() { return 0; }
timeout() { shift;"$@"; }
docker() { while [[ "$1" != python3 ]];do shift;done;command "$@"; }
recovery_file_tool() { [[ "$1" == identity ]] || return 2;python3 -c 'import json,os,sys;s=os.stat(sys.argv[1]);print(json.dumps([str(v) for v in (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)]))' "$MEDIA_HOST_ROOT/$2"; }
requests="$fixture/requests";grabbed=false;replacement=false;lost=false;bad=false
fixture_profile='{"id":1,"minFormatScore":10,"items":[{"allowed":true,"quality":{"id":1}},{"allowed":true,"quality":{"id":2}}]}'
quality='{"quality":{"id":1},"revision":{"version":1,"real":0,"isRepack":false}}'
recovery_api() {
 local method="$1" url="$2" output="$3" payload="${4:-}"
 printf '%s %s\n' "$method" "$url" >>"$requests";RECOVERY_HTTP=200
 case "$method:$url" in
 GET:/health|GET:/command) printf '[]' >"$output";;
 GET:/queue*) printf '{"totalRecords":0,"records":[]}' >"$output";;
 GET:/config/mediamanagement|GET:/settings/mediamanagement) printf '{"recycleBin":"/data/arr_bin","recycleBinCleanupDays":2}' >"$output";;
 GET:/qualityprofile/1) printf '%s' "$fixture_profile" >"$output";;
 GET:/movie) jq -n --argjson q "$quality" '[{id:10,tmdbId:99,monitored:true,tags:[],qualityProfileId:1,hasFile:true,movieFileId:100,movieFile:{id:100,path:"/data/movies/Example/film.mkv",quality:$q}}]' >"$output";;
 GET:/movie/10) jq -n --argjson replacement "$replacement" '{id:10,tmdbId:99,monitored:true,tags:[],qualityProfileId:1,hasFile:true,movieFileId:(if $replacement then 101 else 100 end)}' >"$output";;
 GET:/series) printf '[{"id":20,"tvdbId":88,"path":"/data/series/Example","monitored":true,"tags":[],"qualityProfileId":1,"seasons":[{"seasonNumber":1,"monitored":true}]}]' >"$output";;
 GET:/series/20) printf '{"id":20,"tvdbId":88,"monitored":true,"tags":[],"qualityProfileId":1,"seasons":[{"seasonNumber":1,"monitored":true}]}' >"$output";;
 GET:/episodefile?seriesId=20) printf '[{"id":100,"seriesId":20,"path":"/data/series/Example/film.mkv"}]' >"$output";;
 GET:/episode?seriesId=20) printf '[{"id":201,"seriesId":20,"seasonNumber":1,"episodeNumber":1,"monitored":true,"hasFile":true,"episodeFileId":100},{"id":202,"seriesId":20,"seasonNumber":1,"episodeNumber":2,"monitored":true,"hasFile":true,"episodeFileId":100}]' >"$output";;
 GET:/episode/201|GET:/episode/202) jq -n --argjson id "${url##*/}" --argjson rep "$replacement" '{id:$id,seriesId:20,monitored:true,hasFile:true,episodeFileId:(if $rep then 101 else 100 end)}' >"$output";;
 GET:/moviefile/100|GET:/episodefile/100|GET:/moviefile/101|GET:/episodefile/101)
  jq -n --arg app "$app" --arg path "$api_path" --argjson id "${url##*/}" --argjson q "$quality" --arg added "$(date -u +%FT%TZ)" '{id:$id,path:$path,quality:$q,customFormatScore:100,sceneName:"Old.Release",dateAdded:$added}+(if $app=="Sonarr" then {seriesId:20} else {movieId:10} end)' >"$output";;
 GET:/release*)
  if [[ "$app" == Radarr ]];then
   jq -n --argjson q "$quality" --argjson bad "$bad" '[{guid:"guid-new",indexerId:1,title:"New.Release",protocol:"usenet",size:100,quality:$q,customFormatScore:(if $bad then 0 else 100 end),approved:false,temporarilyRejected:false,rejections:["Existing file meets cutoff: WEB []"],downloadAllowed:true,movieRequested:true,mappedMovieId:10}]' >"$output"
  else
   jq -n --argjson q "$quality" '[{release:{guid:"guid-new",indexerId:1,title:"New.Release",protocol:"usenet",size:100},parsedInfo:{quality:$q,fullSeason:false},decision:{approved:false,temporarilyRejected:false,rejections:[{reason:"diskCutoffMet",message:"Existing cutoff"}]},customFormatScore:100,downloadAllowed:true,mappedSeriesId:20,mappedEpisodeInfo:[{id:201,seasonNumber:1,episodeNumber:1},{id:202,seasonNumber:1,episodeNumber:2}]}]' >"$output"
  fi;;
 GET:/history*)
  jq -n --arg app "$app" --arg path "$api_path" --argjson grab "$grabbed" --argjson rep "$replacement" '{records:(if $grab then (if $app=="Sonarr" then [201,202] else [10] end)|map(. as $id|{id:$id,eventType:"grabbed",sourceTitle:"New.Release",downloadId:"sab-new",data:{guid:"guid-new"}}+(if $app=="Sonarr" then {episodeId:$id,seriesId:20} else {movieId:$id} end))+ (if $rep then (if $app=="Sonarr" then [201,202] else [10] end)|map(. as $id|{id:($id+1000),eventType:"downloadFolderImported",sourceTitle:"New.Release",downloadId:"sab-new",data:{fileId:"101",importedPath:$path}}+(if $app=="Sonarr" then {episodeId:$id,seriesId:20} else {movieId:$id} end)) else [] end) else [] end)}|.totalRecords=(.records|length)' >"$output";;
 POST:/release) grabbed=true;cp "$payload" "$fixture/payload";printf '{}' >"$output";if [[ "$lost" == true ]];then RECOVERY_HTTP=000;return 28;fi;;
 *) echo "Unexpected request $method $url" >&2;return 1;;esac
}
setup() {
 app="$1";grabbed=false;replacement=false;lost=false;bad=false
 printf '{"schema":1,"workflow":"arr-native","actions":{}}' >"$RECOVERY_FILE";: >"$requests"
 if [[ "$app" == Radarr ]];then relative=movies/Example/film.mkv;else relative=series/Example/film.mkv;fi
 api_path="/data/$relative";printf original-damaged >"$MEDIA_HOST_ROOT/$relative"
 recovery_file_tool identity "$relative" >"$fixture/identity"
 jq -n --arg path "$relative" --argjson now "$(date +%s)" --slurpfile i "$fixture/identity" '{schema:1,toolset:"fixture",files:{($path):{identity:$i[0],issue:{id:"finding",kind:"decode_error",proofVersion:4,origin:"decode",confirmationMethod:"normal-isolated-streams-v1",streamEvidence:[{primary:true,kind:"decode_error",exit:1}],confirmationKey:"fixture",confirmed:true,confirmedRuns:2,lastSeen:$now,identity:$i[0]}}}}' >"$TMP_DIR/state.json"
}
setup Radarr;AUTO_RECOVERY_ENABLED=false;recovery_process;[[ ! -s "$requests" ]]
AUTO_RECOVERY_ENABLED=true
# Old metadata-only evidence must never dispatch a native release grab.
setup Radarr
jq 'del(.files[].issue.proofVersion)' "$TMP_DIR/state.json" >"$fixture/old-state"
mv "$fixture/old-state" "$TMP_DIR/state.json"
recovery_process
[[ ! -s "$requests" ]]
jq -e '.actions|length==0' "$RECOVERY_FILE" >/dev/null
# A claimed decoder failure without independent primary-stream evidence is vetoed.
for veto in 'del(.files[].issue.confirmationMethod)' '.files[].issue.streamEvidence=[{primary:false,kind:"decode_error",exit:1}]' '.files[].issue.proofVersion=2';do
 setup Radarr
 jq "$veto" "$TMP_DIR/state.json" >"$fixture/veto-state";mv "$fixture/veto-state" "$TMP_DIR/state.json"
 recovery_process;[[ ! -s "$requests" ]]
 jq -e '.actions|length==0' "$RECOVERY_FILE" >/dev/null
done
for app in Radarr Sonarr;do
 setup "$app";recovery_process;recovery_valid
 jq -e '.actions|length==1 and all(.[];.status=="downloading" and .downloadId=="sab-new")' "$RECOVERY_FILE" >/dev/null
 [[ $(cat "$MEDIA_HOST_ROOT/$relative") == original-damaged ]]
 ! rg -q '^DELETE|^PUT|POST /command' "$requests"
 [[ $(rg -c '^POST /release' "$requests") == 1 ]]
 recovery_process;[[ $(rg -c '^POST /release' "$requests") == 1 ]]
 replacement=true;printf healthy-replacement-longer >"$MEDIA_HOST_ROOT/$relative"
 recovery_process;jq -e 'all(.actions[];.status=="verifying")' "$RECOVERY_FILE" >/dev/null
 recovery_file_tool identity "$relative" >"$fixture/new-identity"
 jq --arg path "$relative" --slurpfile i "$fixture/new-identity" --argjson now "$(date +%s)" '.files[$path]={identity:$i[0],verifiedAt:$now,verificationPolicy:2,coverage:"all_planned_segments_decoded"}' "$TMP_DIR/state.json" >"$fixture/new";mv "$fixture/new" "$TMP_DIR/state.json"
 recovery_process;jq -e 'all(.actions[];.status=="recovered" and .replacementVerifiedAt>0 and (.events|length)>0)' "$RECOVERY_FILE" >/dev/null
 [[ $(rg -c '^POST /release' "$requests") == 1 && ! -e "$MEDIA_HOST_ROOT/repair_hold" ]]
done
setup Radarr;bad=true;recovery_process
jq -e 'all(.actions[];.status=="blocked")' "$RECOVERY_FILE" >/dev/null
! rg -q '^POST' "$requests";[[ $(cat "$MEDIA_HOST_ROOT/$relative") == original-damaged ]]
setup Radarr;lost=true;recovery_process;recovery_process
[[ $(rg -c '^POST /release' "$requests") == 1 ]]
jq -e 'all(.actions[];.status=="downloading")' "$RECOVERY_FILE" >/dev/null
printf 'Native Radarr/Sonarr exact selection, multi-episode mapping, original retention, policy veto, download correlation, lost-response no replay and full-coverage completion passed\n'
