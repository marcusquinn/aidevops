#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Observe one supported native REST request without GH_DEBUG or payload logs.

Return 125 with attempted=false for unsupported shapes; an executed native125
is distinguished by attempted=true. Never decide fallback from exit code alone.
Explicit pagination invokes this once per page.
No response is cached, and no automatic transport retry is performed.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from gh_transport_identity import resolve_owner_proof
from gh_transport_budget import Budget, Deferred, credential_identity, private_directory, quota_owner, scope_key


VALUE_FLAGS = {
    "-X", "--method", "-H", "--header", "--hostname", "-F", "--field",
    "-f", "--raw-field", "--input", "-q", "--jq", "-p", "--preview",
    "-t", "--template",
}
BOOL_FLAGS = {"--include", "-i", "--silent"}
INTERRUPTED_SIGNAL = 0


def interrupted(signum, _frame):
    # Never unwind Popen.wait while it owns its non-reentrant waitpid lock.
    global INTERRUPTED_SIGNAL
    INTERRUPTED_SIGNAL = signum


def check_interrupted():
    if INTERRUPTED_SIGNAL:
        raise SystemExit(128 + INTERRUPTED_SIGNAL)


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


def execute(executable: str, args: list[str], output, environment: dict[str, str]) -> int:
    check_interrupted()
    child = subprocess.Popen([executable, *args], stdout=output, env=environment)
    deadline = time.monotonic() + 90
    try:
        while True:
            check_interrupted()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(child.args, 90)
            try:
                return child.wait(timeout=min(0.2, remaining))
            except subprocess.TimeoutExpired:
                pass
    except subprocess.TimeoutExpired:
        print("[gh-transport] native REST request timed out", file=sys.stderr)
        return 124
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    # An uninterruptible child must not hold admission forever.
                    pass


class _AdmissionTimer:
    """Count only SQLite admission time; leave the budget decision untouched."""

    def __init__(self, budget: Budget):
        self.budget = budget
        self.sqlite_ms = 0.0

    def acquire(self, resource: str) -> str:
        started = time.monotonic()
        try:
            return self.budget.acquire(resource)
        finally:
            self.sqlite_ms += (time.monotonic() - started) * 1000


class _PhaseTimer:
    def __init__(self):
        self.enabled = os.environ.get("AIDEVOPS_GH_SHIM_TIMING") == "1"
        self.tick = time.monotonic() if self.enabled else 0.0

    def phase(self, name: str) -> None:
        if self.enabled:
            now = time.monotonic()
            print(f"[gh-shim-timing] phase={name} elapsed_ms={(now - self.tick) * 1000:.1f}",
                  file=sys.stderr)
            self.tick = now

    def admit(self, budget: Budget, resource: str) -> str:
        if not self.enabled:
            return _acquire(budget, resource)
        timed = _AdmissionTimer(budget)
        started = time.monotonic()
        try:
            return _acquire(timed, resource)
        finally:
            total_ms = (time.monotonic() - started) * 1000
            print(f"[gh-shim-timing] phase=sqlite_admission elapsed_ms={timed.sqlite_ms:.1f} "
                  f"pacing_ms={max(0.0, total_ms - timed.sqlite_ms):.1f}", file=sys.stderr)


def _acquire(budget: Budget, resource: str) -> str:
    # Admission waits are not failed HTTP attempts. Fit pacing inside the normal
    # read timeout while leaving five seconds for transport and response handling.
    timeout = os.environ.get("AIDEVOPS_GH_READ_TIMEOUT", "15")
    timeout = int(timeout) if timeout.isdecimal() else 15
    deadline = time.monotonic() + min(10, max(0, timeout - 5))
    while True:
        try:
            return budget.acquire(resource)
        except Deferred as pause:
            wait = max(0.1, pause.retry_at - time.time()) if pause.retry_at else 0.1
            if not pause.retryable or wait > deadline - time.monotonic():
                raise
            time.sleep(wait)


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


def _exit_status(rc: int) -> int:
    return rc if rc >= 0 else 128 - rc


