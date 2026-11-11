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

from _team_interface_buzz_runtime_install import default_app_data_dir

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


def template_channels(template):
    """Return {channel name: visibility} for all template channels."""
    channels = {}
    for section in template.get("sections", []):
        for channel in section.get("channels", []):
            channels[channel["name"]] = channel.get("visibility", "open")
    for channel in template.get("unsectioned_channels", []):
        channels[channel["name"]] = channel.get("visibility", "open")
    for name in template.get("agents", {}).get("repo_channels", {}):
        channels.setdefault(name, "open")
    return channels


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


def as_list(value, *keys):
    """Return a list from a bare list or a dict wrapping it under a known key."""
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for key in keys:
            if isinstance(value.get(key), list):
                return value[key]
    return []


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


def member_pubkeys(members):
    """Return the set of pubkeys in a buzz members payload."""
    keys = set()
    for member in as_list(members, "members"):
        if isinstance(member, str):
            keys.add(member)
        elif isinstance(member, dict):
            key = member.get("pubkey") or member.get("publicKey")
            if isinstance(key, str):
                keys.add(key)
    return keys


def compute_plan(template, host_slug, identities, live_channels, live_members):
    """Compute the community plan sections without any side effect."""
    wanted = template_channels(template)
    missing_channels = sorted(name for name in wanted if name not in live_channels)
    agents = template.get("agents", {})
    agent_channels = {role: list(channels) for role, channels in agents.get("channels", {}).items()}
    for channel, roles in agents.get("repo_channels", {}).items():
        for role in roles:
            channels = agent_channels.setdefault(role, [])
            if channel not in channels:
                channels.append(channel)
    missing_agents = []
    requests = []
    owner_actions = []
    unreadable_memberships = []
    executing_pubkey = identities.get(f"aidevops-{host_slug}")
    per_channel = {}
    for role, channels in agent_channels.items():
        name = f"{role}-{host_slug}"
        pubkey = identities.get(name)
        if pubkey is None:
            missing_agents.append(name)
            continue
        for channel in channels:
            per_channel.setdefault(channel, []).append((name, pubkey))
    for channel in sorted(per_channel):
        if channel not in live_channels:
            continue
        current = live_members.get(channel)
        if current is None:
            unreadable_memberships.append(channel)
            continue
        pending = [pk for _, pk in per_channel[channel] if pk not in current]
        if not pending:
            continue
        request = {
            "tool": "member_add",
            "channel": live_channels[channel],
            "channel_name": channel,
            "pubkeys": pending,
            "role": "bot",
        }
        requests.append(request)
        if wanted.get(channel) == "private" and executing_pubkey not in current:
            owner_actions.append(channel)
    return {
        "host_slug": host_slug,
        "missing_channels": missing_channels,
        "missing_agents": sorted(missing_agents),
        "member_add_requests": requests,
        "private_channels_needing_owner": owner_actions,
        "unreadable_memberships": unreadable_memberships,
    }


def render_text(plan):
    """Render the plan for humans."""
    lines = [f"Buzz community plan for host slug: {plan['host_slug']}", ""]
    lines.append("1. Missing channels (create in Buzz; local tools cannot):")
    lines += [f"   - {name}" for name in plan["missing_channels"]] or ["   none"]
    lines += ["", "2. Missing agent drafts (generate/submit via the snapshot flow):"]
    lines += [f"   - {name}" for name in plan["missing_agents"]] or ["   none"]
    lines += ["", "3. member_add requests (send to an existing aidevops Buzz agent",
              "   in that channel with `buzz messages send --mention`):"]
    for request in plan["member_add_requests"]:
        lines.append("   " + json.dumps(request, sort_keys=True))
    if not plan["member_add_requests"]:
        lines.append("   none")
    lines += ["", "4. Private channels where the owner must first add that agent",
               "   (member_add is refused with 'restricted: not a channel member'):"]
    lines += [f"   - {name}" for name in plan["private_channels_needing_owner"]] or ["   none"]
    lines += ["", "5. Unreadable memberships (unknown; no member_add requests planned):"]
    lines += [f"   - {name}" for name in plan["unreadable_memberships"]] or ["   none"]
    return "\n".join(lines)


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
            live_members[name] = member_pubkeys(payload)
        plan = compute_plan(template, host_slug, identities, live_channels, live_members)
    except (PlanError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(json.dumps(plan, indent=2, sort_keys=True) if args.as_json else render_text(plan))
    return 0


if __name__ == "__main__":
    sys.exit(main())
