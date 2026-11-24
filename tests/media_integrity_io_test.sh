#!/usr/bin/env bash
# Feature checks use temporary fixtures/mocks only, no Docker or real APIs.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/media_integrity_audit.sh"
fixture=$(mktemp -d /tmp/media-io-features.XXXXXX);trap 'rm -rf "$fixture"' EXIT
TMP_DIR="$fixture";MEDIA_HOST_ROOT="$fixture/media";mkdir -p "$MEDIA_HOST_ROOT/incomplete" "$MEDIA_HOST_ROOT/complete"
RECOVERY_DOWNLOAD_ROOTS=("$MEDIA_HOST_ROOT/incomplete" "$MEDIA_HOST_ROOT/complete")
free_bytes=$((20*1024*1024*1024))
df() { printf 'Filesystem 1B-blocks Used Available Capacity Mounted\nfixture 99999999999 0 %s 0%% /fixture\n' "$free_bytes"; }
recovery_capacity_ready 1073741824 true
free_bytes=$((12*1024*1024*1024))
if recovery_capacity_ready 1073741824 true;then echo 'download/import aggregate space undercounted' >&2;exit 1;fi
free_bytes=$((20*1024*1024*1024))
if recovery_capacity_ready 107374182400 true;then exit 1;fi
RECOVERY_ROOT=http://fixture/api/v3;RECOVERY_KEY=fixture;RECOVERY_DEADLINE=0
printf 0 >"$fixture/attempts"
fixture_mode=retry
curl() {
 local output="" previous="" n
 for arg in "$@";do [[ "$previous" != --output ]] || output="$arg";previous="$arg";done
 n=$(cat "$fixture/attempts");n=$((n+1));printf '%s' "$n" >"$fixture/attempts"
 printf '[]' >"$output"
 if [[ "$fixture_mode" == retry && "$n" == 1 ]];then printf 503;else printf 200;fi
}
sleep() { :; }
recovery_api GET /health "$fixture/result"
[[ $(cat "$fixture/attempts") == 2 ]]
printf 0 >"$fixture/attempts"
recovery_api POST /release "$fixture/result" "$fixture/result" || true
[[ $(cat "$fixture/attempts") == 1 ]]
printf 0 >"$fixture/attempts"
if recovery_api DELETE /moviefile/1 "$fixture/result";then exit 1;fi
[[ $(cat "$fixture/attempts") == 0 ]]
# Real paginator, mocked page responses: complete merge and duplicate-ID veto.
pages_bad=false
recovery_api() {
 local page
 page=${2#*page=};page=${page%%&*};RECOVERY_HTTP=200
 if [[ "$page" == 1 ]];then jq -n '{totalRecords:201,records:[range(1;201)|{id:.,downloadId:"nzo"}]}' >"$3"
 elif [[ "$pages_bad" == true ]];then printf '{"totalRecords":201,"records":[{"id":1,"downloadId":"nzo"}]}' >"$3"
 else printf '{"totalRecords":201,"records":[{"id":201,"downloadId":"nzo"}]}' >"$3";fi
}
printf '{"app":"Radarr","parentId":10,"targets":[10]}' >"$fixture/job"
recovery_history "$fixture/job" "$fixture/history" nzo
jq -e '.records|length==201' "$fixture/history" >/dev/null
pages_bad=true
if recovery_history "$fixture/job" "$fixture/history" nzo;then echo 'duplicate history IDs accepted' >&2;exit 1;fi
printf 'Selected-size aggregate capacity, GET-only transient retry, mutation boundary, complete pagination and duplicate veto passed\n'
