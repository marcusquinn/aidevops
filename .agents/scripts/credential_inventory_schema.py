#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Whole-document validation for the credential registry (GH#34680)."""

from __future__ import annotations

from typing import Any

from credential_inventory_fields import NAME_RE, OWNERSHIP_TYPES, REF_RE, SCHEMA_VERSION


def _validate_accounts(data: dict[str, Any], errors: list[str]) -> None:
    accounts = data.get("provider_accounts")
    if not isinstance(accounts, dict):
        errors.append("provider_accounts must be an object")
        return
    for ref, account in accounts.items():
        if not REF_RE.match(ref) or not isinstance(account, dict):
            errors.append(f"invalid provider account: {ref}")
            continue
        if not REF_RE.match(str(account.get("provider", ""))):
            errors.append(f"account {ref} has an invalid provider")
        env = account.get("account_id_env")
        if env is not None and not NAME_RE.match(str(env)):
            errors.append(f"account {ref} account_id_env must be a variable name")
        ownership = account.get("ownership") or {}
        if ownership.get("type") not in (None, *OWNERSHIP_TYPES):
            errors.append(f"account {ref} has an unknown ownership type")


def _validate_credentials(data: dict[str, Any], errors: list[str]) -> None:
    credentials = data.get("credentials")
    accounts = data.get("provider_accounts") or {}
    if not isinstance(credentials, dict):
        errors.append("credentials must be an object")
        return
    for name, record in credentials.items():
        if not NAME_RE.match(name) or not isinstance(record, dict):
            errors.append(f"invalid credential record: {name}")
            continue
        ref = record.get("account_ref")
        if ref is not None and ref not in accounts:
            errors.append(f"credential {name} references unknown account {ref}")
        if not all(NAME_RE.match(str(alias)) for alias in record.get("aliases") or []):
            errors.append(f"credential {name} has an invalid alias")


def _validate_defaults(data: dict[str, Any], errors: list[str]) -> None:
    defaults = data.get("defaults")
    credentials = data.get("credentials") or {}
    if not isinstance(defaults, dict):
        errors.append("defaults must be an object")
        return
    for provider, name in defaults.items():
        if not REF_RE.match(provider):
            errors.append(f"invalid default provider: {provider}")
        elif name is not None and name not in credentials:
            errors.append(f"default for {provider} names an unrecorded credential")


def _validate_aliases_unique(data: dict[str, Any], errors: list[str]) -> None:
    credentials = data.get("credentials") or {}
    owners: dict[str, str] = {}
    pairs = [(alias, name) for name, record in credentials.items() for alias in (record or {}).get("aliases") or []]
    for alias, name in pairs:
        if alias in credentials:
            errors.append(f"alias {alias} collides with a recorded credential")
        elif owners.setdefault(alias, name) != name:
            errors.append(f"alias {alias} is declared by more than one credential")


def validate(data: Any) -> list[str]:
    """Return a list of schema errors (empty when valid)."""
    if not isinstance(data, dict):
        return ["registry must be a JSON object"]
    errors: list[str] = []
    if data.get("version") != SCHEMA_VERSION:
        errors.append(f"unsupported registry version (expected {SCHEMA_VERSION})")
    _validate_accounts(data, errors)
    _validate_credentials(data, errors)
    _validate_defaults(data, errors)
    _validate_aliases_unique(data, errors)
    return errors
