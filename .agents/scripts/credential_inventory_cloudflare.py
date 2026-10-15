#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only Cloudflare verification for the credential registry (GH#34722).

Run only on explicit request, as a child of `secret-helper.sh NAME -- ...`,
so the token arrives in this process's environment and never in argv:

    aidevops secret verify cloudflare [NAME...]

Every request is an HTTP GET. Raw account IDs are replaced with SHA-256
fingerprints before anything is printed or cached; token values are never
printed or stored. Paths follow the Cloudflare API v4 reference.
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import credential_inventory_fields as rules  # noqa: E402
import credential_inventory_store as store  # noqa: E402

API = "https://api.cloudflare.com/client/v4"
TIMEOUT = 20
MAX_PAGES = 40
PER_PAGE = 50
RESOURCE_PATHS = {"worker": "workers/scripts", "pages": "pages/projects", "r2": "r2/buckets"}


class ApiError(Exception):
    """A Cloudflare call failed; `status` is the HTTP status when known."""

    def __init__(self, status: int | None, message: str) -> None:
        super().__init__(message)
        self.status = status


def fingerprint(raw_id: str) -> str:
    """Stable, non-reversible stand-in for a provider account ID."""
    return "sha256:" + hashlib.sha256(str(raw_id).encode("utf-8")).hexdigest()[:16]


def api_get(token: str, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    """One GET; returns the decoded envelope or raises ApiError (no token in messages)."""
    url = f"{API}/{path}" + (f"?{urllib.parse.urlencode(params)}" if params else "")
    request = urllib.request.Request(url, method="GET", headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:  # nosec B310 -- fixed https API base
            body = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise ApiError(exc.code, f"HTTP {exc.code} for {path}") from None
    except (urllib.error.URLError, TimeoutError, ValueError) as exc:
        raise ApiError(None, f"{type(exc).__name__} for {path}") from None
    if not body.get("success", False):
        raise ApiError(None, f"unsuccessful response for {path}")
    return body


def paged(token: str, path: str) -> list[dict[str, Any]]:
    """All results of a page/per_page (or cursor) listing, bounded by MAX_PAGES."""
    items: list[dict[str, Any]] = []
    params: dict[str, Any] = {"per_page": PER_PAGE, "page": 1}
    for _ in range(MAX_PAGES):
        body = api_get(token, path, params)
        result = body.get("result")
        batch = result.get("buckets", []) if isinstance(result, dict) else (result or [])
        items += batch
        info = body.get("result_info") or {}
        if info.get("cursor"):
            params = {"per_page": PER_PAGE, "cursor": info["cursor"]}
        elif info.get("total_pages") and params.get("page", 0) < info["total_pages"]:
            params = {"per_page": PER_PAGE, "page": params["page"] + 1}
        else:
            break
    return items


def verify_token(token: str, account_ids: list[str]) -> dict[str, Any]:
    """User-token verify, falling back to account-owned token verify."""
    paths = ["user/tokens/verify"] + [f"accounts/{account_id}/tokens/verify" for account_id in account_ids]
    for path in paths:
        try:
            result = api_get(token, path).get("result") or {}
        except ApiError:
            continue
        expires = str(result.get("expires_on") or "")[:10] or None
        return {"status": result.get("status", "unknown"), "expires_on": expires,
                "scope": "user" if path.startswith("user/") else "account"}
    return {"status": "unverified", "expires_on": None, "scope": None}


def account_resources(token: str, account_id: str) -> tuple[list[dict], list[dict]]:
    """Best-effort Workers/Pages/R2 names; 401/403 recorded as unreadable."""
    found: list[dict] = []
    unreadable: list[dict] = []
    for kind, suffix in RESOURCE_PATHS.items():
        try:
            items = paged(token, f"accounts/{account_id}/{suffix}")
        except ApiError as exc:
            unreadable.append({"type": kind, "account": fingerprint(account_id),
                               "reason": "forbidden" if exc.status in (401, 403) else "error"})
            continue
        for item in items:
            name = item.get("id") or item.get("name") or item.get("script_name")
            if name:
                found.append({"type": kind, "name": str(name), "account": fingerprint(account_id)})
    return found, unreadable


def observe(token: str) -> dict[str, Any]:
    """Everything the token can see, with account IDs fingerprinted."""
    observation: dict[str, Any] = {"verified_at": rules.now_iso(), "errors": []}
    try:
        accounts = paged(token, "accounts")
    except ApiError as exc:
        accounts = []
        observation["errors"].append(str(exc))
    ids = [str(account.get("id")) for account in accounts if account.get("id")]
    observation["token"] = verify_token(token, ids)
    observation["accounts"] = [{"name": str(account.get("name") or ""), "fingerprint": fingerprint(account["id"])}
                               for account in accounts if account.get("id")]
    try:
        zones = paged(token, "zones")
    except ApiError as exc:
        zones = []
        observation["errors"].append(str(exc))
    observation["zones"] = sorted(
        ({"name": str(zone.get("name")), "status": str(zone.get("status") or ""),
          "account": fingerprint((zone.get("account") or {}).get("id", ""))} for zone in zones if zone.get("name")),
        key=lambda zone: zone["name"],
    )
    observation["resources"], observation["unreadable"] = [], []
    for account_id in ids:
        found, unreadable = account_resources(token, account_id)
        observation["resources"] += found
        observation["unreadable"] += unreadable
    return observation


def summary(name: str, observation: dict[str, Any]) -> str:
    """One-paragraph, value-free report of a verification."""
    token = observation["token"]
    accounts = ", ".join(account["name"] for account in observation["accounts"]) or "none visible"
    lines = [
        f"{name}  -> {token['status']} ({token['scope'] or 'scope unknown'}), expires {token['expires_on'] or 'never/unknown'}",
        f"  accounts: {accounts}",
        f"  zones: {len(observation['zones'])}, resources: {len(observation['resources'])}, unreadable: {len(observation['unreadable'])}",
    ]
    lines += [f"  error: {error}" for error in observation["errors"]]
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[0] != "verify":
        print("usage: credential_inventory_cloudflare.py verify NAME (run via: aidevops secret verify cloudflare)", file=sys.stderr)
        return 2
    name = rules.check_name("secret name", argv[1])
    token = os.environ.get(name, "")
    if not token:
        print(f"{name} was not injected; run via: aidevops secret verify cloudflare {name}", file=sys.stderr)
        return 1
    observation = observe(token)
    with store.locked() as data:
        store.set_verification(data, name, observation)
    print(summary(name, observation))
    return 0 if observation["token"]["status"] == "active" else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except rules.InventoryError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(2)
