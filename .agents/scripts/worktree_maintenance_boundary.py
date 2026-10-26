#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate an operator-established Linux maintenance window; never establish one.

This is present-tense maintenance evidence, NOT historical managed admission.
No privilege escalation, service stops, exemptions for process names, or registry
mutations are performed here. Unsupported/incomplete observations refuse apply.
"""

import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def system_unit(name):
    executable = shutil.which("systemctl")
    require(executable is not None, "maintenance:systemctl-unavailable")
    root_controlled(executable)
    properties = "Id,LoadState,ActiveState,SubState,MainPID,InvocationID,ControlGroup,User,KillMode,Restart,Conflicts,Before,FragmentPath"
    # Root-controlled executable, fixed observation arguments, no shell interpretation.
    result = subprocess.run(  # nosec B603
        [executable, "--system", "show", name, "--no-pager", "--no-ask-password", "--property=" + properties],
        capture_output=True, text=True, timeout=10, check=True,
        # Do not let a caller-supplied D-Bus address or loader variables turn a
        # root-controlled system service observation into user-supplied output.
        env={"PATH": os.defpath, "LC_ALL": "C"})
    return dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)


def trusted_path(path, depth=0):
    """Follow root-controlled Nix store links, checking every link's ancestry."""
    path = Path(path)
    require(path.is_absolute() and depth < 16, "maintenance:untrusted-control-path")
    for entry in (path, *path.parents):
        info = entry.lstat()
        require(info.st_uid == 0, "maintenance:untrusted-control-file")
        if stat.S_ISLNK(info.st_mode):
            target = Path(os.readlink(entry))
            trusted_path(target if target.is_absolute() else entry.parent / target, depth + 1)
        else:
            # Nix stores commonly use root:nixbld 1775. Sticky directories do
            # not let another UID replace the existing root-owned descendants
            # checked above. Writable regular files never gain this exception.
            protected_directory = stat.S_ISDIR(info.st_mode) and info.st_mode & stat.S_ISVTX
            require(not info.st_mode & 0o022 or protected_directory,
                    "maintenance:untrusted-control-file")


def root_controlled(path):
    """Require an existing regular file and non-replaceable ancestry."""
    path = Path(path)
    trusted_path(path)
    require(path.is_file(), "maintenance:missing-control-file")


def process_group(process):
    values = [line[3:] for line in (process / "cgroup").read_text().splitlines()
              if line.startswith("0::")]
    require(len(values) == 1, "maintenance:cgroup-v2-required")
    return values[0]


def require_exclusive_user(group):
    """Every process bearing this UID must be inside the maintenance service.

    Check all UID fields, including setuid children. Disappeared processes are
    harmless; unreadable identities and live outside processes are not.
    """
    uid = str(os.getuid())
    for process in Path("/proc").iterdir():
        if not process.name.isdecimal():
            continue
        try:
            fields = dict(line.split(":", 1) for line in (process / "status").read_text().splitlines()
                          if ":" in line)
            identities = fields.get("Uid", "").split()
            require(len(identities) == 4, "maintenance:process-identity-unavailable")
            if uid not in identities:
                continue
            current = process_group(process)
            require(current == group or current.startswith(group + "/"),
                    "maintenance:user-process-outside-service")
        except FileNotFoundError:
            require(not process.exists(), "maintenance:process-evidence-missing")


def observe():
    require(sys.platform == "linux" and os.getuid() != 0,
            "maintenance:requires-unprivileged-linux-system-service")
    uid = os.getuid()
    name = f"aidevops-worktree-maintenance@{uid}.service"
    snapshot = system_unit(name)
    require(snapshot.get("LoadState") == "loaded" and snapshot.get("ActiveState") == "active",
            "maintenance:service-not-active")
    root_controlled(snapshot.get("FragmentPath", ""))
    require(snapshot.get("User") == str(uid) and snapshot.get("KillMode") == "control-group"
            and snapshot.get("Restart") == "no", "maintenance:service-contract-mismatch")
    user_manager = f"user@{uid}.service"
    require(user_manager in snapshot.get("Conflicts", "").split()
            and user_manager in snapshot.get("Before", "").split(),
            "maintenance:user-manager-not-fenced")
    require(system_unit(user_manager).get("ActiveState") == "inactive",
            "maintenance:user-manager-active")
    require(any(system_unit(target).get("ActiveState") == "active"
                for target in ("rescue.target", "emergency.target")),
            "maintenance:offline-target-required")
    root_controlled("/run/nologin")
    invocation = snapshot.get("InvocationID", "")
    require(re.fullmatch(r"[0-9a-f]{32}", invocation) is not None
            and invocation == os.environ.get("INVOCATION_ID"),
            "maintenance:invocation-mismatch")
    group = snapshot.get("ControlGroup", "")
    require(group.startswith("/system.slice/") and ".." not in Path(group).parts
            and process_group(Path("/proc/self")) == group,
            "maintenance:not-in-system-service")
    require_exclusive_user(group)
    require(system_unit(name) == snapshot, "maintenance:service-changed")
    return {"unit": name, "invocation": invocation, "cgroup": group}
