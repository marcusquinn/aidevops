#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Host-local rejected-secret cooldowns. Secret bytes never leave the subprocess pipe."""

import contextlib
import fcntl
import hashlib
import json
import os
import re
import signal
import socket
import stat
import subprocess
import sys
import time
from pathlib import Path


def private_open(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        os.close(fd)
        raise OSError('unsafe rejection state')
    return os.fdopen(fd, 'r+')


@contextlib.contextmanager
def rejection_state():
    # Deliberately independent of repo, issue, worktree and pulse cycle.
    directory = Path.home() / '.aidevops/cache/secret-rejections'
    directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    info = directory.lstat()
    if directory.is_symlink() or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise OSError('unsafe rejection directory')
    with private_open(directory / 'state.json') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        content = handle.read()
        state = json.loads(content) if content else {}
        yield state
        handle.seek(0)
        json.dump(state, handle)
        handle.truncate()
        handle.flush()
        os.fsync(handle.fileno())


def value_hash(name):
    try:
        timeout = int(os.environ.get('AIDEVOPS_RUNNER_CAPABILITY_SECRET_TIMEOUT_SECONDS', '15'))
    except ValueError:
        timeout = 15
    process = subprocess.Popen(['aidevops', 'secret', 'get', name],
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        value, _ = process.communicate(timeout=min(60, max(1, timeout)))
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise OSError('secret lookup timed out') from None
    if process.returncode or not value:
        raise OSError('secret lookup unavailable')
    return hashlib.sha256(value).hexdigest()


def ttl_seconds():
    try:
        return min(86400, max(1, int(os.environ.get('AIDEVOPS_REJECTED_SECRET_TTL_SECONDS', '86400'))))
    except ValueError:
        return 86400


def notice(name):
    # Same owner-facing advisory spool as pulse-runner-health-helper.sh.
    directory = Path.home() / '.aidevops/advisories'
    directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    if directory.is_symlink() or directory.stat().st_uid != os.getuid():
        raise OSError('unsafe advisory directory')
    with private_open(directory / f'secret-rejected-{name}.advisory') as handle:
        handle.seek(0)
        handle.write(f'Secret {name} rejected on runner {socket.gethostname()}; '
                     f'refresh it with `aidevops secret set {name}`\n')
        handle.truncate()


def process_names(action, names):
    if not names or len(names) > 32 or not all(re.fullmatch(r'[A-Z][A-Z0-9_]{0,127}', n) for n in names):
        raise ValueError('invalid secret names')
    rejected = ''
    with rejection_state() as state:
        for name in sorted(set(names)):
            marker = state.get(name)
            now = time.time()
            if marker and now - marker['time'] >= ttl_seconds():
                state.pop(name)
                marker = None
            if action == 'check' and not marker:
                continue
            digest = value_hash(name)
            if action == 'record':
                if not marker or marker['hash'] != digest:
                    notice(name)
                    state[name] = {'time': now, 'hash': digest}
            elif marker['hash'] != digest:
                state.pop(name)
            else:
                rejected = rejected or name
    return rejected


if __name__ == '__main__':
    try:
        if len(sys.argv) < 3 or sys.argv[1] not in ('record', 'check'):
            raise ValueError('invalid action')
        rejected_name = process_names(sys.argv[1], sys.argv[2:])
        if rejected_name:
            print(f'runner_capability_unmet reason=secret_rejected name={rejected_name}')
            sys.exit(1)
    except (OSError, ValueError, TypeError, KeyError):
        print('runner_capability_unmet reason=rejection_state_unreadable')
        sys.exit(1)
