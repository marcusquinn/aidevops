#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Deterministic command-wrapper and launcher expansion."""

from __future__ import annotations

import os
from collections.abc import Callable

from command_policy_dispatch import CommandParseError, _validate_argv
from command_policy_launcher_options import (
    _shell_command_index,
    _shell_value_option_index,
    _unwrap_command,
    _unwrap_exec,
)
from command_policy_wrapper_options import (
    _consume_option,
    _is_attached_value_option,
    _is_combined_short_flags,
    _is_safety_sensitive_assignment,
    _strip_leading_assignments,
    _unwrap_env,
    _unwrap_sudo,
    _unwrap_time,
)

__all__ = [
    "_consume_option",
    "_expand_argv",
    "_expand_launcher",
    "_expand_shell_launcher",
    "_is_attached_value_option",
    "_is_combined_short_flags",
    "_is_safety_sensitive_assignment",
    "_reject_dynamic_launcher",
    "_shell_command_index",
    "_shell_value_option_index",
    "_strip_leading_assignments",
    "_unwrap_command",
    "_unwrap_env",
    "_unwrap_exec",
    "_unwrap_simple_wrapper",
    "_unwrap_sudo",
    "_unwrap_time",
]

SHELLS = {"bash", "dash", "ksh", "sh", "zsh"}
ShellParser = Callable[[str], list[list[str]]]


def _expand_argv(argv: list[str], shell_parser: ShellParser) -> list[list[str]]:
    current = _validate_argv(argv)
    while current:
        current = _strip_leading_assignments(current)
        executable = os.path.basename(current[0])
        _reject_dynamic_launcher(current, executable)
        expanded, replacement = _expand_launcher(current, executable, shell_parser)
        if expanded is not None:
            return expanded
        current = replacement
    raise CommandParseError("wrapper chain has no command")


def _expand_launcher(
    argv: list[str], executable: str, shell_parser: ShellParser
) -> tuple[list[list[str]] | None, list[str]]:
    simple = _unwrap_simple_wrapper(argv, executable)
    if simple is not None:
        return None, simple
    if executable == "exec":
        return None, _unwrap_exec(argv)
    if executable == "command":
        expanded = [argv] if len(argv) > 1 and argv[1] in {"-v", "-V"} else None
        return expanded, argv if expanded else _unwrap_command(argv)
    if executable in SHELLS:
        return _expand_shell_launcher(argv, shell_parser), argv
    _reject_directory_launcher(executable)
    return [argv], argv


def _reject_directory_launcher(executable: str) -> None:
    if executable in {"cd", "pushd", "popd"}:
        raise CommandParseError(
            "directory-changing shell builtins are unsupported; use tool cwd"
        )


def _expand_shell_launcher(argv: list[str], shell_parser: ShellParser) -> list[list[str]]:
    command_index = _shell_command_index(argv)
    if command_index is None:
        return [argv]
    if command_index >= len(argv):
        raise CommandParseError("shell -c option has no command string")
    return shell_parser(argv[command_index])


def _reject_dynamic_launcher(argv: list[str], executable: str) -> None:
    dynamic = {
        ".", "!", "alias", "builtin", "case", "coproc", "declare", "do",
        "done", "elif", "else", "enable", "esac", "eval", "export", "fi",
        "for", "function", "if", "local", "parallel", "readonly", "select",
        "set", "source", "then", "trap", "typeset", "unalias", "unset",
        "until", "while", "xargs",
    }
    if executable in dynamic:
        raise CommandParseError(
            f"dynamic shell control or launcher is unsupported: {executable}"
        )
    if executable == "find" and any(
        arg in {"-exec", "-execdir", "-ok", "-okdir"} for arg in argv[1:]
    ):
        raise CommandParseError("find command execution actions are unsupported")


def _unwrap_simple_wrapper(argv: list[str], executable: str) -> list[str] | None:
    wrappers = {"env": _unwrap_env, "sudo": _unwrap_sudo, "time": _unwrap_time}
    if executable in wrappers:
        return wrappers[executable](argv)
    if executable != "nohup":
        return None
    index = 2 if len(argv) > 1 and argv[1] == "--" else 1
    if index >= len(argv) or argv[index].startswith("--"):
        raise CommandParseError("nohup wrapper has no supported command")
    return argv[index:]
