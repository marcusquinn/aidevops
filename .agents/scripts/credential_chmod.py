#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Confirmed `security fix` permission tightening for audited insecure-perms records."""
import json
import os
import stat


def chmod_owned(path):
    """chmod 600 one owned regular file; never follow symlinks or change a foreign owner's file."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            return False
        os.fchmod(fd, 0o600)
        return True
    finally:
        os.close(fd)


def fix_owned_permissions(records, on_fixed):
    """Tighten each insecure-perms file; one failure skips that file only."""
    for record in records:
        if record['category'] != 'insecure-perms':
            continue
        try:
            changed = chmod_owned(record['file'])
        except OSError:
            # Unreadable, replaced by a symlink, or removed since the audit.
            print('Permission fix skipped: ' + json.dumps(record['file'], ensure_ascii=True))
            continue
        if changed:
            on_fixed()
