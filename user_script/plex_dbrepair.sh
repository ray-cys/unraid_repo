#!/bin/bash

###############################################################################
# Plex DBRepair Scheduler Wrapper v3.2
#
# Unraid 7.4-focused scheduler for the current standalone DBRepair executable.
# It verifies the official GitHub release, stages updates safely inside each
# Plex Docker container, runs unattended maintenance, restores the container's
# original state, records a structured receipt, and sends one operational
# grouped notification only when something changed or needs attention.
###############################################################################

set -uo pipefail

readonly VERSION="3.2"

###############################################################################
# CONFIGURATION
###############################################################################

CONTAINERS=(
    "plex-media-server"
    "plex-media"
)

DBREPAIR_INSTALL_DIR="/config/DBRepair"
DBREPAIR_PATH="${DBREPAIR_INSTALL_DIR}/DBRepair"
DBREPAIR_PREVIOUS_PATH="${DBREPAIR_INSTALL_DIR}/DBRepair.previous"
LEGACY_DBREPAIR_PATH="${DBREPAIR_INSTALL_DIR}/DBRepair.sh"
LEGACY_DBREPAIR_ARCHIVE="${DBREPAIR_INSTALL_DIR}/DBRepair.sh.legacy"
DBREPAIR_ARGS=("automatic" "exit")
DBREPAIR_TIMEOUT_SECONDS=14400

GITHUB_RELEASE_API="https://api.github.com/repos/ChuckPa/DBRepair/releases/latest"
GITHUB_API_ACCEPT="application/vnd.github+json"

LOG_DIR="/mnt/vault/cloud/logs/script/plex_dbrepair"
LOG_FILE="${LOG_DIR}/dbrepair.log"
LOG_MAX_BYTES=$((2 * 1024 * 1024))
LOG_KEEP=2

REPORT_DIR="${LOG_DIR}/reports"
REPORT_RETENTION_DAYS=180
NOTIFICATION_STATE_FILE="${LOG_DIR}/notification-state.json"
NOTIFICATION_REMINDER_DAYS=7
NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"

STATUS_DIR="/mnt/vault/cloud/logs/script/user_scripts_status"
LOCK_FILE="/run/plex_dbrepair.lock"

CONTAINER_START_TIMEOUT_SECONDS=90
PLEX_START_TIMEOUT_SECONDS=90

###############################################################################
# RUNTIME
###############################################################################

START_EPOCH="$(date +%s)"
RUN_STAMP="$(date '+%Y%m%d_%H%M%S')_$$"
RUNTIME_DIR=""
RUN_REPORT_FILE=""

DOWNLOAD_READY=0
LATEST_VERSION=""
LATEST_ASSET_NAME=""
LATEST_ASSET_DIGEST=""
STAGED_BINARY=""
UPDATE_STATE="not-checked"
UPDATE_DETAIL="Not performed."
HOST_PACKAGE_ARCH=""

WARNING_COUNT=0
ERROR_COUNT=0
NOTIFICATION_FAILED=0

CONTAINERS_PROCESSED=0
CONTAINERS_SUCCESSFUL=0
CONTAINERS_FAILED=0
CONTAINERS_REPAIRED=0
CONTAINERS_HEALTHY=0
CONTAINERS_UPDATED=0
CONTAINERS_TEMP_STARTED=0
CONTAINERS_RECOVERED=0

RUN_HAS_REPAIR=0
RUN_HAS_ISSUE=0
RUN_HIGHEST_SEVERITY="normal"
GLOBAL_ISSUE_KEY=""

declare -a RESULT_ORDER=()
declare -A RESULT_CLASS=()
declare -A RESULT_FINDING=()
declare -A RESULT_ACTION=()
declare -A RESULT_FINAL_STATE=()
declare -A RESULT_VERSION=()
declare -A RESULT_RC=()
declare -A RESULT_DETAILS=()
declare -A RESULT_UPDATE=()

###############################################################################
# GENERAL HELPERS
###############################################################################

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    local level="$1"
    shift
    printf '%s [%s] [DBREPAIR] %s\n' \
        "$(timestamp)" "$level" "$*" | tee -a "$LOG_FILE"
}

warn() {
    log WARN "$*"
    WARNING_COUNT=$((WARNING_COUNT + 1))
    RUN_HAS_ISSUE=1
    GLOBAL_ISSUE_KEY+="warning:$*;"
    raise_severity warning
}

error() {
    log ERROR "$*" >&2
    ERROR_COUNT=$((ERROR_COUNT + 1))
    RUN_HAS_ISSUE=1
    GLOBAL_ISSUE_KEY+="error:$*;"
    raise_severity alert
}

human_duration() {
    local seconds="${1:-0}"
    printf '%dh:%02dm:%02ds' \
        $((seconds / 3600)) \
        $(((seconds % 3600) / 60)) \
        $((seconds % 60))
}

severity_rank() {
    case "$1" in
        alert) printf '3' ;;
        warning) printf '2' ;;
        *) printf '1' ;;
    esac
}

raise_severity() {
    local proposed="$1"
    if (( $(severity_rank "$proposed") > $(severity_rank "$RUN_HIGHEST_SEVERITY") )); then
        RUN_HIGHEST_SEVERITY="$proposed"
    fi
}

safe_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

map_linux_arch() {
    case "$1" in
        x86_64|amd64) printf 'x86_64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7l|armv7|armhf) printf 'arm32' ;;
        *) return 1 ;;
    esac
}

extract_version() {
    grep -Eo '[0-9]{2}\.[0-9]{2}\.[0-9]+' | awk 'NR == 1 {print; exit}'
}

cleanup() {
    local rc=$?
    if [[ -n "$RUNTIME_DIR" && "$RUNTIME_DIR" == /tmp/plex_dbrepair.* ]]; then
        rm -rf -- "$RUNTIME_DIR"
    fi
    trap - EXIT
    exit "$rc"
}

