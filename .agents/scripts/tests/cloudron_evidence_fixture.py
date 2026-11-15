# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline GitHub API and attestation responses for catalog evidence tests."""

import base64
import copy
import hashlib
import importlib.util
import json
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("catalog_evidence", Path(__file__).resolve().parents[1] / "cloudron-release-evidence.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class EvidenceGitHubFixture:
    def api_content(self, path, value):
        data = value.encode() if isinstance(value, str) else json.dumps(value).encode()
        return {"type": "file", "path": path, "encoding": "base64", "size": len(data),
                "content": base64.b64encode(data).decode()}

    def fake_gh(self, *args):
        if args[0] == "api":
            endpoint = args[1].removeprefix("repos/" + self.repo + "/")
            mapping = {
                "commits/" + self.commit: self.commit_data,
                "commits/" + self.parent + "?per_page=100": self.docs_commit,
                "compare/" + self.source + "..." + self.parent: self.comparison,
                "releases/tags/v2.0.12": self.release,
                "contents/CloudronVersions.json?ref=" + self.source: self.api_content(MODULE.CATALOG, self.before),
                "contents/CloudronVersions.json?ref=" + self.commit: self.api_content(MODULE.CATALOG, self.after),
                "contents/CloudronManifest.json?ref=" + self.source: self.api_content("CloudronManifest.json", self.manifest),
                "contents/CHANGELOG?ref=" + self.source: self.api_content("CHANGELOG", "[2.0.12]\n* Fix startup.\n\n[2.0.11]\n* Earlier.\n"),
                "contents/.github/workflows/publish.yml?ref=" + self.source: self.api_content(".github/workflows/publish.yml", self.workflow),
                "actions/workflows/publish.yml/runs?event=push&status=success&per_page=100": {"workflow_runs": [self.run, *self.extra_runs]},
            }
            mapping.update({"contents/" + path + "?ref=" + self.source: self.api_content(path, content)
                            for path, content in self.source_files.items()})
            return copy.deepcopy(mapping[endpoint])
        self.assertEqual(args[:2], ("attestation", "verify"))
        signer_workflow = MODULE.MANAGED_WORKFLOW if self.pin else self.repo + "/.github/workflows/publish.yml"
        self.assertEqual(args[3:], ("--repo", self.repo, "--signer-workflow", signer_workflow,
                                    "--source-ref", "refs/heads/main", "--source-digest", self.source,
                                    "--signer-digest", self.pin or self.source, "--format", "json"))
        image = args[2].startswith("oci://")
        name = "ghcr.io/" + self.repo if image else MODULE.CATALOG
        digest = "3" * 64 if image else hashlib.sha256(Path(args[2]).read_bytes()).hexdigest()
        invocation = self.proof.repository_url + "/actions/runs/123/attempts/1"
        cert = dict(issuer="https://token.actions.githubusercontent.com",
                    sourceRepositoryURI=self.proof.repository_url, sourceRepositoryDigest=self.source,
                    sourceRepositoryRef=MODULE.SOURCE_REF, buildConfigURI=self.proof.signer,
                     buildConfigDigest=self.source,
                     buildSignerURI="https://github.com/" + signer_workflow + "@" + (self.pin or MODULE.SOURCE_REF),
                     buildSignerDigest=self.pin or self.source, buildTrigger="push", runInvocationURI=invocation)
        verified = {"signature": {"certificate": cert}, "statement": {
            "predicateType": "https://slsa.dev/provenance/v1", "subject": [{"name": name, "digest": {"sha256": digest}}],
            "predicate": {"runDetails": {"metadata": {"invocationId": invocation}}}}}
        self.attest_mutation(verified, image)
        return [{"verificationResult": verified}]

    def sign_catalog_commit(self, verified=True):
        # REST shape of the Git Database API commit GitHub signs for the job token;
        # the publisher keeps the local message bytes, including the final newline.
        message = self.commit_data.get("commit", {}).get("message", "Publish catalog\n\nCloudron-Source: " + self.source)
        self.commit_data["commit"] = {
            "message": message + "\n",
            "author": {"name": "github-actions[bot]", "email": "41898282+github-actions[bot]@users.noreply.github.com"},
            "committer": {"name": "GitHub", "email": "noreply@github.com"},
            "verification": {"verified": verified, "reason": "valid" if verified else "unsigned",
                             "signature": "-----BEGIN PGP SIGNATURE-----\n" if verified else None,
                             "payload": "tree x\n" if verified else None},
        }
