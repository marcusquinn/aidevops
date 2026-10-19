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
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
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
    # Lock a stable inode; atomically replace the data, never the lock.
    with private_open(directory / 'state.lock') as lock:
        acquire_lock(lock)
        with private_open(directory / 'state.json') as handle:
            content = handle.read()
        state = json.loads(content) if content else {}
        if not isinstance(state, dict):
            raise ValueError('invalid rejection state')
        original = json.dumps(state, sort_keys=True)
        yield state
        if json.dumps(state, sort_keys=True) == original:
            return
        fd, temporary = tempfile.mkstemp(dir=directory, prefix='.state-')
        try:
            with os.fdopen(fd, 'w') as handle:
                json.dump(state, handle)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, directory / 'state.json')
            directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            Path(temporary).unlink(missing_ok=True)


def acquire_lock(lock):
    deadline = time.monotonic() + 5
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise OSError('rejection state busy') from None
            time.sleep(0.05)


def value_hash(name):
    try:
        timeout = int(os.environ.get('AIDEVOPS_RUNNER_CAPABILITY_SECRET_TIMEOUT_SECONDS', '15'))
    except ValueError:
        timeout = 15
    executable = shutil.which('aidevops')
    if not executable:
        raise OSError('secret CLI unavailable')
    # Validated name is data-only argv; no shell or issue-selected command.
    process = subprocess.Popen(  # nosec B603 -- resolved CLI, fixed subcommand, validated name
        [str(Path(executable).resolve()), 'secret', 'get', name],
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


def active_marker(state, name):
    marker = state.get(name)
    if marker and time.time() - marker['time'] >= ttl_seconds():
        state.pop(name)
        return None
    return marker


def update_marker(action, name, digest):
    rejected = ''
    with rejection_state() as state:
        marker = active_marker(state, name)
        if action == 'record':
            if not marker or marker['hash'] != digest:
                state[name] = {'time': time.time(), 'hash': digest, 'notified': False}
        elif marker:
            if marker['hash'] != digest:
                state.pop(name)
            else:
                rejected = name
    return rejected


def notify_marker(name, digest):
    # Only notify after the marker is durable. A failed advisory is retried
    # on the next record without resetting the cooldown's timestamp.
    with rejection_state() as state:
        marker = state.get(name)
        if marker and marker['hash'] == digest and not marker.get('notified'):
            notice(name)
            marker['notified'] = True


def process_name(action, name):
    # Never decrypt while holding the host-wide lock. Re-read state afterwards
    # so concurrent records and removals cannot be overwritten by stale copies.
    with rejection_state() as state:
        if action == 'check' and not active_marker(state, name):
            return ''
    digest = value_hash(name)
    rejected = update_marker(action, name, digest)
    if action == 'record':
        notify_marker(name, digest)
    return rejected


def validate_names(names):
    if not names or len(names) > 32 or not all(re.fullmatch(r'[A-Z][A-Z0-9_]{0,127}', n) for n in names):
        raise ValueError('invalid secret names')


def process_names(action, names):
    validate_names(names)
    rejected = ''
    failed = False
    for name in sorted(set(names)):
        try:
            result = process_name(action, name)
            rejected = rejected or result
        except OSError:
            if action != 'record':
                raise
            failed = True
    if failed:
        raise OSError('some secret lookups unavailable')
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
