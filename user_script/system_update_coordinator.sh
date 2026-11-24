#!/bin/bash
clearLog=true
arrayStarted=true
# System Update Coordinator v1.0.0 -- personal Hubble maintenance.
# PURPOSE: Detect Docker/plugin/Unraid OS updates; automatically install only
# explicitly approved, still-installed items during a bounded maintenance window.
# Native DockerMan/plugin installers retain their normal configuration semantics.
# No OS installation/reboot, image-channel change, forced import or DB rollback.
# SCHEDULE: 15,45 * * * *; registry polling has its own six-hour per-item cache.
# New installs: 13:15-15:30 Singapore; at most one/run and two/rolling 24h.
# Default allowlist seeds once, bound to exact installed repository/source URL.
# Retired items leave policy automatically after two complete inventory scans;
# stopped items stay stopped. Reinstalling a retired/changed identity needs review.
# New items default to notify-only, never inherit a broad wildcard approval.
# STATE/LOG: /mnt/vault/cloud/logs/script/system_update_coordinator; atomic JSON,
# private per-action recovery evidence, 2MiB log + two rotations, 30-day age bound.
# Reports: one grouped weekly availability digest; installed/failed/recovered work
# reported after each bounded run. Undelivered reports stay in an existing outbox.
# Recovery: journal before native recreation. Uncertain installs are inspected,
# never blindly repeated. Previous image/config archived before update; latest
# two finished recovery sets retained, plus any unresolved set (new work stops).
# An image archive does not reverse DB migrations. Compatible appdata restoration
# is a critical/manual recovery step; existing backup retention is independent.
# Native mutable tags can move during the installer pull; read-back detects any
# unexpected digest and holds further updates rather than claiming verification.
# Unknown OS majors/interfaces stop installation; read-only status remains usable.
# CLI: --help documents policy management without editing this standalone script.
# BEGIN EMBEDDED OPERATIONS CONTRACT
OPS_SCRIPT_ID="system_update_coordinator"
# Embedded operations contract v1; generated into standalone User Scripts.
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
    "${args[@]}"
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
# END EMBEDDED OPERATIONS CONTRACT
set -uo pipefail
umask 077
readonly SCRIPT_VERSION="1.0.0"
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
BACKUP_MAX_AGE_SECONDS=$((80*3600))
DOCKER_MAINTENANCE_DIR="${DOCKER_MAINTENANCE_DIR:-/run/docker-service-maintenance}"
TMP_DIR='' START_EPOCH=0 RUN_ID='' RESULT=OK SUMMARY='' INSTALL_ACTIVE=false UPDATE_FD='' EXPORT_FD='' LEASE_FILE='' OWN_GATE_FD='' MAINT_FD='' EVENTS=0
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
state_valid(){ jq -e '.schema==1 and (.items|type)=="object" and (.jobs|type)=="object" and (.outbox|type)=="array"' "$1" >/dev/null 2>&1; }
mutate(){ jq "$@" "$STATE_FILE" >"$TMP_DIR/state.next" && state_valid "$TMP_DIR/state.next" && publish "$TMP_DIR/state.next" "$STATE_FILE"; }
policy_valid(){ jq -e '
 .schema==1 and (.enabled|type)=="boolean" and (.docker|type)=="object" and (.plugins|type)=="object" and
 all(.docker[],.plugins[];(.allow|type)=="boolean" and (.identity|type)=="string") and
 (.window.start|type)=="string" and (.window.end|type)=="string" and
 (.window.start|test("^([01][0-9]|2[0-3]):[0-5][0-9]$")) and (.window.end|test("^([01][0-9]|2[0-3]):[0-5][0-9]$")) and .window.start<.window.end and
 ((.limits.dailyTotal // 2)|type)=="number" and ((.limits.dailyPlugins // 1)|type)=="number" and ((.limits.candidateHoldHours // 24)|type)=="number" and
 ((.limits.dailyTotal // 2)|floor)==(.limits.dailyTotal // 2) and (.limits.dailyTotal // 2)>=1 and (.limits.dailyTotal // 2)<=5 and
 ((.limits.dailyPlugins // 1)|floor)==(.limits.dailyPlugins // 1) and (.limits.dailyPlugins // 1)>=0 and (.limits.dailyPlugins // 1)<=2 and (.limits.dailyPlugins // 1)<=(.limits.dailyTotal // 2) and
 ((.limits.candidateHoldHours // 24)|floor)==(.limits.candidateHoldHours // 24) and (.limits.candidateHoldHours // 24)>=1 and (.limits.candidateHoldHours // 24)<=168
 ' "$1" >/dev/null 2>&1; }
policy_update(){ jq "$@" "$POLICY_FILE" >"$TMP_DIR/policy.next" && policy_valid "$TMP_DIR/policy.next" && publish "$TMP_DIR/policy.next" "$POLICY_FILE"; }
event(){
 local importance="$1" subject="$2" detail="$3" key="$4" id
 id=$(printf '%s' "$key"|sha256sum|cut -d' ' -f1)
 mutate --arg id "$id" --arg importance "$importance" --arg subject "$subject" --arg detail "$detail" --argjson now "$(date +%s)" \
  'if any(.outbox[];.id==$id) or (.delivered[$id] // 0)>$now-86400 then . else .outbox+=[{id:$id,importance:$importance,subject:$subject,detail:$detail,at:$now}] end' || return 1
 EVENTS=$((EVENTS+1))
}
window_open(){
 local now start end;now=$(TZ=Asia/Singapore date +%H:%M);start=$(jq -r .window.start "$POLICY_FILE");end=$(jq -r .window.end "$POLICY_FILE")
 [[ "$now" > "$start" || "$now" == "$start" ]] && [[ "$now" < "$end" ]]
}
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
  $local=$u->inspectLocalVersion($repo);if($mode==='docker-local')output(['schema'=>1,'local'=>$local]);$remote=$u->getRemoteVersionV2($repo);
  if(!is_string($remote)||!preg_match('/^sha256:[a-f0-9]{64}$/D',$remote))throw new RuntimeException('Registry digest unavailable');
  output(['schema'=>1,'remote'=>$remote,'local'=>$local,'available'=>$local!==$remote]);
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
      jq 'def entry($identity;$allow):{identity:$identity,allow:$allow,approvedAt:now|floor};
        {schema:1,enabled:true,window:{start:"13:15",end:"15:30"},limits:{dailyTotal:2,dailyPlugins:1,candidateHoldHours:24},docker:(.docker|with_entries(.value=entry(.value.repository;(.key|IN("prowlarr","bazarr","tautulli","seerr","lumunarr"))))),
         plugins:(.plugins|with_entries(.value=entry(.value.installed.url;(.key|IN("community.applications.plg","fix.common.problems.plg","dynamix.system.info.plg")))))}' "$TMP_DIR/initial-inventory" >"$TMP_DIR/policy.initial" || return 1
      policy_valid "$TMP_DIR/policy.initial" && publish "$TMP_DIR/policy.initial" "$POLICY_FILE" || return 1
    fi
    policy_valid "$POLICY_FILE" || { log ERROR 'Policy invalid; preserved; updates prohibited';return 1; }
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
    local kind name identity key
    for kind in docker plugin;do
      while IFS=$'\t' read -r name identity;do
        key="$kind:$name"
        mutate --arg key "$key" --arg kind "$kind" --arg name "$name" --arg identity "$identity" --argjson now "$(date +%s)" '
          .items[$key] = ((.items[$key] // {kind:$kind,name:$name,identity:$identity,firstSeen:$now,checkedAt:0,missingScans:0}) |
            if .identity!=$identity then {kind:$kind,name:$name,identity:$identity,firstSeen:$now,checkedAt:0,missingScans:0,identityChanged:true} else . end) | del(.retired[$key])' || return 1
      done < <(if [[ "$kind" == docker ]];then jq -r '.docker|to_entries[]|[.key,.value.repository]|@tsv' "$TMP_DIR/inventory.json";else jq -r '.plugins|to_entries[]|[.key,.value.installed.url]|@tsv' "$TMP_DIR/inventory.json";fi)
    done
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
        adapter docker-check "$identity" >"$TMP_DIR/check.json" 2>"$TMP_DIR/check.err" || check_rc=$?
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
          .candidateFingerprint=$fingerprint | .candidate=$candidate | .available=$available | .checkedAt=$now | .checkFailures=0 | .checkStatus="VERIFIED" | .evidence=$data[0])' || return 1
      if ((previous_failures>=3));then event normal 'Update checks restored' "$kind/$name: fresh native update evidence obtained after repeated check failures; normal approval and installation guards remain in force." "check-restored:$key:$((now/(7*86400)))" || return 1;fi
      log INFO "$kind/$name: update check completed; available=$available; no installation performed by check"
    done < <(jq -r --argjson now "$now" --argjson interval "$CHECK_INTERVAL_SECONDS" '.items|to_entries|sort_by(.value.checkedAt // 0)|.[]|
      select(.value.missingScans==0 and $now-(.value.checkedAt // 0)>=(if (.value.checkFailures // 0)>0 then ([1800 * pow(2;([.value.checkFailures,3]|min)),21600]|min) else $interval end))|
      [.key,.value.kind,.value.name,.value.identity]|@tsv' "$STATE_FILE")
}

backup_evidence() {
    local kind="$1" source manifest hash now
    now=$(date +%s)
    if [[ "$kind" == docker ]];then
      source="$STATUS_DIR/iss-backup-request.json"
      jq -e --argjson cutoff "$((now-BACKUP_MAX_AGE_SECONDS))" '.schema==1 and .completedAt>=$cutoff and (.generation|startswith("/mnt/vault/backup/cache/backup_")) and (.manifestSha256|test("^[a-f0-9]{64}$"))' "$source" >/dev/null || return 1
      manifest=$(jq -r .generation "$source")/backup_manifest.tsv
      [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
      hash=$(sha256sum "$manifest"|cut -d' ' -f1)
      [[ "$hash" == "$(jq -r .manifestSha256 "$source")" ]] || return 1
      cp "$source" "$TMP_DIR/backup-evidence.json"
    else
      source=/mnt/vault/backup/flash/.backup_boot_disk_state.json
      jq -e --argjson cutoff "$((now-BACKUP_MAX_AGE_SECONDS))" '.successfulAt>=$cutoff and (.archiveSha256|test("^[a-f0-9]{64}$"))' "$source" >/dev/null || return 1
      [[ -f "$(jq -r .backupFile "$source")" ]] || return 1
      cp "$source" "$TMP_DIR/backup-evidence.json"
    fi
}

maintenance_guard() {
    local lock values hour minute
    for lock in /tmp/backup_cache_appdata.lock /tmp/backup_boot_disk.lock /tmp/backup_media_remote.lock /run/backup_vault_remote.lock /run/media_plex_dbrepair.lock /run/backup_restore_drill.lock /run/media_cleanup.lock /run/media_integrity_audit.lock;do
      if [[ -e "$lock" ]];then flock -s -n "$lock" -c true || { SUMMARY="Maintenance deferred: ${lock##*/} active";return 1; };fi
    done
    # Do not compete with manual/native package or container installations.
    pgrep -f '(^|/)(update_container|installpkg|upgradepkg|removepkg)([[:space:]]|$)|/scripts/plugin (install|update|remove)([[:space:]]|$)' >/dev/null && { SUMMARY='Maintenance deferred: native installer/package operation active';return 1; }
    pgrep -f '(^|/)(mover|mover\.old)([[:space:]]|$)|mover\.php' >/dev/null && { SUMMARY='Maintenance deferred: Mover active';return 1; }
    values=$(bounded 5 /usr/local/sbin/mdcmd status) || return 1
    grep -q '^mdState=STARTED$' <<<"$values" || return 1
    # Only active parity/check/rebuild I/O; a stale position is not active work.
    [[ $(awk -F= '$1=="mdResync"{print $2}' <<<"$values") == 0 ]] || { SUMMARY='Maintenance deferred: active array operation';return 1; }
    exec {OWN_GATE_FD}>"$ARR_BACKUP_GATE";flock -x -n "$OWN_GATE_FD" || { exec {OWN_GATE_FD}>&-;SUMMARY='Maintenance deferred: application producer/monitor active';return 1; }
}

readiness() {
    local name="$1"
    bounded 50 /bin/bash "$WATCHDOG_SCRIPT" --readiness "$name" >"$TMP_DIR/readiness.json" 2>"$TMP_DIR/readiness.err" || return 1
    jq -e '.schema==1 and .ready==true' "$TMP_DIR/readiness.json" >/dev/null
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
    local kind="$1" name="$2" id="$3" old_image="${4:-}" old_size free target
    [[ "$ROLLBACK_ROOT" == "$VAULT_MOUNT"/backup/system_updates && ! -L "$ROLLBACK_ROOT" ]] || return 1
    if [[ -e "$ROLLBACK_ROOT" ]];then [[ -f "$ROLLBACK_ROOT/.owner" && $(cat "$ROLLBACK_ROOT/.owner") == system_update_coordinator ]] || return 1
    else mkdir -m 700 "$ROLLBACK_ROOT" && printf 'system_update_coordinator\n' >"$ROLLBACK_ROOT/.owner" || return 1;fi
    target="$ROLLBACK_ROOT/$id";mkdir -m 700 "$target" || return 1
    printf '%s\n' "$id" >"$target/.owner" || return 1
    cp "$TMP_DIR/backup-evidence.json" "$target/backup-evidence.json" || return 1
    if [[ "$kind" == docker ]];then
      old_size=$(docker_cmd image inspect "$old_image" --format '{{.Size}}') || return 1
      [[ "$old_size" =~ ^[0-9]+$ && "$old_size" -le 2147483648 ]] || return 1
      free=$(df -PB1 "$ROLLBACK_ROOT"|awk 'NR==2{print $4}');((free>=old_size+10*1024*1024*1024)) || return 1
      cp "$TMP_DIR/definition-before.json" "$target/definition-before.json"
      cp "$(jq -r .template "$TMP_DIR/definition-before.json")" "$target/template.xml" || return 1
      # Native DockerMan can force-remove the previous image. Archive it before
      # invoking that installer; never assume a temporary tag protects it.
      bounded 180 /bin/bash -c 'set -o pipefail;set +o posix;ulimit -f 2097152;docker image save "$1" | gzip -1 >"$2"' _ "$old_image" "$target/image.tar.gz.partial" || return 1
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
      current=$(adapter docker-local "$identity") || return 1
      # Require installed digest exactly equal to the approved observed candidate.
      [[ $(jq -r .local <<<"$current") == "$expected" ]] || return 1
      [[ $(jq -r .id "$TMP_DIR/definition-after.json") != "$(jq -r --arg id "$id" '.jobs[$id].oldId' "$STATE_FILE")" ]] || return 1
      jq -e --slurpfile old "$(jq -r --arg id "$id" '.jobs[$id].recoveryPath' "$STATE_FILE")/definition-before.json" '.running==true and .definition==$old[0].definition and .templateHash==$old[0].templateHash' "$TMP_DIR/definition-after.json" >/dev/null || return 1
      if readiness "$name";then return 0;else VERIFY_REASON=readiness;return 1;fi
    else
      adapter plugin-check "$name" >"$TMP_DIR/plugin-after.json" || return 1
      jq -e '.busy==false' "$TMP_DIR/plugin-after.json" >/dev/null || return 1
      adapter inventory >"$TMP_DIR/recheck-inventory.json" || return 1
      identity=$(jq -r --arg id "$id" '.jobs[$id].identity' "$STATE_FILE")
      jq -e --arg name "$name" --arg version "$expected" --arg identity "$identity" --arg hash "$(jq -r --arg id "$id" '.jobs[$id].candidateHash' "$STATE_FILE")" '.complete==true and .plugins[$name].installed.version==$version and .plugins[$name].installed.url==$identity and .plugins[$name].installed.sha256==$hash' "$TMP_DIR/recheck-inventory.json" >/dev/null
    fi
}

recover_preparation() {
    local id
    while read -r id;do
      cleanup_unissued_set "$id" || true
      job_update "$id" '.jobs[$id].status="DEFERRED" | .jobs[$id].reason="Interrupted preparation reconciled; no native installer was dispatched"' || return 1
      event normal 'Interrupted preparation reconciled' "$id: preparation reconciled; known owned partial files cleaned where safe and unexpected entries preserved; no native installer had been dispatched and the application was not changed. Normal backoff and safety checks remain in force." "preparation-recovered:$id" || return 1
    done < <(jq -r '.jobs|to_entries[]|select(.value.status=="PREPARING" and (.value.dispatchedAt // 0)==0)|.key' "$STATE_FILE")
}

defer_prepared() {
    job_update "$1" '.jobs[$id].status="DEFERRED" | .jobs[$id].reason=$reason' --arg reason "$2" || return 1
    cleanup_unissued_set "$1" || true
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
        count=$(jq -r --arg id "$id" '.jobs[$id].verifiedScans // 0' "$STATE_FILE");count=$((count+1))
        job_update "$id" '.jobs[$id].verifiedScans=$count' --argjson count "$count" || return 1
        if ((count>=2));then
          local evidence='Expected image digest, retained configuration and application readiness verified on two observations'
          [[ $(jq -r --arg id "$id" '.jobs[$id].kind' "$STATE_FILE") != plugin ]] || evidence='Exact installed plugin version/source/manifest and finished native plugin task verified on two observations; plugin feature behavior was not independently certified'
          job_update "$id" '.jobs[$id].status="COMPLETED" | .jobs[$id].verifiedAt=$now' --argjson now "$(date +%s)" || return 1
          event normal 'Update verified' "$name: $evidence. Previous image/config retained in its recovery set; no database rollback performed." "verified:$id" || return 1
        fi
      else
        if [[ "${VERIFY_REASON:-}" == readiness ]] && (( $(date +%s)-$(jq -r --arg id "$id" '.jobs[$id].dispatchedAt // 0' "$STATE_FILE")<1200 ));then
          job_update "$id" '.jobs[$id].verifiedScans=0 | .jobs[$id].status="VERIFYING"' || return 1
          log INFO "$name: expected image/config verified; application startup readiness pending within 20-minute grace"
          continue
        fi
        job_update "$id" '.jobs[$id].verifiedScans=0 | .jobs[$id].status="ATTENTION"' || return 1
        event warning 'Update requires review' "$name: native update outcome or application readiness remains unverified. Further automatic installs are held. Existing recovery evidence retained; no blind installer replay or database rollback was attempted. Recovery set: $(jq -r --arg id "$id" '.jobs[$id].recoveryPath' "$STATE_FILE")" "attention:$id" || return 1
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

install_one() {
    local key kind name identity candidate approved now count job_id old_id='' old_image='' recovery_path native_rc=0 fresh
    [[ $(jq -r .enabled "$POLICY_FILE") == true ]] && window_open && within_budget 630 || return 0
    # Never continue a batch after an unverified or interrupted native mutation.
    jq -e 'all(.jobs[];.status!="INTENT" and .status!="VERIFYING" and .status!="ATTENTION")' "$STATE_FILE" >/dev/null || { RESULT=DEFERRED;jq -e 'any(.jobs[];.status=="INTENT" or .status=="ATTENTION")' "$STATE_FILE" >/dev/null && RESULT=ATTENTION;SUMMARY='Automatic installs held for pending verification; reconciliation continues';return 0; }
    now=$(date +%s)
    count=$(jq --argjson cutoff "$((now-86400))" '[.jobs[]|select((.dispatchedAt // 0)>=$cutoff)]|length' "$STATE_FILE")
    ((count<$(jq -r '.limits.dailyTotal // 2' "$POLICY_FILE"))) || return 0
    adapter_compatible || { RESULT=DEFERRED;SUMMARY='Native update adapter unverified on this OS/interface; no automatic install';event warning 'Automatic installation deferred' "$SUMMARY; read-only evidence and existing intents retained. Validate native interfaces before enabling a new OS adapter." adapter-unverified;return 0; }
    while IFS=$'\t' read -r key kind name identity candidate;do
      [[ "$name" != unRAIDServer.plg && "$name" != ca.update.applications.plg && "$name" != user.scripts.plg && "$name" != user.scripts.enhanced.plg ]] || continue
      approved=$(jq -r --arg kind "$kind" --arg name "$name" --arg identity "$identity" '(if $kind=="docker" then .docker[$name] else .plugins[$name] end) as $p | ($p.allow==true and $p.identity==$identity)' "$POLICY_FILE")
      [[ "$approved" == true ]] || continue
      # Failed/rejected digest/version stays quarantined until it changes or an
      # operator explicitly resolves the job; no reinstall loops.
      jq -e --arg key "$key" --arg candidate "$candidate" --argjson cutoff "$((now-6*3600))" 'all(.jobs[];.item!=$key or .candidate!=$candidate or (.status=="DEFERRED" and .startedAt<$cutoff))' "$STATE_FILE" >/dev/null || continue
      backup_evidence "$kind" || { log INFO "$name: DEFERRED; recent verified backup evidence unavailable";continue; }
      if [[ "$kind" == docker ]];then
        jq -e --arg name "$name" '.docker[$name].running==true and .docker[$name].managed=="dockerman"' "$TMP_DIR/inventory.json" >/dev/null || continue
        # Require readiness before taking down an already unhealthy application.
        readiness "$name" || { log INFO "$name: DEFERRED; strong application readiness not established";continue; }
        adapter docker-check "$identity" >"$TMP_DIR/fresh.json" || continue
        [[ $(jq -r .remote "$TMP_DIR/fresh.json") == "$candidate" ]] || continue
        adapter definition "$name" >"$TMP_DIR/definition-before.json" || continue
        [[ $(jq -r .templateHash "$TMP_DIR/definition-before.json") == "$(jq -r --arg name "$name" '.docker[$name].templateHash' "$TMP_DIR/inventory.json")" ]] || continue
        same_repository "$(jq -r .runtimeImage "$TMP_DIR/definition-before.json")" "$identity" || { log WARNING "$name: DEFERRED; running image channel differs from saved template; no update started";continue; }
        old_id=$(jq -r .id "$TMP_DIR/definition-before.json");old_image=$(jq -r .imageId "$TMP_DIR/definition-before.json")
      else
        count=$(jq --argjson cutoff "$((now-86400))" '[.jobs[]|select(.kind=="plugin" and (.dispatchedAt // 0)>=$cutoff)]|length' "$STATE_FILE");((count<$(jq -r '.limits.dailyPlugins // 1' "$POLICY_FILE"))) || continue
        bounded 120 "$NATIVE_PLUGIN" check "$name" >"$TMP_DIR/plugin-final-check.log" 2>&1 && adapter plugin-check "$name" >"$TMP_DIR/fresh.json" || continue
        jq -e --arg version "$candidate" --arg identity "$identity" '.available==true and .compatible==true and .busy==false and .candidate.version==$version and .candidate.url==$identity' "$TMP_DIR/fresh.json" >/dev/null || continue
        [[ $(jq -r .candidate.sha256 "$TMP_DIR/fresh.json") == "$(jq -r --arg key "$key" '.items[$key].evidence.candidate.sha256' "$STATE_FILE")" ]] || continue
        bounded 30 "$NATIVE_PLUGIN" validate "/tmp/plugins/$name" >"$TMP_DIR/plugin-validate.log" 2>&1 || continue
      fi
      maintenance_guard || { log INFO "${SUMMARY:-Maintenance conditions unavailable; installation deferred}";return 0; }
      PHASE=install;job_id="$(date +%Y%m%d_%H%M%S)_${kind}_${name}_$$"
      recovery_path="$ROLLBACK_ROOT/$job_id"
      mutate --arg id "$job_id" --arg item "$key" --arg kind "$kind" --arg name "$name" --arg identity "$identity" --arg candidate "$candidate" \
        --arg oldId "$old_id" --arg oldImage "$old_image" --arg path "$recovery_path" --argjson now "$now" \
        '.jobs[$id]={item:$item,kind:$kind,name:$name,identity:$identity,candidate:$candidate,status:"PREPARING",startedAt:$now,oldId:$oldId,oldImage:$oldImage,recoveryPath:$path,verifiedScans:0}' || return 1
      if ! prepare_recovery_set "$kind" "$name" "$job_id" "$old_image";then
        job_update "$job_id" '.jobs[$id].status="DEFERRED" | .jobs[$id].reason="Recovery evidence preparation failed; native installer not called"' || return 1
        cleanup_unissued_set "$job_id" || true
        event warning 'Update deferred before installation' "$name: recovery evidence could not be prepared; native installer was not called and the current application was retained. Check available vault space and the bounded image archive." "prepare:$key:$candidate" || return 1
        return 0
      fi
      if [[ "$kind" == docker ]];then start_container_lease "$name" "$old_id" || { defer_prepared "$job_id" 'Existing maintenance lease; native installer not called';return 0; };fi
      # Recheck backup/interface/window and unchanged installed identity at the
      # final boundary. A late hold is known non-dispatch, not an uncertain POST.
      if ! window_open || ! within_budget 480 || ! adapter_compatible;then defer_prepared "$job_id" 'Final window/runtime/interface guard deferred before native installer';return 0;fi
      if [[ "$kind" == docker ]];then
        fresh=$(docker_cmd inspect "$name" --format '{{.Id}}') || return 1
        [[ "$fresh" == "$old_id" ]] || { defer_prepared "$job_id" 'Installed identity changed; native installer not called';return 0; }
      fi
      job_update "$job_id" '.jobs[$id].status="INTENT" | .jobs[$id].dispatchedAt=$now | .jobs[$id].candidateHash=$hash' --arg hash "$( [[ "$kind" != plugin ]] || jq -r .candidate.sha256 "$TMP_DIR/fresh.json" )" --argjson now "$(date +%s)" || return 1
      INSTALL_ACTIVE=true
      if [[ "$kind" == docker ]];then bounded 420 "$NATIVE_DOCKER_UPDATE" "$name" >"$TMP_DIR/native-install.log" 2>&1 || native_rc=$?
      else bounded 300 "$NATIVE_PLUGIN" update "$name" >"$TMP_DIR/native-install.log" 2>&1 || native_rc=$?;fi
      INSTALL_ACTIVE=false
      tail -c 16384 "$TMP_DIR/native-install.log" >"$recovery_path/native-install.log" || true
      # Native helpers can return zero despite a failed recreation. Read-back,
      # not the exit code or an HTML completion banner, establishes completion.
      job_update "$job_id" '.jobs[$id].status="VERIFYING" | .jobs[$id].nativeExit=$exit' --argjson exit "$native_rc" || return 1
      if job_verified "$job_id";then
        job_update "$job_id" '.jobs[$id].verifiedScans=1' || return 1
        local first_evidence='expected image digest, retained settings and initial readiness verified'
        [[ "$kind" != plugin ]] || first_evidence='expected plugin version/source/manifest and completed native task verified'
        event normal 'Update installed; follow-up verification pending' "$name: native installer completed; $first_evidence. A second scheduled observation will confirm stability. Recovery set: $recovery_path. No image channel or application settings were changed by this coordinator." "installed:$job_id" || return 1
      elif [[ "${VERIFY_REASON:-}" == readiness ]];then
        event normal 'Update installed; startup verification pending' "$name: expected image digest and retained configuration verified; application readiness is still pending within the 20-minute startup grace. Further installations and watchdog restarts remain held while scheduled reconciliation checks actual readiness. Recovery set: $recovery_path." "startup:$job_id" || return 1
      else
        RESULT=ATTENTION
        job_update "$job_id" '.jobs[$id].status="ATTENTION"' || return 1
        event alert 'Update outcome requires attention' "$name: native installer exit=$native_rc; expected version/digest, configuration or readiness could not be confirmed. Further updates are held. The original image/config and backup reference are retained at $recovery_path. No blind replay or database rollback was attempted." "attention:$job_id" || return 1
      fi
      return 0
    done < <(jq -r --argjson cutoff "$((now-$(jq -r '.limits.candidateHoldHours // 24' "$POLICY_FILE")*3600))" '.items|to_entries|sort_by(.value.candidateSeenAt // 0)|.[]|select(.value.missingScans==0 and .value.available==true and .value.checkStatus=="VERIFIED" and .value.candidateSeenAt<=$cutoff)|[.key,.value.kind,.value.name,.value.identity,.value.candidate]|@tsv' "$STATE_FILE")
}

availability_digest() {
    local now previous body
    now=$(date +%s);previous=$(jq -r '.lastAvailabilityReportAt // 0' "$STATE_FILE")
    ((now-previous>=7*86400)) || return 0
    body=$(jq -r '.items[]|select(.available==true)|"- "+.kind+"/"+.name+": candidate "+.candidate+"; last check="+(.checkStatus // "UNVERIFIED")+"; policy approval and maintenance/backup/readiness gates determine installation."' "$STATE_FILE")
    [[ -n "$body" ]] || return 0
    event normal 'Available updates review' "$body" "availability:$((now/(7*86400)))" && mutate --argjson now "$now" '.lastAvailabilityReportAt=$now'
}

flush_notifications() {
    local body count importance rc=0
    jq -e '.outbox|length>0' "$STATE_FILE" >/dev/null || return 0
    # Whole bounded events only. Any remainder is retained for a later run.
    jq 'reduce .outbox[] as $e ({bytes:0,items:[]};(($e.subject+"\n"+$e.detail)|utf8bytelength) as $n|if .bytes+$n<22000 then .bytes+=$n|.items+=[$e] else . end)|.items' "$STATE_FILE" >"$TMP_DIR/notify-selected.json" || return 1
    count=$(jq length "$TMP_DIR/notify-selected.json");((count>0)) || return 1
    body=$(jq -r '.[]|"["+.importance+"] "+.subject+"\nObserved: "+(.at|strflocaltime("%Y-%m-%d %H:%M:%S"))+"\n"+.detail+"\n"' "$TMP_DIR/notify-selected.json") || return 1
    importance=$(jq -r 'if any(.[];.importance=="alert") then "alert" elif any(.[];.importance=="warning") then "warning" else "normal" end' "$TMP_DIR/notify-selected.json")
    usr_ops_notify timeout 30 "$NOTIFY_BIN" -i "$importance" -s 'System Update Coordinator' -d 'Update actions, verification and attention' -m "$body" || rc=$?
    if ((rc==0));then mutate --slurpfile sent "$TMP_DIR/notify-selected.json" --argjson now "$(date +%s)" '
      reduce $sent[0][] as $e (.;.delivered[$e.id]=$now) |
      .outbox=([.outbox[]|. as $e|select(all($sent[0][];.id!=$e.id))]) |
      .delivered |= with_entries(select(.value>=$now-30*86400))' || return 1;fi
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
    [[ -z "${OWN_GATE_FD:-}" ]] || exec {OWN_GATE_FD}>&-
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
13:15-15:30 Singapore, reconciliation and grouped reporting. Schedule: 15,45 * * * *.
--status                       Saved policy and update status; no registry/install.
--check-only                   Refresh due evidence; no installation.
--allow docker NAME             Approve exact installed image repository/channel.
--allow plugin NAME.plg         Approve exact installed plugin source (protected
                               OS/updater/User Scripts plugins cannot be approved).
--deny docker|plugin NAME       Disable approval; retain reporting.
--pause / --resume              Pause/resume all new installations; checks continue.
--window HH:MM HH:MM            Set same-day Singapore maintenance window.
--limits TOTAL PLUGINS HOLD_H   Set daily caps (1-5 total, 0-2 plugins) and
                               candidate hold (1-168 hours); one update/run stays fixed.
--resolve JOB_ID NOTE           Close a reviewed failed/uncertain job without
                               claiming success; no installer/recovery is executed.
--help / --version              No network checks or installation.
Removing an app/plugin needs no command: two complete inventories retire its entry.
New/reinstalled identities default to reporting only and can be approved with CLI.
No command changes Docker startup/template/application settings or image channels.
Approval enables native updates within the existing configured channel. The age
hold is 24h from this coordinator's first observation, not registry publication.
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
    trap finish EXIT
    trap 'SUMMARY="Update coordinator interrupted; durable intent retained";exit 143' INT TERM HUP
    case "${1:-}" in
      --status) QUIET_FINISH=true;jq -n --slurpfile p "$POLICY_FILE" --slurpfile s "$STATE_FILE" '{policy:$p[0],items:$s[0].items,jobs:$s[0].jobs,pendingNotifications:($s[0].outbox|length)}';return 0;;
      --pause|--resume) local enabled=false;[[ "$1" != --resume ]] || enabled=true;policy_update --argjson enabled "$enabled" '.enabled=$enabled';return $?;;
      --limits) [[ $# == 4 && "$2" =~ ^[1-5]$ && "$3" =~ ^[0-2]$ && "$4" =~ ^[0-9]+$ ]] && ((10#$4>=1 && 10#$4<=168 && 10#$3<=10#$2)) || return 2;policy_update --argjson total "$2" --argjson plugins "$3" --argjson hold "$((10#$4))" '.limits={dailyTotal:$total,dailyPlugins:$plugins,candidateHoldHours:$hold}';return $?;;
      --window) [[ $# == 3 && "$2" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ && "$3" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ && "$2" < "$3" ]] || return 2;policy_update --arg start "$2" --arg end "$3" '.window={start:$start,end:$end}';return $?;;
      --resolve) [[ $# == 3 && -n "$3" && ${#3} -le 2000 ]] || return 2;jq -e --arg id "$2" '.jobs[$id]!=null and (.jobs[$id].status|IN("ATTENTION","VERIFYING","INTENT"))' "$STATE_FILE" >/dev/null || return 2;job_update "$2" '.jobs[$id].status="CLOSED_BY_OPERATOR" | .jobs[$id].resolutionNote=$note | .jobs[$id].closedAt=$now' --arg note "$3" --argjson now "$(date +%s)";return $?;;
      --allow|--deny)
        [[ $# == 3 && ( "$2" == docker || "$2" == plugin ) ]] && valid_name "$3" || return 2
        [[ "$3" != unRAIDServer.plg && "$3" != ca.update.applications.plg && "$3" != user.scripts.plg && "$3" != user.scripts.enhanced.plg ]] || return 2
        if [[ "$1" == --deny ]];then
          policy_update --arg kind "$2" --arg name "$3" 'if $kind=="docker" then .docker[$name]=((.docker[$name] // {identity:""})+{allow:false}) else .plugins[$name]=((.plugins[$name] // {identity:""})+{allow:false}) end';return $?
        fi
        collect_inventory || return 1
        local identity allow=false;[[ "$1" != --allow ]] || allow=true
        if [[ "$2" == docker ]];then identity=$(jq -er --arg name "$3" '.docker[$name].repository|select(length>0)' "$TMP_DIR/inventory.json") || return 2
        else identity=$(jq -er --arg name "$3" '.plugins[$name].installed.url|select(startswith("https://"))' "$TMP_DIR/inventory.json") || return 2;fi
        policy_update --arg kind "$2" --arg name "$3" --arg identity "$identity" --argjson allow "$allow" --argjson now "$(date +%s)" \
          'if $kind=="docker" then .docker[$name]={identity:$identity,allow:$allow,approvedAt:$now} else .plugins[$name]={identity:$identity,allow:$allow,approvedAt:$now} end';return $?;;
      ''|--check-only) ;;
      *) return 2;;
    esac
    collect_inventory || { SUMMARY='Inventory unavailable/incomplete; no retirement or installation';return 1; }
    check_updates || return 1
    recover_preparation || return 1
    reconcile_jobs || { RESULT=ATTENTION;SUMMARY='Pending update reconciliation incomplete; native actions not replayed'; }
    [[ "${1:-}" == --check-only ]] || install_one || return 1
    if jq -e 'any(.jobs[];.status=="ATTENTION" or .status=="INTENT")' "$STATE_FILE" >/dev/null;then RESULT=ATTENTION;fi
    clean_recovery_sets || log WARNING 'Recovery-set retention deferred; existing evidence retained'
    availability_digest || return 1
    flush_notifications || { RESULT=ATTENTION;SUMMARY='Notification delivery failed; report retained for retry'; }
    mutate --arg mode "$MODE" --argjson now "$(date +%s)" '.lastCompletedAt=$now | (if $mode=="automatic" then .lastAutomaticRunAt=$now else . end) | .jobs |= with_entries(select(.value.status=="INTENT" or .value.status=="VERIFYING" or .value.status=="ATTENTION" or (.value.startedAt // 0)>=$now-90*86400 or ((.value.recoveryPath // "")!="" and (.value.recoveryPrunedAt // 0)==0)))'
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]];then main "$@";fi
