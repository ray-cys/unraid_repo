#!/bin/bash

###############################################################################
# Remote NAS Backup v2
#
# PURPOSE
# -------
# Mirror selected local Unraid shares to a remote Unraid server using rsync.
#
# Workflow:
#
#   1. Validate local configuration and source paths
#   2. Wake the remote NAS using Wake-on-LAN
#   3. Wait for SSH availability
#   4. Confirm the remote /mnt/user filesystem is actually mounted
#   5. Confirm configured remote destination directories exist
#   6. Estimate changed data and verify aggregate remote free space
#   7. Rsync each configured backup job serially
#   8. Retry eligible failures with exponential backoff
#   9. Collect transfer statistics and preserve raw rsync logs
#  10. Optionally shut down the remote NAS
#  11. Send one consolidated Unraid notification
#  12. Prune old logs
#
#
# SAFETY
# ------
# - The remote backup is a MIRROR.
# - Files removed from the source may also be removed from the destination.
# - Deletions use --delete-delay so removals occur after the transfer phase.
# - Remote /mnt/user MUST be confirmed mounted before any rsync is allowed.
# - Remote destination directories are NEVER auto-created.
# - A failed preflight prevents rsync from starting.
# - Backup failures return a non-zero script exit status.
#
#
# SCHEDULING
# ----------
# Scheduling is managed externally by Unraid User Scripts.
# This script does not create or modify its own schedule.
#
###############################################################################

set -uo pipefail


###############################################################################
# CONFIGURATION
###############################################################################

# ---------------------------------------------------------------------------
# Identification
# ---------------------------------------------------------------------------

SRC_NAS="Hubble NAS"
DEST_NAS="ISS NAS"


# ---------------------------------------------------------------------------
# Remote NAS / SSH
# ---------------------------------------------------------------------------

REMOTE="root@192.168.50.3"
REMOTE_MAC="9C:6B:00:4B:BB:EE"

SSH_PORT=22
SSH_CONNECT_TIMEOUT=5


# ---------------------------------------------------------------------------
# Wake-on-LAN
# ---------------------------------------------------------------------------

ENABLE_WOL=true


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

LOG_DIR="/mnt/user/cloud/logs/remote_logs"
RAW_LOG_DIR="${LOG_DIR}/rsync_raw"

MAX_LOGS=2
MAX_RAW_LOGS=2


# ---------------------------------------------------------------------------
# Backup jobs
# ---------------------------------------------------------------------------

# Format:
#
#   "Label|Local source|Remote destination|Comma-separated excludes|Bandwidth"
#
# Bandwidth is in KiB/s.
#
#   0 = unlimited
#
# Examples:
#
#   20480 = approximately 20 MiB/s
#
# Paths can contain spaces.
#
BACKUP_JOBS=(
    "Media|/mnt/user/media|/mnt/user/media|/net/|0"
    "Secure|/mnt/user/secure|/mnt/user/secure|/torrent/|0"
)


# ---------------------------------------------------------------------------
# Rsync
# ---------------------------------------------------------------------------

# NOTE:
#
# --delete-delay means this remains a MIRROR backup.
# Files deleted from the source can also be deleted from the destination.
#
# -a already includes:
#
#   recursion
#   permissions
#   timestamps
#   symlinks
#   ownership/group preservation
#
RSYNC_BASE_ARGS=(
    "-aH"
    "--delete-delay"
    "--partial"
    "--partial-dir=.rsync-partial"
    "--protect-args"
    "--stats"
)

# Default exclusions applied to every backup job.
#
DEFAULT_EXCLUDES=(
    "--exclude=*.sock"
    "--exclude=*/.cache/*"
)

# Include rsync itemized file changes in the run log.
#
LOG_ITEMIZED_CHANGES=true


# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------

# true:
#   Rsync performs a complete comparison but does not modify the destination.
#
# false:
#   Normal live backup.
#
DRY_RUN=false


# ---------------------------------------------------------------------------
# Retry / backoff
# ---------------------------------------------------------------------------

# Total rsync attempts per backup job.
#
MAX_RETRIES=3

# Initial retry delay in seconds.
#
RETRY_BACKOFF=30

# Exponential delays:
#
#   Attempt 1 failure -> 30s
#   Attempt 2 failure -> 60s
#   Attempt 3 failure -> stop
#
ENABLE_EXPONENTIAL_BACKOFF=true

MAX_BACKOFF=600

# Rsync exit codes eligible for retry.
#
# 255 represents SSH failure. Permanent SSH failures such as authentication or
# host-key errors are detected separately and are not repeatedly retried.
#
RETRY_CODES=(
    10
    11
    12
    20
    23
    24
    30
    255
)


# ---------------------------------------------------------------------------
# Process priority
# ---------------------------------------------------------------------------

USE_LOW_PRIORITY_IO=true

IONICE_CLASS=2
IONICE_PRIORITY=7
NICE_LEVEL=10


# ---------------------------------------------------------------------------
# Remote-space preflight
# ---------------------------------------------------------------------------

# estimate:
#   Perform an rsync --dry-run and use "Total transferred file size".
#
# total:
#   Conservatively assume the entire local source needs to fit.
#
PREFLIGHT_MODE="estimate"

# Minimum free-space safety buffer.
#
# 1 GiB:
#
PREFLIGHT_MIN_BUFFER_BYTES=1073741824

# Additional buffer as percentage of estimated changed bytes.
#
# The larger of:
#
#   PREFLIGHT_MIN_BUFFER_BYTES
#
# or:
#
#   estimated transfer × PREFLIGHT_BUFFER_PERCENT
#
# is used.
#
PREFLIGHT_BUFFER_PERCENT=5

REMOTE_DF_RETRIES=3
REMOTE_DF_RETRY_SLEEP=3


# ---------------------------------------------------------------------------
# Remote readiness
# ---------------------------------------------------------------------------

# Maximum time to wait for SSH after Wake-on-LAN.
#
MAX_SSH_WAIT=420
SSH_WAIT_INTERVAL=20

# Once SSH is available, maximum time to wait for /mnt/user to become mounted.
#
ARRAY_READY_WAIT=180
ARRAY_READY_INTERVAL=6


# ---------------------------------------------------------------------------
# Remote shutdown
# ---------------------------------------------------------------------------

# Current behavior is retained:
#
# Successful backup -> shut remote NAS down.
#
SHUTDOWN_REMOTE_ON_SUCCESS=true

