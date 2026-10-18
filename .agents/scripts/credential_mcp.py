#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""MCP credential discovery and revision-checked Outscraper migration."""
import fcntl
import json
import os
import re
import stat
import tempfile
from pathlib import Path

from credential_literals import SECRET_NAME, finding, read_source
from credential_process import run


def migrate_outscraper(path, scripts, confirm):
    # Serialize cooperating fix invocations. Other config writers may not honor
    # this lock, so retain the revision check and require the runtime be closed.
    print('Close the runtime/config editors before migrating its configuration.')
    if not confirm('Outscraper migration with runtime/config editors closed'):
        return False
    lock_path = str(path) + '.security-fix.lock'
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError('unsafe lock')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return _migrate_outscraper_locked(path, scripts)
    finally:
        os.close(fd)


def _migrate_outscraper_locked(path, scripts):
    from lib.mcp_outscraper import register_outscraper

    original, info = read_source(path)
    if info.st_uid != os.getuid():
        return False
    config = json.loads(original)
    entry = config.get('mcp', {}).get('outscraper')
    if not isinstance(entry, dict):
        return False  # Other runtime schemas need their own launcher adaptation.
    values = [entry[key]['OUTSCRAPER_API_KEY'] for key in ('env', 'environment')
              if isinstance(entry.get(key), dict) and 'OUTSCRAPER_API_KEY' in entry[key]]
    if not values:
        return False
    stored = run(['gopass', 'show', '-n', 'aidevops/OUTSCRAPER_API_KEY'])
    if (stored.returncode or any(not isinstance(value, str) or
                                stored.stdout.rstrip(b'\n') != value.encode() for value in values)
            or run(['bash', str(scripts / 'secret-helper.sh'), 'check', 'OUTSCRAPER_API_KEY']).returncode):
        print('Retained MCP literals: store/choose the matching OUTSCRAPER_API_KEY with aidevops secret set first.')
        return False
    # Reuse the setup migration; do not build a second launcher implementation.
    register_outscraper({'mcp': config['mcp'], 'tools': config.setdefault('tools', {})})
    fd, temporary = tempfile.mkstemp(prefix='.mcp-migrate-', dir=str(Path(path).parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            json.dump(config, output, indent=2)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        current = os.stat(path, follow_symlinks=False)
        if (current.st_dev, current.st_ino, current.st_mtime_ns, current.st_size) != (
                info.st_dev, info.st_ino, info.st_mtime_ns, info.st_size):
            raise ValueError('config changed')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


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
