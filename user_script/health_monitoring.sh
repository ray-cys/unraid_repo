#!/bin/bash
set -euo pipefail
LOCKFILE="/tmp/health_monitoring.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Another run active, exiting (lock: $LOCKFILE)" >&2
    exit 1
fi

# Refactored per recommendations: improved notify usage, SMART scheduling, Btrfs/XFS parsing,
# corrected usage thresholds, temperature fallback, and lightweight locking.
# Unified Unraid SMART + Btrfs + XFS Monitor (Enhanced)
# Features added/updated per user request:
# 1) Timestamped logs
# 2) Use Unraid notify for failures (warning = notify type)
# 3) SMART parsing: pending sectors, reallocated, temperature etc. -> OK/WARNING/CRITICAL
# 4) Per-disk storage used/available + percentage + threshold reporting
# 5) Total storage used/available for arrays (/mnt/user) and for each pool/mount
# 6) Enhanced notifications for SMART/Btrfs/XFS (warning/critical)
# 7) NVMe detailed parsing (wear, life left) - see function nvme_parse_details

# ---------------- Configuration ----------------
# Storage health script settings. Tweak these to suit your system.

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
HISTORY_WINDOW_DAYS=7         # Window (days) for growth averages and trends
RISK_SCORING_ENABLED=1        # 1: show risk scores section
LIFECYCLE_ENABLED=1           # 1: show lifecycle buckets (replace/monitor/healthy)
AGE_AWARE_ENABLED=1           # 1: annotate near-endurance devices
SHARE_BREAKDOWN_ENABLED=0     # 1: compute per-share usage (uses du; can be heavy)
SHARE_TOP_N=5                 # Show top N shares by size/growth

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

# Internals (do not modify unless needed)
ALERT_WARN=()                 # Accumulator for warning messages
ALERT_CRIT=()                 # Accumulator for critical messages
declare -A SMART_STATE        # Map device -> OK/WARNING/CRITICAL
declare -A SMART_MSGS         # Map device -> aggregated SMART message string
declare -A MOUNT_TO_DEV       # Map /mnt/diskX -> /dev/sdX|nvme

# Paths and runtime logs
LOG_DIR="/boot/logs/disk-health"   # Base directory for logs and state files
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)   # Timestamp used for rotating log filenames
SMART_LOG="$LOG_DIR/unraid_smart_$TIMESTAMP.log"   # Per-run SMART log
BTRFS_LOG="$LOG_DIR/unraid_btrfs_$TIMESTAMP.log"   # Per-run btrfs log
XFS_LOG="$LOG_DIR/unraid_xfs_$TIMESTAMP.log"       # Per-run XFS log

# Persistent state files
SMART_LONG_STATE_FILE="$LOG_DIR/unraid_smart_long_processed.log" # Tracks processed long self-tests
SMART_LAST="$LOG_DIR/unraid_smart_last_test.log"                 # Last SMART test per disk
NVME_STATE_FILE="$LOG_DIR/unraid_nvme_counters_last.log"         # Last NVMe unsafe shutdown counters
PREV_ATTR_FILE="$LOG_DIR/unraid_smart_prev_attrs.log"            # Previous SMART attrs for delta tagging
CAPACITY_HISTORY_FILE="$LOG_DIR/unraid_capacity_history.log"     # Historical array/pools percent used
DISK_CAP_HISTORY_FILE="$LOG_DIR/unraid_disk_cap_history.log"     # Historical per-disk used/size
SHARE_USAGE_HISTORY_FILE="$LOG_DIR/unraid_share_usage_history.log" # Historical per-share size
ALERT_NEW_SEEN_FILE="$LOG_DIR/unraid_new_alerts_seen.log"        # Cache of NEW alerts already announced

# JSON export path
JSON_EXPORT_DIR="$LOG_DIR"                                      # Directory to write JSON summary
HEALTH_JSON="$JSON_EXPORT_DIR/unraid_health_summary.json"       # Health JSON output file

# Notification titles
NOTIFY_TITLE_SMART="SMART Test Alert"
NOTIFY_TITLE_BTRFS="Btrfs Scrub Alert"
NOTIFY_TITLE_XFS="XFS Alert"
NOTIFY_TITLE_DISKIO="Disk I/O Alert"

# ---------------- Helper Functions ----------------
# Helper: Unraid notify wrapper (severity: ok|warning|critical)
notify_unraid() {
    local title="$1"; shift
    local body="$1"; shift
    local sev="${1:-warning}"  # ok|warning|critical
    local icon="normal"
    case "$sev" in
        critical|CRITICAL) icon="alert" ;;
        warning|WARNING) icon="warning" ;;
        *) icon="normal" ;;
    esac
    local BIN="/usr/local/emhttp/webGui/scripts/notify"
    if [ -x "$BIN" ]; then
        "$BIN" -e "Disk Health Monitor" -s "$title" -d "$body" -i "$icon"
    else
        logger -t "Disk Health Monitor" "$title: $body"
    fi
}

