#!/usr/bin/env bash

# Focused fixture tests for version reporting and bounded persistent logging in
# user_script/arr_delete_sync_tag.sh. No Arr service or Unraid host is needed.
# Globals below are consumed indirectly by functions in the sourced script.
# shellcheck disable=SC2034

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/user_script/arr_delete_sync_tag.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/arr_delete_sync_tag_test.XXXXXX")"

cleanup_test() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/arr_delete_sync_tag_test.*)
            rm -rf -- "$TEST_ROOT"
            ;;
    esac
}
trap cleanup_test EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_absent() {
    [[ ! -e "$1" ]] || fail "unexpected path remains: $1"
}

# shellcheck disable=SC1090
source "$SCRIPT"
declare -F cleanup_main >/dev/null || fail "exit cleanup handler is missing"
declare -F notify_preflight_failure >/dev/null || fail "preflight handler is missing"

[[ "$SCRIPT_VERSION" == "2.3.0" ]] || fail "unexpected script version"
[[ "$USER_AGENT" == "Arr-Delete-Sync-Tag/$SCRIPT_VERSION" ]] ||
    fail "HTTP User-Agent does not contain the release version"

version_output="$(/bin/bash "$SCRIPT" --version)"
[[ "$version_output" == "arr_delete_sync_tag.sh $SCRIPT_VERSION" ]] ||
    fail "--version output is incorrect: $version_output"

RUNTIME_DIR="${TEST_ROOT}/runtime"
LOG_FILE="${RUNTIME_DIR}/arr-delete-sync-tag.log"
LOG_MAX_BYTES=4096
LOG_BACKUP_FILES=2
LOG_RETENTION_DAYS=30
LOG_LINE_MAX_BYTES=512
LOG_RUNAWAY_MULTIPLIER=4
APP_CONTEXT=TEST
LOG_READY=false
LOG_FAILURE_REPORTED=false
mkdir -p -- "$RUNTIME_DIR"

# Simulate an old deployment with one runaway active log, a runaway backup, an
# expired backup, and a generation beyond the configured retention count.
head -c 20000 /dev/zero > "$LOG_FILE"
head -c 20000 /dev/zero > "$LOG_FILE.1"
printf 'expired\n' > "$LOG_FILE.2"
printf 'obsolete\n' > "$LOG_FILE.3"
touch -t 202001010000 "$LOG_FILE.2"

initialize_logging 2>/dev/null || fail "logging initialization failed"

assert_absent "$LOG_FILE.1"
assert_absent "$LOG_FILE.2"
assert_absent "$LOG_FILE.3"
grep -Fq 'Cleaned 4 oversized, expired, or obsolete log item(s)' "$LOG_FILE" ||
    fail "legacy-log cleanup was not recorded"

printf -v long_message '%*s' 2000 ''
long_message="${long_message// /X}"
log INFO "$long_message" 2>/dev/null
grep -Fq '... [line truncated]' "$LOG_FILE" ||
    fail "oversized log line was not truncated"

# Generate enough output to rotate more than twice during this same process.
# The active log and both retained generations must remain within the cap.
for ((line_number=1; line_number<=50; line_number++)); do
    log INFO "fixture-$line_number $long_message" 2>/dev/null
done

for retained_log in "$LOG_FILE" "$LOG_FILE.1" "$LOG_FILE.2"; do
    [[ -f "$retained_log" ]] || fail "expected retained log is missing: $retained_log"
    retained_size="$(log_file_size "$retained_log")"
    (( retained_size <= LOG_MAX_BYTES )) ||
        fail "retained log exceeds cap: $retained_log ($retained_size bytes)"
done
assert_absent "$LOG_FILE.3"

printf 'arr_delete_sync_tag fixture tests passed\n'
