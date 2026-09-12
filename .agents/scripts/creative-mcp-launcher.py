#!/usr/bin/env python3
"""Fail-closed launcher for optional creative application MCP adapters."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


PROFILES = {
    "freecad": {
        "env": "FREECAD_MCP_COMMAND_JSON",
        "agent": "freecad",
        "extra_flag": None,
    },
    "davinci-resolve": {
        "env": "DAVINCI_RESOLVE_MCP_COMMAND_JSON",
        "agent": "davinci-resolve",
        "extra_flag": None,
    },
    "ableton-live": {
        "env": "ABLETON_LIVE_MCP_COMMAND_JSON",
        "agent": "ableton-live",
        "extra_flag": "AIDEVOPS_ABLETON_TELEMETRY_DISABLED",
    },
}

HEADLESS_FLAGS = (
    "FULL_LOOP_HEADLESS",
    "AIDEVOPS_HEADLESS",
    "OPENCODE_HEADLESS",
    "CLAUDE_HEADLESS",
    "HEADLESS",
    "CI",
)


def enabled(name: str) -> bool:
    return os.environ.get(name, "").lower() in {"1", "true", "yes"}


def validate(profile_name: str) -> list[str]:
    profile = PROFILES[profile_name]
    if any(enabled(name) for name in HEADLESS_FLAGS) or os.environ.get("AIDEVOPS_WORKER_ID"):
        raise ValueError("creative desktop MCP execution is disabled in headless worker sessions")
    if not enabled("AIDEVOPS_CREATIVE_EXTERNAL_EXECUTION_APPROVED"):
        raise ValueError("explicit operator approval is required before creative MCP execution")
    if not enabled("AIDEVOPS_CREATIVE_ISOLATION_CONFIRMED"):
        raise ValueError("an isolated creative application environment must be confirmed")
    extra_flag = profile["extra_flag"]
    if extra_flag and not enabled(extra_flag):
        raise ValueError("Ableton adapter telemetry must be disabled and attested before connection")

    raw = os.environ.get(profile["env"], "")
    if not raw:
        raise ValueError(f"configure {profile['env']} with the reviewed pinned adapter command")
    try:
        command = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ValueError(f"{profile['env']} must be a JSON string array") from error
    if not isinstance(command, list) or not command or not all(isinstance(item, str) and item for item in command):
        raise ValueError(f"{profile['env']} must be a non-empty JSON string array")

    executable = Path(command[0])
    if not executable.is_absolute():
        raise ValueError("creative MCP executable must be an absolute path from a reviewed installation")
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError("configured creative MCP executable is missing or not executable")
    return command


def execution_environment() -> dict[str, str]:
    """Pass only non-secret runtime basics to the operator-reviewed adapter."""
    allowed = ("HOME", "PATH", "LANG", "LC_ALL", "TMPDIR", "TEMP", "TMP")
    return {name: os.environ[name] for name in allowed if name in os.environ}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", choices=sorted(PROFILES))
    parser.add_argument("action", choices=("check", "run"), nargs="?", default="run")
    args = parser.parse_args()
    try:
        command = validate(args.profile)
    except ValueError as error:
        print(f"Creative MCP ({args.profile}): {error}", file=sys.stderr)
        return 2
    if args.action == "check":
        print(f"Creative MCP ({args.profile}): prerequisites accepted; external command not executed")
        return 0
    return subprocess.run(command, check=False, env=execution_environment()).returncode


if __name__ == "__main__":
    raise SystemExit(main())
