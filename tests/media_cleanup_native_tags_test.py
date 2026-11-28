"""Native automatic-tag reconciliation; strict manual/lifecycle safeguards, no network."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
text = (root / 'user_script/media_cleanup.sh').read_text()
a = text.index('mc_arr() (\n') + len('mc_arr() (\n')
b = text.index('\nmain "$@"\n', a)
source = text[:text.index('\n# MODULE: ARR')] + '\n' + text[a:b]
with tempfile.TemporaryDirectory(prefix='cleanup-native-tags.') as tmp:
    folder = Path(tmp)
    (folder / 'module.sh').write_text(source)
    code = r'''
source "$1/module.sh"
RUNTIME_DIR="$1";VERIFY_RUNTIME_DIR="$1";APP_CONTEXT=SONARR;ARR_URL=http://fixture
log(){ printf '%s %s\n' "$1" "$2" >> "$RUNTIME_DIR/messages"; }
printf '[{"id":3,"tags":[8,153],"removeTagsAutomatically":true}]' > "$1/rules"
printf '[{"id":8,"label":"hd"},{"id":145,"label":"seerr-tv"},{"id":153,"label":"retirement-pending"}]' > "$1/catalog"
printf '{"id":20498,"monitored":false,"tags":[8,145,153],"seasons":[{"seasonNumber":1,"monitored":false}]}' > "$1/expected"
printf '{"id":20498,"monitored":false,"tags":[145,153],"seasons":[{"seasonNumber":1,"monitored":false}]}' > "$1/actual"
arr_verification_get(){
  printf '%s\n' "$1" >> "$RUNTIME_DIR/reads"
  ARR_VERIFY_HTTP=200
  case "$1" in
    /api/v3/autotagging) cp "$RUNTIME_DIR/rules" "$2";;
    /api/v3/tag) cp "$RUNTIME_DIR/catalog" "$2";;
    /api/v3/series/20498) cp "$RUNTIME_DIR/actual" "$2";;
    *) return 1;;
  esac
}
arr_expected_fields_match "$1/expected" "$1/actual" 20498
[[ "$ARR_NATIVE_AUTOMATIC_TAG_IDS" == '[8]' && -n "$ARR_NATIVE_TAG_NOTE" ]]
[[ $(wc -l < "$1/reads") -eq 2 ]]
# Cached policy, strict ID/monitoring/seasons/manual/lifecycle and explicit tag actions.
for filter in '.tags=[153]' '.tags=[145]' '.tags+=[999]' '.monitored=true' '.seasons[0].monitored=true' '.id=99'; do
 jq "$filter" "$1/actual" > "$1/bad"
 if arr_expected_fields_match "$1/expected" "$1/bad" 20498;then echo "Unsafe verification: $filter";exit 1;fi
done
if arr_expected_fields_match "$1/expected" "$1/actual" 20498 add;then exit 1;fi
APP_CONTEXT=RADARR
if arr_expected_fields_match "$1/expected" "$1/actual" 20498;then exit 1;fi
APP_CONTEXT=SONARR
printf '{"actions":{"fixture":{"source":"/api/v3/series/20498","verification":"PUT","destination":' > "$1/pending"
jq -Rs . < "$1/expected" >> "$1/pending"
printf '}}}' >> "$1/pending"
PENDING_ACTIONS_FILE="$1/pending"
verify_arr_checkpoint fixture
[[ "$ARR_VERIFY_REASON" == *'Native Sonarr automatic-tag policy'* ]]
# Missing or changed native rules fail closed, even for a previously observed tag.
ARR_NATIVE_TAG_SCOPE='';printf '[]' > "$1/rules"
if arr_expected_fields_match "$1/expected" "$1/actual" 20498;then exit 1;fi
ARR_NATIVE_TAG_SCOPE='';printf '[{"tags":[8],"removeTagsAutomatically":false}]' > "$1/rules"
if arr_expected_fields_match "$1/expected" "$1/actual" 20498;then exit 1;fi
ARR_NATIVE_TAG_SCOPE='';printf '{}' > "$1/rules"
if arr_expected_fields_match "$1/expected" "$1/actual" 20498;then exit 1;fi
RUN_ID=fixture;LOG_FILE="$1/log"
printf '2026-11-28 | ERROR | media_cleanup | run=fixture | phase=arr/SONARR | Exact failure reason\n' > "$LOG_FILE"
current_workflow_error_details > "$1/detail" 2> "$1/awk-error"
grep -q 'Exact failure reason' "$1/detail";[[ ! -s "$1/awk-error" ]]
mc_state_ready(){ return 0; }
STATE_EXPORT_LOCK="$1/export.lock";MC_ROOT="$1/outbox";MC_NOTIFY_LOCK="$1/notify.lock";mkdir "$MC_ROOT"
mc_note arr failed 'Wrapper failure' 'Exact cause already queued' true
jq -e '.topics["main:arr"].status=="failed" and (.events|length)==0' "$MC_ROOT/notification-outbox.json" >/dev/null
mc_note arr failed 'Wrapper failure without details' 'Fallback must remain visible' false
jq -e 'any(.events[];.subject=="Wrapper failure without details")' "$MC_ROOT/notification-outbox.json" >/dev/null
printf '[PASS] Native auto tags reconcile exact checkpoints; manual/lifecycle/monitoring/identity remain strict; unavailable rules fail closed; awk diagnostics preserved\n'
'''
    subprocess.run([os.environ.get('BASH_BIN', shutil.which('bash')), '-euo', 'pipefail', '-c', code, 'fixture', str(folder)], check=True)
