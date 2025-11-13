#!/bin/bash

# Prevent concurrent runs
LOCKFILE="/tmp/disk_health_storage_report.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Another disk_health_storage_report.sh run is active, exiting (lock: $LOCKFILE)"
    exit 1
fi

# --------------------------------------------------------------------------------
# SETTINGS
# Adjust these values to tune alerts and checks
# THRESHOLD: percentage used to trigger alerts
# NEAR_THRESHOLD_DELTA: how many percentage points below threshold counts as "near"
# POOL_EXCLUDES: basenames or mount paths to ignore when enumerating pools
THRESHOLD=90
NEAR_THRESHOLD_DELTA=5
POOL_EXCLUDES=("ramtmp" "user0")


# Tools defaults (will check availability at runtime)
SMARTCTL_CMD="/usr/sbin/smartctl"
BTRFS_CMD="/sbin/btrfs"
XFS_CHECK_CMD="/sbin/xfs_repair" # used for quick check invocation (we'll run -n)

# Spin-up sleep (seconds) used when waking drives via small read
SPINUP_SLEEP=${SPINUP_SLEEP:-6}
SPINUP_RETRIES=${SPINUP_RETRIES:-3}

# Directory to save smartctl full output per device for diagnostics
SMART_DUMP_DIR=${SMART_DUMP_DIR:-/mnt/user/system/disk_health_smart_dumps}

# Ensure SMART_DUMP_DIR is usable; if not, fall back to /tmp
if ! mkdir -p "$SMART_DUMP_DIR" 2>/dev/null || [ ! -w "$SMART_DUMP_DIR" ]; then
    log "SMART_DUMP_DIR '$SMART_DUMP_DIR' not writable or cannot be created; falling back to /tmp/disk_health_smart_dumps"
    SMART_DUMP_DIR=/tmp/disk_health_smart_dumps
    mkdir -p "$SMART_DUMP_DIR" 2>/dev/null || true
fi

# SMART thresholds (used for decisioning in checks)
SMART_REALLOC_WARN=${SMART_REALLOC_WARN:-1}
SMART_REALLOC_CRIT=${SMART_REALLOC_CRIT:-10}
UDMA_CRC_WARN=${UDMA_CRC_WARN:-1}

# --------------------------------------------------------------------------------

# Return 0 if path should be excluded, 1 otherwise
is_excluded() {
    local path=$1
    local base
    base=$(basename "$path")
    for ex in "${POOL_EXCLUDES[@]:-}"; do
        [ -z "$ex" ] && continue
        if [ "$ex" = "$path" ] || [ "$ex" = "$base" ]; then
            return 0
        fi
    done
    return 1
}

# The hdparm-based bulk spin helpers were removed in favor of the tested
# smartctl + tiny-dd spin behaviour implemented in check_disk_smart().
# If you need hdparm/sg_start-based wake behaviour for specific HBAs,
# reintroduce a spin helper and guard it behind a config flag (e.g.
# USE_HDPARM=YES) so the default remains broadly compatible.

# Convert bytes to human-readable (decimal units)
human_readable() {
    local bytes=${1:-0}
    local KB=1000
    local MB=$((KB * KB))
    local GB=$((MB * KB))
    local TB=$((GB * KB))
    if [ "$bytes" -lt "$KB" ]; then
        printf "%d B" "$bytes"
    elif [ "$bytes" -lt "$MB" ]; then
        awk "BEGIN{printf \"%.2f KB\", $bytes/$KB}"
    elif [ "$bytes" -lt "$GB" ]; then
        awk "BEGIN{printf \"%.2f MB\", $bytes/$MB}"
    elif [ "$bytes" -lt "$TB" ]; then
        awk "BEGIN{printf \"%.2f GB\", $bytes/$GB}"
    else
        awk "BEGIN{printf \"%.2f TB\", $bytes/$TB}"
    fi
}

# Helper: map percentage to code (0=ok,1=near,2=exceed)
classify_pct() {
    awk -v a="$1" -v p="$THRESHOLD" -v d="$NEAR_THRESHOLD_DELTA" 'BEGIN{if(a>p) print 2; else if(a + d >= p) print 1; else print 0}'
}

# Map code to emoji
map_emoji() {
    case "$1" in
        2) printf "🔴" ;; 
        1) printf "🟡" ;; 
        *) printf "🟢" ;;
    esac
}

# Simple logger to stdout with timestamp
log() {
    # write logs to stderr so that callers which capture stdout (e.g. sm=$(...))
    # don't swallow diagnostic messages
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# Find the block device(s) backing a mountpoint. Returns space-separated device paths.
get_block_devices_from_mount() {
    local mount=$1
    # Try findmnt to get source(s)
    local src
    if command -v findmnt >/dev/null 2>&1; then
        src=$(findmnt -n -o SOURCE --target "$mount" 2>/dev/null || true)
    else
        src=$(df --output=source "$mount" 2>/dev/null | tail -n1 || true)
    fi
    [ -z "$src" ] && return 0
    # If it's a device mapper or md device, resolve underlying devices using lsblk
    if command -v lsblk >/dev/null 2>&1; then
        # lsblk -no PKNAME/NAME to walk to physical devices
        # Example: /dev/md0 -> /dev/sda /dev/sdb
        # Use lsblk --json for robust parsing when available
        if lsblk --json >/dev/null 2>&1; then
            # get the top-level block device name (strip /dev/)
            top=$(basename "$src")
            # find all leaf devices under this top device
            mapfile -t leaves < <(lsblk -ln -o NAME,TYPE "/dev/$top" 2>/dev/null | awk '$2=="disk"{print $1}');
            if [ ${#leaves[@]} -gt 0 ]; then
                for l in "${leaves[@]}"; do printf "/dev/%s\n" "$l"; done
                return 0
            fi
        fi
        # Fallback: lsblk -P to resolve children
        if lsblk -P "$src" >/dev/null 2>&1; then
            lsblk -P -o NAME,TYPE -n "$src" 2>/dev/null | awk -F'"' '/NAME=/{name=$2} /TYPE=/{type=$4; if(type=="disk") print "/dev/"name}' || true
            return 0
        fi
    fi
    # Last fallback: print the source as-is
    printf "%s\n" "$src"
}

# NOTE: hdparm-style per-device spin logic removed. The script now relies on the
# conservative tiny-read spin in check_disk_smart() which was copied from the
# validated `disk_health.sh` implementation. If you need controller-specific
# hdparm/sg_start behaviour re-add a guarded helper and enable it via a
# config flag (USE_HDPARM=YES).

# Return space-separated list of physical slave devices for an md device name
# Tries (in order): /sys/block/<md>/slaves, lsblk child disks, /proc/mdstat parsing
get_md_slaves() {
    local mdname=$1
    local slaves=()
    # 1) sysfs
    if [ -d "/sys/block/$mdname/slaves" ]; then
        for s in /sys/block/$mdname/slaves/*; do
            [ -e "$s" ] || continue
            slaves+=("/dev/$(basename "$s")")
        done
        if [ ${#slaves[@]} -gt 0 ]; then printf "%s\n" "${slaves[@]}"; return 0; fi
    fi

    # 2) lsblk children (disk/part)
    if command -v lsblk >/dev/null 2>&1; then
        mapfile -t ll < <(lsblk -ln -o NAME,TYPE "/dev/$mdname" 2>/dev/null | awk '$2=="disk" || $2=="part" {print "/dev/"$1}') || true
        if [ ${#ll[@]} -gt 0 ]; then printf "%s\n" "${ll[@]}"; return 0; fi
    fi

    # 3) /proc/mdstat parsing fallback (handle Unraid key=value style)
    if [ -r /proc/mdstat ]; then
        # try matching both the provided name and its partition-stripped form
        md_alt=$(echo "$mdname" | sed -E 's/p[0-9]+$//')
        # read /proc/mdstat lines and collect diskName.N entries
        while IFS= read -r line; do
            # look for diskName.N=<name>
            if echo "$line" | grep -qE '^diskName\.[0-9]+=.*'; then
                idx=$(echo "$line" | awk -F'[.=]' '{print $1}' | sed -E 's/diskName\.//'; )
                # extract name after =
                name=$(echo "$line" | awk -F= '{print $2}' | tr -d '\r' | tr -d ' ')
                if [ "$name" = "$mdname" ] || [ "$name" = "$md_alt" ]; then
                    # find corresponding rdevName.N line
                    rline=$(grep -E "^rdevName\.${idx}=" /proc/mdstat 2>/dev/null || true)
                    if [ -n "$rline" ]; then
                        rval=$(echo "$rline" | awk -F= '{print $2}' | tr -d '\r' | tr -d ' ')
                        # strip partition numbers
                        rval_base=$(echo "$rval" | sed -E 's/[0-9]+$//')
                        slaves+=("/dev/$rval_base")
                    fi
                fi
            fi
        done < /proc/mdstat
        if [ ${#slaves[@]} -gt 0 ]; then printf "%s\n" "${slaves[@]}"; return 0; fi
    fi
    return 1
}

# Internal helper: check a resolved physical device node (e.g. /dev/sda)
_check_disk_smart_dev() {
    local devnode="$1"
    local out

    log "_check_disk_smart_dev: starting checks for $devnode"

    # If smartctl missing, bail
    if [ ! -x "$SMARTCTL_CMD" ]; then
        SMARTCTL_CMD=$(command -v smartctl || true)
    fi
    if [ -z "$SMARTCTL_CMD" ] || [ ! -x "$SMARTCTL_CMD" ]; then
        log "_check_disk_smart_dev: smartctl not found ($SMARTCTL_CMD)"
        printf "FAILED: SMART_TOOL_MISSING"
        return 2
    fi

    # If device is indicated to be in standby, perform tiny harmless reads to spin it
    # and verify it actually left standby. Retry a few times before giving up.
    if "$SMARTCTL_CMD" -n standby "$devnode" >/dev/null 2>&1; then
        log "_check_disk_smart_dev: $devnode in standby, attempting gentle spin via dd (retries=${SPINUP_RETRIES})"
        for attempt in $(seq 1 $SPINUP_RETRIES); do
            log "_check_disk_smart_dev: $devnode spin attempt $attempt"
            dd if="$devnode" of=/dev/null bs=1 count=1 >/dev/null 2>&1 || true
            sleep $SPINUP_SLEEP
            if ! "$SMARTCTL_CMD" -n standby "$devnode" >/dev/null 2>&1; then
                log "_check_disk_smart_dev: $devnode left standby on attempt $attempt"
                break
            else
                log "_check_disk_smart_dev: $devnode still in standby after attempt $attempt"
            fi
        done
    fi

    # Ensure dump directory exists for diagnostics
    mkdir -p "$SMART_DUMP_DIR" 2>/dev/null || true
    local ts safe_name dumpfile
    ts=$(date +%Y%m%dT%H%M%S)
    safe_name=$(basename "$devnode" | sed 's/[^a-zA-Z0-9._-]/_/g')
    dumpfile="$SMART_DUMP_DIR/${safe_name}_${ts}.smartctl.log"

    # Run smartctl and capture both stdout and stderr to the dumpfile for diagnostics
    log "_check_disk_smart_dev: running smartctl for $devnode, dumpfile=$dumpfile"
    if ! $SMARTCTL_CMD -A -d sat "$devnode" >"$dumpfile" 2>&1; then
        log "_check_disk_smart_dev: sat transport failed for $devnode, trying auto transport (appending to $dumpfile)"
        $SMARTCTL_CMD -A -d auto "$devnode" >>"$dumpfile" 2>&1 || true
    fi
    out=$(cat "$dumpfile" 2>/dev/null || true)
    if [ -z "$out" ]; then
        log "_check_disk_smart_dev: smartctl produced no output for $devnode; dump=$dumpfile"
        printf "FAILED: SMART_UNREADABLE"
        return 1
    fi
    log "_check_disk_smart_dev: smartctl output captured for $devnode (dump=$dumpfile, length=$(printf "%s" "$out" | wc -c))"

    # Parse key attributes
    local reallocated pending crc temp
    reallocated=$(printf "%s" "$out" | awk 'tolower($0) ~ /reallocated_sector/ {print $NF; exit}' || true)
    pending=$(printf "%s" "$out" | awk 'tolower($0) ~ /current_pending_sector/ {print $NF; exit}' || true)
    crc=$(printf "%s" "$out" | awk 'tolower($0) ~ /udma_crc|udma_crc_error_count/ {print $NF; exit}' || true)
    temp=$(printf "%s" "$out" | awk 'tolower($0) ~ /temperature_celsius|temperature/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' | head -n1 || true)

    reallocated=${reallocated:-0}
    pending=${pending:-0}
    crc=${crc:-0}
    temp=${temp:-N/A}
    log "_check_disk_smart_dev: parsed $devnode -> Reallocated=$reallocated Pending=$pending CRC=$crc TEMP=$temp"

    if [ "$reallocated" -eq 0 ] && [ "$pending" -eq 0 ] && [ "$crc" -eq 0 ]; then
        if [ "$temp" = "N/A" ]; then
            printf "PASSED"
        else
            printf "PASSED;TEMP=%s" "$temp"
        fi
        return 0
    else
        printf "FAILED: Reallocated=%s Pending=%s CRC=%s Temp=%s SelfTest='N/A'" "$reallocated" "$pending" "$crc" "$temp"
        return 1
    fi
}


# SMART check wrapper: expand md parents to physical slaves and call helper
check_disk_smart() {
    local dev=$1
    local devnode
    devnode=$(readlink -f "$dev" 2>/dev/null || echo "$dev")
    if [ -z "$devnode" ]; then
        log "check_disk_smart: FAILED to resolve device for '$dev'"
        printf "FAILED: CANNOT_RESOLVE_DEVICE"
        return 2
    fi
    log "check_disk_smart: resolved $dev -> $devnode"

    # If this device is an md parent, try to resolve the physical slaves and run checks
    local mdname
    mdname=$(basename "$devnode")
    mapfile -t mdslaves < <(get_md_slaves "$mdname" 2>/dev/null || true)
    if [ ${#mdslaves[@]} -gt 0 ]; then
        local health_status=0
        local desc=""
        local temp="N/A"
        for slave_dev in "${mdslaves[@]}"; do
            [ -n "$slave_dev" ] || continue
            log "check_disk_smart: md parent $devnode -> member $slave_dev"
            sm=$(_check_disk_smart_dev "$slave_dev" ) || true
            desc+="$slave_dev:$sm; "
            s_temp=$(echo "$sm" | sed -n 's/.*TEMP=\([0-9]*\).*/\1/p' || true)
            if [ -n "$s_temp" ]; then temp="$s_temp"; fi
            if echo "$sm" | grep -qi "FAILED"; then health_status=1; fi
        done
        if [ $health_status -eq 0 ]; then
            if [ "$temp" = "N/A" ]; then printf "%s" "PASSED"; else printf "PASSED;TEMP=%s" "$temp"; fi
            return 0
        else
            printf "%s" "FAILED: MEMBERS=%s" "$desc"
            return 1
        fi
    fi
    # No md slaves discovered; operate on the device itself
    log "check_disk_smart: invoking _check_disk_smart_dev on $devnode"
    _check_disk_smart_dev "$devnode"
    return $?
}

# Check NVMe attributes (wear, thermal throttle, media errors)
check_nvme_health() {
    local dev=$1
    # nvme-cli is not assumed available on Unraid; use smartctl -d nvme
    # Assume smartctl is present on Unraid and use it for NVMe
    local out
    out=$($SMARTCTL_CMD -a -d nvme "$dev" 2>/dev/null || true)
    local wear=$(echo "$out" | awk -F: '/Percentage Used/ {gsub(/ /, "", $2); print $2; exit}')
    local throttle=$(echo "$out" | awk -F: '/thermal throttling|throttle/ {gsub(/ /, "", $2); print $2; exit}')
    local media_errs=$(echo "$out" | awk -F: '/media_errors/ {gsub(/ /, "", $2); print $2; exit}')
    local temp=$(echo "$out" | grep -iE 'temperature|temp' | grep -oE '[0-9]{1,3}' | head -n1 || true)
    log "check_nvme_health: $dev -> WEAR=${wear:-N/A} THROTTLE=${throttle:-0} MEDIA_ERRS=${media_errs:-0} TEMP=${temp:-N/A}"
    printf "WEAR=%s THROTTLE=%s MEDIA_ERRS=%s TEMP=%s" "${wear:-N/A}" "${throttle:-0}" "${media_errs:-0}" "${temp:-N/A}"
    return 0
}

# Quick XFS check (no repair): run xfs_repair -n on device
check_xfs_quick() {
    local dev=$1
    if [ ! -x "$XFS_CHECK_CMD" ]; then
        log "check_xfs_quick: XFS tool missing for $dev"
        printf "XFS_TOOL_MISSING"
        return 2
    fi
    # xfs_repair -n returns 0 when no errors found (and non-zero otherwise)
    if $XFS_CHECK_CMD -n "$dev" >/dev/null 2>&1; then
        log "check_xfs_quick: $dev -> PASSED"
        printf "PASSED"
        return 0
    else
        log "check_xfs_quick: $dev -> FAILED"
        printf "FAILED"
        return 1
    fi
}

# Check btrfs filesystem quick status: run scrub status and device status
check_btrfs_pool() {
    local mount=$1
    if [ ! -x "$BTRFS_CMD" ]; then
        log "check_btrfs_pool: btrfs tool missing for $mount"
        printf "BTRFS_TOOL_MISSING"
        return 2
    fi
    # Check scrub status
    local scrub=$($BTRFS_CMD scrub status "$mount" 2>/dev/null || true)
    local scrub_errors=0
    if echo "$scrub" | grep -iq "errors"; then
        # parse errors line like "errors: 0" or "read errors: 0"; conservative: any non-zero
        scrub_errors=$(echo "$scrub" | awk -F: '/errors/ {gsub(/ /, "", $2); print $2; exit}' || echo 0)
    fi
    # Detect RAID profile and devices: use 'btrfs filesystem show'
    local show=$($BTRFS_CMD filesystem show "$mount" 2>/dev/null || true)
    local profile="unknown"
    if echo "$show" | grep -qi "Data, single"; then profile="single"; fi
    if echo "$show" | grep -qi "Data, raid1"; then profile="raid1"; fi

    # Extract device paths listed by btrfs (look for 'Device ... path /dev/...')
    mapfile -t expected_devs < <(echo "$show" | awk '/devid/ {for(i=1;i<=NF;i++) if($i ~ /^\/dev\//) print $i}' | sort -u)

    # Build list of present block devices (from /proc/partitions basename)
    mapfile -t present_devs < <(lsblk -ln -o NAME -d 2>/dev/null | awk '{print "/dev/"$1}')

    # Compare expected vs present to find missing devices
    missing=()
    for ed in "${expected_devs[@]}"; do
        # normalize (some entries may be device names without /dev/)
        e=$(echo "$ed" | sed -e 's,^/dev/,/dev/,')
        found=0
        for pd in "${present_devs[@]}"; do
            if [ "$pd" = "$e" ]; then found=1; break; fi
        done
        if [ $found -eq 0 ]; then missing+=("$e"); fi
    done

    # Btrfs degraded detection: check mount output or explicit missing devices
    local degraded=0
    if mount | grep " $mount " | grep -qi degraded; then degraded=1; fi
    if [ ${#missing[@]} -gt 0 ]; then degraded=1; fi

    if [ "$profile" = "raid1" ] && [ "$degraded" -eq 1 ]; then
        local miss_str="${missing[*]:-none}"
        log "check_btrfs_pool: RAID1 degraded on $mount; missing devices: $miss_str"
        printf "FAILED: RAID1_DEGRADED MISSING=%s" "$miss_str"
        return 1
    fi
    # For our purposes, treat scrub_errors>0 as FAILED
    if [ -n "$scrub_errors" ] && [ "$scrub_errors" -gt 0 ] 2>/dev/null; then
        log "check_btrfs_pool: $mount -> SCRUB_ERRORS=$scrub_errors"
        printf "FAILED: SCRUB_ERRORS=%s" "$scrub_errors"
        return 1
    fi
    log "check_btrfs_pool: $mount -> PASSED"
    printf "PASSED"
    return 0
}

process_group() {
    local group_name=$1; shift
    local paths=("$@")
    local used=0 free=0 size_total=0
    local details=""

    for path in "${paths[@]}"; do
        if mountpoint -q "$path"; then
            local line size u a percent
            line=$(df -B1 "$path" 2>/dev/null | awk 'NR==2') || continue
            size=$(echo "$line" | awk '{print $2}')
            u=$(echo "$line" | awk '{print $3}')
            a=$(echo "$line" | awk '{print $4}')
            size=${size:-0}; u=${u:-0}; a=${a:-0}
            used=$((used + u))
            free=$((free + a))
            size_total=$((size_total + size))
            percent=$(awk "BEGIN {printf \"%.1f\", ($u/$size)*100}")
            details+=$(printf "%-10s %10s / %-10s used (%5s%%)\n" "$(basename "$path")" "$(human_readable $u)" "$(human_readable $size)" "$percent")
            details+=$'\n'
        fi
    done

    if [ "$size_total" -eq 0 ]; then
        printf "[%s Summary]\nNo mounted disks found.\n" "$group_name"
        return
    fi

    local total_used_h=$(human_readable $used)
    local total_free_h=$(human_readable $free)
    local total_size_h=$(human_readable $size_total)
    local percent_total=$(awk "BEGIN {printf \"%.1f\", ($used/$size_total)*100}")

    printf "[%s Summary]\nTotal: %s\nUsed: %s (%s%%)\nFree: %s\n\n%s" \
        "$group_name" "$total_size_h" "$total_used_h" "$percent_total" "$total_free_h" "$details"
}

# Discover arrays and pools
array_disks=(/mnt/disk*)

log "Starting storage_report: building array and pool reports"

# Build array report with health checks per disk
array_report_lines=()
array_total_b=0; array_used_b=0; array_count=0
array_health_failures=()
for d in "${array_disks[@]}"; do
    [ -d "$d" ] || continue
    if mountpoint -q "$d"; then
        array_count=$((array_count+1))
        # get df data
        line=$(df -B1 "$d" 2>/dev/null | awk 'NR==2') || continue
        size=$(echo "$line" | awk '{print $2}'); u=$(echo "$line" | awk '{print $3}')
        size=${size:-0}; u=${u:-0}
        array_total_b=$((array_total_b + size))
        array_used_b=$((array_used_b + u))

        # Determine backing device(s); fall back to df source when resolution fails
        devs=$(get_block_devices_from_mount "$d" )
        if [ -z "$devs" ]; then
            devs=$(df --output=source "$d" 2>/dev/null | tail -n1 || true)
        fi
        # Default health values
        health_status="PASSED"
        health_desc=""
        temp="N/A"
        # Iterate devices backing the mount and aggregate health
        # iterate robustly over possibly multi-line device list
        while IFS= read -r dev; do
            # strip partition number for smart where necessary (eg /dev/sda1 -> /dev/sda)
            base_dev=$(echo "$dev" | sed -E 's/p?[0-9]+$//')
            # Try nvme vs sata
            if echo "$base_dev" | grep -qi "nvme"; then
                nvmeh=$(check_nvme_health "$base_dev" ) || true
                # Extract wear/throttle/media
                health_desc+="$nvmeh; "
                # parse throttle count and temp
                thr=$(echo "$nvmeh" | awk -F' ' '/THROTTLE/ {for(i=1;i<=NF;i++) if($i ~ /THROTTLE=/) {split($i,a,"="); print a[2]}}' | tr -d '[:space:]')
                ntemp=$(echo "$nvmeh" | awk -F' ' '/TEMP/ {for(i=1;i<=NF;i++) if($i ~ /TEMP=/) {split($i,a,"="); print a[2]}}')
                if [ -n "$ntemp" ]; then temp="$ntemp"; fi
                if [ -n "$thr" ] && [ "$thr" != "0" ] && [ "$thr" != "N/A" ]; then
                    health_status="FAILED"
                fi
            else
                # If this resolves to an md device, run SMART against the underlying
                # physical slaves (/dev/sdX) instead of the md parent device.
                if echo "$base_dev" | grep -Eq '^/dev/md[0-9]+' ; then
                    mdname=$(basename "$base_dev")
                    mapfile -t mdslaves < <(get_md_slaves "$mdname" 2>/dev/null || true)
                    if [ ${#mdslaves[@]} -gt 0 ]; then
                        for slave_dev in "${mdslaves[@]}"; do
                            [ -n "$slave_dev" ] || continue
                            log "array: running SMART on md member $slave_dev (parent $mdname)"
                            sm=$(check_disk_smart "$slave_dev" ) || true
                            health_desc+="$slave_dev:$sm; "
                            # update temp if provided
                            s_temp=$(echo "$sm" | sed -n 's/.*TEMP=\([0-9]*\).*/\1/p') || true
                            if [ -n "$s_temp" ]; then temp="$s_temp"; fi
                            if echo "$sm" | grep -qi "FAILED"; then health_status="FAILED"; fi
                        done
                    fi
                else
                    # Rely on the tested check_disk_smart() gentle-read spin instead
                    # of hdparm-based wake logic for broader HBA compatibility.
                    sm=$(check_disk_smart "$base_dev" ) || true
                    if echo "$sm" | grep -qi "PASSED"; then
                        health_desc+="SMART=PASSED; "
                        # extract TEMP if provided by helper
                        s_temp=$(echo "$sm" | sed -n 's/.*TEMP=\([0-9]*\).*/\1/p') || true
                        if [ -n "$s_temp" ]; then temp="$s_temp"; fi
                    else
                        health_desc+="$sm; "
                        # extract temp from failed output too
                        s_temp=$(echo "$sm" | sed -n "s/.*Temp=\([0-9]*\).*/\1/p") || true
                        if [ -n "$s_temp" ]; then temp="$s_temp"; fi
                        health_status="FAILED"
                    fi
                fi
            fi
    done <<< "$devs"

        # Storage percent
        percent=$(awk "BEGIN {printf \"%.1f\", ($u/$size)*100}")
        # Compact single-line per disk: HEALTH | TEMP | STORAGE
        if [ "$health_status" = "PASSED" ]; then
            health_icon="✅"
            # prefer concise health_info
            if echo "$health_desc" | grep -qi "SMART=PASSED"; then
                health_info="SMART PASSED"
            else
                health_info=$(echo "$health_desc" | sed 's/; */, /g' | sed 's/ $//')
            fi
        else
            health_icon="⛔"
            health_info=$(echo "$health_desc" | sed 's/; */, /g' | sed 's/ $//')
            array_health_failures+=("$(basename "$d") - $health_info")
        fi
        array_report_lines+=("$(basename "$d")   $health_icon $health_info  Temp:${temp:-N/A}  —  $(human_readable $u) / $(human_readable $size) (${percent}%)")
    # no extra blank line; compact one-line per disk
    fi
done

# Compute overall percent for array
if [ "$array_total_b" -eq 0 ]; then
    array_percent=0
else
    array_percent=$(awk "BEGIN {printf \"%.1f\", ($array_used_b/$array_total_b)*100}")
fi
array_report=$(printf "[Array Summary]\nTotal: %s\nUsed: %s (%s%%)\nFree: %s\n\n" "$(human_readable $array_total_b)" "$(human_readable $array_used_b)" "$array_percent" "$(human_readable $((array_total_b - array_used_b)))")
for l in "${array_report_lines[@]}"; do
    array_report+=$'\n'"$l"
done
array_report+=$'\n'

pool_mounts=()
for m in /mnt/*; do
    [ -d "$m" ] || continue
    name=$(basename "$m")
    case "$name" in disk*|user) continue ;; esac
    if is_excluded "$m"; then continue; fi
    if mountpoint -q "$m"; then pool_mounts+=("$m"); fi
done
if [ "${#pool_mounts[@]}" -eq 0 ]; then
    # Fallback set; filter any excludes
    fallback=(/mnt/cache* /mnt/data)
    pool_mounts=()
    for f in "${fallback[@]}"; do
        if is_excluded "$f"; then continue; fi
        pool_mounts+=("$f")
    done
fi

# Build pool report with health checks
cache_report=""
pool_total_b=0; pool_used_b=0; pool_count=0
pool_health_failures=()
pool_report_lines=()
for p in "${pool_mounts[@]}"; do
    [ -d "$p" ] || continue
    if mountpoint -q "$p"; then
        pool_count=$((pool_count+1))
        line=$(df -B1 "$p" 2>/dev/null | awk 'NR==2') || continue
        size=$(echo "$line" | awk '{print $2}'); u=$(echo "$line" | awk '{print $3}')
        size=${size:-0}; u=${u:-0}
        pool_total_b=$((pool_total_b + size))
        pool_used_b=$((pool_used_b + u))

        # Run btrfs or xfs quick checks
        fs_type=$(stat -f -c %T "$p" 2>/dev/null || true)
        if echo "$fs_type" | grep -qi "btrfs" || mount | grep " $p " | grep -qi btrfs; then
            health_out=$(check_btrfs_pool "$p" ) || true
            if echo "$health_out" | grep -qi "PASSED"; then
                    pool_icon="✅"
                    pool_info="FS: btrfs PASSED"
                else
                    pool_icon="⛔"
                    pool_info=$(echo "$health_out" | sed 's/FAILED: *//')
                    pool_health_failures+=("$(basename "$p") - $pool_info")
                fi
        else
            # Assume XFS or other: quick xfs check by device(s)
            devs=$(get_block_devices_from_mount "$p")
            xfail=0; xdesc=""
            for dev in $devs; do
                base_dev=$(echo "$dev" | sed -E 's/p?[0-9]+$//')
                xout=$(check_xfs_quick "$base_dev" ) || true
                if echo "$xout" | grep -qi "FAILED"; then
                    xfail=1
                    xdesc+="$base_dev:$xout; "
                fi
            done
            if [ $xfail -eq 1 ]; then
                pool_icon="⛔"
                pool_info="$xdesc"
                pool_health_failures+=("$(basename "$p") - $xdesc")
            else
                pool_icon="✅"
                pool_info="FS: xfs PASSED"
            fi
        fi
        percent=$(awk "BEGIN {printf \"%.1f\", ($u/$size)*100}")
    pool_report_lines+=("$(basename "$p")   $pool_icon $pool_info — $(human_readable $u) / $(human_readable $size) used (${percent}%)")
    fi
done

# Compute overall percent for pools
if [ "$pool_total_b" -eq 0 ]; then
    pool_percent=0
else
    pool_percent=$(awk "BEGIN {printf \"%.1f\", ($pool_used_b/$pool_total_b)*100}")
fi

cache_report=$(printf "[Pools Summary]\nTotal: %s\nUsed: %s (%s%%)\nFree: %s\n\n" "$(human_readable $pool_total_b)" "$(human_readable $pool_used_b)" "$pool_percent" "$(human_readable $((pool_total_b - pool_used_b)))")
for l in "${pool_report_lines[@]}"; do
    cache_report+=$'\n'"$l"
done
cache_report+=$'\n'

# Byte totals are computed earlier alongside report generation
# Standard notification
array_total_h=$(human_readable $array_total_b)
array_used_h=$(human_readable $array_used_b)
pool_total_h=$(human_readable $pool_total_b)
pool_used_h=$(human_readable $pool_used_b)

array_code=$(classify_pct "$array_percent")
pool_code=$(classify_pct "$pool_percent")
array_status_emoji=$(map_emoji "$array_code")
pool_status_emoji=$(map_emoji "$pool_code")
array_icon="🗄️"
pool_icon="⚡"
if [ "$array_code" -eq 2 ] || [ "$pool_code" -eq 2 ]; then overall_code=2
elif [ "$array_code" -eq 1 ] || [ "$pool_code" -eq 1 ]; then overall_code=1
else overall_code=0; fi
status_emoji=$(map_emoji "$overall_code")
array_report=$(printf '%s' "$array_report" | sed "0,/^\[Array Summary\]/s//${array_icon} [Array Summary]/")
cache_report=$(printf '%s' "$cache_report" | sed "0,/^\[Pools Summary\]/s//${pool_icon} [Pools Summary]/")

summary=$(printf "%s Array (%d): %s%% — %s used of %s\n%s Pools (%d): %s%% — %s used of %s" \
    "$array_status_emoji" "$array_count" "$array_percent" "$array_used_h" "$array_total_h" \
    "$pool_status_emoji" "$pool_count" "$pool_percent" "$pool_used_h" "$pool_total_h")
description=$(printf "\n%s\n\n--------------------------------------------------\n%s\n--------------------------------------------------\n%s" "$summary" "$array_report" "$cache_report")

subject_metric=$(printf "%s Array: %s%% | Pools: %s%%" "$status_emoji" "$array_percent" "$pool_percent")

log "Sending standard notification: $subject_metric"
/usr/local/emhttp/webGui/scripts/notify \
    -e "Disk Health & Storage" \
    -s "$subject_metric" \
    -i "normal" \
    -d "$description"

# Consolidated alert notification(s)
exceed_array=0; exceed_pool=0
if awk -v p="$array_percent" -v t="$THRESHOLD" 'BEGIN{exit (p>t)?0:1}'; then exceed_array=1; fi
if awk -v p="$pool_percent" -v t="$THRESHOLD" 'BEGIN{exit (p>t)?0:1}'; then exceed_pool=1; fi

if [ "$exceed_array" -eq 1 ] || [ "$exceed_pool" -eq 1 ]; then
    alert_subject="⚠️ Storage threshold exceeded"
    alert_body=""
    if [ "$exceed_array" -eq 1 ]; then
    over_pct=$(awk -v p="$array_percent" -v t="$THRESHOLD" 'BEGIN{printf "%.1f", p - t}')
    over_bytes=$(awk -v used=$array_used_b -v tot=$array_total_b -v t=$THRESHOLD 'BEGIN{ex=used - (t/100)*tot; if(ex<0) ex=0; printf "%d", ex}')
        alert_body+=$(printf "[Array]\nTotal: %s\nUsed: %s (%s%%)\nFree: %s\nExceeded by: %s%% (~%s)\n\n" \
            "$array_total_h" "$array_used_h" "$array_percent" "$(human_readable $((array_total_b - array_used_b)))" "$over_pct" "$(human_readable $over_bytes)")
        alert_body+="$array_report\n"
    fi
    if [ "$exceed_pool" -eq 1 ]; then
    over_pct_p=$(awk -v p="$pool_percent" -v t="$THRESHOLD" 'BEGIN{printf "%.1f", p - t}')
    over_bytes_p=$(awk -v used=$pool_used_b -v tot=$pool_total_b -v t=$THRESHOLD 'BEGIN{ex=used - (t/100)*tot; if(ex<0) ex=0; printf "%d", ex}')
        alert_body+=$(printf "[Pools]\nTotal: %s\nUsed: %s (%s%%)\nFree: %s\nExceeded by: %s%% (~%s)\n\n" \
            "$pool_total_h" "$pool_used_h" "$pool_percent" "$(human_readable $((pool_total_b - pool_used_b)))" "$over_pct_p" "$(human_readable $over_bytes_p)")
        alert_body+="$cache_report\n"
    fi
    # Append health failure summaries if any
    if [ ${#array_health_failures[@]} -gt 0 ]; then
        alert_body+=$'\n⛔ Health [FAILED] reason:\n'
        for f in "${array_health_failures[@]}"; do
            alert_body+="$f\n"
        done
    fi
    if [ ${#pool_health_failures[@]} -gt 0 ]; then
        alert_body+=$'\n⛔ Pool Health [FAILED] reason:\n'
        for f in "${pool_health_failures[@]}"; do
            alert_body+="$f\n"
        done
    fi
    /usr/local/emhttp/webGui/scripts/notify \
        -e "⚠️ Unraid Storage Alert" \
        -s "$alert_subject" \
        -d "$alert_body" \
        -i "alert"
fi

exit 0