#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Embedded HTTP server for pulse-merge-webhook-receiver.sh (t3038).

Reads webhook deliveries on the loopback address, validates the GitHub
HMAC SHA-256 signature, decodes the JSON payload, and prints one
``PROCESS_PR <slug> <pr_number>`` line per affected PR on stdout. The
parent shell script reads stdout and dispatches to ``process_pr``.

Lines starting with ``# `` are diagnostic logs the parent forwards to
``WEBHOOK_LOG_FILE``.

This file is split out of the receiver to keep the shell wrapper small
enough for the function-complexity gate (<= 100 lines per function).
"""

import hashlib
import hmac
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LISTEN_HOST = os.environ.get("WEBHOOK_LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("WEBHOOK_LISTEN_PORT", "9301"))
HANDLED_EVENTS = {
    e.strip()
    for e in os.environ.get(
        "WEBHOOK_HANDLED_EVENTS",
        "check_suite,pull_request_review,pull_request",
    ).split(",")
    if e.strip()
}
MAX_BODY_BYTES = int(os.environ.get("WEBHOOK_MAX_BODY_BYTES", "1048576"))
SECRET = os.environ.get("_PULSE_WEBHOOK_SECRET", "").encode("utf-8")

LABEL_TRIGGERS = {"auto-dispatch", "coderabbit-nits-ok", "ai-approved"}

# Payload key constants (deduplicated to satisfy aidevops string-literal ratchet).
KEY_ACTION = "action"
KEY_NUMBER = "number"
KEY_PR = "pull_request"
KEY_REVIEW = "review"
KEY_REPO = "repository"
KEY_CHECK_SUITE = "check_suite"
KEY_LABEL = "label"
KEY_NAME = "name"


def _emit_log(msg):
    """Forward a diagnostic line to the parent shell log."""
    sys.stdout.write(f"# {msg}\n")
    sys.stdout.flush()


def _emit_action(slug, pr_number):
    """Print one ACTION line that the bash dispatcher reads."""
    sys.stdout.write(f"PROCESS_PR {slug} {pr_number}\n")
    sys.stdout.flush()


def _verify_signature(body_bytes, header_sig):
    if not SECRET:
        return False
    if not header_sig or not header_sig.startswith("sha256="):
        return False
    expected = "sha256=" + hmac.new(SECRET, body_bytes, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header_sig)


def _slug_from_payload(payload):
    repo = payload.get(KEY_REPO) or {}
    full = repo.get("full_name")
    if isinstance(full, str) and "/" in full:
        if re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", full):
            return full
    return None


def _pr_num(obj):
    num = obj.get(KEY_NUMBER) if isinstance(obj, dict) else None
    return num if isinstance(num, int) and num > 0 else None


def _prs_check_suite(payload, slug):
    if payload.get(KEY_ACTION) != "completed":
        return []
    cs = payload.get(KEY_CHECK_SUITE) or {}
    if cs.get("conclusion") != "success":
        return []
    out = []
    for pr in cs.get("pull_requests") or []:
        num = _pr_num(pr)
        if num:
            out.append((slug, num))
    return out


def _prs_review(payload, slug):
    if payload.get(KEY_ACTION) != "submitted":
        return []
    review = payload.get(KEY_REVIEW) or {}
    state = (review.get("state") or "").lower()
    if state not in ("approved", "changes_requested"):
        return []
    num = _pr_num(payload.get(KEY_PR))
    return [(slug, num)] if num else []


def _prs_pr_labeled(payload, slug):
    if payload.get(KEY_ACTION) != "labeled":
        return []
    label = (payload.get(KEY_LABEL) or {}).get(KEY_NAME) or ""
    if label not in LABEL_TRIGGERS:
        return []
    num = _pr_num(payload.get(KEY_PR))
    return [(slug, num)] if num else []


def _prs_from_event(event, payload):
    """Return list of (slug, pr_number) tuples to dispatch."""
    slug = _slug_from_payload(payload)
    if not slug:
        return []
    if event == KEY_CHECK_SUITE:
        return _prs_check_suite(payload, slug)
    if event == "pull_request_review":
        return _prs_review(payload, slug)
    if event == KEY_PR:
        return _prs_pr_labeled(payload, slug)
    return []


class WebhookHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return  # silence default stderr access log

    def _reply(self, code, msg=b""):
        self.send_response(code)
        self.send_header("Content-Length", str(len(msg)))
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        if msg:
            self.wfile.write(msg)

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
        except (TypeError, ValueError):
            self._reply(400, b"bad content-length")
            return
        if length <= 0 or length > MAX_BODY_BYTES:
            self._reply(413, b"payload too large or empty")
            return

        body = self.rfile.read(length)
        sig = self.headers.get("X-Hub-Signature-256", "")
        event = self.headers.get("X-GitHub-Event", "")
        delivery = self.headers.get("X-GitHub-Delivery", "-")

        if not _verify_signature(body, sig):
            _emit_log(f"signature rejected (event={event}, delivery={delivery})")
            self._reply(401, b"bad signature")
            return

        if event not in HANDLED_EVENTS:
            self._reply(204, b"")
            return

        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            _emit_log(f"json decode failed: {exc!r}")
            self._reply(400, b"bad json")
            return

        actions = _prs_from_event(event, payload)
        if not actions:
            self._reply(204, b"")
            return

        for slug, num in actions:
            _emit_log(f"accepted {event} -> {slug}#{num} (delivery={delivery})")
            _emit_action(slug, num)
        self._reply(202, b"accepted")

    def do_GET(self):
        if self.path == "/health":
            self._reply(200, b"ok")
            return
        self._reply(404, b"not found")


def main():
    if not SECRET:
        _emit_log("FATAL: secret unavailable in child env")
        sys.exit(2)
    server = HTTPServer((LISTEN_HOST, LISTEN_PORT), WebhookHandler)
    _emit_log(f"listening on {LISTEN_HOST}:{LISTEN_PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        _emit_log("shutting down (SIGINT)")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
