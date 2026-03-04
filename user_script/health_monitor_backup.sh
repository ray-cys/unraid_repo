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
SMART_TEST_TYPE="short"       # "short" or "long" (long will only start if interval met)
SMART_INTERVAL_DAYS=30        # Days between long SMART tests per disk (based on self-test log)
ENABLE_NOTIFY=1               # 1 = yes, 0 = no
WARN_THRESHOLD_PERCENT=80     # percentage used per-disk to warn
CRITICAL_THRESHOLD_PERCENT=90 # percentage used per-disk to critical-alert
CONS_NOTIFY=1                 # 1 = consolidated summary notify at end; 0 = immediate per-event
THRESHOLD=90                  # Byte-accurate group threshold for array/pools
NEAR_THRESHOLD_DELTA=5        # Near-threshold window in percent
POOL_EXCLUDES=("ramtmp" "user0") # Pool names to exclude from byte summary
EMAIL_ENABLED=0               # 1 to send consolidated summary by email
EMAIL_TO=""                   # Set recipient address when EMAIL_ENABLED=1
SHORT_TEST_POLL=1             # Poll short tests until completion within script (Option 2)
SHORT_TEST_MAX_WAIT=180       # Max seconds to wait for short test completion
SHORT_TEST_POLL_INTERVAL=10   # Interval seconds between polls

# Notification formatting options (added for configurability)
STORAGE_STATUS_EMOJI_GREEN="🟢"
STORAGE_STATUS_EMOJI_YELLOW="🟡"
STORAGE_STATUS_EMOJI_RED="🔴"

# Additional execution toggles
ENABLE_BTRFS_SCRUB=0          # 1 run btrfs scrub (guarded), 0 only read last status
ENABLE_XFS_CHECK=0            # 1 run xfs_repair -n (read-only check), 0 skip

# Initialize storage metric globals for notifications/alerts
ARRAY_COUNT=0 ARRAY_PERCENT="" ARRAY_USED_BYTES=0 ARRAY_TOTAL_BYTES=0 ARRAY_USED_HR="" ARRAY_TOTAL_HR=""
POOLS_COUNT=0 POOLS_PERCENT="" POOLS_USED_BYTES=0 POOLS_TOTAL_BYTES=0 POOLS_USED_HR="" POOLS_TOTAL_HR=""

# Thresholds for SMART attributes (you can tune these)
ALERT_WARN=()
ALERT_CRIT=()
RELOC_WARNING=1               # Reallocated sectors >= this -> warning
RELOC_CRITICAL=10             # >= this -> critical
PEND_WARNING=1                # Pending sectors >= -> critical (treat as critical)
TEMP_WARNING=60               # Celsius -> warning
TEMP_CRITICAL=70              # Celsius -> critical
NVME_PERCENT_USED_WARN=80
NVME_PERCENT_USED_CRIT=90

# Log files (timestamped)
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
LOG_DIR="/boot/logs/disk-health"
mkdir -p "$LOG_DIR"
SMART_LOG="$LOG_DIR/unraid_smart_$TIMESTAMP.log"
BTRFS_LOG="$LOG_DIR/unraid_btrfs_$TIMESTAMP.log"
XFS_LOG="$LOG_DIR/unraid_xfs_$TIMESTAMP.log"
SMART_LONG_STATE_FILE="$LOG_DIR/unraid_smart_long_processed.log"
SMART_LAST="/boot/logs/disk-health/unraid_smart_last_test.log"

# Notification titles
NOTIFY_TITLE_SMART="SMART Test Alert"
NOTIFY_TITLE_BTRFS="Btrfs Scrub Alert"
NOTIFY_TITLE_XFS="XFS Alert"

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

