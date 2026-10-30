"""Restartable enrollment of cooperating linked-worktree creators.

The marker identifies a protocol generation, not all writers or a deletion right.
Copied metadata and inode reuse outside this protocol are not excluded by it.
"""

import errno
import grp
import json
import os
from pathlib import Path
import pwd
import shutil
import stat
import subprocess  # nosec B404 # read-only Git query using explicit argv, never a shell
import sys
from uuid import UUID, uuid4, uuid5

from .admission import AdmissionClosed, AdmissionRegistry
from .directory_handle import DirectoryHandle
from .storage import LifecycleRegistry, StoreConflict, encode, identifier


MARKER = "aidevops-generation.json"


def _user_private_group(gid: int) -> bool:
    """True when gid is the owner's primary group and no other account is in it.

    Git creates admin directories under the process umask; umask 002 with
    user-private groups (the Ubuntu default) yields group-writable directories
    that only the owner can write. Shared or unknown groups stay untrusted.
    """
    try:
        owner = pwd.getpwuid(os.getuid())
        group = grp.getgrgid(gid)
    except KeyError:
        return False
    if gid != owner.pw_gid or any(member != owner.pw_name for member in group.gr_mem):
        return False
    return all(entry.pw_gid != gid or entry.pw_uid == owner.pw_uid for entry in pwd.getpwall())


def _no_extended_access_acl(directory: Path) -> bool:
    """Allow Linux's private-group exception only without an access ACL.

    With a POSIX ACL, group mode bits describe the mask, not just the owning
    group's rights. Reject all extended access ACLs rather than trusting named
    entries. Other platforms retain the original no-group-write restriction.
    """
    if sys.platform != "linux":
        return False
    try:
        os.getxattr(directory, "system.posix_acl_access")
    except OSError as error:
        # Only a supported query reporting an absent ACL qualifies. ENOTSUP
        # can hide another ACL model (e.g. NFSv4), not prove the absence of ACLs.
        # Fail closed even on ACL-less filesystems rather than guess their model.
        return error.errno == errno.ENODATA
    return False


def _git_directory(path: Path) -> Path:
    if not stat.S_ISREG((path / ".git").lstat().st_mode):
        raise ValueError("linked-worktree-required")
    # An inherited Git environment must not redirect enrollment to another tree.
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    git = shutil.which("git", path=env.get("PATH"))
    if git is None:
        raise ValueError("git-executable-unavailable")
    # The operator controls PATH; this CLI does not accept an executable from a
    # remote request. Git flags are fixed and the directory is one literal argv
    # element. Shell quoting here would corrupt valid directory names.
    result = subprocess.run(  # nosec B603 # resolved executable, fixed flags, canonical path as one argv item
        [git, "-C", str(path), "rev-parse", "--absolute-git-dir"],  # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-tainted-env-args.dangerous-subprocess-use-tainted-env-args
        env=env, capture_output=True, check=True, timeout=10, shell=False,
    )
    directory = Path(os.fsdecode(result.stdout.removesuffix(b"\n")))
    if not directory.is_absolute() or directory.resolve(strict=True) != directory:
        raise ValueError("canonical-git-directory-required")
    info = directory.stat()
    if (info.st_uid != os.getuid() or info.st_mode & 0o002
            or (info.st_mode & 0o020 and not (
                _user_private_group(info.st_gid) and _no_extended_access_acl(directory)))):
        raise ValueError("git-directory-must-be-owned-and-not-shared-writable")
    with (directory / "gitdir").open("rb") as stream:
        target = stream.read(4097)
    if target != os.fsencode(path / ".git") + b"\n":
        raise ValueError("git-directory-backlink-mismatch")
    return directory


def _directory_inode(path: Path) -> int:
    """Persistent protocol evidence; device numbers are operation-local only."""
    return path.stat(follow_symlinks=False).st_ino


