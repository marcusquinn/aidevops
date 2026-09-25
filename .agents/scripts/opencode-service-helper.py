#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Per-user OpenCode V1 owner. Never migrates databases or edits Desktop state."""

import argparse
import json
import os
import subprocess
import sys

from opencode_service_lifecycle import Service
from opencode_service_state import lifecycle_lock, require


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
    elif args.action == "attach":
        service.attach(data, args)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as failure:
        print(f"OpenCode service: {failure}", file=sys.stderr)
        sys.exit(1)
