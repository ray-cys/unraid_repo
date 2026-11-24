"""Isolated media audit evidence/resume fixtures; no live media or Docker calls."""
import base64, contextlib, copy, gzip, io, json, os
from pathlib import Path
import subprocess, tempfile, time, types
root=Path(__file__).resolve().parents[1]
source=(root/'user_script/media_integrity_audit.sh').read_text().split("<<'PYWORKER'\n",1)[1].split('\nPYWORKER\n',1)[0]
m=types.ModuleType('media_fixture');exec(compile(source,'worker','exec'),m.__dict__)
with tempfile.TemporaryDirectory() as folder:
    path=Path(folder).resolve();(path/'movies').mkdir();(path/'series').mkdir();(path/'formula1').mkdir()
    video=path/'movies'/'Example.mkv';video.write_bytes(b'fixture media')
    cfg=dict(root=str(path),hostRoot='/mnt/user/media',libraries=['movies','series','formula1'],mode='scan',budgetSeconds=120,
             maxStateBytes=64*1024*1024,segmentSeconds=600,segmentWallSeconds=30,fileSliceSeconds=90,recheckDays=180,
             settleSeconds=0,threads=2,memoryMiB=2048,toolset='fixture')
    state={'schema':1,'files':{}}
    duration=10
    fail=False;timeout=False;change=False;stop_after=0;calls=0
    def runner(args,fd,seconds,beat,memory):
        global calls
        if args[0]=='ffprobe':
            return dict(code=0,out=json.dumps({'format':{'duration':duration},'streams':[{'index':0,'codec_type':'video','codec_name':'h264'},{'index':1,'codec_type':'audio','codec_name':'aac'}]}),err='',stop='',wall=.01)
        calls+=1
        if change:video.write_bytes(b'changed while decoder runs')
        if timeout:return dict(code=-9,out='',err='',stop='timeout',wall=.01)
        if fail:return dict(code=1,out='',err='Invalid NAL unit, error while decoding',stop='',wall=.01)
        span=float(args[args.index('-t')+1]);out='frame=100\nout_time_us='+str(int(span*1000000))+'\n'
        if stop_after and calls>=stop_after:m.STOP='fixture cancellation'
        return dict(code=0,out=out,err='',stop='',wall=.01)
    m.run_process=runner
    def execute(current):
        m.STOP='';audit=m.Audit(cfg,copy.deepcopy(current))
        with contextlib.redirect_stdout(io.StringIO()):audit.execute()
        return audit
    good=execute(state)
    assert good.stats['cyclesCompleted']==1 and good.state['files']['movies/Example.mkv']['verifiedAt']>0
    assert video.read_bytes()==b'fixture media'
    # Host jq input construction must not round ns timestamps/large inodes and
    # accidentally invalidate every saved offset at the next weekly run.
    bridged=json.loads(subprocess.check_output(['jq','.'],input=json.dumps(good.state).encode()))
    inventory_cfg=copy.deepcopy(cfg);inventory_cfg['mode']='inventory'
    check=m.Audit(inventory_cfg,bridged)
    with contextlib.redirect_stdout(io.StringIO()):check.execute()
    assert check.stats['newChanged']==0 and check.state['files']['movies/Example.mkv']['verifiedAt']>0
    # Priority recovery passes stat/decode exact replacements only and never
    # prune ordinary cached entries outside that narrow scope.
    targeted=copy.deepcopy(cfg);targeted.update(targeted=True,recoveryPriority=['movies/Example.mkv'])
    cached=copy.deepcopy(state);cached['files']['series/untouched.mkv']={'identity':['1','2','3','4','5'],'offset':0,'verifiedAt':123}
    narrow=m.Audit(targeted,cached)
    with contextlib.redirect_stdout(io.StringIO()):narrow.execute()
    assert narrow.stats['targeted'] and narrow.found=={'movies/Example.mkv'}
    assert 'series/untouched.mkv' in narrow.state['files'] and narrow.stats['cyclesCompleted']==1
    # Clearing a known warning starts a fresh full cycle even when an older
    # successful verification timestamp exists; later passes retain progress.
    recheck_cfg=copy.deepcopy(targeted);recheck_cfg['recheckAfter']={'movies/Example.mkv':int(time.time())}
    prior=copy.deepcopy(good.state);prior['files']['movies/Example.mkv']['verifiedAt']=int(time.time())-100
    recheck=m.Audit(recheck_cfg,prior)
    with contextlib.redirect_stdout(io.StringIO()):recheck.execute()
    assert recheck.stats['cyclesCompleted']==1 and recheck.state['files']['movies/Example.mkv']['verifiedAt']>=recheck_cfg['recheckAfter']['movies/Example.mkv']
    # A long file resumes from a confirmed offset, not its beginning.
    duration=1300;stop_after=1;calls=0
    partial=execute(state);e=partial.state['files']['movies/Example.mkv']
    assert e['offset']==600 and not e['verifiedAt']
    stop_after=0;calls=0;continued=execute(partial.state)
    assert continued.stats['cyclesCompleted']==1 and calls==2
    # Missing metadata/probe success alone is not proof of decode health.
    duration=10;fail=True;calls=0
    broken=execute(state);issue=broken.state['files']['movies/Example.mkv']['issue']
    assert issue['confirmed'] and issue['kind']=='decode_error' and calls==2
    assert broken.state['files']['movies/Example.mkv']['offset']==0
    assert issue['confirmedRuns']==1
    # Stale confirmed failures can be refreshed at the recorded failing range
    # even while ordinary seven-day error backoff remains set.
    refresh_cfg=copy.deepcopy(cfg);refresh_cfg.update(targeted=True,recoveryPriority=['movies/Example.mkv'],evidencePaths=['movies/Example.mkv'])
    stale=copy.deepcopy(broken.state);stale['files']['movies/Example.mkv']['issue']['lastSeen']=int(time.time())-3*86400
    refreshed=m.Audit(refresh_cfg,stale)
    with contextlib.redirect_stdout(io.StringIO()):refreshed.execute()
    assert refreshed.state['files']['movies/Example.mkv']['issue']['lastSeen']>=int(time.time())-5
    assert refreshed.stats['targeted'] and refreshed.found=={'movies/Example.mkv'}
    # Same-invocation decoder repeats are not independent weekly observations.
    again=m.Audit(cfg,copy.deepcopy(broken.state));again.runEpoch=issue['lastConfirmedRunAt']
    e=again.state['files']['movies/Example.mkv']
    again.issue('movies/Example.mkv',e,'decode_error','fixture',confirmed=True)
    assert e['issue']['confirmedRuns']==1
    again.runEpoch+=60
    again.issue('movies/Example.mkv',e,'decode_error','fixture',confirmed=True)
    assert e['issue']['confirmedRuns']==2
    upgraded=dict(cfg,toolset='different decoder runtime')
    reset=m.Audit(upgraded,copy.deepcopy(broken.state))
    assert not reset.state['files']['movies/Example.mkv']['issue']['confirmed']
    assert reset.state['files']['movies/Example.mkv']['issue']['confirmedRuns']==0
    fail=False;timeout=True;slow=execute(state);entry=slow.state['files']['movies/Example.mkv']
    assert not entry['issue']['confirmed'] and entry['issue']['kind']=='unverified_timeout' and entry['offset']==0
    timeout=False
    # Two clean same-range rechecks resolve a prior issue; one is not sufficient.
    recovering=copy.deepcopy(broken.state);recovering['files']['movies/Example.mkv']['notBefore']=0
    fixed=execute(recovering)
    assert not fixed.state['files']['movies/Example.mkv'].get('issue') and fixed.state['resolved']
    # A source changed during decoding never receives range credit.
    change=True;changed=execute(state);assert not changed.state['files']['movies/Example.mkv']['verifiedAt']
    assert changed.state['files']['movies/Example.mkv']['offset']==0
    change=False
    # Changed identities invalidate the previous pass before any new decode.
    inventory_cfg=copy.deepcopy(cfg);inventory_cfg['mode']='inventory'
    audit=m.Audit(inventory_cfg,copy.deepcopy(good.state))
    with contextlib.redirect_stdout(io.StringIO()):audit.execute()
    assert audit.state['files']['movies/Example.mkv']['verifiedAt']==0
    # Symlinked payloads cannot redirect the verifier outside its scope.
    (path/'series'/'linked.mkv').symlink_to(video)
    audit=m.Audit(inventory_cfg,copy.deepcopy(state))
    with contextlib.redirect_stdout(io.StringIO()):audit.execute()
    assert audit.stats['symlinksSkipped']==1 and 'series/linked.mkv' not in audit.state['files']
    bad=copy.deepcopy(state);bad['files']['../escape.mkv']={'identity':[1,2,3,4,5]}
    try:m.validate_state(bad,cfg);raise AssertionError('unsafe state accepted')
    except ValueError:pass
    assert m.classify(dict(code=1,stop='',err='Unknown decoder hevc'))=='unverified_tool_or_resource'
    print('Read-only scope, probe/decode separation, range resume, repeatable errors, timeout classification, recovery and changing-file fixtures passed')

    large=copy.deepcopy(state);large['padding']=os.urandom(180000).hex()
    audit=m.Audit(cfg,large);capture=io.StringIO()
    with contextlib.redirect_stdout(capture):audit.checkpoint(True)
    events=[json.loads(line) for line in capture.getvalue().splitlines()]
    assert events[0]['type']=='checkpoint-begin' and events[-1]['type']=='checkpoint-end'
    assert max(map(len,capture.getvalue().splitlines()))<70000
    payload=''.join(e['data'] for e in events if e['type']=='checkpoint-chunk')
    assert json.loads(gzip.decompress(base64.b64decode(payload)))['padding']==large['padding']
    print('Large state transport uses bounded lines and lossless file-backed chunks')
