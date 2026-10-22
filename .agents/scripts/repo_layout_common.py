# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared serialization, private-file and command primitives for layout migration."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import tempfile
from pathlib import Path
from typing import Any


class MigrationError(RuntimeError):
    """A safety invariant refused the requested migration operation."""


def canonical_bytes(value: Any) -> bytes:
    """Return deterministic UTF-8 JSON bytes."""
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha256_bytes(value: bytes) -> str:
    """Return a lowercase SHA-256 digest."""
    return hashlib.sha256(value).hexdigest()


def file_sha256(path: Path) -> str:
    """Hash one regular file without following a final symlink."""
    if path.is_symlink() or not path.is_file():
        raise MigrationError(f"Unsafe or missing file: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def private_directory(path: Path) -> None:
    """Create or validate an owner-private directory."""
    if path.exists():
        details = path.lstat()
        if (
            not stat.S_ISDIR(details.st_mode)
            or path.is_symlink()
            or details.st_uid != os.getuid()
        ):
            raise MigrationError(f"Unsafe state directory: {path}")
    else:
        path.mkdir(parents=True, mode=0o700)
    path.chmod(0o700)


def atomic_write(path: Path, payload: bytes, mode: int = 0o600) -> None:
    """Atomically replace a file on its current filesystem."""
    if path.parent.is_symlink() or not path.parent.is_dir():
        raise MigrationError(f"Unsafe destination directory: {path.parent}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        temporary.chmod(mode)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def load_json(path: Path) -> Any:
    """Load a regular JSON file."""
    if path.is_symlink() or not path.is_file():
        raise MigrationError(f"Unsafe or missing JSON file: {path}")
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise MigrationError(f"Malformed JSON file: {path}") from exc


def expand_path(value: str) -> Path:
    """Expand user syntax and return an absolute lexical path."""
    return Path(os.path.abspath(os.path.expanduser(value)))


def run(command: list[str], *, cwd: Path | None = None, binary: bool = False) -> Any:
    """Run a structured local command and return stdout."""
    try:
        result = subprocess.run(  # nosec B603
            command,
            cwd=cwd,
            check=True,
            capture_output=True,
            text=not binary,
            timeout=30,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        detail = getattr(exc, "stderr", "")
        if isinstance(detail, bytes):
            detail = detail.decode(errors="replace")
        raise MigrationError(f"Command failed: {command[0]} {str(detail).strip()}") from exc
    return result.stdout


def git(repo: Path, *arguments: str, binary: bool = False) -> Any:
    """Run Git against one repository without a shell."""
    return run(["git", "-C", str(repo), *arguments], binary=binary)
