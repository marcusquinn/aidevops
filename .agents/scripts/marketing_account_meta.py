#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Read-only, bounded Meta Marketing API account snapshot adapter."""

from __future__ import annotations

import json
from collections.abc import Callable
from typing import Any
from urllib.parse import urlencode
from urllib.request import Request, urlopen

MAX_PAGES = 20
MAX_RESPONSE_BYTES = 2_000_000
META_GRAPH_VERSION = "v24.0"


class MetaAccountError(ValueError):
    """A sanitized account-collection failure."""


def _account_id(account_ref: str) -> str:
    value = account_ref.removeprefix("act_")
    if not value.isdigit() or len(value) > 20:
        raise MetaAccountError("Meta account reference must be act_<numeric-id>")
    return f"act_{value}"


def collect(
    account_ref: str,
    start: str,
    end: str,
    access_token: str,
    request: Callable[[Request], Any] | None = None,
) -> dict[str, Any]:
    """Fetch a fixed insights view with a bounded official pagination path."""
    account_id = _account_id(account_ref)
    if not access_token:
        raise MetaAccountError("Meta live collection requires configured credentials")
    params = urlencode({"fields": "campaign_id,campaign_name,adset_id,ad_id,impressions,clicks,spend,actions", "time_range": json.dumps({"since": start, "until": end}), "limit": MAX_PAGES})
    endpoint = f"https://graph.facebook.com/{META_GRAPH_VERSION}/{account_id}/insights?{params}"
    if not endpoint.startswith(f"https://graph.facebook.com/{META_GRAPH_VERSION}/"):
        raise MetaAccountError("Meta endpoint was invalid")
    opener = request or (lambda item: urlopen(item, timeout=30))  # nosec B310 -- fixed HTTPS endpoint above
    try:
        response = opener(Request(endpoint, headers={"Authorization": f"Bearer {access_token}"}, method="GET"))
        raw = response.read(MAX_RESPONSE_BYTES + 1)
        if len(raw) > MAX_RESPONSE_BYTES:
            raise MetaAccountError("Meta response exceeded byte budget")
        decoded = json.loads(raw.decode("utf-8"))
    except MetaAccountError:
        raise
    except Exception as error:
        raise MetaAccountError("Meta account collection failed") from error
    rows = decoded.get("data", []) if isinstance(decoded, dict) else []
    if not isinstance(rows, list):
        raise MetaAccountError("Meta account response was invalid")
    return {
        "provider": "meta", "account_ref": account_id,
        "coverage": {"complete": not bool(decoded.get("paging")) if isinstance(decoded, dict) else False,
                     "omissions": ["additional pages not collected"] if isinstance(decoded, dict) and decoded.get("paging") else []},
        "records": rows, "request_budget": 1, "currency": None, "timezone": None,
    }
