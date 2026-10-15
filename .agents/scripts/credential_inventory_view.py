#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only views of the credential registry (GH#34680).

Builds the grouped `describe` summary and its text rendering. Stored-secret
names come from `secret-helper.sh inventory`, which lists names only.
"""

from __future__ import annotations

import json
import shutil
import subprocess  # nosec B404 -- fixed argv to the repository-owned secret-helper.sh, never a shell
from pathlib import Path
from typing import Any

import credential_inventory_names as names

SCRIPT_DIR = Path(__file__).resolve().parent


def stored_secret_names() -> list[str] | None:
    """Names-only listing from secret-helper.sh inventory; None if unavailable."""
    helper = SCRIPT_DIR / "secret-helper.sh"
    bash = shutil.which("bash")
    if not bash:
        return None
    try:
        # Absolute bash, repository-owned helper, fixed argv, no shell.
        result = subprocess.run(  # nosec B603
            [bash, str(helper), "inventory"],
            capture_output=True, text=True, timeout=30, check=False,
        )
        if result.returncode != 0:
            return None
        return sorted(item["name"] for item in json.loads(result.stdout).get("secrets", []))
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def summary(data: dict[str, Any], stored: list[str] | None) -> dict[str, Any]:
    """Whole-registry view, grouped by provider, with undescribed secrets."""
    providers: dict[str, dict[str, Any]] = {}
    for name in sorted(data["credentials"]):
        record = names.describe(data, name)
        group = providers.setdefault(record["provider"], {"credentials": []})
        group["credentials"].append(record)
    for provider, group in providers.items():
        status, default = names.resolve_default(data, provider)
        group["default"] = {"status": status, "name": default}
    known = set(data["credentials"])
    for record in data["credentials"].values():
        known.update(record.get("aliases") or [])
    result: dict[str, Any] = {"providers": providers, "provider_accounts": data["provider_accounts"]}
    if stored is None:
        result["undescribed"] = None
        result["stored_listing"] = "unavailable"
    else:
        result["undescribed"] = [name for name in stored if name not in known]
    return result


def format_account(account: dict[str, Any] | None) -> str:
    """Short human label for an account record."""
    if not account:
        return "account: unrecorded"
    ownership = account.get("ownership") or {}
    tags = [ownership.get("type") or "ownership unknown"]
    if ownership:
        tags.append("confirmed" if ownership.get("confirmed") else "unconfirmed")
    return f"account: {account.get('name')} ({', '.join(tags)})"


def format_record(record: dict[str, Any]) -> str:
    """One human-readable line for a credential."""
    reach = record.get("reach") or {}
    parts = [
        record["name"] + ("  [default]" if record.get("is_default") else ""),
        format_account(record.get("account")),
        "reach: " + (", ".join(reach.get("zones", []) + reach.get("resources", [])) or "unrecorded"),
        "expires: " + (record.get("expires_at") or "unrecorded"),
    ]
    if record.get("purpose"):
        parts.append("purpose: " + record["purpose"])
    if record.get("aliases"):
        parts.append("aliases: " + ", ".join(record["aliases"]))
    return "  " + "\n      ".join(parts)


def print_summary(view: dict[str, Any]) -> None:
    """Text rendering of the whole registry."""
    labels = {"set": "{name}", "none": "explicitly none", "undeclared": "undeclared"}
    if not view["providers"]:
        print("No credentials described yet. Record one with: aidevops secret record NAME --provider PROVIDER --account REF")
    for provider, group in sorted(view["providers"].items()):
        default = group["default"]
        print(f"{provider}  (default: {labels[default['status']].format(name=default['name'])})")
        for record in group["credentials"]:
            print(format_record(record))
    undescribed = view.get("undescribed")
    if undescribed:
        print(f"\nUndescribed stored secrets ({len(undescribed)}): " + ", ".join(undescribed))
        print("Describe them with: aidevops secret record NAME --provider PROVIDER --account REF")
    elif undescribed is None:
        print("\nStored-secret listing unavailable; undescribed secrets not checked.")
