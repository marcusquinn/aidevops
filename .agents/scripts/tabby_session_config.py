# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validated private inventory and argv-only OpenSSH configuration."""

import hashlib
import json
import shutil
import subprocess
from pathlib import Path

from tabby_session_validation import SessionError, validate_host
from tabby_session_validation import identifier as identifier  # Public compatibility export.


def load_hosts(path, selected=None):
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        raise SessionError("Cannot read host inventory; see remote-sessions.md") from None
    if not isinstance(data, dict) or type(data.get("version")) is not int or data["version"] != 1 or not isinstance(data.get("hosts"), list):
        raise SessionError("Expected version 1 host inventory")
    hosts, seen = [], set()
    for index, source in enumerate(data["hosts"]):
        host = validate_host(source, index)
        if host["id"] in seen:
            raise SessionError("Duplicate host ID")
        seen.add(host["id"])
        if host["enabled"] and (selected is None or host["id"] == selected):
            hosts.append(host)
    if selected is not None and not hosts:
        raise SessionError("Unknown or disabled host ID")
    return sorted(hosts, key=lambda h: (h["restoreOrder"], h["index"]))


def equivalent_aliases(hosts, selected, endpoint_id):
    aliases = {selected["sshHost"]}
    for host in hosts:
        try:
            if endpoint(host) == endpoint_id:
                aliases.add(host["sshHost"])
        except (SessionError, OSError):
            # An unavailable host must not block remaining enabled hosts.
            continue
    return aliases


def ssh_argv(host, probe=True):
    args = [required_executable("ssh"), "-o", "ConnectTimeout=15"]
    identities_only = host.get("identitiesOnly", True if host.get("identityFile") else None)
    if identities_only is not None:
        args += ["-o", "IdentitiesOnly=" + ("yes" if identities_only else "no")]
    if probe:
        args += ["-o", "BatchMode=yes", "-T"]
    else:
        args += ["-tt"]
    for field, option in (("port", "-p"), ("user", "-l"), ("identityFile", "-i")):
        if host.get(field) is not None:
            args += [option, str(host[field])]
    return args


def endpoint(host):
    """Resolve aliases locally. Never print ssh -G output or private fields."""
    if host.get("identityFile") and not Path(host["identityFile"]).is_file():
        raise SessionError("Configured identity file is unavailable")
    try:
        result = subprocess.run(  # nosec B603 - resolved SSH path, validated alias, no shell
                                ssh_argv(host) + ["-G", host["sshHost"]],
                                capture_output=True, text=True, timeout=20, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise SessionError("OpenSSH configuration resolution failed") from None
    fields = dict(line.split(" ", 1) for line in result.stdout.splitlines() if " " in line)
    if result.returncode or not all(fields.get(k) for k in ("hostname", "user", "port")):
        raise SessionError("OpenSSH configuration resolution failed")
    identity = host.get("endpointId") or json.dumps(
        [fields["hostname"].lower(), fields["user"], fields["port"]])
    return hashlib.sha256(identity.encode()).hexdigest()


def required_executable(name):
    path = shutil.which(name)
    if not path:
        raise SessionError("Required executable unavailable: " + name)
    return str(Path(path).absolute())
