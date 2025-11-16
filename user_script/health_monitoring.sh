#!/bin/bash
set -euo pipefail
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
# --- SMART Test Scheduling ---
SMART_TEST_TYPE="short"       # SMART test type to run: short|long
SMART_INTERVAL_DAYS=30        # Minimum days between long tests per disk
SHORT_TEST_POLL=1             # If 1, poll short test until it completes
SHORT_TEST_MAX_WAIT=180       # Max seconds to wait while polling short tests
SHORT_TEST_POLL_INTERVAL=10   # Interval between polls (seconds)

# --- Capacity Thresholds ---
WARN_THRESHOLD_PERCENT=80     # Per-disk usage percent that triggers a warning
CRITICAL_THRESHOLD_PERCENT=90 # Per-disk usage percent that triggers a critical alert
THRESHOLD=90                  # Array/pools overall usage percent considered full
NEAR_THRESHOLD_DELTA=5        # Consider "near full" within this percent of THRESHOLD
POOL_EXCLUDES=("ramtmp" "user0") # Pool names to exclude from pool totals

# --- Feature Toggles ---
ENABLE_BTRFS_SCRUB=0          # 1: start btrfs scrub; 0: only parse last status
ENABLE_XFS_CHECK=0            # 1: run xfs_repair -n; 0: skip XFS metadata check
ENABLE_POOL_DEVICE_SMART=1    # 1: include per-device SMART lines for pools
VERBOSE_OK=0                  # 1: show OK lines; 0: suppress OK lines
JSON_EXPORT=1                 # 1: write JSON summary to disk
JSON_INCLUDE_DISKS=1          # 1: include per-disk details in JSON (poh/endurance)
HISTORY_WINDOW_DAYS=7         # Window (days) for growth averages and trends
RISK_SCORING_ENABLED=1        # 1: show risk scores section
LIFECYCLE_ENABLED=1           # 1: show lifecycle buckets (replace/monitor/healthy)
AGE_AWARE_ENABLED=1           # 1: annotate near-endurance devices
SHARE_BREAKDOWN_ENABLED=0     # 1: compute per-share usage (uses du; can be heavy)
SHARE_TOP_N=5                 # Show top N shares by size/growth
LOG_PRUNE_ENABLED=1           # 1: prune old timestamped run logs in LOG_DIR
LOG_MAX_DAYS=3                # Remove run logs older than this many days (0 disables age pruning)
LOG_MAX_COUNT=0               # After age pruning, keep at most this many run logs per pattern (0 disables count pruning)
ADAPTIVE_LONG_TEST_ENABLED=1  # 1: enable adaptive long test scheduling
LONG_TEST_RISK_THRESHOLD=50   # Risk score >= triggers long test escalation
LONG_TEST_CRITICAL_MIN_DAYS=7 # If SMART critical and last long test older than this days -> force long
LONG_TEST_RISK_MIN_DAYS=0     # Minimum days since last long test for risk-based escalation (0=ignore)
TBW_DAYS_WARN=30              # Remaining TBW forecast days < triggers WARNING
TBW_DAYS_CRIT=7               # Remaining TBW forecast days < triggers CRITICAL
ADAPTIVE_ALERTS_ENABLED=1     # 1: emit alert entries for adaptive escalations (warning/critical)
POH_RESET_CRIT_THRESHOLD=500  # If POH drops by > this many hours classify as critical reset
NVME_WEAR_REGRESSION_WARN=1   # Flag any drop in NVMe Percentage Used (wear regression)
LOG_MIRROR_STDOUT=1           # 1: also echo log lines to stdout; 0: silent (only log files)

# --- SMART Thresholds (SATA/NVMe) ---
RELOC_WARNING=1               # Reallocated sectors >= triggers warning
RELOC_CRITICAL=10             # Reallocated sectors >= triggers critical
PEND_WARNING=1                # Pending sectors >= triggers critical
TEMP_WARNING=60               # Temperature C >= triggers warning
TEMP_CRITICAL=70              # Temperature C >= triggers critical
NVME_PERCENT_USED_WARN=80     # NVMe Percentage Used >= triggers warning
NVME_PERCENT_USED_CRIT=90     # NVMe Percentage Used >= triggers critical
LOAD_CYCLE_WARN=300000        # HDD Load_Cycle_Count >= triggers warning
LOAD_CYCLE_CRIT=600000        # HDD Load_Cycle_Count >= triggers critical
SSD_WEAR_WARN=20              # SSD life remaining (%) <= triggers warning
SSD_WEAR_CRIT=10              # SSD life remaining (%) <= triggers critical
TBW_WARN_TB=0                 # If >0, warn when TBW exceeds this TB (fallback)
UNSAFE_SDWN_DELTA_WARN=1      # Warn if NVMe unsafe shutdowns increased by >= this
NVME_AVAIL_SPARE_WARN=5       # Warn if NVMe Available Spare (%) below this
REPORTED_UNC_CRIT=1           # SATA attr 187: any >0 is critical
CMD_TIMEOUT_WARN=1            # SATA attr 188: >= triggers warning
CMD_TIMEOUT_CRIT=50           # SATA attr 188: >= triggers critical
REALLOC_EVENT_WARN=1          # SATA attr 196: >= triggers warning
REALLOC_EVENT_CRIT=10         # SATA attr 196: >= triggers critical
END_TO_END_ERR_CRIT=1         # SATA attr 184: any >0 is critical
SOFT_READ_ERR_WARN=1000       # SATA attr 201: >= triggers warning (heuristic)
SNAPSHOT_WARN=100             # btrfs snapshot count >= triggers warning
SNAPSHOT_CRIT=500             # btrfs snapshot count >= triggers critical

# --- SMART Trend / Parity Suggestion ---
PARITY_SUGGEST_ENABLED=1      # 1: evaluate SMART deltas to suggest parity check / extended test
PARITY_PENDING_MIN_DELTA=1    # Pending sectors increase >= triggers suggestion
PARITY_REALLOC_MIN_DELTA=1    # Reallocated sectors increase >= triggers suggestion
PARITY_REALLOC_EVT_MIN_DELTA=1 # Reallocation event count increase >= triggers suggestion
PARITY_UNC_MIN_DELTA=1        # Offline or reported uncorrectable increase >= triggers suggestion
SMART_TREND_ALERTS_ENABLED=1  # 1: emit warning alerts for SMART trend increases

