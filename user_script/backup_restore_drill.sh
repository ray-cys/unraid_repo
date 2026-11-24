#!/bin/bash

###############################################################################
# Backup Restore Drill
#
# Checks that selected Hubble appdata and boot-device backups can be read and
# restored into an isolated staging directory. It never writes to live appdata
# or the boot device. This is a bounded extraction/database drill, not proof
# of application startup or boot-device recovery.
#
# CLI: bash script [--generation-root /mnt/user/backup/vault_versions/hubble-STAMP]
# With no arguments use the newest local backups. --generation-root uses the
# completed ISS generation itself (appdata/ and flash/); it is run ON ISS.
# Optional environment: VAULT_MOUNT, DRILL_ROOT, LOG_DIR, STATUS_DIR,
# MAX_APPDATA_ARCHIVES (0=all), MAX_EXTRACT_BYTES, EXTRA_FREE_MARGIN_BYTES.
# Default: rotate two archives weekly; release restored payload after checking
# each archive and retain compact evidence only. Larger archives exceeding the
# space budget are reported as untested, never silently counted as verified.
# An OK result covers the named selection, not every application or a full restore.
###############################################################################

set -uo pipefail
umask 077

readonly SCRIPT_VERSION="1.3"

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

MAX_APPDATA_ARCHIVES="${MAX_APPDATA_ARCHIVES:-2}"
MAX_EXTRACT_BYTES="${MAX_EXTRACT_BYTES:-$((64 * 1024 * 1024 * 1024))}"
CHECK_SQLITE_DATABASES="${CHECK_SQLITE_DATABASES:-true}"
SQLITE_MAX_FILES="${SQLITE_MAX_FILES:-200}"

REQUIRE_FLASH_CHECKSUM="${REQUIRE_FLASH_CHECKSUM:-true}"
MIN_FLASH_ARCHIVE_FILES="${MIN_FLASH_ARCHIVE_FILES:-10}"

# Compressed input size multiplied by this factor for extraction-space checks.
EXTRACT_SPACE_MULTIPLIER="${EXTRACT_SPACE_MULTIPLIER:-4}"
EXTRA_FREE_MARGIN_BYTES="${EXTRA_FREE_MARGIN_BYTES:-$((5 * 1024 * 1024 * 1024))}"

MAX_SUCCESSFUL_DRILLS="${MAX_SUCCESSFUL_DRILLS:-2}"
KEEP_FAILED_DRILL="${KEEP_FAILED_DRILL:-false}"

LOG_DIR="${LOG_DIR:-/mnt/vault/cloud/logs/script/backup_restore_drill}"
MAX_LOGS="${MAX_LOGS:-5}"
STATUS_DIR="${STATUS_DIR:-/mnt/vault/cloud/logs/script/user_scripts_status}"
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
DRILL_WARNINGS=0
ARCHIVES_SKIPPED=0
GENERATION_ROOT=""
EXTRACT_PID=""
SELECTED_NAMES=()
SELECTED_BYTES=()
SELECTED_HASHES=()
SELECTED_RAW=()
EXTRACTED_BASE=""
CHECKED_NAMES=()
SKIPPED_NAMES=()

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
    if [[ -n "$EXTRACT_PID" ]]; then
        kill -TERM -- "-$EXTRACT_PID" 2>/dev/null || true
        wait "$EXTRACT_PID" 2>/dev/null || true
    fi
    if (( rc != 0 )); then
        RESULT_SUMMARY="Restore drill failed: ${RESULT_SUMMARY}; archives restored=$ARCHIVES_EXTRACTED, database failures=$DATABASES_FAILED. Production data was not modified."
        notify_unraid alert "Restore drill failed" "$RESULT_SUMMARY"$'\n'"Source: $APPDATA_BACKUP"$'\n'"Log: $LOG_FILE"
    fi
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