def _finish_budget(budget, reservation: str, resource: str, headers: dict[str, str], started: float) -> None:
    if budget is None:
        return
    if reservation:
        try:
            budget.finish(reservation, resource, headers, started=started)
        except (OSError, ValueError, sqlite3.Error):
            print("[gh-transport] quota observation remains uncertain", file=sys.stderr)
    budget.close()


def run(metadata: Path, executable: str, args: list[str]) -> int:
    phase_timer = _PhaseTimer()
    phase = phase_timer.phase
    shape = request_shape(args)
    if shape is None or sys.stdout.isatty():
        return 125
    host, resource, include, silent = shape
    directory = Path(os.environ.get(
        "AIDEVOPS_GH_TRANSPORT_STATE_DIR",
        str(Path.home() / ".aidevops/state/gh-transport"),
    ))
    temp_dir = Path(os.environ.get(
        "AIDEVOPS_TEMP_DIR", str(Path.home() / ".aidevops/.agent-workspace/tmp")
    ))
    budget = None
    reservation = ""
    started = time.time()
    headers: dict[str, str] = {}
    rc = None
    try:
        metadata.write_text('{"attempted":false}', encoding="utf-8")
        private_directory(temp_dir)
        credential, authenticated, environment = credential_identity(executable, host)
        check_interrupted()
        phase("credential_identity")
        if not authenticated:
            # Do not mix anonymous-IP and authenticated-user allowances or
            # trust an identity which could change before native execution.
            return 125
        owner, attributed = quota_owner()
        if not attributed:
            # Digest-only login proof lets one user's PATs share recovery
            # without merging scopes across users or installations.
            private_directory(directory)
            resolve_owner_proof(executable, host, credential, environment, directory)
        budget = Budget(directory, scope_key(host, owner), credential, attributed=attributed)
        phase("sqlite_open")
        reservation = phase_timer.admit(budget, resource)
        phase("sqlite_admission_and_pacing")
        with tempfile.TemporaryFile(dir=temp_dir) as output:
            native_args = args if include else [*args, "--include"]
            metadata.write_text('{"attempted":true}', encoding="utf-8")
            rc = execute(executable, native_args, output, environment)
            phase("native_gh")
            status, headers, body_offset = included_headers(output)
            framing_rc = _copy_response(output, include, silent, status, body_offset)
            rc = rc or framing_rc
            result = _response_metadata(status, headers, authenticated)
            metadata.write_text(json.dumps(result), encoding="utf-8")
            phase("response_framing")
            return _exit_status(rc)
    except Deferred as exc:
        metadata.write_text(json.dumps({"attempted": False, "deferred_by": "local_admission",
                                       "reason": str(exc), "retry_at": exc.retry_at}), encoding="utf-8")
        retry = f" retry_at={exc.retry_at:.3f}" if exc.retry_at else ""
        print(f"[gh-transport] deferred: {exc}{retry}", file=sys.stderr)
        return 75
    except (OSError, ValueError, sqlite3.Error) as exc:
        # Metadata failure after execution is not permission to retry a
        # successful mutation. Keep the observed native status when available.
        sqlite_name = getattr(exc, "sqlite_errorname", "") or None
        failure = {"attempted": False, "deferred_by": "local_state", "reason": type(exc).__name__,
                   "sqlite_error": sqlite_name}
        if rc is None:
            try:
                metadata.write_text(json.dumps(failure), encoding="utf-8")
            except OSError:
                pass
        detail = f"/{sqlite_name}" if sqlite_name else ""
        print(f"[gh-transport] safe REST transport state unavailable: {type(exc).__name__}{detail}",
              file=sys.stderr)
        return _exit_status(rc) if rc is not None else 75
    finally:
        _finish_budget(budget, reservation, resource, headers, started)
        phase("sqlite_finish")


if __name__ == "__main__":
    if len(sys.argv) < 4:
        raise SystemExit(2)
    for handled_signal in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(handled_signal, interrupted)
    exit_code = run(Path(sys.argv[1]), sys.argv[2], sys.argv[3:])
    check_interrupted()
    raise SystemExit(exit_code)
