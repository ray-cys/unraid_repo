# shellcheck shell=bash
# shellcheck disable=SC2034
# Bounded backup admission and resource priority; no persistent scheduler.
# Targets apply to independent labels, never split a directory or pause rsync.
BACKUP_ISS_RECONSTRUCT_WRITE=${BACKUP_ISS_RECONSTRUCT_WRITE:-true}
BACKUP_ADAPTIVE_ENABLED=${BACKUP_ADAPTIVE_ENABLED:-true}
BACKUP_ADAPTIVE_MAX_WORKERS=${BACKUP_ADAPTIVE_MAX_WORKERS:-2}
BACKUP_ADAPTIVE_SAMPLE_SECONDS=${BACKUP_ADAPTIVE_SAMPLE_SECONDS:-30}
BACKUP_ADAPTIVE_QUIET_SECONDS=${BACKUP_ADAPTIVE_QUIET_SECONDS:-300}
BA_ACTIVE=false
BA_REMOTE_READY=false
BA_POOL_FINISHED=false
BA_LAST_WORKER_ERROR=''
BA_SUMMARY='Adaptive controls: not started'
BA_WRITE_SUMMARY='ISS write mode: unchanged'
declare -A BA_PIDS=() BA_STAMPS=() BA_PREV_TOTAL=() BA_PREV_IDLE=() BA_PREV_WAIT=()
declare -A BA_CPU_BUSY=() BA_IO_BUSY=() BA_CPU_QUIET=() BA_IO_QUIET=()
BA_CPU=10 BA_IO=7 BA_TARGET=1 BA_PEAK=0 BA_QUIET=0 BA_SAMPLES=0 BA_DEGRADED=0 BA_LAST_SAMPLE=0
ba_log() {
    if [[ "$SCRIPT_ID" == backup_media_remote ]];then log RESOURCE INFO "$*";else log INFO "$*";fi
}
ba_stamp() {
    local line
    IFS= read -r line <"/proc/$1/stat" || return 1
    line=${line##*) };set -- $line;printf '%s\n' "${20}"
}
ba_alive() { [[ ${1:-} =~ ^[0-9]+$ && -n ${2:-} && $(ba_stamp "$1" 2>/dev/null) == "$2" ]]; }
ba_local_sample() {
    awk '/^cpu /{for(i=2;i<=9;i++)t+=$i;print t,$5,$6}' /proc/stat
    awk '/procs_running/{r=$2}/procs_blocked/{b=$2}END{print r,b}' /proc/stat
    awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}END{if(t>0&&a!="")print int(100*a/t);else print -1}' /proc/meminfo
    getconf _NPROCESSORS_ONLN
}
ba_observe() {
    local host=$1 data=$2 total idle wait running blocked memory cores dt di dw busy iow cpu_level=0 io_level=0
    read -r total idle wait running blocked memory cores <<<"${data//$'\n'/ }"
    for data in "$total" "$idle" "$wait" "$running" "$blocked" "$memory" "$cores";do [[ "$data" =~ ^[0-9]+$ ]] || return 1;done
    ((cores>0&&memory<=100)) || return 1
    if [[ -z ${BA_PREV_TOTAL[$host]:-} ]];then
        BA_PREV_TOTAL[$host]=$total BA_PREV_IDLE[$host]=$idle BA_PREV_WAIT[$host]=$wait
        return 2
    fi
    dt=$((total-BA_PREV_TOTAL[$host]));di=$((idle-BA_PREV_IDLE[$host]));dw=$((wait-BA_PREV_WAIT[$host]))
    BA_PREV_TOTAL[$host]=$total BA_PREV_IDLE[$host]=$idle BA_PREV_WAIT[$host]=$wait
    ((dt>0&&di>=0&&dw>=0&&di+dw<=dt)) || return 1
    busy=$((100*(dt-di-dw)/dt));iow=$((100*dw/dt))
    # High backup disk utilisation alone is not evidence of competing work.
    if ((memory<10||(busy>=90&&running>cores)));then cpu_level=2
    elif ((memory<20||(busy>=75&&running*5>cores*4)));then cpu_level=1;fi
    if ((memory<10||(iow>=20&&blocked>2)));then io_level=2
    elif ((memory<20||(iow>=10&&blocked>1)));then io_level=1;fi
    if ((cpu_level>0));then BA_CPU_BUSY[$host]=$(( ${BA_CPU_BUSY[$host]:-0}+1 ));BA_CPU_QUIET[$host]=0
    else BA_CPU_BUSY[$host]=0;BA_CPU_QUIET[$host]=$(( ${BA_CPU_QUIET[$host]:-0}+BACKUP_ADAPTIVE_SAMPLE_SECONDS ));fi
    if ((io_level>0));then BA_IO_BUSY[$host]=$(( ${BA_IO_BUSY[$host]:-0}+1 ));BA_IO_QUIET[$host]=0
    else BA_IO_BUSY[$host]=0;BA_IO_QUIET[$host]=$(( ${BA_IO_QUIET[$host]:-0}+BACKUP_ADAPTIVE_SAMPLE_SECONDS ));fi
    (( ${BA_CPU_BUSY[$host]:-0}<2 )) || { if ((cpu_level==2));then BA_CPU=10;else ((BA_CPU>=5)) || BA_CPU=5;fi; }
    (( ${BA_IO_BUSY[$host]:-0}<2 )) || { if ((io_level==2));then BA_IO=7;else ((BA_IO>=6)) || BA_IO=6;fi; }
    BA_CPU_PRESSURE=$((BA_CPU_PRESSURE+cpu_level));BA_IO_PRESSURE=$((BA_IO_PRESSURE+io_level))
}
ba_tree() {
    # Capture descendants from a verified live root; each mutation rechecks start time.
    local pid=$1 stamp=$2 child child_stamp
    ba_alive "$pid" "$stamp" || return 0
    printf '%s %s\n' "$pid" "$stamp"
    while read -r child;do
        [[ "$child" =~ ^[0-9]+$ ]] || continue
        child_stamp=$(ba_stamp "$child" 2>/dev/null) || continue
        ba_tree "$child" "$child_stamp"
    done < <(ps -o pid= --ppid "$pid" 2>/dev/null)
}
ba_tune_local() {
    local index pid stamp failed=0
    for index in "${!BA_PIDS[@]}";do
        while read -r pid stamp;do
            ba_alive "$pid" "$stamp" || continue
            renice -n "$BA_CPU" -p "$pid" >/dev/null 2>&1 || { ba_alive "$pid" "$stamp" && failed=1; }
            ionice -c 2 -n "$BA_IO" -p "$pid" >/dev/null 2>&1 || { ba_alive "$pid" "$stamp" && failed=1; }
            if ba_alive "$pid" "$stamp";then
                [[ $(ps -o ni= -p "$pid" 2>/dev/null | tr -d ' ') == "$BA_CPU" ]] || { ba_alive "$pid" "$stamp" && failed=1; }
                [[ $(ionice -p "$pid" 2>/dev/null) == "best-effort: prio $BA_IO" ]] || { ba_alive "$pid" "$stamp" && failed=1; }
            fi
        done < <(ba_tree "${BA_PIDS[$index]}" "${BA_STAMPS[$index]}")
    done
    return "$failed"
}
ba_sample() {
    local local_data remote_data rc=0 old="$BA_CPU/$BA_IO/$BA_TARGET" host observe_rc
    BA_LAST_SAMPLE=$(date +%s)
    BA_CPU_PRESSURE=0 BA_IO_PRESSURE=0
    local_data=$(ba_local_sample) || rc=1
    remote_data=$(BACKUP_SSH_COMMAND_TIMEOUT=15 backup_ssh "timeout 10 bash '$BA_REMOTE/helper' sample") || rc=1
    if ((rc==0));then
        ba_observe hubble "$local_data" || rc=$?
        observe_rc=0;ba_observe iss "$remote_data" || observe_rc=$?
        if ((observe_rc==1||rc==1));then rc=1;elif ((observe_rc==2||rc==2));then rc=2;fi
    fi
    BA_SAMPLES=$((BA_SAMPLES+1))
    if ((rc!=0));then
        BA_TARGET=1 BA_QUIET=0 BA_CPU=10 BA_IO=7
        ((rc!=1)) || BA_DEGRADED=$((BA_DEGRADED+1))
    elif ((BA_CPU_PRESSURE+BA_IO_PRESSURE>0));then BA_QUIET=0 BA_TARGET=1
    else
        BA_QUIET=$((BA_QUIET+BACKUP_ADAPTIVE_SAMPLE_SECONDS))
        if ((BA_QUIET>=BACKUP_ADAPTIVE_QUIET_SECONDS));then BA_TARGET=$BACKUP_ADAPTIVE_MAX_WORKERS;fi
    fi
    # Recover CPU and I/O priority independently after five quiet minutes on BOTH hosts.
    if ((rc==0));then
      if (( ${BA_CPU_QUIET[hubble]:-0}>=BACKUP_ADAPTIVE_QUIET_SECONDS && ${BA_CPU_QUIET[iss]:-0}>=BACKUP_ADAPTIVE_QUIET_SECONDS ));then BA_CPU=0;fi
      if (( ${BA_IO_QUIET[hubble]:-0}>=BACKUP_ADAPTIVE_QUIET_SECONDS && ${BA_IO_QUIET[iss]:-0}>=BACKUP_ADAPTIVE_QUIET_SECONDS ));then BA_IO=4;fi
    fi
    ba_tune_local || { BA_DEGRADED=$((BA_DEGRADED+1));BA_TARGET=1; }
    BACKUP_SSH_COMMAND_TIMEOUT=15 backup_ssh "timeout 10 bash '$BA_REMOTE/helper' tune $BA_CPU $BA_IO" || { BA_DEGRADED=$((BA_DEGRADED+1));BA_TARGET=1; }
    if [[ "$old" != "$BA_CPU/$BA_IO/$BA_TARGET" ]];then
        ba_log "Adaptive target: workers=$BA_TARGET (running jobs drain normally); CPU nice=$BA_CPU; I/O best-effort=$BA_IO; telemetry=/proc counters on Hubble and ISS"
    fi
}
ba_init() {
    [[ "$BACKUP_ADAPTIVE_ENABLED" == true || "$BACKUP_ADAPTIVE_ENABLED" == false ]] || return 1
    [[ "$BACKUP_ISS_RECONSTRUCT_WRITE" == true || "$BACKUP_ISS_RECONSTRUCT_WRITE" == false ]] || return 1
    [[ "$BACKUP_ADAPTIVE_ENABLED" == true ]] || { BA_SUMMARY='Adaptive controls disabled; original serial priority retained';return 0; }
    [[ "$BACKUP_ADAPTIVE_MAX_WORKERS" =~ ^[12]$ && "$BACKUP_ADAPTIVE_SAMPLE_SECONDS" =~ ^[1-9][0-9]*$ && "$BACKUP_ADAPTIVE_QUIET_SECONDS" =~ ^[1-9][0-9]*$ ]] || return 1
    ((BACKUP_ADAPTIVE_SAMPLE_SECONDS>=10&&BACKUP_ADAPTIVE_SAMPLE_SECONDS<=300&&BACKUP_ADAPTIVE_QUIET_SECONDS>=60&&BACKUP_ADAPTIVE_QUIET_SECONDS<=3600)) || return 1
    [[ "$LEASE_TOKEN" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    backup_lease_alive || return 1
    command -v renice >/dev/null && command -v ionice >/dev/null && [[ -r /proc/stat ]] || { BA_SUMMARY='Adaptive controls unavailable; original serial priority retained';return 0; }
    BA_ROOT="$BACKUP_TMP/adaptive";mkdir -m 700 -- "$BA_ROOT" || return 1
    BA_REMOTE="/run/hubble-backup-adaptive/$LEASE_TOKEN"
    local guard_seconds=$((BACKUP_ADAPTIVE_SAMPLE_SECONDS*3+30))
    ((guard_seconds>=120)) || guard_seconds=120
    ba_remote_script >"$BA_ROOT/helper"
    # Mark ownership before installation so a partial setup is cleaned on EXIT.
    BA_REMOTE_READY=true BA_ACTIVE=true
    backup_ssh "umask 077; mkdir -p /run/hubble-backup-adaptive; mkdir '$BA_REMOTE' && cat >'$BA_REMOTE/helper' && chmod 700 '$BA_REMOTE/helper' && printf '10 7\n' >'$BA_REMOTE/priority' && printf '%s\n' '$guard_seconds' >'$BA_REMOTE/guard-timeout' && command -v renice >/dev/null && command -v ionice >/dev/null" <"$BA_ROOT/helper" || return 1
    backup_ssh "for h in /run/hubble-backup-adaptive/*/helper;do test -f \"\$h\" || continue;test \"\$h\" = '$BA_REMOTE/helper' || timeout 20 bash \"\$h\" reconcile || exit 75;done" || return 1
    if [[ "$BACKUP_ISS_RECONSTRUCT_WRITE" == true ]];then
        BA_WRITE_SUMMARY=$(backup_ssh "timeout 20 bash '$BA_REMOTE/helper' write-begin") || { ba_log 'ISS temporary write-mode initialisation failed; backup stopped for safe restoration';return 1; }
        ba_log "$BA_WRITE_SUMMARY"
    fi
    BA_RSYNC_PATH="bash $BA_REMOTE/helper run rsync"
    BA_SUMMARY="$BA_WRITE_SUMMARY. Adaptive controls active; worker results pending."
    ba_sample
    ba_log 'Adaptive backup admission active: start=1, maximum=2 independent jobs; missing telemetry restricts new work to one job'
}
ba_worker() {
    local index=$1 descriptor=$2 label source dest excludes bw rc=0
    # Workers must not run the parent EXIT trap or publish parent completion.
    trap - EXIT INT TERM PIPE
    trap 'exit 143' TERM INT
    IFS='|' read -r label source dest excludes bw <<<"$descriptor"
    renice -n "$BA_CPU" -p "$BASHPID" >/dev/null 2>&1 || exit 74
    ionice -c 2 -n "$BA_IO" -p "$BASHPID" >/dev/null 2>&1 || exit 74
    PRIORITY_PREFIX=()
    if [[ "$SCRIPT_ID" == backup_media_remote ]];then
        rsync_label "$label" "$source" "$dest" "$excludes" "${bw:-0}" || rc=$?
        jq -n --arg label "$label" --argjson index "$index" --argjson rc "$rc" --arg reason "${RESULT_REASON[$label]:-Worker interrupted}" --arg error "${BACKUP_LAST_ERROR:-}" --arg raw "${RAW_LOG_BY_LABEL[$label]:-}" \
          --argjson code "${RESULT_CODE[$label]:-1}" --argjson total "${TOTAL_BYTES[$label]:-0}" --argjson transferred "${TRANSFERRED_BYTES[$label]:-0}" --argjson files "${FILES_TRANSFERRED[$label]:-0}" --argjson deleted "${DELETED_FILES[$label]:-0}" --argjson sent "${BYTES_SENT[$label]:-0}" \
          '{label:$label,index:$index,rc:$rc,reason:$reason,error:$error,raw:$raw,code:$code,total:$total,transferred:$transferred,files:$files,deleted:$deleted,sent:$sent}' >"$BA_ROOT/$index.new" || exit 74
    else
        FILES_VERIFIED=0 BYTES_TRANSFERRED=0 VAULT_PROFILE_MANIFEST_MS=0 VAULT_PROFILE_TRANSFER_MS=0 VAULT_PROFILE_VERIFY_MS=0
        VAULT_PROFILE_FILE="$BA_ROOT/$index.profile"
        transfer_job "$label" "$source" "$TMP_DIR/$label.sha256" || rc=$?
        jq -n --arg label "$label" --argjson index "$index" --argjson rc "$rc" --arg fingerprint "${SOURCE_FINGERPRINT[$label]:-}" \
          --argjson files "${MANIFEST_FILES[$label]:-0}" --argjson bytes "${MANIFEST_BYTES[$label]:-0}" --argjson verified "$FILES_VERIFIED" --argjson transferred "$BYTES_TRANSFERRED" \
          --argjson manifestMs "$VAULT_PROFILE_MANIFEST_MS" --argjson transferMs "$VAULT_PROFILE_TRANSFER_MS" --argjson verifyMs "$VAULT_PROFILE_VERIFY_MS" \
          '{label:$label,index:$index,rc:$rc,fingerprint:$fingerprint,files:$files,bytes:$bytes,verified:$verified,transferred:$transferred,manifestMs:$manifestMs,transferMs:$transferMs,verifyMs:$verifyMs}' >"$BA_ROOT/$index.new" || exit 74
    fi
    mv -f -- "$BA_ROOT/$index.new" "$BA_ROOT/$index.json" || exit 74
    return "$rc"
}
ba_accept() {
    local index=$1 descriptor=$2 exit_code=$3 label file value
    label=${descriptor%%|*};file="$BA_ROOT/$index.json"
    if ! jq -e --arg label "$label" --argjson index "$index" --argjson rc "$exit_code" '
      type=="object" and .label==$label and .index==$index and .rc==$rc and
      ([.rc,.files,.transferred]|all(type=="number" and .>=0 and floor==.))' "$file" >/dev/null 2>&1;then
        ba_log "[$label] Worker completion evidence missing or invalid; backup remains incomplete"
        [[ "$SCRIPT_ID" != backup_media_remote ]] || { RESULT_CODE[$label]=74;RESULT_REASON[$label]='Worker evidence unavailable';FAILED_LABELS+=("$label"); }
        return 1
    fi
    if [[ "$SCRIPT_ID" == backup_media_remote ]];then
        for value in code total transferred files deleted sent;do jq -e --arg key "$value" '.[$key]|type=="number" and .>=0 and floor==.' "$file" >/dev/null || return 1;done
        jq -e '(.rc!=0 or .code==0)' "$file" >/dev/null || return 1
        RESULT_CODE[$label]=$(jq -r .code "$file");RESULT_REASON[$label]=$(jq -r .reason "$file")
        TOTAL_BYTES[$label]=$(jq -r .total "$file");TRANSFERRED_BYTES[$label]=$(jq -r .transferred "$file")
        FILES_TRANSFERRED[$label]=$(jq -r .files "$file");DELETED_FILES[$label]=$(jq -r .deleted "$file");BYTES_SENT[$label]=$(jq -r .sent "$file")
        RAW_LOG_BY_LABEL[$label]=$(jq -r .raw "$file")
        ((exit_code==0)) || { BACKUP_LAST_ERROR=$(jq -r .error "$file");FAILED_LABELS+=("$label"); }
    else
        for value in bytes verified manifestMs transferMs verifyMs;do jq -e --arg key "$value" '.[$key]|type=="number" and .>=0 and floor==.' "$file" >/dev/null || return 1;done
        jq -e '(.fingerprint|type=="string" and length>0) and (.rc!=0 or (.verified==.files and .transferred==.bytes))' "$file" >/dev/null || return 1
        MANIFEST_FILES[$label]=$(jq -r .files "$file");MANIFEST_BYTES[$label]=$(jq -r .bytes "$file");SOURCE_FINGERPRINT[$label]=$(jq -r .fingerprint "$file")
        FILES_VERIFIED=$((FILES_VERIFIED+$(jq -r .verified "$file")));BYTES_TRANSFERRED=$((BYTES_TRANSFERRED+$(jq -r .transferred "$file")))
        VAULT_PROFILE_MANIFEST_MS=$((VAULT_PROFILE_MANIFEST_MS+$(jq -r .manifestMs "$file")))
        VAULT_PROFILE_TRANSFER_MS=$((VAULT_PROFILE_TRANSFER_MS+$(jq -r .transferMs "$file")))
        VAULT_PROFILE_VERIFY_MS=$((VAULT_PROFILE_VERIFY_MS+$(jq -r .verifyMs "$file")))
        [[ ! -f "$BA_ROOT/$index.profile" ]] || cat "$BA_ROOT/$index.profile" >>"$TMP_DIR/vault-profile.jsonl" || return 1
    fi
    if ((exit_code!=0));then
        BA_LAST_WORKER_ERROR="[$label] worker exit=$exit_code; completed labels retained; incomplete work remains pending"
        ba_log "$BA_LAST_WORKER_ERROR"
    fi
    ((exit_code==0))
}
ba_disjoint() {
    local descriptor label source dest old seen_labels="|"
    local -a seen=()
    for descriptor in "${BACKUP_JOBS[@]}";do
        IFS='|' read -r label source dest _ <<<"$descriptor"
        [[ "$SCRIPT_ID" == backup_media_remote ]] || dest="$REMOTE_PARTIAL/$label"
        [[ "$label" =~ ^[a-zA-Z0-9_-]+$ && "$source" == /* && "$source" != *'/../'* && "$dest" == /mnt/* && "$dest" != *'/../'* && "$dest" != *'//'* ]] || return 1
        [[ "$seen_labels" != *"|$label|"* ]] || return 1
        seen_labels+="$label|"
        dest=${dest%/}
        for old in "${seen[@]}";do [[ "$dest/" != "$old/"* && "$old/" != "$dest/"* ]] || return 1;done
        seen+=("$dest")
    done
}
ba_pool() {
    local next=0 index count=0 failed=0 rc now last=${BA_LAST_SAMPLE:-0}
    ba_disjoint || { ba_log 'Overlapping or ambiguous destination jobs rejected before transfer';return 1; }
    while ((next<${#BACKUP_JOBS[@]}||count>0));do
        now=$(date +%s)
        if ((now-last>=BACKUP_ADAPTIVE_SAMPLE_SECONDS));then ba_sample;last=$now;fi
        for index in "${!BA_PIDS[@]}";do
            if ! ba_alive "${BA_PIDS[$index]}" "${BA_STAMPS[$index]}";then
                rc=0;wait "${BA_PIDS[$index]}" || rc=$?
                ba_accept "$index" "${BACKUP_JOBS[$index]}" "$rc" || failed=1
                unset 'BA_PIDS[$index]' 'BA_STAMPS[$index]';count=$((count-1))
            fi
        done
        while ((next<${#BACKUP_JOBS[@]}&&count<BA_TARGET));do
            ba_worker "$next" "${BACKUP_JOBS[$next]}" &
            BA_PIDS[$next]=$!;BA_STAMPS[$next]=$(ba_stamp "$!" 2>/dev/null) || BA_STAMPS[$next]='exited'
            count=$((count+1));next=$((next+1));((count<=BA_PEAK)) || BA_PEAK=$count
        done
        ((next>=${#BACKUP_JOBS[@]}&&count==0)) || sleep 1
    done
    BA_POOL_FINISHED=true
    BA_SUMMARY="$BA_WRITE_SUMMARY. Adaptive controls: peak=$BA_PEAK/$BACKUP_ADAPTIVE_MAX_WORKERS jobs; samples=$BA_SAMPLES; unavailable/control events=$BA_DEGRADED; final CPU nice=$BA_CPU, I/O best-effort=$BA_IO. Concurrency reductions drain active work."
    ba_log "$BA_SUMMARY"
    return "$failed"
}
ba_cleanup() {
    local index pid stamp failed=0
    [[ "$BA_ACTIVE" == true || "$BA_REMOTE_READY" == true ]] || return 0
    if [[ "$BA_POOL_FINISHED" != true ]];then
        BA_SUMMARY+=" Unfinished run: peak=$BA_PEAK/$BACKUP_ADAPTIVE_MAX_WORKERS jobs; samples=$BA_SAMPLES; unavailable/control events=$BA_DEGRADED; pending results are not reported as verified."
    fi
    # On interruption, terminate only verified descendants of this run, then reap.
    for index in "${!BA_PIDS[@]}";do
        while read -r pid stamp;do
            ba_alive "$pid" "$stamp" && kill -TERM "$pid" 2>/dev/null || true
        done < <(ba_tree "${BA_PIDS[$index]}" "${BA_STAMPS[$index]}" | tac)
        local attempt
        for ((attempt=0;attempt<10;attempt++));do
            ba_alive "${BA_PIDS[$index]}" "${BA_STAMPS[$index]}" || break;sleep 1
        done
        if ba_alive "${BA_PIDS[$index]}" "${BA_STAMPS[$index]}";then
            while read -r pid stamp;do ba_alive "$pid" "$stamp" && kill -KILL "$pid" 2>/dev/null || true;done < <(ba_tree "${BA_PIDS[$index]}" "${BA_STAMPS[$index]}" | tac)
        fi
        wait "${BA_PIDS[$index]}" 2>/dev/null || true
    done
    BA_PIDS=() BA_STAMPS=()
    if [[ "$BA_REMOTE_READY" == true ]];then
        if [[ "$BACKUP_ISS_RECONSTRUCT_WRITE" == true ]];then
            local write_end
            write_end=$(BACKUP_SSH_COMMAND_TIMEOUT=25 backup_ssh "timeout 20 bash '$BA_REMOTE/helper' write-end") || failed=1
            if [[ -n "$write_end" ]];then BA_WRITE_SUMMARY=$write_end;BA_SUMMARY+=" $write_end";ba_log "$write_end";fi
        fi
        BACKUP_SSH_COMMAND_TIMEOUT=25 backup_ssh "timeout 20 bash '$BA_REMOTE/helper' cleanup" || failed=1
        ((failed!=0)) || BA_REMOTE_READY=false
    fi
    BA_ACTIVE=false
    if ((failed!=0));then BA_SUMMARY+=' ISS cleanup unverified; automatic shutdown prohibited.';return 1;fi
}
