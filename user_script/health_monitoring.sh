#!/bin/bash
# Unified Unraid SMART + Btrfs + XFS Monitor
# Supports HDD, SATA SSD, NVMe, Btrfs (all RAID types), and XFS pools

# ---------------- Configuration ----------------
# SMART test type: "short" or "long"
SMART_TEST_TYPE="short"
SMART_INTERVAL_DAYS=30      # Days between long tests per disk
ENABLE_NOTIFY=1             # 1 = yes, 0 = no

# Log files
SMART_LOG="/mnt/user/system/log/unraid_smart.log"
BTRFS_LOG="/mnt/user/system/log/unraid_btrfs.log"
XFS_LOG="/mnt/user/system/log/unraid_xfs.log"
SMART_LAST="/mnt/user/system/log/unraid_smart_last_test.log"

# Notification titles
NOTIFY_TITLE_SMART="SMART Test Alert"
NOTIFY_TITLE_BTRFS="Btrfs Scrub Alert"
NOTIFY_TITLE_XFS="XFS Alert"

# Optional: run XFS metadata check (set 1 to enable)
RUN_XFS_CHECK=0

# ---------------- Functions ----------------

# Detect all drives
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

# Save last SMART test dates
save_last_test() {
    > "$SMART_LAST"
    for disk in "${!LAST_TEST[@]}"; do
        echo "$disk ${LAST_TEST[$disk]}" >> "$SMART_LAST"
    done
}

# Run SMART test
run_smart_test() {
    local disk=$1
    local now=$(date +%s)

    if [[ -n "${LAST_TEST[$disk]}" ]]; then
        local last_sec=$(date -d "${LAST_TEST[$disk]}" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "${LAST_TEST[$disk]}" +%s)
        local diff_days=$(( (now - last_sec) / 86400 ))
        if [[ $diff_days -lt $SMART_INTERVAL_DAYS ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Skipping $disk, last SMART test $diff_days days ago" | tee -a $SMART_LOG
            return
        fi
    fi

    [[ $disk == /dev/sd* ]] && hdparm -I $disk >/dev/null 2>&1
    local flag="-t long"
    [[ "$SMART_TEST_TYPE" == "short" ]] && flag="-t short"

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting $SMART_TEST_TYPE test on $disk" | tee -a $SMART_LOG

    if [[ $disk == /dev/nvme* ]]; then
        smartctl $flag -d nvme $disk >/dev/null 2>&1
        # Check percentage used & critical warnings
        percent_used=$(smartctl -A -d nvme $disk | grep "Percentage Used" | awk '{print $4}')
        critical_warn=$(smartctl -A -d nvme $disk | grep "Critical Warnings" | awk '{print $3}')
        if [[ $percent_used -ge 80 || $critical_warn -ne 0 ]]; then
            msg="NVMe $disk degradation warning: Percentage Used=$percent_used%, Critical Warnings=$critical_warn"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a $SMART_LOG
            [[ $ENABLE_NOTIFY -eq 1 ]] && /usr/local/emhttp/plugins/dynamix.system.utilities/scripts/notify "$msg" "$NOTIFY_TITLE_SMART"
        fi
    else
        smartctl $flag $disk >/dev/null 2>&1
    fi

    sleep 5
    local status
    if [[ $disk == /dev/nvme* ]]; then
        status=$(smartctl -a -d nvme $disk | grep -i "Self-test")
    else
        status=$(smartctl -a $disk | grep -i "Self-test execution status")
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $disk status: $status" | tee -a $SMART_LOG

    if echo "$status" | grep -qi "interrupted\|aborted\|error"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - SMART test FAILED on $disk" | tee -a $SMART_LOG
        [[ $ENABLE_NOTIFY -eq 1 ]] && /usr/local/emhttp/plugins/dynamix.system.utilities/scripts/notify "SMART test FAILED on $disk" "$NOTIFY_TITLE_SMART"
    fi

    LAST_TEST[$disk]=$(date '+%Y-%m-%d')
}

# Monitor Btrfs
monitor_btrfs() {
    local mountpoints
    mountpoints=$(mount | grep btrfs | awk '{print $3}')
    for mp in $mountpoints; do
        raid_type=$(btrfs filesystem df $mp | grep "Data," | awk '{print $2}')
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting Btrfs scrub on $mp (RAID type: $raid_type)" | tee -a $BTRFS_LOG
        btrfs scrub start -B $mp 2>&1 | tee -a $BTRFS_LOG
        stats=$(btrfs device stats $mp)
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Btrfs device stats for $mp:" | tee -a $BTRFS_LOG
        echo "$stats" | tee -a $BTRFS_LOG
        if echo "$stats" | grep -qE "corruption|read_errs|write_errs"; then
            if [[ "$raid_type" == "RAID0" ]]; then
                msg="ALERT: RAID0 pool $mp has errors! Data cannot be automatically repaired!"
            else
                msg="Btrfs errors detected on $mp (redundant RAID type: $raid_type)"
            fi
            echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a $BTRFS_LOG
            [[ $ENABLE_NOTIFY -eq 1 ]] && /usr/local/emhttp/plugins/dynamix.system.utilities/scripts/notify "$msg" "$NOTIFY_TITLE_BTRFS"
        fi
    done
}

# Monitor XFS
monitor_xfs() {
    local mountpoints
    mountpoints=$(mount | grep xfs | awk '{print $3}')
    for mp in $mountpoints; do
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Checking XFS pool $mp" | tee -a $XFS_LOG
        # Optional metadata check
        if [[ $RUN_XFS_CHECK -eq 1 ]]; then
            xfs_repair -n $mp 2>&1 | tee -a $XFS_LOG
        fi
        # Scan logs for errors
        if dmesg | tail -n 1000 | grep -q "$mp.*XFS"; then
            msg="XFS error detected on $mp! Check system logs."
            echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a $XFS_LOG
            [[ $ENABLE_NOTIFY -eq 1 ]] && /usr/local/emhttp/plugins/dynamix.system.utilities/scripts/notify "$msg" "$NOTIFY_TITLE_XFS"
        fi
    done
}

# ---------------- Main ----------------

echo "============================================" >> $SMART_LOG
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting SMART tests" >> $SMART_LOG
for disk in $(get_all_disks); do
    run_smart_test $disk
done
save_last_test
echo "$(date '+%Y-%m-%d %H:%M:%S') - SMART tests completed" >> $SMART_LOG
echo "============================================" >> $SMART_LOG

echo "============================================" >> $BTRFS_LOG
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting Btrfs monitoring" >> $BTRFS_LOG
monitor_btrfs
echo "$(date '+%Y-%m-%d %H:%M:%S') - Btrfs monitoring completed" >> $BTRFS_LOG
echo "============================================" >> $BTRFS_LOG

echo "============================================" >> $XFS_LOG
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting XFS monitoring" >> $XFS_LOG
monitor_xfs
echo "$(date '+%Y-%m-%d %H:%M:%S') - XFS monitoring completed" >> $XFS_LOG
echo "============================================" >> $XFS_LOG