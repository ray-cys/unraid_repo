"""Exercise actual Arr lifecycle code with isolated native API resources/state."""
from pathlib import Path
import subprocess,tempfile,shutil
R=Path(__file__).resolve().parents[1]
s=(R/'user_script/media_cleanup.sh').read_text();a=s.index('mc_arr() (\n')+len('mc_arr() (\n');b=s.index('\nmain "$@"\n',a)
with tempfile.TemporaryDirectory(prefix='lifecycle-tags.') as d:
 t=Path(d).resolve();(t/'arr.sh').write_text(s[:s.index('\n# MODULE: ARR')]+'\n'+s[a:b])
 code=r'''
set -euo pipefail
source "$2/arr.sh";trap - EXIT INT TERM HUP
STATE_DIR="$2";RUNTIME_DIR="$2";VERIFY_RUNTIME_DIR="$2";WORK_STATE="$2/state"
RUN_AT=2026-11-26T12:00:00Z;DRY_RUN=false;ARR_RETIREMENT_DAYS=30;ARR_RETIREMENT_WARNING_DAYS=7
RETIREMENTS_CANCELLED=0;RETIREMENTS_STARTED=0;ARR_REMOVALS=0;CONFIRMATION_RUNS=2;REQUIRE_DELETE_HISTORY_EVENT=false
RADARR_RETIRE_FULLY_DELETED_MOVIES=true;RADARR_QUEUE_AVAILABLE=true;QUARANTINE_KODI_SIDECARS=false
TAG_CATALOG='[{"id":1,"label":"plex-deleted"},{"id":2,"label":"retirement-pending"},{"id":3,"label":"plex-deleted-series"},{"id":4,"label":"plex-deleted-season"},{"id":9,"label":"keep-in-arr"},{"id":99,"label":"custom"}]'
log(){ :; };queue_action_notification(){ printf '%s\n' "$*" >>"$STATE_DIR/notifications"; }
queue_stateful_resolution_notification(){ :; };queue_stateful_attention_notification(){ :; }
radarr_queue_has_movie(){ return 1; };age_at_least_days(){ return 1; }
api_get_json_uncached(){ cat "$STATE_DIR/native"; };api_get_json(){ api_get_json_uncached "$@"; }
api_put_json(){ [[ "${fail:-false}" != true ]] || return 1;printf '%s' "$2" >"$STATE_DIR/native";printf '%s\n' "$1" >>"$STATE_DIR/writes"; }
api_delete(){ printf 'Unexpected deletion\n' >&2;return 1; }
run_movie(){ cp "$STATE_DIR/native" "$STATE_DIR/copy";jq '[.]' "$STATE_DIR/copy" >"$STATE_DIR/movies";radarr_process_retirements "$STATE_DIR/movies"; }
ARR_NAME=Radarr
printf '{"movies":{"1":{"everHadFile":true,"missingRuns":2,"lastPlexDeletedTagAppliedAt":"2026-11-01"}},"movieRetirements":{"1":{"startedAt":"2026-11-01T00:00:00Z"}}}' >"$WORK_STATE"
printf '{"id":1,"title":"Movie","year":2026,"hasFile":false,"monitored":false,"tags":[1,2,99]}' >"$STATE_DIR/native"
run_movie
jq -e '.tags==[2,99] and .monitored==false' "$STATE_DIR/native" >/dev/null
jq -e '.movieRetirements["1"].startedAt=="2026-11-01T00:00:00Z"' "$WORK_STATE" >/dev/null
count=$(wc -l <"$STATE_DIR/writes");run_movie;[[ $(wc -l <"$STATE_DIR/writes") == "$count" ]]
[[ $(radarr_movies_missing_tag '[{"id":1,"tags":[2,99]}]' 1) == '[]' ]]
[[ $(radarr_movies_missing_tag '[{"id":1,"tags":[2,99]}]' '') == '[]' ]]
# Restoring monitoring cancels retirement but retains the missing-media marker.
jq '.monitored=true' "$STATE_DIR/native" >"$STATE_DIR/next";mv "$STATE_DIR/next" "$STATE_DIR/native"
run_movie
jq -e '.tags==[1,99] and .monitored==true' "$STATE_DIR/native" >/dev/null
jq -e '.movieRetirements["1"].startedAt==null and .movieRetirements["1"].suppressed==true and .movies["1"].retirementHistory[0].startedAt=="2026-11-01T00:00:00Z"' "$WORK_STATE" >/dev/null
# Returned media clears only lifecycle tags; custom tags/monitoring remain.
jq '.hasFile=true|.tags=[1,2,99]' "$STATE_DIR/native" >"$STATE_DIR/next";mv "$STATE_DIR/next" "$STATE_DIR/native"
run_movie
jq -e '.tags==[99] and .hasFile and .monitored' "$STATE_DIR/native" >/dev/null
# Starting a new hold changes the visible stage atomically in one resource PUT.
jq '.movieRetirements={}' "$WORK_STATE" >"$STATE_DIR/next";mv "$STATE_DIR/next" "$WORK_STATE"
printf '{"id":1,"title":"Movie","year":2026,"hasFile":false,"monitored":false,"tags":[1,99]}' >"$STATE_DIR/native"
count=$(wc -l <"$STATE_DIR/writes");run_movie
[[ $(wc -l <"$STATE_DIR/writes") == $((count+1)) ]]
jq -e '.tags==[2,99]' "$STATE_DIR/native" >/dev/null
jq -e --arg now "$RUN_AT" '.movieRetirements["1"].startedAt==$now' "$WORK_STATE" >/dev/null
# Uncertain writes do not record a successful transition.
cp "$WORK_STATE" "$STATE_DIR/saved";fail=true
if arr_sync_lifecycle_tags movie 1 '["plex-deleted"]' '["plex-deleted","retirement-pending"]' test;then exit 1;fi
cmp "$WORK_STATE" "$STATE_DIR/saved";fail=false
# Dry-run performs neither API changes nor state advancement.
DRY_RUN=true;arr_sync_lifecycle_tags movie 1 '[]' '["plex-deleted","retirement-pending"]' preview;cmp "$WORK_STATE" "$STATE_DIR/saved";DRY_RUN=false
printf 'Radarr: exclusive pending tag, preserved timers, no re-tag churn, cancellation, restore, failure and preview passed\n'
ARR_NAME=Sonarr
printf '{"episodes":{"11":{"seriesId":10,"seasonNumber":1,"everHadFile":true,"missingRuns":2},"12":{"seriesId":10,"seasonNumber":2,"everHadFile":true,"missingRuns":0}},"seasonActions":{"10:1":{"seriesId":10,"seasonNumber":1,"lastUnmonitoredAt":"2026-11-01"}},"seriesActions":{},"seriesRetirements":{}}' >"$WORK_STATE"
printf '[{"id":11,"seriesId":10,"seasonNumber":1,"hasFile":false},{"id":12,"seriesId":10,"seasonNumber":2,"hasFile":true}]' >"$STATE_DIR/episodes"
printf '{"id":10,"title":"Series","monitored":true,"seasons":[{"seasonNumber":1,"monitored":false},{"seasonNumber":2,"monitored":true}],"tags":[2,3,4,99]}' >"$STATE_DIR/native"
sonarr_reconcile_lifecycle_tags 10 "$STATE_DIR/episodes"
jq -e '.tags==[4,99] and .monitored and .seasons[1].monitored' "$STATE_DIR/native" >/dev/null
# Restored season clears its marker without changing season/series monitoring.
jq '.[0].hasFile=true' "$STATE_DIR/episodes" >"$STATE_DIR/next";mv "$STATE_DIR/next" "$STATE_DIR/episodes"
sonarr_reconcile_lifecycle_tags 10 "$STATE_DIR/episodes"
jq -e '.tags==[99] and .monitored and .seasons[1].monitored' "$STATE_DIR/native" >/dev/null
# Previously dual-tagged holds migrate without changing their original date.
jq '.seriesRetirements["10"]={startedAt:"2026-11-01T00:00:00Z"}' "$WORK_STATE" >"$STATE_DIR/next";mv "$STATE_DIR/next" "$WORK_STATE"
jq '.tags=[2,3,4,99]|.monitored=false' "$STATE_DIR/native" >"$STATE_DIR/next";mv "$STATE_DIR/next" "$STATE_DIR/native"
sonarr_reconcile_lifecycle_tags 10 "$STATE_DIR/episodes"
jq -e '.tags==[2,99] and .monitored==false' "$STATE_DIR/native" >/dev/null
jq -e '.seriesRetirements["10"].startedAt=="2026-11-01T00:00:00Z"' "$WORK_STATE" >/dev/null
# Existing historic hold date survives a return/cancellation before first migration.
sonarr_clear_retirement 10
jq -e '.seriesActions["10"].retirementHistory[0].startedAt=="2026-11-01T00:00:00Z"' "$WORK_STATE" >/dev/null
# No script-state provenance: matching manually assigned labels stay untouched.
printf '{"episodes":{},"seriesActions":{},"seasonActions":{},"seriesRetirements":{}}' >"$WORK_STATE"
printf '{"id":10,"title":"Manual","tags":[3,99]}' >"$STATE_DIR/native"
count=$(wc -l <"$STATE_DIR/writes");sonarr_reconcile_lifecycle_tags 10 "$STATE_DIR/episodes";[[ $(wc -l <"$STATE_DIR/writes") == "$count" ]]
# Initial full-series retirement has only the pending stage and unmonitors
# every hierarchy level; completion removes the Arr record, never library files.
SONARR_RETIRE_FULLY_DELETED_SERIES=true;SONARR_RETIRE_CONTINUING_SERIES=true;SONARR_QUEUE_AVAILABLE=true
sonarr_queue_has_series(){ return 1; }
printf '{"episodes":{"11":{"seriesId":10,"seasonNumber":1,"everHadFile":true,"missingRuns":2},"12":{"seriesId":10,"seasonNumber":2,"everHadFile":true,"missingRuns":2}},"seasonActions":{},"seriesActions":{},"seriesRetirements":{}}' >"$WORK_STATE"
printf '[{"id":11,"seriesId":10,"seasonNumber":1,"episodeNumber":1,"monitored":false,"hasFile":false},{"id":12,"seriesId":10,"seasonNumber":2,"episodeNumber":1,"monitored":false,"hasFile":false}]' >"$STATE_DIR/episodes"
printf '{"id":10,"title":"Whole series","status":"ended","monitored":true,"seasons":[{"seasonNumber":1,"monitored":true},{"seasonNumber":2,"monitored":false}],"tags":[3,4,99]}' >"$STATE_DIR/native"
api_put_json(){
 [[ "${fail:-false}" != true ]] || return 1
 if [[ "$1" == /api/v3/series/* || "$1" == /api/v3/movie/* ]];then printf '%s' "$2" >"$STATE_DIR/native";fi
 printf '%s\n' "$1" >>"$STATE_DIR/writes"
}
rc=0;sonarr_process_full_retirement 10 Whole "$(cat "$STATE_DIR/native")" "$STATE_DIR/episodes" || rc=$?;[[ "$rc" == 10 ]]
jq -e '.tags==[2,99] and .monitored==false and all(.seasons[];.monitored==false)' "$STATE_DIR/native" >/dev/null
jq -e --arg now "$RUN_AT" '.seriesRetirements["10"].startedAt==$now' "$WORK_STATE" >/dev/null
age_at_least_days(){ return 0; }
api_delete(){ printf '%s\n' "$1" >>"$STATE_DIR/deletes"; }
rc=0;sonarr_process_full_retirement 10 Whole "$(cat "$STATE_DIR/native")" "$STATE_DIR/episodes" || rc=$?;[[ "$rc" == 10 ]]
grep -q '/series/10?deleteFiles=false&addImportListExclusion=true' "$STATE_DIR/deletes"
sonarr_reconcile_lifecycle_tags 10 "$STATE_DIR/episodes"
ARR_NAME=Radarr
printf '{"movies":{"1":{"everHadFile":true,"missingRuns":2,"lastPlexDeletedTagAppliedAt":"2026-11-01"}},"movieRetirements":{"1":{"startedAt":"2026-11-01T00:00:00Z"}}}' >"$WORK_STATE"
printf '{"id":1,"title":"Movie","year":2026,"hasFile":false,"monitored":false,"tags":[2,99]}' >"$STATE_DIR/native"
run_movie
grep -q '/movie/1?deleteFiles=false&addImportExclusion=true' "$STATE_DIR/deletes"
printf 'Completed holds remove native movie/whole-series records with file deletion disabled and import-list exclusion requested\n'

printf 'Sonarr: partial-season safety, restored markers, legacy pending migration, dates and unrelated/manual tags passed\n'
'''
 result=subprocess.run([shutil.which('bash'),'-c',code,'fixture',str(R),str(t)],capture_output=True,text=True)
 print(result.stdout,end='');print(result.stderr,end='');assert result.returncode==0, f'Lifecycle fixtures failed: {result.returncode}'
