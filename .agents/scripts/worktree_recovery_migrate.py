#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Migrate one validated legacy bucket without retiring or rewriting its source."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess  # nosec B404 -- fixed framework helper, argv only; see archive_command
import sys

from worktree_lifetime_archive import capacity, durable_archive, inode, require
from worktree_recovery_legacy_policy import candidate, guards, has_lifecycle, validate
from worktree_recovery_migration_scratch import finish_scratch, prepare_restore, verify_restore
from worktree_recovery_migration_state import (
    SCHEMA, allocated_bytes, load, manifest_digest, private_directory,
    publish, source_state,
)
from worktree_recovery_timing import child_environment, context as timing_context, operation, phase, timed


SCRIPTS = Path(__file__).resolve().parent


def archive_command(lock, *arguments):
    environment = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1")
    for name in ("GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
                 "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"):
        environment.pop(name, None)
    # Keep the operation locked if this Python parent dies while Bash is still
    # capturing/restoring. A competing invocation must not start a second copy.
    bash = shutil.which("bash")
    require(bash is not None, "migration:bash-unavailable")
    with phase("archive-cli." + str(arguments[0])):
        child_environment(environment)
        result = subprocess.run(  # nosec B603 -- resolved Bash, framework helper, argv only
                                [str(Path(bash).absolute()), str(SCRIPTS / "worktree-archive-helper.sh"),
                                 *map(str, arguments)], env=environment, pass_fds=(lock,),
                                capture_output=True, text=True, check=True, timeout=600)
    return result.stdout.strip()


@timed("reserve-and-source-snapshot")
def reserve(directory, output, identity, arguments):
    journal = directory / "journal.json"
    policy = os.environ.get("AIDEVOPS_WORKTREE_RECOVERY_POLICY", "git-only")
    fingerprint_schema = 3
    if journal.exists() or journal.is_symlink():
        saved = load(journal)["source"]
        policy = saved.get("capture_policy", "preserve-v1")
        fingerprint_schema = saved["snapshot"].get("schema")
    else:
        require(policy == "git-only", "migration:obsolete-capture-policy; new archives use Git changes and untracked files")
    git_only = policy == "git-only"
    current = source_state(identity, git_only, fingerprint_schema)
    if journal.exists() or journal.is_symlink():
        record = load(journal)
        require(record["source"] == current, "migration:source-drift")
        expected = {"directory_inode": inode(directory), "output": str(output),
                    "output_inode": inode(output), "repo": arguments.repo,
                    "base": arguments.base_branch}
        require({key: record[key] for key in expected} == expected,
                "migration:reservation-changed")
        return record
    require(not any(output.iterdir()), "migration:unrecorded-capture")
    if not git_only:
        required = capacity(Path(identity["archive_path"]), current["snapshot"])
        require(shutil.disk_usage(output).free >= required, "migration:insufficient-capacity")
    record = {"schema": SCHEMA, "phase": "reserved", "source": current,
              "directory_inode": inode(directory), "output": str(output),
              "output_inode": inode(output), "repo": arguments.repo,
              "base": arguments.base_branch, "source_retired": False,
                "reclaimed_bytes": 0, "bucket_bytes": None if git_only else allocated_bytes(Path(identity["bucket_path"]))}
    record["legacy_pulse_compaction"] = getattr(arguments, "legacy_pulse_compaction", False)
    publish(journal, record)
    return record