notify_unraid() {
    local importance="$1" description="$2" message="$3"
    if [[ ! -x "$NOTIFY_BIN" ]]; then
        error "Unraid notification command is unavailable: $NOTIFY_BIN"
        NOTIFICATION_FAILED=1
        return 1
    fi
    if ! "$NOTIFY_BIN" \
        -i "$importance" \
        -s "Plex DBRepair" \
        -d "$description" \
        -m "$message" \
        >/dev/null 2>&1; then
        error "Unraid notification command failed"
        NOTIFICATION_FAILED=1
        return 1
    fi
}

###############################################################################
# LOGS, REPORTS, AND STATUS
###############################################################################

rotate_log() {
    local size=0 i
    [[ -f "$LOG_FILE" ]] || return 0
    size="$(stat -c '%s' "$LOG_FILE" 2>/dev/null || printf '0')"
    (( size >= LOG_MAX_BYTES )) || return 0
    if (( LOG_KEEP <= 0 )); then
        : >"$LOG_FILE"
        return 0
    fi
    rm -f -- "${LOG_FILE}.${LOG_KEEP}" 2>/dev/null || true
    for ((i = LOG_KEEP - 1; i >= 1; i--)); do
        [[ -f "${LOG_FILE}.${i}" ]] || continue
        mv -f -- "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
    done
    mv -f -- "$LOG_FILE" "${LOG_FILE}.1"
}

cleanup_legacy_logs() {
    local old_log removed=0
    while IFS= read -r -d '' old_log; do
        rm -f -- "$old_log" || continue
        removed=$((removed + 1))
    done < <(
        find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type f \
            -name 'dbrepair-[0-9]*_[0-9]*.log' -print0 2>/dev/null
    )
    (( removed == 0 )) || log INFO "Removed $removed legacy timestamp log file(s)"
}

prune_reports() {
    local report removed=0
    mkdir -p -- "$REPORT_DIR" || return 1
    while IFS= read -r -d '' report; do
        [[ "$report" == "$REPORT_DIR"/dbrepair-*.txt ]] || continue
        rm -f -- "$report" || return 1
        removed=$((removed + 1))
    done < <(
        find "$REPORT_DIR" -mindepth 1 -maxdepth 1 -type f \
            -name 'dbrepair-*.txt' \
            -mtime "+${REPORT_RETENTION_DAYS}" -print0 2>/dev/null
    )
    (( removed == 0 )) || log INFO "Removed $removed DBRepair report(s) older than $REPORT_RETENTION_DAYS days"
}

write_status_receipt() {
    local status="$1" summary="$2" now tmp
    now="$(date +%s)"
    mkdir -p -- "$STATUS_DIR" 2>/dev/null || return 0
    tmp="$(mktemp "${STATUS_DIR}/.plex_dbrepair.XXXXXX")" || return 0
    if jq -n \
        --arg name "plex_dbrepair" \
        --arg status "$status" \
        --arg summary "$summary" \
        --arg log "$LOG_FILE" \
        --arg report "$RUN_REPORT_FILE" \
        --argjson epoch "$now" \
        --argjson duration "$((now - START_EPOCH))" \
        '{name:$name,status:$status,summary:$summary,log:$log,report:$report,epoch:$epoch,duration_seconds:$duration}' \
        >"$tmp"; then
        mv -f -- "$tmp" "${STATUS_DIR}/plex_dbrepair.json"
    else
        rm -f -- "$tmp"
    fi
}

###############################################################################
# VALIDATION AND LOCKING
###############################################################################

require_commands() {
    local command missing=0
    for command in awk cat chmod date docker find flock grep jq mkdir mktemp \
        mv rm sed sha256sum stat tee timeout tr uname; do
        if ! command -v "$command" >/dev/null 2>&1; then
            printf '%s [ERROR] [DBREPAIR] Required command not found: %s\n' \
                "$(timestamp)" "$command" >&2
            missing=1
        fi
    done
    (( missing == 0 ))
}

