"""Four-producer weekly presentation; no native apps or notifications."""
import copy, datetime as dt, json, subprocess, sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
code=(root/'user_script/media_metadata_audit.sh').read_text().split("<<'PYWEEKLY'\n",1)[1].split('\nPYWEEKLY\n',1)[0]
now=2000000;stamp=dt.datetime.fromtimestamp(now,dt.timezone.utc).isoformat()
base={'saved':{'schema':1,'scheduleKey':'Asia/Singapore/7/11/55','nextDue':now-1,'lastCheckedAt':now-10,'lastReportAt':now-8*86400},'catalogue':{'schema':1,'lastScanAt':now,'trackingSince':now-8*86400,'issues':{},'runs':[]},'gap':False,'backlog':False,'metafusion':{'status':'available','snapshot':{'schema_version':1,'generated_at':stamp,'run':{'run_id':'run','status':'completed','finished_at':stamp},'open':[],'recently_resolved':[],'run_history':[]}}}
def producer(name):return {'name':name,'profile':name,'catalogue':{'schema':1,'lastScanAt':now,'trackingSince':now-8*86400,'coverage':{'valid':True,'paused':False},'issues':{},'runs':{}}}
def run(data):return json.loads(subprocess.check_output([sys.executable,'-c',code,str(now),'Asia/Singapore','7','11','55','20','false'],input=json.dumps(data).encode()))
x=copy.deepcopy(base);x['jobProducers']=[producer('recyclarr'),producer('imagemaid')]
r=run(x);assert not r['send'] and all(r['state']['producerEvidenceOk'].values())
issue={'id':'a','message':'Plex path permission denied; password=secret-value','severity':'ERROR','firstSeen':now-100,'lastSeen':now-20,'resolvedAt':0,'source':'/config/logs/imagemaid.log','occurrences':1}
x['jobProducers'][1]['catalogue']['issues']['a']=issue
r=run(x);assert r['send'] and '[ImageMaid]' in r['body'] and 'Recommended action:' in r['body'] and 'secret-value' not in r['body']
x['jobProducers'][1]['catalogue']['issues']['a']['resolvedAt']=now-10
x['jobProducers'][1]['catalogue']['issues']['a']['resolution']='Subsequent complete native job verified a clean outcome.'
r=run(x);assert r['resolved']==1 and r['actionable']==0 and 'RESOLVED' in r['body']
x['saved']['lastReportAt']=now-1
assert not run(x)['send'],'Old recovery emailed twice'
x['jobProducers'][0]['catalogue']['lastScanAt']=now-7200
r=run(x);assert r['send'] and not r['state']['producerEvidenceOk']['recyclarr'] and 'historical' in r['body']
x['jobProducers'][0]['retired']=True
assert not run(x)['send'],'Retired application reported as a fault'
x['jobProducers'][0]['retired']=False;x['jobProducers'][0]['catalogue']=None
assert run(x)['coverageWarnings']==1
x=copy.deepcopy(base);x['jobProducers']=[producer('recyclarr'),producer('imagemaid')]
for p in x['jobProducers']:
 p['catalogue']['issues']={str(i):dict(issue,id=str(i),message=p['name']+' invalid mapping '+str(i)) for i in range(30)}
x['catalogue']['issues']={'k':dict(id='k',message='YAML invalid key',severity='ERROR',context={},firstSeen=now-100,lastSeen=now-20,resolvedAt=0,affectedRuns=[])}
r=run(x);assert '[Kometa]' in r['body'] and '[ImageMaid]' in r['body'] and '[Recyclarr]' in r['body'] and len(r['body'].encode())<=24000
assert 'invalid mapping 29' in r['fullBody']
print('Quiet healthy/retired, exact recovery, stale/missing coverage, redaction and balanced four-producer report fixtures passed')
