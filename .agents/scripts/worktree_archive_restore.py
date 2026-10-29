#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Prepare Git-only recovery through the same public creation API as Pulse."""

import json
import os
from pathlib import Path
import shutil
import subprocess  # nosec B404 -- fixed local worktree helper, argv only
import sys
import uuid

from worktree_archive_administration import git
from worktree_archive_snapshot import fetch_preservation
from worktree_recovery_timing import timed


def object_store_files(objects):
    """Traverse dependency files without accepting symlinked store entries."""
    from worktree_lifetime_archive import require
    pending = [objects]
    while pending:
        path = pending.pop()
        require(not path.is_symlink(), "restore-proof:symlinked-object-store")
        if path.is_dir():
            pending.extend(path.iterdir())
        else:
            yield path


MANAGED_TABLE = "worktree_managed_lifetimes"
LEGACY_TABLE = "worktree_creation_backends"
NOT_ENROLLED = "restore-proof:verification-copy-not-enrolled"
# Static SQL per registration table; only values are bound as parameters.
REGISTRATION_SQL = {
    MANAGED_TABLE: ("SELECT record FROM worktree_managed_lifetimes WHERE path = ?",
                    "DELETE FROM worktree_managed_lifetimes WHERE path = ?"),
    LEGACY_TABLE: ("SELECT record FROM worktree_creation_backends WHERE path = ?",
                   "DELETE FROM worktree_creation_backends WHERE path = ?"),
}


def registration_table(registered):
    """The registry table that owns a sealed creation registration."""
    if registered.get("backend") == "legacy-guards" and "manager" not in registered:
        return LEGACY_TABLE
    return MANAGED_TABLE


def legacy_registration(connection, target):
    """Return the legacy-guards creation record for target, or None."""
    from worktree_lifetime_archive import require
    if connection.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
                          (LEGACY_TABLE,)).fetchone() is None:
        return None
    row = connection.execute(REGISTRATION_SQL[LEGACY_TABLE][0], (str(target),)).fetchone()
    if row is None:
        return None
    registered = json.loads(row[0])
    invalid = "restore-proof:invalid-creation-backend"
    require(registered.get("schema") == 1, invalid)
    require(registration_table(registered) == LEGACY_TABLE, invalid)
    require(registered.get("identity", {}).get("path") == str(target), invalid)
    require(registered.get("generation"), invalid)
    return registered


def failure_message(final, default):
    """Map a restore child's final exception line to its bounded message.

    GH#35957: NotEnrolled becomes one bounded category so the child's detail
    stays private; a ValueError keeps its policy message.
    """
    import re
    if re.fullmatch(r"[A-Za-z0-9_.]*NotEnrolled: .*", final):
        return NOT_ENROLLED
    if final.startswith("ValueError: "):
        return final.removeprefix("ValueError: ")
    return default


def creation_registration(connection, target):
    """GH#35957: resolve the verification copy's creation registration.

    A managed-lifetime row wins. macOS and AIDEVOPS_WORKTREE_MANAGER=legacy-guards
    creation deliberately records only a worktree_creation_backends entry and never
    a synthetic managed receipt (worktree_lifetime_owner.register), so the proof
    binds that record's identity and generation instead.
    """
    from worktree_lifetime_archive import managed_module, require
    managed = managed_module()
    try:
        registered = managed.load(connection, str(target))
    except managed.NotEnrolled:
        registered = legacy_registration(connection, target)
        require(registered is not None, NOT_ENROLLED)
    managed.verify_identity(registered, target)
    return registered