# --- Disk I/O Error Frequency ---
IO_ERROR_MONITOR_ENABLED=1      # 1: enable syslog scanning for disk I/O error frequency
IO_ERROR_LOG_FILE="/var/log/syslog" # Path to syslog (fallback to dmesg if missing)
IO_ERROR_WINDOW_MINUTES=60      # Time window (minutes) for frequency and de-duplication
IO_ERROR_WARN_THRESHOLD=5       # Unique error events >= warning threshold
IO_ERROR_CRIT_THRESHOLD=20      # Unique error events >= critical threshold
IO_ERROR_DEDUP_ENABLED=1        # 1: de-duplicate identical message hashes inside window

# --- Risk Scoring Weights (tunable) ---
W_SEV_CRIT=70                 # Base score for CRITICAL devices
W_SEV_WARN=30                 # Base score for WARNING devices
W_PENDING=40                  # Weight for pending sectors
W_UNCORR=50                   # Weight for offline/reported uncorrectables
W_REALLOC=15                  # Weight for reallocated sectors present
W_REALLOC_EVENTS=10           # Weight for reallocation events
W_CMD_TIMEOUT=10              # Weight for command timeouts
W_CRC=5                       # Weight for UDMA CRC errors
W_SSD_LIFE=20                 # Weight for low SSD life remaining
W_NVME_WEAR=20                # Weight for high NVMe wear
W_TEMP=10                     # Weight for high temperature
W_E2E=40                      # Weight for end-to-end errors
W_SOFT_READ=10                # Weight for soft read error rate
W_NVME_RO=80                  # Weight for NVMe read-only mode
W_NVME_REL=60                 # Weight for NVMe reliability degraded
W_AGE_NEAR=30                 # Extra weight for near-endurance devices
RISK_REPLACE=80               # Score >= goes to Replace Soon bucket
RISK_MONITOR=30               # Score >= goes to Monitor bucket

# --- Internals (do not modify unless needed) ---
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
declare -A TBW_DAILY_MAP      # Map device -> daily TBW bytes
declare -A TBW_DAYSLEFT_MAP   # Map device -> forecast days remaining
declare -A TBW_STATUS_MAP     # Map device -> TBW status (OK/WARNING/CRITICAL)
declare -A IO_ERROR_RAW_MAP   # Map device -> raw I/O error line count (duplicates included)
declare -A IO_ERROR_UNIQUE_MAP # Map device -> unique I/O error event count (dedup within window)

# --- Runtime ---
SCRIPT_START_EPOCH=$(date +%s)

# -- Adaptive Escalation Tracking ---
ADAPTIVE_DECISIONS=""
declare -A PREV_RISK
: "${STATE_DIR:=/boot/logs/disk-health/state}"
RISK_PREV_FILE="${RISK_PREV_FILE:-$STATE_DIR/risk_prev.log}"
if [ -f "$RISK_PREV_FILE" ]; then
    while read -r dev score; do
        [[ -z "$dev" || -z "$score" ]] && continue
        PREV_RISK["$dev"]="$score"
    done < "$RISK_PREV_FILE"
fi

# -- Logs Paths ---
LOG_DIR="/boot/logs/disk-health"                  # Base directory for logs files
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)                # Timestamp used for rotating log filenames
MASTER_LOG="$LOG_DIR/disk_health_$TIMESTAMP.log"  # Consolidated master log
SMART_LOG="$MASTER_LOG"
BTRFS_LOG="$MASTER_LOG"
XFS_LOG="$MASTER_LOG"

# -- Unified Logging ---
log_to() {
    local file="$1"; shift
    local msg="$*"
    if (( LOG_MIRROR_STDOUT == 1 )); then
        echo "$msg"
    fi
    echo "$msg" >> "$file"
}
# -- Unified Subsystem ---
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

# --- Severity (INFO/WARN/CRIT) ---
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

# --- State Files ---
STATE_DIR="/boot/logs/disk-health/state"                    # Base directory for state files
mkdir -p "$STATE_DIR"
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

# -- JSON Export ---
JSON_EXPORT_DIR="/boot/logs/disk-health/json"               # Directory to write JSON summary
mkdir -p "$JSON_EXPORT_DIR"
HEALTH_JSON="$JSON_EXPORT_DIR/disks_health_summary.json"    # Health JSON output file

# --- Notification Titles ---
NOTIFY_TITLE_SMART="SMART Test Alert"                       # SMART test notifications
NOTIFY_TITLE_BTRFS="Btrfs Scrub Alert"                      # Btrfs scrub notifications
NOTIFY_TITLE_XFS="XFS Alert"                                # XFS filesystem notifications
NOTIFY_TITLE_DISKIO="Disk I/O Alert"                        # Disk I/O notifications

# -----------------------------------------------

