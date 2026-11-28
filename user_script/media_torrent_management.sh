#!/bin/bash
# Release version: bump for every deployed code change; descriptions stay user-owned.
readonly SCRIPT_VERSION="3.7.2"
# Version lookup exits before logging, locks, state, Docker or network activity.
if [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" == --version ]]; then
    printf 'media_torrent_management.sh %s\n' "$SCRIPT_VERSION"
    exit 0
fi
# BEGIN CURRENT OPERATIONAL PURPOSE
# PURPOSE: Prepare completed configured qBittorrent payloads and move them into their final Plex
#   locations, with a separate bounded VueTorrent refresh.
# WORKFLOW: Check active torrent ownership, remove configured unwanted source files, normalize
#   confidently identified JAV codes before rsync, then move completed payloads. Incoming same-
#   name files replace destination names; uncertain codes retain their names.
# COORDINATION: Works with the qBittorrent completion/category workflow and Plex agent naming.
#   Mover guards protect movement; source preparation happens before files reach the array.
# LIMITS: Incomplete downloads and unconfigured categories are not bulk-cleaned. No title
#   scraping, duplicate-name suffixes or original-name archive is added. VueTorrent staging is
#   validated separately.
# REPORTING: Console-only action, timing and backlog reporting; no email notifications.
# Commands and side effects: docs/user-scripts-cli.md in ray-cys/unraid_repo.
# END CURRENT OPERATIONAL PURPOSE
clearLog=true

###############################################################################
# Data Management
#
# PURPOSE
# -------
# Process completed qBittorrent downloads and move them into their final
# Plex library locations.
#
# Workflow:
#
#   qBittorrent
#       |
#       +-- complete/
#       |     |
#       |     +-- ポルノ/
#       |     |
#       |     +-- <configured private performer categories>/
#       |
#       +-- incomplete/
#
#
# Processing:
#
#   1. Validate completed-download category layout.
#   2. Remove unwanted files at the completed-download source.
#   3. Normalize clear JAV release codes for Jav18 before rsync.
#   4. Move ポルノ content to its destination.
#   5. Move private performer categories to their individual destinations.
#   6. Refresh VueTorrent on its separate weekly cadence.
#
# uses incoming-file replacement, source cleanup before renaming, per-payload
# Mover checks, validated WebUI staging and a console-only run summary.
# recognizes leading release codes, numeric studio prefixes and multipart
# names locally. No metadata scraping, original-name archive or extra schedule.
# Uncertain codes, mixed IDs and excerpts retain their names; non-video assets
# keep the existing literal cleanup rules.
# applies the same immediate, per-payload policy to both category phases.
# Run with --help for console-only usage; no notification emails are sent.
#
#
# SAFETY
# ------
# - The incomplete directory is never scanned or modified.
# - Only explicitly configured qBittorrent categories are processed.
# - Unknown non-empty categories stop the script before anything is moved.
# - Incoming same-name files replace destination files through rsync.
# - A healthy API is required. Empty torrent lists permit immediate orphan transfer.
# - Active/incomplete/seeding payload units are retained without blocking siblings.
# - Completed-folder location is trusted for unregistered payloads in both phases.
# - No age/stability wait applies; this cannot prove an orphan file is complete.
# - No duplicate suffixes, original-file copies or media hashing are used.
# - Same-name replacements use rsync temporary files, not in-place writes.
# - VueTorrent is updated only after successful data processing.
#
#
# REQUIREMENTS
# ------------
# Intended for Unraid User Scripts.
#
###############################################################################

# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="media_torrent_management"
# shellcheck shell=bash
# Shared operational logs, notifications and execution receipts.
usr_ops_now_ms() {
    local stamp="${EPOCHREALTIME:-}"
    if [[ "$stamp" =~ ^[0-9]+\.[0-9]{6}$ ]];then stamp=${stamp/./};printf '%s\n' "${stamp:0:${#stamp}-3}"
    else stamp=$(date +%s%N) || return 1;printf '%s\n' "${stamp:0:${#stamp}-6}";fi
}

usr_ops_log_line() {
    local level="${1^^}" phase="$2" message="$3" line LC_ALL=C
    case "$level" in WARN) level=WARNING;; ERR|FATAL) level=ERROR;; NOTICE) level=INFO;; esac
    message=${message//$'\r'/};message=${message//$'\n'/ | }
    printf -v line '%s | %s | %s | run=%s | phase=%s | %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$OPS_SCRIPT_ID" "${OPS_RUN_ID:-$$}" "$phase" "$message"
    if ((${#line}>4096));then line="${line:0:4050} ... [truncated]";fi
    printf '%s\n' "$line"
}

usr_ops_execution_record() (
    local phase="$1" started="$2" pid="$3" rc="${4:-0}" process_start root="${USR_OPS_EXECUTION_ROOT:-/run/user-script-execution}" file tmp now boot old='{}' status
    [[ "${OPS_SCRIPT_ID:-}" =~ ^[a-z0-9_]+$ && ! -L "$root" ]] || return 1
    mkdir -p "$root" || return 1;file="$root/$OPS_SCRIPT_ID.json"
    [[ ! -L "$file" ]] || return 1
    if [[ -f "$file" ]];then old=$(jq -c 'select(.schema==1)' "$file") || old='{}';fi
    [[ -n "$old" ]] || old='{}'
    now=$(date +%s);boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)
    process_start=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')
    [[ "$phase" != finish ]] || process_start=$(jq -r '.processStart // ""' <<<"$old")
    status=RUNNING;[[ "$phase" != finish ]] || { status=COMPLETED;((rc==0)) || status=FAILED; }
    tmp=$(mktemp "$root/.execution.XXXXXX") || return 1;trap 'rm -f -- "$tmp"' EXIT
    jq -n --argjson old "$old" --arg processStart "$process_start" --arg name "$OPS_SCRIPT_ID" --arg boot "$boot" --arg status "$status" --argjson started "$started" --argjson at "$now" --argjson pid "$pid" --argjson rc "$rc" \
      '$old+{schema:1,name:$name,boot:$boot,executionStatus:$status,startedAt:$started,observedAt:$at,pid:$pid,processStart:$processStart,lastExitCode:$rc} |
       if $status!="RUNNING" then .finishedAt=$at|.durationSeconds=($at-$started)|.lastCompletedAt=$at|if $rc==0 then .lastSuccessAt=$at else . end
       else .previousRun={startedAt:$old.startedAt,finishedAt:$old.finishedAt,status:$old.executionStatus,exitCode:$old.lastExitCode,durationSeconds:$old.durationSeconds}|.finishedAt=null|.durationSeconds=null|.lastExitCode=null end' >"$tmp" && chmod 600 "$tmp" && mv "$tmp" "$file" || return 1
    local persistent="${USR_OPS_EXECUTION_PERSISTENT_ROOT:-/mnt/vault/cloud/logs/script/user_scripts_status/execution}" fd export_fd
    mountpoint -q "${USR_OPS_VAULT_MOUNT:-/mnt/vault}" || return 0
    [[ ! -L "$persistent" && $(realpath -m "$persistent") == "$persistent" ]] || return 1
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}";flock -s -n "$export_fd" || return 0
    mkdir -p "$persistent" || return 1
    tmp=$(mktemp "$persistent/.execution.XXXXXX") || return 1
    cp "$file" "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$persistent/$OPS_SCRIPT_ID.json"
)

usr_ops_supervise() {
    local script="$1" started pid='' interrupted='' rc=0 receipt_fd record_owner=false
    # Repository/fixture executions must never publish production evidence.
    # Explicit test roots opt into supervision for isolated regression checks.
    case "$script" in
      /boot/config/plugins/user.scripts/scripts/*/script|/tmp/user.scripts/tmpScripts/*/script) ;;
      *) if [[ -z "${USR_OPS_EXECUTION_ROOT:-}" ]];then USR_OPS_SUPERVISED="$OPS_SCRIPT_ID" /bin/bash "$script";return $?;fi;;
    esac
    local execution_root="${USR_OPS_EXECUTION_ROOT:-/run/user-script-execution}"
    if [[ ! -L "$execution_root" ]] && mkdir -p "$execution_root";then
        exec {receipt_fd}>"$execution_root/$OPS_SCRIPT_ID.lock"
        flock -n "$receipt_fd" && record_owner=true
    fi
    # Register forwarding before launch or receipt I/O. Background Bash may
    # inherit ignored SIGINT, so interactive cancellation uses its TERM cleanup.
    trap 'interrupted=TERM;[[ -z "$pid" ]] || kill -TERM "$pid" 2>/dev/null || true' TERM HUP
    trap 'interrupted=INT;[[ -z "$pid" ]] || kill -TERM "$pid" 2>/dev/null || true' INT
    started=$(date +%s)
    USR_OPS_SUPERVISED="$OPS_SCRIPT_ID" OPS_RUN_ID="${OPS_RUN_ID:-${started}_$$}" /bin/bash "$script" &
    pid=$!
    [[ -z "$interrupted" ]] || kill -TERM "$pid" 2>/dev/null || true
    [[ "$record_owner" != true ]] || usr_ops_execution_record start "$started" "$pid" || printf 'Execution receipt unavailable for %s; workflow continues.\n' "$OPS_SCRIPT_ID" >&2
    wait "$pid" || rc=$?
    # A signal can interrupt wait while the producer is still restoring state.
    if kill -0 "$pid" 2>/dev/null;then wait "$pid" || rc=$?;fi
    if [[ "$interrupted" == INT ]];then rc=130;elif [[ "$interrupted" == TERM ]];then rc=143;fi
    [[ "$record_owner" != true ]] || usr_ops_execution_record finish "$started" "$pid" "$rc" || printf 'Completion receipt unavailable for %s (exit=%s).\n' "$OPS_SCRIPT_ID" "$rc" >&2
    trap - TERM HUP INT
    return "$rc"
}
# END EMBEDDED OPERATIONS CONTRACT
# BEGIN SCHEDULED EXECUTION SUPERVISOR
if [[ "${BASH_SOURCE[0]}" == "$0" && $# == 0 && "${USR_OPS_SUPERVISED:-}" != "$OPS_SCRIPT_ID" ]];then
    usr_ops_supervise "$0";exit $?
fi
# END SCHEDULED EXECUTION SUPERVISOR
set -uo pipefail

umask 0002


###############################################################################
# CONFIGURATION
###############################################################################

# ---------------------------------------------------------------------------
# Source / destination
# ---------------------------------------------------------------------------

SRC_DIR="/mnt/user/secure/torrent"
COMPLETE_DIR="${SRC_DIR}/complete"

DEST_DIR="/mnt/user/secure"

PORN_CATEGORY="ポルノ"
PORN_DEST="${DEST_DIR}/ポルノ"

PRIVATE_DEST_ROOT="${DEST_DIR}/プライベート"


# ---------------------------------------------------------------------------
# qBittorrent private categories
#
# These are treated as an explicit whitelist.
#
# A matching source category:
#
#   complete/Ai.Kano.叶爱/
#
# is moved into:
#
#   /mnt/user/secure/プライベート/Ai.Kano.叶爱/
#
# Unknown non-empty categories are NOT processed.
# ---------------------------------------------------------------------------

PRIVATE_CATEGORIES=(
    "Ai.Kano.叶爱"
    "Aika.Yumeno.夢乃あいか"
    "Akari.Niimura.新村あかり"
    "Ena.Satsuki.沙月恵奈"
    "Karen.Yuzuriha.楪カレン"
    "Sora.Amakawa.天川そら"
    "Sui.Twinkle.月野江すい"
    "Yui.Tenma.天馬ゆい"
)


# ---------------------------------------------------------------------------
# Unknown category handling
#
# true:
#   Stop processing if an unexpected non-empty category is found.
#
# false:
#   Log the unknown category and leave it untouched.
#
# Recommended: true
# ---------------------------------------------------------------------------

FAIL_ON_UNKNOWN_CATEGORY=true


# ---------------------------------------------------------------------------
# Ownership / permissions
#
# Directories:
#   2775 = rwxrwsr-x
#
# Files:
#   0664 = rw-rw-r--
#
# Media files do not need executable permissions.
# ---------------------------------------------------------------------------

OWN_USER="nobody"
OWN_GROUP="users"

DIR_MODE="2775"
FILE_MODE="0664"


# ---------------------------------------------------------------------------
# Filename cleanup
#
# These strings are removed literally wherever they occur in a filename or
# directory name.
#
# "ch" is intentionally NOT included here.
#
# It receives special handling later:
#
#   12345ch       -> 12345
#   ABC-123ch     -> ABC-123
#   teacher       -> teacher
#   archive       -> archive
#
# This avoids globally deleting "ch" from legitimate words.
# ---------------------------------------------------------------------------

RENAME_LITERALS=(
    "hhd800.com@"
    "gg5.co@"
    "-C_GG5"
    "uncensored"
    "-C_X1080X"
    "4k688.com@"
    "-LTX"
)


# ---------------------------------------------------------------------------
# Unwanted file extensions
#
# Extensions are matched case-insensitively.
# Do not include the leading dot.
# ---------------------------------------------------------------------------

UNWANTED_EXTS=(
    "url"
    "html"
    "mht"
    "gif"
    "txt"
    "rar"
    "apk"
    "jpg"
)


# ---------------------------------------------------------------------------
# Exact unwanted filenames
# ---------------------------------------------------------------------------

UNWANTED_NAMES=(
    "18+游戏大全(996gg.cc)-七龍珠H版-三國志H版-三國群淫傳等.mp4"
)


# ---------------------------------------------------------------------------
# VueTorrent
#
# VueTorrent remains part of this script intentionally.
#
# It is updated only after every data-processing phase succeeds.
# ---------------------------------------------------------------------------

VUETORRENT_DIR="/mnt/user/appdata/qbittorrent/webui"
VUETORRENT_REPO="https://github.com/VueTorrent/VueTorrent.git"
VUETORRENT_BRANCH="latest-release"
VUETORRENT_CLONE_TIMEOUT=300
# Console output only. Small durable recovery checkpoints are state, not logs.
TRANSFER_STATE_DIR="${TRANSFER_STATE_DIR:-/mnt/vault/cloud/logs/script/media_torrent_management/state}"
QBIT_API_URL="${QBIT_API_URL:-https://qbittorrent.taila4be9.ts.net}"
QBIT_RESOLVE="${QBIT_RESOLVE:-qbittorrent.taila4be9.ts.net:443:100.64.251.79}"
QBIT_CONTAINER_ROOT="${QBIT_CONTAINER_ROOT:-/data}"
QBIT_HOST_ROOT="${QBIT_HOST_ROOT:-/mnt/user/secure}"
QBIT_HEADERS_FILE="${QBIT_HEADERS_FILE:-/mnt/vault/cloud/logs/script/docker_service_watchdog/probe-auth/qbittorrent.headers}"
QBIT_RUNTIME=""
QBIT_API_UNAVAILABLE=false


# ---------------------------------------------------------------------------
# Runtime / locking
# ---------------------------------------------------------------------------

LOCK_FILE="/tmp/media_torrent_management.lock"

LOG_MIN_LEVEL="info"


###############################################################################
# RUNTIME STATE
###############################################################################

START_TS=$(date +%s)

RENAME_SED_ARGS=()
RUN_TRANSFERRED_FILES=0
RUN_TRANSFERRED_BYTES=0
RUN_RENAMED_FILES=0
RUN_RENAMED_DIRS=0
RUN_REMOVED_FILES=0
RUN_REMOVED_BYTES=0
RUN_SOURCE_REPLACEMENTS=0
RUN_DEST_REPLACEMENTS=0
RUN_RETAINED_PAYLOADS=0
RUN_WEBUI_RESULT="not checked"


###############################################################################
# LOGGING / RUNTIME HELPERS
###############################################################################



log() {
    local level="${1:-info}"
    shift || true

    local msg="$*"
    local rank_level
    local rank_min

    case "$level" in
        debug)
            rank_level=10
            ;;
        info)
            rank_level=20
            ;;
        warn|warning)
            rank_level=30
            level="warn"
            ;;
        err|error)
            rank_level=40
            level="error"
            ;;
        crit|critical)
            rank_level=50
            level="crit"
            ;;
        *)
            rank_level=20
            level="info"
            ;;
    esac

    case "$LOG_MIN_LEVEL" in
        debug)
            rank_min=10
            ;;
        info)
            rank_min=20
            ;;
        warn|warning)
            rank_min=30
            ;;
        err|error)
            rank_min=40
            ;;
        crit|critical)
            rank_min=50
            ;;
        *)
            rank_min=10
            ;;
    esac

    (( rank_level < rank_min )) && return 0

    case "$level" in
        error|warn|crit) usr_ops_log_line "$level" transfer "$msg" >&2;;
        *) usr_ops_log_line "$level" transfer "$msg";;
    esac
}


