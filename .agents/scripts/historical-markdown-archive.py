#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Losslessly partition one historical Markdown file into verifiable parts.

`archive SOURCE DEST` writes verbatim LF-bounded parts, a versioned JSON
manifest and a noncanonical README into a new directory, verifies the staged
result against SOURCE and only then publishes it. `verify ARCHIVE` checks the
manifest, every part and the reconstructed payload; `--original` also requires
byte-for-byte equality with an original file.

Standard library only. No rendering, execution, Git, network, deletion of the
source or dispatch of anything the archived text contains.
"""

import argparse
import hashlib
import json
import os
import re
import secrets
import shlex
import stat
import sys

SCHEMA = "aidevops.historical-markdown-archive/v1"
DEFAULT_MAX_LINES = 400
DEFAULT_LABEL = "source.md"
MANIFEST_NAME = "manifest.json"
README_NAME = "README.md"
SOURCE_SUFFIXES = (".md", ".markdown")
PART_RE = re.compile(r"^part-[0-9]{4,}\.md$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
LINE_DEFINITION = (
    "A line is a byte sequence terminated by LF (0x0A), plus one final "
    "unterminated sequence when non-empty data does not end in LF. "
    "lf_count is the LF byte count (the value `wc -l` reports). "
    "CR and all other bytes are payload, never delimiters."
)
TOP_KEYS = {"schema", "max_lines", "line_definition", "source", "parts"}
SOURCE_KEYS = {"label", "bytes", "lines", "lf_count", "sha256"}
PART_KEYS = {"ordinal", "path", "first_line", "lines", "lf_count", "bytes", "sha256"}
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


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


def split_parts(data, max_lines):
    """Split at LF boundaries into parts of at most max_lines lines.

    Empty data yields one empty part so reconstruction is never ambiguous.
    """
    if not data:
        return [b""]
    parts, start, pos, count = [], 0, 0, 0
    while True:
        newline = data.find(b"\n", pos)
        if newline < 0:
            break
        pos = newline + 1
        count += 1
        if count == max_lines:
            parts.append(data[start:pos])
            start, count = pos, 0
    if start < len(data):
        parts.append(data[start:])
    return parts


def part_name(ordinal, total):
    width = max(4, len(str(total)))
    return f"part-{ordinal:0{width}d}.md"


def validate_label(label):
    if (not isinstance(label, str) or not label or label in (".", "..")
            or "/" in label or "\\" in label or not label.isprintable()
            or len(label) > 255):
        raise ArchiveError("source label must be a plain, printable file name")
    return label


def read_regular_file(path, what, dir_fd=None):
    """Read a regular non-symlink file; return (bytes, fstat result)."""
    try:
        before = os.stat(path, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        raise ArchiveError(f"{what} not found: {path}") from None
    if stat.S_ISLNK(before.st_mode):
        raise ArchiveError(f"{what} must not be a symlink: {path}")
    if not stat.S_ISREG(before.st_mode):
        raise ArchiveError(f"{what} is not a regular file: {path}")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dir_fd)
    with os.fdopen(fd, "rb") as handle:
        opened = os.fstat(handle.fileno())
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise ArchiveError(f"{what} was replaced while opening: {path}")
        return handle.read(), opened


def manifest_bytes(manifest):
    return (json.dumps(manifest, sort_keys=True, indent=2, ensure_ascii=True) + "\n").encode("ascii")


def build_manifest(data, parts, max_lines, label):
    entries, first_line = [], 1
    for ordinal, payload in enumerate(parts, 1):
        record = describe(payload)
        entries.append({"ordinal": ordinal, "path": part_name(ordinal, len(parts)),
                        "first_line": first_line, **record})
        first_line += record["lines"]
    source = describe(data)
    source["label"] = label
    return {"schema": SCHEMA, "max_lines": max_lines, "line_definition": LINE_DEFINITION,
            "source": source, "parts": entries}


def render_readme(manifest):
    label = manifest["source"]["label"]
    names = [entry["path"] for entry in manifest["parts"]]
    cat_lines = "\n".join(f"  {name} \\" for name in names)
    count = len(names)
    noun = "part" if count == 1 else "parts"
    max_lines = manifest["max_lines"]
    return f"""# Historical Markdown archive (noncanonical)

