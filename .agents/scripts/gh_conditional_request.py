#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Request rules for conditional governed REST reads (GH#38566).

Decides which already-governed `gh api` GETs may revalidate their stored
stdout with If-None-Match, and extracts a response's single strong-or-weak
ETag. Storage and replay live in gh_conditional_cache.

Explicit pagination pages (GH#39233) add `--include` only so the page loop can
read `Link`; the loop marks them with PAGE_FRAME_ENV and their whole frame may
be stored. A 304 carries no `Link` and a list ETag tracks the page body, so an
unchanged *full* final page cannot reveal a newly appended page: only frames
that link onward, or final raw arrays with room left, may answer a 304.
"""

from __future__ import annotations

import json
import os
import re
from urllib.parse import parse_qs, urlsplit

from gh_native_response import _request_options

ETAG = re.compile(rb'(?:W/)?"[\x21\x23-\x7e]{1,200}"')
PAGE_FRAME_ENV = "AIDEVOPS_GH_PAGINATION_INCLUDE_OWNED"
# GitHub's documented REST list default and ceiling. A smaller endpoint ceiling
# (notifications: 50) would make a full page look short, so it never qualifies.
_DEFAULT_PER_PAGE = 30
_MAX_PER_PAGE = 100
_LINK_TARGET = re.compile(rb"<[^>]*>([^<]*)")
_NEXT_REL = re.compile(rb'\brel\s*=\s*"?next(?:"|\s|;|,|$)', re.IGNORECASE)
_FINAL_PAGE_FILTERS = {"-q", "--jq", "-t", "--template", "--field"}
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


def page_frame(include: bool) -> bool:
    """Return True when the explicit page loop, not the caller, asked for headers.

    Caller-requested headers stay ineligible: a replayed frame carries the
    stored response's rate-limit headers, which only the page loop ignores.
    """
    return include and os.environ.get(PAGE_FRAME_ENV) == "1"


def eligible(args: list[str], resource: str, include: bool, silent: bool) -> bool:
    """Return True only for request shapes whose stdout is a pure function of the response."""
    excluded = (
        os.environ.get("AIDEVOPS_GH_CONDITIONAL_CACHE_DISABLE") == "1",
        resource != "core",
        include and not page_frame(include),
        silent,
        args[:1] != ["api"],
    )
    if any(excluded):
        return False
    return not any(_replay_unsafe(option, value) for option, value in _inspected_options(args))


def _links_onward(header_frame: bytes) -> bool:
    for line in header_frame.splitlines():
        name, separator, value = line.partition(b":")
        if separator and name.strip().lower() == b"link":
            if any(_NEXT_REL.search(params) for params in _LINK_TARGET.findall(value)):
                return True
    return False


def _final_page_has_room(args: list[str], body: bytes) -> bool:
    """Return True for an unfiltered final raw array page shorter than its page size."""
    try:
        endpoint, options = _request_options(args[1:])
    except (ValueError, StopIteration):
        return False
    target = urlsplit(endpoint)
    sizes = parse_qs(target.query).get("per_page", [str(_DEFAULT_PER_PAGE)])
    if _FINAL_PAGE_FILTERS.intersection(options) or "notifications" in target.path.split("/"):
        return False
    if len(sizes) != 1 or not sizes[0].isdecimal() or int(sizes[0]) < 1:
        return False
    try:
        items = json.loads(body)
    except ValueError:
        return False
    return isinstance(items, list) and len(items) < min(int(sizes[0]), _MAX_PER_PAGE)


def page_frame_replayable(args: list[str], header_frame: bytes, body: bytes) -> bool:
    """Return True when a stored page frame stays exact for a later 304.

    A frame that links onward is exact: every later page is requested and
    validated on its own. A final page is exact only with room left, because
    anything appended would then change this page's body and ETag.
    """
    return _links_onward(header_frame) or _final_page_has_room(args, body)


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
