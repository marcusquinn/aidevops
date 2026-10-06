#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fail-closed orphan trash retry ledger; state never authorizes removal.

gate PATH: exit 0 permits an attempt, exit 1 skips; stdout is a NEW reason only.
failure PATH: record a trash failure (three reserved attempts), emitting the reason.
clear PATH: forget a successful move. report: list live terminal records and recovery.
Terminal records require explicit operator reset, or a different directory inode.
"""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import stat
import sys
import tempfile


def identity(path):
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode):
        raise ValueError("candidate is not a physical directory")
    return [info.st_dev, info.st_ino]


def foreign_owner(path):
    """lstat entries without following directory/file symlinks or mount points."""
    device = os.lstat(path).st_dev
    pending = [path]
    while pending:
        entry = pending.pop()
        info = os.lstat(entry)
        if info.st_uid != os.getuid():
            return True
        if info.st_dev != device:
            raise ValueError("nested mount requires operator inspection")
        if stat.S_ISDIR(info.st_mode):
            with os.scandir(entry) as children:
                pending.extend(child.path for child in children)
    return False


def load(record):
    if record.is_symlink():
        raise ValueError("symlink ledger record")
    if not record.exists():
        return {}
    data = json.loads(record.read_text())
    if (not isinstance(data, dict) or data.get("schema") != 1
            or not isinstance(data.get("path"), str) or not os.path.isabs(data['path'])
            or not isinstance(data.get("identity"), list) or len(data['identity']) != 2
            or any(type(value) is not int for value in data['identity'])
            or type(data.get("attempts")) is not int or not 0 <= data['attempts'] <= 3
            or type(data.get("terminal")) is not bool
            or data.get("reason") not in ("attempt-reserved", "foreign-owner", "trash-failed", "trash-failed-retry-exhausted")):
        raise ValueError("invalid ledger record")
    return data


def save(record, data):
    fd, temporary = tempfile.mkstemp(dir=record.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, record)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def report(directory):
    if not directory.exists():
        return 0
    validate_directory(directory)
    errors = 0
    for record in sorted(directory.glob("*.json")):
        try:
            data = load(record)
            path = data['path']
        except (OSError, ValueError, KeyError, TypeError):
            print(f"Unreadable orphan cleanup record: {shlex.quote(str(record))}")
            errors = 1
            continue
        try:
            if not data.get("terminal") or identity(path) != data.get("identity"):
                continue
        except (FileNotFoundError, ValueError):
            continue
        except OSError:
            print(f"Unable to inspect orphan cleanup candidate: {shlex.quote(path)}")
            errors = 1
            continue
        print(f"{data['reason']}: {shlex.quote(path)} (attempts={data['attempts']})")
        if data['reason'] == 'foreign-owner':
            print("  After inspecting the preserved directory, repair ownership (operator only):")
            print(f"  sudo find -P {shlex.quote(path)} -xdev ! -uid {os.getuid()} "
                  f"-exec chown -h {os.getuid()}:{os.getgid()} -- '{{}}' +")
        else:
            print("  Inspect permissions, mounts and trash availability; resolve before retrying")
        print(f"  Then reset this record: rm -- {shlex.quote(str(record))}")
    return errors


def validate_directory(directory):
    info = directory.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or info.st_mode & 0o022):
        raise ValueError("unsafe state directory")


def main():
    action = sys.argv[1]
    directory = Path(os.environ.get("PULSE_STATE_DIR", str(Path.home() / ".aidevops/.agent-workspace/pulse"))) / "orphan-trash-failures"
    if action == "report":
        return report(directory)
    path = os.path.abspath(sys.argv[2])
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    validate_directory(directory)
    digest = hashlib.sha256(os.fsencode(path)).hexdigest()
    record = directory / (digest + ".json")
    # Serialize state writers across pulse invocations; never follow a lock symlink.
    fd = os.open(directory / (digest + ".lock"), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if action == "clear":
            record.unlink(missing_ok=True)
            return 0
        current = identity(path)
        data = load(record)
        if data.get("path") != path or data.get("identity") != current:
            data = {"schema": 1, "path": path, "identity": current, "attempts": 0, "terminal": False}
        if data.get("terminal"):
            return 1
        if action == "gate":
            if data['attempts'] >= 3:
                data.update(reason="trash-failed-retry-exhausted", terminal=True)
            elif foreign_owner(path):
                data.update(reason="foreign-owner", terminal=True)
            else:
                # Persist the budget BEFORE trash. Concurrent gates and interrupted
                # attempts cannot exceed the cap or retry on an unwritable ledger.
                data['attempts'] += 1
                data.update(reason="attempt-reserved")
                save(record, data)
                return 0
        elif action == "failure":
            data.update(reason="trash-failed", terminal=data['attempts'] >= 3)
            if data['terminal']:
                data['reason'] = "trash-failed-retry-exhausted"
        else:
            raise ValueError("unknown action")
        save(record, data)
        print(data['reason'])
        return 1 if action == "gate" else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, IndexError):
        print("orphan-trash-state-unavailable")
        sys.exit(1)
