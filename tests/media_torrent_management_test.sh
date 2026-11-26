#!/bin/bash
# Real temporary-file moves with mocked read-only qBittorrent API responses.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/media_torrent_management.sh"
tmp=$(mktemp -d /tmp/torrent-transfer-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
QBIT_RUNTIME="$tmp/runtime"; mkdir -p "$QBIT_RUNTIME"
QBIT_CONTAINER_ROOT=/data; QBIT_HOST_ROOT="$tmp/secure"
COMPLETE_DIR="$QBIT_HOST_ROOT/torrent/complete"; DEST_DIR="$tmp/library"
TRANSFER_STATE_DIR="$tmp/state"; mkdir -p "$TRANSFER_STATE_DIR" "$COMPLETE_DIR" "$DEST_DIR"
OWN_USER=$(id -un); OWN_GROUP=$(id -gn)
build_rename_rules
jobs="$tmp/jobs.json"; printf '[]' >"$jobs"
api_fail=false
qbit_request() { [[ "$api_fail" != true ]] || return 1; cp "$jobs" "$2"; }
# Registered active folder must not block an immediately eligible orphan folder.
mkdir -p "$COMPLETE_DIR/phase1/active" "$COMPLETE_DIR/phase1/hhd800.com@orphan"
printf 'busy' >"$COMPLETE_DIR/phase1/active/incomplete.mkv"
printf 'complete' >"$COMPLETE_DIR/phase1/hhd800.com@orphan/hhd800.com@video.mkv"
printf 'advert' >"$COMPLETE_DIR/phase1/hhd800.com@orphan/advert.url"
jq -n '[{hash:"hash",content_path:"/data/torrent/complete/phase1/active",state:"downloading",progress:0.5,amount_left:4}]' >"$jobs"
process_category phase1 "$DEST_DIR/phase1"
[[ -f "$COMPLETE_DIR/phase1/active/incomplete.mkv" && ! -e "$DEST_DIR/phase1/active" ]]
[[ -f "$DEST_DIR/phase1/orphan/video.mkv" && ! -e "$DEST_DIR/phase1/orphan/advert.url" ]]
# Same immediate rule in private-category phase with no age/observation setup.
printf '[]' >"$jobs"
PRIVATE_CATEGORIES=(phase2); PRIVATE_DEST_ROOT="$DEST_DIR/private"
mkdir -p "$COMPLETE_DIR/phase2/new-folder"
printf 'fresh' >"$COMPLETE_DIR/phase2/new-folder/video.mkv"
process_private_categories
[[ -f "$PRIVATE_DEST_ROOT/phase2/new-folder/video.mkv" ]]
# Flat files normalize directly at destination; different collisions survive.
mkdir -p "$COMPLETE_DIR/flat" "$DEST_DIR/flat"
printf 'old' >"$DEST_DIR/flat/video.mkv"
printf 'new' >"$COMPLETE_DIR/flat/hhd800.com@video.mkv"
process_category flat "$DEST_DIR/flat"
[[ $(cat "$DEST_DIR/flat/video.mkv") == old && $(cat "$DEST_DIR/flat/video.dup1.mkv") == new ]]
# API outages/malformed JSON are not treated as empty torrent lists.
printf 'held' >"$COMPLETE_DIR/flat/held.mkv"
api_fail=true; process_category flat "$DEST_DIR/flat"
[[ -f "$COMPLETE_DIR/flat/held.mkv" && ! -e "$DEST_DIR/flat/held.mkv" ]]
api_fail=false; QBIT_API_UNAVAILABLE=false; printf '{}' >"$jobs"
! payload_completion_proven "$COMPLETE_DIR/flat/held.mkv"
QBIT_API_UNAVAILABLE=false; printf '[]' >"$jobs"
# Obvious incomplete files and links remain even when no torrents are registered.
printf partial >"$COMPLETE_DIR/flat/video.mkv.!qB"
! payload_completion_proven "$COMPLETE_DIR/flat/video.mkv.!qB"
ln -s "$COMPLETE_DIR/flat/held.mkv" "$COMPLETE_DIR/flat/link.mkv"
! payload_completion_proven "$COMPLETE_DIR/flat/link.mkv"
# Complete but seeding, queued or checking torrents are retained.
for state in uploading queuedUP checkingUP stoppedDL; do
 jq -n --arg state "$state" '[{hash:"hash",content_path:"/data/torrent/complete/flat/held.mkv",state:$state,progress:1,amount_left:0}]' >"$jobs"
 ! payload_completion_proven "$COMPLETE_DIR/flat/held.mkv"
done
# Matching complete stopped torrent remains eligible under the existing policy.
jq -n '[{hash:"hash",content_path:"/data/torrent/complete/flat/held.mkv",state:"stoppedUP",progress:1,amount_left:0}]' >"$jobs"
payload_completion_proven "$COMPLETE_DIR/flat/held.mkv"
printf 'Immediate phase-1/phase-2, active overlap, normalization, collision, API failure and partial-file tests passed\n'
