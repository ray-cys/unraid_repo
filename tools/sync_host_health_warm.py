"""Embed warm-run helpers in the standalone daily health monitor."""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
p=root/'user_script/host_health_monitor.sh'
block='# BEGIN WARM RUN EVIDENCE\n'+(root/'tools/host_health_warm_run.sh').read_text()+'# END WARM RUN EVIDENCE'
s,n=re.subn(r'# BEGIN WARM RUN EVIDENCE\n.*?# END WARM RUN EVIDENCE',lambda _:block,p.read_text(),flags=re.S)
assert n==1
p.write_text(s)
