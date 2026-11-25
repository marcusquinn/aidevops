# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Descriptor-pinned dependency payload copies and bounded CoW fallback."""

import ctypes
import errno
import fcntl
import hashlib
import os
from pathlib import Path
import re
import stat
from contextlib import ExitStack, contextmanager

from _worktree_dependency_identity import Rejected, object_json, regular_bytes, trusted


STALE_STAGING = re.compile(r"^.+_tmp_\d+$")
# Non-module entries that macOS and build tools create at the dependency root
# (GH#39037). They are skipped, never copied, so a worker cannot resolve them; any
# other unrecorded entry, or one of these names with another type, still rejects.
SKIPPED_ROOT_FILES = {".metadata_never_index", ".DS_Store"}
SKIPPED_ROOT_DIRECTORIES = {".vite", ".vite-temp", ".cache"}


def skipped_root_entry(rel, mode):
    if len(rel.parts) != 1:
        return False
    if stat.S_ISDIR(mode):
        return bool(STALE_STAGING.match(rel.name)) or rel.name in SKIPPED_ROOT_DIRECTORIES
    return stat.S_ISREG(mode) and rel.name in SKIPPED_ROOT_FILES


def safe_entry_name(name):
    lower = name.lower()
    sensitive = {".git", ".ssh", ".aws", ".npmrc", ".netrc", ".pypirc", "credentials.json"}
    if lower in sensitive or lower.startswith(".env") or lower.endswith((".pem", ".key", ".p12", ".pfx")):
        raise Rejected("credential-bearing-path")


def package_position(path):
    return path.parent.name == "node_modules" or (
        path.parent.name.startswith("@") and path.parent.parent.name == "node_modules")


def metadata_entry(name, mode):
    if name in {".bin", ".pnpm"}:
        return stat.S_ISDIR(mode)
    files = {".package-lock.json", ".modules.yaml", ".pnpm-workspace-state-v1.json"}
    return name in files and stat.S_ISREG(mode)


def resolution_root(path, mode):
    namespace = path.name.startswith("@") and stat.S_ISDIR(mode)
    if path.parent.name == "node_modules":
        return not (namespace or metadata_entry(path.name, mode))
    return package_position(path)


@contextmanager
def directory_at(parent, name):
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    try:
        yield fd
    finally:
        os.close(fd)


class PayloadCopies:
    """Copy operations using the traversal's budgets and inventory records."""

    def copy_directory(self, fd, rel, output, depth):
        with ExitStack() as stack:
            child = stack.enter_context(directory_at(fd, rel.name))
            target = None
            if output is not None:
                os.mkdir(rel.name, mode=0o755, dir_fd=output)
                target = stack.enter_context(directory_at(output, rel.name))
            self.records[str(rel)] = b"dir\0"
            self.walk(child, rel, target, depth + 1)

    def read_payload(self, fd, name):
        source_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        with os.fdopen(source_fd, "rb") as source:
            before = os.fstat(source_fd)
            trusted(before)
            if not stat.S_ISREG(before.st_mode) or before.st_size > self.max_bytes - self.total:
                raise Rejected("byte-budget-exceeded")
            data = source.read(self.max_bytes - self.total + 1)
            self.total += len(data)
            after = os.fstat(source_fd)
            if self.total > self.max_bytes or (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                raise Rejected("changed-or-oversized-source")
        return data, before.st_mode & 0o755

    def record_package(self, rel, data):
        package_path = Path("node_modules") / rel.parent
        if self.inventory and rel.name == "package.json" and package_position(package_path):
            key = self.inventory_key(package_path, object_json(data))
            self.seen_packages.add(key)

    def copy_file(self, fd, rel, output):
        if self.workspace:
            self.clone_file(fd, rel, output)
            return
        data, mode = self.read_payload(fd, rel.name)
        self.record_package(rel, data)
        self.records[str(rel)] = b"file\0" + str(mode).encode() + hashlib.sha256(data).digest()
        if output is None:
            return
        destination_fd = os.open(rel.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                 0o600, dir_fd=output)
        with os.fdopen(destination_fd, "wb") as destination:
            destination.write(data)
            os.fchmod(destination_fd, mode)

    def clone_file(self, fd, rel, output):
        """Use pinned descriptors for CoW; unsupported clones use bounded copies."""
        with os.fdopen(os.open(rel.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                               dir_fd=fd), "rb") as source:
            before = os.fstat(source.fileno())
            trusted(before)
            if not stat.S_ISREG(before.st_mode):
                raise Rejected("special-file")
            mode = before.st_mode & 0o755
            target = None
            digest = hashlib.sha256()
            try:
                cloned = False
                if output is not None:
                    target, cloned = clone_descriptor(source.fileno(), output, rel.name)
                while chunk := source.read(1024 * 1024):
                    digest.update(chunk)
                    if output is not None and not cloned:
                        self.fallback_bytes += len(chunk)
                        if self.fallback_bytes > self.max_bytes:
                            raise Rejected("byte-budget-exceeded")
                        with os.fdopen(os.dup(target), "wb") as destination:
                            destination.write(chunk)
                if target is not None:
                    os.fchmod(target, mode)
            finally:
                if target is not None:
                    os.close(target)
            after = os.fstat(source.fileno())
            if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                    after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                raise Rejected("changed-or-oversized-source")
            self.total += before.st_size
            if rel.name == "package.json" and package_position(Path("node_modules") / rel.parent):
                self.record_package(rel, regular_bytes(self.root / rel))
            self.records[str(rel)] = b"file\0" + str(mode).encode() + digest.digest()


def clone_descriptor(source, output, name):
    """macOS clonefile and Linux FICLONE never share writable hardlinks."""
    target = None
    try:
        if os.uname().sysname == "Darwin":
            clone = getattr(ctypes.CDLL(None, use_errno=True), "fclonefileat", None)
            if clone is None:
                raise OSError(errno.ENOTSUP, "clone unavailable")
            clone.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
            clone.restype = ctypes.c_int
            if clone(source, output, os.fsencode(name), 0):
                raise OSError(ctypes.get_errno(), "clone refused")
            target = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=output)
        else:
            target = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=output)
            fcntl.ioctl(target, 0x40049409, source)  # Linux FICLONE
        return target, True
    except OSError as error:
        if error.errno not in {errno.ENOTSUP, errno.EOPNOTSUPP, errno.ENOTTY,
                              errno.EXDEV, errno.EINVAL, errno.ENOSYS}:
            if target is not None:
                os.close(target)
            raise
        if target is None:
            target = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=output)
        return target, False
