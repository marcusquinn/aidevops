#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Liveness-fenced, bounded scratch for archive verification (GH#36468).

Verification scratch is a reproducible derived copy, not recovery data.
Each attempt owns a private directory and holds an exclusive ``flock`` on it
for its whole lifetime, so liveness never depends on cooperative cleanup:

- success or cancellation (SIGTERM/SIGHUP, timeout, Ctrl-C) removes it;
- a verification failure keeps it as diagnostic evidence, marked with the
  sanitized failure reason, but only the newest copy per archive and only for
  ``AIDEVOPS_WORKTREE_VERIFY_EVIDENCE_TTL_HOURS`` (default 24, 0 disables);
- anything else without a live lock holder (SIGKILL, power loss, legacy
  directories) is dead and is reclaimed by :func:`sweep`.

A retry never waits for a person to review retained evidence.
"""

import contextlib
import fcntl
import hashlib
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

PREFIX = '.archive-verify-'
LOCAL_PREFIX = '.verify-local-'
FAILURE_MARKER = '.aidevops-verify-failed'
# Covers only the instant between mkdtemp() and flock(); every live owner
# holds its lock, so a longer age never protects a running verification.
STALE_GRACE_SECONDS = 600
# mkdtemp suffixes are [a-z0-9_]; keyed names embed sha256(archive path).
NAME = re.compile(r'\.(?P<kind>archive-verify|verify-local)-'
                  r'(?:(?P<key>[0-9a-f]{64})(?:-[a-z0-9_]{1,32})?|[a-z0-9_]{1,32})')
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
TERMINATION_SIGNALS = (signal.SIGTERM, signal.SIGHUP)


def evidence_ttl_seconds():
    """Failure-evidence lifetime in seconds; invalid values use the default."""
    try:
        hours = int(os.environ.get('AIDEVOPS_WORKTREE_VERIFY_EVIDENCE_TTL_HOURS', '24'))
    except ValueError:
        hours = 24
    return max(0, min(hours, 24 * 30)) * 3600


def archive_key(archive):
    return hashlib.sha256(os.fsencode(archive)).hexdigest()


@contextlib.contextmanager
def termination_as_exit():
    """Turn SIGTERM/SIGHUP into SystemExit so ``finally`` cleanup runs.

    Python's default disposition terminates without unwinding. Only the main
    thread may install handlers; elsewhere this is a no-op.
    """
    if threading.current_thread() is not threading.main_thread():
        yield
        return

    def leave(signum, _frame):
        raise SystemExit(128 + signum)

    previous = {number: signal.signal(number, leave) for number in TERMINATION_SIGNALS}
    try:
        yield
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def _remove(path, opened):
    """Remove a directory only if the path still names the locked inode."""
    if not getattr(shutil.rmtree, 'avoids_symlink_attacks', False):
        return False
    try:
        current = os.lstat(path)
    except FileNotFoundError:
        return False
    if (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino):
        return False
    shutil.rmtree(path)
    return True


def _probe(path):
    """Return (fd, stat, failed) for a dead scratch, or None while it is owned."""
    try:
        descriptor = os.open(path, DIRECTORY_FLAGS)
    except OSError:
        return None  # Vanished, symlink or unreadable: never follow or delete.
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        opened = os.fstat(descriptor)
        try:
            os.stat(FAILURE_MARKER, dir_fd=descriptor, follow_symlinks=False)
            failed = True
        except FileNotFoundError:
            failed = False
    except OSError:
        os.close(descriptor)
        return None  # A live verifier holds the lock.
    return descriptor, opened, failed


def sweep(parent, now=None, supersede=None):
    """Reclaim dead verification scratch directly inside one archive bucket.

    Returns the removed paths. Live, symlinked or unrecognised entries are
    never touched; the newest unexpired failure evidence per archive is kept
    unless ``supersede`` names that archive key (its owner holds newer
    evidence under a live lock).
    """
    parent = Path(parent)
    now = time.time() if now is None else now
    ttl = evidence_ttl_seconds()
    try:
        names = sorted(entry.name for entry in os.scandir(parent)
                       if NAME.fullmatch(entry.name) and entry.is_dir(follow_symlinks=False))
    except OSError:
        return []
    dead, newest = [], {}
    try:
        for name in names:
            probed = _probe(parent / name)
            if probed is None:
                continue
            descriptor, opened, failed = probed
            dead.append((name, descriptor, opened, failed))
            match = NAME.fullmatch(name)
            key = match['key'] and (match['kind'], match['key'])
            if failed and key and key != supersede and now - opened.st_mtime < ttl:
                if key not in newest or opened.st_mtime > newest[key][1]:
                    newest[key] = (name, opened.st_mtime)
        kept = {name for name, _ in newest.values()}
        removed = []
        for name, _descriptor, opened, failed in dead:
            if name in kept or (not failed and now - opened.st_mtime < STALE_GRACE_SECONDS):
                continue
            if _remove(parent / name, opened):
                removed.append(parent / name)
        return removed
    finally:
        for _name, descriptor, _opened, _failed in dead:
            os.close(descriptor)


def _mark_failed(descriptor, error):
    """Record only a fixed-format reason; never raw stderr, paths or object IDs."""
    reason = type(error).__name__
    if isinstance(error, ValueError) and re.fullmatch(r'[a-z_-]{1,40}:[ -~]{1,300}', str(error)):
        reason = str(error)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    try:
        marker = os.open(FAILURE_MARKER, flags, 0o600, dir_fd=descriptor)
    except OSError:
        return False
    with os.fdopen(marker, 'w', encoding='ascii', errors='replace') as output:
        output.write(reason + '\n')
    return True


@contextlib.contextmanager
def verification_scratch(archive, prefix=PREFIX):
    """Yield a private, locked scratch directory beside ``archive``."""
    if prefix not in (PREFIX, LOCAL_PREFIX):
        raise ValueError('archive-verify:unknown-scratch-prefix')
    archive = Path(archive).resolve(strict=True)
    if not getattr(shutil.rmtree, 'avoids_symlink_attacks', False):
        raise ValueError('archive-verify:safe-cleanup-unavailable')
    sweep(archive.parent)
    digest = archive_key(archive)
    key = (prefix.strip('.-'), digest)
    path = Path(tempfile.mkdtemp(prefix=f'{prefix}{digest}-', dir=archive.parent))
    descriptor = os.open(path, DIRECTORY_FLAGS)
    keep = False
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        opened = os.fstat(descriptor)
        with termination_as_exit():
            try:
                yield path
            except Exception as error:
                # Cancellation is BaseException (SystemExit/KeyboardInterrupt)
                # and is the caller's decision, not a verification finding.
                keep = evidence_ttl_seconds() > 0 and _mark_failed(descriptor, error)
                raise
            finally:
                if not keep:
                    _remove(path, opened)
                # This attempt's outcome (newer evidence or a success)
                # supersedes older failure evidence for the same archive.
                sweep(archive.parent, supersede=key)
    finally:
        os.close(descriptor)


def run_bounded(command, timeout, grace=10, **options):
    """``subprocess.run`` equivalent that lets the child clean up on timeout.

    The child gets its own session, so the whole tree is signalled. Timeout
    sends SIGTERM to the group, waits ``grace`` seconds, then SIGKILLs it.
    Raises ``subprocess.TimeoutExpired`` or ``CalledProcessError`` like run().
    """
    check = options.pop('check', False)
    capture = options.pop('capture_output', False)
    if capture:
        options.setdefault('stdout', subprocess.PIPE)
        options.setdefault('stderr', subprocess.PIPE)
    data = options.pop('input', None)
    if data is not None:
        options['stdin'] = subprocess.PIPE
    with subprocess.Popen(command, start_new_session=True, **options) as process:  # nosec B603
        try:
            stdout, stderr = process.communicate(data, timeout=timeout)
        except subprocess.TimeoutExpired:
            _terminate_group(process, grace)
            stdout, stderr = process.communicate()
            raise subprocess.TimeoutExpired(command, timeout, output=stdout, stderr=stderr) from None
        except BaseException:
            _terminate_group(process, grace)
            raise
    if check and process.returncode:
        raise subprocess.CalledProcessError(process.returncode, command, stdout, stderr)
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def _terminate_group(process, grace):
    for number, wait in ((signal.SIGTERM, grace), (signal.SIGKILL, None)):
        try:
            os.killpg(process.pid, number)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=wait)
            return
        except subprocess.TimeoutExpired:
            continue


def sweep_root(root):
    """Sweep every ``ROOT/<repository>/<bucket>`` without following symlinks."""
    root = Path(root)
    removed = []
    if root.is_symlink() or not root.is_dir():
        return removed
    for repository in sorted(root.iterdir()):
        if repository.is_symlink() or not repository.is_dir():
            continue
        for bucket in sorted(repository.iterdir()):
            if not bucket.is_symlink() and bucket.is_dir():
                removed.extend(sweep(bucket))
    return removed


def main(argv):
    """``sweep ROOT``: reclaim dead scratch in every archive bucket."""
    if len(argv) != 3 or argv[1] != 'sweep':
        print('usage: worktree_archive_scratch.py sweep ARCHIVE_ROOT', file=sys.stderr)
        return 2
    for path in sweep_root(argv[2]):
        print(f'reclaimed\t{path}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