latest_backup_boot_disk() {
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
    for command in find sort tar unzip sha256sum flock awk stat grep jq realpath setsid timeout; do
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
        "$MAX_EXTRACT_BYTES" \
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

    if [[ -n "$GENERATION_ROOT" ]]; then
        APPDATA_BACKUP_ROOT="$GENERATION_ROOT/appdata"
        FLASH_BACKUP_ROOT="$GENERATION_ROOT/flash"
    fi
    [[ -d "$APPDATA_BACKUP_ROOT" ]] || {
        log ERROR "Appdata backup root unavailable: $APPDATA_BACKUP_ROOT"
        return 1
    }
    [[ -d "$FLASH_BACKUP_ROOT" ]] || {
        log ERROR "Flash backup root unavailable: $FLASH_BACKUP_ROOT"
        return 1
    }
    mountpoint -q "$VAULT_MOUNT" || return 1
    [[ ! -L "$DRILL_ROOT" && $(realpath -m -- "$DRILL_ROOT") == "$DRILL_ROOT" ]] || return 1
    [[ "$DRILL_ROOT" == "$VAULT_MOUNT"/* &&
       "$DRILL_ROOT" != "$VAULT_MOUNT/" ]] || {
        log ERROR "Unsafe DRILL_ROOT: $DRILL_ROOT"
        return 1
    }

    if [[ -n "$GENERATION_ROOT" ]]; then
        [[ "$GENERATION_ROOT" =~ ^/mnt/user/backup/vault_versions/hubble-[0-9]{8}_[0-9]{6}$ &&
           -f "$GENERATION_ROOT/completed.txt" && ! -L "$GENERATION_ROOT" &&
           $(realpath -e "$GENERATION_ROOT") == "$GENERATION_ROOT" ]] || {
            log ERROR "Expected a completed canonical ISS generation"; return 1;
        }
        APPDATA_BACKUP="$GENERATION_ROOT/appdata"
        FLASH_BACKUP_ROOT="$GENERATION_ROOT/flash"
    else
        APPDATA_BACKUP="$(latest_entry "$APPDATA_BACKUP_ROOT" d 'backup_[0-9]*_[0-9]*')"
    fi
    FLASH_BACKUP="$(latest_backup_boot_disk)"
    [[ -n "$APPDATA_BACKUP" ]] || {
        log ERROR "No successful appdata backup generation found"
        return 1
    }
    [[ -n "$FLASH_BACKUP" ]] || {
        log ERROR "No boot-device ZIP backup found"
        return 1
    }
}

# A selected archive is checked against the original producer manifest. Hashes
# are not re-created as a new baseline. Manifest checksum must name only itself.
select_appdata_archives() {
    local raw bytes hash name count expected i start j
    local -a names=() sizes=() hashes=() raws=()
    [[ -f "$APPDATA_BACKUP/backup_manifest.tsv" && ! -L "$APPDATA_BACKUP/backup_manifest.tsv" &&
       -f "$APPDATA_BACKUP/backup_manifest.tsv.sha256" ]] || return 1
    [[ $(wc -l <"$APPDATA_BACKUP/backup_manifest.tsv.sha256") == 1 ]] || return 1
    hash=$(awk '{print $1}' "$APPDATA_BACKUP/backup_manifest.tsv.sha256")
    [[ "$hash" =~ ^[a-f0-9]{64}$ &&
       $(sha256sum "$APPDATA_BACKUP/backup_manifest.tsv" | awk '{print $1}') == "$hash" ]] || return 1
    expected=$(sed -n 's/^# archive_count=//p' "$APPDATA_BACKUP/backup_manifest.tsv")
    [[ "$expected" =~ ^[1-9][0-9]*$ ]] || return 1
    while IFS=$'\t' read -r raw bytes hash name; do
        [[ "$raw" == \#* ]] && continue
        [[ "$raw" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ && "$hash" =~ ^[a-f0-9]{64}$ &&
           "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ &&
           -f "$APPDATA_BACKUP/$name.tar.gz" && ! -L "$APPDATA_BACKUP/$name.tar.gz" ]] || return 1
        # Reject duplicates, which could hide a missing archive behind the count.
        for i in "${names[@]}"; do [[ "$i" != "$name" ]] || return 1; done
        names+=("$name"); sizes+=("$bytes"); hashes+=("$hash"); raws+=("$raw")
    done <"$APPDATA_BACKUP/backup_manifest.tsv"
    count=${#names[@]}
    (( count == expected )) || return 1
    start=$(( ($(date +%s) / 604800 * 2) % count ))
    for ((j=0; j<count; j++)); do
        i=$(( (start+j) % count ))
        selected_archive "${names[$i]}" || continue
        if (( ${raws[$i]} > MAX_EXTRACT_BYTES )); then
            ARCHIVES_SKIPPED=$((ARCHIVES_SKIPPED+1))
            SKIPPED_NAMES+=("${names[$i]} (estimated expanded size exceeds budget)")
            log INFO "Outside bounded drill scope: ${names[$i]}; recorded raw size exceeds $(human_bytes "$MAX_EXTRACT_BYTES") budget"
            continue
        fi
        if (( MAX_APPDATA_ARCHIVES > 0 && ${#SELECTED_NAMES[@]} >= MAX_APPDATA_ARCHIVES )); then continue; fi
        SELECTED_NAMES+=("${names[$i]}"); SELECTED_BYTES+=("${sizes[$i]}")
        SELECTED_HASHES+=("${hashes[$i]}"); SELECTED_RAW+=("${raws[$i]}")
    done
    (( ${#SELECTED_NAMES[@]} > 0 ))
}

check_free_space() {
    local available required=0 raw
    for raw in "${SELECTED_RAW[@]}"; do (( raw <= required )) || required=$raw; done
    # One appdata archive is extracted at a time. The larger compressed-size
    # estimate is a fallback; recorded raw sizes can be stale, so runtime checks
    # remain mandatory during extraction.
    local compressed
    for compressed in "${SELECTED_BYTES[@]}"; do
        raw=$(awk -v b="$compressed" -v m="$EXTRACT_SPACE_MULTIPLIER" 'BEGIN {printf "%.0f",b*m}')
        (( raw <= required )) || required=$raw
    done
    (( required <= MAX_EXTRACT_BYTES )) || required=$MAX_EXTRACT_BYTES
    required=$((required + EXTRA_FREE_MARGIN_BYTES + $(file_bytes "$FLASH_BACKUP")))
    available=$(df -B1 --output=avail "$DRILL_ROOT" | awk 'NR==2 {print $1}')
    [[ "$available" =~ ^[0-9]+$ ]] || return 1
    log INFO "Selected ${#SELECTED_NAMES[@]} appdata archives; available=$(human_bytes "$available"), required=$(human_bytes "$required")"
    (( available >= required ))
}

bounded_extract() {
    local archive="$1" destination="$2" available used rc=0
    mkdir -p -- "$destination" || return 1
    # GNU tar rejects traversal and extraction through symlink parents. Keep-old
    # also refuses duplicate/overlapping entries. Each archive gets a fresh root.
    local -a extract_command
    if [[ "$archive" == *.zip ]]; then
        extract_command=(unzip -q "$archive" -d "$destination")
    else
        extract_command=(tar -xzf "$archive" -C "$destination" --no-same-owner
            --no-same-permissions --keep-old-files --delay-directory-restore)
    fi
    setsid timeout --signal=TERM --kill-after=10 3600 "${extract_command[@]}" \
        >"$WORK_DIR/extraction.stdout" 2>"$WORK_DIR/extraction.stderr" &
    EXTRACT_PID=$!
    while kill -0 "$EXTRACT_PID" 2>/dev/null; do
        available=$(df -B1 --output=avail "$DRILL_ROOT" | awk 'NR==2 {print $1}')
        used=$(du -sb "$destination" | awk '{print $1}')
        if ! [[ "$available" =~ ^[0-9]+$ && "$used" =~ ^[0-9]+$ ]] ||
           (( available < EXTRA_FREE_MARGIN_BYTES || used > MAX_EXTRACT_BYTES )); then
            log ERROR "Extraction stopped: free-space reserve or expanded-size budget exceeded"
            kill -TERM -- "-$EXTRACT_PID" 2>/dev/null || true
            wait "$EXTRACT_PID" 2>/dev/null || true
            EXTRACT_PID=""; return 1
        fi
        sleep 1
    done
    wait "$EXTRACT_PID" || rc=$?
    EXTRACT_PID=""
    if (( rc != 0 )); then tail -n 12 "$WORK_DIR/extraction.stderr"; return "$rc"; fi
    used=$(du -sb "$destination" | awk '{print $1}')
    available=$(df -B1 --output=avail "$DRILL_ROOT" | awk 'NR==2 {print $1}')
    (( used <= MAX_EXTRACT_BYTES && available >= EXTRA_FREE_MARGIN_BYTES ))
}

drill_appdata() {
    local i name archive hash
    mkdir -p -- "$WORK_DIR/appdata" || return 1
    for ((i=0; i<${#SELECTED_NAMES[@]}; i++)); do
        name="${SELECTED_NAMES[$i]}"; archive="$APPDATA_BACKUP/$name.tar.gz"
        RESULT_SUMMARY="Checking appdata archive $name"
        [[ $(file_bytes "$archive") == "${SELECTED_BYTES[$i]}" ]] || return 1
        hash=$(sha256sum "$archive" | awk '{print $1}') || return 1
        [[ "$hash" == "${SELECTED_HASHES[$i]}" ]] || { log ERROR "Producer checksum mismatch: $name"; return 1; }
        validate_archive_paths "$archive" || { log ERROR "Unsafe/unreadable tar: $name"; return 1; }
        bounded_extract "$archive" "$WORK_DIR/appdata/$name" || return 1
        ARCHIVES_CHECKED=$((ARCHIVES_CHECKED+1)); ARCHIVES_EXTRACTED=$((ARCHIVES_EXTRACTED+1))
        EXTRACTED_BASE="$WORK_DIR/appdata/$name"
        check_sqlite_databases || return 1
        CHECKED_NAMES+=("$name")
        printf '%s  %s.tar.gz\n' "$hash" "$name" >>"$WORK_DIR/archive-sha256.txt"
        rm -rf -- "$WORK_DIR/appdata/$name" || return 1
        log INFO "Restored and checked $name; temporary payload removed"
    done
}

# Syntax/schema checks only: never execute restored scripts/templates.
CONTROL_SCRIPTS_CHECKED=0
CONTROL_TEMPLATES_CHECKED=0
RECOVERY_CHECK_RESULT="not checked"
drill_control_plane() {
    local config="$1" file schedule entry frequency script normalized
    if [[ ! -f "$config/docker.cfg" ]]; then
        log WARN 'Docker configuration absent from control-plane copy'; DRILL_WARNINGS=$((DRILL_WARNINGS+1))
    fi
    if [[ -d "$config/plugins/dockerMan/templates-user" ]]; then
        while IFS= read -r -d '' file; do
            if command -v php >/dev/null 2>&1; then
                php -r '
                  $s=file_get_contents($argv[1]);
                  if (preg_match("/<!DOCTYPE|<!ENTITY/i",$s)) exit(1);
                  libxml_use_internal_errors(true);
                  $x=simplexml_load_string($s,"SimpleXMLElement",LIBXML_NONET);
                  exit($x!==false && $x->getName()==="Container" && trim((string)$x->Name)!=="" && trim((string)$x->Repository)!=="" ? 0:1);
                ' "$file" >/dev/null 2>&1 || { log ERROR "Invalid Docker template: ${file##*/}"; return 1; }
                CONTROL_TEMPLATES_CHECKED=$((CONTROL_TEMPLATES_CHECKED+1))
            else
                log WARN 'PHP unavailable; Docker XML syntax not verified'; DRILL_WARNINGS=$((DRILL_WARNINGS+1)); break
            fi
        done < <(find "$config/plugins/dockerMan/templates-user" -type f -name '*.xml' -print0)
    else
        log WARN 'Docker templates absent from control-plane copy'; DRILL_WARNINGS=$((DRILL_WARNINGS+1))
    fi
    if [[ -d "$config/plugins/user.scripts/scripts" ]]; then
        while IFS= read -r -d '' file; do
            normalized="$WORK_DIR/control-script.tmp"
            tr -d '\r' <"$file" >"$normalized" || return 1
            IFS= read -r script <"$normalized" || true
            case "$script" in
                '#!'*bash*|'#!'*'/sh'|'') bash -n "$normalized" >/dev/null 2>&1 || { log ERROR "User Script syntax failed: ${file%/script}"; return 1; }; CONTROL_SCRIPTS_CHECKED=$((CONTROL_SCRIPTS_CHECKED+1));;
                '#!'*) log WARN "Non-shell User Script not syntax-tested: ${file%/script}"; DRILL_WARNINGS=$((DRILL_WARNINGS+1));;
                *) bash -n "$normalized" >/dev/null 2>&1 || return 1; CONTROL_SCRIPTS_CHECKED=$((CONTROL_SCRIPTS_CHECKED+1));;
            esac
            rm -f "$normalized"
        done < <(find "$config/plugins/user.scripts/scripts" -type f -name script -print0)
    else
        log WARN 'User Scripts absent from control-plane copy'; DRILL_WARNINGS=$((DRILL_WARNINGS+1))
    fi
    schedule="$config/plugins/user.scripts/schedule.json"
    if [[ -f "$schedule" ]]; then
        jq -e 'type=="object" and all(.[]; type=="object" and (.script|type=="string") and (.frequency|type=="string"))' "$schedule" >/dev/null || {
            log ERROR 'User Scripts schedule JSON schema invalid'; return 1;
        }
        while IFS= read -r entry; do
            script=$(jq -r .script <<<"$entry"); frequency=$(jq -r .frequency <<<"$entry")
            case "$frequency" in ''|disabled|Disabled) continue;; esac
            # Validate known absolute plugin paths without executing any schedule.
            case "$script" in
                /boot/config/plugins/user.scripts/scripts/*/script)
                    [[ "$script" != *'/../'* && -f "$config/${script#/boot/config/}" ]] || { log ERROR 'Active schedule references a missing User Script'; return 1; };;
                *) log WARN 'Schedule uses an unrecognized script path; manual mapping required'; DRILL_WARNINGS=$((DRILL_WARNINGS+1));;
            esac
            if [[ "$frequency" == custom && ! -s "$config/plugins/user.scripts/customSchedule.cron" ]]; then
                log WARN 'Custom schedule present without customSchedule.cron'; DRILL_WARNINGS=$((DRILL_WARNINGS+1))
            fi
        done < <(jq -c '.[]' "$schedule")
    else
        log WARN 'User Scripts schedule absent from control-plane copy'; DRILL_WARNINGS=$((DRILL_WARNINGS+1))
    fi
}

drill_recovery_bundle() {
    local root="${RECOVERY_BUNDLE_ROOT:-/mnt/vault/backup/operations_state/recovery}" file line hash rel count=0 expected
    [[ -z "$GENERATION_ROOT" ]] || root="$GENERATION_ROOT/operations_state/recovery"
    if [[ ! -d "$root" ]]; then
        RECOVERY_CHECK_RESULT="absent; older backup has no recovery bundle"
        log WARN "$RECOVERY_CHECK_RESULT"; DRILL_WARNINGS=$((DRILL_WARNINGS+1)); return 0
    fi
    [[ ! -L "$root" && $(realpath -e "$root") == "$root" && -f "$root/SHA256SUMS" ]] || return 1
    [[ -z $(find "$root" -type l -print -quit) ]] || return 1
    : >"$WORK_DIR/recovery-checked-paths.txt" || return 1
    # Check each path before hashing. Do not trust checksum-file path arguments.
    while IFS= read -r line; do
        hash=${line%% *}; rel=${line#*  }
        [[ "$hash" =~ ^[a-f0-9]{64}$ && "$rel" == ./* && "$rel" != *'/../'* && "$rel" != */.. && "$rel" != *'/./'* && "$rel" != ./SHA256SUMS ]] || return 1
        [[ -f "$root/$rel" && $(realpath -e "$root/$rel") == "$root/${rel#./}" ]] || return 1
        [[ $(sha256sum "$root/$rel" | awk '{print $1}') == "$hash" ]] || { log ERROR 'Recovery bundle checksum mismatch'; return 1; }
        printf '%s\n' "$rel" >>"$WORK_DIR/recovery-checked-paths.txt"
        count=$((count+1))
    done <"$root/SHA256SUMS"
    expected=$(find "$root" -type f ! -path "$root/SHA256SUMS" | wc -l)
    [[ "$count" -eq "$expected" && $(sort -u "$WORK_DIR/recovery-checked-paths.txt" | wc -l) -eq "$count" ]] || return 1
    jq -e '.schema==1 and (.containerCount|type=="number") and (.runtimeStatus=="complete" or .runtimeStatus=="partial" or .runtimeStatus=="unavailable")' "$root/inventory.json" >/dev/null || return 1
    for file in containers images networks volumes files policies coverage; do
        jq -e 'type=="array"' "$root/$file.json" >/dev/null || return 1
    done
    [[ $(jq length "$root/containers.json") -eq $(jq .containerCount "$root/inventory.json") ]] || return 1
    RECOVERY_CHECK_RESULT="SHA-256 verified $count recovery files; runtime=$(jq -r .runtimeStatus "$root/inventory.json"); named-volume mounts=$(jq .namedVolumeMounts "$root/inventory.json")"
    if [[ $(jq -r .runtimeStatus "$root/inventory.json") != complete ]] || (( $(jq .namedVolumeMounts "$root/inventory.json") > 0 )); then
        log WARN "$RECOVERY_CHECK_RESULT"; DRILL_WARNINGS=$((DRILL_WARNINGS+1))
    fi
    drill_control_plane "$root/boot-config/config" || return 1
    log INFO "$RECOVERY_CHECK_RESULT"
}

