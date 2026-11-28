"""Check standalone helper projection, current-purpose coverage and no-op removal."""
from pathlib import Path
import json
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tools'))
from shell_module import functions, project_module

fixture = """# Fixture.
entry() {
    cat <<'PAYLOAD'
}
fake() {
}
PAYLOAD
    worker
}
worker() (
    cat <<-END
\t)
\tEND
)
unused() {
    exit 99
}
"""
kept = project_module(fixture, 'entry', '# Fixture.')
assert set(functions(kept)) == {'entry', 'worker'}
for name, body in functions(kept).items():
    assert body == functions(fixture)[name]
try:
    project_module(fixture + 'unexpected=1\n', 'entry', '# Fixture.')
except ValueError:
    pass
else:
    raise AssertionError('Executable top-level content was discarded')

inventory = json.loads((root / 'user_script/versions.json').read_text())['scripts']
purposes = json.loads((root / 'tools/user_script_purposes.json').read_text())
assert set(inventory) == set(purposes)
for name in inventory:
    code = (root / 'user_script' / f'{name}.sh').read_text()
    assert code.count('# BEGIN CURRENT OPERATIONAL PURPOSE') == 1
    for label in ('PURPOSE', 'WORKFLOW', 'COORDINATION', 'LIMITS', 'REPORTING'):
        assert '# ' + label + ':' in code, (name, label)
    assert (root / 'user_script/descriptions' / f'{name}.txt').is_file()
    for kind in ('OPERATIONS CONTRACT', 'USER SCRIPTS CATALOG'):
        match = re.search(r'# BEGIN EMBEDDED ' + kind + r'\n(.*?)# END EMBEDDED ' + kind, code, re.S)
        if not match:
            continue
        source = match[1]
        bodies = functions(source)
        shared = (root / 'tools' / ('operations_contract.sh' if kind == 'OPERATIONS CONTRACT' else 'user_scripts_catalog.sh')).read_text()
        originals = functions(shared)
        for helper, body in bodies.items():
            expected = originals[helper]
            if helper == 'usr_ops_notify' and 'usr_ops_delivery_record' not in bodies:
                expected = re.sub(r'^    usr_ops_delivery_record .*\n', '', expected, flags=re.M)
            assert body == expected, (name, helper, 'shared implementation drift')
        callers = code[:match.start()] + code[match.end():]
        # Every retained helper must be reachable, even via a quoted dispatch name.
        reachable = project_module(source, callers, '\n'.join(
            line for line in source.splitlines() if line.startswith('OPS_SCRIPT_ID=')))
        assert set(functions(reachable)) == set(bodies), (name, kind)
        prefixes = r'\busr_ops_[A-Za-z0-9_]+\b' if kind == 'OPERATIONS CONTRACT' else r'\busr_scripts_[A-Za-z0-9_]+\b'
        referenced = set(re.findall(prefixes, code))
        declared = set(re.findall(r'^((?:usr_ops_|usr_scripts_)[A-Za-z0-9_]+)\(\)', code, re.M))
        assert referenced <= declared, (name, referenced - declared)
    assert 'RELEASE HISTORY' not in code
print('All 18 scripts have current-purpose documentation, descriptions and reachable standalone helpers; heredoc payloads remain intact')
