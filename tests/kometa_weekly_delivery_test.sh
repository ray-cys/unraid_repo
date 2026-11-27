#!/usr/bin/env bash
set -euo pipefail
PYTHON_BIN="${PYTHON_BIN:-python3}"
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/kometa-weekly.XXXXXX); fixture=$(realpath "$fixture")
trap 'rm -rf -- "$fixture"' EXIT
(
source "$repo/user_script/media_metadata_audit.sh"
STATE_DIR="$fixture/preflight"; mkdir "$STATE_DIR"
WATCHDOG_STATE_FILE="$fixture/watchdog.json"
METAFUSION_FINDINGS_FILE="$fixture/findings.json"
NOTIFY_BIN="$fixture/notify"
now=$(date +%s)
jq -n --arg stamp "$(date -u +%FT%TZ)" '{schema_version:1,generated_at:$stamp,run:{run_id:"native",status:"completed",finished_at:$stamp},open:[],recently_resolved:[],run_history:[]}' >"$METAFUSION_FINDINGS_FILE"
jq -n --argjson now "$now" '{jobs:{kometa:{runLog:{gap:false,backlog:false,maintenance:{schema:1,trackingSince:($now-86400),lastScanAt:$now,runs:[],issues:{one:{id:"one",message:"YAML Error: duplicate key",context:{file:"config/collections/test.yml"},severity:"ERROR",firstSeen:($now-100),lastSeen:($now-10),affectedRuns:[],resolvedAt:0}}}}}}}' >"$WATCHDOG_STATE_FILE"
jq -n --argjson now "$now" '{schema:1,scheduleKey:"Asia/Singapore/7/11/55",nextDue:($now-1),lastCheckedAt:($now-20)}' >"$STATE_DIR/weekly-report-state.json"
# Python runs locally in the fixture; real deployment runs it read-only in Kometa.
timeout() { [[ ${1:-} != --kill-after=* ]] || shift; shift; "$@"; }
docker() { [[ "$1" == exec && "$2" == -i ]]; shift 3; "$PYTHON_BIN" "${@:2}"; }
printf '#!/bin/sh\nexit 1\n' >"$NOTIFY_BIN"; chmod 755 "$NOTIFY_BIN"
before=$(sha256sum "$STATE_DIR/weekly-report-state.json")
if weekly_media_report false; then echo 'Failed notification accepted' >&2; exit 1; fi
[[ "$before" == "$(sha256sum "$STATE_DIR/weekly-report-state.json")" ]]
[[ -f "$STATE_DIR/weekly-pending-notification.json" ]]
# A newer snapshot cannot replace an undelivered historical resolution/report.
jq '.jobs.kometa.runLog.maintenance.issues.one.message="NEW evidence after failed send"' "$WATCHDOG_STATE_FILE" >"$fixture/new-evidence";mv "$fixture/new-evidence" "$WATCHDOG_STATE_FILE"
weekly_media_report true >"$fixture/preview.txt"
[[ "$before" == "$(sha256sum "$STATE_DIR/weekly-report-state.json")" ]]
grep -q 'Recommended action:' "$fixture/preview.txt"
printf '#!/bin/sh\nprintf "sent\\n" >>"%s/calls"\nprintf "%%s\\n" "$*" >>"%s/delivered-body"\n' "$fixture" "$fixture" >"$NOTIFY_BIN"
weekly_media_report false
weekly_media_report false
[[ $(wc -l <"$fixture/calls") == 1 && ! -e "$STATE_DIR/weekly-pending-notification.json" ]]
grep -q 'duplicate key' "$fixture/delivered-body"
if grep -q 'NEW evidence after failed send' "$fixture/delivered-body";then exit 1;fi
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
jq '.kometaEvidenceOk=false' "$KOMETA_WEEKLY_STATE" >"$TMP_DIR/invalid"; mv "$TMP_DIR/invalid" "$KOMETA_WEEKLY_STATE"
if kometa_weekly_delegate_ready; then echo 'Unverified Kometa evidence wrongly delegated' >&2; exit 1; fi
printf 'Routine findings delegated only with a healthy handoff; fatal alerts retained; stale handoff restores immediate alerts without false recovery email\n'
)
(
source "$repo/user_script/media_metadata_audit.sh"
STATE_DIR="$fixture/retention";mkdir "$STATE_DIR"
WATCHDOG_STATE_FILE="$fixture/watchdog.json";METAFUSION_FINDINGS_FILE="$fixture/findings.json";NOTIFY_BIN="$fixture/always-success"
printf '#!/bin/sh\nexit 0\n' > "$NOTIFY_BIN";chmod 755 "$NOTIFY_BIN"
now=$(date +%s)
timeout() { [[ ${1:-} != --kill-after=* ]] || shift;shift;"$@"; }
docker() { [[ "$1" == exec && "$2" == -i ]];shift 3;"$PYTHON_BIN" "${@:2}"; }
for title in first second third;do
 jq --arg title "$title" '.jobs.kometa.runLog.maintenance.issues.one.message=$title' "$WATCHDOG_STATE_FILE" >"$fixture/change";mv "$fixture/change" "$WATCHDOG_STATE_FILE"
 jq -n --argjson now "$now" '{schema:1,scheduleKey:"Asia/Singapore/7/11/55",nextDue:($now-1),lastCheckedAt:($now-20)}' >"$STATE_DIR/weekly-report-state.json"
 weekly_media_report false
done
grep -q 'third' "$STATE_DIR/weekly-report.txt";grep -q 'second' "$STATE_DIR/weekly-report.previous.txt"
[[ $(find "$STATE_DIR" -maxdepth 1 -name 'weekly-report*.txt' | wc -l) == 2 ]]
latest=$(sha256sum "$STATE_DIR/weekly-report.txt");previous=$(sha256sum "$STATE_DIR/weekly-report.previous.txt")
weekly_media_report false
[[ "$latest" == "$(sha256sum "$STATE_DIR/weekly-report.txt")" && "$previous" == "$(sha256sum "$STATE_DIR/weekly-report.previous.txt")" ]]
printf 'Exactly two completed weekly reports retained; routine checks do not overwrite or rotate them\n'
)
(
source "$repo/user_script/docker_service_watchdog.sh"
TMP_DIR="$fixture/delegation";mkdir "$TMP_DIR";STATE_DIR="$TMP_DIR";STATE_WORK="$TMP_DIR/state.json";LOG_FILE="$TMP_DIR/log";NOW=$(date +%s)
KOMETA_WEEKLY_STATE="$fixture/producer-handoff.json";NOTIFY_BIN="$fixture/watchdog-notify"
jq -n --argjson now "$NOW" '{schema:1,lastCheckedAt:$now,nextDue:($now+86400),kometaEvidenceOk:true,reportCapabilities:["scheduled-job-review-v1"],producerEvidenceOk:{imagemaid:true,recyclarr:true}}' > "$KOMETA_WEEKLY_STATE"
jq -n --argjson now "$NOW" '{version:2,jobs:{imagemaid:{weeklyReview:{profile:"imagemaid",lastScanAt:$now}}},observations:{"imagemaid:job-warnings":{active:true,severity:"WARNING",message:"review in weekly report",first:0,bad:2},"imagemaid:availability":{active:true,severity:"CRITICAL",message:"unhealthy",first:0,bad:2}},notification:{issues:{}}}' > "$STATE_WORK"
: > "$fixture/watchdog-mails"
notify_changes
! grep -q 'imagemaid:job-warnings' "$fixture/watchdog-mails";grep -q 'imagemaid:availability' "$fixture/watchdog-mails"
jq '.producerEvidenceOk.imagemaid=false' "$KOMETA_WEEKLY_STATE" > "$TMP_DIR/new";mv "$TMP_DIR/new" "$KOMETA_WEEKLY_STATE"
notify_changes
grep -q 'imagemaid:job-warnings' "$fixture/watchdog-mails"
printf 'Per-producer weekly delegation retains health/restart alerts and falls back when that producer coverage fails\n'
)
