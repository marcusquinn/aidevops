#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Locked import/prune implementation; parsing is shared with the read-only audit."""
import os
import json
import re
import stat
import subprocess
import sys
import tempfile
from collections import Counter, namedtuple
from pathlib import Path

from credential_audit import EXPORT, SECRET_NAME, compare, finding, literal, parse, physical_lines, read_source, run

MigrationOptions = namedtuple('MigrationOptions', 'operation dry_run helper')


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
    counts = Counter(name for _, name, _ in assignments)
    options = MigrationOptions(operation, dry_run, helper)
    removed = set()
    for index, name, raw in assignments:
        if not SECRET_NAME.search(name):
            continue
        value = literal(raw)
        if counts[name] != 1 or not value or value.startswith(('YOUR_', 'CHANGE_ME')):
            print(f'Keeping {name} (ambiguous, empty or unsupported assignment)')
            continue
        if migrate_assignment(name, value, owned, options):
            removed.add(index)
    if removed and dry_run != 'true':
        replace_pruned(path, info, lines, removed)


def migrate_assignment(name, value, owned, options):
    target = 'aidevops/' + name
    if target in owned:
        return migrate_owned(name, value, options.operation, options.dry_run, options.helper)
    if options.operation == 'import':
        if run(['gopass', 'insert', target], (value + '\n').encode()).returncode:
            raise ValueError('insert failed')
        owned.add(target)
        print(f'Imported {name}')
    else:
        print(f'Keeping {name} (not owned by gopass)')
    return False


def migrate_owned(name, value, operation, dry_run, helper):
    stored = run(['gopass', 'show', '-n', 'aidevops/' + name])
    equal = stored.returncode == 0 and stored.stdout.rstrip(b'\n') == value.encode()
    if operation == 'import':
        state = 'value-equal' if equal else 'differing or unreadable'
        print(f'Skipping {name} (already in gopass; {state})')
    elif equal and run(['bash', helper, 'check', name]).returncode == 0:
        print(f'{"Would prune" if dry_run == "true" else "Pruning"} {name}')
        return True
    else:
        print(f'Keeping {name} (gopass differs or is unreadable)')
    return False


def replace_pruned(path, info, lines, removed):
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


def audit(files, loader, helper):
    try:
        listing = run(['gopass', 'ls', '--flat'])
        owned = set(listing.stdout.decode().splitlines()) if not listing.returncode else None
    except (OSError, UnicodeError, subprocess.SubprocessError):
        owned = None
    for path in dict.fromkeys(files):
        if os.path.lexists(path):
            yield from audit_file(path, loader, owned, helper)
    yield from audit_leftovers(files)


def audit_file(path, loader, owned, helper):
    info = os.lstat(path)
    mode = stat.S_IMODE(info.st_mode)
    if mode != 0o600:
        yield finding(path, 0, '', 'insecure-perms', mode=f'{mode:03o}')
    if info.st_uid != os.getuid():
        yield finding(path, 0, '', 'unsafe-owner', uid=info.st_uid)
    try:
        original, _ = read_source(path)
    except (OSError, UnicodeError, ValueError):
        yield finding(path, 0, '', 'unreadable-source')
        return
    if path == loader:
        yield from audit_loader(path, original)
    else:
        assignments, errors = parse(original, path)
        yield from errors
        yield from audit_assignments(path, assignments, owned, helper)


def audit_loader(path, original):
    # Loader structure is intentional; only direct exports strand secrets.
    for number, line in enumerate(physical_lines(original), 1):
        match = EXPORT.fullmatch(line.rstrip('\n'))
        if match and match[1] != 'AIDEVOPS_ACTIVE_TENANT':
            yield finding(path, number, match[1], 'stranded-loader')


def audit_assignments(path, assignments, owned, helper):
    counts = Counter(name for _, name, _ in assignments)
    for index, name, raw in assignments:
        value = literal(raw)
        if not eligible_secret(name, value):
            continue
        if counts[name] != 1:
            category = 'ambiguous-assignment'
        else:
            category = safe_compare(name, value, owned, helper)
        yield finding(path, index + 1, name, category)


def eligible_secret(name, value):
    return bool(SECRET_NAME.search(name) and value and not value.startswith(('YOUR_', 'CHANGE_ME')))


def safe_compare(name, value, owned, helper):
    try:
        return compare(name, value, owned, helper)
    except (OSError, UnicodeError, subprocess.SubprocessError):
        return 'backend-unavailable'


def audit_leftovers(files):
    for directory in sorted({str(Path(path).parent) for path in files}):
        for pattern in ('credentials.sh.bak*', '.credentials-prune-*', '.credentials-repair-*'):
            for backup in sorted(Path(directory).glob(pattern)):
                mode = stat.S_IMODE(backup.lstat().st_mode)
                yield finding(backup, 0, '', 'leftover', mode=f'{mode:03o}')


def mcp_findings(path):
    try:
        original, _ = read_source(path)
        config = json.loads(original)
        for key in ('mcp', 'mcpServers'):
            yield from mcp_servers(path, config.get(key, {}))
    except (OSError, ValueError, UnicodeError, AttributeError):
        yield finding(path, 0, '', 'mcp-unreadable')


def mcp_servers(path, servers):
    if isinstance(servers, dict):
        for server, entry in servers.items():
            if isinstance(entry, dict):
                yield from mcp_entry(path, server, entry)


def mcp_entry(path, server, entry):
    for block in ('env', 'environment'):
        env = entry.get(block, {})
        if not isinstance(env, dict):
            continue
        for name, value in env.items():
            if is_mcp_literal(name, value):
                yield finding(path, 0, name, 'mcp-literal', server=server, block=block)


def is_mcp_literal(name, value):
    return bool(SECRET_NAME.search(name) and isinstance(value, str) and value
                and not re.fullmatch(r'\{(?:env|file):[^{}]+\}', value))


if __name__ == '__main__':
    try:
        migrate(*sys.argv[1:])
    except (OSError, ValueError, UnicodeError, subprocess.SubprocessError):
        print('Credential migration failed safely; use a private regular file containing only comments and simple one-line literal exports, with readable gopass', file=sys.stderr)
        sys.exit(1)
