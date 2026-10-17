#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Locked import/prune implementation; parsing is shared with the read-only audit."""
import os
import subprocess
import sys
import tempfile

from credential_audit import SECRET_NAME, literal, parse, physical_lines, read_source, run


def migrate(path, operation, dry_run, helper):
    original, info = read_source(path, private=True)
    lines = physical_lines(original)
    assignments, errors = parse(original, path)
    if errors:
        for record in errors:
            print(f"Line {record['line']}: {record['name']} ({record['category']})", file=sys.stderr)
        raise ValueError('unsupported shell structure')
    listing = run(['gopass', 'ls', '--flat'])
    if listing.returncode:
        raise ValueError('unavailable listing')
    owned = set(listing.stdout.decode().splitlines())
    counts = {}
    for _, name, _ in assignments:
        counts[name] = counts.get(name, 0) + 1
    removed = set()
    for index, name, raw in assignments:
        if not SECRET_NAME.search(name):
            continue
        value = literal(raw)
        if counts[name] != 1 or not value or value.startswith(('YOUR_', 'CHANGE_ME')):
            print(f'Keeping {name} (ambiguous, empty or unsupported assignment)')
            continue
        target = 'aidevops/' + name
        if target in owned:
            stored = run(['gopass', 'show', '-n', target])
            equal = stored.returncode == 0 and stored.stdout.rstrip(b'\n') == value.encode()
            if operation == 'import':
                state = 'value-equal' if equal else 'differing or unreadable'
                print(f'Skipping {name} (already in gopass; {state})')
            elif equal and run(['bash', helper, 'check', name]).returncode == 0:
                removed.add(index)
                print(f'{"Would prune" if dry_run == "true" else "Pruning"} {name}')
            else:
                print(f'Keeping {name} (gopass differs or is unreadable)')
        elif operation == 'import':
            if run(['gopass', 'insert', target], (value + '\n').encode()).returncode:
                raise ValueError('insert failed')
            owned.add(target)
            print(f'Imported {name}')
        else:
            print(f'Keeping {name} (not owned by gopass)')
    if removed and dry_run != 'true':
        fd, temporary = tempfile.mkstemp(prefix='.credentials-prune-', dir=os.path.dirname(path))
        try:
            with os.fdopen(fd, 'w', encoding='utf-8', newline='') as output:
                output.write(''.join(line for index, line in enumerate(lines) if index not in removed))
                output.flush()
                os.fsync(output.fileno())
            current = os.stat(path, follow_symlinks=False)
            if (current.st_dev, current.st_ino, current.st_mtime_ns, current.st_size) != (
                    info.st_dev, info.st_ino, info.st_mtime_ns, info.st_size):
                raise ValueError('source changed')
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


if __name__ == '__main__':
    try:
        migrate(*sys.argv[1:])
    except (OSError, ValueError, UnicodeError, subprocess.SubprocessError):
        print('Credential migration failed safely; use a private regular file containing only comments and simple one-line literal exports, with readable gopass', file=sys.stderr)
        sys.exit(1)
