#!/bin/bash

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/user_script/appdata_backup.sh"
TEST_ROOT="$(mktemp -d /tmp/appdata_backup_test.XXXXXX)"
TEST_PLEX_DATABASE_BACKUP_PATH=""

cleanup() {
    case "$TEST_ROOT" in
        /tmp/appdata_backup_test.*)
            rm -rf -- "$TEST_ROOT"
            ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_file() {
    [ -f "$1" ] || fail "expected file: $1"
}

assert_contains() {
    local file="$1"
    local pattern="$2"

    grep -Fq -- "$pattern" "$file" ||
        fail "expected '$pattern' in $file"
}

assert_not_contains() {
    local file="$1"
    local pattern="$2"

    if grep -Fq -- "$pattern" "$file"; then
        fail "did not expect '$pattern' in $file"
    fi
}

make_mocks() {
    local root="$1"

    mkdir -p -- "$root/bin"

    cat >"$root/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF

    cat >"$root/bin/notify" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${MOCK_NOTIFY_LOG}"
EOF

    cat >"$root/bin/rsync" <<'EOF'
#!/bin/sh
if [ "${MOCK_RSYNC_FAIL:-0}" = "1" ]; then
    printf 'simulated rsync failure\n' >&2
    exit 23
fi

/usr/bin/rsync "$@" || exit $?

if [ "${MOCK_RSYNC_CORRUPT:-0}" = "1" ]; then
    destination=""
    for argument do
        destination="$argument"
    done

    archive="$(
        find "$destination" \
            -mindepth 1 \
            -maxdepth 1 \
            -type f \
            -name '*.tar.gz' \
            -print \
            -quit
    )"
    [ -n "$archive" ] && printf 'simulated corruption\n' >>"$archive"
fi
EOF

    chmod +x \
        "$root/bin/flock" \
        "$root/bin/notify" \
        "$root/bin/rsync"
}

make_layout() {
    local root="$1"

    mkdir -p \
        "$root/source" \
        "$root/destination" \
        "$root/logs" \
        "$root/staging"
    make_mocks "$root"
}

run_backup() {
    local root="$1"
    local mode="$2"
    local output="$3"
    shift 3

    env \
        PATH="$root/bin:$PATH" \
        SRC_DIR="$root/source" \
        DEST_DIR="$root/destination" \
        LOG_DIR="$root/logs" \
        STAGING_DIR="$root/staging" \
        BACKUP_STORAGE_MODE="$mode" \
        REQUIRE_MOUNT_GUARDS=false \
        MIN_FREE_RESERVE_BYTES=0 \
        LOW_SPACE_MARGIN=0 \
        USE_LOW_PRIORITY_IO=false \
        RETRIES=3 \
        RETRY_DELAY=0 \
        MAX_LOGS=20 \
        LOCK_FILE="$root/appdata.lock" \
        NOTIFY_BIN="$root/bin/notify" \
        MOCK_NOTIFY_LOG="$root/notify.log" \
        PLEX_DATABASE_BACKUP_PATH="$TEST_PLEX_DATABASE_BACKUP_PATH" \
        "$@" \
        bash "$SCRIPT" >"$output" 2>&1
}

newest_generation() {
    local root="$1"

    find "$root/destination" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name 'backup_*' \
        ! -name '*.partial' \
        -print |
        sort |
        tail -n 1
}

count_generations() {
    local root="$1"

    find "$root/destination" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name 'backup_*' \
        ! -name '*.partial' \
        -print |
        wc -l |
        tr -d '[:space:]'
}


###############################################################################
# Auto mode selects alternate staging when mocked vault capacity is too low
###############################################################################

(
    unset PIGZ_THREADS PIGZ_LEVEL USE_LOW_PRIORITY_IO \
        PLEX_DATABASE_BACKUP_PATH

    # shellcheck disable=SC1090
    source "$SCRIPT"

    [ "$PIGZ_THREADS" -eq 6 ]
    [ "$PIGZ_LEVEL" -eq 3 ]
    [ "$USE_LOW_PRIORITY_IO" = "false" ]
    [ "$PLEX_DATABASE_BACKUP_PATH" = "/mnt/vault/backup/plex_db/hubble" ]
) || fail "performance-oriented compression defaults are incorrect"


###############################################################################
# Volume ownership stops only app owners and restarts them at scope completion
###############################################################################

LIFECYCLE_ROOT="${TEST_ROOT}/container-lifecycle"
mkdir -p \
    "$LIFECYCLE_ROOT/source/app-one" \
    "$LIFECYCLE_ROOT/source/app-two" \
    "$LIFECYCLE_ROOT/external-app-two-backups" \
    "$LIFECYCLE_ROOT/user-appdata"

# The sourced script consumes these globals and the docker function indirectly.
# shellcheck disable=SC2030,SC2031,SC2034,SC2154,SC2329
(
    export SRC_DIR="$LIFECYCLE_ROOT/source"

    # shellcheck disable=SC1090
    source "$SCRIPT"

    APPDATA_DIRS=(
        "$SRC_DIR/app-one"
        "$SRC_DIR/app-two"
        "$LIFECYCLE_ROOT/external-app-two-backups"
    )
    ELIGIBLE_APPDATA=(
        ["app-one"]=1
        ["app-two"]=1
        ["app-two-backups"]=1
    )
    NORMAL_APPDATA=(
        ["app-one"]=1
        ["app-two"]=1
    )
    ARCHIVE_NAME_BY_PATH=(
        ["$LIFECYCLE_ROOT/external-app-two-backups"]="app-two-backups"
    )
    EXTRA_ARCHIVE_OWNER=(
        ["app-two-backups"]="app-two"
    )
    APPDATA_PATH_ALIASES=("$LIFECYCLE_ROOT/user-appdata")
    SKIP_CONTAINERS=()
    LOG_FILE=""

    declare -A MOCK_RUNNING=(
        [app-one-container]=true
        [shared-container]=true
        [unrelated-container]=true
    )

    docker() {
        local operation="${1:-}"
        local template="${3:-}"
        local container="${4:-${2:-}}"
        local name=""

        case "$operation" in
            ps)
                for name in \
                    app-one-container \
                    shared-container \
                    unrelated-container
                do
                    [ "${MOCK_RUNNING[$name]}" = "true" ] && printf '%s\n' "$name"
                done
                ;;
            inspect)
                if [[ "$template" == *'.Mounts'* ]]; then
                    case "$container" in
                        app-one-container)
                            printf '%s\t/config\n' "$SRC_DIR/app-one"
                            ;;
                        shared-container)
                            printf '%s\t/config-one\n' "$SRC_DIR/app-one"
                            printf '%s\t/config-two\n' \
                                "$LIFECYCLE_ROOT/user-appdata/app-two"
                            ;;
                        unrelated-container)
                            printf '%s\t/data\n' "$LIFECYCLE_ROOT/unrelated"
                            ;;
                    esac
                else
                    printf '%s\n' "${MOCK_RUNNING[$container]}"
                fi
                ;;
            stop)
                container="${2:-}"
                MOCK_RUNNING["$container"]=false
                ;;
            start)
                container="${2:-}"
                MOCK_RUNNING["$container"]=true
                ;;
            *)
                return 1
                ;;
        esac
    }

    discover_target_containers
    [ "${#TARGET_CONTAINERS[@]}" -eq 2 ]
    [ "${MOCK_RUNNING[unrelated-container]}" = "true" ]

    stop_containers_for_app app-one
    [ "${MOCK_RUNNING[app-one-container]}" = "false" ]
    [ "${MOCK_RUNNING[shared-container]}" = "false" ]
    [ "${MOCK_RUNNING[unrelated-container]}" = "true" ]

    complete_container_scope_for_app app-one
    [ "${MOCK_RUNNING[app-one-container]}" = "true" ]
    [ "${MOCK_RUNNING[shared-container]}" = "false" ]

    stop_containers_for_app app-two
    complete_container_scope_for_app app-two
    [ "${MOCK_RUNNING[shared-container]}" = "false" ]

    stop_containers_for_app app-two-backups
    complete_container_scope_for_app app-two-backups
    [ "${MOCK_RUNNING[shared-container]}" = "true" ]
    [ "$CONTAINERS_NEED_RESTART" = "false" ]
) >"$LIFECYCLE_ROOT/lifecycle.out" 2>&1 ||
    fail "per-app container ownership lifecycle failed"

AUTO_ROOT="${TEST_ROOT}/auto-selection"
make_layout "$AUTO_ROOT"

# shellcheck disable=SC2031
(
    export SRC_DIR="$AUTO_ROOT/source"
    export DEST_DIR="$AUTO_ROOT/destination"
    export LOG_DIR="$AUTO_ROOT/logs"
    export STAGING_DIR="$AUTO_ROOT/staging"
    export BACKUP_STORAGE_MODE=auto
    export REQUIRE_MOUNT_GUARDS=false

    # shellcheck disable=SC1090
    source "$SCRIPT"

    # Invoked indirectly by select_backup_workspace from the sourced script.
    # shellcheck disable=SC2329
    available_bytes_for_path() {
        if [ "$1" = "$DEST_DIR" ]; then
            printf '100\n'
        else
            printf '1000\n'
        fi
    }

    # Consumed by select_backup_workspace from the sourced script.
    # shellcheck disable=SC2034
    ESTIMATED_REQUIRED_BYTES=500
    select_backup_workspace
    [ "$BACKUP_MODE" = "staging" ]
) >"$AUTO_ROOT/selection.out" 2>&1 ||
    fail "auto mode did not select staging for a low-space vault"


###############################################################################
# Direct generation, checksum manifest, and conservative Plex exclusions
###############################################################################

DIRECT_ROOT="${TEST_ROOT}/direct"
make_layout "$DIRECT_ROOT"

mkdir -p \
    "$DIRECT_ROOT/source/app-one" \
    "$DIRECT_ROOT/source/plex-media-server/Library/Application Support/Plex Media Server/Cache" \
    "$DIRECT_ROOT/source/plex-media-server/Library/Application Support/Plex Media Server/Media" \
    "$DIRECT_ROOT/source/plex-media-server/Library/Application Support/Plex Media Server/Metadata" \
    "$DIRECT_ROOT/source/radarr/logs" \
    "$DIRECT_ROOT/plex-db"

TEST_PLEX_DATABASE_BACKUP_PATH="$DIRECT_ROOT/plex-db"

printf 'application data\n' >"$DIRECT_ROOT/source/app-one/data.txt"
printf 'regenerable cache\n' \
    >"$DIRECT_ROOT/source/plex-media-server/Library/Application Support/Plex Media Server/Cache/cache.bin"
printf 'regenerable preview thumbnail\n' \
    >"$DIRECT_ROOT/source/plex-media-server/Library/Application Support/Plex Media Server/Media/preview.bif"
printf 'required metadata\n' \
    >"$DIRECT_ROOT/source/plex-media-server/Library/Application Support/Plex Media Server/Metadata/metadata.db"
printf 'required configuration\n' >"$DIRECT_ROOT/source/radarr/config.xml"
printf 'regenerable log\n' >"$DIRECT_ROOT/source/radarr/logs/radarr.txt"
printf 'scheduled plex database backup\n' \
    >"$DIRECT_ROOT/plex-db/com.plexapp.plugins.library.db-2026-11-21"

run_backup "$DIRECT_ROOT" destination "$DIRECT_ROOT/direct.out" ||
    fail "direct backup failed"

mapfile -t DIRECT_ARCHIVE_ORDER < <(
    sed -n \
        's/.*\[DOCKER\]\[INFO\] \[\(.*\)\] Creating archive$/\1/p' \
        "$DIRECT_ROOT/direct.out"
)

