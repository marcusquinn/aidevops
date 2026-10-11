#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only Hostinger fleet I/O: paginated API GETs and an SSH multisite probe.

Both refuse partial results. The API token is passed in by the caller and is
never logged; SSH runs one fixed, read-only script over validated roots.
"""

from __future__ import annotations

import json
import re
import shlex
import subprocess  # nosec B404 - fixed argv SSH probe only
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hosting_fleet_inventory import DOMAIN_RE, WP_ROOT_RE, FleetError  # noqa: E402

API_BASE = "https://developers.hostinger.com"
WEBSITES_PATH = "/api/hosting/v1/websites"
PAGE_SIZE = 100
MAX_PAGES = 50
SSH_ALIAS_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$")
PROBE_STATES = ("absent", "single", "multisite")
# Prints "<root>\t<absent|single|multisite>\t<space-separated blog URLs>" per root.
PROBE_SCRIPT = (
    "for root in {roots}; do "
    'if [ ! -f "$root/wp-config.php" ]; then printf "%s\\tabsent\\t\\n" "$root"; '
    'elif (cd "$root" && wp core is-installed --network --skip-plugins --skip-themes) '
    ">/dev/null 2>&1; then "
    'urls=$(cd "$root" && wp site list --field=url --skip-plugins --skip-themes 2>/dev/null '
    '| tr "\\n" " "); printf "%s\\tmultisite\\t%s\\n" "$root" "$urls"; '
    'else printf "%s\\tsingle\\t\\n" "$root"; fi; done'
)


def api_get(base_url: str, path: str, query: dict[str, Any], token: str) -> Any:
    """Issue one authenticated GET request and decode JSON."""
    if not base_url.startswith("https://"):
        raise FleetError("Hostinger API base URL must use HTTPS")
    url = f"{base_url.rstrip('/')}{path}?{urllib.parse.urlencode(query)}"
    request = urllib.request.Request(  # noqa: S310 - HTTPS enforced above
        url,
        method="GET",
        # The API edge rejects urllib's default User-Agent with HTTP 403.
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "User-Agent": "aidevops-hostinger-fleet/1",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:  # nosec B310
            return json.load(response)
    except urllib.error.HTTPError as exc:
        raise FleetError(f"Hostinger API returned HTTP {exc.code} for {path}") from exc
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise FleetError(f"Hostinger API request failed for {path}") from exc


def websites_page(payload: Any) -> tuple[list[dict[str, Any]], int]:
    """Validate one websites page and return its data and total."""
    data = payload.get("data") if isinstance(payload, dict) else None
    meta = payload.get("meta") if isinstance(payload, dict) else None
    if not isinstance(data, list) or not isinstance(meta, dict):
        raise FleetError("Unexpected Hostinger websites response shape")
    return data, int(meta.get("total", 0))


def fetch_websites(base_url: str, token: str, username: str | None) -> list[dict[str, Any]]:
    """Collect every website page; refuse partial results."""
    websites: list[dict[str, Any]] = []
    total = -1
    for page in range(1, MAX_PAGES + 1):
        query: dict[str, Any] = {"page": page, "per_page": PAGE_SIZE}
        if username:
            query["username"] = username
        data, total = websites_page(api_get(base_url, WEBSITES_PATH, query, token))
        websites.extend(data)
        if not data or len(websites) >= total:
            break
    if len(websites) != total:
        raise FleetError("Incomplete Hostinger website inventory; refusing a partial result")
    return websites


def site_host(url: str) -> str | None:
    """Return a lowercase site host without a leading www label."""
    host = (urllib.parse.urlsplit(url.strip()).hostname or "").lower().rstrip(".")
    host = host[4:] if host.startswith("www.") else host
    return host if DOMAIN_RE.match(host) else None


def parse_probe(output: str, roots: list[str]) -> dict[str, dict[str, Any]]:
    """Strictly parse probe output; any unexpected or missing root fails closed."""
    results: dict[str, dict[str, Any]] = {}
    for line in output.splitlines():
        root, _, rest = line.partition("\t")
        status, _, urls = rest.partition("\t")
        if root not in roots or status not in PROBE_STATES:
            raise FleetError("Unexpected SSH network discovery output")
        domains = sorted({host for host in (site_host(url) for url in urls.split()) if host})
        results[root] = {"status": status, "domains": domains}
    if set(results) != set(roots):
        raise FleetError("Incomplete SSH network discovery; refusing a partial result")
    return results


def discover_networks(alias: str, roots: list[str]) -> dict[str, dict[str, Any]]:
    """Read-only SSH probe: classify each root and list multisite blog hosts."""
    if not SSH_ALIAS_RE.match(alias):
        raise FleetError("SSH alias must be a configured Host alias")
    if any(not WP_ROOT_RE.match(root) for root in roots):
        raise FleetError("Refusing to probe a document root outside domains/<domain>/public_html")
    if not roots:
        return {}
    script = PROBE_SCRIPT.format(roots=" ".join(shlex.quote(root) for root in roots))
    try:
        output = subprocess.run(  # nosec B603 B607 - fixed argv, validated alias and roots
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", alias, script],
            check=True,
            capture_output=True,
            text=True,
            timeout=600,
        ).stdout
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        raise FleetError("SSH network discovery failed; no partial result was used") from exc
    return parse_probe(output, roots)
