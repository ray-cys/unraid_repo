#!/bin/bash
# Execution audit: consistent receipt snapshots and bounded completion read-back
# avoid false interruption alerts when a worker exits during the audit.
# shellcheck disable=SC2034
clearLog=true
arrayStarted=true
# Backup freshness, delivery and runtime-compatibility audit v1.14.1.
# Schedule: 20 * * * *. Reads local receipts/manifests only: no WOL, remote
# connection, media hashing, container actions or cleanup. One lifecycle email
# for changed findings, recovery, or a 24-hour reminder. Failed delivery retries.
# CLI: bash script [--help|--version]. No CLI modifies backup or application data.
# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="backup_health_audit"
# shellcheck shell=bash
# Embedded operations contract v2; generated into standalone User Scripts.
# Millisecond timing without spawning date on supported Bash; GNU fallback.
usr_ops_now_ms() {
    local stamp="${EPOCHREALTIME:-}"
    if [[ "$stamp" =~ ^[0-9]+\.[0-9]{6}$ ]];then stamp=${stamp/./};printf '%s\n' "${stamp:0:${#stamp}-3}"
    else stamp=$(date +%s%N) || return 1;printf '%s\n' "${stamp:0:${#stamp}-6}";fi
}

usr_ops_log_line() {
    local level="${1^^}" phase="$2" message="$3" line LC_ALL=C
    case "$level" in WARN) level=WARNING;; ERR|FATAL) level=ERROR;; NOTICE) level=INFO;; esac
    message=${message//$'\r'/};message=${message//$'\n'/ | }
    printf -v line '%s | %s | %s | run=%s | phase=%s | %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$OPS_SCRIPT_ID" "${OPS_RUN_ID:-$$}" "$phase" "$message"
    if ((${#line}>4096));then line="${line:0:4050} ... [truncated]";fi
    printf '%s\n' "$line"
}

# Accept the original command, including its timeout, so producer-specific
# delivery/cooldown/acknowledgement semantics stay with the owning script.
usr_ops_notify() {
    local -a args=("$@")
    local i importance=normal summary='' message='' index=-1 status=UPDATE
    for ((i=0;i<${#args[@]};i++));do
        case "${args[$i]}" in
          -i) importance="${args[$((i+1))]:-normal}";;
          -d) summary="${args[$((i+1))]:-}";;
          -m) index=$((i+1));message="${args[$index]:-}";;
        esac
    done
    case "$importance" in alert|warning) status=ATTENTION;;esac
    if [[ "$message" != 'Status: '* ]];then
        message="Status: $status"$'\n'"Summary: $summary"$'\n\n'"Actions and findings:"$'\n'"${message:-$summary}"
        if ((index>=0));then args[$index]="$message";else args+=(-m "$message");fi
    fi
    # Every notifier has a termination escalation, including legacy callers.
    if [[ "${args[0]##*/}" == timeout ]];then
        if [[ " ${args[*]} " != *' --kill-after'* ]];then args=("${args[0]}" --kill-after=5 "${args[@]:1}");fi
    else args=(timeout --signal=TERM --kill-after=5 30 "${args[@]}");fi
    local delivery_rc=0
    "${args[@]}" || delivery_rc=$?
    usr_ops_delivery_record "$delivery_rc" "$importance" "$summary" "$message" "${args[@]}" || printf 'Notification delivery evidence could not be queued; producer failure remains active.\n' >&2
    return "$delivery_rc"
}

# Bounded local history for scripts previously dependent on the plugin console.
usr_ops_append_log() {
    local file="$1" line="$2" max="${3:-2097152}" i
    [[ -d "${file%/*}" && ! -L "$file" ]] || return 1
    for i in 1 2;do [[ ! -L "$file.$i" ]] || return 1;done
    find "${file%/*}" -maxdepth 1 -type f \( -name "${file##*/}.1" -o -name "${file##*/}.2" \) -mtime +29 -delete || return 1
    if [[ -f "$file" ]] && (( $(stat -c %s "$file")+${#line}+1>max ));then
        rm -f "$file.2";[[ ! -f "$file.1" ]] || mv "$file.1" "$file.2";mv "$file" "$file.1" || return 1
    fi
    printf '%s\n' "$line" >>"$file"
}


# Durable failed-delivery evidence for producers without their own outbox.
# Existing media/DNS/watchdog outboxes keep ownership of their delivery policy.
usr_ops_delivery_record() (
    local rc="$1" importance="$2" summary="$3" message="$4" subject='' i key root fd tmp
    shift 4
    case "${OPS_SCRIPT_ID:-}" in backup_boot_disk|backup_cache_appdata|backup_media_remote|backup_vault_remote|backup_restore_drill|media_plex_dbrepair) ;; *) return 0;; esac
    local -a original=("$@")
    local native_delivery=false arg export_fd ram="${USR_OPS_DELIVERY_RAM_ROOT:-/run/user-script-notification-outbox}"
    for arg in "${original[@]}";do [[ "$arg" != /usr/local/emhttp/webGui/scripts/notify ]] || native_delivery=true;done
    [[ "$native_delivery" == true || -n "${USR_OPS_DELIVERY_ROOT:-}" ]] || return 0
    for ((i=0;i<${#original[@]};i++));do [[ "${original[$i]}" != -s ]] || subject="${original[$((i+1))]:-}";done
    root="${USR_OPS_DELIVERY_ROOT:-/mnt/vault/cloud/logs/script/user_scripts_status/notification-outbox}"
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}"
    if ! mountpoint -q "${USR_OPS_VAULT_MOUNT:-/mnt/vault}" || ! flock -s -n "$export_fd";then root="$ram";fi
    [[ ! -L "$root" && $(realpath -m "$root") == "$root" ]] || return 1
    mkdir -p "$root" || return 1;chmod 700 "$root" || return 1
    exec {fd}>"${USR_OPS_DELIVERY_LOCK:-/run/user-script-delivery.lock}";flock -w 3 "$fd" || return 1
    key=$(printf '%s\0' "$OPS_SCRIPT_ID" "$importance" "$subject" "$summary" "$message"|sha256sum|cut -d ' ' -f1)
    if ((rc==0));then
        if [[ "$OPS_SCRIPT_ID" == backup_vault_remote && -n "${USR_OPS_DELIVERY_CONTEXT:-}" ]];then
            mkdir -p "$root/.delivery-receipts" || return 1
            tmp=$(mktemp "$root/.delivery-receipts/.accepted.XXXXXX") || return 1
            jq -n --arg context "$USR_OPS_DELIVERY_CONTEXT" --argjson at "$(date +%s)" '{schema:1,context:$context,acceptedAt:$at}' >"$tmp" && chmod 600 "$tmp" && mv "$tmp" "$root/.delivery-receipts/backup_vault_remote.json" || return 1
        fi
        rm -f -- "$root/$OPS_SCRIPT_ID.$key.json" "$ram/$OPS_SCRIPT_ID.$key.json";return
    fi
    (( $(find "$root" -maxdepth 1 -type f -name '*.json'|wc -l)<100 )) || [[ -f "$root/$OPS_SCRIPT_ID.$key.json" ]] || return 1
    tmp=$(mktemp "$root/.delivery.XXXXXX") || return 1
    trap 'rm -f -- "$tmp"' EXIT
    jq -n --arg context "${USR_OPS_DELIVERY_CONTEXT:-}" --arg id "$key" --arg script "$OPS_SCRIPT_ID" --arg importance "$importance" --arg subject "$subject" --arg summary "$summary" --arg message "$message" --argjson at "$(date +%s)" \
      '{schema:1,context:$context,id:$id,script:$script,importance:$importance,subject:$subject,summary:$summary,message:$message,queuedAt:$at}' >"$tmp" && chmod 600 "$tmp" && mv "$tmp" "$root/$OPS_SCRIPT_ID.$key.json"
)

usr_ops_vault_delivery_seen() {
    local context="$1" cutoff="${2:-0}" root file
    [[ -n "$context" ]] || return 1
    for root in "${USR_OPS_DELIVERY_ROOT:-/mnt/vault/cloud/logs/script/user_scripts_status/notification-outbox}" "${USR_OPS_DELIVERY_RAM_ROOT:-/run/user-script-notification-outbox}";do
        file="$root/.delivery-receipts/backup_vault_remote.json"
        [[ -f "$file" && ! -L "$file" ]] || continue
        jq -e --arg context "$context" --argjson cutoff "$cutoff" --argjson now "$(date +%s)" '.schema==1 and .context==$context and .acceptedAt>=$cutoff and .acceptedAt<=$now+300' "$file" >/dev/null 2>&1 && return 0
    done
    return 1
}

usr_ops_retry_deliveries() {
    local root="${USR_OPS_DELIVERY_ROOT:-/mnt/vault/cloud/logs/script/user_scripts_status/notification-outbox}" file count=0 subject summary message importance owner old_owner="${OPS_SCRIPT_ID:-}" rc=0
    local ram="${USR_OPS_DELIVERY_RAM_ROOT:-/run/user-script-notification-outbox}" digest old_context="${USR_OPS_DELIVERY_CONTEXT:-}" context
    [[ ! -L "$root" && ! -L "$ram" ]] || return 1
    [[ -d "$root" || -d "$ram" ]] || return 0
    while IFS= read -r -d '' file;do
        ((count<3)) || break
        jq -e '(.schema==1) and (.script|test("^(backup_(boot_disk|cache_appdata|media_remote|vault_remote|restore_drill)|media_plex_dbrepair)$")) and (.importance|IN("normal","warning","alert")) and all(.subject,.summary,.message;type=="string")' "$file" >/dev/null 2>&1 || continue
        owner=$(jq -r .script "$file");subject=$(jq -r .subject "$file");summary=$(jq -r .summary "$file");message=$(jq -r .message "$file");importance=$(jq -r .importance "$file")
        context=$(jq -r '.context // ""' "$file")
        if [[ "$owner" == backup_vault_remote ]] && usr_ops_vault_delivery_seen "$context" "$(jq -r .queuedAt "$file")";then rm -f -- "$file";continue;fi
        USR_OPS_DELIVERY_CONTEXT="$context"
        digest=$(sha256sum "$file"|cut -d ' ' -f1)
        OPS_SCRIPT_ID="$owner";count=$((count+1))
        if usr_ops_notify "${NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify}" -i "$importance" -s "$subject" -d "$summary" -m "$message";then
            if [[ -f "$file" && $(sha256sum "$file"|cut -d ' ' -f1) == "$digest" ]];then rm -f -- "$file";fi
        else rc=1;fi
        OPS_SCRIPT_ID="$old_owner";USR_OPS_DELIVERY_CONTEXT="$old_context"
    done < <(find "$root" "$ram" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null|sort -zu)
    return "$rc"
}

# Scheduled executions have an independent parent recording the final exit,
# after producer EXIT traps. CLI operations and sourced libraries are unchanged.
usr_ops_execution_record() (
    local phase="$1" started="$2" pid="$3" rc="${4:-0}" process_start root="${USR_OPS_EXECUTION_ROOT:-/run/user-script-execution}" file tmp now boot old='{}' status
    [[ "${OPS_SCRIPT_ID:-}" =~ ^[a-z0-9_]+$ && ! -L "$root" ]] || return 1
    mkdir -p "$root" || return 1;file="$root/$OPS_SCRIPT_ID.json"
    [[ ! -L "$file" ]] || return 1
    if [[ -f "$file" ]];then old=$(jq -c 'select(.schema==1)' "$file") || old='{}';fi
    [[ -n "$old" ]] || old='{}'
    now=$(date +%s);boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)
    process_start=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')
    [[ "$phase" != finish ]] || process_start=$(jq -r '.processStart // ""' <<<"$old")
    status=RUNNING;[[ "$phase" != finish ]] || { status=COMPLETED;((rc==0)) || status=FAILED; }
    tmp=$(mktemp "$root/.execution.XXXXXX") || return 1;trap 'rm -f -- "$tmp"' EXIT
    jq -n --argjson old "$old" --arg processStart "$process_start" --arg name "$OPS_SCRIPT_ID" --arg boot "$boot" --arg status "$status" --argjson started "$started" --argjson at "$now" --argjson pid "$pid" --argjson rc "$rc" \
      '$old+{schema:1,name:$name,boot:$boot,executionStatus:$status,startedAt:$started,observedAt:$at,pid:$pid,processStart:$processStart,lastExitCode:$rc} |
       if $status!="RUNNING" then .finishedAt=$at|.durationSeconds=($at-$started)|.lastCompletedAt=$at|if $rc==0 then .lastSuccessAt=$at else . end
       else .previousRun={startedAt:$old.startedAt,finishedAt:$old.finishedAt,status:$old.executionStatus,exitCode:$old.lastExitCode,durationSeconds:$old.durationSeconds}|.finishedAt=null|.durationSeconds=null|.lastExitCode=null end' >"$tmp" && chmod 600 "$tmp" && mv "$tmp" "$file" || return 1
    local persistent="${USR_OPS_EXECUTION_PERSISTENT_ROOT:-/mnt/vault/cloud/logs/script/user_scripts_status/execution}" fd export_fd
    mountpoint -q "${USR_OPS_VAULT_MOUNT:-/mnt/vault}" || return 0
    [[ ! -L "$persistent" && $(realpath -m "$persistent") == "$persistent" ]] || return 1
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}";flock -s -n "$export_fd" || return 0
    mkdir -p "$persistent" || return 1
    tmp=$(mktemp "$persistent/.execution.XXXXXX") || return 1
    cp "$file" "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$persistent/$OPS_SCRIPT_ID.json"
)

usr_ops_supervise() {
    local script="$1" started pid='' interrupted='' rc=0 receipt_fd record_owner=false
    # Repository/fixture executions must never publish production evidence.
    # Explicit test roots opt into supervision for isolated regression checks.
    case "$script" in
      /boot/config/plugins/user.scripts/scripts/*/script|/tmp/user.scripts/tmpScripts/*/script) ;;
      *) if [[ -z "${USR_OPS_EXECUTION_ROOT:-}" ]];then USR_OPS_SUPERVISED="$OPS_SCRIPT_ID" /bin/bash "$script";return $?;fi;;
    esac
    local execution_root="${USR_OPS_EXECUTION_ROOT:-/run/user-script-execution}"
    if [[ ! -L "$execution_root" ]] && mkdir -p "$execution_root";then
        exec {receipt_fd}>"$execution_root/$OPS_SCRIPT_ID.lock"
        flock -n "$receipt_fd" && record_owner=true
    fi
    # Register forwarding before launch or receipt I/O. Background Bash may
    # inherit ignored SIGINT, so interactive cancellation uses its TERM cleanup.
    trap 'interrupted=TERM;[[ -z "$pid" ]] || kill -TERM "$pid" 2>/dev/null || true' TERM HUP
    trap 'interrupted=INT;[[ -z "$pid" ]] || kill -TERM "$pid" 2>/dev/null || true' INT
    started=$(date +%s)
    USR_OPS_SUPERVISED="$OPS_SCRIPT_ID" OPS_RUN_ID="${OPS_RUN_ID:-${started}_$$}" /bin/bash "$script" &
    pid=$!
    [[ -z "$interrupted" ]] || kill -TERM "$pid" 2>/dev/null || true
    [[ "$record_owner" != true ]] || usr_ops_execution_record start "$started" "$pid" || printf 'Execution receipt unavailable for %s; workflow continues.\n' "$OPS_SCRIPT_ID" >&2
    wait "$pid" || rc=$?
    # A signal can interrupt wait while the producer is still restoring state.
    if kill -0 "$pid" 2>/dev/null;then wait "$pid" || rc=$?;fi
    if [[ "$interrupted" == INT ]];then rc=130;elif [[ "$interrupted" == TERM ]];then rc=143;fi
    [[ "$record_owner" != true ]] || usr_ops_execution_record finish "$started" "$pid" "$rc" || printf 'Completion receipt unavailable for %s (exit=%s).\n' "$OPS_SCRIPT_ID" "$rc" >&2
    trap - TERM HUP INT
    return "$rc"
}

# Network observation after an accepted shutdown, never a power-state claim.
# No WOL or second poweroff is issued. Native maintenance checks remain upstream.
usr_ops_observe_shutdown() {
    local BACKUP_SSH_COMMAND_TIMEOUT=6
    local host="${REMOTE#*@}" deadline=$(( $(date +%s)+${REMOTE_SHUTDOWN_OBSERVE_SECONDS:-90} )) misses=0
    [[ "${REMOTE_SHUTDOWN_OBSERVE_SECONDS:-90}" != 0 ]] || { SHUTDOWN_RESULT=requested_observation_disabled;return 0; }
    while (( $(date +%s)<deadline ));do
        if timeout --kill-after=1 5 ping -c 1 -W 2 "$host" >/dev/null 2>&1 || backup_ssh true >/dev/null 2>&1;then misses=0
        else misses=$((misses+1));fi
        if ((misses>=3));then SHUTDOWN_RESULT=offline_observed;return 0;fi
        sleep 5
    done
    SHUTDOWN_RESULT=requested_still_reachable;REMOTE_SHUTDOWN_FAILED=1
    return 1
}
# END EMBEDDED OPERATIONS CONTRACT
# BEGIN SCHEDULED EXECUTION SUPERVISOR
if [[ "${BASH_SOURCE[0]}" == "$0" && $# == 0 && "${USR_OPS_SUPERVISED:-}" != "$OPS_SCRIPT_ID" ]];then
    usr_ops_supervise "$0";exit $?
fi
# END SCHEDULED EXECUTION SUPERVISOR
# BEGIN EMBEDDED USER SCRIPTS CATALOG
# shellcheck shell=bash
# Shared User Scripts catalogue v1. Native schedule.json stays authoritative;
# readers also verify the live/restored script file. No schedule is executed.
usr_scripts_catalog() {
    local file="$1" root="${2:-$(dirname "$1")/scripts}" mode="${3:-live}" mapping='{}' native default_cron
    command -v php >/dev/null || { printf '{"schema":1,"valid":false,"detail":"Native PHP runtime unavailable"}\n';return 1; }
    if [[ "$mode" == live ]];then
        native=$(timeout --kill-after=2 8 crontab -c /etc/cron.d -l 2>/dev/null) || native=''
        default_cron=$(timeout --kill-after=2 8 crontab -l 2>/dev/null) || default_cron=''
        native+=$'\n'"$default_cron"
        mapping=$(awk 'NF>=6 && $0 !~ /^[[:space:]]*#/ && /run-parts/ {
          for(i=6;i<=NF;i++)if($i ~ /^\/etc\/cron\.(hourly|daily|weekly|monthly)$/){name=$i;sub(/^.*\./,"",name);print name "\t" $1 " " $2 " " $3 " " $4 " " $5}
        }' <<<"$native" | jq -Rsc 'split("\n")|map(select(length>0)|split("\t")|{key:.[0],value:.[1]})|from_entries') || return 1
    fi
    php /dev/stdin "$file" "$root" "$mode" "$mapping" "${USER_SCRIPTS_RUNNING_ROOT:-/tmp/user.scripts/running}" <<'US_CATALOG_PHP'
<?php
try {
    [$file,$root,$mode,$mapping,$runningRoot]=array_slice($argv,1);
    $mapping=json_decode($mapping,true,512,JSON_THROW_ON_ERROR);
    if(is_link($file)||!is_file($file)||!is_readable($file)||is_link($root)||!is_dir($root)||!is_readable($root))throw new RuntimeException('Schedule file or scripts directory unavailable');
    $raw=file_get_contents($file);$decoded=json_decode($raw,false,512,JSON_THROW_ON_ERROR);
    if(!is_object($decoded))throw new RuntimeException('Schedule root must be an object');
    $data=json_decode($raw,true,512,JSON_THROW_ON_ERROR);$sha=hash('sha256',$raw);$st=stat($root);
    $prefix='/boot/config/plugins/user.scripts/scripts/';$legacy='/usr/local/emhttp/plugins/user.scripts/scripts/';$jobs=[];$installed=[];$roles=[];
    $dir=opendir($root);if(!$dir)throw new RuntimeException('Script inventory unreadable');
    while(($name=readdir($dir))!==false){
        if($name==='.'||$name==='..')continue;$path=$root.'/'.$name.'/script';
        if(is_file($path)&&!is_link($path)&&!is_link(dirname($path))){if(!is_readable($path))throw new RuntimeException('Installed script unreadable');$installed[]=$name;$head=file_get_contents($path,false,null,0,65536);$roles[$name]=preg_match('/^OPS_SCRIPT_ID="([a-z0-9_]+)"\s*$/m',$head,$m)?$m[1]:$name;}
    }closedir($dir);sort($installed);
    $runningNames=[];$uncertainNames=[];
    if($mode==='live'&&is_dir($runningRoot))foreach(glob($runningRoot.'/*')?:[] as $marker){
        $name=basename($marker);if(!is_file($marker)||is_link($marker)||filesize($marker)>64)continue;
        $pid=trim(file_get_contents($marker));if(!ctype_digit($pid)||(int)$pid<=1||!is_dir('/proc/'.$pid))continue;
        $cmd=@file_get_contents('/proc/'.$pid.'/cmdline');if($cmd===false){$uncertainNames[]=$name;continue;}
        if(in_array('/tmp/user.scripts/tmpScripts/'.$name.'/script',explode("\0",$cmd),true)&&str_contains($cmd,'startBackground.php'))$runningNames[]=$name;
    }
    foreach($data as $key=>$entry){
        if(!is_array($entry)||!is_string($entry['frequency']??null))throw new RuntimeException('Schedule entry schema invalid');
        $path=$entry['script']??$key;if(!is_string($path))throw new RuntimeException('Script reference invalid');
        if(str_starts_with($path,$legacy))$path=$prefix.substr($path,strlen($legacy));
        if(!str_starts_with($path,$prefix)||!str_ends_with($path,'/script'))throw new RuntimeException('Script reference outside User Scripts');
        $name=substr($path,strlen($prefix),-strlen('/script'));
        if($name===''||$name==='.'||$name==='..'||preg_match('~[/\\\\\x00-\x1f]~',$name))throw new RuntimeException('Unsafe script name');
        if(str_starts_with((string)$key,$prefix)&&$key!==$path)throw new RuntimeException('Ambiguous schedule key/script identity');
        $physical=$root.'/'.$name.'/script';$present=is_file($physical)&&!is_link($physical)&&!is_link(dirname($physical));
        if((file_exists($physical)||is_link($physical))&&!$present)throw new RuntimeException('Unsupported script file type');
        if($present&&!is_readable($physical))throw new RuntimeException('Script file unreadable');
        $frequency=strtolower(trim($entry['frequency']));$enabled=!in_array($frequency,['','disabled'],true);$event=in_array($frequency,['boot','start','stop'],true);$cron=null;
        if($frequency==='custom'){
            if(!is_string($entry['custom']??null))throw new RuntimeException('Custom schedule missing');
            $value=trim($entry['custom']);$macros=['@hourly'=>'0 * * * *','@daily'=>'0 0 * * *','@midnight'=>'0 0 * * *','@weekly'=>'0 0 * * 0','@monthly'=>'0 0 1 * *','@yearly'=>'0 0 1 1 *','@annually'=>'0 0 1 1 *'];
            if($value==='')$enabled=false;elseif($value==='@reboot')$event=true;else {
                $value=$macros[$value]??$value;$fields=preg_split('/\s+/',$value);
                if(count($fields)!==5||preg_match('~[^0-9A-Za-z*,/\-\s]~',$value))throw new RuntimeException('Custom cron syntax invalid');
                $months=['jan'=>1,'feb'=>2,'mar'=>3,'apr'=>4,'may'=>5,'jun'=>6,'jul'=>7,'aug'=>8,'sep'=>9,'oct'=>10,'nov'=>11,'dec'=>12];$days=['sun'=>0,'mon'=>1,'tue'=>2,'wed'=>3,'thu'=>4,'fri'=>5,'sat'=>6];
                foreach([3=>$months,4=>$days] as $i=>$names)$fields[$i]=preg_replace_callback('/[A-Za-z]+/',function($m)use($names){$n=strtolower($m[0]);if(!isset($names[$n]))throw new RuntimeException('Unknown cron name');return (string)$names[$n];},$fields[$i]);
                foreach([[0,59],[0,23],[1,31],[1,12],[0,7]] as $i=>$limits){foreach(explode(',',$fields[$i]) as $part){if(!preg_match('~^(\\*|[0-9]+(?:-[0-9]+)?)(?:/([0-9]+))?$~D',$part,$q))throw new RuntimeException('Invalid cron field');if(isset($q[2])&&(int)$q[2]<1)throw new RuntimeException('Invalid cron step');if($q[1]!=='*'){$r=explode('-',$q[1]);if((int)$r[0]<$limits[0]||(int)end($r)>$limits[1]||(int)$r[0]>(int)end($r))throw new RuntimeException('Invalid cron range');}}}
                $cron=implode(' ',$fields);
            }
        }elseif(in_array($frequency,['hourly','daily','weekly','monthly'],true))$cron=$mapping[$frequency]??null;
        elseif($enabled&&!$event)throw new RuntimeException('Unknown native schedule frequency');
        $running=in_array($name,$runningNames,true);$unknown=in_array($name,$uncertainNames,true);
        $job=['name'=>$name,'role'=>$roles[$name]??$name,'path'=>$path,'physicalPath'=>$physical,'keys'=>[(string)$key],'present'=>$present,'enabled'=>$enabled,'frequency'=>$frequency,'cron'=>$cron,'event'=>$event,'running'=>$running,'runningUnknown'=>$unknown];
        if(isset($jobs[$path])){foreach(['frequency','cron','event'] as $field)if($jobs[$path][$field]!==$job[$field])throw new RuntimeException('Conflicting duplicate schedule references');$job['keys']=array_merge($jobs[$path]['keys'],$job['keys']);}
        $jobs[$path]=$job;
    }
    if(hash_file('sha256',$file)!==$sha)throw new RuntimeException('Schedule changed during inventory');
    echo json_encode(['schema'=>1,'valid'=>true,'source'=>$file,'sourceSha256'=>$sha,'rootIdentity'=>$st['dev'].':'.$st['ino'],'scriptsRoot'=>$root,'roles'=>(object)$roles,'runningNames'=>$runningNames,'uncertainRunningNames'=>$uncertainNames,'observedAt'=>time(),'installed'=>$installed,'jobs'=>(object)$jobs],JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR);
} catch(Throwable $e) {
    echo json_encode(['schema'=>1,'valid'=>false,'detail'=>$e->getMessage()]);exit(1);
}
US_CATALOG_PHP
}

# Derive freshness from the current native cadence, allowing one missed run and
# caller-specified finish grace. Required job removal never disables evidence.
usr_scripts_due_window() {
    php /dev/stdin "$1" "$2" "$3" "${4:-0}" "${5:-288000}" <<'US_DUE_PHP'
<?php
try {
    [$file,$role,$now,$grace,$fallback]=array_slice($argv,1);$now=(int)$now;$grace=(int)$grace;$fallback=(int)$fallback;
    $c=json_decode(file_get_contents($file),true,512,JSON_THROW_ON_ERROR);
    if(($c['valid']??false)!==true)throw new RuntimeException('Script catalogue unavailable');
    $jobs=array_values(array_filter($c['jobs'],fn($j)=>($j['role']===$role||$j['name']===$role)&&$j['present']&&$j['enabled']));
    if(count($jobs)!==1)throw new RuntimeException('Required job '.$role.' is absent, disabled or ambiguous; configure replacement protection. Existing backup data retained');
    $job=$jobs[0];if($job['event']){echo json_encode(['cutoff'=>$now-$fallback,'source'=>'Event-only job; existing freshness requirement retained']);exit;}
    if(!$job['cron'])throw new RuntimeException('Native job timing unavailable');
    $f=preg_split('/\s+/',$job['cron']);
    function dueValues($expr,$lo,$hi){$out=[];foreach(explode(',',$expr) as $part){if(!preg_match('~^(\*|[0-9]+(?:-[0-9]+)?)(?:/([0-9]+))?$~D',$part,$m))throw new RuntimeException('Invalid cron field');$step=isset($m[2])?(int)$m[2]:1;if($step<1)throw new RuntimeException('Invalid cron step');if($m[1]==='*'){$a=$lo;$b=$hi;}elseif(str_contains($m[1],'-')){[$a,$b]=array_map('intval',explode('-',$m[1]));}else{$a=(int)$m[1];$b=isset($m[2])?$hi:$a;}if($a<$lo||$b>$hi||$b<$a)throw new RuntimeException('Invalid cron range');for($v=$a;$v<=$b;$v+=$step)$out[$v]=true;}return array_keys($out);}
    $mins=dueValues($f[0],0,59);$hours=dueValues($f[1],0,23);$dom=dueValues($f[2],1,31);$months=dueValues($f[3],1,12);$dow=dueValues($f[4],0,7);if(in_array(7,$dow,true))$dow[]=0;
    rsort($mins);rsort($hours);$zone=new DateTimeZone('Asia/Singapore');$day=(new DateTimeImmutable('@'.$now))->setTimezone($zone)->setTime(0,0);$due=[];
    for($d=0;$d<800&&count($due)<2;$d++,$day=$day->modify('-1 day')){if(!in_array((int)$day->format('n'),$months,true))continue;$dm=in_array((int)$day->format('j'),$dom,true);$dw=in_array((int)$day->format('w'),$dow,true);$match=!str_starts_with($f[2],'*')&&!str_starts_with($f[4],'*')?($dm||$dw):($dm&&$dw);if(!$match)continue;foreach($hours as $h)foreach($mins as $m){$at=$day->setTime($h,$m)->getTimestamp();if($at<=$now-$grace){$due[]=$at;if(count($due)===2)break 2;}}}
    if(count($due)!==2)throw new RuntimeException('Recurring cadence could not be established');
    echo json_encode(['cutoff'=>$due[1],'lastDue'=>$due[0],'source'=>'User Scripts cron '.$job['cron'].'; one delayed run and '.($grace%3600===0?($grace/3600).'h':($grace%60===0?($grace/60).'min':$grace.'s')).' finish grace allowed']);
} catch(Throwable $e){echo json_encode(['valid'=>false,'source'=>$e->getMessage()]);exit(1);}
US_DUE_PHP
}

# Two stable observations (>=60s apart), actual file presence and native running
# PID evidence precede pruning. The persistent JSON is authoritative; native RAM
# copy and generated custom cron follow it. No lock file or script payload is removed.
usr_scripts_reconcile() {
    local file="$1" root="$2" actor="$3" now="${4:-$(date +%s)}" catalog fd export_fd rc=0
    mountpoint -q "${USER_SCRIPTS_BOOT_MOUNT:-/boot}" && mountpoint -q "${USER_SCRIPTS_VAULT_MOUNT:-/mnt/vault}" || { printf '{"valid":true,"deferred":true,"detail":"Required mounts unavailable; schedule files preserved","events":[]}\n';return 0; }
    exec {fd}>"${USER_SCRIPTS_REGISTRY_LOCK:-/run/user-scripts-schedule-registry.lock}" || return 1
    if ! flock -n "$fd";then exec {fd}>&-;printf '{"valid":true,"deferred":true,"events":[]}\n';return 0;fi
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || { exec {fd}>&-;return 1; }
    if ! flock -s -n "$export_fd";then exec {fd}>&-;exec {export_fd}>&-;printf '{"valid":true,"deferred":true,"detail":"State export active; schedule files preserved","events":[]}\n';return 0;fi
    catalog=$(mktemp /tmp/user-script-catalog.XXXXXX) || { exec {fd}>&-;exec {export_fd}>&-;return 1; }
    if ! usr_scripts_catalog "$file" "$root" >"$catalog";then cat "$catalog";rm -f "$catalog";exec {fd}>&-;exec {export_fd}>&-;return 1;fi
    php /dev/stdin "$catalog" "$actor" "$now" "${USER_SCRIPTS_REGISTRY_FILE:-/run/user-scripts-schedule-registry.json}" "${USER_SCRIPTS_RUNTIME_SCHEDULE:-/tmp/user.scripts/schedule.json}" "${USER_SCRIPTS_CUSTOM_CRON:-$(dirname "$file")/customSchedule.cron}" "${USER_SCRIPTS_SCHEDULE_ROLLBACK:-/mnt/vault/backup/script_deployments/user-scripts-schedule.previous.json}" <<'US_RECONCILE_PHP'
<?php
try {
    [$catPath,$actor,$now,$statePath,$runtime,$cronPath,$rollback]=array_slice($argv,1);$now=(int)$now;
    $c=json_decode(file_get_contents($catPath),true,512,JSON_THROW_ON_ERROR);$file=$c['source'];$root=$c['scriptsRoot'];
    if($actor==='docker_service_watchdog')foreach($c['jobs'] as $job)if($job['role']==='system_update_coordinator'&&$job['present']&&$job['enabled']){echo json_encode(['valid'=>true,'delegated'=>true,'events'=>[]]);exit;}
    foreach([$file,$runtime,$cronPath,$statePath,$rollback] as $path)if(is_link($path))throw new RuntimeException('Symlink schedule/state path refused');
    $boot=file_get_contents($file);if(hash('sha256',$boot)!==$c['sourceSha256'])throw new RuntimeException('Schedule changed during observation; retry');
    $runtimeRaw=is_file($runtime)?file_get_contents($runtime):null;$cronRaw=is_file($cronPath)?file_get_contents($cronPath):null;
    $fingerprint=hash('sha256',$boot."\0".($runtimeRaw??'MISSING')."\0".($cronRaw??'MISSING')."\0".$c['rootIdentity']);
    $bootId=trim(file_get_contents('/proc/sys/kernel/random/boot_id'));
    $state=is_file($statePath)?json_decode(file_get_contents($statePath),true,512,JSON_THROW_ON_ERROR):['schema'=>1,'events'=>[]];
    if(($state['schema']??0)!==1)throw new RuntimeException('Schedule registry state invalid; original files preserved');
    if(($state['boot']??'')!==$bootId)$state=['schema'=>1,'events'=>[]];
    $same=($state['fingerprint']??'')===$fingerprint;
    $observations=$same?($state['observations']??1):1;$last=$same?($state['lastObserved']??$now):$now;
    if($same&&$now-$last>=60){$observations=min(2,$observations+1);$last=$now;}
    $state['boot']=$bootId;$state['fingerprint']=$fingerprint;$state['observations']=$observations;$state['lastObserved']=$last;
    $priorKnown=$state['knownScripts']??[];$known=$priorKnown;$retired=[];
    if($observations>=2)foreach($known as $name=>$role){if(!in_array($name,$c['installed'],true)&&!in_array($name,$c['runningNames'],true)&&!in_array($name,$c['uncertainRunningNames'],true)){$retired[]=$name;unset($known[$name]);}}
    foreach($c['roles'] as $name=>$role)$known[$name]=$role;
    $state['knownScripts']=(object)$known;
    $data=json_decode($boot,true,512,JSON_THROW_ON_ERROR);$bootObject=json_decode($boot,false,512,JSON_THROW_ON_ERROR);$removed=[];
    if($observations>=2)foreach($c['jobs'] as $job){
      if($job['present']||$job['running']||$job['runningUnknown'])continue;
      if(!preg_match('/^[A-Za-z0-9_.-]+$/D',$job['name']))continue;
      if(file_exists($job['physicalPath'])||is_link($job['physicalPath']))continue;
      foreach($job['keys'] as $key){unset($data[$key]);unset($bootObject->{$key});}$removed[]=$job['name'];
    }
    $desiredBoot=$removed?json_encode($bootObject,JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR):$boot;
    $managed='';
    foreach($c['jobs'] as $job){
      if(in_array($job['name'],$removed,true)||!$job['enabled']||$job['frequency']!=='custom')continue;
      $entry=$data[$job['keys'][0]]??null;if(!$entry)continue;$custom=trim($entry['custom']);if($custom==='')continue;
      $path=$entry['script']??$job['path'];if(!preg_match('~^/[A-Za-z0-9_./-]+$~D',$path))$path=escapeshellarg($path);
      $managed.=$custom.' /usr/local/emhttp/plugins/user.scripts/startCustom.php '.$path." > /dev/null 2>&1\n";
    }
    // Preserve unrelated manual lines; rewrite only this native generated section.
    $extra='';foreach(explode("\n",$cronRaw??'') as $line){if(trim($line)===''||str_starts_with($line,'# Generated cron schedule for user.scripts'))continue;if(!str_starts_with(ltrim($line),'#')&&str_contains($line,'/usr/local/emhttp/plugins/user.scripts/startCustom.php'))continue;$extra.=$line."\n";}
    $desiredCron=$managed!==''||$extra!==''?"# Generated cron schedule for user.scripts\n".$managed.$extra."\n":null;
    $changes=[];if($desiredBoot!==$boot)$changes[$file]=$desiredBoot;if($runtimeRaw!==$desiredBoot)$changes[$runtime]=$desiredBoot;if($cronRaw!==$desiredCron)$changes[$cronPath]=$desiredCron;
    $changed=false;$cronChanged=false;
    function atomicFile($path,$content,$mode=0600){$tmp=tempnam(dirname($path),'.schedule.');if($tmp===false)throw new RuntimeException('Schedule staging failed');$h=fopen($tmp,'wb');if(!$h||fwrite($h,$content)!==strlen($content)){@unlink($tmp);throw new RuntimeException('Schedule write failed');}fflush($h);if(function_exists('fsync'))fsync($h);fclose($h);chmod($tmp,$mode);if(!rename($tmp,$path)){@unlink($tmp);throw new RuntimeException('Schedule publish failed');}}
    if(count($state['events']??[])>=200){$changes=[];$retired=[];$state['knownScripts']=(object)$priorKnown;} // Preserve pending actions; caller drains the outbox first.
    if($changes&&$observations>=2){
      if(!is_dir(dirname($runtime))||!is_dir(dirname($rollback)))throw new RuntimeException('Native runtime/rollback directory unavailable');
      if(hash_file('sha256',$file)!==$c['sourceSha256']||(is_file($runtime)?file_get_contents($runtime):null)!==$runtimeRaw||(is_file($cronPath)?file_get_contents($cronPath):null)!==$cronRaw)throw new RuntimeException('Concurrent schedule edit detected; retry without overwrite');
      foreach($removed as $name)if(file_exists($root.'/'.$name.'/script'))throw new RuntimeException('Script reappeared; retirement cancelled');
      atomicFile($rollback,json_encode(['schema'=>1,'at'=>$now,'source'=>$file,'persistent'=>base64_encode($boot),'runtime'=>$runtimeRaw===null?null:base64_encode($runtimeRaw),'customCron'=>$cronRaw===null?null:base64_encode($cronRaw),'removed'=>$removed],JSON_THROW_ON_ERROR));
      foreach($changes as $path=>$bytes){if($bytes===null){if(is_file($path)&&!unlink($path))throw new RuntimeException('Empty native cron could not be removed');}else{ $mode=is_file($path)?(fileperms($path)&0777):0644;atomicFile($path,$bytes,$mode); }if($path===$cronPath)$cronChanged=true;}
      $changed=true;$state['observations']=0;$state['cronReloadPending']=$cronChanged||($state['cronReloadPending']??false);
    }
    if($changed||$retired){
      $id=hash('sha256',$now.':'.$fingerprint.':'.$desiredBoot.':'.implode(',',$retired));
      $state['events'][]=['id'=>$id,'at'=>$now,'actor'=>$actor,'removed'=>array_values(array_unique(array_merge($removed,$retired))),'pruned'=>$removed,'runtimeSynced'=>array_key_exists($runtime,$changes),'cronUpdated'=>$cronChanged];
    }
    atomicFile($statePath,json_encode($state,JSON_THROW_ON_ERROR));
    echo json_encode(['valid'=>true,'changed'=>$changed,'events'=>$state['events']??[],'cronReloadPending'=>$state['cronReloadPending']??false]);
} catch(Throwable $e){echo json_encode(['valid'=>false,'detail'=>$e->getMessage(),'events'=>[]]);exit(1);}
US_RECONCILE_PHP
    rc=$?
    rm -f -- "$catalog"
    exec {fd}>&-;exec {export_fd}>&-
    return "$rc"
}

usr_scripts_registry_ack() {
    local ids="$1" reload="${2:-false}" fd state="${USER_SCRIPTS_REGISTRY_FILE:-/run/user-scripts-schedule-registry.json}" tmp rc=0
    exec {fd}>"${USER_SCRIPTS_REGISTRY_LOCK:-/run/user-scripts-schedule-registry.lock}" || return 1
    flock -w 5 "$fd" || { exec {fd}>&-;return 1; }
    tmp=$(mktemp "$(dirname "$state")/.schedule-registry.XXXXXX") || { exec {fd}>&-;return 1; }
    jq --argjson ids "$ids" --argjson reload "$reload" '.events|=map(select(.id as $id|($ids|index($id))==null)) | if $reload then .cronReloadPending=false else . end' "$state" >"$tmp" && chmod 600 "$tmp" && mv "$tmp" "$state" || rc=$?
    rm -f -- "$tmp";exec {fd}>&-;return "$rc"
}

# A producer's receipt describes its current native schedule, not a copied cron.
usr_scripts_schedule_evidence() {
    local role="$1" file="${USER_SCRIPTS_SCHEDULE_FILE:-/boot/config/plugins/user.scripts/schedule.json}" tmp window
    tmp=$(mktemp /tmp/user-script-schedule.XXXXXX) || return 1
    if usr_scripts_catalog "$file" "${USER_SCRIPTS_PHYSICAL_ROOT:-$(dirname "$file")/scripts}" >"$tmp";then
        window=$(usr_scripts_due_window "$tmp" "$role" "$(date +%s)" 0 288000) || window='{}'
        jq -c --arg role "$role" --argjson window "$window" '[.jobs[]|select((.role==$role or .name==$role) and .present and .enabled)] |
          if length==1 then .[0]|{verified:true,cron,frequency,event,timezone:"Asia/Singapore",intervalSeconds:(if ($window.lastDue|type)=="number" and ($window.cutoff|type)=="number" then $window.lastDue-$window.cutoff else null end)} else {verified:false,reason:"Enabled schedule missing or ambiguous"} end' "$tmp"
    else printf '{"verified":false,"reason":"Native schedule inventory unavailable"}\n';fi
    rm -f -- "$tmp"
}

# Compare normalized timing and exact launcher paths without evaluating shell.
# A cached schedule or matching path alone does not prove correct dispatch.
usr_scripts_verify_cron() {
    php /dev/stdin "$1" "$2" "${USER_SCRIPTS_NATIVE_HOOK_ROOT:-/usr/local/emhttp/plugins/user.scripts/cron}" <<'US_CRON_VERIFY'
<?php
try {
 [$catalogFile,$cronFile,$hooks]=array_slice($argv,1);$c=json_decode(file_get_contents($catalogFile),true,512,JSON_THROW_ON_ERROR);
 if(($c['valid']??false)!==true||!is_file($cronFile)||!is_readable($cronFile))throw new RuntimeException('Live scheduling evidence unavailable');
 function pathArg($s){$out='';$quote=null;$n=strlen($s);for($i=0;$i<$n;$i++){$ch=$s[$i];if($quote==="'"){if($ch==="'")$quote=null;else $out.=$ch;}elseif($quote==='"'){if($ch==='"')$quote=null;elseif($ch==='$'||$ch==='`')throw new RuntimeException('Expansion in launcher path refused');elseif($ch==='\\'&&$i+1<$n)$out.=$s[++$i];else $out.=$ch;}else{if($ch==="'"||$ch==='"')$quote=$ch;elseif($ch==='\\'&&$i+1<$n)$out.=$s[++$i];elseif(ctype_space($ch)||str_contains('$`;|&<>',$ch))throw new RuntimeException('Unexpected launcher arguments');else $out.=$ch;}}if($quote!==null)throw new RuntimeException('Unclosed launcher quoting');return $out;}
 function cronSignature($s){$s=trim(strtolower($s));$macros=['@hourly'=>'0 * * * *','@daily'=>'0 0 * * *','@midnight'=>'0 0 * * *','@weekly'=>'0 0 * * 0','@monthly'=>'0 0 1 * *','@yearly'=>'0 0 1 1 *','@annually'=>'0 0 1 1 *'];if($s==='@reboot')return 'reboot';$s=$macros[$s]??$s;$f=preg_split('/\s+/',$s);if(count($f)!==5)throw new RuntimeException('Unexpected cron field count');$names=[3=>['jan'=>1,'feb'=>2,'mar'=>3,'apr'=>4,'may'=>5,'jun'=>6,'jul'=>7,'aug'=>8,'sep'=>9,'oct'=>10,'nov'=>11,'dec'=>12],4=>['sun'=>0,'mon'=>1,'tue'=>2,'wed'=>3,'thu'=>4,'fri'=>5,'sat'=>6]];foreach($names as $i=>$map)$f[$i]=preg_replace_callback('/[a-z]+/',fn($m)=>isset($map[$m[0]])?(string)$map[$m[0]]:throw new RuntimeException('Unknown cron name'),$f[$i]);$result=[];foreach([[0,59],[0,23],[1,31],[1,12],[0,7]] as $i=>[$lo,$hi]){$values=[];foreach(explode(',',$f[$i]) as $piece){if(!preg_match('~^(\*|[0-9]+(?:-[0-9]+)?)(?:/([0-9]+))?$~D',$piece,$m))throw new RuntimeException('Invalid cron expression');$step=(int)($m[2]??1);if($step<1)throw new RuntimeException('Invalid cron step');if($m[1]==='*'){$a=$lo;$b=$hi;}elseif(str_contains($m[1],'-'))[$a,$b]=array_map('intval',explode('-',$m[1]));else{$a=(int)$m[1];$b=isset($m[2])?$hi:$a;}if($a<$lo||$b>$hi||$a>$b)throw new RuntimeException('Cron value out of range');for($v=$a;$v<=$b;$v+=$step)$values[$i===4&&$v===7?0:$v]=true;}ksort($values);$result[]=array_keys($values);}$result[]=[str_starts_with($f[2],'*'),str_starts_with($f[4],'*')];return json_encode($result);}
 $actual=[];$issues=[];
 foreach(explode("\n",file_get_contents($cronFile)) as $line){if(trim($line)===''||preg_match('/^\s*#/',$line)||!str_contains($line,'/user.scripts/startCustom.php'))continue;
  if(!preg_match('~^\s*(.*?)\s+/usr/local/emhttp/plugins/user\.scripts/startCustom\.php\s+(.+?)\s+>\s*/dev/null\s+2>&1\s*$~D',$line,$m)){$issues[]='Unrecognized User Scripts launcher line; no shell code executed';continue;}
  try{$path=pathArg($m[2]);$path=preg_replace('~^/usr/local/emhttp/plugins/user\.scripts/scripts/~','/boot/config/plugins/user.scripts/scripts/',$path);$actual[$path][]=cronSignature($m[1]);}catch(Throwable $e){$issues[]='Invalid live launcher timing/path: '.$e->getMessage();}
 }
 $wanted=[];
 foreach($c['jobs'] as $job){if(!$job['present']||!$job['enabled'])continue;
  if($job['frequency']==='custom'){$path=$job['path'];$wanted[$path]=true;$expected=cronSignature($job['event']?'@reboot':($job['cron']??''));if(!isset($actual[$path]))$issues[]=$job['name'].': active launcher missing';elseif(count($actual[$path])!==1)$issues[]=$job['name'].': duplicate live launchers';elseif($actual[$path][0]!==$expected)$issues[]=$job['name'].': live cron timing differs from schedule.json';}
  elseif(in_array($job['frequency'],['hourly','daily','weekly','monthly'],true)){if(!$job['cron'])$issues[]=$job['name'].': native dispatcher timing unavailable';$hook=$hooks.'/user.script.start.'.$job['frequency'].'.sh';if(!is_readable($hook)||!str_contains(file_get_contents($hook),'startSchedule.php'))$issues[]=$job['name'].': native dispatcher hook unavailable';}
 }
 foreach($actual as $path=>$times)if(!isset($wanted[$path]))$issues[]='Launcher has no installed enabled schedule: '.$path;
 echo json_encode(['schema'=>1,'valid'=>!$issues,'checkedAt'=>time(),'issues'=>array_values(array_unique($issues))],JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR);
 if($issues)exit(1);
}catch(Throwable $e){echo json_encode(['schema'=>1,'valid'=>false,'issues'=>[$e->getMessage()]]);exit(1);}
US_CRON_VERIFY
}
# END EMBEDDED USER SCRIPTS CATALOG
set -uo pipefail
readonly SCRIPT_VERSION="1.14.1"
STATUS_DIR="${STATUS_DIR:-/mnt/vault/cloud/logs/script/user_scripts_status}"
STATE_DIR="${STATE_DIR:-/mnt/vault/cloud/logs/script/backup_health_audit}"
APPDATA_ROOT="${APPDATA_ROOT:-/mnt/vault/backup/cache}"
FLASH_ROOT="${FLASH_ROOT:-/mnt/vault/backup/flash}"
REMOTE_LOG_ROOT="${REMOTE_LOG_ROOT:-/mnt/vault/cloud/logs/script/backup_media_remote}"
UNRAID_VERSION_FILE="${UNRAID_VERSION_FILE:-/etc/unraid-version}"
DISK_HEALTH_RECEIPT="${DISK_HEALTH_RECEIPT:-/mnt/vault/cloud/logs/script/health_monitoring/state/monitor_receipt.json}"
DISK_HEALTH_MAX_AGE_SECONDS=$((30*3600))
NOTIFY_BIN="${NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify}"
APPDATA_MAX_AGE_SECONDS=$((80*3600))
FLASH_MAX_AGE_SECONDS=$((80*3600))
MIRROR_MAX_AGE_SECONDS=$((8*86400))
DRILL_MAX_AGE_SECONDS=$((8*86400))
ISS_PENDING_MAX_AGE_SECONDS=$((6*3600))
REMINDER_SECONDS=86400
LOG_MAX_BYTES=262144
NOW=$(date +%s)
FINDINGS=()
ACTIONS=()
RUNTIME_SAFE=true
PLATFORM_VERSION=unknown

finding() { FINDINGS+=("$*"); }
audit_log() { local line;line=$(usr_ops_log_line INFO audit "$*");printf '%s\n' "$line";usr_ops_append_log "$STATE_DIR/audit.log" "$line" "$LOG_MAX_BYTES"; }
latest_path() {
    find "$1" -mindepth 1 -maxdepth 1 -type "$2" -name "$3" ! -name '*.partial' ! -name '*.failed' -printf '%f\n' 2>/dev/null | sort | tail -n 1
}
check_age() {
    local label="$1" epoch="$2" limit="$3" role="${4:-}" grace="${5:-0}" window cutoff
    if ! [[ "$epoch" =~ ^[0-9]+$ ]] || (( epoch==0 )); then finding "$label: no successful completion evidence"; return; fi
    if [[ -n "$role" && -n "${AUDIT_CATALOG_FILE:-}" ]] && jq -e '.valid==true' "$AUDIT_CATALOG_FILE" >/dev/null 2>&1;then
        if window=$(usr_scripts_due_window "$AUDIT_CATALOG_FILE" "$role" "$NOW" "$grace" "$limit");then
            cutoff=$(jq -r .cutoff <<<"$window")
            if ((epoch>NOW+300));then finding "$label: future-dated receipt; clock/evidence review required"
            elif ((epoch<cutoff));then finding "$label: completion overdue against its current User Scripts schedule";ACTIONS+=("$label: $(jq -r .source <<<"$window")");fi
        else finding "$label: current scheduled protection is missing or cannot be validated; existing data retained";fi
        return
    fi
    if (( epoch>NOW+300 )); then finding "$label: future-dated receipt; clock/evidence review required"
    elif (( NOW-epoch>limit )); then finding "$label: completion is overdue (limit=$((limit/3600)) hours)"; ACTIONS+=("$label: last completion $(((NOW-epoch)/3600)) hours ago."); fi
}
audit_script_active() {
    local role="$1"
    [[ -n "${AUDIT_CATALOG_FILE:-}" && -s "$AUDIT_CATALOG_FILE" ]] || return 0
    jq -e '.valid==true' "$AUDIT_CATALOG_FILE" >/dev/null || return 0
    jq -e --arg role "$role" 'any(.jobs[];(.role==$role or .name==$role) and .present and .enabled)' "$AUDIT_CATALOG_FILE" >/dev/null
}

audit_disk_health_monitor() {
    audit_script_active health_monitoring || { ACTIONS+=("Optional health_monitoring checks retired: script absent or disabled; prior receipts retained");return 0; }
    local epoch
    epoch=$(jq -er 'select(.schema == 1) | .lastCompleteEpoch | numbers' "$DISK_HEALTH_RECEIPT" 2>/dev/null) || epoch=0
    check_age 'Disk health monitor' "$epoch" "$DISK_HEALTH_MAX_AGE_SECONDS" health_monitoring 7200
    if jq -e '.schema == 1 and .notification == "failed"' "$DISK_HEALTH_RECEIPT" >/dev/null 2>&1; then
        finding 'Disk health monitor: the latest notification could not be delivered'
    fi
}
audit_media_integrity_monitor() {
    audit_script_active media_integrity_audit || { ACTIONS+=("Optional media_integrity_audit checks retired: script absent or disabled; prior receipts retained");return 0; }
    local receipt="$STATUS_DIR/media_integrity_audit.json" completed first max_gap progress
    if ! jq -e '.schema==1 and (.lastCompletedScanAt|type)=="number" and (.firstScheduledAt|type)=="number"' "$receipt" >/dev/null 2>&1; then
        finding 'Media integrity audit: completion/schedule receipt missing or invalid';return
    fi
    completed=$(jq -r 'if .evidenceSchema==2 then (.lastRealScanAt // 0) else .lastCompletedScanAt end' "$receipt");first=$(jq -r .firstScheduledAt "$receipt")
    progress=$(jq -r --argjson now "$NOW" '(if .evidenceSchema==2 then .lastDecodeProgressAt else .lastProgressScanAt end) as $p | if ($p|type)=="number" and $p>0 and $p<=$now+300 then $p else 0 end' "$receipt")
    ((progress<=completed)) || completed="$progress"
    max_gap=$(jq -r '.schedule.maxGapSeconds // 691200' "$receipt")
    [[ "$max_gap" =~ ^[1-9][0-9]*$ ]] && ((max_gap>=86400 && max_gap<=1382400)) || max_gap=691200
    if (( completed>0 )); then check_age 'Media integrity audit completion/progress' "$completed" "$max_gap" media_integrity_audit 10800
    elif (( first<=0 || NOW>first+86400 )); then finding 'Media integrity audit: first scheduled scan has not completed within its grace period';fi
    if jq -e '.notification=="failed"' "$receipt" >/dev/null; then finding 'Media integrity audit: grouped notification delivery failed; pending report retained';fi
    # Individual media findings remain owned by the scheduled audit, not repeated
    # in this hourly backup/runtime notification stream.
}

audit_media_coordination() {
    local receipt="$STATUS_DIR/media_metadata_audit.json" epoch
    if ! audit_script_active media_metadata_audit;then
      ACTIONS+=("Optional metadata audit checks retired: script absent or disabled; prior receipts retained")
    elif jq -e '(.epoch|type)=="number"' "$receipt" >/dev/null 2>&1;then
      epoch=$(jq -r .epoch "$receipt");check_age 'Media metadata audit invocation' "$epoch" "$((8*3600))" media_metadata_audit 1800
      [[ $(jq -r '.weeklyReportStatus // "OK"' "$receipt") != FAILED ]] || finding 'Media metadata weekly reporting failed; exact pending report retained for retry'
    else finding 'Media metadata audit: valid run receipt missing';fi
    receipt="$STATUS_DIR/media_integrity_audit.json"
    if audit_script_active media_integrity_audit && jq -e '(.stalledCompletedRuns // 0)>=3 and (.progress.capacity.attention // false)!=true' "$receipt" >/dev/null 2>&1;then finding 'Media integrity audit: three completed scans made no measurable coverage progress; review resource holds and scan budget';fi
}

audit_update_coordinator() {
    audit_script_active system_update_coordinator || { ACTIONS+=("Optional system_update_coordinator checks retired: script absent or disabled; prior receipts retained");return 0; }
    local state="${UPDATE_COORDINATOR_STATE_FILE:-/mnt/vault/cloud/logs/script/system_update_coordinator/state.json}" epoch installed
    if ! jq -e '.schema==1 and (.jobs|type)=="object" and (.installedAt|type)=="number"' "$state" >/dev/null 2>&1;then
      finding 'System update coordinator: valid journal missing; automatic-update supervision unavailable';return
    fi
    epoch=$(jq -r '.lastAutomaticRunAt // 0' "$state");installed=$(jq -r .installedAt "$state")
    if ((epoch>0));then check_age 'System update coordinator scheduled run' "$epoch" 10800 system_update_coordinator 900
    elif ((NOW>installed+10800));then finding 'System update coordinator: first automatic run overdue; CLI inspection does not count as scheduled execution';fi
    if jq -e --argjson now "$NOW" 'any(.jobs[];.status=="ATTENTION" or (.status=="INTENT" and (.dispatchedAt // 0)<$now-1200))' "$state" >/dev/null;then
      finding 'System update coordinator: unresolved installation outcome; further updates and affected watchdog recovery held for review'
    fi
    # Only sealed report pages and urgent events are due for delivery. Normal
    # late receipts wait for the next daily summary without becoming a failure.
    if jq -e --argjson now "$NOW" '(.normalDeliveryIds // []) as $batch | any(.outbox[]; . as $event | (.at // 0)<$now-1800 and (.importance!="normal" or ($batch|index($event.id))!=null))' "$state" >/dev/null;then
      finding 'System update coordinator: action report pending delivery; exact evidence remains queued'
    fi
}

audit_runtime() {
    local command version major missing=false
    for command in bash curl jq flock timeout rsync tar unzip sha256sum find sort stat df realpath docker smartctl findmnt mountpoint; do
        if ! command -v "$command" >/dev/null; then finding "Compatibility: required host command unavailable: $command"; missing=true; fi
    done
    PLATFORM_VERSION=$(sed -n 's/^version="\([^"]*\)"/\1/p' "$UNRAID_VERSION_FILE" 2>/dev/null)
    [[ -n "$PLATFORM_VERSION" ]] || PLATFORM_VERSION=unknown
    major=${PLATFORM_VERSION%%.*}
    if [[ "$major" != 7 ]]; then
        finding "Compatibility: Unraid $PLATFORM_VERSION is outside the validated 7.x family. Validate User Scripts scheduling, notification/boot hooks, Docker permissions and Mover interfaces before destructive automation. No compatibility approval inferred."
        missing=true
    fi
    # GNU find version is a standalone option, without a starting path.
    # shellcheck disable=SC2185
    if ! find --version 2>/dev/null | head -n 1 | grep -q GNU; then finding 'Compatibility: GNU find interface unavailable'; missing=true; fi
    if ! stat --version 2>/dev/null | head -n 1 | grep -q GNU; then finding 'Compatibility: GNU stat interface unavailable'; missing=true; fi
    version=$(rsync --version 2>/dev/null | head -n 1)
    if ! awk '{split($3,v,".");exit !(v[1]>3 || (v[1]==3 && v[2]>=1))}' <<<"$version"; then finding 'Compatibility: rsync >=3.1 required on Hubble; ISS is checked during transfers'; missing=true; fi
    [[ -x "$NOTIFY_BIN" ]] || { finding 'Compatibility: Unraid notification helper unavailable; notifications cannot be delivered'; missing=true; }
    if ! timeout 15 docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then finding 'Compatibility: Docker daemon/API unavailable'; missing=true; fi
    local path cron
    for path in /mnt/user /mnt/cache /mnt/data /mnt/vault /mnt/ramlogs; do
        mountpoint -q "$path" || { finding "Compatibility: required filesystem is not mounted: $path"; missing=true; }
    done
    cron=$(timeout 8 crontab -c /etc/cron.d -l 2>/dev/null) || { cron=""; finding 'Compatibility: active Unraid cron inventory unavailable'; missing=true; }
    AUDIT_CATALOG_FILE=$(mktemp /tmp/backup-audit-scripts.XXXXXX) || { finding 'Scheduling: script catalogue staging unavailable';RUNTIME_SAFE=false;return; }
    if ! usr_scripts_catalog "${USER_SCRIPTS_SCHEDULE_FILE:-/boot/config/plugins/user.scripts/schedule.json}" "${USER_SCRIPTS_PHYSICAL_ROOT:-/boot/config/plugins/user.scripts/scripts}" >"$AUDIT_CATALOG_FILE";then
      finding 'Scheduling: native schedule or script inventory invalid; existing files preserved';missing=true
    else
      for path in backup_cache_appdata backup_boot_disk backup_media_remote backup_vault_remote;do
        jq -e --arg role "$path" 'any(.jobs[];(.role==$role or .name==$role) and .present and .enabled)' "$AUDIT_CATALOG_FILE" >/dev/null || { finding "Scheduling: required backup protection missing or disabled: $path; replacement required";missing=true; }
      done
      local live_cron="$AUDIT_CATALOG_FILE.cron" verification="$AUDIT_CATALOG_FILE.verification" issue
      printf '%s\n' "$cron" >"$live_cron"
      if ! usr_scripts_verify_cron "$AUDIT_CATALOG_FILE" "$live_cron" >"$verification";then
        while IFS= read -r issue;do finding "Scheduling: $issue";done < <(jq -r '.issues[]?' "$verification")
        missing=true
      fi
      rm -f -- "$live_cron" "$verification"
      local orphans
      orphans=$(jq '[.jobs[]|select(.present|not)]|length' "$AUDIT_CATALOG_FILE")
      ((orphans==0)) || ACTIONS+=("Scheduling: $orphans absent-script reference(s) excluded from active checks; registry will retire confirmed leftovers")
    fi
    [[ "$missing" != true ]] || RUNTIME_SAFE=false
}
# Only inspect metadata after the first recovery-enabled export. Old snapshots
# are not retroactively treated as broken, and this audit never wakes ISS.
audit_recovery_inventory() {
    local root="${RECOVERY_BUNDLE_ROOT:-/mnt/vault/backup/operations_state/recovery}" status volumes
    [[ -e "$root" ]] || return 0
    if [[ -L "$root" ]] || ! jq -e '.schema==1 and (.runtimeStatus|type=="string") and (.namedVolumeMounts|type=="number")' "$root/inventory.json" >/dev/null 2>&1; then
        finding 'Recovery inventory: missing or invalid metadata; previous data backups are not reclassified'; return
    fi
    status=$(jq -r .runtimeStatus "$root/inventory.json")
    volumes=$(jq -r .namedVolumeMounts "$root/inventory.json")
    [[ "$status" == complete ]] || finding "Recovery inventory: Docker capture $status; runtime reconstruction evidence incomplete"
    (( volumes==0 )) || finding "Recovery inventory: $volumes named-volume mount(s) need explicit payload-backup review"
    ACTIONS+=("Recovery inventory: runtime=$status; named-volume mounts=$volumes. Metadata read only; payload checks remain the producer/restore drill responsibility.")
}

# Execution evidence is independent from each producer's domain result. A
# completed invocation does not certify backup/media payload integrity.
execution_finding() {
    local role="$1";shift
    if [[ "$role" == media_torrent_management ]];then audit_log "Console-only torrent execution finding: $*";else finding "$*";fi
}

# Read one atomic receipt generation. A short-lived worker may exit before its
# supervising parent publishes completion; re-read that narrow handoff before
# reporting an interruption. Never mix PID/status/timestamps from different runs.
audit_execution_worker_active() {
    local record="$1" boot="$2" pid process_start
    pid=$(jq -r .pid "$record")
    [[ "$pid" =~ ^[1-9][0-9]*$ && $(jq -r .boot "$record") == "$boot" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    process_start=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null|awk '{print $20}') || return 1
    [[ -n "$process_start" && "$process_start" == $(jq -r '.processStart // ""' "$record") ]]
}
audit_snapshot_execution() {
    local source="$1" snapshot="$2" boot="$3" attempt status
    AUDIT_EXECUTION_WORKER_ACTIVE=false
    for attempt in 0 1 2;do
      jq -ce 'select(type=="object")' "$source" >"$snapshot" || return 1
      jq -e '.schema==1 and (.executionStatus|IN("RUNNING","COMPLETED","FAILED")) and (.startedAt|type)=="number"' "$snapshot" >/dev/null || return 1
      status=$(jq -r .executionStatus "$snapshot")
      [[ "$status" == RUNNING ]] || return 0
      if audit_execution_worker_active "$snapshot" "$boot";then AUDIT_EXECUTION_WORKER_ACTIVE=true;return 0;fi
      # A previous boot is definite interruption, not a closing-parent race.
      [[ $(jq -r .boot "$snapshot") == "$boot" ]] || return 0
      ((attempt==2)) || sleep 1
    done
    return 0
}

audit_script_executions() {
    [[ -s "${AUDIT_CATALOG_FILE:-}" ]] || return 0
    local name role record epoch window cutoff now="$NOW" pid boot status first grace max_active native_summary inventory="$STATE_DIR/execution-inventory.json" tmp
    [[ -f "$inventory" ]] || printf '{"schema":1,"scripts":{}}' >"$inventory"
    tmp=$(mktemp "$STATE_DIR/.execution-inventory.XXXXXX") || return 1
    jq --slurpfile catalog "$AUDIT_CATALOG_FILE" --argjson now "$NOW" '.scripts as $old | .scripts=([$catalog[0].jobs[]|select(.present and .enabled)|{key:.name,value:($old[.name] // {firstSeen:$now})}]|from_entries)' "$inventory" >"$tmp" && mv "$tmp" "$inventory" || return 1
    boot=$(cat /proc/sys/kernel/random/boot_id)
    AUDIT_EXECUTION_SNAPSHOT=$(mktemp /tmp/backup-health-execution.XXXXXX) || return 1
    local source_record
    while IFS=$'\t' read -r name role;do
        [[ "$role" != backup_health_audit ]] || continue
        record="${USR_OPS_EXECUTION_ROOT:-/run/user-script-execution}/$role.json"
        [[ -f "$record" ]] || record="$STATUS_DIR/execution/$role.json"
        first=$(jq -r --arg name "$name" '.scripts[$name].firstSeen' "$inventory")
        grace=600
        case "$role" in backup_cache_appdata|health_monitoring) grace=7200;;backup_media_remote|backup_vault_remote) grace=21600;;media_integrity_audit) grace=10800;;media_cleanup) grace=3600;;media_plex_dbrepair) grace=21600;;esac
        window=$(usr_scripts_due_window "$AUDIT_CATALOG_FILE" "$role" "$NOW" "$grace" 288000) || { execution_finding "$role" "$name: execution cadence could not be validated";continue; }
        cutoff=$(jq -r .cutoff <<<"$window")
        if [[ ! -f "$record" ]];then
            ((first>=cutoff)) || execution_finding "$role" "$name: no completion receipt after two eligible schedule occurrences and finish grace"
            continue
        fi
        source_record="$record"
        if ! audit_snapshot_execution "$source_record" "$AUDIT_EXECUTION_SNAPSHOT" "$boot";then execution_finding "$role" "$name: execution receipt invalid; previous workflow data retained";continue;fi
        record="$AUDIT_EXECUTION_SNAPSHOT"
        status=$(jq -r .executionStatus "$record");epoch=$(jq -r '.lastCompletedAt // 0' "$record")
        if [[ "$status" == FAILED ]];then
          native_summary=$(jq -r '.summary // "No separate producer summary was saved"' "$STATUS_DIR/$role.json" 2>/dev/null) || native_summary='No separate producer summary was saved'
          [[ "$role" != media_health_monitor ]] || native_summary=$(jq -r '.monitor.lastError // "Monitor exited before publishing a detailed failure"' /mnt/vault/cloud/logs/script/media_health_monitor/state.json 2>/dev/null)
          execution_finding "$role" "$name: latest execution failed (exit=$(jq -r .lastExitCode "$record")). Outcome: ${native_summary:0:1500}"
        fi
        if [[ "$status" == RUNNING ]];then
            if [[ "$AUDIT_EXECUTION_WORKER_ACTIVE" != true ]];then
                execution_finding "$role" "$name: recorded execution ended without a completion receipt after bounded read-back; review interruption evidence"
                continue
            fi
            # Report overruns without terminating active backup/database work.
            max_active=$((grace*2));((max_active>=1800)) || max_active=1800
            case "$role" in backup_cache_appdata) max_active=21600;;backup_boot_disk) max_active=14400;;backup_media_remote|backup_vault_remote) max_active=86400;;media_plex_dbrepair) max_active=43200;;esac
            if ((NOW-$(jq -r .startedAt "$record")>max_active));then execution_finding "$role" "$name: execution remains active beyond its $((max_active/60))-minute allowance; no termination or replay was attempted";fi
            continue
        fi
        ((first>=cutoff || epoch>=cutoff)) || execution_finding "$role" "$name: no completed invocation within its current schedule allowance"
    done < <(jq -r '.jobs[]|select(.present and .enabled)|[.name,.role]|@tsv' "$AUDIT_CATALOG_FILE")
    rm -f -- "$AUDIT_EXECUTION_SNAPSHOT";AUDIT_EXECUTION_SNAPSHOT=''
    local pending count
    pending="${USR_OPS_DELIVERY_ROOT:-$STATUS_DIR/notification-outbox}"
    count=$({ find "$pending" "${USR_OPS_DELIVERY_RAM_ROOT:-/run/user-script-notification-outbox}" -maxdepth 1 -type f -name '*.json' 2>/dev/null || true; }|wc -l)
    ((count==0)) || finding "Notifications: $count producer report(s) remain pending delivery; hourly bounded retries preserve exact details"
    local availability="${MEDIA_HEALTH_STATE_DIR:-/mnt/vault/cloud/logs/script/media_health_monitor}/maintenance-availability.json" row
    if [[ -f "$availability" ]] && jq -e --argjson now "$NOW" '.epoch>$now-600' "$availability" >/dev/null;then
      while IFS= read -r row;do finding "$row: read-only service probe failed during unrelated maintenance; no recovery action was attempted";done < <(jq -r '.services[]|select(.ready==false and .expectedMaintenance==false)|.app' "$availability")
    fi
    local operation=/mnt/vault/cloud/logs/script/media_plex_dbrepair/active-operation.json operation_pid
    if [[ -f "$operation" ]];then
      operation_pid=$(jq -r '.pid // 0' "$operation" 2>/dev/null)
      if ! [[ "$operation_pid" =~ ^[1-9][0-9]*$ ]] || ! kill -0 "$operation_pid" 2>/dev/null;then finding 'Plex DBRepair: interrupted operation journal retained; updates/recovery held for reconciliation';fi
    fi
    local receipt="$STATUS_DIR/ram_logs_watchdog.json" checkpoint path manifest bytes checked boot_now archives="${RAMLOG_ARCHIVE_ROOT:-/mnt/vault/cloud/logs/ram_logs_watchdog_archives}"
    boot_now=$(cat /proc/sys/kernel/random/boot_id)
    if audit_script_active ram_logs_watchdog && (( $(cut -d . -f1 /proc/uptime)>=1800 ));then
      checked=$(jq -r '.checkpoint.checkedAt // 0' "$receipt" 2>/dev/null)
      path=$(jq -r '.checkpoint.path // ""' "$receipt" 2>/dev/null)
      checkpoint=false
      case "$path" in "${RAMLOG_ARCHIVE_ROOT:-/mnt/vault/cloud/logs/ram_logs_watchdog_archives}"/ramlogs_*)
        if [[ $(dirname "$path") == "$archives" && -f "$path/.owner" && ! -L "$path/.owner" && $(cat "$path/.owner") == ramlog_archive && -d "$path" && ! -L "$path" && -f "$path/manifest.json" && ! -L "$path/manifest.json" && -f "$path/payload.tar.gz" && ! -L "$path/payload.tar.gz" ]];then
          manifest=$(sha256sum "$path/manifest.json"|cut -d ' ' -f1);bytes=$(stat -c %s "$path/payload.tar.gz")
          jq -e --arg boot "$boot_now" --arg manifest "$manifest" --argjson bytes "$bytes" '.checkpoint.bootId==$boot and .checkpoint.manifestSha256==$manifest and .checkpoint.payloadBytes==$bytes' "$receipt" >/dev/null 2>&1 && checkpoint=true
        fi;;esac
      if jq -e --arg boot "$boot_now" '.checkpoint.bootId==$boot and .checkpoint.empty==true' "$receipt" >/dev/null 2>&1;then
        local ram_source="${RAMLOG_PATH:-/mnt/ramlogs}"
        if [[ $(jq -r '.checkpoint.source // ""' "$receipt") == "$ram_source" ]] && mountpoint -q "$ram_source" && [[ $(findmnt -rn -T "$ram_source" -o FSTYPE) == tmpfs && -z $(find "$ram_source" -type f -print -quit) ]];then checkpoint=true;fi
      fi
      local ram_window ram_cutoff
      ram_window=$(usr_scripts_due_window "$AUDIT_CATALOG_FILE" ram_logs_watchdog "$NOW" 1800 3600) || ram_window='{"cutoff":0}'
      ram_cutoff=$(jq -r '.cutoff // 0' <<<"$ram_window");((ram_cutoff<=NOW-3600)) || ram_cutoff=$((NOW-3600))
      if ! [[ "$checked" =~ ^[0-9]+$ ]] || ((checked>NOW+60 || checked<ram_cutoff)) || [[ "$checkpoint" != true ]];then
        finding 'RAM logs: current-boot checkpoint is stale or its archive read-back does not match; previous archives retained, crash-log coverage requires attention'
      fi
    fi
    if audit_script_active syslog_watchdog && (( $(cut -d . -f1 /proc/uptime)>=1800 ));then
      receipt="$STATUS_DIR/syslog_watchdog.json"
      # Dynamic schedule owns the allowance; disabled/retired scripts are excluded.
      local freshness cutoff
      freshness=$(usr_scripts_due_window "$AUDIT_CATALOG_FILE" syslog_watchdog "$NOW" 600 900) || freshness='{"cutoff":0}'
      cutoff=$(jq -r '.cutoff // 0' <<<"$freshness")
      jq -e --arg boot "$boot_now" --argjson now "$NOW" --argjson cutoff "$cutoff" '.schema==1 and .bootId==$boot and .lastSuccessfulScanAt<=$now+60 and .lastSuccessfulScanAt>=$cutoff and $cutoff>0' "$receipt" >/dev/null 2>&1 || finding 'Syslog watchdog: no recent successful scan and delivery receipt within the current schedule allowance; execution alone does not prove monitoring coverage'
    fi
}

