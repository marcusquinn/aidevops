#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Existing-owner identity and bounded direct-child transport, without decryption."""
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import time

from credential_lease_protocol import LIMIT, require


def _process_identity(pid):
    path = Path("/proc") / str(pid)
    require(path.stat().st_uid == os.getuid(), "process-owner")
    fields = (path / "stat").read_text().rsplit(")", 1)[1].split()
    require(fields[0] not in {"Z", "X"}, "process-stopped")
    return {"parent": int(fields[1]), "group": int(fields[2]), "started": fields[19]}


def assert_owned_ancestor(pid, started):
    """Prove a live same-user ancestor/group, not authority or a drain receipt."""
    require(sys.platform == "linux", "supervision-platform")
    require(type(pid) is int and pid > 1 and pid != os.getpid(), "process-owner")
    require(isinstance(started, str) and re.fullmatch(r"[0-9]+", started), "process-owner")
    require(os.getpgrp() == pid, "process-group")
    current = os.getpid()
    for _ in range(64):
        identity = _process_identity(current)
        require(identity["group"] == pid, "process-group")
        if current == pid:
            require(identity["started"] == started, "process-reused")
            return
        require(identity["parent"] > 1 and identity["parent"] != current, "process-ancestor")
        current = identity["parent"]
    raise ValueError("process-ancestor")


def _stop_direct_child(child):
    # The unreaped direct PID remains pinned. Its existing owner drains the GROUP.
    child.terminate()
    try:
        child.wait(timeout=1)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait(timeout=5)


def owned_child_output(command, cwd, environment, budget, received):
    child = None
    finished = False
    data = bytearray()
    try:
        child = subprocess.Popen(  # nosec B603 -- reviewed argv, no shell or new process group
            command, cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        require(os.getpgid(child.pid) == os.getpgrp(), "child-process-group")
        os.set_blocking(child.stdout.fileno(), False)
        deadline = time.monotonic() + budget
        eof = False
        while not received and time.monotonic() < deadline:
            if not eof and select.select([child.stdout], [], [], 0.05)[0]:
                part = os.read(child.stdout.fileno(), 4096)
                eof = not part
                data.extend(part)
                if len(data) > LIMIT:
                    break
            elif eof:
                time.sleep(0.05)
            exited = os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            if eof and exited is not None:
                require(os.getpgid(child.pid) == os.getpgrp(), "child-process-group")
                code = child.wait(timeout=5)
                finished = True
                return bytes(data), code
        return None, None
    finally:
        if child is not None:
            try:
                if not finished:
                    _stop_direct_child(child)
            finally:
                child.stdout.close()
