#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/sabnzbd_cleanup.sh"
trap - EXIT INT TERM HUP
fixture=$(mktemp -d /tmp/durable-import-cleanup.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
TMP_DIR="$fixture"; IMPORT_RECEIPT_FILE="$fixture/receipts.json"
SONARR_URL=http://fixture; SONARR_API_KEY=fixture
fixture_job='{"nzo_id":"abc-123","name":"Show.S01E01","storage":"/downloads/show","completed":123,"category":"tv"}'
jq -n --argjson job "$fixture_job" '{version:1,receipts:{"Sonarr:abc-123":{app:"Sonarr",downloadId:"abc-123",conflict:false,sab:$job,
 targets:{one:{kind:"episode",targetId:11,parentId:1,fileId:21,parentExternalId:1001,seasonNumber:1,episodeNumber:1,pathAtImport:"/library/old-name.mkv"}}}}}' >"$IMPORT_RECEIPT_FILE"
fixture_target='{"id":11,"seriesId":1,"seasonNumber":1,"episodeNumber":1,"episodeFileId":21,"hasFile":true}'
fixture_file='{"id":21,"seriesId":1,"path":"/library/new-name.mkv","size":5}'
mkdir "$fixture/source"; printf video >"$fixture/source/show.mkv"; printf video >"$fixture/new-name.mkv"
arr_get() {
 case "$1" in
  */episode/11) printf '%s' "$fixture_target" >"$3";;
  */episodefile/21) printf '%s' "$fixture_file" >"$3";;
  */series/1) printf '%s' '{"id":1,"tvdbId":1001}' >"$3";;
  *) return 1;; esac
}
resolve_imported_path() { [[ "$2" == /library/new-name.mkv && -f "$fixture/new-name.mkv" ]] || return 1; printf '%s' "$fixture/new-name.mkv"; }
verify() { verify_durable_import_receipt Sonarr abc-123 "$fixture/source" "$fixture/proof.json" "$fixture_job"; }
hold() { if verify; then echo 'Unsafe durable proof accepted' >&2; exit 1; fi; }
verify
jq -e '.proofKind=="durable-import-receipt" and .verifiedImportedPaths==1 and .remainingSourceMediaFiles==1' "$fixture/proof.json" >/dev/null
proof_paths_still_valid "$fixture/proof.json"
# A second pack video cannot be covered by one imported file's receipt.
printf video >"$fixture/source/episode2.mkv"; hold; rm "$fixture/source/episode2.mkv"
fixture_target=$(jq '.episodeFileId=22' <<<"$fixture_target"); hold
fixture_target=$(jq '.episodeFileId=21|.seriesId=2' <<<"$fixture_target"); hold
fixture_target=$(jq '.seriesId=1' <<<"$fixture_target")
fixture_file=$(jq '.id=22' <<<"$fixture_file"); hold
fixture_file=$(jq '.id=21' <<<"$fixture_file")
jq '.receipts["Sonarr:abc-123"].targets.one.parentExternalId=1002' "$IMPORT_RECEIPT_FILE" >"$fixture/new"; mv "$fixture/new" "$IMPORT_RECEIPT_FILE"; hold
jq '.receipts["Sonarr:abc-123"].targets.one.parentExternalId=1001' "$IMPORT_RECEIPT_FILE" >"$fixture/new"; mv "$fixture/new" "$IMPORT_RECEIPT_FILE"
fixture_job=$(jq '.storage="/downloads/other"' <<<"$fixture_job"); hold
fixture_job=$(jq '.storage="/downloads/show"' <<<"$fixture_job")
rm "$fixture/new-name.mkv"; hold
printf video >"$fixture/new-name.mkv"
jq '.receipts["Sonarr:abc-123"].conflict=true' "$IMPORT_RECEIPT_FILE" >"$fixture/new"; mv "$fixture/new" "$IMPORT_RECEIPT_FILE"; hold
# An incomplete enumeration cannot manufacture zero remaining source videos.
eval "$(declare -f source_media_count | sed '1s/source_media_count/real_source_media_count/')"
find() { return 1; }
if real_source_media_count "$fixture/source"; then exit 1; fi
printf 'Durable proof survives renames; wrong IDs, packs, changed SAB identity, missing media and incomplete scans remain protected\n'
