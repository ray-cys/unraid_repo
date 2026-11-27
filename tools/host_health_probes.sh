# shellcheck shell=bash
# Fast host checks: read-only, every existing watchdog invocation. No disk tests,
# network restarts, balancing, filesystem repair, or application changes.
# Warning conditions require three samples; recoveries require two good samples.
# Unknown/unsupported results never clear a known incident. Delivery is journaled.
HH_RAM_ROOT="${HH_RAM_ROOT:-/run}"
HH_PROC_ROOT="${HH_PROC_ROOT:-/proc}"
HH_SYS_ROOT="${HH_SYS_ROOT:-/sys}"
HH_MIRROR="${HH_MIRROR:-/mnt/vault/cloud/logs/script/host_health_watchdog/host-health.json}"
HH_PENDING_BODY='' HH_PENDING_IMPORTANCE=normal HH_PREPARED=0 HH_DIRTY=0
hh_atomic() {
    local target="$1" value="$2" temp
    [[ -d "${target%/*}" && ! -L "$target" ]] || return 1
    if [[ -e "$target" ]];then [[ -f "$target" && $(stat -c %u "$target") == "$EUID" && $(stat -c %h "$target") == 1 ]] || return 1;fi
    temp=$(mktemp "${target%/*}/.host-health.XXXXXX") || return 1
    if printf '%s\n' "$value" > "$temp" && chmod 600 "$temp" && mv -f -- "$temp" "$target";then return 0;fi
    rm -f -- "$temp";return 1
}
hh_observe() {
    local id="$1" severity="$2" title="$3" detail="$4" confirmations="${5:-3}"
    HH_OBSERVATIONS=$(jq -c --arg id "$id" --arg severity "$severity" --arg title "$title" --arg detail "$detail" --argjson confirmations "$confirmations" '.+[{id:$id,severity:$severity,title:$title,detail:$detail,confirmations:$confirmations}]' <<< "$HH_OBSERVATIONS")
}
hh_usage() {
    local path="$1" numbers total avail inode_total inode_free used severity=ok
    numbers=$(timeout --kill-after=1 4 stat -f -c '%b %a %c %d' "$path" 9>&- 2>/dev/null) || { hh_observe "space:$path" unknown "Capacity $path" 'Filesystem capacity could not be read';return; }
    read -r total avail inode_total inode_free <<< "$numbers"
    [[ "$total" =~ ^[0-9]+$ && "$avail" =~ ^[0-9]+$ && "$total" -gt 0 ]] || return
    used=$((100*(total-avail)/total));((used>=90)) && severity=warning;((used>=97)) && severity=critical
    # Capacity hysteresis: do not clear a previous finding until below 85%.
    if ((used>=85 && used<90)) && jq -e --arg id "space:$path" '.conditions[$id].active==true' <<< "$HH_STATE" >/dev/null;then severity=warning;fi
    hh_observe "space:$path" "$severity" "Capacity $path" "Used ${used}%; warning 90%, critical 97%, recovery below 85%." 2
    if [[ "$inode_total" =~ ^[0-9]+$ && "$inode_total" -gt 0 && "$inode_free" =~ ^[0-9]+$ ]];then
        used=$((100*(inode_total-inode_free)/inode_total));severity=ok
        ((used>=90)) && severity=warning;((used>=97)) && severity=critical
        hh_observe "inodes:$path" "$severity" "Inodes $path" "Allocated inode use ${used}%." 3
    fi
}
hh_cpu() {
    local sensor name input label current maximum critical severity id previous found=0
    for sensor in "$HH_SYS_ROOT"/class/hwmon/hwmon*;do
        [[ -r "$sensor/name" ]] || continue;read -r name < "$sensor/name"
        case "$name" in coretemp|k10temp|zenpower) ;; *) continue;;esac
        for input in "$sensor"/temp*_input;do
            [[ -r "$input" ]] || continue;label=$(cat "${input%_input}_label" 2>/dev/null)
            case "$label" in 'Package id '*|Tctl|Tdie) ;; *) continue;;esac
            current=$(cat "$input");maximum=$(cat "${input%_input}_max" 2>/dev/null);critical=$(cat "${input%_input}_crit" 2>/dev/null)
            [[ "$current" =~ ^[0-9]+$ && "$maximum" =~ ^[0-9]+$ && "$critical" =~ ^[0-9]+$ ]] || continue
            ((maximum>0 && critical>=maximum && current<200000)) || continue
            id="cpu:$name:$label";found=1;severity=ok
            ((current>=maximum)) && severity=warning;((current>=critical)) && severity=critical
            previous=$(jq -r --arg id "$id" '.conditions[$id].active//false' <<< "$HH_STATE")
            if [[ "$severity" == ok && "$previous" == true ]] && ((current>maximum-5000));then severity=warning;fi
            hh_observe "$id" "$severity" 'CPU temperature' "$label $((current/1000))C; driver limit $((maximum/1000))C, critical $((critical/1000))C." 1
        done
    done
    ((found)) || hh_observe cpu:coverage unsupported 'CPU temperature coverage' 'No trusted package sensor with firmware limits; no guessed limit applied.'
}
hh_network() {
    local iface base carrier speed supported max_speed expected mac old previous_at delta_e delta_p errors packets severity detail flags
    # Only physical interfaces participating in an active default-route bridge,
    # bond or direct route. Excludes Docker/veth/Tailscale and unused adapters.
    local route interfaces=''
    route=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<NF;i++)if($i=="dev")print $(i+1)}' | sort -u)
    for iface in $route;do
        if [[ -d "$HH_SYS_ROOT/class/net/$iface/device" ]];then interfaces+="$iface ";fi
        for base in "$HH_SYS_ROOT/class/net/$iface/brif/"* "$HH_SYS_ROOT/class/net/$iface/lower_"*;do
            [[ -e "$base" ]] || continue
            local member;member=${base##*/};member=${member#lower_}
            if [[ -d "$HH_SYS_ROOT/class/net/$member/device" ]];then interfaces+="$member ";fi
            if [[ -r "$HH_SYS_ROOT/class/net/$member/bonding/slaves" ]];then interfaces+="$(cat "$HH_SYS_ROOT/class/net/$member/bonding/slaves") ";fi
        done
        [[ ! -r "$HH_SYS_ROOT/class/net/$iface/bonding/slaves" ]] || interfaces+="$(cat "$HH_SYS_ROOT/class/net/$iface/bonding/slaves") "
    done
    for iface in $(tr ' ' '\n' <<< "$interfaces" | sort -u);do
        base="$HH_SYS_ROOT/class/net/$iface";[[ -d "$base/device" ]] || continue
        flags=$(cat "$base/flags" 2>/dev/null);[[ "$flags" =~ ^0x[0-9a-fA-F]+$ ]] || continue
        (( (flags&1)==1 )) || continue
        carrier=$(cat "$base/carrier" 2>/dev/null);speed=$(cat "$base/speed" 2>/dev/null);mac=$(cat "$base/address")
        old=$(jq -c --arg id "$iface:$mac" '.baselines.network[$id]//{}' <<< "$HH_STATE")
        previous_at=$(jq -r '.at//0' <<< "$old");max_speed=$(jq -r '.maxSpeed//0' <<< "$old")
        [[ "$speed" =~ ^[0-9]+$ ]] || speed=0
        supported=$(timeout --kill-after=1 3 ethtool "$iface" 9>&- 2>/dev/null | sed -n '/Supported link modes:/,/Supported pause frame use:/p' | grep -oE '[0-9]+base' | sed 's/base//' | sort -nr | head -n1) || supported=''
        if [[ "$supported" =~ ^[0-9]+$ ]];then expected=$((supported<2500?supported:2500));else expected=$max_speed;fi
        severity=ok;detail="Link ${speed}Mb/s; expected at least ${expected}Mb/s."
        if [[ "$carrier" == 0 ]];then severity=critical;detail='Active LAN carrier is down.'
        elif [[ "$carrier" != 1 ]];then severity=unknown
        elif ((expected>0 && speed<expected));then severity=warning;fi
        hh_observe "network:link:$iface:$mac" "$severity" "LAN link $iface" "$detail" 2
        errors=0;packets=0
        local metric value valid=true
        for metric in rx_errors tx_errors rx_packets tx_packets;do
            value=$(cat "$base/statistics/$metric" 2>/dev/null)
            [[ "$value" =~ ^[0-9]+$ ]] || { valid=false;break; }
            case "$metric" in *_errors) errors=$((errors+value));; *) packets=$((packets+value));;esac
        done
        severity=unknown;detail='New baseline or sampling gap; lifetime counters are not treated as current errors.'
        if [[ "$valid" == true ]] && ((previous_at>0 && HH_NOW>previous_at && HH_NOW-previous_at<=1200));then
            delta_e=$((errors-$(jq -r '.errors//0' <<< "$old")));delta_p=$((packets-$(jq -r '.packets//0' <<< "$old")))
            if ((delta_e>=0 && delta_p>=0));then
                severity=ok;((delta_e>=5 && delta_e*1000>=delta_p)) && severity=warning
                detail="New RX/TX errors=$delta_e; packets=$delta_p since previous sample. Drops alone are excluded."
            fi
        fi
        hh_observe "network:errors:$iface:$mac" "$severity" "LAN errors $iface" "$detail" 3
        if [[ "$valid" == true ]];then
            ((speed>max_speed)) && max_speed=$speed
            HH_STATE=$(jq -c --arg id "$iface:$mac" --argjson at "$HH_NOW" --argjson errors "$errors" --argjson packets "$packets" --argjson speed "$max_speed" '.baselines.network[$id]={at:$at,errors:$errors,packets:$packets,maxSpeed:$speed}' <<< "$HH_STATE")
        fi
    done
}
# Optional external-observer enrollment. Read the Pi's atomic runtime state with
# the existing management SSH identity; never invoke a repair or expose mail keys.
hh_external_observer() {
    local config="${HH_EXTERNAL_OBSERVER_CONFIG:-/boot/config/plugins/user.scripts/scripts/host_health_watchdog/external-observer.json}" target installed raw now="$HH_NOW" severity=ok detail
    [[ -e "$config" ]] || return 0
    if [[ -L "$config" || $(stat -c %u "$config") != "$EUID" ]] ||
       ! jq -e '.schema==1 and (.enabled|type)=="boolean"' "$config" >/dev/null 2>&1;then
        hh_observe monitor:external-observer warning 'External observer enrollment' 'External observer configuration is unsafe or invalid; no remote command was attempted.' 3;return
    fi
    [[ $(jq -r '.enabled' "$config") == true ]] || return 0
    target=$(jq -r '.sshTarget' "$config");installed=$(jq -r '.installedAt//0' "$config")
    [[ "$target" =~ ^[a-zA-Z0-9_-]+@[0-9.]+$ && "$installed" =~ ^[0-9]+$ ]] || { hh_observe monitor:external-observer warning 'External observer enrollment' 'Enrollment target or timestamp is invalid.' 3;return; }
    if ! raw=$(timeout --kill-after=1 8 ssh -n -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ConnectTimeout=4 -o ConnectionAttempts=1 "$target" 'sudo -n /bin/cat /var/lib/hubble_availability_watchdog/state.json' 9>&- 2>/dev/null | head -c 65537) ||
       (( ${#raw}>65536 )) || ! jq -e '.schema==1 and (.lastRun.epoch|type)=="number" and (.delivery|type)=="object"' <<< "$raw" >/dev/null 2>&1;then
        severity=warning;detail='Pi observer state could not be read or validated; its execution/mail coverage is unverified. No Pi or DNS restart was attempted.'
        ((now-installed>=900)) || severity=unknown
    elif ! jq -e --argjson now "$now" '.lastRun.epoch<=$now+300 and .lastRun.epoch>=$now-600' <<< "$raw" >/dev/null;then
        severity=warning;detail='Pi observer execution is stale (over ten minutes) or its clock disagrees; inspect its cron/service. No stale result was declared current.'
    elif jq -e '(.delivery.failures//0)>0' <<< "$raw" >/dev/null;then
        severity=warning;detail='Pi observer is running but independent SMTP delivery is failing; pending outage/recovery events remain queued for retry.'
    else detail='Pi observer has a recent completed scan; no outstanding SMTP delivery failure is recorded.';fi
    hh_observe monitor:external-observer "$severity" 'External Hubble observer' "$detail" 3
}
hh_collect() {
    local path info severity type uptime available total percent emergency metrics usage show uuid member rotational all_ssd
    HH_OBSERVATIONS='[]';uptime=${HH_UPTIME:-$(cut -d. -f1 "$HH_PROC_ROOT/uptime")}
    local array_state
    array_state=$(hh_array_state)
    case "$array_state" in
      started|stopped|stopping|starting) hh_observe monitor:mount-inventory ok 'Native mount inventory' "Unraid array state=$array_state; stopped storage is intentionally excluded.";; *)
        hh_observe monitor:mount-inventory warning 'Native mount inventory unavailable' 'Unraid array state could not be read; assigned mount coverage is unverified.' 3;;esac
    while IFS= read -r path;do
        info=$(hh_mount_info "$path");severity=ok
        if [[ $(jq -r '.mounted' <<< "$info") != true ]];then
            severity=critical;((uptime<600)) && severity=unknown
        elif [[ $(jq -r '.readOnly' <<< "$info") == true ]];then severity=critical;fi
        hh_observe "mount:$path" "$severity" "Required mount $path" "Mount evidence: $info. No repair or remount attempted." 1
        [[ "$severity" == ok ]] || continue
        case "$path" in /boot|/var/lib/docker) hh_usage "$path";; /mnt/*)
            # Never poll rotating array disks for capacity or Btrfs pressure.
            [[ "$path" == /mnt/disk[0-9]* ]] && continue
            type=$(jq -r '.type' <<< "$info");[[ "$type" == btrfs ]] || continue
            uuid=$(findmnt -rn -M "$path" -o UUID);all_ssd=true
            [[ -n "$uuid" && -d "$HH_SYS_ROOT/fs/btrfs/$uuid/devices" ]] || all_ssd=false
            for member in "$HH_SYS_ROOT/fs/btrfs/$uuid/devices/"*;do
                [[ -e "$member" ]] || { all_ssd=false;break; }
                rotational=$(lsblk -ndo ROTA "/dev/${member##*/}" 2>/dev/null)
                [[ "$rotational" == 0 ]] || all_ssd=false
            done
            [[ "$all_ssd" == true ]] || continue
            usage=$(timeout --kill-after=1 5 btrfs filesystem usage -b "$path" 9>&- 2>/dev/null) || usage=''
            show=$(timeout --kill-after=1 5 btrfs filesystem show "$path" 9>&- 2>/dev/null) || show=''
            metrics=$(hh_btrfs_metrics "$usage" "$show")
            hh_observe "btrfs:$path" "$(jq -r '.severity' <<< "$metrics")" "Btrfs pool $path" "$(jq -r '"Metadata use=\((.metadataPercent//0)*10|round|./10)%; unallocated=\(.unallocatedBytes/1073741824|floor)GiB; missing device bytes=\(.missingBytes); missing members=\(.missingMembers); reserve used=\(.reserveUsedBytes)B. Metadata pressure requires low unallocated headroom. No balance or repair was attempted."' <<< "$metrics")" 2
            ;;
        esac
    done < <(hh_expected_mounts | sort -u)
    hh_usage /
    read -r total available < <(awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}END{print t+0,a+0}' "$HH_PROC_ROOT/meminfo")
    if ((total>0));then
        percent=$((100*available/total));severity=ok;((percent<10)) && severity=warning;((percent<3)) && severity=critical
        hh_observe memory "$severity" 'Available memory' "MemAvailable=${percent}% (${available}KiB of ${total}KiB); reclaimable cache is included." 2
    else hh_observe memory unknown 'Available memory' 'MemAvailable could not be read.';fi
    hh_cpu;hh_network;hh_external_observer
    emergency="$HH_RAM_ROOT/host-health-monitor-emergency.json"
    if [[ -f "$emergency" && ! -L "$emergency" ]] && jq -e --arg boot "$HH_BOOT" '.bootId==$boot and (.healthy|type)=="boolean"' "$emergency" >/dev/null 2>&1;then
        severity=$(jq -r 'if .healthy then "ok" else "critical" end' "$emergency")
        hh_observe monitor:disk-state "$severity" 'Daily disk monitor state access' "$(jq -r '.detail' "$emergency")" 1
    fi
}
hh_lifecycle() {
    # Keep delivery state separate from observations. A failed notification never
    # consumes an event. Consecutive samples must be close enough to be sustained.
    HH_STATE=$(jq -c --argjson observations "$HH_OBSERVATIONS" --argjson now "$HH_NOW" '
      .conditions //= {} | . as $root |
      reduce $observations[] as $o (. ; .conditions[$o.id] as $previous |
        ($previous//{active:false,bad:0,good:0,notifiedAt:0}) as $p |
        ($p + {title:$o.title,detail:$o.detail,lastSeen:$now}) as $c |
        (if (($p.lastSeen//0)<$now-1200) then $c+{bad:0,good:0} else $c end) as $c |
        if ($o.severity=="warning" or $o.severity=="critical") then
          ($c+{bad:($c.bad+1),good:0}) as $c |
          (if $o.severity=="critical" then $o.confirmations else 3 end) as $required |
          if $c.bad >= $required then
            .conditions[$o.id]=($c+{active:true,severity:$o.severity} |
              if ($p.active!=true or $p.severity!=$o.severity or ($now-($p.notifiedAt//0)>=86400 and ($p.pending//"")==""))
              then .pending=(if $p.active!=true then "RAISED" elif $p.severity!=$o.severity then "SEVERITY CHANGED" else "REMINDER" end) else . end)
          else .conditions[$o.id]=$c end
        elif $o.severity=="ok" then
          ($c+{bad:0,good:($c.good+1)}) as $c |
          .conditions[$o.id]=(if $p.active==true and $c.good>=2 then $c+{active:false,pending:"RECOVERED"} else $c end)
        else .conditions[$o.id]=($c+{bad:0,good:0}) end) |
      # Removed hardware is retired, never described as a proven recovery.
      .conditions |= with_entries(select(.value.lastSeen >= $now-604800)) |
      .baselines.network |= with_entries(select(.value.at >= $now-604800)) |
      .lastSampleAt=$now' <<< "$HH_STATE") || return 1
    HH_PENDING_BODY=$(jq -r '.conditions|to_entries|map(select((.value.pending//"")!=""))|.[0:24][]|"- [\(.value.pending)] \(.value.title) [\(.value.severity//"info")]\n  \(.value.detail)"' <<< "$HH_STATE")
    HH_PENDING_IMPORTANCE=$(jq -r 'if any(.conditions[];(.pending//"")!="" and .active==true and .severity=="critical") then "alert" elif any(.conditions[];(.pending//"")!="" and .active==true) then "warning" else "normal" end' <<< "$HH_STATE")
}
hh_save() {
    local receipt info mirror_at
    hh_atomic "$HH_RAM_ROOT/host-health-state.json" "$HH_STATE" || return 1
    receipt=$(jq -nc --arg boot "$HH_BOOT" --argjson now "$HH_NOW" --argjson observations "$HH_OBSERVATIONS" --argjson state "$HH_STATE" '{schema:1,bootId:$boot,observedAt:$now,status:"COMPLETE",activeConditions:([$state.conditions[]|select(.active)]|length),observations:$observations}')
    hh_atomic "$HH_RAM_ROOT/host-health-receipt.json" "$receipt" || return 1
    info=$(hh_mount_info /mnt/vault)
    if jq -e '.mounted and (.readOnly|not)' <<< "$info" >/dev/null;then
        mirror_at=$(jq -r '.lastSampleAt//0' "$HH_MIRROR" 2>/dev/null) || mirror_at=0
        if [[ "$mirror_at" =~ ^[0-9]+$ ]] && { ((HH_NOW-mirror_at>=3600)) || [[ -n "$HH_PENDING_BODY" || "${HH_DIRTY:-0}" == 1 ]]; };then
            [[ -d "${HH_MIRROR%/*}" && ! -L "${HH_MIRROR%/*}" ]] || mkdir -p -- "${HH_MIRROR%/*}" || return 1
            hh_atomic "$HH_MIRROR" "$HH_STATE" || return 1
        fi
    fi
}
hh_prepare() {
    HH_NOW=${HH_NOW:-$(date +%s)};HH_BOOT=${HH_BOOT:-$(cat "$HH_PROC_ROOT/sys/kernel/random/boot_id")};HH_STATE='{}'
    local source
    for source in "$HH_RAM_ROOT/host-health-state.json" "$HH_MIRROR";do
        [[ -f "$source" && ! -L "$source" && $(stat -c %u "$source") == "$EUID" ]] || continue
        if jq -e '.schema==1 and (.conditions|type)=="object" and (.baselines.network|type)=="object"' "$source" >/dev/null 2>&1;then HH_STATE=$(cat "$source");break;fi
    done
    HH_STATE=$(jq -c --arg boot "$HH_BOOT" '.conditions //= {} | .baselines.network //= {} | if .bootId!=$boot then .baselines={network:{}}|.conditions|=with_entries(.value.bad=0|.value.good=0) else . end | .schema=1 | .bootId=$boot | .baselines.network //= {}' <<< "$HH_STATE") || return 1
    hh_collect && hh_lifecycle && hh_save || return 1
    HH_PREPARED=1
}
# Console presentation only: consume this scan's saved observations, never
# re-probe hardware, change confirmation state or enqueue an email here.
hh_log_observations() {
    local category level message id observed title detail active bad good pending required summary
    while IFS=$'\t' read -r id observed title detail active bad good pending required;do
        [[ -n "$id" ]] || continue
        category=HOST
        case "$id" in
          mount:*|monitor:mount-inventory) category=MOUNTS;;
          space:*) category=CAPACITY;; inodes:*) category=INODES;;
          memory) category=MEMORY;; cpu:*) category=CPU;; network:*) category=LAN;;
          btrfs:*) category=BTRFS;; monitor:external-observer) category=OBSERVER;;
          monitor:disk-state) category=DISK_STATE;;
        esac
        case "$observed" in
          ok) level=INFO;; warning) level=WARNING;; critical) level=CRITICAL;;
          unknown) level=WARNING;; *) level=INFO;;
        esac
        message="$title: observed=${observed^^}; $detail"
        if [[ "$active" == true ]];then
            message+=" Active incident retained"
            [[ "$observed" != ok ]] || message+="; recovery confirmation $good/2"
            message+="."
        elif [[ "$observed" == warning || "$observed" == critical ]];then
            message+=" Confirmation pending $bad/$required; no confirmed incident yet."
        fi
        [[ "$pending" == none ]] || message+=" Lifecycle event=$pending."
        log "$category" "$level" "$message"
    done < <(jq -r --argjson state "$HH_STATE" '.[] | . as $o | ($state.conditions[$o.id] // {}) as $c |
      [$o.id,$o.severity,$o.title,$o.detail,($c.active // false),($c.bad // 0),($c.good // 0),($c.pending // "" | if .=="" then "none" else . end),
       (if $o.severity=="critical" then $o.confirmations else 3 end)] |
      map(tostring|gsub("[\\t\\r\\n]";" ")) | @tsv' <<< "$HH_OBSERVATIONS")
    if ! jq -e 'any(.[]; .id|startswith("network:"))' <<< "$HH_OBSERVATIONS" >/dev/null;then
        log LAN INFO 'LAN coverage: not collected; no eligible active physical default-route interface was observed. No healthy link result inferred.'
    fi
    if ! jq -e 'any(.[]; .id|startswith("btrfs:"))' <<< "$HH_OBSERVATIONS" >/dev/null;then
        log BTRFS INFO 'Btrfs pressure coverage: not collected; only mounted, verified all-SSD Btrfs pools are eligible. Rotating array disks remain excluded.'
    fi
    summary=$(jq -nr --argjson observations "$HH_OBSERVATIONS" --argjson state "$HH_STATE" '
      "Host probes completed: observations=\($observations|length); OK=\([$observations[]|select(.severity=="ok")]|length); warning=\([$observations[]|select(.severity=="warning")]|length); critical=\([$observations[]|select(.severity=="critical")]|length); unverified=\([$observations[]|select(.severity=="unknown")]|length); unsupported=\([$observations[]|select(.severity=="unsupported")]|length); active incidents=\([$state.conditions[]|select(.active==true)]|length). RAM receipt saved; notifications follow the existing lifecycle policy."') || return 1
    log HOST INFO "$summary"
}
hh_delivered() {
    HH_STATE=$(jq -c --argjson now "$HH_NOW" '[.conditions|to_entries[]|select((.value.pending//"")!="")|.key][0:24] as $ids | reduce $ids[] as $id (. ; .conditions[$id].pending=""|.conditions[$id].notifiedAt=$now)' <<< "$HH_STATE") || return 1
    HH_PENDING_BODY='';HH_DIRTY=1;hh_save
}
hh_flush() {
    [[ "$HH_PREPARED" == 1 && -n "$HH_PENDING_BODY" ]] || return 0
    notify_unraid "$HH_PENDING_IMPORTANCE" 'Host health conditions changed' 'Read-only host checks; no repair, restart or configuration change was performed.'
}
