"""Conservatively project simple Bash helper modules onto their actual callers.

Modules use column-zero function signatures and closing braces/parentheses.
References include string literals so dynamic function dispatch is retained.
The source module remains complete for fixtures and other consumers.
"""
import re


def functions(source):
    result = {}
    # Skip quoted, plain and tab-stripped heredocs: embedded PHP/Python braces
    # are payload, never Bash function boundaries. Other module syntax remains
    # deliberately restricted; project_module rejects unpreserved content.
    current = None
    pending = []
    offset = 0
    for line in source.splitlines(keepends=True):
        if pending:
            delimiter, tabs = pending[0]
            candidate = line.rstrip('\n')
            if (candidate.lstrip('\t') if tabs else candidate) == delimiter:
                pending.pop(0)
        else:
            match = re.fullmatch(r'([A-Za-z_][A-Za-z0-9_]*)\(\) ([({])\n', line)
            if match and current is None:
                current = (match[1], offset, '}' if match[2] == '{' else ')')
            elif current and line.rstrip('\n') == current[2]:
                name, start, _ = current
                if name in result:
                    raise ValueError(f'Duplicate helper: {name}')
                result[name] = source[start:offset + len(line)]
                current = None
            for doc in re.finditer(r"(?<!<)<<(-?)[ \t]*(?:'([A-Za-z_][A-Za-z0-9_]*)'|\"([A-Za-z_][A-Za-z0-9_]*)\"|([A-Za-z_][A-Za-z0-9_]*))", line):
                pending.append((doc[2] or doc[3] or doc[4], bool(doc[1])))
        offset += len(line)
    if current or pending:
        raise ValueError('Unclosed helper or heredoc')
    return result


def project_module(source, callers, header):
    bodies = functions(source)
    # Fail closed if a module gains executable top-level code that the supplied
    # header would not preserve, or a heredoc breaks the simple block convention.
    remainder = source
    for body in bodies.values():
        remainder = remainder.replace(body, '', 1)
    header_lines = set(header.splitlines())
    for line in remainder.splitlines():
        if line.strip() and not line.lstrip().startswith('#') and line not in header_lines:
            raise ValueError(f'Unpreserved module content: {line[:80]}')
    roots = set(re.findall(r'\b[A-Za-z_][A-Za-z0-9_]*\b', callers)) & bodies.keys()
    retained = set(roots)
    todo = list(roots)
    while todo:
        name = todo.pop()
        dependencies = set(re.findall(r'\b[A-Za-z_][A-Za-z0-9_]*\b', bodies[name])) & bodies.keys()
        for dependency in dependencies - retained:
            retained.add(dependency)
            todo.append(dependency)
    return header.rstrip() + '\n' + '\n'.join(body for name, body in bodies.items() if name in retained)
