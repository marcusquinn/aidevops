#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""GH#39573 opt-in canonical writes for gitignored runtime output.

#aidevops:trust-boundary — the allowlist is user-authored in the ignored,
untracked canonical `.aidevops.json`; that file, Git metadata and ignore
rules are never writable through it, and tracked files stay protected.
"""

from __future__ import annotations

import functools
import json
import os
import stat
import subprocess  # nosec B404 -- fixed native Git argv only
from pathlib import Path

from canonical_write_policy_paths import Classification, fold_path_component
from native_git import real_git


PROJECT_CONFIG_NAME = ".aidevops.json"
RUNTIME_ALLOW_KEY = "canonical_write_allow"
RUNTIME_ALLOWED = "allowlisted-ignored-runtime-path"
_RESERVED_COMPONENTS = frozenset(
    {".git", PROJECT_CONFIG_NAME, ".gitignore", ".gitattributes"}
)
_PREFIX_FORBIDDEN_CHARACTERS = frozenset("*?[]\\\0")
_CONFIG_MAX_BYTES = 1 << 20


def _git_probe(repo_root: str, *args: str) -> tuple[int, str]:
    """Run one fixed Git probe; any failure is a non-zero code."""
    environment = {
        key: value for key, value in os.environ.items()
        if not key.startswith("GIT_")
    }
    try:
        result = subprocess.run(  # nosec B603 -- native Git, fixed argv; paths are data
            [real_git(), "-C", repo_root, *args],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
            env=environment,
        )
    except (OSError, subprocess.SubprocessError, RuntimeError):
        return -1, ""
    return result.returncode, result.stdout


def _untracked_and_ignored(repo_root: str, relative: str) -> bool:
    """Tracked content stays protected even when an ignore rule matches it."""
    # `literal` keeps glob characters in a filename literal; `icase` makes a
    # case alias of a tracked file (`logs/report.md` for a tracked
    # `logs/Report.md` on case-insensitive storage) count as tracked.
    # check-ignore takes plain pathnames, not pathspec magic.
    code, tracked = _git_probe(
        repo_root, "ls-files", "-z", "--", f":(literal,icase){relative}"
    )
    if code != 0 or tracked:
        return False
    code, _ = _git_probe(repo_root, "check-ignore", "-q", "--", relative)
    return code == 0


def _is_reserved_component(part: str) -> bool:
    return fold_path_component(part) in _RESERVED_COMPONENTS


def _owned_regular_config(info: os.stat_result) -> bool:
    """A single-link regular file owned by this user, within the size cap."""
    owned_single_link = info.st_uid == os.getuid() and info.st_nlink == 1
    return stat.S_ISREG(info.st_mode) and owned_single_link and (
        info.st_size <= _CONFIG_MAX_BYTES
    )


def _read_owned_config(config_path: Path) -> bytes | None:
    """Validate and read the same descriptor, so a swap cannot bypass checks.

    Non-blocking open keeps a FIFO from hanging the guard; the read is
    bounded by the size cap.
    """
    flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(config_path, flags)
    except OSError:
        return None
    with os.fdopen(descriptor, "rb") as handle:
        if not _owned_regular_config(os.fstat(handle.fileno())):
            return None
        return handle.read(_CONFIG_MAX_BYTES + 1)


def _trusted_project_config(repo_root: str) -> dict | None:
    """Return the canonical config only when it is owned, ignored and untracked."""
    if not _untracked_and_ignored(repo_root, PROJECT_CONFIG_NAME):
        return None
    try:
        raw = _read_owned_config(Path(repo_root) / PROJECT_CONFIG_NAME)
        data = json.loads(raw) if raw and len(raw) <= _CONFIG_MAX_BYTES else None
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _runtime_allow_prefix(entry: object) -> tuple[str, ...]:
    """Parse one `dir/` prefix; anything ambiguous yields no prefix."""
    if (
        not isinstance(entry, str)
        or not entry.endswith("/")
        # A leading ":" would be read as pathspec magic by check-ignore.
        or entry.startswith(("/", ":"))
        or any(char in _PREFIX_FORBIDDEN_CHARACTERS for char in entry)
    ):
        return ()
    parts = tuple(entry[:-1].split("/"))
    if any(
        part in ("", ".", "..") or _is_reserved_component(part)
        for part in parts
    ):
        return ()
    return parts


def _allowlisted(config: dict, parts: tuple[str, ...]) -> bool:
    """Strictly beneath one valid prefix; the prefix directory itself is not."""
    entries = config.get(RUNTIME_ALLOW_KEY)
    prefixes = (
        [prefix for prefix in map(_runtime_allow_prefix, entries) if prefix]
        if isinstance(entries, list)
        else []
    )
    return any(
        len(parts) > len(prefix) and parts[: len(prefix)] == prefix
        for prefix in prefixes
    )


def _replaceable_target(target: Path) -> bool:
    """A missing file, or a regular single-link file (no hard-link aliasing)."""
    try:
        info = target.lstat()
    except FileNotFoundError:
        return True
    except OSError:
        return False
    return stat.S_ISREG(info.st_mode) and info.st_nlink == 1


def path_traverses_symlink(cwd: str, file_path: str) -> bool:
    """True when any component of the unresolved path is a symlink.

    Covers aliases above the repository root too, which the Git-origin
    symlink probe skips. `..` is kept so the kernel resolves it as written.
    """
    lexical = Path(file_path).expanduser()
    if not lexical.is_absolute():
        lexical = Path(cwd).expanduser().absolute() / lexical
    current = Path(lexical.anchor)
    for part in lexical.parts[1:]:
        current = current / part
        if part not in (".", "..") and current.is_symlink():
            return True
    return False


def _repository_parts(repo_root: str, target_path: str) -> tuple[str, ...] | None:
    try:
        return Path(target_path).relative_to(repo_root).parts
    except ValueError:
        return None


def _first_denial(
    target: Classification, target_path: str, traversed_symlink: bool
) -> str:
    """Evaluate ordered gates; the first failing gate names the denial."""
    repo_root = target.repo_root
    parts = _repository_parts(repo_root, target_path) if repo_root else None

    @functools.cache
    def config() -> dict | None:
        return _trusted_project_config(repo_root)

    gates = (
        ("not-canonical", lambda: target.classification == "canonical" and bool(repo_root)),
        ("symlink-in-path", lambda: not traversed_symlink),
        ("outside-repository", lambda: parts is not None),
        ("reserved-path", lambda: bool(parts) and not any(map(_is_reserved_component, parts))),
        ("no-trusted-config", lambda: config() is not None),
        ("not-allowlisted", lambda: _allowlisted(config(), parts)),
        ("unsafe-target-file", lambda: _replaceable_target(Path(target_path))),
        ("tracked-or-not-ignored", lambda: _untracked_and_ignored(repo_root, "/".join(parts))),
    )
    return next((reason for reason, passes in gates if not passes()), "")


def canonical_runtime_write(
    target: Classification, target_path: str, traversed_symlink: bool
) -> tuple[bool, str]:
    """Decide the opt-in canonical exception for gitignored runtime output."""
    denial = _first_denial(target, target_path, traversed_symlink)
    return not denial, denial or RUNTIME_ALLOWED
