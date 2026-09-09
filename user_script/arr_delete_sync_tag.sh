#!/usr/bin/env bash
#
# Sonarr + Radarr - Plex Delete Sync and Tagger
#
# Once-daily, persistent-state deletion confirmation for Sonarr and Radarr.
# Sonarr can unmonitor confirmed deleted episodes/seasons and optionally a
# fully deleted series. Radarr only adds an audit tag. Requirements: bash 4+,
# curl, jq.

set -uo pipefail
IFS=$'\n\t'
umask 077

###############################################################################
# CONFIGURATION
###############################################################################

# All active state, logs, and locks live below this one directory. Sonarr and
# Radarr retain separate state files because their schemas and actions differ.
RUNTIME_DIR="/mnt/user/cloud/logs/script/arr_delete_sync_tag"
LOG_FILE="$RUNTIME_DIR/arr-delete-sync-tag.log"
LOCK_DIR="$RUNTIME_DIR/arr-delete-sync-tag.lock"
SONARR_STATE_FILE="$RUNTIME_DIR/sonarr-state.json"
SONARR_STATE_BACKUP="$RUNTIME_DIR/sonarr-state.json.bak"
RADARR_STATE_FILE="$RUNTIME_DIR/radarr-state.json"
RADARR_STATE_BACKUP="$RUNTIME_DIR/radarr-state.json.bak"
NOTIFICATION_STATE_FILE="$RUNTIME_DIR/notification-state.json"

# No trailing slash. Each application keeps its own API key.
SONARR_URL="http://192.168.50.4:8989"
SONARR_API_KEY="PUT_YOUR_SONARR_API_KEY_HERE"
RADARR_URL="http://192.168.50.4:7878"
RADARR_API_KEY="PUT_YOUR_RADARR_API_KEY_HERE"

# Keep true for at least two scheduled runs before changing it to false.
# Dry-run still creates state and confirms candidates, but never changes either
# application. One switch keeps both workflows in the same operating mode.
DRY_RUN=true
CONFIRMATION_RUNS=2

# A single optional freshness policy applies to both applications. Enabling it
# requests an all-library RescanSeries and RescanMovie before snapshots. This
# can spin up media disks and significantly extend the run.
TRIGGER_LIBRARY_RESCAN=false
RESCAN_TIMEOUT_SECONDS=7200
RESCAN_POLL_SECONDS=10

# Both workflows record application-native delete history when available.
# History is supporting audit evidence by default because it can be pruned and
# does not prove Plex initiated the deletion.
INSPECT_DELETE_HISTORY=true
REQUIRE_DELETE_HISTORY_EVENT=false
MAX_HISTORY_INSPECTIONS_PER_RUN=50

# Sonarr actions.
SONARR_UNMONITOR_SEASON=true

# Default-off final safeguard.  When true, a series can be unmonitored only
# after the state proves it once had downloaded media, every such file has a
# confirmed deletion, no current episode has a file or remains monitored, and
# every normal season is already (or is being) unmonitored.  Specials/Season 0
# do not block this action.  The script NEVER disables a series with no proven
# download history in its state file.
SONARR_UNMONITOR_SERIES=false

# Sonarr tags are series-level only.  The first tag means one or more seasons
# of that series were unmonitored after a Plex deletion; it does NOT mean that
# the entire series was deleted.  The second tag is added only if this script
# unmonitors the series itself.  Existing series tags are always preserved.
PLEX_DELETED_SEASON_TAG="plex-deleted-season"
PLEX_DELETED_SERIES_TAG="plex-deleted-series"

# Radarr actions. A missing file becomes a candidate only after Radarr has also
# unmonitored the movie, matching Radarr's Unmonitor Deleted Movies behaviour.
RADARR_REQUIRE_MOVIE_UNMONITORED=true
PLEX_DELETED_MOVIE_TAG="plex-deleted"

# Kodi sidecar quarantine. While media exists, the script records recognized
# NFO, artwork, and external subtitle files. After the whole movie or series is
# confirmed fileless, surviving unchanged files are moved into the existing
# quarantine_lifecycle.sh layout. Recognized sidecars created after the original
# capture must remain unchanged across two cleanup runs before they are moved.
# Other media-linked extras remain the responsibility of Sonarr/Radarr and their
# Recycling Bin setting.
QUARANTINE_KODI_SIDECARS=true
CAPTURE_LATE_KODI_SIDECARS=true
QUARANTINE_ROOT="/mnt/user/media/bin"
# Normalize only QUARANTINE_ROOT and its contents. Supplying an owner without a
# group deliberately preserves each entry's existing group ownership.
QUARANTINE_OWNER="nobody"
QUARANTINE_DIRECTORY_MODE="0755"
QUARANTINE_FILE_MODE="0644"
MOVIES_ROOT="/mnt/user/media/movies"
SERIES_ROOT="/mnt/user/media/series"

# Root paths exactly as Sonarr/Radarr return them through their APIs. Keep them
# equal to the host roots above when the containers use identical paths. For a
# typical remap, use values such as /tv and /movies here; only the suffix below
# each root is transferred to the matching host root.
SONARR_API_SERIES_ROOT="/data/series"
RADARR_API_MOVIES_ROOT="/data/movies"

REQUIRE_SIDECAR_HASH_MATCH=true
REMOVE_EMPTY_MEDIA_FOLDERS=true
# Show a bounded list of files, links, or other non-directory entries that
# prevent rmdir-only cleanup. The manifest remains pending until they are gone.
CLEANUP_REMAINING_LOG_MAX_ITEMS=10
# Let API/state work continue, but defer sidecar moves and rmdir cleanup while
# Unraid Mover is active. Pending manifests remain eligible for the next run.
DEFER_SIDECAR_CLEANUP_WHILE_MOVER=true
MAX_SIDECAR_SIZE_MB=100

# One notification is rendered after both application workflows finish. A run
# with no actions or attention items sends nothing. Unchanged folder blockers
# are state-suppressed until their contents change or cleanup resolves.
SEND_GROUPED_NOTIFICATIONS=true
NOTIFY_DRY_RUN=false
NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
NOTIFICATION_MAX_ITEMS=25
NOTIFICATION_ITEM_MAX_CHARS=600

# A progress line is written for the first series and then every N series, so
# a long library inspection is visibly active without filling the log.
PROGRESS_LOG_EVERY=25

MAX_LOG_SIZE_MB=10
MAX_LOG_FILES=5
HTTP_CONNECT_TIMEOUT=10
HTTP_MAX_TIME=90
HTTP_RETRIES=2
USER_AGENT="Arr-Delete-Sync-Tag/1.6"

###############################################################################
# END CONFIGURATION
###############################################################################

APP_CONTEXT="MAIN"
LOCK_HELD=false
WORK_STATE=""
CURRENT_SNAPSHOT_FILE=""
SIDECAR_BATCH_FILE=""
SIDECAR_ENTRY_FILE=""
ARR_NAME=""
ARR_URL=""
ARR_API_KEY=""
ARR_TEMP_PREFIX=""
ARR_USER_AGENT=""
QUARANTINE_RUN_ID=""
NOTIFICATION_BATCH=""

SIDECARS_CAPTURED=0
SIDECARS_QUARANTINED=0
SIDECARS_NATIVE_MISSING=0
SIDECARS_CHANGED=0
SIDECARS_LATE_CANDIDATES=0
SIDECARS_LATE_CONFIRMED=0
SIDECAR_FAILURES=0
FOLDERS_REMOVED=0
FOLDER_CLEANUP_PENDING=0
MOVER_DEFERRALS=0
MOVER_GUARD_NOTICE_LOGGED=false

CLEANUP_COMPLETE=false
CLEANUP_FOLDER_PENDING=false
CLEANUP_QUARANTINED=0
CLEANUP_NATIVE_MISSING=0
CLEANUP_CHANGED=0
CLEANUP_FOLDERS_REMOVED=0
CLEANUP_PROGRESS_QUARANTINED=0
CLEANUP_PROGRESS_NATIVE_MISSING=0
CLEANUP_PROGRESS_FOLDERS_REMOVED=0
CLEANUP_QUARANTINE_RUN_ID=""
CLEANUP_LATE_CANDIDATES='[]'
CLEANUP_LATE_CANDIDATE_COUNT=0
CLEANUP_LATE_CONFIRMED_COUNT=0
CLEANUP_BLOCKER_COUNT=0
CLEANUP_BLOCKER_DETAILS=""

log() {
    local level="$1"
    shift
    printf '[%s] [%s] [%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$APP_CONTEXT" "$level" "$*" |
        tee -a "$LOG_FILE" >&2
}

notification_hash() {
    printf '%s' "$1" | sha256sum | cut -d ' ' -f 1
}

strip_notification_emoji() {
    printf '%s' "$1" | jq -Rs -r '
        explode
        | map(
            select(
                . != 8205
                and . != 8419
                and . != 65039
                and (. < 9728 or . > 10175)
                and (. < 126976 or . > 129791)
            )
          )
        | implode
        '
}

initialize_grouped_notifications() {
    local next invalid_backup

    [[ "$SEND_GROUPED_NOTIFICATIONS" == true ]] || return 0

    if [[ -f "$NOTIFICATION_STATE_FILE" ]] &&
       ! jq -e 'type == "object" and ((.attention // {}) | type == "object")' \
            "$NOTIFICATION_STATE_FILE" >/dev/null 2>&1; then
        invalid_backup="${NOTIFICATION_STATE_FILE}.invalid.$(date '+%Y%m%d_%H%M%S')"
        cp -f -- "$NOTIFICATION_STATE_FILE" "$invalid_backup" 2>/dev/null || true
        log WARNING "Invalid grouped-notification state was archived and will be rebuilt: $invalid_backup"
        rm -f -- "$NOTIFICATION_STATE_FILE"
    fi

    if [[ ! -f "$NOTIFICATION_STATE_FILE" ]]; then
        next="$(mktemp "$RUNTIME_DIR/.notification-state.XXXXXX")" || return 1
        printf '%s\n' '{"version":1,"attention":{},"lastSentAt":null}' > "$next" || {
            rm -f -- "$next"
            return 1
        }
        mv -f -- "$next" "$NOTIFICATION_STATE_FILE" || return 1
    fi

    NOTIFICATION_BATCH="$(mktemp "$RUNTIME_DIR/.notification-batch.XXXXXX")" || return 1
    : > "$NOTIFICATION_BATCH"
}

append_notification_record() {
    local event="$1"
    local severity="$2"
    local app_name="$3"
    local key="$4"
    local signature="$5"
    local title="$6"
    local detail="$7"

    [[ "$SEND_GROUPED_NOTIFICATIONS" == true ]] || return 0
    [[ -n "$NOTIFICATION_BATCH" && -f "$NOTIFICATION_BATCH" ]] || return 0

    jq -cn \
        --arg event "$event" \
        --arg severity "$severity" \
        --arg app "$app_name" \
        --arg key "$key" \
        --arg signature "$signature" \
        --arg title "$title" \
        --arg detail "$detail" \
        '{
            event: $event,
            severity: $severity,
            app: $app,
            key: $key,
            signature: $signature,
            title: $title,
            detail: $detail
        }' >> "$NOTIFICATION_BATCH"
}

queue_action_notification() {
    local app_name="$1"
    local title="$2"
    local detail="$3"

    if [[ "$DRY_RUN" == true ]]; then
        [[ "$NOTIFY_DRY_RUN" == true ]] || return 0
        title="DRY RUN: $title"
    fi

    append_notification_record action INFO "$app_name" "" "" "$title" "$detail"
}

queue_attention_notification() {
    local severity="$1"
    local app_name="$2"
    local title="$3"
    local detail="$4"

    append_notification_record attention "$severity" "$app_name" "" "" "$title" "$detail"
}

queue_folder_blocker_notification() {
    local app_name="$1"
    local item_id="$2"
    local title="$3"
    local media_path="$4"
    local key signature previous
    local detail

    [[ "$SEND_GROUPED_NOTIFICATIONS" == true ]] || return 0
    [[ -n "$NOTIFICATION_BATCH" && -f "$NOTIFICATION_BATCH" ]] || return 0

    key="folder:${app_name,,}:${item_id}"
    detail="Directory: ${media_path}"$'\n'
    detail+="Blocking entries: ${CLEANUP_BLOCKER_COUNT}"
    if (( CLEANUP_LATE_CANDIDATE_COUNT > 0 )); then
        detail+=$'\n'"Recognized late sidecars awaiting next-run confirmation: ${CLEANUP_LATE_CANDIDATE_COUNT}"
    fi
    [[ -n "$CLEANUP_BLOCKER_DETAILS" ]] && detail+=$'\n'"${CLEANUP_BLOCKER_DETAILS}"
    signature="$(notification_hash "$media_path|$CLEANUP_BLOCKER_COUNT|$CLEANUP_LATE_CANDIDATE_COUNT|$CLEANUP_BLOCKER_DETAILS")"
    previous="$(jq -r --arg key "$key" '.attention[$key].signature // ""' \
        "$NOTIFICATION_STATE_FILE" 2>/dev/null || true)"

    [[ "$previous" != "$signature" ]] || return 0
    if jq -e --arg key "$key" 'select(.key == $key)' "$NOTIFICATION_BATCH" \
        >/dev/null 2>&1; then
        return 0
    fi

    append_notification_record attention WARNING "$app_name" "$key" \
        "$signature" "$title" "$detail"
}

queue_folder_resolution_notification() {
    local app_name="$1"
    local item_id="$2"
    local title="$3"
    local media_path="$4"
    local key

    [[ "$SEND_GROUPED_NOTIFICATIONS" == true ]] || return 0
    [[ -n "$NOTIFICATION_BATCH" && -f "$NOTIFICATION_BATCH" ]] || return 0

    key="folder:${app_name,,}:${item_id}"
    jq -e --arg key "$key" '.attention[$key] != null' "$NOTIFICATION_STATE_FILE" \
        >/dev/null 2>&1 || return 0

    append_notification_record resolved INFO "$app_name" "$key" "" \
        "$title" "Pending directory cleanup completed: $media_path"
}

queue_cleanup_action_notification() {
    local app_name="$1"
    local title="$2"
    local media_path="$3"
    local detail=""

    (( CLEANUP_QUARANTINED > 0 || CLEANUP_FOLDERS_REMOVED > 0 )) || return 0

    detail="Sidecars quarantined: ${CLEANUP_QUARANTINED}; empty directories removed: ${CLEANUP_FOLDERS_REMOVED}."
    if (( CLEANUP_LATE_CONFIRMED_COUNT > 0 )); then
        detail+=$'\n'"Late sidecars confirmed unchanged and quarantined: ${CLEANUP_LATE_CONFIRMED_COUNT}."
    fi
    detail+=$'\n'"Media path: ${media_path}"
    queue_action_notification "$app_name" "$title cleanup" "$detail"
}

mark_notification_batch_delivered() {
    local delivered_file="$1"
    local next now

    now="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    next="$(mktemp "$RUNTIME_DIR/.notification-state.XXXXXX")" || return 1

    if ! jq --arg now "$now" --slurpfile events "$delivered_file" '
        .version = 1
        | .attention //= {}
        | reduce $events[] as $event (.;
            if $event.event == "attention" and $event.key != "" then
                .attention[$event.key] = {
                    signature: $event.signature,
                    app: $event.app,
                    title: $event.title,
                    lastNotifiedAt: $now
                }
            elif $event.event == "resolved" and $event.key != "" then
                del(.attention[$event.key])
            else
                .
            end
          )
        | .lastSentAt = $now
        ' "$NOTIFICATION_STATE_FILE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$NOTIFICATION_STATE_FILE"
}

send_grouped_notification() {
    local total actions attention resolved errors
    local importance description mode body="" record entry shown=0 omitted
    local sorted delivered

    [[ "$SEND_GROUPED_NOTIFICATIONS" == true ]] || return 0
    [[ -n "$NOTIFICATION_BATCH" && -s "$NOTIFICATION_BATCH" ]] || return 0

    total="$(wc -l < "$NOTIFICATION_BATCH" | tr -d ' ')"
    actions="$(jq -s '[.[] | select(.event == "action")] | length' "$NOTIFICATION_BATCH")"
    attention="$(jq -s '[.[] | select(.event == "attention")] | length' "$NOTIFICATION_BATCH")"
    resolved="$(jq -s '[.[] | select(.event == "resolved")] | length' "$NOTIFICATION_BATCH")"
    errors="$(jq -s '[.[] | select(.severity == "ERROR")] | length' "$NOTIFICATION_BATCH")"

    importance=normal
    (( attention > 0 )) && importance=warning
    (( errors > 0 )) && importance=alert
    mode=EXECUTE
    [[ "$DRY_RUN" == true ]] && mode="DRY RUN"
    description="Daily grouped summary: actions=${actions}, attention=${attention}, resolved=${resolved}"
    body="Mode: ${mode}"$'\n'
    body+="Actions: ${actions} | Attention: ${attention} | Resolved: ${resolved}"$'\n\n'

    sorted="$(mktemp "$RUNTIME_DIR/.notification-render.XXXXXX")" || return 1
    delivered="$(mktemp "$RUNTIME_DIR/.notification-delivered.XXXXXX")" || {
        rm -f -- "$sorted"
        return 1
    }
    : > "$delivered"
    jq -sc '
        sort_by(
            if .severity == "ERROR" then 0
            elif .event == "attention" then 1
            elif .event == "resolved" then 2
            else 3
            end,
            .app,
            .title
        ) | .[]
        ' "$NOTIFICATION_BATCH" > "$sorted" || {
        rm -f -- "$sorted" "$delivered"
        return 1
    }

    while IFS= read -r record; do
        [[ -n "$record" ]] || continue
        (( shown < NOTIFICATION_MAX_ITEMS )) || break
        entry="$(jq -r --argjson maximum "$NOTIFICATION_ITEM_MAX_CHARS" '
            (if .event == "attention" then "ATTENTION"
             elif .event == "resolved" then "RESOLVED"
             else "ACTION" end) as $label
            | ("- [" + .app + "] " + .title + " [" + $label + "]"
              + if .detail == "" then "" else "\n  " + (.detail | gsub("[\\r\\n]+"; "\n  ")) end) as $text
            | if ($text | length) > $maximum
              then $text[0:$maximum] + "\n  Detail shortened; see the persistent log."
              else $text
              end
            ' <<< "$record")"
        body+="$entry"$'\n\n'
        printf '%s\n' "$record" >> "$delivered"
        ((shown += 1))
    done < "$sorted"
    rm -f -- "$sorted"

    omitted=$((total - shown))
    if (( omitted > 0 )); then
        body+="${omitted} additional item(s) omitted; see ${LOG_FILE}."$'\n'
    fi

    if [[ ! -x "$NOTIFY_BIN" ]]; then
        rm -f -- "$delivered"
        log ERROR "Grouped notification helper is unavailable: $NOTIFY_BIN"
        return 1
    fi

    description="$(strip_notification_emoji "$description")"
    body="$(strip_notification_emoji "$body")"

    if ! "$NOTIFY_BIN" \
        -i "$importance" \
        -s "Arr Delete Sync" \
        -d "$description" \
        -m "$body" >/dev/null 2>&1; then
        rm -f -- "$delivered"
        log ERROR "Could not send grouped Arr delete notification."
        return 1
    fi

    mark_notification_batch_delivered "$delivered" || {
        rm -f -- "$delivered"
        log ERROR "Notification was sent, but its suppression state could not be updated."
        return 1
    }
    rm -f -- "$delivered"
    log INFO "Sent one grouped notification with $shown of $total queued item(s)."
}

