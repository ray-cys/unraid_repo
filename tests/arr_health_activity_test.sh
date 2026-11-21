#!/bin/bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/user_script/arr_health_activity.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arr_health_activity_test.XXXXXX")

cleanup_test() {
    rm -rf -- "${test_root:?}"
}
trap cleanup_test EXIT

# Load function definitions without entering the Unraid-specific main routine.
# The script installs runtime traps before main, so restore this fixture's trap
# immediately after sourcing it.
# shellcheck disable=SC1090
source <(awk '/^# LOCK$/{exit} {print}' "$script")
trap - INT TERM HUP
trap cleanup_test EXIT

# Use deterministic fixture timestamps; production date parsing is exercised by
# the full monitor and is unrelated to the recovery identity rules tested here.
date_to_epoch() {
    case "$1" in
        2026-11-21T10:00:00Z) printf '100\n' ;;
        2026-11-21T11:00:00Z) printf '200\n' ;;
        2026-11-21T12:00:00Z) printf '300\n' ;;
        2026-11-21T13:00:00Z) printf '400\n' ;;
        *) printf '0\n' ;;
    esac
}

sonarr_history="$test_root/sonarr.json"
jq -n '
[
  {
    id: 1,
    eventType: "downloadFailed",
    date: "2026-11-21T10:00:00Z",
    downloadId: "failed-release",
    seriesId: 10,
    episodeId: 101,
    series: {id: 10, title: "Recovered Series"},
    episode: {id: 101, seriesId: 10, seasonNumber: 1, episodeNumber: 1}
  },
  {
    id: 2,
    eventType: "downloadFolderImported",
    date: "2026-11-21T11:00:00Z",
    downloadId: "replacement-release",
    seriesId: 10,
    episodeId: 101,
    series: {id: 10, title: "Recovered Series"},
    episode: {id: 101, seriesId: 10, seasonNumber: 1, episodeNumber: 1}
  },
  {
    id: 3,
    eventType: "downloadFailed",
    date: "2026-11-21T12:00:00Z",
    downloadId: "unresolved-release",
    seriesId: 10,
    episodeId: 102,
    series: {id: 10, title: "Recovered Series"},
    episode: {id: 102, seriesId: 10, seasonNumber: 1, episodeNumber: 2}
  }
]
' >"$sonarr_history"

sonarr_failure=$(jq -c '.[0]' "$sonarr_history")
sonarr_unresolved=$(jq -c '.[2]' "$sonarr_history")

arr_history_failure_has_terminal_recovery \
    "Sonarr" "$sonarr_failure" "$sonarr_history"

if arr_history_failure_has_terminal_recovery \
    "Sonarr" "$sonarr_unresolved" "$sonarr_history";
then
    printf 'Mismatched Sonarr episode was incorrectly reconciled\n' >&2
    exit 1
fi

process_arr_activity_audit "Sonarr" "$sonarr_history"
[[ "$SONARR_AUDIT_IMPORTED" -eq 1 ]]
[[ "$SONARR_AUDIT_DOWNLOAD_FAILED" -eq 1 ]]
[[ "$SONARR_AUDIT_DOWNLOAD_FAILED_RECOVERED" -eq 1 ]]

radarr_history="$test_root/radarr.json"
jq -n '
[
  {
    id: 10,
    eventType: "downloadFailed",
    date: "2026-11-21T10:00:00Z",
    downloadId: "failed-movie-release",
    movieId: 55,
    movie: {id: 55, title: "Recovered Movie", year: 2026}
  },
  {
    id: 11,
    eventType: "downloadIgnored",
    date: "2026-11-21T11:00:00Z",
    downloadId: "replacement-movie-release",
    movieId: 55,
    movie: {id: 55, title: "Recovered Movie", year: 2026}
  },
  {
    id: 12,
    eventType: "downloadFolderImported",
    date: "2026-11-21T11:00:00Z",
    downloadId: "different-movie-release",
    movieId: 56,
    movie: {id: 56, title: "Recovered Movie", year: 2026}
  }
]
' >"$radarr_history"

radarr_failure=$(jq -c '.[0]' "$radarr_history")
arr_history_failure_has_terminal_recovery \
    "Radarr" "$radarr_failure" "$radarr_history"

# A terminal event before the failure must not be accepted as recovery.
early_history="$test_root/early.json"
jq '.[1].date = "2026-11-21T10:00:00Z" | .[0].date = "2026-11-21T11:00:00Z"' \
    "$radarr_history" >"$early_history"
early_failure=$(jq -c '.[0]' "$early_history")
if arr_history_failure_has_terminal_recovery \
    "Radarr" "$early_failure" "$early_history";
then
    printf 'Earlier Radarr terminal event was incorrectly reconciled\n' >&2
    exit 1
fi

###############################################################################
# SAB warning timestamps and event-only pipeline health
###############################################################################

TEST_RECORDED_ISSUES=0
record_normalized_issue() {
    ((TEST_RECORDED_ISSUES++)) || true
    if [ "$5" = "ERROR" ] && classification_is_event_only_error "$4"; then
        ((EVENT_ONLY_ERROR_COUNT++)) || true
    fi
}
stable_issue_hash() {
    printf 'fixture-hash\n'
}

now=$(date +%s)
SAB_WARNINGS="$test_root/sab-warnings.json"
jq -n \
    --argjson old "$((now - 25 * 3600))" \
    --argjson recent "$((now - 3600))" \
    '{warnings: [
      {type: "WARNING", text: "expired warning", time: $old},
      {type: "WARNING", text: "recent warning", time: $recent},
      {type: "ERROR", text: "recent error", time: $recent}
    ]}' >"$SAB_WARNINGS"

export SAB_WARNINGS_OK=true
export SAB_WARNING_ACTIVE_HOURS=24
SAB_NATIVE_WARNING_COUNT=0
EVENT_ONLY_ERROR_COUNT=0
process_sab_warnings

[[ "$TEST_RECORDED_ISSUES" -eq 2 ]]
[[ "$SAB_NATIVE_WARNING_COUNT" -eq 2 ]]
[[ "$EVENT_ONLY_ERROR_COUNT" -eq 1 ]]

export PIPELINE_HEALTH_ENABLED=true
export SONARR_ENABLED=false
export RADARR_ENABLED=false
export SAB_ENABLED=false
export ACTIVITY_AUDIT_ENABLED=false
export SAB_AUDIT_WINDOW_INCOMPLETE=false
export INFO_COUNT=0
export WARNING_COUNT=0
export ERROR_COUNT=1
EVENT_ONLY_ERROR_COUNT=1
export SAB_AUDIT_MOVIE_FAILED=0
export SAB_AUDIT_TV_FAILED=0
export SONARR_AUDIT_DOWNLOAD_FAILED=0
export RADARR_AUDIT_DOWNLOAD_FAILED=0
export SAB_AUDIT_MOVIE_COMPLETED=0
export SAB_AUDIT_TV_COMPLETED=0
export SONARR_AUDIT_IMPORTED=0
export RADARR_AUDIT_IMPORTED=0

assess_pipeline_health
[[ "$PIPELINE_STATUS" = "ATTENTION" ]]
[[ "$PIPELINE_LIVE_ERROR_COUNT" -eq 0 ]]

export ERROR_COUNT=2
EVENT_ONLY_ERROR_COUNT=1
assess_pipeline_health
[[ "$PIPELINE_STATUS" = "DEGRADED" ]]
[[ "$PIPELINE_LIVE_ERROR_COUNT" -eq 1 ]]

printf 'arr_health_activity fixture tests passed\n'
