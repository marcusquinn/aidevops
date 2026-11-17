#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate Cloudron pinned build inputs against signed upstream proofs."""

import re

from cloudron_release_identity import (
    from_refs, normalize_image, require, split_digests, substitute_versions,
)


def registry_pin_ok(old_ref, new_ref, digest, pins, mappings):
    """A changed digest needs a version-substituted tag the signed registry resolves to it."""
    old_image, _, old_tag = old_ref.rpartition(":")
    new_image, _, new_tag = new_ref.rpartition(":")
    # aidevops:trust-boundary — only the tag may change, and only by the upstream
    # version substitution; a changed repository path never inherits the proof.
    if old_image != new_image or old_tag == new_tag or pins["registry"] is None:
        return False
    if not any(substitute_versions(old_tag, candidate) == new_tag for candidate in mappings):
        return False
    return normalize_image(new_ref) in pins["registry"] and pins["refs"].get(new_ref) == digest


def registry_digests_ok(base_text, head_text, pins, published, mappings):
    base_refs, head_refs = from_refs(base_text), from_refs(head_text)
    if len(base_refs) != len(head_refs):
        return False
    for (old_ref, old_digest), (new_ref, new_digest) in zip(base_refs, head_refs):
        if old_digest != new_digest and new_digest not in published:
            require(registry_pin_ok(old_ref, new_ref, new_digest, pins, mappings),
                    "registry_images: FROM digest is not the registry digest of the new version tag")
    return True


def mask_checksum(base_body, head_body, pins):
    """Blank the signed checksum ARG after proving it equals the published release checksum."""
    if pins["checksum"] is None:
        return base_body, head_body
    arg = pins["checksum"]["arg"]
    pattern = re.compile(r"(?m)^(ARG[ \t]+" + re.escape(arg) + r"=)([a-f0-9]{64})[ \t]*$")
    base_sums, head_sums = pattern.findall(base_body), pattern.findall(head_body)
    require(len(base_sums) == 1 and len(head_sums) == 1, "release_checksum: ARG " + arg + " must appear once")
    require(head_sums[0][1] == pins["sha256"], "release_checksum: ARG " + arg + " is not the published release checksum")
    return (pattern.sub(lambda match: match.group(1) + "<sha256>", base_body),
            pattern.sub(lambda match: match.group(1) + "<sha256>", head_body))


def commit_arg_ok(head_body, identity):
    if identity is None:
        return True
    new_commit = next(iter(identity["commits"].values()))
    arg_line = r"(?m)^ARG[ \t]+" + re.escape(identity["arg"]) + "=" + new_commit + r"[ \t]*$"
    return re.search(arg_line, head_body) is not None


def pinned_changes_ok(base_text, head_text, mappings, identity, pins):
    if head_text == base_text:
        return False
    if identity is None and pins["registry"] is None and pins["checksum"] is None:
        return any(substitute_versions(base_text, candidate) == head_text for candidate in mappings)
    base_body, base_digests = split_digests(base_text)
    head_body, head_digests = split_digests(head_text)
    # aidevops:trust-boundary — a FROM digest may change only to a digest the
    # signed upstream release itself published or the signed registry resolves
    # for the version-substituted tag; any other change fails closed.
    published = identity["digests"] if identity else set()
    changed = any(old != new and new not in published for old, new in zip(base_digests, head_digests))
    digests_ok = len(base_digests) == len(head_digests) and (
        not changed or (pins["registry"] is not None and registry_digests_ok(base_text, head_text, pins, published, mappings)))
    base_body, head_body = mask_checksum(base_body, head_body, pins)
    return digests_ok and commit_arg_ok(head_body, identity) \
        and any(substitute_versions(base_body, candidate) == head_body for candidate in mappings)
