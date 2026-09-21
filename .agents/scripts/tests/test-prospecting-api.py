#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Focused transport, scope, revocation, CSRF, and no-spend service tests."""

from __future__ import annotations

import copy
import json
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import prospecting_auth as auth  # noqa: E402
from prospecting_api import API_SCHEMA, ProspectingAPI  # noqa: E402
from prospecting_mcp import APIClient, MCPAdapterError  # noqa: E402
from prospecting_store import connect, import_document, migrate  # noqa: E402

FIXTURES = Path(__file__).parent / "fixtures" / "prospecting"


def beta_document(alpha: dict) -> dict:
    beta = copy.deepcopy(alpha)
    beta["project"]["project_id"] = "project-beta"
    beta["project"]["name"] = "Beta"
    for index, item in enumerate(beta["objects"], 1):
        item["object_id"] = f"beta-object-{index}"
        item["evidence_id"] = f"ev1:corpus-beta:reddit:sha256:{index}"
        item["corpus_id"] = "corpus-beta"
        item["parent_object_id"] = None
    for index, lead in enumerate(beta["leads"], 1):
        lead["lead_id"] = f"beta-lead-{index}"
        lead["object_id"] = beta["objects"][0]["object_id"]
    return beta


class ProspectingAPITest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "store"
        self.database = connect(self.root)
        migrate(self.database)
        alpha = json.loads((FIXTURES / "store.json").read_text(encoding="utf-8"))
        self.api_fixture = json.loads((FIXTURES / "api.json").read_text(encoding="utf-8"))
        alpha["leads"][0]["matching_phrase"] = self.api_fixture["malicious_phrase"]
        import_document(self.database, alpha)
        import_document(self.database, beta_document(alpha))
        self.auth_database = auth.connect(self.root)
        self.read_token = auth.issue_read_key(self.auth_database, ["project-alpha"])
        self.owner_token, self.csrf = auth.issue_owner_session(self.auth_database, ["project-alpha"])
        self.api = ProspectingAPI(self.database, self.auth_database)

    def tearDown(self) -> None:
        self.database.close()
        self.auth_database.close()
        self.temporary.cleanup()

    @property
    def read_headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.read_token}"}

    @property
    def owner_headers(self) -> dict[str, str]:
        return {"Cookie": f"prospecting_owner={self.owner_token}", "X-CSRF-Token": self.csrf,
                "Host": "127.0.0.1:8765", "Origin": "http://127.0.0.1:8765"}

    def request(self, method: str, path: str, headers: dict[str, str] | None = None, value: dict | None = None):
        raw = json.dumps(value).encode() if value is not None else b""
        return self.api.request(method, path, headers, raw)

    def test_scoped_reads_match_store_and_hide_secret_references(self) -> None:
        projects = self.request("GET", "/v1/projects", self.read_headers)
        self.assertEqual(200, projects.status)
        self.assertEqual(["project-alpha"], [row["project_id"] for row in projects.body["projects"]])
        detail = self.request("GET", "/v1/projects/project-alpha", self.read_headers)
        self.assertNotIn("secret_profile_refs", detail.body["project"]["profile"])
        denied = self.request("GET", "/v1/projects/project-beta", self.read_headers)
        unknown = self.request("GET", "/v1/projects/not-a-project", self.read_headers)
        self.assertEqual((404, denied.body), (unknown.status, unknown.body))

    def test_pagination_coverage_and_untrusted_text_stays_data(self) -> None:
        first = self.request("GET", "/v1/projects/project-alpha/leads?limit=1", self.read_headers)
        self.assertEqual(API_SCHEMA, first.body["schema"])
        self.assertEqual(1, first.body["coverage"]["returned"])
        self.assertEqual(self.api_fixture["malicious_phrase"], first.body["items"][0]["matching_phrase"])
        cursor = first.body["next_cursor"]
        second = self.request("GET", f"/v1/projects/project-alpha/leads?limit=1&cursor={cursor}", self.read_headers)
        self.assertNotEqual(first.body["items"][0]["lead_id"], second.body["items"][0]["lead_id"])
        extra = self.request("GET", "/v1/projects/project-alpha/leads?file=/etc/passwd", self.read_headers)
        self.assertEqual(400, extra.status)

    def test_read_key_cannot_mutate_and_revocation_is_immediate(self) -> None:
        mutation = self.request("PATCH", "/v1/operator/projects/project-alpha/leads/ask-1", self.read_headers,
                                {"disposition": "saved", "expected_version": 1})
        self.assertEqual(403, mutation.status)
        credential_id = self.read_token.split("_", 2)[1]
        auth.revoke(self.auth_database, credential_id)
        self.assertEqual(401, self.request("GET", "/v1/projects", self.read_headers).status)

    def test_owner_requires_origin_csrf_and_scope(self) -> None:
        path = "/v1/operator/projects/project-alpha/leads/ask-1"
        value = {"disposition": "saved", "expected_version": 1}
        self.assertEqual(403, self.request("PATCH", path, {**self.owner_headers, "Origin": "https://evil.example"}, value).status)
        self.assertEqual(401, self.request("PATCH", path, {**self.owner_headers, "X-CSRF-Token": "wrong"}, value).status)
        changed = self.request("PATCH", path, self.owner_headers, value)
        self.assertEqual(200, changed.status)
        self.assertEqual(404, self.request("PATCH", path.replace("project-alpha", "project-beta"), self.owner_headers, value).status)

    def test_manual_job_is_bounded_idempotent_and_does_not_execute(self) -> None:
        path = "/v1/operator/projects/project-alpha/jobs"
        first = self.request("POST", path, self.owner_headers, self.api_fixture["job"])
        second = self.request("POST", path, self.owner_headers, self.api_fixture["job"])
        self.assertEqual((202, False), (first.status, first.body["replayed"]))
        self.assertTrue(second.body["replayed"])
        jobs = self.database.execute("SELECT count(*) FROM jobs").fetchone()[0]
        usage = self.database.execute("SELECT count(*) FROM usage_records").fetchone()[0]
        self.assertEqual((0, 0), (jobs, usage))
        unsafe = {**self.api_fixture["job"], "command": "curl https://evil.example"}
        self.assertEqual(400, self.request("POST", path, self.owner_headers, unsafe).status)

    def test_mcp_client_rejects_ssrf(self) -> None:
        with self.assertRaises(MCPAdapterError):
            APIClient("https://example.test", f"Bearer {self.read_token}")


