"""Keep current operational purpose headers and the reference guide aligned.

This tool never rewrites the user-owned Unraid UI descriptions or schedules.
"""
from pathlib import Path
import json
import re
import textwrap

root = Path(__file__).resolve().parents[1]
purposes = json.loads((root / 'tools/user_script_purposes.json').read_text())
labels = ('Purpose', 'Workflow', 'Coordination', 'Limits', 'Reporting')
guide = [
    '# Hubble User Scripts: purpose and coordination',
    '',
    'This guide describes the current installed release set. Short Unraid UI descriptions',
    'remain user-owned; the matching operational summaries also appear near the top of',
    'each script. Configuration in the script and current native User Scripts schedules',
    'control behaviour; this guide does not create timers or change policies.',
    '',
    'For commands and their side effects, see [the CLI reference](user-scripts-cli.md).',
    'For release numbers and public code hashes, see [the version inventory](../user_script/versions.json).',
    'Live secret configuration can legitimately make installed hashes differ.',
    '',
    'Backup producers create protection; audits inspect evidence; restore drills sample',
    'restorability. Media monitoring, cleanup, integrity and metadata audits have distinct',
    'ownership and share maintenance/recovery guards. The daily and frequent host monitors',
    'share finding lifecycles. Docker recovery and native updates honour producer leases.',
    '',
    '## Script index',
    '',
]
guide += [f'- [{name}](#{name.replace("_", "-")})' for name in purposes]
for name, fields in purposes.items():
    if len(fields) != len(labels):
        raise ValueError(f'Incomplete purpose definition: {name}')
    header = ['# BEGIN CURRENT OPERATIONAL PURPOSE']
    for label, value in zip(labels, fields):
        header.extend(textwrap.wrap(f'{label.upper()}: {value}', width=96,
                                    initial_indent='# ', subsequent_indent='#   '))
    header += ['# Commands and side effects: docs/user-scripts-cli.md in ray-cys/unraid_repo.',
               '# END CURRENT OPERATIONAL PURPOSE']
    path = root / 'user_script' / f'{name}.sh'
    code = path.read_text()
    code = re.sub(r'^# BEGIN CURRENT OPERATIONAL PURPOSE\n.*?^# END CURRENT OPERATIONAL PURPOSE\n',
                  '', code, flags=re.M | re.S)
    # Preserve the deliberately side-effect-free release lookup as the first code.
    position = code.index('\nfi\n') + len('\nfi\n')
    path.write_text(code[:position] + '\n'.join(header) + '\n' + code[position:])
    guide += ['', f'## {name.replace("_", "-")}', '',
              f'Source: [{name}.sh](../user_script/{name}.sh).', '']
    for label, value in zip(labels, fields):
        guide += [f'**{label}.** {value}', '']
guide += ['## Retained compatibility and archived references', '',
          'Readers for existing state, backup manifests, generation ownership and supported',
          'native interfaces remain when they have active callers. Removing them solely',
          'because their format is older would risk losing recovery evidence. Superseded',
          'standalone scripts remain in GitHub as reference material; they are outside the',
          '18-script installed release inventory and must not be scheduled alongside their',
          'replacement workflows.', '',
          'Standalone files embed only shared helpers reachable by their callers. Full',
          'shared module sources remain under tools/ for generation and fixture coverage.', '']
(root / 'docs/user-scripts-guide.md').write_text('\n'.join(guide))
