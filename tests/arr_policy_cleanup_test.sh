#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/sabnzbd_cleanup.sh"
trap - EXIT INT TERM HUP
fixture=$(mktemp -d /tmp/arr-policy-cleanup.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
TMP_DIR="$fixture"; POLICY_DISPOSITION_FILE="$fixture/receipts.json"
SONARR_URL=http://fixture; SONARR_API_KEY=fixture
fixture_item='{"nzo_id":"abc-123","name":"Show.S01E01","storage":"/download/show","completed":123,"category":"tv"}'
jq -n --argjson sab "$fixture_item" '{version:1,actions:{"abc-123":{downloadId:"abc-123",app:"Sonarr",status:"done",queueVerified:true,mode:"redundant",kind:"episode",targetId:11,parentId:1,fileId:21,filePath:"/library/show.mkv",target:{seasonNumber:1,episodeNumber:1},sab:$sab}}}' >"$POLICY_DISPOSITION_FILE"
fixture_target='{"id":11,"seriesId":1,"seasonNumber":1,"episodeNumber":1,"hasFile":true,"episodeFileId":21,"monitored":true}'
fixture_parent='{"id":1,"monitored":true,"tags":[]}'
fixture_file='{"id":21,"seriesId":1,"path":"/library/show.mkv"}'
arr_get() {
 case "$1" in
 */episode/11) printf '%s' "$fixture_target" >"$3";;
 */series/1) printf '%s' "$fixture_parent" >"$3";;
 */episodefile/21) printf '%s' "$fixture_file" >"$3";;
 *) return 1;; esac
}
source_media_count() { printf '%s' "${fixture_count:-1}"; }
resolve_imported_path() { [ "${fixture_missing:-false}" != true ] || return 1; printf '%s' "$fixture/library.mkv"; }
printf 'media' >"$fixture/library.mkv"
stat_size() { printf 5; }
verify() { verify_policy_disposition Sonarr abc-123 /downloads/show "$fixture/proof.json" "$fixture_item"; }
refuse() { if verify; then echo 'unsafe cleanup proof admitted' >&2; exit 1; fi; }
verify
jq -e '.proofKind=="policy-disposition" and .importEvents==0' "$fixture/proof.json" >/dev/null
proof_paths_still_valid "$fixture/proof.json"
fixture_count=2; refuse; fixture_count=1
fixture_missing=true; refuse; fixture_missing=false
fixture_target=$(jq '.episodeFileId=22' <<<"$fixture_target"); refuse
fixture_target=$(jq '.episodeFileId=21|.monitored=false' <<<"$fixture_target"); refuse
fixture_target=$(jq '.monitored=true' <<<"$fixture_target")
fixture_item=$(jq '.storage="/downloads/other"' <<<"$fixture_item"); refuse
fixture_item=$(jq '.storage="/download/show"' <<<"$fixture_item")
jq '.actions["abc-123"] += {mode:"replace",commandId:42}' "$POLICY_DISPOSITION_FILE" >"$fixture/new"; mv "$fixture/new" "$POLICY_DISPOSITION_FILE"
fixture_target=$(jq '.hasFile=false|.episodeFileId=0' <<<"$fixture_target")
verify; proof_paths_still_valid "$fixture/proof.json"
jq '.actions["abc-123"].status="search_uncertain"' "$POLICY_DISPOSITION_FILE" >"$fixture/new"; mv "$fixture/new" "$POLICY_DISPOSITION_FILE"; refuse
printf 'Policy quarantine receipt, retained destination, payload identity and pack protection tests passed\n'
