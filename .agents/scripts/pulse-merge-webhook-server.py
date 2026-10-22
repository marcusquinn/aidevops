#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Authenticated GitHub webhook receiver for pulse merge invalidation.

The HTTP boundary verifies the raw request body before parsing or persisting
request-derived data. Accepted deliveries are recorded in a private, bounded,
atomic ledger before versioned invalidation records and PROCESS_PR actions are
written to stdout for the Bash dispatcher.
"""

from __future__ import annotations

from contextlib import contextmanager
import fcntl
import hashlib
import hmac
import json
import os
import re
import socket
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Iterator

# Sibling module: importable when run as a script (sys.path[0]) or when this
# file is loaded by path from a test harness.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pulse_merge_webhook_payload import (  # noqa: E402
    _event_payload_is_valid,
    _invalidation_records,
    _process_pr_actions,
)


def _env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
    except ValueError:
        return default
    return min(maximum, max(minimum, value))


HOST = os.environ.get("WEBHOOK_LISTEN_HOST", "127.0.0.1")
PORT = _env_int("WEBHOOK_LISTEN_PORT", 9301, 1, 65535)
MAX_BODY = _env_int("WEBHOOK_MAX_BODY_BYTES", 1_048_576, 1, 10_485_760)
HANDLED = {
    event.strip()
    for event in os.environ.get(
        "WEBHOOK_HANDLED_EVENTS",
        "check_run,check_suite,status,workflow_run,issues,issue_comment,"
        "pull_request,pull_request_review,pull_request_review_comment,"
        "pull_request_review_thread",
    ).split(",")
    if event.strip()
}
SECRET = os.environ.get("_PULSE_WEBHOOK_SECRET", "").encode("utf-8")
LEDGER_TTL_SECONDS = _env_int("WEBHOOK_DELIVERY_TTL_SECONDS", 604_800, 60, 31_536_000)
LEDGER_MAX_ENTRIES = _env_int("WEBHOOK_DELIVERY_MAX_ENTRIES", 4096, 16, 100_000)
_DEFAULT_STATE_DIR = os.environ.get(
    "AIDEVOPS_STATE_DIR", str(Path.home() / ".aidevops" / "state")
)
LEDGER_FILE = Path(
    os.path.expanduser(
        os.environ.get(
            "WEBHOOK_DELIVERY_LEDGER_FILE",
            str(Path(_DEFAULT_STATE_DIR) / "pulse-merge-webhook-deliveries.json"),
        )
    )
)

_LEDGER_SCHEMA = "aidevops-webhook-deliveries/v1"
_LEDGER_STRING_FIELDS = ("id", "event", "payload_sha256", "outcome")
_ACTION_PROTOCOL = os.environ.get("WEBHOOK_ACTION_PROTOCOL_VERSION", "v1")
_DELIVERY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
_EVENT_RE = re.compile(r"^[a-z0-9_]{1,64}$")
_LEDGER_LOCK = threading.Lock()
_OUTPUT_LOCK = threading.Lock()


def _log(message: str) -> None:
    with _OUTPUT_LOCK:
        sys.stdout.write(f"# {message}\n")
        sys.stdout.flush()


def _ledger_entry_is_valid(entry: Any) -> bool:
    if not isinstance(entry, dict):
        return False
    if not isinstance(entry.get("received_at"), int):
        return False
    return all(isinstance(entry.get(field), str) for field in _LEDGER_STRING_FIELDS)


def _load_ledger() -> dict[str, Any]:
    if not LEDGER_FILE.exists():
        return {"schema": _LEDGER_SCHEMA, "deliveries": []}
    with LEDGER_FILE.open("r", encoding="utf-8") as ledger_handle:
        ledger = json.load(ledger_handle)
    if not isinstance(ledger, dict) or ledger.get("schema") != _LEDGER_SCHEMA:
        raise ValueError("unsupported delivery ledger schema")
    deliveries = ledger.get("deliveries")
    if not isinstance(deliveries, list):
        raise ValueError("invalid delivery ledger entries")
    for entry in deliveries:
        if not _ledger_entry_is_valid(entry):
            raise ValueError("invalid delivery ledger entry")
    return ledger


def _write_ledger(ledger: dict[str, Any]) -> None:
    parent = LEDGER_FILE.parent
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=".webhook-ledger.", dir=str(parent))
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as ledger_handle:
            json.dump(ledger, ledger_handle, separators=(",", ":"), sort_keys=True)
            ledger_handle.write("\n")
            ledger_handle.flush()
            os.fsync(ledger_handle.fileno())
        os.replace(temporary_path, LEDGER_FILE)
        try:
            parent_descriptor = os.open(parent, os.O_RDONLY)
            try:
                os.fsync(parent_descriptor)
            finally:
                os.close(parent_descriptor)
        except OSError:
            # The 0600 temp file is already atomically committed. Some network
            # filesystems reject directory fsync; do not turn that into a false
            # pre-action ledger failure after the durable replace succeeded.
            pass
    except Exception:
        temporary_path.unlink(missing_ok=True)
        raise


@contextmanager
def _ledger_process_lock() -> Iterator[None]:
    parent = LEDGER_FILE.parent
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_path = parent / f".{LEDGER_FILE.name}.lock"
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _record_delivery(
    delivery_id: str,
    event: str,
    payload_sha256: str,
    outcome: str,
) -> str:
    now = int(time.time())
    oldest = now - LEDGER_TTL_SECONDS
    with _LEDGER_LOCK:
        with _ledger_process_lock():
            ledger = _load_ledger()
            deliveries = [
                entry
                for entry in ledger["deliveries"]
                if oldest <= entry["received_at"] <= now + 300
            ]
            deliveries.sort(key=lambda entry: entry["received_at"], reverse=True)
            for entry in deliveries:
                if entry["id"] != delivery_id:
                    continue
                if entry["payload_sha256"] == payload_sha256 and entry["event"] == event:
                    return "duplicate"
                return "conflict"
            deliveries = deliveries[: max(0, LEDGER_MAX_ENTRIES - 1)]
            deliveries.insert(
                0,
                {
                    "event": event,
                    "id": delivery_id,
                    "outcome": outcome,
                    "payload_sha256": payload_sha256,
                    "received_at": now,
                },
            )
            ledger["deliveries"] = deliveries
            _write_ledger(ledger)
    return "accepted"


def _emit_records(
    invalidations: list[str], actions: list[tuple[str, int]], received_ms: int
) -> None:
    with _OUTPUT_LOCK:
        sys.stdout.write(f"DELIVERY {_ACTION_PROTOCOL} received-ms {received_ms}\n")
        for record in invalidations:
            sys.stdout.write(f"{record}\n")
        for slug, number in actions:
            sys.stdout.write(f"PROCESS_PR {slug} {number}\n")
        sys.stdout.flush()


def _signature_is_valid(body: bytes, signature: str) -> bool:
    if not signature.startswith("sha256="):
        return False
    expected = "sha256=" + hmac.new(SECRET, body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(signature, expected)


class WebhookHandler(BaseHTTPRequestHandler):
    """Verify one delivery and emit its narrow cache invalidations."""

    server_version = "aidevops-webhook"
    sys_version = ""

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def _send(self, status: int, body: bytes = b"") -> None:
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
        if self.path == "/health":
            self._send(200, b"ok\n")
            return
        self._send(404)

    def _read_request_body(self) -> bytes | None:
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send(400)
            return None
        if content_length <= 0:
            self._send(413)
            return None
        if content_length > MAX_BODY:
            self._send(413)
            return None
        body = self.rfile.read(content_length)
        if len(body) != content_length:
            self._send(400)
            return None
        return body

    def _authenticated_identity(self, body: bytes) -> tuple[str, str] | None:
        signature = self.headers.get("X-Hub-Signature-256", "")
        if not _signature_is_valid(body, signature):
            self._send(401)
            return None
        delivery_id = self.headers.get("X-GitHub-Delivery", "")
        if not _DELIVERY_RE.fullmatch(delivery_id):
            self._send(400)
            return None
        event = self.headers.get("X-GitHub-Event", "")
        if not _EVENT_RE.fullmatch(event):
            self._send(400)
            return None
        return delivery_id, event

    def _validated_payload(self, event: str, body: bytes) -> dict[str, Any] | None:
        if event not in HANDLED:
            self._send(204)
            return None
        try:
            payload = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._send(400)
            return None
        if not isinstance(payload, dict):
            self._send(400)
            return None
        if not _event_payload_is_valid(event, payload):
            self._send(400)
            return None
        return payload

    def _respond_to_replay(self, decision: str, event: str, delivery_id: str) -> bool:
        if decision == "conflict":
            _log(f"rejected delivery-id conflict event={event} delivery={delivery_id}")
            self._send(409)
            return True
        if decision == "duplicate":
            _log(f"duplicate event={event} delivery={delivery_id}")
            self._send(200, b"duplicate\n")
            return True
        return False

    def _accept_delivery(
        self, body: bytes, delivery_id: str, event: str, payload: dict[str, Any]
    ) -> None:
        received_ms = time.time_ns() // 1_000_000
        invalidations = _invalidation_records(event, payload, _ACTION_PROTOCOL)
        actions = _process_pr_actions(event, payload)
        fingerprint = hashlib.sha256(body).hexdigest()
        outcome = "accepted" if invalidations or actions else "authenticated-noop"
        # Durable ownership intentionally precedes the one-way shell protocol.
        # This keeps side effects at-most-once. If local invalidation later
        # fails, the receiver suppresses process_pr and periodic polling/TTL
        # supplies the documented recovery path rather than webhook replay.
        try:
            decision = _record_delivery(delivery_id, event, fingerprint, outcome)
        except (OSError, ValueError, json.JSONDecodeError):
            self._send(500)
            return
        if self._respond_to_replay(decision, event, delivery_id):
            return
        _emit_records(invalidations, actions, received_ms)
        _log(
            f"accepted event={event} delivery={delivery_id} "
            f"invalidations={len(invalidations)} actions={len(actions)}"
        )
        self._send(200, b"accepted\n")

    def do_POST(self) -> None:  # noqa: N802 - stdlib handler API
        if self.path != "/webhook":
            self._send(404)
            return
        body = self._read_request_body()
        if body is None:
            return
        identity = self._authenticated_identity(body)
        if identity is None:
            return
        delivery_id, event = identity
        payload = self._validated_payload(event, body)
        if payload is None:
            return
        self._accept_delivery(body, delivery_id, event, payload)


class WebhookServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class IPv6WebhookServer(WebhookServer):
    address_family = socket.AF_INET6


def main() -> int:
    if not SECRET:
        print("webhook-server: secret not set", file=sys.stderr)
        return 1
    if HOST not in {"127.0.0.1", "::1"}:
        print("webhook-server: refusing non-loopback listen host", file=sys.stderr)
        return 1
    if _ACTION_PROTOCOL != "v1":
        print("webhook-server: unsupported action protocol", file=sys.stderr)
        return 1
    server_class = IPv6WebhookServer if HOST == "::1" else WebhookServer
    server = server_class((HOST, PORT), WebhookHandler)
    _log(f"webhook receiver listening on {HOST}:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
