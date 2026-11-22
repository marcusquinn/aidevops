#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Conditional GETs for governed native REST reads (GH#38566).

An eligible `gh api` GET keeps its ETag and exact stdout, keyed by the
credential digest and the full argv. Repeats send If-None-Match. GitHub
validates every replay: only an authorized 304 for the same credential and
request replays the stored stdout, so a hit is equivalent to a live read and
costs no primary quota. Storing post-`--jq` stdout keeps gh's own filter
semantics. Bodies, endpoints and credentials are never logged. Eligibility
rules live in gh_conditional_request.

An explicit pagination page (GH#39233) stores its whole included frame, so a
replay hands the page loop the original `Link` header; it is stored only when
gh_conditional_request.page_frame_replayable proves that replay stays exact.
"""

from __future__ import annotations

import contextlib
import hashlib
import json
import os
import secrets
import sys
import tempfile
import time
from pathlib import Path

from gh_conditional_request import ETAG, eligible, page_frame, page_frame_replayable, response_etag
from gh_native_response import _copy_response
from gh_transport_budget import private_directory

MAX_BODY_BYTES = 1_048_576
# Pulse rereads the same objects within minutes, so six idle hours keeps nearly
# every useful validator while bounding disk use; a miss is one ordinary 200.
MAX_AGE_SECONDS = 21_600
PRUNE_ONE_IN = 256


class Unconditional:
    """An ordinary request: no validator, native stderr, no stored stdout."""

    etag: bytes | None = None

    def validator_args(self) -> list[str]:
        return []

    def stderr_buffer(self, _temp_dir: Path):
        return contextlib.nullcontext()

    def deliver(self, output, _errors, framing, rc: int) -> int:
        """Copy the native response to the caller; framing is (include, silent, status, body_offset)."""
        return rc or _copy_response(output, *framing)


class ConditionalEntry(Unconditional):
    """One credential-and-argv keyed entry in a private state directory."""

    def __init__(self, directory: Path, credential: str, args: list[str], frame: bool = False):
        digest = hashlib.sha256(
            credential.encode() + b"\x1f" + json.dumps(args, separators=(",", ":")).encode()
        ).hexdigest()
        self.directory = directory
        self.path = directory / digest
        self.args = args
        # A page frame keeps its headers; argv (with --include) keys it apart.
        self.frame = frame
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
        if not ETAG.fullmatch(first) or len(body) > MAX_BODY_BYTES:
            self.drop()
            return
        self.etag, self._body = first, body

    def validator_args(self) -> list[str]:
        return ["-H", "If-None-Match: " + self.etag.decode("ascii")] if self.etag else []

    def stderr_buffer(self, temp_dir: Path):
        # Native gh reports a validated 304 as an error; hold stderr until the
        # status shows whether the caller should see it.
        return tempfile.TemporaryFile(dir=temp_dir)

    def deliver(self, output, errors, framing, rc: int) -> int:
        """Replay stored stdout on a validated 304; otherwise behave natively and record."""
        status, body_offset = framing[2], framing[3]
        if self.etag and status == 304:
            # GitHub confirmed the representation for this credential and
            # request is unchanged, so the caller gets the resource it asked for.
            self.replay(sys.stdout.buffer)
            return 0
        errors.seek(0)
        sys.stderr.buffer.write(errors.read())
        sys.stderr.buffer.flush()
        rc = super().deliver(output, errors, framing, rc)
        self.observe(status, rc, output, body_offset)
        return rc

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
            with contextlib.suppress(OSError):
                os.unlink(temp)
            return
        if secrets.randbelow(PRUNE_ONE_IN) == 0:
            prune(self.directory)

    def drop(self) -> None:
        with contextlib.suppress(OSError):
            self.path.unlink()

    def _frame_replayable(self, stream, body_offset: int) -> bool:
        stream.seek(0)
        header_frame = stream.read(body_offset)
        body = stream.read(MAX_BODY_BYTES + 1)
        return len(body) <= MAX_BODY_BYTES and page_frame_replayable(self.args, header_frame, body)

    def observe(self, status: int, rc: int, stream, body_offset: int) -> None:
        """Record a fresh 200, forget a gone resource, keep everything else."""
        if status == 200 and rc == 0:
            etag = response_etag(stream, body_offset)
            if etag and self.frame and not self._frame_replayable(stream, body_offset):
                etag = None
            if etag:
                self.store(etag, stream, 0 if self.frame else body_offset)
            else:
                self.drop()
        elif status in {404, 410}:
            self.drop()


def open_entry(state_directory: Path, credential: str, args: list[str], shape) -> Unconditional:
    """Return the credential-and-argv entry for an eligible GET, else an ordinary request."""
    _host, resource, include, silent = shape
    if not eligible(args, resource, include, silent):
        return Unconditional()
    try:
        cache_dir = state_directory / "conditional"
        private_directory(cache_dir)
        return ConditionalEntry(cache_dir, credential, args, frame=page_frame(include))
    except (OSError, ValueError):
        # Unusable cache state keeps the ordinary unconditional request.
        return Unconditional()


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
