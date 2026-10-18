#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Literal ~/.ssh/config line parsing, risk rules and permission findings. No ssh execution."""
import os
import pwd
import shlex
import stat

from credential_literals import finding

MAX_CONFIG_BYTES = 1024 * 1024


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


def risk(path, number, key, args, global_scope):
    """Finding for a risky directive, by keyword and line only; None otherwise."""
    rule = RISKS.get(key)
    if rule and rule[3](args, global_scope):
        return finding(path, number, rule[0], rule[1], severity=rule[2])
    return None


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
