#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Lint headless prompt bash fences without executing their commands."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Iterator

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
# Proven headless OpenCode entry points: pulse-wrapper-cycle.sh launches these.
# Do not expand this list to interactive documentation without execution evidence.
HEADLESS_PROMPTS = (
    ".agents/workflows/pulse.md",
    ".agents/workflows/pulse-sweep.md",
)
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")


def bash_commands(text: str) -> Iterator[tuple[int, str]]:
    """Yield logical commands with the first physical line's 1-based number."""
    marker = ""
    bash = False
    parts: list[str] = []
    start = 0
    for number, line in enumerate(text.splitlines(), 1):
        fence = FENCE.match(line)
        if fence:
            token, info = fence.groups()
            if not marker:
                marker = token
                bash = info.strip() == "bash"
            elif token[0] == marker[0] and len(token) >= len(marker) and not info.strip():
                if parts:
                    raise ValueError(f"line {start}: unfinished bash continuation")
                marker = ""
                bash = False
            continue
        command = line.strip()
        if not bash or not command or command.startswith("#"):
            continue
        if not parts:
            start = number
        continued = command.endswith("\\")
        parts.append(command[:-1] if continued else command)
        if not continued:
            yield start, " ".join(parts)
            parts = []
    if bash:
        raise ValueError("unterminated bash fence")


def lint_file(path: Path, policy: Path) -> bool:
    """Use the shared CLI so parser and policy decisions cannot drift."""
    forbidden = 0
    count = 0
    for line, command in bash_commands(path.read_text(encoding="utf-8")):
        # The prompt command is data for check-command, never executable argv.
        result = subprocess.run(  # nosec B603 -- fixed interpreter/local checker; command is data, no shell.
            [
                sys.executable, str(SCRIPT_DIR / "command-policy-helper.py"),
                "check-command", "--policy", str(policy), "--cwd", str(REPO_ROOT),
                "--command", command,
            ],
            capture_output=True,
            text=True,
            check=False,
            shell=False,
            timeout=30,
        )
        decision = json.loads(result.stdout)
        if (
            result.returncode not in (0, 20)
            or not isinstance(decision, dict)
            or decision.get("decision") not in ("allow", "forbid")
            or not isinstance(decision.get("rule_id"), str)
        ):
            raise ValueError(
                f"policy checker failed at line {line} (exit {result.returncode})"
            )
        count += 1
        if decision["decision"] == "forbid":
            forbidden += 1
            print(f"{path}:{line} {decision['rule_id']} {command}")
    print(f"{path}: {forbidden} forbidden of {count} bash commands")
    return forbidden == 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "files", nargs="*", type=Path,
        help="Markdown files (default: headless pulse allowlist)",
    )
    parser.add_argument(
        "--policy", type=Path,
        default=SCRIPT_DIR.parent / "configs/command-policy.json",
    )
    args = parser.parse_args()
    files = args.files or [REPO_ROOT / name for name in HEADLESS_PROMPTS]
    passed = True
    for path in files:
        try:
            if not lint_file(path, args.policy):
                passed = False
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            print(f"{path}: prompt command policy lint error: {exc}", file=sys.stderr)
            passed = False
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
