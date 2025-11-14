#!/bin/bash
# Unified Unraid SMART + Btrfs + XFS Monitor (Enhanced)
# Features added/updated per user request:
# 1) Timestamped logs/reports
# 2) Use Unraid notify for failures (warning = notify type)
# 3) SMART parsing: pending sectors, reallocated, temperature etc. -> OK/WARNING/CRITICAL
# 4) Per-disk storage used/available + percentage + threshold reporting
# 5) Total storage used/available for arrays (/mnt/user) and for each pool/mount
# 6) Enhanced notifications for SMART/Btrfs/XFS (warning/critical)
# 7) NVMe detailed parsing (wear, life left) - see function nvme_parse_details

# ---------------- Configuration ----------------
SMART_TEST_TYPE="long"       # "short" or "long"
SMART_INTERVAL_DAYS=30        # Days between long tests per disk
ENABLE_NOTIFY=1               # 1 = yes, 0 = no
WARN_THRESHOLD_PERCENT=80     # percentage used per-disk to warn
CRITICAL_THRESHOLD_PERCENT=90 # percentage used per-disk to critical-alert

# Thresholds for SMART attributes (you can tune these)
RELOC_WARNING=1               # Reallocated sectors >= this -> warning
RELOC_CRITICAL=10             # >= this -> critical
PEND_WARNING=1                # Pending sectors >= -> critical (treat as critical)
TEMP_WARNING=60               # Celsius -> warning
TEMP_CRITICAL=70              # Celsius -> critical
NVME_PERCENT_USED_WARN=80
NVME_PERCENT_USED_CRIT=90

# Log files (timestamped)
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
LOG_DIR="/var/log/unraid_monitor"
mkdir -p "$LOG_DIR"
SMART_LOG="$LOG_DIR/unraid_smart_$TIMESTAMP.log"
BTRFS_LOG="$LOG_DIR/unraid_btrfs_$TIMESTAMP.log"
XFS_LOG="$LOG_DIR/unraid_xfs_$TIMESTAMP.log"
REPORT_DIR="/var/log/unraid_reports"
mkdir -p "$REPORT_DIR"
REPORT_FILE="$REPORT_DIR/unraid_report_$TIMESTAMP.txt"
SMART_LAST="/boot/config/plugins/unraid_smart_last_test.log"

# Notification titles
NOTIFY_TITLE_SMART="SMART Test Alert"
NOTIFY_TITLE_BTRFS="Btrfs Scrub Alert"
NOTIFY_TITLE_XFS="XFS Alert"

# Optional: run XFS metadata check (set 1 to enable)
RUN_XFS_CHECK=0

# Helper: Unraid notify wrapper (type: 'warning' or 'critical')
notify_unraid() {
    local title="$1"
    local body="$2"
    local type=${3:-"warning"}
    # Use dynamix system utilities notification plugin if available
    if [ -x "/usr/local/emhttp/plugins/dynamix.system.utilities/scripts/notify" ]; then
        /usr/local/emhttp/plugins/dynamix.system.utilities/scripts/notify "$body" "$title"
    else
        # Fallback to logger
        logger -t unraid_monitor "$title: $body"
    fi
}

