#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Per-user OpenCode V1 owner. Never migrates databases or edits Desktop state."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlencode

# Python resolves sys.path[0] through directory symlinks. Keep sibling imports
# rooted at the invoked deployment alias so the persistent-install guard agrees.
sys.path.insert(0, str(Path(__file__).absolute().parent))
from opencode_service_lifecycle import Service
from opencode_service_state import lifecycle_lock, require


def desktop_link(service, data, args):
    """Produce a public connection request, never an edit to private Desktop state."""
    require(data["enabled"], "Managed service is disabled; enable it explicitly before connecting Desktop")
    binary = Path(args.desktop_binary).expanduser().resolve(strict=True)
    manifest = binary.parent.parent / "Resources" / "capabilities.json"
    require(manifest.is_file(), "Desktop does not support managed connection links; select the server manually")
    require(manifest.stat().st_size <= 4096, "Invalid Desktop capability manifest")
    capabilities = json.loads(manifest.read_text(encoding="utf-8"))
    require(isinstance(capabilities, dict) and type(capabilities.get("connect-project")) is int
            and capabilities["connect-project"] == 1, "Desktop lacks connect-project v1; select the server manually")
    directory = str(Path(args.dir).expanduser().absolute())
    require(Path(directory).is_dir() and not any(ord(char) < 32 or ord(char) == 127 for char in directory),
            "Desktop project directory must exist and contain no control characters")
    if not args.dry_run:
        with lifecycle_lock(service):
            data = service.load()
            require(data["enabled"], "Managed service is disabled; enable it explicitly before connecting Desktop")
            service.start(data)
    return "opencode://connect?" + urlencode({"url": service.url(data), "directory": directory})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "status", "start", "stop", "disable", "enable",
                                           "run", "route", "desktop-ready", "desktop-link", "attach"))
    parser.add_argument("--port", type=int)
    parser.add_argument("--shard")
    parser.add_argument("--route-new", action="store_true", help="Route plain new TUI launches; old DBs stay direct")
    parser.add_argument("--fresh-default", action="store_true", help="Setup: route only when no old history exists")
    parser.add_argument("--dir", default=os.getcwd())
    parser.add_argument("--desktop-binary", help="Desktop executable advertising connect-project v1")
    parser.add_argument("--session")
    parser.add_argument("--dry-run", action="store_true", help="Attach command or Desktop link preview only")
    args = parser.parse_args()
    if args.dry_run and args.action not in ("attach", "desktop-link"):
        parser.error("--dry-run is supported only for attach or desktop-link; no service changes were made")
    if args.action == "desktop-link" and not args.desktop_binary:
        parser.error("desktop-link requires --desktop-binary")
    if args.action in ("install", "enable", "start", "run", "desktop-ready", "desktop-link", "attach"):
        require(not any(os.environ.get(key) for key in ("OPENCODE_SERVER_PASSWORD", "OPENCODE_SERVER_USERNAME")),
                "Authenticated server mode is unsupported; unset server authentication variables")
    service = Service()
    if args.action == "route":
        data = service.load() if service.config.exists() else {}
        print("managed" if data.get("enabled") and data.get("route_new") else "direct")
        return
    if args.action == "desktop-ready" and not service.config.exists():
        return
    if not (args.action in ("attach", "desktop-link") and args.dry_run):
        service.supported()
    if args.action in ("run", "status", "desktop-link") or args.dry_run:
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
    elif args.action == "stop":
        service.stop()
    elif args.action == "disable":
        service.disable(data)
    elif args.action == "enable":
        service.enable(data)
    elif args.action == "start":
        service.start(data)
    elif args.action == "desktop-ready":
        if data["enabled"]:
            service.start(data)
    elif args.action == "desktop-link":
        print(desktop_link(service, data, args))
    elif args.action == "attach":
        service.attach(data, args)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as failure:
        print(f"OpenCode service: {failure}", file=sys.stderr)
        sys.exit(1)
