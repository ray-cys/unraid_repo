#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source <(awk '/^# LOCK$/{exit} {print}' "$root/user_script/media_health_monitor.sh")
trap - INT TERM HUP
fixture=$(mktemp -d /tmp/sab-loader-recovery.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
SAB_STATUS="$fixture/status" SAB_QUEUE="$fixture/queue" SAB_HISTORY="$fixture/history"
SAB_STATUS_OK=true SAB_QUEUE_OK=true SAB_HISTORY_OK=true
warning='Loading /data/net/incomplete/exact-job/__ADMIN__/SABnzbd_nzo_data failed'
printf '{"status":{"folders":[]}}' >"$SAB_STATUS"
printf '{"queue":{"slots":[{"filename":"exact-job","nzo_id":"new-id","time_added":110,"status":"Queued"}]}}' >"$SAB_QUEUE"
printf '{"history":{"slots":[]}}' >"$SAB_HISTORY"
sab_load_warning_recovered "$warning" 100
printf '{"status":{"folders":["exact-job"]}}' >"$SAB_STATUS"
if sab_load_warning_recovered "$warning" 100; then exit 1; fi
printf '{"status":{"folders":[]}}' >"$SAB_STATUS"
if sab_load_warning_recovered "$warning" 120; then exit 1; fi
printf '{"queue":{"slots":[]}}' >"$SAB_QUEUE"
if sab_load_warning_recovered "$warning" 100; then exit 1; fi
printf '{"history":{"slots":[{"name":"exact-job","nzo_id":"new-id","completed":120,"status":"Completed"}]}}' >"$SAB_HISTORY"
sab_load_warning_recovered "$warning" 100
SAB_STATUS_OK=false
if sab_load_warning_recovered "$warning" 100; then exit 1; fi
printf 'Exact SAB state recovery, active orphan, older record, absent job and unavailable API checks passed\n'
