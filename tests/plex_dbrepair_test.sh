#!/bin/bash
# Globals and mock functions are consumed indirectly by the sourced wrapper.
# shellcheck disable=SC2034,SC2329

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/user_script/plex_dbrepair.sh"
TEST_ROOT="$(mktemp -d /tmp/plex_dbrepair_test.XXXXXX)"
export DOCKER_MAINTENANCE_DIR="$TEST_ROOT/maintenance"

test_cleanup() {
    case "${RUNTIME_DIR:-}" in
        /tmp/plex_dbrepair.fixture.*) rm -rf -- "$RUNTIME_DIR" ;;
    esac
    case "$TEST_ROOT" in
        /tmp/plex_dbrepair_test.*) rm -rf -- "$TEST_ROOT" ;;
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

LOG_DIR="${TEST_ROOT}/logs"
LOG_FILE="${LOG_DIR}/dbrepair.log"
REPORT_DIR="${LOG_DIR}/reports"
NOTIFICATION_STATE_FILE="${LOG_DIR}/notification-state.json"
STATUS_DIR="${TEST_ROOT}/status"
NOTIFY_BIN="${TEST_ROOT}/notify"
MOCK_NOTIFY_LOG="${TEST_ROOT}/notify.log"
MOCK_NOTIFY_COUNT="${TEST_ROOT}/notify.count"
export MOCK_NOTIFY_LOG MOCK_NOTIFY_COUNT
RUNTIME_DIR="$(mktemp -d /tmp/plex_dbrepair.fixture.XXXXXX)"

mkdir -p "$LOG_DIR" "$REPORT_DIR"
: >"$LOG_FILE"
: >"$MOCK_NOTIFY_LOG"
: >"$MOCK_NOTIFY_COUNT"

cat >"$NOTIFY_BIN" <<'EOF'
#!/bin/sh
printf '1\n' >>"$MOCK_NOTIFY_COUNT"
printf '%s\n' "$*" >>"$MOCK_NOTIFY_LOG"
EOF
chmod +x "$NOTIFY_BIN"

reset_results() {
    RESULT_ORDER=()
    RESULT_CLASS=()
    RESULT_FINDING=()
    RESULT_ACTION=()
    RESULT_FINAL_STATE=()
    RESULT_VERSION=()
    RESULT_RC=()
    RESULT_DETAILS=()
    RESULT_UPDATE=()
    CONTAINERS_SUCCESSFUL=0
    CONTAINERS_FAILED=0
    CONTAINERS_REPAIRED=0
    CONTAINERS_HEALTHY=0
    RUN_HAS_REPAIR=0
    RUN_HAS_ISSUE=0
    RUN_HIGHEST_SEVERITY=normal
    GLOBAL_ISSUE_KEY=""
    UPDATE_STATE=verified-latest
    UPDATE_DETAIL="Official DBRepair test package verified"
    WARNING_COUNT=0
    ERROR_COUNT=0
    NOTIFICATION_FAILED=0
}

set_result_fields() {
    local container="$1"
    RESULT_ORDER+=("$container")
    RESULT_FINAL_STATE["$container"]="Container running; server process detected."
    RESULT_VERSION["$container"]="99.12.34"
    RESULT_UPDATE["$container"]="DBRepair 99.12.34 current; update not required"
}

###############################################################################
# Official release package metadata, digest, ZIP, and executable validation
###############################################################################

PACKAGE_ARCH="$(map_linux_arch "$(uname -m)")"
PACKAGE_VERSION="99.12.34"
PACKAGE_NAME="DBRepair-${PACKAGE_VERSION}-Linux-${PACKAGE_ARCH}.zip"
PACKAGE_DIR="${TEST_ROOT}/package"
mkdir -p "$PACKAGE_DIR"
cat >"${PACKAGE_DIR}/DBRepair" <<EOF
#!/bin/sh
printf 'DBRepair ${PACKAGE_VERSION}\n'
EOF
chmod +x "${PACKAGE_DIR}/DBRepair"
(
    cd "$PACKAGE_DIR" && zip -q "${TEST_ROOT}/${PACKAGE_NAME}" DBRepair
) || fail "fixture package could not be created"
portable_stat() {
    if command -v gstat >/dev/null 2>&1; then
        gstat "$@"
    else
        command stat "$@"
    fi
}

