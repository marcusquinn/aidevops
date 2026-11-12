#!/usr/bin/env python3
"""Plan a Buzz community from the aidevops base layout (read-only)."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Subprocess use is limited to read-only Buzz CLI calls with fixed argv and no shell.
import argparse
import json
import os
import shutil
import subprocess  # nosec B404
import sys
from pathlib import Path

from _team_interface_buzz_plan import as_list, compute_plan, member_pubkeys, render_text
from _team_interface_buzz_runtime_install import default_app_data_dir
from _team_interface_buzz_runtime_io import RuntimeError as BuzzRuntimeError

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_TEMPLATE = SCRIPT_DIR.parent / "configs" / "buzz-community-base.json"
TEMPLATE_SCHEMA = "aidevops.buzz-community-template/v1"
IDENTITY_TYPE = "sh.aidevops.buzz/aidevops"
CLI_TIMEOUT_SECONDS = 30


class PlanError(Exception):
    """Raised when the community plan cannot be computed."""


def load_template(path):
    """Load and minimally validate the community template."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise PlanError(f"cannot read template {path}: {error}") from error
    if not isinstance(data, dict) or data.get("schema") != TEMPLATE_SCHEMA:
        raise PlanError(f"template schema must be {TEMPLATE_SCHEMA}")
    return data



def run_buzz_json(buzz_bin, args):
    """Run a read-only buzz CLI command and parse its JSON output."""
    try:
        result = subprocess.run(  # nosec B603 -- resolved executable, fixed argv
            [buzz_bin, *args, "--json"],
            check=False,
            capture_output=True,
            text=True,
            timeout=CLI_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise PlanError(f"buzz {' '.join(args)} failed: {error}") from error
    if result.returncode != 0:
        raise PlanError(f"buzz {' '.join(args)} exited {result.returncode}")
    try:
        return json.loads(result.stdout)
    except ValueError as error:
        raise PlanError(f"buzz {' '.join(args)} returned non-JSON output") from error


def load_identities(app_data_dir):
    """Return {display name: pubkey} for local aidevops agent identities."""
    path = Path(app_data_dir) / "agents" / "identities.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise PlanError(f"cannot read identity store {path}: {error}") from error
    except ValueError as error:
        raise PlanError(f"identity store {path} is not valid JSON") from error
    records = as_list(data, "identities", "agents")
    if not records and isinstance(data, dict):
        records = [dict(value, id=key) for key, value in data.items() if isinstance(value, dict)]
    identities = {}
    for record in records:
        if not isinstance(record, dict) or record.get("type") != IDENTITY_TYPE:
            continue
        name = record.get("displayName") or record.get("name")
        pubkey = record.get("pubkey") or record.get("publicKey") or record.get("id")
        if isinstance(name, str) and isinstance(pubkey, str):
            identities[name] = pubkey
    return identities


def channel_record(channel):
    """Normalise a buzz channel record to (id, name)."""
    return (
        str(channel.get("id") or channel.get("channel_id") or channel.get("channelId") or ""),
        str(channel.get("name") or ""),
    )


def build_parser():
    """Build the CLI parser."""
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    plan = sub.add_parser("plan", help="print the community plan (read-only)")
    plan.add_argument("--host-slug")
    plan.add_argument("--template", default=str(DEFAULT_TEMPLATE))
    plan.add_argument("--app-data-dir")
    plan.add_argument("--json", action="store_true", dest="as_json")
    return parser


def main(argv=None):
    """CLI entry point."""
    args = build_parser().parse_args(argv)
    try:
        template = load_template(args.template)
        host_slug = args.host_slug or os.environ.get("AIDEVOPS_BUZZ_HOST_SLUG")
        if not host_slug:
            raise PlanError("pass --host-slug or set AIDEVOPS_BUZZ_HOST_SLUG")
        app_data = (
            Path(os.path.expanduser(args.app_data_dir))
            if args.app_data_dir
            else default_app_data_dir()
        )
        identities = load_identities(app_data)
        buzz_bin = shutil.which("buzz")
        if buzz_bin is None:
            raise PlanError("buzz CLI not found on PATH")
        raw_channels = as_list(run_buzz_json(buzz_bin, ["channels", "list"]), "channels")
        live_channels = {}
        for raw in raw_channels:
            channel_id, name = channel_record(raw)
            if channel_id and name:
                live_channels[name] = channel_id
        live_members = {}
        for name, channel_id in live_channels.items():
            try:
                payload = run_buzz_json(buzz_bin, ["channels", "members", channel_id])
            except PlanError:
                continue  # unknown memberships are reported without member_add requests
            keys = member_pubkeys(payload)
            if keys is not None:  # unsupported shapes stay unreadable
                live_members[name] = keys
        plan = compute_plan(template, host_slug, identities, live_channels, live_members)
    except (PlanError, BuzzRuntimeError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(json.dumps(plan, indent=2, sort_keys=True) if args.as_json else render_text(plan))
    return 0


if __name__ == "__main__":
    sys.exit(main())
