#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d /tmp/arr-health-batch.XXXXXX)
source <(awk '/^# LOCK$/{exit} {print}' "$repo/user_script/arr_health_activity.sh")
trap - INT TERM HUP
trap 'rm -rf -- "$root"' EXIT
TMP_DIR="$root" STATE_FILE="$root/state.json"
SAB_HISTORY="$root/history.json" SAB_QUEUE="$root/queue.json"
DOWNLOAD_LEDGER_OBSERVATIONS_FILE="$root/observations.jsonl"
START_TIME=200000 AUDIT_CUTOFF_EPOCH=190000
SAB_HISTORY_OK=true SAB_QUEUE_OK=true SAB_SCAN_OK=true
jq -n '{monitor:{},downloadLedger:{"old-enrolled":{flowEnrolled:true}}}' >"$STATE_FILE"
jq -n '{queue:{slots:[{nzo_id:"ACTIVE-ID",cat:"tv",filename:"Active Show",status:"Downloading",time_added:195000}]}}' >"$SAB_QUEUE"
jq -n '{history:{noofslots:1005,slots:([range(0;1000)|{nzo_id:("old-"+tostring),category:"tv",name:"Old Show",status:"Completed",completed:100}]+[
 {nzo_id:"old-enrolled",category:"tv",name:"Tracked Old Show",status:"Completed",completed:100},
 {nzo_id:"new-import",category:"movie",name:"New Movie",status:"Completed",completed:199000},
 {nzo_id:"failed-id",category:"tv",name:"Failed Show",status:"Failed",completed:198000},
 {nzo_id:"ignored-id",category:"f1",name:"Ignored",status:"Completed",completed:199000},
 {nzo_id:"unknown-category",category:"other",name:"Other",status:"Completed",completed:199000}
])}}' >"$SAB_HISTORY"
: >"$DOWNLOAD_LEDGER_OBSERVATIONS_FILE"
collect_sab_download_ledger
jq -se 'length==4 and any(.[];.id=="active-id" and .kind=="sabQueue") and any(.[];.id=="old-enrolled") and any(.[];.id=="new-import" and .app=="Radarr")' "$DOWNLOAD_LEDGER_OBSERVATIONS_FILE" >/dev/null
process_sab_activity_audit
FLOW_CUTOFF_EPOCH=190000
calculate_flow_sab_activity
[[ "$FLOW_SAB_TV_COMPLETED" == 0 && "$FLOW_SAB_MOVIE_COMPLETED" == 1 ]]
[[ "$SAB_AUDIT_OK" == true && "$SAB_AUDIT_MOVIE_COMPLETED" == 1 && "$SAB_AUDIT_TV_FAILED" == 1 && "$SAB_AUDIT_TV_COMPLETED" == 0 && "$SAB_AUDIT_F1_IGNORED" == 1 ]]
jq --arg signature "$SAB_LEDGER_NEW_SIGNATURE" --argjson now "$START_TIME" '.monitor={sabLedgerCacheSignature:$signature,sabLedgerLastReplayAt:$now,sabFilesystemLastSuccessfulAt:$now}' "$STATE_FILE" >"$root/changed.json"; mv "$root/changed.json" "$STATE_FILE"
: >"$DOWNLOAD_LEDGER_OBSERVATIONS_FILE"
collect_sab_download_ledger
jq -se 'length==1 and .[0].id=="active-id"' "$DOWNLOAD_LEDGER_OBSERVATIONS_FILE" >/dev/null
if sab_filesystem_scan_due; then echo 'hourly scan ran too early' >&2; exit 1; fi
SAB_FILESYSTEM_SCAN_OK=false SAB_HISTORY_OK=true SONARR_QUEUE_OK=true RADARR_QUEUE_OK=true
if source_can_resolve SABnzbd 'SABnzbd:orphan:example'; then echo 'deferred filesystem issue could incorrectly resolve' >&2; exit 1; fi
SEEN_ISSUES_FILE="$root/seen.txt"; : >"$SEEN_ISSUES_FILE"
jq '.issues={"SABnzbd:orphan:one":{active:true,app:"SABnzbd",classification:"SAB_STRANDED_MEDIA",severity:"WARNING"}}' "$STATE_FILE" >"$root/with-issue.json"; mv "$root/with-issue.json" "$STATE_FILE"
WARNING_COUNT=0 INFO_COUNT=0 ERROR_COUNT=0 TOTAL_ISSUES=0
carry_deferred_filesystem_issue_counts
[[ "$WARNING_COUNT" == 1 && "$TOTAL_ISSUES" == 1 ]]
START_TIME=204000
sab_filesystem_scan_due
# Failed scans do not get a cursor here; future scans stay due until success.
SONARR_QUEUE="$root/sonarr.json" RADARR_QUEUE="$root/radarr.json"
printf '{"records":[{"downloadId":"Exact-ID","title":"Current Show"}]}\n' >"$SONARR_QUEUE"
printf '{"records":[]}\n' >"$RADARR_QUEUE"
prepare_arr_download_indexes
[[ "$(arr_queue_item_by_download_id Sonarr exact-id | jq -r '.title')" == 'Current Show' ]]
SONARR_SCAN_OK=true
arr_tracks_download Sonarr EXACT-ID
if arr_tracks_download Sonarr absent-id; then exit 1; fi
printf 'Batch history, incremental replay, exact indexes and hourly resolution-preservation tests passed\n'
