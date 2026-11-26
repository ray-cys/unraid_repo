#!/bin/bash
# PRESENTATION: health-presentation.json separates current workflow errors from
# retained historical events. Maintenance availability/resume receipts describe
# backup deferrals without clearing issues or permitting pipeline mutations.
clearLog=true

# Read-only version lookup must return before state, API or automation setup.
if [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" == --version ]];then
    printf 'media_health_monitor.sh 3.28.0\n';exit 0
fi

###############################################################################
# ARR Health / Download / Import Monitor v3.28.0
#
# PURPOSE
# -------
# Monitoring and guarded policy remediation for Sonarr, Radarr, and Usenet:
# v3.28: one exact-ID Sonarr pack job; complete native per-video accounting,
# guarded Auto imports, bounded missing-episode searches and receipt-based
# per-file SAB quarantine. Unknown/required files prevent whole-pack rejection.
# --automation-status includes pack checkpoints and cleanup/replacement evidence.
# v3.21: bounded notifier with durable per-page acknowledgement in state.json;
# per-application change leases shared with media_cleanup/integrity recovery;
# per-request retry deadlines, persistent collector coverage and strict receipt
# contracts. Confirmed inactive targets close obsolete workflow alerts after two
# independent scans; absence of evidence never becomes an import/cancel claim.
# Health polls continue while automation waits for a lease. Four-hour mutation
# windows/budgets remain in force. Docker configuration/images are never edited.
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
# USE CASES / ROLE IN THE FOUR-SCRIPT WORKFLOW
# -------------------------------------------
# Use this script to distinguish real Arr/SAB service failures, blocked imports,
# expected four-hour batching, old abandoned download attempts, and cleanup residue.
# It combines native health, queues/history and exact download/file identities so
# one pipeline problem can produce a grouped explanation rather than an email
# from every affected application. It is a monitor with bounded recovery, not a
# replacement for every native notification or an unconditional repair tool.
#
#   SABnzbd -> Sonarr/Radarr -> verified library import
#                |                      |
#                +---- THIS SCRIPT -----+ -> issues, receipts, bounded recovery
#
#   media_cleanup.sh arr    -> library deletion/unmonitor/tag/sidecar handling
#   media_cleanup.sh quarantine -> metadata bin retention (/mnt/user/media/bin)
#   sabnzbd_cleanup.sh      -> SAB backup/full-payload retention (net/quarantine)
#
# THIS SCRIPT neither purges those bins nor performs their filesystem moves.
#
# PROCESS: NORMAL SCHEDULED RUN
# -----------------------------
# 1. Acquire the run lock, validate state and open a working transaction. Detect
#    earlier incomplete runs/schedule gaps and prepare the bounded log lifecycle.
# 2. Discover/poll enabled native APIs: Arr queue/health/status and SAB queue,
#    history/warnings/status/provider evidence. Incomplete collectors preserve
#    existing dependent issues instead of falsely declaring them resolved.
# 3. Audit quality/custom-format configuration and recover recorded request
#    outcomes. Evaluate eligible automation only under its timing/safety gates.
# 4. Classify every queue reason, group related symptoms by their primary cause,
#    and retain all reasons with the highest applicable severity. Recognize
#    intentional batch waits instead of treating every queued job as stalled.
# 5. Review recent native activity and capture durable import/file-ID receipts.
#    Bounded backfill/enrichment handles older jobs or omitted embedded metadata;
#    unverifiable evidence remains protected rather than invented.
# 6. Reconcile exact download flows through native terminal history or fresh exact
#    file records with stable two-scan evidence. Actual source/library filesystem
#    residue is a separate hourly audit, guarded by mounts, Mover and time budget.
# 7. Update issue lifecycles only where current evidence is complete, persist
#    state before notification, deliver grouped changes, and retain failed delivery
#    state. Prune eligible old resolved records and emit a compact health summary.
#
# CONTROLLED AUTOMATION / ACTION WINDOWS
# -------------------------------------
# The monitor runs every five minutes; NEW rejection/retry/search actions use the
# first ten minutes at 00:00/04:00/08:00/12:00/16:00/20:00 Asia/Singapore by default.
# Read-only monitoring/recovery continues outside those windows. Actual schedules
# are configured in User Scripts; the script's window is an additional action gate.
# All action types share two actions/run and four actions/rolling 24 hours.
#
# - Proven redundant release: ignore exact queue tracking only after verifying a
#   suitable existing file. Do not blocklist it or request another download.
# - Explicit below-minimum rejection with genuinely missing monitored media:
#   blocklist the exact release, preserve its payload, and submit one targeted
#   replacement search. Keep the original quality policy unchanged.
# - Explicit transient busy/locked import: after six hours and stable scans,
#   request a native Auto scan of the exact download/path. At most three attempts
#   per download, separated by at least four hours; never force a manual import.
# - Weekly missing-media survey: inspect a bounded rotating set of newly missing
#   eligible targets and use exact EpisodeSearch/MoviesSearch commands. The first
#   survey protects the existing missing backlog because prior Plex deletion
#   intent may no longer be provable from retained history.
# - Native profile/custom-format changes, including Recyclarr changes, produce a
#   four-hour hold. Invalid/inconsistent settings hold actions until corrected;
#   the script never lowers scores or rewrites profiles to make an import succeed.
#
# Exact IDs, current monitoring, queues, tags/holds, prior import/deletion evidence,
# stable observations and current profiles protect required media. Packs, mixed
# warnings and unsupported policy cases remain protected. A submitted/completed
# command is NOT proof of an import: report pending until exact fresh import/file
# proof is verified. Unknown request outcomes are not blindly replayed.
# ARR_AUTOMATION_ENABLED pauses new actions; POLICY_AUTOMATION_ENABLED separately
# controls rejection handling. Acknowledging an alert is notification management,
# not a replacement for configuring these automation controls.
#
# I/O / LIMITATIONS / WHEN REVIEW IS STILL NEEDED
# ----------------------------------------------
# Native health and database-file reconciliation do not directly stat media paths.
# The separate filesystem audit and actual native import scans can wake disks.
# Old ambiguous download attempts can remain REVIEW_REQUIRED; a stale warning is
# not proof of import/cancellation. Unknown blockers, conflicting proof and
# unverifiable mutations require review. New future native health sources are
# reported dynamically, but unknown import reasons are not automatically repaired.
# A permanently stopped script/host cannot send its own missed-schedule alert;
# the gap is detected only when the script executes again.
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
# the script creates one grouped batch rather than one email per issue. Large
# batches may be split into bounded pages by the notification size limits.
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
# Defaults: 5 MiB per active/rotated log, two backups, 30-day rotated-log
# retention and a 4 KiB line limit. Audit/intent files have separate retention.
#
#
# STATE / RECEIPTS / OPERATOR USE
# --------------------------------
# STATE_DIR defaults to /mnt/vault/cloud/logs/script/media_health_monitor.
# state.json/backups hold issue lifecycles, collector cursors and exact-flow state.
# policy-actions.json and automation-actions.json hold request intent/outcomes;
# import-receipts.json preserves exact native import/file IDs and stable external
# identity for later cleanup, including verified renames. Each receipt/journal
# has its own retention/recovery rules; unresolved proof is not disposable clutter.
# Batch dismissal previews/manifests live in batch-dismissals/. A preview writes
# both a readable TSV and an ACK-ID selection file. Batch execution requires the
# reviewed exact count, narrowing filters and an operator reason; it does not
# change Arr/SAB queues or media files. --ack only suppresses the current unchanged
# signature; it neither resolves the issue nor makes pipeline health healthy.
#
# Use /bin/bash for the User Scripts copy because Unraid flash may reject direct
# execution. Read-only inventory and notification-management examples:
#   monitor_script="/boot/config/plugins/user.scripts/scripts/media_health_monitor/script"
#   /bin/bash "$monitor_script" --help
#   /bin/bash "$monitor_script" --automation-status
#   /bin/bash "$monitor_script" --policy-actions
#   /bin/bash "$monitor_script" --list-active
#   /bin/bash "$monitor_script" --ack ACK_ID "reviewed; waiting for upstream fix"
#   /bin/bash "$monitor_script" --unack ACK_ID
#   /bin/bash "$monitor_script" --dismiss-download ACK_ID "intentional removal"
# Only dismiss a flow after verifying its intended disposition. Do not erase state
# or intent journals to silence an alert or repeat an unverified request. Full
# batch-preview/execute examples and safeguards are printed by --help.
#
#
# ARR-SIDE DETECTION
# ------------------
#   CF_REJECT_MINIMUM
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
# Monitoring is read-only except for the explicitly bounded native Arr command
# and policy-rejection workflows configured below. All payload disposal remains
# delegated to guarded quarantine scripts.
#
# This script NEVER:
#
#   - Deletes downloads
#   - Removes SAB history
#   - Removes non-allowlisted queue items or deletes download data
#   - Forces imports
#   - Marks non-allowlisted downloads failed
#   - Changes monitoring
#   - Changes quality profiles
#   - Changes Custom Formats
#
###############################################################################

# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="media_health_monitor"
# shellcheck shell=bash
# Embedded operations contract v2; generated into standalone User Scripts.
# Millisecond timing without spawning date on supported Bash; GNU fallback.
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

# Accept the original command, including its timeout, so producer-specific
# delivery/cooldown/acknowledgement semantics stay with the owning script.
usr_ops_notify() {
    local -a args=("$@")
    local i importance=normal summary='' message='' index=-1 status=UPDATE
    for ((i=0;i<${#args[@]};i++));do
        case "${args[$i]}" in
          -i) importance="${args[$((i+1))]:-normal}";;
          -d) summary="${args[$((i+1))]:-}";;
          -m) index=$((i+1));message="${args[$index]:-}";;
        esac
    done
    case "$importance" in alert|warning) status=ATTENTION;;esac
    if [[ "$message" != 'Status: '* ]];then
        message="Status: $status"$'\n'"Summary: $summary"$'\n\n'"Actions and findings:"$'\n'"${message:-$summary}"
        if ((index>=0));then args[$index]="$message";else args+=(-m "$message");fi
    fi
    # Every notifier has a termination escalation, including legacy callers.
    if [[ "${args[0]##*/}" == timeout ]];then
        if [[ " ${args[*]} " != *' --kill-after'* ]];then args=("${args[0]}" --kill-after=5 "${args[@]:1}");fi
    else args=(timeout --signal=TERM --kill-after=5 30 "${args[@]}");fi
    local delivery_rc=0
    "${args[@]}" || delivery_rc=$?
    usr_ops_delivery_record "$delivery_rc" "$importance" "$summary" "$message" "${args[@]}" || printf 'Notification delivery evidence could not be queued; producer failure remains active.\n' >&2
    return "$delivery_rc"
}

