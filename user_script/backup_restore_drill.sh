#!/bin/bash
# Release version: bump for every deployed code change; descriptions stay user-owned.
readonly SCRIPT_VERSION="1.6.1"
# Version lookup exits before logging, locks, state, Docker or network activity.
if [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" == --version ]]; then
    printf 'backup_restore_drill.sh %s\n' "$SCRIPT_VERSION"
    exit 0
fi
clearLog=true

###############################################################################
# Backup Restore Drill
#
# Checks that selected Hubble appdata and boot-device backups can be read and
# restored into an isolated staging directory. It never writes to live appdata
# or the boot device. This is a bounded extraction/database drill, not proof
# of application startup or boot-device recovery.
#
# CLI: bash script [--generation-root /mnt/user/backup/vault_versions/hubble-STAMP]
# With no arguments use the newest local backups. --generation-root uses the
# completed ISS generation itself (appdata/ and flash/); it is run ON ISS.
# Optional environment: VAULT_MOUNT, DRILL_ROOT, LOG_DIR, STATUS_DIR,
# MAX_APPDATA_ARCHIVES (0=all), MAX_EXTRACT_BYTES, EXTRA_FREE_MARGIN_BYTES.
# Default: rotate two archives weekly; release restored payload after checking
# each archive and retain compact evidence only. Larger archives exceeding the
# space budget are reported as untested, never silently counted as verified.
# An OK result covers the named selection, not every application or a full restore.
###############################################################################

# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="backup_restore_drill"
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
umask 077


###############################################################################
# CONFIGURATION
###############################################################################

VAULT_MOUNT="${VAULT_MOUNT:-/mnt/vault}"
APPDATA_BACKUP_ROOT="${APPDATA_BACKUP_ROOT:-/mnt/vault/backup/cache}"
FLASH_BACKUP_ROOT="${FLASH_BACKUP_ROOT:-/mnt/vault/backup/flash}"
DRILL_ROOT="${DRILL_ROOT:-/mnt/vault/restore_drill}"

# Empty means extract every appdata archive in the newest successful backup.
# Otherwise use archive base names without .tar.gz.
APPDATA_ARCHIVE_ALLOWLIST=()

MAX_APPDATA_ARCHIVES="${MAX_APPDATA_ARCHIVES:-3}"
MAX_EXTRACT_BYTES="${MAX_EXTRACT_BYTES:-$((64 * 1024 * 1024 * 1024))}"
CHECK_SQLITE_DATABASES="${CHECK_SQLITE_DATABASES:-true}"
SQLITE_MAX_FILES="${SQLITE_MAX_FILES:-200}"

REQUIRE_FLASH_CHECKSUM="${REQUIRE_FLASH_CHECKSUM:-true}"
MIN_FLASH_ARCHIVE_FILES="${MIN_FLASH_ARCHIVE_FILES:-10}"

# Compressed input size multiplied by this factor for extraction-space checks.
EXTRACT_SPACE_MULTIPLIER="${EXTRACT_SPACE_MULTIPLIER:-4}"
EXTRA_FREE_MARGIN_BYTES="${EXTRA_FREE_MARGIN_BYTES:-$((5 * 1024 * 1024 * 1024))}"

MAX_SUCCESSFUL_DRILLS="${MAX_SUCCESSFUL_DRILLS:-2}"
KEEP_FAILED_DRILL="${KEEP_FAILED_DRILL:-false}"

LOG_DIR="${LOG_DIR:-/mnt/vault/cloud/logs/script/backup_restore_drill}"
MAX_LOGS="${MAX_LOGS:-5}"
STATUS_DIR="${STATUS_DIR:-/mnt/vault/cloud/logs/script/user_scripts_status}"
NOTIFY_BIN="${NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify}"
LOCK_FILE="${LOCK_FILE:-/run/backup_restore_drill.lock}"

###############################################################################
# RUNTIME
###############################################################################

RUN_STAMP="$(date '+%Y%m%d_%H%M%S')"
WORK_DIR="${DRILL_ROOT}/drill_${RUN_STAMP}.partial"
FINAL_DIR="${DRILL_ROOT}/drill_${RUN_STAMP}"
LOG_FILE="${LOG_DIR}/restore-drill-${RUN_STAMP}.log"

START_EPOCH="$(date +%s)"
RESULT_STATUS="FAILED"
RESULT_SUMMARY="Restore drill exited before completion"
RECEIPT_WRITTEN=0
WORK_PROMOTED=0

APPDATA_BACKUP=""
FLASH_BACKUP=""
FLASH_CHECKSUM_STATUS="NOT_CHECKED"
FLASH_ARCHIVE_FILES=0
ARCHIVES_CHECKED=0
ARCHIVES_EXTRACTED=0
DATABASES_CHECKED=0
DATABASES_FAILED=0
DRILL_WARNINGS=0
ARCHIVES_SKIPPED=0
GENERATION_ROOT=""
EXTRACT_PID=""
declare -A PLEX_SELECTIVE=()
SELECTIVE_CHECKED=()
SELECTED_NAMES=()
SELECTED_BYTES=()
SELECTED_HASHES=()
SELECTED_RAW=()
EXTRACTED_BASE=""
CHECKED_NAMES=()
SKIPPED_NAMES=()

###############################################################################
# HELPERS
###############################################################################

log() {
    local level="$1"
    shift
    local line
    line=$(usr_ops_log_line "$level" MAIN "$*")
    printf '%s\n' "$line"
    [[ -d "$LOG_DIR" ]] && printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
}

notify_unraid() {
    local importance="$1" description="$2" message="$3"
    [[ "$NOTIFY_BIN" != /nonexistent ]] || { DRILL_NOTIFICATION=suppressed;return 0; }
    [[ -x "$NOTIFY_BIN" ]] || { DRILL_NOTIFICATION=failed;return 1; }
    if usr_ops_notify "$NOTIFY_BIN" -i "$importance" -s "Backup Restore Drill" \
        -d "$description" -m "$message" >/dev/null 2>&1;then DRILL_NOTIFICATION=sent;else DRILL_NOTIFICATION=failed;return 1;fi
}

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " ")
        i=1
        while (b >= 1024 && i < 5) { b/=1024; i++ }
        printf "%.2f %s", b, u[i]
    }'
}

