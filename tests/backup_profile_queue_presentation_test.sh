#!/usr/bin/env bash
# Bounded synthetic evidence only: no production APIs, media actions or email.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/profile-presentation.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
(
 source "$repo/user_script/backup_vault_remote.sh"
 TMP_DIR="$fixture";LOG_FILE="$fixture/profile.log"
 printf 'Total transferred file size: 1,048,576 bytes\nTotal bytes sent: 524,288\n' >"$fixture/rsync.stats"
 start=$(( $(usr_ops_now_ms)-1000 ))
 vault_profile_record photos 1 source_manifest "$start" 0 2097152
 vault_profile_record photos 1 rsync_transfer "$start" 0 2097152 "$fixture/rsync.stats"
 vault_profile_record photos 1 destination_sha256 "$start" 1 2097152
 vault_profile_record appdata 1 source_manifest "$start" 0 2097152
 vault_profile_record photos 2 rsync_transfer "$start" 30 2097152 /not-present
 vault_profile_json >"$fixture/profile.json"
 jq -e '.attemptStages|length==5' "$fixture/profile.json" >/dev/null
 jq -e 'any(.attemptStages[];.stage=="rsync_transfer" and .transferredFileBytes==1048576 and .rsyncSentBytes==524288 and .effectiveChangedMiBPerSecond>0)' "$fixture/profile.json" >/dev/null
 jq -e 'any(.attemptStages[];.stage=="destination_sha256" and .exitCode==1) and any(.attemptStages[];.label=="appdata" and .hashMode=="producer_manifest_validation") and any(.attemptStages[];.exitCode==30 and .effectiveChangedMiBPerSecond==null)' "$fixture/profile.json" >/dev/null
)
(
 source <(awk '/^# LOCK$/{exit}{print}' "$repo/user_script/media_health_monitor.sh")
 trap - INT TERM HUP
 TMP_DIR="$fixture";STATE_DIR="$fixture";AUTOMATION_STATE_FILE="$fixture/actions.json"
 printf '{"actions":{}}' >"$AUTOMATION_STATE_FILE"
 queue="$fixture/queue.json"
 printf '{"records":[{"id":1,"downloadId":"EXACT","episodeId":11},{"id":2,"downloadId":"exact","episodeId":12},{"id":3,"downloadId":"different","episodeId":13}]}' >"$queue"
 item='{"id":1,"downloadId":"exact","episodeId":11,"title":"Show.S01.Complete","statusMessages":[{"messages":["File being used by another process"]}]}'
 arr_queue_presentation Sonarr "$item" "$queue" >"$fixture/pack.txt"
 grep -q '2 related row(s)' "$fixture/pack.txt"
 grep -q 'Pack/multi-target evidence' "$fixture/pack.txt"
 grep -q '11, 12' "$fixture/pack.txt"
 if grep -q '11, 12, 13' "$fixture/pack.txt";then exit 1;fi
 grep -q 'Retry not submitted' "$fixture/pack.txt"
 printf '{"actions":{"a":{"app":"Sonarr","kind":"import-retry","downloadId":"exact","startedAt":100,"status":"accepted","commandId":42},"b":{"app":"Sonarr","kind":"import-retry","downloadId":"exact","startedAt":200,"status":"failed"},"c":{"app":"Sonarr","kind":"import-retry","downloadId":"exact","startedAt":300,"status":"accepted"}}}' >"$AUTOMATION_STATE_FILE"
 arr_queue_presentation Sonarr "$item" "$queue" >"$fixture/retry.txt"
 grep -q 'Import retries: 3/3' "$fixture/retry.txt"
 grep -q 'Retry limit reached' "$fixture/retry.txt"
 printf '{"actions":{}}' >"$AUTOMATION_STATE_FILE"
 printf '{"records":[{"id":1,"downloadId":"exact","episodeId":11}]}' >"$queue"
 item=$(jq '.title="Show.S01E01.1080p"' <<<"$item")
 arr_queue_presentation Sonarr "$item" "$queue" >"$fixture/single.txt"
 grep -q 'Pack evidence: none established' "$fixture/single.txt"
 item=$(jq '.title="Show.S01.Complete"' <<<"$item")
 arr_queue_presentation Sonarr "$item" "$queue" >"$fixture/hint.txt"
 grep -q 'release-name hint only' "$fixture/hint.txt"
)
printf 'Stage profiling, retries/failures, producer-manifest scope and exact-download pack/retry presentation passed\n'
