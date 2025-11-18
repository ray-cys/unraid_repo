#!/bin/bash
set -euo pipefail
set -E
trap 'log_crit "Script aborted at line ${LINENO} (status=$?): in ${FUNCNAME[*]:-main}"' ERR
LOCKFILE="/tmp/health_monitoring.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Another run health_monitoring.sh active, exiting (lock: $LOCKFILE)" >&2
    exit 1
fi

# Disk Health Monitor for Unraid
# Purpose: Run SMART tests, parse SMART/NVMe attributes, track endurance & risk, capture filesystem health,
# evaluate capacity growth, detect firmware/regression events, surface I/O error frequency, and emit concise
# notifications + JSON summary for automation.

# ---------------- Configuration ----------------
# Storage health script settings. Conservatively tuned for performance and reliability.

# === SMART Test Scheduling ===
SMART_TEST_TYPE="short"       # SMART test type to run: short|long
SMART_INTERVAL_DAYS=30        # Minimum days between long tests per disk
SHORT_TEST_POLL=1             # If 1, poll short test until it completes
SHORT_TEST_MAX_WAIT=180       # Max seconds to wait while polling short tests
SHORT_TEST_POLL_INTERVAL=10   # Interval between polls (seconds)
ADAPTIVE_LONG_TEST_ENABLED=1  # Enable adaptive long test scheduling
LONG_TEST_RISK_THRESHOLD=50   # Risk score >= triggers long test escalation
LONG_TEST_CRITICAL_MIN_DAYS=7 # Critical SMART & last long > days -> force long
LONG_TEST_RISK_MIN_DAYS=0     # Min days since last long for risk-based escalation
ADAPTIVE_ALERTS_ENABLED=1     # Emit alert entries for adaptive escalations

# === Capacity Thresholds ===
WARN_THRESHOLD_PERCENT=96     # Per-disk usage percent -> warning
CRITICAL_THRESHOLD_PERCENT=98 # Per-disk usage percent -> critical
THRESHOLD=90                  # Array/pools overall usage percent considered full
NEAR_THRESHOLD_DELTA=5        # "Near full" if within this percent of THRESHOLD
POOL_EXCLUDES=("ramtmp" "user0") # Pool names excluded from pool totals
FORECAST_RECOMMEND_DAYS=14     # Days-to-threshold <= triggers expansion recommendation

# === Filesystem / Device Monitoring Toggles ===
ENABLE_BTRFS_SCRUB=0          # Start btrfs scrub vs just parse last status
ENABLE_BTRFS_DEVICE_STATS=1   # Parse btrfs per-device stats and integrate
BTRFS_DEV_TREND_ENABLED=1     # Persist & render per-device btrfs error trends
BTRFS_TREND_TOP_N=5           # Top N devices by error delta
BTRFS_TREND_WINDOW_DAYS=7     # Window for btrfs device trend aggregation
ENABLE_XFS_CHECK=0            # Run xfs_repair -n metadata check
ENABLE_XFS_PROC_STATS=1       # Parse /proc/fs/xfs/stat counters
IO_ERROR_MONITOR_ENABLED=1    # Enable syslog scanning for disk I/O frequency
IO_ERROR_LOG_FILE="/var/log/syslog" # Syslog path fallback to dmesg
IO_ERROR_WINDOW_MINUTES=60    # Time window (minutes) for de-dup/frequency
IO_ERROR_WARN_THRESHOLD=5     # Unique error events >= warning
IO_ERROR_CRIT_THRESHOLD=20    # Unique error events >= critical
IO_ERROR_DEDUP_ENABLED=1      # De-duplicate identical message hashes inside window

# === SMART / Endurance / Trend Toggles ===
ENABLE_POOL_DEVICE_SMART=1    # Include per-device SMART lines for pools
PARITY_SUGGEST_ENABLED=1      # Evaluate SMART deltas to suggest parity check
SMART_TREND_ALERTS_ENABLED=1  # Emit warning alerts for SMART trend increases
AGE_AWARE_ENABLED=1           # Annotate near-endurance devices
NVME_WEAR_REGRESSION_WARN=1   # Flag any NVMe Percentage Used regression
POH_RESET_CRIT_THRESHOLD=500  # POH drop > threshold -> critical reset event

# === Export / History Toggles ===
JSON_EXPORT=1                 # Write JSON summary to disk
JSON_INCLUDE_DISKS=1          # Include per-disk details (POH/endurance)
HISTORY_WINDOW_DAYS=7         # Days considered for usage growth trends
DYNAMIC_GROWTH=1              # Use first vs last sample over actual elapsed days
SHARE_BREAKDOWN_ENABLED=0     # Compute per-share usage (heavy)
SHARE_TOP_N=5                 # Top N shares by size/growth
LOG_PRUNE_ENABLED=1           # Prune old run logs in LOG_DIR
LOG_MAX_DAYS=0                # Age pruning days (0=disable)
LOG_MAX_COUNT=3               # Max retained logs per pattern (0=disable)
LOG_MIRROR_STDOUT=1           # Echo log lines to stdout

# === Risk / Lifecycle Toggles ===
RISK_SCORING_ENABLED=1        # Show risk scores section
LIFECYCLE_ENABLED=1           # Show lifecycle buckets
LIFECYCLE_RECOMMEND_TOP_N=3   # Max devices listed in lifecycle recommendations
RISK_TREND_REPLACE_DELTA_MIN=1 # Replace-tier increase delta for recommendation
RISK_TREND_MONITOR_DELTA_MIN=2 # Monitor-tier increase delta for recommendation
RISK_TOP_N=5                  # Entries shown in Risk Scores (top list)
RISK_REPLACE=80               # Score >= goes to Replace Soon bucket
RISK_MONITOR=50               # Score >= goes to Monitor bucket

# === Forecast / Display Toggles ===
FORECAST_HIDE_ZERO_GROWTH=1   # Hide lines showing ~0% growth
FORECAST_DECIMALS=1           # Decimals for average growth percent
FORECAST_MIN_VISIBLE=0.1      # Percent below which show ~0% label
FORECAST_ZERO_LABEL="~0%"     # Label for very small growth percentages
SHOW_SUBSYSTEMS_BLOCK="auto"  # Subsystems block policy: auto|always|never
SHOW_OK_SUBSYSTEMS=0          # Hide OK subsystems if any WARN/CRIT exist
SHOW_DISABLED_SUBSYSTEMS=0    # Hide Disabled subsystems in description/body
SHOW_EMPTY_BUCKETS=0          # Hide empty lifecycle buckets
VERBOSE_OK=1                  # Show OK lines (0 suppresses)
SHOW_ZERO_COUNTS=0            # Hide zero-count summary lines unless 1

# === SMART Thresholds (SATA) ===
RELOC_WARNING=1               # Reallocated sectors >= warning
RELOC_CRITICAL=10             # Reallocated sectors >= critical
PEND_WARNING=1                # Pending sectors >= critical
SSD_TEMP_WARNING=65           # SATA SSD temp C >= warning
SSD_TEMP_CRITICAL=70          # SATA SSD temp C >= critical
HDD_TEMP_WARNING=50           # HDD temp C >= warning
HDD_TEMP_CRITICAL=60          # HDD temp C >= critical
LOAD_CYCLE_WARN=300000        # HDD load cycle count >= warning
LOAD_CYCLE_CRIT=600000        # HDD load cycle count >= critical
SSD_WEAR_WARN=20              # SSD life remaining (%) <= warning
SSD_WEAR_CRIT=10              # SSD life remaining (%) <= critical
REPORTED_UNC_CRIT=1           # SATA attr 187 any >0 critical
CMD_TIMEOUT_WARN=1            # SATA attr 188 >= warning
CMD_TIMEOUT_CRIT=50           # SATA attr 188 >= critical
REALLOC_EVENT_WARN=1          # SATA attr 196 >= warning
REALLOC_EVENT_CRIT=10         # SATA attr 196 >= critical
END_TO_END_ERR_CRIT=1         # SATA attr 184 any >0 critical
SOFT_READ_ERR_WARN=1000       # SATA attr 201 >= warning (heuristic)

# === SMART Thresholds (NVMe) ===
NVME_TEMP_WARNING=65          # NVMe temp C >= warning
NVME_TEMP_CRITICAL=75         # NVMe temp C >= critical
NVME_PERCENT_USED_WARN=80     # NVMe wear percent >= warning
NVME_PERCENT_USED_CRIT=90     # NVMe wear percent >= critical
UNSAFE_SDWN_DELTA_WARN=1      # Unsafe shutdowns delta >= warning
NVME_AVAIL_SPARE_WARN=5       # Available Spare (%) below -> warning

# === Btrfs / XFS Snapshot & Device Thresholds ===
SNAPSHOT_WARN=100             # btrfs snapshot count >= warning
SNAPSHOT_CRIT=500             # btrfs snapshot count >= critical
BTRFS_DEV_ERR_WARN_DELTA=1    # Per-device read/write/flush err delta >= warning
BTRFS_DEV_ERR_CRIT_DELTA=10   # Per-device read/write/flush err delta >= critical
BTRFS_DEV_CORR_WARN_DELTA=1   # Per-device corruption/gen err delta >= warning
BTRFS_DEV_CORR_CRIT_DELTA=1   # Per-device corruption/gen err delta >= critical
XFS_PROC_WARN_DELTA=1         # xfs stat failure counter delta >= warning
XFS_PROC_CRIT_DELTA=5         # xfs stat failure counter delta >= critical

# === POH (Power-On Hours) Age Thresholds ===
HDD_POH_WARN_HOURS=50000      # HDD warn
HDD_POH_CRIT_HOURS=70000      # HDD critical
SSD_POH_WARN_HOURS=6000       # SATA SSD warn
SSD_POH_CRIT_HOURS=10000      # SATA SSD critical
NVME_POH_WARN_HOURS=4000      # NVMe warn
NVME_POH_CRIT_HOURS=6000      # NVMe critical

# === TBW / Endurance Forecast Thresholds ===
TBW_DAYS_WARN=14              # Remaining TBW forecast days < warning
TBW_DAYS_CRIT=3               # Remaining TBW forecast days < critical
TBW_WARN_TB=480               # Fallback TBW absolute threshold (TB)
TBW_CONSUMED_WARN=80          # Consumed percent of model TBW >= warning
TBW_CONSUMED_CRIT=95          # Consumed percent of model TBW >= critical

# === SMART Trend / Parity Suggestion Thresholds ===
PARITY_PENDING_MIN_DELTA=1    # Pending sectors increase >= suggestion
PARITY_REALLOC_MIN_DELTA=1    # Reallocated sectors increase >= suggestion
PARITY_REALLOC_EVT_MIN_DELTA=1 # Reallocation events increase >= suggestion
PARITY_UNC_MIN_DELTA=1        # Offline/reported uncorrectables increase >= suggestion

# === Risk Scoring Weights ===
W_SEV_CRIT=70                 # Base score for CRITICAL devices
W_SEV_WARN=30                 # Base score for WARNING devices
W_PENDING=40                  # Pending sectors weight
W_UNCORR=50                   # Uncorrectables weight
W_REALLOC=15                  # Reallocated sectors present
W_REALLOC_EVENTS=10           # Reallocation events weight
W_CMD_TIMEOUT=10              # Command timeouts weight
W_CRC=5                       # UDMA CRC errors weight
W_SSD_LIFE=20                 # Low SSD life remaining weight
W_NVME_WEAR=20                # High NVMe wear weight
W_TEMP=10                     # High temperature weight
W_E2E=40                      # End-to-End errors weight
W_SOFT_READ=10                # Soft read error rate weight
W_NVME_RO=80                  # NVMe read-only mode weight
W_NVME_REL=60                 # NVMe reliability degraded weight
W_AGE_NEAR=30                 # Near endurance extra weight
W_POH_HDD=10                  # High HDD POH age weight
W_POH_SSD=10                  # High SATA SSD POH age weight
W_POH_NVME=10                 # High NVMe POH age weight
W_BTRFS_DEV_ERR=15            # Btrfs per-device I/O/corruption errors weight
W_XFS_META_ERR=15             # XFS metadata/stat anomalies weight
W_SATA_LINK_DOWN=10           # SATA negotiated link downshift weight
W_SELFTEST_CRIT=40            # SMART self-test critical result weight
W_SELFTEST_WARN=15            # SMART self-test warning/ambiguous result weight
W_TBW_CONS_WARN=10            # TBW consumed over warn threshold
W_TBW_CONS_CRIT=25            # TBW consumed over critical threshold

# === Internals (do not modify unless needed) ===
ALERT_WARN=()                 # Accumulator for warning messages
ALERT_CRIT=()                 # Accumulator for critical messages
declare -A SMART_STATE        # Map device -> OK/WARNING/CRITICAL
declare -A SMART_MSGS         # Map device -> aggregated SMART message string
declare -A MOUNT_TO_DEV       # Map /mnt/diskX -> /dev/sdX|nvme
declare -A POOL_MEMBER_MAP    # Map base device (/dev/sdX|nvme0n1) -> pool name
declare -A MODEL_CACHE        # Base device -> model string
declare -A CAPACITY_CACHE     # Base device -> capacity TB (formatted numeric string)
declare -A SMART_RAW          # Base device -> cached SATA smartctl -A output
declare -A NVME_RAW           # Base device -> cached NVMe smartctl -a output
declare -A SMART_INFO         # Base device -> cached SATA smartctl -i output
declare -A TBW_DAILY_MAP      # Map device -> daily TBW bytes
declare -A TBW_DAYSLEFT_MAP   # Map device -> forecast days remaining
declare -A TBW_STATUS_MAP     # Map device -> TBW status (OK/WARNING/CRITICAL)
declare -A IO_ERROR_RAW_MAP   # Map device -> raw I/O error line count (duplicates included)
declare -A IO_ERROR_UNIQUE_MAP # Map device -> unique I/O error event count (dedup within window)
declare -A LAST_TEST          # Map device -> last SMART test timestamp
declare -A NVME_LAST_UNSAFE   # NVMe device -> last unsafe shutdown count
declare -A PREV_ATTR          # device|attr -> previous raw value
declare -A CUR_ATTR           # device|attr -> current raw value
declare -A NEW_SEEN           # Newly seen alerts/disks set

# === Runtime ===
SCRIPT_START_EPOCH=$(date +%s)

# === Adaptive Escalation Tracking ===
ADAPTIVE_DECISIONS=""
declare -A PREV_RISK

# === Logs Paths ===
LOG_DIR="/mnt/user/node/logs/disk_health"         # Base directory for logs files
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)                # Timestamp used for rotating log filenames
MASTER_LOG="$LOG_DIR/disk_health_$TIMESTAMP.log"  # Consolidated master log
SMART_LOG="$MASTER_LOG"
BTRFS_LOG="$MASTER_LOG"
XFS_LOG="$MASTER_LOG"
HEALTH_LOG_USER="${HEALTH_LOG_USER:-nobody}"      # Log file owner
HEALTH_LOG_GROUP="${HEALTH_LOG_GROUP:-users}"     # Log file group
HEALTH_DIR_MODE="${HEALTH_DIR_MODE:-0775}"        # Log directory permissions
HEALTH_FILE_MODE="${HEALTH_FILE_MODE:-0664}"      # Log file permissions
HEALTH_UMASK="${HEALTH_UMASK:-0002}"              # Log umask
umask "$HEALTH_UMASK"
chown "$HEALTH_LOG_USER:$HEALTH_LOG_GROUP" "$LOG_DIR" 2>/dev/null || true
chmod "$HEALTH_DIR_MODE" "$LOG_DIR" 2>/dev/null || true
: > "$MASTER_LOG" 2>/dev/null || true
chown "$HEALTH_LOG_USER:$HEALTH_LOG_GROUP" "$MASTER_LOG" 2>/dev/null || true
chmod "$HEALTH_FILE_MODE" "$MASTER_LOG" 2>/dev/null || true

