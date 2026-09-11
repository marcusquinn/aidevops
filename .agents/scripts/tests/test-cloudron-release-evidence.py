#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline trust-negative coverage using the existing unittest/mock tooling."""

import base64
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("catalog_evidence", Path(__file__).resolve().parents[1] / "cloudron-release-evidence.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.repo = "testorg/package"
        self.source, self.commit = "1" * 40, "2" * 40
        self.proof = MODULE.CatalogEvidence(dict(repo=self.repo, tag="v2.0.12", source=self.source,
                                                commit=self.commit, workflow="publish.yml", event="push"))
        self.before = {"stable": True, "versions": {"2.0.11": {"retained": True}}}
        self.manifest = {"version": "2.0.12", "upstreamVersion": "0.77.1", "changelog": "file://CHANGELOG"}
        self.image = "ghcr.io/" + self.repo + "@sha256:" + "3" * 64
        self.after = copy.deepcopy(self.before)
        self.after["versions"]["2.0.12"] = {
            "publishState": "published",
            "manifest": dict(self.manifest, dockerImage=self.image, changelog="* Fix startup.\n"),
        }
        self.commit_data = {"sha": self.commit, "parents": [{"sha": self.source}],
                            "files": [{"filename": MODULE.CATALOG, "status": "modified"}]}
        self.release = {"tag_name": "v2.0.12", "draft": False, "prerelease": False}
        self.run = {"id": 123, "run_attempt": 1, "event": "push", "status": "completed", "conclusion": "success",
                    "head_sha": self.source, "head_branch": "main", "path": ".github/workflows/publish.yml",
                    "repository": {"full_name": self.repo}, "head_repository": {"full_name": self.repo}}
        self.attest_mutation = lambda result, image: None
        self.extra_runs = []

    def api_content(self, path, value):
        data = value.encode() if isinstance(value, str) else json.dumps(value).encode()
        return {"type": "file", "path": path, "encoding": "base64", "size": len(data),
                "content": base64.b64encode(data).decode()}

    def fake_gh(self, *args):
        if args[0] == "api":
            endpoint = args[1].removeprefix("repos/" + self.repo + "/")
            mapping = {
                "commits/" + self.commit: self.commit_data,
                "releases/tags/v2.0.12": self.release,
                "contents/CloudronVersions.json?ref=" + self.source: self.api_content(MODULE.CATALOG, self.before),
                "contents/CloudronVersions.json?ref=" + self.commit: self.api_content(MODULE.CATALOG, self.after),
                "contents/CloudronManifest.json?ref=" + self.source: self.api_content("CloudronManifest.json", self.manifest),
                "contents/CHANGELOG?ref=" + self.source: self.api_content("CHANGELOG", "[2.0.12]\n* Fix startup.\n\n[2.0.11]\n* Earlier.\n"),
                "actions/workflows/publish.yml/runs?event=push&status=success&per_page=100": {"workflow_runs": [self.run, *self.extra_runs]},
            }
            return copy.deepcopy(mapping[endpoint])
        self.assertEqual(args[:2], ("attestation", "verify"))
        self.assertEqual(args[3:], ("--repo", self.repo, "--signer-workflow", self.repo + "/.github/workflows/publish.yml",
                                    "--source-ref", "refs/heads/main", "--format", "json"))
        image = args[2].startswith("oci://")
        name = self.image.split("@")[0] if image else MODULE.CATALOG
        digest = "3" * 64 if image else hashlib.sha256(Path(args[2]).read_bytes()).hexdigest()
        invocation = self.proof.repository_url + "/actions/runs/123/attempts/1"
        cert = dict(issuer="https://token.actions.githubusercontent.com",
                    sourceRepositoryURI=self.proof.repository_url, sourceRepositoryDigest=self.source,
                    sourceRepositoryRef=MODULE.SOURCE_REF, buildConfigURI=self.proof.signer,
                    buildConfigDigest=self.source, buildSignerURI=self.proof.signer,
                    buildSignerDigest=self.source, buildTrigger="push", runInvocationURI=invocation)
        verified = {"signature": {"certificate": cert}, "statement": {
            "predicateType": "https://slsa.dev/provenance/v1", "subject": [{"name": name, "digest": {"sha256": digest}}],
            "predicate": {"runDetails": {"metadata": {"invocationId": invocation}}}}}
        self.attest_mutation(verified, image)
        return [{"verificationResult": verified}]

    def verify(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, AIDEVOPS_TEMP_DIR=directory), \
                patch.object(MODULE, "gh", side_effect=self.fake_gh):
            return self.proof.verify()

    def test_valid_catalog_and_replay(self):
        self.assertTrue(self.verify())
        self.assertTrue(self.verify())

    def test_generated_commit_boundaries(self):
        cases = [
            {"sha": "4" * 40}, {"parents": [{"sha": "4" * 40}]},
            {"parents": [{"sha": self.source}, {"sha": "4" * 40}]},
            {"files": [{"filename": "README.md", "status": "modified"}]},
            {"files": self.commit_data["files"] + [{"filename": "start.sh", "status": "modified"}]},
            {"files": [{"filename": MODULE.CATALOG, "status": "renamed", "previous_filename": "other.json"}]},
        ]
        original = copy.deepcopy(self.commit_data)
        for change in cases:
            with self.subTest(change=change):
                self.commit_data = dict(original, **change)
                with self.assertRaises(MODULE.EvidenceError):
                    self.verify()

    def test_catalog_cannot_change_history_or_manifest(self):
        mutations = [
            lambda c: c.update(stable=False),
            lambda c: c["versions"]["2.0.11"].update(retained=False),
            lambda c: c["versions"].update({"2.0.13": {}}),
            lambda c: c["versions"]["2.0.12"].update(publishState="testing"),
            lambda c: c["versions"]["2.0.12"]["manifest"].update(upstreamVersion="other"),
            lambda c: c["versions"]["2.0.12"]["manifest"].update(changelog="unreviewed content"),
            lambda c: c["versions"]["2.0.12"]["manifest"].update(dockerImage="evil.invalid/image@sha256:" + "3" * 64),
        ]
        original = copy.deepcopy(self.after)
        for mutation in mutations:
            self.after = copy.deepcopy(original)
            mutation(self.after)
            with self.subTest(catalog=self.after), self.assertRaises(MODULE.EvidenceError):
                self.verify()

    def test_release_and_workflow_negatives(self):
        original = copy.deepcopy(self.run)
        for field, value in (("conclusion", "failure"), ("status", "in_progress"), ("event", "workflow_dispatch"),
                             ("head_sha", "4" * 40), ("head_branch", "other"), ("path", ".github/workflows/evil.yml"),
                             ("head_repository", {"full_name": "fork/package"}), ("repository", {"full_name": "other/repo"})):
            self.run = dict(original, **{field: value})
            with self.subTest(field=field), self.assertRaises(MODULE.EvidenceError):
                self.verify()
        self.run = original
        self.release["draft"] = True
        with self.assertRaises(MODULE.EvidenceError):
            self.verify()

    def test_attestation_certificate_negatives(self):
        for field in ("issuer", "sourceRepositoryURI", "sourceRepositoryDigest", "sourceRepositoryRef",
                      "buildConfigURI", "buildConfigDigest", "buildSignerURI", "buildSignerDigest",
                      "buildTrigger", "runInvocationURI"):
            self.attest_mutation = lambda result, image: result["signature"]["certificate"].update({field: "wrong"})
            with self.subTest(field=field), self.assertRaises(MODULE.EvidenceError):
                self.verify()

    def test_attestation_subject_and_invocation_negatives(self):
        mutations = [
            lambda v, image: v["statement"].update(subject=[]),
            lambda v, image: v["statement"]["subject"][0].update(name="other"),
            lambda v, image: v["statement"]["subject"][0].update(digest={"sha256": "4" * 64}),
            lambda v, image: v["statement"].update(predicateType="unverified"),
            lambda v, image: v["statement"]["predicate"]["runDetails"]["metadata"].update(invocationId="wrong"),
        ]
        for mutate in mutations:
            self.attest_mutation = mutate
            with self.subTest(mutation=mutate), self.assertRaises(MODULE.EvidenceError):
                self.verify()

    def test_different_successful_runs_do_not_combine(self):
        self.extra_runs = [dict(self.run, id=124)]
        def different_run(result, image):
            if image:
                invocation = self.proof.repository_url + "/actions/runs/124/attempts/1"
                result["signature"]["certificate"]["runInvocationURI"] = invocation
                result["statement"]["predicate"]["runDetails"]["metadata"]["invocationId"] = invocation
        self.attest_mutation = different_run
        with self.assertRaises(MODULE.EvidenceError):
            self.verify()

    def test_duplicate_json_and_api_failure(self):
        with self.assertRaises(MODULE.EvidenceError):
            MODULE.decode_json('{"stable":true,"stable":false}')
        with patch.object(MODULE, "gh", side_effect=MODULE.EvidenceError("API unavailable")), \
                self.assertRaises(MODULE.EvidenceError):
            self.proof.verify()


if __name__ == "__main__":
    unittest.main()
