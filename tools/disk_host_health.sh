# shellcheck shell=bash
# shellcheck disable=SC2034 # Shared collector freshness map is consumed by lifecycle code.
# Daily state bootstrap: fail before configuration migration or state creation
# when the persistent pool is absent/read-only. Emergency evidence stays in RAM.
hm_emergency() {
    local healthy="$1" detail="$2" root="${HM_RAM_ROOT:-/run}" value tmp old=0 now boot
    now=$(date +%s);boot=$(cat /proc/sys/kernel/random/boot_id)
    [[ -d "$root" && ! -L "$root/host-health-monitor-emergency.json" ]] || return 1
    value=$(jq -nc --argjson healthy "$healthy" --arg detail "$detail" --arg boot "$boot" --argjson now "$now" '{schema:1,bootId:$boot,observedAt:$now,healthy:$healthy,detail:$detail}') || return 1
    tmp=$(mktemp "$root/.health-state.XXXXXX") || return 1
    printf '%s\n' "$value" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$root/host-health-monitor-emergency.json" || { rm -f "$tmp";return 1; }
    if [[ "$healthy" == false ]] && ! hh_fast_receipt_owns mount:/mnt/vault "$now" && [[ "$(hh_array_state)" == started ]];then
        [[ ! -f "$root/host-health-monitor-alert.epoch" || -L "$root/host-health-monitor-alert.epoch" ]] || read -r old < "$root/host-health-monitor-alert.epoch"
        [[ "$old" =~ ^[0-9]+$ ]] || old=0
        if ((now-old>=86400)) && [[ -x /usr/local/emhttp/webGui/scripts/notify ]];then
            if timeout --kill-after=5 30 /usr/local/emhttp/webGui/scripts/notify -i alert -s 'Unraid disk health' -d 'Persistent health state unavailable' -m "Status: ATTENTION
Summary: Daily disk monitoring deferred

Actions and findings:
$detail
No persistent state, migration or disk maintenance was performed. RAM emergency evidence was recorded; restore the vault mount before retrying.";then
                tmp=$(mktemp "$root/.health-alert.XXXXXX") || return 1
                printf '%s\n' "$now" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$root/host-health-monitor-alert.epoch" || return 1
            fi
        fi
    fi
}
hm_storage_guard() {
    local info type probe
    info=$(hh_mount_info /mnt/vault) || return 1;type=$(jq -r '.type' <<< "$info")
    if [[ "$type" =~ ^(btrfs|xfs|zfs)$ ]] && jq -e '.mounted and (.readOnly|not)' <<< "$info" >/dev/null;then
        # Existing parent permissions and symlinks are checked by the normal state
        # validator. No directory is created to test a missing pool.
        probe=$(mktemp /mnt/vault/.health-state-probe.XXXXXX) || {
            hm_emergency false 'Mounted vault rejected a write probe; persistent monitoring state was not initialized.' || true
            return 1
        }
        if ! printf 'health-state-write-probe\n' > "$probe" || ! rm -f -- "$probe";then
            rm -f -- "$probe" 2>/dev/null || true
            hm_emergency false 'Mounted vault write/delete probe failed; persistent state was left untouched.' || true
            return 1
        fi
        hm_emergency true 'Vault is mounted read-write and accepted a write/delete probe; disk monitoring may initialize.' || return 1
        return 0
    fi
    hm_emergency false "Vault state access deferred: $info. Existing state was left untouched." || true
    printf '%s\n' 'Disk health deferred: vault must be mounted read-write; persistent state was not initialized.' >&2
    return 1
}
hm_pool_health() {
    local mount="$1" status="$2" fresh="$3" now="${RUN_EPOCH:-$(date +%s)}" usage show metrics severity
    local cron_file expression due due_epoch start epoch=0 clean=false grace=259200 entry file tmp existing schedule_status=disabled
    file="$POOL_HEALTH_FILE"
    usage=$(timeout --kill-after=1 8 btrfs filesystem usage -b "$mount" 9>&- 2>/dev/null) || usage=''
    show=$(timeout --kill-after=1 8 btrfs filesystem show "$mount" 9>&- 2>/dev/null) || show=''
    metrics=$(hh_btrfs_metrics "$usage" "$show") || return 1
    severity=$(jq -r '.severity' <<< "$metrics")
    if [[ "$severity" == ok ]];then FRESH_FILESYSTEM["pool:$mount"]=1;fi
    if ! hh_fast_receipt_owns "btrfs:$mount" "$now";then
        case "$severity" in warning|critical)
            record_finding "$severity" filesystem filesystem.btrfs '' 'Btrfs allocation or redundancy requires attention' "$mount: $metrics" 'Check pool capacity and device availability; no balance or repair was started.' btrfs_pool_health "mount:$mount";;
            unknown) record_collector_event FAILED "Btrfs pool $mount" 'Allocation/redundancy evidence unavailable';;
        esac
    fi
    # Native per-pool schedule only. Docker loop scrub retains its existing owner.
    cron_file="${HH_SCRUB_CRON_ROOT:-/boot/config/plugins/dynamix}/scrub_${mount##*/}.cron"
    expression='';due='{"valid":true,"dueEpoch":0}'
    if [[ "$mount" == /mnt/* && -r "$cron_file" ]];then
        expression=$(awk -v target="$mount" '!/^#/ && NF>=8 {found=0;for(i=6;i<=NF;i++)if($i==target)found=1;if(found)print $1" "$2" "$3" "$4" "$5}' "$cron_file")
        if [[ -n "$expression" ]];then
            due=$(hh_cron_last_due "$expression" "$now") || due='{"valid":false}'
            schedule_status=scheduled
            if ! jq -e '.valid and .dueEpoch>0' <<< "$due" >/dev/null;then
                schedule_status=unverified
                record_collector_event FAILED "Native scrub schedule $mount" 'Enabled native cron could not be interpreted; no schedule or scrub was changed'
            fi
        fi
    fi
    start=$(sed -nE 's/^[[:space:]]*Scrub started:[[:space:]]*//p;s/.*scrub started at[[:space:]]*//p' <<< "$status" | head -n1)
    if [[ -n "$start" ]];then epoch=$(date -d "$start" +%s 2>/dev/null) || epoch=0;fi
    [[ "$epoch" =~ ^[0-9]+$ ]] || epoch=0
    if grep -qiE 'Status:[[:space:]]+finished|scrub finished' <<< "$status" && grep -qi 'no errors found' <<< "$status" && ! grep -qiE '(Corrected|Uncorrectable):[[:space:]]*[1-9]' <<< "$status" && ((epoch>0 && epoch<=now));then clean=true;fi
    due_epoch=$(jq -r '.dueEpoch//0' <<< "$due")
    if [[ "$schedule_status" == scheduled ]] && ((now>due_epoch+grace));then
        if [[ "$clean" == true ]] && ((epoch>=due_epoch-300));then
            FRESH_FILESYSTEM["native_scrub:$mount"]=1
        else
            record_finding warning monitoring monitoring.scrub '' 'Native pool scrub completion overdue' "$mount: due=$(jq -r '.dueLocal' <<< "$due"); grace=72h; latest recorded start=$start; clean=$clean; live status=$fresh." 'Review the native scrub history and schedule. This monitor does not start or abort pool scrubs.' native_scrub_overdue "mount:$mount"
        fi
    elif [[ "$schedule_status" == scheduled && "$clean" == true ]] && ((epoch>=due_epoch-300));then FRESH_FILESYSTEM["native_scrub:$mount"]=1;fi
    log BTRFS INFO "$mount: schedule=$schedule_status; last due=$(jq -r '.dueLocal//"not applicable"' <<< "$due"); clean=$clean; start epoch=$epoch; grace=72h; allocation=$metrics"
    entry=$(jq -nc --arg mount "$mount" --argjson at "$now" --argjson metrics "$metrics" --argjson due "$due" --argjson start "$epoch" --argjson clean "$clean" --arg schedule "$schedule_status" --argjson live "$fresh" '{mount:$mount,observedAt:$at,allocation:$metrics,nativeSchedule:$schedule,deadline:$due,lastRecordedStart:$start,recordedClean:$clean,liveStatus:($live==1)}') || return 1
    existing='{"schema":1,"pools":{}}'
    if [[ -s "$file" ]];then
        [[ ! -L "$file" ]] && jq -e '.schema==1 and (.pools|type)=="object"' "$file" >/dev/null || return 1
        existing=$(cat "$file")
    fi
    tmp=$(state_temp_file "$file") || return 1
    jq -c --arg mount "$mount" --argjson entry "$entry" '.pools[$mount]=$entry' <<< "$existing" > "$tmp" && collector_atomic_commit "$tmp" "$file"
}
hm_mount_fallback() {
    local mount info now="$RUN_EPOCH" severity=critical
    while IFS= read -r mount;do
        hh_fast_receipt_owns "mount:$mount" "$now" && continue
        info=$(hh_mount_info "$mount")
        if jq -e '.mounted and (.readOnly|not)' <<< "$info" >/dev/null;then
            FRESH_FILESYSTEM["mount:$mount"]=1
        else
            record_finding "$severity" storage storage.availability '' 'Required mount unavailable or read-only' "$mount: $info; fast-owner evidence unavailable." 'Review native Unraid mount status before repair; no automatic remount was attempted.' mount_access "mount:$mount"
        fi
    done < <(hh_expected_mounts | sort -u)
}
