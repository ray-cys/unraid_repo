#!/bin/bash

###############################################################################
# ARR Health / Download / Import Monitor v3.0.0
#
# PURPOSE
# -------
# Read-only monitoring of Sonarr, Radarr, and the Usenet -> Arr workflow:
#
#   SABnzbd
#      |
#      +--> Sonarr
#      |
#      +--> Radarr
#
# The script detects downloads that completed successfully but were not
# imported, were rejected by Arr policy, require manual attention, or have
# become stranded outside the normal Arr workflow.
#
#
# RECOMMENDED SCHEDULE
# --------------------
# Run this script EVERY FIVE MINUTES using Unraid User Scripts.
#
# Recommended cron:
#
#   */5 * * * *
#
# The script itself does NOT create or manage its schedule.
#
# With the recommended schedule, notification timing is approximately:
#
#   ARR errors:
#       Eligible after ERROR_AFTER_HOURS
#
#   ARR warnings / CF rejection / TBA:
#       Eligible after WARNING_AFTER_HOURS
#
#   ARR manual intervention:
#       Eligible after MANUAL_AFTER_HOURS
#
#   Generic Arr import stalls:
#       Eligible after STALL_AFTER_HOURS
#
#   CF / upgrade / TBA unresolved escalation:
#       Additional notification after POLICY_ESCALATE_AFTER_HOURS
#
#   SAB stranded downloads:
#
#       < SAB_ORPHAN_IGNORE_HOURS
#           Ignore
#
#       Media payload:
#           Eligible for warning after SAB_MEDIA_WARN_HOURS
#
#       Archive payload:
#           Eligible for warning after SAB_ARCHIVE_WARN_HOURS
#
#       Significant unknown payload:
#           Eligible for warning after SAB_OTHER_WARN_HOURS
#
#       Before the applicable warning threshold:
#           Log as an early candidate only
#
#       >= SAB_ORPHAN_ESCALATE_HOURS
#           One additional escalation notification
#
#       Sample / repair / metadata residue:
#           Log only; no notification
#
#       Empty leftover directory:
#           Log only; no notification
#
# Because this is normally run every five minutes, a threshold may be detected up to
# approximately one run interval after it is crossed.
#
#
# NOTIFICATION BEHAVIOR
# ---------------------
# Notifications are GROUPED.
#
# If one run discovers:
#
#   3 Sonarr issues
#   2 Radarr issues
#   1 SAB issue
#
# the script sends ONE grouped Unraid notification rather than six.
#
# Already-notified unchanged issues are suppressed individually.
#
# An issue is allowed another notification when:
#
#   - Its classification changes
#   - Its severity changes
#   - It crosses an escalation threshold
#   - It was previously resolved and later reappears
#
# Resolutions can be included in the same grouped notification.
#
#
# ARR-SIDE DETECTION
# ------------------
#   CF_REJECT_LOWER_SCORE
#   CF_REJECT_EQUAL_SCORE
#   CF_REJECT
#   UPGRADE_REJECT
#   TBA_METADATA
#   UNMATCHED_MEDIA
#   NO_IMPORTABLE_FILES
#   MANUAL
#   PERMISSION
#   PATH
#   IMPORT_FAILED
#   ARR_IMPORT_STALLED
#   WARNING
#   ERROR
#
# Native /api/v3/health entries are also mirrored dynamically, so newly added
# Sonarr/Radarr health checks are not silently missed by a fixed message list.
#
#
# ARR MESSAGE TELEMETRY - v2.3
# ----------------------------
# Generic Sonarr/Radarr issues are recorded over time when they currently
# fall through to:
#
#   WARNING
#   ERROR
#   ARR_IMPORT_STALLED
#
# The underlying queue message is normalized so variable paths, UUIDs and
# episode numbers do not unnecessarily create separate patterns.
#
# Telemetry records:
#
#   firstSeen
#   lastSeen
#   observations
#   distinctIssues
#   normalizedMessage
#   representative examples
#   most recent Arr queue status/state
#
# Telemetry DOES NOT automatically alter classifications.
#
# A recurring unknown pattern must first be observed and reviewed before it
# is promoted into a specific classification in a future version.
#
#
# SAB CROSS-APP DETECTION
# -----------------------
#   SAB_STRANDED_MEDIA
#       Full movie/episode media remains
#
#   SAB_STRANDED_ARCHIVE
#       Archive payload remains
#
#   SAB_STRANDED_OTHER
#       Significant unclassified data remains
#
#   SAB_RESIDUE_SAMPLE
#       Sample/trailer residue; log only
#
#   SAB_RESIDUE
#       Repair/metadata/small miscellaneous residue; log only
#
#   SAB_EMPTY_LEFTOVER
#       Empty directory; log only
#
# SAB OPERATIONAL DETECTION
# -------------------------
#   SAB_API_UNAVAILABLE
#   SAB_WARNING
#   SAB_ERROR
#   SAB_DOWNLOAD_FAILED_*
#   SAB_QUEUE_PAUSED
#   SAB_STALLED_*
#   SAB_CATEGORY_UNKNOWN
#
#
# SAB CATEGORY MAPPING
# --------------------
#   movie -> Radarr
#   tv    -> Sonarr
#   f1    -> ignored
#
#
# ISSUE LIFECYCLE
# ---------------
# v2.2 records:
#
#   firstSeen
#   lastSeen
#   occurrences
#   active
#   resolvedAt
#   notifiedSignature
#
# When an issue disappears during a successful scan:
#
#   active = false
#   resolvedAt = current time
#
# Resolution notifications are configurable and grouped.
#
# If the same issue later returns, it starts a new lifecycle and may generate
# a new notification.
#
#
# SAFETY
# ------
# READ ONLY.
#
# This script NEVER:
#
#   - Deletes downloads
#   - Removes SAB history
#   - Removes Sonarr/Radarr queue entries
#   - Forces imports
#   - Marks downloads failed
#   - Changes monitoring
#   - Changes quality profiles
#   - Changes Custom Formats
#
###############################################################################

set -uo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

# ---------------------------------------------------------------------------
# Sonarr
# ---------------------------------------------------------------------------

SONARR_ENABLED=true
SONARR_URL="http://192.168.50.4:8989"
SONARR_API_KEY="PUT_YOUR_SONARR_API_KEY_HERE"

# ---------------------------------------------------------------------------
# Radarr
# ---------------------------------------------------------------------------

RADARR_ENABLED=true
RADARR_URL="http://192.168.50.4:7878"
RADARR_API_KEY="PUT_YOUR_RADARR_API_KEY_HERE"

# ---------------------------------------------------------------------------
# SABnzbd
# ---------------------------------------------------------------------------

SAB_ENABLED=true
SAB_URL="http://192.168.50.4:8080"
SAB_API_KEY="PUT_YOUR_SABNZBD_API_KEY_HERE"

# ---------------------------------------------------------------------------
# SAB completed download locations
# ---------------------------------------------------------------------------

SAB_COMPLETE_ROOT="/mnt/user/media/net/complete"

SAB_MOVIE_CATEGORY="movie"
SAB_MOVIE_DIR="${SAB_COMPLETE_ROOT}/movies"

SAB_TV_CATEGORY="tv"
SAB_TV_DIR="${SAB_COMPLETE_ROOT}/series"

# Explicitly excluded because it has a separate workflow/script.
SAB_IGNORED_CATEGORY="f1"

# ---------------------------------------------------------------------------
# ARR thresholds
# ---------------------------------------------------------------------------

# Ignore very fresh queue entries.
IGNORE_BEFORE_HOURS=1

# Explicit manual-intervention conditions should be reported promptly after the
# fresh-entry grace period because Arr will not resolve them automatically.
MANUAL_AFTER_HOURS=1

# Normal policy / metadata / warning threshold.
WARNING_AFTER_HOURS=3

# Genuine import/system errors.
ERROR_AFTER_HOURS=2

# Generic completed-but-not-progressing items.
STALL_AFTER_HOURS=6

# CF / upgrade / TBA escalation.
POLICY_ESCALATE_AFTER_HOURS=72

# Native Arr health warnings must remain present for this many consecutive
# successful health scans before notification. Native health errors alert on
# the first successful scan that returns them.
ARR_HEALTH_WARNING_NOTIFY_RUNS=2
ARR_HEALTH_ERROR_NOTIFY_RUNS=1

# A service API problem becomes actionable only after repeated complete-run
# failures. This avoids noise during a normal container restart.
API_FAILURE_NOTIFY_RUNS=3
API_FAILURE_ESCALATE_MINUTES=60

# ---------------------------------------------------------------------------
# SAB stranded download thresholds - v2.2
# ---------------------------------------------------------------------------

# Ignore all possible SAB leftovers younger than this.
SAB_ORPHAN_IGNORE_HOURS=6

# Full media still present.
SAB_MEDIA_WARN_HOURS=12

# RAR/7z/etc. archive payload still present.
SAB_ARCHIVE_WARN_HOURS=12

# Unknown but materially large data.
SAB_OTHER_WARN_HOURS=24

# Any actionable stranded condition still present after this age gets one
# additional escalation notification.
SAB_ORPHAN_ESCALATE_HOURS=72

# Unknown files smaller than this are treated as residue rather than a
# stranded download.
#
# 100 MiB.
SAB_SIGNIFICANT_OTHER_BYTES=$((100 * 1024 * 1024))

# ---------------------------------------------------------------------------
# SAB operational monitoring - v3.0
# ---------------------------------------------------------------------------

# Failed movie/TV jobs remain actionable for this many hours. SAB history is
# persistent, so the monitor intentionally treats older failures as resolved.
SAB_FAILED_ACTIVE_HOURS=24

# A paused queue with monitored jobs must remain paused this long before it is
# reported. Disk/quota pauses and native SAB errors remain immediate.
SAB_PAUSE_WARN_MINUTES=30

# Optional daily pause windows that should not generate an unexpected-pause
# issue. Use 24-hour HH:MM-HH:MM ranges; crossing midnight is supported.
# Example: "02:00-03:30"
SAB_ALLOWED_PAUSE_WINDOWS=()

# No-progress thresholds for live download and post-processing stages.
SAB_DOWNLOAD_STALL_MINUTES=45
SAB_FETCH_STALL_MINUTES=60
SAB_VERIFY_STALL_MINUTES=60
SAB_REPAIR_STALL_MINUTES=120
SAB_EXTRACT_STALL_MINUTES=60
SAB_MOVE_STALL_MINUTES=30
SAB_SCRIPT_STALL_MINUTES=30
SAB_POSTPROCESS_WAIT_MINUTES=60

# Report jobs outside the configured movie, TV, and ignored categories.
SAB_MONITOR_UNKNOWN_CATEGORIES=true

# Maximum history retained in one scan. Retrieval is paginated and merged into
# a temporary file, so the JSON payload is never passed through argv.
SAB_HISTORY_MAX_RECORDS=5000
SAB_QUEUE_MAX_RECORDS=5000

# ---------------------------------------------------------------------------
# Arr message telemetry - v2.3
# ---------------------------------------------------------------------------

# Learn from real Sonarr/Radarr messages that currently fall through to
# generic WARNING, ERROR, or ARR_IMPORT_STALLED classifications.
ARR_TELEMETRY_ENABLED=true

# Historical normalized message patterns remain available this long.
ARR_TELEMETRY_RETENTION_DAYS=60

# Prevent telemetry from growing indefinitely.
ARR_TELEMETRY_MAX_PATTERNS=250

# Remember at most this many distinct issue/download IDs for each pattern.
ARR_TELEMETRY_MAX_ISSUE_KEYS=50

# Keep a few representative real messages for later review.
ARR_TELEMETRY_MAX_EXAMPLES=3

# Maximum raw message length retained as an example.
ARR_TELEMETRY_EXAMPLE_MAX_CHARS=1500

# Log whenever an entirely new normalized pattern is discovered.
ARR_TELEMETRY_LOG_NEW_PATTERNS=true

# ---------------------------------------------------------------------------
# Classification refinement - v2.4
# ---------------------------------------------------------------------------

# Enable reviewed telemetry patterns to be promoted into precise
# classifications.
#
# No promotion occurs unless a rule is explicitly added to
# classify_promoted_arr_pattern().
ARR_PROMOTION_RULES_ENABLED=true

# A telemetry pattern becomes a REVIEW CANDIDATE only after it has been seen
# across at least this many different queue/download issues.
ARR_TELEMETRY_REVIEW_MIN_DISTINCT_ISSUES=2

# It must also have accumulated at least this many observations.
ARR_TELEMETRY_REVIEW_MIN_OBSERVATIONS=4

# Maximum candidates displayed in each script summary.
ARR_TELEMETRY_REVIEW_TOP=10

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------

SEND_NOTIFICATIONS=true

# Include resolved issues in the same grouped notification as new/escalated
# issues. No separate notification script is used.
SEND_RESOLUTION_NOTIFICATIONS=true

NOTIFY="/usr/local/emhttp/webGui/scripts/notify"

NOTIFY_ONCE=true

# Maximum individual issues shown in one grouped notification.
#
# Additional issues remain visible in the User Scripts log.
GROUP_NOTIFICATION_MAX_ITEMS=20

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

STATE_DIR="/mnt/vault/cloud/logs/arr_health_activity"

STATE_FILE="${STATE_DIR}/state.json"
STATE_BACKUP="${STATE_DIR}/state.json.bak"

# Resolved historical issues older than this are removed from state.
STATE_RETENTION_DAYS=30

# ---------------------------------------------------------------------------
# Persistent operational log - v2.5
# ---------------------------------------------------------------------------

LOG_FILE="${STATE_DIR}/arr_health_activity.log"

# Rotate after approximately 10 MiB.
LOG_MAX_SIZE_MB=10

# Keep:
#   arr_health_activity.log
#   arr_health_activity.log.1
#   arr_health_activity.log.2
#   arr_health_activity.log.3
LOG_BACKUPS=3

# ---------------------------------------------------------------------------
# Recent activity audit - v2.5
# ---------------------------------------------------------------------------

ACTIVITY_AUDIT_ENABLED=true

# Look backwards this many hours for actual download/import activity.
ACTIVITY_AUDIT_LOOKBACK_HOURS=24

# Normally only aggregate successful imports are shown.
#
# Set true temporarily when troubleshooting to print individual successful
# Sonarr/Radarr imports in the User Scripts output.
#
# Individual successes are NOT written to the persistent audit log.
AUDIT_SUCCESS_DETAILS=false

# Maximum successful imports displayed when AUDIT_SUCCESS_DETAILS=true.
AUDIT_DETAIL_MAX_ITEMS=20

# Produce a conservative overall pipeline assessment.
#
# This is LOG ONLY.
# It does not generate additional notifications.
PIPELINE_HEALTH_ENABLED=true

# ---------------------------------------------------------------------------
# Activity flow anomaly detection - v2.6
# ---------------------------------------------------------------------------

FLOW_ANOMALY_ENABLED=true

# Analyze a shorter recent window than the general 24-hour activity audit.
#
# IMPORTANT:
# This must not exceed ACTIVITY_AUDIT_LOOKBACK_HOURS because v2.6 reuses
# the Sonarr/Radarr history already fetched by v2.5.
FLOW_ANOMALY_LOOKBACK_HOURS=12

# Require meaningful SAB activity before considering zero Arr imports unusual.
#
# Example:
#
#   SAB TV completed: 1
#   Sonarr imports:   0
#
# Not enough evidence.
#
#   SAB TV completed: 4
#   Sonarr imports:   0
#
# Eligible for flow-anomaly evaluation.
FLOW_MIN_SAB_ACTIVITY=3

# If the same anomaly remains continuously active for this long,
# change its lifecycle stage to ESCALATED.
#
# Severity remains WARNING, but the changed signature allows one additional
# grouped notification.
FLOW_ANOMALY_ESCALATE_HOURS=24

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------

LOCKFILE="/tmp/arr_health_activity.lock"

QUEUE_PAGE_SIZE=1000
SAB_HISTORY_LIMIT=500
ARR_QUEUE_MAX_RECORDS=10000

###############################################################################
# INITIALIZATION
###############################################################################

START_TIME=$(date +%s)

TMP_DIR=""
NOTIFICATION_BATCH=""
SEEN_ISSUES_FILE=""

SONARR_QUEUE=""
RADARR_QUEUE=""
SAB_HISTORY=""
SONARR_HEALTH=""
RADARR_HEALTH=""
SONARR_SYSTEM_STATUS=""
RADARR_SYSTEM_STATUS=""
SAB_QUEUE=""
SAB_WARNINGS=""
SAB_STATUS=""

# Component scan health. The legacy *_SCAN_OK values continue to represent the
# queue/history data required by the existing import and stranded-file checks.
SONARR_SCAN_OK=false
RADARR_SCAN_OK=false
SAB_SCAN_OK=false

SONARR_QUEUE_OK=false
RADARR_QUEUE_OK=false
SONARR_HEALTH_OK=false
RADARR_HEALTH_OK=false
SONARR_STATUS_OK=false
RADARR_STATUS_OK=false
SONARR_API_OK=false
RADARR_API_OK=false

SAB_HISTORY_OK=false
SAB_QUEUE_OK=false
SAB_WARNINGS_OK=false
SAB_STATUS_OK=false
SAB_API_OK=false

SONARR_API_FAILURES=""
RADARR_API_FAILURES=""
SAB_API_FAILURES=""

SAB_PRIMARY_DOWNLOADS_FILE=""
SAB_PROGRESS_SEEN_FILE=""
SAB_PROGRESS_OBSERVATIONS_FILE=""
STATE_WRITE_ALERT_SENT=false

TOTAL_QUEUE=0
TOTAL_ISSUES=0

INFO_COUNT=0
WARNING_COUNT=0
ERROR_COUNT=0

CF_REJECT_COUNT=0
UPGRADE_REJECT_COUNT=0
TBA_COUNT=0
UNMATCHED_COUNT=0
NO_IMPORT_COUNT=0
STALL_COUNT=0

SAB_HISTORY_CHECKED=0
SAB_IGNORED_COUNT=0
SAB_STRANDED_COUNT=0
SAB_CANDIDATE_COUNT=0
SAB_MEDIA_STRANDED_COUNT=0
SAB_ARCHIVE_STRANDED_COUNT=0
SAB_OTHER_STRANDED_COUNT=0

SAB_RESIDUE_COUNT=0
SAB_SAMPLE_RESIDUE_COUNT=0
SAB_EMPTY_COUNT=0

ARR_NATIVE_HEALTH_COUNT=0
SERVICE_API_ISSUE_COUNT=0
SAB_NATIVE_WARNING_COUNT=0
SAB_FAILED_JOB_COUNT=0
SAB_STALLED_JOB_COUNT=0
SAB_PAUSED_COUNT=0
SAB_UNKNOWN_CATEGORY_COUNT=0

RESOLVED_COUNT=0

NOTIFICATIONS_SENT=0
NOTIFICATIONS_SUPPRESSED=0
BATCHED_NOTIFICATION_ITEMS=0

# Arr message telemetry.
TELEMETRY_OBSERVATIONS=0
TELEMETRY_NEW_PATTERNS=0
TELEMETRY_EXISTING_PATTERNS=0

PROMOTION_RULE_MATCHES=0
PROMOTION_CANDIDATES=0

###############################################################################
# ACTIVITY AUDIT - v2.5
###############################################################################

AUDIT_CUTOFF_EPOCH=0
AUDIT_SINCE_ISO=""

SONARR_AUDIT_HISTORY=""
RADARR_AUDIT_HISTORY=""

SONARR_AUDIT_OK=false
RADARR_AUDIT_OK=false
SAB_AUDIT_OK=false

SONARR_AUDIT_IMPORTED=0
SONARR_AUDIT_DOWNLOAD_FAILED=0

RADARR_AUDIT_IMPORTED=0
RADARR_AUDIT_DOWNLOAD_FAILED=0

SAB_AUDIT_MOVIE_COMPLETED=0
SAB_AUDIT_TV_COMPLETED=0

SAB_AUDIT_MOVIE_FAILED=0
SAB_AUDIT_TV_FAILED=0

SAB_AUDIT_F1_IGNORED=0

SAB_AUDIT_WINDOW_INCOMPLETE=false

PIPELINE_STATUS="UNKNOWN"
PIPELINE_REASON="Not assessed"

###############################################################################
# ACTIVITY FLOW ANOMALY - v2.6
###############################################################################

FLOW_CUTOFF_EPOCH=0

FLOW_SAB_TV_COMPLETED=0
FLOW_SAB_MOVIE_COMPLETED=0

FLOW_SONARR_IMPORTS=0
FLOW_RADARR_IMPORTS=0

FLOW_SONARR_EXPLANATIONS=0
FLOW_RADARR_EXPLANATIONS=0

FLOW_ANOMALY_COUNT=0
FLOW_ANOMALY_SUPPRESSED_COUNT=0

FLOW_ANALYSIS_OK=false
FLOW_ANALYSIS_REASON="Not evaluated"

###############################################################################
# BASIC FUNCTIONS
###############################################################################

log() {
    printf '%s : %s\n' "$(date '+%Y/%m/%d %T')" "$*"
}

###############################################################################
# PERSISTENT OPERATIONAL LOG - v2.5
###############################################################################

persistent_log() {

    local level="$1"
    shift

    if [ -z "$LOG_FILE" ]; then
        return
    fi

    if ! printf '%s | %s | %s\n' \
        "$(date '+%Y/%m/%d %T')" \
        "$level" \
        "$*" \
        >>"$LOG_FILE" 2>/dev/null
    then

        log "WARNING: Unable to write persistent log: $LOG_FILE"
    fi
}

###############################################################################
# PERSISTENT LOG ROTATION
###############################################################################

rotate_persistent_log() {

    [ -f "$LOG_FILE" ] || return 0

    local size
    local max_bytes
    local i

    size=$(stat -c '%s' "$LOG_FILE" 2>/dev/null || echo 0)

    [[ "$size" =~ ^[0-9]+$ ]] || size=0

    max_bytes=$(( LOG_MAX_SIZE_MB * 1024 * 1024 ))

    if (( size < max_bytes )); then
        return 0
    fi

    log "Rotating persistent ARR monitor log"

    ###########################################################################
    # REMOVE OLDEST
    ###########################################################################

    if (( LOG_BACKUPS > 0 )); then

        rm -f -- "${LOG_FILE}.${LOG_BACKUPS}" 2>/dev/null || true

        #######################################################################
        # SHIFT EXISTING BACKUPS
        #######################################################################

        for (( i=LOG_BACKUPS-1; i>=1; i-- )); do

            if [ -f "${LOG_FILE}.${i}" ]; then

                mv -f \
                    "${LOG_FILE}.${i}" \
                    "${LOG_FILE}.$((i + 1))"
            fi

        done

        mv -f "$LOG_FILE" "${LOG_FILE}.1"

    else

        : >"$LOG_FILE"
    fi
}

runtime() {

    local seconds=$(( $(date +%s) - START_TIME ))

    printf '%dh:%dm:%ds' \
        $((seconds / 3600)) \
        $(((seconds % 3600) / 60)) \
        $((seconds % 60))
}

bytes_human() {

    local bytes="${1:-0}"

    awk -v b="$bytes" '
        BEGIN {
            if (b >= 1099511627776)
                printf "%.2f TB", b / 1099511627776
            else if (b >= 1073741824)
                printf "%.2f GB", b / 1073741824
            else if (b >= 1048576)
                printf "%.2f MB", b / 1048576
            else if (b >= 1024)
                printf "%.2f KB", b / 1024
            else
                printf "%d B", b
        }
    '
}

# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
cleanup() {

    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf -- "$TMP_DIR" 2>/dev/null || true
    fi
}

trap 'cleanup' EXIT

###############################################################################
# REQUIRE COMMAND
###############################################################################

require_command() {

    local command="$1"

    if ! command -v "$command" >/dev/null 2>&1; then
        log "ERROR: Required command not found: $command"
        exit 2
    fi
}

###############################################################################
# UNRAID NOTIFICATION
###############################################################################

notify() {

    local importance="$1"
    local description="$2"
    local message="$3"

    # Notifications generated by this script are intentionally emoji-free.
    # Filtering at the final boundary also removes emoji supplied by an API or
    # embedded in a release title while preserving normal Unicode text.
    description=$(strip_notification_emoji "$description")
    message=$(strip_notification_emoji "$message")

    if [ "$SEND_NOTIFICATIONS" != true ]; then
        return 2
    fi

    if [ ! -x "$NOTIFY" ]; then

        log "WARNING: Unraid notification command unavailable"

        return 1
    fi

    if "$NOTIFY" \
        -i "$importance" \
        -s "ARR Health Monitor" \
        -d "$description" \
        -m "$message" \
        >/dev/null 2>&1
    then

        ((NOTIFICATIONS_SENT++)) || true

        return 0
    fi

    log "WARNING: Failed to send grouped Unraid notification"

    return 1
}