# Accumulate alerts (warning/critical) for nightly consolidated summary.
record_alert() {
    local sev="$1"; shift
    local title="$1"; shift
    local body="$1"; shift
    if [[ "$sev" =~ ^(critical|CRITICAL)$ ]]; then
        ALERT_CRIT+=("$title: $body")
    else
        ALERT_WARN+=("$title: $body")
    fi
}

# Human-readable bytes (decimal units: KB=1000)
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

# ---------------- Disk and SMART Helpers ----------------
base_device() {
    local d="$1"
    if [[ "$d" == /dev/nvme* ]]; then
        echo "$d" | sed -E 's/p[0-9]+$//'
    else
        echo "$d" | sed -E 's/[0-9]+$//'
    fi
}

get_device_model() {
    local d=$(base_device "$1")
    if [[ "$d" == /dev/nvme* ]]; then
        smartctl -i -d nvme "$d" 2>/dev/null | awk -F: '/Model Number/ {sub(/^ +/,"",$2); print $2; exit}'
    else
        smartctl -i "$d" 2>/dev/null | awk -F: '/Device Model|Model Family/ {sub(/^ +/,"",$2); print $2; exit}'
    fi
}

get_device_capacity_tb() {
    local d=$(base_device "$1")
    local bytes
    bytes=$(lsblk -b -dn -o SIZE "$d" 2>/dev/null | head -n1)
    bytes=${bytes:-0}
    awk -v b="$bytes" 'BEGIN{printf "%.3f", b/1000000000000.0}'
}

