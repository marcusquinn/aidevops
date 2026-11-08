"""macOS native process census (lsof) for observation-era worktree retirement."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess  # nosec B404 # fixed native observation command, no shell


def require_idle_macos(path: Path) -> None:
    """Inspect owned processes' cwd/open files using macOS's native lsof."""
    try:
        observed = subprocess.run(  # nosec B603 # fixed system binary and argv
            ["/usr/sbin/lsof", "-nP", "-a", "-u", str(os.geteuid()), "-F0pfn"],
            capture_output=True, check=False, timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError("proc-observation-unavailable") from error
    if observed.returncode != 0 or observed.stderr:
        raise ValueError("proc-observation-unavailable")
    # NUL-delimited names preserve spaces and newlines. lsof adds a newline
    # between process/file records, not inside their fields.
    seen, cwd_seen = _scan_lsof(path, observed.stdout)
    # A successful but empty/partial census is not evidence of idleness.
    if os.getpid() not in seen or seen != cwd_seen:
        raise ValueError("proc-observation-unavailable")


def _scan_lsof(path: Path, output: bytes) -> tuple[set[int], set[int]]:
    """Return observed pids and pids with an absolute cwd; reject live references."""
    current_pid = None
    descriptor = b""
    seen: set[int] = set()
    cwd_seen: set[int] = set()
    for raw in output.split(b"\0"):
        field = raw.removeprefix(b"\n")
        kind, value = field[:1], field[1:]
        if kind == b"p":
            current_pid = _lsof_pid(value)
            seen.add(current_pid)
            descriptor = b""
        elif kind == b"f":
            descriptor = value
        elif kind == b"n":
            if current_pid is None:
                raise ValueError("proc-observation-unavailable")
            name = Path(os.fsdecode(value))
            if descriptor == b"cwd" and name.is_absolute():
                cwd_seen.add(current_pid)
            if name == path or path in name.parents:
                raise ValueError("live-process-reference")
    return seen, cwd_seen


def _lsof_pid(value: bytes) -> int:
    if not value.isdigit():
        raise ValueError("proc-observation-unavailable")
    return int(value)
