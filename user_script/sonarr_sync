#!/usr/bin/env bash
#
# Sonarr - Plex Delete Sync
#
# Once-daily, persistent-state deletion confirmation. It NEVER unmonitors a
# series. Requirements: bash 4+, curl, jq.

set -uo pipefail
IFS=$'\n\t'
umask 077

###############################################################################
# CONFIGURATION
###############################################################################

# No trailing slash.
SONARR_URL="http://192.168.50.4:8989"
SONARR_API_KEY="PUT_YOUR_SONARR_API_KEY_HERE"

STATE_DIR="/mnt/user/cloud/logs/sonarr_delete_monitor"
STATE_FILE="$STATE_DIR/state.json"
STATE_BACKUP="$STATE_DIR/state.json.bak"
LOG_FILE="$STATE_DIR/delete-monitor.log"
LOCK_DIR="$STATE_DIR/delete-monitor.lock"

# Keep true for at least two scheduled runs before changing it to false.
# Dry-run still creates state and confirms candidates, but never changes Sonarr.
DRY_RUN=true
CONFIRMATION_RUNS=2
UNMONITOR_SEASON=true

# Default-off final safeguard.  When true, a series can be unmonitored only
# after the state proves it once had downloaded media, every such file has a
# confirmed deletion, no current episode has a file or remains monitored, and
# every normal season is already (or is being) unmonitored.  Specials/Season 0
# do not block this action.  The script NEVER disables a series with no proven
# download history in its state file.
UNMONITOR_SERIES=false

# Sonarr tags are series-level only.  The first tag means one or more seasons
# of that series were unmonitored after a Plex deletion; it does NOT mean that
# the entire series was deleted.  The second tag is added only if this script
# unmonitors the series itself.  Existing series tags are always preserved.
PLEX_DELETED_SEASON_TAG="plex-deleted-season"
PLEX_DELETED_SERIES_TAG="plex-deleted-series"

# API-only detection cannot see a filesystem deletion until Sonarr has scanned
# it.  Leave this false for the fast mode: the script uses Sonarr's existing
# database state and adds season unmonitoring after Sonarr's normal scan has
# observed a deletion.  The User Scripts schedule does NOT need to line up
# exactly with Sonarr's scan; a run before that scan simply sees no change, and
# the next run after it starts the persistent confirmation.
#
# Set true only when you explicitly want this script to request one full-library
# Sonarr rescan and wait for it.  That will inspect media storage and can spin
# up library disks, so it is deliberately disabled by default.
TRIGGER_SONARR_RESCAN=false
RESCAN_TIMEOUT_SECONDS=7200
RESCAN_POLL_SECONDS=10

# A progress line is written for the first series and then every N series, so
# a long library inspection is visibly active without filling the log.
PROGRESS_LOG_EVERY=25

MAX_LOG_SIZE_MB=10
MAX_LOG_FILES=5
HTTP_CONNECT_TIMEOUT=10
HTTP_MAX_TIME=90
HTTP_RETRIES=2
USER_AGENT="Sonarr-Plex-Delete-Sync/2.0"

###############################################################################
# END CONFIGURATION
###############################################################################

RUN_AT="$(date '+%Y-%m-%dT%H:%M:%S%z')"
LOCK_HELD=false
WORK_STATE=""
CURRENT_EPISODES_FILE=""
API_FAILURES=0
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
TAG_CATALOG=''
PLEX_DELETED_SEASON_TAG_ID=''
PLEX_DELETED_SERIES_TAG_ID=''

log() {
    local level="$1"
    shift
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" |
        tee -a "$LOG_FILE" >&2
}

die() {
    log ERROR "$*"
    exit 1
}

