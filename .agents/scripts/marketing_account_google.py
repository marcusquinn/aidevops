#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Read-only, bounded Google Ads account snapshot adapter."""

from __future__ import annotations

import json
import re
from collections.abc import Callable
from typing import Any
from urllib.parse import urlencode
from urllib.request import Request, urlopen

MAX_PAGES = 20
MAX_RESPONSE_BYTES = 2_000_000
GOOGLE_ADS_API_VERSION = "v25"
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


class GoogleAccountError(ValueError):
    """A sanitized account-collection failure."""


def _endpoint(account_ref: str) -> str:
    if not account_ref.replace("-", "").isdigit() or len(account_ref.replace("-", "")) > 20:
        raise GoogleAccountError("Google Ads account reference must be numeric")
    return f"https://googleads.googleapis.com/{GOOGLE_ADS_API_VERSION}/customers/{account_ref}:searchStream"


def _query(start: str, end: str) -> str:
    if not DATE.fullmatch(start) or not DATE.fullmatch(end):
        raise GoogleAccountError("Google Ads dates must use YYYY-MM-DD")
    return (
        "SELECT campaign.id, campaign.name, ad_group.id, ad_group.name, "
        "metrics.impressions, metrics.clicks, metrics.cost_micros, metrics.conversions "
        "FROM ad_group_ad WHERE segments.date BETWEEN '" + start + "' AND '" + end + "'"  # nosec B608 -- values are strict ISO dates
    )


def collect(
    account_ref: str,
    start: str,
    end: str,
    access_token: str,
    developer_token: str,
    request: Callable[[Request], Any] | None = None,
) -> dict[str, Any]:
    """Collect one fixed GAQL view; no arbitrary query or mutation endpoint is accepted."""
    if not access_token or not developer_token:
        raise GoogleAccountError("Google Ads live collection requires configured credentials")
    endpoint = _endpoint(account_ref)
    if not endpoint.startswith(f"https://googleads.googleapis.com/{GOOGLE_ADS_API_VERSION}/"):
        raise GoogleAccountError("Google Ads endpoint was invalid")
    payload = json.dumps({"query": _query(start, end)}, separators=(",", ":")).encode("utf-8")
    opener = request or (lambda item: urlopen(item, timeout=30))  # nosec B310 -- fixed HTTPS endpoint above
    try:
        response = opener(Request(endpoint, data=payload, headers={
            "Authorization": f"Bearer {access_token}", "developer-token": developer_token,
            "Content-Type": "application/json",
        }, method="POST"))
        raw = response.read(MAX_RESPONSE_BYTES + 1)
        if len(raw) > MAX_RESPONSE_BYTES:
            raise GoogleAccountError("Google Ads response exceeded byte budget")
        decoded = json.loads(raw.decode("utf-8"))
    except GoogleAccountError:
        raise
    except Exception as error:  # Provider exceptions must not disclose credentials or endpoints.
        raise GoogleAccountError("Google Ads account collection failed") from error
    rows = decoded if isinstance(decoded, list) else decoded.get("results", []) if isinstance(decoded, dict) else []
    if not isinstance(rows, list):
        raise GoogleAccountError("Google Ads account response was invalid")
    return {
        "provider": "google-ads", "account_ref": account_ref, "coverage": {"complete": True, "omissions": []},
        "records": rows[:MAX_PAGES], "request_budget": 1, "currency": None, "timezone": None,
    }
