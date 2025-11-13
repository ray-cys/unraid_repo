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
description=$(printf "\n%s\n\n--------------------------------------------------\n%s\n--------------------------------------------------\n%s" "$summary" "$array_report" "$cache_report")

subject_metric=$(printf "%s Array: %s%% | Pools: %s%%" "$status_emoji" "$array_percent" "$pool_percent")

/usr/local/emhttp/webGui/scripts/notify \
    -e "💾 Unraid Storage Report" \
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
