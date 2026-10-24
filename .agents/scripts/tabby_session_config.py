# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validated private inventory and argv-only OpenSSH configuration."""

import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path


class SessionError(Exception):
    """An intentionally sanitized operational failure."""


def identifier(value, label, pattern=r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}"):
    if not isinstance(value, str) or not re.fullmatch(pattern, value):
        raise SessionError("Invalid " + label)
    return value


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


def validate_host(source, index):
    allowed = {"id", "sshHost", "titlePrefix", "sessionPrefix", "restoreOrder", "enabled",
               "connectIntervalSeconds", "port", "user", "identityFile", "endpointId"}
    if not isinstance(source, dict) or set(source) - allowed:
        raise SessionError("Unknown host fields; arbitrary SSH options/hooks are not supported")
    host = dict(source)
    for field in ("id", "sshHost"):
        identifier(host.get(field), field)
    for field, default in (("titlePrefix", host["id"]), ("sessionPrefix", "oc-")):
        host[field] = identifier(host.get(field, default), field)
    identifier(host["sessionPrefix"], "sessionPrefix", r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}")
    host.setdefault("enabled", True)
    if type(host["enabled"]) is not bool:
        raise SessionError("enabled must be boolean")
    for field, default, low, high in (("restoreOrder", index, 0, 1000000),
                                     ("connectIntervalSeconds", 5, 0, 60),
                                     ("port", None, 1, 65535)):
        value = host.get(field, default)
        if value is not None and (type(value) is not int or not low <= value <= high):
            raise SessionError("Invalid " + field)
        host[field] = value
    if "user" in host:
        identifier(host["user"], "user", r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}")
    if "identityFile" in host:
        value = host["identityFile"]
        if not isinstance(value, str) or not value or any(c in value for c in "\x00\n\r"):
            raise SessionError("Invalid identityFile")
        identity = Path(value).expanduser()
        if not identity.is_absolute():
            raise SessionError("identityFile must be absolute or home-relative, not working-directory-relative")
        host["identityFile"] = str(identity)
    if "endpointId" in host:
        identifier(host["endpointId"], "endpointId")
    host["index"] = index
    return host


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
    args = ["ssh", "-o", "ConnectTimeout=15"]
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
        result = subprocess.run(ssh_argv(host) + ["-G", host["sshHost"]],
                                capture_output=True, text=True, timeout=20, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise SessionError("OpenSSH configuration resolution failed") from None
    fields = dict(line.split(" ", 1) for line in result.stdout.splitlines() if " " in line)
    if result.returncode or not all(fields.get(k) for k in ("hostname", "user", "port")):
        raise SessionError("OpenSSH configuration resolution failed")
    identity = host.get("endpointId") or json.dumps(
        [fields["hostname"].lower(), fields["user"], fields["port"]])
    return hashlib.sha256(identity.encode()).hexdigest()


def tabby_executable():
    override = os.environ.get("AIDEVOPS_TABBY_BIN")
    candidates = [override] if override else [shutil.which("tabby"),
        "/Applications/Tabby.app/Contents/MacOS/Tabby",
        str(Path.home() / "Applications/Tabby.app/Contents/MacOS/Tabby")]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return str(Path(candidate).absolute())
    raise SessionError("Tabby executable unavailable")


def check_tabby(binary):
    try:
        version = subprocess.run([binary, "--version"], capture_output=True, text=True,
                                 timeout=15, check=False)
        help_text = subprocess.run([binary, "run", "--help"], capture_output=True,
                                   text=True, timeout=15, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise SessionError("Tabby CLI probe failed") from None
    if "1.0.235" in version.stdout or "stripAnsi" in version.stderr + help_text.stderr:
        raise SessionError("Broken Tabby CLI (stripAnsi); upgrade Tabby, do not patch its archive")
    if version.returncode or help_text.returncode or "--command" not in help_text.stdout:
        raise SessionError("Unsupported Tabby CLI: run --command array is required")
    match = re.search(r"\b\d+\.\d+\.\d+\b", version.stdout)
    return match.group() if match else "version unknown"