die() {
    queue_attention_notification ERROR "$APP_CONTEXT" "Workflow stopped" "$*" || true
    log ERROR "$*"
    exit 1
}

cleanup_app() {
    local status=$?
    [[ -n "$WORK_STATE" && -f "$WORK_STATE" ]] && rm -f -- "$WORK_STATE"
    [[ -n "$CURRENT_SNAPSHOT_FILE" && -f "$CURRENT_SNAPSHOT_FILE" ]] &&
        rm -f -- "$CURRENT_SNAPSHOT_FILE"
    [[ -n "$SIDECAR_BATCH_FILE" && -f "$SIDECAR_BATCH_FILE" ]] &&
        rm -f -- "$SIDECAR_BATCH_FILE"
    [[ -n "$SIDECAR_ENTRY_FILE" && -f "$SIDECAR_ENTRY_FILE" ]] &&
        rm -f -- "$SIDECAR_ENTRY_FILE"
    trap - EXIT
    exit "$status"
}

cleanup_main() {
    local status=$?
    [[ -n "$NOTIFICATION_BATCH" && -f "$NOTIFICATION_BATCH" ]] &&
        rm -f -- "$NOTIFICATION_BATCH"
    if [[ "$LOCK_HELD" == true ]]; then
        rm -f -- "$LOCK_DIR/pid"
        rmdir -- "$LOCK_DIR" 2>/dev/null || true
    fi
    trap - EXIT
    exit "$status"
}

rotate_log() {
    local bytes i
    [[ -f "$LOG_FILE" ]] || return 0
    bytes="$(stat -c '%s' "$LOG_FILE" 2>/dev/null ||
        stat -f '%z' "$LOG_FILE" 2>/dev/null || printf 0)"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    (( bytes >= MAX_LOG_SIZE_MB * 1024 * 1024 )) || return 0

    rm -f -- "$LOG_FILE.$MAX_LOG_FILES"
    for (( i=MAX_LOG_FILES-1; i>=1; i-- )); do
        [[ -f "$LOG_FILE.$i" ]] && mv -f -- "$LOG_FILE.$i" "$LOG_FILE.$((i + 1))"
    done
    mv -f -- "$LOG_FILE" "$LOG_FILE.1"
    : > "$LOG_FILE"
}

# Temporary files live beside the state files so replacement stays atomic.
# This runs only after the unified exclusive lock is held.
remove_stale_temp_files() {
    local file removed=0 nullglob_was_set=false
    local -a stale_files

    shopt -q nullglob && nullglob_was_set=true
    shopt -s nullglob
    stale_files=(
        "$RUNTIME_DIR"/.state-*
        "$RUNTIME_DIR"/.episodes.*
        "$RUNTIME_DIR"/.movies.*
        "$RUNTIME_DIR"/.sonarr-*
        "$RUNTIME_DIR"/.radarr-*
        "$RUNTIME_DIR"/.sidecars.*
        "$RUNTIME_DIR"/.notification-*
    )
    [[ "$nullglob_was_set" == true ]] || shopt -u nullglob

    for file in "${stale_files[@]}"; do
        [[ -f "$file" ]] || continue
        rm -f -- "$file"
        ((removed += 1))
    done

    (( removed == 0 )) ||
        log INFO "Removed $removed stale temporary file(s) from an interrupted previous run."
}

valid_relative_path() {
    local relative="$1"
    [[ -n "$relative" &&
       "$relative" != /* &&
       "$relative" != "." &&
       "$relative" != ".." &&
       "$relative" != ../* &&
       "$relative" != */../* &&
       "$relative" != */.. &&
       "$relative" != *$'\n'* ]]
}

normalize_quarantine_permissions() {
    local target="$1"
    local quarantine_real target_real
    local failed=false

    [[ -e "$QUARANTINE_ROOT" && ! -L "$QUARANTINE_ROOT" ]] || {
        log ERROR "Quarantine root is unavailable or unsafe for permission normalization: $QUARANTINE_ROOT"
        return 1
    }
    quarantine_real="$(realpath -- "$QUARANTINE_ROOT" 2>/dev/null)" || return 1
    target_real="$(realpath -- "$target" 2>/dev/null)" || return 1

    if [[ "$target_real" != "$quarantine_real" &&
          "$target_real" != "$quarantine_real"/* ]]; then
        log ERROR "Refusing to change ownership or permissions outside quarantine: $target_real"
        return 1
    fi

    # find does not follow symlinks by default. chown -h changes a symlink's
    # own owner; chmod is limited to real directories and regular files.
    if ! find "$target_real" -xdev -exec chown -h -- "$QUARANTINE_OWNER" {} +; then
        log ERROR "Unable to set quarantine owner '$QUARANTINE_OWNER': $target_real"
        failed=true
    fi
    if ! find "$target_real" -xdev -type d \
        -exec chmod -- "$QUARANTINE_DIRECTORY_MODE" {} +; then
        log ERROR "Unable to set quarantine directory mode $QUARANTINE_DIRECTORY_MODE: $target_real"
        failed=true
    fi
    if ! find "$target_real" -xdev -type f \
        -exec chmod -- "$QUARANTINE_FILE_MODE" {} +; then
        log ERROR "Unable to set quarantine file mode $QUARANTINE_FILE_MODE: $target_real"
        failed=true
    fi

    [[ "$failed" == false ]]
}

map_arr_media_path() {
    local api_path="$1"
    local api_root="$2"
    local host_root="$3"
    local relative

    api_path="${api_path%/}"
    api_root="${api_root%/}"
    host_root="${host_root%/}"
    [[ "$api_path" == "$api_root"/* ]] || return 1
    relative="${api_path#"$api_root"/}"
    valid_relative_path "$relative" || return 1
    printf '%s/%s' "$host_root" "$relative"
}

# Print a canonical media directory only when it is a child of the configured
# root. Missing media directories are allowed for post-cleanup verification;
# an existing path must be a real directory and never a symlink.
media_path_under_root() {
    local media_path="$1"
    local media_root="$2"
    local root_real candidate relative

    media_root="${media_root%/}"
    media_path="${media_path%/}"
    root_real="$(realpath -- "$media_root" 2>/dev/null)" || return 1
    [[ "$media_path" == "$media_root"/* ]] || return 1
    relative="${media_path#"$media_root"/}"
    valid_relative_path "$relative" || return 1
    [[ ! -L "$media_path" ]] || return 1
    [[ ! -e "$media_path" || -d "$media_path" ]] || return 1
    if [[ -e "$media_path" ]]; then
        candidate="$(realpath -- "$media_path" 2>/dev/null)" || return 1
        [[ "$candidate" == "$root_real"/* ]] || return 1
    else
        candidate="${root_real}/${relative}"
    fi
    printf '%s' "$candidate"
}

file_size_bytes() {
    stat -c '%s' -- "$1" 2>/dev/null || stat -f '%z' -- "$1" 2>/dev/null
}

capture_kodi_sidecars() {
    local app_name="$1"
    local media_path="$2"
    local media_root="$3"
    local media_relative_paths="$4"
    local media_real relative lower name rel_dir file_name stem candidate
    local file size size_after hash eligible capture_failed=0
    local files='[]'
    local type extension
    local -A exact_paths=()

    media_real="$(media_path_under_root "$media_path" "$media_root")" || {
        log ERROR "Cannot capture $app_name sidecars from unsafe media path: $media_path"
        return 1
    }
    [[ -d "$media_real" ]] || {
        log ERROR "Cannot capture $app_name sidecars because the media directory is missing: $media_path"
        return 1
    }
    jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1 \
        <<< "$media_relative_paths" || return 1

    if [[ "$app_name" == sonarr ]]; then
        exact_paths["tvshow.nfo"]=1
    else
        exact_paths["movie.nfo"]=1
    fi
    for type in poster banner fanart clearart characterart discart keyart \
        landscape logo backdrop clearlogo folder thumb; do
        for extension in jpg jpeg png; do
            exact_paths["${type}.${extension}"]=1
        done
    done

    while IFS= read -r relative; do
        valid_relative_path "$relative" || {
            log WARNING "Skipping unsafe $app_name media-relative path while capturing sidecars: $relative"
            capture_failed=1
            continue
        }
        rel_dir="${relative%/*}"
        [[ "$rel_dir" == "$relative" ]] && rel_dir=""
        file_name="${relative##*/}"
        stem="${file_name%.*}"
        [[ -n "$stem" && "$stem" != "$file_name" ]] || continue

        candidate="${stem}.nfo"
        [[ -n "$rel_dir" ]] && candidate="${rel_dir}/${candidate}"
        exact_paths["${candidate,,}"]=1

        if [[ "$app_name" == sonarr ]]; then
            for extension in jpg jpeg png; do
                candidate="${stem}-thumb.${extension}"
                [[ -n "$rel_dir" ]] && candidate="${rel_dir}/${candidate}"
                exact_paths["${candidate,,}"]=1
            done
        else
            for type in thumb poster banner fanart clearart discart keyart landscape logo backdrop clearlogo; do
                for extension in jpg jpeg png; do
                    candidate="${stem}-${type}.${extension}"
                    [[ -n "$rel_dir" ]] && candidate="${rel_dir}/${candidate}"
                    exact_paths["${candidate,,}"]=1
                done
            done
        fi
    done < <(jq -r '.[]' <<< "$media_relative_paths")

    while IFS= read -r -d '' file; do
        relative="${file#"$media_real"/}"
        valid_relative_path "$relative" || continue
        lower="${relative,,}"
        name="${lower##*/}"
        eligible=false

        if [[ -n "${exact_paths[$lower]+present}" ]]; then
            eligible=true
        elif [[ "$app_name" == sonarr &&
                "$name" =~ ^season([0-9]{2,}|-all|-specials)-(poster|banner|fanart|landscape|thumb)\.(jpg|jpeg|png)$ ]]; then
            eligible=true
        else
            extension="${name##*.}"
            case "$extension" in
                nfo|srt|ass|ssa|vtt|sub|idx|sup|smi|sami)
                    eligible=true
                    ;;
            esac
        fi
        [[ "$eligible" == true ]] || continue

        size="$(file_size_bytes "$file")" || {
            log WARNING "Could not stat $app_name sidecar while capturing it: $file"
            capture_failed=1
            continue
        }
        [[ "$size" =~ ^[0-9]+$ ]] || {
            capture_failed=1
            continue
        }
        if (( size > MAX_SIDECAR_SIZE_MB * 1024 * 1024 )); then
            log WARNING "Skipping oversized $app_name sidecar (${size} bytes): $file"
            continue
        fi
        hash="$(sha256sum -- "$file" 2>/dev/null | cut -d ' ' -f 1)"
        size_after="$(file_size_bytes "$file")" || size_after=-1
        if [[ ! "$hash" =~ ^[a-fA-F0-9]{64}$ || "$size_after" != "$size" ]]; then
            log WARNING "Sidecar changed or could not be hashed while capturing it: $file"
            capture_failed=1
            continue
        fi

        files="$(jq --arg relative "$relative" \
            --arg sha256 "${hash,,}" \
            --argjson size "$size" \
            '. + [{relativePath:$relative,size:$size,sha256:$sha256}] | unique_by(.relativePath)' \
            <<< "$files")" || return 1
    done < <(find "$media_real" -type f -print0)

    (( capture_failed == 0 )) || return 1
    printf '%s' "$files"
}

