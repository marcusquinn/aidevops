#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Access and bundle Git objects without caller repository overrides."""

import os
from pathlib import Path
import re
import subprocess
import tempfile


def git(root, *args, data=None):
    environment = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1")
    for name in ("GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
                 "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"):
        environment.pop(name, None)
    return subprocess.run(["git", "-C", str(root), *args], input=data, env=environment,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          check=True, timeout=60).stdout


def auto_merge_oid(data):
    if not re.fullmatch(rb"(?:[0-9a-f]{40}|[0-9a-f]{64})\n?", data):
        raise ValueError("git_admin:invalid_AUTO_MERGE")
    return data.strip().decode("ascii")


def validate_auto_merge(root, oid):
    try:
        kind = git(root, "cat-file", "-t", oid).strip()
    except subprocess.SubprocessError as error:
        raise ValueError("git_admin:missing_AUTO_MERGE_tree") from error
    if kind != b"tree":
        raise ValueError("git_admin:AUTO_MERGE_not_tree")


def capture_bundle(root, archive, roots, base):
    # Scratch refs make every root (including index-only blobs) a named bundle
    # tip. All writes go to scratch; the source object database is read-only.
    with tempfile.TemporaryDirectory(prefix=".admin-bundle-", dir=archive.parent) as temporary:
        scratch = Path(temporary)
        object_format = git(root, 'rev-parse', '--show-object-format').strip().decode('ascii')
        git(scratch, "init", "--bare", "--quiet", f'--object-format={object_format}')
        objects = git(root, "rev-parse", "--path-format=absolute", "--git-path", "objects").rstrip(b"\n")
        (scratch / "objects/info/alternates").write_bytes(objects + b"\n")
        updates = ''.join(f'update refs/archive/{number} {oid}\n'
                          for number, oid in enumerate(roots))
        git(scratch, "update-ref", "--stdin", data=updates.encode('ascii'))
        git(scratch, "update-ref", "refs/heads/archive-head", git(root, "rev-parse", "HEAD").strip().decode("ascii"))
        git(scratch, "symbolic-ref", "HEAD", "refs/heads/archive-head")
        exclusions = (f'^{base}',) if base else ()
        git(scratch, "bundle", "create", str(archive / "commits.bundle"), "--all", *exclusions)


def fetch_preservation(root, archive):
    bundle = archive / 'commits.bundle'
    if bundle.is_file():
        git(root, 'fetch', '--quiet', '--no-write-fetch-head', str(bundle),
            '+refs/archive/*:refs/archive/*')
