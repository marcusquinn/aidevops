"""Restartable enrollment of cooperating linked-worktree creators.

The marker identifies a protocol generation, not all writers or a deletion right.
Copied metadata and inode reuse outside this protocol are not excluded by it.
"""

import json
import os
from pathlib import Path
import shutil
import stat
import subprocess  # nosec B404 # read-only Git query using explicit argv, never a shell
from uuid import UUID, uuid4, uuid5

from .admission import AdmissionClosed, AdmissionRegistry
from .directory_handle import DirectoryHandle
from .storage import LifecycleRegistry, StoreConflict, encode, identifier


MARKER = "aidevops-generation.json"


def _git_directory(path: Path) -> Path:
    if not stat.S_ISREG((path / ".git").lstat().st_mode):
        raise ValueError("linked-worktree-required")
    # An inherited Git environment must not redirect enrollment to another tree.
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    git = shutil.which("git", path=env.get("PATH"))
    if git is None:
        raise ValueError("git-executable-unavailable")
    result = subprocess.run(  # nosec B603 # resolved executable, fixed flags, canonical path as one argv item
        [git, "-C", str(path), "rev-parse", "--absolute-git-dir"],
        env=env, capture_output=True, check=True, timeout=10,
    )
    directory = Path(os.fsdecode(result.stdout.removesuffix(b"\n")))
    if not directory.is_absolute() or directory.resolve(strict=True) != directory:
        raise ValueError("canonical-git-directory-required")
    info = directory.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError("git-directory-must-be-owned-and-not-shared-writable")
    with (directory / "gitdir").open("rb") as stream:
        target = stream.read(4097)
    if target != os.fsencode(path / ".git") + b"\n":
        raise ValueError("git-directory-backlink-mismatch")
    return directory


def _fingerprint(path: Path) -> int:
    # Device numbers can change across mounts; DirectoryHandle checks them only
    # within the current operation, not as part of the persistent identity.
    return path.stat(follow_symlinks=False).st_ino


def _normalize_marker(value: dict) -> dict:
    """Recover format 1 in memory without rewriting concurrent readers' marker.

    Only the obsolete device numbers are ignored. The caller still compares all
    fields (including both inodes) and validates the live Git-directory backlink.
    """
    if value.get("format") == 1:
        value = value.copy()
        for key in ("directory", "git_identity"):
            identity = value.get(key)
            if (not isinstance(identity, list) or len(identity) != 2
                    or any(type(part) is not int for part in identity)):
                raise ValueError("invalid-generation-marker-identity")
            value[key] = identity[1]
        value["format"] = 2
    return value


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
    return value


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
                    "path": str(path), "directory": _fingerprint(path),
                    "git_directory": str(directory), "git_identity": _fingerprint(directory),
                }
                marker = directory / MARKER
                if create and not marker.exists() and not marker.is_symlink():
                    with self.store.connection() as connection:
                        reserved = connection.execute("SELECT 1 FROM generation_admissions WHERE path=?", (str(path),)).fetchone()
                        if reserved and not marker.exists():
                            raise StoreConflict("reserved-path-without-enrollment-marker")
                    _publish(directory, dict(expected, generation_id=str(uuid4())))
                value = _normalize_marker(_read_marker(marker))
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
