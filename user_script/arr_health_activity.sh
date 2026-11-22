#!/bin/bash

###############################################################################
# ARR Health / Download / Import Monitor v3.11.0
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
#   script --dismiss-download ACK_ID "manual removal reason"
#   script --batch-dismiss-downloads [filters]
#
# Each notification includes the short ACK_ID needed by these commands.
# Dismissing a download-flow issue records an explicit operator disposition,
# resolves it immediately, and queues one informational item for the next
# normal grouped notification. It does not change Sonarr, Radarr, SABnzbd, or
# any media file.
#
# Batch dismissal is preview-only unless --execute is supplied. Execution also
# requires a reason, the exact preview count, an exact classification or an
# ACK-ID file, and at least one additional narrowing filter. A timestamped
# state backup and JSON manifest are created before one atomic state update.
# The next normal monitor run sends one batch summary rather than one notice
# per dismissed download. Every preview also writes a readable TSV report and
# an ACK-only text file that can be passed directly to --ack-file. Run --help
# for complete examples and safeguards.
#
#
# LOGGING BEHAVIOR
# ----------------
# At the default LOG_LEVEL=INFO, an unchanged scheduled run prints one compact
# status line and does not append routine data to the persistent log. A full
# report is emitted after a pipeline-status or lifecycle change (including a
# newly detected monitor degradation) and as a six-hour heartbeat. Warnings,
# errors, issue transitions, resolutions, and notification results remain
# visible.
#
# Temporarily set LOG_LEVEL=DEBUG to restore per-phase, per-item, retry, cache,
# threshold, and suppression detail while troubleshooting. Persistent logs are
# bounded by both size/generation rotation and a numbered-backup age limit.
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
# Native Arr health entries are also mirrored dynamically, so newly added
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
#   DOWNLOAD_FLOW_MANUALLY_DISMISSED
#
# Missing-import, vanished-SAB, and never-reached-SAB issues are reconciled
# automatically through Arr APIs. Exact download history is checked first. If
# no terminal history is available, the monitor verifies the exact Sonarr
# episode/Radarr movie and its Arr database file record twice before closing
# the issue. Physical media paths are never accessed, so this reconciliation
# does not wake array disks.
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
# Active queue/API health remains on every run; read-only residue inventories
# run hourly. A planned interval skip preserves prior filesystem issues.
SAB_FILESYSTEM_SCAN_INTERVAL_MINUTES=60
DOWNLOAD_LEDGER_FULL_REPLAY_HOURS=24

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

# SAB's warnings API is a bounded event log, not a live-condition endpoint.
# Ignore entries older than this window so old GUI warnings cannot keep the
# pipeline unhealthy indefinitely. Current disk, server, queue, and
# authentication conditions are monitored separately below.
SAB_WARNING_ACTIVE_HOURS=24

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
# Notification lifecycle - v3.7
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
STATE_BACKUP_GENERATIONS=3
SAB_HISTORY_CACHE="${STATE_DIR}/sab_history_cache.json"
ARR_HISTORY_CACHE_DIR="${STATE_DIR}/arr-history-cache"
SONARR_HISTORY_CACHE="${ARR_HISTORY_CACHE_DIR}/sonarr.json"
RADARR_HISTORY_CACHE="${ARR_HISTORY_CACHE_DIR}/radarr.json"
BATCH_DISMISS_MANIFEST_DIR="${STATE_DIR}/batch-dismissals"
BATCH_DISMISS_PREVIEW_DIR="${BATCH_DISMISS_MANIFEST_DIR}/previews"

# Resolved historical issues older than this are removed from state.
STATE_RETENTION_DAYS=30

# Keep batch-dismissal preview files, execution manifests, and pre-change state
# backups long enough for review or recovery without allowing one-time cleanup
# artifacts to grow forever.
BATCH_DISMISS_AUDIT_RETENTION_DAYS=30

# ---------------------------------------------------------------------------
# Persistent operational log - v2.5
# ---------------------------------------------------------------------------

LOG_FILE="${STATE_DIR}/arr_health_activity.log"

# Routine runs stay compact. DEBUG temporarily restores phase, checkpoint,
# pagination/cache, suppression, and other troubleshooting messages.
LOG_LEVEL="INFO"

# Emit a full health report on change and as a periodic healthy heartbeat.
HEALTH_HEARTBEAT_HOURS=6

# Rotate after approximately 5 MiB.
LOG_MAX_SIZE_MB=5
LOG_LINE_MAX_BYTES=4096

# Keep:
#   arr_health_activity.log
#   arr_health_activity.log.1
#   arr_health_activity.log.2
# Keep the active log plus two numbered backups (approximately 15 MiB total).
LOG_BACKUPS=2

# A quiet backup can otherwise remain indefinitely because rotation is
# size-based. Remove numbered backups older than this age as a second bound.
LOG_RETENTION_DAYS=30

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
# After 12 hours, vanished/never-arrived attempts with successful API checks
# become WARNING review items. This does not assert cancellation or import,
# dismiss the record, or downgrade a completed download awaiting import.
DOWNLOAD_LEDGER_HISTORICAL_REVIEW_MINUTES=720
DOWNLOAD_LEDGER_IMPORT_WARN_MINUTES=300
DOWNLOAD_LEDGER_ESCALATE_MINUTES=720
DOWNLOAD_LEDGER_DISCOVERY_HOURS=24
DOWNLOAD_LEDGER_RETENTION_DAYS=7

# Automatically reconcile exact download-flow gaps that have no terminal event
# in the normal activity-history window. This covers completed imports as well
# as jobs that vanished from SAB or never became visible in SAB after an Arr
# grab. All checks use Arr database APIs only. The script never calls Arr
# filesystem/rescan endpoints and never stats media paths on the Unraid host.
DOWNLOAD_LEDGER_RECONCILE_ENABLED=true
DOWNLOAD_LEDGER_RECONCILE_CONFIRM_RUNS=2
DOWNLOAD_LEDGER_RECONCILE_MAX_RECORDS=50

# Negative but successful API checks (no exact identity, object no longer in
# Arr, stale file record, etc.) are retried on this slower interval. Positive
# candidates still receive their required confirmation on the next run, while
# transport/authentication failures remain eligible for an immediate retry.
DOWNLOAD_LEDGER_RECONCILE_RETRY_MINUTES=60

# Allow a small timestamp skew between SAB queue time and Arr file dateAdded.
DOWNLOAD_LEDGER_RECONCILE_CLOCK_SKEW_SECONDS=300

# Durable Arr history cursors use a small overlap so delayed history events are
# not lost at a run boundary. The persistent cache retains the complete audit
# window while only the incremental range needs to be requested normally.
ARR_HISTORY_CURSOR_OVERLAP_MINUTES=10

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------

LOCKFILE="/tmp/arr_health_activity.lock"

# Keep a five-minute scheduled run below four minutes. Once the remaining
# reserve is reached, optional audit/reconciliation/filesystem phases are
# deferred without resolving any issue that depends on them.
MONITOR_RUNTIME_BUDGET_SECONDS=240
MONITOR_RUNTIME_RESERVE_SECONDS=20

# Stop repeatedly calling one service during the same run after consecutive
# transport/server failures. Authentication failures open the circuit
# immediately; ordinary endpoint 404 responses do not.
SERVICE_CIRCUIT_FAILURE_THRESHOLD=2

QUEUE_PAGE_SIZE=1000
SAB_HISTORY_LIMIT=500
ARR_QUEUE_MAX_RECORDS=10000
ARR_ACTIVITY_HISTORY_PAGE_SIZE=1000
ARR_ACTIVITY_HISTORY_MAX_RECORDS=10000

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
HTTP_LAST_STATUS=""
HTTP_LAST_URL=""
API_LAST_ERROR=""
API_LAST_HTTP_CODE=""
API_LAST_ENDPOINT=""

SONARR_API_ROOT=""
RADARR_API_ROOT=""
SONARR_API_VERSION=""
RADARR_API_VERSION=""

SONARR_CIRCUIT_FAILURES=0
RADARR_CIRCUIT_FAILURES=0
SAB_CIRCUIT_FAILURES=0
SONARR_CIRCUIT_OPEN=false
RADARR_CIRCUIT_OPEN=false
SAB_CIRCUIT_OPEN=false
SONARR_CIRCUIT_REASON=""
RADARR_CIRCUIT_REASON=""
SAB_CIRCUIT_REASON=""

STATE_STORAGE_FILE=""
STATE_WORK_FILE=""
STATE_TRANSACTION_ACTIVE=false
STATE_TRANSACTION_DIRTY=false
MONITOR_RUN_ACTIVE=false
MONITOR_RUN_FINALIZED=false
MONITOR_EXIT_SIGNAL=""
MONITOR_CURRENT_PHASE="startup"
MONITOR_PHASE_STARTED_AT=0
MONITOR_PHASE_TIMINGS_FILE=""
MONITOR_RUNTIME_DEFERRED=false
MONITOR_RUNTIME_DEFERRED_PHASES=""

SONARR_LEDGER_HISTORY=""
RADARR_LEDGER_HISTORY=""

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
PREVIOUS_RUN_STATUS="unknown"
PREVIOUS_RUN_EXIT_CODE=0
PREVIOUS_RUN_PHASE="startup"
PREVIOUS_RUN_ERROR=""

TOTAL_QUEUE=0
TOTAL_ISSUES=0

INFO_COUNT=0
WARNING_COUNT=0
ERROR_COUNT=0
EVENT_ONLY_ERROR_COUNT=0
PIPELINE_LIVE_ERROR_COUNT=0

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
DOWNLOAD_LEDGER_MANUAL_DISMISSAL_NOTIFICATION_COUNT=0
DOWNLOAD_LEDGER_BATCH_DISMISSAL_NOTIFICATION_COUNT=0
DOWNLOAD_LEDGER_RECONCILIATION_RESULTS_FILE=""
BATCH_PREVIEW_TSV=""
BATCH_PREVIEW_ACK_FILE=""
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
SONARR_AUDIT_DOWNLOAD_FAILED_RECOVERED=0

RADARR_AUDIT_IMPORTED=0
RADARR_AUDIT_DOWNLOAD_FAILED=0
RADARR_AUDIT_DOWNLOAD_FAILED_RECOVERED=0
ARR_HISTORY_FAILURE_RECOVERED_COUNT=0

SAB_AUDIT_MOVIE_COMPLETED=0
SAB_AUDIT_TV_COMPLETED=0

SAB_AUDIT_MOVIE_FAILED=0
SAB_AUDIT_TV_FAILED=0

SAB_AUDIT_F1_IGNORED=0

SAB_AUDIT_WINDOW_INCOMPLETE=false

PIPELINE_STATUS="UNKNOWN"
PIPELINE_REASON="Not assessed"
DETAILED_SUMMARY_DUE=false
DETAILED_SUMMARY_REASON="not evaluated"
ACTIVE_ISSUE_COUNT=0

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

log_level_rank() {

    case "${1^^}" in
        ERROR)
            printf '0\n'
            ;;

        WARNING)
            printf '1\n'
            ;;

        INFO)
            printf '2\n'
            ;;

        DEBUG)
            printf '3\n'
            ;;

        *)
            printf '2\n'
            ;;
    esac
}

log_level_enabled() {

    local requested="$1"
    local configured_rank
    local requested_rank

    configured_rank=$(log_level_rank "$LOG_LEVEL")
    requested_rank=$(log_level_rank "$requested")

    (( requested_rank <= configured_rank ))
}

log() {

    local message="$*"
    local level="INFO"

    case "$message" in
        ERROR:*)
            level="ERROR"
            ;;

        WARNING:*)
            level="WARNING"
            ;;

        DEBUG:*)
            level="DEBUG"
            message="${message#DEBUG: }"
            ;;
    esac

    log_level_enabled "$level" || return 0
    printf '%s : %s\n' "$(date '+%Y/%m/%d %T')" "$message"
}

debug_log() {
    log "DEBUG: $*"
}

###############################################################################
# PERSISTENT OPERATIONAL LOG - v2.5
###############################################################################

persistent_log() {
    local level="$1" message line size max_bytes
    local LC_ALL=C
    shift
    [[ "$level" != DEBUG ]] || log_level_enabled DEBUG || return 0
    [[ -n "$LOG_FILE" ]] || return 0
    message="$*"; message=${message//$'\n'/ | }; message=${message//$'\r'/}
    printf -v line '%s | %s | %s' "$(date '+%Y/%m/%d %T')" "$level" "$message"
    if (( ${#line}>LOG_LINE_MAX_BYTES )); then line="${line:0:LOG_LINE_MAX_BYTES-24} ... [line truncated]"; fi
    size=$(stat -c '%s' "$LOG_FILE" 2>/dev/null || printf 0)
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    max_bytes=$((LOG_MAX_SIZE_MB*1024*1024))
    if (( size>0 && size+${#line}+1>max_bytes )); then
        rotate_persistent_log true || { log "ERROR: Persistent log rotation failed; append refused"; return 1; }
    fi
    if ! printf '%s\n' "$line" >>"$LOG_FILE"; then
        log "WARNING: Unable to write persistent log: $LOG_FILE"; return 1
    fi
}

prune_persistent_logs_by_age() {

    local find_mtime

    [ -d "$STATE_DIR" ] || return 0
    [[ "$LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]] || return 0
    # find rounds file ages down to complete 24-hour periods. Subtract one so
    # a setting of 30 removes backups once they have reached 30 days old.
    find_mtime=$((LOG_RETENTION_DAYS - 1))

    local backup suffix bytes
    for backup in "$LOG_FILE".[0-9]*; do
        [[ -f "$backup" ]] || continue
        suffix=${backup##*.}; [[ "$suffix" =~ ^[0-9]+$ ]] || continue
        bytes=$(stat -c '%s' "$backup") || continue
        if ((suffix>LOG_BACKUPS || bytes>LOG_MAX_SIZE_MB*1024*1024 || (LOG_RETENTION_DAYS>0 && $(date +%s)-$(stat -c '%Y' "$backup")>=LOG_RETENTION_DAYS*86400))); then rm -f -- "$backup" || return 1; fi
    done
}

###############################################################################
# PERSISTENT LOG ROTATION
###############################################################################

rotate_persistent_log() {
    [[ -f "$LOG_FILE" && ! -L "$LOG_FILE" ]] || return 0
    local force="${1:-false}" size max_bytes i
    size=$(stat -c '%s' "$LOG_FILE") || return 1
    max_bytes=$((LOG_MAX_SIZE_MB*1024*1024))
    [[ "$force" == true ]] || ((size>=max_bytes)) || return 0
    # Legacy oversized generations cannot be retained beyond the new cap.
    if ((size>max_bytes)); then
        : >"$LOG_FILE" || return 1
        debug_log "Discarded inherited oversized active log ($size bytes)"
        return 0
    fi
    if ((LOG_BACKUPS>0)); then
        rm -f -- "$LOG_FILE.$LOG_BACKUPS" || return 1
        for ((i=LOG_BACKUPS-1;i>=1;i--)); do
            [[ ! -f "$LOG_FILE.$i" ]] || mv -f -- "$LOG_FILE.$i" "$LOG_FILE.$((i+1))" || return 1
        done
        mv -f -- "$LOG_FILE" "$LOG_FILE.1" || return 1
    fi
    : >"$LOG_FILE"
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

# Invoked indirectly by signal traps below.
# shellcheck disable=SC2329
handle_monitor_signal() {

    MONITOR_EXIT_SIGNAL="$1"

    case "$1" in
        INT)
            exit 130
            ;;

        TERM)
            exit 143
            ;;

        HUP)
            exit 129
            ;;
    esac
}

# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
handle_monitor_exit() {

    local exit_code=$?
    local final_status="failed"
    local final_error="Monitor exited before the completion checkpoint"

    trap - EXIT

    if [ "$MONITOR_RUN_ACTIVE" = true ] &&
       [ "$MONITOR_RUN_FINALIZED" != true ]; then

        if [ -n "$MONITOR_EXIT_SIGNAL" ]; then
            final_status="interrupted"
            final_error="Monitor received ${MONITOR_EXIT_SIGNAL} during ${MONITOR_CURRENT_PHASE}"
        elif (( exit_code != 0 )); then
            final_error="Monitor exited with code ${exit_code} during ${MONITOR_CURRENT_PHASE}"
        else
            exit_code=3
        fi

        complete_monitor_run \
            "$final_status" \
            "$exit_code" \
            "$final_error" 2>/dev/null || true
        commit_state_transaction "abnormal-exit" 2>/dev/null || true
    fi

    cleanup
    exit "$exit_code"
}

trap 'handle_monitor_signal INT' INT
trap 'handle_monitor_signal TERM' TERM
trap 'handle_monitor_signal HUP' HUP
trap 'handle_monitor_exit' EXIT

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
    local stderr_file

    HTTP_LAST_ERROR=""
    HTTP_LAST_STATUS=""
    HTTP_LAST_URL="$safe_url"

    header_file=$(mktemp "${TMP_DIR}/http-headers.XXXXXX") || {
        HTTP_LAST_ERROR="unable to create HTTP response-header file"
        return 1
    }

    stderr_file=$(mktemp "${TMP_DIR}/http-stderr.XXXXXX") || {
        rm -f -- "$header_file" 2>/dev/null || true
        HTTP_LAST_ERROR="unable to create HTTP error-capture file"
        return 1
    }

    while (( attempt <= max_attempts )); do

        : >"$header_file"
        : >"$stderr_file"
        invalid_json=false

        http_code=$(curl \
            "${request_args[@]}" \
            --dump-header "$header_file" \
            "$url" \
            -o "$output" \
            --write-out '%{http_code}' \
            2>"$stderr_file")
        curl_rc=$?
        HTTP_LAST_STATUS="$http_code"

        if (( curl_rc == 0 )); then

            if jq -e \
                'type == "object" or type == "array"' \
                "$output" >/dev/null 2>&1
            then
                rm -f -- "$header_file" "$stderr_file" 2>/dev/null || true
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

        debug_log "Temporary HTTP failure for ${safe_url}: ${HTTP_LAST_ERROR}; retrying in ${delay}s (${attempt}/${HTTP_RETRY_COUNT})"
        sleep "$delay"

        ((attempt++)) || true
    done

    rm -f -- "$header_file" "$stderr_file" 2>/dev/null || true

    return 1
}

api_service_for_url() {

    local url="$1"
    local sonarr_base="${SONARR_URL%/}"
    local radarr_base="${RADARR_URL%/}"
    local sab_base="${SAB_URL%/}"
    local service="Unknown"
    local match_length=0

    if [ -n "$sonarr_base" ] && [[ "$url" == "$sonarr_base"* ]]; then
        service="Sonarr"
        match_length=${#sonarr_base}
    fi

    if [ -n "$radarr_base" ] &&
       [[ "$url" == "$radarr_base"* ]] &&
       (( ${#radarr_base} > match_length )); then
        service="Radarr"
        match_length=${#radarr_base}
    fi

    if [ -n "$sab_base" ] &&
       [[ "$url" == "$sab_base"* ]] &&
       (( ${#sab_base} > match_length )); then
        service="SABnzbd"
    fi

    printf '%s\n' "$service"
}

service_circuit_is_open() {

    case "$1" in
        Sonarr)
            [ "$SONARR_CIRCUIT_OPEN" = true ]
            ;;

        Radarr)
            [ "$RADARR_CIRCUIT_OPEN" = true ]
            ;;

        SABnzbd)
            [ "$SAB_CIRCUIT_OPEN" = true ]
            ;;

        *)
            return 1
            ;;
    esac
}

service_circuit_reason() {

    case "$1" in
        Sonarr)
            printf '%s\n' "$SONARR_CIRCUIT_REASON"
            ;;

        Radarr)
            printf '%s\n' "$RADARR_CIRCUIT_REASON"
            ;;

        SABnzbd)
            printf '%s\n' "$SAB_CIRCUIT_REASON"
            ;;
    esac
}

service_circuit_note_success() {

    case "$1" in
        Sonarr)
            SONARR_CIRCUIT_FAILURES=0
            ;;

        Radarr)
            RADARR_CIRCUIT_FAILURES=0
            ;;

        SABnzbd)
            SAB_CIRCUIT_FAILURES=0
            ;;
    esac
}

service_circuit_note_failure() {

    local service="$1"
    local http_code="$2"
    local reason="$3"
    local immediate=false
    local count=0

    if [[ "$http_code" =~ ^(401|403)$ ]] ||
       grep -Eqi 'api key.*(incorrect|required)|authentication rejected|unauthorized|forbidden' <<<"$reason"
    then
        immediate=true
    elif [[ "$http_code" =~ ^5[0-9][0-9]$ ]] ||
         [[ "$http_code" =~ ^(000|408|425|429)$ ]] ||
         grep -Eqi 'timed out|connection refused|could not resolve|empty response|connection failed|unexpected json contract' <<<"$reason"
    then
        immediate=false
    else
        return 0
    fi

    case "$service" in
        Sonarr)
            ((SONARR_CIRCUIT_FAILURES++)) || true
            count="$SONARR_CIRCUIT_FAILURES"
            if [ "$immediate" = true ] ||
               (( count >= SERVICE_CIRCUIT_FAILURE_THRESHOLD )); then
                SONARR_CIRCUIT_OPEN=true
                SONARR_CIRCUIT_REASON="$reason"
            fi
            ;;

        Radarr)
            ((RADARR_CIRCUIT_FAILURES++)) || true
            count="$RADARR_CIRCUIT_FAILURES"
            if [ "$immediate" = true ] ||
               (( count >= SERVICE_CIRCUIT_FAILURE_THRESHOLD )); then
                RADARR_CIRCUIT_OPEN=true
                RADARR_CIRCUIT_REASON="$reason"
            fi
            ;;

        SABnzbd)
            ((SAB_CIRCUIT_FAILURES++)) || true
            count="$SAB_CIRCUIT_FAILURES"
            if [ "$immediate" = true ] ||
               (( count >= SERVICE_CIRCUIT_FAILURE_THRESHOLD )); then
                SAB_CIRCUIT_OPEN=true
                SAB_CIRCUIT_REASON="$reason"
            fi
            ;;
    esac

    if service_circuit_is_open "$service"; then
        log "WARNING: ${service} circuit breaker opened: ${reason}"
    fi
}

api_contract_failure() {

    local service="$1"
    local endpoint="$2"
    local expected="$3"

    API_LAST_HTTP_CODE="200"
    API_LAST_ENDPOINT="${endpoint%%\?*}"
    API_LAST_ERROR="unexpected JSON contract; expected ${expected}"
    service_circuit_note_failure "$service" "200" "$API_LAST_ERROR"
    return 1
}

validate_arr_payload() {

    local service="$1"
    local kind="$2"
    local file="$3"
    local endpoint="$4"
    local filter
    local expected

    case "$kind" in
        api-info)
            filter='type == "object" and ((.current // "") | type) == "string"'
            expected='an API information object with current version'
            ;;

        queue|history-page)
            filter='type == "object" and (.records | type) == "array" and ((.totalRecords // (.records | length)) | type) == "number"'
            expected='a paged object with records array and numeric totalRecords'
            ;;

        health|history-since)
            filter='type == "array"'
            expected='a JSON array'
            ;;

        system-status)
            filter='type == "object" and ((.version // "") | type) == "string" and ((.version // "") | length) > 0'
            expected='a system-status object with version'
            ;;

        episode|episode-file|movie|movie-file)
            filter='type == "object" and ((.id // 0) | type) == "number" and (.id // 0) > 0'
            expected='an Arr record object with numeric id'
            ;;

        *)
            return 0
            ;;
    esac

    jq -e "$filter" "$file" >/dev/null 2>&1 ||
        api_contract_failure "$service" "$endpoint" "$expected"
}