# Bounded local history for scripts previously dependent on the plugin console.
usr_ops_append_log() {
    local file="$1" line="$2" max="${3:-2097152}" i
    [[ -d "${file%/*}" && ! -L "$file" ]] || return 1
    for i in 1 2;do [[ ! -L "$file.$i" ]] || return 1;done
    find "${file%/*}" -maxdepth 1 -type f \( -name "${file##*/}.1" -o -name "${file##*/}.2" \) -mtime +29 -delete || return 1
    if [[ -f "$file" ]] && (( $(stat -c %s "$file")+${#line}+1>max ));then
        rm -f "$file.2";[[ ! -f "$file.1" ]] || mv "$file.1" "$file.2";mv "$file" "$file.1" || return 1
    fi
    printf '%s\n' "$line" >>"$file"
}


# Durable failed-delivery evidence for producers without their own outbox.
# Existing media/DNS/watchdog outboxes keep ownership of their delivery policy.
usr_ops_delivery_record() (
    local rc="$1" importance="$2" summary="$3" message="$4" subject='' i key root fd tmp
    shift 4
    case "${OPS_SCRIPT_ID:-}" in backup_boot_disk|backup_cache_appdata|backup_media_remote|backup_vault_remote|backup_restore_drill|media_plex_dbrepair) ;; *) return 0;; esac
    local -a original=("$@")
    local native_delivery=false arg export_fd ram="${USR_OPS_DELIVERY_RAM_ROOT:-/run/user-script-notification-outbox}"
    for arg in "${original[@]}";do [[ "$arg" != /usr/local/emhttp/webGui/scripts/notify ]] || native_delivery=true;done
    [[ "$native_delivery" == true || -n "${USR_OPS_DELIVERY_ROOT:-}" ]] || return 0
    for ((i=0;i<${#original[@]};i++));do [[ "${original[$i]}" != -s ]] || subject="${original[$((i+1))]:-}";done
    root="${USR_OPS_DELIVERY_ROOT:-/mnt/vault/cloud/logs/script/user_scripts_status/notification-outbox}"
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}"
    if ! mountpoint -q "${USR_OPS_VAULT_MOUNT:-/mnt/vault}" || ! flock -s -n "$export_fd";then root="$ram";fi
    [[ ! -L "$root" && $(realpath -m "$root") == "$root" ]] || return 1
    mkdir -p "$root" || return 1;chmod 700 "$root" || return 1
    exec {fd}>"${USR_OPS_DELIVERY_LOCK:-/run/user-script-delivery.lock}";flock -w 3 "$fd" || return 1
    key=$(printf '%s\0' "$OPS_SCRIPT_ID" "$importance" "$subject" "$summary" "$message"|sha256sum|cut -d ' ' -f1)
    if ((rc==0));then
        if [[ "$OPS_SCRIPT_ID" == backup_vault_remote && -n "${USR_OPS_DELIVERY_CONTEXT:-}" ]];then
            mkdir -p "$root/.delivery-receipts" || return 1
            tmp=$(mktemp "$root/.delivery-receipts/.accepted.XXXXXX") || return 1
            jq -n --arg context "$USR_OPS_DELIVERY_CONTEXT" --argjson at "$(date +%s)" '{schema:1,context:$context,acceptedAt:$at}' >"$tmp" && chmod 600 "$tmp" && mv "$tmp" "$root/.delivery-receipts/backup_vault_remote.json" || return 1
        fi
        rm -f -- "$root/$OPS_SCRIPT_ID.$key.json" "$ram/$OPS_SCRIPT_ID.$key.json";return
    fi
    (( $(find "$root" -maxdepth 1 -type f -name '*.json'|wc -l)<100 )) || [[ -f "$root/$OPS_SCRIPT_ID.$key.json" ]] || return 1
    tmp=$(mktemp "$root/.delivery.XXXXXX") || return 1
    trap 'rm -f -- "$tmp"' EXIT
    jq -n --arg context "${USR_OPS_DELIVERY_CONTEXT:-}" --arg id "$key" --arg script "$OPS_SCRIPT_ID" --arg importance "$importance" --arg subject "$subject" --arg summary "$summary" --arg message "$message" --argjson at "$(date +%s)" \
      '{schema:1,context:$context,id:$id,script:$script,importance:$importance,subject:$subject,summary:$summary,message:$message,queuedAt:$at}' >"$tmp" && chmod 600 "$tmp" && mv "$tmp" "$root/$OPS_SCRIPT_ID.$key.json"
)

usr_ops_vault_delivery_seen() {
    local context="$1" cutoff="${2:-0}" root file
    [[ -n "$context" ]] || return 1
    for root in "${USR_OPS_DELIVERY_ROOT:-/mnt/vault/cloud/logs/script/user_scripts_status/notification-outbox}" "${USR_OPS_DELIVERY_RAM_ROOT:-/run/user-script-notification-outbox}";do
        file="$root/.delivery-receipts/backup_vault_remote.json"
        [[ -f "$file" && ! -L "$file" ]] || continue
        jq -e --arg context "$context" --argjson cutoff "$cutoff" --argjson now "$(date +%s)" '.schema==1 and .context==$context and .acceptedAt>=$cutoff and .acceptedAt<=$now+300' "$file" >/dev/null 2>&1 && return 0
    done
    return 1
}

usr_ops_retry_deliveries() {
    local root="${USR_OPS_DELIVERY_ROOT:-/mnt/vault/cloud/logs/script/user_scripts_status/notification-outbox}" file count=0 subject summary message importance owner old_owner="${OPS_SCRIPT_ID:-}" rc=0
    local ram="${USR_OPS_DELIVERY_RAM_ROOT:-/run/user-script-notification-outbox}" digest old_context="${USR_OPS_DELIVERY_CONTEXT:-}" context
    [[ ! -L "$root" && ! -L "$ram" ]] || return 1
    [[ -d "$root" || -d "$ram" ]] || return 0
    while IFS= read -r -d '' file;do
        ((count<3)) || break
        jq -e '(.schema==1) and (.script|test("^(backup_(boot_disk|cache_appdata|media_remote|vault_remote|restore_drill)|media_plex_dbrepair)$")) and (.importance|IN("normal","warning","alert")) and all(.subject,.summary,.message;type=="string")' "$file" >/dev/null 2>&1 || continue
        owner=$(jq -r .script "$file");subject=$(jq -r .subject "$file");summary=$(jq -r .summary "$file");message=$(jq -r .message "$file");importance=$(jq -r .importance "$file")
        context=$(jq -r '.context // ""' "$file")
        if [[ "$owner" == backup_vault_remote ]] && usr_ops_vault_delivery_seen "$context" "$(jq -r .queuedAt "$file")";then rm -f -- "$file";continue;fi
        USR_OPS_DELIVERY_CONTEXT="$context"
        digest=$(sha256sum "$file"|cut -d ' ' -f1)
        OPS_SCRIPT_ID="$owner";count=$((count+1))
        if usr_ops_notify "${NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify}" -i "$importance" -s "$subject" -d "$summary" -m "$message";then
            if [[ -f "$file" && $(sha256sum "$file"|cut -d ' ' -f1) == "$digest" ]];then rm -f -- "$file";fi
        else rc=1;fi
        OPS_SCRIPT_ID="$old_owner";USR_OPS_DELIVERY_CONTEXT="$old_context"
    done < <(find "$root" "$ram" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null|sort -zu)
    return "$rc"
}

# Scheduled executions have an independent parent recording the final exit,
# after producer EXIT traps. CLI operations and sourced libraries are unchanged.
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

# Network observation after an accepted shutdown, never a power-state claim.
# No WOL or second poweroff is issued. Native maintenance checks remain upstream.
usr_ops_observe_shutdown() {
    local BACKUP_SSH_COMMAND_TIMEOUT=6
    local host="${REMOTE#*@}" deadline=$(( $(date +%s)+${REMOTE_SHUTDOWN_OBSERVE_SECONDS:-90} )) misses=0
    [[ "${REMOTE_SHUTDOWN_OBSERVE_SECONDS:-90}" != 0 ]] || { SHUTDOWN_RESULT=requested_observation_disabled;return 0; }
    while (( $(date +%s)<deadline ));do
        if timeout --kill-after=1 5 ping -c 1 -W 2 "$host" >/dev/null 2>&1 || backup_ssh true >/dev/null 2>&1;then misses=0
        else misses=$((misses+1));fi
        if ((misses>=3));then SHUTDOWN_RESULT=offline_observed;return 0;fi
        sleep 5
    done
    SHUTDOWN_RESULT=requested_still_reachable;REMOTE_SHUTDOWN_FAILED=1
    return 1
}
# END EMBEDDED OPERATIONS CONTRACT
# BEGIN EMBEDDED USER SCRIPTS CATALOG
# shellcheck shell=bash
# Shared User Scripts catalogue v1. Native schedule.json stays authoritative;
# readers also verify the live/restored script file. No schedule is executed.
usr_scripts_catalog() {
    local file="$1" root="${2:-$(dirname "$1")/scripts}" mode="${3:-live}" mapping='{}' native default_cron
    command -v php >/dev/null || { printf '{"schema":1,"valid":false,"detail":"Native PHP runtime unavailable"}\n';return 1; }
    if [[ "$mode" == live ]];then
        native=$(timeout --kill-after=2 8 crontab -c /etc/cron.d -l 2>/dev/null) || native=''
        default_cron=$(timeout --kill-after=2 8 crontab -l 2>/dev/null) || default_cron=''
        native+=$'\n'"$default_cron"
        mapping=$(awk 'NF>=6 && $0 !~ /^[[:space:]]*#/ && /run-parts/ {
          for(i=6;i<=NF;i++)if($i ~ /^\/etc\/cron\.(hourly|daily|weekly|monthly)$/){name=$i;sub(/^.*\./,"",name);print name "\t" $1 " " $2 " " $3 " " $4 " " $5}
        }' <<<"$native" | jq -Rsc 'split("\n")|map(select(length>0)|split("\t")|{key:.[0],value:.[1]})|from_entries') || return 1
    fi
    php /dev/stdin "$file" "$root" "$mode" "$mapping" "${USER_SCRIPTS_RUNNING_ROOT:-/tmp/user.scripts/running}" <<'US_CATALOG_PHP'
<?php
try {
    [$file,$root,$mode,$mapping,$runningRoot]=array_slice($argv,1);
    $mapping=json_decode($mapping,true,512,JSON_THROW_ON_ERROR);
    if(is_link($file)||!is_file($file)||!is_readable($file)||is_link($root)||!is_dir($root)||!is_readable($root))throw new RuntimeException('Schedule file or scripts directory unavailable');
    $raw=file_get_contents($file);$decoded=json_decode($raw,false,512,JSON_THROW_ON_ERROR);
    if(!is_object($decoded))throw new RuntimeException('Schedule root must be an object');
    $data=json_decode($raw,true,512,JSON_THROW_ON_ERROR);$sha=hash('sha256',$raw);$st=stat($root);
    $prefix='/boot/config/plugins/user.scripts/scripts/';$legacy='/usr/local/emhttp/plugins/user.scripts/scripts/';$jobs=[];$installed=[];$roles=[];
    $dir=opendir($root);if(!$dir)throw new RuntimeException('Script inventory unreadable');
    while(($name=readdir($dir))!==false){
        if($name==='.'||$name==='..')continue;$path=$root.'/'.$name.'/script';
        if(is_file($path)&&!is_link($path)&&!is_link(dirname($path))){if(!is_readable($path))throw new RuntimeException('Installed script unreadable');$installed[]=$name;$head=file_get_contents($path,false,null,0,65536);$roles[$name]=preg_match('/^OPS_SCRIPT_ID="([a-z0-9_]+)"\s*$/m',$head,$m)?$m[1]:$name;}
    }closedir($dir);sort($installed);
    $runningNames=[];$uncertainNames=[];
    if($mode==='live'&&is_dir($runningRoot))foreach(glob($runningRoot.'/*')?:[] as $marker){
        $name=basename($marker);if(!is_file($marker)||is_link($marker)||filesize($marker)>64)continue;
        $pid=trim(file_get_contents($marker));if(!ctype_digit($pid)||(int)$pid<=1||!is_dir('/proc/'.$pid))continue;
        $cmd=@file_get_contents('/proc/'.$pid.'/cmdline');if($cmd===false){$uncertainNames[]=$name;continue;}
        if(in_array('/tmp/user.scripts/tmpScripts/'.$name.'/script',explode("\0",$cmd),true)&&str_contains($cmd,'startBackground.php'))$runningNames[]=$name;
    }
    foreach($data as $key=>$entry){
        if(!is_array($entry)||!is_string($entry['frequency']??null))throw new RuntimeException('Schedule entry schema invalid');
        $path=$entry['script']??$key;if(!is_string($path))throw new RuntimeException('Script reference invalid');
        if(str_starts_with($path,$legacy))$path=$prefix.substr($path,strlen($legacy));
        if(!str_starts_with($path,$prefix)||!str_ends_with($path,'/script'))throw new RuntimeException('Script reference outside User Scripts');
        $name=substr($path,strlen($prefix),-strlen('/script'));
        if($name===''||$name==='.'||$name==='..'||preg_match('~[/\\\\\x00-\x1f]~',$name))throw new RuntimeException('Unsafe script name');
        if(str_starts_with((string)$key,$prefix)&&$key!==$path)throw new RuntimeException('Ambiguous schedule key/script identity');
        $physical=$root.'/'.$name.'/script';$present=is_file($physical)&&!is_link($physical)&&!is_link(dirname($physical));
        if((file_exists($physical)||is_link($physical))&&!$present)throw new RuntimeException('Unsupported script file type');
        if($present&&!is_readable($physical))throw new RuntimeException('Script file unreadable');
        $frequency=strtolower(trim($entry['frequency']));$enabled=!in_array($frequency,['','disabled'],true);$event=in_array($frequency,['boot','start','stop'],true);$cron=null;
        if($frequency==='custom'){
            if(!is_string($entry['custom']??null))throw new RuntimeException('Custom schedule missing');
            $value=trim($entry['custom']);$macros=['@hourly'=>'0 * * * *','@daily'=>'0 0 * * *','@midnight'=>'0 0 * * *','@weekly'=>'0 0 * * 0','@monthly'=>'0 0 1 * *','@yearly'=>'0 0 1 1 *','@annually'=>'0 0 1 1 *'];
            if($value==='')$enabled=false;elseif($value==='@reboot')$event=true;else {
                $value=$macros[$value]??$value;$fields=preg_split('/\s+/',$value);
                if(count($fields)!==5||preg_match('~[^0-9A-Za-z*,/\-\s]~',$value))throw new RuntimeException('Custom cron syntax invalid');
                $months=['jan'=>1,'feb'=>2,'mar'=>3,'apr'=>4,'may'=>5,'jun'=>6,'jul'=>7,'aug'=>8,'sep'=>9,'oct'=>10,'nov'=>11,'dec'=>12];$days=['sun'=>0,'mon'=>1,'tue'=>2,'wed'=>3,'thu'=>4,'fri'=>5,'sat'=>6];
                foreach([3=>$months,4=>$days] as $i=>$names)$fields[$i]=preg_replace_callback('/[A-Za-z]+/',function($m)use($names){$n=strtolower($m[0]);if(!isset($names[$n]))throw new RuntimeException('Unknown cron name');return (string)$names[$n];},$fields[$i]);
                foreach([[0,59],[0,23],[1,31],[1,12],[0,7]] as $i=>$limits){foreach(explode(',',$fields[$i]) as $part){if(!preg_match('~^(\\*|[0-9]+(?:-[0-9]+)?)(?:/([0-9]+))?$~D',$part,$q))throw new RuntimeException('Invalid cron field');if(isset($q[2])&&(int)$q[2]<1)throw new RuntimeException('Invalid cron step');if($q[1]!=='*'){$r=explode('-',$q[1]);if((int)$r[0]<$limits[0]||(int)end($r)>$limits[1]||(int)$r[0]>(int)end($r))throw new RuntimeException('Invalid cron range');}}}
                $cron=implode(' ',$fields);
            }
        }elseif(in_array($frequency,['hourly','daily','weekly','monthly'],true))$cron=$mapping[$frequency]??null;
        elseif($enabled&&!$event)throw new RuntimeException('Unknown native schedule frequency');
        $running=in_array($name,$runningNames,true);$unknown=in_array($name,$uncertainNames,true);
        $job=['name'=>$name,'role'=>$roles[$name]??$name,'path'=>$path,'physicalPath'=>$physical,'keys'=>[(string)$key],'present'=>$present,'enabled'=>$enabled,'frequency'=>$frequency,'cron'=>$cron,'event'=>$event,'running'=>$running,'runningUnknown'=>$unknown];
        if(isset($jobs[$path])){foreach(['frequency','cron','event'] as $field)if($jobs[$path][$field]!==$job[$field])throw new RuntimeException('Conflicting duplicate schedule references');$job['keys']=array_merge($jobs[$path]['keys'],$job['keys']);}
        $jobs[$path]=$job;
    }
    if(hash_file('sha256',$file)!==$sha)throw new RuntimeException('Schedule changed during inventory');
    echo json_encode(['schema'=>1,'valid'=>true,'source'=>$file,'sourceSha256'=>$sha,'rootIdentity'=>$st['dev'].':'.$st['ino'],'scriptsRoot'=>$root,'roles'=>(object)$roles,'runningNames'=>$runningNames,'uncertainRunningNames'=>$uncertainNames,'observedAt'=>time(),'installed'=>$installed,'jobs'=>(object)$jobs],JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR);
} catch(Throwable $e) {
    echo json_encode(['schema'=>1,'valid'=>false,'detail'=>$e->getMessage()]);exit(1);
}
US_CATALOG_PHP
}

# Derive freshness from the current native cadence, allowing one missed run and
# caller-specified finish grace. Required job removal never disables evidence.
usr_scripts_due_window() {
    php /dev/stdin "$1" "$2" "$3" "${4:-0}" "${5:-288000}" <<'US_DUE_PHP'
<?php
try {
    [$file,$role,$now,$grace,$fallback]=array_slice($argv,1);$now=(int)$now;$grace=(int)$grace;$fallback=(int)$fallback;
    $c=json_decode(file_get_contents($file),true,512,JSON_THROW_ON_ERROR);
    if(($c['valid']??false)!==true)throw new RuntimeException('Script catalogue unavailable');
    $jobs=array_values(array_filter($c['jobs'],fn($j)=>($j['role']===$role||$j['name']===$role)&&$j['present']&&$j['enabled']));
    if(count($jobs)!==1)throw new RuntimeException('Required job '.$role.' is absent, disabled or ambiguous; configure replacement protection. Existing backup data retained');
    $job=$jobs[0];if($job['event']){echo json_encode(['cutoff'=>$now-$fallback,'source'=>'Event-only job; existing freshness requirement retained']);exit;}
    if(!$job['cron'])throw new RuntimeException('Native job timing unavailable');
    $f=preg_split('/\s+/',$job['cron']);
    function dueValues($expr,$lo,$hi){$out=[];foreach(explode(',',$expr) as $part){if(!preg_match('~^(\*|[0-9]+(?:-[0-9]+)?)(?:/([0-9]+))?$~D',$part,$m))throw new RuntimeException('Invalid cron field');$step=isset($m[2])?(int)$m[2]:1;if($step<1)throw new RuntimeException('Invalid cron step');if($m[1]==='*'){$a=$lo;$b=$hi;}elseif(str_contains($m[1],'-')){[$a,$b]=array_map('intval',explode('-',$m[1]));}else{$a=(int)$m[1];$b=isset($m[2])?$hi:$a;}if($a<$lo||$b>$hi||$b<$a)throw new RuntimeException('Invalid cron range');for($v=$a;$v<=$b;$v+=$step)$out[$v]=true;}return array_keys($out);}
    $mins=dueValues($f[0],0,59);$hours=dueValues($f[1],0,23);$dom=dueValues($f[2],1,31);$months=dueValues($f[3],1,12);$dow=dueValues($f[4],0,7);if(in_array(7,$dow,true))$dow[]=0;
    rsort($mins);rsort($hours);$zone=new DateTimeZone('Asia/Singapore');$day=(new DateTimeImmutable('@'.$now))->setTimezone($zone)->setTime(0,0);$due=[];
    for($d=0;$d<800&&count($due)<2;$d++,$day=$day->modify('-1 day')){if(!in_array((int)$day->format('n'),$months,true))continue;$dm=in_array((int)$day->format('j'),$dom,true);$dw=in_array((int)$day->format('w'),$dow,true);$match=!str_starts_with($f[2],'*')&&!str_starts_with($f[4],'*')?($dm||$dw):($dm&&$dw);if(!$match)continue;foreach($hours as $h)foreach($mins as $m){$at=$day->setTime($h,$m)->getTimestamp();if($at<=$now-$grace){$due[]=$at;if(count($due)===2)break 2;}}}
    if(count($due)!==2)throw new RuntimeException('Recurring cadence could not be established');
    echo json_encode(['cutoff'=>$due[1],'lastDue'=>$due[0],'source'=>'User Scripts cron '.$job['cron'].'; one delayed run and '.($grace%3600===0?($grace/3600).'h':($grace%60===0?($grace/60).'min':$grace.'s')).' finish grace allowed']);
} catch(Throwable $e){echo json_encode(['valid'=>false,'source'=>$e->getMessage()]);exit(1);}
US_DUE_PHP
}

# Two stable observations (>=60s apart), actual file presence and native running
# PID evidence precede pruning. The persistent JSON is authoritative; native RAM
# copy and generated custom cron follow it. No lock file or script payload is removed.
usr_scripts_reconcile() {
    local file="$1" root="$2" actor="$3" now="${4:-$(date +%s)}" catalog fd export_fd rc=0
    mountpoint -q "${USER_SCRIPTS_BOOT_MOUNT:-/boot}" && mountpoint -q "${USER_SCRIPTS_VAULT_MOUNT:-/mnt/vault}" || { printf '{"valid":true,"deferred":true,"detail":"Required mounts unavailable; schedule files preserved","events":[]}\n';return 0; }
    exec {fd}>"${USER_SCRIPTS_REGISTRY_LOCK:-/run/user-scripts-schedule-registry.lock}" || return 1
    if ! flock -n "$fd";then exec {fd}>&-;printf '{"valid":true,"deferred":true,"events":[]}\n';return 0;fi
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || { exec {fd}>&-;return 1; }
    if ! flock -s -n "$export_fd";then exec {fd}>&-;exec {export_fd}>&-;printf '{"valid":true,"deferred":true,"detail":"State export active; schedule files preserved","events":[]}\n';return 0;fi
    catalog=$(mktemp /tmp/user-script-catalog.XXXXXX) || { exec {fd}>&-;exec {export_fd}>&-;return 1; }
    if ! usr_scripts_catalog "$file" "$root" >"$catalog";then cat "$catalog";rm -f "$catalog";exec {fd}>&-;exec {export_fd}>&-;return 1;fi
    php /dev/stdin "$catalog" "$actor" "$now" "${USER_SCRIPTS_REGISTRY_FILE:-/run/user-scripts-schedule-registry.json}" "${USER_SCRIPTS_RUNTIME_SCHEDULE:-/tmp/user.scripts/schedule.json}" "${USER_SCRIPTS_CUSTOM_CRON:-$(dirname "$file")/customSchedule.cron}" "${USER_SCRIPTS_SCHEDULE_ROLLBACK:-/mnt/vault/backup/script_deployments/user-scripts-schedule.previous.json}" <<'US_RECONCILE_PHP'
<?php
try {
    [$catPath,$actor,$now,$statePath,$runtime,$cronPath,$rollback]=array_slice($argv,1);$now=(int)$now;
    $c=json_decode(file_get_contents($catPath),true,512,JSON_THROW_ON_ERROR);$file=$c['source'];$root=$c['scriptsRoot'];
    if($actor==='docker_service_watchdog')foreach($c['jobs'] as $job)if($job['role']==='system_update_coordinator'&&$job['present']&&$job['enabled']){echo json_encode(['valid'=>true,'delegated'=>true,'events'=>[]]);exit;}
    foreach([$file,$runtime,$cronPath,$statePath,$rollback] as $path)if(is_link($path))throw new RuntimeException('Symlink schedule/state path refused');
    $boot=file_get_contents($file);if(hash('sha256',$boot)!==$c['sourceSha256'])throw new RuntimeException('Schedule changed during observation; retry');
    $runtimeRaw=is_file($runtime)?file_get_contents($runtime):null;$cronRaw=is_file($cronPath)?file_get_contents($cronPath):null;
    $fingerprint=hash('sha256',$boot."\0".($runtimeRaw??'MISSING')."\0".($cronRaw??'MISSING')."\0".$c['rootIdentity']);
    $bootId=trim(file_get_contents('/proc/sys/kernel/random/boot_id'));
    $state=is_file($statePath)?json_decode(file_get_contents($statePath),true,512,JSON_THROW_ON_ERROR):['schema'=>1,'events'=>[]];
    if(($state['schema']??0)!==1)throw new RuntimeException('Schedule registry state invalid; original files preserved');
    if(($state['boot']??'')!==$bootId)$state=['schema'=>1,'events'=>[]];
    $same=($state['fingerprint']??'')===$fingerprint;
    $observations=$same?($state['observations']??1):1;$last=$same?($state['lastObserved']??$now):$now;
    if($same&&$now-$last>=60){$observations=min(2,$observations+1);$last=$now;}
    $state['boot']=$bootId;$state['fingerprint']=$fingerprint;$state['observations']=$observations;$state['lastObserved']=$last;
    $priorKnown=$state['knownScripts']??[];$known=$priorKnown;$retired=[];
    if($observations>=2)foreach($known as $name=>$role){if(!in_array($name,$c['installed'],true)&&!in_array($name,$c['runningNames'],true)&&!in_array($name,$c['uncertainRunningNames'],true)){$retired[]=$name;unset($known[$name]);}}
    foreach($c['roles'] as $name=>$role)$known[$name]=$role;
    $state['knownScripts']=(object)$known;
    $data=json_decode($boot,true,512,JSON_THROW_ON_ERROR);$bootObject=json_decode($boot,false,512,JSON_THROW_ON_ERROR);$removed=[];
    if($observations>=2)foreach($c['jobs'] as $job){
      if($job['present']||$job['running']||$job['runningUnknown'])continue;
      if(!preg_match('/^[A-Za-z0-9_.-]+$/D',$job['name']))continue;
      if(file_exists($job['physicalPath'])||is_link($job['physicalPath']))continue;
      foreach($job['keys'] as $key){unset($data[$key]);unset($bootObject->{$key});}$removed[]=$job['name'];
    }
    $desiredBoot=$removed?json_encode($bootObject,JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR):$boot;
    $managed='';
    foreach($c['jobs'] as $job){
      if(in_array($job['name'],$removed,true)||!$job['enabled']||$job['frequency']!=='custom')continue;
      $entry=$data[$job['keys'][0]]??null;if(!$entry)continue;$custom=trim($entry['custom']);if($custom==='')continue;
      $path=$entry['script']??$job['path'];if(!preg_match('~^/[A-Za-z0-9_./-]+$~D',$path))$path=escapeshellarg($path);
      $managed.=$custom.' /usr/local/emhttp/plugins/user.scripts/startCustom.php '.$path." > /dev/null 2>&1\n";
    }
    // Preserve unrelated manual lines; rewrite only this native generated section.
    $extra='';foreach(explode("\n",$cronRaw??'') as $line){if(trim($line)===''||str_starts_with($line,'# Generated cron schedule for user.scripts'))continue;if(!str_starts_with(ltrim($line),'#')&&str_contains($line,'/usr/local/emhttp/plugins/user.scripts/startCustom.php'))continue;$extra.=$line."\n";}
    $desiredCron=$managed!==''||$extra!==''?"# Generated cron schedule for user.scripts\n".$managed.$extra."\n":null;
    $changes=[];if($desiredBoot!==$boot)$changes[$file]=$desiredBoot;if($runtimeRaw!==$desiredBoot)$changes[$runtime]=$desiredBoot;if($cronRaw!==$desiredCron)$changes[$cronPath]=$desiredCron;
    $changed=false;$cronChanged=false;
    function atomicFile($path,$content,$mode=0600){$tmp=tempnam(dirname($path),'.schedule.');if($tmp===false)throw new RuntimeException('Schedule staging failed');$h=fopen($tmp,'wb');if(!$h||fwrite($h,$content)!==strlen($content)){@unlink($tmp);throw new RuntimeException('Schedule write failed');}fflush($h);if(function_exists('fsync'))fsync($h);fclose($h);chmod($tmp,$mode);if(!rename($tmp,$path)){@unlink($tmp);throw new RuntimeException('Schedule publish failed');}}
    if(count($state['events']??[])>=200){$changes=[];$retired=[];$state['knownScripts']=(object)$priorKnown;} // Preserve pending actions; caller drains the outbox first.
    if($changes&&$observations>=2){
      if(!is_dir(dirname($runtime))||!is_dir(dirname($rollback)))throw new RuntimeException('Native runtime/rollback directory unavailable');
      if(hash_file('sha256',$file)!==$c['sourceSha256']||(is_file($runtime)?file_get_contents($runtime):null)!==$runtimeRaw||(is_file($cronPath)?file_get_contents($cronPath):null)!==$cronRaw)throw new RuntimeException('Concurrent schedule edit detected; retry without overwrite');
      foreach($removed as $name)if(file_exists($root.'/'.$name.'/script'))throw new RuntimeException('Script reappeared; retirement cancelled');
      atomicFile($rollback,json_encode(['schema'=>1,'at'=>$now,'source'=>$file,'persistent'=>base64_encode($boot),'runtime'=>$runtimeRaw===null?null:base64_encode($runtimeRaw),'customCron'=>$cronRaw===null?null:base64_encode($cronRaw),'removed'=>$removed],JSON_THROW_ON_ERROR));
      foreach($changes as $path=>$bytes){if($bytes===null){if(is_file($path)&&!unlink($path))throw new RuntimeException('Empty native cron could not be removed');}else{ $mode=is_file($path)?(fileperms($path)&0777):0644;atomicFile($path,$bytes,$mode); }if($path===$cronPath)$cronChanged=true;}
      $changed=true;$state['observations']=0;$state['cronReloadPending']=$cronChanged||($state['cronReloadPending']??false);
    }
    if($changed||$retired){
      $id=hash('sha256',$now.':'.$fingerprint.':'.$desiredBoot.':'.implode(',',$retired));
      $state['events'][]=['id'=>$id,'at'=>$now,'actor'=>$actor,'removed'=>array_values(array_unique(array_merge($removed,$retired))),'pruned'=>$removed,'runtimeSynced'=>array_key_exists($runtime,$changes),'cronUpdated'=>$cronChanged];
    }
    atomicFile($statePath,json_encode($state,JSON_THROW_ON_ERROR));
    echo json_encode(['valid'=>true,'changed'=>$changed,'events'=>$state['events']??[],'cronReloadPending'=>$state['cronReloadPending']??false]);
} catch(Throwable $e){echo json_encode(['valid'=>false,'detail'=>$e->getMessage(),'events'=>[]]);exit(1);}
US_RECONCILE_PHP
    rc=$?
    rm -f -- "$catalog"
    exec {fd}>&-;exec {export_fd}>&-
    return "$rc"
}

usr_scripts_registry_ack() {
    local ids="$1" reload="${2:-false}" fd state="${USER_SCRIPTS_REGISTRY_FILE:-/run/user-scripts-schedule-registry.json}" tmp rc=0
    exec {fd}>"${USER_SCRIPTS_REGISTRY_LOCK:-/run/user-scripts-schedule-registry.lock}" || return 1
    flock -w 5 "$fd" || { exec {fd}>&-;return 1; }
    tmp=$(mktemp "$(dirname "$state")/.schedule-registry.XXXXXX") || { exec {fd}>&-;return 1; }
    jq --argjson ids "$ids" --argjson reload "$reload" '.events|=map(select(.id as $id|($ids|index($id))==null)) | if $reload then .cronReloadPending=false else . end' "$state" >"$tmp" && chmod 600 "$tmp" && mv "$tmp" "$state" || rc=$?
    rm -f -- "$tmp";exec {fd}>&-;return "$rc"
}

# A producer's receipt describes its current native schedule, not a copied cron.
usr_scripts_schedule_evidence() {
    local role="$1" file="${USER_SCRIPTS_SCHEDULE_FILE:-/boot/config/plugins/user.scripts/schedule.json}" tmp window
    tmp=$(mktemp /tmp/user-script-schedule.XXXXXX) || return 1
    if usr_scripts_catalog "$file" "${USER_SCRIPTS_PHYSICAL_ROOT:-$(dirname "$file")/scripts}" >"$tmp";then
        window=$(usr_scripts_due_window "$tmp" "$role" "$(date +%s)" 0 288000) || window='{}'
        jq -c --arg role "$role" --argjson window "$window" '[.jobs[]|select((.role==$role or .name==$role) and .present and .enabled)] |
          if length==1 then .[0]|{verified:true,cron,frequency,event,timezone:"Asia/Singapore",intervalSeconds:(if ($window.lastDue|type)=="number" and ($window.cutoff|type)=="number" then $window.lastDue-$window.cutoff else null end)} else {verified:false,reason:"Enabled schedule missing or ambiguous"} end' "$tmp"
    else printf '{"verified":false,"reason":"Native schedule inventory unavailable"}\n';fi
    rm -f -- "$tmp"
}

# Compare normalized timing and exact launcher paths without evaluating shell.
# A cached schedule or matching path alone does not prove correct dispatch.
usr_scripts_verify_cron() {
    php /dev/stdin "$1" "$2" "${USER_SCRIPTS_NATIVE_HOOK_ROOT:-/usr/local/emhttp/plugins/user.scripts/cron}" <<'US_CRON_VERIFY'
<?php
try {
 [$catalogFile,$cronFile,$hooks]=array_slice($argv,1);$c=json_decode(file_get_contents($catalogFile),true,512,JSON_THROW_ON_ERROR);
 if(($c['valid']??false)!==true||!is_file($cronFile)||!is_readable($cronFile))throw new RuntimeException('Live scheduling evidence unavailable');
 function pathArg($s){$out='';$quote=null;$n=strlen($s);for($i=0;$i<$n;$i++){$ch=$s[$i];if($quote==="'"){if($ch==="'")$quote=null;else $out.=$ch;}elseif($quote==='"'){if($ch==='"')$quote=null;elseif($ch==='$'||$ch==='`')throw new RuntimeException('Expansion in launcher path refused');elseif($ch==='\\'&&$i+1<$n)$out.=$s[++$i];else $out.=$ch;}else{if($ch==="'"||$ch==='"')$quote=$ch;elseif($ch==='\\'&&$i+1<$n)$out.=$s[++$i];elseif(ctype_space($ch)||str_contains('$`;|&<>',$ch))throw new RuntimeException('Unexpected launcher arguments');else $out.=$ch;}}if($quote!==null)throw new RuntimeException('Unclosed launcher quoting');return $out;}
 function cronSignature($s){$s=trim(strtolower($s));$macros=['@hourly'=>'0 * * * *','@daily'=>'0 0 * * *','@midnight'=>'0 0 * * *','@weekly'=>'0 0 * * 0','@monthly'=>'0 0 1 * *','@yearly'=>'0 0 1 1 *','@annually'=>'0 0 1 1 *'];if($s==='@reboot')return 'reboot';$s=$macros[$s]??$s;$f=preg_split('/\s+/',$s);if(count($f)!==5)throw new RuntimeException('Unexpected cron field count');$names=[3=>['jan'=>1,'feb'=>2,'mar'=>3,'apr'=>4,'may'=>5,'jun'=>6,'jul'=>7,'aug'=>8,'sep'=>9,'oct'=>10,'nov'=>11,'dec'=>12],4=>['sun'=>0,'mon'=>1,'tue'=>2,'wed'=>3,'thu'=>4,'fri'=>5,'sat'=>6]];foreach($names as $i=>$map)$f[$i]=preg_replace_callback('/[a-z]+/',fn($m)=>isset($map[$m[0]])?(string)$map[$m[0]]:throw new RuntimeException('Unknown cron name'),$f[$i]);$result=[];foreach([[0,59],[0,23],[1,31],[1,12],[0,7]] as $i=>[$lo,$hi]){$values=[];foreach(explode(',',$f[$i]) as $piece){if(!preg_match('~^(\*|[0-9]+(?:-[0-9]+)?)(?:/([0-9]+))?$~D',$piece,$m))throw new RuntimeException('Invalid cron expression');$step=(int)($m[2]??1);if($step<1)throw new RuntimeException('Invalid cron step');if($m[1]==='*'){$a=$lo;$b=$hi;}elseif(str_contains($m[1],'-'))[$a,$b]=array_map('intval',explode('-',$m[1]));else{$a=(int)$m[1];$b=isset($m[2])?$hi:$a;}if($a<$lo||$b>$hi||$a>$b)throw new RuntimeException('Cron value out of range');for($v=$a;$v<=$b;$v+=$step)$values[$i===4&&$v===7?0:$v]=true;}ksort($values);$result[]=array_keys($values);}$result[]=[str_starts_with($f[2],'*'),str_starts_with($f[4],'*')];return json_encode($result);}
 $actual=[];$issues=[];
 foreach(explode("\n",file_get_contents($cronFile)) as $line){if(trim($line)===''||preg_match('/^\s*#/',$line)||!str_contains($line,'/user.scripts/startCustom.php'))continue;
  if(!preg_match('~^\s*(.*?)\s+/usr/local/emhttp/plugins/user\.scripts/startCustom\.php\s+(.+?)\s+>\s*/dev/null\s+2>&1\s*$~D',$line,$m)){$issues[]='Unrecognized User Scripts launcher line; no shell code executed';continue;}
  try{$path=pathArg($m[2]);$path=preg_replace('~^/usr/local/emhttp/plugins/user\.scripts/scripts/~','/boot/config/plugins/user.scripts/scripts/',$path);$actual[$path][]=cronSignature($m[1]);}catch(Throwable $e){$issues[]='Invalid live launcher timing/path: '.$e->getMessage();}
 }
 $wanted=[];
 foreach($c['jobs'] as $job){if(!$job['present']||!$job['enabled'])continue;
  if($job['frequency']==='custom'){$path=$job['path'];$wanted[$path]=true;$expected=cronSignature($job['event']?'@reboot':($job['cron']??''));if(!isset($actual[$path]))$issues[]=$job['name'].': active launcher missing';elseif(count($actual[$path])!==1)$issues[]=$job['name'].': duplicate live launchers';elseif($actual[$path][0]!==$expected)$issues[]=$job['name'].': live cron timing differs from schedule.json';}
  elseif(in_array($job['frequency'],['hourly','daily','weekly','monthly'],true)){if(!$job['cron'])$issues[]=$job['name'].': native dispatcher timing unavailable';$hook=$hooks.'/user.script.start.'.$job['frequency'].'.sh';if(!is_readable($hook)||!str_contains(file_get_contents($hook),'startSchedule.php'))$issues[]=$job['name'].': native dispatcher hook unavailable';}
 }
 foreach($actual as $path=>$times)if(!isset($wanted[$path]))$issues[]='Launcher has no installed enabled schedule: '.$path;
 echo json_encode(['schema'=>1,'valid'=>!$issues,'checkedAt'=>time(),'issues'=>array_values(array_unique($issues))],JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR);
 if($issues)exit(1);
}catch(Throwable $e){echo json_encode(['schema'=>1,'valid'=>false,'issues'=>[$e->getMessage()]]);exit(1);}
US_CRON_VERIFY
}
# END EMBEDDED USER SCRIPTS CATALOG
# BEGIN SCHEDULED EXECUTION SUPERVISOR
if [[ "${BASH_SOURCE[0]}" == "$0" && $# == 0 && "${USR_OPS_SUPERVISED:-}" != "$OPS_SCRIPT_ID" ]];then
    usr_ops_supervise "$0";exit $?
fi
# END SCHEDULED EXECUTION SUPERVISOR
# Shared new-action budget. Native outcomes remain in the producer's journal.
usr_ops_arr_reserve() (
    [[ "${USR_OPS_SHARED_BUDGET_ACTIVE:-false}" == true ]] || return 0
    local action="$1" app="$2" target="$3" root="${MEDIA_ACTION_BUDGET_ROOT:-/mnt/vault/cloud/logs/script/media_health_monitor}" now run fd export_fd temp file
    [[ "$app" == Sonarr || "$app" == Radarr ]] || return 1
    [[ "$target" =~ ^[1-9][0-9]*$ && -d "$root" && ! -L "$root" ]] || return 1
    [[ "$root" != /mnt/vault/* ]] || mountpoint -q /mnt/vault || return 75
    file="$root/action-budget.json";[[ ! -L "$file" ]] || return 1
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || return 1
    flock -s -n "$export_fd" || return 75
    exec {fd}>"${MEDIA_ACTION_BUDGET_LOCK:-/run/media-automation-budget.lock}" || return 1
    flock -x -w 5 "$fd" || return 75
    now=$(date +%s);run="${MEDIA_AUTOMATION_RUN_ID:-$OPS_SCRIPT_ID:${START_TIME:-${START_EPOCH:-$$}}:$$}"
    temp=$(mktemp "$root/.action-budget.XXXXXX") || return 1
    trap 'rm -f -- "$temp"' EXIT
    if [[ -f "$file" ]];then
      jq -e '.schema==1 and (.actions|type)=="object" and all(.actions[];(.at|type)=="number" and (.run|type)=="string")' "$file" >/dev/null || return 1
      cp "$file" "$temp" || return 1
    else
      # Seed from existing issued/uncertain journals instead of resetting limits
      # when the shared contract is first installed. Known local non-dispatch is excluded.
      printf '{"schema":1,"actions":{}}\n' >"$temp"
      local source prefix seed
      for source in "$root/automation-actions.json" "$root/policy-actions.json" "$root/pack-actions.json" "${MEDIA_INTEGRITY_RECOVERY_FILE:-/mnt/vault/cloud/logs/script/media_integrity_audit/recovery.json}";do
        [[ -f "$source" && ! -L "$source" ]] || continue
        prefix="${source##*/}";seed="$temp.seed"
        if [[ "$prefix" == pack-actions.json ]];then
          jq --slurpfile old "$source" --argjson since "$((now-86400))" '
            reduce ($old[0].jobs[]?|select((.queueIntentAt // 0)>=$since)) as $j (.;.actions[("pack-queue:"+$j.downloadId)]={at:$j.queueIntentAt,run:"pre-contract",owner:"pack-actions.json",app:"Sonarr",target:([$j.disposalPlan.targets[].id]|min)})' "$temp" >"$seed" && mv "$seed" "$temp" || return 1
          continue
        fi
        jq --slurpfile old "$source" --arg prefix "$prefix" --argjson since "$((now-86400))" '
          reduce (($old[0].actions // {})|to_entries[]|select((.value.startedAt // .value.grabSentAt // 0)>=$since and .value.outcome!="not_dispatched" and
           (if $prefix=="recovery.json" then (.value.grabSentAt // 0)>0 else true end))) as $r
           (.;.actions[($prefix+":"+$r.key)]={at:($r.value.grabSentAt // $r.value.startedAt),run:"pre-contract",owner:$prefix,app:$r.value.app,target:($r.value.targetId // $r.value.parentId)})' "$temp" >"$seed" && mv "$seed" "$temp" || return 1
      done
    fi
    if jq -e --arg key "$action" '.actions[$key]!=null' "$temp" >/dev/null;then return 75;fi
    jq -e --argjson since "$((now-86400))" --arg run "$run" '[.actions[]|select(.at>=$since)] as $today | ($today|length)<4 and ([$today[]|select(.run==$run)]|length)<2' "$temp" >/dev/null || return 75
    jq --arg key "$action" --arg app "$app" --argjson target "$target" --arg run "$run" --arg owner "$OPS_SCRIPT_ID" --argjson now "$now" \
      '.actions |= with_entries(select(.value.at>=$now-30*86400)) | .actions[$key]={at:$now,run:$run,owner:$owner,app:$app,target:$target,outcome:"reserved; native journal owns dispatch/outcome"}' "$temp" >"$temp.next" && mv "$temp.next" "$temp" || return 1
    sync -f "$temp" && mv "$temp" "$file" && sync -f "$root"
)

usr_ops_arr_release_undispatched() (
    [[ "${USR_OPS_SHARED_BUDGET_ACTIVE:-false}" == true ]] || return 0
    local key="$1" root="${MEDIA_ACTION_BUDGET_ROOT:-/mnt/vault/cloud/logs/script/media_health_monitor}" fd export_fd temp run
    run="${MEDIA_AUTOMATION_RUN_ID:-$OPS_SCRIPT_ID:${START_TIME:-${START_EPOCH:-$$}}:$$}"
    [[ -f "$root/action-budget.json" && ! -L "$root/action-budget.json" ]] || return 1
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}";flock -s -n "$export_fd" || return 75
    exec {fd}>"${MEDIA_ACTION_BUDGET_LOCK:-/run/media-automation-budget.lock}";flock -x -w 5 "$fd" || return 75
    temp=$(mktemp "$root/.budget-release.XXXXXX") || return 1
    trap 'rm -f -- "$temp"' EXIT
    jq --arg key "$key" --arg run "$run" 'if .actions[$key].run==$run then del(.actions[$key]) else . end' "$root/action-budget.json" >"$temp" && sync -f "$temp" && mv "$temp" "$root/action-budget.json" && sync -f "$root"
)
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
# Resume an hourly audit in small slices on subsequent five-minute runs.
# Unchecked/failed paths never count as proof that a prior issue recovered.
SAB_FILESYSTEM_BATCH_ITEMS=20
SAB_FILESYSTEM_BATCH_SECONDS=15
SAB_FILESYSTEM_PATH_TIMEOUT_SECONDS=5
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

# New or materially changed issues still notify immediately. Unchanged active
# errors/warnings receive at most three daily reminders, then remain visible in
# state/logs without further reminder email. Resolution reporting is unchanged.
REMINDERS_ENABLED=true
ERROR_REMINDER_INTERVAL_HOURS=24
WARNING_REMINDER_INTERVAL_HOURS=24

# Maximum reminder emails after the initial report, per unchanged signature.
# A new signature/severity resets the budget; 0 would mean unlimited.
REMINDER_MAX_COUNT=3

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

STATE_DIR="/mnt/vault/cloud/logs/script/media_health_monitor"

# Never create the state tree beneath an absent backing mount. The SAB guard
# affects only filesystem orphan/residue analysis; API monitoring continues.
STATE_REQUIRED_MOUNT="/mnt/vault"
SAB_REQUIRED_MOUNT="/mnt/user"
SAB_FILESYSTEM_GUARD_ENABLED=true
MOVER_GUARD_ENABLED=true
MOVER_PROCESS_PATTERN='(^|/)(mover|mover\.old)( |$)|mover\.php'

# Automated policy handling: no forced imports, profile changes, payload deletion,
# series searches. Pack handling has an independent exact-file journal. Disable to retain monitoring-only behavior.
# Six hours includes the four-hour import batch plus a two-hour grace period.
# Two stable observations at least four minutes apart are mandatory.
# Any tag on the movie/series protects it from automation (deletion/hold intent).
# Limits apply across both apps; replacement is at most once/target/7 days,
# three times/30 days. A burst or uncertain mutation stops new actions.
POLICY_AUTOMATION_ENABLED=true
POLICY_GRACE_HOURS=6
POLICY_MAX_ACTIONS_PER_RUN=2
POLICY_MAX_ACTIONS_PER_DAY=4
POLICY_BURST_LIMIT=5
# Alert if preserved rejected payloads still await cleanup after its normal
# six-hour rejection eligibility plus daily scheduling/startup allowance.
POLICY_CLEANUP_EXPECTED_HOURS=48

# Native import events are preserved before Arr history ages out. The cleanup
# script resolves these exact file IDs to current paths, including renames.
IMPORT_RECEIPTS_ENABLED=true
IMPORT_RECEIPT_RETENTION_DAYS=365

# New Arr actions run only within these Singapore-time four-hour windows.
# 0 means 00:00/04:00/08:00/12:00/16:00/20:00; each window lasts ten minutes.
ARR_AUTOMATION_ENABLED=true
AUTOMATION_TIMEZONE="Asia/Singapore"
AUTOMATION_BATCH_HOUR_OFFSET=0
AUTOMATION_BATCH_WINDOW_MINUTES=10
AUTOMATION_MISSING_SURVEY_HOURS=168
AUTOMATION_MISSING_CANDIDATES_PER_APP=4
AUTOMATION_MISSING_MAX_RECORDS=5000
AUTOMATION_IMPORT_RETRY_MAX_ATTEMPTS=3
AUTOMATION_SONARR_COMPLETE_ROOT="/data/net/complete/series"
AUTOMATION_RADARR_COMPLETE_ROOT="/data/net/complete/movies"
AUTOMATION_PROFILE_POLL_MINUTES=60

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

LOG_FILE="${STATE_DIR}/media_health_monitor.log"

# Routine runs stay compact. DEBUG temporarily restores phase, checkpoint,
# pagination/cache, suppression, and other troubleshooting messages.
LOG_LEVEL="INFO"

# Emit a full health report on change and as a periodic healthy heartbeat.
HEALTH_HEARTBEAT_HOURS=6

# Rotate after approximately 5 MiB.
LOG_MAX_SIZE_MB=5
LOG_LINE_MAX_BYTES=4096

# Keep:
#   media_health_monitor.log
#   media_health_monitor.log.1
#   media_health_monitor.log.2
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

LOCKFILE="/tmp/media_health_monitor.lock"

# Keep a five-minute scheduled run below four minutes. Once the remaining
# reserve is reached, optional audit/reconciliation/filesystem phases are
# deferred without resolving any issue that depends on them.
MONITOR_RUNTIME_BUDGET_SECONDS=240
MONITOR_RUNTIME_RESERVE_SECONDS=60

# Stop repeatedly calling one service during the same run after consecutive
# transport/server failures. Authentication failures open the circuit
# immediately; ordinary endpoint 404 responses do not.
SERVICE_CIRCUIT_FAILURE_THRESHOLD=2
MONITOR_NOTIFY_TIMEOUT_SECONDS=30
MONITOR_NOTIFY_LEASE_WAIT_SECONDS=20
MONITOR_OUTBOX_ACTIVE=false
MONITOR_COORDINATION_ACTIVE=false
MONITOR_STATE_LEASE_HELD=false
MONITOR_EXPORT_LEASE_LOST=false
ARR_MUTATION_LOCK_DIR="${ARR_MUTATION_LOCK_DIR:-/run}"
MONITOR_SONARR_MUTATION_FD=""
MONITOR_RADARR_MUTATION_FD=""

QUEUE_PAGE_SIZE=1000
SAB_HISTORY_LIMIT=500
ARR_QUEUE_MAX_RECORDS=10000
ARR_ACTIVITY_HISTORY_PAGE_SIZE=1000
ARR_ACTIVITY_HISTORY_MAX_RECORDS=10000

###############################################################################
# INITIALIZATION
###############################################################################

START_TIME=$(date +%s)
if [[ $# == 0 ]];then
    monitor_native_schedule=$(usr_scripts_schedule_evidence media_health_monitor) || monitor_native_schedule='{}'
    monitor_native_interval=$(jq -r '.intervalSeconds // 0' <<<"$monitor_native_schedule")
    if [[ "$monitor_native_interval" =~ ^[0-9]+$ ]] && ((monitor_native_interval>=60));then MONITOR_EXPECTED_INTERVAL_MINUTES=$((monitor_native_interval/60));fi
fi

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
    usr_ops_log_line "$level" MAIN "$message"
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
    line=$(usr_ops_log_line "$level" MAIN "$message")
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

    monitor_release_mutation_gates
    if [ "$MONITOR_RUN_ACTIVE" = true ] &&
       [ "$MONITOR_RUN_FINALIZED" != true ] && [[ "${MONITOR_EXPORT_LEASE_LOST:-false}" != true ]]; then

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
        logger -t "media_health_monitor" -- "$reason" 2>/dev/null || true
    fi

    if [ "$SEND_NOTIFICATIONS" = true ] && [ -x "$NOTIFY" ]; then
        notify \
            "alert" \
            "Media Health Monitor - State Mount Unavailable" \
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

# Changes by monitor/cleanup/integrity recovery share one per-application gate.
# Only automation owns these leases; native health collection remains available.
monitor_mutation_gate() {
    local app="$1" variable fd
    [[ "${MONITOR_COORDINATION_ACTIVE:-false}" == true ]] || return 0
    case "$app" in Sonarr) variable=MONITOR_SONARR_MUTATION_FD;;Radarr) variable=MONITOR_RADARR_MUTATION_FD;;*) return 1;;esac
    [[ -z "${!variable:-}" ]] || return 0
    exec {fd}>"${ARR_MUTATION_LOCK_DIR:-/run}/arr-mutations-$app.lock" || return 1
    if ! flock -n "$fd";then
        exec {fd}>&-
        printf '%s\n' "$app: another coordinated script owns Arr changes; monitoring continues" >>"$TMP_DIR/automation-deferrals.txt"
        return 1
    fi
    printf -v "$variable" '%s' "$fd"
}

monitor_release_mutation_gates() {
    local variable fd
    for variable in MONITOR_SONARR_MUTATION_FD MONITOR_RADARR_MUTATION_FD;do
        fd="${!variable:-}"
        [[ -z "$fd" ]] || exec {fd}>&-
        printf -v "$variable" ''
    done
}

monitor_note_budget() {
    local scope="$1"
    [[ -d "${TMP_DIR:-}" ]] || return 0
    printf '%s\n' "$scope" >>"$TMP_DIR/budget-deferrals.txt"
}

monitor_http_seconds() {
    local service="$1" remaining limit="${HTTP_REQUEST_TIMEOUT_SECONDS:-30}"
    [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=30
    if [[ "${MONITOR_RUN_ACTIVE:-false}" != true ]];then printf '%s' "$limit";return 0;fi
    remaining=$(( START_TIME+MONITOR_RUNTIME_BUDGET_SECONDS-MONITOR_RUNTIME_RESERVE_SECONDS-$(date +%s) ))
    if ((remaining<=0));then monitor_note_budget "$service";return 1;fi
    ((remaining<=limit)) || remaining="$limit"
    printf '%s' "$remaining"
}

monitor_service_deferred() {
    [[ -f "${TMP_DIR:-}/budget-deferrals.txt" ]] && grep -Fxq -- "$1" "$TMP_DIR/budget-deferrals.txt"
}

# An additive field in existing state.json; no separate permanent log/state tree.
monitor_outbox_valid() {
    jq -e '(.monitor.notification.outbox // {}) as $q | ($q|type)=="object" and
      all($q|to_entries[]; .key==.value.outboxId and (.key|test("^[a-f0-9]{64}$")) and
        (.value.issueKey|type)=="string" and (.value.signature|type)=="string" and
        (.value.detail|type)=="string" and (.value.queuedAt|type)=="number" and
        (.value.event|type)=="string" and (.value.severity=="ERROR" or .value.severity=="WARNING" or .value.severity=="INFO"))' "$STATE_FILE" >/dev/null
}

monitor_outbox_enqueue() {
    local record="$1" key signature event previous id tmp="$TMP_DIR/outbox-enqueue.json"
    [[ "${MONITOR_OUTBOX_ACTIVE:-false}" == true ]] || return 0
    monitor_outbox_valid || return 1
    IFS=$'\t' read -r key signature event < <(jq -r '[.issueKey,.signature,.event]|@tsv' "$record")
    previous=$(jq -r --arg key "$key" '.issues[$key].lastNotifiedAt // 0' "$STATE_FILE") || return 1
    id=$(printf '%s\0' "$key" "$signature" "$event" "$previous" | sha256sum | cut -d ' ' -f1)
    jq --arg id "$id" --argjson now "$(date +%s)" --slurpfile incoming "$record" '
      .monitor.notification.outbox //= {} |
      $incoming[0] as $e |
      # Coalesce obsolete undelivered attention; action/recovery records retain
      # their original payload and observation time until accepted and acked.
      if ($e.event=="new" or $e.event=="reminder") then
        .monitor.notification.outbox |= with_entries(select(.value.issueKey!=$e.issueKey or
          (.value.event!="new" and .value.event!="reminder") or .key==$id))
      else . end |
      .monitor.notification.outbox[$id] //= ($e+{outboxId:$id,queuedAt:$now})' "$STATE_FILE" >"$tmp" && save_state "$tmp"
}

monitor_outbox_load() {
    [[ "${MONITOR_OUTBOX_ACTIVE:-false}" == true ]] || return 0
    monitor_outbox_valid || return 1
    local tmp="$TMP_DIR/outbox-current.json"
    jq '. as $state | .monitor.notification.outbox //= {} |
      .monitor.notification.outbox |= with_entries(select(
        (.value.event!="new" and .value.event!="reminder") or
        ($state.issues[.value.issueKey] == null) or $state.issues[.value.issueKey].active==true))' "$STATE_FILE" >"$tmp" && save_state "$tmp" || return 1
    jq -c '.monitor.notification.outbox // {} | .[]' "$STATE_FILE" >"$NOTIFICATION_BATCH"
}

monitor_outbox_ack() {
    local page="$1" tmp="$TMP_DIR/outbox-acked.json"
    [[ "${MONITOR_OUTBOX_ACTIVE:-false}" == true ]] || return 0
    jq --slurpfile accepted "$page" 'reduce $accepted[] as $a (.;del(.monitor.notification.outbox[$a.outboxId]))' "$STATE_FILE" >"$tmp" &&
      save_state "$tmp" && commit_state_transaction notification-page-accepted
}

monitor_outbox_prepare() {
    monitor_outbox_valid || {
        log 'ERROR: Durable notification outbox invalid; state preserved; automation was not started'
        local marker="${MONITOR_OUTBOX_EMERGENCY_MARKER:-/run/media-health-monitor-outbox-alert}" identity
        identity="$(date +%F)|$(sha256sum "$STATE_FILE"|cut -d ' ' -f1)"
        if [[ ! -f "$marker" || "$(cat "$marker")" != "$identity" ]];then
            if notify alert 'Notification state requires attention' 'Durable pending notification state is invalid. State was preserved; no automation was started. Restore or inspect state.json before resuming.';then printf '%s' "$identity" >"$marker";fi
        fi
        return 1
    }
    MONITOR_OUTBOX_ACTIVE=true
}

monitor_persist_coverage() {
    local tmp="$TMP_DIR/coverage-state.json" data="$TMP_DIR/coverage.json" now elapsed
    now=$(date +%s);elapsed=$((now-START_TIME))
    jq -n --argjson se "$SONARR_ENABLED" --argjson re "$RADARR_ENABLED" --argjson be "$SAB_ENABLED" --argjson audit "$ACTIVITY_AUDIT_ENABLED" --argjson sq "$SONARR_QUEUE_OK" --argjson sh "$SONARR_HEALTH_OK" --argjson ss "$SONARR_STATUS_OK" --argjson sa "$SONARR_AUDIT_OK" \
      --argjson rq "$RADARR_QUEUE_OK" --argjson rh "$RADARR_HEALTH_OK" --argjson rs "$RADARR_STATUS_OK" --argjson ra "$RADARR_AUDIT_OK" \
      --argjson bq "$SAB_QUEUE_OK" --argjson bh "$SAB_HISTORY_OK" --argjson bw "$SAB_WARNINGS_OK" --argjson bs "$SAB_STATUS_OK" --argjson bp "$SAB_SERVER_STATS_OK" \
      '{"Sonarr.queue":$sq,"Sonarr.health":$sh,"Sonarr.status":$ss,"Sonarr.history":$sa,
        "Radarr.queue":$rq,"Radarr.health":$rh,"Radarr.status":$rs,"Radarr.history":$ra,
        "SABnzbd.queue":$bq,"SABnzbd.history":$bh,"SABnzbd.warnings":$bw,"SABnzbd.status":$bs,"SABnzbd.providers":$bp} |
        with_entries(.key as $key | .value={complete:.value,enabled:(if ($key|startswith("Sonarr.")) then $se elif ($key|startswith("Radarr.")) then $re else $be end)}) |
        with_entries(if (.key|endswith(".history")) and (.key|startswith("SABnzbd.")|not) then .value.enabled=(.value.enabled and $audit) else . end)' >"$data" || return 1
    local deferred="${MONITOR_RUNTIME_DEFERRED_PHASES:-}" gates="" reasons="$TMP_DIR/coverage-reasons.json"
    jq -n --arg s "${SONARR_API_FAILURES:-}" --arg r "${RADARR_API_FAILURES:-}" --arg b "${SAB_API_FAILURES:-}" '{Sonarr:$s,Radarr:$r,SABnzbd:$b}' >"$reasons" || return 1
    [[ ! -s "$TMP_DIR/budget-deferrals.txt" ]] || deferred+="; API budget: $(sort -u "$TMP_DIR/budget-deferrals.txt"|tr '\n' ',')"
    [[ ! -s "$TMP_DIR/automation-deferrals.txt" ]] || gates=$(sort -u "$TMP_DIR/automation-deferrals.txt")
    jq --slurpfile coverage "$data" --slurpfile reasons "$reasons" --argjson now "$now" --argjson elapsed "$elapsed" --arg deferred "$deferred" --arg gates "$gates" '
      .monitor.collectionCoverage //= {} |
      reduce ($coverage[0]|to_entries[]) as $c (.;
        .monitor.collectionCoverage[$c.key]={complete:$c.value.complete,enabled:$c.value.enabled,checkedAt:$now,
          reason:(if $c.value.complete then "Fresh successful observation" elif ($c.value.enabled|not) then "Collector disabled by configuration" else ($reasons[0][($c.key|split(".")[0])] | if .!="" then . else "Collector deferred/unavailable; previous evidence retained" end) end),
          firstObservedAt:(.monitor.collectionCoverage[$c.key].firstObservedAt // $now),
          lastSuccessfulAt:(if $c.value.complete then $now else (.monitor.collectionCoverage[$c.key].lastSuccessfulAt // 0) end)}) |
      .monitor.operationalSummary={collectionComplete:all($coverage[0][]|select(.enabled);.complete==true),elapsedSeconds:$elapsed,
        deferredWork:$deferred,automationDeferrals:$gates,
        activeWorkflowWarnings:([.issues[]?|select(.active==true and .severity=="WARNING" and .app!="Monitor")]|length),
        activeWorkflowErrors:([.issues[]?|select(.active==true and .severity=="ERROR" and .app!="Monitor")]|length),
        monitorErrors:([.issues[]?|select(.active==true and .severity=="ERROR" and .app=="Monitor")]|length),
        monitorWarnings:([.issues[]?|select(.active==true and .severity=="WARNING" and .app=="Monitor")]|length),
        pendingNotificationSections:((.monitor.notification.outbox // {})|length)}' "$STATE_FILE" >"$tmp" && save_state "$tmp"
}

monitor_report_stale_coverage() {
    local row key last first now=$(date +%s)
    while IFS= read -r row;do
      key=$(jq -r '.key' <<<"$row");last=$(jq -r '.value.lastSuccessfulAt // 0' <<<"$row");first=$(jq -r '.value.firstObservedAt' <<<"$row")
      record_normalized_issue "Monitor:coverage:$key" Monitor "$key coverage stale" MONITOR_COVERAGE_STALE WARNING stale \
        'Collector has no fresh successful observation for at least 24 hours' 24 \
        "Collector: $key. Last successful epoch: $last; first tracked epoch: $first. Existing dependent issues were preserved. Automatic collection retries continue; no healthy result or import was inferred."
    done < <(jq -c --argjson now "$now" '.monitor.collectionCoverage|to_entries[]|select(.value.enabled and (.value.complete|not) and ($now-(if .value.lastSuccessfulAt>0 then .value.lastSuccessfulAt else .value.firstObservedAt end))>=86400)' "$STATE_FILE")
}

notification_fallback_alert() {

    local reason="$1"

    persistent_log "ERROR" "Notification command failure | ${reason}"


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

    local lease_released=false rc=0
    if [[ "${MONITOR_NOTIFY_DURABLE_PAGE:-false}" == true ]];then
        commit_state_transaction notification-before-send || return 1
    fi
    if [[ "${MONITOR_STATE_LEASE_HELD:-false}" == true && -n "${STATE_EXPORT_FD:-}" ]];then
        exec {STATE_EXPORT_FD}>&-
        MONITOR_STATE_LEASE_HELD=false;lease_released=true
    fi
    usr_ops_notify timeout --signal=TERM --kill-after=5 "$MONITOR_NOTIFY_TIMEOUT_SECONDS" "$NOTIFY" \
        -i "$importance" \
        -s "Media Health Monitor" \
        -d "$description" \
        -m "$message" \
        >/dev/null 2>&1 || rc=$?
    if [[ "$lease_released" == true ]];then
        exec {STATE_EXPORT_FD}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || { MONITOR_EXPORT_LEASE_LOST=true;return 75; }
        if ! flock -s -w "$MONITOR_NOTIFY_LEASE_WAIT_SECONDS" "$STATE_EXPORT_FD";then
            exec {STATE_EXPORT_FD}>&-;MONITOR_EXPORT_LEASE_LOST=true
            log 'MAINTENANCE: export lease could not be reacquired; accepted notification remains pending acknowledgement; next run reconciles'
            return 75
        fi
        MONITOR_STATE_LEASE_HELD=true
    fi
    if ((rc==0));then
        ((NOTIFICATIONS_SENT++)) || true

        return 0
    fi

    log "WARNING: Failed to send grouped Unraid notification"

    if ((rc==124 || rc==137));then
        NOTIFICATION_LAST_ERROR="notification command timed out after ${MONITOR_NOTIFY_TIMEOUT_SECONDS}s; pending messages retained"
    else
        NOTIFICATION_LAST_ERROR="notification command failed (exit ${rc}): ${NOTIFY}; pending messages retained"
    fi
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
    local delay=0 seconds service
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

    service=$(api_service_for_url "$url")
    while (( attempt <= max_attempts )); do
        if ! seconds=$(monitor_http_seconds "$service");then
            HTTP_LAST_ERROR="runtime budget deferred request; existing evidence preserved"
            rm -f -- "$header_file" "$stderr_file"
            return 1
        fi
        : >"$header_file"
        : >"$stderr_file"
        invalid_json=false

        http_code=$(curl \
            "${request_args[@]}" --max-time "$seconds" --max-filesize 67108864 \
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
        if [[ "${MONITOR_RUN_ACTIVE:-false}" == true ]] && (( $(date +%s)+delay>=START_TIME+MONITOR_RUNTIME_BUDGET_SECONDS-MONITOR_RUNTIME_RESERVE_SECONDS ));then
            monitor_note_budget "$service";break
        fi
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
    if [[ "$error" == 'runtime budget deferred request'* ]];then printf '%s' "$current";return 0;fi
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

        if [[ "$combined" =~ below.*profile.minimum ]]; then
            echo "CF_REJECT_MINIMUM"
            return
        fi
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
        CF_REJECT_MINIMUM|\
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
        CF_REJECT_MINIMUM|\
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

        CF_REJECT_MINIMUM)
            echo "Release custom-format score is below the quality profile minimum"
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

    [[ "${MONITOR_EXPORT_LEASE_LOST:-false}" != true ]] || return 1
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
            "Media Health Monitor - State Write Failed" \
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
        CF_REJECT_MINIMUM|\
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
        elif ($key|startswith("AUTO:EVENT:")) then
            .monitor.automationNotifications[($key|ltrimstr("AUTO:EVENT:"))]=$signature
        elif ($key|startswith("PACK:ACTION:")) then
            .monitor.packNotifications[($key|ltrimstr("PACK:ACTION:"))]=$signature
        elif ($key|startswith("POLICY:ACTION:")) then
            .monitor.policyNotifications[($key|ltrimstr("POLICY:ACTION:"))]=$signature
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
            printf '  /bin/bash /boot/config/plugins/user.scripts/scripts/media_health_monitor/script \\\n'
            printf '    --batch-dismiss-downloads --ack-file "%s"\n' "$BATCH_PREVIEW_ACK_FILE"
            printf '\nDismiss this exact saved selection after review:\n'
            printf '  /bin/bash /boot/config/plugins/user.scripts/scripts/media_health_monitor/script \\\n'
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
        'Media Health Monitor v3.28.0 lifecycle commands' \
        'Historical vanished/never-arrived attempts become REVIEW_REQUIRED warnings' \
        'after 12 hours and successful Arr/SAB checks; no import/cancellation is inferred.' \
        'Review warnings notify once per unchanged issue and remain in --list-active.' \
        'Notification details include the last reconciliation decision and evidence.' \
        '' \
        'Always invoke the Unraid User Scripts copy through /bin/bash:' \
        '  /bin/bash /boot/config/plugins/user.scripts/scripts/media_health_monitor/script COMMAND' \
        '' \
        'Inspect and manage one issue:' \
        '  --automation-status  Show action/hold/baseline summaries; no changes.' \
        '  --policy-actions  List guarded policy actions/checkpoints; no changes.' \
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
        "      --ack-file \"/mnt/vault/cloud/logs/script/media_health_monitor/batch-dismissals/previews/FILE-ack-ids.txt\" \\" \
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
                    monitor_service_deferred Sonarr && return 1
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
                    monitor_service_deferred Radarr && return 1
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
                    monitor_service_deferred SABnzbd && return 1
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
                    [ "$SAB_FILESYSTEM_SCAN_OK" = true ] &&
                    grep -Fxq -- "$issue_key" "${TMP_DIR}/sab-filesystem-checked-keys"
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
    # Link the exact shared download without suppressing native API/import faults.
    # Integrity owns replacement results; health retains independent service evidence.
    local recovery_file="${MEDIA_INTEGRITY_RECOVERY_FILE:-/mnt/vault/cloud/logs/script/media_integrity_audit/recovery.json}" incident_id='' download_id=''
    [[ "$issue_key" != FLOW:DOWNLOAD:* ]] || download_id="${issue_key#FLOW:DOWNLOAD:}"
    if [[ -n "$download_id" && -r "$recovery_file" && ! -L "$recovery_file" ]];then
      incident_id=$(jq -r --arg id "$download_id" --arg app "$source" '.actions|to_entries[]|select(.value.app==$app and (.value.downloadId // "")!="" and ((.value.downloadId|ascii_downcase)==($id|ascii_downcase)))|.key' "$recovery_file" 2>/dev/null|head -n 1)
      [[ -z "$incident_id" ]] || detail+=$'\n'"Recovery owner: Media Integrity Audit; incident integrity:$incident_id. This health event reports independent workflow evidence; replacement outcome is recorded by the recovery owner."
    fi
    printf '%s' "$detail" >"$TMP_DIR/notification-detail.txt" || return 1

    jq -nc \
        --arg issueKey "$issue_key" \
        --arg signature "$signature" \
        --arg source "$source" \
        --arg title "$title" \
        --arg classification "$classification" \
        --arg severity "$severity" \
        --arg age "$age" \
        --rawfile detail "$TMP_DIR/notification-detail.txt" \
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
        >"$TMP_DIR/notification-new-record.json" || return 1
    cat "$TMP_DIR/notification-new-record.json" >>"$NOTIFICATION_BATCH" || return 1
    monitor_outbox_enqueue "$TMP_DIR/notification-new-record.json" || return 1

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
                elif $event == "progress"
                then " [" + (.severity // "INFO") + "] [PROGRESS]"
                elif $event == "completed"
                then " [" + (.severity // "INFO") + "] [COMPLETED]"
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
          + (if ((.classification // "") | test("^(ARR_DOWNLOAD_FAILED_HISTORY|SAB_DOWNLOAD_FAILED_.*|SAB_ERROR|SAB_WARNING)$"))
             then "\n  Evidence: recorded application event; this event alone does not prove a current service or import failure."
             elif .classification == "DOWNLOAD_FLOW_REVIEW_REQUIRED"
             then "\n  Evidence: historical outcome remains unverified; current API evidence does not prove import or cancellation."
             else "" end)
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
                then "\n  Tracked issue age: " + (.age | tostring) + "h"
                else ""
            end
          )
          + (if (.queuedAt // 0)>0 then "\n  Queued: "+(.queuedAt|strflocaltime("%Y-%m-%d %H:%M:%S %Z")) else "" end)
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
    local flapping progress completed
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

    IFS=$'\t' read -r progress completed < <(jq -sr '[([.[]|select(.event=="progress")]|length),([.[]|select(.event=="completed")]|length)]|@tsv' "$page_file")
    description="Media Health Monitor - ${batch_total} Update(s)"

    if (( page_total > 1 )); then
        description+=" - Batch ${page_number}/${page_total}"
    fi

    body="Health/activity updates: ${batch_total}"$'\n'
    body+="This batch: ${page_items} | Info: ${info_new} | Warnings: ${warning_new} | Errors: ${error_new} | Resolved: ${resolved}"$'\n'
    body+="Workflow progress: ${progress} | Completed: ${completed}"$'\n'
    body+="Auto-reconciled: ${reconciled} | Manually dismissed: ${dismissed}"$'\n'
    body+="Reminders: ${reminders} | Flapping: ${flapping}"$'\n'

    if (( page_total > 1 )); then
        body+="Batch: ${page_number}/${page_total}"$'\n'
    fi

    body+=$'\n'

    # Presentation groups only: never combine identity, acknowledgement,
    # resolution, or per-record delivery state merely because titles match.
    local group_file="${TMP_DIR}/notification-groups.jsonl" group count member
    jq -sc 'group_by([.source,.title,.classification,.severity,.event]) | .[]' "$page_file" >"$group_file" || return 1
    while IFS= read -r group; do
        count=$(jq 'length' <<<"$group")
        if (( count > 1 )); then
            body+="$(jq -r '.[0] | "- ["+.source+"] "+.title+"\n  "+.classification+" ["+.severity+"] ["+(.event // "new")+"]"' <<<"$group")"$'\n'
            body+="  Related records: $count. Each download retains its own lifecycle and Ack ID."$'\n'
            while IFS= read -r member; do
                entry=$(notification_record_text "$member")
                body+="$(printf '%s\n' "$entry" | tail -n +3)"$'\n'
            done < <(jq -c '.[]' <<<"$group")
            body+=$'\n'
        else
            record=$(jq -c '.[0]' <<<"$group")
            entry=$(notification_record_text "$record")
            body+="$entry"$'\n\n'
        fi
    done <"$group_file"

    if [[ "${MONITOR_OUTBOX_ACTIVE:-false}" == true ]];then
      body+="Collection coverage: $(jq -r '.monitor.operationalSummary.collectionComplete|if . then "complete" else "partial; previous evidence retained" end' "$STATE_FILE")."$'\n'
      body+="Workflow attention: $(jq -r '.monitor.operationalSummary|"\(.activeWorkflowWarnings) warning(s), \(.activeWorkflowErrors) error(s); monitor errors: \(.monitorErrors)"' "$STATE_FILE")."$'\n'
    fi
    body+="Pending messages retain their original observation and action details."$'\n'
    body+="Monitor schedule: every five minutes recommended"$'\n'
    body+="Runtime: $(runtime)"

    MONITOR_NOTIFY_DURABLE_PAGE=true notify \
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
            return 1
        fi

    done <"$page_file"

    monitor_outbox_ack "$page_file" || return 1
    log "Grouped notification batch ${page_number}/${page_total} accepted and acknowledged"
    log "Issues included in batch: $page_items"

    return 0
}

send_grouped_notification() {
    monitor_outbox_load || return 1
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
            (.classification // ""),
            (.event // "new")
        )
        | .[]
        ' "$NOTIFICATION_BATCH" >"$sorted_file" || return 1

    page_file=$(mktemp "${TMP_DIR}/notification-page.XXXXXX") || return 1
    : >"$page_file"

    while IFS= read -r record; do

        [ -n "$record" ] || continue

        entry=$(notification_record_text "$record")
        entry_bytes=$(( $(notification_text_bytes "$entry") + 512 ))

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
    if [[ -z "$failures" ]] && monitor_service_deferred "$app";then return 0;fi
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

    local maintenance_seen
    maintenance_seen=$(cat "${ARR_BACKUP_DEFERRED_AT:-/run/media-health-monitor-backup-deferred-at}" 2>/dev/null || true)
    if [[ "$maintenance_seen" =~ ^[0-9]+$ ]] &&
       (( maintenance_seen > PREVIOUS_RUN_STARTED_AT && maintenance_seen <= START_TIME &&
          START_TIME - maintenance_seen <= 86400 )); then
        log "MAINTENANCE: Previous monitoring interval includes scheduled backup deferrals; schedule-gap alert suppressed"
        return 0
    fi
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

# Presentation only: group native queue evidence by download ID. A pack hint
# never supplies episode identity or authorizes rejection/import/deletion.
arr_queue_presentation() {
    local app="$1" item="$2" queue="$3" input="$TMP_DIR/queue-presentation-item.json" actions="${AUTOMATION_STATE_FILE:-$STATE_DIR/automation-actions.json}" empty="$TMP_DIR/queue-presentation-empty.json"
    printf '%s' "$item" >"$input" || return 1
    [[ -f "$actions" && ! -L "$actions" ]] || { printf '{"actions":{}}' >"$empty";actions="$empty"; }
    jq -r --arg app "$app" --argjson maximum "$AUTOMATION_IMPORT_RETRY_MAX_ATTEMPTS" --slurpfile item "$input" --slurpfile automation "$actions" '
      $item[0] as $i | (($i.downloadId // "")|ascii_downcase) as $id |
      [.records[]?|select(if $id!="" then ((.downloadId // "")|ascii_downcase)==$id else .id==$i.id end)] as $rows |
      ([$rows[]|.episodeId?,.episode.id?,.episodeIds[]?]|map(select(type=="number" and .>0))|unique) as $episodes |
      ([$rows[]|.movieId?]|map(select(type=="number" and .>0))|unique) as $movies |
      (($episodes|length)>1 or ($movies|length)>1 or ($rows|length)>1) as $multi |
      (($i.title // "")|test("([Ss][0-9]{1,3}[Ee][0-9]{1,3}([Ee-][0-9]|.*[Ss][0-9]{1,3}[Ee][0-9])|complete|season[ ._-]*[0-9]|[Ss][0-9]{1,3}([ ._-]|$))";"i")) as $hint |
      ([$automation[0].actions[]?|select(.app==$app and .kind=="import-retry" and ((.downloadId // "")|ascii_downcase)==$id)]|sort_by(.startedAt)) as $retries |
      ([$i.statusMessages[]?.messages[]?]) as $reasons |
      (($reasons|length)>0 and all($reasons[];test("being used by another process|sharing violation|resource (temporarily unavailable|busy)|temporarily locked";"i"))) as $transient |
      ["Download ID: "+(if $id!="" then $id else "not supplied; queue row "+($i.id|tostring) end),
       "Queue scope: "+($rows|length|tostring)+" related row(s); native episode IDs="+($episodes|length|tostring)+"; native movie IDs="+($movies|length|tostring)+".",
       (if $multi then "Pack/multi-target evidence: grouped queue rows/IDs; rejection automation remains blocked. Related rows may be duplicate tracking; no title-based identity is inferred."
        elif $app=="Sonarr" and $hint then "Possible pack: release-name hint only; exact episode coverage is unproven. Rejection automation remains blocked."
        else "Pack evidence: none established; ordinary exact-target safeguards still apply." end),
       (if $app=="Sonarr" and ($episodes|length)>0 then "Native episode IDs (up to 20): "+($episodes[:20]|map(tostring)|join(", ")) else empty end),
       "Import retries: "+($retries|length|tostring)+"/"+($maximum|tostring)+" recorded attempt(s) for this exact download.",
       (if ($retries|length)>0 then $retries[-1] as $last |
          "Last retry: "+($last.startedAt|strflocaltime("%Y-%m-%d %H:%M:%S %Z"))+"; command="+($last.commandId // "unverified"|tostring)+"; checkpoint="+($last.status // "unknown")+"; import outcome="+($last.outcome // "pending")+"."
        else empty end),
       (if ($retries|length)>=$maximum then "Retry limit reached: further automatic import retries are prohibited for this download."
        elif any($retries[];.status=="intent") then "Retry held: previous command outcome is uncertain; no request is replayed."
        elif ($retries|length)>0 then "Next retry spacing: not before "+(($retries[-1].startedAt+14400)|strflocaltime("%Y-%m-%d %H:%M:%S %Z"))+"; four-hour action windows and fresh safety checks still apply."
        elif $transient then "Retry not submitted: native Auto import is eligible only after six-hour grace, stable exact evidence, budget and a four-hour action window."
        else "Automatic retry not eligible for the reported reasons; policy, identity, storage and unknown failures are preserved for their specific workflow." end),
       "Completed scan/search commands do not prove import. Payload and library media remain unchanged by this report."]|join("\n")' "$queue"
}

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
            local queue_presentation
            queue_presentation=$(arr_queue_presentation "$app" "$item" "$queue_file") || queue_presentation='Queue/retry presentation unavailable; no action or resolution inferred.'
            detail+=$'\n'"$queue_presentation"

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

# A persisted SAB warning is an event, not proof the job is still broken.
# Reconcile only this exact loader error against fresh native SAB snapshots.
# No filesystem reads, title-only episode inference, deletion or queue mutation.
sab_load_warning_cleanup_verified() {
    local text="$1" epoch="$2" native name mapped receipt="${MEDIA_CLEANUP_SOURCE_RECEIPTS:-/mnt/vault/cloud/logs/script/media_cleanup/sab/source-removals.json}" mounts
    [[ "$epoch" =~ ^[1-9][0-9]*$ && "$text" == 'Loading '*'/__ADMIN__/SABnzbd_nzo_data failed' && -f "$receipt" && ! -L "$receipt" ]] || return 1
    [[ "$SAB_STATUS_OK" == true && "$SAB_QUEUE_OK" == true && "$SAB_HISTORY_OK" == true ]] || return 1
    native=${text#Loading };native=${native%/__ADMIN__/SABnzbd_nzo_data failed};name=${native##*/}
    [[ "$native" == /* && "$native" != *'/../'* && "$native" != */.. ]] || return 1
    mounts=$(timeout --kill-after=1 4 docker inspect "${SAB_CONTAINER:-sabnzbd}" 2>/dev/null) || return 1
    mapped=$(jq -er --arg path "$native" '[.[0].Mounts[]?|select(.Type=="bind")|.Destination as $d|select($path|startswith($d+"/"))|{source:.Source,destination:$d}]|sort_by(.destination|length)|last as $m|select($m!=null)|$m.source+($path|ltrimstr($m.destination))' <<<"$mounts" 2>/dev/null) || return 1
    jq -en --arg path "$mapped" --arg name "$name" --argjson epoch "$epoch" --slurpfile r "$receipt" --slurpfile s "$SAB_STATUS" --slurpfile q "$SAB_QUEUE" --slurpfile h "$SAB_HISTORY" '
      $r[0].schema==1 and $r[0].records[$path].sourceAbsent==true and $r[0].records[$path].action=="quarantined" and $r[0].records[$path].at>=$epoch |
      . and (($s[0].status.folders|type)=="array") and all($s[0].status.folders[];.!=$name) and
      all($q[0].queue.slots[]?;(.filename // .name // "")!=$name) and
      all($h[0].history.slots[]?;(.name // .nzb_name // "")!=$name or .status=="Completed")' >/dev/null || return 1
}

sab_load_warning_recovered() {
    local text="$1" epoch="$2" path name
    [[ "$epoch" =~ ^[1-9][0-9]*$ && "$text" == 'Loading '*'/__ADMIN__/SABnzbd_nzo_data failed' ]] || return 1
    [[ "$SAB_STATUS_OK" == true && "$SAB_QUEUE_OK" == true && "$SAB_HISTORY_OK" == true ]] || return 1
    path=${text#Loading }; path=${path%/__ADMIN__/SABnzbd_nzo_data failed}; name=${path##*/}
    [[ -n "$name" ]] || return 1
    jq -en --arg name "$name" --argjson epoch "$epoch" --slurpfile s "$SAB_STATUS" --slurpfile q "$SAB_QUEUE" --slurpfile h "$SAB_HISTORY" '
      ($s[0].status.folders|type)=="array"
      and all($s[0].status.folders[]; .!=$name)
      and (any($q[0].queue.slots[]?;
        (.filename // .name // "")==$name and (.nzo_id // ""|length)>0
        and ((.time_added // 0 | tonumber?) // 0)>=$epoch
        and ((.status // ""|ascii_downcase) as $status | ["queued","paused","downloading","fetching","verifying","repairing","unpacking","moving"]|index($status)!=null))
      or any($h[0].history.slots[]?;
        (.name // .nzb_name // "")==$name and (.nzo_id // ""|length)>0
        and .status=="Completed" and ((.completed // 0 | tonumber?) // 0)>=$epoch))
    ' >/dev/null 2>&1
}

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

        local recovery_reason='exact native job registration after warning; orphan no longer listed'
        if sab_load_warning_cleanup_verified "$warning_text" "$warning_epoch";then
            recovery_reason='exact mapped source was quarantined after this warning; durable source-absence receipt and current SAB queues/orphans rechecked'
        elif sab_load_warning_recovered "$warning_text" "$warning_epoch";then :
        else recovery_reason='';fi
        if [[ -n "$recovery_reason" ]];then
            local warning_key="SABnzbd:warning:${issue_hash}"
            if jq -e --arg key "$warning_key" '.issues[$key].active==true' "$STATE_FILE" >/dev/null; then
                log "SAB loader warning recovered; Ack ID: $(issue_ack_id "$warning_key"); reason=$recovery_reason. Original: $warning_text"
                queue_group_notification "$warning_key" "recovered:$issue_hash" SABnzbd 'SAB orphan recovery verified' SAB_STATE_RECOVERED INFO 0 \
                    "Recovery evidence: $recovery_reason. No warning-history deletion or media mutation was performed by the monitor. Download/import completion remains independently monitored. Original warning: $warning_text" reconciled
            fi
            continue
        fi

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
    local listing
    listing=$(mktemp "${TMP_DIR}/sab-path.XXXXXX") || return 1
    # One bounded traversal supplies names AND sizes. No per-file stat process,
    # no following symlinks, and no partial enumeration interpreted as recovery.
    if ! timeout -k 1 "$SAB_FILESYSTEM_PATH_TIMEOUT_SECONDS" \
        find "$path" -type f -printf '%s\0%p\0' >"$listing" 2>/dev/null; then
        rm -f -- "$listing"
        return 1
    fi

    ###########################################################################
    # FILE ITERATOR
    ###########################################################################

    while IFS= read -r -d '' size && IFS= read -r -d '' file; do

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

    done <"$listing"
    rm -f -- "$listing"

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

mark_sab_filesystem_checked() {
    printf 'SAB:%s\nSABnzbd:policy-cleanup:%s\n' "$1" "${1,,}" >>"${TMP_DIR}/sab-filesystem-checked-keys"
}

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
    local fs_cursor fs_started=$SECONDS fs_last="" fs_total fs_processed=0
    fs_cursor=$(jq -r '.monitor.sabFilesystemCursor // ""' "$STATE_FILE") || return 1
    : >"${TMP_DIR}/sab-filesystem-checked-keys"
    jq -c --arg movie "${SAB_MOVIE_CATEGORY,,}" --arg tv "${SAB_TV_CATEGORY,,}" \
      --argjson cutoff "$((START_TIME-SAB_ORPHAN_IGNORE_HOURS*3600))" '
      .[] | select((.status // "" | ascii_downcase)=="completed")
      | select((.category // .cat // "" | ascii_downcase) as $cat | $cat==$movie or $cat==$tv)
      | select(.auditEpoch<=0 or .auditEpoch <= $cutoff)
      | . + {auditKey:(.nzo_id // ((.category // .cat // "")+":"+(.name // .nzb_name // "")))}
    ' "${TMP_DIR}/sab-normalized-history.json" >"$fs_candidates.all" || return 1
    jq -sc --arg cursor "$fs_cursor" 'sort_by(.auditKey) | .[] | select(.auditKey>$cursor)' \
      "$fs_candidates.all" >"$fs_candidates" || return 1
    fs_total=$(wc -l <"$fs_candidates")
    head -n "$SAB_FILESYSTEM_BATCH_ITEMS" "$fs_candidates" >"$fs_candidates.batch"
    while IFS= read -r item; do

        [ -n "$item" ] || continue
        if (( fs_processed > 0 && SECONDS-fs_started >= SAB_FILESYSTEM_BATCH_SECONDS )); then break; fi
        runtime_budget_allows_optional_phase "sab-filesystem-batch" || return 1
        fs_last=$(jq -r '.auditKey' <<<"$item") || return 1
        ((fs_processed++)) || true

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
            mark_sab_filesystem_checked "$fs_last"
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

        # An unresolved path is not proof of absence. Preserve prior issues.
        if [ -z "$completed_path" ]; then continue; fi
        if [ ! -e "$completed_path" ]; then
            mark_sab_filesystem_checked "$fs_last"
            continue
        fi

        # A proven rejection is intentionally awaiting scheduled quarantine,
        # not a missing import. Keep exact SAB identity binding; warn if the
        # cleanup deadline passes instead of suppressing a stuck cleanup forever.
        if policy_disposition_matches "$owner" "$nzo_id" "$item"; then
            mark_sab_filesystem_checked "$fs_last"
            if jq -e --arg id "${nzo_id,,}" '.actions[$id].cleanup.status=="manual_restore"' "${POLICY_STATE_FILE:-$STATE_DIR/policy-actions.json}" >/dev/null;then continue;fi
            if (( now-$(jq -r --arg id "${nzo_id,,}" '.actions[$id].startedAt' "${POLICY_STATE_FILE:-$STATE_DIR/policy-actions.json}") >= POLICY_CLEANUP_EXPECTED_HOURS*3600 )); then
                record_normalized_issue "SABnzbd:policy-cleanup:${nzo_id,,}" SABnzbd "$name" \
                  SAB_STRANDED_POLICY_CLEANUP WARNING waiting \
                  'Verified rejected payload still awaits quarantine beyond expected cleanup window' "$age" \
                  "Download ID: $nzo_id. Arr policy disposition verified; no import is expected for this rejected release. Payload remains at $completed_path after ${age}h. Check media_cleanup sab for queue/path/Mover/receipt blockers. No repeated download rejection or search was submitted."
            else
                debug_log "Verified policy rejection awaiting guarded scheduled quarantine: $nzo_id"
            fi
            continue
        fi

        #######################################################################
        # ANALYZE REMAINING CONTENT
        #######################################################################

        local stats

        if ! stats=$(analyze_sab_path "$completed_path"); then
            log "WARNING: SAB path audit incomplete or timed out; prior filesystem issues preserved: $completed_path"
            return 1
        fi

        mark_sab_filesystem_checked "$fs_last"
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

        IFS=$'\t' read -r total_files total_bytes media_files media_bytes sample_files \
            archive_files repair_files metadata_files other_files other_bytes < <(
            jq -r '[.totalFiles,.totalBytes,.mediaFiles,.mediaBytes,.sampleFiles,
              .archiveFiles,.repairFiles,.metadataFiles,.otherFiles,.otherBytes] | @tsv' <<<"$stats")


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

    done <"$fs_candidates.batch"
    local fs_state="${TMP_DIR}/state.fs-progress.json"
    # End-of-pass means all records after the previous cursor were inspected.
    # New/changed records sorting before it are picked up on the next hourly pass.
    if (( fs_processed >= fs_total )); then
        fs_last=""
    fi
    jq --arg cursor "$fs_last" '.monitor.sabFilesystemCursor=$cursor' "$STATE_FILE" >"$fs_state" && save_state "$fs_state" || return 1
    log "SAB filesystem slice: checked=$fs_processed remaining=$((fs_total-fs_processed)); unchecked issues preserved"
}

carry_deferred_filesystem_issue_counts() {
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
    local cursor
    cursor=$(jq -r '.monitor.sabFilesystemCursor // ""' "$STATE_FILE")
    [[ -n "$cursor" ]] || (( last<=0 || START_TIME-last >= SAB_FILESYSTEM_SCAN_INTERVAL_MINUTES*60 ))
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

        local failure_severity=ERROR
        [[ "${message,,}" != *"manually marked as failed"* ]] || failure_severity=INFO
        record_normalized_issue \
            "${app}:history:download-failed:${issue_id}" \
            "$app" \
            "$title" \
            "ARR_DOWNLOAD_FAILED_HISTORY" \
            "$failure_severity" \
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

# Close only exact, obsolete workflow attempts. This is NOT import proof and
# never authorizes cleanup, a new search, or deletion of SAB/library files.
record_inactive_target_reconciliation() {
    local id="$1" app="$2" record="$3" root key rows="$TMP_DIR/inactive-targets.jsonl" row kind target parent season episode
    local object="$TMP_DIR/inactive-object.json" owner="$TMP_DIR/inactive-parent.json" evidence="$TMP_DIR/inactive-evidence.jsonl" fingerprint count=0
    jq -e --arg key "FLOW:DOWNLOAD:$id" '.issues[$key].classification=="DOWNLOAD_FLOW_REVIEW_REQUIRED"' "$STATE_FILE" >/dev/null || return 1
    download_ledger_can_evaluate "$app" || return 1
    [[ "$SAB_HISTORY_OK" == true && "$SAB_QUEUE_OK" == true ]] || return 1
    download_ledger_arr_queue_contains "$app" "$id" && return 1
    jq -e --arg id "${id,,}" 'all(.history.slots[]?;(.nzo_id|ascii_downcase)!=$id)' "$SAB_HISTORY" >/dev/null || return 1
    jq -e --arg id "${id,,}" 'all(.queue.slots[]?;(.nzo_id|ascii_downcase)!=$id)' "$SAB_QUEUE" >/dev/null || return 1
    IFS=$'\t' read -r root key < <(arr_reconciliation_connection "$app")
    jq -c '.targets // {} | .[]' <<<"$record" >"$rows" || return 1
    [[ -s "$rows" ]] || return 1
    : >"$evidence"
    while IFS= read -r row;do
        runtime_budget_allows_optional_phase inactive-target-reconciliation || return 1
        if [[ "$app" == Sonarr ]];then
            kind=episode;target=$(jq -r '.episodeId // 0' <<<"$row");parent=$(jq -r '.seriesId // 0' <<<"$row")
            season=$(jq -r '.seasonNumber // -1' <<<"$row");episode=$(jq -r '.episodeNumber // -1' <<<"$row")
        else kind=movie;target=$(jq -r '.movieId // 0' <<<"$row");parent="$target";fi
        [[ "$target" =~ ^[1-9][0-9]*$ && "$parent" =~ ^[1-9][0-9]*$ ]] || return 1
        if api_get "$root/$kind/$target" "$key" "$object";then
            jq -e --argjson id "$target" '.id==$id and .monitored==false' "$object" >/dev/null || return 1
            if [[ "$app" == Sonarr ]];then
                [[ "$season" =~ ^[0-9]+$ && "$episode" =~ ^[0-9]+$ ]] || return 1
                jq -e --argjson p "$parent" --argjson s "$season" --argjson e "$episode" '.seriesId==$p and .seasonNumber==$s and .episodeNumber==$e' "$object" >/dev/null || return 1
                api_get "$root/series/$parent" "$key" "$owner" || return 1
                jq -e --argjson p "$parent" '.id==$p' "$owner" >/dev/null || return 1
            fi
            printf '%s:%s:%s:unmonitored\n' "$app" "$parent" "$target" >>"$evidence"
        elif [[ "$API_LAST_HTTP_CODE" == 404 ]];then
            # Parent deletion is required for a missing episode; a single
            # episode 404 during metadata refresh is insufficient evidence.
            if [[ "$app" == Sonarr ]];then
                if api_get "$root/series/$parent" "$key" "$owner";then return 1;fi
                [[ "$API_LAST_HTTP_CODE" == 404 ]] || return 1
            fi
            printf '%s:%s:%s:removed\n' "$app" "$parent" "$target" >>"$evidence"
        else return 1;fi
        count=$((count+1))
    done <"$rows"
    ((count>0)) || return 1
    fingerprint=$(sort "$evidence"|sha256sum|cut -d ' ' -f1)
    write_download_reconciliation_result "$id" "$app" true true inactive_target DOWNLOAD_FLOW_RECONCILED_INACTIVE INFO "$fingerprint" \
      'Exact native targets are removed or explicitly unmonitored; no current Arr/SAB job exists' \
      "Verified $count exact target(s). Closed only this obsolete monitor workflow after the normal two-scan grace. Import/download cancellation was not inferred. Arr, SAB and media were not changed."
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
                | if $result.scanOk then .downloadLedger[$id].reconciliationPolicyRevision=2 else . end
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
                or ((.value.reconciliationPolicyRevision // 0)<2 and $issues["FLOW:DOWNLOAD:"+.key].classification=="DOWNLOAD_FLOW_REVIEW_REQUIRED")
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

        if record_inactive_target_reconciliation "$download_id" "$app" "$refreshed_record";then continue;fi
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

apply_policy_ledger_dispositions() {
    if [ -r "${POLICY_STATE_FILE:-$STATE_DIR/policy-actions.json}" ] && policy_validate_journal "${POLICY_STATE_FILE:-$STATE_DIR/policy-actions.json}"; then
        local policy_tmp="$TMP_DIR/state.policy-ledger.json"
        jq --slurpfile p "${POLICY_STATE_FILE:-$STATE_DIR/policy-actions.json}" '
          reduce ($p[0].actions[]? | select(.status=="done" and .queueVerified==true)) as $a (.;
            if .downloadLedger[$a.downloadId] then
              .downloadLedger[$a.downloadId].arrIgnoredAt=$a.startedAt |
              .downloadLedger[$a.downloadId].policyDisposition=$a.mode
            else . end)' "$STATE_FILE" >"$policy_tmp" && save_state "$policy_tmp" || return 1
    fi

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

    apply_policy_ledger_dispositions || return 1
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
# GUARDED POLICY REMEDIATION
# Queue mutations are never retried. Payload deletion and forced import are
# prohibited here. The separate cleanup script consumes verified dispositions.
###############################################################################

###############################################################################
# AUTOMATION DOCUMENTS AND DURABLE IMPORT PROOF
# No media filesystem reads are performed by receipt capture/profile polling.
###############################################################################

# Shared v1 receipt contract, embedded verbatim in producer and consumer.
# Older receipts may lack optional enrichment; exact live identity validation
# remains mandatory before cleanup. History proof is not expired just by age.
arr_import_receipt_document_valid() {
    jq -e '
      def pos: type=="number" and .>0 and .==floor;
      def nonneg: type=="number" and .>=0 and .==floor;
      def text: type=="string" and length>0 and (contains("\u0000")|not);
      def absolute: text and startswith("/");
      .version==1 and (.receipts|type)=="object" and all(.receipts|to_entries[];
        .key as $key | .value |
        (.app=="Sonarr" or .app=="Radarr") and (.downloadId|text) and $key==(.app+":"+.downloadId) and
        (.targets|type)=="object" and (.targets|length)>0 and
        all(.targets[];
          (.fileId|pos) and (.targetId|pos) and (.parentId|pos) and (.pathAtImport|absolute) and
          (.kind=="episode" or .kind=="movie") and
          ((.parentExternalId // 0)|nonneg) and
          (if .kind=="episode" then
             ((.seasonNumber // 0)|nonneg) and ((.episodeNumber // 0)|nonneg) else .targetId==.parentId end)))' "$1" >/dev/null
}

# BEGIN EMBEDDED MEDIA PACK CONTRACT
# shellcheck shell=bash
# Shared pack contract v1; no source is disposable from a filename/title hint.
pack_document_valid() {
    jq -e '
      def pos:type=="number" and .>0 and .==floor;
      def relative:type=="string" and length>0 and (startswith("/")|not) and (test("(^|/)\\.\\.?(/|$)|//|[\\\\\u0000\n\r\t]")|not);
      .schema==1 and (.jobs|type)=="object" and (.jobs|length)<=128 and all(.jobs|to_entries[];
       .key as $id|.value|.app=="Sonarr" and .downloadId==$id and ($id|test("^[a-z0-9-]+$")) and (.createdAt|pos) and
       (.status as $s|["observing","blocked","queue_intent","queue_verified","resolved","review","manual_hold"]|index($s))!=null
      )' "$1" >/dev/null 2>&1
}
# Validate the immutable disposal plan independently of mutable lifecycle fields.
pack_plan_valid() {
    jq -e '
      def pos:type=="number" and .>0 and .==floor;
      def relative:type=="string" and length>0 and (startswith("/")|not) and (test("(^|/)\\.\\.?(/|$)|//|[\\\\\u0000\n\r\t]")|not);
      . as $plan|.app=="Sonarr" and (.downloadId|test("^[a-z0-9-]+$")) and (.seriesId|pos) and (.tvdbId|pos) and
      (.profileSignature|test("^[a-f0-9]{64}$")) and (.folder|startswith("/")) and (.source.fingerprint|test("^[a-f0-9]{64}$")) and
      (.source.complete==true) and (.source.files|type)=="array" and (.source.files|length)<=800 and (.source.directories|type)=="array" and (.source.directories|length)<=512 and .source.folder==.folder and (.files|type)=="array" and (.files|length)>0 and (.files|length)<=200 and
      (.targets|type)=="object" and (.targets|length)>0 and (.targets|length)<=40 and
      all(.targets|to_entries[];.key as $key|.value|(.id|pos) and (.id|tostring)==$key and (.seasonNumber|type)=="number" and .seasonNumber>=0 and (.episodeNumber|pos)) and
      all(.files[];(.relative|relative) and (.identity|test("^[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-9]+$")) and (.size|pos) and (.episodeIds|length)>0 and
        all(.episodeIds[];pos and ($plan.targets[tostring]!=null)) and (.disposition as $s|["redundant","rejected","required","unknown"]|index($s))!=null) and
      ([.files[].relative]|unique|length)==(.files|length) and
      ([.source.files[].relative]|unique|length)==(.source.files|length) and
      ([.files[].relative]|sort)==([.source.files[]|select(.video)|.relative]|sort) and
      all(.files[];. as $f|any($plan.source.files[];.relative==$f.relative and .identity==$f.identity and .size==$f.size and .video==true)) and
      (.queueIds|type)=="array" and (.queueIds|length)>0 and all(.queueIds[];pos) and
      (.accounted|type)=="boolean" and (.unknown|type)=="boolean" and
      all(.source.files[];(.relative|relative) and (.identity|type)=="string" and (.size|type)=="number" and .size>=0 and (.video|type)=="boolean")' "$1" >/dev/null 2>&1
}
pack_source_inventory() {
    local folder="$1" root="$2" output="$3" input="${TMP_DIR:?}/pack-inventory-input.json"
    jq -n --arg folder "$folder" --arg root "$root" '{folder:$folder,root:$root}' >"$input" || return 1
    timeout --kill-after=2 20 docker exec -i --user 99:100 "${SAB_CONTAINER:-sabnzbd}" python3 -I -c "$(pack_inventory_program)" <"$input" >"$output" 2>"$TMP_DIR/pack-inventory.err" || return 1
    jq -e --arg folder "$folder" '.schema==1 and .complete==true and .folder==$folder and (.files|type)=="array" and (.files|length)<=800' "$output" >/dev/null
}
pack_profile_signature() {
    jq -nSc --slurpfile p "$1" --slurpfile f "$2" '{profiles:[$p[0]|sort_by(.id)[]|{id,cutoff,upgradeAllowed,minFormatScore,cutoffFormatScore,minUpgradeFormatScore,items,formatItems}],formats:[$f[0]|sort_by(.id)[]|{id,specifications,includeCustomFormatWhenRenaming}]}' |sha256sum|cut -d ' ' -f1
}
pack_repair_held() {
    local parent="$1" file="${MEDIA_INTEGRITY_RECOVERY_FILE:-/mnt/vault/cloud/logs/script/media_integrity_audit/recovery.json}"
    [[ -f "$file" && ! -L "$file" ]] || return 0
    jq -e '.schema==1 and .workflow=="arr-native" and (.actions|type)=="object" and all(.actions[];(.app=="Sonarr" or .app=="Radarr") and (.parentId|type)=="number" and .parentId>0 and (.status as $s|["required","selected","grab_intent","downloading","imported","verifying","recovered","blocked","review","cancelled","resolved","retry_wait"]|index($s))!=null)' "$file" >/dev/null || return 0
    local rc=0
    jq -e --argjson parent "$parent" 'any(.actions[];.app=="Sonarr" and .parentId==$parent and (.status as $s|["recovered","resolved","cancelled"]|index($s))==null)' "$file" >/dev/null || rc=$?
    ((rc!=1))
}

pack_inventory_program() {
    cat <<'PACKPY'
"""Bounded read-only completed-download inventory; executed in existing SAB Python."""
import hashlib,json,os,stat,sys

def inventory(folder,root):
    def safe_path(p):
        return isinstance(p,str) and p.startswith('/') and not any(c in p for c in '\x00\n\r\t\\') and os.path.normpath(p)==p
    if not safe_path(folder) or not safe_path(root) or folder==root or not folder.startswith(root+'/'):
        raise ValueError('completed download path is outside the configured root')
    if os.path.realpath(folder)!=folder or os.path.realpath(root)!=root:
        raise ValueError('symlinked completed download path')
    device=os.lstat(folder).st_dev;files=[];directories=[];seen=[];todo=[folder];path_bytes=0
    def identity(s):return ':'.join(str(x) for x in (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns))
    while todo:
        directory=todo.pop();s=os.lstat(directory)
        if not stat.S_ISDIR(s.st_mode) or s.st_dev!=device:raise ValueError('unsafe directory or filesystem boundary')
        directories.append({'relative':os.path.relpath(directory,folder),'identity':identity(s)})
        if len(directories)>512:raise ValueError('directory inventory budget exceeded')
        seen.append((directory,identity(s)))
        with os.scandir(directory) as entries:
            for entry in entries:
                path=entry.path;s=entry.stat(follow_symlinks=False)
                if s.st_dev!=device or stat.S_ISLNK(s.st_mode):raise ValueError('symlink or filesystem boundary')
                if stat.S_ISDIR(s.st_mode):
                    if not safe_path(path) or len(directories)+len(todo)>=512:raise ValueError('unsafe directory or directory inventory budget exceeded')
                    todo.append(path);continue
                if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:raise ValueError('non-regular or hard-linked source entry')
                relative=os.path.relpath(path,folder)
                if not safe_path(path) or relative.startswith('../'):raise ValueError('unsafe source filename')
                path_bytes+=len(relative.encode('utf-8'))
                if path_bytes>131072 or len(files)>=800:raise ValueError('file inventory budget exceeded')
                files.append({'relative':relative,'size':s.st_size,'identity':identity(s),'video':os.path.splitext(relative)[1].lower() in ('.mkv','.mp4','.m4v','.avi','.mov','.ts','.m2ts','.wmv','.webm')})
                seen.append((path,identity(s)))
    if sum(f['video'] for f in files)>200:raise ValueError('video inventory budget exceeded')
    for path,expected in seen:
        if identity(os.lstat(path))!=expected:raise ValueError('source changed during inventory')
    data={'folder':folder,'files':sorted(files,key=lambda f:f['relative']),'directories':sorted(directories,key=lambda d:d['relative'])}
    data['fingerprint']=hashlib.sha256(json.dumps(data,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    return {'schema':1,'complete':True,**data}

if __name__=='__main__':
    try:
        request=json.load(sys.stdin);json.dump(inventory(request['folder'],request['root']),sys.stdout,separators=(',',':'));sys.stdout.write('\n')
    except (OSError,ValueError,KeyError,TypeError) as e:
        print('Pack source inventory unverified: '+str(e),file=sys.stderr);sys.exit(1)
PACKPY
}
# END EMBEDDED MEDIA PACK CONTRACT

automation_document_valid() {
    local file="$1" kind="$2"
    case "$kind" in
        actions)
            jq -e '.version==1 and (.actions|type)=="object" and (.observations|type)=="object" and (.profiles|type)=="object" and (.events|type)=="object" and (.missing|type)=="object" and
              all(.actions[]; (.app=="Sonarr" or .app=="Radarr") and (.kind=="missing-search" or .kind=="import-retry") and
                (.status=="intent" or .status=="accepted" or .status=="completed" or .status=="failed") and
                ([.startedAt,.targetId,.parentId]|all(.[];type=="number" and .>0 and .==floor)) and
                (if .kind=="missing-search" then
                  .command==(if .app=="Sonarr" then {name:"EpisodeSearch",episodeIds:[.targetId]} else {name:"MoviesSearch",movieIds:[.targetId]} end)
                 else .command.name==(if .app=="Sonarr" then "DownloadedEpisodesScan" else "DownloadedMoviesScan" end) and
                   .command.importMode=="Auto" and .command.downloadClientId==.downloadId and (.command.path|startswith("/")) end))' "$file" >/dev/null ;;
        receipts) arr_import_receipt_document_valid "$file" ;;
        *) return 1 ;;
    esac
}

automation_publish_document() {
    local candidate="$1" target="$2" kind="$3"
    automation_document_valid "$candidate" "$kind" || return 1
    if [ -f "$target" ] && cmp -s -- "$candidate" "$target"; then rm -f -- "$candidate"; return 0; fi
    sync -- "$candidate" || return 1
    if [ -f "$target" ] && automation_document_valid "$target" "$kind"; then
        cp -- "$target" "${target}.bak.tmp.$$" && sync -- "${target}.bak.tmp.$$" &&
          mv -f -- "${target}.bak.tmp.$$" "${target}.bak" || return 1
    fi
    mv -f -- "$candidate" "$target" && sync -- "$target" && sync -- "$(dirname -- "$target")"
}

append_native_import_receipt_events() {
    jq -c --arg app "$1" '
          (if type=="array" then . else .records end)[] | select(.eventType=="downloadFolderImported" and ((.data.downloadClient // ""|ascii_downcase)=="sabnzbd")) |
          (.downloadId // ""|ascii_downcase) as $download | (.data.fileId|tonumber? // 0) as $file |
          (if $app=="Sonarr" then .episodeId else .movieId end) as $target |
          (if $app=="Sonarr" then .seriesId else .movieId end) as $parent |
          select($download!="" and $file>0 and $target>0 and $parent>0 and (.data.importedPath // "")!="") |
          (try (.date|sub("\\.[0-9]+Z$";"Z")|fromdateiso8601) catch 0) as $epoch | select($epoch>0) |
          {app:$app,downloadId:$download,historyId:.id,importedAt:$epoch,release:.sourceTitle,
            target:{kind:(if $app=="Sonarr" then "episode" else "movie" end),targetId:$target,parentId:$parent,fileId:$file,
              parentExternalId:(if $app=="Sonarr" then (.series.tvdbId // 0) else (.movie.tmdbId // 0) end),
              seasonNumber:(.episode.seasonNumber // null),episodeNumber:(.episode.episodeNumber // null),
              pathAtImport:.data.importedPath,droppedPath:(.data.droppedPath // ""),importedAt:$epoch,historyId:.id}}' "$2" >>"$3" || return 1
}

# Incremental history in older Arr/cache versions may omit embedded Series /
# Movie resources. Add stable identity only after exact native object/file/path
# verification. Four lookups per scan bound API work; failed proofs retry daily.
enrich_import_receipt_identities() {
    local document="$1" list="$TMP_DIR/receipt-identity-candidates.jsonl" entry app receipt_key target_key root key kind target parent file_id
    local current="$TMP_DIR/receipt-identity-target.json" media="$TMP_DIR/receipt-identity-file.json" owner="$TMP_DIR/receipt-identity-parent.json"
    local expected="$TMP_DIR/receipt-identity-expected.json" history="$TMP_DIR/receipt-identity-history.json" external owner_kind tmp="$TMP_DIR/receipt-identities-updated.json"
    jq -c --argjson now "$START_TIME" '[.receipts|to_entries[]|select(.value.conflict!=true)|. as $r|
      .value.targets|to_entries[]|select((.value.parentExternalId // 0)==0 and $now-(.value.identityCheckedAt // 0)>=86400)|
      {app:$r.value.app,downloadId:$r.value.downloadId,receiptKey:$r.key,targetKey:.key,target:.value}]|.[:4][]' "$document" >"$list" || return 1
    while IFS= read -r entry; do
        runtime_budget_allows_optional_phase import-receipt-identity || break
        app=$(jq -r '.app' <<<"$entry"); receipt_key=$(jq -r '.receiptKey' <<<"$entry"); target_key=$(jq -r '.targetKey' <<<"$entry")
        printf '%s' "$entry" | jq '.target' >"$expected"
        kind=$(jq -r '.kind' "$expected"); target=$(jq -r '.targetId' "$expected"); parent=$(jq -r '.parentId' "$expected"); file_id=$(jq -r '.fileId' "$expected")
        jq --arg r "$receipt_key" --arg t "$target_key" --argjson now "$START_TIME" '.receipts[$r].targets[$t].identityCheckedAt=$now' "$document" >"$tmp" && mv -- "$tmp" "$document" || return 1
        IFS=$'\t' read -r root key < <(arr_reconciliation_connection "$app")
        api_get "$root/$kind/$target" "$key" "$current" && api_get "$root/${kind}file/$file_id" "$key" "$media" || continue
        jq -e --slurpfile e "$expected" '.id==$e[0].targetId and .hasFile==true and
          (if $e[0].kind=="episode" then .seriesId==$e[0].parentId and .episodeFileId==$e[0].fileId and
            ($e[0].seasonNumber==null or .seasonNumber==$e[0].seasonNumber) and ($e[0].episodeNumber==null or .episodeNumber==$e[0].episodeNumber)
           else .movieFileId==$e[0].fileId end)' "$current" >/dev/null || continue
        jq -e --slurpfile e "$expected" '.id==$e[0].fileId and
          (if $e[0].kind=="episode" then .seriesId==$e[0].parentId else .movieId==$e[0].parentId end)' "$media" >/dev/null || continue
        owner_kind=movie; [ "$kind" != episode ] || owner_kind=series
        if [ "$kind" = movie ]; then cp -- "$current" "$owner" || return 1
        else api_get "$root/$owner_kind/$parent" "$key" "$owner" || continue; fi
        external=$(jq -r --arg kind "$kind" 'if $kind=="episode" then (.tvdbId // 0) else (.tmdbId // 0) end' "$owner")
        [[ "$external" =~ ^[1-9][0-9]*$ ]] || continue
        if ! jq -e --slurpfile e "$expected" '.path==$e[0].pathAtImport' "$media" >/dev/null; then
            # A rename that preceded enrichment requires the ORIGINAL exact
            # native event to expose the same stable external identity.
            fetch_arr_history_by_download_id "$app" "$(jq -r '.downloadId' <<<"$entry")" "$history" || continue
            jq -e --slurpfile e "$expected" --argjson external "$external" 'any(.records[]?;
              .eventType=="downloadFolderImported" and .id==$e[0].historyId and (.data.fileId|tonumber?)==$e[0].fileId and
              .data.importedPath==$e[0].pathAtImport and
              (if $e[0].kind=="episode" then .seriesId==$e[0].parentId and .episodeId==$e[0].targetId and .series.tvdbId==$external
               else .movieId==$e[0].targetId and .movie.tmdbId==$external end))' "$history" >/dev/null || continue
        fi
        jq --arg r "$receipt_key" --arg t "$target_key" --argjson external "$external" --slurpfile current "$current" '
          .receipts[$r].targets[$t].parentExternalId=$external |
          .receipts[$r].targets[$t].seasonNumber=(.receipts[$r].targets[$t].seasonNumber // $current[0].seasonNumber // null) |
          .receipts[$r].targets[$t].episodeNumber=(.receipts[$r].targets[$t].episodeNumber // $current[0].episodeNumber // null)' "$document" >"$tmp" && mv -- "$tmp" "$document" || return 1
    done <"$list"
}

capture_durable_import_receipts() {
    [ "$IMPORT_RECEIPTS_ENABLED" = true ] || return 0
    local file="$STATE_DIR/import-receipts.json" tmp="$TMP_DIR/import-receipts-working.json" events="$TMP_DIR/import-proof-events.jsonl"
    local app history
    if [ -e "$file" ]; then
        if ! automation_document_valid "$file" receipts; then
            record_normalized_issue Monitor:import-receipts Monitor 'Import receipt store invalid' IMPORT_RECEIPT_STATE ERROR invalid \
              'Receipt store preserved; automatic proof capture stopped' 0 'Restore or inspect import-receipts.json; cleanup will not use invalid receipt data.'
            return 1
        fi
        cp -- "$file" "$tmp" || return 1
    else printf '{"version":1,"receipts":{}}\n' >"$tmp" || return 1; fi
    : >"$events"
    for app in Sonarr Radarr; do
        case "$app" in
            Sonarr) [ "$SONARR_AUDIT_OK" = true ] || continue; history="$SONARR_AUDIT_HISTORY" ;;
            Radarr) [ "$RADARR_AUDIT_OK" = true ] || continue; history="$RADARR_AUDIT_HISTORY" ;;
        esac
        [ -f "$history" ] || continue
        append_native_import_receipt_events "$app" "$history" "$events" || return 1
    done
    if [ "$SAB_HISTORY_OK" = true ] && [ -f "$SAB_HISTORY" ]; then
        local jobs="$TMP_DIR/import-receipt-backfill.jsonl" job id page="$TMP_DIR/import-receipt-backfill-history.json" checked="$TMP_DIR/import-receipt-backfill-checks.jsonl"
        : >"$checked"
        jq -c --slurpfile existing "$tmp" --slurpfile state "$STATE_FILE" --arg tv "${SAB_TV_CATEGORY,,}" --arg movie "${SAB_MOVIE_CATEGORY,,}" --argjson now "$START_TIME" '
          [.history.slots[] | select(.status=="Completed") |
            (.category // .cat // ""|ascii_downcase) as $cat | select($cat==$tv or $cat==$movie) |
            (if $cat==$tv then "Sonarr" else "Radarr" end) as $app | (.nzo_id|ascii_downcase) as $id |
            select($existing[0].receipts[$app+":"+$id]==null and $now-($state[0].monitor.importReceiptBackfill[$app+":"+$id] // 0)>=86400) |
            {app:$app,id:$id}] | .[:2][]' "$SAB_HISTORY" >"$jobs" || return 1
        while IFS= read -r job; do
            runtime_budget_allows_optional_phase import-receipt-backfill || break
            app=$(jq -r '.app' <<<"$job"); id=$(jq -r '.id' <<<"$job")
            if ! fetch_arr_history_by_download_id "$app" "$id" "$page"; then continue; fi
            if jq -e '.totalRecords==(.records|length)' "$page" >/dev/null; then
                append_native_import_receipt_events "$app" "$page" "$events" || return 1
            fi
            jq -nc --arg key "$app:$id" --argjson at "$START_TIME" '{key:$key,at:$at}' >>"$checked" || return 1
        done <"$jobs"
        if [ -s "$checked" ]; then
            local state_tmp="$TMP_DIR/state.receipt-backfill.json"
            jq --slurpfile checked "$checked" --argjson cutoff "$((START_TIME-365*86400))" '
              reduce $checked[] as $c (.; .monitor.importReceiptBackfill[$c.key]=$c.at) |
              .monitor.importReceiptBackfill |= with_entries(select(.value>=$cutoff))' "$STATE_FILE" >"$state_tmp" && save_state "$state_tmp" || return 1
        fi
    fi
    # Enrich old receipts even when this scan has no new native imports.
    # SAB UUID + immutable job identity bind imported evidence to the payload.
    [ "$SAB_HISTORY_OK" = true ] && [ -f "$SAB_HISTORY" ] || return 0
    local merged="$TMP_DIR/import-receipts.merged.json"
    jq --slurpfile events "$events" --slurpfile sab "$SAB_HISTORY" --argjson cutoff "$((START_TIME-IMPORT_RECEIPT_RETENTION_DAYS*86400))" '
      ($sab[0].history.slots | map({key:(.nzo_id|ascii_downcase),value:({nzo_id,name,storage,completed,category})}) | from_entries) as $jobs |
      reduce $events[] as $e (.; ($e.app+":"+$e.downloadId) as $key |
        .receipts[$key] as $old |
        if $jobs[$e.downloadId]==null then . else
          .receipts[$key] = (($old // {app:$e.app,downloadId:$e.downloadId,release:$e.release,firstImportAt:$e.importedAt,targets:{}}) |
            .conflict=((.conflict // false) or (.sab!=null and .sab!=$jobs[$e.downloadId])) |
            .sab=(.sab // $jobs[$e.downloadId]) |
            .firstImportAt=([(.firstImportAt // $e.importedAt),$e.importedAt]|min) |
            .lastImportAt=([(.lastImportAt // 0),$e.importedAt]|max) |
            ($e.target.kind+":"+($e.target.targetId|tostring)+":"+($e.target.fileId|tostring)) as $targetKey |
            (.targets[$targetKey] // {}) as $prior |
            .conflict=(.conflict or (($prior.parentExternalId // 0)>0 and ($e.target.parentExternalId // 0)>0 and $prior.parentExternalId!=$e.target.parentExternalId)) |
            .targets[$targetKey]=($prior+$e.target |
              .parentExternalId=(if ($prior.parentExternalId // 0)>0 then $prior.parentExternalId else ($e.target.parentExternalId // 0) end) |
              .seasonNumber=($e.target.seasonNumber // $prior.seasonNumber // null) |
              .episodeNumber=($e.target.episodeNumber // $prior.episodeNumber // null)))
        end) |
      .receipts |= with_entries(select(.value.conflict==true or .value.lastImportAt>=$cutoff))' "$tmp" >"$merged" || return 1
    enrich_import_receipt_identities "$merged" || return 1
    automation_publish_document "$merged" "$file" receipts || return 1
    debug_log 'Captured exact download/file-ID import receipts; unchanged evidence requires no storage rewrite'
}

automation_target_history() {
    local kind="$1" target="$2" root="$3" key="$4" output="$5" query
    if [ "$kind" = episode ]; then query="episodeId=$target"; else query="movieIds=$target"; fi
    api_get "$root/history?page=1&pageSize=1000&sortKey=date&sortDirection=descending&$query" "$key" "$output" || return 1
    jq -e --argjson target "$target" --arg kind "$kind" '(.records|type)=="array" and
      .totalRecords==(.records|length) and all(.records[]; (if $kind=="episode" then .episodeId else .movieId end)==$target)' "$output" >/dev/null
}

automation_last_moment_guard() {
    if jq -e '(.packId // "")!=""' "$1" >/dev/null;then pack_command_guard "$1";return $?;fi
    local candidate="$1" root="$2" key="$3" app kind target parent parent_kind object="$TMP_DIR/automation-final-object.json" owner="$TMP_DIR/automation-final-parent.json"
    app=$(jq -r '.app' "$candidate"); kind=$(jq -r '.mediaKind' "$candidate"); target=$(jq -r '.targetId' "$candidate"); parent=$(jq -r '.parentId' "$candidate")
    [[ "$target" =~ ^[1-9][0-9]*$ && "$parent" =~ ^[1-9][0-9]*$ ]] || return 1
    media_recovery_app_held "$app" "$parent" && return 1
    parent_kind=movie; [ "$kind" != episode ] || parent_kind=series
    api_get "$root/$kind/$target" "$key" "$object" && api_get "$root/$parent_kind/$parent" "$key" "$owner" || return 1
    jq -e --slurpfile c "$candidate" '.id==$c[0].targetId and .monitored==true and
      (if $c[0].mediaKind=="episode" then .seriesId==$c[0].parentId else true end) and
      (if $c[0].kind=="missing-search" then .hasFile==false and (.episodeFileId // .movieFileId // 0)==0 else true end)' "$object" >/dev/null || return 1
    jq -e --slurpfile c "$candidate" --slurpfile target "$object" '.id==$c[0].parentId and .monitored==true and (.tags|length)==0 and
      (if $c[0].mediaKind=="episode" then any(.seasons[]?; .seasonNumber==$target[0].seasonNumber and .monitored==true) else true end)' "$owner" >/dev/null || return 1
    fetch_arr_queue "$app" "$root" "$key" "$TMP_DIR/automation-final-queue.json" || return 1
    local history="$TMP_DIR/automation-final-history.json" id
    automation_target_history "$kind" "$target" "$root" "$key" "$history" || return 1
    # No deletion at any retained time: explicit native searches/scans must not
    # undo Plex deletion intent while unmonitoring is still catching up.
    jq -e 'all(.records[]; .eventType!="episodeFileDeleted" and .eventType!="movieFileDeleted")' "$history" >/dev/null || return 1
    if [ "$(jq -r '.kind' "$candidate")" = missing-search ]; then
        jq -e --slurpfile c "$candidate" 'all(.records[]; (if $c[0].mediaKind=="episode" then .seriesId else .movieId end)!=$c[0].parentId)' "$TMP_DIR/automation-final-queue.json" >/dev/null || return 1
    else
        id=$(jq -r '.downloadId' "$candidate")
        jq -e --arg id "$id" --slurpfile c "$candidate" '[.records[]|select((.downloadId // ""|ascii_downcase)==$id)] as $r |
          ($r|length)==1 and ($r[0]|{id,downloadId,outputPath,status,trackedDownloadState,statusMessages,episodeId,movieId,seriesId})==$c[0].queueProof' "$TMP_DIR/automation-final-queue.json" >/dev/null || return 1
    fi
    # A manual SAB job not yet represented by Arr is ambiguous: it may already
    # contain the missing media. Never launch a speculative duplicate search.
    fetch_sab_queue "$TMP_DIR/automation-final-sab.json" || return 1
    if [ "$(jq -r '.kind' "$candidate")" = import-retry ]; then
        jq -e --arg id "$id" 'all(.queue.slots[]?; (.nzo_id // ""|ascii_downcase)!=$id)' "$TMP_DIR/automation-final-sab.json" >/dev/null || return 1
    else
        local category="$SAB_MOVIE_CATEGORY"; [ "$app" != Sonarr ] || category="$SAB_TV_CATEGORY"
        jq -e --arg category "${category,,}" --slurpfile q "$TMP_DIR/automation-final-queue.json" '
          [$q[0].records[].downloadId|ascii_downcase] as $known |
          all(.queue.slots[]? | select((.cat // .category // ""|ascii_downcase)==$category); (.nzo_id|ascii_downcase) as $id | ($known|index($id))!=null)' "$TMP_DIR/automation-final-sab.json" >/dev/null || return 1
    fi
}

automation_followup_imports() {
    local record action="$TMP_DIR/automation-followup-action.json" id app root key kind target parent current="$TMP_DIR/automation-followup-object.json"
    local file_id media="$TMP_DIR/automation-followup-file.json" owner="$TMP_DIR/automation-followup-parent.json" profile="$TMP_DIR/automation-followup-profile.json"
    local file_epoch proof="$TMP_DIR/automation-followup-proof.json" fingerprint runs parent_kind external profile_id
    while IFS= read -r record; do
        runtime_budget_allows_optional_phase automation-import-followup || return 0
        id=$(jq -r '.key' <<<"$record"); printf '%s' "$record" | jq '.value' >"$action"
        app=$(jq -r '.app' "$action"); kind=$(jq -r '.mediaKind' "$action"); target=$(jq -r '.targetId' "$action"); parent=$(jq -r '.parentId' "$action")
        monitor_mutation_gate "$app" || continue
        automation_state_update '.actions[$id].followupAt=$now' --arg id "$id" --argjson now "$START_TIME" || return 1
        IFS=$'\t' read -r root key < <(arr_reconciliation_connection "$app")
        api_get "$root/$kind/$target" "$key" "$current" || continue
        jq -e --slurpfile a "$action" '.id==$a[0].targetId and
          (if $a[0].mediaKind=="episode" then .seriesId==$a[0].parentId and
            ($a[0].identity.seasonNumber==null or .seasonNumber==$a[0].identity.seasonNumber) and
            ($a[0].identity.episodeNumber==null or .episodeNumber==$a[0].identity.episodeNumber) else true end)' "$current" >/dev/null || continue
        if ! jq -e '.hasFile==true and (.episodeFileId // .movieFileId // 0)>0' "$current" >/dev/null; then
            automation_state_update '.actions[$id].proofRuns=0 | .actions[$id].proofFingerprint=""' --arg id "$id" || return 1
            continue
        fi
        file_id=$(jq -r '.episodeFileId // .movieFileId // 0' "$current")
        [[ "$file_id" =~ ^[1-9][0-9]*$ ]] || continue
        api_get "$root/${kind}file/$file_id" "$key" "$media" || continue
        jq -e --slurpfile a "$action" --argjson id "$file_id" '.id==$id and .size>0 and (.path|length)>0 and
          (if $a[0].mediaKind=="episode" then .seriesId==$a[0].parentId else .movieId==$a[0].parentId end)' "$media" >/dev/null || continue
        file_epoch=$(date_to_epoch "$(jq -r '.dateAdded // ""' "$media")")
        ((file_epoch>=$(jq -r '.startedAt' "$action"))) || continue
        if [ "$(jq -r '.kind' "$action")" = import-retry ]; then
            [ -f "$STATE_DIR/import-receipts.json" ] && automation_document_valid "$STATE_DIR/import-receipts.json" receipts || continue
            jq -e --slurpfile a "$action" --argjson file "$file_id" '.receipts[$a[0].app+":"+$a[0].downloadId] |
              select(.conflict!=true) | any(.targets[]; .targetId==$a[0].targetId and .parentId==$a[0].parentId and .fileId==$file and .importedAt>=$a[0].startedAt)' \
              "$STATE_DIR/import-receipts.json" >/dev/null || continue
        fi
        parent_kind=movie; [ "$kind" != episode ] || parent_kind=series
        api_get "$root/$parent_kind/$parent" "$key" "$owner" || continue
        external=$(jq -r '.parentExternalId // (if .mediaKind=="episode" then .owner.tvdbId else .owner.tmdbId end) // 0' "$action")
        if [[ "$external" =~ ^[1-9][0-9]*$ ]]; then
            jq -e --argjson external "$external" --arg kind "$kind" '(if $kind=="episode" then .tvdbId else .tmdbId end)==$external' "$owner" >/dev/null || continue
        fi
        profile_id=$(jq -r '.qualityProfileId // 0' "$owner")
        [[ "$profile_id" =~ ^[1-9][0-9]*$ ]] || continue
        api_get "$root/qualityprofile/$profile_id" "$key" "$profile" || continue
        jq -e --slurpfile p "$profile" '(.customFormatScore|type)=="number" and .customFormatScore >= $p[0].minFormatScore and
          (.quality.quality.id as $quality | [$p[0].items[] | select(.allowed==true) | .quality.id, .items[]?.quality.id] | index($quality)!=null)' "$media" >/dev/null || continue
        fingerprint=$(printf '%s' "$kind:$target:$parent:$file_id:$file_epoch" | sha256sum | awk '{print $1}')
        automation_state_update '.actions[$id].proofRuns=(if .actions[$id].proofFingerprint==$fp then ((.actions[$id].proofRuns // 0)+1) else 1 end) | .actions[$id].proofFingerprint=$fp' \
          --arg id "$id" --arg fp "$fingerprint" || return 1
        runs=$(jq -r --arg id "$id" '.actions[$id].proofRuns' "$AUTOMATION_STATE_FILE")
        if ((runs>=2)); then
            automation_state_update '.actions[$id] += {outcome:"import_verified",status:"completed",verifiedFileId:$file,verifiedAt:$now}' \
              --arg id "$id" --argjson file "$file_id" --argjson now "$START_TIME" || return 1
        fi
    done < <(jq -c --argjson now "$START_TIME" '[.actions|to_entries[]|select(.value.outcome!="import_verified" and
      $now-(.value.followupAt // 0)>=(if (.value.proofRuns // 0)>0 then 240 else 3600 end) and $now-.value.startedAt<30*86400)]|
      sort_by(.value.followupAt // 0)|.[:4][]' "$AUTOMATION_STATE_FILE")
}


automation_state_update() {
    local filter="$1"; shift
    local candidate="$TMP_DIR/automation-updated.json"
    jq "$@" "$filter" "$AUTOMATION_STATE_FILE" >"$candidate" &&
      automation_publish_document "$candidate" "$AUTOMATION_STATE_FILE" actions
}

automation_event() {
    local id="$1" app="$2" title="$3" detail="$4"
    local signature; signature=$(printf '%s' "$detail" | sha256sum | awk '{print $1}')
    automation_state_update '.events[$id]={app:$app,title:$title,detail:$detail,signature:$signature,at:$now}' \
      --arg signature "$signature" --arg id "$id" --arg app "$app" --arg title "$title" --arg detail "$detail" --argjson now "$START_TIME"
}

automation_window_open() {
    local hour minute
    hour=$(TZ="$AUTOMATION_TIMEZONE" date -d "@$START_TIME" +%H)
    minute=$(TZ="$AUTOMATION_TIMEZONE" date -d "@$START_TIME" +%M)
    (( (10#$hour-AUTOMATION_BATCH_HOUR_OFFSET+24)%4==0 && 10#$minute<AUTOMATION_BATCH_WINDOW_MINUTES ))
}

automation_api_ready() {
    [ "$SONARR_API_OK" = true ] && [ "$RADARR_API_OK" = true ] &&
      [ "$SONARR_QUEUE_OK" = true ] && [ "$RADARR_QUEUE_OK" = true ] &&
      [ "$SAB_API_OK" = true ] && [ "$SAB_HISTORY_OK" = true ] && [ "$SAB_QUEUE_OK" = true ] || return 1
    jq -es 'all(.[][]; (.type // ""|ascii_downcase)!="error" and (.type // ""|ascii_downcase)!="warning")' \
      "$SONARR_HEALTH" "$RADARR_HEALTH" >/dev/null
}

automation_profile_audit() {
    local app="$1" root key previous checked profiles="$TMP_DIR/automation-profiles.json" formats="$TMP_DIR/automation-formats.json"
    local summary="$TMP_DIR/automation-profile-summary.json" signature old_signature old_count issues hold=0
    IFS=$'\t' read -r root key < <(arr_reconciliation_connection "$app")
    checked=$(jq -r --arg app "$app" '.profiles[$app].checkedAt // 0' "$AUTOMATION_STATE_FILE")
    if ((START_TIME-checked<AUTOMATION_PROFILE_POLL_MINUTES*60)) && ! automation_window_open; then return 0; fi
    api_get "$root/qualityprofile" "$key" "$profiles" && api_get "$root/customformat" "$key" "$formats" || return 1
    jq -e 'type=="array" and length>0 and all(.[]; .id>0 and (.items|type)=="array" and (.formatItems|type)=="array")' "$profiles" >/dev/null || return 1
    jq -e 'type=="array"' "$formats" >/dev/null || return 1
    jq -n --slurpfile profiles "$profiles" --slurpfile formats "$formats" '
      {profiles:($profiles[0]|sort_by(.id)),formats:($formats[0]|sort_by(.id)),issues:[
        $profiles[0][] as $p |
        ([$p.items[] | select(.allowed==true) | .quality.id, .id, .items[]?.quality.id, .items[]?.id] | map(select(.!=null))) as $allowed |
        ([$p.formatItems[] | .score | select(.>0)] | add // 0) as $ceiling |
        ([$formats[0][].id]) as $formats |
        (if ($allowed|length)==0 then {id:(($p.id|tostring)+":qualities"),title:$p.name,reason:"Quality profile has no allowed quality"} else empty end),
        (if ($allowed|index($p.cutoff))==null then {id:(($p.id|tostring)+":cutoff"),title:$p.name,reason:"Quality cutoff is not an allowed quality/group"} else empty end),
        (if $p.minFormatScore>$ceiling then {id:(($p.id|tostring)+":minimum"),title:$p.name,reason:("Minimum format score "+($p.minFormatScore|tostring)+" exceeds the sum of all positive scores "+($ceiling|tostring))} else empty end),
        (if any($p.formatItems[]; .format as $id | ($formats|index($id))==null) then {id:(($p.id|tostring)+":format"),title:$p.name,reason:"Profile references a custom-format ID absent from the catalog"} else empty end)
      ]}' >"$summary" || return 1
    signature=$(jq -Sc '{profiles:[.profiles[]|{id,cutoff,upgradeAllowed,minFormatScore,cutoffFormatScore,minUpgradeFormatScore,items,formatItems}],formats:[.formats[]|{id,specifications,includeCustomFormatWhenRenaming}]}' "$summary" | sha256sum | awk '{print $1}')
    old_signature=$(jq -r --arg app "$app" '.profiles[$app].signature // ""' "$AUTOMATION_STATE_FILE")
    hold=$(jq -r --arg app "$app" '.profiles[$app].holdUntil // 0' "$AUTOMATION_STATE_FILE")
    if [ -n "$old_signature" ] && [ "$old_signature" != "$signature" ]; then
        hold=$((START_TIME+4*3600))
        automation_event "profiles:$app:$START_TIME" "$app" 'Quality/custom-format configuration changed' \
          'Detected native profile/custom-format changes, including changes produced by Recyclarr. New automated rejection, retry and search actions are held for four hours. Profiles and scores were not modified.' || return 1
    fi
    automation_state_update '.profiles[$app]={signature:$signature,checkedAt:$now,holdUntil:$hold,issues:$summary[0].issues,profileCount:($summary[0].profiles|length)}' \
      --arg app "$app" --arg signature "$signature" --argjson now "$START_TIME" --argjson hold "$hold" --slurpfile summary "$summary"
}

automation_prepare() {
    AUTOMATION_STATE_FILE="$STATE_DIR/automation-actions.json"
    AUTOMATION_CONTROLS_OK=false
    if [ ! -e "$AUTOMATION_STATE_FILE" ]; then
        printf '{"version":1,"actions":{},"observations":{},"profiles":{},"events":{},"missing":{}}\n' >"$TMP_DIR/automation-initial.json"
        automation_publish_document "$TMP_DIR/automation-initial.json" "$AUTOMATION_STATE_FILE" actions || return 1
    fi
    if ! automation_document_valid "$AUTOMATION_STATE_FILE" actions; then
        record_normalized_issue Monitor:automation-state Monitor 'Automation journal invalid' ARR_AUTOMATION_STATE ERROR invalid \
          'New automated actions stopped; journal preserved' 0 'Restore or inspect automation-actions.json before allowing new actions; monitoring continues.'
        return 1
    fi
    automation_state_update '.observations |= with_entries(select(.value.lastAt>=$cutoff)) |
      .events |= with_entries(select(.value.at>=$retention)) |
      .actions |= with_entries(select(.value.status=="intent" or .value.status=="failed" or .value.startedAt>=$retention))' \
      --argjson cutoff "$((START_TIME-86400))" --argjson retention "$((START_TIME-365*86400))" || return 1
    automation_api_ready || return 0
    local app
    for app in Sonarr Radarr; do
        if ! automation_profile_audit "$app"; then
            # A failed forced window audit must not be treated as restored on
            # the next cached off-window scan; require a successful re-poll.
            automation_state_update '.profiles[$app].checkedAt=0' --arg app "$app" || return 1
            record_normalized_issue "Monitor:profile-audit:$app" Monitor "$app profile audit unavailable" ARR_PROFILE_AUDIT WARNING unavailable \
              'Current profile/custom-format catalog could not be validated' 0 'No new automated actions are allowed until the read-only profile audit succeeds.'
            return 0
        fi
    done
    if jq -e --argjson now "$START_TIME" 'all(.profiles[]; .holdUntil<=$now and (.issues|length)==0)' "$AUTOMATION_STATE_FILE" >/dev/null &&
       ! jq -e 'any(.actions[]; .status=="intent")' "$AUTOMATION_STATE_FILE" >/dev/null; then
        AUTOMATION_CONTROLS_OK=true
    fi
}

automation_observe_candidate() {
    local id="$1" fingerprint="$2" min_seconds="${3:-240}"
    automation_state_update '
      .observations[$id] as $old |
      .observations[$id]={fingerprint:$fp,
        firstAt:(if $old.fingerprint==$fp and $now-$old.lastAt<=1800 then $old.firstAt else $now end),
        lastAt:$now,runs:(if $old.fingerprint==$fp and $now-$old.lastAt<=1800 then ($old.runs+1) else 1 end)}' \
      --arg id "$id" --arg fp "$fingerprint" --argjson now "$START_TIME" || return 1
    jq -e --arg id "$id" --argjson now "$START_TIME" --argjson minimum "$min_seconds" \
      '.observations[$id].runs>=2 and $now-.observations[$id].firstAt>=$minimum' "$AUTOMATION_STATE_FILE" >/dev/null
}

automation_action_budget() {
    local policy="$STATE_DIR/policy-actions.json" counter="$TMP_DIR/automation-budget.jsonl" today run
    jq -e 'all(.actions[]; .status!="intent")' "$AUTOMATION_STATE_FILE" >/dev/null || return 1
    jq -c '.actions[]|{startedAt}' "$AUTOMATION_STATE_FILE" >"$counter" || return 1
    if [ -f "$policy" ]; then
        policy_validate_journal "$policy" || return 1
        jq -c '.actions[]|{startedAt}' "$policy" >>"$counter" || return 1
        # Do not race any unresolved policy mutation or replacement request.
        jq -e 'all(.actions[]; .status=="done")' "$policy" >/dev/null || return 1
    fi
    local recovery_file="${MEDIA_INTEGRITY_RECOVERY_FILE:-/mnt/vault/cloud/logs/script/media_integrity_audit/recovery.json}"
    media_recovery_journal_valid || return 1
    jq -c '.actions[]|if (.attempts // []|length)>0 then .attempts[]|{startedAt:.at} else select((.grabSentAt // 0)>0)|{startedAt:.grabSentAt} end' "$recovery_file" >>"$counter" || return 1
    if [[ -f "$STATE_DIR/pack-actions.json" ]];then
      pack_document_valid "$STATE_DIR/pack-actions.json" || return 1
      jq -c '.jobs[]|select((.queueIntentAt // 0)>0)|{startedAt:.queueIntentAt}' "$STATE_DIR/pack-actions.json" >>"$counter" || return 1
    fi
    IFS=$'\t' read -r today run < <(jq -sr --argjson now "$START_TIME" '[([.[]|select(.startedAt>=$now-86400)]|length),([.[]|select(.startedAt>=$now)]|length)]|@tsv' "$counter")
    (( today<POLICY_MAX_ACTIONS_PER_DAY && run<POLICY_MAX_ACTIONS_PER_RUN ))
}

automation_no_active_command() {
    local root="$1" key="$2" commands="$TMP_DIR/automation-active-commands.json"
    api_get "$root/command" "$key" "$commands" || return 1
    jq -e 'type=="array" and all(.[]; ((.status=="queued" or .status=="started") and (.name|test("Search$|^Downloaded.*Scan$")))|not)' "$commands" >/dev/null
}

automation_command_readback() {
    local action_file="$1" root="$2" key="$3" command_id="$4" response="$TMP_DIR/automation-command.json"
    [[ "$command_id" =~ ^[1-9][0-9]*$ ]] || return 1
    api_get "$root/command/$command_id" "$key" "$response" || return 1
    jq -e --slurpfile action "$action_file" --argjson id "$command_id" '
      . as $response | $action[0].command as $request | .id==$id and .name==$request.name and (.body|type)=="object" and
      (.status=="queued" or .status=="started" or .status=="completed" or .status=="failed") and
      all($request|to_entries[]; . as $field |
        if $field.key=="importMode" then ($response.body[$field.key]|ascii_downcase)==($field.value|ascii_downcase)
        else $response.body[$field.key]==$field.value end)' "$response" >/dev/null
}

automation_submit_command() {
    local candidate="$1" root="$2" key="$3" action_id body command_id status
    monitor_mutation_gate "$(jq -r '.app' "$candidate")" || return 1
    automation_window_open && automation_action_budget && automation_no_active_command "$root" "$key" &&
      automation_last_moment_guard "$candidate" "$root" "$key" || return 1
    action_id=$(jq -r '.key' "$candidate"); action_id="$action_id:$START_TIME"
    usr_ops_arr_reserve "command:$action_id" "$(jq -r '.app' "$candidate")" "$(jq -r '.targetId' "$candidate")" || { printf '%s\n' 'Shared media action budget deferred command; no HTTP request sent' >>"$TMP_DIR/automation-deferrals.txt";return 0; }
    automation_state_update '.actions[$id]=$candidate[0]+{status:"intent",startedAt:$now,outcome:"pending"}' \
      --arg id "$action_id" --argjson now "$START_TIME" --slurpfile candidate "$candidate" || return 1
    body=$(jq -c '.command' "$candidate")
    rm -f -- "$TMP_DIR/automation-submit-response.json" || return 1
    local mutation_rc=0
    policy_mutate POST "$root/command" "$key" "$body" "$TMP_DIR/automation-submit-response.json" || mutation_rc=$?
    if ((mutation_rc==75));then
      usr_ops_arr_release_undispatched "command:$action_id" || true
      automation_state_update '.deferred //= {} | .deferred[$id]=(.actions[$id]+{outcome:"not_dispatched",reason:"Local lease/runtime gate refused before HTTP"}) | del(.actions[$id]) | .deferred |= with_entries(select(.value.startedAt>=$cutoff))' \
        --arg id "$action_id" --argjson cutoff "$((START_TIME-7*86400))" || return 1
      printf '%s\n' 'Local deadline/lease deferred a command before HTTP; no request dispatched and no uncertain intent left' >>"$TMP_DIR/automation-deferrals.txt"
      return 0
    fi
    command_id=$(jq -r '.id // 0' "$TMP_DIR/automation-submit-response.json" 2>/dev/null) || command_id=0
    [[ "$command_id" =~ ^[1-9][0-9]*$ ]] || return 1
    automation_state_update '.actions[$id].commandId=$command' --arg id "$action_id" --argjson command "$command_id" || return 1
    if automation_command_readback "$candidate" "$root" "$key" "$command_id"; then
        status=$(jq -r '.status' "$TMP_DIR/automation-command.json")
        case "$status" in failed|completed) ;; *) status=accepted;; esac
        local native_message
        native_message=$(jq -r '(if (.exception|type)=="object" then (.exception.message // .message // "") elif (.exception|type)=="string" and .exception!="" then .exception else (.message // "") end)|tostring|.[0:2000]' "$TMP_DIR/automation-command.json")
        automation_state_update '.actions[$id].status=$status | .actions[$id].nativeMessage=$message' --arg message "$native_message" --arg id "$action_id" --arg status "$status"
    else return 1; fi
}

automation_build_missing_candidate() {
    local app="$1" target="$2" parent="$3" kind="$4" root="$5" key="$6" output="$7"
    local object="$TMP_DIR/automation-target.json" owner="$TMP_DIR/automation-parent.json" history="$TMP_DIR/automation-target-history.json"
    local queue parent_kind=movie id_filter history_filter="$TMP_DIR/automation-protected.json"
    [[ "$target" =~ ^[1-9][0-9]*$ && "$parent" =~ ^[1-9][0-9]*$ ]] || return 1
    if [ "$kind" = episode ]; then queue="$SONARR_QUEUE"; parent_kind=series; id_filter="episodeId=$target"
    else queue="$RADARR_QUEUE"; id_filter="movieIds=$target"; fi
    # Protect entire parent while any pack/episode/movie queue item is active.
    jq -e --arg kind "$kind" --argjson parent "$parent" 'all(.records[]; (if $kind=="episode" then .seriesId else .movieId end)!=$parent)' "$queue" >/dev/null || return 1
    api_get "$root/$kind/$target" "$key" "$object" && api_get "$root/$parent_kind/$parent" "$key" "$owner" || return 1
    jq -e --argjson id "$target" --argjson parent "$parent" --arg kind "$kind" '.id==$id and .monitored==true and .hasFile==false and
      (if $kind=="episode" then .seriesId==$parent and .episodeFileId==0 and (.seasonNumber|type)=="number" and .seasonNumber>=0 and .episodeNumber>0 else .movieFileId==0 and .isAvailable==true end)' "$object" >/dev/null || return 1
    jq -e --argjson id "$parent" --slurpfile target "$object" --arg kind "$kind" '.id==$id and .monitored==true and (.tags|length)==0 and
      (if $kind=="episode" then any(.seasons[]?; .seasonNumber==$target[0].seasonNumber and .monitored==true) else true end)' "$owner" >/dev/null || return 1
    local available
    if [ "$kind" = episode ]; then available=$(date_to_epoch "$(jq -r '.airDateUtc // ""' "$object")")
    else available=$(date_to_epoch "$(jq -r '.added // ""' "$object")"); fi
    ((available>0 && START_TIME-available>=86400)) || return 1
    api_get "$root/history?page=1&pageSize=1000&sortKey=date&sortDirection=descending&$id_filter" "$key" "$history" || return 1
    jq -e --argjson id "$target" --arg kind "$kind" '.records|type=="array"' "$history" >/dev/null || return 1
    jq -e --argjson id "$target" --arg kind "$kind" --argjson cutoff "$((START_TIME-7*86400))" '
      .totalRecords==(.records|length) and all(.records[]; (if $kind=="episode" then .episodeId else .movieId end)==$id) and
      all(.records[]; .eventType!="episodeFileDeleted" and .eventType!="movieFileDeleted" and .eventType!="downloadFolderImported" and
        (.eventType!="grabbed" or ((try (.date|sub("\\.[0-9]+Z$";"Z")|fromdateiso8601) catch 0)<$cutoff)))' "$history" >/dev/null || return 1
    # Durable import evidence remains a deletion-intent veto after native history
    # has expired. Never search missing media that the script knows once existed.
    if [ -f "$STATE_DIR/import-receipts.json" ]; then
        automation_document_valid "$STATE_DIR/import-receipts.json" receipts || return 1
        jq -e --arg app "$app" --argjson id "$target" 'all(.receipts[] | select(.app==$app); all(.targets[]; .targetId!=$id))' "$STATE_DIR/import-receipts.json" >/dev/null || return 1
    fi
    jq -e --arg app "$app" --argjson id "$target" 'all(.downloadLedger[]? | select(.app==$app) | select((.arrImportedAt // 0)>0 or (.arrIgnoredAt // 0)>0 or (.manuallyDismissedAt // 0)>0 or ((.arrFailedAt // 0)==0 and (.sabFailedAt // 0)==0)); all(.targets[]?; (.episodeId // .movieId // 0)!=$id))' "$STATE_FILE" >/dev/null || return 1
    jq -n --arg app "$app" --arg kind "$kind" --argjson target "$target" --argjson parent "$parent" \
      --slurpfile object "$object" --slurpfile owner "$owner" \
      '{key:($app+":missing:"+($target|tostring)),app:$app,kind:"missing-search",mediaKind:$kind,targetId:$target,parentId:$parent,
        title:($owner[0].title+" / "+($object[0].title // "missing media")),
        identity:($object[0]|{id,seriesId,seasonNumber,episodeNumber,airDateUtc,hasFile,episodeFileId,movieFileId,monitored}),
        owner:($owner[0]|{id,tvdbId,tmdbId,qualityProfileId,monitored,tags,seasons:[.seasons[]?|{seasonNumber,monitored}]}),
        command:(if $kind=="episode" then {name:"EpisodeSearch",episodeIds:[$target]} else {name:"MoviesSearch",movieIds:[$target]} end)}' >"$output"
}

automation_fetch_missing() {
    local app="$1" root="$2" key="$3" output="$4" page=1 loaded=0 total=0 records="$TMP_DIR/automation-missing-pages.jsonl" count
    : >"$records"
    while ((loaded<AUTOMATION_MISSING_MAX_RECORDS)); do
        api_get "$root/wanted/missing?page=$page&pageSize=500&monitored=true" "$key" "$output" || return 1
        jq -e '(.records|type)=="array" and (.totalRecords|type)=="number"' "$output" >/dev/null || return 1
        total=$(jq '.totalRecords' "$output"); count=$(jq '.records|length' "$output")
        ((total<=AUTOMATION_MISSING_MAX_RECORDS)) || return 1
        jq -c '.records[]' "$output" >>"$records" || return 1
        loaded=$((loaded+count)); ((loaded>=total)) && break
        ((count>0)) || return 1; page=$((page+1))
    done
    jq -s --argjson total "$total" 'unique_by(.id) | select(length==$total) | {records:.,totalRecords:$total}' "$records" >"$output" || return 1
    jq -e '.records|type=="array"' "$output" >/dev/null
}

# Media integrity recovery owns this hold until a replacement passes full
# planned-range verification. Review/uncertain states never expire silently.
# Library protection ends after full replacement verification. Disposal problems
# concern the retired original only and must not block healthy library media.
# A persistent empty journal is installed with the audit. Missing/unreadable
# state is uncertainty, never permission to process a temporarily missing title.
media_recovery_journal_valid() {
    local file="${MEDIA_INTEGRITY_RECOVERY_FILE:-/mnt/vault/cloud/logs/script/media_integrity_audit/recovery.json}"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e '.schema==1 and .workflow=="arr-native" and (.actions|type)=="object" and all(.actions[];
      (.app=="Sonarr" or .app=="Radarr") and (.parentId|type)=="number" and .parentId>0 and
      (.status as $s|["required","selected","grab_intent","downloading","imported","verifying","recovered","blocked","review","cancelled","resolved","retry_wait"]|index($s))!=null)' "$file" >/dev/null 2>&1
}
media_recovery_ids() {
    local app="$1" output="$2" file="${MEDIA_INTEGRITY_RECOVERY_FILE:-/mnt/vault/cloud/logs/script/media_integrity_audit/recovery.json}"
    media_recovery_journal_valid || return 1
    jq --arg app "$app" '[.actions[]|select(.app==$app and (.status as $s|["recovered","resolved","cancelled"]|index($s))==null)|.parentId]|unique' "$file" >"$output"
}
media_recovery_app_held() {
    local app="$1" parent="${2:-0}" file="${MEDIA_INTEGRITY_RECOVERY_FILE:-/mnt/vault/cloud/logs/script/media_integrity_audit/recovery.json}" rc=0
    media_recovery_journal_valid || return 0
    jq -e --arg app "$app" --argjson parent "$parent" 'any(.actions[];.app==$app and ($parent==0 or .parentId==$parent) and (.status as $s|["recovered","resolved","cancelled"]|index($s))==null)' "$file" >/dev/null 2>&1 || rc=$?
    ((rc!=1))
}


process_media_integrity_recovery() {
    monitor_release_mutation_gates
    local script="${MEDIA_INTEGRITY_SCRIPT:-/boot/config/plugins/user.scripts/scripts/media_integrity_audit/script}" rc=0
    local allow=false
    if [[ "$ARR_AUTOMATION_ENABLED" == true && "$AUTOMATION_CONTROLS_OK" == true ]] && automation_window_open && automation_api_ready && automation_action_budget;then allow=true;fi
    [[ -f "$script" && ! -L "$script" ]] || return 0
    # The child may notify. Commit and release the parent's shared lease too;
    # releasing only the child's descriptor would still block an exclusive export.
    local child_lease_released=false
    if [[ "${MONITOR_STATE_LEASE_HELD:-false}" == true && -n "${STATE_EXPORT_FD:-}" ]];then
      commit_state_transaction before-integrity-child || return 1
      exec {STATE_EXPORT_FD}>&-;MONITOR_STATE_LEASE_HELD=false;child_lease_released=true
    fi
    (
        export SONARR_API_ROOT SONARR_API_KEY RADARR_API_ROOT RADARR_API_KEY
        export RECOVERY_ALLOW_GRAB="$allow" USR_OPS_SHARED_BUDGET_ACTIVE
        export MEDIA_AUTOMATION_RUN_ID="${MEDIA_AUTOMATION_RUN_ID:-media_health_monitor:$START_TIME:$$}"
        local remaining=$((START_TIME+MONITOR_RUNTIME_BUDGET_SECONDS-MONITOR_RUNTIME_RESERVE_SECONDS-$(date +%s)))
        ((remaining>0)) || exit 0
        ((remaining<=45)) || remaining=45
        timeout --signal=TERM --kill-after=5 "$remaining" /bin/bash "$script" --recovery-tick
    ) >"$TMP_DIR/media-integrity-recovery.log" 2>&1 || rc=$?
    if [[ "$child_lease_released" == true ]];then
      exec {STATE_EXPORT_FD}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || { MONITOR_EXPORT_LEASE_LOST=true;return 75; }
      if ! flock -s -w "$MONITOR_NOTIFY_LEASE_WAIT_SECONDS" "$STATE_EXPORT_FD";then exec {STATE_EXPORT_FD}>&-;MONITOR_EXPORT_LEASE_LOST=true;return 75;fi
      MONITOR_STATE_LEASE_HELD=true
    fi
    if ((rc==124 || rc==137)); then
        record_normalized_issue 'Monitor:media-integrity-recovery-timeout' Monitor 'Media recovery executor interrupted' MEDIA_RECOVERY_EXECUTOR_FAILED ERROR executor \
          'Bounded media recovery executor exceeded its runtime' 0 'Inspect media_integrity_audit --recovery-status. Durable intents/originals remain protected; no automatic replay or success is inferred.'
    elif ((rc!=0)); then log "WARNING: Media integrity recovery stopped safely (exit $rc); its own grouped report/journal owns the details";fi
}

automation_missing_searches() {
    automation_window_open || return 0
    local app root key wanted="$TMP_DIR/automation-wanted.json" baseline window surveyed cursor count selected="$TMP_DIR/automation-selected.json"
    local item target parent kind candidate="$TMP_DIR/automation-missing-candidate.json" hash previous survey_error
    window=$(TZ="$AUTOMATION_TIMEZONE" date -d "@$START_TIME" +%Y%m%d%H)
    for app in Sonarr Radarr; do
        surveyed=$(jq -r --arg app "$app" '.missing[$app].surveyedAt // 0' "$AUTOMATION_STATE_FILE")
        previous=$(jq -r --arg app "$app" '.missing[$app].window // ""' "$AUTOMATION_STATE_FILE")
        survey_error=$(jq -r --arg app "$app" '.missing[$app].surveyError // ""' "$AUTOMATION_STATE_FILE")
        if ((START_TIME-surveyed<AUTOMATION_MISSING_SURVEY_HOURS*3600)) && [ "$previous" != "$window" ] && [ -z "$survey_error" ]; then continue; fi
        IFS=$'\t' read -r root key < <(arr_reconciliation_connection "$app")
        if ! automation_fetch_missing "$app" "$root" "$key" "$wanted"; then
            automation_state_update '.missing[$app].surveyError=$error' --arg app "$app" \
              --arg error "Native wanted/missing survey was unavailable or incomplete (maximum $AUTOMATION_MISSING_MAX_RECORDS records). No speculative searches were submitted; retry waits for the next approved window." || return 1
            continue
        fi
        automation_state_update '.missing[$app].surveyError=""' --arg app "$app" || return 1
        baseline=$(jq -r --arg app "$app" '.missing[$app].baselineAt // 0' "$AUTOMATION_STATE_FILE")
        if ((baseline==0)); then
            # Existing missing backlogs have unknown deletion history at deploy.
            # Preserve them rather than redownloading something deleted in Plex.
            automation_state_update '.missing[$app]={baselineAt:$now,baselineIds:[$wanted[0].records[].id],surveyedAt:$now,window:$window,cursor:0,selected:[]}' \
              --arg app "$app" --argjson now "$START_TIME" --arg window "$window" --slurpfile wanted "$wanted" || return 1
            count=$(jq '.records|length' "$wanted")
            automation_event "missing-baseline:$app" "$app" 'Missing-media search baseline recorded' \
              "Preserved $count pre-existing missing monitored item(s), whose prior Plex deletion intent cannot be proven. Weekly bounded searches apply to newly missing, never-imported media; existing files, deletion history, holds, queues and tags remain protected." || return 1
            continue
        fi
        if [ "$previous" != "$window" ]; then
            jq --arg app "$app" --argjson limit "$AUTOMATION_MISSING_CANDIDATES_PER_APP" --slurpfile wanted "$wanted" '
              .missing[$app] as $m | [$wanted[0].records[] | . as $e | select(($m.baselineIds|index($e.id))==null)] as $new |
              (if ($new|length)==0 then [] else ($m.cursor % ($new|length)) as $start | ($new[$start:]+$new[:$start])[:$limit] end)' "$AUTOMATION_STATE_FILE" >"$selected" || return 1
            automation_state_update '.missing[$app].selected=$selected[0] | .missing[$app].window=$window | .missing[$app].surveyedAt=$now | .missing[$app].cursor=((.missing[$app].cursor // 0)+$limit)' \
              --arg app "$app" --arg window "$window" --argjson now "$START_TIME" --argjson limit "$AUTOMATION_MISSING_CANDIDATES_PER_APP" --slurpfile selected "$selected" || return 1
        fi
        while IFS= read -r item; do
            runtime_budget_allows_optional_phase automation-missing-search || return 0
            automation_action_budget || return 0
            target=$(jq -r '.id' <<<"$item")
            if [ "$app" = Sonarr ]; then parent=$(jq -r '.seriesId' <<<"$item"); kind=episode; else parent="$target"; kind=movie; fi
            if media_recovery_app_held "$app" "$parent"; then debug_log "Missing search deferred for recovery-held $app parent $parent";continue;fi
            jq -e --arg app "$app" --argjson target "$target" --argjson cutoff "$((START_TIME-7*86400))" 'all(.actions[]; .app!=$app or .kind!="missing-search" or .targetId!=$target or .startedAt<$cutoff)' "$AUTOMATION_STATE_FILE" >/dev/null || continue
            automation_build_missing_candidate "$app" "$target" "$parent" "$kind" "$root" "$key" "$candidate" || continue
            hash=$(jq -Sc 'del(.identity.lastSearchTime,.owner.statistics,.owner.nextAiring,.owner.previousAiring)' "$candidate" | sha256sum | awk '{print $1}')
            automation_observe_candidate "$app:missing:$target" "$hash" || continue
            # Repeat the exact current monitoring, history, queue and native-file
            # checks immediately before the one bounded search submission.
            fetch_arr_queue "$app" "$root" "$key" "$TMP_DIR/automation-current-queue.json" || continue
            if [ "$app" = Sonarr ]; then cp "$TMP_DIR/automation-current-queue.json" "$SONARR_QUEUE"; else cp "$TMP_DIR/automation-current-queue.json" "$RADARR_QUEUE"; fi
            automation_build_missing_candidate "$app" "$target" "$parent" "$kind" "$root" "$key" "$candidate" || continue
            if ! automation_submit_command "$candidate" "$root" "$key"; then
                if jq -e 'any(.actions[]; .status=="intent")' "$AUTOMATION_STATE_FILE" >/dev/null; then return 0; fi
            fi
        done < <(jq -c --arg app "$app" '.missing[$app].selected[]?' "$AUTOMATION_STATE_FILE")
    done
}

automation_import_retries() {
    automation_window_open || return 0
    local app queue item id root key reasons candidate="$TMP_DIR/automation-retry-candidate.json" sab="$TMP_DIR/automation-retry-sab.json"
    local added completed count last hash path target parent kind command allowed_root
    for app in Sonarr Radarr; do
        case "$app" in Sonarr) queue="$SONARR_QUEUE";kind=episode;command=DownloadedEpisodesScan;; Radarr) queue="$RADARR_QUEUE";kind=movie;command=DownloadedMoviesScan;; esac
        while IFS= read -r item; do
            automation_action_budget || return 0
            id=$(jq -r '.downloadId // ""|ascii_downcase' <<<"$item")
            [[ "$id" =~ ^[a-z0-9-]+$ ]] || continue
            if [[ -f "${PACK_STATE_FILE:-$STATE_DIR/pack-actions.json}" ]] && jq -e --arg id "$id" '.jobs[$id]!=null' "${PACK_STATE_FILE:-$STATE_DIR/pack-actions.json}" >/dev/null;then continue;fi
            # Only explicit transient locks/busy conditions qualify. Mixed
            # policy, permission, disk-space, identity and unknown reasons hold.
            jq -e '(.protocol|ascii_downcase)=="usenet" and .status=="completed" and (.trackedDownloadState=="importPending" or .trackedDownloadState=="importBlocked") and
              ([.statusMessages[]?.messages[]?] as $m | ($m|length)>0 and all($m[]; test("being used by another process|sharing violation|resource (temporarily unavailable|busy)|temporarily locked";"i")) and
                all($m[]; (test("custom format|not an upgrade|permission|denied|disk|space|unmatched|unknown";"i")|not)))' <<<"$item" >/dev/null || continue
            count=$(jq --arg id "$id" '[.actions[]|select(.kind=="import-retry" and .downloadId==$id)]|length' "$AUTOMATION_STATE_FILE")
            ((count<AUTOMATION_IMPORT_RETRY_MAX_ATTEMPTS)) || continue
            last=$(jq --arg id "$id" '[.actions[]|select(.kind=="import-retry" and .downloadId==$id)|.startedAt]|max // 0' "$AUTOMATION_STATE_FILE")
            jq -e --arg id "$id" 'all(.queue.slots[]?; (.nzo_id|ascii_downcase)!=$id)' "$SAB_QUEUE" >/dev/null || continue
            jq --arg id "$id" '[.history.slots[]?|select((.nzo_id|ascii_downcase)==$id and .status=="Completed")]|select(length==1)|.[0]' "$SAB_HISTORY" >"$sab" || continue
            completed=$(jq -r '.completed|tonumber? // 0' "$sab"); added=$(date_to_epoch "$(jq -r '.added // ""' <<<"$item")")
            ((completed>0 && added>0 && START_TIME-completed>=6*3600 && START_TIME-added>=6*3600)) || continue
            path=$(jq -r '.outputPath // ""' <<<"$item")
            allowed_root="$AUTOMATION_RADARR_COMPLETE_ROOT"; [ "$app" != Sonarr ] || allowed_root="$AUTOMATION_SONARR_COMPLETE_ROOT"
            [[ "$path" == "${allowed_root%/}/"* && "$path" != *'/../'* && "$path" != */.. && "$path" != *$'\n'* ]] || continue
            # Exact download-target history is required; no title-only retry.
            IFS=$'\t' read -r root key < <(arr_reconciliation_connection "$app")
            fetch_arr_history_by_download_id "$app" "$id" "$TMP_DIR/automation-retry-history.json" || continue
            target=$(jq -r '(.episodeId // .movieId // 0)' <<<"$item"); parent=$(jq -r '(.seriesId // .movieId // 0)' <<<"$item")
            [[ "$target" =~ ^[1-9][0-9]*$ && "$parent" =~ ^[1-9][0-9]*$ ]] || continue
            jq -e --arg id "$id" --arg kind "$kind" --argjson target "$target" --argjson parent "$parent" '
              .totalRecords==(.records|length) and any(.records[]; .eventType=="grabbed" and (.downloadId|ascii_downcase)==$id and
                (if $kind=="episode" then .episodeId==$target and .seriesId==$parent else .movieId==$target end)) and
              all(.records[]; .eventType!="downloadFolderImported" and .eventType!="downloadFailed" and .eventType!="downloadIgnored")' "$TMP_DIR/automation-retry-history.json" >/dev/null || continue
            local object="$TMP_DIR/automation-retry-object.json" owner="$TMP_DIR/automation-retry-owner.json" owner_kind=movie
            [ "$kind" != episode ] || owner_kind=series
            api_get "$root/$kind/$target" "$key" "$object" && api_get "$root/$owner_kind/$parent" "$key" "$owner" || continue
            jq -e --argjson id "$target" --argjson parent "$parent" --arg kind "$kind" '.id==$id and .monitored==true and
              (if $kind=="episode" then .seriesId==$parent else true end)' "$object" >/dev/null || continue
            jq -e --argjson id "$parent" --arg kind "$kind" --slurpfile object "$object" '.id==$id and .monitored==true and (.tags|length)==0 and
              (if $kind=="episode" then any(.seasons[]?; .seasonNumber==$object[0].seasonNumber and .monitored==true) else true end)' "$owner" >/dev/null || continue
            printf '%s' "$item" >"$TMP_DIR/automation-retry-item.json"
            jq -n --arg app "$app" --arg id "$id" --arg path "$path" --arg command "$command" --arg kind "$kind" \
              --argjson target "$target" --argjson parent "$parent" --slurpfile object "$object" --slurpfile owner "$owner" --slurpfile queue "$TMP_DIR/automation-retry-item.json" \
              '{key:($app+":retry:"+$id),app:$app,kind:"import-retry",downloadId:$id,mediaKind:$kind,targetId:$target,parentId:$parent,
                title:$queue[0].title,reason:[$queue[0].statusMessages[]?.messages[]?],
                identity:($object[0]|{id,seriesId,seasonNumber,episodeNumber,hasFile,episodeFileId,movieFileId,monitored}),
                parentExternalId:(if $kind=="episode" then ($owner[0].tvdbId // 0) else ($owner[0].tmdbId // 0) end),
                queueProof:($queue[0]|{id,downloadId,outputPath,status,trackedDownloadState,statusMessages,episodeId,movieId,seriesId}),
                command:{name:$command,path:$path,downloadClientId:$id,importMode:"Auto"}}' >"$candidate" || return 1
            hash=$(jq -Sc . "$candidate" | sha256sum | awk '{print $1}')
            automation_observe_candidate "$app:retry:$id" "$hash" || continue
            ((START_TIME-last>=4*3600)) || continue
            # Native Auto import still evaluates every file under Arr's own
            # policy; it never means forced/manual import or policy override.
            if ! automation_submit_command "$candidate" "$root" "$key"; then
                if jq -e 'any(.actions[]; .status=="intent")' "$AUTOMATION_STATE_FILE" >/dev/null; then return 0; fi
            fi
        done < <(jq -c '.records[]?|select(any(.statusMessages[]?.messages[]?;test("another process|sharing violation|resource|temporarily locked";"i")))' "$queue")
    done
}

# Lost POST responses are reconciled by a unique exact body/time match. Finding
# a native operation prevents replay; it does not prove import or attribution.
automation_find_existing_command() {
    local action="$1" root="$2" key="$3" output="$4" list="$TMP_DIR/automation-command-list.json"
    api_get "$root/command" "$key" "$list" || return 1
    jq -e --slurpfile action "$action" '
      def epoch: try (sub("\\.[0-9]+Z$";"Z")|fromdateiso8601) catch 0;
      $action[0] as $a |
      [ .[] | select((.id|type)=="number" and .id>0 and .name==$a.command.name and (.body|type)=="object") | . as $native |
        select((.queued // ""|epoch)>=$a.startedAt-5 and (.queued // ""|epoch)<=$a.startedAt+120) |
        select(all($a.command|to_entries[]; . as $field |
          if $field.key=="importMode" then ($native.body[$field.key]|ascii_downcase)==($field.value|ascii_downcase)
          else $native.body[$field.key]==$field.value end)) ] |
      select(length==1) | .[0]' "$list" >"$output"
}

automation_reconcile_commands() {
    local action id app root key command status file="$TMP_DIR/automation-recover-action.json"
    while IFS= read -r action; do
        runtime_budget_allows_optional_phase automation-command-readback || return 0
        id=$(jq -r '.key' <<<"$action"); printf '%s' "$action" | jq '.value' >"$file"
        automation_state_update '.actions[$id].commandCheckedAt=$now' --arg id "$id" --argjson now "$START_TIME" || return 1
        app=$(jq -r '.app' "$file"); command=$(jq -r '.commandId // 0' "$file")
        IFS=$'\t' read -r root key < <(arr_reconciliation_connection "$app")
        if ! [[ "$command" =~ ^[1-9][0-9]*$ ]];then
            if automation_find_existing_command "$file" "$root" "$key" "$TMP_DIR/automation-command-match.json";then
                command=$(jq -r '.id' "$TMP_DIR/automation-command-match.json")
                automation_state_update '.actions[$id].commandId=$command | .actions[$id].commandMatchedBy="unique exact request body and queued time; initiating client unproven"' \
                  --arg id "$id" --argjson command "$command" || return 1
            fi
        fi
        if automation_command_readback "$file" "$root" "$key" "$command"; then
            status=$(jq -r '.status' "$TMP_DIR/automation-command.json")
            case "$status" in failed|completed) ;; *) status=accepted;; esac
            local native_message
            native_message=$(jq -r '(if (.exception|type)=="object" then (.exception.message // .message // "") elif (.exception|type)=="string" and .exception!="" then .exception else (.message // "") end)|tostring|.[0:2000]' "$TMP_DIR/automation-command.json")
            automation_state_update '.actions[$id].status=$status | .actions[$id].nativeMessage=$message | .actions[$id].lastVerifiedStatus=$status' --arg message "$native_message" --arg id "$id" --arg status "$status" || return 1
        else
            automation_state_update '.actions[$id].lastVerifiedStatus=(.actions[$id].lastVerifiedStatus // .actions[$id].status) | .actions[$id].status="intent"' --arg id "$id" || return 1
        fi
    done < <(jq -c '[.actions|to_entries[]|select((.value.status=="intent" or .value.status=="accepted") and .value.outcome!="import_verified")]|sort_by(.value.commandCheckedAt // 0)|.[:4][]' "$AUTOMATION_STATE_FILE")
}

automation_report() {
    local issue action id app title detail status signature sent record file
    while IFS= read -r issue; do
        app=$(jq -r '.app' <<<"$issue"); detail=$(jq -r '.error' <<<"$issue")
        record_normalized_issue "Monitor:missing-survey:$app" Monitor "$app missing-media survey unavailable" ARR_AUTOMATION_SURVEY WARNING unavailable \
          'Complete native missing-media survey could not be obtained' 0 "$detail"
    done < <(jq -c '.missing|to_entries[]|select((.value.surveyError // "")!="")|{app:.key,error:.value.surveyError}' "$AUTOMATION_STATE_FILE")
    while IFS= read -r issue; do
        app=$(jq -r '.app' <<<"$issue"); id=$(jq -r '.id' <<<"$issue"); title=$(jq -r '.title' <<<"$issue"); detail=$(jq -r '.reason' <<<"$issue")
        record_normalized_issue "PROFILE:$app:$id" "$app" "$title" ARR_PROFILE_CONFIGURATION WARNING invalid "$detail" 0 \
          "$detail. Automated actions are held; no profile, score, monitoring or download data was changed. Correct the source Recyclarr configuration or native profile."
    done < <(jq -c '.profiles|to_entries[]|.key as $app|.value.issues[]?|.+{app:$app}' "$AUTOMATION_STATE_FILE")
    while IFS= read -r record; do
        id=$(jq -r '.key' <<<"$record"); app=$(jq -r '.value.app' <<<"$record"); title=$(jq -r '.value.title' <<<"$record"); detail=$(jq -r '.value.detail' <<<"$record")
        signature=$(printf '%s' "$detail" | sha256sum | awk '{print $1}')
        sent=$(jq -r --arg id "$id" '.monitor.automationNotifications[$id] // ""' "$STATE_FILE")
        [ "$sent" = "$signature" ] || queue_group_notification "AUTO:EVENT:$id" "$signature" "$app" "$title" ARR_AUTOMATION INFO 0 "$detail" reconciled
    done < <(jq -c --slurpfile state "$STATE_FILE" '.events|to_entries[]|select(($state[0].monitor.automationNotifications[.key] // "")!=.value.signature)' "$AUTOMATION_STATE_FILE")
    while IFS= read -r action; do
        id=$(jq -r '.key' <<<"$action"); printf '%s' "$action" | jq '.value' >"$TMP_DIR/automation-report-action.json"
        file="$TMP_DIR/automation-report-action.json"
        if jq -e '(.packId // "")!=""' "$file" >/dev/null;then continue;fi
        app=$(jq -r '.app' "$file"); title=$(jq -r '.title' "$file"); status=$(jq -r '.status' "$file")
        detail="Action: $(jq -r '.kind' "$file"); exact $app target $(jq -r '.targetId' "$file")."$'\n'
        detail+="Checkpoint: $status; native command ID: $(jq -r '.commandId // "unverified"' "$file")."$'\n'
        if [ "$(jq -r '.kind' "$file")" = import-retry ]; then
            detail+="Download ID: $(jq -r '.downloadId' "$file"); path: $(jq -r '.command.path' "$file")."$'\n'
            detail+="Original warning: $(jq -r '.reason|join("; ")' "$file")."$'\n'
            local retry_count
            retry_count=$(jq --arg app "$app" --arg download "$(jq -r .downloadId "$file")" '[.actions[]|select(.app==$app and .kind=="import-retry" and .downloadId==$download)]|length' "$AUTOMATION_STATE_FILE")
            detail+="Import retry usage: $retry_count/$AUTOMATION_IMPORT_RETRY_MAX_ATTEMPTS for this exact download; six-hour initial grace and four-hour spacing/action windows apply. Native Auto mode retains Arr import policy."$'\n'
        else
            detail+="Monitored missing target passed queue/history/deletion/hold checks. Pre-existing missing backlog entries were preserved."$'\n'
        fi
        if [ -n "$(jq -r '.nativeMessage // ""' "$file")" ]; then
            detail+="Arr result: $(jq -r '.nativeMessage' "$file")."$'\n'
        fi
        if [[ "$(jq -r '.commandMatchedBy // ""' "$file")" != "" ]];then
          detail+="Automatic reconciliation: $(jq -r '.commandMatchedBy' "$file"); existing command ID $(jq -r '.commandId' "$file") adopted; no request replayed."$'\n'
        fi
        detail+="Native request: $(jq -r '.command.name' "$file"), under the existing profile/monitoring policy. Payloads and library files were not deleted; no profile was lowered and no forced import was requested."$'\n'
        detail+="A completed search/scan command does not prove an import; the normal exact-download reconciliation continues independently."
        if [ "$(jq -r '.outcome' "$file")" = import_verified ]; then
            detail+=$'\n'"Eventual exact-target import verified on two scans; Arr file ID $(jq -r '.verifiedFileId' "$file"). No command was replayed to infer this result."
        fi
        # Once retries are exhausted, one current per-download assessment
        # replaces the stale individual failure cards. Import proof takes
        # precedence over an older command failure, without rewriting history.
        if [[ "$(jq -r '.kind' "$file")" == import-retry && "$(jq -r '.outcome // "pending"' "$file")" != import_verified && "$status" != intent ]] && jq -e --arg key "$app:$(jq -r '.downloadId|ascii_downcase' "$file")" '.retryExhaustions[$key].status=="review_required" or .retryExhaustions[$key].status=="handed_to_policy"' "$AUTOMATION_STATE_FILE" >/dev/null;then continue;fi
        [[ "$(jq -r '.outcome // "pending"' "$file")" != import_verified ]] || status=completed
        if [ "$status" = failed ]; then
            record_normalized_issue "AUTO:ACTION:$id" "$app" "$title" ARR_AUTOMATION_COMMAND_FAILED WARNING failed \
              'Arr reported that the bounded command failed' 0 "$detail No immediate retry was submitted; original queue warnings and attempt limits remain in force."
        elif [ "$status" = intent ]; then
            record_normalized_issue "AUTO:ACTION:$id" "$app" "$title" ARR_AUTOMATION_UNCERTAIN WARNING intent \
              'Command outcome is unverified; no automatic replay allowed' 0 "$detail Request may have succeeded before a timeout; new automated mutations are held pending verification."
        else
            signature="action:submitted:$(jq -r '.outcome // "pending"' "$file")"
            sent=$(jq -r --arg id "$id" '.monitor.automationNotifications[$id] // ""' "$STATE_FILE")
            [ "$sent" = "$signature" ] || queue_group_notification "AUTO:EVENT:$id" "$signature" "$app" "$title" ARR_AUTOMATION INFO 0 "$detail" reconciled
        fi
    done < <(jq -c --slurpfile state "$STATE_FILE" '.actions|to_entries[]|select(.value.status=="intent" or .value.status=="failed" or ($state[0].monitor.automationNotifications[.key] // "")!=("action:submitted:"+(.value.outcome // "pending")))' "$AUTOMATION_STATE_FILE")
}

# No mutation is authorized by retry exhaustion. Fresh queue evidence is
# classified again; existing policy handling alone may reject an exact release.
automation_retry_exhaustion() {
    if jq -e '(.retryExhaustions|type)=="object"' "$AUTOMATION_STATE_FILE" >/dev/null;then
      automation_state_update '. as $s|.retryExhaustions|=with_entries(.key as $key|if .value.status!="resolved" and any($s.actions[];.kind=="import-retry" and (.app+":"+(.downloadId|ascii_downcase))==$key and .outcome=="import_verified") then .value.status="resolved"|.value.reason="Exact-target import verified; retry escalation resolved"|.value.resolvedAt=$now else . end)' --argjson now "$START_TIME" || return 1
    fi
    local record app id queue rows item file="$TMP_DIR/retry-exhaustion.json" reason cause last key patch
    while IFS= read -r record;do
      runtime_budget_allows_optional_phase retry-exhaustion || break
      app=$(jq -r .app <<<"$record");id=$(jq -r .downloadId <<<"$record");key="$app:$id"
      # Pack lifecycle owns its one per-download assessment and per-file reasons.
      if [[ -f "$STATE_DIR/pack-actions.json" ]] && pack_document_valid "$STATE_DIR/pack-actions.json" && jq -e --arg id "$id" '.jobs[$id]!=null' "$STATE_DIR/pack-actions.json" >/dev/null;then continue;fi
      last=$(jq -r .lastStartedAt <<<"$record")
      ((START_TIME-last>=14400)) || continue
      case "$app" in Sonarr) queue="$SONARR_QUEUE";;Radarr) queue="$RADARR_QUEUE";;*) continue;;esac
      [[ -s "$queue" ]] || continue
      jq --arg id "$id" '[.records[]?|select((.downloadId // ""|ascii_downcase)==$id)]' "$queue" >"$file" || return 1
      rows=$(jq length "$file")
      cause=unverified_queue_outcome
      reason='Current queue does not prove an import or safe rejection; payload retained. No fourth retry or speculative search was submitted.'
      if [[ "$rows" == 1 ]];then
        item=$(jq -c '.[0]' "$file")
        case "$(policy_queue_reason "$item")" in
          redundant|replace) cause=policy_reassessment;reason='Fresh reasons now match a supported policy case. Existing exact-ID/profile/history/stability/window checks must authorize any rejection and replacement; exhausted retries supply no deletion authority.';;
          *)
            if jq -e 'any(.[0].statusMessages[]?.messages[]?;test("permission|access.*denied|read.only|disk|space|mount|authentication";"i"))' "$file" >/dev/null;then
              cause=underlying_service_or_storage;reason='Persistent access/storage/service fault requires correction. Payload retained; replacement downloads would not fix this condition.'
            elif jq -e 'all(.[0].statusMessages[]?.messages[]?;test("being used by another process|sharing violation|resource (temporarily unavailable|busy)|temporarily locked";"i")) and ([.[0].statusMessages[]?.messages[]?]|length)>0' "$file" >/dev/null;then
              cause=persistent_file_lock;reason='Transient lock/busy condition persisted through three native Auto import attempts. Further attempts stopped; review the process holding the path. Payload retained.'
            else cause=identity_or_unhandled_reason;reason='Fresh reasons do not authorize automatic rejection. Exact identity, mixed warnings or unsupported import conditions require review; payload retained.';fi;;
        esac
      elif ((rows>1));then cause=pack_or_duplicate_tracking;reason='Multiple current queue rows share this download. Pack/duplicate tracking remains protected; no fourth retry or automatic rejection was submitted.';fi
      local disposition=review_required policy="${POLICY_STATE_FILE:-$STATE_DIR/policy-actions.json}"
      if [[ "$cause" == policy_reassessment && -f "$policy" ]] && policy_validate_journal "$policy" && jq -e --arg id "$id" --arg app "$app" '.actions[$id].app==$app' "$policy" >/dev/null;then disposition=handed_to_policy;fi
      patch=$(jq -nc --arg disposition "$disposition" --arg cause "$cause" --arg reason "$reason" --arg app "$app" --arg id "$id" --argjson at "$START_TIME" '{app:$app,downloadId:$id,status:$disposition,cause:$cause,reason:$reason,checkedAt:$at}')
      automation_state_update '.retryExhaustions //= {}|.retryExhaustions[$key]=$patch|.retryExhaustions|=with_entries(select(.value.checkedAt>=$cutoff))' --arg key "$key" --argjson patch "$patch" --argjson cutoff "$((START_TIME-90*86400))" || return 1
      [[ "$disposition" != handed_to_policy ]] || continue
      record_normalized_issue "AUTO:RETRY_EXHAUSTED:$key" "$app" 'Import retry limit reached' ARR_IMPORT_RETRY_EXHAUSTED WARNING "$cause" "$reason" 0 \
        "Download ID: $id. Attempts: $AUTOMATION_IMPORT_RETRY_MAX_ATTEMPTS/$AUTOMATION_IMPORT_RETRY_MAX_ATTEMPTS; at least four hours since the final attempt. $reason Original native reasons: $(jq -r '[.[]|.statusMessages[]?.messages[]?]|unique|join("; ")' "$file")"
    done < <(jq -c --argjson max "$AUTOMATION_IMPORT_RETRY_MAX_ATTEMPTS" '[.actions[]|select(.kind=="import-retry")]|group_by([.app,(.downloadId|ascii_downcase)])|.[]|select(length>=$max and all(.[];.outcome!="import_verified" and .status!="intent"))|sort_by(.startedAt)|select(.[-1].status=="completed" or .[-1].status=="failed")|{app:.[0].app,downloadId:(.[0].downloadId|ascii_downcase),lastStartedAt:.[-1].startedAt}' "$AUTOMATION_STATE_FILE")
}

automation_preserve_retry_exhaustion() {
    [[ -f "$STATE_FILE" ]] || return 0
    local key
    while IFS= read -r key;do mark_seen "$key";done < <(jq -r '.issues|to_entries[]|select(.key|startswith("AUTO:RETRY_EXHAUSTED:"))|select(.value.active==true)|.key' "$STATE_FILE")
}
# BEGIN EMBEDDED MEDIA PACK ENGINE
# shellcheck shell=bash
# Native Sonarr pack workflow. No forced imports, library deletes or title identities.
pack_publish() {
    local candidate="$1" target="$PACK_STATE_FILE"
    pack_document_valid "$candidate" || return 1
    (( $(stat -c %s "$candidate")<=33554432 )) || return 1
    if [[ -f "$target" ]] && cmp -s "$candidate" "$target";then rm -f "$candidate";return 0;fi
    [[ ! -f "$target" ]] || { cp "$target" "$target.bak.tmp" && sync -f "$target.bak.tmp" && mv "$target.bak.tmp" "$target.bak"; } || return 1
    sync -f "$candidate" && mv "$candidate" "$target" && sync -f "$STATE_DIR"
}
pack_update() {
    local filter="$1";shift
    jq "$@" "$filter" "$PACK_STATE_FILE" >"$TMP_DIR/pack-state.next" && pack_publish "$TMP_DIR/pack-state.next"
}
pack_snapshot() {
    local id="$1" output="$2" root="$SONARR_API_ROOT" key="$SONARR_API_KEY" queue="$TMP_DIR/pack-queue.json" sab="$TMP_DIR/pack-sab.json" history="$TMP_DIR/pack-history.json"
    local series="$TMP_DIR/pack-series.json" profiles="$TMP_DIR/pack-profiles.json" formats="$TMP_DIR/pack-formats.json" profile="$TMP_DIR/pack-profile.json" preview="$TMP_DIR/pack-preview.json" source="$TMP_DIR/pack-source.json"
    local folder parent signature rows="$TMP_DIR/pack-targets.jsonl" target ep="$TMP_DIR/pack-episode.json" file="$TMP_DIR/pack-file.json" prior="$TMP_DIR/pack-target-history.json" pid
    [[ "$id" =~ ^[a-z0-9-]+$ ]] || return 1
    jq --arg id "$id" '[.history.slots[]?|select((.nzo_id|ascii_downcase)==$id and .status=="Completed")]|select(length==1)|.[0]' "$SAB_HISTORY" >"$sab" || return 1
    jq -e --argjson now "$START_TIME" 'type=="object" and (.completed|tonumber)>0 and $now-(.completed|tonumber)>=21600' "$sab" >/dev/null || return 1
    jq -e --arg id "$id" 'all(.queue.slots[]?;(.nzo_id|ascii_downcase)!=$id)' "$SAB_QUEUE" >/dev/null || return 1
    folder=$(jq -r .storage "$sab")
    [[ "$folder" == "$AUTOMATION_SONARR_COMPLETE_ROOT/"* && "$folder" != *'/../'* && "$folder" != */.. ]] || return 1
    fetch_arr_queue Sonarr "$root" "$key" "$queue" || return 1
    jq -e --arg id "$id" --arg folder "$folder" --argjson now "$START_TIME" 'all(.records[]|select((.downloadId // ""|ascii_downcase)==$id);.protocol=="usenet" and .status=="completed" and .outputPath==$folder and ((try (.added|sub("\\.[0-9]+Z$";"Z")|fromdateiso8601) catch $now)<=$now-21600))' "$queue" >/dev/null || return 1
    jq -e --arg id "$id" 'all(.records[]?;(.downloadId // ""|ascii_downcase)!=$id)' "$RADARR_QUEUE" >/dev/null || return 1
    fetch_arr_history_by_download_id Sonarr "$id" "$history" || return 1
    jq -e --arg id "$id" '.totalRecords==(.records|length) and all(.records[];(.downloadId // ""|ascii_downcase)==$id) and any(.records[];.eventType=="grabbed") and ([.records[]|select(.eventType=="grabbed")|{sourceTitle,quality}]|unique|length)==1' "$history" >/dev/null || return 1
    parent=$(jq -r '[.records[]|select(.eventType=="grabbed")|.seriesId]|unique|select(length==1)|.[0]' "$history")
    [[ "$parent" =~ ^[1-9][0-9]*$ ]] || return 1
    pack_repair_held "$parent" && return 1
    api_get "$root/series/$parent" "$key" "$series" && api_get "$root/qualityprofile" "$key" "$profiles" && api_get "$root/customformat" "$key" "$formats" || return 1
    jq -e --argjson id "$parent" '.id==$id and .monitored==true and .tvdbId>0 and (.tags|length)==0' "$series" >/dev/null || return 1
    pid=$(jq -r .qualityProfileId "$series");jq --argjson id "$pid" '.[]|select(.id==$id)' "$profiles" >"$profile"
    jq -e 'type=="object" and (.minFormatScore|type)=="number"' "$profile" >/dev/null || return 1
    signature=$(pack_profile_signature "$profiles" "$formats") || return 1
    jq -e --arg signature "$signature" --argjson now "$START_TIME" '.profiles.Sonarr.signature==$signature and .profiles.Sonarr.holdUntil<=$now and $now-.profiles.Sonarr.checkedAt<=5400' "$AUTOMATION_STATE_FILE" >/dev/null || return 1
    pack_source_inventory "$folder" "$AUTOMATION_SONARR_COMPLETE_ROOT" "$source" || return 1
    local query
    query=$(jq -nr --arg folder "$folder" --arg id "$id" '"folder="+($folder|@uri)+"&downloadId="+($id|@uri)+"&filterExistingFiles=false"')
    api_get "$root/manualimport?$query" "$key" "$preview" || return 1
    jq -e --arg id "$id" --arg folder "$folder" --argjson parent "$parent" --slurpfile source "$source" '
      type=="array" and length>0 and length<=200 and
      all(.[];. as $v|.series.id==$parent and (.downloadId|ascii_downcase)==$id and .size>0 and (.episodes|length)>0 and .path==($folder+"/"+.relativePath) and any($source[0].files[];.relative==$v.relativePath and .size==$v.size)) and
      ([.[].relativePath]|sort)==([$source[0].files[]|select(.video)|.relative]|sort)' "$preview" >/dev/null || return 1
    : >"$rows"
    local targets="$TMP_DIR/pack-target-ids"
    jq -r '[.records[]|select(.eventType=="grabbed")|.episodeId]|unique|select(length>0 and length<=40)|.[]' "$history" >"$targets" || return 1
    [[ -s "$targets" ]] || return 1
    while IFS= read -r target;do
      runtime_budget_allows_optional_phase pack-proof || return 75
      [[ "$target" =~ ^[1-9][0-9]*$ ]] || return 1
      api_get "$root/episode/$target" "$key" "$ep" || return 1
      jq -e --argjson id "$target" --argjson parent "$parent" --slurpfile series "$series" '. as $e|.id==$id and .seriesId==$parent and .monitored==true and .episodeNumber>0 and any($series[0].seasons[]?;.seasonNumber==$e.seasonNumber and .monitored==true)' "$ep" >/dev/null || return 1
      printf '{}' >"$file"
      if jq -e '.hasFile==true and .episodeFileId>0' "$ep" >/dev/null;then
        api_get "$root/episodefile/$(jq -r .episodeFileId "$ep")" "$key" "$file" || return 1
        jq -e --argjson parent "$parent" --slurpfile ep "$ep" '.id==$ep[0].episodeFileId and .seriesId==$parent and .size>0 and (.path|type)=="string"' "$file" >/dev/null || return 1
      elif jq -e '.hasFile==false and (.episodeFileId // 0)==0' "$ep" >/dev/null;then
        automation_target_history episode "$target" "$root" "$key" "$prior" || return 1
        jq -e 'all(.records[];.eventType!="episodeFileDeleted" and .eventType!="downloadFolderImported")' "$prior" >/dev/null || return 1
        if [[ -f "$STATE_DIR/import-receipts.json" ]];then
          automation_document_valid "$STATE_DIR/import-receipts.json" receipts || return 1
          jq -e --argjson id "$target" 'all(.receipts[]|select(.app=="Sonarr");all(.targets[];.targetId!=$id))' "$STATE_DIR/import-receipts.json" >/dev/null || return 1
        fi
        jq -e --argjson id "$target" 'all(.downloadLedger[]?|select(.app=="Sonarr" and ((.arrImportedAt // 0)>0 or (.manuallyDismissedAt // 0)>0));all(.targets[]?;(.episodeId // 0)!=$id))' "$STATE_FILE" >/dev/null || return 1
      else return 1;fi
      jq -nc --slurpfile e "$ep" --slurpfile f "$file" --slurpfile p "$profile" --slurpfile h "$history" '
        $e[0] as $e|$f[0] as $f|{key:($e.id|tostring),value:{id:$e.id,seriesId:$e.seriesId,seasonNumber:$e.seasonNumber,episodeNumber:$e.episodeNumber,monitored:$e.monitored,hasFile:$e.hasFile,fileId:($e.episodeFileId // 0),filePath:($f.path // ""),fileDateAdded:($f.dateAdded // ""),
          goodExisting:($e.hasFile==true and ($f.customFormatScore|type)=="number" and ($f.quality.quality.id|type)=="number" and $f.quality.quality.id>0 and $f.customFormatScore>=$p[0].minFormatScore and ([$p[0].items[]|select(.allowed==true)|.quality.id,.items[]?.quality.id]|index($f.quality.quality.id))!=null),
          importedByJob:any($h[0].records[];.eventType=="downloadFolderImported" and .episodeId==$e.id and ((.data.fileId // "0"|tonumber?)==$e.episodeFileId))}}' >>"$rows" || return 1
    done <"$targets"
    jq -n --arg id "$id" --arg signature "$signature" --arg folder "$folder" --argjson parent "$parent" --slurpfile s "$series" --slurpfile p "$profile" --slurpfile q "$queue" --slurpfile sab "$sab" --slurpfile h "$history" --slurpfile source "$source" --slurpfile preview "$preview" --slurpfile targets "$rows" '
      ($targets|from_entries) as $targets |
      {app:"Sonarr",downloadId:$id,seriesId:$parent,tvdbId:$s[0].tvdbId,title:$sab[0].name,folder:$folder,profileSignature:$signature,profile:$p[0],source:$source[0],targets:$targets,
       sab:($sab[0]|{nzo_id,name,storage,completed,category}),queueIds:[$q[0].records[]|select((.downloadId // ""|ascii_downcase)==$id)|.id]|sort,
       release:([$h[0].records[]|select(.eventType=="grabbed")|{sourceTitle,quality}]|first),files:[$preview[0][]|. as $v|
        ($v.rejections // []|map(.reason)) as $reasons|([$source[0].files[]|select(.relative==$v.relativePath)]|first) as $f|
        {relative:$v.relativePath,size:$f.size,identity:$f.identity,episodeIds:[$v.episodes[].id]|sort,
         disposition:(if ($v.quality.quality.id|type)!="number" or $v.quality.quality.id<=0 or (([$p[0].items[]|select(.allowed==true)|.quality.id,.items[]?.quality.id]|index($v.quality.quality.id))==null) then "unknown"
          elif all($v.episodes[];$targets[.id|tostring]!=null and .seriesId==$parent and .seasonNumber==$targets[.id|tostring].seasonNumber and .episodeNumber==$targets[.id|tostring].episodeNumber)|not then "unknown"
          elif ($reasons|length)>0 and all($reasons[];test("^Not (a |an )?(Custom Format|quality revision|upgrade for existing)";"i") and (test("BeforeRename|AfterRename";"i")|not)) and all($v.episodes[];$targets[.id|tostring].goodExisting) then "redundant"
          elif ($reasons|length)>0 and all($reasons[];test("^Custom Formats? .*(have score|score of|score) -?[0-9]+ .*below .*profile minimum -?[0-9]+$";"i")) and ($v.customFormatScore|type)=="number" and $v.customFormatScore<$p[0].minFormatScore and all($v.episodes[];$targets[.id|tostring].hasFile==false) then "rejected"
          elif ($reasons|length)==0 or all($reasons[];test("being used by another process|sharing violation|resource (temporarily unavailable|busy)|temporarily locked";"i")) then "required" else "unknown" end),reasons:$reasons}]} |
      .accounted=(all(.files[];.disposition=="redundant" or .disposition=="rejected") and
        (. as $plan|all(.targets[];. as $t|any($plan.files[];.episodeIds|index($t.id)) or ($t.goodExisting and $t.importedByJob)))) |
      .unknown=((. as $plan|any(.targets[];. as $t|((any($plan.files[];.episodeIds|index($t.id)))|not) and (($t.goodExisting and $t.importedByJob)|not))) or any(.files[];.disposition=="unknown") or ([.files[].episodeIds[]]|length)!=([.files[].episodeIds[]]|unique|length))' >"$output" || return 1
    pack_plan_valid "$output" || return 1
    jq -e --arg id "$id" --slurpfile plan "$output" 'all(.records[]|select((.downloadId // ""|ascii_downcase)==$id);.seriesId==$plan[0].seriesId and ((.episodeId // 0)==0 or $plan[0].targets[(.episodeId|tostring)]!=null))' "$queue" >/dev/null || return 1
}
pack_missing_guard() {
    local id="$1" target="$2" root="$SONARR_API_ROOT" key="$SONARR_API_KEY" job="$TMP_DIR/pack-search-job.json" object="$TMP_DIR/pack-search-episode.json" owner="$TMP_DIR/pack-search-series.json" history="$TMP_DIR/pack-search-history.json" queue="$TMP_DIR/pack-search-queue.json" profile="$TMP_DIR/pack-search-profiles.json" formats="$TMP_DIR/pack-search-formats.json" parent
    jq --arg id "$id" '.jobs[$id]' "$PACK_STATE_FILE" >"$job" || return 1
    jq -e --arg target "$target" '.status=="queue_verified" and .disposalPlan.targets[$target]!=null and any(.disposalPlan.files[];.disposition=="rejected" and (.episodeIds|index($target|tonumber))!=null)' "$job" >/dev/null || return 1
    parent=$(jq -r .disposalPlan.seriesId "$job")
    pack_repair_held "$parent" && return 1
    api_get "$root/episode/$target" "$key" "$object" && api_get "$root/series/$parent" "$key" "$owner" || return 1
    jq -e --arg target "$target" --slurpfile j "$job" '.id==($target|tonumber) and .seriesId==$j[0].disposalPlan.seriesId and .seasonNumber==$j[0].disposalPlan.targets[$target].seasonNumber and .episodeNumber==$j[0].disposalPlan.targets[$target].episodeNumber and .monitored==true and .hasFile==false and (.episodeFileId // 0)==0' "$object" >/dev/null || return 1
    jq -e --slurpfile j "$job" --slurpfile e "$object" '.id==$j[0].disposalPlan.seriesId and .tvdbId==$j[0].disposalPlan.tvdbId and .qualityProfileId==$j[0].disposalPlan.profile.id and .monitored==true and (.tags|length)==0 and any(.seasons[]?;.seasonNumber==$e[0].seasonNumber and .monitored==true)' "$owner" >/dev/null || return 1
    fetch_arr_queue Sonarr "$root" "$key" "$queue" || return 1
    jq -e --argjson parent "$parent" 'all(.records[];.seriesId!=$parent)' "$queue" >/dev/null || return 1
    fetch_sab_queue "$TMP_DIR/pack-search-sab.json" || return 1
    jq -e --arg category "${SAB_TV_CATEGORY,,}" --slurpfile q "$queue" '[$q[0].records[].downloadId|ascii_downcase] as $known|all(.queue.slots[]?|select((.cat // .category // ""|ascii_downcase)==$category);(.nzo_id|ascii_downcase) as $id|($known|index($id))!=null)' "$TMP_DIR/pack-search-sab.json" >/dev/null || return 1
    automation_target_history episode "$target" "$root" "$key" "$history" || return 1
    jq -e --arg id "$id" --argjson since "$((START_TIME-7*86400))" 'all(.records[];.eventType!="episodeFileDeleted" and .eventType!="downloadFolderImported" and (.eventType!="grabbed" or (.downloadId|ascii_downcase)==$id or ((try (.date|sub("\\.[0-9]+Z$";"Z")|fromdateiso8601) catch 9999999999)<$since)))' "$history" >/dev/null || return 1
    if [[ -f "$STATE_DIR/import-receipts.json" ]];then
      automation_document_valid "$STATE_DIR/import-receipts.json" receipts || return 1
      jq -e --argjson target "$target" 'all(.receipts[]|select(.app=="Sonarr");all(.targets[];.targetId!=$target))' "$STATE_DIR/import-receipts.json" >/dev/null || return 1
    fi
    jq -e --argjson target "$target" 'all(.downloadLedger[]?|select(.app=="Sonarr" and ((.arrImportedAt // 0)>0 or (.manuallyDismissedAt // 0)>0));all(.targets[]?;(.episodeId // 0)!=$target))' "$STATE_FILE" >/dev/null || return 1
    api_get "$root/qualityprofile" "$key" "$profile" && api_get "$root/customformat" "$key" "$formats" || return 1
    [[ $(pack_profile_signature "$profile" "$formats") == $(jq -r .disposalPlan.profileSignature "$job") ]]
}
pack_command_guard() {
    local candidate="$1" id kind fresh="$TMP_DIR/pack-final-plan.json" expected
    id=$(jq -r .packId "$candidate");kind=$(jq -r .kind "$candidate")
    if [[ "$kind" == missing-search ]];then pack_missing_guard "$id" "$(jq -r .targetId "$candidate")";return $?;fi
    jq -e --arg id "$id" --argjson now "$START_TIME" '.jobs[$id].observation|.runs>=2 and .at<=$now and $now-.at<=1200' "$PACK_STATE_FILE" >/dev/null || return 1
    pack_snapshot "$id" "$fresh" || return 1
    expected=$(jq -r --arg id "$id" '.jobs[$id].observation.fingerprint' "$PACK_STATE_FILE")
    [[ $(jq -Sc . "$fresh"|sha256sum|cut -d ' ' -f1) == "$expected" ]] || return 1
    jq -e '.unknown==false and any(.files[];.disposition=="required")' "$fresh" >/dev/null
}
pack_verify_queue_removal() {
    local id="$1" queue="$TMP_DIR/pack-verify-queue.json" history="$TMP_DIR/pack-verify-history.json" blocklist="$TMP_DIR/pack-blocklist.json" job="$TMP_DIR/pack-verify-job.json"
    jq --arg id "$id" '.jobs[$id]' "$PACK_STATE_FILE" >"$job" || return 1
    fetch_arr_queue Sonarr "$SONARR_API_ROOT" "$SONARR_API_KEY" "$queue" && fetch_arr_history_by_download_id Sonarr "$id" "$history" || return 1
    jq -e --arg id "$id" 'all(.records[];(.downloadId // ""|ascii_downcase)!=$id)' "$queue" >/dev/null || return 1
    jq -e --slurpfile j "$job" --arg id "$id" '$j[0].disposalPlan as $p|. as $h|.totalRecords==(.records|length) and all($p.targets[];. as $t|any($h.records[];(.downloadId|ascii_downcase)==$id and .seriesId==$p.seriesId and .episodeId==$t.id and (.eventType==(if $j[0].blocklist then "downloadFailed" else "downloadIgnored" end) or ($t.importedByJob and .eventType=="downloadFolderImported"))))' "$history" >/dev/null || return 1
    if jq -e '.blocklist==true' "$job" >/dev/null;then
      api_get "$SONARR_API_ROOT/blocklist?page=1&pageSize=100&sortKey=date&sortDirection=descending" "$SONARR_API_KEY" "$blocklist" || return 1
      jq -e --slurpfile j "$job" 'any(.records[]; .seriesId==$j[0].disposalPlan.seriesId and .sourceTitle==$j[0].disposalPlan.release.sourceTitle and .quality==$j[0].disposalPlan.release.quality and (.episodeIds|sort)==([$j[0].disposalPlan.targets[].id]|sort) and ((try (.date|sub("\\.[0-9]+Z$";"Z")|fromdateiso8601) catch 0)>=$j[0].queueIntentAt-5))' "$blocklist" >/dev/null || return 1
    fi
    cp "$queue" "$SONARR_QUEUE" || return 1
    pack_update '.jobs[$id].status="queue_verified"|.jobs[$id].queueVerifiedAt=$at|.jobs[$id].reason="Exact queue removal and native disposition verified; payload retained pending guarded file cleanup"' --arg id "$id" --argjson at "$START_TIME"
}
pack_dispatch() {
    local id="$1" plan="$2" fresh="$TMP_DIR/pack-dispatch-fresh.json" fingerprint first queue_id blocklist rc=0
    automation_window_open && automation_action_budget && monitor_mutation_gate Sonarr && automation_no_active_command "$SONARR_API_ROOT" "$SONARR_API_KEY" || return 0
    jq -e 'all(.actions[];.status!="intent")' "$AUTOMATION_STATE_FILE" >/dev/null || return 0
    jq -e '.accounted==true and .unknown==false and (.queueIds|length)>0' "$plan" >/dev/null || return 0
    jq -e --arg id "$id" --argjson now "$START_TIME" '.jobs[$id].observation|.runs>=2 and .at<=$now and $now-.at<=1200' "$PACK_STATE_FILE" >/dev/null || return 0
    pack_snapshot "$id" "$fresh" || return 0
    fingerprint=$(jq -Sc . "$fresh"|sha256sum|cut -d ' ' -f1)
    [[ "$fingerprint" == $(jq -r --arg id "$id" '.jobs[$id].observation.fingerprint' "$PACK_STATE_FILE") ]] || return 0
    first=$(jq -r '[.targets[].id]|min' "$fresh");queue_id=$(jq -r '.queueIds[0]' "$fresh");blocklist=$(jq 'any(.files[];.disposition=="rejected")' "$fresh")
    usr_ops_arr_reserve "pack-queue:$id" Sonarr "$first" || return 0
    pack_update '.jobs[$id].status="queue_intent"|.jobs[$id].queueIntentAt=$at|.jobs[$id].disposalPlan=$plan[0]|.jobs[$id].planFingerprint=$fingerprint|.jobs[$id].blocklist=$blocklist|.jobs[$id].reason="Native queue disposition dispatched; read-back required before disposal"' --arg id "$id" --argjson at "$START_TIME" --slurpfile plan "$fresh" --arg fingerprint "$fingerprint" --argjson blocklist "$blocklist" || return 1
    policy_mutate DELETE "$SONARR_API_ROOT/queue/$queue_id?removeFromClient=false&blocklist=$blocklist&skipRedownload=true&changeCategory=false" "$SONARR_API_KEY" '' "$TMP_DIR/pack-delete-response.json" || rc=$?
    if ((rc==75));then
      usr_ops_arr_release_undispatched "pack-queue:$id" || true
      pack_update '.jobs[$id].status="observing"|del(.jobs[$id].queueIntentAt,.jobs[$id].disposalPlan,.jobs[$id].planFingerprint)|.jobs[$id].reason="Local gate refused before dispatch; queue unchanged"' --arg id "$id";return $?
    fi
    pack_verify_queue_removal "$id" || pack_update '.jobs[$id].reason="Queue disposition outcome unverified; no DELETE replay, search or disposal allowed"' --arg id "$id"
}
pack_submit_import() {
    local id="$1" plan="$2" candidate="$TMP_DIR/pack-import-command.json" count last
    jq -e '.unknown==false and any(.files[];.disposition=="required")' "$plan" >/dev/null || return 0
    count=$(jq --arg id "$id" '[.actions[]|select(.kind=="import-retry" and (.downloadId|ascii_downcase)==$id)]|length' "$AUTOMATION_STATE_FILE")
    last=$(jq --arg id "$id" '[.actions[]|select(.kind=="import-retry" and (.downloadId|ascii_downcase)==$id)|.startedAt]|max // 0' "$AUTOMATION_STATE_FILE")
    if ((count>=AUTOMATION_IMPORT_RETRY_MAX_ATTEMPTS));then
      pack_update '.jobs[$id].status="blocked"|.jobs[$id].reason="Native Auto import retry limit reached; required files retained. Exact mapping is reassessed on later action windows; no fourth retry or speculative rejection"' --arg id "$id"
      return $?
    fi
    ((START_TIME-last>=14400)) || return 0
    jq --arg id "$id" '. as $p|([.files[]|select(.disposition=="required")|.episodeIds[]]|unique|.[0]|tostring) as $t|
      {key:("Sonarr:pack-import:"+$id),app:"Sonarr",kind:"import-retry",packId:$id,downloadId:$id,mediaKind:"episode",targetId:.targets[$t].id,parentId:.seriesId,title:.title,reason:["Fully mapped pack has files eligible for native Auto import"],identity:.targets[$t],parentExternalId:.tvdbId,command:{name:"DownloadedEpisodesScan",path:.folder,downloadClientId:$id,importMode:"Auto"}}' "$plan" >"$candidate" || return 1
    automation_submit_command "$candidate" "$SONARR_API_ROOT" "$SONARR_API_KEY"
}
pack_submit_searches() {
    local id="$1" row target candidate="$TMP_DIR/pack-search-candidate.json" job="$TMP_DIR/pack-search-plan.json" recent
    automation_window_open && automation_action_budget || return 0
    jq --arg id "$id" '.jobs[$id]' "$PACK_STATE_FILE" >"$job" || return 1
    while IFS= read -r target;do
      runtime_budget_allows_optional_phase pack-search || break
      automation_action_budget || break
      # One search per target, with the existing weekly bound across producers.
      recent=$(jq --argjson target "$target" --argjson cutoff "$((START_TIME-7*86400))" '[.actions[]|select(.app=="Sonarr" and .targetId==$target and .kind=="missing-search" and .startedAt>=$cutoff)]|length' "$AUTOMATION_STATE_FILE")
      ((recent==0)) || continue
      if [[ -f "$STATE_DIR/policy-actions.json" ]] && ! jq -e --argjson target "$target" --argjson cutoff "$((START_TIME-7*86400))" 'all(.actions[];.app!="Sonarr" or .targetId!=$target or .mode!="replace" or .startedAt<$cutoff)' "$STATE_DIR/policy-actions.json" >/dev/null;then continue;fi
      pack_missing_guard "$id" "$target" || continue
      jq --arg id "$id" --arg target "$target" '.disposalPlan as $p|{key:("Sonarr:pack-search:"+$id+":"+$target),app:"Sonarr",kind:"missing-search",packId:$id,mediaKind:"episode",targetId:($target|tonumber),parentId:$p.seriesId,title:$p.title,identity:($p.targets[$target]+{episodeFileId:$p.targets[$target].fileId}),parentExternalId:$p.tvdbId,command:{name:"EpisodeSearch",episodeIds:[($target|tonumber)]}}' "$job" >"$candidate" || return 1
      automation_submit_command "$candidate" "$SONARR_API_ROOT" "$SONARR_API_KEY" || return 1
    done < <(jq -r '[.disposalPlan.files[]|select(.disposition=="rejected")|.episodeIds[]]|unique|.[]' "$job")
}
pack_followup() {
    local id="$1" record target ep="$TMP_DIR/pack-followup-episode.json" file="$TMP_DIR/pack-followup-file.json" job="$TMP_DIR/pack-followup-job.json" fingerprint prior runs seen epoch parent
    jq --arg id "$id" '.jobs[$id]' "$PACK_STATE_FILE" >"$job" || return 1
    parent=$(jq -r .disposalPlan.seriesId "$job")
    local owner="$TMP_DIR/pack-followup-owner.json" profiles="$TMP_DIR/pack-followup-profiles.json" formats="$TMP_DIR/pack-followup-formats.json"
    api_get "$SONARR_API_ROOT/series/$parent" "$SONARR_API_KEY" "$owner" && api_get "$SONARR_API_ROOT/qualityprofile" "$SONARR_API_KEY" "$profiles" && api_get "$SONARR_API_ROOT/customformat" "$SONARR_API_KEY" "$formats" || return 0
    jq -e --slurpfile j "$job" '.id==$j[0].disposalPlan.seriesId and .tvdbId==$j[0].disposalPlan.tvdbId and .qualityProfileId==$j[0].disposalPlan.profile.id and .monitored==true and (.tags|length)==0' "$owner" >/dev/null || return 0
    [[ $(pack_profile_signature "$profiles" "$formats") == $(jq -r .disposalPlan.profileSignature "$job") ]] || return 0
    while IFS= read -r target;do
      runtime_budget_allows_optional_phase pack-followup || return 0
      prior=$(jq -r --arg t "$target" '.proofs[$t].fingerprint // ""' "$job");seen=$(jq -r --arg t "$target" '.proofs[$t].at // 0' "$job")
      ((START_TIME-seen>=240)) || continue
      api_get "$SONARR_API_ROOT/episode/$target" "$SONARR_API_KEY" "$ep" || continue
      jq -e --arg t "$target" --slurpfile j "$job" --slurpfile owner "$owner" '. as $e|any($owner[0].seasons[]?;.seasonNumber==$e.seasonNumber and .monitored==true) and .id==($t|tonumber) and .seriesId==$j[0].disposalPlan.seriesId and .seasonNumber==$j[0].disposalPlan.targets[$t].seasonNumber and .episodeNumber==$j[0].disposalPlan.targets[$t].episodeNumber and .monitored==true and .hasFile==true and .episodeFileId>0' "$ep" >/dev/null || { pack_update '.jobs[$id].proofs[$t]={runs:0,verified:false,at:$at}' --arg id "$id" --arg t "$target" --argjson at "$START_TIME";continue; }
      api_get "$SONARR_API_ROOT/episodefile/$(jq -r .episodeFileId "$ep")" "$SONARR_API_KEY" "$file" || continue
      epoch=$(date_to_epoch "$(jq -r '.dateAdded // ""' "$file")")
      ((epoch>=$(jq -r .queueIntentAt "$job"))) || continue
      jq -e --argjson parent "$parent" --slurpfile e "$ep" --slurpfile j "$job" '.id==$e[0].episodeFileId and .seriesId==$parent and .size>0 and (.path|length)>0 and (.customFormatScore|type)=="number" and (.quality.quality.id|type)=="number" and .quality.quality.id>0 and .customFormatScore>=$j[0].disposalPlan.profile.minFormatScore and (.quality.quality.id as $quality|[$j[0].disposalPlan.profile.items[]|select(.allowed==true)|.quality.id,.items[]?.quality.id]|index($quality))!=null' "$file" >/dev/null || continue
      fingerprint=$(jq -Sc '{id,seriesId,path,size,dateAdded,quality,customFormatScore}' "$file"|sha256sum|cut -d ' ' -f1)
      runs=$(jq -r --arg t "$target" '.proofs[$t].runs // 0' "$job");if [[ "$prior" == "$fingerprint" ]];then runs=$((runs+1));else runs=1;fi
      pack_update '.jobs[$id].proofs[$t]={fingerprint:$fp,runs:$runs,at:$at,fileId:$file,verified:($runs>=2)}' --arg id "$id" --arg t "$target" --arg fp "$fingerprint" --argjson runs "$runs" --argjson at "$START_TIME" --argjson file "$(jq .id "$file")" || return 1
    done < <(jq -r '[.disposalPlan.files[]|select(.disposition=="rejected")|.episodeIds[]]|unique|.[]' "$job")
}
pack_reconcile_receipts() {
    local file="${MEDIA_PACK_CLEANUP_RECEIPT:-/mnt/vault/cloud/logs/script/media_cleanup/sab/pack-cleanup.json}" empty="$TMP_DIR/pack-empty-receipts.json"
    printf '{"schema":1,"jobs":{}}' >"$empty"
    if [[ -e "$file" ]];then [[ ! -L "$file" ]] && jq -e '.schema==1 and (.jobs|type)=="object"' "$file" >/dev/null || return 1;else file="$empty";fi
    pack_update ' .jobs|=with_entries(.value as $j|if $receipt[0].jobs[.key] as $c|$c!=null and $c.createdAt==$j.createdAt and $c.planFingerprint==$j.planFingerprint then .value.cleanup=$receipt[0].jobs[.key] else . end |
      if any((.value.cleanup.files // {})[];.status=="manual_restore") then .value.status="manual_hold"|.value.reason="Operator restore intent recorded; automatic re-quarantine and further pack commands held"
      elif .value.status=="queue_verified" then .value as $v|([.value.disposalPlan.files[]|select(.disposition=="rejected")|.episodeIds[]]|unique) as $needed|
        if all($v.disposalPlan.files[];. as $f|$v.cleanup.files[$f.relative].status=="quarantined" and $v.cleanup.files[$f.relative].identity==$f.identity) and all($needed[];$v.proofs[tostring].verified==true and $v.proofs[tostring].at==$now) then .value.status="resolved"|.value.reason="Every source video has committed quarantine proof and all required replacements were verified on two scans" else . end else . end)' --slurpfile receipt "$file" --argjson now "$START_TIME"
}
pack_report() {
    local id job signature sent detail status event=progress commands="$TMP_DIR/pack-report-commands.json"
    while IFS= read -r job;do
      id=$(jq -r .key <<<"$job");jq --arg id "$id" '[.actions[]?|select(.packId==$id)]|group_by([.kind,.targetId])|map(sort_by(.startedAt)|last|{kind,targetId,status,commandId,nativeMessage})' "$AUTOMATION_STATE_FILE" >"$commands" || return 1;status=$(jq -r .value.status <<<"$job")
      signature=$(jq -Sc --slurpfile commands "$commands" '.value|{status,reason,proofs:((.proofs // {})|with_entries(.value|={fileId,verified})),cleanup:((.cleanup.files // {})|with_entries(.value|={status,reason,identity})),commands:$commands[0]}' <<<"$job"|sha256sum|cut -d ' ' -f1)
      sent=$(jq -r --arg id "$id" '.monitor.packNotifications[$id] // ""' "$STATE_FILE")
      detail=$(jq -r --slurpfile commands "$commands" '.value|. as $j|(.disposalPlan // .plan // {}) as $p|"Download ID: "+.downloadId+"\nPack workflow: "+.status+"; "+(.reason // "Evidence collection pending")+"\nSource videos: "+(($p.files // []|length)|tostring)+"; mapped episode IDs: "+(($p.targets // {}|length)|tostring)+".\n"+
        ([($p.files // [])[]|. as $f|"- "+($f.relative|.[0:500])+": "+$f.disposition+"; cleanup="+(.relative as $r|($j.cleanup.files[$r].status // "pending"))+(.relative as $r|if $j.cleanup.files[$r].status=="blocked" then "; "+($j.cleanup.files[$r].reason // "Proof unavailable"|.[0:240]) else "" end)+(.relative as $r|if ($j.cleanup.files[$r].quarantinePath // "")!="" then " -> "+($j.cleanup.files[$r].quarantinePath|.[0:500]) else "" end)]|.[:12]|join("\n"))+"\nNative commands: "+([$commands[0][]|.kind+" episode "+(.targetId|tostring)+": "+.status+" (command "+(.commandId // "unconfirmed"|tostring)+")"+(if (.nativeMessage // "")!="" then ": "+(.nativeMessage|.[0:200]) else "" end)]|join("; "))+"\nExact files, IDs, per-file cleanup receipts and native command intents remain in the pack journal. No library media was moved/deleted; no forced import or series search was requested."' <<<"$job")
      if [[ "$status" == queue_intent ]] && ((START_TIME-$(jq -r '.value.queueIntentAt // 0' <<<"$job")>1200));then
        record_normalized_issue "PACK:REVIEW:$id" Sonarr 'Pack queue disposition unverified' ARR_PACK_AUTOMATION WARNING queue-unverified 'Exact queue disposition could not be verified; no request replay or file disposal' 0 "$detail";continue
      fi
      if jq -e --slurpfile jobs "$PACK_STATE_FILE" --arg id "$id" '$jobs[0].jobs[$id] as $job|any(.[];. as $a|(.status=="failed" or .status=="intent") and $job.status!="resolved" and (($job.proofs[($a.targetId|tostring)].verified // false)|not) and (.kind!="import-retry" or ($job.status!="queue_verified" and $job.status!="manual_hold")))' "$commands" >/dev/null;then
        record_normalized_issue "PACK:REVIEW:$id" Sonarr 'Pack native command requires review' ARR_PACK_AUTOMATION WARNING command-unverified 'Native command failed or remains uncertain; no blind retry' 0 "$detail";continue
      fi
      if [[ "$status" == queue_verified ]] && jq -e --arg id "$id" 'any(.jobs[$id].cleanup.files[]?;.status=="blocked")' "$PACK_STATE_FILE" >/dev/null;then
        record_normalized_issue "PACK:REVIEW:$id" Sonarr 'Pack cleanup deferred' ARR_PACK_AUTOMATION WARNING cleanup-proof 'A per-file cleanup check could not be satisfied; affected source files retained' 0 "$detail";continue
      fi
      case "$status" in
        blocked|review|manual_hold) record_normalized_issue "PACK:REVIEW:$id" Sonarr 'Pack automation requires review' ARR_PACK_AUTOMATION WARNING "$status" "$(jq -r .value.reason <<<"$job")" 0 "$detail";;
        *) if [[ "$sent" != "$signature" ]];then event=progress;[[ "$status" != resolved ]] || event=completed
          queue_group_notification "PACK:ACTION:$id" "$signature" Sonarr "$(jq -r '.value.title // "Completed pack"' <<<"$job")" ARR_PACK_AUTOMATION INFO 0 "$detail" "$event";fi;;
      esac
    done < <(jq -c '.jobs|to_entries[]' "$PACK_STATE_FILE")
}
process_media_packs() {
    PACK_STATE_FILE="$STATE_DIR/pack-actions.json"
    [[ ! -L "$PACK_STATE_FILE" ]] || return 1
    [[ -f "$PACK_STATE_FILE" ]] || { printf '{"schema":1,"jobs":{}}' >"$TMP_DIR/pack-initial";pack_publish "$TMP_DIR/pack-initial"; } || return 1
    pack_document_valid "$PACK_STATE_FILE" || return 1
    pack_update '.jobs|=with_entries(select(.value.status!="resolved" or .value.createdAt>=$since))' --argjson since "$((START_TIME-90*86400))" || return 1
    [[ "$SONARR_QUEUE_OK" == true && "$RADARR_QUEUE_OK" == true && "$SAB_HISTORY_OK" == true && "$SAB_QUEUE_OK" == true ]] || { preserve_pack_issues;return 0; }
    local id plan="$TMP_DIR/pack-plan.json" fp previous at runs status n=0
    # Reconcile without replay before considering any new pack action.
    while read -r id;do runtime_budget_allows_optional_phase pack-queue-followup || break;pack_verify_queue_removal "$id" || true;done < <(jq -r '.jobs|to_entries[]|select(.value.status=="queue_intent")|.key' "$PACK_STATE_FILE")
    while read -r id;do runtime_budget_allows_optional_phase pack-file-followup || break;pack_followup "$id" || true;pack_update '.jobs[$id].lastFollowupAt=$at' --arg id "$id" --argjson at "$START_TIME" || return 1;done < <(jq -r '.jobs|to_entries|sort_by(.value.lastFollowupAt // 0)|map(select(.value.status=="queue_verified"))|.[:2][].key' "$PACK_STATE_FILE")
    pack_reconcile_receipts || return 1
    if [[ "$ARR_AUTOMATION_ENABLED" == true && "$POLICY_AUTOMATION_ENABLED" == true && "$AUTOMATION_CONTROLS_OK" == true ]] && automation_window_open && automation_api_ready;then
      while read -r id;do pack_submit_searches "$id" || true;done < <(jq -r '.jobs|to_entries[]|select(.value.status=="queue_verified")|.key' "$PACK_STATE_FILE")
      while read -r id;do
        ((n<2)) || break;runtime_budget_allows_optional_phase pack-discovery || break
        status=$(jq -r --arg id "$id" '.jobs[$id].status // "new"' "$PACK_STATE_FILE")
        [[ "$status" != queue_intent && "$status" != queue_verified && "$status" != resolved && "$status" != review && "$status" != manual_hold ]] || continue
        n=$((n+1))
        if ! pack_snapshot "$id" "$plan";then
          pack_update '.jobs[$id]=((.jobs[$id] // {app:"Sonarr",downloadId:$id,createdAt:$at})+{checkedAt:$at,status:"blocked",reason:"Complete source inventory, native mapping, current policy or exact identity could not be proven; payload preserved"})' --arg id "$id" --argjson at "$START_TIME" || return 1
          continue
        fi
        fp=$(jq -Sc . "$plan"|sha256sum|cut -d ' ' -f1);previous=$(jq -r --arg id "$id" '.jobs[$id].observation.fingerprint // ""' "$PACK_STATE_FILE");at=$(jq -r --arg id "$id" '.jobs[$id].observation.at // 0' "$PACK_STATE_FILE");runs=$(jq -r --arg id "$id" '.jobs[$id].observation.runs // 0' "$PACK_STATE_FILE")
        if [[ "$previous" == "$fp" ]] && ((START_TIME-at>=240 && START_TIME-at<=1200));then runs=$((runs+1));else runs=1;fi
        pack_update '.jobs[$id]=((.jobs[$id] // {app:"Sonarr",downloadId:$id,createdAt:$at})+{checkedAt:$at,title:$plan[0].title,status:(if $plan[0].unknown then "blocked" else "observing" end),reason:(if $plan[0].unknown then "Unaccounted, mixed or unsupported pack files remain protected" else "Complete pack mapping retained; waiting for stable proof or bounded native action" end),plan:$plan[0],observation:{fingerprint:$fp,at:$at,runs:$runs}})' --arg id "$id" --argjson at "$START_TIME" --arg fp "$fp" --argjson runs "$runs" --slurpfile plan "$plan" || return 1
        ((runs>=2)) || continue
        if jq -e '.accounted and (.unknown|not)' "$plan" >/dev/null;then pack_dispatch "$id" "$plan" || true
        elif jq -e '.unknown|not' "$plan" >/dev/null;then pack_submit_import "$id" "$plan" || true;fi
      done < <(jq -r --slurpfile jobs "$PACK_STATE_FILE" '[[.records[]|select(.protocol=="usenet" and .status=="completed" and (.downloadId // "")!="")]|group_by(.downloadId|ascii_downcase)|.[]|select(length>1 or any(.[];.title|test("complete|season[ ._-]*[0-9]|[Ss][0-9]{1,3}([ ._-]|$)|[Ss][0-9]{1,3}[Ee][0-9]{1,3}[Ee-][0-9]";"i")))|.[0].downloadId|ascii_downcase] | sort_by($jobs[0].jobs[.].checkedAt // 0)|.[]' "$SONARR_QUEUE")
    fi
    pack_report
}
preserve_pack_issues() {
    [[ -f "${STATE_FILE:-}" ]] || return 0
    local key
    while IFS= read -r key;do mark_seen "$key";done < <(jq -r '.issues|to_entries[]|select(.value.active==true and (.key|startswith("PACK:")))|.key' "$STATE_FILE")
}
# END EMBEDDED MEDIA PACK ENGINE

process_arr_automation() {
    [ -f "${AUTOMATION_STATE_FILE:-}" ] && automation_document_valid "$AUTOMATION_STATE_FILE" actions || return 0
    if automation_api_ready; then
        automation_reconcile_commands || return 1
        automation_followup_imports || return 1
        automation_retry_exhaustion || { automation_preserve_retry_exhaustion;return 1; }
    else automation_preserve_retry_exhaustion;fi
    if [ "$ARR_AUTOMATION_ENABLED" = true ] && [ "$AUTOMATION_CONTROLS_OK" = true ] && automation_window_open; then
        automation_import_retries || true
        automation_missing_searches || true
    fi
    automation_report
}

policy_disposition_matches() {
    local app="$1" id="${2,,}" item="$3" file="${POLICY_STATE_FILE:-$STATE_DIR/policy-actions.json}"
    [ -r "$file" ] || return 1
    if [ "${POLICY_JOURNAL_TRUSTED:-false}" != true ]; then
        policy_validate_journal "$file" || return 1
        POLICY_JOURNAL_TRUSTED=true
    fi
    local input="$TMP_DIR/policy-leftover-item.json"
    printf '%s' "$item" >"$input" || return 1
    jq -e --arg app "$app" --arg id "$id" --slurpfile item "$input" '
      .actions[$id] | .status=="done" and .queueVerified==true and .app==$app and
      .sab==($item[0]|{nzo_id,name,storage,completed,category})' "$file" >/dev/null
}

arr_policy_receipt_document_valid() {
    jq -e '
      type=="object" and .version==1 and (.actions|type)=="object" and (.observations|type)=="object" and
      all(.actions|to_entries[];
        .key as $id | .value |
        .downloadId==$id and ($id|test("^[a-z0-9-]+$")) and
        ((.sab.nzo_id // ""|ascii_downcase)==$id) and ((.queue.downloadId // ""|ascii_downcase)==$id) and .queue.id==.queueId and
        ((.app=="Sonarr" and .kind=="episode") or (.app=="Radarr" and .kind=="movie")) and
        (.mode=="redundant" or .mode=="replace") and
        (.status=="intent" or .status=="queue_verified" or .status=="search_uncertain" or .status=="done") and
        ([.targetId,.parentId,.queueId,.startedAt] | all(.[]; type=="number" and .>0 and .==floor)) and
        (.command == (if .kind=="episode" then {name:"EpisodeSearch",episodeIds:[.targetId]} else {name:"MoviesSearch",movieIds:[.targetId]} end)) and
        ([.replacementProofRuns // 0,.replacementCheckedAt // 0,.searchStartedAt // 0] | all(.[];type=="number" and .>=0 and .==floor)) and
        (.profile|type)=="object" and (.target|type)=="object" and (.parent|type)=="object" and (.sab|type)=="object" and (.queue|type)=="object")
    ' "$1" >/dev/null
}

policy_validate_journal() { arr_policy_receipt_document_valid "$1"; }

policy_publish() {
    local candidate="$1" target="$2"
    policy_validate_journal "$candidate" || return 1
    if [ -f "$target" ] && cmp -s -- "$candidate" "$target"; then
        rm -f -- "$candidate"
        return 0
    fi
    sync -- "$candidate" || return 1
    if [ -f "$target" ] && policy_validate_journal "$target"; then
        cp -- "$target" "${target}.bak.tmp.$$" && sync -- "${target}.bak.tmp.$$" && mv -- "${target}.bak.tmp.$$" "${target}.bak" || return 1
    fi
    mv -f -- "$candidate" "$target" && sync -- "$target" && sync -- "$(dirname -- "$target")"
}

policy_update_action() {
    local id="$1" patch="$2" tmp="${POLICY_STATE_FILE}.tmp.$$"
    jq --arg id "$id" --argjson patch "$patch" '.actions[$id] += $patch' "$POLICY_STATE_FILE" >"$tmp" && policy_publish "$tmp" "$POLICY_STATE_FILE"
}

policy_mutate() {
    local method="$1" url="$2" key="$3" body="$4" output="$5"
    monitor_mutation_gate "$(api_service_for_url "$url")" || return 75
    runtime_budget_allows_optional_phase arr-mutation || return 75
    # NO --retry: a timeout may follow a successfully applied mutation.
    local code
    code=$(curl --silent --show-error --connect-timeout "$HTTP_CONNECT_TIMEOUT_SECONDS" \
      --max-time "$HTTP_REQUEST_TIMEOUT_SECONDS" --max-filesize 1048576 \
      -X "$method" -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
      --data-binary "$body" -o "$output" -w '%{http_code}' "$url") || return 1
    [[ "$code" =~ ^2[0-9][0-9]$ ]]
}

policy_queue_reason() {
    # Require every native import rejection to belong to the SAME allowlisted
    # policy decision. Mixed filesystem/identity/permission warnings are held.
    jq -r '
      [.statusMessages[]?.messages[]?] as $reasons
      | if ($reasons|length)==0 then "hold"
        elif all($reasons[]; test("^Not (a |an )?(Custom Format|quality revision|upgrade for existing)";"i"))
             and all($reasons[]; (test("AfterRename|BeforeRename";"i")|not)) then "redundant"
        elif all($reasons[]; test("^Custom Formats? .*(have score|score of|score) -?[0-9]+ .*below .*profile minimum -?[0-9]+$";"i")) then "replace"
        else "hold" end' <<<"$1"
}

policy_build_candidate() {
    local app="$1" item="$2" output="$3" id queue_id root key history target parent profile file_id file
    local item_file="$TMP_DIR/policy-queue-item.json"
    printf '%s' "$item" >"$item_file" || return 1
    id=$(jq -r '.downloadId | ascii_downcase' <<<"$item")
    [[ "$id" =~ ^[a-z0-9-]+$ ]] || return 1
    queue_id=$(jq -r '.id' <<<"$item")
    [[ "$queue_id" =~ ^[1-9][0-9]*$ ]] || return 1
    local mode; mode=$(policy_queue_reason "$item")
    [[ "$mode" != hold ]] || return 1
    # Completed Usenet only; multi-file and multi-episode releases fail closed.
    jq -e '(.protocol|ascii_downcase)=="usenet" and (.status|ascii_downcase)=="completed" and
      .trackedDownloadState=="importPending" and (.trackedDownloadStatus=="warning" or .trackedDownloadStatus=="error")' <<<"$item" >/dev/null || return 1
    local sab="$TMP_DIR/policy-sab.json"
    jq --arg id "$id" '[.history.slots[]? | select((.nzo_id|ascii_downcase)==$id)] | select(length==1) | .[0] | select(.status=="Completed")' "$SAB_HISTORY" >"$sab" || return 1
    jq -e 'type=="object"' "$sab" >/dev/null || return 1
    local completed added; completed=$(jq -r '.completed // 0 | tonumber? // 0 | floor' "$sab")
    added=$(date_to_epoch "$(jq -r '.added // ""' <<<"$item")")
    (( completed>0 && added>0 && START_TIME-completed>=POLICY_GRACE_HOURS*3600 && START_TIME-added>=POLICY_GRACE_HOURS*3600 )) || return 1
    # SAB must have no active entry for this ID (including paused/post-processing).
    jq -e --arg id "$id" 'all(.queue.slots[]?; (.nzo_id|ascii_downcase)!=$id)' "$SAB_QUEUE" >/dev/null || return 1
    IFS=$'\t' read -r root key < <(arr_reconciliation_connection "$app")
    history="$TMP_DIR/policy-history.json"
    fetch_arr_history_by_download_id "$app" "$id" "$history" || return 1
    jq -e --arg id "$id" '(.records|type)=="array" and (.totalRecords==(.records|length)) and all(.records[]; ((.downloadId // "")|ascii_downcase)==$id) and
      any(.records[]; .eventType=="grabbed") and all(.records[]; .eventType!="downloadFolderImported" and .eventType!="downloadFailed" and .eventType!="downloadIgnored")' "$history" >/dev/null || return 1
    target="$TMP_DIR/policy-target.json"; parent="$TMP_DIR/policy-parent.json"; profile="$TMP_DIR/policy-profile.json"; file="$TMP_DIR/policy-file.json"
    local target_id parent_id endpoint kind command ids_field
    if [ "$app" = Sonarr ]; then
        target_id=$(jq -r '.episodeId // 0' <<<"$item"); parent_id=$(jq -r '.seriesId // 0' <<<"$item")
        [[ "$target_id" =~ ^[1-9][0-9]*$ && "$parent_id" =~ ^[1-9][0-9]*$ ]] || return 1
        # Exact one grabbed episode, exact series/season/episode. Title parsing
        # only acts as an additional PACK VETO, never identity proof.
        jq -e --argjson id "$target_id" --argjson parent "$parent_id" '[.records[] | select(.eventType=="grabbed")] as $g |
          ($g|length)==1 and $g[0].episodeId==$id and $g[0].seriesId==$parent' "$history" >/dev/null || return 1
        jq -e '.title | test("[Ss][0-9]{1,3}[Ee][0-9]{1,3}([^0-9Ee-]|$)") and (test("[Ss][0-9]{1,3}[Ee][0-9]{1,3}([Ee-][0-9]|.*[Ss][0-9]{1,3}[Ee][0-9])|complete|season[ ._-]*[0-9]";"i")|not)' <<<"$item" >/dev/null || return 1
        api_get "$root/episode/$target_id" "$key" "$target" && api_get "$root/series/$parent_id" "$key" "$parent" || return 1
        jq -e --argjson id "$target_id" --argjson parent "$parent_id" --slurpfile queue_item "$item_file" '$queue_item[0] as $item | .id==$id and .seriesId==$parent and .seasonNumber==$item.seasonNumber and .episodeNumber>0 and .monitored==true' "$target" >/dev/null || return 1
        local season; season=$(jq '.seasonNumber' "$target")
        jq -e --argjson id "$parent_id" --argjson season "$season" '.id==$id and .monitored==true and any(.seasons[]?; .seasonNumber==$season and .monitored==true) and (.tags|length)==0' "$parent" >/dev/null || return 1
        file_id=$(jq -r '.episodeFileId // 0' "$target"); endpoint=episodefile; kind=episode; command=EpisodeSearch; ids_field=episodeIds
    else
        target_id=$(jq -r '.movieId // 0' <<<"$item"); parent_id="$target_id"
        [[ "$target_id" =~ ^[1-9][0-9]*$ ]] || return 1
        jq -e --argjson id "$target_id" '[.records[] | select(.eventType=="grabbed")] as $g | ($g|length)==1 and $g[0].movieId==$id' "$history" >/dev/null || return 1
        api_get "$root/movie/$target_id" "$key" "$target" || return 1
        cp "$target" "$parent" || return 1
        jq -e --argjson id "$target_id" '.id==$id and .monitored==true and (.tags|length)==0' "$target" >/dev/null || return 1
        file_id=$(jq -r '.movieFileId // 0' "$target"); endpoint=moviefile; kind=movie; command=MoviesSearch; ids_field=movieIds
    fi
    media_recovery_app_held "$app" "$parent_id" && return 1
    local profile_id; profile_id=$(jq -r '.qualityProfileId // 0' "$parent")
    [[ "$profile_id" =~ ^[1-9][0-9]*$ ]] || return 1
    api_get "$root/qualityprofile/$profile_id" "$key" "$profile" || return 1
    jq -e --argjson id "$profile_id" '.id==$id and (.minFormatScore|type)=="number"' "$profile" >/dev/null || return 1
    printf '{}\n' >"$file"
    jq -e --slurpfile p "$profile" '
      .quality.quality.id as $quality |
      [$p[0].items[] | select(.allowed==true) | .quality.id, .items[]?.quality.id] | index($quality)!=null' <<<"$item" >/dev/null || return 1
    if [ "$mode" = redundant ]; then
        [[ "$file_id" =~ ^[1-9][0-9]*$ ]] || return 1
        api_get "$root/$endpoint/$file_id" "$key" "$file" || return 1
        jq -e --argjson id "$file_id" --argjson parent "$parent_id" --arg kind "$kind" --slurpfile profile "$profile" '
          .id==$id and (if $kind=="episode" then .seriesId==$parent else .movieId==$parent end) and
          (.path|type)=="string" and (.path|length)>0 and .size>0 and
          (.customFormatScore|type)=="number" and .customFormatScore >= $profile[0].minFormatScore and
          (.quality.quality.id as $quality | [$profile[0].items[] | select(.allowed==true) | .quality.id, .items[]?.quality.id] | index($quality)!=null)' "$file" >/dev/null || return 1
    else
        # Replacement applies only to genuinely missing monitored media. An
        # existing copy, conflicting hasFile, any tag, or profile mismatch vetoes.
        [[ "$file_id" = 0 ]] || return 1
        jq -e '.hasFile==false' "$target" >/dev/null || return 1
        jq -e --slurpfile p "$profile" '
          . as $q | (.customFormatScore|type)=="number" and .customFormatScore < $p[0].minFormatScore and
          all(.statusMessages[]?.messages[]?;
            capture("score (?<score>-?[0-9]+) .*profile minimum (?<minimum>-?[0-9]+)$";"i") |
            (.score|tonumber)==$q.customFormatScore and (.minimum|tonumber)==$p[0].minFormatScore)' <<<"$item" >/dev/null || return 1
    fi
    local profile_signature=''
    if [[ -f "${AUTOMATION_STATE_FILE:-}" ]];then profile_signature=$(jq -r --arg app "$app" '.profiles[$app].signature // ""' "$AUTOMATION_STATE_FILE") || return 1;fi
    jq -n --arg profileSignature "$profile_signature" --arg app "$app" --arg id "$id" --arg mode "$mode" --arg kind "$kind" --arg command "$command" --arg field "$ids_field" \
      --argjson targetId "$target_id" --argjson parentId "$parent_id" --argjson queueId "$queue_id" --slurpfile queue_item "$item_file" \
      --slurpfile target "$target" --slurpfile parent "$parent" --slurpfile profile "$profile" --slurpfile file "$file" --slurpfile sab "$sab" \
      '$queue_item[0] as $item | {app:$app,downloadId:$id,mode:$mode,kind:$kind,targetId:$targetId,parentId:$parentId,queueId:$queueId,
        title:$item.title,profileSignature:$profileSignature,warning:[$item.statusMessages[]?.messages[]?],command:{name:$command,($field):[$targetId]},
        fileId:($file[0].id // 0),filePath:($file[0].path // ""),profile:$profile[0],target:$target[0],parent:$parent[0],
        sab:($sab[0]|{nzo_id,name,storage,completed,category}),queue:$item}' >"$output"
}

policy_observe() {
    local id="$1" fingerprint="$2" tmp="${POLICY_STATE_FILE}.tmp.$$"
    jq --arg id "$id" --arg fingerprint "$fingerprint" --argjson now "$START_TIME" '
      .observations[$id] as $old | .observations[$id]={fingerprint:$fingerprint,at:$now,
        runs:(if $old.fingerprint==$fingerprint and ($now-$old.at)<=1200 then
          (if ($now-$old.at)>=240 then ($old.runs+1) else $old.runs end) else 1 end),
        at:(if $old.fingerprint==$fingerprint and ($now-$old.at)<240 then $old.at else $now end)}' \
      "$POLICY_STATE_FILE" >"$tmp" && policy_publish "$tmp" "$POLICY_STATE_FILE" || return 1
    jq -e --arg id "$id" '.observations[$id].runs>=2' "$POLICY_STATE_FILE" >/dev/null
}

policy_verify_removed() {
    local app="$1" id="$2" root="$3" key="$4" mode="$5" q="$TMP_DIR/policy-verify-queue.json"
    fetch_arr_queue "$app" "$root" "$key" "$q" || return 1
    jq -e --arg id "$id" 'all(.records[]; ((.downloadId // "")|ascii_downcase)!=$id)' "$q" >/dev/null || return 1
    local history="$TMP_DIR/policy-verify-history.json"
    fetch_arr_history_by_download_id "$app" "$id" "$history" || return 1
    jq -e --arg id "$id" --arg mode "$mode" '.records|any(.[]; ((.downloadId // "")|ascii_downcase)==$id and
      .eventType==(if $mode=="replace" then "downloadFailed" else "downloadIgnored" end))' "$history" >/dev/null || return 1
    if [ "$mode" = replace ]; then
        # Failed history alone does not establish blocklist insertion.
        local b="$TMP_DIR/policy-blocklist.json"
        api_get "$root/blocklist?page=1&pageSize=100&sortKey=date&sortDirection=descending" "$key" "$b" || return 1
        # Arr blocklist resources do not expose downloadId. Correlate the
        # exact original download through its history, then exact native media
        # IDs, release title, quality, and insertion time in the blocklist.
        jq -e --arg id "$id" --slurpfile journal "$POLICY_STATE_FILE" '
          $journal[0].actions[$id] as $a | any(.records[]?;
            .sourceTitle==$a.title and .quality==$a.queue.quality and
            (if $a.kind=="episode" then .seriesId==$a.parentId and (.episodeIds|sort)==[$a.targetId] else .movieId==$a.targetId end) and
            ((try (.date|sub("\\.[0-9]+Z$";"Z")|fromdateiso8601) catch 0) >= $a.startedAt-5))' "$b" >/dev/null || return 1
    fi
}

policy_finish_tracking() {
    local action="$1" id app mode root key tmp status body target_id kind current
    local action_file="$TMP_DIR/policy-active-action.json"
    monitor_mutation_gate "$(jq -r '.app' <<<"$action")" || return 0
    printf '%s' "$action" >"$action_file" || return 1
    id=$(jq -r '.downloadId' <<<"$action"); app=$(jq -r '.app' <<<"$action"); mode=$(jq -r '.mode' <<<"$action")
    status=$(jq -r '.status' <<<"$action")
    IFS=$'\t' read -r root key < <(arr_reconciliation_connection "$app")
    if [ "$status" = intent ]; then
        # Recovery only verifies the original DELETE; it NEVER submits it again.
        policy_verify_removed "$app" "$id" "$root" "$key" "$mode" || return 1
        policy_update_action "$id" '{"status":"queue_verified","queueVerified":true}' || return 1
        status=queue_verified
    fi
    if [[ ( "$status" == queue_verified || "$status" == search_uncertain ) && "$mode" == replace ]];then
        policy_check_replacement "$action" || true
        if jq -e --arg id "$id" '.actions[$id].replacementState=="import_verified"' "$POLICY_STATE_FILE" >/dev/null;then
            policy_update_action "$id" '{"status":"done","queueVerified":true,"resolutionSource":"verified-current-file"}' || return 1
            return 0
        fi
    fi
    if [ "$status" = queue_verified ] && [ "$mode" = replace ]; then
        if [ -f "${AUTOMATION_STATE_FILE:-}" ]; then
            [ "${ARR_AUTOMATION_ENABLED:-true}" = true ] && [ "${AUTOMATION_CONTROLS_OK:-false}" = true ] && automation_window_open || return 1
        fi
        # Re-read monitoring/identity immediately before search: a user may have
        # deleted or unmonitored the target between rejection and this step.
        target_id=$(jq -r '.targetId' <<<"$action"); kind=$(jq -r '.kind' <<<"$action")
        current="$TMP_DIR/policy-presearch.json"
        api_get "$root/$kind/$target_id" "$key" "$current" || return 1
        jq -e --argjson id "$target_id" '.id==$id and .monitored==true and .hasFile==false' "$current" >/dev/null || return 1
        local parent="$TMP_DIR/policy-presearch-parent.json" parent_kind=movie parent_id
        parent_id=$(jq -r '.parentId' <<<"$action"); media_recovery_app_held "$app" "$parent_id" && return 1
        [ "$app" != Sonarr ] || parent_kind=series
        api_get "$root/$parent_kind/$parent_id" "$key" "$parent" || return 1
        jq -e --argjson id "$parent_id" --slurpfile action_record "$action_file" '$action_record[0] as $action | .id==$id and .monitored==true and (.tags|length)==0 and .qualityProfileId==$action.parent.qualityProfileId and
          (if $action.kind=="episode" then any(.seasons[]?; .seasonNumber==$action.target.seasonNumber and .monitored==true) else true end)' "$parent" >/dev/null || return 1
        local profile="$TMP_DIR/policy-presearch-profile.json" profile_id
        profile_id=$(jq -r '.qualityProfileId' "$parent")
        api_get "$root/qualityprofile/$profile_id" "$key" "$profile" || return 1
        jq -e --slurpfile action_record "$action_file" '$action_record[0] as $action | .==$action.profile' "$profile" >/dev/null || return 1
        # Persist before POST. A timeout or interruption leaves an uncertain
        # search, which is not automatically repeated.
        policy_update_action "$id" "{\"status\":\"search_uncertain\",\"searchStartedAt\":$START_TIME}" || return 1
        body=$(jq -c '.command' <<<"$action")
        local mutation_rc=0
        policy_mutate POST "$root/command" "$key" "$body" "$TMP_DIR/policy-search-response.json" || mutation_rc=$?
        if ((mutation_rc==75));then
            policy_update_action "$id" '{"status":"queue_verified","searchNotDispatched":true}' || return 1
            printf '%s\n' "$app: replacement search deferred locally before HTTP; verified queue disposition retained" >>"$TMP_DIR/automation-deferrals.txt"
            return 0
        fi
        ((mutation_rc==0)) || return 1
        local command_id; command_id=$(jq -r '.id // 0' "$TMP_DIR/policy-search-response.json")
        [[ "$command_id" =~ ^[1-9][0-9]*$ ]] || return 1
        policy_update_action "$id" "{\"commandId\":$command_id}" || return 1
        status=search_uncertain
    fi
    if [ "$status" = search_uncertain ]; then
        local command_id; command_id=$(jq -r --arg id "$id" '.actions[$id].commandId // 0' "$POLICY_STATE_FILE")
        if ! [[ "$command_id" =~ ^[1-9][0-9]*$ ]];then
            jq '.startedAt=(.searchStartedAt // .startedAt)' "$action_file" >"$TMP_DIR/policy-command-match-action.json" || return 1
            automation_find_existing_command "$TMP_DIR/policy-command-match-action.json" "$root" "$key" "$TMP_DIR/policy-command-match.json" || return 1
            command_id=$(jq -r '.id' "$TMP_DIR/policy-command-match.json")
            policy_update_action "$id" "{\"commandId\":$command_id,\"commandMatchedBy\":\"unique exact native body and queued time; no replay\"}" || return 1
        fi
        api_get "$root/command/$command_id" "$key" "$TMP_DIR/policy-command-verify.json" || return 1
        jq -e --argjson id "$command_id" --slurpfile action_record "$action_file" '$action_record[0] as $action | .id==$id and .name==$action.command.name and
          (.status=="queued" or .status=="started" or .status=="completed") and
          (if $action.kind=="movie" then .body.movieIds==$action.command.movieIds else .body.episodeIds==$action.command.episodeIds end)' "$TMP_DIR/policy-command-verify.json" >/dev/null || return 1
    fi
    policy_update_action "$id" '{"status":"done","queueVerified":true}' || return 1
}

policy_check_replacement() {
    local action="$1" id root key target_id parent_id kind target file file_id epoch
    local action_file="$TMP_DIR/policy-active-action.json"
    monitor_mutation_gate "$(jq -r '.app' <<<"$action")" || return 0
    printf '%s' "$action" >"$action_file" || return 1
    id=$(jq -r '.downloadId' <<<"$action")
    local check_interval=3600
    (( $(jq -r '.replacementProofRuns // 0' <<<"$action")>0 )) && check_interval=240
    (( START_TIME >= $(jq -r '.replacementCheckedAt // 0' <<<"$action")+check_interval )) || return 0
    IFS=$'\t' read -r root key < <(arr_reconciliation_connection "$(jq -r '.app' <<<"$action")")
    target_id=$(jq -r '.targetId' <<<"$action"); parent_id=$(jq -r '.parentId' <<<"$action"); kind=$(jq -r '.kind' <<<"$action")
    target="$TMP_DIR/policy-replacement-target.json"; file="$TMP_DIR/policy-replacement-file.json"
    # Any interrupted or negative check breaks the consecutive confirmation pair.
    policy_update_action "$id" "{\"replacementCheckedAt\":$START_TIME,\"replacementProofRuns\":0,\"replacementProofFingerprint\":\"\"}" || return 1
    api_get "$root/$kind/$target_id" "$key" "$target" || return 1
    jq -e --argjson id "$target_id" --argjson parent "$parent_id" --slurpfile action_record "$action_file" '$action_record[0] as $action | .id==$id and
      (if $action.kind=="episode" then .seriesId==$parent and .seasonNumber==$action.target.seasonNumber and .episodeNumber==$action.target.episodeNumber else true end)' "$target" >/dev/null || return 1
    file_id=$(jq -r '.episodeFileId // .movieFileId // 0' "$target")
    [[ "$file_id" =~ ^[1-9][0-9]*$ ]] || return 0
    api_get "$root/${kind}file/$file_id" "$key" "$file" || return 1
    jq -e --argjson id "$file_id" --argjson parent "$parent_id" --arg kind "$kind" '.id==$id and .size>0 and (.path|length)>0 and
      (if $kind=="episode" then .seriesId==$parent else .movieId==$parent end)' "$file" >/dev/null || return 1
    epoch=$(date_to_epoch "$(jq -r '.dateAdded // ""' "$file")")
    (( epoch >= $(jq -r '.startedAt' <<<"$action") )) || return 0
    local parent="$TMP_DIR/policy-replacement-parent.json" profile="$TMP_DIR/policy-replacement-profile.json" parent_kind=movie profile_id
    [ "$kind" != episode ] || parent_kind=series
    api_get "$root/$parent_kind/$parent_id" "$key" "$parent" || return 1
    profile_id=$(jq -r '.qualityProfileId // 0' "$parent")
    [[ "$profile_id" =~ ^[1-9][0-9]*$ ]] || return 1
    api_get "$root/qualityprofile/$profile_id" "$key" "$profile" || return 1
    jq -e --slurpfile p "$profile" '(.customFormatScore|type)=="number" and .customFormatScore >= $p[0].minFormatScore and
      (.quality.quality.id as $quality | [$p[0].items[] | select(.allowed==true) | .quality.id, .items[]?.quality.id] | index($quality)!=null)' "$file" >/dev/null || return 0
    local fingerprint runs
    fingerprint=$(printf '%s' "$kind:$target_id:$parent_id:$file_id:$epoch"|sha256sum|cut -d ' ' -f1)
    policy_update_action "$id" "$(jq -cn --arg fp "$fingerprint" --argjson prior "$(jq -r '.replacementProofRuns // 0' <<<"$action")" --arg old "$(jq -r '.replacementProofFingerprint // ""' <<<"$action")" '{replacementProofFingerprint:$fp,replacementProofRuns:(if $old==$fp then $prior+1 else 1 end)}')" || return 1
    runs=$(jq -r --arg id "$id" '.actions[$id].replacementProofRuns' "$POLICY_STATE_FILE")
    ((runs>=2)) || return 0
    # This verifies the database import; do not touch physical media paths.
    policy_update_action "$id" "{\"replacementState\":\"import_verified\",\"replacementFileId\":$file_id,\"replacementImportedAt\":$epoch}"
}

# Read companion receipts; cleanup never writes this monitor's journal.
# A missing source, a completed search or an HTTP 2xx alone cannot resolve work.
policy_reconcile_cleanup() {
    local file="${MEDIA_POLICY_CLEANUP_RECEIPT:-/mnt/vault/cloud/logs/script/media_cleanup/sab/policy-cleanup.json}" sources="${MEDIA_CLEANUP_SOURCE_RECEIPTS:-/mnt/vault/cloud/logs/script/media_cleanup/sab/source-removals.json}" empty="$TMP_DIR/policy-cleanup-empty.json" next="$TMP_DIR/policy-cleanup-merged.json"
    printf '{"schema":1,"actions":{},"records":{}}' >"$empty"
    if [[ -e "$file" ]];then [[ ! -L "$file" ]] && jq -e '.schema==1 and (.actions|type)=="object"' "$file" >/dev/null || return 1;else file="$empty";fi
    if [[ -e "$sources" ]];then [[ ! -L "$sources" ]] && jq -e '.schema==1 and (.records|type)=="object"' "$sources" >/dev/null || return 1;else sources="$empty";fi
    jq --slurpfile cleanup "$file" --slurpfile sources "$sources" --argjson now "$START_TIME" '
      ([$sources[0].records[]?|select(.proofKind=="policy-disposition" and (.at|type)=="number" and .at<=$now+300)]|sort_by(.at)|INDEX([.app,.downloadId,.policyStartedAt,.targetId]|tojson)) as $sourceIndex |
      .actions |= with_entries(.value as $p | .value |= (
        $sourceIndex[([$p.app,$p.downloadId,$p.startedAt,$p.targetId]|tojson)] as $entry |
        (if $entry!=null and $entry.sab==$p.sab and $entry.at>=$p.startedAt then $entry else null end) as $committed |
        $cleanup[0].actions[$p.downloadId] as $c |
        if $committed!=null and ($committed.action=="restored" or $committed.action=="restore_requested") then .cleanup={status:"manual_restore",reason:"Operator restore/request recorded; automatic re-quarantine held",sourcePath:$committed.originalPath,at:$committed.at}
        elif $committed!=null and $committed.action=="quarantined" and $committed.sourceAbsent==true and ($committed.originalPath|type)=="string" and ($committed.destination|type)=="string" then .cleanup={status:"quarantined",reason:"Committed quarantine and source-removal proof verified",sourcePath:$committed.originalPath,quarantinePath:$committed.destination,at:$committed.at}
        elif $c!=null and $c.app==$p.app and $c.policyStartedAt==$p.startedAt and $c.targetId==$p.targetId and $c.sab==$p.sab and
          ($c.at|type)=="number" and $c.at>=$p.startedAt and $c.at<=$now+300 and
          (["blocked","deferred","failed","source_unverified","waiting_grace","manual_restore"]|index($c.status))!=null then .cleanup=$c
        else .cleanup //= {status:"pending",reason:"Awaiting exact cleanup acknowledgement"} end |
        .workflow=(if .status!="done" then "rejection_unverified" elif .cleanup.status=="quarantined" and (.mode=="redundant" or .replacementState=="import_verified") then "resolved"
          elif .cleanup.status=="manual_restore" then "manual_hold"
          elif .cleanup.status=="failed" or .cleanup.status=="blocked" or .cleanup.status=="source_unverified" then "cleanup_blocked"
          elif .mode=="replace" and .replacementState!="import_verified" then "replacement_import_pending" else "cleanup_pending" end)))' "$POLICY_STATE_FILE" >"$next" || return 1
    policy_publish "$next" "$POLICY_STATE_FILE"
}
policy_notification_signature() {
    jq -r '
      "policy:"+.status+":"+(.replacementState // "waiting")+":"+((.replacementFileId // 0)|tostring)+":"+(.workflow // "pending")+":"+(.cleanup.status // "pending")+":"+(.cleanup.reason // "")'
}

policy_report_actions() {
    if ! policy_reconcile_cleanup;then
      record_normalized_issue Monitor:policy-cleanup-receipt Monitor 'Cleanup receipt unavailable' ARR_POLICY_AUTOMATION WARNING unverified-cleanup 'Companion cleanup evidence is invalid/unavailable' 0 'Existing policy/cleanup state preserved. No disappearance, quarantine or resolution was inferred; inspect receipt storage.'
    fi
    local action id status severity detail app title
    while IFS= read -r action; do
        id=$(jq -r '.downloadId' <<<"$action"); status=$(jq -r '.status' <<<"$action"); app=$(jq -r '.app' <<<"$action"); title=$(jq -r '.title' <<<"$action")
        severity=WARNING; [ "$status" != done ] || severity=INFO
        detail="Workflow: $(jq -r '.workflow // "pending"' <<<"$action"). Download ID: $id"$'\n'"Cleanup: $(jq -r '.cleanup.status // "pending"' <<<"$action"); $(jq -r '.cleanup.reason // "Awaiting exact acknowledgement"' <<<"$action")."$'\n'
        if [ "$status" = done ]; then
            if [[ "$(jq -r '.cleanup.status // "pending"' <<<"$action")" == quarantined ]];then
                detail+="Payload quarantined: $(jq -r .cleanup.sourcePath <<<"$action") -> $(jq -r .cleanup.quarantinePath <<<"$action"). Committed source-removal receipt verified; configured quarantine retention applies."$'\n'
            else detail+="Queue removal and native disposition verified. Payload retained pending guarded quarantine by media_cleanup; library unchanged by rejection."$'\n';fi
            if [ "$(jq -r '.mode' <<<"$action")" = replace ]; then
                if [ "$(jq -r '.replacementState // "waiting"' <<<"$action")" = import_verified ]; then
                    if [[ "$(jq -r '.resolutionSource // ""' <<<"$action")" == verified-current-file ]];then
                        detail+="A fresh policy-compliant file was verified on two scans (file ID $(jq -r '.replacementFileId' <<<"$action")). Closed the obsolete pending search; no additional search was sent. Import initiator was not attributed."
                    else
                        detail+="Exact release blocklisted; targeted replacement search accepted. A subsequent exact-target Arr file import was verified on two scans (file ID $(jq -r '.replacementFileId' <<<"$action"))."
                    fi
                else
                    detail+="Exact release blocklisted; one targeted replacement search accepted (command $(jq -r '.commandId' <<<"$action")). Compliant import still pending; no success inferred."
                fi
            else
                detail+="Redundant release ignored without blocklisting or replacement search; existing file ID $(jq -r '.fileId' <<<"$action") retained."
            fi
            if [ "$(jq -r '.mode' <<<"$action")" = replace ] &&
               [ "$(jq -r '.replacementState // "waiting"' <<<"$action")" != import_verified ] &&
               (( START_TIME-$(jq -r '.startedAt' <<<"$action")>=7*86400 )); then
                record_normalized_issue "POLICY:WAITING:$id" "$app" "$title" ARR_POLICY_REPLACEMENT_PENDING WARNING waiting \
                  'No policy-compliant replacement imported within seven days' 168 \
                  "$detail No repeated search was sent. Review release availability or the quality profile if this remains required."
            fi
        else
            detail+="Checkpoint: $status. Request outcome or next action is not fully verified; automatic mutation replay prohibited. Payload preserved."
        fi
        detail+=$'\n'"Original warning: $(jq -r '(.warning // [])|join("; ")' <<<"$action")"
        local signature
        signature=$(policy_notification_signature <<<"$action")
        if [[ "$status" == done && "$(jq -r '.cleanup.status // "pending"' <<<"$action")" != quarantined && "$(jq -r '.cleanup.status // "pending"' <<<"$action")" != manual_restore ]] && ((START_TIME-$(jq -r .startedAt <<<"$action")>=POLICY_CLEANUP_EXPECTED_HOURS*3600));then
            record_normalized_issue "POLICY:CLEANUP:$id" "$app" "$title" ARR_POLICY_CLEANUP_BLOCKED WARNING cleanup-blocked 'Verified rejection still awaits cleanup acknowledgement' 0 "$detail No repeated rejection/search was sent. Latest cleanup blocker above identifies the required action."
        fi
        if [ "$status" = done ]; then
            local sent; sent=$(jq -r --arg id "$id" '.monitor.policyNotifications[$id] // ""' "$STATE_FILE")
            if [ "$sent" != "$signature" ]; then
                local outcome_event=progress
                [[ "$(jq -r '.workflow // "pending"' <<<"$action")" != resolved ]] || outcome_event=completed
                queue_group_notification "POLICY:ACTION:$id" "$signature" "$app" "$title" ARR_POLICY_AUTOMATION INFO 0 "$detail" "$outcome_event"
            fi
        else
            record_normalized_issue "POLICY:$id" "$app" "$title" ARR_POLICY_AUTOMATION "$severity" "$status" \
              "Policy action: $status" 0 "$detail" 1 0 0
        fi
    done < <(jq -c --slurpfile monitor "$STATE_FILE" --argjson now "$START_TIME" '
      .actions[] | ("policy:"+.status+":"+(.replacementState // "waiting")+":"+((.replacementFileId // 0)|tostring)+":"+(.workflow // "pending")+":"+(.cleanup.status // "pending")+":"+(.cleanup.reason // "")) as $signature |
      select(.status!="done" or ($monitor[0].monitor.policyNotifications[.downloadId] // "")!=$signature or
        (.mode=="replace" and (.replacementState // "")!="import_verified" and $now-.startedAt>=7*86400))' "$POLICY_STATE_FILE")
}

process_policy_remediation() {
    POLICY_STATE_FILE="$STATE_DIR/policy-actions.json"
    if [ "$POLICY_AUTOMATION_ENABLED" != true ]; then
        if [ -f "$POLICY_STATE_FILE" ] && policy_validate_journal "$POLICY_STATE_FILE"; then
            policy_report_actions
        fi
        return 0
    fi
    if [ ! -e "$POLICY_STATE_FILE" ]; then
        printf '{"version":1,"actions":{},"observations":{}}\n' >"${POLICY_STATE_FILE}.tmp.$$" && policy_publish "${POLICY_STATE_FILE}.tmp.$$" "$POLICY_STATE_FILE" || return 1
    fi
    if ! policy_validate_journal "$POLICY_STATE_FILE"; then
        record_normalized_issue POLICY:state Monitor 'Policy automation stopped' ARR_POLICY_AUTOMATION ERROR invalid-state \
          'Policy journal invalid; no actions permitted' 0 'Existing journal preserved. Restore its backup or review the damaged file before enabling actions.'
        return 1
    fi
    # Both queues and SAB must be complete and healthy for ANY remediation.
    if [ "$SONARR_QUEUE_OK" != true ] || [ "$RADARR_QUEUE_OK" != true ] || [ "$SAB_HISTORY_OK" != true ] || [ "$SAB_QUEUE_OK" != true ]; then
        policy_report_actions
        return 0
    fi
    local maintenance="${POLICY_STATE_FILE}.tmp.$$"
    jq --argjson now "$START_TIME" '.observations |= with_entries(select(.value.at>=$now-86400)) |
      .actions |= with_entries(select(.value.status!="done" or .value.startedAt>=$now-365*86400))' "$POLICY_STATE_FILE" >"$maintenance" &&
      policy_publish "$maintenance" "$POLICY_STATE_FILE" || return 1
    local action id app queue root key item mode fingerprint count=0 daily target_count window_count existing total
    # Pending mutation recovery does not replay DELETE/POST.
    while IFS= read -r action; do
        policy_finish_tracking "$action" || log 'WARNING: Policy checkpoint remains pending; payload protected'
    done < <(jq -c '.actions[] | select(.status!="done")' "$POLICY_STATE_FILE")
    while IFS= read -r action; do
        runtime_budget_allows_optional_phase policy-replacement-followup || break
        policy_check_replacement "$action" || log 'WARNING: Replacement follow-up unavailable; import not inferred'
    done < <(jq -c --argjson now "$START_TIME" '[.actions[] | select(.status=="done" and .mode=="replace" and
      (.replacementState // "")!="import_verified" and $now >= (.replacementCheckedAt // 0)+3600)] |
      sort_by(.replacementCheckedAt // 0) | .[:4][]' "$POLICY_STATE_FILE")
    # Any ambiguous previous mutation blocks NEW actions globally.
    if jq -e 'any(.actions[]; .status!="done")' "$POLICY_STATE_FILE" >/dev/null; then
        policy_report_actions; return 0
    fi
    if [ "${ARR_AUTOMATION_ENABLED:-true}" != true ] || [ "${AUTOMATION_CONTROLS_OK:-true}" != true ]; then policy_report_actions; return 0; fi
    if [ -f "${AUTOMATION_STATE_FILE:-}" ] && ! automation_window_open; then policy_report_actions; return 0; fi
    total=$(jq -s '[.[].records[]? | select(any(.statusMessages[]?.messages[]?; test("custom format|not an upgrade|not a quality revision";"i")))]|length' "$SONARR_QUEUE" "$RADARR_QUEUE")
    if (( total>POLICY_BURST_LIMIT )); then
        record_normalized_issue POLICY:burst Monitor 'Policy automation held' ARR_POLICY_AUTOMATION WARNING burst \
          'Too many simultaneous policy failures; possible profile change' 0 "$total candidates exceed limit $POLICY_BURST_LIMIT. All downloads preserved; inspect Recyclarr/profile changes."
        policy_report_actions; return 0
    fi
    for app in Sonarr Radarr; do
        monitor_mutation_gate "$app" || continue
        case "$app" in Sonarr) queue="$SONARR_QUEUE";; Radarr) queue="$RADARR_QUEUE";; esac
        while IFS= read -r item; do
            runtime_budget_allows_optional_phase policy-remediation || break
            id=$(jq -r '.downloadId // "" | ascii_downcase' <<<"$item"); [ -n "$id" ] || continue
            jq -e --arg id "$id" '.actions[$id]!=null' "$POLICY_STATE_FILE" >/dev/null && continue
            # One exact queue row per download across BOTH apps; packs vetoed.
            existing=$(jq -s --arg id "$id" '[.[].records[]? | select((.downloadId // ""|ascii_downcase)==$id)] | length' "$SONARR_QUEUE" "$RADARR_QUEUE")
            [ "$existing" = 1 ] || continue
            policy_build_candidate "$app" "$item" "$TMP_DIR/policy-candidate.json" || continue
            mode=$(jq -r '.mode' "$TMP_DIR/policy-candidate.json")
            fingerprint=$(jq -Sc 'del(.parent.statistics,.parent.nextAiring,.parent.previousAiring,.target.statistics,.queue.estimatedCompletionTime,.queue.timeleft)' "$TMP_DIR/policy-candidate.json" | sha256sum | awk '{print $1}')
            policy_observe "$id" "$fingerprint" || continue
            if [ -f "${AUTOMATION_STATE_FILE:-}" ]; then automation_action_budget || break; fi
            (( count<POLICY_MAX_ACTIONS_PER_RUN )) || break
            daily=$(jq --argjson since "$((START_TIME-86400))" '[.actions[]|select(.startedAt>=$since)]|length' "$POLICY_STATE_FILE")
            (( daily<POLICY_MAX_ACTIONS_PER_DAY )) || break
            if [ "$mode" = replace ]; then
                target_count=$(jq --slurpfile c "$TMP_DIR/policy-candidate.json" --argjson since "$((START_TIME-7*86400))" '[.actions[]|select(.app==$c[0].app and .targetId==$c[0].targetId and .mode=="replace" and .startedAt>=$since)]|length' "$POLICY_STATE_FILE")
                window_count=$(jq --slurpfile c "$TMP_DIR/policy-candidate.json" --argjson since "$((START_TIME-30*86400))" '[.actions[]|select(.app==$c[0].app and .targetId==$c[0].targetId and .mode=="replace" and .startedAt>=$since)]|length' "$POLICY_STATE_FILE")
                (( target_count==0 && window_count<3 )) || continue
            fi
            # Re-fetch complete queue and all identity/profile/file/history
            # evidence immediately before recording intent and removing tracking.
            IFS=$'\t' read -r root key < <(arr_reconciliation_connection "$app")
            fetch_arr_queue "$app" "$root" "$key" "$TMP_DIR/policy-fresh-queue.json" || continue
            item=$(jq -c --arg id "$id" '[.records[] | select(((.downloadId // "")|ascii_downcase)==$id)] | select(length==1) | .[0]' "$TMP_DIR/policy-fresh-queue.json")
            [ -n "$item" ] || continue
            policy_build_candidate "$app" "$item" "$TMP_DIR/policy-fresh-candidate.json" || continue
            [ "$fingerprint" = "$(jq -Sc 'del(.parent.statistics,.parent.nextAiring,.parent.previousAiring,.target.statistics,.queue.estimatedCompletionTime,.queue.timeleft)' "$TMP_DIR/policy-fresh-candidate.json" | sha256sum | awk '{print $1}')" ] || continue
            usr_ops_arr_reserve "policy:$id" "$app" "$(jq -r '.targetId' "$TMP_DIR/policy-candidate.json")" || { printf '%s\n' "$app: shared media action budget deferred rejection; queue unchanged" >>"$TMP_DIR/automation-deferrals.txt";continue; }
            local tmp="${POLICY_STATE_FILE}.tmp.$$" queue_id blocklist=false
            jq --slurpfile c "$TMP_DIR/policy-candidate.json" --arg id "$id" --argjson now "$START_TIME" '.actions[$id]=$c[0]+{status:"intent",startedAt:$now}' "$POLICY_STATE_FILE" >"$tmp" && policy_publish "$tmp" "$POLICY_STATE_FILE" || return 1
            queue_id=$(jq -r '.queueId' "$TMP_DIR/policy-candidate.json")
            [ "$mode" != replace ] || blocklist=true
            ((count++)) || true
            # removeFromClient=false preserves SAB data. skipRedownload=true
            # prevents native redownload competing with our single command.
            local mutation_rc=0
            policy_mutate DELETE "$root/queue/$queue_id?removeFromClient=false&blocklist=$blocklist&skipRedownload=true&changeCategory=false" "$key" '' "$TMP_DIR/policy-delete-response" || mutation_rc=$?
            if ((mutation_rc==75));then
                usr_ops_arr_release_undispatched "policy:$id" || true
                jq --arg id "$id" '.deferred //= {} | .deferred[$id]=(.actions[$id]+{outcome:"not_dispatched"}) | del(.actions[$id])' "$POLICY_STATE_FILE" >"$tmp" && policy_publish "$tmp" "$POLICY_STATE_FILE" || return 1
                printf '%s\n' "$app: policy rejection deferred before HTTP; SAB and Arr queue untouched" >>"$TMP_DIR/automation-deferrals.txt"
                continue
            fi
            action=$(jq -c --arg id "$id" '.actions[$id]' "$POLICY_STATE_FILE")
            policy_finish_tracking "$action" || { policy_report_actions; return 0; }
        done < <(jq -c '.records[]? | select(any(.statusMessages[]?.messages[]?; test("custom format|not an upgrade|not a quality revision";"i")))' "$queue")
    done
    local qtmp="$TMP_DIR/policy-filtered-queue.json"
    for queue in "$SONARR_QUEUE" "$RADARR_QUEUE"; do
        jq --slurpfile p "$POLICY_STATE_FILE" '.records |= map(select($p[0].actions[((.downloadId // "")|ascii_downcase)].status!="done")) | .totalRecords=(.records|length)' "$queue" >"$qtmp" && mv "$qtmp" "$queue" || return 1
    done
    policy_report_actions
}

# /bin/bash SCRIPT --automation-status: read-only action/hold/search baseline summary.
if [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" == --automation-status ]]; then
    if [ -f "$STATE_DIR/automation-actions.json" ]; then
        jq '{profiles,missing:(.missing|with_entries(.value |= {baselineAt,baselineCount:(.baselineIds|length),surveyedAt,window,cursor,selectedIds:[.selected[]?.id]})),
          retryExhaustions:([(.retryExhaustions // {})[]]|sort_by(.checkedAt)|reverse|.[:50]),
          actionCount:(.actions|length),recentActions:([.actions[]|{app,kind,packId,targetId,downloadId,status,outcome,commandId,startedAt}]|sort_by(.startedAt)|reverse|.[:50])}' "$STATE_DIR/automation-actions.json"
    else printf 'No automation state recorded.\n'; fi
    if [[ -f "$STATE_DIR/pack-actions.json" ]];then jq '{packs:[.jobs[]|{downloadId,title,status,reason,createdAt,queueIntentAt,queueVerifiedAt,proofs,cleanup}]}' "$STATE_DIR/pack-actions.json";fi
    exit $?
fi

# Policy action inventory:
# /bin/bash /boot/config/plugins/user.scripts/scripts/media_health_monitor/script --policy-actions
# Columns: app, download ID, action, checkpoint, target ID, replacement state,
# workflow, cleanup status, blocker/reason, original path and quarantine path.
# This reads saved receipts only; it does not contact Arr or submit any action.
# "intent" or "search_uncertain" means a request may have succeeded before a
# timeout; do not delete the journal or retry it manually without reviewing Arr.
# Scheduled scans re-read native outcomes and resume verified next steps only.
# POLICY_AUTOMATION_ENABLED=false pauses new actions and keeps monitoring.
if [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" == --policy-actions ]]; then
    if [ -f "$STATE_DIR/policy-actions.json" ]; then
        jq -r '.actions[] | [.app,.downloadId,.mode,.status,.targetId,(.replacementState // "not verified"),(.workflow // "pending"),(.cleanup.status // "pending"),(.cleanup.reason // "Awaiting cleanup acknowledgement"),(.cleanup.sourcePath // ""),(.cleanup.quarantinePath // "")] | @tsv' "$STATE_DIR/policy-actions.json"
    else
        printf 'No policy actions recorded.\n'
    fi
    exit $?
fi

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
require_command timeout
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
# APPDATA BACKUP COORDINATION
# Normal scans hold a shared gate through notification/automation. Backup waits
# before stopping containers. Deferred scans preserve issue state and do not
# resolve issues, send reminders, poll APIs, or submit recovery commands.
# CLI state administration remains available during a backup.
###############################################################################
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

# Read-only checks continue during global mutation deferral. This evidence is
# separate from pipeline issues: no imports, reconciliation or action is run.
monitor_maintenance_availability() {
    local app url container key result ready expected pid boot lease data='[]' tmp now
    now=$(date +%s);boot=$(cat /proc/sys/kernel/random/boot_id)
    for app in Sonarr Radarr SABnzbd;do
        case "$app" in Sonarr) container=sonarr;url="$SONARR_URL";key='';;Radarr) container=radarr;url="$RADARR_URL";key='';;*) container=sabnzbd;url="$SAB_URL";key="$SAB_API_KEY";;esac
        expected=false
        for lease in "${DOCKER_MAINTENANCE_DIR:-/run/docker-service-maintenance}/$container."*.json;do
            [[ -f "$lease" && ! -L "$lease" ]] || continue
            if jq -e --arg boot "$boot" --argjson now "$now" '.boot==$boot and (.expires|type)=="number" and .expires>$now and .expires<=$now+86400 and (.pid|type)=="number" and .pid>=0' "$lease" >/dev/null 2>&1;then
                pid=$(jq -r '.pid // 0' "$lease")
                if ((pid==0));then expected=true
                elif kill -0 "$pid" 2>/dev/null && [[ $(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null|awk '{print $20}') == $(jq -r '.processStart // ""' "$lease") ]];then expected=true;fi
            fi
        done
        local started_epoch started_value
        started_value=$(timeout --kill-after=2 3 docker inspect --format '{{.State.StartedAt}}' "$container" 2>/dev/null) || started_value=''
        started_epoch=0
        [[ -z "$started_value" ]] || started_epoch=$(date -d "$started_value" +%s 2>/dev/null) || started_epoch=0
        if ((started_epoch>0 && started_epoch<=now && now-started_epoch<120));then expected=true;fi
        ready=false;result=''
        if [[ "$app" == SABnzbd ]];then
            result=$(printf 'url = "%s/api"\nget\ndata-urlencode = "mode=version"\ndata-urlencode = "output=json"\ndata-urlencode = "apikey=%s"\n' "${url%/}" "$key" | curl --config - --noproxy '*' --silent --fail --connect-timeout 2 --max-time 4 --max-filesize 65536 2>/dev/null) || result='{}'
            jq -e '.version|type=="string" and length>0' <<<"$result" >/dev/null 2>&1 && ready=true
        else
            result=$(curl --noproxy '*' --silent --fail --connect-timeout 2 --max-time 4 --max-filesize 65536 "${url%/}/ping" 2>/dev/null) || result='{}'
            jq -e '.status=="OK"' <<<"$result" >/dev/null 2>&1 && ready=true
        fi
        data=$(jq -nc --argjson data "$data" --arg app "$app" --argjson ready "$ready" --argjson expected "$expected" '$data+[{app:$app,ready:$ready,expectedMaintenance:$expected}]')
    done
    tmp=$(mktemp "$STATE_DIR/.maintenance-availability.XXXXXX") || return 1
    jq -n --argjson at "$now" --argjson services "$data" --argjson since "$(cat "${ARR_BACKUP_DEFERRED_AT:-/run/media-health-monitor-backup-deferred-at}" 2>/dev/null || printf '%s' "$now")" '{schema:2,epoch:$at,deferredSince:$since,deferredSeconds:($at-$since),mode:"read_only_maintenance",actions:"Pipeline mutations and issue resolution deferred; service availability checked independently",services:$services}' >"$tmp" && mv "$tmp" "$STATE_DIR/maintenance-availability.json"
}

ARR_BACKUP_GATE="${ARR_BACKUP_GATE:-/run/arr-appdata-coordination.lock}"
ARR_BACKUP_GRACE="${ARR_BACKUP_GRACE:-/run/arr-appdata-recovery-until}"
ARR_BACKUP_DEFERRED_AT="${ARR_BACKUP_DEFERRED_AT:-/run/media-health-monitor-backup-deferred-at}"
if [[ $# == 0 ]]; then
    exec {ARR_BACKUP_GATE_FD}>"$ARR_BACKUP_GATE" || exit 3
    arr_backup_deferred=false
    flock -s -n "$ARR_BACKUP_GATE_FD" || arr_backup_deferred=true
    app_update_requested arr && arr_backup_deferred=true
    arr_grace_until=$(cat "$ARR_BACKUP_GRACE" 2>/dev/null || true)
    arr_gate_now=$(date +%s)
    if [[ "$arr_grace_until" =~ ^[0-9]+$ ]] &&
       (( arr_grace_until > arr_gate_now && arr_grace_until <= arr_gate_now + 120 )); then
        arr_backup_deferred=true
    fi
    if [[ "$arr_backup_deferred" == true ]]; then
        [[ -s "$ARR_BACKUP_DEFERRED_AT" ]] || printf '%s\n' "$START_TIME" >"$ARR_BACKUP_DEFERRED_AT"
        monitor_maintenance_availability || log "WARNING: Read-only maintenance availability evidence could not be saved"
        log "MAINTENANCE: Pipeline actions deferred for $((arr_gate_now-$(cat "$ARR_BACKUP_DEFERRED_AT")))s; bounded read-only service probes recorded separately; existing issues preserved"
        exit 0
    fi
fi

###############################################################################
# TEMP DIRECTORY
###############################################################################

TMP_DIR=$(mktemp -d /tmp/media_health_monitor.XXXXXX) || {
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

exec {STATE_EXPORT_FD}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || exit 3
if ! flock -s -n "$STATE_EXPORT_FD"; then
    log "MAINTENANCE: operational-state export active; scan deferred without observations or actions"
    exit 0
fi
ensure_state_storage_ready

initialize_state

if ! begin_state_transaction; then
    log "ERROR: Unable to begin monitor state transaction"
    exit 3
fi

MONITOR_STATE_LEASE_HELD=true

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
    *)
        if (( $#>0 ));then printf 'Unknown command: %s; use --help\n' "$1" >&2;exit 2;fi
        ;;
esac

if [[ -r "${UNRAID_VERSION_FILE:-/etc/unraid-version}" ]]; then
    arr_platform_version=$(sed -n 's/^version="\([^"]*\)"/\1/p' "${UNRAID_VERSION_FILE:-/etc/unraid-version}")
    if [[ "$arr_platform_version" != 7.* ]]; then
        ARR_AUTOMATION_ENABLED=false; POLICY_AUTOMATION_ENABLED=false
        log 'COMPATIBILITY: unvalidated Unraid major; new Arr mutations disabled; monitoring and read-only reconciliation continue'
    fi
fi
start_monitor_phase "startup"

if ! begin_monitor_run; then
    log "ERROR: Unable to update monitor run-start heartbeat"
    persistent_log "ERROR" "Unable to update monitor run-start heartbeat"
    exit 3
fi

monitor_outbox_prepare || exit 3
USR_OPS_SHARED_BUDGET_ACTIVE=true
MONITOR_COORDINATION_ACTIVE=true
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
    "START | Media Health Monitor v3.28.0"

if [ "$ACTIVITY_AUDIT_ENABLED" = true ]; then

    initialize_activity_audit_window

    debug_log "Activity audit window: last ${ACTIVITY_AUDIT_LOOKBACK_HOURS}h"
fi

###############################################################################
# START
###############################################################################

debug_log "Starting Media Health Monitor v3.28.0"
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

start_monitor_phase "automation-controls"
automation_prepare || log 'WARNING: Automation controls unavailable; new actions held'
end_monitor_phase "automation-controls"

if runtime_budget_allows_optional_phase "policy-remediation"; then
    start_monitor_phase "policy-remediation"
    process_policy_remediation || log "WARNING: Policy automation stopped; review grouped report and journal"
    end_monitor_phase "policy-remediation"
fi
if runtime_budget_allows_optional_phase "media-packs";then
    process_media_packs || { log 'WARNING: Pack evidence incomplete; existing files and journals preserved';preserve_pack_issues; }
else preserve_pack_issues;fi
monitor_release_mutation_gates

if runtime_budget_allows_optional_phase "arr-automation"; then
    start_monitor_phase "arr-automation"
    process_media_integrity_recovery || log 'WARNING: Media integrity recovery executor unavailable'
    [[ "$MONITOR_EXPORT_LEASE_LOST" != true ]] || exit 75
    process_arr_automation || log 'WARNING: Arr automation deferred or awaits verification'
    end_monitor_phase "arr-automation"
fi

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

if runtime_budget_allows_optional_phase "import-receipts"; then
    start_monitor_phase "import-receipts"
    capture_durable_import_receipts || log 'WARNING: Durable import receipt capture stopped; prior proof preserved'
    end_monitor_phase "import-receipts"
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
       [ "$SONARR_QUEUE_OK" = true ] && [ "$RADARR_QUEUE_OK" = true ] &&
       [ -z "$(jq -r '.monitor.sabFilesystemCursor // ""' "$STATE_FILE")" ]; then
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
if [[ -e "$STATE_DIR/action-budget.json" ]] && { [[ -L "$STATE_DIR/action-budget.json" ]] || ! jq -e '.schema==1 and (.actions|type)=="object"' "$STATE_DIR/action-budget.json" >/dev/null 2>&1; };then
    record_normalized_issue 'Monitor:shared-media-budget' Monitor 'Shared media action budget invalid' MONITOR_STATE_INVALID ERROR control-plane \
      'New automated actions deferred because the shared action ledger is invalid' 0 \
      'Existing intent journals and media were preserved. Restore a verified action-budget.json or repair its structure; do not clear uncertain native actions.'
fi
monitor_persist_coverage || exit 3
monitor_report_stale_coverage
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
monitor_release_mutation_gates
monitor_persist_coverage || exit 3
send_grouped_notification
NOTIFICATION_SEND_RC=$?
[[ "$MONITOR_EXPORT_LEASE_LOST" != true ]] || exit 75

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

# Presentation separates retained historical evidence from current workflow errors.
# Historical records keep their IDs/lifecycle and are not silently resolved here.
health_presentation=$(mktemp "$STATE_DIR/.health-presentation.XXXXXX") || exit 3
jq -n --arg status "$PIPELINE_STATUS" --arg reason "$PIPELINE_REASON" --argjson at "$(date +%s)" --argjson live "$PIPELINE_LIVE_ERROR_COUNT" --argjson history "$EVENT_ONLY_ERROR_COUNT" --argjson warnings "$WARNING_COUNT" '{schema:1,epoch:$at,status:$status,reason:$reason,currentWorkflowErrors:$live,historicalEventErrors:$history,warningsAndReview:$warnings,scope:"Historical events remain review evidence; currentWorkflowErrors excludes event-only errors"}' >"$health_presentation" && mv "$health_presentation" "$STATE_DIR/health-presentation.json" || exit 3
if [[ -s "$ARR_BACKUP_DEFERRED_AT" ]];then
    deferred_since=$(cat "$ARR_BACKUP_DEFERRED_AT")
    if [[ "$deferred_since" =~ ^[0-9]+$ ]];then
        log "MAINTENANCE: Full monitoring resumed after $((START_TIME-deferred_since))s; deferred issues were preserved and are now rechecked"
        maintenance_resume=$(mktemp "$STATE_DIR/.maintenance-resume.XXXXXX") || exit 3
        jq -n --argjson since "$deferred_since" --argjson resumed "$START_TIME" '{schema:1,deferredSince:$since,resumedAt:$resumed,deferredSeconds:($resumed-$since),mode:"full_monitoring_resumed"}' >"$maintenance_resume" && mv "$maintenance_resume" "$STATE_DIR/maintenance-resume.json" || exit 3
        rm -f "$ARR_BACKUP_DEFERRED_AT"
    fi
fi
log "HEALTH PRESENTATION: current workflow errors=$PIPELINE_LIVE_ERROR_COUNT; retained historical event errors=$EVENT_ONLY_ERROR_COUNT; warnings/review=$WARNING_COUNT"

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
log "Media Health Monitor v3.28.0 completed"
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

monitor_persist_coverage || exit 3
if ! complete_monitor_run "$PIPELINE_STATUS" 0 ""; then
    log "ERROR: Unable to update monitor completion heartbeat"
    persistent_log "ERROR" "Unable to update monitor completion heartbeat"
    exit 3
fi

commit_state_transaction "run-complete" || exit 3
MONITOR_RUN_FINALIZED=true
MONITOR_RUN_ACTIVE=false

exit 0
