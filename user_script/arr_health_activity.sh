#!/bin/bash

###############################################################################
# ARR Health / Download / Import Monitor v3.6.0
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
# Resolutions can be included in the same grouped notification. Live actionable
# warnings/errors receive severity-based reminders, historical events are
# notification-once, and heuristic/evidence-gap reminders are bounded.
# Acknowledging an issue suppresses its unchanged signature until it resolves;
# an escalation or other material signature change clears the acknowledgement
# automatically.
#
# Lifecycle commands from an Unraid terminal:
#
#   script --list-active
#   script --ack ACK_ID "optional note"
#   script --unack ACK_ID
#
# Each notification includes the short ACK_ID needed by these commands.
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
# Sonarr/Radarr health sources are not silently missed by a fixed message list.
# Error, warning, and notice types map to ERROR, WARNING, and INFO respectively;
# an unfamiliar future type is retained and conservatively treated as WARNING.
# Health identity uses application, source, and normalized message so changing
# paths, URLs, UUIDs, and other volatile values do not create alert churn.
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
#   SAB_JOB_PAUSED
#   SAB_JOB_ENCRYPTED
#   SAB_JOB_DUPLICATE
#   SAB_STALLED_*
#   SAB_CATEGORY_UNKNOWN
#   SAB_SERVER_DEGRADED
#   SAB_SERVER_AUTHENTICATION
#   SAB_SERVER_LOW_ARTICLE_SUCCESS
#   SAB_DISK_SPACE_LOW
#   SAB_QUOTA_LOW
#
# EXACT DOWNLOAD FLOW
# -------------------
#   DOWNLOAD_FLOW_NOT_REACHED_SAB
#   DOWNLOAD_FLOW_SAB_VANISHED
#   DOWNLOAD_FLOW_IMPORT_MISSING
#   DOWNLOAD_FLOW_RECONCILED_*
#
# Missing-import issues are reconciled automatically through Arr APIs. Exact
# download history is checked first. If no terminal history is available, the
# monitor verifies the exact Sonarr episode/Radarr movie and its Arr database
# file record twice before closing the issue. Physical media paths are never
# accessed, so this reconciliation does not wake array disks.
#
# MONITOR SELF-HEALTH
# -------------------
#   SERVICE_API_UNAVAILABLE
#   SERVICE_API_AUTHENTICATION
#   MONITOR_SCAN_FAILURE
#   MONITOR_NOTIFICATION_FAILURE
#   MONITOR_SCHEDULE_MISSED
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
# State records include:
#
#   firstSeen
#   lastSeen
#   occurrences
#   active
#   resolvedAt
#   notifiedSignature
#   lastNotifiedAt
#   reminderCount
#   transitionTimestamps
#   flappingStartedAt / flappingUntil / flapNotifiedAt
#   ackId / acknowledgedSignature / acknowledgedAt
#   source
#   normalizedMessage
#
# When an issue disappears during a successful scan:
#
#   active = false
#   resolvedAt = current time
#
# Resolution notifications are configurable and grouped.
#
# If the same issue later returns, it normally starts a new lifecycle. Rapid
# repeats are combined into a flapping episode instead.
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
# successful health scans before notification. Errors and notices alert on the
# first successful scan; unfamiliar future types follow the warning threshold.
ARR_HEALTH_WARNING_NOTIFY_RUNS=2
ARR_HEALTH_ERROR_NOTIFY_RUNS=1
ARR_HEALTH_NOTICE_NOTIFY_RUNS=1
ARR_HEALTH_UNKNOWN_NOTIFY_RUNS=2

# A service API problem becomes actionable only after repeated complete-run
# failures. This avoids noise during a normal container restart.
API_FAILURE_NOTIFY_RUNS=3
API_FAILURE_ESCALATE_MINUTES=60

# Retry temporary transport, rate-limit, and server-side failures inside a
# single monitor run. Authentication and other permanent HTTP failures are not
# retried. Retry-After is honored when supplied by the service.
HTTP_RETRY_COUNT=2
HTTP_RETRY_BASE_DELAY_SECONDS=2
HTTP_RETRY_MAX_DELAY_SECONDS=30
HTTP_CONNECT_TIMEOUT_SECONDS=10
HTTP_REQUEST_TIMEOUT_SECONDS=30

# ---------------------------------------------------------------------------
# Monitor self-health
# ---------------------------------------------------------------------------

# The configured cron interval and tolerated scheduler/startup jitter. A gap
# greater than their sum becomes a lifecycle issue when the script next runs.
# An external watcher is still required to alert while this script is absent.
MONITOR_EXPECTED_INTERVAL_MINUTES=5
MONITOR_MISSED_RUN_GRACE_MINUTES=10

# Secondary collection/processing failures not already owned by a service API
# issue must repeat before notification.
MONITOR_SCAN_FAILURE_NOTIFY_RUNS=3
MONITOR_SCAN_FAILURE_ESCALATE_MINUTES=60

# A missing or failing Unraid notification command is recorded immediately,
# retried on later runs, and mirrored to syslog as a fallback.
MONITOR_NOTIFICATION_FAILURE_NOTIFY_RUNS=1

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

# SAB history status "Queued" is the intentional wait before the next batched
# Arr import run. Allow one complete four-hour batch interval plus one hour for
# that run to start and make progress. This delay applies only to Queued;
# active download and post-processing stages retain the thresholds above.
SAB_BATCH_IMPORT_INTERVAL_MINUTES=240
SAB_BATCH_IMPORT_GRACE_MINUTES=60
SAB_POSTPROCESS_WAIT_MINUTES=$((
    SAB_BATCH_IMPORT_INTERVAL_MINUTES + SAB_BATCH_IMPORT_GRACE_MINUTES
))

# Per-job operational conditions. An intentionally propagating job is allowed
# to reach its advertised ready time plus this grace period before it can be
# classified as stalled.
SAB_JOB_PAUSE_WARN_MINUTES=60
SAB_DUPLICATE_WARN_MINUTES=15
SAB_PROPAGATION_DEFAULT_MINUTES=60
SAB_PROPAGATION_GRACE_MINUTES=30

# Proactive capacity thresholds reported by SABnzbd. SAB reports these values
# in GiB. A value of 0 disables the corresponding proactive warning.
SAB_DISK_WARN_GB=20
SAB_QUOTA_WARN_GB=10

# Individual provider health. Article-success checks use per-run counter
# deltas, so the first successful observation establishes a baseline only.
SAB_SERVER_ERROR_NOTIFY_RUNS=2
SAB_SERVER_MIN_ARTICLE_ATTEMPTS=500
SAB_SERVER_MIN_SUCCESS_PERCENT=80
SAB_SERVER_SUCCESS_NOTIFY_RUNS=2

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

# Maximum individual issues shown in one notification batch. Additional issues
# are sent in subsequent numbered batches during the same run.
GROUP_NOTIFICATION_MAX_ITEMS=20

# Oversized batches are split into multiple notifications. Individual details
# are shortened only at the notification boundary; issue classification and
# lifecycle state remain unchanged.
GROUP_NOTIFICATION_MAX_BYTES=24000
GROUP_NOTIFICATION_ITEM_MAX_CHARS=4000

# ---------------------------------------------------------------------------
# Notification lifecycle - v3.6
# ---------------------------------------------------------------------------

# Repeat unchanged active errors and warnings until they resolve or are
# acknowledged. Informational issues do not receive reminders.
REMINDERS_ENABLED=true
ERROR_REMINDER_INTERVAL_HOURS=6
WARNING_REMINDER_INTERVAL_HOURS=24

# 0 means unlimited reminders while the issue remains active.
REMINDER_MAX_COUNT=0

# Historical events are notification-once. Known heuristic conditions use a
# slower, bounded reminder policy so that a persistent observation cannot
# create unlimited email. A material signature or severity change still
# generates a fresh notification.
HEURISTIC_ERROR_REMINDER_INTERVAL_HOURS=24
HEURISTIC_WARNING_REMINDER_INTERVAL_HOURS=48
HEURISTIC_REMINDER_MAX_COUNT=2

# An exact download-flow evidence gap receives up to three daily reminders if
# API-only reconciliation cannot safely prove a terminal outcome.
DOWNLOAD_FLOW_REMINDER_INTERVAL_HOURS=24
DOWNLOAD_FLOW_REMINDER_MAX_COUNT=3

# Treat repeated active/resolved transitions as one flapping episode. The
# first detected episode is reported once; routine raise/restore messages are
# then suppressed for the configured period.
FLAP_DETECTION_ENABLED=true
FLAP_WINDOW_MINUTES=60
FLAP_TRANSITION_THRESHOLD=4
FLAP_SUPPRESSION_MINUTES=120

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

STATE_DIR="/mnt/vault/cloud/logs/script/arr_health_activity"

# Never create the state tree beneath an absent backing mount. The SAB guard
# affects only filesystem orphan/residue analysis; API monitoring continues.
STATE_REQUIRED_MOUNT="/mnt/vault"
SAB_REQUIRED_MOUNT="/mnt/user"
SAB_FILESYSTEM_GUARD_ENABLED=true
MOVER_GUARD_ENABLED=true
MOVER_PROCESS_PATTERN='(^|/)(mover|mover\.old)( |$)|mover\.php'

STATE_FILE="${STATE_DIR}/state.json"
STATE_BACKUP="${STATE_DIR}/state.json.bak"
SAB_HISTORY_CACHE="${STATE_DIR}/sab_history_cache.json"

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

# Exact cross-application flow ledger. Aggregate flow detection remains as a
# fallback, while records with a shared downloadId/nzo_id are assessed one by
# one. Only recent completions or downloads observed live by this monitor are
# enrolled; old SAB history is not treated as a newly discovered workflow.
# Once enrolled, a download remains monitored beyond the discovery window.
DOWNLOAD_LEDGER_ENABLED=true
DOWNLOAD_LEDGER_GRAB_TO_SAB_WARN_MINUTES=60
DOWNLOAD_LEDGER_SAB_VANISHED_WARN_MINUTES=60
DOWNLOAD_LEDGER_IMPORT_WARN_MINUTES=300
DOWNLOAD_LEDGER_ESCALATE_MINUTES=720
DOWNLOAD_LEDGER_DISCOVERY_HOURS=24
DOWNLOAD_LEDGER_RETENTION_DAYS=7

# Automatically reconcile completed downloads that have no terminal event in
# the normal activity-history window. All checks use Arr database APIs only.
# The script never calls Arr filesystem/rescan endpoints and never stats media
# paths on the Unraid host.
DOWNLOAD_LEDGER_RECONCILE_ENABLED=true
DOWNLOAD_LEDGER_RECONCILE_CONFIRM_RUNS=2
DOWNLOAD_LEDGER_RECONCILE_MAX_RECORDS=50

# Allow a small timestamp skew between SAB queue time and Arr file dateAdded.
DOWNLOAD_LEDGER_RECONCILE_CLOCK_SKEW_SECONDS=300

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
SAB_SERVER_STATS=""

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
SAB_SERVER_STATS_OK=false
SAB_API_OK=false

SAB_FILESYSTEM_SCAN_OK=false
SAB_FILESYSTEM_SCAN_DEFERRED=false
SAB_FILESYSTEM_SCAN_REASON="Not evaluated"
SAB_HISTORY_CACHE_HIT=false
DOWNLOAD_LEDGER_SCAN_OK=false

SONARR_API_FAILURES=""
RADARR_API_FAILURES=""
SAB_API_FAILURES=""

HTTP_LAST_ERROR=""

SAB_PRIMARY_DOWNLOADS_FILE=""
SAB_PROGRESS_SEEN_FILE=""
SAB_PROGRESS_OBSERVATIONS_FILE=""
STATE_WRITE_ALERT_SENT=false
NOTIFICATION_ATTEMPTED=false
NOTIFICATION_LAST_ERROR=""
PREVIOUS_RUN_STARTED_AT=0
PREVIOUS_RUN_COMPLETED_AT=0
PREVIOUS_RUN_INCOMPLETE=false
PREVIOUS_RUN_GAP_MINUTES=0

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
SAB_JOB_PAUSED_COUNT=0
SAB_JOB_ENCRYPTED_COUNT=0
SAB_JOB_DUPLICATE_COUNT=0
SAB_SERVER_DEGRADED_COUNT=0
SAB_SERVER_LOW_SUCCESS_COUNT=0
SAB_CAPACITY_ISSUE_COUNT=0
SAB_FILESYSTEM_SCAN_DEFERRED_COUNT=0

DOWNLOAD_LEDGER_OBSERVATIONS_FILE=""
DOWNLOAD_LEDGER_ENROLLED_IDS_FILE=""
DOWNLOAD_LEDGER_ISSUE_COUNT=0
DOWNLOAD_LEDGER_NOT_REACHED_COUNT=0
DOWNLOAD_LEDGER_VANISHED_COUNT=0
DOWNLOAD_LEDGER_IMPORT_MISSING_COUNT=0
DOWNLOAD_LEDGER_HISTORICAL_RETIRED_COUNT=0
DOWNLOAD_LEDGER_RECONCILIATION_CHECKED_COUNT=0
DOWNLOAD_LEDGER_RECONCILIATION_PENDING_COUNT=0
DOWNLOAD_LEDGER_RECONCILED_COUNT=0
DOWNLOAD_LEDGER_RECONCILIATION_FAILED_COUNT=0
DOWNLOAD_LEDGER_RECONCILIATION_RESULTS_FILE=""
REMINDER_NOTIFICATION_COUNT=0
EVENT_REPEAT_SUPPRESSED_COUNT=0
EVENT_RESOLUTION_SUPPRESSED_COUNT=0
BOUNDED_REMINDER_SUPPRESSED_COUNT=0
FLAPPING_NOTIFICATION_COUNT=0
FLAPPING_SUPPRESSED_COUNT=0
ACKNOWLEDGED_SUPPRESSED_COUNT=0
NOTIFICATION_DECISION_EVENT="new"
RESOLVED_ISSUE_KEY=""
MONITOR_SCAN_FAILURE_COUNT=0
MONITOR_NOTIFICATION_FAILURE_COUNT=0
MONITOR_SCHEDULE_MISSED_COUNT=0

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

required_mount_available() {

    local path="$1"

    [ -z "$path" ] && return 0
    [ -d "$path" ] || return 1

    mountpoint -q -- "$path"
}

unraid_mover_running() {

    [ "$MOVER_GUARD_ENABLED" = true ] || return 1

    pgrep -f "$MOVER_PROCESS_PATTERN" >/dev/null 2>&1
}

ensure_state_storage_ready() {

    if required_mount_available "$STATE_REQUIRED_MOUNT"; then
        return 0
    fi

    local reason="Required state mount is unavailable: ${STATE_REQUIRED_MOUNT}"

    log "ERROR: $reason"

    # Do not let either the direct alert or its fallback logger touch LOG_FILE
    # below a missing mount. The Unraid syslog remains available independently.
    LOG_FILE=""

    if command -v logger >/dev/null 2>&1; then
        logger -t "arr_health_activity" -- "$reason" 2>/dev/null || true
    fi

    if [ "$SEND_NOTIFICATIONS" = true ] && [ -x "$NOTIFY" ]; then
        notify \
            "alert" \
            "ARR Health Monitor - State Mount Unavailable" \
            "${reason}. The monitor stopped before creating ${STATE_DIR}."
    fi

    exit 3
}

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

notification_fallback_alert() {

    local reason="$1"

    persistent_log "ERROR" "Notification command failure | ${reason}"

    if command -v logger >/dev/null 2>&1; then
        logger \
            -t "arr_health_activity" \
            -- \
            "Unraid notification command failure: ${reason}" \
            2>/dev/null || true
    fi
}

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

    NOTIFICATION_ATTEMPTED=true
    NOTIFICATION_LAST_ERROR=""

    if [ ! -x "$NOTIFY" ]; then

        log "WARNING: Unraid notification command unavailable"

        NOTIFICATION_LAST_ERROR="notification command is missing or not executable: ${NOTIFY}"
        notification_fallback_alert "$NOTIFICATION_LAST_ERROR"

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

    NOTIFICATION_LAST_ERROR="notification command returned a non-zero exit status: ${NOTIFY}"
    notification_fallback_alert "$NOTIFICATION_LAST_ERROR"

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

http_error_description() {

    local curl_rc="$1"
    local http_code="$2"

    case "$http_code" in

        401|403)
            echo "authentication rejected (HTTP ${http_code})"
            return
            ;;

        000|"")
            ;;

        *)
            echo "HTTP ${http_code}"
            return
            ;;
    esac

    case "$curl_rc" in

        6)
            echo "DNS resolution failed"
            ;;

        7)
            echo "connection refused or unreachable"
            ;;

        28)
            echo "connection timed out"
            ;;

        35|51|58|60|77|80|82|83|90|91)
            echo "TLS certificate or handshake failure"
            ;;

        *)
            echo "connection failed or timed out"
            ;;
    esac
}

http_failure_retryable() {

    local curl_rc="$1"
    local http_code="$2"
    local invalid_json="$3"

    [ "$invalid_json" = true ] && return 0

    case "$http_code" in

        408|425|429|5??)
            return 0
            ;;

        000|"")
            case "$curl_rc" in
                5|6|7|16|18|28|35|52|55|56|92)
                    return 0
                    ;;

                *)
                    return 1
                    ;;
            esac
            ;;

        *)
            return 1
            ;;
    esac
}

http_json_get() {

    local output="$1"
    local url="$2"
    shift 2

    local -a request_args=("$@")
    local attempt=1
    local max_attempts=$((HTTP_RETRY_COUNT + 1))
    local http_code=""
    local curl_rc=0
    local invalid_json=false
    local retry_after=""
    local retry_epoch=0
    local delay=0
    local safe_url="${url%%\?*}"
    local header_file

    header_file=$(mktemp "${TMP_DIR}/http-headers.XXXXXX") || {
        HTTP_LAST_ERROR="unable to create HTTP response-header file"
        return 1
    }

    HTTP_LAST_ERROR=""

    while (( attempt <= max_attempts )); do

        : >"$header_file"
        invalid_json=false

        http_code=$(curl \
            "${request_args[@]}" \
            --dump-header "$header_file" \
            "$url" \
            -o "$output" \
            --write-out '%{http_code}')
        curl_rc=$?

        if (( curl_rc == 0 )); then

            if jq empty "$output" >/dev/null 2>&1; then
                rm -f -- "$header_file" 2>/dev/null || true
                return 0
            fi

            invalid_json=true
            HTTP_LAST_ERROR="invalid JSON response"

        else

            HTTP_LAST_ERROR=$(http_error_description "$curl_rc" "$http_code")
        fi

        if (( attempt >= max_attempts )) ||
           ! http_failure_retryable "$curl_rc" "$http_code" "$invalid_json"
        then
            break
        fi

        retry_after=$(awk '
            tolower($0) ~ /^retry-after:/ {
                sub(/^[^:]*:[[:space:]]*/, "")
                gsub("\\r", "")
                print
            }
            ' "$header_file" | tail -n 1)

        if [[ "$retry_after" =~ ^[0-9]+$ ]]; then
            delay="$retry_after"
        elif [ -n "$retry_after" ]; then
            retry_epoch=$(date -d "$retry_after" '+%s' 2>/dev/null || echo 0)

            if [[ "$retry_epoch" =~ ^[0-9]+$ ]] &&
               (( retry_epoch > $(date +%s) ))
            then
                delay=$((retry_epoch - $(date +%s)))
            else
                delay=$((HTTP_RETRY_BASE_DELAY_SECONDS * attempt))
            fi
        else
            delay=$((HTTP_RETRY_BASE_DELAY_SECONDS * attempt))
        fi

        (( delay > HTTP_RETRY_MAX_DELAY_SECONDS )) && \
            delay="$HTTP_RETRY_MAX_DELAY_SECONDS"

        log "Temporary HTTP failure for ${safe_url}: ${HTTP_LAST_ERROR}; retrying in ${delay}s (${attempt}/${HTTP_RETRY_COUNT})"
        sleep "$delay"

        ((attempt++)) || true
    done

    rm -f -- "$header_file" 2>/dev/null || true

    return 1
}

api_get() {

    local url="$1"
    local api_key="$2"
    local output="$3"

    local -a request_args

    API_LAST_ERROR=""

    request_args=(
        --silent \
        --show-error \
        --fail \
        --connect-timeout "$HTTP_CONNECT_TIMEOUT_SECONDS" \
        --max-time "$HTTP_REQUEST_TIMEOUT_SECONDS" \
        -H "X-Api-Key: $api_key"
    )

    if ! http_json_get "$output" "$url" "${request_args[@]}"; then
        API_LAST_ERROR="$HTTP_LAST_ERROR"
        return 1
    fi

    return 0
}

sab_get() {

    local mode="$1"
    local output="$2"
    local start="${3:-0}"
    local limit="${4:-$SAB_HISTORY_LIMIT}"
    local last_history_update="${5:-0}"

    local url="${SAB_URL%/}/api"
    local -a request_args

    API_LAST_ERROR=""

    request_args=(
        --silent
        --show-error
        --fail
        --connect-timeout "$HTTP_CONNECT_TIMEOUT_SECONDS"
        --max-time "$HTTP_REQUEST_TIMEOUT_SECONDS"
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

            if [ "$mode" = "history" ] &&
               [[ "$last_history_update" =~ ^[0-9]+$ ]] &&
               (( last_history_update > 0 ))
            then
                request_args+=(
                    --data-urlencode "last_history_update=$last_history_update"
                )
            fi
            ;;

        status)
            request_args+=(
                --data-urlencode "skip_dashboard=1"
            )
            ;;
    esac

    if ! http_json_get "$output" "$url" "${request_args[@]}"; then
        API_LAST_ERROR="$HTTP_LAST_ERROR"
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
    local last_history_update=0
    local -a page_files=()

    SAB_HISTORY_CACHE_HIT=false

    if [ -f "$SAB_HISTORY_CACHE" ] &&
       jq -e '(.history | type) == "object"' "$SAB_HISTORY_CACHE" >/dev/null 2>&1
    then
        last_history_update=$(jq -r \
            '.history.last_history_update // 0' \
            "$SAB_HISTORY_CACHE")

        [[ "$last_history_update" =~ ^[0-9]+$ ]] || last_history_update=0
    fi

    while (( loaded < SAB_HISTORY_MAX_RECORDS )); do

        page_file="${TMP_DIR}/sab_history_page_${page}.json"

        if ! sab_get \
            history \
            "$page_file" \
            "$start" \
            "$SAB_HISTORY_LIMIT" \
            "$last_history_update"
        then
            return 1
        fi

        if (( page == 0 )) &&
           jq -e '.history == false' "$page_file" >/dev/null 2>&1
        then

            if [ -f "$SAB_HISTORY_CACHE" ] &&
               jq -e '(.history | type) == "object"' "$SAB_HISTORY_CACHE" >/dev/null 2>&1
            then
                cp -f -- "$SAB_HISTORY_CACHE" "$output" || return 1
                SAB_HISTORY_CACHE_HIT=true

                loaded=$(jq '.history.slots // [] | length' "$output")
                total=$(jq -r '.history.noofslots // (.history.slots // [] | length)' "$output")

                if (( loaded < total )); then
                    SAB_AUDIT_WINDOW_INCOMPLETE=true
                fi

                log "SABnzbd history unchanged; reused persistent history cache"
                return 0
            fi

            # A stale-update response without a usable cache cannot satisfy the
            # collectors. Repeat once without the conditional cursor.
            last_history_update=0

            if ! sab_get \
                history \
                "$page_file" \
                "$start" \
                "$SAB_HISTORY_LIMIT" \
                0
            then
                return 1
            fi
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
        last_history_update=0
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

    local cache_tmp="${SAB_HISTORY_CACHE}.tmp.$$"

    if cp -f -- "$output" "$cache_tmp" 2>/dev/null; then
        mv -f -- "$cache_tmp" "$SAB_HISTORY_CACHE" 2>/dev/null ||
            rm -f -- "$cache_tmp" 2>/dev/null || true
    else
        log "WARNING: Unable to refresh SABnzbd history cache"
    fi

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

queue_reason_records() {

    local item="$1"

    printf '%s' "$item" |
        jq -c '
            [
                (
                    (.errorMessage // "")
                    | select(type == "string" and length > 0)
                    | {
                        origin: "errorMessage",
                        label: "Queue error",
                        message: .
                    }
                ),
                (
                    .statusMessages[]?
                    |
                    if type == "string" then
                        select(length > 0)
                        | {
                            origin: "statusMessage",
                            label: "Status message",
                            message: .
                        }
                    else
                        . as $statusMessage
                        | ($statusMessage.title // "Status message") as $title
                        | [
                            ($statusMessage.message? // empty),
                            ($statusMessage.messages[]? // empty)
                        ]
                        | map(select(type == "string" and length > 0))
                        | unique
                        | if length > 0 then
                            .[]
                            | {
                                origin: "statusMessage",
                                label: ("Status message: " + $title),
                                message: .
                            }
                          elif ($title | length) > 0 then
                            {
                                origin: "statusMessage",
                                label: "Status message",
                                message: $title
                            }
                          else
                            empty
                          end
                    end
                )
            ]
            | unique_by(.message)
            | to_entries[]
            | .value + {index: .key}
        '
}

severity_rank() {

    case "$1" in
        ERROR) echo 3 ;;
        WARNING) echo 2 ;;
        INFO) echo 1 ;;
        *) echo 0 ;;
    esac
}

analyze_arr_queue_reasons() {

    local tracked_status="$1"
    local tracked_state="$2"
    local status="$3"
    local age="$4"
    local item="$5"
    local output="$6"

    local raw_file
    local classified_file
    local record
    local index
    local label
    local reason_message
    local classification
    local severity
    local rank
    local min_age
    local reason
    local normalized
    local eligible

    raw_file=$(mktemp "${TMP_DIR}/arr-queue-raw.XXXXXX") || return 1
    classified_file=$(mktemp "${TMP_DIR}/arr-queue-classified.XXXXXX") || return 1

    queue_reason_records "$item" >"$raw_file" || return 1

    if [ ! -s "$raw_file" ]; then
        jq -nc \
            --arg message "" \
            '{origin:"queueState",label:"Queue state",message:$message,index:0}' \
            >"$raw_file" || return 1
    fi

    : >"$classified_file"

    while IFS= read -r record; do

        [ -n "$record" ] || continue

        index=$(jq -r '.index // 0' <<<"$record")
        label=$(jq -r '.label // "Status message"' <<<"$record")
        reason_message=$(jq -r '.message // ""' <<<"$record")

        classification=$(classify_issue \
            "$tracked_status" \
            "$tracked_state" \
            "$status" \
            "$reason_message")

        if [ "$classification" = "NONE" ]; then
            severity="NONE"
            rank=0
            min_age=999999
            reason="No actionable classification matched this queue message"
            eligible=false
        else
            severity=$(classification_severity "$classification" "$age")
            rank=$(severity_rank "$severity")
            min_age=$(classification_min_age "$classification")
            reason=$(classification_reason "$classification" "$age")

            if (( age >= min_age )); then
                eligible=true
            else
                eligible=false
            fi
        fi

        normalized=$(normalize_arr_message "$(arr_pattern_raw_message \
            "$tracked_status" \
            "$tracked_state" \
            "$status" \
            "$reason_message")")

        jq -nc \
            --argjson index "$index" \
            --arg label "$label" \
            --arg message "$reason_message" \
            --arg normalizedMessage "$normalized" \
            --arg classification "$classification" \
            --arg severity "$severity" \
            --argjson severityRank "$rank" \
            --argjson minAge "$min_age" \
            --arg reason "$reason" \
            --argjson eligible "$eligible" \
            '{
                index: $index,
                label: $label,
                message: $message,
                normalizedMessage: $normalizedMessage,
                classification: $classification,
                severity: $severity,
                severityRank: $severityRank,
                minAge: $minAge,
                reason: $reason,
                eligible: $eligible
            }' \
            >>"$classified_file" || return 1

    done <"$raw_file"

    jq -s '
        . as $all
        | [$all[] | select(.classification != "NONE")] as $classified
        | [$classified[] | select(.eligible)] as $eligible
        | ($classified | sort_by(.severityRank, .index) | last) as $primaryAny
        | ($eligible | sort_by(.severityRank, .index) | last) as $primary
        | {
            hasIssue: (($classified | length) > 0),
            eligible: (($eligible | length) > 0),
            primaryAnyClassification: ($primaryAny.classification // "NONE"),
            primaryAnySeverity: ($primaryAny.severity // "NONE"),
            primaryClassification: ($primary.classification // "NONE"),
            primarySeverity: ($primary.severity // "NONE"),
            primaryReason: ($primary.reason // ""),
            allMessage: (
                [$all[].message | select(length > 0)]
                | unique
                | join(" | ")
            ),
            signatureMessage: (
                $all
                | map(
                    .classification
                    + "|"
                    + .severity
                    + "|eligible="
                    + (.eligible | tostring)
                    + "|"
                    + .normalizedMessage
                )
                | sort
                | unique
                | join(" || ")
            ),
            reasonDetail: (
                $all
                | map(
                    .label
                    + ": "
                    + (
                        if .classification == "NONE"
                        then "UNCLASSIFIED"
                        else .classification + " [" + .severity + "]"
                        end
                    )
                    + (
                        if .classification != "NONE" and (.eligible | not)
                        then " [pending until " + (.minAge | tostring) + "h]"
                        else ""
                        end
                    )
                    + "\n"
                    + .reason
                    + (
                        if .message != ""
                        then "\nArr detail: " + .message[0:1000]
                        else ""
                        end
                    )
                )
                | join("\n")
            ),
            reasons: $all
        }
        ' \
        "$classified_file" >"$output"
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
       'manual import|manual intervention|requires manual|manually import|needs manual|importblocked|import blocked|automatic import.*not possible|found matching (series|movie) via grab history.*automatic import is not possible'
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
  "version": 13,
  "issues": {},
  "sabProgress": {},
  "downloadLedger": {},
  "sabServerStats": {},
  "monitor": {
    "lastStartedAt": 0,
    "lastCompletedAt": 0,
    "lastStatus": "unknown",
    "notification": {
      "failed": false,
      "reason": "",
      "lastFailureAt": 0,
      "lastSuccessAt": 0
    }
  },
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
  "version": 13,
  "issues": {},
  "sabProgress": {},
  "downloadLedger": {},
  "sabServerStats": {},
  "monitor": {
    "lastStartedAt": 0,
    "lastCompletedAt": 0,
    "lastStatus": "unknown",
    "notification": {
      "failed": false,
      "reason": "",
      "lastFailureAt": 0,
      "lastSuccessAt": 0
    }
  },
  "telemetry": {
    "version": 1,
    "patterns": {}
  }
}
EOF
        fi
    fi
    ###########################################################################
    # STATE MIGRATION - v3.5
    #
    # Existing state is upgraded in place. Completion-only ledger records that
    # predate the discovery window are not enrolled. Any active historical
    # false-positive created from such a record is retired silently here so it
    # cannot generate either another reminder or a mass resolution email.
    ###########################################################################

    local migrate_tmp

    migrate_tmp="$TMP_DIR/state.migrate.json"

    if jq \
        --argjson migrationNow "$START_TIME" \
        --argjson discoverySeconds "$((DOWNLOAD_LEDGER_DISCOVERY_HOURS * 3600))" \
        '
        .version = 13
        |
        .issues = (.issues // {})
        |
        .issues |= with_entries(
            .value |= (
                .transitionTimestamps = (
                    .transitionTimestamps
                    // []
                )
                |
                .flappingUntil = (.flappingUntil // 0)
                |
                .flappingStartedAt = (.flappingStartedAt // 0)
                |
                .flapNotifiedAt = (.flapNotifiedAt // 0)
                |
                .lastNotifiedAt = (
                    if (.lastNotifiedAt // 0) > 0
                    then .lastNotifiedAt
                    elif (.notifiedSignature // "") != ""
                    then $migrationNow
                    else 0
                    end
                )
                |
                .reminderCount = (.reminderCount // 0)
                |
                .ackId = (.ackId // "")
                |
                .acknowledgedSignature = (
                    .acknowledgedSignature
                    // ""
                )
                |
                .acknowledgedAt = (.acknowledgedAt // 0)
                |
                .acknowledgementNote = (
                    .acknowledgementNote
                    // ""
                )
            )
        )
        |
        .sabProgress = (.sabProgress // {})
        |
        .downloadLedger = (.downloadLedger // {})
        |
        .issues as $issues
        |
        .downloadLedger |= with_entries(
            .key as $id
            |
            .value |= (
                . as $record
                |
                ($issues["FLOW:DOWNLOAD:" + $id] // {}) as $issue
                |
                (
                    (($record.arrGrabbedAt // 0) > 0)
                    or (($record.arrQueueLastSeen // 0) > 0)
                    or (($record.sabQueuedAt // 0) > 0)
                    or (($record.sabQueueLastSeen // 0) > 0)
                ) as $liveEvidence
                |
                (
                    (($issue.classification // "") == "DOWNLOAD_FLOW_IMPORT_MISSING")
                    and (($issue.firstSeen // 0) > 0)
                    and (($record.sabCompletedAt // 0) > 0)
                    and (($issue.firstSeen - $record.sabCompletedAt) >= 0)
                    and (($issue.firstSeen - $record.sabCompletedAt) <= $discoverySeconds)
                ) as $credibleExistingIssue
                |
                (
                    if (($record.flowEnrolled | type) == "boolean")
                    then $record.flowEnrolled
                    elif $liveEvidence
                    then true
                    elif $credibleExistingIssue
                    then true
                    elif (($record.sabCompletedAt // 0) >= ($migrationNow - $discoverySeconds))
                    then true
                    else false
                    end
                ) as $enrolled
                |
                .flowEnrolled = $enrolled
                |
                .flowEnrolledAt = (
                    if $enrolled
                    then
                        if (($record.flowEnrolledAt // 0) > 0)
                        then $record.flowEnrolledAt
                        elif (($issue.firstSeen // 0) > 0)
                        then $issue.firstSeen
                        elif (($record.lastSeen // 0) > 0)
                        then $record.lastSeen
                        else $migrationNow
                        end
                    else 0
                    end
                )
                |
                .flowEnrollmentReason = (
                    if $enrolled
                    then
                        if (($record.flowEnrollmentReason // "") != "")
                        then $record.flowEnrollmentReason
                        elif $liveEvidence
                        then "observed-live"
                        elif $credibleExistingIssue
                        then "migrated-active"
                        else "recent-completion"
                        end
                    else "historical-completion"
                    end
                )
                |
                .targets = (.targets // {})
                |
                .originalWarning = (.originalWarning // "")
                |
                .arrReconciledAt = (.arrReconciledAt // 0)
                |
                .reconciliationKind = (.reconciliationKind // "")
                |
                .reconciliationClassification = (
                    .reconciliationClassification // ""
                )
                |
                .reconciliationSeverity = (
                    .reconciliationSeverity // "INFO"
                )
                |
                .reconciliationDetail = (.reconciliationDetail // "")
                |
                .reconciliationEvidence = (
                    .reconciliationEvidence // ""
                )
                |
                .reconciliationFingerprint = (
                    .reconciliationFingerprint // ""
                )
                |
                .reconciliationCandidateFingerprint = (
                    .reconciliationCandidateFingerprint // ""
                )
                |
                .reconciliationCandidateRuns = (
                    .reconciliationCandidateRuns // 0
                )
                |
                .reconciliationCandidateFirstSeenAt = (
                    .reconciliationCandidateFirstSeenAt // 0
                )
                |
                .reconciliationCandidateLastSeenAt = (
                    .reconciliationCandidateLastSeenAt // 0
                )
                |
                .reconciliationLastCheckedAt = (
                    .reconciliationLastCheckedAt // 0
                )
                |
                .reconciliationNotifiedAt = (
                    .reconciliationNotifiedAt // 0
                )
            )
        )
        |
        .downloadLedger as $ledger
        |
        .issues |= with_entries(
            .key as $issueKey
            |
            ($issueKey | ltrimstr("FLOW:DOWNLOAD:")) as $downloadId
            |
            if
                ($issueKey | startswith("FLOW:DOWNLOAD:"))
                and ((.value.active // false) == true)
                and ((.value.classification // "") == "DOWNLOAD_FLOW_IMPORT_MISSING")
                and (($ledger[$downloadId].sabCompletedAt // 0) > 0)
                and ($ledger[$downloadId].flowEnrolled == false)
            then
                .value |= (
                    .active = false
                    |
                    .resolvedAt = $migrationNow
                    |
                    .lastSeen = $migrationNow
                    |
                    .notifiedSignature = ""
                    |
                    .lastNotifiedAt = 0
                    |
                    .reminderCount = 0
                    |
                    .acknowledgedSignature = ""
                    |
                    .acknowledgedAt = 0
                    |
                    .acknowledgementNote = ""
                    |
                    .historicalRetiredAt = $migrationNow
                    |
                    .historicalRetiredReason = "SAB completion predates exact-ledger discovery window"
                )
            else .
            end
        )
        |
        .sabServerStats = (.sabServerStats // {})
        |
        .monitor = (
            {
                lastStartedAt: 0,
                lastCompletedAt: 0,
                lastStatus: "unknown",
                notification: {
                    failed: false,
                    reason: "",
                    lastFailureAt: 0,
                    lastSuccessAt: 0
                }
            }
            * (.monitor // {})
        )
        |
        .monitor.notification = (
            {
                failed: false,
                reason: "",
                lastFailureAt: 0,
                lastSuccessAt: 0
            }
            * (.monitor.notification // {})
        )
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

        DOWNLOAD_LEDGER_HISTORICAL_RETIRED_COUNT=$(jq -r \
            --argjson migrationNow "$START_TIME" \
            '[
                .issues[]?
                | select((.historicalRetiredAt // 0) == $migrationNow)
            ]
            | length' \
            "$STATE_FILE")

        [[ "$DOWNLOAD_LEDGER_HISTORICAL_RETIRED_COUNT" =~ ^[0-9]+$ ]] || \
            DOWNLOAD_LEDGER_HISTORICAL_RETIRED_COUNT=0

        if (( DOWNLOAD_LEDGER_HISTORICAL_RETIRED_COUNT > 0 )); then
            log "Silently retired ${DOWNLOAD_LEDGER_HISTORICAL_RETIRED_COUNT} historical download-flow issue(s) from before ledger monitoring"
        fi

    else

        log "ERROR: Unable to migrate state file to schema version 13"
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
# MONITOR RUN / NOTIFICATION STATE - v3.1
###############################################################################

begin_monitor_run() {

    local now="$START_TIME"
    local tmp="${TMP_DIR}/state.monitor-start.json"

    PREVIOUS_RUN_STARTED_AT=$(jq -r '.monitor.lastStartedAt // 0' "$STATE_FILE")
    PREVIOUS_RUN_COMPLETED_AT=$(jq -r '.monitor.lastCompletedAt // 0' "$STATE_FILE")

    [[ "$PREVIOUS_RUN_STARTED_AT" =~ ^[0-9]+$ ]] || PREVIOUS_RUN_STARTED_AT=0
    [[ "$PREVIOUS_RUN_COMPLETED_AT" =~ ^[0-9]+$ ]] || PREVIOUS_RUN_COMPLETED_AT=0

    if (( PREVIOUS_RUN_STARTED_AT > 0 && now > PREVIOUS_RUN_STARTED_AT )); then
        PREVIOUS_RUN_GAP_MINUTES=$(( (now - PREVIOUS_RUN_STARTED_AT) / 60 ))
    fi

    if (( PREVIOUS_RUN_STARTED_AT > PREVIOUS_RUN_COMPLETED_AT )); then
        PREVIOUS_RUN_INCOMPLETE=true
    fi

    jq \
        --argjson now "$now" \
        '
        .version = 13
        |
        .monitor.lastStartedAt = $now
        |
        .monitor.lastStatus = "running"
        ' \
        "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp"
}

complete_monitor_run() {

    local status="$1"
    local now
    local tmp="${TMP_DIR}/state.monitor-complete.json"

    now=$(date +%s)

    jq \
        --arg status "$status" \
        --argjson now "$now" \
        '
        .monitor.lastCompletedAt = $now
        |
        .monitor.lastStatus = $status
        ' \
        "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp"
}

set_monitor_notification_state() {

    local failed="$1"
    local reason="${2:-}"
    local now
    local tmp="${TMP_DIR}/state.monitor-notification.json"

    now=$(date +%s)

    jq \
        --argjson failed "$failed" \
        --arg reason "$reason" \
        --argjson now "$now" \
        '
        .monitor.notification.failed = $failed
        |
        .monitor.notification.reason = $reason
        |
        if $failed then
            .monitor.notification.lastFailureAt = $now
        else
            .monitor.notification.lastSuccessAt = $now
        end
        ' \
        "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp"
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
        .version = 13
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

issue_ack_id() {

    printf '%s' "$1" |
        sha256sum |
        awk '{print substr($1, 1, 12)}'
}

issue_is_flapping() {

    local issue_key="$1"
    local now="${2:-$(date +%s)}"

    [ "$FLAP_DETECTION_ENABLED" = true ] || return 1

    jq -e \
        --arg key "$issue_key" \
        --argjson now "$now" \
        '(.issues[$key].flappingUntil // 0) > $now' \
        "$STATE_FILE" >/dev/null 2>&1
}

###############################################################################
# ISSUE STATE UPDATE
#
# If an issue was previously resolved and returns:
#
#   - firstSeen resets
#   - occurrences resets
#   - notifiedSignature resets unless a flapping suppression is active
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
    local issue_source="${9:-}"
    local normalized_message="${10:-}"

    local now
    local tmp
    local ack_id
    local transition_cutoff
    local flap_suppression_seconds

    now=$(date +%s)
    ack_id=$(issue_ack_id "$issue_key")
    transition_cutoff=$((now - FLAP_WINDOW_MINUTES * 60))
    flap_suppression_seconds=$((FLAP_SUPPRESSION_MINUTES * 60))

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
        --arg issueSource "$issue_source" \
        --arg normalizedMessage "$normalized_message" \
        --arg ackId "$ack_id" \
        --argjson now "$now" \
        --argjson flapEnabled "$FLAP_DETECTION_ENABLED" \
        --argjson transitionCutoff "$transition_cutoff" \
        --argjson flapThreshold "$FLAP_TRANSITION_THRESHOLD" \
        --argjson flapSuppressionSeconds "$flap_suppression_seconds" \
        '
        .version = 13
        |
        (.issues[$key] // {}) as $old
        |
        ($old.active // false) as $wasActive
        |
        (
            ($old.transitionTimestamps // [])
            | map(
                select(
                    type == "number"
                    and . >= $transitionCutoff
                )
              )
        ) as $recentTransitions
        |
        (
            if $wasActive
            then $recentTransitions
            else $recentTransitions + [$now]
            end
        ) as $transitions
        |
        (($old.flappingUntil // 0) > $now) as $wasFlapping
        |
        (
            $flapEnabled
            and ($wasActive | not)
            and (($transitions | length) >= $flapThreshold)
            and ($wasFlapping | not)
        ) as $startFlapping
        |
        .issues[$key] = {
            signature: $signature,

            notifiedSignature:
                (
                    if $wasActive or $wasFlapping
                    then ($old.notifiedSignature // "")
                    else ""
                    end
                ),

            lastNotifiedAt:
                (
                    if $wasActive or $wasFlapping
                    then
                        if ($old.lastNotifiedAt // 0) > 0
                        then $old.lastNotifiedAt
                        elif ($old.notifiedSignature // "") != ""
                        then $now
                        else 0
                        end
                    else 0
                    end
                ),

            reminderCount:
                (
                    if $wasActive or $wasFlapping
                    then ($old.reminderCount // 0)
                    else 0
                    end
                ),

            app: $app,
            title: $title,
            classification: $classification,
            severity: $severity,
            stage: $stage,
            message: $message,
            source: $issueSource,
            normalizedMessage: $normalizedMessage,

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
            resolvedAt: null,

            ackId: $ackId,
            acknowledgedSignature:
                (
                    if $wasActive
                       and ($old.signature // "") == $signature
                    then ($old.acknowledgedSignature // "")
                    else ""
                    end
                ),
            acknowledgedAt:
                (
                    if $wasActive
                       and ($old.signature // "") == $signature
                    then ($old.acknowledgedAt // 0)
                    else 0
                    end
                ),
            acknowledgementNote:
                (
                    if $wasActive
                       and ($old.signature // "") == $signature
                    then ($old.acknowledgementNote // "")
                    else ""
                    end
                ),

            transitionTimestamps: $transitions,
            flappingUntil:
                (
                    if $startFlapping
                    then $now + $flapSuppressionSeconds
                    else ($old.flappingUntil // 0)
                    end
                ),
            flappingStartedAt:
                (
                    if $startFlapping
                    then $now
                    else ($old.flappingStartedAt // 0)
                    end
                ),
            flapNotifiedAt: ($old.flapNotifiedAt // 0)
        }
        ' \
        "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp"

    mark_seen "$issue_key"
}

###############################################################################
# NOTIFICATION DEDUP
###############################################################################

reminder_policy_for_classification() {

    local classification="$1"
    local severity="$2"
    local mode="persistent"
    local interval_hours=0
    local maximum="$REMINDER_MAX_COUNT"

    case "$severity" in
        ERROR)
            interval_hours="$ERROR_REMINDER_INTERVAL_HOURS"
            ;;

        WARNING)
            interval_hours="$WARNING_REMINDER_INTERVAL_HOURS"
            ;;
    esac

    case "$classification" in

        # These describe an event that already happened. The same event may
        # remain inside an API history/warning window for several runs, but it
        # does not become more actionable because it was observed again.
        ARR_DOWNLOAD_FAILED_HISTORY|\
        SAB_DOWNLOAD_FAILED_*|\
        SAB_ERROR|\
        SAB_WARNING|\
        MONITOR_SCHEDULE_MISSED|\
        DOWNLOAD_FLOW_RECONCILED_*)
            mode="once"
            interval_hours=0
            maximum=0
            ;;

        # These are exact workflow evidence gaps. Reconciliation is attempted
        # first; if it cannot prove an outcome, retain a small daily reminder
        # budget so a genuine missing import is not hidden indefinitely.
        DOWNLOAD_FLOW_IMPORT_MISSING|\
        DOWNLOAD_FLOW_NOT_REACHED_SAB|\
        DOWNLOAD_FLOW_SAB_VANISHED)
            mode="bounded"
            interval_hours="$DOWNLOAD_FLOW_REMINDER_INTERVAL_HOURS"
            maximum="$DOWNLOAD_FLOW_REMINDER_MAX_COUNT"
            ;;

        # These are time-window, policy, or statistical observations. They
        # remain visible in state/logs after the reminder budget is exhausted.
        ACTIVITY_FLOW_ANOMALY|\
        CF_REJECT|\
        CF_REJECT_*|\
        UPGRADE_REJECT|\
        TBA_METADATA|\
        SAB_STALLED_*|\
        SAB_JOB_DUPLICATE|\
        SAB_JOB_PAUSED|\
        SAB_CATEGORY_UNKNOWN|\
        SAB_SERVER_LOW_ARTICLE_SUCCESS|\
        SAB_STRANDED_*)
            mode="bounded"
            maximum="$HEURISTIC_REMINDER_MAX_COUNT"

            case "$severity" in
                ERROR)
                    interval_hours="$HEURISTIC_ERROR_REMINDER_INTERVAL_HOURS"
                    ;;

                WARNING)
                    interval_hours="$HEURISTIC_WARNING_REMINDER_INTERVAL_HOURS"
                    ;;
            esac
            ;;
    esac

    printf '%s\t%s\t%s\n' "$mode" "$interval_hours" "$maximum"
}

should_notify() {

    local issue_key="$1"
    local signature="$2"
    local severity="${3:-}"

    local lifecycle
    local previous
    local last_notified_at
    local reminder_count
    local acknowledged_signature
    local flapping_until
    local flapping_started_at
    local flap_notified_at
    local stored_severity
    local stored_classification
    local now
    local reminder_mode="persistent"
    local reminder_interval_hours=0
    local reminder_maximum="$REMINDER_MAX_COUNT"

    NOTIFICATION_DECISION_EVENT="new"
    now=$(date +%s)

    lifecycle=$(jq -r \
        --arg key "$issue_key" \
        '
        (.issues[$key] // {})
        | [
            (.notifiedSignature // ""),
            ((.lastNotifiedAt // 0) | tostring),
            ((.reminderCount // 0) | tostring),
            (.acknowledgedSignature // ""),
            ((.flappingUntil // 0) | tostring),
            ((.flappingStartedAt // 0) | tostring),
            ((.flapNotifiedAt // 0) | tostring),
            (.severity // ""),
            (.classification // "")
          ]
        | join("|")
        ' "$STATE_FILE")

    IFS='|' read -r \
        previous \
        last_notified_at \
        reminder_count \
        acknowledged_signature \
        flapping_until \
        flapping_started_at \
        flap_notified_at \
        stored_severity \
        stored_classification \
        <<<"$lifecycle"

    [[ "$last_notified_at" =~ ^[0-9]+$ ]] || last_notified_at=0
    [[ "$reminder_count" =~ ^[0-9]+$ ]] || reminder_count=0
    [[ "$flapping_until" =~ ^[0-9]+$ ]] || flapping_until=0
    [[ "$flapping_started_at" =~ ^[0-9]+$ ]] || flapping_started_at=0
    [[ "$flap_notified_at" =~ ^[0-9]+$ ]] || flap_notified_at=0

    [ -n "$severity" ] || severity="$stored_severity"

    if [ -n "$acknowledged_signature" ] &&
       [ "$acknowledged_signature" = "$signature" ]
    then
        ((ACKNOWLEDGED_SUPPRESSED_COUNT++)) || true
        ((NOTIFICATIONS_SUPPRESSED++)) || true
        return 1
    fi

    if (( flapping_until > now && flap_notified_at < flapping_started_at )); then
        NOTIFICATION_DECISION_EVENT="flapping"
        ((FLAPPING_NOTIFICATION_COUNT++)) || true
        return 0
    fi

    if [ "$previous" != "$signature" ]; then
        return 0
    fi

    if (( flapping_until > now )); then
        ((FLAPPING_SUPPRESSED_COUNT++)) || true
        ((NOTIFICATIONS_SUPPRESSED++)) || true
        return 1
    fi

    if [ "$NOTIFY_ONCE" != true ]; then
        return 0
    fi

    if [ "$REMINDERS_ENABLED" = true ]; then

        IFS=$'\t' read -r \
            reminder_mode \
            reminder_interval_hours \
            reminder_maximum \
            < <(reminder_policy_for_classification \
                "$stored_classification" \
                "$severity")

        [[ "$reminder_interval_hours" =~ ^[0-9]+$ ]] || reminder_interval_hours=0
        [[ "$reminder_maximum" =~ ^[0-9]+$ ]] || reminder_maximum=0

        if [ "$reminder_mode" = "once" ]; then
            ((EVENT_REPEAT_SUPPRESSED_COUNT++)) || true
            ((NOTIFICATIONS_SUPPRESSED++)) || true
            return 1
        fi

        if (( reminder_interval_hours > 0 && last_notified_at > 0 )) &&
           (( now - last_notified_at >= reminder_interval_hours * 3600 )) &&
           { (( reminder_maximum == 0 )) ||
             (( reminder_count < reminder_maximum )); }
        then
            NOTIFICATION_DECISION_EVENT="reminder"
            ((REMINDER_NOTIFICATION_COUNT++)) || true
            return 0
        fi

        if [ "$reminder_mode" = "bounded" ] &&
           (( reminder_maximum > 0 && reminder_count >= reminder_maximum ))
        then
            ((BOUNDED_REMINDER_SUPPRESSED_COUNT++)) || true
        fi
    fi

    ((NOTIFICATIONS_SUPPRESSED++)) || true
    return 1
}

mark_notified() {

    local issue_key="$1"
    local signature="$2"
    local event="${3:-new}"

    local tmp
    local now

    tmp="$TMP_DIR/state.notified.json"
    now=$(date +%s)

    jq \
        --arg key "$issue_key" \
        --arg signature "$signature" \
        --arg event "$event" \
        --argjson now "$now" \
        '
        if $event == "reconciled" and ($key | startswith("FLOW:RECONCILIATION:"))
        then
            ($key | ltrimstr("FLOW:RECONCILIATION:") | ascii_downcase) as $downloadId
            |
            if .downloadLedger[$downloadId]
            then
                .downloadLedger[$downloadId].reconciliationNotifiedAt = (
                    [
                        $now,
                        (.downloadLedger[$downloadId].arrReconciledAt // 0)
                    ]
                    | max
                )
            else .
            end
        elif .issues[$key] then
            .issues[$key].notifiedSignature = $signature
            |
            .issues[$key].lastNotifiedAt = $now
            |
            .issues[$key].reminderCount = (
                if $event == "reminder"
                then ((.issues[$key].reminderCount // 0) + 1)
                elif $event == "resolved"
                then (.issues[$key].reminderCount // 0)
                else 0
                end
            )
            |
            .issues[$key].flapNotifiedAt = (
                if $event == "flapping"
                then $now
                else (.issues[$key].flapNotifiedAt // 0)
                end
            )
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
    local transition_cutoff
    local flap_suppression_seconds

    now=$(date +%s)
    transition_cutoff=$((now - FLAP_WINDOW_MINUTES * 60))
    flap_suppression_seconds=$((FLAP_SUPPRESSION_MINUTES * 60))

    tmp="$TMP_DIR/state.resolved.json"

    jq \
        --arg key "$issue_key" \
        --argjson now "$now" \
        --argjson flapEnabled "$FLAP_DETECTION_ENABLED" \
        --argjson transitionCutoff "$transition_cutoff" \
        --argjson flapThreshold "$FLAP_TRANSITION_THRESHOLD" \
        --argjson flapSuppressionSeconds "$flap_suppression_seconds" \
        '
        if .issues[$key] then
            (.issues[$key] // {}) as $old
            |
            ($old.active // false) as $wasActive
            |
            (
                ($old.transitionTimestamps // [])
                | map(
                    select(
                        type == "number"
                        and . >= $transitionCutoff
                    )
                  )
            ) as $recentTransitions
            |
            (
                if $wasActive
                then $recentTransitions + [$now]
                else $recentTransitions
                end
            ) as $transitions
            |
            (($old.flappingUntil // 0) > $now) as $wasFlapping
            |
            (
                $flapEnabled
                and $wasActive
                and (($transitions | length) >= $flapThreshold)
                and ($wasFlapping | not)
            ) as $startFlapping
            |
            .issues[$key].active = false
            |
            .issues[$key].resolvedAt = $now
            |
            .issues[$key].transitionTimestamps = $transitions
            |
            .issues[$key].flappingUntil = (
                if $startFlapping
                then $now + $flapSuppressionSeconds
                else ($old.flappingUntil // 0)
                end
            )
            |
            .issues[$key].flappingStartedAt = (
                if $startFlapping
                then $now
                else ($old.flappingStartedAt // 0)
                end
            )
            |
            .issues[$key].acknowledgedSignature = ""
            |
            .issues[$key].acknowledgedAt = 0
            |
            .issues[$key].acknowledgementNote = ""

        else
            .
        end
        ' \
        "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp"
}

###############################################################################
# OPERATOR ACKNOWLEDGEMENT - v3.3
###############################################################################

resolve_active_issue_selector() {

    local selector="$1"
    local record
    local issue_key
    local ack_id
    local -a matches=()

    RESOLVED_ISSUE_KEY=""

    while IFS= read -r record; do

        [ -n "$record" ] || continue

        issue_key=$(jq -r '.key' <<<"$record")
        ack_id=$(jq -r '.value.ackId // ""' <<<"$record")

        [ -n "$ack_id" ] || ack_id=$(issue_ack_id "$issue_key")

        if [ "$issue_key" = "$selector" ] ||
           [[ "$ack_id" == "$selector"* ]]
        then
            matches+=("$issue_key")
        fi

    done < <(
        jq -c '
            .issues
            | to_entries[]?
            | select(.value.active == true)
            ' "$STATE_FILE"
    )

    case "${#matches[@]}" in
        1)
            RESOLVED_ISSUE_KEY="${matches[0]}"
            return 0
            ;;

        0)
            log "ERROR: No active issue matches acknowledgement selector: $selector"
            return 1
            ;;

        *)
            log "ERROR: Acknowledgement selector is ambiguous: $selector"
            return 1
            ;;
    esac
}

acknowledge_active_issue() {

    local selector="$1"
    local note="${2:-}"
    local issue_key
    local ack_id
    local now
    local tmp="${TMP_DIR}/state.acknowledged.json"

    resolve_active_issue_selector "$selector" || return 1
    issue_key="$RESOLVED_ISSUE_KEY"
    ack_id=$(issue_ack_id "$issue_key")
    now=$(date +%s)

    jq \
        --arg key "$issue_key" \
        --arg ackId "$ack_id" \
        --arg note "$note" \
        --argjson now "$now" \
        '
        if (.issues[$key].active // false) == true then
            .issues[$key].ackId = $ackId
            |
            .issues[$key].acknowledgedSignature = (
                .issues[$key].signature
                // ""
            )
            |
            .issues[$key].acknowledgedAt = $now
            |
            .issues[$key].acknowledgementNote = $note
        else
            .
        end
        ' "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp" || return 1

    persistent_log \
        "ACKNOWLEDGED" \
        "issue=${issue_key} | ack_id=${ack_id} | note=${note:-none}"

    printf 'Acknowledged active issue %s (%s)\n' "$ack_id" "$issue_key"
}

unacknowledge_active_issue() {

    local selector="$1"
    local issue_key
    local ack_id
    local tmp="${TMP_DIR}/state.unacknowledged.json"

    resolve_active_issue_selector "$selector" || return 1
    issue_key="$RESOLVED_ISSUE_KEY"
    ack_id=$(issue_ack_id "$issue_key")

    jq \
        --arg key "$issue_key" \
        '
        if .issues[$key] then
            .issues[$key].acknowledgedSignature = ""
            |
            .issues[$key].acknowledgedAt = 0
            |
            .issues[$key].acknowledgementNote = ""
        else
            .
        end
        ' "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp" || return 1

    persistent_log \
        "UNACKNOWLEDGED" \
        "issue=${issue_key} | ack_id=${ack_id}"

    printf 'Removed acknowledgement from %s (%s)\n' "$ack_id" "$issue_key"
}

list_active_issues() {

    local record
    local issue_key
    local ack_id
    local acknowledged

    printf 'ACK ID       SEVERITY  SOURCE     ACKNOWLEDGED  CLASSIFICATION  TITLE\n'

    while IFS= read -r record; do

        [ -n "$record" ] || continue

        issue_key=$(jq -r '.key' <<<"$record")
        ack_id=$(jq -r '.value.ackId // ""' <<<"$record")
        [ -n "$ack_id" ] || ack_id=$(issue_ack_id "$issue_key")

        acknowledged=$(jq -r '
            (
                (.value.acknowledgedSignature // "") != ""
                and
                (.value.acknowledgedSignature == .value.signature)
            )
            | tostring
            ' <<<"$record")

        jq -r \
            --arg ackId "$ack_id" \
            --arg acknowledged "$acknowledged" \
            '[
                $ackId,
                (.value.severity // "UNKNOWN"),
                (.value.app // "Unknown"),
                $acknowledged,
                (.value.classification // "UNKNOWN"),
                (.value.title // "Unknown")
             ]
             | @tsv' <<<"$record"

    done < <(
        jq -c '
            .issues
            | to_entries[]?
            | select(.value.active == true)
            ' "$STATE_FILE"
    )
}

print_lifecycle_command_help() {

    printf '%s\n' \
        'ARR Health Monitor lifecycle commands:' \
        '  --list-active' \
        '  --ack ACK_ID [note]' \
        '  --unack ACK_ID' \
        '' \
        'Acknowledgements apply only to the current issue signature and clear on resolution or material change.'
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

                FLOW:DOWNLOAD:*)
                    [ "$DOWNLOAD_LEDGER_SCAN_OK" = true ] &&
                    [ "$SONARR_AUDIT_OK" = true ] &&
                    [ "$SONARR_QUEUE_OK" = true ] &&
                    [ "$SAB_HISTORY_OK" = true ] &&
                    [ "$SAB_QUEUE_OK" = true ]
                    ;;

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

                FLOW:DOWNLOAD:*)
                    [ "$DOWNLOAD_LEDGER_SCAN_OK" = true ] &&
                    [ "$RADARR_AUDIT_OK" = true ] &&
                    [ "$RADARR_QUEUE_OK" = true ] &&
                    [ "$SAB_HISTORY_OK" = true ] &&
                    [ "$SAB_QUEUE_OK" = true ]
                    ;;

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

                SABnzbd:queue:*|SABnzbd:category:*|SABnzbd:capacity:*)
                    [ "$SAB_QUEUE_OK" = true ]
                    ;;

                SABnzbd:history:*)
                    [ "$SAB_HISTORY_OK" = true ]
                    ;;

                SABnzbd:server-stats-api|SABnzbd:server-quality:*)
                    [ "$SAB_SERVER_STATS_OK" = true ]
                    ;;

                *)
                    # Existing stranded-file issues depend on SAB history and
                    # successful knowledge of both Arr queues.
                    [ "$SAB_HISTORY_OK" = true ] &&
                    [ "$SONARR_QUEUE_OK" = true ] &&
                    [ "$RADARR_QUEUE_OK" = true ] &&
                    [ "$SAB_FILESYSTEM_SCAN_OK" = true ]
                    ;;
            esac
            ;;

        Monitor)

            # Monitor-generated issues are marked seen only while their
            # condition is present. A completed current run is sufficient to
            # resolve schedule/scan issues; notification recovery is persisted
            # only after the notification command succeeds.
            case "$issue_key" in

                Monitor:notification-command)
                    jq -e \
                        '(.monitor.notification.failed // false) == false' \
                        "$STATE_FILE" \
                        >/dev/null 2>&1
                    ;;

                *)
                    return 0
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
        local severity
        local notification_policy_mode
        local automatic_reconciliation=false
        local reconciliation_kind=""

        issue_key=$(echo "$record" | jq -r '.key')
        source=$(echo "$record" | jq -r '.value.app // ""')
        title=$(echo "$record" | jq -r '.value.title // "Unknown"')
        classification=$(echo "$record" | jq -r '.value.classification // "Unknown"')
        severity=$(echo "$record" | jq -r '.value.severity // "INFO"')
        notified_signature=$(echo "$record" | jq -r '.value.notifiedSignature // ""')

        notification_policy_mode=$(reminder_policy_for_classification \
            "$classification" \
            "$severity")
        notification_policy_mode=${notification_policy_mode%%$'\t'*}

        case "$issue_key" in
            FLOW:DOWNLOAD:*)
                local reconciliation_download_id="${issue_key#FLOW:DOWNLOAD:}"
                reconciliation_kind=$(jq -r \
                    --arg id "${reconciliation_download_id,,}" \
                    'if (.downloadLedger[$id].arrReconciledAt // 0) > 0
                     then (.downloadLedger[$id].reconciliationKind // "automatic")
                     else ""
                     end' \
                    "$STATE_FILE")
                [ -n "$reconciliation_kind" ] && automatic_reconciliation=true
                ;;
        esac

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
                "${source} | ${classification} | ${title} | lifetime=${lifetime_hours}h | automatic_reconciliation=${automatic_reconciliation} | reconciliation_method=${reconciliation_kind:-none}"

            if issue_is_flapping "$issue_key" "$now"; then

                ((FLAPPING_SUPPRESSED_COUNT++)) || true
                ((NOTIFICATIONS_SUPPRESSED++)) || true
                log "Resolution notification suppressed during flapping episode: $issue_key"

            elif [ "$automatic_reconciliation" = true ]; then

                # A richer, one-time AUTO-RECONCILED record is already queued.
                # Suppress the generic "condition no longer present" duplicate.
                log "Generic resolution notification replaced by automatic reconciliation detail: $issue_key"

            elif [ "$notification_policy_mode" = "once" ]; then

                # An event aging out of a history/warning window is not a
                # verified recovery. Keep the lifecycle transition in state and
                # logs without generating a misleading second email.
                if [ "$SEND_RESOLUTION_NOTIFICATIONS" = true ] &&
                   [ -n "$notified_signature" ]
                then
                    ((EVENT_RESOLUTION_SUPPRESSED_COUNT++)) || true
                    ((NOTIFICATIONS_SUPPRESSED++)) || true
                fi

                log "Resolution notification suppressed for notification-once event: $issue_key"

            elif [ "$SEND_RESOLUTION_NOTIFICATIONS" = true ] &&
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
    local event="${9:-${NOTIFICATION_DECISION_EVENT:-new}}"
    local ack_id

    ack_id=$(issue_ack_id "$issue_key")

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
        --arg ackId "$ack_id" \
        '{
            issueKey: $issueKey,
            signature: $signature,
            source: $source,
            title: $title,
            classification: $classification,
            severity: $severity,
            age: $age,
            detail: $detail,
            event: $event,
            ackId: $ackId
        }' \
        >>"$NOTIFICATION_BATCH"

    ((BATCHED_NOTIFICATION_ITEMS++)) || true

    NOTIFICATION_DECISION_EVENT="new"

    log "Queued issue for grouped notification"
}

batch_highest_severity() {

    local batch_file="${1:-$NOTIFICATION_BATCH}"

    if jq -e \
        'select(.severity == "ERROR" and .event != "resolved")' \
        "$batch_file" \
        >/dev/null 2>&1
    then
        echo "ERROR"
        return
    fi

    if jq -e \
        'select(.severity == "WARNING" and .event != "resolved")' \
        "$batch_file" \
        >/dev/null 2>&1
    then
        echo "WARNING"
        return
    fi

    echo "INFO"
}

notification_record_text() {

    local record="$1"
    local rendered

    rendered=$(jq -r '
        (.event // "new") as $event
        | (.detail // "") as $detail
        | (.ackId // "") as $ackId
        | "- [" + (.source // "Unknown") + "] " + (.title // "Unknown")
          + "\n  "
          + (.classification // "UNKNOWN")
          + (
                if $event == "resolved"
                then " [RESOLVED]"
                elif $event == "reconciled"
                then " [" + (.severity // "INFO") + "] [AUTO-RECONCILED]"
                elif $event == "reminder"
                then " [" + (.severity // "INFO") + "] [REMINDER]"
                elif $event == "flapping"
                then " [" + (.severity // "INFO") + "] [FLAPPING]"
                else " [" + (.severity // "INFO") + "]"
            end
          )
          + (
                if ($event == "new" or $event == "reminder" or $event == "flapping") and $ackId != ""
                then "\n  Ack ID: " + $ackId
                else ""
            end
          )
          + (
                if $event == "flapping"
                then "\n  Lifecycle: repeated raise/resolve transitions detected; routine notifications are temporarily suppressed."
                else ""
            end
          )
          + (
                if (.age // "") != "" and (.age // "") != "0"
                then "\n  Age: " + (.age | tostring) + "h"
                else ""
            end
          )
          + (
                if $detail != ""
                then "\n  " + ($detail | gsub("\n"; "\n  "))
                else ""
            end
          )
        ' <<<"$record")

    printf '%s' "$rendered" |
        jq -Rs -r \
            --argjson maximum "$GROUP_NOTIFICATION_ITEM_MAX_CHARS" \
            '
            if length > $maximum
            then .[0:$maximum] + "\n  Detail shortened; see persistent log."
            else .
            end
            '
}

notification_text_bytes() {

    printf '%s' "$1" | wc -c | tr -d ' '
}

send_notification_page() {

    local page_file="$1"
    local page_number="$2"
    local page_total="$3"
    local batch_total="$4"

    local page_items
    local highest
    local importance
    local description
    local info_new
    local warning_new
    local error_new
    local resolved
    local reconciled
    local reminders
    local flapping
    local body=""
    local record
    local entry

    page_items=$(wc -l <"$page_file" | tr -d ' ')
    highest=$(batch_highest_severity "$page_file")

    info_new=$(jq -s \
        '[.[] | select(.severity == "INFO" and .event != "resolved")] | length' \
        "$page_file")
    warning_new=$(jq -s \
        '[.[] | select(.severity == "WARNING" and .event != "resolved")] | length' \
        "$page_file")
    error_new=$(jq -s \
        '[.[] | select(.severity == "ERROR" and .event != "resolved")] | length' \
        "$page_file")
    resolved=$(jq -s \
        '[.[] | select(.event == "resolved")] | length' \
        "$page_file")
    reconciled=$(jq -s \
        '[.[] | select(.event == "reconciled")] | length' \
        "$page_file")
    reminders=$(jq -s \
        '[.[] | select(.event == "reminder")] | length' \
        "$page_file")
    flapping=$(jq -s \
        '[.[] | select(.event == "flapping")] | length' \
        "$page_file")

    case "$highest" in

        ERROR)
            importance="alert"
            ;;

        WARNING)
            importance="warning"
            ;;

        *)
            importance="normal"
            ;;
    esac

    description="ARR Health Monitor - ${batch_total} Update(s)"

    if (( page_total > 1 )); then
        description+=" - Batch ${page_number}/${page_total}"
    fi

    body="Health/activity updates: ${batch_total}"$'\n'
    body+="This batch: ${page_items} | Info: ${info_new} | Warnings: ${warning_new} | Errors: ${error_new} | Resolved: ${resolved} | Auto-reconciled: ${reconciled}"$'\n'
    body+="Reminders: ${reminders} | Flapping: ${flapping}"$'\n'

    if (( page_total > 1 )); then
        body+="Batch: ${page_number}/${page_total}"$'\n'
    fi

    body+=$'\n'

    while IFS= read -r record; do

        [ -n "$record" ] || continue

        entry=$(notification_record_text "$record")
        body+="$entry"$'\n\n'

    done <"$page_file"

    body+="Monitor schedule: every five minutes recommended"$'\n'
    body+="Runtime: $(runtime)"

    notify \
        "$importance" \
        "$description" \
        "$body"

    local notify_rc=$?

    if (( notify_rc != 0 )); then
        return "$notify_rc"
    fi

    # Only records actually included in this successfully delivered page are
    # marked delivered. Later or failed pages remain eligible on the next run.
    while IFS= read -r record; do

        [ -n "$record" ] || continue

        local issue_key
        local signature
        local event

        issue_key=$(jq -r '.issueKey' <<<"$record")
        signature=$(jq -r '.signature' <<<"$record")
        event=$(jq -r '.event // "new"' <<<"$record")

        if ! mark_notified "$issue_key" "$signature" "$event"; then
            log "WARNING: Failed to mark issue notified: $issue_key"
        fi

    done <"$page_file"

    log "Grouped notification batch ${page_number}/${page_total} sent successfully"
    log "Issues included in batch: $page_items"

    return 0
}

send_grouped_notification() {

    [ -f "$NOTIFICATION_BATCH" ] || return 0
    [ -s "$NOTIFICATION_BATCH" ] || return 0

    local total
    local sorted_file
    local page_file
    local page_total
    local page_number
    local current_items=0
    local current_bytes=1024
    local record
    local entry
    local entry_bytes
    local page_rc
    local -a page_files=()

    total=$(wc -l <"$NOTIFICATION_BATCH" | tr -d ' ')

    (( total > 0 )) || return 0

    sorted_file="${TMP_DIR}/notification_batch.sorted.jsonl"

    jq -sc '
        sort_by(
            (
                if (.event // "new") == "resolved" then 3
                elif (.severity // "INFO") == "ERROR" then 0
                elif (.severity // "INFO") == "WARNING" then 1
                else 2
                end
            ),
            (.source // ""),
            (.title // ""),
            (.classification // "")
        )
        | .[]
        ' "$NOTIFICATION_BATCH" >"$sorted_file" || return 1

    page_file=$(mktemp "${TMP_DIR}/notification-page.XXXXXX") || return 1
    : >"$page_file"

    while IFS= read -r record; do

        [ -n "$record" ] || continue

        entry=$(notification_record_text "$record")
        entry_bytes=$(notification_text_bytes "$entry")

        if (( current_items > 0 )) &&
           { (( current_items >= GROUP_NOTIFICATION_MAX_ITEMS )) ||
             (( current_bytes + entry_bytes > GROUP_NOTIFICATION_MAX_BYTES )); }
        then
            page_files+=("$page_file")
            page_file=$(mktemp "${TMP_DIR}/notification-page.XXXXXX") || return 1
            : >"$page_file"
            current_items=0
            current_bytes=1024
        fi

        printf '%s\n' "$record" >>"$page_file"
        ((current_items++)) || true
        current_bytes=$((current_bytes + entry_bytes + 2))

    done <"$sorted_file"

    if (( current_items > 0 )); then
        page_files+=("$page_file")
    fi

    page_total=${#page_files[@]}
    page_number=0

    for page_file in "${page_files[@]}"; do

        ((page_number++)) || true

        send_notification_page \
            "$page_file" \
            "$page_number" \
            "$page_total" \
            "$total"
        page_rc=$?

        if (( page_rc == 2 )); then
            log "Grouped notifications disabled"
            log "New issues that would be grouped: $total"
            return 0
        fi

        if (( page_rc != 0 )); then
            log "ERROR: Grouped notification batch ${page_number}/${page_total} failed"
            log "Failed and unsent batches will remain eligible"
            return 1
        fi
    done

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
    local issue_source="${13:-}"
    local normalized_message="${14:-}"

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

    local signature_message="$message"

    if [ -n "$normalized_message" ]; then
        signature_message="$normalized_message"
    fi

    signature=$(issue_signature \
        "$source" \
        "$issue_key" \
        "$classification" \
        "$severity" \
        "$stage" \
        "$signature_message")

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
        "$message" \
        "$issue_source" \
        "$normalized_message"
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
        local normalized_message
        local message
        local wiki_url
        local classification
        local severity
        local notify_runs
        local issue_hash
        local detail

        health_source=$(jq -r '.source // "Unknown health check"' <<<"$record")
        health_type=$(jq -r '.type // "warning"' <<<"$record")
        message=$(jq -r '.message // "No health detail supplied"' <<<"$record")
        wiki_url=$(jq -r '.wikiUrl // ""' <<<"$record")
        normalized_message=$(normalize_arr_message "$message")

        case "${health_type,,}" in

            error)
                classification="ARR_HEALTH_ERROR"
                severity="ERROR"
                notify_runs="$ARR_HEALTH_ERROR_NOTIFY_RUNS"
                ;;

            warning)
                classification="ARR_HEALTH_WARNING"
                severity="WARNING"
                notify_runs="$ARR_HEALTH_WARNING_NOTIFY_RUNS"
                ;;

            notice)
                classification="ARR_HEALTH_NOTICE"
                severity="INFO"
                notify_runs="$ARR_HEALTH_NOTICE_NOTIFY_RUNS"
                ;;

            *)
                classification="ARR_HEALTH_UNKNOWN_TYPE"
                severity="WARNING"
                notify_runs="$ARR_HEALTH_UNKNOWN_NOTIFY_RUNS"
                ;;
        esac

        issue_hash=$(stable_issue_hash "${app}|${health_source}|${normalized_message}")
        detail="$message"

        if [ "$classification" = "ARR_HEALTH_UNKNOWN_TYPE" ]; then
            detail+=$'\n'
            detail+="Reported health type: ${health_type}"
        fi

        if [ -n "$wiki_url" ]; then
            detail+=$'\n'
            detail+="Help: ${wiki_url}"
        fi

        log "${app} native health issue: ${health_source} (${health_type})"

        record_normalized_issue \
            "${app}:health:${issue_hash}" \
            "$app" \
            "Health: ${health_source}" \
            "$classification" \
            "$severity" \
            "active" \
            "$message" \
            "" \
            "$detail" \
            "$notify_runs" \
            0 \
            "$API_FAILURE_ESCALATE_MINUTES" \
            "$health_source" \
            "$normalized_message"

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
    local normalized_failures

    if grep -Eqi 'authentication rejected|HTTP (401|403)|api key.*(incorrect|required)' <<<"$failures"; then
        classification="SERVICE_API_AUTHENTICATION"
        notify_runs=2
    fi

    normalized_failures=$(normalize_arr_message "$failures")

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
        "$API_FAILURE_ESCALATE_MINUTES" \
        "api" \
        "$normalized_failures"

    ((SERVICE_API_ISSUE_COUNT++)) || true
}

###############################################################################
# MONITOR SELF-HEALTH
###############################################################################

preflight_notification_command() {

    if [ "$SEND_NOTIFICATIONS" != true ]; then
        set_monitor_notification_state false "" || true
        return
    fi

    if [ ! -x "$NOTIFY" ]; then
        NOTIFICATION_LAST_ERROR="notification command is missing or not executable: ${NOTIFY}"
        set_monitor_notification_state true "$NOTIFICATION_LAST_ERROR" || true
        notification_fallback_alert "$NOTIFICATION_LAST_ERROR"
    fi
}

record_monitor_schedule_issue() {

    local allowed_gap
    local message

    allowed_gap=$(( MONITOR_EXPECTED_INTERVAL_MINUTES + MONITOR_MISSED_RUN_GRACE_MINUTES ))

    (( PREVIOUS_RUN_STARTED_AT > 0 )) || return
    (( PREVIOUS_RUN_GAP_MINUTES > allowed_gap )) || return

    message="The interval between monitor starts was ${PREVIOUS_RUN_GAP_MINUTES} minutes; expected at most ${allowed_gap} minutes (${MONITOR_EXPECTED_INTERVAL_MINUTES}-minute schedule plus ${MONITOR_MISSED_RUN_GRACE_MINUTES}-minute grace)."

    record_normalized_issue \
        "Monitor:schedule-gap" \
        "Monitor" \
        "ARR health monitor missed its expected interval" \
        "MONITOR_SCHEDULE_MISSED" \
        "WARNING" \
        "active" \
        "$message" \
        "" \
        "$message" \
        1 \
        0 \
        0 \
        "scheduler" \
        "monitor start interval exceeded expected schedule"

    ((MONITOR_SCHEDULE_MISSED_COUNT++)) || true
}

record_monitor_notification_issue() {

    local failed
    local reason

    failed=$(jq -r \
        '(.monitor.notification.failed // false) | tostring' \
        "$STATE_FILE")

    [ "$failed" = true ] || return

    reason=$(jq -r \
        '.monitor.notification.reason // "Unraid notification command failed"' \
        "$STATE_FILE")

    record_normalized_issue \
        "Monitor:notification-command" \
        "Monitor" \
        "Unraid notification delivery failed" \
        "MONITOR_NOTIFICATION_FAILURE" \
        "ERROR" \
        "active" \
        "$reason" \
        "" \
        "${reason}"$'\n'"The issue is also written to the persistent monitor log and Unraid syslog. Delivery will be retried on a later run." \
        "$MONITOR_NOTIFICATION_FAILURE_NOTIFY_RUNS" \
        0 \
        "$API_FAILURE_ESCALATE_MINUTES" \
        "notification-command" \
        "unraid notification command failure"

    ((MONITOR_NOTIFICATION_FAILURE_COUNT++)) || true
}

record_monitor_scan_issue() {

    local -a failures=()
    local message
    local normalized

    if [ "$PREVIOUS_RUN_INCOMPLETE" = true ]; then
        failures+=("Previous monitor run did not reach its completion checkpoint")
    fi

    if [ "$ACTIVITY_AUDIT_ENABLED" = true ]; then

        if [ "$SONARR_ENABLED" = true ] &&
           [ "$SONARR_API_OK" = true ] &&
           [ "$SONARR_AUDIT_OK" != true ]
        then
            failures+=("Sonarr activity-history scan failed while core Sonarr endpoints remained reachable")
        fi

        if [ "$RADARR_ENABLED" = true ] &&
           [ "$RADARR_API_OK" = true ] &&
           [ "$RADARR_AUDIT_OK" != true ]
        then
            failures+=("Radarr activity-history scan failed while core Radarr endpoints remained reachable")
        fi

        if [ "$SAB_ENABLED" = true ] &&
           [ "$SAB_API_OK" = true ] &&
           [ "$SAB_AUDIT_OK" != true ]
        then
            failures+=("SABnzbd activity scan could not be completed from the retrieved history")
        fi
    fi

    if [ "$FLOW_ANOMALY_ENABLED" = true ] &&
       [ "$ACTIVITY_AUDIT_ENABLED" = true ] &&
       [ "$SONARR_AUDIT_OK" = true ] &&
       [ "$RADARR_AUDIT_OK" = true ] &&
       [ "$SAB_AUDIT_OK" = true ] &&
       [ "$FLOW_ANALYSIS_OK" != true ]
    then
        failures+=("Activity-flow analysis failed: ${FLOW_ANALYSIS_REASON}")
    fi

    (( ${#failures[@]} > 0 )) || return

    printf -v message '%s; ' "${failures[@]}"
    message=${message%; }
    normalized=$(normalize_arr_message "$message")

    record_normalized_issue \
        "Monitor:scan-failure" \
        "Monitor" \
        "ARR health monitor scan repeatedly incomplete" \
        "MONITOR_SCAN_FAILURE" \
        "ERROR" \
        "degraded" \
        "$message" \
        "" \
        "$message" \
        "$MONITOR_SCAN_FAILURE_NOTIFY_RUNS" \
        0 \
        "$MONITOR_SCAN_FAILURE_ESCALATE_MINUTES" \
        "scan" \
        "$normalized"

    ((MONITOR_SCAN_FAILURE_COUNT++)) || true
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
        local reason
        local reason_detail
        local signature_message
        local analysis_file
        local queue_issue_eligible

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

        analysis_file=$(mktemp "${TMP_DIR}/arr-queue-analysis.XXXXXX") || {
            log "ERROR: Unable to create Arr queue analysis file"
            continue
        }

        if ! analyze_arr_queue_reasons \
            "$tracked_status" \
            "$tracked_state" \
            "$status" \
            "$age" \
            "$item" \
            "$analysis_file"
        then
            log "ERROR: Unable to classify ${app} queue messages separately"
            continue
        fi

        if ! jq -e '.hasIssue == true' "$analysis_file" >/dev/null 2>&1; then
            continue
        fi

        queue_issue_eligible=$(jq -r '.eligible | tostring' "$analysis_file")
        message=$(jq -r '.allMessage // ""' "$analysis_file")
        signature_message=$(jq -r '.signatureMessage // ""' "$analysis_file")
        reason_detail=$(jq -r '.reasonDetail // ""' "$analysis_file")

        if [ "$queue_issue_eligible" = true ]; then
            classification=$(jq -r '.primaryClassification' "$analysis_file")
            severity=$(jq -r '.primarySeverity' "$analysis_file")
            reason=$(jq -r '.primaryReason' "$analysis_file")
        else
            classification=$(jq -r '.primaryAnyClassification' "$analysis_file")
            severity=$(jq -r '.primaryAnySeverity' "$analysis_file")
            reason=$(classification_reason "$classification" "$age")
        fi

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
                    severity=$(classification_severity "$classification" "$age")
                    reason=$(classification_reason "$classification" "$age")
                    signature_message+=" || promoted=${classification}"

                    if (( age < $(classification_min_age "$classification") )); then
                        queue_issue_eligible=false
                    fi

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

        while IFS= read -r reason_record; do

            local reason_classification
            local reason_message

            reason_classification=$(jq -r '.classification' <<<"$reason_record")
            reason_message=$(jq -r '.message // ""' <<<"$reason_record")

            [ "$reason_classification" != "NONE" ] || continue

            record_arr_telemetry \
                "$app" \
                "$issue_key" \
                "$media_name" \
                "$release" \
                "$reason_classification" \
                "$tracked_status" \
                "$tracked_state" \
                "$status" \
                "$reason_message"

        done < <(jq -c '.reasons[]?' "$analysis_file")

        ###############################################################################
        # NORMAL AGE THRESHOLD
        ###############################################################################

        if [ "$queue_issue_eligible" != true ]; then
            continue
        fi

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

        if jq -e \
            'any(.reasons[]?; .classification | startswith("CF_REJECT"))' \
            "$analysis_file" >/dev/null 2>&1
        then
            ((CF_REJECT_COUNT++)) || true
        fi

        if jq -e \
            'any(.reasons[]?; .classification == "UPGRADE_REJECT")' \
            "$analysis_file" >/dev/null 2>&1
        then
            ((UPGRADE_REJECT_COUNT++)) || true
        fi

        if jq -e \
            'any(.reasons[]?; .classification == "TBA_METADATA")' \
            "$analysis_file" >/dev/null 2>&1
        then
            ((TBA_COUNT++)) || true
        fi

        if jq -e \
            'any(.reasons[]?; .classification == "UNMATCHED_MEDIA")' \
            "$analysis_file" >/dev/null 2>&1
        then
            ((UNMATCHED_COUNT++)) || true
        fi

        if jq -e \
            'any(.reasons[]?; .classification == "NO_IMPORTABLE_FILES")' \
            "$analysis_file" >/dev/null 2>&1
        then
            ((NO_IMPORT_COUNT++)) || true
        fi

        if jq -e \
            'any(.reasons[]?; .classification == "ARR_IMPORT_STALLED")' \
            "$analysis_file" >/dev/null 2>&1
        then
            ((STALL_COUNT++)) || true
        fi

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

        if jq -e \
            'any(.reasons[]?; .classification | startswith("CF_REJECT"))' \
            "$analysis_file" >/dev/null 2>&1
        then
            log_cf_details "$message"
        fi

        if [ -n "$reason_detail" ]; then
            log "Classified queue reasons:"

            while IFS= read -r detail_line; do
                [ -n "$detail_line" ] && log "  ${detail_line}"
            done <<<"$reason_detail"
        fi

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
                "$signature_message"
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
            "$reason_detail" \
            "queue" \
            "$signature_message"

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

            if [ -n "$reason_detail" ]; then
                detail="Import reasons:"
                detail+=$'\n'
                detail+="$reason_detail"
            fi

            if [[ "$classification" == CF_REJECT* ]]; then

                local cf_detail

                cf_detail=$(build_cf_group_detail "$message")

                if [ -n "$cf_detail" ]; then
                    [ -z "$detail" ] || detail+=$'\n'
                    detail+="$cf_detail"
                fi
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

        queue:fetching)
            echo "$SAB_FETCH_STALL_MINUTES"
            ;;

        queue:propagating)
            echo "$SAB_PROPAGATION_GRACE_MINUTES"
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
    local labels="${8:-}"
    local propagation_delay_minutes="${9:-0}"

    [ -n "$download_id" ] || return 0
    [[ "$propagation_delay_minutes" =~ ^[0-9]+$ ]] || propagation_delay_minutes=0

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
        --arg labels "$labels" \
        --argjson propagationDelayMinutes "$propagation_delay_minutes" \
        '{
            id: $id,
            signature: $signature,
            status: $status,
            sourceKind: $sourceKind,
            owner: $owner,
            name: $name,
            category: $category,
            remaining: $remaining,
            labels: $labels,
            propagationDelayMinutes: $propagationDelayMinutes
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
                labels: ($item.labels // ""),
                lastSeen: $now,
                lastProgressAt: (
                    if ($old.signature // "") == $item.signature
                    then ($old.lastProgressAt // $now)
                    else $now
                    end
                ),
                propagationReadyAt: (
                    if (($item.status // "") | ascii_downcase) == "propagating"
                    then
                        if (($old.status // "") | ascii_downcase) == "propagating"
                           and (($old.propagationReadyAt // 0) > 0)
                        then $old.propagationReadyAt
                        else
                            $now
                            + (
                                (
                                    if ($item.propagationDelayMinutes // 0) > 0
                                    then $item.propagationDelayMinutes
                                    else 0
                                    end
                                )
                                * 60
                            )
                        end
                    else 0
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
        local propagation_ready_at=0
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

        if [ "${status,,}" = "propagating" ]; then

            propagation_ready_at=$(jq -r \
                --arg id "$download_id" \
                '.sabProgress[$id].propagationReadyAt // 0' \
                "$STATE_FILE")

            [[ "$propagation_ready_at" =~ ^[0-9]+$ ]] || propagation_ready_at=0

            if (( propagation_ready_at <= 0 )); then
                propagation_ready_at=$((last_progress + SAB_PROPAGATION_DEFAULT_MINUTES * 60))
            fi

            if (( now < propagation_ready_at + SAB_PROPAGATION_GRACE_MINUTES * 60 )); then
                continue
            fi

            elapsed_minutes=$(( (now - propagation_ready_at) / 60 ))
            threshold="$SAB_PROPAGATION_GRACE_MINUTES"
        fi

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
        if [ "${status,,}" = "propagating" ]; then
            detail+="Past advertised propagation readiness: ${elapsed_minutes} minute(s)"
        else
            detail+="No progress: ${elapsed_minutes} minute(s)"
        fi

        if [ -n "$remaining" ]; then
            detail+=$'\n'
            detail+="Remaining: ${remaining} MB"
        fi

        mark_sab_primary_download "$download_id"

        local summary="${status} has made no observable progress for ${elapsed_minutes} minutes"

        if [ "${status,,}" = "propagating" ]; then
            summary="${status} is ${elapsed_minutes} minutes past its advertised readiness window"
        fi

        record_normalized_issue \
            "SABnzbd:${source_kind}:stalled:${download_id}" \
            "SABnzbd" \
            "$title" \
            "$classification" \
            "$severity" \
            "$stage" \
            "$summary" \
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
            local labels
            local propagation_delay_minutes=0

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
            labels=$(jq -r '
                (.labels // [])
                | if type == "array" then join(" | ") else tostring end
                ' <<<"$item")

            if [ "${status,,}" = "propagating" ]; then
                propagation_delay_minutes=$(sed -nE \
                    's/.*PROPAGATING[[:space:]]+([0-9]+)[[:space:]]*min.*/\1/Ip' \
                    <<<"$labels" | head -n 1)

                [[ "$propagation_delay_minutes" =~ ^[0-9]+$ ]] || \
                    propagation_delay_minutes="$SAB_PROPAGATION_DEFAULT_MINUTES"
            fi

            observe_sab_progress \
                "queue" \
                "$owner" \
                "$category" \
                "$download_id" \
                "$name" \
                "$status" \
                "$remaining" \
                "$labels" \
                "$propagation_delay_minutes"

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
                "" \
                "" \
                0

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

process_sab_queue_job_conditions() {

    local globally_paused="$1"

    [ "$SAB_QUEUE_OK" = true ] || return 0
    [ -f "$SAB_QUEUE" ] || return 0

    while IFS= read -r item; do

        [ -n "$item" ] || continue

        local category
        local owner
        local download_id
        local name
        local status
        local priority
        local labels
        local classification=""
        local severity="WARNING"
        local notify_runs=2
        local minimum_minutes=0
        local reason=""
        local title
        local detail
        local issue_hash

        category=$(jq -r '.cat // .category // ""' <<<"$item")

        if [ "${category,,}" = "${SAB_IGNORED_CATEGORY,,}" ]; then
            continue
        fi

        owner=$(sab_category_owner "$category")
        [ -n "$owner" ] || continue

        download_id=$(jq -r '.nzo_id // ""' <<<"$item")
        name=$(jq -r '.filename // .name // "Unknown SAB job"' <<<"$item")
        status=$(jq -r '.status // ""' <<<"$item")
        priority=$(jq -r '.priority // "" | tostring' <<<"$item")
        labels=$(jq -r '
            (.labels // [])
            | if type == "array" then join(" | ") else tostring end
            ' <<<"$item")

        if grep -Eqi '(^|[|,[:space:]])ENCRYPTED($|[|,[:space:]])' <<<"$labels"; then

            classification="SAB_JOB_ENCRYPTED"
            severity="ERROR"
            notify_runs=1
            minimum_minutes=0
            reason="SABnzbd identified the queued job as encrypted"
            ((SAB_JOB_ENCRYPTED_COUNT++)) || true

        elif grep -Eqi '(^|[|,[:space:]])DUPLICATE($|[|,[:space:]])' <<<"$labels" ||
             [ "${priority,,}" = "duplicate" ] ||
             [ "$priority" = "-3" ]
        then

            classification="SAB_JOB_DUPLICATE"
            notify_runs=2
            minimum_minutes="$SAB_DUPLICATE_WARN_MINUTES"
            reason="SABnzbd is holding the job as a duplicate"
            ((SAB_JOB_DUPLICATE_COUNT++)) || true

        elif [ "$globally_paused" != true ] &&
             { [ "${status,,}" = "paused" ] ||
               [ "${priority,,}" = "paused" ] ||
               [ "$priority" = "-2" ]; }
        then

            classification="SAB_JOB_PAUSED"
            notify_runs=2
            minimum_minutes="$SAB_JOB_PAUSE_WARN_MINUTES"
            reason="An individual SABnzbd job is paused while the global queue is active"
            ((SAB_JOB_PAUSED_COUNT++)) || true
        fi

        [ -n "$classification" ] || continue

        issue_hash="${download_id:-$(stable_issue_hash "${category}|${name}")}"
        title=$(sab_correlated_title "$owner" "$download_id" "$name")
        detail="Owner: ${owner}"$'\n'
        detail+="Release: ${name}"$'\n'
        detail+="SAB status: ${status:-unknown}"$'\n'
        detail+="Priority: ${priority:-unknown}"

        if [ -n "$labels" ]; then
            detail+=$'\n'
            detail+="Labels: ${labels}"
        fi

        mark_sab_primary_download "$download_id"

        record_normalized_issue \
            "SABnzbd:queue:job:${issue_hash}" \
            "SABnzbd" \
            "$title" \
            "$classification" \
            "$severity" \
            "active" \
            "$reason" \
            "" \
            "$detail" \
            "$notify_runs" \
            "$minimum_minutes" \
            "$API_FAILURE_ESCALATE_MINUTES"

    done < <(jq -c '.queue.slots[]?' "$SAB_QUEUE")
}

process_sab_capacity_health() {

    [ "$SAB_QUEUE_OK" = true ] || return 0
    [ -f "$SAB_QUEUE" ] || return 0

    if (( SAB_DISK_WARN_GB > 0 )); then

        local low_disks

        low_disks=$(jq -c \
            --argjson threshold "$SAB_DISK_WARN_GB" \
            '
            [
                {
                    label: "Temporary download storage",
                    free: ((.queue.diskspace1 | tonumber?) // -1),
                    total: ((.queue.diskspacetotal1 | tonumber?) // -1)
                },
                {
                    label: "Completed download storage",
                    free: ((.queue.diskspace2 | tonumber?) // -1),
                    total: ((.queue.diskspacetotal2 | tonumber?) // -1)
                }
            ]
            | map(select(.free >= 0 and .free <= $threshold))
            | unique_by(.free, .total)
            ' "$SAB_QUEUE")

        if jq -e 'length > 0' <<<"$low_disks" >/dev/null 2>&1; then

            local disk_detail

            disk_detail=$(jq -r '
                map(
                    .label
                    + ": "
                    + (.free | tostring)
                    + " GiB free"
                    + (
                        if .total >= 0
                        then " of " + (.total | tostring) + " GiB"
                        else ""
                        end
                    )
                )
                | join("\n")
                ' <<<"$low_disks")

            record_normalized_issue \
                "SABnzbd:capacity:disk" \
                "SABnzbd" \
                "SABnzbd storage running low" \
                "SAB_DISK_SPACE_LOW" \
                "WARNING" \
                "active" \
                "SABnzbd reports no more than ${SAB_DISK_WARN_GB} GiB free" \
                "" \
                "$disk_detail" \
                2 \
                0 \
                "$API_FAILURE_ESCALATE_MINUTES"

            ((SAB_CAPACITY_ISSUE_COUNT++)) || true
        fi
    fi

    if (( SAB_QUOTA_WARN_GB > 0 )) &&
       jq -e \
            --argjson threshold "$SAB_QUOTA_WARN_GB" \
            '
            .queue.have_quota == true
            and
            (((.queue.left_quota | tonumber?) // -1) >= 0)
            and
            (((.queue.left_quota | tonumber?) // -1) <= $threshold)
            ' "$SAB_QUEUE" >/dev/null 2>&1
    then

        local quota_left

        quota_left=$(jq -r '.queue.left_quota // "unknown"' "$SAB_QUEUE")

        record_normalized_issue \
            "SABnzbd:capacity:quota" \
            "SABnzbd" \
            "SABnzbd download quota running low" \
            "SAB_QUOTA_LOW" \
            "WARNING" \
            "active" \
            "SABnzbd reports ${quota_left} GiB of quota remaining" \
            "" \
            "Configured warning threshold: ${SAB_QUOTA_WARN_GB} GiB" \
            2 \
            0 \
            "$API_FAILURE_ESCALATE_MINUTES"

        ((SAB_CAPACITY_ISSUE_COUNT++)) || true
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
    local all_active_servers_unavailable=false

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

        all_active_servers_unavailable=true

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

    if [ "$SAB_STATUS_OK" = true ] &&
       [ "$all_active_servers_unavailable" != true ]
    then

        while IFS= read -r server; do

            [ -n "$server" ] || continue

            local server_name
            local server_error
            local server_hash
            local server_classification="SAB_SERVER_DEGRADED"
            local server_severity="WARNING"
            local server_notify_runs="$SAB_SERVER_ERROR_NOTIFY_RUNS"

            server_name=$(jq -r '.servername // "Unknown server"' <<<"$server")
            server_error=$(jq -r '.servererror // "Unknown server error"' <<<"$server")
            server_hash=$(stable_issue_hash "$server_name")

            if grep -Eqi 'authentication|authorization|login|username|password' <<<"$server_error"; then
                server_classification="SAB_SERVER_AUTHENTICATION"
                server_severity="ERROR"
                server_notify_runs=1
            fi

            record_normalized_issue \
                "SABnzbd:status:server:${server_hash}" \
                "SABnzbd" \
                "SAB server degraded: ${server_name}" \
                "$server_classification" \
                "$server_severity" \
                "active" \
                "$server_error" \
                "" \
                "Server: ${server_name}"$'\n'"Error: ${server_error}" \
                "$server_notify_runs" \
                0 \
                "$API_FAILURE_ESCALATE_MINUTES"

            ((SAB_SERVER_DEGRADED_COUNT++)) || true

        done < <(
            jq -c '
                .status.servers[]?
                | select(
                    .serveractive == true
                    and
                    (.servererror // "") != ""
                )
                ' "$SAB_STATUS"
        )
    fi

    process_sab_queue_job_conditions "$paused"
    process_sab_capacity_health

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

process_sab_server_stats() {

    if [ "$SAB_SERVER_STATS_OK" != true ] || [ ! -f "$SAB_SERVER_STATS" ]; then

        record_normalized_issue \
            "SABnzbd:server-stats-api" \
            "SABnzbd" \
            "SABnzbd provider statistics unavailable" \
            "SAB_SERVER_STATS_UNAVAILABLE" \
            "WARNING" \
            "degraded" \
            "Unable to retrieve SABnzbd server statistics" \
            "" \
            "Provider article-success monitoring could not run; core SAB queue, history, warning and status monitoring remained independent." \
            "$API_FAILURE_NOTIFY_RUNS" \
            0 \
            "$API_FAILURE_ESCALATE_MINUTES"

        return 0
    fi

    local observations_file="${TMP_DIR}/sab_server_stats_observations.jsonl"
    local tmp="${TMP_DIR}/state.sab-server-stats.json"
    local now
    local server

    now=$(date +%s)
    : >"$observations_file"

    if ! jq -c '
            (.servers // {})
            | to_entries[]?
            | {
                name: .key,
                tried: ((.value.articles_tried | tonumber?) // 0),
                success: ((.value.articles_success | tonumber?) // 0)
            }
            ' "$SAB_SERVER_STATS" >"$observations_file"
    then
        SAB_SERVER_STATS_OK=false
        log "WARNING: Unable to parse SABnzbd provider statistics"
        process_sab_server_stats
        return 1
    fi

    while IFS= read -r server; do

        [ -n "$server" ] || continue

        local server_name
        local server_hash
        local issue_key
        local tried
        local success
        local previous_tried
        local previous_success
        local delta_tried=0
        local delta_success=0
        local success_percent=100
        local active_issue

        server_name=$(jq -r '.name' <<<"$server")
        tried=$(jq -r '.tried' <<<"$server")
        success=$(jq -r '.success' <<<"$server")
        server_hash=$(stable_issue_hash "$server_name")
        issue_key="SABnzbd:server-quality:${server_hash}"

        previous_tried=$(jq -r \
            --arg name "$server_name" \
            '.sabServerStats[$name].tried // -1' \
            "$STATE_FILE")
        previous_success=$(jq -r \
            --arg name "$server_name" \
            '.sabServerStats[$name].success // -1' \
            "$STATE_FILE")

        if [[ "$previous_tried" =~ ^[0-9]+$ ]] &&
           [[ "$previous_success" =~ ^[0-9]+$ ]] &&
           (( tried >= previous_tried && success >= previous_success ))
        then
            delta_tried=$((tried - previous_tried))
            delta_success=$((success - previous_success))
        fi

        if (( delta_tried < SAB_SERVER_MIN_ARTICLE_ATTEMPTS )); then

            active_issue=$(jq -r \
                --arg key "$issue_key" \
                '(.issues[$key].active // false) | tostring' \
                "$STATE_FILE")

            if [ "$active_issue" = true ]; then
                mark_seen "$issue_key"
            fi

            continue
        fi

        success_percent=$((delta_success * 100 / delta_tried))

        if (( success_percent < SAB_SERVER_MIN_SUCCESS_PERCENT )); then

            record_normalized_issue \
                "$issue_key" \
                "SABnzbd" \
                "Low article success: ${server_name}" \
                "SAB_SERVER_LOW_ARTICLE_SUCCESS" \
                "WARNING" \
                "degraded" \
                "Provider article success was ${success_percent}% during the latest interval" \
                "" \
                "Server: ${server_name}"$'\n'"Articles attempted: ${delta_tried}"$'\n'"Articles successful: ${delta_success}"$'\n'"Configured minimum: ${SAB_SERVER_MIN_SUCCESS_PERCENT}%" \
                "$SAB_SERVER_SUCCESS_NOTIFY_RUNS" \
                0 \
                "$API_FAILURE_ESCALATE_MINUTES"

            ((SAB_SERVER_LOW_SUCCESS_COUNT++)) || true
        fi

    done <"$observations_file"

    jq \
        --slurpfile stats "$observations_file" \
        --argjson now "$now" \
        --argjson minimumAttempts "$SAB_SERVER_MIN_ARTICLE_ATTEMPTS" \
        '
        .sabServerStats = (.sabServerStats // {})
        | reduce $stats[] as $server (
            .;
            (.sabServerStats[$server.name] // {}) as $old
            | if (($old.tried // -1) < 0)
                 or ($server.tried < ($old.tried // 0))
                 or ($server.success < ($old.success // 0))
                 or (($server.tried - ($old.tried // 0)) >= $minimumAttempts)
              then
                .sabServerStats[$server.name] = {
                    tried: $server.tried,
                    success: $server.success,
                    lastSeen: $now
                }
              else
                .sabServerStats[$server.name].lastSeen = $now
              end
        )
        ' "$STATE_FILE" >"$tmp" || {
            SAB_SERVER_STATS_OK=false
            return 1
        }

    if ! save_state "$tmp"; then
        SAB_SERVER_STATS_OK=false
        return 1
    fi

    return 0
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
    [ "$SAB_FILESYSTEM_SCAN_OK" = true ] || return
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

prepare_sab_filesystem_scan() {

    SAB_FILESYSTEM_SCAN_OK=false
    SAB_FILESYSTEM_SCAN_DEFERRED=false
    SAB_FILESYSTEM_SCAN_REASON="Not evaluated"

    [ "$SAB_ENABLED" = true ] || return 0

    if [ "$SAB_FILESYSTEM_GUARD_ENABLED" != true ]; then
        SAB_FILESYSTEM_SCAN_OK=true
        SAB_FILESYSTEM_SCAN_REASON="Filesystem guard disabled"
        return 0
    fi

    if ! required_mount_available "$SAB_REQUIRED_MOUNT"; then

        SAB_FILESYSTEM_SCAN_REASON="Required SAB completed-download mount is unavailable: ${SAB_REQUIRED_MOUNT}"

        record_normalized_issue \
            "Monitor:storage:sab-complete" \
            "Monitor" \
            "SAB completed-download storage unavailable" \
            "STORAGE_UNAVAILABLE" \
            "ERROR" \
            "active" \
            "$SAB_FILESYSTEM_SCAN_REASON" \
            "" \
            "${SAB_FILESYSTEM_SCAN_REASON}. Filesystem orphan/residue analysis was skipped and existing filesystem issues were preserved." \
            1 \
            0 \
            "$API_FAILURE_ESCALATE_MINUTES" \
            "storage" \
            "sab completed-download mount unavailable"

        return 1
    fi

    if [ ! -d "$SAB_COMPLETE_ROOT" ] || [ ! -r "$SAB_COMPLETE_ROOT" ]; then

        SAB_FILESYSTEM_SCAN_REASON="SAB completed-download root is missing or unreadable: ${SAB_COMPLETE_ROOT}"

        record_normalized_issue \
            "Monitor:storage:sab-complete" \
            "Monitor" \
            "SAB completed-download storage unavailable" \
            "STORAGE_UNAVAILABLE" \
            "ERROR" \
            "active" \
            "$SAB_FILESYSTEM_SCAN_REASON" \
            "" \
            "${SAB_FILESYSTEM_SCAN_REASON}. Filesystem orphan/residue analysis was skipped and existing filesystem issues were preserved." \
            1 \
            0 \
            "$API_FAILURE_ESCALATE_MINUTES" \
            "storage" \
            "sab completed-download root unavailable"

        return 1
    fi

    if unraid_mover_running; then

        SAB_FILESYSTEM_SCAN_DEFERRED=true
        SAB_FILESYSTEM_SCAN_REASON="Unraid mover is active"
        ((SAB_FILESYSTEM_SCAN_DEFERRED_COUNT++)) || true

        log "SAB filesystem orphan/residue scan deferred while Unraid mover is active"
        persistent_log \
            "DEFERRED" \
            "SAB filesystem scan | reason=Unraid mover active"

        record_normalized_issue \
            "Monitor:filesystem-scan-deferred:mover" \
            "Monitor" \
            "SAB filesystem scan deferred" \
            "FILESYSTEM_SCAN_DEFERRED" \
            "INFO" \
            "deferred" \
            "$SAB_FILESYSTEM_SCAN_REASON" \
            "" \
            "API monitoring continued; only filesystem orphan/residue analysis was deferred." \
            999999 \
            0 \
            0 \
            "mover" \
            "filesystem scan deferred while mover active"

        return 1
    fi

    SAB_FILESYSTEM_SCAN_OK=true
    SAB_FILESYSTEM_SCAN_REASON="Filesystem available and mover inactive"

    return 0
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
# EXACT DOWNLOAD WORKFLOW LEDGER - v3.5
###############################################################################

prepare_download_ledger_enrollment_cache() {

    : >"$DOWNLOAD_LEDGER_ENROLLED_IDS_FILE"

    jq -r '
        .downloadLedger
        // {}
        | to_entries[]?
        | select((.value.flowEnrolled // false) == true)
        | .key
        ' \
        "$STATE_FILE" \
        >>"$DOWNLOAD_LEDGER_ENROLLED_IDS_FILE" || return 1
}

download_ledger_id_is_enrolled() {

    local download_id="${1,,}"

    [ -n "$download_id" ] || return 1

    grep -Fxiq -- \
        "$download_id" \
        "$DOWNLOAD_LEDGER_ENROLLED_IDS_FILE" \
        2>/dev/null
}

mark_download_ledger_id_enrolled() {

    local download_id="${1,,}"

    [ -n "$download_id" ] || return 0

    if ! download_ledger_id_is_enrolled "$download_id"; then
        printf '%s\n' "$download_id" >>"$DOWNLOAD_LEDGER_ENROLLED_IDS_FILE"
    fi
}

arr_download_ledger_identity() {

    local app="$1"
    local item="$2"
    local source_kind="${3:-history}"

    case "$app" in

        Sonarr)
            jq -c \
                --arg sourceKind "$source_kind" \
                '
                (
                    .seriesId
                    // .episode.seriesId
                    // .series.id
                    // 0
                ) as $seriesId
                |
                (
                    .episodeId
                    // .episode.id
                    // 0
                ) as $episodeId
                |
                if ($seriesId > 0 and $episodeId > 0)
                then {
                    type: "episode",
                    key: ("episode:" + ($episodeId | tostring)),
                    seriesId: $seriesId,
                    episodeId: $episodeId,
                    seasonNumber: (.episode.seasonNumber // null),
                    episodeNumber: (.episode.episodeNumber // null),
                    preFileKnown: (
                        $sourceKind == "queue"
                        and (.episode | type) == "object"
                        and (.episode | has("episodeFileId"))
                    ),
                    preFileId: (
                        if $sourceKind == "queue"
                        then (.episode.episodeFileId // 0)
                        else 0
                        end
                    )
                }
                else {}
                end
                ' <<<"$item"
            ;;

        Radarr)
            jq -c \
                --arg sourceKind "$source_kind" \
                '
                (
                    .movieId
                    // .movie.id
                    // 0
                ) as $movieId
                |
                if $movieId > 0
                then {
                    type: "movie",
                    key: ("movie:" + ($movieId | tostring)),
                    movieId: $movieId,
                    preFileKnown: (
                        $sourceKind == "queue"
                        and (.movie | type) == "object"
                        and (.movie | has("movieFileId"))
                    ),
                    preFileId: (
                        if $sourceKind == "queue"
                        then (.movie.movieFileId // 0)
                        else 0
                        end
                    )
                }
                else {}
                end
                ' <<<"$item"
            ;;

        *)
            printf '{}\n'
            ;;
    esac
}

arr_download_ledger_warning() {

    local item="$1"

    queue_reason_records "$item" |
        jq -rs '
            [
                .[]?.message
                | select(type == "string" and length > 0)
            ]
            | unique
            | join("; ")
            '
}

append_download_ledger_observation() {

    local download_id="${1,,}"
    local app="$2"
    local release="$3"
    local title="$4"
    local kind="$5"
    local event_epoch="$6"
    local observed_at="${7:-$START_TIME}"
    local status="${8:-}"
    local identity="${9:-}"
    local warning="${10:-}"

    [ -n "$download_id" ] || return 0
    [[ "$event_epoch" =~ ^[0-9]+$ ]] || event_epoch=0
    [[ "$observed_at" =~ ^[0-9]+$ ]] || observed_at="$START_TIME"
    [ -n "$identity" ] || identity='{}'
    jq -e 'type == "object"' <<<"$identity" >/dev/null 2>&1 || identity='{}'

    case "$kind" in
        arrGrabbed|arrQueue|sabQueue)
            mark_download_ledger_id_enrolled "$download_id"
            ;;
    esac

    jq -nc \
        --arg id "$download_id" \
        --arg app "$app" \
        --arg release "$release" \
        --arg title "$title" \
        --arg kind "$kind" \
        --arg status "$status" \
        --arg warning "$warning" \
        --argjson identity "$identity" \
        --argjson eventEpoch "$event_epoch" \
        --argjson observedAt "$observed_at" \
        '{
            id: $id,
            app: $app,
            release: $release,
            title: $title,
            kind: $kind,
            status: $status,
            warning: $warning,
            identity: $identity,
            eventEpoch: $eventEpoch,
            observedAt: $observedAt
        }' >>"$DOWNLOAD_LEDGER_OBSERVATIONS_FILE"
}

collect_arr_download_ledger() {

    local app="$1"
    local history_file="$2"
    local queue_file="$3"

    if [ -f "$history_file" ]; then

        while IFS= read -r item; do

            [ -n "$item" ] || continue

            local download_id
            local event_type
            local event_date
            local event_epoch
            local release
            local title
            local kind=""
            local identity

            download_id=$(jq -r '.downloadId // .data.downloadId // .data.downloadClientId // ""' <<<"$item")
            [ -n "$download_id" ] || continue

            event_type=$(jq -r '.eventType // "unknown"' <<<"$item")

            case "$event_type" in

                grabbed)
                    kind="arrGrabbed"
                    ;;

                downloadFolderImported)
                    kind="arrImported"
                    ;;

                downloadFailed)
                    kind="arrFailed"
                    ;;

                downloadIgnored)
                    kind="arrIgnored"
                    ;;

                *)
                    continue
                    ;;
            esac

            event_date=$(jq -r '.date // ""' <<<"$item")
            event_epoch=$(date_to_epoch "$event_date")
            (( event_epoch > 0 )) || continue

            release=$(jq -r '.sourceTitle // "Unknown release"' <<<"$item")
            title=$(history_media_name "$app" "$item")
            identity=$(arr_download_ledger_identity "$app" "$item" "history")

            append_download_ledger_observation \
                "$download_id" \
                "$app" \
                "$release" \
                "$title" \
                "$kind" \
                "$event_epoch" \
                "$event_epoch" \
                "$event_type" \
                "$identity"

        done < <(jq -c '.[]?' "$history_file")
    fi

    if [ -f "$queue_file" ]; then

        while IFS= read -r item; do

            [ -n "$item" ] || continue

            local download_id
            local release
            local title
            local status
            local identity
            local warning

            download_id=$(jq -r '.downloadId // ""' <<<"$item")
            [ -n "$download_id" ] || continue

            release=$(jq -r '.title // "Unknown release"' <<<"$item")
            title=$(friendly_media_name "$app" "$item")
            status=$(jq -r '
                (.status // "unknown")
                + "/"
                + (.trackedDownloadStatus // "unknown")
                + "/"
                + (.trackedDownloadState // "unknown")
                ' <<<"$item")
            identity=$(arr_download_ledger_identity "$app" "$item" "queue")
            warning=$(arr_download_ledger_warning "$item")

            append_download_ledger_observation \
                "$download_id" \
                "$app" \
                "$release" \
                "$title" \
                "arrQueue" \
                "$START_TIME" \
                "$START_TIME" \
                "$status" \
                "$identity" \
                "$warning"

        done < <(jq -c '.records[]?' "$queue_file")
    fi
}

collect_sab_download_ledger() {

    local discovery_cutoff=$((
        START_TIME - DOWNLOAD_LEDGER_DISCOVERY_HOURS * 3600
    ))

    if [ "$SAB_QUEUE_OK" = true ] && [ -f "$SAB_QUEUE" ]; then

        while IFS= read -r item; do

            [ -n "$item" ] || continue

            local category
            local owner
            local download_id
            local release
            local status
            local queued_at

            category=$(jq -r '.cat // .category // ""' <<<"$item")
            owner=$(sab_category_owner "$category")
            [ -n "$owner" ] || continue

            download_id=$(jq -r '.nzo_id // ""' <<<"$item")
            [ -n "$download_id" ] || continue
            download_id="${download_id,,}"

            release=$(jq -r '.filename // .name // "Unknown SAB job"' <<<"$item")
            status=$(jq -r '.status // "unknown"' <<<"$item")
            queued_at=$(jq -r '.time_added // 0' <<<"$item")
            [[ "$queued_at" =~ ^[0-9]+$ ]] || queued_at="$START_TIME"

            append_download_ledger_observation \
                "$download_id" \
                "$owner" \
                "$release" \
                "$release" \
                "sabQueue" \
                "$queued_at" \
                "$START_TIME" \
                "$status"

        done < <(jq -c '.queue.slots[]?' "$SAB_QUEUE")
    fi

    if [ "$SAB_HISTORY_OK" = true ] && [ -f "$SAB_HISTORY" ]; then

        while IFS= read -r item; do

            [ -n "$item" ] || continue

            local category
            local owner
            local download_id
            local release
            local status
            local event_epoch
            local observed_at
            local kind

            category=$(jq -r '.category // .cat // ""' <<<"$item")
            owner=$(sab_category_owner "$category")
            [ -n "$owner" ] || continue

            download_id=$(jq -r '.nzo_id // ""' <<<"$item")
            [ -n "$download_id" ] || continue
            download_id="${download_id,,}"

            release=$(jq -r '.name // .nzb_name // "Unknown SAB job"' <<<"$item")
            status=$(jq -r '.status // "unknown"' <<<"$item")
            event_epoch=$(sab_history_event_epoch "$item")
            observed_at="$event_epoch"

            case "${status,,}" in

                completed)
                    kind="sabCompleted"
                    ;;

                failed)
                    kind="sabFailed"
                    ;;

                quickcheck|verifying|repairing|fetching|extracting|moving|running|queued)
                    kind="sabQueue"
                    observed_at="$START_TIME"
                    ;;

                *)
                    continue
                    ;;
            esac

            (( event_epoch > 0 )) || event_epoch="$observed_at"

            if [ "$kind" = "sabCompleted" ] &&
               (( event_epoch < discovery_cutoff )) &&
               ! download_ledger_id_is_enrolled "$download_id"
            then
                continue
            fi

            append_download_ledger_observation \
                "$download_id" \
                "$owner" \
                "$release" \
                "$release" \
                "$kind" \
                "$event_epoch" \
                "$observed_at" \
                "$status"

        done < <(jq -c '.history.slots[]?' "$SAB_HISTORY")
    fi
}

update_download_ledger_state() {

    [ -s "$DOWNLOAD_LEDGER_OBSERVATIONS_FILE" ] || return 0

    local tmp="${TMP_DIR}/state.download-ledger.json"

    jq \
        --slurpfile observations "$DOWNLOAD_LEDGER_OBSERVATIONS_FILE" \
        --argjson enrollmentCutoff "$((START_TIME - DOWNLOAD_LEDGER_DISCOVERY_HOURS * 3600))" \
        --argjson enrollmentNow "$START_TIME" \
        '
        def epoch_max($first; $second):
            [($first // 0), ($second // 0)] | max;

        .downloadLedger = (.downloadLedger // {})
        | reduce $observations[] as $item (
            .;
            (.downloadLedger[$item.id] // {
                id: $item.id,
                app: "",
                release: "",
                title: "",
                firstSeen: $item.observedAt,
                lastSeen: 0,
                arrGrabbedAt: 0,
                arrQueueLastSeen: 0,
                arrQueueStatus: "",
                sabQueuedAt: 0,
                sabQueueLastSeen: 0,
                sabStatus: "",
                sabCompletedAt: 0,
                sabFailedAt: 0,
                arrImportedAt: 0,
                arrFailedAt: 0,
                arrIgnoredAt: 0,
                arrReconciledAt: 0,
                flowEnrolled: false,
                flowEnrolledAt: 0,
                flowEnrollmentReason: "",
                targets: {},
                originalWarning: "",
                reconciliationKind: "",
                reconciliationClassification: "",
                reconciliationSeverity: "INFO",
                reconciliationDetail: "",
                reconciliationEvidence: "",
                reconciliationFingerprint: "",
                reconciliationCandidateFingerprint: "",
                reconciliationCandidateRuns: 0,
                reconciliationCandidateFirstSeenAt: 0,
                reconciliationCandidateLastSeenAt: 0,
                reconciliationLastCheckedAt: 0,
                reconciliationNotifiedAt: 0
            }) as $old
            | (
                ($item.kind == "arrGrabbed")
                or ($item.kind == "arrQueue")
                or ($item.kind == "sabQueue")
                or (
                    ($item.kind == "sabCompleted")
                    and ($item.eventEpoch >= $enrollmentCutoff)
                )
            ) as $enrollmentObservation
            | .downloadLedger[$item.id] = (
                $old
                | .app = (if $item.app != "" then $item.app else .app end)
                | .release = (if $item.release != "" then $item.release else .release end)
                | .title = (if $item.title != "" then $item.title else .title end)
                | .lastSeen = epoch_max(.lastSeen; $item.observedAt)
                | .firstSeen = (
                    if (.firstSeen // 0) <= 0 then $item.observedAt
                    elif $item.observedAt > 0 and $item.observedAt < .firstSeen then $item.observedAt
                    else .firstSeen
                    end
                )
                | .flowEnrolled = ((.flowEnrolled // false) or $enrollmentObservation)
                | .flowEnrolledAt = (
                    if ((.flowEnrolled // false) == true) and ((.flowEnrolledAt // 0) > 0)
                    then .flowEnrolledAt
                    elif $enrollmentObservation
                    then $enrollmentNow
                    else 0
                    end
                )
                | .flowEnrollmentReason = (
                    if (($old.flowEnrolled // false) == true) and (($old.flowEnrollmentReason // "") != "")
                    then $old.flowEnrollmentReason
                    elif ($item.kind == "arrGrabbed") or ($item.kind == "arrQueue") or ($item.kind == "sabQueue")
                    then "observed-live"
                    elif $enrollmentObservation
                    then "recent-completion"
                    else (.flowEnrollmentReason // "")
                    end
                )
                | .targets = (.targets // {})
                | .originalWarning = (
                    if (.originalWarning // "") != ""
                    then .originalWarning
                    elif ($item.warning // "") != ""
                    then $item.warning
                    else ""
                    end
                )
                | if (($item.identity.type // "") != "") and
                     (($item.identity.key // "") != "") and
                     (($item.kind == "arrGrabbed") or ($item.kind == "arrQueue"))
                  then
                    ($item.identity.key) as $targetKey
                    |
                    (.targets[$targetKey] // {}) as $existingTarget
                    |
                    .targets[$targetKey] = (
                        $existingTarget
                        * $item.identity
                        |
                        .seasonNumber = (
                            $item.identity.seasonNumber
                            // $existingTarget.seasonNumber
                            // null
                        )
                        |
                        .episodeNumber = (
                            $item.identity.episodeNumber
                            // $existingTarget.episodeNumber
                            // null
                        )
                        |
                        .preFileKnown = (
                            if ($existingTarget.preFileKnown // false)
                            then true
                            else ($item.identity.preFileKnown // false)
                            end
                        )
                        |
                        .preFileId = (
                            if ($existingTarget.preFileKnown // false)
                            then ($existingTarget.preFileId // 0)
                            elif ($item.identity.preFileKnown // false)
                            then ($item.identity.preFileId // 0)
                            else 0
                            end
                        )
                    )
                  else .
                  end
            )
            | if $item.kind == "arrGrabbed" then
                .downloadLedger[$item.id].arrGrabbedAt = epoch_max(.downloadLedger[$item.id].arrGrabbedAt; $item.eventEpoch)
              elif $item.kind == "arrQueue" then
                .downloadLedger[$item.id].arrQueueLastSeen = epoch_max(.downloadLedger[$item.id].arrQueueLastSeen; $item.observedAt)
                | .downloadLedger[$item.id].arrQueueStatus = $item.status
              elif $item.kind == "arrImported" then
                .downloadLedger[$item.id].arrImportedAt = epoch_max(.downloadLedger[$item.id].arrImportedAt; $item.eventEpoch)
              elif $item.kind == "arrFailed" then
                .downloadLedger[$item.id].arrFailedAt = epoch_max(.downloadLedger[$item.id].arrFailedAt; $item.eventEpoch)
              elif $item.kind == "arrIgnored" then
                .downloadLedger[$item.id].arrIgnoredAt = epoch_max(.downloadLedger[$item.id].arrIgnoredAt; $item.eventEpoch)
              elif $item.kind == "sabQueue" then
                .downloadLedger[$item.id].sabQueuedAt = (
                    if (.downloadLedger[$item.id].sabQueuedAt // 0) <= 0
                    then $item.eventEpoch
                    else .downloadLedger[$item.id].sabQueuedAt
                    end
                )
                | .downloadLedger[$item.id].sabQueueLastSeen = epoch_max(.downloadLedger[$item.id].sabQueueLastSeen; $item.observedAt)
                | .downloadLedger[$item.id].sabStatus = $item.status
              elif $item.kind == "sabCompleted" then
                .downloadLedger[$item.id].sabCompletedAt = epoch_max(.downloadLedger[$item.id].sabCompletedAt; $item.eventEpoch)
                | .downloadLedger[$item.id].sabStatus = $item.status
              elif $item.kind == "sabFailed" then
                .downloadLedger[$item.id].sabFailedAt = epoch_max(.downloadLedger[$item.id].sabFailedAt; $item.eventEpoch)
                | .downloadLedger[$item.id].sabStatus = $item.status
              else .
              end
        )
        ' "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp"
}

download_ledger_can_evaluate() {

    case "$1" in

        Sonarr)
            [ "$SONARR_AUDIT_OK" = true ] &&
            [ "$SONARR_QUEUE_OK" = true ] &&
            [ "$SAB_HISTORY_OK" = true ] &&
            [ "$SAB_QUEUE_OK" = true ]
            ;;

        Radarr)
            [ "$RADARR_AUDIT_OK" = true ] &&
            [ "$RADARR_QUEUE_OK" = true ] &&
            [ "$SAB_HISTORY_OK" = true ] &&
            [ "$SAB_QUEUE_OK" = true ]
            ;;

        *)
            return 1
            ;;
    esac
}

url_encode_query_value() {

    local value="$1"

    jq -rn --arg value "$value" '$value | @uri'
}

write_download_reconciliation_result() {

    local download_id="$1"
    local app="$2"
    local scan_ok="$3"
    local evidence_found="$4"
    local kind="${5:-}"
    local classification="${6:-}"
    local severity="${7:-INFO}"
    local fingerprint="${8:-}"
    local evidence="${9:-}"
    local detail="${10:-}"

    jq -nc \
        --arg id "${download_id,,}" \
        --arg app "$app" \
        --argjson scanOk "$scan_ok" \
        --argjson evidenceFound "$evidence_found" \
        --arg kind "$kind" \
        --arg classification "$classification" \
        --arg severity "$severity" \
        --arg fingerprint "$fingerprint" \
        --arg evidence "$evidence" \
        --arg detail "$detail" \
        '{
            id: $id,
            app: $app,
            scanOk: $scanOk,
            evidenceFound: $evidenceFound,
            kind: $kind,
            classification: $classification,
            severity: $severity,
            fingerprint: $fingerprint,
            evidence: $evidence,
            detail: $detail
        }' >>"$DOWNLOAD_LEDGER_RECONCILIATION_RESULTS_FILE"
}

fetch_arr_history_by_download_id() {

    local app="$1"
    local download_id="$2"
    local output="$3"
    local base_url
    local api_key
    local include_query
    local encoded_id

    case "$app" in
        Sonarr)
            base_url="$SONARR_URL"
            api_key="$SONARR_API_KEY"
            include_query="includeSeries=true&includeEpisode=true"
            ;;

        Radarr)
            base_url="$RADARR_URL"
            api_key="$RADARR_API_KEY"
            include_query="includeMovie=true"
            ;;

        *)
            API_LAST_ERROR="unsupported Arr application"
            return 1
            ;;
    esac

    encoded_id=$(url_encode_query_value "$download_id")

    api_get \
        "${base_url%/}/api/v3/history?page=1&pageSize=100&sortKey=date&sortDirection=descending&downloadId=${encoded_id}&${include_query}" \
        "$api_key" \
        "$output"
}

collect_targeted_history_identities() {

    local app="$1"
    local history_page="$2"
    local identity_history="$3"

    jq '
        [
            .records[]?
            | select(.eventType == "grabbed")
        ]
        ' "$history_page" >"$identity_history" || return 1

    collect_arr_download_ledger \
        "$app" \
        "$identity_history" \
        "${TMP_DIR}/no-arr-queue-for-targeted-history.json"
}

record_exact_history_reconciliation() {

    local download_id="$1"
    local app="$2"
    local history_page="$3"
    local terminal
    local event_type
    local event_date
    local event_id
    local classification
    local severity
    local kind
    local evidence
    local detail
    local fingerprint

    terminal=$(jq -c \
        --arg downloadId "${download_id,,}" \
        '
        [
            .records[]?
            | select(
                ((.downloadId // .data.downloadId // "") | ascii_downcase)
                == $downloadId
            )
            | select(
                .eventType == "downloadFolderImported"
                or .eventType == "downloadFailed"
                or .eventType == "downloadIgnored"
            )
        ]
        | sort_by(.date // "")
        | last
        // empty
        ' "$history_page")

    [ -n "$terminal" ] || return 1

    event_type=$(jq -r '.eventType // "unknown"' <<<"$terminal")
    event_date=$(jq -r '.date // "unknown"' <<<"$terminal")
    event_id=$(jq -r '.id // "unknown"' <<<"$terminal")

    case "$event_type" in
        downloadFolderImported)
            kind="exact-history-imported"
            classification="DOWNLOAD_FLOW_RECONCILED_IMPORTED"
            severity="INFO"
            ;;

        downloadFailed)
            kind="exact-history-failed"
            classification="DOWNLOAD_FLOW_RECONCILED_FAILED"
            severity="ERROR"
            ;;

        downloadIgnored)
            kind="exact-history-ignored"
            classification="DOWNLOAD_FLOW_RECONCILED_IGNORED"
            severity="WARNING"
            ;;

        *)
            return 1
            ;;
    esac

    evidence="${app} exact history returned ${event_type} at ${event_date}"
    detail="History event ID: ${event_id}"$'\n'
    detail+="History event: ${event_type}"$'\n'
    detail+="History date: ${event_date}"
    fingerprint=$(printf '%s' \
        "${app}|${download_id,,}|${event_type}|${event_id}|${event_date}" |
        sha256sum |
        awk '{print $1}')

    write_download_reconciliation_result \
        "$download_id" \
        "$app" \
        true \
        true \
        "$kind" \
        "$classification" \
        "$severity" \
        "$fingerprint" \
        "$evidence" \
        "$detail"

    return 0
}

arr_reconciliation_connection() {

    case "$1" in
        Sonarr)
            printf '%s\t%s\n' "$SONARR_URL" "$SONARR_API_KEY"
            ;;

        Radarr)
            printf '%s\t%s\n' "$RADARR_URL" "$RADARR_API_KEY"
            ;;

        *)
            return 1
            ;;
    esac
}

record_arr_database_file_reconciliation() {

    local download_id="$1"
    local app="$2"
    local record="$3"
    local connection
    local base_url
    local api_key
    local start_epoch
    local targets_file
    local target_count
    local target
    local target_type
    local target_id
    local parent_id
    local season_number
    local episode_number
    local pre_file_known
    local pre_file_id
    local object_file
    local media_file
    local current_parent_id
    local current_season_number
    local current_episode_number
    local has_file
    local file_id
    local file_date
    local file_date_epoch
    local file_path
    local file_parent_id
    local identity_valid
    local freshness_valid
    local evidence_file
    local fingerprint_source=""
    local detail=""
    local fingerprint

    connection=$(arr_reconciliation_connection "$app") || {
        write_download_reconciliation_result \
            "$download_id" "$app" false false
        return 1
    }

    IFS=$'\t' read -r base_url api_key <<<"$connection"

    start_epoch=$(jq -r '
        if (.sabQueuedAt // 0) > 0
        then .sabQueuedAt
        else (.arrGrabbedAt // 0)
        end
        ' <<<"$record")
    [[ "$start_epoch" =~ ^[0-9]+$ ]] || start_epoch=0

    targets_file=$(mktemp "${TMP_DIR}/arr-reconcile-targets.XXXXXX") || return 1
    evidence_file=$(mktemp "${TMP_DIR}/arr-reconcile-evidence.XXXXXX") || return 1
    : >"$evidence_file"

    jq -c \
        --arg app "$app" \
        '
        .targets
        // {}
        | to_entries[]?
        | .value
        | select(
            ($app == "Sonarr" and .type == "episode")
            or ($app == "Radarr" and .type == "movie")
        )
        ' <<<"$record" >"$targets_file"

    target_count=$(wc -l <"$targets_file" | tr -d ' ')

    if (( target_count <= 0 )); then
        write_download_reconciliation_result \
            "$download_id" \
            "$app" \
            true \
            false \
            "" \
            "" \
            "INFO" \
            "" \
            "No exact Arr object identity is available" \
            "Title-based recovery was intentionally refused"
        return 0
    fi

    while IFS= read -r target; do

        [ -n "$target" ] || continue

        target_type=$(jq -r '.type' <<<"$target")
        pre_file_known=$(jq -r '(.preFileKnown // false) | tostring' <<<"$target")
        pre_file_id=$(jq -r '.preFileId // 0' <<<"$target")
        [[ "$pre_file_id" =~ ^[0-9]+$ ]] || pre_file_id=0

        identity_valid=false
        freshness_valid=false

        case "$target_type" in

            episode)
                target_id=$(jq -r '.episodeId // 0' <<<"$target")
                parent_id=$(jq -r '.seriesId // 0' <<<"$target")
                season_number=$(jq -r '.seasonNumber // -1' <<<"$target")
                episode_number=$(jq -r '.episodeNumber // -1' <<<"$target")

                if ! [[ "$target_id" =~ ^[0-9]+$ ]] || (( target_id <= 0 )) ||
                   ! [[ "$parent_id" =~ ^[0-9]+$ ]] || (( parent_id <= 0 )) ||
                   ! [[ "$season_number" =~ ^-?[0-9]+$ ]] || (( season_number < 0 )) ||
                   ! [[ "$episode_number" =~ ^-?[0-9]+$ ]] || (( episode_number < 0 ))
                then
                    write_download_reconciliation_result \
                        "$download_id" "$app" true false \
                        "" "" "INFO" "" \
                        "Stored Sonarr identity is incomplete" \
                        "Exact numeric series, season and episode identity is required"
                    return 0
                fi

                object_file="${TMP_DIR}/sonarr-reconcile-episode-${target_id}.json"

                if ! api_get \
                    "${base_url%/}/api/v3/episode/${target_id}" \
                    "$api_key" \
                    "$object_file"
                then
                    ((DOWNLOAD_LEDGER_RECONCILIATION_FAILED_COUNT++)) || true
                    write_download_reconciliation_result \
                        "$download_id" "$app" false false \
                        "" "" "INFO" "" \
                        "Sonarr episode API check failed" \
                        "Episode ID: ${target_id}; ${API_LAST_ERROR}"
                    return 1
                fi

                current_parent_id=$(jq -r '.seriesId // 0' "$object_file")
                current_season_number=$(jq -r '.seasonNumber // -1' "$object_file")
                current_episode_number=$(jq -r '.episodeNumber // -1' "$object_file")
                has_file=$(jq -r '(.hasFile // false) | tostring' "$object_file")
                file_id=$(jq -r '.episodeFileId // 0' "$object_file")

                if [[ "$target_id" =~ ^[0-9]+$ ]] && (( target_id > 0 )) &&
                   [[ "$parent_id" =~ ^[0-9]+$ ]] && (( parent_id > 0 )) &&
                   [[ "$file_id" =~ ^[0-9]+$ ]] && (( file_id > 0 )) &&
                   [ "$has_file" = true ] &&
                   [ "$current_parent_id" = "$parent_id" ] &&
                   [ "$current_season_number" = "$season_number" ] &&
                   [ "$current_episode_number" = "$episode_number" ]
                then
                    identity_valid=true
                fi

                [ "$identity_valid" = true ] || {
                    write_download_reconciliation_result \
                        "$download_id" "$app" true false \
                        "" "" "INFO" "" \
                        "Exact Sonarr episode does not have a valid matching file record" \
                        "Series ID: ${parent_id}; episode ID: ${target_id}"
                    return 0
                }

                media_file="${TMP_DIR}/sonarr-reconcile-episodefile-${file_id}.json"

                if ! api_get \
                    "${base_url%/}/api/v3/episodefile/${file_id}" \
                    "$api_key" \
                    "$media_file"
                then
                    ((DOWNLOAD_LEDGER_RECONCILIATION_FAILED_COUNT++)) || true
                    write_download_reconciliation_result \
                        "$download_id" "$app" false false \
                        "" "" "INFO" "" \
                        "Sonarr episode-file API check failed" \
                        "Episode file ID: ${file_id}; ${API_LAST_ERROR}"
                    return 1
                fi

                file_parent_id=$(jq -r '.seriesId // 0' "$media_file")
                current_season_number=$(jq -r '.seasonNumber // -1' "$media_file")
                ;;

            movie)
                target_id=$(jq -r '.movieId // 0' <<<"$target")
                parent_id="$target_id"
                season_number=-1
                episode_number=-1

                if ! [[ "$target_id" =~ ^[0-9]+$ ]] || (( target_id <= 0 )); then
                    write_download_reconciliation_result \
                        "$download_id" "$app" true false \
                        "" "" "INFO" "" \
                        "Stored Radarr identity is incomplete" \
                        "Exact numeric movie identity is required"
                    return 0
                fi

                object_file="${TMP_DIR}/radarr-reconcile-movie-${target_id}.json"

                if ! api_get \
                    "${base_url%/}/api/v3/movie/${target_id}" \
                    "$api_key" \
                    "$object_file"
                then
                    ((DOWNLOAD_LEDGER_RECONCILIATION_FAILED_COUNT++)) || true
                    write_download_reconciliation_result \
                        "$download_id" "$app" false false \
                        "" "" "INFO" "" \
                        "Radarr movie API check failed" \
                        "Movie ID: ${target_id}; ${API_LAST_ERROR}"
                    return 1
                fi

                has_file=$(jq -r '(.hasFile // false) | tostring' "$object_file")
                file_id=$(jq -r '.movieFileId // 0' "$object_file")

                if [[ "$target_id" =~ ^[0-9]+$ ]] && (( target_id > 0 )) &&
                   [[ "$file_id" =~ ^[0-9]+$ ]] && (( file_id > 0 )) &&
                   [ "$has_file" = true ]
                then
                    identity_valid=true
                fi

                [ "$identity_valid" = true ] || {
                    write_download_reconciliation_result \
                        "$download_id" "$app" true false \
                        "" "" "INFO" "" \
                        "Exact Radarr movie does not have a valid file record" \
                        "Movie ID: ${target_id}"
                    return 0
                }

                media_file="${TMP_DIR}/radarr-reconcile-moviefile-${file_id}.json"

                if ! api_get \
                    "${base_url%/}/api/v3/moviefile/${file_id}" \
                    "$api_key" \
                    "$media_file"
                then
                    ((DOWNLOAD_LEDGER_RECONCILIATION_FAILED_COUNT++)) || true
                    write_download_reconciliation_result \
                        "$download_id" "$app" false false \
                        "" "" "INFO" "" \
                        "Radarr movie-file API check failed" \
                        "Movie file ID: ${file_id}; ${API_LAST_ERROR}"
                    return 1
                fi

                file_parent_id=$(jq -r '.movieId // 0' "$media_file")
                current_season_number=-1
                ;;

            *)
                write_download_reconciliation_result \
                    "$download_id" "$app" true false \
                    "" "" "INFO" "" \
                    "Unsupported exact Arr target type" \
                    "Target type: ${target_type}"
                return 0
                ;;
        esac

        file_date=$(jq -r '.dateAdded // ""' "$media_file")
        file_date_epoch=$(date_to_epoch "$file_date")
        file_path=$(jq -r '.path // ""' "$media_file")

        if [ "$file_parent_id" != "$parent_id" ] ||
           [ -z "$file_path" ] ||
           { [ "$target_type" = episode ] &&
             [ "$current_season_number" != "$season_number" ]; }
        then
            write_download_reconciliation_result \
                "$download_id" "$app" true false \
                "" "" "INFO" "" \
                "Arr file record identity or database path did not match" \
                "Target ID: ${target_id}; file ID: ${file_id}"
            return 0
        fi

        if (( start_epoch > 0 && file_date_epoch > 0 )) &&
           (( file_date_epoch + DOWNLOAD_LEDGER_RECONCILE_CLOCK_SKEW_SECONDS >= start_epoch ))
        then
            freshness_valid=true
        elif [ "$pre_file_known" = true ] &&
             (( file_id != pre_file_id ))
        then
            freshness_valid=true
        fi

        [ "$freshness_valid" = true ] || {
            write_download_reconciliation_result \
                "$download_id" "$app" true false \
                "" "" "INFO" "" \
                "Arr file record exists but cannot be tied to this download" \
                "Target ID: ${target_id}; file ID: ${file_id}; dateAdded: ${file_date:-unknown}"
            return 0
        }

        if [ "$target_type" = episode ]; then
            printf '%s\n' \
                "Episode ${target_id} (S${season_number}E${episode_number}) -> episode file ${file_id}, dateAdded ${file_date}" \
                >>"$evidence_file"
        else
            printf '%s\n' \
                "Movie ${target_id} -> movie file ${file_id}, dateAdded ${file_date}" \
                >>"$evidence_file"
        fi

        fingerprint_source+="${target_type}:${target_id}:${file_id}:${file_date}|"

    done <"$targets_file"

    detail=$(sed '/^$/d' "$evidence_file")
    fingerprint=$(printf '%s' "${app}|${download_id,,}|${fingerprint_source}" |
        sha256sum |
        awk '{print $1}')

    write_download_reconciliation_result \
        "$download_id" \
        "$app" \
        true \
        true \
        "verified-arr-file-record" \
        "DOWNLOAD_FLOW_RECONCILED_FILE" \
        "INFO" \
        "$fingerprint" \
        "Exact Arr object and file database records remained valid" \
        "$detail"
}

update_download_reconciliation_state() {

    [ -s "$DOWNLOAD_LEDGER_RECONCILIATION_RESULTS_FILE" ] || return 0

    local tmp="${TMP_DIR}/state.download-reconciliation.json"

    jq \
        --slurpfile results "$DOWNLOAD_LEDGER_RECONCILIATION_RESULTS_FILE" \
        --argjson now "$START_TIME" \
        --argjson confirmRuns "$DOWNLOAD_LEDGER_RECONCILE_CONFIRM_RUNS" \
        '
        reduce $results[] as $result (
            .;
            ($result.id // "") as $id
            |
            if ($id == "") or (.downloadLedger[$id] == null)
            then .
            elif ($result.scanOk // false) != true
            then .
            else
                .downloadLedger[$id].reconciliationLastCheckedAt = $now
                |
                if ($result.evidenceFound // false) != true
                then
                    .downloadLedger[$id].reconciliationCandidateFingerprint = ""
                    |
                    .downloadLedger[$id].reconciliationCandidateRuns = 0
                    |
                    .downloadLedger[$id].reconciliationCandidateFirstSeenAt = 0
                    |
                    .downloadLedger[$id].reconciliationCandidateLastSeenAt = 0
                else
                    (
                        if
                            (.downloadLedger[$id].reconciliationCandidateFingerprint // "")
                            == ($result.fingerprint // "")
                            and
                            (.downloadLedger[$id].reconciliationCandidateRuns // 0) > 0
                        then
                            (.downloadLedger[$id].reconciliationCandidateRuns // 0) + 1
                        else 1
                        end
                    ) as $candidateRuns
                    |
                    .downloadLedger[$id].reconciliationCandidateFingerprint = (
                        $result.fingerprint // ""
                    )
                    |
                    .downloadLedger[$id].reconciliationCandidateRuns = $candidateRuns
                    |
                    .downloadLedger[$id].reconciliationCandidateFirstSeenAt = (
                        if $candidateRuns == 1
                        then $now
                        else (
                            .downloadLedger[$id].reconciliationCandidateFirstSeenAt
                            // $now
                        )
                        end
                    )
                    |
                    .downloadLedger[$id].reconciliationCandidateLastSeenAt = $now
                    |
                    if $candidateRuns >= $confirmRuns
                    then
                        .downloadLedger[$id].arrReconciledAt = $now
                        |
                        .downloadLedger[$id].reconciliationKind = (
                            $result.kind // ""
                        )
                        |
                        .downloadLedger[$id].reconciliationClassification = (
                            $result.classification // "DOWNLOAD_FLOW_RECONCILED"
                        )
                        |
                        .downloadLedger[$id].reconciliationSeverity = (
                            $result.severity // "INFO"
                        )
                        |
                        .downloadLedger[$id].reconciliationDetail = (
                            $result.detail // ""
                        )
                        |
                        .downloadLedger[$id].reconciliationEvidence = (
                            $result.evidence // ""
                        )
                        |
                        .downloadLedger[$id].reconciliationFingerprint = (
                            $result.fingerprint // ""
                        )
                        |
                        .downloadLedger[$id].lastSeen = $now
                    else .
                    end
                end
            end
        )
        ' "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp"

    DOWNLOAD_LEDGER_RECONCILED_COUNT=$(jq -r \
        --argjson now "$START_TIME" \
        '[
            .downloadLedger[]?
            | select((.arrReconciledAt // 0) == $now)
        ]
        | length' "$STATE_FILE")
    DOWNLOAD_LEDGER_RECONCILIATION_PENDING_COUNT=$(jq -r '
        [
            .downloadLedger[]?
            | select((.arrReconciledAt // 0) <= 0)
            | select((.reconciliationCandidateRuns // 0) > 0)
        ]
        | length' "$STATE_FILE")
}

queue_download_reconciliation_notifications() {

    local records_file="${TMP_DIR}/download-reconciled-records.jsonl"

    jq -c '
        .downloadLedger
        // {}
        | to_entries[]?
        | .value
        | select((.arrReconciledAt // 0) > 0)
        | select(
            (.reconciliationNotifiedAt // 0)
            < (.arrReconciledAt // 0)
        )
        ' "$STATE_FILE" >"$records_file" || return 1

    while IFS= read -r record; do

        [ -n "$record" ] || continue

        local download_id
        local app
        local title
        local release
        local classification
        local severity
        local kind
        local evidence
        local reconciliation_detail
        local original_warning
        local queue_status
        local original_ack_id
        local issue_key
        local signature
        local detail

        download_id=$(jq -r '.id' <<<"$record")
        app=$(jq -r '.app // "Arr"' <<<"$record")
        title=$(jq -r '.title // .release // "Unknown download"' <<<"$record")
        release=$(jq -r '.release // "Unknown release"' <<<"$record")
        classification=$(jq -r '.reconciliationClassification // "DOWNLOAD_FLOW_RECONCILED"' <<<"$record")
        severity=$(jq -r '.reconciliationSeverity // "INFO"' <<<"$record")
        kind=$(jq -r '.reconciliationKind // "unknown"' <<<"$record")
        evidence=$(jq -r '.reconciliationEvidence // ""' <<<"$record")
        reconciliation_detail=$(jq -r '.reconciliationDetail // ""' <<<"$record")
        original_warning=$(jq -r '.originalWarning // "not captured"' <<<"$record")
        queue_status=$(jq -r '.arrQueueStatus // "not observed"' <<<"$record")
        original_ack_id=$(issue_ack_id "FLOW:DOWNLOAD:${download_id}")
        issue_key="FLOW:RECONCILIATION:${download_id}"

        detail="Download ID: ${download_id}"$'\n'
        detail+="Release: ${release}"$'\n'
        detail+="Recovery method: ${kind}"$'\n'
        detail+="Evidence: ${evidence}"$'\n'
        [ -n "$reconciliation_detail" ] && \
            detail+="${reconciliation_detail}"$'\n'
        detail+="Original queue state: ${queue_status}"$'\n'
        detail+="Original warning: ${original_warning:-not captured}"$'\n'
        detail+="Original Ack ID: ${original_ack_id}"$'\n'
        detail+="Action taken: closed the monitor's missing-terminal-event issue automatically"$'\n'
        detail+="Arr/SAB/media changes: none"$'\n'
        detail+="Reconciliation verification: Arr API database records only"$'\n'
        detail+="Reconciliation media-path access: none"
        detail+=$'\n'
        detail+="Confirmation scans: ${DOWNLOAD_LEDGER_RECONCILE_CONFIRM_RUNS}"

        signature=$(issue_signature \
            "$app" \
            "$issue_key" \
            "$classification" \
            "$severity" \
            "reconciled" \
            "$(jq -r '.reconciliationFingerprint // ""' <<<"$record")")

        queue_group_notification \
            "$issue_key" \
            "$signature" \
            "$app" \
            "$title" \
            "$classification" \
            "$severity" \
            "0" \
            "$detail" \
            "reconciled"

        if (( $(jq -r '.arrReconciledAt // 0' <<<"$record") == START_TIME )); then
            persistent_log \
                "RECONCILED" \
                "${app} | ${classification} | ${title} | download_id=${download_id} | method=${kind} | original_ack_id=${original_ack_id}"
        fi

    done <"$records_file"
}

perform_download_ledger_reconciliation() {

    [ "$DOWNLOAD_LEDGER_RECONCILE_ENABLED" = true ] || return 0

    local candidates_file="${TMP_DIR}/download-reconciliation-candidates.jsonl"
    local file_candidates="${TMP_DIR}/download-reconciliation-file-candidates.txt"
    local record
    local download_id
    local app
    local history_page
    local identity_history
    local refreshed_record
    local candidate_key

    : >"$DOWNLOAD_LEDGER_RECONCILIATION_RESULTS_FILE"
    : >"$file_candidates"

    jq -c \
        --argjson now "$START_TIME" \
        --argjson minimumMinutes "$DOWNLOAD_LEDGER_IMPORT_WARN_MINUTES" \
        --argjson maximum "$DOWNLOAD_LEDGER_RECONCILE_MAX_RECORDS" \
        '
        .issues as $issues
        |
        [
            .downloadLedger
            // {}
            | to_entries[]?
            | select((.value.flowEnrolled // false) == true)
            | select((.value.sabCompletedAt // 0) > 0)
            | select((.value.arrImportedAt // 0) <= 0)
            | select((.value.arrFailedAt // 0) <= 0)
            | select((.value.arrIgnoredAt // 0) <= 0)
            | select((.value.sabFailedAt // 0) <= 0)
            | select((.value.arrReconciledAt // 0) <= 0)
            | select(
                (($now - (.value.sabCompletedAt // $now)) / 60)
                >= $minimumMinutes
            )
            | . as $entry
            | {
                activeRank: (
                    if ($issues["FLOW:DOWNLOAD:" + .key].active // false)
                    then 0
                    else 1
                    end
                ),
                completedAt: (.value.sabCompletedAt // 0),
                record: .value
            }
        ]
        | sort_by(.activeRank, .completedAt)
        | .[:$maximum]
        | .[].record
        ' "$STATE_FILE" >"$candidates_file" || return 1

    while IFS= read -r record; do

        [ -n "$record" ] || continue

        download_id=$(jq -r '.id' <<<"$record")
        app=$(jq -r '.app // ""' <<<"$record")

        download_ledger_can_evaluate "$app" || continue
        ((DOWNLOAD_LEDGER_RECONCILIATION_CHECKED_COUNT++)) || true

        candidate_key=$(stable_issue_hash "${app}|${download_id}")
        history_page="${TMP_DIR}/${app,,}-reconcile-history-${candidate_key}.json"
        identity_history="${TMP_DIR}/${app,,}-reconcile-identities-${candidate_key}.json"

        if ! fetch_arr_history_by_download_id \
            "$app" \
            "$download_id" \
            "$history_page"
        then
            ((DOWNLOAD_LEDGER_RECONCILIATION_FAILED_COUNT++)) || true
            log "WARNING: ${app} exact history reconciliation failed for ${download_id}: ${API_LAST_ERROR}"
            write_download_reconciliation_result \
                "$download_id" "$app" false false \
                "" "" "INFO" "" \
                "Exact history API check failed" \
                "$API_LAST_ERROR"
            continue
        fi

        collect_targeted_history_identities \
            "$app" \
            "$history_page" \
            "$identity_history" || true

        if record_exact_history_reconciliation \
            "$download_id" \
            "$app" \
            "$history_page"
        then
            continue
        fi

        printf '%s\t%s\n' "$download_id" "$app" >>"$file_candidates"

    done <"$candidates_file"

    # Merge exact identities discovered from targeted history before the
    # database-file fallback evaluates Sonarr/Radarr object records.
    if ! update_download_ledger_state; then
        log "ERROR: Unable to merge targeted Arr identities into download ledger"
        return 1
    fi

    while IFS=$'\t' read -r download_id app; do

        [ -n "$download_id" ] || continue

        refreshed_record=$(jq -c \
            --arg id "${download_id,,}" \
            '.downloadLedger[$id] // empty' \
            "$STATE_FILE")

        [ -n "$refreshed_record" ] || continue

        record_arr_database_file_reconciliation \
            "$download_id" \
            "$app" \
            "$refreshed_record" || true

    done <"$file_candidates"

    if ! update_download_reconciliation_state; then
        log "ERROR: Unable to update automatic download reconciliation state"
        return 1
    fi

    queue_download_reconciliation_notifications || return 1
}

process_download_ledger_issues() {

    local now
    local records_file="${TMP_DIR}/download-ledger-records.jsonl"

    now=$(date +%s)

    jq -c \
        '.downloadLedger // {} | to_entries[]? | .value' \
        "$STATE_FILE" >"$records_file" || return 1

    while IFS= read -r record; do

        [ -n "$record" ] || continue

        local download_id
        local app
        local title
        local release
        local grabbed_at
        local sab_queued_at
        local sab_queue_last_seen
        local sab_completed_at
        local sab_failed_at
        local arr_imported_at
        local arr_failed_at
        local arr_ignored_at
        local arr_reconciled_at
        local reconciliation_candidate_runs
        local flow_enrolled
        local last_sab_seen
        local classification=""
        local message=""
        local age_minutes=0
        local severity="WARNING"
        local stage="warning"
        local detail
        local current_arr_issue=false

        download_id=$(jq -r '.id' <<<"$record")
        app=$(jq -r '.app // ""' <<<"$record")
        flow_enrolled=$(jq -r '(.flowEnrolled // false) | tostring' <<<"$record")

        download_ledger_can_evaluate "$app" || continue
        [ "$flow_enrolled" = true ] || continue

        title=$(jq -r '.title // .release // "Unknown download"' <<<"$record")
        release=$(jq -r '.release // "Unknown release"' <<<"$record")
        grabbed_at=$(jq -r '.arrGrabbedAt // 0' <<<"$record")
        sab_queued_at=$(jq -r '.sabQueuedAt // 0' <<<"$record")
        sab_queue_last_seen=$(jq -r '.sabQueueLastSeen // 0' <<<"$record")
        sab_completed_at=$(jq -r '.sabCompletedAt // 0' <<<"$record")
        sab_failed_at=$(jq -r '.sabFailedAt // 0' <<<"$record")
        arr_imported_at=$(jq -r '.arrImportedAt // 0' <<<"$record")
        arr_failed_at=$(jq -r '.arrFailedAt // 0' <<<"$record")
        arr_ignored_at=$(jq -r '.arrIgnoredAt // 0' <<<"$record")
        arr_reconciled_at=$(jq -r '.arrReconciledAt // 0' <<<"$record")
        reconciliation_candidate_runs=$(jq -r '.reconciliationCandidateRuns // 0' <<<"$record")

        if (( arr_imported_at > 0 || arr_failed_at > 0 || arr_ignored_at > 0 || arr_reconciled_at > 0 || sab_failed_at > 0 )); then
            continue
        fi

        if grep -Fxiq -- "${app}:${download_id}" "$SEEN_ISSUES_FILE" 2>/dev/null; then
            current_arr_issue=true
        fi

        if [ "$current_arr_issue" = true ] || sab_primary_download_exists "$download_id"; then
            continue
        fi

        if (( sab_completed_at > 0 )); then

            age_minutes=$(( (now - sab_completed_at) / 60 ))

            if (( age_minutes >= DOWNLOAD_LEDGER_IMPORT_WARN_MINUTES )); then
                classification="DOWNLOAD_FLOW_IMPORT_MISSING"
                message="SABnzbd completed the download but ${app} has no matching import or failure event"
                ((DOWNLOAD_LEDGER_IMPORT_MISSING_COUNT++)) || true
            fi

        else

            last_sab_seen="$sab_queue_last_seen"
            (( sab_queued_at > last_sab_seen )) && last_sab_seen="$sab_queued_at"

            if (( last_sab_seen > 0 && sab_queue_last_seen < START_TIME )); then

                age_minutes=$(( (now - last_sab_seen) / 60 ))

                if (( age_minutes >= DOWNLOAD_LEDGER_SAB_VANISHED_WARN_MINUTES )); then
                    classification="DOWNLOAD_FLOW_SAB_VANISHED"
                    message="The download was previously observed in SABnzbd but is no longer in its queue or history and ${app} recorded no terminal event"
                    ((DOWNLOAD_LEDGER_VANISHED_COUNT++)) || true
                fi

            elif (( grabbed_at > 0 && sab_queued_at <= 0 && sab_queue_last_seen <= 0 )); then

                age_minutes=$(( (now - grabbed_at) / 60 ))

                if (( age_minutes >= DOWNLOAD_LEDGER_GRAB_TO_SAB_WARN_MINUTES )); then
                    classification="DOWNLOAD_FLOW_NOT_REACHED_SAB"
                    message="${app} recorded the grab but the matching download ID never appeared in SABnzbd"
                    ((DOWNLOAD_LEDGER_NOT_REACHED_COUNT++)) || true
                fi
            fi
        fi

        [ -n "$classification" ] || continue
        (( age_minutes >= 0 )) || age_minutes=0

        # A matching automatic-recovery candidate must survive two successful
        # scans. Keep an existing issue active during that short grace period,
        # but do not send a reminder that would race the pending reconciliation.
        if (( reconciliation_candidate_runs > 0 )); then
            mark_seen "FLOW:DOWNLOAD:${download_id}"
            log "Automatic reconciliation pending ${reconciliation_candidate_runs}/${DOWNLOAD_LEDGER_RECONCILE_CONFIRM_RUNS}: ${app} ${download_id}"
            continue
        fi

        if (( age_minutes >= DOWNLOAD_LEDGER_ESCALATE_MINUTES )); then
            severity="ERROR"
            stage="escalated"
        fi

        detail="Download ID: ${download_id}"$'\n'
        detail+="Release: ${release}"$'\n'
        detail+="Exact flow age: ${age_minutes} minute(s)"$'\n'
        detail+="Last Arr queue status: $(jq -r '.arrQueueStatus // "not observed"' <<<"$record")"$'\n'
        detail+="Last SAB status: $(jq -r '.sabStatus // "not observed"' <<<"$record")"

        record_normalized_issue \
            "FLOW:DOWNLOAD:${download_id}" \
            "$app" \
            "$title" \
            "$classification" \
            "$severity" \
            "$stage" \
            "$message" \
            "$((age_minutes / 60))" \
            "$detail" \
            1 \
            0 \
            0 \
            "download-ledger" \
            "$classification"

        ((DOWNLOAD_LEDGER_ISSUE_COUNT++)) || true

    done <"$records_file"
}

process_exact_download_ledger() {

    DOWNLOAD_LEDGER_SCAN_OK=false

    [ "$DOWNLOAD_LEDGER_ENABLED" = true ] || return 0
    [ "$ACTIVITY_AUDIT_ENABLED" = true ] || return 0

    : >"$DOWNLOAD_LEDGER_OBSERVATIONS_FILE"

    if ! prepare_download_ledger_enrollment_cache; then
        log "ERROR: Unable to prepare exact download workflow enrollment cache"
        return 1
    fi

    if [ "$SONARR_AUDIT_OK" = true ]; then
        collect_arr_download_ledger \
            "Sonarr" \
            "$SONARR_AUDIT_HISTORY" \
            "$SONARR_QUEUE"
    fi

    if [ "$RADARR_AUDIT_OK" = true ]; then
        collect_arr_download_ledger \
            "Radarr" \
            "$RADARR_AUDIT_HISTORY" \
            "$RADARR_QUEUE"
    fi

    collect_sab_download_ledger

    if ! update_download_ledger_state; then
        log "ERROR: Unable to update exact download workflow ledger"
        return 1
    fi

    if ! perform_download_ledger_reconciliation; then
        log "ERROR: Unable to complete automatic download reconciliation"
        return 1
    fi

    if ! process_download_ledger_issues; then
        log "ERROR: Unable to evaluate exact download workflow ledger"
        return 1
    fi

    DOWNLOAD_LEDGER_SCAN_OK=true
    return 0
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
#
# Exact download ledger and SAB provider baselines:
#   Old records are pruned independently from active issue lifecycle state.
###############################################################################

prune_state() {

    local issue_cutoff
    local telemetry_cutoff
    local ledger_cutoff
    local tmp

    issue_cutoff=$(
        date -d "${STATE_RETENTION_DAYS} days ago" '+%s'
    )

    telemetry_cutoff=$(
        date -d "${ARR_TELEMETRY_RETENTION_DAYS} days ago" '+%s'
    )

    ledger_cutoff=$(
        date -d "${DOWNLOAD_LEDGER_RETENTION_DAYS} days ago" '+%s'
    )

    tmp="$TMP_DIR/state.pruned.json"

    jq \
        --argjson issueCutoff "$issue_cutoff" \
        --argjson telemetryCutoff "$telemetry_cutoff" \
        --argjson ledgerCutoff "$ledger_cutoff" \
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

        .issues as $issues

        |

        .downloadLedger = (
            (.downloadLedger // {})
            | with_entries(
                select(
                    (.value.lastSeen // 0) >= $ledgerCutoff
                    or
                    (.value.arrImportedAt // 0) >= $ledgerCutoff
                    or
                    (.value.arrFailedAt // 0) >= $ledgerCutoff
                    or
                    (.value.arrIgnoredAt // 0) >= $ledgerCutoff
                    or
                    (.value.arrReconciledAt // 0) >= $ledgerCutoff
                    or
                    (.value.sabFailedAt // 0) >= $ledgerCutoff
                    or
                    (
                        $issues["FLOW:DOWNLOAD:" + .key].active
                        // false
                    ) == true
                )
            )
        )

        |

        .sabServerStats = (
            (.sabServerStats // {})
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
require_command tail
require_command sleep
require_command mountpoint
require_command pgrep

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
DOWNLOAD_LEDGER_OBSERVATIONS_FILE="${TMP_DIR}/download_ledger_observations.jsonl"
DOWNLOAD_LEDGER_ENROLLED_IDS_FILE="${TMP_DIR}/download_ledger_enrolled_ids.txt"
DOWNLOAD_LEDGER_RECONCILIATION_RESULTS_FILE="${TMP_DIR}/download_ledger_reconciliation_results.jsonl"

: >"$NOTIFICATION_BATCH"
: >"$SEEN_ISSUES_FILE"
: >"$SAB_PRIMARY_DOWNLOADS_FILE"
: >"$SAB_PROGRESS_SEEN_FILE"
: >"$SAB_PROGRESS_OBSERVATIONS_FILE"
: >"$DOWNLOAD_LEDGER_OBSERVATIONS_FILE"
: >"$DOWNLOAD_LEDGER_ENROLLED_IDS_FILE"
: >"$DOWNLOAD_LEDGER_RECONCILIATION_RESULTS_FILE"

###############################################################################
# STATE
###############################################################################

ensure_state_storage_ready

initialize_state

case "${1:-}" in
    --list-active)
        list_active_issues
        exit 0
        ;;

    --ack)
        if [ -z "${2:-}" ]; then
            print_lifecycle_command_help
            exit 2
        fi

        acknowledge_active_issue "$2" "${*:3}" || exit 2
        exit 0
        ;;

    --unack)
        if [ -z "${2:-}" ]; then
            print_lifecycle_command_help
            exit 2
        fi

        unacknowledge_active_issue "$2" || exit 2
        exit 0
        ;;

    --help|--lifecycle-help)
        print_lifecycle_command_help
        exit 0
        ;;
esac

if ! begin_monitor_run; then
    log "ERROR: Unable to update monitor run-start heartbeat"
    persistent_log "ERROR" "Unable to update monitor run-start heartbeat"
fi

###############################################################################
# v2.5 PERSISTENT LOG / ACTIVITY AUDIT INITIALIZATION
###############################################################################

rotate_persistent_log

persistent_log \
    "START" \
    "ARR Health Monitor v3.5.0"

if [ "$ACTIVITY_AUDIT_ENABLED" = true ]; then

    initialize_activity_audit_window

    log "Activity audit window: last ${ACTIVITY_AUDIT_LOOKBACK_HOURS}h"
fi

###############################################################################
# START
###############################################################################

log "Starting ARR Health Monitor v3.5.0"
log "Recommended schedule: every five minutes"
log "Notifications enabled: $SEND_NOTIFICATIONS"
log "Grouped notification maximum items: $GROUP_NOTIFICATION_MAX_ITEMS"

preflight_notification_command
record_monitor_schedule_issue
record_monitor_notification_issue

###############################################################################
# SABNZBD
###############################################################################

if [ "$SAB_ENABLED" = true ]; then

    log "Connecting to SABnzbd"

    SAB_HISTORY="$TMP_DIR/sab_history.json"
    SAB_QUEUE="$TMP_DIR/sab_queue.json"
    SAB_WARNINGS="$TMP_DIR/sab_warnings.json"
    SAB_STATUS="$TMP_DIR/sab_status.json"
    SAB_SERVER_STATS="$TMP_DIR/sab_server_stats.json"

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

    if sab_get server_stats "$SAB_SERVER_STATS"; then

        SAB_SERVER_STATS_OK=true

    else

        SAB_SERVER_STATS_OK=false
        SAB_SERVER_STATS=""
        log "WARNING: Unable to retrieve optional SABnzbd provider statistics: ${API_LAST_ERROR}"
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
    process_sab_server_stats
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

process_exact_download_ledger || true

###############################################################################
# SAB CROSS-APP CHECK
###############################################################################

prepare_sab_filesystem_scan || true

process_sab_orphans

prune_sab_progress_state

###############################################################################
# ACTIVITY FLOW ANOMALY - v2.6
###############################################################################

assess_activity_flow

# Core service endpoint failures are already represented by the per-service
# API lifecycle issues. This adds repeated incomplete-run, secondary history,
# and internal flow-analysis failures without duplicating those API alerts.
record_monitor_scan_issue

###############################################################################
# RESOLUTION CHECK
#
# Done only after all current issues have been marked seen.
###############################################################################

resolve_missing_issues

###############################################################################
# SEND ONE GROUPED NOTIFICATION
###############################################################################

NOTIFICATION_ATTEMPTED=false
NOTIFICATION_LAST_ERROR=""

send_grouped_notification
NOTIFICATION_SEND_RC=$?

if [ "$NOTIFICATION_ATTEMPTED" = true ]; then

    if (( NOTIFICATION_SEND_RC == 0 )); then
        set_monitor_notification_state false "" || true
    else
        [ -n "$NOTIFICATION_LAST_ERROR" ] || \
            NOTIFICATION_LAST_ERROR="Unraid notification command failed"

        set_monitor_notification_state true "$NOTIFICATION_LAST_ERROR" || true
        record_monitor_notification_issue
    fi
fi

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
log "ARR Health Monitor v3.5.0 completed"

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
log "SAB individually paused jobs: $SAB_JOB_PAUSED_COUNT"
log "SAB encrypted jobs: $SAB_JOB_ENCRYPTED_COUNT"
log "SAB duplicate jobs: $SAB_JOB_DUPLICATE_COUNT"
log "SAB degraded servers: $SAB_SERVER_DEGRADED_COUNT"
log "SAB low-success providers: $SAB_SERVER_LOW_SUCCESS_COUNT"
log "SAB proactive capacity issues: $SAB_CAPACITY_ISSUE_COUNT"
log "SAB unknown-category jobs: $SAB_UNKNOWN_CATEGORY_COUNT"
log "SAB history cache reused: $SAB_HISTORY_CACHE_HIT"

log ""
log "MONITOR SELF-HEALTH"
log "Missed-schedule issues: $MONITOR_SCHEDULE_MISSED_COUNT"
log "Repeated/incomplete scan issues: $MONITOR_SCAN_FAILURE_COUNT"
log "Notification-command issues: $MONITOR_NOTIFICATION_FAILURE_COUNT"
log "Previous start gap: ${PREVIOUS_RUN_GAP_MINUTES}m"
log "Previous run incomplete: $PREVIOUS_RUN_INCOMPLETE"

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
log "EXACT DOWNLOAD WORKFLOW"
log "Ledger evaluation healthy: $DOWNLOAD_LEDGER_SCAN_OK"
log "Workflow issues: $DOWNLOAD_LEDGER_ISSUE_COUNT"
log "  Grab did not reach SAB: $DOWNLOAD_LEDGER_NOT_REACHED_COUNT"
log "  SAB job vanished: $DOWNLOAD_LEDGER_VANISHED_COUNT"
log "  SAB completion missing Arr terminal event: $DOWNLOAD_LEDGER_IMPORT_MISSING_COUNT"
log "Historical pre-monitor issues retired: $DOWNLOAD_LEDGER_HISTORICAL_RETIRED_COUNT"
log "Automatic reconciliation checks: $DOWNLOAD_LEDGER_RECONCILIATION_CHECKED_COUNT"
log "Reconciliation awaiting confirmation: $DOWNLOAD_LEDGER_RECONCILIATION_PENDING_COUNT"
log "Automatically reconciled this run: $DOWNLOAD_LEDGER_RECONCILED_COUNT"
log "Reconciliation API checks failed: $DOWNLOAD_LEDGER_RECONCILIATION_FAILED_COUNT"

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
log "Filesystem scan healthy: $SAB_FILESYSTEM_SCAN_OK"
log "Filesystem scan deferred by mover: $SAB_FILESYSTEM_SCAN_DEFERRED"

log ""
log "LIFECYCLE"
log "Issues resolved this run: $RESOLVED_COUNT"
log "Reminders queued: $REMINDER_NOTIFICATION_COUNT"
log "Historical event repeats suppressed: $EVENT_REPEAT_SUPPRESSED_COUNT"
log "Historical event expiry notices suppressed: $EVENT_RESOLUTION_SUPPRESSED_COUNT"
log "Bounded reminder limits reached: $BOUNDED_REMINDER_SUPPRESSED_COUNT"
log "Flapping episodes queued: $FLAPPING_NOTIFICATION_COUNT"
log "Flapping notifications suppressed: $FLAPPING_SUPPRESSED_COUNT"
log "Acknowledged notifications suppressed: $ACKNOWLEDGED_SUPPRESSED_COUNT"

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
log "Lifecycle updates queued for grouping: $BATCHED_NOTIFICATION_ITEMS"

if [ "$SEND_NOTIFICATIONS" = true ]; then

    log "Grouped notifications sent: $NOTIFICATIONS_SENT"
    log "Notifications suppressed by lifecycle state: $NOTIFICATIONS_SUPPRESSED"

else

    log "Notifications: DISABLED"
    log "Notifications suppressed by lifecycle state: $NOTIFICATIONS_SUPPRESSED"
fi

log ""
log "Recommended run interval: every five minutes"
log "Runtime: $RUNTIME"
log "============================================================"

persistent_log \
    "END" \
    "runtime=${RUNTIME} | active_issues=${TOTAL_ISSUES} | info=${INFO_COUNT} | warnings=${WARNING_COUNT} | errors=${ERROR_COUNT} | reminders=${REMINDER_NOTIFICATION_COUNT} | event_repeats_suppressed=${EVENT_REPEAT_SUPPRESSED_COUNT} | event_expiry_suppressed=${EVENT_RESOLUTION_SUPPRESSED_COUNT} | bounded_limits_reached=${BOUNDED_REMINDER_SUPPRESSED_COUNT} | flapping=${FLAPPING_NOTIFICATION_COUNT} | acknowledged_suppressed=${ACKNOWLEDGED_SUPPRESSED_COUNT}"

if ! complete_monitor_run "$PIPELINE_STATUS"; then
    log "ERROR: Unable to update monitor completion heartbeat"
    persistent_log "ERROR" "Unable to update monitor completion heartbeat"
fi
    
exit 0