cleanup() {
    local status=$?
    [[ -n "$WORK_STATE" && -f "$WORK_STATE" ]] && rm -f -- "$WORK_STATE"
    [[ -n "$CURRENT_EPISODES_FILE" && -f "$CURRENT_EPISODES_FILE" ]] &&
        rm -f -- "$CURRENT_EPISODES_FILE"
    if [[ "$LOCK_HELD" == true ]]; then
        rm -f -- "$LOCK_DIR/pid"
        rmdir -- "$LOCK_DIR" 2>/dev/null || true
    fi
    trap - EXIT
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

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

# Temporary files live beside state.json so state replacement stays atomic.
# A normal exit removes them through cleanup(), but SIGKILL, a reboot, or a
# forced stop in User Scripts can prevent traps from running.  This runs only
# after the exclusive lock is held, so no active instance's files are touched.
remove_stale_temp_files() {
    local file removed=0 nullglob_was_set=false
    local -a stale_files

    shopt -q nullglob && nullglob_was_set=true
    shopt -s nullglob
    stale_files=(
        "$STATE_DIR"/.state-working.*
        "$STATE_DIR"/.state-snapshot.*
        "$STATE_DIR"/.state-action.*
        "$STATE_DIR"/.state-season.*
        "$STATE_DIR"/.state-final.*
        "$STATE_DIR"/.state-backup.*
        "$STATE_DIR"/.state-initial.*
        "$STATE_DIR"/.episodes.*
        "$STATE_DIR"/.sonarr-body.*
        "$STATE_DIR"/.sonarr-error.*
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

###############################################################################
# API: one response body on stdout; useful diagnostics on errors
###############################################################################

api_request() {
    local method="$1"
    local endpoint="$2"
    local payload="$3"
    local body err http_status curl_status message

    body="$(mktemp "$STATE_DIR/.sonarr-body.XXXXXX")" || return 1
    err="$(mktemp "$STATE_DIR/.sonarr-error.XXXXXX")" || {
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
                --header "X-Api-Key: $SONARR_API_KEY" \
                --header 'Accept: application/json' \
                --header "User-Agent: $USER_AGENT" \
                --output "$body" --write-out '%{http_code}' \
                "$SONARR_URL$endpoint" 2>"$err"
        )"
    else
        http_status="$(
            curl --silent --show-error \
                --connect-timeout "$HTTP_CONNECT_TIMEOUT" \
                --max-time "$HTTP_MAX_TIME" \
                --retry "$HTTP_RETRIES" --retry-all-errors \
                --request "$method" \
                --header "X-Api-Key: $SONARR_API_KEY" \
                --header 'Accept: application/json' \
                --header 'Content-Type: application/json' \
                --header "User-Agent: $USER_AGENT" \
                --data-binary "$payload" \
                --output "$body" --write-out '%{http_code}' \
                "$SONARR_URL$endpoint" 2>"$err"
        )"
    fi
    curl_status=$?

    if (( curl_status != 0 )) || ! [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
        message="$({ tr '\r\n' ' ' < "$err"; tr '\r\n' ' ' < "$body"; } | cut -c1-500)"
        [[ -n "$http_status" ]] || http_status=none
        [[ -n "$message" ]] || message="no response body"
        log ERROR "Sonarr $method $endpoint failed (curl=$curl_status HTTP=$http_status): $message"
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
        log ERROR "Sonarr GET $endpoint returned invalid JSON."
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

# Load the small tag catalogue once in live mode.  Dry-run deliberately skips
# it: previews must not create tags or otherwise modify Sonarr.
load_tag_catalog() {
    local tags
    tags="$(api_get_json "/api/v3/tag")" || return 1
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$tags"; then
        log ERROR "Sonarr /tag did not return an array."
        return 1
    fi
    TAG_CATALOG="$tags"
}

# Set the named global variable to an existing tag ID or create the tag.
# A failed create is followed by one catalogue refresh to tolerate another
# Sonarr client creating the same tag at the same time.
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
                log ERROR "Could not create or find Sonarr tag '$label'."
                return 1
            }
        else
            TAG_CATALOG="$(jq --arg label "$label" --argjson id "$id" '
                if any(.[]; .id == $id) then . else . + [{id: $id, label: $label}] end
            ' <<< "$TAG_CATALOG")" || return 1
            log INFO "Created Sonarr tag '$label'."
        fi
    fi

    printf -v "$destination" '%s' "$id"
}

# Submit one all-library RescanSeries command.  Omitting seriesId is deliberate:
# Sonarr scans the complete library under a single tracked command.
start_library_rescan() {
    local response command_id
    response="$(api_post_json "/api/v3/command" '{"name":"RescanSeries"}')" || return 1
    command_id="$(jq -r '.id // empty' <<< "$response")"
    [[ "$command_id" =~ ^[0-9]+$ ]] || {
        log ERROR "Sonarr accepted RescanSeries but did not return a command ID."
        return 1
    }
    printf '%s' "$command_id"
}

wait_for_rescan() {
    local command_id="$1"
    local started now elapsed last_notice=-1 status result
    started="$(date +%s)"

    while true; do
        COMMAND_JSON="$(api_get_json "/api/v3/command/$command_id")" || return 1
        status="$(jq -r '.status // "unknown"' <<< "$COMMAND_JSON")"
        result="$(jq -r '.result // "unknown"' <<< "$COMMAND_JSON")"

        case "$status" in
            completed)
                if [[ "$result" == failed ]]; then
                    log ERROR "Sonarr library rescan command $command_id completed with result=failed."
                    return 1
                fi
                log INFO "Sonarr library rescan command $command_id completed."
                return 0
                ;;
            failed|aborted)
                log ERROR "Sonarr library rescan command $command_id ended with status=$status, result=$result."
                return 1
                ;;
        esac

        now="$(date +%s)"
        elapsed=$((now - started))
        if (( elapsed >= RESCAN_TIMEOUT_SECONDS )); then
            log ERROR "Timed out after ${RESCAN_TIMEOUT_SECONDS}s waiting for Sonarr library rescan command $command_id (status=$status)."
            return 1
        fi
        if (( elapsed / 60 > last_notice )); then
            last_notice=$((elapsed / 60))
            log INFO "Waiting for Sonarr library rescan command $command_id (status=$status, elapsed=${elapsed}s)."
        fi
        sleep "$RESCAN_POLL_SECONDS"
    done
}

