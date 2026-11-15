#!/bin/bash

###############################################################################
# Backup Restore Drill
#
# Proves that the newest Hubble appdata and boot-device backups can be read and
# restored into an isolated staging directory. It never writes to live appdata
# or the boot device.
###############################################################################

set -uo pipefail
umask 077

readonly SCRIPT_VERSION="1.1"

###############################################################################
# CONFIGURATION
###############################################################################

VAULT_MOUNT="${VAULT_MOUNT:-/mnt/vault}"
APPDATA_BACKUP_ROOT="${APPDATA_BACKUP_ROOT:-/mnt/vault/backup/cache}"
FLASH_BACKUP_ROOT="${FLASH_BACKUP_ROOT:-/mnt/vault/backup/flash}"
DRILL_ROOT="${DRILL_ROOT:-/mnt/vault/restore_drill}"

# Empty means extract every appdata archive in the newest successful backup.
# Otherwise use archive base names without .tar.gz.
APPDATA_ARCHIVE_ALLOWLIST=()

MAX_APPDATA_ARCHIVES="${MAX_APPDATA_ARCHIVES:-0}"
CHECK_SQLITE_DATABASES="${CHECK_SQLITE_DATABASES:-true}"
SQLITE_MAX_FILES="${SQLITE_MAX_FILES:-200}"

REQUIRE_FLASH_CHECKSUM="${REQUIRE_FLASH_CHECKSUM:-true}"
MIN_FLASH_ARCHIVE_FILES="${MIN_FLASH_ARCHIVE_FILES:-10}"

# Compressed input size multiplied by this factor for extraction-space checks.
EXTRACT_SPACE_MULTIPLIER="${EXTRACT_SPACE_MULTIPLIER:-4}"
EXTRA_FREE_MARGIN_BYTES="${EXTRA_FREE_MARGIN_BYTES:-$((5 * 1024 * 1024 * 1024))}"

MAX_SUCCESSFUL_DRILLS="${MAX_SUCCESSFUL_DRILLS:-2}"
KEEP_FAILED_DRILL="${KEEP_FAILED_DRILL:-false}"

LOG_DIR="${LOG_DIR:-/mnt/vault/cloud/logs/backup_restore_drill}"
MAX_LOGS="${MAX_LOGS:-5}"
STATUS_DIR="${STATUS_DIR:-/mnt/vault/cloud/logs/user_scripts_status}"
NOTIFY_BIN="${NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify}"
LOCK_FILE="${LOCK_FILE:-/run/backup_restore_drill.lock}"

###############################################################################
# RUNTIME
###############################################################################

RUN_STAMP="$(date '+%Y%m%d_%H%M%S')"
WORK_DIR="${DRILL_ROOT}/drill_${RUN_STAMP}.partial"
FINAL_DIR="${DRILL_ROOT}/drill_${RUN_STAMP}"
LOG_FILE="${LOG_DIR}/restore-drill-${RUN_STAMP}.log"

START_EPOCH="$(date +%s)"
RESULT_STATUS="FAILED"
RESULT_SUMMARY="Restore drill exited before completion"
RECEIPT_WRITTEN=0
WORK_PROMOTED=0

APPDATA_BACKUP=""
FLASH_BACKUP=""
FLASH_CHECKSUM_STATUS="NOT_CHECKED"
FLASH_ARCHIVE_FILES=0
ARCHIVES_CHECKED=0
ARCHIVES_EXTRACTED=0
DATABASES_CHECKED=0
DATABASES_FAILED=0

###############################################################################
# HELPERS
###############################################################################

log() {
    local level="$1"
    shift
    local line
    printf -v line '%s [%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
    printf '%s\n' "$line"
    [[ -d "$LOG_DIR" ]] && printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
}

notify_unraid() {
    local importance="$1" description="$2" message="$3"
    [[ -x "$NOTIFY_BIN" ]] || return 0
    "$NOTIFY_BIN" -i "$importance" -s "Backup Restore Drill" \
        -d "$description" -m "$message" >/dev/null 2>&1 || true
}

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " ")
        i=1
        while (b >= 1024 && i < 5) { b/=1024; i++ }
        printf "%.2f %s", b, u[i]
    }'
}

