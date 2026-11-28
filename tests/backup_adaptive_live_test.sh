#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1090
# Explicit opt-in: run on Hubble; only private RAM fixtures on both hosts.
# Owns the real ISS lease; no production payload, mounts or settings are changed.
set -euo pipefail
[[ ${BACKUP_ADAPTIVE_LIVE_ISS_TEST:-false} == true ]] || { echo 'Opt in with BACKUP_ADAPTIVE_LIVE_ISS_TEST=true on Hubble';exit 2; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
kind=${BACKUP_ADAPTIVE_LIVE_KIND:-media}
case "$kind" in media|vault) ;; *) exit 2;; esac
source "$ROOT/user_script/backup_${kind}_remote.sh"
fixture=$(mktemp -d /tmp/backup-adaptive-live.XXXXXX)
LOG_DIR=$fixture LOG_FILE=$fixture/test.log
TMP_DIR=$fixture
finish_test(){
 local rc=$?
 trap - EXIT INT TERM
 ba_cleanup || rc=1
 [[ -z ${REMOTE_FIXTURE:-} ]] || backup_ssh "rm -rf -- '$REMOTE_FIXTURE'" || rc=1
 [[ -z ${LEASE_INPUT:-} ]] || exec {LEASE_INPUT}>&-
 [[ -z ${LEASE_PID:-} ]] || { kill "$LEASE_PID" 2>/dev/null || true;wait "$LEASE_PID" 2>/dev/null || true; }
 [[ -z ${BACKUP_TMP:-} ]] || { ssh "${TRANSPORT_OPTIONS[@]}" -O exit "$REMOTE" >/dev/null 2>&1 || true;rm -rf "$BACKUP_TMP"; }
 rm -rf "$fixture"
 exit "$rc"
}
trap finish_test EXIT
trap 'exit 143' INT TERM
backup_transport_init
REMOTE_LEASE_WAIT_SECONDS=5
backup_acquire_lease
REMOTE_FIXTURE=$(backup_ssh 'mktemp -d /tmp/backup-adaptive-live.XXXXXX')
[[ "$REMOTE_FIXTURE" =~ ^/tmp/backup-adaptive-live\.[a-zA-Z0-9]+$ ]]
ba_init
[[ $BA_WRITE_SUMMARY == *'no parity disks'* ]] || { echo "Unexpected ISS write-mode inventory: $BA_WRITE_SUMMARY";exit 1; }
mkdir "$fixture/A" "$fixture/B"
dd if=/dev/urandom of="$fixture/A/file with spaces" bs=1M count=1 status=none
cp "$fixture/A/file with spaces" "$fixture/B/payload"
# Force fixture admission to two; production admission is covered by deterministic tests.
eval "$(declare -f ba_sample | sed '1s/ba_sample/native_ba_sample/')"
ba_sample(){ native_ba_sample;BA_TARGET=2; }
BA_TARGET=2
ba_disjoint(){ return 0; } # Fixture destinations deliberately live in /tmp, never /mnt.
rsync_label(){
 local label=$1 src=$2 dest=$3 rc=0
 rsync -a --stats --bwlimit=256 --rsync-path="$BA_RSYNC_PATH" "$src/" "$REMOTE:$dest/" >"$fixture/$label.stats" 2>&1 || rc=$?
 parse_rsync_stats "$fixture/$label.stats" "$label"
 RESULT_CODE[$label]=$rc RESULT_REASON[$label]=fixture
 ((rc==0))
}
if [[ "$kind" == media ]];then
 BACKUP_JOBS=("A|$fixture/A|$REMOTE_FIXTURE/A||0" "B|$fixture/B|$REMOTE_FIXTURE/B||0")
else
 REMOTE_PARTIAL=$REMOTE_FIXTURE
 backup_ssh "mkdir -p '$REMOTE_PARTIAL/manifests'"
 BACKUP_JOBS=("A|$fixture/A" "B|$fixture/B")
 RSYNC_ARGS+=(--bwlimit=256 "--rsync-path=$BA_RSYNC_PATH")
 backup_source_ready(){ [[ "$1" == "$fixture/"* && -d "$1" ]]; }
fi
ba_pool
[[ $BA_PEAK == 2 ]]
if [[ "$kind" == media ]];then [[ ${FILES_TRANSFERRED[A]} == 1 && ${FILES_TRANSFERRED[B]} == 1 ]]
else [[ $FILES_VERIFIED == 2 && $BYTES_TRANSFERRED == 2097152 ]];fi
local_hash=$(sha256sum "$fixture/A/file with spaces");local_hash=${local_hash%% *}
remote_hash=$(backup_ssh "bash '$BA_REMOTE/helper' run sha256sum '$REMOTE_FIXTURE/A/file with spaces'");remote_hash=${remote_hash%% *}
[[ $local_hash == "$remote_hash" ]]
remote_hash=$(backup_ssh "bash '$BA_REMOTE/helper' run sha256sum '$REMOTE_FIXTURE/B/payload'");remote_hash=${remote_hash%% *}
[[ $local_hash == "$remote_hash" ]]
backup_lease_alive
ba_cleanup
[[ $BA_REMOTE_READY == false ]]
printf 'Live Hubble/ISS %s: two bounded rsync jobs, native priorities, independent SHA read-back, no-parity skip and cleanup passed\n' "$kind"
