#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Read and validate the Git administration preserved by worktree archives."""

import json
import os
from pathlib import Path

from worktree_archive_readiness import (
    OPAQUE_ADMIN_FILES,
    read_admin_bytes, validate_readiness_payload,
)
from worktree_archive_git import (
    auto_merge_oid as auto_merge_oid, git as git,
    validate_auto_merge as validate_auto_merge, fetch_head_roots as fetch_head_roots,
)


ADMIN_FILES = {"HEAD", "index", "AUTO_MERGE", "ORIG_HEAD", "FETCH_HEAD", "COMMIT_EDITMSG", "SQUASH_MSG", "MERGE_MSG", "config.worktree", "logs/HEAD"} | OPAQUE_ADMIN_FILES
PRIVATE_PREFIXES = ("refs/worktree/", "refs/bisect/", "refs/rewritten/")
OPERATIONS = {"MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD",
              "rebase-merge", "rebase-apply", "sequencer", "BISECT_LOG"}
# Runtime requests and generation identity are not Git state or grants to restore.
# A restored worktree must enroll a new generation, never inherit the source UUID.
RUNTIME_ADMIN_FILES = frozenset({"aidevops-permission-pending", "aidevops-generation.json"})
IGNORED_ADMIN_FILES = {False: RUNTIME_ADMIN_FILES,
                      True: RUNTIME_ADMIN_FILES | {"commondir", "gitdir"}}


def admin_path_allowed(name):
    return name in ADMIN_FILES or any(name.startswith(prefix) for prefix in PRIVATE_PREFIXES)


def validate_admin_entry(entry, name, allow_merge=False):
    if name == "index.lock":
        raise ValueError("git_admin:index_locked:index.lock")
    if (name in OPERATIONS and not (allow_merge and name == 'MERGE_HEAD')) or name == "aidevops/js-install-partial":
        raise ValueError(f"git_admin:unfinished_operation:{name}")
    if entry.is_symlink():
        raise ValueError(f"git_admin:symlink:{name}")


def admin_directory_allowed(name):
    return (name in {"logs", "refs", "refs/worktree", "refs/bisect", "refs/rewritten", "aidevops"}
            or any(name.startswith(prefix) for prefix in PRIVATE_PREFIXES))


def administration_files(admin, directory, linked, allow_merge=False):
    files = {}
    for entry in sorted(directory.iterdir()):
        name = entry.relative_to(admin).as_posix()
        validate_admin_entry(entry, name, allow_merge)
        # Validate before ignoring: symlinks and non-files remain refused.
        if name in IGNORED_ADMIN_FILES[linked] and entry.is_file():
            continue
        if entry.is_dir() and admin_directory_allowed(name):
            files.update(administration_files(admin, entry, linked, allow_merge))
        elif entry.is_file() and (admin_path_allowed(name) or (allow_merge and name in {'MERGE_HEAD', 'MERGE_MODE'})):
            files[name] = read_admin_bytes(entry, name).hex()
        elif not linked and name == "branches" and entry.is_dir() and not any(entry.iterdir()):
            # Stock Git templates may include this empty legacy directory.
            continue
        elif not linked and (name == "logs/refs" or name.split("/")[0] in
                             {"objects", "refs", "config", "description", "hooks", "info", "packed-refs"}):
            # Independent restores contain ordinary repository infrastructure.
            continue
        else:
            raise ValueError(f"git_admin:unknown_entry:{name}")
    return files


def validate_admin_config(root, admin):
    config = admin / 'config.worktree'
    if config.exists():
        entries = git(root, 'config', '--file', str(config), '--no-includes', '--null', '--list')
        for entry in entries.split(b'\0'):
            key = entry.split(b'\n', 1)[0].lower()
            if key == b'core.worktree' or (key.startswith(b'include') and key.endswith(b'.path')):
                raise ValueError('git_admin:location_dependent_config:' + key.decode('ascii'))


def administration(root, allow_merge=False):
    """Read only explicitly supported per-worktree administration, never common config."""
    admin = Path(os.fsdecode(git(root, "rev-parse", "--absolute-git-dir").rstrip(b"\n")))
    common = Path(os.fsdecode(git(root, "rev-parse", "--path-format=absolute", "--git-common-dir").rstrip(b"\n")))
    files = administration_files(admin, admin, admin.resolve() != common.resolve(), allow_merge)
    fetch_head_roots(files.get("FETCH_HEAD", ""))
    if "AUTO_MERGE" in files:
        validate_auto_merge(root, auto_merge_oid(bytes.fromhex(files["AUTO_MERGE"])))
    if git(root, "rev-parse", "--shared-index-path").strip():
        raise ValueError("git_admin:split_index:index")
    validate_admin_config(root, admin)
    refs = git(root, "for-each-ref", "--format=%(refname) %(objectname) %(symref)", *PRIVATE_PREFIXES)
    head = bytes.fromhex(files['HEAD'])
    head_ref = os.fsdecode(head[5:].strip()) if head.startswith(b'ref: ') else None
    references = {}
    for line in refs.splitlines():
        name, oid, symbolic = os.fsdecode(line).split(' ', 2)
        if symbolic and symbolic != head_ref and not any(symbolic.startswith(prefix) for prefix in PRIVATE_PREFIXES):
            raise ValueError(f'git_admin:external_symbolic_ref:{name}')
        references[name] = oid
    return {"files": files, "refs": references}


def load_administration(archive):
    state = json.loads((archive / "git-admin.json").read_text(encoding="ascii"))
    if not isinstance(state, dict) or set(state) != {"files", "refs"}:
        raise ValueError("git_admin:invalid_artifact")
    if (not isinstance(state['files'], dict) or not isinstance(state['refs'], dict)
            or not {"HEAD", "index"}.issubset(state['files'])):
        raise ValueError("git_admin:invalid_artifact")
    for name, value in state["files"].items():
        if not admin_path_allowed(name) or ".." in Path(name).parts or Path(name).is_absolute():
            raise ValueError("git_admin:unsafe_path")
        validate_readiness_payload(name, value)
        bytes.fromhex(value)
    fetch_head_roots(state["files"].get("FETCH_HEAD", ""))
    if "AUTO_MERGE" in state["files"]:
        auto_merge_oid(bytes.fromhex(state["files"]["AUTO_MERGE"]))
    for name, oid in state["refs"].items():
        if (not any(name.startswith(prefix) for prefix in PRIVATE_PREFIXES)
                or ".." in Path(name).parts or Path(name).is_absolute()):
            raise ValueError("git_admin:unsafe_ref")
        if len(oid) not in (40, 64) or any(char not in "0123456789abcdef" for char in oid):
            raise ValueError("git_admin:invalid_oid")
    return state
