#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Field rules for the non-secret credential registry (GH#34680).

Constants, the shared error type, and validators for individual fields.
Free-text fields that look like pasted secrets or raw account IDs are
refused: the registry stores names and descriptions only.
"""

from __future__ import annotations

import datetime as _dt
import os
import re
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]{0,127}$")
REF_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
KIND_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
DOMAIN_RE = re.compile(r"^(?=.{1,253}$)(?:\*\.)?(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
RESOURCE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}:[A-Za-z0-9._/-]{1,200}$")
HEX_ID_RE = re.compile(r"^[0-9a-fA-F]{32}$")
OWNERSHIP_TYPES = ("client", "former-client", "business", "personal", "partner", "community", "unknown")

# Conventional unlabelled variable each provider's tools read. Resolving it
# to a stored credential requires an explicit `defaults.<provider>` entry.
DEFAULT_ENV = {
    "anthropic": "ANTHROPIC_API_KEY",
    "cloudflare": "CLOUDFLARE_API_TOKEN",
    "github": "GITHUB_TOKEN",
    "hetzner": "HCLOUD_TOKEN",
    "openai": "OPENAI_API_KEY",
    "vercel": "VERCEL_TOKEN",
}


class InventoryError(RuntimeError):
    """The registry refused unsafe, invalid or inconsistent input."""


def inventory_path() -> Path:
    """Resolve the registry path, honouring AIDEVOPS_CREDENTIAL_INVENTORY."""
    override = os.environ.get("AIDEVOPS_CREDENTIAL_INVENTORY", "").strip()
    if override:
        return Path(override).expanduser()
    return Path.home() / ".config" / "aidevops" / "credential-inventory.json"


def empty_inventory() -> dict[str, Any]:
    """Return a new empty registry document."""
    return {"version": SCHEMA_VERSION, "provider_accounts": {}, "credentials": {}, "defaults": {}}


def now_iso() -> str:
    """UTC timestamp with second precision."""
    return _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def looks_like_secret(text: str) -> bool:
    """Heuristic refusal for free-text fields that look like pasted secrets."""
    if not text or any(ch.isspace() for ch in text):
        return False
    if HEX_ID_RE.match(text):
        return True
    if len(text) < 24:
        return False
    has_alpha = any(ch.isalpha() for ch in text)
    has_digit = any(ch.isdigit() for ch in text)
    return has_alpha and has_digit


def check_free_text(label: str, value: str | None, limit: int = 300) -> str | None:
    """Validate a human-readable field; refuse secret-looking values."""
    if value is None:
        return None
    value = value.strip()
    if len(value) > limit:
        raise InventoryError(f"{label} is longer than {limit} characters")
    if looks_like_secret(value):
        raise InventoryError(f"{label} looks like a secret value or raw account ID; store names and descriptions only")
    return value


def check_name(label: str, value: str) -> str:
    """Validate an environment-variable-style secret name."""
    if not NAME_RE.match(value or ""):
        raise InventoryError(f"{label} must be an upper-case environment variable name")
    return value


def check_ref(label: str, value: str) -> str:
    """Validate a lower-case reference such as a provider or account ref."""
    if not REF_RE.match(value or ""):
        raise InventoryError(f"{label} must be lower-case letters, digits and hyphens")
    return value


def check_expiry(value: str | None) -> str | None:
    """Accept an ISO date, `never`, or None (unknown)."""
    if value is None or value == "":
        return None
    if value == "never":
        return value
    if not DATE_RE.match(value):
        raise InventoryError("expiry must be YYYY-MM-DD or 'never'")
    try:
        _dt.date.fromisoformat(value)
    except ValueError as exc:
        raise InventoryError("expiry is not a valid calendar date") from exc
    return value


def split_csv(value: str | None) -> list[str]:
    """Split a comma-separated CLI value into trimmed, de-duplicated items."""
    if not value:
        return []
    seen: list[str] = []
    for item in value.split(","):
        item = item.strip()
        if item and item not in seen:
            seen.append(item)
    return seen


def check_zones(zones: list[str]) -> list[str]:
    """Validate zone/domain names."""
    cleaned = [zone.lower().rstrip(".") for zone in zones]
    for zone in cleaned:
        if zone != "all" and not DOMAIN_RE.match(zone):
            raise InventoryError(f"invalid zone name: {zone}")
    return cleaned


def check_resources(resources: list[str]) -> list[str]:
    """Validate `type:name` resource references."""
    for resource in resources:
        if not RESOURCE_RE.match(resource):
            raise InventoryError(f"resource must be type:name, got: {resource}")
    return resources


def merge_ownership(ownership: dict[str, Any], fields: dict[str, Any]) -> None:
    """Apply validated ownership fields; inferred ownership stays unconfirmed."""
    kind = fields.get("ownership_type")
    if kind:
        if kind not in OWNERSHIP_TYPES:
            raise InventoryError("ownership type must be one of: " + ", ".join(OWNERSHIP_TYPES))
        ownership["type"] = kind
    for key in ("owner", "evidence"):
        value = check_free_text(key, fields.get(key))
        if value:
            ownership[key] = value
    if fields.get("confirmed") is not None:
        ownership["confirmed"] = bool(fields["confirmed"])
    elif ownership and "confirmed" not in ownership:
        ownership["confirmed"] = False
