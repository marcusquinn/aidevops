#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Attest unreadable same-UID session tasks for the worktree census (GH#38428).

Only facts readable without dumpability are used, and each attestation needs a
fact the unprivileged user cannot forge. Mutable task names never attest a task.
"""

import os
from pathlib import Path

import worktree_lifetime_owner as owner

# Root-owned session daemons whose direct, never-exec'd, unprivileged child is
# the OpenSSH privilege-separated session process. The child inherits the
# daemon's "/" CWD; shells, scp and internal-sftp run in its descendants, which
# stay fully inspected. Only root can set a root-owned task's name.
PRIVSEP_SESSION_PARENTS = frozenset({"sshd", "sshd-session"})
PF_FORKNOEXEC = 0x40  # include/linux/sched.h: forked but never exec'd
# systemd forks "(sd-pam)" before the user manager execs; later children
# (units, adopted orphans) are attached after it and start after the manager.
PAM_KEEPER_START_WINDOW_SECONDS = 5
PROC = Path("/proc")  # Attestation root; tests substitute modelled kernel facts.


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
    """Same-UID systemd user manager that PID 1 exec'd from a root-owned binary.

    A dumpable manager exposes its executable. A non-dumpable one (systemd 254+
    grants it ambient capabilities) must hold capabilities in the census's own
    user namespace, which only a privileged launcher can grant; a process in a
    user-created child namespace has a different uid_map.
    """
    uid = str(os.getuid())
    if (fields[1] != "1" or status.get("Name", "").strip() != "systemd"
            or int(fields[6]) & PF_FORKNOEXEC or _uids(status) != [uid] * 4):
        return False
    service = f"/user.slice/user-{uid}.slice/user@{uid}.service"
    if not any(line.endswith((service, service + "/init.scope"))
               for line in (process / "cgroup").read_text().splitlines()):
        return False
    try:
        # stat() follows the magic link to the running inode, even after an upgrade.
        executable = os.stat(process / "exe")
    except PermissionError:
        return (int(status["CapEff"], 16) != 0 and
                (process / "uid_map").read_text() == (PROC / "self" / "uid_map").read_text())
    return executable.st_uid == 0 and not executable.st_mode & 0o022


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
    if _uids(status) != [uid] * 4 or not ppid.isdecimal():
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
