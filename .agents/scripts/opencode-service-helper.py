#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Per-user OpenCode V1 owner. Never migrates databases or edits Desktop state."""

import argparse
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
import time
import urllib.request


LABEL = "sh.aidevops.opencode-server"
UNIT = "aidevops-opencode-server.service"
SCHEMA = "aidevops.opencode-service/v1"
# Keep the stable deployment alias, not a versioned runtime-bundle target.
HELPER = Path(__file__).absolute()


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


class Service:
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

    def shard(self, data):
        return self.work / "opencode-server" / data["shard"]

    @staticmethod
    def url(data):
        return f"http://127.0.0.1:{data['port']}"

    def definition_bytes(self, data):
        args = [data["python"], str(self.runtime / HELPER.name), "run"]
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

    def start(self, data):
        require(data["enabled"], "Service is disabled; run service enable explicitly")
        self.verify_definition()
        require(self.definition.exists(), "Service definition is missing; run service install")
        if not self.pid():
            require(not self.listeners(data), "Port belongs to another owner; refusing to take it over")
            if self.platform == "darwin":
                loaded = command("launchctl", "print", self.target, check=False).returncode == 0
                if not loaded:
                    command("launchctl", "bootstrap", self.domain, str(self.definition))
                else:
                    command("launchctl", "kickstart", self.target)
            else:
                command("systemctl", "--user", "start", UNIT)
        deadline = time.monotonic() + 45
        last_error = "Owner did not become ready"
        while time.monotonic() < deadline:
            try:
                return self.health(data)
            except (RuntimeError, OSError, ValueError) as error:
                last_error = str(error)
                time.sleep(0.5)
        raise RuntimeError(last_error + "; inspect service logs (no local DB fallback)")

    def stop(self):
        self.verify_definition()
        if self.platform == "darwin":
            if command("launchctl", "print", self.target, check=False).returncode == 0:
                command("launchctl", "bootout", self.target)
        else:
            command("systemctl", "--user", "stop", UNIT)

    def disable(self, data):
        self.verify_definition()
        self.save(dict(data, enabled=False))
        try:
            self.stop()
        finally:
            if self.platform == "linux":
                command("systemctl", "--user", "disable", UNIT)

    def recover_dead_lock(self, data):
        """Recover only this registered shard's dead owner after a crash/reboot."""
        lock = self.shard(data) / ".aidevops-server-owner"
        if not lock.exists():
            return
        marker = lock / "pid"
        require(not lock.is_symlink() and not marker.is_symlink(), "Unsafe owner lock")
        previous = marker.read_text()
        require(previous.strip().isdigit() and int(previous) > 1, "Unrecognized owner lock")
        try:
            os.kill(int(previous), 0)
        except ProcessLookupError:
            pass
        else:
            raise RuntimeError("Previous owner PID is alive; refusing lock recovery")
        files = [str(p) for p in (self.shard(data) / "opencode").glob("opencode.db*")]
        if files:
            result = command("lsof", "-t", "--", *files, check=False)
            require(result.returncode == 1 and not result.stdout, "Database still has holders")
        require(marker.read_text() == previous, "Owner lock changed during recovery")
        marker.unlink()
        lock.rmdir()

    def existing_history(self):
        # Presence is deliberately conservative: never inspect or migrate live SQLite.
        shared = Path(os.environ.get("XDG_DATA_HOME", self.home / ".local/share"))
        if (shared / "opencode/opencode.db").exists():
            return True
        roots = {self.work, Path(os.environ.get("AIDEVOPS_WORK_DIR", self.work))}
        return any(next(root.glob("opencode-*/*/opencode/opencode.db"), None) for root in roots)

    def stage_runtime(self):
        """Keep owner startup available even if an older framework is deployed."""
        check_write_path(self.runtime)
        marker = self.runtime / ".managed"
        if self.runtime.exists():
            require(marker.is_file() and marker.read_text() == SCHEMA, "Unknown service runtime")
        else:
            self.runtime.mkdir(parents=True, mode=0o700)
            atomic_write(marker, SCHEMA.encode())
        for name in ("opencode-service-helper.py", "opencode-launcher-helper.sh"):
            atomic_write(self.runtime / name, HELPER.with_name(name).read_bytes())
        # Shared safety tooling follows the normal framework update path. These
        # small bootstraps preserve BASH_SOURCE-relative imports in the real files.
        atomic_write(self.runtime / "shared-constants.sh",
                     b'source "${HOME}/.aidevops/agents/scripts/shared-constants.sh"\n')
        atomic_write(self.runtime / "gh",
                     b'#!/usr/bin/env bash\nexec "${HOME}/.aidevops/agents/scripts/gh" "$@"\n')
        (self.runtime / "gh").chmod(0o700)

    def install(self, args):
        self.supported()
        require(HELPER in (self.home / ".aidevops/agents/scripts/opencode-service-helper.py",
                           self.runtime / "opencode-service-helper.py"),
                "Deploy the helper first; persistent services must not reference disposable worktrees")
        for binary in ("opencode", "python3", "lsof"):
            require(shutil.which(binary), f"{binary} is required")
        self.verify_definition()
        old = self.load() if self.config.exists() else None
        binaries = [shutil.which(name) for name in ("opencode", "python3", "node")]
        paths = [str(Path(binary).parent) for binary in binaries if binary]
        paths += [str(self.home / ".local/bin"), str(self.home / ".bun/bin"),
                  "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        data = old or {"schema": SCHEMA, "port": args.port if args.port is not None else 49036,
                       "shard": args.shard or "managed-default", "directory": str(self.home),
                       "enabled": True, "route_new": False}
        # Preserve identity and opt-out, not obsolete package-manager paths.
        # The definition-change guard below still prevents an active restart.
        data = dict(data, python=shutil.which("python3"), opencode=shutil.which("opencode"),
                    path=":".join(dict.fromkeys(paths)))
        require(not old or ((args.port is None or args.port == old["port"]) and
                           (args.shard is None or args.shard == old["shard"])),
                "Installed identity is immutable; do not redirect existing history")
        if args.route_new or (args.fresh_default and old is None and not self.existing_history()):
            data = dict(data, route_new=True)
        self.validate(data)
        content = self.definition_bytes(data)
        changed = not self.definition.exists() or self.definition.read_bytes() != content
        require(not changed or not self.pid(), "Definition changed; stop the idle owner before reinstalling")
        if changed and self.platform == "darwin":
            require(command("launchctl", "print", self.target, check=False).returncode != 0,
                    "Definition changed but job is loaded; run service stop before reinstalling")
        if not self.pid() and data["enabled"]:
            require(not self.listeners(data), "Port occupied; stop the known previous owner explicitly first")
        self.stage_runtime()
        check_write_path(self.logs)
        self.logs.mkdir(parents=True, exist_ok=True)
        if changed:
            atomic_write(self.definition, content)
        self.save(data)
        # Validate before starting anything; keep disabled installations disabled on update.
        self.load()
        if self.platform == "linux":
            command("systemctl", "--user", "daemon-reload")
            if data["enabled"]:
                command("systemctl", "--user", "enable", UNIT)
        if data["enabled"]:
            try:
                self.start(data)
            except (RuntimeError, OSError, ValueError):
                # A failed fresh install must not leave a restart loop or alter old histories.
                if old is None:
                    self.disable(dict(data, route_new=False))
                raise
        return data

    def run(self, data):
        if not data["enabled"]:
            return
        self.recover_dead_lock(data)
        # No inherited interactive shard, overlay, or plugin-disabling environment.
        environment = {"HOME": str(self.home), "PATH": data["path"],
                       "AIDEVOPS_WORK_DIR": str(self.work)}
        launcher = HELPER.with_name("opencode-launcher-helper.sh")
        os.execve("/bin/bash", ["/bin/bash", str(launcher), "server", "--dir", data["directory"],
                               "--port", str(data["port"]), "--session-id", data["shard"]], environment)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "status", "start", "stop", "disable", "enable",
                                           "run", "route", "desktop-ready", "attach"))
    parser.add_argument("--port", type=int)
    parser.add_argument("--shard")
    parser.add_argument("--route-new", action="store_true", help="Route plain new TUI launches; old DBs stay direct")
    parser.add_argument("--fresh-default", action="store_true", help="Setup: route only when no old history exists")
    parser.add_argument("--dir", default=os.getcwd())
    parser.add_argument("--session")
    parser.add_argument("--dry-run", action="store_true", help="Attach command preview only")
    args = parser.parse_args()
    if args.dry_run and args.action != "attach":
        parser.error("--dry-run is supported only for attach; no service changes were made")
    if args.action in ("install", "enable", "start", "run", "desktop-ready", "attach"):
        require(not any(os.environ.get(key) for key in ("OPENCODE_SERVER_PASSWORD", "OPENCODE_SERVER_USERNAME")),
                "Authenticated server mode is unsupported; unset server authentication variables")
    service = Service()
    if args.action == "route":
        data = service.load() if service.config.exists() else {}
        print("managed" if data.get("enabled") and data.get("route_new") else "direct")
        return
    if args.action == "desktop-ready" and not service.config.exists():
        return
    if not (args.action == "attach" and args.dry_run):
        service.supported()
    if args.action in ("run", "status") or args.dry_run:
        execute(args, service)
    else:
        with lifecycle_lock(service):
            execute(args, service)


