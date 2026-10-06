#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fail-closed Linux orphan test-server inventory; report-only unless --reap.

Only same-user, non-interactive, PID-1-parented process groups with explicit
test/operation evidence qualify. Missing process/socket visibility protects the
group. Environment contents are never emitted. No third-party dependencies.
"""

import argparse
import json
import os
from pathlib import Path
import signal
import sys
import time


def process_info(pid):
    """Read identity using kernel start ticks, not mutable command text."""
    root = Path(f"/proc/{pid}")
    if root.stat().st_uid != os.getuid():
        raise PermissionError("different user")
    fields = (root / "stat").read_text().rsplit(")", 1)[1].split()
    env = dict(item.split(b"=", 1) for item in (root / "environ").read_bytes().split(b"\0") if b"=" in item)
    return {
        "pid": pid, "ppid": int(fields[1]), "pgid": int(fields[2]),
        "tty": int(fields[4]), "started": int(fields[19]), "state": fields[0],
        "rss_kb": int(fields[21]) * os.sysconf("SC_PAGE_SIZE") // 1024,
        "env": env,
    }


def inventory():
    entries = {}
    for root in Path("/proc").iterdir():
        if root.name.isdigit():
            try:
                info = process_info(int(root.name))
                entries[info["pid"]] = info
            except (OSError, ValueError, IndexError):
                continue
    return entries


def live_owner(info, entries):
    env = info["env"]
    operation = env.get(b"AIDEVOPS_OPERATION_ID")
    if not operation:
        return False
    owner = env.get(b"AIDEVOPS_OPERATION_OWNER_PID", b"")
    # Older operations lack the owner marker. Any live supervisor conservatively
    # protects them rather than inferring expiry from missing ledger data.
    candidates = [int(owner)] if owner.isdigit() else (int(root.name) for root in Path("/proc").iterdir() if root.name.isdigit())
    for pid in candidates:
        try:
            root = Path(f"/proc/{pid}")
            if root.stat().st_uid != os.getuid():
                continue
            if b"bounded-operation-supervisor.mjs" in (root / "cmdline").read_bytes():
                return True
        except FileNotFoundError:
            continue
        except OSError:
            return True
    return False


def socket_status(group):
    inodes = set()
    for info in group:
        for fd in Path(f"/proc/{info['pid']}/fd").iterdir():
            target = os.readlink(fd)
            if target.startswith("socket:["):
                inodes.add(target[8:-1])
    ports = set()
    established = set()
    owned_connection = False
    # Use the server's network namespace, not the guard's.
    for protocol in ("tcp", "tcp6"):
        rows = Path(f"/proc/{group[0]['pid']}/net/{protocol}").read_text().splitlines()[1:]
        for row in rows:
            fields = row.split()
            port = int(fields[1].rsplit(":", 1)[1], 16)
            if fields[3] == "0A" and fields[9] in inodes:
                ports.add(port)
            if fields[3] == "01":
                established.add(port)
                if fields[9] in inodes:
                    owned_connection = True
    return ports, established, owned_connection


def listening_ports(group):
    ports, established, owned_connection = socket_status(group)
    return ports if not owned_connection and not ports.intersection(established) else set()


def classify(info, entries, age_limit):
    if info["ppid"] != 1 or info["tty"] or info["pgid"] <= 1:
        return None
    env = info["env"]
    if not (env.get(b"PLAYWRIGHT_TEST") or env.get(b"AIDEVOPS_OPERATION_ID")):
        return None
    uptime = float(Path("/proc/uptime").read_text().split()[0])
    age = uptime - info["started"] / os.sysconf("SC_CLK_TCK")
    if age <= age_limit:
        return None
    group = [entry for entry in entries.values() if entry["pgid"] == info["pgid"]]
    # Every member must be visible, attributable and non-interactive. A new or
    # inaccessible member invalidates group-wide signals, including SIGKILL.
    for root in Path("/proc").iterdir():
        if not root.name.isdigit():
            continue
        try:
            pid = int(root.name)
            if os.getpgid(pid) == info["pgid"] and pid not in entries:
                return None
        except ProcessLookupError:
            continue
        except PermissionError:
            return None
    for member in group:
        marker = member["env"]
        if member["tty"] or live_owner(member, entries):
            return None
        if not (marker.get(b"PLAYWRIGHT_TEST") or marker.get(b"AIDEVOPS_OPERATION_ID")):
            return None
    ports = listening_ports(group)
    if not ports:
        return None
    return {"pid": info["pid"], "pgid": info["pgid"], "ports": sorted(ports),
            "rss_kb": sum(member["rss_kb"] for member in group), "age_seconds": int(age)}


def scan(age_limit, reap=False):
    entries = inventory()
    seen = set()
    for info in entries.values():
        if info["pgid"] in seen:
            continue
        try:
            candidate = classify(info, entries, age_limit)
            if not candidate:
                continue
            seen.add(info["pgid"])
            if reap:
                # Revalidate identity, connectivity, ownership and group members
                # immediately before each destructive signal.
                fresh = inventory()
                current = fresh.get(info["pid"])
                if not current or current["started"] != info["started"] or current["pgid"] != info["pgid"] or not classify(current, fresh, age_limit):
                    continue
                os.killpg(info["pgid"], signal.SIGTERM)
                time.sleep(1)
                fresh = inventory()
                survivors = [entry for entry in fresh.values() if entry["pgid"] == info["pgid"] and entry["state"] != "Z"]
                original = {entry["pid"]: entry["started"] for entry in entries.values() if entry["pgid"] == info["pgid"]}
                if survivors:
                    _, established, owned_connection = socket_status(survivors)
                    if owned_connection or established.intersection(candidate["ports"]):
                        print(json.dumps({"action": "term-only-connected", **candidate}), flush=True)
                        continue
                # After TERM the listener may close; only signal individually
                # identity-verified survivors, never a reused/new process group.
                for survivor in survivors:
                    if original.get(survivor["pid"]) == survivor["started"] and not live_owner(survivor, fresh):
                        pidfd = os.pidfd_open(survivor["pid"])
                        try:
                            verified = process_info(survivor["pid"])
                            if verified["started"] == survivor["started"] and verified["pgid"] == info["pgid"]:
                                signal.pidfd_send_signal(pidfd, signal.SIGKILL)
                        finally:
                            os.close(pidfd)
            print(json.dumps({"action": "reap" if reap else "report", "class": "orphan-test-server", **candidate}), flush=True)
        except (OSError, ValueError, IndexError):
            continue


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--age-limit", type=int, default=7200)
    parser.add_argument("--reap", action="store_true")
    args = parser.parse_args()
    if args.age_limit < 0:
        parser.error("age limit must be non-negative")
    if sys.platform == "linux":
        scan(args.age_limit, args.reap)
    return 0


if __name__ == "__main__":
    sys.exit(main())