strip_notification_emoji() {

    local value="$1"

    printf '%s' "$value" |
        jq -Rs -r '
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

###############################################################################
# APIs
###############################################################################

api_get() {

    local url="$1"
    local api_key="$2"
    local output="$3"

    local http_code
    local curl_rc

    API_LAST_ERROR=""

    http_code=$(curl \
        --silent \
        --show-error \
        --fail \
        --connect-timeout 10 \
        --max-time 30 \
        -H "X-Api-Key: $api_key" \
        "$url" \
        -o "$output" \
        --write-out '%{http_code}')
    curl_rc=$?

    if (( curl_rc != 0 )); then

        case "$http_code" in

            401|403)
                API_LAST_ERROR="authentication rejected (HTTP ${http_code})"
                ;;

            000|"")
                API_LAST_ERROR="connection failed or timed out"
                ;;

            *)
                API_LAST_ERROR="HTTP ${http_code}"
                ;;
        esac

        return 1
    fi

    if ! jq empty "$output" >/dev/null 2>&1; then

        API_LAST_ERROR="invalid JSON response"

        return 1
    fi

    return 0
}

sab_get() {

    local mode="$1"
    local output="$2"
    local start="${3:-0}"
    local limit="${4:-$SAB_HISTORY_LIMIT}"

    local url="${SAB_URL%/}/api"
    local http_code
    local curl_rc
    local -a request_args

    API_LAST_ERROR=""

    request_args=(
        --silent
        --show-error
        --fail
        --connect-timeout 10
        --max-time 30
        --get
        --data-urlencode "mode=$mode"
        --data-urlencode "output=json"
        --data-urlencode "apikey=$SAB_API_KEY"
    )

    case "$mode" in

        history|queue)
            request_args+=(
                --data-urlencode "start=$start"
                --data-urlencode "limit=$limit"
            )
            ;;

        status)
            request_args+=(
                --data-urlencode "skip_dashboard=1"
            )
            ;;
    esac

    http_code=$(curl \
        "${request_args[@]}" \
        "$url" \
        -o "$output" \
        --write-out '%{http_code}')
    curl_rc=$?

    if (( curl_rc != 0 )); then

        case "$http_code" in

            401|403)
                API_LAST_ERROR="authentication rejected (HTTP ${http_code})"
                ;;

            000|"")
                API_LAST_ERROR="connection failed or timed out"
                ;;

            *)
                API_LAST_ERROR="HTTP ${http_code}"
                ;;
        esac

        return 1
    fi

    if ! jq empty "$output" >/dev/null 2>&1; then

        API_LAST_ERROR="invalid JSON response"

        return 1
    fi

    if jq -e '
        (.status | type) == "boolean"
        and .status == false
        and ((.error // "") != "")
        ' "$output" >/dev/null 2>&1
    then

        API_LAST_ERROR=$(jq -r '.error // "SABnzbd API rejected the request"' "$output")

        return 1
    fi

    return 0
}

append_api_failure() {

    local current="$1"
    local endpoint="$2"
    local error="${3:-request failed}"

    if [ -n "$current" ]; then
        printf '%s; %s: %s' "$current" "$endpoint" "$error"
    else
        printf '%s: %s' "$endpoint" "$error"
    fi
}

###############################################################################
# PAGED API FETCHERS
###############################################################################

fetch_arr_queue() {

    local app="$1"
    local base_url="$2"
    local api_key="$3"
    local output="$4"

    local include_query
    local page=1
    local total=0
    local loaded=0
    local max_pages
    local page_file
    local merged
    local -a page_files=()

    case "$app" in

        Sonarr)
            include_query="includeUnknownSeriesItems=true&includeSeries=true&includeEpisode=true"
            ;;

        Radarr)
            include_query="includeUnknownMovieItems=true&includeMovie=true"
            ;;

        *)
            return 1
            ;;
    esac

    max_pages=$(( (ARR_QUEUE_MAX_RECORDS + QUEUE_PAGE_SIZE - 1) / QUEUE_PAGE_SIZE ))

    while (( page <= max_pages )); do

        page_file="${TMP_DIR}/${app,,}_queue_page_${page}.json"

        if ! api_get \
            "${base_url%/}/api/v3/queue?page=${page}&pageSize=${QUEUE_PAGE_SIZE}&${include_query}" \
            "$api_key" \
            "$page_file"
        then
            return 1
        fi

        page_files+=("$page_file")

        loaded=$(( loaded + $(jq '.records // [] | length' "$page_file") ))
        total=$(jq -r '.totalRecords // (.records // [] | length)' "$page_file")

        if (( loaded >= total )); then
            break
        fi

        ((page++)) || true
    done

    merged="${TMP_DIR}/${app,,}_queue_merged.json"

    jq -s '
        . as $pages
        | $pages[0] as $first
        | $first
        | .page = 1
        | .records = [ $pages[] | .records[]? ]
        | .pageSize = (.records | length)
        ' \
        "${page_files[@]}" >"$merged" || return 1

    mv -f "$merged" "$output"

    if (( loaded < total )); then

        log "WARNING: ${app} queue reached ARR_QUEUE_MAX_RECORDS=${ARR_QUEUE_MAX_RECORDS}"
    fi

    return 0
}

fetch_sab_history() {

    local output="$1"
    local page=0
    local start=0
    local loaded=0
    local total=0
    local page_file
    local merged
    local -a page_files=()

    while (( loaded < SAB_HISTORY_MAX_RECORDS )); do

        page_file="${TMP_DIR}/sab_history_page_${page}.json"

        if ! sab_get history "$page_file" "$start" "$SAB_HISTORY_LIMIT"; then
            return 1
        fi

        page_files+=("$page_file")

        local page_count
        page_count=$(jq '.history.slots // [] | length' "$page_file")
        loaded=$(( loaded + page_count ))
        total=$(jq -r '.history.noofslots // (.history.slots // [] | length)' "$page_file")

        if (( page_count == 0 || loaded >= total )); then
            break
        fi

        start="$loaded"
        ((page++)) || true
    done

    merged="${TMP_DIR}/sab_history_merged.json"

    jq -s '
        . as $pages
        | $pages[0] as $first
        | $first
        | .history.slots = [ $pages[] | .history.slots[]? ]
        | .history.noofslots = ($first.history.noofslots // (.history.slots | length))
        ' \
        "${page_files[@]}" >"$merged" || return 1

    mv -f "$merged" "$output"

    if (( loaded < total )); then

        log "WARNING: SAB history reached SAB_HISTORY_MAX_RECORDS=${SAB_HISTORY_MAX_RECORDS}"
        SAB_AUDIT_WINDOW_INCOMPLETE=true
    fi

    return 0
}

fetch_sab_queue() {

    local output="$1"
    local page=0
    local start=0
    local loaded=0
    local total=0
    local page_file
    local merged
    local -a page_files=()

    while (( loaded < SAB_QUEUE_MAX_RECORDS )); do

        page_file="${TMP_DIR}/sab_queue_page_${page}.json"

        if ! sab_get queue "$page_file" "$start" "$SAB_HISTORY_LIMIT"; then
            return 1
        fi

        page_files+=("$page_file")

        local page_count
        page_count=$(jq '.queue.slots // [] | length' "$page_file")
        loaded=$(( loaded + page_count ))
        total=$(jq -r '
            .queue.noofslots_total
            // .queue.noofslots
            // (.queue.slots // [] | length)
            ' "$page_file")

        if (( page_count == 0 || loaded >= total )); then
            break
        fi

        start="$loaded"
        ((page++)) || true
    done

    merged="${TMP_DIR}/sab_queue_merged.json"

    jq -s '
        . as $pages
        | $pages[0] as $first
        | $first
        | .queue.slots = [ $pages[] | .queue.slots[]? ]
        | .queue.start = 0
        | .queue.limit = (.queue.slots | length)
        ' \
        "${page_files[@]}" >"$merged" || return 1

    mv -f "$merged" "$output"

    if (( loaded < total )); then
        log "WARNING: SAB queue reached SAB_QUEUE_MAX_RECORDS=${SAB_QUEUE_MAX_RECORDS}"
    fi

    return 0
}

###############################################################################
# TIME
###############################################################################

date_to_epoch() {

    local value="$1"

    if [ -z "$value" ]; then
        echo 0
        return
    fi

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "$value"
        return
    fi

    date -d "$value" '+%s' 2>/dev/null || echo 0
}

age_hours() {

    local timestamp="$1"

    local epoch
    local now

    epoch=$(date_to_epoch "$timestamp")
    now=$(date +%s)

    if (( epoch <= 0 || now <= epoch )); then
        echo 0
        return
    fi

    echo $(( (now - epoch) / 3600 ))
}

###############################################################################
# ARR MESSAGE
###############################################################################

queue_message() {

    local item="$1"

    echo "$item" |
        jq -r '
            [
                (.errorMessage // empty),

                (
                    .statusMessages[]?
                    | (
                        .title?,
                        .message?,
                        .messages[]?
                    )
                )
            ]
            | map(select(. != null and . != ""))
            | unique
            | join(" | ")
        '
}

###############################################################################
# FRIENDLY MEDIA NAME
###############################################################################

friendly_media_name() {

    local app="$1"
    local item="$2"

    if [ "$app" = "Sonarr" ]; then

        echo "$item" |
            jq -r '
                if (.series.title // "") != "" then

                    if (.episode.seasonNumber // null) != null
                       and (.episode.episodeNumber // null) != null
                    then

                        (.series.title)
                        + " - S"
                        + (
                            (.episode.seasonNumber | tostring)
                            | if length < 2 then "0" + . else . end
                        )
                        + "E"
                        + (
                            (.episode.episodeNumber | tostring)
                            | if length < 2 then "0" + . else . end
                        )
                        + (
                            if (.episode.title // "") != ""
                            then " - " + .episode.title
                            else ""
                            end
                        )

                    else
                        .series.title
                    end

                else
                    (.title // "Unknown")
                end
            '

    else

        echo "$item" |
            jq -r '
                if (.movie.title // "") != "" then

                    .movie.title
                    + (
                        if (.movie.year // 0) > 0
                        then " (" + (.movie.year | tostring) + ")"
                        else ""
                        end
                    )

                else
                    (.title // "Unknown")
                end
            '
    fi
}

release_name() {

    local item="$1"

    echo "$item" |
        jq -r '.title // "Unknown"'
}

###############################################################################
# CUSTOM FORMAT PARSING
###############################################################################

extract_cf_new_score() {

    local message="$1"

    echo "$message" |
        sed -nE \
        's/.*New: \[[^]]*\] \((-?[0-9]+)\).*Existing:.*/\1/p' |
        head -n 1
}

extract_cf_existing_score() {

    local message="$1"

    echo "$message" |
        sed -nE \
        's/.*Existing: \[[^]]*\] \((-?[0-9]+)\).*/\1/p' |
        head -n 1
}

extract_cf_new_formats() {

    local message="$1"

    echo "$message" |
        sed -nE \
        's/.*New: \[([^]]*)\] \(-?[0-9]+\).*Existing:.*/\1/p' |
        head -n 1
}

extract_cf_existing_formats() {

    local message="$1"

    echo "$message" |
        sed -nE \
        's/.*Existing: \[([^]]*)\] \(-?[0-9]+\).*/\1/p' |
        head -n 1
}

normalize_cf_list() {

    local value="$1"

    printf '%s\n' "$value" |
        tr ',' '\n' |
        sed \
            -e 's/^[[:space:]]*//' \
            -e 's/[[:space:]]*$//' |
        sed '/^$/d' |
        sort -u
}

cf_difference() {

    local first="$1"
    local second="$2"

    comm -23 \
        <(normalize_cf_list "$first") \
        <(normalize_cf_list "$second")
}

join_lines() {

    awk '
        NF {
            if (seen)
                printf ", "

            printf "%s", $0
            seen=1
        }

        END {
            if (seen)
                printf "\n"
        }
    '
}

###############################################################################
# CLASSIFICATION
###############################################################################

classify_issue() {

    local tracked_status="$1"
    local tracked_state="$2"
    local status="$3"
    local message="$4"

    local combined
    local new_score
    local existing_score

    combined="$(
        printf '%s %s %s %s' \
            "$tracked_status" \
            "$tracked_state" \
            "$status" \
            "$message" |
        tr '[:upper:]' '[:lower:]'
    )"

    if echo "$combined" |
       grep -Eq \
       'custom format|customformat|custom-format|format score'
    then

        new_score=$(extract_cf_new_score "$message")
        existing_score=$(extract_cf_existing_score "$message")

        if [[ "$new_score" =~ ^-?[0-9]+$ ]] &&
           [[ "$existing_score" =~ ^-?[0-9]+$ ]]
        then

            if (( new_score < existing_score )); then
                echo "CF_REJECT_LOWER_SCORE"
                return
            fi

            if (( new_score == existing_score )); then
                echo "CF_REJECT_EQUAL_SCORE"
                return
            fi
        fi

        echo "CF_REJECT"
        return
    fi

    if echo "$combined" |
       grep -Eq \
       '(^|[^[:alpha:]])tba([^[:alpha:]]|$)|title.*not available|metadata.*not available|metadata.*not ready|waiting.*metadata'
    then

        echo "TBA_METADATA"
        return
    fi

    if echo "$combined" |
       grep -Eq \
       'unable to match|could not match|cannot match|failed to match|unable to identify|could not identify|cannot identify|unknown series|unknown movie'
    then

        echo "UNMATCHED_MEDIA"
        return
    fi

    if echo "$combined" |
       grep -Eq \
       'no files.*eligible.*import|no importable files|no files found.*import|no video files|nothing.*to import'
    then

        echo "NO_IMPORTABLE_FILES"
        return
    fi

    # Queue state is authoritative for manual-intervention detection. History
    # correlation enriches the later notification but never gates detection.
    if echo "$combined" |
       grep -Eq \
       'manual import|manual intervention|requires manual|manually import|needs manual|importblocked|import blocked|found matching (series|movie) via grab history.*automatic import is not possible'
    then

        echo "MANUAL"
        return
    fi

    if echo "$combined" |
       grep -Eq \
       'not an upgrade|existing file.*better|existing.*preferred|quality.*not.*upgrade|does not improve|not an improvement'
    then

        echo "UPGRADE_REJECT"
        return
    fi

    if echo "$combined" |
       grep -Eq \
       'permission denied|access.*denied|unauthorized access|not permitted|operation not permitted'
    then

        echo "PERMISSION"
        return
    fi

    if echo "$combined" |
       grep -Eq \
       'not enough (free )?(disk )?space|insufficient (free )?space|disk.*full|no space left'
    then

        echo "DISK_SPACE"
        return
    fi

    if echo "$combined" |
       grep -Eq \
       'remote path mapping|remote.*path.*map|path mapping.*missing|different path.*download client'
    then

        echo "REMOTE_PATH_MAPPING"
        return
    fi

    if echo "$combined" |
       grep -Eq \
       'unable to communicate with download client|download client.*unavailable|download client.*not available|download client.*failed|connection.*download client'
    then

        echo "DOWNLOAD_CLIENT"
        return
    fi

    if echo "$combined" |
       grep -Eq \
       'file.*locked|being used by another process|resource busy|temporarily unavailable'
    then

        echo "FILE_LOCKED"
        return
    fi

    if echo "$combined" |
       grep -Eq \
       'failed to move|unable to move|could not move|move.*failed'
    then

        echo "MOVE_FAILED"
        return
    fi

    if echo "$combined" |
       grep -Eq \
       'failed to copy|unable to copy|could not copy|copy.*failed'
    then

        echo "COPY_FAILED"
        return
    fi

    if echo "$combined" |
       grep -Eq \
       'file.*too small|smaller than minimum|does not meet.*minimum.*size'
    then

        echo "FILE_TOO_SMALL"
        return
    fi

    if echo "$combined" |
       grep -Eq \
       'unable to determine.*sample|could not determine.*sample|sample.*detection'
    then

        echo "SAMPLE_DETECTION"
        return
    fi

    if echo "$combined" |
       grep -Eq \
       'title.*mismatch|title.*does not match|does not match.*expected'
    then

        echo "TITLE_MISMATCH"
        return
    fi

    if echo "$combined" |
       grep -Eq \
       'unable to parse.*quality|could not parse.*quality|quality.*unknown|failed to parse.*release'
    then

        echo "QUALITY_PARSE"
        return
    fi

    if echo "$combined" |
       grep -Eq \
       'destination.*already exists|existing destination|conflicting destination|destination.*conflict'
    then

        echo "DESTINATION_CONFLICT"
        return
    fi

    if echo "$combined" |
       grep -Eq \
       'path.*does not exist|folder.*does not exist|directory.*does not exist|cannot find|no such file|not accessible|unable to access|folder is missing'
    then

        echo "PATH"
        return
    fi

    if echo "$combined" |
       grep -Eq \
       'import failed|failed to import|unable to import|import error|could not import|cannot import'
    then

        echo "IMPORT_FAILED"
        return
    fi

    case "${tracked_status,,}" in

        warning)
            echo "WARNING"
            return
            ;;

        error)
            echo "ERROR"
            return
            ;;
    esac

    if echo "$combined" |
       grep -Eq \
       'downloaded|completed|importpending|import blocked|waiting'
    then

        echo "ARR_IMPORT_STALLED"
        return
    fi

    echo "NONE"
}

###############################################################################
# CLASSIFICATION SEVERITY
###############################################################################

is_policy_rejection() {

    case "$1" in

        CF_REJECT_LOWER_SCORE|\
        CF_REJECT_EQUAL_SCORE|\
        CF_REJECT|\
        UPGRADE_REJECT)

            return 0
            ;;
    esac

    return 1
}

classification_severity() {

    local classification="$1"
    local age="$2"

    if is_policy_rejection "$classification"; then

        if (( age >= POLICY_ESCALATE_AFTER_HOURS )); then
            echo "WARNING"
        else
            echo "INFO"
        fi

        return
    fi

    case "$classification" in

        TBA_METADATA)

            if (( age >= POLICY_ESCALATE_AFTER_HOURS )); then
                echo "WARNING"
            else
                echo "INFO"
            fi
            ;;

        WARNING|\
        MANUAL|\
        ARR_IMPORT_STALLED|\
        FILE_LOCKED|\
        SAMPLE_DETECTION|\
        TITLE_MISMATCH|\
        QUALITY_PARSE|\
        ACTIVITY_FLOW_ANOMALY)

            echo "WARNING"
            ;;

        UNMATCHED_MEDIA|\
        NO_IMPORTABLE_FILES|\
        PERMISSION|\
        PATH|\
        IMPORT_FAILED|\
        ERROR|\
        DISK_SPACE|\
        MOVE_FAILED|\
        COPY_FAILED|\
        REMOTE_PATH_MAPPING|\
        DOWNLOAD_CLIENT|\
        FILE_TOO_SMALL|\
        DESTINATION_CONFLICT)

            echo "ERROR"
            ;;

        *)
            echo "NONE"
            ;;
    esac
}

classification_min_age() {

    case "$1" in

        CF_REJECT_LOWER_SCORE|\
        CF_REJECT_EQUAL_SCORE|\
        CF_REJECT|\
        UPGRADE_REJECT|\
        TBA_METADATA|\
        WARNING|\
        FILE_LOCKED|\
        SAMPLE_DETECTION|\
        TITLE_MISMATCH|\
        QUALITY_PARSE)

            echo "$WARNING_AFTER_HOURS"
            ;;

        MANUAL)

            echo "$MANUAL_AFTER_HOURS"
            ;;

        UNMATCHED_MEDIA|\
        NO_IMPORTABLE_FILES|\
        PERMISSION|\
        PATH|\
        IMPORT_FAILED|\
        DISK_SPACE|\
        MOVE_FAILED|\
        COPY_FAILED|\
        REMOTE_PATH_MAPPING|\
        DOWNLOAD_CLIENT|\
        FILE_TOO_SMALL|\
        DESTINATION_CONFLICT|\
        ERROR)

            echo "$ERROR_AFTER_HOURS"
            ;;

        ARR_IMPORT_STALLED)
            echo "$STALL_AFTER_HOURS"
            ;;

        *)
            echo 999999
            ;;
    esac
}

classification_reason() {

    local classification="$1"
    local age="$2"

    local escalation=""

    if (( age >= POLICY_ESCALATE_AFTER_HOURS )); then
        escalation=" Issue has remained unresolved for at least ${POLICY_ESCALATE_AFTER_HOURS} hours."
    fi

    case "$classification" in

        CF_REJECT_LOWER_SCORE)
            echo "Downloaded release has a lower Custom Format score than the existing media.${escalation}"
            ;;

        CF_REJECT_EQUAL_SCORE)
            echo "Downloaded release has the same Custom Format score and is not considered an upgrade.${escalation}"
            ;;

        CF_REJECT)
            echo "Custom Format scoring or requirements prevented automatic import.${escalation}"
            ;;

        UPGRADE_REJECT)
            echo "Downloaded release is not considered an upgrade over the existing media.${escalation}"
            ;;

        TBA_METADATA)
            echo "Media metadata/title appears incomplete or TBA and automatic import is waiting or blocked.${escalation}"
            ;;

        UNMATCHED_MEDIA)
            echo "Arr could not reliably match or identify the downloaded media"
            ;;

        NO_IMPORTABLE_FILES)
            echo "Arr could not find an eligible/importable media file in the completed download"
            ;;

        PERMISSION)
            echo "Filesystem permission/access problem"
            ;;

        DISK_SPACE)
            echo "Arr reports insufficient filesystem space for the import operation"
            ;;

        MOVE_FAILED)
            echo "Arr could not move the downloaded media into the library"
            ;;

        COPY_FAILED)
            echo "Arr could not copy the downloaded media into the library"
            ;;

        REMOTE_PATH_MAPPING)
            echo "Arr appears unable to correctly translate the download client's path"
            ;;

        DOWNLOAD_CLIENT)
            echo "Arr reports a problem communicating with or processing data from the download client"
            ;;

        FILE_LOCKED)
            echo "The downloaded or destination file appears to be locked or temporarily unavailable"
            ;;

        FILE_TOO_SMALL)
            echo "The media file appears too small to be accepted as the expected movie or episode"
            ;;

        SAMPLE_DETECTION)
            echo "Arr is unable to reliably determine whether the downloaded media is a sample"
            ;;

        TITLE_MISMATCH)
            echo "The downloaded title does not sufficiently match the expected movie or episode"
            ;;

        QUALITY_PARSE)
            echo "Arr could not reliably determine the quality or release characteristics"
            ;;

        DESTINATION_CONFLICT)
            echo "The import appears blocked by an existing or conflicting destination file"
            ;;

        PATH)
            echo "Downloaded path is missing or inaccessible"
            ;;

        IMPORT_FAILED)
            echo "Automatic import failed"
            ;;

        MANUAL)
            echo "Manual import/intervention is required"
            ;;

        WARNING)
            echo "Arr reports a download/import warning"
            ;;

        ERROR)
            echo "Arr reports a download/import error"
            ;;

        ARR_IMPORT_STALLED)
            echo "Completed download remains tracked by Arr but has not progressed to import"
            ;;
        
        ACTIVITY_FLOW_ANOMALY)
            echo "Recent SAB completions were observed but the corresponding Arr application recorded no successful imports during the activity-flow window"
            ;;
            
        *)
            echo "Unknown"
            ;;
    esac
}

###############################################################################
# STATE INITIALIZATION
###############################################################################

