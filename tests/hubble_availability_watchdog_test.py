"""Pure observer fixtures: no network, email, cron or production-state writes."""
from pathlib import Path
import copy, unittest, tempfile, os
ROOT=Path(__file__).resolve().parents[1]
code=(ROOT/'external_scripts/hubble_availability_watchdog.sh').read_text().split('# BEGIN EXTERNAL WATCHDOG PYTHON\n',1)[1].split('# END EXTERNAL WATCHDOG PYTHON',1)[0]
w={'__name__':'fixture'};exec(compile(code,'external-watchdog','exec'),w)
class ObserverTests(unittest.TestCase):
 def setUp(self):
  self.state=w['initial_state']();self.now=1000000;self.mono=1000
  self.host={'bootId':'a','uptimeSeconds':20000}
 def sample(self,result='ok',host=True,**kw):
  self.now+=120;self.mono+=120
  o={'availability':{'result':result,'severity':'CRITICAL','detail':result+' evidence'}}
  self.state=w['reconcile'](self.state,o,self.host if host else None,self.now,'pi-boot',self.mono)
  return self.state
 def test_failure_requires_three(self):
  self.sample('bad');self.sample('bad');self.assertFalse(self.state['pending'])
  self.sample('bad');self.assertEqual(self.state['pending']['availability']['kind'],'RAISED')
 def test_unknown_does_not_resolve(self):
  for _ in range(3):self.sample('bad')
  self.sample('unknown');self.assertTrue(self.state['conditions']['availability']['active'])
 def test_recovery_two_samples_and_pending_event(self):
  for _ in range(3):self.sample('bad')
  self.sample();self.assertTrue(self.state['conditions']['availability']['active'])
  self.sample();self.assertEqual(self.state['pending']['availability']['kind'],'RECOVERED BEFORE DELIVERY')
 def test_delivered_recovery(self):
  for _ in range(3):self.sample('bad')
  self.state['pending']={};self.state['conditions']['availability']['lastNotifiedAt']=self.now
  self.sample();self.sample();self.assertEqual(self.state['pending']['availability']['kind'],'RECOVERED')
 def test_healthy_quiet(self):
  for _ in range(5):self.sample()
  self.assertFalse(self.state['pending'])
 def test_reboot_observed_once(self):
  self.sample();self.host['bootId']='b';self.sample();self.assertIn('reboot',self.state['pending'])
  self.state['pending']={};self.sample();self.assertFalse(self.state['pending'])
 def test_timed_maintenance(self):
  self.state['maintenance']={'until':self.now+600}
  for _ in range(3):self.sample('bad')
  self.assertFalse(self.state['pending'])
  for _ in range(3):self.sample('bad')
  self.assertEqual(self.state['pending']['availability']['kind'],'RAISED')
 def test_old_active_not_erased_by_maintenance(self):
  for _ in range(3):self.sample('bad')
  self.state['maintenance']={'until':self.now+600};self.sample('bad')
  self.assertTrue(self.state['conditions']['availability']['active'])
 def test_gap_breaks_confirmation(self):
  self.sample('bad');self.sample('bad');self.mono+=1000;self.now+=1000;self.sample('bad')
  self.assertFalse(self.state['pending'])
 def test_unknown_breaks_confirmation(self):
  self.sample('bad');self.sample('bad');self.sample('unknown');self.sample('bad')
  self.assertFalse(self.state['pending'])
 def test_pi_boot_preserves_incident_not_counters(self):
  for _ in range(3):self.sample('bad')
  self.state=w['reconcile'](self.state,{'availability':{'result':'ok','severity':'CRITICAL','detail':'ok'}},self.host,self.now+120,'new-pi',10)
  self.assertTrue(self.state['conditions']['availability']['active']);self.assertEqual(self.state['conditions']['availability']['good'],1)
 def test_delivery_failure_does_not_consume(self):
  for _ in range(3):self.sample('bad')
  before=copy.deepcopy(self.state['pending']);old=w['run_command'];w['run_command']=lambda *a:(77,'','mail failure')
  try:
   with self.assertRaises(RuntimeError):w['deliver']({'mailBinary':'/none','mailAccount':'default','recipient':'a@b.net','sender':'c@d.net'},self.state,self.now)
  finally:w['run_command']=old
  self.assertEqual(before,self.state['pending'])
 def test_delivery_success_commits_history(self):
  for _ in range(3):self.sample('bad')
  old=w['run_command'];w['run_command']=lambda *a:(0,'','')
  try:w['deliver']({'mailBinary':'/none','mailAccount':'default','recipient':'a@b.net','sender':'c@d.net'},self.state,self.now)
  finally:w['run_command']=old
  self.assertFalse(self.state['pending']);self.assertEqual(len(self.state['history']),1)
 def test_atomic_state_private(self):
  with tempfile.TemporaryDirectory() as d:
   path=Path(d)/'state.json';w['atomic_json'](path,self.state);self.assertEqual(path.stat().st_mode&0o777,0o600)
   target=Path(d)/'target';target.write_text('unchanged');path.unlink();path.symlink_to(target)
   with self.assertRaises(ValueError):w['atomic_json'](path,self.state)
   self.assertEqual(target.read_text(),'unchanged')
 def test_web_only_does_not_claim_host_down(self):
  old=w['run_command'];w['run_command']=lambda args,*a:(255,'','SSH denied') if args[0]=='ssh' else (0,'302','')
  c={'sshBinary':'ssh','curlBinary':'curl','knownHosts':'/none','sshIdentity':'/none','target':'root@192.0.2.1','webUrl':'http://192.0.2.1/','expectedHostname':'Hubble'}
  try:o,host=w['collect'](c,self.now)
  finally:w['run_command']=old
  self.assertIsNone(host);self.assertEqual(o['availability']['result'],'ok');self.assertEqual(o['probe_access']['result'],'bad');self.assertEqual(o['monitor_heartbeat']['result'],'unknown')
 def test_ssh_probe_never_consumes_caller_stdin(self):
  seen=[];old=w['run_command']
  def fake(args,*a):
   seen.append(args);return (255,'','unreachable') if args[0]=='ssh' else (0,'302','')
  w['run_command']=fake
  c={'sshBinary':'ssh','curlBinary':'curl','knownHosts':'/none','sshIdentity':'/none','target':'root@192.0.2.1','webUrl':'http://192.0.2.1/','expectedHostname':'Hubble'}
  try:w['collect'](c,self.now)
  finally:w['run_command']=old
  self.assertIn('-n',seen[0]);self.assertIn('/dev/null',seen[0])
 def test_busy_cli_never_claims_test_email_sent(self):
  import unittest.mock as mock
  with tempfile.TemporaryDirectory() as d:
   c={'lockFile':str(Path(d)/'lock'),'stateDirectory':d}
   with mock.patch.dict(w,{'load_config':lambda p:c}),mock.patch.object(w['fcntl'],'flock',side_effect=BlockingIOError),mock.patch.object(w['time'],'monotonic',side_effect=[0,11]):
    self.assertEqual(w['main'](['--test-email']),75)
 def test_stale_wrong_boot_receipt(self):
  import json
  value={'schema':1,'name':'Hubble','bootId':'12345678-1234-1234-1234-123456789abc','epoch':self.now,'uptimeSeconds':20000,'fastWatchdog':{'status':'COMPLETE','bootId':'old','observedAt':self.now}}
  old=w['run_command'];w['run_command']=lambda args,*a:(0,json.dumps(value),'') if args[0]=='ssh' else (0,'302','')
  c={'sshBinary':'ssh','curlBinary':'curl','knownHosts':'/none','sshIdentity':'/none','target':'root@192.0.2.1','webUrl':'http://192.0.2.1/','expectedHostname':'Hubble'}
  try:o,_=w['collect'](c,self.now)
  finally:w['run_command']=old
  self.assertEqual(o['monitor_heartbeat']['result'],'bad')
if __name__=='__main__':unittest.main()
