#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Recognize supported native REST requests and parse numeric response evidence.

This module performs no transport, admission, credential resolution or state writes.
"""

from __future__ import annotations

import os
import re
import shutil
import sys


VALUE_FLAGS = {
    "-X", "--method", "-H", "--header", "--hostname", "-F", "--field",
    "-f", "--raw-field", "--input", "-q", "--jq", "-p", "--preview",
    "-t", "--template",
}
BOOL_FLAGS = {"--include", "-i", "--silent"}


def _value_option(option: str, value: str) -> tuple[str, str]:
    # Streamed input and inherited descriptors must retain native execution.
    if option == "--input" or any(part in value for part in ("/dev/fd/", "/proc/self/fd/")):
        raise ValueError("unsupported input")
    # Caller-supplied authorization is a different identity; caching is opaque.
    if option in {"-H", "--header"}:
        if value.split(":", 1)[0].strip().lower() in {"authorization", "x-gh-cache-ttl"}:
            raise ValueError("unsupported header")
    aliases = {"-X": "--method", "-F": "--field", "-f": "--field", "--raw-field": "--field"}
    return aliases.get(option, option), value


def _request_options(args: list[str]) -> tuple[str, dict[str, str]]:
    endpoint = ""
    options: dict[str, str] = {}
    remaining = iter(args)
    for arg in remaining:
        option, separator, value = arg.partition("=")
        if option in VALUE_FLAGS:
            if not separator:
                value = next(remaining)
            option, value = _value_option(option, value)
            options[option] = value
        elif arg in BOOL_FLAGS:
            options[arg] = ""
        elif endpoint or arg.startswith(("-", "//")):
            # Unknown options and multiple endpoints retain native transport.
            raise ValueError("unsupported argument")
        else:
            endpoint = arg.lstrip("/")
    return endpoint, options


def _request_resource(host: str, endpoint: str, options: dict[str, str]) -> str:
    path = endpoint.split("?", 1)[0]
    unsupported = (
        host != "github.com", not path, ":" in path, "#" in endpoint,
        options.get("--method", "GET").upper() != "GET",
        {"--field", "--method"}.intersection(options) == {"--field"},
        path in {"graphql", "rate_limit"},
    )
    if any(unsupported):
        raise ValueError("unsupported request")
    if path == "search/code":
        return "code_search"
    return "search" if path.startswith("search/") else "core"


def request_shape(args: list[str]) -> tuple[str, str, bool, bool] | None:
    if args[:1] != ["api"] or os.environ.get("GH_DEBUG"):
        return None
    try:
        endpoint, options = _request_options(args[1:])
        host = options.get("--hostname", os.environ.get("GH_HOST", "github.com")).lower()
        resource = _request_resource(host, endpoint, options)
        include = not {"--include", "-i"}.isdisjoint(options)
        return host, resource, include, "--silent" in options
    except (ValueError, StopIteration):
        return None


def included_headers(stream) -> tuple[int, dict[str, str], int]:
    stream.seek(0)
    first = stream.readline(8192)
    match = re.fullmatch(rb"HTTP/[0-9.]+ ([0-9]{3})[^\r\n]*\r?\n", first)
    if not match:
        stream.seek(0)
        return 0, {}, 0
    headers: dict[str, str] = {}
    while stream.tell() < 65536:
        line = stream.readline(8192)
        if line in {b"\n", b"\r\n"}:
            return int(match[1]), headers, stream.tell()
        if not line or b":" not in line:
            break
        name, value = line.decode("ascii", errors="replace").split(":", 1)
        name = name.lower()
        if name in {"x-ratelimit-limit", "x-ratelimit-remaining", "x-ratelimit-used",
                    "x-ratelimit-reset", "x-ratelimit-resource", "retry-after"}:
            # Duplicate rate headers are ambiguous, not additional authority.
            if name in headers:
                return 0, {}, 0
            headers[name] = value.strip()
    return 0, {}, 0


def _response_metadata(status: int, headers: dict[str, str], authenticated: bool) -> dict:
    # Persist numeric metadata only, never endpoint, query, body or auth.
    resource = headers.get("x-ratelimit-resource", "")
    known_resource = resource in {"core", "search", "code_search"}
    cost = None
    if known_resource and 200 <= status < 400:
        cost = 1
        if status == 304:
            cost = 0 if authenticated else None
    result = {
        "attempted": True, "status": status or None,
        "resource": resource if known_resource else None, "cost": cost,
    }
    for name, header in (("remaining", "x-ratelimit-remaining"),
                         ("reset", "x-ratelimit-reset"), ("retry_after", "retry-after")):
        value = headers.get(header, "")
        result[name] = int(value) if value.isdecimal() else None
    return result


def _copy_response(output, include: bool, silent: bool, status: int, body_offset: int) -> int:
    if include:
        output.seek(0)
        shutil.copyfileobj(output, sys.stdout.buffer)
    elif not status:
        # Unknown framing must not leak injected headers or report success.
        print("[gh-transport] unrecognized native response framing", file=sys.stderr)
        return 1
    elif not silent:
        output.seek(body_offset)
        shutil.copyfileobj(output, sys.stdout.buffer)
    return 0
