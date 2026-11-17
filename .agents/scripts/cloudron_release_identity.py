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
POLICY_KEYS = {
    "schema", "kind", "repository", "changelog_files", "pinned_files", "check_files", "check_insertion_pattern",
    "upstream_mode", "upstream_repository", "release_identity", "registry_images", "release_checksum",
    "license_version_url",
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


def validate_pin_fields(policy):
    """Fail closed on unknown keys and malformed opt-in pin fields of a signed policy."""
    require(isinstance(policy, dict) and set(policy) <= POLICY_KEYS, "policy contains an unknown field")
    require("license_version_url" not in policy or policy["license_version_url"] is True,
            "policy license_version_url is invalid")
    images = policy.get("registry_images")
    require(images is None or (isinstance(images, list) and 0 < len(images) <= 20 and len(set(images)) == len(images)
                               and all(isinstance(item, str) and REGISTRY_IMAGE.fullmatch(item) is not None
                                       for item in images)), "policy registry_images is invalid")
    checksum = policy.get("release_checksum")
    require(checksum is None or (
        isinstance(checksum, dict) and set(checksum) == {"arg", "asset", "file"}
        and isinstance(checksum["arg"], str) and ARG_NAME.fullmatch(checksum["arg"]) is not None
        and isinstance(checksum["asset"], str) and ASSET_NAME.fullmatch(checksum["asset"]) is not None
        and isinstance(checksum["file"], str) and CHECKSUM_FILE.fullmatch(checksum["file"]) is not None
        and "{version}" in checksum["file"]), "policy release_checksum is invalid")
    upstream = policy.get("upstream_repository")
    require(upstream is None or (isinstance(upstream, str) and UPSTREAM_REPO.fullmatch(upstream) is not None),
            "policy upstream_repository is invalid")
    require(checksum is None or upstream is not None, "release_checksum needs a semver upstream repository")


def validate_pins_request(policy):
    """Policy-request check for the pins mode: valid fields, at least one opt-in, optional identity shape."""
    validate_pin_fields(policy)
    require(set(policy) <= {"upstream_repository", "release_identity", "registry_images", "release_checksum",
                            "license_version_url"}, "pins request may only set pin fields")
    identity = policy.get("release_identity")
    require(identity is None or (isinstance(identity, dict) and "commit_arg" in identity
                                 and set(identity) <= {"commit_arg", "images_json_asset"}
                                 and ARG_NAME.fullmatch(str(identity["commit_arg"])) is not None
                                 and ASSET_NAME.fullmatch(str(identity.get("images_json_asset", "x"))) is not None
                                 and policy.get("upstream_repository") is not None),
            "policy release_identity is invalid")
    require(any(key in policy for key in ("registry_images", "release_checksum", "license_version_url", "release_identity")),
            "pins policy needs at least one pin field")


def pin_policy(doc, policy):
    """Validate the opt-in registry, checksum and license-URL fields; return their proofs."""
    validate_pin_fields(policy)
    pins = {"registry": None, "checksum": None, "license": False, "refs": {}, "sha256": None}
    images = policy.get("registry_images")
    checksum = policy.get("release_checksum")
    pins["license"] = policy.get("license_version_url") is True
    if images is None and checksum is None:
        return pins
    require(policy.get("upstream_mode", "semver") == "semver", "pin proofs need a semver policy")
    proof = doc.get("pin_proof")
    require(isinstance(proof, dict), "pin proof is missing")
    if images is not None:
        refs = proof.get("registry")
        require(isinstance(refs, dict) and all(
            isinstance(key, str) and isinstance(value, str) and IMAGE_DIGEST.fullmatch(value) is not None
            for key, value in refs.items()), "registry_images digest proof is invalid")
        pins["registry"], pins["refs"] = set(images), refs
    if checksum is not None:
        upstream = policy["upstream_repository"]
        entry = proof.get("checksum")
        require(isinstance(entry, dict) and entry.get("repository") == upstream and entry.get("asset") == checksum["asset"]
                and isinstance(entry.get("version"), str)
                and entry.get("file") == checksum["file"].replace("{version}", entry["version"])
                and isinstance(entry.get("sha256"), str) and SHA256_HEX.fullmatch(entry["sha256"]) is not None,
                "release_checksum proof mismatch")
        pins["checksum"], pins["sha256"], pins["version"] = checksum, entry["sha256"], entry["version"]
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
    keys = set(identity) if isinstance(identity, dict) else set()
    require(keys == {"commit_arg", "images_json_asset"}
            or (keys == {"commit_arg"} and policy.get("registry_images") is not None),
            "policy release_identity is invalid")
    for key, pattern in (("commit_arg", ARG_NAME), ("images_json_asset", ASSET_NAME)):
        require(key not in identity or (isinstance(identity[key], str) and pattern.fullmatch(identity[key]) is not None),
                "policy release_identity is invalid")
    proof = doc.get("release_proof")
    require(isinstance(proof, dict) and proof.get("repository") == upstream
            and proof.get("asset") == identity.get("images_json_asset"), "release proof repository or asset mismatch")
    old_commit, new_commit = proof.get("old_commit"), proof.get("new_commit")
    for value in (old_commit, new_commit):
        require(isinstance(value, str) and FULL_COMMIT.fullmatch(value) is not None,
                "release proof commits must be full SHAs")
    # aidevops:trust-boundary — only strict ancestry between the peeled release
    # commits proves the release progressed; tags and timestamps never do.
    require(old_commit != new_commit and proof.get("status") == "ahead" and proof.get("merge_base") == old_commit,
            "release commits must be strictly ahead")
    digests = proof.get("digests")
    if "images_json_asset" not in identity:
        require(digests == [], "release proof digests are invalid")
    require(isinstance(digests, list) and len(digests) <= 200 and (digests or "images_json_asset" not in identity) and all(
        isinstance(item, str) and IMAGE_DIGEST.fullmatch(item) is not None for item in digests),
        "release proof digests are invalid")
    return {"arg": identity["commit_arg"], "commits": {old_commit: new_commit}, "digests": set(digests)}
