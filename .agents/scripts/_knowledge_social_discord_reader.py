#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and fixture readers for the read-only Discord adapter."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from _knowledge_social_discord import (
    DiscordAdapterError,
    DiscordProviderUnavailableError,
    snowflake,
)
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from _knowledge_social_reader_contract import FixtureReader, ReaderContract
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_PROVIDER_FAILURES = (
    "Discord bot profile token is missing",
    "Discord bot profile configuration is invalid",
    "Discord identity does not match the configured connection",
    "Discord account export is unavailable",
    "Discord gateway event spool is unavailable",
)


CONTRACT = ReaderContract(
    adapter_error=DiscordAdapterError,
    unavailable_error=DiscordProviderUnavailableError,
    max_response_bytes=MAX_RESPONSE_BYTES,
    safe_failures=SAFE_PROVIDER_FAILURES,
    unavailable_message='Discord read provider is unavailable',
    oversize_message='Discord read response exceeds the safety limit',
    invalid_json_message='Discord read provider returned no valid JSON',
    root_message='Discord read response root must be an object',
    expectation_message='Discord fixture expectation must be an object',
    checkpoint_message='Discord request did not resume at the checkpoint',
    response_message='Discord fixture page must be an object',
)


DISCORD_BOT_POLICY = GuardedOAuthPolicy(
    "Discord",
    "DISCORD",
    "DISCORD_READ_LOG",
    READ_TIMEOUT_SECONDS,
    CONTRACT.decode_output,
    CONTRACT.provider_failure,
    DiscordProviderUnavailableError,
    (
        "BOT_TOKEN",
        "APPLICATION_ID",
        "GUILD_ID",
        "CHANNEL_IDS",
        "THREAD_IDS",
        "DM_CHANNEL_IDS",
        "MESSAGE_CONTENT_INTENT",
        "GUILD_MEMBERS_INTENT",
        "EXPORT_USER_ID",
        "EXPORT_PATH",
        "GATEWAY_EVENTS_PATH",
    ),
    "bot",
)


class GuardedDiscordBot(GuardedOAuthReader):
    """Execute only identity and allowlisted GET/local-replay reads."""

    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, DISCORD_BOT_POLICY)


class FixtureDiscord(FixtureReader):
    """Deterministic provider substitute for Discord collection fixtures."""

    def __init__(self, path: Path) -> None:
        super().__init__(path, 'Discord', CONTRACT)


def _bool(value: Any, field: str) -> bool:
    if not isinstance(value, bool):
        raise DiscordAdapterError(f"Discord {field} must be boolean")
    return value


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Validate application, bot, guild, allowlists, and export user binding."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise DiscordAdapterError("Discord identity returned no account")
    bot_id = snowflake(data.get("id"), "bot user ID")
    if bot_id != expected_id:
        raise DiscordAdapterError("Discord identity does not match the configured connection")
    result = {
        "id": bot_id,
        "application_id": snowflake(data.get("application_id"), "application ID"),
        "guild_id": snowflake(data.get("guild_id"), "guild ID"),
        "channel_ids": data.get("channel_ids"),
        "thread_ids": data.get("thread_ids"),
        "dm_channel_ids": data.get("dm_channel_ids"),
        "message_content_intent": _bool(
            data.get("message_content_intent"), "message-content intent"
        ),
        "guild_members_intent": _bool(
            data.get("guild_members_intent"), "guild-members intent"
        ),
        "export_user_id": data.get("export_user_id"),
    }
    for field in ("channel_ids", "thread_ids", "dm_channel_ids"):
        values = result[field]
        if not isinstance(values, list):
            raise DiscordAdapterError(f"Discord {field} must be an array")
        result[field] = [snowflake(value, field) for value in values]
    if result["export_user_id"] is not None:
        result["export_user_id"] = snowflake(result["export_user_id"], "export user ID")
    return result
