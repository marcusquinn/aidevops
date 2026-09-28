#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""GH#32858: Darwin bundle ACLs must name the account; chmod -E rejects numeric uids."""

from __future__ import annotations

import importlib.util
import os
import pwd
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

CORE_PATH = Path(__file__).resolve().parents[1] / "source_access_core.py"
SPEC = importlib.util.spec_from_file_location("source_access_core_bundle_acl_test", CORE_PATH)
if SPEC is None or SPEC.loader is None:
    raise ImportError(f"cannot load {CORE_PATH}")
CORE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CORE
SPEC.loader.exec_module(CORE)

UID = os.getuid() or 501
NAME = "fixture-user"


def _account(name: str, uid: int) -> mock.Mock:
    return mock.Mock(pw_name=name, pw_uid=uid)


class DarwinBundleAclTests(unittest.TestCase):
    def _publish(self, getpwuid, getpwnam) -> list[tuple[list[str], bytes]]:
        calls: list[tuple[list[str], bytes]] = []

        def fake_run(command, **kwargs):
            calls.append((list(command), kwargs.get("input")))
            return subprocess.CompletedProcess(command, 0, b"", b"")

        config = CORE.Config(state_dir=Path("/nonexistent/state"), trust_uid=0)
        with mock.patch.object(CORE.sys, "platform", "darwin"), \
                mock.patch.object(CORE, "root_data_directory", return_value=Path("/nonexistent/state/bundles/1")), \
                mock.patch.object(CORE, "_trusted_file", return_value=True), \
                mock.patch.object(CORE, "_trusted_directory", return_value=True), \
                mock.patch.object(CORE.Path, "resolve", lambda self, strict=False: self), \
                mock.patch.object(CORE.os, "chmod"), \
                mock.patch.object(CORE.pwd, "getpwuid", getpwuid), \
                mock.patch.object(CORE.pwd, "getpwnam", getpwnam), \
                mock.patch.object(CORE.subprocess, "run", fake_run):
            CORE.private_bundle_parent(config, UID)
        return calls

    def test_acl_entry_uses_round_tripped_account_name(self) -> None:
        calls = self._publish(lambda uid: _account(NAME, uid), lambda name: _account(name, UID))
        self.assertEqual(len(calls), 1)
        command, content = calls[0]
        self.assertEqual(command[:2], ["/bin/chmod", "-E"])
        self.assertEqual(content, f"user:{NAME} allow list,search,readattr,readextattr,readsecurity\n".encode())
        self.assertNotIn(f"user:{UID} ".encode(), content)

    def test_name_that_resolves_to_another_uid_is_rejected(self) -> None:
        with self.assertRaisesRegex(CORE.SourceAccessError, "unsafe for an ACL entry"):
            self._publish(lambda uid: _account(NAME, uid), lambda name: _account(name, UID + 1))

    def test_malformed_account_name_is_rejected(self) -> None:
        bad = "evil\nuser:root allow write"
        with self.assertRaisesRegex(CORE.SourceAccessError, "unsafe for an ACL entry"):
            self._publish(lambda uid: _account(bad, uid), lambda name: _account(name, UID))

    def test_missing_account_is_rejected(self) -> None:
        def missing(_uid):
            raise KeyError("missing")

        with self.assertRaisesRegex(CORE.SourceAccessError, "no local account"):
            self._publish(missing, pwd.getpwnam)

    @unittest.skipUnless(sys.platform == "darwin", "exercises the real macOS chmod -E parser")
    def test_real_chmod_accepts_resolved_principal(self) -> None:
        base = Path.home() / ".aidevops" / ".agent-workspace" / "tmp"
        base.mkdir(parents=True, exist_ok=True)
        target = base / f"acl-probe-{os.getpid()}"
        target.mkdir(mode=0o700)
        try:
            principal = CORE._darwin_acl_principal(os.getuid())
            result = subprocess.run(  # nosec B603 -- fixed system binary on a test-owned temp directory
                ["/bin/chmod", "-E", str(target)],
                input=f"user:{principal} allow list,search\n".encode("ascii"),
                capture_output=True, check=False, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode())
        finally:
            target.rmdir()


if __name__ == "__main__":
    unittest.main()
