#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Private outbound payload bounds and versioned stored-intent integrity.

These pure checks do not create transactions or grant operation authority.
"""

from __future__ import annotations

import hashlib
import re
import sqlite3
from typing import Any

from knowledge_social_import import canonical_json
from knowledge_social_store import SocialStoreError

MAX_PAYLOAD_BYTES = 16 * 1024


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _validated_payload(action: str, payload: str | None) -> str | None:
    if action in ("post", "reply"):
        if payload is None or not payload.strip() or "\x00" in payload:
            raise SocialStoreError(f"{action} requires a non-empty private body file")
        if len(payload.encode("utf-8")) > MAX_PAYLOAD_BYTES:
            raise SocialStoreError("outbound body exceeds the private payload limit")
        return payload
    if payload is not None:
        raise SocialStoreError(f"{action} does not accept a body")
    return None


def _intent_document(values: dict[str, Any]) -> dict[str, Any]:
    version = int(values["intent_version"])
    document = {
        "version": version,
        "operation_id": values["operation_id"],
        "provider": values["provider"],
        "connection_id": values["connection_id"],
        "remote_account_id": values["remote_account_id"],
        "action": values["action"],
        "target_remote_id": values["target_remote_id"],
        "payload_sha256": values["payload_sha256"],
        "app_profile": values["app_profile"],
        "username": values["username"],
        "scheduled_at": values["scheduled_at"],
        "created_by": values["created_by"],
    }
    if version in (2, 3):
        document.update(
            {
                "destination_remote_id": values["destination_remote_id"],
                "subject_sha256": values["subject_sha256"],
            }
        )
    if version == 3:
        document.update(
            {
                "media_path": values["media_path"],
                "media_sha256": values["media_sha256"],
            }
        )
    elif version not in (1, 2):
        raise SocialStoreError("unsupported outbound intent version")
    return document


def _intent_sha256(values: dict[str, Any]) -> str:
    return _digest(canonical_json(_intent_document(values)))


def _verify_operation_row(row: sqlite3.Row) -> sqlite3.Row:
    payload_sha256 = _digest(row["payload"] or "")
    if payload_sha256 != row["payload_sha256"]:
        raise SocialStoreError("outbound operation payload integrity check failed")
    intent_version = int(row["intent_version"])
    if intent_version == 1:
        if any(
            row[field] is not None
            for field in ("destination_remote_id", "subject", "subject_sha256")
        ):
            raise SocialStoreError("legacy outbound operation has unbound provider fields")
    elif intent_version in (2, 3):
        subject_sha256 = _digest(row["subject"] or "")
        if subject_sha256 != row["subject_sha256"]:
            raise SocialStoreError("outbound operation subject integrity check failed")
        if intent_version == 3 and (
            (row["media_path"] is None) != (row["media_sha256"] is None)
            or (
                row["media_sha256"] is not None
                and re.fullmatch(r"[0-9a-f]{64}", str(row["media_sha256"])) is None
            )
        ):
            raise SocialStoreError("outbound operation media integrity check failed")
    else:
        raise SocialStoreError("unsupported outbound intent version")
    values = dict(row)
    values["payload_sha256"] = payload_sha256
    if _intent_sha256(values) != row["intent_sha256"]:
        raise SocialStoreError("outbound operation intent integrity check failed")
    return row