# Failed backup -> leave remote NAS running unless explicitly enabled.
#
SHUTDOWN_REMOTE_ON_FAILURE=false


# ---------------------------------------------------------------------------
# Notification
# ---------------------------------------------------------------------------

NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
NOTIFY_SUBJECT="Remote Backup"

NOTIFY_EXCERPT_LINES=8


# ---------------------------------------------------------------------------
# Lock
# ---------------------------------------------------------------------------

LOCK_FILE="/tmp/remote_backup.lock"


###############################################################################
# RUNTIME STATE
#
# Internal values below this point should not normally be modified.
###############################################################################

RUN_STAMP="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE="${LOG_DIR}/remote_backup_${RUN_STAMP}.log"

START_TIME=0

REMOTE_READY=0

REMOTE_WAIT_ERROR=""
REMOTE_VALIDATION_ERROR=""
PREFLIGHT_FAILURE_DETAIL=""

REMOTE_SHUTDOWN_REQUESTED=0
REMOTE_SHUTDOWN_FAILED=0

declare -a PRIORITY_PREFIX=()
declare -a FAILED_LABELS=()

declare -A RESULT_CODE=()
declare -A RESULT_REASON=()

declare -A TOTAL_BYTES=()
declare -A TRANSFERRED_BYTES=()
declare -A FILES_TRANSFERRED=()
declare -A DELETED_FILES=()
declare -A BYTES_SENT=()

declare -A ESTIMATED_BYTES=()
declare -A RAW_LOG_BY_LABEL=()

declare -A DEST_FREE_BYTES=()


###############################################################################
# LOCKING
###############################################################################

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    printf '%s %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "Another remote_backup.sh run is active, exiting (lock: $LOCK_FILE)"

    exit 1
fi


###############################################################################
# GENERIC HELPERS
###############################################################################

ensure_dir() {
    local path="$1"

    if [ -d "$path" ]; then
        return 0
    fi

    mkdir -p -- "$path"
}


log() {
    local category="$1"
    local level="$2"
    shift 2

    local message="$*"

    printf '%s [%s][%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$category" \
        "$level" \
        "$message" |
        tee -a "$LOG_FILE"
}


notify_unraid() {
    local importance="$1"
    local description="$2"
    local message="$3"

    if [ ! -x "$NOTIFY_BIN" ]; then
        log "NOTIFY" "WARN" \
            "Unraid notification helper unavailable: $NOTIFY_BIN"

        return 0
    fi

    if ! "$NOTIFY_BIN" \
        -i "$importance" \
        -b \
        -s "$NOTIFY_SUBJECT" \
        -d "$description" \
        -m "$message"
    then
        log "NOTIFY" "WARN" \
            "Failed to send Unraid notification"
    fi
}


bytes_to_human() {
    local bytes="${1:-0}"

    awk -v b="$bytes" '
        BEGIN {
            unit[0]="B"
            unit[1]="KB"
            unit[2]="MB"
            unit[3]="GB"
            unit[4]="TB"
            unit[5]="PB"

            i=0

            while (b >= 1024 && i < 5) {
                b=b/1024
                i++
            }

            if (b >= 100)
                printf "%.0f%s", b, unit[i]
            else
                printf "%.1f%s", b, unit[i]
        }
    '
}


format_duration() {
    local seconds="${1:-0}"

    printf '%dh:%02dm:%02ds' \
        $((seconds / 3600)) \
        $(((seconds % 3600) / 60)) \
        $((seconds % 60))
}


safe_size_bytes() {
    local path="$1"
    local size=""
    local blocks=""

    size="$(
        du -sb -- "$path" 2>/dev/null |
            awk 'NR == 1 {print $1}'
    )"

    if [[ "$size" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$size"
        return 0
    fi

    blocks="$(
        du -sk -- "$path" 2>/dev/null |
            awk 'NR == 1 {print $1}'
    )"

    if [[ "$blocks" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$((blocks * 1024))"
        return 0
    fi

    printf '0\n'
    return 1
}


safe_name() {
    local name="$1"

    printf '%s' "$name" |
        tr ' ' '_' |
        tr -cs '[:alnum:]_.-' '_'
}


array_contains() {
    local needle="$1"
    shift

    local value=""

    for value in "$@"; do
        if [ "$value" = "$needle" ]; then
            return 0
        fi
    done

    return 1
}


###############################################################################
# CONFIGURATION VALIDATION
###############################################################################

validate_configuration() {
    local descriptor=""
    local label=""
    local src=""
    local dest=""
    local extra_excludes=""
    local bwlimit=""

    local -A seen_labels=()

    if ! command -v rsync >/dev/null 2>&1; then
        log "PREFLIGHT" "ERROR" "rsync is not available"
        return 1
    fi

    if ! command -v ssh >/dev/null 2>&1; then
        log "PREFLIGHT" "ERROR" "ssh is not available"
        return 1
    fi

    if [ "${#BACKUP_JOBS[@]}" -eq 0 ]; then
        log "PREFLIGHT" "ERROR" "No backup jobs are configured"
        return 1
    fi

    case "$PREFLIGHT_MODE" in
        estimate|total)
            ;;
        *)
            log "PREFLIGHT" "ERROR" \
                "PREFLIGHT_MODE must be 'estimate' or 'total'"
            return 1
            ;;
    esac

    if ! [[ "$MAX_RETRIES" =~ ^[0-9]+$ ]] ||
       [ "$MAX_RETRIES" -lt 1 ]
    then
        log "PREFLIGHT" "ERROR" \
            "MAX_RETRIES must be an integer >= 1"
        return 1
    fi

    if ! [[ "$RETRY_BACKOFF" =~ ^[0-9]+$ ]] ||
       ! [[ "$MAX_BACKOFF" =~ ^[0-9]+$ ]]
    then
        log "PREFLIGHT" "ERROR" \
            "Retry backoff values must be non-negative integers"
        return 1
    fi

    if ! [[ "$PREFLIGHT_MIN_BUFFER_BYTES" =~ ^[0-9]+$ ]] ||
       ! [[ "$PREFLIGHT_BUFFER_PERCENT" =~ ^[0-9]+$ ]]
    then
        log "PREFLIGHT" "ERROR" \
            "Preflight buffer settings must be non-negative integers"
        return 1
    fi

    if ! [[ "$REMOTE_DF_RETRIES" =~ ^[0-9]+$ ]] ||
       [ "$REMOTE_DF_RETRIES" -lt 1 ]
    then
        log "PREFLIGHT" "ERROR" \
            "REMOTE_DF_RETRIES must be an integer >= 1"
        return 1
    fi

    for descriptor in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r \
            label \
            src \
            dest \
            extra_excludes \
            bwlimit \
            <<<"$descriptor"

        if [ -z "$label" ] ||
           [ -z "$src" ] ||
           [ -z "$dest" ]
        then
            log "PREFLIGHT" "ERROR" \
                "Invalid backup descriptor: $descriptor"
            return 1
        fi

        if [ -n "${seen_labels[$label]:-}" ]; then
            log "PREFLIGHT" "ERROR" \
                "Duplicate backup label: $label"
            return 1
        fi

        seen_labels["$label"]=1

        if [ ! -d "$src" ]; then
            log "PREFLIGHT" "ERROR" \
                "Local source does not exist for ${label}: $src"
            return 1
        fi

        bwlimit="${bwlimit:-0}"

        if ! [[ "$bwlimit" =~ ^[0-9]+$ ]]; then
            log "PREFLIGHT" "ERROR" \
                "Invalid bandwidth limit for ${label}: $bwlimit"
            return 1
        fi
    done

    return 0
}


