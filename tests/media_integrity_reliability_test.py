"""Duration, incident-range, recovery-speed, signature and capacity regressions."""
import contextlib,copy,io,json,os,tempfile,types,time
from pathlib import Path
source=(Path(__file__).resolve().parents[1]/'user_script/media_integrity_audit.sh').read_text().split("<<'PYWORKER'\n",1)[1].split('\nPYWORKER\n',1)[0]
m=types.ModuleType('reliability');exec(compile(source,'worker','exec'),m.__dict__)
def result(seconds):return dict(code=0,out=f'frame=100\nout_time_us={int(seconds*1000000)}\n',err='',stop='',wall=.01)
assert not m.complete_progress(result(.04),8)
assert not m.complete_progress(result(.01),1)
assert m.complete_progress(result(7.96),8)
assert m.failure_signature('[h264 @ 0x123] Invalid NAL 4\nLast message repeated 3 times\nerror while decoding')==m.failure_signature('error while decoding\n[h264 @ 0x456] Invalid NAL 4\n[h264 @ 0x456] Invalid NAL 4')
assert m.failure_signature('Invalid NAL 4')!=m.failure_signature('Invalid NAL 5')
with tempfile.TemporaryDirectory() as folder:
 root=Path(folder).resolve();(root/'movies').mkdir();(root/'movies/file.mkv').write_bytes(b'fixture')
 cfg=dict(root=str(root),hostRoot='/mnt/user/media',libraries=['movies'],mode='scan',budgetSeconds=120,maxStateBytes=67108864,segmentSeconds=600,segmentWallSeconds=30,fileSliceSeconds=90,recheckDays=180,settleSeconds=0,threads=2,memoryMiB=2048,toolset='fixture')
 a=m.Audit(cfg,{'schema':1,'files':{}})
 with contextlib.redirect_stdout(io.StringIO()):a.inventory()
 e=a.state['files']['movies/file.mkv'];e.update(duration=600,video=[0],audio=[],probeAt=1,chunkSeconds=15)
 fd=a.open_file('movies/file.mkv',e)
 a.active_stage='decode';a.active_range={'start':0,'end':600}
 a.issue('movies/file.mkv',e,'decode_error','Invalid NAL unit',0,True,'key')
 original=copy.deepcopy(e['issue'])
 a.active_range={'start':0,'end':15};a.issue('movies/file.mkv',e,'unverified_timeout','timeout',0)
 assert e['issue']==original and e['auditIssue']['kind']=='unverified_timeout'
 def healthy(args,fd,seconds):return result(float(args[args.index('-t')+1]))
 a.run_tool=healthy
 try:
  a.segment('movies/file.mkv',e,fd);a.segment('movies/file.mkv',e,fd)
  assert e['issue']['kind']=='decode_error' and e['issue']['cleanRechecks']==0 and not e.get('verifiedAt')
  # Smaller clean checks eventually cover the original full interval twice.
  for _ in range(100):
   a.segment('movies/file.mkv',e,fd)
   if not e.get('issue') and not e.get('auditIssue'):break
  assert not e.get('issue') and not e.get('auditIssue') and e['verifiedAt']>0
  assert any('entire original failed interval' in v['resolution'] for v in a.state['resolved'])
  # A temporary reduction is not permanent; restore size after three clean passes.
  e.update(duration=10000,verifiedAt=0,offset=0,chunkSeconds=15,healthyRangeStreak=0)
  for _ in range(3):a.segment('movies/file.mkv',e,fd)
  assert e['chunkSeconds']==30
  # Metadata-only resource limitations close on a successful probe, not media defects.
  a.active_stage='probe';a.issue('movies/file.mkv',e,'unverified_timeout','probe timeout')
  a.run_tool=lambda args,fd,seconds:dict(result(0),out=json.dumps({'format':{'duration':10000},'streams':[{'index':0,'codec_type':'video','codec_name':'h264'}]}))
  assert a.probe('movies/file.mkv',e,fd) and not e.get('issue')
 finally:os.close(fd)
 # Old short-range proof is not silently grandfathered, but probes are retained.
 old=copy.deepcopy(a.state);old_e=old['files']['movies/file.mkv'];old_e.update(verifiedAt=100,coverage='all_planned_segments_decoded',verificationPolicy=1,offset=0)
 migrated=m.Audit(cfg,old);assert migrated.state['files']['movies/file.mkv']['verifiedAt']==0 and migrated.state['files']['movies/file.mkv']['probeAt']>0
 # Estimates need three representative scheduled runs; unknown duration stays explicit.
 e.update(duration=1000000,verifiedAt=0,offset=0)
 a.state['capacityRuns']=[{'budgetSeconds':7200,'inventoryComplete':True,'netMediaSeconds':100} for _ in range(3)]
 a.capacity_metrics();assert a.state['capacity']['status']=='behind_target' and a.state['capacity']['attention']
 a.state['capacityRuns']=[{'budgetSeconds':120,'inventoryComplete':True,'netMediaSeconds':1000000} for _ in range(3)]
 a.capacity_metrics();assert a.state['capacity']['status']=='collecting' and not a.state['capacity']['attention']
print('Short-tail proof, exact full-range recovery, separate limitations, adaptive growth, legacy invalidation, canonical signatures and measured capacity passed')
