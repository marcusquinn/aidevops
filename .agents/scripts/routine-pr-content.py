#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Byte-exact content evidence for deterministic routine PR admission."""
import base64
import hashlib
import json
from pathlib import Path
import re
import sys

BADGE_START = b"<!-- aidevops:badges:start -->"
BADGE_END = b"<!-- aidevops:badges:end -->"


def blob(value):
    """Reject truncated, non-regular or unverifiable Contents API responses."""
    if value is None:
        return b""
    if value.get("type") != "file" or value.get("encoding") != "base64":
        raise ValueError("not a complete regular file")
    data = base64.b64decode("".join(value["content"].split()), validate=True)
    # Git object identity, not a password/signature or trust primitive. Live
    # GitHub permission, pinned tree evidence and byte equality provide admission.
    digest = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data,
                          usedforsecurity=False).hexdigest()
    if len(data) != value["size"] or digest != value["sha"]:
        raise ValueError("blob evidence mismatch")
    return data


def outside_badges(data, required):
    if data.count(BADGE_START) == data.count(BADGE_END) == 0 and not required:
        return data
    if data.count(BADGE_START) != 1 or data.count(BADGE_END) != 1:
        raise ValueError("ambiguous badge block")
    start, end = data.index(BADGE_START), data.index(BADGE_END)
    if end < start:
        raise ValueError("reversed badge block")
    return data[:start] + data[end + len(BADGE_END):]


def validate_readme(head, base):
    head_outside = outside_badges(head, True)
    base_outside = outside_badges(base, False)
    if BADGE_START not in base and BADGE_END not in base:
        # Match inject_block's first-install whitespace exactly, without
        # stripping/normalising any existing README content.
        block = head[head.index(BADGE_START):head.index(BADGE_END) + len(BADGE_END)]
        heading = re.search(rb"^# .*\n", base, re.M)
        if heading:
            offset = heading.end()
            expected = base[:offset] + b"\n" + block + b"\n" + base[offset:]
        else:
            expected = block + b"\n\n" + base
        if head != expected:
            raise ValueError("README differs from deterministic block insertion")
    elif head_outside != base_outside:
        raise ValueError("README changed outside badge block")
    return ""


def validate_workflow(head, template):
    # Reproduce the installer's two substitutions, including optional tag comment.
    match = re.search(rb"^      aidevops_ref: ([0-9a-f]{40})(?: # [^\r\n]+)?$", head, re.M)
    if not match:
        raise ValueError("workflow must pin a commit")
    ref_line = match.group(0).split(b": ", 1)[1]
    expected = Path(template).read_bytes()
    expected = re.sub(rb"^([ \t]*uses:.*loc-badge-reusable.yml)@[^\s]+.*$",
                      lambda m: m[1] + b"@" + ref_line, expected, flags=re.M)
    expected = re.sub(rb"^(      aidevops_ref:).*$",
                      lambda m: m[1] + b" " + ref_line, expected, flags=re.M)
    if head != expected:
        raise ValueError("workflow differs from canonical template")
    return match[1].decode()


def validate(path, template, evidence):
    head, base = blob(evidence["head"]), blob(evidence["base"])
    if path == "README.md":
        return validate_readme(head, base)
    return validate_workflow(head, template)


if __name__ == "__main__":
    try:
        print(validate(sys.argv[1], sys.argv[2], json.load(sys.stdin)))
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(f"Routine content refused: {error}", file=sys.stderr)
        sys.exit(1)
