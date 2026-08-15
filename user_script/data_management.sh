#!/bin/bash

###############################################################################
# Data Management v2
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
#   2. Clean configured strings from file/directory names.
#   3. Remove unwanted files.
#   4. Move ポルノ content to its destination.
#   5. Move private performer categories to their individual destinations.
#   6. Update VueTorrent only after all data processing succeeds.
#
#
# SAFETY
# ------
# - The incomplete directory is never scanned or modified.
# - Only explicitly configured qBittorrent categories are processed.
# - Unknown non-empty categories stop the script before anything is moved.
# - Existing destination files are never silently overwritten.
# - Identical duplicates are removed from the source.
# - Different files with the same destination name are preserved as .dupN.
# - VueTorrent is updated only after successful data processing.
#
#
# REQUIREMENTS
# ------------
# Intended for Unraid User Scripts.
#
###############################################################################

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


# ---------------------------------------------------------------------------
# Runtime / locking
# ---------------------------------------------------------------------------

LOCK_FILE="/tmp/data_management.lock"

LOG_MIN_LEVEL="info"


###############################################################################
# RUNTIME STATE
###############################################################################

START_TS=$(date +%s)

SAFE_MOVE_LAST_BYTES=0

RENAME_SED_ARGS=()


###############################################################################
# LOGGING / RUNTIME HELPERS
###############################################################################

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}


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
        debug)
            printf '%s DEBUG: %s\n' "$(timestamp)" "$msg"
            ;;
        info)
            printf '%s %s\n' "$(timestamp)" "$msg"
            ;;
        warn)
            printf '%s WARN: %s\n' "$(timestamp)" "$msg" >&2
            ;;
        error)
            printf '%s ERROR: %s\n' "$(timestamp)" "$msg" >&2
            ;;
        crit)
            printf '%s CRIT: %s\n' "$(timestamp)" "$msg" >&2
            ;;
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


tree_bytes() {
    local dir="$1"

    local total=0
    local file
    local size

    [[ -d "$dir" ]] || {
        echo 0
        return 0
    }

    while IFS= read -r -d '' file; do
        size=$(filesize "$file")
        total=$((total + size))
    done < <(
        find "$dir" -type f -print0 2>/dev/null
    )

    echo "$total"
}


is_same_file() {
    local file_a="$1"
    local file_b="$2"

    local size_a
    local size_b
    local hash_a
    local hash_b

    [[ -f "$file_a" ]] || return 1
    [[ -f "$file_b" ]] || return 1

    size_a=$(filesize "$file_a")
    size_b=$(filesize "$file_b")

    [[ "$size_a" == "$size_b" ]] || return 1

    hash_a=$(sha256sum -- "$file_a" | awk '{print $1}')
    hash_b=$(sha256sum -- "$file_b" | awk '{print $1}')

    [[ "$hash_a" == "$hash_b" ]]
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
    #   123ch1080p    -> 1231080p
    #
    # Normal words containing "ch" remain untouched.
    ###########################################################################

    RENAME_SED_ARGS+=(
        -e 's/([0-9])ch/\1/g'
    )
}


clean_name() {
    local value="$1"

    printf '%s' "$value" |
        sed -E "${RENAME_SED_ARGS[@]}"
}


resolve_collision() {
    local base="$1"

    local candidate="$base"
    local i=1

    while [[ -e "$candidate" ]]; do
        candidate="${base}.dup${i}"
        ((i++))
    done

    printf '%s' "$candidate"
}