build_priority_prefix() {
    PRIORITY_PREFIX=()

    if [ "$USE_LOW_PRIORITY_IO" != "true" ]; then
        return 0
    fi

    if command -v ionice >/dev/null 2>&1; then
        PRIORITY_PREFIX+=(
            ionice
            "-c${IONICE_CLASS}"
            "-n${IONICE_PRIORITY}"
        )
    fi

    if command -v nice >/dev/null 2>&1; then
        PRIORITY_PREFIX+=(
            nice
            -n "$NICE_LEVEL"
        )
    fi
}


###############################################################################
# SSH HELPERS
###############################################################################

ssh_run() {
    local command_string=""

    printf -v command_string '%q ' "$@"

    ssh \
        -o BatchMode=yes \
        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
        -p "$SSH_PORT" \
        "$REMOTE" \
        "$command_string"
}


ssh_raw() {
    local command_string="$1"

    ssh \
        -o BatchMode=yes \
        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
        -p "$SSH_PORT" \
        "$REMOTE" \
        "$command_string"
}


classify_ssh_error() {
    local stderr="$1"
    local lower=""

    lower="$(
        printf '%s' "$stderr" |
            tr '[:upper:]' '[:lower:]'
    )"

    if printf '%s' "$lower" |
        grep -q 'permission denied'
    then
        printf 'Permission denied (authentication failed)'

    elif printf '%s' "$lower" |
        grep -q 'host key verification failed'
    then
        printf 'Host key verification failed'

    elif printf '%s' "$lower" |
        grep -q 'remote host identification has changed'
    then
        printf 'Remote host key changed'

    elif printf '%s' "$lower" |
        grep -q 'authenticity of host'
    then
        printf 'Host key is not trusted'

    elif printf '%s' "$lower" |
        grep -q 'connection refused'
    then
        printf 'Connection refused'

    elif printf '%s' "$lower" |
        grep -q 'no route to host'
    then
        printf 'No route to host'

    elif printf '%s' "$lower" |
        grep -q 'connection timed out'
    then
        printf 'Connection timed out'

    elif printf '%s' "$lower" |
        grep -q 'could not resolve hostname'
    then
        printf 'Hostname resolution failed'

    elif printf '%s' "$lower" |
        grep -q 'too many authentication failures'
    then
        printf 'Too many authentication failures'

    else
        printf 'SSH connection failure'
    fi
}


is_permanent_ssh_error() {
    local stderr="$1"
    local lower=""

    lower="$(
        printf '%s' "$stderr" |
            tr '[:upper:]' '[:lower:]'
    )"

    printf '%s' "$lower" |
        grep -Eq \
            'permission denied|host key verification failed|remote host identification has changed|authenticity of host|too many authentication failures'
}


###############################################################################
# WAKE / REMOTE READINESS
###############################################################################

wake_remote() {
    if [ "$ENABLE_WOL" != "true" ]; then
        log "REMOTE" "INFO" "Wake-on-LAN disabled"
        return 0
    fi

    if command -v etherwake >/dev/null 2>&1; then
        if etherwake "$REMOTE_MAC" >/dev/null 2>&1; then
            log "REMOTE" "INFO" \
                "Wake-on-LAN sent to ${DEST_NAS} (${REMOTE_MAC})"
        else
            log "REMOTE" "WARN" \
                "etherwake failed for ${REMOTE_MAC}; continuing with readiness checks"
        fi

    elif command -v wakeonlan >/dev/null 2>&1; then
        if wakeonlan "$REMOTE_MAC" >/dev/null 2>&1; then
            log "REMOTE" "INFO" \
                "Wake-on-LAN sent to ${DEST_NAS} (${REMOTE_MAC})"
        else
            log "REMOTE" "WARN" \
                "wakeonlan failed for ${REMOTE_MAC}; continuing with readiness checks"
        fi

    else
        log "REMOTE" "WARN" \
            "No Wake-on-LAN utility available; continuing without WOL"
    fi
}


remote_array_ready() {
    ssh_raw \
        'mountpoint -q /mnt/user 2>/dev/null || grep -qsE "[[:space:]]/mnt/user[[:space:]]" /proc/mounts'
}


