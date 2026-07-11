#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Runtime-neutral, argv-first shell-command safety-floor decisions."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

FORBID_EXIT = 20
POLICY_ERROR_EXIT = 21
SHELL_OPERATORS = {"&&", "||", ";", "|"}
SHELLS = {"bash", "dash", "ksh", "sh", "zsh"}
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
DECISION_RANK = {"allow": 0, "forbid": 1}
WORKER_ENV_KEYS = (
    "FULL_LOOP_HEADLESS",
    "AIDEVOPS_HEADLESS",
    "OPENCODE_HEADLESS",
    "CLAUDE_HEADLESS",
    "Claude_HEADLESS",
    "HEADLESS",
    "GITHUB_ACTIONS",
)


class PolicyError(ValueError):
    """Raised when required policy data cannot be trusted."""


class CommandParseError(ValueError):
    """Raised when shell syntax cannot be represented as deterministic argv."""


def _decision(decision: str, rule_id: str, reason: str) -> dict[str, Any]:
    return {
        "schema_version": 2,
        "decision": decision,
        "rule_id": rule_id,
        "reason": reason,
    }


def _policy_error(reason: str) -> dict[str, Any]:
    return _decision("forbid", "policy.invalid", reason)


def _parse_error(reason: str) -> dict[str, Any]:
    return _decision("forbid", "command.parse-error", reason)


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


def _require_dynamic_guard(
    guards: Any, kind: str, helper: str, error: str
) -> None:
    matches = [
        guard
        for guard in guards or []
        if isinstance(guard, dict) and guard.get("kind") == kind
    ]
    if (
        len(matches) != 1
        or matches[0].get("helper") != helper
        or matches[0].get("decision") != "forbid"
    ):
        raise PolicyError(error)


def _validate_rules(rules: Any) -> None:
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
        if rule.get("decision") != "forbid" or not isinstance(rule.get("reason"), str):
            raise PolicyError(f"command policy rule must be forbid with a reason: {rule_id}")
        seen_ids.add(rule_id)
        seen_matchers.add(matcher)
    if seen_matchers != KNOWN_MATCHERS:
        raise PolicyError("command policy must define every required matcher exactly once")


def _validate_policy_shape(policy: Any) -> None:
    if not isinstance(policy, dict) or policy.get("schema_version") != 2:
        raise PolicyError("command policy schema_version must be 2")
    if policy.get("decision_order") != ["allow", "forbid"]:
        raise PolicyError("command policy decision_order must be allow, forbid")
    default = policy.get("default_decision")
    if not isinstance(default, dict) or default.get("decision") != "allow":
        raise PolicyError("command policy requires an allow default_decision")
    guards = policy.get("dynamic_guards")
    _require_dynamic_guard(
        guards,
        "canonical_git",
        "canonical-git-command-guard.py",
        "command policy requires exactly one canonical Git guard",
    )
    _require_dynamic_guard(
        guards,
        "worker_network",
        "network-tier-helper.sh",
        "command policy requires exactly one worker network guard",
    )
    _validate_rules(policy.get("rules"))
    fixtures = policy.get("fixtures")
    if not isinstance(fixtures, list) or not fixtures:
        raise PolicyError("command policy requires self-test fixtures")


def _validate_argv(value: Any) -> list[str]:
    if not isinstance(value, list) or not value:
        raise CommandParseError("argv must be a non-empty JSON array")
    if not all(isinstance(arg, str) for arg in value):
        raise CommandParseError("every argv element must be a string")
    if any("\x00" in arg for arg in value):
        raise CommandParseError("argv cannot contain NUL bytes")
    return value


def _scan_supported_shell(command: str) -> None:
    if not command.strip():
        raise CommandParseError("command is empty")
    if "\n" in command or "\r" in command:
        raise CommandParseError("multiline shell commands are unsupported")
    single = False
    double = False
    escaped = False
    for index, char in enumerate(command):
        single, double, escaped, consumed = _update_shell_quote_state(
            char, single, double, escaped
        )
        if consumed:
            continue
        if single:
            continue
        _validate_shell_character(command, index, char, double)
    if single or double or escaped:
        raise CommandParseError("unterminated shell quoting or escape")


def _update_shell_quote_state(
    char: str, single: bool, double: bool, escaped: bool
) -> tuple[bool, bool, bool, bool]:
    consumed = True
    if escaped:
        escaped = False
    elif char == "\\" and not single:
        escaped = True
    elif char == "'" and not double:
        single = not single
    elif char == '"' and not single:
        double = not double
    else:
        consumed = False
    return single, double, escaped, consumed


