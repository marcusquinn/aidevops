#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate non-version CloudronManifest.json fields of a routine upstream bump."""

import json

from cloudron_release_identity import require, substitute_versions

VERSION_KEYS = ("version", "upstreamVersion")


def canonical(value):
    """Type-exact comparison: Python treats True == 1 and 1 == 1.0."""
    return json.dumps(value, sort_keys=True, allow_nan=False)


def license_changes_ok(base_manifest, head_manifest, mappings):
    """upstreamLicense may differ only by the proven release-commit or version substitution."""
    base, head = base_manifest.get("upstreamLicense"), head_manifest.get("upstreamLicense")
    if canonical(base) == canonical(head):
        # Unchanged is fine, but an absent field is not the same as null.
        return ("upstreamLicense" in base_manifest) == ("upstreamLicense" in head_manifest)
    if not (isinstance(base, dict) and isinstance(head, dict)):
        return False
    url_base, url_head = base.get("url"), head.get("url")
    if not isinstance(url_base, str) or not isinstance(url_head, str):
        return False
    rest_base = {key: value for key, value in base.items() if key != "url"}
    rest_head = {key: value for key, value in head.items() if key != "url"}
    return canonical(rest_base) == canonical(rest_head) \
        and any(substitute_versions(url_base, candidate) == url_head for candidate in mappings)


def commit_license_mapping(doc, policy):
    """Signed commits-mode opt-in: only the proven full-SHA substitution.

    check_upstream has already proved doc["upstream_proof"] for commits mode.
    """
    if policy.get("license_commit_url") is not True:
        return None
    proof = doc["upstream_proof"]
    return {proof["base"]: proof["head"]}


def license_mappings_for(old_up, new_up, identity, pins, commit_license):
    """Substitutions a signed policy permits in upstreamLicense.url (empty: none)."""
    # Without a signed release identity, license_version_url or license_commit_url
    # the policy permits no manifest field change beyond the version keys.
    mappings = []
    if identity:
        mappings.append(identity["commits"])
    if pins["license"]:
        mappings.append({old_up: new_up})
        if identity:
            mappings.append({**identity["commits"], **{old_up: new_up}})
    if commit_license:
        mappings.append(commit_license)
    return mappings


def check_manifest_fields(base_manifest, head_manifest, identity, pins, commit_license=None):
    """Keep non-version fields fixed unless a signed proof permits the license URL."""
    old_up, new_up = base_manifest.get("upstreamVersion"), head_manifest.get("upstreamVersion")
    mappings = license_mappings_for(old_up, new_up, identity, pins, commit_license)
    exempt = VERSION_KEYS + (("upstreamLicense",) if mappings else ())
    unchanged = {key: value for key, value in base_manifest.items() if key not in exempt}
    require(canonical(unchanged) == canonical({key: value for key, value in head_manifest.items() if key not in exempt}),
            "manifest changes beyond version and upstreamVersion")
    require(not mappings or license_changes_ok(base_manifest, head_manifest, mappings),
            "manifest changes beyond version and upstreamVersion: upstreamLicense.url "
            "is outside the permitted substitution")
