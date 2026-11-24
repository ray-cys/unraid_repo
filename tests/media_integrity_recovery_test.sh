#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/media_integrity_audit.sh"
fixture=$(mktemp -d /tmp/media-integrity-recovery.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
STATE_DIR="$fixture/state"; TMP_DIR="$fixture/tmp"; MEDIA_HOST_ROOT="$fixture/media"
mkdir -p "$MEDIA_HOST_ROOT/arr_bin" "$STATE_DIR" "$TMP_DIR" "$MEDIA_HOST_ROOT/movies/Example" "$MEDIA_HOST_ROOT/series/Example"
RECOVERY_FILE="$STATE_DIR/recovery.json";STATE_EXPORT_LOCK="$fixture/export.lock";ARR_BACKUP_GATE="$fixture/gate.lock"
SONARR_API_KEY=fixture RADARR_API_KEY=fixture
workload_guard() { return 0; };recovery_window_open() { return 0; };recovery_new_window_open() { return 0; }
log() { :; };recovery_runtime_matches() { return 0; };recovery_platform_ready() { return 0; };recovery_capacity_ready() { return 0; }
# Fixture-only filesystem transport; source files live under mktemp, never media.
recovery_file_tool() {
 python3 -c '
import json,os,sys
root,mode,rel,dest=sys.argv[1:];p=os.path.join(root,rel)
s=os.stat(p);i=[str(v) for v in (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)]
if mode=="info":print(json.dumps({"identity":i,"links":s.st_nlink}));sys.exit(0)
if mode in ("move","handoff"):
 request=json.load(sys.stdin);expected=request["identity"] if mode=="handoff" else request
 assert i==expected
 d=os.path.join(root,dest);os.makedirs(os.path.dirname(d),exist_ok=True)
 if os.path.lexists(d):raise FileExistsError(d)
 if mode=="handoff":
  assert s.st_nlink==1
  os.utime(p,ns=(s.st_atime_ns,request["retentionEpoch"]*1000000000))
 os.rename(p,d);s=os.stat(d);i=[str(v) for v in (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)]
print(json.dumps(i))
' "$MEDIA_HOST_ROOT" "$1" "$2" "${3:-}" || return $?
 [[ "$1" != handoff || "${handoff_timeout:-false}" != true ]] || return 124
}
requests="$fixture/requests";: >"$requests"
native_unmonitor=false;monitor_timeout=false;monitor_restored=false;handoff_timeout=false
app=Radarr;replacement=false;deleted=false;post_timeout=false;wrong_path=false;monitored=true;busy=false
recovery_api() {
 local method="$1" endpoint="$2" output="$3" payload="${4:-}"
 printf '%s %s\n' "$method" "$endpoint" >>"$requests"
 RECOVERY_HTTP=200
 case "$method:$endpoint" in
  GET:/config/mediamanagement|GET:/settings/mediamanagement) printf '{"autoUnmonitorPreviouslyDownloadedEpisodes":true,"autoUnmonitorPreviouslyDownloadedMovies":true,"recycleBin":"/data/arr_bin/","recycleBinCleanupDays":2}' >"$output";;
  GET:/system/status) jq -n --arg app "$app" '{appName:$app}' >"$output";;
  GET:/series/20) printf '{"id":20,"monitored":true}' >"$output";;
  PUT:/episode/monitor|PUT:/movie/10) if [[ "$monitor_timeout" == true ]]; then RECOVERY_HTTP=000;return 28;fi;monitor_restored=true;printf '{}' >"$output";;
  GET:/health|GET:/command) printf '[]' >"$output";;
  GET:/queue*) if [[ "$busy" == true ]]; then printf '{"totalRecords":1,"records":[{"movieId":10,"seriesId":20}]}' >"$output";else printf '{"totalRecords":0,"records":[]}' >"$output";fi;;
  GET:/movie) jq -n --argjson monitored "$monitored" --argjson wrong "$wrong_path" '[{id:10,monitored:$monitored,hasFile:true,movieFileId:100,movieFile:{id:100,path:(if $wrong then "/data/movies/Other/film.mkv" else "/data/movies/Example/film.mkv" end)}}]' >"$output";;
  GET:/moviefile/100|GET:/episodefile/100) if [[ "$deleted" == true ]]; then RECOVERY_HTTP=404;printf '{}' >"$output";else jq -n --arg path "$api_path" '{id:100,path:$path}' >"$output";fi;;
  DELETE:/moviefile/100|DELETE:/episodefile/100) deleted=true;printf '{}' >"$output";;
  GET:/movie/10) if [[ "$replacement" == true ]]; then printf '{"id":10,"monitored":true,"hasFile":true,"movieFileId":101}' >"$output";else local watch=true;[[ "$native_unmonitor" != true || "$monitor_restored" == true ]] || watch=false;jq -n --argjson watch "$watch" '{id:10,monitored:$watch,hasFile:false,movieFileId:0}' >"$output";fi;;
  GET:/moviefile/101) jq -n --arg added "$(date -u +%FT%TZ)" '{id:101,movieId:10,path:"/data/movies/Example/film.mkv",dateAdded:$added}' >"$output";;
  GET:/series) printf '[{"id":20,"path":"/data/series/Example","monitored":true,"seasons":[{"seasonNumber":1,"monitored":true}]}]' >"$output";;
  GET:/episodefile?seriesId=20) printf '[{"id":100,"seriesId":20,"path":"/data/series/Example/film.mkv"}]' >"$output";;
  GET:/episode?seriesId=20) printf '[{"id":201,"seriesId":20,"seasonNumber":1,"monitored":true,"hasFile":true,"episodeFileId":100},{"id":202,"seriesId":20,"seasonNumber":1,"monitored":true,"hasFile":true,"episodeFileId":100}]' >"$output";;
  GET:/episode/201|GET:/episode/202) local target=${endpoint##*/} watch=true;[[ "$native_unmonitor" != true || "$monitor_restored" == true ]] || watch=false;jq -n --argjson id "$target" --argjson watch "$watch" '{id:$id,seriesId:20,monitored:$watch,hasFile:false,episodeFileId:0}' >"$output";;
  POST:/command) cp "$payload" "$fixture/submitted";if [[ "$post_timeout" == true ]]; then RECOVERY_HTTP=000;return 28;fi;printf '{"id":61}' >"$output";;
  GET:/command/61) jq '{id:61,name:.name,status:"completed",body:.}' "$fixture/submitted" >"$output";;
  *) printf 'Unexpected fixture request: %s %s\n' "$method" "$endpoint" >&2;return 1;;
 esac
}
setup() {
 app="$1";handoff_timeout=false;native_unmonitor=false;monitor_timeout=false;monitor_restored=false;replacement=false;deleted=false;post_timeout=false;wrong_path=false;monitored=true;busy=false
 rm -f "$RECOVERY_FILE";rm -rf "$MEDIA_HOST_ROOT/repair_hold"
 if [[ "$app" == Radarr ]]; then relative=movies/Example/film.mkv;else relative=series/Example/film.mkv;fi
 api_path="/data/$relative";printf 'damaged fixture' >"$MEDIA_HOST_ROOT/$relative"
 recovery_file_tool identity "$relative" >"$fixture/identity"
 jq -n --arg path "$relative" --argjson now "$(date +%s)" --slurpfile identity "$fixture/identity" '{schema:1,files:{($path):{identity:$identity[0],issue:{kind:"decode_error",confirmed:true,confirmedRuns:2,lastSeen:$now,identity:$identity[0],id:"finding"}}}}' >"$TMP_DIR/state.json"
 : >"$requests"
}
setup Radarr
AUTO_RECOVERY_ENABLED=false
recovery_process
[[ ! -e "$RECOVERY_FILE" && ! -s "$requests" && -f "$MEDIA_HOST_ROOT/$relative" ]]
AUTO_RECOVERY_ENABLED=true
jq '.files[].issue.confirmedRuns=1' "$TMP_DIR/state.json" >"$fixture/new";mv "$fixture/new" "$TMP_DIR/state.json"
recovery_process
[[ ! -s "$requests" && -f "$MEDIA_HOST_ROOT/$relative" ]]
setup Radarr;monitored=false;recovery_process
[[ -f "$MEDIA_HOST_ROOT/$relative" && $(grep -c '^DELETE\|^POST' "$requests" || true) == 0 ]]
setup Radarr;wrong_path=true;recovery_process
[[ -f "$MEDIA_HOST_ROOT/$relative" && $(grep -c '^DELETE\|^POST' "$requests" || true) == 0 ]]
setup Radarr;busy=true;recovery_process
[[ -f "$MEDIA_HOST_ROOT/$relative" && $(grep -c '^DELETE\|^POST' "$requests" || true) == 0 ]]
setup Radarr
recovery_process
recovery_valid
jq -e '.actions|length==1 and all(.[]; .status=="search_submitted" and .commandId==61 and .targets==[10])' "$RECOVERY_FILE" >/dev/null
[[ ! -e "$MEDIA_HOST_ROOT/$relative" ]]
id=$(jq -r '.actions|keys[0]' "$RECOVERY_FILE")
[[ $(cat "$MEDIA_HOST_ROOT/repair_hold/$id/film.mkv") == 'damaged fixture' ]]
recovery_process
[[ $(grep -c '^DELETE' "$requests") == 1 && $(grep -c '^POST' "$requests") == 1 ]]
# Import/file-ID change alone never closes a recovery. Require actual later
# complete audit coverage for the current filesystem identity.
replacement=true;printf 'healthy replacement fixture' >"$MEDIA_HOST_ROOT/$relative"
recovery_file_tool identity "$relative" >"$fixture/replacement-identity"
jq --arg path "$relative" --slurpfile identity "$fixture/replacement-identity" '.files[$path]={identity:$identity[0],verifiedAt:0}' "$TMP_DIR/state.json" >"$fixture/new";mv "$fixture/new" "$TMP_DIR/state.json"
recovery_process
jq -e '.actions|all(.[]; .status=="search_submitted")' "$RECOVERY_FILE" >/dev/null
jq --arg path "$relative" --argjson now "$(date +%s)" '.files[$path].verifiedAt=$now' "$TMP_DIR/state.json" >"$fixture/new";mv "$fixture/new" "$TMP_DIR/state.json"
recovery_process
jq -e '.actions|all(.[]; .status=="handed_off" and .replacementVerifiedAt>0 and .binCleanupDays==2)' "$RECOVERY_FILE" >/dev/null
bin=$(jq -r --arg id "$id" '.actions[$id].binRelative' "$RECOVERY_FILE")
[[ ! -e "$MEDIA_HOST_ROOT/repair_hold/$id/film.mkv" && -f "$MEDIA_HOST_ROOT/$bin" ]]
[[ $(cat "$MEDIA_HOST_ROOT/$relative") == 'healthy replacement fixture' ]]
[[ $(grep -c '^DELETE' "$requests") == 1 && $(grep -c '^POST' "$requests") == 1 ]]
[[ $(stat -c %Y "$MEDIA_HOST_ROOT/$bin") -ge $(jq -r --arg id "$id" '.actions[$id].retentionEpoch' "$RECOVERY_FILE") ]]
rm "$MEDIA_HOST_ROOT/$bin"
recovery_process
jq -e '.actions|all(.[]; .status=="bin_removed")' "$RECOVERY_FILE" >/dev/null
# The handoff must never change a linked downloader/quarantine copy's mtime.
prepare_verified_movie() {
 setup Radarr;recovery_process
 id=$(jq -r '.actions|keys[0]' "$RECOVERY_FILE")
 replacement=true;printf 'healthy replacement fixture' >"$MEDIA_HOST_ROOT/$relative"
 recovery_file_tool identity "$relative" >"$fixture/replacement-identity"
 jq --arg path "$relative" --argjson now "$(date +%s)" --slurpfile identity "$fixture/replacement-identity" '.files[$path]={identity:$identity[0],verifiedAt:$now}' "$TMP_DIR/state.json" >"$fixture/new";mv "$fixture/new" "$TMP_DIR/state.json"
}
prepare_verified_movie
ln "$MEDIA_HOST_ROOT/repair_hold/$id/film.mkv" "$fixture/downloader-link"
mtime=$(stat -c %Y "$fixture/downloader-link")
recovery_process
jq -e '.actions|all(.[]; .status=="handoff_pending" and .replacementVerifiedAt>0)' "$RECOVERY_FILE" >/dev/null
[[ $(stat -c %Y "$fixture/downloader-link") == "$mtime" ]]
rm "$fixture/downloader-link"
recovery_process
jq -e '.actions|all(.[]; .status=="handed_off")' "$RECOVERY_FILE" >/dev/null
# A destination collision must not overwrite another bin file or touch the library.
prepare_verified_movie
collision="$MEDIA_HOST_ROOT/arr_bin/media_audit/radarr/$id/film.mkv"
mkdir -p "${collision%/*}";printf sentinel >"$collision"
if recovery_process;then echo 'Bin collision accepted' >&2;exit 1;fi
[[ $(cat "$collision") == sentinel && -f "$MEDIA_HOST_ROOT/repair_hold/$id/film.mkv" ]]
[[ $(cat "$MEDIA_HOST_ROOT/$relative") == 'healthy replacement fixture' ]]
rm "$collision"
# Lost response after a completed metadata-only move reconciles the exact
# original identity/stamp; it never moves or deletes the current replacement.
prepare_verified_movie;handoff_timeout=true
if recovery_process;then echo 'Uncertain handoff accepted' >&2;exit 1;fi
jq -e '.actions|all(.[]; .status=="handoff_intent")' "$RECOVERY_FILE" >/dev/null
handoff_timeout=false;recovery_process
jq -e '.actions|all(.[]; .status=="handed_off")' "$RECOVERY_FILE" >/dev/null
[[ $(grep -c '^DELETE' "$requests") == 1 && $(grep -c '^POST' "$requests") == 1 ]]
[[ $(cat "$MEDIA_HOST_ROOT/$relative") == 'healthy replacement fixture' ]]
setup Sonarr
recovery_process
jq -e '.actions|all(.[]; .status=="search_submitted" and .targets==[201,202])' "$RECOVERY_FILE" >/dev/null
jq -e '.name=="EpisodeSearch" and .episodeIds==[201,202]' "$fixture/submitted" >/dev/null
# Native unmonitor-on-delete must not strand a previously monitored repair.
setup Radarr;native_unmonitor=true
recovery_process
[[ $(grep -c '^PUT /movie/10' "$requests") == 1 ]]
jq -e '.actions|all(.[]; .status=="search_submitted")' "$RECOVERY_FILE" >/dev/null
setup Sonarr;native_unmonitor=true
recovery_process
[[ $(grep -c '^PUT /episode/monitor' "$requests") == 1 ]]
jq -e '.actions|all(.[]; .status=="search_submitted")' "$RECOVERY_FILE" >/dev/null
setup Radarr;native_unmonitor=true;monitor_timeout=true
if recovery_process; then echo 'Lost monitoring response accepted' >&2;exit 1;fi
recovery_process || true
[[ $(grep -c '^PUT /movie/10' "$requests") == 1 && $(grep -c '^POST' "$requests" || true) == 0 ]]
jq -e '.actions|all(.[]; .status=="review")' "$RECOVERY_FILE" >/dev/null
setup Radarr;post_timeout=true
if recovery_process; then echo 'Lost response accepted' >&2;exit 1;fi
recovery_process || true
[[ $(grep -c '^POST' "$requests") == 1 ]]
jq -e '.actions|all(.[]; .status=="review")' "$RECOVERY_FILE" >/dev/null
printf 'Disabled recovery, independent-run gate, ownership/monitoring/work vetoes, preserved original, exact Radarr/Sonarr multi-episode search and no replay after lost response passed\n'
