#!/usr/bin/env bash
# Reuse the isolated native API/filesystem fixture, never real apps or media.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/tests/media_integrity_recovery_test.sh"
RECOVERY_DEADLINE=0
make_job() {
 setup Radarr
 jq -c '.files|to_entries[0]' "$TMP_DIR/state.json" >"$fixture/candidate"
 recovery_plan "$fixture/candidate" "$fixture/plan"
 id=$(jq -c '[.path,.identity]' "$fixture/plan"|sha256sum|awk '{print $1}')
 recovery_update '.actions[$id]=$p[0]' --arg id "$id" --slurpfile p "$fixture/plan"
 cp "$fixture/plan" "$fixture/job"
}
# Unchanged writes preserve the current inode; a prior validated generation stays.
make_job
before=$(stat -c '%i:%Y' "$RECOVERY_FILE")
recovery_update '.'
[[ $(stat -c '%i:%Y' "$RECOVERY_FILE") == "$before" ]]
recovery_document_valid "${RECOVERY_FILE%.json}.previous.json"
if recovery_update '.actions[].status="unknown"';then echo 'Invalid candidate journal published' >&2;exit 1;fi
[[ $(stat -c '%i:%Y' "$RECOVERY_FILE") == "$before" ]]
# An independently replaced file is verified without claiming our grab did it.
replacement=true;printf independent-healthy-replacement >"$MEDIA_HOST_ROOT/$relative"
recovery_observe_external "$id" "$fixture/job"
jq -e 'all(.actions[];.status=="verifying" and .resolutionSource=="external")' "$RECOVERY_FILE" >/dev/null
recovery_file_tool identity "$relative" >"$fixture/current-identity"
jq --arg path "$relative" --slurpfile i "$fixture/current-identity" --argjson now "$(date +%s)" '.files[$path]={identity:$i[0],verifiedAt:$now,coverage:"all_planned_segments_decoded"}' "$TMP_DIR/state.json" >"$fixture/new";mv "$fixture/new" "$TMP_DIR/state.json"
recovery_observe_external "$id" "$fixture/job"
jq -e 'all(.actions[];.status=="recovered" and .resolutionSource=="external")' "$RECOVERY_FILE" >/dev/null
! rg -q '^POST|^DELETE|^PUT' "$requests"
# Native unmonitoring cancels only with the exact original still present.
make_job
eval "$(declare -f recovery_api|sed '1s/recovery_api/base_fixture_api/')"
recovery_api() {
 base_fixture_api "$@" || return $?
 if [[ "${fixture_unmonitor:-false}" == true && "$1" == GET && "$2" == /movie/10 ]];then jq '.monitored=false' "$3" >"$fixture/changed";mv "$fixture/changed" "$3";fi
}
fixture_unmonitor=true
recovery_observe_external "$id" "$fixture/job"
jq -e 'all(.actions[];.status=="cancelled")' "$RECOVERY_FILE" >/dev/null
[[ $(cat "$MEDIA_HOST_ROOT/$relative") == original-damaged ]]
fixture_unmonitor=false
# Proven native archive failure schedules one alternative after a cooldown.
make_job
jq --arg id "$id" '.actions[$id] += {status:"downloading",selected:{guid:"failed-guid",title:"Failed.Release"},downloadId:"failed-nzo",grabSentAt:100,attempts:[{at:100,guid:"failed-guid",title:"Failed.Release"}]}' "$RECOVERY_FILE" >"$fixture/new";mv "$fixture/new" "$RECOVERY_FILE"
jq --arg id "$id" '.actions[$id]' "$RECOVERY_FILE" >"$fixture/job"
printf '{"records":[{"eventType":"downloadFailed","downloadId":"failed-nzo","movieId":10,"data":{"message":"Repair failed: missing articles and CRC errors"}}]}' >"$fixture/failed-history"
recovery_prepare_retry "$id" "$fixture/job" "$fixture/failed-history"
jq -e --argjson now "$(date +%s)" 'all(.actions[];.status=="retry_wait" and .retryAt>$now and .failedReleases[0].guid=="failed-guid" and .downloadId==null)' "$RECOVERY_FILE" >/dev/null
# Limit reached and storage/manual errors never authorize alternatives.
jq '.attempts += [{at:200,guid:"second"}]' "$fixture/job" >"$fixture/limited"
if recovery_prepare_retry "$id" "$fixture/limited" "$fixture/failed-history";then exit 1;fi
printf '{"records":[{"eventType":"downloadFailed","downloadId":"failed-nzo","movieId":10,"data":{"message":"Unpack failed: disk space unavailable"}}]}' >"$fixture/failed-history"
if recovery_prepare_retry "$id" "$fixture/job" "$fixture/failed-history";then exit 1;fi
! rg -q '^POST|^DELETE|^PUT' "$requests"
# Native retention sets the deadline from actual import time, not polling time.
make_job
recovery_update '.actions[$id].importedAt=200000' --arg id "$id"
recovery_retention "$id" "$fixture/job"
jq -e 'all(.actions[];.binRetentionDays==2 and .verificationDeadlineAt==372800 and .verificationAttentionAt<.verificationDeadlineAt)' "$RECOVERY_FILE" >/dev/null
# More than four waiting files rotate by actual decoder attempts; evidence gets
# one reserved slot without a whole-library inventory.
jq --argjson now "$(date +%s)" '.actions|to_entries[0].value as $job|{schema:1,workflow:"arr-native",actions:([range(0;6)|{key:(("a"*63)+tostring),value:($job+{status:"verifying",replacementPaths:[("movies/file"+tostring+".mkv")],verificationDeadlineAt:($now+172800)})}]|from_entries)}' "$RECOVERY_FILE" >"$fixture/schedule-journal"
cp "$fixture/schedule-journal" "$RECOVERY_FILE"
jq -n '{schema:1,files:([range(0;6)|{key:("movies/file"+tostring+".mkv"),value:{identity:["1","2","3","4","5"],lastAttemptAt:(100+.)}}]|from_entries)}' >"$TMP_DIR/state.json"
recovery_schedule
jq -e '.paths==["movies/file0.mkv","movies/file1.mkv","movies/file2.mkv","movies/file3.mkv"]' "$TMP_DIR/recovery-schedule.json" >/dev/null
jq '.files |= with_entries(if .value.lastAttemptAt<104 then .value.lastAttemptAt=1000 else . end)' "$TMP_DIR/state.json" >"$fixture/new";mv "$fixture/new" "$TMP_DIR/state.json"
recovery_schedule
jq -e '.paths[:2]==["movies/file4.mkv","movies/file5.mkv"]' "$TMP_DIR/recovery-schedule.json" >/dev/null
printf 'Validated journal/no-op writes, external recovery, cancellation, bounded retry vetoes, native retention and fair verification rotation passed\n'
