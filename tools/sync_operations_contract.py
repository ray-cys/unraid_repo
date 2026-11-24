"""Keep standalone scripts on one log/notification contract; no runtime imports."""
from pathlib import Path
import re
root = Path(__file__).resolve().parents[1]
contract = (root / 'tools/operations_contract.sh').read_text()
budget = (root / 'tools/media_action_budget.sh').read_text()
for path in (root / 'user_script').glob('*.sh'):
    text = path.read_text()
    match = re.search(r'# BEGIN EMBEDDED OPERATIONS CONTRACT\n(OPS_SCRIPT_ID=[^\n]*\n).*?# END EMBEDDED OPERATIONS CONTRACT\n', text, re.S)
    if not match:
        continue
    replacement = '# BEGIN EMBEDDED OPERATIONS CONTRACT\n' + match[1] + contract + '# END EMBEDDED OPERATIONS CONTRACT\n'
    text = text[:match.start()] + replacement + text[match.end():]
    if path.stem in ('media_health_monitor', 'media_integrity_audit'):
        start = text.index('# Shared new-action budget.')
        end = text.index('\n)', text.index('usr_ops_arr_release_undispatched() (', start)) + 2
        text = text[:start] + budget.rstrip('\n') + '\n' + text[end:].lstrip('\n')
    path.write_text(text)
