#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Read-only analysis service and finding projection adapters."""

import html
import json
import os
import re
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, quote, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


def exact(path):
    if not isinstance(path, str) or not re.fullmatch(
        r"[A-Za-z0-9_.()\[\]-]+(?:/[A-Za-z0-9_.()\[\]-]+)*", path
    ) or any(part in (".", "..", ".git") for part in path.split("/")):
        raise ValueError("Expected an exact repository-relative path")
    return path


def repository(value):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", value):
        raise ValueError("Expected owner/repository")
    return value


class NoServiceRedirect(HTTPRedirectHandler):
    """Do not forward authenticated service requests to redirect targets."""

    def redirect_request(self, *args, **kwargs):
        raise ValueError("Service redirect refused")


def request_json(url, headers, payload=None):
    parsed = urlsplit(url)
    if parsed.scheme != "https" or parsed.netloc not in ("sonarcloud.io", "api.codacy.com"):
        raise ValueError("Only the configured HTTPS analysis services are permitted")
    body = None if payload is None else json.dumps(payload).encode()
    request = Request(url, data=body, headers={**headers, "Content-Type": "application/json"})
    try:
        with build_opener(NoServiceRedirect()).open(request, timeout=60) as response:
            return json.load(response)
    except HTTPError as error:
        raise ValueError(f"Service request failed (HTTP {error.code})") from None
    except URLError:
        raise ValueError("Service request failed (network)") from None


def fetch_sonar(key):
    findings = []
    headers = {}
    if os.environ.get("SONAR_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["SONAR_TOKEN"]
    page = 1
    while True:
        query = urlencode(dict(componentKeys=key, types="CODE_SMELL", resolved="false", ps=500, p=page))
        data = request_json("https://sonarcloud.io/api/issues/search?" + query, headers)
        rows = data["issues"]
        findings.extend(rows)
        total = data.get("total", data.get("paging", {}).get("total"))
        if total is None:
            raise ValueError("SonarCloud response has no total")
        if page * 500 >= total:
            return findings
        if not rows:
            raise ValueError("SonarCloud pagination ended before total")
        page += 1


def fetch_codacy(repo):
    token = os.environ.get("CODACY_API_TOKEN")
    if not token:
        raise ValueError("CODACY_API_TOKEN is required for live findings")
    org, name = repo.split("/")
    base = ("https://api.codacy.com/api/v3/analysis/organizations/gh/"
            f"{quote(org, safe='')}/repositories/{quote(name, safe='')}/issues/search")
    rows, seen, cursor = [], set(), None
    while True:
        query = {"limit": 1000}
        if cursor:
            query["cursor"] = cursor
        data = request_json(base + "?" + urlencode(query), {"api-token": token}, {})
        rows.extend(data["data"])
        cursor = data.get("pagination", {}).get("cursor")
        if not cursor:
            return rows
        if cursor in seen:
            raise ValueError("Codacy repeated its pagination cursor")
        seen.add(cursor)


def normalize(rows, source):
    result = []
    for row in rows:
        if source == "sonarcloud":
            path = row["component"].split(":", 1)[-1]
            rule, tool = row["rule"], "sonarcloud"
            line = row.get("line", row.get("textRange", {}).get("startLine", 0))
        else:
            path = row["filePath"]
            pattern = row.get("patternInfo", {})
            rule = pattern["id"]
            tool = pattern.get("toolId", pattern.get("tool", "codacy"))
            if isinstance(tool, dict):
                tool = tool.get("name", tool.get("id", "codacy"))
            line = row.get("lineNumber", row.get("line", 0))
        result.append(dict(file=exact(path), line=int(line or 0), source=source,
                           rule=str(rule), tool=str(tool), message=str(row.get("message", ""))))
    return result


def matches(area, finding):
    return (any(finding["file"].startswith(prefix) for prefix in area.get("prefixes", []))
            or finding["rule"] in area.get("rules", [])
            or finding["tool"] in area.get("tools", []))


def core_files(config, root):
    upstream = config.get("upstream", {})
    core = set(upstream.get("files", []))
    if upstream.get("files_file"):
        core.update(line.strip() for line in (root / exact(upstream["files_file"])).read_text().splitlines()
                    if line.strip() and not line.lstrip().startswith("#"))
    for path in core:
        exact(path)
    return core


def cell(value):
    # Escape HTML and markdown/control syntax from untrusted service messages.
    text = html.escape(str(value), quote=True)
    for before, after in (("|", "&#124;"), ("`", "&#96;"), ("{", "&#123;"),
                          ("}", "&#125;"), ("\n", " "), ("\r", " ")):
        text = text.replace(before, after)
    return text
