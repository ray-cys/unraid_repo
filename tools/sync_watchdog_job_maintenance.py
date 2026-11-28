"""Embed bounded maintenance evidence helpers; no runtime host Python dependency."""
from pathlib import Path
r=Path(__file__).resolve().parents[1]
worker=(r/'tools/watchdog_plex_dependency.py').read_text()
shell=(r/'tools/watchdog_job_maintenance.sh').read_text()
a='    # BEGIN EMBEDDED PLEX DEPENDENCY PROBE';b='    # END EMBEDDED PLEX DEPENDENCY PROBE'
shell=shell[:shell.index(a)]+"    docker_cmd exec -i \"$name\" python3 - \"$profile\" \"$mode\" \"$hint\" <<'WD_PLEX_PY'\n"+worker+"WD_PLEX_PY\n"+shell[shell.index(b)+len(b)+1:]
p=r/'user_script/docker_service_watchdog.sh';s=p.read_text()
a='# BEGIN JOB MAINTENANCE CORRELATION';b='# END JOB MAINTENANCE CORRELATION'
block=a+'\n'+shell+b+'\n'
if a in s:s=s[:s.index(a)]+block+s[s.index(b)+len(b)+1:]
else:s=s.replace('\ncheck_job() {','\n'+block+'\ncheck_job() {',1)
p.write_text(s)
