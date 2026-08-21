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
RUNTIME_DIR="/mnt/user/cloud/logs/arr_delete_sync_tag"
LOG_FILE="$RUNTIME_DIR/arr-delete-sync-tag.log"
LOCK_DIR="$RUNTIME_DIR/arr-delete-sync-tag.lock"
SONARR_STATE_FILE="$RUNTIME_DIR/sonarr-state.json"
SONARR_STATE_BACKUP="$RUNTIME_DIR/sonarr-state.json.bak"
RADARR_STATE_FILE="$RUNTIME_DIR/radarr-state.json"
RADARR_STATE_BACKUP="$RUNTIME_DIR/radarr-state.json.bak"

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

# A progress line is written for the first series and then every N series, so
# a long library inspection is visibly active without filling the log.
PROGRESS_LOG_EVERY=25

MAX_LOG_SIZE_MB=10
MAX_LOG_FILES=5
HTTP_CONNECT_TIMEOUT=10
HTTP_MAX_TIME=90
HTTP_RETRIES=2
USER_AGENT="Arr-Delete-Sync-Tag/1.0"

###############################################################################
# END CONFIGURATION
###############################################################################

APP_CONTEXT="MAIN"
LOCK_HELD=false
WORK_STATE=""
CURRENT_SNAPSHOT_FILE=""
ARR_NAME=""
ARR_URL=""
ARR_API_KEY=""
ARR_TEMP_PREFIX=""
ARR_USER_AGENT=""

log() {
    local level="$1"
    shift
    printf '[%s] [%s] [%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$APP_CONTEXT" "$level" "$*" |
        tee -a "$LOG_FILE" >&2
}

die() {
    log ERROR "$*"
    exit 1
}

cleanup_app() {
    local status=$?
    [[ -n "$WORK_STATE" && -f "$WORK_STATE" ]] && rm -f -- "$WORK_STATE"
    [[ -n "$CURRENT_SNAPSHOT_FILE" && -f "$CURRENT_SNAPSHOT_FILE" ]] &&
        rm -f -- "$CURRENT_SNAPSHOT_FILE"
    trap - EXIT
    exit "$status"
}

