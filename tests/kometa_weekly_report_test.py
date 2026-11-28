"""Exercise embedded reader/reporter directly; no Docker/API/YAML mutations."""
import copy, datetime as dt, json, os, pathlib, subprocess, sys, tempfile, time
ROOT=pathlib.Path(__file__).resolve().parents[1]
reader=(ROOT/'user_script/docker_service_watchdog.sh').read_text().split("program=\"$(cat <<'PY'\n",1)[1].split('\nPY\n',1)[0]
reporter=(ROOT/'user_script/media_metadata_audit.sh').read_text().split("<<'PYWEEKLY'\n",1)[1].split('\nPYWEEKLY\n',1)[0]
os.environ['TZ']='UTC';time.tzset()
def epoch(s):return int(dt.datetime.fromisoformat(s).replace(tzinfo=dt.timezone.utc).timestamp())
now=epoch('2026-11-23T01:00:00')
with tempfile.TemporaryDirectory() as temp:
    root=pathlib.Path(temp);path=root/'meta.log';state={}
    def emit(stamp,level,message):
        with path.open('a') as f:f.write(f'[{stamp},123] [kometa.py:499] [{level}] | {message} |\n')
    def run_log(hour,errors=False,scope=True):
        global now
        if path.exists():path.replace(root/'meta-1.log')
        stamp=f'2026-11-23 {hour:02}:00:'
        emit(stamp+'00','INFO','Starting Run')
        emit(stamp+'01','INFO','Loading Collection File File: config/collections/broken.yml')
        if errors:emit(stamp+'02','ERROR','''YAML Error: duplicate key collection_order line 12 token=private-secret "Authorization": "Bearer hidden-value"''')
        emit(stamp+'03','INFO','Movies Library')
        if scope:
            emit(stamp+'04','INFO','Running Example Collection')
            if errors:
                emit(stamp+'05','ERROR','Poster image file not found /assets/poster.jpg')
                emit(stamp+'06','ERROR','Poster image file not found /assets/poster.jpg')
            emit(stamp+'07','INFO','Finished Example Collection')
        emit(stamp+'08','INFO','Running Optional Collection')
        if errors:emit(stamp+'09','WARNING','No items found for collection minimum')
        emit(stamp+'10','INFO','Finished Optional Collection')
        emit(stamp+'11','INFO','Error Summary')
        if errors:emit(stamp+'12','ERROR','''YAML Error: duplicate key collection_order line 12 token=private-secret "Authorization": "Bearer hidden-value"''')
        emit(stamp+'13','INFO','Finished Run')
        emit(stamp+'14','INFO','Start Time: earlier Finished: now Run Time: 0:00:14')
        now=epoch(f'2026-11-23T{hour:02}:01:00')
    def scan():
        global state
        result=json.loads(subprocess.check_output([sys.executable,'-c',reader,'kometa',str(path),str(128*1024*1024),str(now),'test-container'],input=json.dumps(state).encode()))
        state=result['reader'];return result
    run_log(0,True);result=scan();cat=copy.deepcopy(state['maintenance'])
    assert len(cat['issues'])==3,cat
    assert 'private-secret' not in json.dumps(state) and 'hidden-value' not in json.dumps(state)
    assert any(e['context'].get('file')=='config/collections/broken.yml' for e in cat['issues'].values())
    example=next(e for e in cat['issues'].values() if e['context'].get('item')=='Example')
    assert example['occurrencesInLatestRun']==2 and len(example['affectedRuns'])==1
    scan();assert len(state['maintenance']['issues'][example['id']]['affectedRuns'])==1
    run_log(1,scope=False);scan()
    assert not state['maintenance']['issues'][example['id']]['resolvedAt'],'Skipped collection falsely resolved'
    run_log(2);scan();assert not state['maintenance']['issues'][example['id']]['resolvedAt']
    run_log(3);scan();fixed=state['maintenance']['issues'][example['id']]['resolvedAt'];assert fixed
    run_log(4);scan();assert state['maintenance']['issues'][example['id']]['resolvedAt']==fixed
    print('Catalogue context/redaction, repeat grouping, summary deduplication, skipped-scope protection and two-run recovery passed')
    def report(at,saved,catalogue=cat,partial=False):
        value={'metafusion':{'status':'available','snapshot':{'schema_version':1,'generated_at':dt.datetime.fromtimestamp(at,dt.timezone.utc).isoformat(),'run':{'run_id':'empty','status':'completed','finished_at':dt.datetime.fromtimestamp(at,dt.timezone.utc).isoformat()},'open':[],'recently_resolved':[],'run_history':[]}},'saved':saved,'catalogue':{**catalogue,'lastScanAt':at-10},'gap':partial,'backlog':False}
        return json.loads(subprocess.check_output([sys.executable,'-c',reporter,str(at),'Asia/Singapore','7','11','55','20','false'],input=json.dumps(value).encode()))
    start=report(now,{})
    assert not start['due'] and not start['send']
    due=start['state']['nextDue']
    review=report(due+60,start['state'])
    assert review['send'] and review['actionable']==3
    for text in ('broken.yml','Example','line 12','Recommended action:','First observed:','Affected recorded runs','OBSERVED in latest recorded run'):
        assert text in review['body'],text
    assert 'private-secret' not in review['body']
    assert not report(due+120,review['state'])['send'],'Duplicate weekly notification'
    empty={**cat,'issues':{}}
    assert not report(due+60,start['state'],empty)['send'],'Empty all-clear email'
    assert 'Coverage is partial' in report(due+60,start['state'],partial=True)['body']
    print('Weekly initialization, actionable details, timezone deadline, quiet-empty runs, partial coverage and once-weekly rendering passed')

    maintenance={**empty,'issues':{'backup-only':{'id':'backup-only','message':'Config Error: No libraries were found in config','severity':'FATAL','context':{},'firstSeen':due-90,'lastSeen':due-80,'affectedRuns':[due-90],'maintenanceProofs':[{'status':'maintenance-blocked','nativeResult':'failed','successNotClaimed':True,'stoppedAt':due-100,'startedAt':due-90,'finishedAt':due-80,'restartedAt':due-70}]}}}
    history=report(due+60,start['state'],maintenance)
    assert history['actionable']==0 and 'MAINTENANCE-BLOCKED' in history['body'] and 'no YAML change is indicated' in history['body']
    recorded={**history['state'],'nextDue':due+100}
    assert not report(due+120,recorded,maintenance)['send'],'Maintenance-only history churned another report'
    mixed=copy.deepcopy(maintenance);mixed['issues']['backup-only']['affectedRuns'].append(due-200)
    assert report(due+60,start['state'],mixed)['actionable']==1,'Unproven earlier failure was hidden'
    print('Exact maintenance-only history is explained once; native failure retained; mixed/unproven failures stay actionable')
