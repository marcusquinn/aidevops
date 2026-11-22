# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Manifest model and validation for historical-markdown-archive.py.

Standard library only. Validation reads parsed JSON values; it never resolves
manifest paths against the filesystem.
"""

import hashlib
import json
import os
import re

SCHEMA = "aidevops.historical-markdown-archive/v1"
MANIFEST_NAME = "manifest.json"
PART_RE = re.compile(r"^part-[0-9]{4,}\.md$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
LABEL_SEPARATOR_RE = re.compile(r"[\\/]")
LINE_DEFINITION = (
    "A line is a byte sequence terminated by LF (0x0A), plus one final "
    "unterminated sequence when non-empty data does not end in LF. "
    "lf_count is the LF byte count (the value `wc -l` reports). "
    "CR and all other bytes are payload, never delimiters."
)
RECORD_KEYS = ("bytes", "lines", "lf_count", "sha256")
TOP_KEYS = {"schema", "max_lines", "line_definition", "source", "parts"}
SOURCE_KEYS = {"label", *RECORD_KEYS}
PART_KEYS = {"ordinal", "path", "first_line", *RECORD_KEYS}


class ArchiveError(Exception):
    """A refused or failed archive/verify operation."""


def count_lines(data):
    """Return (lines, lf_count) under LINE_DEFINITION."""
    lf_count = data.count(b"\n")
    trailing = 1 if data and not data.endswith(b"\n") else 0
    return lf_count + trailing, lf_count


def describe(data):
    lines, lf_count = count_lines(data)
    return {"bytes": len(data), "lines": lines, "lf_count": lf_count,
            "sha256": hashlib.sha256(data).hexdigest()}


def record_of(value):
    """Return only the integrity fields of a source or part record."""
    return {key: value[key] for key in RECORD_KEYS}


def part_name(ordinal, total):
    width = max(4, len(str(total)))
    return f"part-{ordinal:0{width}d}.md"


def validate_label(label):
    message = "source label must be a plain, printable file name"
    if not isinstance(label, str):
        raise ArchiveError(message)
    if label in ("", ".", "..") or len(label) > 255:
        raise ArchiveError(message)
    if not label.isprintable() or LABEL_SEPARATOR_RE.search(label):
        raise ArchiveError(message)
    return label


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ArchiveError(f"manifest has duplicate key: {key}")
        result[key] = value
    return result


def require_keys(value, keys, what):
    if not isinstance(value, dict):
        raise ArchiveError(f"manifest {what} must be an object")
    if set(value) != keys:
        raise ArchiveError(f"manifest {what} keys must be exactly: {', '.join(sorted(keys))}")


def require_int(value, what, minimum=0):
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ArchiveError(f"manifest {what} must be an integer >= {minimum}")


def require_record(value, what):
    for key in ("bytes", "lines", "lf_count"):
        require_int(value[key], f"{what}.{key}")
    if not isinstance(value["sha256"], str) or not SHA256_RE.match(value["sha256"]):
        raise ArchiveError(f"manifest {what}.sha256 must be 64 lowercase hex characters")
    if value["lines"] - value["lf_count"] not in (0, 1):
        raise ArchiveError(f"manifest {what} line and LF counts are inconsistent")


def check_part_path(path, ordinal, total):
    """Accept only the expected flat part name; never a path to resolve."""
    if os.path.isabs(path) or path.startswith(("/", "\\")):
        raise ArchiveError(f"manifest part {ordinal} path must be relative: {path}")
    components = re.split(r"[\\/]", path)
    if ".." in components:
        raise ArchiveError(f"manifest part {ordinal} path traverses outside the archive: {path}")
    if len(components) != 1 or not PART_RE.match(path):
        raise ArchiveError(f"manifest part {ordinal} path must be a plain part file name: {path}")
    if path != part_name(ordinal, total):
        raise ArchiveError(f"manifest part {ordinal} path is out of order: {path}")


def check_part_identity(entry, index, seen):
    what = f"part #{index + 1}"
    require_keys(entry, PART_KEYS, what)
    require_int(entry["ordinal"], f"{what}.ordinal", 1)
    if not isinstance(entry["path"], str):
        raise ArchiveError(f"manifest {what} path must be a string")
    if entry["ordinal"] in seen["ordinals"] or entry["path"] in seen["paths"]:
        raise ArchiveError(f"manifest has a duplicate part: {entry['ordinal']} {entry['path']}")
    seen["ordinals"].add(entry["ordinal"])
    seen["paths"].add(entry["path"])
    if entry["ordinal"] != index + 1:
        raise ArchiveError(f"manifest parts are missing or reordered at position {index + 1}")


def check_part_shape(entry, manifest, next_line, is_last):
    what = f"part {entry['ordinal']}"
    require_record(entry, what)
    require_int(entry["first_line"], f"{what}.first_line", 1)
    if entry["first_line"] != next_line:
        raise ArchiveError(f"manifest {what} line range is not contiguous")
    if entry["lines"] > manifest["max_lines"]:
        raise ArchiveError(f"manifest {what} exceeds max_lines")
    empty_allowed = len(manifest["parts"]) == 1 and manifest["source"]["bytes"] == 0
    if entry["lines"] == 0 and not empty_allowed:
        raise ArchiveError(f"manifest {what} is empty")
    if not is_last and entry["lines"] != entry["lf_count"]:
        raise ArchiveError(f"manifest {what} must end at an LF boundary")


def check_part_entries(manifest):
    parts = manifest["parts"]
    if not isinstance(parts, list) or not parts:
        raise ArchiveError("manifest parts must be a non-empty list")
    seen, next_line = {"ordinals": set(), "paths": set()}, 1
    for index, entry in enumerate(parts):
        check_part_identity(entry, index, seen)
        check_part_path(entry["path"], entry["ordinal"], len(parts))
        check_part_shape(entry, manifest, next_line, index == len(parts) - 1)
        next_line += entry["lines"]
    for key in ("bytes", "lines", "lf_count"):
        if sum(entry[key] for entry in parts) != manifest["source"][key]:
            raise ArchiveError(f"manifest part {key} total does not match the source record")


def validate_manifest(manifest):
    if not isinstance(manifest, dict):
        raise ArchiveError("manifest must be a JSON object")
    if manifest.get("schema") != SCHEMA:
        raise ArchiveError(f"unsupported manifest schema: {manifest.get('schema')!r}")
    require_keys(manifest, TOP_KEYS, "top level")
    require_int(manifest["max_lines"], "max_lines", 1)
    if not isinstance(manifest["line_definition"], str):
        raise ArchiveError("manifest line_definition must be a string")
    require_keys(manifest["source"], SOURCE_KEYS, "source")
    try:
        validate_label(manifest["source"]["label"])
    except ArchiveError as exc:
        raise ArchiveError(f"manifest {exc}") from None
    require_record(manifest["source"], "source")
    check_part_entries(manifest)


def parse_manifest(raw):
    """Decode, parse and validate manifest bytes; return the manifest dict."""
    try:
        manifest = json.loads(raw.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
    except ValueError as exc:
        raise ArchiveError(f"manifest is not valid JSON: {exc}") from None
    validate_manifest(manifest)
    return manifest
