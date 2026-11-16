#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Conditional GETs for governed native REST reads (GH#38566).

An eligible `gh api` GET keeps its ETag and exact stdout, keyed by the
credential digest and the full argv. Repeats send If-None-Match. GitHub
validates every replay: only an authorized 304 for the same credential and
request replays the stored stdout, so a hit is equivalent to a live read and
costs no primary quota. Storing post-`--jq` stdout keeps gh's own filter
semantics. Bodies, endpoints and credentials are never logged.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import tempfile
import time
from pathlib import Path

MAX_BODY_BYTES = 1_048_576
# Pulse rereads the same objects within minutes, so six idle hours keeps nearly
# every useful validator while bounding disk use; a miss is one ordinary 200.
MAX_AGE_SECONDS = 21_600
PRUNE_ONE_IN = 256
_ETAG = re.compile(rb'(?:W/)?"[\x21\x23-\x7e]{1,200}"')
# Filters whose output depends on time, environment or extra input are not a
# pure function of the representation, so their stdout must not be replayed.
_IMPURE_JQ = re.compile(r"\bnow\b|\benv\b|\$ENV|\binputs?\b|\$__loc__|\bdebug\b|\bstderr\b|\binput_")
_CALLER_VALIDATORS = {"if-none-match", "if-modified-since", "if-match", "if-unmodified-since",
                      "if-range", "cache-control"}


def _option_value(args: list[str], index: int) -> tuple[str, str, int]:
    option, separator, value = args[index].partition("=")
    if separator:
        return option, value, index + 1
    return option, args[index + 1] if index + 1 < len(args) else "", index + 2


def eligible(args: list[str], resource: str, include: bool, silent: bool) -> bool:
    """Return True only for request shapes whose stdout is a pure function of the response."""
    if os.environ.get("AIDEVOPS_GH_CONDITIONAL_CACHE_DISABLE") == "1":
        return False
    if resource != "core" or include or silent or args[:1] != ["api"]:
        return False
    index = 1
    while index < len(args):
        arg = args[index]
        option = arg.partition("=")[0]
        if option in {"-t", "--template"}:
            return False
        if option in {"-H", "--header"}:
            option, value, index = _option_value(args, index)
            if value.split(":", 1)[0].strip().lower() in _CALLER_VALIDATORS:
                return False
            continue
        if option in {"-q", "--jq"}:
            option, value, index = _option_value(args, index)
            if _IMPURE_JQ.search(value):
                return False
            continue
        index += 1
    return True


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
    if len(found) != 1 or not _ETAG.fullmatch(found[0]):
        return None
    return found[0]


class ConditionalEntry:
    """One credential-and-argv keyed entry in a private state directory."""

    def __init__(self, directory: Path, credential: str, args: list[str]):
        digest = hashlib.sha256(
            credential.encode() + b"\x1f" + json.dumps(args, separators=(",", ":")).encode()
        ).hexdigest()
        self.directory = directory
        self.path = directory / digest
        self.etag: bytes | None = None
        self._body = b""
        self._load()

    def _load(self) -> None:
        try:
            if self.path.is_symlink():
                self.drop()
                return
            with open(self.path, "rb") as handle:
                first = handle.readline(256).rstrip(b"\n")
                body = handle.read(MAX_BODY_BYTES + 1)
        except OSError:
            return
        if not _ETAG.fullmatch(first) or len(body) > MAX_BODY_BYTES:
            self.drop()
            return
        self.etag, self._body = first, body

    def validator_args(self) -> list[str]:
        return ["-H", "If-None-Match: " + self.etag.decode("ascii")] if self.etag else []

    def replay(self, sink) -> None:
        sink.write(self._body)
        sink.flush()
        try:
            os.utime(self.path)
        except OSError:
            pass

    def store(self, etag: bytes, stream, body_offset: int) -> None:
        stream.seek(0, os.SEEK_END)
        if stream.tell() - body_offset > MAX_BODY_BYTES:
            self.drop()
            return
        stream.seek(body_offset)
        body = stream.read()
        fd, temp = tempfile.mkstemp(dir=self.directory, prefix=".entry-")
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(etag + b"\n" + body)
            os.chmod(temp, 0o600)
            os.replace(temp, self.path)
        except OSError:
            try:
                os.unlink(temp)
            except OSError:
                pass
            return
        if secrets.randbelow(PRUNE_ONE_IN) == 0:
            prune(self.directory)

    def drop(self) -> None:
        try:
            self.path.unlink()
        except OSError:
            pass

    def observe(self, status: int, rc: int, stream, body_offset: int) -> None:
        """Record a fresh 200, forget a gone resource, keep everything else."""
        if status == 200 and rc == 0:
            etag = response_etag(stream, body_offset)
            if etag:
                self.store(etag, stream, body_offset)
            else:
                self.drop()
        elif status in {404, 410}:
            self.drop()


def prune(directory: Path, *, now: float | None = None) -> int:
    """Delete entries unused for MAX_AGE_SECONDS; return the number removed."""
    cutoff = (time.time() if now is None else now) - MAX_AGE_SECONDS
    removed = 0
    try:
        candidates = list(directory.iterdir())
    except OSError:
        return 0
    for path in candidates:
        try:
            if path.is_symlink() or path.lstat().st_mtime < cutoff:
                path.unlink()
                removed += 1
        except OSError:
            continue
    return removed
