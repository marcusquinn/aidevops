#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded literal traversal of ~/.ssh/config and its Include files.

Never run `ssh -G`: resolving effective configuration executes `Match exec` commands.
"""
import glob
import itertools
import os
import re
from pathlib import Path

from credential_literals import finding
from credential_sshrules import (config_severity, current_user, expand, next_scope, owned_perms,
                                 parse_line, read_config, risk)

MAX_DEPTH = 16  # OpenSSH READCONF_MAX_DEPTH
MAX_SOURCES = 64  # total source visits, including repeated includes in other scopes
LOOPBACK = re.compile(r'localhost|127(?:\.\d{1,3}){3}|::1|\[::1\]', re.IGNORECASE)


class Block:
    """IdentityFile and HostName values of one Host/Match block within one source."""

    def __init__(self, key='', args=()):
        # Only an exact `Host alias` block can be proven loopback; Match, wildcard,
        # negated and pre-Host (top) blocks may apply to remote destinations.
        self.patterns = frozenset(args) if key == 'host' else None
        if self.patterns is not None and (not args or any(c in arg for arg in args for c in '*?!')):
            self.patterns = None
        self.keys = []
        self.hosts = []

    def loopback(self, prior):
        """prior: exact patterns that already set HostName, or None once a wild block did."""
        # Local VM tooling (OrbStack, Lima, Colima) ships passphrase-less loopback keys.
        # OpenSSH keeps the first HostName obtained, so any earlier match disqualifies.
        if self.patterns is None or prior is None or self.patterns & prior:
            return False
        return bool(self.hosts) and all(LOOPBACK.fullmatch(host) for host in self.hosts)


class Audit:
    def __init__(self, home):
        self.home = Path(home)
        self.user = current_user()
        self.stack = []  # active include chain, for cycle detection
        self.visits = 0
        self.keys = {}  # key path -> referenced only by loopback-only blocks
        self.hostnames = frozenset()  # exact patterns with HostName so far; None after a wild one
        self.truncated = False

    def admit(self, real, depth):
        if real in self.stack:
            return False
        if depth > MAX_DEPTH or self.visits >= MAX_SOURCES:
            self.truncated = True
            return False
        self.visits += 1
        return True

    def config(self, path, global_scope, depth):
        # A source may be included again under another scope (e.g. Host x, then Host *),
        # so only the active chain blocks revisits; findings are deduplicated later.
        real = os.path.realpath(path)
        if not self.admit(real, depth):
            return
        self.stack.append(real)
        try:
            yield from self.source(path, global_scope, depth)
        finally:
            self.stack.pop()

    def source(self, path, global_scope, depth):
        try:
            text, info = read_config(path)
        except (OSError, ValueError):
            yield finding(path, 0, '', 'unreadable-ssh-config', severity='medium')
            return
        perms = owned_perms(path, info, config_severity(info))
        if perms:
            yield perms
        block = Block()
        for number, line in enumerate(text.split('\n'), 1):
            parsed = parse_line(line)
            if not parsed:
                continue
            if parsed[0] in ('host', 'match'):
                self.close(block)
                block = Block(*parsed)
            global_scope = next_scope(parsed[0], parsed[1], global_scope)
            yield from self.directive(path, number, parsed, (global_scope, block), depth)
        self.close(block)

    def close(self, block):
        local = block.loopback(self.hostnames)
        for key in block.keys:
            self.keys[key] = self.keys.get(key, True) and local
        if block.hosts and self.hostnames is not None:
            self.hostnames = None if block.patterns is None else self.hostnames | block.patterns

    def remember(self, key, args, block):
        if key == 'hostname' and args:
            block.hosts.append(args[0])
        elif key == 'identityfile' and args:
            resolved = expand(self.home, self.user, args[0])
            if resolved and not resolved.endswith('.pub'):
                block.keys.append(os.path.normpath(resolved))

    def directive(self, path, number, parsed, context, depth):
        key, args = parsed
        global_scope, block = context
        if key == 'include':
            for pattern in args:
                yield from self.include(pattern, global_scope, depth)
        self.remember(key, args, block)
        record = risk(path, number, key, args, global_scope)
        if record:
            yield record

    def include(self, pattern, global_scope, depth):
        resolved = expand(self.home, self.user, pattern) if pattern.startswith(('~', '/', '%')) \
            else str(self.home / '.ssh' / pattern)
        matches = sorted(itertools.islice(glob.iglob(resolved), MAX_SOURCES + 1)) if resolved else []
        if len(matches) > MAX_SOURCES:
            self.truncated = True
        for path in matches[:MAX_SOURCES]:
            # Included Host/Match lines do not leak scope back to the parent (readconf oactive).
            yield from self.config(path, global_scope, depth + 1)

    def key_paths(self):
        """Default id_* keys (ssh may offer them anywhere) plus IdentityFile keys -> loopback-only."""
        ssh = glob.escape(str(self.home / '.ssh'))
        defaults = {p: False for p in sorted(glob.glob(ssh + '/id_*')) if not p.endswith('.pub')}
        return {**self.keys, **defaults}
