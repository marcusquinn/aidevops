#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate and normalize the fixed private OpenCode workload profile."""

from __future__ import annotations

import json
import os
import shutil
import stat
import sys
from pathlib import Path
from typing import Any


EXPECTED_ROOT_ENTRIES = {
    ".opencode",
    "fetch-audit.jsonl",
    "instructions.md",
    "jobs.jsonl",
}
EXPECTED_OPENCODE_ENTRIES = {"opencode.json", "tool"}
GENERATED_OPENCODE_FILES = {".gitignore", "package-lock.json", "package.json"}
GENERATED_OPENCODE_DIRECTORIES = {"node_modules"}
EXPECTED_TOOLS = {"provisional_fetch.ts", "provisional_submit.ts"}
EXPECTED_CONFIG_KEYS = {
    "$schema",
    "agent",
    "autoupdate",
    "default_agent",
    "enabled_providers",
    "formatter",
    "instructions",
    "lsp",
    "model",
    "share",
    "snapshot",
}
EXPECTED_AGENT_KEYS = {"description", "mode", "model", "permission", "steps"}
DENIED_CAPABILITIES = {
    "bash",
    "edit",
    "external_directory",
    "glob",
    "grep",
    "list",
    "lsp",
    "question",
    "read",
    "skill",
    "task",
    "todowrite",
    "webfetch",
    "websearch",
}


def private_entry(path: Path, *, directory: bool, uid: int) -> os.stat_result:
    entry = path.lstat()
    expected_type = stat.S_ISDIR if directory else stat.S_ISREG
    expected_mode = 0o700 if directory else 0o600
    if not expected_type(entry.st_mode) or stat.S_ISLNK(entry.st_mode):
        raise ValueError(f"Unexpected private profile entry type: {path.name}")
    if entry.st_uid != uid or stat.S_IMODE(entry.st_mode) != expected_mode:
        raise ValueError(f"Unexpected private profile permissions: {path.name}")
    if not directory and entry.st_nlink != 1:
        raise ValueError(f"Unexpected private profile link count: {path.name}")
    return entry


def validate_layout(root: Path, uid: int) -> tuple[Path, set[str]]:
    opencode_root = root / ".opencode"
    tool_root = opencode_root / "tool"
    for path in (root, opencode_root, tool_root):
        private_entry(path, directory=True, uid=uid)

    root_entries = {path.name for path in root.iterdir()}
    result_entries = root_entries & {"results.jsonl", "results.pending.jsonl"}
    if len(result_entries) != 1 or root_entries != EXPECTED_ROOT_ENTRIES | result_entries:
        raise ValueError("Unexpected private workload root layout")

    for filename in (
        "fetch-audit.jsonl",
        "instructions.md",
        "jobs.jsonl",
        next(iter(result_entries)),
    ):
        private_entry(root / filename, directory=False, uid=uid)
    for filename in ("opencode.json",):
        private_entry(opencode_root / filename, directory=False, uid=uid)
    for filename in EXPECTED_TOOLS:
        private_entry(tool_root / filename, directory=False, uid=uid)
    if {path.name for path in tool_root.iterdir()} != EXPECTED_TOOLS:
        raise ValueError("Unexpected private workload tool layout")
    return opencode_root, {path.name for path in opencode_root.iterdir()}


def remove_generated_file(path: Path, uid: int) -> None:
    entry = path.lstat()
    if (
        not stat.S_ISREG(entry.st_mode)
        or stat.S_ISLNK(entry.st_mode)
        or entry.st_uid != uid
        or entry.st_nlink != 1
    ):
        raise ValueError("Unsafe generated OpenCode file")
    path.unlink()


def remove_generated_directory(path: Path, uid: int) -> None:
    entry = path.lstat()
    if (
        not stat.S_ISDIR(entry.st_mode)
        or stat.S_ISLNK(entry.st_mode)
        or entry.st_uid != uid
    ):
        raise ValueError("Unsafe generated OpenCode directory")
    shutil.rmtree(path)


