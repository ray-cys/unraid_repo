#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/media_torrent_management.sh"
build_rename_rules
check(){ local got;got=$(clean_name "$1" "${3:-file}");[[ "$got" == "$2" ]] || { printf 'Expected %s; got %s\n' "$2" "$got";exit 1; }; }
check 'new-site.example@abf00123_1080p.mp4' 'ABF-00123.mp4'
check 'pppd528.mp4' 'PPPD-528.mp4'
check 'hhd800.com@ABC-123.mp4' 'ABC-123.mp4'
check 'ABC-123-C_GG5.mp4' 'ABC-123.mp4'
check 'ABC-123-C_X1080X.mp4' 'ABC-123.mp4'
check 'ABC-123-C.mp4' 'ABC-123.mp4'
check 'ABC-123ch.mp4' 'ABC-123.mp4'
check 'ABC-123ch1080p.mp4' 'ABC-123.mp4'
check 'ABC-123-A.mp4' 'ABC-123-A.mp4'
check 'ABC-123-1.mp4' 'ABC-123-1.mp4'
check 'ABC-123-_.mp4' 'ABC-123.mp4'
check '259luxu_1922.mp4' '259LUXU-1922.mp4'
check '812mmc032.mp4' '812MMC-032.mp4'
check 't38-050.mp4' 'T38-050.mp4'
check 'ABC-123 part02.MP4' 'ABC-123 - cd2.mp4'
check 'ABC-123-cd01.mp4' 'ABC-123 - cd1.mp4'
check 'ABC-123 - cd1.mp4' 'ABC-123 - cd1.mp4'
check 'ABC-123 XYZ-456.mp4' 'ABC-123 XYZ-456.mp4'
check 'ABC-123 (scene 5).mp4' 'ABC-123 (scene 5).mp4'
check 'ABC-123.mp4.dup1' 'ABC-123.mp4'
check 'ABC-123.dup1.mp4' 'ABC-123.mp4'
check 'ABC-123B.mp4' 'ABC-123B.mp4'
check 'Title without a code.mp4' 'Title without a code.mp4'
check 'Scene 12.mp4' 'Scene 12.mp4'
check '20261126_123456.mp4' '20261126_123456.mp4'
check 'FC2-PPV-1234567.mp4' 'FC2-PPV-1234567.mp4'
check 'ABC-123.en.srt' 'ABC-123.en.srt'
check 'ABC-123-poster.jpg' 'ABC-123-poster.jpg'
check 'new-site.example@abc123_1080p' 'ABC-123' directory
check 'Actor.Name' 'Actor.Name' directory
# Real child renames preserve content and multipart identities without copies.
tmp=$(mktemp -d /tmp/torrent-jav-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/new-site.example@abc123"
printf one >"$tmp/new-site.example@abc123/abc123-part1.mp4"
printf two >"$tmp/new-site.example@abc123/abc123-part2.mp4"
normalize_names "$tmp" || exit 1
[[ $(cat "$tmp/ABC-123/ABC-123 - cd1.mp4") == one ]]
[[ $(cat "$tmp/ABC-123/ABC-123 - cd2.mp4") == two ]]
[[ $(find "$tmp" -type f|wc -l) -eq 2 ]]
# Source directories converging on one name merge without duplicate suffixes.
mkdir -p "$tmp/merge/hhd800.com@ABC123" "$tmp/merge/ABC-123"
printf incoming >"$tmp/merge/hhd800.com@ABC123/movie.mp4"
printf old >"$tmp/merge/ABC-123/movie.mp4"
normalize_names "$tmp/merge" || exit 1
[[ $(cat "$tmp/merge/ABC-123/movie.mp4") == incoming ]]
[[ $(find "$tmp/merge" -type f|wc -l) -eq 1 ]]
printf 'Jav18 release IDs, numeric studio prefixes, multipart, uncertainty and in-place naming passed\n'
# Real local Git branch checks: unchanged revision does not replace the WebUI;
# changed revision refreshes it; unreachable upstream preserves current files.
mkdir "$tmp/upstream" "$tmp/webui"
git -C "$tmp/upstream" init -q
git -C "$tmp/upstream" config user.email fixture@example.invalid
git -C "$tmp/upstream" config user.name Fixture
git -C "$tmp/upstream" checkout -qb latest-release
mkdir -p "$tmp/upstream/public/assets"
printf 'console.log(1);' >"$tmp/upstream/public/assets/main.js"
printf '<!doctype html><html><script src="./assets/main.js"></script><body>first</body></html>' >"$tmp/upstream/public/index.html"
git -C "$tmp/upstream" add .;git -C "$tmp/upstream" commit -qm initial
VUETORRENT_REPO="file://$tmp/upstream";VUETORRENT_DIR="$tmp/webui"
git clone -q --branch latest-release "$VUETORRENT_REPO" "$tmp/webui/VueTorrent"
printf sentinel >"$tmp/webui/VueTorrent/local-sentinel"
update_vuetorrent || exit 1
[[ -f "$tmp/webui/VueTorrent/local-sentinel" ]]
sed 's/first/second/' "$tmp/upstream/public/index.html" >"$tmp/index.new";mv "$tmp/index.new" "$tmp/upstream/public/index.html"
git -C "$tmp/upstream" add .;git -C "$tmp/upstream" commit -qm second
update_vuetorrent || exit 1
grep -q second "$tmp/webui/VueTorrent/public/index.html"
# Missing referenced assets reject a successful clone before replacing live UI.
sed 's|</html>|<link href="assets/missing.css" rel="stylesheet"></html>|' "$tmp/upstream/public/index.html" >"$tmp/index.new";mv "$tmp/index.new" "$tmp/upstream/public/index.html"
git -C "$tmp/upstream" add .;git -C "$tmp/upstream" commit -qm invalid-assets
if update_vuetorrent;then exit 1;fi
[[ ! -d "$tmp/webui/VueTorrent.old.$$" ]]
grep -q second "$tmp/webui/VueTorrent/public/index.html"
! grep -q missing.css "$tmp/webui/VueTorrent/public/index.html"
# Flat release layout is also accepted; incomplete or non-HTML pages are not.
mkdir -p "$tmp/flat/assets";cp "$tmp/upstream/public/assets/main.js" "$tmp/flat/assets/"
printf '<html><script src="/assets/main.js?v=1"></script></html>' >"$tmp/flat/index.html"
vuetorrent_valid "$tmp/flat"
rm "$tmp/flat/assets/main.js"
if vuetorrent_valid "$tmp/flat";then exit 1;fi
VUETORRENT_REPO="file://$tmp/nonexistent"
if update_vuetorrent;then exit 1;fi
grep -q second "$tmp/webui/VueTorrent/public/index.html"
printf 'VueTorrent unchanged/changed/unavailable upstream checks passed\n'