validate_configuration() {
    [[ ${#CONTAINERS[@]} -gt 0 ]] || {
        error "No Plex containers are configured"
        return 1
    }
    [[ "$DBREPAIR_INSTALL_DIR" == /config/* &&
       "$DBREPAIR_INSTALL_DIR" != *$'\n'* ]] || {
        error "DBREPAIR_INSTALL_DIR must be a safe path below /config"
        return 1
    }
    [[ "$DBREPAIR_PATH" == "$DBREPAIR_INSTALL_DIR"/* ]] || return 1
    [[ "$DBREPAIR_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$REPORT_RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$NOTIFICATION_REMINDER_DAYS" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$CONTAINER_START_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$PLEX_START_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || return 1
    docker info >/dev/null 2>&1 || {
        error "Docker is unavailable or the Unraid Docker service is not running"
        return 1
    }
}

acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log INFO "Another Plex DBRepair run is active; exiting"
        return 1
    fi
}

###############################################################################
# OFFICIAL RELEASE DISCOVERY AND VERIFICATION
###############################################################################

release_fallback() {
    local message="$1"
    DOWNLOAD_READY=0
    UPDATE_STATE="fallback-existing"
    UPDATE_DETAIL="$message; fallback policy: use validated installed executables"
    RUN_HAS_ISSUE=1
    GLOBAL_ISSUE_KEY+="release-fallback;"
    raise_severity warning
    warn "$UPDATE_DETAIL"
}

prepare_latest_release() {
    local release_json asset_row asset_url asset_size expected_digest
    local actual_size actual_digest version_output

    if ! command -v curl >/dev/null 2>&1 ||
       ! command -v unzip >/dev/null 2>&1; then
        release_fallback "curl or unzip is unavailable for DBRepair updates"
        return 0
    fi

    HOST_PACKAGE_ARCH="$(map_linux_arch "$(uname -m 2>/dev/null || true)" || true)"
    if [[ -z "$HOST_PACKAGE_ARCH" ]]; then
        release_fallback "Unsupported Unraid host architecture: $(uname -m 2>/dev/null || printf unknown)"
        return 0
    fi

    release_json="${RUNTIME_DIR}/release.json"
    if ! curl --fail --silent --show-error --location \
        --retry 2 --retry-delay 2 --connect-timeout 15 --max-time 90 \
        -H "Accept: ${GITHUB_API_ACCEPT}" \
        "$GITHUB_RELEASE_API" -o "$release_json"; then
        release_fallback "Could not query the official DBRepair release"
        return 0
    fi

    LATEST_VERSION="$(jq -r '.tag_name // ""' "$release_json" | sed 's/^v//')"
    asset_row="$(jq -r --arg suffix "-Linux-${HOST_PACKAGE_ARCH}.zip" '
        .assets[]?
        | select(.name | endswith($suffix))
        | [.name, .browser_download_url, (.digest // ""), (.size | tostring)]
        | @tsv
    ' "$release_json" | awk 'NR == 1 {print; exit}')"
    IFS=$'\t' read -r LATEST_ASSET_NAME asset_url LATEST_ASSET_DIGEST asset_size \
        <<<"$asset_row"

    if ! [[ "$LATEST_VERSION" =~ ^[0-9]{2}\.[0-9]{2}\.[0-9]+$ ]] ||
       ! [[ "$LATEST_ASSET_NAME" =~ ^DBRepair-[A-Za-z0-9._-]+-Linux-${HOST_PACKAGE_ARCH}\.zip$ ]] ||
       [[ "$asset_url" != https://github.com/ChuckPa/DBRepair/releases/* ]] ||
       [[ "$LATEST_ASSET_DIGEST" != sha256:* ]] ||
       ! [[ "$asset_size" =~ ^[1-9][0-9]*$ ]]; then
        release_fallback "The official release metadata was incomplete or unsafe"
        return 0
    fi

    expected_digest="${LATEST_ASSET_DIGEST#sha256:}"
    [[ "$expected_digest" =~ ^[[:xdigit:]]{64}$ ]] || {
        release_fallback "The official release did not provide a valid SHA-256 digest"
        return 0
    }

    log INFO "Downloading official DBRepair ${LATEST_VERSION} package for Linux ${HOST_PACKAGE_ARCH}"
    if ! curl --fail --silent --show-error --location \
        --retry 2 --retry-delay 2 --connect-timeout 15 --max-time 300 \
        "$asset_url" -o "${RUNTIME_DIR}/${LATEST_ASSET_NAME}"; then
        release_fallback "DBRepair ${LATEST_VERSION} download failed"
        return 0
    fi

    actual_size="$(stat -c '%s' "${RUNTIME_DIR}/${LATEST_ASSET_NAME}" 2>/dev/null || printf 0)"
    actual_digest="$(sha256sum -- "${RUNTIME_DIR}/${LATEST_ASSET_NAME}" | awk '{print $1}')"
    if [[ "$actual_size" != "$asset_size" || "$actual_digest" != "$expected_digest" ]]; then
        release_fallback "DBRepair ${LATEST_VERSION} package size or SHA-256 verification failed"
        return 0
    fi
    if ! unzip -tq "${RUNTIME_DIR}/${LATEST_ASSET_NAME}" >/dev/null 2>&1; then
        release_fallback "DBRepair ${LATEST_VERSION} ZIP validation failed"
        return 0
    fi

    mkdir -p -- "${RUNTIME_DIR}/release" || return 1
    if ! unzip -q "${RUNTIME_DIR}/${LATEST_ASSET_NAME}" DBRepair \
        -d "${RUNTIME_DIR}/release"; then
        release_fallback "DBRepair ${LATEST_VERSION} executable could not be extracted"
        return 0
    fi
    STAGED_BINARY="${RUNTIME_DIR}/release/DBRepair"
    chmod 0755 "$STAGED_BINARY" || {
        release_fallback "DBRepair ${LATEST_VERSION} executable could not be enabled"
        return 0
    }

    if ! version_output="$(
        cd "${RUNTIME_DIR}/release" && timeout 30 ./DBRepair --version 2>&1
    )" ||
       [[ "$(printf '%s\n' "$version_output" | extract_version)" != "$LATEST_VERSION" ]]; then
        release_fallback "The downloaded DBRepair executable failed its version test"
        return 0
    fi

    DOWNLOAD_READY=1
    UPDATE_STATE="verified-latest"
    UPDATE_DETAIL="Official DBRepair ${LATEST_VERSION} package passed size, SHA-256, ZIP and executable checks"
    log INFO "$UPDATE_DETAIL"
}

###############################################################################
# DOCKER AND DBREPAIR INSTALLATION
###############################################################################

container_exists() {
    docker inspect "$1" >/dev/null 2>&1
}

container_is_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == true ]]
}

wait_container_running() {
    local container="$1" deadline=$((SECONDS + CONTAINER_START_TIMEOUT_SECONDS))
    while (( SECONDS < deadline )); do
        container_is_running "$container" && return 0
        sleep 2
    done
    return 1
}

plex_process_running() {
    local processes
    processes="$(docker top "$1" -eo args 2>/dev/null || docker top "$1" 2>/dev/null)" || return 1
    grep -Fq 'Plex Media Server' <<<"$processes"
}

wait_plex_process() {
    local container="$1" deadline=$((SECONDS + PLEX_START_TIMEOUT_SECONDS))
    while (( SECONDS < deadline )); do
        plex_process_running "$container" && return 0
        sleep 3
    done
    return 1
}

read_container_tool_version() {
    local container="$1" path="$2" output
    output="$(docker exec -u 0 -w "$DBREPAIR_INSTALL_DIR" \
        "$container" "$path" --version 2>&1)" || return 1
    printf '%s\n' "$output" | extract_version
}

install_or_resolve_dbrepair() {
    local container="$1" container_arch current_version staged_version
    local current_usable=0 staged_path="${DBREPAIR_PATH}.new"

    RESULT_UPDATE["$container"]=""
    docker exec -u 0 "$container" mkdir -p "$DBREPAIR_INSTALL_DIR" \
        >/dev/null 2>&1 || {
        RESULT_UPDATE["$container"]="Installation directory creation failed: $DBREPAIR_INSTALL_DIR"
        return 1
    }

    current_version="$(read_container_tool_version "$container" "$DBREPAIR_PATH" || true)"
    [[ -n "$current_version" ]] && current_usable=1

    if (( DOWNLOAD_READY == 1 )); then
        container_arch="$(docker exec -u 0 "$container" uname -m 2>/dev/null || true)"
        container_arch="$(map_linux_arch "$container_arch" || true)"
        if [[ "$container_arch" != "$HOST_PACKAGE_ARCH" ]]; then
            RESULT_UPDATE["$container"]="Container architecture does not match the verified ${HOST_PACKAGE_ARCH} package"
        elif [[ "$current_version" == "$LATEST_VERSION" ]]; then
            RESULT_UPDATE["$container"]="DBRepair ${current_version} current; update not required"
        elif docker cp "$STAGED_BINARY" "$container:$staged_path" >/dev/null 2>&1 &&
             docker exec -u 0 "$container" chmod 0755 "$staged_path" >/dev/null 2>&1; then
            staged_version="$(read_container_tool_version "$container" "$staged_path" || true)"
            if [[ "$staged_version" == "$LATEST_VERSION" ]] &&
               docker exec -u 0 "$container" sh -c '
                   set -e
                   target="$1"
                   previous="$2"
                   staged="$3"
                   if [ -e "$target" ]; then cp -f "$target" "$previous"; fi
                   mv -f "$staged" "$target"
               ' sh "$DBREPAIR_PATH" "$DBREPAIR_PREVIOUS_PATH" "$staged_path" \
               >/dev/null 2>&1; then
                current_version="$staged_version"
                current_usable=1
                CONTAINERS_UPDATED=$((CONTAINERS_UPDATED + 1))
                RESULT_UPDATE["$container"]="Installed verified DBRepair ${current_version}"
                log INFO "[$container] Installed verified DBRepair ${current_version}"
            else
                docker exec -u 0 "$container" rm -f "$staged_path" >/dev/null 2>&1 || true
                RESULT_UPDATE["$container"]="Verified release could not replace the existing executable; existing copy retained"
            fi
        else
            docker exec -u 0 "$container" rm -f "$staged_path" >/dev/null 2>&1 || true
            RESULT_UPDATE["$container"]="Verified release could not be copied into the container; existing copy retained"
        fi
    else
        RESULT_UPDATE["$container"]="$UPDATE_DETAIL"
    fi

    case "${RESULT_UPDATE[$container]}" in
        *"could not"*|*"does not match"*|*"retained"*)
            warn "[$container] ${RESULT_UPDATE[$container]}"
            RUN_HAS_ISSUE=1
            GLOBAL_ISSUE_KEY+="${container}-update-fallback;"
            raise_severity warning
            ;;
    esac

    current_version="$(read_container_tool_version "$container" "$DBREPAIR_PATH" || true)"
    if [[ -z "$current_version" ]]; then
        RESULT_UPDATE["$container"]+="; no usable current DBRepair executable is installed"
        return 1
    fi
    current_usable=1

    docker exec -u 0 "$container" sh -c '
        legacy="$1"
        archive="$2"
        if [ -f "$legacy" ]; then
            if [ ! -e "$archive" ]; then
                mv "$legacy" "$archive"
            else
                rm -f "$legacy"
            fi
        fi
    ' sh "$LEGACY_DBREPAIR_PATH" "$LEGACY_DBREPAIR_ARCHIVE" \
        >/dev/null 2>&1 || true

    RESULT_VERSION["$container"]="$current_version"
    (( current_usable == 1 ))
}

###############################################################################
# OUTPUT CLASSIFICATION
###############################################################################

# Keep recognition and notification excerpts on the same input. Exclude only
# known routine progress/clean-result lines; preserve unknown messages and
# explicit WARNING/ERROR lines for review. Strip ANSI escapes before matching.
classification_output() {
    sed -E $'s/\033\\[[0-9;]*[[:alpha:]]//g' "$1" |
        awk '{
            line = $0
            sub(/^[[:space:]]*\[[0-9][0-9][0-9][0-9]-[^]]*\][[:space:]]*/, "", line)
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]]*$/, "", line)
            normalized = tolower(line)
            if (normalized ~ /^checking (main|blobs) (db|database) for orphaned media items[.]*$/) next
            if (normalized ~ /^(no|0) orphaned media items found[.]*$/) next
            print $0
        }'
}