initialize_state() {

    mkdir -p "$STATE_DIR" || {
        log "ERROR: Unable to create state directory: $STATE_DIR"
        exit 3
    }

    if [ ! -f "$STATE_FILE" ]; then

        cat >"$STATE_FILE" <<'EOF'
{
  "version": 8,
  "issues": {},
  "sabProgress": {},
  "telemetry": {
    "version": 1,
    "patterns": {}
  }
}
EOF
    fi

    if ! jq empty "$STATE_FILE" >/dev/null 2>&1; then

        log "WARNING: State file is invalid"

        if [ -f "$STATE_BACKUP" ] &&
           jq empty "$STATE_BACKUP" >/dev/null 2>&1
        then

            log "Restoring state from backup"

            cp -f "$STATE_BACKUP" "$STATE_FILE"

        else

            log "Creating new state file"

            cat >"$STATE_FILE" <<'EOF'
{
  "version": 8,
  "issues": {},
  "sabProgress": {},
  "telemetry": {
    "version": 1,
    "patterns": {}
  }
}
EOF
        fi
    fi
    ###########################################################################
    # v2.3 STATE MIGRATION
    #
    # Existing v2.1/v2.2 state files are upgraded in place.
    ###########################################################################

    local migrate_tmp

    migrate_tmp="$TMP_DIR/state.migrate.json"

    if jq '
        .version = 8
        |
        .issues = (.issues // {})
        |
        .sabProgress = (.sabProgress // {})
        |
        .telemetry = (
            .telemetry
            // {
                version: 1,
                patterns: {}
            }
        )
        |
        .telemetry.version = 1
        |
        .telemetry.patterns = (.telemetry.patterns // {})
        ' \
        "$STATE_FILE" >"$migrate_tmp" &&
       save_state "$migrate_tmp"
    then

        :

    else

        log "ERROR: Unable to migrate state file to schema version 8"
        exit 3
    fi
}

save_state() {

    local new_state="$1"

    if ! jq empty "$new_state" >/dev/null 2>&1; then

        log "ERROR: Refusing to replace state with invalid JSON: $new_state"

        return 1
    fi

    cp -f "$STATE_FILE" "$STATE_BACKUP" 2>/dev/null || true

    if mv -f "$new_state" "$STATE_FILE"; then
        return 0
    fi

    log "ERROR: Unable to replace state file: $STATE_FILE"
    persistent_log "ERROR" "Unable to replace monitor state file"

    if [ "$STATE_WRITE_ALERT_SENT" != true ]; then

        STATE_WRITE_ALERT_SENT=true

        notify \
            "alert" \
            "ARR Health Monitor - State Write Failed" \
            "The monitor could not update ${STATE_FILE}. Issue lifecycle and notification deduplication may be stale."
    fi

    return 1
}

###############################################################################
# SEEN ISSUE TRACKING
###############################################################################

mark_seen() {

    local issue_key="$1"

    printf '%s\n' "$issue_key" >>"$SEEN_ISSUES_FILE"
}

issue_seen_this_run() {

    local issue_key="$1"

    grep -Fqx -- "$issue_key" "$SEEN_ISSUES_FILE" 2>/dev/null
}

###############################################################################
# ARR MESSAGE TELEMETRY - v2.3
#
# Telemetry is observational only.
#
# It does NOT:
#   - change classifications
#   - change severity
#   - generate extra notifications
#   - modify Sonarr/Radarr
#
# It records only generic fallback classifications:
#
#   WARNING
#   ERROR
#   ARR_IMPORT_STALLED
#
###############################################################################

telemetry_classification_eligible() {

    case "$1" in

        WARNING|ERROR|ARR_IMPORT_STALLED)
            return 0
            ;;

        *)
            return 1
            ;;
    esac
}

###############################################################################
# NORMALIZE ARR MESSAGE
#
# Remove variable data that would otherwise make the same underlying error
# look like hundreds of unique patterns.
#
# Examples removed/normalized:
#
#   UUIDs
#   URLs
#   filesystem paths
#   long hexadecimal identifiers
#   episode numbers such as S03E07
#   repeated whitespace
#
###############################################################################

normalize_arr_message() {

    local message="$1"

    printf '%s' "$message" |
        tr '\r\n\t' '   ' |
        tr '[:upper:]' '[:lower:]' |
        sed -E \
            -e 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<uuid>/g' \
            -e 's#https?://[^[:space:]|]+#<url>#g' \
            -e 's#([a-z]:\\[^[:space:]|]+)#<path>#g' \
            -e 's#(/[^[:space:]|]+)+#<path>#g' \
            -e 's/s[0-9]{1,2}e[0-9]{1,3}/s<season>e<episode>/g' \
            -e 's/[0-9a-f]{20,}/<hex>/g' \
            -e 's/[[:space:]]+/ /g' \
            -e 's/^ //' \
            -e 's/ $//'
}

###############################################################################
# BUILD CONSISTENT ARR PATTERN MESSAGE - v2.4
#
# Telemetry collection and promotion matching MUST use exactly the same
# source message. Otherwise a telemetry pattern collected in v2.3 could fail
# to match the corresponding promotion rule later.
###############################################################################

arr_pattern_raw_message() {

    local tracked_status="$1"
    local tracked_state="$2"
    local arr_status="$3"
    local message="$4"

    if [ -n "$message" ]; then

        printf '%s' "$message"

    else

        printf 'No explicit Arr queue message; status=%s; trackedStatus=%s; trackedState=%s' \
            "$arr_status" \
            "$tracked_status" \
            "$tracked_state"
    fi
}

###############################################################################
# PROMOTED ARR CLASSIFICATION RULES - v2.4
#
# IMPORTANT
# ---------
# Rules are added here ONLY after a real normalized telemetry pattern has
# been reviewed.
#
# Never automatically populate this function from telemetry.
#
# The script remains single-file and deterministic.
###############################################################################

classify_promoted_arr_pattern() {

    local app="$1"
    local tracked_status="$2"
    local tracked_state="$3"
    local arr_status="$4"
    local message="$5"

    if [ "$ARR_PROMOTION_RULES_ENABLED" != true ]; then

        echo "NONE"

        return
    fi

    local raw_message
    local normalized

    raw_message=$(
        arr_pattern_raw_message \
            "$tracked_status" \
            "$tracked_state" \
            "$arr_status" \
            "$message"
    )

    normalized=$(normalize_arr_message "$raw_message")

    [ -n "$normalized" ] || {
        echo "NONE"
        return
    }

    ###########################################################################
    # SONARR PROMOTED RULES
    ###########################################################################

    if [ "$app" = "Sonarr" ]; then

        #
        # FUTURE EXAMPLE ONLY — DO NOT ENABLE WITHOUT REAL TELEMETRY:
        #
        # if [[ "$normalized" == *"some reviewed normalized message"* ]]; then
        #     echo "FILE_LOCKED"
        #     return
        # fi
        #

        :
    fi

    ###########################################################################
    # RADARR PROMOTED RULES
    ###########################################################################

    if [ "$app" = "Radarr" ]; then

        #
        # FUTURE EXAMPLE ONLY — DO NOT ENABLE WITHOUT REAL TELEMETRY:
        #
        # if [[ "$normalized" == *"some reviewed normalized message"* ]]; then
        #     echo "DISK_SPACE"
        #     return
        # fi
        #

        :
    fi

    echo "NONE"
}

###############################################################################
# PROMOTED CLASSIFICATION IDENTIFICATION
#
# These classifications are available to future reviewed rules.
#
# Merely listing them here does NOT activate them.
###############################################################################

is_promoted_classification() {

    case "$1" in

        DISK_SPACE|\
        MOVE_FAILED|\
        COPY_FAILED|\
        REMOTE_PATH_MAPPING|\
        DOWNLOAD_CLIENT|\
        FILE_LOCKED|\
        FILE_TOO_SMALL|\
        SAMPLE_DETECTION|\
        TITLE_MISMATCH|\
        QUALITY_PARSE|\
        DESTINATION_CONFLICT)

            return 0
            ;;
    esac

    return 1
}

###############################################################################
# TELEMETRY PATTERN KEY
###############################################################################

arr_telemetry_pattern_key() {

    local app="$1"
    local classification="$2"
    local normalized="$3"

    printf '%s|%s|%s' \
        "$app" \
        "$classification" \
        "$normalized" |
        sha256sum |
        awk '{print $1}'
}

###############################################################################
# RECORD GENERIC ARR MESSAGE
###############################################################################

record_arr_telemetry() {

    local app="$1"
    local issue_key="$2"
    local media="$3"
    local release="$4"

    local classification="$5"
    local tracked_status="$6"
    local tracked_state="$7"
    local arr_status="$8"
    local message="$9"

    [ "$ARR_TELEMETRY_ENABLED" = true ] || return 0

    telemetry_classification_eligible "$classification" || return 0

    ###########################################################################
    # BUILD RAW MESSAGE
    #
    # Some generic queue states contain little/no explicit message text.
    # In that case preserve the status combination itself as telemetry.
    ###########################################################################

    local raw_message

    raw_message=$(
        arr_pattern_raw_message \
            "$tracked_status" \
            "$tracked_state" \
            "$arr_status" \
            "$message"
    )

    ###########################################################################
    # NORMALIZE
    ###########################################################################

    local normalized

    normalized=$(normalize_arr_message "$raw_message")

    [ -n "$normalized" ] || return 0

    local pattern_key

    pattern_key=$(
        arr_telemetry_pattern_key \
            "$app" \
            "$classification" \
            "$normalized"
    )

    ###########################################################################
    # DETERMINE WHETHER WE HAVE SEEN THIS PATTERN BEFORE
    ###########################################################################

    local pattern_exists=false

    if jq -e \
        --arg key "$pattern_key" \
        '.telemetry.patterns[$key] != null' \
        "$STATE_FILE" >/dev/null 2>&1
    then

        pattern_exists=true
        ((TELEMETRY_EXISTING_PATTERNS++)) || true

    else

        ((TELEMETRY_NEW_PATTERNS++)) || true
    fi

    ((TELEMETRY_OBSERVATIONS++)) || true

    ###########################################################################
    # CAP EXAMPLE SIZE
    ###########################################################################

    local example_message

    example_message="${raw_message:0:${ARR_TELEMETRY_EXAMPLE_MAX_CHARS}}"

    local now
    local tmp

    now=$(date +%s)

    tmp="$TMP_DIR/state.telemetry.json"

    ###########################################################################
    # UPDATE TELEMETRY PATTERN
    ###########################################################################

    jq \
        --arg key "$pattern_key" \
        --arg app "$app" \
        --arg classification "$classification" \
        --arg normalized "$normalized" \
        --arg issueKey "$issue_key" \
        --arg media "$media" \
        --arg release "$release" \
        --arg trackedStatus "$tracked_status" \
        --arg trackedState "$tracked_state" \
        --arg arrStatus "$arr_status" \
        --arg exampleMessage "$example_message" \
        --argjson now "$now" \
        --argjson maxIssueKeys "$ARR_TELEMETRY_MAX_ISSUE_KEYS" \
        --argjson maxExamples "$ARR_TELEMETRY_MAX_EXAMPLES" \
        '
        .version = 8
        |
        .telemetry = (
            .telemetry
            // {
                version: 1,
                patterns: {}
            }
        )
        |
        .telemetry.version = 1
        |
        .telemetry.patterns = (.telemetry.patterns // {})
        |
        (.telemetry.patterns[$key] // {}) as $old
        |
        ($old.issueKeys // []) as $oldKeys
        |
        (
            ($oldKeys + [$issueKey])
            | unique
            |
            if length > $maxIssueKeys
            then .[-$maxIssueKeys:]
            else .
            end
        ) as $issueKeys
        |
        ($old.examples // []) as $oldExamples
        |
        (
            if any($oldExamples[]?; .message == $exampleMessage)
            then

                $oldExamples

            else

                (
                    $oldExamples
                    +
                    [
                        {
                            message: $exampleMessage,
                            media: $media,
                            release: $release,
                            seenAt: $now
                        }
                    ]
                )
            end
            |
            sort_by(.seenAt)
            |
            if length > $maxExamples
            then .[-$maxExamples:]
            else .
            end
        ) as $examples
        |
        .telemetry.patterns[$key] = {

            patternKey: $key,

            app: $app,

            genericClassification: $classification,

            normalizedMessage: $normalized,

            firstSeen:
                (
                    $old.firstSeen
                    // $now
                ),

            lastSeen: $now,

            observations:
                (
                    ($old.observations // 0)
                    + 1
                ),

            distinctIssues:
                (
                    $issueKeys
                    | length
                ),

            issueKeys: $issueKeys,

            lastMedia: $media,

            lastRelease: $release,

            lastTrackedStatus: $trackedStatus,

            lastTrackedState: $trackedState,

            lastArrStatus: $arrStatus,

            examples: $examples
        }
        ' \
        "$STATE_FILE" >"$tmp" || {

            log "WARNING: Unable to update Arr message telemetry"

            return 1
        }

    save_state "$tmp"

    ###########################################################################
    # LOG NEW PATTERNS
    ###########################################################################

    if [ "$pattern_exists" = false ] &&
       [ "$ARR_TELEMETRY_LOG_NEW_PATTERNS" = true ]
    then

        log "------------------------------------------------------------"
        log "New Arr telemetry pattern discovered"
        log "Application: $app"
        log "Generic classification: $classification"
        log "Pattern ID: ${pattern_key:0:12}"
        log "Media: $media"
        log "Normalized message: $normalized"
    fi

    return 0
}

###############################################################################
# TELEMETRY PATTERN COUNT
###############################################################################

arr_telemetry_pattern_count() {

    if [ "$ARR_TELEMETRY_ENABLED" != true ]; then

        echo 0

        return
    fi

    jq -r \
        '.telemetry.patterns // {} | length' \
        "$STATE_FILE" 2>/dev/null ||
        echo 0
}

###############################################################################
# TELEMETRY REVIEW CANDIDATES - v2.4
###############################################################################

arr_telemetry_review_candidate_count() {

    if [ "$ARR_TELEMETRY_ENABLED" != true ]; then

        echo 0

        return
    fi

    jq -r \
        --argjson minDistinct "$ARR_TELEMETRY_REVIEW_MIN_DISTINCT_ISSUES" \
        --argjson minObservations "$ARR_TELEMETRY_REVIEW_MIN_OBSERVATIONS" \
        '
        [
            (
                .telemetry.patterns
                // {}
                | to_entries[]
            )

            | select(

                (.value.distinctIssues // 0) >= $minDistinct

                and

                (.value.observations // 0) >= $minObservations
            )
        ]
        | length
        ' \
        "$STATE_FILE" 2>/dev/null ||
        echo 0
}

###############################################################################
# LOG TOP REVIEW CANDIDATES
###############################################################################

log_arr_telemetry_review_candidates() {

    [ "$ARR_TELEMETRY_ENABLED" = true ] || return

    local candidates

    candidates=$(
        jq -r \
            --argjson minDistinct "$ARR_TELEMETRY_REVIEW_MIN_DISTINCT_ISSUES" \
            --argjson minObservations "$ARR_TELEMETRY_REVIEW_MIN_OBSERVATIONS" \
            --argjson top "$ARR_TELEMETRY_REVIEW_TOP" \
            '
            [
                (
                    .telemetry.patterns
                    // {}
                    | to_entries[]
                )

                | select(

                    (.value.distinctIssues // 0) >= $minDistinct

                    and

                    (.value.observations // 0) >= $minObservations
                )
            ]

            | sort_by(
                [
                    (.value.distinctIssues // 0),
                    (.value.observations // 0),
                    (.value.lastSeen // 0)
                ]
            )

            | reverse

            | .[:$top]

            | .[]

            | [
                (.key[0:12]),
                (.value.app // "Unknown"),
                (.value.genericClassification // "Unknown"),
                ((.value.distinctIssues // 0) | tostring),
                ((.value.observations // 0) | tostring),
                (.value.normalizedMessage // "")
            ]

            | @tsv
            ' \
            "$STATE_FILE" 2>/dev/null
    )

    [ -n "$candidates" ] || return

    log ""
    log "ARR TELEMETRY REVIEW CANDIDATES"
    log "------------------------------------------------------------"

    while IFS=$'\t' read -r \
        pattern_id \
        app \
        classification \
        distinct \
        observations \
        normalized
    do

        [ -n "$pattern_id" ] || continue

        log "Candidate pattern: $pattern_id"
        log "Application: $app"
        log "Current classification: $classification"
        log "Distinct issues: $distinct"
        log "Observations: $observations"
        log "Normalized message: $normalized"
        log "------------------------------------------------------------"

    done <<<"$candidates"
}

###############################################################################
# ISSUE SIGNATURE
###############################################################################

issue_signature() {

    local app="$1"
    local id="$2"
    local classification="$3"
    local severity="$4"
    local stage="$5"
    local message="$6"

    #   - Its underlying Arr/SAB issue message changes
    printf '%s|%s|%s|%s|%s|%s' \
        "$app" \
        "$id" \
        "$classification" \
        "$severity" \
        "$stage" \
        "$message" |
        sha256sum |
        awk '{print $1}'
}

###############################################################################
# PERSISTENT ISSUE TRANSITION CHECK - v2.5
#
# Persist only when:
#
#   - issue is new
#   - a resolved issue returns
#   - classification/severity/stage/message changes
#
###############################################################################

issue_transition_should_persist() {

    local issue_key="$1"
    local signature="$2"

    local previous_signature
    local previous_active

    previous_signature=$(
        jq -r \
            --arg key "$issue_key" \
            '.issues[$key].signature // ""' \
            "$STATE_FILE"
    )

    previous_active=$(
        jq -r \
            --arg key "$issue_key" \
            '(.issues[$key].active // false) | tostring' \
            "$STATE_FILE"
    )

    if [ "$previous_active" != "true" ]; then
        return 0
    fi

    if [ "$previous_signature" != "$signature" ]; then
        return 0
    fi

    return 1
}

###############################################################################
# ISSUE STATE UPDATE
#
# If an issue was previously resolved and returns:
#
#   - firstSeen resets
#   - occurrences resets
#   - notifiedSignature resets
#
# This allows the returning issue to alert again.
###############################################################################

update_issue_state() {

    local issue_key="$1"
    local signature="$2"
    local app="$3"
    local title="$4"
    local classification="$5"
    local severity="$6"
    local stage="$7"
    local message="$8"

    local now
    local tmp

    now=$(date +%s)

    tmp="$TMP_DIR/state.new.json"

    jq \
        --arg key "$issue_key" \
        --arg signature "$signature" \
        --arg app "$app" \
        --arg title "$title" \
        --arg classification "$classification" \
        --arg severity "$severity" \
        --arg stage "$stage" \
        --arg message "$message" \
        --argjson now "$now" \
        '
        .version = 8
        |
        (.issues[$key] // {}) as $old
        |
        ($old.active // false) as $wasActive
        |
        .issues[$key] = {
            signature: $signature,

            notifiedSignature:
                (
                    if $wasActive
                    then ($old.notifiedSignature // "")
                    else ""
                    end
                ),

            app: $app,
            title: $title,
            classification: $classification,
            severity: $severity,
            stage: $stage,
            message: $message,

            firstSeen:
                (
                    if $wasActive
                    then ($old.firstSeen // $now)
                    else $now
                    end
                ),

            lastSeen: $now,

            occurrences:
                (
                    if $wasActive
                    then (($old.occurrences // 0) + 1)
                    else 1
                    end
                ),

            active: true,
            resolvedAt: null
        }
        ' \
        "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp"

    mark_seen "$issue_key"
}

###############################################################################
# NOTIFICATION DEDUP
###############################################################################

should_notify() {

    local issue_key="$1"
    local signature="$2"

    if [ "$NOTIFY_ONCE" != true ]; then
        return 0
    fi

    local previous

    previous=$(
        jq -r \
            --arg key "$issue_key" \
            '.issues[$key].notifiedSignature // ""' \
            "$STATE_FILE"
    )

    if [ "$previous" = "$signature" ]; then

        ((NOTIFICATIONS_SUPPRESSED++)) || true

        return 1
    fi

    return 0
}

mark_notified() {

    local issue_key="$1"
    local signature="$2"

    local tmp

    tmp="$TMP_DIR/state.notified.json"

    jq \
        --arg key "$issue_key" \
        --arg signature "$signature" \
        '
        if .issues[$key] then
            .issues[$key].notifiedSignature = $signature
        else
            .
        end
        ' \
        "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp"
}

###############################################################################
# RESOLUTION TRACKING
###############################################################################

mark_issue_resolved() {

    local issue_key="$1"

    local now
    local tmp

    now=$(date +%s)

    tmp="$TMP_DIR/state.resolved.json"

    jq \
        --arg key "$issue_key" \
        --argjson now "$now" \
        '
        if .issues[$key] then

            .issues[$key].active = false
            |
            .issues[$key].resolvedAt = $now

        else
            .
        end
        ' \
        "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp"
}

###############################################################################
# DETERMINE WHETHER SOURCE WAS HEALTHY ENOUGH TO DECLARE RESOLUTION
###############################################################################

source_can_resolve() {

    local source="$1"
    local issue_key="${2:-}"

    case "$source" in

        Sonarr)

            case "$issue_key" in

                Sonarr:service-api)
                    [ "$SONARR_API_OK" = true ]
                    ;;

                Sonarr:health:*)
                    [ "$SONARR_HEALTH_OK" = true ]
                    ;;

                Sonarr:history:*)
                    [ "$SONARR_AUDIT_OK" = true ]
                    ;;

                *)
                    [ "$SONARR_QUEUE_OK" = true ]
                    ;;
            esac
            ;;

        Radarr)

            case "$issue_key" in

                Radarr:service-api)
                    [ "$RADARR_API_OK" = true ]
                    ;;

                Radarr:health:*)
                    [ "$RADARR_HEALTH_OK" = true ]
                    ;;

                Radarr:history:*)
                    [ "$RADARR_AUDIT_OK" = true ]
                    ;;

                *)
                    [ "$RADARR_QUEUE_OK" = true ]
                    ;;
            esac
            ;;

        SABnzbd)

            case "$issue_key" in

                SABnzbd:service-api)
                    [ "$SAB_API_OK" = true ]
                    ;;

                SABnzbd:warning:*)
                    [ "$SAB_WARNINGS_OK" = true ]
                    ;;

                SABnzbd:status:*)
                    [ "$SAB_STATUS_OK" = true ]
                    ;;

                SABnzbd:queue:*|SABnzbd:category:*)
                    [ "$SAB_QUEUE_OK" = true ]
                    ;;

                SABnzbd:history:*)
                    [ "$SAB_HISTORY_OK" = true ]
                    ;;

                *)
                    # Existing stranded-file issues depend on SAB history and
                    # successful knowledge of both Arr queues.
                    [ "$SAB_HISTORY_OK" = true ] &&
                    [ "$SONARR_QUEUE_OK" = true ] &&
                    [ "$RADARR_QUEUE_OK" = true ]
                    ;;
            esac
            ;;

        *)

            return 1
            ;;
    esac
}

###############################################################################
# RESOLVE ISSUES NOT SEEN THIS RUN
###############################################################################

resolve_missing_issues() {

    log "Checking previously active issues for resolution"

    local active_records

    active_records=$(
        jq -c '
            .issues
            | to_entries[]
            | select(.value.active == true)
        ' "$STATE_FILE"
    )

    [ -n "$active_records" ] || {
        log "No previously active issues require resolution checking"
        return
    }

    while IFS= read -r record; do

        [ -n "$record" ] || continue

        local issue_key
        local source
        local title
        local classification
        local first_seen
        local now
        local lifetime_hours
        local notified_signature

        issue_key=$(echo "$record" | jq -r '.key')
        source=$(echo "$record" | jq -r '.value.app // ""')
        title=$(echo "$record" | jq -r '.value.title // "Unknown"')
        classification=$(echo "$record" | jq -r '.value.classification // "Unknown"')
        notified_signature=$(echo "$record" | jq -r '.value.notifiedSignature // ""')

        if issue_seen_this_run "$issue_key"; then
            continue
        fi

        #
        # Do not declare resolution if the relevant API was unavailable.
        #

        if ! source_can_resolve "$source" "$issue_key"; then

            log "Resolution deferred for $issue_key because required source scan was unavailable"

            continue
        fi

        first_seen=$(echo "$record" | jq -r '.value.firstSeen // 0')

        now=$(date +%s)

        lifetime_hours=0

        if [[ "$first_seen" =~ ^[0-9]+$ ]] &&
           (( first_seen > 0 ))
        then
            lifetime_hours=$(( (now - first_seen) / 3600 ))
        fi

        if mark_issue_resolved "$issue_key"; then

            ((RESOLVED_COUNT++)) || true

            log "------------------------------------------------------------"
            log "Issue resolved"
            log "Source: $source"
            log "Media: $title"
            log "Previous classification: $classification"
            log "Observed lifetime: approximately ${lifetime_hours}h"
            log "Resolution notification enabled: $SEND_RESOLUTION_NOTIFICATIONS"
            persistent_log \
                "RESOLVED" \
                "${source} | ${classification} | ${title} | lifetime=${lifetime_hours}h"

            if [ "$SEND_RESOLUTION_NOTIFICATIONS" = true ] &&
               [ -n "$notified_signature" ]; then

                local resolution_signature

                resolution_signature=$(issue_signature \
                    "$source" \
                    "$issue_key" \
                    "$classification" \
                    "INFO" \
                    "resolved" \
                    "resolved")

                queue_group_notification \
                    "$issue_key" \
                    "$resolution_signature" \
                    "$source" \
                    "$title" \
                    "$classification" \
                    "INFO" \
                    "$lifetime_hours" \
                    "Condition is no longer present" \
                    "resolved"
            fi

        else

            log "WARNING: Failed to mark issue resolved: $issue_key"
        fi

    done <<<"$active_records"
}

###############################################################################
# GROUPED NOTIFICATION BATCH
###############################################################################

queue_group_notification() {

    local issue_key="$1"
    local signature="$2"
    local source="$3"
    local title="$4"
    local classification="$5"
    local severity="$6"
    local age="$7"
    local detail="$8"
    local event="${9:-new}"

    jq -nc \
        --arg issueKey "$issue_key" \
        --arg signature "$signature" \
        --arg source "$source" \
        --arg title "$title" \
        --arg classification "$classification" \
        --arg severity "$severity" \
        --arg age "$age" \
        --arg detail "$detail" \
        --arg event "$event" \
        '{
            issueKey: $issueKey,
            signature: $signature,
            source: $source,
            title: $title,
            classification: $classification,
            severity: $severity,
            age: $age,
            detail: $detail,
            event: $event
        }' \
        >>"$NOTIFICATION_BATCH"

    ((BATCHED_NOTIFICATION_ITEMS++)) || true

    log "Queued issue for grouped notification"
}

batch_highest_severity() {

    if jq -e \
        'select(.severity == "ERROR" and .event != "resolved")' \
        "$NOTIFICATION_BATCH" \
        >/dev/null 2>&1
    then
        echo "ERROR"
        return
    fi

    if jq -e \
        'select(.severity == "WARNING" and .event != "resolved")' \
        "$NOTIFICATION_BATCH" \
        >/dev/null 2>&1
    then
        echo "WARNING"
        return
    fi

    echo "INFO"
}

send_grouped_notification() {

    [ -f "$NOTIFICATION_BATCH" ] || return 0
    [ -s "$NOTIFICATION_BATCH" ] || return 0

    local total
    local shown
    local omitted

    local highest
    local importance
    local description

    local info_new
    local warning_new
    local error_new
    local resolved

    local body=""
    local source

    total=$(wc -l <"$NOTIFICATION_BATCH" | tr -d ' ')

    (( total > 0 )) || return 0

    highest=$(batch_highest_severity)

    info_new=$(
        jq -s \
            '[.[] | select(.severity == "INFO" and .event != "resolved")] | length' \
            "$NOTIFICATION_BATCH"
    )

    warning_new=$(
        jq -s \
            '[.[] | select(.severity == "WARNING" and .event != "resolved")] | length' \
            "$NOTIFICATION_BATCH"
    )

    error_new=$(
        jq -s \
            '[.[] | select(.severity == "ERROR" and .event != "resolved")] | length' \
            "$NOTIFICATION_BATCH"
    )

    resolved=$(
        jq -s \
            '[.[] | select(.event == "resolved")] | length' \
            "$NOTIFICATION_BATCH"
    )

    case "$highest" in

        ERROR)
            importance="alert"
            description="ARR Health Monitor - ${total} Update(s)"
            ;;

        WARNING)
            importance="warning"
            description="ARR Health Monitor - ${total} Update(s)"
            ;;

        *)
            importance="normal"
            description="ARR Health Monitor - ${total} Update(s)"
            ;;
    esac

    body="Health/activity updates: ${total}"$'\n'
    body+="Info: ${info_new} | Warnings: ${warning_new} | Errors: ${error_new} | Resolved: ${resolved}"$'\n'

    shown=0

    for source in Sonarr Radarr SABnzbd; do

        local source_count

        source_count=$(
            jq -s \
                --arg source "$source" \
                '[.[] | select(.source == $source)] | length' \
                "$NOTIFICATION_BATCH"
        )

        (( source_count > 0 )) || continue

        body+=$'\n'
        body+="${source} (${source_count})"$'\n'
        body+="--------------------"$'\n'

        while IFS= read -r record; do

            if (( shown >= GROUP_NOTIFICATION_MAX_ITEMS )); then
                break
            fi

            local item_title
            local classification
            local severity
            local age
            local detail
            local event

            item_title=$(echo "$record" | jq -r '.title')
            classification=$(echo "$record" | jq -r '.classification')
            severity=$(echo "$record" | jq -r '.severity')
            age=$(echo "$record" | jq -r '.age')
            detail=$(echo "$record" | jq -r '.detail')
            event=$(echo "$record" | jq -r '.event // "new"')

            body+="- ${item_title}"$'\n'

            if [ "$event" = "resolved" ]; then
                body+="  ${classification} [RESOLVED]"$'\n'
            else
                body+="  ${classification} [${severity}]"$'\n'
            fi

            if [ -n "$age" ] && [ "$age" != "0" ]; then
                body+="  Age: ${age}h"$'\n'
            fi

            if [ -n "$detail" ]; then

                while IFS= read -r detail_line; do

                    [ -n "$detail_line" ] || continue

                    body+="  ${detail_line}"$'\n'

                done <<<"$detail"
            fi

            body+=$'\n'

            ((shown++)) || true

        done < <(
            jq -c \
                --arg source "$source" \
                'select(.source == $source)' \
                "$NOTIFICATION_BATCH"
        )

        if (( shown >= GROUP_NOTIFICATION_MAX_ITEMS )); then
            break
        fi

    done

    omitted=$(( total - shown ))

    if (( omitted > 0 )); then

        body+="Additional issues omitted: ${omitted}"$'\n'
        body+="See the User Scripts log for full details."$'\n'
    fi

    body+=$'\n'
    body+="Monitor schedule: every five minutes recommended"$'\n'
    body+="Runtime: $(runtime)"

    notify \
        "$importance" \
        "$description" \
        "$body"

    local notify_rc=$?

    if [ "$notify_rc" -eq 2 ]; then

        log "Grouped notifications disabled"
        log "New issues that would be grouped: $total"

        return 0
    fi

    if [ "$notify_rc" -ne 0 ]; then

        log "ERROR: Grouped notification failed"
        log "Issue notification state will NOT be marked as sent"

        return 1
    fi

    #
    # Mark individual issues only after successful grouped send.
    #

    while IFS= read -r record; do

        local issue_key
        local signature

        issue_key=$(echo "$record" | jq -r '.issueKey')
        signature=$(echo "$record" | jq -r '.signature')

        if ! mark_notified "$issue_key" "$signature"; then

            log "WARNING: Failed to mark issue notified: $issue_key"
        fi

    done <"$NOTIFICATION_BATCH"

    log "Grouped notification sent successfully"
    log "Issues included: $total"

    return 0
}

###############################################################################
# NORMALIZED ISSUE RECORDER - v3.0
#
# Service collectors emit the same compact issue shape. This is the only new
# path responsible for lifecycle, deduplication, escalation, and grouping.
###############################################################################

record_normalized_issue() {

    local issue_key="$1"
    local source="$2"
    local title="$3"
    local classification="$4"
    local severity="$5"
    local stage="$6"
    local message="$7"
    local display_age="$8"
    local detail="$9"
    local notify_runs="${10:-1}"
    local minimum_minutes="${11:-0}"
    local escalate_minutes="${12:-0}"

    if issue_seen_this_run "$issue_key"; then
        return 0
    fi

    local now
    local first_seen
    local active
    local elapsed_minutes=0
    local signature
    local persist_issue_transition=false
    local occurrences

    now=$(date +%s)

    active=$(jq -r \
        --arg key "$issue_key" \
        '(.issues[$key].active // false) | tostring' \
        "$STATE_FILE")

    first_seen=$(jq -r \
        --arg key "$issue_key" \
        '.issues[$key].firstSeen // 0' \
        "$STATE_FILE")

    if [ "$active" = true ] &&
       [[ "$first_seen" =~ ^[0-9]+$ ]] &&
       (( first_seen > 0 && now > first_seen ))
    then
        elapsed_minutes=$(( (now - first_seen) / 60 ))
    fi

    if (( escalate_minutes > 0 && elapsed_minutes >= escalate_minutes )); then
        stage="escalated"
    fi

    signature=$(issue_signature \
        "$source" \
        "$issue_key" \
        "$classification" \
        "$severity" \
        "$stage" \
        "$message")

    if issue_transition_should_persist "$issue_key" "$signature"; then
        persist_issue_transition=true
    fi

    if ! update_issue_state \
        "$issue_key" \
        "$signature" \
        "$source" \
        "$title" \
        "$classification" \
        "$severity" \
        "$stage" \
        "$message"
    then
        log "ERROR: Unable to update normalized issue state: $issue_key"
        return 1
    fi

    occurrences=$(jq -r \
        --arg key "$issue_key" \
        '.issues[$key].occurrences // 1' \
        "$STATE_FILE")

    ((TOTAL_ISSUES++)) || true

    case "$severity" in

        INFO)
            ((INFO_COUNT++)) || true
            ;;

        WARNING)
            ((WARNING_COUNT++)) || true
            ;;

        ERROR)
            ((ERROR_COUNT++)) || true
            ;;
    esac

    if [ "$persist_issue_transition" = true ]; then

        persistent_log \
            "ISSUE" \
            "${source} | ${classification} | ${severity} | ${title} | stage=${stage}"
    fi

    if (( occurrences < notify_runs || elapsed_minutes < minimum_minutes )); then

        log "Notification pending threshold: $issue_key"
        log "Observations: ${occurrences}/${notify_runs}; active minutes: ${elapsed_minutes}/${minimum_minutes}"

        return 0
    fi

    if should_notify "$issue_key" "$signature"; then

        queue_group_notification \
            "$issue_key" \
            "$signature" \
            "$source" \
            "$title" \
            "$classification" \
            "$severity" \
            "$display_age" \
            "$detail"

    else

        log "Notification suppressed: normalized issue already reported"
    fi
}

