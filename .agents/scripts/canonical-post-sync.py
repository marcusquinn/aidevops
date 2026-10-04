#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Maintainer-local, bounded post-sync commands (never a worker capability)."""

import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time


def worker_session():
    """Fail closed on worker identity, regardless of false headless flags."""
    return any(os.environ.get(key) for key in (
        "WORKER_WORKTREE_PATH", "WORKER_ISSUE_NUMBER", "WORKER_REPO_SLUG",
    )) or any(os.environ.get(key, "").lower() not in ("", "0", "false")
              for key in ("FULL_LOOP_HEADLESS", "AIDEVOPS_HEADLESS",
                          "Claude_HEADLESS", "CLAUDE_HEADLESS", "GITHUB_ACTIONS"))


def trusted_file(path):
    # Validate the opened inode, not a path that could be replaced before read.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "r", encoding="utf-8") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o022):
            raise ValueError("untrusted_config")
        return json.load(stream)


def report(outcome, repo, before, after, **fields):
    receipt = dict(outcome=outcome, before=before, after=after,
                   repository=str(repo), timestamp=int(time.time()), **fields)
    # No argv, command output, or exception text reaches public merge output.
    print("POST_SYNC outcome=" + outcome + "".join(
        f" {key}={value}" for key, value in fields.items()), flush=True)
    log = Path.home() / ".aidevops/logs/canonical-post-sync.jsonl"
    try:
        log.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK
        fd = os.open(log, flags, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as stream:
            info = os.fstat(stream.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_mode & 0o077):
                raise ValueError("unsafe_log")
            stream.write(json.dumps(receipt) + "\n")
    except (OSError, ValueError):
        print("WARNING: POST_SYNC evidence_log_unavailable", file=sys.stderr)


def validate_path(path):
    """Accept only literal relative paths without traversal."""
    if not isinstance(path, str) or not path:
        raise ValueError("invalid_path")
    if any(character in path for character in ("\0", "\\")):
        raise ValueError("invalid_path")
    if path.startswith(("/", ":")) or ".." in path.split("/"):
        raise ValueError("invalid_path")


def validate_argv(argv):
    """Require a nonempty, NUL-free argument vector, never a shell string."""
    if not isinstance(argv, list) or not argv:
        raise ValueError("invalid_argv")
    if not all(isinstance(arg, str) and "\0" not in arg for arg in argv) or not argv[0]:
        raise ValueError("invalid_argv")


def validate_hook(hook):
    """Validate each declaration before any command can execute."""
    if not isinstance(hook, dict):
        raise ValueError("invalid_hook")
    validate_path(hook["when_changed"])
    validate_argv(hook["run"])
    timeout = hook.get("timeout_seconds", 60)
    if type(timeout) is not int or not 1 <= timeout <= 300:
        raise ValueError("invalid_timeout")


def registry_entries(config):
    """Reject malformed registry shapes before inspecting any entry."""
    registry = trusted_file(config)
    if not isinstance(registry, dict):
        raise ValueError("invalid_registry")
    entries = registry["initialized_repos"]
    if not isinstance(entries, list):
        raise ValueError("invalid_entries")
    if not all(isinstance(entry, dict) for entry in entries):
        raise ValueError("invalid_entry")
    return entries


def configured_hooks(repo):
    """Load only the user-owned registry, never project/worker overrides."""
    #aidevops:trust-boundary: never honor worker/project config path overrides.
    config = Path.home() / ".config/aidevops/repos.json"
    if not config.exists():
        return []
    if config.resolve().is_relative_to(repo.resolve()):
        raise ValueError("project_config")
    entries = registry_entries(config)
    matches = [entry for entry in entries if Path(
        os.path.expanduser(entry.get("path", entry.get("repo_path", "")))
    ).resolve() == repo.resolve()]
    if len(matches) != 1:
        return []
    entry = matches[0]
    hooks = entry.get("post_sync", [])
    if hooks and entry.get("role") != "maintainer":
        raise ValueError("maintainer_role_required")
    if not isinstance(hooks, list) or len(hooks) > 16:
        raise ValueError("invalid_hooks")
    for hook in hooks:
        validate_hook(hook)
    return hooks


def execute_hook(repo, hook, remaining):
    """Bound a command and reap its process group on every outcome."""
    process = None
    outcome = "failed"
    code = "unavailable"
    try:
        # The user-owned registry is the authority; validate_hook checks argv.
        process = subprocess.Popen(  # nosec B603 -- maintainer-authorized, validated argv; no shell
            hook["run"], cwd=repo, stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True, shell=False)
        code = process.wait(timeout=min(hook.get("timeout_seconds", 60), remaining))
        outcome = "success" if code == 0 else "failed"
    except subprocess.TimeoutExpired:
        outcome = "timeout"
    except OSError:
        outcome = "failed"
    finally:
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
    return outcome, code


def execute_matching_hooks(repo, before, after, hooks, changed):
    """Keep the entire invocation within its maintenance budget."""
    deadline = time.monotonic() + 300
    for index, hook in enumerate(hooks):
        path = hook["when_changed"].rstrip("/")
        if not any(name == path or name.startswith(path + "/") for name in changed if name):
            continue
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            report("warning", repo, before, after, hook=index, reason="budget_exhausted")
            break
        outcome, code = execute_hook(repo, hook, remaining)
        report(outcome, repo, before, after, hook=index, exit_code=code)
        if outcome != "success":
            print("WARNING: POST_SYNC failed; canonical synchronization remains converged", file=sys.stderr)


def run(repo, before, after, git):
    if worker_session():
        print("POST_SYNC outcome=skipped reason=worker_session")
        return
    if before == after or not before:
        return
    try:
        hooks = configured_hooks(repo)
        if hooks:
            changed = subprocess.run(  # nosec B603 -- audited helper supplies Git and commit IDs; fixed diff argv
                [git, "-C", str(repo), "diff", "--name-only", "-z", "--no-renames", before, after, "--"],
                check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=15, shell=False,
            ).stdout.decode("utf-8", errors="surrogateescape").split("\0")
            execute_matching_hooks(repo, before, after, hooks, changed)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        report("warning", repo, before, after, reason="config_or_diff_invalid")


if __name__ == "__main__":
    run(Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4])
