#!/bin/bash

# Fixture tests for user_script/backup_boot_disk.sh. These tests do not require an
# Unraid host; platform-specific commands are replaced with deterministic mocks.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/user_script/backup_boot_disk.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/backup_boot_disk_test.XXXXXX")

cleanup_test() {
    rm -rf -- "${test_root:?}"
}
trap cleanup_test EXIT

mock_bin="$test_root/bin"
test_pool="$test_root/pool"
backup_dir="$test_pool/backup"
boot_source="$test_root/boot source"
log_dir="$test_root/logs"
notification_log="$test_root/notifications.log"
run_log="$test_root/runs.log"

mkdir -p -- "$mock_bin" "$test_pool" "$boot_source/config" \
    "$boot_source/folder with spaces"

printf 'array assignments\n' >"$boot_source/config/super.dat"
printf 'NAME="Fixture"\n' >"$boot_source/config/ident.cfg"
printf 'fixture license\n' >"$boot_source/config/Pro.key"
printf 'space-safe payload\n' >"$boot_source/folder with spaces/payload.txt"
for fixture_index in $(seq 1 12); do
    printf 'fixture %s\n' "$fixture_index" \
        >"$boot_source/config/fixture-${fixture_index}.cfg"
done

if command -v gstat >/dev/null 2>&1; then
    test_real_stat=$(command -v gstat)
else
    test_real_stat=$(command -v stat)
fi
if command -v gsort >/dev/null 2>&1; then
    test_real_sort=$(command -v gsort)
else
    test_real_sort=$(command -v sort)
fi
test_real_find=$(command -v find)

cat >"$mock_bin/flock" <<'EOF'
#!/bin/bash
exit 0
EOF

cat >"$mock_bin/findmnt" <<'EOF'
#!/bin/bash
printf '%s\n' "${MOCK_MOUNT_TARGET:-$TEST_POOL}"
EOF

cat >"$mock_bin/timeout" <<'EOF'
#!/bin/bash
while [[ "${1:-}" == --* ]]; do shift; done
shift
exec "$@"
EOF

cat >"$mock_bin/df" <<'EOF'
#!/bin/bash
printf 'Avail\n%s\n' "${MOCK_AVAILABLE_BYTES:-1073741824}"
EOF

cat >"$mock_bin/du" <<'EOF'
#!/bin/bash
printf '4096\ttotal\n'
EOF

cat >"$mock_bin/stat" <<'EOF'
#!/bin/bash
exec "$TEST_REAL_STAT" "$@"
EOF

cat >"$mock_bin/sort" <<'EOF'
#!/bin/bash
exec "$TEST_REAL_SORT" "$@"
EOF

