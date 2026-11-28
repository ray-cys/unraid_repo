"""Check conservative code generation and transitive standalone dependencies."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tools'))
from shell_module import functions, project_module

module = '''# Fixture helpers.
entry() {
    selected="worker"
    "$selected"
}
worker() {
    printf '%s' '{"literal":"preserved"}'
    leaf
}
leaf() {
    :
}
unused() {
    exit 99
}
'''
projected = project_module(module, 'entry', '# Fixture helpers.')
assert set(functions(projected)) == {'entry', 'worker', 'leaf'}
for name in functions(projected):
    assert functions(projected)[name] == functions(module)[name]
try:
    project_module('unexpected_global=1\n' + module, 'entry', '# Fixture helpers.')
except ValueError:
    pass
else:
    raise AssertionError('Unpreserved top-level code was silently dropped')
for name in ('host_health_monitor', 'host_health_watchdog'):
    code = (root / 'user_script' / (name + '.sh')).read_text()
    declared = set(re.findall(r'^((?:usr_ops_|hc_|hh_|hm_)[A-Za-z0-9_]+)\(\)', code, re.M))
    referenced = set(re.findall(r'\b(?:usr_ops_|hc_|hh_|hm_)[A-Za-z0-9_]+\b', code))
    assert referenced <= declared, (name, referenced - declared)
    assert not any(re.search(r'^' + removed + r'\(\)', code, re.M) for removed in (
        'usr_ops_observe_shutdown', 'usr_ops_retry_deliveries', 'read_log_all',
        'short_test_is_due', 'forecast_confidence_description', 'format_bytes_per_day'))
print('Conservative generation preserves transitive/dynamic helpers and standalone call dependencies')
