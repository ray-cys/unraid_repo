"""Independent decoder evidence: no actual Docker, Arr or media mutations."""
import copy, contextlib, io, json, os, tempfile, types
from pathlib import Path
source=(Path(__file__).resolve().parents[1]/'user_script/media_integrity_audit.sh').read_text().split("<<'PYWORKER'\n",1)[1].split('\nPYWORKER\n',1)[0]
m=types.ModuleType('worker');exec(compile(source,'worker','exec'),m.__dict__)
def result(code=0,err='',length=10):
    return dict(code=code,err=err,out=f'frame=100\nout_time_us={int(length*1000000)}\n',stop='',wall=.01)
for code in (-9,-11,137,139):
    assert m.classify(result(code,'Invalid NAL unit, error while decoding'))=='unverified_process_exit'
for message in ('Error muxing a packet; Invalid NAL unit','Non-monotonous DTS; corrupt input','Error while filtering; invalid data'):
    assert m.classify(result(1,message))=='unverified_pipeline_error'
    assert m.classify(result(0,message))=='unverified_pipeline_error'
assert m.classify(result(1,'Invalid data found when processing input'))=='unverified_tool_error'
with tempfile.TemporaryDirectory() as folder:
    root=Path(folder).resolve();(root/'movies').mkdir();(root/'movies/a.mkv').write_bytes(b'fixture')
    cfg=dict(root=str(root),hostRoot='/mnt/user/media',libraries=['movies'],mode='scan',budgetSeconds=180,maxStateBytes=67108864,segmentSeconds=600,segmentWallSeconds=60,fileSliceSeconds=90,recheckDays=180,settleSeconds=0,threads=2,memoryMiB=2048,toolset='fixture')
    mode='recoverable';calls=[]
    def run(args,fd,seconds,beat,memory):
        calls.append(args)
        if args[0]=='ffprobe':
            streams=[dict(index=0,codec_type='video',codec_name='h264',disposition={'default':1}),dict(index=1,codec_type='audio',codec_name='aac',disposition={'default':1}),dict(index=2,codec_type='audio',codec_name='aac',disposition={'default':0})]
            return dict(result(),out=json.dumps(dict(format={'duration':1300},streams=streams)))
        length=float(args[args.index('-t')+1]);normal='-xerror' not in args
        if not normal:return result(1,'Invalid NAL unit, error while decoding',length)
        assert '-max_error_rate' not in args
        stream=int(args[args.index('-map')+1].split(':')[1])
        if mode=='signal':return result(-9,'Invalid NAL unit',length)
        if mode=='short':return result(0,'',1)
        if mode=='auxiliary' and stream==2:return result(1,'Invalid NAL unit, error while decoding',length)
        if mode=='primary' and stream==0:return result(1,'Invalid NAL unit, error while decoding',length)
        if mode=='output':return result(1,'Error muxing a packet; Invalid NAL unit',length)
        return result(0,'Invalid NAL unit recovered' if mode=='recoverable' else '',length)
    m.run_process=run
    def audit_run(state=None,run_epoch=100):
        m.STOP='';a=m.Audit(cfg,copy.deepcopy(state or {'schema':1,'files':{}}));a.runEpoch=run_epoch
        with contextlib.redirect_stdout(io.StringIO()):a.inventory()
        e=a.state['files']['movies/a.mkv'];fd=a.open_file('movies/a.mkv',e)
        try:
            assert a.probe('movies/a.mkv',e,fd)
            e['offset']=600
            outcome=a.segment('movies/a.mkv',e,fd)
            return a,e,outcome
        finally:os.close(fd)
    a,e,_=audit_run();assert e['issue']['kind']=='recoverable_media_defect' and not e['issue']['confirmed'] and e['offset']==600
    assert len(e['issue']['streamEvidence'])==3
    normal=[v for v in calls if v[0]=='ffmpeg' and '-xerror' not in v]
    assert all(float(v[v.index('-ss')+1])==480 for v in normal)
    mode='auxiliary';a,e,_=audit_run();assert e['issue']['kind']=='auxiliary_track_error' and not e['issue']['confirmed']
    assert [v['index'] for v in e['issue']['streamEvidence'] if v['kind']=='decode_error']==[2]
    mode='primary';a,e,_=audit_run();assert e['issue']['confirmed'] and e['issue']['confirmedRuns']==1 and e['issue']['proofVersion']==3
    a2,e2,_=audit_run(a.state,run_epoch=100);assert e2['issue']['confirmedRuns']==1
    a3,e3,_=audit_run(a2.state,run_epoch=200);assert e3['issue']['confirmedRuns']==2
    assert e3['issue']['confirmationMethod']=='normal-isolated-streams-v1'
    for mode in ('signal','short','output'):
        a,e,_=audit_run();assert not e['issue']['confirmed'] and e['issue']['kind']=='unverified_stream_confirmation'
    # Confirmation is bounded; insufficient budget never yields replacement proof.
    mode='primary';a=m.Audit(cfg,{'schema':1,'files':{}})
    with contextlib.redirect_stdout(io.StringIO()):a.inventory()
    e=a.state['files']['movies/a.mkv'];fd=a.open_file('movies/a.mkv',e)
    try:
        assert a.probe('movies/a.mkv',e,fd)
        a.deadline=m.time.monotonic()+4
        kind,details,key=a.normal_confirmation('movies/a.mkv',e,fd,calls[-2],600,600)
        assert kind=='unverified_confirmation_budget' and key is None
    finally:os.close(fd)
print('Signal/output exclusions, independent normal decoding, stream isolation, auxiliary veto, partial/budget veto and two-run proof passed')

# Bounded transient retry and persistent-notification eligibility are separate
# from independent corruption confirmations.
with tempfile.TemporaryDirectory() as folder:
    root=Path(folder).resolve();cfg['root']=str(root)
    a=m.Audit(cfg,{'schema':1,'files':{}});a.runEpoch=100
    e={'identity':['1','2','3','4','5'],'chunkSeconds':600}
    a.issue('movies/a.mkv',e,'unverified_timeout','timeout',0)
    assert not e['issue']['alertable'] and a.retry_transient(e) and not a.retry_transient(e)
    a.issue('movies/a.mkv',e,'unverified_timeout','timeout',0)
    assert not e['issue']['alertable'] and e['issue']['observationRuns']==1
    a.runEpoch=200;a.issue('movies/a.mkv',e,'unverified_timeout','timeout',0)
    assert e['issue']['alertable'] and e['issue']['observationRuns']==2
    a.issue('movies/a.mkv',e,'read_error','EIO',0)
    assert e['issue']['alertable'] and not a.retry_transient(e)

assert m.classify(result(1,'[mpeg4 @ 0x123] header damaged'),codecs=['mpeg4'])=='decode_error'
assert m.classify(result(1,'[other @ 0x123] header damaged'),codecs=['mpeg4'])=='unverified_tool_error'
assert m.classify(result(0,'[mpeg4 @ 0x123] header damaged'),codecs=['mpeg4'])=='unverified_decoder_warning'
