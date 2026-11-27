"""Isolated operational fixes; no production APIs, notifications or media changes."""
import os, shutil, subprocess, tempfile
from pathlib import Path
R=Path(__file__).resolve().parents[1];BASH=shutil.which('bash')
s=(R/'user_script/media_cleanup.sh').read_text();a=s.index('mc_arr() (\n')+len('mc_arr() (\n');b=s.index('\nmain "$@"\n',a)
with tempfile.TemporaryDirectory(prefix='hubble-review-fixes.') as d:
 t=Path(d).resolve();lib=t/'arr.sh';lib.write_text(s[:s.index('\n# MODULE: ARR')]+'\n'+s[a:b])
 def run(code):subprocess.run([BASH,'-eu','-c',code,'fixture',str(R),str(t),str(lib)],check=True)
 run(r'''
 source "$1/tools/operations_contract.sh"
 OPS_SCRIPT_ID=fixture;USR_OPS_EXECUTION_ROOT="$2/execution";mountpoint(){ return 1; }
 mkdir "$USR_OPS_EXECUTION_ROOT"
 printf '{"schema":1,"executionStatus":"FAILED","startedAt":10,"finishedAt":20,"durationSeconds":10,"lastExitCode":1,"lastCompletedAt":20,"lastSuccessAt":5}' >"$USR_OPS_EXECUTION_ROOT/fixture.json"
 usr_ops_execution_record start 30 $$
 jq -e '.executionStatus=="RUNNING" and .finishedAt==null and .durationSeconds==null and .lastExitCode==null and .previousRun.exitCode==1 and .lastCompletedAt==20 and .lastSuccessAt==5' "$USR_OPS_EXECUTION_ROOT/fixture.json" >/dev/null
 [[ $(usr_ops_now_ms) =~ ^[0-9]{13}$ ]]
 ''')
 run(r'''
 source "$3"
 log(){ :; };queue_action_notification(){ :; };tag_id_by_label(){ printf 22; }
 api_get_json(){ printf '{"id":1,"tags":[7,22],"monitored":true,"custom":"preserve"}'; }
 api_put_json(){ printf '%s' "$2" >"$TEST_PAYLOAD"; }
 TEST_PAYLOAD="$2/payload";WORK_STATE="$2/arr-state";VERIFY_RUNTIME_DIR="$2";RUN_AT=fixed;RETIREMENTS_CANCELLED=0;ARR_NAME=Sonarr;DRY_RUN=false
 printf '{"seriesRetirements":{"1":{"startedAt":"old"}}}' >"$WORK_STATE"
 sonarr_cancel_retirement 1 'Monitoring restored'
 jq -e '.tags==[7] and .monitored==true and .custom=="preserve"' "$TEST_PAYLOAD" >/dev/null
 jq -e '.seriesRetirements["1"].suppressed==true and .seriesRetirements["1"].startedAt==null' "$WORK_STATE" >/dev/null
 [[ "$ARR_RETIREMENT_DAYS" == 30 && "$STATE_PRUNE_ABSENT_DAYS" == 90 ]]
 DRY_RUN=true;rm "$TEST_PAYLOAD";arr_clear_pending_tag movie 1 retirement-pending
 [[ ! -f "$TEST_PAYLOAD" ]]
 ''')
 run(r'''
 source "$1/user_script/host_health_watchdog.sh"
 STATE_DIR="$2/syslog";mkdir "$STATE_DIR";CURSOR_FILE="$STATE_DIR/cursor";SYSLOG_FILE="$STATE_DIR/syslog"
 SYSLOG_BATCH_MAX_LINES=3;SYSLOG_BATCH_MAX_BYTES=1024;STARTUP_LOOKBACK_LINES=100;log(){ :; }
 mountpoint(){ return 1; };notify_unraid(){ printf '%s\n' "$*" >>"$STATE_DIR/notifications"; }
 printf 'first\nsecond\nthird\nfourth\nfifth\n' >"$SYSLOG_FILE"
 capture_current_syslog_state;build_new_syslog_chunk "$STATE_DIR/chunk"
 [[ $(wc -l <"$STATE_DIR/chunk") == 3 && "$CURRENT_LINE_COUNT" == 3 && "$SYSLOG_BACKLOG" == true ]]
 write_cursor;capture_current_syslog_state;build_new_syslog_chunk "$STATE_DIR/chunk"
 [[ $(wc -l <"$STATE_DIR/chunk") == 2 && "$CURRENT_LINE_COUNT" == 5 ]]
 write_cursor
 printf 'Nov 26 01:00:00 Hubble kernel: kernel panic: example failure\n' >"$STATE_DIR/critical"
 filter_matching_errors "$STATE_DIR/critical" "$STATE_DIR/matches"
 [[ -s "$STATE_DIR/matches" ]]
 jq -e 'any(.incidents[];.severity=="CRITICAL" and .requiresAttention==true)' "$STATE_DIR/incidents.json" >/dev/null
 # Unknown matching messages become JSON evidence without editing rules.
 printf 'Nov 26 01:00:01 Hubble service: error novel-native-message\n' >"$STATE_DIR/new"
 filter_matching_errors "$STATE_DIR/new" "$STATE_DIR/matches"
 jq -e 'any(.incidents[];.example|contains("novel-native-message"))' "$STATE_DIR/incidents.json" >/dev/null
 # A changed/incomplete old log does not acknowledge unread tail.
 printf 'sixth\nseventh\n' >>"$SYSLOG_FILE"
 capture_current_syslog_state;build_new_syslog_chunk "$STATE_DIR/chunk"
 [[ "$CURRENT_LINE_COUNT" == 7 ]]
 write_cursor
 printf 'unfinished' >>"$SYSLOG_FILE"
 capture_current_syslog_state;build_new_syslog_chunk "$STATE_DIR/chunk"
 [[ ! -s "$STATE_DIR/chunk" && "$CURRENT_LINE_COUNT" == 7 ]]
 printf '\n' >>"$SYSLOG_FILE"
 capture_current_syslog_state;build_new_syslog_chunk "$STATE_DIR/chunk"
 [[ "$CURRENT_LINE_COUNT" == 8 && $(cat "$STATE_DIR/chunk") == unfinished ]]
 write_cursor
 mv "$SYSLOG_FILE" "$SYSLOG_FILE.1";printf 'after rotation\n' >"$SYSLOG_FILE"
 capture_current_syslog_state;build_new_syslog_chunk "$STATE_DIR/chunk"
 [[ $(cat "$STATE_DIR/chunk") == 'after rotation' && "$CURRENT_LINE_COUNT" == 1 ]]
 # Persistent vault recovery retains RAM-spooled unknown evidence.
 SYSLOG_INCIDENT_ROOT="$STATE_DIR/persistent";mountpoint(){ return 0; }
 filter_matching_errors "$STATE_DIR/new" "$STATE_DIR/matches"
 jq -e 'any(.incidents[];.severity=="CRITICAL")' "$SYSLOG_INCIDENT_ROOT/incidents.json" >/dev/null
 [[ ! -e "$STATE_DIR/incidents.json" ]]
 ''')
 run(r'''
 eval "$(sed -n '/^sab_load_warning_cleanup_verified() {/,/^}/p' "$1/user_script/media_health_monitor.sh")"
 SAB_STATUS_OK=true;SAB_QUEUE_OK=true;SAB_HISTORY_OK=true
 SAB_STATUS="$2/sab-status";SAB_QUEUE="$2/sab-queue";SAB_HISTORY="$2/sab-history";MEDIA_CLEANUP_SOURCE_RECEIPTS="$2/source-removals"
 printf '{"status":{"folders":[]}}' >"$SAB_STATUS";printf '{"queue":{"slots":[]}}' >"$SAB_QUEUE";printf '{"history":{"slots":[]}}' >"$SAB_HISTORY"
 printf '{"schema":1,"records":{"/mnt/user/media/net/incomplete/Example":{"originalPath":"/mnt/user/media/net/incomplete/Example","sourceAbsent":true,"action":"quarantined","at":200}}}' >"$MEDIA_CLEANUP_SOURCE_RECEIPTS"
 docker(){ printf '[{"Mounts":[{"Type":"bind","Source":"/mnt/user/media","Destination":"/data"}]}]'; }
 timeout(){ [[ "$1" != --kill-after=* ]] || shift;shift;"$@"; }
 sab_load_warning_cleanup_verified 'Loading /data/net/incomplete/Example/__ADMIN__/SABnzbd_nzo_data failed' 100
 if sab_load_warning_cleanup_verified 'Loading /data/net/incomplete/Example/__ADMIN__/SABnzbd_nzo_data failed' 201;then exit 1;fi
 printf '{"queue":{"slots":[{"filename":"Example"}]}}' >"$SAB_QUEUE"
 if sab_load_warning_cleanup_verified 'Loading /data/net/incomplete/Example/__ADMIN__/SABnzbd_nzo_data failed' 100;then exit 1;fi
 ''')
 run(r'''
 source "$1/user_script/backup_health_audit.sh"
 STATUS_DIR="$2/registry";STATE_DIR="$STATUS_DIR";mkdir "$STATUS_DIR";AUDIT_CATALOG_FILE="$2/catalog"
 printf payload >"$2/code";hash=$(sha256sum "$2/code"|cut -d ' ' -f1)
 jq -n --arg path "$2/code" '{jobs:{one:{name:"one",role:"one",present:true,physicalPath:$path}}}' >"$AUDIT_CATALOG_FILE"
 jq -n --arg hash "$hash" '{schema:1,scripts:{one:{sha256:$hash}}}' >"$STATUS_DIR/deployments.json"
 FINDINGS=();audit_deployed_code;[[ ${#FINDINGS[@]} == 0 ]]
 printf change >>"$2/code";audit_deployed_code;[[ ${#FINDINGS[@]} == 1 ]]
 ''')
 print('Receipt lifecycle, 30-day hold/tag cancellation, bounded syslog/incident JSON, exact SAB proof and deployment drift passed')
