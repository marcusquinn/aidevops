#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Create-only encrypted run credentials, never a replacement for saved secrets.

Only ciphertext and an immutable ownership receipt touch disk. All operations
require the same private direct-child directory and serialize on its lock.
"""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time
import uuid

VERSION = 1
LIMIT = 65536
FILES = ("credential-lease.pending.gpg", "credential-lease.gpg",
         "credential-lease.retired.gpg")
RECEIPT = "credential-lease.json"
CAPABILITIES = {"version": VERSION, "encryptedOnly": True, "createOnly": True,
                 "conditionalRemoval": True, "plaintextFiles": False,
                 "ownedProcessGroup": True}


def canonical_run(value):
    if str(uuid.UUID(value)) != value:
        raise ValueError("run")
    return value


def private_directory(path):
    path = Path(path)
    if not path.is_absolute() or path != path.resolve():
        raise ValueError("directory")
    for ancestor in (path, *path.parents):
        if ancestor.is_symlink():
            raise ValueError("directory")
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError("directory")
    if stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError("directory")
    return info


def validate_directory(directory):
    base = Path(os.environ.get("AIDEVOPS_TEMP_DIR",
                               str(Path.home() / ".aidevops/.agent-workspace/tmp")))
    private_directory(base)
    directory = Path(directory)
    info = private_directory(directory)
    if directory.parent != base or directory == base:
        raise ValueError("directory")
    # Even a private directory inside a checkout must never hold credentials.
    result = subprocess.run(["git", "-C", str(directory), "rev-parse", "--git-dir"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            timeout=5, check=False)
    if result.returncode == 0:
        raise ValueError("directory")
    return directory, info


@contextlib.contextmanager
def locked(directory):
    directory, info = validate_directory(directory)
    descriptor = os.open(directory / ".credential-lease.lock",
                         os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        lock_info = os.fstat(descriptor)
        if (not stat.S_ISREG(lock_info.st_mode) or lock_info.st_uid != os.getuid()
                or stat.S_IMODE(lock_info.st_mode) != 0o600 or lock_info.st_nlink != 1):
            raise ValueError("lock")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        current = private_directory(directory)
        if (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
            raise ValueError("directory")
        yield directory, info
    finally:
        os.close(descriptor)


def read_private(path, limit=LIMIT * 4):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > limit):
            raise ValueError("file")
        data = os.read(descriptor, limit + 1)
        if len(data) > limit or len(data) != info.st_size:
            raise ValueError("file")
        return data, info
    finally:
        os.close(descriptor)


def exclusive_write(path, data):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as output:
            output.write(data)
            output.flush()
            os.fsync(descriptor)
        return os.fstat(descriptor)
    finally:
        os.close(descriptor)


def validate_values(values):
    if not isinstance(values, dict) or not 1 <= len(values) <= 16:
        raise ValueError("values")
    for name, value in values.items():
        if (not re.fullmatch(r"[A-Z][A-Z0-9_]{0,95}", name)
                or not isinstance(value, str) or not value or "\0" in value
                or name in {"PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "ENV", "GNUPGHOME",
                            "SHELLOPTS", "GCONV_PATH"}
                or re.match(r"(?:LD_|DYLD_|NODE_|PYTHON|BASH_|AIDEVOPS_)", name)):
            raise ValueError("values")
    if len(json.dumps(values).encode()) > LIMIT:
        raise ValueError("values")
    return values


def crypt(data, recipient=None):
    args = ["gpg", "--batch", "--no-tty", "--pinentry-mode", "error", "--no-auto-key-retrieve",
            "--auto-key-locate", "clear"]
    args += ["--recipient", recipient, "--encrypt"] if recipient else ["--decrypt"]
    # Never generate/import keys, relax trust, or print GPG diagnostics.
    result = subprocess.run(args, input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, timeout=30, check=False)
    if result.returncode or not result.stdout or len(result.stdout) > LIMIT * 4:
        raise ValueError("crypto")
    return result.stdout


def seal(directory, run_id, recipient, values):
    canonical_run(run_id)
    if not re.fullmatch(r"(?:[A-F0-9]{40}|[A-F0-9]{64})", recipient):
        raise ValueError("recipient")
    validate_values(values)
    with locked(directory) as (root, owner):
        if any(os.path.lexists(root / name) for name in (*FILES, RECEIPT)):
            raise ValueError("collision")
        envelope = json.dumps({"version": VERSION, "runId": run_id,
                               "recipient": recipient, "values": values}).encode()
        ciphertext = crypt(envelope, recipient)
        pending = root / FILES[0]
        identity = exclusive_write(pending, ciphertext)
        receipt = {"version": VERSION, "runId": run_id, "recipient": recipient,
                   "directoryDevice": owner.st_dev, "directoryInode": owner.st_ino,
                   "device": identity.st_dev, "inode": identity.st_ino,
                   "sha256": hashlib.sha256(ciphertext).hexdigest(),
                   "names": sorted(values)}
        exclusive_write(root / RECEIPT, json.dumps(receipt).encode())
        # Atomic no-clobber publication. A crash leaves recoverable ciphertext,
        # never plaintext; an existing destination is never overwritten.
        os.link(pending, root / FILES[1], follow_symlinks=False)
        os.unlink(pending)
    return {"status": "sealed", "version": VERSION}


def receipt_for(root, owner, run_id):
    canonical_run(run_id)
    data, _info = read_private(root / RECEIPT)
    receipt = json.loads(data)
    keys = {"version", "runId", "recipient", "directoryDevice", "directoryInode",
            "device", "inode", "sha256", "names"}
    if (not isinstance(receipt, dict) or set(receipt) != keys
            or receipt["version"] != VERSION or receipt["runId"] != run_id
            or receipt["directoryDevice"] != owner.st_dev
            or receipt["directoryInode"] != owner.st_ino
            or not re.fullmatch(r"[a-f0-9]{64}", receipt["sha256"])
            or not isinstance(receipt["names"], list)):
        raise ValueError("receipt")
    return receipt


def matches(data, info, receipt):
    return ((info.st_dev, info.st_ino) == (receipt["device"], receipt["inode"])
            and hashlib.sha256(data).hexdigest() == receipt["sha256"])


def open_values(directory, run_id):
    with locked(directory) as (root, owner):
        receipt = receipt_for(root, owner, run_id)
        data, info = read_private(root / FILES[1])
        if not matches(data, info, receipt):
            raise ValueError("ownership")
        envelope = json.loads(crypt(data))
        if (set(envelope) != {"version", "runId", "recipient", "values"}
                or envelope["version"] != VERSION or envelope["runId"] != run_id
                or envelope["recipient"] != receipt["recipient"]):
            raise ValueError("envelope")
        values = validate_values(envelope["values"])
        if sorted(values) != receipt["names"]:
            raise ValueError("envelope")
        return values


def remove(directory, run_id):
    with locked(directory) as (root, owner):
        receipt = receipt_for(root, owner, run_id)
        # Check every candidate before removing any. Changed or unknown content
        # remains encrypted and is never accepted as this run's credential.
        for name in FILES:
            if os.path.lexists(root / name):
                data, info = read_private(root / name)
                if not matches(data, info, receipt):
                    raise ValueError("ownership")
        for name in FILES[:2]:
            source, retired = root / name, root / FILES[2]
            if not os.path.lexists(source):
                continue
            if os.path.lexists(retired):
                # A prior interrupted retirement is checked above before removal.
                os.unlink(retired)
            os.rename(source, retired)
            data, info = read_private(retired)
            if not matches(data, info, receipt):
                # Restore without overwriting a concurrently installed object.
                # A failed restoration leaves the ciphertext at the known retired
                # path for reconciliation; never delete mismatched material.
                os.link(retired, source, follow_symlinks=False)
                os.unlink(retired)
                raise ValueError("ownership")
            os.unlink(retired)
        retired = root / FILES[2]
        if os.path.lexists(retired):
            data, info = read_private(retired)
            if not matches(data, info, receipt):
                raise ValueError("ownership")
            os.unlink(retired)
        if any(os.path.lexists(root / name) for name in FILES):
            raise ValueError("cleanup")
    # Retain the immutable, non-secret receipt for idempotent recovery.
    return {"status": "removed", "version": VERSION}


def live_group_members(group):
    """Observe only process identity/state, never environments or command lines."""
    members = []
    for path in Path("/proc").iterdir():
        if not path.name.isdecimal():
            continue
        try:
            fields = (path / "stat").read_text().rsplit(")", 1)[1].split()
        except (FileNotFoundError, ProcessLookupError):
            continue
        if int(fields[2]) == group and fields[0] not in {"Z", "X"}:
            members.append(int(path.name))
    return members


def drain_child(child):
    # The unreaped leader pins the group ID until the final wait: never signal
    # a reused PID/group, and never search or kill by name, prefix or port.
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass  # An already-empty owned group requires no signal.
    deadline = time.monotonic() + 10
    while live_group_members(child.pid) and time.monotonic() < deadline:
        time.sleep(0.1)
    if live_group_members(child.pid):
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    code = child.wait(timeout=5)
    deadline = time.monotonic() + 2
    while live_group_members(child.pid) and time.monotonic() < deadline:
        time.sleep(0.1)
    if live_group_members(child.pid):
        raise ValueError("descendants-unresolved")
    return code


def execute(directory, run_id, command, cwd, budget):
    if not command or not 1 <= budget <= 3600:
        raise ValueError("command")
    if sys.platform != "linux" or sys.version_info < (3, 11):
        raise ValueError("supervision-platform")
    values = open_values(directory, run_id)
    # No dotenv loading or ambient secret inheritance after scoped injection.
    environment = {key: os.environ[key] for key in ("PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "AIDEVOPS_TEMP_DIR")
                   if key in os.environ}
    environment.update(values)
    def interrupted(_number, _frame):
        raise KeyboardInterrupt

    previous = signal.signal(signal.SIGTERM, interrupted)
    child = None
    stopped = False
    try:
        child = subprocess.Popen(command, cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 process_group=0)
        deadline = time.monotonic() + budget
        try:
            while os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None:
                if time.monotonic() >= deadline:
                    stopped = True
                    break
                time.sleep(0.1)
        except KeyboardInterrupt:
            stopped = True
    finally:
        try:
            if child is not None:
                returncode = drain_child(child)
        finally:
            signal.signal(signal.SIGTERM, previous)
    if stopped:
        return {"status": "child-interrupted", "version": VERSION}, 1
    return {"status": "child-passed" if returncode == 0 else "child-failed",
            "version": VERSION}, 0 if returncode == 0 else 1
