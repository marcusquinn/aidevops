#!/usr/bin/python3 -I
"""Inspect same-user Linux process references for the worktree removal guard.

Install a root-owned copy with a single-executable sudoers rule. Never run
this from a writable worktree through sudo. Legacy output is a CWD path;
--cwds applies that same per-PID read to several PIDs in one call;
--references (one PID) and --census (all invoker tasks, counts only) emit
bound census evidence, never deletion authority.

The interpreter is deliberately absolute, not `/usr/bin/env python3`: this
runs as root via sudo, where an env lookup could follow the caller's PATH.
The installing operator rewrites line 1 to the root-owned python3 of the host
(see reference/worktree-cwd-visibility.md).
"""

import functools
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys


def uid_fields_accepted(values: list, sudo_uid: int) -> bool:
    """Return True when a /proc Uid: line belongs to the invoking user.

    The real UID must be the invoking user. Effective, saved and filesystem
    UIDs may be that user or root, which covers same-user setuid-root helpers
    such as `fusermount3 auto_unmount` or an open `sudo` parent (GH#32871).
    Any other UID, including a root real UID, is another identity.
    """
    uids = parse_uids(values)
    return sudo_uid > 0 and uids[0] == sudo_uid and all(uid in (sudo_uid, 0) for uid in uids[1:])


def parse_uids(values: list) -> list:
    """Real, effective, saved and filesystem UIDs; [-1] (no valid UID) when malformed."""
    if not re.fullmatch(r"[0-9]+( [0-9]+){3}", " ".join(values)):
        return [-1]
    return [int(value) for value in values]


def owned_by_invoker(pid: str, sudo_uid: int) -> bool:
    with open(f"/proc/{pid}/status", encoding="ascii") as status:
        for line in status:
            if line.startswith("Uid:\t"):
                return uid_fields_accepted(line.split()[1:], sudo_uid)
    raise ValueError("process UID is unavailable")


