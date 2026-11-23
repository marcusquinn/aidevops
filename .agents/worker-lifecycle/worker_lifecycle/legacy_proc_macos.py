"""macOS native process census (lsof) for observation-era worktree retirement.

Every fail-closed branch raises ``ProcessCensusUnavailable`` with a fixed,
path-free stage/cause (GH#39953). The message stays
``proc-observation-unavailable``; ``cli_errors`` surfaces the observation as
``process_observation`` so an operator can tell which condition fired.
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess  # nosec B404 # fixed native observation command, no shell

from .protected_proc import ProcessCensusUnavailable


LSOF_TIMEOUT_SECONDS = 30
# Fixed vocabulary: only the label leaves this module, never lsof's text, which
# can name mount points or other paths.
_STDERR_CLASSES = (
    ("warning-stat", (b"can't stat", b"cannot stat")),
    ("permission-denied", (b"permission denied", b"operation not permitted")),
    ("warning-other", (b"warning",)),
)


def _unavailable(stage: str, cause: str, pid: int = 0, **extra: int) -> ProcessCensusUnavailable:
    error = ProcessCensusUnavailable(pid, pid, stage, cause)
    error.observation.update(extra)
    return error


def _stderr_class(stderr: bytes) -> str:
    text = stderr.lower()
    return next((label for label, terms in _STDERR_CLASSES
                 if any(term in text for term in terms)), "other")


def require_idle_macos(path: Path) -> None:
    """Inspect owned processes' cwd/open files using macOS's native lsof."""
    try:
        observed = subprocess.run(  # nosec B603 # fixed system binary and argv
            ["/usr/sbin/lsof", "-nP", "-a", "-u", str(os.geteuid()), "-F0pfn"],
            capture_output=True, check=False, timeout=LSOF_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as error:
        raise _unavailable("lsof-exec", "timeout") from error
    except (OSError, subprocess.SubprocessError) as error:
        raise _unavailable("lsof-exec", "oserror") from error
    if observed.returncode != 0:
        raise _unavailable("lsof-exit", "nonzero-exit", returncode=observed.returncode)
    if observed.stderr:
        # Any diagnostic may mean an incomplete census; keep failing closed.
        raise _unavailable("lsof-stderr", _stderr_class(observed.stderr))
    # NUL-delimited names preserve spaces and newlines. lsof adds a newline
    # between process/file records, not inside their fields.
    seen, cwd_seen = _scan_lsof(path, observed.stdout)
    # A successful but empty/partial census is not evidence of idleness.
    if os.getpid() not in seen:
        raise _unavailable("census", "self-missing", observed=len(seen))
    missing = seen - cwd_seen
    if missing:
        # pid names the first process to inspect (`ps -p PID`); no command text.
        raise _unavailable("cwd", "missing", min(missing), missing=len(missing))


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
                raise _unavailable("parse", "orphan-name")
            name = Path(os.fsdecode(value))
            if descriptor == b"cwd" and name.is_absolute():
                cwd_seen.add(current_pid)
            if name == path or path in name.parents:
                raise ValueError("live-process-reference")
    return seen, cwd_seen


def _lsof_pid(value: bytes) -> int:
    if not value.isdigit():
        raise _unavailable("parse", "bad-pid")
    return int(value)
