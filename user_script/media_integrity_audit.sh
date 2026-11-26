#!/bin/bash
# shellcheck disable=SC2034
clearLog=true
arrayStarted=true
###############################################################################
# Media Integrity Audit v2.6.3 -- personal Unraid User Script
#
# PURPOSE / USE CASE
# ------------------
# Find unreadable containers and repeatable audio/video decoder errors before
# playback. Read only movies/, series/ and formula1/ under /mnt/user/media using
# Bazarr's existing FFprobe, FFmpeg and Python. No package/image/startup/config
# installation or modification. Default observation performs no media/Arr mutation.
# Optional bounded recovery is installed but AUTO_RECOVERY_ENABLED=false.
# Download/quarantine folders and /mnt/user/secure are outside this scope.
#
# PROCESS / COVERAGE
# ------------------
# Inventory regular video files without following symlinks. New/changed files
# receive a bounded stream/container probe, with up to 25% of the run (30 minutes)
# front-loaded for broad new-file coverage before expensive decoding. Deep work decodes every selected
# video and audio stream in successive, overlapping ten-minute media ranges;
# save the next range so long files resume on a later scheduled run. This is full
# planned-range coverage, NOT a single linear read, checksum baseline, subtitle
# check, visual-quality test, or proof that every Plex client plays the file.
# Size/mtime/ctime/inode changes invalidate progress. Unchanged successful files
# become due again after 180 days; metadata alone cannot rule out later bit rot.
# Prefer new/changed work with a 60% share, reserving 40% for older periodic work
# when both lanes have work. In-progress files resume before starting more files.
#
# BOUNDS / COORDINATION
# ---------------------
# Wednesday and Sunday 07:00 Singapore time; at most two hours per run.
# Single User Scripts custom cron: 0 7 * * 0,3.
# Use two video decoder threads, one audio/filter thread, nice 15, idle-class I/O
# and a 2 GiB per-decoder virtual-address-space limit. This is not a container RAM
# limit. Slow ranges shrink after timeout; timeouts/resource limits are unverified,
# not corruption. One worker at a time; interrupted ranges never advance.
# Actual kernel I/O stalls may outlast termination requests. Missing mounts/API,
# Mover, active parity, backups, Bazarr maintenance or Plex transcodes defer/stop
# read work. A paused parity operation with mdResync=0 does not imply active I/O.
# No long-held backup lock: appdata backup never waits two hours for this audit.
#
# FINDINGS / RECOVERY / NOTIFICATIONS
# ----------------------------------
# Repeat a decoder/container failure on the same unchanged file when budget
# permits; report repeatable errors separately from unsupported tools, permission
# errors, timeouts and incomplete coverage. A changed file is pending verification,
# never automatically healthy. Two clean same-range rechecks can close a prior
# finding; replacement files require a completed planned-range cycle. Confirmed
# inventory removal is reported as removed, not repaired. Failed files retry on
# later schedules rather than consuming the same run repeatedly.
# All run summaries/progress/recoveries remain in local reports. Active
# findings, unexpected failures, state fallback or incomplete/overdue recovery
# trigger grouped attention email. Same evidence reminds at most weekly; progress
# alone and healthy ordinary scans stay quiet. Verified replacement completion
# sends one grouped operational notification, retried if delivery fails. A failed
# attention email remains in one pending outbox and retries while still relevant.
#
# OPTIONAL ARR RECOVERY (OFF): two distinct confirming runs on one unchanged
# version, fresh <=48h evidence and matching decoder runtime. Keep the original
# and Arr file record in place. Use native interactive release search, exact IDs,
# current profile/quality/revision/language/score rules and Usenet only. Select
# an alternative release; POST /release once. No file DELETE, monitoring PUT,
# profile changes, blocklisting, forced import or script-managed bin handoff.
# Arr owns normal replacement and recycling. Exact download history/import/file
# identity plus complete planned-range decoding are required before RECOVERED.
# Existing monitor runs bounded priority verification between scheduled scans; only
# new grabs use 00/04/08/12/16/20:00-09 SGT windows. Same audit/backup/metadata
# locks and exact-target ownership protect complementary script automation.
# Replacement-required/blocked/completed events are grouped and delivery-tracked.
# Native bin retention is independent; overdue verification alerts cannot extend
# it. No promise of atomic filesystem import or guaranteed original rollback.
#
# STATE / LOGS / CLI
# ------------------
# Own /mnt/vault/cloud/logs/script/media_integrity_audit: one compressed JSON state,
# one previous validated state, required recovery.json intent/hold journal,
# an overwritten latest-report.txt, notification
# outbox/receipt and a 1 MiB log with two backups (30-day backup retention).
# Checkpoint at most once per minute and at completion; incomplete last ranges
# may be repeated after interruption. Never create a shadow vault under RAM.
# --help / --version: no scans. --status: saved evidence only, no Docker/media I/O.
# --inventory-only: inventory/stat only; may wake disks and updates audit state,
# but performs no FFprobe/decoding and sends no normal summary. No argument: real
# scheduled audit (read-only while recovery is disabled). --recovery-status reads
# only the recovery journal. --recover-only cannot override the disabled switch.
# No scan, timeout or error changes media permissions.
###############################################################################
# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="media_integrity_audit"
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
# BEGIN SCHEDULED EXECUTION SUPERVISOR
if [[ "${BASH_SOURCE[0]}" == "$0" && $# == 0 && "${USR_OPS_SUPERVISED:-}" != "$OPS_SCRIPT_ID" ]];then
    usr_ops_supervise "$0";exit $?
fi
# END SCHEDULED EXECUTION SUPERVISOR
# Shared new-action budget. Native outcomes remain in the producer's journal.
usr_ops_arr_reserve() (
    [[ "${USR_OPS_SHARED_BUDGET_ACTIVE:-false}" == true ]] || return 0
    local action="$1" app="$2" target="$3" root="${MEDIA_ACTION_BUDGET_ROOT:-/mnt/vault/cloud/logs/script/media_health_monitor}" now run fd export_fd temp file
    [[ "$app" == Sonarr || "$app" == Radarr ]] || return 1
    [[ "$target" =~ ^[1-9][0-9]*$ && -d "$root" && ! -L "$root" ]] || return 1
    [[ "$root" != /mnt/vault/* ]] || mountpoint -q /mnt/vault || return 75
    file="$root/action-budget.json";[[ ! -L "$file" ]] || return 1
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}" || return 1
    flock -s -n "$export_fd" || return 75
    exec {fd}>"${MEDIA_ACTION_BUDGET_LOCK:-/run/media-automation-budget.lock}" || return 1
    flock -x -w 5 "$fd" || return 75
    now=$(date +%s);run="${MEDIA_AUTOMATION_RUN_ID:-$OPS_SCRIPT_ID:${START_TIME:-${START_EPOCH:-$$}}:$$}"
    temp=$(mktemp "$root/.action-budget.XXXXXX") || return 1
    trap 'rm -f -- "$temp"' EXIT
    if [[ -f "$file" ]];then
      jq -e '.schema==1 and (.actions|type)=="object" and all(.actions[];(.at|type)=="number" and (.run|type)=="string")' "$file" >/dev/null || return 1
      cp "$file" "$temp" || return 1
    else
      # Seed from existing issued/uncertain journals instead of resetting limits
      # when the shared contract is first installed. Known local non-dispatch is excluded.
      printf '{"schema":1,"actions":{}}\n' >"$temp"
      local source prefix seed
      for source in "$root/automation-actions.json" "$root/policy-actions.json" "${MEDIA_INTEGRITY_RECOVERY_FILE:-/mnt/vault/cloud/logs/script/media_integrity_audit/recovery.json}";do
        [[ -f "$source" && ! -L "$source" ]] || continue
        prefix="${source##*/}";seed="$temp.seed"
        jq --slurpfile old "$source" --arg prefix "$prefix" --argjson since "$((now-86400))" '
          reduce (($old[0].actions // {})|to_entries[]|select((.value.startedAt // .value.grabSentAt // 0)>=$since and .value.outcome!="not_dispatched" and
           (if $prefix=="recovery.json" then (.value.grabSentAt // 0)>0 else true end))) as $r
           (.;.actions[($prefix+":"+$r.key)]={at:($r.value.grabSentAt // $r.value.startedAt),run:"pre-contract",owner:$prefix,app:$r.value.app,target:($r.value.targetId // $r.value.parentId)})' "$temp" >"$seed" && mv "$seed" "$temp" || return 1
      done
    fi
    if jq -e --arg key "$action" '.actions[$key]!=null' "$temp" >/dev/null;then return 75;fi
    jq -e --argjson since "$((now-86400))" --arg run "$run" '[.actions[]|select(.at>=$since)] as $today | ($today|length)<4 and ([$today[]|select(.run==$run)]|length)<2' "$temp" >/dev/null || return 75
    jq --arg key "$action" --arg app "$app" --argjson target "$target" --arg run "$run" --arg owner "$OPS_SCRIPT_ID" --argjson now "$now" \
      '.actions |= with_entries(select(.value.at>=$now-30*86400)) | .actions[$key]={at:$now,run:$run,owner:$owner,app:$app,target:$target,outcome:"reserved; native journal owns dispatch/outcome"}' "$temp" >"$temp.next" && mv "$temp.next" "$temp" || return 1
    sync -f "$temp" && mv "$temp" "$file" && sync -f "$root"
)

usr_ops_arr_release_undispatched() (
    [[ "${USR_OPS_SHARED_BUDGET_ACTIVE:-false}" == true ]] || return 0
    local key="$1" root="${MEDIA_ACTION_BUDGET_ROOT:-/mnt/vault/cloud/logs/script/media_health_monitor}" fd export_fd temp run
    run="${MEDIA_AUTOMATION_RUN_ID:-$OPS_SCRIPT_ID:${START_TIME:-${START_EPOCH:-$$}}:$$}"
    [[ -f "$root/action-budget.json" && ! -L "$root/action-budget.json" ]] || return 1
    exec {export_fd}>"${STATE_EXPORT_LOCK:-/run/user-script-state-export.lock}";flock -s -n "$export_fd" || return 75
    exec {fd}>"${MEDIA_ACTION_BUDGET_LOCK:-/run/media-automation-budget.lock}";flock -x -w 5 "$fd" || return 75
    temp=$(mktemp "$root/.budget-release.XXXXXX") || return 1
    trap 'rm -f -- "$temp"' EXIT
    jq --arg key "$key" --arg run "$run" 'if .actions[$key].run==$run then del(.actions[$key]) else . end' "$root/action-budget.json" >"$temp" && sync -f "$temp" && mv "$temp" "$root/action-budget.json" && sync -f "$root"
)
set -uo pipefail
umask 077
# Evidence policy: successful FFprobe diagnostics are not corruption proof.
# Only isolated primary-stream failures under both strict and normal decoding
# can authorize recovery. Signals, output errors and auxiliary/recoverable
# defects never authorize replacement. Matching unchanged-file/range/toolchain
# evidence can confirm an incident. Two separate
# audit runs are required before Arr recovery eligibility. Nonfatal H.264 SEI
# user-data/reference-startup diagnostics remain advisories; unknown diagnostics
# stay unverified. Completed ranges prove decoder acceptance, not perfect visual
# playback. Legacy probe-only incidents are re-evaluated without replacing media.
# Worker transport failures preserve the last checkpoint and never accuse media.
readonly SCRIPT_VERSION="2.6.4"
BAZARR_CONTAINER="bazarr"
MEDIA_HOST_ROOT="/mnt/user/media"
MEDIA_CONTAINER_ROOT="/data"
LIBRARY_SUBDIRS=(movies series formula1)
STATE_DIR="${STATE_DIR:-/mnt/vault/cloud/logs/script/media_integrity_audit}"
STATUS_DIR="${STATUS_DIR:-/mnt/vault/cloud/logs/script/user_scripts_status}"
VAULT_MOUNT="/mnt/vault"
STATE_FILE="$STATE_DIR/state.json.gz"
PREVIOUS_STATE_FILE="$STATE_DIR/state.previous.json.gz"
LOG_FILE="$STATE_DIR/media-integrity-audit.log"
LOCK_FILE="${LOCK_FILE:-/run/media_integrity_audit.lock}"
NOTIFY_BIN="${NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify}"
MAX_RUNTIME_SECONDS=7200
QUICK_PASS_MAX_SECONDS=1800
VIDEO_THREADS=2
DECODER_MEMORY_MIB=2048
SEGMENT_MEDIA_SECONDS=600
SEGMENT_WALL_SECONDS=600
FILE_SLICE_SECONDS=900
RECHECK_DAYS=180
SETTLE_SECONDS=600
MAX_STATE_BYTES=$((64*1024*1024))
LOG_MAX_BYTES=$((1024*1024))
NOTIFY_MAX_ITEMS=8
BACKUP_LOCK_FILES=(/tmp/backup_cache_appdata.lock /tmp/backup_media_remote.lock /run/backup_vault_remote.lock)
PLEX_CONTAINERS=(plex-media-server plex-media)
ARR_BACKUP_GATE="/run/arr-appdata-coordination.lock"
STATE_EXPORT_LOCK="/run/user-script-state-export.lock"
DOCKER_MAINTENANCE_DIR="/run/docker-service-maintenance"
# Observation remains the default. Enabling this later permits bounded
# Arr-native release selection/grab, only after two separate audit runs confirm
# the same unchanged decoder error. Original remains in place; no forced import.
AUTO_RECOVERY_ENABLED=false
SONARR_API_ROOT="${SONARR_API_ROOT:-http://192.168.50.4:8989/api/v5}"
SONARR_API_KEY="${SONARR_API_KEY:-PUT_YOUR_SONARR_API_KEY_HERE}"
RADARR_API_ROOT="${RADARR_API_ROOT:-http://192.168.50.4:7878/api/v3}"
RADARR_API_KEY="${RADARR_API_KEY:-PUT_YOUR_RADARR_API_KEY_HERE}"
SONARR_MEDIA_ROOT="/data"
RADARR_MEDIA_ROOT="/data"
RECOVERY_FILE="$STATE_DIR/recovery.json"
RECOVERY_PREVIOUS_FILE="$STATE_DIR/recovery.previous.json"
RECOVERY_DOWNLOAD_ROOTS=(/mnt/user/media/net/incomplete /mnt/user/media/net/complete)
RECOVERY_MAX_ATTEMPTS=2
RECOVERY_RETRY_SECONDS=14400
RECOVERY_MAX_NEW_PER_RUN=1
RECOVERY_MAX_NEW_PER_WEEK=3
RECOVERY_WAIT_DAYS=28
RECOVERY_ALLOW_GRAB="${RECOVERY_ALLOW_GRAB:-false}"
RECOVERY_NEW_GRABS=0
RECOVERY_MAX_SECONDS=90
RECOVERY_DEADLINE=0
NOTIFICATION_REMINDER_SECONDS=604800

recovery_window_open() {
    local hour minute
    hour=$(TZ=Asia/Singapore date +%H);minute=$(TZ=Asia/Singapore date +%M)
    ((10#$hour%4==0 && 10#$minute<10))
}

recovery_new_window_open() {
    local minute
    recovery_window_open || return 1
    minute=$(TZ=Asia/Singapore date +%M)
    ((10#$minute<7)) # reserve the final three minutes for in-flight work
}

TMP_DIR="" WORKER_PID="" WORKER_TOKEN="" WORKER_FINISHED=false
RUN_REPORT_WRITTEN=false FAILURE_REASON=""
MODE=scan GUARD_REASON="" RECOVERY_NOTE="" TRANSPORT_RC=0

log() {
    local level="$1"; shift
    if [[ -f "$LOG_FILE" ]] && (( $(stat -c %s "$LOG_FILE" 2>/dev/null || printf 0)>=LOG_MAX_BYTES )); then
        rm -f -- "$LOG_FILE.2"
        [[ ! -f "$LOG_FILE.1" ]] || mv -f "$LOG_FILE.1" "$LOG_FILE.2"
        mv -f "$LOG_FILE" "$LOG_FILE.1"
    fi
    usr_ops_log_line "$level" MAIN "$*" | tee -a "$LOG_FILE"
}

probe_lock() {
    local fd path="$1"
    [[ ! -e "$path" ]] || { exec {fd}>"$path" || return 1; flock -s -n "$fd"; local rc=$?; exec {fd}>&-; return "$rc"; }
}

workload_guard() {
    local info values active position lock lease now processes container
    GUARD_REASON=""
    mountpoint -q /mnt/user && mountpoint -q "$VAULT_MOUNT" || { GUARD_REASON='Required user/vault mount unavailable'; return 1; }
    [[ -d "$MEDIA_HOST_ROOT" && ! -L "$MEDIA_HOST_ROOT" ]] || { GUARD_REASON='Media root unavailable or symlinked'; return 1; }
    for lock in "$ARR_BACKUP_GATE" "${BACKUP_LOCK_FILES[@]}"; do
        probe_lock "$lock" || { GUARD_REASON="Backup/maintenance lock active: ${lock##*/}"; return 1; }
    done
    if pgrep -f '(^|/)(mover|mover\.old)([[:space:]]|$)|mover\.php' >/dev/null; then GUARD_REASON='Unraid Mover is active'; return 1; fi
    values=$(timeout 5 /usr/local/sbin/mdcmd status 2>/dev/null) || { GUARD_REASON='Array/parity state unavailable'; return 1; }
    grep -q '^mdState=STARTED$' <<<"$values" || { GUARD_REASON='Array not started'; return 1; }
    active=$(awk -F= '$1=="mdResync" {print $2}' <<<"$values")
    position=$(awk -F= '$1=="mdResyncPos" {print $2}' <<<"$values")
    [[ "$active" =~ ^[0-9]+$ && "$position" =~ ^[0-9]+$ ]] || { GUARD_REASON='Parity fields unverified'; return 1; }
    if (( active>0 && position>0 )); then GUARD_REASON='Active parity/check/rebuild I/O'; return 1; fi
    now=$(date +%s)
    for lease in "$DOCKER_MAINTENANCE_DIR/$BAZARR_CONTAINER"*.json; do
        [[ -e "$lease" ]] || continue
        if ! jq -e --argjson now "$now" '(.expires|type)=="number" and .expires<=$now' "$lease" >/dev/null 2>&1; then
            GUARD_REASON='Bazarr maintenance lease active/unverified'; return 1
        fi
    done
    info=$(timeout 8 docker inspect "$BAZARR_CONTAINER" 2>/dev/null) || { GUARD_REASON='Bazarr inspection unavailable'; return 1; }
    if ! jq -e --arg source "$MEDIA_HOST_ROOT" --arg dest "$MEDIA_CONTAINER_ROOT" \
        'length==1 and .[0].State.Running==true and any(.[0].Mounts[]; .Type=="bind" and .Source==$source and .Destination==$dest)' <<<"$info" >/dev/null; then
        GUARD_REASON='Bazarr stopped or exact media bind mount unverified'; return 1
    fi
    for container in "${PLEX_CONTAINERS[@]}"; do
        if [[ $(timeout 6 docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null) == false ]]; then continue;fi
        processes=$(timeout 6 docker top "$container" -eo pid,comm 2>/dev/null) || { GUARD_REASON="Plex workload unverified: $container"; return 1; }
        if grep -Eq '[[:space:]]Plex Transcoder([[:space:]]|$)' <<<"$processes"; then GUARD_REASON="Plex transcoder active: $container"; return 1; fi
    done
}

cancel_worker() {
    [[ -n "$WORKER_TOKEN" && "$WORKER_FINISHED" != true ]] || return 0
    timeout 8 docker exec --user 99:100 "$BAZARR_CONTAINER" python3 -c '
import json,os,signal,sys
key=sys.argv[1];path="/tmp/media-integrity-audit."+key+".json"
try:
 fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
 with os.fdopen(fd) as f: d=json.load(f)
 pid=int(d["pid"])
 if d["token"]==key and key.encode() in open(f"/proc/{pid}/cmdline","rb").read().split(b"\0") and open(f"/proc/{pid}/stat").read().split()[21]==d["start"]:
  os.kill(pid,signal.SIGTERM)
except (FileNotFoundError,ProcessLookupError):pass
' "$WORKER_TOKEN" >/dev/null 2>&1 || true
}

cleanup() {
    cancel_worker
    [[ -z "$WORKER_PID" ]] || { kill "$WORKER_PID" 2>/dev/null || true; wait "$WORKER_PID" 2>/dev/null || true; }
    [[ -z "$TMP_DIR" || "$TMP_DIR" != /tmp/media-integrity-audit.* ]] || rm -rf -- "$TMP_DIR"
}

# If startup/storage/reporting fails before the normal grouped report can be
# written, still emit a bounded operational alert. Never invent healthy state
# or create a shadow vault/log tree. Explicit cancellation stays quiet.
finish() {
    local rc=$? marker
    trap - EXIT
    cleanup
    if ((rc!=0 && rc!=130 && rc!=143)) && [[ "$RUN_REPORT_WRITTEN" != true ]]; then
        marker="/tmp/media-integrity-preflight-$(date +%F).notified"
        printf 'Media integrity audit failed before normal reporting: %s (exit %s)\n' "${FAILURE_REASON:-${GUARD_REASON:-Startup or report persistence failed}}" "$rc" >&2
        if [[ ! -e "$marker" && -x "$NOTIFY_BIN" ]] && command -v timeout >/dev/null; then
            if usr_ops_notify timeout 30 "$NOTIFY_BIN" -i alert -s 'Media Integrity Audit' -d 'Audit could not complete normal reporting' \
              -m "Failure: ${FAILURE_REASON:-${GUARD_REASON:-Startup or persistent reporting failed}} (exit $rc).
No unverified scan/recovery was marked healthy. Existing recovery originals, intent records and deletion-sync holds remain protected. Correct the missing command/storage/configuration or reporting failure before the next run; review the User Scripts console for the failing operation."; then : >"$marker";fi
        fi
    fi
    exit "$rc"
}

load_state() {
    local file="$STATE_FILE"
    [[ ! -L "$file" && ! -L "$PREVIOUS_STATE_FILE" ]] || return 1
    if [[ ! -f "$file" ]]; then
        if [[ -f "$PREVIOUS_STATE_FILE" ]]; then file="$PREVIOUS_STATE_FILE";RECOVERY_NOTE='Current state missing; using previous validated checkpoint'
        else printf '{"schema":1,"files":{}}\n' >"$TMP_DIR/state.json";return 0; fi
    fi
    if ! unpack_state "$file"; then
        [[ "$file" != "$PREVIOUS_STATE_FILE" && -f "$PREVIOUS_STATE_FILE" ]] && unpack_state "$PREVIOUS_STATE_FILE" || return 1
        file="$PREVIOUS_STATE_FILE";RECOVERY_NOTE='Current state invalid; resumed previous validated checkpoint; recent work may repeat'
    fi
    # The publisher rotates the immediately preceding validated checkpoint.
    # Loading state does not rewrite that rollback copy.
    return 0
}

unpack_state() {
    local file="$1" bytes
    (( $(stat -c %s "$file")<=MAX_STATE_BYTES )) || return 1
    if ! timeout 15 gzip -dc -- "$file" 2>/dev/null | head -c "$((MAX_STATE_BYTES+1))" >"$TMP_DIR/state.json"; then return 1; fi
    bytes=$(stat -c %s "$TMP_DIR/state.json")
    (( bytes<=MAX_STATE_BYTES )) && jq -e '
      .schema==1 and (.files|type)=="object" and (.files|length)<=200000 and
      (.hostRoot==null or ((.hostRoot|type)=="string" and (.hostRoot|startswith("/")))) and
      all(.files|to_entries[];
        (.key|type)=="string" and (.key|contains("/")) and (.key|test("//|/$|^$")|not) and (.key|test("(^/|(^|/)\\.\\.?(/|$))")|not) and
        (.value|type)=="object" and (.value.identity|type)=="array" and (.value.identity|length)==5 and
        all(.value.identity[];type=="string" or type=="number") and
        all(.value|to_entries[]|select(.key=="offset" or .key=="probeAt" or .key=="verifiedAt" or .key=="notBefore" or .key=="chunkSeconds" or .key=="duration");(.value|type)=="number" and .value>=0 and (.value|isfinite)) and
        (.value.duration==null or (.value.duration>0 and .value.duration<=604800 and (.value.offset // 0)<=.value.duration+0.05)) and
        all([.value.issue,.value.auditIssue][]; .==null or ((.id|type)=="string" and (.kind|type)=="string" and
          (.failedRange==null or ((.failedRange.start|type)=="number" and (.failedRange.end|type)=="number" and .failedRange.start>=0 and .failedRange.end>.failedRange.start and .failedRange.end<=604800 and (.failedRange.start|isfinite) and (.failedRange.end|isfinite))))) and
        (.value.issue==null or ((.value.issue|type)=="object" and (.value.issue.id|type)=="string" and (.value.issue.kind|type)=="string")))
      ' "$TMP_DIR/state.json" >/dev/null
}

save_checkpoint() {
    local event="$1"
    printf '%s\n' "$event" | jq -er .payload >"$TMP_DIR/checkpoint.base64" || return 1
    printf '%s\n' "$event" | jq .stats >"$TMP_DIR/checkpoint.stats.json" || return 1
    commit_checkpoint "$TMP_DIR/checkpoint.base64" "$TMP_DIR/checkpoint.stats.json"
}

commit_checkpoint() {
    local payload="$1" stats="$2" temp fd
    temp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 1
    if ! base64 -d "$payload" >"$temp" || ! gzip -t "$temp"; then rm -f "$temp";return 1;fi
    # Validate bounded decompressed JSON before touching either durable copy.
    local validation
    validation=$(mktemp -d /tmp/media-integrity-checkpoint.XXXXXX) || { rm -f "$temp";return 1; }
    if ! ( TMP_DIR="$validation";unpack_state "$temp" ) || ! jq -e 'type=="object"' "$stats" >/dev/null; then
        rm -rf "$validation";rm -f "$temp";return 1
    fi
    local old_valid=false
    if [[ -f "$STATE_FILE" ]] && ( TMP_DIR="$validation";unpack_state "$STATE_FILE" );then old_valid=true;fi
    rm -rf "$validation"
    if ! timeout 10 sync -f "$temp";then rm -f "$temp";return 1;fi
    exec {fd}>"$STATE_EXPORT_LOCK" || { rm -f "$temp";return 1; }
    if ! flock -s -w 5 "$fd"; then exec {fd}>&-;rm -f "$temp";return 75;fi
    if [[ -L "$STATE_FILE" || -L "$PREVIOUS_STATE_FILE" ]];then exec {fd}>&-;rm -f "$temp";return 1;fi
    # Rename the immutable previous current file rather than writing a second
    # copy of the whole queue. If publication is interrupted, load_state resumes
    # the previous validated file; export readers are excluded by their lock.
    if [[ "$old_valid" == true ]] && ! mv -f "$STATE_FILE" "$PREVIOUS_STATE_FILE";then exec {fd}>&-;rm -f "$temp";return 1;fi
    local rc=0
    if ! mv -f "$temp" "$STATE_FILE";then
        [[ ! -f "$PREVIOUS_STATE_FILE" ]] || mv -f "$PREVIOUS_STATE_FILE" "$STATE_FILE"
        rm -f "$temp";rc=1
    fi
    exec {fd}>&-
    ((rc==0)) || return "$rc"
    timeout 10 sync -f "$STATE_FILE" || return 1
    cp "$stats" "$TMP_DIR/stats.json"

}

integrity_notify() {
    local released=false rc=0
    if [[ -n "${INTEGRITY_REPORT_EXPORT_FD:-}" ]];then exec {INTEGRITY_REPORT_EXPORT_FD}>&-;released=true;fi
    usr_ops_notify "$@" || rc=$?
    if [[ "$released" == true ]];then
      exec {INTEGRITY_REPORT_EXPORT_FD}>"$STATE_EXPORT_LOCK" || { INTEGRITY_REPORT_EXPORT_LOST=true;return 75; }
      flock -s -w 20 "$INTEGRITY_REPORT_EXPORT_FD" || { exec {INTEGRITY_REPORT_EXPORT_FD}>&-;INTEGRITY_REPORT_EXPORT_LOST=true;return 75; }
    fi
    return "$rc"
}

write_report() {
    local rc=0
    exec {INTEGRITY_REPORT_EXPORT_FD}>"$STATE_EXPORT_LOCK" || return 1
    if ! flock -s -w 30 "$INTEGRITY_REPORT_EXPORT_FD";then exec {INTEGRITY_REPORT_EXPORT_FD}>&-;return 1;fi
    render_report "$@" || rc=$?
    [[ -z "${INTEGRITY_REPORT_EXPORT_FD:-}" ]] || exec {INTEGRITY_REPORT_EXPORT_FD}>&-
    return "$rc"
}

# Summarise saved identities/progress only. No find/stat/read of library media.
# Folder counts describe parents containing tracked media, not empty directories.
coverage_summary() {
    local libraries
    libraries=$(printf '%s\n' "${LIBRARY_SUBDIRS[@]}" | jq -Rsc 'split("\n")|map(select(length>0))') || return 1
    jq -n --slurpfile state "$TMP_DIR/state.json" --slurpfile stats "$TMP_DIR/stats.json" \
      --arg root "$MEDIA_HOST_ROOT" --argjson libraries "$libraries" --argjson now "$(date +%s)" --argjson days "$RECHECK_DAYS" '
      def tally:
        reduce .[] as $r ({total:0,verified:0,partial:0,metadataOnly:0,attemptedUnverified:0,untouched:0,deferred:0,blocked:0,periodicDue:0,workRemaining:0};
          .total+=1 | .[$r.bucket]+=1 | .deferred+=(if $r.deferred then 1 else 0 end) |
          .blocked+=(if $r.blocked then 1 else 0 end) | .periodicDue+=(if $r.periodicDue then 1 else 0 end) |
          .workRemaining+=(if $r.bucket!="verified" or $r.periodicDue then 1 else 0 end)) |
        .awaitingVerification=(.total-.verified);
      [$state[0].files|to_entries[]|.key as $path|.value as $f|
        (($f.verifiedAt // 0)>0 and $f.coverage=="all_planned_segments_decoded" and $f.verificationPolicy==2 and $f.issue==null and $f.auditIssue==null and ($f.replacementPending // false)==false) as $verified |
        {path:$path,library:($path|split("/")[0]),directory:($path|split("/")|.[0:-1]|join("/")),
         bucket:(if $verified then "verified" elif ($f.offset // 0)>0 then "partial" elif ($f.probeAt // 0)>0 then "metadataOnly" elif ($f.lastAttemptAt // 0)>0 or ($f.verifiedAt // 0)>0 or ($f.previousVerifiedAt // 0)>0 then "attemptedUnverified" else "untouched" end),
         deferred:(($f.notBefore // 0)>$now),blocked:($f.issue!=null or $f.auditIssue!=null),lastAttemptAt:($f.lastAttemptAt // 0),
         periodicDue:($f.cycleLane=="old" or (($f.verifiedAt // 0)>0 and $now-$f.verifiedAt>=$days*86400))}] as $rows |
      ($rows|tally) as $overall |
      [$libraries[] as $library | {name:$library,counts:([$rows[]|select(.library==$library)]|tally),
        inventory:($stats[0].inventoryByLibrary[$library] // {status:(if $stats[0].inventoryComplete==true then "complete" else "not_recorded" end),files:null})}] as $byLibrary |
      [$rows|group_by(.directory)[]|{path:.[0].directory,counts:(tally),lastAttemptAt:(map(.lastAttemptAt)|max)}|
        .status=(if .counts.verified==.counts.total and .counts.periodicDue==0 then "complete" elif .counts.untouched==.counts.total then "untouched" else "in_progress" end)] as $folders |
      {schema:1,capacity:($state[0].capacity // {status:"collecting",samples:0,unknownDurations:null,attention:false}),mediaRoot:($state[0].hostRoot // $root),overall:$overall,libraries:$byLibrary,lastActivity:($state[0].lastActivity // {}),
       run:{startedAt:($stats[0].startedAt // null),finishedAt:($stats[0].finishedAt // null),mode:($stats[0].mode // "not_recorded"),
        uniqueFilesAttempted:($stats[0].uniqueFilesAttempted // null),uniqueFilesOpened:($stats[0].uniqueFilesOpened // null),uniqueMetadataPassed:($stats[0].uniqueMetadataPassed // null),
        uniqueFilesDecoded:($stats[0].uniqueFilesDecoded // null),uniqueFilesPartiallyDecoded:($stats[0].uniqueFilesPartiallyDecoded // null),uniqueFilesCompleted:($stats[0].uniqueFilesCompleted // null)},
       directories:{total:($folders|length),complete:([$folders[]|select(.status=="complete")]|length),inProgress:([$folders[]|select(.status=="in_progress")]|length),
        untouched:([$folders[]|select(.status=="untouched")]|length),blocked:([$folders[]|select(.counts.blocked>0)]|length),deferred:([$folders[]|select(.counts.deferred>0)]|length),
        pending:([$folders[]|select(.counts.workRemaining>0)]|length),
        recent:([$folders[]|select(.lastAttemptAt>0)]|sort_by(-.lastAttemptAt,.path)|.[0:3]),
        pendingExamples:([$folders[]|select(.counts.workRemaining>0)]|sort_by(.lastAttemptAt,.path)|.[0:3]),
        blockedExamples:([$folders[]|select(.counts.blocked>0)]|sort_by(.path)|.[0:3])}} |
      def shown:if .==null then "not recorded" else tostring end;
      def counts_line:
        "total="+(.total|tostring)+"; fully verified="+(.verified|tostring)+"; partial decode="+(.partial|tostring)+"; metadata only="+(.metadataOnly|tostring)+
        "; attempted/unverified="+(.attemptedUnverified|tostring)+"; untouched="+(.untouched|tostring)+"; work remaining="+(.workRemaining|tostring)+
        "; deferred="+(.deferred|tostring)+"; blocked="+(.blocked|tostring)+"; periodic due="+(.periodicDue|tostring);
      def activity_line($label;$record):
        $label+": "+(if $record==null then "not yet recorded" else ($record.path|.[0:350])+" | "+($record.kind|gsub("_";" "))+" | "+($record.epoch|strftime("%Y-%m-%d %H:%M UTC"))+
          (if $record.kind=="full_cycle_passed" or $record.kind=="complete" then " | full current cycle completed" else " | next saved offset="+(($record.nextOffset // 0)|tostring)+" s"+(if $record.duration!=null then " of "+($record.duration|tostring)+" s" else "" end) end) end);
      def folder_line($label):$label+": "+.path[0:240]+" | "+.status+" | verified="+(.counts.verified|tostring)+"/"+(.counts.total|tostring)+"; partial="+(.counts.partial|tostring)+"; untouched="+(.counts.untouched|tostring)+"; blocked="+(.counts.blocked|tostring)+"; periodic due="+(.counts.periodicDue|tostring)+"; remaining="+(.counts.workRemaining|tostring);
      .body=(["", "Progress and coverage (saved state; no additional media reads):",
        "Media root: "+.mediaRoot+"; libraries="+([.libraries[].name]|join(", ")),"Last reported run: "+(if .run.startedAt!=null then (.run.startedAt|strftime("%Y-%m-%d %H:%M UTC")) else "not recorded" end)+"; mode="+.run.mode,
        "Unique files this run: attempted="+(.run.uniqueFilesAttempted|shown)+"; opened="+(.run.uniqueFilesOpened|shown)+"; metadata passed="+(.run.uniqueMetadataPassed|shown)+
        "; with passed decode ranges="+(.run.uniqueFilesDecoded|shown)+"; partially decoded="+(.run.uniqueFilesPartiallyDecoded|shown)+"; fully verified="+(.run.uniqueFilesCompleted|shown),
        "Overall files: "+(.overall|counts_line),
        "Deferred, blocked and periodic-due counts overlap coverage categories. Work remaining counts each file once.",
        "Measured capacity: "+.capacity.status+"; representative runs="+(.capacity.samples|tostring)+"/3 minimum; schedule=Wednesday/Sunday 07:00 Singapore; two hours per run.",
        "Known-duration backlog estimate: "+(if .capacity.knownBacklogDaysLowerBound!=null then ((.capacity.knownBacklogDaysLowerBound|ceil)|tostring)+" days or more at measured net progress" else "not yet available" end)+"; pending files with unknown duration="+(.capacity.unknownDurations|shown)+". This is not a full-library completion promise.",
        "Per-library saved coverage:"]+
        [.libraries[]|"- "+.name+": inventory="+(.inventory.status|gsub("_";" "))+"; "+(.counts|counts_line)]+
        [activity_line("Last attempted file";.lastActivity.attempt),activity_line("Last successful check";.lastActivity.success),activity_line("Last passed decode";.lastActivity.decoded),
        "Media-containing folders: total="+(.directories.total|tostring)+"; complete="+(.directories.complete|tostring)+"; in progress="+(.directories.inProgress|tostring)+"; untouched="+(.directories.untouched|tostring)+
        "; pending="+(.directories.pending|tostring)+"; blocked="+(.directories.blocked|tostring)+"; deferred="+(.directories.deferred|tostring)+". Inventory completion does not mean decoding completion; empty/excluded folders are not counted."]+
        [.directories.recent[]|folder_line("Recent folder")]+[.directories.pendingExamples[]|folder_line("Pending folder example")]+[.directories.blockedExamples[]|folder_line("Blocked folder example")]+[""]|join("\n"))
      ' >"$TMP_DIR/coverage-summary.json"
}

render_report() {
    local status="$1" reason="$2" now temp body importance=normal previous="" last=0 signature attention=false sent=0
    now=$(date +%s)
    if [[ -f "$STATE_FILE" ]] && ! unpack_state "$STATE_FILE";then
        status=FAILED;reason='Current checkpoint invalid; prior validated evidence retained; no healthy result inferred'
        unpack_state "$PREVIOUS_STATE_FILE" || printf '{"schema":1,"files":{}}' >"$TMP_DIR/state.json"
    fi
    jq -e '.schema==1 and (.files|type)=="object"' "$TMP_DIR/state.json" >/dev/null 2>&1 || printf '{"schema":1,"files":{}}' >"$TMP_DIR/state.json"
    [[ -f "$TMP_DIR/stats.json" ]] || printf '{}' >"$TMP_DIR/stats.json"
    if recovery_valid;then cp "$RECOVERY_FILE" "$TMP_DIR/recovery-report.json";else printf '{"schema":1,"workflow":"arr-native","actions":{}}' >"$TMP_DIR/recovery-report.json";fi
    if [[ -f "$STATE_DIR/notified.json" ]];then cp "$STATE_DIR/notified.json" "$TMP_DIR/delivery.json";else printf '{}' >"$TMP_DIR/delivery.json";fi
    coverage_summary || return 1
    temp=$(mktemp "$STATE_DIR/.report.XXXXXX") || return 1
    jq -n --slurpfile state "$TMP_DIR/state.json" --slurpfile stats "$TMP_DIR/stats.json" --slurpfile journal "$TMP_DIR/recovery-report.json" --slurpfile receipt "$TMP_DIR/delivery.json" --slurpfile progress "$TMP_DIR/coverage-summary.json" \
      --argjson enabled "$AUTO_RECOVERY_ENABLED" --argjson now "$now" --argjson max "$NOTIFY_MAX_ITEMS" --arg status "$status" --arg reason "$reason" --arg mode "$MODE" --arg note "$RECOVERY_NOTE" '
      def replacement_candidate:
        .value as $f | $f.issue as $i |
        (.issueSlot // "issue")!="auditIssue" and $i.kind=="decode_error" and $i.proofVersion==4 and $i.origin=="decode" and
        $i.confirmationMethod=="normal-isolated-streams-v1" and $i.confirmed==true and
        ($i.confirmedRuns // 0)>=2 and $i.identity==$f.identity and ($i.confirmationKey|type)=="string" and
        any($i.streamEvidence[]?; .primary==true and .kind=="decode_error" and .exit>0);
      [$state[0].files|to_entries[]|. as $file|["issue","auditIssue"][] as $slot|select($file.value[$slot]!=null)|
        $file+{issueSlot:$slot,value:($file.value+{issue:$file.value[$slot]})}] as $rawIssues |
      ($rawIssues|map(.notificationPriority=(if replacement_candidate then 0 elif .value.issue.kind=="read_error" then 1 elif .value.issue.alertable!=false then 2 else 3 end))|sort_by(.notificationPriority,(if (.value.issue.id as $id|($receipt[0].displayedFindingIds // []|index($id))==null) then 0 else 1 end),(.value.issue.firstSeen // 0),.key)) as $issues |
      [$issues[]|select(replacement_candidate)] as $candidates |
      [$issues[]|select(.value.issue.alertable!=false)] as $actionable |
      ([$actionable|group_by(.notificationPriority)[]|.[0]]|.[0:$max]) as $reserved |
      (($reserved+[$actionable[]|select(.value.issue.id as $id|([$reserved[].value.issue.id]|index($id))==null)])|.[0:$max]|sort_by(.notificationPriority,.key)) as $displayed |
      [$state[0].resolved[]?|select((.resolution // "")|startswith("Legacy probe-only"))|
        .notice=("reclassified:"+.id+":"+(.resolvedAt|tostring))|
        select(.notice as $k|($receipt[0].recoveryEvents // []|index($k))==null)] as $reclassified |
      [$journal[0].actions|to_entries[]|.notice=(.key+":"+.value.status+":"+.value.reason+(if .value.status=="verifying" and (.value.verificationDeadlineAt // 0)>0 and $now>=.value.verificationDeadlineAt then ":native_retention_elapsed" else "" end))] as $jobs |
      [$jobs[]|select(.value.status=="required" or .value.status=="downloading" or .value.status=="blocked" or .value.status=="review" or .value.status=="recovered" or .value.status=="cancelled" or .value.status=="resolved" or .value.status=="retry_wait" or
        (.value.status=="verifying" and $now>=(.value.verificationAttentionAt // ((.value.importedAt // .value.startedAt)+86400))))|
        select(.notice as $k|($receipt[0].recoveryEvents // []|index($k))==null)] as $notices |
      [$jobs[]|select(.value.status=="required" or .value.status=="blocked" or .value.status=="review" or .value.status=="retry_wait" or (.value.status=="verifying" and $now>=(.value.verificationAttentionAt // ((.value.importedAt // .value.startedAt)+86400))))] as $attention |
      (if $status=="FAILED" then "FAILED" elif ($issues|length)>0 or ($attention|length)>0 or $note!="" or $progress[0].capacity.attention==true then "WARNING" else $status end) as $effective |
      {schema:1,name:"media_integrity_audit",progress:($progress[0]|del(.body)),status:$effective,epoch:$now,mode:$mode,recoveryEnabled:$enabled,stats:$stats[0],
       coverage:{knownFiles:$progress[0].overall.total,fullyVerified:$progress[0].overall.verified,
        pendingVerification:$progress[0].overall.awaitingVerification,
        oldestPendingObservedAt:([$state[0].files[]|select((.verifiedAt // 0)==0)|.observedAt // empty]|min),
        pendingAgeUnknown:([$state[0].files[]|select((.verifiedAt // 0)==0 and (.observedAt // 0)==0)]|length)},
       coverageStatus:(if ($progress[0].overall.awaitingVerification // 0)>0 then "INCOMPLETE" else "CURRENT_CYCLE_COMPLETE" end),
       auditAttention:($progress[0].capacity.attention==true or $note!="" or ($stats[0].inventoryErrors // 0)>0 or ($stats[0].inventoryComplete==false and ($stats[0].targeted // false)!=true)),recoveryActions:($jobs|length),recoveryAttention:($attention|length),replacementCandidates:($candidates|length),activeFindings:($issues|length),actionableFindings:($actionable|length),recoveries:([$jobs[]|select(.value.status=="recovered")]|length),
       findingKeys:[$actionable|sort_by(.value.issue.id)[]|.value.issue.id+":"+.value.issue.kind+":"+(.value.issue.confirmed|tostring)+":"+((.value.issue.confirmedRuns // 0)>=2|tostring)],
       recoveryAttentionKeys:[$attention[].notice],displayedFindingIds:[$displayed[].value.issue.id],noticeKeys:([$notices[:$max][].notice]+[$reclassified[:$max][].notice]),
       summary:("Media integrity: "+$effective+"; findings="+($issues|length|tostring)+"; replacement candidates="+($candidates|length|tostring)+"; replacement updates="+($notices|length|tostring)+"; fully verified="+($progress[0].overall.verified|tostring)+"/"+($progress[0].overall.total|tostring)),
       body:(["Media integrity audit: "+$effective,"Automatic replacement: "+(if $enabled then "ENABLED" else "DISABLED; original files remain unchanged" end),
        "Run: "+$mode+"; "+$reason,"Finding categories: replacement candidates="+($candidates|length|tostring)+"; audit/review findings="+(($issues|length)-($candidates|length)|tostring),"Checks passed: quick="+(($stats[0].quickPassed // 0)|tostring)+"; ranges="+(($stats[0].segmentsPassed // 0)|tostring)+"; full planned-range cycles="+(($stats[0].cyclesCompleted // 0)|tostring),
        "Coverage: known files="+($progress[0].overall.total|tostring)+"; fully decoded current versions="+($progress[0].overall.verified|tostring)+"; pending current-cycle verification="+($progress[0].overall.awaitingVerification|tostring),
        $progress[0].body,"Original files and monitoring are retained until native Arr replacement. Arr owns imports and recycling; this script never moves/deletes library media or forces import.",
        "State note: "+$note,"", "Replacement actions and results:"]+
       [$notices[:$max][]|"- "+.value.app+" | "+.value.path+" | "+.value.status+
        "\n  Incident: integrity:"+.key+"\n  Action/evidence: "+.value.reason+"\n  Target IDs: "+(.value.targets|tostring)+"; original file ID: "+(.value.fileId|tostring)+
        "\n  Selected release: "+(.value.selected.title // "none; original retained")+"; download ID: "+(.value.downloadId // "none")+
        "\n  Replacement files: "+((.value.replacementFiles // []|map({path,fileId}))|tostring)+
        "\n  Attempts: "+((.value.attempts // []|length)|tostring)+"; retry no earlier than epoch: "+((.value.retryAt // 0)|tostring)+
        "\n  Native recycling retention days: "+((.value.binRetentionDays // "unknown")|tostring)+"; verification deadline: "+(if (.value.verificationDeadlineAt // 0)>0 then (.value.verificationDeadlineAt|strftime("%Y-%m-%d %H:%M UTC")) else "no timed native cleanup verified" end)+
        "\n  Last API diagnostic: "+((.value.lastError // {})|tostring)+"\n  Recent transitions: "+((.value.events[-5:] // []|map(.status+": "+.reason))|join("; "))]+
       ["", "Evidence reclassifications (media unchanged):"]+
       [$reclassified[:$max][]|"- "+.path+"\n  Finding ID: "+.id+"\n  Action: "+.resolution]+
       ["", "Current actionable findings (replacement/storage issues first):", "Showing "+([$displayed[]]|length|tostring)+" of "+($actionable|length|tostring)+" actionable findings; "+((($actionable|length)-$max)|if .>0 then tostring else "0" end)+" omitted. Quiet transient findings="+(($issues|length)-($actionable|length)|tostring)+"; all remain in saved state."]+
       [$displayed[]|"- "+.key+" | "+.value.issue.kind+"\n  Finding ID: "+.value.issue.id+"; separate confirming runs: "+((.value.issue.confirmedRuns // 0)|tostring)+
        "\n  Stream checks: "+((.value.issue.streamEvidence // []|map("#"+((.index // "unknown")|tostring)+" "+(.type // "stream")+" ("+(.codec // "unknown codec")+"; "+(if .primary then "primary" else "additional" end)+"): "+.kind+"; exit="+(.exit|tostring)+"; range="+(if .complete then "completed" else "not completed" end)))|join("; "))+"\n  Evidence: "+((.value.issue.evidence // "")|.[0:650])+"\n  Next action: "+
        (if replacement_candidate then "Primary-stream decode failure confirmed by strict and normal checks in two independent runs. Replacement eligible only after exact Arr safety checks. "+(if $enabled then "Exact-rule selection is bounded; see job outcome." else "Recovery disabled; review evidence before enabling automation." end)
         elif .value.issue.kind=="recoverable_media_defect" then "Strict check failed but normal stream checks completed. Possible recoverable defect; review required, no automatic replacement." elif .value.issue.kind=="auxiliary_track_error" then "Failure is confined to an additional track. Main selected streams were checked separately; no automatic replacement." elif .value.issue.kind=="decode_error" then "Suspected decode failure; another independent matching observation is required. No replacement authorized." elif .value.issue.kind=="read_error" then "Storage read failed. Check the array, drive or mount before retrying; downloading another copy is not authorized." elif .value.issue.alertable==false then "Transient audit limitation; one bounded retry was allowed and future verification is pending. No replacement authorized; email is suppressed unless persistent." else "Audit could not verify this range. Review access, container, tool or resource evidence; no replacement authorized." end)]+
       ["", "Full verification requires all planned decode ranges; a download/import event alone does not prove integrity. Native bin retention continues independently. Verification alerts before the observed native retention expires (or after 24 hours when no deadline applies); no rollback is guaranteed. --recovery-status includes bounded transition history."]|join("\n"))}' >"$temp" || return 1
    body=$(jq -r .body "$temp"|head -c 23000|iconv -f UTF-8 -t UTF-8 -c || true)
    printf '%s\n' "$body" >"$STATE_DIR/latest-report.txt.new" && mv "$STATE_DIR/latest-report.txt.new" "$STATE_DIR/latest-report.txt" || return 1
    signature=$(jq -c '{status,findingKeys,recoveryAttentionKeys,capacityKey:.progress.capacity.status,note:$note,reason:$reason}' --arg note "$RECOVERY_NOTE" --arg reason "$( [[ "$status" != FAILED ]] || printf '%s' "$reason" )" "$temp"|sha256sum|awk '{print $1}')
    previous=$(jq -r '.signature // ""' "$TMP_DIR/delivery.json");last=$(jq -r '.sentAt // 0' "$TMP_DIR/delivery.json")
    jq -e '.auditAttention==true or .actionableFindings>0 or .recoveryAttention>0 or .status=="FAILED" or (.status=="WARNING" and .activeFindings==0)'  "$temp" >/dev/null && attention=true
    if [[ "$MODE" != inventory ]] && { jq -e '.noticeKeys|length>0' "$temp" >/dev/null || [[ "$attention" == true && ( "$signature" != "$previous" || $((now-last)) -ge NOTIFICATION_REMINDER_SECONDS ) ]]; };then
        [[ "$attention" != true ]] || importance=warning;[[ "$status" != FAILED ]] || importance=alert
        jq -n --arg body "$body" --arg signature "$signature" --argjson epoch "$now" '{schema:1,body:$body,signature:$signature,epoch:$epoch}' >"$STATE_DIR/pending-notification.json.new" && mv "$STATE_DIR/pending-notification.json.new" "$STATE_DIR/pending-notification.json" || return 1
        if [[ -x "$NOTIFY_BIN" ]] && integrity_notify timeout 30 "$NOTIFY_BIN" -i "$importance" -s 'Media Integrity Audit' -d "$(jq -r .summary "$temp")" -m "$body";then
            jq --arg signature "$signature" --argjson sentAt "$now" --slurpfile report "$temp" '.signature=$signature | .sentAt=$sentAt | .recoveryEvents=((.recoveryEvents // [])+$report[0].noticeKeys|unique|.[-512:]) | .displayedFindingIds=$report[0].displayedFindingIds' "$TMP_DIR/delivery.json" >"$STATE_DIR/notified.json.new" && mv "$STATE_DIR/notified.json.new" "$STATE_DIR/notified.json" || return 1
            rm -f "$STATE_DIR/pending-notification.json";sent=1
        else log WARNING 'Grouped integrity notification failed; delivery remains pending';fi
    elif [[ "$attention" == false ]];then rm -f "$STATE_DIR/pending-notification.json";fi
    [[ "${INTEGRITY_REPORT_EXPORT_LOST:-false}" != true ]] || return 75
    local completed=0 installed="$now" first="$now"
    if [[ -f "$STATUS_DIR/media_integrity_audit.json" ]];then
        completed=$(jq -r '.lastCompletedScanAt // 0' "$STATUS_DIR/media_integrity_audit.json");installed=$(jq -r '.installedAt // .epoch' "$STATUS_DIR/media_integrity_audit.json");first=$(jq -r '.firstScheduledAt // .epoch' "$STATUS_DIR/media_integrity_audit.json")
    fi
    if [[ "$MODE" == scan && "$WORKER_FINISHED" == true && "$status" != FAILED && "$status" != DEFERRED ]] && jq -e '.inventoryComplete==true' "$TMP_DIR/stats.json" >/dev/null;then completed="$now";fi
    local progress_completed=0
    [[ ! -f "$STATUS_DIR/media_integrity_audit.json" ]] || progress_completed=$(jq -r '.lastProgressScanAt // 0' "$STATUS_DIR/media_integrity_audit.json")
    if [[ "$MODE" == scan && "$WORKER_FINISHED" == true && "$status" != FAILED ]] && jq -e '.inventoryComplete==true and ((.segmentsPassed // 0)>0 or (.quickPassed // 0)>0)' "$TMP_DIR/stats.json" >/dev/null;then progress_completed="$now";fi
    local stalled=0
    [[ ! -f "$STATUS_DIR/media_integrity_audit.json" ]] || stalled=$(jq -r '.stalledCompletedRuns // 0' "$STATUS_DIR/media_integrity_audit.json")
    if [[ "$MODE" == scan && "$WORKER_FINISHED" == true && "$status" != DEFERRED && "$status" != FAILED ]];then
      if jq -e '.coverage.pendingVerification>0 and (.stats.segmentsPassed // 0)==0 and (.stats.cyclesCompleted // 0)==0 and (.stats.quickPassed // 0)==0' "$temp" >/dev/null;then stalled=$((stalled+1));else stalled=0;fi
    fi
    jq --argjson stalled "$stalled" '.stalledCompletedRuns=$stalled' "$temp" >"$temp.next" && mv "$temp.next" "$temp" || return 1
    local delivery=suppressed;((sent==0)) || delivery=sent;[[ ! -f "$STATE_DIR/pending-notification.json" ]] || delivery=failed
    local current_schedule
    current_schedule=$(usr_scripts_schedule_evidence media_integrity_audit) || current_schedule='{"verified":false}'
    jq --argjson schedule "$current_schedule" --arg notification "$delivery" --arg version "$SCRIPT_VERSION" --argjson progress "$progress_completed" --argjson completed "$completed" --argjson installed "$installed" --argjson first "$first" '.+{notification:$notification,scriptVersion:$version,schedule:$schedule,lastCompletedScanAt:$completed,lastProgressScanAt:$progress,installedAt:$installed,firstScheduledAt:$first}' "$temp" >"$STATUS_DIR/.media-integrity-audit.new" && mv "$STATUS_DIR/.media-integrity-audit.new" "$STATUS_DIR/media_integrity_audit.json" || return 1
    RUN_REPORT_WRITTEN=true;log INFO "$(jq -r .summary "$temp")";rm -f "$temp"
}

# Arr-native recovery never moves/unlinks library media, deletes file records,
# changes monitoring, forces imports or purges bins. Only POST /release is allowed.
recovery_valid() { recovery_document_valid "$RECOVERY_FILE"; }
recovery_document_valid() {
    local document="$1"
    [[ -f "$document" && ! -L "$document" ]] || return 1
    jq -e '.schema==1 and .workflow=="arr-native" and (.actions|type)=="object" and all(.actions|to_entries[];
      (.key|test("^[a-f0-9]{64}$")) and (.value.app=="Sonarr" or .value.app=="Radarr") and
      (.value.parentId|type)=="number" and .value.parentId>0 and (.value.fileId|type)=="number" and .value.fileId>0 and
      (.value.path|type)=="string" and (.value.path|startswith("/")|not) and all(.value.path|split("/")[];.!="" and .!="." and .!="..") and
      (.value.identity|type)=="array" and (.value.identity|length)==5 and all(.value.identity[];type=="string" and test("^[0-9]+$")) and
      (.value.targets|type)=="array" and (.value.targets|length)>0 and all(.value.targets[];type=="number" and .>0) and
      (.value.status as $s|["required","selected","grab_intent","downloading","imported","verifying","recovered","blocked","review","cancelled","resolved","retry_wait"]|index($s))!=null and
      (.value.events|type)=="array" and (.value.events|length)<=32)' "$document" >/dev/null
}
recovery_update() {
    local filter="$1" tmp fd previous="${RECOVERY_FILE%.json}.previous.json";shift
    tmp=$(mktemp "$STATE_DIR/.recovery.XXXXXX") || return 1
    jq "$@" "$filter" "$RECOVERY_FILE" >"$tmp" || { rm -f "$tmp";return 1; }
    # Journal only meaningful transitions, capped per action; polling/progress
    # timestamps never create an unbounded event stream or new notification.
    jq --slurpfile old "$RECOVERY_FILE" --argjson now "$(date +%s)" '.actions |= with_entries(
      .key as $id | if ($old[0].actions[$id].status!="" and ($old[0].actions[$id].status!=.value.status or $old[0].actions[$id].reason!=.value.reason)) then
       .value.events=((.value.events // [])+[{at:$now,status:.value.status,reason:.value.reason}]|.[-32:]) else . end)' "$tmp" >"$tmp.events" && mv "$tmp.events" "$tmp" || return 1
    recovery_document_valid "$tmp" || { rm -f "$tmp";return 1; }
    if jq -e --slurpfile next "$tmp" '.==$next[0]' "$RECOVERY_FILE" >/dev/null;then rm -f "$tmp";return 0;fi
    exec {fd}>"$STATE_EXPORT_LOCK" || return 1
    flock -s -w 5 "$fd" && recovery_valid && cp "$RECOVERY_FILE" "$previous.new" && sync -f "$previous.new" && mv -f "$previous.new" "$previous" && sync -f "$tmp" && mv -f "$tmp" "$RECOVERY_FILE" && sync -f "$RECOVERY_FILE"
    local rc=$?;exec {fd}>&-;rm -f "$tmp";return "$rc"
}
recovery_set() {
    recovery_update 'if .actions[$id].status==$status and .actions[$id].reason==$reason then . else .actions[$id].status=$status | .actions[$id].reason=$reason | .actions[$id].updatedAt=$now end' \
      --arg id "$1" --arg status "$2" --arg reason "$3" --argjson now "$(date +%s)"
}
# Retry idempotent reads only. Requests and diagnostics never include API keys.
recovery_api() {
    local method="$1" endpoint="$2" output="$3" payload="${4:-}" rc=0 attempt limit=1 remaining seconds args=()
    RECOVERY_HTTP=000;RECOVERY_LAST_OPERATION="$method $endpoint";RECOVERY_LAST_EXIT=0
    [[ "$method" == GET || ( "$method" == POST && "$endpoint" == /release ) ]] || return 2
    [[ "$method" != GET ]] || limit=2
    [[ "$method" != POST ]] || args+=(--header 'Content-Type: application/json' --data-binary "@$payload")
    for ((attempt=1;attempt<=limit;attempt++));do
        seconds=10;[[ "$endpoint" != /release\?* ]] || seconds=30
        if ((RECOVERY_DEADLINE>0));then remaining=$((RECOVERY_DEADLINE-$(date +%s)));((remaining>0)) || { RECOVERY_LAST_EXIT=124;return 124; };((remaining>=seconds)) || seconds=$remaining;fi
        rc=0
        RECOVERY_HTTP=$(curl --silent --show-error --retry 0 --connect-timeout 4 --max-time "$seconds" --max-filesize 67108864 \
          --request "$method" --header "X-Api-Key: $RECOVERY_KEY" --output "$output" --write-out '%{http_code}' \
          "${args[@]}" "$RECOVERY_ROOT$endpoint" 2>"$TMP_DIR/recovery-curl.error") || rc=$?
        RECOVERY_LAST_EXIT=$rc
        if ((rc==0)) && [[ "$RECOVERY_HTTP" == 2?? || ( "$method" == GET && "$RECOVERY_HTTP" == 404 ) ]];then return 0;fi
        [[ "$method" == GET && ( "$rc" == 28 || "$rc" == 7 || "$rc" == 6 || "$RECOVERY_HTTP" == 429 || "$RECOVERY_HTTP" == 502 || "$RECOVERY_HTTP" == 503 || "$RECOVERY_HTTP" == 504 ) ]] || break
        ((attempt>=limit)) || sleep 1
    done
    return 1
}
recovery_api_diagnostic() {
    local id="$1" detail="$2"
    recovery_update '.actions[$id].lastError={at:$now,detail:$detail,operation:$operation,http:$http,exit:$exit}' --arg id "$id" --arg detail "$detail" \
      --arg operation "${RECOVERY_LAST_OPERATION:-native response validation}" --arg http "${RECOVERY_HTTP:-000}" --argjson exit "${RECOVERY_LAST_EXIT:-0}" --argjson now "$(date +%s)"
}
recovery_connection() {
    case "$1" in Sonarr) RECOVERY_ROOT="$SONARR_API_ROOT";RECOVERY_KEY="$SONARR_API_KEY";;Radarr) RECOVERY_ROOT="$RADARR_API_ROOT";RECOVERY_KEY="$RADARR_API_KEY";;*) return 1;;esac
    [[ -n "$RECOVERY_KEY" && "$RECOVERY_KEY" != PUT_YOUR_* && "$RECOVERY_ROOT" =~ ^https?://[^[:space:]]+/api/v(3|5)$ ]]
}
recovery_file_tool() {
    [[ "$1" == identity ]] || return 2
    timeout 10 docker exec --user 99:100 "$BAZARR_CONTAINER" python3 -c '
import json,os,stat,sys
root,rel=sys.argv[1:];p=os.path.join(root,rel)
if not rel or rel.startswith("/") or any(v in ("",".","..") for v in rel.split("/")) or os.path.realpath(p)!=p:raise ValueError("unsafe/symlinked media path")
s=os.stat(p,follow_symlinks=False)
if not stat.S_ISREG(s.st_mode):raise ValueError("not regular media")
print(json.dumps([str(v) for v in (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)]))
' "$MEDIA_CONTAINER_ROOT" "$2" </dev/null
}
recovery_quiet_app() {
    local parent="$1" kind="$2" queue="$TMP_DIR/recovery-queue.json" commands="$TMP_DIR/recovery-commands.json" health="$TMP_DIR/recovery-health.json"
    recovery_api GET '/health' "$health" && [[ "$RECOVERY_HTTP" == 200 ]] && jq -e 'type=="array" and all(.[]; (.type // ""|ascii_downcase) as $level | ["notice","info"]|index($level)!=null)' "$health" >/dev/null || return 1
    recovery_api GET '/queue?page=1&pageSize=1000&includeUnknownSeriesItems=true&includeUnknownMovieItems=true' "$queue" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
    jq -e --arg field "$kind" --argjson parent "$parent" '
      (.records|type)=="array" and (.totalRecords|type)=="number" and .totalRecords==(.records|length)
      and all(.records[]; (.[$field] // 0)>0 and .[$field]!=$parent)' "$queue" >/dev/null || return 1
    recovery_api GET '/command' "$commands" && [[ "$RECOVERY_HTTP" == 200 ]] && jq -e 'type=="array" and all(.[]; ((.status // ""|ascii_downcase) as $s | ["completed","failed","cancelled","aborted"] | index($s))!=null)' "$commands" >/dev/null
}
recovery_platform_ready() {
    local version
    version=$(sed -n 's/^version="\([^"]*\)"/\1/p' /etc/unraid-version 2>/dev/null) || return 1
    [[ "$version" == 7.* ]]
}
recovery_base_plan() {
    local candidate="$1" output="$2" app relative expected catalog parent files targets file_id parent_id path
    printf '[]\n' >"$TMP_DIR/recovery-linked.json"
    relative=$(jq -r .key "$candidate"); expected="$TMP_DIR/recovery-expected.json"
    jq '.value.identity' "$candidate" >"$expected"
    recovery_capacity_ready "$(jq -r '.[2]' "$expected")" || return 1
    case "$relative" in movies/*) app=Radarr;; series/*) app=Sonarr;; *) return 1;; esac
    recovery_connection "$app" || return 1
    catalog="$TMP_DIR/recovery-catalog.json"; files="$TMP_DIR/recovery-files.json"; targets="$TMP_DIR/recovery-targets.json"
    if [[ "$app" == Sonarr ]]; then
        recovery_api GET /series "$catalog" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        path="$SONARR_MEDIA_ROOT/$relative"
        jq --arg path "$path" '[.[]|select(.monitored==true) | . as $parent | select($path|startswith($parent.path+"/"))]' "$catalog" >"$TMP_DIR/recovery-parent.json" || return 1
        [[ $(jq length "$TMP_DIR/recovery-parent.json") == 1 ]] || return 1
        parent_id=$(jq -r '.[0].id' "$TMP_DIR/recovery-parent.json")
        recovery_api GET "/episodefile?seriesId=$parent_id" "$files" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        jq --arg path "$path" '[.[]|select(.path==$path)]' "$files" >"$TMP_DIR/recovery-match.json" || return 1
        [[ $(jq length "$TMP_DIR/recovery-match.json") == 1 ]] || return 1
        file_id=$(jq -r '.[0].id' "$TMP_DIR/recovery-match.json")
        recovery_api GET "/episode?seriesId=$parent_id" "$targets" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        jq --argjson file "$file_id" --argjson parent "$parent_id" '[.[]|select(.episodeFileId==$file and .seriesId==$parent)]' "$targets" >"$TMP_DIR/recovery-linked.json" || return 1
        jq -e 'length>0 and all(.[]; .monitored==true and .hasFile==true and .id>0)' "$TMP_DIR/recovery-linked.json" >/dev/null || return 1
        jq -e --slurpfile parent "$TMP_DIR/recovery-parent.json" 'all(.[]; .seasonNumber as $n | any($parent[0][0].seasons[]; .seasonNumber==$n and .monitored==true))' "$TMP_DIR/recovery-linked.json" >/dev/null || return 1
        jq '[.[].id]|sort|unique' "$TMP_DIR/recovery-linked.json" >"$targets.ids"
    else
        recovery_api GET /movie "$catalog" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        path="$RADARR_MEDIA_ROOT/$relative"
        jq --arg path "$path" '[.[]|select(.monitored==true and .hasFile==true and .movieFile.path==$path and .movieFileId==.movieFile.id)]' "$catalog" >"$TMP_DIR/recovery-match.json" || return 1
        [[ $(jq length "$TMP_DIR/recovery-match.json") == 1 ]] || return 1
        parent_id=$(jq -r '.[0].id' "$TMP_DIR/recovery-match.json");file_id=$(jq -r '.[0].movieFileId' "$TMP_DIR/recovery-match.json")
        jq '[.[0].id]' "$TMP_DIR/recovery-match.json" >"$targets.ids"
    fi
    [[ "$file_id" =~ ^[1-9][0-9]*$ && "$parent_id" =~ ^[1-9][0-9]*$ ]] || return 1
    recovery_quiet_app "$parent_id" "$([[ "$app" == Sonarr ]] && printf seriesId || printf movieId)" || return 1
    recovery_file_tool identity "$relative" >"$TMP_DIR/recovery-identity.json" || return 1
    jq -e --slurpfile expected "$expected" '.==$expected[0]' "$TMP_DIR/recovery-identity.json" >/dev/null || return 1
    jq -n --arg app "$app" --arg path "$relative" --arg apiPath "$path" --argjson parent "$parent_id" --argjson file "$file_id" \
      --slurpfile candidate "$candidate" --slurpfile ids "$targets.ids" --argjson now "$(date +%s)" \
      '{app:$app,path:$path,apiPath:$apiPath,parentId:$parent,fileId:$file,targets:$ids[0],identity:$candidate[0].value.identity,
        finding:$candidate[0].value.issue,status:"prepared",startedAt:$now,updatedAt:$now,reason:"Exact monitored Arr file/targets and unchanged decoder identity verified"}' >"$output"
}
recovery_runtime_matches() {
    local current
    current=$(timeout 12 docker exec --user 99:100 "$BAZARR_CONTAINER" sh -c 'ffmpeg -version | sed -n "1p"; ffprobe -version | sed -n "1p"') || return 1
    jq -e --arg toolset "$current" '.toolset==$toolset' "$TMP_DIR/state.json" >/dev/null
}

recovery_select_release() {
    timeout 12 docker exec -i --user 99:100 "$BAZARR_CONTAINER" python3 -c '
import json,re,sys
x=json.load(sys.stdin);j=x['\''job'\''];profile=j['\''profile'\''];old=j['\''originalMedia'\''];app=j['\''app'\'']
# Preserve native profile ordering, including grouped qualities. Unknown quality
# IDs, source metadata, rejection formats and episode mappings fail closed.
weights={}
for i,g in enumerate(profile['\''items'\'']):
 for q in ([g.get('\''quality'\'')] if not g.get('\''items'\'') else [v.get('\''quality'\'') for v in g['\''items'\'']]):
  if q and g.get('\''allowed'\'') is True:weights[q['\''id'\'']]=i
oldq=old['\''quality'\'']['\''quality'\'']['\''id'\''];minimum=profile['\''minFormatScore'\''];previous=old.get('\''customFormatScore'\'')
if oldq not in weights or not isinstance(previous,int):raise ValueError('\''original quality/format score unavailable'\'')
allowed={'\''diskCutoffMet'\'','\''diskHigherPreference'\'','\''diskHigherRevision'\'','\''diskCustomFormatCutoffMet'\'','\''diskCustomFormatScore'\'','\''diskCustomFormatScoreIncrement'\''}
patterns=[r'\''Existing file meets cutoff: .+'\'',r'\''Existing file on disk meets (?:quality|Custom Format) cutoff: .+'\'',r'\''Existing file on disk is of equal or higher (?:preference|revision): .+'\'',r'\''Existing file on disk has a equal or higher Custom Format score: .+'\'',r'\''Existing file on disk has Custom Format score within Custom Format score increment: .+'\'']
selected=[]
for r in x['\''releases'\'']:
 try:
  release=r['\''release'\''] if app=='\''Sonarr'\'' else r
  decision=r['\''decision'\''] if app=='\''Sonarr'\'' else r
  parsed=r['\''parsedInfo'\''] if app=='\''Sonarr'\'' else r
  q=parsed['\''quality'\''];qid=q['\''quality'\'']['\''id'\''];score=r['\''customFormatScore'\'']
  if release.get('\''protocol'\'','\'''\'').lower()!='\''usenet'\'' or not isinstance(release.get('\''guid'\''),str) or not release['\''guid'\''] or not isinstance(release.get('\''indexerId'\''),int) or release['\''indexerId'\'']<=0:continue
  if not isinstance(release.get('\''title'\''),str) or not release['\''title'\''] or release.get('\''size'\'',0)<=0 or r.get('\''downloadAllowed'\'') is not True or decision.get('\''temporarilyRejected'\'') is not False:continue
  if qid not in weights or weights[qid]<weights[oldq] or not isinstance(score,int) or score<minimum:continue
  if weights[qid]==weights[oldq] and score<previous:continue
  revision=lambda z:(z.get('\''real'\'',0),z.get('\''version'\'',1),bool(z.get('\''isRepack'\'',False)))
  if qid==oldq and revision(q.get('\''revision'\'',{}))<revision(old['\''quality'\''].get('\''revision'\'',{})):continue
  if old.get('\''languages'\'') and sorted(v['\''id'\''] for v in r.get('\''languages'\'',[]))!=sorted(v['\''id'\''] for v in old['\''languages'\'']):continue
  if any(v.get('\''guid'\'')==release['\''guid'\''] or v.get('\''title'\'')==release['\''title'\''] for v in j.get('\''failedReleases'\'',[])):continue
  if release['\''title'\'']==old.get('\''sceneName'\'') or (r.get('\''history'\'') or {}).get('\''grabbed'\''):continue
  reasons=decision.get('\''rejections'\'')
  if not isinstance(reasons,list):continue
  if not reasons and decision.get('\''approved'\'') is not True:continue
  if app=='\''Sonarr'\'':
   if any(not isinstance(v,dict) or v.get('\''reason'\'') not in allowed for v in reasons):continue
   mapped=r['\''mappedEpisodeInfo'\'']
   if r.get('\''mappedSeriesId'\'')!=j['\''parentId'\''] or sorted(v['\''id'\''] for v in mapped)!=sorted(j['\''targets'\'']) or parsed.get('\''fullSeason'\'') is not False:continue
   expected={v['\''id'\'']:(v['\''seasonNumber'\''],v['\''episodeNumber'\'']) for v in j['\''targetDetails'\'']}
   if any(expected[v['\''id'\'']]!=(v['\''seasonNumber'\''],v['\''episodeNumber'\'']) for v in mapped):continue
   payload={'\''guid'\'':release['\''guid'\''],'\''indexerId'\'':release['\''indexerId'\''],'\''searchInfo'\'':{'\''episodeId'\'':j['\''targets'\''][0]}}
  else:
   if any(not isinstance(v,str) or not any(re.fullmatch(p,v) for p in patterns) for v in reasons):continue
   if r.get('\''mappedMovieId'\'')!=j['\''parentId'\''] or r.get('\''movieRequested'\'') is not True:continue
   if old.get('\''edition'\'') and r.get('\''edition'\'')!=old['\''edition'\'']:continue
   payload={'\''guid'\'':release['\''guid'\''],'\''indexerId'\'':release['\''indexerId'\''],'\''movieId'\'':j['\''parentId'\'']}
  selected.append({'\''title'\'':release['\''title'\''],'\''guid'\'':release['\''guid'\''],'\''indexerId'\'':release['\''indexerId'\''],'\''size'\'':release['\''size'\''],'\''quality'\'':q,'\''score'\'':score,'\''rejections'\'':reasons,'\''payload'\'':payload,'\''rank'\'':r.get('\''releaseWeight'\'',1000000)})
 except (KeyError,TypeError,ValueError):continue
selected.sort(key=lambda v:v['\''rank'\''])
print(json.dumps(selected[0] if selected else None))
'
}
recovery_plan() {
    local candidate="$1" output="$2" base="$TMP_DIR/native-base.json" owner="$TMP_DIR/native-owner.json" media="$TMP_DIR/native-original.json" profile="$TMP_DIR/native-profile.json" app parent file kind pid
    recovery_base_plan "$candidate" "$base" || return 1
    app=$(jq -r .app "$base");parent=$(jq -r .parentId "$base");file=$(jq -r .fileId "$base")
    kind=movie;[[ "$app" != Sonarr ]] || kind=series
    recovery_api GET "/$kind/$parent" "$owner" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
    jq -e --argjson parent "$parent" '.id==$parent and .monitored==true and (.tags|length)==0 and (.qualityProfileId|type)=="number"' "$owner" >/dev/null || return 1
    kind=moviefile;[[ "$app" != Sonarr ]] || kind=episodefile
    recovery_api GET "/$kind/$file" "$media" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
    jq -e --slurpfile job "$base" '.id==$job[0].fileId and .path==$job[0].apiPath and (.customFormatScore|type)=="number"' "$media" >/dev/null || return 1
    pid=$(jq -r .qualityProfileId "$owner")
    recovery_api GET "/qualityprofile/$pid" "$profile" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
    jq -e --argjson pid "$pid" '.id==$pid and (.items|type)=="array" and (.minFormatScore|type)=="number"' "$profile" >/dev/null || return 1
    jq --slurpfile owner "$owner" --slurpfile media "$media" --slurpfile profile "$profile" --slurpfile details "$TMP_DIR/recovery-linked.json" \
      '.workflow="arr-native" | .status="required" | .reason="Confirmed unchanged decoder failure; replacement required. Original remains in its library location and native monitoring is unchanged." |
       .externalId=(if .app=="Sonarr" then $owner[0].tvdbId else $owner[0].tmdbId end) | .profile=$profile[0] | .originalMedia=($media[0]|{id,path,quality,customFormatScore,languages,edition,sceneName}) |
       .targetDetails=(if .app=="Sonarr" then [$details[0][]|{id,seriesId,seasonNumber,episodeNumber}] else [] end) | .events=[]' "$base" >"$output" || return 1
    jq -e '.externalId>0' "$output" >/dev/null
}
# Bound complete pagination. Duplicate IDs or changing totals fail closed.
recovery_history() {
    local job="$1" output="$2" download="${3:-}" query page count total=-1 loaded=0 expected part="$TMP_DIR/history-page.json" rows="$TMP_DIR/history-rows.jsonl"
    if [[ -n "$download" ]];then query="downloadId=$download";elif [[ $(jq -r .app "$job") == Sonarr ]];then query="episodeId=$(jq -r '.targets[0]' "$job")";else query="movieIds=$(jq -r .parentId "$job")";fi
    : >"$rows"
    for ((page=1;page<=10;page++));do
        recovery_api GET "/history?page=$page&pageSize=200&sortKey=date&sortDirection=descending&$query" "$part" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        jq -e '(.records|type)=="array" and (.totalRecords|type)=="number" and .totalRecords>=0 and all(.records[];(.id|type)=="number" and .id>0)' "$part" >/dev/null || return 1
        expected=$(jq .totalRecords "$part");count=$(jq '.records|length' "$part")
        ((expected<=2000 && (total<0 || expected==total))) || return 1;total=$expected
        jq -c '.records[]' "$part" >>"$rows" || return 1;loaded=$((loaded+count))
        ((loaded<total)) || break;((count>0)) || return 1
    done
    jq -s --argjson total "$total" 'unique_by(.id)|select(length==$total)|{totalRecords:$total,records:.}' "$rows" >"$output" || return 1
    jq -e --arg download "$download" '.totalRecords==(.records|length) and (if $download!="" then all(.records[];.downloadId==$download) else true end)' "$output" >/dev/null
}
recovery_correlate() {
    local id="$1" job="$2" history="$TMP_DIR/native-history.json" download selected="$TMP_DIR/native-grabs.json"
    recovery_history "$job" "$history" || return 1
    jq --slurpfile j "$job" '[.records[]|select(.eventType=="grabbed" and .sourceTitle==$j[0].selected.title and .data.guid==$j[0].selected.guid and
      (if $j[0].app=="Sonarr" then .seriesId==$j[0].parentId and .episodeId==$j[0].targets[0] else .movieId==$j[0].parentId end) and
      (.id as $id|($j[0].baselineGrabs|index($id))==null))|.downloadId]|unique' "$history" >"$selected" || return 1
    [[ $(jq length "$selected") == 1 ]] || return 1
    download=$(jq -r '.[0]' "$selected");[[ "$download" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    recovery_history "$job" "$history" "$download" || return 1
    jq -e --slurpfile j "$job" --arg download "$download" '[.records[]|select(.eventType=="grabbed")] as $g |
      ($g|length)>0 and all($g[];.downloadId==$download and .sourceTitle==$j[0].selected.title and .data.guid==$j[0].selected.guid and
      (if $j[0].app=="Sonarr" then .seriesId==$j[0].parentId else .movieId==$j[0].parentId end)) and
      (if $j[0].app=="Sonarr" then ([$g[].episodeId]|sort|unique)==($j[0].targets|sort) else true end)' "$history" >/dev/null || return 1
    recovery_update '.actions[$id].downloadId=$download | if (.actions[$id].attempts // []|length)>0 then .actions[$id].attempts[-1].downloadId=$download | .actions[$id].attempts[-1].outcome="grab_verified" else . end' --arg id "$id" --arg download "$download" || return 1
    recovery_set "$id" downloading 'Selected release correlated through exact native grab history and download ID; original retained while Arr downloads/imports. No repeated grab.'
}
recovery_followup() {
    local id="$1" job="$2" app parent target kind endpoint root current file path added history="$TMP_DIR/native-import-history.json" refs="$TMP_DIR/native-current.json" rows="$TMP_DIR/native-paths.jsonl" valid=true
    app=$(jq -r .app "$job");parent=$(jq -r .parentId "$job")
    if [[ "$app" == Sonarr ]];then kind=episode;endpoint=episodefile;root="$SONARR_MEDIA_ROOT";else kind=movie;endpoint=moviefile;root="$RADARR_MEDIA_ROOT";fi
    local queue="$TMP_DIR/native-followup-queue.json" progress="$TMP_DIR/native-progress.json"
    recovery_api GET '/queue?page=1&pageSize=1000&includeUnknownSeriesItems=true&includeUnknownMovieItems=true' "$queue" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
    jq -e '(.records|type)=="array" and .totalRecords==(.records|length)' "$queue" >/dev/null || return 1
    jq --slurpfile j "$job" '[.records[]|select((.downloadId // ""|ascii_downcase)==($j[0].downloadId|ascii_downcase))|{status,trackedDownloadState,trackedDownloadStatus,sizeleft,statusMessages}]' "$queue" >"$progress" || return 1
    recovery_update 'if (.actions[$id].nativeQueue // []|map({status,trackedDownloadState,trackedDownloadStatus,statusMessages}))==($p[0]|map({status,trackedDownloadState,trackedDownloadStatus,statusMessages})) and $now-(.actions[$id].progressSavedAt // 0)<900 then . else .actions[$id].progressSavedAt=$now | .actions[$id].nativeQueue=$p[0] | .actions[$id].downloadCompletedAt=(if any($p[0][];.status=="completed") then (.actions[$id].downloadCompletedAt // $now) else .actions[$id].downloadCompletedAt end) end' --arg id "$id" --slurpfile p "$progress" --argjson now "$(date +%s)" || return 1
    recovery_history "$job" "$history" "$(jq -r .downloadId "$job")" || return 1
    if jq -e 'any(.records[];.eventType=="downloadFailed" or .eventType=="downloadIgnored")' "$history" >/dev/null;then
        if recovery_prepare_retry "$id" "$job" "$history";then return 0;fi
        recovery_set "$id" review 'Native download failed/ignored; automatic alternative was not authorized. Requires exact archive-failure evidence, unchanged monitored original and fewer than two attempts. Storage/manual/unknown failures stay protected; no blocklist or forced import.';return 0;fi
    local owner="$TMP_DIR/native-followup-owner.json" parent_kind=movie
    [[ "$app" != Sonarr ]] || parent_kind=series
    recovery_api GET "/$parent_kind/$parent" "$owner" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
    jq -e --slurpfile j "$job" '.id==$j[0].parentId and (if $j[0].app=="Sonarr" then .tvdbId else .tmdbId end)==$j[0].externalId' "$owner" >/dev/null || return 1
    if jq -e '.monitored==false' "$owner" >/dev/null;then
        if recovery_observe_external "$id" "$job";then return 0;fi
    fi
    : >"$rows"
    while read -r target;do
        recovery_api GET "/$kind/$target" "$refs" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        jq -e --argjson target "$target" --argjson parent "$parent" --arg app "$app" '.id==$target and .hasFile==true and (if $app=="Sonarr" then .seriesId==$parent else .id==$parent end)' "$refs" >/dev/null || { valid=false;break; }
        file=$(jq -r --arg app "$app" 'if $app=="Sonarr" then .episodeFileId else .movieFileId end' "$refs")
        if [[ "$file" == "$(jq -r .fileId "$job")" ]] && jq -e '.monitored==false' "$refs" >/dev/null;then recovery_observe_external "$id" "$job";return $?;fi
        [[ "$file" =~ ^[1-9][0-9]*$ && "$file" != "$(jq -r .fileId "$job")" ]] || { valid=false;break; }
        recovery_api GET "/$endpoint/$file" "$refs" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        jq -e --argjson file "$file" --argjson parent "$parent" --arg app "$app" '.id==$file and (if $app=="Sonarr" then .seriesId==$parent else .movieId==$parent end)' "$refs" >/dev/null || return 1
        path=$(jq -r '.path // ""' "$refs");[[ "$path" == "$root/"* ]] || return 1;path=${path#"$root/"}
        added=$(date -d "$(jq -r '.dateAdded // ""' "$refs")" +%s 2>/dev/null) || return 1
        ((added>=$(jq -r .startedAt "$job"))) || return 1
        jq -e --slurpfile j "$job" --argjson file "$file" --argjson target "$target" --arg path "$root/$path" 'any(.records[];.eventType=="downloadFolderImported" and .downloadId==$j[0].downloadId and
          (.data.fileId|tonumber?)==$file and .data.importedPath==$path and (if $j[0].app=="Sonarr" then .seriesId==$j[0].parentId and .episodeId==$target else .movieId==$target end))' "$history" >/dev/null || return 1
        recovery_file_tool identity "$path" >"$TMP_DIR/native-current-identity.json" || return 1
        jq -e --slurpfile j "$job" '.[0:4]!=$j[0].identity[0:4]' "$TMP_DIR/native-current-identity.json" >/dev/null || return 1
        jq -cn --arg path "$path" --argjson file "$file" --argjson added "$added" --slurpfile identity "$TMP_DIR/native-current-identity.json" '{path:$path,fileId:$file,identity:$identity[0],importedAt:$added}' >>"$rows"
    done < <(jq -r '.targets[]' "$job")
    if [[ "$valid" != true ]];then
        if (( $(date +%s)-$(jq -r .startedAt "$job")>RECOVERY_WAIT_DAYS*86400 ));then recovery_set "$id" review 'Replacement not imported by the recovery deadline. No original was moved/deleted by this script; inspect the exact native download/import outcome.';fi
        if jq -e 'any(.[];.trackedDownloadStatus=="warning" or .trackedDownloadStatus=="error")' "$progress" >/dev/null;then
            recovery_set "$id" review "Native replacement queue needs attention: $(jq -c '[.[].statusMessages[]?.messages[]?]|unique' "$progress" | head -c 1000). No forced import or extra grab."
        fi
        return 0
    fi
    recovery_update '.actions[$id].replacementPaths=[$rows[].path] | .actions[$id].replacementFiles=$rows | .actions[$id].importedAt=([$rows[].importedAt]|min)' --arg id "$id" --slurpfile rows "$rows" || return 1
    recovery_retention "$id" "$job" || return 1
    if jq -e --slurpfile rows "$rows" --slurpfile j "$job" 'all($rows[];. as $r|$r.path as $p| .identity as $i|
       $state[0].files[$p] as $f|$f!=null and $f.identity==$i and $f.issue==null and $f.auditIssue==null and $f.verificationPolicy==2 and $f.coverage=="all_planned_segments_decoded" and ($f.verifiedAt // 0)>=$j[0].startedAt)' \
       --slurpfile state "$TMP_DIR/state.json" -n >/dev/null;then
        recovery_update '.actions[$id].replacementVerifiedAt=$now | .actions[$id].resolutionSource="native" | .actions[$id].lastError=null' --arg id "$id" --argjson now "$(date +%s)" || return 1
        recovery_set "$id" recovered 'Replacement completed: exact native download/import/file IDs and current filesystem version passed all planned decode ranges. Arr performed replacement and owns original recycling; script performed no media move/delete.'
    else
        recovery_update '.actions[$id].importedAt=(.actions[$id].importedAt // $now)' --arg id "$id" --argjson now "$(date +%s)" || return 1
        recovery_set "$id" verifying 'Arr imported the exact replacement. Priority resumable integrity verification pending; original recycling is owned by Arr. Native bin retention continues during verification.'
    fi
}
# Selected-release capacity includes packed/unpacked download space plus an
# import copy. Shared filesystem budgets are combined instead of double-counted.
recovery_capacity_ready() {
    local bytes="$1" selected="${2:-false}" path device available need library_device="" reserve=$((10*1024*1024*1024))
    local -a paths=("$MEDIA_HOST_ROOT")
    local -A required=() free=()
    [[ "$bytes" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$selected" != true ]] || paths+=("${RECOVERY_DOWNLOAD_ROOTS[@]}")
    for path in "${paths[@]}";do
        [[ "$path" == "$MEDIA_HOST_ROOT" || "$path" == "$MEDIA_HOST_ROOT/"* ]] && [[ -d "$path" && ! -L "$path" ]] || return 1
        device=$(stat -c %d -- "$path") || return 1
        available=$(df -PB1 -- "$path"|awk 'NR==2 {print $4}') || return 1
        [[ "$available" =~ ^[0-9]+$ ]] || return 1
        need=$bytes;[[ "$path" == "$MEDIA_HOST_ROOT" ]] || need=$((bytes*2))
        if [[ "$path" == "$MEDIA_HOST_ROOT" ]];then library_device=$device
        elif ((need>${required[$device]:-0}));then required[$device]=$need;fi
        if [[ -z "${free[$device]+set}" ]] || ((available<free[$device]));then free[$device]=$available;fi
    done
    required[$library_device]=$(( ${required[$library_device]:-0}+bytes ))
    for device in "${!required[@]}";do
        # Ten percent allows for native size estimates/filesystem overhead.
        ((free[$device]>=required[$device]+required[$device]/10+reserve)) || return 1
    done
}
recovery_retention() {
    local id="$1" job="$2" cfg="$TMP_DIR/native-retention.json" endpoint=/config/mediamanagement now days imported deadline attention
    now=$(date +%s)
    if (( now-$(jq -r '.binPolicyCheckedAt // 0' "$job")>=43200 ));then
        [[ "$RECOVERY_ROOT" != */v5 ]] || endpoint=/settings/mediamanagement
        recovery_api GET "$endpoint" "$cfg" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        jq -e '(.recycleBin|type)=="string" and (.recycleBin|startswith("/")) and (.recycleBinCleanupDays|type)=="number" and .recycleBinCleanupDays>=0 and .recycleBinCleanupDays==(.recycleBinCleanupDays|floor)' "$cfg" >/dev/null || return 1
        recovery_update '.actions[$id].binRetentionDays=$c[0].recycleBinCleanupDays | .actions[$id].binPolicyCheckedAt=$now' --arg id "$id" --slurpfile c "$cfg" --argjson now "$now" || return 1
    fi
    days=$(jq -r --arg id "$id" '.actions[$id].binRetentionDays // 0' "$RECOVERY_FILE")
    imported=$(jq -r --arg id "$id" '.actions[$id].importedAt // 0' "$RECOVERY_FILE")
    if ((imported>0 && days>0));then
        deadline=$((imported+days*86400));attention=$((deadline-(days*86400/2<43200 ? days*86400/2 : 43200)))
    else deadline=0;attention=$(( (imported>0 ? imported : now)+86400 ));fi
    recovery_update '.actions[$id].verificationDeadlineAt=$deadline | .actions[$id].verificationAttentionAt=$attention' --arg id "$id" --argjson deadline "$deadline" --argjson attention "$attention"
}
# Read current native/physical identities independently of the selected download.
# Full audit proof can close externally fixed media without claiming our grab
# caused the fix. Native unmonitoring cancels only while the original still exists.
recovery_observe_external() {
    local id="$1" job="$2" refs="$TMP_DIR/external-target.json" owner="$TMP_DIR/external-owner.json" rows="$TMP_DIR/external-rows.jsonl" app parent kind endpoint parent_kind target file path root added old_same=true monitored=true all_verified=true
    app=$(jq -r .app "$job");parent=$(jq -r .parentId "$job")
    if [[ "$app" == Sonarr ]];then kind=episode;endpoint=episodefile;parent_kind=series;root="$SONARR_MEDIA_ROOT";else kind=movie;endpoint=moviefile;parent_kind=movie;root="$RADARR_MEDIA_ROOT";fi
    recovery_api GET "/$parent_kind/$parent" "$owner" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
    jq -e --slurpfile j "$job" '.id==$j[0].parentId and (if $j[0].app=="Sonarr" then .tvdbId else .tmdbId end)==$j[0].externalId' "$owner" >/dev/null || return 1
    jq -e '.monitored==true' "$owner" >/dev/null || monitored=false
    : >"$rows"
    while read -r target;do
        recovery_api GET "/$kind/$target" "$refs" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        jq -e --argjson target "$target" --argjson parent "$parent" --arg app "$app" '.id==$target and .hasFile==true and (if $app=="Sonarr" then .seriesId==$parent else .id==$parent end)' "$refs" >/dev/null || return 1
        jq -e '.monitored==true' "$refs" >/dev/null || monitored=false
        file=$(jq -r --arg app "$app" 'if $app=="Sonarr" then .episodeFileId else .movieFileId end' "$refs")
        [[ "$file" =~ ^[1-9][0-9]*$ ]] || return 1
        recovery_api GET "/$endpoint/$file" "$refs" && [[ "$RECOVERY_HTTP" == 200 ]] || return 1
        jq -e --argjson file "$file" --argjson parent "$parent" --arg app "$app" '.id==$file and (if $app=="Sonarr" then .seriesId==$parent else .movieId==$parent end)' "$refs" >/dev/null || return 1
        path=$(jq -r '.path // ""' "$refs");[[ "$path" == "$root/"* ]] || return 1;path=${path#"$root/"}
        added=$(date -d "$(jq -r '.dateAdded // ""' "$refs")" +%s 2>/dev/null) || added=0
        recovery_file_tool identity "$path" >"$TMP_DIR/external-identity.json" || return 1
        jq -cn --arg path "$path" --argjson file "$file" --argjson added "$added" --slurpfile i "$TMP_DIR/external-identity.json" '{path:$path,fileId:$file,identity:$i[0],importedAt:$added}' >>"$rows"
        [[ "$file" == "$(jq -r .fileId "$job")" ]] && jq -e --slurpfile j "$job" '.==$j[0].identity' "$TMP_DIR/external-identity.json" >/dev/null || old_same=false
        jq -e --arg path "$path" --slurpfile i "$TMP_DIR/external-identity.json" --slurpfile j "$job" '.files[$path] as $f|$f.identity==$i[0] and $f.issue==null and $f.auditIssue==null and $f.verificationPolicy==2 and $f.coverage=="all_planned_segments_decoded" and ($f.verifiedAt // 0)>=$j[0].startedAt and $f.coverage=="all_planned_segments_decoded"' "$TMP_DIR/state.json" >/dev/null || all_verified=false
    done < <(jq -r '.targets[]' "$job")
    if [[ "$old_same" == true && "$monitored" == false ]];then
        recovery_set "$id" cancelled 'Recovery cancelled: native monitoring is now off while the exact original remains present. Monitoring/user intent preserved; no replacement or deletion performed.';return $?
    fi
    if [[ "$all_verified" == true ]];then
        recovery_update '.actions[$id].replacementFiles=$rows | .actions[$id].replacementPaths=[$rows[].path] | .actions[$id].replacementVerifiedAt=$now | .actions[$id].resolutionSource="external" | .actions[$id].lastError=null' --arg id "$id" --slurpfile rows "$rows" --argjson now "$(date +%s)" || return 1
        if [[ "$old_same" == true ]];then recovery_set "$id" resolved 'Recovery no longer required: the unchanged current original completed all planned decode ranges successfully. No replacement attributed to this script.'
        else recovery_set "$id" recovered 'External recovery verified: exact current Arr/external IDs and physical replacement completed all planned decode ranges. Recovery guards released; replacement was not attributed to this script.';fi
        return $?
    fi
    if [[ "$old_same" == true ]];then
        if jq -e --slurpfile rows "$rows" 'all($rows[];.path as $p|$state[0].files[$p].issue==null)' --slurpfile state "$TMP_DIR/state.json" -n >/dev/null;then
            recovery_update '.actions[$id].replacementFiles=$rows | .actions[$id].replacementPaths=[$rows[].path] | .actions[$id].resolutionSource="recheck"' --arg id "$id" --slurpfile rows "$rows" || return 1
            recovery_set "$id" verifying 'Original warning cleared on focused rechecks; a complete current-file decode cycle is still required. No replacement attributed or media changed.';return $?
        fi
        return 1
    fi
    recovery_update '.actions[$id].replacementFiles=$rows | .actions[$id].replacementPaths=[$rows[].path] | .actions[$id].resolutionSource="external" | .actions[$id].importedAt=([$rows[].importedAt|select(.>0)]|min // $now)' --arg id "$id" --slurpfile rows "$rows" --argjson now "$(date +%s)" || return 1
    recovery_retention "$id" "$job" || return 1
    recovery_set "$id" verifying 'External/current replacement detected by exact Arr and physical identities. Attribution is unproven; priority full verification pending. No download replay or monitoring override.'
}
# An alternative is permitted only for an exact, proven native archive/download
# failure, with unchanged monitored original, cooldown, fresh evidence and budgets.
recovery_prepare_retry() {
    local id="$1" job="$2" history="$3" message original="$TMP_DIR/retry-original.json" candidate="$TMP_DIR/retry-candidate.json" now
    now=$(date +%s)
    jq -e --slurpfile j "$job" '[.records[]|select(.eventType=="downloadFailed")] as $fail|($fail|length)>0 and all(.records[];.eventType!="downloadIgnored" and .eventType!="downloadFolderImported") and
      all($fail[];.downloadId==$j[0].downloadId and (if $j[0].app=="Sonarr" then .seriesId==$j[0].parentId and (.episodeId as $e|$j[0].targets|index($e))!=null else .movieId==$j[0].parentId end)) and
      (if $j[0].app=="Sonarr" then ([$fail[].episodeId]|sort|unique)==($j[0].targets|sort) else true end)' "$history" >/dev/null || return 1
    message=$(jq -r '[.records[]|select(.eventType=="downloadFailed")|.data.message // ""]|join("; ")' "$history")
    [[ "$message" =~ [Cc][Rr][Cc]|[Cc]hecksum|[Uu]npack|[Rr]epair|[Mm]issing\ articles|[Ee]ncrypted|[Pp]assword|[Dd]amaged\ archive ]] || return 1
    grep -Eiq 'permission|denied|space|disk|I/O|input/output|manually|ignored|cancel' <<<"$message" && return 1
    jq -e --argjson limit "$RECOVERY_MAX_ATTEMPTS" '(.attempts // []|length)<$limit and .selected.guid!=null' "$job" >/dev/null || return 1
    jq '{key:.path,value:{identity,issue:.finding}}' "$job" >"$candidate"
    recovery_plan "$candidate" "$original" || return 1
    jq -e --slurpfile j "$job" '{identity,fileId,parentId,targets,externalId,profile}==($j[0]|{identity,fileId,parentId,targets,externalId,profile})' "$original" >/dev/null || return 1
    recovery_update '.actions[$id].attempts=(if (.actions[$id].attempts // []|length)==0 then [{at:.actions[$id].grabSentAt,guid:.actions[$id].selected.guid,title:.actions[$id].selected.title,downloadId:.actions[$id].downloadId}] else .actions[$id].attempts end) | .actions[$id].attempts[-1].outcome="native_download_failed" | .actions[$id].failedReleases=((.actions[$id].failedReleases // [])+[{guid:.actions[$id].selected.guid,title:.actions[$id].selected.title}]) |
      .actions[$id].retryAt=$retry | .actions[$id].selected=null | .actions[$id].downloadId=null | .actions[$id].selectionAt=0' --arg id "$id" --argjson retry "$((now+RECOVERY_RETRY_SECONDS))" || return 1
    recovery_set "$id" retry_wait "Verified native download failure: ${message:0:500}. Original unchanged; one alternative may be selected after the four-hour cooldown, fresh evidence and shared budgets. Failed release excluded."
}

# Fair, deadline-aware targeted work. Three replacement slots plus one stale
# evidence slot when needed; timestamps come from actual decoder work, not polls.
recovery_schedule() {
    jq -n --slurpfile j "$RECOVERY_FILE" --slurpfile state "$TMP_DIR/state.json" --argjson now "$(date +%s)" '
      [$j[0].actions|to_entries[]|select(.value.status=="verifying")|. as $job|
       .value.replacementPaths[]? as $path|{path:$path,deadline:($job.value.verificationDeadlineAt // 0),attempt:($state[0].files[$path].lastAttemptAt // 0)}]|
      unique_by(.path)|sort_by(.attempt,(if .deadline>0 then .deadline else 9999999999 end)) as $replacements|
      [$j[0].actions[]|select(.status=="required" or .status=="blocked" or .status=="retry_wait")|. as $job|
       $state[0].files[.path] as $f|select($f.identity==$job.identity and $f.issue.kind=="decode_error" and $f.issue.proofVersion==4 and $f.issue.origin=="decode" and $f.issue.confirmationMethod=="normal-isolated-streams-v1" and any($f.issue.streamEvidence[]?; .primary==true and .kind=="decode_error" and .exit>0) and ($f.issue.confirmationKey|type)=="string" and $f.issue.confirmed==true and
       ($f.issue.lastSeen // 0)<$now-48*3600 and ($f.lastAttemptAt // 0)<$now-86400)|{path:.path,attempt:($f.lastAttemptAt // 0)}]|
      unique_by(.path)|sort_by(.attempt) as $evidence|
      {recheckAfter:([$j[0].actions[]|select(.status=="verifying" and .resolutionSource=="recheck")|. as $job|.replacementPaths[]?|{key:.,value:$job.startedAt}]|from_entries),evidencePaths:[$evidence[:1][].path],paths:([$replacements[:(if ($evidence|length)>0 then 3 else 4 end)][].path]+[$evidence[:1][].path])}' >"$TMP_DIR/recovery-schedule.json"
}

recovery_resume() (
    if [[ "${ARR_MUTATION_COORDINATION_ACTIVE:-false}" != true ]];then recovery_resume_core "$@";return $?;fi
    local coordinated_app fd
    coordinated_app=$(jq -r --arg id "$1" '.actions[$id].app' "$RECOVERY_FILE") || return 1
    case "$coordinated_app" in Sonarr|Radarr) ;;*) return 1;;esac
    exec {fd}>"${ARR_MUTATION_LOCK_DIR:-/run}/arr-mutations-$coordinated_app.lock" || return 1
    flock -n "$fd" || { printf '%s recovery deferred: another coordinated script owns Arr changes\n' "$coordinated_app" >&2;return 0; }
    recovery_resume_core "$@"
)

recovery_resume_core() {
    local id="$1" job="$TMP_DIR/native-job.json" status response="$TMP_DIR/native-response.json" query selected="$TMP_DIR/native-selected.json" fresh="$TMP_DIR/native-fresh.json" candidate="$TMP_DIR/native-candidate.json" history="$TMP_DIR/native-baseline.json" ready
    jq --arg id "$id" '.actions[$id]' "$RECOVERY_FILE" >"$job" || return 1
    status=$(jq -r .status "$job");[[ "$status" != recovered && "$status" != cancelled && "$status" != resolved ]] || return 0
    recovery_connection "$(jq -r .app "$job")" || return 1
    if [[ "$status" == grab_intent || "$status" == review ]] && jq -e '.selected!=null and .grabSentAt>0 and (.downloadId // "")==""' "$job" >/dev/null;then
        recovery_correlate "$id" "$job" || { if recovery_observe_external "$id" "$job";then return 0;fi;recovery_set "$id" review 'Grab outcome uncertain: exact native download identity not established. Request not replayed; original remains in place.';return 0; }
        jq --arg id "$id" '.actions[$id]' "$RECOVERY_FILE" >"$job";status=downloading
    fi
    if [[ $(jq -r '.resolutionSource // ""' "$job") == recheck ]] && recovery_observe_external "$id" "$job";then return 0;fi
    if jq -e '(.downloadId // "")!=""' "$job" >/dev/null;then
        if recovery_followup "$id" "$job";then return 0;fi
        recovery_api_diagnostic "$id" 'Native download/import correlation unavailable; checking exact current media without attributing the replacement' || return 1
        recovery_observe_external "$id" "$job";return $?
    fi
    if recovery_observe_external "$id" "$job";then return 0;fi
    [[ "$status" != retry_wait ]] || (( $(date +%s)>=$(jq -r '.retryAt // 0' "$job") )) || return 0
    [[ "$status" == required || "$status" == selected || "$status" == blocked || "$status" == retry_wait ]] || return 0
    [[ "$RECOVERY_ALLOW_GRAB" == true ]] && recovery_new_window_open || return 0
    jq -e --slurpfile j "$job" --argjson cutoff "$(( $(date +%s)-48*3600 ))" '.files[$j[0].path] as $f|$f.identity==$j[0].identity and $f.issue.identity==$f.identity and $f.issue.kind=="decode_error" and $f.issue.proofVersion==4 and $f.issue.origin=="decode" and $f.issue.confirmationMethod=="normal-isolated-streams-v1" and any($f.issue.streamEvidence[]?; .primary==true and .kind=="decode_error" and .exit>0) and ($f.issue.confirmationKey|type)=="string" and $f.issue.confirmed==true and $f.issue.confirmedRuns>=2 and $f.issue.lastSeen>=$cutoff' "$TMP_DIR/state.json" >/dev/null || { recovery_set "$id" blocked 'Fresh unchanged-file corruption evidence required before release selection; original retained';return 0; }
    local last
    last=$(jq -r '.selectionAt // 0' "$job");(( $(date +%s)-last>=86400 )) || return 0
    jq '{key:.path,value:{identity,issue:.finding}}' "$job" >"$candidate"
    recovery_plan "$candidate" "$fresh" || { recovery_set "$id" blocked 'Original ownership/identity/monitoring/profile/health no longer qualifies. Original unchanged; no grab.';return 0; }
    jq -e --slurpfile j "$job" '{app,parentId,fileId,identity,targets,externalId,profile}==($j[0]|{app,parentId,fileId,identity,targets,externalId,profile})' "$fresh" >/dev/null || { recovery_set "$id" blocked 'Profile or exact original identity changed; no grab. Reconfirm evidence under current rules.';return 0; }
    query="movieId=$(jq -r .parentId "$job")";[[ $(jq -r .app "$job") != Sonarr ]] || query="episodeId=$(jq -r '.targets[0]' "$job")"
    recovery_update '.actions[$id].selectionAt=$now' --arg id "$id" --argjson now "$(date +%s)" || return 1
    recovery_api GET "/release?$query" "$response" && [[ "$RECOVERY_HTTP" == 200 ]] && jq -e 'type=="array"' "$response" >/dev/null || { recovery_set "$id" blocked 'Native interactive release search unavailable; original retained; selection retries at most daily inside approved windows.';return 0; }
    jq -n --slurpfile job "$job" --slurpfile releases "$response" '{job:$job[0],releases:$releases[0]}' | recovery_select_release >"$selected" || return 1
    jq -e 'type=="object"' "$selected" >/dev/null || { recovery_set "$id" blocked 'No exact alternative release satisfies profile, language, quality/revision, score and identity safeguards. Original retained; no fallback deletion or forced import.';return 0; }
    recovery_capacity_ready "$(jq -r .size "$selected")" true || { recovery_set "$id" blocked 'Selected replacement exceeds download/destination filesystem budget or a configured download mount is unavailable. Original retained; no grab.';return 0; }
    recovery_retention "$id" "$job" || { recovery_api_diagnostic "$id" 'Native recycling retention could not be validated';return 1; }
    recovery_update '.actions[$id].selected=$selected[0]' --arg id "$id" --slurpfile selected "$selected" || return 1
    recovery_set "$id" selected 'Exact alternative selected; only existing-file upgrade/cutoff rejections may be bypassed. Profile minimums and identity remain enforced.' || return 1
    # Search may take time. Re-read quiet native state and exact original again
    # before the sole mutation. No app-wide configuration/monitoring override.
    recovery_runtime_matches && recovery_new_window_open && workload_guard && recovery_plan "$candidate" "$fresh" || return 0
    jq -e --slurpfile j "$job" '{parentId,fileId,identity,targets,externalId,profile}==($j[0]|{parentId,fileId,identity,targets,externalId,profile})' "$fresh" >/dev/null || return 1
    ((RECOVERY_NEW_GRABS<RECOVERY_MAX_NEW_PER_RUN)) || return 0
    jq -e --argjson cutoff "$(( $(date +%s)-7*86400 ))" --argjson limit "$RECOVERY_MAX_NEW_PER_WEEK" '[.actions[]|if (.attempts // []|length)>0 then .attempts[]|select(.at>=$cutoff) else select((.grabSentAt // 0)>=$cutoff) end]|length<$limit' "$RECOVERY_FILE" >/dev/null || return 0
    recovery_history "$job" "$history" || return 1
    usr_ops_arr_reserve "integrity:$id:$(jq -r '.attempts // []|length' "$job")" "$(jq -r '.app' "$job")" "$(jq -r '.targets[0]' "$job")" || { RECOVERY_NOTE='Shared media action budget reached or unavailable; replacement deferred; original retained';return 0; }
    recovery_update '.actions[$id].baselineGrabs=[$h[0].records[]|select(.eventType=="grabbed")|.id] | .actions[$id].grabSentAt=$now | .actions[$id].attempts=((.actions[$id].attempts // [])+[{at:$now,guid:.actions[$id].selected.guid,title:.actions[$id].selected.title,indexerId:.actions[$id].selected.indexerId,outcome:"intent"}])' --arg id "$id" --argjson now "$(date +%s)" --slurpfile h "$history" || return 1
    RECOVERY_NEW_GRABS=$((RECOVERY_NEW_GRABS+1))
    recovery_set "$id" grab_intent 'Release grab intent saved before one POST /release. Original remains in library; uncertain outcomes will not be replayed.' || return 1
    jq '.payload' "$selected" >"$TMP_DIR/native-grab-payload.json"
    recovery_window_open || return 0
    recovery_api POST /release "$response" "$TMP_DIR/native-grab-payload.json" || true
    jq --arg id "$id" '.actions[$id]' "$RECOVERY_FILE" >"$job"
    recovery_correlate "$id" "$job" || recovery_set "$id" review 'Grab sent once; exact native download identity not yet established. No replay; follow-up reads history before further action.'
}
# Expiring updater handoff: current operations finish; new conflicting work
# yields before reading/mutating app state. Never deletes or overrides a lock.
app_update_requested() {
    local scope="$1" file now boot seen=0
    now=$(date +%s);boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) || return 1
    for file in "${APP_UPDATE_REQUEST_DIR:-/run/docker-update-requests}/"*.json;do
        [[ -f "$file" && ! -L "$file" ]] || continue
        seen=$((seen+1));((seen<=128)) || break
        (( $(stat -c %s "$file" 2>/dev/null || printf 999999)<=8192 )) || continue
        if jq -e --arg scope "$scope" --arg boot "$boot" --argjson now "$now" '
          .schema==1 and .owner=="system_update_coordinator" and .boot==$boot and
          (.expires|type)=="number" and .expires>$now and .expires<=$now+1200 and
          (.scopes|type)=="array" and (.scopes|index($scope))!=null' "$file" >/dev/null 2>&1;then return 0;fi
    done
    return 1
}

recovery_process() {
    [[ "$AUTO_RECOVERY_ENABLED" == true ]] || return 0
    recovery_platform_ready && recovery_valid || { RECOVERY_NOTE='Recovery platform/journal unavailable; no mutation allowed';return 1; }
    recovery_update '.actions |= with_entries(select((.value.status!="recovered" and .value.status!="resolved" and .value.status!="cancelled") or (.value.replacementVerifiedAt // .value.updatedAt // .value.startedAt // 0)>=$cutoff))' --argjson cutoff "$(( $(date +%s)-365*86400 ))" || return 1
    RECOVERY_DEADLINE=$(( $(date +%s)+RECOVERY_MAX_SECONDS ))
    local fd hold id row count=0 rc=0 candidate="$TMP_DIR/native-candidate-plan.json" plan="$TMP_DIR/native-new-plan.json" now
    exec {fd}>"$ARR_BACKUP_GATE" || return 1;flock -s -n "$fd" || { exec {fd}>&-;return 0; }
    if app_update_requested integrity;then exec {fd}>&-;return 0;fi
    exec {hold}>/tmp/arr_metadata_quarantine.lock || { exec {fd}>&-;return 1; };flock -n "$hold" || { exec {fd}>&-;exec {hold}>&-;return 0; }
    RECOVERY_NEW_GRABS=0
    while read -r id;do (( $(date +%s)<RECOVERY_DEADLINE )) || break;recovery_update ' if $now-(.actions[$id].checkedAt // 0)>=900 then .actions[$id].checkedAt=$now else . end ' --arg id "$id" --argjson now "$(date +%s)" || break;if ! recovery_resume "$id";then
        if ! jq -e --arg id "$id" --argjson cutoff "$(( $(date +%s)-120 ))" '(.actions[$id].lastError.at // 0)>=$cutoff' "$RECOVERY_FILE" >/dev/null;then recovery_api_diagnostic "$id" 'Bounded native API or identity/history evidence step incomplete' || true;fi
        rc=1
    fi;done < <(jq -r '.actions|to_entries|sort_by(.value.checkedAt // 0)|.[]|select(.value.status!="recovered" and .value.status!="resolved" and .value.status!="cancelled")|.key' "$RECOVERY_FILE"|sed -n '1,4p')
    now=$(date +%s)
    if [[ "$RECOVERY_ALLOW_GRAB" == true ]] && recovery_new_window_open && recovery_runtime_matches;then
      while IFS= read -r row;do
        ((count<RECOVERY_MAX_NEW_PER_RUN && $(date +%s)<RECOVERY_DEADLINE)) || break
        jq -e --argjson cutoff "$((now-7*86400))" --argjson limit "$RECOVERY_MAX_NEW_PER_WEEK" '[.actions[]|if (.attempts // []|length)>0 then .attempts[]|select(.at>=$cutoff) else select((.grabSentAt // 0)>=$cutoff) end]|length<$limit' "$RECOVERY_FILE" >/dev/null || break
        printf '%s\n' "$row" >"$candidate";id=$(jq -c '[.key,.value.identity]' "$candidate"|sha256sum|awk '{print $1}')
        jq -e --arg id "$id" '.actions[$id]!=null' "$RECOVERY_FILE" >/dev/null && continue
        recovery_plan "$candidate" "$plan" || continue
        jq -e --slurpfile p "$plan" --argjson cutoff "$((now-30*86400))" 'all(.actions[];.app!=$p[0].app or .parentId!=$p[0].parentId or .startedAt<$cutoff)' "$RECOVERY_FILE" >/dev/null || continue
        recovery_update '.actions[$id]=$p[0]' --arg id "$id" --slurpfile p "$plan" || { rc=1;break; }
        count=$((count+1));recovery_resume "$id" || rc=1
      done < <(jq -c --argjson cutoff "$((now-48*3600))" '.files|to_entries[]|select((.value.issue.lastSeen // 0)>=$cutoff and .value.issue.kind=="decode_error" and .value.issue.proofVersion==4 and .value.issue.origin=="decode" and .value.issue.confirmationMethod=="normal-isolated-streams-v1" and any(.value.issue.streamEvidence[]?; .primary==true and .kind=="decode_error" and .exit>0) and (.value.issue.confirmationKey|type)=="string" and .value.issue.confirmed==true and (.value.issue.confirmedRuns // 0)>=2 and .value.issue.identity==.value.identity and (.value.replacementPending // false)==false)' "$TMP_DIR/state.json")
    fi
    exec {hold}>&-;exec {fd}>&-;return "$rc"
}

worker_program() {
    cat <<'PYWORKER'
"""Read-only worker executed in Bazarr; stdout is a private checkpoint protocol."""
import base64, collections, errno, gzip, hashlib, json, math, os, re, resource
import selectors, signal, stat, subprocess, sys, time

SCHEMA=1
EXTENSIONS={'.mkv','.mp4','.m4v','.avi','.mov','.ts','.m2ts','.mts','.mpg','.mpeg','.webm','.wmv','.flv','.vob','.ogv','.3gp'}
STOP=''
ACTIVE=None

def identity(s):
    # jq bridges host/worker JSON. Nanosecond timestamps and 64-bit inodes
    # exceed IEEE-754's exact integer range, so identities travel as strings.
    return [str(v) for v in (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)]

def emit(event):
    sys.stdout.write(json.dumps(event,separators=(',',':'))+'\n');sys.stdout.flush()

def stop_handler(signum,frame):
    global STOP
    STOP='termination requested'

def kill_child(proc):
    if proc is None or proc.poll() is not None:return
    try:os.killpg(proc.pid,signal.SIGTERM)
    except ProcessLookupError:return
    try:proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:os.killpg(proc.pid,signal.SIGKILL)
        except ProcessLookupError:pass
        proc.wait(timeout=2)

def run_process(args,fd,seconds,beat,memory_mib):
    global ACTIVE
    def limits():
        resource.setrlimit(resource.RLIMIT_CORE,(0,0))
        memory=int(memory_mib)*1024*1024
        resource.setrlimit(resource.RLIMIT_AS,(memory,memory))
    started=time.monotonic(); buffers={'out':b'','err':b''}; stopped=''
    try:
        ACTIVE=subprocess.Popen(args,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                                pass_fds=(fd,),start_new_session=True,preexec_fn=limits)
        with selectors.DefaultSelector() as selector:
            selector.register(ACTIVE.stdout,selectors.EVENT_READ,'out');selector.register(ACTIVE.stderr,selectors.EVENT_READ,'err')
            while selector.get_map() or ACTIVE.poll() is None:
                beat()
                if STOP or time.monotonic()-started>=seconds:
                    stopped='cancelled' if STOP else 'timeout';kill_child(ACTIVE)
                for key,_ in selector.select(0.5):
                    data=os.read(key.fileobj.fileno(),65536)
                    if not data:selector.unregister(key.fileobj);continue
                    buffers[key.data]=(buffers[key.data]+data)[-262144:]
                if stopped and ACTIVE.poll() is not None and not selector.get_map():break
        code=ACTIVE.wait(timeout=2)
        return {'code':code,'out':buffers['out'].decode(errors='replace'),'err':buffers['err'].decode(errors='replace'),
                'stop':stopped,'wall':time.monotonic()-started}
    finally:
        kill_child(ACTIVE)
        if ACTIVE:
            for pipe in (ACTIVE.stdout,ACTIVE.stderr):
                if pipe:pipe.close()
        ACTIVE=None

# Policy 4: probe diagnostics never prove corruption. Successful decoding still
# requires positive frames and complete range progress; unknown stderr is reviewed.
PROOF_VERSION=4

def benign_diagnostics(text):
    lines=[line.strip() for line in text.splitlines() if line.strip()]
    lines=[re.sub(r'^(?:\[[^\]]+\]\s*)+','',line) for line in lines]
    return bool(lines) and any(not line.lower().startswith('last message repeated') for line in lines) and all(re.fullmatch(r'SEI type 5 size \d+ truncated at \d+|number of reference frames \(0\+\d+\) exceeds max \(\d+; probably corrupt input\), discarding one|Last message repeated \d+ times',line,re.I) for line in lines)

def failure_signature(text):
    # Normalise presentation noise only; preserve stream numbers, error numbers,
    # offsets and codec details. Distinct failure positions remain distinct keys.
    lines=[]
    for line in text.lower().splitlines():
        if re.search(r'last message repeated \d+ times',line):continue
        line=re.sub(r'0x[0-9a-f]+','ADDRESS',line)
        line=re.sub(r'^\[?\d{4}-\d\d-\d\d[ t]\d\d:\d\d:\d\d(?:[.,]\d+)?\]?\s*','',line)
        line=' '.join(line.split())
        if line:lines.append(line)
    return hashlib.sha256('\n'.join(sorted(set(lines))).encode()).hexdigest()

def complete_progress(result,expected,video=True):
    frames=[int(v) for v in re.findall(r'^frame=\s*([0-9]+)',result['out'],re.M)]
    times=[int(v)/1000000 for v in re.findall(r'^out_time_us=([0-9]+)',result['out'],re.M)]
    # Scale tolerance for short tails; never exempt the entire final range.
    tolerance=min(0.5,max(0.02,expected*0.02))
    return bool(times and max(times)>0 and max(times)>=expected-tolerance and (not video or (frames and max(frames)>0)))

def classify(result,stage='decode',codecs=()):
    if result['stop']:return result['stop']
    text=result['err'].lower()
    if result['code']<0 or result['code'] in (126,127,137,139,143):return 'unverified_process_exit'
    if re.search(r'cannot allocate memory|out of memory|resource temporarily unavailable|pthread_create|permission denied|operation not permitted|decoder .*not found|unknown decoder|unsupported codec|not implemented',text):
        return 'unverified_tool_or_resource'
    if 'input/output error' in text:return 'read_error'
    if re.search(r'non.monoton|invalid.*timestamp|error.*(?:muxing|muxer|filter|encoder|output)|failed to (?:configure|inject)|unable to.*output|error opening output',text):
        return 'unverified_pipeline_error'
    if result['code']==0:
        return 'passed' if not text.strip() or benign_diagnostics(text) else 'unverified_decoder_warning'
    if stage=='probe':return 'unverified_container'
    if re.search(r'error (while|during) decoding|invalid nal|error submitting packet to decoder|error splitting the input into nal|decode_slice_header error|invalid .* (?:frame|slice|macroblock)|corrupt decoded frame',text) and not benign_diagnostics(text):
        return 'decode_error'
    names='|'.join(re.escape(v.lower()) for v in codecs if isinstance(v,str) and v)
    if names and re.search(r'\[[^\]\n]*\b(?:'+names+r')\s+@[^\]\n]*\]\s*[^\n]*(?:corrupt|truncat|invalid data|header damaged|crc mismatch)',text):
        return 'decode_error'
    return 'unverified_tool_error'

def validate_state(state,cfg):
    if not isinstance(state,dict) or state.get('schema')!=SCHEMA or not isinstance(state.get('files'),dict):raise ValueError('unsupported state schema')
    if state.get('hostRoot',cfg['hostRoot'])!=cfg['hostRoot'] or state.get('libraries',cfg['libraries'])!=cfg['libraries']:
        raise ValueError('state source/scope differs; explicit review required')
    for path,entry in state['files'].items():
        if (not isinstance(path,str) or path.startswith('/') or os.path.normpath(path)!=path or path.split('/')[0] not in cfg['libraries']
                or not isinstance(entry,dict) or not isinstance(entry.get('identity'),list) or len(entry['identity'])!=5):
            raise ValueError('invalid state file identity/path')
        for field in ('offset','verifiedAt','probeAt','notBefore','chunkSeconds','seekWarmupSeconds'):
            value=entry.get(field,0)
            if not isinstance(value,(int,float)) or not math.isfinite(value) or value<0:raise ValueError('invalid numeric progress')
    return state

class Audit:
    def __init__(self,cfg,state):
        self.cfg=cfg;self.state=validate_state(state,cfg);self.start=time.monotonic();self.deadline=self.start+cfg['budgetSeconds']
        self.active_range=None;self.active_stage=None
        self.runEpoch=int(time.time());self.last_heartbeat=0;self.last_checkpoint=0;self.dirty=True
        self.state.update(hostRoot=cfg['hostRoot'],libraries=cfg['libraries'])
        self.state.setdefault('resolved',[]);self.state.setdefault('runs',[])
        if self.state.get('toolset') and self.state['toolset']!=cfg['toolset']:
            for entry in self.state['files'].values():
                if entry.get('issue'):
                    entry['notBefore']=0;entry['probeAt']=0;entry['issue']['confirmedRuns']=0;entry['issue']['confirmed']=False;entry['issue']['lastConfirmedRunAt']=0
        self.state['toolset']=cfg['toolset']
        for entry in self.state['files'].values():
            if (entry.get('offset',0)>0 or entry.get('verifiedAt',0)>0) and entry.get('verificationPolicy')!=2:
                entry['priorCoverage']={'offset':entry.get('offset',0),'verifiedAt':entry.get('verifiedAt',0),'reason':'Duration-proof policy upgraded; metadata retained'}
                entry.update(offset=0,verifiedAt=0,notBefore=0)
                entry.pop('coverage',None)
            entry['verificationPolicy']=2
        for entry in self.state['files'].values():
            old=entry.get('issue')
            if old and old.get('kind')=='decode_error' and old.get('proofVersion')!=PROOF_VERSION:
                old.update(kind='unverified_prior_decoder_evidence' if old.get('origin')=='decode' else 'unverified_legacy_evidence',confirmed=False,confirmedRuns=0,lastConfirmedRunAt=0)
                entry.update(notBefore=0,probeAt=0,verifiedAt=0,offset=old.get('offset') or 0)
                entry.pop('coverage',None)
        self.stats={'startedAt':int(time.time()),'inventoryComplete':False,'inventoryFiles':0,'inventoryErrors':0,'symlinksSkipped':0,
                    'unsupportedImages':0,'newChanged':0,'quickPassed':0,'segmentsPassed':0,'cyclesCompleted':0,
                    'decodeWallSeconds':0.0,'mediaSecondsDecoded':0.0,'reason':'','mode':cfg['mode']}
        self.found=set();self.seen=set()
        self.initial_progress={p:(float(e.get('duration',0)) if e.get('verifiedAt',0)>0 and self.runEpoch-e['verifiedAt']<cfg['recheckDays']*86400 else float(e.get('offset',0))) for p,e in self.state['files'].items()}
        self.run_paths={name:set() for name in ('attempted','opened','probed','ranges','completed')}
        self.stats['inventoryByLibrary']={name:{'status':'not_started','files':0} for name in cfg['libraries']}
    def progress_counts(self):
        for key,name in (('uniqueFilesAttempted','attempted'),('uniqueFilesOpened','opened'),('uniqueMetadataPassed','probed'),('uniqueFilesDecoded','ranges'),('uniqueFilesCompleted','completed')):
            self.stats[key]=len(self.run_paths[name])
        self.stats['uniqueFilesPartiallyDecoded']=len(self.run_paths['ranges']-self.run_paths['completed'])
    def attempt(self,path,entry,outcome):
        kind={'next':'decode_range_passed','complete':'full_cycle_passed','recheck':'repeat_check_pending','retry':'transient_retry_pending','changed':'deferred_source_changed','issue':(entry.get('issue') or {}).get('kind','finding_recorded')}.get(outcome,outcome)
        self.state.setdefault('lastActivity',{})['attempt']={'path':path,'epoch':int(time.time()),'kind':kind,'nextOffset':entry.get('offset',0),'duration':entry.get('duration')}
        self.dirty=True
    def activity(self,path,entry,kind):
        record={'path':path,'epoch':int(time.time()),'kind':kind,'nextOffset':entry.get('offset',0),'duration':entry.get('duration')}
        self.state.setdefault('lastActivity',{})['success']=record
        if kind!='metadata_probe_passed':self.state['lastActivity']['decoded']=record
        self.dirty=True
    def beat(self):
        if time.monotonic()-self.last_heartbeat>=10:
            emit({'type':'heartbeat','elapsed':int(time.monotonic()-self.start)})
            self.last_heartbeat=time.monotonic()
    def remaining(self):return max(0,self.deadline-time.monotonic())
    def stopped(self):return bool(STOP) or self.remaining()<3
    def checkpoint(self,force=False):
        if not force and (not self.dirty or time.monotonic()-self.last_checkpoint<60):return
        self.progress_counts()
        self.state['lastRun']=dict(self.stats,elapsedSeconds=int(time.monotonic()-self.start))
        raw=json.dumps(self.state,separators=(',',':')).encode()
        if len(raw)>self.cfg['maxStateBytes']:raise ValueError('state exceeds configured byte limit; previous checkpoint retained')
        payload=base64.b64encode(gzip.compress(raw,compresslevel=3,mtime=0)).decode()
        if len(payload)<=131072:
            emit({'type':'checkpoint','payload':payload,'stats':self.state['lastRun']})
        else:
            # Keep every protocol line bounded: Bash never needs to hold a
            # multi-megabyte state snapshot or pass it as an executable argument.
            emit({'type':'checkpoint-begin','length':len(payload)})
            for offset in range(0,len(payload),65536):
                emit({'type':'checkpoint-chunk','data':payload[offset:offset+65536]})
            emit({'type':'checkpoint-end','stats':self.state['lastRun']})
        self.last_checkpoint=time.monotonic();self.dirty=False
    def issue(self,path,entry,kind,evidence,offset=None,confirmed=False,confirmation_key=None):
        entry['healthyRangeStreak']=0
        old=entry.get('issue') or {};now=int(time.time())
        confirmed=bool(confirmed and kind=='decode_error' and confirmation_key)
        same=old.get('identity')==entry['identity'] and old.get('kind')==kind and old.get('confirmed') and old.get('confirmationKey')==confirmation_key and old.get('proofVersion')==PROOF_VERSION
        observation_same=old.get('identity')==entry['identity'] and old.get('kind')==kind
        observations=old.get('observationRuns',1) if observation_same else 0
        if not observation_same or old.get('lastObservedRunAt')!=self.runEpoch:observations+=1
        transient=kind in ('unverified_timeout','unverified_tool_or_resource','unverified_process_exit')
        runs=(old.get('confirmedRuns',1) if same else 0)
        if confirmed and (not same or old.get('lastConfirmedRunAt')!=self.runEpoch):runs+=1
        slot='auditIssue' if old.get('identity')==entry['identity'] and old.get('kind') in ('decode_error','recoverable_media_defect','auxiliary_track_error','unverified_prior_decoder_evidence') and kind not in ('decode_error','recoverable_media_defect','auxiliary_track_error') else 'issue'
        if slot=='auditIssue':
            old=entry.get(slot) or {};observation_same=old.get('identity')==entry['identity'] and old.get('kind')==kind
            observations=old.get('observationRuns',0)+(old.get('lastObservedRunAt')!=self.runEpoch) if observation_same else 1
        self.last_issue_slot=slot
        entry[slot]={'id':hashlib.sha256((path+('' if slot=='issue' else '|audit')).encode(errors='surrogateescape')).hexdigest()[:16],
                        'kind':kind,'firstSeen':old.get('firstSeen',now) if observation_same else now,'lastSeen':now,'confirmed':confirmed,
                        'confirmedRuns':runs if confirmed else 0,'lastConfirmedRunAt':self.runEpoch if confirmed else 0,
                        'proofVersion':PROOF_VERSION,'origin':'decode' if confirmation_key else 'unverified','confirmationKey':confirmation_key,
                        'observationRuns':observations,'lastObservedRunAt':self.runEpoch,'alertable':not transient or observations>=2 or (observation_same and now-old.get('firstSeen',now)>=86400),
                        'stage':self.active_stage or ('decode' if offset is not None else 'storage'),'failedRange':dict(self.active_range) if offset is not None and self.active_range else old.get('failedRange'),
                        'offset':offset,'evidence':evidence[-3000:],'identity':entry['identity'],'cleanRechecks':0}
        if old.get('identity')==entry['identity'] and old.get('failedRange') and entry[slot].get('failedRange'):
            entry[slot]['failedRange']={'start':min(old['failedRange']['start'],entry[slot]['failedRange']['start']),'end':max(old['failedRange']['end'],entry[slot]['failedRange']['end'])}
        entry['notBefore']=now+(7*86400 if kind in ('decode_error','read_error','intermittent_error') else 86400)
        self.dirty=True
    def resolve(self,path,entry,reason,slot='issue'):
        if entry.get(slot):
            self.state['resolved'].append(dict(entry.pop(slot),path=path,resolvedAt=int(time.time()),resolution=reason))
            self.dirty=True
    def inventory(self):
        root=self.cfg['root'];complete=True
        if self.cfg.get('targeted'):
            for rel in self.cfg.get('recoveryPriority',[])[:4]:
                if os.path.normpath(rel)!=rel or rel.startswith('/') or rel.split('/')[0] not in self.cfg['libraries']:raise ValueError('unsafe replacement path')
                p=os.path.join(root,rel)
                try:
                    if os.path.realpath(p)!=p:raise ValueError('symlinked replacement')
                    st=os.stat(p,follow_symlinks=False)
                    if not stat.S_ISREG(st.st_mode):raise ValueError('not regular replacement')
                    self.found.add(rel);self.seen.add(rel);current=identity(st);old=self.state['files'].get(rel)
                    if not old or old['identity']!=current:
                        self.state['files'][rel]={'verificationPolicy':2,'identity':current,'observedAt':int(time.time()),'probeAt':0,'verifiedAt':0,'offset':0,'chunkSeconds':self.cfg['segmentSeconds'],'notBefore':0,'cycleLane':'new'}
                        if old and old.get('issue'):self.state['files'][rel]['issue']=old['issue'];self.state['files'][rel]['replacementPending']=True
                except OSError:self.stats['inventoryErrors']+=1
            for rel,after in self.cfg.get('recheckAfter',{}).items():
                e=self.state['files'].get(rel)
                if rel in self.found and e and 0<e.get('verifiedAt',0)<after:
                    e.update(verifiedAt=0,offset=0,notBefore=0)
            for rel in self.cfg.get('evidencePaths',[]):
                e=self.state['files'].get(rel)
                if rel in self.found and e and e.get('issue') and e['issue'].get('identity')==e['identity']:
                    e['notBefore']=0
                    if e['issue'].get('offset') is not None:e['offset']=e['issue']['offset']
            for library in self.cfg['libraries']:
                count=sum(p.split('/')[0]==library for p in self.found)
                self.stats['inventoryByLibrary'][library]={'status':'targeted' if count else 'not_in_targeted_scope','files':count}
            self.stats.update(inventoryFiles=len(self.found),inventoryComplete=False,targeted=True)
            self.checkpoint(True);return
        for library in self.cfg['libraries']:
            before_files=len(self.found);before_errors=self.stats['inventoryErrors']
            library_path=os.path.join(root,library)
            if not os.path.isdir(library_path) or os.path.islink(library_path):
                self.stats['inventoryErrors']+=1;complete=False
                self.stats['inventoryByLibrary'][library]={'status':'unavailable','files':0}
                continue
            stack=[library_path]
            while stack:
                self.beat()
                if self.stopped():complete=False;break
                directory=stack.pop()
                try:
                    with os.scandir(directory) as entries:
                        for item in entries:
                            self.beat()
                            if self.stopped():complete=False;break
                            if item.is_symlink():self.stats['symlinksSkipped']+=1;continue
                            if item.is_dir(follow_symlinks=False):stack.append(item.path);continue
                            if not item.is_file(follow_symlinks=False):continue
                            ext=os.path.splitext(item.name)[1].lower()
                            if ext in ('.iso','.img'):self.stats['unsupportedImages']+=1
                            if ext not in EXTENSIONS:continue
                            rel=os.path.relpath(item.path,root);self.seen.add(rel)
                            current=identity(item.stat(follow_symlinks=False));self.found.add(rel)
                            old=self.state['files'].get(rel)
                            if old is None or old['identity']!=current:
                                entry={'verificationPolicy':2,'identity':current,'observedAt':int(time.time()),'probeAt':0,'verifiedAt':0,'offset':0,'chunkSeconds':self.cfg['segmentSeconds'],
                                       'lastAttemptAt':0,'notBefore':0,'cycleLane':'new'}
                                if old and old.get('issue'):entry['issue']=old['issue'];entry['replacementPending']=True
                                self.state['files'][rel]=entry;self.stats['newChanged']+=1;self.dirty=True
                            if len(self.state['files'])>200000:raise ValueError('inventory exceeds 200000 files; explicit scope review required')
                except OSError:
                    self.stats['inventoryErrors']+=1;complete=False
            self.stats['inventoryByLibrary'][library]={'status':'complete' if not self.stopped() and self.stats['inventoryErrors']==before_errors else 'partial','files':len(self.found)-before_files}
            if self.stopped():break
        self.stats['inventoryFiles']=len(self.found);self.stats['inventoryComplete']=complete
        if complete:
            for path in list(self.state['files']):
                if path not in self.seen:
                    self.resolve(path,self.state['files'][path],'File no longer in a complete library inventory; no repair was performed')
                    self.resolve(path,self.state['files'][path],'File no longer in a complete library inventory; audit limitation closed without repair','auditIssue')
                    del self.state['files'][path];self.dirty=True
        self.checkpoint(True)
    def open_file(self,path,entry):
        full=os.path.join(self.cfg['root'],path)
        if os.path.commonpath((self.cfg['root'],os.path.realpath(full)))!=self.cfg['root']:raise ValueError('source root escape')
        fd=os.open(full,os.O_RDONLY|os.O_NOFOLLOW)
        if not stat.S_ISREG(os.fstat(fd).st_mode) or identity(os.fstat(fd))!=entry['identity']:
            os.close(fd);raise FileNotFoundError('file identity changed')
        return fd
    def unchanged(self,path,entry,fd):
        try:
            return identity(os.fstat(fd))==entry['identity'] and identity(os.stat(os.path.join(self.cfg['root'],path),follow_symlinks=False))==entry['identity']
        except OSError:return False
    def run_tool(self,args,fd,seconds):
        if self.stopped():return {'code':-1,'out':'','err':'','stop':'cancelled','wall':0}
        return run_process(args,fd,min(seconds,max(1,self.remaining()-2)),self.beat,self.cfg['memoryMiB'])
    def probe(self,path,entry,fd):
        self.active_stage='probe'
        args=['ffprobe','-v','error','-protocol_whitelist','file','-show_entries',
              'format=duration,start_time:stream=index,codec_type,codec_name,duration,start_time:stream_disposition=attached_pic,default','-of','json',f'/proc/self/fd/{fd}']
        result=self.run_tool(args,fd,20);kind=classify(result,stage="probe")
        if not self.unchanged(path,entry,fd):
            entry['notBefore']=int(time.time())+300;return False
        if kind!='passed':
            if kind not in ('cancelled','timeout'):self.issue(path,entry,kind,result['err'])
            else:self.issue(path,entry,'unverified_timeout','FFprobe exceeded its time budget; no corruption conclusion')
            return False
        try:
            data=json.loads(result['out']);streams=data['streams']
            videos=[s['index'] for s in streams if s.get('codec_type')=='video' and not s.get('disposition',{}).get('attached_pic')]
            audio=[s['index'] for s in streams if s.get('codec_type')=='audio']
            duration=float(data.get('format',{}).get('duration','nan'))
            if not videos or not math.isfinite(duration) or duration<=0 or duration>7*86400:raise ValueError('video/duration unavailable')
        except (ValueError,TypeError,KeyError):
            self.issue(path,entry,'unverified_metadata','No usable video stream or finite duration; deep decode coverage cannot be established')
            return False
        if result['err'].strip():
            entry['advisory']={'kind':'nonfatal_probe_diagnostic','evidence':result['err'][-3000:],'observedAt':int(time.time())}
            if (entry.get('issue') or {}).get('kind')=='unverified_legacy_evidence':
                self.resolve(path,entry,'Legacy probe-only corruption classification withdrawn: valid metadata with nonfatal diagnostic; media unchanged, full decode verification still pending')
        entry.update(probeAt=int(time.time()),duration=duration,video=videos,audio=audio,
                     streamDetails=[{'index':v['index'],'type':v.get('codec_type'),'codec':v.get('codec_name'),'default':bool(v.get('disposition',{}).get('default')),'duration':v.get('duration'),'start':v.get('start_time')} for v in streams if v['index'] in videos+audio])
        entry['formatStart']=data.get('format',{}).get('start_time',0)
        for slot in ('issue','auditIssue'):
            if (entry.get(slot) or {}).get('stage')=='probe':self.resolve(path,entry,'Metadata probe succeeded on the unchanged file; prior probe limitation resolved; deep coverage remains separate',slot)
        self.run_paths['probed'].add(path);self.activity(path,entry,'metadata_probe_passed')
        self.stats['quickPassed']+=1;self.dirty=True
        return True
    def retry_transient(self,entry):
        issue=entry.get('auditIssue') or entry.get('issue') or {}
        if issue.get('kind') not in ('unverified_timeout','unverified_tool_or_resource','unverified_process_exit'):return False
        if entry.get('retryRunAt')!=self.runEpoch:entry.update(retryRunAt=self.runEpoch,retryCount=0)
        if entry.get('retryCount',0)>=1 or self.remaining()<30:return False
        entry['retryCount']=entry.get('retryCount',0)+1;entry['notBefore']=0
        if issue.get('kind')!='unverified_timeout':entry['chunkSeconds']=max(15,float(entry.get('chunkSeconds',self.cfg['segmentSeconds']))/2)
        return True
    def normal_confirmation(self,path,entry,fd,args,offset,span):
        # Isolate streams only for suspicious ranges. Normal handling is an
        # independent check, not permission to discard/conceal errors as healthy.
        deadline=time.monotonic()+min(90,max(0,self.remaining()-5))
        if deadline-time.monotonic()<5:return 'unverified_confirmation_budget',[],None
        if not entry.get('streamDetails') and not self.probe(path,entry,fd):
            return 'unverified_stream_confirmation',[],None
        self.active_stage='decode'
        details=entry['streamDetails'];primary=set()
        for media_type in ('video','audio'):
            group=[v for v in details if v['type']==media_type]
            if group:primary.add(next((v['index'] for v in group if v['default']),group[0]['index']))
        details=sorted(details,key=lambda v:(v['index'] not in primary,v['index']))
        evidence=[];failures=[];uncertain=False
        if len(details)>8:return 'unverified_stream_confirmation',[],None
        for stream in details:
            if deadline-time.monotonic()<5:return 'unverified_confirmation_budget',evidence,None
            isolated=[];i=0
            while i<len(args):
                if args[i]=='-xerror':i+=1;continue
                if args[i] in ('-max_error_rate','-map'):i+=2;continue
                isolated.append(args[i]);i+=1
            # No seek initialization is needed near the beginning. For later
            # ranges use 120 seconds of context; cost stays wall-time bounded.
            seek=max(0,offset-120);length=span+offset-seek
            isolated[isolated.index('-ss')+1]=str(seek)
            isolated[isolated.index('-t')+1]=str(length)
            isolated[isolated.index('-sn'):isolated.index('-sn')]=['-map','0:'+str(stream['index'])]
            expected=length
            try:
                stream_duration=float(stream.get('duration'));stream_start=float(stream.get('start') or 0)-float(entry.get('formatStart') or 0)
                if math.isfinite(stream_duration) and stream_duration>0 and math.isfinite(stream_start):expected=max(0,min(seek+length,stream_start+stream_duration)-max(seek,stream_start))
            except (TypeError,ValueError):pass
            if expected==0:
                evidence.append(dict(stream,primary=stream['index'] in primary,exit=0,kind='outside_stream_timeline',complete=True,expectedSeconds=0))
                continue
            result=self.run_tool(isolated,fd,min(self.cfg['segmentWallSeconds'],deadline-time.monotonic()))
            self.stats['decodeWallSeconds']+=result['wall']
            if not self.unchanged(path,entry,fd):return 'changed',evidence,None
            kind=classify(result,codecs=[stream.get('codec')])
            complete=complete_progress(result,expected,video=stream['type']=='video')
            evidence.append(dict(stream,index=stream['index'],primary=stream['index'] in primary,exit=result['code'],kind=kind,complete=complete,expectedSeconds=expected,seek=seek,length=length,evidence=result['err'][-1200:]))
            if kind=='decode_error':failures.append((stream,failure_signature(result['err'])))
            elif result['code']==0 and complete and kind in ('passed','unverified_decoder_warning'):
                pass
            else:uncertain=True
        # Auxiliary defects or mixed/incomplete evidence cannot authorize a
        # whole-file replacement. Zero-exit decoding with errors is not a pass.
        if uncertain:return 'unverified_stream_confirmation',evidence,None
        if failures and all(v['index'] not in primary for v,_ in failures):return 'auxiliary_track_error',evidence,None
        if failures:
            key=hashlib.sha256(json.dumps([entry['identity'],offset,span,self.cfg['toolset'],[(v['index'],sig) for v,sig in failures],PROOF_VERSION]).encode()).hexdigest()
            return 'decode_error',evidence,key
        return 'recoverable_media_defect',evidence,None

    def segment(self,path,entry,fd):
        self.active_stage='decode'
        offset=float(entry.get('offset',0));duration=entry['duration']
        for slot in ('issue','auditIssue'):
            incident=entry.get(slot) or {}
            if incident and not entry.get('replacementPending') and incident.get('stage')!='probe':
                failed=incident.get('failedRange')
                if not failed:
                    start=float(incident.get('offset') or 0)
                    end=max([float(v.get('seek',start))+float(v.get('length',0)) for v in incident.get('streamEvidence',[])] or [min(duration,start+self.cfg['segmentSeconds'])])
                    failed={'start':start,'end':min(duration,end)};incident['failedRange']=failed
                if offset<failed['start'] or offset>=failed['end']:offset=failed['start'];entry['offset']=offset

        span=min(float(entry.get('chunkSeconds',self.cfg['segmentSeconds'])),duration-offset)
        if span<=0:return 'complete'
        self.active_range={'start':offset,'end':offset+span}
        seek=max(0,offset-max(2,min(30,float(entry.get("seekWarmupSeconds",2)))));length=span+offset-seek
        args=['ffmpeg','-hide_banner','-nostdin','-v','error','-xerror','-max_error_rate','0','-nostats','-stats_period','5',
              '-protocol_whitelist','file','-threads:v',str(self.cfg['threads']),'-threads:a','1',
              '-ss',str(seek),'-i',f'/proc/self/fd/{fd}','-t',str(length)]
        for index in entry['video']+entry['audio']:args+=['-map',f'0:{index}']
        args+=['-sn','-dn','-filter_threads','1','-filter_complex_threads','1','-threads',str(self.cfg['threads']),
               '-progress','pipe:1','-f','null','/dev/null']
        result=self.run_tool(args,fd,self.cfg['segmentWallSeconds']);kind=classify(result,codecs=[v.get('codec') for v in entry.get('streamDetails',[])])
        if kind=='unverified_tool_error' and not entry.get('streamDetails') and self.remaining()>25:
            if self.probe(path,entry,fd):kind=classify(result,codecs=[v.get('codec') for v in entry.get('streamDetails',[])])
        self.active_stage='decode'
        self.stats['decodeWallSeconds']+=result['wall']
        if not self.unchanged(path,entry,fd):return 'changed'
        if kind in ('cancelled','timeout'):
            if kind=='timeout' and self.remaining()>5:
                entry['chunkSeconds']=max(15,span/2);self.issue(path,entry,'unverified_timeout','Decode range timed out; range size reduced, offset unchanged',offset)
            return 'retry' if kind=='timeout' and self.retry_transient(entry) else kind
        if kind=='decode_error' and self.remaining()>30:
            # Retry with additional preceding context to avoid promoting seek
            # initialization failures. The same target range must still fail.
            retry=list(args);retry_seek=max(0,offset-30)
            retry[retry.index('-ss')+1]=str(retry_seek)
            retry[retry.index('-t')+1]=str(span+offset-retry_seek)
            again=self.run_tool(retry,fd,self.cfg['segmentWallSeconds']);self.stats['decodeWallSeconds']+=again['wall']
            if not self.unchanged(path,entry,fd):return 'changed'
            again_kind=classify(again,codecs=[v.get('codec') for v in entry.get('streamDetails',[])])
            if again_kind in ('cancelled','timeout'):return again_kind
            consistent=again_kind=='decode_error' and failure_signature(result['err'])==failure_signature(again['err'])
            if again_kind=='passed':
                # A successful context retry must pass the same positive frame /
                # duration checks below. Retain the diagnostic, not a corruption
                # incident, and use that context on subsequent range rechecks.
                entry['seekWarmupSeconds']=30
                entry['advisory']={'kind':'seek_context_recovered','evidence':result['err'][-3000:],'observedAt':int(time.time())}
                result=again;kind='passed';length=span+offset-retry_seek
            else:
                if consistent:
                    outcome,details,key=self.normal_confirmation(path,entry,fd,retry,offset,span)
                    if outcome=='changed':return 'changed'
                    self.issue(path,entry,outcome,result['err'],offset,outcome=='decode_error',key)
                    entry[self.last_issue_slot]['streamEvidence']=details
                    entry[self.last_issue_slot]['confirmationMethod']='normal-isolated-streams-v1'
                else:
                    self.issue(path,entry,'intermittent_error' if again_kind=='decode_error' else again_kind,again['err'],offset)
                    if self.retry_transient(entry):return 'retry'
                return 'issue'
        if kind!='passed':
            self.issue(path,entry,kind,result['err'],offset);return 'retry' if self.retry_transient(entry) else 'issue'
        frames=[int(v) for v in re.findall(r'^frame=\s*([0-9]+)',result['out'],re.M)]
        output_times=[int(v) for v in re.findall(r'^out_time_us=([0-9]+)',result['out'],re.M)]
        if not frames or max(frames)==0 or not output_times or max(output_times)<=0:
            self.issue(path,entry,'unverified_empty_decode','Decoder returned success without positive video/frame progress; range not verified',offset)
            return 'issue'
        expected_end=offset+span
        # A successful but substantially short decode is not silently credited
        # for a duration advertised only by a broken/truncated container header.
        if not complete_progress(result,length):
            self.issue(path,entry,'unverified_short_decode','Decoded output ended before the planned range; duration/header review required',offset)
            return 'issue'
        if result['err'].strip():entry['advisory']={'kind':'nonfatal_decode_diagnostic','evidence':result['err'][-3000:],'observedAt':int(time.time())}
        rewind=None
        for slot in ('issue','auditIssue'):
            old=entry.get(slot)
            if not old or entry.get('replacementPending'):continue
            failed=old.get('failedRange')
            if not failed:continue
            until=old.get('cleanUntil',failed['start'])
            if offset<=until+0.001 and expected_end>until:old['cleanUntil']=min(expected_end,failed['end'])
            if old.get('cleanUntil',failed['start'])>=failed['end']-0.001:
                old['cleanRechecks']=old.get('cleanRechecks',0)+1;old['cleanUntil']=failed['start']
                if old['cleanRechecks']>=2:self.resolve(path,entry,'Two complete unchanged-file rechecks covered the entire original failed interval; remaining file coverage is tracked separately',slot)
                else:rewind=failed['start'] if rewind is None else min(rewind,failed['start'])
        entry['offset']=expected_end;entry['notBefore']=0
        entry['healthyRangeStreak']=entry.get('healthyRangeStreak',0)+1
        if entry['healthyRangeStreak']>=3 and not entry.get('issue') and not entry.get('auditIssue'):
            entry['chunkSeconds']=min(self.cfg['segmentSeconds'],max(15,float(entry.get('chunkSeconds',self.cfg['segmentSeconds']))*2));entry['healthyRangeStreak']=0
        if rewind is not None:entry['offset']=rewind
        self.run_paths['ranges'].add(path);self.activity(path,entry,'decode_range_passed')
        self.stats['segmentsPassed']+=1;self.stats['mediaSecondsDecoded']+=span;self.dirty=True
        if expected_end>=duration-0.05 and not entry.get('auditIssue') and (not entry.get('issue') or entry.get('replacementPending')):
            entry.update(verificationPolicy=2,verifiedAt=int(time.time()),offset=0,probeAt=int(time.time()),coverage='all_planned_segments_decoded')
            if entry.pop('replacementPending',False):self.resolve(path,entry,'Replacement file completed all planned decode ranges; source version changed')
            entry.pop('cycleLane',None)
            self.run_paths['completed'].add(path);self.activity(path,entry,'full_cycle_passed')
            self.stats['cyclesCompleted']+=1;return 'complete'
        return 'recheck' if rewind is not None else 'next'
    def work(self,path,probe_only=False):
        self.run_paths['attempted'].add(path)
        entry=self.state['files'][path];entry['lastAttemptAt']=int(time.time());entry.pop('deferredReason',None);self.dirty=True
        self.attempt(path,entry,'metadata_probe_in_progress' if not entry.get('probeAt') else 'decode_in_progress')
        if time.time()-max(map(int,entry['identity'][3:]))/1000000000<self.cfg['settleSeconds']:
            entry['notBefore']=int(time.time())+self.cfg['settleSeconds'];entry['deferredReason']='Recently changed file; ten-minute settle guard'
            self.attempt(path,entry,'deferred_recent_change')
            return
        fd=None;start=time.monotonic();outcome='interrupted_or_unverified'
        try:
            fd=self.open_file(path,entry);self.run_paths['opened'].add(path)
            if not entry.get('probeAt') and not self.probe(path,entry,fd):
                if not self.retry_transient(entry) or not self.probe(path,entry,fd):return
            if probe_only:outcome='metadata_probe_passed';return
            while not self.stopped() and time.monotonic()-start<self.cfg['fileSliceSeconds']:
                outcome=self.segment(path,entry,fd)
                self.attempt(path,entry,outcome)
                self.checkpoint()
                if outcome=='changed':entry['notBefore']=int(time.time())+300;entry['deferredReason']='File identity changed during decoding; no range credit'
                if path in self.cfg.get('evidencePaths',[]) and outcome!='recheck':break
                if outcome not in ('next','recheck','retry'):break
        except FileNotFoundError:
            outcome='deferred_source_changed'
            entry['notBefore']=int(time.time())+300;entry['deferredReason']='File removed/changed before opening; no range credit'
        except OSError as error:
            kind='read_error' if error.errno==errno.EIO else 'unverified_permissions_or_storage'
            outcome=kind;self.issue(path,entry,kind,type(error).__name__+': '+str(error.errno))
        finally:
            if outcome=='interrupted_or_unverified' and entry.get('issue'):outcome=entry['issue']['kind']
            self.attempt(path,entry,outcome)
            if fd is not None:os.close(fd)
            self.checkpoint()
    def capacity_metrics(self):
        files=self.state['files'];now=int(time.time())
        eligible=[r for r in self.state.get('capacityRuns',[]) if r.get('budgetSeconds',0)>=3600 and not r.get('failed')]
        pending=[e for e in files.values() if not e.get('verifiedAt') or now-e['verifiedAt']>=self.cfg['recheckDays']*86400]
        known=sum(max(0,float(e.get('duration',0))-float(e.get('offset',0))) for e in pending)
        weekly=(sum(r.get('netMediaSeconds',0) for r in eligible)/len(eligible)*2) if eligible else 0
        days=known/weekly*7 if weekly>0 else None
        stalled=len(eligible)>=3 and all(r.get('netMediaSeconds',0)==0 for r in eligible[-3:]) and bool(pending)
        status='collecting' if len(eligible)<3 else 'stalled' if stalled else 'behind_target' if days is not None and days>self.cfg['recheckDays'] else 'within_measured_budget'
        self.state['capacity']={'status':status,'samples':len(eligible),'runsPerWeek':2,'runBudgetSeconds':7200,'knownRemainingSeconds':known,'unknownDurations':sum(not e.get('duration') for e in pending),'observedNetMediaSecondsPerWeek':weekly,'knownBacklogDaysLowerBound':days,'attention':status in ('stalled','behind_target')}
    def finish(self):
        self.progress_counts()
        now=int(time.time());files=self.state['files'];stats=self.stats
        stats.update(elapsedSeconds=int(time.monotonic()-self.start),finishedAt=now,
                     pendingInitial=sum(not f.get('verifiedAt') and f.get('cycleLane')!='old' for f in files.values()),
                     pendingPeriodic=sum(f.get('cycleLane')=='old' or (bool(f.get('verifiedAt')) and now-f['verifiedAt']>=self.cfg['recheckDays']*86400) for f in files.values()),
                     activeFindings=sum(bool(f.get('issue'))+bool(f.get('auditIssue')) for f in files.values()),
                     deferredFiles=sum(f.get('notBefore',0)>now for f in files.values()),
                     inProgress=sum(f.get('offset',0)>0 for f in files.values()))
        self.state['resolved']=[r for r in self.state['resolved'] if now-r['resolvedAt']<=30*86400]
        if self.cfg['mode']=='scan' and not self.cfg.get('targeted'):
            duration_known=sum(float(f.get('duration',0)) for f in files.values())
            outstanding=sum(max(0,float(f.get('duration',0))-float(f.get('offset',0))) for f in files.values() if not f.get('verifiedAt') or now-f.get('verifiedAt',0)>=self.cfg['recheckDays']*86400)
            stats['budgetSeconds']=self.cfg['budgetSeconds']
            stats['netMediaSeconds']=sum(max(0,(float(e.get('duration',0)) if e.get('verifiedAt') else float(e.get('offset',0)))-self.initial_progress.get(p,0)) for p,e in files.items() if not e.get('issue') and not e.get('auditIssue'))
            stats['capacity']={'knownDurationSeconds':duration_known,'knownRemainingSeconds':outstanding,'unknownDurations':sum(not f.get('duration') for f in files.values()),'fullyVerified':sum(bool(f.get('verifiedAt')) for f in files.values())}
            history=[r for r in self.state.get('capacityRuns',[]) if r.get('finishedAt',0)!=now]
            self.state['capacityRuns']=(history+[dict(stats)])[-6:]
        self.capacity_metrics()
        self.state['runs']=(self.state['runs']+[dict(stats)])[-12:]
        self.state['toolset']=self.cfg['toolset'];self.dirty=True;self.checkpoint(True)
        emit({'type':'complete','stats':stats})
    def execute(self):
        self.inventory()
        if self.cfg['mode']=='inventory':self.stats['reason']='Inventory only; no media content read or decoded';self.finish();return
        for path in self.cfg.get('evidencePaths',[]):
            if path in self.found and not self.stopped():self.work(path);self.checkpoint()
        quick_deadline=self.start+min(self.cfg.get('quickBudgetSeconds',1800),self.cfg['budgetSeconds']*.25)
        for path in sorted(self.found,key=lambda p:(self.state['files'][p].get('lastAttemptAt',0),p)):
            if self.stopped() or time.monotonic()>=quick_deadline:break
            entry=self.state['files'][path]
            if not entry.get('probeAt') and entry.get('notBefore',0)<=time.time():
                self.work(path,probe_only=True);self.checkpoint()
        spent={'new':0.0,'old':0.0}
        while not self.stopped():
            now=int(time.time());new=[];old=[]
            for path in self.found:
                if path in self.cfg.get('evidencePaths',[]):continue
                f=self.state['files'][path]
                if f.get('notBefore',0)>now:continue
                if f.get('issue') or f.get('auditIssue'):new.append(path)
                elif not f.get('verifiedAt'):
                    (old if f.get('cycleLane')=='old' else new).append(path)
                elif now-f['verifiedAt']>=self.cfg['recheckDays']*86400:old.append(path)
            if not new and not old:break
            def order(path):
                f=self.state['files'][path]
                return (path not in self.cfg.get('recoveryPriority',[]),not bool(f.get('offset',0)),f.get('lastAttemptAt',0),f.get('verifiedAt',0),path)
            new.sort(key=order);old.sort(key=order)
            lane='new' if new and (not old or spent['new']<=0.6*sum(spent.values())) else 'old'
            path=(new if lane=='new' else old)[0]
            if lane=='old' and self.state['files'][path].get('verifiedAt'):
                # Start a fresh periodic cycle; mtime/size alone cannot prove
                # absence of bit rot since a previous successful decode.
                f=self.state['files'][path];f['previousVerifiedAt']=f['verifiedAt'];f['verifiedAt']=0;f['offset']=0;f['probeAt']=0;f['cycleLane']='old'
            started=time.monotonic();self.work(path);spent[lane]+=time.monotonic()-started
            # A segment stopped at the remaining run budget is not corruption.
            if self.remaining()<5:break
        self.stats['reason']=STOP or ('Runtime budget reached; queue resumes next schedule' if self.remaining()<5 else 'Eligible queue slice completed; deferred work remains explicit')
        self.finish()

def main():
    global STOP
    signal.signal(signal.SIGTERM,stop_handler);signal.signal(signal.SIGINT,stop_handler)
    token=sys.argv[1]
    if not re.fullmatch(r'[a-f0-9-]{36}',token):raise ValueError('invalid worker token')
    data=json.load(sys.stdin);cfg=data['config']
    root=os.path.realpath(cfg['root'])
    if root!=cfg['root'] or root=='/' or not os.path.isdir(root):raise ValueError('invalid media root')
    if not cfg['libraries'] or any(not isinstance(s,str) or '/' in s or s in ('.','..') for s in cfg['libraries']):raise ValueError('invalid library scope')
    pidfile='/tmp/media-integrity-audit.'+token+'.json'
    fd=os.open(pidfile,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as f:json.dump({'pid':os.getpid(),'token':token,'start':open('/proc/self/stat').read().split()[21]},f)
    audit=None
    try:
        audit=Audit(cfg,data['state']);audit.execute()
    except (BrokenPipeError,KeyboardInterrupt):
        kill_child(ACTIVE)
    except Exception as error:
        kill_child(ACTIVE)
        if audit:
            audit.stats['reason']='Worker failure: '+type(error).__name__;audit.stats['failed']=True
            try:audit.finish()
            except (BrokenPipeError,ValueError,OSError):pass
        emit({'type':'failure','reason':type(error).__name__+': '+str(error)[:300]});sys.exit(1)
    finally:
        kill_child(ACTIVE)
        try:os.unlink(pidfile)
        except FileNotFoundError:pass
if __name__=='__main__':main()

PYWORKER
}

# Bash read -t consumes partial lines even on timeout. Retain fragments until
# a newline arrives; never classify transport failures as corrupt media.
read_worker_event() {
    local destination="$1" source_fd="$2" timeout_seconds="${3:-5}" piece='' rc=0 LC_ALL=C
    local limit=262144
    IFS= read -r -n "$((limit-${#WORKER_EVENT_PARTIAL}+1))" -t "$timeout_seconds" piece <&"$source_fd" || rc=$?
    WORKER_EVENT_PARTIAL+="$piece"
    (( ${#WORKER_EVENT_PARTIAL}<=limit )) || return 2
    if (( rc==0 )); then
        printf -v "$destination" '%s' "$WORKER_EVENT_PARTIAL"
        WORKER_EVENT_PARTIAL=''
        return 0
    fi
    (( rc>128 )) && return 75
    [[ -z "$WORKER_EVENT_PARTIAL" ]] || return 2
    return 1
}

main() {
    USR_OPS_SHARED_BUDGET_ACTIVE=true
    ARR_MUTATION_COORDINATION_ACTIVE=true
    case "${1:-}" in
      --version) printf 'media_integrity_audit.sh %s\n' "$SCRIPT_VERSION";return 0;;
      --help|-h) printf '%s\n' 'Usage: bash script [--version|--status|--inventory-only|--recovery-status|--recover-only|--help]' \
        'Default: Wednesday/Sunday scan through Bazarr. Recovery is disabled by configuration; no installation or Docker changes.' \
        'Wednesday/Sunday 07:00 SGT, two-hour runtime, two video threads, low CPU/I/O priority.' \
        'Quick probes and resumable overlapping decode ranges are separate evidence; pending files remain unverified.' \
        'Missing mounts, maintenance, active parity/Mover/backups or Plex transcoding defer/stop work.' \
        '--status reads only saved receipts. --inventory-only stats library paths and saves inventory; no decoding or normal email.' \
        'AUTO_RECOVERY_ENABLED=false: observe for several weeks before changing it. No CLI option bypasses the switch.' \
        '--recovery-status reads the journal only. --recover-only handles bounded Arr recovery; the existing Arr monitor invokes it in four-hour action windows.' \
        'When enabled: two distinct confirming audit runs, exact monitored Arr file/target IDs, no active work, original retained in place, durable intents, one exact release grab, full replacement verification.' \
        'Originals remain in their library locations until Arr replaces/recycles them. No repair_hold, file deletion or forced import. Required/blocked/completed replacement updates are grouped.' \
        'Timeouts, read errors, unsupported codecs, unmonitored/ambiguous/unmanaged media never authorize recovery.';return 0;;
      --status) [[ ! -f "$STATUS_DIR/media_integrity_audit.json" ]] || jq . "$STATUS_DIR/media_integrity_audit.json";return 0;;
      --inventory-only) MODE=inventory;;
      --recovery-status) recovery_valid || return 1; jq '{schema,workflow,actions:[.actions|to_entries[]|{id:.key,app:.value.app,path:.value.path,status:.value.status,reason:.value.reason,parentId:.value.parentId,fileId:.value.fileId,targets:.value.targets,selected:.value.selected.title,downloadId:.value.downloadId,replacementFiles:.value.replacementFiles,replacementVerifiedAt:.value.replacementVerifiedAt,events:.value.events}]}' "$RECOVERY_FILE";return 0;;
      --recover-only) MAX_RUNTIME_SECONDS=210;[[ "$AUTO_RECOVERY_ENABLED" == true ]] || { printf 'Automatic media recovery disabled; observation only.\n'; return 0; };MODE=recover;;
      '') ;;
      *) printf 'Unknown option; use --help.\n' >&2;return 2;;
    esac
    local command flag fd line kind program input libraries toolset started last_guard=0 last_log=0 reason status=OK failure=false event_fd
    local chunk_expected=0 chunk_bytes=0 checkpoint_rc=0 invocation_started worker_budget
    invocation_started=$(date +%s)
    RUN_REPORT_WRITTEN=false
    trap finish EXIT
    for command in docker jq flock timeout gzip base64 sha256sum find stat mountpoint pgrep iconv curl sync df; do command -v "$command" >/dev/null || { FAILURE_REASON="Required host command unavailable: $command";return 1; };done
    for flag in "$MAX_RUNTIME_SECONDS" "$VIDEO_THREADS" "$DECODER_MEMORY_MIB" "$SEGMENT_MEDIA_SECONDS" "$SEGMENT_WALL_SECONDS" "$FILE_SLICE_SECONDS" "$RECHECK_DAYS" "$MAX_STATE_BYTES"; do
        [[ "$flag" =~ ^[1-9][0-9]*$ ]] || return 2
    done
    [[ "$AUTO_RECOVERY_ENABLED" == true || "$AUTO_RECOVERY_ENABLED" == false ]] || return 2
    for flag in "$RECOVERY_MAX_NEW_PER_RUN" "$RECOVERY_MAX_NEW_PER_WEEK" "$RECOVERY_WAIT_DAYS" "$RECOVERY_MAX_SECONDS"; do [[ "$flag" =~ ^[1-9][0-9]*$ ]] || return 2;done
    (( RECOVERY_MAX_NEW_PER_RUN<=3 && RECOVERY_MAX_NEW_PER_WEEK<=10 && RECOVERY_WAIT_DAYS<=90 && RECOVERY_MAX_SECONDS<=180 )) || return 2
    (( MAX_RUNTIME_SECONDS>=60 && MAX_RUNTIME_SECONDS<=14400 && VIDEO_THREADS<=8 && DECODER_MEMORY_MIB>=256 )) || return 2
    mountpoint -q "$VAULT_MOUNT" || {
        RUN_REPORT_WRITTEN=true
        printf 'Vault unavailable; no shadow state, scan or recovery started.\n' >&2
        local marker
        marker="/tmp/media-integrity-storage-failure-$(date +%F)"
        if [[ ! -e "$marker" && -x "$NOTIFY_BIN" ]] && usr_ops_notify timeout 30 "$NOTIFY_BIN" -i alert -s 'Media Integrity Audit' -d 'Required vault storage unavailable' -m 'No audit or recovery was started. Persistent state was preserved; no media or Arr action was performed. Check the vault mount and next scheduled audit.'; then : >"$marker";fi
        return 1
    }
    [[ "$STATE_DIR" == "$VAULT_MOUNT"/cloud/logs/script/media_integrity_audit && ! -L "$STATE_DIR" && ! -L "$STATUS_DIR" ]] || return 1
    mkdir -p "$STATE_DIR" "$STATUS_DIR" || return 1
    for flag in "$LOG_FILE" "$LOG_FILE.1" "$LOG_FILE.2" "$STATE_DIR/notified.json" "$STATE_DIR/pending-notification.json" "$STATE_DIR/latest-report.txt" "$RECOVERY_FILE" "$RECOVERY_PREVIOUS_FILE"; do [[ ! -L "$flag" ]] || return 1;done
    exec 9>"$LOCK_FILE" || return 1
    flock -n 9 || { printf 'Another media integrity audit is active; invocation deferred.\n';return 0; }
    TMP_DIR=$(mktemp -d /tmp/media-integrity-audit.XXXXXX) || return 1
    trap finish EXIT
    trap 'GUARD_REASON="Operator interruption";cancel_worker;exit 143' INT TERM HUP
    find "$STATE_DIR" -maxdepth 1 -type f \( -name 'media-integrity-audit.log.1' -o -name 'media-integrity-audit.log.2' \) -mtime +29 -delete
    log INFO "Media Integrity Audit v$SCRIPT_VERSION started; mode=$MODE; scope=${LIBRARY_SUBDIRS[*]}; budget=${MAX_RUNTIME_SECONDS}s"
    if ! load_state; then write_report FAILED 'State invalid/unrecoverable; original state preserved and no scan started';return 1;fi
    if app_update_requested integrity;then write_report DEFERRED "Bazarr or coordinated Arr update requested; existing coverage and recovery state retained";return 0;fi
    if ! workload_guard; then
        status=DEFERRED
        case "$GUARD_REASON" in *unavailable*|*unverified*|*stopped*|*symlinked*) status=FAILED;; esac
        write_report "$status" "$GUARD_REASON";[[ "$status" != FAILED ]];return $?
    fi
    if ! recovery_valid; then write_report FAILED 'Invalid/symlinked recovery journal; no scan or mutation started; recovery holds preserved';return 1;fi
    if [[ "$MODE" == recover ]]; then trap 'exit 143' INT TERM HUP;fi
    if [[ "$MODE" != inventory ]]; then
        if ! recovery_process; then RECOVERY_NOTE='Native recovery follow-up incomplete; original/library state remains Arr-managed. Exact job/checkpoints retained; no uncertain request replayed';fi
    fi
    recovery_schedule || return 1
    if [[ "$MODE" == recover ]] && ! jq -e '.paths|length>0' "$TMP_DIR/recovery-schedule.json" >/dev/null;then
        write_report OK 'Bounded native recovery follow-up; no imported replacement awaiting decoder work';return $?
    fi
    toolset=$(timeout 12 docker exec --user 99:100 "$BAZARR_CONTAINER" sh -c \
      'set -e; command -v python3 >/dev/null; command -v ffprobe >/dev/null; command -v ffmpeg >/dev/null; command -v nice >/dev/null; command -v ionice >/dev/null; ffmpeg -version | sed -n "1p"; ffprobe -version | sed -n "1p"') || {
        write_report FAILED 'Bazarr tool runtime unavailable; no media file was checked';return 1; }
    worker_budget=$((MAX_RUNTIME_SECONDS-($(date +%s)-invocation_started)))
    if ((worker_budget<60)); then write_report DEFERRED 'Preflight/recovery consumed the scan budget; coverage resumes on the next schedule';return 0;fi
    if [[ "$MODE" == recover ]];then worker_budget=$((worker_budget<75 ? worker_budget : 75));SEGMENT_WALL_SECONDS=30;FILE_SLICE_SECONDS=35;fi
    libraries=$(printf '%s\n' "${LIBRARY_SUBDIRS[@]}" | jq -Rsc 'split("\n")|map(select(length>0))')
    input="$TMP_DIR/input.json"
    if [[ -f "$RECOVERY_FILE" ]]; then cp "$RECOVERY_FILE" "$TMP_DIR/recovery-input.json";else printf '{"schema":1,"actions":{}}' >"$TMP_DIR/recovery-input.json";fi
    jq -n --slurpfile state "$TMP_DIR/state.json" --slurpfile recovery "$TMP_DIR/recovery-input.json" --slurpfile schedule "$TMP_DIR/recovery-schedule.json" --arg root "$MEDIA_CONTAINER_ROOT" --arg hostRoot "$MEDIA_HOST_ROOT" \
      --argjson libraries "$libraries" --arg toolset "$toolset" --arg mode "$MODE" \
      --argjson targeted "$( [[ "$MODE" == recover ]] && printf true || printf false )" --argjson budget "$worker_budget" --argjson quick "$QUICK_PASS_MAX_SECONDS" --argjson threads "$VIDEO_THREADS" --argjson memory "$DECODER_MEMORY_MIB" \
      --argjson segment "$SEGMENT_MEDIA_SECONDS" --argjson wall "$SEGMENT_WALL_SECONDS" --argjson slice "$FILE_SLICE_SECONDS" \
      --argjson recheck "$RECHECK_DAYS" --argjson settle "$SETTLE_SECONDS" --argjson max "$MAX_STATE_BYTES" \
      '{state:$state[0],config:{root:$root,hostRoot:$hostRoot,libraries:$libraries,toolset:$toolset,mode:$mode,
       targeted:$targeted,budgetSeconds:$budget,quickBudgetSeconds:$quick,threads:$threads,memoryMiB:$memory,segmentSeconds:$segment,segmentWallSeconds:$wall,
       fileSliceSeconds:$slice,recheckDays:$recheck,settleSeconds:$settle,maxStateBytes:$max,recoveryPriority:$schedule[0].paths,evidencePaths:$schedule[0].evidencePaths,recheckAfter:($schedule[0].recheckAfter // {})}}' >"$input" || return 1
    program=$(worker_program) || return 1
    WORKER_TOKEN=$(cat /proc/sys/kernel/random/uuid)
    mkfifo "$TMP_DIR/events" || return 1
    (
      exec docker exec -i --user 99:100 "$BAZARR_CONTAINER" nice -n 15 ionice -c 3 python3 -c "$program" "$WORKER_TOKEN" <"$input"
    ) >"$TMP_DIR/events" 2>"$TMP_DIR/worker.stderr" &
    WORKER_PID=$!
    exec {event_fd}<"$TMP_DIR/events"
    started=$(date +%s)
    WORKER_EVENT_PARTIAL=""
    local event_rc=0
    while :; do
        event_rc=0;read_worker_event line "$event_fd" || event_rc=$?
        if (( event_rc==0 )); then
            kind=$(jq -er .type <<<"$line" 2>/dev/null) || { failure=true;GUARD_REASON='Invalid worker protocol';cancel_worker;break; }
            case "$kind" in
              checkpoint)
                checkpoint_rc=0;save_checkpoint "$line" || checkpoint_rc=$?
                if (( checkpoint_rc==75 )); then GUARD_REASON='Operational-state export active; deferred with last committed checkpoint';cancel_worker
                elif (( checkpoint_rc!=0 )); then failure=true;GUARD_REASON='Checkpoint could not be committed; original state retained';cancel_worker;fi;;
              checkpoint-begin)
                chunk_expected=$(jq -r .length <<<"$line")
                if [[ ! "$chunk_expected" =~ ^[1-9][0-9]*$ ]] || (( chunk_expected>MAX_STATE_BYTES*2 )); then failure=true;GUARD_REASON='Invalid checkpoint length';cancel_worker;break;fi
                chunk_bytes=0;: >"$TMP_DIR/checkpoint.chunks.base64";;
              checkpoint-chunk)
                if (( chunk_expected<=0 )) || ! jq -e '(.data|type)=="string" and (.data|length)>0 and (.data|length)<=65536' <<<"$line" >/dev/null; then failure=true;GUARD_REASON='Invalid checkpoint chunk';cancel_worker;break;fi
                printf '%s\n' "$line" | jq -jr .data >>"$TMP_DIR/checkpoint.chunks.base64"
                chunk_bytes=$((chunk_bytes+$(jq '.data|length' <<<"$line")))
                if (( chunk_bytes>chunk_expected )); then failure=true;GUARD_REASON='Checkpoint transport overrun';cancel_worker;break;fi;;
              checkpoint-end)
                printf '%s\n' "$line" | jq .stats >"$TMP_DIR/checkpoint.stats.json"
                checkpoint_rc=0
                if (( chunk_bytes!=chunk_expected || chunk_expected<=0 )); then checkpoint_rc=1
                else commit_checkpoint "$TMP_DIR/checkpoint.chunks.base64" "$TMP_DIR/checkpoint.stats.json" || checkpoint_rc=$?;fi
                if (( checkpoint_rc==75 )); then GUARD_REASON='Operational-state export active; deferred with last committed checkpoint';cancel_worker
                elif (( checkpoint_rc!=0 )); then failure=true;GUARD_REASON='Incomplete/uncommitted chunked checkpoint';cancel_worker;fi
                chunk_expected=0;chunk_bytes=0;;
              heartbeat) ;;
              complete) printf '%s\n' "$line" | jq .stats >"$TMP_DIR/stats.json";WORKER_FINISHED=true;;
              failure) failure=true;GUARD_REASON=$(jq -r .reason <<<"$line");;
              transport) TRANSPORT_RC=$(jq -r .code <<<"$line");break;;
              *) failure=true;GUARD_REASON='Unknown worker protocol event';cancel_worker;break;;
            esac
        elif (( event_rc==2 )); then failure=true;GUARD_REASON="Incomplete or oversized worker frame; media evidence unchanged";cancel_worker;break
        elif (( event_rc==1 )); then break;fi
        if (( $(date +%s)-last_guard>=15 )); then
            last_guard=$(date +%s)
            if (( last_guard-last_log>=600 )) && [[ -f "$TMP_DIR/stats.json" ]]; then
                log INFO "Checkpoint: $(jq -r '"quick="+((.quickPassed // 0)|tostring)+"; ranges="+((.segmentsPassed // 0)|tostring)+"; cycles="+((.cyclesCompleted // 0)|tostring)' "$TMP_DIR/stats.json")"
                last_log="$last_guard"
            fi
            if [[ -z "$GUARD_REASON" ]] && ! workload_guard; then log INFO "Work deferred: $GUARD_REASON";cancel_worker;fi
        fi
        if (( $(date +%s)-started>MAX_RUNTIME_SECONDS+90 )); then failure=true;GUARD_REASON='Worker exceeded supervisor deadline; cancellation requested';cancel_worker;break;fi
    done
    exec {event_fd}<&-
    if [[ "$WORKER_FINISHED" != true ]]; then cancel_worker;fi
    local wait_count=0
    while kill -0 "$WORKER_PID" 2>/dev/null && (( wait_count<20 )); do sleep 0.5;wait_count=$((wait_count+1));done
    if kill -0 "$WORKER_PID" 2>/dev/null; then kill "$WORKER_PID" 2>/dev/null || true; sleep 1;kill -KILL "$WORKER_PID" 2>/dev/null || true;fi
    wait "$WORKER_PID" 2>/dev/null || TRANSPORT_RC=$?
    WORKER_PID=""
    # Planned container maintenance may terminate docker exec before the next
    # guard poll. Recheck dependencies before classifying that as a script fault.
    if [[ -z "$GUARD_REASON" && ( "$WORKER_FINISHED" != true || "$TRANSPORT_RC" != 0 ) ]]; then workload_guard || true;fi
    if [[ "$failure" == true ]] || jq -e '.failed==true' "$TMP_DIR/stats.json" >/dev/null 2>&1; then
        status=FAILED;reason="${GUARD_REASON:-Worker failed; last completed checkpoint retained}"
    elif [[ -n "$GUARD_REASON" ]]; then status=DEFERRED;reason="$GUARD_REASON"
    elif [[ "$WORKER_FINISHED" != true || "$TRANSPORT_RC" != 0 ]]; then
        status=FAILED;reason='Worker interrupted/unavailable without maintenance evidence; last completed checkpoint retained'
    else
        reason=$(jq -r '.reason // "Completed scan slice"' "$TMP_DIR/stats.json")
        if jq -e '.activeFindings>0 or .inventoryErrors>0 or (.inventoryComplete!=true and (.targeted // false)!=true)' "$TMP_DIR/stats.json" >/dev/null; then status=WARNING;fi
        [[ "$MODE" != inventory ]] || status=INVENTORY_ONLY
    fi
    if [[ "$MODE" == recover && "$status" != FAILED ]];then
        RECOVERY_ALLOW_GRAB=false;RECOVERY_MAX_SECONDS=20;recovery_process || RECOVERY_NOTE='Replacement verification follow-up incomplete; exact job remains protected'
    fi
    write_report "$status" "$reason" || return 1
    [[ "$status" != FAILED ]]
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
