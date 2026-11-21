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


def blob(value):
    """Reject truncated, non-regular or unverifiable Contents API responses."""
    if value is None:
        return b""
    if value.get("type") != "file" or value.get("encoding") != "base64":
        raise ValueError("not a complete regular file")
    data = base64.b64decode("".join(value["content"].split()), validate=True)
    digest = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
    if len(data) != value["size"] or digest != value["sha"]:
        raise ValueError("blob evidence mismatch")
    return data


def validate(path, template, evidence):
    head, base = blob(evidence["head"]), blob(evidence["base"])
    if path == "README.md":
        start, end = b"<!-- aidevops:badges:start -->", b"<!-- aidevops:badges:end -->"

        def outside(data, required):
            if data.count(start) == data.count(end) == 0 and not required:
                return data
            if data.count(start) != 1 or data.count(end) != 1:
                raise ValueError("ambiguous badge block")
            a, b = data.index(start), data.index(end)
            if b < a:
                raise ValueError("reversed badge block")
            return data[:a] + data[b + len(end):]

        head_outside = outside(head, True)
        base_outside = outside(base, False)
        if start not in base and end not in base:
            # Match inject_block's first-install whitespace exactly, without
            # stripping/normalising any existing README content.
            block = head[head.index(start):head.index(end) + len(end)]
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


if __name__ == "__main__":
    try:
        print(validate(sys.argv[1], sys.argv[2], json.load(sys.stdin)))
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(f"Routine content refused: {error}", file=sys.stderr)
        sys.exit(1)
