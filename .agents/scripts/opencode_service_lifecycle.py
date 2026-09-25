# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Persistent owner installation and explicit service lifecycle operations."""

import os
from pathlib import Path
import shutil
import time

from opencode_service_state import (
    SCHEMA, UNIT, ServiceState, atomic_write, check_write_path, command, require,
)

# Preserve the deployment alias rather than resolving into a versioned bundle.
HELPER = Path(__file__).absolute().with_name("opencode-service-helper.py")
RUNTIME_FILES = ("opencode_service_state.py", "opencode_service_lifecycle.py",
                 "opencode-launcher-helper.sh", "opencode-service-helper.py")


class Service(ServiceState):
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

    def enable(self, data):
        data = dict(data, enabled=True)
        self.save(data)
        if self.platform == "linux":
            command("systemctl", "--user", "enable", UNIT)
        else:
            command("launchctl", "enable", self.target)
        self.start(data)

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

    def install_data(self, args, old):
        binaries = [shutil.which(name) for name in ("opencode", "python3", "node")]
        paths = [str(Path(binary).parent) for binary in binaries if binary]
        paths += [str(self.home / ".local/bin"), str(self.home / ".bun/bin"),
                  "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        data = old or {"schema": SCHEMA, "port": args.port if args.port is not None else 49036,
                       "shard": args.shard or "managed-default", "directory": str(self.home),
                       "enabled": True, "route_new": False}
        # Preserve identity and opt-out, not obsolete package-manager paths.
        data = dict(data, python=shutil.which("python3"), opencode=shutil.which("opencode"),
                    path=":".join(dict.fromkeys(paths)))
        require(not old or ((args.port is None or args.port == old["port"]) and
                           (args.shard is None or args.shard == old["shard"])),
                "Installed identity is immutable; do not redirect existing history")
        if args.route_new or (args.fresh_default and old is None and not self.existing_history()):
            data = dict(data, route_new=True)
        self.validate(data)
        return data

    def install_definition(self, data):
        content = self.definition_bytes(data)
        changed = not self.definition.exists() or self.definition.read_bytes() != content
        require(not changed or not self.pid(), "Definition changed; stop the idle owner before reinstalling")
        if changed and self.platform == "darwin":
            require(command("launchctl", "print", self.target, check=False).returncode != 0,
                    "Definition changed but job is loaded; run service stop before reinstalling")
        if not self.pid() and data["enabled"]:
            require(not self.listeners(data), "Port occupied; stop the known previous owner explicitly first")
        self.stage_runtime(HELPER, RUNTIME_FILES)
        check_write_path(self.logs)
        self.logs.mkdir(parents=True, exist_ok=True)
        if changed:
            atomic_write(self.definition, content)
        self.save(data)
        self.load()

    def install(self, args):
        self.supported()
        require(HELPER in (self.home / ".aidevops/agents/scripts/opencode-service-helper.py",
                           self.runtime / "opencode-service-helper.py"),
                "Deploy the helper first; persistent services must not reference disposable worktrees")
        for binary in ("opencode", "python3", "lsof"):
            require(shutil.which(binary), f"{binary} is required")
        self.verify_definition()
        old = self.load() if self.config.exists() else None
        data = self.install_data(args, old)
        self.install_definition(data)
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

    def attach(self, data, args):
        if not args.dry_run:
            self.start(data)
        argv = ["/bin/bash", str(HELPER.with_name("opencode-launcher-helper.sh")),
                "attach", self.url(data), "--dir", args.dir]
        if args.session:
            argv += ["--session", args.session]
        if args.dry_run:
            argv += ["--dry-run"]
        # Fixed interpreter and script; directory/session remain separate argv values.
        os.execv("/bin/bash", argv)
