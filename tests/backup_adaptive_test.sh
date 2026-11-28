#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1090
# Controller fixtures have no production mount, payload, application or SSH access.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/bin:$PATH"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2;exit 1; }
source "$ROOT/user_script/backup_media_remote.sh"
ba_log(){ :; }
# Pressure decisions use counter deltas; high disk throughput alone is not load.
BA_CPU=0 BA_IO=4 BA_CPU_PRESSURE=0 BA_IO_PRESSURE=0
ba_observe hubble $'1000 500 0\n1 0\n80\n4' && fail 'first sample considered measured' || [[ $? == 2 ]]
ba_observe hubble $'2000 500 0\n8 0\n80\n4'
[[ $BA_CPU == 0 ]] || fail 'single CPU spike throttled'
ba_observe hubble $'3000 500 0\n8 0\n80\n4'
[[ $BA_CPU == 10 && $BA_IO == 4 ]] || fail 'CPU contention did not remain independent'
BA_CPU=0 BA_IO=4
ba_observe iss $'1000 500 0\n1 0\n80\n4' && fail baseline || [[ $? == 2 ]]
ba_observe iss $'2000 1000 300\n1 4\n80\n4'
ba_observe iss $'3000 1500 600\n1 4\n80\n4'
[[ $BA_CPU == 0 && $BA_IO == 7 ]] || fail 'I/O contention did not remain independent'
if ba_observe iss $'4000 2000 600\n1 0\n-1\n4';then fail 'missing memory evidence accepted';fi
if ba_observe iss 'not numeric';then fail 'malformed counters accepted';fi
# Admission waits for complete telemetry and five quiet minutes, including failures.
BA_REMOTE=x BA_PIDS=() BA_PREV_TOTAL=() BA_PREV_IDLE=() BA_PREV_WAIT=()
BA_CPU_QUIET=() BA_IO_QUIET=() BA_CPU_BUSY=() BA_IO_BUSY=()
BA_CPU=10 BA_IO=7 BA_QUIET=0 BA_TARGET=1 BA_DEGRADED=0
ba_tune_local(){ return 0; }
backup_ssh(){ [[ ${remote_missing:-false} != true ]] || return 1;[[ $* != *' sample'* ]] || printf '%s\n' "$telemetry"; }
ba_local_sample(){ printf '%s\n' "$telemetry"; }
for ((tick=1;tick<=12;tick++));do
 telemetry="$((tick*1000)) $((tick*500)) 0"$'\n1 0\n80\n4'
 ba_sample