audit_deployed_code() {
    local registry="$STATUS_DIR/deployments.json" name role path expected actual
    if [[ ! -f "$registry" ]];then
      [[ ! -e "$STATUS_DIR/.deployment-enrolled" ]] || finding 'Deployment registry missing after enrollment; code provenance needs review'
      return 0
    fi
    jq -e '.schema==1 and (.scripts|type)=="object"' "$registry" >/dev/null || { finding 'Deployment registry invalid; no scripts were changed';return; }
    while IFS=$'\t' read -r name role path;do
      expected=$(jq -r --arg role "$role" '.scripts[$role].sha256 // ""' "$registry")
      if [[ -z "$expected" ]];then finding "Deployment: installed script $name is not enrolled; record its reviewed code before trusting drift checks";continue;fi
      actual=$(sha256sum "$path"|cut -d ' ' -f1)
      [[ "$actual" == "$expected" ]] || finding "Deployment: $name differs from its reviewed live-script checksum; inspect code/private setting edits. No overwrite or execution was attempted"
    done < <(jq -r '.jobs[]|select(.present)|[.name,.role,.physicalPath]|@tsv' "$AUDIT_CATALOG_FILE")
}

audit_restore_coverage() {
    local file="${RESTORE_COVERAGE_FILE:-/mnt/vault/cloud/logs/script/backup_restore_drill/restore-coverage.json}" name at scope
    [[ -f "$file" ]] || return 0
    while IFS=$'\t' read -r name at scope;do
      ((at>0)) || continue
      local allowance=$((90*86400));case "$name" in sonarr|radarr|pihole|plex-media|plex-media-server) allowance=$((21*86400));;esac
      ((NOW-at<=allowance)) || finding "Restore coverage: $name last successful $scope restore is older than $((allowance/86400)) days; oldest-first bounded drill will prioritize it"
    done < <(jq -r '.archives|to_entries[]|[.key,.value.verifiedAt,.value.scope]|@tsv' "$file")
}