###############################################################################
# STATE: work only in a temporary copy until final atomic commit
###############################################################################

apply_snapshot() {
    local series_id="$1"
    local series_title="$2"
    local episodes_file="$3"
    local next
    next="$(mktemp "$STATE_DIR/.state-snapshot.XXXXXX")" || return 1

    if ! jq --argjson series_id "$series_id" \
        --arg series_title "$series_title" \
        --arg now "$RUN_AT" \
        --slurpfile source "$episodes_file" '($source[0] // []) as $episodes
        | .episodes //= {}
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

confirmed_episode_ids() {
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

new_candidate_count() {
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

log_new_candidates() {
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

# A season is eligible only if every historically downloaded episode in that
# season is currently present in Sonarr, fileless, and confirmed missing. It
# must also have no current monitored episodes after this run's episode action.
candidate_seasons() {
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
candidate_series() {
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

mark_episode_action() {
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

mark_season_action() {
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

mark_series_action() {
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

commit_state() {
    local final backup had_errors
    final="$(mktemp "$STATE_DIR/.state-final.XXXXXX")" || return 1
    had_errors=false
    (( API_FAILURES > 0 )) && had_errors=true

    if ! jq --arg now "$RUN_AT" --argjson had_errors "$had_errors" '
        .version = 3
        | .lastRun = $now
        | .lastRunHadApiErrors = $had_errors
        | .episodes //= {}
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
# INITIALIZATION
###############################################################################

mkdir -p -- "$STATE_DIR" || exit 1
: > "$LOG_FILE" || exit 1
command -v curl >/dev/null 2>&1 || die "curl is required."
command -v jq >/dev/null 2>&1 || die "jq is required."
[[ -n "$SONARR_URL" && "$SONARR_URL" != */ ]] || die "Set SONARR_URL without a trailing slash."
[[ -n "$SONARR_API_KEY" && "$SONARR_API_KEY" != PUT_YOUR_SONARR_API_KEY_HERE ]] ||
    die "Set SONARR_API_KEY."
[[ "$DRY_RUN" == true || "$DRY_RUN" == false ]] || die "DRY_RUN must be true or false."
[[ "$UNMONITOR_SEASON" == true || "$UNMONITOR_SEASON" == false ]] ||
    die "UNMONITOR_SEASON must be true or false."
[[ "$UNMONITOR_SERIES" == true || "$UNMONITOR_SERIES" == false ]] ||
    die "UNMONITOR_SERIES must be true or false."
[[ "$PLEX_DELETED_SEASON_TAG" =~ ^[a-z0-9-]+$ ]] ||
    die "PLEX_DELETED_SEASON_TAG may contain only lowercase letters, numbers, and hyphens."
[[ "$PLEX_DELETED_SERIES_TAG" =~ ^[a-z0-9-]+$ ]] ||
    die "PLEX_DELETED_SERIES_TAG may contain only lowercase letters, numbers, and hyphens."
[[ "$PLEX_DELETED_SEASON_TAG" != "$PLEX_DELETED_SERIES_TAG" ]] ||
    die "PLEX_DELETED_SEASON_TAG and PLEX_DELETED_SERIES_TAG must be different."
[[ "$TRIGGER_SONARR_RESCAN" == true || "$TRIGGER_SONARR_RESCAN" == false ]] ||
    die "TRIGGER_SONARR_RESCAN must be true or false."
[[ "$CONFIRMATION_RUNS" =~ ^[0-9]+$ ]] && (( CONFIRMATION_RUNS >= 2 )) ||
    die "CONFIRMATION_RUNS must be an integer of at least 2."
[[ "$MAX_LOG_SIZE_MB" =~ ^[1-9][0-9]*$ && "$MAX_LOG_FILES" =~ ^[1-9][0-9]*$ ]] ||
    die "MAX_LOG_SIZE_MB and MAX_LOG_FILES must be positive integers."
[[ "$RESCAN_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ && "$RESCAN_POLL_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
    die "RESCAN_TIMEOUT_SECONDS and RESCAN_POLL_SECONDS must be positive integers."
[[ "$PROGRESS_LOG_EVERY" =~ ^[1-9][0-9]*$ ]] ||
    die "PROGRESS_LOG_EVERY must be a positive integer."
rotate_log

# Atomic directory creation avoids the race in a normal PID-file lock.
if ! mkdir -- "$LOCK_DIR" 2>/dev/null; then
    OLD_PID=""
    [[ -r "$LOCK_DIR/pid" ]] && OLD_PID="$(<"$LOCK_DIR/pid")"
    if [[ "$OLD_PID" =~ ^[0-9]+$ ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        log WARNING "Another instance is already running (PID $OLD_PID); exiting."
        exit 0
    fi
    log WARNING "Removing stale lock."
    rm -f -- "$LOCK_DIR/pid"
    rmdir -- "$LOCK_DIR" 2>/dev/null || die "Cannot clear stale lock directory."
    mkdir -- "$LOCK_DIR" || die "Cannot acquire lock."
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid" || die "Cannot write lock PID."
LOCK_HELD=true

# Safe only after the lock above: an existing running instance would have made
# this invocation exit instead of reaching this point.
remove_stale_temp_files

if [[ ! -f "$STATE_FILE" ]]; then
    INITIAL_STATE="$(mktemp "$STATE_DIR/.state-initial.XXXXXX")" ||
        die "Cannot create initial state file."
    printf '%s\n' '{"version":3,"lastRun":null,"lastRunHadApiErrors":false,"episodes":{}}' > "$INITIAL_STATE" &&
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

log INFO "Starting once-daily delete sync (dry-run=$DRY_RUN, confirmations=$CONFIRMATION_RUNS)."
if [[ "$TRIGGER_SONARR_RESCAN" == true ]]; then
    log INFO "API-only mode: requesting one Sonarr all-library rescan before checking episodes."
else
    log INFO "Using Sonarr's current database state; no rescan will be requested."
fi

SYSTEM="$(api_get_json "/api/v3/system/status")" || {
    ((API_FAILURES += 1))
    die "Cannot contact Sonarr; state was not changed."
}
log INFO "Connected to Sonarr $(jq -r '.version // "unknown"' <<< "$SYSTEM")."

if [[ "$DRY_RUN" == false ]]; then
    load_tag_catalog || {
        ((API_FAILURES += 1))
        die "Could not load Sonarr tags; state was not changed."
    }
fi

if [[ "$TRIGGER_SONARR_RESCAN" == true ]]; then
    RESCAN_ID="$(start_library_rescan)" || {
        ((API_FAILURES += 1))
        die "Could not start Sonarr library rescan; state was not changed."
    }
    log INFO "Submitted Sonarr library rescan command $RESCAN_ID; waiting before checking episodes."
    wait_for_rescan "$RESCAN_ID" || {
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
    [[ -n "$CURRENT_EPISODES_FILE" ]] && rm -f -- "$CURRENT_EPISODES_FILE"
    CURRENT_EPISODES_FILE="$(mktemp "$STATE_DIR/.episodes.XXXXXX")" ||
        die "Cannot create temporary episode snapshot."
    if ! api_get_json "/api/v3/episode?seriesId=$SERIES_ID" > "$CURRENT_EPISODES_FILE"; then
        ((API_FAILURES += 1))
        log ERROR "Skipping $SERIES_TITLE; its state was not advanced."
        continue
    fi
    jq -e 'type == "array"' "$CURRENT_EPISODES_FILE" >/dev/null || {
        ((API_FAILURES += 1))
        log ERROR "Skipping $SERIES_TITLE; Sonarr returned a non-array episode response."
        continue
    }

    ((SERIES_SCANNED += 1))
    COUNT="$(jq length "$CURRENT_EPISODES_FILE")"
    PRESENT="$(jq '[.[] | select(.hasFile == true)] | length' "$CURRENT_EPISODES_FILE")"
    ((EPISODES_SCANNED += COUNT))
    ((FILES_PRESENT += PRESENT))

    apply_snapshot "$SERIES_ID" "$SERIES_TITLE" "$CURRENT_EPISODES_FILE" ||
        die "Could not update temporary state for $SERIES_TITLE."

    NEW="$(new_candidate_count "$SERIES_ID")"
    ((FIRST_MISSING += NEW))
    (( NEW > 0 )) && log_new_candidates "$SERIES_ID"

    IDS="$(confirmed_episode_ids "$CURRENT_EPISODES_FILE")" ||
        die "Could not calculate episode action plan for $SERIES_TITLE."
    ID_COUNT="$(jq length <<< "$IDS")"
    ((EPISODES_CONFIRMED += ID_COUNT))
    EFFECTIVE='[]'

    if (( ID_COUNT > 0 )); then
        if [[ "$DRY_RUN" == true ]]; then
            log INFO "DRY RUN: would unmonitor $ID_COUNT confirmed episode(s) in $SERIES_TITLE: $(jq -r 'join(", ")' <<< "$IDS")."
            EFFECTIVE="$IDS"
            ((EPISODE_ACTIONS += ID_COUNT))
        else
            PAYLOAD="$(jq -cn --argjson ids "$IDS" '{episodeIds:$ids, monitored:false}')"
            if api_put_json "/api/v3/episode/monitor" "$PAYLOAD"; then
                log INFO "Unmonitored $ID_COUNT confirmed episode(s) in $SERIES_TITLE: $(jq -r 'join(", ")' <<< "$IDS")."
                mark_episode_action "$IDS" ||
                    die "Could not record episode action in temporary state."
                EFFECTIVE="$IDS"
                ((EPISODE_ACTIONS += ID_COUNT))
            else
                ((API_FAILURES += 1))
                log ERROR "Episode update failed for $SERIES_TITLE; it will be retried next run."
            fi
        fi
    fi

    # Build independent season and series plans.  The series plan is default
    # off and still needs a fresh series-detail check below.
    SEASONS='[]'
    if [[ "$UNMONITOR_SEASON" == true ]]; then
        SEASONS="$(candidate_seasons "$SERIES_ID" "$CURRENT_EPISODES_FILE" "$EFFECTIVE")" ||
            die "Could not calculate season action plan for $SERIES_TITLE."
    fi
    SEASON_COUNT="$(jq length <<< "$SEASONS")"

    SERIES_PRECONDITION=false
    if [[ "$UNMONITOR_SERIES" == true ]]; then
        SERIES_PRECONDITION="$(candidate_series "$SERIES_ID" "$CURRENT_EPISODES_FILE" "$EFFECTIVE")" ||
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
            mark_season_action "$SERIES_ID" "$ACTIVE" ||
                die "Could not record season action in temporary state."
            ((SEASON_ACTIONS += ACTIVE_COUNT))
        fi
        if [[ "$SERIES_ACTION" == true ]]; then
            log INFO "Unmonitored series $SERIES_TITLE after all normal seasons were unmonitored."
            mark_series_action "$SERIES_ID" ||
                die "Could not record series action in temporary state."
            ((SERIES_ACTIONS += 1))
        fi
        log INFO "Ensured series tag(s) [$ACTION_TAG_LABEL_TEXT] on $SERIES_TITLE."
        ((TAGGED_SERIES_ACTIONS += 1))
    else
        ((API_FAILURES += 1))
        log ERROR "Season/series update failed for $SERIES_TITLE; it will be retried next run."
    fi
done < <(
    {
        jq -r '.[] | select(.monitored == true) | .id' <<< "$SERIES"
        jq -r '.episodes | to_entries[]? | select((.value.missingRuns // 0) > 0) | .value.seriesId' "$WORK_STATE"
    } | sort -nu
)

commit_state || die "Could not atomically save state."
WORK_STATE=""

ACTION_LABEL=applied
[[ "$DRY_RUN" == true ]] && ACTION_LABEL=would-apply
log INFO "Summary: series-listed=$SERIES_LISTED, series-scanned=$SERIES_SCANNED, episodes=$EPISODES_SCANNED, files-present=$FILES_PRESENT, first-missing=$FIRST_MISSING, confirmed=$EPISODES_CONFIRMED, episode-actions-$ACTION_LABEL=$EPISODE_ACTIONS, season-actions-$ACTION_LABEL=$SEASON_ACTIONS, series-actions-$ACTION_LABEL=$SERIES_ACTIONS, tagged-series-$ACTION_LABEL=$TAGGED_SERIES_ACTIONS, api-failures=$API_FAILURES."

if (( API_FAILURES > 0 )); then
    log WARNING "Completed with API failures; only successfully retrieved series advanced their confirmation state."
    exit 2
fi
log INFO "Completed successfully."