output_has() {
    local file="$1" expression="$2"
    # Drain the stream to avoid SIGPIPE under pipefail for large tool output.
    classification_output "$file" | grep -Ei -- "$expression" >/dev/null
}

extract_notable_output() {
    local file="$1"
    classification_output "$file" |
        grep -Ei 'NOTICE|WARNING|ERROR|FAIL|damaged|unrecoverable|requires repair|ghost entr|NULL title|orphan|revert|rollback' |
        sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' |
        awk 'NF && !seen[$0]++ {print "- " $0; count++} count >= 8 {exit}' || true
}

classify_container_output() {
    local container="$1" output_file="$2" rc="$3"
    local main_ok=0 blobs_ok=0 damage=0 fts=0 bloat=0 ghost=0 orphan=0
    local promoted=0 rebuilt=0 unrecoverable=0 reverted=0 notices=0 details=""

    output_has "$output_file" 'Main([[:space:]]+Database|[[:space:]]+DB)[[:space:]]+is[[:space:]]+OK' && main_ok=1
    output_has "$output_file" 'Blobs([[:space:]]+Database|[[:space:]]+DB)[[:space:]]+is[[:space:]]+OK' && blobs_ok=1
    output_has "$output_file" 'damaged|malformed|corrupt|requires repair' && damage=1
    output_has "$output_file" 'FTS.*(damaged|corrupt)|search index.*(damaged|corrupt)' && fts=1
    output_has "$output_file" 'is[[:space:]]+bloated|database bloat|[1-9][0-9]*(\.[0-9]+)?% fragmented|requires.*(deflate|optimization)' && bloat=1
    output_has "$output_file" 'ghost entr|NULL title' && ghost=1
    output_has "$output_file" 'orphan|not connected to their parent' && orphan=1
    output_has "$output_file" 'Swap complete|Live databases updated|Making DB.*active' && promoted=1
    output_has "$output_file" 'rebuild and verification complete' && rebuilt=1
    output_has "$output_file" 'unrecoverable|use .*Replace|cannot be repaired|unable to recover' && unrecoverable=1
    output_has "$output_file" 'revert.*(complete|successful|prior)|restor.*prior.*database|rollback.*(complete|successful)' && reverted=1
    output_has "$output_file" 'NOTICE|WARNING' && notices=1

    details="$(extract_notable_output "$output_file")"
    RESULT_DETAILS["$container"]="$details"
    RESULT_RC["$container"]="$rc"

    if (( unrecoverable == 1 )); then
        RESULT_CLASS["$container"]="UNRECOVERABLE"
        RESULT_FINDING["$container"]="Unrecoverable database corruption reported."
        RESULT_ACTION["$container"]="Verified replacement not confirmed. Manual recovery required: DBRepair Replace with a verified Plex database backup."
        RUN_HAS_ISSUE=1
        raise_severity alert
        return 0
    fi

    if (( rc != 0 )); then
        RESULT_CLASS["$container"]="FAILED"
        if (( rc == 124 )); then
            RESULT_FINDING["$container"]="Maintenance timeout exceeded (${DBREPAIR_TIMEOUT_SECONDS}s)."
        elif (( damage == 1 )); then
            RESULT_FINDING["$container"]="Database corruption reported; maintenance exited with code ${rc}."
        else
            RESULT_FINDING["$container"]="Automatic maintenance failed (exit code ${rc})."
        fi
        if (( promoted == 1 && reverted == 1 )); then
            RESULT_ACTION["$container"]="Database activation followed by reported rollback to prior databases. Verify rollback in DBRepair.log."
        elif (( promoted == 1 )); then
            RESULT_ACTION["$container"]="Database activation reported before failure; final database state unverified. Inspect DBRepair.log."
        else
            RESULT_ACTION["$container"]="Database replacement not reported. Service recovery status follows below."
        fi
        RUN_HAS_ISSUE=1
        raise_severity alert
        return 0
    fi

    if (( promoted == 1 && rebuilt == 1 )); then
        RESULT_CLASS["$container"]="REPAIRED"
        RESULT_FINDING["$container"]="Database rebuild and activation confirmed."
        [[ $fts -eq 0 ]] || RESULT_FINDING["$container"]+=" Search-index corruption detected."
        [[ $bloat -eq 0 ]] || RESULT_FINDING["$container"]+=" Fragmentation or database bloat detected."
        [[ $ghost -eq 0 ]] || RESULT_FINDING["$container"]+=" Ghost or invalid-title records detected."
        RESULT_ACTION["$container"]="Main and blobs databases rebuilt, verified, and activated."
        RUN_HAS_REPAIR=1
        CONTAINERS_REPAIRED=$((CONTAINERS_REPAIRED + 1))
        if (( notices == 1 || orphan == 1 )); then
            RESULT_CLASS["$container"]="WARNING"
            (( orphan == 0 )) || RESULT_FINDING["$container"]+=" Orphaned media records detected."
            RESULT_ACTION["$container"]+=" Additional findings require diagnostic review."
            RUN_HAS_ISSUE=1
            raise_severity warning
        fi
        return 0
    fi

    if (( main_ok == 1 && blobs_ok == 1 && damage == 0 )); then
        RESULT_CLASS["$container"]="HEALTHY"
        RESULT_FINDING["$container"]="Main OK; Blobs OK."
        RESULT_ACTION["$container"]="No repair required."
        CONTAINERS_HEALTHY=$((CONTAINERS_HEALTHY + 1))
        if (( notices == 1 || orphan == 1 )); then
            RESULT_CLASS["$container"]="WARNING"
            (( orphan == 0 )) || RESULT_FINDING["$container"]+=" Orphaned media records detected."
            RESULT_ACTION["$container"]="Advisory correction unverified; inspect diagnostics and DBRepair.log."
            RUN_HAS_ISSUE=1
            raise_severity warning
        fi
        return 0
    fi

    if (( damage == 1 )); then
        RESULT_CLASS["$container"]="WARNING"
        RESULT_FINDING["$container"]="Database damage detected; verified repair activation not confirmed."
        RESULT_ACTION["$container"]="Database replacement unverified. Inspect DBRepair.log before manual recovery."
    else
        RESULT_CLASS["$container"]="WARNING"
        RESULT_FINDING["$container"]="Exit code 0; database verification outcome unrecognized."
        RESULT_ACTION["$container"]="Database changes unverified. Inspect DBRepair.log."
    fi
    RUN_HAS_ISSUE=1
    raise_severity warning
}

