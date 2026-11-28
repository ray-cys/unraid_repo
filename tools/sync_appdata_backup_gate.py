"""Embed the shared runtime validator in standalone media scripts; no host helper install."""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
block='# BEGIN APPDATA BACKUP DEFERRAL\n'+(root/'tools/appdata_backup_gate.sh').read_text()+'# END APPDATA BACKUP DEFERRAL'
for name in ('media_health_monitor','media_metadata_audit'):
    path=root/'user_script'/f'{name}.sh'
    text,count=re.subn(r'# BEGIN APPDATA BACKUP DEFERRAL\n.*?# END APPDATA BACKUP DEFERRAL',lambda _:block,path.read_text(),flags=re.S)
    assert count==1, name
    path.write_text(text)
