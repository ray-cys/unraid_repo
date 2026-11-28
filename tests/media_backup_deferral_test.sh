#!/bin/bash
# Native Linux fixtures: no app APIs, notifications, jobs or configuration writes.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/media-backup-deferral.XXXXXX)
trap 'rm -rf "$work"' EXIT
export root work
source "$root/tools/appdata_backup_gate.sh"
DOCKER_MAINTENANCE_DIR="$work/maintenance";export DOCKER_MAINTENANCE_DIR
mkdir -p "$DOCKER_MAINTENANCE_DIR"
file="$DOCKER_MAINTENANCE_DIR/backup-active.json"
now=$(date +%s);boot=$(cat /proc/sys/kernel/random/boot_id);start=$(sed 's/.*) //' /proc/$$/stat | awk '{print $20}')
jq -n --arg boot "$boot" --arg start "$start" --argjson now "$now" --argjson pid "$$" '{schema:1,producer:"backup_cache_appdata",boot:$boot,pid:$pid,processStart:$start,startedAt:$now,expires:($now+86400),phase:"active"}' > "$file"
cp "$file" "$work/active"
appdata_backup_deferred
jq '.processStart="wrong"' "$work/active" > "$file"
if appdata_backup_deferred;then exit 1;fi
jq '.boot="old"' "$work/active" > "$file"
if appdata_backup_deferred;then exit 1;fi
jq --argjson now "$now" '.phase="grace"|.finishedAt=$now|.expires=($now+120)|.pid=999999' "$work/active" > "$file"
appdata_backup_deferred
jq --argjson old "$((now-300))" '.phase="grace"|.finishedAt=$old|.expires=($old+120)' "$work/active" > "$file"
if appdata_backup_deferred;then exit 1;fi
printf '{}' > "$file"
if appdata_backup_deferred;then exit 1;fi
cp "$work/active" "$file"
# Metadata normal and deadline-only invocations both defer before report delivery.
for mode in normal weekly;do
export mode
bash <<'META'
set -euo pipefail
source "$root/user_script/media_metadata_audit.sh"
STATE_DIR="$work/metadata-$mode";STATUS_DIR="$work/status-$mode";STATE_EXPORT_LOCK="$work/export-$mode.lock"
log(){ printf '%s\n' "$*" >> "$work/metadata.log"; }
mountpoint(){ :; }
weekly_media_report(){ echo 'Unexpected report collection or delivery' >&2;return 99; }
app_update_requested(){ echo 'Unexpected downstream checks' >&2;return 99; }
if [[ $mode == weekly ]];then main --weekly-report;else main;fi
[[ "$METADATA_STATUS" == DEFERRED && "$METADATA_WEEKLY_STATUS" == DEFERRED ]]
[[ ! -e "$STATE_DIR/weekly-report-state.json" ]]
metadata_finish 0
jq -e '.status=="DEFERRED" and .weeklyReportStatus=="DEFERRED"' "$STATUS_DIR/media_metadata_audit.json" >/dev/null
META
done
# Execute the real health-monitor early gate without loading its unrelated runtime.
sed -n '/^ARR_BACKUP_GATE="/ , /^# TEMP DIRECTORY/p' "$root/user_script/media_health_monitor.sh" > "$work/health-gate.sh"
bash <<'HEALTH'
set -euo pipefail
source "$root/tools/appdata_backup_gate.sh"
STATE_DIR="$work/health";mkdir -p "$STATE_DIR";START_TIME=$(date +%s)
ARR_BACKUP_DEFERRED_AT="$work/deferred-at";ARR_BACKUP_GATE="$work/arr.lock"
log(){ printf '%s\n' "$*" >> "$work/health.log"; }
monitor_maintenance_availability(){ echo 'Unexpected service probe' >&2;exit 99; }
app_update_requested(){ echo 'Unexpected downstream action' >&2;exit 99; }
source "$work/health-gate.sh"
echo 'Unexpected normal scan fallthrough' >&2;exit 99
HEALTH
jq -e '.mode=="blanket_backup_deferral" and .services==[] and .availability=="UNVERIFIED"' "$work/health/maintenance-availability.json" >/dev/null
printf 'PASS: shared lease validation, metadata normal/weekly deferral and health blanket gate without API probes\n'