wait_for_remote_ready() {
    local start=0
    local elapsed=0
    local array_start=0
    local ssh_error=""

    start="$(date +%s)"

    log "REMOTE" "INFO" \
        "Waiting up to ${MAX_SSH_WAIT}s for ${DEST_NAS} SSH"

    while :; do
        ssh_error=""

        if ssh_error="$(ssh_run true 2>&1)"; then
            elapsed=$(($(date +%s) - start))

            log "REMOTE" "INFO" \
                "SSH reachable after ${elapsed}s"

            break
        fi

        if is_permanent_ssh_error "$ssh_error"; then
            REMOTE_WAIT_ERROR="$(
                classify_ssh_error "$ssh_error"
            )"

            log "REMOTE" "ERROR" \
                "Permanent SSH failure: ${REMOTE_WAIT_ERROR}"

            return 1
        fi

        elapsed=$(($(date +%s) - start))

        if [ "$elapsed" -ge "$MAX_SSH_WAIT" ]; then
            REMOTE_WAIT_ERROR="$(
                classify_ssh_error "$ssh_error"
            )"

            log "REMOTE" "ERROR" \
                "SSH did not become reachable within ${MAX_SSH_WAIT}s"

            return 1
        fi

        sleep "$SSH_WAIT_INTERVAL"
    done

    array_start="$(date +%s)"

    log "REMOTE" "INFO" \
        "Waiting up to ${ARRAY_READY_WAIT}s for remote /mnt/user mount"

    while :; do
        if remote_array_ready >/dev/null 2>&1; then
            elapsed=$(($(date +%s) - array_start))

            log "REMOTE" "INFO" \
                "Remote /mnt/user confirmed mounted after ${elapsed}s"

            REMOTE_READY=1
            return 0
        fi

        elapsed=$(($(date +%s) - array_start))

        if [ "$elapsed" -ge "$ARRAY_READY_WAIT" ]; then
            REMOTE_WAIT_ERROR="Remote /mnt/user was not confirmed mounted"

            log "REMOTE" "ERROR" \
                "${REMOTE_WAIT_ERROR}; backup will NOT proceed"

            return 1
        fi

        sleep "$ARRAY_READY_INTERVAL"
    done
}


validate_remote_destinations() {
    local descriptor=""
    local label=""
    local src=""
    local dest=""
    local extra_excludes=""
    local bwlimit=""

    for descriptor in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r \
            label \
            src \
            dest \
            extra_excludes \
            bwlimit \
            <<<"$descriptor"

        if ! ssh_run test -d "$dest" >/dev/null 2>&1; then
            REMOTE_VALIDATION_ERROR="Remote destination missing for ${label}: ${dest}"

            log "REMOTE" "ERROR" \
                "$REMOTE_VALIDATION_ERROR"

            return 1
        fi

        log "REMOTE" "INFO" \
            "[${label}] destination confirmed: $dest"
    done

    return 0
}


###############################################################################
# RSYNC ARGUMENT CONSTRUCTION
###############################################################################

build_rsync_args() {
    local output_name="$1"
    local extra_excludes="$2"
    local bwlimit="${3:-0}"
    local mode="${4:-actual}"

    local -n output="$output_name"

    local pattern=""
    local -a extra_array=()

    local rsync_ssh_command="ssh -p ${SSH_PORT} -o BatchMode=yes -o ConnectTimeout=${SSH_CONNECT_TIMEOUT}"

    output=(
        "${RSYNC_BASE_ARGS[@]}"
        "${DEFAULT_EXCLUDES[@]}"
        -e "$rsync_ssh_command"
    )

    if [ -n "$extra_excludes" ]; then
        IFS=',' read -r -a extra_array <<<"$extra_excludes"

        for pattern in "${extra_array[@]}"; do
            [ -n "$pattern" ] || continue

            output+=(
                "--exclude=${pattern}"
            )
        done
    fi

    if [[ "$bwlimit" =~ ^[0-9]+$ ]] &&
       [ "$bwlimit" -gt 0 ]
    then
        output+=(
            "--bwlimit=${bwlimit}"
        )
    fi

    if [ "$mode" = "actual" ] &&
       [ "$LOG_ITEMIZED_CHANGES" = "true" ]
    then
        output+=(
            "--itemize-changes"
        )
    fi

    if [ "$mode" = "actual" ] &&
       [ "$DRY_RUN" = "true" ]
    then
        output+=(
            "--dry-run"
        )
    fi
}


###############################################################################
# RSYNC STATISTICS
###############################################################################

rsync_stat_number() {
    local file="$1"
    local heading="$2"
    local value=""

    value="$(
        grep -F "$heading" "$file" 2>/dev/null |
            tail -n 1 |
            sed -E \
                's/^[^:]*:[[:space:]]*([0-9,]+).*/\1/' |
            tr -d ','
    )"

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$value"
    else
        printf '\n'
    fi
}


parse_rsync_stats() {
    local file="$1"
    local label="$2"

    local total=""
    local transferred=""
    local files=""
    local deleted=""
    local sent=""

    total="$(
        rsync_stat_number \
            "$file" \
            "Total file size"
    )"

    transferred="$(
        rsync_stat_number \
            "$file" \
            "Total transferred file size"
    )"

    files="$(
        rsync_stat_number \
            "$file" \
            "Number of regular files transferred"
    )"

    if [ -z "$files" ]; then
        files="$(
            rsync_stat_number \
                "$file" \
                "Number of files transferred"
        )"
    fi

    deleted="$(
        rsync_stat_number \
            "$file" \
            "Number of deleted files"
    )"

    sent="$(
        rsync_stat_number \
            "$file" \
            "Total bytes sent"
    )"

    TOTAL_BYTES["$label"]="${total:-0}"
    TRANSFERRED_BYTES["$label"]="${transferred:-0}"
    FILES_TRANSFERRED["$label"]="${files:-0}"
    DELETED_FILES["$label"]="${deleted:-0}"
    BYTES_SENT["$label"]="${sent:-0}"
}


###############################################################################
# REMOTE SPACE
###############################################################################

remote_df() {
    local dest="$1"

    local attempt=1
    local output=""

    while [ "$attempt" -le "$REMOTE_DF_RETRIES" ]; do
        output="$(
            ssh_run \
                df \
                -P \
                -B1 \
                -- \
                "$dest" \
                2>/dev/null |
                awk \
                    'NR == 2 {print $1 "|" $4 "|" $6}'
        )"

        if [ -n "$output" ]; then
            printf '%s\n' "$output"
            return 0
        fi

        if [ "$attempt" -lt "$REMOTE_DF_RETRIES" ]; then
            sleep "$REMOTE_DF_RETRY_SLEEP"
        fi

        attempt=$((attempt + 1))
    done

    return 1
}


estimate_job_change() {
    local label="$1"
    local src="$2"
    local dest="$3"
    local extra_excludes="$4"
    local bwlimit="$5"

    local tmp_log=""
    local status=0
    local estimated=""
    local excerpt=""

    local -a rsync_args=()
    local -a command=()

    tmp_log="$(mktemp /tmp/remote_backup_estimate.XXXXXX)"

    build_rsync_args \
        rsync_args \
        "$extra_excludes" \
        "$bwlimit" \
        "preflight"

    rsync_args+=(
        "--dry-run"
    )

    command=(
        "${PRIORITY_PREFIX[@]}"
        rsync
        "${rsync_args[@]}"
        "${src%/}/"
        "${REMOTE}:${dest%/}/"
    )

    log "PREFLIGHT" "INFO" \
        "[${label}] estimating changed data with rsync dry-run"

    "${command[@]}" >"$tmp_log" 2>&1
    status=$?

    if [ "$status" -ne 0 ]; then
        excerpt="$(
            extract_rsync_errors \
                "$tmp_log" \
                "$NOTIFY_EXCERPT_LINES"
        )"

        PREFLIGHT_FAILURE_DETAIL="Rsync estimate failed for ${label}: exit ${status}
