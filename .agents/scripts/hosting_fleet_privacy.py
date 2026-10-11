#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Select fleet privacy entities and merge them into the owner-private guard file."""

from __future__ import annotations

import fcntl
import os
import stat
from typing import Any

from hosting_fleet_inventory import DOMAIN_RE, FleetError
from hosting_fleet_plan import OWNER_RE, parse_exceptions, parse_site_repos
from repo_layout_migrate import atomic_write, expand_path, private_directory

DEFAULT_ENTITIES = "~/.aidevops/configs/privacy-guard-private-entities.txt"


def config_pairs(config: dict[str, Any], key: str) -> list[str]:
    """Convert a config mapping into the DOMAIN=VALUE form the CLI accepts."""
    mapping = config.get(key) or {}
    if not isinstance(mapping, dict):
        raise FleetError(f"Fleet config '{key}' must be an object")
    return [f"{name}={value}" for name, value in sorted(mapping.items())]


def fleet_entities(inventory: dict[str, Any], config: dict[str, Any]) -> set[tuple[str, str]]:
    """Select client names and fleet-owned repository slugs without printing values."""
    mappings = parse_site_repos(config_pairs(config, "site_repos"))
    exceptions = parse_exceptions(config_pairs(config, "owner_exceptions"))
    ignored = config.get("ignore") or []
    if not isinstance(ignored, list) or not all(isinstance(item, str) for item in ignored):
        raise FleetError("Fleet ignore must be a list of domains")
    excluded = {item.strip().lower() for item in ignored} | set(exceptions)
    # Exempt mapped repository names too, including when they are also hosted.
    excluded |= {mappings[name] for name in excluded if name in mappings}
    domains = {site["domain"] for site in inventory["sites"]} | set(mappings)
    names = domains | set(mappings.values())
    if not all(isinstance(name, str) and DOMAIN_RE.fullmatch(name) for name in names):
        raise FleetError("Invalid fleet domain")
    owner = config.get("owner")
    if owner is not None and (not isinstance(owner, str) or not OWNER_RE.fullmatch(owner)):
        raise FleetError("Invalid fleet owner")
    entities = {("client", name) for name in names - excluded}
    if owner:
        repos = {mappings.get(domain, domain) for domain in domains - excluded} - excluded
        entities |= {("repo", f"{owner}/{repo}") for repo in repos}
    return entities


def merge_private_entities(entities: set[tuple[str, str]]) -> int:
    """Serialize additive updates, preserving manual text and securing the file."""
    destination = expand_path(DEFAULT_ENTITIES)
    private_directory(destination.parent)
    lock = destination.with_suffix(".lock")
    descriptor = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "r+") as handle:
        details = os.fstat(handle.fileno())
        if not stat.S_ISREG(details.st_mode) or details.st_uid != os.getuid():
            raise FleetError("Unsafe privacy lock")
        os.fchmod(handle.fileno(), 0o600)
        fcntl.flock(handle, fcntl.LOCK_EX)
        text = ""
        if destination.exists() or destination.is_symlink():
            details = destination.lstat()
            if not stat.S_ISREG(details.st_mode) or details.st_uid != os.getuid():
                raise FleetError("Unsafe privacy entities file")
            text = destination.read_text(encoding="utf-8")
        existing = set()
        for line in text.splitlines():
            if not line or line.startswith("#"):
                continue
            separator = "\t" if "\t" in line else ":"
            kind, _, value = line.partition(separator)
            existing.add(("".join(kind.split()), value.strip()))
        additions = sorted(entities - existing)
        if text and not text.endswith("\n") and additions:
            text += "\n"
        text += "".join(f"{kind}:{value}\n" for kind, value in additions)
        atomic_write(destination, text.encode("utf-8"))
    return len(additions)
