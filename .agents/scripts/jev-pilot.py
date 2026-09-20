#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Opt-in reversible retrieval and shadow triage. No workflow actions are executed."""

import argparse
import contextlib
import json
import os
import re
import subprocess
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import jev_pilot as pilot


def load_corpus(args):
    if not args.input:
        return pilot.sample_corpus(args.mode)
    with Path(args.input).open("rb") as stream:
        raw = stream.read(pilot.MAX_INPUT_BYTES + 1)
    if len(raw) > pilot.MAX_INPUT_BYTES:
        raise ValueError("Input exceeds byte budget")
    return pilot.validate_corpus(json.loads(raw), args.mode)


def scan_request(data):
    """A local pattern scan adds defence, not a guarantee against injection/PII."""
    scanner = Path(__file__).resolve().parent / "prompt-guard-helper.sh"
    try:
        # Only the bundled scanner is executed; corpus content is stdin, never code/argv.
        result = subprocess.run(
            ["/bin/bash", str(scanner), "scan-stdin"], input=json.dumps(pilot.make_request(data)),
            text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=15, check=False, shell=False)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def reject_checkout(directory_fd):
    try:
        os.stat(".git", dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    raise ValueError("Private reports cannot be stored in Git")


def open_component(parent_fd, name):
    try:
        os.mkdir(name, mode=0o700, dir_fd=parent_fd)
    except FileExistsError:
        pass
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)


@contextlib.contextmanager
def private_directory():
    if os.name != "posix":
        raise ValueError("Private report storage requires POSIX directory descriptors")
    root = Path.home() / ".aidevops" / ".agent-workspace" / "work" / "jev-pilots"
    directory_fd = os.open(root.anchor, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        reject_checkout(directory_fd)
        for name in root.parts[1:]:
            child_fd = open_component(directory_fd, name)
            os.close(directory_fd)
            directory_fd = child_fd
            reject_checkout(directory_fd)
        os.fchmod(directory_fd, 0o700)
        yield directory_fd, root
    finally:
        os.close(directory_fd)


def report_directory():
    with private_directory() as (_, root):
        return root


def save_report(report):
    name = uuid.uuid4().hex + ".json"
    with private_directory() as (directory_fd, root):
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=directory_fd)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(report, stream, indent=2, allow_nan=False)
            stream.write("\n")
    return str(root / name)


def execute(args):
    data = load_corpus(args)
    should_call = args.live and not args.unfiltered
    if should_call and args.input and not args.allow_public_data:
        raise ValueError("Custom live input requires --allow-public-data")
    # Check private storage before incurring cost; all output is local and owner-only.
    report_directory()
    if should_call and not scan_request(data):
        raise ValueError("Input scan unavailable or flagged; no provider request sent")
    key = os.environ.get(args.key_env) if should_call else None
    report = pilot.run(data, key, live=should_call, restore=args.unfiltered)
    path = save_report(report)
    needs_fallback = should_call and bool(report["selection"]["fallback_ids"])
    # Metrics, labels and source content stay out of terminal/session transcripts.
    print(json.dumps({"status": report["status"], "private_report": path,
                      "fallback_required": needs_fallback, "shadow_only": True}))
    return 2 if needs_fallback else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("retrieval", "triage"))
    parser.add_argument("--input", help="Bounded public non-personal JSON corpus; otherwise synthetic fixture")
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--allow-public-data", action="store_true", help="Explicitly approve uploading custom public data")
    parser.add_argument("--unfiltered", action="store_true", help="Restore all IDs in original order without network")
    parser.add_argument("--key-env", default="TYPESAFE_API_KEY")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"TYPESAFE_API_KEY(?:_[A-Z0-9_]+)?", args.key_env):
        parser.error("Use TYPESAFE_API_KEY or a suffixed account variable")
    try:
        return execute(args)
    except (OSError, ValueError, TypeError, RecursionError):
        print(json.dumps({"status": "blocked", "reason": "invalid_input_scan_or_private_storage"}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
