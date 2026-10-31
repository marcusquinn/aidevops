"""Operation-local directory identity, not a lock or durable generation proof."""

import os
from pathlib import Path


class DirectoryHandle:
    """Hold a directory open and detect replacement at its canonical path.

    Use as a context manager. A match says nothing about contents, Git metadata,
    writers or later pathname operations. Never serialize it as cleanup authority.
    An observed mismatch is terminal for this handle; reopen for a new observation.
    """

    def __init__(self, path: Path):
        if not path.is_absolute() or path.resolve(strict=True) != path:
            raise ValueError("directory-path-must-be-canonical")
        self.path = path
        self._pid = os.getpid()
        self._valid = True
        self._descriptor: int | None = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(self._descriptor)
            self._identity = (info.st_dev, info.st_ino)
            if not self.matches_path():
                raise ValueError("directory-changed-during-open")
        except BaseException:
            self.close()
            raise

    def matches_path(self) -> bool:
        """Return false on missing access, replacement, closure or process change."""
        if not self._valid or self._descriptor is None or os.getpid() != self._pid:
            self._valid = False
            return False
        try:
            held = os.fstat(self._descriptor)
            current = self.path.stat(follow_symlinks=False)
            self._valid = (
                self.path.resolve(strict=True) == self.path
                and (held.st_dev, held.st_ino) == self._identity
                and (current.st_dev, current.st_ino) == self._identity
            )
        except (OSError, RuntimeError):
            self._valid = False
        return self._valid

    def close(self) -> None:
        self._valid = False
        descriptor, self._descriptor = self._descriptor, None
        if descriptor is not None:
            os.close(descriptor)

    def __enter__(self) -> "DirectoryHandle":
        if not self.matches_path():
            self.close()
            raise ValueError("directory-handle-unavailable")
        return self

    def __exit__(self, *exception: object) -> None:
        self.close()