done
[[ $BA_TARGET == 2 && $BA_CPU == 0 && $BA_IO == 4 ]] || fail 'quiet recovery/admission failed'
remote_missing=true;ba_sample
[[ $BA_TARGET == 1 && $BA_CPU == 10 && $BA_IO == 7 ]] || fail 'missing ISS telemetry did not restrict admission'
# Real worker result handoff retains each share's statistics without eval.
BA_ROOT="$fixture/workers";mkdir "$BA_ROOT";TMP_DIR="$fixture"
BACKUP_JOBS=('A|/source/a|/mnt/user/a||0' 'B|/source/b|/mnt/user/b||0' 'C|/source/c|/mnt/user/c||0')
ba_disjoint || fail 'independent destinations rejected'
BACKUP_JOBS+=('D|/source/d|/mnt/user/a/nested||0')
if ba_disjoint;then fail 'nested destinations accepted';fi
unset 'BACKUP_JOBS[3]'
# Portable fixtures mock priority setters only. Live tests separately verify native setters.
renice(){ :; };ionice(){ :; }
if [[ ! -r /proc/stat ]];then ba_stamp(){ kill -0 "$1" 2>/dev/null && printf 'fixture\n'; };fi
rsync_label(){
 local label=$1
 printf '%s start %s\n' "$label" "$(date +%s)" >>"$fixture/events"
 sleep 2
 RESULT_CODE[$label]=0 RESULT_REASON[$label]=Success TOTAL_BYTES[$label]=100 TRANSFERRED_BYTES[$label]=30 FILES_TRANSFERRED[$label]=3 DELETED_FILES[$label]=1 BYTES_SENT[$label]=20
 printf '%s finish %s\n' "$label" "$(date +%s)" >>"$fixture/events"
 if [[ ${worker_failure:-false} == true && $label == B ]];then RESULT_CODE[$label]=23;return 1;fi
}
ba_sample(){
 BA_TARGET=2
 # After admission, reducing the target drains both admitted workers normally.
 [[ ! -f "$fixture/admitted" ]] || BA_TARGET=1
 touch "$fixture/admitted"
}
BACKUP_ADAPTIVE_SAMPLE_SECONDS=1
BA_CPU=0 BA_IO=4 BA_SAMPLES=0 BA_DEGRADED=0 BA_PEAK=0 BA_PIDS=() BA_STAMPS=()
ba_pool
[[ $BA_PEAK == 2 && ${RESULT_CODE[A]} == 0 && ${FILES_TRANSFERRED[B]} == 3 && ${DELETED_FILES[C]} == 1 ]] || fail 'worker output or bounded pool failed'
[[ $(awk '$2=="finish"{n++}END{print n}' "$fixture/events") == 3 ]] || fail 'draining lost completed jobs'
worker_failure=true;rm "$fixture/admitted";BA_PIDS=() BA_STAMPS=()
if ba_pool;then fail 'one failed worker published overall success';fi
[[ ${RESULT_CODE[B]} == 23 ]] || fail 'failed worker code lost'
printf '{"index":1,"label":"B","rc":0}' >"$BA_ROOT/1.json"
if ba_accept 1 "${BACKUP_JOBS[1]}" 0;then fail 'incomplete result accepted';fi
rm "$BA_ROOT/1.json"
if ba_accept 1 "${BACKUP_JOBS[1]}" 0;then fail 'missing result accepted';fi
# Vault results sum verified totals and profiling once, without concurrent file appends.
ROOT="$ROOT" fixture="$fixture" bash <<'VAULT'
source "$ROOT/user_script/backup_vault_remote.sh"
BA_ROOT="$fixture/workers";TMP_DIR="$fixture"
BACKUP_JOBS=('A|/source/a' 'B|/source/b')
FILES_VERIFIED=0 BYTES_TRANSFERRED=0 VAULT_PROFILE_MANIFEST_MS=0 VAULT_PROFILE_TRANSFER_MS=0 VAULT_PROFILE_VERIFY_MS=0
declare -A MANIFEST_FILES=() MANIFEST_BYTES=() SOURCE_FINGERPRINT=()
for i in 0 1;do
 label=${BACKUP_JOBS[$i]%%|*}
 printf '{"index":%s,"label":"%s","rc":0,"files":4,"bytes":20,"transferred":20,"verified":4,"fingerprint":"stable","manifestMs":10,"transferMs":20,"verifyMs":30}' "$i" "$label" >"$BA_ROOT/$i.json"
 printf '{"stage":"source_manifest"}\n' >"$BA_ROOT/$i.profile"
 ba_accept "$i" "${BACKUP_JOBS[$i]}" 0
done
[[ $FILES_VERIFIED == 8 && $BYTES_TRANSFERRED == 40 && $VAULT_PROFILE_VERIFY_MS == 60 && $(wc -l <"$TMP_DIR/vault-profile.jsonl") == 2 ]] || fail 'vault aggregation duplicated or lost evidence'
VAULT
# Write-mode restoration needs our exact kernel receipt; later manual changes win.
source <(sed '/^case ${1:-} in/,$d' "$ROOT/tools/backup_adaptive_remote.sh")
root="$fixture/write";mkdir "$root"
[[ $(guard_timeout) == 120 ]] || fail 'default guardian timeout changed'
printf '930\n' >"$root/guard-timeout"
[[ $(guard_timeout) == 930 ]] || fail 'custom sampling interval guard rejected'
printf 'invalid\n' >"$root/guard-timeout"
[[ $(guard_timeout) == 120 ]] || fail 'invalid guardian timeout accepted'

write_record(){ cat "$root/kernel"; }
write_set(){ printf 'mdcmd (99): set md_write_method %s\n' "$1" >"$root/kernel"; }
printf 'auto\n' >"$root/write.original"
printf 'mdcmd (98): set md_write_method 1\n' >"$root/write.applied"
cp "$root/write.applied" "$root/kernel"
write_restore || fail 'original mode restore failed'
grep -q 'md_write_method auto' "$root/kernel" || fail 'Auto was not restored'
printf '0\n' >"$root/write.original"
printf 'mdcmd (101): set md_write_method 0\n' >"$root/kernel"
write_restore || fail 'manual mode change not respected'
grep -q '(101)' "$root/kernel" || fail 'manual change overwritten'
printf 'auto\n' >"$root/write.original";rm "$root/write.applied"
if write_restore;then fail 'missing apply receipt assumed ownership';fi
rm "$root/write.original"
write_safe(){ return 2; }
write_begin
grep -q 'no parity disks' "$root/write.status" || fail 'unprotected ISS was tuned'
printf 'Adaptive admission, draining, telemetry fallback, worker failures, vault aggregation and write-mode ownership fixtures passed\n'