def _validate_shell_character(command: str, index: int, char: str, quoted: bool) -> None:
    if char in {"`", "$"}:
        raise CommandParseError("dynamic shell expansion is unsupported")
    if quoted:
        return
    next_char = command[index + 1] if index + 1 < len(command) else ""
    previous_char = command[index - 1] if index else ""
    if char in "<>":
        raise CommandParseError("shell redirection is unsupported")
    if char in "(){}":
        raise CommandParseError("shell grouping and subshell syntax are unsupported")
    if char == "&" and next_char != "&" and previous_char != "&":
        raise CommandParseError("background shell execution is unsupported")
    if char in "*[":
        raise CommandParseError("unquoted shell glob syntax is unsupported")


def _consume_option(
    argv: list[str], index: int, value_options: set[str], flag_options: set[str]
) -> int:
    arg = argv[index]
    next_index: int
    if arg == "--":
        next_index = index + 1
    elif arg in value_options:
        if index + 1 >= len(argv):
            raise CommandParseError(f"missing value for wrapper option {arg}")
        next_index = index + 2
    elif any(arg.startswith(option + "=") for option in value_options if option.startswith("--")):
        next_index = index + 1
    elif any(
        arg.startswith(option) and arg != option
        for option in value_options
        if option.startswith("-") and not option.startswith("--")
    ):
        next_index = index + 1
    elif arg in flag_options:
        next_index = index + 1
    else:
        short_flags = {
            option[1:]
            for option in flag_options
            if re.fullmatch(r"-[A-Za-z0-9]", option)
        }
        if not (
            arg.startswith("-")
            and not arg.startswith("--")
            and set(arg[1:]).issubset(short_flags)
        ):
            raise CommandParseError(f"unsupported wrapper option {arg}")
        next_index = index + 1
    return next_index