###############################################################################
# CONTAINER PROCESSING
###############################################################################

execute_dbrepair() {
    local container="$1" output_file="$2"
    timeout --signal=TERM --kill-after=60 "$DBREPAIR_TIMEOUT_SECONDS" \
        docker exec -u 0 -i -w "$DBREPAIR_INSTALL_DIR" \
        "$container" "$DBREPAIR_PATH" "${DBREPAIR_ARGS[@]}" \
        2>&1 | tee -a "$LOG_FILE" "$output_file"
    return "${PIPESTATUS[0]}"
}

restore_container_state() {
    local container="$1" originally_running="$2" class
    class="${RESULT_CLASS[$container]:-FAILED}"

    if [[ "$originally_running" == false ]]; then
        if container_is_running "$container"; then
            log INFO "[$container] Restoring original stopped container state"
            if ! docker stop -t 30 "$container" >/dev/null 2>&1 ||
               container_is_running "$container"; then
                RESULT_FINAL_STATE["$container"]="Original stopped state not restored; container stop failed or container remains running."
                RESULT_CLASS["$container"]="FAILED"
                RUN_HAS_ISSUE=1
                raise_severity alert
                return 1
            fi
        fi
        RESULT_FINAL_STATE["$container"]="Container stopped; original state restored."
        return 0
    fi

    if ! container_is_running "$container"; then
        warn "[$container] Container stopped unexpectedly; attempting recovery start"
        if docker start "$container" >/dev/null 2>&1 &&
           wait_container_running "$container"; then
            CONTAINERS_RECOVERED=$((CONTAINERS_RECOVERED + 1))
            RESULT_ACTION["$container"]+=" Recovery start completed for stopped container."
        else
            RESULT_FINAL_STATE["$container"]="Container running state unconfirmed; recovery start failed."
            RESULT_CLASS["$container"]="FAILED"
            RUN_HAS_ISSUE=1
            raise_severity alert
            return 1
        fi
    fi

    if wait_plex_process "$container"; then
        RESULT_FINAL_STATE["$container"]="Container running; server process detected."
        return 0
    fi

    warn "[$container] Plex process was not detected; restarting the Docker container once"
    if docker restart -t 30 "$container" >/dev/null 2>&1 &&
       wait_container_running "$container" &&
       wait_plex_process "$container"; then
        CONTAINERS_RECOVERED=$((CONTAINERS_RECOVERED + 1))
        RESULT_ACTION["$container"]+=" Recovery restart completed."
        RESULT_FINAL_STATE["$container"]="Container running; server process detected after recovery restart."
        [[ "$class" == HEALTHY || "$class" == REPAIRED ]] && \
            RESULT_CLASS["$container"]="WARNING"
        RUN_HAS_ISSUE=1
        raise_severity warning
        return 0
    fi

    RESULT_FINAL_STATE["$container"]="Recovery failed to confirm both container running state and server process."
    RESULT_CLASS["$container"]="FAILED"
    RUN_HAS_ISSUE=1
    raise_severity alert
    return 1
}