elapsed() {
    local start="$1"

    echo $(( $(date +%s) - start ))
}


format_runtime() {
    local secs="$1"

    printf '%dh %dm %ds' \
        $((secs / 3600)) \
        $(((secs % 3600) / 60)) \
        $((secs % 60))
}


finish() {
    local code="${1:-0}"
    shift || true

    local message="$*"
    local runtime_seconds
    local runtime

    runtime_seconds=$(elapsed "$START_TS")
    runtime=$(format_runtime "$runtime_seconds")

    if (( code == 0 )); then
        log info "$message (Runtime: $runtime)"
    else
        log error "$message (Runtime: $runtime)"
    fi

    log info "SUMMARY: transferred=$RUN_TRANSFERRED_FILES file(s)/$(human_readable "$RUN_TRANSFERRED_BYTES"); renamed=$RUN_RENAMED_FILES file(s)/$RUN_RENAMED_DIRS directory(s); removed=$RUN_REMOVED_FILES unwanted file(s)/$(human_readable "$RUN_REMOVED_BYTES"); same-name replacements: source=$RUN_SOURCE_REPLACEMENTS destination=$RUN_DEST_REPLACEMENTS; observed retained payloads=$RUN_RETAINED_PAYLOADS; VueTorrent=$RUN_WEBUI_RESULT. Transfer totals cover completed payloads; partial failed transfers are not counted."
    exit "$code"
}


