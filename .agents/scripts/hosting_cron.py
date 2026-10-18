#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Hostinger hPanel cron jobs through the hosting API.

Commands: list, create, delete, output. create and delete preview unless
--apply is given; each change is preceded by a private (0600) snapshot of the
job list and followed by a fresh list. After a failed or partial response the
live list is printed and nothing is retried. The API token is read from
HOSTINGER_API_TOKEN and is never printed; home paths are masked in output.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess  # nosec B404 - fixed argv SSH whoami only
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

API_BASE = "https://developers.hostinger.com"
CRON_PATH = "/api/hosting/v1/accounts/{username}/cron-jobs"
SSH_ALIAS_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$")
USERNAME_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$")
UID_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
HOME_PATH_RE = re.compile(r"(?:/home|/Users)/[^/\s'\"]+")
SNAPSHOT_DIR = Path.home() / ".aidevops" / ".agent-workspace" / "work" / "hostinger-cron"


class CronError(Exception):
    """A refused or failed cron operation."""


def mask(text: Any) -> str:
    """Replace account home paths so private paths are never printed."""
    return HOME_PATH_RE.sub("~", str(text))


def resolve_username(alias: str) -> str:
    """Return the hosting account name from `ssh ALIAS whoami`."""
    if not SSH_ALIAS_RE.match(alias):
        raise CronError("Invalid SSH alias")
    try:
        result = subprocess.run(  # nosec B603 B607 - fixed argv, validated alias
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", alias, "whoami"],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise CronError("SSH whoami failed") from exc
    username = result.stdout.strip()
    if result.returncode != 0 or not USERNAME_RE.match(username):
        raise CronError("Could not resolve the hosting account with 'ssh <alias> whoami'")
    return username


def api_request(method: str, path: str, token: str, body: dict[str, Any] | None = None) -> Any:
    """Issue one authenticated request and decode JSON (empty body gives None)."""
    if not API_BASE.startswith("https://"):
        raise CronError("Hostinger API base URL must use HTTPS")
    data = json.dumps(body).encode() if body is not None else None
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        # The API edge rejects urllib's default User-Agent with HTTP 403.
        "User-Agent": "aidevops-hostinger-cron/1",
    }
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(  # noqa: S310 - HTTPS enforced above
        f"{API_BASE}{path}", data=data, method=method, headers=headers
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:  # nosec B310
            raw = response.read()
    except urllib.error.HTTPError as exc:
        raise CronError(f"Hostinger API returned HTTP {exc.code} for {method} {mask(path)}") from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise CronError(f"Hostinger API request failed for {method} {mask(path)}") from exc
    if not raw.strip():
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise CronError(f"Hostinger API returned invalid JSON for {method} {mask(path)}") from exc


def list_jobs(username: str, token: str) -> list[dict[str, Any]]:
    """Fetch the job list; refuse any response that is not a top-level array."""
    payload = api_request("GET", CRON_PATH.format(username=username), token)
    if not isinstance(payload, list):
        raise CronError("Unexpected cron list response (expected a JSON array)")
    return [job for job in payload if isinstance(job, dict)]


def print_jobs(jobs: list[dict[str, Any]], *, as_json: bool) -> None:
    """Print jobs with home paths masked."""
    rows = [
        {key: mask(job.get(key, "")) for key in ("uid", "time", "command")} for job in jobs
    ]
    if as_json:
        print(json.dumps(rows, indent=2))
        return
    if not rows:
        print("No cron jobs.")
        return
    for row in rows:
        print(f"{row['uid']}\t{row['time']}\t{row['command']}")


def write_snapshot(username: str, jobs: list[dict[str, Any]], action: str) -> Path:
    """Write a private (0600) snapshot of the exact job list; return its path."""
    SNAPSHOT_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(SNAPSHOT_DIR, 0o700)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    path = SNAPSHOT_DIR / f"cron-{action}-{stamp}.json"
    payload = {"taken_at": stamp, "action": action, "username": username, "jobs": jobs}
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
    return path


def show_live_after_failure(username: str, token: str) -> None:
    """Print the live list after a failed mutation, without retrying."""
    print("Mutation failed or was partial. Live jobs (inspect before any retry):", file=sys.stderr)
    try:
        print_jobs(list_jobs(username, token), as_json=False)
    except CronError as exc:
        print(f"Could not list live jobs: {exc}", file=sys.stderr)


def mutate(args: argparse.Namespace, username: str, token: str) -> int:
    """Run create or delete with preview, snapshot, apply and a final list."""
    path = CRON_PATH.format(username=username)
    jobs = list_jobs(username, token)
    if args.action == "create":
        method, target, body = "POST", path, {"time": args.time, "command": args.command}
        print(f"Would create: POST {mask(path)}")
        print(f"  time:    {mask(args.time)}")
        print(f"  command: {mask(args.command)}")
    else:
        match = [job for job in jobs if str(job.get("uid")) == args.uid]
        if not match:
            raise CronError("UID not found in the live job list; nothing to delete")
        method, target, body = "DELETE", f"{path}/{urllib.parse.quote(args.uid, safe='')}", None
        print(f"Would delete: DELETE {mask(path)}/{args.uid}")
        print_jobs(match, as_json=False)
    if not args.apply:
        print("Preview only; nothing changed. Re-run with --apply to proceed.")
        return 0
    snapshot = write_snapshot(username, jobs, args.action)
    print(f"Snapshot (0600): {mask(snapshot)}")
    try:
        api_request(method, target, token, body)
    except CronError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        show_live_after_failure(username, token)
        return 1
    print("Done. Live jobs now:")
    print_jobs(list_jobs(username, token), as_json=False)
    return 0


def run(args: argparse.Namespace) -> int:
    """Dispatch one cron action."""
    token = os.environ.get("HOSTINGER_API_TOKEN", "")
    if not token:
        raise CronError(
            "HOSTINGER_API_TOKEN is not set; run via hostinger-helper.sh cron "
            "(it injects it with 'aidevops secret')"
        )
    username = resolve_username(args.ssh)
    if args.action == "list":
        print_jobs(list_jobs(username, token), as_json=args.json)
        return 0
    if args.action == "output":
        payload = api_request(
            "GET",
            f"{CRON_PATH.format(username=username)}/{urllib.parse.quote(args.uid, safe='')}/output",
            token,
        )
        text = payload if isinstance(payload, str) else json.dumps(payload, indent=2)
        print(mask(text))
        return 0
    return mutate(args, username, token)


def build_parser() -> argparse.ArgumentParser:
    """Build the argument parser."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    for name in ("list", "create", "delete", "output"):
        sub = commands.add_parser(name)
        sub.add_argument("--ssh", required=True, help="SSH alias of the hosting account")
        if name == "list":
            sub.add_argument("--json", action="store_true")
        if name == "create":
            sub.add_argument("--time", required=True, help="cron schedule, e.g. '*/5 * * * *'")
            sub.add_argument("--command", required=True)
        if name in ("delete", "output"):
            sub.add_argument("--uid", required=True)
        if name in ("create", "delete"):
            sub.add_argument("--apply", action="store_true", help="make the change (default: preview)")
    return parser


def main(argv: list[str] | None = None) -> int:
    """Entry point."""
    args = build_parser().parse_args(argv)
    try:
        if getattr(args, "uid", None) is not None and not UID_RE.match(args.uid):
            raise CronError("Invalid UID")
        if args.action == "create" and (not args.time.strip() or not args.command.strip()):
            raise CronError("--time and --command must not be empty")
        return run(args)
    except CronError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
