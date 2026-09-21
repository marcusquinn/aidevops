#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Safe local digest selection and outbox state transitions."""
from __future__ import annotations

import hashlib
from typing import Any
from urllib.parse import urlparse


class AlertError(ValueError):
    pass


def verified_destination(value: dict[str, Any]) -> dict[str, str]:
    kind, target = value.get("kind"), value.get("target")
    if kind not in {"slack", "discord", "email", "webhook"} or not isinstance(target, str) or not target:
        raise AlertError("destination must be an explicit supported internal target")
    if kind == "webhook":
        parsed = urlparse(target)
        has_credentials = bool(parsed.username or parsed.password)
        hostname = parsed.hostname.lower() if parsed.hostname else ""
        is_local = hostname in {"localhost", "127.0.0.1", "::1"}
        if parsed.scheme != "https" or not hostname or has_credentials or is_local:
            raise AlertError("webhook destination is not an approved HTTPS target")
    return {"kind": kind, "target": target}


def digest(leads: list[dict[str, Any]], delivered: set[str], hidden: set[str]) -> list[dict[str, Any]]:
    rows = []
    for lead in leads:
        lead_id = lead.get("lead_id")
        version = lead.get("evidence_version")
        if not isinstance(lead_id, str) or not isinstance(version, str):
            continue
        key = f"{lead_id}:{version}"
        if key in delivered or lead_id in hidden or not lead.get("qualifies", True):
            continue
        rows.append({"lead_id": lead_id, "version": version, "score": lead.get("score"),
                     "reason": lead.get("reason", ""), "evidence_link": lead.get("evidence_link", ""),
                     "community_policy": lead.get("community_policy", "unknown")})
    return rows


def outbox_key(project: str, destination: dict[str, str], window: str, rows: list[dict[str, Any]]) -> str:
    material = "\0".join([project, destination["kind"], destination["target"], window, *sorted(f"{r['lead_id']}:{r['version']}" for r in rows)])
    return hashlib.sha256(material.encode()).hexdigest()


def enqueue(outbox: dict[str, Any], project: str, destination: dict[str, Any], window: str, rows: list[dict[str, Any]]) -> dict[str, Any] | None:
    if not rows:
        return None
    target = verified_destination(destination)
    key = outbox_key(project, target, window, rows)
    return outbox.setdefault(key, {"id": key, "status": "pending", "destination": target, "leads": rows})


def transition(entry: dict[str, Any], status: str) -> dict[str, Any]:
    if status not in {"sending", "sent", "failed", "unknown"}:
        raise AlertError("invalid outbox status")
    if entry["status"] == "sent":
        return entry
    entry["status"] = status
    return entry
