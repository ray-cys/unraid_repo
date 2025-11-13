#!/bin/bash
set -euo pipefail
LOCKFILE="/tmp/storage_report.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Another storage_report.sh run is active, exiting (lock: $LOCKFILE)"
  exit 1
fi

noParity=true
clearLog=false

# --------------------------------------------------------------------------------
# SETTINGS

threshold=90
pool_excludes=("ramtmp" "user0")
SMART_DEBUG=${SMART_DEBUG:-0}
SMART_FORCE_TRANSPORT=${SMART_FORCE_TRANSPORT:-}
SPINUP_RETRIES=${SPINUP_RETRIES:-3}
SPINUP_SLEEP=${SPINUP_SLEEP:-6}
SMART_DUMP_DIR=${SMART_DUMP_DIR:-/mnt/user/system/disk_health_smart_dumps}
SMARTCTL=${SMARTCTL:-$(command -v smartctl || true)}

# --------------------------------------------------------------------------------

# Return 0 if path should be excluded, 1 otherwise
is_excluded() {
    local path=$1
    local base
    base=$(basename "$path")
    for ex in "${pool_excludes[@]:-}"; do
        [ -z "$ex" ] && continue
        if [ "$ex" = "$path" ] || [ "$ex" = "$base" ]; then
            return 0
        fi
    done
    return 1
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

# ------------------------- Array SMART helpers -------------------------

resolve_by_id() {
    local dev=$1
    local real
    real=$(readlink -f "$dev" 2>/dev/null || true)
    [ -z "$real" ] && real="$dev"
    for id in /dev/disk/by-id/*; do
        [ -e "$id" ] || continue
        if [ "$(readlink -f "$id")" = "$real" ]; then
            printf '%s' "$id"
            return 0
        fi
    done
    printf '%s' "$dev"
}

get_md_slaves() {
    local md=$1
    local arr=()
    local name_no_part
    name_no_part=$(echo "$md" | sed -E 's/p[0-9]+$//')
    # 1) sysfs
    if [ -d "/sys/block/$name_no_part/slaves" ]; then
        for s in /sys/block/$name_no_part/slaves/*; do [ -e "$s" ] || continue; arr+=("/dev/$(basename "$s")"); done
    fi
    # 1b) sysfs md/dev-*/block symlinks
    if [ ${#arr[@]} -eq 0 ] && [ -d "/sys/block/$name_no_part/md" ]; then
        for b in /sys/block/$name_no_part/md/dev-*/block; do
            [ -e "$b" ] || continue
            blk=$(basename "$(readlink -f "$b" 2>/dev/null || echo "$b")")
            [ -n "$blk" ] && arr+=("/dev/$blk")
        done
    fi
    if [ ${#arr[@]} -gt 0 ]; then printf '%s\n' "${arr[@]}"; return 0; fi
    # 2) lsblk children
    if command -v lsblk >/dev/null 2>&1; then
        mapfile -t t < <(lsblk -ln -o NAME,TYPE "/dev/$name_no_part" 2>/dev/null | awk '$2=="disk"||$2=="part"{print "/dev/"$1}') || true
        if [ ${#t[@]} -gt 0 ]; then printf '%s\n' "${t[@]}"; return 0; fi
    fi
    # 3) /proc/mdstat Unraid-style fallback
    if [ -r /proc/mdstat ]; then
        # Find entries where diskName.N equals our md name (without partition)
        while IFS= read -r line; do
            case "$line" in
                diskName.*=*)
                    idx=$(printf '%s' "$line" | awk -F'[.=]' '{print $2}')
                    val=$(printf '%s' "$line" | awk -F= '{print $2}' | tr -d ' \r\n')
                    if [ "$val" = "$name_no_part" ]; then
                        rline=$(grep -E "^rdevName\.${idx}=" /proc/mdstat 2>/dev/null || true)
                        if [ -n "$rline" ]; then
                            rdev=$(printf '%s' "$rline" | awk -F= '{print $2}' | tr -d ' \r\n')
                            rbase=$(printf '%s' "$rdev" | sed -E 's/[0-9]+$//')
                            [ -n "$rbase" ] && arr+=("/dev/$rbase")
                        fi
                    fi
                    ;;
            esac
        done < /proc/mdstat
        if [ ${#arr[@]} -gt 0 ]; then printf '%s\n' "${arr[@]}"; return 0; fi
    fi
    return 1
}

spin_device() {
    local dev=$1
    if command -v sg_start >/dev/null 2>&1; then sg_start --start "$dev" >/dev/null 2>&1 || true; fi
    dd if="$dev" of=/dev/null bs=512 count=1 >/dev/null 2>&1 || true
}

detect_transport() {
    local dev=$1
    if [ -n "$SMART_FORCE_TRANSPORT" ]; then printf '%s' "$SMART_FORCE_TRANSPORT"; return 0; fi
    local real base tran
    real=$(readlink -f "$dev" 2>/dev/null || true)
    base=$(basename "${real:-$dev}")
    if echo "$base" | grep -qi '^nvme'; then printf 'nvme'; return 0; fi
    tran=$(lsblk -no TRAN "/dev/$base" 2>/dev/null || true)
    if printf '%s' "$tran" | grep -qiE '^sas|^scsi'; then printf 'scsi'; return 0; fi
    printf 'auto'
}

run_smart_probe() {
    local dev=$1
    mkdir -p "$SMART_DUMP_DIR" 2>/dev/null || true
    local dump="$SMART_DUMP_DIR/$(basename "$dev")_$(date +%Y%m%dT%H%M%S).smart.log"
    local t pref
    pref=$(detect_transport "$dev")
    local probes=()
    case "$pref" in
        nvme) probes=(nvme);;
        scsi) probes=(scsi ata sat auto);;
        *)    probes=(auto ata sat scsi nvme);;
    esac
    [ -n "$SMART_FORCE_TRANSPORT" ] && probes=("$SMART_FORCE_TRANSPORT")
    local out=''
    for t in "${probes[@]}"; do
        [ -z "$SMARTCTL" ] && break
        [ "${SMART_DEBUG:-0}" -eq 1 ] && printf '%s %s\n' "$(date '+%F %T')" "probe: smartctl -A -d $t $dev" >&2
        $SMARTCTL -A -d "$t" "$dev" >"$dump" 2>&1 || true
        out=$(cat "$dump" 2>/dev/null || true)
        if printf '%s' "$out" | grep -qiE 'smart|smartctl|device model|temperature|smart health'; then
            [ "${SMART_DEBUG:-0}" -eq 1 ] && printf '%s\n' "$out" | sed -n '1,60p' >&2
            printf '%s' "$out"
            return 0
        fi
    done
    printf '%s' "$out"
    return 1
}

parse_smart_metrics() {
    local text=$1
    local overall temp realloc pend crc
    overall="UNKNOWN"
    if printf '%s' "$text" | grep -qiE 'overall-health.*PASSED|SMART Health Status: *OK'; then overall="PASSED"; fi
    if printf '%s' "$text" | grep -qiE 'overall-health.*FAILED|SMART Health Status: *FAIL'; then overall="FAILED"; fi
    temp=$(printf '%s' "$text" | awk 'tolower($0) ~ /temperature_celsius|temperature:/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' | head -n1)
    realloc=$(printf '%s' "$text" | awk 'tolower($0) ~ /reallocated_sector/ {print $NF; exit}')
    pend=$(printf '%s' "$text" | awk 'tolower($0) ~ /current_pending_sector/ {print $NF; exit}')
    crc=$(printf '%s' "$text" | awk 'tolower($0) ~ /udma_crc(_error_count)?/ {print $NF; exit}')
    printf '%s|%s|%s|%s|%s' "${overall:-UNKNOWN}" "${temp:-N/A}" "${realloc:-0}" "${pend:-0}" "${crc:-0}"
}

# Discover arrays and pools
array_disks=(/mnt/disk*)
array_report=$(process_group "Array" "${array_disks[@]}") || true
array_percent=$(echo "$array_report" | grep "Used:" | head -1 | awk -F '[()%]' '{print $2}')
array_percent=${array_percent:-0}

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
cache_report=$(process_group "Pools" "${pool_mounts[@]}") || true
pool_percent=$(echo "$cache_report" | grep "Used:" | head -1 | awk -F '[()%]' '{print $2}')
pool_percent=${pool_percent:-0}

# Byte totals
array_total_b=0; array_used_b=0; array_count=0
for d in "${array_disks[@]}"; do
    [ -d "$d" ] || continue
    if mountpoint -q "$d"; then
        array_count=$((array_count+1))
        line=$(df -B1 "$d" 2>/dev/null | awk 'NR==2') || continue
        size=$(echo "$line" | awk '{print $2}'); u=$(echo "$line" | awk '{print $3}')
        size=${size:-0}; u=${u:-0}
        array_total_b=$((array_total_b + size))
        array_used_b=$((array_used_b + u))
    fi
done

pool_total_b=0; pool_used_b=0; pool_count=0
for p in "${pool_mounts[@]}"; do
    [ -d "$p" ] || continue
    if mountpoint -q "$p"; then
        pool_count=$((pool_count+1))
        line=$(df -B1 "$p" 2>/dev/null | awk 'NR==2') || continue
        size=$(echo "$line" | awk '{print $2}'); u=$(echo "$line" | awk '{print $3}')
        size=${size:-0}; u=${u:-0}
        pool_total_b=$((pool_total_b + size))
        pool_used_b=$((pool_used_b + u))
    fi
done

# Build per-disk SMART lines for array
array_health_lines=()
if [ -n "${SMARTCTL:-}" ]; then
    for d in "${array_disks[@]}"; do
        [ -d "$d" ] || continue
        mountpoint -q "$d" || continue
        # usage figures
        line=$(df -B1 "$d" 2>/dev/null | awk 'NR==2') || continue
        size=$(echo "$line" | awk '{print $2}'); u=$(echo "$line" | awk '{print $3}')
        size=${size:-0}; u=${u:-0}
        percent=$(awk "BEGIN {printf \"%.1f\", ($u/$size)*100}")
        # md source and slave devices
        src=$(findmnt -n -o SOURCE --target "$d" 2>/dev/null || true)
        mdname=$(basename "${src%p*}")
        mapfile -t slaves < <(get_md_slaves "$mdname" 2>/dev/null || true)
            if [ ${#slaves[@]} -eq 0 ]; then
                # As a safety, do not fall back to the md device; skip SMART for this disk
                echo "WARN: unable to resolve physical members for $mdname (source=$src)" >&2
                continue
            fi
        health_ok=1; reasons=(); rep_temp="N/A"
        for s in "${slaves[@]}"; do
            # Skip any md* nodes accidentally present
            if echo "$s" | grep -qE '^/dev/md'; then continue; fi
            base=$(echo "$s" | sed -E 's/p?[0-9]+$//')
            dev_pref=$(resolve_by_id "$base")
            # wake attempts
            for attempt in $(seq 1 "$SPINUP_RETRIES"); do
                if $SMARTCTL -n standby "$dev_pref" >/dev/null 2>&1; then
                    spin_device "$dev_pref"; sleep "$SPINUP_SLEEP"; continue
                fi
                break
            done
            out=$(run_smart_probe "$dev_pref" ) || true
            metrics=$(parse_smart_metrics "$out")
            IFS='|' read -r overall temp realloc pend crc <<< "$metrics"
            [ -n "$temp" ] && [ "$temp" != "N/A" ] && rep_temp="$temp"
            if [ "$overall" != "PASSED" ] || [ "${realloc:-0}" != "0" ] || [ "${pend:-0}" != "0" ] || [ "${crc:-0}" != "0" ]; then
                health_ok=0
                reasons+=("$dev_pref: overall=$overall Realloc=${realloc:-0} Pending=${pend:-0} CRC=${crc:-0}")
            fi
        done
        if [ $health_ok -eq 1 ]; then
            array_health_lines+=("$(basename "$d")   ✅ SMART PASSED  Temp:${rep_temp:-N/A} — $(human_readable $u) / $(human_readable $size) (${percent}%)")
        else
            array_health_lines+=("$(basename "$d")   ⛔ $(IFS=','; echo "${reasons[*]}")  Temp:${rep_temp:-N/A} — $(human_readable $u) / $(human_readable $size) (${percent}%)")
        fi
    done
fi

# Standard notification
array_total_h=$(human_readable $array_total_b)
array_used_h=$(human_readable $array_used_b)
pool_total_h=$(human_readable $pool_total_b)
pool_used_h=$(human_readable $pool_used_b)

near_threshold_delta=5

# Helper: notification classify a percentage relative to threshold
classify_pct() {
    awk -v a="$1" -v p="$threshold" -v d="$near_threshold_delta" 'BEGIN{if(a>p) print 2; else if(a + d >= p) print 1; else print 0}'
}

map_emoji() {
    case "$1" in
        2) printf "🔴" ;; 
        1) printf "🟡" ;; 
        *) printf "🟢" ;;
    esac
}

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
description=$(printf "\n%s\n\n--------------------------------------------------\n%s" "$summary" "$array_report")

# Append per-disk array health lines if any
if [ ${#array_health_lines[@]} -gt 0 ]; then
    description+=$'\n\n[Array Health]'
    for l in "${array_health_lines[@]}"; do description+=$'\n'"$l"; done
fi

description+=$'\n--------------------------------------------------\n'
description+="$cache_report"

subject_metric=$(printf "%s Array: %s%% | Pools: %s%%" "$status_emoji" "$array_percent" "$pool_percent")

/usr/local/emhttp/webGui/scripts/notify \
    -e "Disk Storage Report" \
    -s "$subject_metric" \
    -i "normal" \
    -d "$description"

# Consolidated alert notification(s)
exceed_array=0; exceed_pool=0
if awk -v p="$array_percent" -v t="$threshold" 'BEGIN{exit (p>t)?0:1}'; then exceed_array=1; fi
if awk -v p="$pool_percent" -v t="$threshold" 'BEGIN{exit (p>t)?0:1}'; then exceed_pool=1; fi

if [ "$exceed_array" -eq 1 ] || [ "$exceed_pool" -eq 1 ]; then
    alert_subject="⚠️ Storage threshold exceeded"
    alert_body=""
    if [ "$exceed_array" -eq 1 ]; then
        over_pct=$(awk -v p="$array_percent" -v t="$threshold" 'BEGIN{printf "%.1f", p - t}')
        over_bytes=$(awk -v used=$array_used_b -v tot=$array_total_b -v t=$threshold 'BEGIN{ex=used - (t/100)*tot; if(ex<0) ex=0; printf "%d", ex}')
        alert_body+=$(printf "[Array]\nTotal: %s\nUsed: %s (%s%%)\nFree: %s\nExceeded by: %s%% (~%s)\n\n" \
            "$array_total_h" "$array_used_h" "$array_percent" "$(human_readable $((array_total_b - array_used_b)))" "$over_pct" "$(human_readable $over_bytes)")
        alert_body+="$array_report\n"
    fi
    if [ "$exceed_pool" -eq 1 ]; then
        over_pct_p=$(awk -v p="$pool_percent" -v t="$threshold" 'BEGIN{printf "%.1f", p - t}')
        over_bytes_p=$(awk -v used=$pool_used_b -v tot=$pool_total_b -v t=$threshold 'BEGIN{ex=used - (t/100)*tot; if(ex<0) ex=0; printf "%d", ex}')
        alert_body+=$(printf "[Pools]\nTotal: %s\nUsed: %s (%s%%)\nFree: %s\nExceeded by: %s%% (~%s)\n\n" \
            "$pool_total_h" "$pool_used_h" "$pool_percent" "$(human_readable $((pool_total_b - pool_used_b)))" "$over_pct_p" "$(human_readable $over_bytes_p)")
        alert_body+="$cache_report\n"
    fi
    /usr/local/emhttp/webGui/scripts/notify \
        -e "⚠️ Unraid Storage Alert" \
        -s "$alert_subject" \
        -d "$alert_body" \
        -i "alert"
fi
