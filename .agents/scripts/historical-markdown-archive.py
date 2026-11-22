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
import json
import os
import secrets
import shlex
import stat
import sys

from _historical_markdown_files import (
    check_source,
    compare_original,
    ensure_source_unchanged,
    paths_overlap,  # noqa: F401  (re-exported for callers and tests)
    read_regular_file,
    resolve_destination,
)
from _historical_markdown_manifest import (
    LINE_DEFINITION,
    MANIFEST_NAME,
    PART_RE,
    RECORD_KEYS,
    SCHEMA,
    ArchiveError,
    describe,
    parse_manifest,
    part_name,
    record_of,
    validate_label,
)

DEFAULT_MAX_LINES = 400
DEFAULT_LABEL = "source.md"
README_NAME = "README.md"
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


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


def publish(parent, name, files, snapshot):
    """Stage, verify against the source, then rename over a reserved name."""
    source = snapshot[0]
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
        ensure_source_unchanged(snapshot)
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
    publish(parent, name, files, (source, captured_stat, manifest["source"]))
    return manifest


def load_manifest(dir_fd):
    raw, _ = read_regular_file(MANIFEST_NAME, "manifest", dir_fd=dir_fd)
    return parse_manifest(raw)


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
        for key in RECORD_KEYS:
            if actual[key] != entry[key]:
                raise ArchiveError(f"part {entry['ordinal']} ({entry['path']}) {key} does not match the manifest")
        payload += data
    return bytes(payload)


def verify_dir_fd(dir_fd, original=None):
    manifest = load_manifest(dir_fd)
    payload = read_parts(dir_fd, manifest)
    if describe(payload) != record_of(manifest["source"]):
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
