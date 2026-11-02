#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Private OpenCode snapshot exception for the canonical Git guard."""

from __future__ import annotations

import os
from pathlib import Path

from canonical_git_management import is_registered_common_dir
from canonical_git_repository import git_output


def _snapshot_prefix_is_safe(prefix: list[str]) -> bool:
    """Require explicit storage and reject config/option write-target redirection."""
    explicit_git_dir = False
    remaining = iter(prefix)
    for option in remaining:
        if option in {"--git-dir", "--work-tree", "-C"}:
            if not next(remaining, ""):
                return False
            explicit_git_dir |= option == "--git-dir"
        elif option.startswith(("--git-dir=", "--work-tree=")):
            explicit_git_dir |= option.startswith("--git-dir=")
        elif option == "-c":
            if next(remaining, "") not in {
                "core.autocrlf=false", "core.longpaths=true", "core.fsmonitor=false",
            }:
                return False
        else:
            return False
    return explicit_git_dir


def _snapshot_has_private_files(storage: Path) -> bool:
    """Reject nested symlinks and shared files, including object fanout/pack paths."""
    def reject_walk_error(error: OSError) -> None:
        raise error

    try:
        for base, directories, files in os.walk(storage, onerror=reject_walk_error):
            for name in directories + files:
                path = Path(base) / name
                if path.is_symlink() or (path.is_file() and path.stat().st_nlink > 1):
                    return False
    except OSError:
        return False
    return True


def _snapshot_storage_is_private(real_git_path: str, identity: tuple[str, ...]) -> bool:
    """Require unshared storage under the snapshot root, separate from the checkout."""
    common, git_dir, top = identity
    data_home = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share")
    if not data_home.is_absolute():
        return False
    root = data_home.resolve() / "opencode/snapshot"
    storage = Path(git_dir).resolve()
    canonical_common = git_output(
        real_git_path, top, "rev-parse", "--path-format=absolute", "--git-common-dir"
    )
    return all((
        root.resolve() == root,
        root in storage.parents,
        storage.name != ".git",
        not is_registered_common_dir(str(storage)),
        Path(common).resolve() == storage,
        bool(canonical_common),
        Path(canonical_common).resolve() != storage,
    )) and _snapshot_has_private_files(storage)


def is_isolated_opencode_snapshot(
    real_git_path: str, cwd: str, prefix: list[str], subcommand: str, args: list[str]
) -> bool:
    """Permit index/object maintenance, never checkout writes, in private snapshots."""
    safe_args = {
        "add": ([], ["."], ["--all"], ["--all", "--sparse"]),
        "write-tree": ([],),
        "gc": ([], ["--prune=7.days"]),
        "prune": ([],),
    }
    if args not in safe_args.get(subcommand, ()):
        return False
    #aidevops:trust-boundary -- explicit private Git storage is not a checkout edit.
    if any(os.environ.get(name) for name in (
        "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS",
    )) or not _snapshot_prefix_is_safe(prefix):
        return False
    identity = tuple(
        git_output(real_git_path, cwd, *prefix, "rev-parse", "--path-format=absolute", flag)
        for flag in ("--git-common-dir", "--git-dir", "--show-toplevel")
    )
    if not all(identity):
        return False
    # Filtered repacks can export packs outside objects/ without filesystem links.
    # Inspect effective config, including global settings and repository includes.
    if subcommand == "gc" and git_output(
        real_git_path, cwd, *prefix, "config", "--get", "gc.repackFilterTo"
    ):
        return False
    return _snapshot_storage_is_private(real_git_path, identity)
