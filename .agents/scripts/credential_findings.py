#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Read-only credential hygiene findings and backend equality checks."""
import os
import stat
from collections import Counter
from pathlib import Path
from subprocess import SubprocessError  # nosec B404

from credential_literals import EXPORT, SECRET_NAME, finding, literal, parse, physical_lines, read_source
from credential_process import run


def audit(files, loader, helper):
    try:
        listing = run(['gopass', 'ls', '--flat'])
        owned = set(listing.stdout.decode().splitlines()) if not listing.returncode else None
    except (OSError, UnicodeError, SubprocessError):
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
    except (OSError, UnicodeError, SubprocessError):
        return 'backend-unavailable'


def compare(name, value, owned, helper):
    if owned is None:
        return 'backend-unavailable'
    target = 'aidevops/' + name
    if target not in owned:
        return 'not-in-gopass'
    stored = run(['gopass', 'show', '-n', target])
    if stored.returncode:
        return 'backend-unavailable'
    if stored.stdout.rstrip(b'\n') != value.encode():
        return 'drift'
    return 'prunable' if run(['bash', helper, 'check', name]).returncode == 0 else 'backend-unavailable'


def audit_leftovers(files):
    for directory in sorted({str(Path(path).parent) for path in files}):
        for pattern in ('credentials.sh.bak*', '.credentials-prune-*', '.credentials-repair-*'):
            for backup in sorted(Path(directory).glob(pattern)):
                mode = stat.S_IMODE(backup.lstat().st_mode)
                yield finding(backup, 0, '', 'leftover', mode=f'{mode:03o}')
