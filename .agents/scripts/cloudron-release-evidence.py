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
# The Cloudron CLI inlines changelog and text references (description,
# postInstallMessage) but keeps the binary icon reference unchanged; listings
# use iconUrl. These keys must therefore match the source manifest verbatim.
UNRESOLVED_FILE_REF_KEYS = frozenset({"changelog", "icon"})
MANAGED_WORKFLOW = "marcusquinn/aidevops/.github/workflows/cloudron-catalog-publish-reusable.yml"


def caller_scalar(value):
    """Accept only plain or simply quoted values from the managed template."""
    require(not value.startswith(("&", "*", "!", "{", "[")), "unsupported managed caller value")
    if value.startswith(("'", '"')):
        require(len(value) >= 2 and value[-1:] == value[:1], "invalid managed caller quoting")
        return value[1:-1]
    return value


def caller_mapping_lines(text):
    """Yield mapping entries, excluding comments and block-scalar contents."""
    block_indent = None
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if block_indent is not None and indent > block_indent:
            continue
        block_indent = None
        match = re.fullmatch(r" +([A-Za-z_][A-Za-z0-9_-]*):(?: +(.*))?", line)
        require(match is not None, "unsupported managed caller syntax; use the managed template")
        key, value = match.groups()
        value = (value or "").split(" #", 1)[0].strip()
        if value in ("|", "|-", "|+", ">", ">-", ">+"):
            block_indent = indent
        yield indent, key, value


def caller_jobs(text):
    """Read the template's mapping/block-scalar subset, never guess YAML."""
    jobs = re.findall(r"(?m)^jobs:\s*\n((?:[ \t]+[^\n]*\n|\s*\n|#[^\n]*\n)*)", text + "\n")
    require(len(jobs) == 1, "managed caller requires one canonical jobs mapping")
    root = {}
    stack = [(0, root)]
    for indent, key, value in caller_mapping_lines(jobs[0]):
        while stack[-1][0] >= indent:
            stack.pop()
        require(indent == stack[-1][0] + 2, "invalid managed caller indentation")
        parent = stack[-1][1]
        require(key not in parent, "duplicate managed caller key")
        if not value:
            parent[key] = {}
            stack.append((indent, parent[key]))
        else:
            parent[key] = caller_scalar(value)
    return root


def managed_caller(text, require_secret=False):
    """Bound the reusable signer to an unambiguous exact-source managed caller.

    Unsupported YAML fails closed. Standalone receipt verification keeps its
    existing signer policy; approval requests require the managed caller.
    """
    if MANAGED_WORKFLOW not in text:
        require(not require_secret, "release approval requires the managed catalog caller template")
        return None
    callers = [job for job in caller_jobs(text).values() if isinstance(job, dict)
               and isinstance(job.get("uses"), str) and job["uses"].startswith(MANAGED_WORKFLOW + "@")]
    require(len(callers) == 1, "expected exactly one managed catalog caller")
    caller = callers[0]
    pin = caller["uses"].removeprefix(MANAGED_WORKFLOW + "@")
    require(re.fullmatch(r"[0-9a-f]{40}", pin) is not None, "managed caller must pin a full commit")
    require(isinstance(caller.get("with"), dict) and caller["with"].get("aidevops_ref") == pin,
            "managed caller aidevops_ref must equal its uses pin")
    if require_secret:
        require(isinstance(caller.get("secrets"), dict)
                and caller["secrets"].get("CLOUDRON_RELEASE_PAT") == "${{ secrets.CLOUDRON_RELEASE_PAT }}",
                "managed caller must explicitly pass CLOUDRON_RELEASE_PAT from secrets.CLOUDRON_RELEASE_PAT")
    return pin


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


