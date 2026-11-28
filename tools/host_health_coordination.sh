# shellcheck shell=bash
# Shared health contract: collectors retain alert/recovery ownership; peer context
# never creates or clears another collector's incidents. No extra scheduler.
hc_owned_json() {
    local file="$1"
    [[ -f "$file" && ! -L "$file" && $(stat -c %u "$file" 2>/dev/null) == "$EUID" && $(stat -c %h "$file" 2>/dev/null) == 1 ]] || return 1
    (( $(stat -c %s "$file" 2>/dev/null || echo 9999999) <= 2097152 )) || return 1
    jq -e 'type=="object"' "$file" >/dev/null 2>&1
}
# Labels are annotations only; stable finding/device keys remain unchanged.
# Read native metadata/sysfs, never SMART or a block device. Missing metadata
# leaves the device path explicit instead of guessing a slot or serial number.
hc_device_identity() {
    local device="$1" base slot='' native='' model='' serial='' suffix='' label row
    base=${device#/dev/}
    if [[ "$device" =~ ^/dev/(sd[a-z]+|nvme[0-9]+n[0-9]+)$ ]];then
        row=$(awk -F= -v wanted="$base" '
          function emit(){if(dev==wanted && slot!="flash"){matches++;result=slot "|" identity}}
          /^\[/{emit();slot=$0;gsub(/[\[\]"\r]/,"",slot);dev=identity="";next}
          {v=substr($0,index($0,"=")+1);gsub(/["\r]/,"",v)}
          $1=="device"{dev=v} $1=="id"{identity=v} END{emit();if(matches==1)print result}
        ' "${HH_DISKS_INI:-/var/local/emhttp/disks.ini}" 2>/dev/null) || row=''
        IFS='|' read -r slot native <<< "$row"
        [[ "$slot" =~ ^[A-Za-z0-9_.-]+$ ]] || slot=''
        if [[ -n "$native" && "$native" == *_* ]];then model=${native%_*};serial=${native##*_};fi
        if [[ -z "$model" && -r "${HH_SYS_ROOT:-/sys}/class/block/$base/device/model" ]];then
            model=$(head -c 256 "${HH_SYS_ROOT:-/sys}/class/block/$base/device/model" 2>/dev/null) || model=''
        fi
        model=$(printf '%s' "$model" | LC_ALL=C tr -cd '[:print:]' | sed -E 's/_/ /g;s/[[:space:]]+/ /g;s/^[[:space:]]+//;s/[[:space:]]+$//');model=${model:0:96}
        serial=$(printf '%s' "$serial" | LC_ALL=C tr -cd '[:alnum:]-');suffix=${serial: -6}
    fi
    label="$device"
    if [[ -n "$slot" || -n "$model" || -n "$suffix" ]];then
        label="${slot:-slot unverified} | ${model:-model unavailable} | serial ${suffix:+...}${suffix:-unavailable} ($device)"
    fi
    jq -nc --arg device "$device" --arg slot "$slot" --arg model "$model" --arg serial "$suffix" --arg label "$label" \
      '{device:$device,slot:$slot,model:$model,serialSuffix:$serial,label:$label}'
}
hc_device_label() {
    hc_device_identity "$1" | jq -r .label
}
hc_daily_snapshot() {
    local now="$1" file="${HC_DAILY_RECEIPT:-/mnt/vault/cloud/logs/script/host_health_monitor/state/monitor_receipt.json}" schedule="${HC_SCHEDULE_FILE:-/boot/config/plugins/user.scripts/schedule.json}"
    local old='{}' evidence='{}' plan=unknown cron='' due='{"valid":false}' boot
    boot=$(cat "${HH_PROC_ROOT:-/proc}/sys/kernel/random/boot_id") || return 1
    if hc_owned_json "$schedule";then
        plan=$(jq -r '[to_entries[]|select(.key|endswith("/host_health_monitor/script"))][0].value.frequency // "absent"' "$schedule")
        if [[ "$plan" == custom ]];then
            cron=$(jq -r '[to_entries[]|select(.key|endswith("/host_health_monitor/script"))][0].value.custom // ""' "$schedule")
            due=$(hh_cron_last_due "$cron" "$now") || due='{"valid":false}'
            plan=enabled
        elif [[ "$plan" == absent || "$plan" == never || "$plan" == disabled || "$plan" == manual ]];then plan=disabled
        else plan=unknown;fi
    fi
    if hc_owned_json "$file";then
        old=$(cat "$file")
        if jq -e --argjson now "$now" '.healthEvidence.schema==1 and (.healthEvidence.observedAt|type)=="number" and .healthEvidence.observedAt>0 and .healthEvidence.observedAt<=$now+60 and (.healthEvidence.bootId|type)=="string" and (.healthEvidence.findings|type)=="array" and (.healthEvidence.findings|length)<=256 and all(.healthEvidence.findings[];(.id|type)=="string" and (.severity|IN("warning","critical")) and (.title|type)=="string" and (.detail|type)=="string" and (.action|type)=="string")' <<< "$old" >/dev/null;then
            evidence=$(jq -c .healthEvidence <<< "$old")
        fi
    fi
    jq -nc --argjson evidence "$evidence" --argjson producer "$old" --argjson due "$due" --arg plan "$plan" --arg boot "$boot" --argjson now "$now" '
      ($evidence.observedAt//0) as $at | ($due.dueEpoch//0) as $deadline |
      (if $plan=="disabled" then "NOT_SCHEDULED"
       elif $plan!="enabled" or ($due.valid//false)!=true then "UNVERIFIED"
       elif ($at>0 and $evidence.bootId==$boot and $at >= $deadline and $now-$at<=129600) then "CURRENT"
       elif $now<=$deadline+7200 then "AWAITING_SCHEDULED_COMPLETION" else "STALE" end) as $freshness |
      ($producer.maintenance.lastOperationalCompleteEpoch//0) as $operational |
      (if $plan=="disabled" then "NOT_SCHEDULED"
       elif $plan!="enabled" or ($due.valid//false)!=true then "UNVERIFIED"
       elif $operational>0 and $operational<=$now+60 and $operational>=$deadline and $evidence.bootId==$boot then "CURRENT"
       elif $now<=$deadline+7200 then "AWAITING_SCHEDULED_COMPLETION"
       elif ($producer|has("maintenance")) then (if $operational==0 and ($producer.maintenance.lastAttemptEpoch//0)==0 then "UNVERIFIED" else "STALE" end) else "UNCLASSIFIED_LEGACY" end) as $maintenanceFreshness |
      {freshness:$freshness,schedule:$plan,dueEpoch:$deadline,observedAt:$at,runPurpose:($producer.runPurpose//"unclassified legacy"),
       maintenance:{freshness:$maintenanceFreshness,lastAttemptEpoch:($producer.maintenance.lastAttemptEpoch//0),lastOperationalCompleteEpoch:$operational,status:($producer.maintenance.status//"unverified"),verifiedScrubResults:($producer.maintenance.verifiedScrubResults//[])},executionStatus:($producer.status//"unknown"),
       findings:(if $freshness=="NOT_SCHEDULED" then [] else ($evidence.findings//[]) end),coverage:($evidence.coverage//null),thresholds:($evidence.thresholds//{}),
       delivery:($producer.notification//"unknown")}'
}
hc_probe_action() {
    case "$1" in
      cpu:*|disk-temperature:*) printf 'Inspect cooling and airflow; reduce load if overheating persists. No cooling or hardware settings were changed.';;
      mount:*) printf 'Check native Unraid device and mount status. No remount or repair was attempted.';;
      btrfs:*) printf 'Check pool capacity, member availability and filesystem errors. No balance or repair was attempted.';;
      space:*|inodes:*) printf 'Review the affected filesystem and free space deliberately. No files were deleted.';;
      memory) printf 'Identify sustained memory consumers and check recent OOM events. No application was restarted.';;
      network:*) printf 'Check the LAN interface, cable and switch. No network settings were changed.';;
      monitor:daily-health) printf 'Check the daily User Script execution and retained completion evidence. No disk test or backup was forced.';;
      *) printf 'Review the reported evidence and restore the affected collector or service. No automatic repair was attempted.';;
    esac
}
hc_daily_probe() {
    HC_DAILY_SNAPSHOT=$(hc_daily_snapshot "$HH_NOW") || HC_DAILY_SNAPSHOT='{"freshness":"UNVERIFIED","executionStatus":"unverified","findings":[],"thresholds":{}}'
    local freshness severity=ok detail
    freshness=$(jq -r .freshness <<< "$HC_DAILY_SNAPSHOT")
    case "$freshness" in
      STALE|UNVERIFIED) severity=warning;;
      AWAITING_SCHEDULED_COMPLETION) severity=unknown;;
      NOT_SCHEDULED) severity=deferred;;
    esac
    if [[ "$freshness" == CURRENT ]] && jq -e '.executionStatus=="incomplete"' <<< "$HC_DAILY_SNAPSHOT" >/dev/null;then severity=warning;fi
    if [[ "$severity" == ok ]] && jq -e '.maintenance.freshness=="UNVERIFIED"' <<< "$HC_DAILY_SNAPSHOT" >/dev/null;then severity=unknown;fi
    if jq -e '.maintenance.freshness=="STALE" or .maintenance.status=="incomplete"' <<< "$HC_DAILY_SNAPSHOT" >/dev/null;then severity=warning;fi
    detail=$(jq -r '"Daily collector freshness=\(.freshness); latest execution=\(.executionStatus); retained disk findings=\(.findings|length). Last completed collection="+(.observedAt|tostring)+"; maintenance assessment="+(.maintenance.freshness//"unverified")+". Findings remain owned by the daily monitor; schedule grace=2h."' <<< "$HC_DAILY_SNAPSHOT")
    hh_observe monitor:daily-health "$severity" 'Daily disk monitoring' "$detail" 2
}
hc_disk_temperatures() {
    local file="${HH_DISKS_INI:-/var/local/emhttp/disks.ini}" stamp slot dev native_id temp rota kind warn crit severity id label count=0
    stamp=$(stat -c %Y "$file" 2>/dev/null) || stamp=0
    if [[ ! "$stamp" =~ ^[0-9]+$ ]] || ((stamp>HH_NOW+60 || HH_NOW-stamp>900));then
        hh_observe monitor:disk-temperatures warning 'Native disk temperatures unavailable' 'Unraid disk metadata is missing or older than 15 minutes; no SMART read or disk wake was performed.' 3
        return
    fi
    local limits='{}'
    if [[ ${HC_DAILY_SNAPSHOT:-} != '' ]];then limits=$(jq -c '.thresholds//{}' <<< "$HC_DAILY_SNAPSHOT");fi
    while IFS=$'\t' read -r slot dev native_id temp;do
        [[ "$dev" =~ ^(sd[a-z]+|nvme[0-9]+n[0-9]+)$ && -n "$native_id" && "$native_id" != none ]] || continue
        label=$(hc_device_label "/dev/$dev")
        id="disk-temperature:$(printf '%s' "$native_id"|sha256sum|cut -c1-24)";count=$((count+1))
        if [[ "$dev" == nvme* ]];then kind=nvme;warn=70;crit=80
        else
            rota=$(cat "${HH_SYS_ROOT:-/sys}/class/block/$dev/queue/rotational" 2>/dev/null) || rota=''
            case "$rota" in 0) kind=ssd;warn=65;crit=70;;1) kind=hdd;warn=55;crit=60;;*) hh_observe "$id" unknown "Disk temperature $label" 'Device type could not be verified; no threshold guessed.';continue;;esac
        fi
        local w c
        w=$(jq -r --arg kind "$kind" '.[$kind].warning//empty' <<< "$limits");c=$(jq -r --arg kind "$kind" '.[$kind].critical//empty' <<< "$limits")
        if [[ "$w" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ ]] && ((w>=20 && c>=w && c<=120));then warn=$w;crit=$c;fi
        if [[ ! "$temp" =~ ^[0-9]+$ ]] || ((temp<=0 || temp>=150));then
            hh_observe "$id" deferred "Disk temperature $label" 'No current native temperature, commonly because the disk is sleeping. No healthy sample inferred and no disk woken.'
            continue
        fi
        severity=ok;((temp>=warn)) && severity=warning;((temp>=crit)) && severity=critical
        if [[ "$severity" == ok ]] && jq -e --arg id "$id" '.conditions[$id].active==true' <<< "$HH_STATE" >/dev/null && ((temp>warn-3));then severity=warning;fi
        hh_observe "$id" "$severity" "Disk temperature $label" "$dev: ${temp}C; warning=${warn}C, critical=${crit}C; source=Unraid native metadata; no SMART polling or disk wake." 1
        HH_OBSERVATIONS=$(jq -c --arg id "$id" --arg device "/dev/$dev" 'map(if .id==$id then .+{device:$device} else . end)' <<< "$HH_OBSERVATIONS")
        # A daily fallback incident keeps its recovery ownership until confirmed.
        if [[ ${HC_DAILY_SNAPSHOT:-} != '' ]] && jq -e --arg device "/dev/$dev" '.freshness=="CURRENT" and any(.findings[]?;.device==$device and (.id|endswith("|temp")))' <<< "$HC_DAILY_SNAPSHOT" >/dev/null;then
            HH_OBSERVATIONS=$(jq -c --arg id "$id" 'map(if .id==$id then .+{delegated:true} else . end)' <<< "$HH_OBSERVATIONS")
        fi
    done < <(awk -F= '
      function emit(){if(dev!="" && slot!="flash")print slot"\t"dev"\t"(id==""?"none":id)"\t"(temp==""?"*":temp)}
      /^\[/{emit();slot=$0;gsub(/[\[\]"]/,"",slot);dev=id=temp="";next}
      {v=substr($0,index($0,"=")+1);gsub(/^"|"$/,"",v)} $1=="device"{dev=v}$1=="id"{id=v}$1=="temp"{temp=v} END{emit()}' "$file")
    if ((count==0));then hh_observe monitor:disk-temperatures unknown 'Native disk temperature coverage' 'No eligible device identities found in current Unraid metadata.'
    else hh_observe monitor:disk-temperatures ok 'Native disk temperature coverage' "$count device(s) inventoried; sleeping/unverified readings are deferred explicitly.";fi
}
hc_combined_health() {
    local observations="$1" state="$2" now="$3" daily active storage
    daily=${HC_DAILY_SNAPSHOT:-};[[ -n "$daily" ]] || daily=$(hc_daily_snapshot "$now") || daily='{"freshness":"UNVERIFIED","executionStatus":"unverified","findings":[]}'
    active=$(jq -c '[.conditions|to_entries[]|select(.value.active)|{id:.key,severity:.value.severity,title:.value.title,detail:.value.detail,pending:(.value.pending//""),source:"host_health_watchdog"}]' <<< "$state") || return 1
    local previous="${HC_FAST_RECEIPT:-${HH_RAM_ROOT:-/run}/host-health-receipt.json}" cached='[]'
    if jq -e '.freshness|IN("UNVERIFIED","STALE")' <<< "$daily" >/dev/null && hc_owned_json "$previous";then
        cached=$(jq -c --arg boot "$(cat /proc/sys/kernel/random/boot_id)" 'if .bootId==$boot then (.health.daily.findings//[]) else [] end' "$previous") || cached='[]'
        daily=$(jq -c --argjson cached "$cached" 'if (.findings|length)==0 and ($cached|type)=="array" then .findings=$cached|.cachedUnverified=true else . end' <<< "$daily") || return 1
    fi
    storage=$(hc_storage_snapshot "$now") || return 1
    jq -nc --argjson storage "$storage" --argjson daily "$daily" --argjson active "$active" --argjson observations "$observations" --argjson now "$now" '
      {schema:1,observedAt:$now,daily:$daily,fastFindings:$active,storage:$storage,
       healthStatus:(if any($active[];.severity=="critical") or any($daily.findings[];.severity=="critical") then "CRITICAL"
        elif ($active|length)>0 or ($daily.findings|length)>0 or ($storage.openXfsSources|length)>0 then "ATTENTION"
        elif ($storage.evidenceVerified|not) or $storage.executionStatus=="FAILED" or ($storage.fresh|not) or ($daily.freshness|IN("STALE","UNVERIFIED")) or any($observations[];.severity=="unknown") then "UNVERIFIED" elif any($observations[];(.severity|IN("warning","critical")) and (.delegated//false|not)) then "CONFIRMING" else "OK" end),
       coverage:{partial:(any($observations[];.severity|IN("unknown","deferred","unsupported")) or (($daily.coverage.smart.deferred//0)>0) or (($daily.coverage.smart.unverified//0)>0) or (($daily.coverage.smart.neverSampled//0)>0)),observations:($observations|length),unverified:([$observations[]|select(.severity=="unknown")]|length),deferred:([$observations[]|select(.severity=="deferred")]|length),unsupported:([$observations[]|select(.severity=="unsupported")]|length)}}'
}
hc_peer_context() {
    local role="$1" now="$2" daily fast='{}' file="${HC_FAST_RECEIPT:-/run/host-health-receipt.json}"
    if [[ "$role" == watchdog ]];then
        daily=${HC_DAILY_SNAPSHOT:-};[[ -n "$daily" ]] || daily=$(hc_daily_snapshot "$now") || return 1
        jq -r '"Daily disk context (existing findings; not additional notification events): freshness=\(.freshness); execution=\(.executionStatus).", (.findings|sort_by(if .severity=="critical" then 0 else 1 end)|.[0:24][]|"- [\(.severity|ascii_upcase)] \(.title): \(.detail|.[0:1200])\n  Action: \(.action|.[0:500])"), (if (.findings|length)>24 then "Additional existing disk findings: \((.findings|length)-24); retained in daily findings and their original notifications. Peer context does not acknowledge them." else empty end)' <<< "$daily"
    else
        if hc_owned_json "$file" && jq -e --argjson now "$now" --arg boot "$(cat /proc/sys/kernel/random/boot_id)" '.schema==1 and .bootId==$boot and .observedAt<=$now+60 and .observedAt>=$now-900' "$file" >/dev/null;then
            jq -r '"Fast host context (existing findings; watchdog owns notification/recovery): active incidents=\(.health.fastFindings//[]|length); observed epoch=\(.observedAt).",(.health.fastFindings[]?|"- [\(.severity|ascii_upcase)] \(.title): \(.detail)")' "$file"
        else printf 'Fast host context: UNVERIFIED; recent same-boot watchdog evidence unavailable. Daily disk findings remain independently reported.\n';fi
    fi
}
hc_export_daily_evidence() {
    local now="$1" id rows='[]' row prior='[]' file="${MONITOR_RECEIPT_FILE:-}" boot
    boot=$(cat /proc/sys/kernel/random/boot_id) || return 1
    for id in "${FINDING_IDS[@]}";do
        row=$(jq -nc --arg id "$id" --arg severity "${FINDING_SEVERITY[$id]}" --arg title "${FINDING_TITLE[$id]}" --arg detail "${FINDING_EVIDENCE[$id]}" --arg action "${FINDING_ACTION[$id]}" --arg device "${FINDING_DEVICE[$id]:-}" --arg label "$(hc_device_label "${FINDING_DEVICE[$id]:-}")" '{displayLabel:$label,device:$device,id:$id,severity:$severity,title:$title,detail:$detail,action:$action,verification:"observed"}') || return 1
        rows=$(jq -nc --argjson rows "$rows" --argjson row "$row" '$rows+[$row]') || return 1
    done
    hc_owned_json "$file" && prior=$(jq -c '.healthEvidence.findings//[]' "$file")
    for id in "${NOTIFY_CARRY_IDS[@]}";do
        [[ -z "${FINDING_SEEN[$id]:-}" ]] || continue
        row=$(jq -nc --argjson prior "$prior" --arg id "$id" --arg severity "${NOTIFY_PREV_SEVERITY[$id]:-warning}" --arg title "${NOTIFY_PREV_LABEL[$id]:-Previous disk finding}" '([$prior[]|select(.id==$id)][0]//{id:$id,severity:$severity,title:$title,detail:"Previous finding retained; fresh recovery confirmation remains outstanding.",action:"Review current disk evidence; absence of a sample is not recovery."})+{verification:"awaiting-confirmation"}') || return 1
        rows=$(jq -nc --argjson rows "$rows" --argjson row "$row" '$rows+[$row]') || return 1
    done
    jq -nc --argjson at "$now" --arg boot "$boot" --argjson findings "$rows" --argjson coverage "${HOST_HEALTH_COVERAGE:-null}" --argjson hw "$HDD_TEMP_WARNING" --argjson hc "$HDD_TEMP_CRITICAL" --argjson sw "$SSD_TEMP_WARNING" --argjson sc "$SSD_TEMP_CRITICAL" --argjson nw "$NVME_TEMP_WARNING" --argjson nc "$NVME_TEMP_CRITICAL" '{schema:1,observedAt:$at,bootId:$boot,findings:$findings,coverage:$coverage,thresholds:{hdd:{warning:$hw,critical:$hc},ssd:{warning:$sw,critical:$sc},nvme:{warning:$nw,critical:$nc}}}'
}
hc_fast_temperature_owns() {
    local disk="$1" severity="${2,,}" file="${HC_FAST_RECEIPT:-/run/host-health-receipt.json}" daily="${MONITOR_RECEIPT_FILE:-}" now boot
    now=$(date +%s);boot=$(cat /proc/sys/kernel/random/boot_id)
    # Once the daily fallback reported an incident, it retains recovery ownership.
    if hc_owned_json "$daily" && jq -e --arg disk "$disk" 'any(.healthEvidence.findings[]?;.device==$disk and (.id|endswith("|temp")))' "$daily" >/dev/null;then return 1;fi
    hc_owned_json "$file" || return 1
    jq -e --arg disk "$disk" --arg severity "$severity" --arg boot "$boot" --argjson now "$now" '
      ([.observations[]?|select(.device==$disk and (.id|startswith("disk-temperature:")))|.id]) as $ids |
      .bootId==$boot and .observedAt<=$now+60 and .observedAt>=$now-900 and
      any(.health.fastFindings[]?;(.id as $id|$ids|index($id))!=null and .pending=="" and
       (.severity=="critical" or ($severity=="warning" and .severity=="warning")))' "$file" >/dev/null
}
hc_thermal_only_messages() {
    local piece has_temperature=false
    local -a pieces=()
    IFS=';' read -r -a pieces <<< "$1"
    for piece in "${pieces[@]}";do
        piece=${piece#"${piece%%[![:space:]]*}"}
        case "$piece" in
          'NVMe Temp '*|'HDD Temp '*|'SSD Temp '*|'SAS HDD Temp '*) has_temperature=true;;
          'TBW ~ '*|'Read ~ '*|'Endurance used='*|'') ;;
          *) return 1;;
        esac
    done
    [[ "$has_temperature" == true ]]
}
hc_daily_watchdog_guard() {
    local now file="${HC_FAST_RECEIPT:-/run/host-health-receipt.json}" boot schedule="${HC_SCHEDULE_FILE:-/boot/config/plugins/user.scripts/schedule.json}"
    now=$(date +%s);boot=$(cat /proc/sys/kernel/random/boot_id)
    if hc_owned_json "$schedule" && jq -e '[to_entries[]|select(.key|endswith("/host_health_watchdog/script"))][0].value.frequency as $frequency | ($frequency==null or ($frequency|IN("manual","disabled","never")))' "$schedule" >/dev/null;then HC_FAST_FRESH=0;return 0;fi
    if hc_owned_json "$file" && jq -e --arg boot "$boot" --argjson now "$now" '.status=="COMPLETE" and .bootId==$boot and .observedAt<=$now+60 and .observedAt>=$now-900' "$file" >/dev/null;then
        HC_FAST_FRESH=1
        return 0
    fi
    HC_FAST_FRESH=0
    record_finding warning monitoring monitoring.freshness '' 'Fast host watchdog evidence unavailable' 'No recent same-boot fast host receipt; daily disk checks and mount/filesystem/syslog fallbacks continue independently.' 'Review host_health_watchdog and its existing five-minute schedule. No service or disk maintenance was forced.' host_watchdog_stale
}
hc_storage_snapshot() {
    local now="$1" file="${SYSLOG_INCIDENT_ROOT:-/mnt/vault/cloud/logs/script/host_health_watchdog}/incidents.json" events='[]' xfs='[]' heartbeat=0
    local ledger="${XFS_INCIDENT_FILE:-/boot/config/plugins/user.scripts/scripts/host_health_watchdog/xfs_faults.tsv}" verified=true
    if hc_owned_json "$file";then
        events=$(jq -ce --argjson now "$now" '[.incidents|to_entries[]?|select(.value.severity=="CRITICAL" and .value.lastSeen>=$now-86400 and .value.lastSeen<=$now+60)|{id:.key,observedAt:.value.lastSeen,evidence:.value.example,kind:"historical_event_not_proof_of_current_fault"}]|sort_by(.observedAt)|reverse|.[0:24]' "$file") || { events='[]';verified=false; }
    elif [[ -e "$file" ]];then verified=false
    fi
    if [[ -f "$ledger" && ! -L "$ledger" && -O "$ledger" ]];then
        xfs=$(jq -Rn '[inputs|split("\t")|select((.[0]|test("^[A-Za-z0-9_.-]+$")) and (.[1]|test("^[0-9]+$")))|{source:.[0],firstObserved:(.[1]|tonumber),action:"Review XFS shutdown/corruption evidence; --ack-xfs clears a reviewed marker and does not repair the filesystem."}]' "$ledger") || { xfs='[]';verified=false; }
    fi
    file="${HC_SYSLOG_HEARTBEAT:-${STATE_DIR:-/tmp/host_health_watchdog_state}/storage-watch.epoch}"
    if [[ -f "$file" && ! -L "$file" && -O "$file" ]];then read -r heartbeat < "$file" || heartbeat=0;fi
    [[ "$heartbeat" =~ ^[0-9]+$ ]] || heartbeat=0
    jq -nc --argjson verified "$verified" --argjson events "$events" --argjson xfs "$xfs" --argjson heartbeat "$heartbeat" --argjson now "$now" --arg execution "${HC_SYSLOG_RUN_STATUS:-NOT_COLLECTED_THIS_INVOCATION}" '{evidenceVerified:$verified,executionStatus:$execution,lastSuccessfulScanEpoch:$heartbeat,fresh:($heartbeat>0 and $heartbeat<=$now+60 and $heartbeat>=$now-1200),recentCriticalEvents:$events,openXfsSources:$xfs}'
}
hc_time_label() {
    local epoch="${1:-0}"
    if [[ "$epoch" =~ ^[1-9][0-9]*$ ]];then date -d "@$epoch" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf 'unverified';else printf 'not recorded';fi
}
hc_print_status() {
    local file="${HC_FAST_RECEIPT:-/run/host-health-receipt.json}" now boot fast_time disk_time maintenance_time oldest_time
    now=$(date +%s);boot=$(cat /proc/sys/kernel/random/boot_id)
    if ! hc_owned_json "$file" || ! jq -e --arg boot "$boot" --argjson now "$now" '.bootId==$boot and .observedAt<=$now+60 and .observedAt>=$now-900 and .health.schema==1' "$file" >/dev/null;then
        printf 'Host health: UNVERIFIED\nNo current same-boot coordinated receipt. No probes, state changes or notifications performed.\n';return 0
    fi
    fast_time=$(hc_time_label "$(jq -r '.observedAt' "$file")")
    disk_time=$(hc_time_label "$(jq -r '.health.daily.observedAt//0' "$file")")
    maintenance_time=$(hc_time_label "$(jq -r '.health.daily.maintenance.lastOperationalCompleteEpoch//0' "$file")")
    oldest_time=$(hc_time_label "$(jq -r '.health.daily.coverage.smart.oldestFreshEpoch//0' "$file")")
    jq -r --arg fast "$fast_time" --arg disk "$disk_time" --arg maintenance "$maintenance_time" --arg oldest "$oldest_time" '
      def partial: (.health.coverage.partial//false) or (.health.coverage.deferred//0)>0 or (.health.daily.coverage.smart.deferred//0)>0 or (.health.daily.coverage.smart.neverSampled//0)>0;
      "Host health: \(.health.healthStatus)"+(if .health.healthStatus=="OK" then "; no detected faults" else "" end)+(if partial then "; coverage partial" else "" end),
      "Fast probes observed: \($fast)",
      "Daily disk collection: \(.health.daily.freshness); observed \($disk); mode=\(.health.daily.runPurpose//"unclassified legacy")",
      "Maintenance assessment: \(.health.daily.maintenance.freshness//"UNCLASSIFIED_LEGACY"); latest execution=\(.health.daily.maintenance.status//"unverified"); last completed operational assessment: \($maintenance)",
      "An assessment completion is not proof that a native test or scrub completed.",
      "Fast active incidents: \(.health.fastFindings|length); disk findings: \(.health.daily.findings|length)",
      "Fast coverage: unverified=\(.health.coverage.unverified), deferred=\(.health.coverage.deferred), unsupported=\(.health.coverage.unsupported//0)",
      "Disk coverage: \(.health.daily.coverage.inventory//0) inventoried; SMART read this collection=\(.health.daily.coverage.smart.fresh//0); deferred=\(.health.daily.coverage.smart.deferred//0); unverified=\(.health.daily.coverage.smart.unverified//0); never sampled=\(.health.daily.coverage.smart.neverSampled//0)",
      "Oldest retained SMART sample: \($oldest)",
      "Native tests: pending=\(.health.daily.coverage.tests.pending//0); overdue=\(.health.daily.coverage.tests.overdue//0); deferred=\(.health.daily.coverage.tests.deferrals//[]|length)",
      (.health.daily.coverage.devices[]?|select(.status!="observed")|"- \(.label//.device): \(.status); last successful read: \(if .lastSuccessfulReadEpoch>0 then (.ageSeconds/86400|floor|tostring)+" day(s) ago" else "never sampled" end). \(.reason) Next: \(.nextEligibleAttempt)"),
      "Syslog scan: \(.health.storage.executionStatus); freshness=\(.health.storage.fresh)",
      "Open XFS review markers: \(.health.storage.openXfsSources|length)",
      (.health.fastFindings[]?|"- [\(.severity|ascii_upcase)] \(.title): \(.detail)"),
      (.health.daily.findings[]?|"- [\(.severity|ascii_upcase)] \(if (.displayLabel//"")!="" then .displayLabel+": " else "" end)\(.title): \(.detail)\n  Action: \(.action)")' "$file"
}
