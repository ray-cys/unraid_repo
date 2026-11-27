#!/bin/bash
# Pure PHP/state fixtures; never contacts Docker, APIs, SMTP or production paths.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd);tmp=$(mktemp -d /tmp/job-weekly-test.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
now=2000000
cat > "$tmp/failure.json" <<'JSON'
{"id":"container:1:100:200","started":100,"finished":1999000,"result":"failed","complete":true,"source":"scheduler /cron.sh","findings":[{"severity":"ERROR","message":"radarr: invalid custom format; token=private-secret https://user:pass@example.net/?token=hidden"}],"counts":{}}
JSON
jq '.id="container:2:300:400"|.started=1999100|.finished=1999200|.result="success"|.findings=[]' "$tmp/failure.json" > "$tmp/success.json"
state='null'
reduce(){
 local observations="${2:-}";[[ -n "$observations" ]] || observations='{}'
 jq -n --argjson now "$now" --argjson old "$state" --slurpfile fail "$tmp/failure.json" --slurpfile ok "$tmp/success.json" --argjson records "$1" --argjson observations "$observations" \
 '{now:$now,profile:"recyclarr",paused:false,observations:$observations,job:{scanned:$now,finished:1999200,result:"success",evidenceSource:"dockerlogs",weeklyReview:$old,logState:{reviewRuns:$records}}}' > "$tmp/input.json"
 php "$repo/tools/job_weekly_review.php" < "$tmp/input.json" > "$tmp/output.json"
 state=$(cat "$tmp/output.json")
}
# Use actual array payloads, preserving events that failed and recovered between reports.
records=$(jq -sc '.' "$tmp/failure.json" "$tmp/success.json")
reduce "$records"
jq -e '.schema==1 and (.runs|length)==2 and (.issues|length)==1 and all(.issues[];.resolvedAt==1999200 and (.recoveries|length)==1)' "$tmp/output.json" >/dev/null
! grep -q 'private-secret\|user:pass\|token=hidden' "$tmp/output.json"
printf '[PASS] Failure and native recovery retained together; evidence redacted\n'
reduce "$records"
jq -e 'all(.issues[];.occurrences==1 and (.recoveries|length)==1)' "$tmp/output.json" >/dev/null
printf '[PASS] Overlap/repeated scans do not duplicate runs, occurrences or recoveries\n'
# An incomplete clean banner cannot clear a failure.
state=null;record=$(jq -c '[.]' "$tmp/failure.json");reduce "$record"
record=$(jq -c '[.complete=false]' "$tmp/success.json");reduce "$record"
jq -e 'all(.issues[];.resolvedAt==0)' "$tmp/output.json" >/dev/null
printf '[PASS] Incomplete evidence cannot resolve a job failure\n'
# Old late-arriving reasons are historically resolved by an already proven newer clean run.
state=null;record=$(jq -c '[.]' "$tmp/success.json");reduce "$record"
record=$(jq -c '[.]' "$tmp/failure.json");reduce "$record"
jq -e 'all(.issues[];.resolvedAt==1999200)' "$tmp/output.json" >/dev/null
printf '[PASS] Late historical failures do not reopen a verified clean outcome\n'
# New recurrence after a clean outcome preserves earlier recovery history.
record=$(jq -c '[.id="new:3"|.finished=1999500]' "$tmp/failure.json");reduce "$record"
jq -e 'all(.issues[];.resolvedAt==0 and .firstSeen==1999500 and (.recoveries|length)==1)' "$tmp/output.json" >/dev/null
printf '[PASS] Recurrence remains actionable and retains the preceding recovery\n'
# Operational deadlines require a current, valid subsequent watchdog observation.
ops='{"recyclarr:job-overdue":{"active":true,"severity":"CRITICAL","message":"Scheduled sync overdue","first":1999700}}'
reduce '[]' "$ops"
jq -e 'any(.issues[];.kind=="operational" and .resolvedAt==0)' "$tmp/output.json" >/dev/null
reduce '[]' '{}'
jq -e 'any(.issues[];.kind=="operational" and .resolvedAt==2000000)' "$tmp/output.json" >/dev/null
printf '[PASS] Deadline recovery requires fresh valid evidence\n'
# The deployed script embeds PHP on fd 3, with JSON on stdin. Exercise that
# exact path and prove a bad optional catalogue does not abort availability.
source "$repo/user_script/docker_service_watchdog.sh"
TMP_DIR="$tmp/work";mkdir "$TMP_DIR";STATE_DIR="$tmp";STATE_WORK="$tmp/watchdog-state.json";LOG_FILE="$tmp/watchdog.log";NOW=$now
EFFECTIVE_SPECS=('recyclarr||always|0');PROFILE_BY_NAME[recyclarr]=recyclarr
jq -n --argjson now "$now" '{version:2,services:{},recovery:{},observations:{},notification:{issues:{}},jobs:{recyclarr:{firstSeen:1,started:0,finished:1999200,success:1999200,scanned:$now,result:"success",history:[],logState:{},runLog:{},evidenceSource:"dockerlogs"}}}' > "$STATE_WORK"
update_weekly_job_reviews
jq -e '.jobs.recyclarr.weeklyReview.schema==1 and .jobs.recyclarr.weeklyReview.profile=="recyclarr" and .jobs.recyclarr.weeklyReviewError==0' "$STATE_WORK" >/dev/null
state_valid "$STATE_WORK"
printf '[PASS] Standalone embedded reducer works with existing watchdog state validation\n'
mutate '.jobs.recyclarr.weeklyReview.schema=99'
update_weekly_job_reviews
jq -e '.jobs.recyclarr.weeklyReview.schema==99 and .jobs.recyclarr.weeklyReviewError==2000000 and .observations["recyclarr:weekly-review-evidence"].active' "$STATE_WORK" >/dev/null
printf '[PASS] Invalid optional review state is retained and reported without stopping availability checks\n'
# Keep history over Linux's per-argument limit on stdin/files, not --argjson.
large=$(jq -nc --argjson now "$NOW" '{containerId:"large-container",start:1,iteration:"1",failed:false,seen:true,open:false,reviewRuns:[range(0;30)|{id:("run"+tostring),started:1,finished:($now-100),result:"failed",complete:true,findings:[range(0;10)|{severity:"ERROR",message:("x"*700)}]}]}')
jq -n --argjson now "$NOW" '{version:2,services:{},recovery:{},observations:{},notification:{issues:{}},jobs:{recyclarr:{firstSeen:$now,started:1,finished:($now-10),success:($now-10),result:"success",scanned:$now,history:[],logState:{},runLog:{}}}}' > "$STATE_WORK"
printf '%s' "$large" > "$tmp/large-log-state.json"
mutate --slurpfile large "$tmp/large-log-state.json" '.jobs.recyclarr.logState=$large[0]'
docker_cmd(){ [[ "$1" != logs ]] || return 0;return 1; }
check_job recyclarr '[{"Id":"large-container"}]'
jq -e '(.jobs.recyclarr.logState.reviewRuns|length)==30' "$STATE_WORK" >/dev/null
state_valid "$STATE_WORK"
printf '[PASS] Scheduler history above 128 KiB remains file-backed and valid\n'
