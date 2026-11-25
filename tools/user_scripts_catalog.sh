# shellcheck shell=bash
# Shared User Scripts catalogue v1. Native schedule.json stays authoritative;
# readers also verify the live/restored script file. No schedule is executed.
usr_scripts_catalog() {
    local file="$1" root="${2:-$(dirname "$1")/scripts}" mode="${3:-live}" mapping='{}' native default_cron
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
