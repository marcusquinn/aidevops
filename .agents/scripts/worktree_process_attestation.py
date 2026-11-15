#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Attest unreadable same-UID session tasks for the worktree census (GH#38428).

Only facts readable without dumpability are used, and each attestation needs a
fact the unprivileged user cannot forge. Mutable task names never attest a task.
"""

import os
from pathlib import Path
import subprocess  # nosec B404 - fixed root-owned systemctl, empty environment

import worktree_lifetime_owner as owner

# Root-owned session daemons whose direct, never-exec'd, unprivileged child is
# the OpenSSH privilege-separated session process. The child inherits the
# daemon's "/" CWD; shells, scp and internal-sftp run in its descendants, which
# stay fully inspected. A root-owned name is weaker evidence than it looks:
# exec'ing a setuid-root binary through a symlink also sets it.
PRIVSEP_SESSION_PARENTS = frozenset({"sshd", "sshd-session"})
PF_FORKNOEXEC = 0x40  # include/linux/sched.h: forked but never exec'd
# systemd forks "(sd-pam)" before the user manager execs; later children
# (units, adopted orphans) are attached after it and start after the manager.
PAM_KEEPER_START_WINDOW_SECONDS = 5
PROC = Path("/proc")  # Attestation root; tests substitute modelled kernel facts.
INITIAL_UID_MAP = ["0", "0", "4294967295"]
SYSTEMCTL_PATHS = ("/usr/bin/systemctl", "/bin/systemctl")
SYSTEMCTL_TIMEOUT_SECONDS = 5


def _root_owned_file(path):
    """True when path and its directory are root-owned and not group/other-writable."""
    for candidate in (path, os.path.dirname(path)):
        info = os.stat(candidate)
        if info.st_uid != 0 or info.st_mode & 0o022:
            return False
    return True


def user_manager_main_pid(uid):
    """PID 1's own record of the user manager's PID, or None when unavailable.

    Names, cgroups (delegated to the user) and executables (any root-owned
    binary) are all user-influenced; only the system manager knows which
    process it started for user@UID.service. MainPID alone can be repointed by
    a MAINPID= notification, so the PID it exec'd (ExecMainPID) must agree.
    """
    for path in SYSTEMCTL_PATHS:
        try:
            if not _root_owned_file(path):
                return None
        except FileNotFoundError:
            continue
        try:
            result = subprocess.run(  # nosec B603 - absolute root-owned binary, no shell
                [path, "show", "--property=MainPID", "--property=ExecMainPID", "--value",
                 f"user@{uid}.service"],
                env={}, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                timeout=SYSTEMCTL_TIMEOUT_SECONDS, check=False)
        except (OSError, subprocess.SubprocessError):
            return None
        values = result.stdout.split()
        if result.returncode or len(values) != 2 or len(set(values)) != 1:
            return None
        return values[0] if values[0].isdecimal() and values[0] != "0" else None
    return None


def _system_manager_is_pid_1():
    """systemctl's answer names PIDs in our namespace only if our PID 1 is systemd."""
    status = _status_fields(PROC / "1")
    return status.get("Name", "").strip() == "systemd" and _uids(status) == ["0"] * 4


def _initial_user_namespace(*processes):
    """Root and UID facts only mean what they say in the initial user namespace."""
    return all((process / "uid_map").read_text().split() == INITIAL_UID_MAP
               for process in (PROC / "self", *processes))


def _stat_fields(directory):
    """Return stat fields after the (mutable) comm: index 0 is the state."""
    return (directory / "stat").read_text().rsplit(")", 1)[1].split()


def _status_fields(directory):
    return dict(line.split(":", 1) for line in (directory / "status").read_text().splitlines()
                if ":" in line)


def _uids(status):
    values = status.get("Uid", "").split()
    owner.require(len(values) == 4 and all(map(str.isdecimal, values)), "task UID unavailable")
    return values


def _is_user_manager(process, status, fields):
    """Same-UID, exec'd child of PID 1 that PID 1 records as user@UID.service.

    Callers re-read the task's start time after this returns, so the PID that
    PID 1 named is the same process before and after the query.
    """
    uid = str(os.getuid())
    if (fields[1] != "1" or int(fields[6]) & PF_FORKNOEXEC or _uids(status) != [uid] * 4
            or not _system_manager_is_pid_1()):
        return False
    return user_manager_main_pid(uid) == process.name


def _attested_child_class(pid, ppid, start):
    """Classify a never-exec'd child by the parent that forked it, or None."""
    parent = PROC / ppid
    parent_fields, parent_status = _stat_fields(parent), _status_fields(parent)
    parent_start = int(parent_fields[19])
    if parent_start > start:
        return None, parent_start  # The parent PID was reused after this task started.
    if (_uids(parent_status) == ["0"] * 4
            and parent_status.get("Name", "").strip() in PRIVSEP_SESSION_PARENTS):
        return "privsep-session", parent_start
    if (_is_user_manager(parent, parent_status, parent_fields)
            and start - parent_start <= PAM_KEEPER_START_WINDOW_SECONDS * os.sysconf("SC_CLK_TCK")
            and (parent / "task" / ppid / "children").read_text().split()[:1] == [pid]):
        return "pam-session-keeper", parent_start
    return None, parent_start


def attested_session_class(task):
    """Return the attested privileged-session class of an unreadable task, or None.

    Attested: the user manager itself; a never-exec'd child (so it runs its
    parent's code) of a root-owned privilege-separation daemon; or the
    first-attached, never-exec'd child that the user manager forked before its
    exec. Anything else, including any task name, leaves the task uncertain.
    """
    uid = str(os.getuid())
    if uid == "0":
        return None  # Root-owned facts only attest against an unprivileged census user.
    process = task.parent.parent
    fields, status = _stat_fields(task), _status_fields(task)
    ppid, start = fields[1], int(fields[19])
    if (_uids(status) != [uid] * 4 or not ppid.isdecimal()
            or not _initial_user_namespace(process, *([PROC / ppid] if int(ppid) > 0 else []))):
        return None
    parent_start = None
    if _is_user_manager(process, status, fields):
        attested = "user-manager"
    elif (int(status["CapEff"], 16) or int(status["CapPrm"], 16)
          or not int(fields[6]) & PF_FORKNOEXEC or int(ppid) <= 1):
        return None
    else:
        attested, parent_start = _attested_child_class(process.name, ppid, start)
    owner.require(_stat_fields(task)[1] == ppid and int(_stat_fields(task)[19]) == start and
                  (parent_start is None or int(_stat_fields(PROC / ppid)[19]) == parent_start),
                  "process changed during attestation")
    return attested


def session_class(task):
    """Fail closed: any unreadable or changing fact leaves the task unattested."""
    try:
        return attested_session_class(task)
    except (OSError, ValueError, IndexError, KeyError):
        return None
