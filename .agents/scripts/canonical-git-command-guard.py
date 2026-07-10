#!/usr/bin/env python3
"""Fail-closed policy for Git commands targeting a canonical worktree."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

BLOCK_EXIT = 42
SHELL_OPERATORS = {"&&", "||", ";", "|", "(", ")", "&"}
READ_ONLY = {
    "status", "diff", "log", "show", "rev-parse", "show-ref", "for-each-ref",
    "cat-file", "ls-files", "ls-tree", "merge-base", "describe", "grep", "blame",
    "shortlog", "whatchanged", "name-rev", "count-objects", "version", "help",
}
GLOBAL_VALUE_OPTIONS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
WRAPPERS = {"command", "sudo", "time", "nohup"}


def _real_git(explicit: str = "") -> str:
    if explicit:
        return explicit
    guard_dir = Path(__file__).resolve().parent
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(directory or ".") / "git"
        try:
            if candidate.is_file() and os.access(candidate, os.X_OK) and candidate.resolve().parent != guard_dir:
                return str(candidate.resolve())
        except OSError:
            continue
    return shutil.which("git") or "/usr/bin/git"


def _git_output(real_git: str, cwd: str, *args: str) -> str:
    result = subprocess.run(
        [real_git, *args], cwd=cwd, text=True, capture_output=True, timeout=5, check=False
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def _is_canonical(real_git: str, cwd: str, git_prefix: list[str]) -> bool:
    git_dir = _git_output(real_git, cwd, *git_prefix, "rev-parse", "--path-format=absolute", "--git-dir")
    common_dir = _git_output(real_git, cwd, *git_prefix, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if not git_dir or not common_dir:
        return False
    return os.path.realpath(git_dir) == os.path.realpath(common_dir)


def _split_invocation(argv: list[str], base_cwd: str) -> tuple[list[str], str, str, list[str]]:
    prefix: list[str] = []
    cwd = base_cwd
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--":
            index += 1
            break
        if arg in GLOBAL_VALUE_OPTIONS:
            if index + 1 >= len(argv):
                return prefix, cwd, "", []
            value = argv[index + 1]
            prefix.extend([arg, value])
            index += 2
            continue
        if arg.startswith("-"):
            prefix.append(arg)
            index += 1
            continue
        return prefix, cwd, arg, argv[index + 1 :]
    return prefix, cwd, "", argv[index:]


def _branch_is_read_only(args: list[str]) -> bool:
    if not args:
        return True
    mutating = {"-d", "-D", "-m", "-M", "-c", "-C", "-f", "--delete", "--move", "--copy", "--force", "--edit-description", "--set-upstream-to", "--unset-upstream"}
    if any(arg in mutating or arg.startswith(("--move=", "--copy=", "--set-upstream-to=")) for arg in args):
        return False
    listing = any(arg in {"--list", "--contains", "--merged", "--no-merged", "--points-at"} or arg.startswith(("--contains=", "--merged=", "--no-merged=", "--points-at=")) for arg in args)
    return listing or all(arg.startswith("-") or arg in {"HEAD", "@"} for arg in args)


def _config_is_read_only(args: list[str]) -> bool:
    read_flags = {"--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l", "--show-origin", "--show-scope", "--name-only", "--includes", "--null", "-z"}
    return bool(args) and any(arg in read_flags for arg in args) and not any(arg in {"--add", "--unset", "--unset-all", "--rename-section", "--remove-section", "--replace-all"} for arg in args)


def _is_allowed_canonical(subcommand: str, args: list[str]) -> bool:
    if subcommand in READ_ONLY:
        return True
    if subcommand == "branch":
        return _branch_is_read_only(args)
    if subcommand == "config":
        return _config_is_read_only(args)
    if subcommand == "remote":
        return not args or args[0] in {"-v", "--verbose", "get-url", "show"}
    if subcommand == "worktree":
        return bool(args) and args[0] in {"list", "add"}
    if subcommand == "tag":
        return not args or any(arg in {"-l", "--list", "--contains", "--points-at"} or arg.startswith(("--contains=", "--points-at=")) for arg in args)
    return False


def classify_git_argv(argv: list[str], cwd: str, real_git: str, check_unresolved: bool = False) -> tuple[bool, str]:
    prefix, effective_cwd, subcommand, args = _split_invocation(argv, cwd)
    if not subcommand:
        return False, "unable to classify Git subcommand"
    repo_values: list[str] = []
    for index, value in enumerate(prefix[:-1]):
        if value in {"-C", "--git-dir", "--work-tree"}:
            repo_values.append(prefix[index + 1])
    for value in prefix:
        if value.startswith(("--git-dir=", "--work-tree=")):
            repo_values.append(value.split("=", 1)[1])
    if check_unresolved and any(value.startswith("~") or re.search(r"[$`*?\[\]{}]", value) for value in repo_values):
        return False, "unresolved shell syntax in Git repository target"
    if not _is_canonical(real_git, effective_cwd, prefix):
        return True, "linked worktree or non-repository target"
    if _is_allowed_canonical(subcommand, args):
        return True, "read-only canonical operation or linked-worktree creation"
    return False, f"canonical worktree mutation via 'git {subcommand}'"


def _shell_tokens(command: str) -> list[str]:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()")
    lexer.whitespace_split = True
    lexer.commenters = ""
    return list(lexer)


def _git_invocations(command: str, cwd: str) -> list[tuple[list[str], str]]:
    tokens = _shell_tokens(command)
    invocations: list[tuple[list[str], str]] = []
    segment: list[str] = []
    segment_cwd = cwd
    for token in tokens + [";"]:
        if token not in SHELL_OPERATORS:
            segment.append(token)
            continue
        if segment:
            if segment[0] == "cd" and len(segment) >= 2:
                target = os.path.expanduser(segment[1])
                segment_cwd = target if os.path.isabs(target) else os.path.abspath(os.path.join(segment_cwd, target))
            else:
                index = 0
                while index < len(segment):
                    if "=" in segment[index] and not segment[index].startswith("-"):
                        variable_name = segment[index].split("=", 1)[0]
                        if variable_name in {"GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR"}:
                            raise PermissionError("Git repository environment override")
                        index += 1
                        continue
                    if segment[index] in WRAPPERS:
                        index += 1
                        continue
                    if segment[index] == "env":
                        index += 1
                        while index < len(segment) and "=" in segment[index] and not segment[index].startswith("-"):
                            variable_name = segment[index].split("=", 1)[0]
                            if variable_name in {"GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR"}:
                                raise PermissionError("Git repository environment override")
                            index += 1
                        continue
                    break
                if index < len(segment) and os.path.basename(segment[index]) == "git":
                    invocations.append((segment[index + 1 :], segment_cwd))
            segment = []
    return invocations


def classify_command(command: str, cwd: str, real_git: str) -> tuple[bool, str]:
    if re.search(r"(?:^|\s)GIT_(?:DIR|WORK_TREE|COMMON_DIR)=", command):
        return False, "Git repository environment override is not permitted in guarded shell commands"
    try:
        invocations = _git_invocations(command, cwd)
    except PermissionError:
        return False, "Git repository environment override is not permitted in guarded shell commands"
    except ValueError:
        if "git" in command:
            return False, "unable to parse command containing Git"
        return True, "no Git invocation"
    if not invocations and "git" in command and re.search(r"(?:^|[\s'\"])(?:/\S*/)?git\s+", command):
        return False, "unclassified nested Git invocation"
    for argv, invocation_cwd in invocations:
        if invocation_cwd != cwd and (invocation_cwd.startswith("~") or re.search(r"[$`*?\[\]{}]", invocation_cwd)):
            return False, "unresolved shell syntax in Git repository target"
        allowed, reason = classify_git_argv(argv, invocation_cwd, real_git, check_unresolved=True)
        if not allowed:
            return False, reason
    return True, "no prohibited canonical Git mutation"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cwd", default=os.getcwd())
    parser.add_argument("--command", default="")
    parser.add_argument("--argv-json", default="")
    parser.add_argument("--real-git", default="")
    args = parser.parse_args()
    real_git = _real_git(args.real_git)
    if args.argv_json:
        try:
            git_argv = json.loads(args.argv_json)
        except json.JSONDecodeError:
            print("BLOCKED: invalid Git argv", file=sys.stderr)
            return BLOCK_EXIT
        allowed, reason = classify_git_argv(git_argv, args.cwd, real_git)
    else:
        allowed, reason = classify_command(args.command, args.cwd, real_git)
    if allowed:
        return 0
    print(f"BLOCKED by canonical Git guard: {reason}. Use a linked worktree; canonical branch/ref mutation is never permitted.", file=sys.stderr)
    return BLOCK_EXIT


if __name__ == "__main__":
    raise SystemExit(main())
