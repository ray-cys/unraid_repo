#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/kometa-weekly.XXXXXX); fixture=$(realpath "$fixture")
trap 'rm -rf -- "$fixture"' EXIT
(
source "$repo/user_script/kometa_preflight.sh"
STATE_DIR="$fixture/preflight"; mkdir "$STATE_DIR"
WATCHDOG_STATE_FILE="$fixture/watchdog.json"
NOTIFY_BIN="$fixture/notify"
now=$(date +%s)
jq -n --argjson now "$now" '{jobs:{kometa:{runLog:{gap:false,backlog:false,maintenance:{schema:1,trackingSince:($now-86400),lastScanAt:$now,runs:[],issues:{one:{id:"one",message:"YAML Error: duplicate key",context:{file:"config/collections/test.yml"},severity:"ERROR",firstSeen:($now-100),lastSeen:($now-10),affectedRuns:[],resolvedAt:0}}}}}}}' >"$WATCHDOG_STATE_FILE"
jq -n --argjson now "$now" '{schema:1,scheduleKey:"Asia/Singapore/7/11/55",nextDue:($now-1),lastCheckedAt:($now-20)}' >"$STATE_DIR/weekly-report-state.json"
# Python runs locally in the fixture; real deployment runs it read-only in Kometa.
timeout() { [[ ${1:-} != --kill-after=* ]] || shift; shift; "$@"; }
docker() { [[ "$1" == exec && "$2" == -i ]]; shift 3; "$@"; }
printf '#!/bin/sh\nexit 1\n' >"$NOTIFY_BIN"; chmod 755 "$NOTIFY_BIN"
before=$(sha256sum "$STATE_DIR/weekly-report-state.json")
if weekly_kometa_report false; then echo 'Failed notification accepted' >&2; exit 1; fi
[[ "$before" == "$(sha256sum "$STATE_DIR/weekly-report-state.json")" ]]
weekly_kometa_report true >"$fixture/preview.txt"
[[ "$before" == "$(sha256sum "$STATE_DIR/weekly-report-state.json")" ]]
grep -q 'Recommended action:' "$fixture/preview.txt"
printf '#!/bin/sh\nprintf "sent\\n" >>"%s/calls"\n' "$fixture" >"$NOTIFY_BIN"
weekly_kometa_report false
weekly_kometa_report false
[[ $(wc -l <"$fixture/calls") == 1 ]]
jq -e --argjson now "$now" '.nextDue>$now and .lastCheckedAt>=$now' "$STATE_DIR/weekly-report-state.json" >/dev/null
printf 'Failed delivery retries without deadline advancement; preview is read-only; successful delivery occurs once\n'
)
(
source "$repo/user_script/docker_service_watchdog.sh"
TMP_DIR="$fixture/tmp"; STATE_DIR="$fixture/watchdog"; mkdir "$TMP_DIR" "$STATE_DIR"
STATE_WORK="$STATE_DIR/state.json"; LOG_FILE="$STATE_DIR/log"
KOMETA_WEEKLY_STATE="$fixture/preflight/weekly-report-state.json"; NOW=$(date +%s)
NOTIFY_BIN="$fixture/watchdog-notify"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/watchdog-mails"\n' "$fixture" >"$NOTIFY_BIN"; chmod 755 "$NOTIFY_BIN"
jq -n '{version:2,observations:{"kometa:job-errors":{active:true,severity:"WARNING",message:"routine YAML error",first:0,bad:2},"kometa:job-failed":{active:true,severity:"CRITICAL",message:"fatal startup",first:0,bad:2}},notification:{issues:{}}}' >"$STATE_WORK"
notify_changes
if grep -q 'kometa:job-errors' "$fixture/watchdog-mails"; then exit 1; fi
grep -q 'kometa:job-failed' "$fixture/watchdog-mails"
jq -e '.observations["kometa:job-errors"].active==true' "$STATE_WORK" >/dev/null
jq --argjson now "$NOW" '.lastCheckedAt=($now-9*3600)' "$KOMETA_WEEKLY_STATE" >"$TMP_DIR/stale"; mv "$TMP_DIR/stale" "$KOMETA_WEEKLY_STATE"
notify_changes
grep -q 'kometa:job-errors' "$fixture/watchdog-mails"
count=$(wc -l <"$fixture/watchdog-mails")
jq --argjson now "$NOW" '.lastCheckedAt=$now' "$KOMETA_WEEKLY_STATE" >"$TMP_DIR/fresh"; mv "$TMP_DIR/fresh" "$KOMETA_WEEKLY_STATE"
notify_changes
[[ $(wc -l <"$fixture/watchdog-mails") == "$count" ]]
printf 'Routine findings delegated only with a healthy handoff; fatal alerts retained; stale handoff restores immediate alerts without false recovery email\n'
)
