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
# Flat files replace same-name destinations, even with equal size/mtime.
mkdir -p "$COMPLETE_DIR/flat" "$DEST_DIR/flat"
printf 'old' >"$DEST_DIR/flat/video.mkv"
printf 'new' >"$COMPLETE_DIR/flat/hhd800.com@video.mkv"
touch -r "$DEST_DIR/flat/video.mkv" "$COMPLETE_DIR/flat/hhd800.com@video.mkv"
process_category flat "$DEST_DIR/flat"
[[ $(cat "$DEST_DIR/flat/video.mkv") == new && ! -e "$DEST_DIR/flat/video.dup1.mkv" ]]
# Folder payloads also replace equal-size/equal-time targets without .dup names.
mkdir -p "$COMPLETE_DIR/folder/item" "$DEST_DIR/folder/item"
printf old >"$DEST_DIR/folder/item/movie.mp4";printf new >"$COMPLETE_DIR/folder/item/movie.mp4"
touch -r "$DEST_DIR/folder/item/movie.mp4" "$COMPLETE_DIR/folder/item/movie.mp4"
process_category folder "$DEST_DIR/folder"
[[ $(cat "$DEST_DIR/folder/item/movie.mp4") == new ]]
[[ -z $(find "$DEST_DIR" -name '*.dup*' -print -quit) ]]
# Unwanted exact names must be removed before they can normalize over real media.
saved_unwanted=("${UNWANTED_NAMES[@]}");UNWANTED_NAMES=(ABC-123-extra.mp4)
mkdir -p "$COMPLETE_DIR/prune/item"
printf good >"$COMPLETE_DIR/prune/item/ABC-123.mp4"
printf bad >"$COMPLETE_DIR/prune/item/ABC-123-extra.mp4"
process_category prune "$DEST_DIR/prune"
[[ $(cat "$DEST_DIR/prune/item/ABC-123.mp4") == good ]]
UNWANTED_NAMES=("${saved_unwanted[@]}")
# Mover appearing after source preparation defers rsync and leaves a resumable
# category_deferred checkpoint. No partial destination video is published.
mover_checks=0
mover_clear(){ mover_checks=$((mover_checks+1));((mover_checks<2)) || return 75; }
mkdir -p "$COMPLETE_DIR/mover/item";printf held >"$COMPLETE_DIR/mover/item/movie.mp4"
rc=0;process_category mover "$DEST_DIR/mover" || rc=$?
[[ "$rc" == 75 && -f "$COMPLETE_DIR/mover/item/movie.mp4" && ! -f "$DEST_DIR/mover/item/movie.mp4" ]]
jq -e '.phase=="category_deferred"' "$TRANSFER_STATE_DIR/state.json" >/dev/null
mover_clear(){ return 0; }
process_category mover "$DEST_DIR/mover"
[[ $(cat "$DEST_DIR/mover/item/movie.mp4") == held ]]
# Private categories preserve the same Mover deferral code.
PRIVATE_CATEGORIES=(private-mover);mkdir -p "$COMPLETE_DIR/private-mover/item"
printf held >"$COMPLETE_DIR/private-mover/item/movie.mp4"
mover_clear(){ return 75; }
rc=0;process_private_categories || rc=$?
[[ "$rc" == 75 && -f "$COMPLETE_DIR/private-mover/item/movie.mp4" ]]
mover_clear(){ return 0; }
# A failed transfer retains the source and old destination without counting a
# successful replacement.
rsync(){ return 23; }
mkdir -p "$COMPLETE_DIR/failed/item" "$DEST_DIR/failed/item"
printf old >"$DEST_DIR/failed/item/movie.mp4";printf incoming >"$COMPLETE_DIR/failed/item/movie.mp4"
prior_transferred=$RUN_TRANSFERRED_FILES
if process_category failed "$DEST_DIR/failed";then exit 1;fi
[[ $(cat "$DEST_DIR/failed/item/movie.mp4") == old && -f "$COMPLETE_DIR/failed/item/movie.mp4" && "$RUN_TRANSFERRED_FILES" == "$prior_transferred" ]]
unset -f rsync
# A symlink destination is never followed or overwritten.
mkdir -p "$COMPLETE_DIR/linkdest/item" "$DEST_DIR/linkdest/item"
printf untouched >"$tmp/protected";ln -s "$tmp/protected" "$DEST_DIR/linkdest/item/movie.mp4"
printf incoming >"$COMPLETE_DIR/linkdest/item/movie.mp4"
if process_category linkdest "$DEST_DIR/linkdest";then exit 1;fi
[[ $(cat "$tmp/protected") == untouched && -f "$COMPLETE_DIR/linkdest/item/movie.mp4" ]]
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
printf 'Immediate phase-1/phase-2, active overlap, normalization, overwrite, prune-first, Mover deferral/resume, symlink, API failure and partial-file tests passed\n'
