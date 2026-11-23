#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Offline tests for entry-get/entry-put/entry-fingerprint (remote-sync)."""

from __future__ import annotations

import json
import os
import stat
import subprocess  # nosec B404 - test runs a fixed local script
import sys
import tempfile
import unittest
from pathlib import Path

POOL_OPS_PY = Path(__file__).resolve().parents[1] / "oauth-pool-lib" / "pool_ops.py"
EMAIL = "a@example.com"


def run(op: str, pool: Path, stdin: str = "") -> tuple[str, str]:
    env = dict(os.environ, POOL_FILE_PATH=str(pool), PROVIDER="anthropic", EMAIL=EMAIL)
    proc = subprocess.run(  # nosec B603 - fixed argv, no shell, test-controlled input
        [sys.executable, str(POOL_OPS_PY), f"entry-{op}"],
        input=stdin, capture_output=True, text=True, env=env, check=True,
    )
    return proc.stdout, proc.stderr.strip()


def entry(expires: int, refresh: str, **extra) -> dict:
    return {"email": EMAIL, "access": "acc-" + refresh, "refresh": refresh,
            "expires": expires, "status": "active", **extra}


class EntrySyncTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.a = Path(self.tmp.name) / "a" / "oauth-pool.json"
        self.b = Path(self.tmp.name) / "b" / "oauth-pool.json"
        for p in (self.a, self.b):
            p.parent.mkdir()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, path: Path, data: dict) -> None:
        path.write_text(json.dumps(data))

    def sync(self) -> None:
        out, _ = run("get", self.a)
        back, _ = run("put", self.b, out)
        run("put", self.a, back)

    def test_newer_flows_both_ways_and_older_never_overwrites(self) -> None:
        self.write(self.a, {"anthropic": [entry(200, "new")]})
        self.write(self.b, {"anthropic": [entry(100, "old")]})
        self.sync()
        self.assertEqual(json.loads(self.b.read_text())["anthropic"][0]["refresh"], "new")
        self.write(self.b, {"anthropic": [entry(300, "newest")]})
        self.sync()
        self.assertEqual(json.loads(self.a.read_text())["anthropic"][0]["refresh"], "newest")
        _, status = run("put", self.b, json.dumps(entry(50, "stale")))
        self.assertEqual(status, "unchanged")

    def test_auth_error_cleared_other_providers_untouched_mode_600(self) -> None:
        self.write(self.a, {"anthropic": [entry(200, "new")]})
        self.write(self.b, {
            "anthropic": [entry(100, "old", status="auth-error", authRefreshFailures=3)],
            "openai": [{"email": "o@example.com", "refresh": "keep"}],
        })
        self.sync()
        pool = json.loads(self.b.read_text())
        acct = pool["anthropic"][0]
        self.assertEqual(acct["status"], "active")
        self.assertNotIn("authRefreshFailures", acct)
        self.assertEqual(pool["openai"][0]["refresh"], "keep")
        self.assertEqual(stat.S_IMODE(self.b.stat().st_mode), 0o600)
        self.assertFalse(Path(str(self.b) + ".lock.d").exists())

    def test_insert_and_empty_stdin_noop(self) -> None:
        self.write(self.b, {"openai": []})
        _, status = run("put", self.b, "")
        self.assertEqual(status, "noop")
        _, status = run("put", self.b, json.dumps(entry(5, "r")))
        self.assertEqual(status, "inserted")
        self.assertEqual(json.loads(self.b.read_text())["anthropic"][0]["status"], "active")

    def test_fingerprint_hides_tokens(self) -> None:
        self.write(self.a, {"anthropic": [entry(200, "secret-refresh")]})
        out, _ = run("fingerprint", self.a)
        self.assertNotIn("secret-refresh", out)
        self.assertIn("expires=200", out)


if __name__ == "__main__":
    unittest.main()
