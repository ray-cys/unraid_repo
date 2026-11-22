#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/arr-delete-api.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
source "$repo/user_script/arr_delete_sync_tag.sh"
RUNTIME_DIR="$fixture" APP_CONTEXT=SONARR ARR_NAME=Sonarr ARR_TEMP_PREFIX=sonarr ARR_URL=http://fixture ARR_API_KEY=fixture
PENDING_ACTIONS_FILE="$fixture/pending-actions.json" ACTION_RECEIPTS_FILE="$fixture/receipts.jsonl"
NOTIFICATION_STATE_FILE="$fixture/notification-state.json" PENDING_NOTIFICATIONS_FILE="$fixture/outbox.jsonl"
initialize_grouped_notifications
curl() {
    local output="" method=GET retry="" previous="" argument
    for argument in "$@"; do
        case "$previous" in --output) output="$argument";; --request) method="$argument";; --retry) retry="$argument";; esac
        previous="$argument"
    done
    printf '%s %s\n' "$method" "$retry" >>"$fixture/requests.txt"
    [[ "$method" == GET || "$retry" == 0 ]]
    if [[ "${fail_transport:-false}" == true ]]; then printf '000'; return 28; fi
    printf '{"id":1,"monitored":false}\n' >"$output"
    printf '200'
}
api_request PUT /api/v3/series/1 '{"id":1,"monitored":false}' >/dev/null
jq -e '(.actions|length)==0' "$PENDING_ACTIONS_FILE" >/dev/null
fail_transport=true
if api_request PUT /api/v3/series/1 '{"id":1,"monitored":false}' >/dev/null; then exit 1; fi
jq -e '(.actions|length)==1' "$PENDING_ACTIONS_FILE" >/dev/null
fail_transport=false
recover_pending_actions
jq -e '(.actions|length)==0' "$PENDING_ACTIONS_FILE" >/dev/null
[[ "$(grep -c '^PUT 0$' "$fixture/requests.txt")" == 2 ]]
id=$(journal_intent api 'PUT /api/v3/episode/monitor' /api/v3/episode/monitor '{"episodeIds":[11,12],"monitored":false}' PUT)
api_get_json() {
    case "$1" in
        /api/v3/episode/11) printf '{"id":11,"monitored":false}\n';;
        /api/v3/episode/12) printf '{"id":12,"monitored":true}\n';;
        *) return 1;;
    esac
}
recover_pending_actions
jq -e '(.actions|length)==0' "$PENDING_ACTIONS_FILE" >/dev/null
grep -q '1/2 targets currently match' "$ACTION_RECEIPTS_FILE"
grep -q '1 of 2 exact objects' "$PENDING_NOTIFICATIONS_FILE"
printf 'API mutation retry, uncertain response and exact bulk read-back tests passed\n'