write_receipt() {
    local status="$1" summary="$2" now tmp
    if ((${#SELECTIVE_CHECKED[@]}>0)) && [[ "$summary" != *"Selective Plex"* ]];then summary+=" Selective Plex database/preferences extraction: ${SELECTIVE_CHECKED[*]}; Media payload was not extracted.";fi
    now="$(date +%s)"
    mkdir -p -- "$STATUS_DIR" 2>/dev/null || return 0
    command -v jq >/dev/null 2>&1 || return 0
    tmp="$(mktemp "${STATUS_DIR}/.backup_restore_drill.XXXXXX")" || return 0
    if jq -n \
        --arg name "backup_restore_drill" \
        --arg status "$status" \
        --arg summary "$summary" \
        --arg log "$LOG_FILE" \
        --argjson epoch "$now" \
        --arg notification "${DRILL_NOTIFICATION:-not_attempted}" \
        --argjson duration "$((now - START_EPOCH))" \
        '{name:$name,status:$status,summary:$summary,log:$log,epoch:$epoch,duration_seconds:$duration,notification:$notification}' \
        >"$tmp"
    then
        mv -f -- "$tmp" "${STATUS_DIR}/backup_restore_drill.json"
        RECEIPT_WRITTEN=1
    else
        rm -f -- "$tmp"
    fi
}

cleanup() {
    local rc=$?
    if [[ -n "$EXTRACT_PID" ]]; then
        kill -TERM -- "-$EXTRACT_PID" 2>/dev/null || true
        wait "$EXTRACT_PID" 2>/dev/null || true
    fi
    if (( rc != 0 )); then
        RESULT_SUMMARY="Restore drill failed: ${RESULT_SUMMARY}; archives restored=$ARCHIVES_EXTRACTED, database failures=$DATABASES_FAILED. Production data was not modified."
        notify_unraid alert "Restore drill failed" "$RESULT_SUMMARY"$'\n'"Source: $APPDATA_BACKUP"$'\n'"Log: $LOG_FILE"
    fi
    if (( WORK_PROMOTED == 0 )) && [[ -d "$WORK_DIR" ]]; then
        if [[ "$KEEP_FAILED_DRILL" == true ]]; then
            mv -- "$WORK_DIR" "${WORK_DIR%.partial}.failed" 2>/dev/null || true
        else
            rm -rf -- "$WORK_DIR"
        fi
    fi
    if (( RECEIPT_WRITTEN == 0 )); then
        write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
    fi
    trap - EXIT
    exit "$rc"
}

latest_entry() {
    local root="$1" type="$2" pattern="$3"
    find "$root" -mindepth 1 -maxdepth 1 -type "$type" -name "$pattern" \
        ! -name '*.partial' ! -name '*.failed' \
        -printf '%T@|%p\n' 2>/dev/null |
        sort -rn |
        head -n 1 |
        cut -d'|' -f2-
}

latest_backup_boot_disk() {
    find "$FLASH_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type f \
        \( -name '*-boot-backup-*.zip' -o -name '*-flash-backup-*.zip' \) \
        ! -name '*.partial' ! -name '*.failed' \
        -printf '%T@|%p\n' 2>/dev/null |
        sort -rn |
        head -n 1 |
        cut -d'|' -f2-
}

selected_archive() {
    local base="$1" wanted
    (( ${#APPDATA_ARCHIVE_ALLOWLIST[@]} == 0 )) && return 0
    for wanted in "${APPDATA_ARCHIVE_ALLOWLIST[@]}"; do
        [[ "$base" == "$wanted" ]] && return 0
    done
    return 1
}

validate_archive_paths() {
    local archive="$1"
    tar -tzf "$archive" 2>/dev/null |
        awk '
            /^\// { bad=1 }
            /(^|\/)\.\.(\/|$)/ { bad=1 }
            END { exit bad }
        '
}

validate_zip_paths() {
    local list_file="$1"
    awk '
        {
            path=$0
            gsub(/\\/, "/", path)
            if (path ~ /^\// || path ~ /^[A-Za-z]:\// ||
                path ~ /(^|\/)\.\.(\/|$)/) bad=1
        }
        END { exit(bad ? 1 : 0) }
    ' "$list_file"
}

file_bytes() {
    stat -c '%s' "$1" 2>/dev/null || printf 0
}

tree_bytes() {
    find "$1" -type f -printf '%s\n' 2>/dev/null |
        awk '{s+=$1} END {printf "%.0f", s+0}'
}

prune_logs() {
    local -a entries=()
    mapfile -t entries < <(
        find "$LOG_DIR" -maxdepth 1 -type f -name 'restore-drill-*.log' \
            -printf '%T@|%p\n' 2>/dev/null | sort -rn | cut -d'|' -f2-
    )
    for ((i=MAX_LOGS; i<${#entries[@]}; i++)); do
        rm -f -- "${entries[$i]}" 2>/dev/null || true
    done
}

prune_drills() {
    local -a entries=()
    mapfile -t entries < <(
        find "$DRILL_ROOT" -mindepth 1 -maxdepth 1 -type d \
            -name 'drill_[0-9]*_[0-9]*' -printf '%f\n' 2>/dev/null |
            sort -r |
            grep -E '^drill_[0-9]{8}_[0-9]{6}$'
    )
    for ((i=MAX_SUCCESSFUL_DRILLS; i<${#entries[@]}; i++)); do
        [[ "${entries[$i]}" =~ ^drill_[0-9]{8}_[0-9]{6}$ ]] || continue
        log INFO "Pruning old restore drill: ${entries[$i]}"
        rm -rf -- "${DRILL_ROOT:?}/${entries[$i]}" || return 1
    done
}

###############################################################################
# VALIDATION AND DRILL PHASES
###############################################################################

validate_environment() {
    local command numeric
    for command in find sort tar unzip sha256sum flock awk stat grep jq realpath setsid timeout; do
        command -v "$command" >/dev/null 2>&1 || {
            log ERROR "Required command not found: $command"
            return 1
        }
    done

    [[ "$REQUIRE_FLASH_CHECKSUM" == true ||
       "$REQUIRE_FLASH_CHECKSUM" == false ]] || {
        log ERROR "REQUIRE_FLASH_CHECKSUM must be true or false"
        return 1
    }
    [[ "$CHECK_SQLITE_DATABASES" == true ||
       "$CHECK_SQLITE_DATABASES" == false ]] || {
        log ERROR "CHECK_SQLITE_DATABASES must be true or false"
        return 1
    }
    [[ "$KEEP_FAILED_DRILL" == true ||
       "$KEEP_FAILED_DRILL" == false ]] || {
        log ERROR "KEEP_FAILED_DRILL must be true or false"
        return 1
    }

    for numeric in \
        "$MAX_EXTRACT_BYTES" \
        "$MAX_APPDATA_ARCHIVES" \
        "$SQLITE_MAX_FILES" \
        "$EXTRA_FREE_MARGIN_BYTES" \
        "$MAX_SUCCESSFUL_DRILLS" \
        "$MAX_LOGS"
    do
        [[ "$numeric" =~ ^[0-9]+$ ]] || {
            log ERROR "Numeric restore-drill configuration is invalid: $numeric"
            return 1
        }
    done
    [[ "$EXTRACT_SPACE_MULTIPLIER" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
        log ERROR "EXTRACT_SPACE_MULTIPLIER must be a positive number"
        return 1
    }
    if ! [[ "$MIN_FLASH_ARCHIVE_FILES" =~ ^[0-9]+$ ]] ||
       (( MIN_FLASH_ARCHIVE_FILES < 1 )); then
        log ERROR "MIN_FLASH_ARCHIVE_FILES must be a positive integer"
        return 1
    fi

    if [[ -n "$GENERATION_ROOT" ]]; then
        APPDATA_BACKUP_ROOT="$GENERATION_ROOT/appdata"
        FLASH_BACKUP_ROOT="$GENERATION_ROOT/flash"
    fi
    [[ -d "$APPDATA_BACKUP_ROOT" ]] || {
        log ERROR "Appdata backup root unavailable: $APPDATA_BACKUP_ROOT"
        return 1
    }
    [[ -d "$FLASH_BACKUP_ROOT" ]] || {
        log ERROR "Flash backup root unavailable: $FLASH_BACKUP_ROOT"
        return 1
    }
    mountpoint -q "$VAULT_MOUNT" || return 1
    [[ ! -L "$DRILL_ROOT" && $(realpath -m -- "$DRILL_ROOT") == "$DRILL_ROOT" ]] || return 1
    [[ "$DRILL_ROOT" == "$VAULT_MOUNT"/* &&
       "$DRILL_ROOT" != "$VAULT_MOUNT/" ]] || {
        log ERROR "Unsafe DRILL_ROOT: $DRILL_ROOT"
        return 1
    }

    if [[ -n "$GENERATION_ROOT" ]]; then
        [[ "$GENERATION_ROOT" =~ ^/mnt/user/backup/vault_versions/hubble-[0-9]{8}_[0-9]{6}$ &&
           -f "$GENERATION_ROOT/completed.txt" && ! -L "$GENERATION_ROOT" &&
           $(realpath -e "$GENERATION_ROOT") == "$GENERATION_ROOT" ]] || {
            log ERROR "Expected a completed canonical ISS generation"; return 1;
        }
        APPDATA_BACKUP="$GENERATION_ROOT/appdata"
        FLASH_BACKUP_ROOT="$GENERATION_ROOT/flash"
    else
        APPDATA_BACKUP="$(latest_entry "$APPDATA_BACKUP_ROOT" d 'backup_[0-9]*_[0-9]*')"
    fi
    FLASH_BACKUP="$(latest_backup_boot_disk)"
    [[ -n "$APPDATA_BACKUP" ]] || {
        log ERROR "No successful appdata backup generation found"
        return 1
    }
    [[ -n "$FLASH_BACKUP" ]] || {
        log ERROR "No boot-device ZIP backup found"
        return 1
    }
}

# A selected archive is checked against the original producer manifest. Hashes
# are not re-created as a new baseline. Manifest checksum must name only itself.
select_appdata_archives() {
    local raw bytes hash name count expected i start j
    local -a names=() sizes=() hashes=() raws=()
    [[ -f "$APPDATA_BACKUP/backup_manifest.tsv" && ! -L "$APPDATA_BACKUP/backup_manifest.tsv" &&
       -f "$APPDATA_BACKUP/backup_manifest.tsv.sha256" ]] || return 1
    [[ $(wc -l <"$APPDATA_BACKUP/backup_manifest.tsv.sha256") == 1 ]] || return 1
    hash=$(awk '{print $1}' "$APPDATA_BACKUP/backup_manifest.tsv.sha256")
    [[ "$hash" =~ ^[a-f0-9]{64}$ &&
       $(sha256sum "$APPDATA_BACKUP/backup_manifest.tsv" | awk '{print $1}') == "$hash" ]] || return 1
    expected=$(sed -n 's/^# archive_count=//p' "$APPDATA_BACKUP/backup_manifest.tsv")
    [[ "$expected" =~ ^[1-9][0-9]*$ ]] || return 1
    while IFS=$'\t' read -r raw bytes hash name; do
        [[ "$raw" == \#* ]] && continue
        [[ "$raw" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ && "$hash" =~ ^[a-f0-9]{64}$ &&
           "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ &&
           -f "$APPDATA_BACKUP/$name.tar.gz" && ! -L "$APPDATA_BACKUP/$name.tar.gz" ]] || return 1
        # Reject duplicates, which could hide a missing archive behind the count.
        for i in "${names[@]}"; do [[ "$i" != "$name" ]] || return 1; done
        names+=("$name"); sizes+=("$bytes"); hashes+=("$hash"); raws+=("$raw")
    done <"$APPDATA_BACKUP/backup_manifest.tsv"
    count=${#names[@]}
    (( count == expected )) || return 1
    # Evidence-based ordering survives missed weeks and changing app inventories.
    local ordering="$LOG_DIR/.archive-order.$$" coverage="$LOG_DIR/restore-coverage.json" rows="$LOG_DIR/.archive-rows.$$" rank
    [[ -f "$coverage" ]] || printf '{"schema":1,"archives":{}}' >"$coverage"
    : >"$rows"
    for ((i=0;i<count;i++));do jq -nc --arg name "${names[$i]}" --arg hash "${hashes[$i]}" --argjson index "$i" '{name:$name,hash:$hash,index:$index}' >>"$rows";done
    jq -sr --slurpfile coverage "$coverage" --argjson now "$(date +%s)" '
      sort_by(. as $r|($coverage[0].archives[$r.name] // {}) as $old |
        (if (["sonarr","radarr","pihole","plex-media","plex-media-server"]|index($r.name))!=null then 21 else 90 end) as $days |
        [if ($old.verifiedAt // 0)==0 then 0 else 1 end, -(($now-($old.verifiedAt // 0))/($days*86400)), if $old.sha256!=$r.hash then 0 else 1 end,.name])|.[].index' "$rows" >"$ordering" || return 1
    local -a priority=();mapfile -t priority <"$ordering";rm -f "$rows" "$ordering"
    start=0
    for ((j=0; j<count; j++)); do
        i=${priority[$j]}
        selected_archive "${names[$i]}" || continue
        if (( ${raws[$i]} > MAX_EXTRACT_BYTES || ${sizes[$i]} > MAX_EXTRACT_BYTES )) || { (( ${raws[$i]}==0 )) && [[ "${names[$i]}" == plex-media-server || "${names[$i]}" == plex-media ]]; }; then
            if [[ "${names[$i]}" == plex-media-server || "${names[$i]}" == plex-media ]];then
                PLEX_SELECTIVE["${names[$i]}"]=true
                log INFO "Plex archive exceeds full-extraction budget; checking databases/preferences selectively: ${names[$i]}"
            else
            ARCHIVES_SKIPPED=$((ARCHIVES_SKIPPED+1))
            SKIPPED_NAMES+=("${names[$i]} (estimated expanded size exceeds budget)")
            log INFO "Outside bounded drill scope: ${names[$i]}; recorded raw size exceeds $(human_bytes "$MAX_EXTRACT_BYTES") budget"
            continue
            fi
        fi
        if (( MAX_APPDATA_ARCHIVES > 0 && ${#SELECTED_NAMES[@]} >= MAX_APPDATA_ARCHIVES )); then continue; fi
        SELECTED_NAMES+=("${names[$i]}"); SELECTED_BYTES+=("${sizes[$i]}")
        SELECTED_HASHES+=("${hashes[$i]}"); SELECTED_RAW+=("${raws[$i]}")
    done
    (( ${#SELECTED_NAMES[@]} > 0 ))
}

check_free_space() {
    local available required=0 raw
    for raw in "${SELECTED_RAW[@]}"; do (( raw <= required )) || required=$raw; done
    # One appdata archive is extracted at a time. The larger compressed-size
    # estimate is a fallback; recorded raw sizes can be stale, so runtime checks
    # remain mandatory during extraction.
    local compressed
    for compressed in "${SELECTED_BYTES[@]}"; do
        raw=$(awk -v b="$compressed" -v m="$EXTRACT_SPACE_MULTIPLIER" 'BEGIN {printf "%.0f",b*m}')
        (( raw <= required )) || required=$raw
    done
    (( required <= MAX_EXTRACT_BYTES )) || required=$MAX_EXTRACT_BYTES
    required=$((required + EXTRA_FREE_MARGIN_BYTES + $(file_bytes "$FLASH_BACKUP")))
    available=$(df -B1 --output=avail "$DRILL_ROOT" | awk 'NR==2 {print $1}')
    [[ "$available" =~ ^[0-9]+$ ]] || return 1
    log INFO "Selected ${#SELECTED_NAMES[@]} appdata archives; available=$(human_bytes "$available"), required=$(human_bytes "$required")"
    (( available >= required ))
}

bounded_extract() {
    local archive="$1" destination="$2" available used rc=0
    mkdir -p -- "$destination" || return 1
    # GNU tar rejects traversal and extraction through symlink parents. Keep-old
    # also refuses duplicate/overlapping entries. Each archive gets a fresh root.
    local -a extract_command
    if [[ "$archive" == *.zip ]]; then
        extract_command=(unzip -q "$archive" -d "$destination")
    else
        extract_command=(tar -xzf "$archive" -C "$destination" --no-same-owner
            --no-same-permissions --keep-old-files --delay-directory-restore)
    fi
    if [[ -n "${PLEX_EXTRACT_MEMBERS:-}" && "$archive" != *.zip ]];then
        extract_command+=(--verbatim-files-from -T "$PLEX_EXTRACT_MEMBERS")
    fi
    setsid timeout --signal=TERM --kill-after=10 3600 "${extract_command[@]}" \
        >"$WORK_DIR/extraction.stdout" 2>"$WORK_DIR/extraction.stderr" &
    EXTRACT_PID=$!
    while kill -0 "$EXTRACT_PID" 2>/dev/null; do
        available=$(df -B1 --output=avail "$DRILL_ROOT" | awk 'NR==2 {print $1}')
        used=$(du -sb "$destination" | awk '{print $1}')
        if ! [[ "$available" =~ ^[0-9]+$ && "$used" =~ ^[0-9]+$ ]] ||
           (( available < EXTRA_FREE_MARGIN_BYTES || used > MAX_EXTRACT_BYTES )); then
            log ERROR "Extraction stopped: free-space reserve or expanded-size budget exceeded"
            kill -TERM -- "-$EXTRACT_PID" 2>/dev/null || true
            wait "$EXTRACT_PID" 2>/dev/null || true
            EXTRACT_PID=""; return 1
        fi
        sleep 1
    done
    wait "$EXTRACT_PID" || rc=$?
    EXTRACT_PID=""
    if (( rc != 0 )); then tail -n 12 "$WORK_DIR/extraction.stderr"; return "$rc"; fi
    used=$(du -sb "$destination" | awk '{print $1}')
    available=$(df -B1 --output=avail "$DRILL_ROOT" | awk 'NR==2 {print $1}')
    (( used <= MAX_EXTRACT_BYTES && available >= EXTRA_FREE_MARGIN_BYTES ))
}

drill_appdata() {
    local i name archive hash
    mkdir -p -- "$WORK_DIR/appdata" || return 1
    for ((i=0; i<${#SELECTED_NAMES[@]}; i++)); do
        name="${SELECTED_NAMES[$i]}"; archive="$APPDATA_BACKUP/$name.tar.gz"
        RESULT_SUMMARY="Checking appdata archive $name"
        [[ $(file_bytes "$archive") == "${SELECTED_BYTES[$i]}" ]] || return 1
        hash=$(sha256sum "$archive" | awk '{print $1}') || return 1
        [[ "$hash" == "${SELECTED_HASHES[$i]}" ]] || { log ERROR "Producer checksum mismatch: $name"; return 1; }
        validate_archive_paths "$archive" || { log ERROR "Unsafe/unreadable tar: $name"; return 1; }
        if [[ "${PLEX_SELECTIVE[$name]:-false}" == true ]];then
            local members="$WORK_DIR/plex-members.list"
            tar -tzf "$archive" | awk '/(^|\/)Library\/Application Support\/Plex Media Server\/(Preferences.xml|Plug-in Support\/Databases\/[^/]+\.db(-wal|-shm)?)$/ {print}' >"$members" || return 1
            [[ -s "$members" ]] && grep -q '/Preferences.xml$' "$members" && grep -Eq '/Plug-in Support/Databases/[^/]+\.db$' "$members" || { log ERROR "Plex database/preferences restore members missing: $name";return 1; }
            PLEX_EXTRACT_MEMBERS="$members" bounded_extract "$archive" "$WORK_DIR/appdata/$name" || return 1
            SELECTIVE_CHECKED+=("$name")
        else bounded_extract "$archive" "$WORK_DIR/appdata/$name" || return 1;fi
        ARCHIVES_CHECKED=$((ARCHIVES_CHECKED+1)); ARCHIVES_EXTRACTED=$((ARCHIVES_EXTRACTED+1))
        EXTRACTED_BASE="$WORK_DIR/appdata/$name"
        check_sqlite_databases || return 1
        CHECKED_NAMES+=("$name")
        local coverage="$LOG_DIR/restore-coverage.json" coverage_tmp="$WORK_DIR/restore-coverage.tmp"
        [[ -f "$coverage" ]] || printf '{"schema":1,"archives":{}}' >"$coverage"
        jq --arg name "$name" --arg hash "$hash" --arg scope "$( [[ "${PLEX_SELECTIVE[$name]:-false}" == true ]] && printf databases_and_preferences || printf full_archive )" --argjson at "$(date +%s)" '.archives[$name]=((.archives[$name] // {})+{verifiedAt:$at,sha256:$hash,scope:$scope}|if $scope=="full_archive" then .lastFullRestoreAt=$at else .lastCriticalFilesRestoreAt=$at end)' "$coverage" >"$coverage_tmp" && mv "$coverage_tmp" "$coverage" || return 1
        printf '%s  %s.tar.gz\n' "$hash" "$name" >>"$WORK_DIR/archive-sha256.txt"
        rm -rf -- "$WORK_DIR/appdata/$name" || return 1
        log INFO "Restored and checked $name; temporary payload removed"
    done
}

# Syntax/schema checks only: never execute restored scripts/templates.
CONTROL_SCRIPTS_CHECKED=0
CONTROL_TEMPLATES_CHECKED=0
RECOVERY_CHECK_RESULT="not checked"
drill_control_plane() {
    local config="$1" file schedule entry frequency script normalized
    if [[ ! -f "$config/docker.cfg" ]]; then
        log WARN 'Docker configuration absent from control-plane copy'; DRILL_WARNINGS=$((DRILL_WARNINGS+1))
    fi
    if [[ -d "$config/plugins/dockerMan/templates-user" ]]; then
        while IFS= read -r -d '' file; do
            if command -v php >/dev/null 2>&1; then
                php -r '
                  $s=file_get_contents($argv[1]);
                  if (preg_match("/<!DOCTYPE|<!ENTITY/i",$s)) exit(1);
                  libxml_use_internal_errors(true);
                  $x=simplexml_load_string($s,"SimpleXMLElement",LIBXML_NONET);
                  exit($x!==false && $x->getName()==="Container" && trim((string)$x->Name)!=="" && trim((string)$x->Repository)!=="" ? 0:1);
                ' "$file" >/dev/null 2>&1 || { log ERROR "Invalid Docker template: ${file##*/}"; return 1; }
                CONTROL_TEMPLATES_CHECKED=$((CONTROL_TEMPLATES_CHECKED+1))
            else
                log WARN 'PHP unavailable; Docker XML syntax not verified'; DRILL_WARNINGS=$((DRILL_WARNINGS+1)); break
            fi
        done < <(find "$config/plugins/dockerMan/templates-user" -type f -name '*.xml' -print0)
    else
        log WARN 'Docker templates absent from control-plane copy'; DRILL_WARNINGS=$((DRILL_WARNINGS+1))
    fi
    if [[ -d "$config/plugins/user.scripts/scripts" ]]; then
        while IFS= read -r -d '' file; do
            normalized="$WORK_DIR/control-script.tmp"
            tr -d '\r' <"$file" >"$normalized" || return 1
            IFS= read -r script <"$normalized" || true
            case "$script" in
                '#!'*bash*|'#!'*'/sh'|'') bash -n "$normalized" >/dev/null 2>&1 || { log ERROR "User Script syntax failed: ${file%/script}"; return 1; }; CONTROL_SCRIPTS_CHECKED=$((CONTROL_SCRIPTS_CHECKED+1));;
                '#!'*) log WARN "Non-shell User Script not syntax-tested: ${file%/script}"; DRILL_WARNINGS=$((DRILL_WARNINGS+1));;
                *) bash -n "$normalized" >/dev/null 2>&1 || return 1; CONTROL_SCRIPTS_CHECKED=$((CONTROL_SCRIPTS_CHECKED+1));;
            esac
            rm -f "$normalized"
        done < <(find "$config/plugins/user.scripts/scripts" -type f -name script -print0)
    else
        log WARN 'User Scripts absent from control-plane copy'; DRILL_WARNINGS=$((DRILL_WARNINGS+1))
    fi
    schedule="$config/plugins/user.scripts/schedule.json"
    if [[ -f "$schedule" ]]; then
        local catalog="$WORK_DIR/restored-script-catalog.json"
        usr_scripts_catalog "$schedule" "$config/plugins/user.scripts/scripts" snapshot >"$catalog" || { log ERROR 'Saved User Scripts schedule/inventory invalid';return 1; }
        while IFS= read -r entry;do
          script=$(jq -r .path <<<"$entry");frequency=$(jq -r .frequency <<<"$entry")
          [[ $(jq -r .enabled <<<"$entry") == true ]] || continue
          [[ $(jq -r .present <<<"$entry") == true ]] || { log ERROR "Saved active schedule has no matching payload: $script; snapshot consistency failed";return 1; }
          if [[ "$frequency" == custom && ! -s "$config/plugins/user.scripts/customSchedule.cron" ]];then log WARN 'Custom schedule present without customSchedule.cron';DRILL_WARNINGS=$((DRILL_WARNINGS+1));fi
        done < <(jq -c '.jobs[]' "$catalog")
    else
        log WARN 'User Scripts schedule absent from control-plane copy'; DRILL_WARNINGS=$((DRILL_WARNINGS+1))
    fi
}

drill_recovery_bundle() {
    local root="${RECOVERY_BUNDLE_ROOT:-/mnt/vault/backup/operations_state/recovery}" file line hash rel count=0 expected
    [[ -z "$GENERATION_ROOT" ]] || root="$GENERATION_ROOT/operations_state/recovery"
    if [[ ! -d "$root" ]]; then
        RECOVERY_CHECK_RESULT="absent; older backup has no recovery bundle"
        log WARN "$RECOVERY_CHECK_RESULT"; DRILL_WARNINGS=$((DRILL_WARNINGS+1)); return 0
    fi
    [[ ! -L "$root" && $(realpath -e "$root") == "$root" && -f "$root/SHA256SUMS" ]] || return 1
    [[ -z $(find "$root" -type l -print -quit) ]] || return 1
    : >"$WORK_DIR/recovery-checked-paths.txt" || return 1
    # Check each path before hashing. Do not trust checksum-file path arguments.
    while IFS= read -r line; do
        hash=${line%% *}; rel=${line#*  }
        [[ "$hash" =~ ^[a-f0-9]{64}$ && "$rel" == ./* && "$rel" != *'/../'* && "$rel" != */.. && "$rel" != *'/./'* && "$rel" != ./SHA256SUMS ]] || return 1
        [[ -f "$root/$rel" && $(realpath -e "$root/$rel") == "$root/${rel#./}" ]] || return 1
        [[ $(sha256sum "$root/$rel" | awk '{print $1}') == "$hash" ]] || { log ERROR 'Recovery bundle checksum mismatch'; return 1; }
        printf '%s\n' "$rel" >>"$WORK_DIR/recovery-checked-paths.txt"
        count=$((count+1))
    done <"$root/SHA256SUMS"
    expected=$(find "$root" -type f ! -path "$root/SHA256SUMS" | wc -l)
    [[ "$count" -eq "$expected" && $(sort -u "$WORK_DIR/recovery-checked-paths.txt" | wc -l) -eq "$count" ]] || return 1
    jq -e '.schema==1 and (.containerCount|type=="number") and (.runtimeStatus=="complete" or .runtimeStatus=="partial" or .runtimeStatus=="unavailable")' "$root/inventory.json" >/dev/null || return 1
    for file in containers images networks volumes files policies coverage; do
        jq -e 'type=="array"' "$root/$file.json" >/dev/null || return 1
    done
    [[ $(jq length "$root/containers.json") -eq $(jq .containerCount "$root/inventory.json") ]] || return 1
    RECOVERY_CHECK_RESULT="SHA-256 verified $count recovery files; runtime=$(jq -r .runtimeStatus "$root/inventory.json"); named-volume mounts=$(jq .namedVolumeMounts "$root/inventory.json")"
    if [[ $(jq -r .runtimeStatus "$root/inventory.json") != complete ]] || (( $(jq .namedVolumeMounts "$root/inventory.json") > 0 )); then
        log WARN "$RECOVERY_CHECK_RESULT"; DRILL_WARNINGS=$((DRILL_WARNINGS+1))
    fi
    drill_control_plane "$root/boot-config/config" || return 1
    log INFO "$RECOVERY_CHECK_RESULT"
}

drill_flash() {
    local required found checksum_file checksum_name expected_hash actual_hash list_file
    log INFO "Testing boot-device backup: $FLASH_BACKUP"

    checksum_file="${FLASH_BACKUP}.sha256"
    if [[ -f "$checksum_file" ]]; then
        expected_hash=$(awk 'NR==1 {print $1}' "$checksum_file")
        checksum_name=$(sed -n '1s/^[^ ]*  //p' "$checksum_file")
        actual_hash=$(sha256sum "$FLASH_BACKUP" | awk '{print $1}') || return 1
        if [[ $(wc -l <"$checksum_file") != 1 ||
              "$checksum_name" != "${FLASH_BACKUP##*/}" ||
              ! "$expected_hash" =~ ^[a-f0-9]{64}$ || "$actual_hash" != "$expected_hash" ]]; then
            FLASH_CHECKSUM_STATUS="FAILED"
            log ERROR "Boot-device SHA-256 verification failed: $checksum_file"
            return 1
        fi
        FLASH_CHECKSUM_STATUS="VERIFIED"
        log INFO "Boot-device SHA-256 verification passed"
    elif [[ "$REQUIRE_FLASH_CHECKSUM" == true ]]; then
        FLASH_CHECKSUM_STATUS="MISSING"
        log ERROR "Boot-device checksum sidecar is missing: $checksum_file"
        return 1
    else
        FLASH_CHECKSUM_STATUS="MISSING_ALLOWED"
        log WARN "Boot-device checksum sidecar is missing; continuing by configuration"
    fi

    mkdir -p -- "$WORK_DIR/flash" || return 1

    list_file="$WORK_DIR/flash-archive-list.txt"
    unzip -Z1 "$FLASH_BACKUP" >"$list_file" || {
        log ERROR "Boot-device ZIP listing failed"
        return 1
    }
    validate_zip_paths "$list_file" || {
        log ERROR "Boot-device ZIP contains an unsafe path"
        return 1
    }

    FLASH_ARCHIVE_FILES=$(
        awk 'substr($0, length($0), 1) != "/" {count++}
             END {print count+0}' "$list_file"
    )
    [[ "$FLASH_ARCHIVE_FILES" =~ ^[0-9]+$ ]] || FLASH_ARCHIVE_FILES=0
    if (( FLASH_ARCHIVE_FILES < MIN_FLASH_ARCHIVE_FILES )); then
        log ERROR "Boot-device ZIP contains only $FLASH_ARCHIVE_FILES files; minimum is $MIN_FLASH_ARCHIVE_FILES"
        return 1
    fi

    bounded_extract "$FLASH_BACKUP" "$WORK_DIR/flash" || return 1
    # Extraction validated ZIP CRC; the sidecar was already hashed above.
    printf '%s\n' "$FLASH_CHECKSUM_STATUS $FLASH_BACKUP" >>"$WORK_DIR/archive-sha256.txt" || return 1

    found=$(find "$WORK_DIR/flash" -type d -name config -print -quit)
    [[ -n "$found" ]] || { log ERROR "Boot backup has no config directory"; return 1; }
    for required in super.dat ident.cfg; do
        found="$(
            find "$WORK_DIR/flash" -type f -path "*/config/$required" \
                -print -quit 2>/dev/null
        )"
        [[ -n "$found" ]] || {
            log WARN "Boot backup lacks recommended legacy path: $required; review this OS/storage layout"
            DRILL_WARNINGS=$((DRILL_WARNINGS+1))
        }
    done

    drill_control_plane "$(find "$WORK_DIR/flash" -type d -name config -print -quit)" || return 1
    log INFO "Boot-device restore verified $FLASH_ARCHIVE_FILES files"
    rm -rf -- "$WORK_DIR/flash" || return 1
}

check_sqlite_databases() {
    local database result checked=0
    [[ "$CHECK_SQLITE_DATABASES" == true ]] || return 0
    if ! command -v sqlite3 >/dev/null 2>&1; then
        log WARN "sqlite3 is unavailable; database checks NOT verified"
        DRILL_WARNINGS=$((DRILL_WARNINGS+1)); return 0
    fi

    while IFS= read -r -d '' database; do
        if (( checked >= SQLITE_MAX_FILES )); then
            log WARN "SQLite check limit reached: $SQLITE_MAX_FILES; remaining databases NOT verified"
            DRILL_WARNINGS=$((DRILL_WARNINGS+1)); break
        fi
        dd if="$database" bs=15 count=1 status=none 2>/dev/null |
            grep -q '^SQLite format 3' || {
                if [[ "$database" == */Plug-in\ Support/Databases/com.plexapp.plugins.library*.db ]];then
                    DATABASES_FAILED=$((DATABASES_FAILED+1));log ERROR "Plex SQLite header invalid: $database"
                fi
                continue
            }
        checked=$((checked + 1))
        DATABASES_CHECKED=$((DATABASES_CHECKED + 1))
        result="$(timeout --signal=TERM --kill-after=5 120 sqlite3 -readonly "$database" 'PRAGMA quick_check;' 2>&1)" || true
        if [[ "$result" == *"no such collation"* || "$result" == *"no such function"* ]]; then
            DRILL_WARNINGS=$((DRILL_WARNINGS+1))
            log WARN "Database check unverified: $database; SQLite build lacks required application extension: $result"
        elif [[ "$result" != "ok" ]]; then
            DATABASES_FAILED=$((DATABASES_FAILED + 1))
            log ERROR "SQLite quick_check failed: $database: $result"
        else
            log INFO "SQLite quick_check passed: $database"
        fi
    done < <(
        find "${EXTRACTED_BASE:-$WORK_DIR/appdata}" -type f \
            \( -iname '*.db' -o -iname '*.sqlite' -o -iname '*.sqlite3' \) \
            -print0 2>/dev/null
    )

    (( DATABASES_FAILED == 0 ))
}

promote_drill() {
    {
        printf 'script_version=%s\n' "$SCRIPT_VERSION"
        printf 'completed=%s\n' "$(date -Iseconds)"
        printf 'backup_cache_appdata=%s\n' "$APPDATA_BACKUP"
        printf 'backup_boot_disk=%s\n' "$FLASH_BACKUP"
        printf 'flash_checksum_status=%s\n' "$FLASH_CHECKSUM_STATUS"
        printf 'flash_archive_files=%s\n' "$FLASH_ARCHIVE_FILES"
        printf 'archives_extracted=%s\n' "$ARCHIVES_EXTRACTED"
        printf 'databases_checked=%s\n' "$DATABASES_CHECKED"
        printf 'scope=rotating bounded selection; no service startup or boot test\n'
        printf 'checked_archive=%s\n' "${CHECKED_NAMES[@]}"
        printf 'not_extracted=%s\n' "${SKIPPED_NAMES[@]}"
    } >"$WORK_DIR/result.txt" || return 1

    mv -- "$WORK_DIR" "$FINAL_DIR" || return 1
    WORK_PROMOTED=1
}

###############################################################################
# MAIN
###############################################################################

main() {
    case "${1:-}" in
        --help) printf 'Usage: bash script [--generation-root /mnt/user/backup/vault_versions/hubble-STAMP]\nRun on the host holding the backup. Default checks three oldest/changed archives within the extraction budget; MAX_APPDATA_ARCHIVES=0 selects all within MAX_EXTRACT_BYTES. Restored payload is removed; only evidence retained.\n'; return 0;;
        --generation-root) [[ $# == 2 ]] || return 2; GENERATION_ROOT="$2";;
        "") ;;
        *) return 2;;
    esac
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if ! mountpoint -q "$VAULT_MOUNT"; then
        printf 'Vault pool is not mounted: %s\n' "$VAULT_MOUNT" >&2
        return 1
    fi
    [[ "$DRILL_ROOT" == "$VAULT_MOUNT"/* && "$DRILL_ROOT" != "$VAULT_MOUNT/" &&
       ! -L "$DRILL_ROOT" && $(realpath -m -- "$DRILL_ROOT") == "$DRILL_ROOT" ]] || {
        printf 'Unsafe drill workspace: %s\n' "$DRILL_ROOT" >&2; return 1;
    }
    mkdir -p -- "$LOG_DIR" "$DRILL_ROOT" || return 1
    : >"$LOG_FILE" || return 1
    prune_logs

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        RESULT_SUMMARY="Another restore drill is already active"
        log ERROR "$RESULT_SUMMARY"
        return 1
    fi

    log INFO "Starting isolated backup restore drill"
    # Shared locks match producers; select only while retention is excluded.
    exec {APPDATA_LOCK_FD}>"${APPDATA_LOCK_FILE:-/tmp/backup_cache_appdata.lock}" || return 1
    flock -s -n "$APPDATA_LOCK_FD" || { RESULT_SUMMARY="Appdata producer active; retry the drill later"; return 1; }
    exec {FLASH_LOCK_FD}>"${FLASH_LOCK_FILE:-/tmp/backup_boot_disk.lock}" || return 1
    flock -s -n "$FLASH_LOCK_FD" || { RESULT_SUMMARY="Flash producer active; retry the drill later"; return 1; }
    # Export replacement takes this lock exclusively. Keep the local bundle
    # stable while hashing; immutable ISS generations need no Hubble lock.
    if [[ -z "$GENERATION_ROOT" ]]; then
        exec {RECOVERY_LOCK_FD}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || return 1
        flock -s -n "$RECOVERY_LOCK_FD" || { RESULT_SUMMARY="Recovery export active; retry later"; return 1; }
    fi
    validate_environment || return 1
    RESULT_SUMMARY="Producer manifest missing or invalid"
    select_appdata_archives || return 1
    RESULT_SUMMARY="Insufficient extraction space"
    check_free_space || return 1
    [[ ! -e "$WORK_DIR" && ! -e "$FINAL_DIR" ]] || {
        log ERROR "Drill destination already exists"
        return 1
    }
    mkdir -p -- "$WORK_DIR" || return 1

    drill_appdata || return 1
    RESULT_SUMMARY="Boot-device archive validation failed"
    drill_flash || return 1
    RESULT_SUMMARY="Recovery inventory/control-plane validation failed"
    drill_recovery_bundle || return 1
    promote_drill || return 1
    prune_drills || {
        RESULT_STATUS="WARNING"
        RESULT_SUMMARY="Restore drill passed, but old drill pruning failed"
        write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
        notify_unraid warning "Restore drill warning" "$RESULT_SUMMARY"
        return 1
    }

    RESULT_STATUS="OK"
    local importance=normal
    if (( DRILL_WARNINGS > 0 )); then RESULT_STATUS="WARNING"; importance=warning; fi
    RESULT_SUMMARY="Restored and removed temporary payload: ${CHECKED_NAMES[*]}. SQLite databases checked: ${DATABASES_CHECKED}. Boot ZIP restored: ${FLASH_ARCHIVE_FILES} files; checksum ${FLASH_CHECKSUM_STATUS}. Scope: rotating selection, not a full application/boot recovery test."
    RESULT_SUMMARY+=" Templates syntax-checked: $CONTROL_TEMPLATES_CHECKED; shell scripts syntax-checked: $CONTROL_SCRIPTS_CHECKED. Recovery: $RECOVERY_CHECK_RESULT."
    if (( ARCHIVES_SKIPPED > 0 )); then RESULT_SUMMARY+=" Outside extraction budget: ${SKIPPED_NAMES[*]}."; fi
    if (( DRILL_WARNINGS > 0 )); then RESULT_SUMMARY+=" Warnings/unverified checks: $DRILL_WARNINGS; review drill log for affected checks."; fi
    log INFO "$RESULT_SUMMARY"
    write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
    if ((${#SELECTIVE_CHECKED[@]}>0));then RESULT_SUMMARY+=" Selective Plex database/preferences restore: ${SELECTIVE_CHECKED[*]}; Plex Media payload not extracted.";fi
    if ! notify_unraid "$importance" "Restore drill $RESULT_STATUS" \
        "$RESULT_SUMMARY"$'\n'"Staging result: $FINAL_DIR";then
        RESULT_STATUS=WARNING;RESULT_SUMMARY+=" Notification delivery failed; exact report queued for bounded retry."
    fi
    write_receipt "$RESULT_STATUS" "$RESULT_SUMMARY"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
