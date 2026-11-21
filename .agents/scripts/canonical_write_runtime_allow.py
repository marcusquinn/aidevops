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
import unicodedata
from pathlib import Path

from canonical_write_policy_paths import Classification
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
    # Literal pathspecs stop glob characters in a filename from matching
    # nothing; check-ignore rejects that flag and takes plain pathnames.
    code, tracked = _git_probe(
        repo_root, "--literal-pathspecs", "ls-files", "-z", "--", relative
    )
    if code != 0 or tracked:
        return False
    code, _ = _git_probe(repo_root, "check-ignore", "-q", "--", relative)
    return code == 0


def _is_reserved_component(part: str) -> bool:
    # Filesystems may alias `.GIT`, HFS+ ignorable code points (format
    # characters) and trailing dots/spaces to `.git`; compare the folded form.
    folded = "".join(
        char for char in unicodedata.normalize("NFC", part)
        if unicodedata.category(char) != "Cf"
    ).rstrip(". ").casefold()
    return folded in _RESERVED_COMPONENTS


def _owned_regular_config(info: os.stat_result) -> bool:
    """A single-link regular file owned by this user, within the size cap."""
    owned_single_link = info.st_uid == os.getuid() and info.st_nlink == 1
    return stat.S_ISREG(info.st_mode) and owned_single_link and (
        info.st_size <= _CONFIG_MAX_BYTES
    )


def _trusted_project_config(repo_root: str) -> dict | None:
    """Return the canonical config only when it is owned, ignored and untracked."""
    config_path = Path(repo_root) / PROJECT_CONFIG_NAME
    try:
        trusted = _owned_regular_config(config_path.lstat())
    except OSError:
        trusted = False
    if not trusted or not _untracked_and_ignored(repo_root, PROJECT_CONFIG_NAME):
        return None
    try:
        descriptor = os.open(
            config_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        )
        with os.fdopen(descriptor, encoding="utf-8") as handle:
            data = json.load(handle)
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