audit_ram_archive_payloads() {
    audit_script_active ram_logs_watchdog || return 0
    local root="${RAMLOG_ARCHIVE_ROOT:-/mnt/vault/cloud/logs/ram_logs_watchdog_archives}" dir mark="$STATE_DIR/ram-payload-verification.json" previous=0 signature='' now_sig
    if [[ -f "$mark" ]];then previous=$(jq -r '.at // 0' "$mark");signature=$(jq -r '.signature // ""' "$mark");fi
    now_sig=$(find "$root" -mindepth 2 -maxdepth 2 -name SHA256SUMS -type f -exec sha256sum {} + 2>/dev/null|sort|sha256sum|cut -d ' ' -f1)
    # Avoid rehashing rolling payloads every hour; verify at most once weekly.
    ((NOW-previous>=604800)) || return 0
    local success=true checked=0
    while IFS= read -r -d '' dir;do
      [[ -d "$dir" && ! -L "$dir" && -f "$dir/.owner" && $(cat "$dir/.owner") == ramlog_archive && -f "$dir/SHA256SUMS" ]] || continue
      # Only two bounded managed generations; reject extra paths in manifests.
      if ! awk 'NF!=2 || ($2!="payload.tar.gz" && $2!="manifest.json"){bad=1}END{exit bad}' "$dir/SHA256SUMS" || ! (cd "$dir" && timeout --kill-after=2 180 sha256sum -c SHA256SUMS >/dev/null) || ! timeout --kill-after=2 60 gzip -t "$dir/payload.tar.gz";then
        success=false;finding "RAM logs: retained payload checksum/CRC failed for ${dir##*/}; archive preserved for review"
      fi
      checked=$((checked+1));((checked<2)) || break
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -name 'ramlogs_*' -print0 2>/dev/null)
    if [[ "$success" == true && "$checked" != 0 ]];then jq -n --argjson at "$NOW" --arg signature "$now_sig" '{at:$at,signature:$signature}' >"$mark.tmp" && mv "$mark.tmp" "$mark";fi
}

