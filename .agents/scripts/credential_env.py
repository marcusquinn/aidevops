#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded, read-only env-style credential audits. Emit metadata, never source text or values."""
import json
import os
import stat
from pathlib import Path

from credential_dotenv import env_files
from credential_findings import audit
from credential_literals import SECRET_NAME, finding, read_source

CONFIG = '.config/aidevops'
RC_FILES = ('.zshrc', '.bashrc', '.bash_profile', '.profile')
SCALARS = (str, int, float, bool)


def rc_texts(home):
    texts = []
    for name in RC_FILES:
        try:
            texts.append(read_source(home / name)[0])
        except (OSError, UnicodeError, ValueError):
            continue
    return [text for text in texts if 'mcp-env.sh' in text]


def rc_references(home, path, root, texts):
    """Any rc mention gates the root mcp-env.sh; tenant links need an explicit path."""
    if root:
        return bool(texts)
    text = str(path)
    spellings = (text, text.replace(str(home), '~', 1), text.replace(str(home), '$HOME', 1))
    return any(spelling in rc for rc in texts for spelling in spellings)


def valid_link(path):
    sibling = path.parent / 'credentials.sh'
    target = Path(os.path.abspath(path.parent / os.readlink(path)))
    return target == sibling and sibling.is_file()


def audit_mcp_env(path, helper, referenced):
    if path.is_symlink():
        if not valid_link(path):
            yield finding(path, 0, '', 'invalid-mcp-env-link', severity='medium')
    elif path.is_file():
        yield finding(path, 0, '', 'legacy-mcp-env', severity='medium')
        for item in audit([str(path)], '', str(helper)):
            yield dict(item, severity='medium', env_source='mcp')
    elif referenced:
        yield finding(path, 0, '', 'missing-mcp-env-link', severity='low')


def mcp_env(home, helper):
    config = home / CONFIG
    texts = rc_texts(home)
    for directory in [config, *sorted((config / 'tenants').glob('*'))]:
        path = directory / 'mcp-env.sh'
        yield from audit_mcp_env(path, helper, rc_references(home, path, directory == config, texts))


def children(node):
    if isinstance(node, dict):
        return node.items()
    if isinstance(node, list):
        return enumerate(node)
    return ()


def secret_scalar(key, value):
    if not isinstance(key, str) or not SECRET_NAME.search(key):
        return False
    return isinstance(value, SCALARS) and value != ''


def plist_literals(path, node, keys=()):
    # JSON arrays of path components avoid ambiguous dotted keys.
    for key, value in children(node):
        parts = [*keys, key]
        if secret_scalar(key, value):
            yield finding(path, 0, key, 'plist-literal', severity='medium', key_path=parts)
        yield from plist_literals(path, value, parts)


def plist_env(home):
    path = home / CONFIG / 'plist-env-overrides.json'
    if not os.path.lexists(path):
        return
    try:
        text, info = read_source(path)
    except (OSError, UnicodeError, ValueError):
        yield finding(path, 0, '', 'unreadable-plist', severity='medium')
        return
    if stat.S_IMODE(info.st_mode) != 0o600:
        yield finding(path, 0, '', 'insecure-perms', severity='medium', env_source='plist')
    try:
        data = json.loads(text)
    except ValueError:
        yield finding(path, 0, '', 'unreadable-plist', severity='medium')
        return
    yield from plist_literals(path, data)


def confirmed_permissions(records, confirm):
    """Legacy mcp-env.sh chmod needs its own confirmation; other records pass through unchanged."""
    return [record for record in records
            if record['category'] != 'insecure-perms' or record.get('env_source') != 'mcp'
            or confirm('mcp-env.sh chmod 600')]


def fix_missing_links(records, confirm, log):
    """Recreate only absent mcp-env.sh links beside a regular credentials.sh, after confirmation."""
    for record in records:
        path = Path(record['file'])
        if record['category'] != 'missing-mcp-env-link' or not (path.parent / 'credentials.sh').is_file():
            continue
        if not os.path.lexists(path) and confirm('recreate mcp-env.sh symlink'):
            # symlink_to fails if anything appeared meanwhile; existing files are never replaced.
            path.symlink_to('credentials.sh')
            log()


AUDITS = {
    'mcp-env': mcp_env,
    'plist-env': lambda home, _helper: plist_env(home),
    'env-files': env_files,
}


def findings(kind, home, helper):
    return AUDITS[kind](home, helper)
