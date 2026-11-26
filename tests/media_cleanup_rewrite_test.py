"""Performance rewrite parity/fault fixtures. No live paths, API writes or mail."""
import json, os, shutil, subprocess, tempfile
from pathlib import Path
R=Path(__file__).resolve().parents[1]
BASH=shutil.which('bash')
new=(R/'user_script/media_cleanup.sh').read_text()
# Frozen pre-rewrite implementation is the action-plan oracle.
old=subprocess.check_output(['git','show','3873f50:user_script/media_cleanup.sh'],cwd=R,text=True)
def extract(s):
 a=s.index('mc_arr() (\n')+len('mc_arr() (\n');b=s.index('\nmain "$@"\n',a)
 return s[:s.index('\n# MODULE: ARR')]+'\n'+s[a:b]
with tempfile.TemporaryDirectory(prefix='cleanup-rewrite.') as folder:
 t=Path(folder).resolve()
 for label,s in [('old',old),('new',new)]: (t/(label+'.sh')).write_text(extract(s))
 def run(code,*args):
  subprocess.run([BASH,'-eu','-c',code,'fixture',str(t/'new.sh'),str(t),*args],check=True)
 run(r'''
 source "$1"
 VERIFY_RUNTIME_DIR="$2";MC_TMP="$2";APP_CONTEXT=SONARR;WORK_STATE="$2/shard-state.json";RUN_AT=fixed;SERIES_ROOT="$2"
 printf '{"episodes":{"11":{"seriesId":1,"everHadFile":true},"21":{"seriesId":2,"everHadFile":true}},"sidecarManifests":{"1":{"keep":1},"2":{"keep":2}},"seasonActions":{"1:1":{"seriesId":1},"2:2":{"seriesId":2}},"seriesRetirements":{"1":{"keep":1}},"unknown":{"keep":true}}' >"$WORK_STATE"
 cp "$WORK_STATE" "$2/shard-original"
 mc_sonarr_shards_begin;mc_sonarr_select_shard 1
 jq 'del(.sidecarManifests["1"],.seriesRetirements["1"])|.episodes["11"].missingRuns=2|.seriesActions["1"]={seriesId:1}' "$WORK_STATE" >"$WORK_STATE.next";mv "$WORK_STATE.next" "$WORK_STATE"
 [[ $(jq '.episodes|length' "$WORK_STATE") == 1 ]]
 mc_sonarr_shards_finish
 jq -e '.episodes["21"].seriesId==2 and .episodes["11"].missingRuns==2 and .sidecarManifests["1"]==null and .sidecarManifests["2"].keep==2 and .seriesRetirements["1"]==null and .seasonActions["2:2"].seriesId==2 and .unknown.keep' "$WORK_STATE" >/dev/null
 printf '[{"id":1},{"id":1}]' >"$2/bad-snapshot"
 if mc_index_snapshot "$2/bad-snapshot" "$2/index";then exit 1;fi
 printf '[{"id":3,"episodeFileId":30,"downloadId":"ABC"}]' >"$2/snapshot"
 mc_index_snapshot "$2/snapshot" "$2/index"
 jq -e '.byId["3"].id==3 and .byFileId["30"]==[3] and .byDownloadId.abc==[3]' "$2/index" >/dev/null
 ''')
 run(r'''
 source "$1"
 VERIFY_RUNTIME_DIR="$2/cache";mkdir "$VERIFY_RUNTIME_DIR";MC_TMP="$VERIFY_RUNTIME_DIR";APP_CONTEXT=SONARR;MC_POLICY_FINGERPRINT=policy
 WORK_STATE="$VERIFY_RUNTIME_DIR/state";RUN_AT=fixed;MC_NEXT_CURSOR=0;MC_ROTATING_IDS="$VERIFY_RUNTIME_DIR/rotate";: >"$MC_ROTATING_IDS"
 mkdir "$VERIFY_RUNTIME_DIR/media";printf metadata >"$VERIFY_RUNTIME_DIR/media/poster.jpg"
 printf '{}' >"$WORK_STATE"
 log(){ :; }
 mc_capture_sidecars sonarr "$VERIFY_RUNTIME_DIR/media" "$VERIFY_RUNTIME_DIR" '["media.mkv"]' 1 "$VERIFY_RUNTIME_DIR/captured"
 jq -n --slurpfile files "$VERIFY_RUNTIME_DIR/captured" '{sidecarManifests:{"1":{files:$files[0]}}}' >"$WORK_STATE"
 mc_performance_finish
 capture_kodi_sidecars(){ printf called >>"$VERIFY_RUNTIME_DIR/hash-calls";capture_kodi_sidecars_core "$@"; }
 mc_capture_sidecars sonarr "$VERIFY_RUNTIME_DIR/media" "$VERIFY_RUNTIME_DIR" '["media.mkv"]' 1 "$VERIFY_RUNTIME_DIR/reused"
 [[ ! -s "$VERIFY_RUNTIME_DIR/reused" && ! -e "$VERIFY_RUNTIME_DIR/hash-calls" ]]
 printf new >"$VERIFY_RUNTIME_DIR/media/banner.jpg"
 mc_capture_sidecars sonarr "$VERIFY_RUNTIME_DIR/media" "$VERIFY_RUNTIME_DIR" '["media.mkv"]' 1 "$VERIFY_RUNTIME_DIR/changed"
 [[ -e "$VERIFY_RUNTIME_DIR/hash-calls" && -s "$VERIFY_RUNTIME_DIR/changed" ]]
 rm "$VERIFY_RUNTIME_DIR/hash-calls"
 printf 1 >"$MC_ROTATING_IDS"
 mc_capture_sidecars sonarr "$VERIFY_RUNTIME_DIR/media" "$VERIFY_RUNTIME_DIR" '["media.mkv"]' 1 "$VERIFY_RUNTIME_DIR/rotated"
 [[ -e "$VERIFY_RUNTIME_DIR/hash-calls" ]]
 # In-flight edit must invalidate reusable evidence even after capture succeeds.
 capture_kodi_sidecars(){ capture_kodi_sidecars_core "$@";printf changed >"$VERIFY_RUNTIME_DIR/media/poster.jpg"; }
 mc_capture_sidecars sonarr "$VERIFY_RUNTIME_DIR/media" "$VERIFY_RUNTIME_DIR" '["media.mkv"]' 1 "$VERIFY_RUNTIME_DIR/race"
 tail -n 1 "$VERIFY_RUNTIME_DIR/$APP_CONTEXT.sidecar-hints.jsonl"|jq -e '.value.fingerprint==""' >/dev/null
 ''')
 run(r'''
 source "$1"
 MC_TMP="$2/pool";mkdir "$MC_TMP";MC_READ_CACHE="$MC_TMP/cache";mkdir "$MC_READ_CACHE";APP_CONTEXT=SONARR
 MC_GUARDS_ACTIVE=true;MC_DEADLINE=$(( $(date +%s)+10 ));MC_ARR_MAX_READ_REQUESTS=3
 api_get_json_uncached(){ mc_read_reserve;touch "$MC_TMP/active-$BASHPID";[[ $(find "$MC_TMP" -name 'active-*'|wc -l) -le 2 ]] || return 1;printf started >>"$MC_TMP/start";sleep .2;rm "$MC_TMP/active-$BASHPID";printf '[{"id":1}]'; }
 mc_prefetch_pair /one /two
 [[ $(cat "$MC_TMP/arr-SONARR.read-count") == 2 ]]
 [[ -s $(mc_get_cache_path /one) && -s $(mc_get_cache_path /two) ]]
 if mc_prefetch_pair /three /four /five;then exit 1;fi
 [[ $(cat "$MC_TMP/arr-SONARR.read-count") == 2 ]]
 api_get_json_uncached(){ mc_read_reserve;printf '[{"id":';return 1; }
 mc_prefetch_pair /partial
 [[ ! -e $(mc_get_cache_path /partial) ]]
 if mc_read_reserve;then exit 1;fi
 [[ -f "$MC_TMP/deferred-SONARR" ]]
 rm "$MC_TMP/deferred-SONARR";MC_DEADLINE=$(( $(date +%s)+1 ))
 api_get_json_uncached(){ sleep 10;printf '[{"id":2}]'; }
 mc_prefetch_pair /expired
 [[ ! -e $(mc_get_cache_path /expired) ]]
 ''')
 run(r'''
 source "$1"
 MC_TMP="$2/invalidation";mkdir "$MC_TMP";MC_READ_CACHE="$MC_TMP/cache";mkdir "$MC_READ_CACHE";APP_CONTEXT=RADARR
 api_get_json_uncached(){ printf 'fresh'; }
 printf '[{"id":1}]' >"$(mc_get_cache_path /api/v3/movie)"
 arr_api_request_core(){ printf verified; }
 api_put_json /api/v3/movie/1 '{}' >/dev/null
 [[ ! -e $(mc_get_cache_path /api/v3/movie) ]]
 [[ $(api_get_json /api/v3/movie) == fresh ]]
 # Queue pagination changes cannot grant absence proof.
 RUNTIME_DIR="$MC_TMP";ARR_TEMP_PREFIX=radarr;VERIFY_RUNTIME_DIR="$MC_TMP";RADARR_QUEUE_AVAILABLE=false
 api_get_json(){ case "$1" in *page=1*) printf '{"records":[{"id":1,"movieId":1}],"totalRecords":2}';;*) printf '{"records":[{"id":2,"movieId":2}],"totalRecords":3}';;esac; }
 log(){ :; }
 if load_arr_queue radarr;then exit 1;fi
 [[ "$RADARR_QUEUE_AVAILABLE" == false ]]
 ''')
 # Measure full-state processing eliminated by per-series observation shards.
 seed={'episodes':{str(series*1000+e):{'seriesId':series,'everHadFile':True} for series in range(1,11) for e in range(1,201)},'sidecarManifests':{},'sidecarCleanupActions':{},'seriesRetirements':{},'seriesActions':{},'seasonActions':{},'unknown':{'keep':True}}
 for sid in range(1,11):
  (t/f'episodes-{sid}').write_text(json.dumps([{'id':sid*1000+e,'seriesId':sid,'hasFile':True,'episodeFileId':sid*1000+e} for e in range(1,201)]))
 benchmark=r'''
 source "$1"
 WORK_STATE="$2/bench-$3.json";VERIFY_RUNTIME_DIR="$2/bench-$3";mkdir "$VERIFY_RUNTIME_DIR";MC_TMP="$VERIFY_RUNTIME_DIR";APP_CONTEXT=SONARR;RUN_AT=fixed;SERIES_ROOT="$2"
 : >"$VERIFY_RUNTIME_DIR/sidecars";total=0
 if [[ "$3" == new ]];then mc_sonarr_shards_begin;fi
 for sid in {1..10};do
  if [[ "$3" == new ]];then mc_sonarr_select_shard "$sid";fi
  total=$((total+$(stat -c %s "$WORK_STATE")))
  sonarr_apply_snapshot "$sid" Fixture "$2/episodes-$sid" "$2" "$VERIFY_RUNTIME_DIR/sidecars"
 done
 if [[ "$3" == new ]];then mc_sonarr_shards_finish;fi
 jq 'del(.performance)' "$WORK_STATE" >"$2/bench-$3-result"
 printf '%s\n' "$total" >"$2/bench-$3-bytes"
 '''
 for label in ['old','new']:
  (t/f'bench-{label}.json').write_text(json.dumps(seed))
  subprocess.run([BASH,'-eu','-c',benchmark,'fixture',str(t/(label+'.sh')),str(t),label],check=True)
 assert json.loads((t/'bench-old-result').read_text())==json.loads((t/'bench-new-result').read_text())
 before=int((t/'bench-old-bytes').read_text());after=int((t/'bench-new-bytes').read_text())
 assert after<before/4
 print(f'Equivalent 10-series observations: working JSON processed {before:,} -> {after:,} bytes ({100*(1-after/before):.1f}% less)',flush=True)
 run(r'''
 source "$1"
 mkdir "$2/stat-batches"
 for n in {1..70};do printf x >"$2/stat-batches/$n.nfo";done
 jq -n '[range(1;71)|{relativePath:((tostring)+".nfo"),size:1,sha256:("0"*64)}]|{files:.}' >"$2/stat-manifest"
 # Bind the counter path explicitly rather than inheriting a utility argument.
 eval 'stat(){ printf "stat\n" >>"'"$2"'/stat-count";command stat "$@"; }'
 mc_sidecar_fingerprint "$2/stat-batches" '[]' "$2/stat-manifest" "$2/stat-signature"
 [[ $(wc -l <"$2/stat-count") == 2 ]]
 ''')
 # Actual complete Sonarr workflow against fixed API evidence, baseline vs rewrite.
 workflow=r'''
 source "$1"
 MC_ROOT="$2/$3";RUNTIME_DIR="$MC_ROOT";mkdir -p "$RUNTIME_DIR"
 MC_TMP="$RUNTIME_DIR/tmp";mkdir "$MC_TMP";VERIFY_RUNTIME_DIR="$RUNTIME_DIR/ram";mkdir "$VERIFY_RUNTIME_DIR"
 MC_SONARR_API_KEY=fixture;SONARR_API_KEY=fixture
 SONARR_STATE_FILE="$RUNTIME_DIR/state.json";SONARR_STATE_BACKUP="$RUNTIME_DIR/backup.json"
 QUARANTINE_KODI_SIDECARS=false;DRY_RUN=true;INSPECT_DELETE_HISTORY=true
 ARR_RETIREMENT_DAYS=90 # Compare workflow parity under the frozen baseline policy.
 NOTIFICATION_BATCH="$RUNTIME_DIR/notifications";: >"$NOTIFICATION_BATCH"
 MC_BRIDGE_ACTIVE=false;LOG_READY=false;NOTIFICATION_STATE_FILE="$RUNTIME_DIR/notify-state"
 printf '{"episodes":{"11":{"seriesId":1,"everHadFile":true,"missingRuns":1},"21":{"seriesId":2,"everHadFile":true,"missingRuns":1}},"sidecarManifests":{},"unknown":{"keep":true}}' >"$SONARR_STATE_FILE"
 mc_app_mutation_gate(){ return 0; };media_recovery_app_held(){ return 1; }
 recover_pending_actions(){ return 0; };log(){ printf '%s\n' "$*" >&2; }
 ops_publish_checkpoint(){ mv "$1" "$2"; }
 queue_action_notification(){ printf '%s\n' "$*" >>"$MC_ROOT/actions"; }
 queue_stateful_resolution_notification(){ :; };queue_stateful_attention_notification(){ :; };queue_attention_notification(){ :; }
 arr_api_request_core(){
 [[ "$1" == GET ]] || { printf 'Unexpected mutation' >&2;return 1; }
 case "$2" in
 /api/v3/system/status) printf '{"appName":"Sonarr","version":"fixture"}';;
 /api/v3/tag) printf '[]';;
 /api/v3/series) printf '[{"id":1,"title":"One","monitored":true,"path":"/series/One","status":"continuing"},{"id":2,"title":"Two","monitored":true,"path":"/series/Two","status":"continuing"}]';;
 /api/v3/queue*) printf '{"records":[],"totalRecords":0}';;
 /api/v3/episode\?seriesId=1*) printf '[{"id":11,"seriesId":1,"seasonNumber":1,"episodeNumber":1,"monitored":true,"hasFile":false}]';;
 /api/v3/episode\?seriesId=2*) printf '[{"id":21,"seriesId":2,"seasonNumber":1,"episodeNumber":1,"monitored":true,"hasFile":false}]';;
 /api/v3/history/series*) printf '[]';;
 /api/v3/series/1|/api/v3/series/2) printf '{"monitored":true,"seasons":[{"seasonNumber":1,"monitored":true}],"tags":[]}';;
 *) printf 'Unexpected GET: %s\n' "$2" >&2;return 1;;esac
 }
 run_sonarr || exit $?
 jq 'del(.performance,.lastRun,.episodes[].lastObservedAt,.episodes[].missingSince,.episodes[].lastHistoryInspectionAt,.lastPrunedCount)' "$SONARR_STATE_FILE" >"$MC_ROOT/comparable"
 '''
 for label in ['old','new']:
  subprocess.run([BASH,'-eu','-c',workflow,'fixture',str(t/(label+'.sh')),str(t),label],check=True)
 assert json.loads((t/'old/comparable').read_text())==json.loads((t/'new/comparable').read_text())
 assert (t/'old/actions').read_text()==(t/'new/actions').read_text()
 print('Exact indexes, isolated observation merge, stable/changed/rotating/racing sidecars, bounded readers and full Sonarr action/state parity passed')
