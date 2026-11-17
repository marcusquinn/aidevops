#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Collect and validate signed companion-image proofs; never execute package code.

The shell caller resolves the tag with release_registry_digest. Collection reads
only signed GitHub repositories and registry objects; the pure predicate consumes
that trusted snapshot, just like the existing release/registry proofs.
Catalog checksum files deliberately remain non-routine (no append-only opt-in).
"""

import argparse
import base64
import hashlib
import json
import re
import subprocess
import sys

from cloudron_release_identity import (
    ARG_NAME, FULL_COMMIT, IMAGE_DIGEST, REGISTRY_IMAGE, UPSTREAM_REPO,
    NotRoutine, from_refs, matches, require,
)

PATH = re.compile(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*")
FIELDS = {"image", "source_repository", "source_branch", "tag_prefix", "platform",
          "pin_file", "pin_pattern", "floor_revisions", "verify_file", "verify_constants"}
VALUES = {"release_tag", "pin", "image_revision", "image_ref", "index_digest", "platform_digest"}


def validate_companion(policy):
    spec = policy.get("companion_image")
    require(isinstance(spec, dict) and set(spec) == FIELDS, "companion_image: invalid policy fields")
    require(policy.get("upstream_mode", "semver") == "semver"
            and matches(UPSTREAM_REPO, policy.get("upstream_repository")),
            "companion_image: needs a semver upstream repository")
    for key, pattern in (("image", REGISTRY_IMAGE), ("source_repository", UPSTREAM_REPO),
                         ("source_branch", PATH), ("tag_prefix", re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,100}")),
                         ("platform", re.compile(r"linux/(amd64|arm64)")), ("pin_file", PATH), ("verify_file", PATH)):
        require(matches(pattern, spec[key]) and ".." not in spec[key].split("/"),
                "companion_image: invalid " + key)
    require(spec["verify_file"] not in ("Dockerfile", "CloudronManifest.json")
            and spec["pin_file"] != "CloudronManifest.json", "companion_image: invalid file")
    floors = spec["floor_revisions"]
    require(isinstance(floors, list) and len(floors) <= 20
            and all(matches(FULL_COMMIT, item) for item in floors)
            and len(set(floors)) == len(floors), "companion_image: invalid floor revisions")
    constants = spec["verify_constants"]
    require(isinstance(constants, dict), "companion_image: invalid verify constants")
    require(all(matches(ARG_NAME, key) for key in constants), "companion_image: invalid verify constants")
    require(all(isinstance(value, str) for value in constants.values()), "companion_image: invalid verify constants")
    require(len(constants) == len(VALUES) and set(constants.values()) == VALUES,
            "companion_image: invalid verify constants")
    pattern = spec["pin_pattern"]
    require(isinstance(pattern, str) and pattern.startswith("^") and len(pattern) <= 500,
            "companion_image: invalid pin pattern")
    try:
        require(re.compile(pattern).groups == 1, "companion_image: pin pattern needs one capture")
    except re.error as error:
        raise NotRoutine("companion_image: invalid pin pattern") from error
    return spec


def image_pin(text, spec):
    refs = [(ref, digest) for ref, digest in from_refs(text) if ref.startswith(spec["image"] + ":")]
    require(len(refs) == 1, "companion_image: expected one pinned FROM")
    ref, digest = refs[0]
    prefix = spec["image"] + ":" + spec["tag_prefix"]
    require(ref.startswith(prefix) and re.fullmatch(r"[a-f0-9]{7}", ref[len(prefix):]) is not None,
            "companion_image: tag must be a seven-character commit")
    # Keep the platform option and all other FROM bytes outside the proof mask.
    require(re.search(r"(?m)^FROM[ \t]+--platform=" + re.escape(spec["platform"])
                      + r"[ \t]+" + re.escape(ref + "@" + digest) + r"(?:[ \t]|$)", text) is not None,
            "companion_image: FROM platform mismatch")
    return ref, digest, ref[len(prefix):]


def ancestor(comparison, base, label):
    require(isinstance(comparison, dict) and comparison.get("status") in ("ahead", "identical")
            and comparison.get("merge_base_commit", {}).get("sha") == base,
            "companion_image: " + label + " is not an ancestor")


def verified_attestation(results, spec, revision, digests):
    repository = "https://github.com/" + spec["source_repository"]
    source_ref = "refs/heads/" + spec["source_branch"]
    for result in results if isinstance(results, list) else []:
        verified = result.get("verificationResult", {})
        cert = verified.get("signature", {}).get("certificate", {})
        statement = verified.get("statement", {})
        signer = cert.get("buildSignerURI", "")
        workflow_prefix = repository + "/.github/workflows/"
        bindings = {"issuer": "https://token.actions.githubusercontent.com",
                    "sourceRepositoryURI": repository, "sourceRepositoryDigest": revision,
                    "sourceRepositoryRef": source_ref, "buildSignerDigest": revision}
        workflow = signer.removeprefix(workflow_prefix).removesuffix("@" + source_ref)
        signed_here = signer == workflow_prefix + workflow + "@" + source_ref \
            and re.fullmatch(r"[A-Za-z0-9_.-]+\.ya?ml", workflow) is not None
        subjects = statement.get("subject", [])
        bound_digest = any(subject.get("name") == spec["image"]
                           and subject.get("digest", {}).get("sha256") in digests for subject in subjects)
        if signed_here and all(cert.get(key) == value for key, value in bindings.items()) \
                and statement.get("predicateType") == "https://slsa.dev/provenance/v1" and bound_digest:
            return True
    return False


def companion_proof(doc, policy, contents, read_text, new_up):
    if "companion_image" not in policy:
        return None
    spec = validate_companion(policy)
    proof = doc.get("companion_proof")
    require(isinstance(proof, dict), "companion_image: proof missing")
    release = doc.get("release_proof")
    require(isinstance(release, dict) and release.get("repository") == policy["upstream_repository"],
            "companion_image: release repository mismatch")
    old_commit, new_commit = release.get("old_commit"), release.get("new_commit")
    require(matches(FULL_COMMIT, old_commit) and matches(FULL_COMMIT, new_commit),
            "companion_image: release commits must be full SHAs")
    require(old_commit != new_commit and release.get("status") == "ahead"
            and release.get("merge_base") == old_commit, "companion_image: releases must be strictly ahead")
    require(proof.get("release_tag") == "v" + new_up.lstrip("v")
            and proof.get("release_commit") == new_commit, "companion_image: release binding mismatch")
    pins = re.findall(spec["pin_pattern"], proof.get("pin_text", ""), re.MULTILINE)
    require(len(pins) == 1 and matches(FULL_COMMIT, pins[0]), "companion_image: expected exactly one upstream pin")
    old_ref, _, old_short = image_pin(read_text(contents, "Dockerfile", "base"), spec)
    ref, digest, short = image_pin(read_text(contents, "Dockerfile", "head"), spec)
    revision, old_revision = proof.get("image_revision"), proof.get("old_revision")
    require(matches(FULL_COMMIT, revision) and revision.startswith(short)
            and matches(FULL_COMMIT, old_revision) and old_revision.startswith(old_short),
            "companion_image: image revision mismatch")
    require(proof.get("source_repository") == spec["source_repository"], "companion_image: source repository mismatch")
    ancestor(proof.get("branch"), revision, "image on source branch")
    ancestors = proof.get("ancestors", {})
    for commit, label in [(pins[0], "release pin"), (old_revision, "old image")] + [(floor, "floor") for floor in spec["floor_revisions"]]:
        ancestor(ancestors.get(commit), commit, label)
    require(proof.get("index_digest") == digest, "companion_image: registry digest mismatch")
    platform_digest = proof.get("platform_digest")
    require(matches(IMAGE_DIGEST, platform_digest), "companion_image: invalid platform digest")
    require(proof.get("label_revision") == revision, "companion_image: config revision label mismatch")
    require(verified_attestation(proof.get("attestations"), spec, revision,
                                 {digest[7:], platform_digest[7:]}), "companion_image: missing verified attestation")
    values = dict(release_tag="v" + new_up.lstrip("v"), pin=pins[0], image_revision=revision,
                  image_ref=ref, index_digest=digest, platform_digest=platform_digest)
    verify_constants(contents, read_text, spec, values)
    return {"old_ref": old_ref, "ref": ref, "digest": digest, "spec": spec}


def verify_constants(contents, read_text, spec, values):
    texts = [read_text(contents, spec["verify_file"], side) for side in ("base", "head")]
    for name, key in spec["verify_constants"].items():
        pattern = re.compile(r'(?m)^readonly ' + re.escape(name) + r'="([^"\n\r]*)"$')
        found = [pattern.findall(text) for text in texts]
        require(all(len(items) == 1 for items in found) and found[1][0] == values[key],
                "companion_image: verify constant " + name + " mismatch")
        texts = [pattern.sub(lambda match: 'readonly ' + name + '="<proven>"', text) for text in texts]
    require(texts[0] == texts[1], "companion_image: extra verify_file edit (including floor constants)")


def mask_image(text, companion, side):
    if companion is None:
        return text
    ref, digest, _ = image_pin(text, companion["spec"])
    expected = companion["old_ref"] if side == "base" else companion["ref"]
    require(ref == expected, "companion_image: FROM binding mismatch")
    # Only mask the FROM reference, never occurrences in RUN, ARG or comments.
    pattern = re.compile(r"(?m)^(FROM[ \t]+--platform=" + re.escape(companion["spec"]["platform"])
                         + r"[ \t]+)" + re.escape(ref + "@" + digest))
    return pattern.sub(lambda match: match[1] + "companion:<proven>", text, count=1)


def run_json(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=60, check=False)
    require(result.returncode == 0, "companion_image: trusted source or signature verification failed")
    return json.loads(result.stdout)


def api(repository, endpoint):
    return run_json("gh", "api", "repos/" + repository + "/" + endpoint)


def registry_json(spec, token, kind, digest):
    require(matches(IMAGE_DIGEST, digest), "companion_image: invalid registry object digest")
    host, name = spec["image"].split("/", 1)
    registry = "registry-1.docker.io" if host == "docker.io" else host
    result = subprocess.run(["curl", "-fsSL", "--max-time", "30", "-H", "Authorization: Bearer " + token,
                             "-H", "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json",
                             "https://" + registry + "/v2/" + name + "/" + kind + "/" + digest],
                            capture_output=True, timeout=40, check=False)
    require(result.returncode == 0 and "sha256:" + hashlib.sha256(result.stdout).hexdigest() == digest,
            "companion_image: registry object digest mismatch")
    return json.loads(result.stdout)


def collect(doc, digest):
    spec = validate_companion(doc["policy"])
    from cloudron_routine_bump import file_text
    contents = doc["contents"]
    _, pinned_digest, short = image_pin(file_text(contents, "Dockerfile", "head"), spec)
    _, _, old_short = image_pin(file_text(contents, "Dockerfile", "base"), spec)
    require(digest == pinned_digest, "companion_image: registry digest mismatch")
    source = spec["source_repository"]
    revision = api(source, "commits/" + short)["sha"]
    old_revision = api(source, "commits/" + old_short)["sha"]
    require(matches(FULL_COMMIT, revision) and matches(FULL_COMMIT, old_revision), "companion_image: invalid resolved commit")
    release_commit = doc["release_proof"]["new_commit"]
    from urllib.parse import quote
    upstream_file = api(doc["policy"]["upstream_repository"], "contents/" + spec["pin_file"] + "?ref=" + release_commit)
    pin_text = base64.b64decode(upstream_file["content"]).decode("utf-8")
    pins = re.findall(spec["pin_pattern"], pin_text, re.MULTILINE)
    require(len(pins) == 1 and matches(FULL_COMMIT, pins[0]), "companion_image: expected exactly one upstream pin")
    branch = api(source, "git/ref/heads/" + quote(spec["source_branch"], safe=""))["object"]["sha"]
    require(matches(FULL_COMMIT, branch), "companion_image: invalid branch head")
    host, name = spec["image"].split("/", 1)
    token_url = ("https://ghcr.io/token?scope=repository:" + name + ":pull" if host == "ghcr.io" else
                 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:" + name + ":pull")
    token = run_json("curl", "-fsS", "--max-time", "30", token_url)["token"]
    index = registry_json(spec, token, "manifests", digest)
    os_name, arch = spec["platform"].split("/")
    manifests = [entry for entry in index.get("manifests", []) if entry.get("platform", {}).get("os") == os_name
                 and entry.get("platform", {}).get("architecture") == arch]
    require(len(manifests) == 1, "companion_image: expected one platform manifest")
    platform_digest = manifests[0]["digest"]
    manifest = registry_json(spec, token, "manifests", platform_digest)
    config = registry_json(spec, token, "blobs", manifest["config"]["digest"])
    attestations = []
    for candidate in dict.fromkeys((digest, platform_digest)):
        try:
            attestations = run_json("gh", "attestation", "verify", "oci://" + spec["image"] + "@" + candidate,
                                    "--repo", source, "--source-ref", "refs/heads/" + spec["source_branch"],
                                    "--source-digest", revision, "--format", "json")
        except NotRoutine:
            continue
        if verified_attestation(attestations, spec, revision, {candidate[7:]}):
            break
    require(verified_attestation(attestations, spec, revision, {digest[7:], platform_digest[7:]}),
            "companion_image: missing verified attestation")
    upstream_version = json.loads(file_text(contents, "CloudronManifest.json", "head"))["upstreamVersion"]
    return dict(release_tag="v" + upstream_version.lstrip("v"), release_commit=release_commit, pin_text=pin_text,
                source_repository=source, image_revision=revision, old_revision=old_revision,
                branch=api(source, "compare/" + revision + "..." + branch),
                ancestors={commit: api(source, "compare/" + commit + "..." + revision)
                           for commit in set(pins + spec["floor_revisions"] + [old_revision])},
                index_digest=digest, platform_digest=platform_digest,
                label_revision=config.get("config", {}).get("Labels", {}).get("org.opencontainers.image.revision"),
                attestations=attestations)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--digest")
    args = parser.parse_args()
    try:
        doc = json.load(sys.stdin)
        if args.digest:
            print(json.dumps(collect(doc, args.digest)))
        else:
            from cloudron_routine_bump import file_text
            spec = validate_companion(doc["policy"])
            ref, _, _ = image_pin(file_text(doc["contents"], "Dockerfile", "head"), spec)
            print(spec["image"] + "\t" + ref.rsplit(":", 1)[1])
    except (NotRoutine, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print("NOT_ROUTINE: companion_image proof collection failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