process_container() {
    local container="$1" originally_running=false output_file rc=1
    local safe_container

    RESULT_ORDER+=("$container")
    RESULT_CLASS["$container"]="FAILED"
    RESULT_FINDING["$container"]="Container workflow incomplete."
    RESULT_ACTION["$container"]="Database operations unconfirmed."
    RESULT_FINAL_STATE["$container"]="Not evaluated."
    RESULT_VERSION["$container"]="unknown"
    RESULT_RC["$container"]="not-run"
    RESULT_DETAILS["$container"]=""
    RESULT_UPDATE["$container"]=""

    log INFO "[$container] Starting DBRepair workflow"
    if ! container_exists "$container"; then
        RESULT_FINDING["$container"]="Configured Docker container not found."
        RESULT_ACTION["$container"]="Maintenance skipped. Correct CONTAINERS configuration."
        RESULT_FINAL_STATE["$container"]="Container not found."
        CONTAINERS_FAILED=$((CONTAINERS_FAILED + 1))
        RUN_HAS_ISSUE=1
        raise_severity alert
        error "[$container] Configured container was not found"
        return 1
    fi
    CONTAINERS_PROCESSED=$((CONTAINERS_PROCESSED + 1))

    container_is_running "$container" && originally_running=true
    if [[ "$originally_running" == false ]]; then
        log INFO "[$container] Container was stopped; starting it temporarily"
        if ! docker start "$container" >/dev/null 2>&1 ||
           ! wait_container_running "$container" ||
           ! wait_plex_process "$container"; then
            RESULT_FINDING["$container"]="Temporary startup failed container or server-process verification."
            RESULT_ACTION["$container"]="Maintenance skipped; container stop requested."
            RESULT_FINAL_STATE["$container"]="Startup verification failed; final stopped state unverified."
            docker stop -t 30 "$container" >/dev/null 2>&1 || true
            CONTAINERS_FAILED=$((CONTAINERS_FAILED + 1))
            RUN_HAS_ISSUE=1
            raise_severity alert
            error "[$container] Could not start Plex temporarily"
            return 1
        fi
        CONTAINERS_TEMP_STARTED=$((CONTAINERS_TEMP_STARTED + 1))
    fi

    if ! install_or_resolve_dbrepair "$container"; then
        RESULT_FINDING["$container"]="Validated DBRepair executable unavailable."
        RESULT_ACTION["$container"]="Maintenance skipped; legacy DBRepair.sh execution disabled."
        RESULT_FINAL_STATE["$container"]="Container state restoration pending."
        restore_container_state "$container" "$originally_running" || true
        CONTAINERS_FAILED=$((CONTAINERS_FAILED + 1))
        RUN_HAS_ISSUE=1
        raise_severity alert
        error "[$container] No usable current DBRepair executable"
        return 1
    fi

    safe_container="$(safe_name "$container")"
    output_file="${RUNTIME_DIR}/${safe_container}.output.log"
    : >"$output_file"
    log INFO "[$container] Running DBRepair ${RESULT_VERSION[$container]}: ${DBREPAIR_ARGS[*]}"
    execute_dbrepair "$container" "$output_file"
    rc=$?
    classify_container_output "$container" "$output_file" "$rc"
    if (( rc == 124 )); then
        warn "[$container] DBRepair timed out; restarting the Docker container to terminate the maintenance process safely"
        if docker restart -t 30 "$container" >/dev/null 2>&1 &&
           wait_container_running "$container"; then
            CONTAINERS_RECOVERED=$((CONTAINERS_RECOVERED + 1))
            RESULT_ACTION["$container"]+=" Container restarted to terminate timed-out maintenance."
        else
            RESULT_ACTION["$container"]+=" Post-timeout container restart failed."
        fi
    fi
    restore_container_state "$container" "$originally_running" || true

    case "${RESULT_CLASS[$container]}" in
        FAILED|UNRECOVERABLE)
            CONTAINERS_FAILED=$((CONTAINERS_FAILED + 1))
            error "[$container] Completed with ${RESULT_CLASS[$container]} (exit $rc)"
            return 1
            ;;
        *)
            CONTAINERS_SUCCESSFUL=$((CONTAINERS_SUCCESSFUL + 1))
            log INFO "[$container] Completed with ${RESULT_CLASS[$container]} (exit $rc)"
            return 0
            ;;
    esac
}