# Build a file-backed cleanup plan without placing a potentially large sidecar
# list in jq's argument vector. A recognized file absent from the original
# manifest is moved only when its path, size, and hash match the candidate saved
# by the previous cleanup run.
build_sidecar_cleanup_plan() {
    local app_name="$1"
    local media_path="$2"
    local media_root="$3"
    local manifest="$4"
    local current_file plan

    if [[ "$CAPTURE_LATE_KODI_SIDECARS" != true ]]; then
        jq '{
            moveEntries: (.files // []),
            lateCandidates: [],
            lateConfirmed: [],
            observedLate: []
        }' <<< "$manifest"
        return
    fi

    current_file="$(mktemp "$RUNTIME_DIR/.sidecars.late-current.XXXXXX")" || return 1
    if ! capture_kodi_sidecars "$app_name" "$media_path" "$media_root" '[]' \
        > "$current_file"; then
        rm -f -- "$current_file"
        return 1
    fi

    plan="$(jq --slurpfile current_source "$current_file" '
        def same_file($left; $right):
            ($left.relativePath == $right.relativePath)
            and ($left.size == $right.size)
            and (($left.sha256 | ascii_downcase) == ($right.sha256 | ascii_downcase));

        . as $manifest
        | ($manifest.files // []) as $recorded
        | ($manifest.lateSidecarCandidates // []) as $previous
        | ($current_source[0] // []) as $current
        | [
            $current[] as $candidate
            | select(all($recorded[]; .relativePath != $candidate.relativePath))
            | $candidate
          ] as $late
        | [
            $late[] as $candidate
            | select(any($previous[]; same_file($candidate; .)))
            | $candidate
          ] as $confirmed
        | [
            $late[] as $candidate
            | select(all($previous[]; same_file($candidate; .) | not))
            | $candidate
          ] as $pending
        | {
            moveEntries: (($recorded + $confirmed) | unique_by(.relativePath)),
            lateCandidates: $pending,
            lateConfirmed: $confirmed,
            observedLate: $late
          }
        ' <<< "$manifest")" || {
        rm -f -- "$current_file"
        return 1
    }
    rm -f -- "$current_file"
    printf '%s' "$plan"
}

contains_video_files() {
    local media_path="$1"
    find "$media_path" -type f \
        \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' \
           -o -iname '*.avi' -o -iname '*.mov' -o -iname '*.wmv' \
           -o -iname '*.ts' -o -iname '*.m2ts' -o -iname '*.mts' \
           -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.webm' \
           -o -iname '*.vob' -o -iname '*.iso' -o -iname '*.strm' \) \
        -print -quit | grep -q .
}

unraid_mover_running() {
    pgrep -f '(^|/)(mover|mover\.old)( |$)|mover\.php' >/dev/null 2>&1
}

remove_empty_media_dirs() {
    local media_path="$1"
    local directory removed=0

    [[ -d "$media_path" ]] || return 0
    while IFS= read -r -d '' directory; do
        [[ ! -L "$directory" ]] || continue
        if rmdir -- "$directory" 2>/dev/null; then
            ((removed += 1))
            log INFO "Removed empty media directory: $directory"
        fi
    done < <(find "$media_path" -depth -type d -empty -print0 2>/dev/null)
    CLEANUP_FOLDERS_REMOVED=$((CLEANUP_FOLDERS_REMOVED + removed))
}

log_media_cleanup_blockers() {
    local app_name="$1"
    local media_path="$2"
    local entry relative
    local remaining=0 shown=0 additional
    local entry_word="entries"

    CLEANUP_BLOCKER_COUNT=0
    CLEANUP_BLOCKER_DETAILS=""

    while IFS= read -r -d '' entry; do
        ((remaining += 1))
        if (( shown < CLEANUP_REMAINING_LOG_MAX_ITEMS )); then
            relative="${entry#"$media_path"/}"
            relative="${relative//$'\n'/ }"
            log WARNING "$app_name folder cleanup blocker: $relative"
            [[ -z "$CLEANUP_BLOCKER_DETAILS" ]] || CLEANUP_BLOCKER_DETAILS+=$'\n'
            CLEANUP_BLOCKER_DETAILS+="- $relative"
            ((shown += 1))
        fi
    done < <(find "$media_path" -mindepth 1 ! -type d -print0 2>/dev/null)

    if (( remaining == 0 )); then
        log WARNING "$app_name media directory still exists, but no remaining non-directory entry could be enumerated; permissions, a mount, or a concurrent writer may be preventing removal: $media_path"
    elif (( remaining > shown )); then
        additional=$((remaining - shown))
        [[ "$additional" == 1 ]] && entry_word="entry"
        log WARNING "$app_name folder cleanup has $additional additional blocking $entry_word not shown."
    fi

    entry_word="entries"
    [[ "$remaining" == 1 ]] && entry_word="entry"
    CLEANUP_BLOCKER_COUNT="$remaining"
    log WARNING "$app_name media directory remains with $remaining blocking $entry_word; folder cleanup stays pending and will be retried: $media_path"
}

# Return the captured manifest, a safe rmdir-only manifest when no sidecars
# were captured, a folder retry manifest for a cleanup recorded by an older
# release, or a completed sentinel when that recorded directory is absent.
prepare_sidecar_cleanup_manifest() {
    local item_id="$1"
    local current_media_path="$2"
    local media_root="$3"
    local bucket="$4"
    local manifest action

    manifest="$(jq -c --arg key "$item_id" \
        '.sidecarManifests[$key] // null' "$WORK_STATE")" || return 1
    if [[ "$manifest" != null ]]; then
        printf '%s' "$manifest"
        return 0
    fi

    action="$(jq -c --arg key "$item_id" \
        '.sidecarCleanupActions[$key] // null' "$WORK_STATE")" || return 1
    if [[ "$action" == null ]]; then
        log INFO "No pre-deletion sidecar manifest exists; attempting safe rmdir-only cleanup for confirmed fileless media path: $current_media_path"
        jq -cn \
            --arg media_path "$current_media_path" \
            --arg media_root "$media_root" \
            --arg bucket "$bucket" \
            --arg now "$RUN_AT" '
            {
                mediaPath: $media_path,
                mediaRoot: $media_root,
                bucket: $bucket,
                capturedAt: $now,
                files: [],
                lateSidecarCandidates: [],
                cleanupPending: false,
                cleanupProgress: {
                    quarantineRunId: null,
                    quarantinedFiles: 0,
                    nativeMissingFiles: 0,
                    foldersRemoved: 0
                }
            }'
        return
    fi

    if [[ ! -e "$current_media_path" && ! -L "$current_media_path" ]]; then
        printf '%s' '{"cleanupAlreadyRecorded":true}'
        return 0
    fi

    log INFO "Reopening previously recorded sidecar cleanup because its media directory still exists: $current_media_path"
    jq -cn \
        --arg media_path "$current_media_path" \
        --arg media_root "$media_root" \
        --arg bucket "$bucket" \
        --arg now "$RUN_AT" \
        --argjson action "$action" '
        {
            mediaPath: $media_path,
            mediaRoot: $media_root,
            bucket: $bucket,
            capturedAt: ($action.completedAt // $now),
            files: [],
            lateSidecarCandidates: [],
            cleanupPending: true,
            cleanupPendingSince: ($action.completedAt // $now),
            cleanupProgress: {
                quarantineRunId: ($action.quarantineRunId // null),
                quarantinedFiles: ($action.quarantinedFiles // 0),
                nativeMissingFiles: ($action.nativeMissingFiles // 0),
                foldersRemoved: ($action.foldersRemoved // 0)
            }
        }'
}

mark_sidecar_folder_cleanup_pending() {
    local item_id="$1"
    local media_path="$2"
    local media_root="$3"
    local bucket="$4"
    local next
    local total_quarantined total_native_missing total_folders_removed

    total_quarantined=$((CLEANUP_PROGRESS_QUARANTINED + CLEANUP_QUARANTINED))
    total_native_missing=$((CLEANUP_PROGRESS_NATIVE_MISSING + CLEANUP_NATIVE_MISSING))
    total_folders_removed=$((CLEANUP_PROGRESS_FOLDERS_REMOVED + CLEANUP_FOLDERS_REMOVED))
    next="$(mktemp "$STATE_DIR/.state-folder-pending.XXXXXX")" || return 1

    if ! jq \
        --arg key "$item_id" \
        --arg now "$RUN_AT" \
        --arg media_path "$media_path" \
        --arg media_root "$media_root" \
        --arg bucket "$bucket" \
        --arg quarantine_run_id "$CLEANUP_QUARANTINE_RUN_ID" \
        --argjson quarantined "$total_quarantined" \
        --argjson native_missing "$total_native_missing" \
        --argjson folders_removed "$total_folders_removed" \
        --argjson late_candidates "$CLEANUP_LATE_CANDIDATES" '
        (.sidecarManifests[$key] // {}) as $old_manifest
        | (.sidecarCleanupActions[$key] // {}) as $old_action
        | .sidecarManifests[$key] = {
            mediaPath: $media_path,
            mediaRoot: $media_root,
            bucket: $bucket,
            capturedAt: ($old_manifest.capturedAt // $old_action.completedAt // $now),
            files: [],
            lateSidecarCandidates: $late_candidates,
            lateSidecarCandidateAt: (
                if ($late_candidates | length) > 0
                then $now
                else null
                end
            ),
            cleanupPending: true,
            cleanupPendingSince: ($old_manifest.cleanupPendingSince // $old_action.completedAt // $now),
            cleanupLastAttemptAt: $now,
            cleanupProgress: {
                quarantineRunId: (if $quarantine_run_id == "" then null else $quarantine_run_id end),
                quarantinedFiles: $quarantined,
                nativeMissingFiles: $native_missing,
                foldersRemoved: $folders_removed
            }
          }
        | del(.sidecarCleanupActions[$key])
        ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

# Move unchanged files from a pre-deletion manifest plus recognized late
# sidecars confirmed by two cleanup runs. Missing files are treated as already
# handled by Arr's native Recycling Bin path. A changed, symlinked, or unsafe
# file is never moved and keeps the manifest pending.
quarantine_recorded_sidecars() {
    local app_name="$1"
    local bucket="$2"
    local media_root="$3"
    local current_media_path="$4"
    local manifest="$5"
    local recorded_media_path media_real root_real quarantine_real run_root
    local entry relative source source_real size expected_size hash expected_hash
    local root_relative destination destination_parent destination_real
    local files_count
    local cleanup_progress
    local cleanup_plan
    local late_candidate

    CLEANUP_COMPLETE=false
    CLEANUP_FOLDER_PENDING=false
    CLEANUP_QUARANTINED=0
    CLEANUP_NATIVE_MISSING=0
    CLEANUP_CHANGED=0
    CLEANUP_FOLDERS_REMOVED=0
    CLEANUP_PROGRESS_QUARANTINED=0
    CLEANUP_PROGRESS_NATIVE_MISSING=0
    CLEANUP_PROGRESS_FOLDERS_REMOVED=0
    CLEANUP_QUARANTINE_RUN_ID=""
    CLEANUP_LATE_CANDIDATES='[]'
    CLEANUP_LATE_CANDIDATE_COUNT=0
    CLEANUP_LATE_CONFIRMED_COUNT=0
    CLEANUP_BLOCKER_COUNT=0
    CLEANUP_BLOCKER_DETAILS=""

    [[ "$QUARANTINE_RUN_ID" =~ ^[0-9]{8}_[0-9]{6}_[0-9]+$ ]] || return 1
    [[ ! -L "$QUARANTINE_ROOT" ]] || return 1

    if [[ "$manifest" == null || -z "$manifest" ]]; then
        log WARNING "No pre-deletion Kodi sidecar manifest exists for $app_name path $current_media_path; cleanup was skipped."
        return 3
    fi
    if ! jq -e 'type == "object" and (.mediaPath | type == "string") and (.files | type == "array")' \
        >/dev/null 2>&1 <<< "$manifest"; then
        log ERROR "Invalid Kodi sidecar manifest for $app_name path $current_media_path."
        return 1
    fi

    cleanup_progress="$(jq -r '
        [
            (.cleanupProgress.quarantinedFiles // 0),
            (.cleanupProgress.nativeMissingFiles // 0),
            (.cleanupProgress.foldersRemoved // 0),
            (.cleanupProgress.quarantineRunId // "")
        ] | @tsv
        ' <<< "$manifest")" || return 1
    IFS=$'\t' read -r \
        CLEANUP_PROGRESS_QUARANTINED \
        CLEANUP_PROGRESS_NATIVE_MISSING \
        CLEANUP_PROGRESS_FOLDERS_REMOVED \
        CLEANUP_QUARANTINE_RUN_ID <<< "$cleanup_progress"
    [[ "$CLEANUP_PROGRESS_QUARANTINED" =~ ^[0-9]+$ ]] || return 1
    [[ "$CLEANUP_PROGRESS_NATIVE_MISSING" =~ ^[0-9]+$ ]] || return 1
    [[ "$CLEANUP_PROGRESS_FOLDERS_REMOVED" =~ ^[0-9]+$ ]] || return 1

    recorded_media_path="$(jq -r '.mediaPath' <<< "$manifest")"
    media_real="$(media_path_under_root "$current_media_path" "$media_root")" || {
        log ERROR "Refusing $app_name sidecar cleanup for unsafe media path: $current_media_path"
        return 1
    }
    root_real="$(realpath -- "$media_root" 2>/dev/null)" || return 1
    if [[ "${recorded_media_path%/}" != "${current_media_path%/}" ]]; then
        log WARNING "$app_name media path changed after manifest capture; cleanup was deferred: $recorded_media_path -> $current_media_path"
        return 0
    fi

    files_count="$(jq '.files | length' <<< "$manifest")"
    if [[ ! -e "$media_real" ]]; then
        CLEANUP_NATIVE_MISSING="$files_count"
        CLEANUP_COMPLETE=true
        log INFO "$app_name media directory is already absent; recorded sidecars require no further cleanup: $media_real"
        return 0
    fi
    if contains_video_files "$media_real"; then
        log WARNING "$app_name cleanup was deferred because a video file still exists below $media_real."
        return 0
    fi
    if [[ "$DEFER_SIDECAR_CLEANUP_WHILE_MOVER" == true ]] && unraid_mover_running; then
        if [[ "$MOVER_GUARD_NOTICE_LOGGED" == false ]]; then
            log WARNING "Unraid Mover is running; sidecar quarantine and empty-folder cleanup are deferred. Pending manifests will be retried next run."
            MOVER_GUARD_NOTICE_LOGGED=true
        fi
        return 4
    fi

    if [[ -e "$QUARANTINE_ROOT" ]]; then
        quarantine_real="$(realpath -- "$QUARANTINE_ROOT" 2>/dev/null)" || return 1
    else
        quarantine_real="${QUARANTINE_ROOT%/}"
    fi
    run_root="${quarantine_real}/${QUARANTINE_RUN_ID}"
    root_relative="${media_real#"$root_real"/}"
    valid_relative_path "$root_relative" || return 1

    cleanup_plan="$(build_sidecar_cleanup_plan \
        "$app_name" \
        "$media_real" \
        "$media_root" \
        "$manifest")" || {
        log ERROR "Could not build the $app_name late-sidecar cleanup plan: $media_real"
        return 1
    }
    CLEANUP_LATE_CANDIDATES="$(jq -c '.lateCandidates // []' <<< "$cleanup_plan")" || return 1
    CLEANUP_LATE_CANDIDATE_COUNT="$(jq '.lateCandidates | length' <<< "$cleanup_plan")" || return 1
    CLEANUP_LATE_CONFIRMED_COUNT="$(jq '.lateConfirmed | length' <<< "$cleanup_plan")" || return 1
    ((SIDECARS_LATE_CANDIDATES += CLEANUP_LATE_CANDIDATE_COUNT)) || true
    ((SIDECARS_LATE_CONFIRMED += CLEANUP_LATE_CONFIRMED_COUNT)) || true

    while IFS= read -r late_candidate; do
        [[ -n "$late_candidate" ]] || continue
        log INFO "$app_name late sidecar candidate requires one more unchanged cleanup run: $late_candidate"
    done < <(jq -r '.lateCandidates[]?.relativePath' <<< "$cleanup_plan")

    while IFS= read -r late_candidate; do
        [[ -n "$late_candidate" ]] || continue
        log INFO "$app_name late sidecar candidate confirmed for quarantine: $late_candidate"
    done < <(jq -r '.lateConfirmed[]?.relativePath' <<< "$cleanup_plan")

    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        relative="$(jq -r '.relativePath // empty' <<< "$entry")"
        expected_size="$(jq -r '.size // empty' <<< "$entry")"
        expected_hash="$(jq -r '.sha256 // empty' <<< "$entry")"
        if ! valid_relative_path "$relative" ||
           ! [[ "$expected_size" =~ ^[0-9]+$ && "$expected_hash" =~ ^[a-fA-F0-9]{64}$ ]]; then
            log WARNING "Unsafe or invalid recorded $app_name sidecar entry was not moved: $relative"
            ((CLEANUP_CHANGED += 1))
            continue
        fi

        source="${media_real}/${relative}"
        if [[ ! -e "$source" && ! -L "$source" ]]; then
            ((CLEANUP_NATIVE_MISSING += 1))
            continue
        fi
        if [[ -L "$source" || ! -f "$source" ]]; then
            log WARNING "Recorded $app_name sidecar is no longer a regular file; leaving it untouched: $source"
            ((CLEANUP_CHANGED += 1))
            continue
        fi
        source_real="$(realpath -- "$source" 2>/dev/null)" || {
            ((CLEANUP_CHANGED += 1))
            continue
        }
        if [[ "$source_real" != "$media_real"/* ]]; then
            log WARNING "Recorded $app_name sidecar resolved outside its media directory; leaving it untouched: $source"
            ((CLEANUP_CHANGED += 1))
            continue
        fi

        size="$(file_size_bytes "$source")" || size=-1
        if [[ "$REQUIRE_SIDECAR_HASH_MATCH" == true ]]; then
            hash="$(sha256sum -- "$source" 2>/dev/null | cut -d ' ' -f 1)"
            if [[ "$size" != "$expected_size" || "${hash,,}" != "${expected_hash,,}" ]]; then
                log WARNING "Recorded $app_name sidecar changed after capture; leaving it untouched: $source"
                ((CLEANUP_CHANGED += 1))
                continue
            fi
        fi

        destination="${run_root}/${bucket}/${root_relative}/${relative}"
        destination_real="${destination}"
        [[ "$destination_real" == "$run_root"/* ]] || return 1

        if [[ "$DRY_RUN" == true ]]; then
            log INFO "DRY RUN: would quarantine $app_name Kodi sidecar: $source -> $destination"
            ((CLEANUP_QUARANTINED += 1))
            continue
        fi

        if [[ ! -d "$run_root" ]]; then
            mkdir -p -- "$run_root" || return 1
        fi
        if [[ -L "$run_root" || ! -d "$run_root" ]]; then
            log ERROR "Quarantine run path is not a safe directory: $run_root"
            return 1
        fi
        destination_parent="$(dirname -- "$destination")"
        mkdir -p -- "$destination_parent" || return 1
        normalize_quarantine_permissions "$run_root" || {
            log ERROR "Quarantine directories were created but their ownership or permissions could not be normalized: $run_root"
            return 1
        }
        [[ ! -e "$destination" && ! -L "$destination" ]] || {
            log ERROR "Quarantine destination already exists; refusing to overwrite it: $destination"
            return 1
        }
        if mv -- "$source" "$destination"; then
            normalize_quarantine_permissions "$destination" || {
                log ERROR "Sidecar was quarantined but its ownership or permissions could not be normalized: $destination"
                return 1
            }
            log INFO "Quarantined $app_name Kodi sidecar: $source -> $destination"
            [[ -n "$CLEANUP_QUARANTINE_RUN_ID" ]] || \
                CLEANUP_QUARANTINE_RUN_ID="$QUARANTINE_RUN_ID"
            ((CLEANUP_QUARANTINED += 1))
        else
            return 1
        fi
    done < <(jq -c '.moveEntries[]?' <<< "$cleanup_plan")

    if [[ "$DRY_RUN" == true ]]; then
        [[ "$REMOVE_EMPTY_MEDIA_FOLDERS" == true ]] &&
            log INFO "DRY RUN: would attempt rmdir-only cleanup below $media_real after quarantining sidecars."
        return 0
    fi
    (( CLEANUP_CHANGED == 0 )) || return 0

    if (( CLEANUP_LATE_CANDIDATE_COUNT > 0 )) &&
       [[ "$REMOVE_EMPTY_MEDIA_FOLDERS" != true ]]; then
        CLEANUP_FOLDER_PENDING=true
        log INFO "$app_name cleanup remains pending for $CLEANUP_LATE_CANDIDATE_COUNT late sidecar candidate(s): $media_real"
        return 0
    fi

    if [[ "$REMOVE_EMPTY_MEDIA_FOLDERS" == true ]]; then
        remove_empty_media_dirs "$media_real"
        if [[ -e "$media_real" || -L "$media_real" ]]; then
            CLEANUP_FOLDER_PENDING=true
            log_media_cleanup_blockers "$app_name" "$media_real"
            return 0
        fi
    fi
    CLEANUP_COMPLETE=true
}

###############################################################################
# API: one response body on stdout; useful diagnostics on errors
###############################################################################

api_request() {
    local method="$1"
    local endpoint="$2"
    local payload="$3"
    local body err http_status curl_status message

    body="$(mktemp "$RUNTIME_DIR/.${ARR_TEMP_PREFIX}-body.XXXXXX")" || return 1
    err="$(mktemp "$RUNTIME_DIR/.${ARR_TEMP_PREFIX}-error.XXXXXX")" || {
        rm -f -- "$body"
        return 1
    }

    if [[ "$method" == GET ]]; then
        http_status="$(
            curl --silent --show-error \
                --connect-timeout "$HTTP_CONNECT_TIMEOUT" \
                --max-time "$HTTP_MAX_TIME" \
                --retry "$HTTP_RETRIES" --retry-all-errors \
                --request GET \
                --header "X-Api-Key: $ARR_API_KEY" \
                --header 'Accept: application/json' \
                --header "User-Agent: $ARR_USER_AGENT" \
                --output "$body" --write-out '%{http_code}' \
                "$ARR_URL$endpoint" 2>"$err"
        )"
    else
        http_status="$(
            curl --silent --show-error \
                --connect-timeout "$HTTP_CONNECT_TIMEOUT" \
                --max-time "$HTTP_MAX_TIME" \
                --retry "$HTTP_RETRIES" --retry-all-errors \
                --request "$method" \
                --header "X-Api-Key: $ARR_API_KEY" \
                --header 'Accept: application/json' \
                --header 'Content-Type: application/json' \
                --header "User-Agent: $ARR_USER_AGENT" \
                --data-binary "$payload" \
                --output "$body" --write-out '%{http_code}' \
                "$ARR_URL$endpoint" 2>"$err"
        )"
    fi
    curl_status=$?

    if (( curl_status != 0 )) || ! [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
        message="$({ tr '\r\n' ' ' < "$err"; tr '\r\n' ' ' < "$body"; } | cut -c1-500)"
        [[ -n "$http_status" ]] || http_status=none
        [[ -n "$message" ]] || message="no response body"
        log ERROR "$ARR_NAME $method $endpoint failed (curl=$curl_status HTTP=$http_status): $message"
        rm -f -- "$body" "$err"
        return 1
    fi

    cat "$body"
    rm -f -- "$body" "$err"
}

api_get_json() {
    local endpoint="$1"
    local json
    json="$(api_request GET "$endpoint" "")" || return 1
    if ! jq -e . >/dev/null 2>&1 <<< "$json"; then
        log ERROR "$ARR_NAME GET $endpoint returned invalid JSON."
        return 1
    fi
    printf '%s' "$json"
}

api_put_json() {
    api_request PUT "$1" "$2" >/dev/null
}

api_post_json() {
    api_request POST "$1" "$2"
}

# Load one application's tag catalogue into its isolated workflow context.
load_tag_catalog() {
    local tags
    tags="$(api_get_json "/api/v3/tag")" || return 1
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$tags"; then
        log ERROR "$ARR_NAME /tag did not return an array."
        return 1
    fi
    TAG_CATALOG="$tags"
}

# Set the named variable to an existing tag ID or create the tag.
ensure_tag_id() {
    local label="$1"
    local destination="$2"
    local id payload created

    id="$(jq -r --arg label "$label" 'first(.[] | select(.label == $label) | .id) // empty' <<< "$TAG_CATALOG")"
    if [[ ! "$id" =~ ^[0-9]+$ ]]; then
        payload="$(jq -cn --arg label "$label" '{label: $label}')"
        created="$(api_post_json "/api/v3/tag" "$payload" || true)"
        id="$(jq -r '.id // empty' <<< "$created" 2>/dev/null || true)"

        if [[ ! "$id" =~ ^[0-9]+$ ]]; then
            load_tag_catalog || return 1
            id="$(jq -r --arg label "$label" 'first(.[] | select(.label == $label) | .id) // empty' <<< "$TAG_CATALOG")"
            [[ "$id" =~ ^[0-9]+$ ]] || {
                log ERROR "Could not create or find $ARR_NAME tag '$label'."
                return 1
            }
        else
            TAG_CATALOG="$(jq --arg label "$label" --argjson id "$id" '
                if any(.[]; .id == $id) then . else . + [{id: $id, label: $label}] end
            ' <<< "$TAG_CATALOG")" || return 1
            log INFO "Created $ARR_NAME tag '$label'."
        fi
    fi

    printf -v "$destination" '%s' "$id"
}

# Submit one application-specific command and return its tracked command ID.
start_arr_command() {
    local payload="$1"
    local response command_id command_name
    command_name="$(jq -r '.name // "unknown"' <<< "$payload")"
    response="$(api_post_json "/api/v3/command" "$payload")" || return 1
    command_id="$(jq -r '.id // empty' <<< "$response")"
    [[ "$command_id" =~ ^[0-9]+$ ]] || {
        log ERROR "$ARR_NAME accepted $command_name but did not return a command ID."
        return 1
    }
    printf '%s' "$command_id"
}

wait_for_arr_command() {
    local command_id="$1"
    local started now elapsed last_notice=-1 status result
    started="$(date +%s)"

    while true; do
        COMMAND_JSON="$(api_get_json "/api/v3/command/$command_id")" || return 1
        status="$(jq -r '.status // "unknown"' <<< "$COMMAND_JSON")"
        result="$(jq -r '.result // "unknown"' <<< "$COMMAND_JSON")"

        case "$status" in
            completed)
                if [[ "$result" == failed || "$result" == unsuccessful ]]; then
                    log ERROR "$ARR_NAME command $command_id completed with result=$result."
                    return 1
                fi
                log INFO "$ARR_NAME command $command_id completed."
                return 0
                ;;
            failed|aborted)
                log ERROR "$ARR_NAME command $command_id ended with status=$status, result=$result."
                return 1
                ;;
        esac

        now="$(date +%s)"
        elapsed=$((now - started))
        if (( elapsed >= RESCAN_TIMEOUT_SECONDS )); then
            log ERROR "Timed out after ${RESCAN_TIMEOUT_SECONDS}s waiting for $ARR_NAME command $command_id (status=$status)."
            return 1
        fi
        if (( elapsed / 60 > last_notice )); then
            last_notice=$((elapsed / 60))
            log INFO "Waiting for $ARR_NAME command $command_id (status=$status, elapsed=${elapsed}s)."
        fi
        sleep "$RESCAN_POLL_SECONDS"
    done
}

###############################################################################
# STATE: work only in a temporary copy until final atomic commit
###############################################################################

sonarr_apply_snapshot() {
    local series_id="$1"
    local series_title="$2"
    local episodes_file="$3"
    local series_path="$4"
    local sidecar_files_file="$5"
    local next
    next="$(mktemp "$STATE_DIR/.state-snapshot.XXXXXX")" || return 1

    if ! jq --argjson series_id "$series_id" \
        --arg series_title "$series_title" \
        --arg series_path "$series_path" \
        --arg media_root "$SERIES_ROOT" \
        --arg now "$RUN_AT" \
        --slurpfile sidecar_source "$sidecar_files_file" \
        --slurpfile source "$episodes_file" '($source[0] // []) as $episodes
        | ($sidecar_source[0] // null) as $sidecar_files
        | .episodes //= {}
        | .sidecarManifests //= {}
        | if $sidecar_files != null then
            .sidecarManifests[($series_id | tostring)] = {
                mediaPath: $series_path,
                mediaRoot: $media_root,
                bucket: "series",
                capturedAt: $now,
                files: $sidecar_files,
                lateSidecarCandidates: []
            }
          else
            .
          end
        | reduce $episodes[] as $episode (.;
            ($episode.id | tostring) as $key
            | (.episodes[$key] // {}) as $old
            | {
                episodeId: $episode.id,
                seriesId: $series_id,
                seriesTitle: $series_title,
                seasonNumber: ($episode.seasonNumber // 0),
                episodeNumber: ($episode.episodeNumber // 0),
                episodeTitle: ($episode.title // "Unknown"),
                lastObservedAt: $now
              } as $identity
            | if $episode.hasFile == true then
                .episodes[$key] = (
                    $old + $identity + {
                        everHadFile: true,
                        lastKnownFileId: ($episode.episodeFileId // 0),
                        lastSeenWithFileAt: $now,
                        missingSince: null,
                        missingRuns: 0
                    }
                )
              elif $old.everHadFile == true then
                .episodes[$key] = (
                    $old + $identity + {
                        missingSince: ($old.missingSince // $now),
                        missingRuns: (($old.missingRuns // 0) + 1)
                    }
                )
              else
                .
              end
        )
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

sonarr_series_cleanup_eligible() {
    local series_id="$1"
    local episodes_file="$2"

    jq --argjson series_id "$series_id" \
        --argjson needed "$CONFIRMATION_RUNS" \
        --argjson require_history "$REQUIRE_DELETE_HISTORY_EVENT" \
        --slurpfile source "$episodes_file" '($source[0] // []) as $episodes
        | .episodes as $state
        | [
            $state | to_entries[]
            | select(.value.seriesId == $series_id and .value.everHadFile == true)
          ] as $historical
        | ($episodes | map({key:(.id | tostring),value:.}) | from_entries) as $current
        | (
            (($historical | length) > 0)
            and all($episodes[]; .hasFile != true)
            and all(
                $historical[];
                ($current[.key] != null)
                and ($current[.key].hasFile != true)
                and ((.value.missingRuns // 0) >= $needed)
                and (
                    ($require_history | not)
                    or (.value.latestEpisodeFileDeletedHistory != null)
                )
            )
          )
    ' "$WORK_STATE"
}

sonarr_mark_sidecar_cleanup() {
    local series_id="$1"
    local next
    local total_quarantined total_native_missing total_folders_removed

    total_quarantined=$((CLEANUP_PROGRESS_QUARANTINED + CLEANUP_QUARANTINED))
    total_native_missing=$((CLEANUP_PROGRESS_NATIVE_MISSING + CLEANUP_NATIVE_MISSING))
    total_folders_removed=$((CLEANUP_PROGRESS_FOLDERS_REMOVED + CLEANUP_FOLDERS_REMOVED))
    next="$(mktemp "$STATE_DIR/.state-sidecar-action.XXXXXX")" || return 1

    if ! jq --arg now "$RUN_AT" \
        --arg run_id "$CLEANUP_QUARANTINE_RUN_ID" \
        --argjson series_id "$series_id" \
        --argjson quarantined "$total_quarantined" \
        --argjson native_missing "$total_native_missing" \
        --argjson folders_removed "$total_folders_removed" '
        .sidecarCleanupActions //= {}
        | .sidecarCleanupActions[($series_id | tostring)] = {
            seriesId: $series_id,
            completedAt: $now,
            quarantineRunId: (if $quarantined > 0 and $run_id != "" then $run_id else null end),
            quarantinedFiles: $quarantined,
            nativeMissingFiles: $native_missing,
            foldersRemoved: $folders_removed
          }
        | del(.sidecarManifests[($series_id | tostring)])
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

sonarr_confirmed_episode_ids() {
    local episodes_file="$1"
    jq --slurpfile source "$episodes_file" --argjson needed "$CONFIRMATION_RUNS" '($source[0] // []) as $episodes
        | .episodes as $state
        | [
            $episodes[]
            | select(.monitored == true and .hasFile != true)
            | . as $episode
            | ($episode.id | tostring) as $key
            | ($state[$key] // {}) as $record
            | select($record.everHadFile == true and $record.missingRuns >= $needed)
            | $episode.id
          ]
        | unique
    ' "$WORK_STATE"
}

sonarr_new_candidate_count() {
    local series_id="$1"
    jq --argjson series_id "$series_id" --arg now "$RUN_AT" '
        [
            .episodes[]
            | select(
                .seriesId == $series_id and
                .missingSince == $now and
                .missingRuns == 1
              )
        ]
        | length
    ' "$WORK_STATE"
}

sonarr_log_new_candidates() {
    local series_id="$1"
    while IFS= read -r line; do
        [[ -n "$line" ]] && log WARNING "$line"
    done < <(
        jq -r --argjson series_id "$series_id" --arg now "$RUN_AT" '
            .episodes[]
            | select(
                .seriesId == $series_id and
                .missingSince == $now and
                .missingRuns == 1
              )
            | "Deletion candidate: \(.seriesTitle) S\(.seasonNumber)E\(.episodeNumber) — \(.episodeTitle) [episode \(.episodeId)]; confirmation pending."
        ' "$WORK_STATE"
    )
}

# Sonarr exposes deletion history by series. One request can therefore provide
# audit evidence for every confirmed episode in that series.
sonarr_series_delete_history() {
    local series_id="$1"
    local history
    history="$(api_get_json "/api/v3/history/series?seriesId=${series_id}&eventType=episodeFileDeleted")" ||
        return 1
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$history"; then
        log ERROR "Sonarr History for series $series_id did not return an array."
        return 1
    fi
    jq '[
            .[]
            | select(.eventType == "episodeFileDeleted")
            | {
                id: .id,
                episodeId: .episodeId,
                seriesId: .seriesId,
                date: .date,
                eventType: .eventType,
                data: (.data // {})
              }
        ]
        | sort_by(.date // "")
    ' <<< "$history"
}

sonarr_record_history_evidence() {
    local episode_id="$1"
    local evidence="$2"
    local next
    next="$(mktemp "$STATE_DIR/.state-history.XXXXXX")" || return 1

    if ! jq --arg now "$RUN_AT" --argjson episode_id "$episode_id" \
        --argjson evidence "$evidence" '
        .episodes[($episode_id | tostring)] |= . + {
            lastHistoryInspectionAt: $now,
            latestEpisodeFileDeletedHistory: $evidence
        }
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

sonarr_ids_with_history() {
    local ids="$1"
    local history="$2"
    jq --argjson ids "$ids" --argjson history "$history" '
        [
            $ids[] as $id
            | select(any($history[]; .episodeId == $id))
            | $id
        ]
        | unique
    ' <<< 'null'
}

# A season is eligible only if every historically downloaded episode in that
# season is currently present in Sonarr, fileless, and confirmed missing. It
# must also have no current monitored episodes after this run's episode action.
sonarr_candidate_seasons() {
    local series_id="$1"
    local episodes_file="$2"
    local effective_episode_actions="$3"

    jq --argjson series_id "$series_id" \
        --slurpfile source "$episodes_file" \
        --argjson effective "$effective_episode_actions" \
        --argjson needed "$CONFIRMATION_RUNS" '($source[0] // []) as $episodes
        | .episodes as $state
        | ($episodes | map({key: (.id | tostring), value: .}) | from_entries) as $current
        | ($episodes | map(select((.seasonNumber // 0) > 0) | .seasonNumber) | unique) as $seasons
        | [
            $seasons[]
            | . as $season
            | [
                $state | to_entries[]
                | select(
                    .value.seriesId == $series_id and
                    .value.seasonNumber == $season and
                    .value.everHadFile == true
                  )
              ] as $historical
            | select(($historical | length) > 0)
            | select(all(
                $historical[];
                (
                    ($current[.key] != null) and
                    ($current[.key].hasFile != true) and
                    (.value.missingRuns >= $needed)
                )
              ))
            | select(all(
                $episodes[] | select(.seasonNumber == $season);
                . as $episode
                | (
                    $episode.monitored != true or
                    (($effective | index($episode.id)) != null)
                  )
              ))
            | $season
          ]
        | unique
    ' "$WORK_STATE"
}

# This deliberately does not inspect .seasons; it establishes the episode and
# state prerequisites for a series action.  The caller performs the final
# seasons-array check against freshly retrieved Sonarr series detail.
sonarr_candidate_series() {
    local series_id="$1"
    local episodes_file="$2"
    local effective_episode_actions="$3"

    jq --argjson series_id "$series_id" \
        --slurpfile source "$episodes_file" \
        --argjson effective "$effective_episode_actions" \
        --argjson needed "$CONFIRMATION_RUNS" '($source[0] // []) as $episodes
        | .episodes as $state
        | [
            $state | to_entries[]
            | select(.value.seriesId == $series_id and .value.everHadFile == true)
          ] as $historical
        | ($episodes | map({key: (.id | tostring), value: .}) | from_entries) as $current
        | (
            (($historical | length) > 0)
            and all(
                $historical[];
                (
                    ($current[.key] != null)
                    and ($current[.key].hasFile != true)
                    and (.value.missingRuns >= $needed)
                )
            )
            and all(
                $episodes[];
                . as $episode
                | (
                    $episode.hasFile != true
                    and (
                        $episode.monitored != true
                        or (($effective | index($episode.id)) != null)
                    )
                )
            )
          )
    ' "$WORK_STATE"
}

sonarr_mark_episode_action() {
    local ids="$1"
    local next
    next="$(mktemp "$STATE_DIR/.state-action.XXXXXX")" || return 1
    if ! jq --arg now "$RUN_AT" --argjson ids "$ids" '
        reduce $ids[] as $id (.;
            .episodes[($id | tostring)] |= . + {lastEpisodeUnmonitoredAt: $now}
        )
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

sonarr_mark_season_action() {
    local series_id="$1"
    local seasons="$2"
    local next
    next="$(mktemp "$STATE_DIR/.state-season.XXXXXX")" || return 1
    if ! jq --arg now "$RUN_AT" --argjson series_id "$series_id" \
        --argjson seasons "$seasons" '
        .seasonActions //= {}
        | reduce $seasons[] as $season (.;
            .seasonActions[($series_id | tostring) + ":" + ($season | tostring)] = {
                seriesId: $series_id,
                seasonNumber: $season,
                lastUnmonitoredAt: $now
            }
        )
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

sonarr_mark_series_action() {
    local series_id="$1"
    local next
    next="$(mktemp "$STATE_DIR/.state-series.XXXXXX")" || return 1
    if ! jq --arg now "$RUN_AT" --argjson series_id "$series_id" '
        .seriesActions //= {}
        | .seriesActions[($series_id | tostring)] = {
            seriesId: $series_id,
            lastUnmonitoredAt: $now
        }
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

sonarr_commit_state() {
    local final backup had_errors
    final="$(mktemp "$STATE_DIR/.state-final.XXXXXX")" || return 1
    had_errors=false
    (( API_FAILURES > 0 || HISTORY_FAILURES > 0 || SIDECAR_FAILURES > 0 )) && had_errors=true

    if ! jq --arg now "$RUN_AT" --argjson had_errors "$had_errors" '
        .version = 6
        | .lastRun = $now
        | .lastRunHadApiErrors = $had_errors
        | .episodes //= {}
        | .sidecarManifests //= {}
        | .sidecarCleanupActions //= {}
    ' "$WORK_STATE" > "$final" ||
       ! jq -e 'type == "object" and (.episodes | type == "object")' "$final" >/dev/null; then
        rm -f -- "$final"
        return 1
    fi

    backup="$(mktemp "$STATE_DIR/.state-backup.XXXXXX")" || return 1
    if cp -- "$STATE_FILE" "$backup"; then
        mv -f -- "$backup" "$STATE_BACKUP"
    else
        rm -f -- "$backup"
        log WARNING "Could not update state backup."
    fi
    mv -f -- "$final" "$STATE_FILE"
}

###############################################################################
# SONARR WORKFLOW
###############################################################################

run_sonarr() (
APP_CONTEXT="SONARR"
ARR_NAME="Sonarr"
ARR_URL="$SONARR_URL"
ARR_API_KEY="$SONARR_API_KEY"
ARR_TEMP_PREFIX="sonarr"
ARR_USER_AGENT="$USER_AGENT Sonarr"
STATE_DIR="$RUNTIME_DIR"
STATE_FILE="$SONARR_STATE_FILE"
STATE_BACKUP="$SONARR_STATE_BACKUP"
RUN_AT="$(date '+%Y-%m-%dT%H:%M:%S%z')"
WORK_STATE=""
CURRENT_SNAPSHOT_FILE=""
SIDECAR_BATCH_FILE=""
SIDECAR_ENTRY_FILE=""
API_FAILURES=0
HISTORY_FAILURES=0
HISTORY_INSPECTIONS=0
HISTORY_DELETE_EVENTS=0
HISTORY_LIMIT_SKIPS=0
SERIES_LISTED=0
SERIES_SCANNED=0
EPISODES_SCANNED=0
FILES_PRESENT=0
FIRST_MISSING=0
EPISODES_CONFIRMED=0
EPISODE_ACTIONS=0
SEASON_ACTIONS=0
SERIES_ACTIONS=0
TAGGED_SERIES_ACTIONS=0
SIDECARS_CAPTURED=0
SIDECARS_QUARANTINED=0
SIDECARS_NATIVE_MISSING=0
SIDECARS_CHANGED=0
SIDECARS_LATE_CANDIDATES=0
SIDECARS_LATE_CONFIRMED=0
SIDECAR_FAILURES=0
FOLDERS_REMOVED=0
FOLDER_CLEANUP_PENDING=0
MOVER_DEFERRALS=0
MOVER_GUARD_NOTICE_LOGGED=false
TAG_CATALOG=''
PLEX_DELETED_SEASON_TAG_ID=''
PLEX_DELETED_SERIES_TAG_ID=''

trap cleanup_app EXIT
trap 'exit 130' INT TERM

[[ -n "$SONARR_URL" && "$SONARR_URL" != */ ]] || die "Set SONARR_URL without a trailing slash."
[[ -n "$SONARR_API_KEY" && "$SONARR_API_KEY" != PUT_YOUR_SONARR_API_KEY_HERE ]] ||
    die "Set SONARR_API_KEY."
[[ "$SONARR_UNMONITOR_SEASON" == true || "$SONARR_UNMONITOR_SEASON" == false ]] ||
    die "SONARR_UNMONITOR_SEASON must be true or false."
[[ "$SONARR_UNMONITOR_SERIES" == true || "$SONARR_UNMONITOR_SERIES" == false ]] ||
    die "SONARR_UNMONITOR_SERIES must be true or false."
[[ "$PLEX_DELETED_SEASON_TAG" =~ ^[a-z0-9-]+$ ]] ||
    die "PLEX_DELETED_SEASON_TAG may contain only lowercase letters, numbers, and hyphens."
[[ "$PLEX_DELETED_SERIES_TAG" =~ ^[a-z0-9-]+$ ]] ||
    die "PLEX_DELETED_SERIES_TAG may contain only lowercase letters, numbers, and hyphens."
[[ "$PLEX_DELETED_SEASON_TAG" != "$PLEX_DELETED_SERIES_TAG" ]] ||
    die "PLEX_DELETED_SEASON_TAG and PLEX_DELETED_SERIES_TAG must be different."
[[ "$PROGRESS_LOG_EVERY" =~ ^[1-9][0-9]*$ ]] ||
    die "PROGRESS_LOG_EVERY must be a positive integer."

if [[ ! -f "$STATE_FILE" ]]; then
    INITIAL_STATE="$(mktemp "$STATE_DIR/.state-initial.XXXXXX")" ||
        die "Cannot create initial state file."
    printf '%s\n' '{"version":6,"lastRun":null,"lastRunHadApiErrors":false,"episodes":{},"sidecarManifests":{},"sidecarCleanupActions":{}}' > "$INITIAL_STATE" &&
        mv -f -- "$INITIAL_STATE" "$STATE_FILE" || {
            rm -f -- "$INITIAL_STATE"
            die "Cannot create state file."
        }
    log INFO "Created state file; this first run establishes a baseline."
fi
if ! jq -e 'type == "object" and (.episodes | type == "object")' "$STATE_FILE" >/dev/null; then
    die "State file is invalid: $STATE_FILE"
fi
WORK_STATE="$(mktemp "$STATE_DIR/.state-working.XXXXXX")" || die "Cannot create working state."
cp -- "$STATE_FILE" "$WORK_STATE" || die "Cannot copy state to working file."

###############################################################################
# RUN
###############################################################################

log INFO "Starting delete sync (dry-run=$DRY_RUN, confirmations=$CONFIRMATION_RUNS)."
if [[ "$TRIGGER_LIBRARY_RESCAN" == true ]]; then
    log INFO "API-only mode: requesting one Sonarr all-library rescan before checking episodes."
else
    log INFO "Using Sonarr's current database state; no rescan will be requested."
fi

SYSTEM="$(api_get_json "/api/v3/system/status")" || {
    ((API_FAILURES += 1))
    die "Cannot contact Sonarr; state was not changed."
}
if ! jq -e '.appName == "Sonarr"' >/dev/null 2>&1 <<< "$SYSTEM"; then
    die "Configured SONARR_URL did not identify itself as Sonarr."
fi
log INFO "Connected to Sonarr $(jq -r '.version // "unknown"' <<< "$SYSTEM")."

if [[ "$DRY_RUN" == false ]]; then
    load_tag_catalog || {
        ((API_FAILURES += 1))
        die "Could not load Sonarr tags; state was not changed."
    }
fi

if [[ "$TRIGGER_LIBRARY_RESCAN" == true ]]; then
    RESCAN_ID="$(start_arr_command '{"name":"RescanSeries"}')" || {
        ((API_FAILURES += 1))
        die "Could not start Sonarr library rescan; state was not changed."
    }
    log INFO "Submitted Sonarr library rescan command $RESCAN_ID; waiting before checking episodes."
    wait_for_arr_command "$RESCAN_ID" || {
        ((API_FAILURES += 1))
        die "Sonarr library rescan did not complete successfully; state was not changed."
    }
fi

SERIES="$(api_get_json "/api/v3/series")" || {
    ((API_FAILURES += 1))
    die "Could not retrieve series; state was not changed."
}
jq -e 'type == "array"' >/dev/null <<< "$SERIES" ||
    die "Sonarr /series did not return an array."
SERIES_LISTED="$(jq length <<< "$SERIES")"

# Every monitored series is scanned once, plus a series holding a pending
# candidate. No episode-file lookups, refresh commands, or same-run waits occur.
while IFS= read -r SERIES_ID; do
    [[ -n "$SERIES_ID" ]] || continue
    SERIES_TITLE="$(jq -r --argjson id "$SERIES_ID" '.[] | select(.id == $id) | .title // empty' <<< "$SERIES")"
    SERIES_API_PATH="$(jq -r --argjson id "$SERIES_ID" '.[] | select(.id == $id) | .path // empty' <<< "$SERIES")"
    SERIES_PATH=""
    if [[ -n "$SERIES_API_PATH" ]]; then
        SERIES_PATH="$(map_arr_media_path "$SERIES_API_PATH" "$SONARR_API_SERIES_ROOT" "$SERIES_ROOT" || true)"
    fi
    if [[ -z "$SERIES_TITLE" ]]; then
        log WARNING "Series $SERIES_ID is no longer returned by Sonarr; leaving its state untouched."
        continue
    fi

    NEXT_SERIES=$((SERIES_SCANNED + 1))
    if (( NEXT_SERIES == 1 || NEXT_SERIES % PROGRESS_LOG_EVERY == 0 )); then
        log INFO "Episode inspection progress: starting series $NEXT_SERIES ($SERIES_TITLE)."
    fi

    # Keep this potentially large response in a file.  Passing it through
    # jq's --argjson puts the full episode list in exec(2)'s argument vector,
    # which is what caused "Argument list too long" on large series.
    [[ -n "$CURRENT_SNAPSHOT_FILE" ]] && rm -f -- "$CURRENT_SNAPSHOT_FILE"
    CURRENT_SNAPSHOT_FILE="$(mktemp "$STATE_DIR/.episodes.XXXXXX")" ||
        die "Cannot create temporary episode snapshot."
    if ! api_get_json "/api/v3/episode?seriesId=$SERIES_ID&includeEpisodeFile=true" > "$CURRENT_SNAPSHOT_FILE"; then
        ((API_FAILURES += 1))
        log ERROR "Skipping $SERIES_TITLE; its state was not advanced."
        continue
    fi
    jq -e 'type == "array"' "$CURRENT_SNAPSHOT_FILE" >/dev/null || {
        ((API_FAILURES += 1))
        log ERROR "Skipping $SERIES_TITLE; Sonarr returned a non-array episode response."
        continue
    }

    ((SERIES_SCANNED += 1))
    COUNT="$(jq length "$CURRENT_SNAPSHOT_FILE")"
    PRESENT="$(jq '[.[] | select(.hasFile == true)] | length' "$CURRENT_SNAPSHOT_FILE")"
    ((EPISODES_SCANNED += COUNT))
    ((FILES_PRESENT += PRESENT))

    [[ -n "$SIDECAR_ENTRY_FILE" ]] && rm -f -- "$SIDECAR_ENTRY_FILE"
    SIDECAR_ENTRY_FILE="$(mktemp "$STATE_DIR/.sidecars.entry.XXXXXX")" ||
        die "Cannot create temporary Sonarr sidecar manifest."
    if [[ "$QUARANTINE_KODI_SIDECARS" == true ]] && (( PRESENT > 0 )); then
        MEDIA_RELATIVE_PATHS="$(jq '[
            .[]
            | select(.hasFile == true and (.episodeFile.relativePath | type == "string"))
            | .episodeFile.relativePath
        ] | unique' "$CURRENT_SNAPSHOT_FILE")" || die "Could not list Sonarr media paths for $SERIES_TITLE."
        if [[ -z "$SERIES_PATH" || "$(jq length <<< "$MEDIA_RELATIVE_PATHS")" == 0 ]]; then
            ((SIDECAR_FAILURES += 1))
            log ERROR "Could not capture Kodi sidecars for $SERIES_TITLE because Sonarr omitted its media path."
        elif capture_kodi_sidecars sonarr "$SERIES_PATH" "$SERIES_ROOT" \
            "$MEDIA_RELATIVE_PATHS" > "$SIDECAR_ENTRY_FILE"; then
            CAPTURED="$(jq length "$SIDECAR_ENTRY_FILE")"
            ((SIDECARS_CAPTURED += CAPTURED))
        else
            : > "$SIDECAR_ENTRY_FILE"
            ((SIDECAR_FAILURES += 1))
            log ERROR "Kodi sidecar manifest capture failed for $SERIES_TITLE; the previous manifest was retained."
        fi
    fi

    sonarr_apply_snapshot "$SERIES_ID" "$SERIES_TITLE" "$CURRENT_SNAPSHOT_FILE" \
        "$SERIES_PATH" "$SIDECAR_ENTRY_FILE" ||
        die "Could not update temporary state for $SERIES_TITLE."
    rm -f -- "$SIDECAR_ENTRY_FILE"
    SIDECAR_ENTRY_FILE=""

    NEW="$(sonarr_new_candidate_count "$SERIES_ID")"
    ((FIRST_MISSING += NEW))
    (( NEW > 0 )) && sonarr_log_new_candidates "$SERIES_ID"

    IDS="$(sonarr_confirmed_episode_ids "$CURRENT_SNAPSHOT_FILE")" ||
        die "Could not calculate episode action plan for $SERIES_TITLE."
    ID_COUNT="$(jq length <<< "$IDS")"
    ((EPISODES_CONFIRMED += ID_COUNT))
    ACTION_IDS="$IDS"
    EFFECTIVE='[]'

    if (( ID_COUNT > 0 )) && [[ "$INSPECT_DELETE_HISTORY" == true ]]; then
        if (( HISTORY_INSPECTIONS < MAX_HISTORY_INSPECTIONS_PER_RUN )); then
            ((HISTORY_INSPECTIONS += 1))
            if HISTORY="$(sonarr_series_delete_history "$SERIES_ID")"; then
                IDS_WITH_HISTORY="$(sonarr_ids_with_history "$IDS" "$HISTORY")" ||
                    die "Could not match Sonarr History evidence for $SERIES_TITLE."
                IDS_WITH_HISTORY_COUNT="$(jq length <<< "$IDS_WITH_HISTORY")"
                ((HISTORY_DELETE_EVENTS += IDS_WITH_HISTORY_COUNT))

                while IFS= read -r EPISODE_ID; do
                    [[ -n "$EPISODE_ID" ]] || continue
                    EVIDENCE="$(jq --argjson episode_id "$EPISODE_ID" '
                        [ .[] | select(.episodeId == $episode_id) ]
                        | sort_by(.date // "")
                        | last // null
                    ' <<< "$HISTORY")" ||
                        die "Could not select Sonarr History evidence for episode $EPISODE_ID."
                    sonarr_record_history_evidence "$EPISODE_ID" "$EVIDENCE" ||
                        die "Could not record Sonarr History evidence for episode $EPISODE_ID."
                done < <(jq -r '.[]' <<< "$IDS")

                if [[ "$REQUIRE_DELETE_HISTORY_EVENT" == true ]]; then
                    ACTION_IDS="$IDS_WITH_HISTORY"
                fi
                log INFO "History audit: $IDS_WITH_HISTORY_COUNT of $ID_COUNT confirmed episode(s) in $SERIES_TITLE have episodeFileDeleted evidence."
                if [[ "$REQUIRE_DELETE_HISTORY_EVENT" == true ]] &&
                   (( IDS_WITH_HISTORY_COUNT < ID_COUNT )); then
                    queue_attention_notification WARNING Sonarr \
                        "$SERIES_TITLE deletion action awaiting History evidence" \
                        "$((ID_COUNT - IDS_WITH_HISTORY_COUNT)) confirmed episode(s) remain monitored because required episodeFileDeleted evidence is unavailable."
                fi
            else
                ((HISTORY_FAILURES += 1))
                log WARNING "History audit failed for $SERIES_TITLE."
                [[ "$REQUIRE_DELETE_HISTORY_EVENT" == true ]] && ACTION_IDS='[]'
            fi
        else
            ((HISTORY_LIMIT_SKIPS += ID_COUNT))
            log WARNING "History inspection cap reached; deferred audit for $ID_COUNT episode(s) in $SERIES_TITLE."
            [[ "$REQUIRE_DELETE_HISTORY_EVENT" == true ]] && ACTION_IDS='[]'
            if [[ "$REQUIRE_DELETE_HISTORY_EVENT" == true ]]; then
                queue_attention_notification WARNING Sonarr \
                    "$SERIES_TITLE deletion action deferred" \
                    "The daily History inspection cap was reached before $ID_COUNT confirmed episode(s) could be verified."
            fi
        fi
    fi

    ACTION_ID_COUNT="$(jq length <<< "$ACTION_IDS")"
    if (( ACTION_ID_COUNT > 0 )); then
        if [[ "$DRY_RUN" == true ]]; then
            log INFO "DRY RUN: would unmonitor $ACTION_ID_COUNT confirmed episode(s) in $SERIES_TITLE: $(jq -r 'join(", ")' <<< "$ACTION_IDS")."
            EFFECTIVE="$ACTION_IDS"
            ((EPISODE_ACTIONS += ACTION_ID_COUNT))
        else
            PAYLOAD="$(jq -cn --argjson ids "$ACTION_IDS" '{episodeIds:$ids, monitored:false}')"
            if api_put_json "/api/v3/episode/monitor" "$PAYLOAD"; then
                log INFO "Unmonitored $ACTION_ID_COUNT confirmed episode(s) in $SERIES_TITLE: $(jq -r 'join(", ")' <<< "$ACTION_IDS")."
                sonarr_mark_episode_action "$ACTION_IDS" ||
                    die "Could not record episode action in temporary state."
                EFFECTIVE="$ACTION_IDS"
                ((EPISODE_ACTIONS += ACTION_ID_COUNT))
            else
                ((API_FAILURES += 1))
                log ERROR "Episode update failed for $SERIES_TITLE; it will be retried next run."
                queue_attention_notification ERROR Sonarr \
                    "$SERIES_TITLE episode update failed" \
                    "$ACTION_ID_COUNT confirmed episode(s) could not be unmonitored and will be retried."
            fi
        fi

        if (( $(jq length <<< "$EFFECTIVE") > 0 )); then
            queue_action_notification Sonarr "$SERIES_TITLE episodes unmonitored" \
                "Count: $ACTION_ID_COUNT; episode IDs: $(jq -r 'join(", ")' <<< "$EFFECTIVE")"
        fi
    fi

    if [[ "$QUARANTINE_KODI_SIDECARS" == true ]] &&
       [[ "$(sonarr_series_cleanup_eligible "$SERIES_ID" "$CURRENT_SNAPSHOT_FILE")" == true ]]; then
        if [[ -z "$SERIES_PATH" ]]; then
            ((SIDECAR_FAILURES += 1))
            log ERROR "Cannot map Sonarr path '$SERIES_API_PATH' from SONARR_API_SERIES_ROOT to SERIES_ROOT; sidecar cleanup for $SERIES_TITLE was deferred."
            queue_attention_notification WARNING Sonarr "$SERIES_TITLE cleanup deferred" \
                "The Sonarr media path could not be mapped safely: $SERIES_API_PATH"
        else
            MANIFEST="$(prepare_sidecar_cleanup_manifest "$SERIES_ID" \
                "$SERIES_PATH" "$SERIES_ROOT" series)" ||
                die "Could not prepare Kodi sidecar cleanup state for $SERIES_TITLE."
            if jq -e 'type == "object" and (.cleanupAlreadyRecorded // false) == true' \
                >/dev/null 2>&1 <<< "$MANIFEST"; then
                :
            elif quarantine_recorded_sidecars sonarr series "$SERIES_ROOT" "$SERIES_PATH" "$MANIFEST"; then
                ((SIDECARS_QUARANTINED += CLEANUP_QUARANTINED))
                ((SIDECARS_NATIVE_MISSING += CLEANUP_NATIVE_MISSING))
                ((SIDECARS_CHANGED += CLEANUP_CHANGED))
                ((FOLDERS_REMOVED += CLEANUP_FOLDERS_REMOVED))
                queue_cleanup_action_notification Sonarr "$SERIES_TITLE" "$SERIES_PATH"
                if [[ "$CLEANUP_COMPLETE" == true ]]; then
                    queue_folder_resolution_notification Sonarr "$SERIES_ID" \
                        "$SERIES_TITLE folder cleanup" "$SERIES_PATH"
                    sonarr_mark_sidecar_cleanup "$SERIES_ID" ||
                        die "Could not record Kodi sidecar cleanup for $SERIES_TITLE."
                elif [[ "$CLEANUP_FOLDER_PENDING" == true ]]; then
                    mark_sidecar_folder_cleanup_pending "$SERIES_ID" "$SERIES_PATH" \
                        "$SERIES_ROOT" series ||
                        die "Could not retain pending folder cleanup for $SERIES_TITLE."
                    ((FOLDER_CLEANUP_PENDING += 1))
                    queue_folder_blocker_notification Sonarr "$SERIES_ID" \
                        "$SERIES_TITLE folder cleanup pending" "$SERIES_PATH"
                elif (( CLEANUP_CHANGED > 0 )); then
                    queue_attention_notification WARNING Sonarr \
                        "$SERIES_TITLE sidecar cleanup deferred" \
                        "$CLEANUP_CHANGED recorded sidecar file(s) changed or became unsafe. See $LOG_FILE."
                fi
            else
                CLEANUP_RC=$?
                case "$CLEANUP_RC" in
                    3) ;;
                    4) ((MOVER_DEFERRALS += 1)) ;;
                    *)
                        ((SIDECAR_FAILURES += 1))
                        log ERROR "Kodi sidecar quarantine failed for $SERIES_TITLE; its manifest was retained."
                        queue_attention_notification ERROR Sonarr \
                            "$SERIES_TITLE sidecar quarantine failed" \
                            "The manifest was retained and the next daily run will retry. See $LOG_FILE."
                        ;;
                esac
            fi
        fi
    fi

    # Build independent season and series plans.  The series plan is default
    # off and still needs a fresh series-detail check below.
    SEASONS='[]'
    if [[ "$SONARR_UNMONITOR_SEASON" == true ]]; then
        SEASONS="$(sonarr_candidate_seasons "$SERIES_ID" "$CURRENT_SNAPSHOT_FILE" "$EFFECTIVE")" ||
            die "Could not calculate season action plan for $SERIES_TITLE."
    fi
    SEASON_COUNT="$(jq length <<< "$SEASONS")"

    SERIES_PRECONDITION=false
    if [[ "$SONARR_UNMONITOR_SERIES" == true ]]; then
        SERIES_PRECONDITION="$(sonarr_candidate_series "$SERIES_ID" "$CURRENT_SNAPSHOT_FILE" "$EFFECTIVE")" ||
            die "Could not calculate series action plan for $SERIES_TITLE."
    fi

    # Avoid series-detail calls except where there is an actual season plan or
    # an episode/state-qualified series plan.
    if (( SEASON_COUNT == 0 )) && [[ "$SERIES_PRECONDITION" != true ]]; then
        continue
    fi

    DETAIL="$(api_get_json "/api/v3/series/$SERIES_ID")" || {
        ((API_FAILURES += 1))
        log ERROR "Could not inspect season/series monitoring for $SERIES_TITLE; retrying next run."
        continue
    }
    jq -e 'type == "object" and (.seasons | type == "array")' >/dev/null <<< "$DETAIL" || {
        ((API_FAILURES += 1))
        log ERROR "Series detail for $SERIES_TITLE has no usable seasons array."
        continue
    }

    # A candidate season can already be unmonitored manually; only selected,
    # presently monitored seasons are included in the update payload.
    ACTIVE="$(
        jq --argjson candidates "$SEASONS" '
            [
                .seasons[]
                | .seasonNumber as $season
                | select(.monitored == true and ($candidates | index($season)) != null)
                | $season
            ]
            | unique
        ' <<< "$DETAIL"
    )"
    ACTIVE_COUNT="$(jq length <<< "$ACTIVE")"

    # A final series action requires every normal season (Season 1+) to be
    # unmonitored after this run's selected season changes.  Specials do not
    # block the action.  The top-level monitored flag must still be true.
    SERIES_ACTION="$(
        jq --argjson series_precondition "$SERIES_PRECONDITION" \
            --argjson active "$ACTIVE" '
            (
                $series_precondition
                and .monitored == true
                and ([.seasons[] | select(.seasonNumber > 0)] | length > 0)
                and all(
                    .seasons[] | select(.seasonNumber > 0);
                    . as $season
                    | (
                        $season.monitored != true
                        or (($active | index($season.seasonNumber)) != null)
                      )
                )
            )
        ' <<< "$DETAIL"
    )"

    if (( ACTIVE_COUNT == 0 )) && [[ "$SERIES_ACTION" != true ]]; then
        continue
    fi

    ACTION_TAG_LABELS=()
    (( ACTIVE_COUNT > 0 )) && ACTION_TAG_LABELS+=("$PLEX_DELETED_SEASON_TAG")
    [[ "$SERIES_ACTION" == true ]] && ACTION_TAG_LABELS+=("$PLEX_DELETED_SERIES_TAG")
    ACTION_TAG_LABEL_TEXT="$(jq -rn --args '$ARGS.positional | join(", ")' "${ACTION_TAG_LABELS[@]}")"

    if [[ "$DRY_RUN" == true ]]; then
        if (( ACTIVE_COUNT > 0 )); then
            log INFO "DRY RUN: would unmonitor season(s) $(jq -r 'join(", ")' <<< "$ACTIVE") for $SERIES_TITLE."
            ((SEASON_ACTIONS += ACTIVE_COUNT))
        fi
        if [[ "$SERIES_ACTION" == true ]]; then
            log INFO "DRY RUN: would unmonitor series $SERIES_TITLE after all normal seasons are unmonitored."
            ((SERIES_ACTIONS += 1))
        fi
        log INFO "DRY RUN: would ensure series tag(s) [$ACTION_TAG_LABEL_TEXT] on $SERIES_TITLE."
        ((TAGGED_SERIES_ACTIONS += 1))
        queue_action_notification Sonarr "$SERIES_TITLE monitoring and tags" \
            "Seasons to unmonitor: $(jq -r 'if length == 0 then "none" else join(", ") end' <<< "$ACTIVE"); series unmonitor: $SERIES_ACTION; tags: $ACTION_TAG_LABEL_TEXT"
        continue
    fi

    # Preserve the full resource and all season values except the selected
    # season updates. A series action changes only top-level .monitored. The
    # selected audit tags are appended to the existing series-level tags list.
    ACTION_TAG_IDS='[]'
    if (( ACTIVE_COUNT > 0 )); then
        ensure_tag_id "$PLEX_DELETED_SEASON_TAG" PLEX_DELETED_SEASON_TAG_ID || {
            ((API_FAILURES += 1))
            log ERROR "Could not prepare '$PLEX_DELETED_SEASON_TAG' for $SERIES_TITLE; no monitoring changes were sent."
            continue
        }
        ACTION_TAG_IDS="$(jq -cn --argjson tags "$ACTION_TAG_IDS" --argjson id "$PLEX_DELETED_SEASON_TAG_ID" '$tags + [$id] | unique')"
    fi
    if [[ "$SERIES_ACTION" == true ]]; then
        ensure_tag_id "$PLEX_DELETED_SERIES_TAG" PLEX_DELETED_SERIES_TAG_ID || {
            ((API_FAILURES += 1))
            log ERROR "Could not prepare '$PLEX_DELETED_SERIES_TAG' for $SERIES_TITLE; no monitoring changes were sent."
            continue
        }
        ACTION_TAG_IDS="$(jq -cn --argjson tags "$ACTION_TAG_IDS" --argjson id "$PLEX_DELETED_SERIES_TAG_ID" '$tags + [$id] | unique')"
    fi
    SERIES_PAYLOAD="$(
        jq --argjson active "$ACTIVE" \
            --argjson unmonitor_series "$SERIES_ACTION" \
            --argjson action_tags "$ACTION_TAG_IDS" '
            .seasons |= map(
                .seasonNumber as $season
                | if ($active | index($season)) != null then
                    .monitored = false
                  else
                    .
                  end
            )
            | if $unmonitor_series then .monitored = false else . end
            | .tags //= []
            | .tags |= ((. + $action_tags) | unique)
        ' <<< "$DETAIL"
    )"
    if api_put_json "/api/v3/series/$SERIES_ID" "$SERIES_PAYLOAD"; then
        if (( ACTIVE_COUNT > 0 )); then
            log INFO "Unmonitored season(s) $(jq -r 'join(", ")' <<< "$ACTIVE") for $SERIES_TITLE."
            sonarr_mark_season_action "$SERIES_ID" "$ACTIVE" ||
                die "Could not record season action in temporary state."
            ((SEASON_ACTIONS += ACTIVE_COUNT))
        fi
        if [[ "$SERIES_ACTION" == true ]]; then
            log INFO "Unmonitored series $SERIES_TITLE after all normal seasons were unmonitored."
            sonarr_mark_series_action "$SERIES_ID" ||
                die "Could not record series action in temporary state."
            ((SERIES_ACTIONS += 1))
        fi
        log INFO "Ensured series tag(s) [$ACTION_TAG_LABEL_TEXT] on $SERIES_TITLE."
        ((TAGGED_SERIES_ACTIONS += 1))
        queue_action_notification Sonarr "$SERIES_TITLE monitoring and tags" \
            "Seasons unmonitored: $(jq -r 'if length == 0 then "none" else join(", ") end' <<< "$ACTIVE"); series unmonitored: $SERIES_ACTION; tags: $ACTION_TAG_LABEL_TEXT"
    else
        ((API_FAILURES += 1))
        log ERROR "Season/series update failed for $SERIES_TITLE; it will be retried next run."
        queue_attention_notification ERROR Sonarr \
            "$SERIES_TITLE season or series update failed" \
            "The monitoring and tag update will be retried during the next daily run."
    fi
done < <(
    {
        jq -r '.[] | select(.monitored == true) | .id' <<< "$SERIES"
        jq -r '.episodes | to_entries[]? | select((.value.missingRuns // 0) > 0) | .value.seriesId' "$WORK_STATE"
    } | sort -nu
)

sonarr_commit_state || die "Could not atomically save state."
WORK_STATE=""

ACTION_LABEL=applied
[[ "$DRY_RUN" == true ]] && ACTION_LABEL=would-apply
log INFO "Summary: series-listed=$SERIES_LISTED, series-scanned=$SERIES_SCANNED, episodes=$EPISODES_SCANNED, files-present=$FILES_PRESENT, first-missing=$FIRST_MISSING, confirmed=$EPISODES_CONFIRMED, history-inspected=$HISTORY_INSPECTIONS, history-delete-events=$HISTORY_DELETE_EVENTS, history-cap-skips=$HISTORY_LIMIT_SKIPS, episode-actions-$ACTION_LABEL=$EPISODE_ACTIONS, season-actions-$ACTION_LABEL=$SEASON_ACTIONS, series-actions-$ACTION_LABEL=$SERIES_ACTIONS, tagged-series-$ACTION_LABEL=$TAGGED_SERIES_ACTIONS, sidecars-captured=$SIDECARS_CAPTURED, sidecars-$ACTION_LABEL=$SIDECARS_QUARANTINED, late-sidecar-candidates=$SIDECARS_LATE_CANDIDATES, late-sidecars-confirmed-$ACTION_LABEL=$SIDECARS_LATE_CONFIRMED, sidecars-native-missing=$SIDECARS_NATIVE_MISSING, sidecars-changed=$SIDECARS_CHANGED, folders-removed-$ACTION_LABEL=$FOLDERS_REMOVED, folder-cleanup-pending=$FOLDER_CLEANUP_PENDING, mover-deferrals=$MOVER_DEFERRALS, api-failures=$API_FAILURES, history-failures=$HISTORY_FAILURES, sidecar-failures=$SIDECAR_FAILURES."

if (( API_FAILURES > 0 || HISTORY_FAILURES > 0 || SIDECAR_FAILURES > 0 )); then
    FAILURE_SEVERITY=WARNING
    (( API_FAILURES > 0 || SIDECAR_FAILURES > 0 )) && FAILURE_SEVERITY=ERROR
    queue_attention_notification "$FAILURE_SEVERITY" Sonarr \
        "Daily Sonarr delete-sync completed with failures" \
        "API failures: $API_FAILURES; History failures: $HISTORY_FAILURES; sidecar failures: $SIDECAR_FAILURES. See $LOG_FILE."
    log WARNING "Completed with API, History, or sidecar failures; safe state was saved and unfinished actions will be retried."
    exit 2
fi
log INFO "Completed successfully."
)

###############################################################################
# UNIFIED ORCHESTRATION
###############################################################################

validate_common_configuration() {
    local command

    [[ "$RUNTIME_DIR" == /mnt/user/* && "$RUNTIME_DIR" != "/mnt/user/" &&
       "$RUNTIME_DIR" != *$'\n'* ]] || {
        printf 'Unsafe RUNTIME_DIR: %s\n' "$RUNTIME_DIR" >&2
        return 1
    }
    for command in curl jq mktemp stat tee sort cut tr cp mv find grep pgrep chown chmod \
        realpath sha256sum dirname rmdir; do
        command -v "$command" >/dev/null 2>&1 || {
            printf 'Required command not found: %s\n' "$command" >&2
            return 1
        }
    done

    [[ "$DRY_RUN" == true || "$DRY_RUN" == false ]] ||
        die "DRY_RUN must be true or false."
    [[ "$TRIGGER_LIBRARY_RESCAN" == true || "$TRIGGER_LIBRARY_RESCAN" == false ]] ||
        die "TRIGGER_LIBRARY_RESCAN must be true or false."
    [[ "$INSPECT_DELETE_HISTORY" == true || "$INSPECT_DELETE_HISTORY" == false ]] ||
        die "INSPECT_DELETE_HISTORY must be true or false."
    [[ "$REQUIRE_DELETE_HISTORY_EVENT" == true || "$REQUIRE_DELETE_HISTORY_EVENT" == false ]] ||
        die "REQUIRE_DELETE_HISTORY_EVENT must be true or false."
    [[ "$QUARANTINE_KODI_SIDECARS" == true || "$QUARANTINE_KODI_SIDECARS" == false ]] ||
        die "QUARANTINE_KODI_SIDECARS must be true or false."
    [[ "$CAPTURE_LATE_KODI_SIDECARS" == true || "$CAPTURE_LATE_KODI_SIDECARS" == false ]] ||
        die "CAPTURE_LATE_KODI_SIDECARS must be true or false."
    [[ "$REQUIRE_SIDECAR_HASH_MATCH" == true || "$REQUIRE_SIDECAR_HASH_MATCH" == false ]] ||
        die "REQUIRE_SIDECAR_HASH_MATCH must be true or false."
    [[ "$REMOVE_EMPTY_MEDIA_FOLDERS" == true || "$REMOVE_EMPTY_MEDIA_FOLDERS" == false ]] ||
        die "REMOVE_EMPTY_MEDIA_FOLDERS must be true or false."
    [[ "$DEFER_SIDECAR_CLEANUP_WHILE_MOVER" == true ||
       "$DEFER_SIDECAR_CLEANUP_WHILE_MOVER" == false ]] ||
        die "DEFER_SIDECAR_CLEANUP_WHILE_MOVER must be true or false."
    [[ "$SEND_GROUPED_NOTIFICATIONS" == true || "$SEND_GROUPED_NOTIFICATIONS" == false ]] ||
        die "SEND_GROUPED_NOTIFICATIONS must be true or false."
    [[ "$NOTIFY_DRY_RUN" == true || "$NOTIFY_DRY_RUN" == false ]] ||
        die "NOTIFY_DRY_RUN must be true or false."
    [[ "$INSPECT_DELETE_HISTORY" == true || "$REQUIRE_DELETE_HISTORY_EVENT" == false ]] ||
        die "REQUIRE_DELETE_HISTORY_EVENT=true requires INSPECT_DELETE_HISTORY=true."
    [[ "$CONFIRMATION_RUNS" =~ ^[0-9]+$ ]] && (( CONFIRMATION_RUNS >= 2 )) ||
        die "CONFIRMATION_RUNS must be an integer of at least 2."
    [[ "$MAX_HISTORY_INSPECTIONS_PER_RUN" =~ ^[1-9][0-9]*$ ]] ||
        die "MAX_HISTORY_INSPECTIONS_PER_RUN must be a positive integer."
    [[ "$MAX_SIDECAR_SIZE_MB" =~ ^[1-9][0-9]*$ ]] ||
        die "MAX_SIDECAR_SIZE_MB must be a positive integer."
    [[ "$CLEANUP_REMAINING_LOG_MAX_ITEMS" =~ ^[1-9][0-9]*$ ]] ||
        die "CLEANUP_REMAINING_LOG_MAX_ITEMS must be a positive integer."
    [[ "$NOTIFICATION_MAX_ITEMS" =~ ^[1-9][0-9]*$ &&
       "$NOTIFICATION_ITEM_MAX_CHARS" =~ ^[1-9][0-9]*$ ]] ||
        die "Notification item limits must be positive integers."
    [[ "$MAX_LOG_SIZE_MB" =~ ^[1-9][0-9]*$ && "$MAX_LOG_FILES" =~ ^[1-9][0-9]*$ ]] ||
        die "MAX_LOG_SIZE_MB and MAX_LOG_FILES must be positive integers."
    [[ "$HTTP_CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ &&
       "$HTTP_MAX_TIME" =~ ^[1-9][0-9]*$ &&
       "$HTTP_RETRIES" =~ ^[0-9]+$ ]] ||
        die "HTTP timeout values must be positive integers and HTTP_RETRIES non-negative."
    [[ "$RESCAN_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ &&
       "$RESCAN_POLL_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
        die "Rescan timeout and poll values must be positive integers."

    if [[ "$QUARANTINE_KODI_SIDECARS" == true ]]; then
        [[ -n "$QUARANTINE_OWNER" && "$QUARANTINE_OWNER" != *:* ]] ||
            die "QUARANTINE_OWNER must name one owner without a group."
        [[ "$QUARANTINE_DIRECTORY_MODE" =~ ^0?[0-7]{3}$ ]] ||
            die "QUARANTINE_DIRECTORY_MODE must be a three- or four-digit octal mode."
        [[ "$QUARANTINE_FILE_MODE" =~ ^0?[0-7]{3}$ ]] ||
            die "QUARANTINE_FILE_MODE must be a three- or four-digit octal mode."
        [[ "$QUARANTINE_ROOT" == /mnt/user/* && "$QUARANTINE_ROOT" != "/mnt/user/" &&
           "$MOVIES_ROOT" == /mnt/user/* && "$MOVIES_ROOT" != "/mnt/user/" &&
           "$SERIES_ROOT" == /mnt/user/* && "$SERIES_ROOT" != "/mnt/user/" &&
           "$QUARANTINE_ROOT" != *$'\n'* && "$MOVIES_ROOT" != *$'\n'* &&
           "$SERIES_ROOT" != *$'\n'* ]] ||
            die "Kodi sidecar roots must be safe children of /mnt/user."
        [[ "$QUARANTINE_ROOT" != "$MOVIES_ROOT" &&
           "$QUARANTINE_ROOT" != "$SERIES_ROOT" &&
           "$MOVIES_ROOT" != "$SERIES_ROOT" &&
           "$QUARANTINE_ROOT" != "$MOVIES_ROOT"/* &&
           "$QUARANTINE_ROOT" != "$SERIES_ROOT"/* &&
           "$MOVIES_ROOT" != "$QUARANTINE_ROOT"/* &&
           "$SERIES_ROOT" != "$QUARANTINE_ROOT"/* ]] ||
            die "Quarantine, movies, and series roots must not overlap."
        [[ ! -L "$QUARANTINE_ROOT" && ! -L "$MOVIES_ROOT" && ! -L "$SERIES_ROOT" ]] ||
            die "Quarantine, movies, and series roots must not be symlinks."
        [[ "$SONARR_API_SERIES_ROOT" == /* && "$SONARR_API_SERIES_ROOT" != "/" &&
           "$RADARR_API_MOVIES_ROOT" == /* && "$RADARR_API_MOVIES_ROOT" != "/" &&
           "$SONARR_API_SERIES_ROOT" != *$'\n'* && "$RADARR_API_MOVIES_ROOT" != *$'\n'* &&
           "$SONARR_API_SERIES_ROOT" != */../* && "$SONARR_API_SERIES_ROOT" != */.. &&
           "$RADARR_API_MOVIES_ROOT" != */../* && "$RADARR_API_MOVIES_ROOT" != */.. ]] ||
            die "SONARR_API_SERIES_ROOT and RADARR_API_MOVIES_ROOT must be safe absolute paths."
    fi
}

acquire_main_lock() {
    local old_pid=""

    if ! mkdir -- "$LOCK_DIR" 2>/dev/null; then
        [[ -r "$LOCK_DIR/pid" ]] && old_pid="$(<"$LOCK_DIR/pid")"
        if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
            log WARNING "Another unified Arr delete-sync run is active (PID $old_pid); exiting."
            return 2
        fi
        log WARNING "Removing stale unified lock."
        rm -f -- "$LOCK_DIR/pid"
        rmdir -- "$LOCK_DIR" 2>/dev/null || return 1
        mkdir -- "$LOCK_DIR" || return 1
    fi
    printf '%s\n' "$$" > "$LOCK_DIR/pid" || return 1
    LOCK_HELD=true
}

main() {
    local mode="${1:-all}"
    local sonarr_rc=0 radarr_rc=0 lock_rc=0 notification_rc=0

    case "$mode" in
        all|sonarr|radarr) ;;
        *)
            printf 'Usage: %s [all|sonarr|radarr]\n' "$0" >&2
            return 2
            ;;
    esac

    command -v mountpoint >/dev/null 2>&1 || {
        printf 'Required command not found: mountpoint\n' >&2
        return 1
    }
    mountpoint -q /mnt/user || {
        printf '/mnt/user is not mounted; refusing to create runtime state.\n' >&2
        return 1
    }
    validate_common_configuration || return 1
    mkdir -p -- "$RUNTIME_DIR" || return 1
    [[ ! -L "$RUNTIME_DIR" ]] || {
        printf 'RUNTIME_DIR must not be a symlink: %s\n' "$RUNTIME_DIR" >&2
        return 1
    }
    touch "$LOG_FILE" || return 1
    rotate_log

    trap cleanup_main EXIT
    trap 'exit 130' INT TERM
    if acquire_main_lock; then
        :
    else
        lock_rc=$?
        case "$lock_rc" in
            2) return 0 ;;
            *) die "Cannot acquire unified runtime lock." ;;
        esac
    fi
    remove_stale_temp_files
    initialize_grouped_notifications || die "Could not initialize grouped notification state."

    if [[ "$QUARANTINE_KODI_SIDECARS" == true && "$DRY_RUN" == false &&
          -e "$QUARANTINE_ROOT" ]]; then
        normalize_quarantine_permissions "$QUARANTINE_ROOT" ||
            die "Could not normalize quarantine ownership and permissions."
    fi

    QUARANTINE_RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"
    [[ "$QUARANTINE_RUN_ID" =~ ^[0-9]{8}_[0-9]{6}_[0-9]+$ ]] ||
        die "Could not create a valid quarantine run ID."

    log INFO "Starting unified Arr delete workflow (mode=$mode, dry-run=$DRY_RUN)."

    if [[ "$mode" == all || "$mode" == sonarr ]]; then
        run_sonarr || sonarr_rc=$?
    fi
    if [[ "$mode" == all || "$mode" == radarr ]]; then
        run_radarr || radarr_rc=$?
    fi

    APP_CONTEXT="MAIN"
    log INFO "Combined summary: sonarr-rc=$sonarr_rc, radarr-rc=$radarr_rc."
    if (( sonarr_rc != 0 || radarr_rc != 0 )); then
        log WARNING "Unified Arr delete workflow completed with one or more application failures."
        queue_attention_notification ERROR MAIN "Application workflow failure" \
            "Sonarr exit status: ${sonarr_rc}; Radarr exit status: ${radarr_rc}. See ${LOG_FILE}."
    fi

    send_grouped_notification || notification_rc=$?

    if (( sonarr_rc != 0 || radarr_rc != 0 )); then
        return 2
    fi
    if (( notification_rc != 0 )); then
        log WARNING "Unified Arr delete workflow completed, but its grouped notification failed."
        return 2
    fi
    log INFO "Unified Arr delete workflow completed successfully."
}


###############################################################################
# STATE: work only in a temporary copy until final atomic commit
###############################################################################

# A tracked record is created only after Radarr first reports hasFile=true.
# A missing run counts only when the movie is fileless and, when configured,
# unmonitored.  A fileless but still-monitored movie therefore resets the
# confirmation counter instead of being treated as a deletion.
radarr_apply_snapshot() {
    local movies_file="$1"
    local sidecar_manifests_file="$2"
    local next
    next="$(mktemp "$STATE_DIR/.state-snapshot.XXXXXX")" || return 1

    if ! jq --arg now "$RUN_AT" \
        --argjson require_unmonitored "$RADARR_REQUIRE_MOVIE_UNMONITORED" \
        --slurpfile sidecar_source "$sidecar_manifests_file" \
        --slurpfile source "$movies_file" '($source[0] // []) as $movies
        | (($sidecar_source | add) // {}) as $sidecar_manifests
        | .movies //= {}
        | .sidecarManifests = ((.sidecarManifests // {}) * $sidecar_manifests)
        | reduce $movies[] as $movie (.;
            ($movie.id | tostring) as $key
            | (.movies[$key] // {}) as $old
            | {
                movieId: $movie.id,
                title: ($movie.title // "Unknown"),
                year: ($movie.year // null),
                tmdbId: ($movie.tmdbId // null),
                lastObservedAt: $now,
                lastObservedMonitored: ($movie.monitored == true)
              } as $identity
            | if $movie.hasFile == true then
                .movies[$key] = (
                    $old + $identity + {
                        everHadFile: true,
                        lastKnownMovieFileId: ($movie.movieFileId // 0),
                        lastSeenWithFileAt: $now,
                        missingSince: null,
                        missingRuns: 0
                    }
                )
              elif $old.everHadFile == true then
                .movies[$key] = (
                    $old + $identity +
                    (if (($require_unmonitored | not) or ($movie.monitored != true)) then
                        {
                            missingSince: ($old.missingSince // $now),
                            missingRuns: (($old.missingRuns // 0) + 1)
                        }
                     else
                        {
                            missingSince: null,
                            missingRuns: 0
                        }
                     end)
                )
              else
                .
              end
        )
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

radarr_cleanup_history_eligible() {
    local movie_id="$1"
    if [[ "$REQUIRE_DELETE_HISTORY_EVENT" == false ]]; then
        printf 'true'
        return 0
    fi
    jq -r --argjson movie_id "$movie_id" '
        (.movies[($movie_id | tostring)].latestMovieFileDeletedHistory // null) != null
    ' "$WORK_STATE"
}

radarr_mark_sidecar_cleanup() {
    local movie_id="$1"
    local next
    local total_quarantined total_native_missing total_folders_removed

    total_quarantined=$((CLEANUP_PROGRESS_QUARANTINED + CLEANUP_QUARANTINED))
    total_native_missing=$((CLEANUP_PROGRESS_NATIVE_MISSING + CLEANUP_NATIVE_MISSING))
    total_folders_removed=$((CLEANUP_PROGRESS_FOLDERS_REMOVED + CLEANUP_FOLDERS_REMOVED))
    next="$(mktemp "$STATE_DIR/.state-sidecar-action.XXXXXX")" || return 1

    if ! jq --arg now "$RUN_AT" \
        --arg run_id "$CLEANUP_QUARANTINE_RUN_ID" \
        --argjson movie_id "$movie_id" \
        --argjson quarantined "$total_quarantined" \
        --argjson native_missing "$total_native_missing" \
        --argjson folders_removed "$total_folders_removed" '
        .sidecarCleanupActions //= {}
        | .sidecarCleanupActions[($movie_id | tostring)] = {
            movieId: $movie_id,
            completedAt: $now,
            quarantineRunId: (if $quarantined > 0 and $run_id != "" then $run_id else null end),
            quarantinedFiles: $quarantined,
            nativeMissingFiles: $native_missing,
            foldersRemoved: $folders_removed
          }
        | del(.sidecarManifests[($movie_id | tostring)])
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

radarr_new_candidate_count() {
    jq --arg now "$RUN_AT" '
        [
            .movies[]
            | select(.missingSince == $now and .missingRuns == 1)
        ]
        | length
    ' "$WORK_STATE"
}

radarr_log_new_candidates() {
    while IFS= read -r line; do
        [[ -n "$line" ]] && log WARNING "$line"
    done < <(
        jq -r --arg now "$RUN_AT" '
            .movies[]
            | select(.missingSince == $now and .missingRuns == 1)
            | "Deletion candidate: \(.title)\(if .year == null then "" else " (\(.year))" end) [movie \(.movieId)]; confirmation pending."
        ' "$WORK_STATE"
    )
}

# Current Radarr data is always required in addition to state.  This prevents
# a removed Radarr movie from being acted on and makes an old state file alone
# insufficient to create a tag.
radarr_confirmed_movies() {
    local movies_file="$1"
    jq --slurpfile source "$movies_file" \
        --argjson require_unmonitored "$RADARR_REQUIRE_MOVIE_UNMONITORED" \
        --argjson needed "$CONFIRMATION_RUNS" '($source[0] // []) as $movies
        | .movies as $state
        | [
            $movies[]
            | select(.hasFile != true)
            | select(($require_unmonitored | not) or (.monitored != true))
            | . as $movie
            | ($movie.id | tostring) as $key
            | ($state[$key] // {}) as $record
            | select($record.everHadFile == true and ($record.missingRuns // 0) >= $needed)
            | {
                id: $movie.id,
                title: ($movie.title // "Unknown"),
                year: ($movie.year // null),
                path: ($movie.path // ""),
                tags: ($movie.tags // [])
              }
          ]
        | unique_by(.id)
    ' "$WORK_STATE"
}

radarr_movies_missing_tag() {
    local candidates="$1"
    local tag_id="$2"

    if [[ "$tag_id" =~ ^[0-9]+$ ]]; then
        jq --argjson tag_id "$tag_id" '
            [ .[] | select(((.tags // []) | index($tag_id)) == null) ]
        ' <<< "$candidates"
    else
        printf '%s' "$candidates"
    fi
}

radarr_record_history_evidence() {
    local movie_id="$1"
    local evidence="$2"
    local next
    next="$(mktemp "$STATE_DIR/.state-history.XXXXXX")" || return 1

    if ! jq --arg now "$RUN_AT" --argjson movie_id "$movie_id" \
        --argjson evidence "$evidence" '
        .movies[($movie_id | tostring)] |= . + {
            lastHistoryInspectionAt: $now,
            latestMovieFileDeletedHistory: $evidence
        }
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

# This endpoint returns an array for one movie, so it cannot create a costly
# full-library History sweep.  Only the newest movieFileDeleted record is kept.
radarr_history_delete_event() {
    local movie_id="$1"
    local history

    history="$(api_get_json "/api/v3/history/movie?movieId=$movie_id&eventType=movieFileDeleted")" || return 1
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$history"; then
        log ERROR "Radarr History for movie $movie_id did not return an array."
        return 1
    fi
    jq '[
            .[]
            | select(.eventType == "movieFileDeleted")
            | {id: .id, date: .date, eventType: .eventType, data: (.data // {})}
        ]
        | sort_by(.date // "")
        | last // null
    ' <<< "$history"
}

radarr_mark_tag_actions() {
    local ids="$1"
    local next
    next="$(mktemp "$STATE_DIR/.state-action.XXXXXX")" || return 1
    if ! jq --arg now "$RUN_AT" --argjson ids "$ids" '
        reduce $ids[] as $id (.;
            .movies[($id | tostring)] |= . + {lastPlexDeletedTagAppliedAt: $now}
        )
    ' "$WORK_STATE" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    mv -f -- "$next" "$WORK_STATE"
}

radarr_commit_state() {
    local final backup had_errors
    final="$(mktemp "$STATE_DIR/.state-final.XXXXXX")" || return 1
    had_errors=false
    (( API_FAILURES > 0 || HISTORY_FAILURES > 0 || SIDECAR_FAILURES > 0 )) && had_errors=true

    if ! jq --arg now "$RUN_AT" --argjson had_errors "$had_errors" '
        .version = 4
        | .lastRun = $now
        | .lastRunHadApiErrors = $had_errors
        | .movies //= {}
        | .sidecarManifests //= {}
        | .sidecarCleanupActions //= {}
    ' "$WORK_STATE" > "$final" ||
       ! jq -e 'type == "object" and (.movies | type == "object")' "$final" >/dev/null; then
        rm -f -- "$final"
        return 1
    fi

    backup="$(mktemp "$STATE_DIR/.state-backup.XXXXXX")" || return 1
    if cp -- "$STATE_FILE" "$backup"; then
        mv -f -- "$backup" "$STATE_BACKUP"
    else
        rm -f -- "$backup"
        log WARNING "Could not update state backup."
    fi
    mv -f -- "$final" "$STATE_FILE"
}

radarr_movie_name() {
    local movie="$1"
    jq -r '"\(.title)\(if .year == null then "" else " (\(.year))" end) [movie \(.id)]"' <<< "$movie"
}

###############################################################################
# RADARR WORKFLOW
###############################################################################

run_radarr() (
APP_CONTEXT="RADARR"
ARR_NAME="Radarr"
ARR_URL="$RADARR_URL"
ARR_API_KEY="$RADARR_API_KEY"
ARR_TEMP_PREFIX="radarr"
ARR_USER_AGENT="$USER_AGENT Radarr"
STATE_DIR="$RUNTIME_DIR"
STATE_FILE="$RADARR_STATE_FILE"
STATE_BACKUP="$RADARR_STATE_BACKUP"
RUN_AT="$(date '+%Y-%m-%dT%H:%M:%S%z')"
WORK_STATE=""
CURRENT_SNAPSHOT_FILE=""
SIDECAR_BATCH_FILE=""
SIDECAR_ENTRY_FILE=""
API_FAILURES=0
HISTORY_FAILURES=0
MOVIES_LISTED=0
MOVIES_SCANNED=0
FILES_PRESENT=0
FIRST_MISSING=0
MOVIES_CONFIRMED=0
HISTORY_INSPECTIONS=0
HISTORY_DELETE_EVENTS=0
HISTORY_LIMIT_SKIPS=0
TAG_ACTIONS=0
SIDECARS_CAPTURED=0
SIDECARS_QUARANTINED=0
SIDECARS_NATIVE_MISSING=0
SIDECARS_CHANGED=0
SIDECARS_LATE_CANDIDATES=0
SIDECARS_LATE_CONFIRMED=0
SIDECAR_FAILURES=0
FOLDERS_REMOVED=0
FOLDER_CLEANUP_PENDING=0
MOVER_DEFERRALS=0
MOVER_GUARD_NOTICE_LOGGED=false
TAG_CATALOG=''
PLEX_DELETED_MOVIE_TAG_ID=''

trap cleanup_app EXIT
trap 'exit 130' INT TERM

[[ -n "$RADARR_URL" && "$RADARR_URL" != */ ]] || die "Set RADARR_URL without a trailing slash."
[[ -n "$RADARR_API_KEY" && "$RADARR_API_KEY" != PUT_YOUR_RADARR_API_KEY_HERE ]] ||
    die "Set RADARR_API_KEY."
[[ "$RADARR_REQUIRE_MOVIE_UNMONITORED" == true || "$RADARR_REQUIRE_MOVIE_UNMONITORED" == false ]] ||
    die "RADARR_REQUIRE_MOVIE_UNMONITORED must be true or false."
[[ "$PLEX_DELETED_MOVIE_TAG" =~ ^[a-z0-9-]+$ ]] ||
    die "PLEX_DELETED_MOVIE_TAG may contain only lowercase letters, numbers, and hyphens."

if [[ ! -f "$STATE_FILE" ]]; then
    INITIAL_STATE="$(mktemp "$STATE_DIR/.state-initial.XXXXXX")" ||
        die "Cannot create initial state file."
    printf '%s\n' '{"version":4,"lastRun":null,"lastRunHadApiErrors":false,"movies":{},"sidecarManifests":{},"sidecarCleanupActions":{}}' > "$INITIAL_STATE" &&
        mv -f -- "$INITIAL_STATE" "$STATE_FILE" || {
            rm -f -- "$INITIAL_STATE"
            die "Cannot create state file."
        }
    log INFO "Created state file; this first run establishes a baseline."
fi
if ! jq -e 'type == "object" and (.movies | type == "object")' "$STATE_FILE" >/dev/null; then
    die "State file is invalid: $STATE_FILE"
fi
WORK_STATE="$(mktemp "$STATE_DIR/.state-working.XXXXXX")" || die "Cannot create working state."
cp -- "$STATE_FILE" "$WORK_STATE" || die "Cannot copy state to working file."

###############################################################################
# RUN
###############################################################################

log INFO "Starting delete tagger (dry-run=$DRY_RUN, confirmations=$CONFIRMATION_RUNS)."
if [[ "$TRIGGER_LIBRARY_RESCAN" == true ]]; then
    log INFO "Requesting one Radarr all-library rescan before checking movies."
else
    log INFO "Using Radarr's current database state; no rescan will be requested."
fi

SYSTEM="$(api_get_json "/api/v3/system/status")" || {
    ((API_FAILURES += 1))
    die "Cannot contact Radarr; state was not changed."
}
if ! jq -e '.appName == "Radarr"' >/dev/null 2>&1 <<< "$SYSTEM"; then
    die "Configured RADARR_URL did not identify itself as Radarr."
fi
log INFO "Connected to Radarr $(jq -r '.version // "unknown"' <<< "$SYSTEM")."

if [[ "$TRIGGER_LIBRARY_RESCAN" == true ]]; then
    RESCAN_ID="$(start_arr_command '{"name":"RescanMovie"}')" || {
        ((API_FAILURES += 1))
        die "Could not start Radarr library rescan; state was not changed."
    }
    log INFO "Submitted Radarr library rescan command $RESCAN_ID; waiting before checking movies."
    wait_for_arr_command "$RESCAN_ID" || {
        ((API_FAILURES += 1))
        die "Radarr library rescan did not complete successfully; state was not changed."
    }
fi

# Keep this potentially large response in a file.  Passing a full library as
# jq --argjson would put it in exec(2)'s argument vector and can cause
# "Argument list too long" on larger libraries.
CURRENT_SNAPSHOT_FILE="$(mktemp "$STATE_DIR/.movies.XXXXXX")" ||
    die "Cannot create temporary movie snapshot."
if ! api_get_json "/api/v3/movie" > "$CURRENT_SNAPSHOT_FILE"; then
    ((API_FAILURES += 1))
    die "Could not retrieve movies; state was not changed."
fi
jq -e 'type == "array"' "$CURRENT_SNAPSHOT_FILE" >/dev/null ||
    die "Radarr /movie did not return an array."

MOVIES_LISTED="$(jq length "$CURRENT_SNAPSHOT_FILE")"
MOVIES_SCANNED="$MOVIES_LISTED"
FILES_PRESENT="$(jq '[.[] | select(.hasFile == true)] | length' "$CURRENT_SNAPSHOT_FILE")"

SIDECAR_BATCH_FILE="$(mktemp "$STATE_DIR/.sidecars.batch.XXXXXX")" ||
    die "Cannot create temporary Radarr sidecar manifest batch."
if [[ "$QUARANTINE_KODI_SIDECARS" == true ]] && (( FILES_PRESENT > 0 )); then
    while IFS= read -r MOVIE_WITH_FILE; do
        [[ -n "$MOVIE_WITH_FILE" ]] || continue
        MOVIE_ID="$(jq -r '.id' <<< "$MOVIE_WITH_FILE")"
        MOVIE_API_PATH="$(jq -r '.path // empty' <<< "$MOVIE_WITH_FILE")"
        MOVIE_PATH="$(map_arr_media_path "$MOVIE_API_PATH" "$RADARR_API_MOVIES_ROOT" "$MOVIES_ROOT" || true)"
        MOVIE_RELATIVE_PATH="$(jq -r '.movieFile.relativePath // empty' <<< "$MOVIE_WITH_FILE")"
        if [[ -z "$MOVIE_PATH" || -z "$MOVIE_RELATIVE_PATH" ]]; then
            ((SIDECAR_FAILURES += 1))
            log ERROR "Could not map or capture Kodi sidecars for Radarr movie $MOVIE_ID (API path: $MOVIE_API_PATH)."
            continue
        fi
        MEDIA_RELATIVE_PATHS="$(jq -cn --arg path "$MOVIE_RELATIVE_PATH" '[$path]')"
        [[ -n "$SIDECAR_ENTRY_FILE" ]] && rm -f -- "$SIDECAR_ENTRY_FILE"
        SIDECAR_ENTRY_FILE="$(mktemp "$STATE_DIR/.sidecars.entry.XXXXXX")" ||
            die "Cannot create temporary Radarr sidecar manifest."
        if capture_kodi_sidecars radarr "$MOVIE_PATH" "$MOVIES_ROOT" \
            "$MEDIA_RELATIVE_PATHS" > "$SIDECAR_ENTRY_FILE"; then
            CAPTURED="$(jq length "$SIDECAR_ENTRY_FILE")"
            ((SIDECARS_CAPTURED += CAPTURED))
            if ! jq -n --arg key "$MOVIE_ID" \
                --arg media_path "$MOVIE_PATH" \
                --arg media_root "$MOVIES_ROOT" \
                --arg now "$RUN_AT" \
                --slurpfile files_source "$SIDECAR_ENTRY_FILE" '
                ($files_source[0] // []) as $files
                | {($key):{
                    mediaPath:$media_path,
                    mediaRoot:$media_root,
                    bucket:"movies",
                    capturedAt:$now,
                    files:$files,
                    lateSidecarCandidates:[]
                }}
            ' >> "$SIDECAR_BATCH_FILE"; then
                die "Could not build Radarr sidecar manifest batch."
            fi
        else
            ((SIDECAR_FAILURES += 1))
            log ERROR "Kodi sidecar manifest capture failed for Radarr movie $MOVIE_ID; its previous manifest was retained."
        fi
        rm -f -- "$SIDECAR_ENTRY_FILE"
        SIDECAR_ENTRY_FILE=""
    done < <(jq -c '.[] | select(.hasFile == true)' "$CURRENT_SNAPSHOT_FILE")
fi

radarr_apply_snapshot "$CURRENT_SNAPSHOT_FILE" "$SIDECAR_BATCH_FILE" ||
    die "Could not update temporary state."
rm -f -- "$SIDECAR_BATCH_FILE"
SIDECAR_BATCH_FILE=""

FIRST_MISSING="$(radarr_new_candidate_count)"
(( FIRST_MISSING == 0 )) || radarr_log_new_candidates

CONFIRMED="$(radarr_confirmed_movies "$CURRENT_SNAPSHOT_FILE")" ||
    die "Could not calculate tag action plan."
MOVIES_CONFIRMED="$(jq length <<< "$CONFIRMED")"

if (( MOVIES_CONFIRMED > 0 )); then
    if ! load_tag_catalog; then
        ((API_FAILURES += 1))
        log ERROR "Could not load Radarr tags; confirmed movies will be retried next run."
    else
        PLEX_DELETED_MOVIE_TAG_ID="$(jq -r --arg label "$PLEX_DELETED_MOVIE_TAG" 'first(.[] | select(.label == $label) | .id) // empty' <<< "$TAG_CATALOG")"
        ACTION_CANDIDATES="$(radarr_movies_missing_tag "$CONFIRMED" "$PLEX_DELETED_MOVIE_TAG_ID")" ||
            die "Could not calculate movies that need the '$PLEX_DELETED_MOVIE_TAG' tag."
        ACTION_CANDIDATE_COUNT="$(jq length <<< "$ACTION_CANDIDATES")"

        if (( ACTION_CANDIDATE_COUNT == 0 )); then
            log INFO "All $MOVIES_CONFIRMED confirmed movie(s) already have the '$PLEX_DELETED_MOVIE_TAG' tag."
        else
            ELIGIBLE_IDS='[]'
            while IFS= read -r MOVIE; do
                [[ -n "$MOVIE" ]] || continue
                MOVIE_ID="$(jq -r '.id' <<< "$MOVIE")"
                MOVIE_LABEL="$(radarr_movie_name "$MOVIE")"
                HISTORY_EVIDENCE=null
                HISTORY_INSPECTED=false

                if [[ "$INSPECT_DELETE_HISTORY" == true ]]; then
                    if (( HISTORY_INSPECTIONS < MAX_HISTORY_INSPECTIONS_PER_RUN )); then
                        HISTORY_INSPECTED=true
                        ((HISTORY_INSPECTIONS += 1))
                        if HISTORY_EVIDENCE="$(radarr_history_delete_event "$MOVIE_ID")"; then
                            radarr_record_history_evidence "$MOVIE_ID" "$HISTORY_EVIDENCE" ||
                                die "Could not record History evidence for $MOVIE_LABEL."
                            if [[ "$HISTORY_EVIDENCE" != null ]]; then
                                ((HISTORY_DELETE_EVENTS += 1))
                                log INFO "History audit: $MOVIE_LABEL has movieFileDeleted event $(jq -r '.id // "unknown"' <<< "$HISTORY_EVIDENCE") at $(jq -r '.date // "unknown"' <<< "$HISTORY_EVIDENCE")."
                            else
                                log INFO "History audit: $MOVIE_LABEL has no movieFileDeleted event."
                            fi
                        else
                            ((HISTORY_FAILURES += 1))
                            log WARNING "History audit failed for $MOVIE_LABEL."
                        fi
                    else
                        ((HISTORY_LIMIT_SKIPS += 1))
                        log WARNING "History inspection cap reached; deferred audit for $MOVIE_LABEL."
                    fi
                fi

                if [[ "$REQUIRE_DELETE_HISTORY_EVENT" == true ]] &&
                   { [[ "$HISTORY_INSPECTED" != true ]] || [[ "$HISTORY_EVIDENCE" == null ]]; }; then
                    log INFO "Not tagging $MOVIE_LABEL because no verified movieFileDeleted History event is available."
                    queue_attention_notification WARNING Radarr \
                        "$MOVIE_LABEL tag action awaiting History evidence" \
                        "The required movieFileDeleted event is unavailable; the movie remains untagged."
                    continue
                fi

                ELIGIBLE_IDS="$(jq --argjson movie_id "$MOVIE_ID" '. + [$movie_id] | unique' <<< "$ELIGIBLE_IDS")" ||
                    die "Could not extend the tag action plan."
            done < <(jq -c '.[]' <<< "$ACTION_CANDIDATES")

            ELIGIBLE_COUNT="$(jq length <<< "$ELIGIBLE_IDS")"
            if (( ELIGIBLE_COUNT > 0 )); then
                if [[ "$DRY_RUN" == true ]]; then
                    if [[ ! "$PLEX_DELETED_MOVIE_TAG_ID" =~ ^[0-9]+$ ]]; then
                        log INFO "DRY RUN: would create Radarr tag '$PLEX_DELETED_MOVIE_TAG'."
                    fi
                    while IFS= read -r MOVIE; do
                        [[ -n "$MOVIE" ]] || continue
                        log INFO "DRY RUN: would add '$PLEX_DELETED_MOVIE_TAG' to $(radarr_movie_name "$MOVIE")."
                        queue_action_notification Radarr \
                            "$(radarr_movie_name "$MOVIE") tag update" \
                            "Tag to add: $PLEX_DELETED_MOVIE_TAG"
                    done < <(
                        jq --argjson ids "$ELIGIBLE_IDS" '
                            [ .[] | . as $movie | select(($ids | index($movie.id)) != null) ][]
                        ' <<< "$ACTION_CANDIDATES" | jq -c .
                    )
                    TAG_ACTIONS="$ELIGIBLE_COUNT"
                else
                    ensure_tag_id "$PLEX_DELETED_MOVIE_TAG" PLEX_DELETED_MOVIE_TAG_ID || {
                        ((API_FAILURES += 1))
                        log ERROR "Could not prepare '$PLEX_DELETED_MOVIE_TAG'; confirmed movies will be retried next run."
                        PLEX_DELETED_MOVIE_TAG_ID=''
                    }
                    if [[ "$PLEX_DELETED_MOVIE_TAG_ID" =~ ^[0-9]+$ ]]; then
                        PAYLOAD="$(jq -cn --argjson ids "$ELIGIBLE_IDS" --argjson tag_id "$PLEX_DELETED_MOVIE_TAG_ID" '
                            {movieIds: $ids, tags: [$tag_id], applyTags: "add"}
                        ')"
                        if api_put_json "/api/v3/movie/editor" "$PAYLOAD"; then
                            radarr_mark_tag_actions "$ELIGIBLE_IDS" ||
                                die "Could not record applied tag actions."
                            while IFS= read -r MOVIE; do
                                [[ -n "$MOVIE" ]] || continue
                                log INFO "Added '$PLEX_DELETED_MOVIE_TAG' to $(radarr_movie_name "$MOVIE")."
                                queue_action_notification Radarr \
                                    "$(radarr_movie_name "$MOVIE") tag update" \
                                    "Added tag: $PLEX_DELETED_MOVIE_TAG"
                            done < <(
                                jq --argjson ids "$ELIGIBLE_IDS" '
                                    [ .[] | . as $movie | select(($ids | index($movie.id)) != null) ][]
                                ' <<< "$ACTION_CANDIDATES" | jq -c .
                            )
                            TAG_ACTIONS="$ELIGIBLE_COUNT"
                        else
                            ((API_FAILURES += 1))
                            log ERROR "Bulk tag update failed; confirmed movies will be retried next run."
                            queue_attention_notification ERROR Radarr \
                                "Confirmed movie tag update failed" \
                                "$ELIGIBLE_COUNT confirmed movie(s) could not be tagged and will be retried."
                        fi
                    fi
                fi
            fi
        fi
    fi
fi

if [[ "$QUARANTINE_KODI_SIDECARS" == true ]] && (( MOVIES_CONFIRMED > 0 )); then
    while IFS= read -r MOVIE; do
        [[ -n "$MOVIE" ]] || continue
        MOVIE_ID="$(jq -r '.id' <<< "$MOVIE")"
        MOVIE_API_PATH="$(jq -r '.path // empty' <<< "$MOVIE")"
        MOVIE_PATH="$(map_arr_media_path "$MOVIE_API_PATH" "$RADARR_API_MOVIES_ROOT" "$MOVIES_ROOT" || true)"
        MOVIE_LABEL="$(radarr_movie_name "$MOVIE")"
        if [[ -z "$MOVIE_PATH" ]]; then
            ((SIDECAR_FAILURES += 1))
            log ERROR "Cannot map Radarr path '$MOVIE_API_PATH' from RADARR_API_MOVIES_ROOT to MOVIES_ROOT; sidecar cleanup for $MOVIE_LABEL was deferred."
            queue_attention_notification WARNING Radarr "$MOVIE_LABEL cleanup deferred" \
                "The Radarr media path could not be mapped safely: $MOVIE_API_PATH"
            continue
        fi
        if [[ "$(radarr_cleanup_history_eligible "$MOVIE_ID")" != true ]]; then
            log INFO "Not quarantining Kodi sidecars for $MOVIE_LABEL because required deletion History evidence is unavailable."
            continue
        fi
        MANIFEST="$(prepare_sidecar_cleanup_manifest "$MOVIE_ID" \
            "$MOVIE_PATH" "$MOVIES_ROOT" movies)" ||
            die "Could not prepare Kodi sidecar cleanup state for $MOVIE_LABEL."
        if jq -e 'type == "object" and (.cleanupAlreadyRecorded // false) == true' \
            >/dev/null 2>&1 <<< "$MANIFEST"; then
            :
        elif quarantine_recorded_sidecars radarr movies "$MOVIES_ROOT" "$MOVIE_PATH" "$MANIFEST"; then
            ((SIDECARS_QUARANTINED += CLEANUP_QUARANTINED))
            ((SIDECARS_NATIVE_MISSING += CLEANUP_NATIVE_MISSING))
            ((SIDECARS_CHANGED += CLEANUP_CHANGED))
            ((FOLDERS_REMOVED += CLEANUP_FOLDERS_REMOVED))
            queue_cleanup_action_notification Radarr "$MOVIE_LABEL" "$MOVIE_PATH"
            if [[ "$CLEANUP_COMPLETE" == true ]]; then
                queue_folder_resolution_notification Radarr "$MOVIE_ID" \
                    "$MOVIE_LABEL folder cleanup" "$MOVIE_PATH"
                radarr_mark_sidecar_cleanup "$MOVIE_ID" ||
                    die "Could not record Kodi sidecar cleanup for $MOVIE_LABEL."
            elif [[ "$CLEANUP_FOLDER_PENDING" == true ]]; then
                mark_sidecar_folder_cleanup_pending "$MOVIE_ID" "$MOVIE_PATH" \
                    "$MOVIES_ROOT" movies ||
                    die "Could not retain pending folder cleanup for $MOVIE_LABEL."
                ((FOLDER_CLEANUP_PENDING += 1))
                queue_folder_blocker_notification Radarr "$MOVIE_ID" \
                    "$MOVIE_LABEL folder cleanup pending" "$MOVIE_PATH"
            elif (( CLEANUP_CHANGED > 0 )); then
                queue_attention_notification WARNING Radarr \
                    "$MOVIE_LABEL sidecar cleanup deferred" \
                    "$CLEANUP_CHANGED recorded sidecar file(s) changed or became unsafe. See $LOG_FILE."
            fi
        else
            CLEANUP_RC=$?
            case "$CLEANUP_RC" in
                3) ;;
                4) ((MOVER_DEFERRALS += 1)) ;;
                *)
                    ((SIDECAR_FAILURES += 1))
                    log ERROR "Kodi sidecar quarantine failed for $MOVIE_LABEL; its manifest was retained."
                    queue_attention_notification ERROR Radarr \
                        "$MOVIE_LABEL sidecar quarantine failed" \
                        "The manifest was retained and the next daily run will retry. See $LOG_FILE."
                    ;;
            esac
        fi
    done < <(jq -c '.[]' <<< "$CONFIRMED")
fi

radarr_commit_state || die "Could not atomically save state."
WORK_STATE=""

ACTION_LABEL=applied
[[ "$DRY_RUN" == true ]] && ACTION_LABEL=would-apply
log INFO "Summary: movies-listed=$MOVIES_LISTED, movies-scanned=$MOVIES_SCANNED, files-present=$FILES_PRESENT, first-missing=$FIRST_MISSING, confirmed=$MOVIES_CONFIRMED, history-inspected=$HISTORY_INSPECTIONS, history-delete-events=$HISTORY_DELETE_EVENTS, history-cap-skips=$HISTORY_LIMIT_SKIPS, tag-actions-$ACTION_LABEL=$TAG_ACTIONS, sidecars-captured=$SIDECARS_CAPTURED, sidecars-$ACTION_LABEL=$SIDECARS_QUARANTINED, late-sidecar-candidates=$SIDECARS_LATE_CANDIDATES, late-sidecars-confirmed-$ACTION_LABEL=$SIDECARS_LATE_CONFIRMED, sidecars-native-missing=$SIDECARS_NATIVE_MISSING, sidecars-changed=$SIDECARS_CHANGED, folders-removed-$ACTION_LABEL=$FOLDERS_REMOVED, folder-cleanup-pending=$FOLDER_CLEANUP_PENDING, mover-deferrals=$MOVER_DEFERRALS, api-failures=$API_FAILURES, history-failures=$HISTORY_FAILURES, sidecar-failures=$SIDECAR_FAILURES."

if (( API_FAILURES > 0 || HISTORY_FAILURES > 0 || SIDECAR_FAILURES > 0 )); then
    FAILURE_SEVERITY=WARNING
    (( API_FAILURES > 0 || SIDECAR_FAILURES > 0 )) && FAILURE_SEVERITY=ERROR
    queue_attention_notification "$FAILURE_SEVERITY" Radarr \
        "Daily Radarr delete-sync completed with failures" \
        "API failures: $API_FAILURES; History failures: $HISTORY_FAILURES; sidecar failures: $SIDECAR_FAILURES. See $LOG_FILE."
    log WARNING "Completed with API, History, or sidecar failures; safe state was saved and unfinished actions will be retried."
    exit 2
fi
log INFO "Completed successfully."
)

main "$@"
