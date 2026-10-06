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

from orphan_test_server_proc import inventory, listening_ports, live_owner, process_info, proc_pids, socket_status


def test_marker(info):
    env = info["env"]
    return bool(env.get(b"PLAYWRIGHT_TEST") or env.get(b"AIDEVOPS_OPERATION_ID"))


def group_visible(pgid, entries):
    for pid in proc_pids():
        try:
            if os.getpgid(pid) == pgid and pid not in entries:
                return False
        except ProcessLookupError:
            continue
        except PermissionError:
            return False
    return True


def group_protected(group, entries):
    return any(member["tty"] or live_owner(member, entries) or not test_marker(member) for member in group)


def classify(info, entries, age_limit):
    if info["ppid"] != 1 or info["tty"] or info["pgid"] <= 1 or not test_marker(info):
        return None
    uptime = float(Path("/proc/uptime").read_text().split()[0])
    age = uptime - info["started"] / os.sysconf("SC_CLK_TCK")
    group = [entry for entry in entries.values() if entry["pgid"] == info["pgid"]]
    if age <= age_limit or not group_visible(info["pgid"], entries) or group_protected(group, entries):
        return None
    ports = listening_ports(group)
    if not ports:
        return None
    return {"pid": info["pid"], "pgid": info["pgid"], "ports": sorted(ports),
            "rss_kb": sum(member["rss_kb"] for member in group), "age_seconds": int(age)}


def same_identity(current, original):
    return current is not None and current["started"] == original["started"] and current["pgid"] == original["pgid"]


def kill_verified(survivor, original, entries):
    if original.get(survivor["pid"]) != survivor["started"] or live_owner(survivor, entries):
        return
    pidfd = os.pidfd_open(survivor["pid"])
    try:
        if same_identity(process_info(survivor["pid"]), survivor):
            signal.pidfd_send_signal(pidfd, signal.SIGKILL)
    finally:
        os.close(pidfd)


def escalate(candidate, entries):
    fresh = inventory()
    survivors = [entry for entry in fresh.values() if entry["pgid"] == candidate["pgid"] and entry["state"] != "Z"]
    if not survivors:
        return "reap"
    _, established, owned_connection = socket_status(survivors)
    if owned_connection or established.intersection(candidate["ports"]):
        return "term-only-connected"
    # A closed listener after TERM does not revoke start-identity ownership.
    original = {entry["pid"]: entry["started"] for entry in entries.values() if entry["pgid"] == candidate["pgid"]}
    for survivor in survivors:
        kill_verified(survivor, original, fresh)
    return "reap"


def reap_candidate(info, candidate, entries, age_limit):
    fresh = inventory()
    current = fresh.get(info["pid"])
    if not same_identity(current, info) or not classify(current, fresh, age_limit):
        return None
    # Revalidate group identity, all-member ownership and connectivity before TERM.
    os.killpg(info["pgid"], signal.SIGTERM)
    time.sleep(1)
    return escalate(candidate, entries)


def report_candidate(info, entries, age_limit, reap):
    candidate = classify(info, entries, age_limit)
    if not candidate:
        return False
    action = reap_candidate(info, candidate, entries, age_limit) if reap else "report"
    if action:
        print(json.dumps({"action": action, "class": "orphan-test-server", **candidate}), flush=True)
    return True


def scan(age_limit, reap=False):
    entries = inventory()
    seen = set()
    for info in entries.values():
        if info["pgid"] in seen:
            continue
        try:
            if report_candidate(info, entries, age_limit, reap):
                seen.add(info["pgid"])
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
