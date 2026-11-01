#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Verification target selection and registry forgetting (GH#36391).

Non-token kinds (account IDs, R2 keys, endpoints) are never verification
targets; naming one explicitly reports it as not verifiable, not a failure.
`forget` drops registry records only; secret values are never touched.
"""

from __future__ import annotations

import sys
from typing import Any

import credential_inventory_fields as rules
import credential_inventory_names as names
import credential_inventory_store as store
import credential_inventory_view as view
from credential_inventory_drift import is_verifiable

EXIT_INVALID = 2


def _report_unrecorded(missing: list[str], provider: str) -> None:
    for name in sorted(set(missing)):
        print(f"ERROR: {name} is not recorded for {provider}; record it first with: "
              f"aidevops secret record {name} --provider {provider} --account REF", file=sys.stderr)


def verify_targets(data: dict[str, Any], provider: str, requested: list[str]) -> int:
    """Print verifiable recorded credentials for provider (aliases resolved)."""
    credentials = data["credentials"]
    wanted = [names.alias_owner(data, name) or name for name in requested] or sorted(credentials)
    recorded = [name for name in wanted if (credentials.get(name) or {}).get("provider") == provider]
    if requested and len(recorded) != len(wanted):
        _report_unrecorded([name for name in wanted if name not in recorded], provider)
        return EXIT_INVALID
    targets = list(dict.fromkeys(name for name in recorded if is_verifiable(credentials[name])))
    skipped = list(dict.fromkeys(name for name in recorded if name not in targets))
    for name in skipped if requested else []:
        print(f"{name}: not-verifiable (kind={credentials[name].get('kind')})", file=sys.stderr)
    if targets:
        print("\n".join(targets))
    return 0 if targets or (requested and skipped) else 1


def forget(requested: list[str], force: bool) -> int:
    """Drop registry records whose secrets are gone; --force skips the stored check."""
    if not force:
        stored = view.stored_secret_names()
        if stored is None:
            raise rules.InventoryError("stored-secret listing unavailable; rerun with --force to forget anyway")
        still = [name for name in requested if name in stored]
        if still:
            raise rules.InventoryError(f"still stored: {', '.join(still)}; use: aidevops secret rm NAME (or forget --force)")
    with store.locked() as data:
        removed = {name for name in requested if store.forget_credential(data, name)}
    for name in requested:
        print(f"Removed {name} from the credential registry" if name in removed else f"{name} is not recorded; nothing to forget")
    return 0