normalize_names() {
    local root="$1"

    local entry
    local parent
    local old_name
    local new_name
    local new_path

    local had_error=0
    local renamed_dirs=0
    local renamed_files=0
    local removed_duplicates=0

    [[ -d "$root" ]] || return 0

    log info "REN: normalizing names under '$root'"

    ###########################################################################
    # Pass 1 - directories
    #
    # Directories are processed depth-first so children are renamed before
    # their parents.
    ###########################################################################

    while IFS= read -r -d '' entry; do

        [[ -d "$entry" ]] || continue

        parent=$(dirname -- "$entry")
        old_name=$(basename -- "$entry")
        new_name=$(clean_name "$old_name")

        [[ "$new_name" != "$old_name" ]] || continue

        if [[ -z "$new_name" ]]; then

            log warn \
                "REN: cleanup would create an empty directory name; skipping '$entry'"

            had_error=1
            continue
        fi

        new_path="$parent/$new_name"

        if [[ -e "$new_path" ]]; then
            new_path=$(resolve_collision "$new_path")
        fi

        if mv -n -- "$entry" "$new_path"; then

            log info \
                "REN: directory '$old_name' -> '$(basename -- "$new_path")'"

            ((renamed_dirs++))

        else

            log error \
                "REN: failed directory rename '$entry' -> '$new_path'"

            had_error=1
        fi

    done < <(
        find "$root" \
            -depth \
            -mindepth 1 \
            -type d \
            -print0 2>/dev/null
    )


    ###########################################################################
    # Pass 2 - files
    #
    # This is a single filesystem scan regardless of the number of configured
    # rename patterns.
    ###########################################################################

    while IFS= read -r -d '' entry; do

        [[ -f "$entry" ]] || continue

        parent=$(dirname -- "$entry")
        old_name=$(basename -- "$entry")
        new_name=$(clean_name "$old_name")

        [[ "$new_name" != "$old_name" ]] || continue

        if [[ -z "$new_name" ]]; then

            log warn \
                "REN: cleanup would create an empty filename; skipping '$entry'"

            had_error=1
            continue
        fi

        new_path="$parent/$new_name"


        #######################################################################
        # Renamed destination already exists
        #######################################################################

        if [[ -e "$new_path" ]]; then

            if [[ -f "$new_path" ]] &&
               is_same_file "$entry" "$new_path"
            then

                log info \
                    "REN: identical renamed file already exists; removing duplicate '$entry'"

                if rm -f -- "$entry"; then
                    ((removed_duplicates++))
                else
                    log error \
                        "REN: failed removing duplicate '$entry'"
                    had_error=1
                fi

                continue
            fi

            new_path=$(resolve_collision "$new_path")
        fi


        #######################################################################
        # Rename
        #######################################################################

        if mv -n -- "$entry" "$new_path"; then

            log info \
                "REN: file '$old_name' -> '$(basename -- "$new_path")'"

            ((renamed_files++))

        else

            log error \
                "REN: failed file rename '$entry' -> '$new_path'"

            had_error=1
        fi

    done < <(
        find "$root" \
            -type f \
            -print0 2>/dev/null
    )

    log info \
        "REN: completed dirs=$renamed_dirs files=$renamed_files duplicates_removed=$removed_duplicates"

    (( had_error == 0 ))
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

    [[ -d "$root" ]] || return 0

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

            ((removed_count++))
            removed_bytes=$((removed_bytes + size))

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

prepare_move_collisions() {
    local src="$1"
    local dest="$2"

    local src_file
    local relative_path
    local dest_file

    local collision_src
    local collision_dest

    local i

    while IFS= read -r -d '' src_file; do

        relative_path="${src_file#"$src"/}"
        dest_file="$dest/$relative_path"


        #######################################################################
        # Destination does not exist
        #######################################################################

        [[ -e "$dest_file" ]] || continue


        #######################################################################
        # Existing destination is identical
        #######################################################################

        if [[ -f "$dest_file" ]] &&
           is_same_file "$src_file" "$dest_file"
        then

            log info \
                "MV: identical destination exists; removing source duplicate '$src_file'"

            if ! rm -f -- "$src_file"; then
                log error \
                    "MV: failed removing duplicate source '$src_file'"
                return 1
            fi

            continue
        fi


        #######################################################################
        # Destination exists but differs.
        #
        # Never overwrite it.
        #
        # Rename the source to:
        #
        #   filename.ext.dup1
        #   filename.ext.dup2
        #   ...
        #######################################################################

        i=1

        while :; do

            collision_src="${src_file}.dup${i}"
            collision_dest="${dest_file}.dup${i}"

            if [[ ! -e "$collision_src" &&
                  ! -e "$collision_dest" ]]
            then
                break
            fi

            ((i++))
        done

        log warn \
            "MV: destination collision '$dest_file'; preserving incoming file as '$(basename -- "$collision_dest")'"

        if ! mv -n -- "$src_file" "$collision_src"; then

            log error \
                "MV: failed preparing collision file '$src_file'"

            return 1
        fi

    done < <(
        find "$src" \
            -type f \
            -print0 2>/dev/null
    )

    return 0
}


safe_move() {
    local src="$1"
    local dest="$2"

    local transfer_bytes

    SAFE_MOVE_LAST_BYTES=0

    if [[ ! -d "$src" ]]; then
        log debug "MV: source category missing '$src'"
        return 0
    fi

    if ! has_files "$src"; then

        log info \
            "MV: source category empty '$src'"

        remove_empty_dirs "$src"

        return 0
    fi


    ###########################################################################
    # Handle destination collisions before rsync
    ###########################################################################

    prepare_move_collisions "$src" "$dest" || return 1


    ###########################################################################
    # Duplicate cleanup may have removed all files
    ###########################################################################

    if ! has_files "$src"; then

        log info \
            "MV: no files remain after duplicate cleanup '$src'"

        remove_empty_dirs "$src"

        return 0
    fi


    ###########################################################################
    # Calculate transfer size after duplicate cleanup / collision handling
    ###########################################################################

    transfer_bytes=$(tree_bytes "$src")


    ###########################################################################
    # Ensure category destination exists
    #
    # Only the destination used by this run is touched. There is no recursive
    # permission sweep across the existing Plex library.
    ###########################################################################

    if ! mkdir -p -- "$dest"; then

        log error \
            "MV: unable to create destination '$dest'"

        return 1
    fi

    if ! chown "$OWN_USER:$OWN_GROUP" "$dest"; then

        log error \
            "MV: unable to set ownership on '$dest'"

        return 1
    fi

    if ! chmod "$DIR_MODE" "$dest"; then

        log error \
            "MV: unable to set permissions on '$dest'"

        return 1
    fi


    ###########################################################################
    # Transfer complete tree
    #
    # rsync itself applies ownership and permissions to transferred content.
    #
    # No --progress:
    #   avoids noisy scheduled-script logs.
    #
    # No --checksum:
    #   duplicate comparison was already performed above.
    #
    # No --inplace / --partial:
    #   avoids leaving a destination file looking valid after an interrupted
    #   partial transfer.
    ###########################################################################

    log info \
        "MV: transferring '$src' -> '$dest' size=$(human_readable "$transfer_bytes")"

    if ! rsync \
        -a \
        --remove-source-files \
        --chown="${OWN_USER}:${OWN_GROUP}" \
        --chmod="D${DIR_MODE},F${FILE_MODE}" \
        -- \
        "$src/" \
        "$dest/"
    then

        log error \
            "MV: rsync failed '$src' -> '$dest'"

        return 1
    fi


    ###########################################################################
    # rsync --remove-source-files removes files, not directories
    ###########################################################################

    remove_empty_dirs "$src"

    log info \
        "MV: completed '$src' transferred=$(human_readable "$transfer_bytes")"

    return 0
}


###############################################################################
# CATEGORY PROCESSING
###############################################################################

process_category() {
    local category="$1"
    local destination="$2"

    local source="${COMPLETE_DIR}/${category}"

    if ! has_files "$source"; then

        log info \
            "CATEGORY: '$category' has no completed files; skipping"

        return 0
    fi

    log info "------------------------------------------------------------"
    log info "CATEGORY: processing '$category'"
    log info "CATEGORY: source      '$source'"
    log info "CATEGORY: destination '$destination'"
    log info "------------------------------------------------------------"


    ###########################################################################
    # Normalize names
    ###########################################################################

    normalize_names "$source" || {
        log error \
            "CATEGORY: filename normalization failed for '$category'"
        return 1
    }


    ###########################################################################
    # Remove unwanted content
    ###########################################################################

    remove_unwanted_content "$source" || {
        log error \
            "CATEGORY: unwanted-file cleanup failed for '$category'"
        return 1
    }


    ###########################################################################
    # Cleanup may legitimately remove everything
    ###########################################################################

    if ! has_files "$source"; then

        log info \
            "CATEGORY: '$category' contains no files after cleanup"

        return 0
    fi


    ###########################################################################
    # Move
    ###########################################################################

    safe_move "$source" "$destination" || {
        log error \
            "CATEGORY: move failed for '$category'"
        return 1
    }

    return 0
}


process_private_categories() {
    local category

    for category in "${PRIVATE_CATEGORIES[@]}"; do

        process_category \
            "$category" \
            "${PRIVATE_DEST_ROOT}/${category}" ||
            return 1

    done

    return 0
}


###############################################################################
# VUETORRENT UPDATE
###############################################################################

update_vuetorrent() {
    local target="${VUETORRENT_DIR}/VueTorrent"
    local new_target="${VUETORRENT_DIR}/VueTorrent.new.$$"
    local old_target="${VUETORRENT_DIR}/VueTorrent.old.$$"

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

main() {
    ###########################################################################
    # Environment validation
    ###########################################################################

    require_commands \
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


    ###########################################################################
    # Build filename cleanup rules
    ###########################################################################

    build_rename_rules


    ###########################################################################
    # Start
    ###########################################################################

    log info "============================================================"
    log info "Data Management v2 started"
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

        finish 0 \
            "No completed downloads found; nothing to process"
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

    process_category \
        "$PORN_CATEGORY" \
        "$PORN_DEST" ||
        finish 1 \
            "Processing failed for '$PORN_CATEGORY'; VueTorrent update skipped"


    ###########################################################################
    # Phase 2 - private performer categories
    ###########################################################################

    log info "PHASE 2: processing private performer categories"

    process_private_categories ||
        finish 1 \
            "Private-category processing failed; VueTorrent update skipped"


    ###########################################################################
    # Phase 3 - VueTorrent
    #
    # This point is reached only if all data-processing phases succeeded.
    ###########################################################################

    log info "PHASE 3: updating VueTorrent"

    update_vuetorrent ||
        finish 1 \
            "Data processing succeeded but VueTorrent update failed"


    ###########################################################################
    # Complete
    ###########################################################################

    finish 0 \
        "Data Management v2 completed successfully"
}


main "$@"