class ProspectingHTTPIntegrationTest(unittest.TestCase):
    def test_isolated_http_service_and_mcp_adapter(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "store"
            database = connect(root)
            migrate(database)
            document = json.loads((FIXTURES / "store.json").read_text(encoding="utf-8"))
            import_document(database, document)
            database.close()
            auth_database = auth.connect(root)
            token = auth.issue_read_key(auth_database, ["project-alpha"])
            auth_database.close()
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            process = subprocess.Popen(  # noqa: S603
                [sys.executable, str(SCRIPTS / "prospecting-service-helper.py"), "--store", str(root), "serve", "--port", str(port)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            try:
                url = f"http://127.0.0.1:{port}"
                for _attempt in range(30):
                    try:
                        with urlopen(url + "/v1/health", timeout=0.2) as response:  # noqa: S310 -- test loopback
                            if response.status == 200:
                                break
                    except OSError:
                        time.sleep(0.05)
                else:
                    self.fail("isolated service did not become ready")
                client = APIClient(url, f"Bearer {token}")
                self.assertEqual("project-alpha", client.get("/v1/projects")["projects"][0]["project_id"])
                traversal = Request(url + "/ui/%2e%2e/prospecting.db")
                with self.assertRaises(HTTPError) as denied:
                    urlopen(traversal, timeout=1)  # noqa: S310 -- test loopback
                self.assertEqual(404, denied.exception.code)
            finally:
                process.terminate()
                process.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()
