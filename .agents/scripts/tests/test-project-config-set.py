#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Exercise the real CLI setter in isolated sibling Git worktrees."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
CLI = ROOT / "aidevops.sh"
KEY = "validator_timeout_seconds"
GIT = shutil.which("git")
BASH = shutil.which("bash")


def require(condition, message="Config setter verification failed"):
    # Keep fixture checks active even when Python runs with -O.
    if not condition:
        raise AssertionError(message)


def git(repo, *args):
    return subprocess.check_output(  # nosec B603 -- resolved Git and exclusively fixture-owned argv
        [GIT, "-C", str(repo), *args], text=True).strip()


def run(repo, key=KEY, value="1500", success=True):
    env = {**os.environ, "AIDEVOPS_AGENTS_DIR": str(ROOT / ".agents")}
    result = subprocess.run(  # nosec B603 -- resolved Bash, repository-owned CLI, fixture-only argv
                            [BASH, str(CLI), "project-config", "set", key, value],
                            cwd=repo, env=env, capture_output=True, text=True, check=False)
    require((result.returncode == 0) == success, result.stdout + result.stderr)
    return result


def check_repository(base, separate=False):
    repo = base / "canonical checkout"
    repo.mkdir()
    options = ["--separate-git-dir", str(base / "metadata")] if separate else []
    git(repo, "init", "-q", *options)
    git(repo, "config", "user.name", "Fixture")
    git(repo, "config", "user.email", "fixture@example.invalid")
    (repo / ".gitignore").write_text(".aidevops.json\n")
    git(repo, "add", ".gitignore")
    git(repo, "commit", "-qm", "fixture")
    linked = base / "first worktree"
    second = base / "second worktree"
    git(repo, "worktree", "add", "-qb", "first", str(linked))
    git(repo, "worktree", "add", "-qb", "second", str(second))
    common = Path(git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    index = common / "index"
    before = (index.read_bytes(), git(repo, "show-ref"))
    target = repo / ".aidevops.json"
    if separate:
        # Git reports the metadata directory as its first worktree in this
        # layout, not the actual checkout. Never guess a write destination.
        run(linked, success=False)
        require(not target.exists())
        require(not (common / ".aidevops.json").exists())
        require(before == (index.read_bytes(), git(repo, "show-ref")))
        print("PASS: undiscoverable separate-Git-directory destination refused")
        return
    run(linked)
    require(json.loads(target.read_text()) == {KEY: 1500})
    require(target.stat().st_mode & 0o777 == 0o600)
    require(not (linked / ".aidevops.json").exists())
    target.write_text(json.dumps({KEY: 1500, "keep": {"private": "preserve-me"}}))
    target.chmod(0o640)
    subdir = linked / "nested"
    subdir.mkdir()
    run(subdir, value="1800")
    require(json.loads(target.read_text()) == {KEY: 1800, "keep": {"private": "preserve-me"}})
    require(target.stat().st_mode & 0o777 == 0o640)
    # Read through the real validator selector in the other worktree, with the
    # package execution shimmed only to capture the timeout it would receive.
    validators = ROOT / ".agents/scripts/full-loop-helper-commit-validators.sh"
    script = '''source "$1"
_validators_should_run() { return 0; }
_commit_touches_node_files() { return 0; }
_detect_node_project() { pm=bash; return 0; }
print_info() { return 0; }
_validator_scopes() { printf '.\\n'; return 0; }
_run_scoped_node_checks() { test "$3" = 1800; }
unset AIDEVOPS_VALIDATOR_TIMEOUT
_run_project_validators 0
'''
    subprocess.run(  # nosec B603 -- resolved Bash, fixed fixture shell program, local validator path
        [BASH, "-c", script, "test", str(validators)], cwd=second, check=True)
    for key, value in [("features", "1"), (KEY, "0"), (KEY, "-1"), (KEY, "1.5"),
                       (KEY, "01"), (KEY, "1; touch invalid"), (KEY, "")]:
        saved = target.read_bytes()
        run(linked, key, value, success=False)
        require(target.read_bytes() == saved)
    for invalid in ["[]", "null", "not-json"]:
        target.write_text(invalid)
        run(linked, success=False)
        require(target.read_text() == invalid)
    target.unlink()
    outside = base / "outside.json"
    outside.write_text('{"private":"do-not-touch"}')
    target.symlink_to(outside)
    run(linked, success=False)
    require(outside.read_text() == '{"private":"do-not-touch"}')
    target.unlink()
    os.link(outside, target)
    run(linked, success=False)
    target.unlink()
    target.write_text("{}")
    require(before == (index.read_bytes(), git(repo, "show-ref")))
    git(repo, "add", "-f", ".aidevops.json")
    run(linked, success=False)
    git(repo, "reset", "-q", "HEAD", "--", ".aidevops.json")
    # The fixture's add/reset legitimately changes index metadata; capture a
    # new baseline rather than attributing that change to the setter.
    before = (index.read_bytes(), git(repo, "show-ref"))
    (repo / ".gitignore").write_text("")
    run(linked, success=False)
    (repo / ".gitignore").write_text(".aidevops.json\n")
    local = linked / ".aidevops.json"
    local.write_text('{"validator_timeout_seconds":60}')
    result = run(linked)
    require("local .aidevops.json override" in result.stdout)
    require(json.loads(local.read_text())[KEY] == 60)
    audit = common / "aidevops-project-config-audit.jsonl"
    receipts = [json.loads(line) for line in audit.read_text().splitlines()]
    require(receipts[-1]["status"] == "applied")
    require("preserve-me" not in audit.read_text())
    require(before == (index.read_bytes(), git(repo, "show-ref")))
    require(not list(repo.glob(".aidevops.json.set-*")))
    print("PASS: CLI setter safety and cross-worktree validator inheritance")


with tempfile.TemporaryDirectory(prefix="aidevops-config-set-") as directory:
    base = Path(directory).resolve()
    for separate in [False, True]:
        case = base / str(separate)
        case.mkdir()
        check_repository(case, separate)
