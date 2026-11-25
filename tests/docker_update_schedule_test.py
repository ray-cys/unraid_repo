"""Native schedule parsing fixtures; no Docker or application writes."""
import contextlib, io, json, os, sys, types, unittest
from pathlib import Path
from unittest.mock import patch
SOURCE=(Path(__file__).resolve().parents[1]/'user_script/docker_service_watchdog.sh').read_text().split('container_update_schedule() {',1)[1]
def program(tag):return compile(SOURCE.split("<<'"+tag+"'\n",1)[1].split('\n'+tag,1)[0],tag,'exec')
class NativeSchedules(unittest.TestCase):
    def native(self,name,env,config=None):
        out=io.StringIO();yaml=types.ModuleType('yaml');yaml.safe_load=json.loads
        with patch.dict(os.environ,env,clear=True),patch.object(sys,'argv',['-',name]),patch.dict(sys.modules,{'yaml':yaml}),patch.object(Path,'read_text',return_value=json.dumps(config or {})),contextlib.redirect_stdout(out):
            exec(program('PYSCHEDULE'),{})
        return json.loads(out.getvalue())
    def test_kometa_utc_and_invalid_one_shot(self):
        value=self.native('kometa',{'TZ':'UTC','KOMETA_TIME':'00:00, 04:00, 12:00','KOMETA_RUN':'false'})
        self.assertTrue(value['verified']);self.assertEqual(value['events'][2]['cron'],'0 12 * * *');self.assertEqual(value['events'][0]['timezone'],'UTC')
        self.assertFalse(self.native('kometa',{'KOMETA_RUN':'true','KOMETA_TIME':'12:00'})['verified'])
        self.assertFalse(self.native('kometa',{'KOMETA_TIME':'25:00'})['verified'])
    def test_imagemaid_modes_and_weekdays(self):
        value=self.native('imagemaid',{'TZ':'Asia/Singapore','SCHEDULE':'06:30|weekly(wednesday)|mode=clear,07:00|weekly(sunday)|mode=move'})
        self.assertTrue(value['verified']);self.assertEqual([v['cron'] for v in value['events']],['30 6 * * 3','0 7 * * 0'])
        self.assertFalse(self.native('imagemaid',{'SCHEDULE':'07:00|weekly(blursday)'})['verified'])
    def test_metafusion_current_owner_config(self):
        value=self.native('metafusion',{'TZ':'Asia/Singapore'},{'settings':{'schedule':True,'run_times':['11:35','15:35','23:35']}})
        self.assertTrue(value['verified']);self.assertEqual(len(value['events']),3)
        self.assertEqual(self.native('metafusion',{}, {'settings':{'schedule':False}})['events'],[])
    def test_sab_enabled_rules_only(self):
        fake=types.ModuleType('configobj');fake.ConfigObj=lambda *a,**k:{'misc':{'schedlines':['1 30 15 1234567 resume_post','0 20 15 1234567 resume_post','1 0 16 1234567 pause_post','1 32 17 1357 create_backup']}}
        out=io.StringIO()
        with patch.dict(sys.modules,{'configobj':fake}),patch.dict(os.environ,{'TZ':'Asia/Singapore'},clear=True),contextlib.redirect_stdout(out):exec(program('PYSAB'),{})
        value=json.loads(out.getvalue());self.assertTrue(value['verified']);self.assertEqual(len(value['events']),3);self.assertEqual(value['events'][0]['cron'],'30 15 * * 1,2,3,4,5,6,0')
if __name__=='__main__':unittest.main()