# ---------------- Disk and SMART Helpers ----------------
get_all_disks() {
    local sata=$(ls /dev/sd? 2>/dev/null | grep -v '[0-9]$')
    local nvme=$(ls /dev/nvme?n? 2>/dev/null)
    echo "$sata $nvme"
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
    if [[ $disk == /dev/nvme* ]]; then is_nvme=1; fi

    # Initialize state
    local state="OK"
    local messages=()

    if [[ $is_nvme -eq 1 ]]; then
        # NVMe specific checks
        local nvme_output
        nvme_output=$(smartctl -A -d nvme $disk 2>/dev/null)
        # Percentage Used
        percent_used=$(echo "$nvme_output" | awk -F: '/Percentage Used/ {gsub(/%/,"",$2); print $2}' | tr -d ' ')
        percent_used=${percent_used:-0}
        crit_warn=$(echo "$nvme_output" | awk -F: '/Critical Warning/ {gsub(/ /, "", $2); print $2}' | tr -d ' ')
        crit_warn=${crit_warn:-0}
        if [[ $percent_used -ge $NVME_PERCENT_USED_CRIT ]]; then
            state="CRITICAL"
            messages+=("NVMe Percentage Used ${percent_used}% >= ${NVME_PERCENT_USED_CRIT}%")
        elif [[ $percent_used -ge $NVME_PERCENT_USED_WARN ]]; then
            state="WARNING"
            messages+=("NVMe Percentage Used ${percent_used}% >= ${NVME_PERCENT_USED_WARN}%")
        fi
        if [[ $crit_warn -ne 0 ]]; then
            state="CRITICAL"
            messages+=("NVMe Critical Warning flags: $crit_warn")
        fi
    else
        # SATA/SAS/SSD checks
        local attr
        attr=$(smartctl -A $disk 2>/dev/null)
        # Reallocated sectors
        realloc=$(echo "$attr" | awk '/Reallocated_Sector_Ct/ {print $10}' | head -n1)
        realloc=${realloc:-0}
        if [[ $realloc -ge $RELOC_CRITICAL ]]; then
            state="CRITICAL"
            messages+=("Reallocated sectors = $realloc (>= $RELOC_CRITICAL)")
        elif [[ $realloc -ge $RELOC_WARNING ]]; then
            state="WARNING"
            messages+=("Reallocated sectors = $realloc (>= $RELOC_WARNING)")
        fi
        pending=$(echo "$attr" | awk '/Current_Pending_Sector/ {print $10}' | head -n1)
        pending=${pending:-0}
        if [[ $pending -ge $PEND_WARNING ]]; then
            state="CRITICAL"
            messages+=("Current Pending Sectors = $pending")
        fi
        offunc=$(echo "$attr" | awk '/Offline_Uncorrectable/ {print $10}' | head -n1)
        offunc=${offunc:-0}
        if [[ $offunc -gt 0 ]]; then
            state="CRITICAL"
            messages+=("Offline Uncorrectable = $offunc")
        fi
        temp=$(echo "$attr" | awk '/Temperature_Celsius/ {print $10; exit}' )
        temp=${temp:-0}
        if [[ $temp -ge $TEMP_CRITICAL ]]; then
            state="CRITICAL"
            messages+=("Temperature = ${temp}C >= ${TEMP_CRITICAL}C")
        elif [[ $temp -ge $TEMP_WARNING ]]; then
            if [[ "$state" != "CRITICAL" ]]; then state="WARNING"; fi
            messages+=("Temperature = ${temp}C >= ${TEMP_WARNING}C")
        fi
        udma=$(echo "$attr" | awk '/UDMA_CRC_Error_Count/ {print $10; exit}' )
        udma=${udma:-0}
        if [[ $udma -gt 0 ]]; then
            if [[ "$state" != "CRITICAL" ]]; then state="WARNING"; fi
            messages+=("UDMA CRC Errors = $udma")
        fi
    fi

    # Output: state and messages
    echo "$state"
    for m in "${messages[@]}"; do echo "$m"; done
}

# Get per-disk usage (human readable and percentage)
get_disk_usage() {
    local disk=$1
    # find matching DF line; try matching full device name or basename
    local bname=$(basename $disk)
    local line
    line=$(df -h | awk -v d="$disk" -v b="$bname" '$1==d || $1=="/dev/"b {print $0}')
    if [ -z "$line" ]; then
        # fallback: look for any df line containing basename
        line=$(df -h | grep $bname | head -n1)
    fi
    if [ -z "$line" ]; then
        echo "NO_MOUNT 0 0 0"
        return
    fi
    # parse: Filesystem Size Used Avail Use% Mounted on
    local fs size used avail usep mp
    read -r fs size used avail usep mp <<<$(echo $line | awk '{print $1" " $2" " $3" " $4" " $5" " $6}')
    echo "$mp $size $used $avail $usep"
}

# Get total storage used/available for arrays and pools
get_total_usage() {
    # Array (user share) total
    local arr_line
    arr_line=$(df -h | awk '$6=="/mnt/user" {print $2" "$3" "$4" "$5}')
    echo "$arr_line"
}

