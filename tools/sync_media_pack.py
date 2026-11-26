"""Embed bounded pack helpers; standalone scripts require no new runtime files."""
from pathlib import Path
R=Path(__file__).resolve().parents[1]
contract=(R/'tools/media_pack_contract.sh').read_text()
worker=(R/'tools/media_pack_inventory.py').read_text()
shared=contract+'\npack_inventory_program() {\n    cat <<\'PACKPY\'\n'+worker.rstrip()+'\nPACKPY\n}\n'
for name in ['media_health_monitor','media_cleanup']:
 p=R/'user_script'/f'{name}.sh';s=p.read_text()
 def embed(text,label,code,before):
  start='# BEGIN '+label+'\n';end='# END '+label+'\n';block=start+code.rstrip()+'\n'+end
  if start in text:
   a=text.index(start);b=text.index(end,a)+len(end);return text[:a]+block+text[b:]
  at=text.index(before);return text[:at]+block+'\n'+text[at:]
 s=embed(s,'EMBEDDED MEDIA PACK CONTRACT',shared,'# MODULE: ARR' if name=='media_cleanup' else 'automation_document_valid() {')
 code=(R/'tools'/('media_pack_monitor.sh' if name=='media_health_monitor' else 'media_pack_cleanup.sh')).read_text()
 s=embed(s,'EMBEDDED MEDIA PACK ENGINE',code,'process_arr_automation() {' if name=='media_health_monitor' else 'process_completed_jobs() {')
 p.write_text(s)
