"""Embed read-only host modules; deployed User Scripts remain standalone."""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
for name in ['health_monitoring','syslog_watchdog']:
 p=root/'user_script'/f'{name}.sh';s=p.read_text()
 for label,file in [('HOST HEALTH COMMON','host_health_common.sh')]+([('HOST HEALTH PROBES','host_health_probes.sh')] if name=='syslog_watchdog' else [('DISK HOST HEALTH','disk_host_health.sh')]):
  block=f'# BEGIN {label}\n'+(root/'tools'/file).read_text()+f'# END {label}\n'
  pattern=f'# BEGIN {label}\\n.*?# END {label}\\n'
  if re.search(pattern,s,re.S):s=re.sub(pattern,lambda _:block,s,flags=re.S)
  else:
   index=s.index('\nmain() {')
   s=s[:index]+'\n'+block+s[index:]
 p.write_text(s)
