#!/bin/bash
clearLog=true

###############################################################################
# Hubble -> ISS: completion-driven vault backup consumer
#
# GitHub source: user_script/backup_vault_remote.sh
# Installed Unraid User Scripts entry: backup_vault_remote (its file is "script").
#
# PURPOSE
# Keep a separately restorable copy on ISS if Hubble or its local vault fails.
# Back up the newest completed appdata generation, flash backup, User Scripts,
# GitHub working directories, photos and compact operational state. This script
# transfers existing backups; backup_cache_appdata.sh remains the appdata producer.
#
# WHY IT IS SCHEDULED HOURLY
# Use 10 * * * * (hourly at minute 10, Singapore time). Each invocation is a short
# queue check, not a resident daemon or an unconditional hourly full backup.
# backup_cache_appdata.sh publishes iss-backup-request.json only after completing and
# verifying a local generation and checking container restart requirements.
# With no request, or an already acknowledged generation, exit before transport,
# WOL, backup log creation, payload enumeration, pruning or notifications.
#
# REAL BACKUP WORKFLOW (only for a new, valid, fresh request)
# 1. Validate the exact producer generation/manifest; acquire producer/state
#    locks and prepare the compact operational-state export.
# 2. Wake ISS if needed; wait for SSH/array readiness and acquire the shared ISS
#    backup lease, also used by the separate backup_media_remote.sh media mirror.
# 3. Transfer every configured BACKUP_JOBS source into a hidden .partial remote
#    generation; verify regular files against the expected SHA-256 manifest.
# 4. Atomically promote the verified generation and acknowledge its request.
# 5. Prune only after success (REMOTE_KEEP=3); perform a bounded restore drill on
#    ISS when its seven-day interval is due, then request guarded clean shutdown.
# 6. Retain bounded logs/status and send the operational result notification.
# Generations are independent: no Btrfs snapshot or cross-generation hard-link
# dependency. Existing source hard links may be preserved within one generation.
#
# RETRIES AND LIMITS
# An undelivered request is checked again next hour after a producer/transport/
# verification failure. Malformed, changed, future-dated or >72-hour-old requests
# require investigation/a fresh successful producer run; they are not bypassed.
# Acknowledgement occurs BEFORE retention/drill/shutdown. Those later warnings do
# not automatically recopy an already verified generation on the next poll.
# GitHub/photos/flash changes alone do not trigger a new generation in this mode;
# their current contents are included with the next appdata completion request.
#
# CLI (help/version do not acquire locks, contact ISS or start backup work)
#   bash script             Consume a new completion request, otherwise no-op.
#   bash script --help      Explain scheduling, triggers and operational limits.
#   bash script --version   Show this script version.
#   bash script --force     Repeat delivery of the current valid request even if
#                           acknowledged; still enforce freshness/integrity.
# --force may wake ISS and transfer all jobs. It cannot manufacture a request.
# Repository DRY_RUN defaults to true for review; preserve the installed value.
###############################################################################

# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="backup_vault_remote"
# shellcheck shell=bash
# Embedded operations contract v2; generated into standalone User Scripts.
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
       if $status!="RUNNING" then .finishedAt=$at|.durationSeconds=($at-$started)|.lastCompletedAt=$at|if $rc==0 then .lastSuccessAt=$at else . end else . end' >"$tmp" && chmod 600 "$tmp" && mv "$tmp" "$file" || return 1
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
# END EMBEDDED USER SCRIPTS CATALOG
set -uo pipefail
export LC_ALL=C
umask 077

readonly SCRIPT_VERSION="1.22.2"

###############################################################################
# CONFIGURATION
###############################################################################

SRC_NAS="Hubble NAS"
DEST_NAS="ISS NAS"
REMOTE="root@192.168.50.3"
REMOTE_MAC="9C:6B:00:4B:BB:EE"
SSH_PORT=22

# This root must already exist on ISS. The script never creates it implicitly.
REMOTE_VERSION_ROOT="/mnt/user/backup/vault_versions"

# label|local source
BACKUP_JOBS=(
    "appdata|/mnt/vault/backup/cache"
    "flash|/mnt/vault/backup/flash"
    "user_scripts|/boot/config/plugins/user.scripts"
    "github|/mnt/vault/cloud/github"
    "photos|/mnt/vault/cloud/photos"
    "operations_state|/mnt/vault/backup/operations_state"
)

# Each generation is a complete independent copy.
REMOTE_KEEP=3
ENABLE_WOL=true
MAX_SSH_WAIT=420
SSH_WAIT_INTERVAL=15
ARRAY_READY_WAIT=180
ARRAY_READY_INTERVAL=6
SHUTDOWN_REMOTE_ON_SUCCESS=true

# Independent remote-activity shutdown guards. Ordinary read/correcting parity
# checks may be interrupted by the clean shutdown after backup. More critical
# parity sync, rebuild, and disk-clear operations remain protected.
DEFER_REMOTE_SHUTDOWN_WHILE_MOVER=true
DEFER_REMOTE_SHUTDOWN_DURING_PARITY_CHECK=false
DEFER_REMOTE_SHUTDOWN_DURING_CRITICAL_ARRAY_OPERATION=true

# Keep true for the first manually reviewed run.
DRY_RUN=true
# Schedule: 10 * * * *. Poll for a producer request, not an hourly full copy.
# Same delivered identity/no request -> local no-op; no SSH/WOL or backup log.
# --force bypasses delivery deduplication only; a valid fresh request is required.
COMPLETION_DRIVEN=true
ISS_REQUEST_FILE="${ISS_REQUEST_FILE:-/mnt/vault/cloud/logs/script/user_scripts_status/iss-backup-request.json}"
ISS_DELIVERED_FILE="${ISS_DELIVERED_FILE:-/mnt/vault/cloud/logs/script/user_scripts_status/iss-backup-delivered.json}"
MAX_PRODUCER_AGE_SECONDS=$((72 * 3600))
ISS_REQUEST_ID=""
ISS_REQUEST_GENERATION=""
# Run a bounded drill on ISS itself once weekly, while it is already awake.
# The local User Scripts entry supplies the reviewed standalone drill script.
RUN_REMOTE_RESTORE_DRILL=true
RESTORE_DRILL_SCRIPT="${RESTORE_DRILL_SCRIPT:-/boot/config/plugins/user.scripts/scripts/backup_restore_drill/script}"
RESTORE_DRILL_INTERVAL_SECONDS=604800
# Compact operational state plus private recovery configuration (may contain
# credentials). No bulk logs/cache, databases or transient leases. Standalone.
OPERATIONS_STATE_ROOT="${OPERATIONS_STATE_ROOT:-/mnt/vault/backup/operations_state}"
OPERATIONS_STATE_MAX_BYTES=$((128 * 1024 * 1024))
OPERATIONS_STATE_MOUNT_ROOT="${OPERATIONS_STATE_MOUNT_ROOT:-/mnt/vault}"
OPERATIONS_SCRIPT_ROOT="${OPERATIONS_SCRIPT_ROOT:-/mnt/vault/cloud/logs/script}"
OPERATIONS_EXPORT_TEMP=""
# Required state for this personal installation; missing/renamed state must not
# become a silently empty "successful" export after an OS/path change.
OPERATIONS_REQUIRED_STATE_FILES=(
    media_health_monitor/state.json
    media_cleanup/arr/sonarr-state.json
    media_cleanup/arr/radarr-state.json
    media_cleanup/arr/pending-actions.json
    media_cleanup/sab/pending-operations.json
    media_cleanup/quarantine/pending-operations.json
    media_cleanup/notification-outbox.json
    docker_service_watchdog/state.json
    system_update_coordinator/state.json
    system_update_coordinator/policy.json
    dns_redundancy_watchdog/state.json
)
RESTORE_DRILL_RESULT="not_due"
RESTORE_DRILL_EPOCH=0
RESTORE_DRILL_SUMMARY=""

USE_LOW_PRIORITY_IO=true
IONICE_CLASS=2
IONICE_PRIORITY=7
NICE_LEVEL=10

LOG_DIR="/mnt/vault/cloud/logs/script/backup_vault_remote"
MAX_LOGS=5
STATUS_DIR="/mnt/vault/cloud/logs/script/user_scripts_status"
NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"
# Same pending generation + failure reason: initial alert, then one reminder/day.
# New generations/reasons/severity notify immediately; verified completion includes
# recovery in its normal report. Failed sends never consume the reminder budget.
VAULT_FAILURE_REMINDER_SECONDS=86400
VAULT_NOTIFICATION_STATE=""
VAULT_NOTIFICATION_REASON=""
LOCK_FILE="/run/backup_vault_remote.lock"

# Existing ISS generation .owner values are the stable vault_backup v1 format.
# Script/state names changed; verified remote archive ownership is preserved.
readonly SCRIPT_ID="backup_vault_remote"
readonly NOTIFY_SUBJECT="Backup Vault Remote"

###############################################################################
# SHARED ISS COORDINATION AND TRANSPORT (embedded; standalone User Script)
###############################################################################
# Both scripts must use the same remote lock. It is held by a live SSH process,
# not a stale PID file. Only the owner may request ISS shutdown.
REMOTE_BACKUP_LOCK="/run/hubble-iss-backup.lock"
REMOTE_LEASE_WAIT_SECONDS=1800
RSYNC_IO_TIMEOUT=300
MAX_MAIN_LOG_BYTES=$((1024 * 1024))
MAX_RAW_LOG_BYTES=$((2 * 1024 * 1024))
PRESERVE_HARD_LINKS=true
STATUS_DIR="/mnt/vault/cloud/logs/script/user_scripts_status"
BACKUP_RESULT=not_started
RETENTION_RESULT=not_started
VERIFICATION_RESULT=not_started
BACKUP_PHASE=startup
BACKUP_NOTIFIED=false
NOTIFICATION_RESULT=not_attempted
SHUTDOWN_RESULT=not_requested
BACKUP_STARTED=$(date +%s)
BACKUP_TMP=""
LEASE_PID=""
LEASE_INPUT=""
LEASE_TOKEN=""
TRANSPORT_OPTIONS=()

