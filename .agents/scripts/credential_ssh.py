#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Literal, read-only ~/.ssh audit. Emit keywords, paths and lines, never arguments.

Config traversal: credential_sshconfig.py; line rules: credential_sshrules.py.
Never run `ssh -G`: resolving effective configuration executes `Match exec` commands.
"""
import os
import stat
from pathlib import Path

from credential_literals import finding
from credential_sshconfig import Audit
from credential_sshkey import UNREADABLE, key_state
from credential_sshrules import config_severity, owned_perms


def passphrase(path, loopback):
    try:
        state = key_state(path)
    except UNREADABLE:
        state = None
    if state is None:
        # Distinguish "could not inspect" from "encrypted"; neither prints key material.
        yield finding(path, 0, '', 'ssh-key-unchecked', severity='low')
        return
    unencrypted, hardware = state
    if not unencrypted:
        return
    # FIDO sk- keys still need the hardware token; loopback-only keys reach local VMs only.
    extra = {'loopback_only': True} if loopback else {}
    yield finding(path, 0, '', 'ssh-key-no-passphrase',
                  severity='low' if hardware or loopback else 'high', **extra)


def audit_key(path, loopback):
    try:
        info = os.stat(path)
    except OSError:
        return  # missing configured keys are not an exposure
    if not stat.S_ISREG(info.st_mode):
        return
    perms = owned_perms(path, info, 'high')
    if perms:
        yield perms
    yield from passphrase(path, loopback)


def ssh_dir(home):
    path = home / '.ssh'
    try:
        info = os.lstat(path)
    except OSError:
        return
    if stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and info.st_mode & 0o077:
        yield finding(path, 0, '', 'ssh-dir-perms', severity=config_severity(info))


def collect(home):
    audit = Audit(home)
    yield from ssh_dir(audit.home)
    config = audit.home / '.ssh' / 'config'
    if os.path.lexists(config):
        yield from audit.config(str(config), True, 0)
    if audit.truncated:
        yield finding(config, 0, '', 'ssh-config-incomplete', severity='medium')
    for path, loopback in audit.key_paths().items():
        yield from audit_key(path, loopback)


def ssh_findings(home):
    """Deduplicated findings; an unexpected failure reports incompleteness, never aborts callers."""
    seen = set()
    try:
        for record in collect(Path(home)):
            identity = (record['file'], record['line'], record['name'], record['category'])
            if identity not in seen:
                seen.add(identity)
                yield record
    except (OSError, ValueError, RecursionError):
        yield finding(Path(home) / '.ssh', 0, '', 'ssh-config-incomplete', severity='medium')
