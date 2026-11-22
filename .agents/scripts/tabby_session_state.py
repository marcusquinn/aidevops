# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Local-account leases: permanent lock inodes, bounded pending launch tokens."""

import contextlib
import fcntl
import hashlib
import json
import os
import secrets
import stat
import time
from pathlib import Path

from tabby_session_config import SessionError
from tabby_session_legacy import local_managed

PENDING_SECONDS = 120


def state_directory(path, create=True):
    """Walk with openat/O_NOFOLLOW; no symlink ancestor or lock-file traversal."""
    path = Path(path).absolute()
    fd = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            if create:
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise SessionError("State directory must be privately owned (mode 0700)")
        return fd
    except BaseException:
        os.close(fd)
        raise


def state_key(endpoint_id, session):
    identity = [endpoint_id, session["server"], session["created"], session["sid"]]
    return hashlib.sha256(json.dumps(identity).encode()).hexdigest()


class Lease:
    def __init__(self, directory, key, create=True):
        flags = os.O_RDWR | os.O_NOFOLLOW | (os.O_CREAT if create else 0)
        self.fd = os.open(key + ".lock", flags, 0o600, dir_fd=directory)
        info = os.fstat(self.fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_nlink != 1:
            os.close(self.fd)
            raise SessionError("Unsafe attachment lock")
        self.held = False

    def acquire(self):
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.held = True
        except BlockingIOError:
            self.held = False
        return self.held

    def read(self):
        try:
            os.lseek(self.fd, 0, os.SEEK_SET)
            value = json.loads(os.read(self.fd, 8192))
            if not isinstance(value, dict):
                return {}
            for field in ("phase", "token", "remote_pid"):
                if field in value and not isinstance(value[field], str):
                    return {}
            if "expires" in value and type(value["expires"]) not in (int, float):
                return {}
            return value
        except (ValueError, OSError):
            return {}

    def write(self, value):
        if not self.held:
            raise SessionError("Attachment lease is not held")
        payload = json.dumps(value).encode()
        os.lseek(self.fd, 0, os.SEEK_SET)
        os.write(self.fd, payload)
        os.ftruncate(self.fd, len(payload))

    def observe(self, clients, sid):
        if not self.acquire():
            value = self.read()
            return "connected" if (value.get("remote_pid"), sid) in clients else "pending"
        value = self.read()
        if not value and os.fstat(self.fd).st_size:
            raise SessionError("Unreadable attachment state; refusing duplicate-risk launch")
        if value.get("phase") == "attaching" and local_managed(value.get("token")):
            return "connected" if (value.get("remote_pid"), sid) in clients else "pending"
        if value.get("phase") == "pending" and value.get("expires", 0) > time.time():
            return "pending"
        return "missing"

    def reserve(self):
        token = secrets.token_hex(24)
        self.write({"phase": "pending", "token": token, "expires": time.time() + PENDING_SECONDS})
        return token

    def claim(self, token):
        if not self.acquire():
            return False
        value = self.read()
        if value.get("phase") != "pending" or value.get("token") != token or value.get("expires", 0) <= time.time():
            return False
        self.write({"phase": "attaching", "token": token})
        return True

    def close(self):
        os.close(self.fd)


@contextlib.contextmanager
def lease(directory, key, create=True):
    handle = Lease(directory, key, create)
    try:
        yield handle
    finally:
        handle.close()
