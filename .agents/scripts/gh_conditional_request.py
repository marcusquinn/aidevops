#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Request rules for conditional governed REST reads (GH#38566).

Decides which already-governed `gh api` GETs may revalidate their stored
stdout with If-None-Match, and extracts a response's single strong-or-weak
ETag. Storage and replay live in gh_conditional_cache.
"""

from __future__ import annotations

import os
import re

ETAG = re.compile(rb'(?:W/)?"[\x21\x23-\x7e]{1,200}"')
# Filters whose output depends on time, environment or extra input are not a
# pure function of the representation, so their stdout must not be replayed.
_IMPURE_JQ = re.compile(r"\bnow\b|\benv\b|\$ENV|\binputs?\b|\$__loc__|\bdebug\b|\bstderr\b|\binput_")
_CALLER_VALIDATORS = {"if-none-match", "if-modified-since", "if-match", "if-unmodified-since",
                      "if-range", "cache-control"}
_TEMPLATE_OPTIONS = {"-t", "--template"}
_HEADER_OPTIONS = {"-H", "--header"}
_JQ_OPTIONS = {"-q", "--jq"}
_INSPECTED_VALUE_OPTIONS = _HEADER_OPTIONS | _JQ_OPTIONS


def _option_value(args: list[str], index: int) -> tuple[str, str, int]:
    option, separator, value = args[index].partition("=")
    if separator:
        return option, value, index + 1
    return option, args[index + 1] if index + 1 < len(args) else "", index + 2


def _inspected_options(args: list[str]):
    """Yield (option, value) after `api`; only headers and jq filters carry a value."""
    index = 1
    while index < len(args):
        option = args[index].partition("=")[0]
        if option in _INSPECTED_VALUE_OPTIONS:
            option, value, index = _option_value(args, index)
        else:
            value, index = "", index + 1
        yield option, value


def _replay_unsafe(option: str, value: str) -> bool:
    if option in _TEMPLATE_OPTIONS:
        return True
    if option in _HEADER_OPTIONS:
        return value.split(":", 1)[0].strip().lower() in _CALLER_VALIDATORS
    return option in _JQ_OPTIONS and bool(_IMPURE_JQ.search(value))


def eligible(args: list[str], resource: str, include: bool, silent: bool) -> bool:
    """Return True only for request shapes whose stdout is a pure function of the response."""
    excluded = (
        os.environ.get("AIDEVOPS_GH_CONDITIONAL_CACHE_DISABLE") == "1",
        resource != "core",
        include,
        silent,
        args[:1] != ["api"],
    )
    if any(excluded):
        return False
    return not any(_replay_unsafe(option, value) for option, value in _inspected_options(args))


def response_etag(stream, body_offset: int) -> bytes | None:
    """Return the single ETag from an included-headers frame, else None."""
    if body_offset <= 0:
        return None
    stream.seek(0)
    frame = stream.read(body_offset)
    found = []
    for line in frame.splitlines():
        name, separator, value = line.partition(b":")
        if separator and name.strip().lower() == b"etag":
            found.append(value.strip())
    if len(found) != 1 or not ETAG.fullmatch(found[0]):
        return None
    return found[0]
