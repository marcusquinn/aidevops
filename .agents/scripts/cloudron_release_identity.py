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


def release_identity(doc, policy):
    """Return the proven release identity, or None when the policy does not opt in."""
    identity = policy.get("release_identity")
    if identity is None:
        return None
    upstream = policy.get("upstream_repository")
    require(policy.get("upstream_mode", "semver") == "semver" and isinstance(upstream, str)
            and UPSTREAM_REPO.fullmatch(upstream) is not None, "release identity needs a semver upstream repository")
    require(isinstance(identity, dict) and set(identity) == {"commit_arg", "images_json_asset"},
            "policy release_identity is invalid")
    for key, pattern in (("commit_arg", ARG_NAME), ("images_json_asset", ASSET_NAME)):
        require(isinstance(identity[key], str) and pattern.fullmatch(identity[key]) is not None,
                "policy release_identity is invalid")
    proof = doc.get("release_proof")
    require(isinstance(proof, dict) and proof.get("repository") == upstream
            and proof.get("asset") == identity["images_json_asset"], "release proof repository or asset mismatch")
    old_commit, new_commit = proof.get("old_commit"), proof.get("new_commit")
    for value in (old_commit, new_commit):
        require(isinstance(value, str) and FULL_COMMIT.fullmatch(value) is not None,
                "release proof commits must be full SHAs")
    # aidevops:trust-boundary — only strict ancestry between the peeled release
    # commits proves the release progressed; tags and timestamps never do.
    require(old_commit != new_commit and proof.get("status") == "ahead" and proof.get("merge_base") == old_commit,
            "release commits must be strictly ahead")
    digests = proof.get("digests")
    require(isinstance(digests, list) and 0 < len(digests) <= 200 and all(
        isinstance(item, str) and IMAGE_DIGEST.fullmatch(item) is not None for item in digests),
        "release proof digests are invalid")
    return {"arg": identity["commit_arg"], "commits": {old_commit: new_commit}, "digests": set(digests)}
