"""Keep standalone scripts on one log/notification contract; no runtime imports."""
from pathlib import Path
import re
import argparse
from shell_module import project_module
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--only', nargs='+', help='Regenerate only these script names')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
contract = (root / 'tools/operations_contract.sh').read_text()
budget = (root / 'tools/media_action_budget.sh').read_text()
for path in (root / 'user_script').glob('*.sh'):
    if args.only and path.stem not in args.only:
        continue
    text = path.read_text()
    match = re.search(r'# BEGIN EMBEDDED OPERATIONS CONTRACT\n(OPS_SCRIPT_ID=[^\n]*\n).*?# END EMBEDDED OPERATIONS CONTRACT\n', text, re.S)
    if not match:
        continue
    rendered = contract
    if path.stem in ('host_health_monitor', 'host_health_watchdog'):
        host_contract = re.sub(r'^    usr_ops_delivery_record .*\n', '', contract, flags=re.M)
        callers = text[:match.start()] + text[match.end():]
        rendered = project_module(host_contract, callers, '# shellcheck shell=bash\n# Shared operational logs, notifications and execution receipts.')
    replacement = '# BEGIN EMBEDDED OPERATIONS CONTRACT\n' + match[1] + rendered + '# END EMBEDDED OPERATIONS CONTRACT\n'
    text = text[:match.start()] + replacement + text[match.end():]
    if path.stem in ('media_health_monitor', 'media_integrity_audit'):
        start = text.index('# Shared new-action budget.')
        end = text.index('\n)', text.index('usr_ops_arr_release_undispatched() (', start)) + 2
        text = text[:start] + budget.rstrip('\n') + '\n' + text[end:].lstrip('\n')
    path.write_text(text)
