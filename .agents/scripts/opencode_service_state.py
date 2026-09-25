#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Private service configuration, manager identity and readiness checks."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request


LABEL = "sh.aidevops.opencode-server"
UNIT = "aidevops-opencode-server.service"
SCHEMA = "aidevops.opencode-service/v1"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def command(*args, check=True):
    result = subprocess.run(args, capture_output=True, text=True, timeout=30, check=False)
    # Service-manager output can include environment values; don't reproduce it.
    require(not check or result.returncode == 0, f"{Path(args[0]).name} operation failed")
    return result.stdout.strip() if check else result


def check_write_path(path):
    for component in (path, *path.parents):
        require(not component.is_symlink(), "Refusing a symlinked managed path")


def atomic_write(path, content):
    check_write_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def systemd_quote(value, executable=False):
    require(not any(ord(c) < 32 for c in value), "Control character in service value")
    value = value.replace('\\', '\\\\').replace('%', '%%').replace('"', '\\"')
    return '"' + (value.replace('$', '$$') if executable else value) + '"'


@contextmanager
def lifecycle_lock(service):
    import fcntl  # Unix only; unsupported platforms are rejected before this point.

    path = service.config.with_suffix(".lock")
    check_write_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    require(not path.is_symlink(), "Refusing a symlinked lifecycle lock")
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("Another service lifecycle operation is in progress") from error
        yield


