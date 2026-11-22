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
import shutil
import signal
import stat
import subprocess
import sys
import time
import uuid

from credential_lease_owned import assert_owned_ancestor, owned_child_output as _owned_child_output
from credential_lease_protocol import (
    LIMIT, closed_json as _closed_json, read_configuration as _read_configuration,
    require, validate_contract, validate_values)

VERSION = 1
FILES = ("credential-lease.pending.gpg", "credential-lease.gpg",
         "credential-lease.retired.gpg")
RECEIPT = "credential-lease.json"
CAPABILITIES = {"version": VERSION, "encryptedOnly": True, "createOnly": True,
                 "conditionalRemoval": True, "plaintextFiles": False,
                 "ownedProcessGroup": True, "scopedOwnedExecution": True}


def executable(name):
    path = shutil.which(name)
    require(path, "executable")
    return os.path.abspath(path)


def canonical_run(value):
    require(str(uuid.UUID(value)) == value, "run")
    return value


def private_directory(path):
    path = Path(path)
    require(path.is_absolute(), "directory")
    require(path == path.resolve(), "directory")
    for ancestor in (path, *path.parents):
        require(not ancestor.is_symlink(), "directory")
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode), "directory")
    require(info.st_uid == os.getuid(), "directory")
    require(stat.S_IMODE(info.st_mode) == 0o700, "directory")
    return info


def validate_directory(directory):
    base = Path(os.environ.get("AIDEVOPS_TEMP_DIR",
                               str(Path.home() / ".aidevops/.agent-workspace/tmp")))
    private_directory(base)
    directory = Path(directory)
    info = private_directory(directory)
    require(directory.parent == base, "directory")
    require(directory != base, "directory")
    # Even a private directory inside a checkout must never hold credentials.
    # Only a resolved local Git binary and constant inspection arguments; no shell.
    result = subprocess.run(  # nosec B603 -- local executable, argv-only read-only inspection
                            [executable("git"), "-C", str(directory), "rev-parse", "--git-dir"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            timeout=5, check=False)
    require(result.returncode != 0, "directory")
    return directory, info


@contextlib.contextmanager
def locked(directory):
    directory, info = validate_directory(directory)
    descriptor = os.open(directory / ".credential-lease.lock",
                         os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        lock_info = os.fstat(descriptor)
        require(stat.S_ISREG(lock_info.st_mode), "lock")
        require(lock_info.st_uid == os.getuid(), "lock")
        require(stat.S_IMODE(lock_info.st_mode) == 0o600, "lock")
        require(lock_info.st_nlink == 1, "lock")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        current = private_directory(directory)
        require((current.st_dev, current.st_ino) == (info.st_dev, info.st_ino), "directory")
        yield directory, info
    finally:
        os.close(descriptor)


def read_private(path, limit=LIMIT * 4):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode), "file")
        require(info.st_uid == os.getuid(), "file")
        require(stat.S_IMODE(info.st_mode) == 0o600, "file")
        require(info.st_size <= limit, "file")
        data = os.read(descriptor, limit + 1)
        require(len(data) <= limit, "file")
        require(len(data) == info.st_size, "file")
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


def crypt(data, recipient=None):
    args = [executable("gpg"), "--batch", "--no-tty", "--pinentry-mode", "error", "--no-auto-key-retrieve",
            "--auto-key-locate", "clear"]
    args += ["--recipient", recipient, "--encrypt"] if recipient else ["--decrypt"]
    # Never generate/import keys, relax trust, or print GPG diagnostics.
    result = subprocess.run(  # nosec B603 -- resolved GPG, fixed flags, validated recipient, no shell
                            args, input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, timeout=30, check=False)
    require(result.returncode == 0, "crypto")
    require(result.stdout, "crypto")
    require(len(result.stdout) <= LIMIT * 4, "crypto")
    return result.stdout


