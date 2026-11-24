#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/arr_delete_sync_tag.sh"
fixture=$(mktemp -d /tmp/movie-recovery-holds.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
export MEDIA_INTEGRITY_RECOVERY_FILE="$fixture/recovery.json"
printf '{"schema":1,"workflow":"arr-native","actions":{"a":{"app":"Radarr","parentId":10,"status":"review"}}}' >"$MEDIA_INTEGRITY_RECOVERY_FILE"
printf '[{"id":10,"title":"Held","monitored":false,"hasFile":false},{"id":20,"title":"Other","monitored":false,"hasFile":false},{"id":30,"title":"Present","monitored":true,"hasFile":true,"movieFileId":300}]' >"$fixture/catalog.json"
STATE_DIR="$fixture";WORK_STATE="$fixture/state.json";RUN_AT='2026-11-24T14:00:00+0800'
printf '{"movies":{"10":{"movieId":10,"title":"Held","everHadFile":true,"missingSince":"2026-11-01","missingRuns":5},"20":{"movieId":20,"title":"Other","everHadFile":true,"missingSince":"2026-11-01","missingRuns":5}},"sidecarManifests":{"10":{"sentinel":"preserve"}},"movieRetirements":{"10":{"sentinel":"preserve"}}}' >"$WORK_STATE"
jq '.movies["10"]' "$WORK_STATE" >"$fixture/held-before.json"
printf '{}' >"$fixture/sidecars.json"
radarr_action_snapshot "$fixture/catalog.json" "$fixture/actions.json" "$fixture/holds.json"
jq -e 'map(.id)==[20,30]' "$fixture/actions.json" >/dev/null
radarr_apply_snapshot "$fixture/actions.json" "$fixture/sidecars.json"
jq -e --slurpfile before "$fixture/held-before.json" '.movies["10"]==$before[0] and .movies["20"].missingRuns==6 and .sidecarManifests["10"].sentinel=="preserve" and .movieRetirements["10"].sentinel=="preserve"' "$WORK_STATE" >/dev/null
radarr_confirmed_movies "$fixture/actions.json" >"$fixture/confirmed.json"
jq -e 'map(.id)==[20]' "$fixture/confirmed.json" >/dev/null
media_recovery_app_held Radarr 10
if media_recovery_app_held Radarr 20;then exit 1;fi
# Healthy replacement releases the library hold even if original disposal needs review.
jq '.actions.a.status="recovered" | .actions.a.replacementVerifiedAt=1' "$MEDIA_INTEGRITY_RECOVERY_FILE" >"$fixture/new";mv "$fixture/new" "$MEDIA_INTEGRITY_RECOVERY_FILE"
radarr_action_snapshot "$fixture/catalog.json" "$fixture/actions.json" "$fixture/holds.json"
jq -e 'map(.id)==[10,20,30]' "$fixture/actions.json" >/dev/null
if media_recovery_app_held Radarr 10;then exit 1;fi
printf invalid >"$MEDIA_INTEGRITY_RECOVERY_FILE"
if radarr_action_snapshot "$fixture/catalog.json" "$fixture/actions.json" "$fixture/holds.json";then exit 1;fi
printf 'Only held movie is excluded; its observations/sidecars/retirement remain untouched; other movies proceed; verified handoff failures do not block library work; invalid holds stop safely\n'