PLEX_ORDER_VALID=false
for ((i = 0; i < ${#DIRECT_ARCHIVE_ORDER[@]} - 1; i++)); do
    if [ "${DIRECT_ARCHIVE_ORDER[$i]}" = "plex-media-server" ] &&
       [ "${DIRECT_ARCHIVE_ORDER[$((i + 1))]}" = "plex-database-backups" ]
    then
        PLEX_ORDER_VALID=true
        break
    fi
done
[ "$PLEX_ORDER_VALID" = "true" ] ||
    fail "Plex database backup archive was not adjacent to its owner"

DIRECT_GENERATION="$(newest_generation "$DIRECT_ROOT")"
assert_file "$DIRECT_GENERATION/backup_manifest.tsv"
assert_file "$DIRECT_GENERATION/backup_manifest.tsv.sha256"
assert_file "$DIRECT_GENERATION/plex-database-backups.tar.gz"

(
    cd "$DIRECT_GENERATION" &&
        sha256sum -c -- backup_manifest.tsv.sha256 >/dev/null
) || fail "manifest checksum validation failed"

tar -tzf "$DIRECT_GENERATION/plex-media-server.tar.gz" \
    >"$DIRECT_ROOT/plex.list"
assert_contains "$DIRECT_ROOT/plex.list" "Metadata/metadata.db"
assert_not_contains "$DIRECT_ROOT/plex.list" "Cache/cache.bin"
assert_not_contains "$DIRECT_ROOT/plex.list" "Media/preview.bif"

tar -tzf "$DIRECT_GENERATION/radarr.tar.gz" >"$DIRECT_ROOT/radarr.list"
assert_contains "$DIRECT_ROOT/radarr.list" "radarr/config.xml"
assert_not_contains "$DIRECT_ROOT/radarr.list" "radarr/logs/radarr.txt"

tar -tzf "$DIRECT_GENERATION/plex-database-backups.tar.gz" \
    >"$DIRECT_ROOT/plex-db.list"
assert_contains "$DIRECT_ROOT/plex-db.list" \
    "plex-db/com.plexapp.plugins.library.db-2026-11-21"


###############################################################################
# Historical estimation and verified staging replacement
###############################################################################

sleep 1
printf 'new data\n' >>"$DIRECT_ROOT/source/app-one/data.txt"
mkdir -p "$DIRECT_ROOT/source/app-two"
printf 'new application data\n' >"$DIRECT_ROOT/source/app-two/data.txt"

run_backup "$DIRECT_ROOT" staging "$DIRECT_ROOT/staging.out" ||
    fail "verified staging backup failed"

[ "$(count_generations "$DIRECT_ROOT")" -eq 1 ] ||
    fail "staging replacement did not retain exactly one vault generation"

if find "$DIRECT_ROOT/staging" -mindepth 1 -print -quit | grep -q .; then
    fail "successful staging run left data behind"
fi

assert_contains "$DIRECT_ROOT/staging.out" "method=verified manifest history"
assert_contains "$DIRECT_ROOT/staging.out" \
    "history=4 app(s)"
assert_contains "$DIRECT_ROOT/staging.out" \
    "[app-two] Measuring source size (no usable archive history or full scan requested)"
assert_not_contains "$DIRECT_ROOT/staging.out" \
    "[app-one] Measuring source size"
assert_not_contains "$DIRECT_ROOT/staging.out" \
    "[plex-media-server] Measuring source size"
assert_contains "$DIRECT_ROOT/staging.out" \
    "Verified staged generation copied, re-verified, and promoted on vault"


###############################################################################
# Failed final transfer remains recoverable on the next run
###############################################################################

sleep 1
printf 'third generation\n' >>"$DIRECT_ROOT/source/app-one/data.txt"

if run_backup \
    "$DIRECT_ROOT" \
    staging \
    "$DIRECT_ROOT/staging-failure.out" \
    MOCK_RSYNC_FAIL=1
then
    fail "simulated staging transfer failure unexpectedly succeeded"
fi

PENDING_STAGED="$(
    find "$DIRECT_ROOT/staging" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name 'backup_*.staged' \
        -print |
        head -n 1
)"

[ -n "$PENDING_STAGED" ] ||
    fail "verified staged generation was not preserved after transfer failure"

assert_file "$PENDING_STAGED/backup_manifest.tsv.sha256"

run_backup "$DIRECT_ROOT" auto "$DIRECT_ROOT/staging-recovery.out" ||
    fail "pending staged generation was not recovered"

assert_contains "$DIRECT_ROOT/staging-recovery.out" \
    "Earlier staged generation was recovered to the vault"

[ "$(count_generations "$DIRECT_ROOT")" -eq 1 ] ||
    fail "staging recovery did not leave exactly one vault generation"


###############################################################################
# Post-copy checksum detects corruption without repeated decompression
###############################################################################

sleep 1
printf 'checksum generation\n' >>"$DIRECT_ROOT/source/app-one/data.txt"

if run_backup \
    "$DIRECT_ROOT" \
    staging \
    "$DIRECT_ROOT/checksum-failure.out" \
    MOCK_RSYNC_CORRUPT=1
then
    fail "corrupted staged transfer unexpectedly passed checksum verification"
fi

assert_contains "$DIRECT_ROOT/checksum-failure.out" \
    "Vault copy failed checksum or manifest verification"

PENDING_STAGED="$(
    find "$DIRECT_ROOT/staging" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name 'backup_*.staged' \
        -print |
        head -n 1
)"

[ -n "$PENDING_STAGED" ] ||
    fail "verified staged generation was not preserved after checksum failure"

run_backup "$DIRECT_ROOT" auto "$DIRECT_ROOT/checksum-recovery.out" ||
    fail "checksum-failed transfer was not recovered from verified staging"


###############################################################################
# Silent SIGKILL is classified, not retried, and leaves no partial backup
###############################################################################

TEST_PLEX_DATABASE_BACKUP_PATH=""

FAIL_ROOT="${TEST_ROOT}/pipeline-failure"
make_layout "$FAIL_ROOT"
mkdir -p "$FAIL_ROOT/source/plex-media-server"
printf 'plex data\n' >"$FAIL_ROOT/source/plex-media-server/data.txt"

cat >"$FAIL_ROOT/bin/pigz" <<'EOF'
#!/bin/sh
cat >/dev/null
exit 137
EOF
chmod +x "$FAIL_ROOT/bin/pigz"

if run_backup "$FAIL_ROOT" destination "$FAIL_ROOT/failure.out"; then
    fail "simulated SIGKILL unexpectedly succeeded"
fi

[ "$(grep -c 'Compression attempt' "$FAIL_ROOT/failure.out")" -eq 1 ] ||
    fail "non-retryable SIGKILL was retried"

assert_contains "$FAIL_ROOT/failure.out" \
    "compression was killed by SIGKILL; probable memory pressure"
assert_contains "$FAIL_ROOT/notify.log" \
    "[FAILED] [plex-media-server] compression was killed by SIGKILL"

if find "$FAIL_ROOT/destination" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name 'backup_*.partial' \
    -print -quit |
    grep -q .
then
    fail "failed pipeline left a partial backup"
fi

printf 'appdata_backup fixture tests passed\n'