backup_transport_init() {
    local value flag
    [[ "$SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( SSH_PORT <= 65535 )) || return 1
    [[ "$REMOTE_LEASE_WAIT_SECONDS" =~ ^(0|[1-9][0-9]*)$ ]] && (( REMOTE_LEASE_WAIT_SECONDS <= 86400 )) || return 1
    for value in "$RSYNC_IO_TIMEOUT" "$MAX_MAIN_LOG_BYTES" "$MAX_RAW_LOG_BYTES"; do [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1; done
    for flag in "$PRESERVE_HARD_LINKS" "$DRY_RUN" "$ENABLE_WOL" "$USE_LOW_PRIORITY_IO"; do [[ "$flag" == true || "$flag" == false ]] || return 1; done
    BACKUP_TMP=$(mktemp -d /tmp/iss-backup.XXXXXX) || return 1
    chmod 700 "$BACKUP_TMP" || return 1
    TRANSPORT_OPTIONS=(-p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-8}"
        -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o Compression=no
        -o ControlMaster=auto -o ControlPersist=60 -o "ControlPath=$BACKUP_TMP/ssh")
    printf -v RSYNC_RSH '%q ' ssh "${TRANSPORT_OPTIONS[@]}"
    export RSYNC_RSH
}
backup_ssh() {
    local command
    if (( $# == 1 )); then command="$1"; else printf -v command '%q ' "$@"; fi
    if (( ${BACKUP_SSH_COMMAND_TIMEOUT:-0} > 0 )); then
        timeout --signal=TERM --kill-after=5 "$BACKUP_SSH_COMMAND_TIMEOUT" ssh "${TRANSPORT_OPTIONS[@]}" "$REMOTE" "export LC_ALL=C; $command"
    else
        ssh "${TRANSPORT_OPTIONS[@]}" "$REMOTE" "export LC_ALL=C; $command"
    fi
}
backup_source_ready() {
    local source="$1" mount canonical
    [[ "$source" == /* && "$source" != / && "$source" != *$'\n'* && "$source" != *$'\t'* && -d "$source" && ! -L "$source" ]] || return 1
    case "$source" in /mnt/user/*) mount=/mnt/user;; /mnt/vault/*) mount=/mnt/vault;; /boot/*) mount=/boot;; *) return 1;; esac
    mountpoint -q "$mount" || return 1
    canonical=$(realpath -e -- "$source") || return 1
    [[ "$canonical" == "$source" ]] || return 1
    [[ -n "$(find "$source" -mindepth 1 -maxdepth 1 -print -quit)" ]] || return 1
}
# Feature probe, deliberately independent of package/Unraid version numbers.
# Only private /tmp fixtures are touched; configured backup paths are not used.
backup_rsync_probe() (
    local side="$1" links="$2" probe result a b
    export LC_ALL=C
    probe=$(mktemp -d /tmp/hubble-rsync-capability.XXXXXX) || return 1
    trap 'rm -rf -- "$probe"' EXIT
    mkdir "$probe/source" "$probe/destination" || return 1
    printf 'Hubble ISS rsync capability fixture\n' >"$probe/source/file with spaces [1].txt"
    printf '%s: %s\n' "$side" "$(rsync --version | sed -n '1p')"
    local -a options=(-a --delete-delay --delete-excluded --partial --partial-dir=.rsync-partial --protect-args --stats --timeout=15 --max-delete=1 '--filter=P /.hubble-backup-identity')
    [[ "$links" != true ]] || options+=(-H)
    if ! rsync "${options[@]}" "$probe/source/" "$probe/destination/" >"$probe/result" 2>&1; then
        printf '%s rsync required-feature probe failed:\n' "$side" >&2
        tail -n 12 "$probe/result" >&2
        return 1
    fi
    a=$(sha256sum "$probe/source/file with spaces [1].txt");b=$(sha256sum "$probe/destination/file with spaces [1].txt")
    [[ "${a%% *}" == "${b%% *}" ]] || { printf '%s rsync probe content verification failed\n' "$side" >&2;return 1; }
    # Resumption/checksum repair is also used by the vault workflow.
    rsync "${options[@]}" --checksum --dry-run "$probe/source/" "$probe/destination/" >"$probe/result" 2>&1 || { printf '%s checksum probe failed\n' "$side" >&2;tail -n 12 "$probe/result" >&2;return 1; }
    printf '%s rsync required features and temporary copy verified\n' "$side"
)
backup_capabilities() {
    local cmd value
    for value in "$RSYNC_IO_TIMEOUT" "$MAX_MAIN_LOG_BYTES" "$MAX_RAW_LOG_BYTES"; do [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1; done
    [[ "$PRESERVE_HARD_LINKS" == true || "$PRESERVE_HARD_LINKS" == false ]] || return 1
    [[ "$SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( SSH_PORT <= 65535 )) || return 1
    for cmd in ssh rsync jq timeout flock realpath sha256sum stat find sort awk sed tail head tee date mktemp xargs grep cat du mountpoint; do command -v "$cmd" >/dev/null || return 1; done
    # Version banners are diagnostic only. Native Unraid packages may differ
    # between Hubble and ISS; negotiate protocols normally and test real flags.
    if ! backup_rsync_probe Hubble "$PRESERVE_HARD_LINKS" >>"$LOG_FILE" 2>&1;then
        printf 'Hubble rsync feature validation failed; see %s\n' "$LOG_FILE" >&2;return 1
    fi
    local remote_boot
    remote_boot=$(BACKUP_SSH_COMMAND_TIMEOUT=30 backup_ssh 'cat /proc/sys/kernel/random/boot_id') || return 1
    [[ -n "$remote_boot" && "$remote_boot" != "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" ]] || return 1
    {
        declare -f backup_rsync_probe
        cat <<'CAPABILITIES'
set -euo pipefail
export LC_ALL=C
for cmd in bash rsync flock realpath sha256sum stat find sort awk sed df mktemp du mv cat tail mkdir rm;do
    command -v "$cmd" >/dev/null || { printf 'ISS missing required command: %s\n' "$cmd" >&2;exit 1; }
done
CAPABILITIES
        printf 'backup_rsync_probe ISS %q\n' "$PRESERVE_HARD_LINKS"
    } | BACKUP_SSH_COMMAND_TIMEOUT=45 backup_ssh bash -s >>"$LOG_FILE" 2>&1 || {
        printf 'ISS command/rsync feature validation failed; see %s\n' "$LOG_FILE" >&2;return 1
    }

}
backup_acquire_lease() {
    local ready output_fd remote_script original_input original_output
    [[ "$REMOTE_BACKUP_LOCK" =~ ^/run/[A-Za-z0-9_.-]+$ && "$REMOTE_LEASE_WAIT_SECONDS" =~ ^[0-9]+$ ]] || return 1
    remote_script=$(cat <<'LEASE'
set -euo pipefail
exec 9>"$1"
printf '%s\n' "$BASHPID" >"$1.waiter.$3"
trap 'rm -f -- "$1.waiter.$3"' EXIT
flock -w "$2" 9 || exit 75
rm -f -- "$1.waiter.$3"
printf '%s\n' "$3" >"$1.owner"
trap 'rm -f -- "$1.owner"' EXIT
# A recently accepted shutdown must finish before another job starts. /run is
# cleared on reboot; failed shutdown reservations expire after fifteen minutes.
if [[ -f /run/hubble-iss-shutdown.pending ]]; then
    read -r stamp </run/hubble-iss-shutdown.pending
    [[ "$stamp" =~ ^[0-9]+$ ]] || exit 75
    (( $(date +%s) - stamp > 900 )) || exit 75
    rm -f /run/hubble-iss-shutdown.pending
fi
printf 'ISS_BACKUP_READY\n'
while IFS= read -r line; do :; done
LEASE
) || return 1
    LEASE_TOKEN="$SCRIPT_ID-$$-$RANDOM-$RANDOM"
    coproc ISS_LEASE { backup_ssh bash -c "$remote_script" -- "$REMOTE_BACKUP_LOCK" "$REMOTE_LEASE_WAIT_SECONDS" "$LEASE_TOKEN"; }
    LEASE_PID=${ISS_LEASE_PID:-}
    original_input=${ISS_LEASE[1]:-}; original_output=${ISS_LEASE[0]:-}
    [[ -n "$LEASE_PID" && -n "$original_input" && -n "$original_output" ]] || return 1
    exec {LEASE_INPUT}>&"$original_input"
    exec {output_fd}<&"$original_output"
    exec {original_input}>&-
    exec {original_output}<&-
    if ! IFS= read -r -t "$((REMOTE_LEASE_WAIT_SECONDS+15))" ready <&"$output_fd" || [[ "$ready" != ISS_BACKUP_READY ]]; then
        exec {output_fd}<&-
        return 1
    fi
    exec {output_fd}<&-
}
backup_lease_alive() {
    [[ -n "$LEASE_PID" && -n "$LEASE_INPUT" ]] && kill -0 "$LEASE_PID" 2>/dev/null &&
        (trap - PIPE; printf 'active\n' >&"$LEASE_INPUT") &&
        BACKUP_SSH_COMMAND_TIMEOUT=15 backup_ssh "test -f $REMOTE_BACKUP_LOCK.owner && test \"\$(cat $REMOTE_BACKUP_LOCK.owner)\" = '$LEASE_TOKEN'"
}
backup_shutdown_handoff() {
    local waiters
    if ! waiters=$(BACKUP_SSH_COMMAND_TIMEOUT=30 backup_ssh bash -s -- "$REMOTE_BACKUP_LOCK" "$REMOTE_LEASE_WAIT_SECONDS" <<'WAITERS'
set -euo pipefail
for file in "$1".waiter.*; do
    [[ -f "$file" ]] || continue
    read -r pid <"$file"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || exit 3
    age=$(( $(date +%s)-$(stat -c %Y -- "$file") ))
    (( age >= 0 )) || exit 3
    # Dead/reused PIDs cannot leave a permanent shutdown blocker behind.
    if (( age <= $2+60 )) && kill -0 "$pid" 2>/dev/null; then printf 'waiting\n'; else rm -f -- "$file"; fi
done
WAITERS
); then
        REMOTE_SHUTDOWN_SKIPPED_REASON="Queued backup status could not be verified"
        return 1
    fi
    if [[ -n "$waiters" ]]; then
        SHUTDOWN_RESULT=deferred
        REMOTE_SHUTDOWN_SKIPPED_REASON="Another backup is waiting for ISS; leaving it running for handoff"
        return 1
    fi
}
backup_request_shutdown() {
    backup_lease_alive || return 1
    BACKUP_SSH_COMMAND_TIMEOUT=30 backup_ssh bash -s <<'SHUTDOWN'
set -euo pipefail
if [[ -x /usr/local/sbin/powerdown ]]; then command=/usr/local/sbin/powerdown
elif command -v powerdown >/dev/null; then command=$(command -v powerdown)
elif command -v poweroff >/dev/null; then command=$(command -v poweroff)
else exit 3; fi
date +%s >/run/hubble-iss-shutdown.pending
nohup "$command" >/run/hubble-iss-shutdown.log 2>&1 </dev/null &
printf 'Clean shutdown queued; pid=%s\n' "$!"
SHUTDOWN
}
backup_bound_log() {
    local file="$1" limit="$2" temp
    [[ -f "$file" ]] || return 0
    (( $(stat -c %s "$file") > limit )) || return 0
    temp=$(mktemp "${file}.bounded.XXXXXX") || return 1
    tail --bytes="$limit" -- "$file" >"$temp" && mv -f -- "$temp" "$file" || { rm -f -- "$temp"; return 1; }
}
backup_phase() {
    local now
    now=$(date +%s)
    printf '%s [PHASE] %s: %ss elapsed\n' "$(date '+%F %T')" "$BACKUP_PHASE" "$((now-BACKUP_PHASE_STARTED))" >>"$LOG_FILE"
    BACKUP_PHASE="$1"; BACKUP_PHASE_STARTED="$now"
}
BACKUP_PHASE_STARTED=$BACKUP_STARTED
backup_finish() {
    local rc=$? status=OK temp summary
    trap - EXIT INT TERM PIPE
    (( rc == 0 )) || status=FAILED
    [[ "$BACKUP_RESULT" != OK || "$status" != FAILED ]] || status=WARNING
    [[ "${DRY_RUN:-false}" != true || "$status" != OK ]] || status=WARNING
    [[ "$RETENTION_RESULT" != FAILED || "$status" != OK ]] || status=WARNING
    case "$RESTORE_DRILL_RESULT" in FAILED|WARNING) [[ "$status" != OK ]] || status=WARNING;; esac
    [[ "$SHUTDOWN_RESULT" == deferred || ( -z "${REMOTE_SHUTDOWN_SKIPPED_REASON:-}" && "${REMOTE_SHUTDOWN_FAILED:-0}" == 0 ) ]] || { [[ "$status" != OK ]] || status=WARNING; }
    [[ "$SHUTDOWN_RESULT" == deferred || -z "${REMOTE_SHUTDOWN_SKIPPED_REASON:-}" ]] || SHUTDOWN_RESULT=skipped
    if (( rc == 0 )); then BACKUP_PHASE=completed; fi
    summary="${SCRIPT_ID} v${SCRIPT_VERSION}; copy=$BACKUP_RESULT; verify=$VERIFICATION_RESULT; retention=$RETENTION_RESULT; phase=$BACKUP_PHASE; duration=$(( $(date +%s)-BACKUP_STARTED ))s; shutdown=$SHUTDOWN_RESULT ${REMOTE_SHUTDOWN_SKIPPED_REASON:-}"
    if (( rc != 0 )) && [[ "$BACKUP_NOTIFIED" != true && -x "${NOTIFY_BIN:-}" ]]; then
        local last_error
        last_error=$(awk '/\[ERROR\]| \| ERROR \| / {last=$0} END {sub(/^.*(\[ERROR\] | \| phase=[^|]*\| )/,"",last); print last}' "$LOG_FILE" 2>/dev/null)
        VAULT_NOTIFICATION_REASON="$BACKUP_PHASE|$BACKUP_RESULT|$VERIFICATION_RESULT|$RETENTION_RESULT|$last_error"
        notify_unraid alert 'Backup failed' "$summary
Last error: ${last_error:-No structured error line was captured; phase and exit state above identify the failed step.}
ISS shutdown was not forced after this failure; any undelivered appdata request remains eligible for retry.
Log: $LOG_FILE"
    fi
    [[ "$NOTIFICATION_RESULT" != failed && "$NOTIFICATION_RESULT" != unavailable || "$status" != OK ]] || status=WARNING
    if mountpoint -q /mnt/vault && command -v jq >/dev/null; then
        mkdir -p -- "$STATUS_DIR"
        temp=$(mktemp "$STATUS_DIR/.${SCRIPT_ID}.XXXXXX") &&
            jq -n --argjson drillEpoch "$RESTORE_DRILL_EPOCH" --arg drill "$RESTORE_DRILL_RESULT" --arg drillSummary "$RESTORE_DRILL_SUMMARY" --arg name "$SCRIPT_ID" --arg status "$status" --arg summary "$summary" --arg phase "$BACKUP_PHASE" --arg copy "$BACKUP_RESULT" --arg verification "$VERIFICATION_RESULT" --arg retention "$RETENTION_RESULT" --arg notification "$NOTIFICATION_RESULT" --arg shutdown "$SHUTDOWN_RESULT" --arg shutdown_reason "${REMOTE_SHUTDOWN_SKIPPED_REASON:-}" --arg version "$SCRIPT_VERSION" --arg log "$LOG_FILE" --argjson duration "$(( $(date +%s)-BACKUP_STARTED ))" --argjson epoch "$(date +%s)" \
            '{restoreDrillEpoch:$drillEpoch,restoreDrill:$drill,restoreDrillSummary:$drillSummary,name:$name,status:$status,summary:$summary,phase:$phase,copy:$copy,verification:$verification,retention:$retention,notification:$notification,shutdown:$shutdown,shutdown_reason:$shutdown_reason,scriptVersion:$version,duration_seconds:$duration,log:$log,epoch:$epoch}' >"$temp" && mv -f -- "$temp" "$STATUS_DIR/$SCRIPT_ID.json"
    fi
    [[ -z "$LEASE_INPUT" ]] || exec {LEASE_INPUT}>&-
    [[ -z "$LEASE_PID" ]] || { kill "$LEASE_PID" 2>/dev/null || true; wait "$LEASE_PID" 2>/dev/null || true; }
    [[ ${#TRANSPORT_OPTIONS[@]} == 0 ]] || ssh "${TRANSPORT_OPTIONS[@]}" -O exit "$REMOTE" >/dev/null 2>&1 || true
    [[ -z "$BACKUP_TMP" ]] || rm -rf -- "$BACKUP_TMP"
    [[ -z "${TMP_DIR:-}" ]] || rm -rf -- "$TMP_DIR"
    if [[ -n "$OPERATIONS_EXPORT_TEMP" && "$OPERATIONS_EXPORT_TEMP" == "${OPERATIONS_STATE_ROOT%/*}"/.operations-state.*.partial ]]; then rm -rf -- "$OPERATIONS_EXPORT_TEMP"; fi
    [[ ! -f "${LOG_FILE:-}" ]] || backup_bound_log "$LOG_FILE" "$MAX_MAIN_LOG_BYTES" || true
    exit "$rc"
}

###############################################################################
# RUNTIME
###############################################################################

RUN_STAMP="$(date '+%Y%m%d_%H%M%S')"
GENERATION_NAME="hubble-${RUN_STAMP}"
REMOTE_PARTIAL="${REMOTE_VERSION_ROOT}/.${GENERATION_NAME}.partial"
REMOTE_FINAL="${REMOTE_VERSION_ROOT}/${GENERATION_NAME}"
LOG_FILE="${LOG_DIR}/backup_vault_remote-${RUN_STAMP}.log"

TMP_DIR=""

RESULT_SUMMARY="Script exited before completion"
FILES_VERIFIED=0
BYTES_TRANSFERRED=0
REMOTE_SHUTDOWN_FAILED=0
REMOTE_SHUTDOWN_SKIPPED_REASON=""



RSYNC_ARGS=(
    -a
    --delete-delay
    --delete-excluded
    --partial
    --partial-dir=.rsync-partial
    --protect-args
    --stats
    --exclude=*.partial
    --exclude=.rsync-partial
    --exclude=*.tmp
    --exclude=*.sock
)

PRIORITY_PREFIX=()

###############################################################################
# HELPERS
###############################################################################

log() {
    local level="$1"
    shift
    local line
    line=$(usr_ops_log_line "$level" MAIN "$*")
    printf '%s\n' "$line"
    [[ -n "$LOG_FILE" && -d "$LOG_DIR" ]] &&
        { backup_bound_log "$LOG_FILE" "$MAX_MAIN_LOG_BYTES" && printf '%s\n' "$line" >>"$LOG_FILE"; } 2>/dev/null || true
}

# Durable across hourly invocations. The outer vault lock serializes this state;
# only accepted notifications advance its clock. No log or request-age counter is
# used as an incident identity, so an unchanged failure cannot become new hourly.
vault_notification_state_ready() {
    [[ -n "${VAULT_NOTIFICATION_STATE:-}" ]] || VAULT_NOTIFICATION_STATE="$LOG_DIR/notification-state.json"
    [[ "$VAULT_NOTIFICATION_STATE" != /mnt/vault/* ]] || mountpoint -q /mnt/vault || return 1
    [[ ! -L "$VAULT_NOTIFICATION_STATE" && ! -L "${VAULT_NOTIFICATION_STATE%/*}" ]] || return 1
    mkdir -p -- "${VAULT_NOTIFICATION_STATE%/*}" || return 1
    [[ ! -f "$VAULT_NOTIFICATION_STATE" ]] || jq -e '
      .schema==1 and (.activeFailure==null or
        ((.activeFailure.signature|test("^[a-f0-9]{64}$")) and
         (.activeFailure.description|type)=="string" and
         (.activeFailure.firstReportedAt|type)=="number" and
         (.activeFailure.lastSentAt|type)=="number" and
         .activeFailure.firstReportedAt>=0 and .activeFailure.lastSentAt>=0))
      ' "$VAULT_NOTIFICATION_STATE" >/dev/null 2>&1
}

notify_unraid() {
    BACKUP_NOTIFIED=true
    local importance="$1" description="$2" message="$3"
    local state_ready=false incident=false signature="" identity="${ISS_REQUEST_ID:-}" old="" now first=0 last=0 tmp reason=""
    now=$(date +%s)
    vault_notification_state_ready && state_ready=true
    case "$description" in 'ISS handoff unavailable'|'Backup failed') incident=true;; esac
    if [[ "$incident" == true ]]; then
        if [[ -z "$identity" && -f "$ISS_REQUEST_FILE" ]]; then identity=$(sha256sum -- "$ISS_REQUEST_FILE" | cut -d ' ' -f1);fi
        [[ -n "$identity" ]] || identity=no-request
        reason="${VAULT_NOTIFICATION_REASON:-$BACKUP_PHASE|$BACKUP_RESULT|$VERIFICATION_RESULT|$RETENTION_RESULT}"
        signature=$(printf '%s\0' "$identity" "$importance" "$description" "$reason" | sha256sum | cut -d ' ' -f1)
        if usr_ops_vault_delivery_seen "$signature" "$((now-VAULT_FAILURE_REMINDER_SECONDS))";then
            NOTIFICATION_RESULT=suppressed
            log INFO "ISS failure already accepted by notification retry; same request/reason remains under its reminder cooldown"
            return 0
        fi
        if [[ "$state_ready" == true && -f "$VAULT_NOTIFICATION_STATE" ]]; then
            IFS=$'\t' read -r old first last < <(jq -r '[.activeFailure.signature//"",.activeFailure.firstReportedAt//0,.activeFailure.lastSentAt//0]|@tsv' "$VAULT_NOTIFICATION_STATE")
            if [[ "$old" == "$signature" ]] && (( now>=last && now-last<VAULT_FAILURE_REMINDER_SECONDS )); then
                NOTIFICATION_RESULT=suppressed
                log INFO "Repeated ISS failure notification suppressed; same request/reason, reminder interval=${VAULT_FAILURE_REMINDER_SECONDS}s. $description: $reason"
                return 0
            fi
        fi
        [[ "$old" == "$signature" ]] || first="$now"
    elif [[ "$state_ready" == true && -f "$VAULT_NOTIFICATION_STATE" && "$description" == 'Backup completed'* ]]; then
        old=$(jq -r '.activeFailure.description // ""' "$VAULT_NOTIFICATION_STATE")
        [[ -z "$old" ]] || message+=$'\n'"Recovery: previously reported $old is cleared; this generation passed transfer and SHA-256 verification."
    fi
    [[ -x "$NOTIFY_BIN" ]] || { NOTIFICATION_RESULT=unavailable; return 0; }
    if USR_OPS_DELIVERY_CONTEXT="$signature" usr_ops_notify timeout --kill-after=5 30 "$NOTIFY_BIN" -i "$importance" -s "$NOTIFY_SUBJECT" -d "$description" -m "$message" >/dev/null 2>&1; then
        NOTIFICATION_RESULT=sent
        if [[ "$state_ready" == true && ( "$incident" == true || "$description" == 'Backup completed'* ) ]]; then
            tmp=$(mktemp "${VAULT_NOTIFICATION_STATE}.XXXXXX") || { NOTIFICATION_RESULT=failed;log WARN 'Notification accepted but receipt could not be saved; retry deduplication unavailable';return 0; }
            if jq -n --arg signature "$signature" --arg request "$identity" --arg description "$description" --arg reason "$reason" \
                --argjson incident "$incident" --argjson first "$first" --argjson now "$now" \
                '{schema:1,lastAcceptedAt:$now,activeFailure:(if $incident then
                  {signature:$signature,requestId:$request,description:$description,reason:$reason,firstReportedAt:$first,lastSentAt:$now}
                  else null end)}' >"$tmp" && sync -- "$tmp" && mv -f -- "$tmp" "$VAULT_NOTIFICATION_STATE"; then :
            else rm -f -- "$tmp";NOTIFICATION_RESULT=failed;log WARN 'Notification accepted but durable receipt failed; retry deduplication unavailable';fi
        fi
    else
        NOTIFICATION_RESULT=failed
        log WARN 'Notification delivery failed; cooldown was not advanced and the next retry can notify'
    fi
}

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " ")
        i=1
        while (b >= 1024 && i < 5) { b/=1024; i++ }
        printf "%.2f %s", b, u[i]
    }'
}

shell_quote() {
    printf '%q' "$1"
}

ssh_exec() {
    backup_ssh "$1"
}

prune_local_logs() {
    local -a logs=()
    local file
    mapfile -t logs < <(
        find "$LOG_DIR" -maxdepth 1 -type f -name 'backup_vault_remote-*.log' \
            -printf '%T@|%p\n' 2>/dev/null | sort -rn | cut -d'|' -f2-
    )
    for ((i=MAX_LOGS; i<${#logs[@]}; i++)); do
        file="${logs[$i]}"
        rm -f -- "$file" 2>/dev/null || true
    done
    for file in "${logs[@]:0:MAX_LOGS}"; do backup_bound_log "$file" "$MAX_MAIN_LOG_BYTES" || return 1; done
}

build_priority_prefix() {
    PRIORITY_PREFIX=()
    [[ "$USE_LOW_PRIORITY_IO" == true ]] || return 0
    command -v nice >/dev/null 2>&1 &&
        PRIORITY_PREFIX+=(nice -n "$NICE_LEVEL")
    command -v ionice >/dev/null 2>&1 &&
        PRIORITY_PREFIX+=(ionice -c "$IONICE_CLASS" -n "$IONICE_PRIORITY")
}

validate_configuration() {
    local job label source command boolean_name boolean_value
    local -A seen_labels=()
    [[ "$REMOTE_VERSION_ROOT" == /mnt/user/* &&
       "$REMOTE_VERSION_ROOT" != "/mnt/user/" &&
       "$REMOTE_VERSION_ROOT" != *$'\n'* ]] || {
        log ERROR "Unsafe REMOTE_VERSION_ROOT: $REMOTE_VERSION_ROOT"
        return 1
    }
    [[ "$VAULT_RESERVE_BYTES" =~ ^[0-9]+$ && "$PARTIAL_RETENTION_DAYS" =~ ^[0-9]+$ && "$VAULT_MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$REMOTE_KEEP" =~ ^[1-9][0-9]*$ ]] || {
        log ERROR "REMOTE_KEEP must be at least 1"
        return 1
    }
    [[ "$MAX_SSH_WAIT" =~ ^[1-9][0-9]*$ &&
       "$SSH_WAIT_INTERVAL" =~ ^[1-9][0-9]*$ &&
       "$ARRAY_READY_WAIT" =~ ^[1-9][0-9]*$ &&
       "$ARRAY_READY_INTERVAL" =~ ^[1-9][0-9]*$ ]] || {
        log ERROR "Remote readiness timeouts and intervals must be positive integers"
        return 1
    }
    (( SSH_WAIT_INTERVAL <= MAX_SSH_WAIT &&
       ARRAY_READY_INTERVAL <= ARRAY_READY_WAIT )) || {
        log ERROR "Remote readiness intervals must not exceed their timeouts"
        return 1
    }
    (( ${#BACKUP_JOBS[@]} > 0 )) || {
        log ERROR "No BACKUP_JOBS are configured"
        return 1
    }

    for boolean_name in \
        SHUTDOWN_REMOTE_ON_SUCCESS \
        DEFER_REMOTE_SHUTDOWN_WHILE_MOVER \
        DEFER_REMOTE_SHUTDOWN_DURING_PARITY_CHECK \
        DEFER_REMOTE_SHUTDOWN_DURING_CRITICAL_ARRAY_OPERATION
    do
        boolean_value="${!boolean_name}"
        case "$boolean_value" in
            true|false)
                ;;
            *)
                log ERROR "${boolean_name} must be true or false"
                return 1
                ;;
        esac
    done

    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r label source <<<"$job"
        [[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$label" != manifests && "$label" != completed.txt && -z "${seen_labels[$label]:-}" ]] || {
            log ERROR "Unsafe backup label: $label"
            return 1
        }
        seen_labels[$label]=1
        backup_source_ready "$source" || {
            log ERROR "Backup source is unavailable or unsafe: $source"
            return 1
        }
    done

    for command in ssh rsync sha256sum find sort xargs flock jq; do
        command -v "$command" >/dev/null 2>&1 || {
            log ERROR "Required command not found: $command"
            return 1
        }
    done
}

send_wol() {
    [[ "$ENABLE_WOL" == true ]] || return 0
    if command -v etherwake >/dev/null 2>&1; then
        etherwake "$REMOTE_MAC" >/dev/null 2>&1 || true
    elif command -v wakeonlan >/dev/null 2>&1; then
        wakeonlan "$REMOTE_MAC" >/dev/null 2>&1 || true
    else
        log WARN "Wake-on-LAN tool not found; continuing with SSH readiness checks"
    fi
}

wait_for_remote() {
    local ssh_waited=0 array_waited=0 root_q wait_started error_output
    local ssh_ready=0 array_ready=0
    root_q="$(shell_quote "$REMOTE_VERSION_ROOT")"
    send_wol

    wait_started=$(date +%s)
    log INFO "Waiting up to ${MAX_SSH_WAIT}s for $DEST_NAS SSH"
    while (( ssh_waited <= MAX_SSH_WAIT )); do
        if error_output=$(BACKUP_SSH_COMMAND_TIMEOUT=20 ssh_exec "true" 2>&1); then
            ssh_ready=1
            break
        fi
        if grep -qiE 'permission denied|host key verification failed|identification has changed' <<<"$error_output"; then
            log ERROR 'Permanent SSH authentication/host-key failure; readiness retries stopped'
            return 1
        fi
        ssh_waited=$(( $(date +%s)-wait_started ))
        (( ssh_waited >= MAX_SSH_WAIT )) && break
        sleep "$SSH_WAIT_INTERVAL"
        ssh_waited=$(( $(date +%s)-wait_started ))
    done

    (( ssh_ready == 1 )) || {
        log ERROR "$DEST_NAS did not become reachable within ${MAX_SSH_WAIT}s"
        return 1
    }
    log INFO "$DEST_NAS SSH is reachable after ${ssh_waited}s"

    wait_started=$(date +%s)
    log INFO "Waiting up to ${ARRAY_READY_WAIT}s for $DEST_NAS /mnt/user mount"
    while (( array_waited <= ARRAY_READY_WAIT )); do
        if BACKUP_SSH_COMMAND_TIMEOUT=20 ssh_exec 'mountpoint -q /mnt/user 2>/dev/null || grep -qsE "[[:space:]]/mnt/user[[:space:]]" /proc/mounts' \
            >/dev/null 2>&1; then
            array_ready=1
            break
        fi
        (( array_waited >= ARRAY_READY_WAIT )) && break
        sleep "$ARRAY_READY_INTERVAL"
        array_waited=$(( $(date +%s)-wait_started ))
    done

    (( array_ready == 1 )) || {
        log ERROR "$DEST_NAS /mnt/user was not mounted within ${ARRAY_READY_WAIT}s"
        return 1
    }
    log INFO "$DEST_NAS /mnt/user is mounted after ${array_waited}s"

    if ! ssh_exec "test -d $root_q && test ! -L $root_q"; then
        log ERROR "Remote version root is missing, unavailable, or a symlink: $REMOTE_VERSION_ROOT"
        return 1
    fi
}


# Resumable staging is never restore-ready until promoted with completed.txt.
PARTIAL_RETENTION_DAYS=14
VAULT_RESERVE_BYTES=$((10 * 1024 * 1024 * 1024))
VAULT_MAX_ATTEMPTS=3
PRODUCER_LOCK_FDS=()
declare -A MANIFEST_FILES=() MANIFEST_BYTES=() SOURCE_FINGERPRINT=()
vault_producer_locks() {
    local file fd
    for file in /tmp/backup_cache_appdata.lock /tmp/backup_boot_disk.lock; do
        exec {fd}>"$file" || return 1
        flock -s -n "$fd" || { log ERROR "Backup producer is active: $file; retry this vault run later"; return 1; }
        PRODUCER_LOCK_FDS+=("$fd")
    done
}
vault_select_sources() {
    local job label source latest root
    local -a selected=()
    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r label source <<<"$job"
        backup_source_ready "$source" || { log ERROR "Source mount/identity failed: $source"; return 1; }
        if [[ "$label" == appdata ]]; then
            root="$source"
            latest=$(find "$source" -mindepth 1 -maxdepth 1 -type d -name 'backup_[0-9]*_[0-9]*' ! -name '*.partial' -printf '%f\n' | sort | tail -n 1)
            [[ -n "$latest" ]] || { log ERROR "No completed appdata generation exists in $source"; return 1; }
            [[ "$latest" =~ ^backup_[0-9]{8}_[0-9]{6}$ ]] || return 1
            source="$root/$latest"
            [[ -f "$source/backup_manifest.tsv" && -f "$source/backup_manifest.tsv.sha256" ]] &&
                (cd "$source" && sha256sum -c -- backup_manifest.tsv.sha256 >/dev/null) || { log ERROR "Appdata generation manifest is missing or invalid"; return 1; }
            log INFO "Selected completed appdata generation: $source"
        fi
        selected+=("$label|$source")
    done
    BACKUP_JOBS=("${selected[@]}")
}
# Return 10 for a harmless no-op. Malformed/stale requests fail visibly.
vault_pending_request() {
    local digest completed now delivered="" root="" job label source
    VAULT_NOTIFICATION_REASON="request-schema"
    [[ -f "$ISS_REQUEST_FILE" ]] || return 10
    jq -e '.schema==1 and (.generation|type=="string") and
      (.manifestSha256|test("^[a-f0-9]{64}$")) and
      (.completedAt|type=="number" and .==floor and .>0)' "$ISS_REQUEST_FILE" >/dev/null || return 1
    ISS_REQUEST_GENERATION=$(jq -r .generation "$ISS_REQUEST_FILE") || return 1
    digest=$(jq -r .manifestSha256 "$ISS_REQUEST_FILE") || return 1
    completed=$(jq -r .completedAt "$ISS_REQUEST_FILE") || return 1
    now=$(date +%s)
    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r label source <<<"$job"
        [[ "$label" != appdata ]] || root="$source"
    done
    VAULT_NOTIFICATION_REASON="generation-path-unavailable"
    [[ -n "$root" && "$ISS_REQUEST_GENERATION" == "$root"/backup_* &&
       "${ISS_REQUEST_GENERATION##*/}" =~ ^backup_[0-9]{8}_[0-9]{6}$ &&
       -d "$ISS_REQUEST_GENERATION" && ! -L "$ISS_REQUEST_GENERATION" &&
       $(realpath -e -- "$ISS_REQUEST_GENERATION") == "$ISS_REQUEST_GENERATION" ]] || return 1
    ISS_REQUEST_ID="${ISS_REQUEST_GENERATION##*/}:$digest"
    VAULT_NOTIFICATION_REASON="delivery-receipt-invalid"
    if [[ -f "$ISS_DELIVERED_FILE" ]]; then delivered=$(jq -r '.requestId // ""' "$ISS_DELIVERED_FILE") || return 1; fi
    [[ "$ISS_REQUEST_ID" != "$delivered" || "${1:-}" == --force ]] || return 10
    VAULT_NOTIFICATION_REASON="request-stale-or-future-dated"
    (( completed <= now && now-completed <= MAX_PRODUCER_AGE_SECONDS )) || {
        printf 'Pending ISS request is stale/future-dated; source backup must succeed again\n' >&2; return 1;
    }
    VAULT_NOTIFICATION_REASON="producer-manifest-changed"
    [[ $(sha256sum "$ISS_REQUEST_GENERATION/backup_manifest.tsv" | awk '{print $1}') == "$digest" ]] || return 1
    VAULT_NOTIFICATION_REASON=""
}
vault_acknowledge_request() {
    [[ -n "$ISS_REQUEST_ID" ]] || return 0
    local tmp
    mkdir -p -- "${ISS_DELIVERED_FILE%/*}" || return 1
    tmp=$(mktemp "${ISS_DELIVERED_FILE}.XXXXXX") || return 1
    if jq -n --arg requestId "$ISS_REQUEST_ID" --arg source "$ISS_REQUEST_GENERATION" \
      --arg remote "$REMOTE_FINAL" --argjson verifiedAt "$(date +%s)" \
      '{schema:1,requestId:$requestId,source:$source,remote:$remote,verifiedAt:$verifiedAt,verification:"sha256"}' >"$tmp" &&
      mv -f -- "$tmp" "$ISS_DELIVERED_FILE"; then return 0; fi
    rm -f -- "$tmp"; return 1
}
# Reuse the producer's expected archive digests in the transfer manifest. The
# existing remote SHA pass then proves the original backup, with no second full
# read of every local archive or repeated remote payload checksum pass.
vault_appdata_manifest() {
    local source="$1" manifest="$2" raw bytes hash name path rows=0 expected
    local -A hashes=()
    expected=$(sed -n 's/^# archive_count=//p' "$source/backup_manifest.tsv")
    [[ "$expected" =~ ^[1-9][0-9]*$ ]] || return 1
    while IFS=$'\t' read -r raw bytes hash name; do
        [[ "$raw" == \#* ]] && continue
        [[ "$raw" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ && "$hash" =~ ^[a-f0-9]{64}$ &&
           "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && -z "${hashes[$name]+present}" ]] || return 1
        hashes[$name]="$hash"; rows=$((rows+1))
        [[ -f "$source/$name.tar.gz" && ! -L "$source/$name.tar.gz" &&
           $(stat -c %s "$source/$name.tar.gz") == "$bytes" ]] || return 1
    done <"$source/backup_manifest.tsv"
    (( rows == expected )) || return 1
    : >"$manifest"
    while IFS= read -r -d '' path; do
        if [[ "$path" == ./*.tar.gz && "${path#./}" != */* ]]; then
            name="${path#./}"; name="${name%.tar.gz}"
            [[ -n "${hashes[$name]:-}" ]] || return 1
            printf '%s  %s\n' "${hashes[$name]}" "$path" >>"$manifest"
        else
            (cd "$source" && sha256sum -- "$path") >>"$manifest" || return 1
        fi
    done <"$manifest.files"
}

# Default weekly drills use Singapore calendar weeks, preventing small backup
# duration changes from skipping the same weekday's next opportunity on ISS.
# Non-weekly custom intervals retain elapsed-time semantics. No wake is added.
vault_restore_drill_due() {
    local last="$1" now="$2" interval="$3" previous_week current_week
    [[ "$last" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ && "$interval" =~ ^[1-9][0-9]*$ ]] || return 2
    ((last<=now)) || return 2
    ((last>0)) || return 0
    if ((interval==604800));then
        previous_week=$(TZ=Asia/Singapore date -d "@$last" +%G-%V) || return 2
        current_week=$(TZ=Asia/Singapore date -d "@$now" +%G-%V) || return 2
        [[ "$previous_week" != "$current_week" ]]
    else ((now-last>=interval));fi
}

vault_remote_restore_drill() {
    [[ "$RUN_REMOTE_RESTORE_DRILL" == true ]] || { RESTORE_DRILL_RESULT=disabled; return 0; }
    local root="$REMOTE_VERSION_ROOT/restore_drill" last digest remote_script output rc=0
    [[ -f "$RESTORE_DRILL_SCRIPT" && ! -L "$RESTORE_DRILL_SCRIPT" ]] || {
        RESTORE_DRILL_SUMMARY="Restore drill script is missing on Hubble; no drill performed"; return 1;
    }
    last=$(ssh_exec "if test -f $(shell_quote "$root/status/backup_restore_drill.json"); then jq -r 'if .status==\"OK\" or .status==\"WARNING\" then .epoch else 0 end' $(shell_quote "$root/status/backup_restore_drill.json"); else printf 0; fi") || return 1
    [[ "$last" =~ ^[0-9]+$ ]] || return 1
    RESTORE_DRILL_EPOCH=$last
    local due_rc=0
    vault_restore_drill_due "$last" "$(date +%s)" "$RESTORE_DRILL_INTERVAL_SECONDS" || due_rc=$?
    if ((due_rc==1));then RESTORE_DRILL_SUMMARY="ISS restore drill already completed in the current Singapore week/interval; last completed epoch=$last";return 0
    elif ((due_rc!=0));then RESTORE_DRILL_SUMMARY='ISS restore-drill timestamp/cadence invalid; existing backup retained';return 1;fi
    backup_phase restore-drill
    remote_script="$REMOTE_VERSION_ROOT/.hubble-restore-drill.sh"
    digest=$(sha256sum "$RESTORE_DRILL_SCRIPT" | awk '{print $1}') || return 1
    rsync -a --protect-args "$RESTORE_DRILL_SCRIPT" "$REMOTE:$remote_script" || return 1
    output="$TMP_DIR/remote-drill.log"
    # No second email from ISS: its detailed receipt joins the vault notification.
    # A timeout is a drill failure, not permission to invalidate/delete a backup.
    ssh_exec "test \"\$(sha256sum $(shell_quote "$remote_script") | awk '{print \$1}')\" = '$digest' && VAULT_MOUNT=/mnt/user DRILL_ROOT=$(shell_quote "$root") LOG_DIR=$(shell_quote "$root/logs") STATUS_DIR=$(shell_quote "$root/status") NOTIFY_BIN=/nonexistent timeout --signal=TERM --kill-after=15 7200 bash $(shell_quote "$remote_script") --generation-root $(shell_quote "$REMOTE_FINAL")" >"$output" 2>&1 || rc=$?
    tail -n 20 "$output" >>"$LOG_FILE"
    if (( rc != 0 )); then
        RESTORE_DRILL_SUMMARY="ISS extraction/database drill failed (exit=$rc); verified backup retained. Evidence: $root/logs"; return 1
    fi
    RESTORE_DRILL_EPOCH=$(ssh_exec "jq -r '.epoch' $(shell_quote "$root/status/backup_restore_drill.json")") || return 1
    RESTORE_DRILL_SUMMARY=$(ssh_exec "jq -r '.summary' $(shell_quote "$root/status/backup_restore_drill.json")") || return 1
    RESTORE_DRILL_RESULT=$(ssh_exec "jq -r '.status' $(shell_quote "$root/status/backup_restore_drill.json")") || return 1
    [[ "$RESTORE_DRILL_RESULT" == OK || "$RESTORE_DRILL_RESULT" == WARNING ]]
}

# Read-only control-plane capture. Private Docker inspect output can contain
# credentials; never print it or publish it to GitHub. No container is changed.
RECOVERY_SUMMARY="not captured"
RECOVERY_CAPTURE_WARNING=false
RECOVERY_BOOT_ROOT="${RECOVERY_BOOT_ROOT:-/boot}"
recovery_docker() { timeout 30 docker "$@"; }
vault_capture_recovery() {
    local root="$1" boot="$RECOVERY_BOOT_ROOT" file rel before after size total=0
    local status=complete spec label source container_count=0 uncovered=0
    mkdir -m 700 "$root" "$root/boot-config" || return 1
    printf '[]\n' >"$root/files.json"
    # Explicit control files only: omit plugin binaries, logs and backup ZIPs.
    if [[ -d "$boot/config" && ! -L "$boot/config" ]]; then
        while IFS= read -r -d '' file; do
            rel=${file#"$boot/"}
            case "$rel" in
                config/docker.cfg|config/network.cfg|config/network-rules.cfg|config/ident.cfg|config/shares/*.cfg|config/plugins/dockerMan/templates-user/*.xml|config/plugins/user.scripts/schedule.json|config/plugins/user.scripts/customSchedule.cron|config/plugins/user.scripts/scripts/*/script|config/plugins/user.scripts/scripts/*/name|config/plugins/user.scripts/scripts/*/description) ;;
                *) continue;;
            esac
            [[ "$rel" != *$'\n'* && "$rel" != *$'\r'* && $(realpath -e "$file") == "$file" ]] || return 1
            size=$(stat -c %s "$file") || return 1
            total=$((total+size)); ((total <= OPERATIONS_STATE_MAX_BYTES)) || return 1
            before=$(sha256sum "$file" | awk '{print $1}') || return 1
            mkdir -p -- "$root/boot-config/${rel%/*}" || return 1
            cp -p -- "$file" "$root/boot-config/$rel" || return 1
            after=$(sha256sum "$file" | awk '{print $1}') || return 1
            [[ "$before" == "$after" && "$before" == "$(sha256sum "$root/boot-config/$rel" | awk '{print $1}')" ]] || return 1
            jq --arg path "$rel" --arg hash "$before" --argjson bytes "$size" \
                --arg owner "$(stat -c '%u:%g:%a' "$file")" \
                '. + [{path:$path,sha256:$hash,bytes:$bytes,originalOwnerGroupMode:$owner}]' \
                "$root/files.json" >"$root/files.next" && mv "$root/files.next" "$root/files.json" || return 1
        done < <(find "$boot/config" -type f -print0)
    else
        status=partial
    fi
    # Snapshot-local catalogue documents exactly which scripts/schedules were
    # captured. It never removes a missing payload or rewrites archived settings.
    if ! usr_scripts_catalog "$root/boot-config/config/plugins/user.scripts/schedule.json" "$root/boot-config/config/plugins/user.scripts/scripts" snapshot >"$root/user-scripts-catalog.json";then
      status=partial
    elif jq -e 'any(.jobs[];.enabled and (.present|not))' "$root/user-scripts-catalog.json" >/dev/null;then status=partial;fi
    for file in containers images networks volumes; do printf '[]\n' >"$root/$file.json"; done
    # Lists are stored in files, not expanded into one enormous argv.
    if recovery_docker ps -aq --no-trunc >"$root/container-ids.txt" 2>/dev/null; then
        while IFS= read -r file; do
            [[ "$file" =~ ^[a-f0-9]{12,64}$ ]] || { status=partial; continue; }
            if recovery_docker inspect "$file" >"$root/inspect.tmp" 2>/dev/null && jq -e 'type=="array" and length==1' "$root/inspect.tmp" >/dev/null; then
                jq -s '.[0]+.[1]' "$root/containers.json" "$root/inspect.tmp" >"$root/merge.tmp" && mv "$root/merge.tmp" "$root/containers.json" || return 1
            else status=partial; fi
        done <"$root/container-ids.txt"
        if recovery_docker ps -aq --no-trunc >"$root/container-ids-after.txt" 2>/dev/null; then
            sort "$root/container-ids.txt" >"$root/ids-before.tmp"
            sort "$root/container-ids-after.txt" >"$root/ids-after.tmp"
            cmp -s "$root/ids-before.tmp" "$root/ids-after.tmp" || status=partial
        else status=partial; fi
        jq -r '.[].Image' "$root/containers.json" | sort -u >"$root/image-ids.txt"
        for spec in images networks volumes; do
            case "$spec" in
                images) source="$root/image-ids.txt";;
                networks) source="$root/network-ids.txt"; recovery_docker network ls -q >"$source" 2>/dev/null || status=partial;;
                volumes) source="$root/volume-names.txt"; recovery_docker volume ls -q >"$source" 2>/dev/null || status=partial;;
            esac
            while IFS= read -r file; do
                [[ -n "$file" && "$file" != -* ]] || continue
                case "$spec" in images) label=image;; networks) label=network;; volumes) label=volume;; esac
                if recovery_docker "$label" inspect "$file" >"$root/inspect.tmp" 2>/dev/null && jq -e 'type=="array" and length==1' "$root/inspect.tmp" >/dev/null; then
                    jq -s '.[0]+.[1]' "$root/$spec.json" "$root/inspect.tmp" >"$root/merge.tmp" && mv "$root/merge.tmp" "$root/$spec.json" || return 1
                else status=partial; fi
            done <"$source"
        done
    else status=unavailable; fi
    # Policies are evidence, not a claim of payload verification. Never source
    # another script or infer /mnt/user aliases or named-volume data coverage.
    printf '[]\n' >"$root/policies.json"
    for spec in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r label source <<<"$spec"
        jq --arg label "$label" --arg source "$source" '.+[{label:$label,source:$source,evidence:"configured ISS source; transfer verification occurs later"}]' \
            "$root/policies.json" >"$root/merge.tmp" && mv "$root/merge.tmp" "$root/policies.json" || return 1
    done
    if [[ -f "${ISS_REQUEST_GENERATION:-}/backup_manifest.tsv" ]]; then
        cp -- "$ISS_REQUEST_GENERATION/backup_manifest.tsv" "$root/appdata-producer-manifest.tsv" || return 1
    fi
    jq --slurpfile policies "$root/policies.json" '
        [.[] | .Name as $name | .Mounts[]? | . as $m |
        {container:$name,type:.Type,source:.Source,destination:.Destination,readWrite:.RW,
         matchingConfiguredSources:[$policies[0][] | select(.source as $s | $m.Source==$s or ($m.Source|startswith($s+"/"))) | .label],
         payloadStatus:(if .Type=="volume" then "named-volume contents require explicit backup"
           elif (.Source|test("^/(dev|proc|sys|run|tmp)(/|$)")) then "system or transient mount; review dependency"
           else "unverified: check appdata manifest, exclusions and media mirror separately" end)}]' \
        "$root/containers.json" >"$root/coverage.json" || return 1
    if [[ -f "$root/appdata-producer-manifest.tsv" ]]; then
        source=$(sed -n 's/^# source=//p' "$root/appdata-producer-manifest.tsv")
        jq -n --arg source "$source" --rawfile manifest "$root/appdata-producer-manifest.tsv" \
            '{source:$source,archivedNames:[$manifest|split("\n")[]|select(length>0 and (startswith("#")|not))|split("\t")|.[3]],scope:"producer archive names only; per-path exclusions still apply"}' \
            >"$root/appdata-coverage.json" || return 1
    fi
    container_count=$(jq length "$root/containers.json")
    uncovered=$(jq '[.[]|select(.payloadStatus|startswith("named-volume"))]|length' "$root/coverage.json")
    jq -n --arg status "$status" --arg host "$(hostname)" --arg kernel "$(uname -r)" \
        --arg generation "${ISS_REQUEST_GENERATION:-}" --argjson epoch "$(date +%s)" \
        --argjson containers "$container_count" --argjson namedVolumes "$uncovered" \
        '{schema:1,capturedAt:$epoch,host:$host,kernel:$kernel,producerGeneration:$generation,
          runtimeStatus:$status,containerCount:$containers,namedVolumeMounts:$namedVolumes,
          scope:"read-only configuration capture; not an application startup test or proof of mount payload coverage"}' >"$root/inventory.json" || return 1
    cat >"$root/RESTORE.md" <<'RUNBOOK'