# Prune old timestamped run logs based on age and count limits.
prune_old_run_logs() {
    (( LOG_PRUNE_ENABLED == 1 )) || return 0
    local patterns=("disk_health_*.log" "smart_*.log" "btrfs_*.log" "xfs_*.log")
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
    pm_state=$(echo "$SUBSYSTEM_LINES" | awk -F': ' '/^Per-Mount:/ {print $2; exit}')
    local runtime_part=""
    if [[ -n "${RUNTIME_STR:-}" ]]; then
        runtime_part=" | Runtime ${RUNTIME_STR}"
    fi
    local summary_line="SMART ${sm_state:-N/A} | Btrfs ${bt_state:-N/A} | XFS ${xfs_state:-N/A} | Capacity ${cap_state:-N/A} | Per-Mount ${pm_state:-N/A} | ${crit_count} crit / ${warn_count} warn${runtime_part}"
    local body_norm
    body_norm=$(printf "%s\n" "$body" | awk '{sub(/[ \t]+$/, "")} NF{print; blank=0; next} !blank{print ""; blank=1}')
    local BIN="/usr/local/emhttp/webGui/scripts/notify"
    if [ -x "$BIN" ]; then
        "$BIN" -e "Disk Health Monitor" -s "$title" -d "$summary_line" -m "$body_norm" -i "$icon"
    else
        logger -t "Disk Health Monitor" "$title: $summary_line"
        logger -t "Disk Health Monitor" "$body_norm"
    fi
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

# Fetch and cache raw smartctl -a output for NVMe.
get_nvme_raw() {
    local d=$(base_device "$1")
    if [[ -n "${NVME_RAW[$d]:-}" ]]; then
        echo "${NVME_RAW[$d]}"; return 0
    fi
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

declare -A LAST_TEST
if [ -f "$SMART_LAST" ]; then
    while read -r disk date; do
        LAST_TEST["$disk"]=$date
    done < "$SMART_LAST"
fi

declare -A NVME_LAST_UNSAFE
if [ -f "$NVME_STATE_FILE" ]; then
    while read -r dev count; do
        NVME_LAST_UNSAFE["$dev"]=$count
    done < "$NVME_STATE_FILE"
fi

declare -A PREV_ATTR
if [ -f "$PREV_ATTR_FILE" ]; then
    while read -r line; do
        [[ -z "$line" ]] && continue
        local disk token
        disk=$(echo "$line" | awk '{print $1}')
        for token in $(echo "$line" | awk '{for(i=2;i<=NF;i++) print $i}'); do
            local k v
            k=${token%%=*}; v=${token#*=}
            [[ -n "$k" ]] && PREV_ATTR["$disk|$k"]="$v"
        done
    done < "$PREV_ATTR_FILE"
fi
declare -A CUR_ATTR

declare -A NEW_SEEN
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
        duw=$(echo "$nvme_output" | awk -F: '/Data Units Written/ {gsub(/,| /,"",$2); print $2; exit}')
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
            if [[ $nvme_temp -ge $TEMP_CRITICAL ]]; then
                state="CRITICAL"; messages+=("NVMe Temp ${nvme_temp}C >= ${TEMP_CRITICAL}C")
            elif [[ $nvme_temp -ge $TEMP_WARNING && $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("NVMe Temp ${nvme_temp}C >= ${TEMP_WARNING}C")
            fi
        fi
        CUR_ATTR["$disk|nvme_percent_used"]="$percent_used"
        CUR_ATTR["$disk|poh"]="$poh"
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
        if [[ $temp -ge $TEMP_CRITICAL ]]; then
            state="CRITICAL"; messages+=("Temp ${temp}C >= ${TEMP_CRITICAL}C")
        elif [[ $temp -ge $TEMP_WARNING && $state != CRITICAL ]]; then
            [[ $state == OK ]] && state="WARNING"; messages+=("Temp ${temp}C >= ${TEMP_WARNING}C")
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
    fi
    echo "$state"; for m in "${messages[@]}"; do echo "$m"; done
}

# Fetch latest self-test entry from smartctl log.
get_latest_selftest_info() {
    local disk=$1
    local out
    if [[ $disk == /dev/nvme* ]]; then
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
    local waited=0
    local info status sev msg
    while (( waited < SHORT_TEST_MAX_WAIT )); do
        info=$(get_latest_selftest_info "$disk")
        if [[ "$info" == "|||" ]]; then
            echo "OK|Self-test log unavailable; skipping polling"
            return 0
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
    [[ $disk == /dev/sd* ]] && hdparm -I "$disk" >/dev/null 2>&1 || true
    local flag="-t short"
    local selftest poh_attr current_poh last_long_hours_diff="" last_long_poh="" threshold_hours=$(( SMART_INTERVAL_DAYS * 24 ))
    if [[ $disk == /dev/nvme* ]]; then
        selftest=$(smartctl -l selftest -d nvme "$disk" 2>/dev/null || true)
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

    log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Starting SMART ${flag/-t /} test on $disk"
    local exec_status existing_in_progress=0
    if [[ $disk == /dev/nvme* ]]; then
        exec_status=$(smartctl -c -d nvme "$disk" 2>/dev/null | awk -F: '/Self-test execution status/ {print $2}') || true
    else
        exec_status=$(smartctl -c "$disk" 2>/dev/null | awk -F: '/Self-test execution status/ {print $2}') || true
    fi
    if echo "$exec_status" | grep -qi 'in progress'; then
        existing_in_progress=1
    fi
    log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Starting SMART ${flag/-t /} test on $disk"
    if [[ $existing_in_progress -eq 1 ]]; then
        log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Self-test already in progress on $disk; skipping new start (status: ${exec_status})"
    else
        if [[ $disk == /dev/nvme* ]]; then
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
            local attr value prev cur delta
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
    if [[ $ENABLE_BTRFS_SCRUB -eq 1 ]]; then
        log_btrfs "$(date '+%Y-%m-%d %H:%M:%S') - BTRFS scrubbing starting"
    else
        log_btrfs "$(date '+%Y-%m-%d %H:%M:%S') - BTRFS scrubbing disabled"
    fi
    local mountpoints
    mountpoints=$(mount | awk '$5=="btrfs" {print $3}')
    for mp in $mountpoints; do
        local raid_type
        raid_type=$(btrfs filesystem df -p "$mp" 2>/dev/null | awk -F',' '/Data/ {gsub(/ /,"",$2); print $2; exit}') || true
        raid_type=${raid_type:-UNKNOWN}
        local status_pre
        status_pre=$(btrfs scrub status -d "$mp" 2>/dev/null || true)
        if [[ $ENABLE_BTRFS_SCRUB -eq 1 ]]; then
            if echo "$status_pre" | grep -qi 'running'; then
                log_btrfs "$(date '+%Y-%m-%d %H:%M:%S') - Btrfs scrub already running on $mp; will parse current running status"
            else
                log_btrfs "$(date '+%Y-%m-%d %H:%M:%S') - Initiating asynchronous Btrfs scrub on $mp (RAID: $raid_type)"
                btrfs scrub start "$mp" >>"$BTRFS_LOG" 2>&1 || true
            fi
        else
            log_btrfs "$(date '+%Y-%m-%d %H:%M:%S') - Btrfs scrub disabled; parsing last recorded status only for $mp"
        fi
        local status corrected uncorrectable msg
        status=$(btrfs scrub status -d "$mp" 2>/dev/null)
        log_btrfs "$(date '+%Y-%m-%d %H:%M:%S') - Btrfs scrub status for $mp:"
        log_btrfs "$status"
        corrected=$(echo "$status" | awk -F'[: ]+' '/corrected errors/ {print $NF; exit}'); corrected=${corrected:-0}
        uncorrectable=$(echo "$status" | awk -F'[: ]+' '/unrecoverable errors/ {print $NF; exit}'); uncorrectable=${uncorrectable:-0}
        if [[ $uncorrectable -gt 0 ]]; then
            if [[ "$raid_type" =~ RAID0 ]]; then
                msg="CRITICAL: $mp RAID0 unrecoverable errors=$uncorrectable"
            else
                msg="CRITICAL: $mp unrecoverable errors=$uncorrectable"
            fi
            log_btrfs "$(date '+%Y-%m-%d %H:%M:%S') - $msg"
            record_alert critical "$NOTIFY_TITLE_BTRFS" "$msg"
        elif [[ $corrected -gt 0 ]]; then
            msg="WARNING: $mp scrub corrected=$corrected"
            log_btrfs "$(date '+%Y-%m-%d %H:%M:%S') - $msg"
            record_alert warning "$NOTIFY_TITLE_BTRFS" "$msg"
        fi
    done
    log_btrfs "$(date '+%Y-%m-%d %H:%M:%S') - Btrfs scrubbing completed"
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
log_smart "$(date '+%Y-%m-%d %H:%M:%S') - Starting SMART tests (type=$SMART_TEST_TYPE)"
check_completed_long_tests
for disk in $(get_all_disks); do
    run_smart_test "$disk"
done
save_last_test
log_smart "$(date '+%Y-%m-%d %H:%M:%S') - SMART tests completed"
augment_messages_with_deltas
save_nvme_state
monitor_btrfs
check_btrfs_snapshots() {
# Check btrfs snapshot counts against thresholds.
    local mountpoints
    mountpoints=$(mount | awk '$5=="btrfs" {print $3}')
    for mp in $mountpoints; do
        local list cnt
        list=$(btrfs subvolume list "$mp" 2>/dev/null || true)
        [[ -z "$list" ]] && continue
        cnt=$(printf "%s\n" "$list" | grep -Eio '(^|/)[@.]?snapshots?(/|$)|(^|/)snapshot[^/]*' | wc -l)
        if (( cnt >= SNAPSHOT_CRIT )); then
            record_alert critical "$NOTIFY_TITLE_BTRFS" "Critical: $mp snapshot count $cnt >= $SNAPSHOT_CRIT"
        elif (( cnt >= SNAPSHOT_WARN )); then
            record_alert warning "$NOTIFY_TITLE_BTRFS" "Warning: $mp snapshot count $cnt >= $SNAPSHOT_WARN"
        fi
    done
}
check_btrfs_snapshots
monitor_xfs  # XFS metadata check (if enabled earlier)
build_mount_device_map  # Populate array mountpoint -> device map

# Scan syslog/dmesg for disk I/O errors, count unique occurrences per device over time window.
scan_syslog_disk_errors() {
    (( IO_ERROR_MONITOR_ENABLED == 1 )) || { IO_ERROR_FREQ_SECTION=""; return 0; }
    local window_sec=$(( IO_ERROR_WINDOW_MINUTES * 60 ))
    local now_epoch=$(date +%s)
    local cutoff=$(( now_epoch - window_sec ))
    local log_src
    if [[ -f "$IO_ERROR_LOG_FILE" ]]; then
        log_src=$(tail -n 20000 "$IO_ERROR_LOG_FILE" 2>/dev/null)
    else
        log_src=$(dmesg 2>/dev/null | tail -n 20000)
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
        local ts="${HASH_SEEN[$key]}" dv="${key%%|*}" h="${key#*|}"; echo "$ts $dv $h" >> "$new_hist"
    done
    while read -r line; do
        echo "$line" | grep -qiE 'I/O error|blk_update_request|end_request|failed command: (READ|WRITE)|hard resetting link|link is slow to respond|exception Emask' || continue
        local devices=()
        while read -r sd; do devices+=("/dev/$sd"); done < <(echo "$line" | grep -oE 'sd[a-z]+' | sort -u)
        while read -r nv; do devices+=("/dev/$nv"); done < <(echo "$line" | grep -oE 'nvme[0-9]+n[0-9]+' | sort -u)
        [[ ${#devices[@]} -eq 0 ]] && continue
        local ts_part epoch
        ts_part=$(echo "$line" | awk '{print $1" "$2" "$3}')
        if echo "$ts_part" | grep -qE '^[A-Z][a-z]{2} [0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'; then
            epoch=$(date -d "$ts_part $(date +%Y)" +%s 2>/dev/null || echo "$now_epoch")
        else
            epoch=$now_epoch
        fi
        local hash
        hash=$(echo "$line" | sha1sum | awk '{print $1}')
        for dev in "${devices[@]}"; do
            (( IO_ERROR_RAW_MAP[$dev]++ ))
            if (( IO_ERROR_DEDUP_ENABLED == 1 )) && [[ -n "${HASH_SEEN["$dev|$hash"]:-}" ]]; then
                continue
            fi
            HASH_SEEN["$dev|$hash"]=$epoch
            echo "$epoch $dev $hash" >> "$new_hist"
            (( IO_ERROR_UNIQUE_MAP[$dev]++ ))
        done
    done < <(printf "%s\n" "$log_src")
    mv "$new_hist" "$IO_ERROR_HISTORY_FILE" 2>/dev/null || true
    local lines=""
    for dev in "${!IO_ERROR_RAW_MAP[@]}"; do
        local raw=${IO_ERROR_RAW_MAP[$dev]:-0} uniq=${IO_ERROR_UNIQUE_MAP[$dev]:-0} mark=""
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
}
scan_syslog_disk_errors
evaluate_per_mount_thresholds

# ---------------- Notification Builder ----------------
severity_rank() { case "$1" in CRITICAL) echo 2;; WARNING) echo 1;; *) echo 0;; esac; }
status_word()   { case "$1" in 2) echo "CRITICAL";; 1) echo "WARNING";; *) echo "OK";; esac; }
map_emoji()     { case "$1" in 2) printf "🔴";; 1) printf "🟡";; *) printf "🟢";; esac; }