stable_issue_hash() {

    printf '%s' "$1" |
        sha256sum |
        awk '{print $1}'
}

###############################################################################
# SONARR / RADARR NATIVE HEALTH
###############################################################################

process_arr_native_health() {

    local app="$1"
    local health_file="$2"

    [ -f "$health_file" ] || return 0

    while IFS= read -r record; do

        [ -n "$record" ] || continue

        local health_source
        local health_type
        local message
        local wiki_url
        local severity
        local notify_runs
        local issue_hash
        local detail

        health_source=$(jq -r '.source // "Unknown health check"' <<<"$record")
        health_type=$(jq -r '.type // "warning"' <<<"$record")
        message=$(jq -r '.message // "No health detail supplied"' <<<"$record")
        wiki_url=$(jq -r '.wikiUrl // ""' <<<"$record")

        case "${health_type,,}" in

            error)
                severity="ERROR"
                notify_runs="$ARR_HEALTH_ERROR_NOTIFY_RUNS"
                ;;

            *)
                severity="WARNING"
                notify_runs="$ARR_HEALTH_WARNING_NOTIFY_RUNS"
                ;;
        esac

        issue_hash=$(stable_issue_hash "${app}|${health_source}|${message}")
        detail="$message"

        if [ -n "$wiki_url" ]; then
            detail+=$'\n'
            detail+="Help: ${wiki_url}"
        fi

        log "${app} native health issue: ${health_source} (${health_type})"

        record_normalized_issue \
            "${app}:health:${issue_hash}" \
            "$app" \
            "Health: ${health_source}" \
            "ARR_HEALTH_${health_type^^}" \
            "$severity" \
            "active" \
            "$message" \
            "" \
            "$detail" \
            "$notify_runs" \
            0 \
            "$API_FAILURE_ESCALATE_MINUTES"

        ((ARR_NATIVE_HEALTH_COUNT++)) || true

    done < <(jq -c '.[]?' "$health_file")
}

record_service_api_issue() {

    local app="$1"
    local api_ok="$2"
    local failures="$3"

    [ "$api_ok" = true ] && return 0
    [ -n "$failures" ] || failures="one or more required API endpoints failed"

    local classification="SERVICE_API_UNAVAILABLE"
    local notify_runs="$API_FAILURE_NOTIFY_RUNS"

    if grep -Eqi 'authentication rejected|HTTP (401|403)|api key.*(incorrect|required)' <<<"$failures"; then
        classification="SERVICE_API_AUTHENTICATION"
        notify_runs=2
    fi

    record_normalized_issue \
        "${app}:service-api" \
        "$app" \
        "${app} API unavailable" \
        "$classification" \
        "ERROR" \
        "degraded" \
        "$failures" \
        "" \
        "$failures" \
        "$notify_runs" \
        0 \
        "$API_FAILURE_ESCALATE_MINUTES"

    ((SERVICE_API_ISSUE_COUNT++)) || true
}

###############################################################################
# DOWNLOAD CORRELATION HELPERS
###############################################################################

arr_queue_item_by_download_id() {

    local owner="$1"
    local download_id="$2"
    local queue=""

    case "$owner" in

        Sonarr)
            queue="$SONARR_QUEUE"
            ;;

        Radarr)
            queue="$RADARR_QUEUE"
            ;;
    esac

    if [ -z "$queue" ] || [ ! -f "$queue" ]; then
        printf '{}'
        return 0
    fi

    jq -c \
        --arg id "$download_id" \
        '[
            .records[]?
            | select(
                ((.downloadId // "") | ascii_downcase)
                ==
                ($id | ascii_downcase)
            )
        ]
        | first // {}' \
        "$queue"
}

mark_sab_primary_download() {

    local download_id="${1,,}"

    [ -n "$download_id" ] || return 0

    printf '%s\n' "$download_id" >>"$SAB_PRIMARY_DOWNLOADS_FILE"
}

sab_primary_download_exists() {

    local download_id="${1,,}"

    [ -n "$download_id" ] || return 1

    grep -Fqx -- "$download_id" "$SAB_PRIMARY_DOWNLOADS_FILE" 2>/dev/null
}

###############################################################################
# SAB LOOKUP
###############################################################################

sab_history_lookup() {

    local download_id="$1"

    if [ "$SAB_ENABLED" != true ] ||
       [ -z "$SAB_HISTORY" ] ||
       [ ! -f "$SAB_HISTORY" ]
    then

        echo '{}'

        return
    fi

    jq -c \
        --arg id "$download_id" \
        '
        .history.slots // []
        | map(
            select(
                (.nzo_id // "" | ascii_downcase)
                ==
                ($id | ascii_downcase)
            )
        )
        | first // {}
        ' \
        "$SAB_HISTORY"
}

###############################################################################
# ARR DOWNLOAD LOOKUP
###############################################################################

arr_tracks_download() {

    local app="$1"
    local download_id="$2"

    local queue=""

    case "$app" in

        Sonarr)

            [ "$SONARR_SCAN_OK" = true ] || return 2

            queue="$SONARR_QUEUE"
            ;;

        Radarr)

            [ "$RADARR_SCAN_OK" = true ] || return 2

            queue="$RADARR_QUEUE"
            ;;

        *)

            return 2
            ;;
    esac

    [ -n "$queue" ] || return 2
    [ -f "$queue" ] || return 2

    jq -e \
        --arg id "$download_id" \
        '
        any(
            .records[]?;
            ((.downloadId // "") | ascii_downcase)
            ==
            ($id | ascii_downcase)
        )
        ' \
        "$queue" >/dev/null 2>&1
}

###############################################################################
# CF LOG / GROUP DETAILS
###############################################################################

log_cf_details() {

    local message="$1"

    local new_score
    local existing_score
    local difference

    local new_formats
    local existing_formats

    local gained
    local missing

    new_score=$(extract_cf_new_score "$message")
    existing_score=$(extract_cf_existing_score "$message")

    new_formats=$(extract_cf_new_formats "$message")
    existing_formats=$(extract_cf_existing_formats "$message")

    if [[ "$new_score" =~ ^-?[0-9]+$ ]] &&
       [[ "$existing_score" =~ ^-?[0-9]+$ ]]
    then

        difference=$(( new_score - existing_score ))

        log "New CF score: $new_score"
        log "Existing CF score: $existing_score"
        log "CF score difference: $difference"
    fi

    if [ -n "$new_formats" ] &&
       [ -n "$existing_formats" ]
    then

        gained=$(cf_difference "$new_formats" "$existing_formats")
        missing=$(cf_difference "$existing_formats" "$new_formats")

        if [ -n "$gained" ]; then

            log "CFs only in downloaded release:"

            while IFS= read -r cf; do
                [ -n "$cf" ] && log "  + $cf"
            done <<<"$gained"
        fi

        if [ -n "$missing" ]; then

            log "CFs only in existing media:"

            while IFS= read -r cf; do
                [ -n "$cf" ] && log "  + $cf"
            done <<<"$missing"
        fi
    fi
}

build_cf_group_detail() {

    local message="$1"

    local new_score
    local existing_score
    local difference

    local new_formats
    local existing_formats

    local gained
    local missing

    local output=""

    new_score=$(extract_cf_new_score "$message")
    existing_score=$(extract_cf_existing_score "$message")

    new_formats=$(extract_cf_new_formats "$message")
    existing_formats=$(extract_cf_existing_formats "$message")

    if [[ "$new_score" =~ ^-?[0-9]+$ ]] &&
       [[ "$existing_score" =~ ^-?[0-9]+$ ]]
    then

        difference=$(( new_score - existing_score ))

        if (( difference > 0 )); then

            output+="CF: ${new_score} vs ${existing_score} (+${difference})"

        else

            output+="CF: ${new_score} vs ${existing_score} (${difference})"
        fi
    fi

    if [ -n "$new_formats" ] &&
       [ -n "$existing_formats" ]
    then

        gained=$(cf_difference "$new_formats" "$existing_formats")
        missing=$(cf_difference "$existing_formats" "$new_formats")

        if [ -n "$gained" ]; then

            local gained_line

            gained_line=$(echo "$gained" | join_lines)

            [ -z "$output" ] || output+=$'\n'

            output+="Download-only CF: ${gained_line}"
        fi

        if [ -n "$missing" ]; then

            local missing_line

            missing_line=$(echo "$missing" | join_lines)

            [ -z "$output" ] || output+=$'\n'

            output+="Existing-only CF: ${missing_line}"
        fi
    fi

    printf '%s' "$output"
}

###############################################################################
# PROCESS ARR QUEUE
###############################################################################

process_queue() {

    local app="$1"
    local queue_file="$2"

    if ! jq -e '(.records // [] | length) > 0' "$queue_file" >/dev/null 2>&1; then

        log "$app queue: no entries"

        return
    fi

    while IFS= read -r item; do

        [ -n "$item" ] || continue

        ((TOTAL_QUEUE++)) || true

        local id
        local download_id
        local media_name
        local release

        local status
        local tracked_status
        local tracked_state

        local added
        local age

        local message
        local classification
        local severity
        local min_age
        local reason

        id=$(echo "$item" | jq -r '.id // ""')
        download_id=$(echo "$item" | jq -r '.downloadId // ""')

        media_name=$(friendly_media_name "$app" "$item")
        release=$(release_name "$item")

        status=$(echo "$item" | jq -r '.status // "unknown"')

        tracked_status=$(
            echo "$item" |
            jq -r '.trackedDownloadStatus // "unknown"'
        )

        tracked_state=$(
            echo "$item" |
            jq -r '.trackedDownloadState // "unknown"'
        )

        added=$(echo "$item" | jq -r '.added // ""')

        age=$(age_hours "$added")

        if (( age < IGNORE_BEFORE_HOURS )); then
            continue
        fi

        message=$(queue_message "$item")

        classification=$(
            classify_issue \
                "$tracked_status" \
                "$tracked_state" \
                "$status" \
                "$message"
        )

        [ "$classification" != "NONE" ] || continue

        #######################################################################
        # PRIMARY-CAUSE CORRELATION
        #
        # A current SAB failed/stalled issue owns the notification for this
        # download. The Arr queue symptom is retained in SAB's detail instead
        # of producing a second email for the same download chain.
        #######################################################################

        if [ -n "$download_id" ] &&
           sab_primary_download_exists "$download_id"
        then
            log "$app queue symptom suppressed by primary SAB issue: $download_id"
            continue
        fi

        ###############################################################################
        # v2.4 REVIEWED CLASSIFICATION PROMOTION
        #
        # Only generic fallback classifications are eligible.
        #
        # Existing known classifiers always take precedence.
        ###############################################################################

        if telemetry_classification_eligible "$classification"; then

            local promoted_classification

            promoted_classification=$(
                classify_promoted_arr_pattern \
                    "$app" \
                    "$tracked_status" \
                    "$tracked_state" \
                    "$status" \
                    "$message"
            )

            if [ "$promoted_classification" != "NONE" ]; then

                #######################################################################
                # VALIDATE PROMOTED CLASSIFICATION
                #
                # Promotion rules are manually maintained.
                # This prevents an accidental typo or unsupported classification from
                # entering state, notifications, or severity logic.
                #######################################################################

                if is_promoted_classification "$promoted_classification"; then

                    log "Arr generic classification promoted"
                    log "Application: $app"
                    log "From: $classification"
                    log "To: $promoted_classification"

                    classification="$promoted_classification"

                    ((PROMOTION_RULE_MATCHES++)) || true

                else

                    log "WARNING: Invalid promoted Arr classification returned"
                    log "Application: $app"
                    log "Returned classification: $promoted_classification"
                    log "Original classification retained: $classification"
                fi
            fi
        fi

        ###############################################################################
        # BUILD ISSUE KEY EARLY
        #
        # v2.3 telemetry records generic Arr messages even before the normal
        # notification-age threshold is reached.
        ###############################################################################

        local issue_key

        if [ -n "$download_id" ]; then

            issue_key="${app}:${download_id}"

        else

            issue_key="${app}:queue:${id}"
        fi

        ###############################################################################
        # ARR MESSAGE TELEMETRY
        #
        # This has NO effect on notification eligibility or classification.
        ###############################################################################

        record_arr_telemetry \
            "$app" \
            "$issue_key" \
            "$media_name" \
            "$release" \
            "$classification" \
            "$tracked_status" \
            "$tracked_state" \
            "$status" \
            "$message"

        ###############################################################################
        # NORMAL AGE THRESHOLD
        ###############################################################################

        min_age=$(classification_min_age "$classification")

        if (( age < min_age )); then
            continue
        fi

        severity=$(
            classification_severity \
                "$classification" \
                "$age"
        )

        reason=$(
            classification_reason \
                "$classification" \
                "$age"
        )

        ((TOTAL_ISSUES++)) || true

        case "$severity" in

            INFO)
                ((INFO_COUNT++)) || true
                ;;

            WARNING)
                ((WARNING_COUNT++)) || true
                ;;

            ERROR)
                ((ERROR_COUNT++)) || true
                ;;
        esac

        case "$classification" in

            CF_REJECT*)
                ((CF_REJECT_COUNT++)) || true
                ;;

            UPGRADE_REJECT)
                ((UPGRADE_REJECT_COUNT++)) || true
                ;;

            TBA_METADATA)
                ((TBA_COUNT++)) || true
                ;;

            UNMATCHED_MEDIA)
                ((UNMATCHED_COUNT++)) || true
                ;;

            NO_IMPORTABLE_FILES)
                ((NO_IMPORT_COUNT++)) || true
                ;;

            ARR_IMPORT_STALLED)
                ((STALL_COUNT++)) || true
                ;;
        esac

        #######################################################################
        # SAB CORRELATION
        #######################################################################

        local sab_item
        local sab_status

        sab_status="Unknown"

        if [ -n "$download_id" ]; then

            sab_item=$(sab_history_lookup "$download_id")

            sab_status=$(
                echo "$sab_item" |
                jq -r '.status // "Unknown"'
            )
        fi

        #######################################################################
        # LOG
        #######################################################################

        log "------------------------------------------------------------"
        log "$app issue detected"
        log "Media: $media_name"
        log "Release: $release"
        log "Classification: $classification"
        log "Severity: $severity"
        log "Reason: $reason"
        log "Queue age: ${age}h"
        log "Arr status: $status"
        log "Tracked status: $tracked_status"
        log "Tracked state: $tracked_state"

        [ -n "$download_id" ] &&
            log "Download ID: $download_id"

        [ "$sab_status" != "Unknown" ] &&
            log "SAB status: $sab_status"

        if [[ "$classification" == CF_REJECT* ]]; then
            log_cf_details "$message"
        fi

        [ -n "$message" ] &&
            log "Arr message: $message"

        #######################################################################
        # STATE
        #######################################################################

        local signature
        local stage="normal"

        if is_policy_rejection "$classification" ||
           [ "$classification" = "TBA_METADATA" ]
        then

            if (( age >= POLICY_ESCALATE_AFTER_HOURS )); then
                stage="escalated"
            fi
        fi

        signature=$(
            issue_signature \
                "$app" \
                "${download_id:-$id}" \
                "$classification" \
                "$severity" \
                "$stage" \
                "$message"
        )

        local persist_issue_transition=false

        if issue_transition_should_persist \
            "$issue_key" \
            "$signature"
        then
            persist_issue_transition=true
        fi

        update_issue_state \
            "$issue_key" \
            "$signature" \
            "$app" \
            "$media_name" \
            "$classification" \
            "$severity" \
            "$stage" \
            "$message"

        if [ "$persist_issue_transition" = true ]; then

            persistent_log \
                "ISSUE" \
                "${app} | ${classification} | ${severity} | ${media_name} | age=${age}h"
        fi

        #######################################################################
        # GROUP NOTIFICATION
        #######################################################################

        if should_notify "$issue_key" "$signature"; then

            local detail=""

            if [[ "$classification" == CF_REJECT* ]]; then

                detail=$(build_cf_group_detail "$message")

            elif [ -n "$reason" ]; then

                detail="$reason"
            fi

            if [ -n "$message" ]; then

                [ -z "$detail" ] || detail+=$'\n'
                detail+="Arr detail: ${message:0:1000}"
            fi

            [ -z "$detail" ] || detail+=$'\n'
            detail+="Release: ${release}"
            detail+=$'\n'
            detail+="Queue: status=${status}, tracked=${tracked_status}/${tracked_state}"

            if [ "$sab_status" != "Unknown" ]; then
                detail+=$'\n'
                detail+="SAB status: ${sab_status}"
            fi

            queue_group_notification \
                "$issue_key" \
                "$signature" \
                "$app" \
                "$media_name" \
                "$classification" \
                "$severity" \
                "$age" \
                "$detail"

        else

            log "Notification suppressed: issue already reported"
        fi

    done < <(jq -c '.records[]?' "$queue_file")
}

