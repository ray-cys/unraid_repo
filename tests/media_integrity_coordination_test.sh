#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/media-integrity-coordination.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
export MEDIA_INTEGRITY_RECOVERY_FILE="$fixture/recovery.json"
source "$repo/user_script/arr_delete_sync_tag.sh"
if media_recovery_app_held Sonarr 20; then exit 1;fi
printf '{"schema":1,"actions":{"a":{"app":"Sonarr","parentId":20,"status":"search_submitted"}}}' >"$MEDIA_INTEGRITY_RECOVERY_FILE"
media_recovery_app_held Sonarr 20
if media_recovery_app_held Sonarr 21; then exit 1;fi
if media_recovery_app_held Radarr; then exit 1;fi
printf '{"schema":1,"actions":{"a":{"app":"Radarr","parentId":10,"status":"review"}}}' >"$MEDIA_INTEGRITY_RECOVERY_FILE"
media_recovery_app_held Radarr
jq '.actions.a.status="verified"' "$MEDIA_INTEGRITY_RECOVERY_FILE" >"$fixture/next";mv "$fixture/next" "$MEDIA_INTEGRITY_RECOVERY_FILE"
if media_recovery_app_held Radarr; then exit 1;fi
printf invalid >"$MEDIA_INTEGRITY_RECOVERY_FILE"
media_recovery_app_held Radarr
media_recovery_app_held Sonarr 20
source <(awk '/^# LOCK$/{exit} {print}' "$repo/user_script/arr_health_activity.sh")
trap - INT TERM HUP
trap 'rm -rf -- "$fixture"' EXIT
TMP_DIR="$fixture";ARR_AUTOMATION_ENABLED=true;AUTOMATION_CONTROLS_OK=true
export MEDIA_INTEGRITY_SCRIPT="$fixture/fake-audit"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s/calls"\n' "$fixture" >"$MEDIA_INTEGRITY_SCRIPT"
automation_api_ready() { return 0; };automation_window_open() { return 1; }
process_media_integrity_recovery
[[ ! -e "$fixture/calls" ]]
automation_window_open() { return 0; }
process_media_integrity_recovery
[[ $(cat "$fixture/calls") == --recover-only ]]
printf 'Exact-series/movie holds, review persistence, corrupt-journal protection and four-hour executor gating passed\n'