###############################################################################
# RUN REPORT AND NOTIFICATIONS
###############################################################################

build_summary_text() {
    local include_report_path="${1:-true}" container details text=""

    text+="Release verification: ${UPDATE_DETAIL}"$'\n'
    text+="Containers: ${#CONTAINERS[@]} configured; ${CONTAINERS_SUCCESSFUL} successful; ${CONTAINERS_FAILED} failed; ${CONTAINERS_REPAIRED} repaired; ${CONTAINERS_HEALTHY} healthy."$'\n\n'
    for container in "${RESULT_ORDER[@]}"; do
        text+="[${container}] ${RESULT_CLASS[$container]}"$'\n'
        text+="Database checks: ${RESULT_FINDING[$container]}"$'\n'
        text+="Maintenance: ${RESULT_ACTION[$container]}"$'\n'
        text+="Plex status: ${RESULT_FINAL_STATE[$container]}"$'\n'
        text+="DBRepair: ${RESULT_VERSION[$container]}; exit code: ${RESULT_RC[$container]}"$'\n'
        text+="Deployment: ${RESULT_UPDATE[$container]:-Not attempted.}"$'\n'
        details="${RESULT_DETAILS[$container]}"
        if [[ -n "$details" ]]; then
            text+="Diagnostics:"$'\n'"${details}"$'\n'
        fi
        text+="Container log: ${DBREPAIR_INSTALL_DIR}/DBRepair.log"$'\n\n'
    done
    text+="Wrapper log: ${LOG_FILE}"$'\n'
    if [[ "$include_report_path" == true && -n "$RUN_REPORT_FILE" ]]; then
        text+="Run report: ${RUN_REPORT_FILE}"$'\n'
    fi
    printf '%s' "$text"
}

write_run_report() {
    local tmp
    mkdir -p -- "$REPORT_DIR" || return 1
    RUN_REPORT_FILE="${REPORT_DIR}/dbrepair-${RUN_STAMP}.txt"
    tmp="$(mktemp "${REPORT_DIR}/.dbrepair-report.XXXXXX")" || return 1
    {
        printf 'Plex DBRepair run report\n'
        printf 'Started epoch: %s\n' "$START_EPOCH"
        printf 'Finished: %s\n' "$(timestamp)"
        printf 'Wrapper version: %s\n' "$VERSION"
        printf 'Duration: %s\n\n' "$(human_duration "$(($(date +%s) - START_EPOCH))")"
        build_summary_text false
    } >"$tmp" || {
        rm -f -- "$tmp"
        return 1
    }
    mv -f -- "$tmp" "$RUN_REPORT_FILE"
}

initialize_notification_state() {
    local tmp
    if [[ -f "$NOTIFICATION_STATE_FILE" ]] &&
       jq -e 'type == "object" and ((.attention // {}) | type == "object")' \
       "$NOTIFICATION_STATE_FILE" >/dev/null 2>&1; then
        return 0
    fi
    tmp="$(mktemp "${LOG_DIR}/.notification-state.XXXXXX")" || return 1
    printf '%s\n' '{"version":1,"attention":{}}' >"$tmp" || return 1
    mv -f -- "$tmp" "$NOTIFICATION_STATE_FILE"
}

issue_signature_text() {
    local container text=""
    text+="$GLOBAL_ISSUE_KEY"
    [[ "$UPDATE_STATE" == verified-latest ]] || text+="update:${UPDATE_STATE};"
    for container in "${RESULT_ORDER[@]}"; do
        case "${RESULT_CLASS[$container]}" in
            HEALTHY|REPAIRED) ;;
            *) text+="${container}:${RESULT_CLASS[$container]}:${RESULT_RC[$container]};" ;;
        esac
    done
    printf '%s' "$text"
}

save_attention_state() {
    local signature="$1" severity="$2" notified_epoch="$3"
    local now tmp previous_raised previous_signature
    now="$(date +%s)"
    previous_signature="$(jq -r '.attention.signature // ""' "$NOTIFICATION_STATE_FILE")"
    previous_raised="$(jq -r '.attention.raisedEpoch // 0' "$NOTIFICATION_STATE_FILE")"
    [[ "$previous_raised" =~ ^[0-9]+$ ]] || previous_raised=0
    [[ "$previous_signature" == "$signature" ]] || previous_raised=0
    (( previous_raised > 0 )) || previous_raised="$now"
    tmp="$(mktemp "${LOG_DIR}/.notification-state.XXXXXX")" || return 1
    jq \
        --arg signature "$signature" \
        --arg severity "$severity" \
        --argjson raised "$previous_raised" \
        --argjson seen "$now" \
        --argjson notified "$notified_epoch" '
        .version = 1
        | .attention = {
            signature: $signature,
            severity: $severity,
            raisedEpoch: $raised,
            lastSeenEpoch: $seen,
            lastNotifiedEpoch: $notified
          }
    ' "$NOTIFICATION_STATE_FILE" >"$tmp" || {
        rm -f -- "$tmp"
        return 1
    }
    mv -f -- "$tmp" "$NOTIFICATION_STATE_FILE"
}

clear_attention_state() {
    local tmp
    tmp="$(mktemp "${LOG_DIR}/.notification-state.XXXXXX")" || return 1
    jq '.version = 1 | .attention = {}' "$NOTIFICATION_STATE_FILE" >"$tmp" || {
        rm -f -- "$tmp"
        return 1
    }
    mv -f -- "$tmp" "$NOTIFICATION_STATE_FILE"
}