# Hubble recovery runbook

This private bundle contains credentials in Docker environment/template settings.
Keep it off public repositories. Inventory commands never modify Docker.

1. Keep the original failed disks and backups intact. Install a compatible Unraid
   release on replacement flash; restore flash configuration deliberately. Confirm
   disk serials and assignments before starting the array; never blindly apply
   super.dat to different disks. Restore network access and licensing as required.
2. Disable Docker autostart, User Scripts schedules and automatic download/import,
   metadata and cleanup jobs until paths and restored data have been checked.
3. Choose a completed SHA-verified backup generation. Restore appdata, flash
   control files, User Scripts, GitHub, photos and operational state from compatible
   times. The media/secure mirror is separate from vault generations. Check its
   exclusions and latest transfer result; deleted mirrored data is not versioned.
4. Review files.json for original owner/group/mode. boot-config contains a compact
   control-plane copy, not a complete flash backup. Docker templates and schedules
   supplement the full flash ZIP. Restore only the selected settings you need.
5. Review containers.json, images.json, networks.json and volumes.json. Recreate
   required network drivers/IPAM and mount paths first. Inspect recorded image IDs,
   RepoDigests and architecture; tags can change and digests may become unavailable.
   This bundle contains no image layers and no named-volume contents. Do not
   automatically execute captured environment values or blindly replay inspect.