${excerpt}"

        log "PREFLIGHT" "ERROR" \
            "[${label}] rsync estimate failed with exit=${status}"

        rm -f -- "$tmp_log"
        return 1
    fi

    estimated="$(
        rsync_stat_number \
            "$tmp_log" \
            "Total transferred file size"
    )"

    estimated="${estimated:-0}"

    ESTIMATED_BYTES["$label"]="$estimated"

    log "PREFLIGHT" "INFO" \
        "[${label}] estimated transfer: $(bytes_to_human "$estimated")"

    rm -f -- "$tmp_log"

    return 0
}


preflight_space() {
    local descriptor=""
    local label=""
    local src=""
    local dest=""
    local extra_excludes=""
    local bwlimit=""

    local estimated=0

    local df_output=""
    local device=""
    local available=0
    local mountpoint=""

    local needed=0
    local percentage_buffer=0
    local safety_buffer=0

    local -A required_by_device=()
    local -A available_by_device=()
    local -A mount_by_device=()

    PREFLIGHT_FAILURE_DETAIL=""

    for descriptor in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r \
            label \
            src \
            dest \
            extra_excludes \
            bwlimit \
            <<<"$descriptor"

        bwlimit="${bwlimit:-0}"

        case "$PREFLIGHT_MODE" in
            estimate)
                if ! estimate_job_change \
                    "$label" \
                    "$src" \
                    "$dest" \
                    "$extra_excludes" \
                    "$bwlimit"
                then
                    return 1
                fi

                estimated="${ESTIMATED_BYTES[$label]:-0}"
                ;;

            total)
                estimated="$(safe_size_bytes "$src")"
                ESTIMATED_BYTES["$label"]="$estimated"

                log "PREFLIGHT" "INFO" \
                    "[${label}] conservative total-size estimate: $(bytes_to_human "$estimated")"
                ;;
        esac

        if ! df_output="$(remote_df "$dest")"; then
            PREFLIGHT_FAILURE_DETAIL="Unable to query remote filesystem space for ${label}: ${dest}"

            log "PREFLIGHT" "ERROR" \
                "$PREFLIGHT_FAILURE_DETAIL"

            return 1
        fi

        IFS='|' read -r \
            device \
            available \
            mountpoint \
            <<<"$df_output"

        if ! [[ "$available" =~ ^[0-9]+$ ]]; then
            PREFLIGHT_FAILURE_DETAIL="Invalid remote free-space value for ${label}: ${available}"

            log "PREFLIGHT" "ERROR" \
                "$PREFLIGHT_FAILURE_DETAIL"

            return 1
        fi

        DEST_FREE_BYTES["$dest"]="$available"

        required_by_device["$device"]=$(
            (${required_by_device["$device"]:-0} + estimated)
        )

        available_by_device["$device"]="$available"
        mount_by_device["$device"]="$mountpoint"
    done

    for device in "${!required_by_device[@]}"; do
        needed="${required_by_device[$device]:-0}"
        available="${available_by_device[$device]:-0}"
        mountpoint="${mount_by_device[$device]:-unknown}"

        percentage_buffer=$(
            (needed * PREFLIGHT_BUFFER_PERCENT / 100)
        )

        if [ "$percentage_buffer" -lt "$PREFLIGHT_MIN_BUFFER_BYTES" ]; then
            safety_buffer="$PREFLIGHT_MIN_BUFFER_BYTES"
        else
            safety_buffer="$percentage_buffer"
        fi

        log "PREFLIGHT" "INFO" \
            "Filesystem ${device} (${mountpoint}): estimated=$(bytes_to_human "$needed"), buffer=$(bytes_to_human "$safety_buffer"), available=$(bytes_to_human "$available")"

        if [ "$available" -lt $((needed + safety_buffer)) ]; then
            PREFLIGHT_FAILURE_DETAIL="Insufficient remote space on ${device} (${mountpoint})
Estimated transfer: $(bytes_to_human "$needed")
Safety buffer: $(bytes_to_human "$safety_buffer")
Available: $(bytes_to_human "$available")"

            log "PREFLIGHT" "ERROR" \
                "Insufficient space on ${device}: need $(bytes_to_human "$((needed + safety_buffer))"), available $(bytes_to_human "$available")"

            return 1
        fi
    done

    log "PREFLIGHT" "INFO" \
        "Aggregate remote-space preflight passed"

    return 0
}


###############################################################################
# RETRY HELPERS
###############################################################################

rsync_should_retry() {
    local code="$1"

    array_contains \
        "$code" \
        "${RETRY_CODES[@]}"
}


compute_backoff() {
    local failed_attempt="$1"

    local seconds="$RETRY_BACKOFF"

    if [ "$ENABLE_EXPONENTIAL_BACKOFF" = "true" ]; then
        seconds=$(( RETRY_BACKOFF * (2 ** (failed_attempt - 1)) ))
    fi

    if [ "$seconds" -gt "$MAX_BACKOFF" ]; then
        seconds="$MAX_BACKOFF"
    fi

    printf '%s\n' "$seconds"
}


###############################################################################
# RSYNC ERROR HANDLING
###############################################################################

rsync_exit_description() {
    local code="${1:-0}"

    case "$code" in
        0)   printf 'Success' ;;
        1)   printf 'Syntax or usage error' ;;
        2)   printf 'Protocol incompatibility' ;;
        3)   printf 'Input/output selection error' ;;
        4)   printf 'Requested action not supported' ;;
        5)   printf 'Client/server protocol startup error' ;;
        6)   printf 'Daemon log-file error' ;;
        10)  printf 'Socket I/O error' ;;
        11)  printf 'File I/O error' ;;
        12)  printf 'Protocol data-stream error' ;;
        13)  printf 'Program diagnostics error' ;;
        14)  printf 'IPC error' ;;
        20)  printf 'Interrupted by signal' ;;
        21)  printf 'waitpid error' ;;
        22)  printf 'SIGPIPE / broken pipe' ;;
        23)  printf 'Partial transfer due to error' ;;
        24)  printf 'Partial transfer due to vanished source files' ;;
        30)  printf 'Data-transfer timeout' ;;
        255) printf 'SSH connection failure' ;;
        *)   printf 'Unknown rsync exit code %s' "$code" ;;
    esac
}


