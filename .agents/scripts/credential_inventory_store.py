#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Non-secret local credential registry (GH#34680).

Records which provider account each stored secret opens, what it reaches,
who it is for, when it expires, and the explicit default per provider. The
registry holds secret *names* and environment-variable names only: never
secret values and never raw provider account IDs.

Modules: `credential_inventory_fields` (field rules), `_schema` (document
validation), `_names` (defaults and aliases), and this file (I/O and
account/credential records).
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import stat
import tempfile
from pathlib import Path
from typing import Any, Iterator

from credential_inventory_fields import (
    KIND_RE,
    InventoryError,
    check_expiry,
    check_free_text,
    check_name,
    check_ref,
    check_resources,
    check_zones,
    empty_inventory,
    inventory_path,
    merge_ownership,
    now_iso,
)
from credential_inventory_names import alias_owner
from credential_inventory_schema import validate


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
    merge_ownership(ownership, fields)
    if ownership:
        account["ownership"] = ownership
    data["provider_accounts"][ref] = account
    return account


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