# Accumulate alerts (warning/critical) for optional consolidated summary.
record_alert() {
    local sev="$1"; shift
    local title="$1"; shift
    local body="$1"; shift
    if [[ "$sev" =~ ^(critical|CRITICAL)$ ]]; then
        ALERT_CRIT+=("$title: $body")
    else
        ALERT_WARN+=("$title: $body")
    fi
    if [[ $ENABLE_NOTIFY -eq 1 && $CONS_NOTIFY -eq 0 ]]; then
        notify_unraid "$title" "$body" "$sev"
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
get_all_disks() {
    # Retain original discovery method as per user preference; spins up disks intentionally.
    local sata nvme out=()
    sata=$(ls /dev/sd? 2>/dev/null | grep -v '[0-9]$' || true)
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

# Load last SMART test dates
declare -A LAST_TEST
if [ -f "$SMART_LAST" ]; then
    while read -r disk date; do
        LAST_TEST["$disk"]=$date
    done < "$SMART_LAST"
fi

save_last_test() {
    > "$SMART_LAST"
    for disk in "${!LAST_TEST[@]}"; do
        echo "$disk ${LAST_TEST[$disk]}" >> "$SMART_LAST"
    done
}

# Parse SMART attributes for SATA/SAS/SSD
parse_smart_attributes() {
    local disk=$1
    # produce simple key=value lines
    smartctl -A $disk 2>/dev/null | awk '/Model/||/Serial/||/Reallocated_Sector_Ct/||/Current_Pending_Sector/||/Offline_Uncorrectable/||/Temperature_Celsius/||/Power_On_Hours/||/UDMA_CRC_Error_Count/||/Wear_Leveling_Count/||/Media_Wearout_Indicator/ {print}'
}

# Parse NVMe SMART details
nvme_parse_details() {
    local disk=$1
    # collect common NVMe health fields
    smartctl -a -d nvme $disk 2>/dev/null | awk '/Critical Warning/||/Percentage Used/||/Data Units Written/||/Data Units Read/||/Available Spare/||/Temperature/ {print}'
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
        local percent_used crit_warn nvme_temp
        percent_used=$(echo "$nvme_output" | awk -F: '/Percentage Used/ {gsub(/%| /,"",$2); print $2; exit}')
        percent_used=${percent_used:-0}
        crit_warn=$(echo "$nvme_output" | awk -F: '/Critical Warning/ {gsub(/ |\t/,"",$2); print $2; exit}')
        crit_warn=${crit_warn:-0}
        # Extract numeric NVMe temperature (strip units/words like "Celsius")
        nvme_temp=$(echo "$nvme_output" | awk -F: '/Temperature/ {print $2; exit}' | grep -oE '[0-9]+' | head -n1)
        if [[ $percent_used -ge $NVME_PERCENT_USED_CRIT ]]; then
            state="CRITICAL"; messages+=("NVMe wear ${percent_used}% >= ${NVME_PERCENT_USED_CRIT}%")
        elif [[ $percent_used -ge $NVME_PERCENT_USED_WARN ]]; then
            state="WARNING"; messages+=("NVMe wear ${percent_used}% >= ${NVME_PERCENT_USED_WARN}%")
        fi
        if [[ $crit_warn -ne 0 ]]; then
            state="CRITICAL"; messages+=("NVMe Critical Warning flags: $crit_warn")
        fi
        if [[ -n "$nvme_temp" ]]; then
            if [[ $nvme_temp -ge $TEMP_CRITICAL ]]; then
                state="CRITICAL"; messages+=("NVMe Temp ${nvme_temp}C >= ${TEMP_CRITICAL}C")
            elif [[ $nvme_temp -ge $TEMP_WARNING && $state != CRITICAL ]]; then
                [[ $state == OK ]] && state="WARNING"; messages+=("NVMe Temp ${nvme_temp}C >= ${TEMP_WARNING}C")
            fi
        fi
    else
        local attr realloc pending offunc temp udma
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
    if [[ $ENABLE_NOTIFY -eq 1 && ( $state == WARNING || $state == CRITICAL ) ]]; then
        record_alert "$state" "$NOTIFY_TITLE_SMART" "Disk $disk SMART $state: $(echo "$msgs" | tr '\n' ' ')"
    fi
    LAST_TEST[$disk]=$(date '+%Y-%m-%d')
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
            [[ $ENABLE_NOTIFY -eq 1 ]] && record_alert critical "$NOTIFY_TITLE_BTRFS" "$msg"
        elif [[ $corrected -gt 0 ]]; then
            msg="WARNING: $mp scrub corrected=$corrected"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a "$BTRFS_LOG"
            [[ $ENABLE_NOTIFY -eq 1 ]] && record_alert warning "$NOTIFY_TITLE_BTRFS" "$msg"
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
                    [[ $ENABLE_NOTIFY -eq 1 ]] && record_alert critical "$NOTIFY_TITLE_XFS" "$msg"
                fi
            fi
        fi
        if dmesg | tail -n 3000 | grep -qiE "$(basename "$mp").*(XFS|I/O error)|XFS ERROR|xfs_repair"; then
            msg="WARNING: Kernel/XFS I/O messages for $mp"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a "$XFS_LOG"
            [[ $ENABLE_NOTIFY -eq 1 ]] && record_alert warning "$NOTIFY_TITLE_XFS" "$msg"
        fi
    done
    echo "$(date '+%Y-%m-%d %H:%M:%S') - XFS checks completed" | tee -a "$XFS_LOG"
}

# ---------------- Storage Metrics ----------------
compute_storage_metrics() {
    # Reset metrics
    ARRAY_COUNT=0; ARRAY_PERCENT=""; ARRAY_USED_BYTES=0; ARRAY_TOTAL_BYTES=0; ARRAY_USED_HR=""; ARRAY_TOTAL_HR=""
    POOLS_COUNT=0; POOLS_PERCENT=""; POOLS_USED_BYTES=0; POOLS_TOTAL_BYTES=0; POOLS_USED_HR=""; POOLS_TOTAL_HR=""

    # Array: /mnt/disk*
    local array_mounts=()
    for d in /mnt/disk*; do
        [[ -d $d ]] || continue
        mountpoint -q "$d" || continue
        array_mounts+=("$d")
    done
    if (( ${#array_mounts[@]} > 0 )); then
        ARRAY_COUNT=${#array_mounts[@]}
        local used=0 size=0 free=0
        for d in "${array_mounts[@]}"; do
            local line sz u a
            line=$(df -B1 "$d" 2>/dev/null | awk 'NR==2') || continue
            sz=$(echo "$line" | awk '{print $2}'); u=$(echo "$line" | awk '{print $3}'); a=$(echo "$line" | awk '{print $4}')
            sz=${sz:-0}; u=${u:-0}; a=${a:-0}
            used=$((used + u)); size=$((size + sz)); free=$((free + a))
        done
        if (( size > 0 )); then
            ARRAY_USED_BYTES=$used; ARRAY_TOTAL_BYTES=$size
            ARRAY_USED_HR=$(human_readable "$used"); ARRAY_TOTAL_HR=$(human_readable "$size")
            ARRAY_PERCENT=$(awk "BEGIN{printf \"%.1f\", ($used/$size)*100}")
        fi
    fi

    # Pools: /mnt/* excluding disk* and user and POOL_EXCLUDES
    local pool_mounts=()
    for m in /mnt/*; do
        [[ -d $m ]] || continue
        mountpoint -q "$m" || continue
        local name; name=$(basename "$m")
        case "$name" in
            disk*|user) continue;;
        esac
        local skip=0
        for ex in "${POOL_EXCLUDES[@]}"; do
            if [[ "$name" == "$ex" || "$m" == "$ex" ]]; then skip=1; break; fi
        done
        (( skip == 1 )) && continue
        pool_mounts+=("$m")
    done
    if (( ${#pool_mounts[@]} > 0 )); then
        POOLS_COUNT=${#pool_mounts[@]}
        local used=0 size=0 free=0
        for p in "${pool_mounts[@]}"; do
            local line sz u a
            line=$(df -B1 "$p" 2>/dev/null | awk 'NR==2') || continue
            sz=$(echo "$line" | awk '{print $2}'); u=$(echo "$line" | awk '{print $3}'); a=$(echo "$line" | awk '{print $4}')
            sz=${sz:-0}; u=${u:-0}; a=${a:-0}
            used=$((used + u)); size=$((size + sz)); free=$((free + a))
        done
        if (( size > 0 )); then
            POOLS_USED_BYTES=$used; POOLS_TOTAL_BYTES=$size
            POOLS_USED_HR=$(human_readable "$used"); POOLS_TOTAL_HR=$(human_readable "$size")
            POOLS_PERCENT=$(awk "BEGIN{printf \"%.1f\", ($used/$size)*100}")
        fi
    fi
}

# Build human-readable storage status lines for notification body
format_storage_status_lines() {
    local lines=""
    local symbol
    if [[ -n "${ARRAY_PERCENT:-}" ]]; then
        if awk -v p="$ARRAY_PERCENT" -v t="$THRESHOLD" 'BEGIN{exit (p>t)?0:1}'; then symbol="$STORAGE_STATUS_EMOJI_RED";
        elif awk -v p="$ARRAY_PERCENT" -v t="$THRESHOLD" -v d="$NEAR_THRESHOLD_DELTA" 'BEGIN{exit (p + d >= t)?0:1}'; then symbol="$STORAGE_STATUS_EMOJI_YELLOW";
        else symbol="$STORAGE_STATUS_EMOJI_GREEN"; fi
        lines+=$(printf "%s Array (%d): %s%% — %s used of %s\n" "$symbol" "${ARRAY_COUNT:-0}" "${ARRAY_PERCENT:-0.0}" "${ARRAY_USED_HR:-0 B}" "${ARRAY_TOTAL_HR:-0 B}")
    fi
    if [[ -n "${POOLS_PERCENT:-}" ]]; then
        if awk -v p="$POOLS_PERCENT" -v t="$THRESHOLD" 'BEGIN{exit (p>t)?0:1}'; then symbol="$STORAGE_STATUS_EMOJI_RED";
        elif awk -v p="$POOLS_PERCENT" -v t="$THRESHOLD" -v d="$NEAR_THRESHOLD_DELTA" 'BEGIN{exit (p + d >= t)?0:1}'; then symbol="$STORAGE_STATUS_EMOJI_YELLOW";
        else symbol="$STORAGE_STATUS_EMOJI_GREEN"; fi
        lines+=$(printf "%s Pools (%d): %s%% — %s used of %s\n" "$symbol" "${POOLS_COUNT:-0}" "${POOLS_PERCENT:-0.0}" "${POOLS_USED_HR:-0 B}" "${POOLS_TOTAL_HR:-0 B}")
    fi
    printf "%s" "$lines"
}

# Capacity alert evaluation
evaluate_capacity_alerts() {
    if [[ -n "$ARRAY_PERCENT" ]]; then
        if awk -v p="$ARRAY_PERCENT" -v t="$THRESHOLD" 'BEGIN{exit (p>t)?0:1}'; then
            [[ $ENABLE_NOTIFY -eq 1 ]] && record_alert critical "Array Capacity" "Array usage ${ARRAY_PERCENT}% > ${THRESHOLD}%"
        elif awk -v p="$ARRAY_PERCENT" -v t="$THRESHOLD" -v d="$NEAR_THRESHOLD_DELTA" 'BEGIN{exit (p + d >= t)?0:1}'; then
            [[ $ENABLE_NOTIFY -eq 1 ]] && record_alert warning "Array Capacity" "Array usage ${ARRAY_PERCENT}% near ${THRESHOLD}%"
        fi
    fi
    if [[ -n "$POOLS_PERCENT" ]]; then
        if awk -v p="$POOLS_PERCENT" -v t="$THRESHOLD" 'BEGIN{exit (p>t)?0:1}'; then
            [[ $ENABLE_NOTIFY -eq 1 ]] && record_alert critical "Pools Capacity" "Pools usage ${POOLS_PERCENT}% > ${THRESHOLD}%"
        elif awk -v p="$POOLS_PERCENT" -v t="$THRESHOLD" -v d="$NEAR_THRESHOLD_DELTA" 'BEGIN{exit (p + d >= t)?0:1}'; then
            [[ $ENABLE_NOTIFY -eq 1 ]] && record_alert warning "Pools Capacity" "Pools usage ${POOLS_PERCENT}% near ${THRESHOLD}%"
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
            [[ $ENABLE_NOTIFY -eq 1 ]] && record_alert critical "Storage Critical" "$mp usage ${usep}% >= ${CRITICAL_THRESHOLD_PERCENT}%"
        elif [[ $usep -ge $WARN_THRESHOLD_PERCENT ]]; then
            [[ $ENABLE_NOTIFY -eq 1 ]] && record_alert warning "Storage Warning" "$mp usage ${usep}% >= ${WARN_THRESHOLD_PERCENT}%"
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

monitor_btrfs
monitor_xfs

compute_storage_metrics
evaluate_per_mount_thresholds
evaluate_capacity_alerts

if [[ $ENABLE_NOTIFY -eq 1 && $CONS_NOTIFY -eq 1 ]]; then
    total_warn=${#ALERT_WARN[@]}; total_crit=${#ALERT_CRIT[@]}
    if (( total_warn + total_crit > 0 )); then
        subject="Unraid Health Summary: ${total_crit} critical / ${total_warn} warning"
        icon="normal"
        (( total_crit > 0 )) && icon="alert" || { (( total_warn > 0 )) && icon="warning"; }
        body="$(format_storage_status_lines)\n"
        if (( total_crit > 0 )); then
            body+="Critical Issues:\n"; for i in "${ALERT_CRIT[@]}"; do body+=" - $i\n"; done; body+="\n"
        fi
        if (( total_warn > 0 )); then
            body+="Warnings:\n"; for i in "${ALERT_WARN[@]}"; do body+=" - $i\n"; done; body+="\n"
        fi
        notify_unraid "$subject" "$body" "$icon"
        if [[ $EMAIL_ENABLED -eq 1 && -n "$EMAIL_TO" ]]; then
            printf "%s" "$body" | mail -s "$subject" "$EMAIL_TO" || logger -t unraid_monitor "Email send failed"
        fi
    else
        notify_unraid "Unraid Health Summary" "$(format_storage_status_lines)\nNo warnings or critical issues." ok
        if [[ $EMAIL_ENABLED -eq 1 && -n "$EMAIL_TO" ]]; then
            printf "%s\nNo warnings or critical issues.\n" "$(format_storage_status_lines)" | mail -s "Unraid Health Summary" "$EMAIL_TO" || logger -t unraid_monitor "Email send failed"
        fi
    fi
fi

exit 0