###############################################################################
# SAB HELPERS
###############################################################################

sab_completed_epoch() {

    local item="$1"

    local value

    value=$(
        echo "$item" |
        jq -r '
            .completed
            // .completed_time
            // .completedTime
            // .completionTime
            // ""
        '
    )

    date_to_epoch "$value"
}

sab_category_owner() {

    local category="${1,,}"

    if [ "$category" = "${SAB_MOVIE_CATEGORY,,}" ]; then

        echo "Radarr"

        return
    fi

    if [ "$category" = "${SAB_TV_CATEGORY,,}" ]; then

        echo "Sonarr"

        return
    fi

    echo ""
}

sab_category_root() {

    local category="${1,,}"

    if [ "$category" = "${SAB_MOVIE_CATEGORY,,}" ]; then

        echo "$SAB_MOVIE_DIR"

        return
    fi

    if [ "$category" = "${SAB_TV_CATEGORY,,}" ]; then

        echo "$SAB_TV_DIR"

        return
    fi

    echo ""
}

###############################################################################
# SAB NATIVE WARNINGS / FAILED JOBS / LIVE PROGRESS - v3.0
###############################################################################

process_sab_warnings() {

    [ "$SAB_WARNINGS_OK" = true ] || return 0
    [ -f "$SAB_WARNINGS" ] || return 0

    while IFS= read -r record; do

        [ -n "$record" ] || continue

        local warning_type
        local warning_text
        local warning_origin
        local severity
        local classification
        local notify_runs
        local issue_hash

        warning_type=$(jq -r '.type // "WARNING"' <<<"$record")
        warning_text=$(jq -r '.text // .message // "SABnzbd warning without detail"' <<<"$record")
        warning_origin=$(jq -r '.origin // "SABnzbd"' <<<"$record")

        case "${warning_type^^}" in

            ERROR)
                severity="ERROR"
                classification="SAB_ERROR"
                notify_runs=1
                ;;

            *)
                severity="WARNING"
                classification="SAB_WARNING"
                notify_runs=2
                ;;
        esac

        if grep -Eqi \
            'disk.*full|too little disk|no space left|permission denied|authentication failed|login failed|all servers.*unavailable' \
            <<<"$warning_text"
        then
            severity="ERROR"
            notify_runs=1
        fi

        issue_hash=$(stable_issue_hash "${warning_type}|${warning_origin}|${warning_text}")

        record_normalized_issue \
            "SABnzbd:warning:${issue_hash}" \
            "SABnzbd" \
            "SAB warning: ${warning_origin}" \
            "$classification" \
            "$severity" \
            "active" \
            "$warning_text" \
            "" \
            "$warning_text" \
            "$notify_runs" \
            0 \
            "$API_FAILURE_ESCALATE_MINUTES"

        ((SAB_NATIVE_WARNING_COUNT++)) || true

    done < <(jq -c '(.warnings // . // [])[]?' "$SAB_WARNINGS" 2>/dev/null)
}

sab_failure_message() {

    local item="$1"

    jq -r '
        [
            (.fail_message // empty),
            (.error // empty),
            (
                .stage_log?
                | ..
                | strings
            )
        ]
        | map(select(. != ""))
        | unique
        | join(" | ")
        | if length > 1500 then .[:1500] + "..." else . end
        ' <<<"$item"
}

classify_sab_failure() {

    local message="${1,,}"

    if grep -Eq 'authentication|authorization|login|username|password.*server' <<<"$message"; then
        echo "SAB_DOWNLOAD_FAILED_SERVER_AUTH"
    elif grep -Eq 'missing articles|not enough repair|repair.*failed|cannot be completed|aborted.*articles' <<<"$message"; then
        echo "SAB_DOWNLOAD_FAILED_MISSING_ARTICLES"
    elif grep -Eq 'encrypted|password required|password protected|wrong password' <<<"$message"; then
        echo "SAB_DOWNLOAD_FAILED_PASSWORD"
    elif grep -Eq 'unpack|extract|unrar|7-zip|7zip' <<<"$message"; then
        echo "SAB_DOWNLOAD_FAILED_UNPACK"
    elif grep -Eq 'disk.*full|no space left|too little disk|insufficient.*space' <<<"$message"; then
        echo "SAB_DOWNLOAD_FAILED_DISK"
    elif grep -Eq 'permission denied|access denied|not permitted|no such file|path.*missing|folder.*missing' <<<"$message"; then
        echo "SAB_DOWNLOAD_FAILED_PATH"
    elif grep -Eq 'script.*failed|post.processing.*failed|exit code|returned.*non.zero' <<<"$message"; then
        echo "SAB_DOWNLOAD_FAILED_SCRIPT"
    else
        echo "SAB_DOWNLOAD_FAILED_UNKNOWN"
    fi
}

sab_failure_action() {

    case "$1" in

        SAB_DOWNLOAD_FAILED_MISSING_ARTICLES)
            echo "Choose another release; the current post cannot be repaired"
            ;;

        SAB_DOWNLOAD_FAILED_PASSWORD)
            echo "Supply the archive password or choose an unencrypted release"
            ;;

        SAB_DOWNLOAD_FAILED_UNPACK)
            echo "Inspect the archive/unpack log and retry only after correcting the archive problem"
            ;;

        SAB_DOWNLOAD_FAILED_DISK)
            echo "Restore free space before retrying the download"
            ;;

        SAB_DOWNLOAD_FAILED_PATH)
            echo "Correct the folder mapping or permissions before retrying"
            ;;

        SAB_DOWNLOAD_FAILED_SERVER_AUTH)
            echo "Correct the affected news-server credentials or connection"
            ;;

        SAB_DOWNLOAD_FAILED_SCRIPT)
            echo "Inspect the configured post-processing script and its exit output"
            ;;

        *)
            echo "Inspect the SAB job details and choose whether to retry or select another release"
            ;;
    esac
}

sab_correlated_title() {

    local owner="$1"
    local download_id="$2"
    local fallback="$3"
    local queue_item

    queue_item=$(arr_queue_item_by_download_id "$owner" "$download_id")

    if jq -e 'length > 0' <<<"$queue_item" >/dev/null 2>&1; then
        friendly_media_name "$owner" "$queue_item"
    else
        printf '%s' "$fallback"
    fi
}

process_sab_failed_jobs() {

    [ "$SAB_HISTORY_OK" = true ] || return 0
    [ -f "$SAB_HISTORY" ] || return 0

    while IFS= read -r item; do

        [ -n "$item" ] || continue

        local category
        local owner
        local download_id
        local name
        local event_epoch
        local age
        local message
        local classification
        local title
        local detail
        local queue_item
        local action

        category=$(jq -r '.category // .cat // ""' <<<"$item")

        if [ "${category,,}" = "${SAB_IGNORED_CATEGORY,,}" ]; then
            continue
        fi

        owner=$(sab_category_owner "$category")
        [ -n "$owner" ] || continue

        event_epoch=$(sab_history_event_epoch "$item")
        (( event_epoch > 0 )) || continue

        age=$(( ($(date +%s) - event_epoch) / 3600 ))
        (( age >= 0 )) || age=0
        (( age <= SAB_FAILED_ACTIVE_HOURS )) || continue

        download_id=$(jq -r '.nzo_id // ""' <<<"$item")
        name=$(jq -r '.name // .nzb_name // "Unknown SAB job"' <<<"$item")
        message=$(sab_failure_message "$item")
        [ -n "$message" ] || message="SABnzbd marked the job as failed without a failure message"

        classification=$(classify_sab_failure "$message")
        action=$(sab_failure_action "$classification")
        title=$(sab_correlated_title "$owner" "$download_id" "$name")
        queue_item=$(arr_queue_item_by_download_id "$owner" "$download_id")

        detail="Owner: ${owner}"$'\n'
        detail+="Release: ${name}"$'\n'
        detail+="Failure: ${message}"$'\n'
        detail+="Suggested action: ${action}"

        if jq -e 'length > 0' <<<"$queue_item" >/dev/null 2>&1; then
            detail+=$'\n'
            detail+="Arr queue: $(jq -r '
                "status=" + (.status // "unknown")
                + ", tracked="
                + (.trackedDownloadStatus // "unknown")
                + "/"
                + (.trackedDownloadState // "unknown")
                ' <<<"$queue_item")"
        fi

        mark_sab_primary_download "$download_id"

        record_normalized_issue \
            "SABnzbd:history:${download_id:-$(stable_issue_hash "${category}|${name}|${event_epoch}")}" \
            "SABnzbd" \
            "$title" \
            "$classification" \
            "ERROR" \
            "failed" \
            "$message" \
            "$age" \
            "$detail" \
            1 \
            0 \
            "$API_FAILURE_ESCALATE_MINUTES"

        ((SAB_FAILED_JOB_COUNT++)) || true

    done < <(
        jq -c '
            .history.slots[]?
            | select((.status // "" | ascii_downcase) == "failed")
            ' "$SAB_HISTORY"
    )
}

sab_stage_threshold() {

    local source_kind="$1"
    local status="${2,,}"

    case "${source_kind}:${status}" in

        queue:downloading)
            echo "$SAB_DOWNLOAD_STALL_MINUTES"
            ;;

        queue:fetching|queue:propagating)
            echo "$SAB_FETCH_STALL_MINUTES"
            ;;

        history:quickcheck|history:verifying)
            echo "$SAB_VERIFY_STALL_MINUTES"
            ;;

        history:repairing|history:fetching)
            echo "$SAB_REPAIR_STALL_MINUTES"
            ;;

        history:extracting)
            echo "$SAB_EXTRACT_STALL_MINUTES"
            ;;

        history:moving)
            echo "$SAB_MOVE_STALL_MINUTES"
            ;;

        history:running)
            echo "$SAB_SCRIPT_STALL_MINUTES"
            ;;

        history:queued)
            echo "$SAB_POSTPROCESS_WAIT_MINUTES"
            ;;

        *)
            echo 0
            ;;
    esac
}

observe_sab_progress() {

    local source_kind="$1"
    local owner="$2"
    local category="$3"
    local download_id="$4"
    local name="$5"
    local status="$6"
    local remaining="$7"

    [ -n "$download_id" ] || return 0

    local progress_signature

    progress_signature="${status,,}|${remaining}"
    printf '%s\n' "$download_id" >>"$SAB_PROGRESS_SEEN_FILE"

    jq -nc \
        --arg id "$download_id" \
        --arg signature "$progress_signature" \
        --arg status "$status" \
        --arg sourceKind "$source_kind" \
        --arg owner "$owner" \
        --arg name "$name" \
        --arg category "$category" \
        --arg remaining "$remaining" \
        '{
            id: $id,
            signature: $signature,
            status: $status,
            sourceKind: $sourceKind,
            owner: $owner,
            name: $name,
            category: $category,
            remaining: $remaining
        }' >>"$SAB_PROGRESS_OBSERVATIONS_FILE"
}

