#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Git identity and path probes for the canonical write policy."""

from __future__ import annotations

import json
import os
import stat
import subprocess  # nosec B404 -- fixed native Git argv only
import unicodedata
from dataclasses import dataclass
from pathlib import Path

from canonical_git_policy import _git_output as _shared_git_output
from native_git import real_git


GIT_WORKSPACE_ROOT_ENV = "AIDEVOPS_GIT_WORKSPACE_ROOT"

# GH#39573: opt-in canonical writes for gitignored runtime output.
PROJECT_CONFIG_NAME = ".aidevops.json"
RUNTIME_ALLOW_KEY = "canonical_write_allow"
_RESERVED_COMPONENTS = frozenset(
    {".git", PROJECT_CONFIG_NAME, ".gitignore", ".gitattributes"}
)
_PREFIX_FORBIDDEN_CHARACTERS = frozenset("*?[]\\\0")
_CONFIG_MAX_BYTES = 1 << 20


@dataclass
class Classification:
    """One repository-location classification."""

    classification: str
    inside_git: bool
    repo_root: str = ""
    git_dir: str = ""
    common_dir: str = ""
    branch: str = ""
    reason: str = ""


def _real_git() -> str:
    return real_git()


def git_output(cwd: Path, *args: str) -> str:
    try:
        return _shared_git_output(_real_git(), str(cwd), *args)
    except RuntimeError as exc:
        raise RuntimeError(f"Git repository probe failed: {exc}") from exc


def _existing_probe_path(raw_path: str) -> Path:
    path = Path(raw_path).expanduser().resolve(strict=False)
    if path.is_file() or path.is_symlink():
        path = path.parent
    while not path.exists() and path != path.parent:
        path = path.parent
    return path


def _repository_probes(probe_path: Path) -> dict[str, str]:
    return {
        "repo_root": git_output(probe_path, "rev-parse", "--show-toplevel"),
        "git_dir": git_output(probe_path, "rev-parse", "--git-dir"),
        "common_dir": git_output(probe_path, "rev-parse", "--git-common-dir"),
        "branch": git_output(probe_path, "branch", "--show-current"),
    }


def _absolute_probe_value(probe_path: Path, raw_value: str) -> str:
    path = Path(raw_value)
    if not path.is_absolute():
        path = probe_path / path
    return os.path.realpath(path)


def classify_location(raw_path: str) -> Classification:
    """Classify a path as canonical, linked, outside Git, or unknown."""
    probe_path = _existing_probe_path(raw_path)
    try:
        inside = git_output(probe_path, "rev-parse", "--is-inside-work-tree")
    except RuntimeError as exc:
        return Classification("unknown", False, reason=str(exc))
    if inside != "true":
        return Classification(
            "outside", False, reason="path is outside a Git worktree"
        )

    try:
        values = _repository_probes(probe_path)
    except RuntimeError as exc:
        return Classification("unknown", True, reason=str(exc))

    required = ("repo_root", "git_dir", "common_dir")
    if any(not values[name] for name in required):
        return Classification(
            "unknown",
            True,
            reason="required Git worktree identity could not be resolved",
        )

    repo_root = _absolute_probe_value(probe_path, values["repo_root"])
    git_dir = _absolute_probe_value(probe_path, values["git_dir"])
    common_dir = _absolute_probe_value(probe_path, values["common_dir"])
    classification = "canonical" if git_dir == common_dir else "linked"
    return Classification(
        classification,
        True,
        repo_root=repo_root,
        git_dir=git_dir,
        common_dir=common_dir,
        branch=values["branch"],
        reason=(
            "Git directory equals common directory"
            if classification == "canonical"
            else "Git directory is isolated beneath the common directory"
        ),
    )


def target_probe(cwd: str, file_path: str) -> str:
    if not file_path:
        return cwd
    target = Path(file_path).expanduser()
    if not target.is_absolute():
        target = Path(cwd) / target
    return str(target.resolve(strict=False))


def git_symlink_origin(cwd: str, file_path: str) -> Classification | None:
    """Return the Git location containing a traversed symlink, if any."""
    target = Path(file_path).expanduser()
    if not target.is_absolute():
        base = Path(cwd).expanduser()
        if not base.is_absolute():
            base = Path.cwd() / base
        target = base / target
    current = Path(target.anchor)
    for part in target.parts[1:]:
        if part in ("", "."):
            continue
        if part == "..":
            current = current.parent
            continue
        candidate = current / part
        if candidate.is_symlink():
            origin = classify_location(str(current))
            if origin.inside_git:
                return origin
            current = Path(os.path.realpath(candidate))
            continue
        current = candidate
    return None


