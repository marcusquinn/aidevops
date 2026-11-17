#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fail-closed predicate: is a Cloudron package PR a routine upstream bump?

A signed standing release policy (GH#37697) authorizes only this narrow change
class. The caller fetches every input; this module performs no I/O besides
stdin/stdout, so its decision is reproducible from the recorded document.

stdin JSON:
  policy            signed standing-policy object (schema 1)
  finding_upstream  X.Y.Z or full SHA from the trusted upstream monitor finding
  upstream_proof    resolved base/head SHAs, repository, status and merge base
                    from the caller's upstream commit/compare API reads
  release_proof     semver policies with release_identity only: upstream repository,
                    peeled old/new release commits, compare status and the new
                     release's published image digests (images asset, optional)
  pin_proof         registry_images: {"<image>:<tag>": digest} resolved from the
                     registry; release_checksum: upstream repository, asset, file,
                     version and the sha256 listed for that file
  files             GitHub compare entries for main...<exact head>
  contents          {path: {base: base64, head: base64}} for the manifest and
                    every changed pinned or check file (merge-base and exact head)

Prints ROUTINE_BUMP and exits 0, or prints NOT_ROUTINE: <reason> and exits 1.

Tag-monitored packages (including Buzz) must pin strict X.Y.Z, not a main-build
suffix: a tag finding cannot prove which main build was packaged. Migrating an
existing X.Y.Z-main.<sha> pin to a tag requires one per-release signature; later
strict-tag bumps use the unchanged semver policy and its major/0.x boundaries.
"""

import argparse
import base64
import binascii
import difflib
import json
import re
import sys

from cloudron_release_identity import (
    COMMIT_VERSION, FULL_COMMIT, UPSTREAM_REPO, NotRoutine,
    from_refs, normalize_image, pin_policy, validate_pins_request,
    release_identity, require, split_digests, substitute_versions,
)

MANIFEST = "CloudronManifest.json"
POLICY_KIND = "cloudron-standing-upstream-release"
POLICY_FILE_CLASSES = ("changelog_files", "pinned_files", "check_files")
VERSION_KEYS = ("version", "upstreamVersion")
MAX_FILES = 20
MAX_PATTERN = 500
# Patterns are applied with fullmatch, so a trailing newline never qualifies.
PACKAGE_VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
UPSTREAM_VERSION = re.compile(r"v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
REPO_PATH = re.compile(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*")
# Characters Python treats as line breaks (or that hide content) but a shell
# reads as ordinary bytes; a check file containing any of them is not routine.
CHECK_FILE_HIDDEN = re.compile("[\x00\r\x0b\x0c\x1c-\x1e\x85\u2028\u2029]")
# An inserted line after one of these would join the previous command.
CONTINUATION = ("\\", "&&", "||", "|")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def decode_json(text):
    try:
        return json.loads(text, object_pairs_hook=unique_object)
    except (ValueError, RecursionError) as error:
        raise NotRoutine("malformed JSON") from error


def version_tuple(value, pattern, label):
    require(isinstance(value, str), label + " must be a string")
    match = pattern.fullmatch(value)
    require(match is not None, label + " must be X.Y.Z")
    return tuple(int(part) for part in match.groups())


def policy_paths(policy, key):
    values = policy.get(key)
    require(isinstance(values, list) and len(values) <= MAX_FILES, "policy " + key + " must be a short list")
    for value in values:
        # aidevops:trust-boundary — only plain repository-relative paths; the
        # manifest has its own fixed rule and can never join a looser class.
        require(isinstance(value, str) and REPO_PATH.fullmatch(value) is not None
                and ".." not in value.split("/") and value != MANIFEST,
                "policy " + key + " contains an invalid path")
    require(len(set(values)) == len(values), "policy " + key + " contains duplicates")
    return set(values)


def file_text(contents, path, side):
    entry = contents.get(path) if isinstance(contents, dict) else None
    require(isinstance(entry, dict) and isinstance(entry.get(side), str), path + ": missing " + side + " content")
    try:
        raw = base64.b64decode("".join(entry[side].split()), validate=True)
        return raw.decode("utf-8")
    except (binascii.Error, ValueError) as error:
        raise NotRoutine(path + ": undecodable " + side + " content") from error


def check_upstream(doc, policy, old_up, new_up):
    mode = policy.get("upstream_mode", "semver")
    require(mode in ("semver", "commits"), "unsupported upstream mode")
    finding = doc.get("finding_upstream")
    if mode == "commits":
        upstream = policy.get("upstream_repository")
        require(isinstance(upstream, str) and UPSTREAM_REPO.fullmatch(upstream) is not None,
                "commit policy needs an upstream repository")
        for value in (old_up, new_up):
            require(isinstance(value, str) and COMMIT_VERSION.fullmatch(value) is not None,
                    "commit upstreamVersion must be a SHA prefix of 7 to 40 characters")
        require(isinstance(finding, str) and FULL_COMMIT.fullmatch(finding) is not None,
                "commit finding must be a full SHA")
        require(finding.startswith(new_up.lower()), "upstreamVersion must equal the monitor finding")
        proof = doc.get("upstream_proof")
        require(isinstance(proof, dict) and proof.get("repository") == upstream,
                "upstream proof repository mismatch")
        base = proof.get("base")
        require(isinstance(base, str) and FULL_COMMIT.fullmatch(base) is not None
                and base.startswith(old_up.lower()) and proof.get("head") == finding,
                "upstream proof commit mismatch")
        # aidevops:trust-boundary — commits have no major-version boundary;
        # only strict ancestry, never timestamps or lexical SHA order, proves progress.
        require(base != finding and proof.get("status") == "ahead"
                and proof.get("merge_base") == base, "upstream commits must be strictly ahead")
        return
    new_tuple = version_tuple(new_up, UPSTREAM_VERSION, "head upstreamVersion")
    old_tuple = version_tuple(old_up, UPSTREAM_VERSION, "base upstreamVersion")
    require(new_tuple > old_tuple, "upstreamVersion must increase")
    require(new_tuple[0] == old_tuple[0], "a major upstream bump needs a per-release signature")
    require(old_tuple[0] > 0 or new_tuple[1] == old_tuple[1],
            "a 0.x minor upstream bump needs a per-release signature")
    version_tuple(finding, PACKAGE_VERSION, "finding upstream version")
    require(new_up.lstrip("v") == finding, "upstreamVersion must equal the monitor finding")


def registry_digests_ok(base_text, head_text, pins):
    """Each changed FROM digest needs a registry-resolved digest for its version-substituted tag."""
    base_refs, head_refs = from_refs(base_text), from_refs(head_text)
    if len(base_refs) != len(head_refs):
        return False
    changed = []
    for (old_ref, old_digest), (new_ref, new_digest) in zip(base_refs, head_refs):
        if old_digest != new_digest:
            changed.append((old_ref, new_ref, new_digest))
    return all(old_ref != new_ref and pins["registry"] is not None
               and normalize_image(new_ref) in pins["registry"] and pins["refs"].get(new_ref) == new_digest
               for old_ref, new_ref, new_digest in changed)


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
    if len(base_digests) != len(head_digests):
        return False
    published = identity["digests"] if identity else set()
    if any(old != new and new not in published for old, new in zip(base_digests, head_digests)):
        if pins["registry"] is None:
            return False
        require(registry_digests_ok(base_text, head_text, pins),
                "registry_images: FROM digest is not the registry digest of the new version tag")
    if pins["checksum"] is not None:
        arg_pattern = re.compile(r"(?m)^(ARG[ \t]+" + re.escape(pins["checksum"]["arg"]) + r"=)([a-f0-9]{64})[ \t]*$")
        base_sums, head_sums = arg_pattern.findall(base_body), arg_pattern.findall(head_body)
        require(len(base_sums) == 1 and len(head_sums) == 1 and head_sums[0][1] == pins["sha256"],
                "release_checksum: ARG " + pins["checksum"]["arg"] + " is not the published release checksum")
        base_body = arg_pattern.sub(lambda match: match.group(1) + "<sha256>", base_body)
        head_body = arg_pattern.sub(lambda match: match.group(1) + "<sha256>", head_body)
    if identity is not None:
        new_commit = next(iter(identity["commits"].values()))
        arg_line = r"(?m)^ARG[ \t]+" + re.escape(identity["arg"]) + "=" + new_commit + r"[ \t]*$"
        if re.search(arg_line, head_body) is None:
            return False
    return any(substitute_versions(base_body, candidate) == head_body for candidate in mappings)


def license_changes_ok(base_manifest, head_manifest, mappings):
    """upstreamLicense may differ only by the proven release-commit or version substitution."""
    base, head = base_manifest.get("upstreamLicense"), head_manifest.get("upstreamLicense")
    if not isinstance(base, dict) or not isinstance(head, dict):
        return canonical(base) == canonical(head)
    url_base, url_head = base.get("url"), head.get("url")
    if not isinstance(url_base, str) or not isinstance(url_head, str):
        return False
    rest_base = {key: value for key, value in base.items() if key != "url"}
    rest_head = {key: value for key, value in head.items() if key != "url"}
    return canonical(rest_base) == canonical(rest_head) \
        and any(substitute_versions(url_base, candidate) == url_head for candidate in mappings)


def insertion_pattern(policy):
    value = policy.get("check_insertion_pattern")
    if value is None:
        return None
    require(isinstance(value, str) and 0 < len(value) <= MAX_PATTERN, "policy check_insertion_pattern is invalid")
    try:
        return re.compile(value)
    except re.error as error:
        raise NotRoutine("policy check_insertion_pattern does not compile") from error


def check_file_changes(name, base_text, head_text, mapping, pattern):
    """Existing lines may change only by version substitution; new lines must
    fully match the signed insertion pattern (none are allowed without one)."""
    # aidevops:trust-boundary — compare physical lines exactly as a shell reads
    # them; str.splitlines() would hide a joined line behind a Unicode break.
    require(CHECK_FILE_HIDDEN.search(base_text) is None and CHECK_FILE_HIDDEN.search(head_text) is None,
            name + ": check file contains hidden line-break or control characters")
    require(head_text != base_text, name + ": check file is unchanged")
    expected = substitute_versions(base_text, mapping).split("\n")
    actual = head_text.split("\n")
    matcher = difflib.SequenceMatcher(None, expected, actual, autojunk=False)
    for tag, base_start, _, start, end in matcher.get_opcodes():
        if tag == "equal":
            continue
        # aidevops:trust-boundary — check files decide the preflight verdict;
        # removing or rewriting an existing line could weaken it.
        require(tag == "insert", name + ": check file changes beyond version substitution and insertions")
        require(base_start == 0 or not expected[base_start - 1].rstrip().endswith(CONTINUATION),
                name + ": insertion after a continued line")
        for line in actual[start:end]:
            require(pattern is not None and pattern.fullmatch(line) is not None,
                    name + ": inserted line does not match the signed insertion pattern")


def canonical(value):
    """Type-exact comparison: Python treats True == 1 and 1 == 1.0."""
    return json.dumps(value, sort_keys=True, allow_nan=False)


def check(doc, repository):
    require(isinstance(doc, dict), "input must be an object")
    policy = doc.get("policy")
    require(isinstance(policy, dict) and policy.get("schema") == 1 and policy.get("kind") == POLICY_KIND
            and policy.get("repository") == repository, "policy identity does not match this repository")
    classes = {key: policy_paths(policy, key) for key in POLICY_FILE_CLASSES}
    changelogs, pinned, checks = (classes[key] for key in POLICY_FILE_CLASSES)
    require(not (changelogs & pinned or changelogs & checks or pinned & checks), "policy file classes overlap")
    check_pattern = insertion_pattern(policy)

    files = doc.get("files")
    require(isinstance(files, list) and 0 < len(files) <= MAX_FILES, "changed file list is empty or too large")
    names = []
    for entry in files:
        require(isinstance(entry, dict) and isinstance(entry.get("filename"), str), "malformed changed file entry")
        name = entry["filename"]
        # aidevops:trust-boundary — added, removed, renamed or copied files can
        # introduce new build inputs; only in-place edits of named files qualify.
        require(entry.get("status") == "modified" and "previous_filename" not in entry,
                name + ": only in-place modifications qualify")
        require(name == MANIFEST or name in changelogs | pinned | checks, name + ": outside the standing policy")
        names.append(name)
    require(len(set(names)) == len(names), "duplicate changed file entries")
    require(MANIFEST in names, "the manifest must change")

    contents = doc.get("contents")
    base_manifest = decode_json(file_text(contents, MANIFEST, "base"))
    head_manifest = decode_json(file_text(contents, MANIFEST, "head"))
    require(isinstance(base_manifest, dict) and isinstance(head_manifest, dict), "manifest must be an object")
    old_version, new_version = base_manifest.get("version"), head_manifest.get("version")
    old_up, new_up = base_manifest.get("upstreamVersion"), head_manifest.get("upstreamVersion")
    old_tuple = version_tuple(old_version, PACKAGE_VERSION, "base package version")
    new_tuple = version_tuple(new_version, PACKAGE_VERSION, "head package version")
    require(new_tuple == (old_tuple[0], old_tuple[1], old_tuple[2] + 1), "package version must be a patch increment")
    check_upstream(doc, policy, old_up, new_up)
    pins = pin_policy(doc, policy)
    identity = release_identity(doc, policy)
    require(pins["checksum"] is None or pins["version"] == new_up.lstrip("v"),
            "release_checksum: proof is not for the new upstream version")
    require(old_up != old_version, "package and upstream versions are ambiguous")
    # Without a signed release identity or license_version_url the policy permits
    # no manifest field change beyond the version keys; with one, upstreamLicense
    # may also change by the proven release-commit and/or whole-token upstream
    # version substitution (checked separately).
    license_mappings = []
    if identity:
        license_mappings += [identity["commits"]]
    if pins["license"]:
        license_mappings += [{old_up: new_up}]
        if identity:
            license_mappings += [{**identity["commits"], **{old_up: new_up}}]
    exempt = VERSION_KEYS + (("upstreamLicense",) if license_mappings else ())
    unchanged = {key: value for key, value in base_manifest.items() if key not in exempt}
    require(canonical(unchanged) == canonical({key: value for key, value in head_manifest.items() if key not in exempt})
            and (not license_mappings or license_changes_ok(base_manifest, head_manifest, license_mappings)),
            "manifest changes beyond version and upstreamVersion")

    # Shipped build inputs may change only the upstream version; an equal
    # package-version token there could be an unrelated dependency pin.
    # Candidate mappings: the manifest version substitution, plus the proven
    # full-SHA substitution. When their source keys coincide both stay valid.
    pinned_mappings = [{old_up: new_up}]
    if policy.get("upstream_mode", "semver") == "commits":
        proof = doc["upstream_proof"]
        pinned_mappings = [{**{old_up: new_up}, **{proof["base"]: proof["head"]}},
                           {**{proof["base"]: proof["head"]}, **{old_up: new_up}}]
    if identity:
        pinned_mappings = [{**{old_up: new_up}, **identity["commits"]}, {**identity["commits"], **{old_up: new_up}}]
    mapping = {old_up: new_up, old_version: new_version}
    changelog_changed = False
    for entry in files:
        name = entry["filename"]
        if name in changelogs:
            additions, deletions = entry.get("additions"), entry.get("deletions")
            require(isinstance(additions, int) and isinstance(deletions, int) and additions > 0 and deletions == 0,
                    name + ": changelog edits must only add lines")
            changelog_changed = True
        elif name in pinned:
            base_text, head_text = file_text(contents, name, "base"), file_text(contents, name, "head")
            # aidevops:trust-boundary — shipped build inputs may change only by
            # replacing the old upstream version with the new one.
            require(pinned_changes_ok(base_text, head_text, pinned_mappings, identity, pins),
                    name + ": pinned file changes beyond version substitution")
        elif name in checks:
            check_file_changes(name, file_text(contents, name, "base"), file_text(contents, name, "head"),
                               mapping, check_pattern)
    require(changelog_changed, "a changelog entry is required")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repository", required=True)
    parser.add_argument("--validate-pins", action="store_true",
                        help="validate a pins-mode policy-request JSON object from stdin instead of a bump")
    args = parser.parse_args()
    try:
        if args.validate_pins:
            validate_pins_request(decode_json(sys.stdin.read()))
        else:
            check(decode_json(sys.stdin.read()), args.repository)
    except NotRoutine as error:
        print("NOT_ROUTINE: " + str(error))
        return 1
    print("ROUTINE_BUMP")
    return 0


if __name__ == "__main__":
    sys.exit(main())