update_notifications() {
    local signature_text signature="" previous_signature previous_severity
    local last_notified=0 now description body should_notify=0 previous_active=0
    now="$(date +%s)"
    signature_text="$(issue_signature_text)"
    [[ -z "$signature_text" ]] || \
        signature="$(printf '%s' "$signature_text" | sha256sum | awk '{print $1}')"
    previous_signature="$(jq -r '.attention.signature // ""' "$NOTIFICATION_STATE_FILE")"
    previous_severity="$(jq -r '.attention.severity // ""' "$NOTIFICATION_STATE_FILE")"
    last_notified="$(jq -r '.attention.lastNotifiedEpoch // 0' "$NOTIFICATION_STATE_FILE")"
    [[ "$last_notified" =~ ^[0-9]+$ ]] || last_notified=0
    [[ -n "$previous_signature" ]] && previous_active=1

    if [[ -n "$signature" ]]; then
        if [[ "$signature" != "$previous_signature" ||
              "$RUN_HIGHEST_SEVERITY" != "$previous_severity" ]] ||
           (( now - last_notified >= NOTIFICATION_REMINDER_DAYS * 86400 )) ||
           (( RUN_HAS_REPAIR == 1 )); then
            should_notify=1
        fi
        if (( should_notify == 1 )); then
            case "$RUN_HIGHEST_SEVERITY" in
                alert) description="DBRepair FAILED - operator action required" ;;
                *) description="DBRepair WARNING - diagnostic review required" ;;
            esac
            body="$(build_summary_text true)"
            notify_unraid "$RUN_HIGHEST_SEVERITY" "$description" "$body" || true
            if ! save_attention_state "$signature" "$RUN_HIGHEST_SEVERITY" "$now"; then
                error "DBRepair notification state could not be saved"
                NOTIFICATION_FAILED=1
            fi
        else
            log INFO "Unchanged DBRepair warning notification suppressed until reminder interval"
            if ! save_attention_state "$signature" "$RUN_HIGHEST_SEVERITY" "$last_notified"; then
                error "DBRepair notification state could not be saved"
                NOTIFICATION_FAILED=1
            fi
        fi
        return 0
    fi

    if (( RUN_HAS_REPAIR == 1 )); then
        body="$(build_summary_text true)"
        notify_unraid normal "DBRepair REPAIRED - database activation verified" "$body" || true
    elif (( previous_active == 1 )); then
        body="Recovery: Previously reported DBRepair conditions are no longer detected."$'\n\n'"$(build_summary_text true)"
        notify_unraid normal "DBRepair RESOLVED - no active conditions detected" "$body" || true
    else
        log INFO "All Plex databases were healthy; routine notification suppressed"
    fi
    if ! clear_attention_state; then
        error "DBRepair notification state could not be cleared"
        NOTIFICATION_FAILED=1
    fi
}

###############################################################################
# MAIN
###############################################################################

main() {
    local container final_status="OK" final_summary
    umask 022
    trap cleanup EXIT

    if ! mkdir -p -- "$LOG_DIR"; then
        printf '%s [ERROR] [DBREPAIR] Unable to create log directory: %s\n' \
            "$(timestamp)" "$LOG_DIR" >&2
        return 1
    fi
    rotate_log
    touch "$LOG_FILE" || return 1

    if ! require_commands; then
        notify_unraid alert "DBRepair STARTUP FAILED - missing dependencies" \
            "Validation: Required commands unavailable. Maintenance: Not started. Action: Install missing dependencies listed in $LOG_FILE." || true
        write_status_receipt FAILED "Required command validation failed"
        return 1
    fi
    if ! validate_configuration; then
        notify_unraid alert "DBRepair STARTUP FAILED - configuration or Docker" \
            "Validation: Configuration or Docker service check failed. Maintenance: Not started. Action: Inspect $LOG_FILE and correct configuration or restore Docker service." || true
        write_status_receipt FAILED "Configuration or Docker validation failed"
        return 1
    fi
    acquire_lock || return 0

    RUNTIME_DIR="$(mktemp -d /tmp/plex_dbrepair.XXXXXX)" || return 1
    cleanup_legacy_logs
    prune_reports || warn "Old DBRepair reports could not be pruned"
    initialize_notification_state || {
        error "Notification state could not be initialized"
        notify_unraid alert "DBRepair STARTUP FAILED - notification state" \
            "State initialization: Failed. Maintenance: Not started. Action: Check storage availability and permissions for $NOTIFICATION_STATE_FILE. Log: $LOG_FILE" || true
        return 1
    }

    log INFO "===== Plex DBRepair Scheduler START v${VERSION} ====="
    log INFO "Configured containers: ${CONTAINERS[*]}"
    prepare_latest_release || release_fallback "Unexpected release preparation failure"

    for container in "${CONTAINERS[@]}"; do
        process_container "$container" || true
    done

    if ! write_run_report; then
        error "Structured DBRepair run report could not be written"
        RUN_REPORT_FILE=""
        RUN_HAS_ISSUE=1
        GLOBAL_ISSUE_KEY+="report-write-failed;"
        raise_severity alert
    fi
    update_notifications || true

    final_summary="processed=${CONTAINERS_PROCESSED} successful=${CONTAINERS_SUCCESSFUL} failed=${CONTAINERS_FAILED} repaired=${CONTAINERS_REPAIRED} healthy=${CONTAINERS_HEALTHY} updated=${CONTAINERS_UPDATED} temporarily_started=${CONTAINERS_TEMP_STARTED} recovered=${CONTAINERS_RECOVERED} warnings=${WARNING_COUNT} errors=${ERROR_COUNT}"
    if (( CONTAINERS_FAILED > 0 || ERROR_COUNT > 0 || NOTIFICATION_FAILED > 0 )); then
        final_status="FAILED"
        log ERROR "Run summary: $final_summary"
        log ERROR "===== Plex DBRepair Scheduler COMPLETE WITH ERRORS ====="
        write_status_receipt "$final_status" "$final_summary"
        return 1
    fi
    if (( RUN_HAS_ISSUE > 0 || WARNING_COUNT > 0 )); then
        final_status="WARNING"
        log WARN "Run summary: $final_summary"
        log WARN "===== Plex DBRepair Scheduler COMPLETE WITH WARNINGS ====="
    else
        log INFO "Run summary: $final_summary"
        log INFO "===== Plex DBRepair Scheduler COMPLETE ====="
    fi
    write_status_receipt "$final_status" "$final_summary"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
