"""Build portable Buzz member identities and dormant agent definitions."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import re

from _team_interface_buzz_avatar import member_avatar_data_url


GUIDE_AGENT_ID = "agent.aidevops-guide"
BUZZ_AGENT_FORMAT = "buzz-agent-snapshot"
FORMAT_VERSION = 1
AIDEVOPS_RUNTIME_ID = "aidevops-interactive-v1"
PRIVATE_AGENT_ID = "agent.private-local-ai"
PRIVATE_RUNTIME_ID = "buzz-agent"
PRIVATE_PROVIDER_ID = "relay-mesh"
PRIVATE_MODEL_ID = "auto"
HOST_SLUG_PATTERN = re.compile(r"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$")


class ProvisioningError(ValueError):
    """Raised when a safe deterministic provisioning step cannot continue."""


def normalize_slug(value, label, maximum_length):
    """Normalize one local presentation component to lowercase ASCII dashes."""
    if not isinstance(value, str):
        raise ProvisioningError(f"{label} must be a string")
    slug = re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")
    if not slug or len(slug) > maximum_length or not HOST_SLUG_PATTERN.fullmatch(slug):
        raise ProvisioningError(f"{label} is unavailable or invalid")
    return slug


def agent_role_slug(record):
    """Return the stable lowercase role component for one roster record."""
    if record["agent_id"] == GUIDE_AGENT_ID:
        return "aidevops"
    prefix = "agent."
    agent_id = record["agent_id"]
    if not agent_id.startswith(prefix):
        raise ProvisioningError(f"agent ID cannot produce a Buzz role slug: {agent_id}")
    return normalize_slug(agent_id.removeprefix(prefix), "Buzz role slug", 32)


def buzz_display_name(record, host_slug):
    """Map one portable roster record to its host-qualified Buzz name."""
    display_name = f"{agent_role_slug(record)}-{host_slug}"
    if len(display_name) > 100:
        raise ProvisioningError("host-qualified Buzz display name exceeds 100 characters")
    return display_name


def member_system_prompt(record):
    """Build a pointer prompt without copying canonical instruction bodies."""
    if record["agent_id"] == PRIVATE_AGENT_ID:
        return "\n".join(
            (
                f"Aidevops canonical source: {record['source_ref']}",
                f"Expected source digest: {record['source_digest']}",
                f"Portable workload tier: {record['workload_tier']}",
                "You are Private AI, a private investigator using privacy-first AI methods.",
                "Minimize data disclosure; separate facts, inferences, and uncertainty; "
                "never expose credentials or unrelated personal data.",
                "Do not describe Buzz shared compute as local, private, or on-device unless "
                "the active execution boundary independently verifies that claim.",
                "This portable definition grants no authority and carries no credentials.",
            )
        )
    return "\n".join(
        (
            f"Aidevops canonical source: {record['source_ref']}",
            f"Expected source digest: {record['source_digest']}",
            f"Portable workload tier: {record['workload_tier']}",
            "Resolve and verify that installed aidevops source through the supported "
            "aidevops conversation runtime before handling a request.",
            "If the source is unavailable or its digest differs, stop and report that "
            "the runtime is not configured for this agent.",
            "Follow the verified source as this agent's instructions. This portable "
            "definition grants no authority and carries no credentials.",
        )
    )


def build_member(record, host_slug):
    """Build one dormant Buzz agent snapshot member with reviewed routing."""
    display_name = buzz_display_name(record, host_slug)
    definition = {
        "name": display_name,
        "parallelism": 1,
        "respondTo": "owner-only",
        "runtime": AIDEVOPS_RUNTIME_ID,
        "sourceIsBuiltin": False,
        "systemPrompt": member_system_prompt(record),
    }
    if record["agent_id"] == PRIVATE_AGENT_ID:
        definition.update(
            {
                "model": PRIVATE_MODEL_ID,
                "provider": PRIVATE_PROVIDER_ID,
                "runtime": PRIVATE_RUNTIME_ID,
            }
        )
    return {
        "definition": definition,
        "format": BUZZ_AGENT_FORMAT,
        "memory": {"level": "none"},
        "profile": {
            "about": record["description"],
            "avatarDataUrl": member_avatar_data_url(record),
            "displayName": display_name,
        },
        "version": FORMAT_VERSION,
    }