def _unwrap_env(argv: list[str]) -> list[str]:
    index = 1
    values = {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"}
    flags = {"-i", "--ignore-environment", "-0", "--null", "-v", "--debug"}
    while index < len(argv) and argv[index].startswith("-"):
        option = argv[index]
        if option in {"-C", "--chdir", "-S", "--split-string"} or option.startswith(("-C", "-S", "--chdir=", "--split-string=")):
            raise CommandParseError(f"env option changes command interpretation and is unsupported: {option}")
        index = _consume_option(argv, index, values, flags)
    while index < len(argv) and "=" in argv[index] and not argv[index].startswith("="):
        name = argv[index].split("=", 1)[0]
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            break
        if _is_safety_sensitive_assignment(name):
            raise CommandParseError(f"safety-affecting environment assignment is unsupported: {name}")
        index += 1
    if index >= len(argv):
        raise CommandParseError("env wrapper has no command")
    return argv[index:]


def _unwrap_sudo(argv: list[str]) -> list[str]:
    index = 1
    values = {
        "-u", "--user", "-g", "--group", "-h", "--host", "-p", "--prompt",
        "-C", "--close-from", "-T", "--command-timeout", "-R", "--chroot",
        "-D", "--chdir",
    }
    flags = {
        "-A", "--askpass", "-b", "--background", "-E", "--preserve-env",
        "-H", "--set-home", "-n", "--non-interactive", "-P", "--preserve-groups",
        "-S", "--stdin", "-i", "--login", "-s", "--shell", "-k", "-K", "-v",
    }
    while index < len(argv) and argv[index].startswith("-"):
        option = argv[index]
        if option in {"-D", "--chdir", "-R", "--chroot"} or option.startswith(("-D", "-R", "--chdir=", "--chroot=")):
            raise CommandParseError(f"sudo option changes command location and is unsupported: {option}")
        index = _consume_option(argv, index, values, flags)
    if index >= len(argv):
        raise CommandParseError("sudo wrapper has no command")
    return argv[index:]


def _unwrap_time(argv: list[str]) -> list[str]:
    index = 1
    values = {"-f", "--format", "-o", "--output"}
    flags = {"-a", "--append", "-p", "--portability", "-v", "--verbose", "-q", "--quiet"}
    while index < len(argv) and argv[index].startswith("-"):
        index = _consume_option(argv, index, values, flags)
    if index >= len(argv):
        raise CommandParseError("time wrapper has no command")
    return argv[index:]


def _next_shell_option(argv: list[str], index: int) -> int | None:
    arg = argv[index]
    value_options = {"-O", "+O", "-o", "+o", "--init-file", "--rcfile"}
    if arg in {"--init-file", "--rcfile"} or arg.startswith(
        ("--init-file=", "--rcfile=")
    ):
        raise CommandParseError(f"shell startup file option is unsupported: {arg}")
    if arg in value_options:
        if index + 1 >= len(argv):
            raise CommandParseError(f"missing value for shell option {arg}")
        return index + 2
    if any(
        arg.startswith(option + "=")
        for option in value_options
        if option.startswith("--")
    ):
        return index + 1
    if arg.startswith(("-", "+")):
        return index + 1
    return None


def _shell_command_index(argv: list[str]) -> int | None:
    index = 1
    command_index: int | None = None
    while index < len(argv) and command_index is None:
        arg = argv[index]
        if arg == "--":
            break
        if arg.startswith("-") and not arg.startswith("--") and "c" in arg[1:]:
            command_index = index + 1
            continue
        next_index = _next_shell_option(argv, index)
        if next_index is None:
            break
        index = next_index
    return command_index


def _is_safety_sensitive_assignment(name: str) -> bool:
    upper = name.upper()
    return upper.endswith("_PROXY") or upper.startswith("GIT_CONFIG_") or upper in {
        "ALL_PROXY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR",
        "GIT_CONFIG_PARAMETERS",
        "GIT_DIR",
        "GIT_EXEC_PATH",
        "GIT_OBJECT_DIRECTORY",
        "GIT_PROXY_COMMAND",
        "GIT_SSH",
        "GIT_SSH_COMMAND",
        "GIT_WORK_TREE",
        "CURL_HOME",
        "WGETRC",
        "BASH_ENV",
        "ENV",
        "ZDOTDIR",
    }


def _strip_leading_assignments(argv: list[str]) -> list[str]:
    index = 0
    while index < len(argv) and "=" in argv[index]:
        name = argv[index].split("=", 1)[0]
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            break
        if _is_safety_sensitive_assignment(name):
            raise CommandParseError(f"safety-affecting environment assignment is unsupported: {name}")
        index += 1
    if index >= len(argv):
        raise CommandParseError("environment assignment has no command")
    return argv[index:]


def _validate_launcher(argv: list[str], executable: str) -> None:
    blocked = {
        ".", "!", "alias", "builtin", "case", "coproc", "declare", "do",
        "done", "elif", "else", "enable", "esac", "eval", "export", "fi",
        "for", "function", "if", "local", "parallel", "readonly", "select",
        "set", "source", "then", "trap", "typeset", "unalias", "unset",
        "until", "while", "xargs",
    }
    if executable in blocked:
        raise CommandParseError(
            f"dynamic shell control or launcher is unsupported: {executable}"
        )
    if executable == "find" and any(
        arg in {"-exec", "-execdir", "-ok", "-okdir"} for arg in argv[1:]
    ):
        raise CommandParseError("find command execution actions are unsupported")


def _unwrap_nohup(argv: list[str]) -> list[str]:
    index = 2 if len(argv) > 1 and argv[1] == "--" else 1
    if index >= len(argv) or argv[index].startswith("--"):
        raise CommandParseError("nohup wrapper has no supported command")
    return argv[index:]


def _unwrap_exec(argv: list[str]) -> list[str]:
    index = 1
    while index < len(argv) and argv[index].startswith("-"):
        index = _consume_option(argv, index, {"-a"}, {"-c", "-l"})
    if index >= len(argv):
        raise CommandParseError("exec wrapper has no command")
    return argv[index:]


def _unwrap_command(argv: list[str]) -> list[str] | None:
    if len(argv) > 1 and argv[1] in {"-v", "-V"}:
        return None
    index = 1
    while index < len(argv) and argv[index] in {"-p", "--"}:
        index += 1
    if index >= len(argv):
        raise CommandParseError("command wrapper has no command")
    return argv[index:]


def _terminal_invocations(argv: list[str], executable: str) -> list[list[str]]:
    if executable in SHELLS:
        command_index = _shell_command_index(argv)
        if command_index is None:
            return [argv]
        if command_index >= len(argv):
            raise CommandParseError("shell -c option has no command string")
        return _shell_invocations(argv[command_index])
    if executable in {"cd", "pushd", "popd"}:
        raise CommandParseError(
            "directory-changing shell builtins are unsupported; use tool cwd"
        )
    return [argv]


def _expand_argv(argv: list[str]) -> list[list[str]]:
    current = _validate_argv(argv)
    while current:
        current = _strip_leading_assignments(current)
        executable = os.path.basename(current[0])
        _validate_launcher(current, executable)
        unwrap = {
            "env": _unwrap_env,
            "sudo": _unwrap_sudo,
            "nohup": _unwrap_nohup,
            "time": _unwrap_time,
            "exec": _unwrap_exec,
        }.get(executable)
        if unwrap is not None:
            current = unwrap(current)
            continue
        if executable == "command":
            unwrapped = _unwrap_command(current)
            if unwrapped is None:
                return [current]
            current = unwrapped
            continue
        return _terminal_invocations(current, executable)
    raise CommandParseError("wrapper chain has no command")


def _shell_invocations(command: str) -> list[list[str]]:
    _scan_supported_shell(command)
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()")
        lexer.whitespace_split = True
        lexer.commenters = ""
        tokens = list(lexer)
    except ValueError as exc:
        raise CommandParseError(f"unable to tokenize shell command: {exc}") from exc
    invocations: list[list[str]] = []
    segment: list[str] = []
    expect_command = True
    for token in tokens:
        if token in SHELL_OPERATORS:
            if expect_command or not segment:
                raise CommandParseError("empty or repeated shell operator segment")
            invocations.extend(_expand_argv(segment))
            segment = []
            expect_command = True
            continue
        if token and all(char in ";&|()" for char in token):
            raise CommandParseError(f"unsupported shell operator {token}")
        segment.append(token)
        expect_command = False
    if not segment:
        raise CommandParseError("shell command ends with an operator")
    invocations.extend(_expand_argv(segment))
    if not invocations:
        raise CommandParseError("command produced no executable argv")
    return invocations


def _short_flags(args: list[str]) -> set[str]:
    flags: set[str] = set()
    for arg in args:
        if arg == "--":
            break
        if arg.startswith("-") and not arg.startswith("--"):
            flags.update(arg[1:])
    return flags


def _has_flag(args: list[str], short: str, long: str) -> bool:
    option_args = args[:args.index("--")] if "--" in args else args
    return long in option_args or short in _short_flags(option_args)


def _rm_operands(args: list[str]) -> list[str]:
    operands: list[str] = []
    after_options = False
    for arg in args:
        if arg == "--":
            after_options = True
            continue
        if after_options or not arg.startswith("-"):
            operands.append(arg)
    return operands


def _canonical_operand(path: str, cwd: str) -> str | None:
    if not path or "\x00" in path or any(part == ".." for part in Path(path).parts):
        return None
    if path.startswith(("$", "~")):
        return None
    candidate = path if os.path.isabs(path) else os.path.join(cwd, path)
    return os.path.realpath(os.path.normpath(candidate))


def _is_temp_operand(path: str, cwd: str) -> bool:
    canonical = _canonical_operand(path, cwd)
    if not canonical:
        return False
    # nosec B108 -- these canonical roots classify operands; no temp file is created.
    roots = ["/tmp", "/var/tmp"]
    tmpdir = os.environ.get("TMPDIR", "")
    if tmpdir:
        roots.append(tmpdir)
    for root in roots:
        canonical_root = os.path.realpath(os.path.normpath(root))
        try:
            if os.path.commonpath([canonical, canonical_root]) == canonical_root and canonical != canonical_root:
                return True
        except ValueError:
            continue
    return False


def _is_root_or_home_operand(path: str, cwd: str) -> bool:
    canonical = _canonical_operand(path, cwd)
    if not canonical:
        return path in {"/", "~", "$HOME", "${HOME}"}
    home = os.path.realpath(str(Path.home()))
    return canonical == "/" or canonical == home or canonical.startswith(home + os.sep)


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


def _matches_rm(matcher: str, argv: list[str], cwd: str) -> bool:
    executable = os.path.basename(argv[0]) if argv else ""
    args = argv[1:]
    required_flags = _has_flag(args, "r", "--recursive") and _has_flag(
        args, "f", "--force"
    )
    if executable != "rm" or not required_flags:
        return False
    operands = _rm_operands(args)
    if not operands or all(_is_temp_operand(path, cwd) for path in operands):
        return False
    is_root = any(_is_root_or_home_operand(path, cwd) for path in operands)
    return is_root if matcher == "rm_recursive_force_root" else not is_root


def _matches_git_restore(subcommand: str, args: list[str]) -> bool:
    if subcommand != "restore":
        return False
    flags = _short_flags(args)
    staged = "--staged" in args or "S" in flags
    worktree = "--worktree" in args or "W" in flags
    return worktree or not staged


def _matches_git(matcher: str, subcommand: str, args: list[str]) -> bool:
    predicates = {
        "git_checkout_worktree_path": subcommand == "checkout" and "--" in args,
        "git_restore_worktree": _matches_git_restore(subcommand, args),
        "git_reset_destructive": subcommand == "reset"
        and any(arg in {"--hard", "--merge"} for arg in args),
        "git_clean_force": subcommand == "clean"
        and _has_flag(args, "f", "--force")
        and not _has_flag(args, "n", "--dry-run"),
        "git_push_force": subcommand == "push"
        and ("--force" in args or "f" in _short_flags(args)),
        "git_branch_force_delete": subcommand == "branch"
        and "D" in _short_flags(args),
        "git_stash_delete": subcommand == "stash"
        and bool(args)
        and args[0] in {"drop", "clear"},
    }
    return predicates.get(matcher, False)


def _matches(matcher: str, argv: list[str], cwd: str) -> bool:
    if matcher in {"rm_recursive_force_root", "rm_recursive_force"}:
        return _matches_rm(matcher, argv, cwd)
    subcommand, git_args = _git_parts(argv)
    if not subcommand:
        return False
    return _matches_git(matcher, subcommand, git_args)


def _evaluate_static(invocations: list[list[str]], cwd: str, policy: dict[str, Any]) -> dict[str, Any]:
    best = dict(policy["default_decision"])
    best["schema_version"] = 2
    for argv in invocations:
        for rule in policy["rules"]:
            if _matches(rule["matcher"], argv, cwd) and DECISION_RANK[rule["decision"]] > DECISION_RANK[best["decision"]]:
                best = _decision(rule["decision"], rule["id"], rule["reason"])
    return best


def _canonical_guard_path(policy: dict[str, Any], explicit: str) -> Path:
    if explicit:
        return Path(explicit)
    helper = next(guard["helper"] for guard in policy["dynamic_guards"] if guard["kind"] == "canonical_git")
    return Path(__file__).resolve().parent / helper


def _evaluate_canonical_git(invocations: list[list[str]], cwd: str, guard: Path) -> dict[str, Any]:
    git_invocations = [argv for argv in invocations if argv and os.path.basename(argv[0]) == "git"]
    if not git_invocations:
        return _decision("allow", "git.no-invocation", "No Git invocation detected")
    if not guard.is_file():
        return _decision("forbid", "git.guard-unavailable", f"Canonical Git policy helper is unavailable: {guard}")
    for argv in git_invocations:
        try:
            result = subprocess.run(
                [sys.executable, str(guard), "--cwd", cwd, "--argv-json", json.dumps(argv[1:])],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            return _decision("forbid", "git.guard-error", f"Canonical Git policy check failed closed: {exc}")
        if result.returncode != 0:
            reason = result.stderr.strip() or f"Canonical Git guard failed with exit {result.returncode}"
            return _decision("forbid", "git.canonical-worktree", reason)
    return _decision("allow", "git.canonical-allow", "Canonical Git guard allowed every Git argv")


def _normalize_host(value: str) -> str | None:
    candidate = value.strip()
    if not candidate or any(char in candidate for char in "\x00\n\r"):
        return None
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", candidate):
        parsed = urlsplit(candidate)
        return parsed.hostname.lower().rstrip(".") if parsed.hostname else None
    scp_match = re.match(r"^(?:[^@/:]+@)?(\[[^]]+\]|[^/:]+):.+$", candidate)
    if scp_match and not re.match(r"^[A-Za-z]:[\\/]", candidate):
        candidate = scp_match.group(1).strip("[]").lower().rstrip(".")
    elif "@" in candidate and "/" not in candidate:
        candidate = candidate.rsplit("@", 1)[1]
    if "/" in candidate:
        candidate = candidate.split("/", 1)[0]
    if candidate.startswith("[") and "]" in candidate:
        candidate = candidate[1:candidate.index("]")]
    elif candidate.count(":") == 1:
        candidate = candidate.split(":", 1)[0]
    candidate = candidate.rstrip(".").lower()
    try:
        ipaddress.ip_address(candidate)
        return candidate
    except ValueError:
        pass
    if re.fullmatch(r"[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?", candidate) and "." in candidate:
        return candidate
    return None


def _add_destination(result: dict[str, Any], value: str, label: str) -> None:
    host = _normalize_host(value)
    if host:
        result["destinations"].append(host)
    else:
        result["unclassified"].append(f"{label}:{value}")


def _option_value(argv: list[str], index: int) -> tuple[str | None, int]:
    if "=" in argv[index]:
        return argv[index].split("=", 1)[1], index + 1
    if index + 1 >= len(argv):
        return None, index + 1
    return argv[index + 1], index + 2


def _analyze_curl(argv: list[str], result: dict[str, Any]) -> None:
    value_options = {
        "--request", "--header", "--data", "--data-raw", "--data-binary", "--form",
        "--user", "--output", "--referer", "--user-agent", "--cookie", "--cookie-jar",
        "--cacert", "--cert", "--key", "--max-time", "--connect-timeout", "--retry",
        "--proto", "--proto-redir", "--interface", "--dns-interface", "--dns-ipv4-addr",
        "--dns-ipv6-addr",
    }
    destination_options = {"--url", "--proxy", "--preproxy"}
    short_value_options = {"-A", "-b", "-c", "-d", "-D", "-e", "-E", "-F", "-H", "-K", "-m", "-o", "-Q", "-r", "-T", "-u", "-w", "-X", "-Y", "-z"}
    index = 1
    while index < len(argv):
        arg = argv[index]
        option = arg.split("=", 1)[0]
        if option in destination_options:
            value, index = _option_value(argv, index)
            if value is None:
                result["unclassified"].append(f"missing:{option}")
            else:
                _add_destination(result, value, option)
            continue
        if option == "--resolve":
            value, index = _option_value(argv, index)
            match = re.match(r"^(\[[^]]+\]|[^:]+):[^:]*:(.+)$", value or "")
            if not match:
                result["unclassified"].append(f"resolve:{value or ''}")
            else:
                _add_destination(result, match.group(1), "resolve-host")
                _add_destination(result, match.group(2), "resolve-address")
            continue
        if option == "--connect-to":
            value, index = _option_value(argv, index)
            parts = (value or "").split(":")
            if len(parts) != 4:
                result["unclassified"].append(f"connect-to:{value or ''}")
            else:
                if parts[0]:
                    _add_destination(result, parts[0], "connect-source")
                if parts[2]:
                    _add_destination(result, parts[2], "connect-target")
            continue
        if option in {"--config", "-K"} or arg.startswith("-K"):
            result["unclassified"].append("curl-config-file")
            index += 2 if arg in {"--config", "-K"} else 1
            continue
        if option in value_options:
            _, index = _option_value(argv, index)
            continue
        if arg == "-x" or arg.startswith("-x"):
            value = argv[index + 1] if arg == "-x" and index + 1 < len(argv) else arg[2:]
            index += 2 if arg == "-x" else 1
            _add_destination(result, value, "proxy")
            continue
        if arg in short_value_options:
            if index + 1 >= len(argv):
                result["unclassified"].append(f"missing:{arg}")
                index += 1
            else:
                index += 2
            continue
        if any(arg.startswith(option) and arg != option for option in short_value_options):
            index += 1
            continue
        if arg.startswith("-"):
            index += 1
            continue
        _add_destination(result, arg, "url")
        index += 1


def _analyze_wget(argv: list[str], result: dict[str, Any]) -> None:
    index = 1
    value_options = {
        "-O", "--output-document", "-o", "--output-file", "-a", "--append-output",
        "-P", "--directory-prefix", "--header", "--user", "--password", "--timeout",
        "--tries", "--wait", "--user-agent", "--referer",
    }
    short_value_options = {"-O", "-o", "-a", "-P", "-U", "-t", "-T", "-w"}
    while index < len(argv):
        arg = argv[index]
        option = arg.split("=", 1)[0]
        if option == "--proxy":
            value, index = _option_value(argv, index)
            _add_destination(result, value or "", "proxy")
            continue
        if option in {"-e", "--execute"}:
            value, index = _option_value(argv, index)
            match = re.match(r"(?i)^(?:https?|ftp)_proxy=(.+)$", value or "")
            if match:
                _add_destination(result, match.group(1), "proxy")
            elif value and "proxy" not in value.lower():
                result["unclassified"].append(f"wget-execute:{value}")
            continue
        if option in {"-i", "--input-file"}:
            result["unclassified"].append("wget-input-file")
            index += 2 if arg == option and "=" not in arg else 1
            continue
        if option in value_options:
            _, index = _option_value(argv, index)
            continue
        if arg in short_value_options:
            index += 2 if index + 1 < len(argv) else 1
            continue
        if any(arg.startswith(option) and arg != option for option in short_value_options):
            index += 1
            continue
        if arg.startswith("-"):
            index += 1
            continue
        _add_destination(result, arg, "url")
        index += 1


def _analyze_ssh(argv: list[str], result: dict[str, Any]) -> None:
    value_options = {"-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-L", "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w", "-J"}
    index = 1
    target = ""
    while index < len(argv):
        arg = argv[index]
        if arg.startswith("-J") and arg != "-J":
            _add_destination(result, arg[2:], "proxy-jump")
            index += 1
            continue
        if arg in value_options:
            if index + 1 >= len(argv):
                result["unclassified"].append(f"missing:{arg}")
                break
            value = argv[index + 1]
            if arg == "-J":
                for jump in value.split(","):
                    _add_destination(result, jump, "proxy-jump")
            elif arg == "-F":
                result["unclassified"].append("ssh-config-file")
            elif arg == "-W":
                _add_destination(result, value.rsplit(":", 1)[0], "stdio-forward")
            elif arg in {"-L", "-R"}:
                parts = value.split(":")
                if len(parts) >= 3:
                    _add_destination(result, parts[-2], "port-forward")
                else:
                    result["unclassified"].append(f"ssh-forward:{value}")
            elif arg == "-o":
                lower = value.lower()
                if lower.startswith("proxyjump="):
                    _add_destination(result, value.split("=", 1)[1], "proxy-jump")
                elif lower.startswith("proxycommand="):
                    result["unclassified"].append("ssh-proxy-command")
            index += 2
            continue
        if arg.startswith("-"):
            index += 1
            continue
        target = arg
        break
    if target:
        _add_destination(result, target, "ssh-target")
    else:
        result["unclassified"].append("ssh-target-missing")


def _analyze_scp(argv: list[str], result: dict[str, Any]) -> None:
    value_options = {"-c", "-F", "-i", "-J", "-l", "-o", "-P", "-S", "-X"}
    index = 1
    remote_count = 0
    while index < len(argv):
        arg = argv[index]
        if arg in value_options:
            if index + 1 >= len(argv):
                result["unclassified"].append(f"missing:{arg}")
                break
            if arg == "-J":
                _add_destination(result, argv[index + 1], "proxy-jump")
            elif arg in {"-F", "-S"}:
                result["unclassified"].append(f"scp-hidden-network-config:{arg}")
            elif arg == "-o" and argv[index + 1].lower().startswith("proxycommand="):
                result["unclassified"].append("scp-proxy-command")
            index += 2
            continue
        if arg.startswith("-"):
            index += 1
            continue
        if _normalize_host(arg):
            _add_destination(result, arg, "scp-remote")
            remote_count += 1
        index += 1
    if remote_count == 0:
        result["unclassified"].append("scp-remote-missing")


def _resolve_git_remote(cwd: str, remote: str) -> list[str]:
    git_binary = "/usr/bin/git" if Path("/usr/bin/git").is_file() else "git"
    try:
        resolved = subprocess.run(
            [git_binary, "-C", cwd, "remote", "get-url", "--all", remote],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    return [line for line in resolved.stdout.splitlines() if line] if resolved.returncode == 0 else []


def _git_effective_cwd(argv: list[str], cwd: str) -> str:
    effective = cwd
    index = 1
    while index < len(argv):
        if argv[index] == "-C" and index + 1 < len(argv):
            target = argv[index + 1]
            effective = target if os.path.isabs(target) else os.path.abspath(os.path.join(effective, target))
            index += 2
            continue
        if not argv[index].startswith("-"):
            break
        index += 1
    return effective


def _analyze_git(argv: list[str], cwd: str, result: dict[str, Any]) -> bool:
    subcommand, args = _git_parts(argv)
    if subcommand not in {"clone", "fetch", "pull", "push", "ls-remote", "submodule"}:
        return False
    if subcommand == "submodule":
        result["unclassified"].append("git-submodule-configured-remotes")
        return True
    for index, arg in enumerate(argv[:-1]):
        if arg == "-c" and any(token in argv[index + 1].lower() for token in ("proxy", "insteadof")):
            result["unclassified"].append("git-network-config-override")
        if arg == "--config-env":
            result["unclassified"].append("git-config-env-override")
    value_options = {
        "-b", "--branch", "-o", "--origin", "-c", "--config", "--depth",
        "--reference", "--reference-if-able", "--separate-git-dir", "-j", "--jobs",
        "--filter", "--upload-pack", "--receive-pack", "--exec",
    }
    if subcommand == "clone":
        value_options.add("-u")
    positionals: list[str] = []
    explicit_repo = ""
    index = 0
    while index < len(args):
        arg = args[index]
        option = arg.split("=", 1)[0]
        if option == "--repo":
            value, index = _option_value(args, index)
            explicit_repo = value or ""
            continue
        if option in value_options:
            index += 1 if "=" in arg else 2
            continue
        if arg.startswith("-"):
            index += 1
            continue
        positionals.append(arg)
        index += 1
    candidate = explicit_repo or (positionals[0] if positionals else "")
    if not candidate:
        result["unclassified"].append(f"git-{subcommand}-destination-missing")
        return True
    host = _normalize_host(candidate)
    if host:
        result["destinations"].append(host)
        return True
    if subcommand == "clone" and candidate.startswith(("/", "./", "../", "file://")):
        result["requires_destination"] = False
        return True
    remotes = _resolve_git_remote(_git_effective_cwd(argv, cwd), candidate)
    if not remotes:
        result["unclassified"].append(f"git-remote:{candidate}")
        return True
    for remote in remotes:
        _add_destination(result, remote, "git-remote")
    return True


def analyze_network_argv(argv: list[str], cwd: str) -> dict[str, Any]:
    exact = _validate_argv(argv)
    executable = os.path.basename(exact[0]).lower()
    result: dict[str, Any] = {
        "recognized": False,
        "requires_destination": True,
        "destinations": [],
        "unclassified": [],
    }
    if executable == "curl":
        result["recognized"] = True
        _analyze_curl(exact, result)
    elif executable == "wget":
        result["recognized"] = True
        _analyze_wget(exact, result)
    elif executable == "ssh":
        result["recognized"] = True
        _analyze_ssh(exact, result)
    elif executable == "scp":
        result["recognized"] = True
        _analyze_scp(exact, result)
    elif executable == "git":
        result["recognized"] = _analyze_git(exact, cwd, result)
    elif executable in {"dig", "nslookup", "host"}:
        result["recognized"] = True
        candidates = [arg for arg in exact[1:] if not arg.startswith(("-", "+", "@"))]
        if not candidates:
            result["unclassified"].append("dns-query-destination-missing")
        else:
            _add_destination(result, candidates[0], "dns-query")
    result["destinations"] = sorted(set(result["destinations"]))
    return result


def _network_guard_path(policy: dict[str, Any], explicit: str) -> Path:
    if explicit:
        return Path(explicit)
    override = os.environ.get("AIDEVOPS_NETWORK_TIER_HELPER", "")
    if override:
        return Path(override)
    helper = next(
        guard["helper"]
        for guard in policy["dynamic_guards"]
        if guard["kind"] == "worker_network"
    )
    return Path(__file__).resolve().parent / helper


def _evaluate_worker_network(
    invocations: list[list[str]], cwd: str, helper: Path, worker_id: str
) -> dict[str, Any]:
    if not helper.is_file():
        return _decision("forbid", "network.helper-unavailable", f"Required worker network policy helper is unavailable: {helper}")
    for argv in invocations:
        try:
            result = subprocess.run(
                [
                    "/bin/bash", str(helper), "check-argv", json.dumps(argv),
                    "--cwd", cwd, "--worker-id", worker_id,
                ],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            return _decision("forbid", "network.helper-error", f"Worker network policy failed closed: {exc}")
        if result.returncode != 0:
            reason = result.stderr.strip() or "Worker network policy denied or could not classify the command destination"
            return _decision("forbid", "network.worker-policy", reason)
    return _decision("allow", "network.worker-allow", "Worker network policy allowed every argv")


def evaluate_invocations(
    invocations: list[list[str]],
    cwd: str,
    policy: dict[str, Any],
    guard_path: str = "",
    worker: bool = False,
    worker_id: str = "unknown",
    network_helper: str = "",
) -> dict[str, Any]:
    decisions = [
        _evaluate_static(invocations, cwd, policy),
        _evaluate_canonical_git(invocations, cwd, _canonical_guard_path(policy, guard_path)),
    ]
    if worker:
        decisions.append(
            _evaluate_worker_network(
                invocations, cwd, _network_guard_path(policy, network_helper), worker_id
            )
        )
    return max(decisions, key=lambda item: DECISION_RANK[item["decision"]])


def _fixture_invocations(fixture: dict[str, Any]) -> tuple[list[list[str]], bool]:
    has_command = "command" in fixture
    has_argv = "argv" in fixture
    if has_command == has_argv:
        raise PolicyError("command policy fixture requires exactly one of command or argv")
    try:
        invocations = _shell_invocations(fixture["command"]) if has_command else _expand_argv(_validate_argv(fixture["argv"]))
    except CommandParseError as exc:
        if fixture.get("rule_id") == "command.parse-error":
            return [], True
        raise PolicyError(f"command policy fixture parse failed: {fixture.get('name', '?')}: {exc}") from exc
    return invocations, False


def _validate_fixtures(policy: dict[str, Any]) -> None:
    for fixture in policy["fixtures"]:
        if not isinstance(fixture, dict) or not all(key in fixture for key in ("name", "decision", "rule_id")):
            raise PolicyError("command policy fixture is incomplete")
        invocations, rejected = _fixture_invocations(fixture)
        if fixture["rule_id"] == "command.parse-error":
            if not rejected:
                raise PolicyError(
                    f"command policy fixture should fail parsing but did not: {fixture['name']}"
                )
            actual = _parse_error("fixture intentionally rejected")
        else:
            actual = _evaluate_static(invocations, "/work", policy)
        if (actual["decision"], actual["rule_id"]) != (fixture["decision"], fixture["rule_id"]):
            raise PolicyError(
                f"command policy fixture failed: {fixture['name']}: "
                f"expected {fixture['decision']}/{fixture['rule_id']}, "
                f"got {actual['decision']}/{actual['rule_id']}"
            )


def _worker_from_environment() -> bool:
    if os.environ.get("AIDEVOPS_WORKER_ID", ""):
        return True
    return any(os.environ.get(key, "").lower() in {"1", "true", "yes"} for key in WORKER_ENV_KEYS)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("check-command", "validate", "network-destinations"))
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--command", default="")
    source.add_argument("--argv-json", default="")
    parser.add_argument("--cwd", default=os.getcwd())
    parser.add_argument("--policy", default="")
    parser.add_argument("--canonical-git-guard", default="")
    parser.add_argument("--network-helper", default="")
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--worker-id", default=os.environ.get("AIDEVOPS_WORKER_ID", "unknown"))
    args = parser.parse_args()

    try:
        if args.argv_json:
            invocations = _expand_argv(_validate_argv(json.loads(args.argv_json)))
        elif args.command:
            invocations = _shell_invocations(args.command)
        else:
            invocations = []
    except (json.JSONDecodeError, CommandParseError) as exc:
        print(json.dumps(_parse_error(str(exc)), sort_keys=True))
        return FORBID_EXIT

    if args.action == "network-destinations":
        if len(invocations) != 1:
            print(json.dumps({"recognized": False, "requires_destination": True, "destinations": [], "unclassified": ["network analysis requires exactly one argv"]}, sort_keys=True))
            return FORBID_EXIT
        print(json.dumps(analyze_network_argv(invocations[0], args.cwd), sort_keys=True))
        return 0

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
    if not invocations:
        print(json.dumps(_parse_error("command or argv input is required"), sort_keys=True))
        return FORBID_EXIT
    result = evaluate_invocations(
        invocations,
        args.cwd,
        policy,
        args.canonical_git_guard,
        args.worker or _worker_from_environment(),
        args.worker_id,
        args.network_helper,
    )
    print(json.dumps(result, sort_keys=True))
    return 0 if result["decision"] == "allow" else FORBID_EXIT


if __name__ == "__main__":
    raise SystemExit(main())