extract_rsync_errors() {
    local file="$1"
    local max_lines="${2:-8}"

    local excerpt=""

    if [ ! -f "$file" ]; then
        printf '(no rsync raw log)'
        return 0
    fi

    excerpt="$(
        grep -iE \
            'error|warning|failed|permission denied|host key|connection refused|no route|timed out|timeout' \
            "$file" \
            2>/dev/null |
            tail -n "$max_lines" ||
            true
    )"

    if [ -n "$excerpt" ]; then
        printf '%s\n' "$excerpt"
    else
        tail \
            -n "$max_lines" \
            "$file" \
            2>/dev/null ||
            printf '(no rsync output)'
    fi
}


###############################################################################
# RAW RSYNC LOGGING
###############################################################################

preserve_raw_log() {
    local label="$1"
    local attempt="$2"
    local status="$3"
    local source_file="$4"

    local safe_label=""
    local result=""
    local destination=""

    safe_label="$(safe_name "$label")"

    if [ "$status" -eq 0 ]; then
        result="success"
    else
        result="fail"
    fi

    destination="${RAW_LOG_DIR}/rsync_${safe_label}_${RUN_STAMP}_attempt${attempt}_${result}.log"

    if cp -- "$source_file" "$destination" 2>/dev/null; then
        printf '%s\n' "$destination"
        return 0
    fi

    printf '\n'
    return 1
}


###############################################################################
# RSYNC BACKUP
###############################################################################

rsync_label() {
    local label="$1"
    local src="$2"
    local dest="$3"
    local extra_excludes="$4"
    local bwlimit="${5:-0}"

    local attempt=1
    local status=0
    local description=""
    local sleep_seconds=0

    local tmp_log=""
    local saved_log=""
    local command_string=""

    local -a rsync_args=()
    local -a command=()

    RESULT_CODE["$label"]=1
    RESULT_REASON["$label"]="Not run"

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        tmp_log="$(mktemp /tmp/remote_backup_rsync.XXXXXX)"

        build_rsync_args \
            rsync_args \
            "$extra_excludes" \
            "$bwlimit" \
            "actual"

        command=(
            "${PRIORITY_PREFIX[@]}"
            rsync
            "${rsync_args[@]}"
            "${src%/}/"
            "${REMOTE}:${dest%/}/"
        )

        printf -v command_string '%q ' "${command[@]}"

        log "RSYNC" "INFO" \
            "[${label}] attempt ${attempt}/${MAX_RETRIES}"

        log "RSYNC" "INFO" \
            "[${label}] running: ${command_string}"

        "${command[@]}" 2>&1 |
            tee "$tmp_log" |
            while IFS= read -r line; do
                [ -n "$line" ] || continue

                log "RSYNC" "INFO" \
                    "[${label}] $line"
            done

        status="${PIPESTATUS[0]}"

        parse_rsync_stats \
            "$tmp_log" \
            "$label"

        saved_log="$(
            preserve_raw_log \
                "$label" \
                "$attempt" \
                "$status" \
                "$tmp_log"
        )"

        if [ -n "$saved_log" ]; then
            RAW_LOG_BY_LABEL["$label"]="$saved_log"
        fi

        if [ "$status" -eq 0 ]; then
            RESULT_CODE["$label"]=0
            RESULT_REASON["$label"]="Success"

            log "RSYNC" "INFO" \
                "[${label}] completed successfully"

            rm -f -- "$tmp_log"

            return 0
        fi

        description="$(rsync_exit_description "$status")"

        RESULT_CODE["$label"]="$status"
        RESULT_REASON["$label"]="$description"

        log "RSYNC" "ERROR" \
            "[${label}] attempt ${attempt} failed: exit=${status} (${description})"

        # Authentication / host-key problems will not be fixed by retrying.
        if [ "$status" -eq 255 ] &&
           is_permanent_ssh_error "$(cat "$tmp_log" 2>/dev/null)"
        then
            RESULT_REASON["$label"]="$(
                classify_ssh_error \
                    "$(cat "$tmp_log" 2>/dev/null)"
            )"

            log "RSYNC" "ERROR" \
                "[${label}] permanent SSH failure; retries stopped"

            rm -f -- "$tmp_log"
            break
        fi

        if ! rsync_should_retry "$status"; then
            log "RSYNC" "ERROR" \
                "[${label}] exit=${status} is not retryable"

            rm -f -- "$tmp_log"
            break
        fi

        if [ "$attempt" -ge "$MAX_RETRIES" ]; then
            rm -f -- "$tmp_log"
            break
        fi

        sleep_seconds="$(
            compute_backoff "$attempt"
        )"

        log "RSYNC" "WARN" \
            "[${label}] retrying in ${sleep_seconds}s"

        rm -f -- "$tmp_log"

        sleep "$sleep_seconds"

        attempt=$((attempt + 1))
    done

    FAILED_LABELS+=("$label")

    log "RSYNC" "ERROR" \
        "[${label}] final failure: exit=${RESULT_CODE[$label]} (${RESULT_REASON[$label]})"

    return 1
}


run_all_backups() {
    local descriptor=""
    local label=""
    local src=""
    local dest=""
    local extra_excludes=""
    local bwlimit=""

    local failed=0

    for descriptor in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r \
            label \
            src \
            dest \
            extra_excludes \
            bwlimit \
            <<<"$descriptor"

        bwlimit="${bwlimit:-0}"

        log "BACKUP" "INFO" \
            "Starting ${label}: ${src} -> ${DEST_NAS}:${dest}"

        if ! rsync_label \
            "$label" \
            "$src" \
            "$dest" \
            "$extra_excludes" \
            "$bwlimit"
        then
            failed=1
        fi
    done

    return "$failed"
}


###############################################################################
# REPORT SPACE REFRESH
###############################################################################

