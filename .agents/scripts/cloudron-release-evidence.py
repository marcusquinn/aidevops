#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Read-only, fail-closed proof for a direct generated Cloudron catalog commit."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

CATALOG = "CloudronVersions.json"
SOURCE_REF = "refs/heads/main"


class EvidenceError(Exception):
    """An incomplete or inconsistent publication proof."""


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def decode_json(value):
    return json.loads(value, object_pairs_hook=unique_object)


def gh(*args):
    executable = shutil.which("gh")
    require(executable is not None, "GitHub CLI is unavailable")
    result = subprocess.run(  # nosec B603 -- fixed gh CLI, validated argv, never a shell
        [executable, *args], capture_output=True, timeout=60, check=False,
    )
    require(result.returncode == 0, "GitHub API or attestation verification failed")
    return decode_json(result.stdout)


class CatalogEvidence:
    def __init__(self, settings):
        repo, tag, source, commit, workflow, event = (
            settings[key] for key in ("repo", "tag", "source", "commit", "workflow", "event")
        )
        require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo)
                and all(part not in (".", "..") for part in repo.split("/")), "invalid repository")
        require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag), "invalid release tag")
        require(all(re.fullmatch(r"[0-9a-f]{40}", sha) for sha in (source, commit)), "invalid commit")
        require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.ya?ml", workflow), "exact workflow filename required")
        require(event in ("push", "workflow_dispatch"), "generated catalogs require push/dispatch evidence")
        self.repo, self.tag, self.source, self.commit = repo, tag, source, commit
        self.workflow, self.event = workflow, event
        self.version = tag[1:]
        self.repository_url = "https://github.com/" + repo
        self.workflow_path = ".github/workflows/" + workflow
        self.signer = self.repository_url + "/" + self.workflow_path + "@" + SOURCE_REF

    def api(self, suffix):
        return gh("api", "repos/" + self.repo + "/" + suffix)

    def content(self, path, commit):
        item = self.api("contents/" + path + "?ref=" + commit)
        require(item["type"] == "file" and item["path"] == path and item["encoding"] == "base64",
                "expected an ordinary source file")
        require(0 < item["size"] <= 1024 * 1024, "source file outside bounded size")
        data = base64.b64decode("".join(item["content"].split()), validate=True)
        require(len(data) == item["size"], "source file size mismatch")
        return data

    def generated_commit(self):
        commit = self.api("commits/" + self.commit)
        require(commit["sha"] == self.commit and len(commit["parents"]) == 1
                and commit["parents"][0]["sha"] == self.source, "tag must be a direct child of the merged source")
        files = commit["files"]
        require(len(files) == 1 and files[0]["filename"] == CATALOG
                and files[0]["status"] == "modified" and "previous_filename" not in files[0],
                "generated commit must modify only the existing catalog")

    def catalog(self):
        before = decode_json(self.content(CATALOG, self.source))
        data = self.content(CATALOG, self.commit)
        after = decode_json(data)
        entry = after["versions"][self.version]
        require(self.version not in before["versions"], "release version already exists in source catalog")
        remaining = dict(after, versions=dict(after["versions"]))
        del remaining["versions"][self.version]
        require(remaining == before and after["stable"] is True, "catalog must append exactly one stable entry")
        require(entry["publishState"] == "published", "catalog entry is not published")
        manifest = entry["manifest"]
        source_manifest = decode_json(self.content("CloudronManifest.json", self.source))
        require(source_manifest["version"] == self.version and source_manifest["changelog"] == "file://CHANGELOG",
                "source manifest version/changelog contract mismatch")
        image = manifest["dockerImage"]
        require(re.fullmatch(re.escape("ghcr.io/" + self.repo.lower() + "@sha256:") + r"[0-9a-f]{64}", image),
                "image must be a digest in this repository's GHCR namespace")
        comparable = dict(manifest)
        del comparable["dockerImage"]
        comparable["changelog"] = source_manifest["changelog"]
        require(comparable == source_manifest, "generated manifest changes source settings")
        changelog = self.content("CHANGELOG", self.source).decode("utf-8")
        section = re.search(r"(?m)^\[" + re.escape(self.version) + r"\]\s*\n(.*?)(?=^\[|\Z)", changelog, re.S)
        require(section is not None and manifest["changelog"].strip() == section[1].strip(),
                "published changelog differs from the source release section")
        return data, image

    def invocations(self):
        runs = self.api("actions/workflows/" + self.workflow
                        + "/runs?event=" + self.event + "&status=success&per_page=100")["workflow_runs"]
        accepted = set()
        expected = {"status": "completed", "conclusion": "success", "event": self.event,
                    "head_sha": self.source, "head_branch": "main", "path": self.workflow_path}
        for run in runs:
            same_repository = all(run.get(key, {}).get("full_name") == self.repo
                                  for key in ("repository", "head_repository"))
            if all(run.get(key) == value for key, value in expected.items()) and same_repository:
                run_id, attempt = run["id"], run["run_attempt"]
                require(type(run_id) is int and run_id > 0 and type(attempt) is int and attempt > 0,
                        "invalid workflow invocation identity")
                accepted.add(self.repository_url + "/actions/runs/" + str(run_id) + "/attempts/" + str(attempt))
        require(accepted, "no successful exact-source repository-owned workflow")
        return accepted

    def verified_invocations(self, artifact, name, digest, invocations):
        # aidevops:trust-boundary — consume only gh's cryptographically verified
        # results, never the unverified bundle alongside them or a plain checksum.
        results = gh("attestation", "verify", artifact, "--repo", self.repo,
                     "--signer-workflow", self.repo + "/" + self.workflow_path,
                     "--source-ref", SOURCE_REF, "--format", "json")
        accepted = set()
        for result in results:
            verified = result["verificationResult"]
            cert = verified["signature"]["certificate"]
            statement = verified["statement"]
            invocation = cert.get("runInvocationURI")
            expected = {
                "issuer": "https://token.actions.githubusercontent.com",
                "sourceRepositoryURI": self.repository_url,
                "sourceRepositoryDigest": self.source,
                "sourceRepositoryRef": SOURCE_REF,
                "buildConfigURI": self.signer,
                "buildConfigDigest": self.source,
                "buildSignerURI": self.signer,
                "buildSignerDigest": self.source,
                "buildTrigger": self.event,
            }
            bindings = (
                all(cert.get(key) == value for key, value in expected.items()),
                invocation in invocations,
                statement.get("predicateType") == "https://slsa.dev/provenance/v1",
                statement.get("subject") == [{"name": name, "digest": {"sha256": digest}}],
                statement["predicate"]["runDetails"]["metadata"]["invocationId"] == invocation,
            )
            if all(bindings):
                accepted.add(invocation)
        require(accepted, "attestation does not bind the artifact to the expected source/workflow/run")
        return accepted

    def verify(self):
        self.generated_commit()
        release = self.api("releases/tags/" + self.tag)
        require(release["tag_name"] == self.tag and release["draft"] is False
                and release["prerelease"] is False, "expected a published stable release")
        data, image = self.catalog()
        invocations = self.invocations()
        temporary_root = os.environ.get("AIDEVOPS_TEMP_DIR", str(Path.home() / ".aidevops/.agent-workspace/tmp"))
        with tempfile.TemporaryDirectory(prefix="catalog-evidence-", dir=temporary_root) as directory:
            catalog = Path(directory) / CATALOG
            catalog.write_bytes(data)
            file_runs = self.verified_invocations(str(catalog), CATALOG, hashlib.sha256(data).hexdigest(), invocations)
            image_runs = self.verified_invocations("oci://" + image, image.split("@")[0], image.split(":")[-1], invocations)
            require(file_runs & image_runs, "catalog and image were not attested by the same successful invocation")
        return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("repo", "tag", "source", "commit", "workflow", "event"):
        parser.add_argument("--" + option, required=True)
    args = parser.parse_args()
    try:
        CatalogEvidence(vars(args)).verify()
    except (EvidenceError, KeyError, TypeError, ValueError, AttributeError, OSError, subprocess.TimeoutExpired) as error:
        message = str(error) if isinstance(error, EvidenceError) else "malformed or unavailable evidence"
        print("Generated catalog verification failed: " + message, file=sys.stderr)
        return 1
    print("Verified direct catalog-only commit and exact-source image/catalog provenance")
    return 0


if __name__ == "__main__":
    sys.exit(main())