class ServiceState:
    def __init__(self, home=None, platform=None):
        self.home = Path(home or Path.home())
        self.platform = platform or sys.platform
        self.config = self.home / ".config/aidevops/opencode-service.json"
        self.work = self.home / ".aidevops/.agent-workspace/work"
        self.runtime = self.work / "opencode-service/runtime"
        self.logs = self.home / ".aidevops/logs"
        self.domain = f"gui/{os.getuid()}" if hasattr(os, "getuid") else ""
        self.target = f"{self.domain}/{LABEL}"
        self.definition = (self.home / "Library/LaunchAgents" / f"{LABEL}.plist"
                           if self.platform == "darwin" else
                           self.home / ".config/systemd/user" / UNIT)

    def supported(self):
        require(self.platform in ("darwin", "linux"),
                "Native Windows is unsupported; use WSL2 with systemd --user")
        if self.platform == "linux":
            require(shutil.which("systemctl") is not None, "systemd --user is required")
            require(command("systemctl", "--user", "show", "--property=Version", "--value", check=False).returncode == 0,
                    "No systemd user manager; enable it in Linux/WSL2 first")

    def load(self):
        require(not self.config.is_symlink(), "Refusing a symlinked service configuration")
        data = json.loads(self.config.read_text())
        self.validate(data)
        return data

    @staticmethod
    def validate(data):
        require(data.get("schema") == SCHEMA, "Unknown service configuration; leaving it untouched")
        require(type(data.get("port")) is int and 1024 <= data["port"] <= 65535, "Invalid service port")
        require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,100}", data.get("shard", "")), "Invalid shard")
        for key in ("enabled", "route_new"):
            require(type(data.get(key)) is bool, f"Invalid {key} setting")
        require(Path(data["directory"]).is_absolute() and Path(data["directory"]).is_dir(),
                "Owner directory is unavailable")
        for key in ("path", "python", "opencode", "directory"):
            require(isinstance(data[key], str) and not any(ord(c) < 32 for c in data[key]),
                    f"Invalid service {key}")
        for key in ("python", "opencode"):
            require(Path(data[key]).is_absolute(), f"Service {key} must be absolute")

    def save(self, data):
        atomic_write(self.config, (json.dumps(data, indent=2) + "\n").encode())

    def stage_runtime(self, helper, files):
        """Keep owner startup available even if an older framework is deployed."""
        check_write_path(self.runtime)
        marker = self.runtime / ".managed"
        if self.runtime.exists():
            require(marker.is_file() and marker.read_text() == SCHEMA, "Unknown service runtime")
        else:
            self.runtime.mkdir(parents=True, mode=0o700)
            atomic_write(marker, SCHEMA.encode())
        for name in files:
            atomic_write(self.runtime / name, helper.with_name(name).read_bytes())
        # Shared safety tooling follows the normal framework update path.
        atomic_write(self.runtime / "shared-constants.sh",
                     b'source "${HOME}/.aidevops/agents/scripts/shared-constants.sh"\n')
        atomic_write(self.runtime / "gh",
                     b'#!/usr/bin/env bash\nexec "${HOME}/.aidevops/agents/scripts/gh" "$@"\n')
        (self.runtime / "gh").chmod(0o700)

    def shard(self, data):
        return self.work / "opencode-server" / data["shard"]

    def existing_history(self):
        # Presence is deliberately conservative: never inspect or migrate live SQLite.
        shared = Path(os.environ.get("XDG_DATA_HOME", self.home / ".local/share"))
        if (shared / "opencode/opencode.db").exists():
            return True
        roots = {self.work, Path(os.environ.get("AIDEVOPS_WORK_DIR", self.work))}
        return any(next(root.glob("opencode-*/*/opencode/opencode.db"), None) for root in roots)

    @staticmethod
    def url(data):
        return f"http://127.0.0.1:{data['port']}"

    def definition_bytes(self, data):
        args = [data["python"], str(self.runtime / "opencode-service-helper.py"), "run"]
        environment = {"HOME": str(self.home), "PATH": data["path"]}
        if self.platform == "darwin":
            return plistlib.dumps({
                "Label": LABEL, "ProgramArguments": args, "RunAtLoad": True,
                "KeepAlive": {"SuccessfulExit": False}, "ThrottleInterval": 30,
                "ExitTimeOut": 30, "Umask": 0o077, "WorkingDirectory": str(self.home),
                "EnvironmentVariables": environment, "AidevopsManaged": SCHEMA,
                "StandardOutPath": str(self.logs / "opencode-server.out.log"),
                "StandardErrorPath": str(self.logs / "opencode-server.err.log"),
            })
        env = "\n".join("Environment=" + systemd_quote(f"{k}={v}") for k, v in environment.items())
        return (f"# {SCHEMA}\n[Unit]\nDescription=Aidevops OpenCode owner\n"
                "[Service]\nType=simple\n"
                f"ExecStart={systemd_quote(args[0], True)} {systemd_quote(args[1], True)} run\n{env}\n"
                f"WorkingDirectory={systemd_quote(str(self.home))}\n"
                "Restart=on-failure\nRestartSec=30\nTimeoutStopSec=30\nUMask=0077\n"
                "[Install]\nWantedBy=default.target\n").encode()

    def verify_definition(self):
        require(not self.definition.is_symlink(), "Refusing a symlinked service definition")
        if not self.definition.exists():
            return
        raw = self.definition.read_bytes()
        owned = (plistlib.loads(raw).get("AidevopsManaged") == SCHEMA
                 if self.platform == "darwin" else raw.startswith(f"# {SCHEMA}\n".encode()))
        require(owned, "Existing service is not aidevops-managed; refusing to replace or stop it")

    def pid(self):
        if self.platform == "darwin":
            result = command("launchctl", "print", self.target, check=False)
            match = re.search(r"^\s*pid = (\d+)\s*$", result.stdout, re.M)
            return int(match[1]) if result.returncode == 0 and match else 0
        result = command("systemctl", "--user", "show", UNIT, "--property=MainPID", "--value", check=False)
        return int(result.stdout.strip() or 0) if result.returncode == 0 else 0

    def listeners(self, data):
        result = command("lsof", "-nP", "-t", f"-iTCP:{data['port']}", "-sTCP:LISTEN", check=False)
        require(result.returncode in (0, 1), "Cannot inspect listener ownership")
        return set(int(pid) for pid in result.stdout.split())

    @staticmethod
    def descendant(pid, ancestor):
        for _ in range(12):
            if pid == ancestor:
                return True
            if pid <= 1:
                return False
            result = command("ps", "-o", "ppid=", "-p", str(pid), check=False)
            pid = int(result.stdout.strip() or 0)
        return False

    def health(self, data):
        pid = self.pid()
        require(pid > 0, "Managed owner is not running")
        lock = self.shard(data) / ".aidevops-server-owner/pid"
        require(lock.is_file() and lock.read_text().strip() == str(pid), "Owner lock does not match service")
        listeners = self.listeners(data)
        require(len(listeners) == 1 and self.descendant(next(iter(listeners)), pid),
                "Listener is not the managed owner")
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(self.url(data) + "/global/health", timeout=3) as response:
            health = json.load(response)
        require(health.get("healthy") is True, "Owner is not healthy")
        version = command(data["opencode"], "--version")
        require(health.get("version") == version, "CLI/server version mismatch; restart the owner when idle")
        return {"healthy": True, "pid": pid, "version": version, "url": self.url(data)}
