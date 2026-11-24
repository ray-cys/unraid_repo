#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/arr-policy-test.XXXXXX)
source <(awk '/^# LOCK$/{exit} {print}' "$repo/user_script/arr_health_activity.sh")
trap - INT TERM HUP
export MEDIA_INTEGRITY_RECOVERY_FILE="$fixture/recovery.json"
printf '{"schema":1,"workflow":"arr-native","actions":{}}' >"$MEDIA_INTEGRITY_RECOVERY_FILE"
trap 'rm -rf -- "$fixture"' EXIT
TMP_DIR="$fixture"; STATE_DIR="$fixture"; POLICY_STATE_FILE="$fixture/policy-actions.json"; START_TIME=100000
sync() { :; }
log() { :; }
POLICY_GRACE_HOURS=6
SONARR_API_ROOT=http://sonarr/api/v3; SONARR_API_KEY=fixture
RADARR_API_ROOT=http://radarr/api/v3; RADARR_API_KEY=fixture
printf '{"version":1,"actions":{},"observations":{}}' >"$POLICY_STATE_FILE"
SAB_HISTORY="$fixture/sab.json"; SAB_QUEUE="$fixture/sabqueue.json"
printf '{"queue":{"slots":[]}}' >"$SAB_QUEUE"
printf '{"history":{"slots":[{"nzo_id":"abc-123","status":"Completed","completed":70000,"name":"Show.S01E01","storage":"/downloads/Show.S01E01","category":"tv"}]}}' >"$SAB_HISTORY"
item='{"id":9,"downloadId":"abc-123","protocol":"usenet","status":"completed","trackedDownloadState":"importPending","trackedDownloadStatus":"warning","added":"60000","seriesId":1,"episodeId":11,"seasonNumber":1,"title":"Show.S01E01.1080p","customFormatScore":10,"quality":{"quality":{"id":7}},"statusMessages":[{"messages":["Not a Custom Format upgrade for existing episode file(s). New: [x] (10) do not improve on Existing: [y] (20)"]}]}'
fixture_episode='{"id":11,"seriesId":1,"seasonNumber":1,"episodeNumber":1,"monitored":true,"hasFile":true,"episodeFileId":21}'
fixture_series='{"id":1,"monitored":true,"qualityProfileId":2,"tags":[],"seasons":[{"seasonNumber":1,"monitored":true}]}'
fixture_profile='{"id":2,"minFormatScore":0,"items":[{"allowed":true,"quality":{"id":7}}]}'
fixture_file='{"id":21,"seriesId":1,"path":"/library/show.mkv","size":1000,"customFormatScore":20,"quality":{"quality":{"id":7}}}'
fixture_movie='{"id":31,"monitored":true,"hasFile":true,"movieFileId":41,"qualityProfileId":2,"tags":[]}'
fixture_movie_file='{"id":41,"movieId":31,"path":"/library/movie.mkv","size":1000,"customFormatScore":20,"quality":{"quality":{"id":7}}}'
fixture_history='{"totalRecords":1,"records":[{"downloadId":"abc-123","eventType":"grabbed","seriesId":1,"episodeId":11}]}'
date_to_epoch() { printf '%s\n' "$1"; }
fetch_arr_history_by_download_id() { printf '%s' "$fixture_history" >"$3"; }
api_get() {
    [ "${api_fail:-false}" != true ] || return 1
    case "$1" in
      */episode/11) printf '%s' "$fixture_episode" >"$3";;
      */series/1) printf '%s' "$fixture_series" >"$3";;
      */qualityprofile/2) printf '%s' "$fixture_profile" >"$3";;
      */episodefile/21) printf '%s' "$fixture_file" >"$3";;
      */movie/31) printf '%s' "$fixture_movie" >"$3";;
      */moviefile/41) printf '%s' "$fixture_movie_file" >"$3";;
      */command/42) printf '%s' "$command_result" >"$3";;
      */blocklist*) printf '%s' '{"records":[{"downloadId":"abc-123"}]}' >"$3";;
      *) echo "unexpected GET: $1" >&2; return 1;;
    esac
}
check() { policy_build_candidate Sonarr "$item" "$fixture/candidate.json"; }
hold() { if check; then echo 'unsafe candidate admitted' >&2; exit 1; fi; }
check
jq -e '.mode=="redundant" and .fileId==21' "$fixture/candidate.json" >/dev/null
original="$item"
# Mixed warnings, missing file, wrong IDs, partial packs, tags and policy mismatch.
item=$(jq '.statusMessages[0].messages += ["Access denied"]' <<<"$original"); hold
item=$(jq '.statusMessages[0].messages=["Custom Format requires manual review"]' <<<"$original"); hold
item="$original"; fixture_episode=$(jq '.episodeFileId=0' <<<"$fixture_episode"); hold
fixture_episode=$(jq '.episodeFileId=21|.id=12' <<<"$fixture_episode"); hold
fixture_episode=$(jq '.id=11' <<<"$fixture_episode"); fixture_series=$(jq '.tags=[9]' <<<"$fixture_series"); hold
fixture_series=$(jq '.tags=[]|.monitored=false' <<<"$fixture_series"); hold
fixture_series=$(jq '.monitored=true|.seasons[0].monitored=false' <<<"$fixture_series"); hold
fixture_series=$(jq '.seasons[0].monitored=true' <<<"$fixture_series")
item=$(jq '.title="Show.S01E01E02.1080p"' <<<"$original"); hold
item=$(jq '.title="Show.S01.Complete"' <<<"$original"); hold
item="$original"; fixture_history=$(jq '.records += [{downloadId:"abc-123",eventType:"downloadFolderImported",episodeId:11}]|.totalRecords=2' <<<"$fixture_history"); hold
fixture_history='{"totalRecords":1,"records":[{"downloadId":"abc-123","eventType":"grabbed","seriesId":1,"episodeId":11}]}'
api_fail=true; hold; api_fail=false
START_TIME=71000; hold; START_TIME=100000
fixture_file=$(jq '.customFormatScore=-1' <<<"$fixture_file"); hold
fixture_file=$(jq '.customFormatScore=20' <<<"$fixture_file"); fixture_profile=$(jq '.items[0].allowed=false' <<<"$fixture_profile"); hold
fixture_profile=$(jq '.items[0].allowed=true' <<<"$fixture_profile")
# Replacement requires BOTH explicit native minimum rejection and current profile.
fixture_episode=$(jq '.hasFile=false|.episodeFileId=0' <<<"$fixture_episode")
fixture_profile=$(jq '.minFormatScore=50' <<<"$fixture_profile")
item=$(jq '.statusMessages[0].messages=["Custom Formats x have score 10 below Series profile minimum 50"]' <<<"$original")
check; jq -e '.mode=="replace" and .command.episodeIds==[11]' "$fixture/candidate.json" >/dev/null
item=$(jq '.statusMessages[0].messages=["Custom Formats x have score 10 below Series profile minimum 40"]' <<<"$original"); hold
item=$(jq '.statusMessages[0].messages=["Custom Formats x have score 10 below Series profile minimum 50"]' <<<"$original")
fixture_episode=$(jq '.hasFile=true|.episodeFileId=21' <<<"$fixture_episode"); hold
fixture_episode=$(jq '.hasFile=false|.episodeFileId=0' <<<"$fixture_episode")
check
# Two separated stable scans; changed evidence resets; too-close scan not counted.
if policy_observe abc-123 same; then exit 1; fi
START_TIME=100100; if policy_observe abc-123 same; then exit 1; fi
START_TIME=100300; policy_observe abc-123 same
START_TIME=100600; if policy_observe abc-123 changed; then exit 1; fi
# No automatic retry after an uncertain search response. Repeated recovery reads only.
jq --slurpfile c "$fixture/candidate.json" '.actions["abc-123"]=$c[0]+{status:"queue_verified",startedAt:90000,queueVerified:true}' "$POLICY_STATE_FILE" >"$fixture/new"; mv "$fixture/new" "$POLICY_STATE_FILE"
policy_mutate() { printf '%s\n' "$1" >>"$fixture/mutations"; return 1; }
action=$(jq -c '.actions["abc-123"]' "$POLICY_STATE_FILE")
if policy_finish_tracking "$action"; then exit 1; fi
action=$(jq -c '.actions["abc-123"]' "$POLICY_STATE_FILE")
[[ "$(jq -r '.status' <<<"$action")" = search_uncertain ]]
if policy_finish_tracking "$action"; then exit 1; fi
[[ "$(wc -l <"$fixture/mutations" | tr -d ' ')" = 1 ]]
# Existing command recovery must validate exact IDs before declaring success.
policy_update_action abc-123 '{"commandId":42}'
action=$(jq -c '.actions["abc-123"]' "$POLICY_STATE_FILE")
command_result='{"id":42,"name":"EpisodeSearch","status":"completed","body":{"episodeIds":[12]}}'
if policy_finish_tracking "$action"; then exit 1; fi
command_result=$(jq '.body.episodeIds=[11]' <<<"$command_result")
policy_finish_tracking "$action"
jq -e '.actions["abc-123"].status=="done"' "$POLICY_STATE_FILE" >/dev/null
# Radarr follows the same safety checks and targeted movie identity.
fixture_profile=$(jq '.minFormatScore=0' <<<"$fixture_profile")
item=$(jq 'del(.seriesId,.episodeId,.seasonNumber)|.movieId=31|.title="Movie.2026"' <<<"$original")
fixture_history='{"totalRecords":1,"records":[{"downloadId":"abc-123","eventType":"grabbed","movieId":31}]}'
policy_build_candidate Radarr "$item" "$fixture/radarr.json"
jq -e '.mode=="redundant" and .command.movieIds==[31] and .fileId==41' "$fixture/radarr.json" >/dev/null
fixture_movie=$(jq '.hasFile=false|.movieFileId=0' <<<"$fixture_movie"); fixture_profile=$(jq '.minFormatScore=50' <<<"$fixture_profile")
item=$(jq '.statusMessages[0].messages=["Custom Formats x have score 10 below Movie profile minimum 50"]' <<<"$item")
policy_build_candidate Radarr "$item" "$fixture/radarr.json"
jq -e '.mode=="replace"' "$fixture/radarr.json" >/dev/null
printf 'Policy identity, protection, grace, stable evidence and mutation-recovery tests passed\n'
# Native read-back requires BOTH failed/ignored history and queue absence;
# blocklist proof is exact media identity/title/quality/time, not nonexistent ID.
fetch_arr_queue() { printf '%s' "$fixture_queue" >"$4"; }
fixture_queue='{"totalRecords":0,"records":[]}'
fixture_history='{"totalRecords":1,"records":[{"downloadId":"abc-123","eventType":"downloadFailed"}]}'
action=$(jq -c '.actions["abc-123"]' "$POLICY_STATE_FILE")
# Preserve the real verifier while customizing its HTTP source.
eval "$(declare -f api_get | sed '1s/api_get/fixture_base_api_get/')"
api_get() {
  case "$1" in
    */blocklist*) printf '%s' "$fixture_blocklist" >"$3";;
    *) fixture_base_api_get "$@";;
  esac
}
fixture_blocklist=$(jq -n --argjson action "$action" '{records:[{sourceTitle:$action.title,quality:$action.queue.quality,seriesId:$action.parentId,episodeIds:[$action.targetId],date:"1970-01-02T01:00:00.123Z"}]}')
policy_verify_removed Sonarr abc-123 http://sonarr/api/v3 fixture replace
fixture_blocklist=$(jq '.records[0].episodeIds=[12]' <<<"$fixture_blocklist")
if policy_verify_removed Sonarr abc-123 http://sonarr/api/v3 fixture replace; then exit 1; fi
fixture_history=$(jq '.records[0].eventType="downloadIgnored"' <<<"$fixture_history")
policy_verify_removed Sonarr abc-123 http://sonarr/api/v3 fixture redundant
fixture_queue='{"totalRecords":1,"records":[{"downloadId":"abc-123"}]}'
if policy_verify_removed Sonarr abc-123 http://sonarr/api/v3 fixture redundant; then exit 1; fi
# An unflushed intent cannot be published.
( sync() { return 1; }; printf '{"version":1,"actions":{},"observations":{}}' >"$fixture/fail.json"; if policy_publish "$fixture/fail.json" "$fixture/blocked.json"; then exit 1; fi; [[ ! -e "$fixture/blocked.json" ]] )
printf 'Native read-back, blocklist identity, retained queues and failed-flush tests passed\n'
# Replacement follow-up needs a fresh, exact, profile-compliant Arr file.
START_TIME=200000
fixture_episode=$(jq '.hasFile=true|.episodeFileId=21' <<<"$fixture_episode")
fixture_file=$(jq '.dateAdded="10000"|.customFormatScore=60' <<<"$fixture_file")
action=$(jq -c '.actions["abc-123"]' "$POLICY_STATE_FILE")
policy_check_replacement "$action"
jq -e '(.actions["abc-123"].replacementState // "")!="import_verified"' "$POLICY_STATE_FILE" >/dev/null
START_TIME=204000
fixture_file=$(jq '.dateAdded="100000"|.customFormatScore=-1' <<<"$fixture_file")
action=$(jq -c '.actions["abc-123"]' "$POLICY_STATE_FILE")
policy_check_replacement "$action"
jq -e '(.actions["abc-123"].replacementState // "")!="import_verified"' "$POLICY_STATE_FILE" >/dev/null
START_TIME=208000; fixture_file=$(jq '.customFormatScore=60' <<<"$fixture_file")
action=$(jq -c '.actions["abc-123"]' "$POLICY_STATE_FILE")
policy_check_replacement "$action"
jq -e '.actions["abc-123"].replacementProofRuns==1 and (.actions["abc-123"].replacementState // "")!="import_verified"' "$POLICY_STATE_FILE" >/dev/null
START_TIME=208300; action=$(jq -c '.actions["abc-123"]' "$POLICY_STATE_FILE")
policy_check_replacement "$action"
jq -e '.actions["abc-123"].replacementState=="import_verified" and .actions["abc-123"].replacementFileId==21' "$POLICY_STATE_FILE" >/dev/null

