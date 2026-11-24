<?php
// Native adapter regression without a Docker daemon, registry or installed app.
declare(strict_types=1);
$root=dirname(__DIR__);$path=tempnam(sys_get_temp_dir(),'update-native-test-');
$cachePath=tempnam(sys_get_temp_dir(),"update-native-cache-");
$source=file_get_contents($root.'/tools/system_update_native.php');
$source=preg_replace('/^require_once .*;\R/m','',$source);
$stub= <<<'STUB'
class DockerTemplates {}
class DockerClient {
 public function getContainerDetails($name) {return ['Id'=>$name,'Image'=>$name==='plex-new'?'new-image':(in_array($name,['missing','cached-old'],true)?'missing-image':'old-image')];}
 public function getDockerJSON($path) {
  if(str_contains($path,'missing-image'))return ['RepoDigests'=>[]];
  $sha=str_contains($path,'new-image')?str_repeat('b',64):str_repeat('a',64);
  return ['RepoDigests'=>['irrelevant/repo@sha256:'.str_repeat('c',64),'plexinc/pms-docker@sha256:'.$sha,'registry.example:5000/team/app@sha256:'.$sha]];
 }
}
class DockerUpdate {public function getRemoteVersionV2($repo) {return 'sha256:'.str_repeat('b',64);}}
STUB;
$source=str_replace('declare(strict_types=1);','declare(strict_types=1);'.$stub,$source);
file_put_contents($path,$source);
try {
 foreach(['plex-old'=>true,'plex-new'=>false] as $container=>$available){
  exec(escapeshellarg(PHP_BINARY).' '.escapeshellarg($path).' docker-check plexinc/pms-docker '.escapeshellarg($container),$out,$rc);
  $data=json_decode(implode("\n",$out),true,512,JSON_THROW_ON_ERROR);$out=[];
  if($rc!==0||$data['available']!==$available)throw new RuntimeException('Shared tag hid per-container installed image');
 }
 exec(escapeshellarg(PHP_BINARY).' '.escapeshellarg($path).' docker-local registry.example:5000/team/app:develop plex-old',$out,$rc);
 $data=json_decode(implode("\n",$out),true,512,JSON_THROW_ON_ERROR);$out=[];
 if($rc!==0||$data['local']!=='sha256:'.str_repeat('a',64))throw new RuntimeException('Registry port or image-specific digest was not preserved');
 exec(escapeshellarg(PHP_BINARY).' '.escapeshellarg($path).' docker-local plexinc/pms-docker missing 2>/dev/null',$out,$rc);
 if($rc===0)throw new RuntimeException('Missing installed digest did not fail closed');
 file_put_contents($cachePath,json_encode(['items'=>['docker:cached-old'=>['evidence'=>['imageId'=>'missing-image','containerId'=>'cached-old','identity'=>'plexinc/pms-docker','local'=>'sha256:'.str_repeat('a',64),'installedDigestSource'=>'docker-image-metadata']]]]));
 $out=[];exec(escapeshellarg(PHP_BINARY).' '.escapeshellarg($path).' docker-check plexinc/pms-docker cached-old '.escapeshellarg($cachePath),$out,$rc);
 $data=json_decode(implode("\n",$out),true,512,JSON_THROW_ON_ERROR);$out=[];
 if($rc!==0||$data['available']!==true||$data['installedDigestSource']!=='verified-image-cache')throw new RuntimeException('Exact-image cache did not preserve shared-container evidence');
 $bad=json_decode(file_get_contents($cachePath),true);$bad['items']['docker:cached-old']['evidence']['containerId']='different-container';file_put_contents($cachePath,json_encode($bad));
 exec(escapeshellarg(PHP_BINARY).' '.escapeshellarg($path).' docker-local plexinc/pms-docker cached-old '.escapeshellarg($cachePath).' 2>/dev/null',$out,$rc);
 if($rc===0)throw new RuntimeException('Recreated container inherited old digest evidence');
 echo "Per-container shared-tag digest, matching repository, registry port and missing-digest guards passed\n";
} finally {unlink($path);unlink($cachePath);}
