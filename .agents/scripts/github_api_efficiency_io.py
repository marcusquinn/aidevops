#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Atomic output helpers shared by GitHub API efficiency tools."""

from __future__ import annotations

import os
from pathlib import Path
import tempfile


class AtomicWriteError(OSError):
    """Raised when an output cannot be written atomically."""


def atomic_write_text(path: Path, content: str) -> None:
    """Write private UTF-8 text and atomically replace the target."""
    descriptor = -1
    temporary_name = ""
    try:
        if path.is_symlink():
            raise AtomicWriteError("output path must not be a symlink")
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{path.name}.", dir=path.parent
        )
        if hasattr(os, "fchmod"):
            os.fchmod(descriptor, 0o600)
        handle = os.fdopen(descriptor, "w", encoding="utf-8")
        descriptor = -1
        with handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
    except AtomicWriteError:
        raise
    except OSError as exc:
        raise AtomicWriteError("could not atomically write output") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary_name:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass
