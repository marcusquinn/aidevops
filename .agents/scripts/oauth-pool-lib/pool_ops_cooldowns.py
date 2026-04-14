#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
oauth-pool-lib/pool_ops_cooldowns.py — cooldown normalisation commands.

stdin-driven cooldown housekeeping commands extracted from ``pool_ops.py``
during the t2069 decomposition. ``cmd_auto_clear`` lives in its own module
because it owns the pool file directly (atomic write under lock); these two
helpers operate on a pool dict piped via stdin.
"""

from __future__ import annotations

import json
import os
import sys
import time


def cmd_normalize_cooldowns() -> None:
    """normalize-cooldowns: Normalize expired cooldowns from a piped pool.

    Env: PROVIDER (provider name or "all")
    """
    provider = os.environ.get("PROVIDER", "all")
    pool = json.load(sys.stdin)
    now = int(time.time() * 1000)
    updated = 0
    providers = list(pool.keys()) if provider == "all" else [provider]
    for prov in providers:
        if prov.startswith("_"):
            continue
        for account in pool.get(prov, []):
            cooldown_ms = account.get("cooldownUntil") or 0
            if cooldown_ms > 0 and cooldown_ms <= now:
                account["status"] = "idle"
                account["cooldownUntil"] = 0
                updated += 1
    json.dump({"updated": updated, "pool": pool}, sys.stdout, separators=(",", ":"))


def cmd_reset_cooldowns() -> None:
    """reset-cooldowns: Reset cooldowns for accounts.

    Env: PROVIDER
    """
    pool = json.load(sys.stdin)
    target = os.environ["PROVIDER"]
    providers = list(pool.keys()) if target == "all" else [target]
    cleared = 0
    for prov in providers:
        for a in pool.get(prov, []):
            if a.get("cooldownUntil") or a.get("status") in ("rate-limited", "auth-error"):
                a["cooldownUntil"] = None
                a["status"] = "idle"
                cleared += 1
    json.dump({"cleared": cleared, "pool": pool}, sys.stdout, indent=2)
