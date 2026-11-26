"""Embed one read-only catalogue implementation in standalone User Scripts."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
block='# BEGIN EMBEDDED USER SCRIPTS CATALOG\n'+(root/'tools/user_scripts_catalog.sh').read_text()+'# END EMBEDDED USER SCRIPTS CATALOG\n'
for name in ('system_update_coordinator','docker_service_watchdog','backup_health_audit','backup_restore_drill','backup_vault_remote','media_integrity_audit','media_health_monitor'):
    p=root/'user_script'/f'{name}.sh';text=p.read_text()
    if '# BEGIN EMBEDDED USER SCRIPTS CATALOG\n' in text:
        a=text.index('# BEGIN EMBEDDED USER SCRIPTS CATALOG\n');b=text.index('# END EMBEDDED USER SCRIPTS CATALOG\n',a)+len('# END EMBEDDED USER SCRIPTS CATALOG\n');text=text[:a]+block+text[b:]
    else:text=text.replace('# END EMBEDDED OPERATIONS CONTRACT\n','# END EMBEDDED OPERATIONS CONTRACT\n'+block,1)
    p.write_text(text)
