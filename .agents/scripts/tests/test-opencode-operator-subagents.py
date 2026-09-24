#!/usr/bin/env python3
"""Bounded operator-subagent permissions without changing operator model pins."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from agent_config import get_agent_config  # noqa: E402
from opencode_operator_agents import extend_opencode_operator_subagents  # noqa: E402
from subagent_validation import validate_subagent_refs  # noqa: E402


with tempfile.TemporaryDirectory() as root:
    config = Path(root)
    agent_dir = config / "opencode" / "agent"
    agent_dir.mkdir(parents=True)
    allowlist = config / "aidevops" / "opencode-operator-subagents.txt"
    allowlist.parent.mkdir()
    (agent_dir / "operator-worker.md").write_text(
        "---\nmode: subagent\nmodel: example-provider/pinned-model\n---\nOperator prompt\n",
        encoding="utf-8",
    )
    (agent_dir / "generated-worker.md").write_text(
        "---\nmode: subagent\n---\n<!-- aidevops:generated-subagent -->\n",
        encoding="utf-8",
    )
    (agent_dir / "primary-worker.md").write_text(
        "---\nmode: primary\n---\n",
        encoding="utf-8",
    )
    (agent_dir / "legacy-generated.md").write_text(
        "---\nmode: subagent\n---\n"
        "**MANDATORY**: Your first action MUST be to read ~/.aidevops/agents/tools/legacy-generated.md\n",
        encoding="utf-8",
    )
    allowlist.write_text(
        "# Explicit worker names only\noperator-worker\nmissing-worker\n"
        "generated-worker\nlegacy-generated\nprimary-worker\n../escape\n",
        encoding="utf-8",
    )
    build = get_agent_config("Build+", "build-plus.md", ["research-only"])
    primary = {"Build+": build}
    accepted = extend_opencode_operator_subagents(primary, str(config))
    task = build["permission"]["task"]
    assert accepted == {"operator-worker"}, accepted
    assert task == {"*": "deny", "research-only": "allow", "operator-worker": "allow"}, task
    assert validate_subagent_refs(primary, root, operator_subagents=accepted) == [
        ("Build+", "research-only")
    ]
    assert "model: example-provider/pinned-model" in (
        agent_dir / "operator-worker.md"
    ).read_text(encoding="utf-8")
    allowlist.unlink()
    fresh = {"Build+": get_agent_config("Build+", "build-plus.md", ["research-only"])}
    assert extend_opencode_operator_subagents(fresh, str(config)) == set()
    assert "operator-worker" not in fresh["Build+"]["permission"]["task"]

    # Exercise the production discovery writer, not only the config helper.
    home = config / "home"
    source_dir = home / ".aidevops" / "agents"
    source_dir.mkdir(parents=True)
    (source_dir / "build-plus.md").write_text(
        "---\nmode: subagent\nsubagents:\n  - general\n---\nBuild+\n",
        encoding="utf-8",
    )
    operator_dir = home / ".config" / "opencode" / "agent"
    operator_dir.mkdir(parents=True)
    (operator_dir / "operator-worker.md").write_text(
        "---\nmode: subagent\nmodel: example-provider/pinned-model\n---\nOperator\n",
        encoding="utf-8",
    )
    local_allowlist = home / ".config" / "aidevops" / "opencode-operator-subagents.txt"
    local_allowlist.parent.mkdir()
    local_allowlist.write_text("operator-worker\n", encoding="utf-8")
    script_dir = Path(__file__).resolve().parents[1]
    for profile in ("v1", "v2"):
        env = {**os.environ, "HOME": str(home), "AIDEVOPS_OPENCODE_PROFILE": profile}
        subprocess.run(
            [sys.executable, str(script_dir / "agent-discovery.py"), "opencode", "opencode-json"],
            env=env, check=True, capture_output=True, text=True,
        )
        written = json.loads((home / ".config" / "opencode" / "opencode.json").read_text())
        if profile == "v1":
            permissions = written["agent"]["Build+"]["permission"]["task"]
            assert permissions == {"*": "deny", "general": "allow", "operator-worker": "allow"}
        else:
            permissions = written["agents"]["Build+"]["permissions"]
            task_rules = [rule for rule in permissions if rule["action"] == "task"]
            assert task_rules[-3:] == [
                {"action": "task", "resource": "*", "effect": "deny"},
                {"action": "task", "resource": "general", "effect": "allow"},
                {"action": "task", "resource": "operator-worker", "effect": "allow"},
            ], task_rules
        assert (operator_dir / "operator-worker.md").read_text().splitlines()[2] == (
            "model: example-provider/pinned-model"
        )

print("PASS: explicit operator names extend Build+ in both profiles without changing model pins")