def seal(directory, run_id, recipient, values):
    canonical_run(run_id)
    require(re.fullmatch(r"(?:[A-F0-9]{40}|[A-F0-9]{64})", recipient), "recipient")
    validate_values(values)
    with locked(directory) as (root, owner):
        require(not any(os.path.lexists(root / name) for name in (*FILES, RECEIPT)), "collision")
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
    require(isinstance(receipt, dict), "receipt")
    require(set(receipt) == keys, "receipt")
    require(receipt["version"] == VERSION, "receipt")
    require(receipt["runId"] == run_id, "receipt")
    require(receipt["directoryDevice"] == owner.st_dev, "receipt")
    require(receipt["directoryInode"] == owner.st_ino, "receipt")
    require(re.fullmatch(r"[a-f0-9]{64}", receipt["sha256"]), "receipt")
    require(isinstance(receipt["names"], list), "receipt")
    return receipt


def matches(data, info, receipt):
    return ((info.st_dev, info.st_ino) == (receipt["device"], receipt["inode"])
            and hashlib.sha256(data).hexdigest() == receipt["sha256"])


def open_values(directory, run_id):
    with locked(directory) as (root, owner):
        receipt = receipt_for(root, owner, run_id)
        data, info = read_private(root / FILES[1])
        require(matches(data, info, receipt), "ownership")
        envelope = json.loads(crypt(data))
        require(set(envelope) == {"version", "runId", "recipient", "values"}, "envelope")
        require(envelope["version"] == VERSION, "envelope")
        require(envelope["runId"] == run_id, "envelope")
        require(envelope["recipient"] == receipt["recipient"], "envelope")
        values = validate_values(envelope["values"])
        require(sorted(values) == receipt["names"], "envelope")
        return values


def retire_ciphertext(root, name, receipt):
    source, retired = root / name, root / FILES[2]
    if not os.path.lexists(source):
        return
    if os.path.lexists(retired):
        # A prior interrupted retirement was checked before any removal.
        os.unlink(retired)
    os.rename(source, retired)
    data, info = read_private(retired)
    if not matches(data, info, receipt):
        # Restore without overwriting a concurrently installed object. A failed
        # restoration leaves ciphertext at the known path for reconciliation.
        os.link(retired, source, follow_symlinks=False)
        os.unlink(retired)
        raise ValueError("ownership")
    os.unlink(retired)


def remove(directory, run_id):
    with locked(directory) as (root, owner):
        receipt = receipt_for(root, owner, run_id)
        # Check every candidate before removing any. Changed or unknown content
        # remains encrypted and is never accepted as this run's credential.
        for name in FILES:
            if os.path.lexists(root / name):
                data, info = read_private(root / name)
                require(matches(data, info, receipt), "ownership")
        for name in FILES[:2]:
            retire_ciphertext(root, name, receipt)
        retired = root / FILES[2]
        if os.path.lexists(retired):
            data, info = read_private(retired)
            require(matches(data, info, receipt), "ownership")
            os.unlink(retired)
        require(not any(os.path.lexists(root / name) for name in FILES), "cleanup")
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
    require(not live_group_members(child.pid), "descendants-unresolved")
    return code


