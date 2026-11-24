#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/operations-integration.XXXXXX)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
TEST_ROOT=$(realpath "$TEST_ROOT");export ROOT TEST_ROOT
export ARR_BACKUP_GATE="$TEST_ROOT/arr-gate" STATE_EXPORT_LOCK="$TEST_ROOT/export-gate" ARR_BACKUP_GRACE="$TEST_ROOT/grace"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
bash <<'WATCHDOG'
set -euo pipefail
source "$ROOT/user_script/docker_service_watchdog.sh"
TMP_DIR="$TEST_ROOT"; STATE_WORK="$TEST_ROOT/watchdog.json"; NOW=$(date +%s)
printf '{"services":{"service":{"id":"abc","lastRunningAt":%s}}}' "$((NOW-100))" >"$STATE_WORK"
info=$(jq -cn --arg finish "$(date -d "@$((NOW-50))" -Iseconds)" '[{Id:"abc",State:{Status:"exited",FinishedAt:$finish,ExitCode:1}}]')
docker_cmd() { printf '{"Actor":{"ID":"abc"},"Action":"die","time":%s}\n' "$((NOW-50))"; if [[ ${MANUAL:-false} == true ]]; then printf '{"Actor":{"ID":"abc"},"Action":"stop","time":%s}\n' "$((NOW-50))"; fi; }
unexpected_exit_proven service "$info"
MANUAL=true
if unexpected_exit_proven service "$info"; then exit 1; fi
MANUAL=false
jq '.services.service.lastRunningAt=0' "$STATE_WORK" >"$TEST_ROOT/new.json"; mv "$TEST_ROOT/new.json" "$STATE_WORK"
if unexpected_exit_proven service "$info"; then exit 1; fi
printf 'Crash evidence accepted; explicit stop and unknown-running history preserved\n'
WATCHDOG
bash <<'DNS'
set -euo pipefail
source "$ROOT/user_script/dns_redundancy_watchdog.sh"
PRIMARY_IN_MAINTENANCE=true; PRIMARY_FAILURES=4; PRIMARY_DNS_OK=false; FALLBACK_DNS_OK=true
classify_dns_state; [[ "$CLASSIFICATION" == PRIMARY_MAINTENANCE ]]
update_failure_counters; [[ "$PRIMARY_FAILURES" == 4 ]]
FALLBACK_DNS_OK=false; classify_dns_state; [[ "$CLASSIFICATION" == FALLBACK_FAILED ]]
printf 'DNS planned primary downtime preserves counters and fallback failure reporting\n'
DNS
bash <<'EXPORT'
set -euo pipefail
source "$ROOT/user_script/vault_backup.sh"
OPERATIONS_STATE_MOUNT_ROOT="$TEST_ROOT/vault"; OPERATIONS_STATE_ROOT="$TEST_ROOT/vault/backup/operations_state"
OPERATIONS_REQUIRED_STATE_FILES=(arr_health_activity/state.json media_cleanup/arr/pending-operations.json)
OPERATIONS_SCRIPT_ROOT="$TEST_ROOT/live"; LOG_FILE="$TEST_ROOT/export.log"
RECOVERY_BOOT_ROOT="$TEST_ROOT/no-host-boot"
recovery_docker() { return 1; }
mkdir -p "$OPERATIONS_STATE_MOUNT_ROOT/backup" "$OPERATIONS_SCRIPT_ROOT/arr_health_activity" "$OPERATIONS_SCRIPT_ROOT/media_cleanup/arr"
printf '{"issues":{"ack":"preserved"}}' >"$OPERATIONS_SCRIPT_ROOT/arr_health_activity/state.json"
printf '{"operations":{}}' >"$OPERATIONS_SCRIPT_ROOT/media_cleanup/arr/pending-operations.json"
printf 'bulk log data' >"$OPERATIONS_SCRIPT_ROOT/arr_health_activity/huge.log"
printf '{"stale":true}' >"$OPERATIONS_SCRIPT_ROOT/arr_health_activity/state.before-bulk-ack.json"
vault_export_operations_state
[[ -f "$OPERATIONS_STATE_ROOT/arr_health_activity/state.json" && -f "$OPERATIONS_STATE_ROOT/media_cleanup/arr/pending-operations.json" ]]
[[ ! -e "$OPERATIONS_STATE_ROOT/arr_health_activity/huge.log" && ! -e "$OPERATIONS_STATE_ROOT/arr_health_activity/state.before-bulk-ack.json" ]]
printf 'invalid' >"$OPERATIONS_SCRIPT_ROOT/arr_health_activity/state.json"
if vault_export_operations_state; then exit 1; fi
jq -e '.issues.ack=="preserved"' "$OPERATIONS_STATE_ROOT/arr_health_activity/state.json" >/dev/null
printf 'Operational export keeps current journals, excludes logs/history and preserves prior snapshot on invalid source\n'
EXPORT
bash <<'TORRENT'
set -euo pipefail
source "$ROOT/user_script/completed_torrent_download.sh"
QBIT_RUNTIME="$TEST_ROOT/qbit"; mkdir "$QBIT_RUNTIME"; source_dir="$TEST_ROOT/complete/category"; mkdir -p "$source_dir"
printf 'payload' >"$source_dir/file.mkv"
QBIT_HOST_ROOT="$TEST_ROOT"; QBIT_CONTAINER_ROOT=/data
qbit_request() { jq -n --arg state "${JOB_STATE:-stoppedUP}" '[{hash:"abc",content_path:"/data/complete/category/file.mkv",progress:1,amount_left:0,state:$state}]' >"$2"; }
category_completion_proven "$source_dir"
JOB_STATE=downloading
if category_completion_proven "$source_dir"; then exit 1; fi
JOB_STATE=stoppedUP; printf 'unknown' >"$source_dir/unowned.mkv"
if category_completion_proven "$source_dir"; then exit 1; fi
printf 'Exact completed/stopped torrent ownership required; active and unowned files retained\n'
TORRENT
printf 'Operations integration fixtures passed\n'
bash <<'RAM'
set -euo pipefail
source "$ROOT/user_script/ramlog_monitor.sh"
STATE_DIR="$TEST_ROOT/ram-state"; STATUS_DIR="$TEST_ROOT/ram-status"; RAMLOG_PATH="$TEST_ROOT/ramlogs"; mkdir "$RAMLOG_PATH"
NOTIFY="$TEST_ROOT/notify"; printf '#!/bin/sh\nprintf "sent\\n" >>"%s/notified"\n' "$TEST_ROOT" >"$NOTIFY"; chmod 755 "$NOTIFY"
mountpoint() { return 0; }
findmnt() { printf 'tmpfs\n'; }
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nram 102400 1000 100000 %s%% /test\n' "$PERCENT"; }
PERCENT=50; monitor_ramlogs
[[ ! -f "$TEST_ROOT/notified" ]]
PERCENT=75; monitor_ramlogs; monitor_ramlogs
[[ $(wc -l <"$TEST_ROOT/notified") == 1 ]]
PERCENT=95; monitor_ramlogs || true
[[ $(wc -l <"$TEST_ROOT/notified") == 2 ]]
PERCENT=68; monitor_ramlogs
PERCENT=60; monitor_ramlogs
[[ $(wc -l <"$TEST_ROOT/notified") == 4 ]]
printf 'RAM-log lifecycle confirms deduplication, escalation and hysteresis recovery\n'
RAM
bash <<'AUDIT'
set -euo pipefail
source "$ROOT/user_script/backup_health_audit.sh"
NOW=$(date +%s); check_age Appdata "$((NOW-100*3600))" 100
first=$(printf '%s\n' "${FINDINGS[@]}" | sha256sum)
FINDINGS=(); NOW=$((NOW+3600)); check_age Appdata "$((NOW-101*3600))" 100
second=$(printf '%s\n' "${FINDINGS[@]}" | sha256sum)
[[ "$first" == "$second" ]]
printf 'Backup-audit finding signatures remain stable as stale-job age grows\n'
AUDIT
bash <<'IMAGE'
set -euo pipefail
source "$ROOT/user_script/imagemaid_restore_archive.sh"
PLEX_ROOT="$TEST_ROOT/plex"; STATE_DIR="$TEST_ROOT/image-state"; STATUS_DIR="$TEST_ROOT/image-status"; LEASE_DIR="$TEST_ROOT/leases"
export APPDATA_LOCK_FILE="$TEST_ROOT/appdata.lock"
mkdir -p "$PLEX_ROOT/ImageMaid Restore" "$TEST_ROOT/image-logs"
printf 'undo image' >"$PLEX_ROOT/ImageMaid Restore/image.jpg"
printf 'native finished log' >"$TEST_ROOT/image-logs/imagemaid.log"
printf true >"$TEST_ROOT/image-running"
NOTIFY_BIN="$TEST_ROOT/image-notify"; printf '#!/bin/sh\nexit 0\n' >"$NOTIFY_BIN"; chmod 755 "$NOTIFY_BIN"
mountpoint() { return 0; }
timeout() {
    shift
    if [[ "$1" != docker ]]; then command timeout 20 "$@"; return $?; fi
    shift
    case "$1" in
        inspect)
            if [[ ${2:-} == -f ]]; then cat "$TEST_ROOT/image-running"
            else jq -n --arg p "$PLEX_ROOT" --arg logs "$TEST_ROOT/image-logs" '[{State:{Running:true},Mounts:[{Source:$p,Destination:"/plex"},{Source:$logs,Destination:"/config/logs"}]}]'; fi;;
        exec) cat >/dev/null; [[ ${SIMULATE_ACTIVE:-false} != true ]];;
        stop) printf false >"$TEST_ROOT/image-running"; printf 'stop\n' >>"$TEST_ROOT/image-actions";;
        start) printf true >"$TEST_ROOT/image-running"; printf 'start\n' >>"$TEST_ROOT/image-actions";;
        *) return 1;;
    esac
}
(main)
archive=$(jq -r .archive "$STATE_DIR/state.json")
[[ ! -d "$PLEX_ROOT/ImageMaid Restore" && -f "$archive/image.jpg" ]]
[[ $(cat "$TEST_ROOT/image-running") == true && $(wc -l <"$TEST_ROOT/image-actions") == 2 ]]
mkdir "$PLEX_ROOT/ImageMaid Restore"; printf 'retain' >"$PLEX_ROOT/ImageMaid Restore/new.jpg"
SIMULATE_ACTIVE=true
(main)
[[ -f "$PLEX_ROOT/ImageMaid Restore/new.jpg" && $(wc -l <"$TEST_ROOT/image-actions") == 2 ]]
printf 'ImageMaid atomic archival preserves images and active runs; idle scheduler restored\n'
IMAGE
bash <<'COMPAT'
set -euo pipefail
source "$ROOT/user_script/completed_torrent_download.sh"
UNRAID_VERSION_FILE="$TEST_ROOT/unraid-next"
printf 'version="8.0.0"\n' >"$UNRAID_VERSION_FILE"
rc=0; acquire_operation_coordination || rc=$?
[[ "$rc" == 75 ]]
printf 'Unknown Unraid major defers torrent/cleanup mutation before acquiring work state\n'
COMPAT
