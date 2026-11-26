#!/bin/bash
clearLog=true
arrayStarted=true
# System Update Coordinator v1.6.0 -- personal Hubble maintenance.
# PURPOSE: Detect Docker/plugin/Unraid OS updates; automatically install only
# explicitly approved, still-installed items during a bounded maintenance window.
# Existing producers finish; expiring requests make new conflicting work yield.
# Unrelated Docker updates share the backup gate instead of blocking Arr scans.
# Plex direct play/stream is allowed; audio/video/background transcodes defer.
# Native DockerMan/plugin installers retain their normal configuration semantics.
# No OS installation/reboot, image-channel change, forced import or DB rollback.
# SCHEDULE: */15 * * * *; registry polling has its own six-hour per-item cache.
# New installs: 13:15-15:30 and 21:15-23:00 Singapore; at most one/run, six Docker + two plugins/rolling 24h.
# Default Docker holds: stable 6h; nightly/develop/unstable 1h. Plugins 24h.
# Backup freshness follows its User Scripts cron: tolerate one missed run plus
# 12-hour completion grace. Active appdata/boot backup still blocks installs.
# Ordinary non-correcting parity checks, Mover, remote copies and read-only
# restore drills are advisory; rebuilds/correcting or unknown array work defer.
# SAB/qBittorrent downloading and queued four-hour batches do not block updates.
# Arr protects active file-changing/unknown work and imports, not queued checks.
# All observed holds and next reassessment are saved for the grouped report.
# Default allowlist seeds once, bound to exact installed repository/source URL.
# Retired items leave policy automatically after two complete inventory scans;
# stopped items stay stopped. Reinstalling a retired/changed identity needs review.
# New items default to notify-only, never inherit a broad wildcard approval.
# STATE/LOG: /mnt/vault/cloud/logs/script/system_update_coordinator; atomic JSON,
# private per-action recovery evidence, 2MiB log + two rotations, 30-day age bound.
# Reports: one grouped report at 23:15, after both maintenance windows.
# Finish-by guards reserve 20 minutes before preparation, 13 before dispatch,
# covering bounded installation/readiness plus a margin before fixed app work.
# Native schedules are read every attempt; application schedules are never edited.
# Two observed missed windows raise priority and a grouped warning, not a force update.
# Up-to-date entries and empty reports stay quiet; urgent failures bypass batching.
# Undelivered pages stay in a durable outbox.
# Recovery: journal before native recreation. Uncertain installs are inspected,
# never blindly repeated. Previous image/config archived before update; latest
# two finished recovery sets retained, plus unresolved sets (affected dependency groups remain held).
# An image archive does not reverse DB migrations. Compatible appdata restoration
# is a critical/manual recovery step; existing backup retention is independent.
# Native mutable tags can move during the installer pull; read-back detects any
# unexpected digest and holds further updates rather than claiming verification.
# Unknown OS majors/interfaces stop installation; read-only status remains usable.
# CLI: --help documents policy management without editing this standalone script.
# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="system_update_coordinator"
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
umask 077
readonly SCRIPT_VERSION="1.6.1"
# Keep configured per-item holds when approving the same installed identity.
# Daily rolling tags need a shorter hold to avoid perpetually chasing rebuilds.
readonly APPROVAL_JQ='def approval($old;$identity;$allow;$kind;$epoch):
 (if ($old.identity // "")==$identity then $old else {} end) |
 .+{identity:$identity,allow:$allow,approvedAt:$epoch} |
 if $kind=="docker" and .candidateHoldHours==null and ($identity|test(":(nightly|develop|unstable)$")) then .candidateHoldHours=1 elif $kind=="docker" and .candidateHoldHours==null then .candidateHoldHours=6 else . end;'

STATE_DIR="${STATE_DIR:-/mnt/vault/cloud/logs/script/system_update_coordinator}"
STATUS_DIR="${STATUS_DIR:-/mnt/vault/cloud/logs/script/user_scripts_status}"
VAULT_MOUNT="${VAULT_MOUNT:-/mnt/vault}"
STATE_EXPORT_LOCK="${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}"
LOCK_FILE="${LOCK_FILE:-/run/system_update_coordinator.lock}"
ARR_BACKUP_GATE="${ARR_BACKUP_GATE:-/run/arr-appdata-coordination.lock}"
WATCHDOG_SCRIPT="${WATCHDOG_SCRIPT:-/boot/config/plugins/user.scripts/scripts/docker_service_watchdog/script}"
NATIVE_DOCKER_UPDATE="${NATIVE_DOCKER_UPDATE:-/usr/local/emhttp/plugins/dynamix.docker.manager/scripts/update_container}"
NATIVE_PLUGIN="${NATIVE_PLUGIN:-/usr/local/emhttp/plugins/dynamix.plugin.manager/scripts/plugin}"
NATIVE_OS_CHECK="${NATIVE_OS_CHECK:-/usr/local/emhttp/plugins/dynamix.plugin.manager/scripts/unraidcheck}"
NOTIFY_BIN="${NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify}"
ROLLBACK_ROOT="${ROLLBACK_ROOT:-/mnt/vault/backup/system_updates}"
POLICY_FILE="$STATE_DIR/policy.json"
STATE_FILE="$STATE_DIR/state.json"
LOG_FILE="$STATE_DIR/system-update-coordinator.log"
MAX_RUNTIME_SECONDS=840
MAX_CHECKS_PER_RUN=4
CHECK_INTERVAL_SECONDS=21600
BACKUP_MAX_AGE_SECONDS=$((80*3600)) # Fallback only when no User Scripts schedule exists.
BACKUP_SCHEDULE_FILE="${BACKUP_SCHEDULE_FILE:-/boot/config/plugins/user.scripts/schedule.json}"
BACKUP_FINISH_GRACE_SECONDS=43200
BACKUP_REASON=''
DOCKER_MAINTENANCE_DIR="${DOCKER_MAINTENANCE_DIR:-/run/docker-service-maintenance}"
APP_UPDATE_REQUEST_DIR="${APP_UPDATE_REQUEST_DIR:-/run/docker-update-requests}"
COORDINATION_WAIT_SECONDS="${COORDINATION_WAIT_SECONDS:-90}"
CURRENT_REQUEST='' REQUEST_KEEP=false GUARD_GLOBAL=false
PRODUCER_FDS=()
TMP_DIR='' START_EPOCH=0 RUN_ID='' RESULT=OK SUMMARY='' RECOVERY_REASON='' INSTALL_ACTIVE=false UPDATE_FD='' EXPORT_FD='' LEASE_FILE='' OWN_GATE_FD='' MAINT_FD='' EVENTS=0
log(){ local level="$1";shift;local line;line=$(OPS_RUN_ID="${RUN_ID:-$$}" usr_ops_log_line "$level" "${PHASE:-MAIN}" "$*");printf '%s\n' "$line";[[ ! -d "$STATE_DIR" ]] || usr_ops_append_log "$LOG_FILE" "$line"; }
valid_name(){ [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; }
same_repository(){
 local a="$1" b="$2"
 [[ -n "$a" && -n "$b" && "$a" != null && "$b" != null ]] || return 1
 [[ "${a##*/}" == *:* ]] || a+=:latest
 [[ "${b##*/}" == *:* ]] || b+=:latest
 [[ "$a" == "$b" ]]
}
bounded(){ timeout --signal=TERM --kill-after=5 "$@"; }
docker_cmd(){ bounded 30 docker "$@"; }
adapter(){ bounded 100 php "$TMP_DIR/native.php" "$@"; }
export_lock(){ exec {EXPORT_FD}>"$STATE_EXPORT_LOCK" && flock -s -w 20 "$EXPORT_FD"; }
export_unlock(){ [[ -z "${EXPORT_FD:-}" ]] || exec {EXPORT_FD}>&-; }
publish(){ local from="$1" to="$2" rc=0;export_lock || return 1;sync -f "$from" && mv "$from" "$to" && sync -f "${to%/*}" || rc=$?;export_unlock;return "$rc"; }
state_valid(){ jq -e '.schema==1 and (.items|type)=="object" and (.jobs|type)=="object" and (.outbox|type)=="array" and (.normalDeliveryIds==null or ((.normalDeliveryIds|type)=="array" and all(.normalDeliveryIds[];type=="string")))' "$1" >/dev/null 2>&1; }
mutate(){ jq "$@" "$STATE_FILE" >"$TMP_DIR/state.next" && state_valid "$TMP_DIR/state.next" && publish "$TMP_DIR/state.next" "$STATE_FILE"; }
policy_valid(){ jq -e '
 .schema==1 and (.enabled|type)=="boolean" and (.docker|type)=="object" and (.plugins|type)=="object" and
 all(.docker[],.plugins[];(.allow|type)=="boolean" and (.identity|type)=="string" and (.candidateHoldHours==null or ((.candidateHoldHours|type)=="number" and .candidateHoldHours==(.candidateHoldHours|floor) and .candidateHoldHours>=1 and .candidateHoldHours<=168))) and
 (.windows==null or ((.windows|type)=="array" and (.windows|length)>=1 and (.windows|length)<=4 and
   all(.windows[];(.start|test("^([01][0-9]|2[0-3]):[0-5][0-9]$")) and (.end|test("^([01][0-9]|2[0-3]):[0-5][0-9]$")) and .start<.end) and
   (.windows==(.windows|sort_by(.start))) and ([range(1;(.windows|length)) as $i|.windows[$i-1].end<=.windows[$i].start]|all) and .window==.windows[0])) and
 (.window.start|type)=="string" and (.window.end|type)=="string" and
 (.window.start|test("^([01][0-9]|2[0-3]):[0-5][0-9]$")) and (.window.end|test("^([01][0-9]|2[0-3]):[0-5][0-9]$")) and .window.start<.window.end and
 ((.limits.dailyTotal // 8)|type)=="number" and ((.limits.dailyDocker // .limits.dailyTotal // 6)|type)=="number" and ((.limits.dailyPlugins // 2)|type)=="number" and ((.limits.candidateHoldHours // 24)|type)=="number" and
 ((.limits.dailyTotal // 8)|floor)==(.limits.dailyTotal // 8) and (.limits.dailyTotal // 8)>=1 and (.limits.dailyTotal // 8)<=16 and
 ((.limits.dailyDocker // .limits.dailyTotal // 6)|floor)==(.limits.dailyDocker // .limits.dailyTotal // 6) and (.limits.dailyDocker // .limits.dailyTotal // 6)>=1 and (.limits.dailyDocker // .limits.dailyTotal // 6)<=12 and
 (.limits.dailyDocker==null or .limits.dailyTotal==(.limits.dailyDocker+(.limits.dailyPlugins // 2))) and
 ((.limits.dailyPlugins // 2)|floor)==(.limits.dailyPlugins // 2) and (.limits.dailyPlugins // 2)>=0 and (.limits.dailyPlugins // 2)<=4 and (.limits.dailyPlugins // 2)<=(.limits.dailyTotal // 8) and
 ((.limits.candidateHoldHours // 24)|floor)==(.limits.candidateHoldHours // 24) and (.limits.candidateHoldHours // 24)>=1 and (.limits.candidateHoldHours // 24)<=168 and
 ((.reportTime // "15:45")|type)=="string" and ((.reportTime // "15:45")|test("^([01][0-9]|2[0-3]):[0-5][0-9]$")) and
 ((.limits.imageMaxBytes // 4294967296)|type)=="number" and ((.limits.imageMaxBytes // 4294967296)|floor)==(.limits.imageMaxBytes // 4294967296) and
 (.limits.imageMaxBytes // 4294967296)>=1073741824 and (.limits.imageMaxBytes // 4294967296)<=8589934592
 ' "$1" >/dev/null 2>&1; }
policy_update(){ jq "$@" "$POLICY_FILE" >"$TMP_DIR/policy.next" && policy_valid "$TMP_DIR/policy.next" && publish "$TMP_DIR/policy.next" "$POLICY_FILE"; }
event(){
 local importance="$1" subject="$2" detail="$3" key="$4" id
 id=$(printf '%s' "$key"|sha256sum|cut -d' ' -f1)
 jq -n --arg detail "$detail" --arg subject "$subject" --arg id "$id" --arg importance "$importance" --argjson now "$(date +%s)" '
   def pieces: if utf8bytelength>10000 then [range(0;length;2000) as $i | .[$i:$i+2000]] else [.] end;
   ($detail|split("\n")|map(pieces)|add) as $lines |
   (reduce $lines[] as $line ([""]; if ((.[-1]+"\n"+$line)|utf8bytelength)>11000 then .+[$line] else .[-1]+=(if .[-1]=="" then "" else "\n" end)+$line end)) as $pages |
   [range(0;$pages|length) as $i|{id:($id+(if ($pages|length)>1 then ":"+($i|tostring) else "" end)),importance:$importance,subject:($subject+(if ($pages|length)>1 then " (part "+(($i+1)|tostring)+"/"+($pages|length|tostring)+")" else "" end)),detail:$pages[$i],at:$now}]' >"$TMP_DIR/events.next" || return 1
 mutate --slurpfile events "$TMP_DIR/events.next" --argjson now "$(date +%s)" '
   reduce $events[0][] as $e (.;if any(.outbox[];.id==$e.id) or (.delivered[$e.id] // 0)>$now-86400 then . else .outbox+=[$e] end)' || return 1
 EVENTS=$((EVENTS+1))
}

calendar_eval() {
    # One timezone-aware calendar serves window selection, finish-by guards and
    # reporting. External app configuration is read only by the watchdog CLI.
    local mode="$1" now="$2" reserve="${3:-0}" name="${4:-}" kind="${5:-docker}" manifest="${6:-}" catalog="" rc=0
    [[ -n "$manifest" ]] || manifest='{}'
    {
      catalog=$(mktemp "${TMP_DIR:-/tmp}/script-catalog.XXXXXX") || return 1
      if ! usr_scripts_catalog "$BACKUP_SCHEDULE_FILE" "${USER_SCRIPTS_PHYSICAL_ROOT:-$(dirname "$BACKUP_SCHEDULE_FILE")/scripts}" >"$catalog";then cat "$catalog";rm -f "$catalog";return 1;fi
    }
    php -r '
      [$mode,$now,$reserve,$name,$kind,$policyPath,$scriptPath,$catalogPath]=array_slice($argv,1);$now=(int)$now;$reserve=(int)$reserve;
      $catalog=json_decode(file_get_contents($catalogPath),true,512,JSON_THROW_ON_ERROR);if(($catalog["valid"]??false)!==true)throw new Exception("Script catalogue unavailable");$scripts=$catalog["jobs"];
      $p=json_decode(file_get_contents($policyPath),true,512,JSON_THROW_ON_ERROR);$windows=$p["windows"]??[$p["window"]];$zone=new DateTimeZone("Asia/Singapore");
      $today=(new DateTimeImmutable("@".$now))->setTimezone($zone)->setTime(0,0);$spans=[];
      for($d=0;$d<3;$d++)foreach($windows as $w){$day=$today->modify("+$d day");$a=new DateTimeImmutable($day->format("Y-m-d")." ".$w["start"],$zone);$b=new DateTimeImmutable($day->format("Y-m-d")." ".$w["end"],$zone);$spans[]=["start"=>$a->getTimestamp(),"end"=>$b->getTimestamp(),"id"=>$day->format("Y-m-d").":".$w["start"]];}
      usort($spans,fn($a,$b)=>$a["start"]<=>$b["start"]);$current=null;$next=null;
      foreach($spans as $s)if($s["start"]<=$now&&$now<$s["end"])$current=$s;
      // Next reassessment follows the current native coordinator cron, including
      // a renamed folder retaining its logical OPS_SCRIPT_ID.
      $polls=array_values(array_filter($scripts,fn($j)=>($j["role"]==="system_update_coordinator"||$j["name"]==="system_update_coordinator")&&$j["present"]&&$j["enabled"]&&$j["cron"]));
      foreach($polls as $poll){$f=preg_split("/\\s+/",$poll["cron"]);$mm=values($f[0],0,59);$hh=values($f[1],0,23);$dom=values($f[2],1,31);$months=values($f[3],1,12);$dow=values($f[4],0,7);if(in_array(7,$dow,true))$dow[]=0;
        for($d=0;$d<400;$d++){$day=$today->modify("+$d day");if(!in_array((int)$day->format("n"),$months,true))continue;$dm=in_array((int)$day->format("j"),$dom,true);$dw=in_array((int)$day->format("w"),$dow,true);$match=!str_starts_with($f[2],"*")&&!str_starts_with($f[4],"*")?($dm||$dw):($dm&&$dw);if(!$match)continue;$found=false;
          foreach($windows as $w)foreach($hh as $h)foreach($mm as $m){$clock=sprintf("%02d:%02d",$h,$m);$at=$day->setTime($h,$m)->getTimestamp();if($at>=$now&&$clock>=$w["start"]&&$clock<$w["end"]){if($next===null||$at<$next)$next=$at;$found=true;}}if($found)break;
        }
      }
      if(!$polls)$current=null;
      if($mode==="next"){echo json_encode(["at"=>$next]);exit;}
      if($mode==="window"){echo json_encode(["ready"=>$current!==null,"current"=>$current,"nextAttemptAt"=>$next]);exit;}
      $manifest=json_decode(stream_get_contents(STDIN),true,512,JSON_THROW_ON_ERROR);
      if(($manifest["verified"]??false)!==true){echo json_encode(["ready"=>false,"detail"=>$manifest["detail"]??"Native schedule evidence unavailable","retryAt"=>$next]);exit;}
      function values($expr,$lo,$hi){
        $out=[];foreach(explode(",",strtolower($expr)) as $part){
          if(!preg_match("~^(\\*|[0-9]+(?:-[0-9]+)?)(?:/([0-9]+))?$~D",$part,$m))throw new Exception("Unsupported cron syntax");
          $step=isset($m[2])?(int)$m[2]:1;if($step<1)throw new Exception("Invalid cron step");
          if($m[1]==="*"){ $a=$lo;$b=$hi; }elseif(str_contains($m[1],"-")){[$a,$b]=array_map("intval",explode("-",$m[1]));}else{$a=(int)$m[1];$b=isset($m[2])?$hi:$a;}
          if($a<$lo||$b>$hi||$a>$b)throw new Exception("Invalid cron range");for($v=$a;$v<=$b;$v+=$step)$out[$v]=true;
        }return array_keys($out);
      }
      function occurrence($event,$now){
        $z=new DateTimeZone($event["timezone"]??"Asia/Singapore");$f=preg_split("/\\s+/",trim($event["cron"]));if(count($f)!==5)throw new Exception("Invalid schedule");
        $mins=values($f[0],0,59);$hours=values($f[1],0,23);$dom=values($f[2],1,31);$months=values($f[3],1,12);$dow=values($f[4],0,7);if(in_array(7,$dow,true))$dow[]=0;
        $duration=(int)($event["durationSeconds"]??0);if($duration<0||$duration>86400)throw new Exception("Invalid interval");
        $day=(new DateTimeImmutable("@".$now))->setTimezone($z)->setTime(0,0)->modify("-1 day");$future=null;$activeUntil=0;
        for($d=0;$d<10;$d++,$day=$day->modify("+1 day")){
          if(!in_array((int)$day->format("n"),$months,true))continue;
          $dm=in_array((int)$day->format("j"),$dom,true);$dw=in_array((int)$day->format("w"),$dow,true);
          $match=!str_starts_with($f[2],"*")&&!str_starts_with($f[4],"*")?($dm||$dw):($dm&&$dw);if(!$match)continue;
          foreach($hours as $h)foreach($mins as $m){$at=$day->setTime($h,$m)->getTimestamp();if($at<=$now&&$at+$duration>$now)$activeUntil=max($activeUntil,$at+$duration);if($at>=$now&&($future===null||$at<$future))$future=$at;}
        }return [$future,$activeUntil];
      }
      $events=$manifest["events"]??[];
      $related=["backup_cache_appdata","backup_boot_disk"];
      if($kind==="plugin")$related=array_merge($related,["media_cleanup","media_torrent_management","media_plex_dbrepair","media_metadata_audit","media_integrity_audit"]);
      if($kind==="docker"){
        if(preg_match("/sonarr|radarr|sabnzbd|qbittorrent/",$name))$related=array_merge($related,["media_cleanup","media_torrent_management"]);
        if(preg_match("/plex|kometa|metafusion|imagemaid/",$name))$related=array_merge($related,["media_plex_dbrepair","media_metadata_audit"]);
        if($name==="bazarr")$related[]="media_integrity_audit";
      }
      foreach($scripts as $s){if(!in_array($s["role"],$related,true)&&!in_array($s["name"],$related,true))continue;if(!$s["present"]||!$s["enabled"]||$s["event"])continue;if(!$s["cron"])throw new Exception("Native User Scripts timing unavailable");$events[]=["label"=>$s["name"],"cron"=>$s["cron"],"timezone"=>"Asia/Singapore","durationSeconds"=>60];}

      $holds=[];$first=null;
      if($current===null)$holds[]=["label"=>"Outside approved update windows","at"=>($next??$now)];
      elseif($now+$reserve>$current["end"])$holds[]=["label"=>"Not enough time to finish before update window closes","at"=>$current["end"]];
      foreach($events as $event){[$at,$active]=occurrence($event,$now);if($at!==null&&($first===null||$at<$first["at"]))$first=["label"=>$event["label"],"at"=>$at];
        if($active>$now)$holds[]=["label"=>"Protected scheduled interval: ".$event["label"],"at"=>$active];
        elseif($at!==null&&$at<=$now+$reserve)$holds[]=["label"=>"Finish-by buffer before ".$event["label"],"at"=>$at];
      }
      $detail=count($holds)?implode("; ",array_map(fn($h)=>$h["label"]." (".(new DateTimeImmutable("@".$h["at"]))->setTimezone($zone)->format("Y-m-d H:i T").")",$holds)):"Quiet interval verified; update budget fits before scheduled work";
      echo json_encode(["ready"=>!count($holds),"detail"=>$detail,"holds"=>$holds,"nextEvent"=>$first,"retryAt"=>$next,"reservedSeconds"=>$reserve]);
    ' "$mode" "$now" "$reserve" "$name" "$kind" "$POLICY_FILE" "$BACKUP_SCHEDULE_FILE" "$catalog" <<<"$manifest" || rc=$?
    [[ -z "$catalog" ]] || rm -f -- "$catalog"
    return "$rc"
}
resolve_readiness_provider() {
    [[ -f "$WATCHDOG_SCRIPT" ]] && return 0
    local catalogue path
    catalogue=$(usr_scripts_catalog "$BACKUP_SCHEDULE_FILE" "${USER_SCRIPTS_PHYSICAL_ROOT:-$(dirname "$BACKUP_SCHEDULE_FILE")/scripts}") || return 1
    path=$(jq -er '.scriptsRoot as $root|[.roles|to_entries[]|select(.value=="docker_service_watchdog")|($root+"/"+.key+"/script")]|select(length==1)|.[0]' <<<"$catalogue") || { SUMMARY='Required Docker update readiness provider is absent; configure a replacement. Safety checks remain enabled';return 1; }
    WATCHDOG_SCRIPT="$path"
}
scheduled_work_guard() {
    local kind="$1" name="$2" phase="${3:-prepare}" manifest='{"verified":true,"events":[]}' reserve=1200
    [[ "$phase" != dispatch ]] || reserve=780
    if [[ "$kind" == docker ]];then
      resolve_readiness_provider || return 1
      if ! bounded 40 /bin/bash "$WATCHDOG_SCRIPT" --update-schedule "$name" >"$TMP_DIR/native-schedule.json" 2>"$TMP_DIR/native-schedule.err" || ! jq -e '.schema==1 and (.events|type)=="array"' "$TMP_DIR/native-schedule.json" >/dev/null 2>&1;then
        SUMMARY="$name native schedule could not be verified; update deferred";return 1
      fi
      manifest=$(cat "$TMP_DIR/native-schedule.json")
    fi
    calendar_eval guard "$(date +%s)" "$reserve" "$name" "$kind" "$manifest" >"$TMP_DIR/schedule-guard.json" 2>"$TMP_DIR/schedule-guard.err" || { SUMMARY="$name schedule syntax/interface unverified; no update started";return 1; }
    SUMMARY=$(jq -r .detail "$TMP_DIR/schedule-guard.json")
    jq -e '.ready==true' "$TMP_DIR/schedule-guard.json" >/dev/null
}

window_open(){ calendar_eval window "$(date +%s)" | jq -e '.ready==true' >/dev/null; }

within_budget(){ (( $(date +%s)<START_EPOCH+MAX_RUNTIME_SECONDS-${1:-0} )); }
write_adapter(){ cat >"$TMP_DIR/native.php" <<'NATIVEPHP'
<?php
// Read-only adapter. Installation remains with Unraid's native entry points.
declare(strict_types=1);
error_reporting(E_ERROR|E_PARSE);
$_SERVER['DOCUMENT_ROOT']='/usr/local/emhttp';$_SERVER['REQUEST_URI']='';$docroot='/usr/local/emhttp';
require_once "$docroot/webGui/include/Wrappers.php";
require_once "$docroot/plugins/dynamix.docker.manager/include/DockerClient.php";
function output(array $data):never {echo json_encode($data,JSON_THROW_ON_ERROR|JSON_UNESCAPED_SLASHES)."\n";exit;}
function pluginRecord(string $path):array {
 $xml=@simplexml_load_file($path,'SimpleXMLElement',LIBXML_NONET);if(!$xml)throw new RuntimeException('Invalid plugin XML');
 $a=$xml->attributes();return ['version'=>(string)$a['version'],'url'=>(string)$a['pluginURL'],'min'=>(string)$a['min'],'max'=>(string)$a['max'],'sha256'=>hash_file('sha256',$path)];
}
try {
 $mode=$argv[1]??'';$client=new DockerClient();$templates=new DockerTemplates();
 if($mode==='inventory'){
  $docker=[];foreach($client->getDockerContainers() as $row){$name=$row['Name'];$inspect=$client->getContainerDetails($name);$template=$templates->getUserTemplate($name);$repo='';
   if($template && is_file($template)&&!is_link($template)){$x=@simplexml_load_file($template,'SimpleXMLElement',LIBXML_NONET);$repo=$x?(string)$x->Repository:'';}
   $docker[$name]=['name'=>$name,'id'=>$inspect['Id']??'','imageId'=>$inspect['Image']??'','runtimeImage'=>$inspect['Config']['Image']??'','repository'=>$repo,'running'=>(bool)($inspect['State']['Running']??false),'health'=>$inspect['State']['Health']['Status']??'none','template'=>$template?:'','templateHash'=>$template?hash_file('sha256',$template):'','managed'=>$inspect['Config']['Labels']['net.unraid.docker.managed']??''];
  }
  $plugins=[];foreach(glob('/var/log/plugins/*.plg') as $path){$name=basename($path);$plugins[$name]=['name'=>$name,'installed'=>pluginRecord($path)];}
  output(['schema'=>1,'docker'=>$docker?:new stdClass(),'plugins'=>$plugins?:new stdClass(),'complete'=>true]);
 }
 if($mode==='docker-check'||$mode==='docker-local'){
  $repo=$argv[2]??'';if(!$repo||strlen($repo)>512)throw new RuntimeException('Invalid repository');$u=new DockerUpdate();
  $name=$argv[3]??'';$reference=$repo;
  if($name!=='') {if(!preg_match('/^[A-Za-z0-9][A-Za-z0-9_.-]*$/D',$name))throw new RuntimeException('Invalid container');$d=$client->getContainerDetails($name);$reference=$d['Image']??'';if(!$reference)throw new RuntimeException('Container image unavailable');}
  // The installed container, not a shared mutable tag, owns this evidence.
  // A Plex pull must not make a second, older Plex container look current.
  $inspect=$client->getDockerJSON('/images/'.$reference.'/json');$local=null;
  $normalize=static function(string $v):string {$v=preg_replace('/:[^\/]+$/','',explode('@',$v)[0]);$v=preg_replace('#^(docker.io|index.docker.io|registry-1.docker.io)/#','',$v);if(!str_contains($v,'/'))$v='library/'.$v;return $v;};
  foreach($inspect['RepoDigests']??[] as $digest){$parts=explode('@',$digest,2);if(count($parts)===2&&$normalize($parts[0])===$normalize($repo))$local=$parts[1];}
  $provenance='docker-image-metadata';$cachePath=$argv[4]??'';
  // Native image cleanup can remove RepoDigests from an image still used by
  // the other Plex container. Reuse only evidence bound to this exact image,
  // container and repository; a newly recreated container cannot inherit it.
  if(!$local&&$name!==''&&$cachePath!==''&&is_file($cachePath)&&!is_link($cachePath)&&filesize($cachePath)<8388608){
   $cache=json_decode(file_get_contents($cachePath),true);$old=$cache['items']['docker:'.$name]['evidence']??[];
   if(($old['imageId']??'')===$reference&&($old['containerId']??'')===($d['Id']??null)&&($old['identity']??'')===$repo&&in_array($old['installedDigestSource']??'',['docker-image-metadata','verified-image-cache'],true)){$local=$old['local']??null;$provenance='verified-image-cache';}
  }
  if(!is_string($local)||!preg_match('/^sha256:[a-f0-9]{64}$/D',$local))throw new RuntimeException('Installed digest unavailable');if($mode==='docker-local')output(['schema'=>1,'local'=>$local,'imageId'=>$reference,'containerId'=>$d['Id']??null,'identity'=>$repo,'installedDigestSource'=>$provenance]);$remote=$u->getRemoteVersionV2($repo);
  if(!is_string($remote)||!preg_match('/^sha256:[a-f0-9]{64}$/D',$remote))throw new RuntimeException('Registry digest unavailable');
  output(['schema'=>1,'remote'=>$remote,'local'=>$local,'available'=>$local!==$remote,'imageId'=>$reference,'containerId'=>$d['Id']??null,'identity'=>$repo,'installedDigestSource'=>$provenance]);
 }
 if($mode==='plugin-check'){
  $name=$argv[2]??'';if(!preg_match('/^[a-zA-Z0-9_.-]+\.plg$/D',$name))throw new RuntimeException('Invalid plugin name');
  $installed=pluginRecord('/var/log/plugins/'.$name);$candidate=pluginRecord('/tmp/plugins/'.$name);
  require_once "$docroot/plugins/dynamix.plugin.manager/include/PluginHelpers.php";
  $busy=plugin_task_busy($name);
  $version=parse_ini_file('/etc/unraid-version')['version']??'';
  $compatible=(!$candidate['min']||version_compare($version,$candidate['min'],'>='))&&(!$candidate['max']||version_compare($version,$candidate['max'],'<='));
  output(['schema'=>1,'installed'=>$installed,'candidate'=>$candidate,'busy'=>$busy,'compatible'=>$compatible,'available'=>version_compare($candidate['version'],$installed['version'],'>')]);
 }
 if($mode==='definition'){
  $name=$argv[2]??'';$d=$client->getContainerDetails($name);$path=$templates->getUserTemplate($name);if(!$d||!$path)throw new RuntimeException('Container/template unavailable');
  $x=@simplexml_load_file($path,'SimpleXMLElement',LIBXML_NONET);if(!$x)throw new RuntimeException('Template XML invalid');$env=[];
  $all=[];foreach($d['Config']['Env']??[] as $item){[$key,$val]=array_pad(explode('=',$item,2),2,'');$all[$key]=$val;}
  foreach($x->Config as $c){if(strtolower((string)$c['Type'])==='variable'){$key=(string)$c['Target'];$env[$key]=$all[$key]??null;}}
  $host=[];foreach(['Binds','PortBindings','NetworkMode','Privileged','CapAdd','CapDrop','Devices','DeviceRequests','SecurityOpt','ReadonlyRootfs','RestartPolicy','Memory','NanoCpus','CpusetCpus','ExtraHosts','Dns','DnsSearch','GroupAdd','Ulimits','LogConfig','ShmSize'] as $key)$host[$key]=$d['HostConfig'][$key]??null;
  $net=[];foreach($d['NetworkSettings']['Networks']??[] as $network=>$details)$net[$network]=$details['IPAMConfig']??null;ksort($net);ksort($env);
  $labels=[];foreach(['net.unraid.docker.managed'] as $key)$labels[$key]=$d['Config']['Labels'][$key]??null;
  output(['schema'=>1,'name'=>$name,'id'=>$d['Id'],'imageId'=>$d['Image'],'runtimeImage'=>$d['Config']['Image'],'running'=>$d['State']['Running'],'health'=>$d['State']['Health']['Status']??'none','template'=>$path,'templateHash'=>hash_file('sha256',$path),'definition'=>['host'=>$host,'networks'=>$net,'userEnv'=>$env,'labels'=>$labels,'user'=>$d['Config']['User']??'','workingDir'=>$d['Config']['WorkingDir']??'']]);
 }
 throw new RuntimeException('Unknown adapter mode');
}catch(Throwable $e){fwrite(STDERR,"Native update evidence unavailable; no installer action performed by adapter.\n");exit(1);}
NATIVEPHP
}

initialize() {
    mountpoint -q "$VAULT_MOUNT" || { printf 'Required vault unavailable; no update started.\n' >&2;return 1; }
    [[ ! -L "$STATE_DIR" && ! -L "$STATUS_DIR" ]] || return 1
    mkdir -p "$STATE_DIR" "$STATUS_DIR" || return 1
    for file in "$STATE_FILE" "$POLICY_FILE" "$LOG_FILE";do [[ ! -L "$file" ]] || return 1;done
    TMP_DIR=$(mktemp -d /tmp/system-update-coordinator.XXXXXX) || return 1
    write_adapter
    if [[ ! -f "$STATE_FILE" ]];then jq -n --argjson now "$(date +%s)" '{schema:1,items:{},jobs:{},outbox:[],delivered:{},checks:{},retired:{},installedAt:$now}' >"$TMP_DIR/initial";publish "$TMP_DIR/initial" "$STATE_FILE" || return 1;fi
    state_valid "$STATE_FILE" || { log ERROR 'State invalid; preserved; updates prohibited';return 1; }
    if [[ ! -f "$POLICY_FILE" ]];then
      adapter inventory >"$TMP_DIR/initial-inventory" || return 1
      jq "$APPROVAL_JQ"' (now|floor) as $epoch |
        {schema:1,enabled:true,window:{start:"13:15",end:"15:30"},windows:[{start:"13:15",end:"15:30"},{start:"21:15",end:"23:00"}],reportTime:"23:15",limits:{dailyTotal:8,dailyDocker:6,dailyPlugins:2,candidateHoldHours:24,imageMaxBytes:4294967296},
         docker:(.docker|with_entries(.value=approval({};.value.repository;(.value.repository|length>0);"docker";$epoch))),
         plugins:(.plugins|with_entries(.value=approval({};.value.installed.url;(.key!="unRAIDServer.plg" and (.value.installed.url|startswith("https://")));"plugin";$epoch)))}' "$TMP_DIR/initial-inventory" >"$TMP_DIR/policy.initial" || return 1
      policy_valid "$TMP_DIR/policy.initial" && publish "$TMP_DIR/policy.initial" "$POLICY_FILE" || return 1
    fi
    policy_valid "$POLICY_FILE" || { log ERROR 'Policy invalid; preserved; updates prohibited';return 1; }
    # Preserve retry eligibility when upgrading an already queued daily report.
    if jq -e '.normalDeliveryIds==null and any(.outbox[];.importance=="normal" and (.subject|startswith("Daily update summary")))' "$STATE_FILE" >/dev/null;then
      mutate '.normalDeliveryIds=[.outbox[]|select(.importance=="normal")|.id]' || return 1
    fi
}

reconcile_script_schedules() {
    local result="$TMP_DIR/script-reconcile.json" row id ids='[]' reload=false
    if ! usr_scripts_reconcile "$BACKUP_SCHEDULE_FILE" "${USER_SCRIPTS_PHYSICAL_ROOT:-$(dirname "$BACKUP_SCHEDULE_FILE")/scripts}" system_update_coordinator >"$result";then
      SUMMARY=$(jq -r '.detail // "User Scripts schedule catalogue unavailable"' "$result" 2>/dev/null);return 1
    fi
    if [[ $(jq -r '.cronReloadPending // false' "$result") == true ]];then
      bounded 12 update_cron || { SUMMARY='Native User Scripts cron reload pending; source metadata retained';return 1; };reload=true
    fi
    while IFS= read -r row;do
      id=$(jq -r .id <<<"$row")
      event normal 'User Scripts schedule inventory reconciled' "$(jq -r '"Retired scripts/references: "+(if (.removed|length)>0 then (.removed|join(", ")) else "none" end)+". Runtime schedule synchronized: "+(.runtimeSynced|tostring)+". Native custom cron updated: "+(.cronUpdated|tostring)+". Two stable observations confirmed the source; active jobs and held locks were preserved. Remaining script settings/descriptions and historical logs were retained. No script payload or held lock was deleted."' <<<"$row")" "script-schedule:$id" || return 1
      ids=$(jq -nc --argjson ids "$ids" --arg id "$id" '$ids+[$id]')
    done < <(jq -c '.events[]?' "$result")
    if [[ "$ids" != '[]' || "$reload" == true ]];then usr_scripts_registry_ack "$ids" "$reload" || return 1;fi
}
report_retired_updates() {
    local row key name id
    while IFS= read -r row;do
      key=$(jq -r .key <<<"$row");name=$(jq -r .value.name <<<"$row");id=$(jq -r .value.retiredAt <<<"$row")
      event normal 'Removed application/plugin retired from updates' "$name: absent from two complete inventories. Update approval, future scheduling checks and active update tracking were retired. Historical recovery evidence and logs were retained; no application was recreated or started." "retired-update:$key:$id" || return 1
      mutate --arg key "$key" --argjson now "$(date +%s)" '.retired[$key].reportedAt=$now' || return 1
    done < <(jq -c '.retired|to_entries[]|select(.value.reportedAt==null)' "$STATE_FILE")
    prune_update_requests
}

collect_inventory() {
    docker_cmd info >/dev/null || return 1
    adapter inventory >"$TMP_DIR/inventory.json" || return 1
    docker_cmd container ls -a --format '{{.Names}}' | jq -Rsc 'split("\n")|map(select(length>0))|sort' >"$TMP_DIR/docker-names.json" || return 1
    jq -e --slurpfile names "$TMP_DIR/docker-names.json" '(.docker|keys|sort)==$names[0]' "$TMP_DIR/inventory.json" >/dev/null || return 1
    jq -e '.schema==1 and .complete==true and (.docker|type)=="object" and (.plugins|type)=="object"' "$TMP_DIR/inventory.json" >/dev/null || return 1
    # A failed/partial inventory never retires anything. Two full observations
    # retire old identities; a stopped, installed container remains present.
    mutate --slurpfile inv "$TMP_DIR/inventory.json" --argjson now "$(date +%s)" '
      .inventory=$inv[0] |
      .items |= with_entries(.value as $old |
        (if $old.kind=="docker" then $inv[0].docker[$old.name] else $inv[0].plugins[$old.name] end) as $live |
        if $live==null then .value.missingScans=((.value.missingScans // 0)+1) else .value.missingScans=0 end) |
      reduce (.items|to_entries[]|select(.value.missingScans>=2)) as $r (.;.retired[$r.key]=($r.value+{retiredAt:$now})|del(.items[$r.key])) |
      .retired |= with_entries(select(.value.retiredAt>=$now-90*86400))' || return 1
    # Forget deleted approvals automatically; never grant approval again merely
    # because a different installation later reuses the name.
    policy_update --slurpfile state "$STATE_FILE" '
      .docker |= with_entries(select($state[0].retired["docker:"+.key]==null)) |
      .plugins |= with_entries(select($state[0].retired["plugin:"+.key]==null))' || return 1
    mutate --slurpfile inv "$TMP_DIR/inventory.json" --argjson now "$(date +%s)" '
      [($inv[0].docker|to_entries[]|{kind:"docker",name:.key,identity:.value.repository}),
       ($inv[0].plugins|to_entries[]|{kind:"plugin",name:.key,identity:.value.installed.url})] as $live |
      reduce $live[] as $v (.;($v.kind+":"+$v.name) as $key |
        .items[$key]=((.items[$key] // ($v+{firstSeen:$now,checkedAt:0,missingScans:0})) |
          if .identity!=$v.identity then $v+{firstSeen:$now,checkedAt:0,missingScans:0,identityChanged:true} else . end) |
        del(.retired[$key]))'

}

adapter_compatible() {
    local os;os=$(sed -n 's/^version="\([^"]*\)"/\1/p' /etc/unraid-version)
    [[ "$os" == 7.* ]] || return 1
    php -r 'exit(PHP_VERSION_ID>=80100?0:1);' || return 1
    [[ -x "$NATIVE_DOCKER_UPDATE" && -x "$NATIVE_PLUGIN" ]] || return 1
    grep -Fq 'getUserTemplate($value)' "$NATIVE_DOCKER_UPDATE" &&
      grep -Fq 'pullImage_nchan($Name, $Repository)' "$NATIVE_DOCKER_UPDATE" &&
      grep -Fq 'connectExtraNetworks(' "$NATIVE_DOCKER_UPDATE" &&
      grep -Fq 'Usage: plugin update PLUGIN' "$NATIVE_PLUGIN"
}

check_updates() {
    local key kind name identity now count=0 candidate available check_rc data previous_failures
    PHASE=check;now=$(date +%s)
    while IFS=$'\t' read -r key kind name identity;do
      ((count<MAX_CHECKS_PER_RUN)) && within_budget 180 || break
      count=$((count+1));check_rc=0
      previous_failures=$(jq -r --arg key "$key" '.items[$key].checkFailures // 0' "$STATE_FILE")
      if [[ "$kind" == docker ]];then
        if [[ -z "$identity" || "$identity" == *@* ]];then
          mutate --arg key "$key" --argjson now "$now" '.items[$key].checkedAt=$now | .items[$key].available=false | .items[$key].checkStatus="PINNED_OR_UNMANAGED"' || return 1
          continue
        fi
        adapter docker-check "$identity" "$name" "$STATE_FILE" >"$TMP_DIR/check.json" 2>"$TMP_DIR/check.err" || check_rc=$?
      elif [[ "$name" == unRAIDServer.plg ]];then
        bounded 100 env QUERY_STRING=json=true "$NATIVE_OS_CHECK" >"$TMP_DIR/os-check.json" 2>"$TMP_DIR/os-check.err" || check_rc=$?
        # The native OS result is retained as evidence; never route OS through a plugin installer.
        if ((check_rc==0)) && jq -e '(.version|type)=="string" and (.isNewer|type)=="boolean"' "$TMP_DIR/os-check.json" >/dev/null;then
          jq -n --slurpfile result "$TMP_DIR/os-check.json" '{schema:1,available:$result[0].isNewer,osEvidence:$result[0],candidate:{version:$result[0].version}}' >"$TMP_DIR/check.json"
        else check_rc=1;fi
      else
        bounded 120 "$NATIVE_PLUGIN" check "$name" >"$TMP_DIR/plugin-check.log" 2>&1 && adapter plugin-check "$name" >"$TMP_DIR/check.json" 2>"$TMP_DIR/check.err" || check_rc=$?
      fi
      if ((check_rc!=0)) || ! jq -e '.schema==1 and (.available|type)=="boolean"' "$TMP_DIR/check.json" >/dev/null 2>&1;then
        mutate --arg key "$key" --argjson now "$now" '.items[$key].checkedAt=$now | .items[$key].checkFailures=((.items[$key].checkFailures // 0)+1) | .items[$key].checkStatus="UNVERIFIED"' || return 1
        if ((previous_failures>=2));then
          event warning 'Update check remains unavailable' "$kind/$name: repeated native/registry checks failed. Installed application unchanged; automatic installation prohibited until fresh evidence is available. Bounded retry backoff continues." "check-unavailable:$key:$((now/(7*86400)))" || return 1
        fi
        log WARNING "$kind/$name: update evidence unavailable; installed application unchanged; retry uses bounded backoff"
        continue
      fi
      if [[ "$kind" == docker ]];then candidate=$(jq -r .remote "$TMP_DIR/check.json");else candidate=$(jq -r '.candidate.version' "$TMP_DIR/check.json");fi
      available=$(jq -r .available "$TMP_DIR/check.json")
      local fingerprint="$candidate"
      [[ "$kind" != plugin || "$name" == unRAIDServer.plg ]] || fingerprint="$candidate:$(jq -r .candidate.sha256 "$TMP_DIR/check.json")"
      mutate --arg fingerprint "$fingerprint" --arg key "$key" --arg candidate "$candidate" --argjson available "$available" --argjson now "$now" --slurpfile data "$TMP_DIR/check.json" '
        .items[$key] |= (.candidateSeenAt=(if .candidateFingerprint==$fingerprint then (.candidateSeenAt // $now) else $now end) |
          .candidateFingerprint=$fingerprint | .candidate=$candidate | .available=$available | .checkedAt=$now | .checkFailures=0 | .checkStatus="VERIFIED" | .candidateStatus=(if $available then "CANDIDATE" else "UP_TO_DATE" end) | .evidence=$data[0])' || return 1
      if ((previous_failures>=3));then event normal 'Update checks restored' "$kind/$name: fresh native update evidence obtained after repeated check failures; normal approval and installation guards remain in force." "check-restored:$key:$((now/(7*86400)))" || return 1;fi
      log INFO "$kind/$name: update check completed; available=$available; no installation performed by check"
    done < <(jq -r --argjson now "$now" --argjson interval "$CHECK_INTERVAL_SECONDS" '.items|to_entries|sort_by(.value.checkedAt // 0)|.[]|
      select(.value.missingScans==0 and $now-(.value.checkedAt // 0)>=(if (.value.checkFailures // 0)>0 then ([1800 * pow(2;([.value.checkFailures,3]|min)),21600]|min) else $interval end))|
      [.key,.value.kind,.value.name,.value.identity]|@tsv' "$STATE_FILE")
}

backup_schedule_window() {
    # Two due occurrences means one missed run is tolerated. A 12-hour finish
    # grace is applied before a scheduled start becomes due. No cron changes.
    local kind="$1" now="$2" name=backup_cache_appdata catalog rc=0
    [[ "$kind" != plugin ]] || name=backup_boot_disk
    catalog=$(mktemp "${TMP_DIR:-/tmp}/backup-catalog.XXXXXX") || return 1
    if ! usr_scripts_catalog "$BACKUP_SCHEDULE_FILE" "${USER_SCRIPTS_PHYSICAL_ROOT:-$(dirname "$BACKUP_SCHEDULE_FILE")/scripts}" >"$catalog";then cat "$catalog";rm -f "$catalog";return 1;fi
    usr_scripts_due_window "$catalog" "$name" "$now" "$BACKUP_FINISH_GRACE_SECONDS" "$BACKUP_MAX_AGE_SECONDS" || rc=$?
    rm -f -- "$catalog";return "$rc"
}

backup_evidence() {
    local kind="$1" source manifest hash now window cutoff
    now=$(date +%s);BACKUP_REASON='Verified backup evidence unavailable'
    window=$(backup_schedule_window "$kind" "$now") || { BACKUP_REASON=$(jq -r '.source // .detail // "Required backup schedule unavailable; protection is not disabled"' <<<"$window" 2>/dev/null) || BACKUP_REASON="Required backup schedule unavailable; protection is not disabled";return 1; }
    cutoff=$(jq -r .cutoff <<<"$window")
    BACKUP_REASON="Verified backup required since $(TZ=Asia/Singapore date -d "@$cutoff" '+%Y-%m-%d %H:%M SGT'); $(jq -r .source <<<"$window")"
    if [[ "$kind" == docker ]];then
      source="$STATUS_DIR/iss-backup-request.json"
      jq -e --argjson cutoff "$cutoff" '.schema==1 and .completedAt>=$cutoff and (.generation|startswith("/mnt/vault/backup/cache/backup_")) and (.manifestSha256|test("^[a-f0-9]{64}$"))' "$source" >/dev/null || return 1
      manifest=$(jq -r .generation "$source")/backup_manifest.tsv
      [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
      hash=$(sha256sum "$manifest"|cut -d' ' -f1)
      [[ "$hash" == "$(jq -r .manifestSha256 "$source")" ]] || return 1
      cp "$source" "$TMP_DIR/backup-evidence.json"
    else
      source=/mnt/vault/backup/flash/.backup_boot_disk_state.json
      jq -e --argjson cutoff "$cutoff" '.successfulAt>=$cutoff and (.archiveSha256|test("^[a-f0-9]{64}$"))' "$source" >/dev/null || return 1
      [[ -f "$(jq -r .backupFile "$source")" ]] || return 1
      cp "$source" "$TMP_DIR/backup-evidence.json"
    fi
}

release_operation_locks() {
    local fd
    [[ -z "${OWN_GATE_FD:-}" ]] || exec {OWN_GATE_FD}>&-
    OWN_GATE_FD=''
    for fd in "${PRODUCER_FDS[@]}";do exec {fd}>&-;done
    PRODUCER_FDS=()
}
clear_update_request() {
    local file="${1:-${CURRENT_REQUEST:-}}"
    [[ -n "$file" && -f "$file" && ! -L "$file" ]] || return 0
    jq -e '.schema==1 and .owner=="system_update_coordinator"' "$file" >/dev/null 2>&1 || return 1
    rm -f -- "$file"
}
request_update_handoff() {
    local name="$1" scopes="$2" temp now file
    CURRENT_REQUEST='';REQUEST_KEEP=false
    [[ "$scopes" != '[]' ]] || return 0
    valid_name "$name" || return 1
    [[ ! -L "$APP_UPDATE_REQUEST_DIR" ]] || return 1
    mkdir -p "$APP_UPDATE_REQUEST_DIR" || return 1
    file="$APP_UPDATE_REQUEST_DIR/$name.json";now=$(date +%s)
    if [[ -e "$file" ]];then
      [[ ! -L "$file" ]] && jq -e --arg name "$name" '.owner=="system_update_coordinator" and .target==$name' "$file" >/dev/null 2>&1 || { SUMMARY="Update handoff for $name cannot be owned safely; existing request preserved";return 1; }
    fi
    temp=$(mktemp "$APP_UPDATE_REQUEST_DIR/.request.XXXXXX") || return 1
    jq -n --arg name "$name" --arg run "$RUN_ID" --arg boot "$(cat /proc/sys/kernel/random/boot_id)" --argjson now "$now" --argjson scopes "$scopes" \
      '{schema:1,owner:"system_update_coordinator",target:$name,runId:$run,boot:$boot,issuedAt:$now,expires:($now+1200),scopes:$scopes,phase:"waiting",reason:"Approved update handoff; existing producer may finish; new conflicting work yields"}' >"$temp" && mv "$temp" "$file" || return 1
    CURRENT_REQUEST="$file"
}
prune_update_requests() {
    local file now boot
    [[ ! -L "$APP_UPDATE_REQUEST_DIR" ]] || return 1
    now=$(date +%s);boot=$(cat /proc/sys/kernel/random/boot_id)
    for file in "$APP_UPDATE_REQUEST_DIR/"*.json;do
      [[ -f "$file" && ! -L "$file" ]] || continue
      local target
      target=$(jq -r '.target // ""' "$file" 2>/dev/null) || continue
      if valid_name "$target" && jq -e --arg key "docker:$target" '.retired[$key]!=null' "$STATE_FILE" >/dev/null 2>&1;then
        if [[ ! -e "$DOCKER_MAINTENANCE_DIR/$target.lock" ]] || flock -s -n "$DOCKER_MAINTENANCE_DIR/$target.lock" -c true;then clear_update_request "$file" || return 1;continue;fi
      fi
      if jq -e --arg boot "$boot" --argjson now "$now" '.owner=="system_update_coordinator" and (.boot!=$boot or ((.expires|type)=="number" and .expires<=$now))' "$file" >/dev/null 2>&1;then rm -f -- "$file";fi
    done
}
native_installer_idle() {
    ! pgrep -f '(^|/)(update_container|installpkg|upgradepkg|removepkg)([[:space:]]|$)|/scripts/plugin (install|update|remove)([[:space:]]|$)' >/dev/null
}
application_group() {
    local family="${1,,} ${2,,}"
    case "$family" in
      *sonarr*|*radarr*|*sabnzbd*|*prowlarr*|*qbittorrent*|*recyclarr*|*bazarr*) printf media_pipeline;;
      *plex*|*kometa*|*metafusion*|*imagemaid*) printf plex_metadata;;
      *) printf '%s' "$1";;
    esac
}
pending_update_guard() {
    local kind="$1" name="$2" identity="${3:-}" row group other
    group=$(application_group "$name" "$identity")
    while IFS= read -r row;do
      if [[ $(jq -r '.kind' <<<"$row") == plugin || $(jq -r '.installerFinishedVerified // false' <<<"$row") != true ]];then
        SUMMARY="All updates wait: $(jq -r .name <<<"$row") installer completion/host outcome unverified";return 1
      fi
      other=$(application_group "$(jq -r .name <<<"$row")" "$(jq -r '.identity // ""' <<<"$row")")
      if [[ "$kind" == plugin || "$other" == "$group" ]];then
        SUMMARY="$name waits: $(jq -r .name <<<"$row") outcome pending in $other; independent Docker groups remain eligible";return 1
      fi
    done < <(jq -c '.jobs[]|select(.status=="INTENT" or .status=="VERIFYING" or .status=="ATTENTION")' "$STATE_FILE")
}
array_update_guard() {
    local values active action correct
    values=$(bounded 5 /usr/local/sbin/mdcmd status) || { SUMMARY='Array activity could not be verified';return 1; }
    grep -q '^mdState=STARTED$' <<<"$values" || { SUMMARY='Array is not started';return 1; }
    active=$(awk -F= '$1=="mdResync"{print $2}' <<<"$values")
    [[ "$active" =~ ^[0-9]+$ ]] || { SUMMARY='Array operation flag unavailable';return 1; }
    [[ "$active" != 0 ]] || return 0
    action=$(awk -F= '$1=="mdResyncAction"{print $2}' <<<"$values")
    correct=$(awk -F= '$1=="mdResyncCorr"{print $2}' <<<"$values")
    if [[ "$action" =~ ^check([[:space:]]|$) && "$correct" == 0 ]];then return 0;fi
    SUMMARY="Array rebuild, parity sync/correction or unverified operation active: $action; updates wait";return 1
}

target_coordination() {
    local kind="$1" family="${2,,} ${3,,}"
    COORD_SCOPES='[]';COORD_EXCLUSIVE=false;COORD_LOCKS=()
    if [[ "$kind" == plugin || "$family" =~ sonarr|radarr|sabnzbd|prowlarr ]];then
      COORD_EXCLUSIVE=true;COORD_SCOPES='["arr","torrent","metadata","integrity"]'
      [[ "$kind" != plugin ]] || COORD_LOCKS+=(/run/media_plex_dbrepair.lock)
    elif [[ "$family" == *qbittorrent* ]];then
      COORD_SCOPES='["torrent"]';COORD_LOCKS+=(/tmp/media_torrent_management.lock)
    elif [[ "$family" =~ plex|kometa|metafusion|imagemaid ]];then
      COORD_SCOPES='["metadata"]';COORD_LOCKS+=("${METADATA_AUDIT_LOCK:-/mnt/vault/cloud/logs/script/media_metadata_audit/audit.lock}")
      [[ "$family" != *plex* ]] || COORD_LOCKS+=(/run/media_plex_dbrepair.lock)
    elif [[ "$family" == *bazarr* ]];then
      COORD_SCOPES='["integrity"]';COORD_LOCKS+=(/run/media_integrity_audit.lock)
    fi
}

maintenance_guard() {
    local kind="${1:-plugin}" name="${2:-plugin}" identity="${3:-}" lock values fd scopes='[]' exclusive=false family="${2:-plugin} ${3:-}"
    [[ "$COORDINATION_WAIT_SECONDS" =~ ^[0-9]+$ ]] && ((COORDINATION_WAIT_SECONDS<=120)) || { SUMMARY="Invalid coordination wait limit";return 1; }
    local deadline=$(( $(date +%s)+COORDINATION_WAIT_SECONDS ))
    family=${family,,}
    release_operation_locks
    [[ "${REQUEST_KEEP:-false}" == true ]] || clear_update_request || return 1
    CURRENT_REQUEST='';REQUEST_KEEP=false;GUARD_GLOBAL=true
    for lock in /tmp/backup_cache_appdata.lock /tmp/backup_boot_disk.lock;do
      if [[ -e "$lock" ]];then flock -s -n "$lock" -c true || { SUMMARY="Maintenance deferred: ${lock##*/} active";return 1; };fi
    done
    native_installer_idle || { SUMMARY='Maintenance deferred: native installer/package operation active';return 1; }
    # Mover and unrelated remote copies/read-only drills are I/O advisories.
    # Shared/exclusive application gates still protect actual data mutation.
    array_update_guard || return 1
    GUARD_GLOBAL=false
    target_coordination "$kind" "$name" "$identity"
    exclusive=$COORD_EXCLUSIVE;scopes=$COORD_SCOPES
    local -a producer_locks=("${COORD_LOCKS[@]}")
    request_update_handoff "$name" "$scopes" || return 1
    # Wait only for existing consumers, never remove their lock. The expiring
    # request survives a busy attempt so the next scheduled run can resume.
    for lock in "${producer_locks[@]}";do
      [[ -e "$lock" ]] || continue
      exec {fd}>"$lock" || return 1
      if ! flock -s -w "$((deadline>$(date +%s) ? deadline-$(date +%s) : 0))" "$fd";then
        exec {fd}>&-;REQUEST_KEEP=true;SUMMARY="$name update waiting for ${lock##*/} to finish; bounded handoff remains queued; no app stopped";return 1
      fi
      PRODUCER_FDS+=("$fd")
    done
    exec {OWN_GATE_FD}>"$ARR_BACKUP_GATE" || return 1
    local mode=-s;[[ "$exclusive" != true ]] || mode=-x
    if ! flock "$mode" -w "$((deadline>$(date +%s) ? deadline-$(date +%s) : 0))" "$OWN_GATE_FD";then
      REQUEST_KEEP=true;SUMMARY="$name update waiting for existing application/backup operation to finish; next eligible run resumes after verification; no lock bypassed";return 1
    fi
    # Recyclarr has its own native scheduler, outside the shared script gate.
    if [[ "$kind" == docker && "$family" =~ sonarr|radarr ]] && jq -e '.docker.recyclarr.running==true' "$TMP_DIR/inventory.json" >/dev/null 2>&1;then
      readiness recyclarr || { REQUEST_KEEP=true;SUMMARY="$name update waiting for native Recyclarr sync/idle verification; no app stopped";return 1; }
    fi
    SUMMARY="$name maintenance handoff acquired; existing conflicting operations completed"
}


readiness() {
    local name="$1"
    resolve_readiness_provider || return 1
    bounded 50 /bin/bash "$WATCHDOG_SCRIPT" "${2:---update-readiness}" "$name" >"$TMP_DIR/readiness.json" 2>"$TMP_DIR/readiness.err" || return 1
    jq -e '.schema==1 and .ready==true' "$TMP_DIR/readiness.json" >/dev/null
}

# Native plugin versions are not enough for host-network/GPU dependencies.
plugin_service_guard() {
    local name="$1" mode="${2:-before}" service
    docker_cmd info >/dev/null 2>&1 || return 1
    case "$name" in
      tailscale.plg)
        bounded 12 tailscale status --json | jq -e '.BackendState=="Running" and .Self.Online==true' >/dev/null || return 1;;
      gpustat.plg|intel-gpu-top.plg)
        for service in plex-media plex-media-server;do
          jq -e --arg n "$service" '.inventory.docker[$n].running==true' "$STATE_FILE" >/dev/null || continue
          if [[ "$mode" == before ]];then readiness "$service" || return 1
          else readiness "$service" --readiness || return 1;fi
        done;;
    esac
}

start_container_lease() {
    local name="$1" old_id="$2" temp
    mkdir -p "$DOCKER_MAINTENANCE_DIR" || return 1
    exec {MAINT_FD}>"$DOCKER_MAINTENANCE_DIR/$name.lock";flock -x -n "$MAINT_FD" || return 1
    # Never replace or bypass another producer's maintenance lease.
    local file now;now=$(date +%s)
    for file in "$DOCKER_MAINTENANCE_DIR/$name"*.json;do
      [[ ! -e "$file" ]] || jq -e --argjson now "$now" '(.expires|type)=="number" and .expires<=$now' "$file" >/dev/null || return 1
    done
    LEASE_FILE="$DOCKER_MAINTENANCE_DIR/$name.update.json"
    [[ ! -L "$LEASE_FILE" ]] || return 1
    temp=$(mktemp "$DOCKER_MAINTENANCE_DIR/.update.XXXXXX") || return 1
    jq -n --arg owner system_update_coordinator --arg id "$RUN_ID" --arg containerId "$old_id" --arg boot "$(cat /proc/sys/kernel/random/boot_id)" --argjson expires "$((now+1200))" \
      '{owner:$owner,runId:$id,containerId:$containerId,boot:$boot,pid:0,expires:$expires,reason:"Approved automatic update; verification pending"}' >"$temp" && mv "$temp" "$LEASE_FILE"
}

job_update() { local id="$1" expression="$2";shift 2;mutate --arg id "$id" "$@" "$expression"; }

prepare_recovery_set() {
    local kind="$1" name="$2" id="$3" old_image="${4:-}" old_size free target max_bytes
    RECOVERY_REASON="Previous-image export, configuration copy or archive validation did not complete"
    max_bytes=$(jq -r '.limits.imageMaxBytes // 4294967296' "$POLICY_FILE")
    [[ "$ROLLBACK_ROOT" == "$VAULT_MOUNT"/backup/system_updates && ! -L "$ROLLBACK_ROOT" ]] || return 1
    if [[ -e "$ROLLBACK_ROOT" ]];then [[ -f "$ROLLBACK_ROOT/.owner" && $(cat "$ROLLBACK_ROOT/.owner") == system_update_coordinator ]] || return 1
    else mkdir -m 700 "$ROLLBACK_ROOT" && printf 'system_update_coordinator\n' >"$ROLLBACK_ROOT/.owner" || return 1;fi
    target="$ROLLBACK_ROOT/$id";mkdir -m 700 "$target" || return 1
    printf '%s\n' "$id" >"$target/.owner" || return 1
    cp "$TMP_DIR/backup-evidence.json" "$target/backup-evidence.json" || return 1
    if [[ "$kind" == docker ]];then
      old_size=$(docker_cmd image inspect "$old_image" --format '{{.Size}}') || return 1
      [[ "$old_size" =~ ^[0-9]+$ ]] || return 1
      ((old_size<=max_bytes)) || { RECOVERY_REASON="Image size $old_size bytes exceeds recovery archive limit $max_bytes bytes";return 1; }
      free=$(df -PB1 "$ROLLBACK_ROOT"|awk 'NR==2{print $4}');((free>=old_size+10*1024*1024*1024)) || { RECOVERY_REASON="Vault free $free bytes does not cover previous image $old_size bytes plus 10 GiB reserve";return 1; }
      cp "$TMP_DIR/definition-before.json" "$target/definition-before.json"
      cp "$(jq -r .template "$TMP_DIR/definition-before.json")" "$target/template.xml" || return 1
      # Native DockerMan can force-remove the previous image. Archive it before
      # invoking that installer; never assume a temporary tag protects it.
      bounded 180 /bin/bash -c 'set -o pipefail;set +o posix;ulimit -f "$3";docker image save "$1" | gzip -1 >"$2"' _ "$old_image" "$target/image.tar.gz.partial" "$((max_bytes/1024))" || return 1
      bounded 90 gzip -t "$target/image.tar.gz.partial" || return 1
      mv "$target/image.tar.gz.partial" "$target/image.tar.gz"
      sha256sum "$target/image.tar.gz" >"$target/image.sha256";sync -f "$target/image.tar.gz" || return 1
    else
      cp "/var/log/plugins/$name" "$target/installed.plg" && cp "/tmp/plugins/$name" "$target/candidate.plg" || return 1
    fi
    printf '%s\n' "$target" >"$TMP_DIR/recovery-path"
}

job_verified() {
    local id="$1" kind name expected identity current current_id
    VERIFY_REASON=unverified
    kind=$(jq -r --arg id "$id" '.jobs[$id].kind' "$STATE_FILE");name=$(jq -r --arg id "$id" '.jobs[$id].name' "$STATE_FILE");expected=$(jq -r --arg id "$id" '.jobs[$id].candidate' "$STATE_FILE")
    if [[ "$kind" == docker ]];then
      adapter definition "$name" >"$TMP_DIR/definition-after.json" || return 1
      identity=$(jq -r --arg id "$id" '.jobs[$id].identity' "$STATE_FILE")
      same_repository "$(jq -r .runtimeImage "$TMP_DIR/definition-after.json")" "$identity" || return 1
      current=$(adapter docker-local "$identity" "$name" "$STATE_FILE") || return 1
      # Require installed digest exactly equal to the approved observed candidate.
      [[ $(jq -r .local <<<"$current") == "$expected" ]] || return 1
      [[ $(jq -r .id "$TMP_DIR/definition-after.json") != "$(jq -r --arg id "$id" '.jobs[$id].oldId' "$STATE_FILE")" ]] || return 1
      jq -e --slurpfile old "$(jq -r --arg id "$id" '.jobs[$id].recoveryPath' "$STATE_FILE")/definition-before.json" '.running==true and .definition==$old[0].definition and .templateHash==$old[0].templateHash' "$TMP_DIR/definition-after.json" >/dev/null || return 1
      if readiness "$name" --readiness;then return 0;else VERIFY_REASON=readiness;return 1;fi
    else
      adapter plugin-check "$name" >"$TMP_DIR/plugin-after.json" || return 1
      jq -e '.busy==false' "$TMP_DIR/plugin-after.json" >/dev/null || return 1
      enforce_single_installer && plugin_service_guard "$name" after || return 1
      adapter inventory >"$TMP_DIR/recheck-inventory.json" || return 1
      identity=$(jq -r --arg id "$id" '.jobs[$id].identity' "$STATE_FILE")
      jq -e --arg name "$name" --arg version "$expected" --arg identity "$identity" --arg hash "$(jq -r --arg id "$id" '.jobs[$id].candidateHash' "$STATE_FILE")" '.complete==true and .plugins[$name].installed.version==$version and .plugins[$name].installed.url==$identity and .plugins[$name].installed.sha256==$hash' "$TMP_DIR/recheck-inventory.json" >/dev/null
    fi
}

recover_preparation() {
    local id
    while read -r id;do
      cleanup_unissued_set "$id" || true
      job_update "$id" '.jobs[$id].status="DEFERRED" | .jobs[$id].reason="Interrupted preparation reconciled; no native installer was dispatched" | .jobs[$id].retryAt=($now+300)' --argjson now "$(date +%s)" || return 1
      event normal 'Interrupted preparation reconciled' "$id: preparation reconciled; known owned partial files cleaned where safe and unexpected entries preserved; no native installer had been dispatched and the application was not changed. Normal backoff and safety checks remain in force." "preparation-recovered:$id" || return 1
    done < <(jq -r '.jobs|to_entries[]|select(.value.status=="PREPARING" and (.value.dispatchedAt // 0)==0)|.key' "$STATE_FILE")
}

defer_prepared() {
    job_update "$1" '.jobs[$id].status="DEFERRED" | .jobs[$id].reason=$reason | .jobs[$id].retryAt=$retry' --argjson retry "$(( $(date +%s)+300 ))" --arg reason "$2" || return 1
    cleanup_unissued_set "$1" || true
}

release_pre_dispatch() {
    # Called only while the durable journal proves the installer was not called.
    # Never remove another producer lease or any uncertain installation guard.
    if [[ -n "$LEASE_FILE" && -f "$LEASE_FILE" && ! -L "$LEASE_FILE" ]];then
      if jq -e --arg run "$RUN_ID" '.owner=="system_update_coordinator" and .runId==$run' "$LEASE_FILE" >/dev/null 2>&1;then rm -f -- "$LEASE_FILE";fi
    fi
    LEASE_FILE=''
    [[ -z "${MAINT_FD:-}" ]] || exec {MAINT_FD}>&-
    MAINT_FD=''
    [[ "$REQUEST_KEEP" == true ]] || clear_update_request || true
    CURRENT_REQUEST='';REQUEST_KEEP=false
    release_operation_locks
}

reconcile_jobs() {
    local id name count
    while read -r id;do
      within_budget 60 || return 1
      name=$(jq -r --arg id "$id" '.jobs[$id].name' "$STATE_FILE")
      if jq -e --arg id "$id" '.jobs[$id].item as $item | .retired[$item]!=null' "$STATE_FILE" >/dev/null;then
        job_update "$id" '.jobs[$id].status="RETIRED" | .jobs[$id].closedAt=$now' --argjson now "$(date +%s)" || return 1
        event normal 'Removed application retired' "$name: removed on two complete inventory observations; update follow-up retired without claiming successful recovery or recreating the application." "retired:$id" || return 1
        continue
      fi
      if job_verified "$id";then
        clear_update_request "$APP_UPDATE_REQUEST_DIR/$name.json" || return 1
        if native_installer_idle;then job_update "$id" '.jobs[$id].installerFinishedVerified=true' || return 1;fi
        count=$(jq -r --arg id "$id" '.jobs[$id].verifiedScans // 0' "$STATE_FILE");count=$((count+1))
        job_update "$id" '.jobs[$id].verifiedScans=$count' --argjson count "$count" || return 1
        if ((count>=2));then
          local evidence='Expected image digest, retained configuration and application readiness verified on two observations'
          [[ $(jq -r --arg id "$id" '.jobs[$id].kind' "$STATE_FILE") != plugin ]] || evidence='Exact installed plugin version/source/manifest and finished native plugin task verified on two observations; plugin feature behavior was not independently certified'
          job_update "$id" '.jobs[$id].status="COMPLETED" | .jobs[$id].verifiedAt=$now' --argjson now "$(date +%s)" || return 1
          event normal 'Update verified' "$name: $evidence. Recovery evidence retained at $(jq -r --arg id "$id" '.jobs[$id].recoveryPath' "$STATE_FILE"); no automatic restore or database rollback was performed." "verified:$id" || return 1
        fi
      else
        if [[ "${VERIFY_REASON:-}" == readiness ]] && (( $(date +%s)-$(jq -r --arg id "$id" '.jobs[$id].dispatchedAt // 0' "$STATE_FILE")<1200 ));then
          job_update "$id" '.jobs[$id].verifiedScans=0 | .jobs[$id].status="VERIFYING"' || return 1
          log INFO "$name: expected image/config verified; application startup readiness pending within 20-minute grace"
          continue
        fi
        job_update "$id" '.jobs[$id].verifiedScans=0 | .jobs[$id].status="ATTENTION"' || return 1
        event warning 'Update requires review' "$name: native update outcome or application readiness remains unverified. Affected application/dependency updates remain held; independent Docker apps may continue only after installer completion is verified. Existing recovery evidence retained; no blind installer replay or database rollback was attempted. Recovery set: $(jq -r --arg id "$id" '.jobs[$id].recoveryPath' "$STATE_FILE")" "attention:$id" || return 1
      fi
    done < <(jq -r '.jobs|to_entries[]|select(.value.status=="INTENT" or .value.status=="VERIFYING" or .value.status=="ATTENTION")|.key' "$STATE_FILE")
}

cleanup_unissued_set() {
    local id="$1" path="$ROLLBACK_ROOT/$1"
    valid_name "$id" || return 1
    if [[ ! -e "$path" && ! -L "$path" ]];then
      job_update "$id" '.jobs[$id].recoveryPrunedAt=$now' --argjson now "$(date +%s)";return $?
    fi
    [[ -d "$path" && ! -L "$path" && $(cat "$path/.owner" 2>/dev/null) == "$id" ]] || return 1
    [[ -z $(find "$path" -mindepth 1 ! -type f -print -quit) ]] || return 1
    rm -f -- "$path/backup-evidence.json" "$path/definition-before.json" "$path/template.xml" "$path/image.tar.gz" "$path/image.tar.gz.partial" "$path/image.sha256" "$path/installed.plg" "$path/candidate.plg" "$path/native-install.log" "$path/.owner"
    rmdir "$path" && job_update "$id" '.jobs[$id].recoveryPrunedAt=$now' --argjson now "$(date +%s)"
}

clean_recovery_sets() {
    local path id keep=0
    [[ -d "$ROLLBACK_ROOT" && ! -L "$ROLLBACK_ROOT" && $(cat "$ROLLBACK_ROOT/.owner" 2>/dev/null) == system_update_coordinator ]] || return 0
    while read -r id;do
      keep=$((keep+1));((keep>2)) || continue
      path=$(jq -r --arg id "$id" '.jobs[$id].recoveryPath // ""' "$STATE_FILE")
      [[ "$path" == "$ROLLBACK_ROOT/$id" && -d "$path" && ! -L "$path" && -f "$path/.owner" && $(cat "$path/.owner") == "$id" ]] || continue
      [[ -z $(find "$path" -mindepth 1 ! -type f -print -quit) ]] || continue
      # Only a known completed job's small fixed recovery set; no appdata paths.
      rm -f -- "$path/backup-evidence.json" "$path/definition-before.json" "$path/template.xml" "$path/image.tar.gz" "$path/image.sha256" "$path/installed.plg" "$path/candidate.plg" "$path/native-install.log" "$path/.owner"
      rmdir "$path" || continue
      job_update "$id" '.jobs[$id].recoveryPrunedAt=$now' --argjson now "$(date +%s)" || return 1
    done < <(jq -r '.jobs|to_entries|sort_by(-(.value.verifiedAt // .value.closedAt // 0))|.[]|select(.value.status=="COMPLETED" or .value.status=="RETIRED" or .value.status=="CLOSED_BY_OPERATOR")|.key' "$STATE_FILE")
}

# Independent Docker/plugin budgets; an exhausted Docker budget must not
# prevent eligible plugins from using their own allowance, or vice versa.
quota_available() {
    local kind="$1" count limit
    case "$kind" in docker) limit=$(jq -r '.limits.dailyDocker // .limits.dailyTotal // 6' "$POLICY_FILE");;plugin) limit=$(jq -r '.limits.dailyPlugins // 2' "$POLICY_FILE");;*) return 1;;esac
    count=$(jq --arg kind "$kind" --argjson cutoff "$(( $(date +%s)-86400 ))" '[.jobs[]|select(.kind==$kind and (.dispatchedAt // 0)>=$cutoff)]|length' "$STATE_FILE") || return 1
    ((count<limit))
}

install_one() {
    local key kind name identity candidate approved now count job_id old_id='' old_image='' recovery_path native_rc=0 post_guard_failed=false fresh
    [[ $(jq -r .enabled "$POLICY_FILE") == true ]] && window_open && within_budget 630 || return 0
    # Uncertain/running installers remain global; completed Docker installers
    # hold only the affected dependency group while reconciliation continues.
    now=$(date +%s)
    count=$(jq --argjson cutoff "$((now-86400))" '[.jobs[]|select((.dispatchedAt // 0)>=$cutoff)]|length' "$STATE_FILE")
    ((count<$(jq -r '.limits.dailyTotal // 8' "$POLICY_FILE"))) || return 0
    adapter_compatible || { RESULT=DEFERRED;SUMMARY='Native update adapter unverified on this OS/interface; no automatic install';event warning 'Automatic installation deferred' "$SUMMARY; read-only evidence and existing intents retained. Validate native interfaces before enabling a new OS adapter." adapter-unverified;return 0; }
    while IFS=$'\t' read -r key kind name identity candidate;do
      [[ "$name" != unRAIDServer.plg ]] || continue
      approved=$(jq -r --arg kind "$kind" --arg name "$name" --arg identity "$identity" '(if $kind=="docker" then .docker[$name] else .plugins[$name] end) as $p | ($p.allow==true and $p.identity==$identity)' "$POLICY_FILE")
      [[ "$approved" == true ]] || continue
      pending_update_guard "$kind" "$name" "$identity" || { decision "$key" "$SUMMARY";continue; }
      scheduled_work_guard "$kind" "$name" prepare || { decision "$key" "$SUMMARY";continue; }
      # Failed/rejected digest/version stays quarantined until it changes or an
      # operator explicitly resolves the job; no reinstall loops.
      jq -e --arg key "$key" --arg candidate "$candidate" --argjson cutoff "$((now-6*3600))" --argjson now "$now" 'all(.jobs[];.item!=$key or .candidate!=$candidate or (.status=="DEFERRED" and (.retryAt // (.startedAt+21600))<=$now))' "$STATE_FILE" >/dev/null || continue
      quota_available "$kind" || { decision "$key" "Rolling 24-hour $kind update limit reached";continue; }
      backup_evidence "$kind" || { decision "$key" "${BACKUP_REASON:-Recent verified backup evidence unavailable}";log INFO "$name: DEFERRED; ${BACKUP_REASON:-recent verified backup evidence unavailable}";continue; }
      if [[ "$kind" == docker ]];then
        jq -e --arg name "$name" '.docker[$name].running==true and .docker[$name].managed=="dockerman"' "$TMP_DIR/inventory.json" >/dev/null || { decision "$key" "Container stopped or not managed by DockerMan";continue; }
        # Require readiness before taking down an already unhealthy application.
        readiness "$name" || { decision "$key" "$(jq -r '.detail // "Strong application readiness not established"' "$TMP_DIR/readiness.json" 2>/dev/null)";log INFO "$name: DEFERRED; busy or application readiness unverified";continue; }
        adapter docker-check "$identity" "$name" "$STATE_FILE" >"$TMP_DIR/fresh.json" || { decision "$key" "Fresh registry/container digest could not be verified";continue; }
        [[ $(jq -r .remote "$TMP_DIR/fresh.json") == "$candidate" ]] || { decision "$key" "Registry candidate changed; stability hold restarts on the next check";continue; }
        adapter definition "$name" >"$TMP_DIR/definition-before.json" || { decision "$key" "Current container/template definition unavailable";continue; }
        [[ $(jq -r .templateHash "$TMP_DIR/definition-before.json") == "$(jq -r --arg name "$name" '.docker[$name].templateHash' "$TMP_DIR/inventory.json")" ]] || { decision "$key" "Template changed during preflight; current settings preserved";continue; }
        same_repository "$(jq -r .runtimeImage "$TMP_DIR/definition-before.json")" "$identity" || { decision "$key" "Running image channel differs from saved template";log WARNING "$name: DEFERRED; running image channel differs from saved template; no update started";continue; }
        old_id=$(jq -r .id "$TMP_DIR/definition-before.json");old_image=$(jq -r .imageId "$TMP_DIR/definition-before.json")
      else
        bounded 120 "$NATIVE_PLUGIN" check "$name" >"$TMP_DIR/plugin-final-check.log" 2>&1 && adapter plugin-check "$name" >"$TMP_DIR/fresh.json" || { decision "$key" "Fresh plugin evidence unavailable";continue; }
        jq -e --arg version "$candidate" --arg identity "$identity" '.available==true and .compatible==true and .busy==false and .candidate.version==$version and .candidate.url==$identity' "$TMP_DIR/fresh.json" >/dev/null || { decision "$key" "Plugin candidate incompatible, busy, changed or no longer available";continue; }
        [[ $(jq -r .candidate.sha256 "$TMP_DIR/fresh.json") == "$(jq -r --arg key "$key" '.items[$key].evidence.candidate.sha256' "$STATE_FILE")" ]] || { decision "$key" "Plugin manifest changed; waiting for fresh stable candidate evidence";continue; }
        bounded 30 "$NATIVE_PLUGIN" validate "/tmp/plugins/$name" >"$TMP_DIR/plugin-validate.log" 2>&1 || { decision "$key" "Native plugin package/hash validation failed";continue; }
      fi
      if [[ "$kind" == plugin ]];then plugin_service_guard "$name" || { decision "$key" "Host network or Plex/GPU dependency is active/unverified; plugin update deferred";continue; };fi
      if ! maintenance_guard "$kind" "$name" "$identity";then
        decision "$key" "${SUMMARY:-Maintenance guard unavailable}";log INFO "${SUMMARY:-Maintenance conditions unavailable; installation deferred}"
        release_operation_locks
        [[ "$GUARD_GLOBAL" != true ]] || return 0
        continue
      fi
      # The producer finished while we waited; prove current readiness again.
      if [[ "$kind" == docker ]] && ! readiness "$name";then
        decision "$key" "$(jq -r '.detail // "Application busy after handoff; update deferred"' "$TMP_DIR/readiness.json" 2>/dev/null)"
        clear_update_request;CURRENT_REQUEST='';REQUEST_KEEP=false;release_operation_locks;continue
      fi
      decision "$key" "Recovery preparation started"
      PHASE=install;job_id="$(date +%Y%m%d_%H%M%S)_${kind}_${name}_$$"
      recovery_path="$ROLLBACK_ROOT/$job_id"
      mutate --arg id "$job_id" --arg item "$key" --arg kind "$kind" --arg name "$name" --arg identity "$identity" --arg candidate "$candidate" \
        --arg previous "$(jq -r '.local // .installed.version // "unknown"' "$TMP_DIR/fresh.json")" --arg oldId "$old_id" --arg oldImage "$old_image" --arg path "$recovery_path" --argjson now "$now" \
        '.jobs[$id]={previous:$previous,item:$item,kind:$kind,name:$name,identity:$identity,candidate:$candidate,status:"PREPARING",startedAt:$now,oldId:$oldId,oldImage:$oldImage,recoveryPath:$path,verifiedScans:0}' || return 1
      if ! prepare_recovery_set "$kind" "$name" "$job_id" "$old_image";then
        defer_prepared "$job_id" "Recovery evidence preparation failed; native installer not called: ${RECOVERY_REASON:-archive preparation unavailable}" || return 1
        event warning 'Update deferred before installation' "$name: recovery evidence could not be prepared; native installer was not called and the current application was retained. Reason: ${RECOVERY_REASON:-Recovery preparation did not complete}." "prepare:$key:$candidate" || return 1
        release_pre_dispatch;continue
      fi
      if [[ "$kind" == docker ]];then start_container_lease "$name" "$old_id" || { defer_prepared "$job_id" 'Existing maintenance lease; native installer not called' || return 1;release_pre_dispatch;continue; };fi
      # Recheck backup/interface/window and unchanged installed identity at the
      # final boundary. A late hold is known non-dispatch, not an uncertain POST.
      if ! window_open || ! within_budget 480 || ! adapter_compatible;then defer_prepared "$job_id" 'Final window/runtime/interface guard deferred before native installer';return 0;fi
      if [[ "$kind" == docker ]];then
        fresh=$(docker_cmd inspect "$name" --format '{{.Id}}') || return 1
        readiness "$name" || { decision "$key" "$(jq -r '.detail // "Application busy or readiness unverified"' "$TMP_DIR/readiness.json" 2>/dev/null)";defer_prepared "$job_id" 'Final application readiness/busy guard deferred before dispatch' || return 1;release_pre_dispatch;continue; }
        [[ "$fresh" == "$old_id" ]] || { defer_prepared "$job_id" 'Installed identity changed; native installer not called' || return 1;release_pre_dispatch;continue; }
      fi
      if ! scheduled_work_guard "$kind" "$name" dispatch;then
        decision "$key" "$SUMMARY";defer_prepared "$job_id" "$SUMMARY" || return 1;release_pre_dispatch;continue
      fi
      job_update "$job_id" '.jobs[$id].status="INTENT" | .jobs[$id].dispatchedAt=$now | .jobs[$id].candidateHash=$hash | .items[.jobs[$id].item].missedUpdateWindows=0 | .items[.jobs[$id].item].updateWaitWindows={}' --arg hash "$( [[ "$kind" != plugin ]] || jq -r .candidate.sha256 "$TMP_DIR/fresh.json" )" --argjson now "$(date +%s)" || return 1
      INSTALL_ACTIVE=true
      if [[ "$kind" == docker ]];then bounded 420 "$NATIVE_DOCKER_UPDATE" "$name" >"$TMP_DIR/native-install.log" 2>&1 || native_rc=$?
      else bounded 300 "$NATIVE_PLUGIN" update "$name" >"$TMP_DIR/native-install.log" 2>&1 || native_rc=$?;fi
      INSTALL_ACTIVE=false
      local finished_verified=false
      if ((native_rc!=124 && native_rc!=137 && native_rc!=143)) && native_installer_idle;then finished_verified=true;fi
      job_update "$job_id" '.jobs[$id].nativeFinishedAt=$now | .jobs[$id].installerFinishedVerified=$finished' --argjson now "$(date +%s)" --argjson finished "$finished_verified" || return 1
      if [[ "$kind" == plugin ]];then
        enforce_single_installer || post_guard_failed=true
      fi
      tail -c 16384 "$TMP_DIR/native-install.log" >"$recovery_path/native-install.log" || true
      # Native helpers can return zero despite a failed recreation. Read-back,
      # not the exit code or an HTML completion banner, establishes completion.
      job_update "$job_id" '.jobs[$id].status="VERIFYING" | .jobs[$id].nativeExit=$exit | .jobs[$id].postInstallGuardFailed=$guard' --argjson guard "$post_guard_failed" --argjson exit "$native_rc" || return 1
      if job_verified "$job_id";then
        job_update "$job_id" '.jobs[$id].verifiedScans=1' || return 1
        local first_evidence='expected image digest, retained settings and initial readiness verified'
        [[ "$kind" != plugin ]] || first_evidence='expected plugin version/source/manifest and completed native task verified'
        event normal 'Update installed; follow-up verification pending' "$name: native installer completed; $first_evidence. A second scheduled observation will confirm stability. Recovery set: $recovery_path. No image channel or application settings were changed by this coordinator." "installed:$job_id" || return 1
      elif [[ "${VERIFY_REASON:-}" == readiness ]];then
        REQUEST_KEEP=true
        if [[ -n "$CURRENT_REQUEST" && -f "$CURRENT_REQUEST" ]];then
          jq --argjson expires "$(( $(date +%s)+1200 ))" '.expires=$expires | .phase="startup_grace"' "$CURRENT_REQUEST" >"$TMP_DIR/request-startup" && mv "$TMP_DIR/request-startup" "$CURRENT_REQUEST" || return 1
        fi
        event normal 'Update installed; startup verification pending' "$name: expected image digest and retained configuration verified; application readiness is still pending within the 20-minute startup grace. Affected dependency installations and watchdog restarts remain held while scheduled reconciliation checks readiness; independent Docker apps may continue only after installer completion is verified. Recovery set: $recovery_path." "startup:$job_id" || return 1
      else
        RESULT=ATTENTION
        job_update "$job_id" '.jobs[$id].status="ATTENTION"' || return 1
        event alert 'Update outcome requires attention' "$name: native installer exit=$native_rc; expected version/digest, configuration or readiness could not be confirmed. Affected application/dependency updates are held; uncertain installer completion or plugin outcomes still hold all updates. Previous-image/configuration or plugin-definition recovery evidence and the backup reference are retained at $recovery_path. No blind replay or database rollback was attempted." "attention:$job_id" || return 1
      fi
      return 0
    done < <(jq -r --slurpfile policy "$POLICY_FILE" --argjson now "$now" '
      .items|to_entries|sort_by([-(.value.missedUpdateWindows // 0),(.value.candidateSeenAt // 0)])|.[]|.value as $i|
      (if $i.kind=="docker" then $policy[0].docker[$i.name] else $policy[0].plugins[$i.name] end) as $p|
      (($p.candidateHoldHours // $policy[0].limits.candidateHoldHours // 24)*3600) as $hold|
      select($i.missingScans==0 and $i.available==true and $i.checkStatus=="VERIFIED" and $i.candidateSeenAt<=$now-$hold)|
      [.key,$i.kind,$i.name,$i.identity,$i.candidate]|@tsv' "$STATE_FILE")
}

# One explicit decision per candidate; daily reporting retains the actual guard.
decision() {
    mutate --arg key "$1" --arg reason "${2:-Update deferred by safety guard}" --argjson now "$(date +%s)" '
      .items[$key].decision={at:$now,candidate:.items[$key].candidate,reason:($reason[0:1200])}'
}

# CA may regenerate its cron files during a plugin upgrade. Keep a single
# automatic installer and verify User Scripts did not lose the coordinator job.
enforce_single_installer() {
    local ca="${CA_SETTINGS_ROOT:-/boot/config/plugins/ca.update.applications}" root="${USER_SCRIPTS_ROOT:-/boot/config/plugins/user.scripts}" file temp cron changed=false launcher="${USER_SCRIPTS_LAUNCHER:-/usr/local/emhttp/plugins/user.scripts/startCustom.php}"
    if [[ -d "$ca" ]];then
      for file in DockerUpdateSettings.json AutoUpdateSettings.json;do
        if [[ ! -e "$ca/$file" && ! -e /var/log/plugins/ca.update.applications.plg ]];then continue;fi
        [[ -f "$ca/$file" && ! -L "$ca/$file" ]] && jq -e 'type=="object" and (.cron|type)=="object"' "$ca/$file" >/dev/null || return 1
        if [[ "$file" == DockerUpdateSettings.json ]];then
          jq -e '.cron.dockerCronFrequency=="disabled" and .global.dockerUpdateAll=="no"' "$ca/$file" >/dev/null && continue
        else jq -e '.cron.pluginCronFrequency=="disabled" and .Global=="false"' "$ca/$file" >/dev/null && continue;fi
        temp=$(mktemp "$ca/.coordinator.XXXXXX") || return 1
        if [[ "$file" == DockerUpdateSettings.json ]];then
          jq '.cron.dockerCronFrequency="disabled" | .global.dockerUpdateAll="no"' "$ca/$file" >"$temp" || return 1
        else jq '.cron.pluginCronFrequency="disabled" | .Global="false"' "$ca/$file" >"$temp" || return 1;fi
        if cmp -s "$temp" "$ca/$file";then rm -f "$temp";else mv "$temp" "$ca/$file" || return 1;changed=true;fi
      done
      for file in docker_update.cron plugin_update.cron;do
        [[ ! -L "$ca/$file" ]] || return 1
        if [[ ! -f "$ca/$file" ]] || grep -Eq '^[[:space:]]*[^#[:space:]]' "$ca/$file";then printf '# Automatic installations delegated to system_update_coordinator\n' >"$ca/$file" || return 1;changed=true;fi
      done
    fi
    [[ -r "$launcher" && ! -L "$launcher" ]] || return 1
    local catalogue active_path
    catalogue=$(usr_scripts_catalog "$root/schedule.json" "$root/scripts") || return 1
    active_path=$(jq -er '[.jobs[]|select((.role=="system_update_coordinator" or .name=="system_update_coordinator") and .present and .enabled and .frequency=="custom")][0].path' <<<"$catalogue") || return 1
    bounded 8 php -l "$launcher" >/dev/null 2>&1 || return 1

    [[ "$changed" != true ]] || update_cron || return 1
    cron=$(bounded 8 crontab -c /etc/cron.d -l) || return 1
    if ! grep -Fq "$active_path" <<<"$cron";then update_cron || return 1;cron=$(bounded 8 crontab -c /etc/cron.d -l) || return 1;grep -Fq "$active_path" <<<"$cron" || return 1;fi
    ! grep -Eq 'ca.update.applications/.+(updateDocker|updatePlugins)' <<<"$cron"
}

next_update_attempt() { calendar_eval next "${1:-$(date +%s)}" | jq -er .at; }

add_hold() {
    jq -nc --arg code "$1" --arg reason "$2" '{code:$code,reason:$reason}' >>"$TMP_DIR/holds.ndjson"
}
track_update_windows() {
    # Count only windows where this coordinator actually observed an approved,
    # mature candidate. No retrospective guesses after downtime or installation.
    local now="${1:-$(date +%s)}" current
    current=$(calendar_eval window "$now") || return 1
    mutate --argjson now "$now" --argjson current "$current" --slurpfile policy "$POLICY_FILE" '
      .jobs as $jobs | $policy[0] as $p |
      .items |= with_entries(.key as $key | .value |= (
        reduce ((.updateWaitWindows // {})|to_entries[]|select(.value.status=="OPEN" and .value.end<=$now)) as $w (. ;
          if $p.enabled!=true then .updateWaitWindows[$w.key].status="SKIPPED"
          elif any($jobs[];.item==$key and (.dispatchedAt // 0)>=$w.value.start and (.dispatchedAt // 0)<$w.value.end) then
            .updateWaitWindows[$w.key].status="UPDATED" | .missedUpdateWindows=0
          else .updateWaitWindows[$w.key].status="MISSED" | .missedUpdateWindows=((.missedUpdateWindows // 0)+1) end) |
        . as $i | (if .kind=="docker" then $p.docker[.name] else $p.plugins[.name] end) as $a |
        if .available!=true then .missedUpdateWindows=0 | .updateWaitWindows={} else . end |
        if $p.enabled==true and $current.current!=null and .name!="unRAIDServer.plg" and .available==true and .checkStatus=="VERIFIED" and (.missingScans // 0)==0 and
           $a.allow==true and $a.identity==.identity and (.candidateSeenAt // $now)+(($a.candidateHoldHours // $p.limits.candidateHoldHours // 24)*3600)<=$now and
           (any($jobs[];.item==$key and .candidate==$i.candidate and .status!="DEFERRED")|not) then
          .updateWaitWindows[$current.current.id]=((.updateWaitWindows[$current.current.id] // $current.current)+{status:"OPEN"})
        else . end |
        .updateWaitWindows=((.updateWaitWindows // {})|to_entries|sort_by(.value.start)|.[-16:]|from_entries)
      ))' || return 1
}
warn_starved_updates() {
    local row name count detail day
    [[ $(jq -r .enabled "$POLICY_FILE") == true ]] || return 0
    day=$(TZ=Asia/Singapore date +%F)
    while IFS= read -r row;do
      name=$(jq -r .name <<<"$row");count=$(jq -r .missedUpdateWindows <<<"$row")
      detail=$(jq -r '[.holds.reasons[]?.reason]|join("; ")' <<<"$row")
      event normal 'Repeated update deferral; queue priority increased' "[WARNING] $name missed $count observed eligible update windows. Action: raised queue priority; all activity, backup and schedule guards remain enforced. Current observations: ${detail:-Final checks pending}. Delivery remains in the single grouped daily report; no app was stopped to force an update." "starved:$name:$day" || return 1
    done < <(jq -c --slurpfile policy "$POLICY_FILE" '.items[]|. as $i|select(.available==true and (.missingScans // 0)==0 and (.missedUpdateWindows // 0)>=2)| (if .kind=="docker" then $policy[0].docker[.name] else $policy[0].plugins[.name] end) as $a|select($a.allow==true and $a.identity==$i.identity)' "$STATE_FILE")
}

collect_update_holds() {
    # Read-only assessment after installation work, so reporting cannot consume
    # its preparation budget. Cache expensive readiness for at most 30 minutes.
    local key kind name identity row now age hours retry candidate family lock mode cached checks=0 array_reason='' backup_docker='' backup_plugin=''
    local interface_bad=false saved_summary="$SUMMARY"
    now=$(date +%s)
    adapter_compatible || interface_bad=true
    array_update_guard || array_reason="$SUMMARY"
    backup_evidence docker || backup_docker="${BACKUP_REASON:-Verified appdata backup unavailable}"
    backup_evidence plugin || backup_plugin="${BACKUP_REASON:-Verified boot backup unavailable}"
    while IFS=$'\t' read -r key kind name identity candidate;do
      within_budget 30 || break
      : >"$TMP_DIR/holds.ndjson"
      row=$(jq -c --arg key "$key" '.items[$key]' "$STATE_FILE")
      hours=$(jq -r --arg kind "$kind" --arg name "$name" '(if $kind=="docker" then .docker[$name] else .plugins[$name] end).candidateHoldHours // .limits.candidateHoldHours // 24' "$POLICY_FILE")
      age=$(( $(jq -r '.candidateSeenAt // 0' <<<"$row")+hours*3600 ));retry=$((now+1));((age<=retry)) || retry=$age
      [[ "$name" != unRAIDServer.plg ]] || add_hold manual-os 'Unraid OS updates remain manual'
      [[ $(jq -r .enabled "$POLICY_FILE") == true ]] || add_hold paused 'Automatic updates paused'
      window_open || add_hold window 'Outside the approved installation window'
      ((age<=now)) || add_hold candidate-age "Candidate observation hold: $hours hour(s); new digests restart this timer"
      jq -e --arg kind "$kind" --arg name "$name" --arg identity "$identity" '(if $kind=="docker" then .docker[$name] else .plugins[$name] end)|.allow==true and .identity==$identity' "$POLICY_FILE" >/dev/null || add_hold approval 'Installed repository/source identity is not approved'
      [[ $(jq -r .checkStatus <<<"$row") == VERIFIED ]] || add_hold registry 'Fresh registry/native evidence unavailable'
      [[ $(jq -r '.missingScans // 0' <<<"$row") == 0 ]] || add_hold presence 'Presence needs complete inventory confirmation'
      [[ "$interface_bad" != true ]] || add_hold native-interface 'Native Unraid updater interface/OS compatibility could not be verified'
      [[ -z "$array_reason" ]] || add_hold array "$array_reason"
      native_installer_idle || add_hold installer 'Native installer/package operation still active; all updates wait'
      pending_update_guard "$kind" "$name" "$identity" || add_hold pending "$SUMMARY"
      if window_open;then
        if within_budget 75;then scheduled_work_guard "$kind" "$name" prepare || add_hold scheduled-work "$SUMMARY";else add_hold schedule-pending 'Finish-by schedule evidence requires refresh before installation';fi
      fi
      # Previous image archive limits are independent of application activity.
      if [[ "$kind" == docker ]];then
        local image size free maximum
        image=$(jq -r --arg name "$name" '.inventory.docker[$name].imageId // ""' "$STATE_FILE")
        if [[ -n "$image" ]];then
          size=$(docker_cmd image inspect "$image" --format '{{.Size}}' 2>/dev/null) || size=''
          maximum=$(jq -r '.limits.imageMaxBytes // 4294967296' "$POLICY_FILE")
          if [[ "$size" =~ ^[0-9]+$ ]];then
            ((size<=maximum)) || add_hold image-size "Previous image is larger than the configured $maximum byte recovery limit"
            free=$(df -PB1 "$VAULT_MOUNT"|awk 'NR==2{print $4}')
            [[ "$free" =~ ^[0-9]+$ ]] && ((free>=size+10737418240)) || add_hold recovery-space 'Vault space must cover the previous image plus 10 GiB reserve'
          else add_hold image-evidence 'Previous image size could not be verified for recovery preparation';fi
        fi
      fi
      if [[ "$kind" == docker ]];then
        [[ -z "$backup_docker" ]] || add_hold backup "$backup_docker"
        jq -e --arg name "$name" '.inventory.docker[$name].running==true and .inventory.docker[$name].managed=="dockerman"' "$STATE_FILE" >/dev/null || add_hold stopped 'Container stopped or not managed by DockerMan; no automatic start'
      else [[ -z "$backup_plugin" ]] || add_hold backup "$backup_plugin";fi
      quota_available "$kind" || add_hold quota "Rolling 24-hour $kind installation limit reached"
      local total
      total=$(jq --argjson since "$((now-86400))" '[.jobs[]|select((.dispatchedAt // 0)>=$since)]|length' "$STATE_FILE")
      ((total<$(jq -r '.limits.dailyTotal // 8' "$POLICY_FILE"))) || add_hold total-quota 'Combined rolling 24-hour installation limit reached'
      for lock in /tmp/backup_cache_appdata.lock /tmp/backup_boot_disk.lock;do
        [[ ! -e "$lock" ]] || flock -s -n "$lock" -c true || add_hold backup-active "Protected ${lock##*/} operation active"
      done
      target_coordination "$kind" "$name" "$identity"
      mode=-s;[[ "$COORD_EXCLUSIVE" != true ]] || mode=-x
      if window_open;then
        [[ ! -e "$ARR_BACKUP_GATE" ]] || flock "$mode" -n "$ARR_BACKUP_GATE" -c true || add_hold coordination 'Short application operation active; dispatch waits for its verified completion and retries within the window'
        for lock in "${COORD_LOCKS[@]}";do
          [[ ! -e "$lock" ]] || flock -s -n "$lock" -c true || add_hold producer "Existing ${lock##*/} producer must finish"
        done
      fi
      # Keep same-candidate suppression visible alongside other independent holds.
      jq -e --arg key "$key" --arg c "$candidate" --argjson now "$now" 'any(.jobs[];.item==$key and .candidate==$c and (.status!="DEFERRED" or (.retryAt // (.startedAt+21600))>$now))' "$STATE_FILE" >/dev/null && add_hold journal 'Candidate already handled or unresolved; no blind reinstall'
      cached=$(jq -c '.readinessAssessment // {}' <<<"$row")
      if [[ "$kind" == docker ]] && ((now-$(jq -r '.at // 0' <<<"$cached")>=1800 && checks<4)) && within_budget 75;then
        checks=$((checks+1))
        readiness "$name" || true
        if jq -e '(.ready|type)=="boolean"' "$TMP_DIR/readiness.json" >/dev/null 2>&1;then
          cached=$(jq --argjson at "$now" '{at:$at,ready,detail}' "$TMP_DIR/readiness.json")
          mutate --arg key "$key" --argjson evidence "$cached" '.items[$key].readinessAssessment=$evidence' || return 1
        fi
      fi
      if [[ "$kind" == docker && "$name" =~ ^(sonarr|radarr)$ ]] && jq -e '.inventory.docker.recyclarr.running==true' "$STATE_FILE" >/dev/null;then
        if within_budget 75;then readiness recyclarr || add_hold dependency "$(jq -r '.detail // "Recyclarr activity unavailable"' "$TMP_DIR/readiness.json" 2>/dev/null)";else add_hold dependency-pending 'Recyclarr sync readiness requires refresh before installation';fi
      fi
      if [[ "$kind" == plugin ]];then
        if within_budget 75;then plugin_service_guard "$name" || add_hold plugin-dependency 'Host network/Plex GPU dependency readiness is busy or unverified';else add_hold dependency-pending 'Plugin dependency readiness requires refresh before installation';fi
      fi
      if [[ "$kind" == docker ]];then
        if ((now-$(jq -r '.at // 0' <<<"$cached")>=1800));then add_hold readiness-pending 'Application activity evidence needs refresh before installation'
        elif [[ $(jq -r '.ready // false' <<<"$cached") != true ]];then add_hold application "$(jq -r '.detail // "Application activity/readiness unavailable"' <<<"$cached"); evidence checked $(TZ=Asia/Singapore date -d "@$(jq -r .at <<<"$cached")" '+%Y-%m-%d %H:%M SGT')";fi
      fi
      retry=$(next_update_attempt "$retry") || return 1
      jq -s 'unique_by(.code,.reason)' "$TMP_DIR/holds.ndjson" >"$TMP_DIR/holds.json" || return 1
      mutate --arg key "$key" --arg c "$candidate" --argjson now "$now" --argjson retry "$retry" --slurpfile holds "$TMP_DIR/holds.json" '.items[$key].holds={at:$now,candidate:$c,nextAttemptAt:$retry,reasons:$holds[0]} | .items[$key].candidateStatus="CANDIDATE" | .items[$key].scheduling={state:(if any($holds[0][];.code!="window") then "WAITING_CHECKS" elif any($holds[0][];.code=="window") then "WAITING_WINDOW" else "READY_FOR_SLOT" end),nextAttemptAt:$retry,assessedAt:$now}' || return 1
    done < <(jq -r '.items|to_entries|sort_by(.value.readinessAssessment.at // 0)|.[]|select(.value.available==true)|[.key,.value.kind,.value.name,.value.identity,.value.candidate]|@tsv' "$STATE_FILE")
    SUMMARY="$saved_summary"
}

render_update_report() {
    local now day start
    now=$(date +%s);day=$(TZ=Asia/Singapore date +%F);start=$(TZ=Asia/Singapore date -d "$day 00:00:00" +%s)
    TZ=Asia/Singapore jq -nr --slurpfile state "$STATE_FILE" --slurpfile policy "$POLICY_FILE" --argjson now "$now" --argjson start "$start" --arg day "$day" '
      $state[0] as $s | $policy[0] as $p |
      def short: if startswith("sha256:") then .[0:19] else . end;
      def approval($i): (if $i.kind=="docker" then $p.docker[$i.name] else $p.plugins[$i.name] end) as $a | $a.allow==true and $a.identity==$i.identity;
      def hold($i): (if $i.kind=="docker" then $p.docker[$i.name] else $p.plugins[$i.name] end).candidateHoldHours // $p.limits.candidateHoldHours // 24;
      def latest($key): [$s.jobs[]|select(.item==$key)]|sort_by(.dispatchedAt // .startedAt // 0)|last;
      def reason_legacy($key;$i): latest($key) as $j |
        if $i.name=="unRAIDServer.plg" then "OS update is manual; no OS installation or reboot"
        elif ($i.missingScans // 0)>0 then "Presence unconfirmed; waiting for a second complete inventory"
        elif $j!=null and ($j.status|IN("INTENT","VERIFYING","ATTENTION")) then "Update outcome: "+$j.status+"; "+($j.reason // "scheduled verification/reconciliation pending")
        elif $i.checkStatus=="PINNED_OR_UNMANAGED" then "Digest-pinned or unmanaged image; no mutable update channel is available"
        elif $i.checkStatus!="VERIFIED" then "Update status unverified: "+($i.checkStatus // "not checked yet")+"; installed app left unchanged"
        elif $i.available!=true then "Up to date at last successful check"
        elif (approval($i)|not) then "Identity is not approved; reporting only"
        elif $p.enabled!=true then "Automatic installation paused"
        elif $j!=null and $j.candidate==$i.candidate and ($j.status|IN("CLOSED_BY_OPERATOR","RETIRED","COMPLETED")) then "This candidate already handled; no automatic reinstall"
        elif $j!=null and $j.candidate==$i.candidate and $j.status=="DEFERRED" and ($j.retryAt // ($j.startedAt+21600))>$now then "Retry backoff after: "+($j.reason // "pre-installation deferral")
        elif $now-($i.candidateSeenAt // $now)<(hold($i)*3600) then "Candidate stability hold: "+((($now-($i.candidateSeenAt // $now))/3600|floor)|tostring)+"/"+(hold($i)|tostring)+"h"
        elif ($i.decision.at // 0)>=$start and $i.decision.candidate==$i.candidate then $i.decision.reason
        elif any($s.jobs[];.status=="INTENT" or .status=="VERIFYING" or .status=="ATTENTION") then "Earlier update needs reconciliation; dependency scope is checked before dispatch"
        elif ([$s.jobs[]|select((.dispatchedAt // 0)>$now-86400)]|length)>=($p.limits.dailyTotal // 8) then "Rolling 24-hour update limit reached"
        elif $i.kind=="docker" and ([$s.jobs[]|select(.kind=="docker" and (.dispatchedAt // 0)>$now-86400)]|length)>=($p.limits.dailyDocker // $p.limits.dailyTotal // 6) then "Rolling 24-hour Docker update limit reached"
        elif $i.kind=="plugin" and ([$s.jobs[]|select(.kind=="plugin" and (.dispatchedAt // 0)>$now-86400)]|length)>=($p.limits.dailyPlugins // 2) then "Rolling 24-hour plugin limit reached"
        elif $i.kind=="docker" and $s.inventory.docker[$i.name].running!=true then "Installed container is stopped; left stopped"
        else "Queued for the next eligible maintenance slot; one installer per run" end;
      def reason($key;$i): latest($key) as $j |
        if $i.holds!=null and $i.holds.candidate==$i.candidate then
          (if ($i.missedUpdateWindows // 0)>=2 then "[WARNING] "+($i.missedUpdateWindows|tostring)+" eligible windows missed; priority increased. " else "" end)+(if ($i.holds.reasons|length)>0 then ($i.holds.reasons|map(.reason)|join("; ")) else "No observed hold; awaiting serialized installation slot and final checks" end)+
          ". Next reassessment: "+($i.holds.nextAttemptAt|strflocaltime("%Y-%m-%d %H:%M SGT"))+"; assessment: "+($i.holds.at|strflocaltime("%Y-%m-%d %H:%M SGT"))
        else reason_legacy($key;$i) end;
      "Daily system update report - "+$day+" (Singapore)",
      "Policy: "+(if $p.enabled then "automatic" else "paused" end)+"; windows "+(($p.windows // [$p.window])|map(.start+"-"+.end)|join(", "))+"; daily limits "+(($p.limits.dailyDocker // $p.limits.dailyTotal // 6)|tostring)+" Docker / "+(($p.limits.dailyPlugins // 2)|tostring)+" plugin(s).",
      "", "UPDATED AND VERIFIED:",
      ([$s.jobs[]|select(.status=="COMPLETED" and (.verifiedAt // 0)>=$start)] as $done |
        if ($done|length)==0 then "- None verified today."
        else $done[]|"- "+.kind+"/"+.name+": "+((.previous // "unknown")|short)+" -> "+(.candidate|short)+"; native result and follow-up verification passed. Recovery: "+(.recoveryPath // "not recorded") end),
      "", "INSTALLED / OUTCOME PENDING:",
      ([$s.jobs[]|select(.status|IN("INTENT","VERIFYING","ATTENTION"))] as $pending |
        if ($pending|length)==0 then "- None."
        else $pending[]|"- "+.kind+"/"+.name+": "+.status+"; candidate "+(.candidate|short)+". "+(.reason // "Digest/version, retained configuration and readiness require confirmation")+". Recovery: "+(.recoveryPath // "not recorded") end),
      "", "UPDATE CANDIDATES / WAITING OR UNVERIFIED:",
      ($s.items|to_entries|sort_by(.key)|.[]|
        .key as $key|.value as $i|
        if ($i.checkStatus=="VERIFIED" and $i.available!=true and ($i.missingScans // 0)==0) then empty
        elif any($s.jobs[];.item==$key and ((.status|IN("INTENT","VERIFYING","ATTENTION")) or (.status=="COMPLETED" and .candidate==$i.candidate and (.verifiedAt // 0)>=$start))) then empty
        else "- "+$i.kind+"/"+$i.name+": "+reason($key;$i)+". Update evidence checked: "+(if ($i.checkedAt // 0)>0 then ($i.checkedAt|strflocaltime("%Y-%m-%d %H:%M SGT")) else "not yet performed" end)+(if ($i.decision.at // 0)>0 then "; installation decision: "+($i.decision.at|strflocaltime("%Y-%m-%d %H:%M SGT")) else "" end) end),
      "", "Removed items retire after two complete inventories. No OS installation, reboot or automatic database rollback is performed."'
}

daily_update_report() {
    local day clock report
    day=$(TZ=Asia/Singapore date +%F);clock=$(TZ=Asia/Singapore date +%H:%M)
    [[ "$clock" > "$(jq -r '.reportTime // "15:45"' "$POLICY_FILE")" || "$clock" == "$(jq -r '.reportTime // "15:45"' "$POLICY_FILE")" ]] || return 0
    [[ $(jq -r '.lastDailyReportDay // ""' "$STATE_FILE") != "$day" ]] || return 0
    local start content_rc=0
    start=$(TZ=Asia/Singapore date -d "$day 00:00:00" +%s)
    jq -e --argjson start "$start" '
      any(.items[];.available==true or .checkStatus!="VERIFIED" or (.missingScans // 0)>0) or
      any(.jobs[];(.status|IN("INTENT","VERIFYING","ATTENTION")) or (.status=="COMPLETED" and (.verifiedAt // 0)>=$start)) or
      (.outbox|length)>0' "$STATE_FILE" >/dev/null || content_rc=$?
    ((content_rc<=1)) || return 1
    if ((content_rc==1));then
      mutate --arg day "$day" '.lastDailyReportDay=$day' || return 1
      log INFO 'No available updates, update outcomes or unverified checks to report; routine notification suppressed'
      return 0
    fi
    report=$(render_update_report) || return 1
    event normal 'Daily update summary' "$report" "daily-update-report:$day" && mutate --arg day "$day" '.lastDailyReportDay=$day | .normalDeliveryIds=[.outbox[]|select(.importance=="normal")|.id]'
}

flush_notifications() {
    local body count importance rc=0 urgent=false total
    jq -e 'any(.outbox[];.importance!="normal")' "$STATE_FILE" >/dev/null && urgent=true
    jq -e '.outbox|length>0' "$STATE_FILE" >/dev/null || return 0
    # Whole bounded events only. Any remainder is retained for a later run.
    jq --argjson urgent "$urgent" '
      (.normalDeliveryIds // []) as $batch |
      reduce ((.outbox|sort_by(if .importance=="alert" then 0 elif .importance=="warning" then 1 else 2 end))[]|. as $event|select($urgent or ($batch|index($event.id))!=null)) as $e ({bytes:0,items:[]};
        (($e.subject+"\nObserved: "+($e.at|tostring)+"\n"+$e.detail+"\n")|utf8bytelength) as $n |
        if .bytes+$n+300<19000 then .bytes+=($n+300)|.items+=[$e] else . end)|.items' "$STATE_FILE" >"$TMP_DIR/notify-selected.json" || return 1
    count=$(jq length "$TMP_DIR/notify-selected.json");((count>0)) || { log INFO "Routine update events retained for the daily report cutoff; urgent attention bypasses batching";return 0; }
    total=$(jq '.outbox|length' "$STATE_FILE")
    body=$(jq -r '.[]|"["+.importance+"] "+.subject+"\nObserved: "+(.at|strflocaltime("%Y-%m-%d %H:%M:%S"))+"\n"+.detail+"\n"' "$TMP_DIR/notify-selected.json") || return 1
    body+=$'\n'"Delivery: $count of $total queued event(s); any remainder is retained for the next scheduled delivery."
    importance=$(jq -r 'if any(.[];.importance=="alert") then "alert" elif any(.[];.importance=="warning") then "warning" else "normal" end' "$TMP_DIR/notify-selected.json")
    usr_ops_notify timeout 30 "$NOTIFY_BIN" -i "$importance" -s 'System Update Coordinator' -d "Update report: $count event(s), $((total-count)) retained" -m "$body" || rc=$?
    if ((rc==0));then mutate --slurpfile sent "$TMP_DIR/notify-selected.json" --argjson now "$(date +%s)" '
      reduce $sent[0][] as $e (.;.delivered[$e.id]=$now) |
      .outbox=([.outbox[]|. as $e|select(all($sent[0][];.id!=$e.id))]) |
      .normalDeliveryIds=([(.normalDeliveryIds // [])[] | . as $id | select(all($sent[0][];.id!=$id))]) |
      .delivered |= with_entries(select(.value>=$now-30*86400))' || return 1;fi
    if ((rc==0));then log INFO "Notification accepted; acknowledged $count event(s); $((total-count)) retained";else log ERROR "Notification delivery failed; $total queued event(s) retained for retry";fi
    return "$rc"
}

finish() {
    local rc=$? temp
    trap - EXIT INT TERM HUP
    # Never remove a live/uncertain native mutation's maintenance protection.
    if [[ -n "$LEASE_FILE" && "$INSTALL_ACTIVE" != true ]];then
      # Durable INTENT/VERIFYING/ATTENTION also suppress watchdog recovery;
      # the temporary lease itself can expire independently of this process.
      rm -f -- "$LEASE_FILE"
    fi
    [[ -z "${MAINT_FD:-}" ]] || exec {MAINT_FD}>&-
    release_operation_locks
    [[ "$REQUEST_KEEP" == true ]] || clear_update_request || true
    ((rc==0)) || RESULT=FAILED
    if ((rc!=0)) && [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && state_valid "$STATE_FILE";then
      event alert 'Coordinator stopped before completion' "${SUMMARY:-Coordinator operation failed}. Durable intents and recovery evidence were retained. No uncertain installer action will be replayed; next scheduled run reconciles actual state." coordinator-execution-failed || true
      flush_notifications || true
    fi
    if [[ -n "$TMP_DIR" && -d "$STATE_DIR" ]];then
      temp="$TMP_DIR/receipt.json"
      jq -n --arg status "$RESULT" --arg summary "${SUMMARY:-Update policy, evidence and pending work evaluated}" --arg version "$SCRIPT_VERSION" --arg run "$RUN_ID" --argjson epoch "$(date +%s)" --argjson started "$START_EPOCH" --arg mode "${MODE:-automatic}" --argjson automatic "$(jq -r '.lastAutomaticRunAt // 0' "$STATE_FILE" 2>/dev/null || printf 0)" \
       '{mode:$mode,lastAutomaticRunAt:$automatic,schema:1,name:"system_update_coordinator",status:$status,summary:$summary,scriptVersion:$version,runId:$run,epoch:$epoch,durationSeconds:($epoch-$started)}' >"$temp" && publish "$temp" "$STATUS_DIR/system_update_coordinator.json" || true
      if [[ "${QUIET_FINISH:-false}" == true ]];then
        usr_ops_append_log "$LOG_FILE" "$(usr_ops_log_line INFO policy 'Saved update policy/status inspected; no installer started')" || true
      else log INFO "Completed run; status=$RESULT; ${SUMMARY:-pending work retained for its next eligible window}" || true;fi
      rm -rf -- "$TMP_DIR"
    fi
    exit "$rc"
}

usage() {
 cat <<'HELP'
Usage: /bin/bash /boot/config/plugins/user.scripts/scripts/system_update_coordinator/script [COMMAND]
No command: automatic policy evaluation, bounded checks, approved installation in
13:15-15:30 Singapore, reconciliation and grouped reporting. Schedule: */15 * * * *.
--status                       Saved policy and update status; no registry/install.
--check-only [--refresh]       Refresh due/all bounded evidence; no installation.
--candidates                   Show verified/held available update candidates and next attempts.
--allow docker NAME             Approve exact installed image repository/channel.
--allow plugin NAME.plg         Approve exact installed plugin source (OS excluded).
--allow-installed              Approve current installed identities; OS stays manual.
--report-preview               Print saved holds, schedule cutoffs and next attempt; no install/email.
--deny docker|plugin NAME       Disable approval; retain reporting.
--pause / --resume              Pause/resume all new installations; checks continue.
--window HH:MM HH:MM            Set primary same-day Singapore window.
--add-window HH:MM HH:MM        Add a non-overlapping window (maximum four).
--remove-window HH:MM HH:MM     Remove a window; at least one must remain.
--report-time HH:MM             Set the daily grouped report time (default 15:45).
--hold docker|plugin NAME H     Override one installed identity hold (1-168 hours).
--archive-limit GIB             Bound previous-image size/archive (1-8 GiB; default 4).
--limits DOCKER PLUGINS HOLD_H  Set independent daily caps (1-12 Docker, 0-4 plugins) and
                               candidate hold (1-168 hours); one update/run stays fixed.
--resolve JOB_ID NOTE           Close a reviewed failed/uncertain job without
                               claiming success; no installer/recovery is executed.
--help / --version              No network checks or installation.
Removing an app/plugin needs no command: two complete inventories retire its entry.
New/reinstalled identities default to reporting only and can be approved with CLI.
No command changes Docker startup/template/application settings or image channels.
The two default windows are 13:15-15:30 and 21:15-23:00 Singapore.
The daily report defaults to 23:15 so both windows are included in one email.
Native schedules and relevant User Scripts jobs are checked before preparation
and dispatch; updates defer if the bounded restart cannot fit. Protected job
schedules, Docker startup and app configuration are never changed.
Two observed missed windows raise priority and a grouped warning; no guard is
overridden and no active job is killed to force an update.
Active conflicting scripts finish normally; updater waits up to 90 seconds, then
retries on its existing schedule. Expiring 20-minute requests let new conflicting
work yield, avoiding repeated collisions. Unrelated Docker apps remain eligible.
Plex direct play/direct stream permits updates (brief playback interruption is
possible); transcoding, database repair and backups still defer installation.
Approval enables native updates within the existing configured channel. The age
hold defaults to 6h for Docker, 1h for nightly/develop/unstable and 24h for plugins.
All holds measure this coordinator's observation, not registry publication.
Backup freshness follows the current appdata/boot User Scripts cron, allowing
one delayed run and 12 hours for completion. Invalid schedules defer updates.
Mover, non-correcting parity checks and unrelated remote copies are advisory.
All observed holds and the next reassessment time appear in the grouped report.
Unknown major OS/interface: installation stops. No OS install/reboot or automatic
DB rollback is provided. Old image/config evidence does not guarantee DB rollback.
HELP
}

main() {
    case "${1:-}" in --help|-h) usage;return 0;;--version) printf 'system_update_coordinator.sh %s\n' "$SCRIPT_VERSION";return 0;;esac
    MODE="${1:-automatic}"
    START_EPOCH=$(date +%s);RUN_ID="$(date +%Y%m%d_%H%M%S)_$$"
    for cmd in jq php docker flock timeout gzip tar sha256sum sync stat find df mountpoint;do command -v "$cmd" >/dev/null || { printf 'Required command unavailable: %s\n' "$cmd" >&2;return 1; };done
    exec {UPDATE_FD}>"$LOCK_FILE";flock -n "$UPDATE_FD" || { printf 'Update coordinator already active; invocation deferred.\n';return 0; }
    if ! initialize;then
      local marker="/run/system-update-coordinator-startup-$(date +%F)"
      if [[ "$MODE" == automatic && ! -e "$marker" && -x "$NOTIFY_BIN" ]];then
        usr_ops_notify timeout 30 "$NOTIFY_BIN" -i alert -s 'System Update Coordinator' -d 'Coordinator startup failed; automatic updates stopped' -m 'State, policy, storage or native inventory could not be validated. Existing files were preserved and no installer was started. Review the operational console and restore valid coordinator state before resuming.' && : >"$marker" || true
      fi
      return 1
    fi
    prune_update_requests
    trap finish EXIT
    trap 'SUMMARY="Update coordinator interrupted; durable intent retained";exit 143' INT TERM HUP
    case "${1:-}" in
      --candidates) QUIET_FINISH=true;jq '[.items|to_entries[]|select(.value.available==true)|{kind:.value.kind,name:.value.name,status:"CANDIDATE",candidate:.value.candidate,verified:(.value.checkStatus=="VERIFIED"),firstObservedAt:.value.candidateSeenAt,checkedAt:.value.checkedAt,scheduling:.value.scheduling,nextAttemptAt:.value.holds.nextAttemptAt,holds:(.value.holds.reasons // []),readiness:.value.readinessAssessment}]' "$STATE_FILE";return $?;;
      --status) QUIET_FINISH=true;jq -n --slurpfile p "$POLICY_FILE" --slurpfile s "$STATE_FILE" '{policy:$p[0],items:$s[0].items,jobs:$s[0].jobs,pendingNotifications:($s[0].outbox|length)}';return 0;;
      --pause|--resume) local enabled=false;[[ "$1" != --resume ]] || enabled=true;policy_update --argjson enabled "$enabled" '.enabled=$enabled';return $?;;
      --limits) [[ $# == 4 && "$2" =~ ^([1-9]|1[0-2])$ && "$3" =~ ^[0-4]$ && "$4" =~ ^[0-9]+$ ]] && ((10#$4>=1 && 10#$4<=168)) || return 2;policy_update --argjson docker "$2" --argjson plugins "$3" --argjson hold "$((10#$4))" '.limits += {dailyDocker:$docker,dailyPlugins:$plugins,dailyTotal:($docker+$plugins),candidateHoldHours:$hold}';return $?;;
      --hold)
        [[ $# == 4 && ( "$2" == docker || "$2" == plugin ) && "$4" =~ ^[0-9]+$ ]] && valid_name "$3" && ((10#$4>=1 && 10#$4<=168)) || return 2
        jq -e --arg kind "$2" --arg name "$3" '((if $kind=="docker" then .docker[$name] else .plugins[$name] end).identity|type)=="string"' "$POLICY_FILE" >/dev/null || return 2
        policy_update --arg kind "$2" --arg name "$3" --argjson hours "$((10#$4))" 'if $kind=="docker" then .docker[$name].candidateHoldHours=$hours else .plugins[$name].candidateHoldHours=$hours end';return $?;;
      --archive-limit) [[ $# == 2 && "$2" =~ ^[1-8]$ ]] || return 2;policy_update --argjson bytes "$((10#$2*1073741824))" '.limits.imageMaxBytes=$bytes';return $?;;
      --report-time) [[ $# == 2 && "$2" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || return 2;policy_update --arg time "$2" '.reportTime=$time';return $?;;
      --window) [[ $# == 3 && "$2" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ && "$3" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ && "$2" < "$3" ]] || return 2;policy_update --arg start "$2" --arg end "$3" '.window={start:$start,end:$end} | if .windows!=null then .windows[0]=.window | .windows|=sort_by(.start) | .window=.windows[0] else . end';return $?;;
      --add-window|--remove-window)
        [[ $# == 3 && "$2" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ && "$3" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ && "$2" < "$3" ]] || return 2
        if [[ "$1" == --add-window ]];then
          policy_update --arg start "$2" --arg end "$3" '.windows=((.windows // [.window])+[{start:$start,end:$end}]|unique|sort_by(.start)) | .window=.windows[0]'
        else policy_update --arg start "$2" --arg end "$3" '.windows=((.windows // [.window])|map(select(.start!=$start or .end!=$end))) | .window=.windows[0]';fi;return $?;;
      --resolve) [[ $# == 3 && -n "$3" && ${#3} -le 2000 ]] || return 2;jq -e --arg id "$2" '.jobs[$id]!=null and (.jobs[$id].status|IN("ATTENTION","VERIFYING","INTENT"))' "$STATE_FILE" >/dev/null || return 2;job_update "$2" '.jobs[$id].status="CLOSED_BY_OPERATOR" | .jobs[$id].resolutionNote=$note | .jobs[$id].closedAt=$now' --arg note "$3" --argjson now "$(date +%s)";return $?;;
      --report-preview) QUIET_FINISH=true;render_update_report;return $?;;
      --allow-installed)
        [[ $# == 1 ]] || return 2;collect_inventory || return 1
        policy_update --slurpfile inv "$TMP_DIR/inventory.json" --argjson now "$(date +%s)" "$APPROVAL_JQ"'
          . as $old |
          .docker=($inv[0].docker|with_entries(.key as $name|.value=approval(($old.docker[$name] // {});.value.repository;(.value.repository|length>0);"docker";$now))) |
          .plugins=($inv[0].plugins|with_entries(.key as $name|.value=approval(($old.plugins[$name] // {});.value.installed.url;(.key!="unRAIDServer.plg" and (.value.installed.url|startswith("https://")));"plugin";$now)))';return $?;;
      --allow|--deny)
        [[ $# == 3 && ( "$2" == docker || "$2" == plugin ) ]] && valid_name "$3" || return 2
        [[ "$3" != unRAIDServer.plg ]] || return 2
        if [[ "$1" == --deny ]];then
          policy_update --arg kind "$2" --arg name "$3" 'if $kind=="docker" then .docker[$name]=((.docker[$name] // {identity:""})+{allow:false}) else .plugins[$name]=((.plugins[$name] // {identity:""})+{allow:false}) end';return $?
        fi
        collect_inventory || return 1
        local identity allow=false;[[ "$1" != --allow ]] || allow=true
        if [[ "$2" == docker ]];then identity=$(jq -er --arg name "$3" '.docker[$name].repository|select(length>0)' "$TMP_DIR/inventory.json") || return 2
        else identity=$(jq -er --arg name "$3" '.plugins[$name].installed.url|select(startswith("https://"))' "$TMP_DIR/inventory.json") || return 2;fi
        policy_update --arg kind "$2" --arg name "$3" --arg identity "$identity" --argjson allow "$allow" --argjson now "$(date +%s)" \
          "$APPROVAL_JQ"'if $kind=="docker" then .docker[$name]=approval((.docker[$name] // {});$identity;$allow;$kind;$now) else .plugins[$name]=approval((.plugins[$name] // {});$identity;$allow;$kind;$now) end';return $?;;
      ''|--check-only)
        [[ $# -le 2 && ( $# -lt 2 || "$2" == --refresh ) ]] || return 2
        if [[ "${2:-}" == --refresh ]];then CHECK_INTERVAL_SECONDS=0;MAX_CHECKS_PER_RUN=32;fi;;
      *) return 2;;
    esac
    reconcile_script_schedules || { SUMMARY="Schedule reconciliation deferred: ${SUMMARY:-inventory unverified}";return 1; }
    collect_inventory || { SUMMARY='Inventory unavailable/incomplete; no retirement or installation';return 1; }
    report_retired_updates || return 1
    check_updates || return 1
    recover_preparation || return 1
    track_update_windows || return 1
    reconcile_jobs || { RESULT=ATTENTION;SUMMARY='Pending update reconciliation incomplete; native actions not replayed'; }
    [[ "${1:-}" == --check-only ]] || install_one || return 1
    if jq -e 'any(.jobs[];.status=="ATTENTION" or .status=="INTENT")' "$STATE_FILE" >/dev/null;then RESULT=ATTENTION;fi
    clean_recovery_sets || log WARNING 'Recovery-set retention deferred; existing evidence retained'
    collect_update_holds || log WARNING 'Update hold assessment incomplete; existing observations retained'
    warn_starved_updates || return 1
    daily_update_report || return 1
    flush_notifications || { RESULT=ATTENTION;SUMMARY='Notification delivery failed; report retained for retry'; }
    mutate --arg mode "$MODE" --argjson now "$(date +%s)" '.lastCompletedAt=$now | (if $mode=="automatic" then .lastAutomaticRunAt=$now else . end) | .jobs |= with_entries(select(.value.status=="INTENT" or .value.status=="VERIFYING" or .value.status=="ATTENTION" or (.value.startedAt // 0)>=$now-90*86400 or ((.value.recoveryPath // "")!="" and (.value.recoveryPrunedAt // 0)==0)))'
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]];then main "$@";fi
