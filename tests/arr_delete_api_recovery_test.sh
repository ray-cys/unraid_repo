#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/arr-delete-api.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
source "$repo/user_script/arr_delete_sync_tag.sh"
RUNTIME_DIR="$fixture" APP_CONTEXT=SONARR ARR_NAME=Sonarr ARR_TEMP_PREFIX=sonarr ARR_URL=http://fixture ARR_API_KEY=fixture
VERIFY_RUNTIME_DIR="$fixture/verify"; mkdir -p "$VERIFY_RUNTIME_DIR"
API_VERIFY_ATTEMPTS=2 API_VERIFY_DELAY_SECONDS=0
PENDING_ACTIONS_FILE="$fixture/pending-actions.json" ACTION_RECEIPTS_FILE="$fixture/receipts.jsonl"
NOTIFICATION_STATE_FILE="$fixture/notification-state.json" PENDING_NOTIFICATIONS_FILE="$fixture/outbox.jsonl"
initialize_grouped_notifications
printf '{"monitored":true,"absent":false,"excluded":false,"ignorePut":false,"insertExclusion":true,"episode12":true}\n' >"$fixture/server.json"
server_update() { jq "$1" "$fixture/server.json" >"$fixture/server.next"; mv "$fixture/server.next" "$fixture/server.json"; }
curl() {
    local output="" method=GET retry="" previous="" argument endpoint http=200
    for argument in "$@"; do
        case "$previous" in --output) output="$argument";; --request) method="$argument";; --retry) retry="$argument";; esac
        previous="$argument"
    done
    endpoint=${argument#http://fixture}
    printf '%s %s %s\n' "$method" "$retry" "$endpoint" >>"$fixture/requests.txt"
    [[ "$method" == GET || "$retry" == 0 ]]
    if [[ "${fail_transport:-false}" == true ]]; then printf '000'; return 28; fi
    case "$method:$endpoint" in
        PUT:*)
            if ! jq -e '.ignorePut' "$fixture/server.json" >/dev/null; then server_update '.monitored=false'; fi
            printf '{"id":1,"monitored":false}\n' >"$output";;
        DELETE:*) server_update '.absent=true | .excluded=.insertExclusion'; printf '{}' >"$output";;
        POST:/api/v3/tag) printf '{"id":7,"label":"verified-tag"}' >"$output";;
        POST:/api/v3/command) printf '{"id":51}' >"$output";;
        GET:/api/v3/series/1|GET:/api/v3/movie/31)
            if jq -e '.absent' "$fixture/server.json" >/dev/null; then http=404; printf '{"message":"Not found"}' >"$output"
            else jq '{id:1,tvdbId:1001,tmdbId:2001,monitored}' "$fixture/server.json" >"$output"; if [[ "$endpoint" == /api/v3/movie/31 ]]; then jq '.id=31' "$output" >"$fixture/object.next"; mv "$fixture/object.next" "$output"; fi; fi;;
        GET:/api/v3/importlistexclusion|GET:/api/v3/exclusions)
            if jq -e '.excluded' "$fixture/server.json" >/dev/null; then printf '[{"id":9,"tvdbId":1001,"tmdbId":2001}]' >"$output"; else printf '[]' >"$output"; fi;;
        GET:/api/v3/episode/11) printf '{"id":11,"monitored":false}' >"$output";;
        GET:/api/v3/episode/12) jq '{id:12,monitored:.episode12}' "$fixture/server.json" >"$output";;
        GET:/api/v3/tag) printf '[{"id":7,"label":"verified-tag"}]' >"$output";;
        GET:/api/v3/command/51) printf '{"id":51,"name":"RescanSeries","status":"queued","body":{"name":"RescanSeries","seriesId":1}}' >"$output";;
        *) printf '{"message":"Unexpected fixture route"}' >"$output"; http=404;;
    esac
    printf '%s' "$http"
}
api_request PUT /api/v3/series/1 '{"id":1,"monitored":false}' >/dev/null
jq -e '(.actions|length)==0' "$PENDING_ACTIONS_FILE" >/dev/null
# HTTP acceptance is insufficient if exact read-back disagrees.
server_update '.ignorePut=true | .monitored=true'
if api_request PUT /api/v3/series/1 '{"id":1,"monitored":false}' >/dev/null; then echo 'unverified PUT incorrectly succeeded' >&2; exit 1; fi
jq -e '(.actions|length)==1' "$PENDING_ACTIONS_FILE" >/dev/null
put_count=$(grep -c '^PUT ' "$fixture/requests.txt")
server_update '.monitored=false'
recover_pending_actions
[[ "$(grep -c '^PUT ' "$fixture/requests.txt")" == "$put_count" ]]
jq -e '(.actions|length)==0' "$PENDING_ACTIONS_FILE" >/dev/null
# A partial bulk result is explicitly reevaluated from fresh state, never replayed.
id=$(journal_intent api 'PUT /api/v3/episode/monitor' /api/v3/episode/monitor '{"episodeIds":[11,12],"monitored":false}' PUT)
recover_pending_actions
grep -q '1/2 exact targets' "$ACTION_RECEIPTS_FILE"
# Tag and command submissions require catalog/command-ID proof.
api_request POST /api/v3/tag '{"label":"verified-tag"}' >/dev/null
api_request POST /api/v3/command '{"name":"RescanSeries","seriesId":1}' >/dev/null
# An absent title without its external-ID exclusion is not fully successful.
server_update '.absent=false | .excluded=false | .insertExclusion=false'
if api_request DELETE '/api/v3/series/1?deleteFiles=false&addImportListExclusion=true' '' >/dev/null; then echo 'missing exclusion incorrectly succeeded' >&2; exit 1; fi
jq -e '.actions|length==1' "$PENDING_ACTIONS_FILE" >/dev/null
delete_count=$(grep -c '^DELETE ' "$fixture/requests.txt")
server_update '.excluded=true'
recover_pending_actions
[[ "$(grep -c '^DELETE ' "$fixture/requests.txt")" == "$delete_count" ]]
jq -e '.actions|length==0' "$PENDING_ACTIONS_FILE" >/dev/null
grep -q 'tvdbId=1001 present in import exclusions' "$ACTION_RECEIPTS_FILE"
# Radarr uses its own catalog and TMDB identity.
APP_CONTEXT=RADARR ARR_NAME=Radarr
server_update '.absent=false | .excluded=false | .insertExclusion=true'
api_request DELETE '/api/v3/movie/31?deleteFiles=false&addImportExclusion=true' '' >/dev/null
grep -q 'tmdbId=2001 present in import exclusions' "$ACTION_RECEIPTS_FILE"
jq -se 'all(.[]; .event!="attention" or (.key|startswith("api-action:")|not))' "$PENDING_NOTIFICATIONS_FILE" >/dev/null
# A failed checkpoint flush must prevent sending any mutation at all.
mutations_before=$(grep -Ec '^(PUT|POST|DELETE) ' "$fixture/requests.txt")
( sync() { return 1; }; if api_request PUT /api/v3/movie/31 '{"id":31,"monitored":false}' >/dev/null; then exit 1; fi )
[[ "$(grep -Ec '^(PUT|POST|DELETE) ' "$fixture/requests.txt")" == "$mutations_before" ]]
printf 'Verified mutation, command identity, bulk reconciliation and exact Sonarr/Radarr exclusion tests passed\n'
