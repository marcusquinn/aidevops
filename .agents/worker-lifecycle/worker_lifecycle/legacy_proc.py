"""Fail-closed process checks for observation-era worktree retirement."""

from __future__ import annotations

from collections import Counter
from contextlib import contextmanager
from contextvars import ContextVar
import os
from pathlib import Path
import platform
import subprocess  # nosec B404 # fixed native observation command, no shell

from .process import ProcessIdentity


NON_HOLDER_DAEMONS = frozenset({
    "sshd", "ssh-agent", "gpg-agent", "(sd-pam)", "systemd", "dbus-daemon",
})
_observations: ContextVar[Counter | None] = ContextVar("legacy_proc_observations", default=None)


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
    current_pid = None
    descriptor = b""
    seen: set[int] = set()
    cwd_seen: set[int] = set()
    for field in observed.stdout.split(b"\0"):
        field = field.removeprefix(b"\n")
        if not field:
            continue
        if field[:1] == b"p":
            if not field[1:].isdigit():
                raise ValueError("proc-observation-unavailable")
            current_pid = int(field[1:])
            seen.add(current_pid)
            descriptor = b""
        elif field[:1] == b"f":
            descriptor = field[1:]
        elif field[:1] == b"n":
            name = Path(os.fsdecode(field[1:]))
            if current_pid is None:
                raise ValueError("proc-observation-unavailable")
            if descriptor == b"cwd" and name.is_absolute():
                cwd_seen.add(current_pid)
            if name == path or path in name.parents:
                raise ValueError("live-process-reference")
    # A successful but empty/partial census is not evidence of idleness.
    if os.getpid() not in seen or seen != cwd_seen:
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
            except FileNotFoundError:
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
    target = Path(os.readlink(reference).removesuffix(" (deleted)"))
    if target == path or path in target.parents:
        raise ValueError("live-process-reference")


def require_predating_daemon(path, task, proc):
    """Only exempt known non-holders proven older than this worktree's .git."""
    try:
        status = (task / "status").read_text(encoding="utf-8")
        fields = dict(line.split(":", 1) for line in status.splitlines() if ":" in line)
        if fields.get("Name", "").strip() not in NON_HOLDER_DAEMONS:
            raise ValueError("unknown-daemon")
        # comm may contain spaces and parentheses; field 3 follows the last ')'.
        stat = (task / "stat").read_text(encoding="utf-8")
        ticks = int(stat.rsplit(")", 1)[1].split()[19])
        boot = next(line.split()[1] for line in (proc / "stat").read_text(
            encoding="utf-8").splitlines() if line.startswith("btime "))
        boot_time = int(boot)
        frequency = os.sysconf("SC_CLK_TCK")
        if ticks < 0 or boot_time <= 0 or frequency <= 0:
            raise ValueError("invalid-process-clock")
        # btime is second-granularity and starttime is tick-granularity. Use an
        # upper bound so rounding cannot exempt a task created after the tree.
        latest_start = boot_time + 1 + (ticks + 1) / frequency
        if latest_start >= (path / ".git").stat().st_ctime:
            raise ValueError("daemon-not-older")
    except (OSError, ValueError, IndexError, StopIteration) as error:
        raise ValueError("proc-observation-unavailable") from error
    counts = _observations.get()
    if counts is not None:
        counts["skipped_nondumpable"] += 1


def inspect_proc_task(path, task, proc=Path("/proc")):
    try:
        if not live_owned_proc_task(task):
            return
        inspect_proc_references(path, task, proc)
    except FileNotFoundError:
        if task.exists():
            raise ValueError("proc-observation-unavailable") from None


def inspect_proc_references(path, task, proc):
    try:
        require_idle_reference(path, task / "cwd")
        for fd in (task / "fd").iterdir():
            try:
                require_idle_reference(path, fd)
            except FileNotFoundError:
                continue  # An independently closed descriptor grants no authority.
    except PermissionError:
        require_predating_daemon(path, task, proc)