refresh_remote_space_for_report() {
    local descriptor=""
    local label=""
    local src=""
    local dest=""
    local extra_excludes=""
    local bwlimit=""

    local df_output=""
    local device=""
    local available=""
    local mountpoint=""

    for descriptor in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r \
            label \
            src \
            dest \
            extra_excludes \
            bwlimit \
            <<<"$descriptor"

        if df_output="$(remote_df "$dest")"; then
            IFS='|' read -r \
                device \
                available \
                mountpoint \
                <<<"$df_output"

            if [[ "$available" =~ ^[0-9]+$ ]]; then
                DEST_FREE_BYTES["$dest"]="$available"
            fi
        fi
    done
}


###############################################################################
# REMOTE SHUTDOWN
###############################################################################

shutdown_remote() {
    local backup_failed="$1"
    local should_shutdown=false

    if [ "$REMOTE_READY" -ne 1 ]; then
        return 0
    fi

    if [ "$DRY_RUN" = "true" ]; then
        log "REMOTE" "INFO" \
            "DRY_RUN=true; remote shutdown skipped"

        return 0
    fi

    if [ "$backup_failed" -eq 0 ] &&
       [ "$SHUTDOWN_REMOTE_ON_SUCCESS" = "true" ]
    then
        should_shutdown=true
    fi

    if [ "$backup_failed" -ne 0 ] &&
       [ "$SHUTDOWN_REMOTE_ON_FAILURE" = "true" ]
    then
        should_shutdown=true
    fi

    if [ "$should_shutdown" != "true" ]; then
        if [ "$backup_failed" -ne 0 ]; then
            log "REMOTE" "INFO" \
                "Remote NAS left running because backup failed and SHUTDOWN_REMOTE_ON_FAILURE=false"
        fi

        return 0
    fi

    REMOTE_SHUTDOWN_REQUESTED=1

    log "REMOTE" "INFO" \
        "Requesting shutdown of ${DEST_NAS}"

    if ssh_raw \
        'nohup powerdown >/dev/null 2>&1 </dev/null &'
    then
        log "REMOTE" "INFO" \
            "Shutdown request sent successfully"
    else
        REMOTE_SHUTDOWN_FAILED=1

        log "REMOTE" "ERROR" \
            "Failed to send shutdown command to ${DEST_NAS}"

        return 1
    fi

    return 0
}


###############################################################################
# RETENTION
###############################################################################

prune_main_logs() {
    local -a logs=()
    local removed=0

    mapfile -t logs < <(
        find "$LOG_DIR" \
            -maxdepth 1 \
            -type f \
            -name 'remote_backup_*.log' \
            -printf '%T@\t%p\n' \
            2>/dev/null |
            sort -nr |
            cut -f2-
    )

    while [ "${#logs[@]}" -gt "$MAX_LOGS" ]; do
        rm -f -- "${logs[-1]}"
        unset 'logs[-1]'
        logs=("${logs[@]}")
        removed=$((removed + 1))
    done

    if [ "$removed" -gt 0 ]; then
        log "CLEANUP" "INFO" \
            "Removed ${removed} old main log(s)"
    fi
}


prune_raw_logs() {
    local descriptor=""
    local label=""
    local src=""
    local dest=""
    local extra_excludes=""
    local bwlimit=""

    local safe_label=""
    local removed=0

    local -a logs=()

    for descriptor in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r \
            label \
            src \
            dest \
            extra_excludes \
            bwlimit \
            <<<"$descriptor"

        safe_label="$(safe_name "$label")"

        logs=()

        mapfile -t logs < <(
            find "$RAW_LOG_DIR" \
                -maxdepth 1 \
                -type f \
                -name "rsync_${safe_label}_*.log" \
                -printf '%T@\t%p\n' \
                2>/dev/null |
                sort -nr |
                cut -f2-
        )

        while [ "${#logs[@]}" -gt "$MAX_RAW_LOGS" ]; do
            rm -f -- "${logs[-1]}"
            unset 'logs[-1]'
            logs=("${logs[@]}")
            removed=$((removed + 1))
        done
    done

    if [ "$removed" -gt 0 ]; then
        log "CLEANUP" "INFO" \
            "Removed ${removed} old raw rsync log(s)"
    fi
}


prune_old_artifacts() {
    prune_main_logs
    prune_raw_logs
}


###############################################################################
# FINAL NOTIFICATION
###############################################################################

send_final_notification() {
    local backup_failed="$1"
    local runtime_human="$2"

    local level="normal"
    local overall_status="OK"

    local descriptor=""
    local label=""
    local src=""
    local dest=""
    local extra_excludes=""
    local bwlimit=""

    local code=0
    local total=0
    local transferred=0
    local files=0
    local deleted=0
    local sent=0
    local estimated=0
    local free=0

    local raw_log=""
    local excerpt=""

    local body=""

    if [ "$backup_failed" -ne 0 ]; then
        level="alert"
        overall_status="FAILED"

    elif [ "$REMOTE_SHUTDOWN_FAILED" -ne 0 ]; then
        level="warning"
        overall_status="OK - shutdown failed"
    fi

    body+="Mode: "

    if [ "$DRY_RUN" = "true" ]; then
        body+="DRY RUN"
    else
        body+="LIVE"
    fi

    body+=$'\n'
    body+="Runtime: ${runtime_human}"$'\n'
    body+="Route: ${SRC_NAS} -> ${DEST_NAS}"$'\n'
    body+=$'\n'

    for descriptor in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r \
            label \
            src \
            dest \
            extra_excludes \
            bwlimit \
            <<<"$descriptor"

        code="${RESULT_CODE[$label]:-1}"

        total="${TOTAL_BYTES[$label]:-0}"
        transferred="${TRANSFERRED_BYTES[$label]:-0}"
        files="${FILES_TRANSFERRED[$label]:-0}"
        deleted="${DELETED_FILES[$label]:-0}"
        sent="${BYTES_SENT[$label]:-0}"

        estimated="${ESTIMATED_BYTES[$label]:-0}"
        free="${DEST_FREE_BYTES[$dest]:-0}"

        if [ "$code" -eq 0 ]; then
            body+="[OK] ${label}"$'\n'
        else
            body+="[FAILED] ${label}: exit=${code} (${RESULT_REASON[$label]:-Unknown failure})"$'\n'
        fi

        body+="  Total source:      $(bytes_to_human "$total")"$'\n'
        body+="  Estimated change:  $(bytes_to_human "$estimated")"$'\n'
        body+="  Transferred:       $(bytes_to_human "$transferred")"$'\n'
        body+="  Files transferred: ${files}"$'\n'
        body+="  Files deleted:     ${deleted}"$'\n'
        body+="  Network sent:      $(bytes_to_human "$sent")"$'\n'

        if [ "$free" -gt 0 ]; then
            body+="  Remote free:       $(bytes_to_human "$free")"$'\n'
        fi

        if [ "$code" -ne 0 ]; then
            raw_log="${RAW_LOG_BY_LABEL[$label]:-}"

            if [ -n "$raw_log" ] &&
               [ -f "$raw_log" ]
            then
                excerpt="$(
                    extract_rsync_errors \
                        "$raw_log" \
                        "$NOTIFY_EXCERPT_LINES"
                )"

                body+="  Recent error output:"$'\n'
                body+="${excerpt}"$'\n'
            fi
        fi

        body+=$'\n'
    done

    if [ "$REMOTE_SHUTDOWN_REQUESTED" -eq 1 ]; then
        if [ "$REMOTE_SHUTDOWN_FAILED" -eq 0 ]; then
            body+="Remote shutdown: requested successfully"$'\n'
        else
            body+="Remote shutdown: FAILED"$'\n'
        fi
    elif [ "$DRY_RUN" = "true" ]; then
        body+="Remote shutdown: skipped for dry run"$'\n'
    elif [ "$backup_failed" -ne 0 ]; then
        body+="Remote shutdown: skipped after backup failure"$'\n'
    fi

    body+="Log: ${LOG_FILE}"

    notify_unraid \
        "$level" \
        "${SRC_NAS} -> ${DEST_NAS} - ${overall_status}" \
        "$body"
}


