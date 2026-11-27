<?php
// Pure reducer for compact scheduler/run-log evidence. No files, APIs or actions.
// One catalogue per installed producer; 14 days/128 runs/256 causes maximum.
$input=json_decode(stream_get_contents(STDIN),true,512,JSON_THROW_ON_ERROR);
$now=(int)$input['now'];$cutoff=$now-14*86400;$job=$input['job'];$profile=$input['profile'];
$old=$job['weeklyReview']??['schema'=>1,'trackingSince'=>$now,'issues'=>[],'runs'=>[],'droppedAt'=>0];
if(($old['schema']??0)!==1||!is_array($old['issues'])||!is_array($old['runs']))throw new RuntimeException('Invalid retained weekly job catalogue');
function redactJob($text){
 $s=(string)$text;
 $s=preg_replace('~(?i)(https?://)[^/@\s]+@~','$1[REDACTED]@',$s);
 $s=preg_replace('~(?i)(https?://[^\s?#|]+)[?#][^\s|]*~','$1?[REDACTED]',$s);
 $s=preg_replace('~(?i)(["\x27]?(?:api[_-]?key|token|password|secret|authorization)["\x27]?\s*[:=]\s*)(["\x27]).*?\2~','$1[REDACTED]',$s);
 $s=preg_replace('~(?i)(authorization[=: ]+(?:bearer\s+|basic\s+)?)[^\s,;|]+~','$1[REDACTED]',$s);
 $s=preg_replace('~(?i)((?:api[_-]?key|token|password|secret)[=: ]+)[^\s,;|]+~','$1[REDACTED]',$s);
 return substr(preg_replace('/\s+/',' ',trim($s)),0,900);
}
function resolveJobCause(&$row,$at,$reason){
 $row['resolvedAt']=$at;$row['resolution']=$reason;
 $history=$row['recoveries']??[];if(!in_array($at,$history,true))$history[]=$at;
 $row['recoveries']=array_slice($history,-8);
}
function jobCause(&$cat,$key,$message,$severity,$at,$run,$source){
 $prior=$cat['issues'][$key]??null;
 $row=$prior??['id'=>$key,'firstSeen'=>$at,'lastSeen'=>$at,'affectedRuns'=>[],'resolvedAt'=>0,'occurrences'=>0];
 if(!in_array($run,$row['affectedRuns'],true)){$row['affectedRuns'][]=$run;$row['occurrences']++;}
 $row['affectedRuns']=array_slice($row['affectedRuns'],-128);
 if($prior && ($at<$prior['lastSeen'] || ($prior['resolvedAt']??0)>=$at)){
  $row['firstSeen']=min($row['firstSeen'],$at);$cat['issues'][$key]=$row;return;
 }
 if($prior && ($prior['resolvedAt']??0)>0)$row['firstSeen']=$at;
 $row['lastSeen']=$at;$row['message']=redactJob($message);$row['severity']=$severity;$row['source']=$source;$row['resolvedAt']=0;
 $cat['issues'][$key]=$row;
}