drill_flash() {
    local required found checksum_file checksum_name expected_hash actual_hash list_file
    log INFO "Testing boot-device backup: $FLASH_BACKUP"

    checksum_file="${FLASH_BACKUP}.sha256"
    if [[ -f "$checksum_file" ]]; then
        expected_hash=$(awk 'NR==1 {print $1}' "$checksum_file")
        checksum_name=$(sed -n '1s/^[^ ]*  //p' "$checksum_file")
        actual_hash=$(sha256sum "$FLASH_BACKUP" | awk '{print $1}') || return 1
        if [[ $(wc -l <"$checksum_file") != 1 ||
              "$checksum_name" != "${FLASH_BACKUP##*/}" ||
              ! "$expected_hash" =~ ^[a-f0-9]{64}$ || "$actual_hash" != "$expected_hash" ]]; then
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

    bounded_extract "$FLASH_BACKUP" "$WORK_DIR/flash" || return 1
    # Extraction validated ZIP CRC; the sidecar was already hashed above.
    printf '%s\n' "$FLASH_CHECKSUM_STATUS $FLASH_BACKUP" >>"$WORK_DIR/archive-sha256.txt" || return 1

    found=$(find "$WORK_DIR/flash" -type d -name config -print -quit)
    [[ -n "$found" ]] || { log ERROR "Boot backup has no config directory"; return 1; }
    for required in super.dat ident.cfg; do
        found="$(
            find "$WORK_DIR/flash" -type f -path "*/config/$required" \
                -print -quit 2>/dev/null
        )"
        [[ -n "$found" ]] || {
            log WARN "Boot backup lacks recommended legacy path: $required; review this OS/storage layout"
            DRILL_WARNINGS=$((DRILL_WARNINGS+1))
        }
    done

    drill_control_plane "$(find "$WORK_DIR/flash" -type d -name config -print -quit)" || return 1
    log INFO "Boot-device restore verified $FLASH_ARCHIVE_FILES files"
    rm -rf -- "$WORK_DIR/flash" || return 1
}

