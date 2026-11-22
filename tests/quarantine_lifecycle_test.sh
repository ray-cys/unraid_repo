#!/bin/bash
# Globals below are consumed indirectly by functions in the sourced script.
# shellcheck disable=SC2034

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/user_script/quarantine_lifecycle.sh"
TEST_ROOT="$(mktemp -d /tmp/quarantine_lifecycle_test.XXXXXX)"

test_cleanup() {
    if [[ -n "${RUNTIME_DIR:-}" &&
          "$RUNTIME_DIR" == /tmp/quarantine_lifecycle.fixture.* ]]; then
        rm -rf -- "$RUNTIME_DIR"
    fi
    case "$TEST_ROOT" in
        /tmp/quarantine_lifecycle_test.*)
            rm -rf -- "$TEST_ROOT"
            ;;
    esac
}
trap test_cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local file="$1" pattern="$2"
    grep -Fq -- "$pattern" "$file" ||
        fail "expected '$pattern' in $file"
}

# shellcheck disable=SC1090
source "$SCRIPT"
MIN_RUN_IDLE_HOURS=0

# macOS realpath lacks GNU's harmless -e option used by Unraid. Keep the test
# focused on lifecycle behavior while preserving canonical path checks.
# shellcheck disable=SC2329
realpath() {
    local argument
    local -a paths=()
    for argument in "$@"; do
        case "$argument" in
            -e|--) ;;
            *) paths+=("$argument") ;;
        esac
    done
    command realpath "${paths[@]}"
}

# Avoid platform-specific GNU date parsing in the fixture.
# shellcheck disable=SC2329
run_id_epoch() {
    printf '%s\n' "$((START_EPOCH - 10 * 86400))"
}

# The production host provides GNU find and mountpoint. Supply the small GNU
# find surface used by this test when it runs on macOS.
# shellcheck disable=SC2329
mountpoint() {
    return 1
}

# shellcheck disable=SC2329
find() {
    local root="${1:-}" argument format="" path relative item_type size

    for argument in "$@"; do
        if [[ "$argument" == '%s\n' ||
              "$argument" == '.' ||
              "$argument" == '%P\t%y\t%s\0' ]]; then
            format="$argument"
        fi
    done

    case "$format" in
        '%s\n')
            while IFS= read -r -d '' path; do
                gstat -c '%s' "$path"
            done < <(command find "$root" -xdev -type f -print0)
            ;;
        '.')
            while IFS= read -r -d '' path; do
                printf '.'
            done < <(command find "$root" -xdev -type f -print0)
            ;;
        '%P\t%y\t%s\0')
            while IFS= read -r -d '' path; do
                relative="${path#"${root%/}/"}"
                item_type=f
                [[ -L "$path" ]] && item_type=l
                size="$(gstat -c '%s' "$path")"
                printf '%s\t%s\t%s\0' "$relative" "$item_type" "$size"
            done < <(command find "$root" -xdev -mindepth 1 ! -type d -print0)
            ;;
        *)
            command find "$@"
            ;;
    esac
}

LOG_DIR="${TEST_ROOT}/logs"
LOG_FILE="${LOG_DIR}/quarantine-lifecycle.log"
INDEX_FILE="${LOG_DIR}/quarantine-index.tsv"
NOTIFICATION_STATE_FILE="${LOG_DIR}/notification-state.json"
PURGE_RECEIPT_DIR="${LOG_DIR}/purge-receipts"
STATUS_DIR="${TEST_ROOT}/status"
RUNTIME_DIR="$(mktemp -d /tmp/quarantine_lifecycle.fixture.XXXXXX)"
PURGE_FILE_CANDIDATES="${RUNTIME_DIR}/purge-candidates.tsv"
NOTIFY_BIN="${TEST_ROOT}/notify"
MOCK_NOTIFY_LOG="${TEST_ROOT}/notify.log"
export MOCK_NOTIFY_LOG

mkdir -p \
    "$LOG_DIR" \
    "$PURGE_RECEIPT_DIR" \
    "$TEST_ROOT/quarantine" \
    "$TEST_ROOT/movies" \
    "$TEST_ROOT/series"
: >"$LOG_FILE"
: >"$PURGE_FILE_CANDIDATES"

cat >"$NOTIFY_BIN" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MOCK_NOTIFY_LOG"
EOF
chmod +x "$NOTIFY_BIN"

QUARANTINE_REAL="$(realpath "$TEST_ROOT/quarantine")"
MOVIES_REAL="$(realpath "$TEST_ROOT/movies")"
SERIES_REAL="$(realpath "$TEST_ROOT/series")"
RETENTION_DAYS=7
PURGE_ENABLED=true
PURGE_CONFIRMATION="$REQUIRED_PURGE_CONFIRMATION"
DEFER_PURGE_WHILE_MOVER=false
MAX_PURGE_RUNS_PER_EXECUTION=25
MAX_PURGE_BYTES_PER_EXECUTION=$((1024 * 1024))
PURGE_NOTIFICATION_FILE_LIMIT=2
PURGE_RECEIPT_RETENTION_DAYS=365

OPS_NOTIFICATION_STATE="$NOTIFICATION_STATE_FILE"
initialize_notification_state || fail "notification state initialization failed"

