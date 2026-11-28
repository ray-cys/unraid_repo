"""Embed shared health coordination; standalone deployments need no helper files."""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
block='# BEGIN HOST HEALTH COORDINATION\n'+(root/'tools/host_health_coordination.sh').read_text()+'# END HOST HEALTH COORDINATION\n'
for name in ('host_health_monitor','host_health_watchdog'):
 p=root/'user_script'/f'{name}.sh';s=p.read_text()
 pattern=r'# BEGIN HOST HEALTH COORDINATION\n.*?# END HOST HEALTH COORDINATION\n'
 if re.search(pattern,s,re.S):s=re.sub(pattern,lambda _:block,s,flags=re.S)
 else:s=s.replace('\nmain() {','\n'+block+'\nmain() {',1)
 p.write_text(s)
