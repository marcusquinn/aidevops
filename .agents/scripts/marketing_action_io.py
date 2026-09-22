#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Descriptor-safe local I/O primitives for marketing actions."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import shutil
import stat
import subprocess
import tempfile
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

MAX_INPUT_BYTES = 1_048_576
GIT = shutil.which("git")
if GIT is None:
    raise RuntimeError("git executable is unavailable")


class ActionError(ValueError):
    """Raised when an action cannot safely proceed."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ActionError(message)


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def digest_bytes(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def digest(value: Any) -> str:
    return digest_bytes(canonical_json(value))


def load_json(path: str | Path, maximum: int = MAX_INPUT_BYTES) -> Any:
    with Path(path).open("rb") as stream:
        raw = stream.read(maximum + 1)
    require(len(raw) <= maximum, "document exceeds byte budget")
    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        raise ActionError("document is not valid JSON") from error


def run_git(root: Path, *args: str) -> str:
    process = subprocess.run(  # nosec B603 - argv is fixed to local Git operations after path validation
        [GIT, "-C", str(root), *args], capture_output=True, text=True, check=False, timeout=10
    )
    require(process.returncode == 0, "target is not an owned Git worktree")
    return process.stdout.strip()


def validate_worktree(value: Any) -> tuple[Path, str, str]:
    require(isinstance(value, str) and value, "project_root must be a path")
    lexical_root = Path(value).expanduser().absolute()
    current = Path(lexical_root.anchor)
    for part in lexical_root.parts[1:]:
        current /= part
        require(not current.is_symlink(), "project_root cannot contain symlinks")
    root = lexical_root.resolve()
    require(root.is_dir(), "project_root must be a real directory")
    top = Path(run_git(root, "rev-parse", "--show-toplevel")).resolve()
    require(top == root, "project_root must identify the worktree root")
    branch = run_git(root, "branch", "--show-current")
    require(branch not in {"", "main", "master"}, "actions require a non-default linked worktree branch")
    git_marker = root / ".git"
    require(git_marker.is_file() and not git_marker.is_symlink(), "actions require an isolated linked worktree")
    git_dir = Path(run_git(root, "rev-parse", "--absolute-git-dir")).resolve()
    require(git_dir.is_dir(), "worktree Git metadata is unavailable")
    identity = digest({"root": str(root), "git_dir": str(git_dir), "branch": branch})
    return root, branch, identity


def safe_target(root: Path, relative: Any) -> Path:
    require(isinstance(relative, str) and relative and "\x00" not in relative, "action path is invalid")
    candidate = Path(relative)
    require(not candidate.is_absolute() and ".." not in candidate.parts, "action path escapes the project")
    current = root
    for part in candidate.parts:
        current /= part
        metadata = current.lstat()
        require(not stat.S_ISLNK(metadata.st_mode), "action path contains a symlink")
    resolved = current.resolve()
    require(resolved.is_file() and resolved.is_relative_to(root), "action target must be a regular project file")
    run_git(root, "ls-files", "--error-unmatch", "--", relative)
    return resolved


@contextmanager
def target_parent(root: Path, relative: str) -> Iterator[tuple[int, str]]:
    candidate = Path(relative)
    require(not candidate.is_absolute() and candidate.name and ".." not in candidate.parts,
            "action path escapes the project")
    descriptors: list[int] = []
    flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(root, flags)
        descriptors.append(descriptor)
        for part in candidate.parts[:-1]:
            descriptor = os.open(part, flags, dir_fd=descriptor)
            descriptors.append(descriptor)
        yield descriptor, candidate.name
    except OSError as error:
        raise ActionError("action path changed or contains a symlink") from error
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def read_target(root: Path, relative: str) -> tuple[bytes, int, tuple[int, int]]:
    safe_target(root, relative)
    with target_parent(root, relative) as (parent_fd, name):
        descriptor = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent_fd)
        try:
            metadata = os.fstat(descriptor)
            require(stat.S_ISREG(metadata.st_mode), "action target must remain a regular file")
            with os.fdopen(os.dup(descriptor), "rb") as stream:
                content = stream.read(MAX_INPUT_BYTES + 1)
            require(len(content) <= MAX_INPUT_BYTES, "action target exceeds byte budget")
            return content, stat.S_IMODE(metadata.st_mode), (metadata.st_dev, metadata.st_ino)
        finally:
            os.close(descriptor)


def _require_parent_binding(root: Path, relative: str, expected_fd: int) -> None:
    with target_parent(root, relative) as (current_fd, _):
        expected = os.fstat(expected_fd)
        current = os.fstat(current_fd)
        require((current.st_dev, current.st_ino) == (expected.st_dev, expected.st_ino),
                "action target parent moved during operation")


def write_target(
    root: Path, relative: str, content: bytes, expected_digest: str, expected_identity: tuple[int, int]
) -> None:
    with target_parent(root, relative) as (parent_fd, name):
        current_fd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent_fd)
        try:
            metadata = os.fstat(current_fd)
            with os.fdopen(os.dup(current_fd), "rb") as stream:
                current = stream.read(MAX_INPUT_BYTES + 1)
        finally:
            os.close(current_fd)
        require((metadata.st_dev, metadata.st_ino) == expected_identity, "action target identity changed")
        require(digest_bytes(current) == expected_digest, "action target content changed")
        _require_parent_binding(root, relative, parent_fd)
        temporary = f".{name}.aidevops-{os.getpid()}"
        temporary_fd = os.open(
            temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            stat.S_IMODE(metadata.st_mode), dir_fd=parent_fd,
        )
        try:
            with os.fdopen(temporary_fd, "wb", closefd=False) as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            final = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            require((final.st_dev, final.st_ino) == expected_identity, "action target changed before replacement")
            _require_parent_binding(root, relative, parent_fd)
            os.replace(temporary, name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        finally:
            os.close(temporary_fd)
            try:
                os.unlink(temporary, dir_fd=parent_fd)
            except FileNotFoundError:
                pass


def private_directory(path: str | Path) -> Path:
    workspace = (Path.home() / ".aidevops" / ".agent-workspace").resolve()
    lexical = Path(path).expanduser().absolute()
    require(not lexical.is_symlink(), "receipt path cannot be a symlink")
    directory = lexical.resolve()
    require(directory.is_relative_to(workspace), "receipts must stay in the private aidevops workspace")
    current = workspace
    for part in directory.relative_to(workspace).parts:
        current /= part
        try:
            current.mkdir(mode=0o700)
        except FileExistsError:
            pass
        metadata = current.lstat()
        require(stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode),
                "receipt path contains a symlink or non-directory")
        require(metadata.st_uid == os.getuid() and stat.S_IMODE(metadata.st_mode) == 0o700,
                "receipt directory must already be private to the operator")
    require(not (directory / ".git").exists(), "receipts must remain outside Git")
    git_check = subprocess.run(  # nosec B603 - fixed read-only Git query
        [GIT, "-C", str(directory), "rev-parse", "--is-inside-work-tree"],
        capture_output=True, text=True, check=False, timeout=10,
    )
    require(git_check.returncode != 0, "receipts must remain outside every Git worktree")
    return directory


def atomic_write(path: Path, content: bytes, mode: int = 0o600) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def operation_lock(root: Path) -> Iterator[None]:
    git_dir = Path(run_git(root, "rev-parse", "--absolute-git-dir"))
    lock_path = git_dir / "aidevops-marketing-actions.lock"
    with lock_path.open("a+", encoding="utf-8") as stream:
        try:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ActionError("another marketing action operation owns this worktree") from error
        yield


def receipt_path(receipt_dir: Path, plan_digest: str) -> Path:
    return receipt_dir / f"{plan_digest.removeprefix('sha256:')}.json"
