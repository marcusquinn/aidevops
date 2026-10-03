#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded private file operations and safe affiliate scalar values."""

import contextlib
import hashlib
import json
import os
import re
import stat
import uuid
from datetime import datetime
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

SECRET_QUERY = re.compile(r"token|secret|password|cookie|auth|session|key|code|tax|iban", re.I)


class AffiliateError(ValueError):
    """Sanitized safety failure; never include input values in diagnostics."""


def date(value: str) -> datetime:
    """Require explicit timezone evidence timestamps."""
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if result.tzinfo is None:
            raise ValueError
        return result
    except (ValueError, AttributeError) as error:
        raise AffiliateError("invalid evidence date") from error


def public_url(value: str) -> str:
    """Preserve tracking bytes while rejecting credential-shaped URLs."""
    if not isinstance(value, str) or len(value) > 2048 or any(c.isspace() for c in value):
        raise AffiliateError("invalid public URL")
    parsed = urlsplit(value)
    if any((parsed.scheme != "https", not parsed.hostname, parsed.username,
            parsed.password, parsed.fragment, parsed.port not in (None, 443))):
        raise AffiliateError("invalid public URL")
    if any(SECRET_QUERY.search(key) for key, _ in parse_qsl(parsed.query)):
        raise AffiliateError("credential-shaped URL is forbidden")
    return value


def integer(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def private_stat(info: os.stat_result, *, directory: bool = False) -> None:
    """Check the opened inode, not a pathname that can be substituted."""
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if (not expected(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600)):
        raise AffiliateError("insecure affiliate inode")


@contextlib.contextmanager
def directory_fd(path: Path):
    """Anchor operations through non-symlink directory descriptors at every component."""
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.absolute().parts[1:]:
            if part in {".", ".."}:
                raise AffiliateError("non-canonical affiliate path")
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        private_stat(os.fstat(descriptor), directory=True)
        yield descriptor
    finally:
        os.close(descriptor)


def read_private(name: str, directory: int, *, maximum: int = 65536) -> bytes:
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
    with os.fdopen(descriptor, "rb") as handle:
        private_stat(os.fstat(handle.fileno()))
        payload = handle.read(maximum + 1)
    if len(payload) > maximum:
        raise AffiliateError("affiliate observation exceeds bounded size")
    return payload


def observations(directory: int, corpus: str):
    """Yield digest-bound envelopes, excluding interrupted private drafts."""
    for name in sorted(os.listdir(directory)):
        if name.startswith(".affiliate-"):
            try:
                private_stat(os.stat(name, dir_fd=directory, follow_symlinks=False))
            except FileNotFoundError:
                pass
            continue
        payload = read_private(name, directory)
        digest = hashlib.sha256(payload).hexdigest()
        if name != digest + ".json":
            raise AffiliateError("evidence integrity mismatch")
        envelope = json.loads(payload)
        if not isinstance(envelope, dict):
            raise AffiliateError("evidence envelope must be an object")
        if set(envelope) != {"version", "corpus_id", "sequence", "record"}:
            raise AffiliateError("unsupported evidence envelope fields")
        if any((not integer(envelope["version"]), envelope["version"] != 1,
                envelope["corpus_id"] != corpus, not integer(envelope["sequence"]))):
            raise AffiliateError("unsupported or cross-corpus evidence")
        yield digest, envelope


def atomic(path: Path, payload: bytes) -> None:
    """Replace descriptor-anchored private files, fsync data and directory."""
    with directory_fd(path.parent) as directory:
        try:
            info = os.stat(path.name, dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            info = None
        if info is not None:
            private_stat(info)
        name = ".affiliate-" + uuid.uuid4().hex
        descriptor = os.open(name, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW,
                             0o600, dir_fd=directory)
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(name, path.name, src_dir_fd=directory, dst_dir_fd=directory)
            os.fsync(directory)
        finally:
            try:
                os.unlink(name, dir_fd=directory)
            except FileNotFoundError:
                pass