def execute(directory, run_id, command, cwd, budget):
    require(command, "command")
    require(1 <= budget <= 3600, "command")
    require(sys.platform == "linux", "supervision-platform")
    require(sys.version_info >= (3, 11), "supervision-platform")
    values = open_values(directory, run_id)
    # No dotenv loading or ambient secret inheritance after scoped injection.
    environment = {key: os.environ[key] for key in ("PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "AIDEVOPS_TEMP_DIR")
                   if key in os.environ}
    environment.update(values)
    received = []

    def record(number, _frame):
        # Record stop requests instead of raising, so a repeated SIGTERM/SIGINT
        # can never abort the owned-group drain and strand secret-bearing children.
        received.append(number)

    previous = {number: signal.signal(number, record) for number in (signal.SIGTERM, signal.SIGINT)}
    child = None
    stopped = False
    try:
        # This API intentionally executes the trusted local caller's argv, never
        # shell text; secret injection, output and process lifetime are confined.
        child = subprocess.Popen(  # nosec B603 -- explicit local argv-only execution contract
                                 command, cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 process_group=0)
        deadline = time.monotonic() + budget
        while os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None:
            if received or time.monotonic() >= deadline:
                stopped = True
                break
            time.sleep(0.1)
    finally:
        try:
            if child is not None:
                returncode = drain_child(child)
        finally:
            for number, handler in previous.items():
                signal.signal(number, handler)
    if stopped or received:
        return {"status": "child-interrupted", "version": VERSION}, 1
    return {"status": "child-passed" if returncode == 0 else "child-failed",
            "version": VERSION}, 0 if returncode == 0 else 1


def _execution_contract(directory, run_id, path, digest):
    """Pin a private, non-secret set of exact outputs; never learn labels from stdout."""
    require(re.fullmatch(r"[a-f0-9]{64}", digest), "contract")
    with locked(directory) as (root, owner):
        receipt_for(root, owner, run_id)
        path = Path(path)
        require(path.is_absolute() and path.parent == root and path == path.resolve(), "contract")
        data, info = read_private(path, LIMIT)
        require(info.st_nlink == 1, "contract")
        require(hashlib.sha256(data).hexdigest() == digest, "contract")
    return validate_contract(_closed_json(data))


def execute_owned(directory, run_id, command, options):
    """Reinject inside an existing bounded owner; never create/claim another group."""
    cwd, budget, names = options["cwd"], options["budget"], options["names"]
    owner_pid, owner_started = options["ownerPid"], options["ownerStarted"]
    contract_path, contract_digest = options["contract"], options["contractDigest"]
    configuration_fd = options["configurationFd"]
    require(command and 1 <= budget <= 3600, "command")
    require(sys.version_info >= (3, 11), "supervision-platform")
    assert_owned_ancestor(owner_pid, owner_started)
    require(isinstance(names, list) and 1 <= len(names) <= 16, "names")
    require(all(isinstance(name, str) for name in names) and len(set(names)) == len(names), "names")
    for name in names:
        validate_values({name: "selected-name-placeholder"})
    contract = _execution_contract(directory, run_id, contract_path, contract_digest)
    require(not set(names).intersection(contract["configurationNames"]), "configuration")
    configuration = _read_configuration(configuration_fd, contract["configurationNames"])
    received = []

    def record(number, _frame):
        received.append(number)

    previous = {number: signal.signal(number, record) for number in (signal.SIGTERM, signal.SIGINT)}
    try:
        values = open_values(directory, run_id)
        require(set(names).issubset(values), "names")
        assert_owned_ancestor(owner_pid, owner_started)
        if received:
            return {"status": "owned-child-unverified", "version": VERSION}, 1
        environment = {key: os.environ[key] for key in
                       ("PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "AIDEVOPS_TEMP_DIR")
                       if key in os.environ}
        environment.update(configuration)
        environment.update({name: values[name] for name in names})
        data, code = _owned_child_output(command, cwd, environment, budget, received)
        if data is not None and not received:
            try:
                result = _closed_json(data)
                # Compare canonical JSON, not Python's True == 1 equality.
                encoded = json.dumps(result, sort_keys=True, separators=(",", ":"))
                for allowed in contract["results"]:
                    expected = json.dumps(allowed["value"], sort_keys=True, separators=(",", ":"))
                    if code == allowed["exitCode"] and encoded == expected:
                        assert_owned_ancestor(owner_pid, owner_started)
                        return {"status": "owned-child-result", "version": VERSION,
                                "result": allowed["value"], "exitCode": code}, 0
            except (ValueError, TypeError, UnicodeError, RecursionError):
                pass  # Never forward output, parse errors, or decoder context.
        return {"status": "owned-child-unverified", "version": VERSION}, 1
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
