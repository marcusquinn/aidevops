#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
oauth-pool-lib/_common.py — Shared primitives for pool_ops_*.py modules.

Houses cross-platform locking, atomic file writes, the provider endpoint
tables, and the auth.json entry builder. Extracted from pool_ops.py during
the t2069 decomposition so each per-command module imports from here rather
than re-declaring its own copies.

Security: No token values are printed by any helper here.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request
from typing import Any


TOKEN_URLS: dict[str, str] = {
    "anthropic": "https://platform.claude.com/v1/oauth/token",
    "openai": "https://auth.openai.com/oauth/token",
    "google": "https://oauth2.googleapis.com/token",
}

CLIENT_IDS: dict[str, str] = {
    "anthropic": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
    "openai": "app_EMoamEEZ73f0CkXaXp7hrann",
    "google": "681255809395-oo8ft6t5t0rnmhfqgpnkqtev5b9a2i5j.apps.googleusercontent.com",
}


# ---------------------------------------------------------------------------
# Cross-platform exclusive file lock (stdlib only, no pip dependencies).
# ---------------------------------------------------------------------------

def _acquire_lock_win(lock_fd) -> None:
    import msvcrt
    deadline = time.time() + 30
    while True:
        try:
            lock_fd.seek(0)
            msvcrt.locking(lock_fd.fileno(), msvcrt.LK_NBLCK, 1)
            return
        except OSError:
            if time.time() >= deadline:
                raise
            time.sleep(0.1)


def _release_lock_win(lock_fd) -> None:
    import msvcrt
    try:
        lock_fd.seek(0)
        msvcrt.locking(lock_fd.fileno(), msvcrt.LK_UNLCK, 1)
    except OSError:
        pass


def acquire_lock(lock_fd) -> None:
    """Acquire an exclusive lock on the given file descriptor."""
    if sys.platform == "win32":
        _acquire_lock_win(lock_fd)
        return
    import fcntl
    fcntl.flock(lock_fd, fcntl.LOCK_EX)


def release_lock(lock_fd) -> None:
    """Release an exclusive lock on the given file descriptor."""
    if sys.platform == "win32":
        _release_lock_win(lock_fd)
        return
    import fcntl
    fcntl.flock(lock_fd, fcntl.LOCK_UN)


def atomic_write_json(path: str, data: Any) -> None:
    """Atomically write JSON data to a file (write-to-temp then rename)."""
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ---------------------------------------------------------------------------
# Auth-entry builder (shared by rotate + refresh self-heal).
# ---------------------------------------------------------------------------

def build_auth_entry(provider: str, account: dict, current_auth: dict) -> dict:
    """Build the per-provider entry for ``auth.json`` from a pool account.

    Carries over ``accountId`` for OpenAI (preserving the workspace selection
    when the new account doesn't override it), and falls back to the existing
    ``type`` from ``current_auth`` if present (defaults to ``oauth``).
    """
    entry: dict[str, Any] = {
        "type": current_auth.get("type", "oauth") if isinstance(current_auth, dict) else "oauth",
        "refresh": account.get("refresh", ""),
        "access": account.get("access", ""),
        "expires": account.get("expires", 0),
    }
    if provider == "openai":
        existing_id = current_auth.get("accountId", "") if isinstance(current_auth, dict) else ""
        account_id = account.get("accountId", existing_id)
        if account_id:
            entry["accountId"] = account_id
    return entry


# ---------------------------------------------------------------------------
# OAuth refresh request (shared by cmd_refresh + cmd_rotate auto-refresh).
# ---------------------------------------------------------------------------

def call_token_endpoint(
    token_url: str,
    client_id: str,
    refresh_tok: str,
    ua_header: str,
    timeout: int = 15,
) -> dict | None:
    """POST a refresh-token grant to ``token_url`` and return the parsed JSON.

    Returns ``None`` on any HTTP/network error. The caller is responsible for
    deciding what counts as success — a 200 response that omits
    ``access_token`` should still be treated as a failure by the caller.
    """
    body = json.dumps(
        {
            "grant_type": "refresh_token",
            "refresh_token": refresh_tok,
            "client_id": client_id,
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        token_url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "User-Agent": ua_header,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, urllib.error.HTTPError, OSError):
        return None