def _marker_identity(value: dict) -> dict:
    """Read format 1 without rewriting it or trusting obsolete device numbers."""
    version = value.get("format")
    if type(version) is not int or version != 1:
        return value
    normalized = dict(value, format=2)
    for field in ("directory", "git_identity"):
        pair = value.get(field)
        if (not isinstance(pair, list) or len(pair) != 2
                or any(type(number) is not int or number < 0 for number in pair)):
            raise StoreConflict("invalid-generation-directory-identity")
        normalized[field] = pair[1]
    return normalized


def _read_marker(path: Path) -> dict:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077 or info.st_size > 4096):
            raise ValueError("generation-marker-must-be-private-owned-file")
        value = json.loads(stream.read(4097))
    if not isinstance(value, dict) or not isinstance(value.get("generation_id"), str):
        raise ValueError("invalid-generation-marker")
    identifier(value["generation_id"])
    return _marker_identity(value)


def _publish(directory: Path, value: dict) -> None:
    """Publish a complete marker without replacing another creator's marker."""
    temporary = directory / f".aidevops-generation-{uuid4()}.tmp"
    descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(encode(value).encode("utf-8"))
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary, directory / MARKER)
        except FileExistsError:
            pass  # The winner is read and validated, never overwritten.
    finally:
        temporary.unlink()
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


class GenerationEnrollment:
    def __init__(self, store: LifecycleRegistry):
        self.store = store

    def has_schema_one_gap(self, path: Path) -> bool:
        """Recognize an un-enrolled schema-1 creation, never grant admission."""
        with self.store.connection() as connection:
            if connection.execute("PRAGMA user_version").fetchone()[0] != 1:
                return False
            if connection.execute("SELECT 1 FROM sqlite_master WHERE name='generation_admissions'").fetchone():
                raise StoreConflict("schema-one-with-admission-state")
            self.store.summary()  # Validate the observation tables before compatibility handling.
            with DirectoryHandle(path) as root:
                directory = _git_directory(path)
                with DirectoryHandle(directory) as admin:
                    marker = directory / MARKER
                    if marker.exists() or marker.is_symlink():
                        raise StoreConflict("schema-one-with-generation-marker")
                    if not root.matches_path() or not admin.matches_path():
                        raise StoreConflict("generation-directory-changed")
        return True

    def resolve(self, path: Path, *, create: bool = False) -> str:
        """Enroll or resolve; never initialize/migrate a DB or reopen a closed gate.

        A crash after marker publication is recovered by repeating create=True.
        Read-only resolution refuses incomplete enrollment. Return values are not
        admission: the native launch must still transact through AdmissionRegistry.
        """
        with self.store.connection() as connection:
            AdmissionRegistry._require_schema(connection)
        with DirectoryHandle(path) as root:
            directory = _git_directory(path)
            with DirectoryHandle(directory) as admin:
                expected = {
                    "format": 2, "installation_id": self.store.installation_id(),
                    "path": str(path), "directory": _directory_inode(path),
                    "git_directory": str(directory), "git_identity": _directory_inode(directory),
                }
                marker = directory / MARKER
                if create and not marker.exists() and not marker.is_symlink():
                    with self.store.connection() as connection:
                        reserved = connection.execute("SELECT 1 FROM generation_admissions WHERE path=?", (str(path),)).fetchone()
                        if reserved and not marker.exists():
                            raise StoreConflict("reserved-path-without-enrollment-marker")
                    _publish(directory, dict(expected, generation_id=str(uuid4())))
                value = _read_marker(marker)
                generation = value.pop("generation_id")
                if encode(value) != encode(expected) or not root.matches_path() or not admin.matches_path():
                    raise StoreConflict("generation-directory-mismatch")
                if create:
                    AdmissionRegistry(self.store).open_generation(
                        str(uuid5(UUID(generation), "enroll")), generation, path,
                    )
                with self.store.connection() as connection:
                    row = connection.execute(
                        "SELECT path,state FROM generation_admissions WHERE generation_id=?", (generation,),
                    ).fetchone()
                    if row is None or row["state"] != "open" or row["path"] != str(path):
                        raise AdmissionClosed("generation-not-open")
                if not root.matches_path() or not admin.matches_path() or _git_directory(path) != directory:
                    raise StoreConflict("generation-directory-changed")
                return generation
