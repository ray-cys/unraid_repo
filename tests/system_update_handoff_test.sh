#!/bin/bash
# Only isolated lock files, request files and application-response fixtures.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d);trap 'rm -rf "$fixture"' EXIT
source "$repo/user_script/system_update_coordinator.sh"
APP_UPDATE_REQUEST_DIR="$fixture/requests";ARR_BACKUP_GATE="$fixture/arr.lock";TMP_DIR="$fixture";RUN_ID=fixture;COORDINATION_WAIT_SECONDS=1
cat(){ if [[ "${1:-}" == /proc/sys/kernel/random/boot_id ]];then printf 'fixture-boot\n';else command cat "$@";fi; }
pgrep(){ return 1; }
bounded(){ printf 'mdState=STARTED\nmdResync=0\n'; }
exec {reader}>"$ARR_BACKUP_GATE";flock -s "$reader"
maintenance_guard docker seerr seerr
[[ ! -e "$APP_UPDATE_REQUEST_DIR/seerr.json" ]]
release_operation_locks
if maintenance_guard docker radarr radarr;then echo 'Exclusive update bypassed active reader' >&2;exit 1;fi
[[ "$REQUEST_KEEP" == true ]]
jq -e '.target=="radarr" and (.scopes|index("arr")!=null)' "$APP_UPDATE_REQUEST_DIR/radarr.json" >/dev/null
release_operation_locks
# The next independent app can still acquire shared protection.
maintenance_guard docker tautulli tautulli
release_operation_locks
[[ -f "$APP_UPDATE_REQUEST_DIR/radarr.json" ]]
exec {reader}>&-
maintenance_guard docker radarr radarr
clear_update_request;release_operation_locks
[[ ! -e "$APP_UPDATE_REQUEST_DIR/radarr.json" ]]
# Consumer rejects old-boot/expired/other-scope requests without touching them.
source <(sed -n '/^app_update_requested() {/,/^}/p' "$repo/user_script/media_cleanup.sh")
request_update_handoff radarr '["arr"]'
app_update_requested arr
if app_update_requested metadata;then exit 1;fi
jq '.boot="old-boot"' "$CURRENT_REQUEST" >"$fixture/next";mv "$fixture/next" "$CURRENT_REQUEST"
if app_update_requested arr;then exit 1;fi
request_update_handoff radarr '["arr"]'
jq '.expires=0' "$CURRENT_REQUEST" >"$fixture/next";mv "$fixture/next" "$CURRENT_REQUEST"
if app_update_requested arr;then exit 1;fi
prune_update_requests
[[ ! -e "$CURRENT_REQUEST" ]]
printf 'Shared unrelated update, bounded exclusive wait, durable handoff and resume passed\n'
repo="$repo" bash <<'WATCHDOG'
set -euo pipefail
source "$repo/user_script/docker_service_watchdog.sh"
check_plex(){ local expected="$1" processes="$2" xml="$3";printf '%s' "$xml" | plex_sessions_summary "$processes" | jq -e --argjson ready "$expected" '.ready==$ready' >/dev/null; }
check_plex true 0 '<MediaContainer size="1"><Video><Media videoDecision="directplay" audioDecision="directplay"/></Video></MediaContainer>'
check_plex true 1 '<MediaContainer size="1"><Video><TranscodeSession videoDecision="copy" audioDecision="copy"/></Video></MediaContainer>'
check_plex false 1 '<MediaContainer size="1"><Video><TranscodeSession videoDecision="copy" audioDecision="transcode"/></Video></MediaContainer>'
check_plex false 1 '<MediaContainer size="0"/>'
check_plex false 0 '<MediaContainer size="1"><Video><TranscodeSession/></Video></MediaContainer>'
if printf '<broken' | plex_sessions_summary 0 >/dev/null;then exit 1;fi
printf 'Plex direct playback/remux allowed; audio transcoding, background and incomplete evidence deferred\n'
printf '%s' '{"commands":[],"queue":{"records":[{"trackedDownloadState":"importPending"}],"totalRecords":1}}' | arr_activity_summary | jq -e .ready >/dev/null
printf '%s' '{"commands":[{"status":"started"}],"queue":{"records":[],"totalRecords":0}}' | arr_activity_summary | jq -e '.ready==false' >/dev/null
printf '%s' '{"commands":[],"queue":{"records":[{"trackedDownloadState":"importing"}],"totalRecords":1}}' | arr_activity_summary | jq -e '.ready==false' >/dev/null
if printf '%s' '{"commands":[],"queue":{"records":[],"totalRecords":5}}' | arr_activity_summary >/dev/null 2>&1;then exit 1;fi
printf '%s' '{"commands":[{"name":"DownloadedEpisodesScan","status":"queued"},{"name":"RssSync","status":"started"}],"queue":{"records":[{"trackedDownloadState":"downloading"},{"trackedDownloadState":"importPending"}],"totalRecords":2}}' | arr_activity_summary | jq -e .ready >/dev/null
printf '%s' '{"commands":[{"name":"DownloadedEpisodesScan","status":"started"}],"queue":{"records":[],"totalRecords":0}}' | arr_activity_summary | jq -e '.ready==false' >/dev/null
printf '%s' '{"commands":[{"name":"RssSync","status":"started","body":{"requiresDiskAccess":true}}],"queue":{"records":[],"totalRecords":0}}' | arr_activity_summary | jq -e '.ready==false' >/dev/null
printf 'Arr active command/import protected; import warnings allowed; incomplete response refused\n'
WATCHDOG