$cat=$old;$cat['lastScanAt']=$now;$paused=(bool)($input['paused']??false);
$observations=$input['observations']??[];
$invalid=false;foreach($observations as $key=>$o)if(preg_match('/:job-(evidence|unverified)$/',$key))$invalid=true;
$valid=!$paused && !$invalid && ($job['scanned']??0)>=$now-600 && ($job['scanned']??0)<=$now+300;
if($profile==='imagemaid')$valid=$valid && !($job['runLog']['gap']??true) && !($job['runLog']['backlog']??true);
$valid=$valid && !in_array($job['result']??'unknown',['unknown','completed-unverified'],true);
$cat['profile']=$profile;
$cat['coverage']=['valid'=>$valid,'paused'=>$paused,'source'=>$job['evidenceSource']??'unknown','checkedAt'=>$now];
if($paused){$cat['issues']=(object)$cat['issues'];$cat['runs']=(object)$cat['runs'];echo json_encode($cat,JSON_THROW_ON_ERROR);exit;}
$records=$profile==='imagemaid'?($job['runLog']['reviewRuns']??[]):($job['logState']['reviewRuns']??[]);
// A prior cached result has a date/outcome, but no reconstructed reason history.
// It cannot prove clean coverage or resolve any newly tracked finding.
if(!$records && ($job['finished']??0)>0)$records=[['id'=>'retained:'.($job['finished']), 'started'=>$job['started']??0,'finished'=>$job['finished'],'result'=>$job['result']??'unknown','complete'=>false,'findings'=>[],'source'=>$job['evidenceSource']??'unknown','retained'=>true]];
$cat['droppedAt']=max($cat['droppedAt']??0,$job['runLog']['reviewDroppedAt']??0,$job['logState']['reviewDroppedAt']??0);
foreach($records as $row)if(($row['captureLimited']??false) && ($row['finished']??0)>=$cutoff)$cat['droppedAt']=max($cat['droppedAt']??0,$row['finished']);
usort($records,fn($a,$b)=>($a['finished']??0)<=>($b['finished']??0));
$latestProcessed=(int)($cat['latestProcessed']??0);
foreach($records as $record){
 $at=$record['finished']??0;$id=$record['id']??'';
 if(is_int($at)&&$at<$cutoff)continue;
 if(!is_int($at)||$at>$now+300||!is_string($id)||$id===''||!is_array($record['findings']??[])){$cat['coverage']['valid']=false;continue;}
 $revision=hash('sha256',json_encode($record,JSON_THROW_ON_ERROR));
 $existing=$cat['runs'][$id]??null;
 if($existing && ($existing['revision']??'')===$revision)continue;
 $findings=$record['findings']??[];$counts=$record['counts']??[];$keys=[];$reasonsValid=true;
 foreach($findings as $f){
  if(!is_array($f)||!is_string($f['message']??null)){$reasonsValid=false;$cat['coverage']['valid']=false;continue;}
  $message=redactJob($f['message']);$severity=strtoupper($f['severity']??'WARNING');
  $key=substr(hash('sha256',$profile.'|'.$severity.'|'.$message),0,24);$keys[$key]=true;
  jobCause($cat,$key,$message,$severity,$at,$id,$record['source']??($job['evidenceSource']??'unknown'));
 }
 if(in_array($record['result']??'',['failed','completed-errors','completed-warnings','completed-unverified'],true) && !$keys){
  $message='Recorded job outcome: '.$record['result'].'; detailed reasons were not captured. Review the native run log.';
  $key=substr(hash('sha256',$profile.'|'.$message),0,24);$keys[$key]=true;
  jobCause($cat,$key,$message,'WARNING',$at,$id,$record['source']??'native job');
 }
 $complete=($record['complete']??false)===true && $reasonsValid && !($record['captureLimited']??false);
 // Exact complete clean scheduler/run evidence resolves processing causes.
 // Operational conditions (missed run/evidence) require their own recovery.
 if($at>=$latestProcessed && $complete && ($record['result']??'')==='success' && !$keys){
  foreach($cat['issues'] as &$issue)if(($issue['kind']??'processing')==='processing' && ($issue['lastSeen']??0)<$at && !($issue['resolvedAt']??0)){
   resolveJobCause($issue,$at,'A subsequent complete native run finished without recorded errors or warnings.');
  }unset($issue);
 }
 $cat['runs'][$id]=['id'=>$id,'started'=>$record['started']??0,'finished'=>$at,'result'=>$record['result']??'unknown','complete'=>$complete,'clean'=>($complete && ($record['result']??'')==='success' && !$keys),'counts'=>$counts,'revision'=>$revision,'retained'=>$record['retained']??false];
 $latestProcessed=max($latestProcessed,$at);
}
$cat['latestProcessed']=$latestProcessed;
// Late-arriving old failures remain in history without reopening a cause that
// a later complete native run has already cleared.
foreach($cat['issues'] as &$issue)if(($issue['kind']??'processing')==='processing' && !($issue['resolvedAt']??0)){
 foreach($cat['runs'] as $r)if(($r['clean']??false) && $r['finished']>$issue['lastSeen']){
  resolveJobCause($issue,$r['finished'],'A later complete clean native run already verified recovery when this older evidence arrived.');break;
 }
}unset($issue);

$activeOps=[];
foreach($observations as $key=>$o){
 // Processing errors come from exact run records above; retain failures even
 // if a later run succeeds before the weekly consumer runs.
 if(!preg_match('/:job-(overdue|frequency|overrun|evidence|unverified)$/',$key))continue;
 $id='operation:'.substr(hash('sha256',$key),0,24);$activeOps[$id]=true;
 jobCause($cat,$id,$o['message']??$key,$o['severity']??'WARNING',$now,'condition:'.($o['first']??$now),$job['evidenceSource']??'watchdog');
 $cat['issues'][$id]['kind']='operational';
}
if($valid)foreach($cat['issues'] as $id=>&$issue)if(($issue['kind']??'')==='operational' && !isset($activeOps[$id]) && !($issue['resolvedAt']??0)){
 resolveJobCause($issue,$now,'Docker watchdog confirmed that the exact job-evidence/deadline condition cleared with current valid evidence.');
}unset($issue);
$cat['runs']=array_filter($cat['runs'],fn($r)=>$r['finished']>=$cutoff);
uasort($cat['runs'],fn($a,$b)=>$a['finished']<=>$b['finished']);
if(count($cat['runs'])>128){$cat['droppedAt']=$now;$cat['runs']=array_slice($cat['runs'],-128,null,true);}
$cat['issues']=array_filter($cat['issues'],fn($r)=>!($r['resolvedAt']??0)||$r['resolvedAt']>=$cutoff);
if(count($cat['issues'])>256){uasort($cat['issues'],fn($a,$b)=>$a['lastSeen']<=>$b['lastSeen']);$cat['issues']=array_slice($cat['issues'],-256,null,true);$cat['droppedAt']=$now;}
if($cat['coverage']['valid'])$cat['lastEvidenceAt']=$now;
$cat['issues']=(object)$cat['issues'];$cat['runs']=(object)$cat['runs'];
echo json_encode($cat,JSON_THROW_ON_ERROR|JSON_UNESCAPED_SLASHES);
