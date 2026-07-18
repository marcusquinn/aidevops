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
_SLUG_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_SHA_RE = re.compile(r"^[A-Fa-f0-9]{40}$")
_ALLOWED_LABELS = {"auto-dispatch", "coderabbit-nits-ok", "ai-approved"}
_EVENT_ACTIONS = {
    "check_run": {"completed", "created", "requested_action", "rerequested"},
    "check_suite": {"completed", "requested", "rerequested"},
    "issue_comment": {"created", "deleted", "edited"},
    "issues": {
        "assigned",
        "closed",
        "deleted",
        "demilestoned",
        "edited",
        "labeled",
        "locked",
        "milestoned",
        "opened",
        "pinned",
        "reopened",
        "transferred",
        "typed",
        "unassigned",
        "unlabeled",
        "unlocked",
        "unpinned",
        "untyped",
    },
    "pull_request": {
        "assigned",
        "auto_merge_disabled",
        "auto_merge_enabled",
        "closed",
        "converted_to_draft",
        "dequeued",
        "demilestoned",
        "edited",
        "enqueued",
        "labeled",
        "locked",
        "milestoned",
        "opened",
        "ready_for_review",
        "reopened",
        "review_request_removed",
        "review_requested",
        "synchronize",
        "unassigned",
        "unlabeled",
        "unlocked",
    },
    "pull_request_review": {"dismissed", "edited", "submitted"},
    "pull_request_review_comment": {"created", "deleted", "edited"},
    "pull_request_review_thread": {"resolved", "unresolved"},
    "workflow_run": {"completed", "in_progress", "requested"},
}
_STATUS_STATES = {"error", "failure", "pending", "success"}
_LEDGER_LOCK = threading.Lock()
_OUTPUT_LOCK = threading.Lock()


def _log(message: str) -> None:
    with _OUTPUT_LOCK:
        sys.stdout.write(f"# {message}\n")
        sys.stdout.flush()


def _repository_slug(payload: dict[str, Any]) -> str | None:
    repository = payload.get("repository")
    if not isinstance(repository, dict):
        return None
    slug = repository.get("full_name")
    if not isinstance(slug, str) or not _SLUG_RE.fullmatch(slug):
        return None
    owner, name = slug.split("/", 1)
    if not owner[0].isalnum() or owner in {".", ".."} or name in {".", ".."}:
        return None
    return slug


def _pull_number(value: Any) -> int | None:
    if not isinstance(value, dict):
        return None
    number = value.get("number")
    if isinstance(number, int) and number > 0:
        return number
    return None


def _attached_pull_numbers(payload: dict[str, Any], key: str) -> list[int]:
    container = payload.get(key)
    if not isinstance(container, dict):
        return []
    pulls = container.get("pull_requests")
    if not isinstance(pulls, list):
        return []
    numbers = {_pull_number(pull) for pull in pulls}
    return sorted(number for number in numbers if number is not None)


def _attached_pulls_are_valid(payload: dict[str, Any], key: str) -> bool:
    container = payload.get(key)
    if not isinstance(container, dict):
        return False
    pulls = container.get("pull_requests", [])
    return isinstance(pulls, list) and all(_pull_number(pull) is not None for pull in pulls)


def _label_payload_is_valid(payload: dict[str, Any]) -> bool:
    label = payload.get("label")
    if not isinstance(label, dict):
        return False
    return isinstance(label.get("name"), str)


def _issue_event_payload_is_valid(event: str, payload: dict[str, Any]) -> bool:
    if _pull_number(payload.get("issue")) is None:
        return False
    if event != "issues":
        return True
    if payload.get("action") not in {"labeled", "unlabeled"}:
        return True
    return _label_payload_is_valid(payload)


def _review_payload_is_valid(payload: dict[str, Any]) -> bool:
    review = payload.get("review")
    if not isinstance(review, dict):
        return False
    if payload.get("action") != "submitted":
        return True
    return str(review.get("state", "")).lower() in {
        "approved",
        "changes_requested",
        "commented",
        "dismissed",
        "pending",
    }


def _pull_event_payload_is_valid(event: str, payload: dict[str, Any]) -> bool:
    if _pull_number(payload.get("pull_request")) is None:
        return False
    if event == "pull_request_review":
        return _review_payload_is_valid(payload)
    if event != "pull_request":
        return True
    if payload.get("action") not in {"labeled", "unlabeled"}:
        return True
    return _label_payload_is_valid(payload)


def _check_event_payload_is_valid(event: str, payload: dict[str, Any]) -> bool:
    if _check_sha(event, payload) is None:
        return False
    return _attached_pulls_are_valid(payload, event)


def _status_event_payload_is_valid(_event: str, payload: dict[str, Any]) -> bool:
    if payload.get("state") not in _STATUS_STATES:
        return False
    return _check_sha("status", payload) is not None


def _workflow_event_payload_is_valid(event: str, payload: dict[str, Any]) -> bool:
    return _check_sha(event, payload) is not None


