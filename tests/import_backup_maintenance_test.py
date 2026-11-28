"""Proof import fixtures: receipt, completed log and exact native timestamps must agree."""
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
from zoneinfo import ZoneInfo
root=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('windows',root/'tools/import_backup_maintenance.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
start=1795833969;boot='fixture'
receipt=dict(schema=1,name='backup_cache_appdata',executionStatus='COMPLETED',lastExitCode=0,boot=boot,startedAt=start,finishedAt=start+300)
def iso(t):return datetime.fromtimestamp(t,timezone.utc).isoformat().replace('+00:00','Z')
def line(t,message):return datetime.fromtimestamp(t,ZoneInfo('Asia/Singapore')).strftime('%Y-%m-%d %H:%M:%S')+' | INFO | backup_cache_appdata | run=fixture | phase=DOCKER | '+message
containers=[dict(Id='id',Name='/plex-media-server',State=dict(Running=True,FinishedAt=iso(start+50),StartedAt=iso(start+200)))]
log='\n'.join([line(start,'Scheduled appdata backup started'),line(start+50,'[plex] Stopped owning container: plex-media-server'),line(start+206,'Container started: plex-media-server; readiness result=0; stop-to-startup-check elapsed=156s'),line(start+290,'Appdata backup verified and finalized: /fixture')])
found=m.windows(receipt,containers,log,boot,start+310)
assert len(found)==1
row=next(iter(found.values()));assert row['startedAt']==start+50 and row['endedAt']==start+200
assert not m.windows(receipt,containers,log.replace('Stopped owning container','Unproven stop'),boot,start+310)
changed=[dict(containers[0],State=dict(containers[0]['State'],StartedAt=iso(start+400)))]
assert not m.windows(receipt,changed,log,boot,start+500)
for invalid in (dict(receipt,lastExitCode=1),dict(receipt,boot='old'),dict(receipt,executionStatus='RUNNING')):
 try:m.windows(invalid,containers,log,boot,start+310)
 except ValueError:pass
 else:raise AssertionError('Invalid producer receipt accepted')
assert m.epoch('2026-11-28T02:55:48.23382069Z')==1795834548
print('Exact producer/log/native-Docker proof accepted; missing, changed, failed and other-boot evidence rejected')
