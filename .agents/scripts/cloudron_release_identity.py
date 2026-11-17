#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fail-closed validation of signed Cloudron upstream release identity proofs."""

import re

COMMIT_VERSION = re.compile(r"[a-fA-F0-9]{7,40}")
FULL_COMMIT = re.compile(r"[a-f0-9]{40}")
UPSTREAM_REPO = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*")
IMAGE_DIGEST = re.compile(r"sha256:[a-f0-9]{64}")
ARG_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
ASSET_NAME = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*")
# Only the digest of a FROM image reference may change with a release.
FROM_DIGEST = re.compile(r"(?m)^(FROM[ \t]+(?:--[^ \t]+[ \t]+)*[^ \t@]+)@(sha256:[a-f0-9]{64})")
# Same shape as FROM_DIGEST, capturing the bare image reference and its digest.
FROM_REF = re.compile(r"(?m)^FROM[ \t]+(?:--[^ \t]+[ \t]+)*([^ \t@]+)@(sha256:[a-f0-9]{64})")
# Only these registries have an anonymous-token resolver in the approval helper.
REGISTRY_IMAGE = re.compile(r"(ghcr\.io|docker\.io)(/[a-z0-9][a-z0-9._-]*){2,4}")
CHECKSUM_FILE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.{}-]*")
SHA256_HEX = re.compile(r"[a-f0-9]{64}")
PIN_KEYS = {"upstream_repository", "release_identity", "registry_images", "release_checksum", "license_version_url", "companion_image", "catalog_baseline"}
POLICY_KEYS = {
    "schema", "kind", "repository", "changelog_files", "pinned_files", "check_files", "check_insertion_pattern",
    "upstream_mode", "upstream_repository", "release_identity", "registry_images", "release_checksum",
    "license_version_url", "companion_image", "catalog_baseline",
}


def substitute_versions(text, mapping):
    """Replace each whole old version token with its new value in one pass.

    Boundaries stop 0.20.3 matching inside 10.20.3 or 3.39.8 inside 3.39.87.
    """
    olds = sorted(mapping, key=len, reverse=True)
    alternatives = []
    for old in olds:
        if COMMIT_VERSION.fullmatch(old):
            alternatives.append(r"(?<![A-Za-z0-9_])" + re.escape(old) + r"(?![A-Za-z0-9_])")
        else:
            alternatives.append(r"(?<![0-9.])" + re.escape(old) + r"(?![0-9]|\.[0-9])")
    pattern = re.compile("|".join(alternatives))
    return pattern.sub(lambda match: mapping[match.group(0)], text)


def split_digests(text):
    body = FROM_DIGEST.sub(lambda match: match.group(1) + "@sha256:<digest>", text)
    return body, [match.group(2) for match in FROM_DIGEST.finditer(text)]


class NotRoutine(Exception):
    """The change is outside the standing policy; a per-release signature is required."""


def require(condition, reason):
    if not condition:
        raise NotRoutine(reason)


def normalize_image(ref):
    """Canonical registry/name of an image reference without its tag (docker.io default)."""
    name = ref.rsplit(":", 1)[0] if ":" in ref.rsplit("/", 1)[-1] else ref
    first = name.split("/", 1)[0]
    if "/" in name and ("." in first or ":" in first):
        return name
    return "docker.io/" + (name if "/" in name else "library/" + name)


def from_refs(text):
    return [(match.group(1), match.group(2)) for match in FROM_REF.finditer(text)]


def matches(pattern, value):
    return isinstance(value, str) and pattern.fullmatch(value) is not None


def check_registry_images(policy):
    images = policy.get("registry_images")
    if "registry_images" not in policy:
        return
    require(isinstance(images, list) and 0 < len(images) <= 20, "policy registry_images is invalid")
    require(all(matches(REGISTRY_IMAGE, item) for item in images), "policy registry_images is invalid")
    require(len(set(images)) == len(images), "policy registry_images is invalid")


def check_release_checksum(policy):
    checksum = policy.get("release_checksum")
    if "release_checksum" not in policy:
        return
    require(isinstance(checksum, dict) and set(checksum) == {"arg", "asset", "file"},
            "policy release_checksum is invalid")
    for key, pattern in (("arg", ARG_NAME), ("asset", ASSET_NAME), ("file", CHECKSUM_FILE)):
        require(matches(pattern, checksum[key]), "policy release_checksum is invalid")
    require("{version}" in checksum["file"], "policy release_checksum is invalid")
    require(policy.get("upstream_repository") is not None, "release_checksum needs a semver upstream repository")