# Full scan orchestration: no first-scan mutations, bounded actions, cooldown,
# burst-stop and ambiguous-intent stop across BOTH applications.
policy_report_actions() { :; }
policy_check_replacement() { :; }
record_normalized_issue() { printf '%s\n' "$1" >>"$fixture/notices"; }
runtime_budget_allows_optional_phase() { return 0; }
POLICY_AUTOMATION_ENABLED=true
SONARR_QUEUE_OK=true; RADARR_QUEUE_OK=true; SAB_HISTORY_OK=true; SAB_QUEUE_OK=true
SONARR_QUEUE="$fixture/sonarr.json"; RADARR_QUEUE="$fixture/radarrqueue.json"
printf '{"records":[],"totalRecords":0}' >"$RADARR_QUEUE"
fixture_candidate=$(jq -c '.actions["abc-123"] | del(.status,.startedAt,.commandId,.queueVerified)' "$POLICY_STATE_FILE")
policy_build_candidate() {
  jq --argjson item "$2" --argjson base "$fixture_candidate" '$base + {downloadId:$item.downloadId,queueId:$item.id,queue:$item,sab:($base.sab + {nzo_id:$item.downloadId})}' <<<null >"$3"
}
fetch_arr_queue() { cp "$SONARR_QUEUE" "$4"; }
policy_finish_tracking() {
  if [ "${fixture_ambiguous:-false}" = true ]; then return 1; fi
  policy_update_action "$(jq -r '.downloadId' <<<"$1")" '{"status":"done","queueVerified":true,"commandId":42}'
}
policy_mutate() { printf '%s %s\n' "$1" "$2" >>"$fixture/mutations"; }
reset_scan() {
 printf '{"version":1,"actions":{},"observations":{}}' >"$POLICY_STATE_FILE"
 : >"$fixture/mutations"; : >"$fixture/notices"
 jq -n '{records:[range(1;4)|{id:.,downloadId:("job-"+tostring),statusMessages:[{messages:["Not an upgrade for existing file"]}]}],totalRecords:3}' >"$SONARR_QUEUE"
}
reset_scan
START_TIME=300000
process_policy_remediation; [[ ! -s "$fixture/mutations" ]]
START_TIME=300300
process_policy_remediation
# Candidate mode replace, all three share target11: exactly one rejection,
# then target cooldown prevents another replacement for the same episode.
[[ "$(wc -l <"$fixture/mutations" | tr -d ' ')" = 1 ]]
grep -q 'removeFromClient=false&blocklist=true&skipRedownload=true' "$fixture/mutations"
START_TIME=300600; process_policy_remediation
[[ "$(wc -l <"$fixture/mutations" | tr -d ' ')" = 1 ]]
# Six simultaneous policy warnings stop before recording any intent.
reset_scan
jq '.records += [.records[]|.id+=10|.downloadId+="x"] | .totalRecords=6' "$SONARR_QUEUE" >"$fixture/new"; mv "$fixture/new" "$SONARR_QUEUE"
process_policy_remediation
[[ ! -s "$fixture/mutations" ]]; grep -q POLICY:burst "$fixture/notices"
# An uncertain first mutation halts the whole scan, not merely the Sonarr loop.
reset_scan; fixture_ambiguous=true
START_TIME=400000; process_policy_remediation
START_TIME=400300; process_policy_remediation
[[ "$(wc -l <"$fixture/mutations" | tr -d ' ')" = 1 ]]
START_TIME=400600; process_policy_remediation
[[ "$(wc -l <"$fixture/mutations" | tr -d ' ')" = 1 ]]
# Malformed but syntactically valid command journal cannot dispatch commands.
jq '.actions["job-1"].command={name:"DeleteEverything"}' "$POLICY_STATE_FILE" >"$fixture/new"; mv "$fixture/new" "$POLICY_STATE_FILE"
if policy_validate_journal "$POLICY_STATE_FILE"; then exit 1; fi
printf 'Whole-scan two-scan grace, exact target cooldown, burst and uncertain-mutation stop tests passed\n'
# Redundant handling shares global per-run and rolling-day budgets.
fixture_ambiguous=false
fixture_candidate=$(jq '.mode="redundant"' <<<"$fixture_candidate")
reset_scan
START_TIME=500000; process_policy_remediation
START_TIME=500300; process_policy_remediation
[[ "$(wc -l <"$fixture/mutations" | tr -d ' ')" = 2 ]]
START_TIME=500600; process_policy_remediation
[[ "$(wc -l <"$fixture/mutations" | tr -d ' ')" = 3 ]]
jq '.records=[range(4;7)|{id:.,downloadId:("job-"+tostring),statusMessages:[{messages:["Not an upgrade for existing file"]}]}] | .totalRecords=3' "$SONARR_QUEUE" >"$fixture/new"; mv "$fixture/new" "$SONARR_QUEUE"
START_TIME=500900; process_policy_remediation
START_TIME=501200; process_policy_remediation
[[ "$(wc -l <"$fixture/mutations" | tr -d ' ')" = 4 ]]
START_TIME=501500; process_policy_remediation
[[ "$(wc -l <"$fixture/mutations" | tr -d ' ')" = 4 ]]
printf 'Shared two-per-run and four-per-day mutation limits passed\n'

# Rejected attempts close as policy dispositions, never fabricated imports;
# the same bound SAB identity distinguishes expected retention from an orphan.
STATE_FILE="$fixture/monitor.json"
printf '{"downloadLedger":{"job-1":{"arrImportedAt":0}}}' >"$STATE_FILE"
save_state() { cp "$1" "$STATE_FILE"; }
apply_policy_ledger_dispositions
jq -e '.downloadLedger["job-1"].arrIgnoredAt>0 and .downloadLedger["job-1"].arrImportedAt==0 and .downloadLedger["job-1"].policyDisposition=="redundant"' "$STATE_FILE" >/dev/null
fixture_sab=$(jq -c '.actions["job-1"].sab' "$POLICY_STATE_FILE")
policy_disposition_matches Sonarr job-1 "$fixture_sab"
fixture_sab=$(jq '.storage="/downloads/different"' <<<"$fixture_sab")
if policy_disposition_matches Sonarr job-1 "$fixture_sab"; then exit 1; fi
printf 'Rejected-flow disposition and exact SAB-bound retained-payload reporting passed\n'