def creation_receipt(target, owner_pid):
    """Seal the creating actor/generation before any archive payload is applied."""
    from worktree_lifetime_archive import inode, require, transaction
    from worktree_recovery_migration_state import sync_directory
    with transaction() as connection:
        registered = creation_registration(connection, target)
        owner = connection.execute("SELECT * FROM worktree_owners WHERE worktree_path = ?",
                                   (str(target),)).fetchone()
        actor = connection.execute("SELECT owner_pid, task_id, branch FROM worktree_owners WHERE worktree_path = ?",
                                   (str(target),)).fetchone()
        require(actor == (owner_pid, "archive-verification:" + target.parent.name, "HEAD"),
                "restore-proof:creation-owner-changed")
        value = {"schema": "canonical-creation/v1", "registration": registered, "owner": list(owner),
                 "slot_inode": inode(target.parent), "target_inode": inode(target)}
        descriptor = os.open(target.parent / ".creation.json",
                             os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w", encoding="ascii") as handle:
            json.dump(value, handle, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        sync_directory(target.parent)


@timed("registered-restoration-preparation")
def prepare(archive, target, verification=False):
    manifest = json.loads((archive / "manifest.json").read_text(encoding="utf-8"))
    common = Path(manifest["source_git_common_dir"])
    if not common.is_absolute() or not common.is_dir() or os.path.lexists(target):
        raise ValueError("restore requires the recorded repository and a new worktree path")
    entries = git(common, "worktree", "list", "--porcelain", "-z").split(b"\0")
    repository = Path(os.fsdecode(next(entry[9:] for entry in entries if entry.startswith(b"worktree "))))
    bundle = archive / "commits.bundle"
    # Canonical policy intentionally refuses fetch and bundle unbundle. Create
    # our registered worktree at the available base first, then import objects
    # through that owned linked target without touching shared preservation refs.
    initial_head = manifest["base_sha"] if bundle.is_file() else manifest["head_sha"]
    environment = dict(os.environ, AIDEVOPS_SKIP_AUTO_CLAIM="1", WORKTREE_NODE_MODULES_RESTORE_ENABLED="0",
                       AIDEVOPS_WORKTREE_JS_BOOTSTRAP_ENABLED="0",
                       GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="core.hooksPath", GIT_CONFIG_VALUE_0=os.devnull)
    for name in ("GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
                 "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"):
        environment.pop(name, None)
    # Pulse calls this same command. It owns path policy, Git creation and
    # registration; recovery supplies only its exact saved commit and new branch.
    helper = Path(__file__).resolve().with_name("worktree-helper.sh")
    bash = shutil.which("bash")
    if bash is None:
        raise ValueError("Bash is unavailable")
    if verification:
        # Never bind scratch to a worker's managed run unit. An explicit
        # legacy-guards contract is kept: it selects the same creation record
        # that macOS always writes, which creation_registration accepts.
        if environment.get("AIDEVOPS_WORKTREE_MANAGER") != "legacy-guards":
            environment.pop("AIDEVOPS_WORKTREE_MANAGER", None)
        environment.pop("AIDEVOPS_MANAGED_WORKTREE_RUN_UNIT", None)
        environment.update(AIDEVOPS_WORKTREE_CREATE_TASK="archive-verification:" + target.parent.name,
                           AIDEVOPS_WORKTREE_CREATE_OWNER_PID=str(os.getppid()),
                           AIDEVOPS_WORKTREE_CREATE_SESSION="archive-verification:" + target.parent.name)
        subprocess.run(  # nosec B603 -- fixed framework primitive, argv-only owned target
            [str(Path(bash).absolute()), "-c",
             'source "$1" && worktree_create_registered "$2" "$3" "$4" --detach',
             "archive-verification", str(helper.with_name("shared-worktree-create.sh")),
             str(repository), str(target), initial_head],
            env=environment, capture_output=True, check=True, timeout=180)
        creation_receipt(target, os.getppid())
    else:
        subprocess.run(  # nosec B603 -- resolved Bash and fixed framework helper
                       [str(Path(bash).absolute()), str(helper), "add", "recovery/" + uuid.uuid4().hex,
                        str(target), "--base", initial_head], cwd=repository,
                       env=environment, stdout=sys.stderr, check=True, timeout=180)
    if bundle.is_file():
        fetch_preservation(target, archive)
        if verification:
            git(target, "checkout", "--quiet", "--detach", manifest["head_sha"])
        else:
            git(target, "reset", "--hard", manifest["head_sha"])


class RestorationProof:
    """Process-local proof, never reconstructed from a durable verified boolean.

    The caller owns the admission/operation lock for this object's whole lifetime.
    Public restore performs integrity and graph preparation exactly once. Subsequent
    barriers hash the artifacts and physical base object store, not another fetch
    into a temporary repository. This is intentionally NOT a cross-operation cache.
    """

    def __init__(self, directory, record, command, save):
        from worktree_lifetime_archive import inode, require
        from worktree_recovery_retirement_transaction import fingerprint
        from worktree_recovery_timing import phase

        self.pid = os.getpid()
        self.archive = Path(record["archive"])
        require(self.archive.is_absolute() and self.archive == self.archive.resolve(strict=True)
                and self.archive.is_dir(), "restore-proof:unsafe-archive")
        if "output" in record:
            output = Path(record["output"])
            require(output == output.resolve(strict=True) and inode(output) == record["output_inode"]
                    and self.archive.is_relative_to(output), "restore-proof:output-changed")
            pin = self.archive / ".aidevops-archive-pin"
            require(pin.is_file() and not pin.is_symlink(), "restore-proof:pin-missing")
        if "directory_inode" in record:
            require(directory == directory.resolve(strict=True) and inode(directory) == record["directory_inode"],
                    "restore-proof:journal-directory-changed")
        self.archive_inode = inode(self.archive)
        self.archive_digest = fingerprint(self.archive)
        self.manifest = json.loads((self.archive / "manifest.json").read_text(encoding="utf-8"))
        require(self.manifest.get("capture_policy") == "git-only", "restore-proof:unsupported-policy")
        require(self.manifest["source_fingerprint"] == record["source"]["snapshot"],
                "restore-proof:snapshot-mismatch")
        import hashlib
        require(hashlib.sha256((self.archive / "manifest.json").read_bytes()).hexdigest()
                == record["manifest_sha256"], "restore-proof:manifest-changed")
        previous = record.get("canonical_restore")
        if previous and previous.get("state") != "cleaned":
            # A partial restore is not a new deletion baseline. A sealed copy can
            # finish its owned cleanup, but fresh restoration is still mandatory.
            old_slot = directory / previous["slot"]
            if previous.get("state") == "restoring" and old_slot.is_dir() and not any(old_slot.iterdir()):
                require(old_slot == old_slot.resolve(strict=True) and inode(old_slot) == previous["slot_inode"]
                        and old_slot.parent == directory and old_slot.name.startswith(".restore-"),
                        "restore-proof:slot-changed")
                old_slot.rmdir()
                previous["state"] = "cleaned"
                save(record)
            elif (previous.get("state") == "restoring" and old_slot.is_dir()
                  and not os.path.lexists(old_slot / ".creation.json")):
                self.recover_unsealed(directory, previous, save, record,
                                      Path(self.manifest["source_git_common_dir"]))
            else:
                self.cleanup(directory, previous, save, record)
        import tempfile
        slot = Path(tempfile.mkdtemp(prefix=".restore-", dir=directory))
        receipt = {"schema": "canonical-restore/v1", "operation": uuid.uuid4().hex,
                   "state": "restoring", "slot": slot.name, "slot_inode": inode(slot),
                   "archive": str(self.archive), "archive_inode": self.archive_inode,
                   "archive_digest": self.archive_digest, "manifest_sha256": record["manifest_sha256"],
                   "source": record["source"], "base": self.manifest["base_sha"],
                   "capture_schema": self.manifest["schema"], "policy": "git-only"}
        record["canonical_restore"] = receipt
        save(record)
        common = Path(self.manifest["source_git_common_dir"])
        require(common.is_absolute() and common == common.resolve(strict=True), "restore-proof:unsafe-base")
        identity = record["source"].get("identity", {})
        expected_common = identity.get("common_path", identity.get("common"))
        require(expected_common is None or str(common) == expected_common, "restore-proof:wrong-base")
        self.common = common
        self.common_inode = inode(common)
        self.objects = common / "objects"
        require(self.objects == self.objects.resolve(strict=True)
                and not os.path.lexists(self.objects / "info/alternates"),
                "restore-proof:unsupported-external-object-store")
        with phase("dependency-seal-before-restore"):
            dependencies = {path: fingerprint(path) for path in object_store_files(self.objects)}
        target = slot / "worktree"
        with phase("canonical-restore"):
            command("restore", self.archive, "--target", target, "--registered-verification-copy")
        from worktree_recovery_migration_state import load
        created = load(slot / ".creation.json", "canonical-creation/v1")
        require(created["slot_inode"] == inode(slot) and created["target_inode"] == inode(target),
                "restore-proof:creation-identity-changed")
        with phase("compare-restoration"):
            from worktree_archive_snapshot import git_snapshot
            require(git_snapshot(target) == record["source"]["snapshot"], "restore-proof:state-mismatch")
        require(inode(self.archive) == self.archive_inode and fingerprint(self.archive) == self.archive_digest,
                "restore-proof:archive-changed")
        with phase("dependency-seal"):
            # Imports may add archived objects; existing dependency files cannot
            # disappear or change during the canonical verifier's graph check.
            require(inode(common) == self.common_inode
                    and all(fingerprint(path) == digest for path, digest in dependencies.items()),
                    "restore-proof:base-changed-during-restore")
            require(self.objects == self.objects.resolve(strict=True)
                    and not os.path.lexists(self.objects / "info/alternates"),
                    "restore-proof:external-object-store-added")
            # Exhaust the traversal to recheck every entry after object imports.
            for _path in object_store_files(self.objects):
                pass
            self.objects_digest = fingerprint(self.objects)
            git(common, "cat-file", "-e", self.manifest["base_sha"] + "^{commit}")
        from worktree_lifetime_archive import transaction
        with transaction() as connection:
            registered = creation_registration(connection, target)
            owner = connection.execute("SELECT * FROM worktree_owners WHERE worktree_path = ?",
                                       (str(target),)).fetchone()
            require(owner is not None, "restore-proof:owner-missing")
            identity = registered["identity"]
            task = connection.execute("SELECT task_id, branch FROM worktree_owners WHERE worktree_path = ?",
                                      (str(target),)).fetchone()
            require(task == ("archive-verification:" + slot.name, "HEAD")
                    and identity["path"] == str(target) and identity["common"] == str(common),
                    "restore-proof:wrong-registration")
            require(registered == created["registration"] and list(owner) == created["owner"],
                    "restore-proof:creation-generation-changed")
        receipt.update(state="compared", target_inode=inode(target), target_digest=fingerprint(target),
                        registration=registered, owner=list(owner),
                        base_inode=self.common_inode, objects_digest=self.objects_digest,
                        creation_sha256=hashlib.sha256((slot / ".creation.json").read_bytes()).hexdigest())
        save(record)
        with phase("cleanup-verification-scratch"):
            self.cleanup(directory, receipt, save, record)
        self.check()

    def check(self):
        from worktree_lifetime_archive import inode, require
        from worktree_recovery_retirement_transaction import fingerprint
        from worktree_recovery_timing import phase
        require(os.getpid() == self.pid, "restore-proof:process-changed")
        with phase("archive-and-dependency-stability"):
            require(inode(self.archive) == self.archive_inode and fingerprint(self.archive) == self.archive_digest,
                    "restore-proof:archive-changed")
            require(inode(self.common) == self.common_inode and fingerprint(self.objects) == self.objects_digest,
                    "restore-proof:base-changed")
            git(self.common, "cat-file", "-e", self.manifest["base_sha"] + "^{commit}")

    @staticmethod
    def recover_unsealed(directory, receipt, save, record, common):
        """GH#35957: reclaim a registered copy whose creation was never sealed.

        Before legacy-guards creation was accepted, macOS failed after Git and
        registry creation but before .creation.json, leaving a "restoring" slot
        that held a registered worktree. Remove it only when the slot inode,
        sole entry, verification owner row, legacy creation identity and Git
        common dir all match; any other unsealed copy stays fail-closed.
        """
        from worktree_lifetime_archive import inode, managed_module, require, transaction
        slot = directory / receipt["slot"]
        target = slot / "worktree"
        require(common.is_absolute() and common == common.resolve(strict=True), "restore-proof:unsafe-base")
        changed = "restore-proof:slot-changed"
        require(slot == slot.resolve(strict=True), changed)
        require(inode(slot) == receipt["slot_inode"], changed)
        require(slot.parent == directory and slot.name.startswith(".restore-"), changed)
        require({entry.name for entry in slot.iterdir()} == {"worktree"}, changed)
        require(target.is_dir() and not target.is_symlink(), changed)
        unsealed = "restore-proof:unsealed-copy-retained; inspect owned scratch"
        with transaction() as connection:
            owner = connection.execute("SELECT task_id, branch FROM worktree_owners WHERE worktree_path = ?",
                                       (str(target),)).fetchone()
            require(owner == ("archive-verification:" + slot.name, "HEAD"), unsealed)
            if connection.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
                                  (MANAGED_TABLE,)).fetchone():
                require(connection.execute(REGISTRATION_SQL[MANAGED_TABLE][0], (str(target),)).fetchone() is None,
                        unsealed)
            registered = legacy_registration(connection, target)
            require(registered is not None, unsealed)
            # verify_identity recomputes path/admin/common from Git itself.
            managed_module().verify_identity(registered, target)
            require(registered["identity"]["common"] == str(common), "restore-proof:wrong-base")
            entries = git(common, "worktree", "list", "--porcelain", "-z").split(b"\0")
            repository = Path(os.fsdecode(next(entry[9:] for entry in entries if entry.startswith(b"worktree "))))
            git(repository, "worktree", "remove", "--force", str(target))
            require(not os.path.lexists(target) and not os.path.lexists(Path(registered["identity"]["admin"])),
                    "restore-proof:administration-remains")
            connection.execute("DELETE FROM worktree_owners WHERE worktree_path = ?", (str(target),))
            connection.execute(REGISTRATION_SQL[LEGACY_TABLE][1], (str(target),))
        slot.rmdir()
        receipt["state"] = "cleaned"
        save(record)

    @staticmethod
    def cleanup(directory, receipt, save, record):
        from worktree_lifetime_archive import inode, require, transaction
        name = receipt["slot"]
        require(Path(name).name == name and name.startswith(".restore-"), "restore-proof:unsafe-slot")
        slot = directory / name
        if os.path.lexists(slot):
            require(slot == slot.resolve(strict=True) and inode(slot) == receipt["slot_inode"],
                    "restore-proof:slot-changed")
            require({entry.name for entry in slot.iterdir()} <= {"worktree", ".creation.json"},
                    "restore-proof:unexpected-entry")
        target = slot / "worktree"
        require(receipt["state"] in ("compared", "cleanup-pending"),
                "restore-proof:unsealed-copy-retained; inspect owned scratch")
        receipt["state"] = "cleanup-pending"
        save(record)
        registered = receipt["registration"]
        # The same SQLite transaction excludes cooperative ownership replacement
        # across Git removal and registry cleanup. No manifest-supplied deletion path.
        select_registration, delete_registration = REGISTRATION_SQL[registration_table(registered)]
        with transaction() as connection:
            row = connection.execute(select_registration, (str(target),)).fetchone()
            current = json.loads(row[0]) if row else None
            owner = connection.execute("SELECT * FROM worktree_owners WHERE worktree_path = ?",
                                       (str(target),)).fetchone()
            completed = current is None and owner is None and not os.path.lexists(target)
            require(completed or (current == registered and list(owner or ()) == receipt["owner"]),
                    "restore-proof:registration-changed")
            common = Path(registered["identity"]["common"])
            if os.path.lexists(target):
                require(inode(target) == receipt["target_inode"] and not target.is_symlink(),
                        "restore-proof:target-changed")
                from worktree_archive_snapshot import git_snapshot
                from worktree_recovery_retirement_transaction import fingerprint
                require(git_snapshot(target) == receipt["source"]["snapshot"]
                        and fingerprint(target) == receipt["target_digest"], "restore-proof:scratch-drift")
                # The canonical linked-removal exception verifies the checkout
                # top-level as well as the common dir; -C <common> has no top-level.
                entries = git(common, "worktree", "list", "--porcelain", "-z").split(b"\0")
                repository = Path(os.fsdecode(next(entry[9:] for entry in entries if entry.startswith(b"worktree "))))
                git(repository, "worktree", "remove", "--force", str(target))
            require(not os.path.lexists(Path(registered["identity"]["admin"])),
                    "restore-proof:administration-remains")
            connection.execute("DELETE FROM worktree_owners WHERE worktree_path = ?", (str(target),))
            connection.execute(delete_registration, (str(target),))
        if os.path.lexists(slot):
            import hashlib
            creation = slot / ".creation.json"
            if os.path.lexists(creation):
                require(not creation.is_symlink() and hashlib.sha256(creation.read_bytes()).hexdigest()
                        == receipt["creation_sha256"], "restore-proof:creation-receipt-changed")
                creation.unlink()
            slot.rmdir()
        receipt["state"] = "cleaned"
        save(record)


if __name__ == "__main__":
    try:
        prepare(Path(sys.argv[1]).resolve(strict=True), Path(sys.argv[2]).absolute(),
                verification=sys.argv[3:] == ["--verification-copy"])
    except subprocess.CalledProcessError as error:
        # Python's default traceback omits the captured Git stderr. Carry only
        # fixed diagnostic categories across Bash; never expose Git argv/data.
        from worktree_recovery_retry import restore_diagnostic
        print(restore_diagnostic(error), file=sys.stderr)
        sys.exit(1)