# === Unified Logging ===
log_to() {
    local file="$1"; shift
    local msg="$*"
    if (( LOG_MIRROR_STDOUT == 1 )); then
        echo "$msg"
    fi
    echo "$msg" >> "$file"
}
# === Unified Subsystem ===
_subsys_emit() {
    local tag="$1"; shift
    local raw="$*"
    if [[ "$raw" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
        raw="$(echo "$raw" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} - //')"
    fi
    local ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[$tag] $ts - $raw"
    if (( LOG_MIRROR_STDOUT == 1 )); then echo "$line"; fi
    echo "$line" >> "$MASTER_LOG"
}
log_smart() { _subsys_emit SMART "$*"; }
log_btrfs() { _subsys_emit BTRFS "$*"; }
log_xfs()   { _subsys_emit XFS   "$*"; }

# === Severity (INFO/WARN/CRIT) ===
log_emit() {
    local sev="$1"; shift
    local msg="$*"
    local ts="$(date '+%Y-%m-%d %H:%M:%S')"
    if [[ "$msg" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
        msg="$(echo "$msg" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} - //')"
    fi
    local line="[${sev}] $ts - $msg"
    if (( LOG_MIRROR_STDOUT == 1 )); then echo "$line"; fi
    echo "$line" >> "$MASTER_LOG"
}
log_info()  { log_emit INFO "$*"; }
log_warn()  { log_emit WARN "$*"; }
log_crit()  { log_emit CRIT "$*"; }

# === State Files ===
STATE_DIR="/mnt/user/node/logs/disk_health/state"           # Base directory for state files
mkdir -p "$STATE_DIR"
chown "$HEALTH_LOG_USER:$HEALTH_LOG_GROUP" "$STATE_DIR" 2>/dev/null || true
chmod "$HEALTH_DIR_MODE" "$STATE_DIR" 2>/dev/null || true
SMART_LONG_STATE_FILE="$STATE_DIR/smart_long_processed.log" # Tracks processed long self-tests
SMART_LAST="$STATE_DIR/smart_last_test.log"                 # Last SMART test per disk
NVME_STATE_FILE="$STATE_DIR/counters_last.log"              # Last NVMe unsafe shutdown counters
PREV_ATTR_FILE="$STATE_DIR/smart_prev_attrs.log"            # Previous SMART attrs for delta tagging
CAPACITY_HISTORY_FILE="$STATE_DIR/capacity_history.log"     # Historical array/pools percent used
DISK_CAP_HISTORY_FILE="$STATE_DIR/disk_cap_history.log"     # Historical per-disk used/size
SHARE_USAGE_HISTORY_FILE="$STATE_DIR/share_usage_history.log" # Historical per-share size
ALERT_NEW_SEEN_FILE="$STATE_DIR/new_alerts_seen.log"        # Cache of NEW alerts already announced
RISK_PREV_FILE="$STATE_DIR/risk_prev.log"                   # Previous per-disk risk scores
TBW_HISTORY_FILE="$STATE_DIR/tbw_history.log"               # Historical per-disk TBW bytes
HEAVY_WRITER_HISTORY_FILE="$STATE_DIR/heavy_writer_history.log" # Historical heavy writer normalized percent
RISK_TIER_HISTORY_FILE="$STATE_DIR/risk_tier_history.log"   # Historical daily risk tier & lifecycle counts
IO_ERROR_HISTORY_FILE="$STATE_DIR/io_error_history.log"     # Recent disk I/O error message hashes (epoch device hash)
BTRFS_DEV_HIST_FILE="$STATE_DIR/btrfs_device_stats.history" # Btrfs per-device stats history
if [ -f "$RISK_PREV_FILE" ]; then                           # Load previous risk scores
    while read -r dev score; do
        [[ -z "$dev" || -z "$score" ]] && continue
        PREV_RISK["$dev"]="$score"
    done < "$RISK_PREV_FILE"
fi

# === JSON Export ===
JSON_EXPORT_DIR="/mnt/user/node/logs/disk_health/json"      # Directory to write JSON summary
mkdir -p "$JSON_EXPORT_DIR"
chown "$HEALTH_LOG_USER:$HEALTH_LOG_GROUP" "$JSON_EXPORT_DIR" 2>/dev/null || true
chmod "$HEALTH_DIR_MODE" "$JSON_EXPORT_DIR" 2>/dev/null || true
HEALTH_JSON="$JSON_EXPORT_DIR/disks_health_summary.json"    # Health JSON output file

# === Notification Titles ===
NOTIFY_TITLE_SMART="SMART Test Alert"                       # SMART test notifications
NOTIFY_TITLE_BTRFS="Btrfs Scrub Alert"                      # Btrfs scrub notifications
NOTIFY_TITLE_XFS="XFS Alert"                                # XFS filesystem notifications
NOTIFY_TITLE_DISKIO="Disk I/O Alert"                        # Disk I/O notifications

# -----------------------------------------------

# Prune old timestamped run logs based on age and count limits.
prune_old_run_logs() {
    (( LOG_PRUNE_ENABLED == 1 )) || return 0
    local patterns=("disk_health_*.log")
    local removed=0
    for pat in "${patterns[@]}"; do
        if (( LOG_MAX_DAYS > 0 )); then
            while IFS= read -r f; do
                [[ -f "$f" ]] || continue
                rm -f -- "$f" && ((removed++)) || true
            done < <(find "$LOG_DIR" -maxdepth 1 -type f -name "$pat" -mtime +$LOG_MAX_DAYS 2>/dev/null)
        fi
        if (( LOG_MAX_COUNT > 0 )); then
            mapfile -t files < <(find "$LOG_DIR" -maxdepth 1 -type f -name "$pat" -printf '%T@\t%p\n' 2>/dev/null | sort -n | awk -F'\t' '{print $2}')
            while (( ${#files[@]} > LOG_MAX_COUNT )); do
                local oldest="${files[0]}"
                rm -f -- "$oldest" && ((removed++)) || true
                files=("${files[@]:1}")
            done
        fi
    done
    if (( removed > 0 )); then
        log_info "Pruned $removed old run log(s)"
    fi
}
prune_old_run_logs

# Send notification via Unraid notify utility with aggregated subsystem summary.
notify_unraid() {
    local title="$1"; shift
    local body="$1"; shift
    local sev="${1:-warning}"
    local icon="normal"
    case "$sev" in
        critical|CRITICAL) icon="alert" ;;
        warning|WARNING) icon="warning" ;;
        *) icon="normal" ;;
    esac
        local crit_count=${#ALERT_CRIT[@]}
    local warn_count=${#ALERT_WARN[@]}
    local sev_word
    case "$sev" in
        critical|CRITICAL) sev_word="CRITICAL";;
        warning|WARNING) sev_word="WARNING";;
        *) sev_word="OK";;
    esac
    local sm_state bt_state xfs_state cap_state pm_state
    sm_state=$(echo "$SUBSYSTEM_LINES" | awk -F': ' '/^SMART:/ {print $2; exit}')
    bt_state=$(echo "$SUBSYSTEM_LINES" | awk -F': ' '/^Btrfs:/ {print $2; exit}')
    xfs_state=$(echo "$SUBSYSTEM_LINES" | sed -n 's/^XFS:[ \t]*\(.*\)$/\1/p' | head -n1)
    cap_state=$(echo "$SUBSYSTEM_LINES" | awk -F': ' '/^Capacity:/ {print $2; exit}')
    pr_state=$(echo "$SUBSYSTEM_LINES" | awk -F': ' '/^Parity:/ {print $2; exit}')
    pm_state=$(echo "$SUBSYSTEM_LINES" | awk -F': ' '/^Per-Mount:/ {print $2; exit}')
    local parts=()
    add_if() { local k="$1" v="$2"; [[ -z "$v" ]] && return; if [[ "$v" == "Disabled" && $SHOW_DISABLED_SUBSYSTEMS -eq 0 ]]; then return; fi; if [[ $SHOW_OK_SUBSYSTEMS -eq 0 && "$v" == "OK" ]]; then return; fi; if [[ "$v" == "N/A" ]]; then return; fi; parts+=("$k $v"); }
    add_if SMART "$sm_state"
    add_if Btrfs "$bt_state"
    add_if XFS "$xfs_state"
    add_if Capacity "$cap_state"
    add_if Parity "$pr_state"
    add_if Per-Mount "$pm_state"
    local subsum="" sep=""
    if (( ${#parts[@]} > 0 )); then subsum=$(IFS=' | '; echo "${parts[*]}"); fi
    local summary_line
    if [[ -n "$subsum" ]]; then
        summary_line="$subsum"
    else
        summary_line=""
    fi
    local body_norm
    body_norm=$(printf "%s\n" "$body" | awk '{sub(/[ \t]+$/, "")} NF{print; blank=0; next} !blank{print ""; blank=1}')
    local BIN="/usr/local/emhttp/webGui/scripts/notify"
    local rc=0
    if [ -x "$BIN" ]; then
        log_info "Sending notification with $icon title '$title'"
        "$BIN" -s "${title:-Disks Health Monitoring}" -d "$summary_line" -m "$body_norm" -i "$icon" || rc=$?
        if (( rc != 0 )); then
            log_warn "Sending notification FAILED - returned non-zero exit $rc; continuing"
        fi
    else
        log_warn "Sending notification FAILED - notify binary missing, using syslog fallback"
        logger -t "Disks Health Monitoring" "${title:-Disks Health Monitoring}: $summary_line"
        logger -t "Disks Health Monitoring" "$body_norm"
    fi
    return 0
}

# Accumulate an alert (warning/critical) and log with severity.
record_alert() {
    local sev="$1"; shift
    local title="$1"; shift
    local body="$1"; shift
    if [[ "$sev" =~ ^(critical|CRITICAL)$ ]]; then
        ALERT_CRIT+=("$title: $body")
        log_crit "$title - $body"
    else
        ALERT_WARN+=("$title: $body")
        log_warn "$title - $body"
    fi
}

# Convert bytes to human readable decimal units.
human_readable() {
    local bytes=${1:-0}
    local KB=1000
    local MB=$((KB*KB))
    local GB=$((MB*KB))
    local TB=$((GB*KB))
    if (( bytes < KB )); then printf "%d B" "$bytes"; return; fi
    if (( bytes < MB )); then awk -v b="$bytes" -v k="$KB" 'BEGIN{printf "%.2f KB", b/k}'; return; fi
    if (( bytes < GB )); then awk -v b="$bytes" -v m="$MB" 'BEGIN{printf "%.2f MB", b/m}'; return; fi
    if (( bytes < TB )); then awk -v b="$bytes" -v g="$GB" 'BEGIN{printf "%.2f GB", b/g}'; return; fi
    awk -v b="$bytes" -v t="$TB" 'BEGIN{printf "%.2f TB", b/t}'
}

# Normalize a device to its base (strip partition component).
base_device() {
    local d="$1"
    if [[ "$d" == /dev/nvme* ]]; then
        echo "$d" | sed -E 's/p[0-9]+$//'
    else
        echo "$d" | sed -E 's/[0-9]+$//'
    fi
}

# Return and cache device model string using smartctl -i.
get_device_model() {
    local d=$(base_device "$1")
    if [[ -n "${MODEL_CACHE[$d]:-}" ]]; then
        echo "${MODEL_CACHE[$d]}"; return 0
    fi
    if [[ "$d" == /dev/nvme* ]]; then
        MODEL_CACHE[$d]=$(smartctl -i -d nvme "$d" 2>/dev/null | awk -F: '/Model Number/ {sub(/^ +/,"",$2); print $2; exit}')
    else
        MODEL_CACHE[$d]=$(smartctl -i "$d" 2>/dev/null | awk -F: '/Device Model|Model Family/ {sub(/^ +/,"",$2); print $2; exit}')
    fi
    echo "${MODEL_CACHE[$d]}"
}

# Return and cache device capacity in TB (decimal, 1 TB = 10^12 bytes).
get_device_capacity_tb() {
    local d=$(base_device "$1")
    if [[ -n "${CAPACITY_CACHE[$d]:-}" ]]; then
        echo "${CAPACITY_CACHE[$d]}"; return 0
    fi
    local bytes
    bytes=$(lsblk -b -dn -o SIZE "$d" 2>/dev/null | head -n1)
    bytes=${bytes:-0}
    CAPACITY_CACHE[$d]=$(awk -v b="$bytes" 'BEGIN{printf "%.3f", b/1000000000000.0}')
    echo "${CAPACITY_CACHE[$d]}"
}

# Fetch and cache raw smartctl -A output for SATA.
get_sata_raw() {
    local d=$(base_device "$1")
    if [[ -n "${SMART_RAW[$d]:-}" ]]; then
        echo "${SMART_RAW[$d]}"; return 0
    fi
    SMART_RAW[$d]=$(smartctl -A "$d" 2>/dev/null || true)
    echo "${SMART_RAW[$d]}"
}

# Fetch and cache smartctl -i output for SATA (interface & link info).
get_sata_info() {
    local d=$(base_device "$1")
    if [[ -n "${SMART_INFO[$d]:-}" ]]; then
        echo "${SMART_INFO[$d]}"; return 0
    fi
    SMART_INFO[$d]=$(smartctl -i "$d" 2>/dev/null || true)
    echo "${SMART_INFO[$d]}"
}

# Fetch and cache raw smartctl -a output for NVMe.
get_nvme_raw() {
    local d=$(base_device "$1")
    if [[ -n "${NVME_RAW[$d]:-}" ]]; then
        echo "${NVME_RAW[$d]}"; return 0
    fi
    log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART attribute read (-a) on $d"
    NVME_RAW[$d]=$(smartctl -a -d nvme "$d" 2>/dev/null || true)
    echo "${NVME_RAW[$d]}"
}

# Determine TBW endurance threshold (TB) based on model heuristic.
tbw_threshold_tb_for_device() {
    local model="$1"; shift
    local cap="$1"; shift
    local per_tb=0
    if echo "$model" | grep -qi 'MX500'; then per_tb=350; fi
    if echo "$model" | grep -qi 'WD Red' | grep -qi 'SA500'; then per_tb=600; fi
    if echo "$model" | grep -qi 'T500'; then per_tb=600; fi
    if echo "$model" | grep -qiE 'P3|P300'; then per_tb=220; fi
    if (( per_tb == 0 )); then echo ""; return 0; fi
    awk -v c="$cap" -v p="$per_tb" 'BEGIN{printf "%.0f", c*p}'
}

# Determine POH warn/crit thresholds by device model/type
poh_thresholds_for_device() {
    local dev="$1"; shift
    local dtype="$1"; shift # nvme|sata
    local rota="${1:-}"    # for sata: 1=HDD, 0=SSD
    local model
    model=$(get_device_model "$dev")
    local warn=0 crit=0
    if [[ "$dtype" == "nvme" ]]; then
        warn=$NVME_POH_WARN_HOURS; crit=$NVME_POH_CRIT_HOURS
        if echo "$model" | grep -qiE 'Crucial.*T500|T500'; then warn=4000; crit=6000; fi
    else
        if [[ "$rota" == "1" ]]; then
            # HDD
            warn=$HDD_POH_WARN_HOURS; crit=$HDD_POH_CRIT_HOURS
            if echo "$model" | grep -qi 'Ultrastar'; then warn=50000; crit=70000; fi
        else
            # SATA SSD
            warn=$SSD_POH_WARN_HOURS; crit=$SSD_POH_CRIT_HOURS
            if echo "$model" | grep -qiE 'SA500|WD Red SA500'; then warn=6000; crit=10000; fi
        fi
    fi
    echo "$warn $crit"
}

# Enumerate all physical disks, excluding /boot device, intentionally spinning them up.
get_all_disks() {
    local sata nvme out=()
    sata=$(ls /dev/sd* 2>/dev/null | grep -E '^/dev/sd[a-z]+$' || true)
    nvme=$(ls /dev/nvme?n? 2>/dev/null || true)
    local boot_src boot_root=""
    boot_src=$(findmnt -n -o SOURCE /boot 2>/dev/null || true)
    if [[ -n "$boot_src" ]]; then
        if [[ "$boot_src" == /dev/nvme* ]]; then
            boot_root=$(echo "$boot_src" | sed -E 's/p[0-9]+$//')
        else
            boot_root=$(echo "$boot_src" | sed -E 's/[0-9]+$//')
        fi
    fi
    for d in $sata $nvme; do
        if [[ -n "$boot_root" && "$d" == "$boot_root" ]]; then
            continue
        fi
        out+=("$d")
    done
    echo "${out[@]}"
}

# Construct mapping of Unraid array mountpoints to physical devices
build_mount_device_map() {
    MOUNT_TO_DEV=()
    local ini="/var/local/emhttp/disks.ini"
    local cfg="/boot/config/disk.cfg"
    local src=""
    if [[ -f "$ini" ]]; then
        src="$ini"
    elif [[ -f "$cfg" ]]; then
        src="$cfg"
    else
        return 0
    fi
    while IFS=$'\t' read -r name dev; do
        [[ -z "$name" || -z "$dev" ]] && continue
        case "$name" in
            disk[0-9]*) MOUNT_TO_DEV["/mnt/$name"]="/dev/$dev";;
        esac
    done < <(awk -F= '
        BEGIN{disk=""}
        /^\[disk[0-9]+\]/ {disk=$0; gsub(/^\[/, "", disk); gsub(/\]$/, "", disk); next}
        tolower($1)=="device" && disk!="" {val=$2; gsub(/"/, "", val); sub(/^[ \t]+/, "", val); sub(/[ \t]+$/, "", val); printf "%s\t%s\n", disk, val}
    ' "$src" 2>/dev/null)

    while IFS=$'\t' read -r name idv; do
        [[ -z "$name" || -z "$idv" ]] && continue
        local mp="/mnt/$name"
        [[ -n "${MOUNT_TO_DEV[$mp]:-}" ]] && continue
        local resolved
        resolved=$(readlink -f "/dev/disk/by-id/$idv" 2>/dev/null || true)
        if [[ -b "$resolved" ]]; then
            MOUNT_TO_DEV["$mp"]="$resolved"
        fi
    done < <(awk -F= '
        BEGIN{disk=""}
        /^\[disk[0-9]+\]/ {disk=$0; gsub(/^\[/, "", disk); gsub(/\]$/, "", disk); next}
        tolower($1)=="id" && disk!="" {val=$2; gsub(/"/, "", val); sub(/^[ \t]+/, "", val); sub(/[ \t]+$/, "", val); printf "%s\t%s\n", disk, val}
    ' "$src" 2>/dev/null)
}

# Parity state discovery sets global fields without re-parsing
parity_state() {
    PARITY_VALID_FLAG=""
    PARITY_SOURCE="none"
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
        sb=$(awk -F= 'tolower($1)=="sbclean" {gsub(/"| |\r|\n/,"",$2); print tolower($2); exit}' "$ini" 2>/dev/null)
        case "$sb" in
            1|yes|true) PARITY_VALID_FLAG="1"; PARITY_SOURCE="var.ini"; return 0;;
            0|no|false) PARITY_VALID_FLAG="0"; PARITY_SOURCE="var.ini"; return 0;;
        esac
    fi
    # Fallback to mdcmd status
    local cmd="/usr/local/sbin/mdcmd" out
    [[ -x "$cmd" ]] || cmd="mdcmd"
    if command -v "$cmd" >/dev/null 2>&1; then
        out=$("$cmd" status 2>/dev/null | tr -d '\r') || out=""
        if [[ -n "$out" ]]; then
            PARITY_SOURCE="mdcmd"
            local sb st act corr pos size errs spk rem
            sb=$(echo "$out" | awk -F= 'tolower($1)=="sbclean" {print tolower($2); exit}')
            st=$(echo "$out" | awk -F= 'tolower($1)=="mdstate" {print tolower($2); exit}')
            act=$(echo "$out" | awk -F= 'tolower($1)=="mdresyncaction" {print tolower($2); exit}')
            corr=$(echo "$out"| awk -F= 'tolower($1)=="mdresynccorr" {print $2; exit}')
            pos=$(echo "$out" | awk -F= 'tolower($1)=="mdresyncpos" {print $2; exit}')
            size=$(echo "$out"| awk -F= 'tolower($1)=="mdresyncsize" {print $2; exit}')
            errs=$(echo "$out"| awk -F= 'tolower($1)=="mdsyncerrs" {print $2; exit}')
            spk=$(echo "$out" | awk -F= 'tolower($1)=="mdresyncspeed" {print $2; exit}')
            rem=$(echo "$out" | awk -F= 'tolower($1)=="mdresyncrem" {print $2; exit}')
            if [[ -n "$sb" ]]; then
                case "$sb" in 1|yes|true) PARITY_VALID_FLAG="1";; 0|no|false) PARITY_VALID_FLAG="0";; esac
            else
                if [[ -n "$act" && "$act" != "idle" ]]; then PARITY_VALID_FLAG="0"
                elif [[ "$st" == "started" ]]; then PARITY_VALID_FLAG="1"
                else PARITY_VALID_FLAG=""; fi
            fi
            PARITY_ACTION="$act"
            PARITY_CORR="$corr"
            PARITY_POS="$pos"
            PARITY_SIZE="$size"
            PARITY_ERRS="$errs"
            PARITY_SPEED_K="$spk"
            PARITY_REM="$rem"
            return 0
        fi
    fi
    return 1
}

# Determine parity validity from var.ini or mdcmd
parity_clean_flag() {
    parity_state || true
    if [[ -n "${PARITY_VALID_FLAG:-}" ]]; then echo "${PARITY_VALID_FLAG}"; return 0; fi
    echo ""; return 1
}

discover_parity_and_status() {
    PARITY_STATUS_LINE=""
    PARITY_DETAILS_SECTION=""
    PARITY_LABELS_JSON="[]"
    PARITY_DEVICES_JSON="[]"
    PARITY_DETAILS_JSON="null"
    local ini="/var/local/emhttp/disks.ini"
    local -a parity_labels=()
    local -a parity_devs=()
    if [[ -f "$ini" ]]; then
        while IFS=$'\t' read -r sec dev idv; do
            [[ -z "$sec" ]] && continue
            case "$sec" in
                parity|parity2|parity[0-9]*)
                    local resolved=""
                    if [[ -n "$dev" ]]; then
                        resolved="/dev/$dev"
                    elif [[ -n "$idv" ]]; then
                        resolved=$(readlink -f "/dev/disk/by-id/$idv" 2>/dev/null || true)
                    fi
                    if [[ -n "$resolved" ]]; then
                        parity_labels+=("$sec")
                        parity_devs+=("$resolved")
                    fi
                    ;;
            esac
        done < <(awk -F= '
            BEGIN{sec=""; dev=""; idv=""}
            /^\[(parity|parity2|parity[0-9]+)\]/ {
                if (sec!="") { printf "%s\t%s\t%s\n", sec, dev, idv }
                sec=$0; gsub(/^[\[]|[\]]$/, "", sec); dev=""; idv=""; next
            }
            tolower($1)=="device" && sec!="" {val=$2; gsub(/"/, "", val); sub(/^[ \t]+/, "", val); sub(/[ \t]+$/, "", val); dev=val; next}
            tolower($1)=="id" && sec!="" {val=$2; gsub(/"/, "", val); sub(/^[ \t]+/, "", val); sub(/[ \t]+$/, "", val); idv=val; next}
            END{ if (sec!="") { printf "%s\t%s\t%s\n", sec, dev, idv } }
        ' "$ini" 2>/dev/null)
    fi
    local labels_join=""
    if (( ${#parity_labels[@]} > 0 )); then
        labels_join=$(IFS=","; echo "${parity_labels[*]}")
        labels_join=$(echo "$labels_join" | sed 's/,/, /g')
        local _lj="" _dj="" i
        for ((i=0;i<${#parity_labels[@]};i++)); do
            local l=${parity_labels[$i]} d=${parity_devs[$i]}
            _lj+="\"$l\""; _dj+="\"$d\""
            if (( i<${#parity_labels[@]}-1 )); then _lj+=","; _dj+=","; fi
        done
        PARITY_LABELS_JSON="[${_lj}]"
        PARITY_DEVICES_JSON="[${_dj}]"
    fi
    parity_state || true
    local clean_flag="${PARITY_VALID_FLAG:-}"
    PARITY_CLEAN_FLAG="$clean_flag"
    if [[ -n "$clean_flag" ]]; then
        if [[ "$clean_flag" == "1" ]]; then
            if [[ -n "$labels_join" ]]; then
                PARITY_STATUS_LINE="Parity ($labels_join): Valid"
            else
                PARITY_STATUS_LINE="Parity: Valid"
            fi
        else
            if [[ -n "$labels_join" ]]; then
                PARITY_STATUS_LINE="Parity ($labels_join): Invalid (sync required)"
            else
                PARITY_STATUS_LINE="Parity: Invalid (sync required)"
            fi
            record_alert warning "Parity Status" "Parity invalid (sync required)"

            local action="${PARITY_ACTION:-}" corr="${PARITY_CORR:-}" pos="${PARITY_POS:-}" size="${PARITY_SIZE:-}" errs="${PARITY_ERRS:-}" speed_k="${PARITY_SPEED_K:-}" rem="${PARITY_REM:-}"
            local action_word="" corr_label="" pct="" eta_str=""
            [[ -n "$action" ]] && action_word=$(printf "%s" "$action" | awk '{print tolower($1)}')
            corr_label=$([[ "$corr" == "1" ]] && echo "correcting" || echo "non-correcting")
            if [[ -n "$pos" && -n "$size" ]]; then
                pct=$(awk -v p="$pos" -v s="$size" 'BEGIN{ if (s>0) printf "%.1f", (p/s)*100; }')
            fi
            if [[ -n "$action_word" && "$action_word" != "idle" ]]; then
                PARITY_STATUS_LINE+=" — ${action_word} in progress (${corr_label})"
                [[ -n "$pct" ]] && PARITY_STATUS_LINE+=", ~${pct}%"
                PARITY_DETAILS_SECTION="Parity Details:\n"
                PARITY_DETAILS_SECTION+=" - Action: ${action_word} (${corr_label})\n"
                if [[ -n "$pos" && -n "$size" ]]; then
                    PARITY_DETAILS_SECTION+=" - Progress: ${pos} / ${size}"
                    [[ -n "$pct" ]] && PARITY_DETAILS_SECTION+=" (~${pct}%)"
                    PARITY_DETAILS_SECTION+="\n"
                fi
                local progress_file="$STATE_DIR/parity_progress.state" prev_pos="" prev_ts="" curr_ts=$(date +%s)
                if [[ -f "$progress_file" ]]; then
                    read -r prev_pos prev_ts < "$progress_file" || true
                fi
                if [[ -n "$pos" && -n "$prev_pos" && -n "$prev_ts" && "$pos" =~ ^[0-9]+$ && "$prev_pos" =~ ^[0-9]+$ && "$prev_ts" =~ ^[0-9]+$ && $pos -ge $prev_pos ]]; then
                    local dt=$(( curr_ts - prev_ts ))
                    if (( dt > 0 )); then
                        local delta=$(( pos - prev_pos ))
                        local bytes=$(( delta * 512 ))
                        local mbps=$(awk -v b="$bytes" -v d="$dt" 'BEGIN{ if(d>0) printf "%.2f", (b/1048576)/d; }')
                        if [[ -n "$mbps" && -n "$size" && "$size" =~ ^[0-9]+$ ]]; then
                            local remaining=$(( size - pos ))
                            if (( remaining > 0 )); then
                                local rem_bytes=$(( remaining * 512 ))
                                local eta_sec=$(awk -v rb="$rem_bytes" -v mbps="$mbps" 'BEGIN{ mb=mbps*1048576; if(mb>0) printf "%d", rb/mb; }')
                                if [[ -n "$eta_sec" && "$eta_sec" =~ ^[0-9]+$ ]]; then
                                    local eta_h=$(( eta_sec/3600 )) eta_m=$(( (eta_sec%3600)/60 )) eta_s=$(( eta_sec%60 ))
                                    if (( eta_h>0 )); then eta_str="${eta_h}h ${eta_m}m"; elif (( eta_m>0 )); then eta_str="${eta_m}m ${eta_s}s"; else eta_str="${eta_s}s"; fi
                                    PARITY_DETAILS_SECTION+=" - ETA: ${eta_str} remaining\n"
                                fi
                            fi
                        fi
                        PARITY_DETAILS_SECTION+=" - Speed: ${mbps} MB/s (Δ ${delta} sectors / ${dt}s)\n"
                    fi
                fi
                if [[ -n "$speed_k" && "$speed_k" =~ ^[0-9]+$ ]]; then
                    local speed_mb=$(awk -v sp="$speed_k" 'BEGIN{printf "%.2f", sp/1024.0}')
                    PARITY_DETAILS_SECTION+=" - Reported Speed: ${speed_mb} MB/s\n"
                fi
                if [[ -n "$rem" && "$rem" =~ ^[0-9]+$ ]]; then
                    PARITY_DETAILS_SECTION+=" - Remaining Sectors: ${rem}\n"
                fi
                if [[ -n "$errs" ]]; then
                    PARITY_DETAILS_SECTION+=" - Errors: ${errs}\n"
                fi
                if [[ -n "$pos" ]]; then echo "$pos $curr_ts" > "$progress_file" 2>/dev/null || true; fi

                local corr_bool=$([[ "$corr" == "1" ]] && echo true || echo false)
                local speed_mb_json="null"; [[ -n "$speed_k" && "$speed_k" =~ ^[0-9]+$ ]] && speed_mb_json=$(awk -v sp="$speed_k" 'BEGIN{printf "%.2f", sp/1024.0}')
                local pct_json="null"; [[ -n "$pct" ]] && pct_json="$pct"
                local errs_json="null"; [[ -n "$errs" ]] && errs_json="$errs"
                local rem_json="null"; [[ -n "$rem" ]] && rem_json="$rem"
                local eta_json="null"; [[ -n "$eta_str" ]] && eta_json="\"$eta_str\""
                PARITY_DETAILS_JSON="{ \"action\": \"${action_word}\", \"correcting\": ${corr_bool}, \"progress_pos\": ${pos:-0}, \"progress_size\": ${size:-0}, \"progress_percent\": ${pct_json}, \"speed_mbps\": ${speed_mb_json}, \"remaining_sectors\": ${rem_json}, \"errors\": ${errs_json}, \"eta\": ${eta_json} }"
            fi
            local idx
            for ((idx=0; idx<${#parity_devs[@]}; idx++)); do
                local pdev="${parity_devs[$idx]}"
                [[ -b "$pdev" ]] || continue
                local model cap
                model=$(get_device_model "$pdev")
                cap=$(get_device_capacity_tb "$pdev")
                printf -v ARRAY_DEVICE_LINES "%s%-8s %-10s %sTB %s %s\n" \
                    "$ARRAY_DEVICE_LINES" "$(basename "$pdev")" "[WARNING]" "$cap" "$model" "Parity invalid (sync required)"
            done
        fi
    else
        PARITY_STATUS_LINE="Parity: Unknown"
    fi
}

# Given a mountpoint, return the associated physical device (from map or findmnt).
smart_device_for_mount() {
    local mp="$1"
    local dev="${MOUNT_TO_DEV[$mp]:-}"
    if [[ -n "$dev" && -b "$dev" ]]; then
        echo "$dev"; return 0
    fi
    local src
    src=$(findmnt -n -o SOURCE "$mp" 2>/dev/null || true)
    echo "$src"
}

if [ -f "$SMART_LAST" ]; then
    while read -r disk date; do
        LAST_TEST["$disk"]=$date
    done < "$SMART_LAST"
fi

if [ -f "$NVME_STATE_FILE" ]; then
    while read -r dev count; do
        NVME_LAST_UNSAFE["$dev"]=$count
    done < "$NVME_STATE_FILE"
fi

if [ -f "$PREV_ATTR_FILE" ]; then
    while read -r line; do
        [[ -z "$line" ]] && continue
        disk=""
        token=""
        disk=$(echo "$line" | awk '{print $1}')
        for token in $(echo "$line" | awk '{for(i=2;i<=NF;i++) print $i}'); do
            k=""; v=""
            k=${token%%=*}; v=${token#*=}
            [[ -n "$k" ]] && PREV_ATTR["$disk|$k"]="$v"
        done
    done < "$PREV_ATTR_FILE"
fi
if [ -f "$ALERT_NEW_SEEN_FILE" ]; then
    while IFS= read -r key; do
        [[ -n "$key" ]] && NEW_SEEN["$key"]=1
    done < "$ALERT_NEW_SEEN_FILE"
fi

# Save current SMART attributes for delta tracking.
save_last_test() {
    > "$SMART_LAST"
    for disk in "${!LAST_TEST[@]}"; do
        echo "$disk ${LAST_TEST[$disk]}" >> "$SMART_LAST"
    done
}

# Save current NVMe unsafe shutdown counters.
save_nvme_state() {
    > "$NVME_STATE_FILE"
    for dev in "${!NVME_LAST_UNSAFE[@]}"; do
        echo "$dev ${NVME_LAST_UNSAFE[$dev]}" >> "$NVME_STATE_FILE"
    done
}

# Evaluate SMART attributes and status for a given disk.
evaluate_smart() {
    local disk=$1
    local is_nvme=0
    [[ $disk == /dev/nvme* ]] && is_nvme=1
    local state="OK"
    local messages=()
    if [[ $is_nvme -eq 1 ]]; then
        local nvme_output
        nvme_output=$(get_nvme_raw "$disk")
        local percent_used crit_warn nvme_temp media_errors err_logs unsafe_shutdowns avail_spare avail_spare_thr duw poh
        percent_used=$(echo "$nvme_output" | awk -F: '/Percentage Used/ {gsub(/%| /,"",$2); print $2; exit}')
        percent_used=${percent_used:-0}
        poh=$(echo "$nvme_output" | awk -F: '/Power On Hours/ {gsub(/ /,"",$2); print $2; exit}')
        poh=${poh:-0}
        crit_warn=$(echo "$nvme_output" | awk -F: '/Critical Warning/ {gsub(/ |\t/,"",$2); print $2; exit}')
        crit_warn=${crit_warn:-0}
        media_errors=$(echo "$nvme_output" | awk -F: '/Media and Data Integrity Errors/ {gsub(/ /,"",$2); print $2; exit}')
        media_errors=${media_errors:-0}
        err_logs=$(echo "$nvme_output" | awk -F: '/Error Information Log Entries/ {gsub(/ /,"",$2); print $2; exit}')
        err_logs=${err_logs:-0}
        unsafe_shutdowns=$(echo "$nvme_output" | awk -F: '/Unsafe Shutdowns/ {gsub(/ /,"",$2); print $2; exit}')
        unsafe_shutdowns=${unsafe_shutdowns:-0}
        avail_spare=$(echo "$nvme_output" | awk -F: '/Available Spare[^T]/ {gsub(/%| /,"",$2); print $2; exit}')
        avail_spare=${avail_spare:-}
        avail_spare_thr=$(echo "$nvme_output" | awk -F: '/Available Spare Threshold/ {gsub(/%| /,"",$2); print $2; exit}')
        avail_spare_thr=${avail_spare_thr:-}
        duw=$(echo "$nvme_output" | awk -F: '/Data Units Written/ { if (match($2, /[0-9][0-9,]*/)) { v=substr($2,RSTART,RLENGTH); gsub(/,/, "", v); print v } else { print "" } exit }')
        if [[ -n "$duw" ]]; then
            local tbw_bytes=$(( duw * 512000 ))
            local tbw_hr=$(human_readable "$tbw_bytes")
            messages+=("TBW ~ $tbw_hr")
            CUR_ATTR["$disk|tbw_bytes"]="$tbw_bytes"
            local model cap tbw_thresh
            model=$(get_device_model "$disk")
            cap=$(get_device_capacity_tb "$disk")
            tbw_thresh=$(tbw_threshold_tb_for_device "$model" "$cap")
            if [[ -n "$tbw_thresh" ]]; then
                local TB=$((1000*1000*1000*1000))
                if (( tbw_bytes >= tbw_thresh * TB )) && [[ $state != CRITICAL ]]; then
                    [[ $state == OK ]] && state="WARNING"; messages+=("TBW exceeds model baseline ${tbw_thresh} TB")
                else
                    local consumed_pct=$(awk -v b="$tbw_bytes" -v th="$tbw_thresh" -v TB="$TB" 'BEGIN{if(th>0){printf "%d", (b/(th*TB))*100}else{print 0}}')
                    CUR_ATTR["$disk|tbw_consumed_pct"]="$consumed_pct"
                    if (( consumed_pct >= TBW_CONSUMED_CRIT )); then
                        state="CRITICAL"; messages+=("TBW consumed ${consumed_pct}% >= ${TBW_CONSUMED_CRIT}%")
                    elif (( consumed_pct >= TBW_CONSUMED_WARN )) && [[ $state != CRITICAL ]]; then
                        [[ $state == OK ]] && state="WARNING"; messages+=("TBW consumed ${consumed_pct}% >= ${TBW_CONSUMED_WARN}%")
                    fi
                fi
            elif [[ $TBW_WARN_TB -gt 0 ]]; then
                local TB=$((1000*1000*1000*1000))
                if (( tbw_bytes >= TBW_WARN_TB * TB )) && [[ $state != CRITICAL ]]; then
                    [[ $state == OK ]] && state="WARNING"; messages+=("TBW exceeds ${TBW_WARN_TB} TB")
                fi
            fi
        fi
        nvme_temp=$(echo "$nvme_output" | awk -F: '/Temperature/ {print $2; exit}' | grep -oE '[0-9]+' | head -n1)
        if [[ $percent_used -ge $NVME_PERCENT_USED_CRIT ]]; then
            state="CRITICAL"; messages+=("NVMe wear ${percent_used}% >= ${NVME_PERCENT_USED_CRIT}%")
        elif [[ $percent_used -ge $NVME_PERCENT_USED_WARN ]]; then
            state="WARNING"; messages+=("NVMe wear ${percent_used}% >= ${NVME_PERCENT_USED_WARN}%")
        fi
        if [[ $crit_warn -ne 0 ]]; then
            state="CRITICAL"; messages+=("NVMe Critical Warning flags: $crit_warn")
            local cw_dec=""
            if [[ $crit_warn =~ ^0x[0-9A-Fa-f]+$ ]]; then
                cw_dec=$((16#${crit_warn#0x}))
            else
                cw_dec=$crit_warn
            fi
            if (( (cw_dec & 0x02) != 0 )); then
                messages+=("NVMe thermal threshold exceeded (Critical Warning bit1)")
            fi
            if (( (cw_dec & 0x01) != 0 )); then
                local dup=0; for m in "${messages[@]}"; do [[ $m == *"Available Spare"* ]] && dup=1; done; (( dup==0 )) && messages+=("NVMe available spare below threshold (Critical Warning bit0)")
                [[ $state == OK ]] && state="WARNING"
            fi
            if (( (cw_dec & 0x04) != 0 )); then
                state="CRITICAL"; messages+=("NVMe reliability degraded (Critical Warning bit2)")
            fi
            if (( (cw_dec & 0x08) != 0 )); then
                state="CRITICAL"; messages+=("NVMe media in read-only mode (Critical Warning bit3)")
            fi
            if (( (cw_dec & 0x10) != 0 )); then
                [[ $state == OK ]] && state="WARNING"; messages+=("NVMe volatile memory backup failed (Critical Warning bit4)")
            fi
        fi
        if [[ $media_errors -gt 0 ]]; then
            state="CRITICAL"; messages+=("NVMe media/data integrity errors = $media_errors")
        fi
        if [[ -n "$avail_spare" && -n "$avail_spare_thr" && $avail_spare -lt $avail_spare_thr ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("NVMe Available Spare ${avail_spare}% < threshold ${avail_spare_thr}%")
        elif [[ -n "$avail_spare" && $avail_spare -lt $NVME_AVAIL_SPARE_WARN ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("NVMe Available Spare low: ${avail_spare}%")
        fi
        local prev_uns=${NVME_LAST_UNSAFE[$disk]:-0}
        if [[ $unsafe_shutdowns -gt $prev_uns && $UNSAFE_SDWN_DELTA_WARN -gt 0 && $((unsafe_shutdowns - prev_uns)) -ge $UNSAFE_SDWN_DELTA_WARN ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("NVMe Unsafe Shutdowns increased: ${prev_uns} -> ${unsafe_shutdowns}")
        fi
        NVME_LAST_UNSAFE[$disk]=$unsafe_shutdowns
        if [[ -n "$nvme_temp" ]]; then
            if [[ $nvme_temp -ge $NVME_TEMP_CRITICAL ]]; then
                state="CRITICAL"; messages+=("NVMe Temp ${nvme_temp}C >= ${NVME_TEMP_CRITICAL}C")
            elif [[ $nvme_temp -ge $NVME_TEMP_WARNING && $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("NVMe Temp ${nvme_temp}C >= ${NVME_TEMP_WARNING}C")
            fi
        fi
        CUR_ATTR["$disk|nvme_percent_used"]="$percent_used"
        CUR_ATTR["$disk|poh"]="$poh"
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
        # POH age thresholds for NVMe (model-aware)
        if [[ -n "$poh" && "$poh" =~ ^[0-9]+$ ]]; then
            local _poh_w _poh_c
            read -r _poh_w _poh_c < <(poh_thresholds_for_device "$disk" "nvme")
            if [[ -n "$_poh_w" && -n "$_poh_c" ]]; then
                if (( poh >= _poh_c )); then
                    state="CRITICAL"; messages+=("POH age NVMe ${poh}h >= ${_poh_c}h")
                elif (( poh >= _poh_w )) && [[ $state != CRITICAL ]]; then
                    [[ $state == OK ]] && state="WARNING"; messages+=("POH age NVMe ${poh}h >= ${_poh_w}h")
                fi
            fi
        fi
    else
        local attr realloc pending offunc temp udma reported_uncorr cmd_timeout realloc_events end2end soft_read_err lcc poh
        attr=$(get_sata_raw "$disk")
        realloc=$(echo "$attr" | awk '/Reallocated_Sector_Ct/ {print $10; exit}')
        realloc=${realloc:-0}
        if [[ $realloc -ge $RELOC_CRITICAL ]]; then
            state="CRITICAL"; messages+=("Reallocated = $realloc (>= $RELOC_CRITICAL)")
        elif [[ $realloc -ge $RELOC_WARNING ]]; then
            state="WARNING"; messages+=("Reallocated = $realloc (>= $RELOC_WARNING)")
        fi
        pending=$(echo "$attr" | awk '/Current_Pending_Sector/ {print $10; exit}')
        pending=${pending:-0}
        if [[ $pending -ge $PEND_WARNING ]]; then
            state="CRITICAL"; messages+=("Pending sectors = $pending")
        fi
        offunc=$(echo "$attr" | awk '/Offline_Uncorrectable/ {print $10; exit}')
        offunc=${offunc:-0}
        if [[ $offunc -gt 0 ]]; then
            state="CRITICAL"; messages+=("Offline Uncorrectable = $offunc")
        fi
        reported_uncorr=$(echo "$attr" | awk '/Reported_Uncorrectable|Reported_Uncorrect/ {print $10; exit}')
        reported_uncorr=${reported_uncorr:-0}
        if [[ $reported_uncorr -ge $REPORTED_UNC_CRIT ]]; then
            state="CRITICAL"; messages+=("Reported Uncorrectable = $reported_uncorr")
        fi
        cmd_timeout=$(echo "$attr" | awk '/Command_Timeout/ {print $10; exit}')
        cmd_timeout=${cmd_timeout:-0}
        if [[ $cmd_timeout -ge $CMD_TIMEOUT_CRIT ]]; then
            state="CRITICAL"; messages+=("Command Timeout events = $cmd_timeout (>= $CMD_TIMEOUT_CRIT)")
        elif [[ $cmd_timeout -ge $CMD_TIMEOUT_WARN && $state != CRITICAL ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("Command Timeout events = $cmd_timeout")
        fi
        realloc_events=$(echo "$attr" | awk '/Reallocated_Event_Count/ {print $10; exit}')
        realloc_events=${realloc_events:-0}
        if [[ $realloc_events -ge $REALLOC_EVENT_CRIT ]]; then
            state="CRITICAL"; messages+=("Reallocated Event Count = $realloc_events (>= $REALLOC_EVENT_CRIT)")
        elif [[ $realloc_events -ge $REALLOC_EVENT_WARN && $state != CRITICAL ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("Reallocated Event Count = $realloc_events")
        fi
        end2end=$(echo "$attr" | awk '/End_to_End_Error/ {print $10; exit}')
        end2end=${end2end:-0}
        if [[ $end2end -ge $END_TO_END_ERR_CRIT ]]; then
            state="CRITICAL"; messages+=("End-to-End Errors = $end2end")
        fi
        soft_read_err=$(echo "$attr" | awk '/Soft_Read_Error_Rate/ {print $10; exit}')
        soft_read_err=${soft_read_err:-}
        if [[ -n "$soft_read_err" && $soft_read_err =~ ^[0-9]+$ && $soft_read_err -ge $SOFT_READ_ERR_WARN && $state != CRITICAL ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("Soft Read Error Rate = $soft_read_err (>= $SOFT_READ_ERR_WARN)")
        fi
        temp=$(echo "$attr" | awk '/Temperature_Celsius|Airflow_Temperature_Cel/ {print $10; exit}')
        temp=${temp:-0}
        local bdv=$(base_device "$disk")
        local rota=$(lsblk -dn -o ROTA "$bdv" 2>/dev/null | head -n1)
        local warn_t crit_t label
        if [[ "$rota" == "1" ]]; then
            warn_t=$HDD_TEMP_WARNING; crit_t=$HDD_TEMP_CRITICAL; label="HDD Temp"
        else
            warn_t=$SSD_TEMP_WARNING; crit_t=$SSD_TEMP_CRITICAL; label="SSD Temp"
        fi
        if [[ -n "$temp" && "$temp" != "0" ]]; then
            if [[ $temp -ge $crit_t ]]; then
                state="CRITICAL"; messages+=("${label} ${temp}C >= ${crit_t}C")
            elif [[ $temp -ge $warn_t && $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("${label} ${temp}C >= ${warn_t}C")
            fi
        fi
        udma=$(echo "$attr" | awk '/UDMA_CRC_Error_Count/ {print $10; exit}')
        udma=${udma:-0}
        if [[ $udma -gt 0 && $state != CRITICAL ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("UDMA CRC Errors = $udma")
        fi
        local lcc
        lcc=$(echo "$attr" | awk '/Load_Cycle_Count/ {print $10; exit}')
        lcc=${lcc:-}
        if [[ -n "$lcc" ]]; then
            if [[ $lcc -ge $LOAD_CYCLE_CRIT ]]; then
                state="CRITICAL"; messages+=("Load Cycle Count = $lcc (>= $LOAD_CYCLE_CRIT)")
            elif [[ $lcc -ge $LOAD_CYCLE_WARN && $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("Load Cycle Count = $lcc (>= $LOAD_CYCLE_WARN)")
            fi
        fi
        local wear_norm mwi_norm
        wear_norm=$(echo "$attr" | awk '/Wear_Leveling_Count/ {print $4; exit}')
        mwi_norm=$(echo "$attr" | awk '/Media_Wearout_Indicator/ {print $4; exit}')
        local life_remain=""
        if [[ -n "$mwi_norm" ]]; then life_remain=$mwi_norm; elif [[ -n "$wear_norm" ]]; then life_remain=$wear_norm; fi
        if [[ -n "$life_remain" ]]; then
            if [[ $life_remain -le $SSD_WEAR_CRIT ]]; then
                state="CRITICAL"; messages+=("SSD life remaining ${life_remain}% <= ${SSD_WEAR_CRIT}%")
            elif [[ $life_remain -le $SSD_WEAR_WARN && $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("SSD life remaining ${life_remain}% <= ${SSD_WEAR_WARN}%")
            fi
        fi
        poh=$(echo "$attr" | awk '/Power_On_Hours/ {print $10; exit}')
        CUR_ATTR["$disk|poh"]="${poh:-0}"
        # POH age thresholds for SATA (HDD vs SSD determined by ROTA, model-aware)
        if [[ -n "${poh:-}" && "$poh" =~ ^[0-9]+$ ]]; then
            local _poh_w _poh_c
            read -r _poh_w _poh_c < <(poh_thresholds_for_device "$disk" "sata" "$rota")
            if [[ -n "$_poh_w" && -n "$_poh_c" ]]; then
                if (( poh >= _poh_c )); then
                    if [[ "$rota" == "1" ]]; then state="CRITICAL"; messages+=("POH age HDD ${poh}h >= ${_poh_c}h");
                    else state="CRITICAL"; messages+=("POH age SSD ${poh}h >= ${_poh_c}h"); fi
                elif (( poh >= _poh_w )) && [[ $state != CRITICAL ]]; then
                    [[ $state == OK ]] && state="WARNING"
                    if [[ "$rota" == "1" ]]; then messages+=("POH age HDD ${poh}h >= ${_poh_w}h"); else messages+=("POH age SSD ${poh}h >= ${_poh_w}h"); fi
                fi
            fi
        fi
        # SATA negotiated link speed downshift detection
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
                fi
            fi
        fi
        [[ -n "$life_remain" ]] && CUR_ATTR["$disk|life_remain"]="$life_remain"
        local lbasw hw32mib lbasr tbw_bytes tbw_hr reads_bytes reads_hr
        lbasw=$(echo "$attr" | awk '/Total_LBAs_Written/ {print $10; exit}')
        if [[ -z "$lbasw" ]]; then lbasw=$(echo "$attr" | awk '/^[ ]*241[ ]/ {print $10; exit}'); fi
        if [[ -z "$lbasw" ]]; then
            hw32mib=$(echo "$attr" | awk '/Host_Writes_32MiB/ {print $10; exit}')
            if [[ -z "$hw32mib" ]]; then hw32mib=$(echo "$attr" | awk '/^[ ]*246[ ]/ {print $10; exit}'); fi
            if [[ -n "$hw32mib" ]]; then
                tbw_bytes=$(( hw32mib * 32 * 1024 * 1024 ))
            fi
        else
            tbw_bytes=$(( lbasw * 512 ))
        fi
        lbasr=$(echo "$attr" | awk '/Total_LBAs_Read/ {print $10; exit}')
        if [[ -z "$lbasr" ]]; then lbasr=$(echo "$attr" | awk '/^[ ]*242[ ]/ {print $10; exit}'); fi
        if [[ -n "$lbasr" ]]; then reads_bytes=$(( lbasr * 512 )); fi
        if [[ -n "${tbw_bytes:-}" ]]; then
            tbw_hr=$(human_readable "$tbw_bytes")
            messages+=("TBW ~ $tbw_hr")
            CUR_ATTR["$disk|tbw_bytes"]="$tbw_bytes"
            local model cap tbw_thresh
            model=$(get_device_model "$disk")
            cap=$(get_device_capacity_tb "$disk")
            tbw_thresh=$(tbw_threshold_tb_for_device "$model" "$cap")
            local TB=$((1000*1000*1000*1000))
            if [[ -n "$tbw_thresh" ]]; then
                if (( tbw_bytes >= tbw_thresh * TB )) && [[ $state != CRITICAL ]]; then
                    [[ $state == OK ]] && state="WARNING"; messages+=("TBW exceeds model baseline ${tbw_thresh} TB")
                else
                    local consumed_pct=$(awk -v b="$tbw_bytes" -v th="$tbw_thresh" -v TB="$TB" 'BEGIN{if(th>0){printf "%d", (b/(th*TB))*100}else{print 0}}')
                    CUR_ATTR["$disk|tbw_consumed_pct"]="$consumed_pct"
                    if (( consumed_pct >= TBW_CONSUMED_CRIT )); then
                        state="CRITICAL"; messages+=("TBW consumed ${consumed_pct}% >= ${TBW_CONSUMED_CRIT}%")
                    elif (( consumed_pct >= TBW_CONSUMED_WARN )) && [[ $state != CRITICAL ]]; then
                        [[ $state == OK ]] && state="WARNING"; messages+=("TBW consumed ${consumed_pct}% >= ${TBW_CONSUMED_WARN}%")
                    fi
                fi
            elif [[ $TBW_WARN_TB -gt 0 ]]; then
                if (( tbw_bytes >= TBW_WARN_TB * TB )) && [[ $state != CRITICAL ]]; then
                    [[ $state == OK ]] && state="WARNING"; messages+=("TBW exceeds ${TBW_WARN_TB} TB")
                fi
            fi
        fi
        if [[ -n "${reads_bytes:-}" ]]; then
            reads_hr=$(human_readable "$reads_bytes")
            messages+=("Read ~ $reads_hr")
        fi
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
    echo "$state"; for m in "${messages[@]}"; do echo "$m"; done
}

# Fetch latest self-test entry from smartctl log.
get_latest_selftest_info() {
    local disk=$1
    local out
    if [[ $disk == /dev/nvme* ]]; then
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART self-test log read (-l selftest) on $disk"
        out=$(smartctl -l selftest -d nvme "$disk" 2>/dev/null || true)
    else
        out=$(smartctl -l selftest "$disk" 2>/dev/null || true)
    fi
    local line
    line=$(echo "$out" | awk 'NR>5 && $1 ~ /^[0-9]+$/ {print; exit}')
    if [[ -z "$line" ]]; then
        echo "|||"; return
    fi
    local num type status lifetime remaining
    num=$(echo "$line" | awk '{print $1}')
    type=$(echo "$line" | awk '{print $2" "$3}')
    remaining=$(echo "$line" | grep -o '[0-9]\+%\?' | head -n1)
    lifetime=$(echo "$line" | awk '{for(i=1;i<=NF;i++){if($i ~ /hours/){print $(i-1); break}}}')
    status=$(echo "$line" | sed -E 's/^\s*[0-9]+\s+[^ ]+\s+[^ ]+\s+//' | sed -E 's/\s+[0-9]+%.*//' )
    echo "${num}|${type}|${status}|${lifetime}|${remaining}"
}

# Classify self-test status string into severity + message.
classify_selftest_status() {
    local status="$1"
    local sev="OK"
    local msg="$status"
    if echo "$status" | grep -qi "in progress"; then
        sev="INPROGRESS"
    elif echo "$status" | grep -qiE "Completed without error|without error|no error|passed"; then
        sev="OK"
    elif echo "$status" | grep -qiE "read failure|uncorrectable|failed"; then
        sev="CRITICAL"; msg="Self-test critical: $status"
    elif echo "$status" | grep -qiE "aborted|interrupted"; then
        sev="WARNING"; msg="Self-test did not complete cleanly: $status"
    elif echo "$status" | grep -qi "Completed"; then
        sev="WARNING"; msg="Self-test completed with issues: $status"
    else
        sev="WARNING"; msg="Self-test ambiguous status: $status"
    fi
    echo "$sev|$msg"
}

# Poll for short self-test completion up to max wait time.
poll_short_test_completion() {
    local disk=$1
    local waited=0 info status sev msg
    while (( waited < SHORT_TEST_MAX_WAIT )); do
        info=$(get_latest_selftest_info "$disk")
        if [[ "$info" == "|||" ]]; then
            local exec_status
            if [[ $disk == /dev/nvme* ]]; then
                log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART capability read (-c) on $disk"
                exec_status=$(smartctl -c -d nvme "$disk" 2>/dev/null | awk -F: '/Self-test execution status/ {print $2}') || true
            else
                exec_status=$(smartctl -c "$disk" 2>/dev/null | awk -F: '/Self-test execution status/ {print $2}') || true
            fi
            if echo "$exec_status" | grep -qi 'in progress'; then
                sleep $SHORT_TEST_POLL_INTERVAL
                waited=$(( waited + SHORT_TEST_POLL_INTERVAL ))
                continue
            else
                echo "OK|Self-test log not yet populated"
                return 0
            fi
        fi
        status=$(echo "$info" | awk -F'|' '{print $3}')
        local class
        class=$(classify_selftest_status "$status")
        sev=$(echo "$class" | awk -F'|' '{print $1}')
        msg=$(echo "$class" | awk -F'|' '{print $2}')
        if [[ $sev != INPROGRESS ]]; then
            echo "$sev|$msg"
            return 0
        fi
        sleep $SHORT_TEST_POLL_INTERVAL
        waited=$(( waited + SHORT_TEST_POLL_INTERVAL ))
    done
    echo "INPROGRESS|Short test still running after ${SHORT_TEST_MAX_WAIT}s"
    return 0
}

# Given state and messages, return risk score.
risk_score_quick() {
    local st="$1"; shift
    local msg="$1"; shift
    local score=0
    case "$st" in
        CRITICAL) ((score += W_SEV_CRIT));;
        WARNING)  ((score += W_SEV_WARN));;
    esac
    [[ $msg == *"Pending sectors"* ]] && ((score += W_PENDING))
    [[ $msg == *"Offline Uncorrectable"* || $msg == *"Reported Uncorrectable"* ]] && ((score += W_UNCORR))
    [[ $msg == *"Reallocated ="* ]] && ((score += W_REALLOC))
    [[ $msg == *"Reallocated Event Count"* ]] && ((score += W_REALLOC_EVENTS))
    [[ $msg == *"Command Timeout"* ]] && ((score += W_CMD_TIMEOUT))
    [[ $msg == *"UDMA CRC Errors"* ]] && ((score += W_CRC))
    [[ $msg == *"SSD life remaining"* ]] && ((score += W_SSD_LIFE))
    [[ $msg == *"NVMe wear"* ]] && ((score += W_NVME_WEAR))
    [[ $msg == *"POH age HDD"* ]] && ((score += W_POH_HDD))
    [[ $msg == *"POH age SSD"* ]] && ((score += W_POH_SSD))
    [[ $msg == *"POH age NVMe"* ]] && ((score += W_POH_NVME))
    [[ $msg == *"Btrfs device errors"* ]] && ((score += W_BTRFS_DEV_ERR))
    [[ $msg == *"XFS metadata anomalies"* ]] && ((score += W_XFS_META_ERR))
    [[ $msg == *"Temp"* ]] && ((score += W_TEMP))
    [[ $msg == *"End-to-End Errors"* ]] && ((score += W_E2E))
    [[ $msg == *"Soft Read Error Rate"* ]] && ((score += W_SOFT_READ))
    [[ $msg == *"read-only mode"* ]] && ((score += W_NVME_RO))
    [[ $msg == *"reliability degraded"* ]] && ((score += W_NVME_REL))
    echo "$score"
}

# Check if disk is available for testing
run_smart_test() {
    local disk=$1
    if [[ $disk == /dev/sd* ]]; then
        local pstate
        pstate=$(hdparm -C "$disk" 2>/dev/null | awk -F: '/state is/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print tolower($2)}')
        if echo "$pstate" | grep -qi "standby"; then
            log_info "Spinning up disk $disk (standby -> active) via hdparm -I"
        fi
        hdparm -I "$disk" >/dev/null 2>&1 || true
    fi
    local flag="-t short"
    local selftest poh_attr current_poh last_long_hours_diff="" last_long_poh="" threshold_hours=$(( SMART_INTERVAL_DAYS * 24 ))
    if [[ $disk == /dev/nvme* ]]; then
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART self-test log read (-l selftest) on $disk"
        selftest=$(smartctl -l selftest -d nvme "$disk" 2>/dev/null || true)
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART attribute read (-a) on $disk"
        poh_attr=$(smartctl -a -d nvme "$disk" 2>/dev/null | awk -F: '/Power On Hours/ {gsub(/ /,"",$2); print $2; exit}')
    else
        selftest=$(smartctl -l selftest "$disk" 2>/dev/null || true)
        poh_attr=$(smartctl -A "$disk" 2>/dev/null | awk '/Power_On_Hours/ {print $10; exit}')
    fi
    current_poh=${poh_attr:-0}
    last_long_poh=$(echo "$selftest" | awk 'NR>5 && /Extended offline|Extended self-test|Long/ && $1 ~ /^[0-9]+$/ {for(i=1;i<=NF;i++){if($i ~ /^[0-9]+$/ && $(i+1) ~ /^-/){print $i; break}}}' | head -n1)
    if [[ -z "$last_long_poh" ]]; then
        last_long_poh=$(echo "$selftest" | awk 'NR>5 && /Extended offline|Long/ && $1 ~ /^[0-9]+$/ {for(i=NF;i>=1;i--){if($i ~ /^[0-9]+$/){print $i; break}}}' | head -n1)
    fi
    if [[ -n "$last_long_poh" && $current_poh -gt 0 ]]; then
        last_long_hours_diff=$(( current_poh - last_long_poh ))
    fi

    if [[ "$SMART_TEST_TYPE" == "long" ]]; then
        if [[ -z "$last_long_hours_diff" || "$last_long_hours_diff" -ge $threshold_hours ]]; then
            flag="-t long"
        else
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Skip long on $disk (interval ${last_long_hours_diff}h < ${threshold_hours}h)"
        fi
    fi

    if (( ADAPTIVE_LONG_TEST_ENABLED == 1 )) && [[ $flag == "-t short" ]]; then
        local pre state msgs risk adaptive_reason="" prev_risk=""
        pre=$(evaluate_smart "$disk")
        state=$(echo "$pre" | head -n1)
        msgs=$(echo "$pre" | tail -n +2 | tr '\n' '; ')
        risk=$(risk_score_quick "$state" "$msgs")
        prev_risk=${PREV_RISK["$disk"]:-}
        local crit_age_hours=$(( LONG_TEST_CRITICAL_MIN_DAYS * 24 ))
        local risk_age_hours=$(( LONG_TEST_RISK_MIN_DAYS * 24 ))
        if [[ "$state" == CRITICAL && ( -z "$last_long_hours_diff" || "$last_long_hours_diff" -ge $crit_age_hours ) ]]; then
            flag="-t long"; adaptive_reason="critical SMART state"
        elif (( risk >= LONG_TEST_RISK_THRESHOLD )) && [[ -z "$last_long_hours_diff" || "$last_long_hours_diff" -ge $risk_age_hours ]]; then
            if [[ -z "$prev_risk" || $risk -gt $prev_risk ]]; then
                flag="-t long"; adaptive_reason="risk score $risk (prev ${prev_risk:-none}) >= threshold $LONG_TEST_RISK_THRESHOLD rising"
            fi
        fi
        if [[ -n "$adaptive_reason" ]]; then
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Adaptive LONG test escalation on $disk: $adaptive_reason (last long diff=${last_long_hours_diff:-N/A}h)"
            ADAPTIVE_DECISIONS+="$disk: $adaptive_reason (risk=$risk prev=${prev_risk:-none} last_long_hours=${last_long_hours_diff:-N/A})\n"
            if (( ADAPTIVE_ALERTS_ENABLED == 1 )); then
                if [[ "$adaptive_reason" == critical* ]]; then
                    record_alert critical "Adaptive SMART" "Disk $disk adaptive escalation (critical state; long test forced; risk=$risk prev=${prev_risk:-none})"
                else
                    record_alert warning "Adaptive SMART" "Disk $disk adaptive escalation (rising risk $risk >= $LONG_TEST_RISK_THRESHOLD; long test scheduled)"
                fi
            fi
        fi
    fi

    local exec_status existing_in_progress=0
    if [[ $disk == /dev/nvme* ]]; then
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART capability read (-c) on $disk"
        exec_status=$(smartctl -c -d nvme "$disk" 2>/dev/null | awk -F: '/Self-test execution status/ {print $2}') || true
    else
        exec_status=$(smartctl -c "$disk" 2>/dev/null | awk -F: '/Self-test execution status/ {print $2}') || true
    fi
    if echo "$exec_status" | grep -qi 'in progress'; then
        existing_in_progress=1
    fi
    if [[ $existing_in_progress -eq 1 ]]; then
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Self-test already in progress on $disk; skipping new start (status: ${exec_status})"
    else
        if [[ $disk == /dev/nvme* ]]; then
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Starting NVMe SMART test ($flag) on $disk"
            smartctl $flag -d nvme "$disk" >/dev/null 2>&1 || true
        else
            smartctl $flag "$disk" >/dev/null 2>&1 || true
        fi
    fi
    local test_kind=${flag/-t /}
    if [[ $test_kind == short && $SHORT_TEST_POLL -eq 1 && $existing_in_progress -eq 0 ]]; then
        local result
        result=$(poll_short_test_completion "$disk")
        local s sev msg
        sev=$(echo "$result" | awk -F'|' '{print $1}')
        msg=$(echo "$result" | awk -F'|' '{print $2}')
        if [[ $sev != INPROGRESS ]]; then
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - $disk short self-test status: $msg"
            if [[ $sev == WARNING ]]; then
                record_alert warning "$NOTIFY_TITLE_SMART" "Disk $disk short self-test warning: $msg"
            fi
        else
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - $disk short self-test still in progress after wait window"
        fi
    else
        if [[ $existing_in_progress -eq 1 ]]; then
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Skipping poll (different test still running)"
        else
            sleep 5
        fi
    fi
    local state_and_msgs state msgs
    state_and_msgs=$(evaluate_smart "$disk")
    state=$(echo "$state_and_msgs" | head -n1)
    msgs=$(echo "$state_and_msgs" | tail -n +2)
    log_smart "$(date '+%Y-%m-%d %H:%M:%S') - $disk SMART state: $state"
    [[ -n "$msgs" ]] && log_smart "$msgs"
    SMART_STATE["$disk"]="$state"
    SMART_MSGS["$disk"]="$(echo "$msgs" | tr '\n' '; ')"
    if [[ $state == WARNING || $state == CRITICAL ]]; then
        record_alert "$state" "$NOTIFY_TITLE_SMART" "Disk $disk SMART $state: $(echo "$msgs" | tr '\n' ' ')"
    fi
    LAST_TEST[$disk]=$(date '+%Y-%m-%d')
}

# Track NEW markers to avoid duplicates
augment_messages_with_deltas() {
    for disk in "${!SMART_STATE[@]}"; do
        local raw="${SMART_MSGS[$disk]}"
        [[ -z "$raw" ]] && continue
        IFS='; ' read -r -a parts <<< "$raw"
        local augmented=()
        for p in "${parts[@]}"; do
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

# Check completed long SMART tests since last processing
check_completed_long_tests() {
    declare -A PROCESSED
    if [[ -f "$SMART_LONG_STATE_FILE" ]]; then
        while read -r d id; do PROCESSED[$d]="$id"; done < "$SMART_LONG_STATE_FILE"
    fi
    local disks; disks=$(get_all_disks)
    for disk in $disks; do
        local out
        if [[ $disk == /dev/nvme* ]]; then
            log_smart "$(date '+%Y-%m-%d %H:%M:%S') - NVMe SMART self-test log read (-l selftest) on $disk"
            out=$(smartctl -l selftest -d nvme "$disk" 2>/dev/null || true)
        else
            out=$(smartctl -l selftest "$disk" 2>/dev/null || true)
        fi
        local line
        line=$(echo "$out" | awk 'NR>5 && /Extended offline|Extended self-test|Long/ && $1 ~ /^[0-9]+$/ {print; exit}')
        [[ -z "$line" ]] && continue
        local id type status
        id=$(echo "$line" | awk '{print $1}')
        type=$(echo "$line" | awk '{for(i=2;i<=NF;i++){if($i ~ /Extended|Long/){print $i; break}}}')
        status=$(echo "$line" | sed -E 's/^\s*[0-9]+\s+[^ ]+\s+[^ ]+\s+//' | sed -E 's/\s+[0-9]+%.*//' )
        if [[ ${PROCESSED[$disk]:-} == "$id" ]]; then
            continue
        fi
        if echo "$status" | grep -qi 'in progress'; then
            continue
        fi
        local class msg sev
        class=$(classify_selftest_status "$status")
        sev=$(echo "$class" | awk -F'|' '{print $1}')
        msg=$(echo "$class" | awk -F'|' '{print $2}')
        if [[ $sev == WARNING ]]; then
            record_alert warning "$NOTIFY_TITLE_SMART" "Disk $disk long self-test warning: $msg"
        elif [[ $sev == CRITICAL ]]; then
            record_alert critical "$NOTIFY_TITLE_SMART" "Disk $disk long self-test CRITICAL: $msg"
        fi
        echo "$disk $id" >> "$SMART_LONG_STATE_FILE.tmp"
    done
    if [[ -f "$SMART_LONG_STATE_FILE.tmp" ]]; then
        awk '{a[$1]=$2} END {for(k in a) print k, a[k]}' "$SMART_LONG_STATE_FILE.tmp" > "$SMART_LONG_STATE_FILE"
        rm -f "$SMART_LONG_STATE_FILE.tmp"
    fi
}

# Monitor Btrfs filesystems for scrub status
monitor_btrfs() {
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
    if [[ $ENABLE_BTRFS_SCRUB -eq 1 ]]; then
        log_btrfs "BTRFS scrubbing starting (${#filtered[@]} mount(s))"
    else
        log_btrfs "BTRFS scrubbing disabled; summarizing last recorded status for ${#filtered[@]} mount(s)"
    fi
    for m in "${filtered[@]}"; do
        local data_raid meta_raid
        data_raid=$(btrfs filesystem df -p "$m" 2>/dev/null | awk -F',' '/Data/ {gsub(/ /,"",$2); print $2; exit}') || true
        meta_raid=$(btrfs filesystem df -p "$m" 2>/dev/null | awk -F',' '/Metadata/ {gsub(/ /,"",$2); print $2; exit}') || true
        data_raid=${data_raid:-UNKNOWN}
        meta_raid=${meta_raid:-UNKNOWN}
        local initial_status
        initial_status=$(btrfs scrub status "$m" 2>/dev/null || true)
        if [[ $ENABLE_BTRFS_SCRUB -eq 1 ]]; then
            if echo "$initial_status" | grep -qi 'running'; then
                log_btrfs "Scrub already running on $m (Data: $data_raid Meta: $meta_raid)"
            else
                log_btrfs "Starting async scrub on $m (Data: $data_raid Meta: $meta_raid)"
                btrfs scrub start "$m" >>"$BTRFS_LOG" 2>&1 || true
            fi
        fi
        local status corrected uncorrectable msg
        status=$(btrfs scrub status "$m" 2>/dev/null || true)
        log_btrfs "Scrub status $m (Data: $data_raid Meta: $meta_raid)"
        while IFS= read -r ln; do
            [[ -z "$ln" ]] && continue
            log_btrfs "$m: $ln"
        done < <(printf "%s" "$status")
        corrected=$(echo "$status" | awk -F'[: ]+' '/corrected errors/ {print $NF; exit}'); corrected=${corrected:-0}
        uncorrectable=$(echo "$status" | awk -F'[: ]+' '/unrecoverable errors/ {print $NF; exit}'); uncorrectable=${uncorrectable:-0}
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
    log_btrfs "Btrfs scrubbing completed"
}

# Monitor XFS filesystems for metadata issues
monitor_xfs() {
    if [[ $ENABLE_XFS_CHECK -eq 1 ]]; then
        log_xfs "$(date '+%Y-%m-%d %H:%M:%S') - XFS checks starting"
    else
        log_xfs "$(date '+%Y-%m-%d %H:%M:%S') - XFS checks disabled"
    fi
    local mountpoints
    mountpoints=$(mount | awk '$5=="xfs" {print $3}')
    for mp in $mountpoints; do
        log_xfs "$(date '+%Y-%m-%d %H:%M:%S') - XFS check $mp"
        if [[ $ENABLE_XFS_CHECK -eq 1 ]]; then
            local dev xfs_out msg
            dev=$(findmnt -n -o SOURCE --target "$mp")
            if [[ -n "$dev" ]]; then
                xfs_out=$(xfs_repair -n "$dev" 2>&1)
                log_xfs "$xfs_out"
                if echo "$xfs_out" | grep -qiE "error|corrupt|fatal"; then
                    msg="CRITICAL: XFS metadata issue on $mp ($dev)"
                    log_xfs "$(date '+%Y-%m-%d %H:%M:%S') - $msg"
                    record_alert critical "$NOTIFY_TITLE_XFS" "$msg"
                fi
            fi
        fi
        if dmesg | tail -n 3000 | grep -qiE "$(basename "$mp").*(XFS|I/O error)|XFS ERROR|xfs_repair"; then
            msg="WARNING: Kernel/XFS I/O messages for $mp"
            log_xfs "$(date '+%Y-%m-%d %H:%M:%S') - $msg"
            record_alert warning "$NOTIFY_TITLE_XFS" "$msg"
        fi
    done
    log_xfs "$(date '+%Y-%m-%d %H:%M:%S') - XFS checks completed"
}

# Evaluate array and pool capacity against thresholds
evaluate_capacity_alerts() {
    if [[ -n "$ARRAY_PERCENT" ]]; then
        if awk -v p="$ARRAY_PERCENT" -v t="$THRESHOLD" 'BEGIN{exit (p>t)?0:1}'; then
            record_alert critical "Array Capacity" "Array usage ${ARRAY_PERCENT}% > ${THRESHOLD}%"
        elif awk -v p="$ARRAY_PERCENT" -v t="$THRESHOLD" -v d="$NEAR_THRESHOLD_DELTA" 'BEGIN{exit (p + d >= t)?0:1}'; then
            record_alert warning "Array Capacity" "Array usage ${ARRAY_PERCENT}% near ${THRESHOLD}%"
        fi
    fi
    if [[ -n "$POOLS_PERCENT" ]]; then
        if awk -v p="$POOLS_PERCENT" -v t="$THRESHOLD" 'BEGIN{exit (p>t)?0:1}'; then
            record_alert critical "Pools Capacity" "Pools usage ${POOLS_PERCENT}% > ${THRESHOLD}%"
        elif awk -v p="$POOLS_PERCENT" -v t="$THRESHOLD" -v d="$NEAR_THRESHOLD_DELTA" 'BEGIN{exit (p + d >= t)?0:1}'; then
            record_alert warning "Pools Capacity" "Pools usage ${POOLS_PERCENT}% near ${THRESHOLD}%"
        fi
    fi
}

# Evaluate mountpoint usage against defined thresholds
evaluate_per_mount_thresholds() {
    local candidates=(/mnt/disk* /mnt/cache /mnt/*)
    declare -A seen
    local uniq=()
    local mp
    for mp in "${candidates[@]}"; do
        [[ -e "$mp" ]] || continue
        [[ -n "${seen[$mp]:-}" ]] && continue
        seen[$mp]=1
        uniq+=("$mp")
    done
    for mp in "${uniq[@]}"; do
        mountpoint -q "$mp" || continue
        local df_line usep
        df_line=$(df -h "$mp" | awk 'NR==2') || continue
        usep=$(echo "$df_line" | awk '{print $5}' | tr -d '%')
        [[ -n "$usep" ]] || continue
        if [[ $usep -ge $CRITICAL_THRESHOLD_PERCENT ]]; then
            record_alert critical "Storage Critical" "$mp usage ${usep}% >= ${CRITICAL_THRESHOLD_PERCENT}%"
        elif [[ $usep -ge $WARN_THRESHOLD_PERCENT ]]; then
            record_alert warning "Storage Warning" "$mp usage ${usep}% >= ${WARN_THRESHOLD_PERCENT}%"
        fi
    done
}

# === Main Execution: SMART tests, filesystem checks, mapping, I/O error scan ===
log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Starting SMART tests ($SMART_TEST_TYPE test type)"
check_completed_long_tests
for disk in $(get_all_disks); do
    run_smart_test "$disk"
done
save_last_test
log_smart "$(date '+%Y-%m-%d %H:%M:%S') - SMART tests completed"
augment_messages_with_deltas
save_nvme_state
monitor_btrfs
log_info "Btrfs: scrub status assessed"
check_btrfs_snapshots() {
# Check btrfs snapshot counts against thresholds.
    local mountpoints
    mountpoints=$(mount | awk '$5=="btrfs" {print $3}')
    for mp in $mountpoints; do
        local list cnt
        list=$(btrfs subvolume list "$mp" 2>/dev/null || true)
        [[ -z "$list" ]] && continue
        cnt=$(printf "%s\n" "$list" | grep -Eio '(^|/)[@.]?snapshots?(/|$)|(^|/)snapshot[^/]*' | wc -l || true)
        if (( cnt >= SNAPSHOT_CRIT )); then
            record_alert critical "$NOTIFY_TITLE_BTRFS" "Critical: $mp snapshot count $cnt >= $SNAPSHOT_CRIT"
        elif (( cnt >= SNAPSHOT_WARN )); then
            record_alert warning "$NOTIFY_TITLE_BTRFS" "Warning: $mp snapshot count $cnt >= $SNAPSHOT_WARN"
        fi
    done
}
check_btrfs_snapshots
log_info "Btrfs: snapshot counts evaluated"
monitor_xfs  # XFS metadata check (if enabled earlier)
log_info "XFS: metadata check completed"
build_mount_device_map  # Populate array mountpoint -> device map
log_info "Mount mapping: devices resolved"

# Scan syslog/dmesg for disk I/O errors, count unique occurrences per device over time window.
scan_syslog_disk_errors() {
    (( IO_ERROR_MONITOR_ENABLED == 1 )) || { IO_ERROR_FREQ_SECTION=""; return 0; }
    local had_e=0
    case $- in *e*) had_e=1; set +e;; esac
    local window_sec=$(( IO_ERROR_WINDOW_MINUTES * 60 ))
    local now_epoch=$(date +%s)
    local cutoff=$(( now_epoch - window_sec ))
    local log_src
    if [[ -f "$IO_ERROR_LOG_FILE" ]]; then
        log_src=$(tail -n 20000 "$IO_ERROR_LOG_FILE" 2>/dev/null || true)
    else
        log_src=$(dmesg 2>/dev/null | tail -n 20000 || true)
    fi
    declare -A HASH_SEEN
    if [[ -f "$IO_ERROR_HISTORY_FILE" ]]; then
        while read -r ts dev hash; do
            [[ -z "$ts" || -z "$dev" || -z "$hash" ]] && continue
            if (( ts >= cutoff )); then
                HASH_SEEN["$dev|$hash"]=$ts
            fi
        done < "$IO_ERROR_HISTORY_FILE"
    fi
    local new_hist="$(mktemp)"
    for key in "${!HASH_SEEN[@]}"; do
        local ts="${HASH_SEEN[$key]}" dv="${key%%|*}" h="${key#*|}"; printf "%s %s %s\n" "$ts" "$dv" "$h" >> "$new_hist"
    done
    while read -r line; do
        [[ "$line" == *"Script aborted"* ]] && continue
        [[ "$line" == *"Disk I/O Alert"* ]] && continue
        if ! grep -qiE 'I/O error|blk_update_request|end_request|failed command: (READ|WRITE)|hard resetting link|link is slow to respond|exception Emask' <<< "$line"; then
            continue
        fi
        local devices=()
        local dev_tokens
        dev_tokens=$(echo "$line" | grep -oE 'sd[a-z]|nvme[0-9]+n[0-9]+' 2>/dev/null || true)
        for tok in $dev_tokens; do
            [[ -n "$tok" ]] && devices+=("/dev/$tok")
        done
        (( ${#devices[@]} == 0 )) && continue
        local ts_part epoch
        ts_part=$(echo "$line" | awk '{print $1" "$2" "$3}')
        if [[ "$ts_part" =~ ^[A-Z][a-z]{2}\ [0-9]{1,2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
            epoch=$(date -d "$ts_part $(date +%Y)" +%s 2>/dev/null || echo "$now_epoch")
        else
            epoch=$now_epoch
        fi
        local hash
        hash=$(echo "$line" | sha1sum | awk '{print $1}')
        for dev in "${devices[@]}"; do
            IO_ERROR_RAW_MAP["$dev"]=$(( ${IO_ERROR_RAW_MAP["$dev"]:-0} + 1 ))
            if (( IO_ERROR_DEDUP_ENABLED == 1 )) && [[ -n "${HASH_SEEN["$dev|$hash"]:-}" ]]; then
                continue
            fi
            HASH_SEEN["$dev|$hash"]=$epoch
            printf "%s %s %s\n" "$epoch" "$dev" "$hash" >> "$new_hist"
            IO_ERROR_UNIQUE_MAP["$dev"]=$(( ${IO_ERROR_UNIQUE_MAP["$dev"]:-0} + 1 ))
        done
    done < <(printf "%s\n" "$log_src")
    mv "$new_hist" "$IO_ERROR_HISTORY_FILE" 2>/dev/null || true
    local lines="" dev
    for dev in "${!IO_ERROR_RAW_MAP[@]}"; do
        local raw=${IO_ERROR_RAW_MAP[$dev]:-0} uniq=${IO_ERROR_UNIQUE_MAP[$dev]:-0} mark="" sev_msg=""
        if (( uniq >= IO_ERROR_CRIT_THRESHOLD )); then
            record_alert critical "$NOTIFY_TITLE_DISKIO" "Disk $dev I/O errors unique $uniq >= $IO_ERROR_CRIT_THRESHOLD (last ${IO_ERROR_WINDOW_MINUTES}m)"
            mark="CRIT"
        elif (( uniq >= IO_ERROR_WARN_THRESHOLD )); then
            record_alert warning "$NOTIFY_TITLE_DISKIO" "Disk $dev I/O errors unique $uniq >= $IO_ERROR_WARN_THRESHOLD (last ${IO_ERROR_WINDOW_MINUTES}m)"
            mark="WARN"
        fi
        lines+=" - $(basename "$dev") raw=$raw unique=$uniq${mark:+ ($mark)}\n"
    done
    if [[ -n "$lines" ]]; then
        IO_ERROR_FREQ_SECTION="I/O Error Frequency (last ${IO_ERROR_WINDOW_MINUTES}m):\n$lines"
    else
        IO_ERROR_FREQ_SECTION=""
    fi
    (( had_e == 1 )) && set -e
}
scan_syslog_disk_errors
evaluate_per_mount_thresholds

# ---------------- Notification Builder ----------------
severity_rank() { case "$1" in CRITICAL) echo 2;; WARNING) echo 1;; *) echo 0;; esac; }
status_word()   { case "$1" in 2) echo "CRITICAL";; 1) echo "WARNING";; *) echo "OK";; esac; }
map_emoji()     { case "$1" in 2) printf "🔴";; 1) printf "🟡";; *) printf "🟢";; esac; }

# Return btrfs Data profile for a mounted path (e.g., RAID1, single, RAID10).
btrfs_data_profile_for_mount() {
    local mp="$1"
    local prof
    prof=$(btrfs filesystem df "$mp" 2>/dev/null | awk -F',' '/^Data/ {gsub(/ /, "", $2); sub(/:.*/, "", $2); print $2; exit}') || true
    echo "$prof"
}

# Return btrfs Metadata profile for a mounted path
btrfs_metadata_profile_for_mount() {
    local mp="$1"
    local prof
    prof=$(btrfs filesystem df "$mp" 2>/dev/null | awk -F',' '/^Metadata/ {gsub(/ /, "", $2); sub(/:.*/, "", $2); print $2; exit}') || true
    echo "$prof"
}

# Condense and sanitize SMART message lists for inline display.
sanitize_smart_for_inline() {
    local raw="${1:-}"; local strip_wear=${2:-0}
    local s
    s=$(printf "%s" "$raw" | sed -E 's/[[:space:]]+/ /g; s/^ +//; s/ +$//')
    if (( strip_wear == 1 )); then
        s=$(printf "%s" "$s" | sed -E 's/NVMe wear [0-9]+%//g; s/SSD life remaining [0-9]+%//g')
    fi
    s=$(printf "%s" "$s" | sed -E 's/TBW ~ [^;]+//g; s/Read ~ [^;]+//g')
    s=$(printf "%s" "$s" | sed -E 's/(^|[, ] )TBW, ~, [0-9]+(\.[0-9]+)?( [A-Za-z]+)?(, |$)/\1/g')
    s=$(printf "%s" "$s" | sed -E 's/(^|, )~(, |$)/\1/g')
    local IFS=';'
    read -r -a parts <<< "$s"
    local out_parts=()
    local part
    for part in "${parts[@]}"; do
        part=$(printf "%s" "$part" | sed -E 's/^ +//; s/ +$//')
        [[ -n "$part" ]] && out_parts+=("$part")
        (( ${#out_parts[@]} >= 3 )) && break
    done
    if (( ${#out_parts[@]} == 0 )); then
        echo ""
        return 0
    fi
    local out
    out=$(printf "%s, " "${out_parts[@]}")
    out=${out%%, }
    out=$(printf "%s" "$out" | sed -E 's/, +, /, /g; s/, ,/, /g; s/ +,/,/g; s/, +/, /g; s/^, +//; s/, +$//')
    echo "$out"
}

# Build storage array and pool usage lines with severity
build_storage_and_disk_lines() {
    # Array
    ARRAY_MAX_SEV=0; POOLS_MAX_SEV=0
    ARRAY_DISK_LINES=""; POOL_LINES=""; POOL_DEVICE_LINES=""; ARRAY_DEVICE_LINES=""
    local -a ARRAY_DEV_INFO=()
    local -a POOL_DEV_INFO=()
    local arr=()
    for d in /mnt/disk*; do [[ -d "$d" ]] || continue; mountpoint -q "$d" || continue; arr+=("$d"); done
    ARRAY_COUNT=${#arr[@]}
    local arr_used=0 arr_size=0
    declare -a ARR_INFO POOL_INFO
    local name usage pct sev driver_part reason_str
    for d in "${arr[@]}"; do
        local line=$(df -B1 "$d" 2>/dev/null | awk 'NR==2') || continue
        local sz=$(echo "$line" | awk '{print $2}') u=$(echo "$line" | awk '{print $3}')
        sz=${sz:-0}; u=${u:-0}
        arr_size=$((arr_size + sz)); arr_used=$((arr_used + u))
        local pct_local=$(awk "BEGIN{ if($sz>0) printf \"%.1f\",($u/$sz)*100; else print 0 }")
        local usage_sev=0
        if (( $(awk "BEGIN{print ($pct_local >= $CRITICAL_THRESHOLD_PERCENT)}") )); then usage_sev=2
        elif (( $(awk "BEGIN{print ($pct_local >= $WARN_THRESHOLD_PERCENT)}") )); then usage_sev=1
        fi
        local dev=$(smart_device_for_mount "$d")
        local sm_state=${SMART_STATE["$dev"]:-OK}
        local sm_msg=${SMART_MSGS["$dev"]:-}
        local sm_rank=$(severity_rank "$sm_state")
        local final_sev=$usage_sev; (( sm_rank > final_sev )) && final_sev=$sm_rank
        (( final_sev > ARRAY_MAX_SEV )) && ARRAY_MAX_SEV=$final_sev
        local sev_word=$(status_word "$final_sev")
        local reasons=()
        if [[ -n "$sm_msg" && "$sm_state" != OK ]]; then
            local sm_inline=$(sanitize_smart_for_inline "$sm_msg" 0)
            [[ -n "$sm_inline" ]] && reasons+=("SMART: $sm_inline")
        fi
        local reason_join=""; if (( ${#reasons[@]} > 0 )); then reason_join=$(printf "%s; " "${reasons[@]}"); reason_join=${reason_join%%; }; fi
        local cap_str="$(human_readable "$u") / $(human_readable "$sz")"
        local drv_part=""
        if (( final_sev > 0 && sm_rank > 0 )); then
            local has_smart=0 has_tbw=0 has_wear=0
            has_smart=1
            if [[ "$sm_msg" == *"TBW"* ]]; then has_tbw=1; fi
            if [[ "$sm_msg" == *"NVMe wear"* || "$sm_msg" == *"SSD life remaining"* ]]; then has_wear=1; fi
            local parts=() sep=""
            (( has_smart==1 )) && parts+=("SMART")
            (( has_tbw==1 )) && parts+=("TBW")
            (( has_wear==1 )) && parts+=("Wear")
            if (( ${#parts[@]} > 0 )); then
                local joined="$(IFS=,; echo "${parts[*]}")"
                drv_part="{driver: ${joined}}"
            fi
        fi
        if (( VERBOSE_OK == 1 || final_sev > 0 )); then
            ARR_INFO+=("$(basename "$d")|$cap_str|$pct_local|$sev_word|$drv_part|$reason_join")
        fi
        if (( sm_rank > 0 )); then
            local model cap wear_info="" msg_inline msg_full="" entry
            model=$(get_device_model "$dev")
            cap=$(get_device_capacity_tb "$dev")
            if [[ "$sm_msg" == *"NVMe wear" ]]; then wear_info=$(echo "$sm_msg" | grep -o 'NVMe wear [0-9]*%' | head -n1)
            elif [[ "$sm_msg" == *"SSD life remaining" ]]; then wear_info=$(echo "$sm_msg" | grep -o 'SSD life remaining [0-9]*%' | head -n1)
            elif [[ "$sm_msg" == *"TBW consumed" ]]; then wear_info=$(echo "$sm_msg" | grep -o 'TBW consumed [0-9]*%' | head -n1)
            elif [[ "$sm_msg" == *"SATA link downshift" ]]; then wear_info="SATA link downshift"
            fi
            msg_inline=$(sanitize_smart_for_inline "$sm_msg" 1)
            msg_full=""; [[ -n "$wear_info" ]] && msg_full+="($wear_info) "; [[ -n "$msg_inline" ]] && msg_full+="SMART: $msg_inline"
            local msg_part=""; [[ -n "$msg_full" ]] && msg_part=" $msg_full"
            entry="$(basename "$dev")|[$(status_word "$sm_rank")]|${cap}TB|$model|${msg_part# }"
            ARRAY_DEV_INFO+=("$entry")
        fi
    done
    ARRAY_TOTAL_BYTES=$arr_size
    ARRAY_USED_BYTES=$arr_used
    if (( arr_size > 0 )); then
        ARRAY_PERCENT=$(awk "BEGIN{printf \"%.1f\", ($arr_used/$arr_size)*100}")
        ARRAY_USED_HR=$(human_readable "$arr_used")
        ARRAY_TOTAL_HR=$(human_readable "$arr_size")
    fi

    # Include parity devices in [Array Disks] when parity is valid
    local pflag="$(parity_clean_flag || true)"
    if [[ "$pflag" == "1" ]]; then
        local ini="/var/local/emhttp/disks.ini"
        if [[ -f "$ini" ]]; then
            # First try direct device mapping
            while IFS=$'\t' read -r sec dev; do
                [[ -z "$sec" || -z "$dev" ]] && continue
                case "$sec" in
                    parity|parity2)
                        local bdev="/dev/$dev"
                        local cap_tb="$(get_device_capacity_tb "$bdev")"
                        local cap_str="0B / ${cap_tb}TB"
                        ARR_INFO+=("${sec}|$cap_str|n/a|OK||")
                        ;;
                esac
            done < <(awk -F= '
                BEGIN{sec=""}
                /^\[(parity|parity2)\]/ {sec=$0; gsub(/^[[]|[]]$/, "", sec); next}
                tolower($1)=="device" && sec!="" {val=$2; gsub(/"/, "", val); sub(/^[ \t]+/, "", val); sub(/[ \t]+$/, "", val); printf "%s\t%s\n", sec, val}
            ' "$ini" 2>/dev/null)
            # Fallback: resolve by-id if needed
            while IFS=$'\t' read -r sec idv; do
                [[ -z "$sec" || -z "$idv" ]] && continue
                case "$sec" in
                    parity|parity2)
                        local resolved
                        resolved=$(readlink -f "/dev/disk/by-id/$idv" 2>/dev/null || true)
                        if [[ -b "$resolved" ]]; then
                            local cap_tb="$(get_device_capacity_tb "$resolved")"
                            local cap_str="0B / ${cap_tb}TB"
                            ARR_INFO+=("${sec}|$cap_str|n/a|OK||")
                        fi
                        ;;
                esac
            done < <(awk -F= '
                BEGIN{sec=""}
                /^\[(parity|parity2)\]/ {sec=$0; gsub(/^[[]|[]]$/, "", sec); next}
                tolower($1)=="id" && sec!="" {val=$2; gsub(/"/, "", val); sub(/^[ \t]+/, "", val); sub(/[ \t]+$/, "", val); printf "%s\t%s\n", sec, val}
            ' "$ini" 2>/dev/null)
        fi
    fi

    # Pools
    local pools=()
    for p in /mnt/*; do
        [[ -d "$p" ]] || continue; mountpoint -q "$p" || continue
        local name=$(basename "$p")
        case "$name" in disk*|user) continue;; esac
        local skip=0; for ex in "${POOL_EXCLUDES[@]}"; do [[ "$name" == "$ex" || "$p" == "$ex" ]] && { skip=1; break; }; done
        (( skip==1 )) && continue
        pools+=("$p")
    done
    POOLS_COUNT=${#pools[@]}
    local pools_used=0 pools_size=0
    for p in "${pools[@]}"; do
        local name line fstype raid_str="" devlist=""
        name=$(basename "$p")
        line=$(df -B1 "$p" 2>/dev/null | awk 'NR==2') || continue
        local sz=$(echo "$line" | awk '{print $2}') u=$(echo "$line" | awk '{print $3}')
        sz=${sz:-0}; u=${u:-0}
        pools_size=$((pools_size + sz)); pools_used=$((pools_used + u))
        local pct=$(awk "BEGIN{ if($sz>0) printf \"%.1f\",($u/$sz)*100; else print 0 }")
        local usage_sev=0
        if (( $(awk "BEGIN{print ($pct >= $CRITICAL_THRESHOLD_PERCENT)}") )); then usage_sev=2
        elif (( $(awk "BEGIN{print ($pct >= $WARN_THRESHOLD_PERCENT)}") )); then usage_sev=1
        fi
        fstype=$(findmnt -n -o FSTYPE "$p" 2>/dev/null || true)
        if [[ "$fstype" == "btrfs" ]]; then
            local prof_data prof_meta raid_parts=()
            prof_data=$(btrfs_data_profile_for_mount "$p")
            prof_meta=$(btrfs_metadata_profile_for_mount "$p")
            [[ -n "$prof_data" ]] && raid_parts+=("DATA:$(echo "$prof_data" | tr '[:lower:]' '[:upper:]')")
            [[ -n "$prof_meta" ]] && raid_parts+=("META:$(echo "$prof_meta" | tr '[:lower:]' '[:upper:]')")
            if (( ${#raid_parts[@]} > 0 )); then
                local pd_up=$(echo "$prof_data" | tr '[:lower:]' '[:upper:]')
                local pm_up=$(echo "$prof_meta" | tr '[:lower:]' '[:upper:]')
                if [[ -n "$pd_up" && -n "$pm_up" && "$pd_up" == "$pm_up" ]]; then
                    raid_str="(${pd_up})"
                else
                    raid_str="(${raid_parts[*]})"
                fi
            fi
            devlist=$(btrfs filesystem show "$p" 2>/dev/null | awk '/devid/ && /path/ {for(i=1;i<=NF;i++){if($i=="path"){print $(i+1)}}}');
            [[ -z "$devlist" ]] && devlist=$(btrfs filesystem show "$p" 2>/dev/null | awk '/devid/ {print $NF}')
        else
            devlist=$(findmnt -n -o SOURCE "$p" 2>/dev/null || true)
            raid_str="(SINGLE)"
        fi

        local pool_dev_max=0 pool_has_wear=0 pool_has_tbw=0 pool_has_smart=0
        for dv in $devlist; do
            local rootdv="$dv"
            if [[ "$rootdv" == /dev/nvme* ]]; then
                rootdv=$(echo "$rootdv" | sed -E 's/p[0-9]+$//')
            else
                rootdv=$(echo "$rootdv" | sed -E 's/[0-9]+$//')
            fi
            local st="${SMART_STATE[$rootdv]:-OK}" msg="${SMART_MSGS[$rootdv]:-}"
            local r=$(severity_rank "$st")
            (( r > pool_dev_max )) && pool_dev_max=$r
            [[ $r -gt 0 ]] && pool_has_smart=1
            if [[ "$msg" == *"NVMe wear"* || "$msg" == *"SSD life remaining"* ]]; then pool_has_wear=1; fi
            if [[ "$msg" == *"TBW exceeds"* || "$msg" == *"TBW ~"* ]]; then pool_has_tbw=1; fi
        done

        local pool_final=$usage_sev
        (( pool_dev_max > pool_final )) && pool_final=$pool_dev_max
        (( pool_final > POOLS_MAX_SEV )) && POOLS_MAX_SEV=$pool_final

        # Build driver tags (SMART/TBW/Wear) for Pool Disks (only if severity > 0)
        local meta_part=""
        if (( pool_final > 0 )); then
            local parts=()
            (( pool_has_smart == 1 )) && parts+=("SMART")
            (( pool_has_tbw   == 1 )) && parts+=("TBW")
            (( pool_has_wear  == 1 )) && parts+=("Wear")
            if (( ${#parts[@]} > 0 )); then
                local joined="$(IFS=,; echo "${parts[*]}")"
                meta_part="{driver: ${joined}}"
            fi
        fi

        if (( VERBOSE_OK == 1 || pool_final > 0 )); then
            local cap_str="$(human_readable "$u") / $(human_readable "$sz")"
            local usage_display="$cap_str"; [[ -n "$raid_str" ]] && usage_display="$cap_str $raid_str"
            POOL_INFO+=("$name|$usage_display|$pct|$(status_word "$pool_final")|$meta_part")
        fi

        if [[ $ENABLE_POOL_DEVICE_SMART -eq 1 ]]; then
            for dv in $devlist; do
                local rootdv="$dv"
                if [[ "$rootdv" == /dev/nvme* ]]; then
                    rootdv=$(echo "$rootdv" | sed -E 's/p[0-9]+$//')
                else
                    rootdv=$(echo "$rootdv" | sed -E 's/[0-9]+$//')
                fi
                POOL_MEMBER_MAP["$rootdv"]="$name"
                local st="${SMART_STATE[$rootdv]:-OK}" msg="${SMART_MSGS[$rootdv]:-}"
                local rank=$(severity_rank "$st")
                if (( rank > 0 )); then
                    local model cap wear_info="" msg_inline msg_full="" entry
                    if [[ -n "$msg" ]]; then
                        model=$(get_device_model "$rootdv")
                        cap=$(get_device_capacity_tb "$rootdv")
                        if [[ "$msg" == *"NVMe wear" ]]; then
                            wear_info=$(echo "$msg" | grep -o 'NVMe wear [0-9]*%' | head -n1)
                        elif [[ "$msg" == *"SSD life remaining"* ]]; then
                            wear_info=$(echo "$msg" | grep -o 'SSD life remaining [0-9]*%' | head -n1)
                        elif [[ "$msg" == *"TBW consumed" ]]; then
                            wear_info=$(echo "$msg" | grep -o 'TBW consumed [0-9]*%' | head -n1)
                        fi
                        msg_inline=$(sanitize_smart_for_inline "$msg" 1)
                        msg_full=""
                        [[ -n "$wear_info" ]] && msg_full+="($wear_info) "
                        [[ -n "$msg_inline" ]] && msg_full+="SMART: $msg_inline"
                        local msg_part=""
                        [[ -n "$msg_full" ]] && msg_part=" $msg_full"
                        entry="$(basename "$rootdv")|[$(status_word "$rank")]|${cap}TB|$model|${msg_part# }"
                        POOL_DEV_INFO+=("$entry")
                    else
                        local model cap
                        model=$(get_device_model "$rootdv")
                        cap=$(get_device_capacity_tb "$rootdv")
                        entry="$(basename "$rootdv")|[$(status_word "$rank")]|${cap}TB|$model|"
                        POOL_DEV_INFO+=("$entry")
                    fi
                fi
            done
        fi
    done
    POOLS_TOTAL_BYTES=$pools_size
    POOLS_USED_BYTES=$pools_used
    if (( pools_size > 0 )); then
        POOLS_PERCENT=$(awk "BEGIN{printf \"%.1f\", ($pools_used/$pools_size)*100}")
        POOLS_USED_HR=$(human_readable "$pools_used")
        POOLS_TOTAL_HR=$(human_readable "$pools_size")
    fi

    # Persist per-disk capacity usage for growth analysis
    local today=$(date +%Y-%m-%d)
    for d in "${arr[@]}"; do
        local line=$(df -B1 "$d" 2>/dev/null | awk 'NR==2') || continue
        local sz=$(echo "$line" | awk '{print $2}') u=$(echo "$line" | awk '{print $3}')
        echo "$today $(basename \"$d\") used=$u size=$sz" >> "$DISK_CAP_HISTORY_FILE"
    done

    # Adjust group severity (array/pools) with capacity thresholds
    if awk -v p="$ARRAY_PERCENT" -v t="$THRESHOLD" 'BEGIN{exit (p>t)?0:1}'; then ARRAY_MAX_SEV=2
    elif awk -v p="$ARRAY_PERCENT" -v t="$THRESHOLD" -v d="$NEAR_THRESHOLD_DELTA" 'BEGIN{exit (p + d >= t)?0:1}' && [[ $ARRAY_MAX_SEV -lt 1 ]]; then ARRAY_MAX_SEV=1; fi
    if awk -v p="$POOLS_PERCENT" -v t="$THRESHOLD" 'BEGIN{exit (p>t)?0:1}'; then POOLS_MAX_SEV=2
    elif awk -v p="$POOLS_PERCENT" -v t="$THRESHOLD" -v d="$NEAR_THRESHOLD_DELTA" 'BEGIN{exit (p + d >= t)?0:1}' && [[ $POOLS_MAX_SEV -lt 1 ]]; then POOLS_MAX_SEV=1; fi

    local a_emoji=$(map_emoji "$ARRAY_MAX_SEV")
    local p_emoji=$(map_emoji "$POOLS_MAX_SEV")
    local a_word=$(status_word "$ARRAY_MAX_SEV")
    local p_word=$(status_word "$POOLS_MAX_SEV")

    STORAGE_TOP_LINES=$(printf "%s Array %s (%d Disk): %s%% — %s used of %s\n%s Pools %s (%d Disk): %s%% — %s used of %s" \
        "$a_emoji" "$a_word" "$ARRAY_COUNT" "${ARRAY_PERCENT:-0.0}" "${ARRAY_USED_HR:-0 B}" "${ARRAY_TOTAL_HR:-0 B}" \
        "$p_emoji" "$p_word" "$POOLS_COUNT" "${POOLS_PERCENT:-0.0}" "${POOLS_USED_HR:-0 B}" "${POOLS_TOTAL_HR:-0 B}")

    # Dynamic alignment for [Array Disks] and [Pool Disks]
    local NAME_COL_WIDTH=6 USAGE_COL_WIDTH=22 PCT_COL_WIDTH=4 STATUS_COL_WIDTH=7 DRIVER_COL_WIDTH=0 REASON_COL_WIDTH=0
    local tmp_entry
    for tmp_entry in "${ARR_INFO[@]}" "${POOL_INFO[@]}"; do
        [[ -z "$tmp_entry" ]] && continue
        local n u pct sev drv rsn
        n=$(echo "$tmp_entry" | awk -F'|' '{print $1}')
        u=$(echo "$tmp_entry" | awk -F'|' '{print $2}')
        pct=$(echo "$tmp_entry" | awk -F'|' '{print $3}')
        sev=$(echo "$tmp_entry" | awk -F'|' '{print $4}')
        drv=$(echo "$tmp_entry" | awk -F'|' '{print $5}')
        rsn=$(echo "$tmp_entry" | awk -F'|' '{print $6}')
        (( ${#n}   > NAME_COL_WIDTH )) && NAME_COL_WIDTH=${#n}
        (( ${#u}   > USAGE_COL_WIDTH )) && USAGE_COL_WIDTH=${#u}
        (( ${#pct} > PCT_COL_WIDTH )) && PCT_COL_WIDTH=${#pct}
        (( ${#sev} > STATUS_COL_WIDTH )) && STATUS_COL_WIDTH=${#sev}
        drv=${drv# }
        (( ${#drv} > DRIVER_COL_WIDTH )) && DRIVER_COL_WIDTH=${#drv}
        (( ${#rsn} > REASON_COL_WIDTH )) && REASON_COL_WIDTH=${#rsn}
    done
    (( USAGE_COL_WIDTH > 40 )) && USAGE_COL_WIDTH=40
    (( DRIVER_COL_WIDTH > 40 )) && DRIVER_COL_WIDTH=40
    (( REASON_COL_WIDTH > 80 )) && REASON_COL_WIDTH=80
    local fmt_array fmt_pool
    fmt_array="%-${NAME_COL_WIDTH}s %s (%s%%) [%s]%s%s\n"
    fmt_pool="%-${NAME_COL_WIDTH}s %s (%s%%) [%s]%s%s\n"
    ARRAY_DISK_LINES=""
    for tmp_entry in "${ARR_INFO[@]}"; do
        local n u pctv sevw drv rsn
        n=$(echo "$tmp_entry" | awk -F'|' '{print $1}')
        u=$(echo "$tmp_entry" | awk -F'|' '{print $2}')
        pctv=$(echo "$tmp_entry" | awk -F'|' '{print $3}')
        sevw=$(echo "$tmp_entry" | awk -F'|' '{print $4}')
        drv=$(echo "$tmp_entry" | awk -F'|' '{print $5}')
        rsn=$(echo "$tmp_entry" | awk -F'|' '{print $6}')
        drv=${drv# }
        local drv_out="" rsn_out=""
        [[ -n "$drv" ]] && drv_out=" $drv"
        [[ -n "$rsn" ]] && rsn_out=" $rsn"
        printf -v ARRAY_DISK_LINES "%s${fmt_array}" "$ARRAY_DISK_LINES" "$n" "$u" "$pctv" "$sevw" "$drv_out" "$rsn_out"
    done
    POOL_LINES=""
    for tmp_entry in "${POOL_INFO[@]}"; do
        local n u pctv sevw meta rsn
        n=$(echo "$tmp_entry" | awk -F'|' '{print $1}')
        u=$(echo "$tmp_entry" | awk -F'|' '{print $2}')
        pctv=$(echo "$tmp_entry" | awk -F'|' '{print $3}')
        sevw=$(echo "$tmp_entry" | awk -F'|' '{print $4}')
        meta=$(echo "$tmp_entry" | awk -F'|' '{print $5}')
        rsn=$(echo "$tmp_entry" | awk -F'|' '{print $6}')
        meta=${meta# }
        local meta_out="" rsn_out=""
        [[ -n "$meta" ]] && meta_out=" $meta"
        [[ -n "$rsn" ]] && rsn_out=" $rsn"
        printf -v POOL_LINES "%s${fmt_pool}" "$POOL_LINES" "$n" "$u" "$pctv" "$sevw" "$meta_out" "$rsn_out"
    done
    # Dynamic alignment for device detail sections
    if (( ${#ARRAY_DEV_INFO[@]} > 0 )); then
        local DNW=8 DSW=8 DCW=6 DMW=10
        local entry
        for entry in "${ARRAY_DEV_INFO[@]}" "${POOL_DEV_INFO[@]}"; do
            [[ -z "$entry" ]] && continue
            local f1=$(echo "$entry" | awk -F'|' '{print $1}')
            local f2=$(echo "$entry" | awk -F'|' '{print $2}')
            local f3=$(echo "$entry" | awk -F'|' '{print $3}')
            local f4=$(echo "$entry" | awk -F'|' '{print $4}')
            (( ${#f1} > DNW )) && DNW=${#f1}
            (( ${#f2} > DSW )) && DSW=${#f2}
            (( ${#f3} > DCW )) && DCW=${#f3}
            (( ${#f4} > DMW )) && DMW=${#f4}
        done
        (( DMW > 26 )) && DMW=26
        local dev_fmt_pool dev_fmt_array
        dev_fmt_pool="%-${DNW}s %s %s %-${DMW}s %s\n"
        dev_fmt_array="%-${DNW}s %s %s %-${DMW}s %s\n"
        ARRAY_DEVICE_LINES=""
        for entry in "${ARRAY_DEV_INFO[@]}"; do
            local f1=$(echo "$entry" | awk -F'|' '{print $1}')
            local f2=$(echo "$entry" | awk -F'|' '{print $2}')
            local f3=$(echo "$entry" | awk -F'|' '{print $3}')
            local f4=$(echo "$entry" | awk -F'|' '{print $4}')
            local f5=$(echo "$entry" | awk -F'|' '{print $5}')
            printf -v ARRAY_DEVICE_LINES "%s${dev_fmt_array}" "$ARRAY_DEVICE_LINES" "$f1" "$f2" "$f3" "$f4" "$f5"
        done
        POOL_DEVICE_LINES=""
        for entry in "${POOL_DEV_INFO[@]}"; do
            local f1=$(echo "$entry" | awk -F'|' '{print $1}')
            local f2=$(echo "$entry" | awk -F'|' '{print $2}')
            local f3=$(echo "$entry" | awk -F'|' '{print $3}')
            local f4=$(echo "$entry" | awk -F'|' '{print $4}')
            local f5=$(echo "$entry" | awk -F'|' '{print $5}')
            printf -v POOL_DEVICE_LINES "%s${dev_fmt_pool}" "$POOL_DEVICE_LINES" "$f1" "$f2" "$f3" "$f4" "$f5"
        done
    fi
}

# Check for discrepancies between array usage and /mnt/user usage
validate_storage_metrics() {
    local user_pct user_line discrepancy_section=""
    if mountpoint -q /mnt/user; then
        user_line=$(df -B1 /mnt/user 2>/dev/null | awk 'NR==2')
        local user_sz=$(echo "$user_line" | awk '{print $2}') user_used=$(echo "$user_line" | awk '{print $3}')
        if [[ -n "$user_sz" && -n "$user_used" ]]; then
            local user_pct_calc=$(awk "BEGIN{ if($user_sz>0) printf \"%.1f\", ($user_used/$user_sz)*100; else print 0 }")
            if [[ -n "$ARRAY_PERCENT" ]]; then
                local diff=$(awk -v a="$ARRAY_PERCENT" -v u="$user_pct_calc" 'BEGIN{d=a-u; if(d<0)d=-d; printf "%.2f", d}')
                if (( $(awk -v d="$diff" 'BEGIN{print (d>=5.0)}') )); then
                    discrepancy_section+="Storage Discrepancy: aggregated array ${ARRAY_PERCENT}% vs /mnt/user ${user_pct_calc}% (diff ${diff}%). Possible share caching or recent deletions not synced.\n"
                fi
            fi
        fi
    fi
    STORAGE_VALIDATION_SECTION="$discrepancy_section"
}

# Summarize subsystem statuses based on collected alerts
build_subsystem_lines() {
    local sm=OK bt=OK xfs=OK cap=OK pm=OK end=OK ad=OK pr=OK
    for a in "${ALERT_CRIT[@]}"; do
        [[ $a == "$NOTIFY_TITLE_SMART"* ]] && sm=CRITICAL
        [[ $a == "$NOTIFY_TITLE_BTRFS"* ]] && bt=CRITICAL
        [[ $a == "$NOTIFY_TITLE_XFS"* ]] && xfs=CRITICAL
        [[ $a == *Capacity* ]] && cap=CRITICAL
        [[ $a == Storage\ Critical* ]] && pm=CRITICAL
        [[ $a == TBW\ Endurance* ]] && end=CRITICAL
        [[ $a == Adaptive\ SMART* ]] && ad=CRITICAL
        [[ $a == Parity\ Status:* ]] && pr=CRITICAL
    done
    for a in "${ALERT_WARN[@]}"; do
        [[ $sm != CRITICAL && $a == "$NOTIFY_TITLE_SMART"* ]] && sm=WARNING
        [[ $bt != CRITICAL && $a == "$NOTIFY_TITLE_BTRFS"* ]] && bt=WARNING
        [[ $xfs != CRITICAL && $a == "$NOTIFY_TITLE_XFS"* ]] && xfs=WARNING
        [[ $cap != CRITICAL && $a == *Capacity* ]] && cap=WARNING
        [[ $pm != CRITICAL && $a == Storage\ Warning* ]] && pm=WARNING
        [[ $end != CRITICAL && $a == TBW\ Endurance* ]] && end=WARNING
        [[ $ad != CRITICAL && $a == Adaptive\ SMART* ]] && ad=WARNING
        [[ $pr != CRITICAL && $a == Parity\ Status:* ]] && pr=WARNING
    done
    SUBSYSTEM_LINES="SMART: $sm
Btrfs: $( [[ $ENABLE_BTRFS_SCRUB -eq 1 ]] && echo "$bt" || echo "Disabled")
XFS:   $( [[ $ENABLE_XFS_CHECK -eq 1 ]] && echo "$xfs" || echo "Disabled")
Capacity: $cap
Per-Mount: $pm
Endurance: $end
Adaptive: $ad
Parity: $pr"
}

# Build recommended actions based on alert messages
build_recommendations() {
    local rec=""
    if (( ${#ALERT_WARN[@]} + ${#ALERT_CRIT[@]} > 0 )); then
        rec+="Recommended actions:\n"
        for x in "${ALERT_CRIT[@]}" "${ALERT_WARN[@]}"; do
            local disk_ref mnt_ref
            disk_ref=$(echo "$x" | grep -o '/dev/[a-zA-Z0-9]*' | head -n1 || true)
            mnt_ref=$(echo "$x" | grep -o '/mnt/[a-zA-Z0-9_-]*' | head -n1 || true)
            local friendly="$disk_ref"
            if [[ -n "$disk_ref" ]]; then
                local bdev="$(base_device "$disk_ref")"
                local arr_slot="" pool_name=""
                local k
                for k in "${!MOUNT_TO_DEV[@]}"; do
                    if [[ "$k" == /mnt/disk* ]]; then
                        local mdev="${MOUNT_TO_DEV[$k]}"
                        local bmdev="$(base_device "$mdev")"
                        if [[ "$bmdev" == "$bdev" ]]; then arr_slot="$(basename "$k")"; break; fi
                    fi
                done
                if [[ -n "${POOL_MEMBER_MAP[$bdev]:-}" ]]; then pool_name="${POOL_MEMBER_MAP[$bdev]}"; fi
                if [[ -n "$arr_slot" ]]; then
                    friendly="$arr_slot:$(basename "$bdev")"
                elif [[ -n "$pool_name" ]]; then
                    friendly="${pool_name}:$(basename "$bdev")"
                else
                    friendly="$(basename "$bdev")"
                fi
            fi
            local display_friendly="$friendly"
            if [[ "$friendly" == *:* ]]; then
                local left="${friendly%%:*}" right="${friendly##*:}"
                display_friendly="${left} [${right}]"
            fi
            case "$x" in
                *"Btrfs device errors"*)
                    [[ -n "$friendly" ]] && rec+=" - $display_friendly: Btrfs device error counters increased; run scrub, inspect cables, consider replacing device if trend continues.\n" ;; 
                *"XFS metadata anomalies"*)
                    [[ -n "$friendly" ]] && rec+=" - $display_friendly: XFS metadata/stat anomaly; schedule offline check (xfs_repair -n) and verify backups.\n" ;;
                *"POH age HDD"*)
                    if echo "$x" | grep -qi 'SMART CRITICAL'; then
                        [[ -n "$friendly" ]] && rec+=" - $display_friendly: Critical HDD power-on hours; schedule replacement window and ensure backups are current.\n"
                    else
                        [[ -n "$friendly" ]] && rec+=" - $display_friendly: Elevated HDD power-on hours; monitor closely and plan refresh.\n"
                    fi ;;
                *"POH age SSD"*)
                    if echo "$x" | grep -qi 'SMART CRITICAL'; then
                        [[ -n "$friendly" ]] && rec+=" - $display_friendly: Critical SSD power-on hours; migrate workloads and replace soon.\n"
                    else
                        [[ -n "$friendly" ]] && rec+=" - $display_friendly: Elevated SSD power-on hours; plan maintenance window and review TBW/endurance.\n"
                    fi ;;
                *"POH age NVMe"*)
                    if echo "$x" | grep -qi 'SMART CRITICAL'; then
                        [[ -n "$friendly" ]] && rec+=" - $display_friendly: Critical NVMe power-on hours; schedule replacement and validate firmware health.\n"
                    else
                        [[ -n "$friendly" ]] && rec+=" - $display_friendly: Elevated NVMe power-on hours; plan refresh and monitor performance/SMART.\n"
                    fi ;;
                *"Reallocated"*)
                    [[ -n "$friendly" ]] && rec+=" - $display_friendly: Reallocated sectors rising; monitor; replace if trend increases.\n" ;;
                *"Pending sectors"*)
                    [[ -n "$friendly" ]] && rec+=" - $display_friendly: Pending sectors; backup; run long test; plan replacement.\n" ;;
                *"Offline Uncorrectable"*)
                    [[ -n "$friendly" ]] && rec+=" - $display_friendly: Offline uncorrectable; clone and replace soon.\n" ;;
                *"UDMA CRC Errors"*)
                    [[ -n "$friendly" ]] && rec+=" - $display_friendly: CRC errors; reseat/replace SATA cable.\n" ;;
                *"Temp "*C*)
                    [[ -n "$friendly" ]] && rec+=" - $display_friendly: High temperature; improve cooling / airflow.\n" ;;
                *"NVMe wear"*)
                    rec+=" - ${display_friendly:-NVMe}: High NVMe wear level; schedule replacement.\n" ;;
                *"long self-test CRITICAL"*)
                    [[ -n "$friendly" ]] && rec+=" - $display_friendly: Failed long test; migrate data; replace drive.\n" ;;
                *"short self-test warning"*)
                    [[ -n "$friendly" ]] && rec+=" - $display_friendly: Short test warning; run a long test.\n" ;;
                *"unrecoverable errors="*)
                    [[ -n "$mnt_ref" ]] && rec+=" - $mnt_ref (Btrfs): Unrecoverable errors; backup; inspect device(s); rerun scrub.\n" ;;
                *"scrub corrected="*)
                    [[ -n "$mnt_ref" ]] && rec+=" - $mnt_ref (Btrfs): Corrected errors; monitor; consider more frequent scrubs.\n" ;;
                *"XFS metadata issue"*)
                    [[ -n "$mnt_ref" ]] && rec+=" - $mnt_ref (XFS): Metadata issue; schedule offline xfs_repair; backup first.\n" ;;
                *"Array usage "*|*"Pools usage "*)
                    rec+=" - Capacity: Cleanup data or plan expansion (usage threshold crossed).\n" ;;
                *"Storage Warning "*)
                    [[ -n "$mnt_ref" ]] && rec+=" - $mnt_ref: High usage; cleanup or plan expansion.\n" ;;
                *"Storage Critical "*)
                    [[ -n "$mnt_ref" ]] && rec+=" - $mnt_ref: Critical usage; expand immediately or purge data.\n" ;;
                *"Reallocated Event Count"*)
                    [[ -n "$friendly" ]] && rec+=" - $display_friendly: Reallocation events logged; monitor trend; consider replacement if increasing.\n" ;;
                *"Reported Uncorrectable"*)
                    [[ -n "$friendly" ]] && rec+=" - $display_friendly: Uncorrectable errors; backup immediately; plan replacement.\n" ;;
                *"Command Timeout events"*)
                    [[ -n "$friendly" ]] && rec+=" - $display_friendly: Command timeouts; inspect cabling/power; monitor closely.\n" ;;
                *"End-to-End Errors"*)
                    [[ -n "$friendly" ]] && rec+=" - $display_friendly: Data path integrity errors; replace drive/controller.\n" ;;
                *"Soft Read Error Rate"*)
                    [[ -n "$friendly" ]] && rec+=" - $display_friendly: Elevated soft read errors; run long test; monitor trend.\n" ;;
                *"SATA link downshift"*)
                    [[ -n "$friendly" ]] && rec+=" - $display_friendly: Negotiated SATA link speed reduced; reseat/replace cable, test different controller port, verify backplane integrity.\n" ;;
                *"NVMe reliability degraded"*)
                    [[ -n "$friendly" ]] && rec+=" - $display_friendly: NVMe reliability degraded; schedule replacement soon.\n" ;;
                *"NVMe media in read-only mode"*)
                    [[ -n "$friendly" ]] && rec+=" - $display_friendly: NVMe is read-only; clone data; replace immediately.\n" ;;
                *"NVMe volatile memory backup failed"*)
                    [[ -n "$friendly" ]] && rec+=" - $display_friendly: NVMe volatile memory backup failed; ensure power protection; plan replacement.\n" ;;
                *"TBW consumed "*)
                    if echo "$x" | grep -q "TBW consumed .*>= ${TBW_CONSUMED_CRIT}%"; then
                        [[ -n "$friendly" ]] && rec+=" - $display_friendly: SSD endurance nearly exhausted; migrate workloads and replace soon.\n"
                    else
                        [[ -n "$friendly" ]] && rec+=" - $display_friendly: High SSD endurance consumption; reduce writes and plan refresh.\n"
                    fi ;;
                *"TBW Endurance"*)
                    if echo "$x" | grep -qi 'CRITICAL'; then
                        [[ -n "$friendly" ]] && rec+=" - $display_friendly: TBW near exhaustion; schedule replacement and migrate workloads.\n"
                    else
                        [[ -n "$friendly" ]] && rec+=" - $display_friendly: TBW forecast low; reduce write amplification and plan refresh.\n"
                    fi ;;
                *"Adaptive SMART"*)
                    if echo "$x" | grep -qi 'critical'; then
                        [[ -n "$friendly" ]] && rec+=" - $display_friendly: Adaptive escalation due to critical SMART state; perform data backup, review SMART details, consider immediate replacement.\n"
                    else
                        [[ -n "$friendly" ]] && rec+=" - $display_friendly: Adaptive escalation on rising risk; monitor subsequent runs, analyze contributing SMART attributes, schedule proactive diagnostics.\n"
                    fi ;;
                *"I/O errors unique"*)
                    [[ -n "$friendly" ]] && rec+=" - $display_friendly: High I/O error frequency; check SATA/NVMe cabling, power stability, controller logs; consider moving data & replacing if persistent.\n" ;;
            esac
        done
    fi
    # Append storage improvement suggestions if high usage
    local improve=""
    if [[ -n "$ARRAY_PERCENT" ]] && (( $(awk -v p="$ARRAY_PERCENT" 'BEGIN{print (p>=80)}') )); then
        improve+=" - Array >=80%: Identify large stale media; archive or delete.\n"
        improve+=" - Enable per-share cache or move cold data to slower pool.\n"
    fi
    if [[ -n "$POOLS_PERCENT" ]] && (( $(awk -v p="$POOLS_PERCENT" 'BEGIN{print (p>=80)}') )); then
        improve+=" - Pools >=80%: Rebalance data across pools / expand SSD pool.\n"
        improve+=" - Consider compression (Btrfs/ZFS if applicable) for infrequently accessed data.\n"
    fi
    if [[ -n "${CAPACITY_FORECAST:-}" ]] && echo "${CAPACITY_FORECAST:-}" | grep -q 'days to' ; then
        local soon_arr=$(echo "${CAPACITY_FORECAST:-}" | awk -F'Array avg daily growth:' '{print $2}' | awk -F'days to' '{print $2}' | awk '{print $NF}' | tr -d ':')
        local soon_pool=$(echo "${CAPACITY_FORECAST:-}" | awk -F'Pools avg daily growth:' '{print $2}' | awk -F'days to' '{print $2}' | awk '{print $NF}' | tr -d ':')
        :
    fi
    [[ -n "$improve" ]] && rec+="Storage Improvement Suggestions:\n$improve"

    # SMART trend suggestions based on deltas
    if (( PARITY_SUGGEST_ENABLED == 1 )); then
        local trend=""
        declare -A TREND_ADDED
        for dev in "${!SMART_STATE[@]}"; do
            local bdev="$(basename "$dev")"
            local prev_pending=${PREV_ATTR["$dev|pending"]:-}
            local curr_pending=${CUR_ATTR["$dev|pending"]:-}
            if [[ -n "$prev_pending" && -n "$curr_pending" && "$prev_pending" =~ ^[0-9]+$ && "$curr_pending" =~ ^[0-9]+$ ]]; then
                local dp=$(( curr_pending - prev_pending ))
                if (( dp >= PARITY_PENDING_MIN_DELTA && curr_pending > prev_pending )); then
                    trend+=" - $bdev: Pending sectors ${prev_pending}->${curr_pending} (Δ +$dp); schedule parity check & long SMART test.\n"
                    if (( SMART_TREND_ALERTS_ENABLED == 1 )); then
                        record_alert warning "SMART Trend" "Disk $dev pending sectors increased ${prev_pending}->${curr_pending} (+$dp)"
                    fi
                    if [[ -z "${TREND_ADDED["$dev|pending"]:-}" ]]; then
                        rec+=" - $dev: Rising pending sectors; run parity check soon; plan drive swap if growth continues.\n"
                        TREND_ADDED["$dev|pending"]=1
                    fi
                fi
            fi
            local prev_realloc=${PREV_ATTR["$dev|realloc"]:-}
            local curr_realloc=${CUR_ATTR["$dev|realloc"]:-}
            if [[ -n "$prev_realloc" && -n "$curr_realloc" && "$prev_realloc" =~ ^[0-9]+$ && "$curr_realloc" =~ ^[0-9]+$ ]]; then
                local dr=$(( curr_realloc - prev_realloc ))
                if (( dr >= PARITY_REALLOC_MIN_DELTA && curr_realloc > prev_realloc )); then
                    trend+=" - $bdev: Reallocated sectors ${prev_realloc}->${curr_realloc} (Δ +$dr); parity check recommended; monitor closely.\n"
                    if (( SMART_TREND_ALERTS_ENABLED == 1 )); then
                        record_alert warning "SMART Trend" "Disk $dev reallocated sectors increased ${prev_realloc}->${curr_realloc} (+$dr)"
                    fi
                    if [[ -z "${TREND_ADDED["$dev|realloc"]:-}" ]]; then
                        rec+=" - $dev: Rising reallocated sectors; confirm no rapid escalation; schedule long test.\n"
                        TREND_ADDED["$dev|realloc"]=1
                    fi
                fi
            fi
            local prev_rel_evt=${PREV_ATTR["$dev|realloc_events"]:-}
            local curr_rel_evt=${CUR_ATTR["$dev|realloc_events"]:-}
            if [[ -n "$prev_rel_evt" && -n "$curr_rel_evt" && "$prev_rel_evt" =~ ^[0-9]+$ && "$curr_rel_evt" =~ ^[0-9]+$ ]]; then
                local dre=$(( curr_rel_evt - prev_rel_evt ))
                if (( dre >= PARITY_REALLOC_EVT_MIN_DELTA && curr_rel_evt > prev_rel_evt )); then
                    trend+=" - $bdev: Reallocation events ${prev_rel_evt}->${curr_rel_evt} (Δ +$dre); extended SMART test advisable.\n"
                    if (( SMART_TREND_ALERTS_ENABLED == 1 )); then
                        record_alert warning "SMART Trend" "Disk $dev reallocation events increased ${prev_rel_evt}->${curr_rel_evt} (+$dre)"
                    fi
                    if [[ -z "${TREND_ADDED["$dev|realloc_events"]:-}" ]]; then
                        rec+=" - $dev: Rising reallocation events; run long SMART test; track escalation.\n"
                        TREND_ADDED["$dev|realloc_events"]=1
                    fi
                fi
            fi
            local prev_off=${PREV_ATTR["$dev|offunc"]:-}
            local curr_off=${CUR_ATTR["$dev|offunc"]:-}
            if [[ -n "$prev_off" && -n "$curr_off" && "$prev_off" =~ ^[0-9]+$ && "$curr_off" =~ ^[0-9]+$ ]]; then
                local doff=$(( curr_off - prev_off ))
                if (( doff >= PARITY_UNC_MIN_DELTA && curr_off > prev_off )); then
                    trend+=" - $bdev: Offline uncorrectable ${prev_off}->${curr_off} (Δ +$doff); parity check & data backup urgent.\n"
                    if (( SMART_TREND_ALERTS_ENABLED == 1 )); then
                        record_alert warning "SMART Trend" "Disk $dev offline uncorrectable increased ${prev_off}->${curr_off} (+$doff)"
                    fi
                    if [[ -z "${TREND_ADDED["$dev|offunc"]:-}" ]]; then
                        rec+=" - $dev: Offline uncorrectable count rising; backup now; consider immediate replacement.\n"
                        TREND_ADDED["$dev|offunc"]=1
                    fi
                fi
            fi
            local prev_rep_unc=${PREV_ATTR["$dev|reported_uncorr"]:-}
            local curr_rep_unc=${CUR_ATTR["$dev|reported_uncorr"]:-}
            if [[ -n "$prev_rep_unc" && -n "$curr_rep_unc" && "$prev_rep_unc" =~ ^[0-9]+$ && "$curr_rep_unc" =~ ^[0-9]+$ ]]; then
                local dru=$(( curr_rep_unc - prev_rep_unc ))
                if (( dru >= PARITY_UNC_MIN_DELTA && curr_rep_unc > prev_rep_unc )); then
                    trend+=" - $bdev: Reported uncorrectable ${prev_rep_unc}->${curr_rep_unc} (Δ +$dru); schedule parity check; prepare replacement.\n"
                    if (( SMART_TREND_ALERTS_ENABLED == 1 )); then
                        record_alert warning "SMART Trend" "Disk $dev reported uncorrectable increased ${prev_rep_unc}->${curr_rep_unc} (+$dru)"
                    fi
                    if [[ -z "${TREND_ADDED["$dev|reported_uncorr"]:-}" ]]; then
                        rec+=" - $dev: Reported uncorrectable errors rising; clone critical data; replace drive.\n"
                        TREND_ADDED["$dev|reported_uncorr"]=1
                    fi
                fi
            fi
        done
        [[ -n "$trend" ]] && rec+="SMART Trend Suggestions:\n$trend"
    fi

    # Capacity forecast recommendations
    if [[ -n "${ARR_DAYS_TO_THRESHOLD:-}" && "${ARR_DAYS_TO_THRESHOLD}" =~ ^[0-9]+$ ]]; then
        if (( ARR_DAYS_TO_THRESHOLD > 0 && ARR_DAYS_TO_THRESHOLD <= FORECAST_RECOMMEND_DAYS )); then
            rec+=" - Capacity: Array ~${ARR_DAYS_TO_THRESHOLD} days to ${THRESHOLD}% (growth ${ARR_GROWTH_STR:-?}); plan expansion / cleanup.\n"
        fi
    fi
    if [[ -n "${POOL_DAYS_TO_THRESHOLD:-}" && "${POOL_DAYS_TO_THRESHOLD}" =~ ^[0-9]+$ ]]; then
        if (( POOL_DAYS_TO_THRESHOLD > 0 && POOL_DAYS_TO_THRESHOLD <= FORECAST_RECOMMEND_DAYS )); then
            rec+=" - Capacity: Pools ~${POOL_DAYS_TO_THRESHOLD} days to ${THRESHOLD}% (growth ${POOL_GROWTH_STR:-?}); rebalance / add capacity.\n"
        fi
    fi
    # Parity invalid
    if [[ "${PARITY_CLEAN_FLAG:-1}" == "0" ]]; then
        rec+=" - Parity: invalid; run non-correcting parity check then correcting if errors found.\n"
    fi
    # Risk trend deltas using last two history lines
    if [[ -f "$RISK_TIER_HISTORY_FILE" ]]; then
        local last_two
        last_two=$(tail -n 2 "$RISK_TIER_HISTORY_FILE" 2>/dev/null || true)
        local line1 line2
        line1=$(echo "$last_two" | head -n1)
        line2=$(echo "$last_two" | tail -n1)
        if [[ -n "$line1" && -n "$line2" && "$line1" != "$line2" ]]; then
            local r1 r2 m1 m2
            r1=$(echo "$line1" | awk '{for(i=1;i<=NF;i++){if($i ~ /^replace=/){sub(/replace=/,"",$i);print $i}}}')
            r2=$(echo "$line2" | awk '{for(i=1;i<=NF;i++){if($i ~ /^replace=/){sub(/replace=/,"",$i);print $i}}}')
            m1=$(echo "$line1" | awk '{for(i=1;i<=NF;i++){if($i ~ /^monitor=/){sub(/monitor=/,"",$i);print $i}}}')
            m2=$(echo "$line2" | awk '{for(i=1;i<=NF;i++){if($i ~ /^monitor=/){sub(/monitor=/,"",$i);print $i}}}')
            [[ -z "$r1" ]] && r1=0; [[ -z "$r2" ]] && r2=0; [[ -z "$m1" ]] && m1=0; [[ -z "$m2" ]] && m2=0
            local dr=$(( r2 - r1 )) dm=$(( m2 - m1 ))
            if (( dr >= RISK_TREND_REPLACE_DELTA_MIN )); then
                rec+=" - Risk trend: Replace-tier +$dr since prior sample; prioritize replacements.\n"
            fi
            if (( dm >= RISK_TREND_MONITOR_DELTA_MIN )); then
                rec+=" - Risk trend: Monitor-tier +$dm; review SMART and schedule diagnostics.\n"
            fi
        fi
    fi
    # Per-disk risk score recommendations (top N)
    declare -A ADDED_REC_DEVICE
    if declare -p RISK_MAP &>/dev/null; then
        local scored_list idx=0
        scored_list=$(for d in "${!RISK_MAP[@]}"; do echo "${RISK_MAP[$d]} $d"; done | sort -nr -k1,1)
        while read -r sc dv; do
            [[ -z "$dv" ]] && continue
            local bdev="$(base_device "$dv")"
            local arr_slot="" pool_name="" k
            for k in "${!MOUNT_TO_DEV[@]}"; do
                if [[ "$k" == /mnt/disk* ]]; then
                    local mdev="${MOUNT_TO_DEV[$k]}" bmdev="$(base_device "$mdev")"
                    if [[ "$bmdev" == "$bdev" ]]; then arr_slot="$(basename "$k")"; break; fi
                fi
            done
            if [[ -n "${POOL_MEMBER_MAP[$bdev]:-}" ]]; then pool_name="${POOL_MEMBER_MAP[$bdev]}"; fi
            local tag
            if [[ -n "$arr_slot" ]]; then tag="$arr_slot [$(basename "$bdev")]"; elif [[ -n "$pool_name" ]]; then tag="$pool_name [$(basename "$bdev")]"; else tag="$(basename "$bdev")"; fi
            local bucket="${RISK_BUCKET_MAP[$dv]:-}"
            if [[ -n "$bucket" && -z "${ADDED_REC_DEVICE[$dv]:-}" ]]; then
                case "$bucket" in
                    replace) rec+=" - $tag: High risk score ${sc}; clone/migrate data and replace.\n" ;;
                    monitor) rec+=" - $tag: Elevated risk score ${sc}; run long SMART test; monitor trend.\n" ;;
                esac
                ADDED_REC_DEVICE[$dv]=1
            fi
            (( ++idx >= RISK_TOP_N )) && break
        done < <(printf "%s\n" "$scored_list")
    fi
    # Lifecycle bucket summaries (concise)
    if declare -p REPLACE_LIST &>/dev/null; then
        local rcnt=${#REPLACE_LIST[@]}
        if (( rcnt > 0 )); then
            local list_show=("${REPLACE_LIST[@]:0:LIFECYCLE_RECOMMEND_TOP_N}")
            rec+=" - Lifecycle: Replace Soon (${rcnt}) -> ${list_show[*]}\n"
        fi
    fi
    if declare -p MONITOR_LIST &>/dev/null; then
        local mcnt=${#MONITOR_LIST[@]}
        if (( mcnt > 0 )); then
            local list_show=("${MONITOR_LIST[@]:0:LIFECYCLE_RECOMMEND_TOP_N}")
            rec+=" - Lifecycle: Monitor (${mcnt}) -> ${list_show[*]}\n"
        fi
    fi
    RECOMMEND_SECTION="$rec"
}

# Build notification subject line
build_subject() {
    SUBJECT="Disks Health"
}

# Summarize disk health states
build_disk_health_summary() {
    local crit_count=0 warn_count=0 pending_count=0 uncorrect_count=0 high_temp=0 nvme_wear_warn=0 read_only=0 reliability=0 timeout_warn=0 realloc_events_warn=0 end2end_count=0 soft_read_warn=0
    local selftest_crit=0 selftest_warn=0
    local poh_hdd=0 poh_ssd=0 poh_nvme=0
    local btrfs_dev_errs=0 xfs_meta_anoms=0 sata_link_down=0 tbw_consumed_warn=0 tbw_consumed_crit=0
    for dev in "${!SMART_STATE[@]}"; do
        local st="${SMART_STATE[$dev]:-OK}" msg="${SMART_MSGS[$dev]:-}"
        if [[ $st == CRITICAL ]]; then ((++crit_count)); fi
        if [[ $st == WARNING ]]; then ((++warn_count)); fi
        if [[ $msg == *"Pending sectors"* ]]; then ((++pending_count)); fi
        if [[ $msg == *"Offline Uncorrectable"* || $msg == *"Reported Uncorrectable"* ]]; then ((++uncorrect_count)); fi
        if [[ $msg == *"Temp"* ]]; then ((++high_temp)); fi
        if [[ $msg == *"NVMe wear"* ]]; then ((++nvme_wear_warn)); fi
        if [[ $msg == *"read-only mode"* ]]; then ((++read_only)); fi
        if [[ $msg == *"reliability degraded"* ]]; then ((++reliability)); fi
        if [[ $msg == *"Command Timeout"* ]]; then ((++timeout_warn)); fi
        if [[ $msg == *"Reallocated Event Count"* ]]; then ((++realloc_events_warn)); fi
        if [[ $msg == *"End-to-End Errors"* ]]; then ((++end2end_count)); fi
        if [[ $msg == *"Soft Read Error Rate"* ]]; then ((++soft_read_warn)); fi
        if [[ $msg == *"POH age HDD"* ]]; then ((++poh_hdd)); fi
        if [[ $msg == *"POH age SSD"* ]]; then ((++poh_ssd)); fi
        if [[ $msg == *"POH age NVMe"* ]]; then ((++poh_nvme)); fi
        if [[ $msg == *"Btrfs device errors"* ]]; then ((++btrfs_dev_errs)); fi
        if [[ $msg == *"XFS metadata anomalies"* ]]; then ((++xfs_meta_anoms)); fi
        if [[ $msg == *"SATA link downshift"* ]]; then ((++sata_link_down)); fi
        if [[ $msg == *"TBW consumed"* ]]; then
            if echo "$msg" | grep -q "TBW consumed .*>= ${TBW_CONSUMED_CRIT}%"; then ((++tbw_consumed_crit)); else ((++tbw_consumed_warn)); fi
        fi
        if [[ $msg == *"Self-test critical"* ]]; then ((++selftest_crit)); fi
        if [[ $msg == *"Self-test warning"* ]]; then ((++selftest_warn)); fi
    done
    CRIT_DISK_COUNT=$crit_count
    WARN_DISK_COUNT=$warn_count
    local lines=("Disk Health Summary:")
    local add_line
    add_line() { local k="$1"; local v="$2"; if (( SHOW_ZERO_COUNTS==1 )) || (( v>0 )); then lines+=(" - $k: $v"); fi; }
    add_line "Critical" "$crit_count"
    add_line "Warning" "$warn_count"
    local parity_invalid=0
    if [[ "${PARITY_CLEAN_FLAG:-}" == "0" ]]; then parity_invalid=1; fi
    add_line "Parity invalid" "$parity_invalid"
    add_line "Pending sectors" "$pending_count"
    add_line "Uncorrectable errors" "$uncorrect_count"
    add_line "High temp" "$high_temp"
    add_line "NVMe wear" "$nvme_wear_warn"
    add_line "NVMe read-only" "$read_only"
    add_line "NVMe reliability" "$reliability"
    add_line "Command timeouts" "$timeout_warn"
    add_line "Reallocation events" "$realloc_events_warn"
    add_line "End-to-end errors" "$end2end_count"
    add_line "Soft read errors" "$soft_read_warn"
    add_line "POH age HDD" "$poh_hdd"
    add_line "POH age SSD" "$poh_ssd"
    add_line "POH age NVMe" "$poh_nvme"
    add_line "Btrfs device errors" "$btrfs_dev_errs"
    add_line "XFS metadata anomalies" "$xfs_meta_anoms"
    add_line "SATA link downshift" "$sata_link_down"
    add_line "TBW consumed critical" "$tbw_consumed_crit"
    add_line "TBW consumed warning" "$tbw_consumed_warn"
    add_line "Self-test critical" "$selftest_crit"
    add_line "Self-test warning" "$selftest_warn"
    if (( ${#lines[@]} == 1 )); then
        lines+=(" - No issues detected")
    fi
    DISK_HEALTH_SUMMARY="$(printf "%s\n" "${lines[@]}")"
}

# Compute risk scores for disks based on SMART attributes and categorize into lifecycle buckets
compute_risk_and_lifecycle() {
    (( RISK_SCORING_ENABLED == 1 )) || return 0
    local risk_lines="" lifecycle_lines="" age_lines=""
    declare -g -A RISK_MAP RISK_BUCKET_MAP AGE_CLASS
    declare -A RISK SCORE_ATTR
    for dev in "${!SMART_STATE[@]}"; do
        local st="${SMART_STATE[$dev]:-OK}" msg="${SMART_MSGS[$dev]:-}"
        local score=0
        case "$st" in
            CRITICAL) ((score += W_SEV_CRIT));;
            WARNING)  ((score += W_SEV_WARN));;
        esac
        if [[ $msg == *"Pending sectors"* ]]; then ((score += W_PENDING)); fi
        if [[ $msg == *"Offline Uncorrectable"* || $msg == *"Reported Uncorrectable"* ]]; then ((score += W_UNCORR)); fi
        if [[ $msg == *"Reallocated ="* ]]; then ((score += W_REALLOC)); fi
        if [[ $msg == *"Reallocated Event Count"* ]]; then ((score += W_REALLOC_EVENTS)); fi
        if [[ $msg == *"Command Timeout"* ]]; then ((score += W_CMD_TIMEOUT)); fi
        if [[ $msg == *"UDMA CRC Errors"* ]]; then ((score += W_CRC)); fi
        if [[ $msg == *"SSD life remaining"* ]]; then ((score += W_SSD_LIFE)); fi
        if [[ $msg == *"NVMe wear"* ]]; then ((score += W_NVME_WEAR)); fi
        if [[ $msg == *"POH age HDD"* ]]; then ((score += W_POH_HDD)); fi
        if [[ $msg == *"POH age SSD"* ]]; then ((score += W_POH_SSD)); fi
        if [[ $msg == *"POH age NVMe"* ]]; then ((score += W_POH_NVME)); fi
        if [[ $msg == *"Btrfs device errors"* ]]; then ((score += W_BTRFS_DEV_ERR)); fi
        if [[ $msg == *"XFS metadata anomalies"* ]]; then ((score += W_XFS_META_ERR)); fi
        if [[ $msg == *"SATA link downshift"* ]]; then ((score += W_SATA_LINK_DOWN)); fi
        if [[ $msg == *"Self-test critical"* || $msg == *"long self-test CRITICAL"* ]]; then ((score += W_SELFTEST_CRIT)); fi
        if [[ $msg == *"Self-test warning"* || $msg == *"short self-test warning"* ]]; then ((score += W_SELFTEST_WARN)); fi
        if [[ $msg == *"Temp"* ]]; then ((score += W_TEMP)); fi
        if [[ $msg == *"End-to-End Errors"* ]]; then ((score += W_E2E)); fi
        if [[ $msg == *"Soft Read Error Rate"* ]]; then ((score += W_SOFT_READ)); fi
        if [[ $msg == *"read-only mode"* ]]; then ((score += W_NVME_RO)); fi
        if [[ $msg == *"reliability degraded"* ]]; then ((score += W_NVME_REL)); fi
        local poh=0 percent_used=0 life_remain=0
        if [[ $dev == /dev/nvme* ]]; then
            percent_used=${CUR_ATTR["$dev|nvme_percent_used"]:-0}
            poh=${CUR_ATTR["$dev|poh"]:-0}
            if (( percent_used >= 90 )); then ((score += W_AGE_NEAR)); AGE_CLASS[$dev]="Near endurance"; fi
        else
            poh=${CUR_ATTR["$dev|poh"]:-0}
            life_remain=${CUR_ATTR["$dev|life_remain"]:-0}
            if [[ $life_remain -gt 0 && $life_remain -le 10 ]]; then ((score += W_AGE_NEAR)); AGE_CLASS[$dev]="Near endurance"; fi
        fi
        if [[ -n "${CUR_ATTR["$dev|tbw_consumed_pct"]:-}" ]]; then
            local _tc=${CUR_ATTR["$dev|tbw_consumed_pct"]}
            if (( _tc >= TBW_CONSUMED_CRIT )); then ((score += W_TBW_CONS_CRIT));
            elif (( _tc >= TBW_CONSUMED_WARN )); then ((score += W_TBW_CONS_WARN)); fi
        fi
        if (( AGE_AWARE_ENABLED == 1 )); then
            if [[ -n "${AGE_CLASS[$dev]:-}" ]]; then
                age_lines+="$(basename "$dev") (${AGE_CLASS[$dev]}) POH=${poh}"
                age_lines+="\n"
            fi
        fi
        RISK[$dev]=$score
        RISK_MAP[$dev]=$score
    done
    local sorted=$(for d in "${!RISK[@]}"; do echo "${RISK[$d]} $d"; done | sort -nr -k1,1)
    local filtered="$sorted"
    if (( SHOW_ZERO_COUNTS == 0 )); then
        filtered=$(printf "%s\n" "$sorted" | awk '$1>0')
    fi
    local total_count=$(printf "%s\n" "$filtered" | grep -c . || true)
    local idx=0
    while read -r line; do
        [[ -z "$line" ]] && continue
        local sc dv
        sc=$(echo "$line" | awk '{print $1}')
        dv=$(echo "$line" | awk '{print $2}')
        risk_lines+="$(basename "$dv") $sc"
        risk_lines+="\n"
        ((++idx))
        (( idx >= RISK_TOP_N )) && break
    done < <(printf "%s\n" "$filtered")
    if (( total_count > idx )); then
        local more=$(( total_count - idx ))
        (( more > 0 )) && risk_lines+="(+${more} more)\n"
    fi
    if (( LIFECYCLE_ENABLED == 1 )); then
        local replace=() monitor=() healthy=()
        for d in "${!RISK[@]}"; do
            local s=${RISK[$d]}
            if (( s >= RISK_REPLACE )); then replace+=("$(basename "$d")"); RISK_BUCKET_MAP[$d]="replace"
            elif (( s >= RISK_MONITOR )); then monitor+=("$(basename "$d")"); RISK_BUCKET_MAP[$d]="monitor"
            else healthy+=("$(basename "$d")"); RISK_BUCKET_MAP[$d]="healthy"
            fi
        done
        local lns=()
        if (( SHOW_EMPTY_BUCKETS==1 )) || (( ${#replace[@]} > 0 )); then
            lns+=("Replace Soon (high risk) (${#replace[@]}): ${replace[*]:-none}")
        fi
        if (( SHOW_EMPTY_BUCKETS==1 )) || (( ${#monitor[@]} > 0 )); then
            lns+=("Monitor (elevated risk) (${#monitor[@]}): ${monitor[*]:-none}")
        fi
        if (( SHOW_EMPTY_BUCKETS==1 )) || (( ${#healthy[@]} > 0 )); then
            lns+=("Healthy (low risk) (${#healthy[@]}): ${healthy[*]:-none}")
        fi
        lifecycle_lines+="$(printf "%s\n" "${lns[@]}")"
        REPLACE_COUNT=${#replace[@]}
        MONITOR_COUNT=${#monitor[@]}
        HEALTHY_COUNT=${#healthy[@]}
        declare -g REPLACE_LIST MONITOR_LIST HEALTHY_LIST
        REPLACE_LIST=("${replace[@]}")
        MONITOR_LIST=("${monitor[@]}")
        HEALTHY_LIST=("${healthy[@]}")
    fi
    RISK_SECTION=""
    if (( RISK_SCORING_ENABLED==1 )); then
        if ! { (( SHOW_ZERO_COUNTS==0 )) && [[ -z "$risk_lines" ]]; }; then
            RISK_SECTION+="Risk Scores (top):\n${risk_lines}\n"
        fi
    fi
    if (( LIFECYCLE_ENABLED==1 )); then
        if (( SHOW_EMPTY_BUCKETS==1 )) || [[ -n "$lifecycle_lines" ]]; then
            RISK_SECTION+="\nLifecycle Buckets (disks grouped by urgency):\n${lifecycle_lines}\n"
        fi
    fi
    if (( AGE_AWARE_ENABLED==1 )) && [[ -n "$age_lines" ]]; then RISK_SECTION+="Age Awareness:\n${age_lines}"; fi
}

# Append today's risk tier counts to history file
persist_risk_tier_history() {
    (( RISK_SCORING_ENABLED == 1 )) || return 0
    local today=$(date +%Y-%m-%d)
    local crit=${CRIT_DISK_COUNT:-0} warn=${WARN_DISK_COUNT:-0}
    local replace=${REPLACE_COUNT:-0} monitor=${MONITOR_COUNT:-0} healthy=${HEALTHY_COUNT:-0}
    local tmp=$(mktemp)
    if [[ -f "$RISK_TIER_HISTORY_FILE" ]]; then
        awk -v d="$today" '$1!=d{print}' "$RISK_TIER_HISTORY_FILE" > "$tmp" || true
    fi
    echo "$today critical=$crit warning=$warn replace=$replace monitor=$monitor healthy=$healthy" >> "$tmp"
    mv -f "$tmp" "$RISK_TIER_HISTORY_FILE"
}

# Analyze risk tier history and build trend summary
build_risk_tier_trend_section() {
    (( RISK_SCORING_ENABLED == 1 )) || { RISK_TIER_TREND_SECTION=""; return 0; }
    local lines
    lines=$(tac "$RISK_TIER_HISTORY_FILE" 2>/dev/null | awk '!seen[$1]++ {print}' | head -n 7 | tac)
    [[ -z "$lines" ]] && { RISK_TIER_TREND_SECTION=""; return 0; }
    local count_lines=$(printf "%s\n" "$lines" | grep -c . || true)
    local first last
    first=$(printf "%s\n" "$lines" | head -n1)
    last=$(printf "%s\n" "$lines" | tail -n1)
    local fcrit fwarn freplace fmonitor fhealthy lcrit lwarn lreplace lmonitor lhealthy
    fcrit=$(echo "$first" | awk '{for(i=1;i<=NF;i++){if($i ~ /^critical=/){sub(/critical=/,"",$i);print $i}}}')
    fwarn=$(echo "$first" | awk '{for(i=1;i<=NF;i++){if($i ~ /^warning=/){sub(/warning=/,"",$i);print $i}}}')
    freplace=$(echo "$first" | awk '{for(i=1;i<=NF;i++){if($i ~ /^replace=/){sub(/replace=/,"",$i);print $i}}}')
    fmonitor=$(echo "$first" | awk '{for(i=1;i<=NF;i++){if($i ~ /^monitor=/){sub(/monitor=/,"",$i);print $i}}}')
    fhealthy=$(echo "$first" | awk '{for(i=1;i<=NF;i++){if($i ~ /^healthy=/){sub(/healthy=/,"",$i);print $i}}}')
    lcrit=$(echo "$last" | awk '{for(i=1;i<=NF;i++){if($i ~ /^critical=/){sub(/critical=/,"",$i);print $i}}}')
    lwarn=$(echo "$last" | awk '{for(i=1;i<=NF;i++){if($i ~ /^warning=/){sub(/warning=/,"",$i);print $i}}}')
    lreplace=$(echo "$last" | awk '{for(i=1;i<=NF;i++){if($i ~ /^replace=/){sub(/replace=/,"",$i);print $i}}}')
    lmonitor=$(echo "$last" | awk '{for(i=1;i<=NF;i++){if($i ~ /^monitor=/){sub(/monitor=/,"",$i);print $i}}}')
    lhealthy=$(echo "$last" | awk '{for(i=1;i<=NF;i++){if($i ~ /^healthy=/){sub(/healthy=/,"",$i);print $i}}}')
    for v in fcrit fwarn freplace fmonitor fhealthy lcrit lwarn lreplace lmonitor lhealthy; do
        [[ -n "${!v}" ]] || eval "$v=0"
    done
    local dcrit=$(( lcrit - fcrit ))
    local dwarn=$(( lwarn - fwarn ))
    local dreplace=$(( lreplace - freplace ))
    local dmonitor=$(( lmonitor - fmonitor ))
    local dhealthy=$(( lhealthy - fhealthy ))
    local crit_line warn_line replace_line monitor_line healthy_line
    if (( count_lines > 1 )); then
        crit_line="Critical disks (SMART severe): ${fcrit} -> ${lcrit} ($(printf "%+d" $dcrit))"
        warn_line="Warning disks (SMART warnings): ${fwarn} -> ${lwarn} ($(printf "%+d" $dwarn))"
        replace_line="Replace-tier (high risk): ${freplace} -> ${lreplace} ($(printf "%+d" $dreplace))"
        monitor_line="Monitor-tier (elevated risk): ${fmonitor} -> ${lmonitor} ($(printf "%+d" $dmonitor))"
        healthy_line="Healthy-tier (low risk): ${fhealthy} -> ${lhealthy} ($(printf "%+d" $dhealthy))"
    else
        crit_line="Critical disks (SMART severe): ${lcrit} (no prior data)"
        warn_line="Warning disks (SMART warnings): ${lwarn} (no prior data)"
        replace_line="Replace-tier (high risk): ${lreplace} (no prior data)"
        monitor_line="Monitor-tier (elevated risk): ${lmonitor} (no prior data)"
        healthy_line="Healthy-tier (low risk): ${lhealthy} (no prior data)"
    fi
    RISK_TIER_TREND_SECTION="Risk Tier Trend (last ${count_lines} samples, max 7):\n ${crit_line}\n ${warn_line}\n ${replace_line}\n ${monitor_line}\n ${healthy_line}\n"
}

# Compute share usage breakdown and growth trends
compute_share_breakdown() {
    (( SHARE_BREAKDOWN_ENABLED == 1 )) || { SHARE_SECTION=""; return 0; }
    local root="/mnt/user"
    [[ -d "$root" ]] || { SHARE_SECTION=""; return 0; }
    local today=$(date +%Y-%m-%d)
    local shares=()
    while IFS= read -r d; do shares+=("$d"); done < <(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    [[ ${#shares[@]} -eq 0 ]] && { SHARE_SECTION=""; return 0; }
    local sizes=()
    local name path bytes
    for path in "${shares[@]}"; do
        name=$(basename "$path")
        bytes=$(du -sb "$path" 2>/dev/null | awk '{print $1}')
        bytes=${bytes:-0}
        sizes+=("$bytes $name")
        echo "$today $name bytes=$bytes" >> "$SHARE_USAGE_HISTORY_FILE"
    done
    local sorted_size=$(printf "%s\n" "${sizes[@]}" | sort -nr -k1,1 | head -n "$SHARE_TOP_N")
    local size_lines=""
    while read -r b n; do
        [[ -z "$n" ]] && continue
        size_lines+=" - $(printf "%-20s" "$n") $(human_readable "$b")\n"
    done < <(printf "%s\n" "$sorted_size")
    local win=$HISTORY_WINDOW_DAYS
    local cutoff=$(date -d "-$win days" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)
    local lines=$(tail -n 50000 "$SHARE_USAGE_HISTORY_FILE" 2>/dev/null || true)
    local tmp=$(mktemp)
    printf "%s\n" "$lines" | awk -v c="$cutoff" '$1>=c{print}' | awk '{s=$2; for(i=3;i<=NF;i++){split($i,a,"="); if(a[1]=="bytes") b=a[2]} if(s!="" && b!=""){print $1,s,b}}' > "$tmp"
    declare -A first_b first_dt last_b last_dt
    while read -r dt s b; do
        if [[ -z "${first_dt[$s]:-}" || "$dt" < "${first_dt[$s]}" ]]; then first_dt[$s]="$dt"; first_b[$s]="$b"; fi
        if [[ -z "${last_dt[$s]:-}" || "$dt" > "${last_dt[$s]}" ]]; then last_dt[$s]="$dt"; last_b[$s]="$b"; fi
    done < "$tmp"
    rm -f "$tmp"
    local growth=()
    for s in "${!last_b[@]}"; do
        local fu=${first_b[$s]:-0} lu=${last_b[$s]:-0}
        if (( lu>0 && fu>=0 && lu>fu )); then
            local days=$(( ( $(date -d "${last_dt[$s]}" +%s 2>/dev/null || date +%s) - $(date -d "${first_dt[$s]}" +%s 2>/dev/null || date +%s) ) / 86400 ))
            (( days<=0 )) && days=1
            local per_day=$(( (lu - fu) / days ))
            growth+=("$per_day $s")
        fi
    done
    local growth_lines=""
    if (( ${#growth[@]} > 0 )); then
        local sorted_g=$(printf "%s\n" "${growth[@]}" | sort -nr -k1,1 | head -n "$SHARE_TOP_N")
        while read -r pd s; do
            [[ -z "$s" ]] && continue
            growth_lines+=" - $(printf "%-20s" "$s") +$(human_readable "$pd")/day\n"
        done < <(printf "%s\n" "$sorted_g")
    fi
    SHARE_SECTION="Top Shares by Size:\n${size_lines}$( [[ -n \"$growth_lines\" ]] && printf "Top Share Growth (last %sd):\n%s" "$win" "$growth_lines" )"
}

# Track capacity usage history, compute growth trends, estimate days to threshold, export JSON
capacity_forecast_and_export() {
    local now_date=$(date +%Y-%m-%d)
    local array_pct="${ARRAY_PERCENT:-0}" pools_pct="${POOLS_PERCENT:-0}"
    echo "$now_date array=$array_pct pools=$pools_pct" >> "$CAPACITY_HISTORY_FILE"
    local arr_prev=() pool_prev=() dates=()
    local lines
    lines=$(tail -n $HISTORY_WINDOW_DAYS "$CAPACITY_HISTORY_FILE" 2>/dev/null || true)
    while read -r l; do
        [[ -z "$l" ]] && continue
        dates+=("$l")
        arr_prev+=("$(echo "$l" | awk -F '[ =]' '{for(i=1;i<=NF;i++){if($i ~ /^array=/){print substr($i,7)}}}')")
        pool_prev+=("$(echo "$l" | awk -F '[ =]' '{for(i=1;i<=NF;i++){if($i ~ /^pools=/){print substr($i,7)}}}')")
    done < <(printf "%s\n" "$lines")
    local arr_growth=0 pool_growth=0 count=${#arr_prev[@]}
    if (( count > 1 )); then
        if (( DYNAMIC_GROWTH == 1 )); then
            local first_line="${dates[0]}" last_line="${dates[$((count-1))]}"
            local first_date="${first_line%% *}" last_date="${last_line%% *}"
            local first_arr="${arr_prev[0]}" last_arr="${arr_prev[$((count-1))]}"
            local first_pool="${pool_prev[0]}" last_pool="${pool_prev[$((count-1))]}"
            if [[ $first_arr =~ ^[0-9.]+$ && $last_arr =~ ^[0-9.]+$ ]]; then
                local days_elapsed=$(( ( $(date -d "$last_date" +%s 2>/dev/null || date +%s) - $(date -d "$first_date" +%s 2>/dev/null || date +%s) ) / 86400 ))
                (( days_elapsed <= 0 )) && days_elapsed=1
                arr_growth=$(awk -v l="$last_arr" -v f="$first_arr" -v d="$days_elapsed" 'BEGIN{chg=l-f; if(d>0) printf "%.3f", chg/d; else print 0}')
            fi
            if [[ $first_pool =~ ^[0-9.]+$ && $last_pool =~ ^[0-9.]+$ ]]; then
                local days_elapsed_p=$(( ( $(date -d "$last_date" +%s 2>/dev/null || date +%s) - $(date -d "$first_date" +%s 2>/dev/null || date +%s) ) / 86400 ))
                (( days_elapsed_p <= 0 )) && days_elapsed_p=1
                pool_growth=$(awk -v l="$last_pool" -v f="$first_pool" -v d="$days_elapsed_p" 'BEGIN{chg=l-f; if(d>0) printf "%.3f", chg/d; else print 0}')
            fi
        else
            local i
            for ((i=1;i<count;i++)); do
                if [[ ${arr_prev[$i]} =~ ^[0-9.]+$ && ${arr_prev[$((i-1))]} =~ ^[0-9.]+$ ]]; then
                    arr_growth=$(awk -v a="$arr_growth" -v cur="${arr_prev[$i]}" -v prev="${arr_prev[$((i-1))]}" 'BEGIN{print a + (cur-prev)}')
                fi
                if [[ ${pool_prev[$i]} =~ ^[0-9.]+$ && ${pool_prev[$((i-1))]} =~ ^[0-9.]+$ ]]; then
                    pool_growth=$(awk -v a="$pool_growth" -v cur="${pool_prev[$i]}" -v prev="${pool_prev[$((i-1))]}" 'BEGIN{print a + (cur-prev)}')
                fi
            done
            arr_growth=$(awk -v g="$arr_growth" -v n="$(($count-1))" 'BEGIN{if(n>0) printf "%.3f", g/n; else print 0}')
            pool_growth=$(awk -v g="$pool_growth" -v n="$(($count-1))" 'BEGIN{if(n>0) printf "%.3f", g/n; else print 0}')
        fi
    fi
    local days_to_arr_thresh="N/A" days_to_pool_thresh="N/A"
    if (( $(awk -v g="$arr_growth" 'BEGIN{print (g>0)}') )); then
        days_to_arr_thresh=$(awk -v pct="$array_pct" -v g="$arr_growth" -v th="$THRESHOLD" 'BEGIN{left=th-pct; if(left<=0) print 0; else printf "%.1f", left/g}')
    fi
    if (( $(awk -v g="$pool_growth" 'BEGIN{print (g>0)}') )); then
        days_to_pool_thresh=$(awk -v pct="$pools_pct" -v g="$pool_growth" -v th="$THRESHOLD" 'BEGIN{left=th-pct; if(left<=0) print 0; else printf "%.1f", left/g}')
    fi
    fmt_growth() {
        local g="$1"
        if (( $(awk -v g="$g" -v m="$FORECAST_MIN_VISIBLE" 'BEGIN{print (g>0 && g<m)}') )); then
            printf "%s" "$FORECAST_ZERO_LABEL"
        else
            awk -v g="$g" -v d="$FORECAST_DECIMALS" 'BEGIN{printf "%.*f%%", d, g}'
        fi
    }
    local arr_g_str pool_g_str
    arr_g_str=$(fmt_growth "$arr_growth")
    pool_g_str=$(fmt_growth "$pool_growth")
    fmt_days() { local v="$1"; if [[ "$v" == "N/A" || -z "$v" ]]; then echo "N/A"; else awk -v x="$v" 'BEGIN{printf "%d", (x==0)?0:int(x+0.999)}'; fi; }
    local arr_days_str pool_days_str
    arr_days_str=$(fmt_days "$days_to_arr_thresh")
    pool_days_str=$(fmt_days "$days_to_pool_thresh")
    local lines_cf=("Capacity Forecast:")
    if (( FORECAST_HIDE_ZERO_GROWTH==0 )) || [[ "$arr_g_str" != "$FORECAST_ZERO_LABEL" ]]; then
        lines_cf+=(" Array avg daily growth: ${arr_g_str} -> days to ${THRESHOLD}%%: ${arr_days_str}")
    fi
    if (( FORECAST_HIDE_ZERO_GROWTH==0 )) || [[ "$pool_g_str" != "$FORECAST_ZERO_LABEL" ]]; then
        lines_cf+=(" Pools avg daily growth: ${pool_g_str} -> days to ${THRESHOLD}%%: ${pool_days_str}")
    fi
    if (( ${#lines_cf[@]} == 1 )); then
        lines_cf+=(" Stable: no meaningful growth detected in the last ${HISTORY_WINDOW_DAYS} days")
    fi
    CAPACITY_FORECAST="$(printf "%s\n" "${lines_cf[@]}")\n"
    ARR_DAYS_TO_THRESHOLD="$arr_days_str"
    POOL_DAYS_TO_THRESHOLD="$pool_days_str"
    ARR_GROWTH_STR="$arr_g_str"
    POOL_GROWTH_STR="$pool_g_str"

    if (( JSON_EXPORT == 1 )); then
        mkdir -p "$(dirname "$HEALTH_JSON")" || true
        local include_disks=$JSON_INCLUDE_DISKS
        {
            echo '{'
            echo "  \"timestamp\": \"$(date '+%Y-%m-%dT%H:%M:%S')\",";
            echo "  \"array\": { \"percent\": $array_pct, \"used_hr\": \"${ARRAY_USED_HR:-0 B}\", \"total_hr\": \"${ARRAY_TOTAL_HR:-0 B}\" },";
            echo "  \"pools\": { \"percent\": $pools_pct, \"used_hr\": \"${POOLS_USED_HR:-0 B}\", \"total_hr\": \"${POOLS_TOTAL_HR:-0 B}\" },";
            echo "  \"disk_health_summary\": \"$(echo "${DISK_HEALTH_SUMMARY:-}" | sed 's/\"/\\\"/g')\",";
            {
                local _dev_trend=${BTRFS_TREND_DEV_JSON:-[]}; [[ -z "${_dev_trend}" ]] && _dev_trend=[]
                local _mnt_tot=${BTRFS_TREND_MOUNT_JSON:-[]}; [[ -z "${_mnt_tot}" ]] && _mnt_tot=[]
                local _key_tot=${BTRFS_TREND_KEYS_JSON:-[]}; [[ -z "${_key_tot}" ]] && _key_tot=[]
                echo "  \"btrfs_device_trend\": ${_dev_trend},"
                echo "  \"btrfs_mount_totals\": ${_mnt_tot},"
                echo "  \"btrfs_key_totals\": ${_key_tot},"
            }
            {
                local _p_clean="null"
                if [[ -n "${PARITY_CLEAN_FLAG:-}" ]]; then _p_clean="${PARITY_CLEAN_FLAG}"; fi
                local _p_labels="${PARITY_LABELS_JSON:-[]}"; [[ -z "${_p_labels}" ]] && _p_labels="[]"
                local _p_devs="${PARITY_DEVICES_JSON:-[]}"; [[ -z "${_p_devs}" ]] && _p_devs="[]"
                local _p_status="$(printf "%s" "${PARITY_STATUS_LINE:-}" | sed 's/\\/\\\\/g; s/\"/\\\"/g')"
                local _p_details="${PARITY_DETAILS_JSON:-null}"; [[ -z "${_p_details}" ]] && _p_details="null"
                echo "  \"parity\": { \"clean_flag\": ${_p_clean}, \"labels\": ${_p_labels}, \"devices\": ${_p_devs}, \"status_line\": \"${_p_status}\", \"details\": ${_p_details} },"
            }
            if (( include_disks == 1 )); then
                echo "  \"capacity_forecast\": \"$(echo "$CAPACITY_FORECAST" | sed 's/\"/\\\"/g')\",";
                echo "  \"disks\": ["
                local first=1
                for dev in "${!SMART_STATE[@]}"; do
                    local st="${SMART_STATE[$dev]}" msg="${SMART_MSGS[$dev]}" typ model cap poh endurance_nvme endurance_sata
                    local array_member=false array_slot=""
                    local pool_member=false pool_name=""
                    if [[ "$dev" == /dev/nvme* ]]; then
                        typ="nvme"
                        endurance_nvme=${CUR_ATTR["$dev|nvme_percent_used"]:-0}
                    else
                        typ="sata"
                        endurance_sata=${CUR_ATTR["$dev|life_remain"]:-0}
                    fi
                    poh=${CUR_ATTR["$dev|poh"]:-0}
                    model=$(get_device_model "$dev" 2>/dev/null || echo "")
                    cap=$(get_device_capacity_tb "$dev" 2>/dev/null || echo "0")
                    local bdev="$(base_device "$dev")"
                    local k
                    for k in "${!MOUNT_TO_DEV[@]}"; do
                        if [[ "$k" == /mnt/disk* ]]; then
                            local mdev="${MOUNT_TO_DEV[$k]}"
                            local bmdev="$(base_device "$mdev")"
                            if [[ "$bdev" == "$bmdev" ]]; then
                                array_member=true; array_slot="$(basename "$k")"; break
                            fi
                        fi
                    done
                    if [[ -n "${POOL_MEMBER_MAP[$bdev]:-}" ]]; then
                        pool_member=true; pool_name="${POOL_MEMBER_MAP[$bdev]}"
                    fi
                    local esc_model esc_msg group
                    esc_model=$(printf "%s" "$model" | sed 's/\\/\\\\/g; s/\"/\\\"/g')
                    esc_msg=$(printf "%s" "$msg" | sed 's/\\/\\\\/g; s/\"/\\\"/g')
                    if $array_member; then group="array"; elif $pool_member; then group="pool"; else group="other"; fi
                    if (( first == 0 )); then echo ','; else first=0; fi
                    local tbw_bytes=${CUR_ATTR["$dev|tbw_bytes"]:-}
                    local tbw_daily=${TBW_DAILY_MAP[$dev]:-}
                    local tbw_days_left=${TBW_DAYSLEFT_MAP[$dev]:-}
                    local tbw_status=${TBW_STATUS_MAP[$dev]:-}
                    local poh_status="OK"
                    if [[ -n "$poh" && "$poh" =~ ^[0-9]+$ ]]; then
                        if [[ "$typ" == "nvme" ]]; then
                            local _pw _pc; read -r _pw _pc < <(poh_thresholds_for_device "$dev" "nvme")
                            if [[ -n "$_pw" && -n "$_pc" ]]; then
                                if (( poh >= _pc )); then poh_status="CRITICAL"; elif (( poh >= _pw )); then poh_status="WARNING"; fi
                            fi
                        else
                            local bdv rota; bdv=$(base_device "$dev"); rota=$(lsblk -dn -o ROTA "$bdv" 2>/dev/null | head -n1)
                            local _pw _pc; read -r _pw _pc < <(poh_thresholds_for_device "$dev" "sata" "$rota")
                            if [[ -n "$_pw" && -n "$_pc" ]]; then
                                if (( poh >= _pc )); then poh_status="CRITICAL"; elif (( poh >= _pw )); then poh_status="WARNING"; fi
                            fi
                        fi
                    fi
                    echo -n "    { \"device\": \"$dev\", \"type\": \"$typ\", \"model\": \"$esc_model\", \"state\": \"$st\", \"poh_hours\": ${poh:-0}, \"poh_status\": \"$poh_status\", \"capacity_tb\": ${cap:-0}, \"group\": \"$group\", \"array_member\": ${array_member}, \"array_slot\": \"$array_slot\", \"pool_member\": ${pool_member}, \"pool\": \"$pool_name\""
                    local io_raw=${IO_ERROR_RAW_MAP[$dev]:-0}
                    local io_unique=${IO_ERROR_UNIQUE_MAP[$dev]:-0}
                    echo -n ", \"io_errors_raw\": $io_raw, \"io_errors_unique\": $io_unique"
                    if [[ -n "$tbw_bytes" ]]; then
                        echo -n ", \"tbw_bytes\": $tbw_bytes"
                        if [[ -n "$tbw_daily" ]]; then echo -n ", \"tbw_daily_bytes\": $tbw_daily"; else echo -n ", \"tbw_daily_bytes\": null"; fi
                        if [[ -n "$tbw_days_left" ]]; then echo -n ", \"tbw_days_to_threshold\": $tbw_days_left"; else echo -n ", \"tbw_days_to_threshold\": null"; fi
                        if [[ -n "$tbw_status" ]]; then echo -n ", \"tbw_status\": \"$tbw_status\""; else echo -n ", \"tbw_status\": \"UNKNOWN\""; fi
                    fi
                    local prev_poh=${PREV_ATTR["$dev|poh"]:-}
                    local prev_nvme_used=${PREV_ATTR["$dev|nvme_percent_used"]:-}
                    local poh_reset=false nvme_regress=false poh_drop=0 nvme_drop=0
                    if [[ -n "$prev_poh" && "$prev_poh" =~ ^[0-9]+$ && "$poh" =~ ^[0-9]+$ && $poh -lt $prev_poh ]]; then
                        poh_reset=true; poh_drop=$((prev_poh - poh))
                    fi
                    if [[ "$typ" == "nvme" && -n "$prev_nvme_used" && "$prev_nvme_used" =~ ^[0-9]+$ && ${endurance_nvme:-0} -lt $prev_nvme_used ]]; then
                        nvme_regress=true; nvme_drop=$((prev_nvme_used - ${endurance_nvme:-0}))
                    fi
                    echo -n ", \"poh_prev_hours\": ${prev_poh:-null}, \"poh_reset_detected\": $poh_reset, \"poh_reset_drop_hours\": $poh_drop"
                    if [[ "$typ" == "nvme" ]]; then
                        echo -n ", \"nvme_percent_used_prev\": ${prev_nvme_used:-null}, \"nvme_wear_regression\": $nvme_regress, \"nvme_wear_regression_drop\": $nvme_drop"
                    fi
                    if [[ "$typ" == "nvme" ]]; then
                        echo -n ", \"nvme_percent_used\": ${endurance_nvme:-0}"
                    else
                        echo -n ", \"life_remaining_percent\": ${endurance_sata:-0}"
                        local link_max=${CUR_ATTR["$dev|sata_link_max"]:-}
                        local link_curr=${CUR_ATTR["$dev|sata_link_current"]:-}
                        if [[ -n "$link_max" || -n "$link_curr" ]]; then
                            local downshift=false
                            if [[ -n "$link_max" && -n "$link_curr" && "$link_max" != "$link_curr" ]]; then downshift=true; fi
                            echo -n ", \"sata_link\": { \"max_gbps\": ${link_max:-null}, \"current_gbps\": ${link_curr:-null}, \"downshift\": $downshift }"
                        fi
                    fi
                    local _tc=${CUR_ATTR["$dev|tbw_consumed_pct"]:-}
                    if [[ -n "$_tc" ]]; then echo -n ", \"tbw_consumed_percent\": ${_tc}"; fi
                    local st_json_status=$(printf "%s" "${CUR_ATTR[\"$dev|selftest_status\"]:-}" | sed 's/\\/\\\\/g; s/\"/\\\"/g')
                    local st_json_msg=$(printf "%s" "${CUR_ATTR[\"$dev|selftest_msg\"]:-}" | sed 's/\\/\\\\/g; s/\"/\\\"/g')
                    if [[ -n "$st_json_status" || -n "$st_json_msg" ]]; then
                        echo -n ", \"selftest\": { \"status\": \"${st_json_status}\", \"message\": \"${st_json_msg}\" }"
                    fi
                    if [[ -n "$esc_msg" ]]; then
                        echo -n ", \"message\": \"$esc_msg\""
                    fi
                    echo -n ' }'
                done
                echo
                echo "  ]"
                echo '}'
            else
                echo "  \"capacity_forecast\": \"$(echo "$CAPACITY_FORECAST" | sed 's/\"/\\\"/g')\"";
                echo '}'
            fi
        } > "$HEALTH_JSON"
        chown "$HEALTH_LOG_USER:$HEALTH_LOG_GROUP" "$HEALTH_JSON" 2>/dev/null || true
        chmod "$HEALTH_FILE_MODE" "$HEALTH_JSON" 2>/dev/null || true
    fi
}

# Analyze disk usage history and compute top growth rates
compute_disk_growth_top() {
    (( ${DISK_GROWTH_ENABLED:-1} == 1 )) || { DISK_GROWTH_SECTION=""; return 0; }
    local win=$HISTORY_WINDOW_DAYS
    local lines=$(tail -n 20000 "$DISK_CAP_HISTORY_FILE" 2>/dev/null || true)
    [[ -z "$lines" ]] && { DISK_GROWTH_SECTION=""; return 0; }
    local cutoff=$(date -d "-$win days" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)
    local tmp=$(mktemp)
    printf "%s\n" "$lines" | awk -v c="$cutoff" '$1>=c{print}' | awk '{d=$2; for(i=3;i<=NF;i++){split($i,a,"="); if(a[1]=="used") used=a[2]; if(a[1]=="size") sz=a[2]} if(used!="" && sz!=""){print $1,d,used,sz}}' > "$tmp"
    declare -A first_used first_date last_used last_date size_map
    while read -r dt disk used sz; do
        size_map[$disk]="$sz"
        if [[ -z "${first_date[$disk]:-}" || "$dt" < "${first_date[$disk]}" ]]; then
            first_date[$disk]="$dt"; first_used[$disk]="$used"
        fi
        if [[ -z "${last_date[$disk]:-}" || "$dt" > "${last_date[$disk]}" ]]; then
            last_date[$disk]="$dt"; last_used[$disk]="$used"
        fi
    done < "$tmp"
    rm -f "$tmp"
    local out=""; local rank=()
    for disk in "${!last_used[@]}"; do
        local fu=${first_used[$disk]:-0} lu=${last_used[$disk]:-0} sz=${size_map[$disk]:-0}
        if (( lu>0 && fu>=0 && lu>fu )); then
            local days
            days=$(( ( $(date -d "${last_date[$disk]}" +%s 2>/dev/null || date +%s) - $(date -d "${first_date[$disk]}" +%s 2>/dev/null || date +%s) ) / 86400 ))
            (( days<=0 )) && days=1
            local per_day=$(( (lu - fu) / days ))
            rank+=("$per_day $disk $sz")
        fi
    done
    if (( ${#rank[@]} > 0 )); then
        local sorted=$(printf "%s\n" "${rank[@]}" | sort -nr -k1,1 | head -n 5)
        while read -r pd disk sz; do
            [[ -z "$pd" ]] && continue
            local pd_hr=$(human_readable "$pd")
            out+=" - $(printf "%-8s" "$disk") +$pd_hr/day"
            if (( sz>0 )); then
                local pct=$(awk -v pd="$pd" -v sz="$sz" 'BEGIN{printf "%.2f", (pd/sz)*100}')
                out+=" (${pct}%/day)"
            fi
            out+="\n"
        done < <(printf "%s\n" "$sorted")
        DISK_GROWTH_SECTION="Top Disk Growth (last ${win}d):\n$out"
    else
        DISK_GROWTH_SECTION=""
    fi
}

# Analyze TBW history to estimate daily write rates and days to threshold
tbw_forecast_and_heavy_writers() {
    (( ${TBW_FORECAST_ENABLED:-1} == 1 )) || { TBW_SECTION=""; return 0; }
    local today=$(date +%Y-%m-%d)
    for dev in "${!SMART_STATE[@]}"; do
        local tbw=${CUR_ATTR["$dev|tbw_bytes"]:-}
        [[ -n "$tbw" ]] && echo "$today $dev tbw=$tbw" >> "$TBW_HISTORY_FILE"
    done
    declare -A PREV_HEAVY
    if [[ -f "$HEAVY_WRITER_HISTORY_FILE" ]]; then
        local hw_lines
        hw_lines=$(tail -n 2000 "$HEAVY_WRITER_HISTORY_FILE" 2>/dev/null || true)
        while read -r line; do
            [[ -z "$line" ]] && continue
            local dt dv npct dbytes
            dt=$(echo "$line" | awk '{print $1}')
            dv=$(echo "$line" | awk '{print $2}')
            npct=$(echo "$line" | awk '{for(i=3;i<=NF;i++){if($i ~ /^norm=/){sub(/norm=/,"",$i); print $i; break}}}')
            if [[ -n "$dv" && -n "$npct" ]]; then
                PREV_HEAVY[$dv]="$npct"
            fi
        done < <(printf "%s\n" "$hw_lines")
    fi
    local win=$HISTORY_WINDOW_DAYS
    local cutoff=$(date -d "-$win days" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)
    local lines=$(tail -n 50000 "$TBW_HISTORY_FILE" 2>/dev/null || true)
    [[ -z "$lines" ]] && { TBW_SECTION=""; return 0; }
    local tmp=$(mktemp)
    printf "%s\n" "$lines" | awk -v c="$cutoff" '$1>=c{print}' | awk '{d=$2; for(i=3;i<=NF;i++){split($i,a,"="); if(a[1]=="tbw") v=a[2]} if(d!="" && v!=""){print $1,d,v}}' > "$tmp"
    declare -A first_dt first_v last_dt last_v
    while read -r dt dev v; do
        if [[ -z "${first_dt[$dev]:-}" || "$dt" < "${first_dt[$dev]}" ]]; then first_dt[$dev]="$dt"; first_v[$dev]="$v"; fi
        if [[ -z "${last_dt[$dev]:-}" || "$dt" > "${last_dt[$dev]}" ]]; then last_dt[$dev]="$dt"; last_v[$dev]="$v"; fi
    done < "$tmp"
    rm -f "$tmp"
    declare -A TBW_DAILY TBW_DAYS_LEFT TBW_THRESHOLD_TB
    local heavy_rank=()
    for dev in "${!last_v[@]}"; do
        local start=${first_v[$dev]:-0} end=${last_v[$dev]:-0}
        local days=$(( ( $(date -d "${last_dt[$dev]}" +%s 2>/dev/null || date +%s) - $(date -d "${first_dt[$dev]}" +%s 2>/dev/null || date +%s) ) / 86400 ))
        (( days<=0 )) && days=1
        if (( end>start )); then
            local daily=$(( (end - start) / days ))
            TBW_DAILY[$dev]=$daily
            TBW_DAILY_MAP[$dev]=$daily
            local model cap tbw_thresh
            model=$(get_device_model "$dev")
            cap=$(get_device_capacity_tb "$dev")
            tbw_thresh=$(tbw_threshold_tb_for_device "$model" "$cap")
            local total_bytes="" remaining_bytes="" days_left=""
            if [[ -n "$tbw_thresh" ]]; then
                local TB=$((1000*1000*1000*1000))
                total_bytes=$(( tbw_thresh * TB ))
            else
                local used_pct=${CUR_ATTR["$dev|nvme_percent_used"]:-}
                if [[ -n "$used_pct" && "$used_pct" =~ ^[0-9]+$ && $used_pct -gt 0 ]]; then
                    total_bytes=$(( end * 100 / used_pct ))
                fi
            fi
            if [[ -n "$total_bytes" && $total_bytes -gt end && $daily -gt 0 ]]; then
                remaining_bytes=$(( total_bytes - end ))
                days_left=$(awk -v r="$remaining_bytes" -v d="$daily" 'BEGIN{printf "%.1f", r/d}')
                TBW_DAYS_LEFT[$dev]=$days_left
                TBW_DAYSLEFT_MAP[$dev]=$days_left
                local status="OK"
                if [[ -n "$days_left" ]]; then
                    if (( $(awk -v dl="$days_left" -v c="$TBW_DAYS_CRIT" 'BEGIN{print (dl < c)}') )); then
                        status="CRITICAL"
                    elif (( $(awk -v dl="$days_left" -v w="$TBW_DAYS_WARN" 'BEGIN{print (dl < w)}') )); then
                        status="WARNING"
                    fi
                fi
                TBW_STATUS_MAP[$dev]="$status"
                if [[ -n "$tbw_thresh" ]]; then TBW_THRESHOLD_TB[$dev]="$tbw_thresh"; fi
            fi
            local cap_tb=$(printf "%s" "$cap" | awk '{print ($0+0)}')
            if [[ -n "$cap_tb" && "$cap_tb" != 0 ]]; then
                local norm_pct=$(awk -v daily="$daily" -v cap_tb="$cap_tb" 'BEGIN{printf "%.6f", (daily/ (cap_tb*1000000000000.0))*100}')
                heavy_rank+=("$norm_pct $dev $daily $cap_tb")
            fi
        fi
    done
    local heavy_section="" forecast_section=""
    if (( ${#heavy_rank[@]} > 0 )); then
        local sorted=$(printf "%s\n" "${heavy_rank[@]}" | sort -nr -k1,1 | head -n 5)
        while read -r pct dev daily cap_tb; do
            [[ -z "$dev" ]] && continue
            local daily_hr=$(human_readable "$daily")
            local prev_npct=${PREV_HEAVY[$dev]:-}
            local delta_str=""
            if [[ -n "$prev_npct" ]]; then
                delta_str=$(awk -v n="$pct" -v p="$prev_npct" 'BEGIN{d=n-p; printf "%+.3f", d}')
            fi
            heavy_section+=" - $(basename "$dev") ${daily_hr}/day (cap ${cap_tb}TB, $(printf '%.3f' $pct)% cap/day${delta_str:+, Δ ${delta_str}%})\n"
            echo "$today $dev norm=$pct daily=$daily" >> "$HEAVY_WRITER_HISTORY_FILE"
        done < <(printf "%s\n" "$sorted")
    fi
    for dev in "${!TBW_DAYS_LEFT[@]}"; do
        local days_left=${TBW_DAYS_LEFT[$dev]}
        local daily=${TBW_DAILY[$dev]:-0}
        local daily_hr=$(human_readable "$daily")
        local thresh_tb=${TBW_THRESHOLD_TB[$dev]:-}
        local status=${TBW_STATUS_MAP[$dev]:-OK}
        if [[ "$status" == "CRITICAL" ]]; then
            record_alert critical "TBW Endurance" "Disk $dev TBW forecast CRITICAL: ${days_left}d remaining (<${TBW_DAYS_CRIT}d)"
        elif [[ "$status" == "WARNING" ]]; then
            record_alert warning "TBW Endurance" "Disk $dev TBW forecast WARNING: ${days_left}d remaining (<${TBW_DAYS_WARN}d)"
        fi
        forecast_section+=" - $(basename "$dev") ${daily_hr}/day -> ${days_left}d (${status}) to ${( [[ -n "$thresh_tb" ]] && echo "${thresh_tb}TB" || echo "endurance" )}\n"
    done
    if [[ -n "$forecast_section" || -n "$heavy_section" ]]; then
        TBW_SECTION="TBW Forecast:
${forecast_section}$( [[ -n "$heavy_section" ]] && printf "Top Heavy Writers (normalized):\n%s" "$heavy_section" )"
    else
        TBW_SECTION=""
    fi
}

log_info "Summarizing disks and pools usage..."
build_storage_and_disk_lines
log_info "Usage summary completed"
log_info "Checking capacity thresholds..."
evaluate_capacity_alerts
log_info "Capacity threshold check completed"
log_info "Preparing parity summary..."
discover_parity_and_status
log_info "Parity summary completed"
log_info "Collecting btrfs per-device stats..."
collect_btrfs_device_stats
log_info "Btrfs device stats collection completed"
log_info "Collecting XFS /proc stats..."
collect_xfs_proc_stats
log_info "XFS /proc stats collection completed"
log_info "Precomputing btrfs device trend aggregates for JSON..."
build_btrfs_device_trend_section
log_info "Btrfs trend aggregates prepared"
log_info "Estimating capacity growth and exporting JSON..."
capacity_forecast_and_export
log_info "Capacity forecast/export completed"
log_info "Compiling recommendations..."
build_recommendations 
log_info "Recommendations compiled"
build_subject
log_info "Building disk health summary..."
build_disk_health_summary
log_info "Disk health summary completed"
log_info "Analyzing write rates and TBW forecasts..."
tbw_forecast_and_heavy_writers
log_info "TBW analysis completed"
log_info "Summarizing subsystem statuses..."
build_subsystem_lines
log_info "Subsystem summary completed"
log_info "Scoring disk risk and lifecycle buckets..."
compute_risk_and_lifecycle
log_info "Risk and lifecycle scoring completed"
log_info "Validating storage metrics..."
validate_storage_metrics
log_info "Storage metrics validation completed"
log_info "Analyzing top disk growth..."
compute_disk_growth_top
log_info "Disk growth analysis completed"
log_info "Computing share sizes and growth (if enabled)..."
compute_share_breakdown
log_info "Share analysis completed"
log_info "Scanning syslog for disk I/O errors..."
scan_syslog_disk_errors
log_info "Syslog scan completed"
log_info "Recording today's risk tier counts..."
persist_risk_tier_history
log_info "Risk tier counts recorded"
log_info "Summarizing recent risk trends..."
build_risk_tier_trend_section
log_info "Risk trend summary completed"
log_info "Building btrfs device error trend section..."
build_btrfs_device_trend_section
log_info "Btrfs device error trend section completed"
log_info "Trend analysis done; preparing notification"

# Detect firmware/controller resets by checking for Power-On Hours (POH) drops and NVMe Percentage Used regression
detect_counter_resets() {
    FIRMWARE_EVENT_SECTION=""
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
                if (( delta >= NVME_WEAR_REGRESSION_WARN )); then
                    events+=" - $(basename "$dev") NVMe percent_used regression: ${prev_used}% -> ${curr_used}% (drop ${delta}%)\n"
                    record_alert warning "Firmware Reset" "Disk $dev NVMe Percentage Used decreased (${prev_used}% -> ${curr_used}%); check firmware or controller resets"
                fi
            fi
        fi
    done
    [[ -n "$events" ]] && FIRMWARE_EVENT_SECTION="Firmware Reset / Counter Regression:\n$events"
    return 0
}

detect_counter_resets

# Collect and integrate btrfs per-device stats
collect_btrfs_device_stats() {
    (( ENABLE_BTRFS_DEVICE_STATS == 1 )) || return 0
    local prev_file="$STATE_DIR/btrfs_device_stats.prev"
    declare -A PREV_STAT
    if [[ -f "$prev_file" ]]; then
        while read -r dev key val; do
            [[ -z "$dev" || -z "$key" || -z "$val" ]] && continue
            PREV_STAT["$dev|$key"]="$val"
        done < "$prev_file"
    fi
    local mts
    mts=$(mount | awk '/ btrfs /{print $3}')
    [[ -z "$mts" ]] && return 0
    local out_has=0
    > "$prev_file.tmp"
    for m in $mts; do
        local stats
        stats=$(btrfs device stats -z "$m" 2>/dev/null || true)
        [[ -z "$stats" ]] && continue
        while read -r line; do
            [[ -z "$line" ]] && continue
            if [[ "$line" =~ ^[/]dev/ ]]; then
                local dev=$(echo "$line" | awk '{print $1}' | sed 's/://')
                local key=$(echo "$line" | awk '{print $2}')
                local val=$(echo "$line" | awk '{print $3}')
                [[ -z "$dev" || -z "$key" || -z "$val" ]] && continue
                echo "$dev $key $val" >> "$prev_file.tmp"
                out_has=1
                if [[ "$val" =~ ^[0-9]+$ ]]; then
                    local prev=${PREV_STAT["$dev|$key"]:-0}
                    local delta=$(( val - prev ))
                    if (( delta > 0 )); then
                        local sev="warning"
                        case "$key" in
                            corruption_errs|generation_errs)
                                (( delta >= BTRFS_DEV_CORR_CRIT_DELTA )) && sev="critical" || sev="critical";;
                            read_io_errs|write_io_errs|flush_io_errs)
                                if (( delta >= BTRFS_DEV_ERR_CRIT_DELTA )); then sev="critical"; elif (( delta >= BTRFS_DEV_ERR_WARN_DELTA )); then sev="warning"; fi;;
                        esac
                        record_alert "$sev" "Btrfs Device" "Device $dev $key +$delta (now $val) on mount $m"
                        local today=$(date +%Y-%m-%d)
                        echo "$today $dev mount=$m key=$key delta=$delta value=$val" >> "$BTRFS_DEV_HIST_FILE"
                        local bdev=$(base_device "$dev")
                        [[ -z "${SMART_STATE[$bdev]:-}" ]] && SMART_STATE[$bdev]="OK"
                        SMART_MSGS[$bdev]="${SMART_MSGS[$bdev]:-} Btrfs device errors: $key +$delta" 
                    fi
                fi
            fi
        done < <(echo "$stats" | awk 'NF>=3')
    done
    if (( out_has == 1 )); then
        mv "$prev_file.tmp" "$prev_file" 2>/dev/null || rm -f "$prev_file.tmp"
    else
        rm -f "$prev_file.tmp" 2>/dev/null || true
    fi
}

# Collect and integrate xfs /proc stats (global deltas)
collect_xfs_proc_stats() {
    (( ENABLE_XFS_PROC_STATS == 1 )) || return 0
    local stat_file="/proc/fs/xfs/stat"
    [[ -r "$stat_file" ]] || return 0
    local prev_file="$STATE_DIR/xfs_proc_stats.prev"
    declare -A PREV_XFS
    if [[ -f "$prev_file" ]]; then
        while read -r key val; do
            [[ -z "$key" || -z "$val" ]] && continue
            PREV_XFS["$key"]="$val"
        done < "$prev_file"
    fi
    > "$prev_file.tmp"
    local anomalies=0
    local keys=(extent_alloc dir_lookup dir_create xs_xstrat delalloc flush)
    for k in "${keys[@]}"; do
        local val
        val=$(grep -E "^$k " "$stat_file" | awk '{print $2}' | head -n1)
        [[ -z "$val" || ! "$val" =~ ^[0-9]+$ ]] && continue
        echo "$k $val" >> "$prev_file.tmp"
        local prev=${PREV_XFS["$k"]:-0}
        local delta=$(( val - prev ))
        if (( delta > 0 )); then
            local sev="warning"
            if (( delta >= XFS_PROC_CRIT_DELTA )); then sev="critical"; elif (( delta >= XFS_PROC_WARN_DELTA )); then sev="warning"; else continue; fi
            anomalies=1
            record_alert "$sev" "XFS Stat" "Counter $k +$delta (now $val)"
        fi
    done
    if (( anomalies == 1 )); then
        local xfs_mounts
        xfs_mounts=$(mount | awk '/ xfs /{print $3}')
        for m in $xfs_mounts; do
            local src=$(findmnt -n -o SOURCE "$m" 2>/dev/null || true)
            [[ -z "$src" ]] && continue
            local bdev=$(base_device "$src")
            [[ -z "${SMART_STATE[$bdev]:-}" ]] && SMART_STATE[$bdev]="OK"
            SMART_MSGS[$bdev]="${SMART_MSGS[$bdev]:-} XFS metadata anomalies"
        done
    fi
    mv "$prev_file.tmp" "$prev_file" 2>/dev/null || rm -f "$prev_file.tmp"
}

# Build and send notification
SCRIPT_END_EPOCH=$(date +%s)
RUNTIME_SEC=$(( SCRIPT_END_EPOCH - SCRIPT_START_EPOCH ))
build_btrfs_device_trend_section() {
    (( BTRFS_DEV_TREND_ENABLED == 1 )) || { BTRFS_DEV_TREND_SECTION=""; return 0; }
    local hist_file="${BTRFS_DEV_HIST_FILE}"
    [[ -f "$hist_file" ]] || { BTRFS_DEV_TREND_SECTION=""; return 0; }
    BTRFS_TREND_DEV_JSON="[]"; BTRFS_TREND_MOUNT_JSON="[]"; BTRFS_TREND_KEYS_JSON="[]"
    local win=${BTRFS_TREND_WINDOW_DAYS:-7}
    local cutoff=$(date -d "-$win days" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)
    local lines
    lines=$(tail -n 50000 "$hist_file" 2>/dev/null || true)
    [[ -z "$lines" ]] && { BTRFS_DEV_TREND_SECTION=""; return 0; }
    declare -A SUM_DEV SUM_KEY DEV_SUM SUM_MOUNT SUM_MOUNT_KEY KEY_SUM MOUNT_SUM
    while read -r dt rest; do
        [[ -z "$dt" || "$dt" < "$cutoff" ]] && continue
        local dev mount key delta val
        dev=$(echo "$rest" | awk '{print $1}')
        key=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^key=/){sub(/key=/, "", $i); print $i; break}}}')
        mount=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^mount=/){sub(/mount=/, "", $i); print $i; break}}}')
        delta=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^delta=/){sub(/delta=/, "", $i); print $i; break}}}')
        val=$(echo "$rest" | awk '{for(i=1;i<=NF;i++){if($i ~ /^value=/){sub(/value=/, "", $i); print $i; break}}}')
        [[ -z "$dev" || -z "$key" || -z "$delta" ]] && continue
        [[ "$delta" =~ ^[0-9]+$ ]] || continue
        (( delta == 0 )) && continue
        SUM_KEY["$dev|$key"]=$(( ${SUM_KEY["$dev|$key"]:-0} + delta ))
        DEV_SUM["$dev"]=$(( ${DEV_SUM["$dev"]:-0} + delta ))
        [[ -n "$mount" ]] && {
            SUM_MOUNT_KEY["$mount|$key"]=$(( ${SUM_MOUNT_KEY["$mount|$key"]:-0} + delta ))
            MOUNT_SUM["$mount"]=$(( ${MOUNT_SUM["$mount"]:-0} + delta ))
        }
        KEY_SUM["$key"]=$(( ${KEY_SUM["$key"]:-0} + delta ))
    done < <(printf "%s\n" "$lines")
    [[ ${#DEV_SUM[@]} -eq 0 ]] && { BTRFS_DEV_TREND_SECTION=""; return 0; }
    local ranked
    ranked=$(for d in "${!DEV_SUM[@]}"; do echo "${DEV_SUM[$d]} $d"; done | sort -nr -k1,1)
    local out="" count=0 top=${BTRFS_TREND_TOP_N:-5}
    local dev_elems=""
    while read -r total dev; do
        [[ -z "$dev" ]] && continue
        local klist=(read_io_errs write_io_errs flush_io_errs corruption_errs generation_errs)
        local parts=()
        local k
        for k in "${klist[@]}"; do
            local v=${SUM_KEY["$dev|$k"]:-0}
            if (( v > 0 )); then
                local label="$k"
                case "$k" in
                    read_io_errs) label="read";;
                    write_io_errs) label="write";;
                    flush_io_errs) label="flush";;
                    corruption_errs) label="corruption";;
                    generation_errs) label="generation";;
                esac
                parts+=("$label +$v")
            fi
        done
        if (( ${#parts[@]} > 0 )); then
            out+=" - $(basename \"$dev\"): ${parts[*]}\n"
            local r=${SUM_KEY["$dev|read_io_errs"]:-0}
            local w=${SUM_KEY["$dev|write_io_errs"]:-0}
            local f=${SUM_KEY["$dev|flush_io_errs"]:-0}
            local c=${SUM_KEY["$dev|corruption_errs"]:-0}
            local g=${SUM_KEY["$dev|generation_errs"]:-0}
            local esc_dev=$(printf "%s" "$dev" | sed 's/\\/\\\\/g; s/"/\\"/g')
            local elem="{ \"device\": \"$esc_dev\", \"total_delta\": $total, \"breakdown\": { \"read\": $r, \"write\": $w, \"flush\": $f, \"corruption\": $c, \"generation\": $g } }"
            if [[ -z "$dev_elems" ]]; then dev_elems="$elem"; else dev_elems="$dev_elems, $elem"; fi
            (( ++count >= top )) && break
        fi
    done < <(printf "%s\n" "$ranked")
    local mount_out=""
    local mount_elems=""
    if [[ ${#MOUNT_SUM[@]} -gt 0 ]]; then
        local ranked_m
        ranked_m=$(for m in "${!MOUNT_SUM[@]}"; do echo "${MOUNT_SUM[$m]} $m"; done | sort -nr -k1,1)
        local mcount=0
        while read -r total mnt; do
            [[ -z "$mnt" ]] && continue
            local klist=(read_io_errs write_io_errs flush_io_errs corruption_errs generation_errs)
            local parts=()
            local k
            for k in "${klist[@]}"; do
                local v=${SUM_MOUNT_KEY["$mnt|$k"]:-0}
                if (( v > 0 )); then
                    local label="$k"
                    case "$k" in
                        read_io_errs) label="read";;
                        write_io_errs) label="write";;
                        flush_io_errs) label="flush";;
                        corruption_errs) label="corruption";;
                        generation_errs) label="generation";;
                    esac
                    parts+=("$label +$v")
                fi
            done
            if (( ${#parts[@]} > 0 )); then
                mount_out+=" - $mnt: ${parts[*]}\n"
                local r=${SUM_MOUNT_KEY["$mnt|read_io_errs"]:-0}
                local w=${SUM_MOUNT_KEY["$mnt|write_io_errs"]:-0}
                local f=${SUM_MOUNT_KEY["$mnt|flush_io_errs"]:-0}
                local c=${SUM_MOUNT_KEY["$mnt|corruption_errs"]:-0}
                local g=${SUM_MOUNT_KEY["$mnt|generation_errs"]:-0}
                local esc_m=$(printf "%s" "$mnt" | sed 's/\\/\\\\/g; s/"/\\"/g')
                local elem="{ \"mount\": \"$esc_m\", \"total_delta\": $total, \"breakdown\": { \"read\": $r, \"write\": $w, \"flush\": $f, \"corruption\": $c, \"generation\": $g } }"
                if [[ -z "$mount_elems" ]]; then mount_elems="$elem"; else mount_elems="$mount_elems, $elem"; fi
                (( ++mcount >= 5 )) && break
            fi
        done < <(printf "%s\n" "$ranked_m")
    fi
    local key_out=""
    local key_elems=""
    if [[ ${#KEY_SUM[@]} -gt 0 ]]; then
        local klist=(read_io_errs write_io_errs flush_io_errs corruption_errs generation_errs)
        local parts=()
        local k
        for k in "${klist[@]}"; do
            local v=${KEY_SUM[$k]:-0}
            if (( v > 0 )); then
                local label="$k"
                case "$k" in
                    read_io_errs) label="read";;
                    write_io_errs) label="write";;
                    flush_io_errs) label="flush";;
                    corruption_errs) label="corruption";;
                    generation_errs) label="generation";;
                esac
                parts+=("$label:+$v")
            fi
        done
        if (( ${#parts[@]} > 0 )); then
            key_out="Top Keys (all devices): ${parts[*]}\n"
        fi
        local lbl v elem k
        for k in ${klist[*]}; do
            v=${KEY_SUM[$k]:-0}
            case "$k" in
                read_io_errs) lbl="read";;
                write_io_errs) lbl="write";;
                flush_io_errs) lbl="flush";;
                corruption_errs) lbl="corruption";;
                generation_errs) lbl="generation";;
            esac
            elem="{ \"key\": \"$lbl\", \"total_delta\": $v }"
            if [[ -z "$key_elems" ]]; then key_elems="$elem"; else key_elems="$key_elems, $elem"; fi
        done
    fi
    if [[ -n "$dev_elems" ]]; then BTRFS_TREND_DEV_JSON="[ $dev_elems ]"; fi
    if [[ -n "$mount_elems" ]]; then BTRFS_TREND_MOUNT_JSON="[ $mount_elems ]"; fi
    if [[ -n "$key_elems" ]]; then BTRFS_TREND_KEYS_JSON="[ $key_elems ]"; fi
    if [[ -n "$out$key_out$mount_out" ]]; then
        BTRFS_DEV_TREND_SECTION="Btrfs Device Error Trend (last ${win}d):\n${out}${mount_out:+Per-mount Totals:\n$mount_out}${key_out:+$key_out}"
    else
        BTRFS_DEV_TREND_SECTION=""
    fi
}

if (( RUNTIME_SEC < 0 )); then RUNTIME_SEC=0; fi
runtime_h=$(( RUNTIME_SEC / 3600 ))
runtime_m=$(( (RUNTIME_SEC % 3600) / 60 ))
runtime_s=$(( RUNTIME_SEC % 60 ))
if (( runtime_h > 0 )); then
    RUNTIME_STR="${runtime_h}h ${runtime_m}m ${runtime_s}s"
elif (( runtime_m > 0 )); then
    RUNTIME_STR="${runtime_m}m ${runtime_s}s"
else
    RUNTIME_STR="${runtime_s}s"
fi

# Build optional sections safely under set -u / set -e
POOL_DEVICE_SECTION=""
if (( ${ENABLE_POOL_DEVICE_SMART:-0} == 1 )) && [[ -n "${POOL_DEVICE_LINES:-}" ]]; then
    POOL_DEVICE_SECTION="[Pool Devices]:\n${POOL_DEVICE_LINES}\n"
fi
ARRAY_DEVICE_SECTION=""
if [[ -n "${ARRAY_DEVICE_LINES:-}" ]]; then
    ARRAY_DEVICE_SECTION="[Array Devices]:\n${ARRAY_DEVICE_LINES}\n"
fi
ADAPTIVE_DECISIONS_SECTION=""
if [[ -n "${ADAPTIVE_DECISIONS:-}" ]]; then
    ADAPTIVE_DECISIONS_SECTION="Adaptive SMART Decisions:\n${ADAPTIVE_DECISIONS}"
fi

# Build a conditional Risk block with surrounding spacing only when content exists
RISK_BLOCK=""
if [[ -n "${RISK_SECTION:-}" ]]; then
    RISK_BLOCK="\n${RISK_SECTION}\n"
fi

# Build Subsystems block per policy (auto|always|never)
SUBSYSTEMS_BLOCK=""
case "${SHOW_SUBSYSTEMS_BLOCK:-auto}" in
    always)
        if [[ -n "${SUBSYSTEM_LINES:-}" ]]; then
            SUBSYSTEMS_BLOCK="Subsystems:\n${SUBSYSTEM_LINES}\n"
        fi
        ;;
    never)
        : ;;
    auto|*)
        if echo "${SUBSYSTEM_LINES:-}" | grep -Eq ': (WARNING|CRITICAL)$'; then
            local _filtered
            _filtered=$(printf "%s\n" "${SUBSYSTEM_LINES:-}" | awk '/: (WARNING|CRITICAL)$/')
            if [[ -n "${_filtered}" ]]; then
                SUBSYSTEMS_BLOCK="Subsystems:\n${_filtered}\n"
            fi
        fi
        ;;
esac

NOTIFY_BODY="Runtime: ${RUNTIME_STR:-}
${STORAGE_TOP_LINES:-}
[Array Disks]:
${PARITY_STATUS_LINE:-}
${PARITY_DETAILS_SECTION:-}
${ARRAY_DISK_LINES:-}
${ARRAY_DEVICE_SECTION:-}
[Pool Disks]:
${POOL_LINES:-}
${POOL_DEVICE_SECTION:-}
${DISK_HEALTH_SUMMARY:-}
${RISK_TIER_TREND_SECTION:-}
${CAPACITY_FORECAST:-}
${RISK_BLOCK:-}
${FIRMWARE_EVENT_SECTION:-}
${TBW_SECTION:-}
${BTRFS_DEV_TREND_SECTION:-}
${DISK_GROWTH_SECTION:-}
${SHARE_SECTION:-}
${STORAGE_VALIDATION_SECTION:-}
${ADAPTIVE_DECISIONS_SECTION:-}
${IO_ERROR_FREQ_SECTION:-}
${SUBSYSTEMS_BLOCK:-}
${RECOMMEND_SECTION:-}"

# Normalize spacing: collapse multiple blank lines to a single blank line
NOTIFY_BODY=$(printf "%s\n" "$NOTIFY_BODY" | awk '
BEGIN{empty=0}
{
    if ($0 ~ /^[[:space:]]*$/) {
        if (empty==0) print ""; empty=1
    } else {
        print; empty=0
    }
}
END{}')

# Log severity used for the outgoing notification
if (( ${#ALERT_CRIT[@]} > 0 )); then
    _final_sev=critical
elif (( ${#ALERT_WARN[@]} > 0 )); then
    _final_sev=warning
else
    _final_sev=ok
fi
log_info "Preparing notification severity level= ${_final_sev}, critical count= ${#ALERT_CRIT[@]}, warning count= ${#ALERT_WARN[@]}"
notify_unraid "${SUBJECT:-Disk Health Summary}" "$NOTIFY_BODY" "${_final_sev}"

# Persist current SMART attributes and states
persist_current_attrs() {
    > "$PREV_ATTR_FILE"
    for disk in "${!SMART_STATE[@]}"; do
        local line="$disk state=${SMART_STATE[$disk]}"
        for key in realloc pending offunc reported_uncorr cmd_timeout realloc_events udma lcc end2end soft_read_err temp; do
            local v=${CUR_ATTR["$disk|$key"]:-}
            [[ -n "$v" ]] && line+=" $key=$v"
        done
        local poh=${CUR_ATTR["$disk|poh"]:-}
        [[ -n "$poh" ]] && line+=" poh=$poh"
        local nvme_used=${CUR_ATTR["$disk|nvme_percent_used"]:-}
        [[ -n "$nvme_used" ]] && line+=" nvme_percent_used=$nvme_used"
        echo "$line" >> "$PREV_ATTR_FILE"
    done
}
persist_current_attrs

# Persist newly seen disks for alert suppression
persist_new_seen() {
    > "$ALERT_NEW_SEEN_FILE"
    for key in "${!NEW_SEEN[@]}"; do
        echo "$key" >> "$ALERT_NEW_SEEN_FILE"
    done
}
persist_new_seen

# Persist current risk scores for trend analysis
persist_risk_scores() {
    > "$RISK_PREV_FILE"
    for dev in "${!SMART_STATE[@]}"; do
        local msg="${SMART_MSGS[$dev]}"
        local score
        score=$(risk_score_quick "${SMART_STATE[$dev]}" "$msg")
        echo "$dev $score" >> "$RISK_PREV_FILE"
    done
}
persist_risk_scores
exit 0
