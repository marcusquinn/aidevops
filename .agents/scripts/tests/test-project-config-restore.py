#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Exercise the real config-only entry point with isolated registered Git repos."""

import json
import os
import pathlib
import pty
import select
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
CLI = ROOT / "aidevops.sh"


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def wait_for_prompt(master, process):
    output = b""
    for _ in range(100):
        readable, _, _ = select.select([master], [], [], 0.2)
        if readable:
            try:
                output += os.read(master, 4096)
            except OSError:
                break
            if b"Type the exact destination to confirm:" in output:
                return output
        if process.poll() is not None:
            break
    process.kill()
    raise AssertionError(f"confirmation prompt missing: {output!r}")


def read_remaining(master):
    os.set_blocking(master, False)
    output = b""
    try:
        while chunk := os.read(master, 4096):
            output += chunk
    except (OSError, BlockingIOError):
        pass
    return output


def run(env, *args, confirm=None):
    command = ["bash", str(CLI), "project-config", "restore", "fixture/repo", *args]
    if confirm is None:
        return subprocess.run(command, env=env, text=True, capture_output=True, check=False)
    master, slave = pty.openpty()
    try:
        process = subprocess.Popen(command, env=env, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        output = wait_for_prompt(master, process)
        os.write(master, (confirm + "\n").encode())
        process.wait(timeout=20)
        return process.returncode, (output + read_remaining(master)).decode(errors="replace")
    finally:
        os.close(master)


with tempfile.TemporaryDirectory(prefix="aidevops-config-restore-") as directory:
    root = pathlib.Path(directory).resolve()
    home = root / "home"
    home.mkdir()
    repo = root / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Fixture")
    (repo / ".gitignore").write_text(".aidevops.json\n")
    git(repo, "add", ".gitignore")
    git(repo, "commit", "-qm", "fixture")
    head = git(repo, "rev-parse", "HEAD")
    registry = root / "repos.json"
    entry = {"slug": "fixture/repo", "path": str(repo), "local_only": True, "features": ["git-workflow", "deployment-context"], "init_scope": "minimal"}
    registry.write_text(json.dumps({"initialized_repos": [entry]}))
    env = {**os.environ, "HOME": str(home), "AIDEVOPS_REPOS_FILE": str(registry)}
    target = repo / ".aidevops.json"

    preview = run(env)
    assert preview.returncode == 0, preview.stderr
    assert str(target) in preview.stdout and "UNKNOWN" in preview.stdout
    assert not target.exists() and git(repo, "status", "--porcelain") == ""
    assert run(env, "--apply").returncode != 0, "non-TTY apply must fail"

    code, output = run(env, "--apply", confirm=str(target) + "-wrong")
    assert code != 0 and not target.exists(), output
    code, output = run(env, "--apply", confirm=str(target))
    assert code == 0 and target.exists(), output
    config = json.loads(target.read_text())
    assert config["features"] == {"git_workflow": True, "deployment_context": True}, config
    assert config["init_scope"] == "minimal" and "counter_branch" not in config
    assert "planning" not in config["features"] and "plugins" not in config
    assert target.stat().st_mode & 0o777 == 0o600
    first = target.read_bytes()
    assert run(env).returncode == 0 and target.read_bytes() == first
    assert git(repo, "status", "--porcelain") == "" and git(repo, "rev-parse", "HEAD") == head

    target.unlink()
    backup = root / "backup.json"
    backup.write_text(json.dumps({"version": "old", "features": {"planning": False}, "counter_branch": "chosen", "plugins": []}))
    code, output = run(env, "--backup", str(backup), "--apply", confirm=str(target))
    assert code == 0, output
    assert json.loads(target.read_text())["counter_branch"] == "chosen"
    target.unlink()

    # A tracked config cannot be recreated as local metadata.
    target.write_text("{}")
    tracked_fixture = subprocess.run(
        ["git", "-C", str(repo), "add", "-f", ".aidevops.json"], capture_output=True, check=False
    )
    if tracked_fixture.returncode == 0:
        git(repo, "commit", "-qm", "tracked")
        target.unlink()
        assert run(env).returncode != 0 and not target.exists()
        git(repo, "rm", "--cached", "-q", ".aidevops.json")
        git(repo, "commit", "-qm", "untrack")
    else:
        assert b"canonical Git guard" in tracked_fixture.stderr, tracked_fixture.stderr
        print("SKIP tracked fixture: local canonical Git guard forbids fixture setup")
        target.unlink()

    target.symlink_to(backup)
    assert run(env).returncode != 0 and target.is_symlink()
    target.unlink()

    entry["features"] = ["unexpected-feature"]
    registry.write_text(json.dumps({"initialized_repos": [entry]}))
    assert run(env).returncode != 0 and not target.exists()
    entry["features"] = ["git-workflow"]

    # A registration pointing at a linked worktree must never be interpreted as canonical.
    linked = root / "linked"
    linked_fixture = subprocess.run(
        ["git", "-C", str(repo), "worktree", "add", "-q", "-b", "fixture-linked", str(linked)],
        capture_output=True, check=False,
    )
    if linked_fixture.returncode == 0:
        entry["path"] = str(linked)
        registry.write_text(json.dumps({"initialized_repos": [entry]}))
        assert run(env).returncode != 0 and not (linked / ".aidevops.json").exists()
    else:
        assert b"canonical Git guard" in linked_fixture.stderr, linked_fixture.stderr
        print("SKIP linked fixture: local canonical Git guard forbids fixture setup")

print("PASS project config restore: preview, confirmation, canonical target, backup, unknown fields, idempotence, symlink/worktree guards (tracked fixture when permitted)")