@timed("capture")
def capture(directory, record, lock):
    output = Path(record["output"])
    worktree = record["source"]["identity"]["archive_path"]
    git_only = record["source"].get("capture_policy") == "git-only"
    if not any(output.iterdir()):
        require(git_only and record["source"]["snapshot"].get("schema") in (3, 4),
                "migration:legacy-capture-read-only; existing source retained")
        record["phase"] = "capturing"
        publish(directory / "journal.json", record)
        archive_command(lock, "archive", worktree, "--repo", record["repo"],
                        "--base-branch", record["base"], "--unattributed",
                        "--reason", "unattributed-worktree", "--output-root", output)
    manifests = list(output.glob("*/*/*/manifest.json"))
    require(len(manifests) == 1, "migration:capture-incomplete; retained without another allocation")
    archive = manifests[0].parent
    require(archive == archive.resolve(strict=True), "migration:archive-path-changed")
    manifest = json.loads(manifests[0].read_text(encoding="utf-8"))
    if git_only:
        require(manifest.get("capture_policy") == "git-only" and manifest.get("source_worktree") == worktree,
                "migration:wrong-archive-policy")
        record["source"]["snapshot"] = manifest["source_fingerprint"]
    else:
        archive_command(lock, "verify", archive)
        archive_command(lock, "source-matches", archive, worktree)
        require(isinstance(manifest.get("self_contained"), bool) and manifest.get("include_ignored") is True
                and manifest.get("git_admin_policy") == "preserve-v1"
                and manifest.get("source_worktree") == worktree, "migration:wrong-archive-policy")
    pin = archive / ".aidevops-archive-pin"
    if not pin.exists() and not pin.is_symlink():
        descriptor = os.open(pin, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            handle.write("Legacy migration: no retirement or expiry authority.\n")
    require(pin.is_file() and not pin.is_symlink(), "migration:unsafe-pin")
    durable_archive(archive)
    record.update(phase="captured", archive=str(archive), manifest_sha256=manifest_digest(archive))
    publish(directory / "journal.json", record)


@timed("verify-archive-and-source")
def verify_archive(record, lock, check_source=True):
    archive = Path(record["archive"])
    output = Path(record["output"])
    require(archive == archive.resolve(strict=True) and archive.is_relative_to(output)
            and inode(output) == record["output_inode"], "migration:archive-path-changed")
    require(manifest_digest(archive) == record["manifest_sha256"], "migration:manifest-changed")
    if record["source"].get("capture_policy") == "git-only":
        from worktree_archive_restore import RestorationProof
        bucket = Path(record["source"]["identity"]["bucket_path"])
        directory = bucket.parent / ".compact-migrations" / bucket.name
        RestorationProof(directory, record, lambda *args: archive_command(lock, *args),
                         lambda value: publish(directory / "journal.json", value))
    else:
        archive_command(lock, "verify", archive)
    require(manifest_digest(archive) == record["manifest_sha256"], "migration:manifest-changed")
    require((archive / ".aidevops-archive-pin").is_file()
            and not (archive / ".aidevops-archive-pin").is_symlink(), "migration:pin-missing")
    if check_source:
        require(source_state(record["source"]["identity"], record["source"].get("capture_policy") == "git-only",
                             record["source"]["snapshot"].get("schema"))
                == record["source"], "migration:source-drift")


@timed("independent-restore")
def independent_restore(directory, record, lock):
    restored = prepare_restore(directory, record)
    if not restored.exists() and not restored.is_symlink():
        archive_command(lock, "restore", record["archive"], "--target", restored)
    with phase("compare-restoration"):
        verify_restore(restored, record)
    verify_archive(record, lock)
    record.update(phase="restore-verified", restore_inode=inode(restored),
                  archive_bytes=allocated_bytes(Path(record["archive"])))
    publish(directory / "journal.json", record)


@timed("finish-verification")
def finish(directory, record, lock):
    verify_archive(record, lock)
    if record["phase"] != "archive-verified":
        with phase("cleanup-verification-scratch"):
            finish_scratch(directory, record)
    record["phase"] = "verified"
    publish(directory / "journal.json", record)


def migrate(directory, output, identity, arguments, lock):
    record = reserve(directory, output, identity, arguments)
    timing_context(resumed=record["phase"] != "reserved", receipt=str(directory / "journal.json"),
                   source_bytes=record["bucket_bytes"],
                   legacy_pulse_compaction=record.get("legacy_pulse_compaction", False))
    if record["phase"] in ("reserved", "capturing"):
        capture(directory, record, lock)
    if record["source"].get("capture_policy") == "git-only":
        require(record["phase"] in ("captured", "archived"), "migration:incomplete-phase")
        record.update(phase="archived", archive_bytes=allocated_bytes(Path(record["archive"])))
        publish(directory / "journal.json", record)
        timing_context(archive=record["archive"], archive_bytes=record["archive_bytes"],
                       capture_policy="git-only", source_retired=False)
        return {"state": "archived", "receipt": str(directory / "journal.json"),
                "archive": record["archive"], "bucket_bytes": record["bucket_bytes"],
                "archive_bytes": record["archive_bytes"], "source_retired": False, "reclaimed_bytes": 0}
    if record["phase"] == "captured":
        verify_archive(record, lock)
        if record.get("legacy_pulse_compaction") is True:
            record.update(phase="archive-verified", archive_bytes=allocated_bytes(Path(record["archive"])),
                          verification="archive-integrity-and-source-match")
            publish(directory / "journal.json", record)
        else:
            independent_restore(directory, record, lock)
    if record["phase"] in ("restore-verified", "cleanup-pending", "archive-verified"):
        finish(directory, record, lock)
    require(record["phase"] == "verified", "migration:incomplete-phase")
    verify_archive(record, lock)
    timing_context(archive=record["archive"], archive_bytes=record["archive_bytes"], source_retired=False)
    return {"state": "verified", "receipt": str(directory / "journal.json"),
            "archive": record["archive"], "bucket_bytes": record["bucket_bytes"],
            "archive_bytes": record["archive_bytes"], "source_retired": False, "reclaimed_bytes": 0}


@operation("legacy-migration")
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo")
    parser.add_argument("--base-branch")
    parser.add_argument("--retire-automatic", action="store_true")
    arguments = parser.parse_args()
    identity = json.load(sys.stdin)
    bucket = Path(identity["bucket_path"])
    if arguments.retire_automatic:
        from worktree_recovery_producer import attribution
        require(identity.get("source_removal_outcome") == "removed", "migration:source-removal-incomplete")
        common = Path(identity["common_path"]).resolve(strict=True)
        require(not common.is_relative_to(bucket), "migration:base-inside-source")
        guards(identity, bucket)
        arguments.repo, arguments.base_branch = attribution(Path(identity["archive_path"]), {"common": str(common)})
    require(bool(arguments.repo and arguments.base_branch), "migration:repository-and-base-required")
    timing_context(repo=arguments.repo, source=str(bucket))
    with phase("preflight-policy-and-process-guards"):
        arguments.legacy_pulse_compaction = candidate(identity) and not has_lifecycle(identity)
        if arguments.legacy_pulse_compaction:
            # Fail before allocating an archive when retirement is already blocked.
            validate(identity)
            guards(identity, bucket)
    private_directory(bucket.parent / ".compact-migrations")
    directory = bucket.parent / ".compact-migrations" / bucket.name
    private_directory(directory)
    root = Path(os.environ.get("AIDEVOPS_WORKTREE_ARCHIVE_ROOT", str(Path.home() / ".aidevops/recovery/archives")))
    identifier = hashlib.sha256(os.fsencode(bucket)).hexdigest()
    output = root / ".legacy-migrations" / identifier
    require(not output.is_relative_to(bucket), "migration:output-inside-source")
    private_directory(output)
    lock = os.open(directory / "lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        require(stat.S_ISREG(os.fstat(lock).st_mode), "migration:unsafe-lock")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = migrate(directory, output, identity, arguments, lock)
        if arguments.retire_automatic:
            from worktree_recovery_retire import automatic_retire
            result = automatic_retire(directory, load(directory / "journal.json"), bucket, lock)
            timing_context(source_retired=result["retired"], source_bytes=result["bucket_bytes"],
                           archive_bytes=result["archive_bytes"])
        print(json.dumps(result, sort_keys=True))
    finally:
        os.close(lock)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        reason = str(error) if isinstance(error, ValueError) else "migration:evidence-unavailable"
        print(json.dumps({"state": "incomplete", "reason": reason, "source_retired": False}))
        sys.exit(1)
