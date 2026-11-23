#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arr-reconciliation.XXXXXX")
source <(awk '/^# LOCK$/{exit} {print}' "$repo_root/user_script/arr_health_activity.sh")
trap - INT TERM HUP
trap 'rm -rf -- "$test_root"' EXIT
TMP_DIR="$test_root"
STATE_FILE="$test_root/state.json"
DOWNLOAD_LEDGER_RECONCILIATION_RESULTS_FILE="$test_root/results.jsonl"
START_TIME=100000
DOWNLOAD_LEDGER_RECONCILIATION_FAILED_COUNT=0
arr_reconciliation_connection() { printf 'http://fixture/api/v3\tfixture-key\n'; }
date_to_epoch() { printf '%s\n' "$1"; }
api_get() {
    if [ "${fail_api:-false}" = true ]; then
        API_LAST_HTTP_CODE=503 API_LAST_ENDPOINT=fixture API_LAST_ERROR=unavailable
        return 1
    fi
    case "$1" in
        */episode/11) printf '%s\n' "$episode" >"$3" ;;
        */episodefile/21) printf '%s\n' "$episode_file" >"$3" ;;
        */movie/31) printf '%s\n' "$movie" >"$3" ;;
        */moviefile/41) printf '%s\n' "$movie_file" >"$3" ;;
        *) return 1 ;;
    esac
}
save_state() { cp "$1" "$STATE_FILE"; }
assert_result() { jq -e "$1" "$DOWNLOAD_LEDGER_RECONCILIATION_RESULTS_FILE" >/dev/null; }
check_record() {
    : >"$DOWNLOAD_LEDGER_RECONCILIATION_RESULTS_FILE"
    record_arr_database_file_reconciliation id "$1" "$record"
}
episode='{"id":11,"seriesId":1,"seasonNumber":3,"episodeNumber":2,"hasFile":true,"episodeFileId":21}'
episode_file='{"id":21,"seriesId":1,"seasonNumber":3,"path":"/media/episode.mkv","dateAdded":"90000"}'
movie='{"id":31,"hasFile":true,"movieFileId":41}'
movie_file='{"id":41,"movieId":31,"path":"/media/movie.mkv","dateAdded":"90000"}'
record='{"sabQueuedAt":80000,"targets":{"episode:11":{"type":"episode","episodeId":11,"seriesId":1,"seasonNumber":null,"episodeNumber":null}}}'
check_record Sonarr
assert_result '.evidenceFound == true'
# Two successful independent results required; API failure freezes candidate.
printf '{"downloadLedger":{"id":{}}}\n' >"$STATE_FILE"
update_download_reconciliation_state
jq -e '.downloadLedger.id.reconciliationCandidateRuns == 1 and (.downloadLedger.id.arrReconciledAt // 0) == 0' "$STATE_FILE" >/dev/null
fail_api=true
if check_record Sonarr; then echo 'API failure unexpectedly succeeded' >&2; exit 1; fi
update_download_reconciliation_state
jq -e '.downloadLedger.id.reconciliationCandidateRuns == 1 and .downloadLedger.id.reconciliationLastScanOk == false and .downloadLedger.id.reconciliationLastReason == "Sonarr episode API check failed"' "$STATE_FILE" >/dev/null
fail_api=false
START_TIME=100300
check_record Sonarr
update_download_reconciliation_state
jq -e '.downloadLedger.id.arrReconciledAt == 100300' "$STATE_FILE" >/dev/null
# Never substitute a different episode or overwrite conflicting numbering.
episode=$(jq '.id=12' <<<"$episode")
check_record Sonarr; assert_result '.evidenceFound == false'
episode=$(jq '.id=11' <<<"$episode")
record=$(jq '.targets["episode:11"].seasonNumber=2' <<<"$record")
check_record Sonarr; assert_result '.evidenceFound == false'
record=$(jq '.targets["episode:11"].seasonNumber=null' <<<"$record")
episode_file=$(jq '.dateAdded="10000"' <<<"$episode_file")
check_record Sonarr; assert_result '.evidenceFound == false and (.evidence | contains("cannot be tied"))'
# A known changed file ID is valid alternative evidence.
record=$(jq '.targets["episode:11"] += {preFileKnown:true,preFileId:20}' <<<"$record")
check_record Sonarr; assert_result '.evidenceFound == true'
episode_file=$(jq '.id=22' <<<"$episode_file")
check_record Sonarr; assert_result '.evidenceFound == false'
record='{"sabQueuedAt":80000,"targets":{"movie:31":{"type":"movie","movieId":31}}}'
check_record Radarr; assert_result '.evidenceFound == true'
movie=$(jq '.id=32' <<<"$movie")
check_record Radarr; assert_result '.evidenceFound == false'
movie=$(jq '.id=31' <<<"$movie")
movie_file=$(jq '.dateAdded="10000"' <<<"$movie_file")
check_record Radarr; assert_result '.evidenceFound == false'
record='{"sabQueuedAt":80000,"targets":{}}'
check_record Sonarr; assert_result '.evidenceFound == false and (.evidence | contains("No exact"))'
update_download_reconciliation_state
jq -e '.downloadLedger.id.reconciliationLastReason | contains("No exact")' "$STATE_FILE" >/dev/null
# Review needs a recent successful check, never masks completed-import failures.
record='{"reconciliationLastScanOk":true,"reconciliationLastCheckedAt":100300}'
download_ledger_needs_review "$record" DOWNLOAD_FLOW_SAB_VANISHED 800
download_ledger_needs_review "$record" DOWNLOAD_FLOW_NOT_REACHED_SAB 800
if download_ledger_needs_review "$record" DOWNLOAD_FLOW_IMPORT_MISSING 800; then exit 1; fi
if download_ledger_needs_review "$record" DOWNLOAD_FLOW_SAB_VANISHED 60; then exit 1; fi
if download_ledger_needs_review '{"reconciliationLastScanOk":false}' DOWNLOAD_FLOW_SAB_VANISHED 800; then exit 1; fi
SONARR_QUEUE="$test_root/queue.json" RADARR_QUEUE="$test_root/queue.json"
printf '{"records":[{"downloadId":"ID"}]}\n' >"$SONARR_QUEUE"
download_ledger_arr_queue_contains Sonarr id
download_ledger_arr_queue_contains Radarr id
SONARR_AUDIT_OK=true SONARR_QUEUE_OK=true SAB_HISTORY_OK=true SAB_QUEUE_OK=false
if download_ledger_can_evaluate Sonarr; then exit 1; fi
SAB_QUEUE_OK=true RADARR_AUDIT_OK=true RADARR_QUEUE_OK=true
download_ledger_can_evaluate Sonarr
download_ledger_can_evaluate Radarr
printf 'Arr exact-identity, freshness, two-scan, diagnostics and review guard tests passed\n'
# Exercise the full shared issue classifier, including current SAB/Arr evidence.
date() { if [ "$*" = '+%s' ]; then printf '%s\n' "$START_TIME"; else command date "$@"; fi; }
SEEN_ISSUES_FILE="$test_root/seen" SAB_PRIMARY_DOWNLOADS_FILE="$test_root/sab-primary"
: >"$SEEN_ISSUES_FILE"; : >"$SAB_PRIMARY_DOWNLOADS_FILE"
printf '{"records":[]}\n' >"$SONARR_QUEUE"
record_normalized_issue() { printf '%s\t%s\t%s\n' "$2" "$4" "$5" >>"$test_root/classifications"; }
for app in Sonarr Radarr; do
    jq -n --arg app "$app" --argjson now "$START_TIME" '{downloadLedger:{id:{id:"id",app:$app,flowEnrolled:true,sabQueuedAt:1000,sabQueueLastSeen:1000,reconciliationLastScanOk:true,reconciliationLastCheckedAt:$now}}}' >"$STATE_FILE"
    : >"$test_root/classifications"
    process_download_ledger_issues
    grep -q "$app"$'\tDOWNLOAD_FLOW_REVIEW_REQUIRED\tWARNING' "$test_root/classifications"
    printf 'id\n' >"$SAB_PRIMARY_DOWNLOADS_FILE"
    : >"$test_root/classifications"
    process_download_ledger_issues
    test ! -s "$test_root/classifications"
    : >"$SAB_PRIMARY_DOWNLOADS_FILE"
    jq '.downloadLedger.id.sabCompletedAt=1000' "$STATE_FILE" >"$test_root/edit.json"
    cp "$test_root/edit.json" "$STATE_FILE"
    process_download_ledger_issues
    grep -q 'DOWNLOAD_FLOW_IMPORT_MISSING'$'\tERROR' "$test_root/classifications"
done
printf 'Shared Sonarr/Radarr/SAB classifier integration tests passed\n'
