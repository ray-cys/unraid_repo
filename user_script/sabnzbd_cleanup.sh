#!/bin/bash

###############################################################################
# SABnzbd Cleanup v2.5.0
#
# PURPOSE / PERSONAL USE CASE
# ---------------------------
# Reclaim SABnzbd backup and completed-download storage in one scheduled script,
# while protecting required media and leaving the native SAB/Arr history intact.
# The GitHub filename is sabnzbd_cleanup.sh; the personal Unraid User Scripts
# entry is arr_sabnzbd_cleanup. Both names refer to this same implementation.
#
# ROLE IN THE FOUR-SCRIPT WORKFLOW
# -------------------------------
# arr_health_activity.sh captures durable exact-ID import receipts and verified
# policy dispositions. This script may consume that proof alongside native history
# before moving leftover SAB payloads. It also owns their final quarantine purge.
# It does NOT expire metadata under /mnt/user/media/bin: quarantine_lifecycle.sh
# handles that separate bin, produced by arr_delete_sync_tag.sh.
#
# PROCESS: NORMAL SCHEDULED RUN
# -----------------------------
# 1. Validate configured mounts, execution mode, roots and locks; initialize the
#    bounded logs/daily outbox and reconcile unfinished move/purge/restore work.
# 2. Apply backup retention independently: default NZB backups retain 60 days;
#    top-level SAB application backup ZIPs retain seven days. Matches are limited
#    to the supported backup extensions/locations, not arbitrary archive trees.
# 3. Obtain complete SAB history/queue and enabled Arr queues. Map categories
#    explicitly to Sonarr/Radarr; preserve active or ambiguously owned jobs.
# 4. Consider Completed jobs only after MIN_COMPLETED_AGE_HOURS (336 hours / 14
#    days) and MIN_PATH_STABLE_HOURS (24 hours unchanged). Resolve source paths
#    through configured roots/mappings and reject unsafe/unstable paths.
# 5. Establish one supported proof route:
#    a. Native history: exact grab/download ID and subsequent import events, with
#       current nonempty imported library files accounting for remaining videos.
#    b. Durable import receipt: unchanged SAB identity and exact native target/
#       file IDs resolved to current physical library files. TVDB/TMDB identity
#       permits verified renames; older receipts without it require the old path.
#    c. Verified policy disposition: an explicitly handled redundant/rejected job
#       recorded by the monitor, not a fabricated import. Fresh monitoring/file
#       checks and the narrow single-video protection still apply.
# 6. Recheck current queues, proof and Mover immediately before a move. Commit a
#    prepared manifest, move the payload into its owned quarantine wrapper, then
#    verify/commit the completed move. Nothing is moved into the live library.
# 7. Purge only this script's valid, committed quarantine wrappers after their own
#    14-day retention, subject to limits, Mover checks and durable purge receipts.
# 8. Report the real actions, named source/destination paths, retained items and
#    errors. Failed/ambiguous work stays protected and can be revisited later.
#
# QUARANTINE / RETENTION / LIMITS
# ------------------------------
# Default root: /mnt/user/media/net/quarantine/items/Sonarr|Radarr/WRAPPER/payload.
# Each wrapper has .sabnzbd-cleanup-manifest.json with original path, job identity,
# proof and move/retention state. Purge age uses the recorded quarantine time,
# not a directory mtime that permissions or file activity might change.
# Defaults: ten quarantine moves, 25 purges and 100 GiB purge bytes per run.
# The initial completed-age gate and the later quarantine retention are separate:
# a job usually waits at least 14 days before quarantine, then another 14 days
# before final purge. Quarantine can be restored before final purge; deleted
# backup files and already purged payloads are not recoverable through this CLI.
#
# SAFETY, I/O AND REVIEW BOUNDARIES
# -------------------------------
# Incomplete APIs/pagination, missing destinations, wrong IDs, conflicting receipts,
# partial/unaccounted packs and recently changed paths do not authorize a move.
# Source traversal must succeed; an unreadable subtree cannot count as zero media.
# Moves require the supported same-filesystem path/device checks. Owner nobody,
# 0755 directories and 0644 files apply only to this quarantine tree; other source,
# backup, library and log paths keep their permissions/ownership.
# Mover is rechecked before destructive backup cleanup, quarantine/purge and restore.
# An uncertain operation is not blindly repeated. Restore never overwrites an
# existing path or returns an actively queued job. The script does not change SAB
# history, Arr queue/history records, monitoring or live library files. Proof and
# inventory checks do read real source/library storage and may wake array disks.
#
# SCHEDULE / EXECUTION MODE
# ------------------------
# Run once daily during a quiet period after your normal import batches. The
# four-hour action windows in the health monitor do not shorten these cleanup
# retention gates. Cron is configured in Unraid User Scripts, not by this script.
# GitHub defaults DRY_RUN=true; the installed personal copy can retain execute mode.
# Inspect the local configuration before running. --dry-run previews payload/
# backup deletions, moves and purges, while logs/observations can still be updated.
# CLEAN_BACKUPS, CLEAN_STRANDED_DOWNLOADS and PURGE_QUARANTINE are independent
# module switches. --no-purge permits quarantine without final payload purging.
#
# NOTIFICATIONS / LOGGING / STATE
# ------------------------------
# A durable outbox sends at most one normal grouped report per day. It identifies
# actual backup deletions, quarantine/purge/restore paths and bytes, proof route,
# protected jobs and failures; overflow/failed reports remain queued. Unchanged
# attention is suppressed rather than producing one email per job every run.
# LOG_DIR defaults to /mnt/user/cloud/logs/script/arr_sabnzbd_cleanup. It contains
# notification state/outbox, pending operations and independent recovery/purge
# receipts. Runtime scratch is separate temporary storage. The active log is capped
# at 1 MiB with two backups and 30-day backup retention; audit retention is normally
# 365 days, with referenced receipts pinned while operations remain unfinished.
#
# CLI / OPERATOR EXAMPLES
# -----------------------
#   cleanup_script="/boot/config/plugins/user.scripts/scripts/arr_sabnzbd_cleanup/script"
#   /bin/bash "$cleanup_script" --help
#   /bin/bash "$cleanup_script" --dry-run --no-purge
#   /bin/bash "$cleanup_script" --execute --no-purge
#   /bin/bash "$cleanup_script" --inspect
#   /bin/bash "$cleanup_script" --restore /mnt/user/media/net/quarantine/items/Sonarr/WRAPPER
#   /bin/bash "$cleanup_script" --pending-operations
#   /bin/bash "$cleanup_script" --resolve-operation OPERATION_ID "verified outcome"
# Replace WRAPPER/OPERATION_ID with values from inspection/pending output. Operator
# resolution records a verified decision; it does not move/delete payloads or
# force a retry. Use /bin/bash because direct flash execution can be disallowed.
###############################################################################

set -uo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

VERSION="2.5.0"

# ---------------------------------------------------------------------------
# Execution behavior
# ---------------------------------------------------------------------------

DRY_RUN="${DRY_RUN:-true}"

# Each cleanup module can be disabled independently. Quarantine purge does not
# require SABnzbd or Arr API access when stranded-download cleanup is disabled.
CLEAN_BACKUPS="${CLEAN_BACKUPS:-true}"
CLEAN_STRANDED_DOWNLOADS="${CLEAN_STRANDED_DOWNLOADS:-true}"
PURGE_QUARANTINE="${PURGE_QUARANTINE:-true}"

# ---------------------------------------------------------------------------
# SABnzbd backup retention
# ---------------------------------------------------------------------------

SAB_BACKUP_DIR="${SAB_BACKUP_DIR:-/mnt/vault/backup/arr_db/sabnzbd}"
NZB_BACKUP_DIR="${NZB_BACKUP_DIR:-${SAB_BACKUP_DIR}/nzb}"

NZB_RETENTION_DAYS="${NZB_RETENTION_DAYS:-60}"
APP_BACKUP_RETENTION_DAYS="${APP_BACKUP_RETENTION_DAYS:-7}"

# A conservative grace period. Radarr/Sonarr also regard aggressive SAB
# history retention (less than 14 days) as unsafe.
MIN_COMPLETED_AGE_HOURS="${MIN_COMPLETED_AGE_HOURS:-336}"

# Even an old job is protected if anything below its path changed recently.
MIN_PATH_STABLE_HOURS="${MIN_PATH_STABLE_HOURS:-24}"

# Quarantine retention starts when this script moves the payload.
QUARANTINE_RETENTION_DAYS="${QUARANTINE_RETENTION_DAYS:-14}"

# Limit real quarantine moves per run. Zero means unlimited.
MAX_QUARANTINES_PER_RUN="${MAX_QUARANTINES_PER_RUN:-10}"
MAX_PURGES_PER_RUN="${MAX_PURGES_PER_RUN:-25}"
MAX_PURGE_BYTES_PER_RUN="${MAX_PURGE_BYTES_PER_RUN:-107374182400}"
PURGE_RECEIPT_RETENTION_DAYS=365
PURGE_RECEIPT_DIR="${LOG_DIR:-/mnt/user/cloud/logs/script/arr_sabnzbd_cleanup}/purge-receipts"

# Refuse to overlap Unraid Mover. The process pattern matches current and
# legacy Unraid mover entry points and is shared with mover_audit.sh.
MOVER_GUARD_ENABLED="${MOVER_GUARD_ENABLED:-true}"
MOVER_PROCESS_PATTERN="${MOVER_PROCESS_PATTERN:-(^|/)(mover|mover\.old)( |$)|mover\.php}"

# Send a normal Unraid notification when a scheduled cleanup is skipped because
# Mover is still active. The script exits successfully so User Scripts does not
# report the deliberate skip as a failure.
NOTIFY_MOVER_SKIP="${NOTIFY_MOVER_SKIP:-true}"

# ---------------------------------------------------------------------------
# Sonarr
# ---------------------------------------------------------------------------

SONARR_ENABLED="${SONARR_ENABLED:-true}"
SONARR_URL="${SONARR_URL:-http://192.168.50.4:8989}"
SONARR_API_KEY="${SONARR_API_KEY:-PUT_YOUR_SONARR_API_KEY_HERE}"

# Semicolon-separated container-prefix|host-prefix mappings. The script first
# tries importedPath exactly as Arr reports it, then tries each mapping.
SONARR_IMPORT_PATH_MAPS="${SONARR_IMPORT_PATH_MAPS:-/media/series|/mnt/user/media/series;/data/media/series|/mnt/user/media/series;/tv|/mnt/user/media/series}"

# Semicolon-separated host roots. Every verified Sonarr importedPath must
# resolve below one of these roots.
SONARR_LIBRARY_ROOTS="${SONARR_LIBRARY_ROOTS:-/mnt/user/media/series}"

# ---------------------------------------------------------------------------
# Radarr
# ---------------------------------------------------------------------------

RADARR_ENABLED="${RADARR_ENABLED:-true}"
RADARR_URL="${RADARR_URL:-http://192.168.50.4:7878}"
RADARR_API_KEY="${RADARR_API_KEY:-PUT_YOUR_RADARR_API_KEY_HERE}"

RADARR_IMPORT_PATH_MAPS="${RADARR_IMPORT_PATH_MAPS:-/media/movies|/mnt/user/media/movies;/data/media/movies|/mnt/user/media/movies;/movies|/mnt/user/media/movies}"
RADARR_LIBRARY_ROOTS="${RADARR_LIBRARY_ROOTS:-/mnt/user/media/movies}"

# ---------------------------------------------------------------------------
# SABnzbd
# ---------------------------------------------------------------------------

SAB_URL="${SAB_URL:-http://192.168.50.4:8080}"
SAB_API_KEY="${SAB_API_KEY:-PUT_YOUR_SABNZBD_API_KEY_HERE}"

# Host-visible completed download layout. These defaults match the repository's
# arr_health_activity.sh configuration.
# Only the monitor-generated verified dispositions can authorize rejected-payload quarantine.
# Exact native import receipts survive history pruning and destination renames.
IMPORT_RECEIPT_FILE="${IMPORT_RECEIPT_FILE:-/mnt/vault/cloud/logs/script/arr_health_activity/import-receipts.json}"
POLICY_DISPOSITION_FILE="${POLICY_DISPOSITION_FILE:-/mnt/vault/cloud/logs/script/arr_health_activity/policy-actions.json}"

SAB_COMPLETE_ROOT="${SAB_COMPLETE_ROOT:-/mnt/user/media/net/complete}"

SAB_MOVIE_CATEGORY="${SAB_MOVIE_CATEGORY:-movie}"
SAB_MOVIE_DIR="${SAB_MOVIE_DIR:-${SAB_COMPLETE_ROOT}/movies}"

SAB_TV_CATEGORY="${SAB_TV_CATEGORY:-tv}"
SAB_TV_DIR="${SAB_TV_DIR:-${SAB_COMPLETE_ROOT}/series}"

# SAB may return its container-side path. Configure the completed root exactly
# as SAB sees it. Leave empty to disable prefix mapping; basename fallback under
# the category root remains available and is still root-validated.
SAB_CONTAINER_COMPLETE_ROOT="${SAB_CONTAINER_COMPLETE_ROOT:-}"

# ---------------------------------------------------------------------------
# Quarantine, logs, notifications, and APIs
# ---------------------------------------------------------------------------

# Keep quarantine outside SAB_COMPLETE_ROOT but preferably on the same Unraid
# share/filesystem so the move is fast and recoverable.
QUARANTINE_DIR="${QUARANTINE_DIR:-/mnt/user/media/net/quarantine}"

# Normalize only QUARANTINE_DIR and its contents. Supplying an owner without a
# group deliberately preserves each entry's existing group ownership.
QUARANTINE_OWNER="${QUARANTINE_OWNER:-nobody}"
QUARANTINE_DIRECTORY_MODE="${QUARANTINE_DIRECTORY_MODE:-0755}"
QUARANTINE_FILE_MODE="${QUARANTINE_FILE_MODE:-0644}"

LOG_DIR="${LOG_DIR:-/mnt/user/cloud/logs/script/arr_sabnzbd_cleanup}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/arr_sabnzbd_cleanup.log}"
# Compact operational logs; full inventories remain in deletion receipts.
LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_BACKUP_FILES=2
LOG_RETENTION_DAYS=30
LOG_LINE_MAX_BYTES=4096

LOG_MAX_BYTES="${LOG_MAX_BYTES:-1048576}"
LOG_KEEP="${LOG_KEEP:-2}"

SEND_NOTIFICATIONS="${SEND_NOTIFICATIONS:-true}"
OPS_NOTIFICATION_STATE="${LOG_DIR}/notification-state.json"
NOTIFY_DRY_RUN="${NOTIFY_DRY_RUN:-false}"
NOTIFY="${NOTIFY:-/usr/local/emhttp/webGui/scripts/notify}"

LOCK_FILE="${LOCK_FILE:-/tmp/arr_sabnzbd_cleanup.lock}"

SAB_HISTORY_PAGE_SIZE="${SAB_HISTORY_PAGE_SIZE:-500}"
SAB_HISTORY_MAX_PAGES="${SAB_HISTORY_MAX_PAGES:-100}"
ARR_QUEUE_PAGE_SIZE="${ARR_QUEUE_PAGE_SIZE:-10000}"
ARR_HISTORY_PAGE_SIZE="${ARR_HISTORY_PAGE_SIZE:-1000}"

CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-10}"
CURL_MAX_TIME="${CURL_MAX_TIME:-60}"
TLS_VERIFY="${TLS_VERIFY:-true}"

###############################################################################
# INTERNAL STATE
###############################################################################

START_EPOCH="$(date '+%s')"
RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"
TMP_DIR=""

SAB_HISTORY_FILE=""
SAB_QUEUE_FILE=""
SONARR_QUEUE_FILE=""
RADARR_QUEUE_FILE=""

SAB_MOVIE_DIR_REAL=""
SAB_TV_DIR_REAL=""
QUARANTINE_DIR_REAL=""
SAB_BACKUP_DIR_REAL=""
NZB_BACKUP_DIR_REAL=""

BACKUP_CLEANUP_STATUS="DISABLED"
STRANDED_CLEANUP_STATUS="DISABLED"
QUARANTINE_PURGE_STATUS="DISABLED"

NZB_BACKUPS_ELIGIBLE=0
APP_BACKUPS_ELIGIBLE=0
NZB_BACKUPS_REMOVED=0
APP_BACKUPS_REMOVED=0
NZB_BACKUP_BYTES=0
APP_BACKUP_BYTES=0

SCANNED=0
COMPLETED_SCANNED=0
TOO_YOUNG=0
QUEUE_PROTECTED=0
PATH_MISSING=0
PATH_UNSTABLE=0
HISTORY_UNPROVEN=0
DESTINATION_UNVERIFIED=0
SOURCE_UNACCOUNTED=0
SAFETY_SKIPPED=0
MOVER_PROTECTED=0
ELIGIBLE=0
QUARANTINED=0
PURGED=0
ERRORS=0
BYTES_ELIGIBLE=0
BYTES_QUARANTINED=0
BYTES_PURGED=0

BACKUP_DETAILS=()
QUARANTINE_DETAILS=()
PURGE_DETAILS=()

RECOVERED=0
NOTIFICATION_FINALIZED=false
RUN_INITIALIZED=false
RECOVERY_DETAILS=()
MOVER_GUARD_TRIGGERED=false
MOVER_GUARD_CONTEXT=""

