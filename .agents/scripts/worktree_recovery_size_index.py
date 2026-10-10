#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Advisory allocated-byte index; never evidence authorizing archive deletion."""

import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time

PREFIX = "aidevops-worktree-cleanup-"
SCHEMA = "aidevops.worktree-recovery-size/v1"
# Fixed system locations only: PATH must not select the sizing executable.
DU_CANDIDATES = ("/usr/bin/du", "/bin/du", "/run/current-system/sw/bin/du")


def du_executable():
    for candidate in DU_CANDIDATES:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise FileNotFoundError("du not found in trusted system locations")


def identity(path):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode):
        raise ValueError("not an ordinary directory")
    return [info.st_dev, info.st_ino]


def index_directory(root):
    identity(root)
    directory = root / ".size-index"
    directory.mkdir(mode=0o700, exist_ok=True)
    identity(directory)
    return directory


def read_hint(bucket, directory):
    try:
        record = directory / (bucket.name + ".json")
        if not stat.S_ISREG(record.lstat().st_mode):
            raise ValueError("not an ordinary index record")
        data = json.loads(record.read_text(encoding="utf-8"))
        if data.get("schema") != SCHEMA or data.get("identity") != identity(bucket):
            return None
        size = data.get("bytes")
        if type(size) is not int or size < 0:
            return None
        measured_at = data.get("measured_at")
        if type(measured_at) not in (int, float):
            return None
        if 0 <= time.time() - measured_at < 86400:
            return data
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    return None


def record_size(bucket, directory, timeout, measured_bytes=None):
    before = identity(bucket)
    size = measured_bytes
    if size is None:
        result = subprocess.run(  # nosec B603 -- absolute executable and fixed argv
            [du_executable(), "-sk", str(bucket)], capture_output=True, text=True,
            timeout=max(0.01, timeout), check=True,
        )
        size = int(result.stdout.split()[0]) * 1024
    if identity(bucket) != before or size < 0:
        raise ValueError("bucket changed during sizing")
    descriptor, temporary = tempfile.mkstemp(prefix=".size-", dir=directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump({"schema": SCHEMA, "identity": before, "bytes": size,
                       "measured_at": time.time()}, output)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, directory / (bucket.name + ".json"))
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def read_cursor(directory, bucket_count):
    cursor_path = directory / ".backfill-cursor"
    try:
        if not stat.S_ISREG(cursor_path.lstat().st_mode):
            raise ValueError("invalid cursor")
        return int(cursor_path.read_text()) % max(1, bucket_count)
    except (OSError, ValueError):
        return 0


def write_cursor(directory, next_offset):
    descriptor, temporary = tempfile.mkstemp(prefix=".cursor-", dir=directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(str(next_offset))
        os.replace(temporary, directory / ".backfill-cursor")
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def backfill(directory, buckets, hints, budget):
    # Rotate attempts, including timeouts, so a slow miss cannot starve later ones.
    deadline = time.monotonic() + budget
    offset = read_cursor(directory, len(buckets))
    pending = buckets[offset:] + buckets[:offset]
    for position, bucket in enumerate(pending):
        hint = hints[bucket]
        if hint and time.time() - hint["measured_at"] < 86400:
            continue
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        # Reserve progress before du: the outer deadline may kill this process,
        # so an end-of-pass-only cursor would retry the same slow bucket forever.
        next_offset = (offset + position + 1) % max(1, len(buckets))
        write_cursor(directory, next_offset)
        try:
            record_size(bucket, directory, min(remaining, 2))
            hints[bucket] = read_hint(bucket, directory)
        except (OSError, ValueError, subprocess.SubprocessError):
            continue


def snapshot(root, budget):
    directory = index_directory(root)
    buckets = sorted(path for path in root.iterdir() if path.name.startswith(PREFIX))
    hints = {path: read_hint(path, directory) for path in buckets}
    backfill(directory, buckets, hints, budget)
    known = [hint["bytes"] for hint in hints.values() if hint]
    # Interrupted transactions are still on disk but outside the bucket census.
    trash = root / ".retention-trash"
    staged = os.path.lexists(trash) and (
        trash.is_symlink() or not trash.is_dir() or any(trash.iterdir()))
    return {"store_bytes": sum(known) if len(known) == len(buckets) and not staged else None,
            "indexed_bytes": sum(known), "indexed_count": len(known),
            "bucket_count": len(buckets), "confidence": "indexed-estimate"}


def record_operation(args):
    if not args.path.name.startswith(PREFIX):
        raise ValueError("not a recovery bucket")
    record_size(args.path, index_directory(args.path.parent), args.budget, args.bytes)


def snapshot_operation(args):
    print(json.dumps(snapshot(args.path, args.budget)))


def invalidate_plan(args):
    plan = json.loads(args.path.read_text())
    for entry in plan.get("entries", []):
        recovery_identity = entry.get("identity") or entry.get("recovery_identity") or {}
        bucket = Path(entry.get("bucket_path") or recovery_identity.get("bucket_path")
                      or entry.get("path", ""))
        if not bucket.is_absolute() or not bucket.name.startswith(PREFIX):
            continue
        record = index_directory(bucket.parent) / (bucket.name + ".json")
        # Removing telemetry cannot remove archive data. No recursive deletes.
        record.unlink(missing_ok=True)


def order_operation(args):
    # Sort scheduling hints only. The shell keeps its rotating coverage cursor.
    paths = [Path(line) for line in args.path.read_text().splitlines()]
    if not paths:
        return
    root = paths[0].parent
    if any(path.parent != root for path in paths) or args.offset < 0:
        raise ValueError("inventory outside root")
    try:
        directory = index_directory(root)
        sizes = {path: read_hint(path, directory) for path in paths}
    except (OSError, ValueError):
        # Advisory-index failure must not stop the guarded maintenance path.
        sizes = dict.fromkeys(paths)
    # Stable ties retain the producer inventory order, including no-index fallback.
    paths.sort(key=lambda path: -(sizes[path]["bytes"] if sizes[path] else -1))
    offset = args.offset % len(paths)
    for path in paths[offset:] + paths[:offset]:
        print(path)


def main():
    operations = {"record": record_operation, "snapshot": snapshot_operation,
                  "invalidate-plan": invalidate_plan, "order": order_operation}
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=operations)
    parser.add_argument("path", type=Path)
    parser.add_argument("--budget", type=float, default=2)
    parser.add_argument("--bytes", type=int)
    parser.add_argument("--offset", type=int, default=0)
    args = parser.parse_args()
    if not args.path.is_absolute() or not 0 <= args.budget <= 3600:
        raise ValueError("invalid index arguments")
    operations[args.operation](args)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.SubprocessError):
        raise SystemExit(1)
