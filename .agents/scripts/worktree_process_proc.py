#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Unprivileged procfs evidence, collected once without per-PID subprocesses.

No process names are exemptions. Unknown same-user evidence remains degraded.
This module observes processes; it neither manages tasks nor authorizes removal.
"""

import os
from pathlib import Path
import sys


def denied_process_is_irrelevant(process: Path, uid: int) -> bool:
    """Ignore only proven zombies, foreign identities, or vanished processes."""
    try:
        fields = dict(
            line.split(":", 1)
            for line in (process / "status").read_text().splitlines()
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
    with os.scandir(proc_root) as entries:
        for entry in entries:
            if not entry.name.isascii() or not entry.name.isdigit():
                continue
            process = Path(entry.path)
            try:
                target = os.readlink(process / "cwd")
            except OSError:
                if not denied_process_is_irrelevant(process, uid):
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


def cwd_map(proc_root: Path) -> int:
    """Print `R<TAB>pid<TAB>cwd` (readable), `S<TAB>pid` (provably irrelevant), else `F<TAB>pid`.

    Replaces one readlink fork per process for the shell provider. Every failed
    or unusual read is reported as `F` so the caller applies its full
    denial/zombie/foreign-UID/privileged handling; nothing is decided here.
    """
    with os.scandir(proc_root) as entries:
        for entry in entries:
            if not entry.name.isascii() or not entry.name.isdigit():
                continue
            try:
                target = os.readlink(os.path.join(entry.path, "cwd"))
            except OSError:
                # Same rule as the shell consumer: only vanished, zombie and
                # provably foreign-UID processes are skipped here; the rest stay F.
                irrelevant = denied_process_is_irrelevant(Path(entry.path), os.getuid())
                print(f"{'S' if irrelevant else 'F'}\t{entry.name}")
                continue
            if not target or any(ord(char) < 32 or ord(char) == 127 for char in target):
                print(f"F\t{entry.name}")
                continue
            print(f"R\t{entry.name}\t{target}")
    return 0


def main(arguments: list[str]) -> int:
    if len(arguments) == 2 and arguments[0] == "cwdmap":
        try:
            return cwd_map(Path(arguments[1]))
        except OSError:
            return 1
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