cat >"$mock_bin/find" <<'EOF'
#!/bin/bash
for candidate in \
    "$TEST_BACKUP_DIR"/*-boot-backup-*.zip \
    "$TEST_BACKUP_DIR"/*-flash-backup-*.zip
do
    [[ -f "$candidate" ]] || continue
    modified=$("$TEST_REAL_STAT" -c '%Y' "$candidate")
    printf '%s.0|%s\0' "$modified" "$candidate"
done
EOF

cat >"$mock_bin/notify" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_NOTIFICATION_LOG"
EOF

mock_helper="$test_root/mock_backup_boot_disk"
cat >"$mock_helper" <<'EOF'
#!/bin/bash

if [[ "${1:-}" == size ]]; then
    printf '4096\n'
    exit 0
fi

case "${MOCK_FLASH_MODE:-valid}" in
    valid)
        cd "$TEST_BOOT_SOURCE"
        zip -qr - .
        ;;
    invalid)
        printf 'not a zip archive'
        ;;
    unsafe)
        cd "$TEST_BOOT_SOURCE/config"
        zip -q - ../ident.cfg
        ;;
    timeout)
        printf 'partial data'
        exit 124
        ;;
    failure)
        printf 'partial data'
        printf 'simulated helper failure\n' >&2
        exit 23
        ;;
    diagnostic_flood)
        printf 'partial data'
        head -c "${MOCK_DIAGNOSTIC_BYTES:-1048576}" /dev/zero >&2
        exit 23
        ;;
    *)
        exit 99
        ;;
esac
EOF

chmod 755 "$mock_bin"/* "$mock_helper"

export TEST_POOL="$test_pool"
export TEST_BACKUP_DIR="$backup_dir"
export TEST_BOOT_SOURCE="$boot_source"
export TEST_NOTIFICATION_LOG="$notification_log"
export TEST_REAL_STAT="$test_real_stat"
export TEST_REAL_SORT="$test_real_sort"

run_backup() {
    local backend="$1" helper="$2" mode="$3"
    local available="${4:-1073741824}"
    local mount_target="${5:-$test_pool}"

    PATH="$mock_bin:$PATH" \
    BACKUP_DIR="$backup_dir" \
    POOL_PATH="$test_pool" \
    BOOT_SOURCE="$boot_source" \
    BACKUP_BACKEND="$backend" \
    HELPER="$helper" \
    NOTIFY="$mock_bin/notify" \
    TIMEOUT_BIN="timeout" \
    LOCKFILE="$test_root/backup_boot_disk.lock" \
    LOG_DIR="$log_dir" \
    STATE_FILE="$backup_dir/.backup_boot_disk_state.json" \
    MIN_ARCHIVE_FILES=5 \
    MOCK_FLASH_MODE="$mode" \
    MOCK_AVAILABLE_BYTES="$available" \
    MOCK_MOUNT_TARGET="$mount_target" \
    bash "$script" >>"$run_log" 2>&1
}

zip_count() {
    "$test_real_find" "$backup_dir" -maxdepth 1 -type f \
        -name '*-boot-backup-*.zip' | wc -l | tr -d ' '
}

temp_count() {
    "$test_real_find" "$backup_dir" -maxdepth 1 -type f \
        -name '.*.tmp.*' | wc -l | tr -d ' '
}

verify_generations() {
    local archive
    while IFS= read -r archive; do
        [[ -f "${archive}.sha256" ]]
        (cd "$(dirname "$archive")" &&
            sha256sum -c --status "$(basename "$archive").sha256")
        unzip -tq "$archive" >/dev/null
    done < <(
        "$test_real_find" "$backup_dir" -maxdepth 1 -type f \
            -name '*-boot-backup-*.zip'
    )
}

expect_failure() {
    local expected_rc="$1"
    shift
    set +e
    run_backup "$@"
    local actual_rc=$?
    set -e
    if (( actual_rc != expected_rc )); then
        printf 'Expected exit %s, received %s\n' "$expected_rc" "$actual_rc" >&2
        tail -n 80 "$run_log" >&2
        return 1
    fi
}

###############################################################################
# Native stream, retention, checksums, and state
###############################################################################

run_backup native "$mock_helper" valid
sleep 1
run_backup native "$mock_helper" valid
sleep 1
run_backup native "$mock_helper" valid

[[ "$(zip_count)" -eq 2 ]]
[[ "$(temp_count)" -eq 0 ]]
verify_generations
jq -e '.backend == "native" and .fallbackUsed == false and
       (.archiveSha256 | length) == 64' \
    "$backup_dir/.backup_boot_disk_state.json" >/dev/null

###############################################################################
# Helper fingerprint change is detected and reported once
###############################################################################

: >"$notification_log"
printf '\n# helper fingerprint change\n' >>"$mock_helper"
sleep 1
run_backup native "$mock_helper" valid
grep -q 'Platform change verified: native helper changed' "$notification_log"

: >"$notification_log"
sleep 1
run_backup native "$mock_helper" valid
if grep -q 'Platform change verified:' "$notification_log"; then
    printf 'Platform change notification repeated after state was updated\n' >&2
    exit 1
fi

###############################################################################
# Invalid native output automatically falls back to direct ZIP generation
###############################################################################

: >"$notification_log"
sleep 1
run_backup auto "$mock_helper" invalid
jq -e '.backend == "direct" and .fallbackUsed == true' \
    "$backup_dir/.backup_boot_disk_state.json" >/dev/null
grep -q 'OK WITH FALLBACK' "$notification_log"
latest_zip=$(
    "$test_real_find" "$backup_dir" -maxdepth 1 -type f \
        -name '*-boot-backup-*.zip' -print | "$test_real_sort" -r | head -n 1
)
unzip -Z1 "$latest_zip" | grep -q 'folder with spaces/payload.txt'

###############################################################################
# Missing helper also falls back automatically
###############################################################################

sleep 1
run_backup auto "$test_root/missing_helper" valid
jq -e '.backend == "direct" and .helperSha256 == "missing"' \
    "$backup_dir/.backup_boot_disk_state.json" >/dev/null

###############################################################################
# Forced native failures preserve successful generations and remove partials
###############################################################################

before_failure=$(zip_count)
expect_failure 6 native "$mock_helper" timeout
[[ "$(zip_count)" -eq "$before_failure" ]]
[[ "$(temp_count)" -eq 0 ]]

expect_failure 6 native "$mock_helper" invalid
[[ "$(zip_count)" -eq "$before_failure" ]]
[[ "$(temp_count)" -eq 0 ]]

expect_failure 6 native "$mock_helper" unsafe
[[ "$(zip_count)" -eq "$before_failure" ]]
[[ "$(temp_count)" -eq 0 ]]

###############################################################################
# Space and mount guards fail before replacing a successful generation
###############################################################################

expect_failure 6 native "$mock_helper" valid 1
[[ "$(zip_count)" -eq "$before_failure" ]]

expect_failure 2 native "$mock_helper" valid 1073741824 "$test_root/not-mounted"
[[ "$(zip_count)" -eq "$before_failure" ]]

verify_generations

###############################################################################
# Backend diagnostics and legacy runaway logs remain strictly bounded
###############################################################################

export LOG_MAX_BYTES=32768
export LOG_KEEP=1
export LOG_RETENTION_DAYS=30
export LOG_LINE_MAX_BYTES=1024
export LOG_RUNAWAY_MULTIPLIER=4
export BACKEND_DIAGNOSTIC_MAX_BYTES=8192
export BACKEND_DIAGNOSTIC_MAX_LINES=10
export MOCK_DIAGNOSTIC_BYTES=1048576

expect_failure 6 native "$mock_helper" diagnostic_flood

diagnostic_notice_count=$(
    grep -h 'captured output is binary' "$log_dir"/backup_boot_disk.log* 2>/dev/null |
        awk 'END {print NR+0}'
)
[[ "$diagnostic_notice_count" -eq 1 ]]

for bounded_log in "$log_dir"/backup_boot_disk.log*; do
    [[ -f "$bounded_log" ]] || continue
    [[ "$("$test_real_stat" -c '%s' "$bounded_log")" -le "$LOG_MAX_BYTES" ]]
done

head -c 200000 /dev/zero >"$log_dir/backup_boot_disk.log"
cp "$log_dir/backup_boot_disk.log" "$log_dir/backup_boot_disk.log.1"
cp "$log_dir/backup_boot_disk.log" "$log_dir/backup_boot_disk.log.2"

run_backup native "$mock_helper" valid

[[ ! -e "$log_dir/backup_boot_disk.log.2" ]]
[[ "$("$test_real_stat" -c '%s' "$log_dir/backup_boot_disk.log")" -le "$LOG_MAX_BYTES" ]]
grep -q 'oversized, expired, or obsolete log file' \
    "$log_dir/backup_boot_disk.log"

printf 'backup_boot_disk fixture tests passed\n'
