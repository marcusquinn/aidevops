"""Refresh only canonical pointer digests during an owner-run Buzz install."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import json
import re

from _team_interface_buzz_runtime_install import backup_existing
from _team_interface_buzz_runtime_io import (
    RuntimeError,
    atomic_write,
    canonical_payload,
    require_safe_directory_chain,
)
from _team_interface_buzz_runtime_prepare import load_module


DIGEST_LINE = re.compile(r"^Expected source digest: sha256:([a-f0-9]{64})$", re.MULTILINE)


def refresh_source_digests(app_data_dir, agents_dir):
    """Back up and atomically update eligible records without exposing store data."""
    path = app_data_dir / "agents" / "managed-agents.json"
    require_safe_directory_chain(path.parent)
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise RuntimeError("Buzz managed agents store must be a regular non-symlink file")
    if not path.exists():
        return
    try:
        store = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise RuntimeError("Buzz managed agents store is unavailable or invalid") from error
    if not isinstance(store, list) or any(not isinstance(record, dict) for record in store):
        raise RuntimeError("Buzz managed agents store must be an array of records")

    scripts = agents_dir / "scripts"
    roster_module = load_module(
        "buzz_refresh_roster", scripts / "team-interface-agent-roster.py",
        "anchored roster generator is unavailable",
    )
    snapshot = load_module(
        "buzz_refresh_snapshot", scripts / "team-interface-buzz-team-snapshot.py",
        "anchored snapshot generator is unavailable",
    )
    host = snapshot.resolve_host_slug()
    expected = {}
    for member in roster_module.build_roster(agents_dir)["agents"]:
        name = snapshot.buzz_display_name(member, host)
        if name in expected:
            raise RuntimeError("anchored roster contains duplicate Buzz display names")
        expected[name] = snapshot.member_system_prompt(member)

    summaries = []
    changed = False
    for record in store:
        name = record.get("name")
        prompt = record.get("system_prompt")
        if not isinstance(name, str) or name not in expected:
            continue
        if not isinstance(prompt, str) or not prompt.startswith("Aidevops canonical source:"):
            continue
        matches = list(DIGEST_LINE.finditer(prompt))
        canonical = expected[name]
        new_digest = DIGEST_LINE.search(canonical)
        if len(matches) != 1 or new_digest is None:
            summaries.append(f"{name}: skipped (non-digest prompt differs)")
            continue
        old_digest = matches[0]
        updated = prompt[:old_digest.start()] + new_digest.group() + prompt[old_digest.end():]
        if updated != canonical:
            summaries.append(f"{name}: skipped (non-digest prompt differs)")
        elif updated != prompt:
            record["system_prompt"] = updated
            changed = True
            summaries.append(f"{name}: {old_digest.group(1)[:12]} -> {new_digest.group(1)[:12]}")

    if changed:
        backup = backup_existing(path, "managed-agents")
        atomic_write(path, canonical_payload(store))
        print(f"Buzz managed agents backup: {backup}")
    for summary in summaries:
        print(summary)
