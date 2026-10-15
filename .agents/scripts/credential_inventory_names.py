#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Provider defaults, aliases and lookups for the credential registry (GH#34680).

A missing `defaults.<provider>` key means undeclared; an explicit null means
"deliberately no default". Defaults are never inferred.
"""

from __future__ import annotations

from typing import Any

from credential_inventory_fields import InventoryError, check_name, check_ref


def set_default(data: dict[str, Any], provider: str, name: str | None) -> None:
    """Declare the provider default credential, or explicitly declare none."""
    check_ref("provider", provider)
    if name is not None:
        check_name("secret name", name)
        record = data["credentials"].get(name)
        if record is None:
            raise InventoryError(f"{name} is not recorded; record it first with: aidevops secret record {name} --provider {provider}")
        if record.get("provider") != provider:
            raise InventoryError(f"{name} is recorded for provider {record.get('provider')}")
    data["defaults"][provider] = name


def resolve_default(data: dict[str, Any], provider: str) -> tuple[str, str | None]:
    """Return ("set", NAME), ("none", None) or ("undeclared", None)."""
    defaults = data.get("defaults") or {}
    if provider not in defaults:
        return "undeclared", None
    name = defaults[provider]
    return ("none", None) if name is None else ("set", name)


def alias_owner(data: dict[str, Any], alias: str) -> str | None:
    """Return the credential that declares `alias`, if any."""
    for name, record in (data.get("credentials") or {}).items():
        if alias in ((record or {}).get("aliases") or []):
            return name
    return None


def add_alias(data: dict[str, Any], name: str, alias: str) -> None:
    """Declare `alias` as another name for recorded credential `name`."""
    check_name("secret name", name)
    check_name("alias", alias)
    record = data["credentials"].get(name)
    if record is None:
        raise InventoryError(f"{name} is not recorded")
    if alias == name or alias in data["credentials"]:
        raise InventoryError(f"{alias} is itself a recorded credential; aliases must be retired names")
    owner = alias_owner(data, alias)
    if owner and owner != name:
        raise InventoryError(f"{alias} is already an alias of {owner}")
    aliases = list(record.get("aliases") or [])
    if alias not in aliases:
        aliases.append(alias)
    record["aliases"] = sorted(aliases)


def describe(data: dict[str, Any], name: str) -> dict[str, Any]:
    """Return a credential record with its resolved account and default flags."""
    record = data["credentials"].get(name)
    if record is None:
        owner = alias_owner(data, name)
        if owner is None:
            raise InventoryError(f"{name} is not recorded")
        resolved = describe(data, owner)
        resolved["alias_of"] = owner
        resolved["name"] = name
        return resolved
    result = {"name": name, **record}
    ref = record.get("account_ref")
    if ref:
        result["account"] = data["provider_accounts"].get(ref)
    provider = record.get("provider")
    result["is_default"] = (data.get("defaults") or {}).get(provider) == name
    return result