check_sqlite_databases() {
    local database result checked=0
    [[ "$CHECK_SQLITE_DATABASES" == true ]] || return 0
    if ! command -v sqlite3 >/dev/null 2>&1; then
        log WARN "sqlite3 is unavailable; database checks NOT verified"
        DRILL_WARNINGS=$((DRILL_WARNINGS+1)); return 0
    fi

    while IFS= read -r -d '' database; do
        if (( checked >= SQLITE_MAX_FILES )); then
            log WARN "SQLite check limit reached: $SQLITE_MAX_FILES; remaining databases NOT verified"
            DRILL_WARNINGS=$((DRILL_WARNINGS+1)); break
        fi
        dd if="$database" bs=15 count=1 status=none 2>/dev/null |
            grep -q '^SQLite format 3' || continue
        checked=$((checked + 1))
        DATABASES_CHECKED=$((DATABASES_CHECKED + 1))
        result="$(timeout --signal=TERM --kill-after=5 120 sqlite3 -readonly "$database" 'PRAGMA quick_check;' 2>&1)" || true
        if [[ "$result" == *"no such collation"* || "$result" == *"no such function"* ]]; then
            DRILL_WARNINGS=$((DRILL_WARNINGS+1))
            log WARN "Database check unverified: $database; SQLite build lacks required application extension: $result"
        elif [[ "$result" != "ok" ]]; then
            DATABASES_FAILED=$((DATABASES_FAILED + 1))
            log ERROR "SQLite quick_check failed: $database: $result"
        else
            log INFO "SQLite quick_check passed: $database"
        fi
    done < <(
        find "${EXTRACTED_BASE:-$WORK_DIR/appdata}" -type f \
            \( -iname '*.db' -o -iname '*.sqlite' -o -iname '*.sqlite3' \) \
            -print0 2>/dev/null
    )

    (( DATABASES_FAILED == 0 ))
}

