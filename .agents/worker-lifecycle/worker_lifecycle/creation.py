"""Create a fresh worktree and record its cooperating creator, never adopt one."""

from collections.abc import Iterator
from contextlib import contextmanager, ExitStack
import ctypes
from dataclasses import dataclass
import os
from pathlib import Path
import shutil
import subprocess  # nosec B404 # explicit native Git invocation
import sys
import tempfile
from uuid import UUID, uuid5

from .directory_handle import DirectoryHandle
from .enrollment import GenerationEnrollment
from .runtime import adapter_for, require_ready
from .session import admit_session
from .storage import LifecycleRegistry, StoreConflict


@dataclass(frozen=True)
class WorktreeSpec:
    repository: Path
    path: Path
    ref: str
    options: tuple[str, ...]


def _publish_directory(source: int, destination: int, name: str) -> None:
    """Use the native no-replace promotion pattern from dependency provisioning."""
    libc = ctypes.CDLL(None, use_errno=True)
    symbol, flag = ("renameatx_np", 4) if sys.platform == "darwin" else ("renameat2", 1)
    rename = getattr(libc, symbol, None)
    if rename is None:
        raise ValueError("atomic-no-replace-unavailable")
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
                       ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(source, b"tree", destination, os.fsencode(name), flag) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def _matches_created(path: Path, descriptor: int) -> bool:
    original = os.fstat(descriptor)
    current = path.lstat()
    return (original.st_dev, original.st_ino) == (current.st_dev, current.st_ino)


@contextmanager
def _created_directory(path: Path) -> Iterator[int]:
    """Pin a private directory before exposing it at the requested public name."""
    container = Path(tempfile.mkdtemp(prefix=".lifecycle-create-", dir=path.parent))
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    try:
        with ExitStack() as resources:
            source = os.open(container, flags)
            resources.callback(os.close, source)
            os.mkdir("tree", mode=0o700, dir_fd=source)
            original = os.open("tree", flags, dir_fd=source)
            resources.callback(os.close, original)
            destination = os.open(path.parent, flags)
            resources.callback(os.close, destination)
            _publish_directory(source, destination, path.name)
            if not _matches_created(path, original):
                raise StoreConflict("creation-directory-changed")
            yield original
    finally:
        # Remove only empty private staging directories, never a partial worktree.
        for temporary in (container / "tree", container):
            try:
                temporary.rmdir()
            except OSError:
                pass


def create_worktree(
    store: LifecycleRegistry, spec: WorktreeSpec, pid: int, session_id: str,
) -> dict[str, object]:
    """Own fresh directory creation; failures retain partial results for recovery.

    A receipt proves this constructor created the tree and admitted its declared
    runtime owner. It is not a claim about uncooperative external writers, nor
    deletion authority. Existing directories cannot acquire this provenance.
    """
    repo, path, ref, options = spec.repository, spec.path, spec.ref, spec.options
    if not isinstance(session_id, str) or not 0 < len(session_id) <= 256:
        raise ValueError("invalid-session-identity")
    if not path.is_absolute() or path.parent.resolve(strict=True) != path.parent:
        raise ValueError("canonical-parent-required")
    adapter = adapter_for(store.installation_id())
    require_ready(adapter)
    identity = adapter.capture(pid)
    if adapter.observe(identity).status != "alive":
        raise StoreConflict("creator-not-alive")
    with store.connection() as connection:
        if connection.execute(
            "SELECT 1 FROM generation_admissions WHERE path=?", (str(path),),
        ).fetchone():
            raise StoreConflict("generation-path-reserved")
    git = shutil.which("git")
    if git is None:
        raise ValueError("git-executable-unavailable")
    environment = {
        key: value for key, value in os.environ.items()
        if not key.startswith("GIT_")
    }
    environment["GIT_TERMINAL_PROMPT"] = "0"
    with DirectoryHandle(repo) as repository, DirectoryHandle(path.parent) as parent:
        with _created_directory(path) as original, DirectoryHandle(path) as directory:
            subprocess.run(  # nosec B603 # caller's native Git options, no shell
                [git, "-C", str(repo), "worktree", "add", *options,
                 "--", str(path), ref],
                env=environment, capture_output=True, check=True, timeout=120,
            )
            if (not _matches_created(path, original)
                    or not all(handle.matches_path() for handle in
                               (repository, parent, directory))):
                raise StoreConflict("creation-directory-changed")
            owner = admit_session(store, path, pid, session_id)
            generation = str(owner["generation_id"])
            if (adapter.capture(pid) != identity
                    or adapter.observe(identity).status != "alive"):
                raise StoreConflict("creator-or-generation-changed")
            if (not _matches_created(path, original)
                    or not all(handle.matches_path() for handle in
                               (repository, parent, directory))
                    or GenerationEnrollment(store).inspect(path) != generation):
                raise StoreConflict("creator-or-generation-changed")
            with store.connection(write=True) as connection:
                store._event(
                    connection, str(uuid5(UUID(generation), "created-worktree")),
                    {"type": "created-worktree", "generation_id": generation,
                     "creator_run_id": owner["run_id"], "path": str(path)},
                )
    return dict(owner, status="created-and-admitted")