###############################################################################
# GENERAL HELPERS
###############################################################################

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

is_true() {
  case "${1:-}" in
    1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]) return 0 ;;
    *) return 1 ;;
  esac
}

is_false() {
  case "${1:-}" in
    0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff]) return 0 ;;
    *) return 1 ;;
  esac
}

OPS_SCRIPT_NAME="arr_sabnzbd_cleanup"
OPS_SCRIPT_VERSION="2.5.0"
OPS_RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"
OPS_ATTENTION_DETAILS=""
OPS_ATTENTION_FILE=""
OPS_LOG_BYTES=""

# Shared operational logging convention, embedded to keep User Scripts standalone.
# INFO records actions, warnings and one completion summary. DEBUG adds routine
# progress. Numbered backups expire by size, count and age; receipts are separate.
ops_initialize_log() {
    find "$LOG_DIR" -maxdepth 1 -type f \( -name '.notify-*' -o -name '.operation-*' \) -mtime +1 -delete || return 1
    local file suffix bytes now cutoff
    [[ ! -L "$LOG_FILE" ]] || return 1
    now=$(date +%s); cutoff=$((now-LOG_RETENTION_DAYS*86400))
    for file in "$LOG_FILE".[0-9]*; do
        [[ -f "$file" ]] || continue
        suffix=${file##*.}; [[ "$suffix" =~ ^[0-9]+$ ]] || continue
        bytes=$(stat -c '%s' "$file") || return 1
        if (( suffix>LOG_BACKUP_FILES || bytes>LOG_MAX_BYTES || (LOG_RETENTION_DAYS>0 && $(stat -c '%Y' "$file")<=cutoff) )); then
            rm -f -- "$file" || return 1
        fi
    done
    : >>"$LOG_FILE" || return 1
    OPS_LOG_BYTES=$(stat -c '%s' "$LOG_FILE") || return 1
    if (( OPS_LOG_BYTES>LOG_MAX_BYTES*4 )); then : >"$LOG_FILE"; OPS_LOG_BYTES=0; fi
    if (( OPS_LOG_BYTES>=LOG_MAX_BYTES )); then ops_rotate_log || return 1; fi
}

ops_rotate_log() {
    local i
    rm -f -- "$LOG_FILE.$LOG_BACKUP_FILES" || return 1
    for ((i=LOG_BACKUP_FILES-1;i>=1;i--)); do
        [[ ! -f "$LOG_FILE.$i" ]] || mv -f -- "$LOG_FILE.$i" "$LOG_FILE.$((i+1))" || return 1
    done
    [[ ! -f "$LOG_FILE" ]] || mv -f -- "$LOG_FILE" "$LOG_FILE.1" || return 1
    : >"$LOG_FILE" || return 1
    OPS_LOG_BYTES=0
}

ops_log() {
    local level="$1" message line size
    local LC_ALL=C
    shift; message="$*"
    [[ "$level" != DEBUG || "${LOG_LEVEL^^}" == DEBUG ]] || return 0
    case "$level" in
        WARN|WARNING|ERROR|CRITICAL)
            OPS_ATTENTION_DETAILS+="- [$level] $message"$'\n'
            if [[ -n "${OPS_ATTENTION_FILE:-}" ]]; then printf '%s\n' "- [$level] $message" >>"$OPS_ATTENTION_FILE"; fi
            ;;
    esac
    if (( ${#message}>LOG_LINE_MAX_BYTES )); then message="${message:0:LOG_LINE_MAX_BYTES} ... [line truncated]"; fi
    printf -v line '%s | %s | %s v%s | run=%s | %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$OPS_SCRIPT_NAME" "$OPS_SCRIPT_VERSION" "$OPS_RUN_ID" "$message"
    printf '%s\n' "$line" >&2
    [[ -d "${LOG_FILE%/*}" ]] || return 0
    [[ -n "${OPS_LOG_BYTES:-}" ]] || ops_initialize_log || return 1
    size=$(( ${#line}+1 ))
    if (( OPS_LOG_BYTES+size>LOG_MAX_BYTES )); then ops_rotate_log || return 1; fi
    printf '%s\n' "$line" >>"$LOG_FILE" || return 1
    OPS_LOG_BYTES=$(( OPS_LOG_BYTES+size ))
}

# Durable daily outbox. Unsent chunks survive failures, daily limits and caps.
# Flush only destructive-operation checkpoints and their receipts, never every
# log line. Flush the containing directory after atomic replacement too.
ops_flush_file() {
    sync -- "$1"
}

ops_publish_checkpoint() {
    local temporary="$1" destination="$2"
    ops_flush_file "$temporary" || return 1
    mv -f -- "$temporary" "$destination" || return 1
    ops_flush_file "$destination" || return 1
    # Some FUSE versions reject directory fsync; syncfs is a checked fallback.
    sync -- "$(dirname -- "$destination")" 2>/dev/null || sync -f "$destination"
}

ops_flush_directory() {
    sync -- "$1" 2>/dev/null || sync -f "$1"
}

ops_flush_move() {
    local source="$1" destination="$2"
    if [[ -f "$destination" ]]; then ops_flush_file "$destination" || return 1
    elif [[ -d "$destination" ]]; then sync -f "$destination" || return 1
    else return 1; fi
    ops_flush_directory "$(dirname -- "$source")" || return 1
    ops_flush_directory "$(dirname -- "$destination")"
}

ops_set_topic() {
    local topic="$1" status="$2" summary="$3" tmp
    ops_notification_state || return 1
    tmp=$(mktemp "${LOG_DIR}/.notify-topic.XXXXXX") || return 1
    jq --arg topic "$topic" --arg status "$status" --arg summary "$summary" --arg at "$(date -Iseconds)" '
      .topics[$topic]={status:$status,summary:$summary,updatedAt:$at}
      | .outbox |= map(
          if .topic==$topic and .kind=="attention" and $status=="healthy" then
            .description as $previousDescription | .message as $previousMessage
            | .kind="resolved" | .importance="normal"
            | .id += ":resolved" | .description="Queued condition resolved before delivery"
            | .message=("Earlier queued condition: "+$previousDescription+"\nEarlier detail: "+$previousMessage[0:600]+"\nCurrent result: "+$summary+"\nThe earlier warning is no longer reported as active.")
          else . end)
    ' "$OPS_NOTIFICATION_STATE" >"$tmp" && mv -f -- "$tmp" "$OPS_NOTIFICATION_STATE"
}

ops_notification_state() {
    local tmp
    [[ ! -L "$OPS_NOTIFICATION_STATE" ]] || return 1
    if [[ ! -e "$OPS_NOTIFICATION_STATE" ]]; then
        tmp=$(mktemp "${LOG_DIR}/.notify-state.XXXXXX") || return 1
        printf '%s\n' '{"version":1,"outbox":[],"attention":{},"topics":{}}' >"$tmp" && mv -f -- "$tmp" "$OPS_NOTIFICATION_STATE" || return 1
    fi
    jq -e 'type=="object" and ((.outbox // [])|type)=="array" and ((.topics // {})|type)=="object"' "$OPS_NOTIFICATION_STATE" >/dev/null || return 1
    if jq -e '.outbox==null or .topics==null or any(.outbox[]?; .topic==null or .kind==null or ((.message // "")|utf8bytelength)>8000)' "$OPS_NOTIFICATION_STATE" >/dev/null; then
        local topic=sab-cleanup
        [[ "$OPS_SCRIPT_NAME" != quarantine_lifecycle ]] || topic=lifecycle
        tmp=$(mktemp "$LOG_DIR/.notify-migration.XXXXXX") || return 1
        jq --arg topic "$topic" '
          .outbox //= [] | .topics //= {}
          | .outbox |= [ .[] | .topic //= $topic
            | .kind //= (if .description=="Quarantine review required" then "attention" else "action" end)
            | if (.message|utf8bytelength)>8000 then
                . as $event | range(0;(.message|length);2000) as $offset
                | $event + {id:($event.id+":part"+($offset|tostring)),offset:(($event.offset // 0)+$offset),message:$event.message[$offset:$offset+2000]}
              else . end ]
        ' "$OPS_NOTIFICATION_STATE" >"$tmp" && mv -f -- "$tmp" "$OPS_NOTIFICATION_STATE" || return 1
    fi
}

ops_notify() {
    local importance="$1" subject="$2" description="$3" message="$4" topic="${5:-}" kind="${6:-action}" tmp message_file id
    OPS_NOTIFICATION_DELIVERED=false
    ops_notification_state || return 1
    message_file=$(mktemp "${LOG_DIR}/.notify-message.XXXXXX") || return 1
    printf '%s' "$message" >"$message_file" || return 1
    id=$( { printf '%s\n' "$subject" "$description" "$topic" "$kind"; cat "$message_file"; } | sha256sum | cut -d ' ' -f1)
    tmp=$(mktemp "${LOG_DIR}/.notify-outbox.XXXXXX") || return 1
    jq --arg id "$id" --arg importance "$importance" --arg subject "$subject" --arg description "$description" \
      --arg topic "$topic" --arg kind "$kind" --rawfile message "$message_file" --arg at "$(date -Iseconds)" '
      .outbox //= []
      | if any(.outbox[]; .eventId==$id) then . else
          if $topic!="" and ($kind=="attention" or $kind=="resolved") then
            .outbox |= map(select(.topic!=$topic or (.kind!="attention" and .kind!="resolved")))
          else . end
          | .outbox += [range(0;([$message|length,1]|max);2000) as $offset |
            {eventId:$id,id:($id+":"+($offset|tostring)),importance:$importance,subject:$subject,description:$description,
             message:$message[$offset:$offset+2000],offset:$offset,queuedAt:$at,topic:$topic,kind:$kind}]
        end
    ' "$OPS_NOTIFICATION_STATE" >"$tmp" && mv -f -- "$tmp" "$OPS_NOTIFICATION_STATE" || { rm -f -- "$tmp" "$message_file"; return 1; }
    rm -f -- "$message_file"
    ops_flush_notifications || return 1
    if ! jq -e --arg id "$id" 'any(.outbox[]?;.eventId==$id)' "$OPS_NOTIFICATION_STATE" >/dev/null; then OPS_NOTIFICATION_DELIVERED=true; fi
}

ops_flush_notifications() {
    local tmp selected body importance subject count sent today="$(date +%F)" notify_bin="${NOTIFY_BIN:-${NOTIFY:-}}"
    ops_notification_state || return 1
    jq -e '(.outbox // []|length)>0' "$OPS_NOTIFICATION_STATE" >/dev/null || return 0
    [[ "$(jq -r '.lastSentAt // ""' "$OPS_NOTIFICATION_STATE")" != "$today"* ]] || return 0
    selected=$(mktemp "${LOG_DIR}/.notify-selected.XXXXXX") || return 1
    # Include as many complete sections as fit a 22 KB payload budget. Reserve
    # 2 KB for the summary/footer; count UTF-8 bytes, not display characters.
    jq '
      .topics as $topics
      | [.outbox[] | . as $event
         | ($topics[.topic // ""] // {}) as $topic
         | .effectiveImportance=(if $topic.status=="healthy" and (.kind // "")!="attention" then "normal" else .importance end)
         | .render=("Queued: "+.queuedAt+"\n"+.description+"\n"
           + (if ($topic.summary // "")!="" then "Current status: "+$topic.summary+"\nAction details below were recorded at the queued time.\n" else "" end)
           + "\n"+.message)]
      | sort_by((if .effectiveImportance=="alert" then 0 elif .effectiveImportance=="warning" then 1 else 2 end),.queuedAt,.eventId,(.offset // 0))
      | reduce .[] as $event ({bytes:0,selected:[]};
          (($event.render|utf8bytelength)+10) as $bytes
          | if .bytes+$bytes<=22000 then .bytes+=$bytes | .selected+=[$event] else . end)
      | .selected
    ' "$OPS_NOTIFICATION_STATE" >"$selected" || return 1
    sent=$(jq 'length' "$selected")
    if ((sent==0)); then
        rm -f -- "$selected"; ops_log ERROR "Queued legacy report exceeds the notification byte budget; report preserved for review."; return 1
    fi
    body=$(jq -r 'map(.render)|join("\n\n----------\n\n")' "$selected")
    importance=$(jq -r 'if any(.[];.effectiveImportance=="alert") then "alert" elif any(.[];.effectiveImportance=="warning") then "warning" else "normal" end' "$selected")
    subject=$(jq -r '.[0].subject' "$selected")
    body=$(printf '%s' "$body" | jq -Rsr 'explode | map(select(.!=8205 and .!=8419 and .!=65039 and (. < 9728 or . > 10175) and (. < 126976 or . > 129791))) | implode')
    count=$(jq '.outbox|length' "$OPS_NOTIFICATION_STATE")
    body+=$'\n\n'"Included $sent report section(s); $((count-sent)) additional section(s) remain queued. Completed-action records are retained separately."
    if [[ ! -x "$notify_bin" ]] || ! "$notify_bin" -i "$importance" -s "$subject" -d "Operational actions and exceptions" -m "$body" >/dev/null 2>&1; then
        rm -f -- "$selected"; ops_log ERROR "Notification delivery failed; detailed reports retained in the daily outbox."; return 1
    fi
    tmp=$(mktemp "${LOG_DIR}/.notify-sent.XXXXXX") || return 1
    jq --slurpfile selected "$selected" --arg now "$(date -Iseconds)" \
      '.outbox |= map(. as $event | select(any($selected[0][]; .id==$event.id)|not)) | .lastSentAt=$now' \
      "$OPS_NOTIFICATION_STATE" >"$tmp" && mv -f -- "$tmp" "$OPS_NOTIFICATION_STATE" || return 1
    rm -f -- "$selected"
    ops_log INFO "Delivered one daily email containing $sent report sections; queued sections=$((count-sent))."
}

# Unfinished purge/restore operations outlive processes and daily log rotation.
ops_list_pending_operations() {
    local state="${OPS_PENDING_OPERATIONS_FILE:-$LOG_DIR/pending-operations.json}"
    [[ -d "$LOG_DIR" ]] || { printf 'Operation state directory is unavailable: %s\n' "$LOG_DIR" >&2; return 1; }
    if [[ -f "$state" ]]; then jq -e '.version==1 and (.operations|type)=="object"' "$state" >/dev/null && jq '.operations' "$state"
    else printf '{}\n'; fi
}

ops_operation_state() {
    OPS_PENDING_OPERATIONS_FILE="${OPS_PENDING_OPERATIONS_FILE:-$LOG_DIR/pending-operations.json}"
    OPS_OPERATION_AUDIT_FILE="${OPS_OPERATION_AUDIT_FILE:-$LOG_DIR/operation-recovery.jsonl}"
    [[ ! -L "$OPS_PENDING_OPERATIONS_FILE" && ! -L "$OPS_OPERATION_AUDIT_FILE" ]] || return 1
    local tmp
    if [[ ! -e "$OPS_PENDING_OPERATIONS_FILE" ]]; then
        tmp=$(mktemp "$LOG_DIR/.operation-state.XXXXXX") || return 1
        printf '%s\n' '{"version":1,"operations":{}}' >"$tmp"
        ops_publish_checkpoint "$tmp" "$OPS_PENDING_OPERATIONS_FILE" || return 1
    fi
    jq -e '.version==1 and (.operations|type)=="object"' "$OPS_PENDING_OPERATIONS_FILE" >/dev/null
}

ops_operation_paths_valid() {
    local source="$1" destination="$2" source_real root_real destination_real allowed=false root
    [[ -d "$OPS_QUARANTINE_ROOT" && ! -L "$OPS_QUARANTINE_ROOT" ]] || return 1
    source_real=$(realpath -m -- "$source") || return 1
    root_real=$(realpath -m -- "$OPS_QUARANTINE_ROOT") || return 1
    [[ "$source_real" == "$root_real"/* ]] || return 1
    if [[ -n "$destination" ]]; then
        destination_real=$(realpath -m -- "$destination") || return 1
        for root in "${OPS_RESTORE_ROOTS[@]}"; do
            root_real=$(realpath -m -- "$root") || return 1
            [[ "$destination_real" != "$root_real"/* ]] || allowed=true
        done
        [[ "$allowed" == true ]] || return 1
    fi
}

ops_operation_begin() {
    local kind="$1" source="$2" destination="$3" proof="$4" identity="" id tmp
    ops_operation_state || return 1
    ops_operation_paths_valid "$source" "$destination" || { ops_log ERROR "Unsafe operation paths; checkpoint and mutation refused: $source -> $destination"; return 1; }
    id=$(printf '%s' "$kind|$source|$destination" | sha256sum | cut -d ' ' -f1)
    if jq -e --arg id "$id" '.operations[$id]!=null' "$OPS_PENDING_OPERATIONS_FILE" >/dev/null; then
        # A partial purge resumes only after the caller's normal retention,
        # inventory, Mover and byte-limit checks. Its original evidence stays.
        [[ "$kind" == purge ]] || { ops_log ERROR "Restore already pending; reconciliation required ($id)."; return 1; }
        printf '%s' "$id"; return 0
    fi
    [[ -f "$proof" ]] || return 1
    ops_flush_file "$proof" || return 1
    ops_flush_directory "$(dirname -- "$proof")" || return 1
    if [[ "$kind" == restore ]]; then identity=$(stat -c '%d:%i:%F:%s' -- "$source") || return 1; fi
    tmp=$(mktemp "$LOG_DIR/.operation-intent.XXXXXX") || return 1
    jq --arg id "$id" --arg kind "$kind" --arg source "$source" --arg destination "$destination" \
      --arg proof "$proof" --arg identity "$identity" --argjson now "$(date +%s)" \
      '.operations[$id]={kind:$kind,source:$source,destination:$destination,proof:$proof,identity:$identity,startedAt:$now}' \
      "$OPS_PENDING_OPERATIONS_FILE" >"$tmp" && ops_publish_checkpoint "$tmp" "$OPS_PENDING_OPERATIONS_FILE" || return 1
    printf '%s' "$id"
}

ops_operation_finish() {
    ops_operation_state || return 1
    local id="$1" result="$2" tmp
    jq -c --arg id "$id" --arg result "$result" --argjson now "$(date +%s)" \
      '.operations[$id]+{id:$id,result:$result,at:$now}' "$OPS_PENDING_OPERATIONS_FILE" >>"$OPS_OPERATION_AUDIT_FILE" || return 1
    ops_flush_file "$OPS_OPERATION_AUDIT_FILE" || return 1
    tmp=$(mktemp "$LOG_DIR/.operation-finished.XXXXXX") || return 1
    jq --arg id "$id" 'del(.operations[$id])' "$OPS_PENDING_OPERATIONS_FILE" >"$tmp" && ops_publish_checkpoint "$tmp" "$OPS_PENDING_OPERATIONS_FILE"
}

ops_receipt_in_use() {
    local state="${OPS_PENDING_OPERATIONS_FILE:-$LOG_DIR/pending-operations.json}"
    [[ -f "$state" ]] || return 1
    if ! jq -e '.version==1 and (.operations|type)=="object"' "$state" >/dev/null 2>&1; then
        ops_log ERROR "Invalid operation state; all aged receipts preserved until checkpoints can be reviewed: $state"
        return 0
    fi
    jq -e --arg file "$1" 'any(.operations[]?;.proof==$file)' "$state" >/dev/null
}

ops_recover_operations() {
    local list entry id kind source destination identity actual failed=0
    OPS_RECOVERY_DETAILS=""; OPS_RECOVERED_COUNT=0
    ops_operation_state || return 1
    list=$(mktemp "$LOG_DIR/.operation-recovery.XXXXXX") || return 1
    jq -c '.operations|to_entries[]' "$OPS_PENDING_OPERATIONS_FILE" >"$list" || return 1
    while IFS= read -r entry; do
        id=$(jq -r '.key' <<<"$entry"); kind=$(jq -r '.value.kind' <<<"$entry")
        source=$(jq -r '.value.source' <<<"$entry"); destination=$(jq -r '.value.destination' <<<"$entry")
        ops_operation_paths_valid "$source" "$destination" || { ops_log ERROR "Unsafe pending operation preserved: $id"; failed=$((failed+1)); continue; }
        if [[ "$kind" == purge && -z "$destination" ]]; then
            if [[ ! -e "$source" && ! -L "$source" ]]; then
                ops_operation_finish "$id" "Reconciled interrupted purge: directory absence confirmed; no new deletion performed" || return 1
                OPS_RECOVERY_DETAILS+="- Reconciled interrupted purge: $source is absent. No new deletion was needed. Operation $id."$'\n'
                OPS_RECOVERED_COUNT=$((OPS_RECOVERED_COUNT+1))
            elif [[ -d "$source" && ! -L "$source" ]]; then
                ops_log WARNING "Incomplete purge preserved: $source; remaining files will be retried only after normal retention, idle, Mover and execution-limit checks. Operation $id."
            else
                ops_log ERROR "Interrupted purge source changed type; preserved for review: $source (operation $id)"; failed=$((failed+1))
            fi
        elif [[ "$kind" == restore && -n "$destination" ]]; then
            if [[ ! -e "$source" && ! -L "$source" && -e "$destination" && ! -L "$destination" ]]; then
                identity=$(jq -r '.value.identity' <<<"$entry")
                actual=$(stat -c '%d:%i:%F:%s' -- "$destination") || actual=""
                if [[ -n "$identity" && "$actual" == "$identity" ]]; then
                    ops_operation_finish "$id" "Reconciled interrupted restore: original object identity verified at destination" || return 1
                    OPS_RECOVERY_DETAILS+="- Recovered interrupted restore: $source -> $destination. Original object identity matched; no overwrite or repeat move performed."$'\n'
                    OPS_RECOVERED_COUNT=$((OPS_RECOVERED_COUNT+1))
                else
                    ops_log ERROR "Restore destination exists but identity cannot be proven (possible cross-filesystem copy); destination preserved: $destination. Review operation $id with --pending-operations; use --resolve-operation only after verification."
                    failed=$((failed+1))
                fi
            elif [[ -e "$source" && ! -e "$destination" && ! -L "$destination" ]]; then
                ops_operation_finish "$id" "Interrupted restore was not applied; original source preserved for explicit retry" || return 1
                OPS_RECOVERY_DETAILS+="- Restore did not occur: $source remains quarantined; $destination was not created. An explicit restore may be retried."$'\n'
                OPS_RECOVERED_COUNT=$((OPS_RECOVERED_COUNT+1))
            else
                ops_log ERROR "Ambiguous interrupted restore: source=$source; destination=$destination. Both locations preserved; operation=$id."
                failed=$((failed+1))
            fi
        else ops_log ERROR "Unknown checkpoint type preserved for review: $id"; failed=$((failed+1)); fi
    done <"$list"
    rm -f -- "$list"
    # Keep the small recovery audit for one year, independently of main logs.
    if [[ -s "$OPS_OPERATION_AUDIT_FILE" ]]; then
        local retained
        retained=$(mktemp "$LOG_DIR/.operation-audit.XXXXXX") || return 1
        jq -c --argjson cutoff "$(( $(date +%s)-365*86400 ))" 'select(.at >= $cutoff)' "$OPS_OPERATION_AUDIT_FILE" >"$retained" &&
          ops_publish_checkpoint "$retained" "$OPS_OPERATION_AUDIT_FILE" || return 1
    fi
    ((failed==0))
}

ops_resolve_operation() {
    local id="$1" note="$2"
    [[ "$id" =~ ^[a-f0-9]{64}$ && -n "$note" ]] || return 2
    ops_operation_state || return 1
    jq -e --arg id "$id" '.operations[$id]!=null' "$OPS_PENDING_OPERATIONS_FILE" >/dev/null || return 2
    ops_operation_finish "$id" "Operator verified: $note" || return 1
    OPS_RECOVERY_DETAILS="- Operator resolved operation $id: $note. No payload mutation was performed by this command."
    OPS_RECOVERED_COUNT=1
}

log() {
    ops_log "$@"
}

die() {
  ((ERRORS++)) || true
  log "ERROR" "$*"
  exit 1
}

runtime() {
  local seconds=$(( $(date '+%s') - START_EPOCH ))
  printf '%dh:%dm:%ds' \
    $((seconds / 3600)) \
    $(((seconds % 3600) / 60)) \
    $((seconds % 60))
}

bytes_human() {
  local bytes="${1:-0}"

  awk -v b="$bytes" '
    BEGIN {
      if (b >= 1099511627776) printf "%.2f TB", b / 1099511627776
      else if (b >= 1073741824) printf "%.2f GB", b / 1073741824
      else if (b >= 1048576) printf "%.2f MB", b / 1048576
      else if (b >= 1024) printf "%.2f KB", b / 1024
      else printf "%d B", b
    }
  '
}

stat_size() {
  stat -c '%s' -- "$1" 2>/dev/null || stat -f '%z' -- "$1" 2>/dev/null || printf '0'
}

stat_mtime() {
  stat -c '%Y' -- "$1" 2>/dev/null || stat -f '%m' -- "$1" 2>/dev/null || printf '0'
}

stat_device() {
  stat -c '%d' -- "$1" 2>/dev/null || stat -f '%d' -- "$1" 2>/dev/null || printf ''
}

sanitize_component() {
  printf '%s' "$1" |
    tr '/\n\r\t' '____' |
    sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^[_ .-]+//; s/[_ .-]+$//' |
    cut -c 1-120
}

cleanup_tmp() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}

on_exit() {
  local exit_code=$?
  if [[ "$RUN_INITIALIZED" == true && "$NOTIFICATION_FINALIZED" != true ]]; then
    if (( exit_code!=0 )); then ((ERRORS++)) || true; fi
    notify_summary || exit_code=1
  fi
  if [[ "$RUN_INITIALIZED" == true ]] && is_true "$SEND_NOTIFICATIONS"; then ops_flush_notifications || exit_code=1; fi
  cleanup_tmp
  trap - EXIT
  exit "$exit_code"
}

trap on_exit EXIT
trap 'exit 130' INT TERM

###############################################################################
# COMMAND-LINE OVERRIDES
###############################################################################

usage() {
  cat <<'EOF'
Usage: sabnzbd_cleanup.sh [options]

Options:
  --dry-run     Report all eligible cleanup without changing anything.
  --execute     Enable backup deletion and quarantine operations.
  --purge       Enable delayed quarantine purge.
  --no-purge    Disable delayed quarantine purge.
  --inspect     List quarantine payloads, original paths, state and retention age; change nothing.
  --restore WRAPPER Restore one manifest-backed payload to its original path; never overwrite.
  --pending-operations List unfinished purge/restore checkpoints.
  --resolve-operation ID "verified outcome" Record an operator resolution; change no payload.
  --version     Print release version.
  --help        Show this help.

Normal scheduled invocation uses configuration above. Notifications include actions,
protected items and failures, grouped through a durable once-daily outbox.
Examples: /bin/bash SCRIPT --dry-run --no-purge
          /bin/bash SCRIPT --inspect
          /bin/bash SCRIPT --restore /mnt/user/media/net/quarantine/items/Sonarr/WRAPPER
EOF
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      --execute) DRY_RUN=false ;;
      --purge) PURGE_QUARANTINE=true ;;
      --no-purge) PURGE_QUARANTINE=false ;;
      --pending-operations) CLI_OPERATION=pending ;;
      --resolve-operation) [[ $# -ge 3 ]] || { usage >&2; exit 2; }; CLI_OPERATION=resolve; CLI_OPERATION_ID="$2"; CLI_OPERATION_NOTE="$3"; shift 2 ;;
      --inspect) CLI_OPERATION=inspect ;;
      --restore) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; CLI_OPERATION=restore; CLI_WRAPPER="$2"; shift ;;
      --version) printf 'sabnzbd_cleanup.sh %s\n' "$VERSION"; exit 0 ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
    shift
  done
}

###############################################################################
# INITIALIZATION / VALIDATION
###############################################################################

rotate_logs() {
    ops_initialize_log
}

require_commands() {
  local command_name
  local missing=0

  for command_name in awk basename cat chown chmod curl cut date dirname find flock jq mkdir mktemp mv realpath rm rmdir sed sort stat sha256sum tee tr wc sync; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      log "ERROR" "Required command not found: $command_name"
      missing=1
    fi
  done

  if is_true "$MOVER_GUARD_ENABLED" && ! command -v pgrep >/dev/null 2>&1; then
    log "ERROR" "Required Mover guard command not found: pgrep"
    missing=1
  fi

  (( missing == 0 )) || die "One or more required commands are unavailable."
}

validate_boolean() {
  local name="$1"
  local value="$2"
  if ! is_true "$value" && ! is_false "$value"; then
    ((ERRORS++)) || true
    log "ERROR" "$name must be true/false, yes/no, on/off, or 1/0."
    return 1
  fi
}

validate_integer() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    ((ERRORS++)) || true
    log "ERROR" "$name must be a non-negative integer."
    return 1
  fi
}

validate_api_key() {
  local app="$1"
  local key="$2"

  if [[ -z "$key" ]]; then
    ((ERRORS++)) || true
    log "ERROR" "$app API key is empty."
    return 1
  fi

  if [[ "$key" == PUT_YOUR_* ]]; then
    ((ERRORS++)) || true
    log "ERROR" "$app API key still contains its placeholder value."
    return 1
  fi
}

validate_library_roots() {
  local app="$1"
  local roots="$2"
  local root_list=()
  local root
  local valid=0
  local invalid=0

  IFS=';' read -r -a root_list <<<"$roots"

  for root in "${root_list[@]}"; do
    [[ -n "$root" ]] || continue

    if [[ -d "$root" ]]; then
      root="$(realpath -- "$root")" || continue
      if dangerously_broad_path "$root"; then
        ((ERRORS++)) || true
        log "ERROR" "$app library root is dangerously broad: $root"
        invalid=1
        continue
      fi
      ((valid++)) || true
    else
      log "WARNING" "$app library root does not exist and cannot verify imports: $root"
    fi
  done

  if (( valid == 0 )); then
    ((ERRORS++)) || true
    log "ERROR" "$app has no accessible library root for import verification."
    invalid=1
  fi

  (( invalid == 0 ))
}

dangerously_broad_path() {
  case "$1" in
    /|/mnt|/mnt/user|/mnt/user/media) return 0 ;;
  esac

  [[ "$1" =~ ^/mnt/[^/]+$ ]]
}

canonicalize_target() {
  local target="$1"
  local cursor="$target"
  local suffix=""
  local component
  local parent
  local resolved

  while [[ ! -e "$cursor" ]]; do
    component="$(basename -- "$cursor")"
    parent="$(dirname -- "$cursor")"

    [[ "$parent" != "$cursor" ]] || return 1
    suffix="/${component}${suffix}"
    cursor="$parent"
  done

  resolved="$(realpath -- "$cursor")" || return 1
  printf '%s%s' "$resolved" "$suffix"
}

path_is_below() {
  local child="$1"
  local root="$2"
  [[ "$child" == "$root"/* && "$child" != "$root" ]]
}

normalize_quarantine_permissions() {
  local target="$1"
  local target_real
  local failed=false

  target_real="$(realpath -- "$target")" || {
    log "ERROR" "Unable to resolve quarantine permission target: $target"
    return 1
  }

  if [[ "$target_real" != "$QUARANTINE_DIR_REAL" ]] && \
     ! path_is_below "$target_real" "$QUARANTINE_DIR_REAL"; then
    log "ERROR" "Refusing to change ownership or permissions outside quarantine: $target_real"
    return 1
  fi

  # find does not follow symlinks by default. chown -h changes a symlink's own
  # owner, while chmod is limited to real directories and regular files.
  if ! find "$target_real" -xdev ! -user "$QUARANTINE_OWNER" -exec chown -h -- "$QUARANTINE_OWNER" {} +; then
    log "ERROR" "Unable to set quarantine owner '$QUARANTINE_OWNER': $target_real"
    failed=true
  fi

  if ! find "$target_real" -xdev -type d -exec chmod -- "$QUARANTINE_DIRECTORY_MODE" {} +; then
    log "ERROR" "Unable to set quarantine directory mode $QUARANTINE_DIRECTORY_MODE: $target_real"
    failed=true
  fi

  if ! find "$target_real" -xdev -type f -exec chmod -- "$QUARANTINE_FILE_MODE" {} +; then
    log "ERROR" "Unable to set quarantine file mode $QUARANTINE_FILE_MODE: $target_real"
    failed=true
  fi

  ! is_true "$failed"
}

paths_overlap() {
  local first="$1"
  local second="$2"

  [[ "$first" == "$second" || "$first" == "$second"/* || "$second" == "$first"/* ]]
}

validate_common_environment() {
  local valid=true

  validate_boolean "DRY_RUN" "$DRY_RUN" || valid=false
  validate_boolean "CLEAN_BACKUPS" "$CLEAN_BACKUPS" || valid=false
  validate_boolean "CLEAN_STRANDED_DOWNLOADS" "$CLEAN_STRANDED_DOWNLOADS" || valid=false
  validate_boolean "PURGE_QUARANTINE" "$PURGE_QUARANTINE" || valid=false
  validate_boolean "MOVER_GUARD_ENABLED" "$MOVER_GUARD_ENABLED" || valid=false
  validate_boolean "NOTIFY_MOVER_SKIP" "$NOTIFY_MOVER_SKIP" || valid=false
  validate_boolean "SEND_NOTIFICATIONS" "$SEND_NOTIFICATIONS" || valid=false
  validate_boolean "NOTIFY_DRY_RUN" "$NOTIFY_DRY_RUN" || valid=false
  validate_boolean "TLS_VERIFY" "$TLS_VERIFY" || valid=false
  validate_integer "LOG_MAX_BYTES" "$LOG_MAX_BYTES" || valid=false
  validate_integer "LOG_KEEP" "$LOG_KEEP" || valid=false
  validate_integer "MAX_PURGES_PER_RUN" "$MAX_PURGES_PER_RUN" || valid=false
  validate_integer "MAX_PURGE_BYTES_PER_RUN" "$MAX_PURGE_BYTES_PER_RUN" || valid=false
  validate_integer "CURL_CONNECT_TIMEOUT" "$CURL_CONNECT_TIMEOUT" || valid=false
  validate_integer "CURL_MAX_TIME" "$CURL_MAX_TIME" || valid=false

  if ! is_true "$CLEAN_BACKUPS" &&
     ! is_true "$CLEAN_STRANDED_DOWNLOADS" &&
     ! is_true "$PURGE_QUARANTINE"
  then
    ((ERRORS++)) || true
    log "ERROR" "At least one cleanup module must be enabled."
    valid=false
  fi

  if is_true "$MOVER_GUARD_ENABLED" && [[ -z "$MOVER_PROCESS_PATTERN" ]]; then
    ((ERRORS++)) || true
    log "ERROR" "MOVER_PROCESS_PATTERN cannot be empty while the Mover guard is enabled."
    valid=false
  fi

  is_true "$valid"
}

validate_backup_environment() {
  local valid=true

  validate_integer "NZB_RETENTION_DAYS" "$NZB_RETENTION_DAYS" || valid=false
  validate_integer "APP_BACKUP_RETENTION_DAYS" "$APP_BACKUP_RETENTION_DAYS" || valid=false

  if [[ ! -d "$SAB_BACKUP_DIR" ]]; then
    ((ERRORS++)) || true
    log "ERROR" "SABnzbd backup directory does not exist: $SAB_BACKUP_DIR"
    return 1
  fi

  SAB_BACKUP_DIR_REAL="$(realpath -- "$SAB_BACKUP_DIR")" || {
    ((ERRORS++)) || true
    log "ERROR" "Unable to resolve SABnzbd backup directory: $SAB_BACKUP_DIR"
    return 1
  }

  if dangerously_broad_path "$SAB_BACKUP_DIR_REAL"; then
    ((ERRORS++)) || true
    log "ERROR" "SABnzbd backup directory is dangerously broad: $SAB_BACKUP_DIR_REAL"
    valid=false
  fi

  if [[ -d "$NZB_BACKUP_DIR" ]]; then
    NZB_BACKUP_DIR_REAL="$(realpath -- "$NZB_BACKUP_DIR")" || {
      ((ERRORS++)) || true
      log "ERROR" "Unable to resolve NZB backup directory: $NZB_BACKUP_DIR"
      return 1
    }

    if ! path_is_below "$NZB_BACKUP_DIR_REAL" "$SAB_BACKUP_DIR_REAL"; then
      ((ERRORS++)) || true
      log "ERROR" "NZB backup directory must be below SAB_BACKUP_DIR: $NZB_BACKUP_DIR_REAL"
      valid=false
    fi
  else
    NZB_BACKUP_DIR_REAL=""
    log "WARNING" "NZB backup directory is unavailable; NZB retention will be skipped: $NZB_BACKUP_DIR"
  fi

  is_true "$valid"
}

prepare_quarantine_environment() {
  validate_integer "QUARANTINE_RETENTION_DAYS" "$QUARANTINE_RETENTION_DAYS" || return 1

  if [[ -z "$QUARANTINE_OWNER" || "$QUARANTINE_OWNER" == *:* ]]; then
    ((ERRORS++)) || true
    log "ERROR" "QUARANTINE_OWNER must name one owner without a group."
    return 1
  fi

  if ! [[ "$QUARANTINE_DIRECTORY_MODE" =~ ^0?[0-7]{3}$ ]]; then
    ((ERRORS++)) || true
    log "ERROR" "QUARANTINE_DIRECTORY_MODE must be a three- or four-digit octal mode."
    return 1
  fi

  if ! [[ "$QUARANTINE_FILE_MODE" =~ ^0?[0-7]{3}$ ]]; then
    ((ERRORS++)) || true
    log "ERROR" "QUARANTINE_FILE_MODE must be a three- or four-digit octal mode."
    return 1
  fi

  QUARANTINE_DIR_REAL="$(canonicalize_target "$QUARANTINE_DIR")" || {
    ((ERRORS++)) || true
    log "ERROR" "Unable to resolve quarantine target: $QUARANTINE_DIR"
    return 1
  }

  if dangerously_broad_path "$QUARANTINE_DIR_REAL"; then
    ((ERRORS++)) || true
    log "ERROR" "Quarantine directory is dangerously broad: $QUARANTINE_DIR_REAL"
    return 1
  fi

  if ! is_true "$DRY_RUN"; then
    if ! mkdir -p -- "$QUARANTINE_DIR_REAL/items/Sonarr" "$QUARANTINE_DIR_REAL/items/Radarr"; then
      ((ERRORS++)) || true
      log "ERROR" "Unable to create quarantine directories."
      return 1
    fi

    QUARANTINE_DIR_REAL="$(realpath -- "$QUARANTINE_DIR_REAL")" || {
      ((ERRORS++)) || true
      log "ERROR" "Unable to resolve created quarantine directory."
      return 1
    }

    if ! normalize_quarantine_permissions "$QUARANTINE_DIR_REAL"; then
      ((ERRORS++)) || true
      return 1
    fi
  fi
}

validate_stranded_environment() {
  local valid=true

  validate_boolean "SONARR_ENABLED" "$SONARR_ENABLED" || valid=false
  validate_boolean "RADARR_ENABLED" "$RADARR_ENABLED" || valid=false
  validate_integer "MIN_COMPLETED_AGE_HOURS" "$MIN_COMPLETED_AGE_HOURS" || valid=false
  validate_integer "MIN_PATH_STABLE_HOURS" "$MIN_PATH_STABLE_HOURS" || valid=false
  validate_integer "MAX_QUARANTINES_PER_RUN" "$MAX_QUARANTINES_PER_RUN" || valid=false
  validate_integer "SAB_HISTORY_PAGE_SIZE" "$SAB_HISTORY_PAGE_SIZE" || valid=false
  validate_integer "SAB_HISTORY_MAX_PAGES" "$SAB_HISTORY_MAX_PAGES" || valid=false
  validate_integer "ARR_QUEUE_PAGE_SIZE" "$ARR_QUEUE_PAGE_SIZE" || valid=false
  validate_integer "ARR_HISTORY_PAGE_SIZE" "$ARR_HISTORY_PAGE_SIZE" || valid=false

  if [[ "$SAB_HISTORY_PAGE_SIZE" =~ ^[0-9]+$ ]] && (( SAB_HISTORY_PAGE_SIZE == 0 )); then
    ((ERRORS++)) || true
    log "ERROR" "SAB_HISTORY_PAGE_SIZE must be greater than zero."
    valid=false
  fi
  if [[ "$SAB_HISTORY_MAX_PAGES" =~ ^[0-9]+$ ]] && (( SAB_HISTORY_MAX_PAGES == 0 )); then
    ((ERRORS++)) || true
    log "ERROR" "SAB_HISTORY_MAX_PAGES must be greater than zero."
    valid=false
  fi
  if [[ "$ARR_QUEUE_PAGE_SIZE" =~ ^[0-9]+$ ]] && (( ARR_QUEUE_PAGE_SIZE == 0 )); then
    ((ERRORS++)) || true
    log "ERROR" "ARR_QUEUE_PAGE_SIZE must be greater than zero."
    valid=false
  fi
  if [[ "$ARR_HISTORY_PAGE_SIZE" =~ ^[0-9]+$ ]] && (( ARR_HISTORY_PAGE_SIZE == 0 )); then
    ((ERRORS++)) || true
    log "ERROR" "ARR_HISTORY_PAGE_SIZE must be greater than zero."
    valid=false
  fi

  validate_api_key "SABnzbd" "$SAB_API_KEY" || valid=false

  if is_true "$SONARR_ENABLED"; then
    validate_api_key "Sonarr" "$SONARR_API_KEY" || valid=false
    validate_library_roots "Sonarr" "$SONARR_LIBRARY_ROOTS" || valid=false
  fi

  if is_true "$RADARR_ENABLED"; then
    validate_api_key "Radarr" "$RADARR_API_KEY" || valid=false
    validate_library_roots "Radarr" "$RADARR_LIBRARY_ROOTS" || valid=false
  fi

  if [[ ! -d "$SAB_MOVIE_DIR" ]]; then
    ((ERRORS++)) || true
    log "ERROR" "SAB movie directory does not exist: $SAB_MOVIE_DIR"
    valid=false
  else
    SAB_MOVIE_DIR_REAL="$(realpath -- "$SAB_MOVIE_DIR")" || valid=false
  fi

  if [[ ! -d "$SAB_TV_DIR" ]]; then
    ((ERRORS++)) || true
    log "ERROR" "SAB TV directory does not exist: $SAB_TV_DIR"
    valid=false
  else
    SAB_TV_DIR_REAL="$(realpath -- "$SAB_TV_DIR")" || valid=false
  fi

  if [[ -n "$SAB_MOVIE_DIR_REAL" ]] && dangerously_broad_path "$SAB_MOVIE_DIR_REAL"; then
    ((ERRORS++)) || true
    log "ERROR" "SAB movie directory is dangerously broad: $SAB_MOVIE_DIR_REAL"
    valid=false
  fi
  if [[ -n "$SAB_TV_DIR_REAL" ]] && dangerously_broad_path "$SAB_TV_DIR_REAL"; then
    ((ERRORS++)) || true
    log "ERROR" "SAB TV directory is dangerously broad: $SAB_TV_DIR_REAL"
    valid=false
  fi

  if [[ -n "$SAB_MOVIE_DIR_REAL" && -n "$SAB_TV_DIR_REAL" ]] && paths_overlap "$SAB_MOVIE_DIR_REAL" "$SAB_TV_DIR_REAL"; then
    ((ERRORS++)) || true
    log "ERROR" "SAB movie and TV roots must not overlap."
    valid=false
  fi
  if [[ -n "$QUARANTINE_DIR_REAL" && -n "$SAB_MOVIE_DIR_REAL" ]] && paths_overlap "$QUARANTINE_DIR_REAL" "$SAB_MOVIE_DIR_REAL"; then
    ((ERRORS++)) || true
    log "ERROR" "Quarantine and SAB movie roots must not overlap."
    valid=false
  fi
  if [[ -n "$QUARANTINE_DIR_REAL" && -n "$SAB_TV_DIR_REAL" ]] && paths_overlap "$QUARANTINE_DIR_REAL" "$SAB_TV_DIR_REAL"; then
    ((ERRORS++)) || true
    log "ERROR" "Quarantine and SAB TV roots must not overlap."
    valid=false
  fi

  if [[ "${SAB_MOVIE_CATEGORY,,}" == "${SAB_TV_CATEGORY,,}" ]]; then
    ((ERRORS++)) || true
    log "ERROR" "SAB movie and TV categories must be different."
    valid=false
  fi

  is_true "$valid"
}

initialize() {
  # Never create a shadow log/outbox tree on Unraid's root filesystem if the
  # share/pool disappeared. A RAM marker bounds the exceptional direct alert.
  local required_log_mount="" storage_marker="/tmp/arr-sab-cleanup-storage-$(date +%F).notified" storage_reason
  case "$LOG_DIR" in /mnt/user/*) required_log_mount=/mnt/user;; /mnt/vault/*) required_log_mount=/mnt/vault;; esac
  if [[ -n "$required_log_mount" ]] && ! mountpoint -q "$required_log_mount"; then
    storage_reason="Required log storage $required_log_mount is unavailable. No backup deletions, quarantine moves, purges or restores were attempted."
    printf '%s\n' "$storage_reason" >&2
    if [[ ! -e "$storage_marker" && -x "$NOTIFY" ]] && is_true "$SEND_NOTIFICATIONS"; then
      if "$NOTIFY" -i alert -s "SABnzbd Cleanup" -d "Storage preflight failed" -m "$storage_reason" >/dev/null 2>&1; then : >"$storage_marker"; fi
    fi
    return 1
  fi
  mkdir -p -- "$LOG_DIR" || {
    printf 'Unable to create log directory: %s\n' "$LOG_DIR" >&2
    exit 1
  }

  require_commands

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "INFO" "Another SABnzbd cleanup run is active; exiting."
    exit 0
  fi

  RUN_INITIALIZED=true
  rotate_logs || die "Persistent logging initialization failed."
  ops_notification_state || die "Invalid notification state; existing outbox was preserved."
  TMP_DIR="$(mktemp -d '/tmp/sabnzbd_cleanup.XXXXXX')" || \
    die "Unable to create temporary directory."

  OPS_ATTENTION_FILE="$TMP_DIR/attention-details.txt"
  : >"$OPS_ATTENTION_FILE"
  SAB_HISTORY_FILE="$TMP_DIR/sab_history.json"
  SAB_QUEUE_FILE="$TMP_DIR/sab_queue.json"
  SONARR_QUEUE_FILE="$TMP_DIR/sonarr_queue.json"
  RADARR_QUEUE_FILE="$TMP_DIR/radarr_queue.json"

  if ! validate_common_environment; then
    die "Common configuration validation failed."
  fi
}

###############################################################################
# UNRAID MOVER GUARD
###############################################################################

mover_is_running() {
  is_true "$MOVER_GUARD_ENABLED" || return 1
  pgrep -f "$MOVER_PROCESS_PATTERN" >/dev/null 2>&1
}

notify_mover_skip() {
  # The finalizer includes the guard context and completed actions in the same
  # durable daily report; never send a second standalone Mover email.
  return 0
}

check_mover_guard() {
  local context="$1"

  mover_is_running || return 0

  MOVER_GUARD_TRIGGERED=true
  MOVER_GUARD_CONTEXT="$context"
  ((MOVER_PROTECTED++)) || true

  log "WARNING" "Unraid Mover is running at guard point '$context'."
  log "WARNING" "Stopping cleanup successfully; no further cleanup writes will be attempted."
  notify_mover_skip "$context"

  return 20
}

###############################################################################
# BACKUP RETENTION
###############################################################################

find_backup_candidates() {
  local backup_kind="$1"

  case "$backup_kind" in
    nzb)
      [[ -n "$NZB_BACKUP_DIR_REAL" ]] || return 0
      find "$NZB_BACKUP_DIR_REAL" \
        -type f \
        \( -iname '*.nzb' -o -iname '*.nzb.gz' \) \
        -mmin "+$((NZB_RETENTION_DAYS * 1440))" \
        -print0
      ;;
    application)
      find "$SAB_BACKUP_DIR_REAL" \
        -maxdepth 1 \
        -type f \
        -iname '*.zip' \
        -mmin "+$((APP_BACKUP_RETENTION_DAYS * 1440))" \
        -print0
      ;;
    *)
      return 2
      ;;
  esac
}

backup_candidate_is_contained() {
  local backup_kind="$1"
  local file="$2"
  local file_real
  local expected_root

  file_real="$(realpath -- "$file" 2>/dev/null)" || return 1

  case "$backup_kind" in
    nzb) expected_root="$NZB_BACKUP_DIR_REAL" ;;
    application) expected_root="$SAB_BACKUP_DIR_REAL" ;;
    *) return 1 ;;
  esac

  path_is_below "$file_real" "$expected_root"
}

process_backup_candidate() {
  local backup_kind="$1"
  local file="$2"
  local label
  local size
  local guard_status

  case "$backup_kind" in
    nzb) label="NZB backup" ;;
    application) label="application backup" ;;
    *) return 2 ;;
  esac

  if ! backup_candidate_is_contained "$backup_kind" "$file"; then
    ((ERRORS++)) || true
    log "ERROR" "Refusing ${label} outside its validated root: $file"
    return 1
  fi

  size="$(stat_size "$file")"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0

  case "$backup_kind" in
    nzb)
      ((NZB_BACKUPS_ELIGIBLE++)) || true
      ((NZB_BACKUP_BYTES += size)) || true
      ;;
    application)
      ((APP_BACKUPS_ELIGIBLE++)) || true
      ((APP_BACKUP_BYTES += size)) || true
      ;;
  esac

  if is_true "$DRY_RUN"; then
    log "INFO" "[DRY RUN] Would delete ${label}: $file"
    return 0
  fi

  check_mover_guard "before deleting ${label} ${file}"
  guard_status=$?
  (( guard_status == 0 )) || return "$guard_status"

  if rm -f -- "$file"; then
    BACKUP_DETAILS+=("Removed $backup_kind backup: $file ($(bytes_human "$size")); retention policy satisfied.")
    log "INFO" "Deleted ${label}: $file"
    case "$backup_kind" in
      nzb) ((NZB_BACKUPS_REMOVED++)) || true ;;
      application) ((APP_BACKUPS_REMOVED++)) || true ;;
    esac
    return 0
  fi

  ((ERRORS++)) || true
  log "ERROR" "Failed to delete ${label}: $file"
  return 1
}

cleanup_backup_class() {
  local backup_kind="$1"
  local file
  local candidate_status
  local class_failed=false

  local candidate_list="$TMP_DIR/backup-$backup_kind.list"
  if ! find_backup_candidates "$backup_kind" >"$candidate_list"; then
    log ERROR "Incomplete $backup_kind backup inventory; this backup class was preserved."
    return 1
  fi
  while IFS= read -r -d '' file; do
    process_backup_candidate "$backup_kind" "$file"
    candidate_status=$?

    if (( candidate_status == 20 )); then
      return 20
    elif (( candidate_status != 0 )); then
      class_failed=true
    fi
  done <"$candidate_list"

  ! is_true "$class_failed"
}

remove_empty_nzb_backup_directories() {
  local guard_status

  is_true "$DRY_RUN" && return 0
  [[ -n "$NZB_BACKUP_DIR_REAL" ]] || return 0

  check_mover_guard "before removing empty NZB backup directories"
  guard_status=$?
  (( guard_status == 0 )) || return "$guard_status"

  find "$NZB_BACKUP_DIR_REAL" \
    -mindepth 1 \
    -depth \
    -type d \
    -empty \
    -delete 2>/dev/null || true
}

cleanup_backups() {
  local operation_status
  local cleanup_failed=false

  log "DEBUG" "Cleaning SABnzbd backups."
  log "DEBUG" "NZB retention: ${NZB_RETENTION_DAYS}d"
  log "DEBUG" "Application backup retention: ${APP_BACKUP_RETENTION_DAYS}d"

  if [[ -n "$NZB_BACKUP_DIR_REAL" ]]; then
    cleanup_backup_class nzb
    operation_status=$?
    (( operation_status == 20 )) && return 20
    (( operation_status == 0 )) || cleanup_failed=true
  fi

  cleanup_backup_class application
  operation_status=$?
  (( operation_status == 20 )) && return 20
  (( operation_status == 0 )) || cleanup_failed=true

  remove_empty_nzb_backup_directories
  operation_status=$?
  (( operation_status == 20 )) && return 20

  ! is_true "$cleanup_failed"
}

###############################################################################
# API HELPERS
###############################################################################

curl_common_args() {
  printf '%s\0' \
    --silent \
    --show-error \
    --fail \
    --retry 2 \
    --retry-delay 1 \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time "$CURL_MAX_TIME"

  if ! is_true "$TLS_VERIFY"; then
    printf '%s\0' --insecure
  fi
}

run_curl() {
  local args=()
  while IFS= read -r -d '' arg; do
    args+=("$arg")
  done < <(curl_common_args)

  curl "${args[@]}" "$@"
}

sab_get() {
  local mode="$1"
  local output="$2"
  shift 2

  local query_args=(
    --get
    --data-urlencode "mode=$mode"
    --data-urlencode "output=json"
    --data-urlencode "apikey=$SAB_API_KEY"
  )

  local parameter
  for parameter in "$@"; do
    query_args+=(--data-urlencode "$parameter")
  done

  if ! run_curl "${query_args[@]}" "${SAB_URL%/}/api" -o "$output"; then
    return 1
  fi

  jq empty "$output" >/dev/null 2>&1
}

arr_get() {
  local url="$1"
  local api_key="$2"
  local output="$3"
  shift 3

  local query_args=(--get -H "X-Api-Key: $api_key")
  local parameter

  for parameter in "$@"; do
    query_args+=(--data-urlencode "$parameter")
  done

  if ! run_curl "${query_args[@]}" "$url" -o "$output"; then
    return 1
  fi

  jq empty "$output" >/dev/null 2>&1
}

fetch_sab_history() {
  local slots_file="$TMP_DIR/sab_history_slots.jsonl"
  : > "$slots_file"

  local start=0
  local page=0
  local count
  local output

  while (( page < SAB_HISTORY_MAX_PAGES )); do
    output="$TMP_DIR/sab_history_page_${page}.json"

    if ! sab_get history "$output" "start=$start" "limit=$SAB_HISTORY_PAGE_SIZE"; then
      return 1
    fi

    count="$(jq '.history.slots // [] | length' "$output" 2>/dev/null)" || return 1
    [[ "$count" =~ ^[0-9]+$ ]] || return 1

    jq -c '.history.slots[]?' "$output" >> "$slots_file" || return 1

    (( count == 0 )) && break

    start=$((start + count))
    page=$((page + 1))

    (( count < SAB_HISTORY_PAGE_SIZE )) && break
  done

  if (( page >= SAB_HISTORY_MAX_PAGES && count >= SAB_HISTORY_PAGE_SIZE )); then
    log "ERROR" "SAB history exceeded the configured pagination safety limit."
    return 1
  fi

  jq -s '.' "$slots_file" > "$SAB_HISTORY_FILE" || return 1
}

fetch_sab_queue() {
  sab_get queue "$SAB_QUEUE_FILE" "start=0" "limit=0" || return 1
  jq -e '.queue|type=="object" and (.slots|type)=="array" and ((.noofslots|tonumber) <= (.slots|length))' "$SAB_QUEUE_FILE" >/dev/null || {
    log ERROR "SAB queue is incomplete or invalid; stranded download cleanup is prohibited."
    return 1
  }
}

fetch_arr_queue() {
  local app="$1"
  local output="$2"
  local base_url
  local api_key
  local unknown_parameter

  case "$app" in
    Sonarr)
      base_url="$SONARR_URL"
      api_key="$SONARR_API_KEY"
      unknown_parameter="includeUnknownSeriesItems=true"
      ;;
    Radarr)
      base_url="$RADARR_URL"
      api_key="$RADARR_API_KEY"
      unknown_parameter="includeUnknownMovieItems=true"
      ;;
    *) return 1 ;;
  esac

  if ! arr_get \
    "${base_url%/}/api/v3/queue" \
    "$api_key" \
    "$output" \
    "page=1" \
    "pageSize=$ARR_QUEUE_PAGE_SIZE" \
    "$unknown_parameter"
  then
    return 1
  fi

  local loaded
  local total
  loaded="$(jq '.records // [] | length' "$output" 2>/dev/null)" || return 1
  total="$(jq '.totalRecords // (.records // [] | length)' "$output" 2>/dev/null)" || return 1

  [[ "$loaded" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || return 1

  if (( loaded < total )); then
    log "ERROR" "$app queue has $total records but only $loaded were loaded; refusing cleanup."
    return 1
  fi
}

fetch_arr_history_for_download() {
  local app="$1"
  local download_id="$2"
  local output="$3"
  local base_url
  local api_key

  case "$app" in
    Sonarr)
      base_url="$SONARR_URL"
      api_key="$SONARR_API_KEY"
      ;;
    Radarr)
      base_url="$RADARR_URL"
      api_key="$RADARR_API_KEY"
      ;;
    *) return 1 ;;
  esac

  if ! arr_get \
    "${base_url%/}/api/v3/history" \
    "$api_key" \
    "$output" \
    "page=1" \
    "pageSize=$ARR_HISTORY_PAGE_SIZE" \
    "sortKey=date" \
    "sortDirection=descending" \
    "downloadId=$download_id"
  then
    return 1
  fi

  local loaded
  local total
  loaded="$(jq '.records // [] | length' "$output" 2>/dev/null)" || return 1
  total="$(jq '.totalRecords // (.records // [] | length)' "$output" 2>/dev/null)" || return 1

  [[ "$loaded" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || return 1

  if (( loaded < total )); then
    log "WARNING" "$app history for download ID '$download_id' was truncated ($loaded/$total)."
    return 1
  fi
}

fetch_required_state() {
  log "INFO" "Fetching SABnzbd history and queue."
  if ! fetch_sab_history; then
    ((ERRORS++)) || true
    log "ERROR" "Unable to fetch complete SABnzbd history. Stranded cleanup was skipped."
    return 1
  fi
  if ! fetch_sab_queue; then
    ((ERRORS++)) || true
    log "ERROR" "Unable to fetch SABnzbd queue. Stranded cleanup was skipped."
    return 1
  fi

  if is_true "$SONARR_ENABLED"; then
    log "INFO" "Fetching Sonarr Activity queue."
    if ! fetch_arr_queue Sonarr "$SONARR_QUEUE_FILE"; then
      ((ERRORS++)) || true
      log "ERROR" "Unable to fetch complete Sonarr queue. Stranded cleanup was skipped."
      return 1
    fi
  else
    printf '{"records":[],"totalRecords":0}\n' > "$SONARR_QUEUE_FILE"
  fi

  if is_true "$RADARR_ENABLED"; then
    log "INFO" "Fetching Radarr Activity queue."
    if ! fetch_arr_queue Radarr "$RADARR_QUEUE_FILE"; then
      ((ERRORS++)) || true
      log "ERROR" "Unable to fetch complete Radarr queue. Stranded cleanup was skipped."
      return 1
    fi
  else
    printf '{"records":[],"totalRecords":0}\n' > "$RADARR_QUEUE_FILE"
  fi
}

refresh_active_state() {
  fetch_sab_queue || return 1

  if is_true "$SONARR_ENABLED"; then
    fetch_arr_queue Sonarr "$SONARR_QUEUE_FILE" || return 1
  fi

  if is_true "$RADARR_ENABLED"; then
    fetch_arr_queue Radarr "$RADARR_QUEUE_FILE" || return 1
  fi
}

###############################################################################
# TIME / QUEUE HELPERS
###############################################################################

date_to_epoch() {
  local value="$1"
  local normalized

  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
    return 0
  fi

  if date -d "$value" '+%s' >/dev/null 2>&1; then
    date -d "$value" '+%s'
    return 0
  fi

  normalized="${value%%.*}"
  normalized="${normalized%Z}"

  date -j -u -f '%Y-%m-%dT%H:%M:%S' "$normalized" '+%s' 2>/dev/null || printf '0'
}

sab_completed_epoch() {
  local item="$1"
  local value

  value="$(jq -r '.completed // .completed_time // .completedTime // .completionTime // ""' <<<"$item")"
  date_to_epoch "$value"
}

queue_contains_download() {
  local queue_file="$1"
  local download_id="$2"

  jq -e \
    --arg id "$download_id" \
    'any(.records[]?; ((.downloadId // "") | ascii_downcase) == ($id | ascii_downcase))' \
    "$queue_file" >/dev/null 2>&1
}

sab_queue_contains_download() {
  local download_id="$1"

  jq -e \
    --arg id "$download_id" \
    'any(.queue.slots[]?; ((.nzo_id // "") | ascii_downcase) == ($id | ascii_downcase))' \
    "$SAB_QUEUE_FILE" >/dev/null 2>&1
}

download_is_active_anywhere() {
  local download_id="$1"

  sab_queue_contains_download "$download_id" || \
    queue_contains_download "$SONARR_QUEUE_FILE" "$download_id" || \
    queue_contains_download "$RADARR_QUEUE_FILE" "$download_id"
}

###############################################################################
# PATH HELPERS
###############################################################################

owner_for_category() {
  local category="${1,,}"

  if [[ "$category" == "${SAB_TV_CATEGORY,,}" ]]; then
    printf 'Sonarr'
  elif [[ "$category" == "${SAB_MOVIE_CATEGORY,,}" ]]; then
    printf 'Radarr'
  fi
}

root_for_owner() {
  case "$1" in
    Sonarr) printf '%s' "$SAB_TV_DIR_REAL" ;;
    Radarr) printf '%s' "$SAB_MOVIE_DIR_REAL" ;;
  esac
}

library_roots_for_owner() {
  case "$1" in
    Sonarr) printf '%s' "$SONARR_LIBRARY_ROOTS" ;;
    Radarr) printf '%s' "$RADARR_LIBRARY_ROOTS" ;;
  esac
}

path_maps_for_owner() {
  case "$1" in
    Sonarr) printf '%s' "$SONARR_IMPORT_PATH_MAPS" ;;
    Radarr) printf '%s' "$RADARR_IMPORT_PATH_MAPS" ;;
  esac
}

resolve_sab_path() {
  local item="$1"
  local root="$2"
  local storage
  local name
  local candidate=""
  local relative
  local resolved

  storage="$(jq -r '.storage // .path // ""' <<<"$item")"
  name="$(jq -r '.name // .nzb_name // ""' <<<"$item")"

  if [[ -n "$storage" && -e "$storage" ]]; then
    candidate="$storage"
  elif [[ -n "$storage" && -n "$SAB_CONTAINER_COMPLETE_ROOT" && \
          ( "$storage" == "$SAB_CONTAINER_COMPLETE_ROOT" || "$storage" == "$SAB_CONTAINER_COMPLETE_ROOT"/* ) ]]; then
    relative="${storage#"$SAB_CONTAINER_COMPLETE_ROOT"}"
    candidate="${SAB_COMPLETE_ROOT%/}${relative}"
  elif [[ -n "$storage" ]]; then
    candidate="${root%/}/$(basename -- "${storage%/}")"
  elif [[ -n "$name" ]]; then
    candidate="${root%/}/$name"
  else
    return 1
  fi

  [[ -e "$candidate" ]] || return 1
  [[ ! -L "$candidate" ]] || return 1

  resolved="$(realpath -- "$candidate")" || return 1
  path_is_below "$resolved" "$root" || return 1

  printf '%s' "$resolved"
}

resolve_imported_path() {
  local owner="$1"
  local reported="$2"
  local candidate=""
  local resolved
  local mappings
  local mapping
  local from
  local to
  local roots
  local root
  local allowed=false

  if [[ -e "$reported" ]]; then
    candidate="$reported"
  else
    mappings="$(path_maps_for_owner "$owner")"
    local mapping_list=()
    IFS=';' read -r -a mapping_list <<<"$mappings"

    for mapping in "${mapping_list[@]}"; do
      [[ "$mapping" == *'|'* ]] || continue
      from="${mapping%%|*}"
      to="${mapping#*|}"
      [[ -n "$from" && -n "$to" ]] || continue

      if [[ "$reported" == "$from" || "$reported" == "$from"/* ]]; then
        candidate="${to%/}${reported#"$from"}"
        [[ -e "$candidate" ]] && break
        candidate=""
      fi
    done
  fi

  [[ -n "$candidate" && -f "$candidate" ]] || return 1

  resolved="$(realpath -- "$candidate")" || return 1
  roots="$(library_roots_for_owner "$owner")"

  local root_list=()
  IFS=';' read -r -a root_list <<<"$roots"

  for root in "${root_list[@]}"; do
    [[ -d "$root" ]] || continue
    root="$(realpath -- "$root")" || continue
    if path_is_below "$resolved" "$root"; then
      allowed=true
      break
    fi
  done

  is_true "$allowed" || return 1

  local size
  size="$(stat_size "$resolved")"
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  (( size > 0 )) || return 1

  printf '%s' "$resolved"
}

newest_path_mtime() {
  find "$1" -xdev -printf '%T@\n' | awk 'BEGIN{max=0} $1>max {max=$1} END{printf "%.0f",max}'
}

path_is_stable() {
  local path="$1"
  local newest
  local cutoff

  newest="$(newest_path_mtime "$path")"
  [[ "$newest" =~ ^[0-9]+$ ]] || return 1
  (( newest > 0 )) || return 1

  cutoff=$(( $(date '+%s') - MIN_PATH_STABLE_HOURS * 3600 ))
  (( newest <= cutoff ))
}

path_size() {
  if [[ -f "$1" ]]; then stat_size "$1"; return; fi
  find "$1" -xdev -type f -printf '%s\n' | awk '{n+=$1} END{printf "%.0f",n+0}'
}

source_media_count() {
  local path="$1"
  local count=0
  local file
  local base inventory
  inventory=$(mktemp "$TMP_DIR/source-media.XXXXXX") || return 1
  if [[ -f "$path" && ! -L "$path" ]]; then
    printf '%s\0' "$path" >"$inventory" || return 1
  elif [[ -d "$path" && ! -L "$path" ]]; then
    find "$path" -xdev -type f -print0 >"$inventory" || { rm -f -- "$inventory"; return 1; }
  else rm -f -- "$inventory"; return 1; fi

  while IFS= read -r -d '' file; do
    base="${file##*/}"
    base="${base,,}"

    case "$base" in
      *.mkv|*.mp4|*.m4v|*.avi|*.mov|*.ts|*.m2ts|*.wmv|*.webm)
        if [[ "$base" =~ (^|[._\ -])(sample|trailer)([._\ -]|$) ]]; then
          continue
        fi
        ((count++)) || true
        ;;
    esac
  done <"$inventory"
  rm -f -- "$inventory" || return 1

  printf '%s' "$count"
}

###############################################################################
# ARR IMPORT PROOF
###############################################################################

# A policy disposition is NOT an import. Accept only this monitor's durable,
# verified exact-ID receipt, with unchanged SAB identity and fresh Arr checks.
# It authorizes reversible quarantine only, never removal from the library.
# Durable receipts supplement native history; they never substitute a title
# match or a different current file. A rename is accepted only for the SAME ID.
verify_durable_import_receipt() {
  local owner="$1" download_id="${2,,}" source_path="$3" proof_file="$4" item="$5"
  local input="$TMP_DIR/import-receipt-job.json" receipt="$TMP_DIR/import-receipt.json" targets="$TMP_DIR/import-receipt-targets.jsonl"
  local root key target target_id parent_id file_id kind object="$TMP_DIR/receipt-object.json" media="$TMP_DIR/receipt-media.json"
  local paths="$TMP_DIR/receipt-paths.jsonl" resolved source_count count
  [[ -f "$IMPORT_RECEIPT_FILE" && ! -L "$IMPORT_RECEIPT_FILE" ]] || return 11
  printf '%s' "$item" >"$input" || return 11
  jq -e --arg app "$owner" --arg id "$download_id" --slurpfile job "$input" '
    select(.version==1) | .receipts[$app+":"+$id] | select(.app==$app and .downloadId==$id and .conflict!=true and
      .sab==($job[0]|{nzo_id,name,storage,completed,category}) and (.targets|type)=="object" and (.targets|length)>0)' "$IMPORT_RECEIPT_FILE" >"$receipt" || return 11
  case "$owner" in
    Sonarr) root="${SONARR_URL%/}/api/v3"; key="$SONARR_API_KEY"; kind=episode ;;
    Radarr) root="${RADARR_URL%/}/api/v3"; key="$RADARR_API_KEY"; kind=movie ;;
    *) return 11 ;;
  esac
  jq -c '.targets[]' "$receipt" >"$targets" || return 11
  : >"$paths"
  while IFS= read -r target; do
    target_id=$(jq -r '.targetId' <<<"$target"); parent_id=$(jq -r '.parentId' <<<"$target"); file_id=$(jq -r '.fileId' <<<"$target")
    [[ "$target_id" =~ ^[1-9][0-9]*$ && "$parent_id" =~ ^[1-9][0-9]*$ && "$file_id" =~ ^[1-9][0-9]*$ ]] || return 12
    jq -e --arg kind "$kind" '.kind==$kind' <<<"$target" >/dev/null || return 12
    arr_get "$root/$kind/$target_id" "$key" "$object" && arr_get "$root/${kind}file/$file_id" "$key" "$media" || return 10
    local target_input="$TMP_DIR/receipt-target.json"; printf '%s' "$target" >"$target_input"
    jq -e --slurpfile expected "$target_input" --arg kind "$kind" '
      $expected[0] as $e | .id==$e.targetId and .hasFile==true and
      (if $kind=="episode" then .episodeFileId==$e.fileId and .seriesId==$e.parentId and
        ($e.seasonNumber==null or .seasonNumber==$e.seasonNumber) and ($e.episodeNumber==null or .episodeNumber==$e.episodeNumber)
       else .movieFileId==$e.fileId end)' "$object" >/dev/null || return 12
    jq -e --argjson id "$file_id" --argjson parent "$parent_id" --arg kind "$kind" '.id==$id and .size>0 and
      (if $kind=="episode" then .seriesId==$parent else .movieId==$parent end) and (.path|type)=="string"' "$media" >/dev/null || return 12
    local external parent_object="$TMP_DIR/receipt-parent.json" parent_kind=movie
    external=$(jq -r '.parentExternalId // 0' <<<"$target")
    if [[ "$external" =~ ^[1-9][0-9]*$ ]]; then
      [[ "$kind" != episode ]] || parent_kind=series
      arr_get "$root/$parent_kind/$parent_id" "$key" "$parent_object" || return 10
      jq -e --argjson id "$parent_id" --argjson external "$external" --arg kind "$kind" '.id==$id and
        (if $kind=="episode" then .tvdbId==$external else .tmdbId==$external end)' "$parent_object" >/dev/null || return 12
    else
      # Older receipts without TVDB/TMDB identity can prove the original exact
      # path, but may not authorize a rename after database IDs were reused.
      jq -e --slurpfile expected "$target_input" '.path==$expected[0].pathAtImport' "$media" >/dev/null || return 12
    fi
    resolved=$(resolve_imported_path "$owner" "$(jq -r '.path' "$media")") || return 12
    jq -nc --arg path "$resolved" '$path' >>"$paths" || return 12
  done <"$targets"
  source_count=$(source_media_count "$source_path") || return 13
  count=$(jq -s 'unique|length' "$paths") || return 12
  [[ "$source_count" =~ ^[0-9]+$ ]] && ((count>0 && count>=source_count)) || return 13
  jq -n --arg owner "$owner" --arg id "$download_id" --argjson count "$count" --argjson source "$source_count" \
    --slurpfile receipt "$receipt" --slurpfile paths "$paths" \
    '{proofKind:"durable-import-receipt",owner:$owner,downloadId:$id,importReceipt:$receipt[0],
      latestGrabEpoch:0,importEvents:($receipt[0].targets|length),verifiedImportedPaths:$count,
      remainingSourceMediaFiles:$source,importedPaths:($paths|unique)}' >"$proof_file"
}

verify_policy_disposition() {
  local owner="$1" download_id="${2,,}" source_path="$3" proof_file="$4" item="$5"
  local receipt="$TMP_DIR/policy-receipt.json" target="$TMP_DIR/policy-current-target.json" parent="$TMP_DIR/policy-current-parent.json"
  local root key kind target_id parent_id mode file_id file endpoint resolved source_count
  [[ -r "$POLICY_DISPOSITION_FILE" ]] || return 11
  local item_file="$TMP_DIR/policy-sab-item.json"
  printf '%s' "$item" >"$item_file" || return 11
  jq -e --arg id "$download_id" --arg app "$owner" --slurpfile sab_item "$item_file" '$sab_item[0] as $item |
    .actions[$id] | select(.downloadId==$id and .app==$app and .status=="done" and .queueVerified==true and
      (.mode=="redundant" or .mode=="replace") and
      .sab==($item|{nzo_id,name,storage,completed,category}))' "$POLICY_DISPOSITION_FILE" >"$receipt" || return 11
  kind=$(jq -r '.kind' "$receipt"); target_id=$(jq -r '.targetId' "$receipt"); parent_id=$(jq -r '.parentId' "$receipt"); mode=$(jq -r '.mode' "$receipt")
  [[ "$target_id" =~ ^[1-9][0-9]*$ && "$parent_id" =~ ^[1-9][0-9]*$ ]] || return 11
  case "$owner:$kind" in
    Sonarr:episode) root="${SONARR_URL%/}/api/v3"; key="$SONARR_API_KEY"; endpoint=series ;;
    Radarr:movie) root="${RADARR_URL%/}/api/v3"; key="$RADARR_API_KEY"; endpoint=movie ;;
    *) return 11 ;;
  esac
  source_count=$(source_media_count "$source_path") || return 13
  # A second video could be a partial pack/extra required episode: preserve.
  [[ "$source_count" =~ ^[01]$ ]] || return 13
  arr_get "$root/$kind/$target_id" "$key" "$target" && arr_get "$root/$endpoint/$parent_id" "$key" "$parent" || return 10
  jq -e --argjson id "$target_id" --argjson parent "$parent_id" --arg kind "$kind" --slurpfile receipt "$receipt" '.id==$id and .monitored==true and
    (if $kind=="episode" then .seriesId==$parent and .seasonNumber==$receipt[0].target.seasonNumber and .episodeNumber==$receipt[0].target.episodeNumber else true end)' "$target" >/dev/null || return 12
  jq -e --argjson id "$parent_id" '.id==$id and .monitored==true and (.tags|length)==0' "$parent" >/dev/null || return 12
  local imported='[]'
  if [[ "$mode" == redundant ]]; then
    file_id=$(jq -r '.fileId' "$receipt"); [[ "$file_id" =~ ^[1-9][0-9]*$ ]] || return 12
    jq -e --argjson file "$file_id" '(.episodeFileId // .movieFileId)==$file and .hasFile==true' "$target" >/dev/null || return 12
    file="$TMP_DIR/policy-existing-file.json"
    arr_get "$root/${kind}file/$file_id" "$key" "$file" || return 10
    jq -e --argjson id "$file_id" --argjson parent "$parent_id" --arg kind "$kind" --slurpfile receipt "$receipt" '.id==$id and .path==$receipt[0].filePath and
      (if $kind=="episode" then .seriesId==$parent else .movieId==$parent end)' "$file" >/dev/null || return 12
    resolved=$(resolve_imported_path "$owner" "$(jq -r '.path' "$file")") || return 12
    imported=$(jq -nc --arg path "$resolved" '[$path]') || return 12
  else
    # Rejection must still be followed by an explicitly accepted targeted search.
    jq -e '.commandId>0' "$receipt" >/dev/null || return 11
  fi
  jq -n --arg owner "$owner" --arg id "$download_id" --argjson paths "$imported" --argjson count "$source_count" --slurpfile receipt "$receipt" \
    '{proofKind:"policy-disposition",owner:$owner,downloadId:$id,policyReceipt:$receipt[0],importEvents:0,
      latestGrabEpoch:0,verifiedImportedPaths:($paths|length),remainingSourceMediaFiles:$count,importedPaths:$paths}' >"$proof_file"
}

verify_arr_import() {
  local owner="$1"
  local download_id="$2"
  local source_path="$3"
  local proof_file="$4"

  local history_file="$TMP_DIR/history_${SCANNED}.json"
  local imported_paths_file="$TMP_DIR/imported_paths_${SCANNED}.txt"
  local imported_paths_unique="$TMP_DIR/imported_paths_unique_${SCANNED}.txt"
  : > "$imported_paths_file"

  if ! fetch_arr_history_for_download "$owner" "$download_id" "$history_file"; then
    log "WARNING" "$owner history lookup failed for download ID: $download_id"
    return 10
  fi

  local latest_grab_epoch=0
  local record
  local record_id
  local event_type
  local event_date
  local event_epoch

  while IFS= read -r record; do
    record_id="$(jq -r '.downloadId // ""' <<<"$record")"
    [[ "${record_id,,}" == "${download_id,,}" ]] || continue

    event_type="$(jq -r '.eventType // ""' <<<"$record")"
    [[ "$event_type" == "grabbed" ]] || continue

    event_date="$(jq -r '.date // ""' <<<"$record")"
    event_epoch="$(date_to_epoch "$event_date")"
    [[ "$event_epoch" =~ ^[0-9]+$ ]] || event_epoch=0

    (( event_epoch > latest_grab_epoch )) && latest_grab_epoch="$event_epoch"
  done < <(jq -c '.records[]?' "$history_file")

  (( latest_grab_epoch > 0 )) || return 11

  local reported_path
  local resolved_path
  local import_events=0

  while IFS= read -r record; do
    record_id="$(jq -r '.downloadId // ""' <<<"$record")"
    [[ "${record_id,,}" == "${download_id,,}" ]] || continue

    event_type="$(jq -r '.eventType // ""' <<<"$record")"
    [[ "$event_type" == "downloadFolderImported" ]] || continue

    event_date="$(jq -r '.date // ""' <<<"$record")"
    event_epoch="$(date_to_epoch "$event_date")"
    [[ "$event_epoch" =~ ^[0-9]+$ ]] || event_epoch=0
    (( event_epoch >= latest_grab_epoch )) || continue

    ((import_events++)) || true
    reported_path="$(jq -r '.data.importedPath // ""' <<<"$record")"
    [[ -n "$reported_path" ]] || return 12

    resolved_path="$(resolve_imported_path "$owner" "$reported_path" || true)"
    [[ -n "$resolved_path" ]] || return 12
    printf '%s\n' "$resolved_path" >> "$imported_paths_file"
  done < <(jq -c '.records[]?' "$history_file")

  (( import_events > 0 )) || return 11

  sort -u -- "$imported_paths_file" > "$imported_paths_unique"

  local imported_count
  local source_count
  imported_count="$(wc -l < "$imported_paths_unique" | tr -d ' ')"
  source_count="$(source_media_count "$source_path")"

  [[ "$imported_count" =~ ^[0-9]+$ && "$source_count" =~ ^[0-9]+$ ]] || return 13
  (( imported_count > 0 )) || return 12
  (( imported_count >= source_count )) || return 13

  local imported_paths_json
  imported_paths_json="$(jq -R -s 'split("\n") | map(select(length > 0))' "$imported_paths_unique")" || return 12

  jq -n \
    --arg owner "$owner" \
    --arg downloadId "$download_id" \
    --argjson latestGrabEpoch "$latest_grab_epoch" \
    --argjson importEvents "$import_events" \
    --argjson verifiedImportedPaths "$imported_count" \
    --argjson remainingSourceMediaFiles "$source_count" \
    --argjson importedPaths "$imported_paths_json" \
    '{
      owner: $owner,
      downloadId: $downloadId,
      latestGrabEpoch: $latestGrabEpoch,
      importEvents: $importEvents,
      verifiedImportedPaths: $verifiedImportedPaths,
      remainingSourceMediaFiles: $remainingSourceMediaFiles,
      importedPaths: $importedPaths
    }' > "$proof_file"
}

proof_paths_still_valid() {
  local proof_file="$1"
  local imported_path
  local size

  while IFS= read -r imported_path; do
    [[ -n "$imported_path" && -f "$imported_path" ]] || return 1
    size="$(stat_size "$imported_path")"
    [[ "$size" =~ ^[0-9]+$ ]] || return 1
    (( size > 0 )) || return 1
  done < <(jq -r '.importedPaths[]?' "$proof_file")

  if jq -e '.proofKind=="policy-disposition" and .policyReceipt.mode=="replace"' "$proof_file" >/dev/null; then
    # Missing-media rejection has no imported destination. It remains protected
    # by the exact receipt, single-video inventory, path-idle and fresh queues.
    return 0
  fi
  jq -e '.importedPaths | length > 0' "$proof_file" >/dev/null 2>&1
}

###############################################################################
# QUARANTINE / PURGE
###############################################################################

quarantine_payload() {
  local owner="$1"
  local category="$2"
  local download_id="$3"
  local job_name="$4"
  local completed_epoch="$5"
  local source_path="$6"
  local size="$7"
  local proof_file="$8"

  local safe_id
  local safe_name
  local wrapper
  local payload_name
  local manifest

  safe_id="$(sanitize_component "$download_id")"
  safe_name="$(sanitize_component "$job_name")"
  [[ -n "$safe_id" ]] || safe_id="unknown-id"
  [[ -n "$safe_name" ]] || safe_name="unnamed-job"

  wrapper="${QUARANTINE_DIR_REAL}/items/${owner}/${safe_id}__${safe_name}"
  if [[ -e "$wrapper" ]]; then
    wrapper="${wrapper}__${RUN_ID}"
  fi

  LAST_QUARANTINE_DESTINATION="$wrapper/payload"
  payload_name="$(basename -- "$source_path")"
  manifest="${wrapper}/.sabnzbd-cleanup-manifest.json"

  if is_true "$DRY_RUN"; then
    log "INFO" "[DRY RUN] Would quarantine: $source_path"
    log "INFO" "[DRY RUN] Destination wrapper: $wrapper"
    return 0
  fi

  # This is deliberately the last check before the first quarantine write.
  # If Mover started after the initial scan, stop the entire run here.
  check_mover_guard "before quarantine move for ${download_id}" || return $?

  mkdir -p -- "$wrapper" || return 1

  local wrapper_real
  wrapper_real="$(realpath -- "$wrapper")" || return 1
  path_is_below "$wrapper_real" "${QUARANTINE_DIR_REAL}/items/${owner}" || return 1

  local source_device
  local destination_device
  source_device="$(stat_device "$source_path")"
  destination_device="$(stat_device "$wrapper")"

  if [[ -z "$source_device" || -z "$destination_device" || "$source_device" != "$destination_device" ]]; then
    log "ERROR" "Source and quarantine are not on the same filesystem: $source_path"
    rmdir -- "$wrapper" 2>/dev/null || true
    return 1
  fi

  local prepared="$wrapper/.manifest-prepared.$$" committed="$wrapper/.manifest-committed.$$"
  if ! jq -n --arg version "$VERSION" --arg runId "$RUN_ID" --arg quarantinedAt "$(timestamp)" \
    --arg owner "$owner" --arg category "$category" --arg downloadId "$download_id" --arg jobName "$job_name" \
    --arg originalPath "$source_path" --arg payloadName "$payload_name" --argjson completedEpoch "$completed_epoch" \
    --argjson bytes "$size" --argjson now "$(date +%s)" --slurpfile proof "$proof_file" \
    '{scriptVersion:$version,runId:$runId,state:"prepared",preparedEpoch:$now,quarantinedAt:$quarantinedAt,
      owner:$owner,category:$category,downloadId:$downloadId,jobName:$jobName,originalPath:$originalPath,
      payloadName:$payloadName,completedEpoch:$completedEpoch,bytes:$bytes,importProof:$proof[0]}' >"$prepared" ||
     ! ops_publish_checkpoint "$prepared" "$manifest"; then
      log ERROR "Cannot commit quarantine intent; source was preserved: $source_path"; return 1
  fi
  if ! mv -- "$source_path" "$wrapper/payload"; then
    log ERROR "Quarantine move was unsuccessful; recovery manifest retained: $manifest"; return 1
  fi
  normalize_quarantine_permissions "$wrapper" || return 1
  ops_flush_move "$source_path" "$wrapper/payload" || return 1
  jq --argjson now "$(date +%s)" '.state="committed" | .quarantinedEpoch=$now' "$manifest" >"$committed" &&
    ops_publish_checkpoint "$committed" "$manifest" || return 1
  normalize_quarantine_permissions "$manifest" || return 1

  return 0
}

validate_quarantine_manifest() {
  local wrapper="$1" manifest="$1/.sabnzbd-cleanup-manifest.json" real owner
  [[ -d "$wrapper" && ! -L "$wrapper" && -f "$manifest" && ! -L "$manifest" ]] || return 1
  real=$(realpath -- "$wrapper") || return 1
  owner=$(basename -- "$(dirname -- "$real")")
  [[ "$owner" == Sonarr || "$owner" == Radarr ]] || return 1
  path_is_below "$real" "$QUARANTINE_DIR_REAL/items/$owner" || return 1
  jq -e --arg owner "$owner" --arg movie "$SAB_MOVIE_DIR_REAL" --arg tv "$SAB_TV_DIR_REAL" '
    type=="object" and .owner==$owner
    and (.downloadId|type)=="string" and (.downloadId|length)>0
    and (.originalPath|type)=="string" and
      ((.originalPath|startswith($movie+"/")) or (.originalPath|startswith($tv+"/")))
    and (.bytes|type)=="number" and .bytes>=0
    and ((.state // "committed")=="committed" or .state=="prepared")
  ' "$manifest" >/dev/null
}

inspect_quarantines() {
  local root list manifest epoch age
  [[ -d "$QUARANTINE_DIR/items" && ! -L "$QUARANTINE_DIR" ]] || { printf 'No quarantine payloads found.\n'; return 0; }
  root=$(realpath -- "$QUARANTINE_DIR") || return 1
  exec 9>"$LOCK_FILE"; flock -n 9 || { printf 'Cleanup is active; inspection deferred.\n' >&2; return 1; }
  TMP_DIR=$(mktemp -d /tmp/sabnzbd_cleanup.XXXXXX) || return 1
  list="$TMP_DIR/inspect.list"
  find "$root/items" -mindepth 3 -maxdepth 3 -name '.sabnzbd-cleanup-manifest.json' -type f -print0 >"$list" || return 1
  while IFS= read -r -d '' manifest; do
    jq -c --arg wrapper "${manifest%/*}" --argjson now "$(date +%s)" \
      '{wrapper:$wrapper,job:.jobName,originalPath,state:(.state // "committed"),quarantinedAt,quarantinedEpoch,bytes,
        ageDays:(if (.quarantinedEpoch // 0)>0 then (($now-.quarantinedEpoch)/86400|floor) else null end)}' "$manifest" || return 1
  done <"$list"
}

restore_quarantine_payload() {
  OPS_QUARANTINE_ROOT="$QUARANTINE_DIR_REAL"
  OPS_RESTORE_ROOTS=("$SAB_MOVIE_DIR_REAL" "$SAB_TV_DIR_REAL")
  local operation_id
  local wrapper="$1" manifest="$1/.sabnzbd-cleanup-manifest.json" destination resolved
  check_mover_guard "before manual quarantine restore" || return $?
  validate_quarantine_manifest "$wrapper" || { log ERROR "Invalid restore manifest or unsafe wrapper: $wrapper"; return 1; }
  destination=$(jq -r '.originalPath' "$manifest")
  resolved=$(realpath -m -- "$destination") || return 1
  if ! { path_is_below "$resolved" "$SAB_MOVIE_DIR_REAL" || path_is_below "$resolved" "$SAB_TV_DIR_REAL"; }; then log ERROR "Restore path escapes completed-download roots: $destination"; return 1; fi
  [[ -e "$wrapper/payload" && ! -L "$wrapper/payload" && ! -e "$destination" && ! -L "$destination" ]] || { log ERROR "Restore refused: source missing/unsafe or destination already exists: $destination"; return 1; }
  if is_true "$DRY_RUN"; then log INFO "[DRY RUN] Would restore $wrapper/payload -> $destination"; return 0; fi
  mkdir -p -- "$PURGE_RECEIPT_DIR" "$(dirname -- "$destination")" || return 1
  jq -c --argjson at "$(date +%s)" '. + {auditEvent:"restore_intent",at:$at}' "$manifest" >>"$PURGE_RECEIPT_DIR/$RUN_ID.jsonl" || return 1
  operation_id=$(ops_operation_begin restore "$wrapper/payload" "$destination" "$PURGE_RECEIPT_DIR/$RUN_ID.jsonl") || { log ERROR "Cannot flush restore checkpoint; payload preserved."; return 1; }
  check_mover_guard "immediately before manual restore" || return $?
  ops_operation_paths_valid "$wrapper/payload" "$destination" || return 1
  mv -T -n -- "$wrapper/payload" "$destination" || return 1
  [[ ! -e "$wrapper/payload" && ! -L "$wrapper/payload" && -e "$destination" ]] || { log ERROR "Restore was not completed; existing paths and checkpoint preserved."; return 1; }
  jq -c --argjson at "$(date +%s)" '. + {auditEvent:"restore_verified",at:$at}' "$manifest" >>"$PURGE_RECEIPT_DIR/$RUN_ID.jsonl" || return 1
  ops_flush_move "$wrapper/payload" "$destination" || return 1
  ops_flush_file "$PURGE_RECEIPT_DIR/$RUN_ID.jsonl" || return 1
  ops_operation_finish "$operation_id" "Restore verified by successful move, source absence and destination presence" || return 1
  rm -f -- "$manifest"; rmdir -- "$wrapper" 2>/dev/null || true
  RECOVERY_DETAILS+=("Restored $destination from $wrapper/payload; existing destinations were not overwritten. Permissions outside quarantine were not changed.")
  ((RECOVERED++)) || true
  log INFO "Restored quarantined download: $destination"
}

recover_quarantine_preparations() {
  local manifests="$TMP_DIR/prepared-manifests.list" manifest wrapper source tmp payload_exists=false source_exists=false
  [[ -d "$QUARANTINE_DIR_REAL/items" ]] || return 0
  find "$QUARANTINE_DIR_REAL/items" -mindepth 3 -maxdepth 3 -name '.sabnzbd-cleanup-manifest.json' -type f -print0 >"$manifests" || return 1
  while IFS= read -r -d '' manifest; do
    jq -e '.state=="prepared"' "$manifest" >/dev/null || continue
    wrapper=${manifest%/*}
    validate_quarantine_manifest "$wrapper" || { log ERROR "Invalid interrupted quarantine was preserved: $wrapper"; ((ERRORS++)) || true; continue; }
    source=$(jq -r '.originalPath' "$manifest")
    if [[ -e "$wrapper/payload" && ! -e "$source" && ! -L "$source" ]]; then
      local recorded_size actual_size
      recorded_size=$(jq -r '.bytes' "$manifest"); actual_size=$(path_size "$wrapper/payload") || return 1
      if [[ "$recorded_size" != "$actual_size" ]]; then
        log ERROR "Interrupted payload size differs from its intent: $wrapper/payload; recorded=$recorded_size actual=$actual_size. Payload preserved for review."
        ((ERRORS++)) || true; continue
      fi
      check_mover_guard "before recovering quarantine intent" || return $?
      normalize_quarantine_permissions "$wrapper" || return 1
      tmp="$wrapper/.manifest-recovered.$$"
      jq --argjson now "$(date +%s)" '.state="committed" | .quarantinedEpoch=$now | .recovered=true' "$manifest" >"$tmp" && mv -f -- "$tmp" "$manifest" || return 1
      normalize_quarantine_permissions "$manifest" || return 1
      ((RECOVERED++)) || true
      RECOVERY_DETAILS+=("Recovered interrupted move: $source -> $wrapper/payload; manifest committed; retention restarted conservatively.")
    elif [[ -e "$source" && ! -e "$wrapper/payload" && ! -L "$wrapper/payload" ]]; then
      local extras="$TMP_DIR/prepared-extra.list"
      find "$wrapper" -mindepth 1 -maxdepth 1 ! -name '.sabnzbd-cleanup-manifest.json' -print -quit >"$extras" || return 1
      if [[ ! -s "$extras" ]]; then
        mkdir -p -- "$PURGE_RECEIPT_DIR" || return 1
        jq -c --argjson now "$(date +%s)" '. + {auditEvent:"interrupted_move_not_applied",auditedAt:$now}' "$manifest" >>"$PURGE_RECEIPT_DIR/$RUN_ID.jsonl" || return 1
        rm -f -- "$manifest" && rmdir -- "$wrapper" || return 1
        RECOVERY_DETAILS+=("Interrupted move did not occur: source preserved at $source; empty prepared wrapper removed; import proof will be reevaluated.")
        ((RECOVERED++)) || true
      else log ERROR "Interrupted quarantine contains unexpected entries; source and wrapper preserved: $wrapper"; ((ERRORS++)) || true; fi
    else
      log ERROR "Ambiguous interrupted move preserved: source=$source; quarantine=$wrapper/payload. Neither copy was overwritten or deleted."
      ((ERRORS++)) || true
    fi
  done <"$manifests"
}

purge_quarantine() {
  OPS_QUARANTINE_ROOT="$QUARANTINE_DIR_REAL"
  OPS_RESTORE_ROOTS=("$SAB_MOVIE_DIR_REAL" "$SAB_TV_DIR_REAL")
  local operation_id expired_receipts
  is_true "$PURGE_QUARANTINE" || return 0
  [[ -d "$QUARANTINE_DIR_REAL/items" ]] || return 0
  local wrappers="$TMP_DIR/purge-wrappers.list" candidates="$TMP_DIR/purge-candidates.tsv" wrapper manifest epoch at now size inventory receipt tmp count
  : >"$candidates"
  now=$(date +%s)
  mkdir -p -- "$PURGE_RECEIPT_DIR" || return 1
  if ! is_true "$DRY_RUN"; then
    expired_receipts="$TMP_DIR/old-receipts.list"
    find "$PURGE_RECEIPT_DIR" -maxdepth 1 -type f -name '*.jsonl' -mtime "+$PURGE_RECEIPT_RETENTION_DAYS" -print0 >"$expired_receipts" || return 1
    local old_receipt
    while IFS= read -r -d '' old_receipt; do
      ops_receipt_in_use "$old_receipt" && continue
      rm -f -- "$old_receipt" || return 1
    done <"$expired_receipts"
  fi
  find "$QUARANTINE_DIR_REAL/items" -mindepth 2 -maxdepth 2 -type d -print0 >"$wrappers" || return 1
  while IFS= read -r -d '' wrapper; do
    manifest="$wrapper/.sabnzbd-cleanup-manifest.json"
    if ! validate_quarantine_manifest "$wrapper"; then
      log WARNING "Quarantine preserved: missing/invalid manifest or unsafe path: $wrapper"; continue
    fi
    jq -e '(.state // "committed")=="committed"' "$manifest" >/dev/null || continue
    epoch=$(jq -r '.quarantinedEpoch // 0' "$manifest")
    if [[ ! "$epoch" =~ ^[0-9]+$ ]] || ((epoch<=0)); then
      at=$(jq -r '.quarantinedAt // ""' "$manifest"); epoch=$(date_to_epoch "$at")
    fi
    if [[ ! "$epoch" =~ ^[0-9]+$ ]] || ((epoch<=0 || epoch>now)); then
      log WARNING "Quarantine preserved: trustworthy quarantine timestamp unavailable: $wrapper"; continue
    fi
    (( now-epoch>=QUARANTINE_RETENTION_DAYS*86400 )) || continue
    printf '%s\t%s\n' "$epoch" "$wrapper" >>"$candidates"
  done <"$wrappers"
  sort -n "$candidates" -o "$candidates" || return 1
  receipt="$PURGE_RECEIPT_DIR/$RUN_ID.jsonl"
  while IFS=$'\t' read -r epoch wrapper; do
    [[ -n "$wrapper" ]] || continue
    check_mover_guard "before quarantine purge" || return $?
    validate_quarantine_manifest "$wrapper" || return 1
    inventory="$TMP_DIR/purge-inventory.raw"
    find "$wrapper" -xdev -type f -printf '%P\t%s\0' >"$inventory" || { log ERROR "Incomplete purge inventory; wrapper preserved: $wrapper"; return 1; }
    tmp="$TMP_DIR/purge-inventory.json"
    jq -Rs '[split("\u0000")[]|select(length>0)|capture("^(?<path>.*)\t(?<bytes>[0-9]+)$";"s")|.bytes|=tonumber]' "$inventory" >"$tmp" || return 1
    size=$(jq '[.[].bytes]|add // 0' "$tmp"); count=$(jq 'length' "$tmp")
    if ((size>MAX_PURGE_BYTES_PER_RUN)); then
      log WARNING "Oversized expired payload preserved: $wrapper; size=$(bytes_human "$size") exceeds MAX_PURGE_BYTES_PER_RUN=$(bytes_human "$MAX_PURGE_BYTES_PER_RUN"). Other eligible payloads will still be evaluated."
      continue
    fi
    if ((PURGED>=MAX_PURGES_PER_RUN || BYTES_PURGED+size>MAX_PURGE_BYTES_PER_RUN)); then
      log WARNING "Purge limit reached; retained additional expired payloads for the next run (count limit=$MAX_PURGES_PER_RUN, byte limit=$MAX_PURGE_BYTES_PER_RUN)."; break
    fi
    manifest="$wrapper/.sabnzbd-cleanup-manifest.json"
    if is_true "$DRY_RUN"; then
      PURGE_DETAILS+=("[DRY RUN] Would purge $(jq -r '.jobName // .downloadId' "$manifest"): $wrapper ($count files, $(bytes_human "$size")); manifest retention satisfied.")
      ((PURGED++)) || true; ((BYTES_PURGED+=size)) || true; continue
    fi
    jq -nc --slurpfile manifest "$manifest" --slurpfile files "$tmp" --arg wrapper "$wrapper" --argjson now "$now" \
      '{event:"purge_intent",at:$now,wrapper:$wrapper,manifest:$manifest[0],files:$files[0]}' >>"$receipt" || return 1
    operation_id=$(ops_operation_begin purge "$wrapper" "" "$receipt") || { log ERROR "Cannot flush purge checkpoint; payload preserved: $wrapper"; return 1; }
    check_mover_guard "immediately before quarantine deletion" || return $?
    if rm -rf --one-file-system -- "$wrapper" && [[ ! -e "$wrapper" && ! -L "$wrapper" ]]; then
      jq -nc --arg wrapper "$wrapper" --argjson now "$(date +%s)" '{event:"purge_verified",at:$now,wrapper:$wrapper}' >>"$receipt" || return 1
      ops_flush_directory "$(dirname -- "$wrapper")" || return 1
      ops_flush_file "$receipt" || return 1
      ops_operation_finish "$operation_id" "Purge verified: wrapper absent; files=$count bytes=$size" || return 1
      PURGE_DETAILS+=("Purged $wrapper: $count files, $(bytes_human "$size"); quarantine age=$(((now-epoch)/86400)) days; deletion verified.")
      ((PURGED++)) || true; ((BYTES_PURGED+=size)) || true
      log INFO "Purged quarantine: $wrapper; files=$count; bytes=$size; absence verified."
    else ((ERRORS++)) || true; log ERROR "Quarantine deletion incomplete; remaining entries preserved: $wrapper"; return 1; fi
  done <"$candidates"
}

###############################################################################
# MAIN CANDIDATE PROCESSING
###############################################################################

process_completed_jobs() {
  local item
  local status
  local category
  local owner
  local enabled
  local root
  local download_id
  local job_name
  local completed_epoch
  local age_hours
  local source_path
  local size
  local proof_file
  local proof_status
  local verified_paths
  local source_media
  local quarantine_status

  log "INFO" "Evaluating completed SABnzbd jobs."

  while IFS= read -r item; do
    ((SCANNED++)) || true

    status="$(jq -r '.status // ""' <<<"$item")"
    [[ "${status,,}" == "completed" ]] || continue
    ((COMPLETED_SCANNED++)) || true

    category="$(jq -r '.category // ""' <<<"$item")"
    owner="$(owner_for_category "$category")"
    [[ -n "$owner" ]] || continue

    case "$owner" in
      Sonarr) enabled="$SONARR_ENABLED" ;;
      Radarr) enabled="$RADARR_ENABLED" ;;
      *) enabled=false ;;
    esac

    if ! is_true "$enabled"; then
      ((SAFETY_SKIPPED++)) || true
      log "INFO" "Skipping $owner category because that integration is disabled: $category"
      continue
    fi

    download_id="$(jq -r '.nzo_id // ""' <<<"$item")"
    job_name="$(jq -r '.name // .nzb_name // "Unknown"' <<<"$item")"

    if [[ -z "$download_id" ]]; then
      ((SAFETY_SKIPPED++)) || true
      log "WARNING" "Skipping completed job without a download ID: $job_name"
      continue
    fi

    completed_epoch="$(sab_completed_epoch "$item")"
    [[ "$completed_epoch" =~ ^[0-9]+$ ]] || completed_epoch=0

    if (( completed_epoch <= 0 )); then
      ((SAFETY_SKIPPED++)) || true
      log "WARNING" "Skipping job with unknown completion time: $job_name"
      continue
    fi

    age_hours=$(( ($(date '+%s') - completed_epoch) / 3600 ))
    (( age_hours >= 0 )) || age_hours=0

    if (( age_hours < MIN_COMPLETED_AGE_HOURS )); then
      ((TOO_YOUNG++)) || true
      continue
    fi

    if download_is_active_anywhere "$download_id"; then
      ((QUEUE_PROTECTED++)) || true
      log "INFO" "Queue-protected completed job: $job_name [$download_id]"
      continue
    fi

    root="$(root_for_owner "$owner")"
    source_path="$(resolve_sab_path "$item" "$root" || true)"

    if [[ -z "$source_path" || ! -e "$source_path" ]]; then
      ((PATH_MISSING++)) || true
      continue
    fi

    if ! path_is_stable "$source_path"; then
      ((PATH_UNSTABLE++)) || true
      log "INFO" "Recently changed path remains protected: $source_path"
      continue
    fi

    proof_file="$TMP_DIR/proof_${SCANNED}.json"
    verify_arr_import "$owner" "$download_id" "$source_path" "$proof_file"
    proof_status=$?
    if ((proof_status!=0)); then
      # Fresh exact-ID APIs and physical destination checks remain mandatory.
      # An unavailable/pruned history endpoint alone no longer discards proof.
      if verify_durable_import_receipt "$owner" "$download_id" "$source_path" "$proof_file" "$item"; then
        proof_status=0
      fi
    fi
    if [[ "$proof_status" == 11 ]]; then
      verify_policy_disposition "$owner" "$download_id" "$source_path" "$proof_file" "$item"
      proof_status=$?
    fi

    case "$proof_status" in
      0) ;;
      10|11)
        ((HISTORY_UNPROVEN++)) || true
        log "INFO" "Import history not proven; preserving: $job_name [$download_id]"
        continue
        ;;
      12)
        ((DESTINATION_UNVERIFIED++)) || true
        log "WARNING" "Imported library destination not verified; preserving: $job_name [$download_id]"
        continue
        ;;
      13)
        ((SOURCE_UNACCOUNTED++)) || true
        log "WARNING" "Remaining source media not fully accounted for; preserving: $job_name [$download_id]"
        continue
        ;;
      *)
        ((SAFETY_SKIPPED++)) || true
        log "WARNING" "Unexpected import-proof result $proof_status; preserving: $job_name [$download_id]"
        continue
        ;;
    esac

    # Recheck mutable filesystem state immediately before declaring
    # eligibility. Execute mode also refreshes all live queues so an API
    # snapshot cannot become stale during a long run.
    if ! proof_paths_still_valid "$proof_file"; then
      ((DESTINATION_UNVERIFIED++)) || true
      log "WARNING" "Imported destination changed during validation; preserving: $job_name [$download_id]"
      continue
    fi

    if ! is_true "$DRY_RUN" && ! refresh_active_state; then
      ((ERRORS++)) || true
      ((SAFETY_SKIPPED++)) || true
      log "ERROR" "Unable to refresh active queues; preserving: $job_name [$download_id]"
      continue
    fi

    if download_is_active_anywhere "$download_id" || \
       [[ ! -e "$source_path" || -L "$source_path" ]] || \
       ! path_is_below "$(realpath -- "$source_path" 2>/dev/null || true)" "$root" || \
       ! path_is_stable "$source_path"
    then
      ((QUEUE_PROTECTED++)) || true
      log "INFO" "Candidate changed during validation; preserving: $job_name [$download_id]"
      continue
    fi

    verified_paths="$(jq -r '.verifiedImportedPaths' "$proof_file")"
    source_media="$(jq -r '.remainingSourceMediaFiles' "$proof_file")"
    size="$(path_size "$source_path")"
    [[ "$size" =~ ^[0-9]+$ ]] || size=0

    ((ELIGIBLE++)) || true
    ((BYTES_ELIGIBLE += size)) || true

    log "DEBUG" "------------------------------------------------------------"
    log "DEBUG" "Verified stranded completed download"
    log "DEBUG" "Owner: $owner"
    log "DEBUG" "Category: $category"
    log "DEBUG" "Release: $job_name"
    log "DEBUG" "Download ID: $download_id"
    log "DEBUG" "Completed age: ${age_hours}h"
    log "DEBUG" "Source path: $source_path"
    log "DEBUG" "Source size: $(bytes_human "$size")"
    log "DEBUG" "Verified imported paths: $verified_paths"
    log "DEBUG" "Remaining source media files: $source_media"

    if (( MAX_QUARANTINES_PER_RUN > 0 && QUARANTINED >= MAX_QUARANTINES_PER_RUN )) && ! is_true "$DRY_RUN"; then
      log "WARNING" "Per-run quarantine limit reached; preserving remaining candidates."
      continue
    fi

    quarantine_payload \
      "$owner" \
      "$category" \
      "$download_id" \
      "$job_name" \
      "$completed_epoch" \
      "$source_path" \
      "$size" \
      "$proof_file"
    quarantine_status=$?

    if (( quarantine_status == 0 )); then
      ((QUARANTINED++)) || true
      ((BYTES_QUARANTINED += size)) || true
      QUARANTINE_DETAILS+=("Quarantined [$owner] $job_name: $source_path -> $LAST_QUARANTINE_DESTINATION ($(bytes_human "$size")); $(jq -r 'if .proofKind=="policy-disposition" then "verified policy disposition (not an import)" elif .proofKind=="durable-import-receipt" then "durable exact-file import proof (current paths revalidated)" else "exact import proof" end' "$proof_file") and fresh queue protections passed.")

      if is_true "$DRY_RUN"; then
        log "INFO" "Action: dry-run candidate only"
      else
        log "INFO" "Action: moved to quarantine"
      fi
    elif (( quarantine_status == 20 )); then
      return 20
    else
      ((ERRORS++)) || true
      log "ERROR" "Failed to quarantine: $source_path"
    fi
  done < <(jq -c '.[]?' "$SAB_HISTORY_FILE")
}

###############################################################################
# NOTIFICATION / SUMMARY
###############################################################################

notify_summary() {
  NOTIFICATION_FINALIZED=true
  is_true "$SEND_NOTIFICATIONS" || return 0
  if is_true "$DRY_RUN" && ! is_true "$NOTIFY_DRY_RUN"; then return 0; fi
  local changed=$((NZB_BACKUPS_REMOVED+APP_BACKUPS_REMOVED+QUARANTINED+PURGED+RECOVERED))
  local warnings="$OPS_ATTENTION_DETAILS" signature previous="" mode="EXECUTE" importance=normal message detail shown=0
  if [[ -s "${OPS_ATTENTION_FILE:-}" ]]; then warnings=$(cat "$OPS_ATTENTION_FILE"); fi
  signature=$(printf '%s' "$BACKUP_CLEANUP_STATUS|$STRANDED_CLEANUP_STATUS|$QUARANTINE_PURGE_STATUS|$warnings" | sha256sum | cut -d ' ' -f1)
  previous=$(jq -r '.lastAttentionSignature // ""' "$OPS_NOTIFICATION_STATE" 2>/dev/null || true)
  local kind=action topic_status=healthy queued_attention=false
  jq -e 'any(.outbox[]?;.topic=="sab-cleanup" and (.kind=="attention" or .kind=="resolved"))' "$OPS_NOTIFICATION_STATE" >/dev/null && queued_attention=true
  if [[ -n "$warnings" || "$ERRORS" != 0 ]]; then topic_status=attention; fi
  ops_set_topic sab-cleanup "$topic_status" "status=$topic_status; backup=$BACKUP_CLEANUP_STATUS; downloads=$STRANDED_CLEANUP_STATUS; purge=$QUARANTINE_PURGE_STATUS; errors=$ERRORS" || return 1
  if (( changed==0 && ERRORS==0 )) && [[ -z "$warnings" && -z "$previous" && "$queued_attention" != true ]]; then return 0; fi
  if ((changed==0)); then if [[ "$topic_status" == attention ]]; then kind=attention; else kind=resolved; fi; fi
  if (( changed==0 )) && [[ -n "$warnings" && "$signature" == "$previous" ]]; then return 0; fi
  is_true "$DRY_RUN" && mode="DRY RUN"
  (( ERRORS==0 )) || importance=alert
  [[ -z "$warnings" || "$importance" == alert ]] || importance=warning
  message="SABnzbd Cleanup v$VERSION | Mode: $mode"$'\n'
  message+="Backup cleanup: $BACKUP_CLEANUP_STATUS; removed $NZB_BACKUPS_REMOVED NZB backup(s), $APP_BACKUPS_REMOVED application backup(s), $(bytes_human "$((NZB_BACKUP_BYTES+APP_BACKUP_BYTES))") eligible."$'\n'
  message+="Completed downloads: $STRANDED_CLEANUP_STATUS; quarantined $QUARANTINED payload(s), $(bytes_human "$BYTES_QUARANTINED")."$'\n'
  message+="Quarantine purge: $QUARANTINE_PURGE_STATUS; purged $PURGED payload(s), $(bytes_human "$BYTES_PURGED"). Recovered interrupted actions: $RECOVERED."$'\n'
  message+="Protected/skipped: active queue=$QUEUE_PROTECTED; recently changed=$PATH_UNSTABLE; import history unproven=$HISTORY_UNPROVEN; destination unverified=$DESTINATION_UNVERIFIED; source media unaccounted=$SOURCE_UNACCOUNTED; Mover stops=$MOVER_PROTECTED. Errors: $ERRORS."$'\n'
  for detail in "${RECOVERY_DETAILS[@]}" "${QUARANTINE_DETAILS[@]}" "${PURGE_DETAILS[@]}" "${BACKUP_DETAILS[@]}"; do
    message+=$'\n'"- $detail"; shown=$((shown+1))
  done
  if [[ -n "$warnings" ]]; then message+=$'\n\n'"Exceptions and preserved items:"$'\n'"$warnings"; fi
  if [[ -n "$previous" && -z "$warnings" && "$ERRORS" == 0 ]]; then message+=$'\n'"Recovery: previously reported cleanup exceptions are no longer present; configured checks completed."; fi
  ops_notify "$importance" "SABnzbd Cleanup" "Actions, recovery and protected downloads" "$message" sab-cleanup "$kind" || return 1
  if [[ "$OPS_NOTIFICATION_DELIVERED" == true ]]; then
    local tmp="$TMP_DIR/notification-state.json" new_signature=""
    [[ -z "$warnings" && "$ERRORS" == 0 ]] || new_signature="$signature"
    jq --arg signature "$new_signature" '.lastAttentionSignature=$signature' "$OPS_NOTIFICATION_STATE" >"$tmp" && mv -f -- "$tmp" "$OPS_NOTIFICATION_STATE" || return 1
  fi
}

log_detail_list() {
  local heading="$1"
  shift

  (( $# > 0 )) || return 0

  log "INFO" "$heading"

  local detail
  for detail in "$@"; do
    log "INFO" "  - $detail"
  done
}

print_summary() {
  log INFO "SUMMARY | backups=$BACKUP_CLEANUP_STATUS removed=$((NZB_BACKUPS_REMOVED+APP_BACKUPS_REMOVED)) | stranded=$STRANDED_CLEANUP_STATUS quarantined=$QUARANTINED bytes=$BYTES_QUARANTINED | purge=$QUARANTINE_PURGE_STATUS purged=$PURGED bytes=$BYTES_PURGED | recovered=$RECOVERED errors=$ERRORS runtime=$(runtime)"
  if [[ "${LOG_LEVEL^^}" == DEBUG ]]; then
    log_detail_list "Quarantine details:" "${QUARANTINE_DETAILS[@]}"
    log_detail_list "Purge details:" "${PURGE_DETAILS[@]}"
    log_detail_list "Recovery details:" "${RECOVERY_DETAILS[@]}"
  fi
}

###############################################################################
# ENTRY POINT
###############################################################################

main() {
  local operation_status
  local quarantine_ready=false

  CLI_OPERATION=""; CLI_WRAPPER=""; CLI_OPERATION_ID=""; CLI_OPERATION_NOTE=""
  parse_args "$@"
  if [[ "$CLI_OPERATION" == inspect ]]; then inspect_quarantines; return $?; fi
  if [[ "$CLI_OPERATION" == pending ]]; then ops_list_pending_operations; return $?; fi
  initialize || return 1
  if [[ "$CLI_OPERATION" == resolve ]]; then
    ops_resolve_operation "$CLI_OPERATION_ID" "$CLI_OPERATION_NOTE" || return $?
    RECOVERED=1; RECOVERY_DETAILS+=("$OPS_RECOVERY_DETAILS")
    notify_summary; return $?
  fi
  if [[ -n "$CLI_OPERATION" ]]; then
    STRANDED_CLEANUP_STATUS="MANUAL_${CLI_OPERATION^^}"
    validate_stranded_environment || return 1
    prepare_quarantine_environment || return 1
    fetch_required_state || { log ERROR "Cannot validate active queues for restore; payload preserved."; return 1; }
    local restore_id
    restore_id=$(jq -r '.downloadId' "$CLI_WRAPPER/.sabnzbd-cleanup-manifest.json") || return 1
    if download_is_active_anywhere "$restore_id"; then log ERROR "Restore refused: exact download is active in an Arr/SAB queue ($restore_id)."; return 1; fi
    restore_quarantine_payload "$CLI_WRAPPER"
    return $?
  fi

  log "DEBUG" "Starting SABnzbd cleanup v${VERSION}."
  log "DEBUG" "DRY_RUN=$DRY_RUN | CLEAN_BACKUPS=$CLEAN_BACKUPS | CLEAN_STRANDED_DOWNLOADS=$CLEAN_STRANDED_DOWNLOADS | PURGE_QUARANTINE=$PURGE_QUARANTINE"
  log "DEBUG" "Mover guard enabled: $MOVER_GUARD_ENABLED"

  check_mover_guard "startup"
  operation_status=$?
  if (( operation_status == 20 )); then
    is_true "$CLEAN_BACKUPS" && BACKUP_CLEANUP_STATUS="MOVER_SKIPPED"
    is_true "$CLEAN_STRANDED_DOWNLOADS" && STRANDED_CLEANUP_STATUS="MOVER_SKIPPED"
    is_true "$PURGE_QUARANTINE" && QUARANTINE_PURGE_STATUS="MOVER_SKIPPED"
    print_summary
    return 0
  fi

  if is_true "$CLEAN_BACKUPS"; then
    if validate_backup_environment; then
      BACKUP_CLEANUP_STATUS="RUNNING"
      cleanup_backups
      operation_status=$?

      if (( operation_status == 20 )); then
        BACKUP_CLEANUP_STATUS="MOVER_STOPPED"
        is_true "$CLEAN_STRANDED_DOWNLOADS" && STRANDED_CLEANUP_STATUS="MOVER_SKIPPED"
        is_true "$PURGE_QUARANTINE" && QUARANTINE_PURGE_STATUS="MOVER_SKIPPED"
        print_summary
        return 0
      elif (( operation_status == 0 )); then
        BACKUP_CLEANUP_STATUS="COMPLETED"
      else
        BACKUP_CLEANUP_STATUS="COMPLETED_WITH_ERRORS"
      fi
    else
      BACKUP_CLEANUP_STATUS="SKIPPED_CONFIGURATION"
    fi
  fi

  if is_true "$CLEAN_STRANDED_DOWNLOADS" || is_true "$PURGE_QUARANTINE"; then
    if prepare_quarantine_environment; then
      quarantine_ready=true
      if [[ -z "$SAB_MOVIE_DIR_REAL" && -d "$SAB_MOVIE_DIR" ]]; then SAB_MOVIE_DIR_REAL=$(realpath -- "$SAB_MOVIE_DIR"); fi
      if [[ -z "$SAB_TV_DIR_REAL" && -d "$SAB_TV_DIR" ]]; then SAB_TV_DIR_REAL=$(realpath -- "$SAB_TV_DIR"); fi
      OPS_QUARANTINE_ROOT="$QUARANTINE_DIR_REAL"
      OPS_RESTORE_ROOTS=("$SAB_MOVIE_DIR_REAL" "$SAB_TV_DIR_REAL")
      if ! is_true "$DRY_RUN"; then
        local recovery_status=0
        ops_recover_operations || recovery_status=$?
        RECOVERED=$((RECOVERED+OPS_RECOVERED_COUNT))
        [[ -z "$OPS_RECOVERY_DETAILS" ]] || RECOVERY_DETAILS+=("$OPS_RECOVERY_DETAILS")
        if ((recovery_status!=0)); then ((ERRORS++)) || true; log ERROR "Pending purge/restore operations require review; further payload mutations stopped."; return 1; fi
      fi
      if ! is_true "$DRY_RUN"; then recover_quarantine_preparations || { ((ERRORS++)) || true; log ERROR "Interrupted quarantine recovery incomplete; preserved affected payloads."; }; fi
    else
      is_true "$CLEAN_STRANDED_DOWNLOADS" && STRANDED_CLEANUP_STATUS="SKIPPED_CONFIGURATION"
      is_true "$PURGE_QUARANTINE" && QUARANTINE_PURGE_STATUS="SKIPPED_CONFIGURATION"
    fi
  fi

  if is_true "$CLEAN_STRANDED_DOWNLOADS" && is_true "$quarantine_ready"; then
    log "DEBUG" "Minimum completed age: ${MIN_COMPLETED_AGE_HOURS}h"
    log "DEBUG" "Minimum path stability: ${MIN_PATH_STABLE_HOURS}h"

    if ! validate_stranded_environment; then
      STRANDED_CLEANUP_STATUS="SKIPPED_CONFIGURATION"
    elif ! fetch_required_state; then
      STRANDED_CLEANUP_STATUS="SKIPPED_API_FAILURE"
      ((ERRORS++)) || true
      log ERROR "Sonarr/Radarr/SAB API collection failed; completed-download payloads were preserved."
    else
      STRANDED_CLEANUP_STATUS="RUNNING"
      process_completed_jobs
      operation_status=$?

      if (( operation_status == 20 )); then
        STRANDED_CLEANUP_STATUS="MOVER_STOPPED"
        is_true "$PURGE_QUARANTINE" && QUARANTINE_PURGE_STATUS="MOVER_SKIPPED"
        print_summary
        return 0
      elif (( operation_status == 0 )); then
        STRANDED_CLEANUP_STATUS="COMPLETED"
      else
        ((ERRORS++)) || true
        STRANDED_CLEANUP_STATUS="COMPLETED_WITH_ERRORS"
        log "ERROR" "Completed-job processing failed with status $operation_status."
      fi
    fi
  fi

  if is_true "$PURGE_QUARANTINE" && is_true "$quarantine_ready"; then
    log "DEBUG" "Quarantine retention: ${QUARANTINE_RETENTION_DAYS}d"
    QUARANTINE_PURGE_STATUS="RUNNING"
    purge_quarantine
    operation_status=$?

    if (( operation_status == 20 )); then
      QUARANTINE_PURGE_STATUS="MOVER_STOPPED"
      print_summary
      return 0
    elif (( operation_status == 0 )); then
      QUARANTINE_PURGE_STATUS="COMPLETED"
    else
      ((ERRORS++)) || true
      QUARANTINE_PURGE_STATUS="FAILED"
      log "ERROR" "Quarantine purge failed with status $operation_status."
    fi
  fi

  print_summary
  notify_summary

  (( ERRORS == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