6. Check coverage.json, policies.json and the producer manifest. Configured paths
   do not prove payload coverage. Appdata exclusions, external mounts, named
   volumes and the separate remote media mirror need individual review. Do not
   assume /mnt/user and pool paths are aliases without checking the restored layout.
7. Restore databases and configuration before starting one service at a time.
   Validate application access and actual media paths; the bounded restore drill
   does not start containers or certify a complete working system.
8. Restore script state with its matching application state. Let mutation journals
   reconcile exact API/file IDs; do not blindly replay actions or restore /run
   locks, PIDs, heartbeats or maintenance leases. Verify a new backup and monitor
   baseline, then deliberately re-enable schedules, imports and cleanup policies.
RUNBOOK
    rm -f -- "$root/"*.tmp "$root/container-ids-after.txt"
    # Secure copied files beneath a private parent. Original modes are recorded.
    find "$root" -type d -exec chmod 700 {} + || return 1
    find "$root" -type f -exec chmod 600 {} + || return 1
    (cd "$root" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS) || return 1
    chmod 600 "$root/SHA256SUMS"
    [[ "$status" == complete && "$uncovered" == 0 ]] || RECOVERY_CAPTURE_WARNING=true
    RECOVERY_SUMMARY="runtime=$status; containers=$container_count; named-volume mounts needing payload review=$uncovered; mount coverage requires policy review"
    log INFO "Recovery inventory: $RECOVERY_SUMMARY"
}