promote_drill() {
    {
        printf 'script_version=%s\n' "$SCRIPT_VERSION"
        printf 'completed=%s\n' "$(date -Iseconds)"
        printf 'backup_cache_appdata=%s\n' "$APPDATA_BACKUP"
        printf 'backup_boot_disk=%s\n' "$FLASH_BACKUP"
        printf 'flash_checksum_status=%s\n' "$FLASH_CHECKSUM_STATUS"
        printf 'flash_archive_files=%s\n' "$FLASH_ARCHIVE_FILES"
        printf 'archives_extracted=%s\n' "$ARCHIVES_EXTRACTED"
        printf 'databases_checked=%s\n' "$DATABASES_CHECKED"
        printf 'scope=rotating bounded selection; no service startup or boot test\n'
        printf 'checked_archive=%s\n' "${CHECKED_NAMES[@]}"
        printf 'not_extracted=%s\n' "${SKIPPED_NAMES[@]}"
    } >"$WORK_DIR/result.txt" || return 1

    mv -- "$WORK_DIR" "$FINAL_DIR" || return 1
    WORK_PROMOTED=1
}

###############################################################################
# MAIN
###############################################################################

main() {
    case "${1:-}" in
        --help) printf 'Usage: bash script [--generation-root /mnt/user/backup/vault_versions/hubble-STAMP]\nRun on the host holding the backup. Default rotates two archives; MAX_APPDATA_ARCHIVES=0 selects all within MAX_EXTRACT_BYTES. Restored payload is removed; only evidence retained.\n'; return 0;;
        --generation-root) [[ $# == 2 ]] || return 2; GENERATION_ROOT="$2";;
        "") ;;
        *) return 2;;
    esac
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if ! mountpoint -q "$VAULT_MOUNT"; then
        printf 'Vault pool is not mounted: %s\n' "$VAULT_MOUNT" >&2
        return 1
    fi
    [[ "$DRILL_ROOT" == "$VAULT_MOUNT"/* && "$DRILL_ROOT" != "$VAULT_MOUNT/" &&
       ! -L "$DRILL_ROOT" && $(realpath -m -- "$DRILL_ROOT") == "$DRILL_ROOT" ]] || {
        printf 'Unsafe drill workspace: %s\n' "$DRILL_ROOT" >&2; return 1;
    }
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
    # Shared locks match producers; select only while retention is excluded.
    exec {APPDATA_LOCK_FD}>"${APPDATA_LOCK_FILE:-/tmp/backup_cache_appdata.lock}" || return 1
    flock -s -n "$APPDATA_LOCK_FD" || { RESULT_SUMMARY="Appdata producer active; retry the drill later"; return 1; }
    exec {FLASH_LOCK_FD}>"${FLASH_LOCK_FILE:-/tmp/backup_boot_disk.lock}" || return 1
    flock -s -n "$FLASH_LOCK_FD" || { RESULT_SUMMARY="Flash producer active; retry the drill later"; return 1; }
    # Export replacement takes this lock exclusively. Keep the local bundle
    # stable while hashing; immutable ISS generations need no Hubble lock.
    if [[ -z "$GENERATION_ROOT" ]]; then
        exec {RECOVERY_LOCK_FD}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || return 1
        flock -s -n "$RECOVERY_LOCK_FD" || { RESULT_SUMMARY="Recovery export active; retry later"; return 1; }
    fi
    validate_environment || return 1
    RESULT_SUMMARY="Producer manifest missing or invalid"
    select_appdata_archives || return 1
    RESULT_SUMMARY="Insufficient extraction space"
    check_free_space || return 1
    [[ ! -e "$WORK_DIR" && ! -e "$FINAL_DIR" ]] || {
        log ERROR "Drill destination already exists"
        return 1
    }
    mkdir -p -- "$WORK_DIR" || return 1

    drill_appdata || return 1
    RESULT_SUMMARY="Boot-device archive validation failed"
    drill_flash || return 1
    RESULT_SUMMARY="Recovery inventory/control-plane validation failed"
    drill_recovery_bundle || return 1
    promote_drill || return 1
    prune_drills || {
        RESULT_STATUS="WARNING"
        RESULT_SUMMARY="Restore drill passed, but old drill pruning failed"
        write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
        notify_unraid warning "Restore drill warning" "$RESULT_SUMMARY"
        return 1
    }

    RESULT_STATUS="OK"
    local importance=normal
    if (( DRILL_WARNINGS > 0 )); then RESULT_STATUS="WARNING"; importance=warning; fi
    RESULT_SUMMARY="Restored and removed temporary payload: ${CHECKED_NAMES[*]}. SQLite databases checked: ${DATABASES_CHECKED}. Boot ZIP restored: ${FLASH_ARCHIVE_FILES} files; checksum ${FLASH_CHECKSUM_STATUS}. Scope: rotating selection, not a full application/boot recovery test."
    RESULT_SUMMARY+=" Templates syntax-checked: $CONTROL_TEMPLATES_CHECKED; shell scripts syntax-checked: $CONTROL_SCRIPTS_CHECKED. Recovery: $RECOVERY_CHECK_RESULT."
    if (( ARCHIVES_SKIPPED > 0 )); then RESULT_SUMMARY+=" Outside extraction budget: ${SKIPPED_NAMES[*]}."; fi
    if (( DRILL_WARNINGS > 0 )); then RESULT_SUMMARY+=" Warnings/unverified checks: $DRILL_WARNINGS; review drill log for affected checks."; fi
    log INFO "$RESULT_SUMMARY"
    write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
    notify_unraid "$importance" "Restore drill $RESULT_STATUS" \
        "$RESULT_SUMMARY"$'\n'"Staging result: $FINAL_DIR"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