def catalog_baseline_file(policy):
    """Validate the signed, disjoint repository-relative baseline path."""
    if "catalog_baseline" not in policy:
        return None
    spec = policy["catalog_baseline"]
    require(isinstance(spec, dict) and set(spec) == {"file"}, "catalog_baseline: invalid policy")
    path = spec["file"]
    require(isinstance(path, str) and re.fullmatch(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*", path)
            and ".." not in path.split("/"), "catalog_baseline: invalid path")
    reserved = {"CloudronManifest.json", "CloudronVersions.json"}
    for key in ("changelog_files", "pinned_files", "check_files"):
        reserved.update(policy.get(key, []))
    companion = policy.get("companion_image")
    if isinstance(companion, dict):
        reserved.update(("Dockerfile", companion.get("verify_file")))
    require(path not in reserved, "catalog_baseline: policy file classes overlap")
    return path


def validate_pin_fields(policy):
    """Fail closed on unknown keys and malformed opt-in pin fields of a signed policy."""
    require(isinstance(policy, dict) and set(policy) <= POLICY_KEYS, "policy contains an unknown field")
    require(policy.get("license_version_url", True) is True, "policy license_version_url is invalid")
    require("upstream_repository" not in policy or matches(UPSTREAM_REPO, policy["upstream_repository"]),
            "policy upstream_repository is invalid")
    check_registry_images(policy)
    check_release_checksum(policy)
    catalog_baseline_file(policy)
    if "companion_image" in policy:
        from cloudron_companion_image import validate_companion
        validate_companion(policy)


def validate_pins_request(policy):
    """Policy-request check for the pins mode: valid fields, at least one opt-in, optional identity shape."""
    validate_pin_fields(policy)
    require(set(policy) <= PIN_KEYS, "pins request may only set pin fields")
    # The helper merges pins into these fixed default file classes before signing.
    catalog_baseline_file(dict(changelog_files=["CHANGELOG", "CHANGELOG.md"],
                               pinned_files=["Dockerfile"], check_files=["test/package-test.sh"], **policy))
    require(any(key in policy for key in PIN_KEYS - {"upstream_repository"}), "pins policy needs at least one pin field")
    identity = policy.get("release_identity")
    if "release_identity" not in policy:
        return
    require(isinstance(identity, dict) and "commit_arg" in identity and set(identity) <= {"commit_arg", "images_json_asset"},
            "policy release_identity is invalid")
    require(matches(ARG_NAME, identity["commit_arg"]), "policy release_identity is invalid")
    require(matches(ASSET_NAME, identity["images_json_asset"]) if "images_json_asset" in identity
            else "registry_images" in policy, "policy release_identity is invalid")
    require("upstream_repository" in policy, "policy release_identity is invalid")


def registry_proof(proof):
    refs = proof.get("registry")
    require(isinstance(refs, dict), "registry_images digest proof is invalid")
    require(all(isinstance(key, str) and matches(IMAGE_DIGEST, value) for key, value in refs.items()),
            "registry_images digest proof is invalid")
    return refs


def checksum_proof(proof, policy):
    entry = proof.get("checksum")
    checksum = policy["release_checksum"]
    require(isinstance(entry, dict) and isinstance(entry.get("version"), str), "release_checksum proof mismatch")
    require(entry.get("repository") == policy["upstream_repository"] and entry.get("asset") == checksum["asset"],
            "release_checksum proof mismatch")
    require(entry.get("file") == checksum["file"].replace("{version}", entry["version"])
            and matches(SHA256_HEX, entry.get("sha256")), "release_checksum proof mismatch")
    return entry


def pin_policy(doc, policy):
    """Validate the opt-in registry, checksum and license-URL fields; return their proofs."""
    validate_pin_fields(policy)
    pins = {"registry": None, "checksum": None, "license": policy.get("license_version_url") is True,
            "refs": {}, "sha256": None}
    require(not pins["license"] or policy.get("upstream_mode", "semver") == "semver",
            "license_version_url needs a semver policy")
    if policy.get("registry_images") is None and policy.get("release_checksum") is None:
        return pins
    require(policy.get("upstream_mode", "semver") == "semver", "pin proofs need a semver policy")
    proof = doc.get("pin_proof")
    require(isinstance(proof, dict), "pin proof is missing")
    if policy.get("registry_images") is not None:
        pins["registry"], pins["refs"] = set(policy["registry_images"]), registry_proof(proof)
    if policy.get("release_checksum") is not None:
        entry = checksum_proof(proof, policy)
        pins.update(checksum=policy["release_checksum"], sha256=entry["sha256"], version=entry["version"])
    return pins


def release_identity(doc, policy):
    """Return the proven release identity, or None when the policy does not opt in."""
    identity = policy.get("release_identity")
    if identity is None:
        return None
    upstream = policy.get("upstream_repository")
    require(policy.get("upstream_mode", "semver") == "semver" and isinstance(upstream, str)
            and UPSTREAM_REPO.fullmatch(upstream) is not None, "release identity needs a semver upstream repository")
    # images_json_asset may be omitted only when registry digest proof covers the images.
    require(isinstance(identity, dict), "policy release_identity is invalid")
    allowed = [{"commit_arg", "images_json_asset"}] + ([{"commit_arg"}] if policy.get("registry_images") else [])
    require(set(identity) in allowed, "policy release_identity is invalid")
    for key, pattern in (("commit_arg", ARG_NAME), ("images_json_asset", ASSET_NAME)):
        require(key not in identity or matches(pattern, identity[key]), "policy release_identity is invalid")
    proof = doc.get("release_proof")
    require(isinstance(proof, dict), "release proof repository or asset mismatch")
    require(proof.get("repository") == upstream and proof.get("asset") == identity.get("images_json_asset"),
            "release proof repository or asset mismatch")
    old_commit, new_commit = proof.get("old_commit"), proof.get("new_commit")
    for value in (old_commit, new_commit):
        require(isinstance(value, str) and FULL_COMMIT.fullmatch(value) is not None,
                "release proof commits must be full SHAs")
    # aidevops:trust-boundary — only strict ancestry between the peeled release
    # commits proves the release progressed; tags and timestamps never do.
    require(old_commit != new_commit and proof.get("status") == "ahead" and proof.get("merge_base") == old_commit,
            "release commits must be strictly ahead")
    digests = proof.get("digests")
    require(isinstance(digests, list) and len(digests) <= 200, "release proof digests are invalid")
    # Digests come from the images asset when signed; otherwise the registry proves them.
    require(bool(digests) == ("images_json_asset" in identity), "release proof digests are invalid")
    require(all(matches(IMAGE_DIGEST, item) for item in digests), "release proof digests are invalid")
    return {"arg": identity["commit_arg"], "commits": {old_commit: new_commit}, "digests": set(digests)}