PACKAGE_DIGEST="$(sha256sum "${TEST_ROOT}/${PACKAGE_NAME}" | awk '{print $1}')"
PACKAGE_SIZE="$(portable_stat -c '%s' "${TEST_ROOT}/${PACKAGE_NAME}")"
cat >"${TEST_ROOT}/release.json" <<EOF
{
  "tag_name": "v${PACKAGE_VERSION}",
  "assets": [{
    "name": "${PACKAGE_NAME}",
    "browser_download_url": "https://github.com/ChuckPa/DBRepair/releases/download/v${PACKAGE_VERSION}/${PACKAGE_NAME}",
    "digest": "sha256:${PACKAGE_DIGEST}",
    "size": ${PACKAGE_SIZE}
  }]
}
EOF

stat() {
    portable_stat "$@"
}

curl() {
    local destination="" previous="" argument url=""
    for argument in "$@"; do
        if [[ "$previous" == -o ]]; then
            destination="$argument"
        fi
        [[ "$argument" == https://* ]] && url="$argument"
        previous="$argument"
    done
    [[ -n "$destination" ]] || return 1
    if [[ "$url" == "$GITHUB_RELEASE_API" ]]; then
        cp "$TEST_ROOT/release.json" "$destination"
    else
        cp "$TEST_ROOT/$PACKAGE_NAME" "$destination"
    fi
}

prepare_latest_release || fail "verified release preparation failed"
[[ "$DOWNLOAD_READY" -eq 1 ]] || fail "verified release was not accepted"
[[ "$LATEST_VERSION" == "$PACKAGE_VERSION" ]] || fail "release version was not parsed"
[[ -x "$STAGED_BINARY" ]] || fail "release executable was not staged"

###############################################################################
# Persistent /config installation and legacy shell retirement
###############################################################################

MOCK_CONTAINER_ROOT="${TEST_ROOT}/container"
mkdir -p "${MOCK_CONTAINER_ROOT}/config/DBRepair"
printf '#!/bin/sh\nexit 0\n' \
    >"${MOCK_CONTAINER_ROOT}/config/DBRepair/DBRepair.sh"

container_path() {
    printf '%s%s' "$MOCK_CONTAINER_ROOT" "$1"
}

docker() {
    local operation="${1:-}"
    shift || true
    local source destination path command code target previous staged legacy archive

    case "$operation" in
        cp)
            source="$1"
            destination="${2#*:}"
            cp "$source" "$(container_path "$destination")"
            ;;
        exec)
            while [[ "${1:-}" == -* ]]; do
                case "$1" in
                    -u|-w) shift 2 ;;
                    *) shift ;;
                esac
            done
            shift # container name
            command="${1:-}"
            shift || true
            case "$command" in
                mkdir)
                    shift # -p
                    mkdir -p "$(container_path "$1")"
                    ;;
                chmod)
                    chmod "$1" "$(container_path "$2")"
                    ;;
                uname)
                    uname "$@"
                    ;;
                /config/*)
                    path="$(container_path "$command")"
                    "$path" "$@"
                    ;;
                rm)
                    shift # -f
                    rm -f "$(container_path "$1")"
                    ;;
                sh)
                    shift # -c
                    code="$1"
                    shift 2 # script and argv[0]
                    if [[ "$code" == *'target='* ]]; then
                        target="$(container_path "$1")"
                        previous="$(container_path "$2")"
                        staged="$(container_path "$3")"
                        [[ ! -e "$target" ]] || cp -f "$target" "$previous"
                        mv -f "$staged" "$target"
                    else
                        legacy="$(container_path "$1")"
                        archive="$(container_path "$2")"
                        if [[ -f "$legacy" ]]; then
                            if [[ ! -e "$archive" ]]; then
                                mv "$legacy" "$archive"
                            else
                                rm -f "$legacy"
                            fi
                        fi
                    fi
                    ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

RESULT_UPDATE=()
CONTAINERS_UPDATED=0
install_or_resolve_dbrepair plex-media-server ||
    fail "verified executable was not installed into the Docker fixture"
[[ "${RESULT_VERSION[plex-media-server]}" == "$PACKAGE_VERSION" ]] ||
    fail "installed executable version was not validated"
[[ -x "${MOCK_CONTAINER_ROOT}/config/DBRepair/DBRepair" ]] ||
    fail "current DBRepair executable is missing from persistent config"
[[ -f "${MOCK_CONTAINER_ROOT}/config/DBRepair/DBRepair.sh.legacy" ]] ||
    fail "obsolete DBRepair.sh was not retired"
[[ "$CONTAINERS_UPDATED" -eq 1 ]] || fail "container update was not counted"

###############################################################################
# Documented DBRepair output classification
###############################################################################

reset_results
HEALTHY_OUTPUT="${TEST_ROOT}/healthy.out"
cat >"$HEALTHY_OUTPUT" <<'EOF'
Checking the PMS databases...
  Main  DB is OK.
  Blobs DB is OK.
Starting PMS.
Started PMS.
[2026-11-21 20.09.54] Checking Main DB for orphaned media items
[2026-11-21 20.09.54] No orphaned media items found
EOF
classify_container_output healthy "$HEALTHY_OUTPUT" 0
[[ "${RESULT_CLASS[healthy]}" == HEALTHY ]] || fail "healthy output was misclassified"
[[ -z "${RESULT_DETAILS[healthy]}" ]] || fail "routine orphan checks leaked into diagnostics"
[[ "$RUN_HAS_ISSUE" -eq 0 ]] || fail "routine orphan checks raised an issue"

# Check normalization with terminal colors and the alternative zero-count form.
printf '\033[32m[2026-11-21 20.09.54] 0 orphaned media items found.\033[0m\n' >>"$HEALTHY_OUTPUT"
classify_container_output healthy "$HEALTHY_OUTPUT" 0
[[ "${RESULT_CLASS[healthy]}" == HEALTHY ]] || fail "colored clean output was misclassified"
[[ -z "${RESULT_DETAILS[healthy]}" ]] || fail "colored clean output leaked into diagnostics"

# Positive findings and unknown explicit warnings must still require review.
ORPHAN_OUTPUT="${TEST_ROOT}/orphan.out"
cp "$HEALTHY_OUTPUT" "$ORPHAN_OUTPUT"
printf 'Found 12 orphaned media items\n' >>"$ORPHAN_OUTPUT"
reset_results
classify_container_output orphan "$ORPHAN_OUTPUT" 0
[[ "${RESULT_CLASS[orphan]}" == WARNING ]] || fail "real orphan finding was suppressed"
assert_contains <(printf '%s' "${RESULT_DETAILS[orphan]}") 'Found 12 orphaned media items'
assert_contains <(printf '%s' "${RESULT_FINDING[orphan]}") 'Orphaned media records detected'

WARNING_OUTPUT="${TEST_ROOT}/warning.out"
cp "$HEALTHY_OUTPUT" "$WARNING_OUTPUT"
printf 'WARNING: Database maintenance requires manual review\n' >>"$WARNING_OUTPUT"
reset_results
classify_container_output warning "$WARNING_OUTPUT" 0
[[ "${RESULT_CLASS[warning]}" == WARNING ]] || fail "explicit warning was suppressed"
assert_contains <(printf '%s' "${RESULT_DETAILS[warning]}") 'WARNING: Database maintenance requires manual review'
printf '[WARNING] No orphaned media items found\n' >>"$WARNING_OUTPUT"
classify_container_output warning "$WARNING_OUTPUT" 0
assert_contains <(printf '%s' "${RESULT_DETAILS[warning]}") '[WARNING] No orphaned media items found'

reset_results
REPAIRED_OUTPUT="${TEST_ROOT}/repaired.out"
cat >"$REPAIRED_OUTPUT" <<'EOF'
Main Database is damaged: Rowid out of order
Main DB rebuild and verification complete.
Blobs DB rebuild and verification complete.
Making DB(s) active
Swap complete. Live databases updated.
Started PMS.
[2026-11-21 20.09.54] Checking Main DB for orphaned media items
[2026-11-21 20.09.54] No orphaned media items found
EOF
classify_container_output repaired "$REPAIRED_OUTPUT" 0
[[ "${RESULT_CLASS[repaired]}" == REPAIRED ]] || fail "repair output was misclassified"
assert_contains <(printf '%s' "${RESULT_ACTION[repaired]}") "Main and blobs databases rebuilt, verified, and activated."

UNRECOVERABLE_OUTPUT="${TEST_ROOT}/unrecoverable.out"
cat >"$UNRECOVERABLE_OUTPUT" <<'EOF'
Main DB has unrecoverable damage. Use Replace with a Plex backup.
EOF
classify_container_output unrecoverable "$UNRECOVERABLE_OUTPUT" 0
[[ "${RESULT_CLASS[unrecoverable]}" == UNRECOVERABLE ]] ||
    fail "unrecoverable output was misclassified"

FAILED_OUTPUT="${TEST_ROOT}/failed.out"
printf 'ERROR: Automatic maintenance failed before activation\n' >"$FAILED_OUTPUT"
classify_container_output failed "$FAILED_OUTPUT" 1
[[ "${RESULT_CLASS[failed]}" == FAILED ]] || fail "failed output was misclassified"

###############################################################################
# Grouped operational report, notification deduplication, and resolution
###############################################################################

initialize_notification_state || fail "notification state initialization failed"
reset_results
set_result_fields plex-media-server
RESULT_CLASS["plex-media-server"]=REPAIRED
RESULT_FINDING["plex-media-server"]="Database rebuild and activation confirmed."
RESULT_ACTION["plex-media-server"]="Main and blobs databases rebuilt, verified, and activated."
RESULT_RC["plex-media-server"]=0
RESULT_DETAILS["plex-media-server"]=""
CONTAINERS=(plex-media-server)
CONTAINERS_SUCCESSFUL=1
CONTAINERS_REPAIRED=1
RUN_HAS_REPAIR=1
write_run_report || fail "structured run report failed"
update_notifications
[[ "$(wc -l <"$MOCK_NOTIFY_COUNT" | tr -d '[:space:]')" -eq 1 ]] ||
    fail "successful repair did not send exactly one notification"
assert_contains "$MOCK_NOTIFY_LOG" "Database checks:"
assert_contains "$MOCK_NOTIFY_LOG" "Maintenance:"
assert_contains "$MOCK_NOTIFY_LOG" "Plex status: Container running; server process detected."
assert_contains "$MOCK_NOTIFY_LOG" "DBRepair: 99.12.34; exit code: 0"
assert_contains "$RUN_REPORT_FILE" "Plex DBRepair run report"

: >"$MOCK_NOTIFY_LOG"
: >"$MOCK_NOTIFY_COUNT"
clear_attention_state
reset_results
set_result_fields plex-media-server
RESULT_CLASS["plex-media-server"]=WARNING
RESULT_FINDING["plex-media-server"]="Exit code 0; database verification outcome unrecognized."
RESULT_ACTION["plex-media-server"]="Database changes unverified. Inspect DBRepair.log."
RESULT_RC["plex-media-server"]=0
RESULT_DETAILS["plex-media-server"]="- WARNING: Review DBRepair.log"
CONTAINERS=(plex-media-server)
CONTAINERS_SUCCESSFUL=1
RUN_HAS_ISSUE=1
RUN_HIGHEST_SEVERITY=warning
update_notifications
update_notifications
[[ "$(wc -l <"$MOCK_NOTIFY_COUNT" | tr -d '[:space:]')" -eq 1 ]] ||
    fail "unchanged warning was not deduplicated"

reset_results
set_result_fields plex-media-server
RESULT_CLASS["plex-media-server"]=HEALTHY
RESULT_FINDING["plex-media-server"]="Main OK; Blobs OK."
RESULT_ACTION["plex-media-server"]="No repair required."
RESULT_RC["plex-media-server"]=0
RESULT_DETAILS["plex-media-server"]=""
CONTAINERS=(plex-media-server)
CONTAINERS_SUCCESSFUL=1
CONTAINERS_HEALTHY=1
update_notifications
[[ "$(wc -l <"$MOCK_NOTIFY_COUNT" | tr -d '[:space:]')" -eq 2 ]] ||
    fail "warning resolution notification was not sent"
assert_contains "$MOCK_NOTIFY_LOG" "Recovery: Previously reported DBRepair conditions are no longer detected."

# Subsequent clean runs stay silent, including the real-world orphan-check
# output that originally generated false NOTICE emails.
reset_results
set_result_fields plex-media-server
classify_container_output plex-media-server "$HEALTHY_OUTPUT" 0
CONTAINERS_SUCCESSFUL=1
update_notifications
[[ "$(wc -l <"$MOCK_NOTIFY_COUNT" | tr -d '[:space:]')" -eq 2 ]] ||
    fail "clean orphan-check output generated a routine notification"

assert_contains "$SCRIPT" 'DBREPAIR_ARGS=("automatic" "exit")'
# shellcheck disable=SC2016
assert_contains "$SCRIPT" 'docker exec -u 0 -i -w "$DBREPAIR_INSTALL_DIR"'
assert_contains "$SCRIPT" 'docker restart -t 30'

# A real lease is created before maintenance, with a bounded lifetime and an
# owner identity. The wrapper removes it even when processing returns failure.
# shellcheck disable=SC2329
flock() { return 0; }
plex_maintenance_begin plex-media-server || fail "Plex maintenance lease failed"
jq -e --argjson now "$(date +%s)" '.pid > 0 and (.processStart | type == "string") and
    .expires > $now and .expires <= ($now + 86400)' \
    "$DOCKER_MAINTENANCE_DIR/plex-media-server.dbrepair.json" >/dev/null || fail "invalid Plex maintenance lease"
# shellcheck disable=SC2329
process_container_impl() {
    [[ -f "$DOCKER_MAINTENANCE_DIR/$1.dbrepair.json" ]] || fail "maintenance began without lease"
    return 1
}
if process_container plex-media-server; then fail "processing failure was hidden"; fi
[[ ! -e "$DOCKER_MAINTENANCE_DIR/plex-media-server.dbrepair.json" ]] || fail "Plex lease leaked after processing"

printf 'plex_dbrepair fixture tests passed\n'
