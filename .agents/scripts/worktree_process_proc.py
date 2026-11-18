#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Unprivileged procfs evidence, collected once without per-PID subprocesses.

No process names are exemptions. Unknown same-user evidence remains degraded.
A denied same-user process is excluded only when every one of its threads passes
the lease census attestation (GH#38428), so the removal guard, the maintenance
boundary and the census agree on the same task (GH#39034). Attestation queries
PID 1 once per user-manager candidate; it never runs per-PID subprocesses.
This module observes processes; it neither manages tasks nor authorizes removal.
"""

import os
from pathlib import Path
import sys

import worktree_process_attestation as attestation
from worktree_process_census import require_proc_visibility


def attestation_enabled(proc_root: Path) -> bool:
    """Census preconditions: Linux, the attestation root, unfiltered same-namespace proc.

    The non-root and initial-user-namespace checks run per task inside
    attestation.session_class. Any failed precondition disables attestation, so
    every denied same-user process stays denied.
    """
    if sys.platform != "linux" or Path(proc_root) != attestation.PROC:
        return False
    try:
        require_proc_visibility()
    except (OSError, ValueError, IndexError):
        return False
    return True


def process_is_attested(process: Path) -> bool:
    """True only when every thread is an attested privileged-session task.

    Uses exactly the census predicate; an empty, unreadable or partly
    unattested thread list leaves the process denied.
    """
    try:
        tasks = list((process / "task").iterdir())
    except OSError:
        return False
    return bool(tasks) and all(attestation.session_class(task) for task in tasks)


def denied_process_is_irrelevant(process: Path, uid: int) -> bool:
    """Ignore only proven zombies, foreign identities, or vanished processes."""
    try:
        fields = dict(
            line.split(":", 1)
            for line in (process / "status").read_text(errors="surrogateescape").splitlines()
            if ":" in line
        )
    except (OSError, UnicodeError):
        try:
            return process.stat().st_uid != uid
        except FileNotFoundError:
            return True
        except OSError:
            return False
    if fields.get("State", "").strip().startswith("Z"):
        return True
    identities = fields.get("Uid", "").split()
    return (
        len(identities) == 4
        and all(value.isascii() and value.isdigit() for value in identities)
        and all(int(value) != uid for value in identities)
    )


def collect(proc_root: Path) -> tuple[list[str], list[Path]]:
    """Return readable CWDs and unresolved processes, never converting denials to absence."""
    paths: list[str] = []
    denied: list[Path] = []
    uid = os.getuid()
    attest = attestation_enabled(proc_root)
    with os.scandir(proc_root) as entries:
        for entry in entries:
            if not entry.name.isascii() or not entry.name.isdigit():
                continue
            process = Path(entry.path)
            try:
                target = os.readlink(process / "cwd")
            except OSError:
                if not denied_process_is_irrelevant(process, uid) and not (
                        attest and process_is_attested(process)):
                    denied.append(process)
                continue
            # The shell consumer uses a line protocol. Do not let unusual names
            # fabricate additional paths or turn a malformed snapshot complete.
            if not target.startswith("/") or any(ord(char) < 32 or ord(char) == 127 for char in target):
                denied.append(process)
                continue
            paths.append(target)
    return paths, denied


def diagnostic_name(process: Path) -> str:
    try:
        name = (process / "comm").read_text().strip()
    except (OSError, UnicodeError):
        return "unknown"
    return "".join(char for char in name if 32 <= ord(char) < 127)[:32] or "unknown"


def cwd_map_line(entry: os.DirEntry, attest: bool = False) -> str:
    """Classify one process: `R<TAB>pid<TAB>cwd`, `S<TAB>pid` (provably irrelevant), else `F<TAB>pid`.

    Every failed or unusual read is `F` so the shell caller applies its full
    denial/zombie/foreign-UID/privileged handling; nothing else is decided here.
    """
    try:
        target = os.readlink(os.path.join(entry.path, "cwd"))
    except OSError:
        # Same rule as the shell consumer: only vanished, zombie and provably
        # foreign-UID processes are skipped, plus (GH#39034) processes the
        # census attestation proves are privileged-session tasks; the rest stay F.
        process = Path(entry.path)
        irrelevant = denied_process_is_irrelevant(process, os.getuid()) or (
            attest and process_is_attested(process))
        return f"{'S' if irrelevant else 'F'}\t{entry.name}"
    if not target or any(ord(char) < 32 or ord(char) == 127 for char in target):
        return f"F\t{entry.name}"
    return f"R\t{entry.name}\t{target}"


def cwd_map(proc_root: Path) -> int:
    """Print one classified line per process, replacing a readlink fork each."""
    attest = attestation_enabled(proc_root)
    with os.scandir(proc_root) as entries:
        for entry in entries:
            if entry.name.isascii() and entry.name.isdigit():
                print(cwd_map_line(entry, attest))
    return 0


def main(arguments: list[str]) -> int:
    if len(arguments) == 2 and arguments[0] == "cwdmap":
        return run_cwd_map(Path(arguments[1]))
    return run_collect(arguments)


def run_cwd_map(proc_root: Path) -> int:
    try:
        return cwd_map(proc_root)
    except OSError:
        return 1


def run_collect(arguments: list[str]) -> int:
    if len(arguments) != 1 or arguments[0] not in ("paths", "denied"):
        return 1
    try:
        paths, denied = collect(Path("/proc"))
    except OSError:
        return 1
    if arguments[0] == "denied":
        for process in denied:
            print(f"{process.name}\t{diagnostic_name(process)}\tunprivileged-review")
        return 0
    for path in paths:
        print(path)
    return 2 if denied else (0 if paths else 1)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
