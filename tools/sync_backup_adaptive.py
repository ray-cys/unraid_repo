"""Embed the backup controller and ephemeral ISS helper into standalone scripts."""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
module=(root/'tools/backup_adaptive.sh').read_text()
remote=(root/'tools/backup_adaptive_remote.sh').read_text()
block='# BEGIN BACKUP ADAPTIVE\n'+module+'\nba_remote_script() {\ncat <<\'BACKUP_ADAPTIVE_REMOTE\'\n'+remote+'BACKUP_ADAPTIVE_REMOTE\n}\n# END BACKUP ADAPTIVE\n'
for name in ('backup_media_remote','backup_vault_remote'):
    p=root/'user_script'/f'{name}.sh';s=p.read_text()
    pattern=r'# BEGIN BACKUP ADAPTIVE\n.*?# END BACKUP ADAPTIVE\n'
    if re.search(pattern,s,re.S):s=re.sub(pattern,lambda _:block,s,flags=re.S)
    else:s=s.replace('\nmain() {','\n'+block+'\nmain() {',1)
    p.write_text(s)