###############################################################################
# ABORT NOTIFICATION
###############################################################################

send_abort_notification() {
    local description="$1"
    local detail="$2"

    local runtime_seconds=0
    local runtime_human=""

    runtime_seconds=$(($(date +%s) - START_TIME))
    runtime_human="$(format_duration "$runtime_seconds")"

    notify_unraid \
        "alert" \
        "$description" \
        "${detail}

Runtime: ${runtime_human}
Log: ${LOG_FILE}"
}


###############################################################################
# MAIN
###############################################################################

main() {
    local backup_failed=0

    local runtime_seconds=0
    local runtime_human=""

    # -----------------------------------------------------------------------
    # Logging initialization
    # -----------------------------------------------------------------------

    if ! ensure_dir "$LOG_DIR"; then
        printf '%s ERROR: Unable to create log directory: %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$LOG_DIR"

        return 1
    fi

    if ! ensure_dir "$RAW_LOG_DIR"; then
        printf '%s ERROR: Unable to create raw log directory: %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$RAW_LOG_DIR"

        return 1
    fi

    if ! : >"$LOG_FILE"; then
        printf '%s ERROR: Unable to create log file: %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$LOG_FILE"

        return 1
    fi

    START_TIME="$(date +%s)"

    log "BACKUP" "INFO" \
        "Remote backup started"

    log "BACKUP" "INFO" \
        "Source NAS: ${SRC_NAS}"

    log "BACKUP" "INFO" \
        "Destination NAS: ${DEST_NAS}"

    if [ "$DRY_RUN" = "true" ]; then
        log "BACKUP" "WARN" \
            "DRY_RUN=true; no destination files will be modified"
    fi


    # -----------------------------------------------------------------------
    # Local preflight
    # -----------------------------------------------------------------------

    if ! validate_configuration; then
        send_abort_notification \
            "Remote Backup - Configuration FAILED" \
            "Local configuration or source-path validation failed."

        prune_old_artifacts

        return 1
    fi

    build_priority_prefix

    prune_old_artifacts


    # -----------------------------------------------------------------------
    # Wake remote
    # -----------------------------------------------------------------------

    wake_remote


    # -----------------------------------------------------------------------
    # Wait for SSH + array mount
    # -----------------------------------------------------------------------

    if ! wait_for_remote_ready; then
        send_abort_notification \
            "Remote Backup - Remote Unavailable" \
            "${DEST_NAS} did not become ready.

Reason: ${REMOTE_WAIT_ERROR}"

        prune_old_artifacts

        return 1
    fi


    # -----------------------------------------------------------------------
    # Validate configured remote destinations
    # -----------------------------------------------------------------------

    if ! validate_remote_destinations; then
        shutdown_remote 1 || true

        send_abort_notification \
            "Remote Backup - Destination FAILED" \
            "${REMOTE_VALIDATION_ERROR}

No rsync was started."

        prune_old_artifacts

        return 1
    fi


    # -----------------------------------------------------------------------
    # Aggregate space preflight
    # -----------------------------------------------------------------------

    if ! preflight_space; then
        shutdown_remote 1 || true

        send_abort_notification \
            "Remote Backup - Preflight FAILED" \
            "${PREFLIGHT_FAILURE_DETAIL}

No live rsync was started."

        prune_old_artifacts

        return 1
    fi


    # -----------------------------------------------------------------------
    # Rsync backup jobs
    # -----------------------------------------------------------------------

    if ! run_all_backups; then
        backup_failed=1
    fi


    # -----------------------------------------------------------------------
    # Refresh remote free-space information before optional shutdown
    # -----------------------------------------------------------------------

    refresh_remote_space_for_report || true


    # -----------------------------------------------------------------------
    # Optional remote shutdown
    # -----------------------------------------------------------------------

    shutdown_remote "$backup_failed" || true


    # -----------------------------------------------------------------------
    # Runtime / final notification
    # -----------------------------------------------------------------------

    runtime_seconds=$(($(date +%s) - START_TIME))
    runtime_human="$(format_duration "$runtime_seconds")"

    if [ "$backup_failed" -eq 0 ]; then
        log "BACKUP" "INFO" \
            "Remote backup completed successfully in ${runtime_human}"
    else
        log "BACKUP" "ERROR" \
            "Remote backup completed with failures in ${runtime_human}"
    fi

    send_final_notification \
        "$backup_failed" \
        "$runtime_human"


    # -----------------------------------------------------------------------
    # Retention
    # -----------------------------------------------------------------------

    prune_old_artifacts


    # -----------------------------------------------------------------------
    # Exit status
    # -----------------------------------------------------------------------

    if [ "$backup_failed" -ne 0 ] ||
       [ "$REMOTE_SHUTDOWN_FAILED" -ne 0 ]
    then
        return 1
    fi

    return 0
}


###############################################################################
# ENTRY POINT
###############################################################################

main "$@"