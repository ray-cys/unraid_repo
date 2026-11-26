#!/bin/bash
# secure_duplicate_cleanup.sh 1.0.0
# One-time Hubble JAV duplicate removal; never install a cron/User Scripts job.
# Removes only explicit manifest paths with an unchanged, byte-identical keeper.
# ポルノコレクション is a hard exclusion. Different encodes and multipart media
# are retained. Existing Plex/qBittorrent configuration is read, never changed.
#
# Usage (default: inspect manifest only, no hashing/deletion):
#   bash tools/secure_duplicate_cleanup.sh --manifest /tmp/cleanup-manifest.json
#   bash tools/secure_duplicate_cleanup.sh --manifest /tmp/cleanup-manifest.json \
#     --evidence /tmp/full-results.jsonl --execute
#
# The manifest must be freshly prepared from filesystem and allowed Plex-library
# inventories: schema=1, root=/mnt/user/secure, generatedAt, excludedRoot, pairs.
# Each pair has id, code, keep, remove, keepPlex[], removePlex[] (ratingKey and
# sectionId). Optional evidence is previous SHA-256 proof, never a filename guess.
# Cached hashes are reusable only with matching device/inode/size/mtime/ctime.
# Missing/changed proofs are hashed sequentially with native sha256sum. All pairs
# are verified before short appdata/export/torrent leases and final live checks.
#
# Writes one metadata-only receipt, duplicate-cleanup-last.json, under the existing
# media_torrent_management log root. No quarantine, media backup, .dup copies,
# recursive deletion or configuration changes. Interrupted/uncertain actions are
# recorded; reruns revalidate paths and never remove the keeper. Ordinary Plex
# library scans are requested once per affected library; no metadata refresh or
# forced trash emptying. ROOT/prefs/API are deliberately Hubble-specific.
set -euo pipefail
for command in php sha256sum curl pgrep;do command -v "$command" >/dev/null || { printf 'Missing requirement: %s\n' "$command" >&2;exit 1; };done
for argument in "$@";do
    if [[ "$argument" == --execute ]];then
        mountpoint -q /mnt/user && mountpoint -q /mnt/vault || { printf 'Required user/vault mounts unavailable; no deletion performed.\n' >&2;exit 1; }
    fi