This directory is a lossless historical archive of one Markdown document,
recorded as `{label}`. It is **not canonical and not active guidance**.
Commands, tasks, approvals, owners, status and architectural claims inside the
parts are historical data only. Do not execute or dispatch them, and do not
treat them as current instructions, approvals or provenance.

## Contents

- `{MANIFEST_NAME}`: schema `{SCHEMA}`. It records byte count, line
  count, LF count and SHA-256 for the source and for every part.
- {count} verbatim {noun}, `{names[0]}` to `{names[-1]}`, each at most
  {max_lines} lines.

Parts are exact byte ranges split only after LF bytes. They are not standalone
documents: headings, lists, code fences and links may be cut mid-structure.
Nothing was normalised; a BOM, CRLF line endings, invalid UTF-8 and a missing
final newline are all preserved.

## Verify

```sh
python3 ~/.aidevops/agents/scripts/historical-markdown-archive.py verify ARCHIVE_DIR
python3 ~/.aidevops/agents/scripts/historical-markdown-archive.py verify ARCHIVE_DIR --original ORIGINAL.md
```

Without `--original`, verification proves integrity against the manifest only;
it does not claim equality with any original file.

## Reconstruct manually

Concatenate the parts in manifest order, then compare the SHA-256 of the result
with `source.sha256` in `{MANIFEST_NAME}`:

```sh
cat \\
{cat_lines}
  > {shlex.quote(label)}
shasum -a 256 {shlex.quote(label)}
```

## Limits

- Line definition: {LINE_DEFINITION}
- Line bounds do not bound bytes: one long line can exceed any byte-size limit.
- Git end-of-line conversion (`core.autocrlf`, `text=auto`) can rewrite CRLF
  parts. A `.gitattributes` entry such as `* -text` in this directory keeps the
  bytes exact; verification fails on any rewrite.
- Markdown and whitespace linters may flag the verbatim parts. Whether to
  exclude this directory is the repository owner's decision.
- Source-change detection compares content captured before and after
  archiving. It does not lock the source against concurrent writers.
