#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/user_script/arr_delete_sync_tag.sh"
fixture=$(mktemp -d /tmp/auxiliary-sidecar.XXXXXX)
fixture=$(realpath "$fixture")
trap 'rm -rf -- "$fixture"' EXIT
RUNTIME_DIR="$fixture"; AUTO_RECOGNIZE_KNOWN_AUXILIARY=true
mkdir -p "$fixture/media/.actors" "$fixture/media/extrafanart" "$fixture/media/unknown"
printf '\377\330\377\340image' >"$fixture/media/.actors/Actor.JPG"
printf 'not an image' >"$fixture/media/.actors/Invalid.jpg"
printf '\211PNG\r\n\032\nimage' >"$fixture/media/extrafanart/frame.png"
printf '\000\000\000\001Bud1data' >"$fixture/media/.DS_Store"
printf '[.ShellClassInfo]\nIconResource=folder.ico\n' >"$fixture/media/desktop.ini"
printf 'personal note' >"$fixture/media/unknown/data.bin"
is_known_auxiliary_sidecar sonarr .actors/Actor.JPG "$fixture/media/.actors/Actor.JPG"
is_known_auxiliary_sidecar sonarr extrafanart/frame.png "$fixture/media/extrafanart/frame.png"
is_known_auxiliary_sidecar sonarr .DS_Store "$fixture/media/.DS_Store"
is_known_auxiliary_sidecar sonarr desktop.ini "$fixture/media/desktop.ini"
if is_known_auxiliary_sidecar sonarr .actors/Invalid.jpg "$fixture/media/.actors/Invalid.jpg"; then exit 1; fi
if is_known_auxiliary_sidecar sonarr unknown/data.bin "$fixture/media/unknown/data.bin"; then exit 1; fi
# Even a real JPEG does not license an arbitrary directory or symlink.
cp "$fixture/media/.actors/Actor.JPG" "$fixture/media/unknown/photo.jpg"
if is_known_auxiliary_sidecar sonarr unknown/photo.jpg "$fixture/media/unknown/photo.jpg"; then exit 1; fi
ln -s "$fixture/media/.actors/Actor.JPG" "$fixture/media/.actors/link.jpg"
if is_known_auxiliary_sidecar sonarr .actors/link.jpg "$fixture/media/.actors/link.jpg"; then exit 1; fi
# First late scan captures candidates only; second identical scan confirms.
# Keep the unsafe invalid JPEG out of capture, not silently extension-allowlisted.
EXTRA_SIDECAR_EXTENSIONS="xml,json,txt,sfv,md5,sha1,sha256,url,webp"
manifest=$(jq -nc --arg path "$fixture/media" '{mediaPath:$path,files:[],lateSidecarCandidates:[]}')
plan=$(build_sidecar_cleanup_plan sonarr "$fixture/media" "$fixture" "$manifest")
jq -e '(.lateCandidates|length)==4 and (.moveEntries|length)==0' <<<"$plan" >/dev/null
printf '%s' "$plan" >"$fixture/plan.json"
manifest=$(jq --slurpfile plan "$fixture/plan.json" '.lateSidecarCandidates=$plan[0].lateCandidates' <<<"$manifest")
plan=$(build_sidecar_cleanup_plan sonarr "$fixture/media" "$fixture" "$manifest")
jq -e '(.lateConfirmed|length)==4 and (.moveEntries|length)==4' <<<"$plan" >/dev/null
printf 'Known content signatures and two stable observations required; arbitrary files and symlinks preserved\n'
