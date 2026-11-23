#!/usr/bin/env bash
# Linux per-argument limits must not constrain the compact maintenance catalogue.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/watchdog-large-state.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
source "$repo/user_script/docker_service_watchdog.sh"
TMP_DIR="$fixture"; STATE_WORK="$fixture/state.json"; LOG_FILE="$fixture/run.log"
NOW=$(date +%s)
printf '{"version":2,"jobs":{},"observations":{}}' >"$STATE_WORK"
JOB_RULES=('kometa|6|24|runlog:/config/logs/meta.log')
read_native_run_log() {
 jq -n --argjson now "$NOW" '{reader:{version:1,parserVersion:3,padding:("x"*300000)},started:($now-120),finished:($now-60),success:($now-60),backlog:false,incomplete:false,findings:{},activeFatal:{},result:"success"}'
}
check_job kometa '[{"Id":"fixture"}]'
check_job kometa '[{"Id":"fixture"}]'
jq -e '.jobs.kometa.runLog.padding|length==300000' "$STATE_WORK" >/dev/null
printf '300 KB native-reader state survives initial and repeated job updates without command-line JSON arguments\n'