tbw_threshold_tb_for_device() {
    # Args: model, capacity_tb -> echo threshold TB (integer or float). Return empty if unknown.
    local model="$1"; shift
    local cap="$1"; shift
    # Defaults per TB (conservative baselines)
    local per_tb=0
    if echo "$model" | grep -qi 'MX500'; then per_tb=350; fi
    if echo "$model" | grep -qi 'WD Red' | grep -qi 'SA500'; then per_tb=600; fi
    if echo "$model" | grep -qi 'T500'; then per_tb=600; fi
    if echo "$model" | grep -qiE 'P3|P300'; then per_tb=220; fi
    if (( per_tb == 0 )); then echo ""; return 0; fi
    awk -v c="$cap" -v p="$per_tb" 'BEGIN{printf "%.0f", c*p}'
}
get_all_disks() {
    # Retain original discovery method as per user preference; spins up disks intentionally.
    local sata nvme out=()
    # Support multi-letter devices (sda, sdz, sdaa, etc.), exclude partitions
    sata=$(ls /dev/sd* 2>/dev/null | grep -E '^/dev/sd[a-z]+$' || true)
    nvme=$(ls /dev/nvme?n? 2>/dev/null || true)
    # Determine the root device for /boot and exclude it (handles sdX1 and nvmeXpY)
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

# Build mountpoint -> physical device map using Unraid metadata
build_mount_device_map() {
    # Clear existing map
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
    # Pass 1: use device= (e.g., sdg, sdaa, nvme0n1)
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

    # Pass 2: fallback to id= (by-id symlink) when device missing
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

# Resolve best SMART device for a given mountpoint
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

# Load last SMART test dates and NVMe counters
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

# Load previous SMART attribute snapshot for trend deltas
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

# Load seen NEW alerts to throttle duplicates
declare -A NEW_SEEN
if [ -f "$ALERT_NEW_SEEN_FILE" ]; then
    while IFS= read -r key; do
        [[ -n "$key" ]] && NEW_SEEN["$key"]=1
    done < "$ALERT_NEW_SEEN_FILE"
fi

save_last_test() {
    > "$SMART_LAST"
    for disk in "${!LAST_TEST[@]}"; do
        echo "$disk ${LAST_TEST[$disk]}" >> "$SMART_LAST"
    done
}

save_nvme_state() {
    > "$NVME_STATE_FILE"
    for dev in "${!NVME_LAST_UNSAFE[@]}"; do
        echo "$dev ${NVME_LAST_UNSAFE[$dev]}" >> "$NVME_STATE_FILE"
    done
}


# Evaluate SMART results to determine OK/WARNING/CRITICAL
evaluate_smart() {
    local disk=$1
    local is_nvme=0
    [[ $disk == /dev/nvme* ]] && is_nvme=1
    local state="OK"
    local messages=()
    if [[ $is_nvme -eq 1 ]]; then
        local nvme_output
        nvme_output=$(smartctl -a -d nvme "$disk" 2>/dev/null || true)
        local percent_used crit_warn nvme_temp media_errors err_logs unsafe_shutdowns avail_spare avail_spare_thr duw
        percent_used=$(echo "$nvme_output" | awk -F: '/Percentage Used/ {gsub(/%| /,"",$2); print $2; exit}')
        percent_used=${percent_used:-0}
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
        # TBW from Data Units Written (1 unit = 512,000 bytes per NVMe spec)
        if [[ -n "$duw" ]]; then
            local tbw_bytes=$(( duw * 512000 ))
            local tbw_hr=$(human_readable "$tbw_bytes")
            messages+=("TBW ~ $tbw_hr")
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
        # Extract numeric NVMe temperature (strip units/words like "Celsius")
        nvme_temp=$(echo "$nvme_output" | awk -F: '/Temperature/ {print $2; exit}' | grep -oE '[0-9]+' | head -n1)
        if [[ $percent_used -ge $NVME_PERCENT_USED_CRIT ]]; then
            state="CRITICAL"; messages+=("NVMe wear ${percent_used}% >= ${NVME_PERCENT_USED_CRIT}%")
        elif [[ $percent_used -ge $NVME_PERCENT_USED_WARN ]]; then
            state="WARNING"; messages+=("NVMe wear ${percent_used}% >= ${NVME_PERCENT_USED_WARN}%")
        fi
        if [[ $crit_warn -ne 0 ]]; then
            state="CRITICAL"; messages+=("NVMe Critical Warning flags: $crit_warn")
            # Decode NVMe Critical Warning bitmask: bit0 spare below threshold, bit1 temp, bit2 reliability degraded,
            # bit3 media read-only, bit4 volatile memory backup failed.
            local cw_dec=""
            if [[ $crit_warn =~ ^0x[0-9A-Fa-f]+$ ]]; then
                cw_dec=$((16#${crit_warn#0x}))
            else
                cw_dec=$crit_warn
            fi
            # Bit1 temperature
            if (( (cw_dec & 0x02) != 0 )); then
                messages+=("NVMe thermal threshold exceeded (Critical Warning bit1)")
            fi
            # Bit0 available spare below threshold (avoid duplicate if already logged)
            if (( (cw_dec & 0x01) != 0 )); then
                local dup=0; for m in "${messages[@]}"; do [[ $m == *"Available Spare"* ]] && dup=1; done; (( dup==0 )) && messages+=("NVMe available spare below threshold (Critical Warning bit0)")
                [[ $state == OK ]] && state="WARNING"
            fi
            # Bit2 reliability degraded
            if (( (cw_dec & 0x04) != 0 )); then
                state="CRITICAL"; messages+=("NVMe reliability degraded (Critical Warning bit2)")
            fi
            # Bit3 media read-only
            if (( (cw_dec & 0x08) != 0 )); then
                state="CRITICAL"; messages+=("NVMe media in read-only mode (Critical Warning bit3)")
            fi
            # Bit4 volatile memory backup failed
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
        # Unsafe shutdowns delta check
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
    else
        local attr realloc pending offunc temp udma reported_uncorr cmd_timeout realloc_events end2end soft_read_err lcc
        attr=$(smartctl -A "$disk" 2>/dev/null || true)
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
        # Additional SATA SMART attributes (187, 188, 196, 184, 201)
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
        # Load Cycle Count
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
        # SSD wear-leveling (normalized life remaining)
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
        # TBW reporting with attribute fallbacks (241 -> 246); include reads (242) as informational
        local lbasw hw32mib lbasr tbw_bytes tbw_hr reads_bytes reads_hr
        # Prefer by name first
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
        # Reads informational (242)
        lbasr=$(echo "$attr" | awk '/Total_LBAs_Read/ {print $10; exit}')
        if [[ -z "$lbasr" ]]; then lbasr=$(echo "$attr" | awk '/^[ ]*242[ ]/ {print $10; exit}'); fi
        if [[ -n "$lbasr" ]]; then reads_bytes=$(( lbasr * 512 )); fi
        if [[ -n "${tbw_bytes:-}" ]]; then
            tbw_hr=$(human_readable "$tbw_bytes")
            messages+=("TBW ~ $tbw_hr")
            # Per-model threshold if available, else global fallback
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
        # Collect current attribute snapshot for trends
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

# -------- SMART self-test helpers --------
get_latest_selftest_info() {
    # Returns: test_num|test_type|status_phrase|lifetime_hours|remaining_pct
    local disk=$1
    local out
    if [[ $disk == /dev/nvme* ]]; then
        out=$(smartctl -l selftest -d nvme "$disk" 2>/dev/null || true)
    else
        out=$(smartctl -l selftest "$disk" 2>/dev/null || true)
    fi
    # SATA style: lines starting with number; NVMe similar or may be limited
    local line
    line=$(echo "$out" | awk 'NR>5 && $1 ~ /^[0-9]+$/ {print; exit}')
    if [[ -z "$line" ]]; then
        echo "|||"; return
    fi
    local num type status lifetime remaining
    num=$(echo "$line" | awk '{print $1}')
    type=$(echo "$line" | awk '{print $2" "$3}')
    # Status may span multiple fields; detect Remaining and Lifetime to split
    remaining=$(echo "$line" | grep -o '[0-9]\+%\?' | head -n1)
    lifetime=$(echo "$line" | awk '{for(i=1;i<=NF;i++){if($i ~ /hours/){print $(i-1); break}}}')
    # Extract status phrase between type fields and Remaining
    status=$(echo "$line" | sed -E 's/^\s*[0-9]+\s+[^ ]+\s+[^ ]+\s+//' | sed -E 's/\s+[0-9]+%.*//' )
    echo "${num}|${type}|${status}|${lifetime}|${remaining}"
}

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

poll_short_test_completion() {
    local disk=$1
    local waited=0
    local info status sev msg
    while (( waited < SHORT_TEST_MAX_WAIT )); do
        info=$(get_latest_selftest_info "$disk")
        if [[ "$info" == "|||" ]]; then
            # Unsupported / empty self-test log; treat as OK and skip polling
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

# Run SMART test (short or long based on SMART_TEST_TYPE & interval)
run_smart_test() {
    local disk=$1
    [[ $disk == /dev/sd* ]] && hdparm -I "$disk" >/dev/null 2>&1 || true
    local flag="-t short"
    if [[ "$SMART_TEST_TYPE" == "long" ]]; then
        # Determine interval using lifetime hours vs last long test lifetime hours
        local selftest poh_attr poh current_poh last_long_hours_diff="" threshold_hours last_long_poh
        if [[ $disk == /dev/nvme* ]]; then
            selftest=$(smartctl -l selftest -d nvme "$disk" 2>/dev/null || true)
            poh_attr=$(smartctl -a -d nvme "$disk" 2>/dev/null | awk -F: '/Power On Hours/ {gsub(/ /,"",$2); print $2; exit}')
        else
            selftest=$(smartctl -l selftest "$disk" 2>/dev/null || true)
            poh_attr=$(smartctl -A "$disk" 2>/dev/null | awk '/Power_On_Hours/ {print $10; exit}')
        fi
        current_poh=${poh_attr:-0}
        # Extract lifetime hours from latest Extended/Long entry
        last_long_poh=$(echo "$selftest" | awk 'NR>5 && /Extended offline|Extended self-test|Long/ && $1 ~ /^[0-9]+$/ {for(i=1;i<=NF;i++){if($i ~ /^[0-9]+$/ && $(i+1) ~ /^-/){print $i; break}}}' | head -n1)
        # Fallback: if above pattern fails, attempt second method (field before trailing '-')
        if [[ -z "$last_long_poh" ]]; then
            last_long_poh=$(echo "$selftest" | awk 'NR>5 && /Extended offline|Long/ && $1 ~ /^[0-9]+$/ {for(i=NF;i>=1;i--){if($i ~ /^[0-9]+$/){print $i; break}}}' | head -n1)
        fi
        if [[ -n "$last_long_poh" && $current_poh -gt 0 ]]; then
            last_long_hours_diff=$(( current_poh - last_long_poh ))
        fi
        threshold_hours=$(( SMART_INTERVAL_DAYS * 24 ))
        if [[ -z "$last_long_hours_diff" || "$last_long_hours_diff" -ge $threshold_hours ]]; then
            flag="-t long"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Skip long on $disk (interval ${last_long_hours_diff}h < ${threshold_hours}h)" | tee -a "$SMART_LOG"
        fi
    fi
    # Detect existing self-test in progress to avoid attempting a new one
    local exec_status existing_in_progress=0
    if [[ $disk == /dev/nvme* ]]; then
        exec_status=$(smartctl -c -d nvme "$disk" 2>/dev/null | awk -F: '/Self-test execution status/ {print $2}') || true
    else
        exec_status=$(smartctl -c "$disk" 2>/dev/null | awk -F: '/Self-test execution status/ {print $2}') || true
    fi
    if echo "$exec_status" | grep -qi 'in progress'; then
        existing_in_progress=1
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting SMART ${flag/-t /} test on $disk" | tee -a "$SMART_LOG"
    if [[ $existing_in_progress -eq 1 ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Self-test already in progress on $disk; skipping new start (status: ${exec_status})" | tee -a "$SMART_LOG"
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
            echo "$(date '+%Y-%m-%d %H:%M:%S') - $disk short self-test status: $msg" | tee -a "$SMART_LOG"
            if [[ $sev == WARNING ]]; then
                record_alert warning "$NOTIFY_TITLE_SMART" "Disk $disk short self-test warning: $msg"
            fi
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - $disk short self-test still in progress after wait window" | tee -a "$SMART_LOG"
        fi
    else
        if [[ $existing_in_progress -eq 1 ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Skipping poll (different test still running)" | tee -a "$SMART_LOG"
        else
            # Allow initial attribute update; long test result will be evaluated next run
            sleep 5
        fi
    fi
    local state_and_msgs state msgs
    state_and_msgs=$(evaluate_smart "$disk")
    state=$(echo "$state_and_msgs" | head -n1)
    msgs=$(echo "$state_and_msgs" | tail -n +2)
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $disk SMART state: $state" | tee -a "$SMART_LOG"
    [[ -n "$msgs" ]] && echo "$msgs" | tee -a "$SMART_LOG"
    SMART_STATE["$disk"]="$state"
    SMART_MSGS["$disk"]="$(echo "$msgs" | tr '\n' '; ')"
    if [[ $state == WARNING || $state == CRITICAL ]]; then
        record_alert "$state" "$NOTIFY_TITLE_SMART" "Disk $disk SMART $state: $(echo "$msgs" | tr '\n' ' ')"
    fi
    LAST_TEST[$disk]=$(date '+%Y-%m-%d')
}

# Augment SMART messages with trend deltas and NEW markers
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
            # Determine issue key for throttling NEW markers
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
    # State file keeps disk|test_num processed entries
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
        # Find latest extended/long style line
        local line
        line=$(echo "$out" | awk 'NR>5 && /Extended offline|Extended self-test|Long/ && $1 ~ /^[0-9]+$/ {print; exit}')
        [[ -z "$line" ]] && continue
        local id type status
        id=$(echo "$line" | awk '{print $1}')
        type=$(echo "$line" | awk '{for(i=2;i<=NF;i++){if($i ~ /Extended|Long/){print $i; break}}}')
        # Extract status (strip leading fields and remaining percent if present)
        status=$(echo "$line" | sed -E 's/^\s*[0-9]+\s+[^ ]+\s+[^ ]+\s+//' | sed -E 's/\s+[0-9]+%.*//' )
        # Skip if already processed or still in progress
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
        # Alert if severity WARNING or CRITICAL
        if [[ $sev == WARNING ]]; then
            record_alert warning "$NOTIFY_TITLE_SMART" "Disk $disk long self-test warning: $msg"
        elif [[ $sev == CRITICAL ]]; then
            record_alert critical "$NOTIFY_TITLE_SMART" "Disk $disk long self-test CRITICAL: $msg"
        fi
        # Record processed test id
        echo "$disk $id" >> "$SMART_LONG_STATE_FILE.tmp"
    done
    # Merge old processed with new, keeping latest id per disk
    if [[ -f "$SMART_LONG_STATE_FILE.tmp" ]]; then
        awk '{a[$1]=$2} END {for(k in a) print k, a[k]}' "$SMART_LONG_STATE_FILE.tmp" > "$SMART_LONG_STATE_FILE"
        rm -f "$SMART_LONG_STATE_FILE.tmp"
    fi
}

# ---------------- Btrfs monitoring ----------------
monitor_btrfs() {
    # Start banner depends on scrub enable flag
    if [[ $ENABLE_BTRFS_SCRUB -eq 1 ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - BTRFS scrubbing starting" | tee -a "$BTRFS_LOG"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - BTRFS scrubbing disabled" | tee -a "$BTRFS_LOG"
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
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Btrfs scrub already running on $mp; will parse current running status" | tee -a "$BTRFS_LOG"
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Initiating asynchronous Btrfs scrub on $mp (RAID: $raid_type)" | tee -a "$BTRFS_LOG"
                btrfs scrub start "$mp" >>"$BTRFS_LOG" 2>&1 || true
            fi
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Btrfs scrub disabled; parsing last recorded status only for $mp" | tee -a "$BTRFS_LOG"
        fi
        local status corrected uncorrectable msg
        status=$(btrfs scrub status -d "$mp" 2>/dev/null)
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Btrfs scrub status for $mp:" | tee -a "$BTRFS_LOG"
        echo "$status" | tee -a "$BTRFS_LOG"
        corrected=$(echo "$status" | awk -F'[: ]+' '/corrected errors/ {print $NF; exit}'); corrected=${corrected:-0}
        uncorrectable=$(echo "$status" | awk -F'[: ]+' '/unrecoverable errors/ {print $NF; exit}'); uncorrectable=${uncorrectable:-0}
        if [[ $uncorrectable -gt 0 ]]; then
            if [[ "$raid_type" =~ RAID0 ]]; then
                msg="CRITICAL: $mp RAID0 unrecoverable errors=$uncorrectable"
            else
                msg="CRITICAL: $mp unrecoverable errors=$uncorrectable"
            fi
            echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a "$BTRFS_LOG"
            record_alert critical "$NOTIFY_TITLE_BTRFS" "$msg"
        elif [[ $corrected -gt 0 ]]; then
            msg="WARNING: $mp scrub corrected=$corrected"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a "$BTRFS_LOG"
            record_alert warning "$NOTIFY_TITLE_BTRFS" "$msg"
        fi
    done
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Btrfs scrubbing completed" | tee -a "$BTRFS_LOG"
}

# ---------------- XFS monitoring ----------------
monitor_xfs() {
    # Start banner depends on metadata check enable flag
    if [[ $ENABLE_XFS_CHECK -eq 1 ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - XFS checks starting" | tee -a "$XFS_LOG"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - XFS checks disabled" | tee -a "$XFS_LOG"
    fi
    local mountpoints
    mountpoints=$(mount | awk '$5=="xfs" {print $3}')
    for mp in $mountpoints; do
        echo "$(date '+%Y-%m-%d %H:%M:%S') - XFS check $mp" | tee -a "$XFS_LOG"
        if [[ $ENABLE_XFS_CHECK -eq 1 ]]; then
            local dev xfs_out msg
            dev=$(findmnt -n -o SOURCE --target "$mp")
            if [[ -n "$dev" ]]; then
                xfs_out=$(xfs_repair -n "$dev" 2>&1)
                echo "$xfs_out" | tee -a "$XFS_LOG"
                if echo "$xfs_out" | grep -qiE "error|corrupt|fatal"; then
                    msg="CRITICAL: XFS metadata issue on $mp ($dev)"
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a "$XFS_LOG"
                    record_alert critical "$NOTIFY_TITLE_XFS" "$msg"
                fi
            fi
        fi
        if dmesg | tail -n 3000 | grep -qiE "$(basename "$mp").*(XFS|I/O error)|XFS ERROR|xfs_repair"; then
            msg="WARNING: Kernel/XFS I/O messages for $mp"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a "$XFS_LOG"
            record_alert warning "$NOTIFY_TITLE_XFS" "$msg"
        fi
    done
    echo "$(date '+%Y-%m-%d %H:%M:%S') - XFS checks completed" | tee -a "$XFS_LOG"
}



# Capacity alert evaluation
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

# Per-mount threshold alert evaluation
evaluate_per_mount_thresholds() {
    for mp in /mnt/disk* /mnt/cache /mnt/*; do
        [[ -e "$mp" ]] || continue
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

# ---------------- Main ----------------
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting SMART tests (type=$SMART_TEST_TYPE)" | tee -a "$SMART_LOG"
check_completed_long_tests
for disk in $(get_all_disks); do
    run_smart_test "$disk"
done
save_last_test
echo "$(date '+%Y-%m-%d %H:%M:%S') - SMART tests completed" | tee -a "$SMART_LOG"
augment_messages_with_deltas

# Persist NVMe counters after SMART evaluation
save_nvme_state

monitor_btrfs
check_btrfs_snapshots() {
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
monitor_xfs

# Build mount -> device mapping before composing per-disk lines
build_mount_device_map

# Scan system logs for disk I/O issues
scan_syslog_disk_errors() {
    local src=""
    if [[ -f /var/log/syslog ]]; then
        src=$(tail -n 5000 /var/log/syslog 2>/dev/null)
    else
        src=$(dmesg 2>/dev/null | tail -n 5000)
    fi
    # Look for common disk error patterns and extract device names
    local devs=()
    while read -r line; do
        if echo "$line" | grep -qiE 'I/O error|blk_update_request|end_request|failed command: (READ|WRITE)|hard resetting link|link is slow to respond'; then
            local d
            for d in $(echo "$line" | grep -oE 'sd[a-z]+' | sort -u); do devs+=("/dev/$d"); done
            for d in $(echo "$line" | grep -oE 'nvme[0-9]+n[0-9]+' | sort -u); do devs+=("/dev/$d"); done
        fi
    done < <(printf "%s\n" "$src")
    # Deduplicate
    local uniq=()
    local seen=""
    for d in "${devs[@]}"; do
        [[ "$seen" == *"|$d|"* ]] && continue
        uniq+=("$d"); seen+="|$d|"
    done
    for d in "${uniq[@]}"; do
        record_alert warning "$NOTIFY_TITLE_DISKIO" "Kernel reported disk I/O issues for $d (see syslog)"
    done
}
scan_syslog_disk_errors

evaluate_per_mount_thresholds

# ---------------- Notification Builder (Refactored) ----------------
severity_rank() { case "$1" in CRITICAL) echo 2;; WARNING) echo 1;; *) echo 0;; esac; }
status_word()   { case "$1" in 2) echo "CRITICAL";; 1) echo "WARNING";; *) echo "OK";; esac; }
map_emoji()     { case "$1" in 2) printf "🔴";; 1) printf "🟡";; *) printf "🟢";; esac; }

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
        # Map mountpoint to underlying device (likely /dev/mdX); attempt direct SMART lookup; fallback for md -> physical disk not resolved
        local dev sm_state sm_msg
        dev=$(smart_device_for_mount "$d")
        sm_state=${SMART_STATE["$dev"]:-OK}
        sm_msg=${SMART_MSGS["$dev"]:-}
        local sm_rank=$(severity_rank "$sm_state")
        (( sm_rank > usage_sev )) && usage_sev=$sm_rank
        (( usage_sev > ARRAY_MAX_SEV )) && ARRAY_MAX_SEV=$usage_sev
        local sev_word=$(status_word "$usage_sev")
        # Build unified reasons combining usage and SMART
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
        POOL_LINES+=$(printf "%-10s %10s / %-10s (%5s%%) %s\n" "$name" "$(human_readable "$u")" "$(human_readable "$sz")" "$pct" "$(status_word "$usage_sev")")

        if [[ $ENABLE_POOL_DEVICE_SMART -eq 1 ]]; then
            local fstype devlist
            fstype=$(findmnt -n -o FSTYPE "$p" 2>/dev/null || true)
            if [[ "$fstype" == "btrfs" ]]; then
                # Enhanced parsing: extract path token following 'path' for each devid line; fallback to last field
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
                local st="${SMART_STATE[$rootdv]:-OK}" msg="${SMART_MSGS[$rootdv]:-}"
                local rank=$(severity_rank "$st")
                if [[ -n "$msg" ]]; then
                    # Add model, capacity, wear snippet
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

# Validate array vs /mnt/user and pools mapping for edge cases (double count, missing mounts)
validate_storage_metrics() {
    local user_pct user_line discrepancy_section=""
    if mountpoint -q /mnt/user; then
        user_line=$(df -B1 /mnt/user 2>/dev/null | awk 'NR==2')
        local user_sz=$(echo "$user_line" | awk '{print $2}') user_used=$(echo "$user_line" | awk '{print $3}')
        if [[ -n "$user_sz" && -n "$user_used" ]]; then
            local user_pct_calc=$(awk "BEGIN{ if($user_sz>0) printf \"%.1f\", ($user_used/$user_sz)*100; else print 0 }")
            # Difference between aggregated array percent and direct /mnt/user percent
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

build_subsystem_lines() {
    local sm=OK bt=OK xfs=OK cap=OK pm=OK
    for a in "${ALERT_CRIT[@]}"; do
        [[ $a == "$NOTIFY_TITLE_SMART"* ]] && sm=CRITICAL
        [[ $a == "$NOTIFY_TITLE_BTRFS"* ]] && bt=CRITICAL
        [[ $a == "$NOTIFY_TITLE_XFS"* ]] && xfs=CRITICAL
        [[ $a == *Capacity* ]] && cap=CRITICAL
        [[ $a == Storage\ Critical* ]] && pm=CRITICAL
    done
    for a in "${ALERT_WARN[@]}"; do
        [[ $sm != CRITICAL && $a == "$NOTIFY_TITLE_SMART"* ]] && sm=WARNING
        [[ $bt != CRITICAL && $a == "$NOTIFY_TITLE_BTRFS"* ]] && bt=WARNING
        [[ $xfs != CRITICAL && $a == "$NOTIFY_TITLE_XFS"* ]] && xfs=WARNING
        [[ $cap != CRITICAL && $a == *Capacity* ]] && cap=WARNING
        [[ $pm != CRITICAL && $a == Storage\ Warning* ]] && pm=WARNING
    done
    SUBSYSTEM_LINES="SMART: $sm
Btrfs: $( [[ $ENABLE_BTRFS_SCRUB -eq 1 ]] && echo "$bt" || echo "Disabled")
XFS:   $( [[ $ENABLE_XFS_CHECK -eq 1 ]] && echo "$xfs" || echo "Disabled")
Capacity: $cap
Per-Mount: $pm"
}

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
        # (Simple heuristic; we already display days inside section.)
        :
    fi
    [[ -n "$improve" ]] && rec+="Storage Improvement Suggestions:\n$improve"
    RECOMMEND_SECTION="$rec"
}

build_subject() {
    local sev=0
    (( ${#ALERT_CRIT[@]} > 0 )) && sev=2 || { (( ${#ALERT_WARN[@]} > 0 )) && sev=1; }
    SUBJECT="Unraid Nightly Health: $(status_word $sev) ($((${#ALERT_CRIT[@]})) critical / $((${#ALERT_WARN[@]})) warning)"
}
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
    DISK_HEALTH_SUMMARY="Disk Health Summary:\n Critical disks: $crit_count\n Warning disks: $warn_count\n Pending sector disks: $pending_count\n Uncorrectable error disks: $uncorrect_count\n High temp disks: $high_temp\n NVMe wear warnings: $nvme_wear_warn\n NVMe read-only: $read_only\n NVMe reliability degraded: $reliability\n Command timeout warnings: $timeout_warn\n Reallocated event warnings: $realloc_events_warn\n End-to-end error disks: $end2end_count\n Soft read error warnings: $soft_read_warn"
}

# Risk scoring & lifecycle buckets + age awareness
compute_risk_and_lifecycle() {
    (( RISK_SCORING_ENABLED == 1 )) || return 0
    local risk_lines="" lifecycle_lines="" age_lines=""
    declare -A RISK SCORE_ATTR AGE_CLASS
    for dev in "${!SMART_STATE[@]}"; do
        local st="${SMART_STATE[$dev]}" msg="${SMART_MSGS[$dev]}"
        local score=0
        # Base severity weight (use tunables)
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
        # Age awareness (Power On Hours + wear)
        local poh=0 percent_used=0 life_remain=0
        if [[ $dev == /dev/nvme* ]]; then
            percent_used=$(smartctl -a -d nvme "$dev" 2>/dev/null | awk -F: '/Percentage Used/ {gsub(/%| /,"",$2); print $2; exit}')
            poh=$(smartctl -a -d nvme "$dev" 2>/dev/null | awk -F: '/Power On Hours/ {gsub(/ /,"",$2); print $2; exit}')
            percent_used=${percent_used:-0}; poh=${poh:-0}
            if (( percent_used >= 90 )); then ((score += W_AGE_NEAR)); AGE_CLASS[$dev]="Near endurance"; fi
        else
            poh=$(smartctl -A "$dev" 2>/dev/null | awk '/Power_On_Hours/ {print $10; exit}')
            life_remain=$(smartctl -A "$dev" 2>/dev/null | awk '/Media_Wearout_Indicator/ {print $4; exit}')
            [[ -z "$life_remain" ]] && life_remain=$(smartctl -A "$dev" 2>/dev/null | awk '/Wear_Leveling_Count/ {print $4; exit}')
            poh=${poh:-0}; life_remain=${life_remain:-0}
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
    # Create sorted list
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
    # Lifecycle buckets
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
    fi
    RISK_SECTION="$( (( RISK_SCORING_ENABLED==1 )) && echo "Risk Scores (top):\n${risk_lines}" )$( (( LIFECYCLE_ENABLED==1 )) && echo "Lifecycle Buckets:\n${lifecycle_lines}" )$( (( AGE_AWARE_ENABLED==1 )) && [[ -n "$age_lines" ]] && echo "Age Awareness:\n${age_lines}" )"
}

# Share-level usage breakdown and growth (optional)
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
    # Top N by size
    local sorted_size=$(printf "%s\n" "${sizes[@]}" | sort -nr -k1,1 | head -n "$SHARE_TOP_N")
    local size_lines=""
    while read -r b n; do
        [[ -z "$n" ]] && continue
        size_lines+=" - $(printf "%-20s" "$n") $(human_readable "$b")\n"
    done < <(printf "%s\n" "$sorted_size")
    # Growth over window
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

# Capacity forecast & JSON export
capacity_forecast_and_export() {
    local now_date=$(date +%Y-%m-%d)
    local array_pct="${ARRAY_PERCENT:-0}" pools_pct="${POOLS_PERCENT:-0}"
    echo "$now_date array=$array_pct pools=$pools_pct" >> "$CAPACITY_HISTORY_FILE"
    # Compute average daily growth over last HISTORY_WINDOW_DAYS entries
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
        {
            echo '{'
            echo "  \"timestamp\": \"$(date '+%Y-%m-%dT%H:%M:%S')\",";
            echo "  \"array\": { \"percent\": $array_pct, \"used_hr\": \"${ARRAY_USED_HR}\", \"total_hr\": \"${ARRAY_TOTAL_HR}\" },";
            echo "  \"pools\": { \"percent\": $pools_pct, \"used_hr\": \"${POOLS_USED_HR}\", \"total_hr\": \"${POOLS_TOTAL_HR}\" },";
            echo "  \"disk_health_summary\": \"$(echo "$DISK_HEALTH_SUMMARY" | sed 's/"/\\"/g')\",";
            echo "  \"capacity_forecast\": \"$(echo "$CAPACITY_FORECAST" | sed 's/"/\\"/g')\"";
            echo '}'
        } > "$HEALTH_JSON"
    fi
}

# Compute top per-disk growth over HISTORY_WINDOW_DAYS
compute_disk_growth_top() {
    local win=$HISTORY_WINDOW_DAYS
    local lines=$(tail -n 20000 "$DISK_CAP_HISTORY_FILE" 2>/dev/null || true)
    [[ -z "$lines" ]] && { DISK_GROWTH_SECTION=""; return 0; }
    # Build earliest and latest used per disk within window by date ordering
    local cutoff=$(date -d "-$win days" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)
    local tmp=$(mktemp)
    printf "%s\n" "$lines" | awk -v c="$cutoff" '$1>=c{print}' | awk '{d=$2; for(i=3;i<=NF;i++){split($i,a,"="); if(a[1]=="used") used=a[2]; if(a[1]=="size") sz=a[2]} if(used!="" && sz!=""){print $1,d,used,sz}}' > "$tmp"
    # Compute growth per disk
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
build_subsystem_lines
build_recommendations
build_subject
build_disk_health_summary
capacity_forecast_and_export
compute_risk_and_lifecycle
validate_storage_metrics
compute_disk_growth_top
compute_share_breakdown

NOTIFY_BODY="$STORAGE_TOP_LINES
Array Disks:
$ARRAY_DISK_LINES
Pools:
$POOL_LINES
$( [[ $ENABLE_POOL_DEVICE_SMART -eq 1 && -n "$POOL_DEVICE_LINES" ]] && printf "Pool Devices:\n%s\n" "$POOL_DEVICE_LINES" )
${DISK_HEALTH_SUMMARY}
${CAPACITY_FORECAST}
${RISK_SECTION}
${DISK_GROWTH_SECTION}
${SHARE_SECTION}
${STORAGE_VALIDATION_SECTION}
Subsystems:
$SUBSYSTEM_LINES
$RECOMMEND_SECTION"

notify_unraid "$SUBJECT" "$NOTIFY_BODY" "$( [[ ${#ALERT_CRIT[@]} -gt 0 ]] && echo critical || { [[ ${#ALERT_WARN[@]} -gt 0 ]] && echo warning || echo ok; } )"

# Persist current SMART attribute snapshot for next run trend analysis
persist_current_attrs() {
    > "$PREV_ATTR_FILE"
    for disk in "${!SMART_STATE[@]}"; do
        local line="$disk state=${SMART_STATE[$disk]}"
        for key in realloc pending offunc reported_uncorr cmd_timeout realloc_events udma lcc end2end soft_read_err temp; do
            local v=${CUR_ATTR["$disk|$key"]:-}
            [[ -n "$v" ]] && line+=" $key=$v"
        done
        echo "$line" >> "$PREV_ATTR_FILE"
    done
}
persist_current_attrs
persist_new_seen() {
    > "$ALERT_NEW_SEEN_FILE"
    for key in "${!NEW_SEEN[@]}"; do
        echo "$key" >> "$ALERT_NEW_SEEN_FILE"
    done
}
persist_new_seen
exit 0
