#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Focused standard-library checks for the repository auth boundary."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import github_app_auth as backend
import pulse_repo_auth as auth


class RepositoryAuthTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.shim = str(Path(auth.__file__).resolve().with_name("gh"))
        self.personal_credential = uuid.uuid4().hex
        self.installation_credential = uuid.uuid4().hex
        self.key = self.root / "key.pem"
        self.key.write_text("test-key-material")
        self.key.chmod(0o600)
        self.profile = {"app_id": "123", "private_key_path": str(self.key)}
        self.config = self.root / "app.json"
        self.config.write_text(json.dumps({"profiles": {"team": self.profile}}))
        self.data = {"initialized_repos": [
            {"slug": "owner/repo", "pulse": False, "pulse_auth": {
                "provider": "github-app", "profile": "team", "installation_id": "456"}},
            {"slug": "owner/legacy", "pulse": True}]}
        self.env = patch.dict(os.environ, {"AIDEVOPS_PULSE_AUTH": "1",
                                          "GH_TOKEN": self.personal_credential,
                                          "GH_HOST": "github.com"})
        self.env.start()
        self.addCleanup(self.env.stop)
        os.environ.pop("AIDEVOPS_PULSE_REPO", None)

    def test_read_and_write_classification(self):
        for command in (["issue", "list"], ["pr", "view"],
                        ["api", "/repos/owner/repo/issues"],
                        ["api", "graphql", "-f", "query=query { viewer { login } }"]):
            self.assertEqual(auth.operation(command), "read")
        for command in (["issue", "create"], ["pr", "merge"],
                        ["api", "/repos/owner/repo/issues", "-f", "title=test"],
                        ["api", "graphql", "-f", "query=mutation { something }"]):
            self.assertEqual(auth.operation(command), "write")
        self.assertEqual(auth.operation(["api", "graphql", "--input", "body.json"]), "unknown")

    def test_explicit_single_repository(self):
        self.assertEqual(auth.repository(["issue", "list", "-Rowner/repo"]), "owner/repo")
        self.assertEqual(auth.repository(["api", "/repos/owner/repo/issues"]), "owner/repo")
        with self.assertRaises(backend.AuthError):
            auth.repository(["issue", "list"])
        with self.assertRaises(backend.AuthError):
            auth.repository(["issue", "list", "-R", "owner/repo", "--repo", "other/repo"])
        with patch.dict(os.environ, {"AIDEVOPS_PULSE_REPO": "other/repo"}):
            with self.assertRaises(backend.AuthError):
                auth.repository(["api", "/repos/owner/repo"])

    def test_read_isolation_and_no_retry(self):
        original = os.environ.copy()
        with patch.object(auth, "cached_token", return_value={"token": self.installation_credential}), \
                patch.object(auth.subprocess, "call", return_value=1) as call:
            self.assertEqual(auth.execute(self.shim, ["issue", "list", "-R", "owner/repo"], self.data, self.config), 1)
        call.assert_called_once()
        env = call.call_args.kwargs["env"]
        self.assertEqual(env["GH_TOKEN"], self.installation_credential)
        self.assertEqual(env["AIDEVOPS_GH_AUTH_PRINCIPAL"], "app-installation:456")
        self.assertEqual(env["AIDEVOPS_GITHUB_APP_ENABLED"], "0")
        self.assertNotIn(self.installation_credential, call.call_args.args[0])
        self.assertFalse(Path(env["GH_CONFIG_DIR"]).exists())
        self.assertEqual(os.environ, original)

    def test_writes_and_legacy_repo_keep_original_credentials(self):
        for command in (["pr", "merge", "1", "-R", "owner/repo"],
                        ["issue", "list", "-R", "owner/legacy"]):
            with patch.object(auth, "cached_token") as mint, \
                    patch.object(auth.subprocess, "call", return_value=0) as call:
                self.assertEqual(auth.execute(self.shim, command, self.data, self.config), 0)
            mint.assert_not_called()
            self.assertEqual(call.call_args.kwargs["env"]["GH_TOKEN"], self.personal_credential)

    def test_failed_mint_never_invokes_personal_transport(self):
        with patch.object(auth, "cached_token", side_effect=backend.AuthError("denied")), \
                patch.object(auth.subprocess, "call") as call:
            with self.assertRaises(backend.AuthError):
                auth.execute("gh", ["issue", "list", "-R", "owner/repo"], self.data, self.config)
        call.assert_not_called()

    def test_ambiguous_scope_and_header_override_fail_closed(self):
        for command in (["api", "/search/issues"], ["custom-extension"],
                        ["api", "/repos/owner/repo", "-H", "Authorization: example"],
                        ["api", "/repos/owner/repo", "--hostname", "other.example"]):
            with patch.object(auth.subprocess, "call") as call:
                with self.assertRaises(backend.AuthError):
                    auth.execute("gh", command, self.data, self.config)
                call.assert_not_called()

    def test_account_identity_is_not_replaced_by_bot(self):
        for command in (["api", "user"], ["api", "rate_limit"]):
            self.assertEqual(auth.operation(command), "account")
            with patch.object(auth, "cached_token") as mint, \
                    patch.object(auth.subprocess, "call", return_value=0) as call:
                auth.execute(self.shim, command, self.data, self.config)
                mint.assert_not_called()
                self.assertEqual(call.call_args.kwargs["env"]["GH_TOKEN"], self.personal_credential)
        with patch.dict(os.environ, {"AIDEVOPS_PULSE_REPO": "owner/repo"}):
            self.assertEqual(auth.operation(["api", "rate_limit"]), "read")

    def test_api_option_order_graphql_variables_and_mixed_documents(self):
        command = ["api", "-X", "GET", "--hostname", "github.com", "/repos/owner/repo"]
        self.assertEqual(auth.operation(command), "read")
        self.assertEqual(auth.repository(command), "owner/repo")
        command = ["api", "graphql", "-F", "owner=owner", "-F", "name=repo",
                   "-f", "query=query { repository(owner: $owner, name: $name) { id } }"]
        self.assertEqual(auth.repository(command), "owner/repo")
        self.assertEqual(auth.operation(command + ["-f", "query=mutation { delete }"]), "unknown")
        self.assertEqual(auth.operation(["api", "graphql", "-f", "query=query { viewer { login } } mutation { delete }"]), "unknown")
        self.assertFalse(auth.valid_slug("../repo"))

    def test_duplicate_registry_and_write_permissions_rejected(self):
        self.data["initialized_repos"].append(self.data["initialized_repos"][0].copy())
        with self.assertRaises(backend.AuthError):
            auth.settings(self.data, "owner/repo", self.config)
        self.data["initialized_repos"].pop()
        self.profile["permissions"] = {"issues": "write"}
        self.config.write_text(json.dumps({"profiles": {"team": self.profile}}))
        with self.assertRaises(backend.AuthError):
            auth.settings(self.data, "owner/repo", self.config)

    def test_cli_set_is_atomic_and_preserves_pulse(self):
        registry = self.root / "repos.json"
        registry.write_text(json.dumps(self.data))
        env = dict(os.environ, AIDEVOPS_REPOS_CONFIG=str(registry), AIDEVOPS_GITHUB_APP_CONFIG=str(self.config))
        command = [sys.executable, str(Path(auth.__file__)), "set", "owner/repo", "--profile", "team", "--installation-id", "789"]
        # Interpreter and sibling test target are fixed; no shell or external command input.
        result = subprocess.run(command, env=env, capture_output=True, text=True, check=False)  # nosec B603
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = json.loads(registry.read_text())
        self.assertFalse(actual["initialized_repos"][0]["pulse"])
        self.assertEqual(actual["initialized_repos"][0]["pulse_auth"]["installation_id"], "789")
        self.assertEqual(actual["initialized_repos"][1], self.data["initialized_repos"][1])
        self.assertFalse(Path(str(registry) + ".lock").exists())

    def test_cache_refresh_rotation_and_scope(self):
        cache = self.root / "cache"
        response = {"token": self.installation_credential, "expires_at_epoch": time.time() + 3600}
        with patch.object(backend, "exchange", return_value=response) as mint:
            backend.cached_token(self.profile, "456", "owner/repo", cache)
            backend.cached_token(self.profile, "456", "owner/repo", cache)
            self.assertEqual(mint.call_count, 1)
            backend.cached_token(self.profile, "789", "owner/repo", cache)
            backend.cached_token(self.profile, "456", "owner/another", cache)
            self.key.write_text("rotated-key-material")
            backend.cached_token(self.profile, "456", "owner/repo", cache)
            self.assertEqual(mint.call_count, 4)
            for path in cache.glob("*.json"):
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                value = json.loads(path.read_text())
                value["expires_at_epoch"] = time.time() + 30
                path.write_text(json.dumps(value))
            backend.cached_token(self.profile, "456", "owner/repo", cache)
            self.assertEqual(mint.call_count, 5)

    def test_private_file_and_lock_safety(self):
        with self.assertRaises(backend.AuthError):
            auth.run_shim("/untrusted/program", [], {})
        self.key.chmod(0o644)
        with self.assertRaises(backend.AuthError):
            backend.private_read(self.key, secret=True)
        link = self.root / "link"
        link.symlink_to(self.key)
        with self.assertRaises(OSError):
            backend.private_read(link)
        with backend.lock(self.root / "lock"):
            with self.assertRaises(backend.AuthError):
                with backend.lock(self.root / "lock", timeout=0):
                    self.fail("Lock should not be acquired twice")


if __name__ == "__main__":
    unittest.main()
