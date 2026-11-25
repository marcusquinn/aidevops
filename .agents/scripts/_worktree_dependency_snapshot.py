# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded no-follow traversal of inventory-backed dependency sources."""

import hashlib
import ctypes
import errno
import fcntl
import os
import re
from pathlib import Path
import stat
from contextlib import ExitStack, contextmanager

from _worktree_dependency_identity import Rejected, contained_path, object_json, open_directory, regular_bytes, trusted


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


def metadata_entry(name, mode):
    if name in {".bin", ".pnpm"}:
        return stat.S_ISDIR(mode)
    files = {".package-lock.json", ".modules.yaml", ".pnpm-workspace-state-v1.json"}
    return name in files and stat.S_ISREG(mode)


def package_position(path):
    return path.parent.name == "node_modules" or (
        path.parent.name.startswith("@") and path.parent.parent.name == "node_modules")


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


class Snapshot:
    """One bounded traversal with pinned source and destination descriptors."""

    def __init__(self, root, max_bytes, max_entries, inventory):
        self.root = contained_path(root)
        self.max_bytes = max_bytes
        self.max_entries = max_entries
        self.inventory = inventory
        self.total = 0
        self.count = 0
        self.records = {}
        self.seen_packages = set()
        self.workspace = bool(inventory and inventory[0] == "workspace")
        self.boundary = inventory[2] if self.workspace else self.root
        self.logical_root = inventory[3] if self.workspace else self.root
        self.fallback_bytes = 0

    def walk(self, fd, relative, output, depth=0):
        trusted(os.fstat(fd))
        if depth > 64:
            raise Rejected("depth-budget-exceeded")
        with os.scandir(fd) as entries:
            for entry in entries:
                self.visit(fd, relative / entry.name, output, entry.stat(follow_symlinks=False), depth)

    def visit(self, fd, rel, output, info, depth):
        if skipped_root_entry(rel, info.st_mode):
            # Interrupted pnpm staging directories and root markers/caches: neither counted,
            # copied nor inventoried, so source and staged snapshots keep identical digests.
            return
        self.count += 1
        if self.count > (2000000 if self.workspace else self.max_entries):
            raise Rejected("entry-budget-exceeded")
        safe_entry_name(rel.name)
        self.check_package_root(rel, info.st_mode)
        if stat.S_ISLNK(info.st_mode):
            self.copy_link(fd, rel, output)
        elif stat.S_ISDIR(info.st_mode):
            self.copy_directory(fd, rel, output, depth)
        elif stat.S_ISREG(info.st_mode):
            self.copy_file(fd, rel, output)
        else:
            raise Rejected("special-file")

    def resolved_inside(self, rel):
        try:
            candidate = self.root / rel
            if self.workspace and candidate.is_symlink():
                target = os.readlink(candidate)
                if os.path.isabs(target):
                    raise Rejected("escaping-dependency-link")
                candidate = self.logical_root / rel.parent / target
            elif self.workspace:
                candidate = self.logical_root / rel
            resolved = candidate.resolve(strict=True)
        except (FileNotFoundError, NotADirectoryError):
            raise Rejected("dangling-dependency-link") from None
        if not resolved.is_relative_to(self.boundary):
            raise Rejected("escaping-package-root")
        return resolved

    def inventory_key(self, package_path, manifest):
        if self.inventory[0] == "npm":
            key = str(package_path)
        else:
            key = f"{manifest.get('name')}@{manifest.get('version')}"
        if key not in self.inventory[1]:
            raise Rejected("unrecorded-package")
        return key

    def check_package_root(self, rel, mode):
        package_root = Path("node_modules") / rel
        if not self.inventory or not resolution_root(package_root, mode):
            return
        if not (stat.S_ISDIR(mode) or stat.S_ISLNK(mode)):
            raise Rejected("unrecorded-module-file")
        manifest = object_json(regular_bytes(self.resolved_inside(rel) / "package.json"))
        self.inventory_key(package_root, manifest)

    def copy_link(self, fd, rel, output):
        target = os.readlink(rel.name, dir_fd=fd)
        if os.path.isabs(target):
            raise Rejected("escaping-dependency-link")
        try:
            self.resolved_inside(rel)
        except Rejected as error:
            # A dangling .bin link is dangling in the source too; copy it as-is
            # only when its lexical target stays inside the dependency root.
            lexical = os.path.normpath(os.path.join(str(rel.parent), target))
            if (str(error) != "dangling-dependency-link" or rel.parent.name != ".bin"
                    or lexical == ".." or lexical.startswith("../")):
                raise
        self.records[str(rel)] = b"link\0" + target.encode()
        if output is not None:
            os.symlink(target, rel.name, dir_fd=output)

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

    def scan(self, copy_to):
        with ExitStack() as stack:
            fd = stack.enter_context(open_directory(self.root))
            output_fd = None
            if copy_to is not None:
                output_fd = stack.enter_context(open_directory(copy_to))
                trusted(os.fstat(output_fd))
            self.walk(fd, Path(), output_fd)
        if self.count == 0:
            raise Rejected("missing-dependencies")
        if self.inventory and not self.workspace and self.seen_packages != self.inventory[1]:
            raise Rejected("incomplete-package-inventory")
        if self.workspace and self.logical_root == self.boundary / "node_modules":
            if not self.inventory[4].issubset(self.seen_packages):
                raise Rejected("incomplete-package-inventory")
        digest = hashlib.sha256()
        for name, value in sorted(self.records.items()):
            digest.update(name.encode() + b"\0" + value)
        return f"{digest.hexdigest()} {self.total} {self.count}"


def snapshot(root, max_bytes, max_entries, copy_to=None, inventory=None):
    return Snapshot(root, max_bytes, max_entries, inventory).scan(copy_to)


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
            target = os.open(name, os.O_WRONLY | os.O_NOFOLLOW, dir_fd=output)
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
