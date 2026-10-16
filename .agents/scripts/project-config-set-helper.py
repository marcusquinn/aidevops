#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Allowlisted operational metadata setter; never a general canonical editor."""

import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

GIT = shutil.which("git")


def git(repo, *args):
    if not GIT:
        raise ValueError("Git executable is unavailable")
    return subprocess.check_output(  # nosec B603 -- resolved Git; fixed internal subcommands and data-only path argv
        [GIT, "-C", str(repo), *args], text=True, stderr=subprocess.PIPE
    ).strip()


def safe_file(path):
    """Refuse symlinks, special files, foreign ownership and hard links."""
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        raise ValueError("Unsafe config or audit file")
    return info


def ignored_config(repo):
    if git(repo, "ls-files", "--", ".aidevops.json"):
        raise ValueError("Tracked config requires a linked-worktree migration")
    if subprocess.run(  # nosec B603 -- resolved Git; fixed check-ignore argv, path is data
        [GIT, "-C", str(repo), "check-ignore", "-q", "--", ".aidevops.json"],
        check=False,
    ).returncode != 0:
        raise ValueError("Config must be ignored by Git before setting a timeout")


def repository_paths():
    root = Path(git(Path.cwd(), "rev-parse", "--show-toplevel")).resolve()
    common = Path(git(root, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve()
    records = git(root, "-c", "core.quotePath=false", "worktree", "list", "--porcelain")
    first = records.splitlines()[0]
    if not first.startswith("worktree "):
        raise ValueError("Cannot resolve canonical checkout")
    canonical = Path(first[len("worktree "):])
    if not canonical.is_absolute() or canonical.resolve() != canonical:
        raise ValueError("Canonical checkout path is unsafe")
    if canonical.stat().st_uid != os.getuid():
        raise ValueError("Canonical checkout owner changed")
    if Path(git(canonical, "rev-parse", "--path-format=absolute", "--git-dir")).resolve() != common:
        raise ValueError("Canonical Git directory identity changed")
    if Path(git(canonical, "rev-parse", "--show-toplevel")).resolve() != canonical:
        raise ValueError("Canonical checkout root changed")
    ignored_config(root)
    ignored_config(canonical)
    return root, common, canonical


def read_config(target):
    before, mode = None, 0o600
    if target.exists() or target.is_symlink():
        info = safe_file(target)
        mode = stat.S_IMODE(info.st_mode)
        before = target.read_bytes()
    data = json.loads(before) if before is not None else {}
    if not isinstance(data, dict):
        raise ValueError("Project config must be a JSON object")
    return data, before, mode


def record(log, receipt, status):
    log.write(json.dumps({**receipt, "status": status}) + "\n")
    log.flush()
    os.fsync(log.fileno())


def replace_config(canonical, data, before, mode):
    target = canonical / ".aidevops.json"
    fd, name = tempfile.mkstemp(prefix=".aidevops.json.set-", dir=canonical)
    try:
        with os.fdopen(fd, "w") as output:
            os.fchmod(output.fileno(), mode)
            json.dump(data, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        ignored_config(canonical)
        if target.exists() or target.is_symlink():
            safe_file(target)
            if before is None or target.read_bytes() != before:
                raise ValueError("Config changed during update; retry")
        elif before is not None:
            raise ValueError("Config disappeared during update; retry")
        os.replace(name, target)
        directory_fd = os.open(canonical, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def set_timeout(key, value):
    #aidevops:trust-boundary — only this operational key can cross the canonical
    # write boundary. No caller-supplied destination or arbitrary JSON keys.
    if key != "validator_timeout_seconds" or not re.fullmatch(r"[1-9][0-9]*", value):
        raise ValueError("Only validator_timeout_seconds <positive-integer> is supported")
    seconds = int(value)
    root, common, canonical = repository_paths()
    # Serialize setters in the shared Git directory; no lock artifacts in the
    # canonical worktree. Other config writers must not run concurrently: the
    # byte check below detects intervening edits, but is not a filesystem CAS.
    # O_NOFOLLOW also protects the lock/audit destinations.
    lock = common / "aidevops-project-config.lock"
    with os.fdopen(os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600), "r+") as handle:
        safe_file(lock)
        fcntl.flock(handle, fcntl.LOCK_EX)
        data, before, mode = read_config(canonical / ".aidevops.json")
        data[key] = seconds
        audit = common / "aidevops-project-config-audit.jsonl"
        with os.fdopen(os.open(audit, os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600), "a") as log:
            safe_file(audit)
            receipt = {"timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       "operation": "project-config-set", "key": key, "value": seconds}
            # Persist intent before the atomic update; never log other fields.
            record(log, receipt, "attempt")
            replace_config(canonical, data, before, mode)
            record(log, receipt, "applied")
    print(f"Set {key}={seconds} in ignored canonical .aidevops.json (audited)")
    local = root / ".aidevops.json"
    if root != canonical and (local.exists() or local.is_symlink()):
        print("Note: this worktree has a local .aidevops.json override; it retains precedence")


def main():
    if len(sys.argv) != 3:
        print("Usage: aidevops project-config set validator_timeout_seconds <positive-integer>", file=sys.stderr)
        return 2
    try:
        set_timeout(*sys.argv[1:])
    except (OSError, ValueError, subprocess.CalledProcessError):
        # Config parsing errors can include private field values; do not echo
        # JSON contents or subprocess stderr into public worker transcripts.
        print("Config update refused: validate key/value, canonical identity, and an owned, ignored JSON object without symlinks", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
