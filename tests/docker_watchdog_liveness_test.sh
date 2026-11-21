#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/docker_liveness_test.XXXXXX)"
trap 'rm -rf -- "${TEST_ROOT:?}"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC1091
source "$ROOT/user_script/docker_watchdog_liveness.sh"
STATE_DIR="$TEST_ROOT/state"; mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/state.json"; HEARTBEAT_FILE="$TEST_ROOT/heartbeat.json"
LOG_FILE="$STATE_DIR/liveness.log"; BOOT_ID=fixture
NOTIFY_BIN="$TEST_ROOT/notify"
printf '#!/bin/sh\n[ ! -e "%s/fail-notify" ] || exit 1\nprintf "sent\\n" >>"%s/sent"\n' "$TEST_ROOT" "$TEST_ROOT" >"$NOTIFY_BIN"
chmod 755 "$NOTIFY_BIN"
stat() { if command -v gstat >/dev/null; then gstat "$@"; else command stat "$@"; fi; }
has_issue() { printf '%s\n' "${ISSUES[@]}" | grep -Fq "$1"; }
valid() {
    jq -n --argjson now "$NOW" '{version:1,boot:"fixture",firstSeen:($now-2000),lastSuccessful:($now-30),started:($now-60),finished:($now-30),phase:"completed",failures:0,lockSkips:0}' >"$HEARTBEAT_FILE"
    ISSUES=()
}
valid; check_heartbeat; (( ${#ISSUES[@]} == 0 )) || fail 'healthy execution reported failed'
notify_changes || fail 'healthy audit failed'
[[ ! -e "$TEST_ROOT/sent" ]] || fail 'healthy audit sent notification'
jq '.lastSuccessful -= 3600' "$HEARTBEAT_FILE" >"$TEST_ROOT/new"; mv "$TEST_ROOT/new" "$HEARTBEAT_FILE"
check_heartbeat; has_issue successful-execution-overdue || fail 'stale execution missed'
notify_changes; notify_changes
[[ "$(wc -l <"$TEST_ROOT/sent")" -eq 1 ]] || fail 'unchanged liveness failure repeated'
valid; check_heartbeat; notify_changes
[[ "$(wc -l <"$TEST_ROOT/sent")" -eq 2 ]] || fail 'liveness recovery missing'
valid
jq '.phase="running" | .started -= 700 | .failures=3' "$HEARTBEAT_FILE" >"$TEST_ROOT/new"; mv "$TEST_ROOT/new" "$HEARTBEAT_FILE"
check_heartbeat
has_issue execution-stuck-or-lock-contention || fail 'stuck execution missed'
valid
jq '.failures=3' "$HEARTBEAT_FILE" >"$TEST_ROOT/new"; mv "$TEST_ROOT/new" "$HEARTBEAT_FILE"
check_heartbeat
has_issue repeated-execution-failures || fail 'repeated monitor failures missed'
touch "$TEST_ROOT/fail-notify"
if notify_changes; then fail 'notification failure swallowed'; fi
jq -e '.issues == []' "$STATE_FILE" >/dev/null || fail 'failed notification advanced checkpoint'
rm "$TEST_ROOT/fail-notify"
notify_changes || fail 'liveness notification not retried'
valid; printf '{}\n' >"$HEARTBEAT_FILE"; check_heartbeat
has_issue heartbeat-missing-or-invalid || fail 'malformed heartbeat accepted'
valid; jq '.boot="old-boot"' "$HEARTBEAT_FILE" >"$TEST_ROOT/new"; mv "$TEST_ROOT/new" "$HEARTBEAT_FILE"
check_heartbeat; has_issue heartbeat-from-previous-boot || fail 'prior boot heartbeat accepted'
printf 'docker_watchdog_liveness fixture tests passed\n'
