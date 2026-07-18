#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize conditional GitHub REST responses into canonical Pulse snapshots."""

from __future__ import annotations

import datetime as _dt
import json
import os
import re
import sys
from dataclasses import dataclass
from typing import Any


def _now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _write_cache(cache_file: str, payload: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(cache_file), exist_ok=True)
    tmp = f"{cache_file}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, separators=(",", ":"))
        handle.write("\n")
    os.replace(tmp, cache_file)


_SNAPSHOT_SCHEMA = "aidevops-pulse-snapshot/v1"


@dataclass(frozen=True)
class _SnapshotContext:
    kind: str
    slug: str
    projection: str
    auth_scope: str
    generation: str
    now: str


@dataclass(frozen=True)
class _ConditionalResponse:
    source: str
    etag: str
    status: int
    complete: bool
    items: list[dict[str, Any]]


def _split_response(response_file: str) -> tuple[int, str, bool, str]:
    raw = open(response_file, "rb").read().decode("utf-8", "replace")
    normalized = raw.replace("\r\n", "\n")
    headers, body = normalized.split("\n\n", 1) if "\n\n" in normalized else (normalized, "")
    match = re.search(r"^HTTP/\S+\s+(\d{3})", headers, re.M)
    if not match:
        raise ValueError("missing HTTP status")
    etag_match = re.search(r"^etag:\s*(.+)$", headers, re.I | re.M)
    link_match = re.search(r"^link:\s*(.+)$", headers, re.I | re.M)
    has_next = bool(link_match and re.search(r'rel="next"', link_match.group(1), re.I))
    return (
        int(match.group(1)),
        etag_match.group(1).strip() if etag_match else "",
        has_next,
        body,
    )


def _normalize_items(kind: str, body: str) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    for item in json.loads(body or "[]"):
        if kind == "issues":
            if item.get("pull_request") is not None:
                continue
            items.append(
                {
                    "number": item.get("number"),
                    "title": item.get("title"),
                    "state": item.get("state") or "open",
                    "labels": item.get("labels") or [],
                    "updatedAt": item.get("updated_at") or item.get("updatedAt"),
                    "assignees": item.get("assignees") or [],
                }
            )
            continue
        user = item.get("user") or {}
        head = item.get("head") or {}
        items.append(
            {
                "number": item.get("number"),
                "title": item.get("title"),
                "labels": item.get("labels") or [],
                "updatedAt": item.get("updated_at") or item.get("updatedAt"),
                "assignees": item.get("assignees") or [],
                "createdAt": item.get("created_at") or item.get("createdAt"),
                "author": {"login": user.get("login")} if user.get("login") else item.get("author"),
                "headRefOid": head.get("sha"),
                "headRefName": head.get("ref"),
            }
        )
    return items


def _snapshot_payload(
    context: _SnapshotContext,
    response: _ConditionalResponse,
) -> dict[str, Any]:
    return {
        "schema": _SNAPSHOT_SCHEMA,
        "repository": context.slug,
        "collection": context.kind,
        "projection": context.projection,
        "auth_scope": context.auth_scope,
        "generation": context.generation,
        "source": response.source,
        "complete": response.complete,
        "truncated": not response.complete,
        "fetched_at": context.now,
        "timestamp": context.now,
        "last_success": context.now,
        "etag": response.etag,
        "validator": {"etag": response.etag} if response.etag else {},
        "conditional_status": response.status,
        "conditional_cache_hit": response.status == 304,
        "items": response.items,
    }


def main(argv: list[str]) -> int:
    result = 0
    if len(argv) != 8:
        print(
            "usage: pulse-batch-conditional-cache.py KIND SLUG RESPONSE_FILE "
            "CACHE_FILE GENERATION AUTH_SCOPE PROJECTION",
            file=sys.stderr,
        )
        result = 2
    else:
        kind, slug, response_file, cache_file, generation, auth_scope, projection = argv[1:8]
        status, etag, has_next, body = _split_response(response_file)
        now = _now_iso()
        context = _SnapshotContext(kind, slug, projection, auth_scope, generation, now)
        if status == 304:
            result = _refresh_cached_response(context, cache_file, etag)
        elif status < 200 or status >= 300:
            result = 1
        else:
            _write_cache(
                cache_file,
                _snapshot_payload(
                    context,
                    _ConditionalResponse(
                        source="conditional-rest",
                        etag=etag,
                        status=status,
                        complete=not has_next,
                        items=_normalize_items(kind, body),
                    ),
                ),
            )
            print(str(status))
    return result


def _refresh_cached_response(
    context: _SnapshotContext,
    cache_file: str,
    etag: str,
) -> int:
    if not os.path.exists(cache_file):
        return 1
    with open(cache_file, encoding="utf-8") as handle:
        payload = json.load(handle)
    items = payload.get("items")
    if not isinstance(items, list) or any(not isinstance(item, dict) for item in items):
        return 1
    if context.kind == "issues":
        if any("state" not in item for item in items):
            return 1
        payload["items"] = [
            item
            for item in items
            if str(item.get("state") or "open").lower() == "open"
        ]
    compatible = all(
        (
            payload.get("schema") == _SNAPSHOT_SCHEMA,
            payload.get("repository") == context.slug,
            payload.get("collection") == context.kind,
            payload.get("projection") == context.projection,
            payload.get("auth_scope") == context.auth_scope,
            isinstance(payload.get("complete"), bool),
        )
    )
    payload.update(
        {
            "schema": _SNAPSHOT_SCHEMA if compatible else payload.get("schema", "legacy"),
            "repository": context.slug,
            "collection": context.kind,
            "projection": context.projection if compatible else payload.get("projection", "legacy"),
            "auth_scope": context.auth_scope,
            "generation": context.generation,
            "source": "conditional-rest",
            "complete": payload.get("complete", False) if compatible else False,
            "truncated": not (payload.get("complete", False) if compatible else False),
            "fetched_at": context.now,
            "timestamp": context.now,
            "last_success": context.now,
            "conditional_status": 304,
            "conditional_cache_hit": True,
        }
    )
    if etag:
        payload["etag"] = etag
        payload["validator"] = {"etag": etag}
    _write_cache(cache_file, payload)
    print("304")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