validate_sab_payload() {

    local kind="$1"
    local file="$2"
    local endpoint="$3"
    local filter
    local expected

    case "$kind" in
        history)
            filter='(.history == false) or ((.history | type) == "object" and (.history.slots | type) == "array")'
            expected='a history object with slots array or an unchanged-history marker'
            ;;

        queue)
            filter='(.queue | type) == "object" and (.queue.slots | type) == "array"'
            expected='a queue object with slots array'
            ;;

        warnings)
            filter='((.warnings // .) | type) == "array"'
            expected='a warnings array'
            ;;

        status)
            filter='type == "object" and has("status") and (.status | type) == "object"'
            expected='a status object'
            ;;

        server_stats)
            filter='type == "object" and has("servers") and (.servers | type) == "object"'
            expected='a provider-statistics object with servers'
            ;;

        *)
            return 0
            ;;
    esac

    jq -e "$filter" "$file" >/dev/null 2>&1 ||
        api_contract_failure "SABnzbd" "$endpoint" "$expected"
}

api_get() {

    local url="$1"
    local api_key="$2"
    local output="$3"

    local -a request_args
    local service

    API_LAST_ERROR=""
    API_LAST_HTTP_CODE=""
    API_LAST_ENDPOINT="${url%%\?*}"

    service=$(api_service_for_url "$url")

    if service_circuit_is_open "$service"; then
        API_LAST_ERROR="request skipped because ${service} circuit breaker is open: $(service_circuit_reason "$service")"
        API_LAST_HTTP_CODE=""
        return 1
    fi

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
        API_LAST_HTTP_CODE="$HTTP_LAST_STATUS"
        API_LAST_ENDPOINT="$HTTP_LAST_URL"
        service_circuit_note_failure \
            "$service" \
            "$API_LAST_HTTP_CODE" \
            "$API_LAST_ERROR"
        return 1
    fi

    API_LAST_HTTP_CODE="$HTTP_LAST_STATUS"
    API_LAST_ENDPOINT="$HTTP_LAST_URL"
    service_circuit_note_success "$service"

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
    API_LAST_HTTP_CODE=""
    API_LAST_ENDPOINT="${url%%\?*}"

    if service_circuit_is_open "SABnzbd"; then
        API_LAST_ERROR="request skipped because SABnzbd circuit breaker is open: $(service_circuit_reason SABnzbd)"
        API_LAST_HTTP_CODE=""
        return 1
    fi

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
        API_LAST_HTTP_CODE="$HTTP_LAST_STATUS"
        API_LAST_ENDPOINT="$HTTP_LAST_URL"
        service_circuit_note_failure \
            "SABnzbd" \
            "$API_LAST_HTTP_CODE" \
            "$API_LAST_ERROR"
        return 1
    fi

    API_LAST_HTTP_CODE="$HTTP_LAST_STATUS"
    API_LAST_ENDPOINT="$HTTP_LAST_URL"

    if jq -e '
        (.status | type) == "boolean"
        and .status == false
        and ((.error // "") != "")
        ' "$output" >/dev/null 2>&1
    then

        API_LAST_ERROR=$(jq -r '.error // "SABnzbd API rejected the request"' "$output")

        service_circuit_note_failure \
            "SABnzbd" \
            "$API_LAST_HTTP_CODE" \
            "$API_LAST_ERROR"

        return 1
    fi

    service_circuit_note_success "SABnzbd"

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

store_arr_api_capability() {

    local app="$1"
    local root="$2"
    local version="$3"
    local previous_version
    local tmp="${TMP_DIR}/state.api-capability.json"

    previous_version=$(jq -r \
        --arg app "$app" \
        '.apiCapabilities[$app].version // ""' \
        "$STATE_FILE")

    jq \
        --arg app "$app" \
        --arg root "$root" \
        --arg version "$version" \
        --argjson now "$START_TIME" \
        '
        .apiCapabilities = (.apiCapabilities // {})
        |
        .apiCapabilities[$app] = {
            root: $root,
            version: $version,
            detectedAt: $now
        }
        ' "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp" || return 1

    if [ -n "$previous_version" ] &&
       [ "$previous_version" != "$version" ]; then
        record_normalized_issue \
            "${app}:api-version-change" \
            "$app" \
            "${app} API version changed" \
            "ARR_API_VERSION_CHANGED" \
            "INFO" \
            "changed" \
            "${app} API changed from ${previous_version} to ${version}" \
            "" \
            "Previous API: ${previous_version}"$'\n'"Current API: ${version}"$'\n'"Selected root: ${root}" \
            1 \
            0 \
            0 \
            "api-capability" \
            "arr api version changed"
    fi
}

discover_arr_api() {

    local app="$1"
    local base_url="$2"
    local api_key="$3"
    local info_file="${TMP_DIR}/${app,,}-api-info.json"
    local probe_file="${TMP_DIR}/${app,,}-api-probe.json"
    local discovered=""
    local root=""
    local candidate
    local cached_version
    local seen_candidates=""
    local -a candidates=()

    cached_version=$(jq -r \
        --arg app "$app" \
        '.apiCapabilities[$app].version // ""' \
        "$STATE_FILE")

    if api_get "${base_url%/}/api" "$api_key" "$info_file" &&
       validate_arr_payload "$app" api-info "$info_file" "${base_url%/}/api"
    then
        discovered=$(jq -r '.current // ""' "$info_file")
        discovered="${discovered#/api/}"
        discovered="${discovered#api/}"
        discovered="${discovered#/}"

        if [[ "$discovered" =~ ^v[0-9]+$ ]]; then
            root="${base_url%/}/api/${discovered}"
        fi
    fi

    if [ -z "$root" ]; then
        if [[ "$cached_version" =~ ^v[0-9]+$ ]]; then
            candidates+=("$cached_version")
        fi

        case "$app" in
            Sonarr)
                candidates+=(v5 v3)
                ;;

            Radarr)
                candidates+=(v3)
                ;;
        esac

        for candidate in "${candidates[@]}"; do
            if [[ " $seen_candidates " == *" $candidate "* ]]; then
                continue
            fi
            seen_candidates+=" ${candidate}"

            if api_get \
                "${base_url%/}/api/${candidate}/system/status" \
                "$api_key" \
                "$probe_file" &&
               validate_arr_payload \
                "$app" \
                system-status \
                "$probe_file" \
                "${base_url%/}/api/${candidate}/system/status"
            then
                discovered="$candidate"
                root="${base_url%/}/api/${candidate}"
                break
            fi
        done
    fi

    if [ -z "$root" ]; then
        case "$app" in
            Sonarr)
                SONARR_API_VERSION="v3"
                SONARR_API_ROOT="${base_url%/}/api/v3"
                ;;

            Radarr)
                RADARR_API_VERSION="v3"
                RADARR_API_ROOT="${base_url%/}/api/v3"
                ;;
        esac
        return 1
    fi

    case "$app" in
        Sonarr)
            SONARR_API_VERSION="$discovered"
            SONARR_API_ROOT="$root"
            ;;

        Radarr)
            RADARR_API_VERSION="$discovered"
            RADARR_API_ROOT="$root"
            ;;
    esac

    store_arr_api_capability "$app" "$root" "$discovered" || return 1
    debug_log "${app} API capability detected: ${discovered}"
    return 0
}

###############################################################################
# PAGED API FETCHERS
###############################################################################

