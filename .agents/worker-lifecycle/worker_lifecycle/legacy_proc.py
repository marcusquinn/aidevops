"""Fail-closed process checks for observation-era worktree retirement."""

import os
from pathlib import Path

from .process import ProcessIdentity


def require_ended(item, adapter, *, operator_confirmed=False):
    for value in item["runs"].values():
        observed = adapter.observe(ProcessIdentity.from_dict(value))
        if observed.status != "ended":
            raise ValueError("process-" + observed.status)
    if not operator_confirmed and (not item["runs"] or item["unbound"]):
        raise ValueError("no-recorded-processes")


def require_idle_proc(path, proc=Path("/proc")):
    """Inspect every Linux thread, including private cwd/fd tables, fail closed."""
    if not (proc / "self").exists():
        raise ValueError("proc-observation-unavailable")
    try:
        for process in proc.iterdir():
            if not process.name.isdecimal():
                continue
            try:
                threads = list((process / "task").iterdir())
            except FileNotFoundError:
                if process.exists():
                    raise ValueError("proc-observation-unavailable") from None
                continue
            for task in threads:
                inspect_proc_task(path, task)
    except (OSError, StopIteration) as error:
        raise ValueError("proc-observation-unavailable") from error


def live_owned_proc_task(task):
    # Non-dumpable same-UID tasks can have root-owned /proc directories.
    status = (task / "status").read_text(encoding="utf-8")
    fields = dict(line.split(":", 1) for line in status.splitlines() if ":" in line)
    if not fields.get("Uid") or not fields.get("State"):
        raise ValueError("proc-observation-unavailable")
    return (str(os.geteuid()) in fields["Uid"].split()
            and fields["State"].split()[0] not in ("Z", "X"))


def require_idle_reference(path, reference):
    target = Path(os.readlink(reference).removesuffix(" (deleted)"))
    if target == path or path in target.parents:
        raise ValueError("live-process-reference")


def inspect_proc_task(path, task):
    try:
        if not live_owned_proc_task(task):
            return
        require_idle_reference(path, task / "cwd")
        for fd in (task / "fd").iterdir():
            try:
                require_idle_reference(path, fd)
            except FileNotFoundError:
                continue  # An independently closed descriptor grants no authority.
    except FileNotFoundError:
        if task.exists():
            raise ValueError("proc-observation-unavailable") from None
