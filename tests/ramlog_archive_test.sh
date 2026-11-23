#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/ramlog-archive.XXXXXX); fixture=$(realpath "$fixture")
trap 'rm -rf -- "$fixture"' EXIT
source "$repo/user_script/ramlog_monitor.sh"
RAMLOG_PATH="$fixture/ramlogs"; VAULT_MOUNT="$fixture/vault"; ARCHIVE_ROOT="$VAULT_MOUNT/archives"
STATE_DIR="$fixture/state"; BOOT_ID_FILE="$fixture/boot-id"
mkdir -p "$RAMLOG_PATH/app" "$VAULT_MOUNT" "$STATE_DIR"
printf 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' >"$BOOT_ID_FILE"
printf 'first log\n' >"$RAMLOG_PATH/app/run.log"
ln -s /etc/passwd "$RAMLOG_PATH/app/ignored-link"
mountpoint() { [[ ${VAULT_DOWN:-false} != true || "$*" != *"$VAULT_MOUNT"* ]]; }
findmnt() { printf 'tmpfs\n'; }
sync() { return 0; }
archive_ramlogs manual
first=$(find "$ARCHIVE_ROOT" -mindepth 1 -maxdepth 1 -name 'ramlogs_*' -type d -print -quit)
(cd "$first" && sha256sum -c SHA256SUMS >/dev/null)
tar -tzf "$first/payload.tar.gz" | grep -qx 'app/run.log'
if tar -tzf "$first/payload.tar.gz" | grep -q ignored-link; then exit 1; fi
archive_ramlogs checkpoint
[[ $(find "$ARCHIVE_ROOT" -maxdepth 1 -name 'ramlogs_*' -type d | wc -l) == 1 ]]
printf 'second log\n' >>"$RAMLOG_PATH/app/run.log"
archive_ramlogs manual
[[ $(find "$ARCHIVE_ROOT" -maxdepth 1 -name 'ramlogs_*' -type d | wc -l) == 1 ]]
printf 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' >"$BOOT_ID_FILE"
archive_ramlogs manual
[[ $(find "$ARCHIVE_ROOT" -maxdepth 1 -name 'ramlogs_*' -type d | wc -l) == 2 ]]
printf 'third log\n' >>"$RAMLOG_PATH/app/run.log"
archive_ramlogs shutdown
[[ $(find "$ARCHIVE_ROOT" -maxdepth 1 -name 'ramlogs_*' -type d | wc -l) == 2 ]]
# New-boot periodic activity must preserve the previous boot's last checkpoint.
jq -s -e 'any(.[];.bootId=="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa") and any(.[];.bootId=="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" and .reason=="shutdown")' "$ARCHIVE_ROOT"/ramlogs_*/manifest.json >/dev/null
printf 'cccccccc-cccc-cccc-cccc-cccccccccccc' >"$BOOT_ID_FILE"
archive_ramlogs manual
[[ $(find "$ARCHIVE_ROOT" -maxdepth 1 -name 'ramlogs_*' -type d | wc -l) == 2 ]]
if grep -q aaaaaaaa "$ARCHIVE_ROOT"/ramlogs_*/manifest.json; then exit 1; fi
printf 'Capture/CRC/hash verification, link exclusion, same-boot rollover and two-boot retention passed\n'
before=$(find "$ARCHIVE_ROOT" -name payload.tar.gz -exec sha256sum {} + | sort)
VAULT_DOWN=true
if archive_ramlogs manual; then exit 1; fi
VAULT_DOWN=false
[[ "$before" == "$(find "$ARCHIVE_ROOT" -name payload.tar.gz -exec sha256sum {} + | sort)" ]]
# A failed tar must never replace or prune the last successful generations.
real_tar=$(command -v tar)
tar() { if [[ ${1:-} == --version ]]; then command tar --version; else return 2; fi; }
if archive_ramlogs manual; then exit 1; fi
unset -f tar
[[ "$before" == "$(find "$ARCHIVE_ROOT" -name payload.tar.gz -exec sha256sum {} + | sort)" ]]
[[ -z $(find "$ARCHIVE_ROOT" -maxdepth 1 -name '.ramlog-*.partial' -print -quit) ]]
# Compressed output cap is enforced before promotion; source files remain intact.
ARCHIVE_MAX_BYTES=1024
dd if=/dev/urandom of="$RAMLOG_PATH/app/random.log" bs=4096 count=8 2>/dev/null
if archive_ramlogs manual; then exit 1; fi
[[ -f "$RAMLOG_PATH/app/random.log" && "$before" == "$(find "$ARCHIVE_ROOT" -name payload.tar.gz -exec sha256sum {} + | sort)" ]]
rm "$RAMLOG_PATH/app/random.log"
ARCHIVE_MAX_BYTES=$((256*1024*1024))
printf 'Compressed-size cap rejects oversized output without replacing completed archives\n'
# Recognizable interrupted staging is cleaned while completed archives survive.
partial="$ARCHIVE_ROOT/.ramlog-interrupted.partial"; mkdir "$partial"
printf ramlog_archive >"$partial/.owner"; printf unfinished >"$partial/payload.tar.gz"
archive_ramlogs checkpoint
[[ ! -e "$partial" ]]
printf 'Missing vault, failed capture and interrupted staging preserve completed archives\n'
# Event adapter is idempotent, bounded, and preserves unrecognized hooks.
ARCHIVE_HOOK_ROOT="$fixture/hook"; EMHTTP_EVENT="$fixture/emhttp_event"; INSTALLED_SCRIPT="$repo/user_script/ramlog_monitor.sh"
printf '# unmounting_disks\n' >"$EMHTTP_EVENT"
# Fixture hook root meets the production /tmp namespace rule on Linux/macOS.
ARCHIVE_HOOK_ROOT="/tmp/$(basename "$fixture")/hook"
install_archive_hook
bash -n "$ARCHIVE_HOOK_ROOT/event/unmounting_disks"
grep -q -- '--archive shutdown' "$ARCHIVE_HOOK_ROOT/event/unmounting_disks"
previous=$(sha256sum "$ARCHIVE_HOOK_ROOT/event/unmounting_disks")
install_archive_hook
[[ "$previous" == "$(sha256sum "$ARCHIVE_HOOK_ROOT/event/unmounting_disks")" ]]
printf '#!/bin/sh\n# foreign hook\n' >"$ARCHIVE_HOOK_ROOT/event/unmounting_disks"
if install_archive_hook; then exit 1; fi
grep -q 'foreign hook' "$ARCHIVE_HOOK_ROOT/event/unmounting_disks"
printf 'Boot event registration, idempotence and foreign-hook preservation passed\n'
# The automatic wrapper times out the whole worker/process group, not just tar.
export RAMLOG_PATH VAULT_MOUNT ARCHIVE_ROOT STATE_DIR BOOT_ID_FILE
export -f mountpoint findmnt sync
tar() { if [[ ${1:-} == --version ]]; then command tar --version; else sleep 10; fi; }
export -f tar
ARCHIVE_TIMEOUT_SECONDS=1
if run_ramlog_archive manual; then exit 1; fi
[[ "$ARCHIVE_LAST_ERROR" == *'exit=124'* && "$before" == "$(find "$ARCHIVE_ROOT" -name payload.tar.gz -exec sha256sum {} + | sort)" ]]
unset -f tar
printf 'Bounded worker timeout preserves completed snapshots\n'