write_receipt() {
    local status="$1" summary="$2" now tmp
    now="$(date +%s)"
    mkdir -p -- "$STATUS_DIR" 2>/dev/null || return 0
    command -v jq >/dev/null 2>&1 || return 0
    tmp="$(mktemp "${STATUS_DIR}/.backup_restore_drill.XXXXXX")" || return 0
    if jq -n \
        --arg name "backup_restore_drill" \
        --arg status "$status" \
        --arg summary "$summary" \
        --arg log "$LOG_FILE" \
        --argjson epoch "$now" \
        --argjson duration "$((now - START_EPOCH))" \
        '{name:$name,status:$status,summary:$summary,log:$log,epoch:$epoch,duration_seconds:$duration}' \
        >"$tmp"
    then
        mv -f -- "$tmp" "${STATUS_DIR}/backup_restore_drill.json"
        RECEIPT_WRITTEN=1
    else
        rm -f -- "$tmp"
    fi
}

cleanup() {
    local rc=$?
    if (( WORK_PROMOTED == 0 )) && [[ -d "$WORK_DIR" ]]; then
        if [[ "$KEEP_FAILED_DRILL" == true ]]; then
            mv -- "$WORK_DIR" "${WORK_DIR%.partial}.failed" 2>/dev/null || true
        else
            rm -rf -- "$WORK_DIR"
        fi
    fi
    if (( RECEIPT_WRITTEN == 0 )); then
        write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
    fi
    trap - EXIT
    exit "$rc"
}

latest_entry() {
    local root="$1" type="$2" pattern="$3"
    find "$root" -mindepth 1 -maxdepth 1 -type "$type" -name "$pattern" \
        ! -name '*.partial' ! -name '*.failed' \
        -printf '%T@|%p\n' 2>/dev/null |
        sort -rn |
        head -n 1 |
        cut -d'|' -f2-
}

latest_flash_backup() {
    find "$FLASH_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type f \
        \( -name '*-boot-backup-*.zip' -o -name '*-flash-backup-*.zip' \) \
        ! -name '*.partial' ! -name '*.failed' \
        -printf '%T@|%p\n' 2>/dev/null |
        sort -rn |
        head -n 1 |
        cut -d'|' -f2-
}

