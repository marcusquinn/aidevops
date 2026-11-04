#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Cheap local metadata checks for compact archive retention candidates."""

import datetime
import json
import os


PIN = ".aidevops-archive-pin"


def identity(path):
    value = path.lstat()
    return value.st_dev, value.st_ino


def inspect(root, directory):
    """Reject aliases, pins and malformed metadata from cheap local state only.

    The structural check (artifact hashes) still runs only for archives
    selected for removal, never for every archive.
    """
    for path in (directory, *directory.parents):
        if path == root:
            break
        if path.is_symlink():
            raise ValueError("symlinked archive path")
    if os.path.lexists(directory / PIN):
        raise ValueError("pinned archive")
    manifest_path = directory / "manifest.json"
    if manifest_path.is_symlink():
        raise ValueError("symlinked manifest")
    raw = manifest_path.read_bytes()
    manifest = json.loads(raw)
    if not isinstance(manifest, dict):
        raise ValueError("manifest must be an object")
    created = datetime.datetime.fromisoformat(manifest["created_at"].replace("Z", "+00:00"))
    if created.tzinfo is None or created > datetime.datetime.now(datetime.timezone.utc):
        raise ValueError("invalid archive creation time")
    size = sum(path.stat().st_size for path in directory.iterdir())
    return created, size, directory, identity(directory), raw
