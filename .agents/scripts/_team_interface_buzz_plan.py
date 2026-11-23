# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Pure planning and rendering helpers for the Buzz community plan."""

import json


def as_list(value, *keys):
    """Return a list from a bare list or a dict wrapping it under a known key."""
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for key in keys:
            if isinstance(value.get(key), list):
                return value[key]
    return []


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


def member_pubkeys(members):
    """Return the set of pubkeys in a buzz members payload, or None if unsupported."""
    if isinstance(members, dict):
        members = members.get("members")
    if not isinstance(members, list):
        return None
    keys = set()
    for member in members:
        if isinstance(member, str):
            keys.add(member)
        elif isinstance(member, dict):
            key = member.get("pubkey") or member.get("publicKey")
            if isinstance(key, str):
                keys.add(key)
    return keys


def agent_channel_map(agents):
    """Return {role: [channels]} including repo channel assignments."""
    agent_channels = {role: list(channels) for role, channels in agents.get("channels", {}).items()}
    for channel, roles in agents.get("repo_channels", {}).items():
        for role in roles:
            channels = agent_channels.setdefault(role, [])
            if channel not in channels:
                channels.append(channel)
    return agent_channels


def resolve_agents(agent_channels, host_slug, identities):
    """Return (missing agent names, {channel: [(name, pubkey)]})."""
    missing = []
    per_channel = {}
    for role, channels in agent_channels.items():
        name = f"{role}-{host_slug}"
        pubkey = identities.get(name)
        if pubkey is None:
            missing.append(name)
            continue
        for channel in channels:
            per_channel.setdefault(channel, []).append((name, pubkey))
    return missing, per_channel


def member_add_request(channel, channel_id, pending):
    """Build one member_add request."""
    return {
        "tool": "member_add",
        "channel": channel_id,
        "channel_name": channel,
        "pubkeys": pending,
        "role": "bot",
    }


def plan_memberships(per_channel, wanted, live_channels, live_members, executing_pubkey):
    """Return (requests, owner actions, unreadable memberships)."""
    requests = []
    owner_actions = []
    unreadable = []
    for channel in sorted(c for c in per_channel if c in live_channels):
        current = live_members.get(channel)
        if current is None:
            unreadable.append(channel)
            continue
        pending = [pk for _, pk in per_channel[channel] if pk not in current]
        if not pending:
            continue
        requests.append(member_add_request(channel, live_channels[channel], pending))
        if wanted.get(channel) == "private" and executing_pubkey not in current:
            owner_actions.append(channel)
    return requests, owner_actions, unreadable


def compute_plan(template, host_slug, identities, live_channels, live_members):
    """Compute the community plan sections without any side effect."""
    wanted = template_channels(template)
    agent_channels = agent_channel_map(template.get("agents", {}))
    missing_agents, per_channel = resolve_agents(agent_channels, host_slug, identities)
    requests, owner_actions, unreadable = plan_memberships(
        per_channel, wanted, live_channels, live_members, identities.get(f"aidevops-{host_slug}")
    )
    return {
        "host_slug": host_slug,
        "missing_channels": sorted(name for name in wanted if name not in live_channels),
        "missing_agents": sorted(missing_agents),
        "member_add_requests": requests,
        "private_channels_needing_owner": owner_actions,
        "unreadable_memberships": unreadable,
    }


def bullets(names):
    """Render names as bullet lines, or 'none'."""
    return [f"   - {name}" for name in names] or ["   none"]


def render_text(plan):
    """Render the plan for humans."""
    lines = [f"Buzz community plan for host slug: {plan['host_slug']}", ""]
    lines.append("1. Missing channels (create in Buzz; local tools cannot):")
    lines += bullets(plan["missing_channels"])
    lines += ["", "2. Missing agent drafts (generate/submit via the snapshot flow):"]
    lines += bullets(plan["missing_agents"])
    lines += ["", "3. member_add requests (send to an existing aidevops Buzz agent",
              "   in that channel with `buzz messages send --mention`):"]
    lines += [
        "   " + json.dumps(request, sort_keys=True) for request in plan["member_add_requests"]
    ] or ["   none"]
    lines += ["", "4. Private channels where the owner must first add that agent",
              "   (member_add is refused with 'restricted: not a channel member'):"]
    lines += bullets(plan["private_channels_needing_owner"])
    lines += ["", "5. Unreadable memberships (unknown; no member_add requests planned):"]
    lines += bullets(plan["unreadable_memberships"])
    return "\n".join(lines)