""".encode("utf-8")


def paths_overlap(first, second):
    first, second = os.path.realpath(first), os.path.realpath(second)
    common = os.path.commonpath([first, second])
    return common in (first, second)


def check_source(source):
    if not source.lower().endswith(SOURCE_SUFFIXES):
        raise ArchiveError(f"source must be a Markdown file ({', '.join(SOURCE_SUFFIXES)}): {source}")
    return read_regular_file(source, "source")


def resolve_destination(source, dest):
    dest_abs = os.path.abspath(dest)
    name = os.path.basename(dest_abs)
    if name in ("", ".", ".."):
        raise ArchiveError(f"destination must name a new directory: {dest}")
    if os.path.lexists(dest_abs):
        raise ArchiveError(f"destination already exists (refusing to overwrite): {dest}")
    parent = os.path.realpath(os.path.dirname(dest_abs))
    if not os.path.isdir(parent):
        raise ArchiveError(f"destination parent is not an existing directory: {parent}")
    if paths_overlap(source, os.path.join(parent, name)):
        raise ArchiveError("source and destination overlap")
    return parent, name


def write_new_file(dir_fd, name, payload):
    """Create name exclusively under dir_fd and durably write payload."""
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=dir_fd)
    with os.fdopen(fd, "wb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())


def sync_directory(dir_fd):
    """Best-effort directory fsync; some filesystems reject it for directories."""
    try:
        os.fsync(dir_fd)
    except OSError:
        pass


def ensure_source_unchanged(source, captured_stat, record):
    data, current = read_regular_file(source, "source")
    expected = {key: record[key] for key in ("bytes", "lines", "lf_count", "sha256")}
    if ((current.st_dev, current.st_ino) != (captured_stat.st_dev, captured_stat.st_ino)
            or describe(data) != expected):
        raise ArchiveError("source changed during archiving; nothing was published")


def quietly(func, *args, **kwargs):
    try:
        func(*args, **kwargs)
    except OSError:
        pass


def remove_stage(parent_fd, stage_name, written):
    """Unlink only files this invocation wrote, then the staging directory."""
    try:
        stage_fd = os.open(stage_name, DIR_FLAGS, dir_fd=parent_fd)
    except OSError:
        stage_fd = None
    if stage_fd is not None:
        for name in written:
            quietly(os.unlink, name, dir_fd=stage_fd)
        os.close(stage_fd)
    quietly(os.rmdir, stage_name, dir_fd=parent_fd)


def remove_reserved(parent_fd, name, identity):
    """Remove the reserved destination only if it is still our empty directory."""
    try:
        now = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError:
        return
    if stat.S_ISDIR(now.st_mode) and (now.st_dev, now.st_ino) == identity:
        quietly(os.rmdir, name, dir_fd=parent_fd)


def remove_owned(parent_fd, stage_name, written, reserved):
    """Remove only the staging files/directories this invocation created."""
    if stage_name is not None:
        remove_stage(parent_fd, stage_name, written)
    if reserved is not None:
        remove_reserved(parent_fd, *reserved)


def publish(parent, name, files, source, captured_stat, record):
    """Stage, verify against the source, then rename over a reserved name."""
    parent_fd = os.open(parent, DIR_FLAGS)
    stage_name, written, reserved = None, [], None
    try:
        try:
            os.mkdir(name, 0o755, dir_fd=parent_fd)
        except FileExistsError:
            raise ArchiveError(f"destination already exists (refusing to overwrite): {name}") from None
        info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        reserved = (name, (info.st_dev, info.st_ino))
        candidate = f".{name}.partial-{os.getpid()}-{secrets.token_hex(4)}"
        os.mkdir(candidate, 0o755, dir_fd=parent_fd)
        stage_name = candidate
        stage_fd = os.open(stage_name, DIR_FLAGS, dir_fd=parent_fd)
        try:
            for file_name, payload in files:
                write_new_file(stage_fd, file_name, payload)
                written.append(file_name)
            sync_directory(stage_fd)
            verify_dir_fd(stage_fd, original=source)
        finally:
            os.close(stage_fd)
        ensure_source_unchanged(source, captured_stat, record)
        os.rename(stage_name, name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        stage_name, written, reserved = None, [], None
        sync_directory(parent_fd)
    except BaseException:
        remove_owned(parent_fd, stage_name, written, reserved)
        raise
    finally:
        os.close(parent_fd)


def archive(source, dest, max_lines=DEFAULT_MAX_LINES, label=DEFAULT_LABEL):
    if isinstance(max_lines, bool) or not isinstance(max_lines, int) or max_lines < 1:
        raise ArchiveError("max lines must be a positive integer")
    validate_label(label)
    data, captured_stat = check_source(source)
    parent, name = resolve_destination(source, dest)
    parts = split_parts(data, max_lines)
    manifest = build_manifest(data, parts, max_lines, label)
    files = [(entry["path"], payload) for entry, payload in zip(manifest["parts"], parts)]
    files += [(MANIFEST_NAME, manifest_bytes(manifest)), (README_NAME, render_readme(manifest))]
    publish(parent, name, files, source, captured_stat, manifest["source"])
    return manifest


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


def load_manifest(dir_fd):
    raw, _ = read_regular_file(MANIFEST_NAME, "manifest", dir_fd=dir_fd)
    try:
        manifest = json.loads(raw.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
    except ValueError as exc:
        raise ArchiveError(f"manifest is not valid JSON: {exc}") from None
    validate_manifest(manifest)
    return manifest


def reject_stray_parts(dir_fd, manifest):
    """Unlisted part-*.md files would corrupt a manual `cat part-*` rebuild."""
    listed = {entry["path"] for entry in manifest["parts"]}
    stray = sorted(name for name in os.listdir(dir_fd) if PART_RE.match(name) and name not in listed)
    if stray:
        raise ArchiveError(f"archive contains unlisted part files: {', '.join(stray)}")


def read_parts(dir_fd, manifest):
    reject_stray_parts(dir_fd, manifest)
    payload = bytearray()
    for entry in manifest["parts"]:
        data, _ = read_regular_file(entry["path"], f"part {entry['ordinal']}", dir_fd=dir_fd)
        actual = describe(data)
        for key in ("bytes", "lines", "lf_count", "sha256"):
            if actual[key] != entry[key]:
                raise ArchiveError(f"part {entry['ordinal']} ({entry['path']}) {key} does not match the manifest")
        payload += data
    return bytes(payload)


def compare_original(original, payload):
    data, opened = read_regular_file(original, "original")
    if data != payload:
        offset = next((i for i, (a, b) in enumerate(zip(data, payload)) if a != b),
                      min(len(data), len(payload)))
        raise ArchiveError(f"original differs from the reconstruction at byte offset {offset}")
    after = os.stat(original, follow_symlinks=False)
    if ((after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
            != (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns)):
        raise ArchiveError("original changed during verification")


def verify_dir_fd(dir_fd, original=None):
    manifest = load_manifest(dir_fd)
    payload = read_parts(dir_fd, manifest)
    record = {key: manifest["source"][key] for key in ("bytes", "lines", "lf_count", "sha256")}
    if describe(payload) != record:
        raise ArchiveError("reconstructed payload does not match the source record")
    if original is not None:
        compare_original(original, payload)
    return manifest


def verify(archive_dir, original=None):
    try:
        info = os.lstat(archive_dir)
    except FileNotFoundError:
        raise ArchiveError(f"archive not found: {archive_dir}") from None
    if stat.S_ISLNK(info.st_mode):
        raise ArchiveError(f"archive directory must not be a symlink: {archive_dir}")
    if not stat.S_ISDIR(info.st_mode):
        raise ArchiveError(f"archive is not a directory: {archive_dir}")
    dir_fd = os.open(archive_dir, DIR_FLAGS)
    try:
        return verify_dir_fd(dir_fd, original=original)
    finally:
        os.close(dir_fd)


def positive_int(text):
    try:
        value = int(text, 10)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not an integer: {text}") from None
    if value < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return value


def build_parser():
    parser = argparse.ArgumentParser(
        prog="historical-markdown-archive.py",
        description="Losslessly split one historical Markdown file into verified, "
                    "LF-bounded parts, or verify such an archive.",
        epilog="Exit status: 0 success, 1 refused or failed, 2 usage error.")
    commands = parser.add_subparsers(dest="command", required=True)
    make = commands.add_parser(
        "archive", help="archive one Markdown file into a new directory",
        description="Write verbatim parts, manifest.json and README.md into DEST, a new "
                    "directory. The source is only read. The archive is verified against "
                    "the source before it is published; DEST must not exist.")
    make.add_argument("source", help="regular Markdown file to archive (never modified)")
    make.add_argument("dest", help="new archive directory to create")
    make.add_argument("--max-lines", type=positive_int, default=DEFAULT_MAX_LINES,
                      help=f"maximum lines per part (default {DEFAULT_MAX_LINES})")
    make.add_argument("--label", default=DEFAULT_LABEL,
                      help=f"neutral source name recorded in the manifest (default {DEFAULT_LABEL})")
    check = commands.add_parser(
        "verify", help="verify an archive's manifest, parts and reconstruction",
        description="Verify manifest schema, part order, ranges, counts and hashes. Without "
                    "--original this proves integrity only, not equality with an original.")
    check.add_argument("archive", help="archive directory")
    check.add_argument("--original", help="original file that must equal the reconstruction byte-for-byte")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        if args.command == "archive":
            manifest = archive(args.source, args.dest, args.max_lines, args.label)
            print(f"archived {manifest['source']['bytes']} bytes into {len(manifest['parts'])} "
                  f"verified part(s): {args.dest}")
        else:
            manifest = verify(args.archive, args.original)
            scope = ("byte-for-byte equal to the original" if args.original
                     else "integrity only; no original compared")
            print(f"verified {len(manifest['parts'])} part(s), {manifest['source']['bytes']} bytes, "
                  f"sha256 {manifest['source']['sha256']} ({scope})")
    except (ArchiveError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