audit_backups() {
    local latest path created epoch=0 request delivered requested source manifest old_digest new_digest log copy_epoch=0
    latest=$(latest_path "$APPDATA_ROOT" d 'backup_[0-9]*_[0-9]*')
    path="$APPDATA_ROOT/$latest"
    if [[ -n "$latest" && -f "$path/backup_manifest.tsv" && -f "$path/backup_manifest.tsv.sha256" ]]; then
        old_digest=$(awk 'NR==1 {print $1}' "$path/backup_manifest.tsv.sha256")
        new_digest=$(sha256sum "$path/backup_manifest.tsv" | awk '{print $1}')
        [[ "$old_digest" == "$new_digest" && "$old_digest" =~ ^[a-f0-9]{64}$ ]] || finding 'Appdata: current generation manifest checksum mismatch; archive payloads were not rehashed by this audit'
        created=$(sed -n 's/^# created=//p' "$path/backup_manifest.tsv")
        epoch=$(date -d "$created" +%s 2>/dev/null || printf 0)
        ACTIONS+=("Appdata generation: $latest; manifest checked, archive payload verification remains the producer/ISS/drill responsibility.")
    fi
    check_age Appdata "$epoch" "$APPDATA_MAX_AGE_SECONDS" backup_cache_appdata 43200
    latest=$(latest_path "$FLASH_ROOT" f '*-boot-backup-*.zip')
    epoch=0
    if [[ -n "$latest" && -f "$FLASH_ROOT/$latest.sha256" ]]; then epoch=$(stat -c %Y "$FLASH_ROOT/$latest"); ACTIONS+=("Flash generation: $latest; checksum sidecar present (ZIP payload not rehashed)."); fi
    check_age Flash "$epoch" "$FLASH_MAX_AGE_SECONDS" backup_boot_disk 43200
    local mirror_success="$STATUS_DIR/backup_media_remote.last-success.json" mirror_attempt="$STATUS_DIR/backup_media_remote.last-attempt.json"
    if [[ -f "$mirror_success" ]] && jq -e '.schema==2 and .copy=="OK" and .verification=="rsync_transfer_verified" and (.jobs|length)>0 and all(.jobs[];.exitCode==0)' "$mirror_success" >/dev/null;then
        copy_epoch=$(jq -r .epoch "$mirror_success")
        ACTIONS+=("Media mirror: structured per-job completion recorded; transferred-file checksums verified by rsync; unchanged files were not fully rehashed.")
        if [[ -f "$mirror_attempt" ]] && jq -e --argjson completed "$copy_epoch" '.epoch>$completed' "$mirror_attempt" >/dev/null;then finding "Media mirror: latest attempt did not complete verification. $(jq -r '.lastError // .status' "$mirror_attempt") Previous successful evidence retained.";fi
    elif [[ -f "$STATUS_DIR/backup_media_remote.json" ]] && jq -e '.copy=="OK" and .verification=="rsync_transfer_verified"' "$STATUS_DIR/backup_media_remote.json" >/dev/null; then
        copy_epoch=$(jq -r .epoch "$STATUS_DIR/backup_media_remote.json")
    else
        # Cutover compatibility: the previous successful mirror predates atomic
        # receipts. A bounded, anchored success line is legacy log evidence only.
        log=$(latest_path "$REMOTE_LOG_ROOT" f 'backup_media_remote_*.log')
        if [[ -n "$log" ]]; then
            created=$(tail -n 80 "$REMOTE_LOG_ROOT/$log" | sed -n '/Remote backup completed successfully/s/^\(.\{19\}\).*/\1/p' | tail -n 1)
            [[ -z "$created" ]] || copy_epoch=$(date -d "$created" +%s 2>/dev/null || printf 0)
            (( copy_epoch==0 )) || ACTIONS+=('Mirror freshness obtained from legacy completion log; next successful mirror should publish its verification receipt.')
        fi
    fi
    check_age 'Media/Secure mirror' "$copy_epoch" "$MIRROR_MAX_AGE_SECONDS"
    request="$STATUS_DIR/iss-backup-request.json"; delivered="$STATUS_DIR/iss-backup-delivered.json"
    if [[ -f "$request" ]]; then
        if jq -e '.schema==1 and (.completedAt|type)=="number" and (.manifestSha256|type)=="string"' "$request" >/dev/null; then
            requested=$(jq -r .completedAt "$request")
            source=$(jq -r .generation "$request"); manifest=$(jq -r .manifestSha256 "$request")
            if [[ -f "$delivered" ]] && jq -e --arg id "${source##*/}:$manifest" '.requestId==$id and .verification=="sha256"' "$delivered" >/dev/null; then
                ACTIONS+=("ISS acknowledged appdata generation ${source##*/}; remote SHA verification recorded.")
                [[ -f /mnt/vault/backup/operations_state/export.json ]] || finding 'Operational-state export missing after ISS delivery; check the vault script version and source map'
            else
                check_age 'Pending ISS completion request' "$requested" "$ISS_PENDING_MAX_AGE_SECONDS"
                ACTIONS+=("ISS request pending for ${source##*/}; hourly transfer retry remains responsible. ISS was not contacted by this audit.")
            fi
        else finding 'ISS request: invalid completion receipt; existing file preserved'; fi
    else
        ACTIONS+=('ISS handoff: awaiting the first successful appdata producer request after cutover.')
    fi
    if [[ -f "$STATUS_DIR/backup_vault_remote.json" ]]; then
        [[ $(jq -r '.restoreDrill // "not_observed"' "$STATUS_DIR/backup_vault_remote.json") != FAILED ]] || finding 'ISS restore drill failed after a verified copy; backup retained; inspect the vault drill summary'
        epoch=$(jq -r '.restoreDrillEpoch // 0' "$STATUS_DIR/backup_vault_remote.json")
    else epoch=0; fi
    if [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch>0 )); then check_age 'ISS rotating restore drill' "$epoch" "$DRILL_MAX_AGE_SECONDS"
    elif [[ -f "$STATUS_DIR/backup_restore_drill.json" ]]; then
        epoch=$(jq -r 'if .status=="OK" or .status=="WARNING" then .epoch else 0 end' "$STATUS_DIR/backup_restore_drill.json")
        check_age 'Local rotating restore drill' "$epoch" "$DRILL_MAX_AGE_SECONDS"
        ACTIONS+=('ISS drill execution has not yet been recorded by the new vault workflow; local drill evidence is labelled separately.')
    else finding 'Restore drill: no successful local or ISS completion evidence'; fi
}
main() {
    case "${1:-}" in --version) printf 'backup_health_audit.sh %s\n' "$SCRIPT_VERSION"; return;; --help) printf 'Usage: bash script\nHourly read-only backup freshness/runtime audit; never wakes ISS or starts backups.\n'; return;; '') ;; *) return 2;; esac
    for command in jq php flock timeout date find stat sha256sum; do command -v "$command" >/dev/null || return 1; done
    if ! mountpoint -q /mnt/vault; then printf 'Vault unavailable; no shadow audit state created.\n' >&2; return 1; fi
    mkdir -p "$STATE_DIR" "$STATUS_DIR" || return 1
    exec 9>"$STATE_DIR/audit.lock" || return 1
    flock -n 9 || return 0
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || return 1
    flock -s -n "$export_fd" || return 0
    trap '[[ -z "${AUDIT_CATALOG_FILE:-}" ]] || rm -f -- "$AUDIT_CATALOG_FILE"; [[ -z "${AUDIT_EXECUTION_SNAPSHOT:-}" ]] || rm -f -- "$AUDIT_EXECUTION_SNAPSHOT"' EXIT
    local previous='' last=0 fingerprint temp status=OK importance=normal body
    audit_runtime; audit_deployed_code; audit_restore_coverage; audit_ram_archive_payloads; usr_ops_retry_deliveries || true; audit_script_executions; audit_backups; audit_recovery_inventory; audit_disk_health_monitor; audit_media_integrity_monitor; audit_media_coordination; audit_update_coordinator
    fingerprint=$(printf '%s\n' "${FINDINGS[@]}" | sort | sha256sum | awk '{print $1}')
    if [[ -f "$STATE_DIR/state.json" ]]; then
        jq -e '.fingerprint|type=="string"' "$STATE_DIR/state.json" >/dev/null || { printf 'Invalid audit state preserved.\n' >&2; return 1; }
        previous=$(jq -r .fingerprint "$STATE_DIR/state.json"); last=$(jq -r '.notifiedAt // 0' "$STATE_DIR/state.json")
        [[ "$last" =~ ^[0-9]+$ ]] || return 1
    fi
    if (( ${#FINDINGS[@]}>0 )); then status=WARNING; importance=warning; fi
    body="Backup audit: $status; Unraid $PLATFORM_VERSION; findings=${#FINDINGS[@]}."$'\n'"$(printf '%s\n' "${FINDINGS[@]}" "${ACTIONS[@]}")"$'\n''Actions: local backup evidence and host capabilities checked. No backup, remote wake, media scan, restart or cleanup was performed. Previously failed producer notifications may have been retried.'
    if [[ "$fingerprint" != "$previous" && ( -n "$previous" || "$status" != OK ) ]] || { [[ "$status" != OK ]] && (( NOW-last>=REMINDER_SECONDS )); }; then
        if [[ ! -x "$NOTIFY_BIN" ]] || ! usr_ops_notify timeout 30 "$NOTIFY_BIN" -i "$importance" -s 'Backup Health Audit' -d "Backup audit: $status" -m "$body"; then
            printf 'Audit notification failed; transition remains pending.\n' >&2; return 1
        fi
        last=$NOW
    fi
    temp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 1
    jq -n --arg fingerprint "$fingerprint" --argjson notifiedAt "$last" --argjson epoch "$NOW" '{fingerprint:$fingerprint,notifiedAt:$notifiedAt,epoch:$epoch}' >"$temp" && mv "$temp" "$STATE_DIR/state.json" || return 1
    temp=$(mktemp "$STATUS_DIR/.backup-audit.XXXXXX") || return 1
    jq -n --arg name backup_health_audit --arg status "$status" --arg summary "$body" --arg version "$PLATFORM_VERSION" --argjson safe "$RUNTIME_SAFE" --argjson epoch "$NOW" '{name:$name,status:$status,summary:$summary,platformVersion:$version,runtimeCapabilitiesPassed:$safe,epoch:$epoch}' >"$temp" && mv "$temp" "$STATUS_DIR/backup_health_audit.json" || return 1
    if [[ -f "$STATE_DIR/audit.log" ]] && (( $(stat -c %s "$STATE_DIR/audit.log")>=LOG_MAX_BYTES )); then mv -f "$STATE_DIR/audit.log" "$STATE_DIR/audit.log.1"; fi
    audit_log "Audit complete: $status; findings=${#FINDINGS[@]}; platform=$PLATFORM_VERSION"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
