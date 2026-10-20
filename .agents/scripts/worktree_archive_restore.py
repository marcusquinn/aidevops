#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Prepare Git-only recovery through the same public creation API as Pulse."""

import json
import os
from pathlib import Path
import shutil
import subprocess  # nosec B404 -- fixed local worktree helper, argv only
import sys
import uuid

from worktree_archive_administration import git


def prepare(archive, target):
    manifest = json.loads((archive / "manifest.json").read_text(encoding="utf-8"))
    common = Path(manifest["source_git_common_dir"])
    if not common.is_absolute() or not common.is_dir() or os.path.lexists(target):
        raise ValueError("restore requires the recorded repository and a new worktree path")
    entries = git(common, "worktree", "list", "--porcelain", "-z").split(b"\0")
    repository = Path(os.fsdecode(next(entry[9:] for entry in entries if entry.startswith(b"worktree "))))
    bundle = archive / "commits.bundle"
    if bundle.is_file():
        git(repository, "fetch", "--quiet", "--no-write-fetch-head", str(bundle), "HEAD")
    environment = dict(os.environ, AIDEVOPS_SKIP_AUTO_CLAIM="1", WORKTREE_NODE_MODULES_RESTORE_ENABLED="0")
    for name in ("GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
                 "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"):
        environment.pop(name, None)
    # Pulse calls this same command. It owns path policy, Git creation and
    # registration; recovery supplies only its exact saved commit and new branch.
    helper = Path(__file__).resolve().with_name("worktree-helper.sh")
    bash = shutil.which("bash")
    if bash is None:
        raise ValueError("Bash is unavailable")
    subprocess.run(  # nosec B603 -- resolved Bash and fixed framework helper
                   [str(Path(bash).absolute()), str(helper), "add", "recovery/" + uuid.uuid4().hex,
                    str(target), "--base", manifest["head_sha"]], cwd=repository,
                   env=environment, stdout=sys.stderr, check=True, timeout=180)


if __name__ == "__main__":
    prepare(Path(sys.argv[1]).resolve(strict=True), Path(sys.argv[2]).absolute())
