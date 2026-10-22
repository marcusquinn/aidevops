#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Filesystem evidence: Git owns tracked state, tar owns untracked files."""

import hashlib
import json
import os
from pathlib import Path
import stat
import tarfile


def unreadable_directory(error):
    raise error


def supported_metadata(observed, attributes, tar_metadata=False):
    if observed.st_uid != os.geteuid() or observed.st_gid != os.getegid() or attributes:
        raise ValueError("ownership, ACLs or extended attributes require separate preservation")
    if tar_metadata and stat.S_ISREG(observed.st_mode):
        return  # PAX retains permissions; external inode relationships are not archived.
    directory = stat.S_ISDIR(observed.st_mode)
    allowed = (0o755,) if directory else ((0o777,) if stat.S_ISLNK(observed.st_mode) else (0o644, 0o755))
    if stat.S_IMODE(observed.st_mode) not in allowed or (not directory and observed.st_nlink != 1):
        raise ValueError("special permissions or hard links require separate preservation")


def supported_directories(root):
    if not hasattr(os, "listxattr"):
        raise ValueError("filesystem metadata inspection unavailable")
    for directory, directories, files in os.walk(root, followlinks=False, onerror=unreadable_directory):
        current = Path(directory)
        supported_metadata(current.lstat(), os.listxattr(current, follow_symlinks=False))
        if current == root:
            directories[:] = [name for name in directories if name != ".git"]
        elif ".git" in directories or ".git" in files:
            raise ValueError("nested repository requires separate preservation")
        if current != root and not directories and not files:
            raise ValueError("empty directories are not represented in this archive format")


def regular_fingerprint(path, parent, tar_metadata=False, git_metadata=False):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError("unsupported filesystem object")
        if not git_metadata:
            supported_metadata(before, os.listxattr(source.fileno()), tar_metadata)
        digest = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
        after = os.fstat(source.fileno())
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise ValueError("source changed while fingerprinting")
    mode = (0o755 if before.st_mode & stat.S_IXUSR else 0o644) if git_metadata else stat.S_IMODE(before.st_mode)
    return ["file", mode, before.st_size, digest.hexdigest()]


def open_parent(root, parts):
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for name in parts:
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def fingerprint(root, raw, tar_metadata=False, git_metadata=False):
    relative = Path(os.fsdecode(raw))
    if relative.is_absolute() or ".." in relative.parts or ".git" in relative.parts:
        raise ValueError("unsafe recovery path")
    try:
        parent = open_parent(root, relative.parts[:-1])
    except FileNotFoundError:
        return ["missing"]
    try:
        try:
            observed = os.stat(relative.name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            return ["missing"]
        if stat.S_ISLNK(observed.st_mode):
            supported_metadata(observed, os.listxattr(root / relative, follow_symlinks=False))
            return ["symlink", os.readlink(relative.name, dir_fd=parent)]
        if not stat.S_ISREG(observed.st_mode):
            raise ValueError("unsupported recovery file type")
        return regular_fingerprint(relative.name, parent, tar_metadata, git_metadata)
    finally:
        os.close(parent)


def supported_git_metadata(root, paths):
    """Tracked files follow Git's type/executable model, not full Unix metadata."""
    for raw in paths:
        relative = Path(os.fsdecode(raw))
        try:
            parent = open_parent(root, relative.parts[:-1])
        except FileNotFoundError:
            continue
        try:
            observed = os.stat(relative.name, dir_fd=parent, follow_symlinks=False)
            if not (stat.S_ISREG(observed.st_mode) or stat.S_ISLNK(observed.st_mode)):
                raise ValueError('unsupported tracked filesystem object')
        except FileNotFoundError:
            continue
        finally:
            os.close(parent)


def untracked_contents(root, paths):
    """Canonical first-name references bind only hard links inside the selected set."""
    contents, inodes = [], {}
    for raw in paths:
        value = fingerprint(root, raw, tar_metadata=True)
        if value[0] == 'file':
            observed = (root / os.fsdecode(raw)).lstat()
            key = (observed.st_dev, observed.st_ino)
            if key in inodes:
                value = ['hardlink', inodes[key]]
            else:
                inodes[key] = os.fsdecode(raw)
        contents.append([os.fsdecode(raw), value])
    return contents


def untracked_member_fingerprint(source, member):
    if member.issym():
        return ['symlink', member.linkname]
    if member.islnk():
        return ['hardlink', member.linkname]
    if not member.isfile():
        raise ValueError('unsupported untracked archive member')
    digest = hashlib.sha256()
    with source.extractfile(member) as handle:
        for chunk in iter(lambda: handle.read(1048576), b''):
            digest.update(chunk)
    return ['file', member.mode, member.size, digest.hexdigest()]


def verify_untracked_payload(archive, manifest):
    """Bind tar contents and internal links to the captured source snapshot."""
    saved = manifest.get('source_fingerprint', {})
    if manifest.get('capture_policy') != 'git-only' or saved.get('schema') not in (3, 4):
        return
    contents = []
    payload = archive / 'untracked.tar.gz'
    if payload.exists():
        with tarfile.open(payload, 'r:gz') as source:
            members = source.getmembers()
            if len({member.name for member in members}) != len(members):
                raise ValueError('duplicate untracked archive path')
            regular = {}
            for member in members:
                if member.islnk():
                    original = regular.get(member.linkname)
                    if original is None or original.mode != member.mode:
                        raise ValueError('hard link must reference an earlier regular payload member')
                elif member.isfile():
                    regular[member.name] = member
            contents = [[member.name, untracked_member_fingerprint(source, member)]
                        for member in sorted(members, key=lambda entry: os.fsencode(entry.name))]
    digest = hashlib.sha256(json.dumps(contents, ensure_ascii=True).encode('ascii')).hexdigest()
    if len(contents) != saved.get('untracked_files') or digest != saved.get('untracked_sha256'):
        raise ValueError('untracked payload does not match captured source')
