# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Linux process/socket evidence for the orphan test-server guard."""

import os
from pathlib import Path


def proc_pids():
    return (int(root.name) for root in Path("/proc").iterdir() if root.name.isdigit())


def process_info(pid):
    root = Path(f"/proc/{pid}")
    if root.stat().st_uid != os.getuid():
        raise PermissionError("different user")
    fields = (root / "stat").read_text().rsplit(")", 1)[1].split()
    env = dict(item.split(b"=", 1) for item in (root / "environ").read_bytes().split(b"\0") if b"=" in item)
    return {
        "pid": pid, "ppid": int(fields[1]), "pgid": int(fields[2]),
        "tty": int(fields[4]), "started": int(fields[19]), "state": fields[0],
        "rss_kb": int(fields[21]) * os.sysconf("SC_PAGE_SIZE") // 1024, "env": env,
    }


def inventory():
    entries = {}
    for pid in proc_pids():
        try:
            entries[pid] = process_info(pid)
        except (OSError, ValueError, IndexError):
            continue
    return entries


def is_supervisor(pid):
    try:
        root = Path(f"/proc/{pid}")
        return root.stat().st_uid == os.getuid() and b"bounded-operation-supervisor.mjs" in (root / "cmdline").read_bytes()
    except FileNotFoundError:
        return False
    except OSError:
        return True  # Unavailable owner evidence protects the candidate.


def live_owner(info, _entries):
    env = info["env"]
    if not env.get(b"AIDEVOPS_OPERATION_ID"):
        return False
    owner = env.get(b"AIDEVOPS_OPERATION_OWNER_PID", b"")
    # Older operations lack owner markers: any same-user supervisor protects.
    candidates = [int(owner)] if owner.isdigit() else proc_pids()
    return any(is_supervisor(pid) for pid in candidates)


def socket_inodes(group):
    inodes = set()
    for info in group:
        for fd in Path(f"/proc/{info['pid']}/fd").iterdir():
            target = os.readlink(fd)
            if target.startswith("socket:["):
                inodes.add(target[8:-1])
    return inodes


def tcp_rows(pid):
    # Inspect the server's namespace rather than the guard's namespace.
    for protocol in ("tcp", "tcp6"):
        rows = Path(f"/proc/{pid}/net/{protocol}").read_text().splitlines()[1:]
        for row in rows:
            fields = row.split()
            yield int(fields[1].rsplit(":", 1)[1], 16), fields[3], fields[9]


def socket_status(group):
    inodes = socket_inodes(group)
    ports, established = set(), set()
    owned_connection = False
    for port, state, inode in tcp_rows(group[0]["pid"]):
        if state == "0A" and inode in inodes:
            ports.add(port)
        if state == "01":
            established.add(port)
            owned_connection = owned_connection or inode in inodes
    return ports, established, owned_connection


def listening_ports(group):
    ports, established, owned_connection = socket_status(group)
    return ports if not owned_connection and not ports.intersection(established) else set()
