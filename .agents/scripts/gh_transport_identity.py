# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Trusted GitHub quota-owner attribution."""

import hashlib
import json
import os
import subprocess
import time
from pathlib import Path

OWNER_CACHE = "quota-owners.json"
OWNER_RETRY_SECONDS = 300


def quota_owner() -> tuple[str, bool]:
    """Return a validated configured owner and whether it is authoritative."""
    owner = os.environ.get("AIDEVOPS_GH_QUOTA_OWNER", "")
    if not owner or owner == "unresolved":
        return "unresolved", False
    if "\0" in owner or len(owner) > 256:
        raise ValueError("invalid GitHub quota owner")
    return owner, True


def _load_owner_cache(directory: Path) -> dict:
    path = directory / OWNER_CACHE
    try:
        if path.is_symlink() or path.stat().st_uid != os.getuid():
            return {}
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _store_owner_cache(directory: Path, cache: dict) -> None:
    path = directory / OWNER_CACHE
    temporary = directory / f"{OWNER_CACHE}.{os.getpid()}.tmp"
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(cache, stream, sort_keys=True)
        os.replace(temporary, path)
    except OSError:
        # Attribution only speeds recovery; failure keeps conservative accounting.
        return


def resolve_owner_proof(target: tuple[str, str], credential: str, environment: dict,
                        directory: Path) -> str | None:
    """Cache a one-way digest of the authenticated login for one credential.

    The login is never stored or logged. GitHub App installation tokens (ghs_)
    are never attributed to a user: they remain separate, unresolved owners.
    """
    token = environment.get("GH_TOKEN", "")
    executable, host = target
    if not token or token.startswith("ghs_"):
        return None
    now = time.time()
    cache = _load_owner_cache(directory)
    entry = cache.get(credential)
    if isinstance(entry, dict):
        if isinstance(entry.get("owner"), str) and entry["owner"]:
            return entry["owner"]
        if now - float(entry.get("failed_at", 0) or 0) < OWNER_RETRY_SECONDS:
            return None
    try:
        login = subprocess.run(  # nosec B603
            [executable, "api", "--hostname", host, "user", "--jq", ".login"],
            env=environment, capture_output=True, timeout=5, check=True,
        ).stdout.decode().strip()
    except (OSError, ValueError, subprocess.SubprocessError):
        login = ""
    if not login or len(login) > 256 or "\0" in login:
        cache[credential] = {"failed_at": now}
        _store_owner_cache(directory, cache)
        return None
    digest = hashlib.sha256(f"{host}\0{login}".encode()).hexdigest()
    cache[credential] = {"owner": digest}
    _store_owner_cache(directory, cache)
    return digest


def credentials_share_proven_owner(directory: Path, credentials: list[str]) -> bool:
    """True only when every credential has the same cached owner digest."""
    cache = _load_owner_cache(directory)
    owners = set()
    for credential in credentials:
        entry = cache.get(credential)
        owner = entry.get("owner") if isinstance(entry, dict) else None
        if not isinstance(owner, str) or not owner:
            return False
        owners.add(owner)
    return len(owners) == 1
