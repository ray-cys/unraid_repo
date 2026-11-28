#!/bin/bash
# Native Linux fixtures only: no real Docker actions, schedules or notifications.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/backup-watchdog-gate.XXXXXX)
trap 'rm -rf "$work"' EXIT
export root work
bash <<'WATCHDOG'
set -euo pipefail
source "$root/user_script/docker_service_watchdog.sh"
DOCKER_MAINTENANCE_DIR="$work/maintenance";mkdir -p "$DOCKER_MAINTENANCE_DIR"
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
alerts=0
observe(){ alerts=$((alerts+1)); }
now=$(date +%s);start=$(sed 's/.*) //' /proc/$$/stat | awk '{print $20}')
file="$DOCKER_MAINTENANCE_DIR/backup-active.json"
jq -n --arg boot "$BOOT_ID" --arg start "$start" --argjson pid "$$" --argjson now "$now" '{schema:1,producer:"backup_cache_appdata",boot:$boot,pid:$pid,processStart:$start,startedAt:$now,expires:($now+86400),phase:"active"}' > "$file"
watchdog_backup_suppressed
[[ $alerts == 0 && $BACKUP_SUPPRESSION_REASON == *active* ]]
cp "$file" "$work/active"
jq '.processStart="wrong"' "$work/active" > "$file"
if watchdog_backup_suppressed;then exit 1;fi
[[ $alerts == 1 ]]
jq '.boot="old-boot"' "$work/active" > "$file"
if watchdog_backup_suppressed;then exit 1;fi
[[ $alerts == 1 ]]
jq --argjson now "$(date +%s)" '.phase="grace"|.finishedAt=$now|.expires=($now+120)|.pid=999999' "$work/active" > "$file"
watchdog_backup_suppressed
[[ $BACKUP_SUPPRESSION_REASON == *grace* ]]
jq --argjson now "$(( $(date +%s)-300 ))" '.phase="grace"|.finishedAt=$now|.expires=($now+120)' "$work/active" > "$file"
if watchdog_backup_suppressed;then exit 1;fi
printf 'not-json' > "$file"
if watchdog_backup_suppressed;then exit 1;fi
[[ $alerts == 2 ]]
rm "$file"
if watchdog_backup_suppressed;then exit 1;fi
# Exercise the main early-return path: no health scans, recovery or delivery.
cp "$work/active" "$file"
STATE_DIR="$work/state";STATUS_DIR="$work/status";STATE_FILE="$STATE_DIR/state.json"
STATE_EXPORT_LOCK="$work/export.lock";LOCK_FILE="$work/main.lock";LOG_FILE="$work/main.log"
heartbeat_event(){ :; };mountpoint(){ :; };bound_existing_logs(){ :; }
load_state(){ printf '{"version":2,"services":{},"recovery":{},"observations":{},"notification":{"issues":{}},"jobs":{}}' > "$STATE_WORK"; }
state_valid(){ jq -e 'type=="object"' "$1" >/dev/null; }
docker_cmd(){ return 1; }
watchdog_schedule_inventory(){ echo 'Unexpected schedule/health scan' >&2;return 1; }
notify_changes(){ echo 'Unexpected notification' >&2;return 1; }
attempt_recovery(){ echo 'Unexpected recovery' >&2;return 1; }
main
jq -e '.status=="DEFERRED" and .availabilityStatus=="UNVERIFIED" and (.summary|contains("backup active"))' "$STATUS_DIR/docker_service_watchdog.json" >/dev/null
jq -e '.backupMonitoring.status=="DEFERRED"' "$STATE_FILE" >/dev/null
WATCHDOG
bash <<'BACKUP'
set -euo pipefail
source "$root/user_script/backup_cache_appdata.sh"
DOCKER_MAINTENANCE_DIR="$work/producer";DOCKER_WATCHDOG_LOCK_FILE="$work/watchdog.lock"
backup_watchdog_begin
jq -e '.phase=="active" and .producer=="backup_cache_appdata"' "$DOCKER_MAINTENANCE_DIR/backup-active.json" >/dev/null
backup_watchdog_end 0
jq -e '.phase=="grace" and .expires==(.finishedAt+120)' "$DOCKER_MAINTENANCE_DIR/backup-active.json" >/dev/null
backup_watchdog_begin;backup_watchdog_end 1
[[ ! -e "$DOCKER_MAINTENANCE_DIR/backup-active.json" ]]
SRC_DIR=/mnt/cache/appdata;APPDATA_PATH_ALIASES=(/mnt/user/appdata)
ELIGIBLE_APPDATA=([sonarr]=1 [codex-cli]=1 [stopped-app]=1 [external-db]=1)
EXTRA_ARCHIVE_OWNER=([external-db]=stopped-app)
docker(){
 case "$1" in
 ps) printf 'abc\ndef\n';;
 inspect) printf '[{"Name":"/sonarr","Mounts":[{"Type":"bind","Source":"/mnt/cache/appdata/sonarr"}]},{"Name":"/stopped","Mounts":[{"Type":"bind","Source":"/mnt/user/appdata/stopped-app/config"}]}]';;
 *) return 1;;esac
}
discover_installed_appdata_owners
[[ $APP_OWNER_INVENTORY_VERIFIED == true ]]
[[ $(appdata_owner_label sonarr) == '' && $(appdata_owner_label stopped-app) == '' && $(appdata_owner_label external-db) == '' ]]
[[ $(appdata_owner_label codex-cli) == ' [no container]' ]]
docker(){ return 1; }
discover_installed_appdata_owners
[[ $(appdata_owner_label sonarr) == ' [owner unknown]' ]]
BACKUP
printf 'PASS: backup runtime gate, recovery grace, dead owner, old boot, malformed lease and installed-container ownership\n'
