"""Derived-state persistence shared by the incremental session-time collectors.

t19433 / GH#40628. See session_time_incremental.py for the collection design.
"""

from __future__ import annotations

import json
import os
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

STATE_VERSION = 1


@dataclass
class Scan:
    """Per-run parameters shared by every source scan."""

    since: int
    now: int
    deadline: float
    checkpoint: Callable[[], None]

    def expired(self):
        return time.monotonic() > self.deadline


def empty_state():
    return {"version": STATE_VERSION, "sessions": {}, "obs": {}}


def load_state(path):
    try:
        loaded = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return empty_state()
    if not isinstance(loaded, dict) or loaded.get("version") != STATE_VERSION:
        return empty_state()
    loaded.setdefault("sessions", {})
    loaded.setdefault("obs", {})
    return loaded


def save_state(path, state):
    target = Path(path)
    if target.is_symlink() or not target.parent.is_dir():
        raise OSError("session-time state path is not a safe regular-file target")
    handle, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
    try:
        os.fchmod(handle, 0o600)
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(state, stream, separators=(",", ":"))
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def file_identity(db_path):
    stat = db_path.stat()
    return [stat.st_size, stat.st_mtime_ns]