fetch_arr_queue() {

    local app="$1"
    local api_root="$2"
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
            "${api_root%/}/queue?page=${page}&pageSize=${QUEUE_PAGE_SIZE}&${include_query}" \
            "$api_key" \
            "$page_file"
        then
            return 1
        fi

        validate_arr_payload \
            "$app" \
            queue \
            "$page_file" \
            "${api_root%/}/queue" || return 1

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

update_sab_history_cursor() {

    local history_file="$1"
    local cursor
    local tmp="${TMP_DIR}/state.sab-history-cursor.json"

    cursor=$(jq -r '.history.last_history_update // 0' "$history_file")
    [[ "$cursor" =~ ^[0-9]+$ ]] || cursor=0
    (( cursor > 0 )) || return 0

    jq \
        --argjson cursor "$cursor" \
        --argjson now "$START_TIME" \
        '
        .historyCursors = (.historyCursors // {})
        |
        .historyCursors.SABnzbd = {
            lastHistoryUpdate: $cursor,
            updatedAt: $now
        }
        ' "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp"
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
    local state_history_update=0
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

    state_history_update=$(jq -r \
        '.historyCursors.SABnzbd.lastHistoryUpdate // 0' \
        "$STATE_FILE")
    [[ "$state_history_update" =~ ^[0-9]+$ ]] || state_history_update=0
    if (( state_history_update > last_history_update )); then
        # The conditional SAB cursor is useful only with the exact cached
        # payload it describes. A cursor/cache mismatch must force a full
        # response rather than accepting history=false against stale data.
        log "WARNING: SAB history cursor is newer than its cache; forcing full history refresh"
        last_history_update=0
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

        validate_sab_payload \
            history \
            "$page_file" \
            "${SAB_URL%/}/api" || return 1

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

                debug_log "SABnzbd history unchanged; reused persistent history cache"
                update_sab_history_cursor "$output" || return 1
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

            validate_sab_payload \
                history \
                "$page_file" \
                "${SAB_URL%/}/api" || return 1
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

    update_sab_history_cursor "$output" || return 1

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

        validate_sab_payload \
            queue \
            "$page_file" \
            "${SAB_URL%/}/api" || return 1

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

validate_state_schema() {

    local candidate="$1"

    jq -e '
        (.version | type) == "number"
        and (.version >= 17)
        and (.issues | type) == "object"
        and (.sabProgress | type) == "object"
        and (.downloadLedger | type) == "object"
        and (.downloadDismissalBatches | type) == "object"
        and (.sabServerStats | type) == "object"
        and (.apiCapabilities | type) == "object"
        and (.historyCursors | type) == "object"
        and (.monitor | type) == "object"
        and ((.monitor.lastDetailedSummaryAt // 0) | type) == "number"
        and (.monitor.notification | type) == "object"
        and (.telemetry | type) == "object"
        and (.telemetry.patterns | type) == "object"
        ' "$candidate" >/dev/null 2>&1
}

state_backup_path() {

    local generation="$1"

    if (( generation <= 1 )); then
        printf '%s\n' "$STATE_BACKUP"
    else
        printf '%s.%s\n' "$STATE_BACKUP" "$generation"
    fi
}

rotate_state_backups() {

    local target="$1"
    local generation
    local previous
    local destination
    local backup_tmp

    (( STATE_BACKUP_GENERATIONS > 0 )) || return 0

    for ((generation=STATE_BACKUP_GENERATIONS; generation>=2; generation--)); do
        previous=$(state_backup_path $((generation - 1)))
        destination=$(state_backup_path "$generation")

        if [ -f "$previous" ] && validate_state_schema "$previous"; then
            backup_tmp=$(mktemp "${STATE_DIR}/.state-backup.XXXXXX") || return 1
            cp -f -- "$previous" "$backup_tmp" || {
                rm -f -- "$backup_tmp"
                return 1
            }
            mv -f -- "$backup_tmp" "$destination" || return 1
        fi
    done

    if [ -f "$target" ] && validate_state_schema "$target"; then
        backup_tmp=$(mktemp "${STATE_DIR}/.state-backup.XXXXXX") || return 1
        cp -f -- "$target" "$backup_tmp" || {
            rm -f -- "$backup_tmp"
            return 1
        }
        mv -f -- "$backup_tmp" "$STATE_BACKUP" || return 1
    fi
}

atomic_replace_state() {

    local source="$1"
    local target="$2"
    local state_tmp

    validate_state_schema "$source" || {
        log "ERROR: Refusing state commit with an invalid schema: $source"
        return 1
    }

    state_tmp=$(mktemp "${STATE_DIR}/.state-commit.XXXXXX") || return 1

    if ! cp -f -- "$source" "$state_tmp"; then
        rm -f -- "$state_tmp"
        return 1
    fi

    validate_state_schema "$state_tmp" || {
        rm -f -- "$state_tmp"
        return 1
    }

    if ! rotate_state_backups "$target"; then
        rm -f -- "$state_tmp"
        log "ERROR: Unable to rotate validated state backups"
        return 1
    fi

    if command -v sync >/dev/null 2>&1; then
        sync -f "$state_tmp" 2>/dev/null || true
    fi

    mv -f -- "$state_tmp" "$target"
}

create_initial_state() {

    local initial_tmp

    initial_tmp=$(mktemp "${STATE_DIR}/.state-initial.XXXXXX") || return 1

    if ! cat >"$initial_tmp" <<'EOF'
{
  "version": 17,
  "issues": {},
  "sabProgress": {},
  "downloadLedger": {},
  "downloadDismissalBatches": {},
  "sabServerStats": {},
  "apiCapabilities": {},
  "historyCursors": {},
  "monitor": {
    "lastStartedAt": 0,
    "lastCompletedAt": 0,
    "lastStatus": "unknown",
    "lastExitCode": 0,
    "lastPhase": "startup",
    "lastError": "",
    "lastDetailedSummaryAt": 0,
    "phaseTimings": {},
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
    then
        rm -f -- "$initial_tmp"
        return 1
    fi

    if ! validate_state_schema "$initial_tmp"; then
        rm -f -- "$initial_tmp"
        return 1
    fi

    mv -f -- "$initial_tmp" "$STATE_FILE"
}

restore_valid_state_backup() {

    local generation
    local candidate
    local restore_tmp

    for ((generation=1; generation<=STATE_BACKUP_GENERATIONS; generation++)); do
        candidate=$(state_backup_path "$generation")

        if [ -f "$candidate" ] &&
           { validate_state_schema "$candidate" ||
             jq -e \
                'type == "object" and ((.version // 0) < 17)' \
                "$candidate" >/dev/null 2>&1; }
        then
            restore_tmp=$(mktemp "${STATE_DIR}/.state-restore.XXXXXX") || return 1
            cp -f -- "$candidate" "$restore_tmp" || {
                rm -f -- "$restore_tmp"
                return 1
            }
            mv -f -- "$restore_tmp" "$STATE_FILE" || return 1
            log "Restored state from readable backup generation ${generation}; schema migration will validate it"
            return 0
        fi
    done

    return 1
}

begin_state_transaction() {

    STATE_STORAGE_FILE="$STATE_FILE"
    STATE_WORK_FILE="${TMP_DIR}/state.working.json"

    cp -f -- "$STATE_STORAGE_FILE" "$STATE_WORK_FILE" || return 1
    validate_state_schema "$STATE_WORK_FILE" || return 1

    STATE_FILE="$STATE_WORK_FILE"
    STATE_TRANSACTION_ACTIVE=true
    STATE_TRANSACTION_DIRTY=false
}

commit_state_transaction() {

    local checkpoint="${1:-checkpoint}"

    [ "$STATE_TRANSACTION_ACTIVE" = true ] || return 0
    [ "$STATE_TRANSACTION_DIRTY" = true ] || return 0

    if ! atomic_replace_state "$STATE_WORK_FILE" "$STATE_STORAGE_FILE"; then
        log "ERROR: State transaction commit failed at checkpoint: $checkpoint"
        return 1
    fi

    STATE_TRANSACTION_DIRTY=false
    debug_log "State checkpoint committed: $checkpoint"
}

initialize_state() {

    mkdir -p "$STATE_DIR" || {
        log "ERROR: Unable to create state directory: $STATE_DIR"
        exit 3
    }

    if [ ! -f "$STATE_FILE" ]; then
        create_initial_state || {
            log "ERROR: Unable to create initial monitor state"
            exit 3
        }
    fi

    if ! jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then

        log "WARNING: State file is invalid"

        if ! restore_valid_state_backup; then
            log "No usable state backup was found; creating new state"
            create_initial_state || exit 3
        fi
    fi

    # Schema migrations are one-time. Normal runs use the transaction working
    # copy and should not rewrite the vault merely to reapply defaults.
    if validate_state_schema "$STATE_FILE"; then
        return 0
    fi

    ###########################################################################
    # STATE MIGRATION - v3.9
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
        .version = 17
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
        .downloadDismissalBatches = (.downloadDismissalBatches // {})
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
                |
                .manuallyDismissedAt = (.manuallyDismissedAt // 0)
                |
                .manualDismissalReason = (
                    .manualDismissalReason // ""
                )
                |
                .manualDismissalAckId = (
                    .manualDismissalAckId // ""
                )
                |
                .manualDismissalPreviousClassification = (
                    .manualDismissalPreviousClassification // ""
                )
                |
                .manualDismissalNotifiedAt = (
                    .manualDismissalNotifiedAt // 0
                )
                |
                .manualDismissalBatchId = (
                    .manualDismissalBatchId // ""
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
        .apiCapabilities = (.apiCapabilities // {})
        |
        .historyCursors = (.historyCursors // {})
        |
        .monitor = (
            {
                lastStartedAt: 0,
                lastCompletedAt: 0,
                lastStatus: "unknown",
                lastExitCode: 0,
                lastPhase: "startup",
                lastError: "",
                lastDetailedSummaryAt: 0,
                phaseTimings: {},
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
        .monitor.lastExitCode = (.monitor.lastExitCode // 0)
        |
        .monitor.lastPhase = (.monitor.lastPhase // "startup")
        |
        .monitor.lastError = (.monitor.lastError // "")
        |
        .monitor.lastDetailedSummaryAt = (
            .monitor.lastDetailedSummaryAt // 0
        )
        |
        .monitor.phaseTimings = (.monitor.phaseTimings // {})
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

        log "ERROR: Unable to migrate state file to schema version 17"
        exit 3
    fi
}

save_state() {

    local new_state="$1"
    local display_state="${STATE_STORAGE_FILE:-$STATE_FILE}"

    if ! validate_state_schema "$new_state"; then

        log "ERROR: Refusing to replace state with invalid JSON or schema: $new_state"

        return 1
    fi

    if [ "$STATE_TRANSACTION_ACTIVE" = true ]; then
        if mv -f -- "$new_state" "$STATE_WORK_FILE"; then
            STATE_FILE="$STATE_WORK_FILE"
            STATE_TRANSACTION_DIRTY=true
            return 0
        fi
    elif atomic_replace_state "$new_state" "$STATE_FILE"; then
        return 0
    fi

    log "ERROR: Unable to replace state file: $display_state"
    persistent_log "ERROR" "Unable to replace monitor state file"

    if [ "$STATE_WRITE_ALERT_SENT" != true ]; then

        STATE_WRITE_ALERT_SENT=true

        notify \
            "alert" \
            "ARR Health Monitor - State Write Failed" \
            "The monitor could not update ${display_state}. Issue lifecycle and notification deduplication may be stale."
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
    PREVIOUS_RUN_STATUS=$(jq -r '.monitor.lastStatus // "unknown"' "$STATE_FILE")
    PREVIOUS_RUN_EXIT_CODE=$(jq -r '.monitor.lastExitCode // 0' "$STATE_FILE")
    PREVIOUS_RUN_PHASE=$(jq -r '.monitor.lastPhase // "startup"' "$STATE_FILE")
    PREVIOUS_RUN_ERROR=$(jq -r '.monitor.lastError // ""' "$STATE_FILE")

    [[ "$PREVIOUS_RUN_STARTED_AT" =~ ^[0-9]+$ ]] || PREVIOUS_RUN_STARTED_AT=0
    [[ "$PREVIOUS_RUN_COMPLETED_AT" =~ ^[0-9]+$ ]] || PREVIOUS_RUN_COMPLETED_AT=0
    [[ "$PREVIOUS_RUN_EXIT_CODE" =~ ^[0-9]+$ ]] || PREVIOUS_RUN_EXIT_CODE=0

    if (( PREVIOUS_RUN_STARTED_AT > 0 && now > PREVIOUS_RUN_STARTED_AT )); then
        PREVIOUS_RUN_GAP_MINUTES=$(( (now - PREVIOUS_RUN_STARTED_AT) / 60 ))
    fi

    if (( PREVIOUS_RUN_STARTED_AT > PREVIOUS_RUN_COMPLETED_AT )); then
        PREVIOUS_RUN_INCOMPLETE=true
    fi

    jq \
        --argjson now "$now" \
        '
        .version = 17
        |
        .monitor.lastStartedAt = $now
        |
        .monitor.lastStatus = "running"
        |
        .monitor.lastExitCode = 0
        |
        .monitor.lastPhase = "startup"
        |
        .monitor.lastError = ""
        |
        .monitor.phaseTimings = {}
        ' \
        "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp"
}

complete_monitor_run() {

    local status="$1"
    local exit_code="${2:-0}"
    local error="${3:-}"
    local now
    local tmp="${TMP_DIR}/state.monitor-complete.json"

    now=$(date +%s)

    jq \
        --arg status "$status" \
        --arg phase "$MONITOR_CURRENT_PHASE" \
        --arg error "$error" \
        --argjson exitCode "$exit_code" \
        --argjson now "$now" \
        --slurpfile timings "$MONITOR_PHASE_TIMINGS_FILE" \
        '
        .monitor.lastCompletedAt = $now
        |
        .monitor.lastStatus = $status
        |
        .monitor.lastExitCode = $exitCode
        |
        .monitor.lastPhase = $phase
        |
        .monitor.lastError = $error
        |
        .monitor.phaseTimings = (
            reduce $timings[] as $timing (
                {};
                .[$timing.phase] = $timing.seconds
            )
        )
        ' \
        "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp"
}

start_monitor_phase() {

    MONITOR_CURRENT_PHASE="$1"
    MONITOR_PHASE_STARTED_AT=$(date +%s)
    debug_log "Phase started: ${MONITOR_CURRENT_PHASE}"
}

end_monitor_phase() {

    local phase="${1:-$MONITOR_CURRENT_PHASE}"
    local finished
    local seconds

    finished=$(date +%s)
    seconds=$((finished - MONITOR_PHASE_STARTED_AT))
    (( seconds >= 0 )) || seconds=0

    if [ -n "$MONITOR_PHASE_TIMINGS_FILE" ]; then
        jq -nc \
            --arg phase "$phase" \
            --argjson seconds "$seconds" \
            '{phase: $phase, seconds: $seconds}' \
            >>"$MONITOR_PHASE_TIMINGS_FILE" || true
    fi

    debug_log "Phase completed: ${phase} (${seconds}s)"
}

runtime_budget_allows_optional_phase() {

    local phase="$1"
    local elapsed=$(( $(date +%s) - START_TIME ))
    local latest_start=$((
        MONITOR_RUNTIME_BUDGET_SECONDS - MONITOR_RUNTIME_RESERVE_SECONDS
    ))

    if (( elapsed < latest_start )); then
        return 0
    fi

    MONITOR_RUNTIME_DEFERRED=true
    if [ -n "$MONITOR_RUNTIME_DEFERRED_PHASES" ]; then
        MONITOR_RUNTIME_DEFERRED_PHASES+=", "
    fi
    MONITOR_RUNTIME_DEFERRED_PHASES+="$phase"
    log "WARNING: Runtime budget deferred optional phase: ${phase} (${elapsed}s elapsed)"
    return 1
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
        .version = 17
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
        .version = 17
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
        ARR_API_VERSION_CHANGED|\
        SAB_DOWNLOAD_FAILED_*|\
        SAB_ERROR|\
        SAB_WARNING|\
        MONITOR_SCHEDULE_MISSED|\
        DOWNLOAD_FLOW_REVIEW_REQUIRED|\
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

classification_is_event_only_error() {

    case "$1" in
        ARR_DOWNLOAD_FAILED_HISTORY|SAB_DOWNLOAD_FAILED_*|SAB_ERROR|SAB_WARNING)
            return 0
            ;;

        *)
            return 1
            ;;
    esac
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
        if $event == "batch-dismissed" and ($key | startswith("FLOW:BATCH-DISMISS:"))
        then
            ($key | ltrimstr("FLOW:BATCH-DISMISS:")) as $batchId
            |
            if .downloadDismissalBatches[$batchId]
            then
                .downloadDismissalBatches[$batchId].notifiedAt = (
                    [
                        $now,
                        (.downloadDismissalBatches[$batchId].dismissedAt // 0)
                    ]
                    | max
                )
            else .
            end
        elif $event == "dismissed" and ($key | startswith("FLOW:DOWNLOAD:"))
        then
            ($key | ltrimstr("FLOW:DOWNLOAD:") | ascii_downcase) as $downloadId
            |
            if .downloadLedger[$downloadId]
            then
                .downloadLedger[$downloadId].manualDismissalNotifiedAt = (
                    [
                        $now,
                        (.downloadLedger[$downloadId].manuallyDismissedAt // 0)
                    ]
                    | max
                )
            else .
            end
        elif $event == "reconciled" and ($key | startswith("FLOW:RECONCILIATION:"))
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
# OPERATOR ACKNOWLEDGEMENT AND DOWNLOAD DISMISSAL - v3.7
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

dismiss_download_flow_issue() {

    local selector="$1"
    local reason="${2:-Manually removed from Arr and download client}"
    local issue_key
    local download_id
    local classification
    local ack_id
    local now
    local tmp="${TMP_DIR}/state.download-dismissed.json"

    resolve_active_issue_selector "$selector" || return 1
    issue_key="$RESOLVED_ISSUE_KEY"

    case "$issue_key" in
        FLOW:DOWNLOAD:*)
            download_id="${issue_key#FLOW:DOWNLOAD:}"
            download_id="${download_id,,}"
            ;;

        *)
            log "ERROR: Manual download dismissal applies only to FLOW:DOWNLOAD issues: $issue_key"
            return 1
            ;;
    esac

    classification=$(jq -r \
        --arg key "$issue_key" \
        '.issues[$key].classification // ""' \
        "$STATE_FILE")

    case "$classification" in
        DOWNLOAD_FLOW_NOT_REACHED_SAB|\
        DOWNLOAD_FLOW_SAB_VANISHED|\
        DOWNLOAD_FLOW_IMPORT_MISSING|DOWNLOAD_FLOW_REVIEW_REQUIRED)
            ;;

        *)
            log "ERROR: Issue is not an exact unresolved download-flow condition: $classification"
            return 1
            ;;
    esac

    if ! jq -e \
        --arg id "$download_id" \
        '.downloadLedger[$id] != null' \
        "$STATE_FILE" >/dev/null 2>&1
    then
        log "ERROR: Download ledger record is unavailable for $download_id"
        return 1
    fi

    reason="${reason//$'\r'/ }"
    reason="${reason//$'\n'/ }"
    [ -n "$reason" ] || reason="Manually removed from Arr and download client"

    ack_id=$(issue_ack_id "$issue_key")
    now=$(date +%s)

    jq \
        --arg key "$issue_key" \
        --arg id "$download_id" \
        --arg ackId "$ack_id" \
        --arg reason "$reason" \
        --arg classification "$classification" \
        --argjson now "$now" \
        '
        .downloadLedger[$id] |= (
            .manuallyDismissedAt = $now
            |
            .manualDismissalReason = $reason
            |
            .manualDismissalAckId = $ackId
            |
            .manualDismissalPreviousClassification = $classification
            |
            .manualDismissalNotifiedAt = 0
            |
            .reconciliationCandidateFingerprint = ""
            |
            .reconciliationCandidateRuns = 0
            |
            .reconciliationCandidateFirstSeenAt = 0
            |
            .reconciliationCandidateLastSeenAt = 0
            |
            .lastSeen = ([ (.lastSeen // 0), $now ] | max)
        )
        |
        .issues[$key] |= (
            .active = false
            |
            .resolvedAt = $now
            |
            .lastSeen = $now
            |
            .manuallyDismissedAt = $now
            |
            .manualDismissalReason = $reason
            |
            .transitionTimestamps = (
                ((.transitionTimestamps // []) + [$now])
                | map(select(type == "number"))
                | unique
                | sort
            )
            |
            .acknowledgedSignature = ""
            |
            .acknowledgedAt = 0
            |
            .acknowledgementNote = ""
        )
        ' "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp" || return 1

    persistent_log \
        "MANUALLY_DISMISSED" \
        "issue=${issue_key} | ack_id=${ack_id} | download_id=${download_id} | previous_classification=${classification} | reason=${reason}"

    printf 'Dismissed download-flow issue %s (%s); no Arr, SABnzbd, or media changes were made.\n' \
        "$ack_id" \
        "$issue_key"
}

write_batch_dismiss_preview() {

    local matches_file="$1"
    local count="$2"
    local source="$3"
    local classification="$4"
    local title_contains="$5"
    local older_than_hours="$6"
    local before_value="$7"
    local input_ack_file="$8"
    local timestamp
    local preview_hash
    local preview_id
    local tsv_tmp
    local ack_tmp

    BATCH_PREVIEW_TSV=""
    BATCH_PREVIEW_ACK_FILE=""

    mkdir -p -- "$BATCH_DISMISS_PREVIEW_DIR" || {
        log "ERROR: Unable to create batch-dismissal preview directory"
        return 1
    }

    timestamp=$(date '+%Y%m%d-%H%M%S')
    preview_hash=$(printf '%s' \
        "${START_TIME}|${source}|${classification}|${title_contains}|${older_than_hours}|${before_value}|${input_ack_file}|${count}|$$" |
        sha256sum |
        awk '{print substr($1, 1, 10)}')
    preview_id="${timestamp}-${preview_hash}"

    BATCH_PREVIEW_TSV="${BATCH_DISMISS_PREVIEW_DIR}/batch-preview-${preview_id}.tsv"
    BATCH_PREVIEW_ACK_FILE="${BATCH_DISMISS_PREVIEW_DIR}/batch-preview-${preview_id}-ack-ids.txt"

    tsv_tmp=$(mktemp "${BATCH_DISMISS_PREVIEW_DIR}/.batch-preview.XXXXXX") || return 1
    ack_tmp=$(mktemp "${BATCH_DISMISS_PREVIEW_DIR}/.batch-preview-ack.XXXXXX") || {
        rm -f -- "$tsv_tmp"
        return 1
    }

    if ! {
        printf 'ACK_ID\tSOURCE\tSEVERITY\tAGE_HOURS\tLEDGER\tCLASSIFICATION\tTITLE\tDOWNLOAD_ID\tARR_QUEUE_STATUS\tSAB_STATUS\tFIRST_SEEN_EPOCH\n'
        jq -r '
            [
                .ackId,
                .source,
                .severity,
                (.ageHours | tostring),
                (if .ledgerPresent then "yes" else "NO" end),
                .classification,
                .title,
                .downloadId,
                .arrQueueStatus,
                .sabStatus,
                (.firstSeen | tostring)
            ]
            | @tsv
            ' "$matches_file"
    } >"$tsv_tmp"
    then
        rm -f -- "$tsv_tmp" "$ack_tmp"
        log "ERROR: Unable to write batch-dismissal TSV preview"
        return 1
    fi

    if ! jq -r '.ackId' "$matches_file" >"$ack_tmp"; then
        rm -f -- "$tsv_tmp" "$ack_tmp"
        log "ERROR: Unable to write batch-dismissal ACK-ID preview"
        return 1
    fi

    mv -f -- "$tsv_tmp" "$BATCH_PREVIEW_TSV" || {
        rm -f -- "$tsv_tmp" "$ack_tmp"
        return 1
    }

    mv -f -- "$ack_tmp" "$BATCH_PREVIEW_ACK_FILE" || {
        rm -f -- "$ack_tmp"
        return 1
    }
}

batch_dismiss_downloads() {

    local source=""
    local classification=""
    local title_contains=""
    local older_than_hours=""
    local before_value=""
    local before_epoch=0
    local ack_file=""
    local normalized_ack_file=""
    local unmatched_ack_file=""
    local requested_ack_count=0
    local execute=false
    local confirm_count=""
    local reason=""
    local matches_file="${TMP_DIR}/batch-dismiss-matches.jsonl"
    local candidates_file="${TMP_DIR}/batch-dismiss-candidates.jsonl"
    local count=0
    local missing_ledger_count=0
    local record
    local issue_key
    local ack_id
    local batch_id
    local batch_hash
    local now
    local timestamp
    local state_backup
    local manifest_file
    local manifest_tmp
    local state_tmp="${TMP_DIR}/state.batch-dismissed.json"

    while (( $# > 0 )); do
        case "$1" in
            --source)
                [ -n "${2:-}" ] || {
                    log "ERROR: --source requires Sonarr or Radarr"
                    return 2
                }
                source="$2"
                shift 2
                ;;

            --classification)
                [ -n "${2:-}" ] || {
                    log "ERROR: --classification requires a value"
                    return 2
                }
                classification="$2"
                shift 2
                ;;

            --title-contains)
                [ -n "${2:-}" ] || {
                    log "ERROR: --title-contains requires literal text"
                    return 2
                }
                title_contains="$2"
                shift 2
                ;;

            --older-than-hours)
                [ -n "${2:-}" ] || {
                    log "ERROR: --older-than-hours requires an integer"
                    return 2
                }
                older_than_hours="$2"
                shift 2
                ;;

            --before)
                [ -n "${2:-}" ] || {
                    log "ERROR: --before requires a date or date/time"
                    return 2
                }
                before_value="$2"
                shift 2
                ;;

            --ack-file)
                [ -n "${2:-}" ] || {
                    log "ERROR: --ack-file requires a path"
                    return 2
                }
                ack_file="$2"
                shift 2
                ;;

            --execute)
                execute=true
                shift
                ;;

            --confirm-count)
                [ -n "${2:-}" ] || {
                    log "ERROR: --confirm-count requires an integer"
                    return 2
                }
                confirm_count="$2"
                shift 2
                ;;

            --reason)
                [ -n "${2:-}" ] || {
                    log "ERROR: --reason requires an explanation"
                    return 2
                }
                reason="$2"
                shift 2
                ;;

            --help|-h)
                print_lifecycle_command_help
                return 0
                ;;

            *)
                log "ERROR: Unknown batch-dismiss option: $1"
                print_lifecycle_command_help
                return 2
                ;;
        esac
    done

    case "$source" in
        ""|Sonarr|Radarr)
            ;;
        *)
            log "ERROR: --source must be Sonarr or Radarr"
            return 2
            ;;
    esac

    case "$classification" in
        ""|DOWNLOAD_FLOW_NOT_REACHED_SAB|DOWNLOAD_FLOW_SAB_VANISHED|DOWNLOAD_FLOW_IMPORT_MISSING|DOWNLOAD_FLOW_REVIEW_REQUIRED)
            ;;
        *)
            log "ERROR: Unsupported batch-dismiss classification: $classification"
            log "Only exact unresolved download-flow classifications may be dismissed."
            return 2
            ;;
    esac

    if [ -n "$older_than_hours" ]; then
        if ! [[ "$older_than_hours" =~ ^[0-9]+$ ]] ||
           (( older_than_hours <= 0 )); then
            log "ERROR: --older-than-hours must be a positive integer"
            return 2
        fi
    fi

    if [ -n "$before_value" ]; then
        before_epoch=$(date -d "$before_value" '+%s' 2>/dev/null) || {
            log "ERROR: Unable to parse --before value: $before_value"
            return 2
        }
    fi

    if [ -n "$ack_file" ]; then
        [ -s "$ack_file" ] || {
            log "ERROR: ACK-ID file is missing or empty: $ack_file"
            return 2
        }

        normalized_ack_file="${TMP_DIR}/batch-dismiss-ack-ids.txt"
        unmatched_ack_file="${TMP_DIR}/batch-dismiss-unmatched-ack-ids.txt"
        awk 'NF {print tolower($1)}' "$ack_file" |
            sort -u >"$normalized_ack_file"

        if [ ! -s "$normalized_ack_file" ] ||
           grep -Evq '^[0-9a-f]{12}$' "$normalized_ack_file"; then
            log "ERROR: Every --ack-file entry must be one complete 12-character ACK ID"
            return 2
        fi

        requested_ack_count=$(wc -l <"$normalized_ack_file" | tr -d ' ')
    fi

    # Preview may be broad because it is read-only. Execution must select an
    # exact classification or an explicit ACK list, plus another narrowing
    # filter, so a mistyped command cannot clear the whole ledger.
    if [ "$execute" = true ]; then
        if [ -z "$classification" ] && [ -z "$ack_file" ]; then
            log "ERROR: Execution requires --classification or --ack-file"
            return 2
        fi

        if [ -z "$ack_file" ] &&
           [ -z "$source" ] &&
           [ -z "$title_contains" ] &&
           [ -z "$older_than_hours" ] &&
           [ -z "$before_value" ]; then
            log "ERROR: Execution requires an additional narrowing filter"
            log "Use --source, --title-contains, --older-than-hours, --before, or --ack-file."
            return 2
        fi

        if ! [[ "$confirm_count" =~ ^[0-9]+$ ]] ||
           (( confirm_count <= 0 )); then
            log "ERROR: Execution requires --confirm-count with the exact positive preview count"
            return 2
        fi

        reason="${reason//$'\r'/ }"
        reason="${reason//$'\n'/ }"
        [ -n "$reason" ] || {
            log "ERROR: Execution requires a non-empty --reason"
            return 2
        }
    fi

    : >"$matches_file"

    jq -c \
        --arg source "$source" \
        --arg classification "$classification" \
        --arg titleContains "${title_contains,,}" \
        --argjson now "$START_TIME" \
        --argjson olderHours "${older_than_hours:-0}" \
        --argjson beforeEpoch "$before_epoch" \
        '
        (.downloadLedger // {}) as $ledger
        |
        .issues
        // {}
        | to_entries[]?
        | select((.value.active // false) == true)
        | select(.key | startswith("FLOW:DOWNLOAD:"))
        | select(
            (.value.classification // "") == "DOWNLOAD_FLOW_NOT_REACHED_SAB"
            or (.value.classification // "") == "DOWNLOAD_FLOW_SAB_VANISHED"
            or (.value.classification // "") == "DOWNLOAD_FLOW_IMPORT_MISSING"
            or (.value.classification // "") == "DOWNLOAD_FLOW_REVIEW_REQUIRED"
          )
        | select($source == "" or (.value.app // "") == $source)
        | select(
            $classification == ""
            or (.value.classification // "") == $classification
          )
        | select(
            $titleContains == ""
            or ((.value.title // "") | ascii_downcase | contains($titleContains))
          )
        | select(
            $olderHours == 0
            or (($now - (.value.firstSeen // $now)) >= ($olderHours * 3600))
          )
        | select(
            $beforeEpoch == 0
            or ((.value.firstSeen // 0) > 0 and (.value.firstSeen // 0) <= $beforeEpoch)
          )
        | (.key | ltrimstr("FLOW:DOWNLOAD:") | ascii_downcase) as $downloadId
        | {
            issueKey: .key,
            downloadId: $downloadId,
            ackId: (.value.ackId // ""),
            source: (.value.app // "Unknown"),
            severity: (.value.severity // "ERROR"),
            classification: (.value.classification // "UNKNOWN"),
            title: (.value.title // "Unknown"),
            firstSeen: (.value.firstSeen // 0),
            ageHours: (
                if (.value.firstSeen // 0) > 0
                then (($now - .value.firstSeen) / 3600 | floor)
                else 0
                end
            ),
            ledgerPresent: ($ledger[$downloadId] != null),
            arrQueueStatus: ($ledger[$downloadId].arrQueueStatus // "not observed"),
            sabStatus: ($ledger[$downloadId].sabStatus // "not observed")
          }
        ' "$STATE_FILE" >"$candidates_file" || return 1

    while IFS= read -r record; do
        [ -n "$record" ] || continue

        issue_key=$(jq -r '.issueKey' <<<"$record")
        ack_id=$(jq -r '.ackId // ""' <<<"$record")
        [ -n "$ack_id" ] || ack_id=$(issue_ack_id "$issue_key")

        if [ -n "$normalized_ack_file" ] &&
           ! grep -Fxiq -- "$ack_id" "$normalized_ack_file"; then
            continue
        fi

        jq -c --arg ackId "$ack_id" '.ackId = $ackId' <<<"$record" \
            >>"$matches_file" || return 1
    done <"$candidates_file"

    count=$(wc -l <"$matches_file" | tr -d ' ')
    [[ "$count" =~ ^[0-9]+$ ]] || count=0

    if [ -n "$normalized_ack_file" ]; then
        jq -r '.ackId' "$matches_file" |
            sort -u >"${TMP_DIR}/batch-dismiss-matched-ack-ids.txt"
        comm -23 \
            "$normalized_ack_file" \
            "${TMP_DIR}/batch-dismiss-matched-ack-ids.txt" \
            >"$unmatched_ack_file"
    fi

    printf 'Batch download-flow dismissal %s\n' \
        "$([ "$execute" = true ] && printf 'execution' || printf 'preview')"
    printf 'Matches: %s\n' "$count"
    printf 'Source filter: %s\n' "${source:-any}"
    printf 'Classification filter: %s\n' "${classification:-any exact flow issue}"
    printf 'Title contains: %s\n' "${title_contains:-not set}"
    if [ -n "$older_than_hours" ]; then
        printf 'Older than: %sh\n' "$older_than_hours"
    else
        printf 'Older than: not set\n'
    fi
    printf 'Before: %s\n' "${before_value:-not set}"
    printf 'ACK-ID file: %s\n\n' "${ack_file:-not set}"

    if [ -n "$unmatched_ack_file" ] && [ -s "$unmatched_ack_file" ]; then
        printf 'WARNING: These requested ACK IDs did not match an eligible active issue:\n'
        sed 's/^/  /' "$unmatched_ack_file"
        printf '\n'
    fi

    if (( count > 0 )); then
        printf 'ACK ID       SOURCE   AGE(h)  LEDGER  CLASSIFICATION                     TITLE\n'
        jq -r '
            [
                .ackId,
                .source,
                (.ageHours | tostring),
                (if .ledgerPresent then "yes" else "NO" end),
                .classification,
                .title
            ]
            | @tsv
            ' "$matches_file"
    fi

    if [ "$execute" != true ]; then
        write_batch_dismiss_preview \
            "$matches_file" \
            "$count" \
            "$source" \
            "$classification" \
            "$title_contains" \
            "$older_than_hours" \
            "$before_value" \
            "$ack_file" || return 1

        printf '\nPreview only: no issues were dismissed and no Arr, SABnzbd, or media changes were made.\n'
        printf 'Review table: %s\n' "$BATCH_PREVIEW_TSV"
        printf 'ACK-ID selection: %s\n' "$BATCH_PREVIEW_ACK_FILE"

        if (( count > 0 )); then
            printf '\nPreview this exact saved selection again:\n'
            printf '  /bin/bash /boot/config/plugins/user.scripts/scripts/arr_health_activity/script \\\n'
            printf '    --batch-dismiss-downloads --ack-file "%s"\n' "$BATCH_PREVIEW_ACK_FILE"
            printf '\nDismiss this exact saved selection after review:\n'
            printf '  /bin/bash /boot/config/plugins/user.scripts/scripts/arr_health_activity/script \\\n'
            printf '    --batch-dismiss-downloads --ack-file "%s" \\\n' "$BATCH_PREVIEW_ACK_FILE"
            printf '    --execute --confirm-count %s --reason "YOUR REVIEWED REASON"\n' "$count"
        else
            printf 'The ACK-ID file is empty because no eligible issues matched.\n'
        fi

        return 0
    fi

    if [ -n "$unmatched_ack_file" ] && [ -s "$unmatched_ack_file" ]; then
        log "ERROR: The ACK-ID file requested ${requested_ack_count} issue(s), but one or more did not match"
        log "Batch dismissal was refused; nothing was changed."
        return 2
    fi

    (( count > 0 )) || {
        log "ERROR: No active download-flow issues matched; nothing was changed"
        return 2
    }

    if (( confirm_count != count )); then
        log "ERROR: --confirm-count ${confirm_count} does not match the current preview count ${count}"
        log "Run the preview again; nothing was changed."
        return 2
    fi

    missing_ledger_count=$(jq -s '[.[] | select(.ledgerPresent != true)] | length' "$matches_file")
    if (( missing_ledger_count > 0 )); then
        log "ERROR: ${missing_ledger_count} matching issue(s) have no download-ledger record"
        log "Batch dismissal was refused; nothing was changed."
        return 2
    fi

    now=$(date +%s)
    timestamp=$(date '+%Y%m%d-%H%M%S')
    batch_hash=$(printf '%s' \
        "${now}|${source}|${classification}|${title_contains}|${older_than_hours}|${before_value}|${reason}|${count}" |
        sha256sum |
        awk '{print substr($1, 1, 10)}')
    batch_id="${timestamp}-${batch_hash}"

    mkdir -p -- "$BATCH_DISMISS_MANIFEST_DIR" || {
        log "ERROR: Unable to create batch-dismissal manifest directory"
        return 1
    }

    state_backup="${STATE_STORAGE_FILE:-$STATE_FILE}.pre-batch-dismiss.${batch_id}.bak"
    cp -p -- "$STATE_FILE" "$state_backup" || {
        log "ERROR: Unable to create pre-dismissal state backup: $state_backup"
        return 1
    }

    manifest_file="${BATCH_DISMISS_MANIFEST_DIR}/batch-dismiss-${batch_id}.json"
    manifest_tmp=$(mktemp "${BATCH_DISMISS_MANIFEST_DIR}/.batch-dismiss.XXXXXX") || return 1

    if ! jq -s \
        --arg batchId "$batch_id" \
        --arg source "$source" \
        --arg classification "$classification" \
        --arg titleContains "$title_contains" \
        --arg olderHours "$older_than_hours" \
        --arg before "$before_value" \
        --arg ackFile "$ack_file" \
        --arg reason "$reason" \
        --arg stateBackup "$state_backup" \
        --argjson dismissedAt "$now" \
        '{
            version: 1,
            batchId: $batchId,
            dismissedAt: $dismissedAt,
            reason: $reason,
            stateBackup: $stateBackup,
            filters: {
                source: $source,
                classification: $classification,
                titleContains: $titleContains,
                olderThanHours: $olderHours,
                before: $before,
                ackFile: $ackFile
            },
            count: length,
            items: .
          }' "$matches_file" >"$manifest_tmp"
    then
        rm -f -- "$manifest_tmp"
        log "ERROR: Unable to build batch-dismissal manifest"
        return 1
    fi

    mv -f -- "$manifest_tmp" "$manifest_file" || return 1

    if ! jq \
        --slurpfile matches "$matches_file" \
        --arg batchId "$batch_id" \
        --arg source "$source" \
        --arg classification "$classification" \
        --arg titleContains "$title_contains" \
        --arg olderHours "$older_than_hours" \
        --arg before "$before_value" \
        --arg ackFile "$ack_file" \
        --arg reason "$reason" \
        --arg manifest "$manifest_file" \
        --arg stateBackup "$state_backup" \
        --argjson now "$now" \
        --argjson count "$count" \
        '
        .version = 17
        |
        .downloadDismissalBatches = (.downloadDismissalBatches // {})
        |
        .downloadDismissalBatches[$batchId] = {
            batchId: $batchId,
            dismissedAt: $now,
            notifiedAt: 0,
            count: $count,
            reason: $reason,
            manifest: $manifest,
            stateBackup: $stateBackup,
            filters: {
                source: $source,
                classification: $classification,
                titleContains: $titleContains,
                olderThanHours: $olderHours,
                before: $before,
                ackFile: $ackFile
            }
          }
        |
        reduce $matches[] as $match (
            .;
            ($match.downloadId | ascii_downcase) as $id
            | ($match.issueKey) as $key
            | .downloadLedger[$id] |= (
                .manuallyDismissedAt = $now
                | .manualDismissalReason = $reason
                | .manualDismissalAckId = $match.ackId
                | .manualDismissalPreviousClassification = $match.classification
                | .manualDismissalNotifiedAt = $now
                | .manualDismissalBatchId = $batchId
                | .reconciliationCandidateFingerprint = ""
                | .reconciliationCandidateRuns = 0
                | .reconciliationCandidateFirstSeenAt = 0
                | .reconciliationCandidateLastSeenAt = 0
                | .lastSeen = ([ (.lastSeen // 0), $now ] | max)
              )
            | .issues[$key] |= (
                .active = false
                | .resolvedAt = $now
                | .lastSeen = $now
                | .manuallyDismissedAt = $now
                | .manualDismissalReason = $reason
                | .manualDismissalBatchId = $batchId
                | .transitionTimestamps = (
                    ((.transitionTimestamps // []) + [$now])
                    | map(select(type == "number"))
                    | unique
                    | sort
                  )
                | .acknowledgedSignature = ""
                | .acknowledgedAt = 0
                | .acknowledgementNote = ""
              )
          )
        ' "$STATE_FILE" >"$state_tmp"
    then
        log "ERROR: Unable to prepare atomic batch-dismissal state update"
        return 1
    fi

    save_state "$state_tmp" || return 1

    persistent_log \
        "BATCH_DISMISSED" \
        "batch_id=${batch_id} | count=${count} | source=${source:-any} | classification=${classification:-ack-list} | reason=${reason} | manifest=${manifest_file}"

    printf '\nBatch dismissal completed.\n'
    printf 'Dismissed: %s\n' "$count"
    printf 'Batch ID: %s\n' "$batch_id"
    printf 'State backup: %s\n' "$state_backup"
    printf 'Manifest: %s\n' "$manifest_file"
    printf 'No Sonarr, Radarr, SABnzbd, or media changes were made.\n'
    printf 'One summary notification will be queued by the next normal monitor run.\n'
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
        'ARR Health Monitor v3.11.0 lifecycle commands' \
        'Historical vanished/never-arrived attempts become REVIEW_REQUIRED warnings' \
        'after 12 hours and successful Arr/SAB checks; no import/cancellation is inferred.' \
        'Review warnings notify once per unchanged issue and remain in --list-active.' \
        'Notification details include the last reconciliation decision and evidence.' \
        '' \
        'Always invoke the Unraid User Scripts copy through /bin/bash:' \
        '  /bin/bash /boot/config/plugins/user.scripts/scripts/arr_health_activity/script COMMAND' \
        '' \
        'Inspect and manage one issue:' \
        '  --list-active' \
        '      List active issues and their 12-character ACK IDs.' \
        '' \
        '  --ack ACK_ID [note]' \
        '      Suppress reminders for the current unchanged issue signature.' \
        '      Acknowledgement does not resolve the issue or improve pipeline health.' \
        '' \
        '  --unack ACK_ID' \
        '      Remove an acknowledgement from an active issue.' \
        '' \
        '  --dismiss-download ACK_ID [reason]' \
        '      Close one intentionally abandoned exact download-flow issue.' \
        '' \
        'Preview or execute a guarded batch dismissal:' \
        '  --batch-dismiss-downloads [filters] [execution options]' \
        '' \
        '  Filters:' \
        '    --source Sonarr|Radarr' \
        '    --classification DOWNLOAD_FLOW_NOT_REACHED_SAB' \
        '    --classification DOWNLOAD_FLOW_SAB_VANISHED' \
        '    --classification DOWNLOAD_FLOW_IMPORT_MISSING' \
        '    --title-contains LITERAL_TEXT' \
        '    --older-than-hours POSITIVE_INTEGER' \
        '    --before DATE_OR_DATETIME' \
        '    --ack-file PATH' \
        '        One complete 12-character ACK ID per line.' \
        '' \
        '  Execution options:' \
        '    --execute' \
        '    --confirm-count EXACT_PREVIEW_COUNT' \
        '    --reason "operator explanation"' \
        '' \
        '  Preview is the default and never dismisses issues:' \
        "    --batch-dismiss-downloads --source Sonarr \\" \
        "      --classification DOWNLOAD_FLOW_SAB_VANISHED \\" \
        '      --title-contains "NCIS" --older-than-hours 24' \
        '' \
        '  Every preview writes two files and prints their exact paths:' \
        '    batch-preview-TIMESTAMP.tsv' \
        '        Full human-readable table for review.' \
        '    batch-preview-TIMESTAMP-ack-ids.txt' \
        '        ACK IDs only; accepted directly by --ack-file.' \
        '' \
        '  Use the generated ACK-only file as an exact saved selection:' \
        "    --batch-dismiss-downloads \\" \
        "      --ack-file \"/mnt/vault/cloud/logs/script/arr_health_activity/batch-dismissals/previews/FILE-ack-ids.txt\" \\" \
        "      --execute --confirm-count PREVIEW_COUNT \\" \
        '      --reason "Reviewed intentional removals"' \
        '' \
        '  After reviewing every preview row, execute with the exact count:' \
        "    --batch-dismiss-downloads --source Sonarr \\" \
        "      --classification DOWNLOAD_FLOW_SAB_VANISHED \\" \
        "      --title-contains \"NCIS\" --older-than-hours 24 \\" \
        "      --execute --confirm-count 64 \\" \
        '      --reason "One-time cleanup of intentionally removed downloads"' \
        '' \
        'Batch execution safeguards:' \
        '  - Requires an exact classification or an explicit ACK-ID file.' \
        '  - Requires at least one additional narrowing filter.' \
        '  - Refuses a changed preview count or a missing ledger record.' \
        '  - Creates a timestamped state backup and detailed JSON manifest.' \
        '  - Saves preview TSV and ACK-only files for 30 days.' \
        '  - Updates monitor state atomically and sends one later summary.' \
        '  - Never changes Sonarr, Radarr, SABnzbd, or any media file.' \
        '' \
        'Acknowledgements apply only to the current issue signature and clear on resolution or material change.' \
        'Download dismissal closes an intentional manual abandonment in monitor state only; it does not change Arr, SABnzbd, or media.'
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

    debug_log "Checking previously active issues for resolution"

    local active_records

    active_records=$(
        jq -c '
            .issues
            | to_entries[]
            | select(.value.active == true)
        ' "$STATE_FILE"
    )

    [ -n "$active_records" ] || {
        debug_log "No previously active issues require resolution checking"
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

            debug_log "Resolution deferred for $issue_key because required source scan was unavailable"

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
                debug_log "Resolution notification suppressed during flapping episode: $issue_key"

            elif [ "$automatic_reconciliation" = true ]; then

                # A richer, one-time AUTO-RECONCILED record is already queued.
                # Suppress the generic "condition no longer present" duplicate.
                debug_log "Generic resolution notification replaced by automatic reconciliation detail: $issue_key"

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

                debug_log "Resolution notification suppressed for notification-once event: $issue_key"

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
                elif $event == "batch-dismissed"
                then " [" + (.severity // "INFO") + "] [BATCH DISMISSED]"
                elif $event == "dismissed"
                then " [" + (.severity // "INFO") + "] [MANUALLY DISMISSED]"
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
    local dismissed
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
    dismissed=$(jq -s \
        '[.[] | select(.event == "dismissed" or .event == "batch-dismissed")] | length' \
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
    body+="This batch: ${page_items} | Info: ${info_new} | Warnings: ${warning_new} | Errors: ${error_new} | Resolved: ${resolved}"$'\n'
    body+="Auto-reconciled: ${reconciled} | Manually dismissed: ${dismissed}"$'\n'
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

            if classification_is_event_only_error "$classification"; then
                ((EVENT_ONLY_ERROR_COUNT++)) || true
            fi
            ;;
    esac

    if [ "$persist_issue_transition" = true ]; then

        persistent_log \
            "ISSUE" \
            "${source} | ${classification} | ${severity} | ${title} | stage=${stage}"
    fi

    if (( occurrences < notify_runs || elapsed_minutes < minimum_minutes )); then

        debug_log "Notification pending threshold: $issue_key"
        debug_log "Observations: ${occurrences}/${notify_runs}; active minutes: ${elapsed_minutes}/${minimum_minutes}"

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

        debug_log "Notification suppressed: normalized issue already reported"
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

        debug_log "${app} native health issue: ${health_source} (${health_type})"

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
    elif [ "$PREVIOUS_RUN_STATUS" = "failed" ] ||
         [ "$PREVIOUS_RUN_STATUS" = "interrupted" ]; then
        failures+=("Previous monitor run ${PREVIOUS_RUN_STATUS} during ${PREVIOUS_RUN_PHASE}: ${PREVIOUS_RUN_ERROR:-exit code ${PREVIOUS_RUN_EXIT_CODE}}")
    fi

    if [ "$MONITOR_RUNTIME_DEFERRED" = true ]; then
        failures+=("Runtime budget deferred optional phase(s): ${MONITOR_RUNTIME_DEFERRED_PHASES}")
    fi

    if [ "$ACTIVITY_AUDIT_ENABLED" = true ] &&
       [[ "$MONITOR_RUNTIME_DEFERRED_PHASES" != *"activity-audit"* ]]; then

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

prepare_arr_download_indexes() {
    local app queue
    for app in Sonarr Radarr; do
        case "$app" in Sonarr) queue="$SONARR_QUEUE";; Radarr) queue="$RADARR_QUEUE";; esac
        [[ -f "$queue" ]] || continue
        jq 'reduce .records[]? as $item ({}; ($item.downloadId // "" | ascii_downcase) as $id | if $id!="" and .[$id]==null then .[$id]=$item else . end)' \
          "$queue" >"${TMP_DIR}/${app,,}-download-index.json" || return 1
    done
}

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

    if [[ -s "${TMP_DIR}/${owner,,}-download-index.json" ]]; then
        jq -c --arg id "${download_id,,}" '.[$id] // {}' "${TMP_DIR}/${owner,,}-download-index.json"
        return $?
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

    if [[ -s "${TMP_DIR}/${app,,}-download-index.json" ]]; then
        jq -e --arg id "${download_id,,}" 'has($id)' "${TMP_DIR}/${app,,}-download-index.json" >/dev/null
        return $?
    fi

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

        debug_log "New CF score: $new_score"
        debug_log "Existing CF score: $existing_score"
        debug_log "CF score difference: $difference"
    fi

    if [ -n "$new_formats" ] &&
       [ -n "$existing_formats" ]
    then

        gained=$(cf_difference "$new_formats" "$existing_formats")
        missing=$(cf_difference "$existing_formats" "$new_formats")

        if [ -n "$gained" ]; then

            debug_log "CFs only in downloaded release:"

            while IFS= read -r cf; do
                [ -n "$cf" ] && debug_log "  + $cf"
            done <<<"$gained"
        fi

        if [ -n "$missing" ]; then

            debug_log "CFs only in existing media:"

            while IFS= read -r cf; do
                [ -n "$cf" ] && debug_log "  + $cf"
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

        debug_log "$app queue: no entries"

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
            debug_log "$app queue symptom suppressed by primary SAB issue: $download_id"
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

                    debug_log "Arr generic classification promoted"
                    debug_log "Application: $app"
                    debug_log "From: $classification"
                    debug_log "To: $promoted_classification"

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

        debug_log "------------------------------------------------------------"
        debug_log "$app issue detected"
        debug_log "Media: $media_name"
        debug_log "Release: $release"
        debug_log "Classification: $classification"
        debug_log "Severity: $severity"
        debug_log "Reason: $reason"
        debug_log "Queue age: ${age}h"
        debug_log "Arr status: $status"
        debug_log "Tracked status: $tracked_status"
        debug_log "Tracked state: $tracked_state"

        [ -n "$download_id" ] &&
            debug_log "Download ID: $download_id"

        [ "$sab_status" != "Unknown" ] &&
            debug_log "SAB status: $sab_status"

        if jq -e \
            'any(.reasons[]?; .classification | startswith("CF_REJECT"))' \
            "$analysis_file" >/dev/null 2>&1
        then
            log_cf_details "$message"
        fi

        if [ -n "$reason_detail" ]; then
            debug_log "Classified queue reasons:"

            while IFS= read -r detail_line; do
                [ -n "$detail_line" ] && debug_log "  ${detail_line}"
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

            debug_log "Notification suppressed: issue already reported"
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
        local warning_epoch
        local warning_age=""

        warning_type=$(jq -r '.type // "WARNING"' <<<"$record")
        warning_text=$(jq -r '.text // .message // "SABnzbd warning without detail"' <<<"$record")
        warning_origin=$(jq -r '.origin // "SABnzbd"' <<<"$record")
        warning_epoch=$(jq -r '
            (.time // 0)
            | if type == "number" then floor
              elif type == "string" then (tonumber? // 0 | floor)
              else 0
              end
            ' <<<"$record")

        if [[ "$warning_epoch" =~ ^[0-9]+$ ]] && (( warning_epoch > 0 )); then
            warning_age=$(( ($(date +%s) - warning_epoch) / 3600 ))
            (( warning_age >= 0 )) || warning_age=0
            (( warning_age <= SAB_WARNING_ACTIVE_HOURS )) || continue
        else
            warning_age=""
        fi

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
            "$warning_age" \
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

            debug_log "SABnzbd queue pause is inside an allowed pause window"

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

        # A core SAB API outage already owns the incident. Do not add a child
        # provider-statistics alert that cannot be independently actioned.
        if [ "$SAB_API_OK" != true ]; then
            return 0
        fi

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

    debug_log "Checking SABnzbd completed jobs for stranded downloads"

    if ! jq -e '(.history.slots // [] | length) > 0' "$SAB_HISTORY" >/dev/null 2>&1; then
        debug_log "SABnzbd history contains no jobs"
        return
    fi

    prepare_sab_history_index || return 1
    local fs_candidates="${TMP_DIR}/sab-filesystem-candidates.jsonl"
    jq -c --arg movie "${SAB_MOVIE_CATEGORY,,}" --arg tv "${SAB_TV_CATEGORY,,}" \
      --argjson cutoff "$((START_TIME-SAB_ORPHAN_IGNORE_HOURS*3600))" '
      .[] | select((.status // "" | ascii_downcase)=="completed")
      | select((.category // .cat // "" | ascii_downcase) as $cat | $cat==$movie or $cat==$tv)
      | select(.auditEpoch<=0 or .auditEpoch <= $cutoff)
    ' "${TMP_DIR}/sab-normalized-history.json" >"$fs_candidates" || return 1
    while IFS= read -r item; do

        [ -n "$item" ] || continue
        runtime_budget_allows_optional_phase "sab-filesystem-batch" || return 1

        local status
        local category
        local nzo_id
        local name

        IFS=$'\t' read -r status category nzo_id name < <(jq -r \
            '[.status // "unknown", .category // .cat // "unknown", .nzo_id // "unknown", .name // .nzb_name // "Unknown"] | @tsv' <<<"$item")

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

                    debug_log "Skipping SAB orphan check for '$name': Sonarr scan unavailable"

                    continue
                fi
                ;;

            Radarr)

                if [ "$RADARR_SCAN_OK" != true ]; then

                    debug_log "Skipping SAB orphan check for '$name': Radarr scan unavailable"

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

        completed_epoch=$(jq -r '.auditEpoch // 0' <<<"$item")
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

            debug_log "------------------------------------------------------------"
            debug_log "SAB empty leftover"
            debug_log "Expected owner: $owner"
            debug_log "Category: $category"
            debug_log "Release: $name"
            debug_log "Age: ${age}h"
            debug_log "Path: $completed_path"
            debug_log "Action: log only"

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

                debug_log "------------------------------------------------------------"
                debug_log "SAB sample residue"
                debug_log "Expected owner: $owner"
                debug_log "Category: $category"
                debug_log "Release: $name"
                debug_log "Age: ${age}h"
                debug_log "Path: $completed_path"
                debug_log "Samples: $sample_files"
                debug_log "Remaining size: $(bytes_human "$total_bytes")"
                debug_log "Action: log only"

                continue
                ;;

            SAB_RESIDUE)

                ((SAB_RESIDUE_COUNT++)) || true

                debug_log "------------------------------------------------------------"
                debug_log "SAB cleanup residue"
                debug_log "Expected owner: $owner"
                debug_log "Category: $category"
                debug_log "Release: $name"
                debug_log "Age: ${age}h"
                debug_log "Path: $completed_path"
                debug_log "Repair files: $repair_files"
                debug_log "Metadata files: $metadata_files"
                debug_log "Other files: $other_files"
                debug_log "Remaining size: $(bytes_human "$total_bytes")"
                debug_log "Action: log only"

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

        debug_log "------------------------------------------------------------"
        debug_log "SAB stranded download detected"
        debug_log "Expected owner: $owner"
        debug_log "Category: $category"
        debug_log "Release: $name"
        debug_log "Classification: $classification"
        debug_log "Severity: $severity"
        debug_log "Stage: $stage"
        debug_log "Reason: $reason"
        debug_log "SAB status: $status"
        debug_log "Completed age: ${age}h"
        debug_log "$owner queue: Not found"

        [ -n "$nzo_id" ] &&
            debug_log "Download ID: $nzo_id"

        debug_log "Completed path: $completed_path"

        debug_log "Total files: $total_files"
        debug_log "Total size: $(bytes_human "$total_bytes")"

        debug_log "Media files: $media_files ($(bytes_human "$media_bytes"))"
        debug_log "Archive files: $archive_files"
        debug_log "Sample files: $sample_files"
        debug_log "Repair files: $repair_files"
        debug_log "Metadata files: $metadata_files"
        debug_log "Other files: $other_files ($(bytes_human "$other_bytes"))"

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

            debug_log "Candidate only: $classification notification threshold is ${warn_after}h"

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

            debug_log "Notification suppressed: stranded issue already reported"
        fi

    done <"$fs_candidates"
}

carry_deferred_filesystem_issue_counts() {
    [[ "$SAB_FILESYSTEM_SCAN_OK" != true ]] || return 0
    local counts info warning error
    counts=$(jq -r --rawfile seen "$SEEN_ISSUES_FILE" '
      ($seen|split("\n")) as $seen
      | [.issues|to_entries[]|select(.value.active==true)
         | select(.value.app=="SABnzbd" and (.value.classification // "" | startswith("SAB_STRANDED_")))
         | select(.key as $key | ($seen|index($key))==null)] as $preserved
      | [([$preserved[]|select(.value.severity=="INFO")]|length),
         ([$preserved[]|select(.value.severity=="WARNING")]|length),
         ([$preserved[]|select(.value.severity=="ERROR")]|length)] | @tsv
    ' "$STATE_FILE") || return 1
    IFS=$'\t' read -r info warning error <<<"$counts"
    INFO_COUNT=$((INFO_COUNT+info)); WARNING_COUNT=$((WARNING_COUNT+warning)); ERROR_COUNT=$((ERROR_COUNT+error))
    TOTAL_ISSUES=$((TOTAL_ISSUES+info+warning+error))
}

sab_filesystem_scan_due() {
    local last
    last=$(jq -r '.monitor.sabFilesystemLastSuccessfulAt // 0' "$STATE_FILE")
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( last<=0 || START_TIME-last >= SAB_FILESYSTEM_SCAN_INTERVAL_MINUTES*60 ))
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

        debug_log "SAB filesystem orphan/residue scan deferred while Unraid mover is active"
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

fetch_arr_activity_history_paged() {

    local app="$1"
    local api_root="$2"
    local api_key="$3"
    local output="$4"
    local since_iso="${5:-$AUDIT_SINCE_ISO}"
    local include_query
    local records_file="${TMP_DIR}/${app,,}-history-audit-records.jsonl"
    local page_file
    local endpoint
    local page=1
    local loaded=0
    local count=0
    local reached_cutoff=false

    case "$app" in
        Sonarr)
            include_query="includeSeries=true&includeEpisode=true"
            ;;

        Radarr)
            include_query="includeMovie=true"
            ;;

        *)
            API_LAST_ERROR="unsupported Arr application"
            API_LAST_HTTP_CODE=""
            API_LAST_ENDPOINT=""
            return 1
            ;;
    esac

    : >"$records_file"

    while (( loaded < ARR_ACTIVITY_HISTORY_MAX_RECORDS )); do
        page_file="${TMP_DIR}/${app,,}-history-audit-page-${page}.json"
        endpoint="${api_root%/}/history?page=${page}&pageSize=${ARR_ACTIVITY_HISTORY_PAGE_SIZE}&sortKey=date&sortDirection=descending&${include_query}"

        api_get "$endpoint" "$api_key" "$page_file" || return 1

        validate_arr_payload \
            "$app" \
            history-page \
            "$page_file" \
            "$endpoint" || return 1

        count=$(jq '.records | length' "$page_file")
        [[ "$count" =~ ^[0-9]+$ ]] || count=0

        jq -c \
            --arg since "$since_iso" \
            '.records[]? | select((.date // "") >= $since)' \
            "$page_file" >>"$records_file" || return 1

        if jq -e \
            --arg since "$since_iso" \
            'any(.records[]?; (.date // "") < $since)' \
            "$page_file" >/dev/null 2>&1
        then
            reached_cutoff=true
        fi

        loaded=$((loaded + count))

        if [ "$reached_cutoff" = true ] ||
           (( count < ARR_ACTIVITY_HISTORY_PAGE_SIZE )); then
            break
        fi

        ((page++)) || true
    done

    if [ "$reached_cutoff" != true ] &&
       (( loaded >= ARR_ACTIVITY_HISTORY_MAX_RECORDS )); then
        API_LAST_ERROR="paged history reached ARR_ACTIVITY_HISTORY_MAX_RECORDS=${ARR_ACTIVITY_HISTORY_MAX_RECORDS} before the audit cutoff"
        API_LAST_HTTP_CODE="200"
        API_LAST_ENDPOINT="${api_root%/}/history"
        return 1
    fi

    jq -s '.' "$records_file" >"$output" || return 1
}

arr_history_cache_for_app() {

    case "$1" in
        Sonarr)
            printf '%s\n' "$SONARR_HISTORY_CACHE"
            ;;

        Radarr)
            printf '%s\n' "$RADARR_HISTORY_CACHE"
            ;;

        *)
            return 1
            ;;
    esac
}

atomic_replace_history_cache() {

    local source="$1"
    local target="$2"
    local cache_tmp

    jq -e 'type == "array"' "$source" >/dev/null 2>&1 || return 1
    mkdir -p -- "$ARR_HISTORY_CACHE_DIR" || return 1
    cache_tmp=$(mktemp "${ARR_HISTORY_CACHE_DIR}/.history-cache.XXXXXX") || return 1

    cp -f -- "$source" "$cache_tmp" || {
        rm -f -- "$cache_tmp"
        return 1
    }

    mv -f -- "$cache_tmp" "$target"
}

update_arr_history_cursor() {

    local app="$1"
    local delta_file="$2"
    local latest_date
    local latest_id
    local tmp="${TMP_DIR}/state.history-cursor.json"

    latest_date=$(jq -r \
        '[.[]? | select((.date // "") != "")] | max_by(.date // "") | .date // empty' \
        "$delta_file")
    latest_id=$(jq -r \
        --arg date "$latest_date" \
        '[.[]? | select((.date // "") == $date)] | max_by(.id // 0) | .id // ""' \
        "$delta_file")

    if [ -z "$latest_date" ]; then
        latest_date=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        latest_id=""
    fi

    jq \
        --arg app "$app" \
        --arg date "$latest_date" \
        --arg id "$latest_id" \
        --argjson now "$START_TIME" \
        '
        .historyCursors = (.historyCursors // {})
        |
        .historyCursors[$app] = {
            lastDate: $date,
            lastId: $id,
            updatedAt: $now
        }
        ' "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp"
}

fetch_arr_activity_history() {

    local app="$1"
    local api_root="$2"
    local api_key="$3"
    local output="$4"
    local cache_file
    local delta_file="${TMP_DIR}/${app,,}-history-delta.json"
    local merged_file="${TMP_DIR}/${app,,}-history-cache-merged.json"
    local cursor_date
    local cursor_epoch=0
    local overlap_epoch=0
    local request_since="$AUDIT_SINCE_ISO"
    local endpoint

    cache_file=$(arr_history_cache_for_app "$app") || return 1
    cursor_date=$(jq -r \
        --arg app "$app" \
        '.historyCursors[$app].lastDate // ""' \
        "$STATE_FILE")

    if [ -f "$cache_file" ] &&
       jq -e 'type == "array"' "$cache_file" >/dev/null 2>&1 &&
       [ -n "$cursor_date" ]
    then
        cursor_epoch=$(date_to_epoch "$cursor_date")
        if (( cursor_epoch > 0 )); then
            overlap_epoch=$((
                cursor_epoch - ARR_HISTORY_CURSOR_OVERLAP_MINUTES * 60
            ))
            request_since=$(date -u -d "@${overlap_epoch}" '+%Y-%m-%dT%H:%M:%SZ')
        fi
    fi

    case "$app" in

        Sonarr)
            endpoint="${api_root%/}/history/since?date=${request_since}&includeSeries=true&includeEpisode=true"
            ;;

        Radarr)
            endpoint="${api_root%/}/history/since?date=${request_since}&includeMovie=true"
            ;;

        *)

            return 1
            ;;
    esac

    if api_get "$endpoint" "$api_key" "$delta_file"; then
        validate_arr_payload \
            "$app" \
            history-since \
            "$delta_file" \
            "$endpoint" || return 1
    elif [ "$API_LAST_HTTP_CODE" != 404 ]; then
        return 1
    else
        # Some Arr versions or reverse-proxy routes do not expose
        # history/since. Fall back to stable paged history collection.
        fetch_arr_activity_history_paged \
            "$app" \
            "$api_root" \
            "$api_key" \
            "$delta_file" \
            "$request_since" || return 1
    fi

    if [ -f "$cache_file" ] &&
       jq -e 'type == "array"' "$cache_file" >/dev/null 2>&1
    then
        jq -s \
            --arg cutoff "$AUDIT_SINCE_ISO" \
            '
            [ .[][]? ]
            | unique_by(
                [
                    (.id // ""),
                    (.date // ""),
                    (.eventType // ""),
                    (.downloadId // .data.downloadId // "")
                ]
                | @json
            )
            | map(select((.date // "") >= $cutoff))
            | sort_by(.date // "")
            ' "$cache_file" "$delta_file" >"$merged_file" || return 1
    else
        jq \
            --arg cutoff "$AUDIT_SINCE_ISO" \
            'map(select((.date // "") >= $cutoff)) | sort_by(.date // "")' \
            "$delta_file" >"$merged_file" || return 1
    fi

    cp -f -- "$merged_file" "$output" || return 1
    atomic_replace_history_cache "$merged_file" "$cache_file" || return 1
    update_arr_history_cursor "$app" "$delta_file" || return 1

    case "$app" in
        Sonarr)
            SONARR_LEDGER_HISTORY="$delta_file"
            ;;

        Radarr)
            RADARR_LEDGER_HISTORY="$delta_file"
            ;;
    esac

    return 0
}

###############################################################################
# PROCESS RECENT ARR ACTIVITY - v2.5
###############################################################################

arr_history_failure_has_terminal_recovery() {

    local app="$1"
    local failure="$2"
    local history_file="$3"
    local failure_date failure_epoch download_id identity
    local series_id=0 episode_id=0 movie_id=0
    local recovery recovery_epoch

    failure_date=$(jq -r '.date // ""' <<<"$failure")
    failure_epoch=$(date_to_epoch "$failure_date")
    (( failure_epoch > 0 )) || return 1

    download_id=$(jq -r \
        '.downloadId // .data.downloadId // .data.downloadClientId // ""' \
        <<<"$failure")
    identity=$(arr_download_ledger_identity "$app" "$failure" "history")

    case "$app" in
        Sonarr)
            series_id=$(jq -r '.seriesId // 0' <<<"$identity")
            episode_id=$(jq -r '.episodeId // 0' <<<"$identity")
            ;;

        Radarr)
            movie_id=$(jq -r '.movieId // 0' <<<"$identity")
            ;;
    esac

    [[ "$series_id" =~ ^[0-9]+$ ]] || series_id=0
    [[ "$episode_id" =~ ^[0-9]+$ ]] || episode_id=0
    [[ "$movie_id" =~ ^[0-9]+$ ]] || movie_id=0

    while IFS= read -r recovery; do
        [ -n "$recovery" ] || continue

        recovery_epoch=$(date_to_epoch "$(jq -r '.date // ""' <<<"$recovery")")
        if (( recovery_epoch > failure_epoch )); then
            return 0
        fi
    done < <(
        jq -c \
            --arg app "$app" \
            --arg downloadId "${download_id,,}" \
            --argjson seriesId "$series_id" \
            --argjson episodeId "$episode_id" \
            --argjson movieId "$movie_id" \
            '
            .[]?
            | select(
                .eventType == "downloadFolderImported"
                or .eventType == "downloadIgnored"
            )
            | select(
                (
                    $downloadId != ""
                    and
                    (
                        .downloadId
                        // .data.downloadId
                        // .data.downloadClientId
                        // ""
                        | ascii_downcase
                    ) == $downloadId
                )
                or
                (
                    $app == "Sonarr"
                    and $seriesId > 0
                    and $episodeId > 0
                    and
                    (
                        .seriesId
                        // .episode.seriesId
                        // .series.id
                        // 0
                    ) == $seriesId
                    and
                    (
                        .episodeId
                        // .episode.id
                        // 0
                    ) == $episodeId
                )
                or
                (
                    $app == "Radarr"
                    and $movieId > 0
                    and
                    (
                        .movieId
                        // .movie.id
                        // 0
                    ) == $movieId
                )
            )
            ' \
            "$history_file" 2>/dev/null
    )

    return 1
}

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

    failed=0
    local recovered=0 failure

    while IFS= read -r failure; do
        [ -n "$failure" ] || continue

        if arr_history_failure_has_terminal_recovery \
            "$app" \
            "$failure" \
            "$history_file"
        then
            ((recovered++)) || true
        else
            ((failed++)) || true
        fi
    done < <(
        jq -c \
            '.[]? | select(.eventType == "downloadFailed")' \
            "$history_file" 2>/dev/null
    )

    case "$app" in

        Sonarr)

            SONARR_AUDIT_IMPORTED="$imported"
            SONARR_AUDIT_DOWNLOAD_FAILED="$failed"
            SONARR_AUDIT_DOWNLOAD_FAILED_RECOVERED="$recovered"
            ;;

        Radarr)

            RADARR_AUDIT_IMPORTED="$imported"
            RADARR_AUDIT_DOWNLOAD_FAILED="$failed"
            RADARR_AUDIT_DOWNLOAD_FAILED_RECOVERED="$recovered"
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

        if arr_history_failure_has_terminal_recovery \
            "$app" \
            "$item" \
            "$history_file"
        then
            ((ARR_HISTORY_FAILURE_RECOVERED_COUNT++)) || true
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

    local history_signature="" previous_signature="" replay_at=0
    if [ -f "$history_file" ]; then
        history_signature=$(sha256sum "$history_file" | awk '{print $1}')
        previous_signature=$(jq -r --arg app "$app" '.monitor.arrLedgerHistory[$app].signature // ""' "$STATE_FILE")
        replay_at=$(jq -r --arg app "$app" '.monitor.arrLedgerHistory[$app].replayedAt // 0' "$STATE_FILE")
    fi
    if [ -f "$history_file" ] && { [ "$history_signature" != "$previous_signature" ] || (( START_TIME-replay_at >= DOWNLOAD_LEDGER_FULL_REPLAY_HOURS*3600 )); }; then

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

        done < <(jq -c '.[]? | select(.eventType == "grabbed" or .eventType == "downloadFolderImported" or .eventType == "downloadFailed" or .eventType == "downloadIgnored")' "$history_file")
        jq -nc --arg app "$app" --arg signature "$history_signature" --argjson now "$START_TIME" \
          '{app:$app,signature:$signature,replayedAt:$now}' >>"${TMP_DIR}/arr-ledger-cursors.jsonl" || return 1
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
    local signature="" previous="" last_replay=0 tmp
    # Queue observations are always fresh, even if completed history is cached.
    if [ "$SAB_QUEUE_OK" = true ] && [ -f "$SAB_QUEUE" ]; then
        jq -c --arg movie "${SAB_MOVIE_CATEGORY,,}" --arg tv "${SAB_TV_CATEGORY,,}" --argjson now "$START_TIME" '
          .queue.slots[]? | (.cat // .category // "" | ascii_downcase) as $cat
          | select($cat == $movie or $cat == $tv)
          | (.nzo_id // "" | ascii_downcase) as $id | select($id != "")
          | {id:$id,app:(if $cat==$movie then "Radarr" else "Sonarr" end),
             release:(.filename // .name // "Unknown SAB job"),title:(.filename // .name // "Unknown SAB job"),
             kind:"sabQueue",status:(.status // "unknown"),warning:"",identity:{},
             eventEpoch:(.time_added | tonumber? // $now),observedAt:$now}
        ' "$SAB_QUEUE" >>"$DOWNLOAD_LEDGER_OBSERVATIONS_FILE" || return 1
    fi
    [ "$SAB_HISTORY_OK" = true ] && [ -f "$SAB_HISTORY" ] || return 0
    signature=$(sha256sum "$SAB_HISTORY" | awk '{print $1}')
    previous=$(jq -r '.monitor.sabLedgerCacheSignature // ""' "$STATE_FILE")
    last_replay=$(jq -r '.monitor.sabLedgerLastReplayAt // 0' "$STATE_FILE")
    if [ "$signature" = "$previous" ] && (( START_TIME-last_replay < DOWNLOAD_LEDGER_FULL_REPLAY_HOURS*3600 )); then
        debug_log "SAB ledger history unchanged; retained unresolved ledger records continue reconciliation"
        return 0
    fi
    tmp="${TMP_DIR}/sab-ledger-batch.jsonl"
    # One JSON pass replaces per-history-item jq/date/process invocations.
    # Preserve the original timestamp for GNU-date fallback on future formats.
    jq -c --slurpfile state "$STATE_FILE" --arg movie "${SAB_MOVIE_CATEGORY,,}" --arg tv "${SAB_TV_CATEGORY,,}" \
      --argjson now "$START_TIME" --argjson cutoff "$((START_TIME-DOWNLOAD_LEDGER_DISCOVERY_HOURS*3600))" '
      def epoch: if type=="number" then floor else (tonumber? // (try (sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) catch 0)) end;
      .history.slots[]? | (.category // .cat // "" | ascii_downcase) as $cat
      | select($cat==$movie or $cat==$tv)
      | (.nzo_id // "" | ascii_downcase) as $id | select($id!="")
      | (.status // "unknown" | ascii_downcase) as $status
      | (if $status=="completed" then "sabCompleted" elif $status=="failed" then "sabFailed"
         elif (["quickcheck","verifying","repairing","fetching","extracting","moving","running","queued"] | index($status))!=null then "sabQueue" else "" end) as $kind
      | select($kind!="")
      | (.completed // .completed_time // .completedTime // .completionTime // .time_completed // "") as $raw
      | ($raw | epoch) as $epoch
      | {id:$id,app:(if $cat==$movie then "Radarr" else "Sonarr" end),
         release:(.name // .nzb_name // "Unknown SAB job"),title:(.name // .nzb_name // "Unknown SAB job"),
         kind:$kind,status:(.status // "unknown"),warning:"",identity:{},
         eventEpoch:$epoch,observedAt:(if $kind=="sabQueue" then $now else $epoch end),rawEpoch:$raw,
         enrolled:($state[0].downloadLedger[$id].flowEnrolled // false)}
      | select(.kind!="sabCompleted" or .eventEpoch==0 or .eventEpoch >= $cutoff or .enrolled)
    ' "$SAB_HISTORY" >"$tmp" || return 1
    local record raw epoch
    # Rare fallback records retain the existing permissive date parser.
    while IFS= read -r record; do
        raw=$(jq -r '.rawEpoch' <<<"$record")
        epoch=$(date_to_epoch "$raw")
        jq -c --argjson epoch "$epoch" '.eventEpoch=(if $epoch>0 then $epoch elif .kind=="sabQueue" then .observedAt else $epoch end) | if .kind!="sabQueue" then .observedAt=$epoch else . end' <<<"$record" >>"${tmp}.fallback" || return 1
    done < <(jq -c 'select(.eventEpoch<=0)' "$tmp")
    jq -c 'select(.eventEpoch>0) | del(.rawEpoch,.enrolled)' "$tmp" >>"$DOWNLOAD_LEDGER_OBSERVATIONS_FILE" || return 1
    if [ -s "${tmp}.fallback" ]; then
        jq -c --argjson cutoff "$((START_TIME-DOWNLOAD_LEDGER_DISCOVERY_HOURS*3600))" \
          'select(.kind!="sabCompleted" or .eventEpoch >= $cutoff or .enrolled) | del(.rawEpoch,.enrolled)' \
          "${tmp}.fallback" >>"$DOWNLOAD_LEDGER_OBSERVATIONS_FILE" || return 1
    fi
    SAB_LEDGER_NEW_SIGNATURE="$signature"
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
                reconciliationNotifiedAt: 0,
                manuallyDismissedAt: 0,
                manualDismissalReason: "",
                manualDismissalAckId: "",
                manualDismissalPreviousClassification: "",
                manualDismissalNotifiedAt: 0,
                manualDismissalBatchId: ""
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
    local api_root
    local api_key
    local include_query
    local encoded_id

    case "$app" in
        Sonarr)
            api_root="$SONARR_API_ROOT"
            api_key="$SONARR_API_KEY"
            include_query="includeSeries=true&includeEpisode=true"
            ;;

        Radarr)
            api_root="$RADARR_API_ROOT"
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
        "${api_root%/}/history?page=1&pageSize=100&sortKey=date&sortDirection=descending&downloadId=${encoded_id}&${include_query}" \
        "$api_key" \
        "$output" || return 1

    validate_arr_payload \
        "$app" \
        history-page \
        "$output" \
        "${api_root%/}/history"
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
            printf '%s\t%s\n' "$SONARR_API_ROOT" "$SONARR_API_KEY"
            ;;

        Radarr)
            printf '%s\t%s\n' "$RADARR_API_ROOT" "$RADARR_API_KEY"
            ;;

        *)
            return 1
            ;;
    esac
}

record_arr_reconciliation_not_found() {

    local download_id="$1"
    local app="$2"
    local object_label="$3"
    local object_id="$4"

    debug_log "${app} reconciliation: ${object_label} ${object_id} no longer exists in Arr (HTTP 404); download ${download_id} remains unresolved"

    write_download_reconciliation_result \
        "$download_id" \
        "$app" \
        true \
        false \
        "" \
        "" \
        "INFO" \
        "" \
        "Exact Arr record no longer exists" \
        "${object_label}: ${object_id}; HTTP 404. The issue remains active for review or intentional batch dismissal."
}

record_arr_database_file_reconciliation() {

    local download_id="$1"
    local app="$2"
    local record="$3"
    local connection
    local api_root
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

    IFS=$'\t' read -r api_root api_key <<<"$connection"

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
                   ! [[ "$parent_id" =~ ^[0-9]+$ ]] || (( parent_id <= 0 ))
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
                    "${api_root%/}/episode/${target_id}" \
                    "$api_key" \
                    "$object_file"
                then
                    if [ "$API_LAST_HTTP_CODE" = 404 ]; then
                        record_arr_reconciliation_not_found \
                            "$download_id" "$app" "Episode ID" "$target_id"
                        return 0
                    fi

                    ((DOWNLOAD_LEDGER_RECONCILIATION_FAILED_COUNT++)) || true
                    write_download_reconciliation_result \
                        "$download_id" "$app" false false \
                        "" "" "INFO" "" \
                        "Sonarr episode API check failed" \
                        "Episode ID: ${target_id}; endpoint: ${API_LAST_ENDPOINT}; ${API_LAST_ERROR}"
                    return 1
                fi

                if ! validate_arr_payload \
                    "$app" episode "$object_file" \
                    "${api_root%/}/episode/${target_id}"
                then
                    ((DOWNLOAD_LEDGER_RECONCILIATION_FAILED_COUNT++)) || true
                    write_download_reconciliation_result \
                        "$download_id" "$app" false false \
                        "" "" "INFO" "" \
                        "Sonarr episode response validation failed" \
                        "Endpoint: ${API_LAST_ENDPOINT}; ${API_LAST_ERROR}"
                    return 1
                fi

                current_parent_id=$(jq -r '.seriesId // 0' "$object_file")
                current_season_number=$(jq -r '.seasonNumber // -1' "$object_file")
                current_episode_number=$(jq -r '.episodeNumber // -1' "$object_file")
                has_file=$(jq -r '(.hasFile // false) | tostring' "$object_file")
                file_id=$(jq -r '.episodeFileId // 0' "$object_file")

                # History may contain exact episode/series IDs without expanded
                # numbering. Enrich missing numbers only from that exact episode;
                # supplied numbers must still match. Never infer identity by title.
                [[ "$season_number" =~ ^[0-9]+$ ]] || season_number="$current_season_number"
                [[ "$episode_number" =~ ^[0-9]+$ ]] || episode_number="$current_episode_number"

                if [[ "$current_season_number" =~ ^[0-9]+$ ]] &&
                   [[ "$current_episode_number" =~ ^[0-9]+$ ]] &&
                   [ "$(jq -r '.id // 0' "$object_file")" = "$target_id" ] &&
                   [[ "$target_id" =~ ^[0-9]+$ ]] && (( target_id > 0 )) &&
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
                    "${api_root%/}/episodefile/${file_id}" \
                    "$api_key" \
                    "$media_file"
                then
                    if [ "$API_LAST_HTTP_CODE" = 404 ]; then
                        record_arr_reconciliation_not_found \
                            "$download_id" "$app" "Episode file ID" "$file_id"
                        return 0
                    fi

                    ((DOWNLOAD_LEDGER_RECONCILIATION_FAILED_COUNT++)) || true
                    write_download_reconciliation_result \
                        "$download_id" "$app" false false \
                        "" "" "INFO" "" \
                        "Sonarr episode-file API check failed" \
                        "Episode file ID: ${file_id}; endpoint: ${API_LAST_ENDPOINT}; ${API_LAST_ERROR}"
                    return 1
                fi

                if ! validate_arr_payload \
                    "$app" episode-file "$media_file" \
                    "${api_root%/}/episodefile/${file_id}"
                then
                    ((DOWNLOAD_LEDGER_RECONCILIATION_FAILED_COUNT++)) || true
                    write_download_reconciliation_result \
                        "$download_id" "$app" false false \
                        "" "" "INFO" "" \
                        "Sonarr episode-file response validation failed" \
                        "Endpoint: ${API_LAST_ENDPOINT}; ${API_LAST_ERROR}"
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
                    "${api_root%/}/movie/${target_id}" \
                    "$api_key" \
                    "$object_file"
                then
                    if [ "$API_LAST_HTTP_CODE" = 404 ]; then
                        record_arr_reconciliation_not_found \
                            "$download_id" "$app" "Movie ID" "$target_id"
                        return 0
                    fi

                    ((DOWNLOAD_LEDGER_RECONCILIATION_FAILED_COUNT++)) || true
                    write_download_reconciliation_result \
                        "$download_id" "$app" false false \
                        "" "" "INFO" "" \
                        "Radarr movie API check failed" \
                        "Movie ID: ${target_id}; endpoint: ${API_LAST_ENDPOINT}; ${API_LAST_ERROR}"
                    return 1
                fi

                if ! validate_arr_payload \
                    "$app" movie "$object_file" \
                    "${api_root%/}/movie/${target_id}"
                then
                    ((DOWNLOAD_LEDGER_RECONCILIATION_FAILED_COUNT++)) || true
                    write_download_reconciliation_result \
                        "$download_id" "$app" false false \
                        "" "" "INFO" "" \
                        "Radarr movie response validation failed" \
                        "Endpoint: ${API_LAST_ENDPOINT}; ${API_LAST_ERROR}"
                    return 1
                fi

                has_file=$(jq -r '(.hasFile // false) | tostring' "$object_file")
                file_id=$(jq -r '.movieFileId // 0' "$object_file")

                if [[ "$target_id" =~ ^[0-9]+$ ]] && (( target_id > 0 )) &&
                   [[ "$file_id" =~ ^[0-9]+$ ]] && (( file_id > 0 )) &&
                   [ "$has_file" = true ] &&
                   [ "$(jq -r '.id // 0' "$object_file")" = "$target_id" ]
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
                    "${api_root%/}/moviefile/${file_id}" \
                    "$api_key" \
                    "$media_file"
                then
                    if [ "$API_LAST_HTTP_CODE" = 404 ]; then
                        record_arr_reconciliation_not_found \
                            "$download_id" "$app" "Movie file ID" "$file_id"
                        return 0
                    fi

                    ((DOWNLOAD_LEDGER_RECONCILIATION_FAILED_COUNT++)) || true
                    write_download_reconciliation_result \
                        "$download_id" "$app" false false \
                        "" "" "INFO" "" \
                        "Radarr movie-file API check failed" \
                        "Movie file ID: ${file_id}; endpoint: ${API_LAST_ENDPOINT}; ${API_LAST_ERROR}"
                    return 1
                fi

                if ! validate_arr_payload \
                    "$app" movie-file "$media_file" \
                    "${api_root%/}/moviefile/${file_id}"
                then
                    ((DOWNLOAD_LEDGER_RECONCILIATION_FAILED_COUNT++)) || true
                    write_download_reconciliation_result \
                        "$download_id" "$app" false false \
                        "" "" "INFO" "" \
                        "Radarr movie-file response validation failed" \
                        "Endpoint: ${API_LAST_ENDPOINT}; ${API_LAST_ERROR}"
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

        if [ "$(jq -r '.id // 0' "$media_file")" != "$file_id" ] ||
           [ "$file_parent_id" != "$parent_id" ] ||
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
            else
                .downloadLedger[$id].reconciliationLastAttemptAt = $now
                | .downloadLedger[$id].reconciliationLastScanOk = $result.scanOk
                | .downloadLedger[$id].reconciliationLastReason = ($result.evidence // "API evidence unavailable")
                | .downloadLedger[$id].reconciliationLastDetail = ($result.detail // "")
                |
                # API failures preserve candidates and never become proof of
                # recovery or a historical-only outcome.
                if ($result.scanOk // false) != true then .
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
        local original_classification
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
        original_classification=$(jq -r \
            --arg key "FLOW:DOWNLOAD:${download_id}" \
            '.issues[$key].classification // "DOWNLOAD_FLOW_UNKNOWN"' \
            "$STATE_FILE")
        issue_key="FLOW:RECONCILIATION:${download_id}"

        detail="Download ID: ${download_id}"$'\n'
        detail+="Release: ${release}"$'\n'
        detail+="Recovery method: ${kind}"$'\n'
        detail+="Evidence: ${evidence}"$'\n'
        [ -n "$reconciliation_detail" ] && \
            detail+="${reconciliation_detail}"$'\n'
        detail+="Original queue state: ${queue_status}"$'\n'
        detail+="Original classification: ${original_classification}"$'\n'
        detail+="Original warning: ${original_warning:-not captured}"$'\n'
        detail+="Original Ack ID: ${original_ack_id}"$'\n'
        detail+="Action taken: closed the monitor's exact download-flow issue automatically"$'\n'
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

queue_download_batch_dismissal_notifications() {

    local batches_file="${TMP_DIR}/download-batch-dismissals.jsonl"

    jq -c '
        .downloadDismissalBatches
        // {}
        | to_entries[]?
        | .value
        | select((.dismissedAt // 0) > 0)
        | select((.notifiedAt // 0) < (.dismissedAt // 0))
        ' "$STATE_FILE" >"$batches_file" || return 1

    while IFS= read -r record; do
        [ -n "$record" ] || continue

        local batch_id
        local count
        local source
        local classification
        local title_contains
        local older_hours
        local before
        local ack_file
        local reason
        local manifest
        local issue_key
        local signature
        local detail

        batch_id=$(jq -r '.batchId' <<<"$record")
        count=$(jq -r '.count // 0' <<<"$record")
        source=$(jq -r '.filters.source // ""' <<<"$record")
        classification=$(jq -r '.filters.classification // ""' <<<"$record")
        title_contains=$(jq -r '.filters.titleContains // ""' <<<"$record")
        older_hours=$(jq -r '.filters.olderThanHours // ""' <<<"$record")
        before=$(jq -r '.filters.before // ""' <<<"$record")
        ack_file=$(jq -r '.filters.ackFile // ""' <<<"$record")
        reason=$(jq -r '.reason // "No reason recorded"' <<<"$record")
        manifest=$(jq -r '.manifest // "not recorded"' <<<"$record")
        issue_key="FLOW:BATCH-DISMISS:${batch_id}"

        detail="Dismissed issues: ${count}"$'\n'
        detail+="Source filter: ${source:-any}"$'\n'
        detail+="Classification filter: ${classification:-explicit ACK list}"$'\n'
        [ -n "$title_contains" ] && detail+="Title contained: ${title_contains}"$'\n'
        [ -n "$older_hours" ] && detail+="Older than: ${older_hours} hour(s)"$'\n'
        [ -n "$before" ] && detail+="First seen before: ${before}"$'\n'
        [ -n "$ack_file" ] && detail+="ACK-ID selection file: ${ack_file}"$'\n'
        detail+="Reason: ${reason}"$'\n'
        detail+="Action taken: closed the selected monitor-state issues"$'\n'
        detail+="Arr/SAB/media changes: none"$'\n'
        detail+="Manifest: ${manifest}"

        signature=$(issue_signature \
            "Monitor" \
            "$issue_key" \
            "DOWNLOAD_FLOW_BATCH_DISMISSED" \
            "INFO" \
            "dismissed" \
            "${batch_id}|${count}|${reason}")

        queue_group_notification \
            "$issue_key" \
            "$signature" \
            "Monitor" \
            "${count} exact download-flow issue(s)" \
            "DOWNLOAD_FLOW_BATCH_DISMISSED" \
            "INFO" \
            "0" \
            "$detail" \
            "batch-dismissed"

        ((DOWNLOAD_LEDGER_BATCH_DISMISSAL_NOTIFICATION_COUNT++)) || true

    done <"$batches_file"
}

queue_download_manual_dismissal_notifications() {

    local records_file="${TMP_DIR}/download-manual-dismissals.jsonl"

    jq -c '
        .downloadLedger
        // {}
        | to_entries[]?
        | .value
        | select((.manuallyDismissedAt // 0) > 0)
        | select(
            (.manualDismissalNotifiedAt // 0)
            < (.manuallyDismissedAt // 0)
        )
        ' "$STATE_FILE" >"$records_file" || return 1

    while IFS= read -r record; do

        [ -n "$record" ] || continue

        local download_id
        local app
        local title
        local release
        local dismissed_at
        local reason
        local previous_classification
        local original_ack_id
        local issue_key
        local signature
        local detail

        download_id=$(jq -r '.id' <<<"$record")
        app=$(jq -r '.app // "Arr"' <<<"$record")
        title=$(jq -r '.title // .release // "Unknown download"' <<<"$record")
        release=$(jq -r '.release // "Unknown release"' <<<"$record")
        dismissed_at=$(jq -r '.manuallyDismissedAt // 0' <<<"$record")
        reason=$(jq -r '.manualDismissalReason // "No reason recorded"' <<<"$record")
        previous_classification=$(jq -r '.manualDismissalPreviousClassification // "DOWNLOAD_FLOW_UNKNOWN"' <<<"$record")
        original_ack_id=$(jq -r '.manualDismissalAckId // ""' <<<"$record")
        issue_key="FLOW:DOWNLOAD:${download_id}"
        [ -n "$original_ack_id" ] || original_ack_id=$(issue_ack_id "$issue_key")

        detail="Download ID: ${download_id}"$'\n'
        detail+="Release: ${release}"$'\n'
        detail+="Previous classification: ${previous_classification}"$'\n'
        detail+="Original Ack ID: ${original_ack_id}"$'\n'
        detail+="Reason: ${reason}"$'\n'
        detail+="Action taken: closed the monitor's exact download-flow issue"$'\n'
        detail+="Arr/SAB/media changes: none"

        signature=$(issue_signature \
            "$app" \
            "$issue_key" \
            "DOWNLOAD_FLOW_MANUALLY_DISMISSED" \
            "INFO" \
            "dismissed" \
            "${dismissed_at}|${reason}")

        queue_group_notification \
            "$issue_key" \
            "$signature" \
            "$app" \
            "$title" \
            "DOWNLOAD_FLOW_MANUALLY_DISMISSED" \
            "INFO" \
            "0" \
            "$detail" \
            "dismissed"

        ((DOWNLOAD_LEDGER_MANUAL_DISMISSAL_NOTIFICATION_COUNT++)) || true

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
        --argjson importMinutes "$DOWNLOAD_LEDGER_IMPORT_WARN_MINUTES" \
        --argjson vanishedMinutes "$DOWNLOAD_LEDGER_SAB_VANISHED_WARN_MINUTES" \
        --argjson notReachedMinutes "$DOWNLOAD_LEDGER_GRAB_TO_SAB_WARN_MINUTES" \
        --argjson retryMinutes "$DOWNLOAD_LEDGER_RECONCILE_RETRY_MINUTES" \
        --argjson maximum "$DOWNLOAD_LEDGER_RECONCILE_MAX_RECORDS" \
        '
        .issues as $issues
        |
        [
            .downloadLedger
            // {}
            | to_entries[]?
            | select((.value.flowEnrolled // false) == true)
            | select((.value.arrImportedAt // 0) <= 0)
            | select((.value.arrFailedAt // 0) <= 0)
            | select((.value.arrIgnoredAt // 0) <= 0)
            | select((.value.sabFailedAt // 0) <= 0)
            | select((.value.arrReconciledAt // 0) <= 0)
            | select((.value.manuallyDismissedAt // 0) <= 0)
            | select(
                (.value.reconciliationCandidateRuns // 0) > 0
                or (.value.reconciliationLastAttemptAt // 0) <= 0
                or .value.reconciliationLastScanOk == false
                or (.value.reconciliationLastCheckedAt // 0) <= 0
                or (($now - (.value.reconciliationLastCheckedAt // 0)) / 60) >= $retryMinutes
              )
            | (
                if (.value.sabCompletedAt // 0) > 0
                then (.value.sabCompletedAt // 0)
                elif (.value.sabQueueLastSeen // 0) > 0
                then (.value.sabQueueLastSeen // 0)
                else (.value.arrGrabbedAt // 0)
                end
              ) as $candidateEpoch
            | select(
                (
                    (.value.sabCompletedAt // 0) > 0
                    and (($now - (.value.sabCompletedAt // $now)) / 60) >= $importMinutes
                )
                or
                (
                    (.value.sabQueuedAt // 0) > 0
                    and (.value.sabCompletedAt // 0) <= 0
                    and (.value.sabFailedAt // 0) <= 0
                    and (.value.sabQueueLastSeen // 0) > 0
                    and (($now - (.value.sabQueueLastSeen // $now)) / 60) >= $vanishedMinutes
                )
                or
                (
                    (.value.arrGrabbedAt // 0) > 0
                    and (.value.sabQueuedAt // 0) <= 0
                    and (($now - (.value.arrGrabbedAt // $now)) / 60) >= $notReachedMinutes
                )
            )
            | {
                activeRank: (
                    if ($issues["FLOW:DOWNLOAD:" + .key].active // false)
                    then 0
                    else 1
                    end
                ),
                candidateEpoch: $candidateEpoch,
                record: .value
            }
        ]
        | sort_by(.activeRank, .candidateEpoch)
        | .[:$maximum]
        | .[].record
        ' "$STATE_FILE" >"$candidates_file" || return 1

    while IFS= read -r record; do

        [ -n "$record" ] || continue
        runtime_budget_allows_optional_phase "exact-history-batch" || return 1

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
            log "WARNING: ${app} exact history reconciliation failed for ${download_id}: endpoint=${API_LAST_ENDPOINT}; ${API_LAST_ERROR}"
            write_download_reconciliation_result \
                "$download_id" "$app" false false \
                "" "" "INFO" "" \
                "Exact history API check failed" \
                "Endpoint: ${API_LAST_ENDPOINT}; ${API_LAST_ERROR}"
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
        runtime_budget_allows_optional_phase "exact-file-batch" || return 1

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

download_ledger_arr_queue_contains() {
    local app="$1" download_id="$2" queue_file=""
    case "$app" in
        Sonarr) queue_file="$SONARR_QUEUE" ;;
        Radarr) queue_file="$RADARR_QUEUE" ;;
    esac
    [ -s "$queue_file" ] || return 1
    jq -e --arg id "${download_id,,}" '
        (if type == "array" then . else .records end)[]?
        | select((.downloadId // "" | ascii_downcase) == $id)
    ' "$queue_file" >/dev/null
}

# Historical ambiguity remains visible, but is distinct from a live failure.
# Successful Arr/SAB audits and complete queues are mandatory at the caller.
download_ledger_needs_review() {
    local record="$1" classification="$2" age_minutes="$3"
    case "$classification" in
        DOWNLOAD_FLOW_SAB_VANISHED|DOWNLOAD_FLOW_NOT_REACHED_SAB) ;;
        *) return 1 ;;
    esac
    (( age_minutes >= DOWNLOAD_LEDGER_HISTORICAL_REVIEW_MINUTES )) || return 1
    jq -e --argjson now "$START_TIME" \
        --argjson retry "$DOWNLOAD_LEDGER_RECONCILE_RETRY_MINUTES" '
        .reconciliationLastScanOk == true
        and (.reconciliationLastCheckedAt // 0) > 0
        and ($now - .reconciliationLastCheckedAt) <= (($retry + 10) * 60)
        and (.reconciliationCandidateRuns // 0) == 0
    ' <<<"$record" >/dev/null
}

process_download_ledger_issues() {

    local now
    local records_file="${TMP_DIR}/download-ledger-records.jsonl"

    now=$(date +%s)

    jq -c \
        '.downloadLedger // {} | to_entries[]? | .value
          | select(.flowEnrolled == true)
          | select(([.arrImportedAt,.arrFailedAt,.arrIgnoredAt,.arrReconciledAt,.manuallyDismissedAt,.sabFailedAt] | map(. // 0) | max) <= 0)' \
        "$STATE_FILE" >"$records_file" || return 1

    while IFS= read -r record; do

        [ -n "$record" ] || continue
        runtime_budget_allows_optional_phase "download-ledger-batch" || return 1

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
        local manually_dismissed_at
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
        manually_dismissed_at=$(jq -r '.manuallyDismissedAt // 0' <<<"$record")
        reconciliation_candidate_runs=$(jq -r '.reconciliationCandidateRuns // 0' <<<"$record")

        if (( arr_imported_at > 0 ||
              arr_failed_at > 0 ||
              arr_ignored_at > 0 ||
              arr_reconciled_at > 0 ||
              manually_dismissed_at > 0 ||
              sab_failed_at > 0 )); then
            continue
        fi

        if grep -Fxiq -- "${app}:${download_id}" "$SEEN_ISSUES_FILE" 2>/dev/null; then
            current_arr_issue=true
        fi

        if [ "$current_arr_issue" = true ] ||
           download_ledger_arr_queue_contains "$app" "$download_id" ||
           sab_primary_download_exists "$download_id"; then
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
            debug_log "Automatic reconciliation pending ${reconciliation_candidate_runs}/${DOWNLOAD_LEDGER_RECONCILE_CONFIRM_RUNS}: ${app} ${download_id}"
            continue
        fi

        if (( age_minutes >= DOWNLOAD_LEDGER_ESCALATE_MINUTES )); then
            severity="ERROR"
            stage="escalated"
        fi

        if download_ledger_needs_review "$record" "$classification" "$age_minutes"; then
            classification="DOWNLOAD_FLOW_REVIEW_REQUIRED"
            severity="WARNING"
            stage="review"
            message="Historical download outcome is unverified; absent from current Arr/SAB queues and available SAB history. Import or cancellation is not confirmed"
        fi

        detail="Download ID: ${download_id}"$'\n'
        detail+="Release: ${release}"$'\n'
        detail+="Exact flow age: ${age_minutes} minute(s)"$'\n'
        detail+="Last Arr queue status: $(jq -r '.arrQueueStatus // "not observed"' <<<"$record")"$'\n'
        detail+="Last SAB status: $(jq -r '.sabStatus // "not observed"' <<<"$record")"

        detail+=$'\n'"Reconciliation: $(jq -r '.reconciliationLastReason // "Not yet checked"' <<<"$record")"
        detail+=$'\n'"Evidence: $(jq -r '.reconciliationLastDetail // ""' <<<"$record")"

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
    : >"${TMP_DIR}/arr-ledger-cursors.jsonl"

    if ! prepare_download_ledger_enrollment_cache; then
        log "ERROR: Unable to prepare exact download workflow enrollment cache"
        return 1
    fi

    if [ "$SONARR_AUDIT_OK" = true ]; then
        collect_arr_download_ledger \
            "Sonarr" \
            "${SONARR_LEDGER_HISTORY:-$SONARR_AUDIT_HISTORY}" \
            "$SONARR_QUEUE"
    fi

    if [ "$RADARR_AUDIT_OK" = true ]; then
        collect_arr_download_ledger \
            "Radarr" \
            "${RADARR_LEDGER_HISTORY:-$RADARR_AUDIT_HISTORY}" \
            "$RADARR_QUEUE"
    fi

    SAB_LEDGER_NEW_SIGNATURE=""
    collect_sab_download_ledger || return 1

    if ! update_download_ledger_state; then
        log "ERROR: Unable to update exact download workflow ledger"
        return 1
    fi

    if [ -s "${TMP_DIR}/arr-ledger-cursors.jsonl" ]; then
        local arr_cursor_tmp="${TMP_DIR}/state.arr-ledger-cursors.json"
        jq --slurpfile cursors "${TMP_DIR}/arr-ledger-cursors.jsonl" \
          'reduce $cursors[] as $c (.; .monitor.arrLedgerHistory[$c.app]=$c)' "$STATE_FILE" >"$arr_cursor_tmp" && save_state "$arr_cursor_tmp" || return 1
    fi
    if [ -n "$SAB_LEDGER_NEW_SIGNATURE" ]; then
        local cursor_tmp="${TMP_DIR}/state.sab-ledger-cursor.json"
        jq --arg signature "$SAB_LEDGER_NEW_SIGNATURE" --argjson now "$START_TIME" \
          '.monitor.sabLedgerCacheSignature=$signature | .monitor.sabLedgerLastReplayAt=$now' \
          "$STATE_FILE" >"$cursor_tmp" && save_state "$cursor_tmp" || return 1
    fi

    if ! perform_download_ledger_reconciliation; then
        log "ERROR: Unable to complete automatic download reconciliation"
        return 1
    fi

    if ! queue_download_batch_dismissal_notifications; then
        log "ERROR: Unable to queue batch download-dismissal notifications"
        return 1
    fi

    if ! queue_download_manual_dismissal_notifications; then
        log "ERROR: Unable to queue manual download-dismissal notifications"
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

prepare_sab_history_index() {
    local output="${TMP_DIR}/sab-normalized-history.json" fallback="${TMP_DIR}/sab-date-fallback.jsonl" row ordinal raw epoch
    [[ -s "$output" ]] && return 0
    : >"$fallback"
    jq '[.history.slots[]? | . + {auditEpoch:((.completed // .completed_time // .completedTime // .completionTime // .time_completed // "") | tonumber? // 0)}]' \
        "$SAB_HISTORY" >"$output" || return 1
    while IFS= read -r row; do
        ordinal=$(jq -r '.key' <<<"$row")
        raw=$(jq -r '.value | .completed // .completed_time // .completedTime // .completionTime // .time_completed // ""' <<<"$row")
        epoch=$(date_to_epoch "$raw")
        jq -nc --argjson ordinal "$ordinal" --argjson epoch "$epoch" '{ordinal:$ordinal,epoch:$epoch}' >>"$fallback" || return 1
    done < <(jq -c 'to_entries[] | select(.value.auditEpoch<=0)' "$output")
    if [[ -s "$fallback" ]]; then
        jq --slurpfile changes "$fallback" 'reduce $changes[] as $c (.; .[$c.ordinal].auditEpoch=$c.epoch)' "$output" >"${output}.merged" && mv -f -- "${output}.merged" "$output" || return 1
    fi
}

process_sab_activity_audit() {
    SAB_AUDIT_OK=false
    [[ "$SAB_SCAN_OK" == true && -f "$SAB_HISTORY" ]] || return 1
    prepare_sab_history_index || return 1
    local counts loaded total oldest
    counts=$(jq -r --arg movie "${SAB_MOVIE_CATEGORY,,}" --arg tv "${SAB_TV_CATEGORY,,}" --arg ignored "${SAB_IGNORED_CATEGORY,,}" --argjson cutoff "$AUDIT_CUTOFF_EPOCH" '
      . as $all | map(select(.auditEpoch >= $cutoff)) as $recent
      | [($all|length), ([$all[].auditEpoch|select(.>0)]|min // 0),
          ([$recent[]|select((.category // .cat // "" | ascii_downcase)==$ignored)]|length),
          ([$recent[]|select((.category // .cat // "" | ascii_downcase)==$movie and (.status // "" | ascii_downcase)=="completed")]|length),
          ([$recent[]|select((.category // .cat // "" | ascii_downcase)==$movie and (.status // "" | ascii_downcase)=="failed")]|length),
          ([$recent[]|select((.category // .cat // "" | ascii_downcase)==$tv and (.status // "" | ascii_downcase)=="completed")]|length),
          ([$recent[]|select((.category // .cat // "" | ascii_downcase)==$tv and (.status // "" | ascii_downcase)=="failed")]|length)] | @tsv
    ' "${TMP_DIR}/sab-normalized-history.json") || return 1
    IFS=$'\t' read -r loaded oldest SAB_AUDIT_F1_IGNORED SAB_AUDIT_MOVIE_COMPLETED SAB_AUDIT_MOVIE_FAILED SAB_AUDIT_TV_COMPLETED SAB_AUDIT_TV_FAILED <<<"$counts"
    total=$(jq '.history.noofslots // (.history.slots|length)' "$SAB_HISTORY")
    SAB_AUDIT_WINDOW_INCOMPLETE=false
    if ((loaded<total && oldest>AUDIT_CUTOFF_EPOCH)); then SAB_AUDIT_WINDOW_INCOMPLETE=true; fi
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

    PIPELINE_LIVE_ERROR_COUNT=$((ERROR_COUNT - EVENT_ONLY_ERROR_COUNT))
    (( PIPELINE_LIVE_ERROR_COUNT >= 0 )) || PIPELINE_LIVE_ERROR_COUNT=0

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

    if (( PIPELINE_LIVE_ERROR_COUNT > 0 )); then

        PIPELINE_STATUS="DEGRADED"
        PIPELINE_REASON="${PIPELINE_LIVE_ERROR_COUNT} active live error-level issue(s) detected"

        return
    fi

    ###########################################################################
    # ACTIVE WARNING
    ###########################################################################

    if (( WARNING_COUNT > 0 )); then

        PIPELINE_STATUS="ATTENTION"
        PIPELINE_REASON="${WARNING_COUNT} warning-level issue/event(s) detected"

        if (( EVENT_ONLY_ERROR_COUNT > 0 )); then
            PIPELINE_REASON+="; ${EVENT_ONLY_ERROR_COUNT} recent error event(s) retained for review"
        fi

        return
    fi

    ###########################################################################
    # RECENT ERROR EVENTS WITHOUT A CURRENT LIVE FAILURE
    ###########################################################################

    if (( EVENT_ONLY_ERROR_COUNT > 0 )); then

        PIPELINE_STATUS="ATTENTION"
        PIPELINE_REASON="${EVENT_ONLY_ERROR_COUNT} recent error event(s) retained for review; no current live error detected"

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
# SUMMARY AND PERSISTENT AUDIT POLICY - v3.9
###############################################################################

determine_detailed_summary_policy() {

    local now
    local last_detailed
    local heartbeat_seconds=$((HEALTH_HEARTBEAT_HOURS * 3600))

    now=$(date +%s)
    last_detailed=$(jq -r \
        '.monitor.lastDetailedSummaryAt // 0' \
        "$STATE_FILE")
    [[ "$last_detailed" =~ ^[0-9]+$ ]] || last_detailed=0

    ACTIVE_ISSUE_COUNT=$(jq \
        '[.issues[]? | select((.active // false) == true)] | length' \
        "$STATE_FILE" 2>/dev/null || echo 0)
    [[ "$ACTIVE_ISSUE_COUNT" =~ ^[0-9]+$ ]] || ACTIVE_ISSUE_COUNT=0

    DETAILED_SUMMARY_DUE=false
    DETAILED_SUMMARY_REASON="unchanged"

    if [ "${LOG_LEVEL^^}" = "DEBUG" ]; then
        DETAILED_SUMMARY_DUE=true
        DETAILED_SUMMARY_REASON="debug logging enabled"
    elif [ "$PREVIOUS_RUN_STATUS" = "unknown" ] ||
       [ "$PREVIOUS_RUN_STATUS" != "$PIPELINE_STATUS" ]; then
        DETAILED_SUMMARY_DUE=true
        DETAILED_SUMMARY_REASON="pipeline status changed"
    elif (( BATCHED_NOTIFICATION_ITEMS > 0 || RESOLVED_COUNT > 0 ||
            DOWNLOAD_LEDGER_RECONCILED_COUNT > 0 ||
            DOWNLOAD_LEDGER_MANUAL_DISMISSAL_NOTIFICATION_COUNT > 0 ||
            DOWNLOAD_LEDGER_BATCH_DISMISSAL_NOTIFICATION_COUNT > 0 )); then
        DETAILED_SUMMARY_DUE=true
        DETAILED_SUMMARY_REASON="lifecycle activity"
    elif (( last_detailed <= 0 ||
            now - last_detailed >= heartbeat_seconds )); then
        DETAILED_SUMMARY_DUE=true
        DETAILED_SUMMARY_REASON="${HEALTH_HEARTBEAT_HOURS}-hour heartbeat"
    fi
}

record_detailed_summary_emitted() {

    local tmp="${TMP_DIR}/state.summary-emitted.json"
    local now

    now=$(date +%s)

    jq \
        --argjson now "$now" \
        '.monitor.lastDetailedSummaryAt = $now' \
        "$STATE_FILE" >"$tmp" || return 1

    save_state "$tmp"
}

write_compact_console_summary() {

    local runtime_value="$1"

    log "${PIPELINE_STATUS} | Sonarr=$SONARR_API_OK | Radarr=$RADARR_API_OK | SAB=$SAB_API_OK | active=${ACTIVE_ISSUE_COUNT} | runtime=${runtime_value}"
}

write_persistent_activity_summary() {

    persistent_log \
        "HEARTBEAT" \
        "reason=${DETAILED_SUMMARY_REASON} | status=${PIPELINE_STATUS} | active=${ACTIVE_ISSUE_COUNT} | runtime=$(runtime)"

    persistent_log \
        "API" \
        "Sonarr=${SONARR_API_OK} | Radarr=${RADARR_API_OK} | SABnzbd=${SAB_API_OK}"

    if [ "$ACTIVITY_AUDIT_ENABLED" = true ]; then

        persistent_log \
            "AUDIT" \
            "lookback=${ACTIVITY_AUDIT_LOOKBACK_HOURS}h | SAB movie_completed=${SAB_AUDIT_MOVIE_COMPLETED} tv_completed=${SAB_AUDIT_TV_COMPLETED} failed=$((SAB_AUDIT_MOVIE_FAILED + SAB_AUDIT_TV_FAILED)) | Sonarr imports=${SONARR_AUDIT_IMPORTED} failed=${SONARR_AUDIT_DOWNLOAD_FAILED} recovered=${SONARR_AUDIT_DOWNLOAD_FAILED_RECOVERED} | Radarr imports=${RADARR_AUDIT_IMPORTED} failed=${RADARR_AUDIT_DOWNLOAD_FAILED} recovered=${RADARR_AUDIT_DOWNLOAD_FAILED_RECOVERED}"
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
    [[ -f "$SAB_HISTORY" ]] || return 1
    prepare_sab_history_index || return 1
    local counts
    counts=$(jq -r --arg tv "${SAB_TV_CATEGORY,,}" --arg movie "${SAB_MOVIE_CATEGORY,,}" \
      --arg ignored "${SAB_IGNORED_CATEGORY,,}" --argjson cutoff "$FLOW_CUTOFF_EPOCH" '
        [.[] | select((.status // "" | ascii_downcase)=="completed" and .auditEpoch>0 and .auditEpoch >= $cutoff)
         | (.category // .cat // "" | ascii_downcase) | select(.!=$ignored)] as $categories
        | [([$categories[]|select(.==$tv)]|length),([$categories[]|select(.==$movie)]|length)] | @tsv
      ' "${TMP_DIR}/sab-normalized-history.json") || return 1
    IFS=$'\t' read -r FLOW_SAB_TV_COMPLETED FLOW_SAB_MOVIE_COMPLETED <<<"$counts"
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

    debug_log ""
    debug_log "Activity flow anomaly detected"
    debug_log "Application: $app"
    debug_log "Media type: $kind"
    debug_log "Flow window: ${FLOW_ANOMALY_LOOKBACK_HOURS}h"
    debug_log "SAB completed jobs: $sab_completed"
    debug_log "Arr successful imports: $arr_imports"
    debug_log "Stage: $stage"

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

        debug_log "Notification suppressed: activity-flow issue already reported"
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

                debug_log "Sonarr flow anomaly candidate suppressed"
                debug_log "Reason: ${FLOW_SONARR_EXPLANATIONS} active Sonarr/SAB issue(s) already tracked"
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

                debug_log "Radarr flow anomaly candidate suppressed"
                debug_log "Reason: ${FLOW_RADARR_EXPLANATIONS} active Radarr/SAB issue(s) already tracked"
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
                    (.value.manuallyDismissedAt // 0) >= $ledgerCutoff
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

        .downloadDismissalBatches = (
            (.downloadDismissalBatches // {})
            | with_entries(
                select((.value.dismissedAt // 0) >= $issueCutoff)
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

    if [ -d "$BATCH_DISMISS_MANIFEST_DIR" ]; then
        find "$BATCH_DISMISS_MANIFEST_DIR" \
            -maxdepth 1 \
            -type f \
            -name 'batch-dismiss-*.json' \
            -mtime "+${BATCH_DISMISS_AUDIT_RETENTION_DAYS}" \
            -delete 2>/dev/null || true
    fi

    if [ -d "$BATCH_DISMISS_PREVIEW_DIR" ]; then
        find "$BATCH_DISMISS_PREVIEW_DIR" \
            -maxdepth 1 \
            -type f \
            -name 'batch-preview-*' \
            -mtime "+${BATCH_DISMISS_AUDIT_RETENTION_DAYS}" \
            -delete 2>/dev/null || true
    fi

    find "$STATE_DIR" \
        -maxdepth 1 \
        -type f \
        -name 'state.json.pre-batch-dismiss.*.bak' \
        -mtime "+${BATCH_DISMISS_AUDIT_RETENTION_DAYS}" \
        -delete 2>/dev/null || true
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
MONITOR_PHASE_TIMINGS_FILE="${TMP_DIR}/phase_timings.jsonl"

: >"$NOTIFICATION_BATCH"
: >"$SEEN_ISSUES_FILE"
: >"$SAB_PRIMARY_DOWNLOADS_FILE"
: >"$SAB_PROGRESS_SEEN_FILE"
: >"$SAB_PROGRESS_OBSERVATIONS_FILE"
: >"$DOWNLOAD_LEDGER_OBSERVATIONS_FILE"
: >"$DOWNLOAD_LEDGER_ENROLLED_IDS_FILE"
: >"$DOWNLOAD_LEDGER_RECONCILIATION_RESULTS_FILE"
: >"$MONITOR_PHASE_TIMINGS_FILE"

###############################################################################
# STATE
###############################################################################

ensure_state_storage_ready

initialize_state

if ! begin_state_transaction; then
    log "ERROR: Unable to begin monitor state transaction"
    exit 3
fi

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
        commit_state_transaction "acknowledgement" || exit 3
        exit 0
        ;;

    --unack)
        if [ -z "${2:-}" ]; then
            print_lifecycle_command_help
            exit 2
        fi

        unacknowledge_active_issue "$2" || exit 2
        commit_state_transaction "unacknowledgement" || exit 3
        exit 0
        ;;

    --dismiss-download)
        if [ -z "${2:-}" ]; then
            print_lifecycle_command_help
            exit 2
        fi

        dismiss_download_flow_issue "$2" "${*:3}" || exit 2
        commit_state_transaction "manual-dismissal" || exit 3
        exit 0
        ;;

    --batch-dismiss-downloads)
        batch_dismiss_downloads "${@:2}"
        command_rc=$?
        if (( command_rc == 0 )); then
            commit_state_transaction "batch-dismissal" || exit 3
        fi
        exit "$command_rc"
        ;;

    --help|--lifecycle-help)
        print_lifecycle_command_help
        exit 0
        ;;
esac

start_monitor_phase "startup"

if ! begin_monitor_run; then
    log "ERROR: Unable to update monitor run-start heartbeat"
    persistent_log "ERROR" "Unable to update monitor run-start heartbeat"
    exit 3
fi

MONITOR_RUN_ACTIVE=true
commit_state_transaction "run-start" || exit 3
end_monitor_phase "startup"

###############################################################################
# v2.5 PERSISTENT LOG / ACTIVITY AUDIT INITIALIZATION
###############################################################################

rotate_persistent_log
prune_persistent_logs_by_age

persistent_log \
    "DEBUG" \
    "START | ARR Health Monitor v3.11.0"

if [ "$ACTIVITY_AUDIT_ENABLED" = true ]; then

    initialize_activity_audit_window

    debug_log "Activity audit window: last ${ACTIVITY_AUDIT_LOOKBACK_HOURS}h"
fi

###############################################################################
# START
###############################################################################

debug_log "Starting ARR Health Monitor v3.11.0"
debug_log "Recommended schedule: every five minutes"
debug_log "Notifications enabled: $SEND_NOTIFICATIONS"
debug_log "Grouped notification maximum items: $GROUP_NOTIFICATION_MAX_ITEMS"

preflight_notification_command
record_monitor_schedule_issue
record_monitor_notification_issue

start_monitor_phase "service-collection"

###############################################################################
# SABNZBD
###############################################################################

if [ "$SAB_ENABLED" = true ]; then

    debug_log "Connecting to SABnzbd"

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

        debug_log "SABnzbd history records loaded: $SAB_COUNT"

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
        debug_log "SABnzbd queue entries: $(jq '.queue.slots // [] | length' "$SAB_QUEUE")"

    else

        SAB_QUEUE_OK=false
        SAB_QUEUE=""
        SAB_API_FAILURES=$(append_api_failure \
            "$SAB_API_FAILURES" \
            "queue" \
            "$API_LAST_ERROR")
    fi

    if sab_get warnings "$SAB_WARNINGS" &&
       validate_sab_payload warnings "$SAB_WARNINGS" "${SAB_URL%/}/api"
    then

        SAB_WARNINGS_OK=true

    else

        SAB_WARNINGS_OK=false
        SAB_WARNINGS=""
        SAB_API_FAILURES=$(append_api_failure \
            "$SAB_API_FAILURES" \
            "warnings" \
            "$API_LAST_ERROR")
    fi

    if sab_get status "$SAB_STATUS" &&
       validate_sab_payload status "$SAB_STATUS" "${SAB_URL%/}/api"
    then

        SAB_STATUS_OK=true

    else

        SAB_STATUS_OK=false
        SAB_STATUS=""
        SAB_API_FAILURES=$(append_api_failure \
            "$SAB_API_FAILURES" \
            "status" \
            "$API_LAST_ERROR")
    fi

    if sab_get server_stats "$SAB_SERVER_STATS" &&
       validate_sab_payload server_stats "$SAB_SERVER_STATS" "${SAB_URL%/}/api"
    then

        SAB_SERVER_STATS_OK=true

    else

        SAB_SERVER_STATS_OK=false
        SAB_SERVER_STATS=""
        debug_log "Unable to retrieve optional SABnzbd provider statistics: ${API_LAST_ERROR}"
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

    debug_log "Checking Sonarr health and queue"

    if ! discover_arr_api \
        "Sonarr" \
        "$SONARR_URL" \
        "$SONARR_API_KEY"
    then
        SONARR_API_FAILURES=$(append_api_failure \
            "$SONARR_API_FAILURES" \
            "api-discovery" \
            "$API_LAST_ERROR")
        debug_log "Sonarr API discovery failed; using compatibility fallback ${SONARR_API_ROOT}"
    fi

    SONARR_QUEUE="$TMP_DIR/sonarr_queue.json"
    SONARR_HEALTH="$TMP_DIR/sonarr_health.json"
    SONARR_SYSTEM_STATUS="$TMP_DIR/sonarr_system_status.json"

    if fetch_arr_queue \
        "Sonarr" \
        "$SONARR_API_ROOT" \
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

        debug_log "Sonarr queue entries: $SONARR_COUNT"

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
        "${SONARR_API_ROOT%/}/health" \
        "$SONARR_API_KEY" \
        "$SONARR_HEALTH" &&
       validate_arr_payload \
        "Sonarr" health "$SONARR_HEALTH" "${SONARR_API_ROOT%/}/health"
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
        "${SONARR_API_ROOT%/}/system/status" \
        "$SONARR_API_KEY" \
        "$SONARR_SYSTEM_STATUS" &&
       validate_arr_payload \
        "Sonarr" system-status "$SONARR_SYSTEM_STATUS" \
        "${SONARR_API_ROOT%/}/system/status"
    then
        SONARR_STATUS_OK=true
        debug_log "Connected to Sonarr $(jq -r '.version // "unknown"' "$SONARR_SYSTEM_STATUS")"
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

    debug_log "Checking Radarr health and queue"

    if ! discover_arr_api \
        "Radarr" \
        "$RADARR_URL" \
        "$RADARR_API_KEY"
    then
        RADARR_API_FAILURES=$(append_api_failure \
            "$RADARR_API_FAILURES" \
            "api-discovery" \
            "$API_LAST_ERROR")
        debug_log "Radarr API discovery failed; using compatibility fallback ${RADARR_API_ROOT}"
    fi

    RADARR_QUEUE="$TMP_DIR/radarr_queue.json"
    RADARR_HEALTH="$TMP_DIR/radarr_health.json"
    RADARR_SYSTEM_STATUS="$TMP_DIR/radarr_system_status.json"

    if fetch_arr_queue \
        "Radarr" \
        "$RADARR_API_ROOT" \
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

        debug_log "Radarr queue entries: $RADARR_COUNT"

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
        "${RADARR_API_ROOT%/}/health" \
        "$RADARR_API_KEY" \
        "$RADARR_HEALTH" &&
       validate_arr_payload \
        "Radarr" health "$RADARR_HEALTH" "${RADARR_API_ROOT%/}/health"
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
        "${RADARR_API_ROOT%/}/system/status" \
        "$RADARR_API_KEY" \
        "$RADARR_SYSTEM_STATUS" &&
       validate_arr_payload \
        "Radarr" system-status "$RADARR_SYSTEM_STATUS" \
        "${RADARR_API_ROOT%/}/system/status"
    then
        RADARR_STATUS_OK=true
        debug_log "Connected to Radarr $(jq -r '.version // "unknown"' "$RADARR_SYSTEM_STATUS")"
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

prepare_arr_download_indexes || log "WARNING: Exact download index unavailable; direct queue lookups retained"
end_monitor_phase "service-collection"

###############################################################################
# UNIFIED HEALTH / QUEUE PROCESSING
###############################################################################

start_monitor_phase "issue-evaluation"

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

end_monitor_phase "issue-evaluation"

###############################################################################
# RECENT ACTIVITY AUDIT - v2.5
###############################################################################

if [ "$ACTIVITY_AUDIT_ENABLED" = true ] &&
   runtime_budget_allows_optional_phase "activity-audit"
then

    start_monitor_phase "activity-audit"

    debug_log "Running recent operational activity audit"

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
            "$SONARR_API_ROOT" \
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

            log "WARNING: Unable to retrieve recent Sonarr history: endpoint=${API_LAST_ENDPOINT}; ${API_LAST_ERROR}"

            persistent_log \
                "ERROR" \
                "Unable to retrieve recent Sonarr history: endpoint=${API_LAST_ENDPOINT}; ${API_LAST_ERROR}"
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
            "$RADARR_API_ROOT" \
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

            log "WARNING: Unable to retrieve recent Radarr history: endpoint=${API_LAST_ENDPOINT}; ${API_LAST_ERROR}"

            persistent_log \
                "ERROR" \
                "Unable to retrieve recent Radarr history: endpoint=${API_LAST_ENDPOINT}; ${API_LAST_ERROR}"
        fi
    fi

    end_monitor_phase "activity-audit"
fi

if runtime_budget_allows_optional_phase "download-ledger-reconciliation"; then
    start_monitor_phase "download-ledger-reconciliation"
    process_exact_download_ledger || true
    end_monitor_phase "download-ledger-reconciliation"
else
    DOWNLOAD_LEDGER_SCAN_OK=false
fi

###############################################################################
# SAB CROSS-APP CHECK
###############################################################################

if sab_filesystem_scan_due; then
  if runtime_budget_allows_optional_phase "sab-filesystem-scan"; then
    start_monitor_phase "sab-filesystem-scan"
    prepare_sab_filesystem_scan || true
    if ! process_sab_orphans; then SAB_FILESYSTEM_SCAN_OK=false; fi
    if [ "$SAB_FILESYSTEM_SCAN_OK" = true ] && [ "$SAB_HISTORY_OK" = true ] &&
       [ "$SONARR_QUEUE_OK" = true ] && [ "$RADARR_QUEUE_OK" = true ]; then
        fs_cursor_tmp="${TMP_DIR}/state.filesystem-cursor.json"
        jq --argjson now "$START_TIME" '.monitor.sabFilesystemLastSuccessfulAt=$now' "$STATE_FILE" >"$fs_cursor_tmp" && save_state "$fs_cursor_tmp"
    fi
    end_monitor_phase "sab-filesystem-scan"
  else
    SAB_FILESYSTEM_SCAN_OK=false
    SAB_FILESYSTEM_SCAN_DEFERRED=true
    SAB_FILESYSTEM_SCAN_REASON="Runtime budget deferred filesystem scan"
  fi
else
    SAB_FILESYSTEM_SCAN_OK=false
    SAB_FILESYSTEM_SCAN_DEFERRED=true
    SAB_FILESYSTEM_SCAN_REASON="Scheduled hourly filesystem audit not due; prior issues preserved"
fi

start_monitor_phase "state-maintenance"
carry_deferred_filesystem_issue_counts || log "WARNING: Could not summarize preserved filesystem issues"
prune_sab_progress_state
end_monitor_phase "state-maintenance"

###############################################################################
# ACTIVITY FLOW ANOMALY - v2.6
###############################################################################

start_monitor_phase "activity-flow"
assess_activity_flow
end_monitor_phase "activity-flow"

start_monitor_phase "monitor-self-health"
# Core service endpoint failures are already represented by the per-service
# API lifecycle issues. This adds repeated incomplete-run, secondary history,
# and internal flow-analysis failures without duplicating those API alerts.
record_monitor_scan_issue
end_monitor_phase "monitor-self-health"

###############################################################################
# RESOLUTION CHECK
#
# Done only after all current issues have been marked seen.
###############################################################################

start_monitor_phase "lifecycle-resolution"
resolve_missing_issues
end_monitor_phase "lifecycle-resolution"

###############################################################################
# SEND ONE GROUPED NOTIFICATION
###############################################################################

NOTIFICATION_ATTEMPTED=false
NOTIFICATION_LAST_ERROR=""

# Persist the complete observation/lifecycle transaction before sending. If a
# notification command blocks or the process is interrupted, the underlying
# issue state remains durable and no unavailable collector can resolve issues.
start_monitor_phase "pre-notification-checkpoint"
commit_state_transaction "pre-notification" || exit 3
end_monitor_phase "pre-notification-checkpoint"

start_monitor_phase "notifications"

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

end_monitor_phase "notifications"
start_monitor_phase "post-notification-checkpoint"
commit_state_transaction "post-notification" || exit 3
end_monitor_phase "post-notification-checkpoint"

start_monitor_phase "finalization"

###############################################################################
# PRUNE OLD RESOLVED STATE
###############################################################################

prune_state

###############################################################################
# PIPELINE HEALTH - v2.5
###############################################################################

assess_pipeline_health

determine_detailed_summary_policy

if [ "$DETAILED_SUMMARY_DUE" = true ]; then
    write_persistent_activity_summary
    record_detailed_summary_emitted || exit 3
fi

###############################################################################
# SUMMARY
###############################################################################

RUNTIME=$(runtime)

if [ "$DETAILED_SUMMARY_DUE" = true ]; then

log "============================================================"
log "ARR Health Monitor v3.11.0 completed"
log "Detailed summary reason: $DETAILED_SUMMARY_REASON"

log ""
log "SCAN HEALTH"
log "Sonarr API healthy: $SONARR_API_OK"
log "  API: ${SONARR_API_VERSION:-undetected} | Queue: $SONARR_QUEUE_OK | Health: $SONARR_HEALTH_OK | Status: $SONARR_STATUS_OK"
log "Radarr API healthy: $RADARR_API_OK"
log "  API: ${RADARR_API_VERSION:-undetected} | Queue: $RADARR_QUEUE_OK | Health: $RADARR_HEALTH_OK | Status: $RADARR_STATUS_OK"
log "SABnzbd API healthy: $SAB_API_OK"
log "  History: $SAB_HISTORY_OK | Queue: $SAB_QUEUE_OK | Warnings: $SAB_WARNINGS_OK | Status: $SAB_STATUS_OK"
log "Circuit breakers: Sonarr=$SONARR_CIRCUIT_OPEN | Radarr=$RADARR_CIRCUIT_OPEN | SABnzbd=$SAB_CIRCUIT_OPEN"

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
log "SAB warning event window: ${SAB_WARNING_ACTIVE_HOURS}h"
log "SAB history cache reused: $SAB_HISTORY_CACHE_HIT"

log ""
log "MONITOR SELF-HEALTH"
log "Missed-schedule issues: $MONITOR_SCHEDULE_MISSED_COUNT"
log "Repeated/incomplete scan issues: $MONITOR_SCAN_FAILURE_COUNT"
log "Notification-command issues: $MONITOR_NOTIFICATION_FAILURE_COUNT"
log "Previous start gap: ${PREVIOUS_RUN_GAP_MINUTES}m"
log "Previous run incomplete: $PREVIOUS_RUN_INCOMPLETE"
log "Previous run status: ${PREVIOUS_RUN_STATUS} | exit=${PREVIOUS_RUN_EXIT_CODE} | phase=${PREVIOUS_RUN_PHASE}"
log "Runtime budget deferred work: $MONITOR_RUNTIME_DEFERRED"
[ -n "$MONITOR_RUNTIME_DEFERRED_PHASES" ] && \
    log "Deferred phases: $MONITOR_RUNTIME_DEFERRED_PHASES"

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
    log "Unreconciled download-failed events: $SONARR_AUDIT_DOWNLOAD_FAILED"
    log "Download failures reconciled by later terminal events: $SONARR_AUDIT_DOWNLOAD_FAILED_RECOVERED"

    log ""
    log "Radarr"
    log "Successful import events: $RADARR_AUDIT_IMPORTED"
    log "Unreconciled download-failed events: $RADARR_AUDIT_DOWNLOAD_FAILED"
    log "Download failures reconciled by later terminal events: $RADARR_AUDIT_DOWNLOAD_FAILED_RECOVERED"

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
log "Historical failure events reconciled this run: $ARR_HISTORY_FAILURE_RECOVERED_COUNT"
log "Manual dismissal notices queued: $DOWNLOAD_LEDGER_MANUAL_DISMISSAL_NOTIFICATION_COUNT"
log "Batch dismissal summaries queued: $DOWNLOAD_LEDGER_BATCH_DISMISSAL_NOTIFICATION_COUNT"

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
log "  Live errors affecting pipeline health: $PIPELINE_LIVE_ERROR_COUNT"
log "  Recent event-only errors retained for review: $EVENT_ONLY_ERROR_COUNT"

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
log "Phase timings: $(jq -sr 'map(.phase + "=" + (.seconds | tostring) + "s") | join(", ")' "$MONITOR_PHASE_TIMINGS_FILE")"
log "Runtime: $RUNTIME"
log "============================================================"

persistent_log \
    "SUMMARY" \
    "reason=${DETAILED_SUMMARY_REASON} | runtime=${RUNTIME} | active_issues=${TOTAL_ISSUES} | info=${INFO_COUNT} | warnings=${WARNING_COUNT} | errors=${ERROR_COUNT} | live_errors=${PIPELINE_LIVE_ERROR_COUNT} | event_only_errors=${EVENT_ONLY_ERROR_COUNT} | history_failures_reconciled=${ARR_HISTORY_FAILURE_RECOVERED_COUNT} | reminders=${REMINDER_NOTIFICATION_COUNT} | event_repeats_suppressed=${EVENT_REPEAT_SUPPRESSED_COUNT} | event_expiry_suppressed=${EVENT_RESOLUTION_SUPPRESSED_COUNT} | bounded_limits_reached=${BOUNDED_REMINDER_SUPPRESSED_COUNT} | flapping=${FLAPPING_NOTIFICATION_COUNT} | acknowledged_suppressed=${ACKNOWLEDGED_SUPPRESSED_COUNT}"

else

    write_compact_console_summary "$RUNTIME"
fi

end_monitor_phase "finalization"

if ! complete_monitor_run "$PIPELINE_STATUS" 0 ""; then
    log "ERROR: Unable to update monitor completion heartbeat"
    persistent_log "ERROR" "Unable to update monitor completion heartbeat"
    exit 3
fi

commit_state_transaction "run-complete" || exit 3
MONITOR_RUN_FINALIZED=true
MONITOR_RUN_ACTIVE=false

exit 0