###############################################################################
# VALIDATION HELPERS
###############################################################################

require_commands() {
    local missing=()
    local cmd

    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if (( ${#missing[@]} > 0 )); then
        log error "Missing required command(s): ${missing[*]}"
        return 1
    fi

    return 0
}


array_contains() {
    local wanted="$1"
    shift || true

    local item

    for item in "$@"; do
        [[ "$item" == "$wanted" ]] && return 0
    done

    return 1
}


has_files() {
    local dir="$1"

    [[ -d "$dir" ]] || return 1

    find "$dir" \
        -type f \
        -print -quit 2>/dev/null |
        grep -q .
}


validate_configuration() {
    local category

    if [[ -z "$SRC_DIR" || "$SRC_DIR" == "/" ]]; then
        log error "Invalid SRC_DIR: '$SRC_DIR'"
        return 1
    fi

    if [[ -z "$DEST_DIR" || "$DEST_DIR" == "/" ]]; then
        log error "Invalid DEST_DIR: '$DEST_DIR'"
        return 1
    fi

    if [[ "$SRC_DIR" == "$DEST_DIR" ]]; then
        log error "SRC_DIR and DEST_DIR cannot be identical"
        return 1
    fi

    if [[ ! -d "$SRC_DIR" ]]; then
        log error "Source directory does not exist: $SRC_DIR"
        return 1
    fi

    if [[ ! -d "$DEST_DIR" ]]; then
        log error "Destination directory does not exist: $DEST_DIR"
        return 1
    fi

    if ! id "$OWN_USER" >/dev/null 2>&1; then
        log error "Configured user does not exist: $OWN_USER"
        return 1
    fi

    if ! grep -q "^${OWN_GROUP}:" /etc/group; then
        log error "Configured group does not exist: $OWN_GROUP"
        return 1
    fi

    for category in "${PRIVATE_CATEGORIES[@]}"; do

        if [[ "$category" == "$PORN_CATEGORY" ]]; then
            log error \
                "Private category '$category' conflicts with PORN_CATEGORY"
            return 1
        fi

    done

    return 0
}


###############################################################################
# FILE HELPERS
###############################################################################

filesize() {
    local file="$1"

    [[ -f "$file" ]] || {
        echo 0
        return 0
    }

    stat -c '%s' -- "$file" 2>/dev/null || echo 0
}


human_readable() {
    local bytes="${1:-0}"

    if [[ -z "$bytes" || "$bytes" -eq 0 ]]; then
        printf '0B'
        return 0
    fi

    numfmt \
        --to=iec-i \
        --suffix=B \
        --format='%.1f' \
        "$bytes"
}


remove_empty_dirs() {
    local dir="$1"

    [[ -d "$dir" ]] || return 0

    find "$dir" \
        -mindepth 1 \
        -depth \
        -type d \
        -empty \
        -delete 2>/dev/null || true
}


###############################################################################
# CATEGORY VALIDATION
###############################################################################

is_known_category() {
    local category="$1"

    if [[ "$category" == "$PORN_CATEGORY" ]]; then
        return 0
    fi

    array_contains "$category" "${PRIVATE_CATEGORIES[@]}"
}


validate_complete_layout() {
    local entry
    local name
    local unknown_count=0

    [[ -d "$COMPLETE_DIR" ]] || return 0

    log info "VALIDATE: checking completed-download category layout"

    while IFS= read -r -d '' entry; do

        name=$(basename -- "$entry")

        #######################################################################
        # Files directly under complete/ are unclassified
        #######################################################################

        if [[ -f "$entry" ]]; then

            log error \
                "VALIDATE: unclassified file directly under complete/: '$name'"

            ((unknown_count++))
            continue
        fi


        #######################################################################
        # Known category directory
        #######################################################################

        if [[ -d "$entry" ]] && is_known_category "$name"; then
            log debug "VALIDATE: known category '$name'"
            continue
        fi


        #######################################################################
        # Unknown empty directories are harmless
        #######################################################################

        if [[ -d "$entry" ]] && ! has_files "$entry"; then

            log debug \
                "VALIDATE: ignoring unknown empty directory '$name'"

            continue
        fi


        #######################################################################
        # Unknown non-empty category
        #######################################################################

        log error \
            "VALIDATE: unknown non-empty category '$name'"

        ((unknown_count++))

    done < <(
        find "$COMPLETE_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            -print0 2>/dev/null
    )

    if (( unknown_count > 0 )); then

        if [[ "$FAIL_ON_UNKNOWN_CATEGORY" == "true" ]]; then

            log error \
                "VALIDATE: found $unknown_count unclassified item(s); refusing to process completed downloads"

            return 1

        fi

        log warn \
            "VALIDATE: found $unknown_count unclassified item(s); they will remain untouched"
    fi

    return 0
}


###############################################################################
# FILENAME NORMALIZATION
###############################################################################

escape_sed_literal() {
    local value="$1"

    printf '%s' "$value" |
        sed \
            -e 's/[][\\.^$*+?(){}|]/\\&/g' \
            -e 's,/,\\/,g'
}


build_rename_rules() {
    local literal
    local escaped

    RENAME_SED_ARGS=()

    for literal in "${RENAME_LITERALS[@]}"; do

        escaped=$(escape_sed_literal "$literal")

        RENAME_SED_ARGS+=(
            -e "s/${escaped}//g"
        )

    done

    ###########################################################################
    # Special release-code handling
    #
    # Remove lowercase "ch" only when it immediately follows a digit.
    #
    # Examples:
    #
    #   12345ch       -> 12345
    #   ABC-123ch     -> ABC-123
    #   123ch1080p    -> 123-1080p
    #
    # Normal words containing "ch" remain untouched.
    ###########################################################################

    RENAME_SED_ARGS+=(
        -e 's/([0-9])ch([0-9])/\1-\2/g'
        -e 's/([0-9])ch/\1/g'
    )
}


# The installed Jav18 agent searches a release ID derived from Plex's name.
# Normalize only a clear leading ID; never infer identity from a title alone.
# Used for completed payloads, not a recurring walk of existing libraries.
jav_release_name() {
    local value="$1" mode="${2:-directory}" stem="$1" extension="" prefix number tail upper part=""
    local code='^([0-9]{0,3}[A-Za-z]{2,8}|[Tt]38)[ ._+-]*([0-9]{2,5})([^0-9]|$)'
    local head='^([0-9]{0,3}[A-Za-z]{2,8}|[Tt]38)[ ._+-]*[0-9]{2,5}'
    local other='(^|[^A-Za-z0-9])([0-9]{0,3}[A-Za-z]{2,8}|[Tt]38)[ ._+-]*[0-9]{2,5}([^0-9]|$)'
    if [[ "$mode" == file ]];then
        extension="${value##*.}";extension="${extension,,}"
        case "$extension" in mp4|mkv|avi|wmv|m4v|mov|ts) stem="${value%.*}";;*) return 1;;esac
        extension=".$extension"
    fi
    # Common advertiser wrappers are recognized structurally, without adding
    # every new domain to the keyword list. Other embedded text is untouched.
    if [[ "$stem" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}@(.+)$ ]];then stem="${BASH_REMATCH[1]}";fi
    [[ "$stem" =~ $code ]] || return 1
    prefix="${BASH_REMATCH[1]^^}";number="${BASH_REMATCH[2]}"
    case "$prefix" in SCENE|PART|DISC|DISK|VIDEO|MOVIE|SAMPLE|TRAILER|CLIP|JAVWITHSUBS|FC|HDR|HEVC|XVID) return 1;;esac
    # Keep leading zeroes: they can be part of the actual catalogue ID.
    if [[ "$stem" =~ $head ]];then tail="${stem:${#BASH_REMATCH[0]}}";else return 1;fi
    upper="${tail^^}"
    [[ ! "$upper" =~ \.DUP[0-9]+ ]] || return 1
    # Multiple releases and scene excerpts cannot become one full-release ID.
    [[ ! "$upper" =~ (^|[^A-Z])SCENE[[:space:]_.+-]*[0-9]+ ]] || return 1
    # An attached letter may identify a different edition/part. Keep it rather
    # than guessing. The established ch suffix remains ordinary junk cleanup.
    [[ ! "$tail" =~ ^[A-Za-z] ]] || return 1
    # Bare part/edition suffixes are ambiguous; do not erase their identity.
    [[ ! "$upper" =~ ^[[:space:]_.+-]+([ABD]|[0-9]{1,2})($|[[:space:]_.+-]) ]] || return 1
    if [[ "$upper" =~ (^|[^A-Z])(CD|DISC|DISK|PART|PT)[[:space:]_.-]*([0-9]{1,2})([^0-9]|$) ]];then
        part=$((10#${BASH_REMATCH[3]}));((part>0)) || return 1
        upper="${upper/"${BASH_REMATCH[0]}"/ }"
        part=" - cd$part"
    fi
    [[ ! "$upper" =~ $other ]] || return 1
    printf '%s-%s%s%s' "$prefix" "$number" "$part" "$extension"
}

clean_name() {
    local value="$1" mode="${2:-directory}" cleaned
    cleaned=$(printf '%s' "$value" | sed -E "${RENAME_SED_ARGS[@]}") || return 1
    # Old duplicate suffixes on incoming payloads return to the original name;
    # rsync then applies the same incoming-file replacement policy.
    if [[ "$mode" == file && "$cleaned" =~ ^(.+)\.(mp4|mkv|avi|wmv|m4v|mov|ts)\.dup[1-9][0-9]*$ ]];then
        cleaned="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    elif [[ "$mode" == file && "$cleaned" =~ ^(.+)\.dup[1-9][0-9]*\.(mp4|mkv|avi|wmv|m4v|mov|ts)$ ]];then
        cleaned="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    fi
    jav_release_name "$cleaned" "$mode" || printf '%s' "$cleaned"
}


# Merge colliding source directories using moves, without copying their media.
# Incoming regular files win; directory/file conflicts and links are retained.
merge_rename_directory() {
    local src="$1" dest="$2" entry target
    [[ -d "$src" && -d "$dest" && ! -L "$src" && ! -L "$dest" ]] || return 1
    while IFS= read -r -d '' entry;do
        target="$dest/${entry##*/}"
        [[ ! -L "$entry" && ! -L "$target" ]] || return 1
        if [[ -d "$entry" && -d "$target" ]];then
            merge_rename_directory "$entry" "$target" || return 1
        elif [[ -d "$entry" ]];then
            [[ ! -e "$target" ]] || return 1
            mv -T -- "$entry" "$target" || return 1
        elif [[ -f "$entry" ]];then
            [[ ! -e "$target" || -f "$target" ]] || return 1
            [[ ! -f "$target" ]] || RUN_SOURCE_REPLACEMENTS=$((RUN_SOURCE_REPLACEMENTS+1))
            mv -fT -- "$entry" "$target" || return 1
        else return 1
        fi
    done < <(find "$src" -mindepth 1 -maxdepth 1 -print0)
    rmdir -- "$src"
}

normalize_names() {
    local root="$1" entry old_name new_name new_path renamed_files=0 renamed_dirs=0
    [[ -d "$root" ]] || return 0
    log info "REN: normalizing names at source '$root'"
    while IFS= read -r -d '' entry;do
        [[ -f "$entry" && ! -L "$entry" ]] || return 1
        old_name="${entry##*/}";new_name=$(clean_name "$old_name" file) || return 1
        [[ "$new_name" != "$old_name" ]] || continue
        [[ -n "$new_name" && "$new_name" != . && "$new_name" != .. && "$new_name" != */* ]] || return 1
        new_path="${entry%/*}/$new_name"
        [[ ! -L "$new_path" && ( ! -e "$new_path" || -f "$new_path" ) ]] || return 1
        [[ ! -f "$new_path" ]] || RUN_SOURCE_REPLACEMENTS=$((RUN_SOURCE_REPLACEMENTS+1))
        mv -fT -- "$entry" "$new_path" || return 1
        renamed_files=$((renamed_files+1));RUN_RENAMED_FILES=$((RUN_RENAMED_FILES+1))
        log info "REN: file '$old_name' -> '$new_name'"
    done < <(find "$root" -type f -print0)
    # Children first; merging a parent never invalidates an unprocessed child.
    while IFS= read -r -d '' entry;do
        [[ -d "$entry" ]] || continue
        [[ ! -L "$entry" ]] || return 1
        old_name="${entry##*/}";new_name=$(clean_name "$old_name" directory) || return 1
        [[ "$new_name" != "$old_name" ]] || continue
        [[ -n "$new_name" && "$new_name" != . && "$new_name" != .. && "$new_name" != */* ]] || return 1
        new_path="${entry%/*}/$new_name";[[ ! -L "$new_path" ]] || return 1
        if [[ -d "$new_path" ]];then merge_rename_directory "$entry" "$new_path" || return 1
        else [[ ! -e "$new_path" ]] && mv -T -- "$entry" "$new_path" || return 1
        fi
        renamed_dirs=$((renamed_dirs+1));RUN_RENAMED_DIRS=$((RUN_RENAMED_DIRS+1))
        log info "REN: directory '$old_name' -> '$new_name'"
    done < <(find "$root" -depth -mindepth 1 -type d -print0)
    log info "REN: completed dirs=$renamed_dirs files=$renamed_files; incoming files replace same-name source targets"
}


###############################################################################
# UNWANTED FILE CLEANUP
###############################################################################

is_unwanted_extension() {
    local extension="${1,,}"

    array_contains "$extension" "${UNWANTED_EXTS[@]}"
}


is_unwanted_name() {
    local name="$1"

    array_contains "$name" "${UNWANTED_NAMES[@]}"
}


remove_unwanted_content() {
    local root="$1"

    local file
    local name
    local extension
    local size

    local removed_count=0
    local removed_bytes=0
    local had_error=0

    [[ -e "$root" ]] || return 0

    log info "PRUNE: scanning '$root'"

    while IFS= read -r -d '' file; do

        name=$(basename -- "$file")

        #######################################################################
        # Determine extension
        #######################################################################

        if [[ "$name" == *.* ]]; then
            extension="${name##*.}"
        else
            extension=""
        fi


        #######################################################################
        # Keep file unless it matches one of our cleanup rules
        #######################################################################

        if ! is_unwanted_name "$name" &&
           ! is_unwanted_extension "$extension"
        then
            continue
        fi


        #######################################################################
        # Remove
        #######################################################################

        size=$(filesize "$file")

        log info \
            "PRUNE: removing '$file' size=$(human_readable "$size")"

        if rm -f -- "$file"; then

            removed_count=$((removed_count+1))
            removed_bytes=$((removed_bytes + size))
            RUN_REMOVED_FILES=$((RUN_REMOVED_FILES+1))
            RUN_REMOVED_BYTES=$((RUN_REMOVED_BYTES+size))

        else

            log error \
                "PRUNE: failed removing '$file'"

            had_error=1
        fi

    done < <(
        find "$root" \
            -type f \
            -print0 2>/dev/null
    )

    remove_empty_dirs "$root"

    log info \
        "PRUNE: completed removed=$removed_count size=$(human_readable "$removed_bytes")"

    (( had_error == 0 ))
}


###############################################################################
# MOVE / COLLISION HANDLING
###############################################################################

# No media hashes or duplicate names: rsync replaces same-name regular files.
# This pass validates destination types and collects one set of transfer totals.
prepare_transfer_targets() {
    local src="$1" dest="$2" file relative target parent
    TRANSFER_FILES=0;TRANSFER_BYTES=0;TRANSFER_REPLACEMENTS=0
    [[ ! -L "$dest" && ( ! -e "$dest" || -d "$dest" ) ]] || return 1
    while IFS= read -r -d '' file;do
        relative="${file#"$src"/}";target="$dest/$relative";parent="${target%/*}"
        while [[ "$parent" != "$dest" ]];do
            [[ ! -L "$parent" && ( ! -e "$parent" || -d "$parent" ) ]] || return 1
            parent="${parent%/*}"
        done
        [[ ! -L "$target" && ( ! -e "$target" || -f "$target" ) ]] || {
            log error "MV: destination is a symlink or non-file; retained source '$file'";return 1;
        }
        [[ ! -f "$target" ]] || TRANSFER_REPLACEMENTS=$((TRANSFER_REPLACEMENTS+1))
        TRANSFER_FILES=$((TRANSFER_FILES+1));TRANSFER_BYTES=$((TRANSFER_BYTES+$(filesize "$file")))
    done < <(find "$src" -type f -print0)
}

mover_clear() {
    if pgrep -f '(^|/)(mover|mover\.old)([[:space:]]|$)' >/dev/null;then
        log info 'Mover active; remaining payloads retained for the next scheduled run'
        return 75
    fi
}

safe_move() {
    local src="$1" dest="$2"
    [[ -d "$src" ]] || return 0
    prepare_transfer_targets "$src" "$dest" || return 1
    if ((TRANSFER_FILES==0));then remove_empty_dirs "$src";return 0;fi
    mkdir -p -- "$dest" && chown "$OWN_USER:$OWN_GROUP" "$dest" && chmod "$DIR_MODE" "$dest" || return 1
    mover_clear || return $?
    log info "MV: transferring '$src' -> '$dest'; files=$TRANSFER_FILES bytes=$TRANSFER_BYTES same-name replacements=$TRANSFER_REPLACEMENTS"
    # --ignore-times ensures incoming content wins even with equal size/mtime.
    # Default rsync temporary-file replacement retains the old file on failure.
    rsync -a --ignore-times --remove-source-files --chown="$OWN_USER:$OWN_GROUP" \
        --chmod="D${DIR_MODE},F${FILE_MODE}" -- "$src/" "$dest/" || return 1
    RUN_TRANSFERRED_FILES=$((RUN_TRANSFERRED_FILES+TRANSFER_FILES))
    RUN_TRANSFERRED_BYTES=$((RUN_TRANSFERRED_BYTES+TRANSFER_BYTES))
    RUN_DEST_REPLACEMENTS=$((RUN_DEST_REPLACEMENTS+TRANSFER_REPLACEMENTS))
    remove_empty_dirs "$src"
    log info "MV: completed '$src'; incoming same-name files replaced their destination"
}

process_payload_file() {
    local source="$1" destination="$2" name target bytes replaced=0
    name=$(clean_name "${source##*/}" file) || return 1
    [[ -n "$name" && "$name" != . && "$name" != .. && "$name" != */* ]] || return 1
    [[ ! -L "$destination" && ( ! -e "$destination" || -d "$destination" ) ]] || return 1
    mkdir -p -- "$destination" && chown "$OWN_USER:$OWN_GROUP" "$destination" && chmod "$DIR_MODE" "$destination" || return 1
    target="$destination/$name"
    [[ ! -L "$target" && ( ! -e "$target" || -f "$target" ) ]] || return 1
    [[ ! -f "$target" ]] || replaced=1
    bytes=$(filesize "$source")
    mover_clear || return $?
    log info "MV: transferring '$source' -> '$target'; same-name replacement=$replaced"
    rsync -a --ignore-times --remove-source-files --chown="$OWN_USER:$OWN_GROUP" \
        --chmod="D${DIR_MODE},F${FILE_MODE}" -- "$source" "$target" || return 1
    RUN_TRANSFERRED_FILES=$((RUN_TRANSFERRED_FILES+1));RUN_TRANSFERRED_BYTES=$((RUN_TRANSFERRED_BYTES+bytes))
    RUN_DEST_REPLACEMENTS=$((RUN_DEST_REPLACEMENTS+replaced))
    [[ "${source##*/}" == "$name" ]] || RUN_RENAMED_FILES=$((RUN_RENAMED_FILES+1))
}


process_category() {
    local category_started=$(usr_ops_now_ms)
    local category_bytes=0 category_files=0
    local category="$1" destination="$2" source="${COMPLETE_DIR}/$1"
    local unit name target rc listing moved=0 deferred=0
    if ! has_files "$source"; then
        log info "CATEGORY: '$category' has no completed files; skipping"
        return 0
    fi
    [[ -d "$source" && ! -L "$source" && ! -L "$destination" ]] || return 1
    listing=$(mktemp "$QBIT_RUNTIME/category-units.XXXXXX") || return 1
    # Capture the worklist before changes. Units that arrive later wait only
    # until the next normal schedule, never for an age or repeated observation.
    find "$source" -mindepth 1 -maxdepth 1 -print0 >"$listing" || return 1
    while IFS= read -r -d '' unit; do
        [[ -e "$unit" || -L "$unit" ]] || continue
        mover_clear || { RUN_RETAINED_PAYLOADS=$((RUN_RETAINED_PAYLOADS+1));return 75; }
        rc=0
        payload_completion_proven "$unit" || rc=$?
        if (( rc!=0 )); then
            ((deferred++)) || true
            RUN_RETAINED_PAYLOADS=$((RUN_RETAINED_PAYLOADS+1))
            continue
        fi
        if [[ -d "$unit" ]];then name=$(clean_name "${unit##*/}" directory);else name=$(clean_name "${unit##*/}" file);fi || return 1
        [[ -n "$name" && "$name" != . && "$name" != .. && "$name" != */* ]] || return 1
        target="$destination/$name"
        [[ ! -L "$target" ]] || { log error "MV: symlink destination retained: $target"; return 1; }
        transfer_checkpoint category_intent "$unit" "$target" || return 1
        category_bytes=$((category_bytes+${QBIT_PROVEN_BYTES:-0}));category_files=$((category_files+${QBIT_PROVEN_FILES:-0}))
        # Exact unwanted names are checked before normalization changes them.
        remove_unwanted_content "$unit" || return 1
        if [[ -d "$unit" ]];then normalize_names "$unit" || return 1;fi
        rc=0
        if [[ -d "$unit" ]];then
            transfer_checkpoint moving "$unit" "$target" || return 1
            safe_move "$unit" "$target" || rc=$?
            ((rc!=0)) || rmdir -- "$unit" 2>/dev/null || true
        elif [[ -f "$unit" ]];then
            transfer_checkpoint moving "$unit" "$target" || return 1
            process_payload_file "$unit" "$destination" || rc=$?
        fi
        if ((rc==75));then
            transfer_checkpoint category_deferred "$unit" "$target" || return 1
            RUN_RETAINED_PAYLOADS=$((RUN_RETAINED_PAYLOADS+1));return 75
        fi
        ((rc==0)) || return "$rc"
        transfer_checkpoint category_complete "$unit" "$target" || return 1
        ((moved++)) || true
    done <"$listing"
    rm -f -- "$listing"
    log info "CATEGORY TIMING: '$category' elapsed=$(( $(usr_ops_now_ms)-category_started ))ms candidate-files=$category_files candidate-bytes=$category_bytes processed-units=$moved retained-units=$deferred; bytes are source observations, not measured network traffic"
    log info "CATEGORY: '$category' processed=$moved retained=$deferred; unregistered completed-folder payloads require no age or repeat observation"
}


process_private_categories() {
    local category

    for category in "${PRIVATE_CATEGORIES[@]}"; do

        process_category \
            "$category" \
            "${PRIVATE_DEST_ROOT}/${category}" ||
            return $?

    done

    return 0
}


###############################################################################
# VUETORRENT UPDATE
###############################################################################

# qBittorrent releases may contain public/index.html or a flat index.html.
# Validate referenced local JS/CSS before replacing the working checkout.
vuetorrent_valid() {
    local root="$1" web="$1" refs ref lower js=0
    local pattern="(src|href)[[:space:]]*=[[:space:]]*[\"'][^\"']+[\"']"
    [[ -d "$root" && ! -L "$root" ]] || return 1
    if [[ ! -s "$web/index.html" ]];then web="$root/public";fi
    [[ -s "$web/index.html" && ! -L "$web/index.html" && ! -L "$web" ]] || return 1
    grep -Eiq '<(!doctype|html)([[:space:]>])' "$web/index.html" || return 1
    refs=$(grep -Eio "$pattern" "$web/index.html" | sed -E "s/^[^=]*=[[:space:]]*[\"']//;s/[\"']$//") || return 1
    while IFS= read -r ref;do
        lower="${ref,,}";case "$lower" in http:*|https:*|//*|data:*) continue;;esac
        ref="${ref%%[?#]*}";ref="${ref#/}";ref="${ref#./}";lower="${ref,,}"
        case "$lower" in *.js|*.css)
            [[ "$ref" != ../* && "$ref" != */../* && "$ref" != *\\* && -s "$web/$ref" && ! -L "$web/$ref" ]] || return 1
            [[ "$lower" != *.js ]] || js=$((js+1))
        esac
    done <<<"$refs"
    ((js>0))
}

update_vuetorrent() {
    local target="${VUETORRENT_DIR}/VueTorrent"
    local new_target="${VUETORRENT_DIR}/VueTorrent.new.$$"
    local old_target="${VUETORRENT_DIR}/VueTorrent.old.$$"
    local remote_commit current_commit

    log info "------------------------------------------------------------"
    log info "VUETORRENT: updating WebUI"
    log info "------------------------------------------------------------"

    if [[ ! -d "$VUETORRENT_DIR" ]]; then

        log error \
            "VUETORRENT: WebUI directory missing '$VUETORRENT_DIR'"

        return 1
    fi


    ###########################################################################
    # Remove stale temporary paths from this PID if they somehow exist
    ###########################################################################

    rm -rf -- "$new_target" "$old_target"


    ###########################################################################
    # Clone replacement first.
    #
    # Existing VueTorrent remains untouched while GitHub is being contacted.
    ###########################################################################

    export GIT_TERMINAL_PROMPT=0
    remote_commit=$(timeout "$VUETORRENT_CLONE_TIMEOUT" git ls-remote --exit-code --heads "$VUETORRENT_REPO" "refs/heads/$VUETORRENT_BRANCH") || {
        log error 'VUETORRENT: GitHub revision check failed; current WebUI retained'
        return 1
    }
    remote_commit="${remote_commit%%[[:space:]]*}"
    [[ "$remote_commit" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ]] || return 1
    current_commit=$(git -C "$target" rev-parse --verify HEAD 2>/dev/null) || current_commit=""
    if [[ "$current_commit" == "$remote_commit" ]] && vuetorrent_valid "$target";then
        RUN_WEBUI_RESULT="current (${current_commit:0:12})"
        log info "VUETORRENT: already current at $current_commit; no download or replacement"
        return 0
    fi

    log info \
        "VUETORRENT: cloning '$VUETORRENT_BRANCH' branch"

    if ! timeout "$VUETORRENT_CLONE_TIMEOUT" \
        git clone \
            --quiet \
            --depth 1 \
            --single-branch \
            --branch "$VUETORRENT_BRANCH" \
            "$VUETORRENT_REPO" \
            "$new_target"
    then

        rm -rf -- "$new_target"

        log error \
            "VUETORRENT: clone failed or timed out"

        return 1
    fi


    if ! vuetorrent_valid "$new_target";then
        rm -rf -- "$new_target"
        log error 'VUETORRENT: staged HTML/JavaScript/CSS validation failed; working WebUI retained'
        return 1
    fi

    ###########################################################################
    # Move existing installation aside only after successful clone
    ###########################################################################

    if [[ -e "$target" ]]; then

        if ! mv -- "$target" "$old_target"; then

            rm -rf -- "$new_target"

            log error \
                "VUETORRENT: unable to stage existing installation"

            return 1
        fi
    fi


    ###########################################################################
    # Install replacement
    ###########################################################################

    if mv -- "$new_target" "$target"; then

        rm -rf -- "$old_target"

        RUN_WEBUI_RESULT="updated; HTML and referenced JS/CSS validated"
        log info \
            "VUETORRENT: update completed successfully"

        return 0
    fi


    ###########################################################################
    # Replacement failed - restore previous working installation
    ###########################################################################

    log error \
        "VUETORRENT: unable to activate new installation"

    rm -rf -- "$new_target"

    if [[ -e "$old_target" ]]; then

        if mv -- "$old_target" "$target"; then

            log warn \
                "VUETORRENT: previous installation restored"

        else

            log crit \
                "VUETORRENT: failed restoring previous installation"
        fi
    fi

    return 1
}


###############################################################################
# MAIN
###############################################################################

# Shared maintenance protocol. Hold through API/filesystem mutations so appdata
# cannot stop dependencies midway through this run. Export lock protects a
# consistent per-service operational-state snapshot, never bulk application data.
qbit_request() {
    local endpoint="$1" output="$2"
    local -a args=(--noproxy '*' --connect-timeout 4 --max-time 20 --max-filesize 16777216 --fail --silent --show-error)
    [[ "$QBIT_API_URL" == https://* && "$QBIT_API_URL" != *'@'* && "$QBIT_API_URL" != *'?'* ]] || return 1
    [[ -z "$QBIT_RESOLVE" ]] || args+=(--resolve "$QBIT_RESOLVE")
    [[ ! -f "$QBIT_HEADERS_FILE" ]] || args+=(--header "@$QBIT_HEADERS_FILE")
    curl "${args[@]}" "$QBIT_API_URL/api/v2/$endpoint" -o "$output"
}

transfer_checkpoint() {
    local phase="$1" source="${2:-}" target="${3:-}" temp
    temp=$(mktemp "$TRANSFER_STATE_DIR/.checkpoint.XXXXXX") || return 1
    jq -n --arg phase "$phase" --arg source "$source" --arg destination "$target" --argjson epoch "$(date +%s)" \
       '{schema:1,phase:$phase,source:$source,destination:$destination,epoch:$epoch,policy:"console-only; no automatic pending mutation replay"}' >"$temp" &&
       mv "$temp" "$TRANSFER_STATE_DIR/state.json" || return 1
}

payload_completion_proven() {
    local source="$1" job native mapped state complete matched=false markers
    if [[ "${QBIT_API_UNAVAILABLE:-false}" == true ]]; then
        log warn "RETAIN: API unavailable earlier in this run; payload untouched: $source"
        return 1
    fi
    if ! qbit_request torrents/info "$QBIT_RUNTIME/jobs.json" ||
       ! jq -e 'type=="array" and all(.[]; (.hash|type)=="string" and (.hash|length)>0
          and (.content_path|type)=="string" and (.content_path|startswith("/"))
          and (.progress|type)=="number" and (.amount_left|type)=="number"
          and (.state|type)=="string")' "$QBIT_RUNTIME/jobs.json" >/dev/null 2>&1; then
        QBIT_API_UNAVAILABLE=true
        log error "RETAIN: qBittorrent API unavailable or invalid; no empty-list assumption; payload untouched: $source"
        return 1
    fi
    while IFS= read -r job; do
        native=$(jq -r '.content_path' <<<"$job") || return 1
        # This host has one verified payload bind mount. Unmapped/path-traversal
        # records cannot safely rule out ownership, so defer without guessing.
        if [[ "$native" != "$QBIT_CONTAINER_ROOT/"* || "$native" == *'/../'* || "$native" == */.. || "$native" == *'/./'* ]]; then
            log warn "RETAIN: qBittorrent path cannot be mapped through configured payload root; payload untouched: $source"
            return 1
        fi
        mapped=$(realpath -m -s -- "$QBIT_HOST_ROOT/${native#"$QBIT_CONTAINER_ROOT/"}") || return 1
        if [[ "$mapped" == "$source" || "$mapped" == "$source/"* || "$source" == "$mapped/"* ]]; then
            matched=true
            state=$(jq -r '.state' <<<"$job") || return 1
            complete=$(jq -r '.progress==1 and .amount_left==0' <<<"$job") || return 1
            if [[ "$complete" != true || ! "$state" =~ ^(stoppedUP|pausedUP)$ ]]; then
                log warn "RETAIN: payload overlaps registered torrent state=$state complete=$complete; other units remain eligible: $source"
                return 1
            fi
        fi
    done < <(jq -c '.[]' "$QBIT_RUNTIME/jobs.json")
    # Never move symlinks or obvious qBittorrent partial payloads, even if the
    # corresponding record has disappeared. No timers/stability counters used.
    markers=$(mktemp "$QBIT_RUNTIME/payload-markers.XXXXXX") || return 1
    : >"$markers.stats"
    if ! find "$source" \( -type l -o -name '*.\!qB' \) -print0 -o -type f -fprintf "$markers.stats" '%s\n' >"$markers"; then
        rm -f -- "$markers"; return 1
    fi
    if [[ -s "$markers" || ( ! -f "$source" && ! -d "$source" ) ]]; then
        rm -f -- "$markers"
        log warn "RETAIN: payload contains a symlink, partial-download marker, or unsupported entry: $source"
        return 1
    fi
    IFS=' ' read -r QBIT_PROVEN_FILES QBIT_PROVEN_BYTES < <(awk '{n++;b+=$1}END{printf "%.0f %.0f\n",n,b}' "$markers.stats")
    rm -f -- "$markers" "$markers.stats"
    if [[ "$matched" == true ]]; then
        log info "ELIGIBLE: exact registered torrent is complete and stopped: $source"
    else
        log info "ELIGIBLE: unregistered payload in configured completed category; immediate scheduled transfer: $source"
    fi
}

torrent_storage_ready() {
    mountpoint -q /mnt/user && mountpoint -q /mnt/vault || { log error 'Required user/vault storage unavailable; no changes performed.'; return 1; }
    mover_clear || return $?
    [[ ! -L "$TRANSFER_STATE_DIR" ]] || return 1
    mkdir -p "$TRANSFER_STATE_DIR" || return 1
    chmod 700 "$TRANSFER_STATE_DIR" || return 1
    if [[ -f "$TRANSFER_STATE_DIR/state.json" ]]; then
        jq -e '.schema==1 and (.phase|type)=="string"' "$TRANSFER_STATE_DIR/state.json" >/dev/null || return 1
        local phase
        phase=$(jq -r .phase "$TRANSFER_STATE_DIR/state.json")
        if [[ "$phase" != complete && "$phase" != webui_failed && "$phase" != category_complete && "$phase" != category_deferred ]]; then
            log error "Previous transfer checkpoint=$phase is unfinished. Files preserved; inspect exact recorded source/destination before retrying. No automatic ambiguous replay."
            return 1
        fi
    fi
    QBIT_RUNTIME=$(mktemp -d /tmp/media_torrent_management.XXXXXX) || return 1
    trap 'rm -rf -- "$QBIT_RUNTIME"' EXIT
}

refresh_vuetorrent_if_due() {
    local last=0 now
    [[ ! -f "$TRANSFER_STATE_DIR/webui-updated-at" ]] || read -r last <"$TRANSFER_STATE_DIR/webui-updated-at"
    [[ "$last" =~ ^[0-9]+$ ]] || return 1
    now=$(date +%s)
    if (( now>=last && now-last<604800 )); then RUN_WEBUI_RESULT='not due';log info 'VueTorrent refresh not due; data processing outcome remains independent.'; return 0; fi
    update_vuetorrent || { RUN_WEBUI_RESULT="check/update failed; current WebUI retained";return 1; }
    printf '%s\n' "$now" >"$TRANSFER_STATE_DIR/.webui-updated-at" && mv "$TRANSFER_STATE_DIR/.webui-updated-at" "$TRANSFER_STATE_DIR/webui-updated-at"
}

# Expiring updater handoff: current operations finish; new conflicting work
# yields before reading/mutating app state. Never deletes or overrides a lock.
app_update_requested() {
    local scope="$1" file now boot seen=0
    now=$(date +%s);boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) || return 1
    for file in "${APP_UPDATE_REQUEST_DIR:-/run/docker-update-requests}/"*.json;do
        [[ -f "$file" && ! -L "$file" ]] || continue
        seen=$((seen+1));((seen<=128)) || break
        (( $(stat -c %s "$file" 2>/dev/null || printf 999999)<=8192 )) || continue
        if jq -e --arg scope "$scope" --arg boot "$boot" --argjson now "$now" '
          .schema==1 and .owner=="system_update_coordinator" and .boot==$boot and
          (.expires|type)=="number" and .expires>$now and .expires<=$now+1200 and
          (.scopes|type)=="array" and (.scopes|index($scope))!=null' "$file" >/dev/null 2>&1;then return 0;fi
    done
    return 1
}

acquire_operation_coordination() {
    local now until version_file="${UNRAID_VERSION_FILE:-/etc/unraid-version}" version
    if [[ -r "$version_file" ]]; then
        version=$(sed -n 's/^version="\([^"]*\)"/\1/p' "$version_file")
        if [[ "$version" != 7.* ]]; then printf 'Unvalidated Unraid version %s; mutations deferred pending compatibility validation.\n' "$version" >&2; return 75; fi
    fi
    exec {ARR_OPERATION_FD}>"${ARR_BACKUP_GATE:-/run/arr-appdata-coordination.lock}" || return 1
    flock -s -n "$ARR_OPERATION_FD" || return 75
    app_update_requested torrent && return 75
    now=$(date +%s)
    until=$(cat "${ARR_BACKUP_GRACE:-/run/arr-appdata-recovery-until}" 2>/dev/null || true)
    if [[ "$until" =~ ^[0-9]+$ ]] && (( until>now && until<=now+120 )); then return 75; fi
    exec {STATE_EXPORT_FD}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || return 1
    flock -s -n "$STATE_EXPORT_FD" || return 75
}

main() {
    case "${1:-}" in
        --version) printf 'media_torrent_management.sh %s\n' "$SCRIPT_VERSION"; return 0;;
        --help|-h) printf '%s\n' 'Usage: bash script [--help|--version]' 'Normal run: console-only processing of configured categories, one top-level download/file at a time.' 'Unregistered completed-folder payloads move immediately at the schedule; no age or repeat-scan delay in either phase.' 'Active/incomplete/checking/seeding torrents, symlinks and partial markers are preserved. API failure defers transfers. Same-name destination files are replaced; no .dup copies are created. Unwanted files are removed before source renaming and rsync.' 'Unfinished checkpoints require review before retry. VueTorrent refresh is weekly and independent of transfers.'; return 0;;
        "") ;;
        *) printf 'Unknown option: %s; use --help.\n' "$1" >&2; return 2;;
    esac
    ###########################################################################
    # Environment validation
    ###########################################################################

    local coordination_rc=0
    acquire_operation_coordination || coordination_rc=$?
    if (( coordination_rc==75 )); then printf 'MAINTENANCE: run deferred for appdata/startup/state export; no mutations performed.\n'; return 0; fi
    (( coordination_rc==0 )) || return 1

    require_commands \
        curl jq mountpoint pgrep mktemp realpath \
        flock \
        find \
        grep \
        rsync \
        stat \
        sed \
        awk \
        sha256sum \
        numfmt \
        git \
        timeout \
        id \
        mkdir \
        mv \
        rm \
        chown \
        chmod \
        dirname \
        rmdir \
        basename ||
        finish 1 "Required command validation failed"

    validate_configuration ||
        finish 1 "Configuration validation failed"


    ###########################################################################
    # Lock
    ###########################################################################

    exec 9>"$LOCK_FILE" ||
        finish 1 "Unable to open lock file: $LOCK_FILE"

    if ! flock -n 9; then

        finish 1 \
            "Another data management run is already active (lock: $LOCK_FILE)"
    fi


    local storage_rc=0
    torrent_storage_ready || storage_rc=$?
    if (( storage_rc==75 )); then return 0; fi
    (( storage_rc==0 )) || return 1

    ###########################################################################
    # Build filename cleanup rules
    ###########################################################################

    build_rename_rules


    ###########################################################################
    # Start
    ###########################################################################

    log info "============================================================"
    log info "Data Management v$SCRIPT_VERSION started"
    log info "Completed dir : $COMPLETE_DIR"
    log info "Destination   : $DEST_DIR"
    log info "============================================================"


    ###########################################################################
    # Nothing completed yet
    #
    # This is normal for a scheduled script and therefore exit 0.
    ###########################################################################

    if [[ ! -d "$COMPLETE_DIR" ]] ||
       ! has_files "$COMPLETE_DIR"
    then

        refresh_vuetorrent_if_due || { transfer_checkpoint webui_failed; finish 0 "No completed files; VueTorrent refresh failed independently; existing Web UI retained"; }
        transfer_checkpoint complete || return 1
        finish 0 "No completed downloads found; nothing to process"
    fi


    ###########################################################################
    # Validate qBittorrent category routing BEFORE modifying anything
    ###########################################################################

    validate_complete_layout ||
        finish 1 \
            "Completed-download category validation failed"


    ###########################################################################
    # Phase 1 - ポルノ
    ###########################################################################

    log info "PHASE 1: processing '$PORN_CATEGORY'"

    local transfer_rc=0
    process_category "$PORN_CATEGORY" "$PORN_DEST" || transfer_rc=$?
    ((transfer_rc!=75)) || finish 0 'Mover detected; remaining downloads retained; VueTorrent check deferred'
    ((transfer_rc==0)) || finish 1 "Processing failed for '$PORN_CATEGORY'; VueTorrent update skipped"


    ###########################################################################
    # Phase 2 - private performer categories
    ###########################################################################

    log info "PHASE 2: processing private performer categories"

    transfer_rc=0;process_private_categories || transfer_rc=$?
    ((transfer_rc!=75)) || finish 0 'Mover detected; remaining downloads retained; VueTorrent check deferred'
    ((transfer_rc==0)) || finish 1 'Private-category processing failed; VueTorrent update skipped'


    ###########################################################################
    # Phase 3 - VueTorrent
    #
    # This point is reached only if all data-processing phases succeeded.
    ###########################################################################

    log info "PHASE 3: checking VueTorrent"
    mover_clear || finish 0 'Mover detected; VueTorrent check deferred'

    if ! refresh_vuetorrent_if_due; then
        transfer_checkpoint webui_failed || return 1
        finish 0 "Data processing completed; VueTorrent update failed independently and existing Web UI was retained"
    fi
    transfer_checkpoint complete || return 1


    ###########################################################################
    # Complete
    ###########################################################################

    finish 0 \
        "Data Management v$SCRIPT_VERSION completed successfully"
}


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi