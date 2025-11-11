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

# Spin up all rotational disks sequentially using hdparm -S0 -y.
# Uses /dev/disk/by-id symlinks for a more persistent identifier when available.
spin_up_all_disks() {
    local timeout=${1:-30}
    if ! command -v hdparm >/dev/null 2>&1; then
        log "spin_up_all_disks: hdparm not available"
        return 1
    fi
    # Find all rotational disks (ROTA==1)
    mapfile -t disks < <(lsblk -dn -o NAME,ROTA | awk '$2==1 {print "/dev/"$1}')
    if [ ${#disks[@]} -eq 0 ]; then
        log "spin_up_all_disks: no rotational disks found"
        return 0
    fi
    local succ=()
    local fail=()
    for d in "${disks[@]}"; do
        # prefer a persistent by-id label for logging, but act on the real /dev/sdX
        local byid
        byid=$(ls -l /dev/disk/by-id 2>/dev/null | awk -v dev="$(basename "$d")" '$0~dev{print $9; exit}' || true)
        local label
        if [ -n "$byid" ]; then label="/dev/disk/by-id/$byid"; else label="$d"; fi
        log "spin_up_all_disks: attempting spin for $label -> $d"
        if spin_up_device "$d" "$timeout"; then
            succ+=("$label")
        else
            fail+=("$label")
        fi
        # small pause between drives to avoid overloading backplanes
        sleep 1
    done
    if [ ${#succ[@]} -gt 0 ]; then
        log "spin_up_all_disks: succeeded: ${succ[*]}"
    fi
    if [ ${#fail[@]} -gt 0 ]; then
        log "spin_up_all_disks: failed: ${fail[*]}"
    fi
    return 0
}

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
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
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

# Attempt to spin up / wake a block device so SMART can be read.
# Uses hdparm -S0 -y exclusively (user preference). Returns 0 if device appears active, non-zero otherwise.
spin_up_device() {
    local dev=$1
    local timeout=${2:-30}
    local retries=3
    local poll_interval=2

    # Special-case: spin up all rotational disks sequentially
    if [ "$dev" = "all" ]; then
        spin_up_all_disks "$timeout"
        return $?
    fi

    # Ensure we're root (hdparm requires privileges)
    if [ "$(id -u)" -ne 0 ]; then
        log "spin_up_device: WARNING: not running as root; hdparm may fail"
    fi

    # Resolve to the real block device (follow symlinks). Prefer base device (/dev/sdX)
    local real_dev
    real_dev=$(readlink -f "$dev" 2>/dev/null || true)
    if [ -z "$real_dev" ]; then real_dev="$dev"; fi
    # strip partition suffix (sda1 -> sda)
    local base_dev
    base_dev=$(basename "$real_dev")
    base_dev="/dev/$(echo "$base_dev" | sed -E 's/p?[0-9]+$//')"

    # NVMe devices don't need hdparm
    if echo "$base_dev" | grep -qi '^/dev/nvme'; then
        log "spin_up_device: $base_dev appears NVMe, no hdparm required"
        return 0
    fi

    # Find hdparm binary explicitly to avoid PATH differences
    local hdparm_cmd
    hdparm_cmd=$(command -v hdparm || echo "/sbin/hdparm")
    if [ ! -x "$hdparm_cmd" ]; then
        log "spin_up_device: hdparm not found at $hdparm_cmd"
        return 1
    fi

    # Helper: get current power state via hdparm -C
    get_powstate() {
        local out
        out=$($hdparm_cmd -C "$base_dev" 2>/dev/null || true)
        # sample output: /dev/sda:
        # drive state is:  active/idle
        echo "$out" | tr '\n' ' ' | sed -n 's/.*drive state is: *\([^ ]*\).*/\1/p' || true
    }

    local state
    state=$(get_powstate)
    if [ -n "$state" ] && echo "$state" | grep -Ei 'active|running|idle|ready|online' >/dev/null 2>&1; then
        log "spin_up_device: $base_dev already in state=$state"
        return 0
    fi

    # Attempt retries of hdparm wake and poll until timeout
    local attempt=1
    local start_ts=$(date +%s)
    while [ $attempt -le $retries ]; do
        log "spin_up_device: attempt $attempt -> $hdparm_cmd -S0 -y $base_dev"
        # capture output for debugging
        out=$($hdparm_cmd -S0 -y "$base_dev" 2>&1) || rc=$?
        rc=${rc:-$?}
        log "spin_up_device: hdparm exit=$rc output: $(echo "$out" | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ *//')"

        # After issuing wake, poll power state until active or until timeout
        local now
        now=$(date +%s)
        local elapsed=$((now - start_ts))
        while [ $elapsed -lt $timeout ]; do
            state=$(get_powstate)
            if [ -n "$state" ] && echo "$state" | grep -Ei 'active|running|idle|ready|online' >/dev/null 2>&1; then
                log "spin_up_device: $base_dev became active (state=$state) after attempt $attempt"
                return 0
            fi
            sleep $poll_interval
            now=$(date +%s)
            elapsed=$((now - start_ts))
        done

        attempt=$((attempt + 1))
        # small backoff before retry
        sleep 1
    done

    # fallback: check lsblk STATE if hdparm power state parsing failed
    state=$(lsblk -n -o STATE "$base_dev" 2>/dev/null | tr -d '[:space:]' || true)
    if [ -n "$state" ] && echo "$state" | grep -Ei 'running|active|online|ready' >/dev/null 2>&1; then
        log "spin_up_device: $base_dev appears active by lsblk (state=$state)"
        return 0
    fi

    log "spin_up_device: failed to activate $base_dev after $retries attempts and ${timeout}s poll"
    return 1
}

# SMART check for a block device. Prints summary line and returns 0 if passed, 1 if failed.
check_disk_smart() {
    local dev=$1
    local out=""
    local rc=0
    # Resolve md/mapper/lvm style top-level devices to underlying physical disks
    local targets=()
    # If device looks like md device or device mapper, try to expand
    if echo "$dev" | grep -Eq '/dev/(md|md[0-9]+|mapper|dm-)'; then
        # list children from lsblk, then map partitions to parent disks
        mapfile -t parts < <(lsblk -ln -o NAME -r "$dev" 2>/dev/null | awk '{print $1}' || true)
        for p in "${parts[@]}"; do
            # skip the top device itself
            [ "$p" = "$(basename "$dev")" ] && continue
            # Try to get parent (PKNAME) for a partition; PKNAME gives the disk name
            parent=$(lsblk -n -o PKNAME "/dev/$p" 2>/dev/null | tr -d '[:space:]' || true)
            if [ -n "$parent" ]; then
                targets+=("/dev/$parent")
            else
                # fallback: if p itself looks like a disk name (sda, nvme0n1), use it
                if echo "$p" | grep -Eq '^[a-z]+[0-9]*'; then
                    targets+=("/dev/$p")
                fi
            fi
        done
        # dedupe targets
        if [ ${#targets[@]} -gt 0 ]; then
            IFS=$'\n' read -r -d '' -a targets < <(printf "%s\n" "${targets[@]}" | awk '!x[$0]++' && printf '\0')
        fi
    fi
    if [ ${#targets[@]} -eq 0 ]; then
        targets=("$dev")
    fi
    # Probe sequence: try default, then common -d options
    local probes=("" "-d sat" "-d ata" "-d scsi")
    local probe
    local last_err=""
    local smart_bin
    smart_bin=${SMARTCTL_CMD:-$(command -v smartctl 2>/dev/null || true)}
    if [ -z "$smart_bin" ] || [ ! -x "$smart_bin" ]; then
        log "check_disk_smart: smartctl not found ($SMARTCTL_CMD)"
        printf "FAILED: SMART_TOOL_MISSING"
        return 2
    fi

    # We'll probe each physical target until we get a meaningful SMART result
    local any_passed=0
    local any_failed=0
    local combined_fail_msg=""
    for t in "${targets[@]}"; do
        for probe in "${probes[@]}"; do
            # build command
            cmd=("$smart_bin")
            if [ -n "$probe" ]; then
                for a in $probe; do cmd+=("$a"); done
            fi
            cmd+=("-H" "-i" "-A" "$t")
            out=$( "${cmd[@]}" 2>&1 ) || rc=$?
            rc=${rc:-0}
            log "check_disk_smart: target=$t probe='$probe' rc=$rc output='$(echo "$out" | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ *//')'"

            if echo "$out" | grep -qi "SMART support is: Disabled"; then
                log "check_disk_smart: SMART disabled on $t, attempting to enable"
                "$smart_bin" -s on "$t" >/dev/null 2>&1 || true
                out=$( "${cmd[@]}" 2>&1 ) || rc=$?
                rc=${rc:-0}
                log "check_disk_smart: re-probe target=$t rc=$rc output='$(echo "$out" | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ *//')'"
            fi

            if echo "$out" | grep -Eqi "SMART|SMART overall-health|SMART Health"; then
                if echo "$out" | grep -iq "PASSED"; then
                    temp=$(echo "$out" | grep -iE 'temperature|temperature_celsius|temperature_internal' | grep -oE '[0-9]{1,3}' | head -n1 || true)
                    if [ -n "$temp" ]; then
                        printf "PASSED;TEMP=%s" "$temp"
                    else
                        printf "PASSED"
                    fi
                    return 0
                else
                    # SMART present but not PASSED -> gather attributes and mark failed
                    any_failed=1
                    local reallocated=$(echo "$out" | awk '/Reallocated_Sector_Ct|Reallocated_Sector_Count/ {print $10; exit}')
                    local pending=$(echo "$out" | awk '/Current_Pending_Sector/ {print $10; exit}')
                    local crc=$(echo "$out" | awk '/UDMA_CRC_Error_Count/ {print $10; exit}')
                    local selftest=$( "$smart_bin" -c "$t" 2>/dev/null | awk '/Self-test execution status/ {print; exit}' || true)
                    local temp=$(echo "$out" | grep -iE 'temperature|temperature_celsius|temperature_internal' | grep -oE '[0-9]{1,3}' | head -n1 || true)
                    combined_fail_msg+="$t: Reallocated=${reallocated:-0} Pending=${pending:-0} CRC=${crc:-0} Temp=${temp:-N/A} SelfTest='${selftest:-N/A}'; "
                    # continue checking other targets
                    break
                fi
            fi

            last_err=$(echo "$out" | tail -n5 | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ *//')
        done
    done

    if [ $any_failed -eq 1 ]; then
        # return aggregated failure info for all physical targets
        printf "FAILED: %s" "${combined_fail_msg:-SMART_PRESENT_BUT_FAILED}"
        return 1
    fi

    # All probes failed to retrieve SMART info. Return clear failure reason.
    log "check_disk_smart: all probes failed for $dev; last_err='$last_err'"
    # sanitize last_err: replace double-quotes with single-quotes and collapse whitespace
    processed=$(echo "$last_err" | tr '"' "'" | sed -E 's/[[:space:]]+/ /g' | cut -c1-200)
    printf "FAILED: SMART_UNREADABLE (%s)" "$processed"
    return 1
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
    printf "WEAR=%s THROTTLE=%s MEDIA_ERRS=%s TEMP=%s" "${wear:-N/A}" "${throttle:-0}" "${media_errs:-0}" "${temp:-N/A}"
    return 0
}

# Quick XFS check (no repair): run xfs_repair -n on device
check_xfs_quick() {
    local dev=$1
    if [ ! -x "$XFS_CHECK_CMD" ]; then
        printf "XFS_TOOL_MISSING"
        return 2
    fi
    # xfs_repair -n returns 0 when no errors found (and non-zero otherwise)
    if $XFS_CHECK_CMD -n "$dev" >/dev/null 2>&1; then
        printf "PASSED"
        return 0
    else
        printf "FAILED"
        return 1
    fi
}

# Check btrfs filesystem quick status: run scrub status and device status
check_btrfs_pool() {
    local mount=$1
    if [ ! -x "$BTRFS_CMD" ]; then
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
        log "BTRFS RAID1 degraded on $mount; missing devices: $miss_str"
        printf "FAILED: RAID1_DEGRADED MISSING=%s" "$miss_str"
        return 1
    fi
    # For our purposes, treat scrub_errors>0 as FAILED
    if [ -n "$scrub_errors" ] && [ "$scrub_errors" -gt 0 ] 2>/dev/null; then
        printf "FAILED: SCRUB_ERRORS=%s" "$scrub_errors"
        return 1
    fi
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
                # Ensure drive is spun up/woken before reading SMART
                spin_up_device "$base_dev" 20 >/dev/null 2>&1 || true
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
                    pool_info="BTRFS PASSED"
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
                pool_info="XFS PASSED"
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
    -e "💾 Unraid Storage Report" \
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