def git_workspace_root_from_environment() -> str:
    """Return the trusted Git workspace root, defaulting to ~/Git."""
    if GIT_WORKSPACE_ROOT_ENV in os.environ:
        return os.environ[GIT_WORKSPACE_ROOT_ENV]
    return str(Path.home() / "Git")


def canonical_git_workspace_root(workspace_root: str) -> str:
    if not workspace_root:
        return ""
    root = os.path.realpath(os.path.expanduser(workspace_root))
    home = os.path.realpath(str(Path.home()))
    if root in {os.path.abspath(os.sep), home} or not os.path.isdir(root):
        return ""
    return root


def is_within_workspace(path: str, workspace_root: str) -> bool:
    if not path or not workspace_root:
        return False
    try:
        return (
            os.path.commonpath([os.path.realpath(path), workspace_root])
            == workspace_root
        )
    except ValueError:
        return False


def repository_within_workspace(
    location: Classification, workspace_root: str
) -> bool:
    """Require the worktree and its shared Git metadata beneath one root."""
    return location.inside_git and all(
        is_within_workspace(path, workspace_root)
        for path in (location.repo_root, location.git_dir, location.common_dir)
    )


def _git_probe(repo_root: str, *args: str) -> tuple[int, str]:
    """Run one fixed Git probe; any failure is a non-zero code."""
    environment = {
        key: value for key, value in os.environ.items()
        if not key.startswith("GIT_")
    }
    try:
        result = subprocess.run(  # nosec B603 -- native Git, fixed argv; paths are data
            [_real_git(), "-C", repo_root, *args],
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


def _trusted_project_config(repo_root: str) -> dict | None:
    """Return the canonical config only when it is owned, ignored and untracked."""
    config_path = Path(repo_root) / PROJECT_CONFIG_NAME
    try:
        info = config_path.lstat()
    except OSError:
        return None
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_nlink != 1
        or info.st_size > _CONFIG_MAX_BYTES
        or not _untracked_and_ignored(repo_root, PROJECT_CONFIG_NAME)
    ):
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


def _runtime_allow_prefixes(config: dict) -> list[tuple[str, ...]]:
    entries = config.get(RUNTIME_ALLOW_KEY)
    if not isinstance(entries, list):
        return []
    return [prefix for prefix in map(_runtime_allow_prefix, entries) if prefix]


def _replaceable_target(target: Path) -> bool:
    """A missing file, or a regular single-link file (no hard-link aliasing)."""
    try:
        info = target.lstat()
    except FileNotFoundError:
        return True
    except OSError:
        return False
    return stat.S_ISREG(info.st_mode) and info.st_nlink == 1


def canonical_runtime_write(
    target: Classification, target_path: str, traversed_symlink: bool
) -> tuple[bool, str]:
    """Decide the opt-in canonical exception for gitignored runtime output.

    #aidevops:trust-boundary — the allowlist is user-authored in the ignored,
    untracked canonical `.aidevops.json`; that file, Git metadata and ignore
    rules are never writable through it, and tracked files stay protected.
    """
    if target.classification != "canonical" or not target.repo_root:
        return False, "not-canonical"
    if traversed_symlink:
        return False, "symlink-in-path"
    try:
        parts = Path(target_path).relative_to(target.repo_root).parts
    except ValueError:
        return False, "outside-repository"
    if not parts or any(_is_reserved_component(part) for part in parts):
        return False, "reserved-path"
    config = _trusted_project_config(target.repo_root)
    if config is None:
        return False, "no-trusted-config"
    if not any(
        len(parts) > len(prefix) and parts[: len(prefix)] == prefix
        for prefix in _runtime_allow_prefixes(config)
    ):
        return False, "not-allowlisted"
    if not _replaceable_target(Path(target_path)):
        return False, "unsafe-target-file"
    if not _untracked_and_ignored(target.repo_root, "/".join(parts)):
        return False, "tracked-or-not-ignored"
    return True, "allowlisted-ignored-runtime-path"
