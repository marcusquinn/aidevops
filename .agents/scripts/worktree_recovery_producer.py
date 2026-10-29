#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Create source-bound compact recovery archives; never remove a source.

One durable reservation per source/admin inode prevents duplicate captures on
retry. Interrupted artifacts remain protected. Only independently restored,
self-contained archives can be handed to the existing native-removal guard.
"""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess  # nosec B404 -- subprocess errors only; execution uses the shared helper
import sys

from worktree_archive_snapshot import git, git_snapshot, snapshot
from worktree_archive_restore import NOT_ENROLLED, RestorationProof, failure_message
from worktree_lifetime_archive import capacity, durable_archive, inode, require
from worktree_recovery_migrate import archive_command
from worktree_recovery_migration_scratch import finish_scratch, prepare_restore, verify_restore
from worktree_recovery_migration_state import (
    allocated_bytes, load, manifest_digest, private_directory, publish,
)
from worktree_recovery_retirement_transaction import fingerprint
from worktree_recovery_timing import context as timing_context, operation, phase, timed


SCHEMA = "aidevops.worktree-recovery-producer/v1"


def failure_reason(error):
    # Exact messages from worktree_archive_filesystem.supported_metadata.
    # Inspect only the final exception line, never emit captured CLI diagnostics.
    metadata_errors = {
        "ownership, ACLs or extended attributes require separate preservation",
        "special permissions or hard links require separate preservation",
    }
    message = str(error) if isinstance(error, ValueError) else ""
    if isinstance(error, subprocess.CalledProcessError) and isinstance(error.stderr, str):
        lines = error.stderr.rstrip().splitlines()
        # source_fingerprint's shell caller adds this fixed failure trailer.
        if lines and lines[-1] == "Error: worktree fingerprint unavailable":
            lines.pop()
        message = failure_message(lines[-1] if lines else "", message)
        if message == NOT_ENROLLED:
            return NOT_ENROLLED
    if message in metadata_errors:
        return ("producer:unsupported-metadata; permissions, ownership, ACLs, extended attributes "
                "or hard links require separate preservation; source retained; "
                "retrying will not resolve this policy refusal")
    return str(error) if isinstance(error, ValueError) else "producer:evidence-unavailable"


def journal_for_archive(archive):
    require(len(archive.parents) >= 5 and archive.parents[3].name == ".producer-archives"
            and re.fullmatch(r"[0-9a-f]{64}", archive.parents[2].name), "producer:archive-layout-changed")
    return archive.parents[4] / ".producer-transactions" / archive.parents[2].name / "journal.json"


def identity(source):
    require(source.is_absolute() and source == source.resolve(strict=True), "producer:source-path-changed")
    admin = Path(os.fsdecode(git(source, "rev-parse", "--absolute-git-dir").strip()))
    common = Path(os.fsdecode(git(source, "rev-parse", "--path-format=absolute", "--git-common-dir").strip()))
    require(admin == admin.resolve(strict=True) and common == common.resolve(strict=True)
            and admin != common, "producer:linked-worktree-required")
    return {"path": str(source), "inode": inode(source), "admin": str(admin),
            "admin_inode": inode(admin), "common": str(common), "common_inode": inode(common)}


@timed("source-snapshot")
def source_state(source, policy="git-only", fingerprint_schema=3):
    observed = identity(source)
    baseline = (git_snapshot(source, include_untracked=fingerprint_schema != 2) if policy == "git-only"
                else snapshot(source, preserve_git_admin=True, include_ignored=True))
    require(identity(source) == observed, "producer:source-identity-changed")
    state = {"identity": observed, "snapshot": baseline}
    if policy == "git-only":
        state["capture_policy"] = policy
    return state


def attribution(source, observed):
    # Never infer an issue from a pathname or contact the forge to archive data.
    # Local/non-GitHub repositories receive a stable, explicitly local identity.
    digest = hashlib.sha256(os.fsencode(observed["common"])).hexdigest()
    repo = "local/" + digest
    try:
        remote = os.fsdecode(git(source, "remote", "get-url", "origin").strip())
    except subprocess.CalledProcessError:
        remote = ""
    match = re.fullmatch(r"(?:https://github\.com/|git@github\.com:)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?", remote)
    if match:
        repo = match.group(1)
    # Do not pick the first feature branch: cleanup may delete it immediately.
    # Use the integration ref, or the canonical branch for local-only repositories.
    try:
        base = os.fsdecode(git(source, "symbolic-ref", "--short", "refs/remotes/origin/HEAD").strip())
        base = base.removeprefix("origin/")
    except subprocess.CalledProcessError:
        base = os.fsdecode(git(Path(observed["common"]), "symbolic-ref", "--short", "HEAD").strip())
    require(bool(base), "producer:base-attribution-unavailable")
    return repo, base


@contextmanager
def operation_lock(directory):
    descriptor = os.open(directory / "lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        observed = os.fstat(descriptor)
        require(stat.S_ISREG(observed.st_mode) and observed.st_uid == os.getuid(), "producer:unsafe-lock")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield descriptor
    finally:
        os.close(descriptor)


@timed("reservation-preflight")
def reservation(source, root):
    observed = identity(source)
    require(root.is_absolute() and root == root.resolve()
             and not root.is_relative_to(source)
             and not root.is_relative_to(Path(observed["common"])),
             "producer:unsafe-storage-root")
    identifier = hashlib.sha256(json.dumps(observed, sort_keys=True).encode()).hexdigest()
    directory = root / ".producer-transactions" / identifier
    output = root / ".producer-archives" / identifier
    private_directory(directory)
    private_directory(output)
    policy = os.environ.get("AIDEVOPS_WORKTREE_RECOVERY_POLICY", "git-only")
    fingerprint_schema = 3
    if os.path.lexists(directory / "journal.json"):
        saved = load(directory / "journal.json", SCHEMA)["source"]
        policy = saved.get("capture_policy", "preserve-v1")
        fingerprint_schema = saved.get("snapshot", {}).get("schema", 3)
    else:
        require(policy == "git-only", "producer:obsolete-capture-policy; new archives use Git changes and untracked files")
    if policy == "git-only" and not os.path.lexists(directory / "journal.json"):
        current = {"identity": observed, "capture_policy": policy}
    else:
        current = source_state(source, policy, fingerprint_schema)
    return current, directory, output


@timed("reserve")
def reserve(current, directory, output, caller, context):
    journal = directory / "journal.json"
    if os.path.lexists(journal):
        record = load(journal, SCHEMA)
        expected = dict(record["source"])
        actual = dict(current)
        if expected.get("capture_policy") == "git-only" and "snapshot" not in expected:
            actual.pop("snapshot", None)
        require(expected == actual, "producer:source-drift; existing archive retained")
        require(record["directory_inode"] == inode(directory) and record["output"] == str(output)
                and record["output_inode"] == inode(output), "producer:reservation-changed")
        return record
    require(not any(output.iterdir()), "producer:unrecorded-capture; retained for review")
    source = Path(current["identity"]["path"])
    git_only = current.get("capture_policy") == "git-only"
    if not git_only:
        require(shutil.disk_usage(output).free >= capacity(source, current["snapshot"]), "producer:insufficient-capacity")
    repo, base = attribution(source, current["identity"])
    record = {"schema": SCHEMA, "phase": "reserved", "source": current,
              "directory_inode": inode(directory), "output": str(output), "output_inode": inode(output),
              "repo": repo, "base": base, "caller": caller, "context": context,
              "session_id": os.environ.get("AIDEVOPS_SESSION_ID", ""),
              "source_removal_outcome": "pending", "source_bytes": None if git_only else allocated_bytes(source)}
    publish(journal, record)
    return record


@timed("capture")
def capture(directory, record, lock):
    output = Path(record["output"])
    source = record["source"]["identity"]["path"]
    git_only = record["source"].get("capture_policy") == "git-only"
    if not any(output.iterdir()):
        require(git_only, "producer:legacy-capture-read-only; existing source retained")
        record["phase"] = "capturing"
        publish(directory / "journal.json", record)
        archive_command(lock, "archive", source, "--repo", record["repo"],
                        "--base-branch", record["base"], "--unattributed",
                        "--reason", "unattributed-worktree", "--output-root", output)
    manifests = list(output.glob("*/*/*/manifest.json"))
    require(len(manifests) == 1, "producer:capture-incomplete; retained without another allocation")
    archive = manifests[0].parent
    require(archive == archive.resolve(strict=True), "producer:archive-path-changed")
    manifest = json.loads(manifests[0].read_text(encoding="utf-8"))
    if git_only:
        require(manifest.get("capture_policy") == "git-only" and manifest.get("source_worktree") == source,
                "producer:wrong-archive-policy")
        record["source"]["snapshot"] = manifest["source_fingerprint"]
    else:
        require(manifest.get("self_contained") is True and manifest.get("include_ignored") is True
                and manifest.get("git_admin_policy") == "preserve-v1"
                and manifest.get("source_worktree") == source, "producer:wrong-archive-policy")
        archive_command(lock, "verify", archive)
        archive_command(lock, "source-matches", archive, source)
    require(journal_for_archive(archive) == directory / "journal.json", "producer:archive-layout-changed")
    pin = archive / ".aidevops-archive-pin"
    if not os.path.lexists(pin):
        descriptor = os.open(pin, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            handle.write("Producer recovery: no automatic expiry authority.\n")
    require(pin.is_file() and not pin.is_symlink(), "producer:unsafe-pin")
    durable_archive(archive)
    record.update(phase="captured", archive=str(archive), manifest_sha256=manifest_digest(archive))
    publish(directory / "journal.json", record)


@timed("verify-archive")
def verify_archive(record, lock):
    if record["phase"] in ("restore-verified", "cleanup-pending", "verified"):
        require(isinstance(record.get("restore_fingerprint"), str)
                and re.fullmatch(r"[0-9a-f]{64}", record["restore_fingerprint"]),
                "producer:missing-scratch-proof")
    archive = Path(record["archive"])
    output = Path(record["output"])
    require(archive == archive.resolve(strict=True) and archive.is_relative_to(output)
            and output == output.resolve(strict=True) and inode(output) == record["output_inode"],
            "producer:archive-path-changed")
    require(manifest_digest(archive) == record["manifest_sha256"], "producer:manifest-changed")
    archive_command(lock, "verify", archive)
    require(manifest_digest(archive) == record["manifest_sha256"], "producer:manifest-changed")
    pin = archive / ".aidevops-archive-pin"
    require(pin.is_file() and not pin.is_symlink(), "producer:pin-missing")


@operation("producer-capture")
def prepare(source, root, caller, context):
    timing_context(source=str(source), caller=caller)
    current, directory, output = reservation(source, root)
    with operation_lock(directory) as lock:
        record = reserve(current, directory, output, caller, context)
        timing_context(repo=record["repo"], resumed=record["phase"] != "reserved",
                       receipt=str(directory / "journal.json"), source_bytes=record["source_bytes"])
        if record["phase"] in ("reserved", "capturing"):
            capture(directory, record, lock)
        if record["source"].get("capture_policy") == "git-only":
            require(record["phase"] in ("captured", "archived"), "producer:incomplete-phase")
            record.update(phase="archived", archive_bytes=allocated_bytes(Path(record["archive"])))
            publish(directory / "journal.json", record)
            timing_context(archive=record["archive"], archive_bytes=record["archive_bytes"],
                           capture_policy="git-only", source_removal_outcome=record["source_removal_outcome"])
            return record["archive"]
        if record["phase"] == "captured":
            restored = prepare_restore(directory, record)
            # A previous process may have restored data but died before sealing
            # it. Never adopt that mutable tree as a new deletion baseline.
            require(not os.path.lexists(restored), "producer:unsealed-restore-retained; review required")
            archive_command(lock, "restore", record["archive"], "--target", restored)
            with phase("compare-restoration"):
                verify_restore(restored, record)
            verify_archive(record, lock)
            require(source_state(source, "preserve-v1") == record["source"], "producer:source-drift")
            record.update(phase="restore-verified", restore_inode=inode(restored),
                          restore_fingerprint=fingerprint(restored),
                          archive_bytes=allocated_bytes(Path(record["archive"])))
            publish(directory / "journal.json", record)
        if record["phase"] in ("restore-verified", "cleanup-pending"):
            verify_archive(record, lock)
            require(source_state(source, "preserve-v1") == record["source"], "producer:source-drift")
            with phase("cleanup-verification-scratch"):
                finish_scratch(directory, record)
            record["phase"] = "verified"
            publish(directory / "journal.json", record)
        require(record["phase"] == "verified", "producer:incomplete-phase")
        verify_archive(record, lock)
        require(source_state(source, "preserve-v1") == record["source"], "producer:source-drift")
        timing_context(archive=record["archive"], archive_bytes=record["archive_bytes"],
                       source_removal_outcome=record["source_removal_outcome"])
        return record["archive"]


@operation("producer-validation")
def check(archive, source=None, removed=False):
    require(archive == archive.resolve(strict=True), "producer:archive-path-changed")
    journal = journal_for_archive(archive)
    require(journal.name == "journal.json" and journal == journal.resolve(strict=True), "producer:journal-path-changed")
    directory = journal.parent
    with operation_lock(directory) as lock:
        record = load(journal, SCHEMA)
        timing_context(repo=record["repo"], archive=str(archive), source=record["source"]["identity"]["path"])
        git_only = record["source"].get("capture_policy") == "git-only"
        require(record["directory_inode"] == inode(directory) and record["archive"] == str(archive)
                 and record["phase"] == ("archived" if git_only else "verified"), "producer:incomplete-receipt")
        if git_only:
            RestorationProof(directory, record, lambda *args: archive_command(lock, *args),
                             lambda value: publish(journal, value))
        else:
            verify_archive(record, lock)
        if source is not None:
            require(source_state(source, "git-only" if git_only else "preserve-v1",
                                 record["source"]["snapshot"].get("schema")) == record["source"], "producer:source-drift")
            archive_command(lock, "source-matches", archive, source)
        if removed:
            observed = record["source"]["identity"]
            common = Path(observed["common"])
            require(common == common.resolve(strict=True) and inode(common) == observed["common_inode"]
                    and Path(observed["path"]).parent.is_dir(), "producer:source-parent-unavailable")
            require(not os.path.lexists(observed["path"]) and not os.path.lexists(observed["admin"]),
                    "producer:source-or-registration-remains")
            record["source_removal_outcome"] = "removed"
            publish(journal, record)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("capture", "verify", "source-matches", "removed"))
    parser.add_argument("path", type=Path)
    parser.add_argument("arguments", nargs="*")
    args = parser.parse_args()
    if args.command == "capture" and len(args.arguments) == 3:
        root, caller, context = args.arguments
        print(prepare(args.path, Path(root), caller, context))
    elif args.command == "source-matches" and len(args.arguments) == 1:
        check(args.path, Path(args.arguments[0]))
    elif args.command in ("verify", "removed") and not args.arguments:
        check(args.path, removed=args.command == "removed")
    else:
        parser.error("invalid command arguments")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(failure_reason(error), file=sys.stderr)
        sys.exit(1)
