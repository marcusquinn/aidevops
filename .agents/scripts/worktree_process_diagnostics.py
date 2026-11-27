#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Manual procfs diagnostics, never census clearance or removal authority."""

import os
from pathlib import Path


def diagnostic_name(process: Path) -> str:
    try:
        name = (process / "comm").read_text().strip()
    except (OSError, UnicodeError):
        return "unknown"
    return "".join(char for char in name if 32 <= ord(char) < 127)[:32] or "unknown"


def diagnostic_task(process: Path, task: Path) -> None:
    """Print unreadable CWD evidence, never treating foreign ownership as clearance."""
    try:
        os.readlink(task / "cwd")
        return
    except (FileNotFoundError, ProcessLookupError):
        return
    except OSError:
        pass
    try:
        fields = dict(line.split(":", 1) for line in
                      (task / "status").read_text(errors="surrogateescape").splitlines() if ":" in line)
    except (FileNotFoundError, ProcessLookupError):
        return
    except OSError:
        fields = {}
    if fields.get("State", "").split()[:1] in (["Z"], ["X"], ["x"]):
        return
    identities = fields.get("Uid", "").split()
    valid = len(identities) == 4 and all(value.isascii() and value.isdigit() for value in identities)
    uids = ",".join(identities) if valid else "unknown"
    foreign = valid and all(int(value) != os.geteuid() for value in identities)
    remedy = "foreign-review" if foreign else "unprivileged-review"
    print(f"{process.name}\t{diagnostic_name(task)}\t{remedy}\t{uids}\t{task.name}")


def unreadable_tasks(proc_root: Path) -> int:
    """Manual diagnostic only: all visible UIDs/threads, no attestation or sudo.

    Native retirement inspects each thread, whereas the CWD snapshot can skip
    foreign identities and attested tasks. Keep this listing independent of
    snapshot exclusions so a native refusal's PID/TID remains discoverable.
    """
    try:
        for process in sorted(proc_root.iterdir(), key=lambda item: item.name):
            if not process.name.isascii() or not process.name.isdigit():
                continue
            try:
                tasks = list((process / "task").iterdir())
            except (FileNotFoundError, ProcessLookupError):
                # Preserve a process-level diagnostic if its task inventory
                # vanishes mid-scan. Other enumeration failures stay failures.
                tasks = [process]
            for task in sorted(tasks, key=lambda item: item.name):
                diagnostic_task(process, task)
    except OSError:
        return 1
    return 0