def execute(args, service):
    if args.action == "install":
        data = service.install(args)
        print(json.dumps({"installed": True, "enabled": data["enabled"], "url": service.url(data),
                          "route_new": data["route_new"]}))
        return
    data = service.load()
    if args.action == "run":
        service.run(data)
    elif args.action == "status":
        print(json.dumps(service.health(data)))
    elif args.action in ("stop", "disable"):
        if args.action == "disable":
            service.disable(data)
        else:
            service.stop()
    elif args.action in ("start", "enable", "desktop-ready"):
        if args.action == "enable":
            data = dict(data, enabled=True)
            service.save(data)
            if service.platform == "linux":
                command("systemctl", "--user", "enable", UNIT)
            else:
                command("launchctl", "enable", service.target)
        if args.action != "desktop-ready" or data["enabled"]:
            service.start(data)
    elif args.action == "attach":
        if not args.dry_run:
            service.start(data)
        argv = ["/bin/bash", str(HELPER.with_name("opencode-launcher-helper.sh")),
                "attach", service.url(data), "--dir", args.dir]
        if args.session:
            argv += ["--session", args.session]
        if args.dry_run:
            argv += ["--dry-run"]
        os.execv(argv[0], argv)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as failure:
        print(f"OpenCode service: {failure}", file=sys.stderr)
        sys.exit(1)
