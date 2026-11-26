#!/usr/bin/env python3
"""Exercise the actual consolidated modules against the existing safety fixtures."""
import os
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash')
MODULES = {'arr': 'arr_delete_sync_tag', 'sab': 'sabnzbd_cleanup', 'quarantine': 'quarantine_lifecycle'}
SHARED_LOG_REPLACEMENTS = {'log_file_size','log_file_mtime','rotate_log','record_removed_log','cleanup_existing_logs'}
text = (REPO/'user_script/media_cleanup.sh').read_text()
common = text[:text.index('\n# MODULE: ARR')]
with tempfile.TemporaryDirectory(prefix='media-cleanup-fixtures.') as temporary:
    target = Path(temporary)
    shutil.copytree(REPO/'tests', target/'tests')
    (target/'user_script').mkdir()
    for source in (REPO/'user_script').glob('*.sh'):
        (target/'user_script'/source.name).symlink_to(source)
    for module, original in MODULES.items():
        start = text.index('mc_'+module+'() (\n') + len('mc_'+module+'() (\n')
        end = text.index('\nmain "$@"\n', start)
        body = text[start:end]
        # Every original operation/helper must still exist locally or be shared.
        original_text = (REPO/'user_script'/f'{original}.sh').read_text()
        names = set(re.findall(r'^(\w+)\(\) [({]', original_text, re.M))
        available = set(re.findall(r'^(\w+)\(\) [({]', common+'\n'+body, re.M))
        missing = names-available-(SHARED_LOG_REPLACEMENTS if module=='arr' else set())
        assert not missing, (module, missing)
        path=target/'user_script'/f'{original}.sh'
        path.unlink()
        # These fixtures test actions/proofs rather than the common logger;
        # redirect only its sink into the fixture's private log path.
        path.write_text(common+'\nMC_MODULE='+module+'\n'+body+'''
mc_write_line() { [[ ! -d "${LOG_FILE%/*}" ]] || printf '%s\\n' "$1" >>"$LOG_FILE"; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
''')
    # The optimized read-only planner view must match the original full-state
    # implementation, including a same-run state replacement and series switch.
    planner = r'''
source "$1"
WORK_STATE="$2/state.json"; VERIFY_RUNTIME_DIR="$2/ram"; mkdir -p "$VERIFY_RUNTIME_DIR"
SERIES_ID=1; RUN_AT="2026-11-24T00:00:00+0800"
for phase in initial updated other; do
 if [[ "$phase" == initial ]]; then
  printf '{"episodes":{"11":{"seriesId":1,"everHadFile":true,"missingRuns":2},"21":{"seriesId":2,"everHadFile":true,"missingRuns":1}},"sidecarManifests":{},"sidecarCleanupActions":{},"seriesRetirements":{}}' >"$WORK_STATE"
 elif [[ "$phase" == updated ]]; then
  jq '.episodes["11"].missingRuns=0' "$WORK_STATE" >"$WORK_STATE.next";mv "$WORK_STATE.next" "$WORK_STATE"
 else SERIES_ID=2; fi
 jq -cn --argjson sid "$SERIES_ID" '[{id:($sid*10+1),seriesId:$sid,seasonNumber:1,episodeNumber:1,monitored:true,hasFile:false}]' >"$2/episodes.json"
 sonarr_new_candidate_count "$SERIES_ID"
 sonarr_confirmed_episode_ids "$2/episodes.json"
 sonarr_candidate_seasons "$SERIES_ID" "$2/episodes.json" '[]'
 sonarr_candidate_series "$SERIES_ID" "$2/episodes.json" '[]'
 sonarr_series_cleanup_eligible "$SERIES_ID" "$2/episodes.json"
done
if declare -F sonarr_prepare_read_state >/dev/null; then
 sonarr_prepare_read_state
 [[ "$SONARR_READ_STATE" != "$WORK_STATE" ]]
 jq -e 'all(.episodes[];.seriesId==2)' "$SONARR_READ_STATE" >/dev/null
fi
'''
    outputs=[]
    for label,script in (("original",REPO/'user_script/arr_delete_sync_tag.sh'),("merged",target/'user_script/arr_delete_sync_tag.sh')):
        data=target/label;data.mkdir()
        outputs.append(subprocess.check_output([BASH,'-eu','-c',planner,'planner',str(script),str(data)]))
    def decode_stream(raw):
        result=[]; remaining=raw.decode();decoder=json.JSONDecoder()
        while remaining.strip():
            remaining=remaining.lstrip();value,end=decoder.raw_decode(remaining)
            result.append(value);remaining=remaining[end:]
        return result
    assert decode_stream(outputs[0])==decode_stream(outputs[1]), 'Planner cache changed a decision or failed to invalidate'
    print('Planner output parity, state-replacement invalidation and series isolation passed',flush=True)
    retirement = r'''
source "$1"
RUNTIME_DIR="$2";STATE_DIR="$2";VERIFY_RUNTIME_DIR="$2";WORK_STATE="$2/state.json"
ARR_RETIREMENT_DAYS=90 # Compare unchanged retirement decisions under identical policy; 30-day policy is tested separately.
RUN_AT='2026-11-24T00:00:00+0800';DRY_RUN=true;RETIREMENTS_CANCELLED=0;ARR_REMOVALS=0;RETIREMENTS_STARTED=0
RADARR_QUEUE_AVAILABLE=true
TAG_CATALOG='[{"id":1,"label":"plex-deleted"},{"id":2,"label":"keep-in-arr"}]'
log() { :; }
# Keep only semantic topics in this fixture output, never temporary paths.
queue_action_notification() { printf 'action|%s|%s\n' "$1" "$2" >>"$events"; }
queue_stateful_resolution_notification() { printf 'resolved|%s|%s\n' "$1" "$2" >>"$events"; }
queue_stateful_attention_notification() { printf 'attention|%s|%s\n' "$1" "$3" >>"$events"; }
radarr_queue_has_movie() { return 1; }
api_put_json() { printf 'Unexpected API mutation\n' >&2;return 1; }
api_delete() { printf 'Unexpected API deletion\n' >&2;return 1; }
events="$2/events";: >"$events"
jq -n '{movies:{"6":{everHadFile:true,missingRuns:2}},movieRetirements:{
 "2":{startedAt:"2026-10-01T00:00:00Z"},"4":{startedAt:"2026-11-01T00:00:00Z"},
 "5":{startedAt:"2026-10-01T00:00:00Z"},"7":{startedAt:"2026-10-01T00:00:00Z"},
 "8":{suppressed:true},"9":{startedAt:"2026-01-01T00:00:00Z"}},
 sidecarManifests:{},sidecarCleanupActions:{"6":{completedAt:"2026-11-01"}}}' >"$WORK_STATE"
jq -n '[range(1;10)|. as $id|{id:$id,title:("Fixture "+($id|tostring)),year:2026,
 hasFile:([1,2]|index($id)!=null),monitored:([1,2,3,5]|index($id)!=null),
 tags:(if $id==7 then [1,2] else [1] end)}]' >"$2/movies.json"
radarr_process_retirements "$2/movies.json"
# Compare retirement decisions; the merged script also keeps bounded audit history.
jq -cS '(.movies // {})|=(with_entries(.value|=del(.retirementHistory,.lifecycleTags))|with_entries(select(.value!={})))' "$WORK_STATE"
sort "$events"
printf 'cancelled=%s; removed=%s; started=%s\n' "$RETIREMENTS_CANCELLED" "$ARR_REMOVALS" "$RETIREMENTS_STARTED"
'''
    results=[]
    for label,script in (("retirement-original",REPO/'user_script/arr_delete_sync_tag.sh'),("retirement-merged",target/'user_script/arr_delete_sync_tag.sh')):
        data=target/label;data.mkdir()
        results.append(subprocess.check_output([BASH,'-eu','-c',retirement,'retirement',str(script),str(data)]))
    assert results[0]==results[1], 'Retirement filtering changed a timer, cancellation or removal decision'
    print('Radarr retirement parity: healthy, returned, monitored, held, exempt, suppressed and due cases passed',flush=True)
    for test in ('auxiliary_sidecar_test.sh','arr_delete_api_recovery_test.sh',
                 'arr_policy_cleanup_test.sh','durable_import_cleanup_test.sh',
                 'cleanup_checkpoint_test.sh','cleanup_recovery_test.sh',
                 'sab_orphan_cleanup_test.sh','sab_native_orphan_recovery_test.sh',
                 'quarantine_lifecycle_test.sh','quarantine_incremental_test.sh'):
        print('Merged-module safety fixture:',test,flush=True)
        subprocess.run([BASH,str(target/'tests'/test)],check=True,cwd=target)
print('All original module functions accounted for; consolidated safety fixtures passed')
