#!/bin/bash

# Focused fixtures for the boot-device portion of backup_restore_drill.sh.

# Variables below are consumed by functions loaded from the sourced script.
# shellcheck disable=SC1091,SC2034

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/backup_restore_drill_test.XXXXXX")

cleanup_test() {
    rm -rf -- "${test_root:?}"
}
trap cleanup_test EXIT

for required in zip unzip sha256sum awk find; do
    command -v "$required" >/dev/null 2>&1 || {
        printf 'Required test command is unavailable: %s\n' "$required" >&2
        exit 1
    }
done

# Sourcing is supported specifically so archive-validation fixtures can call
# the drill phases without mounting or modifying any production path.
source "$repo_root/user_script/backup_restore_drill.sh"

LOG_DIR="$test_root/logs"
mkdir -p -- "$LOG_DIR"
LOG_FILE="$LOG_DIR/test.log"
: >"$LOG_FILE"

write_checksum() {
    local archive="$1"
    (
        cd "$(dirname "$archive")"
        sha256sum "$(basename "$archive")" \
            >"$(basename "$archive").sha256"
    )
}

expect_flash_failure() {
    set +e
    drill_flash
    local rc=$?
    set -e
    (( rc != 0 )) || {
        printf 'Expected drill_flash to fail for %s\n' "$FLASH_BACKUP" >&2
        return 1
    }
}

###############################################################################
# Valid archive and checksum
###############################################################################

valid_source="$test_root/valid source"
mkdir -p -- "$valid_source/config"
printf 'array data\n' >"$valid_source/config/super.dat"
printf 'identity\n' >"$valid_source/config/ident.cfg"
for fixture_index in $(seq 1 10); do
    printf 'fixture %s\n' "$fixture_index" \
        >"$valid_source/config/fixture-${fixture_index}.cfg"
done

valid_archive="$test_root/fixture-boot-backup-20261115-000000.zip"
(cd "$valid_source" && zip -qr "$valid_archive" .)
write_checksum "$valid_archive"

FLASH_BACKUP="$valid_archive"
WORK_DIR="$test_root/valid-work"
REQUIRE_FLASH_CHECKSUM=true
MIN_FLASH_ARCHIVE_FILES=5
FLASH_CHECKSUM_STATUS="NOT_CHECKED"
FLASH_ARCHIVE_FILES=0

drill_flash
[[ "$FLASH_CHECKSUM_STATUS" == VERIFIED ]]
(( FLASH_ARCHIVE_FILES >= 12 ))
[[ -f "$WORK_DIR/flash/config/super.dat" ]]
[[ -f "$WORK_DIR/flash/config/ident.cfg" ]]

###############################################################################
# Checksum mismatch
###############################################################################

checksum_archive="$test_root/checksum-boot-backup-20261115-000001.zip"
cp -- "$valid_archive" "$checksum_archive"
printf '%064d  %s\n' 0 "$(basename "$checksum_archive")" \
    >"${checksum_archive}.sha256"

FLASH_BACKUP="$checksum_archive"
WORK_DIR="$test_root/checksum-work"
expect_flash_failure
[[ "$FLASH_CHECKSUM_STATUS" == FAILED ]]

###############################################################################
# Missing required checksum
###############################################################################

missing_checksum_archive="$test_root/missing-boot-backup-20261115-000002.zip"
cp -- "$valid_archive" "$missing_checksum_archive"
FLASH_BACKUP="$missing_checksum_archive"
WORK_DIR="$test_root/missing-checksum-work"
FLASH_CHECKSUM_STATUS="NOT_CHECKED"
expect_flash_failure
[[ "$FLASH_CHECKSUM_STATUS" == MISSING ]]

###############################################################################
# Unsafe traversal path
###############################################################################

mkdir -p -- "$valid_source/config/subdirectory"
unsafe_archive="$test_root/unsafe-boot-backup-20261115-000003.zip"
(cd "$valid_source/config/subdirectory" &&
    zip -q "$unsafe_archive" ../ident.cfg)
write_checksum "$unsafe_archive"

FLASH_BACKUP="$unsafe_archive"
WORK_DIR="$test_root/unsafe-work"
FLASH_CHECKSUM_STATUS="NOT_CHECKED"
MIN_FLASH_ARCHIVE_FILES=1
expect_flash_failure

###############################################################################
# Structurally valid but incomplete boot backup
###############################################################################

incomplete_source="$test_root/incomplete"
mkdir -p -- "$incomplete_source/data"
for fixture_index in $(seq 1 10); do
    printf 'fixture %s\n' "$fixture_index" \
        >"$incomplete_source/data/fixture-${fixture_index}.txt"
done
incomplete_archive="$test_root/incomplete-boot-backup-20261115-000004.zip"
(cd "$incomplete_source" && zip -qr "$incomplete_archive" .)
write_checksum "$incomplete_archive"

FLASH_BACKUP="$incomplete_archive"
WORK_DIR="$test_root/incomplete-work"
FLASH_CHECKSUM_STATUS="NOT_CHECKED"
MIN_FLASH_ARCHIVE_FILES=5
expect_flash_failure

printf 'backup_restore_drill flash fixtures passed\n'