cleanup_main() {
    local status=$?
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
    (( API_FAILURES > 0 || HISTORY_FAILURES > 0 )) && had_errors=true

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
    if ! api_get_json "/api/v3/episode?seriesId=$SERIES_ID" > "$CURRENT_SNAPSHOT_FILE"; then
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

    sonarr_apply_snapshot "$SERIES_ID" "$SERIES_TITLE" "$CURRENT_SNAPSHOT_FILE" ||
        die "Could not update temporary state for $SERIES_TITLE."

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
            else
                ((HISTORY_FAILURES += 1))
                log WARNING "History audit failed for $SERIES_TITLE."
                [[ "$REQUIRE_DELETE_HISTORY_EVENT" == true ]] && ACTION_IDS='[]'
            fi
        else
            ((HISTORY_LIMIT_SKIPS += ID_COUNT))
            log WARNING "History inspection cap reached; deferred audit for $ID_COUNT episode(s) in $SERIES_TITLE."
            [[ "$REQUIRE_DELETE_HISTORY_EVENT" == true ]] && ACTION_IDS='[]'
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

sonarr_commit_state || die "Could not atomically save state."
WORK_STATE=""

ACTION_LABEL=applied
[[ "$DRY_RUN" == true ]] && ACTION_LABEL=would-apply
log INFO "Summary: series-listed=$SERIES_LISTED, series-scanned=$SERIES_SCANNED, episodes=$EPISODES_SCANNED, files-present=$FILES_PRESENT, first-missing=$FIRST_MISSING, confirmed=$EPISODES_CONFIRMED, history-inspected=$HISTORY_INSPECTIONS, history-delete-events=$HISTORY_DELETE_EVENTS, history-cap-skips=$HISTORY_LIMIT_SKIPS, episode-actions-$ACTION_LABEL=$EPISODE_ACTIONS, season-actions-$ACTION_LABEL=$SEASON_ACTIONS, series-actions-$ACTION_LABEL=$SERIES_ACTIONS, tagged-series-$ACTION_LABEL=$TAGGED_SERIES_ACTIONS, api-failures=$API_FAILURES, history-failures=$HISTORY_FAILURES."

if (( API_FAILURES > 0 || HISTORY_FAILURES > 0 )); then
    log WARNING "Completed with API or History failures; safe state was saved and unfinished actions will be retried."
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
    for command in curl jq mktemp stat tee sort cut tr cp mv chmod; do
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
    [[ "$INSPECT_DELETE_HISTORY" == true || "$REQUIRE_DELETE_HISTORY_EVENT" == false ]] ||
        die "REQUIRE_DELETE_HISTORY_EVENT=true requires INSPECT_DELETE_HISTORY=true."
    [[ "$CONFIRMATION_RUNS" =~ ^[0-9]+$ ]] && (( CONFIRMATION_RUNS >= 2 )) ||
        die "CONFIRMATION_RUNS must be an integer of at least 2."
    [[ "$MAX_HISTORY_INSPECTIONS_PER_RUN" =~ ^[1-9][0-9]*$ ]] ||
        die "MAX_HISTORY_INSPECTIONS_PER_RUN must be a positive integer."
    [[ "$MAX_LOG_SIZE_MB" =~ ^[1-9][0-9]*$ && "$MAX_LOG_FILES" =~ ^[1-9][0-9]*$ ]] ||
        die "MAX_LOG_SIZE_MB and MAX_LOG_FILES must be positive integers."
    [[ "$HTTP_CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ &&
       "$HTTP_MAX_TIME" =~ ^[1-9][0-9]*$ &&
       "$HTTP_RETRIES" =~ ^[0-9]+$ ]] ||
        die "HTTP timeout values must be positive integers and HTTP_RETRIES non-negative."
    [[ "$RESCAN_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ &&
       "$RESCAN_POLL_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
        die "Rescan timeout and poll values must be positive integers."
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
    local sonarr_rc=0 radarr_rc=0 lock_rc=0

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
    local next
    next="$(mktemp "$STATE_DIR/.state-snapshot.XXXXXX")" || return 1

    if ! jq --arg now "$RUN_AT" \
        --argjson require_unmonitored "$RADARR_REQUIRE_MOVIE_UNMONITORED" \
        --slurpfile source "$movies_file" '($source[0] // []) as $movies
        | .movies //= {}
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
    (( API_FAILURES > 0 || HISTORY_FAILURES > 0 )) && had_errors=true

    if ! jq --arg now "$RUN_AT" --argjson had_errors "$had_errors" '
        .version = 1
        | .lastRun = $now
        | .lastRunHadApiErrors = $had_errors
        | .movies //= {}
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
    printf '%s\n' '{"version":1,"lastRun":null,"lastRunHadApiErrors":false,"movies":{}}' > "$INITIAL_STATE" &&
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

radarr_apply_snapshot "$CURRENT_SNAPSHOT_FILE" || die "Could not update temporary state."

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

                if [[ "$REQUIRE_HISTORY_DELETE_EVENT" == true ]] &&
                   { [[ "$HISTORY_INSPECTED" != true ]] || [[ "$HISTORY_EVIDENCE" == null ]]; }; then
                    log INFO "Not tagging $MOVIE_LABEL because no verified movieFileDeleted History event is available."
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
                            done < <(
                                jq --argjson ids "$ELIGIBLE_IDS" '
                                    [ .[] | . as $movie | select(($ids | index($movie.id)) != null) ][]
                                ' <<< "$ACTION_CANDIDATES" | jq -c .
                            )
                            TAG_ACTIONS="$ELIGIBLE_COUNT"
                        else
                            ((API_FAILURES += 1))
                            log ERROR "Bulk tag update failed; confirmed movies will be retried next run."
                        fi
                    fi
                fi
            fi
        fi
    fi
fi

radarr_commit_state || die "Could not atomically save state."
WORK_STATE=""

ACTION_LABEL=applied
[[ "$DRY_RUN" == true ]] && ACTION_LABEL=would-apply
log INFO "Summary: movies-listed=$MOVIES_LISTED, movies-scanned=$MOVIES_SCANNED, files-present=$FILES_PRESENT, first-missing=$FIRST_MISSING, confirmed=$MOVIES_CONFIRMED, history-inspected=$HISTORY_INSPECTIONS, history-delete-events=$HISTORY_DELETE_EVENTS, history-cap-skips=$HISTORY_LIMIT_SKIPS, tag-actions-$ACTION_LABEL=$TAG_ACTIONS, api-failures=$API_FAILURES, history-failures=$HISTORY_FAILURES."

if (( API_FAILURES > 0 || HISTORY_FAILURES > 0 )); then
    log WARNING "Completed with API failures; safely retrieved state was saved and unfinished tag actions will be retried."
    exit 2
fi
log INFO "Completed successfully."
)

main "$@"