selected_archive() {
    local base="$1" wanted
    (( ${#APPDATA_ARCHIVE_ALLOWLIST[@]} == 0 )) && return 0
    for wanted in "${APPDATA_ARCHIVE_ALLOWLIST[@]}"; do
        [[ "$base" == "$wanted" ]] && return 0
    done
    return 1
}

validate_archive_paths() {
    local archive="$1"
    tar -tzf "$archive" 2>/dev/null |
        awk '
            /^\// { bad=1 }
            /(^|\/)\.\.(\/|$)/ { bad=1 }
            END { exit bad }
        '
}

validate_zip_paths() {
    local list_file="$1"
    awk '
        {
            path=$0
            gsub(/\\/, "/", path)
            if (path ~ /^\// || path ~ /^[A-Za-z]:\// ||
                path ~ /(^|\/)\.\.(\/|$)/) bad=1
        }
        END { exit(bad ? 1 : 0) }
    ' "$list_file"
}

file_bytes() {
    stat -c '%s' "$1" 2>/dev/null || printf 0
}

tree_bytes() {
    find "$1" -type f -printf '%s\n' 2>/dev/null |
        awk '{s+=$1} END {printf "%.0f", s+0}'
}

prune_logs() {
    local -a entries=()
    mapfile -t entries < <(
        find "$LOG_DIR" -maxdepth 1 -type f -name 'restore-drill-*.log' \
            -printf '%T@|%p\n' 2>/dev/null | sort -rn | cut -d'|' -f2-
    )
    for ((i=MAX_LOGS; i<${#entries[@]}; i++)); do
        rm -f -- "${entries[$i]}" 2>/dev/null || true
    done
}

prune_drills() {
    local -a entries=()
    mapfile -t entries < <(
        find "$DRILL_ROOT" -mindepth 1 -maxdepth 1 -type d \
            -name 'drill_[0-9]*_[0-9]*' -printf '%f\n' 2>/dev/null |
            sort -r |
            grep -E '^drill_[0-9]{8}_[0-9]{6}$'
    )
    for ((i=MAX_SUCCESSFUL_DRILLS; i<${#entries[@]}; i++)); do
        [[ "${entries[$i]}" =~ ^drill_[0-9]{8}_[0-9]{6}$ ]] || continue
        log INFO "Pruning old restore drill: ${entries[$i]}"
        rm -rf -- "${DRILL_ROOT:?}/${entries[$i]}" || return 1
    done
}

###############################################################################
# VALIDATION AND DRILL PHASES
###############################################################################

validate_environment() {
    local command numeric
    for command in find sort gzip tar unzip sha256sum flock awk stat grep; do
        command -v "$command" >/dev/null 2>&1 || {
            log ERROR "Required command not found: $command"
            return 1
        }
    done

    [[ "$REQUIRE_FLASH_CHECKSUM" == true ||
       "$REQUIRE_FLASH_CHECKSUM" == false ]] || {
        log ERROR "REQUIRE_FLASH_CHECKSUM must be true or false"
        return 1
    }
    [[ "$CHECK_SQLITE_DATABASES" == true ||
       "$CHECK_SQLITE_DATABASES" == false ]] || {
        log ERROR "CHECK_SQLITE_DATABASES must be true or false"
        return 1
    }
    [[ "$KEEP_FAILED_DRILL" == true ||
       "$KEEP_FAILED_DRILL" == false ]] || {
        log ERROR "KEEP_FAILED_DRILL must be true or false"
        return 1
    }

    for numeric in \
        "$MAX_APPDATA_ARCHIVES" \
        "$SQLITE_MAX_FILES" \
        "$EXTRA_FREE_MARGIN_BYTES" \
        "$MAX_SUCCESSFUL_DRILLS" \
        "$MAX_LOGS"
    do
        [[ "$numeric" =~ ^[0-9]+$ ]] || {
            log ERROR "Numeric restore-drill configuration is invalid: $numeric"
            return 1
        }
    done
    [[ "$EXTRACT_SPACE_MULTIPLIER" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
        log ERROR "EXTRACT_SPACE_MULTIPLIER must be a positive number"
        return 1
    }
    if ! [[ "$MIN_FLASH_ARCHIVE_FILES" =~ ^[0-9]+$ ]] ||
       (( MIN_FLASH_ARCHIVE_FILES < 1 )); then
        log ERROR "MIN_FLASH_ARCHIVE_FILES must be a positive integer"
        return 1
    fi

    [[ -d "$APPDATA_BACKUP_ROOT" ]] || {
        log ERROR "Appdata backup root unavailable: $APPDATA_BACKUP_ROOT"
        return 1
    }
    [[ -d "$FLASH_BACKUP_ROOT" ]] || {
        log ERROR "Flash backup root unavailable: $FLASH_BACKUP_ROOT"
        return 1
    }
    [[ "$DRILL_ROOT" == "$VAULT_MOUNT"/* &&
       "$DRILL_ROOT" != "$VAULT_MOUNT/" ]] || {
        log ERROR "Unsafe DRILL_ROOT: $DRILL_ROOT"
        return 1
    }

    APPDATA_BACKUP="$(latest_entry "$APPDATA_BACKUP_ROOT" d 'backup_[0-9]*_[0-9]*')"
    FLASH_BACKUP="$(latest_flash_backup)"
    [[ -n "$APPDATA_BACKUP" ]] || {
        log ERROR "No successful appdata backup generation found"
        return 1
    }
    [[ -n "$FLASH_BACKUP" ]] || {
        log ERROR "No boot-device ZIP backup found"
        return 1
    }
}

check_free_space() {
    local appdata_bytes flash_bytes compressed required available
    appdata_bytes="$(tree_bytes "$APPDATA_BACKUP")"
    flash_bytes="$(file_bytes "$FLASH_BACKUP")"
    compressed=$((appdata_bytes + flash_bytes))
    required="$(awk -v b="$compressed" -v m="$EXTRACT_SPACE_MULTIPLIER" \
        -v e="$EXTRA_FREE_MARGIN_BYTES" 'BEGIN {printf "%.0f", b*m+e}')"
    available="$(df -B1 --output=avail "$DRILL_ROOT" 2>/dev/null |
        awk 'NR==2 {print $1}')"
    [[ "$available" =~ ^[0-9]+$ ]] || return 1

    log INFO "Space preflight: available=$(human_bytes "$available"), required=$(human_bytes "$required")"
    if (( available < required )); then
        log ERROR "Insufficient free space for isolated extraction"
        return 1
    fi
}

drill_appdata() {
    local archive base extracted=0
    local -a archives=()

    mapfile -t archives < <(
        find "$APPDATA_BACKUP" -maxdepth 1 -type f -name '*.tar.gz' \
            -printf '%f\n' 2>/dev/null | sort
    )
    (( ${#archives[@]} > 0 )) || {
        log ERROR "No appdata archives found in $APPDATA_BACKUP"
        return 1
    }

    mkdir -p -- "$WORK_DIR/appdata" || return 1

    for base in "${archives[@]}"; do
        archive="${APPDATA_BACKUP}/${base}"
        base="${base%.tar.gz}"
        selected_archive "$base" || continue
        if (( MAX_APPDATA_ARCHIVES > 0 && extracted >= MAX_APPDATA_ARCHIVES )); then
            break
        fi

        log INFO "Testing appdata archive: $archive"
        gzip -t "$archive" || {
            log ERROR "Gzip integrity failed: $archive"
            return 1
        }
        tar -tzf "$archive" >/dev/null || {
            log ERROR "Tar listing failed: $archive"
            return 1
        }
        validate_archive_paths "$archive" || {
            log ERROR "Unsafe path found in archive: $archive"
            return 1
        }

        sha256sum "$archive" >>"$WORK_DIR/archive-sha256.txt" || return 1
        tar -xzf "$archive" -C "$WORK_DIR/appdata" \
            --no-same-owner --no-same-permissions || {
            log ERROR "Extraction failed: $archive"
            return 1
        }
        ARCHIVES_CHECKED=$((ARCHIVES_CHECKED + 1))
        ARCHIVES_EXTRACTED=$((ARCHIVES_EXTRACTED + 1))
        extracted=$((extracted + 1))
    done

    (( ARCHIVES_EXTRACTED > 0 )) || {
        log ERROR "Archive selection extracted nothing"
        return 1
    }
}

drill_flash() {
    local required found checksum_file checksum_dir checksum_name list_file
    log INFO "Testing boot-device backup: $FLASH_BACKUP"

    checksum_file="${FLASH_BACKUP}.sha256"
    if [[ -f "$checksum_file" ]]; then
        checksum_dir="$(dirname "$checksum_file")"
        checksum_name="$(basename "$checksum_file")"
        if ! (cd "$checksum_dir" && sha256sum -c --status "$checksum_name"); then
            FLASH_CHECKSUM_STATUS="FAILED"
            log ERROR "Boot-device SHA-256 verification failed: $checksum_file"
            return 1
        fi
        FLASH_CHECKSUM_STATUS="VERIFIED"
        log INFO "Boot-device SHA-256 verification passed"
    elif [[ "$REQUIRE_FLASH_CHECKSUM" == true ]]; then
        FLASH_CHECKSUM_STATUS="MISSING"
        log ERROR "Boot-device checksum sidecar is missing: $checksum_file"
        return 1
    else
        FLASH_CHECKSUM_STATUS="MISSING_ALLOWED"
        log WARN "Boot-device checksum sidecar is missing; continuing by configuration"
    fi

    unzip -tq "$FLASH_BACKUP" >/dev/null || {
        log ERROR "Boot-device ZIP integrity failed"
        return 1
    }

    mkdir -p -- "$WORK_DIR/flash" || return 1

    list_file="$WORK_DIR/flash-archive-list.txt"
    unzip -Z1 "$FLASH_BACKUP" >"$list_file" || {
        log ERROR "Boot-device ZIP listing failed"
        return 1
    }
    validate_zip_paths "$list_file" || {
        log ERROR "Boot-device ZIP contains an unsafe path"
        return 1
    }

    FLASH_ARCHIVE_FILES=$(
        awk 'substr($0, length($0), 1) != "/" {count++}
             END {print count+0}' "$list_file"
    )
    [[ "$FLASH_ARCHIVE_FILES" =~ ^[0-9]+$ ]] || FLASH_ARCHIVE_FILES=0
    if (( FLASH_ARCHIVE_FILES < MIN_FLASH_ARCHIVE_FILES )); then
        log ERROR "Boot-device ZIP contains only $FLASH_ARCHIVE_FILES files; minimum is $MIN_FLASH_ARCHIVE_FILES"
        return 1
    fi

    unzip -q "$FLASH_BACKUP" -d "$WORK_DIR/flash" || return 1
    sha256sum "$FLASH_BACKUP" >>"$WORK_DIR/archive-sha256.txt" || return 1

    for required in super.dat ident.cfg; do
        found="$(
            find "$WORK_DIR/flash" -type f -path "*/config/$required" \
                -print -quit 2>/dev/null
        )"
        [[ -n "$found" ]] || {
            log ERROR "Boot backup is missing required path: $required"
            return 1
        }
    done

    log INFO "Boot-device restore verified $FLASH_ARCHIVE_FILES files"
}

check_sqlite_databases() {
    local database result checked=0
    [[ "$CHECK_SQLITE_DATABASES" == true ]] || return 0
    if ! command -v sqlite3 >/dev/null 2>&1; then
        log WARN "sqlite3 is unavailable; database quick checks were skipped"
        return 0
    fi

    while IFS= read -r -d '' database; do
        if (( checked >= SQLITE_MAX_FILES )); then
            log WARN "SQLite check limit reached: $SQLITE_MAX_FILES"
            break
        fi
        dd if="$database" bs=15 count=1 status=none 2>/dev/null |
            grep -q '^SQLite format 3' || continue
        checked=$((checked + 1))
        DATABASES_CHECKED=$((DATABASES_CHECKED + 1))
        result="$(sqlite3 -readonly "$database" 'PRAGMA quick_check;' 2>&1)" || true
        if [[ "$result" != "ok" ]]; then
            DATABASES_FAILED=$((DATABASES_FAILED + 1))
            log ERROR "SQLite quick_check failed: $database: $result"
        else
            log INFO "SQLite quick_check passed: $database"
        fi
    done < <(
        find "$WORK_DIR/appdata" -type f \
            \( -iname '*.db' -o -iname '*.sqlite' -o -iname '*.sqlite3' \) \
            -print0 2>/dev/null
    )

    (( DATABASES_FAILED == 0 ))
}

promote_drill() {
    {
        printf 'script_version=%s\n' "$SCRIPT_VERSION"
        printf 'completed=%s\n' "$(date -Iseconds)"
        printf 'appdata_backup=%s\n' "$APPDATA_BACKUP"
        printf 'flash_backup=%s\n' "$FLASH_BACKUP"
        printf 'flash_checksum_status=%s\n' "$FLASH_CHECKSUM_STATUS"
        printf 'flash_archive_files=%s\n' "$FLASH_ARCHIVE_FILES"
        printf 'archives_extracted=%s\n' "$ARCHIVES_EXTRACTED"
        printf 'databases_checked=%s\n' "$DATABASES_CHECKED"
    } >"$WORK_DIR/result.txt" || return 1

    mv -- "$WORK_DIR" "$FINAL_DIR" || return 1
    WORK_PROMOTED=1
}

###############################################################################
# MAIN
###############################################################################

main() {
    trap cleanup EXIT

    if ! mountpoint -q "$VAULT_MOUNT"; then
        printf 'Vault pool is not mounted: %s\n' "$VAULT_MOUNT" >&2
        return 1
    fi
    mkdir -p -- "$LOG_DIR" "$DRILL_ROOT" || return 1
    : >"$LOG_FILE" || return 1
    prune_logs

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        RESULT_SUMMARY="Another restore drill is already active"
        log ERROR "$RESULT_SUMMARY"
        return 1
    fi

    log INFO "Starting isolated backup restore drill"
    validate_environment || return 1
    check_free_space || return 1
    [[ ! -e "$WORK_DIR" && ! -e "$FINAL_DIR" ]] || {
        log ERROR "Drill destination already exists"
        return 1
    }
    mkdir -p -- "$WORK_DIR" || return 1

    drill_appdata || return 1
    drill_flash || return 1
    check_sqlite_databases || return 1
    promote_drill || return 1
    prune_drills || {
        RESULT_STATUS="WARNING"
        RESULT_SUMMARY="Restore drill passed, but old drill pruning failed"
        write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
        notify_unraid warning "Restore drill warning" "$RESULT_SUMMARY"
        return 1
    }

    RESULT_STATUS="OK"
    RESULT_SUMMARY="${ARCHIVES_EXTRACTED} appdata archives restored; ${DATABASES_CHECKED} SQLite databases checked; boot ZIP restored with ${FLASH_ARCHIVE_FILES} files and checksum ${FLASH_CHECKSUM_STATUS}"
    log INFO "$RESULT_SUMMARY"
    write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
    notify_unraid normal "Restore drill passed" \
        "$RESULT_SUMMARY"$'\n'"Staging result: $FINAL_DIR"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