vault_export_operations_state() {
    local fd spec name source file base size total=0 temp previous current_hash copied_hash optional_media_bytes=0
    local scripts="$OPERATIONS_SCRIPT_ROOT"
    local -a sources=(
        "execution|$STATUS_DIR/execution"
        "notification-outbox|$STATUS_DIR/notification-outbox"
        "backup_restore_drill|$scripts/backup_restore_drill"
        "backup_vault_remote|$scripts/backup_vault_remote"
        "media_health_monitor|$scripts/media_health_monitor"
        "media_cleanup|$scripts/media_cleanup"
        "media_cleanup/arr|$scripts/media_cleanup/arr"
        "media_cleanup/sab|$scripts/media_cleanup/sab"
        "media_cleanup/quarantine|$scripts/media_cleanup/quarantine"
        "media_cleanup/sab/purge-receipts|$scripts/media_cleanup/sab/purge-receipts"
        "media_cleanup/quarantine/purge-receipts|$scripts/media_cleanup/quarantine/purge-receipts"
        "docker_service_watchdog|$scripts/docker_service_watchdog"
        "system_update_coordinator|$scripts/system_update_coordinator"
        "dns_redundancy_watchdog|$scripts/dns_redundancy_watchdog"
        "media_plex_dbrepair|$scripts/media_plex_dbrepair"
        "media_metadata_audit|$scripts/media_metadata_audit"
        "imagemaid_restore_archive|$scripts/imagemaid_restore_archive"
        "backup_health_audit|$scripts/backup_health_audit"
        "media_torrent_management|$scripts/media_torrent_management/state"
        "media_integrity_audit|$scripts/media_integrity_audit"
    )
    [[ "$OPERATIONS_STATE_ROOT" == "$OPERATIONS_STATE_MOUNT_ROOT"/backup/* && ! -L "$OPERATIONS_STATE_ROOT" &&
       $(realpath -m "$OPERATIONS_STATE_ROOT") == "$OPERATIONS_STATE_ROOT" ]] || return 1
    if [[ -e "$OPERATIONS_STATE_ROOT" ]]; then
        [[ -d "$OPERATIONS_STATE_ROOT" && -f "$OPERATIONS_STATE_ROOT/.owner" && $(cat "$OPERATIONS_STATE_ROOT/.owner") == vault_operations_state ]] || {
            log ERROR 'Existing operational-state directory is unowned; preserved without changes'; return 1;
        }
    fi
    exec {fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || return 1
    if ! flock -x -w 600 "$fd"; then exec {fd}>&-; log ERROR 'Operational-state writers did not quiesce; no ISS wake performed'; return 1; fi
    temp=$(mktemp -d "${OPERATIONS_STATE_ROOT%/*}/.operations-state.XXXXXX.partial") || { exec {fd}>&-; return 1; }
    OPERATIONS_EXPORT_TEMP="$temp"
    chmod 700 "$temp"
    printf 'vault_operations_state\n' >"$temp/.owner" || { exec {fd}>&-; return 1; }
    for spec in "${sources[@]}"; do
        IFS='|' read -r name source <<<"$spec"
        [[ -d "$source" && ! -L "$source" ]] || continue
        mkdir -p "$temp/$name" || { exec {fd}>&-; return 1; }
        while IFS= read -r -d '' file; do
            base=${file##*/}
            # Explicit current files, never dated backup snapshots or generic logs.
            if [[ "$name" == execution || "$name" == notification-outbox ]];then
                [[ "$base" == *.json ]] || continue
            else
            case "$base" in
                active-operation.json) [[ "$name" == media_plex_dbrepair ]] || continue;;
                restore-coverage.json) [[ "$name" == backup_restore_drill ]] || continue;;
                recovery.json|recovery.previous.json)
                    [[ "$name" == media_integrity_audit ]] || continue
                    # Recovery intents/holds are required control-plane material,
                    # unlike the optional bulk read-only verification queue.
                    jq -e '.schema==1 and (.actions|type)=="object"' "$file" >/dev/null || { log ERROR 'Media recovery journal invalid; control-plane export stopped';exec {fd}>&-;return 1; };;
                state.json.gz|notified.json|pending-notification.json)
                    [[ "$name" == media_integrity_audit ]] || continue
                    # Read-only audit progress is optional recovery material.
                    # A damaged queue must not block the actual data backup.
                    if [[ "$base" == *.gz ]]; then
                        if ! gzip -t "$file" 2>/dev/null; then log WARNING 'Optional media integrity queue invalid; excluded from state export';continue;fi
                    elif ! jq -e . "$file" >/dev/null 2>&1; then log WARNING 'Optional media integrity delivery state invalid; excluded from export';continue;fi;;
                *.jsonl|*.tsv)
                    [[ "$name" == media_cleanup/*/purge-receipts || "$base" == action-receipts.jsonl || "$base" == pending-notifications.jsonl || "$base" == operation-recovery.jsonl || "$base" == quarantine-index.tsv || "$base" == transfer-manifest.tsv ]] || continue;;
                notification-outbox.json|latest-run.json)
                    [[ "$name" == media_cleanup || "$name" == media_cleanup/quarantine ]] || continue;;
                policy.json) [[ "$name" == system_update_coordinator ]] || continue;;
                state.json|notification-state.json|import-receipts.json|automation-actions.json|policy-actions.json|sonarr-state.json|radarr-state.json|pending-actions.json|pending-operations.json|action-receipts.jsonl|pending-notifications.jsonl|operation-recovery.jsonl|quarantine-index.tsv|transfer-manifest.tsv) ;;
                *) continue;;
            esac
            fi
            size=$(stat -c %s "$file") || { exec {fd}>&-; return 1; }
            if [[ "$name" == media_integrity_audit && "$base" != recovery.json && "$base" != recovery.previous.json ]] && (( total+size>OPERATIONS_STATE_MAX_BYTES )); then
                log WARNING 'Optional media integrity queue exceeds export budget; omitted without blocking data backup';continue
            fi
            total=$((total+size))
            [[ "$name" != media_integrity_audit || ( "$base" == recovery.json || "$base" == recovery.previous.json ) ]] || optional_media_bytes=$((optional_media_bytes+size))
            if [[ "$name" == media_integrity_audit && ( "$base" == recovery.json || "$base" == recovery.previous.json ) ]] && ((total>OPERATIONS_STATE_MAX_BYTES && optional_media_bytes>0)); then
                rm -f -- "$temp/media_integrity_audit/state.json.gz" "$temp/media_integrity_audit/notified.json" "$temp/media_integrity_audit/pending-notification.json"
                total=$((total-optional_media_bytes));optional_media_bytes=0
                log WARNING 'Optional integrity progress omitted to retain required media recovery journal'
            fi
            (( total<=OPERATIONS_STATE_MAX_BYTES )) || { exec {fd}>&-; log ERROR 'Operational state exceeds export budget; previous snapshot retained'; return 1; }
            [[ "$base" != *.json ]] || jq -e . "$file" >/dev/null || { exec {fd}>&-; return 1; }
            cp -p -- "$file" "$temp/$name/$base" || { exec {fd}>&-; return 1; }
            chmod 600 "$temp/$name/$base"
            current_hash=$(sha256sum "$file" | awk '{print $1}')
            copied_hash=$(sha256sum "$temp/$name/$base" | awk '{print $1}')
            [[ "$current_hash" == "$copied_hash" ]] || { exec {fd}>&-; return 1; }
        done < <(find "$source" -maxdepth 1 -type f -print0)
    done
    local required
    for required in "${OPERATIONS_REQUIRED_STATE_FILES[@]}"; do
        if [[ ! -f "$temp/$required" ]]; then
            exec {fd}>&-
            log ERROR "Required operational state is missing: $required; previous export retained"
            return 1
        fi
    done
    (( total>0 )) || { exec {fd}>&-; log ERROR 'No current operational state found; empty export refused'; return 1; }
    # Point 7 remains excluded: do not change disk-health scheduling/code. Its
    # private config is copied under its existing lock, independently of logs.
    local health_source="$scripts/health_monitoring/state/health_monitoring.conf" health_fd
    if [[ -f "$health_source" && ! -L "$health_source" ]]; then
        exec {health_fd}>/run/health_monitoring.lock || { exec {fd}>&-; return 1; }
        if ! flock -n "$health_fd"; then exec {health_fd}>&-; exec {fd}>&-; return 1; fi
        mkdir "$temp/health_monitoring" && cp -p "$health_source" "$temp/health_monitoring/health_monitoring.conf" || { exec {health_fd}>&-; exec {fd}>&-; return 1; }
        exec {health_fd}>&-
    fi
    cat >"$temp/RESTORE.txt" <<'RESTORE'
Operational state export; bulk logs and volatile locks/leases are excluded.
Stop the corresponding User Script before restoring its matching state files.
Keep restored Sonarr/Radarr/SAB app state and script state from compatible times.
Do not replay pending mutations or clear ambiguous journals: existing scripts
must reconcile them against current exact API/file IDs. Restoring state does not
prove actions were completed. Preserve owner/mode and review paths first.
Never restore /run heartbeats, process IDs or maintenance leases across boots.
Private disk-health configuration is included; keep this snapshot access private.
RESTORE
    vault_capture_recovery "$temp/recovery" || { exec {fd}>&-; log ERROR 'Recovery capture failed; previous export retained'; return 1; }
    local recovery_bytes=0
    while IFS= read -r -d '' file; do
        size=$(stat -c %s "$file") || { exec {fd}>&-; return 1; }
        recovery_bytes=$((recovery_bytes+size))
    done < <(find "$temp/recovery" -type f -print0)
    if (( total+recovery_bytes>OPERATIONS_STATE_MAX_BYTES && optional_media_bytes>0 )); then
        rm -f -- "$temp/media_integrity_audit/state.json.gz" "$temp/media_integrity_audit/notified.json" "$temp/media_integrity_audit/pending-notification.json"
        rmdir -- "$temp/media_integrity_audit" 2>/dev/null || true
        total=$((total-optional_media_bytes))
        log WARNING 'Optional media integrity queue omitted to preserve recovery-bundle export capacity'
    fi
    (( total+recovery_bytes <= OPERATIONS_STATE_MAX_BYTES )) || { exec {fd}>&-; log ERROR 'State and recovery capture exceed export budget; previous export retained'; return 1; }
    jq -n --argjson createdAt "$(date +%s)" --argjson bytes "$total" --argjson recoveryBytes "$recovery_bytes" '{schema:2,createdAt:$createdAt,stateBytes:$bytes,recoveryBytes:$recoveryBytes,totalBytes:($bytes+$recoveryBytes),scope:"quiescent script state plus private recovery inventory; no application databases or logs"}' >"$temp/export.json" || { exec {fd}>&-; return 1; }
    previous="${OPERATIONS_STATE_ROOT}.previous"
    [[ ! -L "$previous" ]] || { exec {fd}>&-; return 1; }
    if [[ -e "$previous" ]]; then
        [[ -d "$previous" && -f "$previous/.owner" && $(cat "$previous/.owner") == vault_operations_state ]] || { exec {fd}>&-; return 1; }
    fi
    # Recover only our known previous rename after interruption. Never delete
    # the sole usable export merely to make room for a replacement.
    if [[ ! -e "$OPERATIONS_STATE_ROOT" && -d "$previous" ]]; then mv "$previous" "$OPERATIONS_STATE_ROOT" || { exec {fd}>&-; return 1; }; fi
    if [[ -e "$previous" ]]; then rm -rf -- "$previous" || { exec {fd}>&-; return 1; }; fi
    if [[ -d "$OPERATIONS_STATE_ROOT" ]]; then mv "$OPERATIONS_STATE_ROOT" "$previous" || { exec {fd}>&-; return 1; }; fi
    if ! mv "$temp" "$OPERATIONS_STATE_ROOT"; then
        [[ ! -d "$previous" ]] || mv "$previous" "$OPERATIONS_STATE_ROOT"
        exec {fd}>&-; return 1
    fi
    rm -rf -- "$previous"
    OPERATIONS_EXPORT_TEMP=""
    exec {fd}>&-
    log INFO "Exported $total state bytes and $recovery_bytes recovery bytes; bulk logs excluded"
}

vault_inventory() {
    (cd "$1" && find . \( -name '*.partial' -o -name .rsync-partial -o -name '*.tmp' -o -name '*.sock' \) -prune -o -printf '%y:%s:%T@:%l:%p\0' | sort -z | sha256sum)
}
vault_space_preflight() {
    local job label source required=0 estimated output available
    backup_phase capacity
    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r label source <<<"$job"
        output="$TMP_DIR/$label.estimate"
        rsync "${RSYNC_ARGS[@]}" --dry-run "$source/" "$REMOTE:$REMOTE_PARTIAL/$label/" >"$output" 2>&1 || { log ERROR "Capacity estimate failed for $label"; return 1; }
        estimated=$(awk -F': ' '/^Total transferred file size:/ {gsub(/[^0-9]/,"",$2); print $2}' "$output")
        [[ "$estimated" =~ ^[0-9]+$ ]] || return 1
        required=$((required+estimated))
    done
    available=$(ssh_exec "df -P -B1 -- $(shell_quote "$REMOTE_VERSION_ROOT")" | awk 'NR==2 {print $4}') || return 1
    [[ "$available" =~ ^[0-9]+$ ]] || return 1
    log INFO "ISS capacity: estimated additional transfer=$required bytes; available=$available; reserve=$VAULT_RESERVE_BYTES"
    (( available >= required+VAULT_RESERVE_BYTES )) || { log ERROR 'Insufficient ISS capacity; completed generations were retained'; return 1; }
}

build_manifest() {
    local label="$1" source="$2" manifest="$3" row size path files=0 bytes=0 before after
    backup_phase "manifest-$label"
    backup_source_ready "$source" || return 1
    before=$(vault_inventory "$source") || return 1
    (cd "$source" && find . \( -name '*.partial' -o -name .rsync-partial -o -name '*.tmp' -o -name '*.sock' \) -prune -o -type f -printf '%s\t%p\0') >"$manifest.inventory" || return 1
    : >"$manifest.files"
    while IFS= read -r -d '' row; do
        size=${row%%$'\t'*}; path=${row#*$'\t'}
        [[ "$size" =~ ^[0-9]+$ ]] || return 1
        files=$((files+1)); bytes=$((bytes+size))
        printf '%s\0' "$path" >>"$manifest.files"
    done <"$manifest.inventory"
    (( files > 0 )) || { log ERROR "Refusing an empty source for $label"; return 1; }
    if [[ "$label" == appdata ]]; then
        vault_appdata_manifest "$source" "$manifest" || return 1
    else
        (cd "$source" && sort -z "$manifest.files" | xargs -0 -r sha256sum) >"$manifest" || return 1
    fi
    after=$(vault_inventory "$source") || return 1
    [[ "$before" == "$after" ]] || { log WARN "Source changed while hashing $label; run will be retried"; return 1; }
    MANIFEST_FILES[$label]=$files; MANIFEST_BYTES[$label]=$bytes; SOURCE_FINGERPRINT[$label]=$after
    log INFO "Manifest $label: $files files, $bytes bytes"
}

remote_prepare() {
    local signature job label source
    signature=$(printf '%s\n' "$REMOTE" "$REMOTE_VERSION_ROOT" "${BACKUP_JOBS[@]}" | sha256sum); signature=${signature%% *}
    REMOTE_FINAL="$REMOTE_VERSION_ROOT/$GENERATION_NAME"
    REMOTE_PARTIAL="$REMOTE_VERSION_ROOT/.hubble-resume.partial"
    # All mutations are under the shared ISS lease. Unknown staging is not deleted.
    backup_ssh bash -s -- "$REMOTE_VERSION_ROOT" "$signature" "$GENERATION_NAME" <<'PREPARE'
set -euo pipefail
root=$1 signature=$2 generation=$3
[[ $(realpath -e -- "$root") == "$root" && ! -L "$root" ]]
partial="$root/.hubble-resume.partial"
if [[ -e "$partial" ]]; then
    [[ -d "$partial" && ! -L "$partial" && -f "$partial/.owner" && $(cat "$partial/.owner") == vault_backup ]] || exit 1
    if [[ ! -f "$partial/.config.sha256" || $(cat "$partial/.config.sha256") != "$signature" ]]; then
        mv -T -- "$partial" "$root/.$generation.incompatible.partial"
    fi
fi
mkdir -p -- "$partial/manifests"
printf '%s\n' vault_backup >"$partial/.owner"
printf '%s\n' "$signature" >"$partial/.config.sha256"
[[ ! -L "$partial/manifests" && $(realpath -e -- "$partial/manifests") == "$partial/manifests" ]]
PREPARE
    local rc=$?
    (( rc == 0 )) || return "$rc"
    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r label source <<<"$job"
        ssh_exec "test ! -L $(shell_quote "$REMOTE_PARTIAL/$label") && mkdir -p -- $(shell_quote "$REMOTE_PARTIAL/$label") && test \"\$(realpath -e -- $(shell_quote "$REMOTE_PARTIAL/$label"))\" = $(shell_quote "$REMOTE_PARTIAL/$label")" || return 1
    done
}

transfer_job() {
    local label="$1" source="$2" manifest="$3" attempt rc output before after elapsed started force_checksum=false
    local destination="$REMOTE_PARTIAL/$label" manifest_remote="$REMOTE_PARTIAL/manifests/$label.sha256"
    local -a args=()
    output="$TMP_DIR/$label.rsync"
    for ((attempt=1; attempt<=VAULT_MAX_ATTEMPTS; attempt++)); do
        backup_lease_alive && backup_source_ready "$source" || return 1
        # Rebuild after an interruption/source change, never verify against a stale manifest.
        build_manifest "$label" "$source" "$manifest" || { (( attempt < VAULT_MAX_ATTEMPTS )) && { sleep 5; continue; }; return 1; }
        before=${SOURCE_FINGERPRINT[$label]}
        if [[ "$DRY_RUN" == true ]]; then log INFO "[DRY RUN] Would transfer ${MANIFEST_FILES[$label]} files from $source"; return 0; fi
        backup_phase "transfer-$label"
        started=$(date +%s); args=("${RSYNC_ARGS[@]}")
        [[ "$force_checksum" != true ]] || args+=(--checksum)
        "${PRIORITY_PREFIX[@]}" rsync "${args[@]}" "$source/" "$REMOTE:$destination/" 2>&1 | tail --bytes="$MAX_RAW_LOG_BYTES" >"$output"
        rc=${PIPESTATUS[0]}; elapsed=$(( $(date +%s)-started ))
        tail -n 30 -- "$output" >>"$LOG_FILE"
        log INFO "$label attempt=$attempt duration=${elapsed}s rsync_exit=$rc"
        if (( rc == 0 )); then
            after=$(vault_inventory "$source") || return 1
            if [[ "$before" != "$after" ]]; then
                log WARN "Source changed during $label transfer; rebuilding manifest and retrying"
            else
                ssh_exec "find $(shell_quote "$destination") -type d -name .rsync-partial -prune -exec rm -rf -- {} +" || return 1
                rsync -a --checksum --protect-args "--timeout=$RSYNC_IO_TIMEOUT" "$manifest" "$REMOTE:$manifest_remote" || return 1
                backup_phase "verify-$label"
                if ssh_exec "cd $(shell_quote "$destination") && sha256sum -c -- $(shell_quote "$manifest_remote") >/dev/null"; then
                    FILES_VERIFIED=$((FILES_VERIFIED+MANIFEST_FILES[$label]))
                    BYTES_TRANSFERRED=$((BYTES_TRANSFERRED+MANIFEST_BYTES[$label]))
                    return 0
                fi
                force_checksum=true
                log WARN "Checksum mismatch for $label; retry will compare source and staged file contents"
            fi
        else
            case "$rc" in 10|12|23|24|30|35) ;; 255) grep -qiE 'permission denied|host key verification failed|identification has changed' "$output" && return 1;; *) return 1;; esac
        fi
        (( attempt < VAULT_MAX_ATTEMPTS )) && sleep "$((15*attempt))"
    done
    log ERROR "Transfer/source-stability/verification attempts exhausted for $label"
    return 1
}

promote_generation() {
    local job label source map="$TMP_DIR/restore-sources.tsv"
    printf 'label\tsource_path\tgeneration_path\n' >"$map"
    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r label source <<<"$job"
        printf '%s\t%s\t%s/\n' "$label" "$source" "$label" >>"$map"
    done
    rsync -a --protect-args "--timeout=$RSYNC_IO_TIMEOUT" "$map" "$REMOTE:$REMOTE_PARTIAL/manifests/restore-sources.tsv" || return 1
    backup_ssh bash -s -- "$REMOTE_PARTIAL" "$REMOTE_FINAL" "$SRC_NAS" "$DEST_NAS" "$SCRIPT_VERSION" <<'PROMOTE'
set -euo pipefail
partial=$1 final=$2
[[ -d "$partial" && ! -L "$partial" && ! -e "$final" && ! -L "$final" ]]
printf '%s\n' "source=$3" "destination=$4" "completed=$(date -Iseconds)" "script_version=$5" >"$partial/completed.txt"
mv -T -- "$partial" "$final"
PROMOTE
}

prune_remote_generations() {
    backup_phase retention
    backup_lease_alive || return 1
    backup_ssh bash -s -- "$REMOTE_VERSION_ROOT" "$REMOTE_KEEP" "$PARTIAL_RETENTION_DAYS" <<'RETENTION'
set -euo pipefail
root=$1 keep=$2 days=$3
[[ $(realpath -e -- "$root") == "$root" && ! -L "$root" ]]
list=$(mktemp /tmp/vault-retention.XXXXXX)
trap 'rm -f -- "$list" "$list.partial"' EXIT
find "$root" -mindepth 1 -maxdepth 1 -type d -name 'hubble-*' -printf '%f\n' | sort -r >"$list"
mapfile -t entries <"$list"
count=0
for entry in "${entries[@]}"; do
    [[ "$entry" =~ ^hubble-[0-9]{8}_[0-9]{6}$ ]] || continue
    [[ -f "$root/$entry/completed.txt" && ! -L "$root/$entry" ]] || continue
    count=$((count+1))
    (( count <= keep )) || rm -rf -- "$root/$entry"
done
# Only script-owned abandoned staging is eligible. Current resumable staging
# and unmarked historical partials are deliberately retained.
find "$root" -mindepth 1 -maxdepth 1 -type d -name '.hubble-*.partial' -mtime "+$days" -print0 >"$list.partial"
while IFS= read -r -d '' path; do
    [[ "$path" != "$root/.hubble-resume.partial" && ! -L "$path" ]] || continue
    [[ -f "$path/.owner" && $(cat "$path/.owner") == vault_backup ]] || continue
    printf 'Removing expired owned partial: %s\n' "$path"
    rm -rf -- "$path"
done <"$list.partial"
find "$root" -mindepth 1 -maxdepth 1 -type d -name '*.partial' -exec du -sh -- {} \;
RETENTION
}

remote_shutdown_blockers() {
    BACKUP_SSH_COMMAND_TIMEOUT=30 backup_ssh \
        bash -s -- \
        "$DEFER_REMOTE_SHUTDOWN_WHILE_MOVER" \
        "$DEFER_REMOTE_SHUTDOWN_DURING_PARITY_CHECK" \
        "$DEFER_REMOTE_SHUTDOWN_DURING_CRITICAL_ARRAY_OPERATION" \
        <<'REMOTE_ACTIVITY_PROBE'
defer_mover="$1"
defer_parity_check="$2"
defer_critical_operation="$3"

case "${defer_mover}:${defer_parity_check}:${defer_critical_operation}" in
    true:true:true|true:true:false|true:false:true|true:false:false|\
    false:true:true|false:true:false|false:false:true|false:false:false)
        ;;
    *)
        exit 3
        ;;
esac

if [ "$defer_mover" = true ]; then
    command -v pgrep >/dev/null 2>&1 || exit 3
    if pgrep -f '(^|/)(mover|mover\.old)( |$)|mover\.php' >/dev/null 2>&1; then
        printf '%s\n' 'Mover is active'
    fi
fi

if [ "$defer_parity_check" != true ] &&
   [ "$defer_critical_operation" != true ]; then
    exit 0
fi

if [ -x /usr/local/sbin/mdcmd ]; then
    mdcmd_bin=/usr/local/sbin/mdcmd
elif command -v mdcmd >/dev/null 2>&1; then
    mdcmd_bin=mdcmd
else
    exit 3
fi

md_status="$($mdcmd_bin status 2>/dev/null)" || exit 3
printf '%s\n' "$md_status" | awk -F= '
    function clean(value) {
        gsub(/^[[:space:]"\r]+|[[:space:]"\r]+$/, "", value)
        return value
    }
    tolower($1) == "mdresyncaction" { action=clean($2) }
    tolower($1) == "mdresync"       { resync=clean($2) }
    tolower($1) == "mdresyncpos"    { pos=clean($2) }
    END {
        if (!(resync ~ /^[0-9]+$/) || !(pos ~ /^[0-9]+$/)) exit 3

        action_lc=tolower(action)
        active=(resync + 0 > 0 || pos + 0 > 0)
        if (!active) exit

        state=(resync + 0 > 0 ? "active" : "paused")
        if (action_lc ~ /^check([[:space:]]|$)/) {
            if (defer_parity_check == "true")
                printf "Parity check is %s (%s)\n", state, action
        } else if (defer_critical_operation == "true") {
            if (action != "")
                printf "Critical array operation is %s (%s)\n", state, action
            else
                printf "Critical array operation is %s\n", state
        }
    }
' \
    defer_parity_check="$defer_parity_check" \
    defer_critical_operation="$defer_critical_operation"
REMOTE_ACTIVITY_PROBE
}

shutdown_remote() {
    local blockers=""
    local blocker_status=0

    [[ "$SHUTDOWN_REMOTE_ON_SUCCESS" == true ]] || return 0
    backup_lease_alive || { REMOTE_SHUTDOWN_SKIPPED_REASON="Shared ISS lease is not held"; return 0; }

    if ! backup_shutdown_handoff; then log INFO "$REMOTE_SHUTDOWN_SKIPPED_REASON"; return 0; fi
    blockers="$(remote_shutdown_blockers 2>/dev/null)"
    blocker_status=$?

    if (( blocker_status != 0 )); then
        REMOTE_SHUTDOWN_SKIPPED_REASON="Mover/parity status could not be verified"
        log WARN "Remote shutdown skipped: ${REMOTE_SHUTDOWN_SKIPPED_REASON}. $DEST_NAS will remain powered on."
        return 0
    fi

    if [[ -n "$blockers" ]]; then
        REMOTE_SHUTDOWN_SKIPPED_REASON="${blockers//$'\n'/; }"
        log WARN "Remote shutdown skipped: ${REMOTE_SHUTDOWN_SKIPPED_REASON}. $DEST_NAS will remain powered on."
        return 0
    fi

    log INFO "Requesting clean shutdown of $DEST_NAS"
    if backup_request_shutdown; then SHUTDOWN_RESULT=requested; return 0; fi

    REMOTE_SHUTDOWN_FAILED=1
    SHUTDOWN_RESULT=failed_or_unconfirmed
    log WARN "Remote shutdown request failed"
    return 1
}

###############################################################################
# MAIN
###############################################################################

vault_usage() {
    cat <<'HELP'
Usage: bash script [--help|--version|--force]
Installed Unraid entry: backup_vault_remote; GitHub source: backup_vault_remote.sh.

Schedule: 10 * * * * (hourly at minute 10, Singapore time).
This is a scheduled completion-request check, not a continuously running daemon.
No request/already delivered: local no-op; no ISS SSH/WOL, new backup log or email.

A successful backup_cache_appdata publishes a request for its verified local generation.
A new valid request causes all configured jobs (appdata, flash, User Scripts,
GitHub, photos and operational state) to be copied into a new ISS generation.
Verify SHA-256, promote atomically, acknowledge delivery, retain three successful
remote generations, run the weekly drill when due, then request guarded shutdown.

Undelivered requests retry on later checks. Identical request/failure notifications
are limited to one per 24 hours; new reasons notify immediately. Verified success
reports recovery, and failed notification sends remain eligible for retry.
Requests older than 72 hours, changed
sources or invalid manifests fail safely. Retention/drill/shutdown warnings after
delivery acknowledgement do not automatically trigger another full copy.
Photos/GitHub/flash changes alone do not trigger delivery in completion-driven mode.

--force repeats the current request despite delivery acknowledgement, while keeping
source/freshness/integrity checks. It may wake ISS and transfer every backup job.
Help/version perform no backup work. Preserve the installed DRY_RUN setting.
HELP
}
main() {
    local job label source manifest notification_message
    case "${1:-}" in
        --help|-h) vault_usage; return 0;;
        --version) printf 'backup_vault_remote.sh %s (Unraid entry: backup_vault_remote)\n' "$SCRIPT_VERSION"; return 0;;
        ""|--force) ;;
        *) vault_usage >&2; return 2;;
    esac
    exec 9>"$LOCK_FILE" || return 1
    flock -n 9 || { printf 'Another vault backup is active\n' >&2; return 1; }
    local pending_rc=0
    if [[ "$COMPLETION_DRIVEN" == true ]]; then
        vault_pending_request "${1:-}" || pending_rc=$?
        if (( pending_rc == 10 )); then printf 'No new completed appdata generation; ISS remains undisturbed\n'; return 0; fi
        if (( pending_rc != 0 )); then
            notify_unraid warning "ISS handoff unavailable" "Reason: $VAULT_NOTIFICATION_REASON. Pending appdata request is malformed, stale, or its source changed. No ISS wake or transfer was attempted. A fresh successful appdata backup is required."
            return 1
        fi
    fi
    trap backup_finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 141' PIPE
    backup_transport_init || return 1

    if ! mountpoint -q /mnt/vault || ! mountpoint -q /boot; then
        printf 'Required local mounts are unavailable: /mnt/vault and/or /boot\n' >&2
        return 1
    fi
    mkdir -p -- "$LOG_DIR" || return 1
    : >"$LOG_FILE" || return 1
    prune_local_logs


    log INFO "Starting $SRC_NAS -> $DEST_NAS versioned backup (dry_run=$DRY_RUN)"
    validate_configuration || return 1
    build_priority_prefix
    TMP_DIR="$(mktemp -d /tmp/backup_vault_remote.XXXXXX)" || return 1
    vault_producer_locks || return 1
    for job in "${BACKUP_JOBS[@]}"; do
        if [[ "$job" == "operations_state|$OPERATIONS_STATE_ROOT" ]]; then
            # Dry run also captures local state consistently; remote remains read-only.
            vault_export_operations_state || return 1
        fi
    done
    vault_select_sources || return 1
    if [[ -n "$ISS_REQUEST_ID" ]]; then
        local matched=false
        for job in "${BACKUP_JOBS[@]}"; do
            [[ "$job" != "appdata|$ISS_REQUEST_GENERATION" ]] || matched=true
        done
        [[ "$matched" == true ]] || { log ERROR "Producer advanced; pending request will be retried on the next check"; return 1; }
    fi
    wait_for_remote || return 1
    backup_phase capabilities
    backup_capabilities || { log ERROR "Local/ISS capability validation failed; no backup was published. ISS is left available for retry."; return 1; }
    backup_acquire_lease || { log ERROR "ISS is already in use by another backup, or lease acquisition failed"; return 1; }
    [[ "$PRESERVE_HARD_LINKS" != true ]] || RSYNC_ARGS+=(-H)
    RSYNC_ARGS+=("--timeout=$RSYNC_IO_TIMEOUT")
    RSYNC_ARGS+=("--rsync-path=LC_ALL=C rsync")
    backup_phase prepare
    if [[ "$DRY_RUN" != true ]]; then
        remote_prepare || {
            log ERROR "Unable to create remote partial generation"
            return 1
        }
    fi

    if [[ "$DRY_RUN" != true ]]; then vault_space_preflight || return 1; fi
    for job in "${BACKUP_JOBS[@]}"; do
        IFS='|' read -r label source <<<"$job"
        manifest="${TMP_DIR}/${label}.sha256"
        transfer_job "$label" "$source" "$manifest" || {
            log ERROR "Transfer or verification failed for $label"
            return 1
        }
    done

    if [[ "$DRY_RUN" == true ]]; then
        BACKUP_RESULT=DRY_RUN; VERIFICATION_RESULT=not_performed

        RESULT_SUMMARY="Dry run completed; no remote generation was created"
        log INFO "$RESULT_SUMMARY"
        notify_unraid normal "Dry run completed" "$RESULT_SUMMARY"$'\n'"Log: $LOG_FILE"

        return 0
    fi

    backup_phase promotion
    backup_lease_alive || return 1
    promote_generation || {
        log ERROR "Remote generation promotion failed; partial data was retained"
        return 1
    }

    BACKUP_RESULT=OK; VERIFICATION_RESULT=sha256_verified
    vault_acknowledge_request || { log ERROR "Remote generation verified but local handoff acknowledgement failed; retry remains pending"; return 1; }
    if ! prune_remote_generations; then
        RETENTION_RESULT=FAILED

        RESULT_SUMMARY="Generation verified, but retention pruning failed"
        notify_unraid warning "Backup completed with warning" \
            "$RESULT_SUMMARY"$'\n'"Generation: $REMOTE_FINAL"

        return 1
    fi

    RETENTION_RESULT=OK
    if ! vault_remote_restore_drill; then
        RESTORE_DRILL_RESULT=FAILED
        [[ -n "$RESTORE_DRILL_SUMMARY" ]] || RESTORE_DRILL_SUMMARY="ISS restore drill unavailable; verified backup retained. Review remote drill prerequisites/logs."
    fi

    RESULT_SUMMARY="Verified ${GENERATION_NAME}: ${FILES_VERIFIED} files, $(human_bytes "$BYTES_TRANSFERRED")"
    log INFO "$RESULT_SUMMARY"
    backup_phase shutdown
    shutdown_remote || true
    notification_message="$RESULT_SUMMARY"$'\n'"Destination: $REMOTE_FINAL"
    if [[ -n "$REMOTE_SHUTDOWN_SKIPPED_REASON" ]]; then
        notification_message+=$'\n'"Remote shutdown: skipped (${REMOTE_SHUTDOWN_SKIPPED_REASON}); $DEST_NAS left powered on"
    elif (( REMOTE_SHUTDOWN_FAILED == 1 )); then
        notification_message+=$'\n'"Remote shutdown: request failed"
    fi
    notification_message+=$'\n'"Recovery inventory: $RECOVERY_SUMMARY"
    notification_message+=$'\n'"Restore drill: $RESTORE_DRILL_RESULT. $RESTORE_DRILL_SUMMARY"
    local importance=normal
    [[ "$RECOVERY_CAPTURE_WARNING" != true ]] || importance=warning
    case "$RESTORE_DRILL_RESULT" in FAILED|WARNING) importance=warning;; esac
    if [[ -n "$REMOTE_SHUTDOWN_SKIPPED_REASON" && "$SHUTDOWN_RESULT" != deferred ]] || (( REMOTE_SHUTDOWN_FAILED != 0 )); then importance=warning; fi
    notify_unraid "$importance" "Backup completed" "$notification_message"

}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
