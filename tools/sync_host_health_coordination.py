"""Embed shared health coordination; standalone deployments need no helper files."""
from pathlib import Path
import re
from shell_module import project_module
root=Path(__file__).resolve().parents[1]
source=(root/'tools/host_health_coordination.sh').read_text()
for name in ('host_health_monitor','host_health_watchdog'):
 p=root/'user_script'/f'{name}.sh';s=p.read_text()
 pattern=r'# BEGIN HOST HEALTH COORDINATION\n.*?# END HOST HEALTH COORDINATION\n'
 callers=re.sub(pattern,'',s,flags=re.S)
 rendered=project_module(source,callers,'# shellcheck shell=bash\n# Coordinated health evidence; each producer retains incident ownership.')
 block='# BEGIN HOST HEALTH COORDINATION\n'+rendered+'# END HOST HEALTH COORDINATION\n'
 if re.search(pattern,s,re.S):s=re.sub(pattern,lambda _:block,s,flags=re.S)
 else:s=s.replace('\nmain() {','\n'+block+'\nmain() {',1)
 p.write_text(s)