def resolve_file_refs(source_manifest, fetch):
    """Expand top-level text references the CLI inlines; changelog and icon stay verbatim."""
    expanded = {}
    for key, value in source_manifest.items():
        if key in UNRESOLVED_FILE_REF_KEYS or not isinstance(value, str) or not value.startswith("file://"):
            continue
        path = value[len("file://"):]
        # aidevops:trust-boundary — only repository-relative files at the source
        # commit may justify differences in the generated manifest.
        require(path and not path.startswith("/") and ".." not in path.split("/"),
                "file reference must be a non-empty repository-relative path")
        expanded[key] = fetch(path).decode("utf-8")
    return expanded


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
        image_match = re.fullmatch(
            r"(?P<repository>" + re.escape("ghcr.io/" + self.repo.lower())
            + r")(?:\:(?P<tag>[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}))?@sha256:(?P<digest>[0-9a-f]{64})",
            image,
        )
        require(image_match is not None,
                "image must be a digest in this repository's GHCR namespace")
        comparable = dict(manifest)
        del comparable["dockerImage"]
        comparable["changelog"] = source_manifest["changelog"]
        for key, expected in resolve_file_refs(source_manifest, lambda path: self.content(path, self.source)).items():
            require(key in manifest and manifest[key] == expected,
                    "published file reference differs from the source file")
            comparable[key] = source_manifest[key]
        require(comparable == source_manifest, "generated manifest changes source settings")
        changelog = self.content("CHANGELOG", self.source).decode("utf-8")
        section = re.search(r"(?m)^\[" + re.escape(self.version) + r"\]\s*\n(.*?)(?=^\[|\Z)", changelog, re.S)
        require(section is not None and manifest["changelog"].strip() == section[1].strip(),
                "published changelog differs from the source release section")
        return data, image, image_match["repository"], image_match["digest"]

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
                # Failed-job reruns retain artifacts from earlier successful jobs.
                accepted.update(self.repository_url + "/actions/runs/" + str(run_id) + "/attempts/" + str(number)
                                for number in range(1, attempt + 1))
        require(accepted, "no successful exact-source repository-owned workflow")
        return accepted

    def verified_invocations(self, artifact, name, digest, invocations):
        # aidevops:trust-boundary — consume only gh's cryptographically verified
        # results, never the unverified bundle alongside them or a plain checksum.
        signer_workflow = MANAGED_WORKFLOW if self.managed_pin else self.repo + "/" + self.workflow_path
        signer_digest = self.managed_pin or self.source
        signer_uri = "https://github.com/" + signer_workflow + "@" + (self.managed_pin or SOURCE_REF)
        results = gh("attestation", "verify", artifact, "--repo", self.repo,
                     "--signer-workflow", signer_workflow,
                     "--source-ref", SOURCE_REF, "--source-digest", self.source,
                     "--signer-digest", signer_digest, "--format", "json")
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
                "buildSignerURI": signer_uri,
                "buildSignerDigest": signer_digest,
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
        self.managed_pin = managed_caller(self.content(self.workflow_path, self.source).decode("utf-8"))
        self.generated_commit()
        release = self.api("releases/tags/" + self.tag)
        require(release["tag_name"] == self.tag and release["draft"] is False
                and release["prerelease"] is False, "expected a published stable release")
        data, image, image_name, image_digest = self.catalog()
        invocations = self.invocations()
        temporary_root = os.environ.get("AIDEVOPS_TEMP_DIR", str(Path.home() / ".aidevops/.agent-workspace/tmp"))
        with tempfile.TemporaryDirectory(prefix="catalog-evidence-", dir=temporary_root) as directory:
            catalog = Path(directory) / CATALOG
            catalog.write_bytes(data)
            file_runs = self.verified_invocations(str(catalog), CATALOG, hashlib.sha256(data).hexdigest(), invocations)
            image_runs = self.verified_invocations("oci://" + image, image_name, image_digest, invocations)
            # aidevops:trust-boundary — only validated invocation URIs may share a
            # successful run ID; the build and publish attempts can differ.
            file_run_ids = {uri.rsplit("/attempts/", 1)[0] for uri in file_runs}
            image_run_ids = {uri.rsplit("/attempts/", 1)[0] for uri in image_runs}
            require(file_run_ids & image_run_ids, "catalog and image were not attested by the same successful run")
        return True


def main():
    if sys.argv[1:] == ["--check-caller"]:
        try:
            managed_caller(sys.stdin.read(), require_secret=True)
        except EvidenceError as error:
            print("Cloudron caller preflight failed: " + str(error), file=sys.stderr)
            return 1
        return 0
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
