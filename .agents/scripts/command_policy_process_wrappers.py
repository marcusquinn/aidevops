#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Process-launch wrapper expansion for the shared command policy."""

from __future__ import annotations

import re

from command_policy_dispatch import CommandParseError
from command_policy_wrapper_options import _consume_option


def _unwrap_setsid(argv: list[str]) -> list[str]:
    index = 1
    flags = {"-c", "--ctty", "-f", "--fork", "-w", "--wait"}
    while index < len(argv) and argv[index].startswith("-"):
        index = _consume_option(argv, index, set(), flags)
    if index >= len(argv):
        raise CommandParseError("setsid wrapper has no command")
    return argv[index:]


def _unwrap_timeout(argv: list[str]) -> list[str]:
    index = 1
    values = {"-k", "--kill-after", "-s", "--signal"}
    flags = {"--foreground", "--preserve-status", "-v", "--verbose"}
    while index < len(argv) and argv[index].startswith("-"):
        index = _consume_option(argv, index, values, flags)
    command_index = index + 1
    if command_index >= len(argv):
        raise CommandParseError("timeout wrapper has no duration and command")
    return argv[command_index:]


def _unwrap_nice(argv: list[str]) -> list[str]:
    index = 1
    values = {"-n", "--adjustment"}
    while index < len(argv) and argv[index].startswith("-"):
        if re.fullmatch(r"-[0-9]+", argv[index]):
            index += 1
            continue
        index = _consume_option(argv, index, values, set())
    if index >= len(argv):
        raise CommandParseError("nice wrapper has no command")
    return argv[index:]


def _unwrap_stdbuf(argv: list[str]) -> list[str]:
    index = 1
    values = {"-e", "--error", "-i", "--input", "-o", "--output"}
    while index < len(argv) and argv[index].startswith("-"):
        index = _consume_option(argv, index, values, set())
    if index >= len(argv):
        raise CommandParseError("stdbuf wrapper has no command")
    return argv[index:]
