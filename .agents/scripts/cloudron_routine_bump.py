#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fail-closed predicate: is a Cloudron package PR a routine upstream bump?

A signed standing release policy (GH#37697) authorizes only this narrow change
class. The caller fetches every input; this module performs no I/O besides
stdin/stdout, so its decision is reproducible from the recorded document.

stdin JSON:
  policy            signed standing-policy object (schema 1)
  finding_upstream  X.Y.Z from the PR's trusted upstream monitor finding
  files             GitHub compare entries for main...<exact head>
  contents          {path: {base: base64, head: base64}} for the manifest and
                    every changed pinned or check file (merge-base and exact head)

Prints ROUTINE_BUMP and exits 0, or prints NOT_ROUTINE: <reason> and exits 1.
"""

import argparse
import base64
import binascii
import difflib
import json
import re
import sys

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


class NotRoutine(Exception):
    """The change is outside the standing policy; a per-release signature is required."""


def require(condition, reason):
    if not condition:
        raise NotRoutine(reason)


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


def substitute_versions(text, mapping):
    """Replace each whole old version token with its new value in one pass.

    Boundaries stop 0.20.3 matching inside 10.20.3 or 3.39.8 inside 3.39.87.
    """
    olds = sorted(mapping, key=len, reverse=True)
    pattern = re.compile(r"(?<![0-9.])(?:" + "|".join(re.escape(old) for old in olds) + r")(?![0-9]|\.[0-9])")
    return pattern.sub(lambda match: mapping[match.group(0)], text)


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
    expected = substitute_versions(base_text, mapping).splitlines()
    actual = head_text.splitlines()
    matcher = difflib.SequenceMatcher(None, expected, actual, autojunk=False)
    for tag, _, _, start, end in matcher.get_opcodes():
        if tag == "equal":
            continue
        # aidevops:trust-boundary — check files decide the preflight verdict;
        # removing or rewriting an existing line could weaken it.
        require(tag == "insert", name + ": check file changes beyond version substitution and insertions")
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
    new_up_tuple = version_tuple(new_up, UPSTREAM_VERSION, "head upstreamVersion")
    old_up_tuple = version_tuple(old_up, UPSTREAM_VERSION, "base upstreamVersion")
    require(new_up_tuple > old_up_tuple, "upstreamVersion must increase")
    require(new_up_tuple[0] == old_up_tuple[0], "a major upstream bump needs a per-release signature")
    finding = doc.get("finding_upstream")
    version_tuple(finding, PACKAGE_VERSION, "finding upstream version")
    require(new_up.lstrip("v") == finding, "upstreamVersion must equal the monitor finding")
    require(old_up != old_version, "package and upstream versions are ambiguous")
    unchanged = {key: value for key, value in base_manifest.items() if key not in VERSION_KEYS}
    require(canonical(unchanged) == canonical({key: value for key, value in head_manifest.items() if key not in VERSION_KEYS}),
            "manifest changes beyond version and upstreamVersion")

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
            # replacing the old package/upstream versions with the new ones.
            require(head_text != base_text and substitute_versions(base_text, mapping) == head_text,
                    name + ": pinned file changes beyond version substitution")
        elif name in checks:
            check_file_changes(name, file_text(contents, name, "base"), file_text(contents, name, "head"),
                               mapping, check_pattern)
    require(changelog_changed, "a changelog entry is required")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repository", required=True)
    args = parser.parse_args()
    try:
        check(decode_json(sys.stdin.read()), args.repository)
    except NotRoutine as error:
        print("NOT_ROUTINE: " + str(error))
        return 1
    print("ROUTINE_BUMP")
    return 0


if __name__ == "__main__":
    sys.exit(main())
