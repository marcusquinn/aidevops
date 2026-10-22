#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bind untracked PAX payloads to source content and internal hard links."""

import hashlib
import json
import os
import tarfile

from worktree_archive_filesystem import fingerprint


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