done
exec php /dev/stdin "$@" <<'PHP'
<?php
function note(string $s):void {echo date('Y-m-d H:i:s')." | $s\n";flush();}
function excluded(string $p,string $root):bool {$x=$root.'/プライベート/ポルノコレクション';return $p===$x||str_starts_with($p,$x.'/');}
function fileState(string $p,string $root):array {
    if(excluded($p,$root)||!str_starts_with($p,$root.'/')||str_contains($p,"\0"))throw new RuntimeException('EXCLUDED_OR_OUTSIDE_SCOPE');
    $rs=@lstat($root);if(!$rs||($rs['mode']&0170000)!==0040000)throw new RuntimeException('UNSAFE_ROOT');
    if(!preg_match('/\.(mp4|mkv|avi|wmv|m4v|mov|ts)(?:\.dup[0-9]+)?$/i',$p))throw new RuntimeException('NOT_A_VIDEO_PATH');
    $relative=substr($p,strlen($root)+1);if(!str_starts_with($relative,'ポルノ/')&&!str_starts_with($relative,'プライベート/'))throw new RuntimeException('OUTSIDE_MEDIA_ROOTS');
    $current=$root;foreach(explode('/',$relative) as $bit){if($bit===''||$bit==='.'||$bit==='..')throw new RuntimeException('UNSAFE_PATH');$current.='/'.$bit;clearstatcache(true,$current);$s=@lstat($current);if(!$s)throw new RuntimeException('PATH_MISSING');if(($s['mode']&0170000)===0120000)throw new RuntimeException('SYMLINK_RETAINED');}
    if(($s['mode']&0170000)!==0100000||$s['size']<=0)throw new RuntimeException('NOT_A_NONEMPTY_REGULAR_FILE');
    return ['path'=>$p,'size'=>$s['size'],'dev'=>$s['dev'],'inode'=>$s['ino'],'mtime'=>$s['mtime'],'ctime'=>$s['ctime'],'links'=>$s['nlink']];
}
function unchanged(array $a,array $b):bool {foreach(['size','dev','inode','mtime','ctime'] as $k)if(!isset($a[$k],$b[$k])||$a[$k]!==$b[$k])return false;return true;}
function runCommand(array $args):array {$proc=proc_open($args,[1=>['pipe','w'],2=>['pipe','w']],$pipes);if(!is_resource($proc))throw new RuntimeException('COMMAND_START_FAILED');$out=stream_get_contents($pipes[1]);$err=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);$rc=proc_close($proc);return [$rc,$out,$err];}
function saveReceipt(string $path,array $report):void {
    $dir=dirname($path);if(!is_dir($dir)||is_link($dir)||is_link($path))throw new RuntimeException('UNSAFE_OR_UNAVAILABLE_REPORT_DIRECTORY');
    $tmp=tempnam($dir,'.duplicate-receipt-');if($tmp===false)throw new RuntimeException('RECEIPT_CREATE_FAILED');chmod($tmp,0600);
    $f=fopen($tmp,'wb');$json=json_encode($report,JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR)."\n";
    if(!$f||fwrite($f,$json)!==strlen($json)||!fflush($f)||(function_exists('fsync')&&!fsync($f))){@unlink($tmp);throw new RuntimeException('RECEIPT_WRITE_FAILED');}fclose($f);if(!rename($tmp,$path)){@unlink($tmp);throw new RuntimeException('RECEIPT_PUBLISH_FAILED');}
}
function verifiedHash(string $path,string $root,array &$cache):array {
    $before=fileState($path,$root);$old=$cache[$path]??[];
    if(unchanged($before,$old)&&preg_match('/^[a-f0-9]{64}$/',$old['sha256']??'')){note('Reused unchanged full-file proof: '.basename($path));return $before+['sha256'=>$old['sha256']];}
    note('Hashing '.basename($path).' ('.round($before['size']/1073741824,2).' GiB)');
    [$rc,$out]=runCommand(['sha256sum','--',$path]);if($rc!==0||!preg_match('/^([a-f0-9]{64})\s/',$out,$m))throw new RuntimeException('FULL_HASH_READ_FAILED');
    $after=fileState($path,$root);if(!unchanged($before,$after))throw new RuntimeException('FILE_CHANGED_DURING_HASH');
    return $cache[$path]=$after+['sha256'=>$m[1]];
}
function applyVerifiedPair(array $pair,array $keepProof,array $removeProof,string $root):array {
    $keep=$pair['keep'];$remove=$pair['remove'];if($keep===$remove)throw new RuntimeException('KEEPER_EQUALS_REMOVAL');
    if(!preg_match('/^[a-f0-9]{64}$/',$keepProof['sha256']??'')||($keepProof['sha256']??'')!==($removeProof['sha256']??null))throw new RuntimeException('NOT_BYTE_IDENTICAL');
    $ks=fileState($keep,$root);$ds=fileState($remove,$root);
    if(!unchanged($ks,$keepProof)||!unchanged($ds,$removeProof))throw new RuntimeException('FILE_CHANGED_BEFORE_DELETION');
    if($ks['dev']===$ds['dev']&&$ks['inode']===$ds['inode'])throw new RuntimeException('SAME_INODE_NO_STORAGE_SAVING');
    if(!unlink($remove))throw new RuntimeException('UNLINK_FAILED');
    // Never remove a library root, performer root or a nonempty directory.
    $dir=dirname($remove);$rel=substr($dir,strlen($root)+1);$bits=explode('/',$rel);$minimum=$bits[0]==='プライベート'?3:2;$dirs=[];
    while(count($bits)>=$minimum&&!excluded($dir,$root)&&!is_link($dir)&&@rmdir($dir)){$dirs[]=$dir;$dir=dirname($dir);array_pop($bits);}
    try{$keeperStable=unchanged(fileState($keep,$root),$keepProof);}catch(Throwable $e){$keeperStable=false;}
    return ['deletedBytes'=>$ds['size'],'removedDirectories'=>$dirs,'keeperStableAfter'=>$keeperStable];
}
function plexGet(string $path):array {
    static $context=null;if($context===null){$p=@simplexml_load_file('/mnt/cache/appdata/plex-media/Library/Application Support/Plex Media Server/Preferences.xml');$token=$p?(string)$p['PlexOnlineToken']:'';if($token==='')throw new RuntimeException('PLEX_TOKEN_UNAVAILABLE');$context=stream_context_create(['http'=>['timeout'=>12,'header'=>"Accept: application/json\r\nX-Plex-Token: $token\r\n"]]);}
    $body=@file_get_contents('http://192.168.50.21:32400'.$path,false,$context);if($body===false)throw new RuntimeException('PLEX_API_UNAVAILABLE');if(preg_match('#^/library/sections/[0-9]+/refresh$#',$path))return ['requestAccepted'=>true];$j=json_decode($body,true,512,JSON_THROW_ON_ERROR);if(!isset($j['MediaContainer']))throw new RuntimeException('INVALID_PLEX_RESPONSE');return $j['MediaContainer'];
}
function plexMember(string $path,array $refs):array {
    $wanted='/data/'.substr($path,strlen('/mnt/user/secure/'));$views=0;$found=false;$sections=[];$keys=[];
    foreach($refs as $ref){$id=(string)($ref['ratingKey']??'');$section=(string)($ref['sectionId']??'');if(!ctype_digit($id)||!ctype_digit($section)||($ref['library']??'')==='ポルノコレクション')throw new RuntimeException('INVALID_PLEX_REFERENCE');
        foreach(plexGet('/library/metadata/'.$id)['Metadata']??[] as $item){foreach($item['Media']??[] as $media){foreach($media['Part']??[] as $part){if(($part['file']??'')!==$wanted)continue;if(count($media['Part'])!==1)throw new RuntimeException('MULTIPART_RETAINED');$found=true;$views=max($views,(int)($item['viewCount']??0));$sections[]=$section;$keys[]=$id;}}}}
    if(!$found)throw new RuntimeException('PLEX_FILE_REFERENCE_CHANGED');return ['viewCount'=>$views,'sections'=>array_unique($sections),'keys'=>array_unique($keys)];
}
function liveQbit():array {
    [$rc,$out]=runCommand(['curl','--noproxy','*','--connect-timeout','4','--max-time','20','--max-filesize','16777216','--fail','--silent','--show-error','--resolve','qbittorrent.taila4be9.ts.net:443:100.64.251.79','https://qbittorrent.taila4be9.ts.net/api/v2/torrents/info']);
    if($rc!==0)throw new RuntimeException('QBIT_API_UNAVAILABLE');$j=json_decode($out,true,512,JSON_THROW_ON_ERROR);if(!is_array($j)||!array_is_list($j))throw new RuntimeException('INVALID_QBIT_RESPONSE');foreach($j as $job)if(!isset($job['content_path'],$job['hash'])||!str_starts_with($job['content_path'],'/data/'))throw new RuntimeException('UNMAPPED_QBIT_PATH');return $j;
}
function activeMedia(array $pair,array $refs,array $jobs):bool {
    foreach($jobs as $job){$p='/mnt/user/secure/'.substr($job['content_path'],6);foreach([$pair['keep'],$pair['remove']] as $f)if($p===$f||str_starts_with($p,$f.'/')||str_starts_with($f,$p.'/'))return true;}
    foreach(plexGet('/status/sessions')['Metadata']??[] as $item){if(in_array((string)($item['ratingKey']??''),$refs,true))return true;foreach($item['Media']??[] as $m)foreach($m['Part']??[] as $p)if(in_array('/mnt/user/secure/'.substr($p['file']??'',6),[$pair['keep'],$pair['remove']],true))return true;}
    return false;
}
function lease(string $path,int $mode){$f=fopen($path,'c');if(!$f||!flock($f,$mode|LOCK_NB))throw new RuntimeException('COORDINATED_OPERATION_BUSY');return $f;}
// MAIN
$opt=getopt('',['manifest:','evidence:','report:','execute','help']);
if(isset($opt['help'])||!isset($opt['manifest'])){echo "Usage: bash secure_duplicate_cleanup.sh --manifest FILE [--evidence JSONL] [--report FILE] [--execute]\nDefault: validate explicit paths only; --execute verifies content and removes approved extras once.\n";exit(isset($opt['help'])?0:2);}
$root='/mnt/user/secure';$reportPath=$opt['report']??'/mnt/vault/cloud/logs/script/media_torrent_management/duplicate-cleanup-last.json';$manifest=json_decode(file_get_contents($opt['manifest']),true,512,JSON_THROW_ON_ERROR);
if(($manifest['schema']??0)!==1||($manifest['root']??'')!==$root||($manifest['excludedRoot']??'')!==$root.'/プライベート/ポルノコレクション'||time()-($manifest['generatedAt']??0)>3600||($manifest['generatedAt']??0)>time()+60||count($manifest['pairs']??[])>100)throw new RuntimeException('INVALID_OR_STALE_MANIFEST');
$pairs=$manifest['pairs'];$seen=[];foreach($pairs as $p){foreach(['keep','remove'] as $k){fileState($p[$k],$root);if(empty($p[$k.'Plex']))throw new RuntimeException('MISSING_PLEX_REFERENCE');}if($p['keep']===$p['remove']||isset($seen[$p['remove']]))throw new RuntimeException('CONFLICTING_PLAN');$seen[$p['remove']]=true;}
foreach($pairs as $p)if(isset($seen[$p['keep']]))throw new RuntimeException('KEEPER_IS_ANOTHER_REMOVAL');
note('Validated '.count($pairs).' explicit pairs; excluded library: ポルノコレクション');if(!isset($opt['execute'])){note('Inspection only; no hashing or deletion');exit(0);}
$own=lease('/run/secure_duplicate_cleanup.lock',LOCK_EX);$cache=[];
if(isset($opt['evidence']))foreach(file($opt['evidence'],FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){$j=json_decode($line,true,512,JSON_THROW_ON_ERROR);if(($j['status']??'')!=='IDENTICAL')continue;foreach($j['files']??[] as $f)if(($f['status']??'')==='VERIFIED')$cache[$f['path']]=$f;}
if(is_file($reportPath)&&!is_link($reportPath)){foreach(json_decode(file_get_contents($reportPath),true)['evidence']??[] as $f)$cache[$f['path']]=$f;}
$report=['schema'=>1,'version'=>'1.0.0','startedAt'=>time(),'status'=>'VERIFYING','excludedRoot'=>$manifest['excludedRoot'],'manifestSha256'=>hash_file('sha256',$opt['manifest']),'plexInventorySummary'=>$manifest['plexInventorySummary']??[],'retainedPlexReviews'=>$manifest['retainedPlexReviews']??[],'selectedPairs'=>count($pairs),'actions'=>[],'evidence'=>[],'deletedFiles'=>0,'deletedBytes'=>0,'scanRequests'=>[]];saveReceipt($reportPath,$report);$ready=[];
// Small unverified pairs first; previously completed proof is reused unchanged.
usort($pairs,fn($a,$b)=>filesize($a['remove'])<=>filesize($b['remove']));
foreach($pairs as $pair){$id=(string)$pair['id'];try{$ks=fileState($pair['keep'],$root);$ds=fileState($pair['remove'],$root);if($ks['size']!==$ds['size'])throw new RuntimeException('DIFFERENT_SIZE_RETAINED');plexMember($pair['keep'],$pair['keepPlex']);plexMember($pair['remove'],$pair['removePlex']);$k=verifiedHash($pair['keep'],$root,$cache);$report['evidence'][$pair['keep']]=$k;saveReceipt($reportPath,$report);$d=verifiedHash($pair['remove'],$root,$cache);$report['evidence'][$pair['remove']]=$d;if($k['sha256']!==$d['sha256'])throw new RuntimeException('DIFFERENT_CONTENT_RETAINED');$ready[]=[$pair,$k,$d];$report['actions'][$id]=['status'=>'VERIFIED_READY','keep'=>$pair['keep'],'remove'=>$pair['remove'],'sha256'=>$k['sha256'],'size'=>$d['size']];note('Verified identical: '.$pair['code']);}catch(Throwable $e){$report['actions'][$id]=['status'=>'RETAINED','keep'=>$pair['keep'],'remove'=>$pair['remove'],'reason'=>$e->getMessage()];note('Retained '.$pair['code'].': '.$e->getMessage());}saveReceipt($reportPath,$report);}
try{$torrent=lease('/tmp/media_torrent_management.lock',LOCK_EX);$appdata=lease('/run/arr-appdata-coordination.lock',LOCK_SH);$export=lease('/run/user-script-state-export.lock',LOCK_SH);$jobs=liveQbit();}catch(Throwable $e){$report['status']='DEFERRED';$report['reason']=$e->getMessage();saveReceipt($reportPath,$report);note('No deletion: '.$e->getMessage());exit(75);}
$report['status']='DELETING';saveReceipt($reportPath,$report);$sections=[];
foreach($ready as [$pair,$k,$d]){$id=(string)$pair['id'];try{[$rc]=runCommand(['pgrep','-f','(^|/)(mover|mover\\.old)([[:space:]]|$)']);if($rc!==1)throw new RuntimeException('MOVER_OR_PROCESS_CHECK_UNCERTAIN');$km=plexMember($pair['keep'],$pair['keepPlex']);$dm=plexMember($pair['remove'],$pair['removePlex']);if($dm['viewCount']>$km['viewCount'])throw new RuntimeException('WATCH_HISTORY_PRIORITY_CHANGED');if(activeMedia($pair,array_unique(array_merge($km['keys'],$dm['keys'])),liveQbit()))throw new RuntimeException('ACTIVE_MEDIA_RETAINED');$report['actions'][$id]['status']='DELETE_INTENT';$report['actions'][$id]['intentAt']=time();saveReceipt($reportPath,$report);$result=applyVerifiedPair($pair,$k,$d,$root);$report['actions'][$id]+=$result;$report['actions'][$id]['status']=$result['keeperStableAfter']?'DELETED':'DELETED_KEEPER_REQUIRES_REVIEW';$report['actions'][$id]['deletedAt']=time();$report['deletedFiles']++;$report['deletedBytes']+=$result['deletedBytes'];$sections=array_unique(array_merge($sections,$dm['sections']));note('Deleted extra copy: '.$pair['code'].'; keeper retained');if(!$result['keeperStableAfter']){saveReceipt($reportPath,$report);throw new RuntimeException('KEEPER_CHANGED_AFTER_UNLINK');}}catch(Throwable $e){if(($report['actions'][$id]['status']??'')!=='DELETED_KEEPER_REQUIRES_REVIEW')$report['actions'][$id]['status']='RETAINED_OR_REQUIRES_REVIEW';$report['actions'][$id]['reason']=$e->getMessage();note('Retained/review '.$pair['code'].': '.$e->getMessage());}saveReceipt($reportPath,$report);if(($report['actions'][$id]['status']??'')==='DELETED_KEEPER_REQUIRES_REVIEW')break;}
// Release shared leases before requesting asynchronous library scans.
unset($torrent,$appdata,$export);
foreach($sections as $id){try{plexGet('/library/sections/'.$id.'/refresh');$report['scanRequests'][$id]='REQUESTED';}catch(Throwable $e){$report['scanRequests'][$id]='FAILED: '.$e->getMessage();}}
$retained=count(array_filter($report['actions'],fn($a)=>$a['status']!=='DELETED'));$report['status']=$retained?'COMPLETED_WITH_RETAINED_FILES':'COMPLETED';$report['completedAt']=time();saveReceipt($reportPath,$report);note('Complete: deleted='.$report['deletedFiles'].'; duplicate GiB='.round($report['deletedBytes']/1073741824,2).'; retained='.$retained.'; receipt='.$reportPath);
PHP
