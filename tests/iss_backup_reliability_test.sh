#!/usr/bin/env bash
# Real rsync/filesystem fixtures; SSH and Unraid mount discovery are isolated.
# shellcheck disable=SC1090,SC2034,SC2329
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/iss-backup-tests.XXXXXX)
trap 'rm -rf -- "${TEST_ROOT:?}"' EXIT
TEST_ROOT=$(realpath "$TEST_ROOT")
export TEST_ROOT ROOT
# GNU interfaces match Unraid; macOS CI/development can use Homebrew tools.
export PATH="/opt/homebrew/opt/findutils/libexec/gnubin:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/bin:$PATH"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for cmd in bash rsync flock jq sha256sum find sort stat; do command -v "$cmd" >/dev/null || fail "missing $cmd"; done
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/run"
cat >"$TEST_ROOT/bin/fake-ssh" <<'SSH'
#!/usr/bin/env bash
set -e
while [[ $# -gt 0 && "$1" != fixture ]]; do shift; done
shift
exec bash -c "$*"
SSH
chmod 755 "$TEST_ROOT/bin/fake-ssh"
# Each source is loaded in a separate shell, exactly as standalone User Scripts.
for SCRIPT_ID_TEST in remote_backup vault_backup; do
export SCRIPT_ID_TEST
bash <<'FIXTURE'
set -euo pipefail
source "$ROOT/user_script/$SCRIPT_ID_TEST.sh"
eval "$(declare -f backup_transport_init | sed '1s/backup_transport_init/original_transport_init/')"
fail() { printf 'FAIL (%s): %s\n' "$SCRIPT_ID_TEST" "$*" >&2; exit 1; }
log_file="$TEST_ROOT/$SCRIPT_ID_TEST.log"
LOG_FILE="$log_file"; LOG_DIR="$TEST_ROOT"; RAW_LOG_DIR="$TEST_ROOT/raw"; mkdir -p "$RAW_LOG_DIR"
BACKUP_TMP="$TEST_ROOT/transport-$SCRIPT_ID_TEST"; mkdir -p "$BACKUP_TMP"
REMOTE_BACKUP_LOCK=/run/fixture-iss.lock
backup_ssh() {
    local arg command=""; local -a args=()
    for arg in "$@"; do arg=${arg//\/run\//$TEST_ROOT/run/}; args+=("$arg"); done
    if (( ${#args[@]} == 1 )); then bash -c "${args[0]}"; else "${args[@]}"; fi
}
# Source availability is tested independently; fixture transfers use /tmp.
if backup_source_ready /; then fail 'root source accepted'; fi
if backup_source_ready "$TEST_ROOT"; then fail 'unexpected filesystem accepted'; fi
backup_acquire_lease || fail 'first lease unavailable'
backup_lease_alive || fail 'live lease not recognized'
printf '%s\n' "$BASHPID" >"$TEST_ROOT/run/fixture-iss.lock.waiter.fixture"
if backup_shutdown_handoff; then fail 'shutdown permitted while another backup waits'; fi
[[ "$SHUTDOWN_RESULT" == deferred ]] || fail 'normal handoff not distinguished from failure'
rm "$TEST_ROOT/run/fixture-iss.lock.waiter.fixture"
SHUTDOWN_RESULT=not_requested; REMOTE_SHUTDOWN_SKIPPED_REASON=""
backup_shutdown_handoff || fail 'empty queue falsely blocked shutdown' 
# A second independent process must be excluded by the same remote lock.
if (flock -n "$TEST_ROOT/run/fixture-iss.lock" true); then fail 'overlap acquired active remote lock'; fi
printf 'x' >"$TEST_ROOT/run/hubble-iss-shutdown.pending"
# Release live stdin; the real flock worker must exit on EOF.
exec {LEASE_INPUT}>&-
wait "$LEASE_PID"
LEASE_INPUT=""; LEASE_PID=""
if backup_acquire_lease; then fail 'unverifiable shutdown reservation ignored'; fi
[[ -z "$LEASE_INPUT" ]] || exec {LEASE_INPUT}>&-
wait "$LEASE_PID" 2>/dev/null || true
LEASE_INPUT=""; LEASE_PID=""
rm "$TEST_ROOT/run/hubble-iss-shutdown.pending"
backup_acquire_lease || fail 'lease not reusable after disconnect'
# Bounded logs keep a tail, not multiple full-size copies.
printf '%010000d' 1 >"$TEST_ROOT/large-$SCRIPT_ID_TEST.log"
backup_bound_log "$TEST_ROOT/large-$SCRIPT_ID_TEST.log" 512
[[ $(stat -c %s "$TEST_ROOT/large-$SCRIPT_ID_TEST.log") == 512 ]] || fail 'log cap not enforced'
if [[ "$SCRIPT_ID_TEST" == remote_backup ]]; then
    RSYNC_RSH="$TEST_ROOT/bin/fake-ssh"
    MAX_DELETIONS=1
    build_rsync_args opts '' 0 actual
    [[ " ${opts[*]} " == *' --max-delete=1 '* && " ${opts[*]} " == *' --timeout=300 '* ]] || fail 'rsync limits omitted'
    [[ " ${opts[*]} " == *' -H '* ]] || fail 'hard link policy lost'
    src="$TEST_ROOT/mirror source"; dst="$TEST_ROOT/mirror dest"; mkdir -p "$src" "$dst"
    printf original >"$src/media.mkv"
    printf protect >"$dst/.hubble-backup-identity"
    printf old >"$dst/old1"; printf old >"$dst/old2"
    if rsync "${opts[@]}" "$src/" "fixture:$dst/" >"$TEST_ROOT/delete.log" 2>&1; then fail 'deletion cap falsely succeeded'; fi
    [[ -f "$dst/.hubble-backup-identity" ]] || fail 'identity marker deleted'
    [[ -f "$dst/old1" || -f "$dst/old2" ]] || fail 'deletion cap failed to retain excess'
    # Run the complete mirror workflow, with only host discovery/SSH isolated.
    backup_source_ready() { [[ -d "$1" && ! -L "$1" ]]; }
    backup_destination() { [[ -d "$3" && ! -L "$3" ]]; }
    backup_capabilities() { :; }
    backup_transport_init() { export RSYNC_RSH="$TEST_ROOT/bin/fake-ssh"; TRANSPORT_OPTIONS=(); }
    wait_for_remote_ready() { REMOTE_READY=1; }
    mountpoint() { return 0; }
    REMOTE=fixture; ENABLE_WOL=false; SHUTDOWN_REMOTE_ON_SUCCESS=false
    LOCK_FILE="$TEST_ROOT/mirror.local.lock"
    STATUS_DIR="$TEST_ROOT/mirror-main-status"
    NOTIFY_BIN="$TEST_ROOT/main-notify"; printf '#!/bin/sh\nexit 0\n' >"$NOTIFY_BIN"; chmod 755 "$NOTIFY_BIN"
    BACKUP_JOBS=("Media|$src|$dst||0")
    exec {LEASE_INPUT}>&-; wait "$LEASE_PID"; LEASE_INPUT=""; LEASE_PID=""
    if (main) >"$TEST_ROOT/mirror-main.log" 2>&1; then :; else cat "$TEST_ROOT/mirror-main.log"; fail 'complete mirror workflow failed'; fi
    cmp "$src/media.mkv" "$dst/media.mkv" || fail 'main mirror data mismatch'
    jq -e '.copy == "OK" and .verification == "rsync_transfer_verified"' "$STATUS_DIR/remote_backup.json" >/dev/null || fail 'main mirror receipt wrong'
    backup_acquire_lease || fail 'main mirror leaked remote lease'
    # Exercise the existing aggregate-capacity arithmetic with controlled data.
    BACKUP_JOBS=('Media|/mnt/user/media|/mnt/user/media||0')
    estimate_job_change() { ESTIMATED_BYTES[$1]=200; }
    remote_df() { printf 'fixture-device|1000|/mnt/user\n'; }
    PREFLIGHT_MODE=estimate; PREFLIGHT_MIN_BUFFER_BYTES=10; PREFLIGHT_BUFFER_PERCENT=5
    preflight_space || fail 'valid aggregate space rejected'
    remote_df() { printf 'fixture-device|100|/mnt/user\n'; }
    if preflight_space; then fail 'insufficient space accepted'; fi
else
    REMOTE=fixture
    export RSYNC_RSH="$TEST_ROOT/bin/fake-ssh"
    TMP_DIR="$TEST_ROOT/vault-work"; mkdir -p "$TMP_DIR"
    REMOTE_VERSION_ROOT="$TEST_ROOT/remote versions"; mkdir -p "$REMOTE_VERSION_ROOT"
    src="$TEST_ROOT/vault source"; mkdir -p "$src"
    printf 'payload 1' >"$src/file with spaces"
    printf 'linebreak' >"$src/"$'name\nwith-newline'
    mkdir -p "$src/ignored.partial"; printf unfinished >"$src/ignored.partial/work"
    BACKUP_JOBS=("photos|$src")
    backup_source_ready() { [[ -d "$1" && ! -L "$1" ]]; }
    remote_prepare || fail 'partial prepare failed'
    initial_partial=$REMOTE_PARTIAL
    rsync -a "$src/" "$REMOTE_PARTIAL/photos/"
    remote_prepare || fail 'compatible partial cannot resume'
    [[ "$REMOTE_PARTIAL" == "$initial_partial" && -f "$REMOTE_PARTIAL/photos/file with spaces" ]] || fail 'resumption discarded staged data'
    DRY_RUN=false; PRIORITY_PREFIX=(); VAULT_RESERVE_BYTES=0
    RSYNC_ARGS+=(--timeout=300)
    build_manifest photos "$src" "$TMP_DIR/photos.sha256" || fail 'manifest creation failed'
    [[ ${MANIFEST_FILES[photos]} == 2 && ${MANIFEST_BYTES[photos]} == 18 ]] || fail 'manifest stats/filter mismatch'
    # A staged corruption with matching size+mtime defeats quick-check, but
    # verification must detect and repair it on a checksum-based retry.
    printf 'corrupt!!' >"$REMOTE_PARTIAL/photos/file with spaces"
    touch -r "$src/file with spaces" "$REMOTE_PARTIAL/photos/file with spaces"
    sleep() { :; }
    transfer_job photos "$src" "$TMP_DIR/photos.sha256" || fail 'checksum-based repair/resume failed'
    cmp "$src/file with spaces" "$REMOTE_PARTIAL/photos/file with spaces" || fail 'corruption survived verification'
    [[ ! -e "$REMOTE_PARTIAL/photos/ignored.partial" ]] || fail 'incomplete artifacts copied'
    [[ "$FILES_VERIFIED" == 2 ]] || fail 'verified file count incorrect'
    # An actual source write between rsync and verification must force a fresh
    # manifest and retry rather than promote an inconsistent source generation.
    rsync() {
        command rsync "$@" || return $?
        local arg
        for arg in "$@"; do
            if [[ "$arg" == "$src/" && ! -f "$TEST_ROOT/source-mutated" ]]; then
                printf '%s' '-changed' >>"$src/file with spaces"
                : >"$TEST_ROOT/source-mutated"
                break
            fi
        done
    }
    transfer_job photos "$src" "$TMP_DIR/photos.sha256" || fail 'changing-source retry failed'
    unset -f rsync
    cmp "$src/file with spaces" "$REMOTE_PARTIAL/photos/file with spaces" || fail 'changing source not reconciled'
    # Space preflight never deletes old generations to make room.
    mkdir -p "$REMOTE_VERSION_ROOT/hubble-20260101_000000"
    printf old >"$REMOTE_VERSION_ROOT/hubble-20260101_000000/keep"
    VAULT_RESERVE_BYTES=999999999999999999
    if vault_space_preflight; then fail 'insufficient vault space accepted'; fi
    [[ -f "$REMOTE_VERSION_ROOT/hubble-20260101_000000/keep" ]] || fail 'preflight deleted previous generation'
    VAULT_RESERVE_BYTES=0
    promote_generation || fail 'verified generation promotion failed'
    [[ -f "$REMOTE_FINAL/completed.txt" && -f "$REMOTE_FINAL/photos/file with spaces" ]] || fail 'restore-ready marker/content missing'
    # A second promotion must not nest a partial inside an existing generation.
    mkdir -p "$REMOTE_PARTIAL/manifests"
    if promote_generation; then fail 'existing generation overwritten'; fi
    # Only complete generations count toward retention; unknown partials stay.
    mkdir -p "$REMOTE_VERSION_ROOT/.hubble-unknown.partial"
    REMOTE_KEEP=1
    prune_remote_generations || fail 'retention failed'
    [[ -f "$REMOTE_FINAL/completed.txt" && -f "$REMOTE_VERSION_ROOT/hubble-20260101_000000/keep" ]] || fail 'unmarked directory pruned'
    [[ -d "$REMOTE_VERSION_ROOT/.hubble-unknown.partial" ]] || fail 'unknown partial removed'
    # Execute the complete vault workflow too; only Unraid readiness/producer
    # lock discovery are replaced. Transfers, manifests, promotion, retention,
    # outcome receipts and lease acquisition/release run normally.
    backup_capabilities() { :; }
    backup_transport_init() { export RSYNC_RSH="$TEST_ROOT/bin/fake-ssh"; TRANSPORT_OPTIONS=(); }
    wait_for_remote() { :; }
    vault_producer_locks() { :; }
    # Retain the real validator; substitute only the isolated /tmp namespace
    # for the production /mnt/user prefix.
    eval "$(declare -f validate_configuration | sed "s#/mnt/user/#$TEST_ROOT/#g")"
    mountpoint() { return 0; }
    saved_jobs=("${BACKUP_JOBS[@]}")
    for reserved_label in manifests completed.txt .owner; do
        BACKUP_JOBS=("$reserved_label|$src")
        if validate_configuration >/dev/null 2>&1; then fail 'reserved metadata label accepted'; fi
    done
    BACKUP_JOBS=("${saved_jobs[@]}")
    SHUTDOWN_REMOTE_ON_SUCCESS=false
    LOCK_FILE="$TEST_ROOT/vault.local.lock"
    STATUS_DIR="$TEST_ROOT/vault-main-status"
    NOTIFY_BIN="$TEST_ROOT/main-notify"; printf '#!/bin/sh\nexit 0\n' >"$NOTIFY_BIN"; chmod 755 "$NOTIFY_BIN"
    GENERATION_NAME=hubble-20261122_235959
    rm -rf -- "$REMOTE_PARTIAL"
    exec {LEASE_INPUT}>&-; wait "$LEASE_PID"; LEASE_INPUT=""; LEASE_PID=""
    if (main) >"$TEST_ROOT/vault-main.log" 2>&1; then :; else cat "$TEST_ROOT/vault-main.log"; fail 'complete vault workflow failed'; fi
    jq -e '.copy == "OK" and .verification == "sha256_verified"' "$STATUS_DIR/vault_backup.json" >/dev/null || fail 'main vault receipt wrong'
    [[ -f "$REMOTE_VERSION_ROOT/$GENERATION_NAME/manifests/restore-sources.tsv" ]] || fail 'restore source map missing'
    backup_acquire_lease || fail 'main vault leaked remote lease'
fi
exec {LEASE_INPUT}>&-
wait "$LEASE_PID"
LEASE_INPUT=""; LEASE_PID=""
# Transport configuration must reach rsync too, including custom SSH ports.
SSH_PORT=2222
original_transport_init || fail 'transport initialization failed'
[[ "$RSYNC_RSH" == *'-p 2222'* && "$RSYNC_RSH" == *'ServerAliveInterval=15'* && "$RSYNC_RSH" == *'ControlPath='* ]] || fail 'rsync transport diverges from SSH probes'
# Exit receipts distinguish a valid backup from a later retention failure.
STATUS_DIR="$TEST_ROOT/status-$SCRIPT_ID_TEST"
mountpoint() { return 0; }
NOTIFY_BIN="$TEST_ROOT/notify-$SCRIPT_ID_TEST"
printf '#!/bin/sh\nprintf notified >>"%s/notifications"\n' "$TEST_ROOT" >"$NOTIFY_BIN"
chmod 755 "$NOTIFY_BIN"
ssh() { return 0; }
set +e
(
    trap backup_finish EXIT
    BACKUP_RESULT=OK; VERIFICATION_RESULT=fixture_verified; RETENTION_RESULT=FAILED
    exit 1
)
exit_status=$?
set -e
[[ "$exit_status" == 1 ]] || fail 'cleanup lost failure exit code'
jq -e '.status == "WARNING" and .copy == "OK" and .retention == "FAILED"' "$STATUS_DIR/$SCRIPT_ID.json" >/dev/null || fail 'valid copy mislabeled after retention failure'
printf '%s reliability fixtures passed\n' "$SCRIPT_ID_TEST"
FIXTURE
done
printf 'ISS backup reliability fixtures passed\n'