# Build storage array and pool usage lines with severity
build_storage_and_disk_lines() {
    ARRAY_MAX_SEV=0; POOLS_MAX_SEV=0
    ARRAY_DISK_LINES=""; POOL_LINES=""; POOL_DEVICE_LINES=""

    # Array disks
    local arr=()
    for d in /mnt/disk*; do [[ -d "$d" ]] || continue; mountpoint -q "$d" || continue; arr+=("$d"); done
    ARRAY_COUNT=${#arr[@]}
    local arr_used=0 arr_size=0
    for d in "${arr[@]}"; do
        local line=$(df -B1 "$d" 2>/dev/null | awk 'NR==2') || continue
        local sz=$(echo "$line" | awk '{print $2}') u=$(echo "$line" | awk '{print $3}')
        sz=${sz:-0}; u=${u:-0}
        arr_size=$((arr_size + sz)); arr_used=$((arr_used + u))
        local pct=$(awk "BEGIN{ if($sz>0) printf \"%.1f\",($u/$sz)*100; else print 0 }")
        local usage_sev=0
        if (( $(awk "BEGIN{print ($pct >= $CRITICAL_THRESHOLD_PERCENT)}") )); then usage_sev=2
        elif (( $(awk "BEGIN{print ($pct >= $WARN_THRESHOLD_PERCENT)}") )); then usage_sev=1
        fi
        local dev sm_state sm_msg
        dev=$(smart_device_for_mount "$d")
        sm_state=${SMART_STATE["$dev"]:-OK}
        sm_msg=${SMART_MSGS["$dev"]:-}
        local sm_rank=$(severity_rank "$sm_state")
        (( sm_rank > usage_sev )) && usage_sev=$sm_rank
        (( usage_sev > ARRAY_MAX_SEV )) && ARRAY_MAX_SEV=$usage_sev
        local sev_word=$(status_word "$usage_sev")
        local reasons=()
        if (( $(awk "BEGIN{print ($pct >= $WARN_THRESHOLD_PERCENT)}") )); then
            reasons+=("Usage ${pct}%")
        fi
        if [[ -n "$sm_msg" && "$sm_state" != OK ]]; then
            reasons+=("SMART: $sm_msg")
        fi
        local reason_str=""
        if (( ${#reasons[@]} > 0 )); then
            reason_str=$(printf "%s; " "${reasons[@]}")
            reason_str=${reason_str%%; }
        fi
        if (( VERBOSE_OK == 1 || usage_sev > 0 )); then
            if [[ -n "$reason_str" ]]; then
                ARRAY_DISK_LINES+=$(printf "%-10s %10s / %-10s (%5s%%) [%s] %s\n" "$(basename "$d")" "$(human_readable "$u")" "$(human_readable "$sz")" "$pct" "$sev_word" "$reason_str")
            else
                ARRAY_DISK_LINES+=$(printf "%-10s %10s / %-10s (%5s%%) [%s]\n" "$(basename "$d")" "$(human_readable "$u")" "$(human_readable "$sz")" "$pct" "$sev_word")
            fi
        fi
    done
    ARRAY_TOTAL_BYTES=$arr_size
    ARRAY_USED_BYTES=$arr_used
    if (( arr_size > 0 )); then
        ARRAY_PERCENT=$(awk "BEGIN{printf \"%.1f\", ($arr_used/$arr_size)*100}")
        ARRAY_USED_HR=$(human_readable "$arr_used")
        ARRAY_TOTAL_HR=$(human_readable "$arr_size")
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
        local line=$(df -B1 "$p" 2>/dev/null | awk 'NR==2') || continue
        local sz=$(echo "$line" | awk '{print $2}') u=$(echo "$line" | awk '{print $3}')
        sz=${sz:-0}; u=${u:-0}
        pools_size=$((pools_size + sz)); pools_used=$((pools_used + u))
        local pct=$(awk "BEGIN{ if($sz>0) printf \"%.1f\",($u/$sz)*100; else print 0 }")
        local usage_sev=0
        if (( $(awk "BEGIN{print ($pct >= $CRITICAL_THRESHOLD_PERCENT)}") )); then usage_sev=2
        elif (( $(awk "BEGIN{print ($pct >= $WARN_THRESHOLD_PERCENT)}") )); then usage_sev=1
        fi
        (( usage_sev > POOLS_MAX_SEV )) && POOLS_MAX_SEV=$usage_sev
        if (( VERBOSE_OK == 1 || usage_sev > 0 )); then
            POOL_LINES+=$(printf "%-10s %10s / %-10s (%5s%%) %s\n" "$name" "$(human_readable "$u")" "$(human_readable "$sz")" "$pct" "$(status_word "$usage_sev")")
        fi

        if [[ $ENABLE_POOL_DEVICE_SMART -eq 1 ]]; then
            local fstype devlist
            fstype=$(findmnt -n -o FSTYPE "$p" 2>/dev/null || true)
            if [[ "$fstype" == "btrfs" ]]; then
                devlist=$(btrfs filesystem show "$p" 2>/dev/null | awk '/devid/ && /path/ {for(i=1;i<=NF;i++){if($i=="path"){print $(i+1)}}}');
                if [[ -z "$devlist" ]]; then
                    devlist=$(btrfs filesystem show "$p" 2>/dev/null | awk '/devid/ {print $NF}')
                fi
            else
                devlist=$(findmnt -n -o SOURCE "$p" 2>/dev/null || true)
            fi
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
                if (( VERBOSE_OK == 1 || rank > 0 )); then
                    if [[ -n "$msg" ]]; then
                        local model cap wear_info=""
                        model=$(get_device_model "$rootdv")
                        cap=$(get_device_capacity_tb "$rootdv")
                        if [[ "$msg" == *"NVMe wear"* ]]; then
                            wear_info=$(echo "$msg" | grep -o 'NVMe wear [0-9]*%' | head -n1)
                        elif [[ "$msg" == *"SSD life remaining"* ]]; then
                            wear_info=$(echo "$msg" | grep -o 'SSD life remaining [0-9]*%' | head -n1)
                        fi
                        POOL_DEVICE_LINES+=$(printf "%-10s %-12s [%s] %sTB %s %s%s\n" "$name" "$(basename "$rootdv")" "$(status_word "$rank")" "$cap" "$model" "${wear_info:+($wear_info)}" "${msg:+ SMART: $msg}")
                    else
                        local model cap
                        model=$(get_device_model "$rootdv")
                        cap=$(get_device_capacity_tb "$rootdv")
                        POOL_DEVICE_LINES+=$(printf "%-10s %-12s [%s] %sTB %s\n" "$name" "$(basename "$rootdv")" "$(status_word "$rank")" "$cap" "$model")
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
    local sm=OK bt=OK xfs=OK cap=OK pm=OK end=OK ad=OK
    for a in "${ALERT_CRIT[@]}"; do
        [[ $a == "$NOTIFY_TITLE_SMART"* ]] && sm=CRITICAL
        [[ $a == "$NOTIFY_TITLE_BTRFS"* ]] && bt=CRITICAL
        [[ $a == "$NOTIFY_TITLE_XFS"* ]] && xfs=CRITICAL
        [[ $a == *Capacity* ]] && cap=CRITICAL
        [[ $a == Storage\ Critical* ]] && pm=CRITICAL
        [[ $a == TBW\ Endurance* ]] && end=CRITICAL
        [[ $a == Adaptive\ SMART* ]] && ad=CRITICAL
    done
    for a in "${ALERT_WARN[@]}"; do
        [[ $sm != CRITICAL && $a == "$NOTIFY_TITLE_SMART"* ]] && sm=WARNING
        [[ $bt != CRITICAL && $a == "$NOTIFY_TITLE_BTRFS"* ]] && bt=WARNING
        [[ $xfs != CRITICAL && $a == "$NOTIFY_TITLE_XFS"* ]] && xfs=WARNING
        [[ $cap != CRITICAL && $a == *Capacity* ]] && cap=WARNING
        [[ $pm != CRITICAL && $a == Storage\ Warning* ]] && pm=WARNING
        [[ $end != CRITICAL && $a == TBW\ Endurance* ]] && end=WARNING
        [[ $ad != CRITICAL && $a == Adaptive\ SMART* ]] && ad=WARNING
    done
    SUBSYSTEM_LINES="SMART: $sm
Btrfs: $( [[ $ENABLE_BTRFS_SCRUB -eq 1 ]] && echo "$bt" || echo "Disabled")
XFS:   $( [[ $ENABLE_XFS_CHECK -eq 1 ]] && echo "$xfs" || echo "Disabled")
Capacity: $cap
Per-Mount: $pm
Endurance: $end
Adaptive: $ad"
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
            case "$x" in
                *"Reallocated"*)
                    [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: Reallocated sectors rising; monitor; replace if trend increases.\n" ;;
                *"Pending sectors"*)
                    [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: Pending sectors; backup; run long test; plan replacement.\n" ;;
                *"Offline Uncorrectable"*)
                    [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: Offline uncorrectable; clone and replace soon.\n" ;;
                *"UDMA CRC Errors"*)
                    [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: CRC errors; reseat/replace SATA cable.\n" ;;
                *"Temp "*C*)
                    [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: High temperature; improve cooling / airflow.\n" ;;
                *"NVMe wear"*)
                    rec+=" - ${disk_ref:-NVMe}: High NVMe wear level; schedule replacement.\n" ;;
                *"long self-test CRITICAL"*)
                    [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: Failed long test; migrate data; replace drive.\n" ;;
                *"short self-test warning"*)
                    [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: Short test warning; run a long test.\n" ;;
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
                    [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: Reallocation events logged; monitor trend; consider replacement if increasing.\n" ;;
                *"Reported Uncorrectable"*)
                    [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: Uncorrectable errors; backup immediately; plan replacement.\n" ;;
                *"Command Timeout events"*)
                    [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: Command timeouts; inspect cabling/power; monitor closely.\n" ;;
                *"End-to-End Errors"*)
                    [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: Data path integrity errors; replace drive/controller.\n" ;;
                *"Soft Read Error Rate"*)
                    [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: Elevated soft read errors; run long test; monitor trend.\n" ;;
                *"NVMe reliability degraded"*)
                    [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: NVMe reliability degraded; schedule replacement soon.\n" ;;
                *"NVMe media in read-only mode"*)
                    [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: NVMe is read-only; clone data; replace immediately.\n" ;;
                *"NVMe volatile memory backup failed"*)
                    [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: NVMe volatile memory backup failed; ensure power protection; plan replacement.\n" ;;
                *"TBW Endurance"*)
                    if echo "$x" | grep -qi 'CRITICAL'; then
                        [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: TBW near exhaustion; schedule replacement and migrate workloads.\n"
                    else
                        [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: TBW forecast low; reduce write amplification and plan refresh.\n"
                    fi ;;
                *"Adaptive SMART"*)
                    if echo "$x" | grep -qi 'critical'; then
                        [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: Adaptive escalation due to critical SMART state; perform data backup, review SMART details, consider immediate replacement.\n"
                    else
                        [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: Adaptive escalation on rising risk; monitor subsequent runs, analyze contributing SMART attributes, schedule proactive diagnostics.\n"
                    fi ;;
                *"I/O errors unique"*)
                    [[ -n "$disk_ref" ]] && rec+=" - $disk_ref: High I/O error frequency; check SATA/NVMe cabling, power stability, controller logs; consider moving data & replacing if persistent.\n" ;;
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
    if [[ -n "$CAPACITY_FORECAST" ]] && echo "$CAPACITY_FORECAST" | grep -q 'days to' ; then
        local soon_arr=$(echo "$CAPACITY_FORECAST" | awk -F'Array avg daily growth:' '{print $2}' | awk -F'days to' '{print $2}' | awk '{print $NF}' | tr -d ':')
        local soon_pool=$(echo "$CAPACITY_FORECAST" | awk -F'Pools avg daily growth:' '{print $2}' | awk -F'days to' '{print $2}' | awk '{print $NF}' | tr -d ':')
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
    RECOMMEND_SECTION="$rec"
}

# Build notification subject line
build_subject() {
    SUBJECT="Disks Health"
}

# Summarize disk health states
build_disk_health_summary() {
    local crit_count=0 warn_count=0 pending_count=0 uncorrect_count=0 high_temp=0 nvme_wear_warn=0 read_only=0 reliability=0 timeout_warn=0 realloc_events_warn=0 end2end_count=0 soft_read_warn=0
    for dev in "${!SMART_STATE[@]}"; do
        local st="${SMART_STATE[$dev]}" msg="${SMART_MSGS[$dev]}"
        [[ $st == CRITICAL ]] && ((crit_count++))
        [[ $st == WARNING ]] && ((warn_count++))
        [[ $msg == *"Pending sectors"* ]] && ((pending_count++))
        [[ $msg == *"Offline Uncorrectable"* || $msg == *"Reported Uncorrectable"* ]] && ((uncorrect_count++))
        [[ $msg == *"Temp"* ]] && ((high_temp++))
        [[ $msg == *"NVMe wear"* ]] && ((nvme_wear_warn++))
        [[ $msg == *"read-only mode"* ]] && ((read_only++))
        [[ $msg == *"reliability degraded"* ]] && ((reliability++))
        [[ $msg == *"Command Timeout"* ]] && ((timeout_warn++))
        [[ $msg == *"Reallocated Event Count"* ]] && ((realloc_events_warn++))
        [[ $msg == *"End-to-End Errors"* ]] && ((end2end_count++))
        [[ $msg == *"Soft Read Error Rate"* ]] && ((soft_read_warn++))
    done
    CRIT_DISK_COUNT=$crit_count
    WARN_DISK_COUNT=$warn_count
    DISK_HEALTH_SUMMARY="Disk Health Summary:\n Critical disks: $crit_count\n Warning disks: $warn_count\n Pending sector disks: $pending_count\n Uncorrectable error disks: $uncorrect_count\n High temp disks: $high_temp\n NVMe wear warnings: $nvme_wear_warn\n NVMe read-only: $read_only\n NVMe reliability degraded: $reliability\n Command timeout warnings: $timeout_warn\n Reallocated event warnings: $realloc_events_warn\n End-to-end error disks: $end2end_count\n Soft read error warnings: $soft_read_warn"
}

# Compute risk scores for disks based on SMART attributes and categorize into lifecycle buckets
compute_risk_and_lifecycle() {
    (( RISK_SCORING_ENABLED == 1 )) || return 0
    local risk_lines="" lifecycle_lines="" age_lines=""
    declare -A RISK SCORE_ATTR AGE_CLASS
    for dev in "${!SMART_STATE[@]}"; do
        local st="${SMART_STATE[$dev]}" msg="${SMART_MSGS[$dev]}"
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
        [[ $msg == *"Temp"* ]] && ((score += W_TEMP))
        [[ $msg == *"End-to-End Errors"* ]] && ((score += W_E2E))
        [[ $msg == *"Soft Read Error Rate"* ]] && ((score += W_SOFT_READ))
        [[ $msg == *"read-only mode"* ]] && ((score += W_NVME_RO))
        [[ $msg == *"reliability degraded"* ]] && ((score += W_NVME_REL))
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
        if (( AGE_AWARE_ENABLED == 1 )); then
            if [[ -n "${AGE_CLASS[$dev]:-}" ]]; then
                age_lines+="$(basename "$dev") (${AGE_CLASS[$dev]}) POH=${poh}"
                age_lines+="\n"
            fi
        fi
        RISK[$dev]=$score
    done
    local sorted=$(for d in "${!RISK[@]}"; do echo "${RISK[$d]} $d"; done | sort -nr -k1,1)
    local idx=0
    while read -r line; do
        [[ -z "$line" ]] && continue
        local sc dv
        sc=$(echo "$line" | awk '{print $1}')
        dv=$(echo "$line" | awk '{print $2}')
        risk_lines+="$(basename "$dv") score=$sc"
        risk_lines+="\n"
        ((idx++))
        (( idx >= 20 )) && break
    done < <(printf "%s\n" "$sorted")
    if (( LIFECYCLE_ENABLED == 1 )); then
        local replace=() monitor=() healthy=()
        for d in "${!RISK[@]}"; do
            local s=${RISK[$d]}
            if (( s >= RISK_REPLACE )); then replace+=("$(basename "$d")")
            elif (( s >= RISK_MONITOR )); then monitor+=("$(basename "$d")")
            else healthy+=("$(basename "$d")")
            fi
        done
        lifecycle_lines+="Replace Soon: ${replace[*]:-none}\nMonitor: ${monitor[*]:-none}\nHealthy: ${healthy[*]:-none}"
        REPLACE_COUNT=${#replace[@]}
        MONITOR_COUNT=${#monitor[@]}
        HEALTHY_COUNT=${#healthy[@]}
    fi
    RISK_SECTION="$( (( RISK_SCORING_ENABLED==1 )) && echo "Risk Scores (top):\n${risk_lines}" )$( (( LIFECYCLE_ENABLED==1 )) && echo "Lifecycle Buckets:\n${lifecycle_lines}" )$( (( AGE_AWARE_ENABLED==1 )) && [[ -n "$age_lines" ]] && echo "Age Awareness:\n${age_lines}" )"
}

# Append today's risk tier counts to history file
persist_risk_tier_history() {
    (( RISK_SCORING_ENABLED == 1 )) || return 0
    local today=$(date +%Y-%m-%d)
    local crit=${CRIT_DISK_COUNT:-0} warn=${WARN_DISK_COUNT:-0}
    local replace=${REPLACE_COUNT:-0} monitor=${MONITOR_COUNT:-0} healthy=${HEALTHY_COUNT:-0}
    echo "$today critical=$crit warning=$warn replace=$replace monitor=$monitor healthy=$healthy" >> "$RISK_TIER_HISTORY_FILE"
}

# Analyze risk tier history and build trend summary
build_risk_tier_trend_section() {
    (( RISK_SCORING_ENABLED == 1 )) || { RISK_TIER_TREND_SECTION=""; return 0; }
    local lines
    lines=$(tail -n 7 "$RISK_TIER_HISTORY_FILE" 2>/dev/null || true)
    [[ -z "$lines" ]] && { RISK_TIER_TREND_SECTION=""; return 0; }
    local count_lines=$(printf "%s\n" "$lines" | wc -l | awk '{print $1}')
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
        crit_line="Critical disks: ${fcrit} -> ${lcrit} ($(printf "%+d" $dcrit))"
        warn_line="Warning disks: ${fwarn} -> ${lwarn} ($(printf "%+d" $dwarn))"
        replace_line="Replace-tier: ${freplace} -> ${lreplace} ($(printf "%+d" $dreplace))"
        monitor_line="Monitor-tier: ${fmonitor} -> ${lmonitor} ($(printf "%+d" $dmonitor))"
        healthy_line="Healthy-tier: ${fhealthy} -> ${lhealthy} ($(printf "%+d" $dhealthy))"
    else
        crit_line="Critical disks: ${lcrit} (no prior data)"
        warn_line="Warning disks: ${lwarn} (no prior data)"
        replace_line="Replace-tier: ${lreplace} (no prior data)"
        monitor_line="Monitor-tier: ${lmonitor} (no prior data)"
        healthy_line="Healthy-tier: ${lhealthy} (no prior data)"
    fi
    RISK_TIER_TREND_SECTION="Risk Tier Trend (last ${count_lines}d collected, max 7d):\n ${crit_line}\n ${warn_line}\n ${replace_line}\n ${monitor_line}\n ${healthy_line}"
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
    local days_to_arr_thresh="N/A" days_to_pool_thresh="N/A"
    if (( $(awk -v g="$arr_growth" 'BEGIN{print (g>0)}') )); then
        days_to_arr_thresh=$(awk -v pct="$array_pct" -v g="$arr_growth" -v th="$THRESHOLD" 'BEGIN{left=th-pct; if(left<=0) print 0; else printf "%.1f", left/g}')
    fi
    if (( $(awk -v g="$pool_growth" 'BEGIN{print (g>0)}') )); then
        days_to_pool_thresh=$(awk -v pct="$pools_pct" -v g="$pool_growth" -v th="$THRESHOLD" 'BEGIN{left=th-pct; if(left<=0) print 0; else printf "%.1f", left/g}')
    fi
    CAPACITY_FORECAST="Capacity Forecast:\n Array avg daily growth: ${arr_growth}% -> days to ${THRESHOLD}%: ${days_to_arr_thresh}\n Pools avg daily growth: ${pool_growth}% -> days to ${THRESHOLD}%: ${days_to_pool_thresh}"

    if (( JSON_EXPORT == 1 )); then
        mkdir -p "$(dirname "$HEALTH_JSON")" || true
        local include_disks=$JSON_INCLUDE_DISKS
        {
            echo '{'
            echo "  \"timestamp\": \"$(date '+%Y-%m-%dT%H:%M:%S')\",";
            echo "  \"array\": { \"percent\": $array_pct, \"used_hr\": \"${ARRAY_USED_HR}\", \"total_hr\": \"${ARRAY_TOTAL_HR}\" },";
            echo "  \"pools\": { \"percent\": $pools_pct, \"used_hr\": \"${POOLS_USED_HR}\", \"total_hr\": \"${POOLS_TOTAL_HR}\" },";
            echo "  \"disk_health_summary\": \"$(echo "$DISK_HEALTH_SUMMARY" | sed 's/\"/\\\"/g')\",";
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
                    echo -n "    { \"device\": \"$dev\", \"type\": \"$typ\", \"model\": \"$esc_model\", \"state\": \"$st\", \"poh_hours\": ${poh:-0}, \"capacity_tb\": ${cap:-0}, \"group\": \"$group\", \"array_member\": ${array_member}, \"array_slot\": \"$array_slot\", \"pool_member\": ${pool_member}, \"pool\": \"$pool_name\""
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
    fi
}

# Analyze disk usage history and compute top growth rates
compute_disk_growth_top() {
    (( DISK_GROWTH_ENABLED == 1 )) || { DISK_GROWTH_SECTION=""; return 0; }
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

build_storage_and_disk_lines
evaluate_capacity_alerts
build_recommendations 
build_subject
build_disk_health_summary
tbw_forecast_and_heavy_writers
build_subsystem_lines
capacity_forecast_and_export
compute_risk_and_lifecycle
validate_storage_metrics
compute_disk_growth_top
compute_share_breakdown
persist_risk_tier_history
build_risk_tier_trend_section

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
}

detect_counter_resets

# Analyze TBW history to estimate daily write rates and days to threshold
tbw_forecast_and_heavy_writers() {
    (( TBW_FORECAST_ENABLED == 1 )) || { TBW_SECTION=""; return 0; }
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

# Build and send notification
SCRIPT_END_EPOCH=$(date +%s)
RUNTIME_SEC=$(( SCRIPT_END_EPOCH - SCRIPT_START_EPOCH ))
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

NOTIFY_BODY="Runtime: ${RUNTIME_STR}
$STORAGE_TOP_LINES
Array Disks:
$ARRAY_DISK_LINES
Pools:
$POOL_LINES
$( [[ $ENABLE_POOL_DEVICE_SMART -eq 1 && -n "$POOL_DEVICE_LINES" ]] && printf "Pool Devices:\n%s\n" "$POOL_DEVICE_LINES" )
${DISK_HEALTH_SUMMARY}
${RISK_TIER_TREND_SECTION}
${CAPACITY_FORECAST}
${RISK_SECTION}
${FIRMWARE_EVENT_SECTION}
${TBW_SECTION}
${DISK_GROWTH_SECTION}
${SHARE_SECTION}
${STORAGE_VALIDATION_SECTION}
$( [[ -n "$ADAPTIVE_DECISIONS" ]] && printf "Adaptive SMART Decisions:\n%s" "$ADAPTIVE_DECISIONS" )
${IO_ERROR_FREQ_SECTION}
Subsystems:
$SUBSYSTEM_LINES
$RECOMMEND_SECTION"

notify_unraid "$SUBJECT" "$NOTIFY_BODY" "$( [[ ${#ALERT_CRIT[@]} -gt 0 ]] && echo critical || { [[ ${#ALERT_WARN[@]} -gt 0 ]] && echo warning || echo ok; } )"

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