def remove_generated_runtime_entries(
    opencode_root: Path, entries: set[str], uid: int
) -> None:
    allowed_entries = (
        EXPECTED_OPENCODE_ENTRIES
        | GENERATED_OPENCODE_FILES
        | GENERATED_OPENCODE_DIRECTORIES
    )
    if not EXPECTED_OPENCODE_ENTRIES <= entries or not entries <= allowed_entries:
        raise ValueError("Unexpected local OpenCode profile entry")

    for name in entries & GENERATED_OPENCODE_FILES:
        remove_generated_file(opencode_root / name, uid)
    for name in entries & GENERATED_OPENCODE_DIRECTORIES:
        remove_generated_directory(opencode_root / name, uid)
    if {path.name for path in opencode_root.iterdir()} != EXPECTED_OPENCODE_ENTRIES:
        raise ValueError("OpenCode runtime metadata cleanup was incomplete")


def exact_mapping(value: Any, keys: set[str], message: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise ValueError(message)
    return value


def validate_config_values(
    config: dict[str, Any], model: str, agent: str, provider: str
) -> None:
    expected_values = {
        "$schema": "https://opencode.ai/config.json",
        "autoupdate": False,
        "default_agent": agent,
        "enabled_providers": [provider],
        "formatter": False,
        "instructions": ["instructions.md"],
        "lsp": False,
        "model": model,
        "share": "disabled",
        "snapshot": False,
    }
    for key, expected_value in expected_values.items():
        if config[key] != expected_value:
            raise ValueError("Restricted OpenCode runtime does not match the request")


def validate_steps(steps: Any) -> None:
    if (
        not isinstance(steps, int)
        or isinstance(steps, bool)
        or not 1 <= steps <= 10_000
    ):
        raise ValueError("Invalid restricted OpenCode agent step count")


def validate_permissions(value: Any) -> None:
    expected_permissions = {
        "*",
        "provisional_fetch",
        "provisional_submit",
    } | DENIED_CAPABILITIES
    permissions = exact_mapping(
        value,
        expected_permissions,
        "Unexpected restricted OpenCode permissions",
    )
    if permissions["*"] != "deny":
        raise ValueError("Unsafe restricted OpenCode permissions")
    if permissions["provisional_fetch"] != "allow":
        raise ValueError("Unsafe restricted OpenCode permissions")
    if permissions["provisional_submit"] != "allow":
        raise ValueError("Unsafe restricted OpenCode permissions")
    for name in DENIED_CAPABILITIES:
        if permissions[name] != "deny":
            raise ValueError("Unsafe restricted OpenCode permissions")


def validate_agent_config(value: Any, model: str) -> None:
    agent_config = exact_mapping(
        value,
        EXPECTED_AGENT_KEYS,
        "Unexpected restricted OpenCode agent configuration",
    )
    description = agent_config["description"]
    if not isinstance(description, str) or not description:
        raise ValueError("Invalid restricted OpenCode agent description")
    if agent_config["mode"] != "primary" or agent_config["model"] != model:
        raise ValueError("Invalid restricted OpenCode agent runtime")
    validate_steps(agent_config["steps"])
    validate_permissions(agent_config["permission"])


def validate_config(config: Any, model: str, agent: str, provider: str) -> None:
    root_config = exact_mapping(
        config,
        EXPECTED_CONFIG_KEYS,
        "Unexpected restricted OpenCode configuration",
    )
    validate_config_values(root_config, model, agent, provider)

    agents = exact_mapping(
        root_config["agent"],
        {agent},
        "Unexpected restricted OpenCode agent",
    )
    validate_agent_config(agents[agent], model)


def main() -> int:
    if len(sys.argv) != 5:
        return 2
    root = Path(sys.argv[1])
    model, agent, provider = sys.argv[2:]
    uid = os.getuid()
    opencode_root, entries = validate_layout(root, uid)
    remove_generated_runtime_entries(opencode_root, entries, uid)
    config: Any = json.loads((opencode_root / "opencode.json").read_text(encoding="utf-8"))
    validate_config(config, model, agent, provider)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError):
        raise SystemExit(1) from None