_EVENT_PAYLOAD_VALIDATORS = {
    "check_run": _check_event_payload_is_valid,
    "check_suite": _check_event_payload_is_valid,
    "issue_comment": _issue_event_payload_is_valid,
    "issues": _issue_event_payload_is_valid,
    "pull_request": _pull_event_payload_is_valid,
    "pull_request_review": _pull_event_payload_is_valid,
    "pull_request_review_comment": _pull_event_payload_is_valid,
    "pull_request_review_thread": _pull_event_payload_is_valid,
    "status": _status_event_payload_is_valid,
    "workflow_run": _workflow_event_payload_is_valid,
}


def _event_payload_is_valid(event: str, payload: dict[str, Any]) -> bool:
    if _repository_slug(payload) is None:
        return False
    if event != "status" and payload.get("action") not in _EVENT_ACTIONS.get(event, set()):
        return False
    validator = _EVENT_PAYLOAD_VALIDATORS.get(event)
    if validator is None:
        return False
    return validator(event, payload)


def _successful_check_pull_numbers(event: str, payload: dict[str, Any]) -> list[int]:
    if payload.get("action") != "completed":
        return []
    check = payload.get(event)
    if not isinstance(check, dict):
        return []
    if check.get("conclusion") != "success":
        return []
    return _attached_pull_numbers(payload, event)


def _review_process_pull_numbers(_event: str, payload: dict[str, Any]) -> list[int]:
    if payload.get("action") != "submitted":
        return []
    review = payload.get("review")
    if not isinstance(review, dict):
        return []
    if str(review.get("state", "")).lower() not in {"approved", "changes_requested"}:
        return []
    number = _pull_number(payload.get("pull_request"))
    if number is None:
        return []
    return [number]


def _label_process_pull_numbers(_event: str, payload: dict[str, Any]) -> list[int]:
    if payload.get("action") != "labeled":
        return []
    label = payload.get("label")
    if not isinstance(label, dict) or label.get("name") not in _ALLOWED_LABELS:
        return []
    number = _pull_number(payload.get("pull_request"))
    if number is None:
        return []
    return [number]


_PROCESS_PR_RESOLVERS = {
    "check_run": _successful_check_pull_numbers,
    "check_suite": _successful_check_pull_numbers,
    "pull_request": _label_process_pull_numbers,
    "pull_request_review": _review_process_pull_numbers,
}


def _process_pr_actions(event: str, payload: dict[str, Any]) -> list[tuple[str, int]]:
    slug = _repository_slug(payload)
    if slug is None:
        return []
    resolver = _PROCESS_PR_RESOLVERS.get(event)
    if resolver is None:
        return []
    numbers = resolver(event, payload)
    return [(slug, number) for number in numbers]


def _check_sha(event: str, payload: dict[str, Any]) -> str | None:
    sha: Any = None
    if event == "check_suite":
        suite = payload.get("check_suite")
        sha = suite.get("head_sha") if isinstance(suite, dict) else None
    elif event == "check_run":
        check_run = payload.get("check_run")
        if isinstance(check_run, dict):
            sha = check_run.get("head_sha")
            if sha is None and isinstance(check_run.get("check_suite"), dict):
                sha = check_run["check_suite"].get("head_sha")
    elif event == "status":
        sha = payload.get("sha")
    elif event == "workflow_run":
        workflow_run = payload.get("workflow_run")
        sha = workflow_run.get("head_sha") if isinstance(workflow_run, dict) else None
    if not isinstance(sha, str) or not _SHA_RE.fullmatch(sha):
        return None
    return sha.lower()


def _invalidation_records(event: str, payload: dict[str, Any]) -> list[str]:
    slug = _repository_slug(payload)
    if slug is None:
        return []
    records: list[str] = []
    if event == "issues":
        records.append(f"INVALIDATE {_ACTION_PROTOCOL} collection issues {slug}")
    elif event == "issue_comment":
        issue = payload.get("issue")
        kind = "prs" if isinstance(issue, dict) and "pull_request" in issue else "issues"
        records.append(f"INVALIDATE {_ACTION_PROTOCOL} collection {kind} {slug}")
    elif event in {
        "pull_request",
        "pull_request_review",
        "pull_request_review_comment",
        "pull_request_review_thread",
    }:
        records.append(f"INVALIDATE {_ACTION_PROTOCOL} collection prs {slug}")
    elif event in {"check_run", "check_suite", "status", "workflow_run"}:
        sha = _check_sha(event, payload)
        if sha is not None:
            records.append(f"INVALIDATE {_ACTION_PROTOCOL} checks {slug} {sha}")
    return records


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


def _emit_records(invalidations: list[str], actions: list[tuple[str, int]]) -> None:
    with _OUTPUT_LOCK:
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
        invalidations = _invalidation_records(event, payload)
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
        _emit_records(invalidations, actions)
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
