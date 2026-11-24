"""Read-only native-log and SAB API readiness fixtures; no Docker or app writes."""
import contextlib
import datetime
import io
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
from zoneinfo import ZoneInfo

SOURCE=(Path(__file__).resolve().parents[1]/'user_script/docker_service_watchdog.sh').read_text()
def program(function):
    body=SOURCE.split(function+'() {',1)[1].split("<<'PY'\n",1)[1].split('\nPY\n',1)[0]
    return compile(body, function, 'exec')

class Readiness(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.path=Path(self.temp.name)/'log'
        self.now=datetime.datetime.now(ZoneInfo('Asia/Singapore')).replace(microsecond=0)
    def line(self,message,minutes=0):
        return '['+(self.now+datetime.timedelta(minutes=minutes)).strftime('%Y-%m-%d %H:%M:%S')+',123] [app.py:1] [INFO] | '+message+' |\n'
    def scheduler(self,text,profile='kometa',purpose='update'):
        self.path.write_text(text)
        result=io.StringIO()
        with patch.object(sys,'argv',['-',profile,str(self.path),purpose]),contextlib.redirect_stdout(result):
            exec(program('scheduler_readiness'),{})
        return json.loads(result.getvalue())
    def test_kometa_idle_and_active(self):
        start=self.line('Starting 12:00 Run',-2)
        footer=self.line('Start Time: 12:00:00 Finished: 12:01:00 Run Time: 0:01:00',-1)
        self.assertTrue(self.scheduler(start+footer)['ready'])
        self.assertFalse(self.scheduler(start+self.line('ordinary processing')*6000)['ready'])
        self.assertFalse(self.scheduler(start+footer+self.line('Starting 16:00 Run'))['ready'])
        self.assertFalse(self.scheduler(start+self.line('Finished Blade Runner Collection'))['ready'])
    def test_job_errors_do_not_invent_scheduler_failure(self):
        text=self.line('Validating Options',-3)+self.line('ERROR: one processing item failed',-2)+self.line('ImageMaid Finished',-1)+self.line('Total Runtime | 0:02:01',-1)
        self.assertTrue(self.scheduler(text,'imagemaid')['ready'])
        self.assertFalse(self.scheduler(self.line('Validating Options'),'imagemaid')['ready'])
        self.assertTrue(self.scheduler(self.line('Validating Options'),'imagemaid','health')['ready'])
    def test_malformed_native_log_fails_closed(self):
        with self.assertRaises(AssertionError):self.scheduler('unrecognized content\n')
    def sab(self,queue,history,purpose='update'):
        native=types.ModuleType('configobj')
        native.ConfigObj=lambda *a,**k:{'misc':{'port':8080,'api_key':'fixture-secret'}}
        import urllib.request
        def open_(url,timeout):
            return io.StringIO(json.dumps({'queue':queue} if 'mode=queue' in url else {'history':history}))
        out=io.StringIO()
        with patch.dict(sys.modules,{'configobj':native}),patch.object(sys,'argv',['-',purpose]),patch.object(urllib.request,'urlopen',open_),contextlib.redirect_stdout(out):
            exec(program('sab_readiness'),{})
        self.assertNotIn('fixture-secret',out.getvalue())
        return json.loads(out.getvalue())
    def test_sab_batched_queued_work_remains_eligible(self):
        q={'status':'Paused','slots':[{'status':'Queued'}]}
        self.assertTrue(self.sab(q,{'slots':[{'status':'Completed'}]})['ready'])
        self.assertFalse(self.sab(q,{'slots':[{'status':'Extracting'}]})['ready'])
        self.assertFalse(self.sab({'status':'Downloading','slots':[]},{'slots':[]})['ready'])
        self.assertTrue(self.sab(q,{'slots':[{'status':'Extracting'}]},'health')['ready'])
    def test_sab_malformed_api_fails_closed(self):
        with self.assertRaises(AssertionError):self.sab({'status':'Paused'},{'slots':[]})

if __name__=='__main__':unittest.main()
