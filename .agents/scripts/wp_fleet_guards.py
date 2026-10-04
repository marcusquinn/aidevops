#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared fail-closed guards for the WordPress fleet runner.

Shipped to remote hosts by wp-fleet-runner.py; must stay Python 3.6
compatible and import only the standard library.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess  # nosec B404 -- fixed executables only, see command()
import tempfile
import zipfile

SCHEMA = 1
ALLOWED_EXECUTABLES = ('wp', 'gh', 'bash', 'ssh', 'sshpass')
UNSAFE_PARTS = ('', '.', '..')
MEMBER_TYPES = (0, stat.S_IFREG, stat.S_IFDIR)
MAX_MEMBERS = 10000
MAX_EXPANDED_BYTES = 256 * 1024 * 1024
NUMERIC_VERSION = re.compile(r'\d+(?:\.\d+)*')


class Stop(Exception):
    pass


def require(condition, reason):
    if not condition:
        raise Stop(reason)


def digest(value):
    return hashlib.sha256(value).hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def atomic(path, value):
    path = Path(path)
    fd, name = tempfile.mkstemp(dir=str(path.parent), prefix='.checkpoint-')
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(encoded(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, str(path))
    finally:
        if os.path.exists(name):
            os.unlink(name)


def command(argv, data=None, timeout=120, env=None):
    require(argv and argv[0] in ALLOWED_EXECUTABLES, 'unapproved command executable')
    # Executables are fixed; callers validate selections and audit argv. No
    # release notes or shell strings enter this local subprocess boundary.
    result = subprocess.run(argv, input=data, stdout=subprocess.PIPE,  # nosec B603 -- fixed executables, validated argv, no shell
                            stderr=subprocess.PIPE, timeout=timeout, env=env, shell=False)
    require(result.returncode == 0, 'command failed; private checkpoint retained')
    return result.stdout


def private_dir(path):
    path = Path(path)
    require(not any(p.is_symlink() for p in [path] + list(path.parents)),
            'symlink private directory refused')
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(path.stat().st_uid == os.getuid(), 'private directory owner mismatch')
    require(stat.S_IMODE(path.stat().st_mode) == 0o700, 'private directory must be 0700')
    return path.resolve()


def _member_parts(item, slug):
    name = item.filename
    parts = name.rstrip('/').split('/')
    require(parts[0] == slug, 'unsafe archive member')
    require(not any(part in UNSAFE_PARTS for part in parts), 'unsafe archive member')
    require('\\' not in name and not name.startswith('/'), 'unsafe archive member')
    require(stat.S_IFMT(item.external_attr >> 16) in MEMBER_TYPES, 'unsafe archive member')
    return parts


def _check_header(content, version):
    header = content[:8192].decode('utf-8', 'replace')
    require(re.search(r'Plugin Name:\s*\S', header), 'plugin header identity mismatch')
    version_line = r'Version:\s*' + re.escape(version) + r'\s*(?:\r?\n|\*/)'
    require(re.search(version_line, header), 'plugin header identity mismatch')


def _check_tree(members):
    for name in members:
        parts = name.split('/')
        prefixes = ('/'.join(parts[:n]) for n in range(1, len(parts)))
        require(all(members.get(prefix, True) for prefix in prefixes), 'archive file/directory collision')


def _bounded_members(bundle):
    items = bundle.infolist()
    require(len(items) <= MAX_MEMBERS, 'archive member limit exceeded')
    require(sum(item.file_size for item in items) <= MAX_EXPANDED_BYTES, 'archive expansion limit exceeded')
    return items


def archive(data, slug, version):
    """Return {relative path: sha256} for a safe single-plugin release ZIP."""
    files = {}
    members = {}
    with zipfile.ZipFile(io.BytesIO(data)) as bundle:
        for item in _bounded_members(bundle):
            parts = _member_parts(item, slug)
            normalized = '/'.join(parts)
            require(normalized not in members, 'duplicate archive member')
            members[normalized] = item.is_dir()
            if item.is_dir():
                continue
            require(len(parts) > 1, 'unsafe archive path')
            name = '/'.join(parts[1:])
            require(name not in files, 'duplicate archive member')
            content = bundle.read(item)
            files[name] = digest(content)
            if name == slug + '.php':
                _check_header(content, version)
    require(slug + '.php' in files, 'expected main plugin file missing')
    _check_tree(members)
    return files


def matches(state, release):
    return state['version'] == release['version'] and state['files'] == release['files']


def scope_guard(state, baseline, release):
    keys = ('root', 'urls', 'activation', 'host_identity', 'config_sha256', 'health')
    require(all(state[key] == baseline[key] for key in keys),
            'fleet scope, activation, config or health drift')
    require(state == baseline or matches(state, release), 'fleet version/bytes drift')


def audit_guard(audit):
    require(isinstance(audit, list) and all(isinstance(arg, str) for arg in audit),
            'invalid read-only audit argv')
    overrides = ('--path', '--url', '--ssh', '--http', '--exec', '--require')
    require(not any(arg.startswith(overrides) for arg in audit),
            'audit transport/bootstrap overrides refused')


def version_guard(installed, target):
    # Fail closed on versions whose ordering cannot be established safely.
    require(all(NUMERIC_VERSION.fullmatch(v) for v in (installed, target)),
            'numeric release versions required')
    old, new = [list(map(int, v.split('.'))) for v in (installed, target)]
    length = max(len(old), len(new))
    require(old + [0] * (length - len(old)) <= new + [0] * (length - len(new)),
            'newer installed version refused')