evaluate_sab_progress() {

    [ -s "$SAB_PROGRESS_OBSERVATIONS_FILE" ] || return 0

    local now
    local observations_array
    local tmp

    now=$(date +%s)
    observations_array="${TMP_DIR}/sab_progress_observations.json"
    tmp="${TMP_DIR}/state.sab-progress.json"

    jq -s '.' "$SAB_PROGRESS_OBSERVATIONS_FILE" >"$observations_array" || return 1

    jq \
        --slurpfile observations "$observations_array" \
        --argjson now "$now" \
        '
        reduce ($observations[0][]?) as $item (
            .;
            (.sabProgress[$item.id] // {}) as $old
            | .sabProgress[$item.id] = {
                signature: $item.signature,
                status: $item.status,
                sourceKind: $item.sourceKind,
                name: $item.name,
                category: $item.category,
                remaining: $item.remaining,
                lastSeen: $now,
                lastProgressAt: (
                    if ($old.signature // "") == $item.signature
                    then ($old.lastProgressAt // $now)
                    else $now
                    end
                )
            }
        )
        ' "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp" || return 1

    while IFS= read -r observation; do

        [ -n "$observation" ] || continue

        local source_kind
        local owner
        local download_id
        local name
        local status
        local remaining
        local last_progress
        local elapsed_minutes
        local threshold
        local stage
        local severity
        local classification
        local title
        local detail

        source_kind=$(jq -r '.sourceKind' <<<"$observation")
        owner=$(jq -r '.owner' <<<"$observation")
        download_id=$(jq -r '.id' <<<"$observation")
        name=$(jq -r '.name' <<<"$observation")
        status=$(jq -r '.status' <<<"$observation")
        remaining=$(jq -r '.remaining' <<<"$observation")

        last_progress=$(jq -r \
            --arg id "$download_id" \
            '.sabProgress[$id].lastProgressAt // 0' \
            "$STATE_FILE")

        elapsed_minutes=$(( (now - last_progress) / 60 ))
        threshold=$(sab_stage_threshold "$source_kind" "$status")

        (( threshold > 0 && elapsed_minutes >= threshold )) || continue

        stage="warning"
        severity="WARNING"

        if (( elapsed_minutes >= threshold * 4 )); then
            stage="escalated"
            severity="ERROR"
        fi

        classification="SAB_STALLED_$(printf '%s' "$status" | tr '[:lower:] -' '[:upper:]__')"
        title=$(sab_correlated_title "$owner" "$download_id" "$name")
        detail="Owner: ${owner}"$'\n'
        detail+="SAB stage: ${status}"$'\n'
        detail+="No progress: ${elapsed_minutes} minute(s)"

        if [ -n "$remaining" ]; then
            detail+=$'\n'
            detail+="Remaining: ${remaining} MB"
        fi

        mark_sab_primary_download "$download_id"

        record_normalized_issue \
            "SABnzbd:${source_kind}:stalled:${download_id}" \
            "SABnzbd" \
            "$title" \
            "$classification" \
            "$severity" \
            "$stage" \
            "${status} has made no observable progress for ${elapsed_minutes} minutes" \
            "$(( (elapsed_minutes + 59) / 60 ))" \
            "$detail" \
            1 \
            0 \
            0

        ((SAB_STALLED_JOB_COUNT++)) || true

    done <"$SAB_PROGRESS_OBSERVATIONS_FILE"
}

process_sab_live_progress() {

    if [ "$SAB_QUEUE_OK" = true ] && [ -f "$SAB_QUEUE" ]; then

        while IFS= read -r item; do

            [ -n "$item" ] || continue

            local category
            local owner
            local download_id
            local name
            local status
            local remaining

            category=$(jq -r '.cat // .category // ""' <<<"$item")

            if [ "${category,,}" = "${SAB_IGNORED_CATEGORY,,}" ]; then
                continue
            fi

            owner=$(sab_category_owner "$category")
            [ -n "$owner" ] || continue

            download_id=$(jq -r '.nzo_id // ""' <<<"$item")
            name=$(jq -r '.filename // .name // .nzb_name // "Unknown SAB job"' <<<"$item")
            status=$(jq -r '.status // ""' <<<"$item")
            remaining=$(jq -r '.mbleft // .sizeleft // ""' <<<"$item")

            observe_sab_progress \
                "queue" \
                "$owner" \
                "$category" \
                "$download_id" \
                "$name" \
                "$status" \
                "$remaining"

        done < <(jq -c '.queue.slots[]?' "$SAB_QUEUE")
    fi

    if [ "$SAB_HISTORY_OK" = true ] && [ -f "$SAB_HISTORY" ]; then

        while IFS= read -r item; do

            [ -n "$item" ] || continue

            local category
            local owner
            local download_id
            local name
            local status

            category=$(jq -r '.category // .cat // ""' <<<"$item")

            if [ "${category,,}" = "${SAB_IGNORED_CATEGORY,,}" ]; then
                continue
            fi

            owner=$(sab_category_owner "$category")
            [ -n "$owner" ] || continue

            download_id=$(jq -r '.nzo_id // ""' <<<"$item")
            name=$(jq -r '.name // .nzb_name // "Unknown SAB job"' <<<"$item")
            status=$(jq -r '.status // ""' <<<"$item")

            observe_sab_progress \
                "history" \
                "$owner" \
                "$category" \
                "$download_id" \
                "$name" \
                "$status" \
                ""

        done < <(
            jq -c '
                .history.slots[]?
                | select(
                    ((.status // "") | ascii_downcase)
                    | IN(
                        "quickcheck",
                        "verifying",
                        "repairing",
                        "fetching",
                        "extracting",
                        "moving",
                        "running",
                        "queued"
                    )
                )
                ' "$SAB_HISTORY"
        )
    fi
}

sab_pause_allowed_now() {

    local now_hour
    local now_minute
    local now_total
    local window

    now_hour=$(date '+%H')
    now_minute=$(date '+%M')
    now_total=$(( 10#$now_hour * 60 + 10#$now_minute ))

    for window in "${SAB_ALLOWED_PAUSE_WINDOWS[@]}"; do

        [[ "$window" =~ ^([0-2][0-9]):([0-5][0-9])-([0-2][0-9]):([0-5][0-9])$ ]] || continue

        local start_total
        local end_total

        if (( 10#${BASH_REMATCH[1]} > 23 || 10#${BASH_REMATCH[3]} > 23 )); then
            continue
        fi

        start_total=$(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} ))
        end_total=$(( 10#${BASH_REMATCH[3]} * 60 + 10#${BASH_REMATCH[4]} ))

        if (( start_total <= end_total )); then

            if (( now_total >= start_total && now_total <= end_total )); then
                return 0
            fi

        elif (( now_total >= start_total || now_total <= end_total )); then

            return 0
        fi
    done

    return 1
}

process_sab_queue_health() {

    [ "$SAB_QUEUE_OK" = true ] || return 0
    [ -f "$SAB_QUEUE" ] || return 0

    local monitored_count
    local paused
    local pause_reason=""
    local minimum_minutes
    local severity
    local classification

    monitored_count=$(jq \
        --arg movie "${SAB_MOVIE_CATEGORY,,}" \
        --arg tv "${SAB_TV_CATEGORY,,}" \
        '[
            .queue.slots[]?
            | select(
                ((.cat // .category // "") | ascii_downcase) == $movie
                or
                ((.cat // .category // "") | ascii_downcase) == $tv
            )
        ] | length' "$SAB_QUEUE")

    paused=$(jq -r '.queue.paused // .paused // false' "$SAB_QUEUE")

    if [ "$SAB_STATUS_OK" = true ] && [ -f "$SAB_STATUS" ]; then

        paused=$(jq -r \
            --argjson fallback "$paused" \
            '.status.paused // .paused // $fallback' \
            "$SAB_STATUS")

        pause_reason=$(jq -r \
            '.status.pause_reason // .pause_reason // ""' \
            "$SAB_STATUS")
    fi

    if [ "$paused" = true ] && (( monitored_count > 0 )); then

        minimum_minutes="$SAB_PAUSE_WARN_MINUTES"
        severity="WARNING"
        classification="SAB_QUEUE_PAUSED"

        if grep -Eqi 'disk|space|quota' <<<"$pause_reason" ||
           jq -e '
                (
                    .queue.have_quota == true
                    and
                    ((.queue.left_quota | tonumber?) // 1) <= 0
                )
                or
                (((.queue.diskspace1 | tonumber?) // 1) <= 0)
                or
                (((.queue.diskspace2 | tonumber?) // 1) <= 0)
                ' "$SAB_QUEUE" >/dev/null 2>&1 ||
           jq -e '
                .warnings[]?
                | select(
                    (.text // .message // "")
                    | test("disk|space|quota"; "i")
                )
                ' "$SAB_WARNINGS" >/dev/null 2>&1
        then
            minimum_minutes=0
            severity="ERROR"
            classification="SAB_QUEUE_PAUSED_STORAGE"
        fi

        if [ "$classification" = "SAB_QUEUE_PAUSED" ] && sab_pause_allowed_now; then

            log "SABnzbd queue pause is inside an allowed pause window"

        else

            [ -n "$pause_reason" ] || pause_reason="SABnzbd queue is paused with monitored jobs waiting"

            record_normalized_issue \
                "SABnzbd:queue:global-pause" \
                "SABnzbd" \
                "SABnzbd queue paused" \
                "$classification" \
                "$severity" \
                "paused" \
                "$pause_reason" \
                "" \
                "${pause_reason}; monitored jobs: ${monitored_count}" \
                1 \
                "$minimum_minutes" \
                "$API_FAILURE_ESCALATE_MINUTES"

            ((SAB_PAUSED_COUNT++)) || true
        fi
    fi

    if [ "$SAB_STATUS_OK" = true ] &&
       jq -e '
            [.status.servers[]? | select(.serveractive == true)] as $active
            | ($active | length) > 0
            and
            all($active[]; (.servererror // "") != "")
            ' "$SAB_STATUS" >/dev/null 2>&1
    then

        local server_errors

        server_errors=$(jq -r '
            [
                .status.servers[]?
                | select(
                    .serveractive == true
                    and
                    (.servererror // "") != ""
                )
                | (.servername // "Unknown server")
                  + ": "
                  + .servererror
            ]
            | join(" | ")
            ' "$SAB_STATUS")

        record_normalized_issue \
            "SABnzbd:status:all-servers-unavailable" \
            "SABnzbd" \
            "All SAB news servers unavailable" \
            "SAB_ALL_SERVERS_UNAVAILABLE" \
            "ERROR" \
            "active" \
            "$server_errors" \
            "" \
            "$server_errors" \
            1 \
            0 \
            "$API_FAILURE_ESCALATE_MINUTES"
    fi

    [ "$SAB_MONITOR_UNKNOWN_CATEGORIES" = true ] || return 0

    while IFS= read -r item; do

        [ -n "$item" ] || continue

        local category
        local download_id
        local name
        local issue_hash

        category=$(jq -r '.cat // .category // ""' <<<"$item")

        if [ "${category,,}" = "${SAB_MOVIE_CATEGORY,,}" ] ||
           [ "${category,,}" = "${SAB_TV_CATEGORY,,}" ] ||
           [ "${category,,}" = "${SAB_IGNORED_CATEGORY,,}" ]
        then
            continue
        fi

        download_id=$(jq -r '.nzo_id // ""' <<<"$item")
        name=$(jq -r '.filename // .name // "Unknown SAB job"' <<<"$item")
        issue_hash="${download_id:-$(stable_issue_hash "${category}|${name}")}"

        record_normalized_issue \
            "SABnzbd:category:${issue_hash}" \
            "SABnzbd" \
            "$name" \
            "SAB_CATEGORY_UNKNOWN" \
            "WARNING" \
            "active" \
            "Unexpected SAB category: ${category:-default}" \
            "" \
            "Category: ${category:-default}" \
            2 \
            0 \
            0

        ((SAB_UNKNOWN_CATEGORY_COUNT++)) || true

    done < <(jq -c '.queue.slots[]?' "$SAB_QUEUE")
}

prune_sab_progress_state() {

    if [ "$SAB_QUEUE_OK" != true ] || [ "$SAB_HISTORY_OK" != true ]; then
        return 0
    fi

    local ids_file="${TMP_DIR}/sab_progress_ids.json"
    local tmp="${TMP_DIR}/state.sab-progress-pruned.json"

    jq -R -s '
        split("\n")
        | map(select(length > 0))
        | unique
        ' "$SAB_PROGRESS_SEEN_FILE" >"$ids_file" || return 1

    jq \
        --slurpfile ids "$ids_file" \
        '
        ($ids[0] // []) as $activeIds
        | .sabProgress = (
            (.sabProgress // {})
            | with_entries(
                select(.key as $key | $activeIds | index($key))
            )
        )
        ' "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp"
}

###############################################################################
# SAB PATH RESOLUTION
###############################################################################

resolve_sab_path() {

    local item="$1"
    local root="$2"

    local storage
    local name
    local base
    local candidate

    storage=$(
        echo "$item" |
        jq -r '.storage // .path // ""'
    )

    name=$(
        echo "$item" |
        jq -r '.name // .nzb_name // ""'
    )

    #
    # SAB returned host-visible path.
    #

    if [ -n "$storage" ] &&
       [ -e "$storage" ]
    then

        printf '%s' "$storage"

        return 0
    fi

    #
    # Container-side path:
    # try basename underneath category's host directory.
    #

    if [ -n "$storage" ]; then

        base=$(basename "${storage%/}")

        if [ -n "$base" ] &&
           [ "$base" != "/" ]
        then

            candidate="${root}/${base}"

            if [ -e "$candidate" ]; then

                printf '%s' "$candidate"

                return 0
            fi
        fi
    fi

    #
    # Fallback from SAB job name.
    #

    if [ -n "$name" ]; then

        candidate="${root}/${name}"

        if [ -e "$candidate" ]; then

            printf '%s' "$candidate"

            return 0
        fi
    fi

    return 1
}

###############################################################################
# SAB LEFTOVER ANALYSIS - v2.2
#
# Inspect what actually remains inside a completed SAB download.
#
# Categories:
#
#   media
#       Real movie/episode files
#
#   sample
#       Sample/trailer media files
#
#   archive
#       RAR/7z/ZIP/multipart payload
#
#   repair
#       PAR2/SFV repair/check files
#
#   metadata
#       NFO/subtitles/images/text metadata
#
#   other
#       Anything not classified above
#
###############################################################################

analyze_sab_path() {

    local path="$1"

    local total_files=0
    local total_bytes=0

    local media_files=0
    local media_bytes=0

    local sample_files=0
    local sample_bytes=0

    local archive_files=0
    local archive_bytes=0

    local repair_files=0
    local repair_bytes=0

    local metadata_files=0
    local metadata_bytes=0

    local other_files=0
    local other_bytes=0

    local file
    local size
    local lower
    local base

    ###########################################################################
    # FILE ITERATOR
    ###########################################################################

    while IFS= read -r -d '' file; do

        size=$(stat -c '%s' "$file" 2>/dev/null || echo 0)

        if ! [[ "$size" =~ ^[0-9]+$ ]]; then
            size=0
        fi

        lower="${file,,}"
        base="${lower##*/}"

        ((total_files++)) || true
        ((total_bytes += size)) || true

        #######################################################################
        # SAMPLE / TRAILER MEDIA
        #
        # Check this BEFORE normal media classification.
        #######################################################################

        if [[ "$base" =~ (^|[._\ -])(sample|trailer)([._\ -]|$) ]] &&
           [[ "$base" =~ \.(mkv|mp4|m4v|avi|mov|ts)$ ]]
        then

            ((sample_files++)) || true
            ((sample_bytes += size)) || true

            continue
        fi

        #######################################################################
        # REAL MEDIA
        #######################################################################

        case "$base" in

            *.mkv|*.mp4|*.m4v|*.avi|*.mov|*.ts)

                ((media_files++)) || true
                ((media_bytes += size)) || true

                continue
                ;;
        esac

        #######################################################################
        # ARCHIVES
        #######################################################################

        case "$base" in

            *.rar|\
            *.r[0-9][0-9]|\
            *.7z|\
            *.zip|\
            *.[0-9][0-9][0-9])

                ((archive_files++)) || true
                ((archive_bytes += size)) || true

                continue
                ;;
        esac

        #######################################################################
        # REPAIR / VERIFICATION FILES
        #######################################################################

        case "$base" in

            *.par2|\
            *.sfv|\
            *.md5|\
            *.sha1|\
            *.sha256)

                ((repair_files++)) || true
                ((repair_bytes += size)) || true

                continue
                ;;
        esac

        #######################################################################
        # METADATA / SUBTITLES / IMAGES
        #######################################################################

        case "$base" in

            *.nfo|\
            *.srt|\
            *.ass|\
            *.ssa|\
            *.sub|\
            *.idx|\
            *.vtt|\
            *.jpg|\
            *.jpeg|\
            *.png|\
            *.webp|\
            *.txt|\
            *.xml|\
            *.json)

                ((metadata_files++)) || true
                ((metadata_bytes += size)) || true

                continue
                ;;
        esac

        #######################################################################
        # UNKNOWN
        #######################################################################

        ((other_files++)) || true
        ((other_bytes += size)) || true

    done < <(

        if [ -f "$path" ]; then

            printf '%s\0' "$path"

        elif [ -d "$path" ]; then

            find "$path" \
                -type f \
                -print0 2>/dev/null

        fi
    )

    ###########################################################################
    # RETURN JSON
    #######################################################################

    jq -nc \
        --argjson totalFiles "$total_files" \
        --argjson totalBytes "$total_bytes" \
        --argjson mediaFiles "$media_files" \
        --argjson mediaBytes "$media_bytes" \
        --argjson sampleFiles "$sample_files" \
        --argjson sampleBytes "$sample_bytes" \
        --argjson archiveFiles "$archive_files" \
        --argjson archiveBytes "$archive_bytes" \
        --argjson repairFiles "$repair_files" \
        --argjson repairBytes "$repair_bytes" \
        --argjson metadataFiles "$metadata_files" \
        --argjson metadataBytes "$metadata_bytes" \
        --argjson otherFiles "$other_files" \
        --argjson otherBytes "$other_bytes" \
        '{
            totalFiles: $totalFiles,
            totalBytes: $totalBytes,

            mediaFiles: $mediaFiles,
            mediaBytes: $mediaBytes,

            sampleFiles: $sampleFiles,
            sampleBytes: $sampleBytes,

            archiveFiles: $archiveFiles,
            archiveBytes: $archiveBytes,

            repairFiles: $repairFiles,
            repairBytes: $repairBytes,

            metadataFiles: $metadataFiles,
            metadataBytes: $metadataBytes,

            otherFiles: $otherFiles,
            otherBytes: $otherBytes
        }'
}

###############################################################################
# CLASSIFY SAB LEFTOVER
###############################################################################

classify_sab_leftover() {

    local stats="$1"

    local media
    local archive
    local sample
    local repair
    local metadata
    local other
    local other_bytes

    media=$(echo "$stats" | jq -r '.mediaFiles')
    archive=$(echo "$stats" | jq -r '.archiveFiles')
    sample=$(echo "$stats" | jq -r '.sampleFiles')
    repair=$(echo "$stats" | jq -r '.repairFiles')
    metadata=$(echo "$stats" | jq -r '.metadataFiles')
    other=$(echo "$stats" | jq -r '.otherFiles')
    other_bytes=$(echo "$stats" | jq -r '.otherBytes')

    ###########################################################################
    # HIGH CONFIDENCE: ACTUAL MEDIA REMAINS
    ###########################################################################

    if (( media > 0 )); then

        echo "SAB_STRANDED_MEDIA"

        return
    fi

    ###########################################################################
    # HIGH CONFIDENCE: UNEXTRACTED / LEFTOVER ARCHIVE PAYLOAD
    ###########################################################################

    if (( archive > 0 )); then

        echo "SAB_STRANDED_ARCHIVE"

        return
    fi

    ###########################################################################
    # UNKNOWN BUT MATERIAL AMOUNT OF DATA
    ###########################################################################

    if (( other > 0 )) &&
       (( other_bytes >= SAB_SIGNIFICANT_OTHER_BYTES ))
    then

        echo "SAB_STRANDED_OTHER"

        return
    fi

    ###########################################################################
    # SAMPLE ONLY
    ###########################################################################

    if (( sample > 0 )) &&
       (( repair == 0 )) &&
       (( metadata == 0 )) &&
       (( other == 0 ))
    then

        echo "SAB_RESIDUE_SAMPLE"

        return
    fi

    ###########################################################################
    # EVERYTHING ELSE IS LOW-VALUE RESIDUE
    ###########################################################################

    echo "SAB_RESIDUE"
}

###############################################################################
# SAB STRANDED THRESHOLD BY TYPE
###############################################################################

sab_warning_threshold() {

    case "$1" in

        SAB_STRANDED_MEDIA)

            echo "$SAB_MEDIA_WARN_HOURS"
            ;;

        SAB_STRANDED_ARCHIVE)

            echo "$SAB_ARCHIVE_WARN_HOURS"
            ;;

        SAB_STRANDED_OTHER)

            echo "$SAB_OTHER_WARN_HOURS"
            ;;

        *)

            echo 999999
            ;;
    esac
}

###############################################################################
# HUMAN DESCRIPTION
###############################################################################

sab_leftover_reason() {

    case "$1" in

        SAB_STRANDED_MEDIA)

            echo "Completed media file(s) remain on disk but the expected Arr application no longer tracks the download."
            ;;

        SAB_STRANDED_ARCHIVE)

            echo "Archive payload remains after SAB completion and the expected Arr application no longer tracks the download."
            ;;

        SAB_STRANDED_OTHER)

            echo "A significant amount of unclassified data remains after SAB completion and the expected Arr application no longer tracks the download."
            ;;

        SAB_RESIDUE_SAMPLE)

            echo "Only sample/trailer media remains. Treated as cleanup residue."
            ;;

        SAB_RESIDUE)

            echo "Only low-priority repair, metadata, subtitle, or small miscellaneous files remain."
            ;;

        *)

            echo "Unknown SAB leftover condition"
            ;;
    esac
}

###############################################################################
# PROCESS SAB CROSS-APP ISSUES - v2.2
###############################################################################

process_sab_orphans() {

    [ "$SAB_ENABLED" = true ] || return
    [ "$SAB_SCAN_OK" = true ] || return
    [ -n "$SAB_HISTORY" ] || return
    [ -f "$SAB_HISTORY" ] || return

    log "Checking SABnzbd completed jobs for stranded downloads"

    if ! jq -e '(.history.slots // [] | length) > 0' "$SAB_HISTORY" >/dev/null 2>&1; then
        log "SABnzbd history contains no jobs"
        return
    fi

    while IFS= read -r item; do

        [ -n "$item" ] || continue

        local status
        local category
        local nzo_id
        local name

        status=$(echo "$item" | jq -r '.status // ""')
        category=$(echo "$item" | jq -r '.category // .cat // ""')
        nzo_id=$(echo "$item" | jq -r '.nzo_id // ""')
        name=$(echo "$item" | jq -r '.name // .nzb_name // "Unknown"')

        #######################################################################
        # ONLY COMPLETED JOBS
        #######################################################################

        [ "${status,,}" = "completed" ] || continue

        ((SAB_HISTORY_CHECKED++)) || true

        #######################################################################
        # IGNORE F1
        #######################################################################

        if [ "${category,,}" = "${SAB_IGNORED_CATEGORY,,}" ]; then

            ((SAB_IGNORED_COUNT++)) || true

            continue
        fi

        #######################################################################
        # EXPECTED ARR OWNER
        #######################################################################

        local owner
        local root

        owner=$(sab_category_owner "$category")

        [ -n "$owner" ] || continue

        root=$(sab_category_root "$category")

        #######################################################################
        # REQUIRE HEALTHY ARR SCAN
        #######################################################################

        case "$owner" in

            Sonarr)

                if [ "$SONARR_SCAN_OK" != true ]; then

                    log "Skipping SAB orphan check for '$name': Sonarr scan unavailable"

                    continue
                fi
                ;;

            Radarr)

                if [ "$RADARR_SCAN_OK" != true ]; then

                    log "Skipping SAB orphan check for '$name': Radarr scan unavailable"

                    continue
                fi
                ;;
        esac

        #######################################################################
        # COMPLETION AGE
        #######################################################################

        local completed_epoch
        local now
        local age

        completed_epoch=$(sab_completed_epoch "$item")
        now=$(date +%s)

        if (( completed_epoch <= 0 )); then

            log "WARNING: Unable to determine SAB completion time: $name"

            continue
        fi

        age=$(( (now - completed_epoch) / 3600 ))

        (( age >= 0 )) || age=0

        if (( age < SAB_ORPHAN_IGNORE_HOURS )); then
            continue
        fi

        #######################################################################
        # ARR STILL TRACKING DOWNLOAD
        #######################################################################

        if [ -n "$nzo_id" ] &&
           arr_tracks_download "$owner" "$nzo_id"
        then

            continue
        fi

        #######################################################################
        # RESOLVE COMPLETED PATH
        #######################################################################

        local completed_path=""

        completed_path=$(
            resolve_sab_path "$item" "$root" || true
        )

        #
        # Nothing remains on disk.
        #
        # This is normally a successful Arr import.
        #

        if [ -z "$completed_path" ] ||
           [ ! -e "$completed_path" ]
        then

            continue
        fi

        #######################################################################
        # ANALYZE REMAINING CONTENT
        #######################################################################

        local stats

        stats=$(analyze_sab_path "$completed_path")

        local total_files
        local total_bytes

        local media_files
        local media_bytes

        local sample_files
        local archive_files
        local repair_files
        local metadata_files

        local other_files
        local other_bytes

        total_files=$(echo "$stats" | jq -r '.totalFiles')
        total_bytes=$(echo "$stats" | jq -r '.totalBytes')

        media_files=$(echo "$stats" | jq -r '.mediaFiles')
        media_bytes=$(echo "$stats" | jq -r '.mediaBytes')

        sample_files=$(echo "$stats" | jq -r '.sampleFiles')
        archive_files=$(echo "$stats" | jq -r '.archiveFiles')
        repair_files=$(echo "$stats" | jq -r '.repairFiles')
        metadata_files=$(echo "$stats" | jq -r '.metadataFiles')

        other_files=$(echo "$stats" | jq -r '.otherFiles')
        other_bytes=$(echo "$stats" | jq -r '.otherBytes')

        #######################################################################
        # EMPTY
        #######################################################################

        if (( total_files == 0 )); then

            ((SAB_EMPTY_COUNT++)) || true

            log "------------------------------------------------------------"
            log "SAB empty leftover"
            log "Expected owner: $owner"
            log "Category: $category"
            log "Release: $name"
            log "Age: ${age}h"
            log "Path: $completed_path"
            log "Action: log only"

            continue
        fi

        #######################################################################
        # CLASSIFY REMAINING DATA
        #######################################################################

        local classification
        local reason

        classification=$(classify_sab_leftover "$stats")
        reason=$(sab_leftover_reason "$classification")

        #######################################################################
        # LOW-PRIORITY RESIDUE
        #######################################################################

        case "$classification" in

            SAB_RESIDUE_SAMPLE)

                ((SAB_SAMPLE_RESIDUE_COUNT++)) || true
                ((SAB_RESIDUE_COUNT++)) || true

                log "------------------------------------------------------------"
                log "SAB sample residue"
                log "Expected owner: $owner"
                log "Category: $category"
                log "Release: $name"
                log "Age: ${age}h"
                log "Path: $completed_path"
                log "Samples: $sample_files"
                log "Remaining size: $(bytes_human "$total_bytes")"
                log "Action: log only"

                continue
                ;;

            SAB_RESIDUE)

                ((SAB_RESIDUE_COUNT++)) || true

                log "------------------------------------------------------------"
                log "SAB cleanup residue"
                log "Expected owner: $owner"
                log "Category: $category"
                log "Release: $name"
                log "Age: ${age}h"
                log "Path: $completed_path"
                log "Repair files: $repair_files"
                log "Metadata files: $metadata_files"
                log "Other files: $other_files"
                log "Remaining size: $(bytes_human "$total_bytes")"
                log "Action: log only"

                continue
                ;;
        esac

        #######################################################################
        # ACTIONABLE STRANDED DATA
        #######################################################################

        local warn_after
        local severity="INFO"
        local stage="candidate"

        warn_after=$(sab_warning_threshold "$classification")

        if (( age >= SAB_ORPHAN_ESCALATE_HOURS )); then

            severity="WARNING"
            stage="escalated"

        elif (( age >= warn_after )); then

            severity="WARNING"
            stage="warning"
        fi

        ((SAB_STRANDED_COUNT++)) || true

        case "$classification" in

            SAB_STRANDED_MEDIA)
                ((SAB_MEDIA_STRANDED_COUNT++)) || true
                ;;

            SAB_STRANDED_ARCHIVE)
                ((SAB_ARCHIVE_STRANDED_COUNT++)) || true
                ;;

            SAB_STRANDED_OTHER)
                ((SAB_OTHER_STRANDED_COUNT++)) || true
                ;;
        esac

        if [ "$stage" = "candidate" ]; then
            ((SAB_CANDIDATE_COUNT++)) || true
        fi

        ((TOTAL_ISSUES++)) || true

        case "$severity" in

            INFO)
                ((INFO_COUNT++)) || true
                ;;

            WARNING)
                ((WARNING_COUNT++)) || true
                ;;
        esac

        #######################################################################
        # LOG
        #######################################################################

        log "------------------------------------------------------------"
        log "SAB stranded download detected"
        log "Expected owner: $owner"
        log "Category: $category"
        log "Release: $name"
        log "Classification: $classification"
        log "Severity: $severity"
        log "Stage: $stage"
        log "Reason: $reason"
        log "SAB status: $status"
        log "Completed age: ${age}h"
        log "$owner queue: Not found"

        [ -n "$nzo_id" ] &&
            log "Download ID: $nzo_id"

        log "Completed path: $completed_path"

        log "Total files: $total_files"
        log "Total size: $(bytes_human "$total_bytes")"

        log "Media files: $media_files ($(bytes_human "$media_bytes"))"
        log "Archive files: $archive_files"
        log "Sample files: $sample_files"
        log "Repair files: $repair_files"
        log "Metadata files: $metadata_files"
        log "Other files: $other_files ($(bytes_human "$other_bytes"))"

        #######################################################################
        # STATE
        #######################################################################

        local issue_key
        local signature
        local message

        if [ -n "$nzo_id" ]; then

            issue_key="SAB:${nzo_id}"

        else

            issue_key="SAB:${category}:${name}"
        fi

        message="${reason}"

        signature=$(
            issue_signature \
                "SABnzbd" \
                "${nzo_id:-${category}:${name}}" \
                "$classification" \
                "$severity" \
                "$stage" \
                "$message"
        )

        local persist_issue_transition=false

        if issue_transition_should_persist \
            "$issue_key" \
            "$signature"
        then
            persist_issue_transition=true
        fi

        update_issue_state \
            "$issue_key" \
            "$signature" \
            "SABnzbd" \
            "$name" \
            "$classification" \
            "$severity" \
            "$stage" \
            "$message"

        if [ "$persist_issue_transition" = true ]; then

            persistent_log \
                "ISSUE" \
                "SABnzbd | ${classification} | ${severity} | ${name} | owner=${owner} | age=${age}h | remaining=$(bytes_human "$total_bytes")"
        fi

        #######################################################################
        # CANDIDATE = LOG ONLY
        #######################################################################

        if [ "$stage" = "candidate" ]; then

            log "Candidate only: $classification notification threshold is ${warn_after}h"

            continue
        fi

        #######################################################################
        # GROUP NOTIFICATION
        #######################################################################

        if should_notify "$issue_key" "$signature"; then

            local sab_detail

            sab_detail="Owner: ${owner}"$'\n'
            sab_detail+="Remaining: $(bytes_human "$total_bytes")"$'\n'

            case "$classification" in

                SAB_STRANDED_MEDIA)

                    sab_detail+="Media: ${media_files} file(s), $(bytes_human "$media_bytes")"
                    ;;

                SAB_STRANDED_ARCHIVE)

                    sab_detail+="Archive files: ${archive_files}"
                    ;;

                SAB_STRANDED_OTHER)

                    sab_detail+="Unknown files: ${other_files}, $(bytes_human "$other_bytes")"
                    ;;
            esac

            queue_group_notification \
                "$issue_key" \
                "$signature" \
                "SABnzbd" \
                "$name" \
                "$classification" \
                "$severity" \
                "$age" \
                "$sab_detail"

        else

            log "Notification suppressed: stranded issue already reported"
        fi

    done < <(jq -c '.history.slots[]?' "$SAB_HISTORY")
}

###############################################################################
# ACTIVITY AUDIT WINDOW - v2.5
###############################################################################

initialize_activity_audit_window() {

    AUDIT_CUTOFF_EPOCH=$(
        date \
            -d "${ACTIVITY_AUDIT_LOOKBACK_HOURS} hours ago" \
            '+%s'
    )

    AUDIT_SINCE_ISO=$(
        date \
            -u \
            -d "@${AUDIT_CUTOFF_EPOCH}" \
            '+%Y-%m-%dT%H:%M:%SZ'
    )
}

###############################################################################
# FETCH RECENT ARR HISTORY - v2.5
###############################################################################

fetch_arr_activity_history() {

    local app="$1"
    local base_url="$2"
    local api_key="$3"
    local output="$4"

    local endpoint

    case "$app" in

        Sonarr)

            endpoint="${base_url%/}/api/v3/history/since?date=${AUDIT_SINCE_ISO}&includeSeries=true&includeEpisode=true"
            ;;

        Radarr)

            endpoint="${base_url%/}/api/v3/history/since?date=${AUDIT_SINCE_ISO}&includeMovie=true"
            ;;

        *)

            return 1
            ;;
    esac

    api_get \
        "$endpoint" \
        "$api_key" \
        "$output"
}

###############################################################################
# PROCESS RECENT ARR ACTIVITY - v2.5
###############################################################################

