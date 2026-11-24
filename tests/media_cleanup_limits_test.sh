#!/usr/bin/env bash
# Isolated limits, permission writes and resumable SAB purge fault tests.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/media-cleanup-limits.XXXXXX)
fixture=$(realpath "$fixture")
trap 'rm -rf -- "$fixture"' EXIT
export repo fixture
if [[ -n "${MEDIA_CLEANUP_SAB_MODULE:-}" ]];then cp "$MEDIA_CLEANUP_SAB_MODULE" "$fixture/sab.sh"
else python3 - <<'PY'
from pathlib import Path
import os
s=Path(os.environ['repo']+'/user_script/media_cleanup.sh').read_text()
a=s.index('mc_sab() (\n')+len('mc_sab() (\n');b=s.index('\nmain "$@"\n',a)
Path(os.environ['fixture']+'/sab.sh').write_text(s[:s.index('\n# MODULE: ARR')]+'\n'+s[a:b])
PY
fi
bash <<'GUARDS'
set -euo pipefail
source "$repo/user_script/media_cleanup.sh"
MC_TMP="$fixture/ram";mkdir "$MC_TMP"
MC_GUARDS_ACTIVE=true;MC_DEADLINE=$(( $(date +%s)+1000 ));APP_CONTEXT=SONARR
arr_api_request_core(){ printf '1 000\n' >"$MC_TMP/arr-$APP_CONTEXT.transport";printf 'called\n' >>"$fixture/calls";return 1; }
for n in 1 2 3 4;do if output=$(api_request GET /fixture '');then exit 1;fi;done
[[ $(wc -l <"$fixture/calls") == 3 && -f "$MC_TMP/deferred-SONARR" ]]
# A healthy response resets consecutive failure state; 404 is not an outage.
rm "$MC_TMP/deferred-SONARR";printf '2\n' >"$MC_TMP/arr-SONARR.failures"
arr_api_request_core(){ printf '0 404\n' >"$MC_TMP/arr-$APP_CONTEXT.transport";return 1; }
if api_request GET /fixture '';then exit 1;fi
[[ $(cat "$MC_TMP/arr-SONARR.failures") == 0 ]]
MC_ARR_MAX_MUTATIONS=2;MC_ARR_MAX_RETIREMENTS=1
mc_arr_write_reserve DELETE /movie/1
if mc_arr_write_reserve DELETE /movie/2;then exit 1;fi
[[ $(cat "$MC_TMP/arr-SONARR.writes") == '1 1' ]]
rm "$MC_TMP/deferred-SONARR"
mc_arr_write_reserve PUT /movie/1
if mc_arr_write_reserve PUT /movie/2;then exit 1;fi
MC_DEADLINE=1
if mc_work_allowed sab;then exit 1;fi
[[ -f "$MC_TMP/deferred-sab" ]]
printf 'Deadline, cross-subshell API circuit/reset and mutation/retirement budgets passed\n'
GUARDS
bash <<'SUPERVISOR'
set -euo pipefail
source "$repo/user_script/media_cleanup.sh"
MC_ROOT="$fixture/supervised";mkdir "$MC_ROOT"
MC_STATUS_DIR="$fixture/status";MC_LOCK="$fixture/supervisor.lock";MC_LOG_LOCK="$fixture/supervisor-log.lock";MC_NOTIFY_LOCK="$fixture/supervisor-mail.lock"
STATE_EXPORT_LOCK="$fixture/supervisor-export.lock";MC_NOTIFY_BIN="$fixture/accept-mail"
printf '#!/bin/bash\nexit 0\n' >"$MC_NOTIFY_BIN";chmod +x "$MC_NOTIFY_BIN"
MC_MAX_RUNTIME_SECONDS=2
mc_state_ready(){ return 0; }
mc_arr(){ LOG_READY=true;sleep 3;mc_finish_module arr 0 all; }
mc_sab(){ touch "$fixture/unexpected-sab"; }
mc_quarantine(){ touch "$fixture/unexpected-quarantine"; }
mc_main all
jq -e '.status=="DEFERRED" and .modules[0].status=="COMPLETED" and .modules[1].status=="DEFERRED" and .modules[1].metrics.notStarted==true and .modules[2].status=="DEFERRED" and (.notificationBacklog.pendingSections|type)=="number"' "$MC_ROOT/latest-run.json" >/dev/null
[[ ! -e "$fixture/unexpected-sab" && ! -e "$fixture/unexpected-quarantine" ]]
# A real failure must outrank a deliberate deferral in the same module.
printf 'Real Radarr failure\n' >"$MC_TMP/failed-arr"
printf 'Budget exhausted\n' >"$MC_TMP/deferred-SONARR"
if mc_finish_module arr 2;then exit 1;fi
jq -e '.status=="FAILED" and (.reason|contains("Real Radarr failure"))' "$MC_TMP/arr.result.json" >/dev/null
printf 'Supervisor deadline stops later modules; truthful deferral/metrics and failure precedence passed\n'
SUPERVISOR
bash <<'PURGE'
set -euo pipefail
source "$fixture/sab.sh"
trap - EXIT INT TERM
LOG_DIR="$fixture/log";TMP_DIR="$fixture/tmp";MC_TMP="$fixture/work";mkdir -p "$LOG_DIR" "$TMP_DIR" "$MC_TMP"
OPS_ATTENTION_FILE='';MC_MODULE=sab;MC_GUARDS_ACTIVE=false
QUARANTINE_DIR_REAL="$fixture/quarantine";SAB_MOVIE_DIR_REAL="$fixture/movies";SAB_TV_DIR_REAL="$fixture/series"
PURGE_RECEIPT_DIR="$LOG_DIR/receipts";OPS_PENDING_OPERATIONS_FILE="$LOG_DIR/pending.json";OPS_OPERATION_AUDIT_FILE="$LOG_DIR/audit.jsonl"
mkdir -p "$QUARANTINE_DIR_REAL/items/Sonarr" "$SAB_MOVIE_DIR_REAL" "$SAB_TV_DIR_REAL"
MC_LOG_LOCK="$fixture/log.lock";MC_ROOT="$LOG_DIR";LOG_LEVEL=INFO
MOVER_GUARD_ENABLED=false;DRY_RUN=false;PURGE_QUARANTINE=true;MAX_PURGE_BYTES_PER_RUN=1024;MAX_PURGE_FILES_PER_RUN=250
QUARANTINE_RETENTION_DAYS=14;RUN_ID=fixture
sync(){ :; }
# Existing correct permissions cause zero chmod writes, wrong entries only one.
QUARANTINE_OWNER=$(id -un);QUARANTINE_DIRECTORY_MODE=0755;QUARANTINE_FILE_MODE=0644
printf x >"$QUARANTINE_DIR_REAL/test";chmod 644 "$QUARANTINE_DIR_REAL/test";chmod 755 "$QUARANTINE_DIR_REAL" "$QUARANTINE_DIR_REAL/items" "$QUARANTINE_DIR_REAL/items/Sonarr"
REAL_CHMOD=$(command -v chmod);mkdir "$fixture/bin"
printf '#!/bin/bash\nprintf "chmod\\n" >>%q\nexec %q "$@"\n' "$fixture/chmod-count" "$REAL_CHMOD" >"$fixture/bin/chmod"
"$REAL_CHMOD" +x "$fixture/bin/chmod"
PATH="$fixture/bin:$PATH"
normalize_quarantine_permissions "$QUARANTINE_DIR_REAL"
[[ ! -e "$fixture/chmod-count" ]]
"$REAL_CHMOD" 600 "$QUARANTINE_DIR_REAL/test"
normalize_quarantine_permissions "$QUARANTINE_DIR_REAL"
[[ $(wc -l <"$fixture/chmod-count") == 1 ]]
rm "$QUARANTINE_DIR_REAL/test"
make_wrapper(){
 wrapper="$QUARANTINE_DIR_REAL/items/Sonarr/$1";mkdir -p "$wrapper/payload"
 jq -nc --arg original "$SAB_TV_DIR_REAL/Fixture" '{owner:"Sonarr",downloadId:"fixture",originalPath:$original,bytes:1400,quarantinedEpoch:1,state:"committed"}' >"$wrapper/.sabnzbd-cleanup-manifest.json"
 head -c 700 /dev/zero >"$wrapper/payload/a.mkv";head -c 700 /dev/zero >"$wrapper/payload/b.mkv"
}
reset_counts(){ PURGED=0;BYTES_PURGED=0;SAB_PURGED_FILES=0;SAB_PARTIAL_PURGES=0;SAB_PURGE_REMAINING=0;PURGE_DETAILS=(); }
make_wrapper big;reset_counts
purge_quarantine
[[ "$BYTES_PURGED" == 700 && "$SAB_PARTIAL_PURGES" == 1 && -f "$wrapper/payload/b.mkv" && ! -e "$wrapper/payload/a.mkv" ]]
jq -e '.operations|length==0' "$OPS_PENDING_OPERATIONS_FILE" >/dev/null
jq -e '.incrementalPurgeStarted==true' "$wrapper/.sabnzbd-cleanup-manifest.json" >/dev/null
reset_counts;purge_quarantine
[[ ! -e "$wrapper" && "$PURGED" == 1 && "$BYTES_PURGED" -le 1024 ]]
# Explicit restore after partial purge reports that only the remainder returns.
make_wrapper restore-remainder;reset_counts;purge_quarantine
restore_quarantine_payload "$wrapper"
[[ -f "$SAB_TV_DIR_REAL/Fixture/b.mkv" && ! -e "$SAB_TV_DIR_REAL/Fixture/a.mkv" ]]
[[ "${RECOVERY_DETAILS[*]}" == *'only the remaining quarantined payload'* ]]
command rm -rf -- "$SAB_TV_DIR_REAL/Fixture"
# Failed unlink result after actual deletion leaves a recoverable exact intent.
make_wrapper interrupted;reset_counts
(
 rm(){ command rm "$@";[[ "${*: -1}" != "$wrapper/payload/a.mkv" ]]; }
 if purge_quarantine;then exit 1;fi
)
jq -e 'any(.operations[];.kind=="purge-file")' "$OPS_PENDING_OPERATIONS_FILE" >/dev/null
ops_recover_operations
jq -e '.operations|length==0' "$OPS_PENDING_OPERATIONS_FILE" >/dev/null
# A changed object after its durable intent is preserved, never unlinked.
reset_counts
eval "$(declare -f ops_operation_begin | sed '1s/ops_operation_begin/fixture_original_begin/')"
ops_operation_begin(){ local id;id=$(fixture_original_begin "$@") || return 1;[[ "$1" != purge-file ]] || printf changed >>"$2";printf '%s' "$id"; }
# Force partial mode for the remaining 700-byte file plus its manifest.
MAX_PURGE_FILES_PER_RUN=1
if purge_quarantine;then exit 1;fi
[[ -f "$wrapper/payload/b.mkv" ]]
if ops_recover_operations;then exit 1;fi
printf 'Only mismatched permissions written; oversized wrapper progress, caps, interrupted unlink and changed-object protection passed\n'
PURGE
