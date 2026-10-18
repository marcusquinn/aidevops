#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Literal, read-only ~/.ssh/config audit. Emit keywords, paths and lines, never arguments.

Never run `ssh -G`: resolving effective configuration executes `Match exec` commands.
"""
import glob
import itertools
import os
import pwd
import re
import shlex
import stat
from pathlib import Path

from credential_literals import finding
from credential_sshkey import UNREADABLE, key_state

MAX_DEPTH = 16  # OpenSSH READCONF_MAX_DEPTH
MAX_SOURCES = 64  # total source visits, including repeated includes in other scopes
MAX_CONFIG_BYTES = 1024 * 1024
LOOPBACK = re.compile(r'localhost|127(?:\.\d{1,3}){3}|::1|\[::1\]', re.IGNORECASE)


def disabled(args, _global_scope):
    return bool(args) and args[0].lower() in ('no', 'off')


def discarded(args, _global_scope):
    return any(arg in ('/dev/null', 'none') for arg in args)


def global_agent(args, global_scope):
    return global_scope and bool(args) and args[0].lower() not in ('no', 'false')


def configured(args, _global_scope):
    return bool(args) and args[0].lower() != 'none'


def external_provider(args, _global_scope):
    # 'internal' is the built-in FIDO middleware, meaningful only for SecurityKeyProvider.
    return configured(args, _global_scope) and args[0].lower() != 'internal'


def match_exec(args, _global_scope):
    return any(arg.lower() == 'exec' for arg in args)


# keyword -> (display name, category, severity, predicate). Command directives are
# often legitimate (bastions, tunnels), so they are low-severity persistence signals.
RISKS = {
    'stricthostkeychecking': ('StrictHostKeyChecking', 'ssh-hostkey-check-disabled', 'medium', disabled),
    'userknownhostsfile': ('UserKnownHostsFile', 'ssh-known-hosts-discarded', 'medium', discarded),
    'forwardagent': ('ForwardAgent', 'ssh-agent-forwarding-global', 'medium', global_agent),
    'proxycommand': ('ProxyCommand', 'ssh-command-directive', 'low', configured),
    'localcommand': ('LocalCommand', 'ssh-command-directive', 'low', configured),
    'knownhostscommand': ('KnownHostsCommand', 'ssh-command-directive', 'low', configured),
    'pkcs11provider': ('PKCS11Provider', 'ssh-command-directive', 'low', configured),
    'securitykeyprovider': ('SecurityKeyProvider', 'ssh-command-directive', 'low', external_provider),
    'match': ('Match exec', 'ssh-command-directive', 'low', match_exec),
}


def parse_line(line):
    """Return (keyword, args) like OpenSSH readconf, or None for blank/comment/unbalanced lines."""
    try:
        words = shlex.split(line, comments=True)
    except ValueError:
        return None
    if not words:
        return None
    key, _, rest = words[0].partition('=')
    args = ([rest] if rest else []) + words[1:]
    if args and args[0].startswith('='):
        args = ([args[0][1:]] if args[0][1:] else []) + args[1:]
    return key.lower(), args


def next_scope(key, args, global_scope):
    if key == 'host':
        return args == ['*']
    if key == 'match':
        return [arg.lower() for arg in args] == ['all']
    return global_scope


def expand(home, user, value):
    """Resolve ~, %d, %u and %%; None for host-dependent, env or cwd-relative paths."""
    if '${' in value:
        return None
    value = value.replace('%%', '\0').replace('%d', str(home)).replace('%u', user)
    if '%' in value:
        return None
    value = value.replace('\0', '%')
    if value == '~' or value.startswith('~/'):
        value = str(home) + value[1:]
    return value if value.startswith('/') else None


def read_config(path):
    # ssh follows symlinked configs, so the audit reads through them too. O_NONBLOCK
    # keeps a FIFO from hanging the scan; the read itself is bounded, not just fstat.
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ValueError('unsafe source')
        data = source.read(MAX_CONFIG_BYTES + 1)
    if len(data) > MAX_CONFIG_BYTES:
        raise ValueError('oversize source')
    return data.decode('utf-8'), info


def current_user():
    try:
        return pwd.getpwuid(os.getuid()).pw_name
    except KeyError:  # containers without a passwd entry
        return os.environ.get('USER', '')


def owned_perms(path, info, severity):
    """Fixable insecure-perms only for an owned regular path; symlinks are report-only."""
    if info.st_uid != os.getuid():
        return None if info.st_uid == 0 else finding(path, 0, '', 'ssh-foreign-owner', severity='medium')
    if not info.st_mode & 0o077:
        return None
    if os.path.islink(path):
        return finding(path, 0, '', 'ssh-insecure-perms-symlink', severity=severity)
    return finding(path, 0, '', 'insecure-perms', severity=severity, env_source='ssh')


def config_severity(info):
    # ssh itself refuses group/world-writable configs; readable ones only leak inventory.
    return 'medium' if info.st_mode & 0o022 else 'low'


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
        rule = RISKS.get(key)
        if rule and rule[3](args, global_scope):
            yield finding(path, number, rule[0], rule[1], severity=rule[2])

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
