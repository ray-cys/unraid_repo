#!/bin/bash
#clearLog=true
# shellcheck disable=SC2034,SC2155
# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="health_monitoring"
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
# BEGIN SCHEDULED EXECUTION SUPERVISOR
if [[ "${BASH_SOURCE[0]}" == "$0" && $# == 0 && "${USR_OPS_SUPERVISED:-}" != "$OPS_SCRIPT_ID" ]];then
    usr_ops_supervise "$0";exit $?
fi
# END SCHEDULED EXECUTION SUPERVISOR
set -uo pipefail
umask 077

readonly SCRIPT_VERSION="3.0.1"
readonly TRUSTED_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
PATH="$TRUSTED_PATH"
export PATH

if (( BASH_VERSINFO[0] < 4 )); then
    printf 'health_monitoring.sh requires Bash 4 or newer (found %s).\n' \
        "${BASH_VERSION:-unknown}" >&2
    exit 2
fi

# Disk Health Monitor for Unraid v2.22.0
# Purpose: Monitor Unraid disk, filesystem, capacity and parity health with grouped
# actionable alerts, stable device identities and conservative recovery evidence.
# v3.0.0: documented host-write units, calendar SMART scheduling, asynchronous
# tests, maintenance gates, observed scrub dates, and syslog-watchdog delegation.
# Removed speculative risk/lifetime forecasts, soak readiness and XFS workload alerts.
# Native SMART failures, pending/uncorrectable sectors, temperature, NVMe faults,
# rated TBW, filesystem errors, parity results and stale SMART coverage remain active.
# Sleeping disks stay asleep; deferred collection never proves recovery. Only a
# successful fresh scan advances relevant baselines. Healthy runs remain quiet.
# Self-tests are started only on eligible awake disks outside backup/parity/Mover/
# scrub work. At most one new long test starts per run; results are collected later.
# Native Unraid scheduling owns Btrfs scrubs; this monitor never starts a scrub.
# State: existing schema remains compatible. ATA write-history is rebaselined once
# per stable identity when unit revision changes; physical fault counters are kept.
# Legacy analytic files are left for rollback but no longer written or recreated.
# Use --help for supported read-only diagnostics and state administration commands.
# No Docker image, startup or application configuration is modified.

load_builtin_defaults() {

# === SMART Test Scheduling ===
SHORT_TEST_INTERVAL_DAYS=7                      # Run automatic short tests no more often than this (0=disable)
SMART_ALLOW_SPINUP=0                            # Allow SMART collection/tests to wake standby SATA HDDs (0=defer)
LONG_TEST_MAX_INTERVAL_DAYS=120                 # Powered-on days between routine long tests
LONG_TEST_CRITICAL_MIN_DAYS=7                   # Critical SMART & last long age >= days -> force long
LONG_TEST_DECISION=""                           # Accumulator for long test scheduling decisions
LONG_TEST_NEAR_WINDOW_DAYS=5                    # Show health alert when long test is due within N days
LONG_TEST_INITIAL_FORCE=0                       # When no prior long test record, force an immediate long (1=enable, 0=skip)

# === Capacity Thresholds ===
WARN_THRESHOLD_PERCENT=96                       # Per-disk usage percent -> warning
CRITICAL_THRESHOLD_PERCENT=98                   # Per-disk usage percent -> critical
THRESHOLD=90                                    # Array/pools overall usage percent considered full
NEAR_THRESHOLD_DELTA=5                          # "Near full" if within this percent of THRESHOLD
POOL_EXCLUDES=("ramtmp" "user0")                # Pool names excluded from pool totals

# === Storage Validation / Discrepancy Alerts ===

# === Filesystem / Device Monitoring Toggles ===
BTRFS_SCRUB_STATE_TTL_DAYS=90                   # Days to retain scrub state files
ENABLE_BTRFS_DEVICE_STATS=1                     # Parse btrfs per-device stats and integrate (0=disable)
IO_ERROR_LOG_FILE="/var/log/syslog"             # Syslog path fallback to dmesg
IO_ERROR_WINDOW_MINUTES=60                      # Time window (minutes) for de-dup/frequency
IO_ERROR_WARN_THRESHOLD=5                       # Unique error events >= warning
IO_ERROR_CRIT_THRESHOLD=20                      # Unique error events >= critical
SYSLOG_CURSOR_STARTUP_LOOKBACK_LINES=100         # First cursor run: inspect only the most recent N lines
SYSLOG_CURSOR_ROTATION_LOOKBACK_LINES=2000       # Recovery scan when the previous rotated file cannot be found
SYSLOG_FAST_STORAGE_OWNER=1                      # Hubble's five-minute syslog watcher owns individual urgent events
SYSLOG_FAST_HEARTBEAT="/tmp/syslog_watchdog_state/storage-watch.epoch"

# === Trends & Alerts: Toggles ===
NVME_WEAR_REGRESSION_WARN=1                     # Flag any NVMe Percentage Used regression (0=disable)
SATA_LINK_INSTABILITY_ENABLED=1                 # Enable SATA link instability frequency tracking (0=disable)
TEMP_RATE_ALERT_ENABLED=1                       # Enable temperature change rate alerts (0=disable)
IO_ERROR_MONITOR_ENABLED=1                      # Enable syslog scanning for disk I/O frequency (0=disable)
IO_ERROR_DEDUP_ENABLED=1                        # De-duplicate identical message hashes inside window (0=disable)

# === SMART / Endurance / Trend Parameters ===
PARITY_SYNC_ERR_WARN=1                          # Parity sync errors threshold for warning alert
PARITY_SYNC_ERR_CRIT=10                         # Parity sync errors threshold for critical alert
POH_RESET_CRIT_THRESHOLD=500                    # POH drop > threshold -> critical reset event
SATA_LINK_INSTABILITY_WINDOW_DAYS=14            # Days window for link instability analysis
SATA_LINK_INSTABILITY_STREAK_WARN=2             # Consecutive days with downshift events -> warning
SATA_LINK_INSTABILITY_STREAK_CRIT=5             # Consecutive days with downshift events -> critical

# === Export / History / Logging ===
HISTORY_WINDOW_DAYS=14                          # Days considered for usage growth trends
FORECAST_MIN_SAMPLES=3                         # Minimum distinct daily samples for an actionable forecast
FORECAST_MIN_SPAN_DAYS=2                       # Minimum elapsed days for an actionable forecast
FORECAST_HIGH_SAMPLES=7                        # Samples required for HIGH confidence
FORECAST_HIGH_SPAN_DAYS=7                      # Elapsed days required for HIGH confidence
FORECAST_STALE_AFTER_DAYS=3                    # Latest sample older than this is marked STALE
FORECAST_MAX_GAP_DAYS=14                       # Histories with a larger internal gap are LOW confidence
LOG_PRUNE_ENABLED=1                             # Prune old run logs in LOG_DIR
LOG_MAX_DAYS=0                                  # Age pruning days (0=disable)
LOG_MAX_COUNT=3                                 # Max retained logs per pattern (0=disable)
HISTORY_PRUNE_ENABLED=1                         # Enable auto-prune of history files (0=disable)
HISTORY_MAX_DAYS=180                            # Remove lines older than this many days (0=disable age pruning)
HISTORY_MAX_LINES=20000                         # Keep at most this many recent lines per history file (0=disable line pruning)
LOG_MIRROR_STDOUT=1                             # Mirror log lines to the User Scripts console

# === Risk / Lifecycle Settings ===

# === Display / Notification Preferences ===
NOTIFY_MAX_BODY_CHARS=12000                     # Maximum notification body length before safe truncation
NOTIFY_MAX_BODY_LINES=180                       # Maximum notification body lines before safe truncation
LOG_FULL_NOTIFICATION_ON_TRUNCATION=1           # Preserve the complete body in the run log when shortened
NOTIFICATION_LIFECYCLE_ENABLED=1                # Notify on changes/recovery and use reminder cooldowns (0=every run)
NOTIFICATION_WARNING_REMINDER_HOURS=24          # Repeat unchanged warnings after this interval (0=disable)
NOTIFICATION_CRITICAL_REMINDER_HOURS=6          # Repeat unchanged critical alerts after this interval (0=disable)
NOTIFICATION_OK_REMINDER_HOURS=0                # Unchanged all-clears are opt-in (0=disable)
NOTIFICATION_RECOVERY_CONFIRM_RUNS=2            # Consecutive collector-safe runs required before reporting recovery
NOTIFICATION_MAX_ATTEMPTS=3                     # Total Unraid notification delivery attempts
NOTIFICATION_RETRY_INITIAL_DELAY_SECONDS=2      # Initial retry delay; doubles after each failed attempt
NOTIFICATION_RETRY_MAX_DELAY_SECONDS=30         # Maximum delay between notification attempts
NOTIFICATION_DRY_RUN=0                          # Build/log decision but do not deliver or advance notification journal

# === Execution Safety / Collector Isolation ===
SMARTCTL_TIMEOUT_SECONDS=45                     # Maximum wall time for one smartctl command
BTRFS_COMMAND_TIMEOUT_SECONDS=60                # Maximum wall time for one btrfs command
SYSTEM_COMMAND_TIMEOUT_SECONDS=30               # Maximum wall time for df/findmnt/dmesg commands
NOTIFICATION_TIMEOUT_SECONDS=30                 # Maximum wall time for notify/logger delivery
COMMAND_KILL_GRACE_SECONDS=5                    # Grace period before forcibly killing a timed-out command
COLLECTOR_SLOW_SECONDS=300                      # Log a collector as slow after this duration (0=disable)
COLLECTOR_FAILURE_NOTIFICATIONS=1               # Add a warning finding when a collector times out/fails

# === Phase 15 Soak Evidence ===

# === Paths / Integration ===
LOG_DIR="/mnt/vault/cloud/logs/script/health_monitoring" # Deployed run logs and persistent state
LOCK_FILE="/run/health_monitoring.lock"          # Root-controlled non-blocking single-instance lock
NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"

# === Temperature Trend / Rate Thresholds (Global) ===
TEMP_RATE_WARN_C_PER_DAY=4.0                    # Avg rise °C/day >= warning threshold (global)
TEMP_RATE_MIN_SPAN_DAYS=1.0                     # Minimum span days required to evaluate rate (global)

# === SMART Thresholds (SATA) ===
RELOC_WARNING=1                                 # Reallocated sectors >= warning
RELOC_CRITICAL=10                               # Reallocated sectors >= critical
PEND_WARNING=1                                  # Pending sectors >= critical
SSD_TEMP_WARNING=65                             # SATA SSD temp C >= warning
SSD_TEMP_CRITICAL=70                            # SATA SSD temp C >= critical
HDD_TEMP_WARNING=55                             # HDD temp C >= warning
HDD_TEMP_CRITICAL=60                            # HDD temp C >= critical
LOAD_CYCLE_WARN=300000                          # HDD load cycle count >= warning
LOAD_CYCLE_CRIT=600000                          # HDD load cycle count >= critical
REPORTED_UNC_CRIT=1                             # SATA attr 187 any >0 critical
CMD_TIMEOUT_WARN=5                              # SATA attr 188 >= warning
CMD_TIMEOUT_CRIT=50                             # SATA attr 188 >= critical
CMD_TIMEOUT_DELTA_WARN=5                        # Increase in attr 188 between runs >= triggers rate alert (0=disable)
CMD_TIMEOUT_COOLDOWN_DAYS=2                     # Suppress repeated delta alerts for N days (0=disable)
REALLOC_EVENT_WARN=1                            # SATA attr 196 >= warning
REALLOC_EVENT_CRIT=10                           # SATA attr 196 >= critical
END_TO_END_ERR_CRIT=1                           # SATA attr 184 any >0 critical
SOFT_READ_ERR_WARN=1000                         # SATA attr 201 >= warning (heuristic)

# === SMART Thresholds (NVMe) ===
NVME_TEMP_WARNING=70                             # NVMe temp C >= warning
NVME_TEMP_CRITICAL=80                            # NVMe temp C >= critical
NVME_PERCENT_USED_WARN=80                        # NVMe wear percent >= warning
NVME_PERCENT_USED_CRIT=90                        # NVMe wear percent >= critical
WEAR_TREND_ENABLED=1                             # Retain measured NVMe wear history
HEAVY_WRITER_RECENT_DAYS=3                       # Recent window used for workload intensity and improvement tracking
HEAVY_WRITER_MIN_RECENT_SAMPLES=2                # Minimum recent counter samples required before using the recent rate
HEAVY_WRITER_IMPROVEMENT_PCT=20                  # Recent rate change needed to label improving or rising
UNSAFE_SDWN_DELTA_WARN=5                         # Unsafe shutdowns delta >= warning (M)
UNSAFE_SDWN_ABSOLUTE_MIN=100                     # Only warn if total unsafe shutdowns >= N (0=disable)
UNSAFE_SDWN_COOLDOWN_DAYS=3                      # Suppress repeat warnings for X days after one triggers (0=disable)
NVME_AVAIL_SPARE_WARN=5                          # Available Spare (%) below -> warning
NVME_ERR_LOG_DELTA_WARN=1                        # NVMe Error Information Log Entries delta >= warn
NVME_ERR_LOG_DELTA_CRIT=10                       # NVMe Error Information Log Entries delta >= critical
NVME_PCIE_CORR_DELTA_WARN=1                      # NVMe PCIe Correctable Error Count delta >= warn
NVME_PCIE_CORR_DELTA_CRIT=50                     # NVMe PCIe Correctable Error Count delta >= critical
NVME_PCIE_UNC_DELTA_WARN=1                       # NVMe PCIe Uncorrectable Error Count delta >= warn (usually critical on any)
NVME_PCIE_UNC_DELTA_CRIT=1                       # NVMe PCIe Uncorrectable Error Count delta >= critical (any increase)
NVME_THERM_T1_DELTA_WARN=1                       # NVMe Thermal Management T1 Transitions delta >= warn
NVME_THERM_T2_DELTA_WARN=1                       # NVMe Thermal Management T2 Transitions delta >= warn (treat as critical if >=1)
NVME_WARN_TEMP_TIME_DELTA_WARN=300               # NVMe Warning Comp. Temperature Time delta (seconds) >= warn
NVME_CRIT_TEMP_TIME_DELTA_WARN=60                # NVMe Critical Comp. Temperature Time delta (seconds) >= warn (usually critical if >0)

# === Btrfs / XFS Snapshot & Device Thresholds ===
BTRFS_DEV_ERR_WARN_DELTA=1                       # Per-device read/write/flush err delta >= warning
BTRFS_DEV_ERR_CRIT_DELTA=10                      # Per-device read/write/flush err delta >= critical
BTRFS_DEV_CORR_WARN_DELTA=1                      # Per-device corruption/gen err delta >= warning
BTRFS_DEV_CORR_CRIT_DELTA=1                      # Per-device corruption/gen err delta >= critical
BTRFS_ERR_BURST_WARN_RATIO=5                     # Btrfs device error delta / previous delta >= warn ratio
BTRFS_ERR_BURST_CRIT_RATIO=10                    # Btrfs device error delta / previous delta >= critical ratio
BURST_WARN_BOOST=15                              # Composite SMART boost for warning burst events
BURST_CRIT_BOOST=30                              # Composite SMART boost for critical burst events

# === POH (Power-On Hours) Age Thresholds ===

# === TBW / Endurance Forecast Thresholds ===
TBW_CONSUMED_WARN=80                             # Consumed percent of model TBW >= warning
TBW_CONSUMED_CRIT=95                             # Consumed percent of model TBW >= critical

# === Risk Scoring Weights ===

# === Model-Specific Overrides ===
# Rule format uses ';'-separated key:value pairs per line. Supported keys:
#  - regex: POSIX ERE to match model string (case-insensitive)
#  - cap_min / cap_max: optional decimal TB capacity window (inclusive)
#  - per_tb: TBW endurance per TB of capacity (numeric)
#  - type: nvme | sata-ssd | sata-hdd (for POH overrides)
#  - warn / crit: POH hours thresholds (numeric)
#  - action: for quirks (e.g., invert_mwi_small)
# TBW endurance per TB overrides (model + optional capacity window)
TBW_MODEL_RULES='\
regex:MX500;per_tb:350
regex:WD[[:space:]]+Red.*SA500|WDS500G1R0A;cap_min:0.45;cap_max:0.55;per_tb:700
regex:WD[[:space:]]+Red.*SA500;cap_min:0.95;cap_max:1.05;per_tb:600
regex:Crucial[[:space:]]*T500|CT1000T500SSD[58];cap_min:0.95;cap_max:1.05;per_tb:600
regex:Crucial[[:space:]]*P5(\\+|[[:space:]]*Plus|P5P)|CT1000P5PSSD8;cap_min:0.95;cap_max:1.05;per_tb:600
'
# POH threshold overrides by device type and model
# Parsing/compatibility quirks (e.g., vendor-reported life remaining anomalies)

}

load_builtin_defaults

# Unraid Exclusive Shares expose /mnt/user/<share> as a symbolic link to the
# same share on one physical pool. Resolve only that exact, constrained shape;
# arbitrary redirects, nested links, and mismatched share names remain unsafe.
UNRAID_EXCLUSIVE_PATH_RESULT=""
UNRAID_EXCLUSIVE_PATH_STATUS="UNCHANGED"
UNRAID_EXCLUSIVE_PATH_REASON=""

resolve_unraid_exclusive_share_path() {
    local requested="$1" user_root="${2:-/mnt/user}" mount_root="${3:-/mnt}"
    local relative share suffix source target target_relative pool target_share
    local remainder component current

    UNRAID_EXCLUSIVE_PATH_RESULT="$requested"
    UNRAID_EXCLUSIVE_PATH_STATUS="UNCHANGED"
    UNRAID_EXCLUSIVE_PATH_REASON=""

    [[ "$requested" == "$user_root"/* ]] || return 0
    relative="${requested#"$user_root"/}"
    share="${relative%%/*}"
    suffix=""
    [[ "$relative" == */* ]] && suffix="${relative#*/}"
    if [[ -z "$share" || ! "$share" =~ ^[A-Za-z0-9._-]+$ ||
          "$share" == "." || "$share" == ".." ]]; then
        UNRAID_EXCLUSIVE_PATH_REASON="invalid Unraid share name"
        return 1
    fi

    source="$user_root/$share"
    [[ -L "$source" ]] || return 0
    target=$(readlink -- "$source" 2>/dev/null) || {
        UNRAID_EXCLUSIVE_PATH_REASON="cannot read exclusive-share link $source"
        return 1
    }
    if [[ "$target" != /* || "$target" == *"//"* || "$target" =~ [[:cntrl:]] ]]; then
        UNRAID_EXCLUSIVE_PATH_REASON="exclusive-share link target is not a clean absolute path"
        return 1
    fi
    [[ "$target" == "$mount_root"/* ]] || {
        UNRAID_EXCLUSIVE_PATH_REASON="exclusive-share link leaves $mount_root"
        return 1
    }

    target_relative="${target#"$mount_root"/}"
    pool="${target_relative%%/*}"
    target_share="${target_relative#*/}"
    if [[ -z "$pool" || "$target_relative" == "$pool" ||
          "$target_share" != "$share" || "$target_share" == */* ||
          ! "$pool" =~ ^[A-Za-z0-9._-]+$ ||
          "$pool" == "user" || "$pool" == "user0" ||
          "$pool" =~ ^disk[0-9]+$ ]]; then
        UNRAID_EXCLUSIVE_PATH_REASON="exclusive-share link does not target the same share on one pool"
        return 1
    fi
    if [[ ! -d "$target" || -L "$mount_root" || -L "$mount_root/$pool" ||
          -L "$target" ]]; then
        UNRAID_EXCLUSIVE_PATH_REASON="exclusive-share pool target is missing or contains a symbolic link"
        return 1
    fi

    current="$target"
    remainder="$suffix"
    while [[ -n "$remainder" ]]; do
        component="${remainder%%/*}"
        if [[ -z "$component" || "$component" == "." || "$component" == ".." ]]; then
            UNRAID_EXCLUSIVE_PATH_REASON="exclusive-share suffix contains an unsafe component"
            return 1
        fi
        current+="/$component"
        if [[ -L "$current" ]]; then
            UNRAID_EXCLUSIVE_PATH_REASON="exclusive-share suffix contains symbolic-link component $current"
            return 1
        fi
        [[ "$remainder" == */* ]] || break
        remainder="${remainder#*/}"
    done

    UNRAID_EXCLUSIVE_PATH_RESULT="$target${suffix:+/$suffix}"
    UNRAID_EXCLUSIVE_PATH_STATUS="RESOLVED"
    return 0
}

if ! resolve_unraid_exclusive_share_path "$LOG_DIR"; then
    printf '%s [PATH][ERROR] Unsafe Unraid exclusive-share log path %s: %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$LOG_DIR" \
        "$UNRAID_EXCLUSIVE_PATH_REASON" >&2
    exit 2
fi
if [[ "$UNRAID_EXCLUSIVE_PATH_STATUS" == "RESOLVED" ]]; then
    LOG_DIR="$UNRAID_EXCLUSIVE_PATH_RESULT"
fi

# Derive the allowlist directly from assignments in load_builtin_defaults().
# This avoids a second setting list and remains stable even if the caller's
# environment already contains a variable with the same name as a setting.
declare -a EXTERNAL_CONFIG_KEYS=()
declare -A EXTERNAL_CONFIG_ALLOWED=()
while IFS= read -r _variable_name; do
    EXTERNAL_CONFIG_KEYS+=("$_variable_name")
    EXTERNAL_CONFIG_ALLOWED[$_variable_name]=1
done < <(declare -f load_builtin_defaults | awk '
    {
        line=$0
        sub(/^[[:space:]]*/, "", line)
        if (line ~ /^[A-Z][A-Z0-9_]*=/) {
            sub(/=.*/, "", line)
            print line
        }
    }
')
unset _variable_name

# Persisted-format versions are implementation constants rather than
# user-adjustable settings.
readonly STATE_SCHEMA_VERSION=2
readonly HISTORY_SCHEMA_VERSION=3
readonly DEVICE_ID_SCHEMA_VERSION=2
readonly STATE_SCHEMA_FORMAT="health-monitoring-state"

# === Runtime State (do not modify) ===
declare -A SMART_STATE=()                         # Map device -> OK/WARNING/CRITICAL
declare -A SMART_MSGS=()                          # Map device -> aggregated SMART message string
declare -A MOUNT_TO_DEV=()                        # Map /mnt/diskX -> /dev/sdX|nvme
declare -A POOL_MEMBER_MAP=()                     # Map base device (/dev/sdX|nvme0n1) -> pool name
declare -A BURST_BOOST=()                         # Base device -> accumulated burst boost this run (0-100)
declare -A WRITER_DAILY=()                        # Map device -> recent daily bytes (workload presentation)
declare -A WRITER_PREVIOUS_DAILY=()               # Map device -> preceding-window daily bytes
declare -A WRITER_DIRECTION=()                    # Map device -> IMPROVING/RISING/STEADY/COLLECTING
declare -A WRITER_CHANGE_PCT=()                   # Map device -> signed recent-vs-previous rate change
declare -A WRITER_RECENT_READY=()                 # Map device -> 1 when recent window has sufficient evidence
declare -A WRITER_RECENT_SAMPLES=()               # Map device -> sample count in the recent workload window
declare -A WRITER_PREVIOUS_SAMPLES=()             # Map device -> sample count in the preceding workload window
declare -A TBW_FORECAST_CONFIDENCE=()             # Per-device TBW forecast confidence
declare -A TEMP_RATE_CONFIDENCE=()                # Per-device temperature-rate confidence
declare -A LAST_TEST=()                           # Map device -> last SMART test timestamp
declare -A LAST_TEST_EPOCH=() LAST_TEST_KIND=()   # Actual test-start epoch/type (legacy date state remains supported)
declare -A NVME_LAST_UNSAFE=()                    # NVMe device -> last unsafe shutdown count
declare -A NVME_LAST_ERRLOG=()                    # NVMe device -> last error information log entries
declare -A NVME_LAST_PCIE_CORR=()                 # NVMe device -> last PCIe correctable error count
declare -A NVME_LAST_PCIE_UNC=()                  # NVMe device -> last PCIe uncorrectable error count
declare -A NVME_LAST_THERM_T1=()                  # NVMe device -> last thermal management T1 transitions
declare -A NVME_LAST_THERM_T2=()                  # NVMe device -> last thermal management T2 transitions
declare -A NVME_LAST_WARN_TEMP_TIME=()            # NVMe device -> last warning temperature time (seconds)
declare -A NVME_LAST_CRIT_TEMP_TIME=()            # NVMe device -> last critical temperature time (seconds)
declare -A PREV_ATTR=()                           # device|attr -> previous raw value
declare -A CUR_ATTR=()                            # device|attr -> current raw value
declare -A NEW_SEEN=()                            # Newly seen alerts/disks set
declare -A LONG_LAST_POH=()                       # Map device -> last long self-test lifetime hours
declare -A LONG_TEST_DUE_SOON=()                  # Map device -> days until next long test when near
declare -A CMD_TIMEOUT_LAST=()                    # Map device -> previous command timeout count
declare -A LONG_TEST_RUNNING_LONG=()              # Map device -> 1 if a long/extended self-test is currently in progress
declare -a FINDING_IDS=()                         # Ordered canonical finding identifiers
declare -A FINDING_SEEN=()                        # Canonical finding de-duplication within a run
declare -A FINDING_SEVERITY=() FINDING_CATEGORY=() # Finding classification
declare -A FINDING_SIGNAL=() FINDING_DEVICE=()    # Risk signal and normalized base device
declare -A FINDING_SCOPE=()                       # Stable device, mount, pool, or global finding scope
declare -A FINDING_TITLE=() FINDING_EVIDENCE=()   # User-facing finding content
declare -A FINDING_ACTION=()                      # Canonical recommended action
declare -A SATA_POWER_STATE=() SMART_DEFERRED=()  # Cached SATA power state and deferred SMART checks
declare -A FRESH_SMART=() FRESH_STORAGE=() FRESH_FILESYSTEM=()
declare -A NOTIFY_PREV_DEVICE_ID=() NOTIFY_CURRENT_DEVICE_ID=()
ARRAY_RUNTIME_STATE=""
ARRAY_TOPOLOGY_OBSERVED=0
PARITY_RESULT_OBSERVED=0
PARITY_HISTORY_OBSERVED=0
RUN_COMPLETION_READY=0
MONITOR_LAST_COMPLETE_EPOCH=0
declare -A DEVICE_ID_BY_PATH=() DEVICE_PATH_BY_ID=() # Runtime path <-> stable persistent identity
declare -A DEVICE_ID_SOURCE=()                    # Identity source: WWN, by-id, serial, or path fallback
declare -a DISCOVERED_DISKS=()                    # Ordered SMART-capable base-device candidates
declare -a NOTIFY_SECTIONS=()                     # Final notification sections
declare -a TBW_EVAL_MESSAGES=()                   # Output from direct TBW evaluation
declare -a COLLECTOR_ORDER=()                     # Deterministic collector report order
declare -A COLLECTOR_LABEL=() COLLECTOR_STATUS=() # Collector label and final status
declare -A COLLECTOR_DURATION=() COLLECTOR_DETAIL=() # Collector timing and event summary
declare -A NOTIFY_PREV_SEVERITY=() NOTIFY_PREV_FINGERPRINT=() NOTIFY_PREV_LABEL=()
declare -A NOTIFY_CURRENT_SEVERITY=() NOTIFY_CURRENT_FINGERPRINT=() NOTIFY_CURRENT_LABEL=()
declare -A NOTIFY_RECOVERY_PREV_COUNT=() NOTIFY_RECOVERY_PREV_FINGERPRINT=()
declare -A NOTIFY_RECOVERY_NEXT_COUNT=() NOTIFY_RECOVERY_NEXT_FINGERPRINT=()
declare -A EXTERNAL_CONFIG_VALUES=()
declare -a NOTIFY_PREV_IDS=()
declare -a NOTIFY_RECOVERY_NEXT_IDS=() NOTIFY_CARRY_IDS=()
declare -a EXTERNAL_CONFIG_OVERRIDE_KEYS=()
TBW_EVAL_STATE="OK"

RUN_STAMP=""
RUN_EPOCH=0
MASTER_LOG=""
RUN_DIR=""
SMART_CACHE_DIR=""
COLLECTOR_EVENT_FILE=""
CURRENT_COLLECTOR="runtime"
LAST_COLLECTOR_RC=0
CLEANUP_DONE=0
PARITY_STATE_LOADED=0
PARITY_ACTIVE=0
DEVICE_INVENTORY_READY=0
SYSLOG_CURSOR_READY=0
SYSLOG_CURSOR_PENDING_PATH=""
SYSLOG_CURSOR_PENDING_DEVICE=""
SYSLOG_CURSOR_PENDING_INODE=""
SYSLOG_CURSOR_PENDING_LINES=0
SYSLOG_CURSOR_PENDING_SIZE=0
SYSLOG_CURSOR_PENDING_ANCHOR="-"
SYSLOG_CHUNK_FILE=""
SYSLOG_CURSOR_MODE="not_run"
RUN_MODE="monitor"
ROLLBACK_BACKUP_ID=""
CONFIG_ERROR_COUNT=0
CONFIG_WARNING_COUNT=0
DEPENDENCY_ERROR_COUNT=0
DEPENDENCY_WARNING_COUNT=0
FINDING_CRITICAL_COUNT=0
FINDING_WARNING_COUNT=0
FULL_NOTIFICATION_BODY=""
NOTIFICATION_TRUNCATED=0
NOTIFICATION_JOURNAL_LOADED=0
NOTIFICATION_LAST_SUCCESS_EPOCH=0
NOTIFICATION_LAST_SUCCESS_SEVERITY="normal"
NOTIFICATION_CURRENT_SEVERITY="normal"
NOTIFICATION_DECISION="SEND"
NOTIFICATION_REASON="legacy every-run delivery"
NOTIFICATION_NEW_COUNT=0
NOTIFICATION_CHANGED_COUNT=0
NOTIFICATION_RESOLVED_COUNT=0
NOTIFICATION_RECOVERY_DEFERRED_COUNT=0
NOTIFICATION_RECOVERY_PENDING_COUNT=0
NOTIFICATION_RECOVERY_SECTION=""
NOTIFICATION_JOURNAL_COMMIT_ALLOWED=0
NOTIFICATION_DELIVERY_ATTEMPTS=0
NOTIFICATION_DELIVERY_RC=0
NOTIFICATION_PHASE_REACHED=0
EXTERNAL_CONFIG_STATUS="NOT_LOADED"
EXTERNAL_CONFIG_DETAIL=""
EXTERNAL_CONFIG_OVERRIDE_COUNT=0
EXTERNAL_CONFIG_LOAD_FAILED=0
STATE_BACKUP_PATH_RESULT=""
STATE_BACKUP_SNAPSHOT_RESULT=""

# === Logs Paths ===
STATE_DIR="${LOG_DIR:-}/state"
MONITOR_RECEIPT_FILE="$STATE_DIR/monitor_receipt.json"
SMART_COVERAGE_FILE="$STATE_DIR/smart_coverage.tsv"
SMART_BASELINES_FILE="$STATE_DIR/smart_baselines.json"
EXTERNAL_CONFIG_FILE="$STATE_DIR/health_monitoring.conf"
LEGACY_EXTERNAL_CONFIG_FILE="$LOG_DIR/health_monitoring.conf"
STATE_BACKUP_DIR="$STATE_DIR/backups"

# === Categorized Timestamp Logging ===
log() {
    local category="$1"
    local level="$2"
    shift 2

    local message="$*"
    local line

    message="$(printf '%s' "$message" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} - //')"
    line=$(usr_ops_log_line "$level" "$category" "$message")

    if (( LOG_MIRROR_STDOUT == 1 )); then
        # Use stderr so logging never contaminates data returned by command substitution.
        printf '%s\n' "$line" >&2
    fi

    if [[ -n "$MASTER_LOG" ]]; then
        printf '%s\n' "$line" >> "$MASTER_LOG" 2>/dev/null || true
    fi
}

log_info()  { log "HEALTH" "INFO" "$*"; }
log_warn()  { log "HEALTH" "WARN" "$*"; }
log_crit()  { log "HEALTH" "CRIT" "$*"; }
log_smart() { log "SMART"  "INFO" "$*"; }
log_btrfs() { log "BTRFS"  "INFO" "$*"; }
log_xfs()   { log "XFS"    "INFO" "$*"; }

# === State Files ===
# --- Alerting & Runtime (immediate health evaluation, deltas, cooldowns, recent events) ---
SMART_LONG_STATE_FILE="$STATE_DIR/smart_long_processed.log"         # Long SMART test last run time per disk (scheduling)
SMART_LONG_LAST_POH_FILE="$STATE_DIR/smart_long_last.log"           # Long SMART test last POH snapshot per disk (delta vetting)
SMART_LAST="$STATE_DIR/smart_last_test.log"                         # Last SMART test type/time per disk (summary)
SMART_SELFTEST_DIR="$STATE_DIR/smart_selftest"                      # Per-disk SMART self-test logs (lifecycle events)
NVME_STATE_FILE="$STATE_DIR/counters_last.log"                      # NVMe counters last snapshot (delta alerts)
PREV_ATTR_FILE="$STATE_DIR/smart_prev_attrs.log"                    # Previous SMART/NVMe attribute raw values (delta calculations)
ALERT_NEW_SEEN_FILE="$STATE_DIR/new_alerts_seen.log"                # Newly seen alert/device tracking (de-dup noise)
CMD_TIMEOUT_LAST_FILE="$STATE_DIR/cmd_timeout_last.log"             # Previous command timeout counts (delta alerting)
CMD_TIMEOUT_STATE_DIR="$STATE_DIR/cmd_timeout"                      # Per-disk command timeout cooldown files
UNSAFE_SDWN_STATE_DIR="$STATE_DIR/unsafe_shutdown"                  # Per-NVMe unsafe shutdown cooldown files
BTRFS_SCRUB_STATE_DIR="$STATE_DIR/btrfs_scrub_status"               # Per-pool scrub status (in-progress vs last)
BTRFS_DEV_PREV_FILE="$STATE_DIR/btrfs_device_stats.prev"            # Previous Btrfs per-device counters and capture metadata
SYSLOG_CURSOR_STATE_FILE="$STATE_DIR/syslog_cursor.state"            # Persistent inode/line cursor for incremental syslog reads
DEVICE_ID_MAP_FILE="$STATE_DIR/device_identity_map.log"             # Stable ID to current /dev path inventory
DEVICE_ID_SCHEMA_FILE="$STATE_DIR/device_identity_schema.version"   # One-time /dev history migration marker
STATE_SCHEMA_MANIFEST_FILE="$STATE_DIR/state_schema.manifest"       # Coordinated persisted-format versions
REPLACEMENT_EVENTS_FILE="$STATE_DIR/replacement_events.log"         # Drive replacement lifecycle events (alerts context)
SATA_LINK_HISTORY_FILE="$STATE_DIR/sata_link_downshift_history.log" # SATA link instability events (alert context)
NOTIFICATION_JOURNAL_FILE="$STATE_DIR/notification_lifecycle.state" # Last successfully delivered canonical finding set
NOTIFICATION_RECOVERY_STATE_FILE="$STATE_DIR/notification_recovery.state" # Consecutive safe-run recovery candidates
# --- Trend / Historical Analytics (longer-term forecasting, prioritization, trajectory) ---
IO_ERROR_HISTORY_FILE="$STATE_DIR/io_error_history.log"             # I/O error frequency timeline (acceleration)
BTRFS_DEV_HIST_FILE="$STATE_DIR/btrfs_device_stats_history.log"     # Btrfs per-device error deltas over time
TBW_HISTORY_FILE="$STATE_DIR/tbw_history.log"                       # Total bytes written progression (wear modeling)
SMART_ATTR_HISTORY_FILE="$STATE_DIR/smart_attr_history.log"         # Attribute growth time-series (trend alerts)
TEMP_HISTORY_FILE="$STATE_DIR/temp_history.log"                     # Temperature samples (rate & exposure)
STATE_FILES_ALERT_RUNTIME=(
    "$MONITOR_RECEIPT_FILE" "$SMART_COVERAGE_FILE"
    "$SMART_LONG_STATE_FILE" "$SMART_LONG_LAST_POH_FILE" "$SMART_LAST" "$ALERT_NEW_SEEN_FILE"   "$BTRFS_DEV_PREV_FILE" "$SYSLOG_CURSOR_STATE_FILE"  "$REPLACEMENT_EVENTS_FILE" "$SATA_LINK_HISTORY_FILE" "$NOTIFICATION_JOURNAL_FILE" "$NOTIFICATION_RECOVERY_STATE_FILE"
)
STATE_FILES_TREND_HISTORY=(
    "$IO_ERROR_HISTORY_FILE" "$BTRFS_DEV_HIST_FILE"  "$TBW_HISTORY_FILE" "$SMART_ATTR_HISTORY_FILE" "$TEMP_HISTORY_FILE"
)
# === Notification Settings ===
NOTIFY_TITLE_SMART="SMART Test Alert"                       # SMART test notifications
NOTIFY_TITLE_BTRFS="Btrfs Scrub Alert"                      # Btrfs scrub notifications
NOTIFY_TITLE_XFS="XFS Alert"                                # XFS filesystem notifications
NOTIFY_TITLE_DISKIO="Disk I/O Alert"                        # Disk I/O notifications
ENABLE_MODEL_IN_ALERTS=0                                    # If 1, append disk model to per-disk health alert lines

################################################################################

# ---------------------------------------------------------------------------
# Runtime, locking, cleanup, and atomic state helpers
# ---------------------------------------------------------------------------

PATH_VALIDATION_REASON=""

validate_secure_absolute_path() {
    local path="${1:-}" remainder component

    PATH_VALIDATION_REASON=""
    if [[ -z "$path" || "$path" != /* || "$path" == "/" ]]; then
        PATH_VALIDATION_REASON="must be a non-root absolute path"
        return 1
    fi
    if [[ "$path" =~ [[:cntrl:]] ]]; then
        PATH_VALIDATION_REASON="contains control characters"
        return 1
    fi
    if [[ "$path" == *"//"* ]]; then
        PATH_VALIDATION_REASON="contains an empty path component"
        return 1
    fi

    remainder="${path#/}"
    while [[ -n "$remainder" ]]; do
        component="${remainder%%/*}"
        if [[ "$component" == "." || "$component" == ".." ]]; then
            PATH_VALIDATION_REASON="contains a dot traversal component"
            return 1
        fi
        [[ "$remainder" == */* ]] || break
        remainder="${remainder#*/}"
    done
    return 0
}

validate_symlink_free_path() {
    local path="$1" remainder component current=""

    validate_secure_absolute_path "$path" || return 1
    remainder="${path#/}"
    while [[ -n "$remainder" ]]; do
        component="${remainder%%/*}"
        current+="/$component"
        if [[ -L "$current" ]]; then
            PATH_VALIDATION_REASON="contains symbolic-link component $current"
            return 1
        fi
        [[ "$remainder" == */* ]] || break
        remainder="${remainder#*/}"
    done
    return 0
}

validate_secure_owned_directory() {
    local path="$1" owner mode permissions

    validate_symlink_free_path "$path" || return 1
    if [[ ! -d "$path" ]]; then
        PATH_VALIDATION_REASON="directory is missing"
        return 1
    fi
    owner="$(stat -c '%u' "$path" 2>/dev/null)" || {
        PATH_VALIDATION_REASON="cannot read directory ownership"
        return 1
    }
    if [[ "$owner" != "$EUID" ]]; then
        PATH_VALIDATION_REASON="directory owner uid $owner does not match runtime uid $EUID"
        return 1
    fi
    mode="$(stat -c '%a' "$path" 2>/dev/null)" || {
        PATH_VALIDATION_REASON="cannot read directory permissions"
        return 1
    }
    if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]]; then
        PATH_VALIDATION_REASON="cannot parse directory permissions"
        return 1
    fi
    permissions=$((8#$mode))
    if (( (permissions & 0022) != 0 )); then
        PATH_VALIDATION_REASON="directory is writable by group or others (mode $mode)"
        return 1
    fi
    return 0
}

validate_secure_owned_file() {
    local path="$1" owner mode links permissions

    validate_symlink_free_path "$path" || return 1
    if [[ ! -f "$path" ]]; then
        PATH_VALIDATION_REASON="target is not a regular file"
        return 1
    fi
    owner="$(stat -c '%u' "$path" 2>/dev/null)" || {
        PATH_VALIDATION_REASON="cannot read file ownership"
        return 1
    }
    if [[ "$owner" != "$EUID" ]]; then
        PATH_VALIDATION_REASON="file owner uid $owner does not match runtime uid $EUID"
        return 1
    fi
    links="$(stat -c '%h' "$path" 2>/dev/null)" || {
        PATH_VALIDATION_REASON="cannot read file link count"
        return 1
    }
    if [[ "$links" != "1" ]]; then
        PATH_VALIDATION_REASON="file has $links hard links"
        return 1
    fi
    mode="$(stat -c '%a' "$path" 2>/dev/null)" || {
        PATH_VALIDATION_REASON="cannot read file permissions"
        return 1
    }
    if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]]; then
        PATH_VALIDATION_REASON="cannot parse file permissions"
        return 1
    fi
    permissions=$((8#$mode))
    if (( (permissions & 0077) != 0 )); then
        PATH_VALIDATION_REASON="file is accessible by group or others (mode $mode)"
        return 1
    fi
    return 0
}

validate_managed_file_target() {
    local target="$1" parent links

    validate_symlink_free_path "$target" || return 1
    if [[ -e "$target" && ! -f "$target" ]]; then
        PATH_VALIDATION_REASON="existing target is not a regular file"
        return 1
    fi
    if [[ -f "$target" ]]; then
        links="$(stat -c '%h' "$target" 2>/dev/null)" || {
            PATH_VALIDATION_REASON="cannot read existing target link count"
            return 1
        }
        if [[ "$links" != "1" ]]; then
            PATH_VALIDATION_REASON="existing target has $links hard links"
            return 1
        fi
    fi
    parent="${target%/*}"
    [[ -n "$parent" ]] || parent="/"
    if [[ ! -d "$parent" || -L "$parent" ]]; then
        PATH_VALIDATION_REASON="parent directory is missing or unsafe"
        return 1
    fi
    return 0
}

# Unraid may remap existing share content to nobody:users (uid 99) even when
# the script originally created it. The state/config path is a fixed bootstrap
# path that external configuration cannot override, so root may safely reclaim
# only this exact directory and regular, single-link configuration file before
# parsing. Symbolic links, hard links, and unexpected path layouts still fail.
harden_existing_external_config_path() {
    local expected="$STATE_DIR/health_monitoring.conf"

    if [[ "$EXTERNAL_CONFIG_FILE" != "$expected" ]]; then
        PATH_VALIDATION_REASON="external configuration is outside the managed state directory"
        return 1
    fi
    if [[ ! -e "$STATE_DIR" && ! -L "$STATE_DIR" ]]; then
        return 0
    fi
    validate_symlink_free_path "$STATE_DIR" || return 1
    if [[ ! -d "$STATE_DIR" ]]; then
        PATH_VALIDATION_REASON="managed state path is not a directory"
        return 1
    fi
    if ! command -v chmod >/dev/null 2>&1; then
        PATH_VALIDATION_REASON="chmod is unavailable for state-directory hardening"
        return 1
    fi

    if (( EUID == 0 )); then
        if ! command -v chown >/dev/null 2>&1; then
            PATH_VALIDATION_REASON="chown is unavailable for Unraid ownership repair"
            return 1
        fi
        chown "$EUID" -- "$STATE_DIR" 2>/dev/null || {
            PATH_VALIDATION_REASON="cannot assign the state directory to uid $EUID"
            return 1
        }
    fi
    chmod 700 -- "$STATE_DIR" 2>/dev/null || {
        PATH_VALIDATION_REASON="cannot restrict state directory permissions"
        return 1
    }

    if [[ -e "$EXTERNAL_CONFIG_FILE" || -L "$EXTERNAL_CONFIG_FILE" ]]; then
        validate_managed_file_target "$EXTERNAL_CONFIG_FILE" || return 1
        if (( EUID == 0 )); then
            chown "$EUID" -- "$EXTERNAL_CONFIG_FILE" 2>/dev/null || {
                PATH_VALIDATION_REASON="cannot assign the external configuration to uid $EUID"
                return 1
            }
        fi
        chmod 600 -- "$EXTERNAL_CONFIG_FILE" 2>/dev/null || {
            PATH_VALIDATION_REASON="cannot restrict external configuration permissions"
            return 1
        }
    fi

    validate_secure_owned_directory "$STATE_DIR" || return 1
    if [[ -e "$EXTERNAL_CONFIG_FILE" || -L "$EXTERNAL_CONFIG_FILE" ]]; then
        validate_secure_owned_file "$EXTERNAL_CONFIG_FILE" || return 1
    fi
    return 0
}

ensure_dir() {
    local path="$1"

    validate_symlink_free_path "$path" || {
        log "PATH" "ERROR" "Unsafe directory path $path: $PATH_VALIDATION_REASON"
        return 1
    }
    if [[ -e "$path" && ! -d "$path" ]]; then
        log "PATH" "ERROR" "Directory target is not a directory: $path"
        return 1
    fi
    [[ -d "$path" ]] || mkdir -p -- "$path" || return 1
    validate_symlink_free_path "$path" || {
        log "PATH" "ERROR" "Directory became unsafe after creation $path: $PATH_VALIDATION_REASON"
        return 1
    }
}

ensure_private_dir() {
    local path="$1"

    ensure_dir "$path" || return 1
    if (( EUID == 0 )); then
        chown "$EUID" -- "$path" 2>/dev/null || {
            log "PATH" "ERROR" "Unable to assign private directory to uid $EUID: $path"
            return 1
        }
    fi
    chmod 700 -- "$path" 2>/dev/null || {
        log "PATH" "ERROR" "Unable to restrict directory permissions: $path"
        return 1
    }
}

secure_create_file() {
    local target="$1"

    validate_managed_file_target "$target" || {
        log "PATH" "ERROR" "Unsafe file target $target: $PATH_VALIDATION_REASON"
        return 1
    }
    if [[ -e "$target" || -L "$target" ]]; then
        log "PATH" "ERROR" "Refusing to overwrite existing file: $target"
        return 1
    fi
    if ! (set -o noclobber; : > "$target") 2>/dev/null; then
        log "PATH" "ERROR" "Unable to create file exclusively: $target"
        return 1
    fi
    chmod 600 -- "$target" 2>/dev/null || {
        rm -f -- "$target" 2>/dev/null || true
        return 1
    }
}

validate_managed_state_paths() {
    local path
    local -a directories=(
        "$STATE_DIR" "$SMART_SELFTEST_DIR" "$UNSAFE_SDWN_STATE_DIR"
        "$BTRFS_SCRUB_STATE_DIR" "$CMD_TIMEOUT_STATE_DIR" "$STATE_BACKUP_DIR"
    )
    local -a files=(
        "$STATE_SCHEMA_MANIFEST_FILE" "$DEVICE_ID_MAP_FILE" "$DEVICE_ID_SCHEMA_FILE"
        "$EXTERNAL_CONFIG_FILE" "$SMART_BASELINES_FILE"
        "${STATE_FILES_ALERT_RUNTIME[@]}" "${STATE_FILES_TREND_HISTORY[@]}"
    )

    for path in "${directories[@]}"; do
        validate_symlink_free_path "$path" || {
            log "PATH" "ERROR" "Unsafe managed directory $path: $PATH_VALIDATION_REASON"
            return 1
        }
        [[ ! -e "$path" || -d "$path" ]] || {
            log "PATH" "ERROR" "Managed directory target has the wrong type: $path"
            return 1
        }
    done
    for path in "${files[@]}"; do
        validate_managed_file_target "$path" || {
            log "PATH" "ERROR" "Unsafe managed state file $path: $PATH_VALIDATION_REASON"
            return 1
        }
    done
    return 0
}

harden_managed_state_permissions() {
    local path
    local -a files=(
        "$STATE_SCHEMA_MANIFEST_FILE" "$DEVICE_ID_MAP_FILE" "$DEVICE_ID_SCHEMA_FILE"
        "$EXTERNAL_CONFIG_FILE"
        "${STATE_FILES_ALERT_RUNTIME[@]}" "${STATE_FILES_TREND_HISTORY[@]}"
    )

    for path in "${files[@]}"; do
        [[ -e "$path" ]] || continue
        chmod 600 -- "$path" 2>/dev/null || {
            log "PATH" "ERROR" "Unable to restrict state-file permissions: $path"
            return 1
        }
    done
    return 0
}

external_config_log() {
    local level="$1"
    shift
    log "CONFIG" "$level" "$*"
}

trim_external_config_field() {
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    TRIMMED_EXTERNAL_CONFIG_FIELD="$value"
}

validate_external_pool_excludes() {
    local raw="$1" item
    local -a items=()

    EXTERNAL_POOL_EXCLUDES=()
    [[ -n "$raw" ]] || return 0
    IFS=',' read -r -a items <<< "$raw"
    for item in "${items[@]}"; do
        trim_external_config_field "$item"
        item="$TRIMMED_EXTERNAL_CONFIG_FIELD"
        if [[ -z "$item" || "$item" == */* ]]; then
            return 1
        fi
        EXTERNAL_POOL_EXCLUDES+=("$item")
    done
    return 0
}

# Parse KEY=VALUE records as data. The file is never sourced, so command
# substitutions, shell metacharacters, and executable statements stay inert.
load_external_configuration() {
    local line key value first last parent
    local line_number=0 errors=0
    local -a parsed_keys=()
    local -A parsed_values=() seen=()

    EXTERNAL_CONFIG_STATUS="ABSENT"
    EXTERNAL_CONFIG_DETAIL="using built-in defaults"
    EXTERNAL_CONFIG_OVERRIDE_COUNT=0
    EXTERNAL_CONFIG_OVERRIDE_KEYS=()
    EXTERNAL_CONFIG_VALUES=()
    EXTERNAL_CONFIG_LOAD_FAILED=0

    if [[ ! -e "$EXTERNAL_CONFIG_FILE" && ! -L "$EXTERNAL_CONFIG_FILE" ]]; then
        if [[ -e "$LEGACY_EXTERNAL_CONFIG_FILE" ||
              -L "$LEGACY_EXTERNAL_CONFIG_FILE" ]]; then
            EXTERNAL_CONFIG_DETAIL="using built-in defaults; legacy shared-directory configuration is ignored"
            external_config_log WARN \
                "Ignoring legacy configuration $LEGACY_EXTERNAL_CONFIG_FILE because LOG_DIR is not a trusted configuration directory; review and copy intended overrides into $EXTERNAL_CONFIG_FILE"
        fi
        return 0
    fi
    parent="${EXTERNAL_CONFIG_FILE%/*}"
    if ! validate_secure_owned_directory "$parent"; then
        EXTERNAL_CONFIG_STATUS="UNSAFE"
        EXTERNAL_CONFIG_DETAIL="$PATH_VALIDATION_REASON"
        EXTERNAL_CONFIG_LOAD_FAILED=1
        external_config_log ERROR \
            "Refusing external configuration $EXTERNAL_CONFIG_FILE: $EXTERNAL_CONFIG_DETAIL"
        return 1
    fi
    if ! validate_secure_owned_file "$EXTERNAL_CONFIG_FILE"; then
        EXTERNAL_CONFIG_STATUS="UNSAFE"
        EXTERNAL_CONFIG_DETAIL="$PATH_VALIDATION_REASON"
        EXTERNAL_CONFIG_LOAD_FAILED=1
        external_config_log ERROR \
            "Refusing external configuration $EXTERNAL_CONFIG_FILE: $EXTERNAL_CONFIG_DETAIL"
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        line="${line%$'\r'}"
        trim_external_config_field "$line"
        line="$TRIMMED_EXTERNAL_CONFIG_FIELD"
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" != *=* ]]; then
            external_config_log ERROR \
                "$EXTERNAL_CONFIG_FILE:$line_number requires KEY=VALUE"
            errors=$((errors + 1))
            continue
        fi
        key="${line%%=*}"
        value="${line#*=}"
        trim_external_config_field "$key"
        key="$TRIMMED_EXTERNAL_CONFIG_FIELD"
        trim_external_config_field "$value"
        value="$TRIMMED_EXTERNAL_CONFIG_FIELD"

        if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
            external_config_log ERROR \
                "$EXTERNAL_CONFIG_FILE:$line_number contains invalid setting name '$key'"
            errors=$((errors + 1))
            continue
        fi
        if [[ -z "${EXTERNAL_CONFIG_ALLOWED[$key]+present}" ]]; then
            external_config_log ERROR \
                "$EXTERNAL_CONFIG_FILE:$line_number contains unknown setting '$key'"
            errors=$((errors + 1))
            continue
        fi
        case "$key" in
            LOG_DIR|LOCK_FILE)
                external_config_log ERROR \
                    "$EXTERNAL_CONFIG_FILE:$line_number cannot override bootstrap setting $key"
                errors=$((errors + 1))
                continue
                ;;
        esac
        if [[ -n "${seen[$key]+present}" ]]; then
            external_config_log ERROR \
                "$EXTERNAL_CONFIG_FILE:$line_number repeats setting $key"
            errors=$((errors + 1))
            continue
        fi

        first="${value:0:1}"
        last="${value: -1}"
        if [[ "$first" == "'" || "$first" == '"' ]]; then
            if (( ${#value} < 2 )) || [[ "$last" != "$first" ]]; then
                external_config_log ERROR \
                    "$EXTERNAL_CONFIG_FILE:$line_number has unmatched quotes"
                errors=$((errors + 1))
                continue
            fi
            value="${value:1:${#value}-2}"
        elif [[ "$last" == "'" || "$last" == '"' ]]; then
            external_config_log ERROR \
                "$EXTERNAL_CONFIG_FILE:$line_number has unmatched quotes"
            errors=$((errors + 1))
            continue
        fi
        if [[ "$value" =~ [[:cntrl:]] ]]; then
            external_config_log ERROR \
                "$EXTERNAL_CONFIG_FILE:$line_number contains control characters"
            errors=$((errors + 1))
            continue
        fi
        if [[ "$key" == "POOL_EXCLUDES" ]] &&
           ! validate_external_pool_excludes "$value"
        then
            external_config_log ERROR \
                "$EXTERNAL_CONFIG_FILE:$line_number has invalid comma-separated pool names"
            errors=$((errors + 1))
            continue
        fi

        seen[$key]=1
        parsed_keys+=("$key")
        parsed_values[$key]="$value"
    done < "$EXTERNAL_CONFIG_FILE"

    if (( errors > 0 )); then
        EXTERNAL_CONFIG_STATUS="INVALID"
        EXTERNAL_CONFIG_DETAIL="$errors parse error(s); no overrides applied"
        EXTERNAL_CONFIG_LOAD_FAILED=1
        return 1
    fi

    for key in "${parsed_keys[@]}"; do
        value="${parsed_values[$key]}"
        if [[ "$key" == "POOL_EXCLUDES" ]]; then
            validate_external_pool_excludes "$value" || return 1
            POOL_EXCLUDES=("${EXTERNAL_POOL_EXCLUDES[@]}")
        else
            printf -v "$key" '%s' "$value"
        fi
        EXTERNAL_CONFIG_VALUES[$key]="$value"
        EXTERNAL_CONFIG_OVERRIDE_KEYS+=("$key")
    done
    EXTERNAL_CONFIG_OVERRIDE_COUNT="${#EXTERNAL_CONFIG_OVERRIDE_KEYS[@]}"
    EXTERNAL_CONFIG_STATUS="LOADED"
    EXTERNAL_CONFIG_DETAIL="$EXTERNAL_CONFIG_OVERRIDE_COUNT override(s) from $EXTERNAL_CONFIG_FILE"
    external_config_log INFO "$EXTERNAL_CONFIG_DETAIL"
    return 0
}

ensure_external_config_template() {
    local content

    [[ ! -e "$EXTERNAL_CONFIG_FILE" && ! -L "$EXTERNAL_CONFIG_FILE" ]] || return 0
    content="# Disk Health Monitor v${SCRIPT_VERSION} external overrides
# Location is fixed inside STATE_DIR so the configuration shares state path,
# permission, migration-backup, and rollback protection.
#
# Syntax: one KEY=VALUE per line. This file is parsed as data, not sourced.
# LOG_DIR and LOCK_FILE are bootstrap settings and cannot be overridden here.
# POOL_EXCLUDES uses comma-separated pool names.
#
# Examples (remove the leading '# ' to enable):
# SMART_ALLOW_SPINUP=0
# SHORT_TEST_INTERVAL_DAYS=7
# HISTORY_WINDOW_DAYS=14
# WARN_THRESHOLD_PERCENT=96
# CRITICAL_THRESHOLD_PERCENT=98
# NOTIFICATION_WARNING_REMINDER_HOURS=24
# NOTIFICATION_CRITICAL_REMINDER_HOURS=6
# NOTIFICATION_OK_REMINDER_HOURS=0
# NOTIFICATION_RECOVERY_CONFIRM_RUNS=2
# NOTIFICATION_DRY_RUN=0
# HEAVY_WRITER_RECENT_DAYS=3
# POOL_EXCLUDES=ramtmp,user0
"
    atomic_write_text "$EXTERNAL_CONFIG_FILE" "$content" || return 1
    chmod 600 -- "$EXTERNAL_CONFIG_FILE" || return 1
    log "CONFIG" "INFO" \
        "Created external configuration template: $EXTERNAL_CONFIG_FILE"
}

safe_state_name() {
    local value="${1:-unknown}"

    value="${value#/dev/}"
    value=$(printf '%s' "$value" | sed -E 's#[^A-Za-z0-9._-]+#_#g; s#^_+##; s#_+$##')
    [[ -n "$value" ]] || value="unknown"
    printf '%s' "$value"
}

join_by() {
    local delimiter="$1"
    shift
    local output=""
    local value

    for value in "$@"; do
        if [[ -z "$output" ]]; then
            output="$value"
        else
            output+="$delimiter$value"
        fi
    done

    printf '%s' "$output"
}

state_temp_file() {
    local target="$1"

    validate_managed_file_target "$target" || {
        log "PATH" "WARN" "Unsafe atomic-write target $target: $PATH_VALIDATION_REASON"
        return 1
    }
    mktemp "${target}.tmp.XXXXXX"
}

atomic_commit() {
    local temp_file="$1"
    local target="$2"
    local temp_parent target_parent

    validate_managed_file_target "$target" || {
        rm -f -- "$temp_file" 2>/dev/null || true
        log "STATE" "WARN" "Refused unsafe atomic target $target: $PATH_VALIDATION_REASON"
        return 1
    }
    if [[ ! -f "$temp_file" || -L "$temp_file" ]]; then
        log "STATE" "WARN" "Atomic source is not a regular temporary file: $temp_file"
        return 1
    fi
    temp_parent="${temp_file%/*}"
    target_parent="${target%/*}"
    if [[ "$temp_parent" != "$target_parent" ]]; then
        rm -f -- "$temp_file" 2>/dev/null || true
        log "STATE" "WARN" "Atomic source and target are not in the same directory: $target"
        return 1
    fi

    if ! mv -f -- "$temp_file" "$target"; then
        rm -f -- "$temp_file" 2>/dev/null || true
        log "STATE" "WARN" "Unable to replace state file atomically: $target"
        return 1
    fi

    return 0
}

atomic_write_text() {
    local target="$1"
    local value="$2"
    local temp_file

    temp_file="$(state_temp_file "$target")" || {
        log "STATE" "WARN" "Unable to create temporary state file for $target"
        return 1
    }

    if ! printf '%s' "$value" > "$temp_file"; then
        rm -f -- "$temp_file" 2>/dev/null || true
        log "STATE" "WARN" "Unable to write temporary state file for $target"
        return 1
    fi

    atomic_commit "$temp_file" "$target"
}

state_manifest_value() {
    local manifest="$1"
    local wanted="$2"

    [[ -r "$manifest" && -f "$manifest" && ! -L "$manifest" ]] || return 1
    awk -F= -v wanted="$wanted" '
        $1 == wanted {
            count++
            value=substr($0, length($1) + 2)
        }
        END {
            if (count == 1) {
                print value
                exit 0
            }
            exit 1
        }
    ' "$manifest"
}

write_state_schema_manifest() {
    local identity_schema="${1:-0}"
    local updated_epoch="${RUN_EPOCH:-0}"
    local content

    [[ "$identity_schema" =~ ^[0-9]+$ ]] || identity_schema=0
    (( updated_epoch > 0 )) || updated_epoch=$(date +%s)
    printf -v content \
        'format=%s\nstate_schema=%s\nhistory_schema=%s\nidentity_schema=%s\nwriter_version=%s\nupdated_epoch=%s\n' \
        "$STATE_SCHEMA_FORMAT" \
        "$STATE_SCHEMA_VERSION" \
        "$HISTORY_SCHEMA_VERSION" \
        "$identity_schema" \
        "$SCRIPT_VERSION" \
        "$updated_epoch"
    atomic_write_text "$STATE_SCHEMA_MANIFEST_FILE" "$content"
}

inspect_state_schema_manifest() {
    local manifest="${1:-$STATE_SCHEMA_MANIFEST_FILE}"
    local format state_schema history_schema identity_schema

    STATE_SCHEMA_STATUS="UNKNOWN"
    STATE_SCHEMA_DETAIL=""

    if [[ ! -e "$manifest" && ! -L "$manifest" ]]; then
        STATE_SCHEMA_STATUS="UNINITIALIZED"
        STATE_SCHEMA_DETAIL="state manifest is absent"
        return 10
    fi
    if ! validate_managed_file_target "$manifest"; then
        STATE_SCHEMA_STATUS="UNSAFE"
        STATE_SCHEMA_DETAIL="$PATH_VALIDATION_REASON"
        return 20
    fi

    format=$(state_manifest_value "$manifest" format 2>/dev/null || true)
    state_schema=$(state_manifest_value "$manifest" state_schema 2>/dev/null || true)
    history_schema=$(state_manifest_value "$manifest" history_schema 2>/dev/null || true)
    identity_schema=$(state_manifest_value "$manifest" identity_schema 2>/dev/null || true)

    if [[ "$format" != "$STATE_SCHEMA_FORMAT" ||
          ! "$state_schema" =~ ^[0-9]+$ ||
          ! "$history_schema" =~ ^[0-9]+$ ||
          ! "$identity_schema" =~ ^[0-9]+$ ]]
    then
        STATE_SCHEMA_STATUS="INVALID"
        STATE_SCHEMA_DETAIL="manifest is malformed, incomplete, or has duplicate keys"
        return 20
    fi

    if (( state_schema > STATE_SCHEMA_VERSION ||
          history_schema > HISTORY_SCHEMA_VERSION ||
          identity_schema > DEVICE_ID_SCHEMA_VERSION ))
    then
        STATE_SCHEMA_STATUS="FUTURE"
        STATE_SCHEMA_DETAIL="found state=$state_schema history=$history_schema identity=$identity_schema; supported state=$STATE_SCHEMA_VERSION history=$HISTORY_SCHEMA_VERSION identity=$DEVICE_ID_SCHEMA_VERSION"
        return 30
    fi

    if (( state_schema < STATE_SCHEMA_VERSION ||
          history_schema < HISTORY_SCHEMA_VERSION ))
    then
        STATE_SCHEMA_STATUS="LEGACY"
        STATE_SCHEMA_DETAIL="found state=$state_schema history=$history_schema identity=$identity_schema"
        return 40
    fi

    STATE_SCHEMA_STATUS="CURRENT"
    STATE_SCHEMA_DETAIL="state=$state_schema history=$history_schema identity=$identity_schema"
    return 0
}

current_identity_schema() {
    local identity_schema=0

    if [[ -r "$DEVICE_ID_SCHEMA_FILE" && -f "$DEVICE_ID_SCHEMA_FILE" &&
          ! -L "$DEVICE_ID_SCHEMA_FILE" ]]
    then
        read -r identity_schema < "$DEVICE_ID_SCHEMA_FILE" || identity_schema=0
    fi
    [[ "$identity_schema" =~ ^[0-9]+$ ]] || identity_schema=0
    printf '%s\n' "$identity_schema"
}

state_directory_has_payload() {
    local entry

    while IFS= read -r -d '' entry; do
        [[ "$entry" == "$STATE_BACKUP_DIR" ]] && continue
        [[ -d "$entry" ]] &&
            ! find "$entry" -mindepth 1 -print -quit 2>/dev/null | grep -q . &&
            continue
        return 0
    done < <(find "$STATE_DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    return 1
}

backup_metadata_value() {
    local metadata_file="$1" wanted="$2"

    [[ -r "$metadata_file" && -f "$metadata_file" && ! -L "$metadata_file" ]] || return 1
    awk -F= -v wanted="$wanted" '
        $1 == wanted {
            count++
            value=substr($0, length($1) + 2)
        }
        END {
            if (count == 1) {
                print value
                exit 0
            }
            exit 1
        }
    ' "$metadata_file"
}

validate_state_backup_id() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$ ]]
}

create_state_backup() {
    local reason="$1" source_state="$2" source_history="$3" source_identity="$4"
    local stamp backup_id temp_dir final_dir snapshot_dir entry metadata

    STATE_BACKUP_RESULT_ID=""
    [[ "$reason" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    ensure_private_dir "$STATE_BACKUP_DIR" || return 1
    validate_secure_owned_directory "$STATE_BACKUP_DIR" || {
        log "STATE" "ERROR" \
            "Unsafe backup directory $STATE_BACKUP_DIR: $PATH_VALIDATION_REASON"
        return 1
    }
    if find "$STATE_DIR" -path "$STATE_BACKUP_DIR" -prune -o \
        \( ! -type f ! -type d \) -print -quit |
       grep -q .
    then
        log "STATE" "ERROR" \
            "Refusing to back up state containing links or unsupported file types"
        return 1
    fi
    if find "$STATE_DIR" -path "$STATE_BACKUP_DIR" -prune -o \
        -type f -links +1 -print -quit | grep -q .
    then
        log "STATE" "ERROR" "Refusing to back up hard-linked state files"
        return 1
    fi

    stamp="$(date '+%Y%m%d_%H%M%S')"
    backup_id="${reason}-${stamp}-$$"
    validate_state_backup_id "$backup_id" || return 1
    final_dir="$STATE_BACKUP_DIR/$backup_id"
    [[ ! -e "$final_dir" && ! -L "$final_dir" ]] || return 1
    temp_dir="$(mktemp -d "$STATE_BACKUP_DIR/.backup.XXXXXX")" || return 1
    chmod 700 -- "$temp_dir" || {
        rm -rf -- "$temp_dir" 2>/dev/null || true
        return 1
    }
    snapshot_dir="$temp_dir/state"
    mkdir -p -- "$snapshot_dir" || {
        rm -rf -- "$temp_dir" 2>/dev/null || true
        return 1
    }
    chmod 700 -- "$snapshot_dir" || true

    while IFS= read -r -d '' entry; do
        [[ "$entry" == "$STATE_BACKUP_DIR" ]] && continue
        if ! cp -a -- "$entry" "$snapshot_dir/"; then
            rm -rf -- "$temp_dir" 2>/dev/null || true
            log "STATE" "ERROR" "Unable to copy state into backup $backup_id"
            return 1
        fi
    done < <(find "$STATE_DIR" -mindepth 1 -maxdepth 1 -print0)

    metadata="$temp_dir/backup.meta"
    if ! printf \
        'format=health-monitoring-state-backup\nbackup_schema=1\nreason=%s\ncreated_epoch=%s\nsource_state_schema=%s\nsource_history_schema=%s\nsource_identity_schema=%s\nwriter_version=%s\n' \
        "$reason" "$(date +%s)" "$source_state" "$source_history" \
        "$source_identity" "$SCRIPT_VERSION" > "$metadata"
    then
        rm -rf -- "$temp_dir" 2>/dev/null || true
        return 1
    fi
    chmod 600 -- "$metadata" || true
    if ! mv -- "$temp_dir" "$final_dir"; then
        rm -rf -- "$temp_dir" 2>/dev/null || true
        return 1
    fi
    STATE_BACKUP_RESULT_ID="$backup_id"
    log "STATE" "INFO" "Created state backup $backup_id"
    return 0
}

list_state_backups() {
    local backup_path backup_id metadata reason created source_schema found=0

    printf 'State backup directory: %s\n' "$STATE_BACKUP_DIR"
    if [[ ! -d "$STATE_BACKUP_DIR" ]]; then
        printf 'No state backups found.\n'
        return 0
    fi
    while IFS= read -r backup_path; do
        [[ -n "$backup_path" ]] || continue
        backup_id="${backup_path##*/}"
        metadata="$backup_path/backup.meta"
        reason="$(backup_metadata_value "$metadata" reason 2>/dev/null || printf 'unknown')"
        created="$(backup_metadata_value "$metadata" created_epoch 2>/dev/null || printf 'unknown')"
        source_schema="$(backup_metadata_value "$metadata" source_state_schema 2>/dev/null || printf 'unknown')"
        printf '%s\treason=%s\tcreated_epoch=%s\tsource_state_schema=%s\n' \
            "$backup_id" "$reason" "$created" "$source_schema"
        found=1
    done < <(find "$STATE_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d \
        ! -name '.*' -print 2>/dev/null | LC_ALL=C sort)
    (( found == 1 )) || printf 'No state backups found.\n'
}

validate_state_backup_contents() {
    local backup_id="$1" backup_dir snapshot_dir metadata format backup_schema

    STATE_BACKUP_PATH_RESULT=""
    STATE_BACKUP_SNAPSHOT_RESULT=""
    validate_state_backup_id "$backup_id" || {
        log "STATE" "ERROR" "Invalid state backup ID: $backup_id"
        return 1
    }
    backup_dir="$STATE_BACKUP_DIR/$backup_id"
    snapshot_dir="$backup_dir/state"
    metadata="$backup_dir/backup.meta"
    validate_secure_owned_directory "$backup_dir" || {
        log "STATE" "ERROR" "Unsafe state backup $backup_id: $PATH_VALIDATION_REASON"
        return 1
    }
    validate_secure_owned_directory "$snapshot_dir" || {
        log "STATE" "ERROR" "Unsafe backup snapshot $backup_id: $PATH_VALIDATION_REASON"
        return 1
    }
    validate_secure_owned_file "$metadata" || {
        log "STATE" "ERROR" "Unsafe backup metadata $backup_id: $PATH_VALIDATION_REASON"
        return 1
    }
    format="$(backup_metadata_value "$metadata" format 2>/dev/null || true)"
    backup_schema="$(backup_metadata_value "$metadata" backup_schema 2>/dev/null || true)"
    if [[ "$format" != "health-monitoring-state-backup" || "$backup_schema" != "1" ]]; then
        log "STATE" "ERROR" "State backup metadata is incompatible: $backup_id"
        return 1
    fi
    if find "$snapshot_dir" \( ! -type f ! -type d \) -print -quit | grep -q .; then
        log "STATE" "ERROR" \
            "State backup contains links or unsupported file types: $backup_id"
        return 1
    fi
    if find "$snapshot_dir" -type f -links +1 -print -quit | grep -q .; then
        log "STATE" "ERROR" "State backup contains hard-linked files: $backup_id"
        return 1
    fi
    STATE_BACKUP_PATH_RESULT="$backup_dir"
    STATE_BACKUP_SNAPSHOT_RESULT="$snapshot_dir"
    return 0
}

restore_state_backup_contents() {
    local backup_id="$1" snapshot_dir entry target

    validate_state_backup_contents "$backup_id" || return 1
    snapshot_dir="$STATE_BACKUP_SNAPSHOT_RESULT"

    # A rollback is explicit and runs under the process lock. Preserve the
    # backup directory itself while replacing the backed-up state payload.
    while IFS= read -r -d '' entry; do
        [[ "$entry" == "$STATE_BACKUP_DIR" ]] && continue
        target="$entry"
        validate_symlink_free_path "$target" || return 1
        if [[ -d "$target" ]]; then
            rm -rf -- "$target" || return 1
        else
            rm -f -- "$target" || return 1
        fi
    done < <(find "$STATE_DIR" -mindepth 1 -maxdepth 1 -print0)

    while IFS= read -r -d '' entry; do
        cp -a -- "$entry" "$STATE_DIR/" || return 1
    done < <(find "$snapshot_dir" -mindepth 1 -maxdepth 1 -print0)
    find "$STATE_DIR" -path "$STATE_BACKUP_DIR" -prune -o -type d -exec chmod 700 -- {} +
    find "$STATE_DIR" -path "$STATE_BACKUP_DIR" -prune -o -type f -exec chmod 600 -- {} +
    return 0
}

rollback_state_backup() {
    local backup_id="$1" current_state=0 current_history=0 current_identity=0
    local guard_id

    validate_state_backup_id "$backup_id" || {
        log "STATE" "ERROR" "Invalid state backup ID: $backup_id"
        return 1
    }
    ensure_private_dir "$STATE_DIR" || return 1
    ensure_private_dir "$STATE_BACKUP_DIR" || return 1
    validate_state_backup_contents "$backup_id" || return 1
    current_state="$(state_manifest_value "$STATE_SCHEMA_MANIFEST_FILE" state_schema 2>/dev/null || printf '0')"
    current_history="$(state_manifest_value "$STATE_SCHEMA_MANIFEST_FILE" history_schema 2>/dev/null || printf '0')"
    current_identity="$(state_manifest_value "$STATE_SCHEMA_MANIFEST_FILE" identity_schema 2>/dev/null || printf '0')"
    create_state_backup \
        "pre-rollback" "$current_state" "$current_history" "$current_identity" || return 1
    guard_id="$STATE_BACKUP_RESULT_ID"
    if ! restore_state_backup_contents "$backup_id"; then
        log "STATE" "ERROR" \
            "Rollback failed; current-state safety backup is $guard_id"
        return 1
    fi
    log "STATE" "INFO" \
        "Restored state backup $backup_id (pre-rollback safety backup: $guard_id)"
    printf 'State rollback completed: %s\n' "$backup_id"
    printf 'Pre-rollback safety backup: %s\n' "$guard_id"
    printf 'Do not run v%s normally if you intend to restore an older script version.\n' \
        "$SCRIPT_VERSION"
    return 0
}

migrate_state_schema() {
    local from_state="$1" from_history="$2" from_identity="$3"
    local backup_id

    if [[ "$from_state" != "1" || "$from_history" != "$HISTORY_SCHEMA_VERSION" ||
          ! "$from_identity" =~ ^[0-9]+$ ||
          "$from_identity" -gt "$DEVICE_ID_SCHEMA_VERSION" ]]
    then
        log "STATE" "ERROR" \
            "No safe migration path from state=$from_state history=$from_history identity=$from_identity"
        return 1
    fi
    create_state_backup \
        "migration-v${from_state}-to-v${STATE_SCHEMA_VERSION}" \
        "$from_state" "$from_history" "$from_identity" || return 1
    backup_id="$STATE_BACKUP_RESULT_ID"
    if ! write_state_schema_manifest "$from_identity"; then
        log "STATE" "ERROR" \
            "State migration manifest update failed; original backup is $backup_id"
        return 1
    fi
    log "STATE" "INFO" \
        "Migrated state schema v$from_state to v$STATE_SCHEMA_VERSION (rollback backup: $backup_id)"
    return 0
}

ensure_state_schema_manifest() {
    local rc identity_schema manifest_identity state_schema history_schema

    if inspect_state_schema_manifest; then
        identity_schema=$(current_identity_schema)
        if (( identity_schema > DEVICE_ID_SCHEMA_VERSION )); then
            log "STATE" "ERROR" \
                "Device identity schema $identity_schema is newer than supported $DEVICE_ID_SCHEMA_VERSION"
            return 1
        fi
        manifest_identity=$(state_manifest_value "$STATE_SCHEMA_MANIFEST_FILE" identity_schema 2>/dev/null || printf '0')
        if [[ "$manifest_identity" != "$identity_schema" ]]; then
            write_state_schema_manifest "$identity_schema" || return 1
            log "STATE" "INFO" \
                "Reconciled state manifest identity schema to $identity_schema"
        fi
        return 0
    else
        rc=$?
    fi

    case "$rc" in
        10)
            identity_schema=$(current_identity_schema)
            if (( identity_schema > DEVICE_ID_SCHEMA_VERSION )); then
                log "STATE" "ERROR" \
                    "Device identity schema $identity_schema is newer than supported $DEVICE_ID_SCHEMA_VERSION"
                return 1
            fi
            if state_directory_has_payload; then
                create_state_backup \
                    "adoption-to-v${STATE_SCHEMA_VERSION}" 0 \
                    "$HISTORY_SCHEMA_VERSION" "$identity_schema" || return 1
            fi
            write_state_schema_manifest "$identity_schema" || return 1
            log "STATE" "INFO" \
                "Registered existing state as schema $STATE_SCHEMA_VERSION (history=$HISTORY_SCHEMA_VERSION identity=$identity_schema)"
            ;;
        40)
            state_schema="$(state_manifest_value "$STATE_SCHEMA_MANIFEST_FILE" state_schema 2>/dev/null || true)"
            history_schema="$(state_manifest_value "$STATE_SCHEMA_MANIFEST_FILE" history_schema 2>/dev/null || true)"
            identity_schema="$(state_manifest_value "$STATE_SCHEMA_MANIFEST_FILE" identity_schema 2>/dev/null || true)"
            migrate_state_schema "$state_schema" "$history_schema" "$identity_schema" || return 1
            ;;
        *)
            log "STATE" "ERROR" \
                "Refusing incompatible state manifest ($STATE_SCHEMA_STATUS): $STATE_SCHEMA_DETAIL"
            return 1
            ;;
    esac
    return 0
}

print_state_schema_status() {
    local rc=0 backup_count=0

    if inspect_state_schema_manifest; then
        rc=0
    else
        rc=$?
    fi
    printf 'State directory: %s\n' "$STATE_DIR"
    printf 'State schema status: %s\n' "$STATE_SCHEMA_STATUS"
    printf 'State schema detail: %s\n' "$STATE_SCHEMA_DETAIL"
    printf 'Supported schemas: state=%s history=%s identity=%s\n' \
        "$STATE_SCHEMA_VERSION" "$HISTORY_SCHEMA_VERSION" "$DEVICE_ID_SCHEMA_VERSION"
    printf 'External configuration: %s (%s)\n' \
        "$EXTERNAL_CONFIG_FILE" "$EXTERNAL_CONFIG_STATUS"
    if [[ -d "$STATE_BACKUP_DIR" ]]; then
        backup_count="$(find "$STATE_BACKUP_DIR" -mindepth 1 -maxdepth 1 \
            -type d ! -name '.*' -print 2>/dev/null | awk 'END {print NR+0}')"
    fi
    printf 'State rollback backups: %s\n' "$backup_count"
    case "$rc" in
        0|10) return 0 ;;
        *)    return 1 ;;
    esac
}

# Return a record timestamp. Schema-v3 rows carry captured_epoch; legacy rows
# fall back to midnight for their leading YYYY-MM-DD date.
history_record_epoch() {
    local date_field="$1"
    local record="${2:-}"
    local token epoch=""
    local -a tokens=()

    IFS=$' \t' read -r -a tokens <<< "$record"
    for token in "${tokens[@]}"; do
        if [[ "$token" == captured_epoch=* ]]; then
            epoch="${token#*=}"
            break
        fi
    done
    if [[ "$epoch" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$epoch"
    else
        date -d "$date_field 00:00:00" +%s 2>/dev/null || return 1
    fi
}

history_field_value() {
    local record="$1"
    local wanted="$2"
    local token
    local -a tokens=()

    IFS=$' \t' read -r -a tokens <<< "$record"
    for token in "${tokens[@]}"; do
        if [[ "$token" == "$wanted="* ]]; then
            printf '%s\n' "${token#*=}"
            return 0
        fi
    done
    return 1
}

# Replace every row for one date in one atomic commit. Callers pass complete
# normalized rows as separate arguments. Malformed legacy rows are discarded.
atomic_replace_daily_history() {
    local target="$1"
    local replace_date="$2"
    shift 2
    local temp_file record

    temp_file="$(state_temp_file "$target")" || return 1
    if [[ -f "$target" ]]; then
        if ! awk -v d="$replace_date" '
            /^#/ { print; next }
            $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
                if ($1 != d) print
            }
        ' "$target" > "$temp_file" 2>/dev/null
        then
            rm -f -- "$temp_file" 2>/dev/null || true
            log "HISTORY" "WARN" "Unable to stage daily history update: $target"
            return 1
        fi
    fi
    for record in "$@"; do
        [[ "$record" == "$replace_date "* ]] || continue
        printf '%s\n' "$record" >> "$temp_file" || {
            rm -f -- "$temp_file" 2>/dev/null || true
            return 1
        }
    done
    atomic_commit "$temp_file" "$target"
}

# Atomically replace one date/entity row while retaining other entities from
# that date. This is used by collectors that discover samples one device at a
# time, such as SMART temperature parsing.
atomic_upsert_daily_history() {
    local target="$1"
    local replace_date="$2"
    local entity="$3"
    local record="$4"
    local temp_file

    [[ "$record" == "$replace_date $entity "* ]] || return 1
    temp_file="$(state_temp_file "$target")" || return 1
    if [[ -f "$target" ]]; then
        if ! awk -v d="$replace_date" -v e="$entity" '
            /^#/ { print; next }
            $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
                if (!($1 == d && $2 == e)) print
            }
        ' "$target" > "$temp_file" 2>/dev/null
        then
            rm -f -- "$temp_file" 2>/dev/null || true
            log "HISTORY" "WARN" "Unable to stage entity history update: $target"
            return 1
        fi
    fi
    printf '%s\n' "$record" >> "$temp_file" || {
        rm -f -- "$temp_file" 2>/dev/null || true
        return 1
    }
    atomic_commit "$temp_file" "$target"
}

# ---------------------------------------------------------------------------
# Bounded commands, collector isolation, and persistence gates
# ---------------------------------------------------------------------------

record_collector_event() {
    local kind="$1"
    local label="${2:-command}"
    local detail="${3:-}"
    local collector="${CURRENT_COLLECTOR:-runtime}"

    [[ -n "${COLLECTOR_EVENT_FILE:-}" ]] || return 0
    label="${label//$'\t'/ }"
    label="${label//$'\n'/ }"
    detail="${detail//$'\t'/ }"
    detail="${detail//$'\n'/ }"
    printf '%s\t%s\t%s\t%s\n' "$collector" "$kind" "$label" "$detail" \
        >> "$COLLECTOR_EVENT_FILE" 2>/dev/null || true
}

collector_event_count() {
    local collector="$1"
    local kind="$2"

    [[ -r "${COLLECTOR_EVENT_FILE:-}" ]] || {
        printf '0\n'
        return 0
    }
    awk -F '\t' -v collector="$collector" -v kind="$kind" \
        '$1 == collector && $2 == kind {count++} END {print count+0}' \
        "$COLLECTOR_EVENT_FILE"
}

collector_has_blocking_event() {
    local collector="${1:-${CURRENT_COLLECTOR:-runtime}}"

    [[ -r "${COLLECTOR_EVENT_FILE:-}" ]] || return 1
    awk -F '\t' -v collector="$collector" '
        $1 == collector && ($2 == "TIMEOUT" || $2 == "FAILED") {found=1; exit}
        END {exit !found}
    ' "$COLLECTOR_EVENT_FILE"
}

collector_device_has_blocking_event() {
    local collector="$1"
    local device="$2"

    [[ -r "${COLLECTOR_EVENT_FILE:-}" ]] || return 1
    awk -F '\t' -v collector="$collector" -v device="$device" '
        $1 == collector && ($2 == "TIMEOUT" || $2 == "FAILED") &&
        ($3 == "smartctl " device || $3 == "SMART " device) {
            found=1
            exit
        }
        END {exit !found}
    ' "$COLLECTOR_EVENT_FILE"
}

collector_current_state_writable() {
    ! collector_has_blocking_event "${CURRENT_COLLECTOR:-runtime}"
}

# Do not replace a known-good baseline after a command timeout/failure in the
# collector currently producing it.
collector_atomic_commit() {
    local temp_file="$1"
    local target="$2"

    if ! collector_current_state_writable; then
        rm -f -- "$temp_file" 2>/dev/null || true
        log "STATE" "WARN" \
            "Preserved existing state after ${CURRENT_COLLECTOR:-runtime} collector failure: $target"
        return 0
    fi
    atomic_commit "$temp_file" "$target" || {
        record_collector_event FAILED "State $target" "atomic commit failed"
        return 1
    }
}

collector_atomic_write_text() {
    local target="$1"
    local value="$2"

    if ! collector_current_state_writable; then
        log "STATE" "WARN" \
            "Skipped state update after ${CURRENT_COLLECTOR:-runtime} collector failure: $target"
        return 0
    fi
    atomic_write_text "$target" "$value" || {
        record_collector_event FAILED "State $target" "atomic write failed"
        return 1
    }
}

collector_replace_daily_history() {
    if ! collector_current_state_writable; then
        log "HISTORY" "WARN" \
            "Skipped history replacement after ${CURRENT_COLLECTOR:-runtime} collector failure: $1"
        return 0
    fi
    atomic_replace_daily_history "$@" || {
        record_collector_event FAILED "State $1" "history replacement failed"
        return 1
    }
}

collector_upsert_daily_history() {
    if ! collector_current_state_writable; then
        log "HISTORY" "WARN" \
            "Skipped history upsert after ${CURRENT_COLLECTOR:-runtime} collector failure: $1"
        return 0
    fi
    atomic_upsert_daily_history "$@" || {
        record_collector_event FAILED "State $1" "history upsert failed"
        return 1
    }
}

# GNU timeout returns 124 for an elapsed deadline. The command's ordinary exit
# status remains available to callers so health tools such as smartctl and
# xfs_repair can retain their native result semantics.
run_bounded() {
    local timeout_seconds="$1"
    local label="$2"
    shift 2
    local rc

    timeout --signal=TERM \
        --kill-after="${COMMAND_KILL_GRACE_SECONDS}s" \
        "${timeout_seconds}s" "$@"
    rc=$?
    if (( rc == 124 || rc == 137 )); then
        record_collector_event TIMEOUT "$label" "deadline=${timeout_seconds}s rc=$rc"
    fi
    return "$rc"
}

run_bounded_checked() {
    local timeout_seconds="$1"
    local label="$2"
    shift 2
    local rc

    run_bounded "$timeout_seconds" "$label" "$@"
    rc=$?
    if (( rc != 0 && rc != 124 && rc != 137 )); then
        record_collector_event FAILED "$label" "rc=$rc"
    fi
    return "$rc"
}

smartctl_exit_has_operational_failure() {
    local rc="${1:-}"

    [[ "$rc" =~ ^[0-9]+$ ]] || return 0
    (( (rc & 3) != 0 ))
}

smartctl_bounded() {
    local device="${*: -1}"
    local rc

    run_bounded "$SMARTCTL_TIMEOUT_SECONDS" "smartctl $device" smartctl "$@"
    rc=$?
    # smartctl uses a bitmask: bits 0/1 are command-line or device-open
    # failures, while higher bits describe actual SMART health findings.
    if (( rc != 124 && rc != 137 )) &&
       smartctl_exit_has_operational_failure "$rc"
    then
        record_collector_event FAILED "smartctl $device" "command_or_open_failure rc=$rc"
    fi
    return "$rc"
}

smartctl_bounded_optional() {
    run_bounded "$SMARTCTL_TIMEOUT_SECONDS" "smartctl ${*: -1}" smartctl "$@"
}

btrfs_bounded() {
    run_bounded_checked "$BTRFS_COMMAND_TIMEOUT_SECONDS" "btrfs $*" btrfs "$@"
}

btrfs_bounded_optional() {
    run_bounded "$BTRFS_COMMAND_TIMEOUT_SECONDS" "btrfs $*" btrfs "$@"
}

df_bounded() {
    run_bounded_checked "$SYSTEM_COMMAND_TIMEOUT_SECONDS" "df ${*: -1}" df "$@"
}

findmnt_bounded() {
    run_bounded "$SYSTEM_COMMAND_TIMEOUT_SECONDS" "findmnt ${*: -1}" findmnt "$@"
}

# shellcheck disable=SC2120
lsblk_bounded() {
    run_bounded_checked "$SYSTEM_COMMAND_TIMEOUT_SECONDS" "lsblk ${*: -1}" lsblk "$@"
}

hdparm_bounded() {
    run_bounded "$SYSTEM_COMMAND_TIMEOUT_SECONDS" "hdparm ${*: -1}" hdparm "$@"
}

collector_status_is_safe() {
    case "${COLLECTOR_STATUS[$1]:-NOT_RUN}" in
        OK|DEFERRED) return 0 ;;
        *)           return 1 ;;
    esac
}

all_collectors_state_safe() {
    local collector

    for collector in "${COLLECTOR_ORDER[@]}"; do
        case "${COLLECTOR_STATUS[$collector]:-NOT_RUN}" in
            TIMED_OUT|FAILED) return 1 ;;
        esac
    done
    return 0
}

run_collector() {
    local collector="$1"
    local label="$2"
    shift 2
    local start_epoch end_epoch duration rc=0 status detail=""
    local timeout_count failure_count deferred_count slow=0 existing

    existing="${COLLECTOR_LABEL[$collector]:-}"
    if [[ -z "$existing" ]]; then
        COLLECTOR_ORDER+=("$collector")
    fi
    COLLECTOR_LABEL[$collector]="$label"
    CURRENT_COLLECTOR="$collector"
    start_epoch=$(date +%s)

    if "$@"; then
        rc=0
    else
        rc=$?
    fi

    end_epoch=$(date +%s)
    duration=$((end_epoch - start_epoch))
    (( duration < 0 )) && duration=0
    timeout_count=$(collector_event_count "$collector" TIMEOUT)
    failure_count=$(collector_event_count "$collector" FAILED)
    deferred_count=$(collector_event_count "$collector" DEFERRED)

    if (( timeout_count > 0 )); then
        status="TIMED_OUT"
    elif (( rc != 0 || failure_count > 0 )); then
        status="FAILED"
    elif (( deferred_count > 0 )); then
        status="DEFERRED"
    else
        status="OK"
    fi

    (( timeout_count > 0 )) && detail+="timeouts=$timeout_count"
    if (( failure_count > 0 )); then
        [[ -z "$detail" ]] || detail+=", "
        detail+="failures=$failure_count"
    fi
    if (( deferred_count > 0 )); then
        [[ -z "$detail" ]] || detail+=", "
        detail+="deferred=$deferred_count"
    fi
    if (( rc != 0 )); then
        [[ -z "$detail" ]] || detail+=", "
        detail+="rc=$rc"
    fi
    if (( COLLECTOR_SLOW_SECONDS > 0 && duration >= COLLECTOR_SLOW_SECONDS )); then
        slow=1
        [[ -z "$detail" ]] || detail+=", "
        detail+="slow>=${COLLECTOR_SLOW_SECONDS}s"
    fi

    COLLECTOR_STATUS[$collector]="$status"
    COLLECTOR_DURATION[$collector]="$duration"
    COLLECTOR_DETAIL[$collector]="$detail"
    LAST_COLLECTOR_RC=$rc
    CURRENT_COLLECTOR="runtime"

    if [[ "$status" == "TIMED_OUT" || "$status" == "FAILED" || $slow -eq 1 ]]; then
        log "COLLECTOR" "WARN" \
            "$label completed status=$status duration=${duration}s${detail:+ ($detail)}"
    else
        log "COLLECTOR" "INFO" \
            "$label completed status=$status duration=${duration}s${detail:+ ($detail)}"
    fi

    if (( COLLECTOR_FAILURE_NOTIFICATIONS == 1 )); then
        case "$status" in
            TIMED_OUT)
                record_finding warning monitoring monitoring.timeout "" \
                    "Collector timeout" \
                    "$label exceeded one or more command deadlines; affected baselines were preserved." \
                    "Review the run log, device responsiveness, controller health, and configured timeout before retrying." \
                    "collector_${collector}_timeout"
                ;;
            FAILED)
                record_finding warning monitoring monitoring.failure "" \
                    "Collector failure" \
                    "$label failed or returned incomplete data; affected baselines were preserved." \
                    "Review the run log and correct the collector dependency or input before retrying." \
                    "collector_${collector}_failure"
                ;;
        esac
    fi

    return 0
}

# Classify forecast evidence. RESET is supplied by callers when a monotonic
# endurance counter regresses and STALE when the newest sample is too old.
forecast_confidence() {
    local samples="${1:-0}"
    local span_days="${2:-0}"
    local latest_age_days="${3:-999999}"
    local maximum_gap_days="${4:-999999}"

    if (( samples < FORECAST_MIN_SAMPLES )) ||
       awk -v span="$span_days" -v minimum="$FORECAST_MIN_SPAN_DAYS" \
           'BEGIN { exit !(span < minimum) }'
    then
        printf 'INSUFFICIENT\n'
    elif awk -v age="$latest_age_days" -v stale="$FORECAST_STALE_AFTER_DAYS" \
             'BEGIN { exit !(age > stale) }'
    then
        printf 'STALE\n'
    elif awk -v gap="$maximum_gap_days" -v maximum="$FORECAST_MAX_GAP_DAYS" \
             'BEGIN { exit !(gap > maximum) }'
    then
        printf 'LOW\n'
    elif (( samples >= FORECAST_HIGH_SAMPLES )) &&
         awk -v span="$span_days" -v high="$FORECAST_HIGH_SPAN_DAYS" \
             'BEGIN { exit !(span >= high) }'
    then
        printf 'HIGH\n'
    else
        printf 'MEDIUM\n'
    fi
}

forecast_confidence_is_actionable() {
    [[ "$1" == "MEDIUM" || "$1" == "HIGH" ]]
}

acquire_lock() {
    local parent lock_rc

    if ! command -v flock >/dev/null 2>&1; then
        printf '%s [LOCK][ERROR] flock is unavailable\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" >&2
        return 1
    fi

    parent="${LOCK_FILE%/*}"
    [[ -n "$parent" ]] || parent="/"
    if ! validate_secure_owned_directory "$parent"; then
        printf '%s [LOCK][ERROR] Unsafe lock directory %s: %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$parent" \
            "$PATH_VALIDATION_REASON" >&2
        return 1
    fi
    if [[ ! -e "$LOCK_FILE" && ! -L "$LOCK_FILE" ]]; then
        secure_create_file "$LOCK_FILE" || return 1
    fi
    if ! validate_secure_owned_file "$LOCK_FILE"; then
        printf '%s [LOCK][ERROR] Unsafe lock file %s: %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$LOCK_FILE" \
            "$PATH_VALIDATION_REASON" >&2
        return 1
    fi

    exec 9<>"$LOCK_FILE" || return 1
    if flock -n -E 75 9; then
        return 0
    else
        lock_rc=$?
    fi
    if (( lock_rc == 75 )); then
        printf '%s [LOCK][INFO] Another health_monitoring.sh run is active; exiting (lock: %s)\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$LOCK_FILE" >&2
        return 75
    fi
    printf '[LOCK][ERROR] Unable to acquire %s (flock status %s)\n' "$LOCK_FILE" "$lock_rc" >&2
    return 1
}

write_monitor_receipt() {
    local status="$1" exit_code="$2" outcome finished=0
    set_notification_outcome
    outcome="$RECEIPT_NOTIFICATION_OUTCOME_RESULT"
    if [[ "$status" != running ]]; then finished=$(date +%s); fi
    if [[ "$status" == complete ]]; then MONITOR_LAST_COMPLETE_EPOCH="$finished"; fi
    atomic_write_text "$MONITOR_RECEIPT_FILE" "$(printf \
        '{"schema":1,"status":"%s","version":"%s","lastAttemptEpoch":%d,"finishedEpoch":%d,"lastCompleteEpoch":%d,"notification":"%s","exitCode":%d}\n' \
        "$status" "$SCRIPT_VERSION" "$RUN_EPOCH" "$finished" \
        "$MONITOR_LAST_COMPLETE_EPOCH" "$outcome" "$exit_code")"
}

initialize_runtime() {
    local state_file

    ensure_dir "$LOG_DIR" || return 1
    ensure_private_dir "$STATE_DIR" || return 1
    validate_managed_state_paths || return 1
    # Inspect/adopt the manifest before changing existing state permissions or
    # creating state subdirectories. Future or malformed schemas therefore
    # fail without partially initializing this version's layout.
    ensure_state_schema_manifest || return 1

    ensure_private_dir "$STATE_DIR" || return 1
    ensure_private_dir "$SMART_SELFTEST_DIR" || return 1
    ensure_private_dir "$UNSAFE_SDWN_STATE_DIR" || return 1
    ensure_private_dir "$BTRFS_SCRUB_STATE_DIR" || return 1
    ensure_private_dir "$CMD_TIMEOUT_STATE_DIR" || return 1
    validate_managed_state_paths || return 1
    harden_managed_state_permissions || return 1
    ensure_external_config_template || return 1

    RUN_EPOCH="$(date +%s)"
    RUN_STAMP="$(date '+%Y-%m-%d_%H%M%S')"
    MASTER_LOG="$LOG_DIR/disk_health_${RUN_STAMP}_$$.log"
    secure_create_file "$MASTER_LOG" || return 1

    RUN_DIR="$(mktemp -d /tmp/health_monitoring.XXXXXX)" || {
        log "INIT" "ERROR" "Unable to create run workspace"
        return 1
    }
    chmod 700 -- "$RUN_DIR" 2>/dev/null || return 1
    SMART_CACHE_DIR="$RUN_DIR/smartctl"
    ensure_private_dir "$SMART_CACHE_DIR" || return 1
    COLLECTOR_EVENT_FILE="$RUN_DIR/collector_events.tsv"
    secure_create_file "$COLLECTOR_EVENT_FILE" || return 1

    # Remove cache files produced by older versions; this version never reuses
    # SMART output across runs.
    find /tmp -maxdepth 1 -type f -name 'health_smart_cache_*.txt' \
        -delete 2>/dev/null || true

    for state_file in \
        "${STATE_FILES_ALERT_RUNTIME[@]}" \
        "${STATE_FILES_TREND_HISTORY[@]}"
    do
        [[ -e "$state_file" ]] || : > "$state_file" || {
            log "STATE" "WARN" "Unable to initialize state file: $state_file"
            return 1
        }
    done

    log "INIT" "INFO" "Runtime initialized (state: $STATE_DIR)"
}

cleanup() {
    local exit_code="$1" receipt_status=incomplete

    if (( CLEANUP_DONE == 1 )); then
        return 0
    fi
    CLEANUP_DONE=1

    if (( RUN_EPOCH > 0 )); then
        if (( RUN_COMPLETION_READY == 1 && exit_code == 0 )); then receipt_status=complete; fi
        if ! write_monitor_receipt "$receipt_status" "$exit_code"; then
            log "STATE" "ERROR" "Unable to persist monitor completion receipt"
            (( exit_code != 0 )) || exit_code=1
        fi
    fi

    if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
        rm -rf -- "$RUN_DIR" 2>/dev/null || true
    fi

    if (( exit_code == 0 )); then
        log "RUN" "INFO" "Health monitoring completed"
    else
        log "RUN" "ERROR" "Health monitoring exited with status $exit_code"
    fi
    return "$exit_code"
}

handle_signal() {
    local signal_name="$1"
    local exit_code=143

    [[ "$signal_name" == "INT" ]] && exit_code=130
    log "RUN" "WARN" "Received $signal_name; stopping"
    exit "$exit_code"
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------

set_notification_outcome() {
    RECEIPT_NOTIFICATION_OUTCOME_RESULT="not_evaluated"

    (( NOTIFICATION_PHASE_REACHED == 1 )) || return 0
    if [[ "$NOTIFICATION_DECISION" == "SUPPRESS" ]]; then
        RECEIPT_NOTIFICATION_OUTCOME_RESULT="suppressed"
    elif (( NOTIFICATION_DRY_RUN == 1 )); then
        RECEIPT_NOTIFICATION_OUTCOME_RESULT="dry_run"
    elif (( NOTIFICATION_DELIVERY_ATTEMPTS > 0 && NOTIFICATION_DELIVERY_RC == 0 )); then
        RECEIPT_NOTIFICATION_OUTCOME_RESULT="delivered"
    else
        RECEIPT_NOTIFICATION_OUTCOME_RESULT="failed"
    fi
}

# ---------------------------------------------------------------------------
# Retention
# ---------------------------------------------------------------------------

# Trim old run logs under LOG_DIR to keep history bounded
prune_old_run_logs() {
    (( LOG_PRUNE_ENABLED == 1 )) || return 0
    local patterns=("disk_health_*.log")
    local removed=0
    local removed_age=0
    local removed_count=0
    local examined=0
    for pat in "${patterns[@]}"; do
        # Age-based pruning (mtime exceeding LOG_MAX_DAYS)
        if (( LOG_MAX_DAYS > 0 )); then
            while IFS= read -r f; do
                [[ -f "$f" ]] || continue
                ((examined++)) || true
                rm -f -- "$f" && ((removed++)) && ((removed_age++)) || true
            done < <(find "$LOG_DIR" -maxdepth 1 -type f -name "$pat" -mtime +$LOG_MAX_DAYS 2>/dev/null)
        fi
        # Count-based pruning (oldest first until within limit)
        if (( LOG_MAX_COUNT > 0 )); then
            mapfile -t files < <(find "$LOG_DIR" -maxdepth 1 -type f -name "$pat" -printf '%T@\t%p\n' 2>/dev/null | sort -n | awk -F'\t' '{print $2}')
            while (( ${#files[@]} > LOG_MAX_COUNT )); do
                local oldest="${files[0]}"
                rm -f -- "$oldest" && ((removed++)) && ((removed_count++)) || true
                files=("${files[@]:1}")
            done
            if (( LOG_MAX_COUNT > 0 )); then
                log_info "Run log pruning: pattern = $pat retained = ${#files[@]} (limit = $LOG_MAX_COUNT)"
            fi
        fi
    done
    # Emit summary if any deletions occurred
    log_info "Run log pruning: removed_total = $removed age = $removed_age count = $removed_count examined = $examined"
}

# === Helper Function ===
# Prune history/state growth files by age and line count (first column date YYYY-MM-DD)
prune_history_files() {
    (( HISTORY_PRUNE_ENABLED == 1 )) || return 0
    local max_days=${HISTORY_MAX_DAYS:-0} max_lines=${HISTORY_MAX_LINES:-0}
    local cutoff="" cutoff_epoch=0 today
    today=$(date '+%Y-%m-%d')
    if (( max_days > 0 )); then
        cutoff=$(date -d "-${max_days} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
        cutoff_epoch=$(date -d "$cutoff 00:00:00" +%s 2>/dev/null || echo 0)
    fi
    local files=(
        "$IO_ERROR_HISTORY_FILE" "$BTRFS_DEV_HIST_FILE"  "$SMART_ATTR_HISTORY_FILE" "$TEMP_HISTORY_FILE" "$TBW_HISTORY_FILE" "$SATA_LINK_HISTORY_FILE" "$REPLACEMENT_EVENTS_FILE"
    )
    local f retain_days file_cutoff file_epoch
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        retain_days=0
        case "$f" in
            "$TEMP_HISTORY_FILE") retain_days=$(( ${TEMP_TREND_WINDOW_DAYS:-14} + 7 )) ;;
            "$TBW_HISTORY_FILE") retain_days=$(( HISTORY_WINDOW_DAYS + 7 )) ;;
            "$SMART_ATTR_HISTORY_FILE") retain_days=$((  + 14 )) ;;
            "$SATA_LINK_HISTORY_FILE") retain_days=$(( SATA_LINK_INSTABILITY_WINDOW_DAYS + 7 )) ;;
        esac
        file_cutoff="$cutoff"; file_epoch="$cutoff_epoch"
        if (( retain_days > 0 && max_days > 0 )); then
            file_cutoff=$(date -d "-$retain_days days" '+%Y-%m-%d') || continue
            file_epoch=$(date -d "$file_cutoff 00:00:00" +%s) || continue
        fi
        local filtered final_file line_count
        filtered="$(state_temp_file "$f")" || continue
        final_file="$(state_temp_file "$f")" || {
            rm -f -- "$filtered" 2>/dev/null || true
            continue
        }

        # Date-led analytics rows and epoch-led I/O-event rows are both valid.
        # Anything else is malformed history and is removed during staging.
        if ! awk -v c="$file_cutoff" -v ce="$file_epoch" -v prune_age="$max_days" '
            /^#/ { print; next }
            $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
                if (!prune_age || $1 >= c) print
                next
            }
            $1 ~ /^[0-9]+$/ {
                if (!prune_age || $1 >= ce) print
                next
            }
        ' "$f" > "$filtered" 2>/dev/null
        then
            rm -f -- "$filtered" "$final_file" 2>/dev/null || true
            log "HISTORY" "WARN" "Unable to stage history pruning: $f"
            continue
        fi

        line_count=$(wc -l < "$filtered" 2>/dev/null || echo 0)
        if (( max_lines > 0 && line_count > max_lines )); then
            if ! tail -n "$max_lines" "$filtered" > "$final_file" 2>/dev/null; then
                rm -f -- "$filtered" "$final_file" 2>/dev/null || true
                log "HISTORY" "WARN" "Unable to apply history line limit: $f"
                continue
            fi
        else
            if ! cp -p -- "$filtered" "$final_file" 2>/dev/null; then
                rm -f -- "$filtered" "$final_file" 2>/dev/null || true
                log "HISTORY" "WARN" "Unable to stage retained history: $f"
                continue
            fi
        fi
        rm -f -- "$filtered" 2>/dev/null || true
        atomic_commit "$final_file" "$f" || true
    done
}

# === Helper Functions ===
# Caching wrappers for external commands to minimize repeated calls
declare LSBLK_ALL_CACHE=""
declare -A BTRFS_DF_CACHE_DATA=() BTRFS_DF_CACHE_META=()
cache_lsblk_all() {
    if [[ -z "$LSBLK_ALL_CACHE" ]]; then
        LSBLK_ALL_CACHE="$(lsblk_bounded -b -dn -o NAME,SIZE,ROTA,TYPE 2>/dev/null || true)"
    fi
}
lsblk_size_cached() {
    local dev="$1" source="$LSBLK_ALL_CACHE"
    [[ -n "$source" ]] || source="$(lsblk_bounded -b -dn -o NAME,SIZE,ROTA,TYPE 2>/dev/null || true)"
    awk -v d="${dev##*/}" '$1==d{print $2; exit}' <<<"$source"
}
lsblk_rota_cached() {
    local dev="$1" source="$LSBLK_ALL_CACHE"
    [[ -n "$source" ]] || source="$(lsblk_bounded -b -dn -o NAME,SIZE,ROTA,TYPE 2>/dev/null || true)"
    awk -v d="${dev##*/}" '$1==d{print $3; exit}' <<<"$source"
}

# Read a SATA device's power state without intentionally waking it. The result
# is cached for the run so every SMART-related phase makes the same decision.
refresh_sata_power_state() {
    local disk="$1"
    local state="" probe="" rota=""

    [[ "$disk" == /dev/sd* ]] || return 0
    [[ -n "${SATA_POWER_STATE[$disk]:-}" ]] && return 0

    if command -v hdparm >/dev/null 2>&1; then
        state=$(hdparm_bounded -C "$disk" 2>/dev/null |
            awk -F: '/state is/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print tolower($2); exit}')
    fi

    case "$state" in
        standby|sleeping|sleep) SATA_POWER_STATE[$disk]="standby"; return 0 ;;
        active/idle|active|idle) SATA_POWER_STATE[$disk]="active"; return 0 ;;
    esac

    # smartctl -n exits before normal SMART access when a rotational device is
    # sleeping. This is a fallback for controllers not supported by hdparm.
    probe=$(smartctl_bounded_optional -n standby -i "$disk" 2>&1 || true)
    if printf '%s' "$probe" | grep -qiE 'device is in (standby|sleep)|standby mode|sleep mode'; then
        SATA_POWER_STATE[$disk]="standby"
        return 0
    fi
    if printf '%s' "$probe" | grep -qiE 'device model|model family|smart support|serial number'; then
        SATA_POWER_STATE[$disk]="active"
        return 0
    fi

    rota=$(lsblk_rota_cached "$disk" 2>/dev/null || true)
    if [[ "$rota" == "0" ]]; then
        SATA_POWER_STATE[$disk]="solid-state"
    else
        SATA_POWER_STATE[$disk]="unknown"
    fi
}

# Prepare a device for full SMART access. Return 1 when a rotational SATA disk
# is asleep (or its power state cannot be proven safe) and wake-up is disabled.
prepare_smart_access() {
    local disk="$1"
    local state

    [[ "$disk" == /dev/sd* ]] || return 0
    refresh_sata_power_state "$disk"
    state="${SATA_POWER_STATE[$disk]:-unknown}"

    case "$state" in
        active|solid-state) return 0 ;;
        standby|unknown)
            if (( SMART_ALLOW_SPINUP == 0 )); then
                return 1
            fi
            log "SMART" "INFO" "Wake-up permitted for $disk (power state: $state)"
            if command -v hdparm >/dev/null 2>&1; then
                hdparm_bounded -I "$disk" >/dev/null 2>&1 || true
            fi
            SATA_POWER_STATE[$disk]="active"
            return 0
            ;;
    esac

    return 0
}

retain_previous_smart_snapshot() {
    local disk="$1"
    local power_state="${2:-standby}"
    local previous_state="${PREV_ATTR["$disk|state"]:-OK}"
    local composite attr value message

    case "$previous_state" in
        OK|WARNING|CRITICAL) ;;
        *) previous_state="OK" ;;
    esac

    SMART_DEFERRED[$disk]="$power_state"
    SMART_STATE[$disk]="$previous_state"
    SMART_MSGS[$disk]="SMART collection and self-test deferred (${power_state}; automatic spin-up disabled)"

    # Preserve the previous attribute baseline so persistence and trend delta
    # calculations do not erase or reset a sleeping disk's last known values.
    for composite in "${!PREV_ATTR[@]}"; do
        [[ "$composite" == "$disk|"* ]] || continue
        attr="${composite#"$disk|"}"
        [[ "$attr" == "state" ]] && continue
        value="${PREV_ATTR[$composite]}"
        CUR_ATTR["$disk|$attr"]="$value"
    done

    message="Disk $disk remains ${power_state}; previous SMART state $previous_state retained"
    if [[ "$previous_state" == "CRITICAL" || "$previous_state" == "WARNING" ]]; then
        record_alert "$previous_state" "$NOTIFY_TITLE_SMART" "$message"
    fi

    log "SMART" "INFO" "Deferred live SMART collection and self-test for $disk (power state: $power_state)"
    record_collector_event DEFERRED "SMART $disk" "power_state=$power_state"
}

short_test_is_due() {
    local disk="$1"
    local interval_days="${SHORT_TEST_INTERVAL_DAYS:-0}"
    local last_epoch="${LAST_TEST_EPOCH[$disk]:-}"
    local last_date="${LAST_TEST[$disk]:-}"
    local now_epoch

    [[ "$interval_days" =~ ^[0-9]+$ ]] || return 1
    (( 10#$interval_days > 0 )) || return 1

    if [[ ! "$last_epoch" =~ ^[0-9]+$ && -n "$last_date" ]]; then
        last_epoch=$(date -d "$last_date" +%s 2>/dev/null || true)
    fi
    [[ "$last_epoch" =~ ^[0-9]+$ ]] || return 0

    now_epoch=$(date +%s)
    local today_day last_day
    today_day=$(date -d "$(date -d "@$now_epoch" +%F)" +%s) || return 1
    last_day=$(date -d "$(date -d "@$last_epoch" +%F)" +%s) || return 1
    (( today_day - last_day >= 10#$interval_days * 86400 ))
}

short_test_next_date() {
    local disk="$1"
    local last_epoch="${LAST_TEST_EPOCH[$disk]:-}"
    local last_date="${LAST_TEST[$disk]:-}"
    local interval_days="${SHORT_TEST_INTERVAL_DAYS:-0}"

    if [[ ! "$last_epoch" =~ ^[0-9]+$ && -n "$last_date" ]]; then
        last_epoch=$(date -d "$last_date" +%s 2>/dev/null || true)
    fi
    if [[ "$last_epoch" =~ ^[0-9]+$ && "$interval_days" =~ ^[0-9]+$ ]]; then
        date -d "$(date -d "@$last_epoch" +%F) +${interval_days} days" '+%Y-%m-%d 00:00' 2>/dev/null || true
    fi
}

mark_test_started() {
    local disk="$1"
    local test_kind="$2"
    local now_epoch

    now_epoch=$(date +%s)
    LAST_TEST[$disk]=$(date '+%Y-%m-%d')
    LAST_TEST_EPOCH[$disk]="$now_epoch"
    LAST_TEST_KIND[$disk]="$test_kind"
}

smartctl_cached() {
    local key cache_file temp_file device_arg device_key rc=0

    key="$(printf '%s\0' "$@" | cksum | awk '{print $1 "_" $2}')"
    device_arg="${!#}"
    device_key="$(safe_state_name "$device_arg")"
    cache_file="$SMART_CACHE_DIR/${device_key}_${key}.txt"

    if [[ ! -f "$cache_file" ]]; then
        temp_file="$(mktemp "$SMART_CACHE_DIR/.smartctl.XXXXXX")" || return 1
        if smartctl_bounded "$@" > "$temp_file" 2>&1; then
            rc=0
        else
            rc=$?
        fi
        if (( rc == 124 || rc == 137 )); then
            rm -f -- "$temp_file" 2>/dev/null || true
            return "$rc"
        fi
        if smartctl_exit_has_operational_failure "$rc"; then
            rm -f -- "$temp_file" 2>/dev/null || true
            return "$rc"
        fi
        if [[ ! -s "$temp_file" && $rc -ne 0 ]]; then
            record_collector_event FAILED "smartctl $device_arg" "empty_output rc=$rc"
            rm -f -- "$temp_file" 2>/dev/null || true
            return "$rc"
        fi
        mv -f -- "$temp_file" "$cache_file" || {
            rm -f -- "$temp_file" 2>/dev/null || true
            return 1
        }
    fi

    cat -- "$cache_file"
}

invalidate_smart_cache() {
    local disk="${1:-}"
    local disk_key=""

    if [[ -n "$SMART_CACHE_DIR" && -d "$SMART_CACHE_DIR" ]]; then
        if [[ -n "$disk" ]]; then
            disk_key="$(safe_state_name "$disk")"
            find "$SMART_CACHE_DIR" -maxdepth 1 -type f \
                -name "${disk_key}_*.txt" -delete 2>/dev/null || true
        else
            find "$SMART_CACHE_DIR" -maxdepth 1 -type f -delete 2>/dev/null || true
        fi
    fi
}
get_selftest_live() {
    local disk="$1"
    if [[ ! "$disk" =~ ^/dev/[A-Za-z0-9]+([p0-9]+)?$ ]]; then printf ""; return; fi
    if [[ $disk == /dev/nvme* ]]; then
        smartctl_bounded -l selftest -d nvme "$disk" 2>/dev/null || true
    else
        smartctl_bounded -l selftest "$disk" 2>/dev/null || true
    fi
}
get_capabilities_live() {
    local disk="$1"
    if [[ ! "$disk" =~ ^/dev/[A-Za-z0-9]+([p0-9]+)?$ ]]; then printf ""; return; fi
    if [[ $disk == /dev/nvme* ]]; then
        smartctl_bounded -c -d nvme "$disk" 2>/dev/null || true
    else
        smartctl_bounded -c "$disk" 2>/dev/null || true
    fi
}
btrfs_df_cached() {
    # Cache raw 'btrfs filesystem df' (pretty first, fallback) per mount
    local m="$1"; local key="$m"; if [[ -n "${BTRFS_DF_CACHE_DATA[$key]:-}" || -n "${BTRFS_DF_CACHE_META[$key]:-}" ]]; then return 0; fi
    local out_p out
    out_p=$(btrfs_bounded_optional filesystem df -p "$m" 2>/dev/null || true)
    if [[ -n "$out_p" ]]; then out="$out_p"; else out=$(btrfs_bounded filesystem df "$m" 2>/dev/null || true); fi
    BTRFS_DF_CACHE_DATA[$key]=$(printf "%s" "$out" | awk -F',' '/Data/ {gsub(/ /,"",$2); print $2; exit}')
    BTRFS_DF_CACHE_META[$key]=$(printf "%s" "$out" | awk -F',' '/Metadata/ {gsub(/ /,"",$2); print $2; exit}')
    BTRFS_DF_CACHE_DATA[$key]="${BTRFS_DF_CACHE_DATA[$key]:-UNKNOWN}"; BTRFS_DF_CACHE_META[$key]="${BTRFS_DF_CACHE_META[$key]:-UNKNOWN}"
}

# === Helper Function ===
# Send a notification through Unraid's notify script with severity
notify_unraid() {
    local title="$1"
    local body="$2"
    local sev="${3:-warning}"
    # Map severity to icon
    local icon="normal"
    case "$sev" in
        critical|CRITICAL) icon="alert" ;;
        warning|WARNING) icon="warning" ;;
        *) icon="normal" ;;
    esac
    local crit_count="${FINDING_CRITICAL_COUNT:-0}"
    local warn_count="${FINDING_WARNING_COUNT:-0}"
    local description="${NOTIFICATION_DESCRIPTION:-$title}"
    # Normalize body for cleaner presentation (collapse multiple blank lines)
    local body_norm
    body_norm=$(printf "%s\n" "$body" | awk '{sub(/[ \t]+$/, "")} NF{print; blank=0; next} !blank{print ""; blank=1}')
    if [[ ! -x "$NOTIFY_BIN" ]]; then
        log_warn "Unraid notification helper is unavailable: $NOTIFY_BIN"
        return 127
    fi

    log_info "Sending notification with $icon title '$title' (critical=$crit_count, warning=$warn_count)"
    body_norm="Status: $( [[ "$icon" == normal ]] && printf UPDATE || printf ATTENTION )"$'\n'"Summary: $description"$'\n\n'"Actions and findings:"$'\n'"$body_norm"
    run_bounded_checked "$NOTIFICATION_TIMEOUT_SECONDS" \
        "Unraid notification helper" \
        "$NOTIFY_BIN" -s "${title:-Disk Health Monitor}" \
        -d "$description" -m "$body_norm" -i "$icon"
}

# Keep an undelivered notification visible in syslog without treating that
# observability fallback as a successful Unraid GUI notification.
log_notification_fallback() {
    local title="$1" body="$2" rc=0

    if ! command -v logger >/dev/null 2>&1; then
        log_warn "Notification syslog fallback is unavailable; logger is missing"
        return 1
    fi
    run_bounded_checked "$NOTIFICATION_TIMEOUT_SECONDS" \
        "Syslog notification summary" logger -t "Disk Health Monitor" \
        "${title:-Disk Health Monitor}: delivery failed" || rc=$?
    run_bounded_checked "$NOTIFICATION_TIMEOUT_SECONDS" \
        "Syslog notification body" logger -t "Disk Health Monitor" \
        "$body" || rc=$?
    (( rc == 0 )) || log_warn \
        "Notification syslog fallback failed with exit $rc"
    return "$rc"
}

deliver_notification_with_retry() {
    local title="$1" body="$2" severity="$3"
    local attempt rc=1 delay="${NOTIFICATION_RETRY_INITIAL_DELAY_SECONDS:-0}"
    local maximum_delay="${NOTIFICATION_RETRY_MAX_DELAY_SECONDS:-0}"

    NOTIFICATION_DELIVERY_ATTEMPTS=0
    NOTIFICATION_DELIVERY_RC=1

    if [[ ! -x "$NOTIFY_BIN" ]]; then
        notify_unraid "$title" "$body" "$severity" || rc=$?
        NOTIFICATION_DELIVERY_ATTEMPTS=1
        NOTIFICATION_DELIVERY_RC="$rc"
        log_notification_fallback "$title" "$body" || true
        return "$rc"
    fi

    for (( attempt=1; attempt<=NOTIFICATION_MAX_ATTEMPTS; attempt++ )); do
        NOTIFICATION_DELIVERY_ATTEMPTS="$attempt"
        if notify_unraid "$title" "$body" "$severity"; then
            NOTIFICATION_DELIVERY_RC=0
            log "NOTIFY" "INFO" \
                "Notification delivered successfully on attempt $attempt"
            return 0
        else
            rc=$?
        fi
        NOTIFICATION_DELIVERY_RC="$rc"
        log "NOTIFY" "WARN" \
            "Notification attempt $attempt/$NOTIFICATION_MAX_ATTEMPTS failed with exit $rc"
        if (( attempt < NOTIFICATION_MAX_ATTEMPTS && delay > 0 )); then
            log "NOTIFY" "INFO" "Retrying notification in ${delay}s"
            sleep "$delay"
            delay=$((delay * 2))
            (( delay <= maximum_delay )) || delay="$maximum_delay"
        fi
    done

    log_notification_fallback "$title" "$body" || true
    return "$rc"
}

# === Helper Functions ===
# Classify one finding once. These globals are consumed immediately by
# record_alert(), avoiding a side-effecting helper inside command substitution.
classify_finding_metadata() {
    local title="$1"
    local body="$2"
    local lower_title="${title,,}"
    local lower_body="${body,,}"

    FINDING_CLASS_CATEGORY="general"
    FINDING_CLASS_SIGNAL="advisory"
    FINDING_CLASS_ACTION="Review the evidence and the related subsystem logs."

    case "$lower_title|$lower_body" in
        *"pending sectors"*|*"offline uncorrectable"*|*"reported uncorrectable"*|*"media integrity"*)
            FINDING_CLASS_CATEGORY="smart"
            FINDING_CLASS_SIGNAL="smart.media"
            FINDING_CLASS_ACTION="Back up immediately, run a long SMART test, and plan replacement if the condition remains."
            ;;
        *"reallocated"*)
            FINDING_CLASS_CATEGORY="smart"
            FINDING_CLASS_SIGNAL="smart.reallocation"
            FINDING_CLASS_ACTION="Monitor the counter trend and replace the drive if it continues to increase."
            ;;
        *"self-test"*)
            FINDING_CLASS_CATEGORY="smart"
            FINDING_CLASS_SIGNAL="smart.selftest"
            FINDING_CLASS_ACTION="Review the self-test log; back up and replace the drive after a failed long test."
            ;;
        *"end-to-end errors"*)
            FINDING_CLASS_CATEGORY="smart"
            FINDING_CLASS_SIGNAL="smart.end_to_end"
            FINDING_CLASS_ACTION="Back up the device and inspect both the drive and controller data path."
            ;;
        *"soft read error"*)
            FINDING_CLASS_CATEGORY="smart"
            FINDING_CLASS_SIGNAL="smart.soft_read"
            FINDING_CLASS_ACTION="Run a long SMART test and monitor whether the counter continues to rise."
            ;;
        *"read-only mode"*)
            FINDING_CLASS_CATEGORY="smart"
            FINDING_CLASS_SIGNAL="smart.read_only"
            FINDING_CLASS_ACTION="Clone or back up the data immediately and replace the NVMe device."
            ;;
        *"reliability degraded"*)
            FINDING_CLASS_CATEGORY="smart"
            FINDING_CLASS_SIGNAL="smart.reliability"
            FINDING_CLASS_ACTION="Back up the device and schedule replacement."
            ;;
        *"nvme error log"*)
            FINDING_CLASS_CATEGORY="smart"
            FINDING_CLASS_SIGNAL="smart.nvme_error_log"
            FINDING_CLASS_ACTION="Review NVMe logs and firmware, then monitor for continued growth."
            ;;
        "nvme critical warning|"*)
            FINDING_CLASS_CATEGORY="smart"
            FINDING_CLASS_SIGNAL="smart.critical_warning"
            FINDING_CLASS_ACTION="Back up immediately, decode the warning flags, and plan replacement for persistent critical conditions."
            ;;
        *"command timeout"*)
            FINDING_CLASS_CATEGORY="io"
            FINDING_CLASS_SIGNAL="io.command_timeout"
            FINDING_CLASS_ACTION="Inspect power, cabling, backplane, and controller logs."
            ;;
        *"udma crc"*|*"sata link instability"*)
            FINDING_CLASS_CATEGORY="io"
            FINDING_CLASS_SIGNAL="io.sata_link"
            FINDING_CLASS_ACTION="Reseat or replace the SATA cable and verify the controller/backplane link."
            ;;
        *"pcie correctable"*|*"pcie uncorrectable"*)
            FINDING_CLASS_CATEGORY="io"
            FINDING_CLASS_SIGNAL="io.pcie_link"
            FINDING_CLASS_ACTION="Inspect the PCIe slot or backplane, reseat the device, and verify cooling."
            ;;
        *"i/o errors unique"*)
            FINDING_CLASS_CATEGORY="io"
            FINDING_CLASS_SIGNAL="io.kernel"
            FINDING_CLASS_ACTION="Inspect cabling, power, controller logs, and the affected device before errors escalate."
            ;;
        *"unsafe shutdown"*|*"volatile memory backup"*)
            FINDING_CLASS_CATEGORY="io"
            FINDING_CLASS_SIGNAL="io.power"
            FINDING_CLASS_ACTION="Check UPS, PSU, firmware, and power stability before the counter grows further."
            ;;
        temp*|*"temperature"*|*" temp"*|*"thermal"*)
            FINDING_CLASS_CATEGORY="temperature"
            FINDING_CLASS_SIGNAL="thermal.exposure"
            FINDING_CLASS_ACTION="Improve airflow or cooling and reduce sustained I/O until temperature stabilizes."
            ;;
        *"write workload anomaly"*|*"array write anomaly"*)
            FINDING_CLASS_CATEGORY="workload"
            FINDING_CLASS_SIGNAL="workload.write_rate"
            FINDING_CLASS_ACTION="Confirm the writers and mover schedule, then correct unexpected write amplification or placement."
            ;;
        *"tbw"*|*"heavy writer"*)
            FINDING_CLASS_CATEGORY="endurance"
            FINDING_CLASS_SIGNAL="endurance.tbw"
            FINDING_CLASS_ACTION="Reduce write amplification, confirm backups, and plan the device refresh window."
            ;;
        *"nvme wear"*|*"available spare"*|*"ssd life remaining"*)
            FINDING_CLASS_CATEGORY="endurance"
            FINDING_CLASS_SIGNAL="endurance.wear"
            FINDING_CLASS_ACTION="Reduce write load and plan replacement before the remaining endurance is exhausted."
            ;;
        *"poh age"*|*"load cycle count"*)
            FINDING_CLASS_CATEGORY="lifecycle"
            FINDING_CLASS_SIGNAL="lifecycle.age"
            FINDING_CLASS_ACTION="Keep backups current and plan a proactive refresh based on trend and workload."
            ;;
        *"firmware reset"*|*"drive replacement"*)
            FINDING_CLASS_CATEGORY="lifecycle"
            FINDING_CLASS_SIGNAL="lifecycle.regression"
            FINDING_CLASS_ACTION="Verify device identity and firmware, then establish fresh SMART and filesystem baselines."
            ;;
        *"btrfs"*)
            FINDING_CLASS_CATEGORY="filesystem"
            FINDING_CLASS_SIGNAL="filesystem.btrfs"
            FINDING_CLASS_ACTION="Run or review a scrub, inspect device health and cabling, and back up before repair."
            ;;
        *"xfs"*)
            FINDING_CLASS_CATEGORY="filesystem"
            FINDING_CLASS_SIGNAL="filesystem.xfs"
            FINDING_CLASS_ACTION="Back up first, unmount during maintenance, and run an offline read-only XFS check."
            ;;
        *"capacity"*|*"storage warning"*|*"storage critical"*|*"storage validation"*)
            FINDING_CLASS_CATEGORY="capacity"
            FINDING_CLASS_SIGNAL="capacity.space"
            FINDING_CLASS_ACTION="Free space or expand capacity and verify share, cache, and mover settings."
            ;;
        *"parity"*)
            FINDING_CLASS_CATEGORY="parity"
            FINDING_CLASS_SIGNAL="parity.integrity"
            FINDING_CLASS_ACTION="Review the parity operation, SMART health, and cabling before a corrective check."
            ;;
        *"smart scheduling"*|*"smart test start failed"*)
            FINDING_CLASS_CATEGORY="maintenance"
            FINDING_CLASS_SIGNAL="maintenance.smart_test"
            FINDING_CLASS_ACTION="Review the scheduled test result on the next run."
            ;;
        *"smart"*)
            FINDING_CLASS_CATEGORY="smart"
            FINDING_CLASS_SIGNAL="smart.aggregate"
            FINDING_CLASS_ACTION="Review the device SMART evidence and keep a current backup."
            ;;
    esac
}

finding_code_for_alert() {
    local title="$1"
    local body="$2"
    local code="${title,,}"
    local discriminator=""

    code="${code//[!a-z0-9]/_}"
    while [[ "$code" == *__* ]]; do code="${code//__/_}"; done
    code="${code#_}"
    code="${code%_}"

    if [[ "$title" == "$NOTIFY_TITLE_SMART" ]]; then
        if [[ "${body,,}" == *"self-test"* ]]; then
            discriminator="selftest"
        elif [[ "${body,,}" == *"deferred"* || "${body,,}" == *"remains standby"* ]]; then
            discriminator="deferred"
        else
            discriminator="aggregate"
        fi
    fi

    case "$title" in
        "Btrfs Device"|"Btrfs Burst")
            if [[ "$body" =~ (read_io_errs|write_io_errs|flush_io_errs|corruption_errs|generation_errs) ]]; then
                discriminator="${BASH_REMATCH[1]}"
            fi
            ;;
        "Firmware Reset")
            if [[ "$body" == *"Power-On Hours"* ]]; then discriminator="poh"
            elif [[ "$body" == *"Percentage Used"* || "$body" == *"percent_used"* ]]; then discriminator="wear"
            fi
            ;;
        "XFS Alert")
            if [[ "$body" =~ Counter[[:space:]]+([A-Za-z0-9_]+) ]]; then
                discriminator="${BASH_REMATCH[1]}"
            fi
            ;;
        "SMART Trend")
            discriminator="$(printf '%s' "$body" | cksum | awk '{print $1}')"
            ;;
    esac

    FINDING_CODE_RESULT="${code:-finding}${discriminator:+_$discriminator}"
}

record_finding() {
    local severity="${1,,}"
    local category="$2"
    local signal="$3"
    local device="$4"
    local title="$5"
    local evidence="$6"
    local action="$7"
    local code="$8"
    local scope="${9:-global}"
    local mount_ref=""
    local pool_ref=""
    local id old_severity requested_severity should_log=0

    [[ "$severity" == "critical" ]] || severity="warning"
    requested_severity="$severity"
    if [[ -n "$device" ]]; then
        device="$(base_device "$device")"
        scope="device:${device:-unknown}"
    elif [[ "$scope" == global ]]; then
        mount_ref=$(printf '%s' "$evidence" | grep -Eo '/mnt/[A-Za-z0-9_.-]+' | head -n1 || true)
        if [[ -n "$mount_ref" ]]; then
            scope="mount:$mount_ref"
        elif [[ "$evidence" =~ Pool[[:space:]]+([A-Za-z0-9_.-]+) ]]; then
            pool_ref="${BASH_REMATCH[1]}"
            scope="pool:$pool_ref"
        fi
    fi

    id="$scope|$code"
    if [[ -z "${FINDING_SEEN[$id]:-}" ]]; then
        FINDING_SEEN[$id]=1
        FINDING_IDS+=("$id")
        should_log=1
    fi

    old_severity="${FINDING_SEVERITY[$id]:-}"
    if [[ "$old_severity" == "critical" && "$requested_severity" != "critical" ]]; then
        return 0
    elif [[ "$old_severity" == "warning" && "$severity" == "critical" ]]; then
        should_log=1
    fi

    FINDING_SEVERITY[$id]="$severity"
    FINDING_CATEGORY[$id]="$category"
    FINDING_SIGNAL[$id]="$signal"
    FINDING_DEVICE[$id]="$device"
    FINDING_SCOPE[$id]="$scope"
    FINDING_TITLE[$id]="$title"
    FINDING_EVIDENCE[$id]="$evidence"
    FINDING_ACTION[$id]="$action"

    if (( should_log == 1 )); then
        if [[ "$severity" == "critical" ]]; then
            log_crit "$title - $evidence"
        else
            log_warn "$title - $evidence"
        fi
    fi

    return 0
}

# Record one canonical finding. Repeated wording changes for the same device and
# condition update the evidence instead of adding another risk contribution.
record_alert() {
    local severity="$1"
    local title="$2"
    local body="$3"
    local device=""

    device=$(printf '%s' "$body" | grep -Eo '/dev/[A-Za-z0-9]+' | head -n1 || true)
    classify_finding_metadata "$title" "$body"
    finding_code_for_alert "$title" "$body"
    record_finding \
        "$severity" \
        "$FINDING_CLASS_CATEGORY" \
        "$FINDING_CLASS_SIGNAL" \
        "$device" \
        "$title" \
        "$body" \
        "$FINDING_CLASS_ACTION" \
        "$FINDING_CODE_RESULT"
}

# Return a stable category rank for deterministic report ordering.
finding_category_rank() {
    case "$1" in
        smart)       printf '10\n' ;;
        io)          printf '20\n' ;;
        filesystem)  printf '30\n' ;;
        temperature) printf '40\n' ;;
        endurance)   printf '50\n' ;;
        lifecycle)   printf '60\n' ;;
        workload)    printf '65\n' ;;
        capacity)    printf '70\n' ;;
        parity)      printf '80\n' ;;
        maintenance) printf '90\n' ;;
        monitoring)  printf '95\n' ;;
        *)           printf '99\n' ;;
    esac
}

# Emit canonical finding IDs in deterministic priority order: critical first,
# then category, scope, title, and stable ID.
emit_sorted_finding_ids() {
    local id severity_rank category_rank scope title device

    for id in "${FINDING_IDS[@]}"; do
        if [[ "${FINDING_SEVERITY[$id]:-warning}" == "critical" ]]; then
            severity_rank=0
        else
            severity_rank=1
        fi
        device="${FINDING_DEVICE[$id]:-}"
        category_rank="$(finding_category_rank "${FINDING_CATEGORY[$id]:-general}")"
        scope="${FINDING_SCOPE[$id]:-${id%%|*}}"
        title="${FINDING_TITLE[$id]:-Finding}"
        printf '%d\t%03d\t%02d\t%s\t%s\t%s\n' \
            "$severity_rank" 0 "$category_rank" \
            "$scope" "$title" "$id"
    done | LC_ALL=C sort -t $'\t' -k1,1n -k2,2n -k3,3n -k4,4 -k5,5 -k6,6 |
        cut -f6-
}

# Finalize canonical finding counts after all collectors and trend producers
# have completed. Rendering reads finding metadata directly.
finalize_finding_counts() {
    local id

    FINDING_CRITICAL_COUNT=0
    FINDING_WARNING_COUNT=0

    for id in "${FINDING_IDS[@]}"; do
        if [[ "${FINDING_SEVERITY[$id]:-warning}" == "critical" ]]; then
            FINDING_CRITICAL_COUNT=$((FINDING_CRITICAL_COUNT + 1))
        else
            FINDING_WARNING_COUNT=$((FINDING_WARNING_COUNT + 1))
        fi
    done
}

# === Helper Function ===
# Convert bytes to human readable units
human_readable() {
    local bytes=${1:-0}
    local KB=1000; local MB=$((KB*KB)); local GB=$((MB*KB)); local TB=$((GB*KB))
    if (( bytes < KB )); then printf "%d B" "$bytes"; return; fi
    if (( bytes < MB )); then awk -v b="$bytes" -v k="$KB" 'BEGIN{printf "%.2f KB", b/k}'; return; fi
    if (( bytes < GB )); then awk -v b="$bytes" -v m="$MB" 'BEGIN{printf "%.2f MB", b/m}'; return; fi
    if (( bytes < TB )); then awk -v b="$bytes" -v g="$GB" 'BEGIN{printf "%.2f GB", b/g}'; return; fi
    awk -v b="$bytes" -v t="$TB" 'BEGIN{printf "%.2f TB", b/t}'
}

# === Helper Function ===
# Normalize partition path to its base device (e.g., /dev/sda1 -> /dev/sda)
base_device() {
    local d="$1"
    if [[ ! "$d" =~ ^/dev/[A-Za-z0-9]+([p0-9]+)?$ ]]; then
        echo ""; return 0
    fi
    if [[ "$d" == /dev/nvme* ]]; then
        echo "$d" | sed -E 's/p[0-9]+$//'
    else
        echo "$d" | sed -E 's/[0-9]+$//'
    fi
}

# ---------------------------------------------------------------------------
# Pure parser helpers
# ---------------------------------------------------------------------------
# These helpers accept captured text and emit normalized values only. Normal
# monitoring and the built-in fixtures therefore exercise the same parsers
# without requiring the fixture suite to access a live disk or filesystem.

smart_labeled_field_value() {
    local output="$1"
    local wanted="$2"
    local mode="${3:-number}"

    printf '%s\n' "$output" | awk -F: -v wanted="$wanted" -v mode="$mode" '
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        function normalize(value) {
            value=trim(value)
            gsub(/[[:space:]]+/, " ", value)
            return tolower(value)
        }
        BEGIN { wanted_normalized=normalize(wanted) }
        {
            key=$1
            if (normalize(key) != wanted_normalized) next
            value=substr($0, index($0, ":") + 1)
            value=trim(value)
            if (mode == "text") {
                print value
            } else if (mode == "scalar") {
                split(value, fields, /[[:space:]]+/)
                scalar=fields[1]
                gsub(/,|%/, "", scalar)
                if (scalar ~ /^[0-9]+$/) {
                    sub(/^0+/, "", scalar)
                    if (scalar == "") scalar="0"
                    print scalar
                } else if (scalar ~ /^0[xX][0-9A-Fa-f]+$/) {
                    print scalar
                }
            } else if (match(value, /[0-9][0-9,]*/)) {
                number=substr(value, RSTART, RLENGTH)
                gsub(/,/, "", number)
                sub(/^0+/, "", number)
                if (number == "") number="0"
                print number
            }
            exit
        }
    '
}

ata_smart_attribute_value() {
    local output="$1"
    local selector="$2"
    local value_kind="${3:-raw}"
    local field=10

    [[ "$value_kind" == "normalized" ]] && field=4
    printf '%s\n' "$output" | awk -v selector="$selector" -v field="$field" '
        /^[[:space:]]*[0-9]+[[:space:]]/ {
            id=$1
            name=$2
            if (selector ~ /^[0-9]+$/) {
                if (id != selector) next
            } else if (name !~ "^(" selector ")$") {
                next
            }
            value=$field
            gsub(/,/, "", value)
            if (value ~ /^[0-9]+$/) {
                sub(/^0+/, "", value)
                if (value == "") value="0"
                print value
            }
            exit
        }
    '
}

ata_smart_attribute_row_count() {
    local output="$1"

    printf '%s\n' "$output" | awk \
        '/^[[:space:]]*[0-9]+[[:space:]]+[A-Za-z0-9_-]+[[:space:]]/ {count++} END {print count+0}'
}

ata_smart_output_is_complete() {
    local output="$1"
    local row_count poh

    row_count=$(ata_smart_attribute_row_count "$output")
    poh=$(ata_smart_attribute_value "$output" "Power_On_Hours|Power_On_Hours_and_Msec")
    [[ "$row_count" =~ ^[0-9]+$ ]] && (( row_count >= 5 )) && [[ "$poh" =~ ^[0-9]+$ ]]
}

nvme_smart_output_is_complete() {
    local output="$1"

    [[ -n "$(smart_labeled_field_value "$output" "Critical Warning" scalar)" ]] &&
    [[ -n "$(smart_labeled_field_value "$output" "Temperature" number)" ]] &&
    [[ -n "$(smart_labeled_field_value "$output" "Available Spare" number)" ]] &&
    [[ -n "$(smart_labeled_field_value "$output" "Available Spare Threshold" number)" ]] &&
    [[ -n "$(smart_labeled_field_value "$output" "Percentage Used" number)" ]] &&
    [[ -n "$(smart_labeled_field_value "$output" "Data Units Written" number)" ]] &&
    [[ -n "$(smart_labeled_field_value "$output" "Power On Hours" number)" ]] &&
    [[ -n "$(smart_labeled_field_value "$output" "Unsafe Shutdowns" number)" ]] &&
    [[ -n "$(smart_labeled_field_value "$output" "Media and Data Integrity Errors" number)" ]] &&
    [[ -n "$(smart_labeled_field_value "$output" "Error Information Log Entries" number)" ]]
}

scsi_smart_field_value() {
    local output="$1"
    local wanted="$2"

    printf '%s\n' "$output" | awk -v wanted="$wanted" '
        function canonical(number) {
            gsub(/,/, "", number)
            sub(/^0+/, "", number)
            return (number == "" ? "0" : number)
        }
        wanted == "health" && /^SMART Health Status:/ {
            value=$0
            sub(/^[^:]*:[[:space:]]*/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            exit
        }
        wanted == "temperature" && /^Current Drive Temperature:/ {
            value=$0
            sub(/^[^:]*:[[:space:]]*/, "", value)
            if (match(value, /[0-9][0-9,]*/))
                print canonical(substr(value, RSTART, RLENGTH))
            exit
        }
        wanted == "poh" && /Accumulated power on time/ {
            value=$0
            sub(/^.*hours:minutes[[:space:]]+/, "", value)
            split(value, parts, ":")
            if (parts[1] ~ /^[0-9][0-9,]*$/) print canonical(parts[1])
            exit
        }
        wanted == "grown_defects" && /^Elements in grown defect list:/ {
            value=$0
            sub(/^[^:]*:[[:space:]]*/, "", value)
            if (match(value, /[0-9][0-9,]*/))
                print canonical(substr(value, RSTART, RLENGTH))
            exit
        }
        wanted == "read_uncorrected" && /^read:/ {
            value=$NF
            if (value ~ /^[0-9][0-9,]*$/) print canonical(value)
            exit
        }
        wanted == "write_uncorrected" && /^write:/ {
            value=$NF
            if (value ~ /^[0-9][0-9,]*$/) print canonical(value)
            exit
        }
        wanted == "non_medium" && /^Non-medium error count:/ {
            value=$0
            sub(/^[^:]*:[[:space:]]*/, "", value)
            if (match(value, /[0-9][0-9,]*/))
                print canonical(substr(value, RSTART, RLENGTH))
            exit
        }
    '
}

scsi_smart_output_is_complete() {
    local output="$1"

    [[ -n "$(scsi_smart_field_value "$output" health)" ]] &&
    [[ -n "$(scsi_smart_field_value "$output" temperature)" ]] &&
    [[ -n "$(scsi_smart_field_value "$output" poh)" ]]
}

parse_btrfs_device_stats_text() {
    local text="$1"
    local line dev key value

    while IFS= read -r line; do
        dev=""; key=""; value=""
        if [[ "$line" =~ ^\[([^]]+)\]\.([^[:space:]]+)[[:space:]]+([0-9]+) ]]; then
            dev="${BASH_REMATCH[1]}"
            key="${BASH_REMATCH[2]}"
            value="${BASH_REMATCH[3]}"
        elif [[ "$line" =~ ^(/dev/[^:[:space:]]+):?[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9]+) ]]; then
            dev="${BASH_REMATCH[1]}"
            key="${BASH_REMATCH[2]}"
            value="${BASH_REMATCH[3]}"
        fi
        [[ -n "$dev" && -n "$key" && "$value" =~ ^[0-9]+$ ]] || continue
        printf '%s\t%s\t%s\n' "$dev" "$key" "$value"
    done <<< "$text"
}

syslog_line_is_disk_io_error() {
    local line="$1"

    [[ "$line" == *"Script aborted"* || "$line" == *"Disk I/O Alert"* ]] && return 1
    grep -qiE \
        'I/O error|blk_update_request|end_request|failed command: (READ|WRITE)|hard resetting link|link is slow to respond|exception Emask|md:.*disk[0-9]+.*(read|write) error' \
        <<< "$line"
}

extract_syslog_device_paths() {
    local line="$1" token slot path
    while IFS= read -r token; do
        case "$token" in
            sd*|nvme*) base_device "/dev/$token" ;;
            md*|disk*)
                slot="disk${token#md}"; slot="${slot%%p[0-9]*}"
                [[ "$token" == disk* ]] && slot="$token"
                [[ "$slot" != disk0 ]] || continue
                path="${MOUNT_TO_DEV[/mnt/$slot]:-slot:$slot}"
                printf '%s\n' "$path" ;;
        esac
    done < <(printf '%s\n' "$line" | tr -cs '[:alnum:]_' '\n' |
        grep -Ex 'sd[a-z]+[0-9]*|nvme[0-9]+n[0-9]+(p[0-9]+)?|md[0-9]+(p[0-9]+)?|disk[0-9]+' || true) |
        sed '/^$/d' | sort -u
}

parse_unraid_disk_devices_file() {
    local source="$1"

    [[ -r "$source" ]] || return 1
    awk -F= '
        tolower($1) ~ /^[[:space:]]*device[[:space:]]*$/ {
            value=$2
            gsub(/"/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            sub(/^\/dev\//, "", value)
            if (value ~ /^(sd[a-z]+|nvme[0-9]+n[0-9]+)$/) print value
        }
    ' "$source"
}

parse_smart_selftest_output() {
    local output="$1"
    local fallback_status="${2:-Self-test log not yet populated}"
    local line

    line=$(printf '%s\n' "$output" | awk '
        (($1 == "#" && $2 ~ /^[0-9]+$/) || $1 ~ /^[0-9]+$/) {print; exit}
    ')
    if [[ -z "$line" ]]; then
        printf '0|unknown|%s| |\n' "$fallback_status"
        return 0
    fi

    printf '%s\n' "$line" | awk '
        {
            if ($1 == "#") {
                number=$2
                first=3
            } else {
                number=$1
                first=2
            }
            status_start=0
            percent_at=0
            for (i=first; i<=NF; i++) {
                if ($i ~ /^[0-9]+%$/ && percent_at == 0) percent_at=i
                if (status_start == 0 &&
                    ($i ~ /^(Completed:?|Aborted:?|Interrupted:?|Cancelled:?|Fatal:?|Electrical:?|Servo:?|Read:?|Write:?|Unknown)$/ ||
                     ($i == "Self-test" && $(i+1) == "routine"))) status_start=i
            }
            if (status_start == 0) status_start=first+2
            if (status_start > NF) status_start=first

            type=""
            for (i=first; i<status_start; i++)
                type=type (type == "" ? "" : " ") $i
            if (type == "") type="unknown"

            status_end=(percent_at > status_start ? percent_at-1 : NF)
            status=""
            for (i=status_start; i<=status_end; i++)
                status=status (status == "" ? "" : " ") $i
            if (status == "") status="unknown"

            remaining=(percent_at > 0 ? $(percent_at) : "")
            lifetime=""
            if (percent_at > 0) {
                for (i=percent_at+1; i<=NF; i++) {
                    if ($i ~ /^[0-9]+$/) {lifetime=$i; break}
                }
            }
            printf "%s|%s|%s|%s|%s\n", number, type, status, lifetime, remaining
        }
    '
}

select_latest_long_selftest_line() {
    local output="$1"
    local type_regex="${2:-Extended|Long|Offline}"

    printf '%s\n' "$output" | awk -v type_regex="$type_regex" '
        $0 ~ type_regex && tolower($0) !~ /short/ &&
        (($1 == "#" && $2 ~ /^[0-9]+$/) || $1 ~ /^[0-9]+$/) {print; exit}
    '
}

# === Helper Function ===
# Return device model string using smartctl (cached when possible)
get_device_model() {
    local d identity
    d=$(base_device "$1")
    [[ -z "$d" ]] && echo "" && return 0
    # Model lookup uses smartctl and can wake a SATA HDD. Defer it along with
    # the rest of SMART collection when this run intentionally kept it asleep.
    [[ -n "${SMART_DEFERRED[$d]:-}" ]] && echo "" && return 0
    if [[ "$d" == /dev/nvme* ]]; then
        identity=$(smartctl_cached -i -d nvme "$d" 2>/dev/null) || return
    else
        identity=$(smartctl_cached -i "$d" 2>/dev/null) || return
    fi
    # Let smartctl finish before parsing so a short read cannot turn into
    # SIGPIPE and a spurious collector failure.
    awk '
        /^(Model Number|Device Model):/ && !model {sub(/^[^:]+:[[:space:]]*/, ""); model=$0}
        /^Model Family:/ && !family {sub(/^[^:]+:[[:space:]]*/, ""); family=$0}
        END {if (model) print model; else if (family) print family}
    ' <<< "$identity"
}

# === Helper Function ===
# Build optional model suffix for health alerts depending on toggle
model_suffix_for() {
    local dev="$1"
    local suffix=""
    if [[ -n "$dev" && -n "${SMART_DEFERRED[$dev]:-}" ]]; then
        printf '%s' "$suffix"
        return 0
    fi
    if (( ${ENABLE_MODEL_IN_ALERTS:-0} == 1 )) && [[ -n "$dev" ]]; then
        local mdl
        mdl="$(get_device_model "$dev" 2>/dev/null)"
        if [[ -n "$mdl" ]]; then suffix=" (Model: $mdl)"; fi
    fi
    printf "%s" "$suffix"
}

# === Helper Function ===
# Return device capacity in TB (decimal TB)
get_device_capacity_tb() {
    local d
    d=$(base_device "$1")
    [[ -z "$d" ]] && echo "0" && return 0
    local bytes
    bytes=$(lsblk_size_cached "$d")
    bytes=${bytes:-0}
    awk -v b="$bytes" 'BEGIN{printf "%.3f", b/1000000000000.0}'
}

# === Helper Function ===
# Read a SATA SMART raw attribute value by ID
get_sata_raw() {
    local d
    d=$(base_device "$1")
    [[ -z "$d" ]] && echo "" && return 0
    smartctl_cached -A "$d" 2>/dev/null || true
}

# === Helper Function ===
# Parse SATA device basic info from smartctl --info
get_sata_info() {
    local d
    d=$(base_device "$1")
    [[ -z "$d" ]] && echo "" && return 0
    smartctl_cached -i "$d" 2>/dev/null || true
}

# === Helper Function ===
# Read an NVMe SMART/health value by key
get_nvme_raw() {
    local d
    d=$(base_device "$1")
    [[ -z "$d" ]] && echo "" && return 0
    log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART attribute read (-a) on $d"
    smartctl_cached -a -d nvme "$d" 2>/dev/null || true
}

# === Helper Function ===
# Read extended NVMe statistics (device statistics & thermal/PCIe counters)
get_nvme_extended_raw() {
    local d
    d=$(base_device "$1")
    [[ -z "$d" ]] && echo "" && return 0
    log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe extended statistics read (-x) on $d"
    smartctl_cached -x -d nvme "$d" 2>/dev/null || true
}

# === Helper Function ===
# Lookup or estimate TBW endurance threshold for a device
tbw_threshold_tb_for_device() {
    # Map model hints to endurance (TB written per TB capacity); return empty if unknown
    local model="$1"; shift
    local cap="$1"; shift
    local per_tb=""
    # Evaluate configured TBW rules first
    if [[ -n "${TBW_MODEL_RULES:-}" ]]; then
        while IFS= read -r __rline; do
            [[ -z "$__rline" || "$__rline" =~ ^# ]] && continue
            local _regex="" _per="" _min="" _max=""
            IFS=';' read -r -a __parts <<< "$__rline"
            for __p in "${__parts[@]}"; do
                case "$__p" in
                    regex:*) _regex="${__p#regex:}" ;;
                    per_tb:*) _per="${__p#per_tb:}" ;;
                    cap_min:*) _min="${__p#cap_min:}" ;;
                    cap_max:*) _max="${__p#cap_max:}" ;;
                esac
            done
            [[ -z "$_regex" || -z "$_per" ]] && continue
            if echo "$model" | grep -qiE "$_regex"; then
                local _cap_ok=1
                if [[ -n "$_min" || -n "$_max" ]]; then
                    _cap_ok=0
                    if awk -v c="$cap" -v a="${_min:-0}" -v b="${_max:-9999}" 'BEGIN{exit !(c+0>=a+0 && c+0<=b+0)}'; then _cap_ok=1; fi
                fi
                if (( _cap_ok == 1 )); then per_tb="$_per"; break; fi
            fi
        done <<< "${TBW_MODEL_RULES}"
    fi
    [[ -z "$per_tb" ]] && { echo ""; return 0; }
    awk -v c="$cap" -v p="$per_tb" 'BEGIN{printf "%.0f", c*p}'
}

# === Helper Function ===
# Evaluate TBW thresholds through explicit globals so alert side effects remain
# in the current shell. Do not call this function through command substitution.
eval_tbw_state() {
    local disk="$1"
    local tbw_bytes="$2"
    local in_state="${3:-OK}"
    local model cap tbw_thresh consumed_pct

    TBW_EVAL_STATE="$in_state"
    TBW_EVAL_MESSAGES=()

    model=$(get_device_model "$disk")
    cap=$(get_device_capacity_tb "$disk")
    tbw_thresh=$(tbw_threshold_tb_for_device "$model" "$cap")

    if [[ -n "$tbw_thresh" && "$tbw_thresh" =~ ^[0-9]+$ ]]; then
        if [[ "$cap" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            consumed_pct=$(awk -v w="$tbw_bytes" -v th="$tbw_thresh" 'BEGIN{printf "%.0f", (w/(th*1000*1000*1000*1000))*100}')
        fi
        if [[ -n "$consumed_pct" && "$consumed_pct" =~ ^[0-9]+$ ]]; then
            CUR_ATTR["$disk|tbw_consumed_pct"]="$consumed_pct"
            if (( consumed_pct >= TBW_CONSUMED_CRIT )); then
                TBW_EVAL_STATE="CRITICAL"
                TBW_EVAL_MESSAGES+=("TBW consumed ${consumed_pct}% >= ${TBW_CONSUMED_CRIT}%")
                record_alert critical "TBW Consumed" "Disk $disk TBW consumed ${consumed_pct}% >= ${TBW_CONSUMED_CRIT}%"
                return 0
            elif (( consumed_pct >= TBW_CONSUMED_WARN )) && [[ $TBW_EVAL_STATE != CRITICAL ]]; then
                [[ $TBW_EVAL_STATE == OK ]] && TBW_EVAL_STATE="WARNING"
                TBW_EVAL_MESSAGES+=("TBW consumed ${consumed_pct}% >= ${TBW_CONSUMED_WARN}%")
                record_alert warning "TBW Consumed" "Disk $disk TBW consumed ${consumed_pct}% >= ${TBW_CONSUMED_WARN}%"
                return 0
            fi
        fi
        return 0

    fi
}

# === Device discovery and stable identity ===
# Choose the best /dev/disk/by-id name without accessing drive media.
best_by_id_for_device() {
    local disk="$1"
    local link resolved name rank best="" best_rank=99

    for link in /dev/disk/by-id/*; do
        [[ -L "$link" ]] || continue
        name="${link##*/}"
        [[ "$name" == *-part[0-9]* ]] && continue
        resolved=$(readlink -f -- "$link" 2>/dev/null || true)
        [[ "$resolved" == "$disk" ]] || continue

        case "$name" in
            wwn-*|nvme-eui.*|nvme-uuid.*) rank=1 ;;
            ata-*|nvme-*) rank=2 ;;
            scsi-*) rank=3 ;;
            usb-*) rank=4 ;;
            *) rank=5 ;;
        esac

        if (( rank < best_rank )) ||
           { (( rank == best_rank )) && [[ -z "$best" || "$name" < "$best" ]]; }
        then
            best="$name"
            best_rank=$rank
        fi
    done

    printf '%s' "$best"
}

register_device_identity() {
    local disk="$1"
    local wwn serial by_id component identity source fingerprint existing

    [[ -b "$disk" ]] || return 1
    [[ -n "${DEVICE_ID_BY_PATH[$disk]:-}" ]] && return 0

    wwn=$(lsblk_bounded -dn -o WWN "$disk" 2>/dev/null | awk '{$1=$1; print; exit}')
    serial=$(lsblk_bounded -dn -o SERIAL "$disk" 2>/dev/null | awk '{$1=$1; print; exit}')
    by_id=$(best_by_id_for_device "$disk")

    component=$(safe_state_name "$wwn")
    if [[ -n "$wwn" && "$component" =~ [1-9A-Fa-f] ]]; then
        identity="wwn_${component}"
        source="wwn"
    elif [[ -n "$by_id" ]]; then
        identity="byid_$(safe_state_name "$by_id")"
        source="by-id"
    elif [[ -n "$serial" ]]; then
        identity="serial_$(safe_state_name "$serial")"
        source="serial"
    else
        identity="path_$(safe_state_name "$disk")"
        source="path-fallback"
    fi

    existing="${DEVICE_PATH_BY_ID[$identity]:-}"
    if [[ -n "$existing" && "$existing" != "$disk" ]]; then
        fingerprint=$(printf '%s' "$disk|$wwn|$serial|$by_id" | cksum | awk '{print $1}')
        identity="${identity}_${fingerprint}"
        log "INVENTORY" "WARN" \
            "Duplicate device identity detected for $disk and $existing; using disambiguated key $identity"
    fi

    DEVICE_ID_BY_PATH[$disk]="$identity"
    DEVICE_PATH_BY_ID[$identity]="$disk"
    DEVICE_ID_SOURCE[$identity]="$source"

    if [[ "$source" == "path-fallback" ]]; then
        log "INVENTORY" "WARN" \
            "No WWN, by-id, or serial available for $disk; persistent identity falls back to its path"
    fi
}

discover_device_inventory() {
    local boot_src boot_root="" name type disk device_name temp_file identity source
    local -a candidates=()
    local -A seen=()

    DEVICE_ID_BY_PATH=()
    DEVICE_PATH_BY_ID=()
    DEVICE_ID_SOURCE=()
    DISCOVERED_DISKS=()
    DEVICE_INVENTORY_READY=0

    cache_lsblk_all
    while read -r name _size _rota type; do
        [[ "$type" == "disk" ]] || continue
        [[ "$name" =~ ^sd[a-z]+$ || "$name" =~ ^nvme[0-9]+n[0-9]+$ ]] || continue
        disk="/dev/$name"
        [[ -b "$disk" && -z "${seen[$disk]:-}" ]] || continue
        seen[$disk]=1
        candidates+=("$disk")
    done <<< "$LSBLK_ALL_CACHE"

    # Include devices explicitly assigned by Unraid even if a controller omits
    # useful TYPE metadata from lsblk.
    if [[ -r /var/local/emhttp/disks.ini ]]; then
        while IFS= read -r device_name; do
            device_name="${device_name#/dev/}"
            [[ "$device_name" =~ ^(sd[a-z]+|nvme[0-9]+n[0-9]+)$ ]] || continue
            disk="/dev/$device_name"
            [[ -b "$disk" && -z "${seen[$disk]:-}" ]] || continue
            seen[$disk]=1
            candidates+=("$disk")
        done < <(parse_unraid_disk_devices_file /var/local/emhttp/disks.ini 2>/dev/null)
    fi

    # Last-resort discovery for unusual lsblk/controller output.
    for disk in /dev/sd* /dev/nvme*n*; do
        [[ -b "$disk" ]] || continue
        name="${disk##*/}"
        [[ "$name" =~ ^sd[a-z]+$ || "$name" =~ ^nvme[0-9]+n[0-9]+$ ]] || continue
        [[ -z "${seen[$disk]:-}" ]] || continue
        seen[$disk]=1
        candidates+=("$disk")
    done

    boot_src=$(findmnt_bounded -n -o SOURCE /boot 2>/dev/null || true)
    if [[ -n "$boot_src" ]]; then
        boot_src=$(readlink -f -- "$boot_src" 2>/dev/null || printf '%s' "$boot_src")
    fi
    [[ -n "$boot_src" ]] && boot_root=$(base_device "$boot_src")

    mapfile -t DISCOVERED_DISKS < <(
        printf '%s\n' "${candidates[@]}" |
            awk 'NF' |
            sort -Vu
    )

    candidates=()
    for disk in "${DISCOVERED_DISKS[@]}"; do
        [[ -n "$boot_root" && "$disk" == "$boot_root" ]] && continue
        register_device_identity "$disk" || continue
        candidates+=("$disk")
    done
    DISCOVERED_DISKS=("${candidates[@]}")

    temp_file="$(state_temp_file "$DEVICE_ID_MAP_FILE")" || return 1
    for disk in "${DISCOVERED_DISKS[@]}"; do
        identity="${DEVICE_ID_BY_PATH[$disk]}"
        source="${DEVICE_ID_SOURCE[$identity]}"
        printf '%s %s source=%s\n' "$identity" "$disk" "$source" >> "$temp_file"
    done
    collector_atomic_commit "$temp_file" "$DEVICE_ID_MAP_FILE" || return 1
    DEVICE_INVENTORY_READY=1

    if (( ${#DISCOVERED_DISKS[@]} == 0 )); then
        log "INVENTORY" "WARN" "No non-boot SATA/SAS/NVMe disks were discovered"
    else
        log "INVENTORY" "INFO" \
            "Discovered ${#DISCOVERED_DISKS[@]} disk(s) with stable identity mapping"
    fi
}

persistent_device_key() {
    local device="$1"
    local base suffix identity

    [[ "$device" == /dev/* ]] || { printf '%s' "$device"; return 0; }
    base=$(base_device "$device")
    [[ -n "$base" ]] || { printf 'path_%s' "$(safe_state_name "$device")"; return 0; }
    # shellcheck disable=SC2295
    suffix="${device#$base}"
    identity="${DEVICE_ID_BY_PATH[$base]:-}"
    [[ -n "$identity" ]] || identity="path_$(safe_state_name "$base")"
    printf '%s%s' "$identity" "${suffix:+@$suffix}"
}

runtime_device_path() {
    local key="$1"
    local identity suffix="" base

    if [[ "$key" == /dev/* ]]; then
        printf '%s' "$key"
        return 0
    fi

    identity="${key%%@*}"
    [[ "$key" == *@* ]] && suffix="${key#*@}"
    base="${DEVICE_PATH_BY_ID[$identity]:-}"
    [[ -n "$base" ]] || return 1
    printf '%s%s' "$base" "$suffix"
}

persistent_seen_key() {
    local key="$1" device remainder
    if [[ "$key" == /dev/*'|'* ]]; then
        device="${key%%|*}"
        remainder="${key#*|}"
        printf '%s|%s' "$(persistent_device_key "$device")" "$remainder"
    else
        printf '%s' "$key"
    fi
}

runtime_seen_key() {
    local key="$1" identity remainder device
    [[ "$key" == *'|'* ]] || { printf '%s' "$key"; return 0; }
    identity="${key%%|*}"
    remainder="${key#*|}"
    if device=$(runtime_device_path "$identity"); then
        printf '%s|%s' "$device" "$remainder"
    else
        printf '%s' "$key"
    fi
}

migrate_device_identity_histories() {
    local current_version="" file temp_file disk identity legacy_name stable_name directory
    local migration_failed=0
    local -a files=(
        "$TEMP_HISTORY_FILE"
        "$SATA_LINK_HISTORY_FILE"
        "$REPLACEMENT_EVENTS_FILE"
        "$SMART_ATTR_HISTORY_FILE"
        "$TBW_HISTORY_FILE"
        "$BTRFS_DEV_HIST_FILE"
        "$BTRFS_DEV_PREV_FILE"
        "$IO_ERROR_HISTORY_FILE"
    )

    [[ -r "$DEVICE_ID_SCHEMA_FILE" ]] && read -r current_version < "$DEVICE_ID_SCHEMA_FILE" || true
    [[ "$current_version" == "$DEVICE_ID_SCHEMA_VERSION" ]] && return 0

    if (( ${#DISCOVERED_DISKS[@]} == 0 )); then
        log "STATE" "WARN" \
            "Deferring stable identity migration because no data disks were discovered"
        return 1
    fi

    log "STATE" "INFO" \
        "Migrating persisted device references to stable identity schema v$DEVICE_ID_SCHEMA_VERSION"

    for file in "${files[@]}"; do
        [[ -s "$file" ]] || continue
        temp_file="$(state_temp_file "$file")" || {
            migration_failed=1
            continue
        }
        cp -p -- "$file" "$temp_file" 2>/dev/null || {
            rm -f -- "$temp_file" 2>/dev/null || true
            migration_failed=1
            continue
        }

        for disk in "${DISCOVERED_DISKS[@]}"; do
            identity="${DEVICE_ID_BY_PATH[$disk]:-}"
            [[ -n "$identity" ]] || continue
            sed -E \
                -e "s#${disk}(p?[0-9]+)#${identity}@\\1#g" \
                -e "s#${disk}([^A-Za-z0-9]|$)#${identity}\\1#g" \
                "$temp_file" > "${temp_file}.next" 2>/dev/null || {
                    migration_failed=1
                    rm -f -- "${temp_file}.next" 2>/dev/null || true
                    break
                }
            mv -f -- "${temp_file}.next" "$temp_file" || {
                migration_failed=1
                break
            }
        done

        if (( migration_failed == 0 )); then
            collector_atomic_commit "$temp_file" "$file" || migration_failed=1
        else
            rm -f -- "$temp_file" "${temp_file}.next" 2>/dev/null || true
            break
        fi
    done

    # Migrate per-device cooldown and self-test filenames where a legacy file
    # exists. The file contents themselves remain unchanged.
    if (( migration_failed == 0 )); then
        for disk in "${DISCOVERED_DISKS[@]}"; do
            identity="${DEVICE_ID_BY_PATH[$disk]:-}"
            [[ -n "$identity" ]] || continue
            legacy_name=$(safe_state_name "$disk")
            stable_name=$(safe_state_name "$identity")

            for directory in "$UNSAFE_SDWN_STATE_DIR" "$CMD_TIMEOUT_STATE_DIR"; do
                if [[ -e "$directory/${legacy_name}.lastwarn" && ! -e "$directory/${stable_name}.lastwarn" ]]; then
                    mv -f -- "$directory/${legacy_name}.lastwarn" "$directory/${stable_name}.lastwarn" 2>/dev/null || true
                fi
            done

            if [[ -e "$SMART_SELFTEST_DIR/${disk##*/}.snapshot" && ! -e "$SMART_SELFTEST_DIR/${stable_name}.snapshot" ]]; then
                mv -f -- \
                    "$SMART_SELFTEST_DIR/${disk##*/}.snapshot" \
                    "$SMART_SELFTEST_DIR/${stable_name}.snapshot" 2>/dev/null || true
            fi
        done
    fi

    if (( migration_failed == 1 )); then
        log "STATE" "WARN" "Stable identity history migration was incomplete; it will retry next run"
        return 1
    fi

    collector_atomic_write_text \
        "$DEVICE_ID_SCHEMA_FILE" "${DEVICE_ID_SCHEMA_VERSION}"$'\n' || return 1
    write_state_schema_manifest "$DEVICE_ID_SCHEMA_VERSION" || return 1
    log "STATE" "INFO" "Stable identity history migration completed"
}

# Enumerate the inventory captured once by main().
get_all_disks() {
    if (( DEVICE_INVENTORY_READY == 0 )); then
        discover_device_inventory || true
    fi
    printf '%s\n' "${DISCOVERED_DISKS[@]}"
}

# === Helper Function ===
# Construct mapping from /mnt/diskX mountpoints to block devices using disks.ini / disk.cfg definitions
build_mount_device_map() {
    MOUNT_TO_DEV=()
    local ini="/var/local/emhttp/disks.ini" cfg="/boot/config/disk.cfg" src=""
    local slot type status device fstype
    if [[ -r "$ini" ]]; then
        while IFS='|' read -r slot type status device fstype; do
            [[ "$type" == Data && "$device" =~ ^[[:alnum:]_.-]+$ ]] || continue
            MOUNT_TO_DEV["/mnt/$slot"]="/dev/$device"
        done < <(unraid_assigned_slots "$ini")
        return 0
    fi
    if [[ -f "$ini" ]]; then src="$ini"; elif [[ -f "$cfg" ]]; then src="$cfg"; else return 0; fi
    # First pass: device fields
    while IFS=$'\t' read -r name dev; do
        [[ -z "$name" || -z "$dev" ]] && continue
        case "$name" in disk[0-9]*) MOUNT_TO_DEV["/mnt/$name"]="/dev/$dev";; esac
    done < <(awk -F= 'BEGIN{disk=""}
        /^\[disk[0-9]+\]/ {disk=$0; gsub(/^\[/, "", disk); gsub(/\]$/, "", disk); next}
        tolower($1)=="device" && disk!="" {val=$2; gsub(/"/, "", val); sub(/^[ \t]+/, "", val); sub(/[ \t]+$/, "", val); printf "%s\t%s\n", disk, val}' "$src" 2>/dev/null)
    # Second pass: id fields (by-id symlink resolution) filling missing entries
    while IFS=$'\t' read -r name idv; do
        [[ -z "$name" || -z "$idv" ]] && continue
        local mp="/mnt/$name"
        [[ -n "${MOUNT_TO_DEV[$mp]:-}" ]] && continue
        local resolved
        resolved=$(readlink -f "/dev/disk/by-id/$idv" 2>/dev/null || true)
        [[ -b "$resolved" ]] && MOUNT_TO_DEV["$mp"]="$resolved"
    done < <(awk -F= 'BEGIN{disk=""}
        /^\[disk[0-9]+\]/ {disk=$0; gsub(/^\[/, "", disk); gsub(/\]$/, "", disk); next}
        tolower($1)=="id" && disk!="" {val=$2; gsub(/"/, "", val); sub(/^[ \t]+/, "", val); sub(/[ \t]+$/, "", val); printf "%s\t%s\n", disk, val}' "$src" 2>/dev/null)
}

# === Helper Function ===
# Derive the active flag once from the cached parity snapshot.
derive_parity_activity() {
    local action_lc="${PARITY_ACTION:-}"
    local pos="${PARITY_POS:-}"
    local size="${PARITY_SIZE:-}"
    local remaining="${PARITY_REM:-}"
    local speed="${PARITY_SPEED_K:-}"

    PARITY_ACTIVE=0
    action_lc="${action_lc,,}"

    [[ -n "$action_lc" && "$action_lc" != "idle" ]] || return 0

    if [[ "$speed" =~ ^[0-9]+$ ]] && (( 10#$speed > 0 )); then
        PARITY_ACTIVE=1
    elif [[ "$remaining" =~ ^[0-9]+$ ]] && (( 10#$remaining > 0 )); then
        PARITY_ACTIVE=1
    elif [[ "$pos" =~ ^[0-9]+$ && "$size" =~ ^[0-9]+$ ]] &&
         (( 10#$pos > 0 && 10#$pos < 10#$size ))
    then
        PARITY_ACTIVE=1
    fi
}

# Keep empty fields and handle Unraid's quoted INI section names.
unraid_assigned_slots() {
    awk -F= '
        function emit() {
            if (slot ~ /^[[:alnum:]_.-]+$/ && type ~ /^(Data|Parity|Cache)$/ &&
                (device != "" || saved != "" || id != "" || (status != "" && status !~ /^DISK_NP/)))
                print slot "|" type "|" status "|" device "|" fstype
        }
        /^\[/ {
            emit()
            slot=$0; gsub(/[\[\]"\r]/, "", slot)
            type=status=device=fstype=saved=id=""
            next
        }
        { value=$2; gsub(/["\r]/, "", value) }
        $1=="type"   {type=value}
        $1=="status" {status=value}
        $1=="device" {device=value}
        $1=="fsType" {fstype=value}
        $1=="idSb"   {saved=value}
        $1=="id"     {id=value}
        END {emit()}
    ' "$1"
}

check_expected_storage() {
    local slots slot type status device fstype mount evidence
    case "$ARRAY_RUNTIME_STATE" in
        stopped)
            record_collector_event DEFERRED "Array topology" "array stopped"
            return 0
            ;;
        started) ;;
        *) return 1 ;;
    esac
    slots=$(unraid_assigned_slots /var/local/emhttp/disks.ini) || return 1
    [[ -n "$slots" ]] || return 1
    while IFS='|' read -r slot type status device fstype; do
        mount=""
        if [[ "$type" == Data || ( "$type" == Cache && -n "$fstype" ) ]]; then
            mount="/mnt/$slot"
        fi
        case "$status" in
            DISK_OK) evidence="" ;;
            *) evidence="Unraid reports ${status:-unknown status}" ;;
        esac
        if [[ -z "$evidence" && ( ! "$device" =~ ^[[:alnum:]_.-]+$ || ! -b "/dev/$device" ) ]]; then
            evidence="Assigned $type device is missing"
        fi
        if [[ -z "$evidence" && -n "$mount" ]] && ! mountpoint -q -- "$mount"; then
            evidence="Expected filesystem $mount is not mounted"
        fi
        if [[ -z "$evidence" ]]; then
            FRESH_STORAGE["slot:$slot"]=1
            continue
        fi
        record_finding critical storage storage.availability "" \
            "Assigned storage unavailable" "$slot: $evidence" \
            "Open Unraid Main, verify the slot and connections, and confirm backups before rebuilding." \
            "storage_unavailable" "slot:$slot"
    done <<< "$slots"
    ARRAY_TOPOLOGY_OBSERVED=1
    return 0
}

check_completed_parity() {
    local file="$1" rows stamp duration speed result errors action size epoch last="" recent=""
    local year month day clock
    [[ -e "$file" ]] || return 0
    [[ -r "$file" && -f "$file" ]] || return 1
    rows=$(tail -n 200 -- "$file") || return 1
    while IFS='|' read -r stamp duration speed result errors action size; do
        [[ "$result" == 0 && "$errors" =~ ^(0|[1-9][0-9]{0,14})$ ]] || continue
        [[ -z "$action" || "$action" == check || "$action" == 'check '* ]] || continue
        read -r year month day clock <<< "$stamp"
        [[ "$year" =~ ^[0-9]{4}$ && "$month" =~ ^[A-Za-z]{3}$ &&
           "$day" =~ ^[0-9]{1,2}$ && "$clock" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || continue
        epoch=$(LC_ALL=C date -d "$month $day $year $clock" +%s 2>/dev/null) || continue
        last="$stamp|$errors"
        if (( errors >= PARITY_SYNC_ERR_WARN && epoch >= MONITOR_LAST_COMPLETE_EPOCH )); then
            recent="$last"
        fi
    done <<< "$rows"
    [[ -n "$last" ]] || return 0
    PARITY_HISTORY_OBSERVED=1
    (( MONITOR_LAST_COMPLETE_EPOCH > 0 )) || recent=""
    IFS='|' read -r stamp errors <<< "${recent:-$last}"
    if (( errors >= PARITY_SYNC_ERR_WARN )); then
        local severity=warning
        (( errors < PARITY_SYNC_ERR_CRIT )) || severity=critical
        record_alert "$severity" "Completed Parity Check" \
            "Parity check completed $stamp with $errors sync errors. Review the history and disk or controller evidence."
    fi
}

# Populate global parity progress/validity variables once per run.
parity_state() {
    if (( PARITY_STATE_LOADED == 1 )); then
        [[ -n "${PARITY_VALID_FLAG:-}${PARITY_ACTION:-}" ]]
        return
    fi
    PARITY_STATE_LOADED=1

    PARITY_VALID_FLAG=""
    PARITY_ACTION=""
    PARITY_CORR=""
    PARITY_POS=""
    PARITY_SIZE=""
    PARITY_ERRS=""
    PARITY_SPEED_K=""
    PARITY_REM=""
    # Prefer var.ini sbClean
    local ini="/var/local/emhttp/var.ini"
    if [[ -r "$ini" ]]; then
        local sb
        ARRAY_RUNTIME_STATE=$(awk -F= 'tolower($1)=="mdstate" {gsub(/[" \r]/,"",$2); print tolower($2); exit}' "$ini")
        sb=$(awk -F= 'tolower($1)=="sbclean" {gsub(/"| |\r|\n/,"",$2); print tolower($2); exit}' "$ini" 2>/dev/null)
        case "$sb" in
            1|yes|true) PARITY_VALID_FLAG="1";;
            0|no|false) PARITY_VALID_FLAG="0";;
        esac
    fi
    # Fallback to mdcmd status
    local cmd="/usr/local/sbin/mdcmd" out
    [[ -x "$cmd" ]] || cmd="mdcmd"
    if command -v "$cmd" >/dev/null 2>&1; then
        out=$("$cmd" status 2>/dev/null | tr -d '\r') || out=""
        if [[ -n "$out" ]]; then
            local sb st act corr pos size errs spk rem resync
            sb=$(echo "$out" | awk -F= 'tolower($1)=="sbclean" {print tolower($2); exit}')
            st=$(echo "$out" | awk -F= 'tolower($1)=="mdstate" {print tolower($2); exit}')
            act=$(echo "$out" | awk -F= 'tolower($1)=="mdresyncaction" {print tolower($2); exit}')
            corr=$(echo "$out"| awk -F= 'tolower($1)=="mdresynccorr" {print $2; exit}')
            pos=$(echo "$out" | awk -F= 'tolower($1)=="mdresyncpos" {print $2; exit}')
            size=$(echo "$out"| awk -F= 'tolower($1)=="mdresyncsize" {print $2; exit}')
            errs=$(echo "$out"| awk -F= 'tolower($1)=="mdsyncerrs" {print $2; exit}')
            spk=$(echo "$out" | awk -F= 'tolower($1)=="mdresyncspeed" {print $2; exit}')
            rem=$(echo "$out" | awk -F= 'tolower($1)=="mdresyncrem" {print $2; exit}')
            [[ -z "$st" ]] || ARRAY_RUNTIME_STATE="$st"
            resync=$(echo "$out" | awk -F= 'tolower($1)=="mdresync" {print $2; exit}')
            if [[ -n "$sb" ]]; then
                case "$sb" in 1|yes|true) PARITY_VALID_FLAG="1";; 0|no|false) PARITY_VALID_FLAG="0";; esac
            fi
            PARITY_ACTION="$act"
            PARITY_CORR="$corr"
            PARITY_POS="$pos"
            PARITY_SIZE="$size"
            PARITY_ERRS="$errs"
            PARITY_SPEED_K="$spk"
            PARITY_REM="$rem"
            derive_parity_activity
            if [[ "$resync" =~ ^[0-9]+$ ]] && (( 10#$resync > 0 )); then PARITY_ACTIVE=1; fi
            return 0
        fi
    fi
    derive_parity_activity
    return 1
}

# === Main Function ===
# Evaluate current parity validity and errors without generating progress tables.
# shellcheck disable=SC2329
evaluate_live_parity() {
    [[ "$ARRAY_RUNTIME_STATE" == started ]] || return 0
    local errors="${PARITY_ERRS:-}"
    if (( PARITY_ACTIVE == 0 )); then
        case "${PARITY_VALID_FLAG:-}" in
            0)
                PARITY_RESULT_OBSERVED=1
                record_alert warning "Parity Status" "Parity invalid (sync required)"
                ;;
            1) PARITY_RESULT_OBSERVED=1 ;;
        esac
        return 0
    fi
    log "PARITY" "INFO" "Operation: ${PARITY_ACTION:-unknown}; position=${PARITY_POS:-unknown}/${PARITY_SIZE:-unknown}; errors=${errors:-unknown}"
    [[ "$errors" =~ ^(0|[1-9][0-9]{0,14})$ ]] || return 0
    if (( errors >= PARITY_SYNC_ERR_CRIT )); then
        record_alert critical "Parity Sync Errors" "Active parity operation has $errors sync errors."
    elif (( errors >= PARITY_SYNC_ERR_WARN )); then
        record_alert warning "Parity Sync Errors" "Active parity operation has $errors sync errors."
    fi
    return 0
}

# === Helper Function ===

# === Helper Function ===
# Resolve SMART-capable device for a given /mnt path
smart_device_for_mount() {
    local mp="$1"
    local dev="${MOUNT_TO_DEV[$mp]:-}"
    if [[ -n "$dev" && -b "$dev" ]]; then echo "$dev"; return 0; fi
    local src
    src=$(findmnt_bounded -n -o SOURCE "$mp" 2>/dev/null || true)
    echo "$src"
}

prepare_smart_baseline_inputs() {
    local file group
    if [[ ! -e "$SMART_BASELINES_FILE" && ! -L "$SMART_BASELINES_FILE" ]]; then
        for file in "$NVME_STATE_FILE" "$PREV_ATTR_FILE" "$CMD_TIMEOUT_LAST_FILE"; do
            validate_managed_file_target "$file" || return 1
            [[ ! -e "$file" || -r "$file" ]] || return 1
        done
        return 0
    fi

    validate_secure_owned_file "$SMART_BASELINES_FILE" || return 1
    for group in nvme smart command_timeout; do
        jq -er --arg group "$group" '
            def token: type == "string" and test("^[^[:space:]]+$");
            if .schema != 1 then error("unknown SMART baseline schema") else .[$group] end
            | if type != "object" then error("invalid SMART baseline group") else . end
            | [to_entries[] | .key as $id |
                if ($id|token|not) then error("invalid device key") else .value end
                | if $group == "command_timeout" then
                    if type != "string" or (test("^[0-9]+$")|not)
                    then error("invalid command timeout") else "\($id) \(.)" end
                  else
                    if type != "object" then error("invalid attribute map") else . end
                    | [$id, (to_entries[] |
                        if (.key|test("^[A-Za-z0-9_]+$")) and (.value|token)
                        then "\(.key)=\(.value)" else error("invalid SMART attribute") end)]
                    | join(" ")
                  end
            ] | join("\n")
        ' "$SMART_BASELINES_FILE" > "$RUN_DIR/baseline-$group" || {
            log "STATE" "ERROR" "Invalid SMART baseline JSON ($group); refusing to reset the counters"
            return 1
        }
    done
    nvme_input="$RUN_DIR/baseline-nvme"
    smart_input="$RUN_DIR/baseline-smart"
    timeout_input="$RUN_DIR/baseline-command_timeout"
}

load_persistent_state() {
    local disk date dev rest token k v line key poh cnt ts score stored_key
    local nvme_input="$NVME_STATE_FILE" smart_input="$PREV_ATTR_FILE" timeout_input="$CMD_TIMEOUT_LAST_FILE"
    prepare_smart_baseline_inputs || return 1

if [ -f "$SMART_LAST" ]; then
    while read -r stored_key date rest; do
        disk=$(runtime_device_path "$stored_key" 2>/dev/null || true)
        [[ -n "$disk" && -n "$date" ]] || continue
        LAST_TEST["$disk"]=$date
        for token in $rest; do
            k=${token%%=*}
            v=${token#*=}
            case "$k" in
                epoch) [[ "$v" =~ ^[0-9]+$ ]] && LAST_TEST_EPOCH["$disk"]="$v" ;;
                type) [[ -n "$v" ]] && LAST_TEST_KIND["$disk"]="$v" ;;
            esac
        done
        if [[ ! "${LAST_TEST_EPOCH[$disk]:-}" =~ ^[0-9]+$ ]]; then
            LAST_TEST_EPOCH["$disk"]=$(date -d "$date" +%s 2>/dev/null || true)
        fi
    done < "$SMART_LAST"
fi

if [ -f "$nvme_input" ]; then
    while read -r stored_key rest; do
        dev=$(runtime_device_path "$stored_key" 2>/dev/null || true)
        [[ -z "$dev" ]] && continue
        # Support legacy format: dev <unsafe_shutdowns>
        if [[ -z "$rest" ]]; then
            continue
        fi
        # Tokenize key=value pairs after the device name
        # Legacy single number (unsafe) support
        if [[ "$rest" =~ ^[0-9]+$ ]]; then
            NVME_LAST_UNSAFE["$dev"]="$rest"
            continue
        fi
        for token in $dev $rest; do
            # First token is device; skip
            [[ "$token" == "$dev" ]] && continue
            k=${token%%=*}
            v=${token#*=}
            [[ -z "$k" || -z "$v" ]] && continue
            case "$k" in
                unsafe) NVME_LAST_UNSAFE["$dev"]="$v";;
                errlog) NVME_LAST_ERRLOG["$dev"]="$v";;
                pc_corr) NVME_LAST_PCIE_CORR["$dev"]="$v";;
                pc_unc) NVME_LAST_PCIE_UNC["$dev"]="$v";;
                therm_t1) NVME_LAST_THERM_T1["$dev"]="$v";;
                therm_t2) NVME_LAST_THERM_T2["$dev"]="$v";;
                warn_temp_time) NVME_LAST_WARN_TEMP_TIME["$dev"]="$v";;
                crit_temp_time) NVME_LAST_CRIT_TEMP_TIME["$dev"]="$v";;
            esac
        done
    done < "$nvme_input"
fi

if [ -f "$smart_input" ]; then
    while read -r line; do
        [[ -z "$line" ]] && continue
        disk=""
        token=""
        stored_key=$(echo "$line" | awk '{print $1}')
        disk=$(runtime_device_path "$stored_key" 2>/dev/null || true)
        [[ -n "$disk" ]] || continue
        for token in $(echo "$line" | awk '{for(i=2;i<=NF;i++) print $i}'); do
            k=""; v=""
            k=${token%%=*}; v=${token#*=}
            [[ -n "$k" ]] && PREV_ATTR["$disk|$k"]="$v"
        done
    done < "$smart_input"
fi

if [ -f "$ALERT_NEW_SEEN_FILE" ]; then
    while IFS= read -r key; do
        key=$(runtime_seen_key "$key")
        [[ -n "$key" ]] && NEW_SEEN["$key"]=1
    done < "$ALERT_NEW_SEEN_FILE"
fi

# Load persisted last long self-test lifetime hours
if [ -f "$SMART_LONG_LAST_POH_FILE" ]; then
    while read -r stored_key poh; do
        disk=$(runtime_device_path "$stored_key" 2>/dev/null || true)
        [[ -z "$disk" || -z "$poh" ]] && continue
        [[ "$poh" =~ ^[0-9]+$ ]] || continue
        LONG_LAST_POH["$disk"]="$poh"
    done < "$SMART_LONG_LAST_POH_FILE"
fi

# Load previous Command_Timeout counts for delta alerts
if [ -f "$timeout_input" ]; then
    while read -r stored_key cnt; do
        disk=$(runtime_device_path "$stored_key" 2>/dev/null || true)
        [[ -z "$disk" || -z "$cnt" ]] && continue
        [[ "$cnt" =~ ^[0-9]+$ ]] || continue
        CMD_TIMEOUT_LAST["$disk"]="$cnt"
    done < "$timeout_input"
fi

}

# === Helper Function ===
# Persist actual SMART test-start metadata for a device
save_last_test() {
    local temp_file disk state_key
    temp_file="$(state_temp_file "$SMART_LAST")" || return 1
    for disk in "${!LAST_TEST[@]}"; do
        state_key=$(persistent_device_key "$disk")
        printf '%s %s epoch=%s type=%s\n' \
            "$state_key" \
            "${LAST_TEST[$disk]}" \
            "${LAST_TEST_EPOCH[$disk]:-0}" \
            "${LAST_TEST_KIND[$disk]:-unknown}" >> "$temp_file" || return 1
    done
    atomic_commit "$temp_file" "$SMART_LAST"
}

# === Helper Function ===
# Persist last-run NVMe health snapshot for a device
save_nvme_state() {
    local target="$1"
    local temp_file dev line state_key
    temp_file="$(state_temp_file "$target")" || return 1
    for dev in "${!NVME_LAST_UNSAFE[@]}"; do
        state_key=$(persistent_device_key "$dev")
        line="$state_key unsafe=${NVME_LAST_UNSAFE[$dev]:-0}"
        line+=" errlog=${NVME_LAST_ERRLOG[$dev]:-0}"
        line+=" pc_corr=${NVME_LAST_PCIE_CORR[$dev]:-0}"
        line+=" pc_unc=${NVME_LAST_PCIE_UNC[$dev]:-0}"
        line+=" therm_t1=${NVME_LAST_THERM_T1[$dev]:-0}"
        line+=" therm_t2=${NVME_LAST_THERM_T2[$dev]:-0}"
        line+=" warn_temp_time=${NVME_LAST_WARN_TEMP_TIME[$dev]:-0}"
        line+=" crit_temp_time=${NVME_LAST_CRIT_TEMP_TIME[$dev]:-0}"
        printf '%s\n' "$line" >> "$temp_file" || return 1
    done
    atomic_commit "$temp_file" "$target"
}

# === Helper Function ===
# Persist last observed long self-test lifetime hours per disk
save_long_last_poh() {
    local temp_file disk state_key
    temp_file="$(state_temp_file "$SMART_LONG_LAST_POH_FILE")" || return 1
    for disk in "${!LONG_LAST_POH[@]}"; do
        state_key=$(persistent_device_key "$disk")
        printf '%s %s\n' "$state_key" "${LONG_LAST_POH[$disk]}" >> "$temp_file" || return 1
    done
    atomic_commit "$temp_file" "$SMART_LONG_LAST_POH_FILE"
}

# === Helper Function ===
# Persist last observed Command_Timeout counts per disk
save_cmd_timeout_last() {
    local target="$1"
    local temp_file disk state_key
    temp_file="$(state_temp_file "$target")" || return 1
    for disk in "${!CMD_TIMEOUT_LAST[@]}"; do
        state_key=$(persistent_device_key "$disk")
        printf '%s %s\n' "$state_key" "${CMD_TIMEOUT_LAST[$disk]}" >> "$temp_file" || return 1
    done
    atomic_commit "$temp_file" "$target"
}

# Use model-aware age thresholds for replacement planning without elevating
# SMART health or opening a notification incident.

# SCSI devices expose labeled counters instead of ATA attribute IDs.
evaluate_scsi_smart() {
    local disk="$1"
    local output="$2"
    local ctx="${3:-}"
    local previous_state="${SMART_STATE[$disk]:-}"
    local previous_messages="${SMART_MSGS[$disk]:-}"
    local health temperature poh grown_defects read_uncorrected write_uncorrected non_medium
    local total_uncorrected state="OK" joined="" message
    local -a messages=()

    health=$(scsi_smart_field_value "$output" health)
    temperature=$(scsi_smart_field_value "$output" temperature)
    poh=$(scsi_smart_field_value "$output" poh)
    grown_defects=$(scsi_smart_field_value "$output" grown_defects)
    read_uncorrected=$(scsi_smart_field_value "$output" read_uncorrected)
    write_uncorrected=$(scsi_smart_field_value "$output" write_uncorrected)
    non_medium=$(scsi_smart_field_value "$output" non_medium)
    grown_defects=${grown_defects:-0}
    read_uncorrected=${read_uncorrected:-0}
    write_uncorrected=${write_uncorrected:-0}
    non_medium=${non_medium:-0}
    total_uncorrected=$(( read_uncorrected + write_uncorrected ))

    if ! grep -qiE '^(OK|PASSED)$' <<< "$health"; then
        state="CRITICAL"
        messages+=("SAS SMART health status: ${health:-unknown}")
        record_alert critical "SMART SAS Health" \
            "Disk $disk SAS SMART health status is ${health:-unknown}"
    fi
    if (( total_uncorrected > 0 )); then
        state="CRITICAL"
        messages+=("SAS uncorrected read/write errors = $total_uncorrected")
        record_alert critical "SMART SAS Uncorrected" \
            "Disk $disk SAS uncorrected read/write errors = $total_uncorrected"
    fi
    if (( grown_defects > 0 )); then
        [[ "$state" == "OK" ]] && state="WARNING"
        messages+=("SAS grown defect list = $grown_defects")
        record_alert warning "SMART SAS Grown Defects" \
            "Disk $disk SAS grown defect list = $grown_defects"
    fi
    if (( non_medium > 0 )); then
        [[ "$state" == "OK" ]] && state="WARNING"
        messages+=("SAS non-medium errors = $non_medium")
        record_alert warning "SMART SAS Non-Medium Errors" \
            "Disk $disk SAS non-medium errors = $non_medium"
    fi
    if (( temperature >= HDD_TEMP_CRITICAL )); then
        state="CRITICAL"
        messages+=("SAS HDD Temp ${temperature}C >= ${HDD_TEMP_CRITICAL}C")
        record_alert critical "Temp" \
            "Disk $disk SAS HDD Temp ${temperature}C >= ${HDD_TEMP_CRITICAL}C"
    elif (( temperature >= HDD_TEMP_WARNING )); then
        [[ "$state" == "OK" ]] && state="WARNING"
        messages+=("SAS HDD Temp ${temperature}C >= ${HDD_TEMP_WARNING}C")
        record_alert warning "Temp" \
            "Disk $disk SAS HDD Temp ${temperature}C >= ${HDD_TEMP_WARNING}C"
    fi

    CUR_ATTR["$disk|realloc"]="$grown_defects"
    CUR_ATTR["$disk|pending"]=0
    CUR_ATTR["$disk|offunc"]="$total_uncorrected"
    CUR_ATTR["$disk|reported_uncorr"]="$total_uncorrected"
    CUR_ATTR["$disk|cmd_timeout"]=0
    CUR_ATTR["$disk|realloc_events"]="$grown_defects"
    CUR_ATTR["$disk|end2end"]=0
    CUR_ATTR["$disk|soft_read_err"]=0
    CUR_ATTR["$disk|udma"]=0
    CUR_ATTR["$disk|lcc"]=0
    CUR_ATTR["$disk|temp"]="$temperature"
    CUR_ATTR["$disk|poh"]="$poh"

    local sample_date sample_key sample_record
    sample_date=$(date '+%Y-%m-%d')
    sample_key=$(persistent_device_key "$disk")
    sample_record="$sample_date $sample_key temp=$temperature captured_epoch=$RUN_EPOCH schema=$HISTORY_SCHEMA_VERSION"
    collector_upsert_daily_history \
        "$TEMP_HISTORY_FILE" "$sample_date" "$sample_key" "$sample_record" || true

    local selftest_info selftest_class selftest_severity selftest_message
    selftest_info=$(get_latest_selftest_info "$disk")
    selftest_class=$(classify_selftest_status "$(printf '%s' "$selftest_info" | awk -F'|' '{print $3}')")
    selftest_severity=${selftest_class%%|*}
    selftest_message=${selftest_class#*|}
    CUR_ATTR["$disk|selftest_status"]="$selftest_severity"
    CUR_ATTR["$disk|selftest_msg"]="$selftest_message"
    if [[ "$selftest_severity" == "CRITICAL" ]]; then
        state="CRITICAL"
        messages+=("Self-test critical: $selftest_message")
    elif [[ "$selftest_severity" == "WARNING" && "$state" != "CRITICAL" ]]; then
        [[ "$state" == "OK" ]] && state="WARNING"
        messages+=("Self-test warning: $selftest_message")
    fi

    for message in "${messages[@]}"; do
        [[ -z "$joined" ]] || joined+="; "
        joined+="$message"
    done
    SMART_STATE["$disk"]="$state"
    SMART_MSGS["$disk"]="$joined"
    if [[ "$ctx" != "post-test" || "$previous_state" != "$state" ||
          "$previous_messages" != "$joined" ]]
    then
        log_smart "SMART state${ctx:+ ($ctx)} $disk: $state"
        for message in "${messages[@]}"; do
            log_smart "SMART detail $disk: $message"
        done
    fi
}

# === Main Function ===
# Collect SMART data, classify device health, and raise alerts
# Only host counters with explicit units are converted. NAND writes are a different
# metric; raw IDs 241/242 vary by vendor and must never imply 512-byte sectors.
ata_host_counter_bytes() {
    local text="$1" direction="$2" name value multiplier
    case "$direction" in
        writes) name='Host_Writes_GiB|Host_Writes_32MiB|Total_LBAs_Written' ;;
        reads) name='Host_Reads_GiB|Host_Reads_32MiB|Total_LBAs_Read' ;;
        *) return 1 ;;
    esac
    local row
    row=$(awk -v names="$name" '$1 ~ /^[0-9]+$/ && $2 ~ "^(" names ")$" {print $2, $10; exit}' <<< "$text")
    read -r name value <<< "$row"
    [[ "$value" =~ ^[0-9]{1,15}$ ]] || return 1
    case "$name" in
        *_GiB) multiplier=1073741824 ;;
        *_32MiB) multiplier=33554432 ;;
        Total_LBAs_*) multiplier=512 ;;
        *) return 1 ;;
    esac
    # Exact integer text, avoiding signed shell arithmetic overflow.
    awk -v value="$value" -v unit="$multiplier" 'BEGIN {printf "%.0f\n", value*unit}'
}

# v3 recalculates ATA writes in documented units. Ignore old-unit history for that
# device until its new baseline is persisted; preserve all physical fault counters.
rebaseline_ata_host_writes() {
    local disk="$1" key tmp
    CUR_ATTR["$disk|host_write_units_revision"]=2
    [[ "${PREV_ATTR["$disk|host_write_units_revision"]:-0}" == 2 ]] && return 0
    key=$(persistent_device_key "$disk") || return 1
    tmp=$(state_temp_file "$TBW_HISTORY_FILE") || return 1
    awk -v key="$key" -v disk="$disk" '$2 != key && $2 != disk' "$TBW_HISTORY_FILE" > "$tmp" || return 1
    collector_atomic_commit "$tmp" "$TBW_HISTORY_FILE" || return 1
    unset 'PREV_ATTR["$disk|tbw_bytes"]'
    log "SMART" "INFO" "$disk: host-write units corrected; write-rate history rebaselined; fault counters retained"
}

evaluate_smart() {
    local disk=$1
    local ctx=${2:-}
    local prev_state="${SMART_STATE[$disk]:-}"
    local prev_msgs="${SMART_MSGS[$disk]:-}"
    local is_nvme=0
    [[ $disk == /dev/nvme* ]] && is_nvme=1
    local state="OK"
    local messages=()
    if [[ $is_nvme -eq 1 ]]; then
        # Query raw NVMe SMART output once and parse key fields
        local nvme_output
        nvme_output=$(get_nvme_raw "$disk")
        if ! nvme_smart_output_is_complete "$nvme_output"; then
            record_collector_event FAILED "smartctl $disk" "incomplete_nvme_smart_output"
            log_warn "Incomplete NVMe SMART output for $disk; retaining the previous device baseline"
            return 0
        fi
        local percent_used crit_warn nvme_temp media_errors err_logs unsafe_shutdowns avail_spare avail_spare_thr duw poh
        # Extended statistics (PCIe errors, thermal transitions, temperature time accumulation)
        local nvme_ext pcie_corr pcie_unc therm_t1 therm_t2 warn_temp_time crit_temp_time
        nvme_ext=$(get_nvme_extended_raw "$disk")
        # Parse endurance, age, warnings, error counters, and spares
        percent_used=$(smart_labeled_field_value "$nvme_output" "Percentage Used" number)
        percent_used=${percent_used:-0}
        poh=$(smart_labeled_field_value "$nvme_output" "Power On Hours" number)
        poh=${poh:-0}
        crit_warn=$(smart_labeled_field_value "$nvme_output" "Critical Warning" scalar)
        crit_warn=${crit_warn:-0}
        media_errors=$(smart_labeled_field_value "$nvme_output" "Media and Data Integrity Errors" number)
        media_errors=${media_errors:-0}
        err_logs=$(smart_labeled_field_value "$nvme_output" "Error Information Log Entries" number)
        err_logs=${err_logs:-0}
        unsafe_shutdowns=$(smart_labeled_field_value "$nvme_output" "Unsafe Shutdowns" number)
        unsafe_shutdowns=${unsafe_shutdowns:-0}
        avail_spare=$(smart_labeled_field_value "$nvme_output" "Available Spare" number)
        avail_spare=${avail_spare:-}
        avail_spare_thr=$(smart_labeled_field_value "$nvme_output" "Available Spare Threshold" number)
        avail_spare_thr=${avail_spare_thr:-}
        # Parse bytes written to estimate TBW, persist, and compare to thresholds
        duw=$(smart_labeled_field_value "$nvme_output" "Data Units Written" number)
        # Parse extended NVMe statistics
        pcie_corr=$(smart_labeled_field_value "$nvme_ext" "PCIe Correctable Error Count" number)
        pcie_corr=${pcie_corr:-${NVME_LAST_PCIE_CORR[$disk]:-0}}
        pcie_unc=$(smart_labeled_field_value "$nvme_ext" "PCIe Uncorrectable Error Count" number)
        pcie_unc=${pcie_unc:-${NVME_LAST_PCIE_UNC[$disk]:-0}}
        therm_t1=$(smart_labeled_field_value "$nvme_ext" "Thermal Management T1 Transitions" number)
        therm_t1=${therm_t1:-${NVME_LAST_THERM_T1[$disk]:-0}}
        therm_t2=$(smart_labeled_field_value "$nvme_ext" "Thermal Management T2 Transitions" number)
        therm_t2=${therm_t2:-${NVME_LAST_THERM_T2[$disk]:-0}}
        warn_temp_time=$(smart_labeled_field_value "$nvme_ext" "Warning Comp. Temperature Time" number)
        warn_temp_time=${warn_temp_time:-${NVME_LAST_WARN_TEMP_TIME[$disk]:-0}}
        crit_temp_time=$(smart_labeled_field_value "$nvme_ext" "Critical Comp. Temperature Time" number)
        crit_temp_time=${crit_temp_time:-${NVME_LAST_CRIT_TEMP_TIME[$disk]:-0}}
        if [[ -n "$duw" ]]; then
            local tbw_bytes=$(( duw * 512000 ))
            local tbw_hr
            tbw_hr=$(human_readable "$tbw_bytes")
            messages+=("TBW ~ $tbw_hr")
            CUR_ATTR["$disk|tbw_bytes"]="$tbw_bytes"
            eval_tbw_state "$disk" "$tbw_bytes" "$state"
            state="$TBW_EVAL_STATE"
            if (( ${#TBW_EVAL_MESSAGES[@]} > 0 )); then
                messages+=("${TBW_EVAL_MESSAGES[@]}")
            fi
        fi
        # Parse temperature and evaluate wear percent thresholds
        nvme_temp=$(smart_labeled_field_value "$nvme_output" "Temperature" number)
        if [[ -n "$nvme_temp" && "$nvme_temp" =~ ^[0-9]+$ ]]; then
            local nvme_temp_date nvme_temp_key nvme_temp_record
            nvme_temp_date=$(date '+%Y-%m-%d')
            nvme_temp_key=$(persistent_device_key "$disk")
            nvme_temp_record="$nvme_temp_date $nvme_temp_key temp=$nvme_temp captured_epoch=$RUN_EPOCH schema=$HISTORY_SCHEMA_VERSION"
            collector_upsert_daily_history \
                "$TEMP_HISTORY_FILE" "$nvme_temp_date" "$nvme_temp_key" "$nvme_temp_record" || true
        fi
        if [[ $percent_used -ge $NVME_PERCENT_USED_CRIT ]]; then
            state="CRITICAL"; messages+=("NVMe wear ${percent_used}% >= ${NVME_PERCENT_USED_CRIT}%")
            record_alert critical "NVMe Wear" "Disk $disk NVMe wear ${percent_used}% >= ${NVME_PERCENT_USED_CRIT}%"
        elif [[ $percent_used -ge $NVME_PERCENT_USED_WARN ]]; then
            state="WARNING"; messages+=("NVMe wear ${percent_used}% >= ${NVME_PERCENT_USED_WARN}%")
            record_alert warning "NVMe Wear" "Disk $disk NVMe wear ${percent_used}% >= ${NVME_PERCENT_USED_WARN}%"
        fi
        # Decode Critical Warning bitfield and append detailed messages
        if [[ $crit_warn -ne 0 ]]; then
            state="CRITICAL"; messages+=("NVMe Critical Warning flags: $crit_warn")
            record_alert critical "NVMe Critical Warning" "Disk $disk NVMe Critical Warning flags: $crit_warn"
            local cw_dec=""
            if [[ $crit_warn =~ ^0[xX][0-9A-Fa-f]+$ ]]; then
                cw_dec=$((16#${crit_warn:2}))
            else
                cw_dec=$crit_warn
            fi
            if (( (cw_dec & 0x02) != 0 )); then
                messages+=("NVMe thermal threshold exceeded (Critical Warning bit1)")
                record_alert critical "NVMe Thermal Warning" "Disk $disk NVMe thermal threshold exceeded (Critical Warning bit1)"
            fi
            if (( (cw_dec & 0x01) != 0 )); then
                # Available spare below threshold (warn)
                local dup=0; for m in "${messages[@]}"; do [[ $m == *"Available Spare"* ]] && dup=1; done; (( dup==0 )) && messages+=("NVMe available spare below threshold (Critical Warning bit0)")
                [[ $state == OK ]] && state="WARNING"
                record_alert warning "NVMe Available Spare" "Disk $disk NVMe available spare below threshold (Critical Warning bit0)"
            fi
            if (( (cw_dec & 0x04) != 0 )); then
                state="CRITICAL"; messages+=("NVMe reliability degraded (Critical Warning bit2)")
                record_alert critical "NVMe Reliability" "Disk $disk NVMe reliability degraded (Critical Warning bit2)"
            fi
            if (( (cw_dec & 0x08) != 0 )); then
                state="CRITICAL"; messages+=("NVMe media in read-only mode (Critical Warning bit3)")
                record_alert critical "NVMe Read-Only" "Disk $disk NVMe media in read-only mode (Critical Warning bit3)"
            fi
            if (( (cw_dec & 0x10) != 0 )); then
                [[ $state == OK ]] && state="WARNING"; messages+=("NVMe volatile memory backup failed (Critical Warning bit4)")
                record_alert warning "NVMe Volatile Memory" "Disk $disk NVMe volatile memory backup failed (Critical Warning bit4)"
            fi
        fi
        # Flag media/data integrity errors and low spare
        if [[ $media_errors -gt 0 ]]; then
            state="CRITICAL"; messages+=("NVMe media/data integrity errors = $media_errors")
            record_alert critical "NVMe Media Integrity" "Disk $disk NVMe media/data integrity errors = $media_errors"
        fi
        # Delta-based alerts for NVMe error log entries growth
        local prev_errlog=${NVME_LAST_ERRLOG[$disk]:-0}
        if [[ $err_logs -gt $prev_errlog ]]; then
            local delta_errlog=$((err_logs - prev_errlog))
            if (( delta_errlog >= NVME_ERR_LOG_DELTA_CRIT )); then
                state="CRITICAL"; messages+=("NVMe error log entries increased by ${delta_errlog} (${prev_errlog} -> ${err_logs})")
                record_alert critical "NVMe Error Log" "Disk $disk NVMe error log entries increased by ${delta_errlog} (${prev_errlog} -> ${err_logs})"
            elif (( delta_errlog >= NVME_ERR_LOG_DELTA_WARN )) && [[ $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("NVMe error log entries increased by ${delta_errlog} (${prev_errlog} -> ${err_logs})")
                record_alert warning "NVMe Error Log" "Disk $disk NVMe error log entries increased by ${delta_errlog} (${prev_errlog} -> ${err_logs})"
            fi
        fi
        # Delta-based alerts for PCIe correctable errors
        local prev_pcie_corr=${NVME_LAST_PCIE_CORR[$disk]:-0}
        if [[ $pcie_corr -gt $prev_pcie_corr ]]; then
            local delta_corr=$((pcie_corr - prev_pcie_corr))
            if (( delta_corr >= NVME_PCIE_CORR_DELTA_CRIT )); then
                state="CRITICAL"; messages+=("NVMe PCIe correctable errors increased by ${delta_corr} (${prev_pcie_corr} -> ${pcie_corr})")
                record_alert critical "NVMe PCIe Correctable" "Disk $disk NVMe PCIe correctable errors increased by ${delta_corr} (${prev_pcie_corr} -> ${pcie_corr})"
            elif (( delta_corr >= NVME_PCIE_CORR_DELTA_WARN )) && [[ $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("NVMe PCIe correctable errors increased by ${delta_corr} (${prev_pcie_corr} -> ${pcie_corr})")
                record_alert warning "NVMe PCIe Correctable" "Disk $disk NVMe PCIe correctable errors increased by ${delta_corr} (${prev_pcie_corr} -> ${pcie_corr})"
            fi
        fi
        # Delta-based alerts for PCIe uncorrectable errors (any increase critical)
        local prev_pcie_unc=${NVME_LAST_PCIE_UNC[$disk]:-0}
        if [[ $pcie_unc -gt $prev_pcie_unc ]]; then
            local delta_unc=$((pcie_unc - prev_pcie_unc))
            if (( delta_unc >= NVME_PCIE_UNC_DELTA_CRIT )); then
                state="CRITICAL"; messages+=("NVMe PCIe uncorrectable errors increased by ${delta_unc} (${prev_pcie_unc} -> ${pcie_unc})")
                record_alert critical "NVMe PCIe Uncorrectable" "Disk $disk NVMe PCIe uncorrectable errors increased by ${delta_unc} (${prev_pcie_unc} -> ${pcie_unc})"
            elif (( delta_unc >= NVME_PCIE_UNC_DELTA_WARN )) && [[ $state != CRITICAL ]]; then
                state="CRITICAL"; messages+=("NVMe PCIe uncorrectable errors increased by ${delta_unc} (${prev_pcie_unc} -> ${pcie_unc})")
                record_alert critical "NVMe PCIe Uncorrectable" "Disk $disk NVMe PCIe uncorrectable errors increased by ${delta_unc} (${prev_pcie_unc} -> ${pcie_unc})"
            fi
        fi
        # Delta-based alerts for thermal transitions
        local prev_t1=${NVME_LAST_THERM_T1[$disk]:-0}
        if [[ $therm_t1 -gt $prev_t1 ]]; then
            local delta_t1=$((therm_t1 - prev_t1))
            if (( delta_t1 >= NVME_THERM_T1_DELTA_WARN )) && [[ $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("NVMe thermal transitions T1 increased by ${delta_t1} (${prev_t1} -> ${therm_t1})")
                record_alert warning "NVMe Thermal T1" "Disk $disk NVMe thermal transitions T1 increased by ${delta_t1} (${prev_t1} -> ${therm_t1})"
            fi
        fi
        local prev_t2=${NVME_LAST_THERM_T2[$disk]:-0}
        if [[ $therm_t2 -gt $prev_t2 ]]; then
            local delta_t2=$((therm_t2 - prev_t2))
            if (( delta_t2 >= NVME_THERM_T2_DELTA_WARN )); then
                state="CRITICAL"; messages+=("NVMe thermal transitions T2 increased by ${delta_t2} (${prev_t2} -> ${therm_t2})")
                record_alert critical "NVMe Thermal T2" "Disk $disk NVMe thermal transitions T2 increased by ${delta_t2} (${prev_t2} -> ${therm_t2})"
            fi
        fi
        # Delta-based alerts for temperature time accumulation
        local prev_warn_tt=${NVME_LAST_WARN_TEMP_TIME[$disk]:-0}
        if [[ $warn_temp_time -gt $prev_warn_tt ]]; then
            local delta_wtt=$((warn_temp_time - prev_warn_tt))
            if (( delta_wtt >= NVME_WARN_TEMP_TIME_DELTA_WARN )) && [[ $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("NVMe warning temperature time +${delta_wtt}s (total ${warn_temp_time}s)")
                record_alert warning "NVMe Warn Temp Time" "Disk $disk NVMe warning temperature time +${delta_wtt}s (total ${warn_temp_time}s)"
            fi
        fi
        local prev_crit_tt=${NVME_LAST_CRIT_TEMP_TIME[$disk]:-0}
        if [[ $crit_temp_time -gt $prev_crit_tt ]]; then
            local delta_ctt=$((crit_temp_time - prev_crit_tt))
            if (( delta_ctt >= NVME_CRIT_TEMP_TIME_DELTA_WARN )); then
                state="CRITICAL"; messages+=("NVMe critical temperature time +${delta_ctt}s (total ${crit_temp_time}s)")
                record_alert critical "NVMe Critical Temp Time" "Disk $disk NVMe critical temperature time +${delta_ctt}s (total ${crit_temp_time}s)"
            fi
        fi
        if [[ -n "$avail_spare" && -n "$avail_spare_thr" && $avail_spare -lt $avail_spare_thr ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("NVMe Available Spare ${avail_spare}% < threshold ${avail_spare_thr}%")
            record_alert warning "NVMe Available Spare" "Disk $disk NVMe Available Spare ${avail_spare}% < threshold ${avail_spare_thr}%"
        elif [[ -n "$avail_spare" && $avail_spare -lt $NVME_AVAIL_SPARE_WARN ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("NVMe Available Spare low: ${avail_spare}%")
            record_alert warning "NVMe Available Spare" "Disk $disk NVMe Available Spare low: ${avail_spare}%"
        fi
        # Detect unsafe shutdown deltas since last run and warn
        local prev_uns=${NVME_LAST_UNSAFE[$disk]:-0}
        local delta=$((unsafe_shutdowns - prev_uns))
        local total_ok=1
        if [[ ${UNSAFE_SDWN_ABSOLUTE_MIN:-0} -gt 0 && $unsafe_shutdowns -lt $UNSAFE_SDWN_ABSOLUTE_MIN ]]; then
            total_ok=0
        fi
        local cooldown_ok=1
        local cooldown_key legacy_warn_file
        cooldown_key=$(persistent_device_key "$disk")
        local warn_file="$UNSAFE_SDWN_STATE_DIR/$(safe_state_name "$cooldown_key").lastwarn"
        legacy_warn_file="$UNSAFE_SDWN_STATE_DIR/$(safe_state_name "$disk").lastwarn"
        if [[ ! -e "$warn_file" && -e "$legacy_warn_file" ]]; then
            mv -f -- "$legacy_warn_file" "$warn_file" 2>/dev/null || true
        fi
        if [[ ${UNSAFE_SDWN_COOLDOWN_DAYS:-0} -gt 0 ]]; then
            if [[ -f "$warn_file" ]]; then
                local last_ts now diff cooldown_sec
                last_ts=$(cat "$warn_file" 2>/dev/null || echo 0)
                now=$(date +%s)
                cooldown_sec=$((UNSAFE_SDWN_COOLDOWN_DAYS * 86400))
                diff=$((now - last_ts))
                if [[ $diff -lt $cooldown_sec ]]; then
                    cooldown_ok=0
                fi
            fi
        fi
        if [[ $unsafe_shutdowns -gt $prev_uns && $UNSAFE_SDWN_DELTA_WARN -gt 0 && $delta -ge $UNSAFE_SDWN_DELTA_WARN && $total_ok -eq 1 && $cooldown_ok -eq 1 ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("NVMe Unsafe Shutdowns increased: ${prev_uns} -> ${unsafe_shutdowns}")
            record_alert warning "NVMe Unsafe Shutdowns" "Disk $disk NVMe Unsafe Shutdowns increased: ${prev_uns} -> ${unsafe_shutdowns}"
            # Persist last warning timestamp for cooldown
            if (( UNSAFE_SDWN_COOLDOWN_DAYS > 0 )); then
                collector_atomic_write_text "$warn_file" "$(date +%s)" || true
            fi
        fi
        NVME_LAST_UNSAFE[$disk]=$unsafe_shutdowns
        # Evaluate temperature against warn/critical thresholds
        if [[ -n "$nvme_temp" ]]; then
            if [[ $nvme_temp -ge $NVME_TEMP_CRITICAL ]]; then
                state="CRITICAL"; messages+=("NVMe Temp ${nvme_temp}C >= ${NVME_TEMP_CRITICAL}C")
            elif [[ $nvme_temp -ge $NVME_TEMP_WARNING && $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("NVMe Temp ${nvme_temp}C >= ${NVME_TEMP_WARNING}C")
            fi
        fi
        # Persist parsed NVMe attributes for downstream consumers
        CUR_ATTR["$disk|nvme_percent_used"]="$percent_used"
        CUR_ATTR["$disk|poh"]="$poh"
        CUR_ATTR["$disk|unsafe_shutdowns"]="$unsafe_shutdowns"
        CUR_ATTR["$disk|media_errors"]="$media_errors"
        CUR_ATTR["$disk|err_logs"]="$err_logs"
        CUR_ATTR["$disk|avail_spare"]="$avail_spare"
        CUR_ATTR["$disk|pcie_corr"]="$pcie_corr"
        CUR_ATTR["$disk|pcie_unc"]="$pcie_unc"
        CUR_ATTR["$disk|therm_t1"]="$therm_t1"
        CUR_ATTR["$disk|therm_t2"]="$therm_t2"
        CUR_ATTR["$disk|warn_temp_time"]="$warn_temp_time"
        CUR_ATTR["$disk|crit_temp_time"]="$crit_temp_time"
        # Update last counters for next run
        NVME_LAST_ERRLOG[$disk]="$err_logs"
        NVME_LAST_PCIE_CORR[$disk]="$pcie_corr"
        NVME_LAST_PCIE_UNC[$disk]="$pcie_unc"
        NVME_LAST_THERM_T1[$disk]="$therm_t1"
        NVME_LAST_THERM_T2[$disk]="$therm_t2"
        NVME_LAST_WARN_TEMP_TIME[$disk]="$warn_temp_time"
        NVME_LAST_CRIT_TEMP_TIME[$disk]="$crit_temp_time"
        # Retrieve and classify latest self-test; persist status and message
        local st_info st_class st_sev st_msg
        st_info=$(get_latest_selftest_info "$disk")
        st_class=$(classify_selftest_status "$(echo "$st_info" | awk -F'|' '{print $3}')")
        st_sev=$(echo "$st_class" | awk -F'|' '{print $1}')
        st_msg=$(echo "$st_class" | awk -F'|' '{print $2}')
        CUR_ATTR["$disk|selftest_status"]="$st_sev"
        CUR_ATTR["$disk|selftest_msg"]="$st_msg"
        if [[ "$st_sev" == "CRITICAL" ]]; then
            state="CRITICAL"; messages+=("Self-test critical: $st_msg")
        elif [[ "$st_sev" == "WARNING" && $state != CRITICAL ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("Self-test warning: $st_msg")
        fi

    else
        # Query raw SATA SMART attributes and parse key metrics
        local attr realloc pending offunc temp udma reported_uncorr cmd_timeout realloc_events end2end soft_read_err lcc poh
        attr=$(get_sata_raw "$disk")
        if ! ata_smart_output_is_complete "$attr"; then
            if scsi_smart_output_is_complete "$attr"; then
                evaluate_scsi_smart "$disk" "$attr" "$ctx"
                return 0
            fi
            attr=$(smartctl_cached -a "$disk" 2>/dev/null || true)
            if scsi_smart_output_is_complete "$attr"; then
                evaluate_scsi_smart "$disk" "$attr" "$ctx"
                return 0
            elif ! ata_smart_output_is_complete "$attr"; then
                record_collector_event FAILED "smartctl $disk" "incomplete_ata_or_scsi_smart_output"
                log_warn "Incomplete ATA/SCSI SMART output for $disk; retaining the previous device baseline"
                return 0
            fi
        fi
        local overall_output overall_health
        overall_output=$(smartctl_cached -H "$disk" 2>/dev/null || true)
        overall_health=$(sed -nE 's/^SMART overall-health self-assessment test result:[[:space:]]*//p' <<< "$overall_output")
        if [[ "$overall_health" == PASSED* ]]; then :
        elif [[ "$overall_health" == FAILED* ]]; then
            state="CRITICAL"; messages+=("Native SMART overall health FAILED")
            record_alert critical "SMART Overall Health" "Disk $disk native SMART overall health FAILED; back up and inspect immediately"
        else
            record_collector_event FAILED "smartctl $disk" "overall_health_unavailable"
            log "SMART" "WARN" "$disk: native overall-health response unavailable; retaining previous health baseline"
            return 0
        fi
        # Evaluate reallocated sectors thresholds (warn/crit)
        realloc=$(ata_smart_attribute_value "$attr" "Reallocated_Sector_Ct")
        realloc=${realloc:-0}
        if [[ $realloc -ge $RELOC_CRITICAL ]]; then
            state="CRITICAL"; messages+=("Reallocated = $realloc (>= $RELOC_CRITICAL)")
            record_alert critical "Reallocated =" "Disk $disk reallocated sectors $realloc >= $RELOC_CRITICAL"
        elif [[ $realloc -ge $RELOC_WARNING ]]; then
            state="WARNING"; messages+=("Reallocated = $realloc (>= $RELOC_WARNING)")
            record_alert warning "Reallocated =" "Disk $disk reallocated sectors $realloc >= $RELOC_WARNING"
        fi
        # Evaluate pending/uncorrectable sectors
        pending=$(ata_smart_attribute_value "$attr" "Current_Pending_Sector")
        pending=${pending:-0}
        if [[ $pending -ge $PEND_WARNING ]]; then
            state="CRITICAL"; messages+=("Pending sectors = $pending")
            record_alert critical "Pending sectors" "Disk $disk pending sectors $pending >= $PEND_WARNING"
        fi
        offunc=$(ata_smart_attribute_value "$attr" "Offline_Uncorrectable")
        offunc=${offunc:-0}
        if [[ $offunc -gt 0 ]]; then
            state="CRITICAL"; messages+=("Offline Uncorrectable = $offunc")
            record_alert critical "Offline Uncorrectable" "Disk $disk offline uncorrectable $offunc > 0"
        fi
        # Evaluate reported uncorrectable and command timeout counters
        reported_uncorr=$(ata_smart_attribute_value "$attr" "Reported_Uncorrectable|Reported_Uncorrect")
        reported_uncorr=${reported_uncorr:-0}
        if [[ $reported_uncorr -ge $REPORTED_UNC_CRIT ]]; then
            state="CRITICAL"; messages+=("Reported Uncorrectable = $reported_uncorr")
            record_alert critical "Reported Uncorrectable" "Disk $disk reported uncorrectable $reported_uncorr >= $REPORTED_UNC_CRIT"
        fi
        cmd_timeout=$(ata_smart_attribute_value "$attr" "Command_Timeout")
        cmd_timeout=${cmd_timeout:-0}
        # Absolute threshold evaluation
        if [[ $cmd_timeout -ge $CMD_TIMEOUT_CRIT ]]; then
            state="CRITICAL"; messages+=("Command Timeout events = $cmd_timeout (>= $CMD_TIMEOUT_CRIT)")
            record_alert critical "Command Timeout events" "Disk $disk command timeout events $cmd_timeout >= $CMD_TIMEOUT_CRIT"
        elif [[ $cmd_timeout -ge $CMD_TIMEOUT_WARN && $state != CRITICAL ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("Command Timeout events = $cmd_timeout")
            record_alert warning "Command Timeout events" "Disk $disk command timeout events $cmd_timeout >= $CMD_TIMEOUT_WARN"
        fi
        # Rate (delta) alert with cooldown
        if [[ $CMD_TIMEOUT_DELTA_WARN -gt 0 && $CMD_TIMEOUT_COOLDOWN_DAYS -ge 0 ]]; then
            local prev_ct=${CMD_TIMEOUT_LAST[$disk]:-}
            if [[ -n "$prev_ct" && "$prev_ct" =~ ^[0-9]+$ ]]; then
                local delta=$(( cmd_timeout - prev_ct ))
                if (( delta >= CMD_TIMEOUT_DELTA_WARN )) && [[ $cmd_timeout -ge $CMD_TIMEOUT_WARN ]]; then
                    local cooldown_ok=1
                    if [[ $CMD_TIMEOUT_COOLDOWN_DAYS -gt 0 ]]; then
                        mkdir -p "$CMD_TIMEOUT_STATE_DIR" 2>/dev/null || true
                        local cooldown_key legacy_warn_file
                        cooldown_key=$(persistent_device_key "$disk")
                        local warn_file="$CMD_TIMEOUT_STATE_DIR/$(safe_state_name "$cooldown_key").lastwarn"
                        legacy_warn_file="$CMD_TIMEOUT_STATE_DIR/$(safe_state_name "$disk").lastwarn"
                        if [[ ! -e "$warn_file" && -e "$legacy_warn_file" ]]; then
                            mv -f -- "$legacy_warn_file" "$warn_file" 2>/dev/null || true
                        fi
                        if [[ -f "$warn_file" ]]; then
                            local last_ts now diff cooldown_sec
                            last_ts=$(cat "$warn_file" 2>/dev/null || echo 0)
                            now=$(date +%s)
                            cooldown_sec=$((CMD_TIMEOUT_COOLDOWN_DAYS * 86400))
                            diff=$((now - last_ts))
                            if [[ $diff -lt $cooldown_sec ]]; then cooldown_ok=0; fi
                        fi
                    fi
                    if (( cooldown_ok == 1 )) && [[ $state != CRITICAL ]]; then
                        [[ $state == OK ]] && state="WARNING"
                        messages+=("Command Timeout increased: ${prev_ct} -> ${cmd_timeout} (+${delta})")
                        record_alert warning "Command Timeout events" "Disk $disk command timeout increased ${prev_ct}->${cmd_timeout} (+${delta})"
                        if [[ $CMD_TIMEOUT_COOLDOWN_DAYS -gt 0 ]]; then
                            collector_atomic_write_text "$warn_file" "$(date +%s)" || true
                        fi
                    fi
                fi
            fi
            CMD_TIMEOUT_LAST[$disk]=$cmd_timeout
        fi
        # Evaluate reallocated event count, end-to-end and soft read error rate
        realloc_events=$(ata_smart_attribute_value "$attr" "Reallocated_Event_Count")
        realloc_events=${realloc_events:-0}
        if [[ $realloc_events -ge $REALLOC_EVENT_CRIT ]]; then
            state="CRITICAL"; messages+=("Reallocated Event Count = $realloc_events (>= $REALLOC_EVENT_CRIT)")
            record_alert critical "Reallocated Event Count" "Disk $disk reallocated event count $realloc_events >= $REALLOC_EVENT_CRIT"
        elif [[ $realloc_events -ge $REALLOC_EVENT_WARN && $state != CRITICAL ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("Reallocated Event Count = $realloc_events")
            record_alert warning "Reallocated Event Count" "Disk $disk reallocated event count $realloc_events >= $REALLOC_EVENT_WARN"
        fi
        end2end=$(ata_smart_attribute_value "$attr" "End_to_End_Error")
        end2end=${end2end:-0}
        if [[ $end2end -ge $END_TO_END_ERR_CRIT ]]; then
            state="CRITICAL"; messages+=("End-to-End Errors = $end2end")
            record_alert critical "End-to-End Errors" "Disk $disk end-to-end errors $end2end >= $END_TO_END_ERR_CRIT"
        fi
        soft_read_err=$(ata_smart_attribute_value "$attr" "Soft_Read_Error_Rate")
        soft_read_err=${soft_read_err:-}
        if [[ -n "$soft_read_err" && $soft_read_err =~ ^[0-9]+$ && $soft_read_err -ge $SOFT_READ_ERR_WARN && $state != CRITICAL ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("Soft Read Error Rate = $soft_read_err (>= $SOFT_READ_ERR_WARN)")
            record_alert warning "Soft Read Error Rate" "Disk $disk soft read error rate $soft_read_err >= $SOFT_READ_ERR_WARN"
        fi
        # Determine device class (HDD/SSD) and evaluate temperature thresholds
        temp=$(ata_smart_attribute_value "$attr" "Temperature_Celsius|Airflow_Temperature_Cel")
        temp=${temp:-0}
        if [[ -n "$temp" && "$temp" =~ ^[0-9]+$ && "$temp" != 0 ]]; then
            local sata_temp_date sata_temp_key sata_temp_record
            sata_temp_date=$(date '+%Y-%m-%d')
            sata_temp_key=$(persistent_device_key "$disk")
            sata_temp_record="$sata_temp_date $sata_temp_key temp=$temp captured_epoch=$RUN_EPOCH schema=$HISTORY_SCHEMA_VERSION"
            collector_upsert_daily_history \
                "$TEMP_HISTORY_FILE" "$sata_temp_date" "$sata_temp_key" "$sata_temp_record" || true
        fi
        local bdv
        bdv=$(base_device "$disk")
        local rota
            rota=$(lsblk_rota_cached "$bdv" 2>/dev/null || echo 1)
        local warn_t crit_t label
        if [[ "$rota" == "1" ]]; then
            warn_t=$HDD_TEMP_WARNING; crit_t=$HDD_TEMP_CRITICAL; label="HDD Temp"
        else
            warn_t=$SSD_TEMP_WARNING; crit_t=$SSD_TEMP_CRITICAL; label="SSD Temp"
        fi
        if [[ -n "$temp" && "$temp" != "0" ]]; then
            if [[ $temp -ge $crit_t ]]; then
                state="CRITICAL"; messages+=("${label} ${temp}C >= ${crit_t}C")
                record_alert critical "Temp" "Disk $disk ${label} ${temp}C >= ${crit_t}C"
            elif [[ $temp -ge $warn_t && $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("${label} ${temp}C >= ${warn_t}C")
                record_alert warning "Temp" "Disk $disk ${label} ${temp}C >= ${warn_t}C"
            fi
        fi
        # Check UDMA CRC errors and head parking (Load Cycle Count)
        udma=$(ata_smart_attribute_value "$attr" "UDMA_CRC_Error_Count")
        udma=${udma:-0}
        local prior_udma="${PREV_ATTR["$disk|udma"]:-}"
        if [[ "$prior_udma" =~ ^[0-9]+$ && "$udma" =~ ^[0-9]+$ ]] && (( udma > prior_udma )); then
            [[ $state == OK ]] && state="WARNING"
            messages+=("UDMA CRC errors increased by $((udma-prior_udma)) (total=$udma)")
            record_alert warning "UDMA CRC Errors" "Disk $disk UDMA CRC errors increased by $((udma-prior_udma)); inspect SATA cable/power"
        elif [[ "$udma" =~ ^[0-9]+$ ]] && (( udma > 0 )); then
            log "SMART" "INFO" "$disk historical UDMA CRC count=$udma; no proven new growth"
        fi
        local lcc
        lcc=$(ata_smart_attribute_value "$attr" "Load_Cycle_Count")
        if [[ "$lcc" =~ ^(0|[1-9][0-9]*)$ ]] && (( lcc >= LOAD_CYCLE_WARN )); then
            log "SMART" "INFO" "$disk load-cycle count $lcc (review thresholds: $LOAD_CYCLE_WARN / $LOAD_CYCLE_CRIT)."
        fi
        # Vendor MWI encodings are not interchangeable percentages. Keep the raw
        # normalized value for review; native SMART failure and rated TBW remain active.
        local mwi_norm
        mwi_norm=$(ata_smart_attribute_value "$attr" "Media_Wearout_Indicator" normalized)
        if [[ -n "$mwi_norm" ]]; then
            messages+=("Vendor wear value=$mwi_norm (remaining-life percentage unverified)")
            CUR_ATTR["$disk|vendor_mwi"]="$mwi_norm"
        fi
        # Retain hours for device history and replacement planning.
        poh=$(ata_smart_attribute_value "$attr" "Power_On_Hours|Power_On_Hours_and_Msec")
        poh=${poh:-0}
        CUR_ATTR["$disk|poh"]="$poh"

        CUR_ATTR["$disk|realloc"]="${realloc:-0}"
        CUR_ATTR["$disk|pending"]="${pending:-0}"
        CUR_ATTR["$disk|offunc"]="${offunc:-0}"
        CUR_ATTR["$disk|reported_uncorr"]="${reported_uncorr:-0}"
        CUR_ATTR["$disk|cmd_timeout"]="${cmd_timeout:-0}"
        CUR_ATTR["$disk|realloc_events"]="${realloc_events:-0}"
        CUR_ATTR["$disk|end2end"]="${end2end:-0}"
        CUR_ATTR["$disk|soft_read_err"]="${soft_read_err:-0}"
        CUR_ATTR["$disk|udma"]="${udma:-0}"
        CUR_ATTR["$disk|lcc"]="${lcc:-0}"
        CUR_ATTR["$disk|temp"]="${temp:-0}"
        # Detect SATA negotiated link speed downshift (cabling/port issues)
        local info line max_speed current_speed
        info=$(get_sata_info "$disk")
        line=$(echo "$info" | grep -m1 'SATA Version is:' || true)
        if [[ -n "$line" ]]; then
            if [[ $line =~ ([0-9]+\.[0-9])[[:space:]]Gb/s ]]; then
                max_speed="${BASH_REMATCH[1]}"
            fi
            if [[ $line =~ \(current:[[:space:]]([0-9]+\.[0-9])[[:space:]]Gb/s\) ]]; then
                current_speed="${BASH_REMATCH[1]}"
            fi
            current_speed=${current_speed:-$max_speed}
            if [[ -n "$max_speed" && -n "$current_speed" ]]; then
                CUR_ATTR["$disk|sata_link_max"]="$max_speed"
                CUR_ATTR["$disk|sata_link_current"]="$current_speed"
                local max_i=${max_speed/./} curr_i=${current_speed/./}
                if [[ "$max_speed" != "$current_speed" ]]; then
                    local half=$(( max_i / 2 ))
                    if (( curr_i < half )); then
                        state="CRITICAL"; messages+=("SATA link downshift: max ${max_speed} current ${current_speed} Gb/s")
                    else
                        [[ $state == OK ]] && state="WARNING"; messages+=("SATA link downshift: max ${max_speed} current ${current_speed} Gb/s")
                    fi
                    # Persist daily link downshift event (dedup per-date per-device)
                    if (( SATA_LINK_INSTABILITY_ENABLED == 1 )); then
                        local today sata_link_key sata_link_record
                        today=$(date '+%Y-%m-%d')
                        sata_link_key=$(persistent_device_key "$disk")
                        sata_link_record="$today $sata_link_key max=$max_speed current=$current_speed captured_epoch=$RUN_EPOCH schema=$HISTORY_SCHEMA_VERSION"
                        collector_upsert_daily_history \
                            "$SATA_LINK_HISTORY_FILE" "$today" "$sata_link_key" "$sata_link_record" || true
                    fi
                fi
            fi
        fi
        # Persist commonly used parsed SMART attributes for downstream logic and JSON export
        local tbw_bytes="" tbw_hr reads_bytes="" reads_hr
        tbw_bytes=$(ata_host_counter_bytes "$attr" writes || true)
        reads_bytes=$(ata_host_counter_bytes "$attr" reads || true)
        if [[ -n "$tbw_bytes" ]]; then
            rebaseline_ata_host_writes "$disk" || return 1
        fi
        # Summarize TBW/Read totals and evaluate TBW thresholds (model-aware or global)
        if [[ -n "${tbw_bytes:-}" ]]; then
            tbw_hr=$(human_readable "$tbw_bytes")
            messages+=("TBW ~ $tbw_hr")
            CUR_ATTR["$disk|tbw_bytes"]="$tbw_bytes"
            eval_tbw_state "$disk" "$tbw_bytes" "$state"
            state="$TBW_EVAL_STATE"
            if (( ${#TBW_EVAL_MESSAGES[@]} > 0 )); then
                messages+=("${TBW_EVAL_MESSAGES[@]}")
            fi
        fi
        # Add read total summary (human-readable)
        if [[ -n "${reads_bytes:-}" ]]; then
            reads_hr=$(human_readable "$reads_bytes")
            messages+=("Read ~ $reads_hr")
        fi
        # Persist per-attribute counters for later comparisons and reporting
        CUR_ATTR["$disk|realloc"]="$realloc"
        CUR_ATTR["$disk|pending"]="$pending"
        CUR_ATTR["$disk|offunc"]="$offunc"
        CUR_ATTR["$disk|reported_uncorr"]="$reported_uncorr"
        CUR_ATTR["$disk|cmd_timeout"]="$cmd_timeout"
        CUR_ATTR["$disk|realloc_events"]="$realloc_events"
        CUR_ATTR["$disk|udma"]="$udma"
        CUR_ATTR["$disk|lcc"]="${lcc:-0}"
        CUR_ATTR["$disk|end2end"]="$end2end"
        CUR_ATTR["$disk|soft_read_err"]="${soft_read_err:-0}"
        CUR_ATTR["$disk|temp"]="$temp"
        # Retrieve and classify latest SATA self-test; persist and update severity
        local st_info st_class st_sev st_msg
        st_info=$(get_latest_selftest_info "$disk")
        st_class=$(classify_selftest_status "$(echo "$st_info" | awk -F'|' '{print $3}')")
        st_sev=$(echo "$st_class" | awk -F'|' '{print $1}')
        st_msg=$(echo "$st_class" | awk -F'|' '{print $2}')
        CUR_ATTR["$disk|selftest_status"]="$st_sev"
        CUR_ATTR["$disk|selftest_msg"]="$st_msg"
        if [[ "$st_sev" == "CRITICAL" ]]; then
            state="CRITICAL"; messages+=("Self-test critical: $st_msg")
        elif [[ "$st_sev" == "WARNING" && $state != CRITICAL ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("Self-test warning: $st_msg")
        fi
    fi
    # Persist state & aggregated messages + emit per-line logs (minimal, no single-line aggregation)
    local _joined="" _m
    for _m in "${messages[@]}"; do
        if [[ -z "$_joined" ]]; then _joined="$_m"; else _joined+="; $_m"; fi
    done
    # Decide whether to log based on delta when in post-test context
    SMART_STATE["$disk"]="$state"
    SMART_MSGS["$disk"]="$_joined"
    if [[ "$ctx" == "post-test" && "$prev_state" == "$state" && "${prev_msgs}" == "$_joined" ]]; then
        # No change in state or messages; suppress duplicate post-test log
        :
    else
        # Log state then each message with disk prefix for clarity
        if [[ -n "$ctx" ]]; then
            log_smart "SMART state ($ctx) $disk: $state"
        else
            log_smart "SMART state $disk: $state"
        fi
        for _m in "${messages[@]}"; do
            log_smart "SMART detail $disk: $_m"
        done
    fi
    return 0
}

# === Helper Function ===
# Extract latest SMART self-test entry from smartctl output
get_latest_selftest_info() {
    local disk=$1
    local out
    if [[ $disk == /dev/nvme* ]]; then
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART self-test log read (-l selftest) on $disk"
        out=$(get_selftest_live "$disk")
    else
        out=$(get_selftest_live "$disk")
    fi
    local line exec_status=""
    # Most recent entry is the first row with a numeric test identifier. The
    # pure parser supports both ATA '# 1' and NVMe/numeric-first layouts.
    line=$(printf '%s\n' "$out" | awk \
        '(($1=="#" && $2 ~ /^[0-9]+$/) || $1 ~ /^[0-9]+$/) {print; exit}')
    if [[ -z "$line" ]]; then
        # No entries in self-test log; fall back to execution status from capabilities page
        if [[ $disk == /dev/nvme* ]]; then
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART capability read (-c) on $disk"
            exec_status=$(get_capabilities_live "$disk" | awk -F: '/Self-test execution status/ {sub(/^ +/,"",$2); print $2; exit}') || true
        else
            exec_status=$(get_capabilities_live "$disk" | awk -F: '/Self-test execution status/ {sub(/^ +/,"",$2); print $2; exit}') || true
        fi
        exec_status=${exec_status:-"Self-test log not yet populated"}
    fi
    parse_smart_selftest_output "$out" "$exec_status"
}

# === Helper Function ===
# Map SMART self-test entries to severity
classify_selftest_status() {
    local raw="$1"
    local status norm code sev msg
    status="$raw"
    norm=$(echo "$status" | tr -s ' ' ' ' | sed 's/^ //; s/ $//')
    if [[ -z "${norm//[[:space:]]/}" ]] || echo "$norm" | grep -qiE "not yet populated|no self-tests|no entries|self[- ]?test log (is )?empty"; then
        echo "OK|Self-test log not yet populated"; return 0
    fi
    code=$(echo "$norm" | grep -Eo '0x[0-9a-fA-F]+' | head -n1 || true)
    [[ -z "$code" ]] && code=$(echo "$norm" | grep -Eo '\b[0-9]{1,3}\b' | head -n1 || true)
    sev="OK"; msg="$norm"
    if echo "$norm" | grep -qiE "in progress|progress"; then
        sev="INPROGRESS"; msg="Self-test in progress: $norm"
    elif echo "$norm" | grep -qiE "Completed without error|without error|completed successfully|no error|passed"; then
        sev="OK"; msg="Self-test passed${code:+ (code $code)}"
    elif echo "$norm" | grep -qiE "(read|write|uncorrectable|unrecoverable|fatal|electrical|servo|seek|verify) (error|failure)|failed"; then
        sev="CRITICAL"; msg="Self-test critical${code:+ (code $code)}: $norm"
    elif echo "$norm" | grep -qiE "aborted|interrupted|cancelled"; then
        sev="WARNING"; msg="Self-test did not complete: $norm"
    elif echo "$norm" | grep -qi "Completed"; then
        sev="OK"; msg="Self-test completed${code:+ (code $code)}"
    else
        sev="WARNING"; msg="Self-test ambiguous status: $norm"
    fi
    echo "$sev|$msg"
}

# === Helper Function ===
# Persist a compact snapshot of the latest SMART self-test (or capabilities fallback)
save_selftest_snapshot() {
    local disk="$1"
    local info num type status lifetime remaining sev msg target temp_file state_key
    info=$(get_latest_selftest_info "$disk")
    IFS='|' read -r num type status lifetime remaining <<< "$info"
    # Classify status for quick glance
    local cls
    cls=$(classify_selftest_status "$status")
    sev=$(echo "$cls" | awk -F'|' '{print $1}')
    msg=$(echo "$cls" | awk -F'|' '{print $2}')
    state_key=$(persistent_device_key "$disk")
    target="$SMART_SELFTEST_DIR/$(safe_state_name "$state_key").snapshot"
    temp_file="$(state_temp_file "$target")" || return 1
    {
        printf "Captured: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
        printf "Disk: %s\n" "$disk"
        printf "Entry: %s\n" "${num:-0}"
        printf "Type: %s\n" "${type:-unknown}"
        printf "Status: %s\n" "${status:-unknown}"
        [[ -n "${lifetime:-}" ]] && printf "LifetimeHours: %s\n" "$lifetime"
        [[ -n "${remaining:-}" ]] && printf "Remaining: %s\n" "$remaining"
        printf "Class: %s\n" "${sev:-OK}"
        [[ -n "${msg:-}" ]] && printf "ClassDetail: %s\n" "$msg"
    } > "$temp_file" 2>/dev/null || {
        rm -f -- "$temp_file" 2>/dev/null || true
        return 1
    }
    collector_atomic_commit "$temp_file" "$target"
}

# === Helper Function ===
# Poll a short self-test until completion or timeout

# === Helper Functions ===
# the configured weights distinguish warning from critical evidence.

# Canonical scorer used by SMART scheduling, ranking, persistence, and lifecycle
# classification. Each underlying signal contributes at most once per device,
# even when several collectors report different evidence for that signal.

# === Helper Function ===
# Launch SMART tests (short/long) as configured
SMART_LONG_STARTED=0
SMART_FLEET_LONG_RUNNING=0
smart_test_start_allowed() {
    local kind="$1" lock values active action mount status mover_pid=0
    for lock in /tmp/backup_cache_appdata.lock /tmp/backup_boot_disk.lock; do
        if [[ -e "$lock" ]] && ! flock -s -n "$lock" -c true; then
            log "SMART" "INFO" "New $kind self-test deferred: ${lock##*/} active"; return 1
        fi
    done
    values=$(timeout 5 mdcmd status 2>/dev/null) || {
        log "SMART" "INFO" "New $kind self-test deferred: parity status unavailable"; return 1;
    }
    active=$(awk -F= '$1=="mdResync" {gsub(/"/,"",$2);print $2}' <<< "$values")
    action=$(awk -F= '$1=="mdResyncAction" {gsub(/"/,"",$2);print $2}' <<< "$values")
    [[ "$active" =~ ^[0-9]+$ ]] || return 1
    if [[ -r /var/run/mover.pid ]]; then read -r mover_pid < /var/run/mover.pid || mover_pid=0; fi
    if [[ "$mover_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$mover_pid" 2>/dev/null; then
        log "SMART" "INFO" "New $kind self-test deferred: Mover PID $mover_pid active"; return 1
    fi
    if (( active > 0 )) || pgrep -f '^(/bin/bash |/bin/sh )?(/usr/local/sbin/)?mover( |$)' >/dev/null; then
        log "SMART" "INFO" "New $kind self-test deferred: parity/Mover active ($action)"; return 1
    fi
    while IFS= read -r mount; do
        status=$(btrfs_bounded_optional scrub status "$mount" 2>&1) || {
            grep -qi 'no stats available' <<< "$status" && continue
            log "SMART" "INFO" "New $kind self-test deferred: scrub status unavailable on $mount"; return 1;
        }
        if grep -qiE 'status:[[:space:]]*running|scrub.*running' <<< "$status"; then
            log "SMART" "INFO" "New $kind self-test deferred: scrub active on $mount"; return 1
        fi
    done < <(findmnt -rn -t btrfs -o TARGET | sort -u)
    if [[ "$kind" == long ]] && (( SMART_LONG_STARTED || SMART_FLEET_LONG_RUNNING )); then
        log "SMART" "INFO" "New long self-test deferred: another long test is running/started"; return 1
    fi
    return 0
}

run_smart_test() {
    local disk=$1
    if ! prepare_smart_access "$disk"; then
        retain_previous_smart_snapshot "$disk" "${SATA_POWER_STATE[$disk]:-standby}"
        return 0
    fi
    local test_kind="short"
    local selftest poh_attr current_poh initial_smart_output
    local last_long_hours_diff="" last_long_poh="" threshold_hours=$(( LONG_TEST_MAX_INTERVAL_DAYS * 24 ))
    if [[ $disk == /dev/nvme* ]]; then
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART self-test log read (-l selftest) on $disk"
        selftest=$(smartctl_bounded -l selftest -d nvme "$disk" 2>/dev/null || true)
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART attribute read (-a) on $disk"
        initial_smart_output=$(smartctl_cached -a -d nvme "$disk" 2>/dev/null || true)
        if ! nvme_smart_output_is_complete "$initial_smart_output"; then
            record_collector_event FAILED "smartctl $disk" "incomplete_nvme_smart_output"
            log_warn "Incomplete NVMe SMART output for $disk; skipping replacement detection and test scheduling"
            return 0
        fi
        poh_attr=$(smart_labeled_field_value "$initial_smart_output" "Power On Hours" number)
    else
        selftest=$(smartctl_bounded -l selftest "$disk" 2>/dev/null || true)
        initial_smart_output=$(smartctl_cached -A "$disk" 2>/dev/null || true)
        if ata_smart_output_is_complete "$initial_smart_output"; then
            poh_attr=$(ata_smart_attribute_value "$initial_smart_output" "Power_On_Hours|Power_On_Hours_and_Msec")
        else
            initial_smart_output=$(smartctl_cached -a "$disk" 2>/dev/null || true)
            if ata_smart_output_is_complete "$initial_smart_output"; then
                poh_attr=$(ata_smart_attribute_value "$initial_smart_output" "Power_On_Hours|Power_On_Hours_and_Msec")
            elif scsi_smart_output_is_complete "$initial_smart_output"; then
                poh_attr=$(scsi_smart_field_value "$initial_smart_output" poh)
            else
                record_collector_event FAILED "smartctl $disk" "incomplete_ata_or_scsi_smart_output"
                log_warn "Incomplete ATA/SCSI SMART output for $disk; skipping replacement detection and test scheduling"
                return 0
            fi
        fi
    fi
    if [[ ! "$poh_attr" =~ ^[0-9]+$ ]]; then
        record_collector_event FAILED "smartctl $disk" "missing_power_on_hours"
        log_warn "SMART Power-On Hours missing for $disk; skipping replacement detection and test scheduling"
        return 0
    fi
    current_poh=$poh_attr
    if collector_device_has_blocking_event smart "$disk"; then
        log_warn "SMART collection incomplete on $disk; skipping replacement detection, evaluation, and test scheduling"
        return 0
    fi
    # Determine model/vendor and apply hardcoded pattern expansion
    local model_raw
    model_raw=$(get_device_model "$disk") || model_raw=""
    # Include generic "Extended" to cover NVMe long tests as well as SATA variants
    local patterns=("Extended" "Extended offline" "Extended self-test" "Long")
    if echo "$model_raw" | grep -qi 'ultrastar' && echo "$model_raw" | grep -qi 'wd\|western'; then
        patterns+=("Extended offline" "Extended" "Long offline" "Offline" "Extended-Offline" "Long_test")
    fi
    declare -A _seen_pat=()
    local p uniq_patterns=()
    for p in "${patterns[@]}"; do
        [[ -z "$p" ]] && continue
        if [[ -z "${_seen_pat[$p]:-}" ]]; then _seen_pat[$p]=1; uniq_patterns+=("$p"); fi
    done
    local combined_regex=""
    for p in "${uniq_patterns[@]}"; do
        [[ -n "$p" ]] && combined_regex+="${p}|"
    done
    combined_regex=${combined_regex%|}
    # Parse the newest non-short long-test row through the same pure parser
    # exercised by the Phase 11 fixtures.
    local latest_long_line parsed_long_line
    latest_long_line=$(select_latest_long_selftest_line "$selftest" "$combined_regex")
    if [[ -n "$latest_long_line" ]]; then
        parsed_long_line=$(parse_smart_selftest_output "$latest_long_line")
        last_long_poh=$(printf '%s' "$parsed_long_line" | awk -F'|' '{print $4}')
    fi
    if [[ -n "$last_long_poh" && $current_poh -gt 0 ]]; then
        # Monotonic guard: ignore regressed lifetime unless drive replacement (current_poh also regressed)
        local prev_ll=${LONG_LAST_POH["$disk"]:-}
        if [[ -n "$prev_ll" && "$prev_ll" =~ ^[0-9]+$ && "$last_long_poh" =~ ^[0-9]+$ ]]; then
            if (( last_long_poh < prev_ll )) && (( current_poh >= prev_ll )) && (( prev_ll - last_long_poh > 1 )); then
                log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Ignoring regressed last long-test lifetime $last_long_poh < $prev_ll on $disk (monotonic guard)"
            else
                LONG_LAST_POH["$disk"]="$last_long_poh"
            fi
        else
            LONG_LAST_POH["$disk"]="$last_long_poh"
        fi
        local eff_ll=${LONG_LAST_POH["$disk"]:-$last_long_poh}
        last_long_hours_diff=$(( current_poh - eff_ll ))
    elif [[ -z "$last_long_poh" && -n "${LONG_LAST_POH[$disk]:-}" && $current_poh -gt 0 ]]; then
        # Fallback to persisted last long POH when self-test log has no entries
        local persisted=${LONG_LAST_POH[$disk]}
        if [[ "$persisted" =~ ^[0-9]+$ && $current_poh -ge $persisted ]]; then
            last_long_hours_diff=$(( current_poh - persisted ))
        fi
    fi
    # Schedule from measured state and test age; no weighted risk score is used.
    local state_pre msgs_pre schedule_long=0 test_due=0 test_started=0 reasons=()
    evaluate_smart "$disk" "pre-test"
    if collector_device_has_blocking_event smart "$disk"; then
        log_warn "SMART evaluation incomplete on $disk; skipping SMART test scheduling"
        return 0
    fi
    state_pre="${SMART_STATE[$disk]:-OK}"
    msgs_pre="${SMART_MSGS[$disk]:-}"
    local crit_age_hours=$(( LONG_TEST_CRITICAL_MIN_DAYS * 24 ))
    # No previous long test record: optionally force initial long only if LONG_TEST_INITIAL_FORCE=1
    # If disabled, we simply skip auto-scheduling and rely on interval/critical triggers later.
    if [[ -z "${last_long_hours_diff:-}" ]]; then
        if (( LONG_TEST_INITIAL_FORCE == 1 )); then
            schedule_long=1; reasons+=("no record")
        else
            # Re-attempt extraction with combined vendor patterns already performed; if still empty we just skip forcing
            if [[ -n "$last_long_poh" && $current_poh -gt 0 ]]; then
                last_long_hours_diff=$(( current_poh - last_long_poh ))
            fi
        fi
    fi
    # Interval elapsed
    if [[ -n "${last_long_hours_diff:-}" && ${last_long_hours_diff} -ge $threshold_hours ]]; then schedule_long=1; reasons+=("interval ${last_long_hours_diff}h >= ${threshold_hours}h"); fi
    # Critical SMART state with sufficient age
    if [[ "$state_pre" == CRITICAL && ( -z "${last_long_hours_diff:-}" || ${last_long_hours_diff} -ge $crit_age_hours ) ]]; then schedule_long=1; reasons+=("critical state"); fi
    if (( schedule_long == 1 )); then
        test_kind="long"
        test_due=1
        local last_note="no record"
        [[ -n "${last_long_hours_diff:-}" ]] && last_note="${last_long_hours_diff}h"
        local reason_join
        reason_join=$(join_by ', ' "${reasons[@]}")
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - LONG test scheduled on $disk (last_long=${last_note}; reasons=${reason_join})"
        LONG_TEST_DECISION+="$disk: long scheduled (last=${last_note}; reasons=${reason_join}; state=${state_pre})\n"
    else
        if short_test_is_due "$disk"; then
            test_due=1
            log_smart "SHORT test due on $disk (interval=${SHORT_TEST_INTERVAL_DAYS}d, state=${state_pre})"
        elif [[ "${SHORT_TEST_INTERVAL_DAYS:-0}" =~ ^0+$ ]]; then
            log_smart "Automatic SHORT tests disabled for $disk (SHORT_TEST_INTERVAL_DAYS=0)"
        else
            local next_short_date
            next_short_date=$(short_test_next_date "$disk")
            log_smart "SHORT test not due on $disk${next_short_date:+; next eligible $next_short_date}"
        fi
    fi
    # If not scheduled yet but near interval, add to due-soon health alerts list
    if (( schedule_long == 0 )) && [[ -n "${last_long_hours_diff:-}" ]]; then
        local remaining=$(( threshold_hours - last_long_hours_diff ))
        if (( remaining > 0 )); then
            local days_left=$(( (remaining + 23) / 24 ))
            if (( days_left <= LONG_TEST_NEAR_WINDOW_DAYS )); then
                LONG_TEST_DUE_SOON["$disk"]=$days_left
            fi
        fi
    fi
    # Check for existing in-progress test
    local exec_status existing_in_progress=0
    if [[ $disk == /dev/nvme* ]]; then
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART capability read (-c) on $disk"
        exec_status=$(smartctl_bounded -c -d nvme "$disk" 2>/dev/null | awk -F: '/Self-test execution status/ {print $2}') || true
    else
        exec_status=$(smartctl_bounded -c "$disk" 2>/dev/null | awk -F: '/Self-test execution status/ {print $2}') || true
    fi
    if collector_device_has_blocking_event smart "$disk"; then
        log_warn "SMART capability read incomplete on $disk; skipping SMART test start"
        return 0
    fi
    if printf '%s\n%s\n' "$exec_status" "$selftest" | grep -qi 'in progress'; then
        existing_in_progress=1
        # Attempt to classify running test type via latest self-test log entry
        local latest
        latest=$(get_latest_selftest_info "$disk")
        local latest_type latest_status
        latest_type=$(echo "$latest" | awk -F'|' '{print $2}' )
        latest_status=$(echo "$latest" | awk -F'|' '{print $3}' )
        if echo "$latest_status" | grep -qi 'in progress' && echo "$latest_type" | grep -qiE 'extended|long'; then
            LONG_TEST_RUNNING_LONG["$disk"]=1
        fi
    fi
    if [[ $existing_in_progress -eq 1 ]]; then
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Self-test already in progress on $disk; skipping new start (status: ${exec_status})"
    elif (( test_due == 1 )) && smart_test_start_allowed "$test_kind"; then
        local test_start_output="" test_start_rc=0
        if [[ $disk == /dev/nvme* ]]; then
            log_smart "Starting NVMe SMART test (-t ${test_kind}) on $disk"
            test_start_output=$(smartctl_bounded -t "$test_kind" -d nvme "$disk" 2>&1)
            test_start_rc=$?
        else
            log_smart "Starting SATA SMART test (-t ${test_kind}) on $disk"
            test_start_output=$(smartctl_bounded -t "$test_kind" "$disk" 2>&1)
            test_start_rc=$?
        fi

        if (( test_start_rc == 0 )) ||
           printf '%s' "$test_start_output" |
               grep -qiE 'self-test.*(begun|started)|testing has begun|please wait'
        then
            test_started=1
            mark_test_started "$disk" "$test_kind"
            if [[ $test_kind == long || $test_kind == extended ]]; then
                LONG_TEST_RUNNING_LONG["$disk"]=1
                SMART_LONG_STARTED=1
            fi
        else
            local start_error
            start_error=$(printf '%s' "$test_start_output" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c1-240)
            log_warn "SMART test start failed on $disk (type=$test_kind, rc=$test_start_rc): ${start_error:-no output}"
            record_alert warning "SMART Test Start Failed" "Disk $disk failed to start $test_kind SMART test"
        fi
    fi
    if (( test_started == 1 )); then
        log "SMART" "INFO" "$disk: $test_kind self-test started asynchronously; results collected on a later run"
    fi
    # A test can change self-test/capability output. Drop only this run's cache before
    # the post-test read so no pre-test snapshot is accidentally reused.
    if (( test_started == 1 )); then
        invalidate_smart_cache "$disk"
    fi

    # Attribute health was evaluated once before scheduling. Short-test completion
    # is classified above, so a second full attribute pass would only duplicate
    # threshold alerts in the same run.
    local state="${SMART_STATE[$disk]:-OK}" msgs="${SMART_MSGS[$disk]:-}"
    if [[ $state == WARNING || $state == CRITICAL ]]; then
        record_alert "$state" "$NOTIFY_TITLE_SMART" "Disk $disk SMART $state: $msgs"
    fi
    # Persist a compact latest self-test snapshot (even when device self-test log is empty)
    save_selftest_snapshot "$disk"
}

# === Helper Function ===
# Append trend deltas (e.g., pending, realloc) to SMART messages
augment_messages_with_deltas() {
    for disk in "${!SMART_STATE[@]}"; do
        local raw="${SMART_MSGS[$disk]}"
        [[ -z "$raw" ]] && continue
        IFS=';' read -r -a parts <<< "$raw"
        local augmented=()
        for p in "${parts[@]}"; do
            p="${p#"${p%%[![:space:]]*}"}"
            p="${p%"${p##*[![:space:]]}"}"
            [[ -z "$p" ]] && continue
            local attr="" value="" prev="" cur="" delta=""
            if [[ $p =~ Reallocated\ =\ ([0-9]+) ]]; then attr=realloc; value=${BASH_REMATCH[1]}; fi
            if [[ $p =~ Pending\ sectors\ =\ ([0-9]+) ]]; then attr=pending; value=${BASH_REMATCH[1]}; fi
            if [[ $p =~ UDMA\ CRC\ Errors\ =\ ([0-9]+) ]]; then attr=udma; value=${BASH_REMATCH[1]}; fi
            if [[ $p =~ Soft\ Read\ Error\ Rate\ =\ ([0-9]+) ]]; then attr=soft_read_err; value=${BASH_REMATCH[1]}; fi
            if [[ -n "$attr" ]]; then
                prev=${PREV_ATTR["$disk|$attr"]:-}
                cur=${CUR_ATTR["$disk|$attr"]:-$value}
                if [[ -n "$prev" && "$cur" =~ ^[0-9]+$ && "$prev" =~ ^[0-9]+$ ]]; then
                    delta=$((cur - prev))
                    if (( delta > 0 )); then
                        p+=" (+${delta})"
                    fi
                fi
            fi
            local kind=""
            if [[ $p == Reallocated\ *=* ]]; then kind="realloc"; fi
            if [[ $p == Pending\ sectors* ]]; then kind="pending"; fi
            if [[ $p == UDMA\ CRC\ Errors* ]]; then kind="udma"; fi
            if [[ $p == Soft\ Read\ Error\ Rate* ]]; then kind="soft_read"; fi
            if [[ $p == Offline\ Uncorrectable* || $p == Reported\ Uncorrectable* ]]; then kind="uncorrect"; fi
            if [[ $p == NVMe\ thermal* ]]; then kind="nvme_thermal"; fi
            if [[ $p == NVMe\ reliability* ]]; then kind="nvme_rel"; fi
            if [[ $p == NVMe\ media\ in\ read-only* ]]; then kind="nvme_ro"; fi
            if [[ $p == NVMe\ Available\ Spare* ]]; then kind="nvme_spare"; fi
            if [[ $p == NVMe\ media/data\ integrity\ errors* ]]; then kind="nvme_media"; fi
            local prev_state_tag=${PREV_ATTR["$disk|state"]:-OK}
            local new_key="$disk|${kind:-generic}"
            if [[ "${SMART_STATE[$disk]}" != OK && "$prev_state_tag" == OK && -z "${NEW_SEEN[$new_key]:-}" ]]; then
                p="NEW: $p"; NEW_SEEN[$new_key]=1
            fi
            augmented+=("$p")
            attr=""; value=""; prev=""; cur=""; delta=""
        done
        SMART_MSGS[$disk]="$(printf "%s; " "${augmented[@]}")"
    done
}

# === Helper Function ===
# Detect newly completed long tests and summarize result
check_completed_long_tests() {
    declare -A PROCESSED=()
    local -a disks=()
    local disk temp_file d id stored_key state_key

    if [[ -f "$SMART_LONG_STATE_FILE" ]]; then
        while read -r stored_key id; do
            d=$(runtime_device_path "$stored_key" 2>/dev/null || true)
            [[ -n "$d" && -n "$id" ]] && PROCESSED[$d]="$id"
        done < "$SMART_LONG_STATE_FILE"
    fi
    mapfile -t disks < <(get_all_disks)
    SMART_FLEET_LONG_RUNNING=0
    local capabilities fleet_log
    for disk in "${disks[@]}"; do
        prepare_smart_access "$disk" || continue
        if [[ "$disk" == /dev/nvme* ]]; then
            capabilities=$(smartctl_cached -c -d nvme "$disk" 2>/dev/null || true)
            fleet_log=$(smartctl_cached -l selftest -d nvme "$disk" 2>/dev/null || true)
        else
            capabilities=$(smartctl_cached -c "$disk" 2>/dev/null || true)
            fleet_log=$(smartctl_cached -l selftest "$disk" 2>/dev/null || true)
        fi
        if grep -qi 'in progress' <<< "$capabilities$fleet_log"; then
            # An unidentified in-progress self-test also holds new long tests.
            SMART_FLEET_LONG_RUNNING=1
        fi
    done
    for disk in "${disks[@]}"; do
        [[ -n "$disk" ]] || continue
        # Sanitize disk before smartctl invocations
        if [[ ! "$disk" =~ ^/dev/[A-Za-z0-9]+([p0-9]+)?$ ]]; then continue; fi
        # Do not wake sleeping rotational devices merely to inspect an old
        # self-test log. run_smart_test() will retain their previous snapshot.
        if ! prepare_smart_access "$disk"; then
            continue
        fi
        local out model_raw
        if [[ $disk == /dev/nvme* ]]; then
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART self-test log read (-l selftest) on $disk"
            out=$(smartctl_bounded -l selftest -d nvme "$disk" 2>/dev/null || true)
        else
            out=$(smartctl_bounded -l selftest "$disk" 2>/dev/null || true)
        fi
        model_raw=$(get_device_model "$disk") || model_raw=""
        # Build unified long-test pattern list (include generic "Extended" for NVMe devices)
        local patterns=("Extended" "Extended offline" "Extended self-test" "Long" "Extended-Offline" "Long offline" "Offline")
        if echo "$model_raw" | grep -qi 'ultrastar' && echo "$model_raw" | grep -qi 'wd\|western'; then
            patterns+=("Extended" "Long_test")
        fi
        declare -A _seen_lp; local p uniq_lp=()
        for p in "${patterns[@]}"; do
            [[ -z "$p" ]] && continue
            if [[ -z "${_seen_lp[$p]:-}" ]]; then _seen_lp[$p]=1; uniq_lp+=("$p"); fi
        done
        local rgx=""
        for p in "${uniq_lp[@]}"; do
            [[ -n "$p" ]] && rgx+="${p}|"
        done
        rgx=${rgx%|}
        local line
        line=$(select_latest_long_selftest_line "$out" "$rgx")
        [[ -z "$line" ]] && continue
        local id type status lifetime remaining parsed_selftest
        parsed_selftest=$(parse_smart_selftest_output "$line")
        IFS='|' read -r id type status lifetime remaining <<< "$parsed_selftest"
        if [[ ${PROCESSED[$disk]:-} == "$id" ]]; then continue; fi
        if echo "$status" | grep -qi 'in progress'; then continue; fi
        local class msg sev
        class=$(classify_selftest_status "$status")
        sev=$(echo "$class" | awk -F'|' '{print $1}')
        msg=$(echo "$class" | awk -F'|' '{print $2}')
        if [[ $sev == WARNING ]]; then
            record_alert warning "$NOTIFY_TITLE_SMART" "Disk $disk long self-test warning: $msg"
        elif [[ $sev == CRITICAL ]]; then
            record_alert critical "$NOTIFY_TITLE_SMART" "Disk $disk long self-test CRITICAL: $msg"
        fi
        local poh current_poh
        if [[ -n "${lifetime:-}" && "$lifetime" =~ ^[0-9]+$ ]]; then
            local prev_ll=${LONG_LAST_POH["$disk"]:-}
            if [[ -n "$prev_ll" && "$prev_ll" =~ ^[0-9]+$ && $lifetime -lt $prev_ll ]]; then
                # Need current POH to decide replacement vs regression
                local cur_poh cur_poh_output
                if [[ $disk == /dev/nvme* ]]; then
                    cur_poh_output=$(smartctl_cached -a -d nvme "$disk" 2>/dev/null || true)
                    cur_poh=$(smart_labeled_field_value "$cur_poh_output" "Power On Hours" number)
                else
                    cur_poh_output=$(smartctl_cached -A "$disk" 2>/dev/null || true)
                    cur_poh=$(ata_smart_attribute_value "$cur_poh_output" "Power_On_Hours|Power_On_Hours_and_Msec")
                    if [[ -z "$cur_poh" ]]; then
                        cur_poh_output=$(smartctl_cached -a "$disk" 2>/dev/null || true)
                        cur_poh=$(scsi_smart_field_value "$cur_poh_output" poh)
                    fi
                fi
                if [[ "$cur_poh" =~ ^[0-9]+$ && $cur_poh -ge $prev_ll && $(( prev_ll - lifetime )) -gt 1 ]]; then
                    log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Ignoring regressed long-test POH $lifetime < $prev_ll on $disk (monotonic guard)"
                else
                    LONG_LAST_POH["$disk"]="$lifetime"
                    log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Recorded last long-test POH for $disk from self-test log: ${lifetime}h"
                fi
            else
                LONG_LAST_POH["$disk"]="$lifetime"
                log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Recorded last long-test POH for $disk from self-test log: ${lifetime}h"
            fi
        else
            if [[ $disk == /dev/nvme* ]]; then
                log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART attribute read (-a) for POH fallback on $disk"
                local poh_output
                poh_output=$(smartctl_cached -a -d nvme "$disk" 2>/dev/null || true)
                poh=$(smart_labeled_field_value "$poh_output" "Power On Hours" number)
            else
                local poh_output
                poh_output=$(smartctl_cached -A "$disk" 2>/dev/null || true)
                poh=$(ata_smart_attribute_value "$poh_output" "Power_On_Hours|Power_On_Hours_and_Msec")
                if [[ -z "$poh" ]]; then
                    poh_output=$(smartctl_cached -a "$disk" 2>/dev/null || true)
                    poh=$(scsi_smart_field_value "$poh_output" poh)
                fi
            fi
            if [[ -n "${poh:-}" && "$poh" =~ ^[0-9]+$ ]]; then
                LONG_LAST_POH["$disk"]="$poh"
                log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Recorded last long-test POH for $disk from POH fallback: ${poh}h"
            fi
        fi
        PROCESSED["$disk"]="$id"
    done

    temp_file="$(state_temp_file "$SMART_LONG_STATE_FILE")" || return 0
    for disk in "${!PROCESSED[@]}"; do
        state_key=$(persistent_device_key "$disk")
        printf '%s %s\n' "$state_key" "${PROCESSED[$disk]}" >> "$temp_file"
    done
    collector_atomic_commit "$temp_file" "$SMART_LONG_STATE_FILE" || true
}

# === Main Function ===
# Monitor Btrfs filesystems for scrub status
# shellcheck disable=SC2329
monitor_btrfs() {
    # Prune aged persisted status files to avoid indefinite growth
    if [[ -d "$BTRFS_SCRUB_STATE_DIR" && ${BTRFS_SCRUB_STATE_TTL_DAYS:-0} -gt 0 ]]; then
        find "$BTRFS_SCRUB_STATE_DIR" -type f -name '*.status' -mtime +"${BTRFS_SCRUB_STATE_TTL_DAYS}" -delete 2>/dev/null || true
    fi
    local all_mounts filtered=()
    mapfile -t all_mounts < <(mount | awk '$5=="btrfs" {print $3}' | sort -u)
    local m
    for m in "${all_mounts[@]}"; do
        local skip=0 base
        for base in "${filtered[@]}"; do
            if [[ "$m" == "$base" ]]; then skip=1; break; fi
            if [[ "$m" == "$base"/* ]]; then skip=1; break; fi
        done
        (( skip==0 )) && filtered+=("$m")
    done
    log_btrfs "Reading recorded Btrfs scrub status for ${#filtered[@]} mount(s); no scrub is started"
    for m in "${filtered[@]}"; do
        # Per-mount persisted file key
        local key file
        key="$(safe_state_name "$m")"
        file="$BTRFS_SCRUB_STATE_DIR/${key}.status"
        local data_raid meta_raid
        # Try pretty (-p) output; fallback to default if unsupported by btrfs-progs
        btrfs_df_cached "$m"
        data_raid="${BTRFS_DF_CACHE_DATA[$m]:-UNKNOWN}"
        meta_raid="${BTRFS_DF_CACHE_META[$m]:-UNKNOWN}"
        data_raid=${data_raid:-UNKNOWN}
        meta_raid=${meta_raid:-UNKNOWN}
        local status corrected uncorrectable msg fresh=0
        if ! status=$(btrfs_bounded_optional scrub status "$m" 2>&1) &&
           ! grep -qi "no stats available" <<< "$status"; then
            record_collector_event FAILED "Btrfs scrub $m" "unable to read scrub status"
            continue
        fi
        if grep -qiE 'Status:[[:space:]]+finished|scrub finished' <<< "$status" &&
           grep -qiE 'no errors found|uncorrectable:|unrecoverable errors' <<< "$status"
        then
            FRESH_FILESYSTEM["scrub:$m"]=1
            fresh=1
        fi
        # If kernel has no recorded stats (e.g., post-reboot), load our persisted last status for this mount
        if echo "$status" | grep -qi "no stats available"; then
            if [[ -s "$file" ]]; then
                status=$(cat "$file" 2>/dev/null || true)
            else
                # No kernel stats and no persisted file: emit a clear synthetic summary line
                log_btrfs "$m: Last scrub: none recorded"
            fi
        fi
        log_btrfs "Scrub status $m (Data: $data_raid Meta: $meta_raid)"
        while IFS= read -r ln; do
            [[ -z "$ln" ]] && continue
            log_btrfs "$m: $ln"
        done < <(awk '!/^Saved:/ || !saved++' <<< "$status")
        if (( fresh == 1 )) &&
           { [[ ! -s "$file" ]] || [[ "$(sed '/^Saved:/d' "$file")" != "$status" ]]; }; then
            local status_temp
            status_temp="$(state_temp_file "$file")" || status_temp=""
            if [[ -n "$status_temp" ]]; then
                {
                    printf "Saved: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
                    printf "%s" "$status"
                } > "$status_temp" && collector_atomic_commit "$status_temp" "$file" || return 1
            else
                return 1
            fi
        fi
        # If status indicates no stats available, add explicit synthetic summary for clarity
        if echo "$status" | grep -qi "no stats available"; then
            log_btrfs "$m: Last scrub: none recorded"
        fi
        local scrub_date scrub_epoch scrub_age
        scrub_date=$(sed -nE 's/^[[:space:]]*Scrub started:[[:space:]]*//p; s/.*scrub started at[[:space:]]*//p' <<< "$status" | head -n1)
        scrub_epoch=$(date -d "$scrub_date" +%s 2>/dev/null || true)
        if [[ -n "$scrub_date" && "$scrub_epoch" =~ ^[0-9]+$ ]] && (( scrub_epoch <= RUN_EPOCH )); then
            scrub_age=$(( (RUN_EPOCH-scrub_epoch)/86400 ))
            log_btrfs "$m: recorded scrub started=$scrub_date; age=${scrub_age}d; observation=${fresh:-0} (1=live status, 0=cached)"
        else
            log_btrfs "$m: recorded scrub date unavailable; freshness is unverified"
        fi
        corrected=$(awk '{for(i=1;i<NF;i++) if ($i=="Corrected:" || ($i=="corrected" && $(i+1)=="errors:")) {print $(i+($i=="Corrected:"?1:2)); exit}}' <<< "$status")
        uncorrectable=$(awk '{for(i=1;i<NF;i++) if ($i=="Uncorrectable:" || ($i=="unrecoverable" && $(i+1)=="errors:")) {print $(i+($i=="Uncorrectable:"?1:2)); exit}}' <<< "$status")
        [[ "$corrected" =~ ^[0-9]+$ ]] || corrected=0
        [[ "$uncorrectable" =~ ^[0-9]+$ ]] || uncorrectable=0
        if [[ $uncorrectable -gt 0 ]]; then
            if [[ "$data_raid" =~ RAID0 || "$meta_raid" =~ RAID0 ]]; then
                msg="CRITICAL: $m RAID0 segment unrecoverable errors=$uncorrectable"
            else
                msg="CRITICAL: $m unrecoverable errors=$uncorrectable"
            fi
            log_btrfs "$msg"
            record_alert critical "$NOTIFY_TITLE_BTRFS" "$msg"
        elif [[ $corrected -gt 0 ]]; then
            msg="WARNING: $m scrub corrected=$corrected"
            log_btrfs "$msg"
            record_alert warning "$NOTIFY_TITLE_BTRFS" "$msg"
        fi
    done
    log_btrfs "Btrfs scrub status collection completed; reported dates belong to recorded scrubs"
}

# === Main Function ===
# Monitor XFS filesystems for metadata issues
# shellcheck disable=SC2329

# === Main Function ===
# Evaluate array and pool capacity against thresholds
# shellcheck disable=SC2329
evaluate_capacity_alerts() {
    if [[ -n "${ARRAY_PERCENT:-}" ]]; then
        # Critical if usage exceeds configured threshold
        if awk -v p="${ARRAY_PERCENT:-0}" -v t="$THRESHOLD" 'BEGIN{exit (p>t)?0:1}'; then
            record_alert critical "Array Capacity" "Array usage ${ARRAY_PERCENT:-0}% > ${THRESHOLD}%"
        # Warning if approaching threshold within NEAR_THRESHOLD_DELTA
        elif awk -v p="${ARRAY_PERCENT:-0}" -v t="$THRESHOLD" -v d="$NEAR_THRESHOLD_DELTA" 'BEGIN{exit (p + d >= t)?0:1}'; then
            record_alert warning "Array Capacity" "Array usage ${ARRAY_PERCENT:-0}% near ${THRESHOLD}%"
        fi
    fi
    if [[ -n "${POOLS_PERCENT:-}" ]]; then
        # Critical / warning evaluation mirrors array logic for pooled storage
        if awk -v p="${POOLS_PERCENT:-0}" -v t="$THRESHOLD" 'BEGIN{exit (p>t)?0:1}'; then
            record_alert critical "Pools Capacity" "Pools usage ${POOLS_PERCENT:-0}% > ${THRESHOLD}%"
        elif awk -v p="${POOLS_PERCENT:-0}" -v t="$THRESHOLD" -v d="$NEAR_THRESHOLD_DELTA" 'BEGIN{exit (p + d >= t)?0:1}'; then
            record_alert warning "Pools Capacity" "Pools usage ${POOLS_PERCENT:-0}% near ${THRESHOLD}%"
        fi
    fi
}

# === Helper Function ===
# Evaluate mountpoint usage against defined thresholds
# shellcheck disable=SC2329

# === Main Collection Phase ===
# Collect SMART health and measured wear history; schedule tests without waiting.
update_smart_coverage() {
    local disk identity first last rows="" age=0
    local -A first_seen=() last_fresh=()
    if [[ -s "$SMART_COVERAGE_FILE" ]]; then
        while IFS=$'\t' read -r identity first last; do
            [[ -n "$identity" && "$first" =~ ^[1-9][0-9]{0,11}$ && "$last" =~ ^(0|[1-9][0-9]{0,11})$ ]] || continue
            first_seen[$identity]="$first"
            last_fresh[$identity]="$last"
        done < "$SMART_COVERAGE_FILE"
    fi
    for disk in "$@"; do
        identity=$(persistent_device_key "$disk")
        first="${first_seen[$identity]:-$RUN_EPOCH}"
        last="${last_fresh[$identity]:-0}"
        if [[ -n "${FRESH_SMART[$disk]:-}" ]]; then last="$RUN_EPOCH"; fi
        printf -v rows '%s%s\t%s\t%s\n' "$rows" "$identity" "$first" "$last"
        age=$(( RUN_EPOCH - (last > 0 ? last : first) ))
        if (( age >= 14 * 86400 )); then
            record_finding warning monitoring monitoring.smart_coverage "$disk" \
                "SMART data overdue" "No fresh SMART sample for $((age / 86400)) days." \
                "Arrange one SMART read while the disk is awake and check controller access if it fails." \
                smart_coverage
        fi
    done
    atomic_write_text "$SMART_COVERAGE_FILE" "$rows"
}

# shellcheck disable=SC2329
collect_smart_health() {
    local -a disks=()
    local disk today tmp poh line key val stored_key

    log_smart "Collecting SMART health and scheduling eligible asynchronous self-tests"
    check_completed_long_tests
    mapfile -t disks < <(get_all_disks)
    SMART_FLEET_LONG_RUNNING=0
    local capabilities fleet_log
    for disk in "${disks[@]}"; do
        prepare_smart_access "$disk" || continue
        if [[ "$disk" == /dev/nvme* ]]; then
            capabilities=$(smartctl_cached -c -d nvme "$disk" 2>/dev/null || true)
            fleet_log=$(smartctl_cached -l selftest -d nvme "$disk" 2>/dev/null || true)
        else
            capabilities=$(smartctl_cached -c "$disk" 2>/dev/null || true)
            fleet_log=$(smartctl_cached -l selftest "$disk" 2>/dev/null || true)
        fi
        if grep -qi 'in progress' <<< "$capabilities$fleet_log"; then
            # An unidentified in-progress self-test also holds new long tests.
            SMART_FLEET_LONG_RUNNING=1
        fi
    done
    for disk in "${disks[@]}"; do
        [[ -n "$disk" ]] || continue
        run_smart_test "$disk"
        if collector_device_has_blocking_event smart "$disk"; then
            for tmp in "${!CUR_ATTR[@]}"; do
                [[ "$tmp" == "$disk|"* ]] && unset 'CUR_ATTR[$tmp]'
            done
            retain_previous_smart_snapshot "$disk" "collection-unavailable"
            log "SMART" "WARN" \
                "Live SMART data was incomplete for $disk; retained its previous known baseline"
        elif [[ -z "${SMART_DEFERRED[$disk]:-}" && -n "${SMART_STATE[$disk]:-}" ]]; then
            FRESH_SMART[$disk]=1
        fi
    done
    update_smart_coverage "${disks[@]}" || return 1
    log_smart "SMART collection and test scheduling completed; pending tests are not declared complete"
    augment_messages_with_deltas

    # Keep the measured NVMe wear signal and timestamps for history and regressions.
    # Existing rows with additional SMART fields remain readable.
    if (( WEAR_TREND_ENABLED == 1 )); then
        today=$(date '+%Y-%m-%d')
        local -a wear_records=()
        for disk in "${!FRESH_SMART[@]}"; do
            [[ "$disk" == /dev/nvme* ]] || continue
            val=${CUR_ATTR["$disk|nvme_percent_used"]:-}
            [[ "$val" =~ ^[0-9]+$ ]] || continue
            wear_records+=("$today $(persistent_device_key "$disk") nvme_percent_used=$val captured_epoch=$RUN_EPOCH schema=$HISTORY_SCHEMA_VERSION")
        done
        collector_replace_daily_history "$SMART_ATTR_HISTORY_FILE" "$today" "${wear_records[@]}" ||
            log_warn "Unable to atomically update NVMe wear history"
    fi

}

# === Helper Function ===
# Check btrfs snapshot counts against thresholds.
# shellcheck disable=SC2329

# Append a fixed, inclusive line range without reading lines appended after the
# metadata snapshot. Called directly so write failures propagate to the cursor
# builder instead of being hidden by command substitution.
append_syslog_line_range() {
    local source="$1" start_line="$2" end_line="$3" target="$4"

    (( start_line <= end_line )) || return 0
    sed -n "${start_line},${end_line}p" "$source" >> "$target"
}

# Build the exact syslog chunk for this run and stage the cursor metadata that
# may be committed only after the I/O history update succeeds.
build_new_syslog_chunk() {
    local source="$IO_ERROR_LOG_FILE"
    local metadata current_device current_inode current_size current_lines current_anchor="-"
    local schema="" previous_path="" previous_device="" previous_inode=""
    local previous_lines=0 previous_size=0 previous_anchor="-" start_line reason
    local rotated rotated_metadata rotated_device rotated_inode rotated_size rotated_lines
    local recovered=0 anchor_matches=0 observed_anchor="" generation next
    local verify_metadata verify_device verify_inode verify_size chunk_lines

    SYSLOG_CURSOR_READY=0
    SYSLOG_CURSOR_MODE="not_run"
    SYSLOG_CHUNK_FILE="$RUN_DIR/syslog.incremental.log"
    : > "$SYSLOG_CHUNK_FILE" || return 1

    if [[ ! -r "$source" ]]; then
        log "SYSLOG" "WARN" "$source is unavailable; preserving the cursor for a retry"
        return 1
    fi

    metadata=$(stat -c '%d %i %s' -- "$source" 2>/dev/null) || return 1
    read -r current_device current_inode current_size <<< "$metadata"
    current_lines=$(wc -l < "$source" 2>/dev/null || echo 0)
    current_lines=${current_lines//[[:space:]]/}
    [[ "$current_device" =~ ^[0-9]+$ && "$current_inode" =~ ^[0-9]+$ ]] || return 1
    [[ "$current_size" =~ ^[0-9]+$ && "$current_lines" =~ ^[0-9]+$ ]] || return 1
    if (( current_lines > 0 )); then
        current_anchor=$(sed -n "${current_lines}p" "$source" 2>/dev/null | sha1sum | awk '{print $1}')
        [[ -n "$current_anchor" ]] || current_anchor="-"
    fi

    if [[ -s "$SYSLOG_CURSOR_STATE_FILE" ]]; then
        read -r schema previous_path previous_device previous_inode previous_lines previous_size previous_anchor \
            < "$SYSLOG_CURSOR_STATE_FILE" || true
    fi
    if [[ "$schema" != "v2" || ! "$previous_device" =~ ^[0-9]+$ ||
          ! "$previous_inode" =~ ^[0-9]+$ || ! "$previous_lines" =~ ^[0-9]+$ ||
          ! "$previous_size" =~ ^[0-9]+$ || -z "$previous_anchor" ]]; then
        schema=""
        previous_lines=0
        previous_size=0
        previous_anchor="-"
    fi

    if [[ -n "$schema" && "$previous_path" == "$source" &&
          "$previous_device" == "$current_device" && "$previous_inode" == "$current_inode" &&
          "$current_lines" -ge "$previous_lines" && "$current_size" -ge "$previous_size" ]]; then
        if (( previous_lines == 0 )) || [[ "$previous_anchor" == "-" ]]; then
            anchor_matches=1
        else
            observed_anchor=$(sed -n "${previous_lines}p" "$source" 2>/dev/null | sha1sum | awk '{print $1}')
            [[ "$observed_anchor" == "$previous_anchor" ]] && anchor_matches=1
        fi
    fi

    if [[ -z "$schema" ]]; then
        if (( current_lines > SYSLOG_CURSOR_STARTUP_LOOKBACK_LINES )); then
            start_line=$(( current_lines - SYSLOG_CURSOR_STARTUP_LOOKBACK_LINES + 1 ))
        else
            start_line=1
        fi
        append_syslog_line_range "$source" "$start_line" "$current_lines" "$SYSLOG_CHUNK_FILE" || return 1
        reason="initial lookback"
        SYSLOG_CURSOR_MODE="initial_lookback"
    elif (( anchor_matches == 1 )); then
        start_line=$(( previous_lines + 1 ))
        append_syslog_line_range "$source" "$start_line" "$current_lines" "$SYSLOG_CHUNK_FILE" || return 1
        reason="cursor continuation"
        SYSLOG_CURSOR_MODE="cursor_continuation"
    else
        for generation in 1 2 3 4 5 6 7 8 9 0; do
            [[ "$previous_path" == "$source" ]] || break
            rotated="${source}.$generation"
            [[ -r "$rotated" ]] || continue
            rotated_metadata=$(stat -c '%d %i %s' -- "$rotated" 2>/dev/null) || continue
            read -r rotated_device rotated_inode rotated_size <<< "$rotated_metadata"
            [[ "$rotated_device" == "$previous_device" && "$rotated_inode" == "$previous_inode" ]] || continue
            rotated_lines=$(wc -l < "$rotated" 2>/dev/null || echo 0)
            rotated_lines=${rotated_lines//[[:space:]]/}
            [[ "$rotated_lines" =~ ^[0-9]+$ ]] || continue
            (( rotated_lines >= previous_lines && rotated_size >= previous_size )) || continue
            if (( previous_lines > 0 )) && [[ "$previous_anchor" != "-" ]]; then
                observed_anchor=$(sed -n "${previous_lines}p" "$rotated" 2>/dev/null | sha1sum | awk '{print $1}')
                [[ "$observed_anchor" == "$previous_anchor" ]] || continue
            fi
            append_syslog_line_range "$rotated" "$(( previous_lines + 1 ))" "$rotated_lines" "$SYSLOG_CHUNK_FILE" || return 1
            for (( next=generation-1; next>=1; next-- )); do
                [[ -r "${source}.$next" ]] || break
                cat -- "${source}.$next" >> "$SYSLOG_CHUNK_FILE" || return 1
            done
            if (( next >= 1 )); then
                : > "$SYSLOG_CHUNK_FILE" || return 1
                break
            fi
            append_syslog_line_range "$source" 1 "$current_lines" "$SYSLOG_CHUNK_FILE" || return 1
            recovered=1
            reason="rotation recovery via ${rotated}"
            SYSLOG_CURSOR_MODE="rotation_recovery"
            break
        done

        if (( recovered == 0 )); then
            if (( current_lines > SYSLOG_CURSOR_ROTATION_LOOKBACK_LINES )); then
                start_line=$(( current_lines - SYSLOG_CURSOR_ROTATION_LOOKBACK_LINES + 1 ))
            else
                start_line=1
            fi
            append_syslog_line_range "$source" "$start_line" "$current_lines" "$SYSLOG_CHUNK_FILE" || return 1
            reason="rotation/truncation fallback"
            SYSLOG_CURSOR_MODE="rotation_fallback"
            log "SYSLOG" "WARN" \
                "Previous syslog inode was unavailable; scanning the last ${SYSLOG_CURSOR_ROTATION_LOOKBACK_LINES} line(s)"
        fi
    fi

    # Do not advance a cursor captured across a concurrent rotation. The chunk
    # remains safe to process because event hashes are de-duplicated; the next
    # run will retry from the last committed cursor.
    verify_metadata=$(stat -c '%d %i %s' -- "$source" 2>/dev/null || true)
    read -r verify_device verify_inode verify_size <<< "$verify_metadata"
    if [[ "$verify_device" != "$current_device" || "$verify_inode" != "$current_inode" ||
          ! "$verify_size" =~ ^[0-9]+$ || "$verify_size" -lt "$current_size" ]] ||
       { (( current_lines > 0 )) &&
         [[ "$(sed -n "${current_lines}p" "$source" | sha1sum | awk '{print $1}')" != "$current_anchor" ]]; }; then
        SYSLOG_CURSOR_MODE="concurrent_rotation"
        log "SYSLOG" "WARN" "Syslog rotated while its incremental chunk was being built; cursor advancement deferred"
        return 1
    fi

    SYSLOG_CURSOR_PENDING_PATH="$source"
    SYSLOG_CURSOR_PENDING_DEVICE="$current_device"
    SYSLOG_CURSOR_PENDING_INODE="$current_inode"
    SYSLOG_CURSOR_PENDING_LINES="$current_lines"
    SYSLOG_CURSOR_PENDING_SIZE="$current_size"
    SYSLOG_CURSOR_PENDING_ANCHOR="$current_anchor"
    SYSLOG_CURSOR_READY=1

    chunk_lines=$(wc -l < "$SYSLOG_CHUNK_FILE" 2>/dev/null || echo 0)
    chunk_lines=${chunk_lines//[[:space:]]/}
    log "SYSLOG" "INFO" \
        "Prepared ${chunk_lines:-0} new line(s) using ${reason}"
}

commit_syslog_cursor() {
    (( SYSLOG_CURSOR_READY == 1 )) || return 0
    collector_atomic_write_text "$SYSLOG_CURSOR_STATE_FILE" \
        "v2 $SYSLOG_CURSOR_PENDING_PATH $SYSLOG_CURSOR_PENDING_DEVICE $SYSLOG_CURSOR_PENDING_INODE $SYSLOG_CURSOR_PENDING_LINES $SYSLOG_CURSOR_PENDING_SIZE $SYSLOG_CURSOR_PENDING_ANCHOR"$'\n'
}

syslog_timestamp_epoch() {
    local line="$1" now_epoch="$2"
    local timestamp year epoch

    timestamp=$(printf '%s\n' "$line" | awk '{print $1" "$2" "$3}')
    if [[ "$timestamp" =~ ^[A-Z][a-z]{2}\ [0-9]{1,2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        year=$(date '+%Y')
        epoch=$(date -d "$timestamp $year" +%s 2>/dev/null || echo "$now_epoch")
        if (( epoch > now_epoch + 86400 )); then
            epoch=$(date -d "$timestamp $(( year - 1 ))" +%s 2>/dev/null || echo "$now_epoch")
        fi
        printf '%s' "$epoch"
    else
        printf '%s' "$now_epoch"
    fi
}

# Scan only the new syslog chunk, count unique disk I/O events in the configured
# time window, then atomically advance history and cursor together.
# shellcheck disable=SC2329
# Read one inventory snapshot for attribution. Only use actual mounted XFS sources.
map_xfs_syslog_sources() {
    local rows source mount filesystem
    rows=$(findmnt_bounded -rn -o SOURCE,TARGET,FSTYPE) || return 1
    while read -r source mount filesystem; do
        [[ "$filesystem" == xfs && "$source" =~ ^/dev/[[:alnum:]_.-]+$ && "$mount" == /mnt/* ]] || continue
        XFS_SYSLOG_MOUNTS["${source#/dev/}"]="$mount"
        case "$SYSLOG_CURSOR_MODE" in
            cursor_continuation|rotation_recovery) FRESH_FILESYSTEM["xfs:$mount"]=1 ;;
        esac
    done <<< "$rows"
}

record_xfs_syslog_event() {
    local line="$1" source mount severity=warning
    local prefix='kernel:[[:space:]]+XFS[[:space:]]+\(([[:alnum:]_.-]+)\):'
    [[ "$line" =~ $prefix ]] || return 1
    source="${BASH_REMATCH[1]}"
    case "${line,,}" in
        *corrupt*|*shutdown*|*"shut down"*|*"shutting down"*) severity=critical ;;
        *"i/o error"*|*"log error"*|*"metadata error"*) ;;
        *) return 1 ;;
    esac
    (( SYSLOG_FAST_STORAGE_OWNER == 0 )) || return 0
    mount="${XFS_SYSLOG_MOUNTS[$source]:-}"
    [[ -n "$mount" ]] || return 1
    record_finding "$severity" filesystem filesystem.xfs "" \
        "XFS kernel error" "${line#*kernel: }" \
        "Check Unraid diagnostics and backups for this filesystem before scheduling an offline check." \
        xfs_kernel_error "mount:$mount"
}

# Peak distinct event count in any rolling window ending at a newly read event.
peak_syslog_bursts() {
    local window="$1" events="$2"
    LC_ALL=C sort -k1,1 -k2,2n -k3,3 "$events" | awk -v window="$window" '
        function emit() { if (key != "" && peak > 0) print key, peak }
        $1 != key { emit(); key=$1; first=1; last=0; peak=0; previous="" }
        {
            signature=$2 FS $3
            if (signature != previous) { timestamps[++last]=$2; previous=signature }
            while (first <= last && timestamps[first] < $2-window) delete timestamps[first++]
            if ($4 == 1 && last-first+1 > peak) peak=last-first+1
        }
        END { emit() }
    '
}

scan_syslog_disk_errors() {
    local window=$(( IO_ERROR_WINDOW_MINUTES * 60 )) now cutoff device key timestamp hash
    local events="$RUN_DIR/io-events.tsv" line devices rows peak history heartbeat=0
    local kernel='^[^ ]+ +([0-9]+ [0-9:]+ +)?[^ ]+ +kernel:[[:space:]]'
    local -A XFS_SYSLOG_MOUNTS=()
    now=$(date +%s) || return 1
    cutoff=$((now - window))
    : > "$events" || return 1
    build_new_syslog_chunk || return 1
    if [[ "$SYSLOG_CURSOR_MODE" == rotation_fallback ]]; then
        record_finding warning io io.kernel "" "Syslog coverage gap" \
            "A complete rotation chain was unavailable; some disk I/O events may have been missed." \
            "Check syslog retention and the fast syslog watcher." syslog_coverage_gap
    fi
    if (( SYSLOG_FAST_STORAGE_OWNER == 1 )); then
        if [[ -f "$SYSLOG_FAST_HEARTBEAT" && ! -L "$SYSLOG_FAST_HEARTBEAT" ]] &&
           [[ "$(stat -c %u -- "$SYSLOG_FAST_HEARTBEAT" 2>/dev/null)" == "$EUID" ]]; then
            read -r heartbeat < "$SYSLOG_FAST_HEARTBEAT" || heartbeat=0
        fi
        if [[ ! "$heartbeat" =~ ^[1-9][0-9]{0,11}$ ]] || (( heartbeat > now || now-heartbeat > 1200 )); then
            record_finding warning io io.kernel "" "Fast storage watcher not current" \
                "No successful fast syslog scan in the last 20 minutes." \
                "Check the syslog_watchdog User Script and its five-minute schedule." syslog_fast_watcher_stale
        fi
    else
        map_xfs_syslog_sources || return 1
    fi

    if (( SYSLOG_FAST_STORAGE_OWNER == 1 )) && [[ "$heartbeat" =~ ^[1-9][0-9]{0,11}$ ]] &&
       (( heartbeat <= now && now-heartbeat <= 1200 )) &&
       ! grep -Eq '^finding.*(disk_i_o_alert|disk_io_burst|xfs_kernel_error)' "$NOTIFICATION_JOURNAL_FILE" 2>/dev/null; then
        log "IO" "INFO" "Current syslog_watchdog owns storage-error notifications; duplicate daily parsing skipped"
        return 0
    fi
    # Primary watcher unavailable: activate the existing bounded cursor-based fallback,
    # including real XFS corruption attribution. Do not silence errors because ownership is configured.
    map_xfs_syslog_sources || return 1
    local SYSLOG_FAST_STORAGE_OWNER=0
    if [[ -r "$IO_ERROR_HISTORY_FILE" ]]; then
        while read -r timestamp key hash; do
            [[ "$timestamp" =~ ^[1-9][0-9]*$ && -n "$key" && -n "$hash" ]] || continue
            printf '%s %s %s 0\n' "$key" "$timestamp" "$hash" >> "$events" || return 1
        done < "$IO_ERROR_HISTORY_FILE"
    fi
    while IFS= read -r line; do
        [[ "$line" =~ $kernel ]] || continue
        if record_xfs_syslog_event "$line"; then continue; fi
        (( IO_ERROR_MONITOR_ENABLED == 1 )) || continue
        syslog_line_is_disk_io_error "$line" || continue
        devices=$(extract_syslog_device_paths "$line")
        [[ -n "$devices" ]] || continue
        timestamp=$(syslog_timestamp_epoch "$line" "$now")
        hash=$(printf '%s' "$line" | sha1sum | awk '{print $1}') || return 1
        if (( IO_ERROR_DEDUP_ENABLED == 0 )); then hash+="-$RANDOM-$RANDOM"; fi
        while IFS= read -r device; do
            [[ -n "$device" ]] || continue
            if [[ "$device" == slot:* ]]; then key="$device"
            else key=$(persistent_device_key "$device") || return 1
            fi
            printf '%s %s %s 1\n' "$key" "$timestamp" "$hash" >> "$events" || return 1
        done <<< "$devices"
    done < "$SYSLOG_CHUNK_FILE"

    rows=$(peak_syslog_bursts "$window" "$events") || return 1
    while read -r key peak; do
        [[ -n "$key" ]] || continue
        local severity=""
        if (( peak >= IO_ERROR_CRIT_THRESHOLD )); then severity=critical
        elif (( peak >= IO_ERROR_WARN_THRESHOLD )); then severity=warning
        fi
        if [[ -n "$severity" ]]; then
            if [[ "$key" == slot:* ]]; then
                record_finding "$severity" io io.kernel "" "Sustained disk I/O errors" \
                    "Unraid ${key#slot:}: $peak distinct errors in a ${IO_ERROR_WINDOW_MINUTES}-minute window." \
                    "Check Unraid diagnostics and identify the physical disk in this slot." disk_io_burst "$key"
            else
                device=$(runtime_device_path "$key") || continue
                record_alert "$severity" "$NOTIFY_TITLE_DISKIO" \
                    "Disk $device I/O errors unique peak $peak in a ${IO_ERROR_WINDOW_MINUTES}-minute window ending at a newly read event."
            fi
        fi
    done <<< "$rows"
    history=$(awk -v cutoff="$cutoff" '$2 >= cutoff && !seen[$1 FS $2 FS $3]++ {print $2, $1, $3}' "$events") || return 1
    if [[ -n "$history" ]]; then history+=$'\n'; fi
    collector_atomic_write_text "$IO_ERROR_HISTORY_FILE" "$history"
}

# === Notification Builder ===
severity_rank() { case "$1" in CRITICAL) echo 2;; WARNING) echo 1;; *) echo 0;; esac; }
status_word()   { case "$1" in 2) echo "CRITICAL";; 1) echo "WARNING";; *) echo "OK";; esac; }

# === Helper Function ===
# Condense and sanitize SMART message lists for inline display.

# === Helper Function ===
# Trim only leading and trailing blank-only lines, preserving internal blank lines
trim_outer_blank_lines() {
    awk 'BEGIN{seen=0;pending=""} {
        if ($0 ~ /^[[:space:]]*$/) { if (seen) pending = pending $0 ORS; next }
        if (pending) { printf "%s", pending; pending="" }
        print; seen=1
    } END{}'
}

# === Main Function ===
# Sample each mount once for capacity alerts, recovery evidence, and totals.
# shellcheck disable=SC2329
collect_storage_usage() {
    local root="${1:-/mnt}" mount name kind ex size used pct use_pct dev fstype devices member profile_data profile_meta
    local array_used=0 array_total=0 pools_used=0 pools_total=0
    local -a members
    ARRAY_PERCENT=""
    POOLS_PERCENT=""
    POOL_MEMBER_MAP=()

    for mount in "$root"/*; do
        [[ -d "$mount" ]] || continue
        name="${mount##*/}"
        case "$name" in user|user0) continue ;; esac
        for ex in "${POOL_EXCLUDES[@]}"; do
            [[ "$ex" != "$name" && "$ex" != "$mount" ]] || continue 2
        done
        mountpoint -q "$mount" || continue
        kind=pool
        if [[ "$name" =~ ^disk[0-9]+$ ]]; then kind=array; fi
        # The dedicated RAM-log monitor owns RAM-backed usage alerts.
        if [[ "$kind" == pool ]]; then
            fstype=$(findmnt_bounded -n -o FSTYPE "$mount" 2>/dev/null || true)
            case "$fstype" in tmpfs|ramfs) continue ;; esac
        fi
        if ! read -r size used pct < <(df_bounded -B1 --output=size,used,pcent "$mount" 2>/dev/null | tail -n1) ||
           [[ ! "$size" =~ ^[1-9][0-9]*$ || ! "$used" =~ ^[0-9]+$ || ! "$pct" =~ ^[0-9]+%$ ]]; then
            record_collector_event FAILED "Capacity $mount" "df returned no usable sample"
            continue
        fi
        FRESH_STORAGE[$mount]=1
        use_pct="${pct%%%}"
        if (( 10#$use_pct >= CRITICAL_THRESHOLD_PERCENT )); then
            record_alert critical "Storage Critical" "$mount usage $pct >= ${CRITICAL_THRESHOLD_PERCENT}%"
        elif (( 10#$use_pct >= WARN_THRESHOLD_PERCENT )); then
            record_alert warning "Storage Warning" "$mount usage $pct >= ${WARN_THRESHOLD_PERCENT}%"
        fi
        if [[ "$kind" == array ]]; then
            array_used=$((array_used + used))
            array_total=$((array_total + size))
            continue
        fi

        pools_used=$((pools_used + used))
        pools_total=$((pools_total + size))
        if [[ "$fstype" == btrfs ]]; then
            btrfs_df_cached "$mount"
            profile_data="${BTRFS_DF_CACHE_DATA[$mount]:-UNKNOWN}"
            profile_meta="${BTRFS_DF_CACHE_META[$mount]:-UNKNOWN}"
            profile_data="${profile_data%%:*}"; profile_data="${profile_data^^}"
            profile_meta="${profile_meta%%:*}"; profile_meta="${profile_meta^^}"
            if ! devices=$(btrfs_bounded filesystem show "$mount" 2>/dev/null); then
                record_collector_event FAILED "Pool members $mount" "unable to read Btrfs membership"
                continue
            fi
            mapfile -t members < <(awk '/devid/ {for (i=1;i<NF;i++) if ($i=="path" && $(i+1) ~ /^\/dev\//) print $(i+1)}' <<< "$devices")
            if [[ "$profile_data" == RAID1 && "${#members[@]}" -lt 2 ]]; then
                record_alert warning "Btrfs Unbalanced" "Pool $name has a RAID1 data profile but only ${#members[@]} visible devices; verify pool membership."
            elif [[ "$profile_data" == SINGLE && "${#members[@]}" -ge 2 ]]; then
                record_alert warning "Btrfs Unbalanced" "Pool $name has multiple members but uses a SINGLE data profile; verify expected redundancy."
            elif [[ "$profile_data" == RAID[0-9]* && "$profile_meta" == SINGLE ]] ||
                 [[ "$profile_meta" == RAID[0-9]* && "$profile_data" == SINGLE ]]; then
                record_alert warning "Btrfs Profile" "Pool $name data profile is $profile_data and metadata profile is $profile_meta; verify expected redundancy."
            fi
        else
            devices=$(findmnt_bounded -n -o SOURCE "$mount" 2>/dev/null || true)
            members=("$devices")
        fi
        for member in "${members[@]}"; do
            [[ "$member" == /dev/* ]] || continue
            dev=$(base_device "$member")
            [[ -n "$dev" ]] && POOL_MEMBER_MAP[$dev]="$name"
        done
    done

    ARRAY_USED_BYTES="$array_used"; ARRAY_TOTAL_BYTES="$array_total"
    POOLS_USED_BYTES="$pools_used"; POOLS_TOTAL_BYTES="$pools_total"
    STORAGE_TOP_LINES=""
    if (( array_total > 0 )); then
        ARRAY_PERCENT=$(awk -v used="$array_used" -v total="$array_total" 'BEGIN {printf "%.3f", 100*used/total}')
        printf -v STORAGE_TOP_LINES 'Array: %.1f%% used (%s of %s)' \
            "$ARRAY_PERCENT" "$(human_readable "$array_used")" "$(human_readable "$array_total")"
    fi
    if (( pools_total > 0 )); then
        POOLS_PERCENT=$(awk -v used="$pools_used" -v total="$pools_total" 'BEGIN {printf "%.3f", 100*used/total}')
        printf -v STORAGE_TOP_LINES '%sPools: %.1f%% used (%s of %s)' \
            "${STORAGE_TOP_LINES:+$STORAGE_TOP_LINES$'\n'}" "$POOLS_PERCENT" \
            "$(human_readable "$pools_used")" "$(human_readable "$pools_total")"
    fi
    return 0
}

# Set FINDING_TARGET_LABEL_RESULT for one canonical finding without encoding
# display labels back into the finding itself.
set_finding_target_label() {
    local id="$1"
    local scope="${FINDING_SCOPE[$id]:-${id%%|*}}"
    local device="${FINDING_DEVICE[$id]:-}"
    local category="${FINDING_CATEGORY[$id]:-general}"
    local base_device_path="" array_slot="" pool_name="" mount_path=""
    local mapped_mount mapped_device mapped_base model_suffix=""

    FINDING_TARGET_LABEL_RESULT="System"
    if [[ -n "$device" ]]; then
        base_device_path="$(base_device "$device")"
        for mapped_mount in "${!MOUNT_TO_DEV[@]}"; do
            [[ "$mapped_mount" == /mnt/disk* ]] || continue
            mapped_device="${MOUNT_TO_DEV[$mapped_mount]:-}"
            mapped_base="$(base_device "$mapped_device")"
            if [[ "$mapped_base" == "$base_device_path" ]]; then
                array_slot="$(basename "$mapped_mount")"
                break
            fi
        done
        pool_name="${POOL_MEMBER_MAP[$base_device_path]:-}"
        if [[ -n "$array_slot" ]]; then
            FINDING_TARGET_LABEL_RESULT="$array_slot [$(basename "$base_device_path")]"
        elif [[ -n "$pool_name" ]]; then
            FINDING_TARGET_LABEL_RESULT="$pool_name [$(basename "$base_device_path")]"
        else
            FINDING_TARGET_LABEL_RESULT="$(basename "$base_device_path")"
        fi
        model_suffix="$(model_suffix_for "$base_device_path")"
        FINDING_TARGET_LABEL_RESULT+="$model_suffix"
        return 0
    fi

    case "$scope" in
        mount:*)
            mount_path="${scope#mount:}"
            FINDING_TARGET_LABEL_RESULT="$mount_path"
            ;;
        slot:*) FINDING_TARGET_LABEL_RESULT="${scope#slot:}" ;;
        pool:*)
            FINDING_TARGET_LABEL_RESULT="Pool ${scope#pool:}"
            ;;
        *)
            case "$category" in
                smart)       FINDING_TARGET_LABEL_RESULT="SMART" ;;
                io)          FINDING_TARGET_LABEL_RESULT="Disk I/O" ;;
                filesystem)  FINDING_TARGET_LABEL_RESULT="Filesystems" ;;
                temperature) FINDING_TARGET_LABEL_RESULT="Temperature" ;;
                endurance)   FINDING_TARGET_LABEL_RESULT="Endurance" ;;
                lifecycle)   FINDING_TARGET_LABEL_RESULT="Lifecycle" ;;
                capacity)    FINDING_TARGET_LABEL_RESULT="Capacity" ;;
                parity)      FINDING_TARGET_LABEL_RESULT="Parity" ;;
                maintenance) FINDING_TARGET_LABEL_RESULT="SMART scheduling" ;;
                monitoring)  FINDING_TARGET_LABEL_RESULT="Monitoring" ;;
            esac
            ;;
    esac
}

# Build the actionable section exclusively from canonical finding metadata.
# Findings are grouped by stable scope and each recommendation is emitted once
# per group, eliminating legacy text matching and duplicate priority formulas.
build_health_alerts() {
    local id scope category group_key severity target count evidence action action_key finding_severity marker
    local group_ids rec="Health Alerts:"
    NOTIFICATION_DESCRIPTION=""
    declare -a group_keys=()
    declare -A group_seen=() group_findings=() group_count=() group_severity=()
    declare -A action_seen=()

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        scope="${FINDING_SCOPE[$id]:-${id%%|*}}"
        category="${FINDING_CATEGORY[$id]:-general}"
        if [[ "$scope" == "global" ]]; then
            group_key="global:$category"
        else
            group_key="$scope"
        fi
        if [[ -z "${group_seen[$group_key]:-}" ]]; then
            group_seen[$group_key]=1
            group_keys+=("$group_key")
            group_count[$group_key]=0
            group_severity[$group_key]="warning"
        fi
        group_findings[$group_key]+="$id"$'\n'
        group_count[$group_key]=$(( ${group_count[$group_key]:-0} + 1 ))
        if [[ "${FINDING_SEVERITY[$id]:-warning}" == "critical" ]]; then
            group_severity[$group_key]="critical"
        fi
    done < <(emit_sorted_finding_ids)

    if (( ${#group_keys[@]} == 0 )); then
        HEALTH_ALERTS_SECTION=""
        return 0
    fi

    for group_key in "${group_keys[@]}"; do
        group_ids="${group_findings[$group_key]:-}"
        id="${group_ids%%$'\n'*}"
        [[ -n "$id" ]] || continue
        set_finding_target_label "$id"
        target="$FINDING_TARGET_LABEL_RESULT"
        severity="${group_severity[$group_key]:-warning}"
        count="${group_count[$group_key]:-1}"
        if [[ -z "$NOTIFICATION_DESCRIPTION" ]]; then
            NOTIFICATION_DESCRIPTION="$target - ${FINDING_TITLE[$id]:-Finding}"
        fi
        rec+=$'\n'
        rec+=" - [${severity^^}] $target - $count finding"
        (( count == 1 )) || rec+="s"

        while IFS= read -r id; do
            [[ -n "$id" ]] || continue
            evidence="${FINDING_EVIDENCE[$id]:-No evidence supplied}"
            evidence="${evidence//$'\n'/ }"
            evidence="${evidence//\\n/ }"
            finding_severity="${FINDING_SEVERITY[$id]:-warning}"
            marker=""
            if [[ "$finding_severity" != "$severity" ]]; then marker="[${finding_severity^^}] "; fi
            rec+=$'\n'
            rec+="   - $marker${FINDING_TITLE[$id]:-Finding}: $evidence"
        done <<< "$group_ids"

        while IFS= read -r id; do
            [[ -n "$id" ]] || continue
            action="${FINDING_ACTION[$id]:-Review the related subsystem logs.}"
            action="${action//$'\n'/ }"
            action_key="$group_key|$action"
            if [[ -n "${action_seen[$action_key]:-}" ]]; then
                continue
            fi
            action_seen[$action_key]=1
            rec+=$'\n'
            rec+="     Action: $action"
        done <<< "$group_ids"
    done

    HEALTH_ALERTS_SECTION="$(printf '%s\n' "$rec" | trim_outer_blank_lines)"
}

# The notification journal contains only stable finding semantics and the last
# successful delivery time. Volatile evidence (temperatures, counters, usage)
# is excluded from fingerprints so routine value movement cannot bypass the
# configured reminder cooldown.
finding_notification_fingerprint() {
    local id="$1" payload

    printf -v payload '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$id" \
        "${FINDING_SEVERITY[$id]:-warning}" \
        "${FINDING_CATEGORY[$id]:-general}" \
        "${FINDING_SIGNAL[$id]:-advisory}" \
        "${FINDING_SCOPE[$id]:-${id%%|*}}" \
        "${FINDING_TITLE[$id]:-Finding}" \
        "${FINDING_ACTION[$id]:-Review the related subsystem logs.}"
    printf '%s' "$payload" | sha1sum | awk '{print $1}'
}

load_notification_journal() {
    local line id severity fingerprint label
    local meta_count=0 finding_count=0 malformed=0
    local -a fields=()

    NOTIFY_PREV_IDS=()
    NOTIFY_PREV_SEVERITY=()
    NOTIFY_PREV_FINGERPRINT=()
    NOTIFY_PREV_LABEL=()
    NOTIFY_PREV_DEVICE_ID=()
    NOTIFICATION_JOURNAL_LOADED=0
    NOTIFICATION_LAST_SUCCESS_EPOCH=0
    NOTIFICATION_LAST_SUCCESS_SEVERITY="normal"

    [[ -s "$NOTIFICATION_JOURNAL_FILE" ]] || return 0
    [[ -r "$NOTIFICATION_JOURNAL_FILE" && -f "$NOTIFICATION_JOURNAL_FILE" &&
       ! -L "$NOTIFICATION_JOURNAL_FILE" ]] || {
        log "NOTIFY" "WARN" \
            "Notification journal is unreadable or unsafe; treating it as uninitialized"
        return 0
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -n "$line" ]] || continue
        fields=()
        IFS=$'\t' read -r -a fields <<< "$line"
        case "${fields[0]:-}" in
            meta)
                if (( ${#fields[@]} != 4 || meta_count != 0 )) ||
                   [[ "${fields[1]:-}" != "1" ||
                      ! "${fields[2]:-}" =~ ^[0-9]+$ ]] ||
                   [[ ! "${fields[3]:-}" =~ ^(normal|warning|critical)$ ]]
                then
                    malformed=1
                    break
                fi
                meta_count=1
                NOTIFICATION_LAST_SUCCESS_EPOCH="${fields[2]}"
                NOTIFICATION_LAST_SUCCESS_SEVERITY="${fields[3]}"
                ;;
            finding)
                if (( ${#fields[@]} != 5 && ${#fields[@]} != 6 )) ||
                   [[ -z "${fields[1]:-}" ||
                      ! "${fields[2]:-}" =~ ^(warning|critical)$ ||
                      ! "${fields[3]:-}" =~ ^[0-9a-f]{40}$ ||
                      -z "${fields[4]:-}" ]]
                then
                    malformed=1
                    break
                fi
                id="${fields[1]}"
                severity="${fields[2]}"
                fingerprint="${fields[3]}"
                label="${fields[4]}"
                # A retired alert is a policy change, not an observed recovery.
                case "${id#*|}" in
                    poh_age_*|load_cycle_count|smart_scheduling|temperature_rate|storage_validation|nvme_wear_projection|tbw_endurance|endurance_forecast|ssd_life_remaining*|heavy_writer|write_workload|sustained_array_write_workload) continue ;;
                esac
                if [[ -n "${NOTIFY_PREV_FINGERPRINT[$id]+present}" ]]; then
                    malformed=1
                    break
                fi
                NOTIFY_PREV_IDS+=("$id")
                NOTIFY_PREV_SEVERITY[$id]="$severity"
                NOTIFY_PREV_FINGERPRINT[$id]="$fingerprint"
                NOTIFY_PREV_LABEL[$id]="$label"
                NOTIFY_PREV_DEVICE_ID[$id]="${fields[5]:-}"
                finding_count=$((finding_count + 1))
                ;;
            *)
                malformed=1
                break
                ;;
        esac
    done < "$NOTIFICATION_JOURNAL_FILE"

    if (( malformed == 1 || meta_count != 1 )); then
        NOTIFY_PREV_IDS=()
        NOTIFY_PREV_SEVERITY=()
        NOTIFY_PREV_FINGERPRINT=()
        NOTIFY_PREV_LABEL=()
        NOTIFICATION_LAST_SUCCESS_EPOCH=0
        NOTIFICATION_LAST_SUCCESS_SEVERITY="normal"
        log "NOTIFY" "WARN" \
            "Notification journal is malformed; treating it as uninitialized"
        return 0
    fi

    NOTIFICATION_JOURNAL_LOADED=1
    log "NOTIFY" "INFO" \
        "Loaded notification journal ($finding_count finding(s), last success epoch=$NOTIFICATION_LAST_SUCCESS_EPOCH)"
}

load_notification_recovery_state() {
    local line id fingerprint count captured_epoch
    local malformed=0
    local -a fields=()

    NOTIFY_RECOVERY_PREV_COUNT=()
    NOTIFY_RECOVERY_PREV_FINGERPRINT=()
    [[ -s "$NOTIFICATION_RECOVERY_STATE_FILE" ]] || return 0
    [[ -r "$NOTIFICATION_RECOVERY_STATE_FILE" &&
       -f "$NOTIFICATION_RECOVERY_STATE_FILE" &&
       ! -L "$NOTIFICATION_RECOVERY_STATE_FILE" ]] || {
        log "NOTIFY" "WARN" \
            "Notification recovery state is unreadable or unsafe; restarting confirmation"
        return 0
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -n "$line" ]] || continue
        fields=()
        IFS=$'\t' read -r -a fields <<< "$line"
        if (( ${#fields[@]} != 6 )) ||
           [[ "${fields[0]:-}" != "candidate" ||
              "${fields[1]:-}" != "1" ||
              -z "${fields[2]:-}" ||
              ! "${fields[3]:-}" =~ ^[0-9a-f]{40}$ ||
              ! "${fields[4]:-}" =~ ^[1-9][0-9]*$ ||
              ! "${fields[5]:-}" =~ ^[0-9]+$ ]]
        then
            malformed=1
            break
        fi
        id="${fields[2]}"
        fingerprint="${fields[3]}"
        count="${fields[4]}"
        captured_epoch="${fields[5]}"
        if [[ "$id" == *$'\t'* || -n "${NOTIFY_RECOVERY_PREV_COUNT[$id]+present}" ]]; then
            malformed=1
            break
        fi
        NOTIFY_RECOVERY_PREV_COUNT[$id]="$count"
        NOTIFY_RECOVERY_PREV_FINGERPRINT[$id]="$fingerprint"
    done < "$NOTIFICATION_RECOVERY_STATE_FILE"

    if (( malformed == 1 )); then
        NOTIFY_RECOVERY_PREV_COUNT=()
        NOTIFY_RECOVERY_PREV_FINGERPRINT=()
        log "NOTIFY" "WARN" \
            "Notification recovery state is malformed; restarting confirmation"
    fi
}

persist_notification_recovery_state() {
    local temp_file id persisted_epoch="${RUN_EPOCH:-0}"

    temp_file="$(state_temp_file "$NOTIFICATION_RECOVERY_STATE_FILE")" || return 1
    : > "$temp_file" || {
        rm -f -- "$temp_file" 2>/dev/null || true
        return 1
    }
    (( persisted_epoch > 0 )) || persisted_epoch="$(date +%s)"
    for id in "${NOTIFY_RECOVERY_NEXT_IDS[@]}"; do
        [[ -n "$id" ]] || continue
        printf 'candidate\t1\t%s\t%s\t%s\t%s\n' \
            "$id" "${NOTIFY_RECOVERY_NEXT_FINGERPRINT[$id]}" \
            "${NOTIFY_RECOVERY_NEXT_COUNT[$id]}" "$persisted_epoch" \
            >> "$temp_file" || {
                rm -f -- "$temp_file" 2>/dev/null || true
                return 1
            }
    done
    atomic_commit "$temp_file" "$NOTIFICATION_RECOVERY_STATE_FILE"
}

build_current_notification_state() {
    local id fingerprint label

    NOTIFY_CURRENT_SEVERITY=()
    NOTIFY_CURRENT_FINGERPRINT=()
    NOTIFY_CURRENT_LABEL=()
    NOTIFY_CURRENT_DEVICE_ID=()

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        if [[ "$id" == *$'\t'* || "$id" == *$'\r'* || "$id" == *$'\n'* ]]; then
            log "NOTIFY" "WARN" \
                "Refusing a finding ID containing notification-journal delimiters"
            return 1
        fi
        fingerprint="$(finding_notification_fingerprint "$id")" || return 1
        [[ "$fingerprint" =~ ^[0-9a-f]{40}$ ]] || return 1
        set_finding_target_label "$id"
        label="$FINDING_TARGET_LABEL_RESULT - ${FINDING_TITLE[$id]:-Finding}"
        label="${label//$'\t'/ }"
        label="${label//$'\r'/ }"
        label="${label//$'\n'/ }"
        NOTIFY_CURRENT_SEVERITY[$id]="${FINDING_SEVERITY[$id]:-warning}"
        NOTIFY_CURRENT_FINGERPRINT[$id]="$fingerprint"
        NOTIFY_CURRENT_LABEL[$id]="$label"
        local device="${FINDING_DEVICE[$id]:-}"
        if [[ -n "$device" ]]; then
            NOTIFY_CURRENT_DEVICE_ID[$id]="${DEVICE_ID_BY_PATH[$device]:-}"
        fi
    done < <(emit_sorted_finding_ids)

    if (( FINDING_CRITICAL_COUNT > 0 )); then
        NOTIFICATION_CURRENT_SEVERITY="critical"
    elif (( FINDING_WARNING_COUNT > 0 )); then
        NOTIFICATION_CURRENT_SEVERITY="warning"
    else
        NOTIFICATION_CURRENT_SEVERITY="normal"
    fi
}

notification_reminder_due() {
    local interval_hours="$1" now="$2" elapsed

    (( interval_hours > 0 )) || return 1
    elapsed=$((now - NOTIFICATION_LAST_SUCCESS_EPOCH))
    (( elapsed < 0 )) && elapsed=0
    (( elapsed >= interval_hours * 3600 ))
}

finding_has_fresh_recovery_evidence() {
    local id="$1" scope="${1%%|*}" code="${1#*|}" device identity key
    case "$scope" in
        device:*)
            device="${scope#device:}"
            identity="${NOTIFY_PREV_DEVICE_ID[$id]:-}"
            if [[ -n "$identity" ]]; then
                device="${DEVICE_PATH_BY_ID[$identity]:-}"
                [[ -n "$device" ]] || return 1
                [[ -z "${NOTIFY_CURRENT_FINGERPRINT["device:$device|$code"]:-}" ]] || return 1
            fi
            case "$code" in
                btrfs_device_*|btrfs_burst_*)
                    key="${code#btrfs_device_}"; key="${key#btrfs_burst_}"
                    [[ -n "${FRESH_FILESYSTEM["btrfs:$device:$key"]:-}" ]] ;;
                disk_i_o_*|disk_io_*)
                    [[ -n "${DEVICE_ID_BY_PATH[$device]:-}" &&
                       "$SYSLOG_CURSOR_MODE" =~ ^(cursor_continuation|rotation_recovery)$ ]] &&
                        collector_status_is_safe syslog_io ;;
                endurance_forecast) return 1 ;; # Retired policy; not physical recovery evidence.
                *)
                    [[ -n "${FRESH_SMART[$device]:-}" ]] ;;
            esac
            ;;
        mount:*)
            case "$code" in
                btrfs_scrub_alert) [[ -n "${FRESH_FILESYSTEM["scrub:${scope#mount:}"]:-}" ]] ;;
                # Silence cannot prove that a shutdown/corruption was repaired.
                xfs_kernel_error) [[ "${NOTIFY_PREV_SEVERITY[$id]:-}" != critical ]] &&
                    [[ -n "${FRESH_FILESYSTEM["xfs:${scope#mount:}"]:-}" ]] &&
                    collector_status_is_safe syslog_io ;;
                xfs_alert) [[ -n "${FRESH_FILESYSTEM["xfs:${scope#mount:}"]:-}" ]] &&
                    collector_status_is_safe syslog_io ;;
                *) [[ -n "${FRESH_STORAGE["${scope#mount:}"]:-}" ]] ;;
            esac
            ;;
        slot:*)
            if [[ "$code" == disk_io_burst ]]; then
                [[ "$SYSLOG_CURSOR_MODE" =~ ^(cursor_continuation|rotation_recovery)$ ]] &&
                    collector_status_is_safe syslog_io
            else [[ -n "${FRESH_STORAGE[$scope]:-}" ]]
            fi ;;
        *)
            case "$code" in
                completed_parity_check) (( PARITY_HISTORY_OBSERVED == 1 )) ;;
                syslog_coverage_gap) [[ "$SYSLOG_CURSOR_MODE" =~ ^(cursor_continuation|rotation_recovery)$ ]] &&
                    collector_status_is_safe syslog_io ;;
                syslog_fast_watcher_stale) collector_status_is_safe syslog_io ;;
                parity_status|parity_sync_errors) (( PARITY_RESULT_OBSERVED == 1 )) ;;
                array_capacity|pools_capacity|storage_validation) (( ARRAY_TOPOLOGY_OBSERVED == 1 )) ;;
                *) return 0 ;;
            esac
            ;;
    esac
}

prepare_notification_lifecycle() {
    local id now interval_hours safe_state=0 recovery_state_ok=1
    local recovery_count previous_count previous_fingerprint
    local recovery_rows=""
    local -a absent_ids=()

    NOTIFICATION_PHASE_REACHED=1
    NOTIFICATION_DECISION="SUPPRESS"
    NOTIFICATION_REASON="unchanged state within reminder cooldown"
    NOTIFICATION_NEW_COUNT=0
    NOTIFICATION_CHANGED_COUNT=0
    NOTIFICATION_RESOLVED_COUNT=0
    NOTIFICATION_RECOVERY_DEFERRED_COUNT=0
    NOTIFICATION_RECOVERY_PENDING_COUNT=0
    NOTIFICATION_RECOVERY_SECTION=""
    NOTIFICATION_JOURNAL_COMMIT_ALLOWED=0
    NOTIFY_RECOVERY_NEXT_IDS=()
    NOTIFY_RECOVERY_NEXT_COUNT=()
    NOTIFY_RECOVERY_NEXT_FINGERPRINT=()
    NOTIFY_CARRY_IDS=()

    build_current_notification_state || {
        NOTIFICATION_DECISION="SEND"
        NOTIFICATION_REASON="unable to fingerprint current findings"
        log "NOTIFY" "WARN" "$NOTIFICATION_REASON; journal update disabled"
        return 1
    }
    load_notification_journal
    load_notification_recovery_state
    NOTIFICATION_JOURNAL_COMMIT_ALLOWED=1
    if all_collectors_state_safe; then
        safe_state=1
    fi

    for id in "${!NOTIFY_CURRENT_FINGERPRINT[@]}"; do
        if [[ -z "${NOTIFY_PREV_FINGERPRINT[$id]+present}" ]]; then
            NOTIFICATION_NEW_COUNT=$((NOTIFICATION_NEW_COUNT + 1))
        elif [[ "${NOTIFY_CURRENT_FINGERPRINT[$id]}" != \
                "${NOTIFY_PREV_FINGERPRINT[$id]}" ]]
        then
            NOTIFICATION_CHANGED_COUNT=$((NOTIFICATION_CHANGED_COUNT + 1))
        fi
    done

    for id in "${NOTIFY_PREV_IDS[@]}"; do
        [[ -z "${NOTIFY_CURRENT_FINGERPRINT[$id]+present}" ]] || continue
        absent_ids+=("$id")
        (( safe_state == 1 )) || continue
        finding_has_fresh_recovery_evidence "$id" || continue
        previous_count="${NOTIFY_RECOVERY_PREV_COUNT[$id]:-0}"
        previous_fingerprint="${NOTIFY_RECOVERY_PREV_FINGERPRINT[$id]:-}"
        [[ "$previous_count" =~ ^[0-9]+$ ]] || previous_count=0
        if [[ "$previous_fingerprint" == "${NOTIFY_PREV_FINGERPRINT[$id]}" ]]; then
            recovery_count=$((previous_count + 1))
        else
            recovery_count=1
        fi
        NOTIFY_RECOVERY_NEXT_IDS+=("$id")
        NOTIFY_RECOVERY_NEXT_COUNT[$id]="$recovery_count"
        NOTIFY_RECOVERY_NEXT_FINGERPRINT[$id]="${NOTIFY_PREV_FINGERPRINT[$id]}"
    done

    # Recovery confirmation is independent of the last-success journal and is
    # updated on every collector-safe run. An incomplete run clears the streak
    # so only consecutive safe observations can resolve a finding.
    if (( NOTIFICATION_DRY_RUN == 0 )) && ! persist_notification_recovery_state; then
        recovery_state_ok=0
        log "NOTIFY" "WARN" \
            "Unable to persist notification recovery confirmation; recovery remains pending"
    fi

    for id in "${absent_ids[@]}"; do
        if (( safe_state == 0 )) || ! finding_has_fresh_recovery_evidence "$id"; then
            NOTIFICATION_RECOVERY_DEFERRED_COUNT=$((NOTIFICATION_RECOVERY_DEFERRED_COUNT + 1))
            NOTIFY_CARRY_IDS+=("$id")
        elif (( recovery_state_ok == 0 )); then
            NOTIFICATION_RECOVERY_PENDING_COUNT=$((NOTIFICATION_RECOVERY_PENDING_COUNT + 1))
            NOTIFY_CARRY_IDS+=("$id")
        else
            recovery_count="${NOTIFY_RECOVERY_NEXT_COUNT[$id]:-0}"
            if (( recovery_count >= NOTIFICATION_RECOVERY_CONFIRM_RUNS )); then
                NOTIFICATION_RESOLVED_COUNT=$((NOTIFICATION_RESOLVED_COUNT + 1))
                recovery_rows+=" - [${NOTIFY_PREV_SEVERITY[$id]^^}] ${NOTIFY_PREV_LABEL[$id]}"$'\n'
            else
                NOTIFICATION_RECOVERY_PENDING_COUNT=$((NOTIFICATION_RECOVERY_PENDING_COUNT + 1))
                NOTIFY_CARRY_IDS+=("$id")
            fi
        fi
    done
    if (( NOTIFICATION_RESOLVED_COUNT > 0 )); then
        NOTIFICATION_RECOVERY_SECTION="Resolved Since Last Successful Notification:
${recovery_rows%$'\n'}"
    fi

    now="${RUN_EPOCH:-0}"
    (( now > 0 )) || now="$(date +%s)"

    if (( NOTIFICATION_LIFECYCLE_ENABLED == 0 )); then
        NOTIFICATION_DECISION="SEND"
        NOTIFICATION_REASON="notification lifecycle suppression disabled"
    elif (( NOTIFICATION_JOURNAL_LOADED == 0 )); then
        NOTIFICATION_DECISION="SEND"
        NOTIFICATION_REASON="initial notification baseline"
    elif (( NOTIFICATION_NEW_COUNT > 0 || NOTIFICATION_CHANGED_COUNT > 0 )); then
        NOTIFICATION_DECISION="SEND"
        NOTIFICATION_REASON="finding set changed (new=$NOTIFICATION_NEW_COUNT changed=$NOTIFICATION_CHANGED_COUNT resolved=$NOTIFICATION_RESOLVED_COUNT)"
    elif (( NOTIFICATION_RESOLVED_COUNT > 0 )); then
        NOTIFICATION_DECISION="SEND"
        NOTIFICATION_REASON="$NOTIFICATION_RESOLVED_COUNT finding(s) resolved"
    elif (( NOTIFICATION_RECOVERY_DEFERRED_COUNT > 0 &&
            ${#NOTIFY_CURRENT_FINGERPRINT[@]} == 0 )); then
        NOTIFICATION_REASON="recovery deferred because collector state is incomplete"
    elif (( NOTIFICATION_RECOVERY_PENDING_COUNT > 0 &&
            ${#NOTIFY_CURRENT_FINGERPRINT[@]} == 0 )); then
        NOTIFICATION_REASON="recovery awaiting ${NOTIFICATION_RECOVERY_CONFIRM_RUNS} consecutive safe runs"
    else
        case "$NOTIFICATION_CURRENT_SEVERITY" in
            critical) interval_hours="$NOTIFICATION_CRITICAL_REMINDER_HOURS" ;;
            warning)  interval_hours="$NOTIFICATION_WARNING_REMINDER_HOURS" ;;
            *)        interval_hours="$NOTIFICATION_OK_REMINDER_HOURS" ;;
        esac
        if notification_reminder_due "$interval_hours" "$now"; then
            NOTIFICATION_DECISION="SEND"
            NOTIFICATION_REASON="unchanged $NOTIFICATION_CURRENT_SEVERITY reminder is due"
        elif (( interval_hours == 0 )); then
            NOTIFICATION_REASON="unchanged $NOTIFICATION_CURRENT_SEVERITY reminders disabled"
        fi
    fi

    log "NOTIFY" "INFO" \
        "Lifecycle decision=$NOTIFICATION_DECISION reason='$NOTIFICATION_REASON' new=$NOTIFICATION_NEW_COUNT changed=$NOTIFICATION_CHANGED_COUNT resolved=$NOTIFICATION_RESOLVED_COUNT pending_recovery=$NOTIFICATION_RECOVERY_PENDING_COUNT deferred_recovery=$NOTIFICATION_RECOVERY_DEFERRED_COUNT"
    (( recovery_state_ok == 1 ))
}

persist_notification_journal() {
    local temp_file id label persisted_epoch="${RUN_EPOCH:-0}"
    local -A written=()

    temp_file="$(state_temp_file "$NOTIFICATION_JOURNAL_FILE")" || return 1
    (( persisted_epoch > 0 )) || persisted_epoch="$(date +%s)"
    printf 'meta\t1\t%s\t%s\n' \
        "$persisted_epoch" "$NOTIFICATION_CURRENT_SEVERITY" > "$temp_file" || {
        rm -f -- "$temp_file" 2>/dev/null || true
        return 1
    }
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        label="${NOTIFY_CURRENT_LABEL[$id]}"
        printf 'finding\t%s\t%s\t%s\t%s\t%s\n' \
            "$id" "${NOTIFY_CURRENT_SEVERITY[$id]}" \
            "${NOTIFY_CURRENT_FINGERPRINT[$id]}" "$label" "${NOTIFY_CURRENT_DEVICE_ID[$id]:-}" >> "$temp_file" || {
            rm -f -- "$temp_file" 2>/dev/null || true
                return 1
            }
        written[$id]=1
    done < <(emit_sorted_finding_ids)
    # Findings awaiting recovery confirmation remain in the successful-state
    # journal even if another finding causes a notification in the meantime.
    for id in "${NOTIFY_CARRY_IDS[@]}"; do
        [[ -n "$id" && -z "${written[$id]+present}" ]] || continue
        printf 'finding\t%s\t%s\t%s\t%s\t%s\n' \
            "$id" "${NOTIFY_PREV_SEVERITY[$id]}" \
            "${NOTIFY_PREV_FINGERPRINT[$id]}" "${NOTIFY_PREV_LABEL[$id]}" "${NOTIFY_PREV_DEVICE_ID[$id]:-}" \
            >> "$temp_file" || {
                rm -f -- "$temp_file" 2>/dev/null || true
                return 1
            }
        written[$id]=1
    done
    atomic_commit "$temp_file" "$NOTIFICATION_JOURNAL_FILE"
}

process_notification_delivery() {
    local title="$1" body="$2" severity="$3"

    if [[ "$NOTIFICATION_DECISION" == "SUPPRESS" ]]; then
        log "NOTIFY" "INFO" \
            "External notification suppressed: $NOTIFICATION_REASON"
        return 0
    fi
    if (( NOTIFICATION_DRY_RUN == 1 )); then
        log "NOTIFY" "INFO" \
            "Dry run: would send '$title' (severity=$severity); journal unchanged"
        return 0
    fi

    if deliver_notification_with_retry "$title" "$body" "$severity"; then
        if (( NOTIFICATION_JOURNAL_COMMIT_ALLOWED == 1 )); then
            if persist_notification_journal; then
                log "NOTIFY" "INFO" \
                    "Notification journal advanced after successful delivery"
            else
                log "NOTIFY" "WARN" \
                    "Notification delivered but journal update failed; the next run may repeat it"
                return 1
            fi
        else
            log "NOTIFY" "WARN" \
                "Notification delivered but its fingerprint could not be recorded"
            return 1
        fi
    else
        log "NOTIFY" "ERROR" \
            "Notification delivery failed after $NOTIFICATION_DELIVERY_ATTEMPTS attempt(s); journal unchanged"
        return 1
    fi
    return 0
}

# Trend stages intentionally communicate through the structured globals used
# by trend evaluation and final rendering. Each stage otherwise owns its local
# parsing state and can fail independently.
declare -a TREND_DIAGNOSTIC_ITEMS=()
declare -A TREND_HISTORY_CACHE=()
TREND_CACHE_RESULT=""

trend_add_diagnostic() {
    local label="$1" content="$2"

    [[ -n "$content" ]] && TREND_DIAGNOSTIC_ITEMS+=("$label: $content")
    return 0
}

trend_log_diagnostics() {
    local item

    for item in "${TREND_DIAGNOSTIC_ITEMS[@]}"; do
        log "TREND" "INFO" "$item"
    done
    return 0
}

forecast_confidence_description() {
    case "${1:-INSUFFICIENT}" in
        HIGH)         printf 'high forecast confidence' ;;
        MEDIUM)       printf 'medium forecast confidence' ;;
        LOW)          printf 'low forecast confidence' ;;
        STALE)        printf 'stale history' ;;
        RESET)        printf 'counter reset detected; forecast rebuilding' ;;
        *)            printf 'insufficient history' ;;
    esac
}

format_bytes_per_day() {
    local bytes="${1:-0}"

    if [[ "$bytes" =~ ^[0-9]+$ ]]; then
        printf '%s/day' "$(human_readable "$bytes")"
    else
        printf 'unknown/day'
    fi
}

# Copy a bounded history tail once per run. Trend stages share the cached file
# instead of repeatedly reading the same persistent history into shell strings.
prepare_trend_history_cache() {
    local tag="$1" source="$2" maximum_lines="$3"
    local cache_dir cache_file temp_file cached

    TREND_CACHE_RESULT=""
    cached="${TREND_HISTORY_CACHE[$tag]:-}"
    if [[ -n "$cached" && -r "$cached" && -f "$cached" && ! -L "$cached" ]]; then
        TREND_CACHE_RESULT="$cached"
        return 0
    fi
    [[ "$maximum_lines" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ -r "$source" && -f "$source" && ! -L "$source" ]] || return 1

    cache_dir="$RUN_DIR/trend_cache"
    ensure_private_dir "$cache_dir" || return 1
    cache_file="$cache_dir/$(safe_state_name "$tag").log"
    temp_file=$(mktemp "${cache_file}.tmp.XXXXXX") || return 1
    chmod 600 -- "$temp_file" 2>/dev/null || {
        rm -f -- "$temp_file" 2>/dev/null || true
        return 1
    }
    if ! tail -n "$maximum_lines" -- "$source" > "$temp_file" 2>/dev/null; then
        rm -f -- "$temp_file" 2>/dev/null || true
        return 1
    fi
    if ! mv -f -- "$temp_file" "$cache_file"; then
        rm -f -- "$temp_file" 2>/dev/null || true
        return 1
    fi

    TREND_HISTORY_CACHE[$tag]="$cache_file"
    TREND_CACHE_RESULT="$cache_file"
    return 0
}

# Emit only well-formed dated history rows in the requested window. Sorting
# makes first/last analysis deterministic when legacy rows are out of order.
stream_trend_history_window() {
    local source="$1" cutoff="$2"

    awk -v cutoff="$cutoff" '
        $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ &&
        $1 >= cutoff && NF >= 2 { print }
    ' "$source" 2>/dev/null | LC_ALL=C sort -s -k1,1
}

run_trend_stage() {
    local label="$1"
    shift
    local rc

    CURRENT_TREND_BLOCK="$label"
    "$@"
    rc=$?
    if (( rc != 0 )); then
        log "TREND" "WARN" "Trend stage failed: $label (rc=$rc)"
        record_collector_event FAILED "Trend $label" "rc=$rc"
    fi
    return 0
}

record_temperature_approach() {
    local disk="$1" temperature="$2" epoch="$3" rate="$4" span="$5" confidence="$6"
    local limit="$SSD_TEMP_WARNING" margin=5

    (( TEMP_RATE_ALERT_ENABLED == 1 )) || return 0
    [[ -n "${FRESH_SMART[$disk]:-}" && "$epoch" == "$RUN_EPOCH" &&
        "$temperature" =~ ^(0|[1-9][0-9]*)$ ]] || return 0
    if [[ "$disk" == /dev/nvme* ]]; then
        limit="$NVME_TEMP_WARNING"
    elif [[ "$(lsblk_rota_cached "$disk" 2>/dev/null || printf '1')" == 1 ]]; then
        limit="$HDD_TEMP_WARNING"
    fi
    # Let the absolute temperature alert own readings at or above the limit.
    (( temperature < limit && temperature >= limit - margin )) || return 0
    forecast_confidence_is_actionable "$confidence" || return 0
    awk -v rate="$rate" -v threshold="$TEMP_RATE_WARN_C_PER_DAY" \
        -v days="$span" -v minimum="$TEMP_RATE_MIN_SPAN_DAYS" \
        'BEGIN { exit !(rate >= threshold && days >= minimum) }' || return 0
    record_alert warning "Temperature Approaching Limit" \
        "Disk $disk is at ${temperature}°C, rising about ${rate}°C/day (warning at ${limit}°C)."
}

analyze_temperature_trends() {
    local dev

    TEMP_FORECAST_CONFIDENCE_LINE=""
    # Temperature Evolution subsection
    CURRENT_TREND_BLOCK="temperature"
    if prepare_trend_history_cache temperatures "$TEMP_HISTORY_FILE" 50000; then
        local temp_win=${TEMP_TREND_WINDOW_DAYS:-14} stored_key rest dt
        local temp_cache="$TREND_CACHE_RESULT"
        local now_ts
        now_ts=$(date +%s)
        local cut_ts=$(( now_ts - temp_win*86400 ))
        declare -A TT_CNT=() TT_FIRST=() TT_LAST=() TT_FIRST_TS=() TT_LAST_TS=() TT_MAX_GAP_SECONDS=()
        declare -A TEMP_SAMPLE_VALUE=() TEMP_SAMPLE_EPOCH=() TEMP_DEVICE_SEEN=() TEMP_SEQUENCE=()
        TEMP_RATE_CONFIDENCE=()
        while read -r dt stored_key rest; do
            [[ "$dt" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
            local dev tmp ts temp_sample_key
            dev=$(runtime_device_path "$stored_key" 2>/dev/null || true)
            [[ -n "$dev" ]] || continue
            tmp=$(history_field_value "$rest" temp 2>/dev/null || true)
            if [[ -z "$tmp" ]]; then
                tmp="${rest%% *}"
                tmp="${tmp#temp=}"
            fi
            [[ "$tmp" =~ ^[0-9]+$ ]] || continue
            ts=$(history_record_epoch "$dt" "$rest" 2>/dev/null || true)
            [[ "$ts" =~ ^[0-9]+$ ]] || continue
            (( ts >= cut_ts )) || continue
            temp_sample_key="$dev|$dt"
            if [[ -n "${TEMP_SAMPLE_EPOCH[$temp_sample_key]:-}" ]] &&
               (( ts < TEMP_SAMPLE_EPOCH[$temp_sample_key] ))
            then
                continue
            fi
            TEMP_SAMPLE_VALUE[$temp_sample_key]="$tmp"
            TEMP_SAMPLE_EPOCH[$temp_sample_key]="$ts"
            TEMP_DEVICE_SEEN[$dev]=1
        done < "$temp_cache"

        local temp_sample
        for temp_sample in "${!TEMP_SAMPLE_VALUE[@]}"; do
            local temp_dev="${temp_sample%|*}"
            TEMP_SEQUENCE[$temp_dev]="${TEMP_SEQUENCE[$temp_dev]:-}${TEMP_SAMPLE_EPOCH[$temp_sample]} ${TEMP_SAMPLE_VALUE[$temp_sample]}"$'\n'
        done

        local temp_dev
        for temp_dev in "${!TEMP_DEVICE_SEEN[@]}"; do
            local previous_ts=0 max_gap_seconds=0 gap_seconds=0 sample_temp sample_ts
            while read -r sample_ts sample_temp; do
                [[ "$sample_ts" =~ ^[0-9]+$ && "$sample_temp" =~ ^[0-9]+$ ]] || continue
                if [[ -z "${TT_FIRST[$temp_dev]:-}" ]]; then
                    TT_FIRST[$temp_dev]="$sample_temp"
                    TT_FIRST_TS[$temp_dev]="$sample_ts"
                elif (( previous_ts > 0 )); then
                    gap_seconds=$(( sample_ts - previous_ts ))
                    (( gap_seconds > max_gap_seconds )) && max_gap_seconds=$gap_seconds
                fi
                TT_CNT[$temp_dev]=$(( ${TT_CNT[$temp_dev]:-0} + 1 ))
                TT_LAST[$temp_dev]="$sample_temp"
                TT_LAST_TS[$temp_dev]="$sample_ts"
                previous_ts=$sample_ts
            done < <(printf '%s' "${TEMP_SEQUENCE[$temp_dev]:-}" | sort -n -k1,1)
            TT_MAX_GAP_SECONDS[$temp_dev]="$max_gap_seconds"
        done
        local tdev
        for tdev in "${!TT_CNT[@]}"; do
            local rise rate days
            if [[ -n "${TT_FIRST[$tdev]:-}" && -n "${TT_LAST[$tdev]:-}" ]]; then
                rise=$(( ${TT_LAST[$tdev]:-0} - ${TT_FIRST[$tdev]:-0} ))
            else
                rise=0
            fi
            rate="0.0"; days=0
            if [[ -n "${TT_FIRST_TS[$tdev]:-}" && -n "${TT_LAST_TS[$tdev]:-}" ]]; then
                local span
                span=$(( ${TT_LAST_TS[$tdev]:-0} - ${TT_FIRST_TS[$tdev]:-0} ))
                if (( span > 0 )); then
                    days=$(awk -v s="$span" 'BEGIN{printf "%.2f", s/86400.0}')
                    rate=$(awk -v r="$rise" -v d="$days" 'BEGIN{ if(d>0) printf "%.2f", r/d; else print "0.0" }')
                fi
            fi
            local temp_latest_age temp_max_gap_days temp_confidence
            temp_latest_age=$(awk -v now="$RUN_EPOCH" -v last="${TT_LAST_TS[$tdev]:-0}" \
                'BEGIN { if(last<=0) print 999999; else { age=(now-last)/86400.0; if(age<0) age=0; printf "%.3f", age } }')
            temp_max_gap_days=$(awk -v gap="${TT_MAX_GAP_SECONDS[$tdev]:-0}" \
                'BEGIN { printf "%.3f", gap/86400.0 }')
            temp_confidence=$(forecast_confidence \
                "${TT_CNT[$tdev]:-0}" "$days" "$temp_latest_age" "$temp_max_gap_days")
            TEMP_RATE_CONFIDENCE[$tdev]="$temp_confidence"
            trend_add_diagnostic "temperature trend" \
                "device=$(basename "$tdev") samples=${TT_CNT[$tdev]:-0} span_days=$days rise_c=$rise rate_c_per_day=$rate latest_age_days=$temp_latest_age maximum_gap_days=$temp_max_gap_days confidence=$temp_confidence"
            record_temperature_approach "$tdev" "${TT_LAST[$tdev]:-0}" \
                "${TT_LAST_TS[$tdev]:-0}" "$rate" "$days" "$temp_confidence"
        done
        local -a temp_stale=() temp_insufficient=() temp_low=() temp_reset=()
        for tdev in "${!TEMP_RATE_CONFIDENCE[@]}"; do
            case "${TEMP_RATE_CONFIDENCE[$tdev]:-INSUFFICIENT}" in
                HIGH|MEDIUM) ;;
                STALE) temp_stale+=("$(basename "$tdev")") ;;
                LOW) temp_low+=("$(basename "$tdev")") ;;
                RESET) temp_reset+=("$(basename "$tdev")") ;;
                *) temp_insufficient+=("$(basename "$tdev")") ;;
            esac
        done
        (( ${#temp_stale[@]} == 0 )) ||
            mapfile -t temp_stale < <(printf '%s\n' "${temp_stale[@]}" | LC_ALL=C sort -u)
        (( ${#temp_insufficient[@]} == 0 )) ||
            mapfile -t temp_insufficient < <(printf '%s\n' "${temp_insufficient[@]}" | LC_ALL=C sort -u)
        (( ${#temp_low[@]} == 0 )) ||
            mapfile -t temp_low < <(printf '%s\n' "${temp_low[@]}" | LC_ALL=C sort -u)
        (( ${#temp_reset[@]} == 0 )) ||
            mapfile -t temp_reset < <(printf '%s\n' "${temp_reset[@]}" | LC_ALL=C sort -u)
        local -a temp_quality_parts=()
        if (( ${#temp_stale[@]} > 0 )); then
            local stale_count=${#temp_stale[@]} stale_noun="disks" stale_pronoun="they are"
            if (( stale_count == 1 )); then
                stale_noun="disk"
                stale_pronoun="it is"
            fi
            temp_quality_parts+=("Temperature history is stale for ${stale_count} ${stale_noun}, likely because ${stale_pronoun} sleeping")
        fi
        if (( ${#temp_insufficient[@]} > 0 )); then
            local insufficient_count=${#temp_insufficient[@]} insufficient_noun="disks" insufficient_verb="need"
            if (( insufficient_count == 1 )); then
                insufficient_noun="disk"
                insufficient_verb="needs"
            fi
            temp_quality_parts+=("${insufficient_count} ${insufficient_noun} ${insufficient_verb} more temperature samples")
        fi
        if (( ${#temp_low[@]} > 0 )); then
            local low_count=${#temp_low[@]} low_noun="disks" low_verb="have"
            if (( low_count == 1 )); then
                low_noun="disk"
                low_verb="has"
            fi
            temp_quality_parts+=("${low_count} ${low_noun} ${low_verb} widely spaced temperature samples")
        fi
        if (( ${#temp_reset[@]} > 0 )); then
            local reset_count=${#temp_reset[@]} reset_noun="disks" reset_verb="have"
            if (( reset_count == 1 )); then
                reset_noun="disk"
                reset_verb="has"
            fi
            temp_quality_parts+=("${reset_count} ${reset_noun} ${reset_verb} reset temperature history")
        fi
        if (( ${#temp_quality_parts[@]} > 0 )); then
            TEMP_FORECAST_CONFIDENCE_LINE="$(join_by '; ' "${temp_quality_parts[@]}")"
        fi
    fi
    return 0
}

analyze_sata_link_trends() {
    (( SATA_LINK_INSTABILITY_ENABLED == 1 )) || return 0
    prepare_trend_history_cache sata-links "$SATA_LINK_HISTORY_FILE" 20000 || return 0
    local cutoff date_key identity fields device mx cur streak previous severity
    local -A dates_by_device=() max_by_device=() current_by_device=()
    local -a dates
    cutoff=$(date -d "-$SATA_LINK_INSTABILITY_WINDOW_DAYS days" '+%Y-%m-%d') || return 1
    while read -r date_key identity fields; do
        device=$(runtime_device_path "$identity") || continue
        dates_by_device[$device]+="$date_key"$'\n'
        mx=$(history_field_value "$fields" max) || continue
        cur=$(history_field_value "$fields" current) || continue
        max_by_device[$device]="$mx"
        current_by_device[$device]="$cur"
    done < <(stream_trend_history_window "$TREND_CACHE_RESULT" "$cutoff")
    for device in "${!dates_by_device[@]}"; do
        mapfile -t dates < <(printf '%s' "${dates_by_device[$device]}" | sort -u)
        streak=1
        local i
        for ((i=${#dates[@]}-1; i>0; i--)); do
            previous=$(date -d "${dates[i-1]} +1 day" '+%Y-%m-%d') || break
            [[ "${dates[i]}" == "$previous" ]] || break
            streak=$((streak + 1))
        done
        severity=""
        if (( streak >= SATA_LINK_INSTABILITY_STREAK_CRIT )); then severity=critical
        elif (( streak >= SATA_LINK_INSTABILITY_STREAK_WARN )); then severity=warning
        fi
        mx="${max_by_device[$device]:-?}"
        cur="${current_by_device[$device]:-?}"
        trend_add_diagnostic "SATA link" "device=$device downshift_days=${#dates[@]} streak_days=$streak maximum_gbps=$mx current_gbps=$cur"
        if [[ -n "$severity" ]]; then
            record_alert "$severity" "SATA Link Instability" "Disk $device link downshift streak $streak days (max $mx, current $cur Gb/s)."
        fi
    done
    return 0
}

log_health_trends() {
    local device
    trend_add_diagnostic "temperature history" "${TEMP_FORECAST_CONFIDENCE_LINE:-}"
    for device in "${!WRITER_DAILY[@]}"; do
        trend_add_diagnostic "write workload" "device=${device##*/} bytes_per_day=${WRITER_DAILY[$device]} direction=${WRITER_DIRECTION[$device]:-COLLECTING} change_percent=${WRITER_CHANGE_PCT[$device]:-0} confidence=${TBW_FORECAST_CONFIDENCE[$device]:-INSUFFICIENT}"
    done
    trend_log_diagnostics
}

# shellcheck disable=SC2329  # Invoked by the main monitoring pipeline.
build_trend_section() {
    trap 'log_crit "Trend analysis failed in block: ${CURRENT_TREND_BLOCK:-unknown}"' ERR

    CURRENT_TREND_BLOCK="initialization"
    TEMP_FORECAST_CONFIDENCE_LINE=""
    TREND_DIAGNOSTIC_ITEMS=()
    TREND_HISTORY_CACHE=()

    run_trend_stage "temperature" analyze_temperature_trends
    run_trend_stage "SATA link" analyze_sata_link_trends
    log_health_trends

    trap - ERR
    return 0
}

# === Helper Function ===
# Build notification subject line
build_subject() {
    if (( FINDING_CRITICAL_COUNT == 0 && FINDING_WARNING_COUNT == 0 &&
          NOTIFICATION_RESOLVED_COUNT > 0 )); then
        SUBJECT="Disk Health Monitor - RECOVERED (${NOTIFICATION_RESOLVED_COUNT})"
    elif (( FINDING_CRITICAL_COUNT > 0 )); then
        SUBJECT="Disk Health Monitor - CRITICAL (${FINDING_CRITICAL_COUNT})"
    elif (( FINDING_WARNING_COUNT > 0 )); then
        SUBJECT="Disk Health Monitor - WARNING (${FINDING_WARNING_COUNT})"
    else
        SUBJECT="Disk Health Monitor - OK"
    fi
    if (( NOTIFICATION_RESOLVED_COUNT > 0 &&
          (FINDING_CRITICAL_COUNT > 0 || FINDING_WARNING_COUNT > 0) )); then
        SUBJECT+=" - ${NOTIFICATION_RESOLVED_COUNT} recovered"
    fi
}

# Keep the current per-device score for alert ordering and SMART scheduling.
# shellcheck disable=SC2329

# Compute a monotonic counter rate inside one bounded epoch range. Results are
# returned through globals so callers do not lose side effects in a subshell.
COUNTER_WINDOW_RATE=0
COUNTER_WINDOW_SPAN_DAYS="0"
COUNTER_WINDOW_SAMPLES=0
WRITER_DIRECTION_RESULT="COLLECTING"
WRITER_CHANGE_RESULT="0.0"

calculate_counter_window_rate() {
    local sequence="$1" minimum_epoch="$2" maximum_epoch="$3" minimum_samples="$4"
    local sample_epoch value previous_value="" first_epoch=0 first_value=0
    local last_epoch=0 last_value=0 samples=0 reset_seen=0 span_seconds

    COUNTER_WINDOW_RATE=0
    COUNTER_WINDOW_SPAN_DAYS="0"
    COUNTER_WINDOW_SAMPLES=0
    [[ "$minimum_epoch" =~ ^[0-9]+$ && "$maximum_epoch" =~ ^[0-9]+$ &&
       "$minimum_samples" =~ ^[1-9][0-9]*$ ]] || return 1
    (( maximum_epoch >= minimum_epoch )) || return 1

    while read -r sample_epoch value; do
        [[ "$sample_epoch" =~ ^[0-9]+$ && "$value" =~ ^[0-9]+$ ]] || continue
        (( sample_epoch >= minimum_epoch && sample_epoch <= maximum_epoch )) || continue
        if (( samples == 0 )); then
            first_epoch=$sample_epoch
            first_value=$value
        elif (( value < previous_value )); then
            reset_seen=1
        fi
        last_epoch=$sample_epoch
        last_value=$value
        previous_value=$value
        samples=$((samples + 1))
    done < <(printf '%s' "$sequence" | LC_ALL=C sort -n -k1,1)

    COUNTER_WINDOW_SAMPLES=$samples
    (( samples >= minimum_samples && reset_seen == 0 && last_epoch > first_epoch )) || return 1
    (( last_value >= first_value )) || return 1
    span_seconds=$((last_epoch - first_epoch))
    COUNTER_WINDOW_SPAN_DAYS=$(awk -v seconds="$span_seconds" \
        'BEGIN { printf "%.3f", seconds/86400.0 }')
    COUNTER_WINDOW_RATE=$(awk -v first="$first_value" -v last="$last_value" \
        -v seconds="$span_seconds" \
        'BEGIN { printf "%d", ((last-first)*86400.0)/seconds }')
    return 0
}

classify_writer_direction() {
    local recent="$1" previous="$2" threshold="$3"

    WRITER_DIRECTION_RESULT="COLLECTING"
    WRITER_CHANGE_RESULT="0.0"
    [[ "$recent" =~ ^[0-9]+$ && "$previous" =~ ^[0-9]+$ &&
       "$threshold" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
    if (( previous == 0 )); then
        if (( recent > 0 )); then
            WRITER_DIRECTION_RESULT="RISING"
            WRITER_CHANGE_RESULT="100.0"
        else
            WRITER_DIRECTION_RESULT="STEADY"
        fi
        return 0
    fi
    WRITER_CHANGE_RESULT=$(awk -v recent="$recent" -v previous="$previous" \
        'BEGIN { printf "%.1f", ((recent-previous)/previous)*100 }')
    if awk -v change="$WRITER_CHANGE_RESULT" -v threshold="$threshold" \
        'BEGIN { exit !(change <= -threshold) }'
    then
        WRITER_DIRECTION_RESULT="IMPROVING"
    elif awk -v change="$WRITER_CHANGE_RESULT" -v threshold="$threshold" \
        'BEGIN { exit !(change >= threshold) }'
    then
        WRITER_DIRECTION_RESULT="RISING"
    else
        WRITER_DIRECTION_RESULT="STEADY"
    fi
}

# === Main Function ===
# Analyze TBW history for a smoothed endurance forecast and a separate recent
# workload rate that can respond quickly when writes are reduced.
# shellcheck disable=SC2329
collect_write_rates() {
    # Measured write rates only; rated TBW is not a failure-date prediction.
    TBW_FORECAST_CONFIDENCE=()
    WRITER_DAILY=()
    WRITER_PREVIOUS_DAILY=()
    WRITER_DIRECTION=()
    WRITER_CHANGE_PCT=()
    WRITER_RECENT_READY=()
    WRITER_RECENT_SAMPLES=()
    WRITER_PREVIOUS_SAMPLES=()
    local today
    today=$(date '+%Y-%m-%d')
    local -a tbw_records=()
    for dev in "${!SMART_STATE[@]}"; do
        [[ -n "${SMART_DEFERRED[$dev]:-}" ]] && continue
        local tbw=${CUR_ATTR["$dev|tbw_bytes"]:-}
        if [[ "$tbw" =~ ^[0-9]+$ ]]; then
            tbw_records+=("$today $(persistent_device_key "$dev") tbw=$tbw captured_epoch=$RUN_EPOCH schema=$HISTORY_SCHEMA_VERSION")
        fi
    done
    collector_replace_daily_history "$TBW_HISTORY_FILE" "$today" "${tbw_records[@]}" ||
        log_warn "Unable to atomically update TBW history"
    local win=$HISTORY_WINDOW_DAYS
    # Compute per-device daily TBW deltas over window and estimate days to threshold
    local cutoff
    cutoff=$(date -d "-$win days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
    local lines
    lines=$(tail -n 50000 "$TBW_HISTORY_FILE" 2>/dev/null || true)
    [[ -n "$lines" ]] || return 0
    declare -A _TBW_SAMPLE_VALUE=() _TBW_SAMPLE_EPOCH=() _TBW_DEVICE_SEEN=() _TBW_SEQUENCE=()
    local stored_key dt rest v sample_key sample_epoch
    while read -r dt stored_key rest; do
        [[ "$dt" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
        [[ "$dt" < "$cutoff" ]] && continue
        dev=$(runtime_device_path "$stored_key" 2>/dev/null || true)
        [[ -n "$dev" ]] || continue
        v=$(history_field_value "$rest" tbw 2>/dev/null || true)
        [[ "$v" =~ ^[0-9]+$ ]] || continue
        sample_epoch=$(history_record_epoch "$dt" "$rest" 2>/dev/null || true)
        [[ "$sample_epoch" =~ ^[0-9]+$ ]] || continue
        sample_key="$dev|$dt"
        _TBW_SAMPLE_VALUE[$sample_key]="$v"
        _TBW_SAMPLE_EPOCH[$sample_key]="$sample_epoch"
        _TBW_DEVICE_SEEN[$dev]=1
    done < <(printf '%s\n' "$lines")

    for sample_key in "${!_TBW_SAMPLE_VALUE[@]}"; do
        dev="${sample_key%|*}"
        _TBW_SEQUENCE[$dev]="${_TBW_SEQUENCE[$dev]:-}${_TBW_SAMPLE_EPOCH[$sample_key]} ${_TBW_SAMPLE_VALUE[$sample_key]}"$'\n'
    done

    local writer_window_seconds=$((HEAVY_WRITER_RECENT_DAYS * 86400))
    local writer_recent_min=$((RUN_EPOCH - writer_window_seconds))
    local writer_previous_min=$((RUN_EPOCH - writer_window_seconds * 2))
    local writer_previous_max=$writer_recent_min
    (( writer_recent_min >= 0 )) || writer_recent_min=0
    (( writer_previous_min >= 0 )) || writer_previous_min=0

    for dev in "${!_TBW_DEVICE_SEEN[@]}"; do
        local first_epoch=0 last_epoch=0 previous_epoch=0 previous_value=""
        local samples=0 max_gap_seconds=0 gap_seconds reset_seen=0
        while read -r sample_epoch v; do
            [[ "$sample_epoch" =~ ^[0-9]+$ && "$v" =~ ^[0-9]+$ ]] || continue
            if (( samples == 0 )); then
                first_epoch=$sample_epoch
            else
                gap_seconds=$(( sample_epoch - previous_epoch ))
                (( gap_seconds > max_gap_seconds )) && max_gap_seconds=$gap_seconds
                (( v < previous_value )) && reset_seen=1
            fi
            last_epoch=$sample_epoch
            previous_epoch=$sample_epoch
            previous_value=$v
            ((samples++)) || true
        done < <(printf '%s' "${_TBW_SEQUENCE[$dev]:-}" | sort -n -k1,1)

        local span_days latest_age_days max_gap_days confidence
        span_days=$(awk -v first="$first_epoch" -v last="$last_epoch" \
            'BEGIN { if(last>first) printf "%.3f", (last-first)/86400.0; else print "0" }')
        latest_age_days=$(awk -v now="$RUN_EPOCH" -v last="$last_epoch" \
            'BEGIN { age=(now-last)/86400.0; if(age<0) age=0; printf "%.3f", age }')
        max_gap_days=$(awk -v gap="$max_gap_seconds" 'BEGIN { printf "%.3f", gap/86400.0 }')
        confidence=$(forecast_confidence "$samples" "$span_days" "$latest_age_days" "$max_gap_days")
        if (( reset_seen == 1 )); then
            confidence="RESET"
        fi
        TBW_FORECAST_CONFIDENCE[$dev]="$confidence"

        if calculate_counter_window_rate "${_TBW_SEQUENCE[$dev]:-}" \
            "$writer_recent_min" "$RUN_EPOCH" "$HEAVY_WRITER_MIN_RECENT_SAMPLES"
        then
            WRITER_DAILY[$dev]="$COUNTER_WINDOW_RATE"
            WRITER_RECENT_READY[$dev]=1
            WRITER_RECENT_SAMPLES[$dev]="$COUNTER_WINDOW_SAMPLES"
            if calculate_counter_window_rate "${_TBW_SEQUENCE[$dev]:-}" \
                "$writer_previous_min" "$writer_previous_max" \
                "$HEAVY_WRITER_MIN_RECENT_SAMPLES"
            then
                WRITER_PREVIOUS_DAILY[$dev]="$COUNTER_WINDOW_RATE"
                WRITER_PREVIOUS_SAMPLES[$dev]="$COUNTER_WINDOW_SAMPLES"
                classify_writer_direction "${WRITER_DAILY[$dev]}" \
                    "${WRITER_PREVIOUS_DAILY[$dev]}" "$HEAVY_WRITER_IMPROVEMENT_PCT"
                WRITER_DIRECTION[$dev]="$WRITER_DIRECTION_RESULT"
                WRITER_CHANGE_PCT[$dev]="$WRITER_CHANGE_RESULT"
            else
                WRITER_PREVIOUS_SAMPLES[$dev]=0
                WRITER_DIRECTION[$dev]="COLLECTING"
                WRITER_CHANGE_PCT[$dev]="0.0"
            fi
        else
            WRITER_RECENT_READY[$dev]=0
            WRITER_RECENT_SAMPLES[$dev]=0
            WRITER_PREVIOUS_SAMPLES[$dev]=0
            WRITER_DIRECTION[$dev]="COLLECTING"
            WRITER_CHANGE_PCT[$dev]="0.0"
        fi
    done

}

# === Helper Function ===
# Detect firmware/controller resets by checking for Power-On Hours (POH) drops and NVMe Percentage Used regression
# shellcheck disable=SC2329
detect_counter_resets() {
    local events=""
    for dev in "${!SMART_STATE[@]}"; do
        local prev_poh=${PREV_ATTR["$dev|poh"]:-}
        local curr_poh=${CUR_ATTR["$dev|poh"]:-}
        if [[ -n "$prev_poh" && -n "$curr_poh" && "$prev_poh" =~ ^[0-9]+$ && "$curr_poh" =~ ^[0-9]+$ && $curr_poh -lt $prev_poh ]]; then
            local drop=$(( prev_poh - curr_poh ))
            local sev="warning"
            if (( drop > POH_RESET_CRIT_THRESHOLD )); then sev="critical"; fi
            events+=" - $(basename "$dev") POH regression: ${prev_poh}h -> ${curr_poh}h (drop ${drop}h)\n"
            record_alert "$sev" "Firmware Reset" "Disk $dev Power-On Hours dropped (${prev_poh} -> ${curr_poh}) possible controller/firmware reset"
        fi
        if [[ "$dev" == /dev/nvme* ]]; then
            local prev_used=${PREV_ATTR["$dev|nvme_percent_used"]:-}
            local curr_used=${CUR_ATTR["$dev|nvme_percent_used"]:-}
            if [[ -n "$prev_used" && -n "$curr_used" && "$prev_used" =~ ^[0-9]+$ && "$curr_used" =~ ^[0-9]+$ && $curr_used -lt $prev_used ]]; then
                local delta=$(( prev_used - curr_used ))
                if (( NVME_WEAR_REGRESSION_WARN > 0 &&
                      delta >= NVME_WEAR_REGRESSION_WARN )); then
                    events+=" - $(basename "$dev") NVMe percent_used regression: ${prev_used}% -> ${curr_used}% (drop ${delta}%)\n"
                    record_alert warning "Firmware Reset" "Disk $dev NVMe Percentage Used decreased (${prev_used}% -> ${curr_used}%); check firmware or controller resets"
                fi
            fi
        fi
    done
    return 0
}

# Normalize a counter delta to a per-day rate when capture timing is known.
counter_rate_per_day() {
    local delta="$1" elapsed_seconds="$2"
    (( elapsed_seconds > 0 )) || return 1
    awk -v delta="$delta" -v elapsed="$elapsed_seconds" \
        'BEGIN { printf "%.6f", (delta * 86400.0) / elapsed }'
}

last_btrfs_history_metric() {
    local stable_key="$1" legacy_path="$2" wanted_key="$3"
    [[ -f "$BTRFS_DEV_HIST_FILE" ]] || return 0
    awk -v stable="$stable_key" -v legacy="$legacy_path" -v wanted="$wanted_key" '
        $2 != stable && $2 != legacy { next }
        {
            matched = 0
            reset = 0
            delta = ""
            rate = ""
            for (i = 3; i <= NF; i++) {
                if ($i == "key=" wanted) matched = 1
                if ($i == "event=reset") reset = 1
                if ($i ~ /^delta=/) { delta=$i; sub(/^delta=/, "", delta) }
                if ($i ~ /^rate_day=/) { rate=$i; sub(/^rate_day=/, "", rate) }
            }
            if (!matched) next
            if (reset) { print "reset", 0; next }
            if (delta !~ /^[0-9]+$/) next
            if (rate ~ /^[0-9]+([.][0-9]+)?$/ && rate > 0) print "rate", rate
            else print "delta", delta
        }
    ' "$BTRFS_DEV_HIST_FILE" 2>/dev/null | tail -n 1
}

# Collect Btrfs counters without resetting them. Missing baselines and counter
# regressions establish a new baseline and never become synthetic error deltas.
# shellcheck disable=SC2329
collect_btrfs_device_stats() {
    (( ${ENABLE_BTRFS_DEVICE_STATS:-0} == 1 )) || return 0
    local prev_file="$BTRFS_DEV_PREV_FILE"
    local snapshot_temp now_epoch previous_epoch=0 current_boot_id="unknown"
    local stored_key state_key dev key val line token m stats prev delta elapsed_seconds
    local rate_day current_kind current_metric last_kind last_metric ratio=0
    local absolute_severity alert_severity alert_title alert_message boost bdev
    local out_has=0 baseline_count=0 reset_count=0 delta_count=0
    local today
    local -a mounts=()
    declare -A PREV_STAT=() PREV_PRESENT=()

    now_epoch=$(date +%s)
    [[ -r /proc/sys/kernel/random/boot_id ]] && read -r current_boot_id < /proc/sys/kernel/random/boot_id || true

    if [[ -f "$prev_file" ]]; then
        while read -r stored_key key val line; do
            if [[ "$stored_key" == "meta" ]]; then
                for token in "$key" "$val" $line; do
                    [[ "$token" == captured_epoch=* ]] && previous_epoch="${token#*=}"
                done
                continue
            fi
            dev=$(runtime_device_path "$stored_key" 2>/dev/null || true)
            [[ -n "$dev" && -n "$key" && "$val" =~ ^[0-9]+$ ]] || continue
            PREV_STAT["$dev|$key"]="$val"
            PREV_PRESENT["$dev|$key"]=1
        done < "$prev_file"
    fi
    [[ "$previous_epoch" =~ ^[0-9]+$ ]] || previous_epoch=0
    elapsed_seconds=$(( now_epoch - previous_epoch ))
    (( elapsed_seconds > 0 )) || elapsed_seconds=0

    mapfile -t mounts < <(mount | awk '/ btrfs /{print $3}')
    (( ${#mounts[@]} > 0 )) || return 0

    snapshot_temp="$(state_temp_file "$prev_file")" || return 0
    printf 'meta schema=2 captured_epoch=%s boot_id=%s\n' "$now_epoch" "$current_boot_id" > "$snapshot_temp"
    today=$(date '+%Y-%m-%d')

    for m in "${mounts[@]}"; do
        # Never pass -z: the monitor must preserve filesystem diagnostic evidence.
        stats=$(btrfs_bounded device stats "$m" 2>/dev/null || true)
        [[ -n "$stats" ]] || continue

        while IFS=$'\t' read -r dev key val; do
            [[ -n "$dev" && -n "$key" && "$val" =~ ^[0-9]+$ ]] || continue
            FRESH_FILESYSTEM["btrfs:$(base_device "$dev"):$key"]=1
            state_key=$(persistent_device_key "$dev")
            printf '%s %s %s\n' "$state_key" "$key" "$val" >> "$snapshot_temp"
            out_has=1

            if [[ -z "${PREV_PRESENT["$dev|$key"]:-}" ]]; then
                ((baseline_count++)) || true
                continue
            fi

            prev=${PREV_STAT["$dev|$key"]}
            if (( val < prev )); then
                ((reset_count++)) || true
                printf '%s %s mount=%s key=%s event=reset previous=%s value=%s captured_epoch=%s schema=%s\n' \
                    "$today" "$state_key" "$m" "$key" "$prev" "$val" \
                    "$RUN_EPOCH" "$HISTORY_SCHEMA_VERSION" >> "$BTRFS_DEV_HIST_FILE"
                continue
            fi

            delta=$(( val - prev ))
            (( delta > 0 )) || continue
            ((delta_count++)) || true
            rate_day=$(counter_rate_per_day "$delta" "$elapsed_seconds" 2>/dev/null || true)
            if [[ -n "$rate_day" ]]; then
                current_kind="rate"
                current_metric="$rate_day"
            else
                current_kind="delta"
                current_metric="$delta"
            fi

            last_kind=""; last_metric=""; ratio=0
            read -r last_kind last_metric < <(last_btrfs_history_metric "$state_key" "$dev" "$key") || true
            if [[ "$last_kind" == "$current_kind" && "$last_metric" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                ratio=$(awk -v current="$current_metric" -v previous="$last_metric" \
                    'BEGIN { if (previous > 0) printf "%d", int(current / previous); else print 0 }')
            fi

            printf '%s %s mount=%s key=%s delta=%s value=%s elapsed_sec=%s%s captured_epoch=%s schema=%s\n' \
                "$today" "$state_key" "$m" "$key" "$delta" "$val" "$elapsed_seconds" \
                "${rate_day:+ rate_day=$rate_day}" "$RUN_EPOCH" "$HISTORY_SCHEMA_VERSION" >> "$BTRFS_DEV_HIST_FILE"

            absolute_severity=""
            case "$key" in
                corruption_errs|generation_errs)
                    if (( delta >= BTRFS_DEV_CORR_CRIT_DELTA )); then absolute_severity="critical"
                    elif (( delta >= BTRFS_DEV_CORR_WARN_DELTA )); then absolute_severity="warning"
                    fi
                    ;;
                read_io_errs|write_io_errs|flush_io_errs)
                    if (( delta >= BTRFS_DEV_ERR_CRIT_DELTA )); then absolute_severity="critical"
                    elif (( delta >= BTRFS_DEV_ERR_WARN_DELTA )); then absolute_severity="warning"
                    fi
                    ;;
            esac

            alert_severity="$absolute_severity"
            alert_title="Btrfs Device"
            alert_message="Device $dev $key +$delta (now $val) on mount $m"
            boost=0
            if (( ratio >= BTRFS_ERR_BURST_CRIT_RATIO )); then
                alert_severity="critical"
                alert_title="Btrfs Burst"
                alert_message="Device $dev $key rate burst x${ratio} (+$delta) on mount $m"
                boost=$BURST_CRIT_BOOST
            elif (( ratio >= BTRFS_ERR_BURST_WARN_RATIO )); then
                [[ "$alert_severity" == "critical" ]] || alert_severity="warning"
                alert_title="Btrfs Burst"
                alert_message="Device $dev $key rate elevated x${ratio} (+$delta) on mount $m"
                boost=$BURST_WARN_BOOST
            fi

            [[ -n "$alert_severity" ]] || continue
            record_alert "$alert_severity" "$alert_title" "$alert_message"
            bdev=$(base_device "$dev")
            [[ -n "$bdev" ]] || continue
            [[ -n "${SMART_STATE[$bdev]:-}" ]] || SMART_STATE[$bdev]="OK"
            SMART_MSGS[$bdev]="${SMART_MSGS[$bdev]:-} Btrfs device errors: $key +$delta"
            if (( boost > 0 )); then
                boost=$(( ${BURST_BOOST[$bdev]:-0} + boost ))
                (( boost > 100 )) && boost=100
                BURST_BOOST[$bdev]=$boost
            fi
        done < <(parse_btrfs_device_stats_text "$stats")
    done

    if (( out_has == 1 )); then
        collector_atomic_commit "$snapshot_temp" "$prev_file" || true
    else
        rm -f -- "$snapshot_temp" 2>/dev/null || true
    fi
    (( baseline_count > 0 )) && log "BTRFS" "INFO" \
        "Established $baseline_count new counter baseline(s) without alerting"
    (( reset_count > 0 )) && log "BTRFS" "WARN" \
        "Detected $reset_count counter reset(s); affected counters were re-baselined"
    log "BTRFS" "INFO" "Recorded $delta_count positive counter delta(s)"
}

# === Main Function ===
# Collect and integrate xfs /proc stats (global deltas)
# shellcheck disable=SC2329

# ---------------------------------------------------------------------------
# Notification assembly
# ---------------------------------------------------------------------------

add_notification_section() {
    local section="${1:-}"
    local cleaned

    if ! printf '%s' "$section" | grep -q '[^[:space:]]'; then
        return 0
    fi

    section="${section//\\n/$'\n'}"
    cleaned="$(
        printf '%s\n' "$section" |
            awk '
                BEGIN { emitted=0; blanks=0 }
                /^[[:space:]]*$/ { blanks++; next }
                {
                    if (blanks > 0 && emitted > 0)
                        print ""
                    blanks=0
                    print
                    emitted++
                }
            '
    )"

    [[ -n "$cleaned" ]] && NOTIFY_SECTIONS+=("$cleaned")
}

limit_notification_body() {
    local max_chars="${NOTIFY_MAX_BODY_CHARS:-12000}"
    local max_lines="${NOTIFY_MAX_BODY_LINES:-180}"
    local full_chars full_lines notice content_char_limit content_line_limit
    local line limited="" separator_chars candidate_chars line_number=0

    FULL_NOTIFICATION_BODY="$NOTIFY_BODY"
    NOTIFICATION_TRUNCATED=0
    full_chars=${#FULL_NOTIFICATION_BODY}
    full_lines=$(printf '%s\n' "$FULL_NOTIFICATION_BODY" | awk 'END {print NR+0}')
    if (( full_chars <= max_chars && full_lines <= max_lines )); then
        return 0
    fi

    NOTIFICATION_TRUNCATED=1
    if (( LOG_FULL_NOTIFICATION_ON_TRUNCATION == 1 )) && [[ -n "${MASTER_LOG:-}" ]]; then
        notice="[Report shortened: complete ${full_lines}-line report saved in ${MASTER_LOG}.]"
    else
        notice="[Report shortened: increase the notification limits to include more detail.]"
    fi
    content_char_limit=$((max_chars - ${#notice} - 1))
    content_line_limit=$((max_lines - 1))
    (( content_char_limit > 0 )) || content_char_limit=1
    (( content_line_limit > 0 )) || content_line_limit=1

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        (( line_number <= content_line_limit )) || break
        if [[ -n "$limited" ]]; then separator_chars=1; else separator_chars=0; fi
        candidate_chars=$(( ${#limited} + separator_chars + ${#line} ))
        if (( candidate_chars > content_char_limit )); then
            if [[ -z "$limited" ]]; then
                limited="${line:0:content_char_limit}"
            fi
            break
        fi
        [[ -z "$limited" ]] || limited+=$'\n'
        limited+="$line"
    done <<< "$FULL_NOTIFICATION_BODY"

    NOTIFY_BODY="${limited}${limited:+$'\n'}${notice}"

    if (( LOG_FULL_NOTIFICATION_ON_TRUNCATION == 1 )) && [[ -n "${MASTER_LOG:-}" ]]; then
        {
            printf '\n===== FULL NOTIFICATION BODY (v%s) =====\n' "$SCRIPT_VERSION"
            printf '%s\n' "$FULL_NOTIFICATION_BODY"
            printf '===== END FULL NOTIFICATION BODY =====\n'
        } >> "$MASTER_LOG"
        log "REPORT" "WARN" \
            "Notification shortened from ${full_chars} characters/${full_lines} lines; full body retained in $MASTER_LOG"
    else
        log "REPORT" "WARN" \
            "Notification shortened from ${full_chars} characters/${full_lines} lines"
    fi
}

compose_notification() {
    local index

    NOTIFY_SECTIONS=()
    add_notification_section "${HEALTH_ALERTS_SECTION:-}"
    add_notification_section "${NOTIFICATION_RECOVERY_SECTION:-}"
    if [[ -n "${HEALTH_ALERTS_SECTION:-}" || -z "${NOTIFICATION_RECOVERY_SECTION:-}" ]]; then
        add_notification_section "${STORAGE_TOP_LINES:-}"
    fi
    if (( ${#NOTIFY_SECTIONS[@]} == 0 )); then
        add_notification_section "No actionable findings in the data collected."
    fi

    NOTIFY_BODY=""
    for index in "${!NOTIFY_SECTIONS[@]}"; do
        if (( index > 0 )); then
            NOTIFY_BODY+=$'\n\n'
        fi
        NOTIFY_BODY+="${NOTIFY_SECTIONS[$index]}"
    done

    if (( FINDING_CRITICAL_COUNT > 0 )); then
        FINAL_NOTIFICATION_SEVERITY="critical"
    elif (( FINDING_WARNING_COUNT > 0 )); then
        FINAL_NOTIFICATION_SEVERITY="warning"
    else
        FINAL_NOTIFICATION_SEVERITY="normal"
    fi

    limit_notification_body
}

# ---------------------------------------------------------------------------
# Atomic persistence
# ---------------------------------------------------------------------------

persist_current_attrs() {
    local target="$1"
    local temp_file disk key value line state_key

    temp_file="$(state_temp_file "$target")" || return 1

    for disk in "${!SMART_STATE[@]}"; do
        state_key=$(persistent_device_key "$disk")
        line="$state_key state=${SMART_STATE[$disk]}"

        for key in \
            realloc pending offunc reported_uncorr cmd_timeout realloc_events \
            udma lcc end2end soft_read_err temp poh vendor_mwi host_write_units_revision tbw_bytes \
            tbw_consumed_pct nvme_percent_used unsafe_shutdowns media_errors \
            err_logs avail_spare pcie_corr pcie_unc therm_t1 therm_t2 \
            warn_temp_time crit_temp_time selftest_status
        do
            value=${CUR_ATTR["$disk|$key"]:-}
            [[ -n "$value" ]] && line+=" $key=$value"
        done

        printf '%s\n' "$line" >> "$temp_file" || return 1
    done

    atomic_commit "$temp_file" "$target"
}

persist_new_seen() {
    local temp_file key state_key

    temp_file="$(state_temp_file "$ALERT_NEW_SEEN_FILE")" || return 1

    for key in "${!NEW_SEEN[@]}"; do
        state_key=$(persistent_seen_key "$key")
        printf '%s\n' "$state_key" >> "$temp_file" || return 1
    done

    atomic_commit "$temp_file" "$ALERT_NEW_SEEN_FILE"
}

persist_smart_baselines() {
    local nvme="$RUN_DIR/nvme-baseline" smart="$RUN_DIR/smart-baseline"
    local timeouts="$RUN_DIR/timeout-baseline" json
    save_nvme_state "$nvme" || return 1
    persist_current_attrs "$smart" || return 1
    save_cmd_timeout_last "$timeouts" || return 1
    json=$(jq -nc --rawfile nvme "$nvme" --rawfile smart "$smart" --rawfile timeouts "$timeouts" '
        def rows($text): $text | split("\n") | map(select(length > 0) | split(" "));
        def attrs($text):
            reduce (rows($text)[]) as $row ({};
                .[$row[0]] = (reduce ($row[1:][]) as $field ({};
                    ($field|index("=")) as $sep |
                    if $sep then .[$field[:$sep]] = $field[$sep+1:] else error("invalid SMART field") end)));
        {schema:1, nvme:attrs($nvme), smart:attrs($smart),
         command_timeout:(reduce (rows($timeouts)[]) as $row ({}; .[$row[0]] = $row[1]))}
    ') || return 1
    atomic_write_text "$SMART_BASELINES_FILE" "$json"$'\n'
}

persist_all_state() {
    local failed=0
    log "STATE" "INFO" "Persisting runtime state"
    if collector_status_is_safe smart; then
        persist_smart_baselines || { record_collector_event FAILED "SMART baseline JSON" "write failed"; failed=1; }
        save_long_last_poh || { record_collector_event FAILED "Long self-test baseline" "write failed"; failed=1; }
        save_last_test || { record_collector_event FAILED "SMART test scheduling baseline" "write failed"; failed=1; }
    else
        log "STATE" "WARN" \
            "Preserved SMART/NVMe baselines because the SMART collector was incomplete"
    fi
    persist_new_seen || { record_collector_event FAILED "Seen alert baseline" "write failed"; failed=1; }
    return "$failed"
}

# ---------------------------------------------------------------------------
# Validation and orchestration
# ---------------------------------------------------------------------------

configuration_error() {
    CONFIG_ERROR_COUNT=$((CONFIG_ERROR_COUNT + 1))
    log "CONFIG" "ERROR" "$*"
}

configuration_warning() {
    CONFIG_WARNING_COUNT=$((CONFIG_WARNING_COUNT + 1))
    log "CONFIG" "WARN" "$*"
}

configuration_value() {
    local setting="$1"

    if ! declare -p "$setting" >/dev/null 2>&1; then
        return 1
    fi
    printf '%s' "${!setting}"
}

validate_boolean_setting() {
    local setting="$1" value

    value=$(configuration_value "$setting" 2>/dev/null || true)
    [[ "$value" =~ ^[01]$ ]] ||
        configuration_error "$setting must be 0 or 1 (found '${value:-unset}')"
}

validate_nonnegative_integer_setting() {
    local setting="$1" value

    value=$(configuration_value "$setting" 2>/dev/null || true)
    [[ "$value" =~ ^[0-9]+$ ]] ||
        configuration_error "$setting must be a non-negative integer (found '${value:-unset}')"
}

validate_positive_integer_setting() {
    local setting="$1" value

    value=$(configuration_value "$setting" 2>/dev/null || true)
    [[ "$value" =~ ^[1-9][0-9]*$ ]] ||
        configuration_error "$setting must be a positive integer (found '${value:-unset}')"
}

validate_nonnegative_number_setting() {
    local setting="$1" value

    value=$(configuration_value "$setting" 2>/dev/null || true)
    [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
        configuration_error "$setting must be a non-negative number (found '${value:-unset}')"
}

validate_positive_number_setting() {
    local setting="$1" value

    value=$(configuration_value "$setting" 2>/dev/null || true)
    if [[ ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
       ! awk -v value="$value" 'BEGIN { exit !(value > 0) }'
    then
        configuration_error "$setting must be a positive number (found '${value:-unset}')"
    fi
}

validate_percent_setting() {
    local setting="$1" value

    value=$(configuration_value "$setting" 2>/dev/null || true)
    if [[ ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
       ! awk -v value="$value" 'BEGIN { exit !(value >= 0 && value <= 100) }'
    then
        configuration_error "$setting must be between 0 and 100 (found '${value:-unset}')"
    fi
}

validate_ordered_pair() {
    local lower_setting="$1" upper_setting="$2" lower upper

    lower=$(configuration_value "$lower_setting" 2>/dev/null || true)
    upper=$(configuration_value "$upper_setting" 2>/dev/null || true)
    [[ "$lower" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
    [[ "$upper" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
    if ! awk -v lower="$lower" -v upper="$upper" \
        'BEGIN { exit !(lower <= upper) }'
    then
        configuration_error \
            "$lower_setting ($lower) must be less than or equal to $upper_setting ($upper)"
    fi
}

validate_absolute_path_setting() {
    local setting="$1" value

    value=$(configuration_value "$setting" 2>/dev/null || true)
    if ! validate_secure_absolute_path "$value"; then
        configuration_error "$setting $PATH_VALIDATION_REASON (found '${value:-unset}')"
        return 0
    fi
    if [[ -L "$value" ]]; then
        configuration_error "$setting must not be a symbolic link"
        return 0
    fi

    case "$setting" in
        LOG_DIR)
            if [[ -e "$value" && ! -d "$value" ]]; then
                configuration_error "$setting must identify a directory"
            fi
            ;;
        LOCK_FILE|NOTIFY_BIN|IO_ERROR_LOG_FILE)
            if [[ -e "$value" && ! -f "$value" ]]; then
                configuration_error "$setting must identify a regular file"
            fi
            ;;
    esac
    if [[ "$setting" == "LOG_DIR" && "$value" == */ ]]; then
        configuration_error "$setting must not end with a slash"
    fi
}

validate_model_rule_block() {
    local setting="$1" kind="$2" block line line_number=0

    block=$(configuration_value "$setting" 2>/dev/null || true)
    while IFS= read -r line; do
        line_number=$((line_number + 1))
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == "\\" || "$line" =~ ^[[:space:]]*# ]] && continue

        local -A fields=()
        local -a parts=()
        local part key value grep_status
        IFS=';' read -r -a parts <<< "$line"
        for part in "${parts[@]}"; do
            if [[ "$part" != *:* ]]; then
                configuration_error "$setting line $line_number has an invalid field: $part"
                continue
            fi
            key="${part%%:*}"
            value="${part#*:}"
            case "$kind:$key" in
                tbw:regex|tbw:per_tb|tbw:cap_min|tbw:cap_max|\
                poh:type|poh:regex|poh:warn|poh:crit|poh:cap_min|poh:cap_max|\
                quirk:action|quirk:regex|quirk:cap_min|quirk:cap_max)
                    ;;
                *)
                    configuration_error \
                        "$setting line $line_number contains unsupported key '$key'"
                    continue
                    ;;
            esac
            if [[ -n "${fields[$key]+set}" ]]; then
                configuration_error "$setting line $line_number repeats key '$key'"
            fi
            fields[$key]="$value"
        done

        if [[ -z "${fields[regex]:-}" ]]; then
            configuration_error "$setting line $line_number requires regex"
        else
            printf '' | grep -Eq -- "${fields[regex]}" 2>/dev/null
            grep_status=$?
            (( grep_status != 2 )) ||
                configuration_error "$setting line $line_number has an invalid regex"
        fi

        for key in cap_min cap_max; do
            [[ -z "${fields[$key]:-}" ]] && continue
            [[ "${fields[$key]}" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
                configuration_error "$setting line $line_number has invalid $key"
        done
        if [[ "${fields[cap_min]:-}" =~ ^[0-9]+([.][0-9]+)?$ &&
              "${fields[cap_max]:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
           ! awk -v minimum="${fields[cap_min]}" -v maximum="${fields[cap_max]}" \
                'BEGIN { exit !(minimum <= maximum) }'
        then
            configuration_error "$setting line $line_number has cap_min greater than cap_max"
        fi

        case "$kind" in
            tbw)
                if [[ ! "${fields[per_tb]:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
                   ! awk -v value="${fields[per_tb]:-0}" 'BEGIN { exit !(value > 0) }'
                then
                    configuration_error "$setting line $line_number requires positive per_tb"
                fi
                ;;
            poh)
                case "${fields[type]:-}" in
                    nvme|sata-ssd|sata-hdd) ;;
                    *) configuration_error \
                        "$setting line $line_number requires type nvme, sata-ssd, or sata-hdd" ;;
                esac
                for key in warn crit; do
                    [[ "${fields[$key]:-}" =~ ^[1-9][0-9]*$ ]] ||
                        configuration_error "$setting line $line_number requires positive $key"
                done
                if [[ "${fields[warn]:-}" =~ ^[0-9]+$ &&
                      "${fields[crit]:-}" =~ ^[0-9]+$ ]] &&
                   ! awk -v warn="${fields[warn]}" -v crit="${fields[crit]}" \
                        'BEGIN { exit !(warn <= crit) }'
                then
                    configuration_error "$setting line $line_number has warn greater than crit"
                fi
                ;;
            quirk)
                case "${fields[action]:-}" in
                    invert_mwi_small) ;;
                    *) configuration_error \
                        "$setting line $line_number has unsupported action '${fields[action]:-unset}'" ;;
                esac
                ;;
        esac
    done <<< "$block"
}

validate_configuration() {
    CONFIG_ERROR_COUNT=0
    CONFIG_WARNING_COUNT=0

    local setting pair excluded_pool
    local -a boolean_settings=(
        SMART_ALLOW_SPINUP  LONG_TEST_INITIAL_FORCE

          ENABLE_BTRFS_DEVICE_STATS

        SATA_LINK_INSTABILITY_ENABLED

        TEMP_RATE_ALERT_ENABLED
        IO_ERROR_MONITOR_ENABLED IO_ERROR_DEDUP_ENABLED LOG_PRUNE_ENABLED
        HISTORY_PRUNE_ENABLED LOG_MIRROR_STDOUT

        WEAR_TREND_ENABLED ENABLE_MODEL_IN_ALERTS
        LOG_FULL_NOTIFICATION_ON_TRUNCATION COLLECTOR_FAILURE_NOTIFICATIONS
        NOTIFICATION_LIFECYCLE_ENABLED NOTIFICATION_DRY_RUN

    )
    local -a integer_settings=(
        SHORT_TEST_INTERVAL_DAYS
          LONG_TEST_MAX_INTERVAL_DAYS

        LONG_TEST_CRITICAL_MIN_DAYS  LONG_TEST_NEAR_WINDOW_DAYS

        WARN_THRESHOLD_PERCENT CRITICAL_THRESHOLD_PERCENT THRESHOLD NEAR_THRESHOLD_DELTA
        BTRFS_SCRUB_STATE_TTL_DAYS
        IO_ERROR_WINDOW_MINUTES
        IO_ERROR_WARN_THRESHOLD IO_ERROR_CRIT_THRESHOLD
        SYSLOG_CURSOR_STARTUP_LOOKBACK_LINES SYSLOG_CURSOR_ROTATION_LOOKBACK_LINES
        NVME_WEAR_REGRESSION_WARN PARITY_SYNC_ERR_WARN PARITY_SYNC_ERR_CRIT
        POH_RESET_CRIT_THRESHOLD
        SATA_LINK_INSTABILITY_WINDOW_DAYS SATA_LINK_INSTABILITY_STREAK_WARN
        SATA_LINK_INSTABILITY_STREAK_CRIT HISTORY_WINDOW_DAYS
        HISTORY_SCHEMA_VERSION FORECAST_MIN_SAMPLES FORECAST_HIGH_SAMPLES
        FORECAST_MAX_GAP_DAYS LOG_MAX_DAYS LOG_MAX_COUNT HISTORY_MAX_DAYS
        HISTORY_MAX_LINES
        RELOC_WARNING RELOC_CRITICAL PEND_WARNING
        SSD_TEMP_WARNING SSD_TEMP_CRITICAL HDD_TEMP_WARNING HDD_TEMP_CRITICAL
        LOAD_CYCLE_WARN LOAD_CYCLE_CRIT
        REPORTED_UNC_CRIT CMD_TIMEOUT_WARN CMD_TIMEOUT_CRIT CMD_TIMEOUT_DELTA_WARN
        CMD_TIMEOUT_COOLDOWN_DAYS REALLOC_EVENT_WARN REALLOC_EVENT_CRIT
        END_TO_END_ERR_CRIT SOFT_READ_ERR_WARN NVME_TEMP_WARNING NVME_TEMP_CRITICAL
        NVME_PERCENT_USED_WARN NVME_PERCENT_USED_CRIT

        HEAVY_WRITER_RECENT_DAYS HEAVY_WRITER_MIN_RECENT_SAMPLES
        HEAVY_WRITER_IMPROVEMENT_PCT

        UNSAFE_SDWN_DELTA_WARN UNSAFE_SDWN_ABSOLUTE_MIN UNSAFE_SDWN_COOLDOWN_DAYS
        NVME_AVAIL_SPARE_WARN NVME_ERR_LOG_DELTA_WARN NVME_ERR_LOG_DELTA_CRIT
        NVME_PCIE_CORR_DELTA_WARN NVME_PCIE_CORR_DELTA_CRIT
        NVME_PCIE_UNC_DELTA_WARN NVME_PCIE_UNC_DELTA_CRIT
        NVME_THERM_T1_DELTA_WARN NVME_THERM_T2_DELTA_WARN
        NVME_WARN_TEMP_TIME_DELTA_WARN NVME_CRIT_TEMP_TIME_DELTA_WARN
        BTRFS_DEV_ERR_WARN_DELTA BTRFS_DEV_ERR_CRIT_DELTA
        BTRFS_DEV_CORR_WARN_DELTA BTRFS_DEV_CORR_CRIT_DELTA
        BTRFS_ERR_BURST_WARN_RATIO BTRFS_ERR_BURST_CRIT_RATIO

         BURST_WARN_BOOST BURST_CRIT_BOOST

         TBW_CONSUMED_WARN TBW_CONSUMED_CRIT

         NOTIFY_MAX_BODY_CHARS NOTIFY_MAX_BODY_LINES
        SMARTCTL_TIMEOUT_SECONDS BTRFS_COMMAND_TIMEOUT_SECONDS
        SYSTEM_COMMAND_TIMEOUT_SECONDS
        NOTIFICATION_TIMEOUT_SECONDS
        COMMAND_KILL_GRACE_SECONDS COLLECTOR_SLOW_SECONDS
        NOTIFICATION_WARNING_REMINDER_HOURS NOTIFICATION_CRITICAL_REMINDER_HOURS
        NOTIFICATION_OK_REMINDER_HOURS NOTIFICATION_RECOVERY_CONFIRM_RUNS
        NOTIFICATION_MAX_ATTEMPTS
        NOTIFICATION_RETRY_INITIAL_DELAY_SECONDS NOTIFICATION_RETRY_MAX_DELAY_SECONDS

    )
    local -a number_settings=(
        FORECAST_MIN_SPAN_DAYS FORECAST_HIGH_SPAN_DAYS FORECAST_STALE_AFTER_DAYS
        TEMP_RATE_WARN_C_PER_DAY TEMP_RATE_MIN_SPAN_DAYS

    )
    local -a percent_settings=(
        WARN_THRESHOLD_PERCENT CRITICAL_THRESHOLD_PERCENT THRESHOLD NEAR_THRESHOLD_DELTA

          NVME_PERCENT_USED_WARN NVME_PERCENT_USED_CRIT
        NVME_AVAIL_SPARE_WARN TBW_CONSUMED_WARN TBW_CONSUMED_CRIT
        HEAVY_WRITER_IMPROVEMENT_PCT

    )
    local -a positive_integer_settings=(
         IO_ERROR_WINDOW_MINUTES
        SYSLOG_CURSOR_STARTUP_LOOKBACK_LINES SYSLOG_CURSOR_ROTATION_LOOKBACK_LINES
        HISTORY_WINDOW_DAYS HISTORY_SCHEMA_VERSION FORECAST_MIN_SAMPLES
        FORECAST_HIGH_SAMPLES FORECAST_MAX_GAP_DAYS
        HEAVY_WRITER_RECENT_DAYS HEAVY_WRITER_MIN_RECENT_SAMPLES

        NOTIFY_MAX_BODY_CHARS NOTIFY_MAX_BODY_LINES
        SMARTCTL_TIMEOUT_SECONDS BTRFS_COMMAND_TIMEOUT_SECONDS
        SYSTEM_COMMAND_TIMEOUT_SECONDS
        NOTIFICATION_TIMEOUT_SECONDS COMMAND_KILL_GRACE_SECONDS
        NOTIFICATION_MAX_ATTEMPTS
        NOTIFICATION_RECOVERY_CONFIRM_RUNS

    )
    local -a ordered_pairs=(

        WARN_THRESHOLD_PERCENT:CRITICAL_THRESHOLD_PERCENT
        IO_ERROR_WARN_THRESHOLD:IO_ERROR_CRIT_THRESHOLD
        PARITY_SYNC_ERR_WARN:PARITY_SYNC_ERR_CRIT
        SATA_LINK_INSTABILITY_STREAK_WARN:SATA_LINK_INSTABILITY_STREAK_CRIT
        FORECAST_MIN_SAMPLES:FORECAST_HIGH_SAMPLES
        FORECAST_MIN_SPAN_DAYS:FORECAST_HIGH_SPAN_DAYS
        RELOC_WARNING:RELOC_CRITICAL CMD_TIMEOUT_WARN:CMD_TIMEOUT_CRIT
        REALLOC_EVENT_WARN:REALLOC_EVENT_CRIT SSD_TEMP_WARNING:SSD_TEMP_CRITICAL
        HDD_TEMP_WARNING:HDD_TEMP_CRITICAL LOAD_CYCLE_WARN:LOAD_CYCLE_CRIT
         NVME_TEMP_WARNING:NVME_TEMP_CRITICAL
        NVME_PERCENT_USED_WARN:NVME_PERCENT_USED_CRIT

        NVME_ERR_LOG_DELTA_WARN:NVME_ERR_LOG_DELTA_CRIT
        NVME_PCIE_CORR_DELTA_WARN:NVME_PCIE_CORR_DELTA_CRIT
        NVME_PCIE_UNC_DELTA_WARN:NVME_PCIE_UNC_DELTA_CRIT
        BTRFS_DEV_ERR_WARN_DELTA:BTRFS_DEV_ERR_CRIT_DELTA
        BTRFS_DEV_CORR_WARN_DELTA:BTRFS_DEV_CORR_CRIT_DELTA
        BTRFS_ERR_BURST_WARN_RATIO:BTRFS_ERR_BURST_CRIT_RATIO

        BURST_WARN_BOOST:BURST_CRIT_BOOST

        TBW_CONSUMED_WARN:TBW_CONSUMED_CRIT
        NOTIFICATION_RETRY_INITIAL_DELAY_SECONDS:NOTIFICATION_RETRY_MAX_DELAY_SECONDS
    )

    if (( EXTERNAL_CONFIG_LOAD_FAILED == 1 )); then
        configuration_error \
            "External configuration is $EXTERNAL_CONFIG_STATUS: $EXTERNAL_CONFIG_DETAIL"
    fi

    for setting in "${boolean_settings[@]}"; do
        validate_boolean_setting "$setting"
    done
    for setting in "${integer_settings[@]}"; do
        validate_nonnegative_integer_setting "$setting"
    done
    for setting in "${number_settings[@]}"; do
        validate_nonnegative_number_setting "$setting"
    done
    for setting in "${percent_settings[@]}"; do
        validate_percent_setting "$setting"
    done
    for setting in "${positive_integer_settings[@]}"; do
        validate_positive_integer_setting "$setting"
    done
    for pair in "${ordered_pairs[@]}"; do
        validate_ordered_pair "${pair%%:*}" "${pair#*:}"
    done

    validate_absolute_path_setting LOG_DIR
    validate_absolute_path_setting LOCK_FILE
    validate_absolute_path_setting NOTIFY_BIN
    validate_absolute_path_setting IO_ERROR_LOG_FILE

    [[ -z "${LONG_TEST_DECISION:-}" ]] ||
        configuration_error "LONG_TEST_DECISION is runtime state and must start empty"

    if [[ "${HISTORY_SCHEMA_VERSION:-}" =~ ^[0-9]+$ ]] &&
       (( HISTORY_SCHEMA_VERSION != 3 ))
    then
        configuration_error "HISTORY_SCHEMA_VERSION must remain 3 for this script version"
    fi
    if [[ "${THRESHOLD:-}" =~ ^[0-9]+$ ]] && (( THRESHOLD == 0 )); then
        configuration_error "THRESHOLD must be greater than zero"
    fi
    if [[ "${HEAVY_WRITER_RECENT_DAYS:-}" =~ ^[0-9]+$ &&
          "${HISTORY_WINDOW_DAYS:-}" =~ ^[0-9]+$ ]] &&
       (( HEAVY_WRITER_RECENT_DAYS * 2 > HISTORY_WINDOW_DAYS ))
    then
        configuration_error \
            "HISTORY_WINDOW_DAYS must cover two HEAVY_WRITER_RECENT_DAYS windows"
    fi
    if [[ "${HEAVY_WRITER_MIN_RECENT_SAMPLES:-}" =~ ^[0-9]+$ &&
          "${HEAVY_WRITER_RECENT_DAYS:-}" =~ ^[0-9]+$ ]] &&
       (( HEAVY_WRITER_MIN_RECENT_SAMPLES > HEAVY_WRITER_RECENT_DAYS + 1 ))
    then
        configuration_error \
            "HEAVY_WRITER_MIN_RECENT_SAMPLES exceeds the expected daily samples in its window"
    fi
    if [[ "${NOTIFY_MAX_BODY_CHARS:-}" =~ ^[0-9]+$ ]] &&
       (( NOTIFY_MAX_BODY_CHARS < 512 ))
    then
        configuration_error "NOTIFY_MAX_BODY_CHARS must be at least 512"
    fi
    if [[ "${NOTIFY_MAX_BODY_LINES:-}" =~ ^[0-9]+$ ]] &&
       (( NOTIFY_MAX_BODY_LINES < 20 ))
    then
        configuration_error "NOTIFY_MAX_BODY_LINES must be at least 20"
    fi

    if ! declare -p POOL_EXCLUDES 2>/dev/null | grep -q '^declare -a'; then
        configuration_error "POOL_EXCLUDES must be an indexed Bash array"
    else
        for excluded_pool in "${POOL_EXCLUDES[@]}"; do
            if [[ -z "$excluded_pool" || "$excluded_pool" == */* ]]; then
                configuration_error \
                    "POOL_EXCLUDES entries must be non-empty pool names without '/': '$excluded_pool'"
            fi
        done
    fi

    validate_model_rule_block TBW_MODEL_RULES tbw

    if [[ "${ENABLE_BTRFS_SCRUB:-}" == "0" && "${FIRST_RUN_FORCE:-}" == "1" ]]; then
        configuration_warning \
            "FIRST_RUN_FORCE=1 may start a one-time baseline Btrfs scrub even though ENABLE_BTRFS_SCRUB=0"
    fi

    if (( CONFIG_ERROR_COUNT > 0 )); then
        log "CONFIG" "ERROR" \
            "Configuration validation failed with $CONFIG_ERROR_COUNT error(s) and $CONFIG_WARNING_COUNT warning(s)"
        return 1
    fi
    log "CONFIG" "INFO" \
        "Configuration validation passed with $CONFIG_WARNING_COUNT warning(s)"
    return 0
}

dependency_error() {
    DEPENDENCY_ERROR_COUNT=$((DEPENDENCY_ERROR_COUNT + 1))
    log "DEPENDENCY" "ERROR" "$*"
}

dependency_warning() {
    DEPENDENCY_WARNING_COUNT=$((DEPENDENCY_WARNING_COUNT + 1))
    log "DEPENDENCY" "WARN" "$*"
}

validate_runtime_dependencies() {
    local mode="${1:-monitor}" command_name
    local -a required_commands=()

    DEPENDENCY_ERROR_COUNT=0
    DEPENDENCY_WARNING_COUNT=0

    case "$mode" in
        self-test)
            required_commands=(
                awk chmod chown cp cut date find flock grep jq ln mkdir mktemp mv rm sed
                sha1sum sleep sort stat timeout tr wc
            )
            ;;
        notification-test)
            required_commands=(awk chmod chown date flock grep sed sleep stat timeout)
            ;;
        state-admin)
            required_commands=(
                awk chmod chown cp date find flock grep mkdir mktemp mv rm sed sort
                stat wc
            )
            ;;
        *)
            required_commands=(
                awk basename cat chmod chown cksum cp cut date df dirname find findmnt
                flock grep head jq lsblk mkdir mktemp mount mountpoint mv readlink rm
                sed sha1sum sleep smartctl sort stat tail timeout tr wc
            )
            ;;
    esac

    for command_name in "${required_commands[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 ||
            dependency_error "Required command is unavailable: $command_name"
    done

    if command -v timeout >/dev/null 2>&1 &&
       ! timeout --signal=TERM --kill-after=1s 1s sleep 0 >/dev/null 2>&1
    then
        dependency_error "GNU-compatible timeout with --kill-after support is required"
    fi

    if [[ "$mode" == "monitor" || "$mode" == "diagnostics" ]]; then
        if [[ "${ENABLE_BTRFS_SCRUB:-0}" == "1" ||
              "${FIRST_RUN_FORCE:-0}" == "1" ||
              "${ENABLE_BTRFS_DEVICE_STATS:-0}" == "1" ]] &&
           ! command -v btrfs >/dev/null 2>&1
        then
            dependency_error "btrfs is required by the enabled Btrfs monitoring settings"
        fi
        command -v hdparm >/dev/null 2>&1 ||
            dependency_warning "hdparm is unavailable; standby detection will use smartctl -n"
        if command -v date >/dev/null 2>&1 &&
           [[ "$(date -d '1970-01-02 00:00:00 UTC' +%s 2>/dev/null || true)" != "86400" ]]
        then
            dependency_error "GNU-compatible date -d support is required"
        fi
        if command -v stat >/dev/null 2>&1 &&
           ! stat -c '%d %i %s' / >/dev/null 2>&1
        then
            dependency_error "GNU-compatible stat -c support is required"
        fi
        if command -v readlink >/dev/null 2>&1 &&
           [[ "$(readlink -f / 2>/dev/null || true)" != "/" ]]
        then
            dependency_error "readlink -f support is required"
        fi
        if command -v find >/dev/null 2>&1 &&
           ! find /tmp -maxdepth 0 -printf '' >/dev/null 2>&1
        then
            dependency_error "GNU-compatible find -printf support is required"
        fi
    fi

    if [[ "$mode" == "monitor" || "$mode" == "diagnostics" ||
          "$mode" == "notification-test" ]] &&
       [[ ! -x "$NOTIFY_BIN" ]]
    then
        dependency_warning \
            "Unraid notification helper is unavailable; logger is observability-only and cannot confirm delivery"
    fi

    if (( DEPENDENCY_ERROR_COUNT > 0 )); then
        log "DEPENDENCY" "ERROR" \
            "Dependency validation failed with $DEPENDENCY_ERROR_COUNT error(s) and $DEPENDENCY_WARNING_COUNT warning(s)"
        return 1
    fi
    log "DEPENDENCY" "INFO" \
        "Dependency validation passed with $DEPENDENCY_WARNING_COUNT warning(s)"
    return 0
}

print_usage() {
    printf 'Disk Health Monitor for Unraid v%s\n\n' "$SCRIPT_VERSION"
    cat <<'USAGE'
Usage:
  health_monitoring.sh                 Run normal monitoring
  health_monitoring.sh --check-config  Validate configuration only
  health_monitoring.sh --state-status  Inspect state-schema compatibility
  health_monitoring.sh --state-backups List migration and rollback backups
  health_monitoring.sh --rollback-state BACKUP_ID
                                       Restore one explicit state backup and exit
  health_monitoring.sh --diagnostics   Run read-only environment diagnostics
  health_monitoring.sh --self-test     Run tests/health_monitoring_test.sh from a full checkout
  health_monitoring.sh --test-notification
                                       Send one notification without monitoring or state changes
  health_monitoring.sh --notification-dry-run
                                       Run monitoring but skip delivery and notification-journal changes
  health_monitoring.sh --version       Print the script version
  health_monitoring.sh --help          Show this help

The configuration, state-status, state-backups, diagnostics and self-test
modes do not run SMART commands against disks, start tests or scrubs, write monitoring state,
advance the syslog cursor, send notifications, or spin up disks. The explicit
notification test sends only its fixed test message. Notification dry-run is a
normal monitoring run: only external delivery and notification-journal updates
are skipped. Rollback-state changes only the protected state directory after
creating a pre-rollback safety backup; it never runs monitoring.
USAGE
}

parse_arguments() {
    if (( $# > 2 )); then
        printf 'Too many arguments.\n' >&2
        return 2
    fi
    case "${1:-}" in
        "")
            (( $# == 0 )) || return 2
            RUN_MODE="monitor"
            ;;
        --check-config)
            (( $# == 1 )) || return 2
            RUN_MODE="check-config"
            ;;
        --state-status)
            (( $# == 1 )) || return 2
            RUN_MODE="state-status"
            ;;
        --state-backups)
            (( $# == 1 )) || return 2
            RUN_MODE="state-backups"
            ;;
        --rollback-state)
            if (( $# != 2 )); then
                printf '%s requires one BACKUP_ID.\n' "$1" >&2
                return 2
            fi
            RUN_MODE="rollback-state"
            ROLLBACK_BACKUP_ID="$2"
            ;;
        --diagnostics)
            (( $# == 1 )) || return 2
            RUN_MODE="diagnostics"
            ;;
        --self-test)
            (( $# == 1 )) || return 2
            RUN_MODE="self-test"
            ;;
        --test-notification)
            (( $# == 1 )) || return 2
            RUN_MODE="test-notification"
            ;;
        --notification-dry-run)
            (( $# == 1 )) || return 2
            RUN_MODE="monitor"
            NOTIFICATION_DRY_RUN=1
            ;;
        --version)
            (( $# == 1 )) || return 2
            RUN_MODE="version"
            ;;
        --help|-h)
            (( $# == 1 )) || return 2
            RUN_MODE="help"
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            print_usage >&2
            return 2
            ;;
    esac
}

diagnostic_result() {
    local level="$1" label="$2" detail="$3"
    printf '[%-4s] %-26s %s\n' "$level" "$label" "$detail"
}

nearest_existing_parent() {
    local path="$1" parent

    parent="$path"
    while [[ ! -e "$parent" && "$parent" != "/" ]]; do
        parent="$(dirname -- "$parent")"
    done
    [[ -d "$parent" ]] || return 1
    printf '%s\n' "$parent"
}

run_diagnostics() {
    local failures=0 warnings=0 config_status=0 dependency_status=0 state_status=0
    local parent device_rows

    printf 'Disk Health Monitor for Unraid v%s - read-only diagnostics\n' \
        "$SCRIPT_VERSION"
    printf 'No disk SMART reads, tests, scrubs, state writes, cursor updates, or notifications will occur.\n\n'

    if validate_configuration; then
        diagnostic_result PASS "Configuration" "valid ($CONFIG_WARNING_COUNT warning(s))"
    else
        config_status=1
        failures=$((failures + 1))
        diagnostic_result FAIL "Configuration" "$CONFIG_ERROR_COUNT error(s)"
    fi

    if validate_runtime_dependencies diagnostics; then
        diagnostic_result PASS "Dependencies" "available ($DEPENDENCY_WARNING_COUNT warning(s))"
    else
        dependency_status=1
        failures=$((failures + 1))
        diagnostic_result FAIL "Dependencies" "$DEPENDENCY_ERROR_COUNT error(s)"
    fi

    diagnostic_result INFO "Bash" "$BASH_VERSION"
    diagnostic_result INFO "Kernel" "$(uname -sr 2>/dev/null || printf 'unknown')"
    diagnostic_result INFO "Command deadlines" \
        "SMART=${SMARTCTL_TIMEOUT_SECONDS}s Btrfs=${BTRFS_COMMAND_TIMEOUT_SECONDS}s System=${SYSTEM_COMMAND_TIMEOUT_SECONDS}s Notify=${NOTIFICATION_TIMEOUT_SECONDS}s"
    diagnostic_result INFO "Regression fixtures" "run tests/health_monitoring_test.sh from the repository"

    if inspect_state_schema_manifest; then
        diagnostic_result PASS "State schema" "$STATE_SCHEMA_DETAIL"
    else
        state_status=$?
        case "$state_status" in
            10)
                diagnostic_result INFO "State schema" \
                    "uninitialized; v${SCRIPT_VERSION} will register existing state on the first monitoring run"
                ;;
            *)
                failures=$((failures + 1))
                diagnostic_result FAIL "State schema" \
                    "$STATE_SCHEMA_STATUS: $STATE_SCHEMA_DETAIL"
                ;;
        esac
    fi

    if [[ -d "$LOG_DIR" ]]; then
        if [[ -w "$LOG_DIR" ]]; then
            diagnostic_result PASS "Log directory" "$LOG_DIR is writable"
        else
            failures=$((failures + 1))
            diagnostic_result FAIL "Log directory" "$LOG_DIR is not writable"
        fi
    else
        parent=$(nearest_existing_parent "$LOG_DIR" 2>/dev/null || true)
        if [[ -n "$parent" && -w "$parent" ]]; then
            diagnostic_result PASS "Log directory parent" "$parent can create $LOG_DIR"
        else
            failures=$((failures + 1))
            diagnostic_result FAIL "Log directory parent" "no writable parent for $LOG_DIR"
        fi
    fi

    parent="${LOCK_FILE%/*}"
    if validate_secure_owned_directory "$parent" &&
       { [[ ! -e "$LOCK_FILE" && ! -L "$LOCK_FILE" ]] ||
         validate_secure_owned_file "$LOCK_FILE"; }
    then
        diagnostic_result PASS "Secure lock path" "$LOCK_FILE"
    else
        failures=$((failures + 1))
        diagnostic_result FAIL "Secure lock path" "$PATH_VALIDATION_REASON"
    fi

    case "$EXTERNAL_CONFIG_STATUS" in
        LOADED)
            diagnostic_result PASS "External configuration" "$EXTERNAL_CONFIG_DETAIL"
            ;;
        ABSENT)
            diagnostic_result INFO "External configuration" \
                "$EXTERNAL_CONFIG_DETAIL; $EXTERNAL_CONFIG_FILE will be created on the next monitoring run"
            ;;
        *)
            diagnostic_result FAIL "External configuration" "$EXTERNAL_CONFIG_DETAIL"
            ;;
    esac

    if [[ -x "$NOTIFY_BIN" ]]; then
        diagnostic_result PASS "Unraid notification" "$NOTIFY_BIN is executable"
    elif command -v logger >/dev/null 2>&1; then
        warnings=$((warnings + 1))
        diagnostic_result WARN "Unraid notification" \
            "notify helper missing; logger fallback is observability-only"
    else
        warnings=$((warnings + 1))
        diagnostic_result WARN "Unraid notification" "notify helper and logger are unavailable"
    fi

    if [[ -r "$IO_ERROR_LOG_FILE" ]]; then
        diagnostic_result PASS "Syslog source" "$IO_ERROR_LOG_FILE is readable"
    else
        warnings=$((warnings + 1))
        diagnostic_result WARN "Syslog source" "$IO_ERROR_LOG_FILE unavailable; dmesg fallback will be used"
    fi

    if [[ -r /var/local/emhttp/disks.ini && -r /var/local/emhttp/var.ini ]]; then
        diagnostic_result PASS "Unraid metadata" "disks.ini and var.ini are readable"
    else
        warnings=$((warnings + 1))
        diagnostic_result WARN "Unraid metadata" "one or more /var/local/emhttp metadata files are unavailable"
    fi

    if mountpoint -q /mnt/user 2>/dev/null; then
        diagnostic_result PASS "Unraid user share" "/mnt/user is mounted"
    else
        warnings=$((warnings + 1))
        diagnostic_result WARN "Unraid user share" "/mnt/user is not mounted"
    fi

    device_rows=$(lsblk_bounded -b -dn -o NAME,SIZE,ROTA,TYPE 2>/dev/null |
        awk '$4=="disk" && ($1 ~ /^sd[a-z]+$/ || $1 ~ /^nvme[0-9]+n[0-9]+$/) {count++} END {print count+0}')
    diagnostic_result INFO "Block-device inventory" "${device_rows:-0} candidate disk(s), read from lsblk only"

    printf '\nDiagnostic summary: failures=%d warnings=%d config_status=%d dependency_status=%d\n' \
        "$failures" "$((warnings + CONFIG_WARNING_COUNT + DEPENDENCY_WARNING_COUNT))" \
        "$config_status" "$dependency_status"
    (( failures == 0 ))
}

# Collector bundles keep dependencies and persistence gates aligned while
# allowing the orchestrator to continue after non-fatal subsystem failures.
collector_step() {
    local label="$1"
    shift
    local rc

    if "$@"; then
        rc=0
    else
        rc=$?
    fi
    (( rc == 0 )) && return 0
    record_collector_event FAILED "$label" "collector_step_rc=$rc"
    return 0
}

# These bundles are callbacks dispatched by run_collector through "$@".
# Keep SC2329 local so genuinely unreachable functions elsewhere remain visible.
# shellcheck disable=SC2329
collect_inventory_phase() {
    cache_lsblk_all
    discover_device_inventory || return 1
    if collector_current_state_writable; then
        migrate_device_identity_histories || true
    else
        log "STATE" "WARN" \
            "Deferred stable-identity migration because inventory collection was incomplete"
    fi
    load_persistent_state || return 1
    parity_state || true
    build_mount_device_map
}

# shellcheck disable=SC2329
collect_btrfs_filesystem_phase() {
    collector_step "Btrfs scrub status" monitor_btrfs
    return 0
}

# shellcheck disable=SC2329
collect_capacity_phase() {
    collector_step "Assigned storage" check_expected_storage
    if [[ "$ARRAY_RUNTIME_STATE" == stopped ]]; then
        STORAGE_TOP_LINES="Array: stopped; mounted storage coverage deferred."
        return 0
    fi
    collector_step "Storage utilization" collect_storage_usage
    collector_step "Capacity thresholds" evaluate_capacity_alerts
    collector_step "Parity status" evaluate_live_parity
    collector_step "Completed parity history" check_completed_parity /boot/config/parity-checks.log
    return 0
}

# shellcheck disable=SC2329

# shellcheck disable=SC2329
collect_endurance_phase() {
    collector_step "Host-write rates" collect_write_rates
    collector_step "Counter regression detection" detect_counter_resets
    return 0
}

run_notification_test() {
    local rc

    validate_configuration || return 1
    validate_runtime_dependencies notification-test || return 1
    acquire_lock || return 1

    printf 'Sending one Unraid notification test; no monitoring or state writes will occur.\n'
    if deliver_notification_with_retry \
        "Disk Health Monitor v${SCRIPT_VERSION} - Notification Test" \
        "Notification delivery test completed at $(date '+%Y-%m-%d %H:%M:%S').\nNo SMART reads, tests, scrubs, cursor updates, or monitoring-state writes were performed." \
        normal
    then
        printf 'Notification test delivered successfully in %d attempt(s).\n' \
            "$NOTIFICATION_DELIVERY_ATTEMPTS"
        return 0
    else
        rc=$?
        printf 'Notification test failed after %d attempt(s), exit=%d.\n' \
            "$NOTIFICATION_DELIVERY_ATTEMPTS" "$rc" >&2
        return "$rc"
    fi
}

main() {
    local exit_code previous_complete

    parse_arguments "$@" || return $?
    case "$RUN_MODE" in
        help)
            print_usage
            return 0
            ;;
        version)
            printf 'Disk Health Monitor for Unraid v%s\n' "$SCRIPT_VERSION"
            return 0
            ;;
        check-config)
            if validate_configuration; then
                printf 'Configuration is valid (%d warning(s)).\n' "$CONFIG_WARNING_COUNT"
                # Fixture mutations occur only inside the self-test subshell.
                # shellcheck disable=SC2031
                printf 'External configuration: %s (%s; %d override(s))\n' \
                    "$EXTERNAL_CONFIG_FILE" "$EXTERNAL_CONFIG_STATUS" \
                    "$EXTERNAL_CONFIG_OVERRIDE_COUNT"
                return 0
            fi
            return 1
            ;;
        state-status)
            validate_configuration || return 1
            print_state_schema_status
            return $?
            ;;
        state-backups)
            validate_runtime_dependencies state-admin || return 1
            list_state_backups
            return $?
            ;;
        rollback-state)
            validate_runtime_dependencies state-admin || return 1
            acquire_lock || return 1
            rollback_state_backup "$ROLLBACK_BACKUP_ID"
            return $?
            ;;
        diagnostics)
            run_diagnostics
            return $?
            ;;
        self-test)
            local test_suite
            test_suite="$(dirname -- "${BASH_SOURCE[0]}")/../tests/health_monitoring_test.sh"
            if [[ "${BASH_SOURCE[0]##*/}" != health_monitoring.sh || ! -f "$test_suite" ]]; then
                printf '%s\n' 'Regression fixtures are packaged in the repository. Run bash tests/health_monitoring_test.sh from a checkout; use --diagnostics for the installed monitor.' >&2
                return 2
            fi
            bash "$test_suite"
            return $?
            ;;
        test-notification)
            run_notification_test
            return $?
            ;;
    esac

    # Normal monitoring validates everything before acquiring the lock or
    # creating logs/state. A configuration failure therefore has no persistent
    # side effects.
    validate_configuration || return 1
    validate_runtime_dependencies monitor || return 1

    acquire_lock || {
        exit_code=$?
        (( exit_code != 75 )) || return 0
        return "$exit_code"
    }

    trap 'exit_code=$?; cleanup "$exit_code"; exit $?' EXIT
    trap 'handle_signal INT' INT
    trap 'handle_signal TERM' TERM

    initialize_runtime || return 1
    # shellcheck disable=SC2031
    previous_complete=$(sed -nE 's/.*"lastCompleteEpoch":([0-9]{1,12}),.*/\1/p' "$MONITOR_RECEIPT_FILE")
    # shellcheck disable=SC2031
    if [[ "$previous_complete" =~ ^(0|[1-9][0-9]{0,11})$ ]] && (( previous_complete <= RUN_EPOCH )); then
        MONITOR_LAST_COMPLETE_EPOCH="$previous_complete"
    fi
    write_monitor_receipt running 0 || return 1

    log "RUN" "INFO" "Starting Unraid disk health monitoring"

    run_collector inventory "Device inventory" collect_inventory_phase
    if (( LAST_COLLECTOR_RC != 0 || DEVICE_INVENTORY_READY != 1 )); then
        log "RUN" "ERROR" "Device inventory is unavailable; monitoring cannot continue safely"
        return 1
    fi

    # Fixture mutations occur only inside the self-test subshell.
    # shellcheck disable=SC2031
    log "SMART" "INFO" \
        "Collecting SMART health (short-test interval=${SHORT_TEST_INTERVAL_DAYS}d, automatic spin-up=${SMART_ALLOW_SPINUP})"
    run_collector smart "SMART/NVMe health" collector_step "SMART/NVMe collection" collect_smart_health

    log "BTRFS" "INFO" "Assessing scrub status"
    run_collector btrfs_filesystem "Btrfs scrub status" collect_btrfs_filesystem_phase

    log "CAPACITY" "INFO" "Collecting array, pool, and disk utilization"
    run_collector capacity "Capacity and parity" collect_capacity_phase

    log "BTRFS" "INFO" "Collecting non-destructive device statistics"
    run_collector btrfs_devices "Btrfs device counters" collector_step "Btrfs device counters" collect_btrfs_device_stats

    log "IO" "INFO" "Checking syslog-watchdog freshness and storage-error fallback"
    run_collector syslog_io "Syslog I/O scan" collector_step "Syslog I/O scan" scan_syslog_disk_errors

    log "ENDURANCE" "INFO" "Updating measured host-write history and rates"
    run_collector endurance "Host-write history" collect_endurance_phase

    # Trend analysis can raise findings, so it must complete before canonical
    # lifecycle classification, and alert rendering.
    log "TREND" "INFO" "Compiling trend analytics"
    run_collector trends "Trend analytics" collector_step "Trend analytics" build_trend_section

    run_collector state "Essential state" persist_all_state
    finalize_finding_counts

    log "REPORT" "INFO" "Finalizing canonical alert and status sections"
    build_health_alerts
    exit_code=0
    prepare_notification_lifecycle || exit_code=1
    build_subject
    compose_notification

    # ShellCheck sees the isolated self-test subshell's assignment above; the
    # production lifecycle decision is set in this main shell.
    # shellcheck disable=SC2031
    log "NOTIFY" "INFO" \
        "Processing consolidated notification (decision=$NOTIFICATION_DECISION, severity=$FINAL_NOTIFICATION_SEVERITY, critical=$FINDING_CRITICAL_COUNT, warning=$FINDING_WARNING_COUNT, resolved=$NOTIFICATION_RESOLVED_COUNT)"
    # Notification composition is intentionally performed in the main shell;
    # ShellCheck cannot infer that through every helper call above.
    # shellcheck disable=SC2031
    process_notification_delivery \
        "${SUBJECT:-Disk Health Summary}" \
        "$NOTIFY_BODY" \
        "$FINAL_NOTIFICATION_SEVERITY" || exit_code=1

    # Keep unread events retryable when delivery or its journal write failed.
    if (( exit_code == 0 && NOTIFICATION_DRY_RUN == 0 )) &&
       collector_status_is_safe syslog_io; then
        commit_syslog_cursor || exit_code=1
    fi
    prune_history_files
    prune_old_run_logs

    if (( exit_code == 0 )) && all_collectors_state_safe; then
        RUN_COMPLETION_READY=1
    else
        exit_code=1
    fi
    return "$exit_code"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if harden_existing_external_config_path; then
        load_external_configuration || true
    else
        EXTERNAL_CONFIG_STATUS="UNSAFE"
        EXTERNAL_CONFIG_DETAIL="$PATH_VALIDATION_REASON"
        EXTERNAL_CONFIG_LOAD_FAILED=1
        external_config_log ERROR \
            "Unable to secure external configuration $EXTERNAL_CONFIG_FILE: $EXTERNAL_CONFIG_DETAIL"
    fi
    main "$@"
fi
