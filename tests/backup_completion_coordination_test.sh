#!/usr/bin/env bash
# Run with GNU tools (Unraid/Linux). No production paths, APIs, or Docker actions.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/backup-completion-test.XXXXXX)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
TEST_ROOT=$(realpath "$TEST_ROOT")
export ROOT TEST_ROOT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for cmd in jq flock sha256sum tar timeout setsid; do command -v "$cmd" >/dev/null || fail "missing $cmd"; done
bash <<'PENDING'
set -euo pipefail
source "$ROOT/user_script/vault_backup.sh"
LOCK_FILE="$TEST_ROOT/vault.lock"
ISS_REQUEST_FILE="$TEST_ROOT/request.json"; ISS_DELIVERED_FILE="$TEST_ROOT/delivered.json"
wait_for_remote() { touch "$TEST_ROOT/unexpected-wake"; return 1; }
(main)
[[ ! -e "$TEST_ROOT/unexpected-wake" ]]
gen="$TEST_ROOT/backup_20261122_000000"; mkdir "$gen"
BACKUP_JOBS=("appdata|$TEST_ROOT")
printf 'original producer manifest\n' >"$gen/backup_manifest.tsv"
hash=$(sha256sum "$gen/backup_manifest.tsv" | awk '{print $1}')
jq -n --arg generation "$gen" --arg manifestSha256 "$hash" --argjson completedAt "$(date +%s)" \
 '{schema:1,generation:$generation,manifestSha256:$manifestSha256,completedAt:$completedAt}' >"$ISS_REQUEST_FILE"
vault_pending_request
REMOTE_FINAL=/mnt/user/backup/vault_versions/hubble-fixture
vault_acknowledge_request
rc=0; vault_pending_request || rc=$?; [[ "$rc" == 10 ]]
vault_pending_request --force
# The appdata transfer manifest must preserve producer hashes despite local
# same-size corruption, so the remote verifier rejects those changed bytes.
printf 'good' >"$gen/app.tar.gz"
producer_hash=$(sha256sum "$gen/app.tar.gz" | awk '{print $1}')
printf '# archive_count=1\n4\t4\t%s\tapp\n' "$producer_hash" >"$gen/backup_manifest.tsv"
printf './app.tar.gz\0' >"$TEST_ROOT/payload.sha256.files"
printf 'evil' >"$gen/app.tar.gz"
vault_appdata_manifest "$gen" "$TEST_ROOT/payload.sha256"
if (cd "$gen" && sha256sum -c "$TEST_ROOT/payload.sha256" >/dev/null 2>&1); then exit 1; fi
printf 'tampered manifest\n' >>"$gen/backup_manifest.tsv"
if vault_pending_request --force; then exit 1; fi
printf 'completion request, deduplication and changed-source fixtures passed\n'
PENDING
# Exercise the actual gate block before any state/API initialization.
awk '/^ARR_BACKUP_GATE="/{copy=1} copy && /^# TEMP DIRECTORY/{exit} copy{print}' \
 "$ROOT/user_script/arr_health_activity.sh" >"$TEST_ROOT/gate.sh"
