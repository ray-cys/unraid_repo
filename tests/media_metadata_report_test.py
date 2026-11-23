"""Native MetaFusion contract fixtures; no Docker, API or application mutations."""
import copy
import datetime as dt
import json
from pathlib import Path
import subprocess
import sys

root=Path(__file__).resolve().parents[1]
reporter=(root/'user_script/media_metadata_audit.sh').read_text().split("<<'PYWEEKLY'\n",1)[1].split('\nPYWEEKLY\n',1)[0]
now=int(dt.datetime(2026,11,29,4,tzinfo=dt.timezone.utc).timestamp())
def stamp(age=0): return dt.datetime.fromtimestamp(now-age,dt.timezone.utc).isoformat()
def row(key,**changes):
    return dict(finding_id=key*64,status='open',first_seen=stamp(9*86400),last_seen=stamp(100),last_checked_at=stamp(100),reason_code='no_candidate_returned',operation='poster',library='Movies',library_uuid='lib-1',server_id='server-1',plex_rating_key='123',title='Example',mode='kometa',component='core',last_run_id='r1',observations=3,next_action='recheck_on_eligible_scan',evidence={'provider_attempts':[{'provider':'tmdb','status':'empty','candidates':0}]},**changes)
base_row=row('a')
field=copy.deepcopy(base_row);field.update(finding_id='b'*64,operation='field/summary',reason_code='source_missing',evidence={'target_value_present':True,'token':'private-secret','url':'https://example.com/image?token=another-secret'})
fixed=copy.deepcopy(base_row);fixed.update(finding_id='c'*64,status='resolved',resolved_at=stamp(100),resolution='filesystem_verified',recovery_evidence={'provider':'fanart'})
native=dict(schema_version=1,generated_at=stamp(100),run=dict(run_id='r1',status='completed',finished_at=stamp(100),mode='kometa',targeted=False,libraries={'Movies':{'status':'success'}},fields_by_action={'updated':2},artwork_present_by_action={'reused':5},enabled_operations={'metadata':True,'posters':True}),open=[base_row,field],recently_resolved=[fixed],run_history=[])
catalogue=dict(schema=1,lastScanAt=now-10,trackingSince=now-8*86400,issues={},runs=[])
saved=dict(schema=1,scheduleKey='Asia/Singapore/7/11/55',nextDue=now-1,lastCheckedAt=now-10,lastReportAt=now-8*86400)
def report(native_value=native,cat=catalogue,wrapper=None):
    data=dict(saved=saved,catalogue=cat,gap=False,backlog=False,metafusion=wrapper or {'status':'available','snapshot':native_value})
    return json.loads(subprocess.check_output([sys.executable,'-c',reporter,str(now),'Asia/Singapore','7','11','55','20','false'],input=json.dumps(data).encode()))
r=report()
assert r['send'] and r['metafusionOpen']==2 and r['metafusionResolved']==1
for text in ['PERSISTENT','server=server-1','Plex=123','Provider returned no artwork candidate','target_value_present','existing metadata','filesystem verification','Recommended action:']:
    assert text in r['body'],text
assert 'private-secret' not in r['fullBody'] and 'another-secret' not in r['fullBody']
assert 'does not establish Plex application' not in r['body'] or 'RESOLVED' in r['body']
skipped=copy.deepcopy(native);skipped['open'][0]['last_run_id']='older'
assert 'Not rechecked in latest run; remains open' in report(skipped)['body']
stale=copy.deepcopy(native);stale['generated_at']=stamp(9*3600);stale['run']['finished_at']=stamp(9*3600)
r=report(stale);assert r['send'] and not r['state']['metafusionEvidenceOk'] and 'historical' in r['body']
broken=copy.deepcopy(native);broken['run']['status']='incomplete'
assert 'incomplete' in report(broken)['body']
r=report(wrapper={'status':'missing; awaiting first producer export'})
assert r['send'] and 'COVERAGE UNVERIFIED' in r['body'] and not r['state']['metafusionEvidenceOk']
future=copy.deepcopy(native);future['schema_version']=2
assert 'unsupported/invalid' in report(future)['body']
r=report(cat=None);assert r['send'] and not r['state']['kometaEvidenceOk'] and r['metafusionOpen']==2
empty=copy.deepcopy(native);empty.update(open=[],recently_resolved=[])
assert not report(empty)['send']
unknown=copy.deepcopy(native);unknown['open'][0]['reason_code']='future_reason'
assert 'future_reason' in report(unknown)['body']
# No loss of native recoveries on a skipped/unchanged run and no repeated old recovery.
old=copy.deepcopy(native);old['recently_resolved'][0]['resolved_at']=stamp(9*86400)
assert report(old)['metafusionResolved']==0
many=copy.deepcopy(native);many['open']=[dict(base_row,finding_id=str(i),title='Item '+str(i),operation='field/'+str(i),evidence={'error_type':'PermissionError','destination':'x'*1500}) for i in range(100)]
cat=copy.deepcopy(catalogue);cat['issues']={'k':dict(id='k',severity='ERROR',message='YAML Error: duplicate key',firstSeen=now-100,lastSeen=now-50,context={},affectedRuns=[],resolvedAt=0)}
r=report(many,cat)
assert '[Kometa]' in r['body'] and '[MetaFusion]' in r['body'] and len(r['body'].encode())<=24000
assert 'additional entries/groups' in r['body'] and 'Item 99' in r['fullBody']
print('Native identity/evidence/recovery, skipped scopes, stale/missing/unknown schemas, redaction, quiet-empty and shared email budget tests passed')

grouped=copy.deepcopy(native);grouped['open']=[dict(base_row,finding_id=str(i),title='Example '+str(i)) for i in range(100)]
r=report(grouped)
assert 'Related native findings: 100' in r['body'] and 'Example 99' in r['fullBody']
print('Repeated native observations grouped for email without losing individual full-report records')
