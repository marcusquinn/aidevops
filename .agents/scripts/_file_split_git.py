# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Local Git helpers for file-split-verify.py (no network, argv lists only)."""

import re
import shutil
import subprocess  # nosec B404 -- resolved local Git only, argv lists, never a shell


class GitError(Exception):
    """A git invocation failed."""


def git(*args, ok_codes=(0,)):
    """Run git and return decoded stdout; raise GitError on failure."""
    executable = shutil.which("git")
    if not executable:
        raise GitError("git executable not found on PATH")
    proc = subprocess.run(  # nosec B603 -- resolved Git, fixed subcommands, refs/paths are argv data
        [executable, "-c", "core.quotePath=false", *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode not in ok_codes:
        message = proc.stderr.decode("utf-8", "replace").strip()
        raise GitError(f"git {' '.join(args)}: {message or proc.returncode}")
    return proc.stdout.decode("utf-8", "surrogateescape")


def grep_head(head, args, pathspecs=(":/",)):
    """Run git grep at HEAD and return root-relative (path, line_no, content) hits.

    `:/` searches from the repository root even when run from a subdirectory;
    `--full-name` keeps result paths root-relative for `git show HEAD:<path>`.
    """
    output = git("grep", "-n", "-I", "--full-name", *args, head, "--", *pathspecs, ok_codes=(0, 1))
    prefix = f"{head}:"
    hits = []
    for line in output.splitlines():
        line = line.removeprefix(prefix)
        match = re.match(r"^(.*?):(\d+):(.*)$", line)
        if match:
            hits.append((match.group(1), int(match.group(2)), match.group(3)))
    return hits


def file_lines(head, path, cache):
    """Return the lines of path at HEAD (cached)."""
    if path not in cache:
        cache[path] = git("show", f"{head}:{path}").split("\n")
    return cache[path]