cat >>"$TEST_ROOT/gate.sh" <<'GUARD'
touch "$TEST_ROOT/api-called"
GUARD
export ARR_BACKUP_GATE="$TEST_ROOT/gate.lock" ARR_BACKUP_GRACE="$TEST_ROOT/grace"
export ARR_BACKUP_DEFERRED_AT="$TEST_ROOT/deferred"
export START_TIME; START_TIME=$(date +%s)
export -f fail
log() { printf '%s\n' "$*"; }; export -f log
flock -x "$ARR_BACKUP_GATE" sh -c 'touch "$TEST_ROOT/held"; sleep 2' &
holder=$!
while [[ ! -f "$TEST_ROOT/held" ]]; do sleep .05; done
bash "$TEST_ROOT/gate.sh"
[[ ! -f "$TEST_ROOT/api-called" ]] || fail 'API reached during backup'
[[ -f "$TEST_ROOT/deferred" ]] || fail 'missing deferred heartbeat'
wait "$holder"
printf '%s\n' "$((START_TIME+120))" >"$ARR_BACKUP_GRACE"
bash "$TEST_ROOT/gate.sh"
[[ ! -f "$TEST_ROOT/api-called" ]] || fail 'API reached during startup grace'
printf '%s\n' "$((START_TIME-1))" >"$ARR_BACKUP_GRACE"
bash "$TEST_ROOT/gate.sh"
[[ -f "$TEST_ROOT/api-called" ]] || fail 'normal monitoring did not resume'
printf 'backup gate and bounded startup grace fixtures passed\n'
# Test producer-hash validation and real isolated extraction/database checks.
bash <<'DRILL'
set -euo pipefail
source "$ROOT/user_script/backup_restore_drill.sh"
LOG_DIR="$TEST_ROOT/logs"; mkdir -p "$LOG_DIR"; LOG_FILE="$LOG_DIR/drill.log"
APPDATA_BACKUP="$TEST_ROOT/archives"; mkdir "$APPDATA_BACKUP"
mkdir -p "$TEST_ROOT/source/app"
printf 'critical config\n' >"$TEST_ROOT/source/app/config.txt"
if command -v sqlite3 >/dev/null; then sqlite3 "$TEST_ROOT/source/app/service.db" 'CREATE TABLE item(id INTEGER); INSERT INTO item VALUES(1);'; fi
tar -czf "$APPDATA_BACKUP/app.tar.gz" -C "$TEST_ROOT/source" app
size=$(stat -c %s "$APPDATA_BACKUP/app.tar.gz")
hash=$(sha256sum "$APPDATA_BACKUP/app.tar.gz" | awk '{print $1}')
printf '# archive_count=1\n10240\t%s\t%s\tapp\n' "$size" "$hash" >"$APPDATA_BACKUP/backup_manifest.tsv"
(cd "$APPDATA_BACKUP" && sha256sum backup_manifest.tsv >backup_manifest.tsv.sha256)
select_appdata_archives
DRILL_ROOT="$TEST_ROOT"; WORK_DIR="$TEST_ROOT/work"; mkdir "$WORK_DIR"
EXTRA_FREE_MARGIN_BYTES=0
MAX_EXTRACT_BYTES=1048576
check_free_space() { return 0; }
drill_appdata
[[ "$ARCHIVES_EXTRACTED" == 1 && ! -e "$WORK_DIR/appdata/app" ]]
if command -v sqlite3 >/dev/null; then [[ "$DATABASES_CHECKED" == 1 ]]; fi
printf 'corruption' >>"$APPDATA_BACKUP/app.tar.gz"
if drill_appdata; then exit 1; fi
# A link followed by a child entry must not write through the archive link.
mkdir "$TEST_ROOT/evil" "$TEST_ROOT/outside"
ln -s "$TEST_ROOT/outside" "$TEST_ROOT/evil/link"
tar -cf "$TEST_ROOT/evil.tar" -C "$TEST_ROOT/evil" link
rm "$TEST_ROOT/evil/link"; mkdir "$TEST_ROOT/evil/link"
printf 'must not escape\n' >"$TEST_ROOT/evil/link/payload"
tar -rf "$TEST_ROOT/evil.tar" -C "$TEST_ROOT/evil" link/payload
gzip "$TEST_ROOT/evil.tar"
if bounded_extract "$TEST_ROOT/evil.tar.gz" "$WORK_DIR/evil"; then exit 1; fi
[[ ! -e "$TEST_ROOT/outside/payload" ]]
printf 'producer checksum, SQLite, payload cleanup and link-traversal fixtures passed\n'
DRILL
printf 'backup completion/coordination fixtures passed\n'
# Full drill workflow: mounted/storage discovery is isolated to the fixture.
bash <<'FULL'
set -euo pipefail
source "$ROOT/user_script/backup_restore_drill.sh"
VAULT_MOUNT="$TEST_ROOT"; DRILL_ROOT="$TEST_ROOT/drills"
APPDATA_BACKUP_ROOT="$TEST_ROOT/completed"; FLASH_BACKUP_ROOT="$TEST_ROOT/flash"
LOG_DIR="$TEST_ROOT/full-logs"; STATUS_DIR="$TEST_ROOT/full-status"
LOCK_FILE="$TEST_ROOT/full.lock"; APPDATA_LOCK_FILE="$TEST_ROOT/appdata.lock"; FLASH_LOCK_FILE="$TEST_ROOT/flash.lock"
WORK_DIR="$DRILL_ROOT/drill_$RUN_STAMP.partial"; FINAL_DIR="$DRILL_ROOT/drill_$RUN_STAMP"; LOG_FILE="$LOG_DIR/drill.log"
NOTIFY_BIN=/nonexistent; EXTRA_FREE_MARGIN_BYTES=0
mkdir -p "$APPDATA_BACKUP_ROOT/backup_20261122_000000" "$FLASH_BACKUP_ROOT" "$TEST_ROOT/boot/config"
printf 'recreated' >"$TEST_ROOT/archives/app.tar.gz"
# Rebuild untampered fixture/archive and manifest.
tar -czf "$APPDATA_BACKUP_ROOT/backup_20261122_000000/app.tar.gz" -C "$TEST_ROOT/source" app
archive="$APPDATA_BACKUP_ROOT/backup_20261122_000000/app.tar.gz"
size=$(stat -c %s "$archive"); hash=$(sha256sum "$archive" | awk '{print $1}')
printf '# archive_count=1\n10240\t%s\t%s\tapp\n' "$size" "$hash" >"${archive%/*}/backup_manifest.tsv"
(cd "${archive%/*}" && sha256sum backup_manifest.tsv >backup_manifest.tsv.sha256)
printf 'array' >"$TEST_ROOT/boot/config/super.dat"; printf 'identity' >"$TEST_ROOT/boot/config/ident.cfg"
for i in {1..10}; do printf 'fixture' >"$TEST_ROOT/boot/config/$i.cfg"; done
(cd "$TEST_ROOT/boot" && zip -qr "$FLASH_BACKUP_ROOT/test-boot-backup-fixture.zip" .)
(cd "$FLASH_BACKUP_ROOT" && sha256sum test-boot-backup-fixture.zip >test-boot-backup-fixture.zip.sha256)
mountpoint() { return 0; }
(main)
jq -e '.status=="OK" and (.summary|contains("app"))' "$STATUS_DIR/backup_restore_drill.json" >/dev/null
[[ -f "$FINAL_DIR/result.txt" && ! -e "$FINAL_DIR/flash" ]]
printf 'complete bounded restore workflow passed\n'
FULL
# Execute the real SSH command construction against a local simulated receiver.
bash <<'REMOTE_DRILL'
set -euo pipefail
source "$ROOT/user_script/vault_backup.sh"
REMOTE=fixture
REMOTE_VERSION_ROOT="$TEST_ROOT/remote"
REMOTE_FINAL="$REMOTE_VERSION_ROOT/hubble-fixture"
TMP_DIR="$TEST_ROOT/hook-tmp"; mkdir -p "$TMP_DIR" "$REMOTE_VERSION_ROOT"
LOG_FILE="$TEST_ROOT/hook.log"
RESTORE_DRILL_SCRIPT="$TEST_ROOT/fake-drill.sh"
cat >"$RESTORE_DRILL_SCRIPT" <<'FAKE'
#!/bin/bash
set -eu
mkdir -p "$STATUS_DIR"
jq -n --argjson epoch "$(date +%s)" '{status:"OK",summary:"fixture archive and database restored",epoch:$epoch}' >"$STATUS_DIR/backup_restore_drill.json"
printf 'called\n' >>"$DRILL_ROOT/calls"
FAKE
ssh_exec() { bash -c "$1"; }
rsync() { local source="${@: -2:1}" target="${@: -1}"; cp "$source" "${target#fixture:}"; }
backup_phase() { :; }
vault_remote_restore_drill
[[ "$RESTORE_DRILL_RESULT" == OK && "$RESTORE_DRILL_SUMMARY" == 'fixture archive and database restored' ]]
vault_remote_restore_drill
[[ $(wc -l <"$REMOTE_VERSION_ROOT/restore_drill/calls") == 1 ]]
printf 'remote drill command, script digest and weekly interval fixtures passed\n'
REMOTE_DRILL
