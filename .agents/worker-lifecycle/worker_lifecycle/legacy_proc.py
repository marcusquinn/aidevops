"""Fail-closed process checks for observation-era worktree retirement."""

from __future__ import annotations

from collections import Counter
from contextlib import contextmanager
from contextvars import ContextVar
import os
from pathlib import Path
import platform

from .legacy_proc_clock import is_root_sshd_session, require_older_than_tree, status_fields
from .legacy_proc_denied import inspect_denied_references
from .legacy_proc_macos import require_idle_macos
from .process import ProcessIdentity
from .protected_proc import OPT_IN, require_protected_references
from .protected_proc import ProcessCensusUnavailable as ProcessCensusUnavailable


NON_HOLDER_DAEMONS = frozenset({
    # OpenSSH's split session daemon retains the same non-dumpable role as sshd.
    "sshd", "sshd-session", "ssh-agent", "gpg-agent", "(sd-pam)", "systemd", "dbus-daemon",
})
_observations: ContextVar[Counter | None] = ContextVar("legacy_proc_observations", default=None)
# A task exiting mid-scan surfaces as ENOENT or, for open /proc entries, ESRCH.
# Callers still re-check existence so a present task keeps failing closed.
_VANISHED = (FileNotFoundError, ProcessLookupError)


@contextmanager
def collect_proc_observations():
    """Count skipped task observations (including repeated retirement checks)."""
    counts: Counter = Counter()
    token = _observations.set(counts)
    try:
        yield counts
    finally:
        _observations.reset(token)


def require_ended(item, adapter, *, operator_confirmed=False):
    for value in item["runs"].values():
        observed = adapter.observe(ProcessIdentity.from_dict(value))
        if observed.status != "ended":
            raise ValueError("process-" + observed.status)
    if not operator_confirmed and (not item["runs"] or item["unbound"]):
        raise ValueError("no-recorded-processes")


def require_idle_processes(path: Path) -> None:
    """Require a usable native census at the tree's current removal location."""
    system = platform.system()
    if system == "Linux":
        require_idle_proc(path)
    elif system == "Darwin":
        require_idle_macos(path)
    else:
        raise ValueError("proc-observation-unavailable")


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
            except _VANISHED:
                if process.exists():
                    raise ValueError("proc-observation-unavailable") from None
                continue
            for task in threads:
                inspect_proc_task(path, task, proc)
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
    raw = os.readlink(reference)
    targets = (Path(raw), Path(raw.removesuffix(" (deleted)")))
    if any(target == path or path in target.parents for target in targets):
        raise ValueError("live-process-reference")


def require_predating_daemon(path, task, proc):
    """Only exempt known non-holders proven older than this worktree's .git."""
    try:
        fields = status_fields(task / "status")
        if fields.get("Name", "").strip() not in NON_HOLDER_DAEMONS:
            raise ValueError("unknown-daemon")
        root_session = is_root_sshd_session(fields, task, proc)
        try:
            require_older_than_tree(path, task, proc)
            predates_tree = True
        except (OSError, ValueError, IndexError, StopIteration):
            if not root_session:
                raise
            predates_tree = False
    except (OSError, ValueError, IndexError, StopIteration) as error:
        raise ValueError("proc-observation-unavailable") from error
    # A root parent may pass a worktree log fd into the session.
    if root_session and not predates_tree and os.environ.get(OPT_IN) == "1":
        require_protected_references(path, task, proc)
    counts = _observations.get()
    if counts is not None:
        counts["skipped_nondumpable"] += 1


def inspect_proc_task(path, task, proc=Path("/proc")):
    try:
        if not live_owned_proc_task(task):
            return
        inspect_proc_references(path, task, proc)
    except _VANISHED:
        if task.exists():
            raise ValueError("proc-observation-unavailable") from None


def inspect_proc_references(path, task, proc):
    stage = "cwd"
    try:
        require_idle_reference(path, task / "cwd")
        stage = "fd"
        for fd in (task / "fd").iterdir():
            try:
                require_idle_reference(path, fd)
            except _VANISHED:
                continue  # An independently closed descriptor grants no authority.
    except PermissionError:
        inspect_denied_references(path, task, proc, stage,
                                  (require_predating_daemon, require_protected_references))
