# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded no-follow traversal of inventory-backed dependency sources."""

import hashlib
import os
from pathlib import Path
import stat
from contextlib import ExitStack

from _worktree_dependency_closure import check_closure
from _worktree_dependency_identity import Rejected, contained_path, object_json, open_directory, regular_bytes, trusted
from _worktree_dependency_payload import (
    PayloadCopies, resolution_root, safe_entry_name, skipped_root_entry,
)


class Snapshot(PayloadCopies):
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
                destination = self.inventory[5]
                eventual = destination / self.logical_root.relative_to(self.boundary) / rel.parent / target
                if not eventual.resolve().is_relative_to(destination):
                    raise Rejected("escaping-worktree-link")
            elif self.workspace:
                candidate = self.logical_root / rel
            resolved = candidate.resolve(strict=True)
        except (FileNotFoundError, NotADirectoryError):
            raise Rejected("dangling-dependency-link") from None
        if not resolved.is_relative_to(self.boundary):
            raise Rejected("escaping-package-root")
        if self.workspace:
            relative = resolved.relative_to(self.boundary)
            for part in relative.parts:
                safe_entry_name(part)
            destination = self.inventory[5]
            if not (destination / relative).resolve().is_relative_to(destination):
                raise Rejected("escaping-worktree-link")
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
        if self.workspace:
            # Lock inventories also contain optional packages for other platforms.
            # Require this importer's entry points instead of every lock package.
            for dependency in self.inventory[4]:
                rel = Path(dependency)
                if not os.path.lexists(self.root / rel):
                    raise Rejected("incomplete-package-inventory")
                self.check_package_root(rel, (self.root / rel).lstat().st_mode)
                check_closure(self.resolved_inside(rel), set(), self.boundary)
        digest = hashlib.sha256()
        for name, value in sorted(self.records.items()):
            digest.update(name.encode() + b"\0" + value)
        return f"{digest.hexdigest()} {self.total} {self.count}"


def snapshot(root, max_bytes, max_entries, copy_to=None, inventory=None):
    return Snapshot(root, max_bytes, max_entries, inventory).scan(copy_to)
