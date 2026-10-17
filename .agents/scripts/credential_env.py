#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded, read-only env audits. Emit metadata, never source text or values."""
import json
import os
import re
import stat
import time
from pathlib import Path
from subprocess import SubprocessError

from credential_findings import audit
from credential_literals import SECRET_NAME, finding, literal, read_source
from credential_process import run


def record(path, category, severity='medium', line=0, name='', **extra):
    return finding(path, line, name, category, severity=severity, **extra)


def mcp_env(home, helper):
    config = home / '.config/aidevops'
    directories = [config, *sorted((config / 'tenants').glob('*'))]
    rc = []
    for name in ('.zshrc', '.bashrc', '.bash_profile', '.profile'):
        try:
            rc.append(read_source(home / name)[0])
        except (OSError, UnicodeError, ValueError):
            continue
    for directory in directories:
        path = directory / 'mcp-env.sh'
        sibling = directory / 'credentials.sh'
        if path.is_symlink():
            target = Path(os.path.abspath(path.parent / os.readlink(path)))
            if target != sibling or not sibling.is_file():
                yield record(path, 'invalid-mcp-env-link')
        elif path.is_file():
            yield record(path, 'legacy-mcp-env')
            for item in audit([str(path)], '', str(helper)):
                yield dict(item, severity='medium', env_source='mcp')
        elif any('mcp-env.sh' in text and (
                directory == config or str(path) in text or
                str(path).replace(str(home), '~', 1) in text or
                str(path).replace(str(home), '$HOME', 1) in text) for text in rc):
            yield record(path, 'missing-mcp-env-link', 'low')


def plist_env(home):
    path = home / '.config/aidevops/plist-env-overrides.json'
    if not os.path.lexists(path):
        return
    try:
        text, info = read_source(path)
        if stat.S_IMODE(info.st_mode) != 0o600:
            yield record(path, 'insecure-perms', env_source='plist')
        data = json.loads(text)
    except (OSError, UnicodeError, ValueError):
        yield record(path, 'unreadable-plist')
        return

    def walk(node, keys):
        if isinstance(node, dict):
            for key, value in node.items():
                parts = keys + [key]
                if SECRET_NAME.search(key) and isinstance(value, (str, int, float, bool)) and value != '':
                    # JSON arrays of path components avoid ambiguous dotted keys.
                    yield record(path, 'plist-literal', name=key, key_path=parts)
                if isinstance(value, (dict, list)):
                    yield from walk(value, parts)
        elif isinstance(node, list):
            for index, value in enumerate(node):
                yield from walk(value, keys + [index])

    yield from walk(data, [])


def env_paths(home):
    roots = [home / 'Git']
    try:
        text, _ = read_source(home / '.config/aidevops/repos.json')
        for repo in json.loads(text).get('initialized_repos', []):
            path = repo.get('path')
            if isinstance(path, str) and path:
                roots.append(Path(path.replace('~', str(home), 1)) if path.startswith('~/') else Path(path))
    except FileNotFoundError:
        pass
    except (OSError, UnicodeError, ValueError, TypeError, AttributeError):
        yield None
    seen = set()
    deadline = time.monotonic() + 15
    entries = 0
    for root in dict.fromkeys(roots):
        for directory, dirs, files in os.walk(root, followlinks=False):
            entries += 1
            if time.monotonic() > deadline or entries > 10000:
                yield None
                return
            depth = len(Path(directory).relative_to(root).parts)
            dirs[:] = [name for name in dirs if name not in ('.git', 'node_modules', '.venv') and depth < 2]
            for name in files:
                if name != '.env' and not name.startswith('.env.'):
                    continue
                if name in ('.env.example', '.env.sample', '.env.template'):
                    continue
                path = Path(directory) / name
                if path not in seen:
                    seen.add(path)
                    yield path


def git_status(path):
    args = ['git', '-C', str(path.parent)]
    try:
        tracked = run(args + ['ls-files', '--error-unmatch', '--', path.name])
        if tracked.returncode == 0:
            return 'tracked-env', 'high'
        ignored = run(args + ['check-ignore', '-q', '--', path.name])
        if ignored.returncode == 1:
            return 'unignored-env', 'medium'
        if ignored.returncode != 0:
            return 'env-git-unavailable', 'medium'
    except (OSError, SubprocessError):
        return 'env-git-unavailable', 'medium'
    return None


def dotenv_literal(raw):
    """Recognise dotenv quoting/comments without executing or expanding anything."""
    if raw.startswith(("'", '"')):
        match = re.fullmatch(r'''('[^']*'|"(?:\\.|[^"\\])*")\s*(?:#.*)?''', raw)
        if not match:
            return None
        quoted = match[1]
        return quoted[1:-1] if quoted.startswith("'") else literal(quoted)
    raw = re.split(r'\s+#', raw, maxsplit=1)[0].rstrip()
    return raw if not re.search(r'''[$`'"\x00]''', raw) and not raw.startswith('#') else None


def env_files(home, helper):
    checked = {}
    for path in env_paths(home):
        if path is None:
            yield record(home / 'Git', 'env-discovery-incomplete')
            continue
        status = git_status(path)
        if status:
            yield record(path, *status)
        try:
            text, _ = read_source(path)
        except (OSError, UnicodeError, ValueError):
            yield record(path, 'unreadable-env')
            continue
        for line, source in enumerate(text.split('\n'), 1):
            match = re.fullmatch(r'\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)', source)
            if not match or not SECRET_NAME.search(match[1]):
                continue
            raw = match[2].strip()
            value = dotenv_literal(raw)
            if not value:
                continue
            name = match[1]
            if name not in checked:
                try:
                    checked[name] = run(['bash', str(helper), 'check', name]).returncode == 0
                except (OSError, SubprocessError):
                    checked[name] = False
            yield record(path, 'env-literal', 'low', line, name, in_gopass=checked[name])


def findings(kind, home, helper):
    return {'mcp-env': mcp_env, 'plist-env': lambda h, _: plist_env(h), 'env-files': env_files}[kind](home, helper)