def task_identity(task: Path, sudo_uid: int) -> tuple:
    """Bind a permitted task to its inode and kernel start time, never its name."""
    before = task.stat()
    fields = dict(line.split(":", 1) for line in
                  (task / "status").read_text(encoding="ascii").splitlines() if ":" in line)
    if not uid_fields_accepted(fields.get("Uid", "").split(), sudo_uid):
        raise ValueError("process owner does not match the invoking user")
    start = int((task / "stat").read_text(encoding="ascii").rsplit(")", 1)[1].split()[19])
    after = task.stat()
    if start < 0 or (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
        raise ValueError("process identity changed during inspection")
    return after.st_dev, after.st_ino, start


def directory_identity(candidate: Path, sudo_uid: int) -> tuple:
    """Only inspect a canonical directory owned by the invoking user."""
    if not candidate.is_absolute() or candidate.resolve(strict=True) != candidate:
        raise ValueError("canonical candidate required")
    info = candidate.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != sudo_uid:
        raise ValueError("candidate owner does not match the invoking user")
    return info.st_dev, info.st_ino


def safe_text(text: str) -> bool:
    """Bounded text without control characters."""
    return len(text) <= 4096 and not any(ord(character) < 32 or ord(character) == 127 for character in text)


def names_candidate(text: str, candidate: Path) -> bool:
    # The suffix can be a literal filename, not only a kernel annotation.
    targets = (Path(text), Path(text.removesuffix(" (deleted)")))
    return any(target == candidate or candidate in target.parents for target in targets)


def link_texts(task: Path):
    """Yield a task's CWD and open-descriptor targets."""
    yield os.readlink(task / "cwd")
    for descriptor in (task / "fd").iterdir():
        try:
            yield os.readlink(descriptor)
        except FileNotFoundError:
            continue  # Independently closed descriptor; the task identity is rechecked.


def reference_report(pid: str, candidate_text: str, sudo_uid: int) -> dict:
    """Observe all task CWD/fd tables; emit no paths or descriptor contents."""
    if not re.fullmatch(r"[1-9][0-9]*", pid) or not safe_text(candidate_text):
        raise ValueError("invalid reference request")
    candidate = Path(candidate_text)
    directory = directory_identity(candidate, sudo_uid)
    process = Path("/proc") / pid
    identity = task_identity(process, sudo_uid)
    tasks = list((process / "task").iterdir())
    if not tasks or any(not task.name.isdecimal() for task in tasks):
        raise ValueError("thread inventory unavailable")
    identities = {task.name: task_identity(task, sudo_uid) for task in tasks}
    # Every task is read (a list, not a generator); a match only ends that task's scan.
    held = any([any(names_candidate(text, candidate) for text in link_texts(task)) for task in tasks])
    after = {task.name: task_identity(task, sudo_uid)
             for task in (process / "task").iterdir()}
    if (after != identities or task_identity(process, sudo_uid) != identity
            or directory_identity(candidate, sudo_uid) != directory):
        raise ValueError("reference identities changed during inspection")
    return {"version": 1, "pid": int(pid), "start_ticks": identity[2],
            "directory": list(directory), "status": "held" if held else "clear"}


def reference_texts(task: Path):
    """Yield what the unprivileged census matches: CWD, descriptors, worktree env."""
    yield from link_texts(task)
    for entry in (task / "environ").read_bytes().split(b"\0"):
        key, separator, value = entry.partition(b"=")
        if separator and key in (b"PWD", b"AIDEVOPS_WORKTREE"):
            yield os.fsdecode(value)


def stat_fields(task: Path) -> list:
    """Fields after the mutable comm: index 0 is the state, 19 the start time."""
    return (task / "stat").read_text(encoding="ascii").rsplit(")", 1)[1].split()


def task_outcome(task: Path, candidate: Path, sudo_uid: int) -> list:
    """Return [held|clear|uncertain] for an invoker task; [] for foreign or ended tasks."""
    (uids,) = [parse_uids(line.split()[1:]) for line in
               (task / "status").read_text(encoding="ascii").splitlines() if line.startswith("Uid:")]
    if -1 in uids:
        raise ValueError("task UID unavailable")
    # Mirror the unprivileged census: the invoker in any of the four UID fields.
    if sudo_uid not in uids:
        return []
    fields = stat_fields(task)
    if fields[0] in ("Z", "X"):
        return []
    held = any(names_candidate(text, candidate) for text in reference_texts(task))
    return ["held" if held else "clear" if stat_fields(task)[19] == fields[19] else "uncertain"]


def guarded(path: Path, observe) -> list:
    """Vanished paths ended; any other unreadable state stays uncertain."""
    try:
        return observe()
    except FileNotFoundError:
        return ["uncertain" if os.path.lexists(path) else "ended"]
    except (OSError, ValueError, IndexError):
        return ["uncertain"]


def process_outcomes(process: Path, candidate: Path, sudo_uid: int) -> list:
    """Every thread is inspected: unshared CWD and descriptor tables can differ."""
    return guarded(process, lambda: [
        outcome for task in list((process / "task").iterdir())
        for outcome in guarded(task, functools.partial(task_outcome, task, candidate, sudo_uid))])


PROC_MOUNT = re.compile(r"\S+ \S+ \S+ \S+ /proc (\S+) .*?- (\S+) \S+ (\S+)")
FILTERED_PROC_OPTION = re.compile(r"hidepid=(?!(?:0|off)$).*|subset=.*")


def require_full_proc_view() -> None:
    """Refuse a proc from another PID namespace or a filtered mount: hidden tasks are never clear.

    Like the unprivileged census, this counts the census's own PID namespace;
    processes in other namespaces (such as a host sharing a bind-mounted tree)
    are outside both views, so this result adds no visibility either lacks.
    """
    namespace_pids = re.findall(r"^NSpid:\s+(.+)$",
                                Path("/proc/self/status").read_text(encoding="ascii"), re.M)
    mounts = [match.groups() for match in map(
        PROC_MOUNT.fullmatch, Path("/proc/self/mountinfo").read_text(encoding="utf-8").splitlines())
        if match]
    options = ",".join(mount[0] + "," + mount[2] for mount in mounts).split(",")
    if (namespace_pids != [str(os.getpid())] or [mount[1] for mount in mounts] != ["proc"]
            or any(map(FILTERED_PROC_OPTION.fullmatch, options))):
        raise ValueError("partial proc view")


def census_report(candidate_text: str, sudo_uid: int) -> dict:
    """Count the invoker's task references to one tree; emit counts only (GH#38428)."""
    if not safe_text(candidate_text):
        raise ValueError("invalid census request")
    require_full_proc_view()
    candidate = Path(candidate_text)
    directory = directory_identity(candidate, sudo_uid)
    processes = [process for process in Path("/proc").iterdir() if process.name.isdecimal()]
    outcomes = [outcome for process in processes
                for outcome in process_outcomes(process, candidate, sudo_uid)]
    if (str(os.getpid()) not in {process.name for process in processes}
            or directory_identity(candidate, sudo_uid) != directory):
        raise ValueError("census identities changed during inspection")
    return {"version": 1, "mode": "census", "directory": list(directory),
            "references": outcomes.count("held"), "uncertain": outcomes.count("uncertain")}


def bounded_report(deadline: int, build) -> int:
    """Bound the privileged child itself, not only its sudo parent's wait.

    Only a completed response is printed, so a deadline never leaves partial output.
    """
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.alarm(deadline)
    try:
        text = build()
    finally:
        signal.alarm(0)
    print(text)
    return 0


def json_text(report: dict) -> str:
    """Stable JSON for the --references and --census reports."""
    return json.dumps(report, sort_keys=True)


CWDS_MAX_PIDS = 4096
PID_TEXT = re.compile(r"[1-9][0-9]*")


def legacy_cwd(pid: str, invoker_uid: int) -> str:
    """One same-user process CWD: stable identity, safe absolute path, else ValueError/OSError."""
    if not PID_TEXT.fullmatch(pid):
        raise ValueError("invalid inspector arguments")
    proc_dir = f"/proc/{pid}"
    before = os.stat(proc_dir, follow_symlinks=False)
    if not owned_by_invoker(pid, invoker_uid):
        raise ValueError("process owner does not match the invoking user")
    cwd = os.readlink(f"{proc_dir}/cwd")
    after = os.stat(proc_dir, follow_symlinks=False)
    if (before.st_ino != after.st_ino or not owned_by_invoker(pid, invoker_uid)
            or not cwd.startswith("/") or not safe_text(cwd)):
        raise ValueError("process changed or its CWD is not a safe absolute path")
    return cwd


def cwd_record(pid: str, invoker_uid: int) -> str:
    """`R` with exactly what `<pid>` mode would print, else an opaque `F`."""
    try:
        cwd = legacy_cwd(pid, invoker_uid)
        cwd.encode("utf-8")  # An unprintable CWD fails only its own PID, not the batch.
    except (OSError, ValueError, IndexError):
        return f"F\t{pid}"
    return f"R\t{pid}\t{cwd}"


def cwds_report(pids: list, invoker_uid: int) -> str:
    """Apply the legacy single-PID read to each PID in one invocation (GH#38918).

    Discloses nothing beyond legacy mode. Every PID must be distinct and well
    formed before any read; the header and trailer let the caller reject an
    incomplete response.
    """
    if not 0 < len(set(filter(PID_TEXT.fullmatch, pids))) == len(pids) <= CWDS_MAX_PIDS:
        raise ValueError("invalid batch request")
    return "\n".join([f"aidevops-cwd-inspect\tcwds\t1\t{len(pids)}",
                      *(cwd_record(pid, invoker_uid) for pid in pids), f"end\t{len(pids)}"])


def main() -> int:
    try:
        sudo_uid = os.environ.get("SUDO_UID", "")
        if os.geteuid() != 0 or not re.fullmatch(r"[1-9][0-9]*", sudo_uid):
            raise ValueError("privileged invocation by a valid invoking identity is required")
        # Each mode unpacks its exact arguments: a wrong count raises ValueError.
        if sys.argv[1:2] == ["--references"]:
            pid, candidate = sys.argv[2:]
            return bounded_report(2, lambda: json_text(reference_report(pid, candidate, int(sudo_uid))))
        if sys.argv[1:2] == ["--census"]:
            (candidate,) = sys.argv[2:]
            return bounded_report(5, lambda: json_text(census_report(candidate, int(sudo_uid))))
        if sys.argv[1:2] == ["--cwds"]:  # An empty PID list is refused by cwds_report.
            return bounded_report(5, functools.partial(cwds_report, sys.argv[2:], int(sudo_uid)))
        (pid,) = sys.argv[1:]  # Legacy mode takes exactly one PID; anything else raises ValueError.
        cwd = legacy_cwd(pid, int(sudo_uid))
    except (OSError, ValueError, IndexError):
        return 1
    print(cwd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
