#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Non-secret local credential registry (GH#34680).

Records which provider account each stored secret opens, what it reaches,
who it is for, when it expires, and the explicit default per provider. The
registry holds secret *names* and environment-variable names only: never
secret values and never raw provider account IDs.
"""

from __future__ import annotations

import contextlib
import datetime as _dt
import fcntl
import json
import os
import re
import stat
import tempfile
from pathlib import Path
from typing import Any, Iterator

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


# --------------------------------------------------------------------------
# Validation of a whole document
# --------------------------------------------------------------------------


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
        for alias in record.get("aliases") or []:
            if not NAME_RE.match(str(alias)):
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
    for name, record in credentials.items():
        for alias in (record or {}).get("aliases") or []:
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


# --------------------------------------------------------------------------
# Load / save
# --------------------------------------------------------------------------


def _check_private_file(path: Path) -> None:
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise InventoryError("credential registry must be a regular non-symlink file")
    if info.st_mode & 0o077:
        raise InventoryError("credential registry must be owner-only (chmod 600)")


def load(path: Path | None = None) -> dict[str, Any]:
    """Load and validate the registry; a missing file is an empty registry."""
    path = path or inventory_path()
    if not path.exists() and not path.is_symlink():
        return empty_inventory()
    _check_private_file(path)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise InventoryError("credential registry is not readable JSON") from exc
    for key in ("provider_accounts", "credentials", "defaults"):
        data.setdefault(key, {})
    errors = validate(data)
    if errors:
        raise InventoryError("credential registry is invalid: " + "; ".join(errors))
    return data


def save(data: dict[str, Any], path: Path | None = None) -> None:
    """Validate then atomically write the registry with owner-only perms."""
    path = path or inventory_path()
    errors = validate(data)
    if errors:
        raise InventoryError("refusing to write invalid registry: " + "; ".join(errors))
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    payload = json.dumps(data, indent=2, sort_keys=True) + "\n"
    fd, tmp_name = tempfile.mkstemp(prefix=".credential-inventory.", dir=str(path.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp_name)
        raise


@contextlib.contextmanager
def locked(path: Path | None = None, write: bool = True) -> Iterator[dict[str, Any]]:
    """Hold an exclusive lock, yield the registry, and save it on success."""
    path = path or inventory_path()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_path = path.with_name(path.name + ".lock")
    with open(lock_path, "a", encoding="utf-8") as lock_handle:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        data = load(path)
        yield data
        if write:
            save(data, path)


# --------------------------------------------------------------------------
# Operations
# --------------------------------------------------------------------------


def add_account(data: dict[str, Any], ref: str, provider: str, name: str, **fields: Any) -> dict[str, Any]:
    """Create or update a provider account (non-secret identity only)."""
    check_ref("account ref", ref)
    check_ref("provider", provider)
    existing = data["provider_accounts"].get(ref) or {}
    if existing and existing.get("provider") != provider:
        raise InventoryError(f"account {ref} already belongs to provider {existing.get('provider')}")
    account = dict(existing)
    account["provider"] = provider
    account["name"] = check_free_text("account name", name, 120) or ref
    env = fields.get("account_id_env")
    if env:
        account["account_id_env"] = check_name("account ID variable", env)
    ownership = dict(account.get("ownership") or {})
    _merge_ownership(ownership, fields)
    if ownership:
        account["ownership"] = ownership
    data["provider_accounts"][ref] = account
    return account


def _merge_ownership(ownership: dict[str, Any], fields: dict[str, Any]) -> None:
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


def record_credential(data: dict[str, Any], name: str, provider: str, **fields: Any) -> dict[str, Any]:
    """Create or update metadata for a stored secret; only given fields change."""
    check_name("secret name", name)
    check_ref("provider", provider)
    owner = alias_owner(data, name)
    if owner:
        raise InventoryError(f"{name} is already declared as an alias of {owner}")
    record = dict(data["credentials"].get(name) or {})
    if record and record.get("provider") != provider:
        raise InventoryError(f"{name} is already recorded for provider {record.get('provider')}")
    record["provider"] = provider
    _apply_account(data, record, provider, fields.get("account_ref"))
    _apply_text_fields(record, fields)
    _apply_reach(record, fields)
    record.setdefault("aliases", [])
    record.setdefault("recorded_at", now_iso())
    record["updated_at"] = now_iso()
    data["credentials"][name] = record
    return record


def _apply_account(data: dict[str, Any], record: dict[str, Any], provider: str, ref: str | None) -> None:
    if not ref:
        return
    check_ref("account ref", ref)
    account = data["provider_accounts"].get(ref)
    if account is None:
        raise InventoryError(f"unknown account {ref}; add it first with: aidevops secret account add {ref} --provider {provider} --name NAME")
    if account.get("provider") != provider:
        raise InventoryError(f"account {ref} belongs to provider {account.get('provider')}")
    record["account_ref"] = ref


def _apply_text_fields(record: dict[str, Any], fields: dict[str, Any]) -> None:
    kind = fields.get("kind")
    if kind:
        if not KIND_RE.match(kind):
            raise InventoryError("kind must be lower-case, e.g. api_token")
        record["kind"] = kind
    purpose = check_free_text("purpose", fields.get("purpose"))
    if purpose:
        record["purpose"] = purpose
    if fields.get("expires_at") is not None:
        record["expires_at"] = check_expiry(fields["expires_at"])


def _apply_reach(record: dict[str, Any], fields: dict[str, Any]) -> None:
    zones = fields.get("zones")
    resources = fields.get("resources")
    if zones is None and resources is None:
        return
    reach = dict(record.get("reach") or {})
    if zones is not None:
        reach["zones"] = check_zones(zones)
    if resources is not None:
        reach["resources"] = check_resources(resources)
    record["reach"] = reach


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
