"""Embed read-only host modules; deployed User Scripts remain standalone."""
from pathlib import Path
import re
from shell_module import project_module
root=Path(__file__).resolve().parents[1]
for name in ['host_health_monitor','host_health_watchdog']:
 p=root/'user_script'/f'{name}.sh';s=p.read_text()
 for label,file in [('HOST HEALTH COMMON','host_health_common.sh')]+([('HOST HEALTH PROBES','host_health_probes.sh')] if name=='host_health_watchdog' else [('DISK HOST HEALTH','disk_host_health.sh')]):
  source=(root/'tools'/file).read_text()
  if name=='host_health_watchdog' and label=='HOST HEALTH COMMON':
   callers=re.sub(r'# BEGIN HOST HEALTH COMMON\n.*?# END HOST HEALTH COMMON\n','',s,flags=re.S)
   prefix=source[:source.index('hh_mount_info() {')]
   source=project_module(source,callers,prefix)
  block=f'# BEGIN {label}\n'+source+f'# END {label}\n'
  pattern=f'# BEGIN {label}\\n.*?# END {label}\\n'
  if re.search(pattern,s,re.S):s=re.sub(pattern,lambda _:block,s,flags=re.S)
  else:
   index=s.index('\nmain() {')
   s=s[:index]+'\n'+block+s[index:]
 p.write_text(s)
