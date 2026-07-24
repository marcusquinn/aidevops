#!/usr/bin/env python3
"""Fail-closed policy for Git commands targeting a canonical worktree."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys
from pathlib import Path
from typing import Optional

from canonical_git_policy import BLOCK_EXIT, classify_git_argv, real_git
from canonical_shell_parser import git_invocations


SCRIPT_DIR = Path(__file__).resolve().parent


def _recovery_helper_command() -> str:
    helper = SCRIPT_DIR / "canonical-recovery-helper.sh"
    return shlex.quote(str(helper))


def _parse_invocations(
    command: str, cwd: str
) -> tuple[list[tuple[list[str], str]], Optional[tuple[bool, str]]]:
    try:
        return git_invocations(command, cwd), None
    except PermissionError:
        return [], (
            False,
            "Git repository environment override is not permitted in guarded shell commands",
        )
    except ValueError:
        if "git" in command:
            return [], (False, "unable to parse command containing Git")
        return [], (True, "no Git invocation")


def _first_blocked_invocation(
    invocations: list[tuple[list[str], str]], cwd: str, real_git_path: str
) -> Optional[tuple[bool, str]]:
    for argv, invocation_cwd in invocations:
        if invocation_cwd != cwd and (
            invocation_cwd.startswith("~") or re.search(r"[$`*?\[\]{}]", invocation_cwd)
        ):
            return False, "unresolved shell syntax in Git repository target"
        allowed, reason = classify_git_argv(
            argv, invocation_cwd, real_git_path, check_unresolved=True
        )
        if not allowed:
            return False, reason
    return None


def classify_command(command: str, cwd: str, real_git: str) -> tuple[bool, str]:
    if re.search(r"(?:^|\s)GIT_(?:DIR|WORK_TREE|COMMON_DIR)=", command):
        return (
            False,
            "Git repository environment override is not permitted in guarded shell commands",
        )
    invocations, parse_result = _parse_invocations(command, cwd)
    if parse_result is not None:
        return parse_result
    if (
        not invocations
        and "git" in command
        and re.search(r"(?:^|[\s'\"])(?:/\S*/)?git\s+", command)
    ):
        return False, "unclassified nested Git invocation"
    blocked = _first_blocked_invocation(invocations, cwd, real_git)
    return blocked or (True, "no prohibited canonical Git mutation")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cwd", default=os.getcwd())
    parser.add_argument("--command", default="")
    parser.add_argument("--argv-json", default="")
    parser.add_argument("--real-git", default="")
    args = parser.parse_args()
    real_git_path = real_git(args.real_git)
    if args.argv_json:
        try:
            git_argv = json.loads(args.argv_json)
        except json.JSONDecodeError:
            print("BLOCKED: invalid Git argv", file=sys.stderr)
            return BLOCK_EXIT
        allowed, reason = classify_git_argv(git_argv, args.cwd, real_git_path)
    else:
        allowed, reason = classify_command(args.command, args.cwd, real_git_path)
    if allowed:
        return 0
    recovery_helper = _recovery_helper_command()
    print(
        f"BLOCKED by canonical Git guard: {reason}. Use a linked worktree for edits. "
        "For an explicitly authorized clean canonical fast-forward, use "
        f"{recovery_helper} fast-forward-current; use sync-mirror when "
        "verified preservation is required. Direct canonical Git mutation remains prohibited.",
        file=sys.stderr,
    )
    return BLOCK_EXIT


if __name__ == "__main__":
    raise SystemExit(main())