RUN_ID="20200101_000000_12345"
RUN_DIR="${QUARANTINE_REAL}/${RUN_ID}"
mkdir -p \
    "$RUN_DIR/movies/Example Movie (2020)" \
    "$RUN_DIR/series/Example Show/Season 01"
printf 'movie poster content\n' \
    >"$RUN_DIR/movies/Example Movie (2020)/poster.jpg"
printf 'series metadata\n' \
    >"$RUN_DIR/series/Example Show/tvshow.nfo"
printf 'episode artwork with a larger payload\n' \
    >"$RUN_DIR/series/Example Show/Season 01/episode-thumb.jpg"

audit_quarantine || fail "initial quarantine audit failed"
[[ "$EXPIRED_RUNS" -eq 1 ]] || fail "fixture run was not classified as expired"
assert_contains "$INDEX_FILE" "$RUN_ID"

MIN_RUN_IDLE_HOURS=24
purge_expired || fail "recent-run guard failed"
[[ -d "$RUN_DIR" && "$RESULT_STATUS" == WARNING ]] || fail "recently changed expired run was not preserved and reported as warning"
MIN_RUN_IDLE_HOURS=0
purge_expired || fail "receipt-backed purge failed"
[[ ! -e "$RUN_DIR" ]] || fail "expired run was not removed"
[[ "$PURGED_RUNS" -eq 1 ]] || fail "purged run total is incorrect"
[[ "$PURGED_FILES" -eq 3 ]] || fail "purged file total is incorrect"
[[ "$RUNS_SCANNED" -eq 0 ]] || fail "post-purge index was not refreshed"
[[ "$EXPIRED_RUNS" -eq 0 ]] || fail "post-purge expired total is stale"
if grep -Fq -- "$RUN_ID" "$INDEX_FILE"; then
    fail "refreshed index still contains the purged run"
fi

[[ -f "$PURGE_RECEIPT_FILE" ]] || fail "purge receipt was not created"
assert_contains "$PURGE_RECEIPT_FILE" $'RUN_INVENTORY\t'
assert_contains "$PURGE_RECEIPT_FILE" \
    $'movies\tExample Movie (2020)/poster.jpg\tf\t'
assert_contains "$PURGE_RECEIPT_FILE" \
    $'series\tExample Show/tvshow.nfo\tf\t'
assert_contains "$PURGE_RECEIPT_FILE" \
    $'series\tExample Show/Season 01/episode-thumb.jpg\tf\t'
assert_contains "$PURGE_RECEIPT_FILE" "purged_and_absence_verified"

update_lifecycle_notifications || fail "purge notification failed"
assert_contains "$MOCK_NOTIFY_LOG" "Quarantine purge completed"
assert_contains "$MOCK_NOTIFY_LOG" "Purged 1 run(s), 3 file(s)"
assert_contains "$MOCK_NOTIFY_LOG" "Largest purged files:"
assert_contains "$MOCK_NOTIFY_LOG" "series/Example Show/Season 01/episode-thumb.jpg"
assert_contains "$MOCK_NOTIFY_LOG" "...and 1 more file(s)"
assert_contains "$MOCK_NOTIFY_LOG" "Full receipt: $PURGE_RECEIPT_FILE"
assert_contains "$MOCK_NOTIFY_LOG" "Current index: $INDEX_FILE"

OLD_RECEIPT="${PURGE_RECEIPT_DIR}/purge-20200101_000000_1.tsv"
RECENT_RECEIPT="${PURGE_RECEIPT_DIR}/purge-20990101_000000_1.tsv"
: >"$OLD_RECEIPT"
: >"$RECENT_RECEIPT"
touch -t 202001010000 "$OLD_RECEIPT"
prune_purge_receipts || fail "purge receipt retention failed"
[[ ! -e "$OLD_RECEIPT" ]] || fail "old purge receipt was not pruned"
[[ -e "$RECENT_RECEIPT" ]] || fail "recent purge receipt was pruned"

# A receipt storage failure must preserve the expired quarantine run.
BLOCKED_RUN_ID="20200102_000000_12346"
BLOCKED_RUN_DIR="${QUARANTINE_REAL}/${BLOCKED_RUN_ID}"
mkdir -p "$BLOCKED_RUN_DIR/movies/Blocked Movie" "$BLOCKED_RUN_DIR/series"
printf 'must remain\n' >"$BLOCKED_RUN_DIR/movies/Blocked Movie/poster.jpg"
PURGE_RECEIPT_FILE=""
PURGE_RECEIPT_DIR="${TEST_ROOT}/not-a-directory"
: >"$PURGE_RECEIPT_DIR"
PURGED_RUNS=0
PURGED_FILES=0
PURGED_BYTES=0
PURGE_RUN_DETAILS=""
: >"$PURGE_FILE_CANDIDATES"

audit_quarantine || fail "blocked-run audit failed"
if purge_expired; then
    fail "purge unexpectedly succeeded without writable receipt storage"
fi
[[ -d "$BLOCKED_RUN_DIR" ]] || \
    fail "run was deleted even though its receipt could not be committed"

printf 'quarantine_lifecycle fixture tests passed\n'
