#!/usr/bin/env python3
"""Runtime-neutral shell-command safety-floor decisions."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any

PROMPT_EXIT = 10
FORBID_EXIT = 20
POLICY_ERROR_EXIT = 21
SHELL_OPERATORS = {"&&", "||", ";", "|", "(", ")", "&"}
SHELLS = {"bash", "dash", "ksh", "sh", "zsh"}
WRAPPERS = {"command", "nohup", "sudo", "time"}
KNOWN_MATCHERS = {
    "rm_recursive_force_root",
    "rm_recursive_force",
    "git_checkout_worktree_path",
    "git_restore_worktree",
    "git_reset_destructive",
    "git_clean_force",
    "git_push_force",
    "git_branch_force_delete",
    "git_stash_delete",
}
DECISION_RANK = {"allow": 0, "prompt": 1, "forbid": 2}


class PolicyError(ValueError):
    """Raised when the required policy cannot be trusted."""


def _decision(decision: str, rule_id: str, reason: str) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "decision": decision,
        "rule_id": rule_id,
        "reason": reason,
    }


def _policy_error(reason: str) -> dict[str, Any]:
    return _decision("forbid", "policy.invalid", reason)


def _default_policy_path() -> Path:
    override = os.environ.get("AIDEVOPS_COMMAND_POLICY_CONFIG", "")
    if override:
        return Path(override)
    return Path(__file__).resolve().parent.parent / "configs" / "command-policy.json"


def _load_policy(path: Path) -> dict[str, Any]:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise PolicyError(f"required command policy is unavailable: {path}: {exc}") from exc
    try:
        policy = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise PolicyError(f"required command policy is malformed: {path}: {exc}") from exc
    _validate_policy_shape(policy)
    return policy


def _validate_policy_shape(policy: Any) -> None:
    if not isinstance(policy, dict) or policy.get("schema_version") != 1:
        raise PolicyError("command policy schema_version must be 1")
    if policy.get("decision_order") != ["allow", "prompt", "forbid"]:
        raise PolicyError("command policy decision_order is invalid")
    default = policy.get("default_decision")
    if not isinstance(default, dict) or default.get("decision") != "allow":
        raise PolicyError("command policy requires an allow default_decision")
    guards = policy.get("dynamic_guards")
    canonical = [guard for guard in guards or [] if isinstance(guard, dict) and guard.get("kind") == "canonical_git"]
    if len(canonical) != 1 or canonical[0].get("helper") != "canonical-git-command-guard.py" or canonical[0].get("decision") != "forbid":
        raise PolicyError("command policy requires exactly one canonical Git dynamic guard")
    rules = policy.get("rules")
    if not isinstance(rules, list) or not rules:
        raise PolicyError("command policy rules must be a non-empty list")
    seen_ids: set[str] = set()
    seen_matchers: set[str] = set()
    for rule in rules:
        if not isinstance(rule, dict):
            raise PolicyError("command policy rule must be an object")
        rule_id = rule.get("id")
        matcher = rule.get("matcher")
        if not isinstance(rule_id, str) or not rule_id or rule_id in seen_ids:
            raise PolicyError("command policy rule IDs must be unique non-empty strings")
        if matcher not in KNOWN_MATCHERS or matcher in seen_matchers:
            raise PolicyError(f"command policy matcher is invalid or duplicated: {matcher}")
        if rule.get("decision") not in DECISION_RANK or not isinstance(rule.get("reason"), str):
            raise PolicyError(f"command policy rule is incomplete: {rule_id}")
        seen_ids.add(rule_id)
        seen_matchers.add(matcher)
    if seen_matchers != KNOWN_MATCHERS:
        raise PolicyError("command policy must define every required matcher exactly once")
    fixtures = policy.get("fixtures")
    if not isinstance(fixtures, list) or not fixtures:
        raise PolicyError("command policy requires self-test fixtures")


def _shell_segments(command: str) -> list[list[str]]:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()")
    lexer.whitespace_split = True
    lexer.commenters = ""
    tokens = list(lexer)
    segments: list[list[str]] = []
    segment: list[str] = []
    for token in tokens + [";"]:
        if token not in SHELL_OPERATORS:
            segment.append(token)
            continue
        if segment:
            segments.extend(_expand_segment(segment))
            segment = []
    return segments


def _expand_segment(segment: list[str]) -> list[list[str]]:
    index = 0
    while index < len(segment):
        token = segment[index]
        if token in WRAPPERS:
            index += 1
            continue
        if token == "env":
            index += 1
            while index < len(segment) and "=" in segment[index] and not segment[index].startswith("-"):
                index += 1
            continue
        if "=" in token and not token.startswith("-"):
            index += 1
            continue
        break
    argv = segment[index:]
    if not argv:
        return []
    if os.path.basename(argv[0]) in SHELLS and "-c" in argv[1:]:
        command_index = argv.index("-c") + 1
        if command_index < len(argv):
            return _shell_segments(argv[command_index])
    return [argv]


def _short_flags(args: list[str]) -> set[str]:
    flags: set[str] = set()
    for arg in args:
        if arg.startswith("-") and not arg.startswith("--"):
            flags.update(arg[1:])
    return flags


def _has_flag(args: list[str], short: str, long: str) -> bool:
    return long in args or short in _short_flags(args)


def _rm_operands(args: list[str]) -> list[str]:
    return [arg for arg in args if arg != "--" and not arg.startswith("-")]


def _is_temp_operand(path: str) -> bool:
    return path.startswith(("/tmp/", "/var/tmp/", "$TMPDIR/", "${TMPDIR}/", '"$TMPDIR/'))


def _is_root_or_home_operand(path: str) -> bool:
    return path in {"/", "~", "$HOME", "${HOME}"} or path.startswith(("~/", "$HOME/", "${HOME}/"))


def _git_parts(argv: list[str]) -> tuple[str, list[str]]:
    if not argv or os.path.basename(argv[0]) != "git":
        return "", []
    index = 1
    value_options = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
    while index < len(argv):
        arg = argv[index]
        if arg in value_options:
            index += 2
            continue
        if arg.startswith("-"):
            index += 1
            continue
        return arg, argv[index + 1 :]
    return "", []


def _matches(matcher: str, argv: list[str]) -> bool:
    executable = os.path.basename(argv[0]) if argv else ""
    args = argv[1:]
    if matcher in {"rm_recursive_force_root", "rm_recursive_force"}:
        if executable != "rm" or not _has_flag(args, "r", "--recursive") or not _has_flag(args, "f", "--force"):
            return False
        operands = _rm_operands(args)
        if not operands or all(_is_temp_operand(path) for path in operands):
            return False
        is_root = any(_is_root_or_home_operand(path) for path in operands)
        return is_root if matcher == "rm_recursive_force_root" else not is_root

    subcommand, git_args = _git_parts(argv)
    if not subcommand:
        return False
    if matcher == "git_checkout_worktree_path":
        return subcommand == "checkout" and "--" in git_args
    if matcher == "git_restore_worktree":
        if subcommand != "restore":
            return False
        staged = "--staged" in git_args or "S" in _short_flags(git_args)
        worktree = "--worktree" in git_args or "W" in _short_flags(git_args)
        return worktree or not staged
    if matcher == "git_reset_destructive":
        return subcommand == "reset" and any(arg in {"--hard", "--merge"} for arg in git_args)
    if matcher == "git_clean_force":
        force = _has_flag(git_args, "f", "--force")
        dry_run = _has_flag(git_args, "n", "--dry-run")
        return subcommand == "clean" and force and not dry_run
    if matcher == "git_push_force":
        short_force = "f" in _short_flags(git_args)
        return subcommand == "push" and ("--force" in git_args or short_force)
    if matcher == "git_branch_force_delete":
        return subcommand == "branch" and "D" in _short_flags(git_args)
    if matcher == "git_stash_delete":
        return subcommand == "stash" and bool(git_args) and git_args[0] in {"drop", "clear"}
    return False


def _evaluate_static(command: str, policy: dict[str, Any]) -> dict[str, Any]:
    try:
        invocations = _shell_segments(command)
    except ValueError as exc:
        return _decision("forbid", "command.parse-error", f"Unable to parse shell command safely: {exc}")
    best = dict(policy["default_decision"])
    best["schema_version"] = 1
    for argv in invocations:
        for rule in policy["rules"]:
            if _matches(rule["matcher"], argv) and DECISION_RANK[rule["decision"]] > DECISION_RANK[best["decision"]]:
                best = _decision(rule["decision"], rule["id"], rule["reason"])
    return best


def _canonical_guard_path(policy: dict[str, Any], explicit: str) -> Path:
    if explicit:
        return Path(explicit)
    helper = next(guard["helper"] for guard in policy["dynamic_guards"] if guard["kind"] == "canonical_git")
    return Path(__file__).resolve().parent / helper


def _evaluate_canonical_git(command: str, cwd: str, guard: Path) -> dict[str, Any]:
    try:
        has_git_invocation = any(
            argv and os.path.basename(argv[0]) == "git"
            for argv in _shell_segments(command)
        )
    except ValueError:
        has_git_invocation = "git" in command
    if not has_git_invocation:
        return _decision("allow", "git.no-invocation", "No Git invocation detected")
    if not guard.is_file():
        return _decision("forbid", "git.guard-unavailable", f"Canonical Git policy helper is unavailable: {guard}")
    try:
        result = subprocess.run(
            [sys.executable, str(guard), "--cwd", cwd, "--command", command],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return _decision("forbid", "git.guard-error", f"Canonical Git policy check failed closed: {exc}")
    if result.returncode == 0:
        return _decision("allow", "git.canonical-allow", "Canonical Git guard allowed the command")
    reason = result.stderr.strip() or f"Canonical Git guard failed with exit {result.returncode}"
    return _decision("forbid", "git.canonical-worktree", reason)


def evaluate_command(command: str, cwd: str, policy: dict[str, Any], guard_path: str = "") -> dict[str, Any]:
    static = _evaluate_static(command, policy)
    dynamic = _evaluate_canonical_git(command, cwd, _canonical_guard_path(policy, guard_path))
    return dynamic if DECISION_RANK[dynamic["decision"]] > DECISION_RANK[static["decision"]] else static


def _validate_fixtures(policy: dict[str, Any]) -> None:
    for fixture in policy["fixtures"]:
        if not isinstance(fixture, dict) or not all(key in fixture for key in ("name", "command", "decision", "rule_id")):
            raise PolicyError("command policy fixture is incomplete")
        actual = _evaluate_static(fixture["command"], policy)
        if (actual["decision"], actual["rule_id"]) != (fixture["decision"], fixture["rule_id"]):
            raise PolicyError(
                f"command policy fixture failed: {fixture['name']}: "
                f"expected {fixture['decision']}/{fixture['rule_id']}, "
                f"got {actual['decision']}/{actual['rule_id']}"
            )


def _exit_for_decision(decision: str) -> int:
    if decision == "allow":
        return 0
    if decision == "prompt":
        return PROMPT_EXIT
    return FORBID_EXIT


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("check-command", "validate"))
    parser.add_argument("--command", default="")
    parser.add_argument("--cwd", default=os.getcwd())
    parser.add_argument("--policy", default="")
    parser.add_argument("--canonical-git-guard", default="")
    args = parser.parse_args()
    policy_path = Path(args.policy) if args.policy else _default_policy_path()
    try:
        policy = _load_policy(policy_path)
        _validate_fixtures(policy)
    except PolicyError as exc:
        if args.action == "check-command":
            print(json.dumps(_policy_error(str(exc)), sort_keys=True))
        else:
            print(f"BLOCKED: {exc}", file=sys.stderr)
        return POLICY_ERROR_EXIT
    if args.action == "validate":
        print(f"Command policy valid: {policy_path}")
        return 0
    result = evaluate_command(args.command, args.cwd, policy, args.canonical_git_guard)
    print(json.dumps(result, sort_keys=True))
    return _exit_for_decision(result["decision"])


if __name__ == "__main__":
    raise SystemExit(main())
