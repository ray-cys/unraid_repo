"""Embed one read-only catalogue implementation in standalone User Scripts."""
from pathlib import Path
from shell_module import project_module
root=Path(__file__).resolve().parents[1]
source=(root/'tools/user_scripts_catalog.sh').read_text()
for name in ('system_update_coordinator','docker_service_watchdog','backup_health_audit','backup_restore_drill','backup_vault_remote','media_integrity_audit','media_health_monitor'):
    p=root/'user_script'/f'{name}.sh';text=p.read_text()
    if '# BEGIN EMBEDDED USER SCRIPTS CATALOG\n' in text:
        a=text.index('# BEGIN EMBEDDED USER SCRIPTS CATALOG\n');b=text.index('# END EMBEDDED USER SCRIPTS CATALOG\n',a)+len('# END EMBEDDED USER SCRIPTS CATALOG\n')
    else:
        a=text.index('# END EMBEDDED OPERATIONS CONTRACT\n')+len('# END EMBEDDED OPERATIONS CONTRACT\n');b=a
    rendered=project_module(source,text[:a]+text[b:],'# Shared read-only installed User Scripts and native schedule catalogue.')
    block='# BEGIN EMBEDDED USER SCRIPTS CATALOG\n'+rendered+'# END EMBEDDED USER SCRIPTS CATALOG\n'
    text=text[:a]+block+text[b:]
    p.write_text(text)
