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
