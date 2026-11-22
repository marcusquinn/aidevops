# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Read-only filesystem guards for historical-markdown-archive.py.

Every read refuses symlinks and non-regular files and detects replacement
between stat and open. Nothing here writes, renames or deletes.
"""

import os
import stat

from _historical_markdown_manifest import ArchiveError, describe, record_of

SOURCE_SUFFIXES = (".md", ".markdown")


def read_regular_file(path, what, dir_fd=None):
    """Read a regular non-symlink file; return (bytes, fstat result)."""
    try:
        before = os.stat(path, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        raise ArchiveError(f"{what} not found: {path}") from None
    if stat.S_ISLNK(before.st_mode):
        raise ArchiveError(f"{what} must not be a symlink: {path}")
    if not stat.S_ISREG(before.st_mode):
        raise ArchiveError(f"{what} is not a regular file: {path}")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dir_fd)
    with os.fdopen(fd, "rb") as handle:
        opened = os.fstat(handle.fileno())
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise ArchiveError(f"{what} was replaced while opening: {path}")
        return handle.read(), opened


def paths_overlap(first, second):
    first, second = os.path.realpath(first), os.path.realpath(second)
    common = os.path.commonpath([first, second])
    return common in (first, second)


def check_source(source):
    if not source.lower().endswith(SOURCE_SUFFIXES):
        raise ArchiveError(f"source must be a Markdown file ({', '.join(SOURCE_SUFFIXES)}): {source}")
    return read_regular_file(source, "source")


def resolve_destination(source, dest):
    """Return (real parent directory, new entry name) for a not-yet-existing dest."""
    dest_abs = os.path.abspath(dest)
    name = os.path.basename(dest_abs)
    if name in ("", ".", ".."):
        raise ArchiveError(f"destination must name a new directory: {dest}")
    if os.path.lexists(dest_abs):
        raise ArchiveError(f"destination already exists (refusing to overwrite): {dest}")
    parent = os.path.realpath(os.path.dirname(dest_abs))
    if not os.path.isdir(parent):
        raise ArchiveError(f"destination parent is not an existing directory: {parent}")
    if paths_overlap(source, os.path.join(parent, name)):
        raise ArchiveError("source and destination overlap")
    return parent, name


def ensure_source_unchanged(snapshot):
    """snapshot is (source path, stat captured at first read, source record)."""
    source, captured_stat, record = snapshot
    data, current = read_regular_file(source, "source")
    same_file = (current.st_dev, current.st_ino) == (captured_stat.st_dev, captured_stat.st_ino)
    if not same_file or describe(data) != record_of(record):
        raise ArchiveError("source changed during archiving; nothing was published")


def stat_identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)


def compare_original(original, payload):
    """Require byte equality with original and no change while it was read."""
    data, opened = read_regular_file(original, "original")
    if data != payload:
        offset = next((i for i, (a, b) in enumerate(zip(data, payload)) if a != b),
                      min(len(data), len(payload)))
        raise ArchiveError(f"original differs from the reconstruction at byte offset {offset}")
    if stat_identity(os.stat(original, follow_symlinks=False)) != stat_identity(opened):
        raise ArchiveError("original changed during verification")