# ---------------- SMART test runner ----------------
run_smart_test() {
    local disk=$1
    local now=$(date +%s)
    if [[ -n "${LAST_TEST[$disk]}" ]]; then
        local last_sec
        last_sec=$(date -d "${LAST_TEST[$disk]}" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "${LAST_TEST[$disk]}" +%s 2>/dev/null)
        if [[ -n "$last_sec" ]]; then
            local diff_days=$(( (now - last_sec) / 86400 ))
            if [[ $diff_days -lt $SMART_INTERVAL_DAYS ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Skipping $disk, last SMART test $diff_days days ago" | tee -a "$SMART_LOG"
                return
            fi
        fi
    fi

    [[ $disk == /dev/sd* ]] && hdparm -I $disk >/dev/null 2>&1
    local flag="-t long"
    [[ "$SMART_TEST_TYPE" == "short" ]] && flag="-t short"

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting $SMART_TEST_TYPE test on $disk" | tee -a "$SMART_LOG"

    if [[ $disk == /dev/nvme* ]]; then
        smartctl $flag -d nvme $disk >/dev/null 2>&1
    else
        smartctl $flag $disk >/dev/null 2>&1
    fi

    sleep 5
    # Evaluate immediate SMART attributes
    state_and_msgs=$(evaluate_smart $disk)
    state=$(echo "$state_and_msgs" | head -n1)
    msgs=$(echo "$state_and_msgs" | tail -n +2)
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $disk SMART state: $state" | tee -a "$SMART_LOG"
    if [ -n "$msgs" ]; then
        echo "$msgs" | tee -a "$SMART_LOG"
    fi

    if [[ "$state" == "WARNING" || "$state" == "CRITICAL" ]]; then
        if [[ $ENABLE_NOTIFY -eq 1 ]]; then
            notify_unraid "$NOTIFY_TITLE_SMART" "Disk $disk SMART $state: $(echo $msgs | tr '
' ' ' )"
        fi
    fi

    LAST_TEST[$disk]=$(date '+%Y-%m-%d')
}

# ---------------- Btrfs monitoring ----------------
monitor_btrfs() {
    local mountpoints
    mountpoints=$(mount | grep btrfs | awk '{print $3}')
    for mp in $mountpoints; do
        raid_type=$(btrfs filesystem df $mp | grep "Data," | awk '{print $2}')
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting Btrfs scrub on $mp (RAID type: $raid_type)" | tee -a "$BTRFS_LOG"
        scrub_out=$(btrfs scrub start -B $mp 2>&1)
        echo "$scrub_out" | tee -a "$BTRFS_LOG"
        stats=$(btrfs device stats $mp 2>/dev/null)
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Btrfs device stats for $mp:" | tee -a "$BTRFS_LOG"
        echo "$stats" | tee -a "$BTRFS_LOG"

        # parse for corrected/uncorrectable
        corrected=$(echo "$scrub_out" | awk -F: '/errors corrected/{gsub(/ /,"",$2); print $2}' )
        uncorrectable=$(echo "$scrub_out" | awk -F: '/errors uncorrectable/{gsub(/ /,"",$2); print $2}' )
        corrected=${corrected:-0}
        uncorrectable=${uncorrectable:-0}

        if [[ $uncorrectable -gt 0 ]]; then
            if [[ "$raid_type" == "RAID0" ]]; then
                msg="CRITICAL: RAID0 pool $mp has $uncorrectable uncorrectable errors — data cannot be auto-repaired"
            else
                msg="CRITICAL: Btrfs pool $mp has $uncorrectable uncorrectable errors"
            fi
            echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a "$BTRFS_LOG"
            [[ $ENABLE_NOTIFY -eq 1 ]] && notify_unraid "$NOTIFY_TITLE_BTRFS" "$msg"
        elif [[ $corrected -gt 0 ]]; then
            msg="WARNING: Btrfs pool $mp scrub corrected $corrected errors"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a "$BTRFS_LOG"
            [[ $ENABLE_NOTIFY -eq 1 ]] && notify_unraid "$NOTIFY_TITLE_BTRFS" "$msg"
        fi
    done
}

# ---------------- XFS monitoring ----------------
monitor_xfs() {
    local mountpoints
    mountpoints=$(mount | grep xfs | awk '{print $3}')
    for mp in $mountpoints; do
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Checking XFS pool $mp" | tee -a "$XFS_LOG"
        if [[ $RUN_XFS_CHECK -eq 1 ]]; then
            # xfs_repair requires device node; user must stop array/umount or use -n for no modify
            xfs_out=$(xfs_repair -n $mp 2>&1)
            echo "$xfs_out" | tee -a "$XFS_LOG"
            if echo "$xfs_out" | grep -qi "error\|corrupt"; then
                msg="CRITICAL: XFS metadata issues detected on $mp (see logs)"
                echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a "$XFS_LOG"
                [[ $ENABLE_NOTIFY -eq 1 ]] && notify_unraid "$NOTIFY_TITLE_XFS" "$msg"
            fi
        fi
        # scan kernel logs for XFS/I/O errors relating to mountpoint
        if dmesg | tail -n 2000 | grep -qi "$(basename $mp).*XFS\|I/O error\|xfs"; then
            msg="WARNING: Recent kernel/XFS or I/O messages for $mp — check system logs"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a "$XFS_LOG"
            [[ $ENABLE_NOTIFY -eq 1 ]] && notify_unraid "$NOTIFY_TITLE_XFS" "$msg"
        fi
    done
}

# ---------------- Reporting helpers ----------------
append_report_header() {
    echo "===================================" >> "$REPORT_FILE"
    echo "Unraid Health Report - Generated: $(date '+%Y-%m-%d %H:%M:%S')" >> "$REPORT_FILE"
    echo "===================================" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
}

generate_report() {
    append_report_header

    echo "SMART Summary (recent):" >> "$REPORT_FILE"
    echo "----------------------" >> "$REPORT_FILE"
    tail -n 200 "$SMART_LOG" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    echo "Btrfs Summary (recent):" >> "$REPORT_FILE"
    echo "-----------------------" >> "$REPORT_FILE"
    tail -n 200 "$BTRFS_LOG" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    echo "XFS Summary (recent):" >> "$REPORT_FILE"
    echo "---------------------" >> "$REPORT_FILE"
    tail -n 200 "$XFS_LOG" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    echo "Per-disk usage and thresholds:" >> "$REPORT_FILE"
    echo "-----------------------------" >> "$REPORT_FILE"
    for disk in $(get_all_disks); do
        echo "Disk: $disk" >> "$REPORT_FILE"
        usage=$(get_disk_usage $disk)
        echo "Usage: $usage" >> "$REPORT_FILE"
        # check threshold
        usep=$(echo "$usage" | awk '{print $4}' | tr -d '%')
        if [[ "$usep" != "" && "$usep" != "0" ]]; then
            if [[ $usep -ge $CRITICAL_THRESHOLD_PERCENT ]]; then
                echo "!! CRITICAL: Disk $disk usage ${usep}% >= ${CRITICAL_THRESHOLD_PERCENT}%" >> "$REPORT_FILE"
                [[ $ENABLE_NOTIFY -eq 1 ]] && notify_unraid "Storage Critical" "Disk $disk usage ${usep}% >= ${CRITICAL_THRESHOLD_PERCENT}%"
            elif [[ $usep -ge $WARN_THRESHOLD_PERCENT ]]; then
                echo "! WARNING: Disk $disk usage ${usep}% >= ${WARN_THRESHOLD_PERCENT}%" >> "$REPORT_FILE"
                [[ $ENABLE_NOTIFY -eq 1 ]] && notify_unraid "Storage Warning" "Disk $disk usage ${usep}% >= ${WARN_THRESHOLD_PERCENT}%"
            fi
        fi
        echo "" >> "$REPORT_FILE"
    done

    echo "Total array (user share) usage:" >> "$REPORT_FILE"
    echo "--------------------------------" >> "$REPORT_FILE"
    df -h /mnt/user >> "$REPORT_FILE" 2>/dev/null || echo "/mnt/user not mounted" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    echo "Pool mountpoints usage:" >> "$REPORT_FILE"
    echo "-----------------------" >> "$REPORT_FILE"
    # all btrfs and xfs mounts
    mount | egrep "btrfs|xfs" | awk '{print $3}' | while read -r mp; do
        echo "Mount: $mp" >> "$REPORT_FILE"
        df -h $mp >> "$REPORT_FILE" 2>/dev/null
        echo "" >> "$REPORT_FILE"
    done

    echo "Report saved to: $REPORT_FILE"
}

# ---------------- Main ----------------
# 1) Run SMART tests with evaluation
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting SMART tests" | tee -a "$SMART_LOG"
for disk in $(get_all_disks); do
    run_smart_test $disk
done
save_last_test
echo "$(date '+%Y-%m-%d %H:%M:%S') - SMART tests completed" | tee -a "$SMART_LOG"

# 2) Btrfs monitoring
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting Btrfs monitoring" | tee -a "$BTRFS_LOG"
monitor_btrfs
echo "$(date '+%Y-%m-%d %H:%M:%S') - Btrfs monitoring completed" | tee -a "$BTRFS_LOG"

# 3) XFS monitoring
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting XFS monitoring" | tee -a "$XFS_LOG"
monitor_xfs
echo "$(date '+%Y-%m-%d %H:%M:%S') - XFS monitoring completed" | tee -a "$XFS_LOG"

# 4) Generate report
generate_report

# 5) Email option: user must configure 'mail' or msmtp/postfix on Unraid. This is a placeholder.
# Example (uncomment and configure):
# EMAIL_TO="you@example.com"
# mail -s "Unraid Health Report $(date '+%Y-%m-%d')" "$EMAIL_TO" < "$REPORT_FILE"

exit 0
