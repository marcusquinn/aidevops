#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize conditional GitHub REST responses into pulse batch cache files."""

from __future__ import annotations

import datetime as _dt
import json
import os
import re
import sys
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


def _split_response(response_file: str) -> tuple[int, str, str]:
    raw = open(response_file, "rb").read().decode("utf-8", "replace")
    normalized = raw.replace("\r\n", "\n")
    headers, body = normalized.split("\n\n", 1) if "\n\n" in normalized else (normalized, "")
    match = re.search(r"^HTTP/\S+\s+(\d{3})", headers, re.M)
    if not match:
        raise ValueError("missing HTTP status")
    etag_match = re.search(r"^etag:\s*(.+)$", headers, re.I | re.M)
    return int(match.group(1)), etag_match.group(1).strip() if etag_match else "", body


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


def main(argv: list[str]) -> int:
    if len(argv) != 5:
        print("usage: pulse-batch-conditional-cache.py KIND SLUG RESPONSE_FILE CACHE_FILE", file=sys.stderr)
        return 2
    kind, _slug, response_file, cache_file = argv[1:5]
    status, etag, body = _split_response(response_file)
    now = _now_iso()
    if status == 304:
        if not os.path.exists(cache_file):
            return 1
        with open(cache_file, encoding="utf-8") as handle:
            payload = json.load(handle)
        if kind == "issues":
            items = payload.get("items") or []
            if any("state" not in item for item in items):
                return 1
            payload["items"] = [
                item
                for item in items
                if str(item.get("state") or "open").lower() == "open"
            ]
        payload.update(
            {
                "timestamp": now,
                "last_success": now,
                "conditional_status": 304,
                "conditional_cache_hit": True,
            }
        )
        if etag:
            payload["etag"] = etag
        _write_cache(cache_file, payload)
        print("304")
        return 0
    if status < 200 or status >= 300:
        return 1
    _write_cache(
        cache_file,
        {
            "timestamp": now,
            "last_success": now,
            "etag": etag,
            "conditional_status": status,
            "conditional_cache_hit": False,
            "items": _normalize_items(kind, body),
        },
    )
    print(str(status))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
