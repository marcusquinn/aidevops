"""Process-age and sshd-session helpers for legacy worktree holder checks."""

import os


_SSHD_NAMES = frozenset({"sshd", "sshd-session"})


def status_fields(status_file):
    text = status_file.read_text(encoding="utf-8")
    return dict(line.split(":", 1) for line in text.splitlines() if ":" in line)


def is_root_sshd_session(fields, task, proc):
    """GH#38997: an unprivileged sshd session forked by the root sshd listener.

    A same-UID process cannot reparent under a root-owned sshd, and sshd never
    changes into a worktree, so a login newer than the tree is not a holder.
    """
    if fields.get("Name", "").strip() not in _SSHD_NAMES:
        return False
    parent = fields.get("PPid", "").strip()
    if not parent.isdecimal() or int(parent) <= 1:
        return False
    try:
        parent_fields = status_fields(proc / parent / "status")
        if status_fields(task / "status").get("PPid", "").strip() != parent:
            return False
    except OSError:
        return False  # Unproven parent: fall through to the age check.
    uids = parent_fields.get("Uid", "").split()
    return (parent_fields.get("Name", "").strip() in _SSHD_NAMES and len(uids) == 4
            and set(uids) == {"0"})


def require_older_than_tree(path, task, proc):
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
