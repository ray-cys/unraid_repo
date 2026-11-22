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
printf '#!/bin/sh\n[ ! -e "%s/fail-notify" ] || exit 1\nprintf "sent\\n" >>"%s/sent"\nprintf "%%s\\n" "$*" >>"%s/messages"\n' "$TEST_ROOT" "$TEST_ROOT" "$TEST_ROOT" >"$NOTIFY_BIN"
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
grep -Fq 'Last successful monitoring execution was 3630s ago; limit=900s.' "$TEST_ROOT/messages" || fail 'notification lacks age and threshold'
grep -Fq 'Action: Check the User Scripts schedule' "$TEST_ROOT/messages" || fail 'notification lacks condition-specific action'
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

# Invalid limits and unsafe output collisions fail before files are opened.
validate_configuration || fail 'valid configuration rejected'
saved_limit="$MAX_RUNNING_SECONDS"; MAX_RUNNING_SECONDS=invalid
if validate_configuration 2>"$TEST_ROOT/config-error"; then fail 'invalid threshold accepted'; fi
grep -Fq 'Configuration error' "$TEST_ROOT/config-error" || fail 'configuration diagnostic missing'
MAX_RUNNING_SECONDS="$saved_limit"
saved_state="$STATE_FILE"; STATE_FILE="$HEARTBEAT_FILE"
if validate_configuration 2>/dev/null; then fail 'heartbeat output collision accepted'; fi
STATE_FILE="$saved_state"
if (PATH=/usr/bin:/bin; require_dependencies) 2>"$TEST_ROOT/dependency-error"; then
    # Some Linux test hosts provide every dependency in /usr/bin; force one
    # known-missing command lookup without changing the production function.
    (
        command() { [[ "$1" != -v || "$2" != jq ]] && builtin command "$@"; }
        require_dependencies
    ) 2>"$TEST_ROOT/dependency-error" && fail 'missing dependency accepted'
fi
grep -Fq 'Required command unavailable:' "$TEST_ROOT/dependency-error" || fail 'missing dependency not identified'

# Producer replacement after read cannot change the data being classified.
valid
head() {
    command head "$@"
    if [[ "${*: -1}" == "$HEARTBEAT_FILE" ]]; then printf '{}\n' >"$HEARTBEAT_FILE"; fi
}
check_heartbeat
(( ${#ISSUES[@]} == 0 )) || fail 'classification mixed two heartbeat generations'
unset -f head
[[ "$(cat "$HEARTBEAT_FILE")" == '{}' ]] || fail 'snapshot replacement fixture failed'

valid
head -c "$((HEARTBEAT_MAX_BYTES + 1))" /dev/zero | tr '\0' X >"$HEARTBEAT_FILE"
check_heartbeat; has_issue heartbeat-missing-or-invalid || fail 'oversized heartbeat accepted'

# Invalid state is preserved, rebuilt only after delivery, then clears once.
valid
printf '{"version":999,"issues":[]}\n' >"$STATE_FILE"
check_heartbeat; notify_changes || fail 'invalid state repair failed'
[[ -f "$STATE_FILE.invalid" ]] || fail 'invalid state evidence not preserved'
grep -Fq '999' "$STATE_FILE.invalid" || fail 'invalid state original content lost'
notification_state_valid "$STATE_FILE" || fail 'rebuilt notification state invalid'
check_heartbeat; notify_changes || fail 'state-repair resolution failed'
jq -e '.issues == []' "$STATE_FILE" >/dev/null || fail 'state-repair condition never cleared'

# A commit failure reports failure and removes the unfinished temporary file.
valid; ISSUES=()
add_issue fixture-condition 'Fixture commit failure.' 'Review fixture.'
mv() {
    if [[ "${*: -1}" == "$STATE_FILE" ]]; then return 1; fi
    command mv "$@"
}
if notify_changes; then fail 'checkpoint commit failure swallowed'; fi
unset -f mv
cleanup
[[ -z "$(find "$STATE_DIR" -name '.liveness.*' -print)" ]] || fail 'temporary state files leaked'

# Log limits apply to inherited oversized files and exceptionally large lines.
LOG_MAX_BYTES=8192; LOG_LINE_MAX_BYTES=512
head -c 20000 /dev/zero >"$LOG_FILE"
initialize_logging || fail 'inherited log bounding failed'
printf -v long_message '%*s' 4000 ''
log INFO "$long_message" >/dev/null || fail 'bounded log write failed'
[[ "$(stat -c %s "$LOG_FILE")" -le "$LOG_MAX_BYTES" && "$(stat -c %s "$LOG_FILE.1")" -le "$LOG_MAX_BYTES" ]] || fail 'log file limit exceeded'
grep -Fq '[line truncated]' "$LOG_FILE" || fail 'large message not truncated'

# Main entrypoint validates uptime, applies boot grace, and performs a healthy
# scan without sending another notification. No Unraid paths are accessed.
flock() { return 0; }
LOCK_FILE="$TEST_ROOT/liveness.lock"; UPTIME_FILE="$TEST_ROOT/uptime"
printf '99999.00 0.00\n' >"$UPTIME_FILE"
valid
(main) >"$TEST_ROOT/main-output" 2>&1 || fail 'healthy main entrypoint failed'
printf 'invalid\n' >"$UPTIME_FILE"
if (main) >"$TEST_ROOT/main-error" 2>&1; then fail 'main accepted invalid uptime'; fi
grep -Fq 'Uptime unavailable or invalid' "$TEST_ROOT/main-error" || fail 'uptime error lacked diagnostic'
printf 'docker_watchdog_liveness fixture tests passed\n'
