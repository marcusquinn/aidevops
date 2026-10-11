#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize Hostinger websites into a deterministic fleet inventory.

Pure data shaping: no network, SSH or filesystem mutation. Sites sharing one
account document root form a codebase; its primary owns the shared code and
the others are network members (WordPress) or aliases.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from repo_layout_migrate import canonical_bytes, expand_path, load_json, sha256_bytes  # noqa: E402

INVENTORY_SCHEMA = "aidevops-hostinger-fleet-inventory/v1"
DOMAIN_RE = re.compile(r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
WP_ROOT_RE = re.compile(r"^domains/[a-z0-9.-]+/public_html$")
PRIMARY_VHOSTS = ("main", "addon")
WORDPRESS_INSTALLS = ("single", "multisite")


class FleetError(RuntimeError):
    """A read-only fleet operation refused unsafe or invalid input."""


def relative_root(root: str | None) -> str | None:
    """Strip the account home prefix so private paths stay account-relative."""
    if not root:
        return None
    match = re.match(r"^/home/[^/]+/(.+)$", root)
    return match.group(1) if match else root


def normalize_site(raw: dict[str, Any]) -> dict[str, Any] | None:
    """Keep only non-secret identity fields required for planning."""
    domain = str(raw.get("domain") or "").strip().lower().rstrip(".")
    if not domain:
        return None
    if not DOMAIN_RE.match(domain):
        raise FleetError("Hostinger returned an invalid website domain")
    return {
        "domain": domain,
        "vhost_type": raw.get("vhost_type"),
        "website_type": raw.get("website_type"),
        "username": raw.get("username"),
        "parent_domain": raw.get("parent_domain") or None,
        "root": relative_root(raw.get("root_directory")),
        "is_enabled": bool(raw.get("is_enabled", True)),
        "source": "hosting-panel",
    }


def normalize_sites(websites: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Normalize every website that has a domain."""
    return [site for site in (normalize_site(item) for item in websites) if site]


def choose_primary(members: list[dict[str, Any]]) -> dict[str, Any]:
    """Pick the site that owns a shared document root."""
    root = members[0].get("root") or ""
    match = re.match(r"^domains/([^/]+)/", root)
    owner_domain = match.group(1).lower() if match else None

    def rank(site: dict[str, Any]) -> tuple[int, int, int, str]:
        return (
            0 if site["domain"] == owner_domain else 1,
            0 if site.get("vhost_type") in PRIMARY_VHOSTS else 1,
            0 if not site.get("parent_domain") else 1,
            site["domain"],
        )

    return sorted(members, key=rank)[0]


def is_wordpress(members: list[dict[str, Any]], install: str | None) -> bool:
    """A probe result is authoritative; the panel type is only a fallback.

    The panel reported website_type "other" for a live multisite network.
    """
    if install:
        return install in WORDPRESS_INSTALLS
    return any(item.get("website_type") == "wordpress" for item in members)


def build_codebases(
    sites: list[dict[str, Any]], discovery: dict[str, dict[str, Any]]
) -> list[dict[str, Any]]:
    """Group sites by account and document root; assign roles in place."""
    groups: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for site in sites:
        key = (str(site.get("username") or ""), site.get("root") or f"site:{site['domain']}")
        groups.setdefault(key, []).append(site)
    codebases = []
    for (username, root), members in sorted(groups.items()):
        primary = choose_primary(members)
        install = discovery.get(root, {}).get("status")
        wordpress = is_wordpress(members, install)
        secondary_role = "network-member" if wordpress else "alias"
        for site in members:
            site["codebase_primary"] = primary["domain"]
            site["role"] = "primary" if site is primary else secondary_role
        codebases.append(
            {
                "username": username or None,
                "root": None if root.startswith("site:") else root,
                "primary": primary["domain"],
                "wordpress": wordpress,
                "wordpress_install": install,
                "members": sorted(item["domain"] for item in members),
            }
        )
    return codebases


def load_network_map(path: str | None) -> dict[str, str]:
    """Load blog-domain -> primary-domain mappings for sites absent from the panel."""
    if not path:
        return {}
    payload = load_json(expand_path(path))
    if not isinstance(payload, dict):
        raise FleetError("Network map must be a JSON object of blog domain to primary domain")
    mapping = {}
    for blog, primary in payload.items():
        blog_domain = str(blog).strip().lower()
        primary_domain = str(primary).strip().lower()
        if not DOMAIN_RE.match(blog_domain) or not DOMAIN_RE.match(primary_domain):
            raise FleetError("Network map entries must be domain names")
        mapping[blog_domain] = primary_domain
    return mapping


def probe_roots(websites: list[dict[str, Any]]) -> list[str]:
    """Distinct standard document roots; website_type cannot gate discovery."""
    return sorted(
        {
            site["root"]
            for site in normalize_sites(websites)
            if site.get("root") and WP_ROOT_RE.match(site["root"])
        }
    )


def discovery_network_map(
    sites: list[dict[str, Any]], discovery: dict[str, dict[str, Any]]
) -> dict[str, str]:
    """Translate discovered multisite blogs into blog -> primary mappings."""
    mapping: dict[str, str] = {}
    for root, result in discovery.items():
        members = [site for site in sites if site.get("root") == root]
        if result["status"] != "multisite" or not members:
            continue
        primary = choose_primary(members)["domain"]
        for domain in result["domains"]:
            mapping[domain] = primary
    return mapping


def add_network_sites(
    sites: list[dict[str, Any]], mapping: dict[str, str], explicit: dict[str, str]
) -> None:
    """Append network blogs that have no hosting-panel entry."""
    by_domain = {site["domain"]: site for site in sites}
    for blog, primary in sorted(mapping.items()):
        if blog in by_domain:
            continue
        parent = by_domain.get(primary)
        if parent is None:
            raise FleetError("Network map primary is not a hosting-panel website")
        sites.append(
            {
                "domain": blog,
                "vhost_type": None,
                "website_type": parent.get("website_type"),
                "username": parent.get("username"),
                "parent_domain": primary,
                "root": parent.get("root"),
                "is_enabled": parent.get("is_enabled", True),
                "source": "network-map" if blog in explicit else "network-discovery",
            }
        )


def inventory_counts(sites: list[dict[str, Any]], codebases: list[dict[str, Any]]) -> dict[str, int]:
    """Summary counts for receipts and reconciliation."""
    return {
        "panel_entries": sum(1 for site in sites if site["source"] == "hosting-panel"),
        "sites": len(sites),
        "codebases": len(codebases),
        "wordpress_codebases": sum(1 for item in codebases if item["wordpress"]),
        "multisite_networks": sum(1 for item in codebases if item["wordpress_install"] == "multisite"),
        "disabled": sum(1 for site in sites if not site["is_enabled"]),
    }


def build_inventory(
    websites: list[dict[str, Any]],
    network_map: dict[str, str],
    discovery: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Return the deterministic, normalized, content-hashed fleet inventory."""
    sites = normalize_sites(websites)
    if len({site["domain"] for site in sites}) != len(sites):
        raise FleetError("Duplicate website domains in Hostinger inventory")
    discovery = discovery or {}
    # Explicit operator mappings win over discovered ones.
    merged = {**discovery_network_map(sites, discovery), **network_map}
    add_network_sites(sites, merged, network_map)
    sites.sort(key=lambda item: item["domain"])
    codebases = build_codebases(sites, discovery)
    inventory = {
        "schema": INVENTORY_SCHEMA,
        "accounts": sorted({str(site["username"]) for site in sites if site.get("username")}),
        "network_discovery": bool(discovery),
        "counts": inventory_counts(sites, codebases),
        "codebases": codebases,
        "sites": sites,
    }
    inventory["inventory_sha256"] = sha256_bytes(canonical_bytes(inventory))
    return inventory


def load_inventory(path: Path) -> dict[str, Any]:
    """Load an inventory and verify its content hash."""
    inventory = load_json(path)
    if not isinstance(inventory, dict) or inventory.get("schema") != INVENTORY_SCHEMA:
        raise FleetError("Unsupported inventory; regenerate it with 'fleet inventory'")
    body = {key: value for key, value in inventory.items() if key != "inventory_sha256"}
    if inventory.get("inventory_sha256") != sha256_bytes(canonical_bytes(body)):
        raise FleetError("Inventory hash mismatch; regenerate it with 'fleet inventory'")
    return inventory