process_arr_activity_audit() {

    local app="$1"
    local history_file="$2"

    local imported
    local failed

    imported=$(
        jq \
            '[
                .[]?
                | select(
                    .eventType == "downloadFolderImported"
                )
            ]
            | length' \
            "$history_file" 2>/dev/null ||
            echo 0
    )

    failed=$(
        jq \
            '[
                .[]?
                | select(
                    .eventType == "downloadFailed"
                )
            ]
            | length' \
            "$history_file" 2>/dev/null ||
            echo 0
    )

    case "$app" in

        Sonarr)

            SONARR_AUDIT_IMPORTED="$imported"
            SONARR_AUDIT_DOWNLOAD_FAILED="$failed"
            ;;

        Radarr)

            RADARR_AUDIT_IMPORTED="$imported"
            RADARR_AUDIT_DOWNLOAD_FAILED="$failed"
            ;;
    esac

    [ "$AUDIT_SUCCESS_DETAILS" = true ] || return 0
    (( imported > 0 )) || return 0

    log ""
    log "$app recent successful imports"

    if [ "$app" = "Sonarr" ]; then

        jq -r \
            --argjson maximum "$AUDIT_DETAIL_MAX_ITEMS" \
            '
            def pad2:
                tostring
                | if length < 2
                  then "0" + .
                  else .
                  end;

            [
                .[]?
                | select(
                    .eventType == "downloadFolderImported"
                )
            ]

            | sort_by(.date)
            | reverse
            | .[:$maximum]
            | .[]

            |

            if
                (.series.title // "") != ""
                and
                (.episode.seasonNumber // null) != null
                and
                (.episode.episodeNumber // null) != null

            then

                (.series.title)
                + " - S"
                + (.episode.seasonNumber | pad2)
                + "E"
                + (.episode.episodeNumber | pad2)
                +
                (
                    if (.episode.title // "") != ""
                    then " - " + .episode.title
                    else ""
                    end
                )

            else

                (.sourceTitle // "Unknown")

            end
            ' \
            "$history_file" |
        while IFS= read -r item; do

            [ -n "$item" ] &&
                log "  + $item"

        done

    else

        jq -r \
            --argjson maximum "$AUDIT_DETAIL_MAX_ITEMS" \
            '
            [
                .[]?
                | select(
                    .eventType == "downloadFolderImported"
                )
            ]

            | sort_by(.date)
            | reverse
            | .[:$maximum]
            | .[]

            |

            if (.movie.title // "") != ""
            then

                .movie.title
                +
                (
                    if (.movie.year // 0) > 0
                    then " (" + (.movie.year | tostring) + ")"
                    else ""
                    end
                )

            else

                (.sourceTitle // "Unknown")

            end
            ' \
            "$history_file" |
        while IFS= read -r item; do

            [ -n "$item" ] &&
                log "  + $item"

        done
    fi
}

###############################################################################
# PROCESS ARR HISTORY FAILURES - v3.0
#
# Queue state remains the primary detector. History fills the gap when a
# failed download leaves the queue before the next five-minute scan.
###############################################################################

history_media_name() {

    local app="$1"
    local item="$2"

    if [ "$app" = "Sonarr" ]; then

        jq -r '
            def pad2:
                tostring | if length < 2 then "0" + . else . end;

            if (.series.title // "") != "" then
                .series.title
                + (
                    if (.episode.seasonNumber // null) != null
                       and (.episode.episodeNumber // null) != null
                    then
                        " - S"
                        + (.episode.seasonNumber | pad2)
                        + "E"
                        + (.episode.episodeNumber | pad2)
                        + (
                            if (.episode.title // "") != ""
                            then " - " + .episode.title
                            else ""
                            end
                        )
                    else ""
                    end
                )
            else
                (.sourceTitle // "Unknown")
            end
            ' <<<"$item"

    else

        jq -r '
            if (.movie.title // "") != "" then
                .movie.title
                + (
                    if (.movie.year // 0) > 0
                    then " (" + (.movie.year | tostring) + ")"
                    else ""
                    end
                )
            else
                (.sourceTitle // "Unknown")
            end
            ' <<<"$item"
    fi
}

process_arr_history_failures() {

    local app="$1"
    local history_file="$2"

    [ -f "$history_file" ] || return 0

    while IFS= read -r item; do

        [ -n "$item" ] || continue

        local record_id
        local download_id
        local title
        local release
        local date_value
        local age
        local message
        local issue_id

        record_id=$(jq -r '.id // ""' <<<"$item")
        download_id=$(jq -r '.downloadId // .data.downloadId // .data.downloadClientId // ""' <<<"$item")

        if [ -n "$download_id" ] && sab_primary_download_exists "$download_id"; then
            continue
        fi

        if [ -n "$download_id" ] &&
           jq -e \
                --arg id "$download_id" \
                'any(
                    .[]?;
                    .eventType == "downloadFolderImported"
                    and
                    (
                        (.downloadId // .data.downloadId // .data.downloadClientId // "")
                        == $id
                    )
                )' \
                "$history_file" >/dev/null 2>&1
        then
            continue
        fi

        title=$(history_media_name "$app" "$item")
        release=$(jq -r '.sourceTitle // "Unknown release"' <<<"$item")
        date_value=$(jq -r '.date // ""' <<<"$item")
        age=$(age_hours "$date_value")
        message=$(jq -r '
            .data.message
            // .data.reason
            // .data.statusMessage
            // "Arr recorded a failed download"
            ' <<<"$item")

        issue_id="${download_id:-${record_id:-$(stable_issue_hash "${app}|${release}|${date_value}")}}"

        record_normalized_issue \
            "${app}:history:download-failed:${issue_id}" \
            "$app" \
            "$title" \
            "ARR_DOWNLOAD_FAILED_HISTORY" \
            "ERROR" \
            "failed" \
            "$message" \
            "$age" \
            "Release: ${release}"$'\n'"Failure: ${message}" \
            1 \
            0 \
            "$API_FAILURE_ESCALATE_MINUTES"

    done < <(
        jq -c '
            .[]?
            | select(.eventType == "downloadFailed")
            ' "$history_file"
    )
}

###############################################################################
# SAB HISTORY EVENT TIME - v2.5
#
# Reuses the timestamp styles SAB has already exposed to this script.
###############################################################################

sab_history_event_epoch() {

    local item="$1"

    local value

    value=$(
        echo "$item" |
        jq -r '
            .completed
            // .completed_time
            // .completedTime
            // .completionTime
            // .time_completed
            // ""
        '
    )

    date_to_epoch "$value"
}

###############################################################################
# PROCESS RECENT SAB ACTIVITY - v2.5
###############################################################################

process_sab_activity_audit() {

    if [ "$SAB_SCAN_OK" != true ] ||
       [ -z "$SAB_HISTORY" ] ||
       [ ! -f "$SAB_HISTORY" ]
    then

        SAB_AUDIT_OK=false
        return
    fi

    local loaded
    local total_available
    local oldest_epoch=0

    loaded=$(
        jq '.history.slots // [] | length' \
            "$SAB_HISTORY" 2>/dev/null ||
            echo 0
    )

    total_available=$(
        jq '.history.noofslots // (.history.slots // [] | length)' \
            "$SAB_HISTORY" 2>/dev/null ||
            echo "$loaded"
    )

    while IFS= read -r item; do

        [ -n "$item" ] || continue

        local status
        local category
        local event_epoch

        status=$(
            echo "$item" |
                jq -r '.status // ""'
        )

        category=$(
            echo "$item" |
                jq -r '.category // .cat // ""'
        )

        event_epoch=$(sab_history_event_epoch "$item")

        if (( event_epoch <= 0 )); then
            continue
        fi

        if (( oldest_epoch == 0 || event_epoch < oldest_epoch )); then
            oldest_epoch="$event_epoch"
        fi

        if (( event_epoch < AUDIT_CUTOFF_EPOCH )); then
            continue
        fi

        #######################################################################
        # F1 IS AUDIT-IGNORED
        #######################################################################

        if [ "${category,,}" = "${SAB_IGNORED_CATEGORY,,}" ]; then

            ((SAB_AUDIT_F1_IGNORED++)) || true
            continue
        fi

        #######################################################################
        # MOVIES
        #######################################################################

        if [ "${category,,}" = "${SAB_MOVIE_CATEGORY,,}" ]; then

            case "${status,,}" in

                completed)
                    ((SAB_AUDIT_MOVIE_COMPLETED++)) || true
                    ;;

                failed)
                    ((SAB_AUDIT_MOVIE_FAILED++)) || true
                    ;;
            esac

            continue
        fi

        #######################################################################
        # TV
        #######################################################################

        if [ "${category,,}" = "${SAB_TV_CATEGORY,,}" ]; then

            case "${status,,}" in

                completed)
                    ((SAB_AUDIT_TV_COMPLETED++)) || true
                    ;;

                failed)
                    ((SAB_AUDIT_TV_FAILED++)) || true
                    ;;
            esac
        fi

    done < <(
        jq -c '.history.slots[]?' "$SAB_HISTORY"
    )

    ###########################################################################
    # DETECT POSSIBLY TRUNCATED HISTORY
    #
    # If the paginated safety cap was reached and even the oldest loaded record
    # is newer than our requested audit cutoff, relevant records may remain.
    ###########################################################################

    SAB_AUDIT_WINDOW_INCOMPLETE=false

    if (( loaded < total_available )) &&
       (( oldest_epoch > AUDIT_CUTOFF_EPOCH ))
    then

        SAB_AUDIT_WINDOW_INCOMPLETE=true
    fi

    SAB_AUDIT_OK=true
}

###############################################################################
# PIPELINE HEALTH ASSESSMENT - v2.5
#
# Operational evidence only.
#
# This does NOT claim one-to-one verification between SAB jobs and Arr files.
###############################################################################

assess_pipeline_health() {

    if [ "$PIPELINE_HEALTH_ENABLED" != true ]; then

        PIPELINE_STATUS="DISABLED"
        PIPELINE_REASON="Pipeline health assessment disabled"

        return
    fi

    local recent_failure_signals=0
    local recent_activity=0

    recent_failure_signals=$((
        SAB_AUDIT_MOVIE_FAILED
        + SAB_AUDIT_TV_FAILED
        + SONARR_AUDIT_DOWNLOAD_FAILED
        + RADARR_AUDIT_DOWNLOAD_FAILED
    ))

    recent_activity=$((
        SAB_AUDIT_MOVIE_COMPLETED
        + SAB_AUDIT_TV_COMPLETED
        + SONARR_AUDIT_IMPORTED
        + RADARR_AUDIT_IMPORTED
    ))

    ###########################################################################
    # REQUIRED API UNAVAILABLE
    ###########################################################################

    if { [ "$SONARR_ENABLED" = true ] &&
         [ "$SONARR_API_OK" != true ]; } ||
       { [ "$RADARR_ENABLED" = true ] &&
         [ "$RADARR_API_OK" != true ]; } ||
       { [ "$SAB_ENABLED" = true ] &&
         [ "$SAB_API_OK" != true ]; }
    then

        PIPELINE_STATUS="UNAVAILABLE"
        PIPELINE_REASON="One or more required application APIs could not be queried"

        return
    fi

    ###########################################################################
    # ACTIVITY AUDIT COULD NOT COMPLETE
    ###########################################################################

    if [ "$ACTIVITY_AUDIT_ENABLED" = true ]; then

        if { [ "$SONARR_ENABLED" = true ] &&
             [ "$SONARR_AUDIT_OK" != true ]; } ||
           { [ "$RADARR_ENABLED" = true ] &&
             [ "$RADARR_AUDIT_OK" != true ]; } ||
           { [ "$SAB_ENABLED" = true ] &&
             [ "$SAB_AUDIT_OK" != true ]; }
        then

            PIPELINE_STATUS="DEGRADED"
            PIPELINE_REASON="Core APIs are reachable but recent activity audit is incomplete"

            return
        fi
    fi

    ###########################################################################
    # ACTIVE ERROR
    ###########################################################################

    if (( ERROR_COUNT > 0 )); then

        PIPELINE_STATUS="DEGRADED"
        PIPELINE_REASON="${ERROR_COUNT} active error-level issue(s) detected"

        return
    fi

    ###########################################################################
    # ACTIVE WARNING
    ###########################################################################

    if (( WARNING_COUNT > 0 )); then

        PIPELINE_STATUS="ATTENTION"
        PIPELINE_REASON="${WARNING_COUNT} active warning-level issue(s) detected"

        return
    fi

    ###########################################################################
    # RECENT HISTORICAL FAILURE SIGNAL
    ###########################################################################

    if (( recent_failure_signals > 0 )); then

        PIPELINE_STATUS="ATTENTION"
        PIPELINE_REASON="${recent_failure_signals} recent download-failure signal(s) observed within the audit window"

        return
    fi

    ###########################################################################
    # SAB AUDIT WINDOW MAY BE INCOMPLETE
    ###########################################################################

    if [ "$SAB_AUDIT_WINDOW_INCOMPLETE" = true ]; then

        PIPELINE_STATUS="ATTENTION"
        PIPELINE_REASON="SAB history limit was reached before the full audit window could be confirmed"

        return
    fi

    ###########################################################################
    # INFORMATIONAL ACTIVE ISSUES
    ###########################################################################

    if (( INFO_COUNT > 0 )); then

        PIPELINE_STATUS="HEALTHY / INFO"
        PIPELINE_REASON="Pipeline operational with ${INFO_COUNT} informational unresolved issue(s)"

        return
    fi

    ###########################################################################
    # RECENT SUCCESSFUL ACTIVITY
    ###########################################################################

    if (( recent_activity > 0 )); then

        PIPELINE_STATUS="HEALTHY"
        PIPELINE_REASON="APIs healthy, recent successful activity observed, no significant active problems detected"

        return
    fi

    ###########################################################################
    # NOTHING HAPPENED RECENTLY
    ###########################################################################

    PIPELINE_STATUS="HEALTHY / IDLE"
    PIPELINE_REASON="APIs healthy and no significant problems detected; no recent relevant activity available to validate"
}

###############################################################################
# WRITE COMPACT PERSISTENT AUDIT RECORD - v2.5
###############################################################################

write_persistent_activity_summary() {

    persistent_log \
        "API" \
        "Sonarr=${SONARR_API_OK} | Radarr=${RADARR_API_OK} | SABnzbd=${SAB_API_OK}"

    if [ "$ACTIVITY_AUDIT_ENABLED" = true ]; then

        persistent_log \
            "AUDIT" \
            "lookback=${ACTIVITY_AUDIT_LOOKBACK_HOURS}h | SAB movie_completed=${SAB_AUDIT_MOVIE_COMPLETED} tv_completed=${SAB_AUDIT_TV_COMPLETED} failed=$((SAB_AUDIT_MOVIE_FAILED + SAB_AUDIT_TV_FAILED)) | Sonarr imports=${SONARR_AUDIT_IMPORTED} failed=${SONARR_AUDIT_DOWNLOAD_FAILED} | Radarr imports=${RADARR_AUDIT_IMPORTED} failed=${RADARR_AUDIT_DOWNLOAD_FAILED}"
    fi

    if [ "$FLOW_ANOMALY_ENABLED" = true ]; then

        persistent_log \
            "FLOW" \
            "window=${FLOW_ANOMALY_LOOKBACK_HOURS}h | SAB_tv=${FLOW_SAB_TV_COMPLETED} Sonarr_imports=${FLOW_SONARR_IMPORTS} | SAB_movie=${FLOW_SAB_MOVIE_COMPLETED} Radarr_imports=${FLOW_RADARR_IMPORTS} | anomalies=${FLOW_ANOMALY_COUNT} suppressed=${FLOW_ANOMALY_SUPPRESSED_COUNT}"
    fi

    persistent_log \
        "PIPELINE" \
        "status=${PIPELINE_STATUS} | ${PIPELINE_REASON}"
}

###############################################################################
# ACTIVITY FLOW ANOMALY DETECTION - v2.6
###############################################################################

###############################################################################
# INITIALIZE FLOW WINDOW
###############################################################################

initialize_flow_anomaly_window() {

    FLOW_ANALYSIS_OK=false
    FLOW_ANALYSIS_REASON="Not evaluated"

    if [ "$FLOW_ANOMALY_ENABLED" != true ]; then

        FLOW_ANALYSIS_REASON="Flow anomaly detection disabled"

        return 1
    fi

    ###########################################################################
    # v2.6 REUSES THE HISTORY FETCHED BY v2.5
    #
    # Therefore the flow window cannot be larger than the activity-audit
    # history window.
    ###########################################################################

    if (( FLOW_ANOMALY_LOOKBACK_HOURS > ACTIVITY_AUDIT_LOOKBACK_HOURS )); then

        FLOW_ANALYSIS_REASON="Flow window exceeds available activity-audit history"

        log "WARNING: FLOW_ANOMALY_LOOKBACK_HOURS=${FLOW_ANOMALY_LOOKBACK_HOURS}"
        log "WARNING: ACTIVITY_AUDIT_LOOKBACK_HOURS=${ACTIVITY_AUDIT_LOOKBACK_HOURS}"
        log "WARNING: Activity-flow analysis skipped"

        return 1
    fi

    FLOW_CUTOFF_EPOCH=$(
        date \
            -d "${FLOW_ANOMALY_LOOKBACK_HOURS} hours ago" \
            '+%s'
    )

    return 0
}

###############################################################################
# COUNT ARR IMPORT EVENTS SINCE FLOW CUTOFF
###############################################################################

count_arr_imports_since() {

    local history_file="$1"
    local cutoff="$2"

    local count=0
    local event_type
    local event_date
    local event_epoch

    [ -f "$history_file" ] || {
        echo 0
        return
    }

    while IFS=$'\t' read -r \
        event_type \
        event_date
    do

        [ "$event_type" = "downloadFolderImported" ] || continue

        event_epoch=$(date_to_epoch "$event_date")

        if (( event_epoch >= cutoff )); then

            ((count++)) || true
        fi

    done < <(
        jq -r '
            .[]?
            |
            [
                (.eventType // ""),
                (.date // "")
            ]
            |
            @tsv
        ' "$history_file"
    )

    echo "$count"
}

###############################################################################
# CALCULATE SAB ACTIVITY INSIDE FLOW WINDOW
###############################################################################

calculate_flow_sab_activity() {

    FLOW_SAB_TV_COMPLETED=0
    FLOW_SAB_MOVIE_COMPLETED=0

    [ -f "$SAB_HISTORY" ] || return 1

    local item
    local status
    local category
    local event_epoch

    while IFS= read -r item; do

        [ -n "$item" ] || continue

        status=$(
            echo "$item" |
                jq -r '.status // ""'
        )

        #######################################################################
        # ONLY SUCCESSFULLY COMPLETED SAB JOBS ARE RELEVANT HERE
        #######################################################################

        [ "${status,,}" = "completed" ] || continue

        category=$(
            echo "$item" |
                jq -r '.category // .cat // ""'
        )

        #######################################################################
        # F1 REMAINS COMPLETELY OUTSIDE THIS WORKFLOW
        #######################################################################

        if [ "${category,,}" = "${SAB_IGNORED_CATEGORY,,}" ]; then
            continue
        fi

        event_epoch=$(sab_history_event_epoch "$item")

        (( event_epoch > 0 )) || continue

        if (( event_epoch < FLOW_CUTOFF_EPOCH )); then
            continue
        fi

        #######################################################################
        # TV
        #######################################################################

        if [ "${category,,}" = "${SAB_TV_CATEGORY,,}" ]; then

            ((FLOW_SAB_TV_COMPLETED++)) || true

            continue
        fi

        #######################################################################
        # MOVIES
        #######################################################################

        if [ "${category,,}" = "${SAB_MOVIE_CATEGORY,,}" ]; then

            ((FLOW_SAB_MOVIE_COMPLETED++)) || true
        fi

    done < <(
        jq -c '.history.slots[]?' "$SAB_HISTORY"
    )

    return 0
}

###############################################################################
# COUNT EXISTING ISSUES THAT MAY ALREADY EXPLAIN A FLOW PROBLEM
#
# This is intentionally conservative.
#
# If Sonarr already has a CF/TBA/import/etc issue, or SAB already has a
# stranded-download issue, v2.6 does not add another higher-level warning.
#
# ACTIVITY_FLOW_ANOMALY itself is excluded so an existing flow issue does not
# suppress its own next observation.
###############################################################################

flow_explaining_issue_count() {

    local app="$1"

    jq -r \
        --arg app "$app" \
        --argjson runStart "$START_TIME" \
        '
        [
            (
                .issues
                // {}
                | to_entries[]
            )

            | select(
                (.value.active // false) == true
            )

            | select(
                (.value.lastSeen // 0) >= $runStart
            )

            | select(
                (.value.classification // "")
                !=
                "ACTIVITY_FLOW_ANOMALY"
            )

            | select(
                (
                    (.value.app // "") == $app
                )
                or
                (
                    (.value.app // "") == "SABnzbd"
                )
            )
        ]
        | length
        ' \
        "$STATE_FILE" 2>/dev/null ||
        echo 0
}

###############################################################################
# PRESERVE EXISTING FLOW ISSUE WHEN THE FLOW ANALYSIS CANNOT RUN
#
# Without this safeguard:
#
#   history API fails
#       ↓
#   flow detector cannot evaluate
#       ↓
#   issue isn't seen
#       ↓
#   normal lifecycle code could incorrectly mark it RESOLVED
#
###############################################################################

preserve_existing_flow_issue() {

    local app="$1"
    local kind="$2"

    local issue_key="FLOW:${app}:${kind}"

    local active

    active=$(
        jq -r \
            --arg key "$issue_key" \
            '(.issues[$key].active // false) | tostring' \
            "$STATE_FILE" 2>/dev/null
    )

    if [ "$active" = "true" ]; then

        mark_seen "$issue_key"
    fi
}

###############################################################################
# DETERMINE FLOW ISSUE LIFECYCLE STAGE
###############################################################################

flow_anomaly_stage() {

    local issue_key="$1"

    local active
    local first_seen
    local now
    local elapsed

    active=$(
        jq -r \
            --arg key "$issue_key" \
            '(.issues[$key].active // false) | tostring' \
            "$STATE_FILE" 2>/dev/null
    )

    ###########################################################################
    # NEW OR PREVIOUSLY RESOLVED ISSUE
    #
    # Do not inherit the old firstSeen timestamp.
    ###########################################################################

    if [ "$active" != "true" ]; then

        echo "INITIAL"

        return
    fi

    first_seen=$(
        jq -r \
            --arg key "$issue_key" \
            '.issues[$key].firstSeen // 0' \
            "$STATE_FILE" 2>/dev/null
    )

    [[ "$first_seen" =~ ^[0-9]+$ ]] || first_seen=0

    if (( first_seen <= 0 )); then

        echo "INITIAL"

        return
    fi

    now=$(date '+%s')

    elapsed=$(( now - first_seen ))

    if (( elapsed >= FLOW_ANOMALY_ESCALATE_HOURS * 3600 )); then

        echo "ESCALATED"

    else

        echo "INITIAL"
    fi
}

###############################################################################
# RECORD ACTIVITY FLOW ANOMALY
###############################################################################

record_activity_flow_anomaly() {

    local app="$1"
    local kind="$2"
    local sab_completed="$3"
    local arr_imports="$4"

    local issue_key
    local title
    local classification
    local severity
    local stage
    local message
    local signature
    local signature_message
    local persist_issue_transition=false

    issue_key="FLOW:${app}:${kind}"

    title="${kind} activity flow"

    classification="ACTIVITY_FLOW_ANOMALY"

    severity="WARNING"

    stage=$(flow_anomaly_stage "$issue_key")

    ###########################################################################
    # HUMAN-READABLE MESSAGE
    ###########################################################################

    message="SAB completed ${sab_completed} ${kind} job(s) during the last ${FLOW_ANOMALY_LOOKBACK_HOURS}h, but ${app} recorded ${arr_imports} successful import event(s). No currently tracked ${app}/SAB issue explains the inactivity."

    ###########################################################################
    # STABLE SIGNATURE MESSAGE
    #
    # Do NOT put the live SAB count into the signature.
    #
    # Otherwise:
    #
    #   3 completions -> notification
    #   4 completions -> changed signature -> notification
    #   5 completions -> changed signature -> notification
    #
    # The signature should change only when lifecycle stage changes.
    ###########################################################################

    signature_message="SAB activity present but ${app} recorded zero successful imports during ${FLOW_ANOMALY_LOOKBACK_HOURS}h flow window"

    signature=$(
        issue_signature \
            "$app" \
            "$issue_key" \
            "$classification" \
            "$severity" \
            "$stage" \
            "$signature_message"
    )

    if issue_transition_should_persist \
        "$issue_key" \
        "$signature"
    then

        persist_issue_transition=true
    fi

    update_issue_state \
        "$issue_key" \
        "$signature" \
        "$app" \
        "$title" \
        "$classification" \
        "$severity" \
        "$stage" \
        "$message"

    ###########################################################################
    # COUNTERS
    ###########################################################################

    ((FLOW_ANOMALY_COUNT++)) || true
    ((WARNING_COUNT++)) || true
    ((TOTAL_ISSUES++)) || true

    ###########################################################################
    # CURRENT RUN LOG
    ###########################################################################

    log ""
    log "Activity flow anomaly detected"
    log "Application: $app"
    log "Media type: $kind"
    log "Flow window: ${FLOW_ANOMALY_LOOKBACK_HOURS}h"
    log "SAB completed jobs: $sab_completed"
    log "Arr successful imports: $arr_imports"
    log "Stage: $stage"

    ###########################################################################
    # PERSIST ONLY NEW / CHANGED / RETURNED ISSUE
    ###########################################################################

    if [ "$persist_issue_transition" = true ]; then

        persistent_log \
            "ISSUE" \
            "${app} | ${classification} | ${severity} | ${kind} | SAB_completed=${sab_completed} | Arr_imports=${arr_imports} | window=${FLOW_ANOMALY_LOOKBACK_HOURS}h | stage=${stage}"
    fi

    if should_notify "$issue_key" "$signature"; then

        queue_group_notification \
            "$issue_key" \
            "$signature" \
            "$app" \
            "$title" \
            "$classification" \
            "$severity" \
            "" \
            "$message"

    else

        log "Notification suppressed: activity-flow issue already reported"
    fi
}

###############################################################################
# ASSESS ACTIVITY FLOW
###############################################################################

assess_activity_flow() {

    FLOW_ANALYSIS_OK=false
    FLOW_ANALYSIS_REASON="Not evaluated"

    ###########################################################################
    # FEATURE DISABLED
    ###########################################################################

    if [ "$FLOW_ANOMALY_ENABLED" != true ]; then

        FLOW_ANALYSIS_REASON="Flow anomaly detection disabled"

        preserve_existing_flow_issue \
            "Sonarr" \
            "TV"

        preserve_existing_flow_issue \
            "Radarr" \
            "Movie"

        return
    fi

    ###########################################################################
    # v2.5 ACTIVITY AUDIT IS REQUIRED
    ###########################################################################

    if [ "$ACTIVITY_AUDIT_ENABLED" != true ]; then

        FLOW_ANALYSIS_REASON="Activity audit disabled; flow data unavailable"

        preserve_existing_flow_issue \
            "Sonarr" \
            "TV"

        preserve_existing_flow_issue \
            "Radarr" \
            "Movie"

        return
    fi

    ###########################################################################
    # INITIALIZE WINDOW
    ###########################################################################

    if ! initialize_flow_anomaly_window; then

        preserve_existing_flow_issue \
            "Sonarr" \
            "TV"

        preserve_existing_flow_issue \
            "Radarr" \
            "Movie"

        return
    fi

    ###########################################################################
    # SAB DATA MUST BE HEALTHY
    ###########################################################################

    if [ "$SAB_AUDIT_OK" != true ]; then

        FLOW_ANALYSIS_REASON="SAB activity data unavailable"

        preserve_existing_flow_issue \
            "Sonarr" \
            "TV"

        preserve_existing_flow_issue \
            "Radarr" \
            "Movie"

        return
    fi

    if ! calculate_flow_sab_activity; then

        FLOW_ANALYSIS_REASON="Unable to calculate SAB flow activity"

        preserve_existing_flow_issue \
            "Sonarr" \
            "TV"

        preserve_existing_flow_issue \
            "Radarr" \
            "Movie"

        return
    fi

    ###########################################################################
    # SONARR IMPORT ACTIVITY
    ###########################################################################

    if [ "$SONARR_ENABLED" = true ] &&
       [ "$SONARR_AUDIT_OK" = true ] &&
       [ -f "$SONARR_AUDIT_HISTORY" ]
    then

        FLOW_SONARR_IMPORTS=$(
            count_arr_imports_since \
                "$SONARR_AUDIT_HISTORY" \
                "$FLOW_CUTOFF_EPOCH"
        )

        FLOW_SONARR_EXPLANATIONS=$(
            flow_explaining_issue_count \
                "Sonarr"
        )

        #######################################################################
        # STRONG ANOMALY:
        #
        # meaningful SAB activity
        # +
        # absolutely zero successful Sonarr imports
        #######################################################################

        if (( FLOW_SAB_TV_COMPLETED >= FLOW_MIN_SAB_ACTIVITY )) &&
           (( FLOW_SONARR_IMPORTS == 0 ))
        then

            if (( FLOW_SONARR_EXPLANATIONS == 0 )); then

                record_activity_flow_anomaly \
                    "Sonarr" \
                    "TV" \
                    "$FLOW_SAB_TV_COMPLETED" \
                    "$FLOW_SONARR_IMPORTS"

            else

                ((FLOW_ANOMALY_SUPPRESSED_COUNT++)) || true

                log "Sonarr flow anomaly candidate suppressed"
                log "Reason: ${FLOW_SONARR_EXPLANATIONS} active Sonarr/SAB issue(s) already tracked"
            fi
        fi

    else

        preserve_existing_flow_issue \
            "Sonarr" \
            "TV"
    fi

    ###########################################################################
    # RADARR IMPORT ACTIVITY
    ###########################################################################

    if [ "$RADARR_ENABLED" = true ] &&
       [ "$RADARR_AUDIT_OK" = true ] &&
       [ -f "$RADARR_AUDIT_HISTORY" ]
    then

        FLOW_RADARR_IMPORTS=$(
            count_arr_imports_since \
                "$RADARR_AUDIT_HISTORY" \
                "$FLOW_CUTOFF_EPOCH"
        )

        FLOW_RADARR_EXPLANATIONS=$(
            flow_explaining_issue_count \
                "Radarr"
        )

        if (( FLOW_SAB_MOVIE_COMPLETED >= FLOW_MIN_SAB_ACTIVITY )) &&
           (( FLOW_RADARR_IMPORTS == 0 ))
        then

            if (( FLOW_RADARR_EXPLANATIONS == 0 )); then

                record_activity_flow_anomaly \
                    "Radarr" \
                    "Movie" \
                    "$FLOW_SAB_MOVIE_COMPLETED" \
                    "$FLOW_RADARR_IMPORTS"

            else

                ((FLOW_ANOMALY_SUPPRESSED_COUNT++)) || true

                log "Radarr flow anomaly candidate suppressed"
                log "Reason: ${FLOW_RADARR_EXPLANATIONS} active Radarr/SAB issue(s) already tracked"
            fi
        fi

    else

        preserve_existing_flow_issue \
            "Radarr" \
            "Movie"
    fi

    FLOW_ANALYSIS_OK=true
    FLOW_ANALYSIS_REASON="Flow analysis completed"
}

###############################################################################
# PRUNE STATE - v2.3
#
# Issue lifecycle:
#   Active issues are retained regardless of age.
#   Old resolved issues are removed.
#
# Arr telemetry:
#   Patterns older than ARR_TELEMETRY_RETENTION_DAYS are removed.
#   Pattern count is also capped at ARR_TELEMETRY_MAX_PATTERNS.
###############################################################################

prune_state() {

    local issue_cutoff
    local telemetry_cutoff
    local tmp

    issue_cutoff=$(
        date -d "${STATE_RETENTION_DAYS} days ago" '+%s'
    )

    telemetry_cutoff=$(
        date -d "${ARR_TELEMETRY_RETENTION_DAYS} days ago" '+%s'
    )

    tmp="$TMP_DIR/state.pruned.json"

    jq \
        --argjson issueCutoff "$issue_cutoff" \
        --argjson telemetryCutoff "$telemetry_cutoff" \
        --argjson telemetryMax "$ARR_TELEMETRY_MAX_PATTERNS" \
        '
        #######################################################################
        # ISSUE LIFECYCLE
        #######################################################################

        .issues |= with_entries(

            select(

                (.value.active == true)

                or

                (
                    (
                        .value.resolvedAt
                        // .value.lastSeen
                        // 0
                    )
                    >= $issueCutoff
                )
            )
        )

        |

        .sabProgress = (
            (.sabProgress // {})
            | with_entries(
                select((.value.lastSeen // 0) >= $issueCutoff)
            )
        )

        |

        #######################################################################
        # ARR TELEMETRY
        #######################################################################

        .telemetry = (
            .telemetry
            // {
                version: 1,
                patterns: {}
            }
        )

        |

        .telemetry.patterns = (

            (.telemetry.patterns // {})

            | to_entries

            | map(

                select(
                    (.value.lastSeen // 0)
                    >= $telemetryCutoff
                )
            )

            | sort_by(.value.lastSeen)

            | reverse

            | .[:$telemetryMax]

            | from_entries
        )
        ' \
        "$STATE_FILE" >"$tmp" || return

    save_state "$tmp"
}

###############################################################################
# LOCK
###############################################################################

exec 9>"$LOCKFILE"

if ! flock -n 9; then

    log "Another ARR import monitor run is already active"

    exit 1
fi

###############################################################################
# REQUIREMENTS
###############################################################################

require_command curl
require_command jq
require_command date
require_command stat
require_command sed
require_command sort
require_command comm
require_command tr
require_command sha256sum
require_command find
require_command awk
require_command wc
require_command grep

###############################################################################
# TEMP DIRECTORY
###############################################################################

TMP_DIR=$(mktemp -d /tmp/arr_health_activity.XXXXXX) || {
    log "ERROR: Unable to create temporary directory"
    exit 3
}

NOTIFICATION_BATCH="${TMP_DIR}/notification_batch.jsonl"
SEEN_ISSUES_FILE="${TMP_DIR}/seen_issues.txt"
SAB_PRIMARY_DOWNLOADS_FILE="${TMP_DIR}/sab_primary_downloads.txt"
SAB_PROGRESS_SEEN_FILE="${TMP_DIR}/sab_progress_seen.txt"
SAB_PROGRESS_OBSERVATIONS_FILE="${TMP_DIR}/sab_progress_observations.jsonl"

: >"$NOTIFICATION_BATCH"
: >"$SEEN_ISSUES_FILE"
: >"$SAB_PRIMARY_DOWNLOADS_FILE"
: >"$SAB_PROGRESS_SEEN_FILE"
: >"$SAB_PROGRESS_OBSERVATIONS_FILE"

###############################################################################
# STATE
###############################################################################

initialize_state

###############################################################################
# v2.5 PERSISTENT LOG / ACTIVITY AUDIT INITIALIZATION
###############################################################################

rotate_persistent_log

persistent_log \
    "START" \
    "ARR Health Monitor v3.0.0"

if [ "$ACTIVITY_AUDIT_ENABLED" = true ]; then

    initialize_activity_audit_window

    log "Activity audit window: last ${ACTIVITY_AUDIT_LOOKBACK_HOURS}h"
fi

###############################################################################
# START
###############################################################################

log "Starting ARR Health Monitor v3.0.0"
log "Recommended schedule: every five minutes"
log "Notifications enabled: $SEND_NOTIFICATIONS"
log "Grouped notification maximum items: $GROUP_NOTIFICATION_MAX_ITEMS"

###############################################################################
# SABNZBD
###############################################################################

if [ "$SAB_ENABLED" = true ]; then

    log "Connecting to SABnzbd"

    SAB_HISTORY="$TMP_DIR/sab_history.json"
    SAB_QUEUE="$TMP_DIR/sab_queue.json"
    SAB_WARNINGS="$TMP_DIR/sab_warnings.json"
    SAB_STATUS="$TMP_DIR/sab_status.json"

    if fetch_sab_history "$SAB_HISTORY"; then

        SAB_HISTORY_OK=true
        SAB_SCAN_OK=true

        SAB_COUNT=$(
            jq '.history.slots | length' \
            "$SAB_HISTORY" 2>/dev/null ||
            echo 0
        )

        log "SABnzbd history records loaded: $SAB_COUNT"

    else

        SAB_HISTORY_OK=false
        SAB_SCAN_OK=false
        SAB_HISTORY=""

        SAB_API_FAILURES=$(append_api_failure \
            "$SAB_API_FAILURES" \
            "history" \
            "$API_LAST_ERROR")
    fi

    if fetch_sab_queue "$SAB_QUEUE"; then

        SAB_QUEUE_OK=true
        log "SABnzbd queue entries: $(jq '.queue.slots // [] | length' "$SAB_QUEUE")"

    else

        SAB_QUEUE_OK=false
        SAB_QUEUE=""
        SAB_API_FAILURES=$(append_api_failure \
            "$SAB_API_FAILURES" \
            "queue" \
            "$API_LAST_ERROR")
    fi

    if sab_get warnings "$SAB_WARNINGS"; then

        SAB_WARNINGS_OK=true

    else

        SAB_WARNINGS_OK=false
        SAB_WARNINGS=""
        SAB_API_FAILURES=$(append_api_failure \
            "$SAB_API_FAILURES" \
            "warnings" \
            "$API_LAST_ERROR")
    fi

    if sab_get status "$SAB_STATUS"; then

        SAB_STATUS_OK=true

    else

        SAB_STATUS_OK=false
        SAB_STATUS=""
        SAB_API_FAILURES=$(append_api_failure \
            "$SAB_API_FAILURES" \
            "status" \
            "$API_LAST_ERROR")
    fi

    SAB_API_OK=false

    if [ "$SAB_HISTORY_OK" = true ] &&
       [ "$SAB_QUEUE_OK" = true ] &&
       [ "$SAB_WARNINGS_OK" = true ] &&
       [ "$SAB_STATUS_OK" = true ]
    then
        SAB_API_OK=true
    fi
fi

###############################################################################
# SONARR
###############################################################################

if [ "$SONARR_ENABLED" = true ]; then

    log "Checking Sonarr health and queue"

    SONARR_QUEUE="$TMP_DIR/sonarr_queue.json"
    SONARR_HEALTH="$TMP_DIR/sonarr_health.json"
    SONARR_SYSTEM_STATUS="$TMP_DIR/sonarr_system_status.json"

    if fetch_arr_queue \
        "Sonarr" \
        "$SONARR_URL" \
        "$SONARR_API_KEY" \
        "$SONARR_QUEUE"
    then

        SONARR_QUEUE_OK=true
        SONARR_SCAN_OK=true

        SONARR_COUNT=$(
            jq '.records | length' \
            "$SONARR_QUEUE" 2>/dev/null ||
            echo 0
        )

        log "Sonarr queue entries: $SONARR_COUNT"

    else

        SONARR_QUEUE_OK=false
        SONARR_SCAN_OK=false
        SONARR_QUEUE=""

        SONARR_API_FAILURES=$(append_api_failure \
            "$SONARR_API_FAILURES" \
            "queue" \
            "$API_LAST_ERROR")
    fi

    if api_get \
        "${SONARR_URL%/}/api/v3/health" \
        "$SONARR_API_KEY" \
        "$SONARR_HEALTH"
    then
        SONARR_HEALTH_OK=true
    else
        SONARR_HEALTH_OK=false
        SONARR_HEALTH=""
        SONARR_API_FAILURES=$(append_api_failure \
            "$SONARR_API_FAILURES" \
            "health" \
            "$API_LAST_ERROR")
    fi

    if api_get \
        "${SONARR_URL%/}/api/v3/system/status" \
        "$SONARR_API_KEY" \
        "$SONARR_SYSTEM_STATUS"
    then
        SONARR_STATUS_OK=true
        log "Connected to Sonarr $(jq -r '.version // "unknown"' "$SONARR_SYSTEM_STATUS")"
    else
        SONARR_STATUS_OK=false
        SONARR_SYSTEM_STATUS=""
        SONARR_API_FAILURES=$(append_api_failure \
            "$SONARR_API_FAILURES" \
            "system/status" \
            "$API_LAST_ERROR")
    fi

    SONARR_API_OK=false

    if [ "$SONARR_QUEUE_OK" = true ] &&
       [ "$SONARR_HEALTH_OK" = true ] &&
       [ "$SONARR_STATUS_OK" = true ]
    then
        SONARR_API_OK=true
    fi
fi

###############################################################################
# RADARR
###############################################################################

if [ "$RADARR_ENABLED" = true ]; then

    log "Checking Radarr health and queue"

    RADARR_QUEUE="$TMP_DIR/radarr_queue.json"
    RADARR_HEALTH="$TMP_DIR/radarr_health.json"
    RADARR_SYSTEM_STATUS="$TMP_DIR/radarr_system_status.json"

    if fetch_arr_queue \
        "Radarr" \
        "$RADARR_URL" \
        "$RADARR_API_KEY" \
        "$RADARR_QUEUE"
    then

        RADARR_QUEUE_OK=true
        RADARR_SCAN_OK=true

        RADARR_COUNT=$(
            jq '.records | length' \
            "$RADARR_QUEUE" 2>/dev/null ||
            echo 0
        )

        log "Radarr queue entries: $RADARR_COUNT"

    else

        RADARR_QUEUE_OK=false
        RADARR_SCAN_OK=false
        RADARR_QUEUE=""

        RADARR_API_FAILURES=$(append_api_failure \
            "$RADARR_API_FAILURES" \
            "queue" \
            "$API_LAST_ERROR")
    fi

    if api_get \
        "${RADARR_URL%/}/api/v3/health" \
        "$RADARR_API_KEY" \
        "$RADARR_HEALTH"
    then
        RADARR_HEALTH_OK=true
    else
        RADARR_HEALTH_OK=false
        RADARR_HEALTH=""
        RADARR_API_FAILURES=$(append_api_failure \
            "$RADARR_API_FAILURES" \
            "health" \
            "$API_LAST_ERROR")
    fi

    if api_get \
        "${RADARR_URL%/}/api/v3/system/status" \
        "$RADARR_API_KEY" \
        "$RADARR_SYSTEM_STATUS"
    then
        RADARR_STATUS_OK=true
        log "Connected to Radarr $(jq -r '.version // "unknown"' "$RADARR_SYSTEM_STATUS")"
    else
        RADARR_STATUS_OK=false
        RADARR_SYSTEM_STATUS=""
        RADARR_API_FAILURES=$(append_api_failure \
            "$RADARR_API_FAILURES" \
            "system/status" \
            "$API_LAST_ERROR")
    fi

    RADARR_API_OK=false

    if [ "$RADARR_QUEUE_OK" = true ] &&
       [ "$RADARR_HEALTH_OK" = true ] &&
       [ "$RADARR_STATUS_OK" = true ]
    then
        RADARR_API_OK=true
    fi
fi

###############################################################################
# UNIFIED HEALTH / QUEUE PROCESSING
###############################################################################

if [ "$SAB_ENABLED" = true ]; then

    record_service_api_issue "SABnzbd" "$SAB_API_OK" "$SAB_API_FAILURES"
    process_sab_warnings
    process_sab_queue_health
    process_sab_failed_jobs
    process_sab_live_progress
    evaluate_sab_progress
fi

if [ "$SONARR_ENABLED" = true ]; then

    record_service_api_issue "Sonarr" "$SONARR_API_OK" "$SONARR_API_FAILURES"

    if [ "$SONARR_HEALTH_OK" = true ]; then
        process_arr_native_health "Sonarr" "$SONARR_HEALTH"
    fi

    if [ "$SONARR_QUEUE_OK" = true ]; then
        process_queue "Sonarr" "$SONARR_QUEUE"
    fi
fi

if [ "$RADARR_ENABLED" = true ]; then

    record_service_api_issue "Radarr" "$RADARR_API_OK" "$RADARR_API_FAILURES"

    if [ "$RADARR_HEALTH_OK" = true ]; then
        process_arr_native_health "Radarr" "$RADARR_HEALTH"
    fi

    if [ "$RADARR_QUEUE_OK" = true ]; then
        process_queue "Radarr" "$RADARR_QUEUE"
    fi
fi

###############################################################################
# RECENT ACTIVITY AUDIT - v2.5
###############################################################################

if [ "$ACTIVITY_AUDIT_ENABLED" = true ]; then

    log "Running recent operational activity audit"

    ###########################################################################
    # SABNZBD
    ###########################################################################

    process_sab_activity_audit

    ###########################################################################
    # SONARR HISTORY
    ###########################################################################

    if [ "$SONARR_ENABLED" = true ]
    then

        SONARR_AUDIT_HISTORY="${TMP_DIR}/sonarr_history_audit.json"

        if fetch_arr_activity_history \
            "Sonarr" \
            "$SONARR_URL" \
            "$SONARR_API_KEY" \
            "$SONARR_AUDIT_HISTORY"
        then

            SONARR_AUDIT_OK=true

            process_arr_activity_audit \
                "Sonarr" \
                "$SONARR_AUDIT_HISTORY"

            process_arr_history_failures \
                "Sonarr" \
                "$SONARR_AUDIT_HISTORY"

        else

            SONARR_AUDIT_OK=false

            log "WARNING: Unable to retrieve recent Sonarr history"

            persistent_log \
                "ERROR" \
                "Unable to retrieve recent Sonarr history"
        fi
    fi

    ###########################################################################
    # RADARR HISTORY
    ###########################################################################

    if [ "$RADARR_ENABLED" = true ]
    then

        RADARR_AUDIT_HISTORY="${TMP_DIR}/radarr_history_audit.json"

        if fetch_arr_activity_history \
            "Radarr" \
            "$RADARR_URL" \
            "$RADARR_API_KEY" \
            "$RADARR_AUDIT_HISTORY"
        then

            RADARR_AUDIT_OK=true

            process_arr_activity_audit \
                "Radarr" \
                "$RADARR_AUDIT_HISTORY"

            process_arr_history_failures \
                "Radarr" \
                "$RADARR_AUDIT_HISTORY"

        else

            RADARR_AUDIT_OK=false

            log "WARNING: Unable to retrieve recent Radarr history"

            persistent_log \
                "ERROR" \
                "Unable to retrieve recent Radarr history"
        fi
    fi
fi

###############################################################################
# SAB CROSS-APP CHECK
###############################################################################

process_sab_orphans

prune_sab_progress_state

###############################################################################
# ACTIVITY FLOW ANOMALY - v2.6
###############################################################################

assess_activity_flow

###############################################################################
# RESOLUTION CHECK
#
# Done only after all current issues have been marked seen.
###############################################################################

resolve_missing_issues

###############################################################################
# SEND ONE GROUPED NOTIFICATION
###############################################################################

send_grouped_notification

###############################################################################
# PRUNE OLD RESOLVED STATE
###############################################################################

prune_state

###############################################################################
# PIPELINE HEALTH - v2.5
###############################################################################

assess_pipeline_health

write_persistent_activity_summary

###############################################################################
# SUMMARY
###############################################################################

RUNTIME=$(runtime)

log "============================================================"
log "ARR Health Monitor v3.0.0 completed"

log ""
log "SCAN HEALTH"
log "Sonarr API healthy: $SONARR_API_OK"
log "  Queue: $SONARR_QUEUE_OK | Health: $SONARR_HEALTH_OK | Status: $SONARR_STATUS_OK"
log "Radarr API healthy: $RADARR_API_OK"
log "  Queue: $RADARR_QUEUE_OK | Health: $RADARR_HEALTH_OK | Status: $RADARR_STATUS_OK"
log "SABnzbd API healthy: $SAB_API_OK"
log "  History: $SAB_HISTORY_OK | Queue: $SAB_QUEUE_OK | Warnings: $SAB_WARNINGS_OK | Status: $SAB_STATUS_OK"

log ""
log "NATIVE HEALTH"
log "Arr native health issues: $ARR_NATIVE_HEALTH_COUNT"
log "Service API issues: $SERVICE_API_ISSUE_COUNT"
log "SAB warnings/errors: $SAB_NATIVE_WARNING_COUNT"
log "SAB failed jobs: $SAB_FAILED_JOB_COUNT"
log "SAB stalled jobs: $SAB_STALLED_JOB_COUNT"
log "SAB queue pauses: $SAB_PAUSED_COUNT"
log "SAB unknown-category jobs: $SAB_UNKNOWN_CATEGORY_COUNT"

log ""
log "RECENT ACTIVITY - LAST ${ACTIVITY_AUDIT_LOOKBACK_HOURS}H"

if [ "$ACTIVITY_AUDIT_ENABLED" = true ]; then

    log ""
    log "SABnzbd"
    log "Movie jobs completed: $SAB_AUDIT_MOVIE_COMPLETED"
    log "TV jobs completed: $SAB_AUDIT_TV_COMPLETED"
    log "Movie jobs failed: $SAB_AUDIT_MOVIE_FAILED"
    log "TV jobs failed: $SAB_AUDIT_TV_FAILED"
    log "F1 jobs ignored by audit: $SAB_AUDIT_F1_IGNORED"

    if [ "$SAB_AUDIT_WINDOW_INCOMPLETE" = true ]; then

        log "WARNING: SAB history may not cover the complete audit window"
    fi

    log ""
    log "Sonarr"
    log "Successful import events: $SONARR_AUDIT_IMPORTED"
    log "Download-failed events: $SONARR_AUDIT_DOWNLOAD_FAILED"

    log ""
    log "Radarr"
    log "Successful import events: $RADARR_AUDIT_IMPORTED"
    log "Download-failed events: $RADARR_AUDIT_DOWNLOAD_FAILED"

else

    log "Activity audit: DISABLED"
fi

log ""
log "ARR QUEUES"
log "Queue entries examined: $TOTAL_QUEUE"
log "CF rejections: $CF_REJECT_COUNT"
log "Other upgrade rejections: $UPGRADE_REJECT_COUNT"
log "TBA / metadata waits: $TBA_COUNT"
log "Unmatched media: $UNMATCHED_COUNT"
log "No-importable-file issues: $NO_IMPORT_COUNT"
log "ARR import stalls: $STALL_COUNT"

log ""
log "SAB CROSS-APP"
log "Completed SAB jobs examined: $SAB_HISTORY_CHECKED"
log "F1 jobs ignored: $SAB_IGNORED_COUNT"

log "Stranded downloads: $SAB_STRANDED_COUNT"
log "  Media payload: $SAB_MEDIA_STRANDED_COUNT"
log "  Archive payload: $SAB_ARCHIVE_STRANDED_COUNT"
log "  Significant other data: $SAB_OTHER_STRANDED_COUNT"

log "Early stranded candidates: $SAB_CANDIDATE_COUNT"

log "Cleanup residue: $SAB_RESIDUE_COUNT"
log "  Sample-only residue: $SAB_SAMPLE_RESIDUE_COUNT"

log "Empty leftover directories: $SAB_EMPTY_COUNT"

log ""
log "LIFECYCLE"
log "Issues resolved this run: $RESOLVED_COUNT"

log ""
log "TOTAL"
log "Active issues detected this run: $TOTAL_ISSUES"
log "Informational: $INFO_COUNT"
log "Warnings: $WARNING_COUNT"
log "Errors: $ERROR_COUNT"

log ""
log "ARR MESSAGE TELEMETRY"

if [ "$ARR_TELEMETRY_ENABLED" = true ]; then

    TELEMETRY_TOTAL_PATTERNS=$(arr_telemetry_pattern_count)
    PROMOTION_CANDIDATES=$(arr_telemetry_review_candidate_count)

    log "Generic Arr observations this run: $TELEMETRY_OBSERVATIONS"
    log "New normalized patterns: $TELEMETRY_NEW_PATTERNS"
    log "Existing pattern matches: $TELEMETRY_EXISTING_PATTERNS"
    log "Stored telemetry patterns: $TELEMETRY_TOTAL_PATTERNS"
    log "Telemetry retention: ${ARR_TELEMETRY_RETENTION_DAYS} days"
    log "Review candidates: $PROMOTION_CANDIDATES"
    log "Promotion-rule matches this run: $PROMOTION_RULE_MATCHES"
    log "Telemetry retention: ${ARR_TELEMETRY_RETENTION_DAYS} days"

else

    log "Telemetry: DISABLED"
fi

if (( PROMOTION_CANDIDATES > 0 )); then
    log_arr_telemetry_review_candidates
fi

log ""
log "ACTIVITY FLOW - LAST ${FLOW_ANOMALY_LOOKBACK_HOURS}H"

if [ "$FLOW_ANOMALY_ENABLED" = true ]; then

    log ""
    log "Sonarr / TV"
    log "SAB TV jobs completed: $FLOW_SAB_TV_COMPLETED"
    log "Sonarr successful imports: $FLOW_SONARR_IMPORTS"
    log "Existing issue explanations: $FLOW_SONARR_EXPLANATIONS"

    log ""
    log "Radarr / Movies"
    log "SAB movie jobs completed: $FLOW_SAB_MOVIE_COMPLETED"
    log "Radarr successful imports: $FLOW_RADARR_IMPORTS"
    log "Existing issue explanations: $FLOW_RADARR_EXPLANATIONS"

    log ""
    log "Flow anomalies: $FLOW_ANOMALY_COUNT"
    log "Candidates suppressed by existing issues: $FLOW_ANOMALY_SUPPRESSED_COUNT"
    log "Flow analysis successful: $FLOW_ANALYSIS_OK"
    log "Flow analysis status: $FLOW_ANALYSIS_REASON"

else

    log "Activity flow anomaly detection: DISABLED"
fi

log ""
log "PIPELINE HEALTH"
log "Status: $PIPELINE_STATUS"
log "Reason: $PIPELINE_REASON"

log ""
log "NOTIFICATIONS"
log "New/escalated issues queued for grouping: $BATCHED_NOTIFICATION_ITEMS"

if [ "$SEND_NOTIFICATIONS" = true ]; then

    log "Grouped notifications sent: $NOTIFICATIONS_SENT"
    log "Previously-notified issues suppressed: $NOTIFICATIONS_SUPPRESSED"

else

    log "Notifications: DISABLED"
    log "Previously-notified issues suppressed: $NOTIFICATIONS_SUPPRESSED"
fi

log ""
log "Recommended run interval: every five minutes"
log "Runtime: $RUNTIME"
log "============================================================"

persistent_log \
    "END" \
    "runtime=${RUNTIME} | active_issues=${TOTAL_ISSUES} | info=${INFO_COUNT} | warnings=${WARNING_COUNT} | errors=${ERROR_COUNT}"
    
exit 0
