#!/bin/bash
# Saved-state coverage only: no filesystem media lookup or Docker invocation.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/media_integrity_audit.sh"
fixture=$(mktemp -d);trap 'rm -rf "$fixture"' EXIT
TMP_DIR="$fixture";now=$(date +%s)
jq -n --argjson now "$now" '{schema:1,files:{
 "movies/Done/a.mkv":{verifiedAt:$now,verificationPolicy:2,coverage:"all_planned_segments_decoded",lastAttemptAt:$now},
 "movies/Partial/a.mkv":{offset:600,probeAt:$now,lastAttemptAt:$now},
 "movies/Probe/a.mkv":{probeAt:$now,lastAttemptAt:$now},
 "series/Pending/Season 01/a.mkv":{},
 "series/Blocked/Season 01/a.mkv":{lastAttemptAt:$now,notBefore:($now+3600),issue:{kind:"read_error"}},
 "formula1/Old/a.mkv":{verifiedAt:($now-200*86400),verificationPolicy:2,coverage:"all_planned_segments_decoded",lastAttemptAt:($now-200*86400)}
 },lastActivity:{attempt:{path:"series/Blocked/Season 01/a.mkv",epoch:$now,kind:"read_error",nextOffset:0},success:{path:"movies/Partial/a.mkv",epoch:$now,kind:"decode_range_passed",nextOffset:600,duration:7200}}}' >"$TMP_DIR/state.json"
jq -n --argjson now "$now" '{startedAt:$now,mode:"scan",uniqueFilesAttempted:3,uniqueFilesOpened:2,uniqueMetadataPassed:1,uniqueFilesDecoded:1,uniqueFilesPartiallyDecoded:1,uniqueFilesCompleted:0,inventoryByLibrary:{movies:{status:"complete",files:3},series:{status:"partial",files:2},formula1:{status:"not_started",files:0}}}' >"$TMP_DIR/stats.json"
coverage_summary
jq -e '.overall=={total:6,verified:2,partial:1,metadataOnly:1,attemptedUnverified:1,untouched:1,deferred:1,blocked:1,periodicDue:1,workRemaining:5,awaitingVerification:4}' "$TMP_DIR/coverage-summary.json" >/dev/null
jq -e '(.libraries[]|select(.name=="series")|.inventory.status)=="partial" and (.directories|.total==6 and .complete==1 and .inProgress==4 and .untouched==1 and .pending==5 and .blocked==1 and .deferred==1) and .run.uniqueFilesAttempted==3 and (.lastActivity.attempt.path|contains("Blocked")) and (.body|contains("next saved offset=600 s of 7200 s"))' "$TMP_DIR/coverage-summary.json" >/dev/null
# Large folder inventories produce bounded examples, never a huge email.
jq '.files=(reduce range(0;1000) as $i ({}; .["movies/Folder\($i)/file.mkv"]={})) | del(.lastActivity)' "$TMP_DIR/state.json" >"$fixture/new";mv "$fixture/new" "$TMP_DIR/state.json"
printf '{}' >"$TMP_DIR/stats.json"
coverage_summary
jq -e '.directories.total==1000 and (.directories.pendingExamples|length)==3 and .run.uniqueFilesAttempted==null and (.body|contains("not recorded")) and (.body|contains("not yet recorded")) and (.body|length)<7000' "$TMP_DIR/coverage-summary.json" >/dev/null
printf '{"schema":1,"files":{}}' >"$TMP_DIR/state.json"
coverage_summary
jq -e '.overall.total==0 and .directories.total==0 and (.libraries|length)==3' "$TMP_DIR/coverage-summary.json" >/dev/null
printf 'Disjoint coverage buckets, periodic overlap, library inventory scope, saved last checks, bounded folder examples and legacy/empty state passed\n'
