"""Opt-in evidence from a fixed, operator-installed Linux reference inspector.

No installation, sudo policy changes or process control occurs here. A response
describes one fresh census, not lifetime evidence or cleanup authorization.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import subprocess


INSPECTOR = Path("/usr/local/libexec/aidevops-worktree-cwd-inspect")
SUDO = Path("/usr/bin/sudo")
OPT_IN = "AIDEVOPS_PROTECTED_PROC_INSPECTION"


class ProcessCensusUnavailable(ValueError):
    """Stable refusal plus controlled, path-free details for the actual census."""

    def __init__(self, pid: int, tid: int, stage: str, cause: str) -> None:
        super().__init__("proc-observation-unavailable")
        self.observation = {"pid": pid, "tid": tid, "stage": stage, "cause": cause}


def _trusted_executable(path: Path) -> bool:
    """Reject writable replacements, including ancestor symlinks and directories."""
    if not path.is_absolute() or path.resolve(strict=True) != path:
        return False
    for item in (path, *path.parents):
        info = item.lstat()
        if info.st_uid != 0 or info.st_mode & 0o022:
            return False
        if not (stat.S_ISREG(info.st_mode) if item == path else stat.S_ISDIR(info.st_mode)):
            return False
    return os.access(path, os.X_OK)


def _allowed() -> bool:
    if os.environ.get(OPT_IN) != "1":
        return False
    if (os.environ.get("AIDEVOPS_WORKTREE_MAINTENANCE_PLAN")
            or os.environ.get("AIDEVOPS_WORKTREE_MAINTENANCE_CONFIRM")):
        return False
    fields = dict(line.split("=", 1) for line in
                  Path("/etc/os-release").read_text(encoding="utf-8").splitlines() if "=" in line)
    identifier = fields.get("ID", "").strip("\"'")
    return bool(identifier) and identifier != "nixos"


def _matches_report_identity(report: object, expected: dict[str, object]) -> bool:
    """Require the exact schema and integer identities, rejecting boolean aliases."""
    if not isinstance(report, dict) or set(report) != {*expected, "status"}:
        return False
    if any(type(report[key]) is not type(value) or report[key] != value
           for key, value in expected.items()):
        return False
    return all(type(value) is int for value in report["directory"])


def require_protected_references(path: Path, task: Path, proc: Path) -> None:
    """Require bound full-reference evidence; never accept legacy CWD output."""
    pid = task.parent.parent.name
    unavailable = ProcessCensusUnavailable(int(pid), int(task.name), "references", "inspector-unavailable")
    try:
        if proc != Path("/proc") or not _allowed():
            unavailable.observation["cause"] = "inspection-not-enabled"
            raise unavailable
        # Execute the validated resolved sudo binary, not an alternatives symlink
        # that might traverse a different path after validation.
        sudo = SUDO.resolve(strict=True)
        if not _trusted_executable(INSPECTOR) or not _trusted_executable(sudo):
            raise unavailable
        directory = path.lstat()
        process = proc / pid
        before = process.stat()
        start = int((process / "stat").read_text(encoding="ascii").rsplit(")", 1)[1].split()[19])
        result = subprocess.run(  # nosec B603 # validated root-owned executables, fixed flags, paths as argv only
            [str(sudo), "-n", "--", str(INSPECTOR), "--references", pid, str(path)],
            stdin=subprocess.DEVNULL, capture_output=True, timeout=3, check=False,
            env={"PATH": "/usr/bin:/bin", "LANG": "C"},
        )
        if result.returncode or result.stderr or len(result.stdout) > 4096:
            raise unavailable
        report = json.loads(result.stdout)
        after = process.stat()
        current_start = int((process / "stat").read_text(encoding="ascii").rsplit(")", 1)[1].split()[19])
        current_directory = path.lstat()
        expected = {"version": 1, "pid": int(pid), "start_ticks": start,
                    "directory": [directory.st_dev, directory.st_ino]}
        if not _matches_report_identity(report, expected):
            raise unavailable
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino) or start != current_start:
            raise unavailable
        if (directory.st_dev, directory.st_ino) != (current_directory.st_dev, current_directory.st_ino):
            raise unavailable
        status = report["status"]
        if status not in ("held", "clear"):
            raise unavailable
    except ProcessCensusUnavailable:
        raise
    except (OSError, subprocess.SubprocessError, IndexError, ValueError) as error:
        raise unavailable from error
    if status == "held":
        raise ValueError("live-process-reference")
