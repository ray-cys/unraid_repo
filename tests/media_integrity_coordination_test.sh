#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/media-integrity-coordination.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
export MEDIA_INTEGRITY_RECOVERY_FILE="$fixture/recovery.json"
# Each standalone script owns its readonly release identifier. Real workflows
# execute them in separate processes; keep that isolation in this fixture too.
(
source "$repo/user_script/arr_delete_sync_tag.sh"
media_recovery_app_held Sonarr 20
printf '{"schema":1,"workflow":"arr-native","actions":{}}' >"$MEDIA_INTEGRITY_RECOVERY_FILE"
if media_recovery_app_held Sonarr 20;then exit 1;fi
printf '{"schema":1,"workflow":"arr-native","actions":{"a":{"app":"Sonarr","parentId":20,"status":"downloading"}}}' >"$MEDIA_INTEGRITY_RECOVERY_FILE"
media_recovery_app_held Sonarr 20
if media_recovery_app_held Sonarr 21; then exit 1;fi
if media_recovery_app_held Radarr; then exit 1;fi
printf '{"schema":1,"workflow":"arr-native","actions":{"a":{"app":"Radarr","parentId":10,"status":"review"}}}' >"$MEDIA_INTEGRITY_RECOVERY_FILE"
media_recovery_app_held Radarr
jq '.actions.a.status="recovered"' "$MEDIA_INTEGRITY_RECOVERY_FILE" >"$fixture/next";mv "$fixture/next" "$MEDIA_INTEGRITY_RECOVERY_FILE"
if media_recovery_app_held Radarr; then exit 1;fi
printf invalid >"$MEDIA_INTEGRITY_RECOVERY_FILE"
media_recovery_app_held Radarr
media_recovery_app_held Sonarr 20
)
source <(awk '/^# LOCK$/{exit} {print}' "$repo/user_script/media_health_monitor.sh")
trap - INT TERM HUP
trap 'rm -rf -- "$fixture"' EXIT
TMP_DIR="$fixture";ARR_AUTOMATION_ENABLED=true;AUTOMATION_CONTROLS_OK=true
export MEDIA_INTEGRITY_SCRIPT="$fixture/fake-audit"
printf '#!/bin/bash\nprintf "%%s|%%s\\n" "$*" "$RECOVERY_ALLOW_GRAB" >>"%s/calls"\n' "$fixture" >"$MEDIA_INTEGRITY_SCRIPT"
automation_action_budget() { return 0; };automation_api_ready() { return 0; };automation_window_open() { return 1; }
process_media_integrity_recovery
[[ $(cat "$fixture/calls") == '--recovery-tick|false' ]]
automation_window_open() { return 0; }
process_media_integrity_recovery
[[ $(wc -l <"$fixture/calls") == 2 ]]
[[ $(tail -n 1 "$fixture/calls") == '--recovery-tick|true' ]]
# The final generic mutation guard refuses the held parent before API calls.
printf '{"schema":1,"workflow":"arr-native","actions":{"a":{"app":"Sonarr","parentId":20,"status":"downloading"}}}' >"$MEDIA_INTEGRITY_RECOVERY_FILE"
printf '{"app":"Sonarr","mediaKind":"episode","kind":"import-retry","parentId":20,"targetId":201}' >"$fixture/retry.json"
api_get() { echo 'unexpected API call during held mutation' >&2;exit 1; }
if automation_last_moment_guard "$fixture/retry.json" http://fixture key;then exit 1;fi
printf 'Exact-series/movie holds, review persistence, corrupt-journal protection and four-hour executor gating passed\n'
