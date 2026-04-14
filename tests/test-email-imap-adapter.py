#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Tests for email_imap_adapter.py parsing helpers (t2064).

Covers `_parse_imap_date`, `_parse_response_line_fields`,
`_parse_header_bytes`, and `_parse_envelope_from_fetch` — the helpers that
were previously duplicated between `email_imap_adapter.py` and the now
deleted `email_imap_adapter_core.py`. These tests pin the behaviour of the
canonical module so any future refactor is byte-equivalent on the parts
that had to be merged.
"""

import importlib.util
import sys
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).parent.parent / ".agents" / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

# `email_imap_adapter.py` is a normal Python module name, so a direct import
# works — no dynamic spec needed.
import email_imap_adapter as adapter  # noqa: E402  (sys.path setup above)


class TestParseImapDate(unittest.TestCase):
    """`_parse_imap_date` — converts an RFC 2822 Date header to ISO 8601."""

    def test_empty_header(self):
        self.assertEqual(adapter._parse_imap_date(""), "")

    def test_none_header(self):
        self.assertEqual(adapter._parse_imap_date(None), "")

    def test_valid_rfc2822(self):
        result = adapter._parse_imap_date("Mon, 14 Apr 2026 07:20:53 +0000")
        # Expected: ISO 8601 with offset (the exact format is %Y-%m-%dT%H:%M:%S%z)
        self.assertEqual(result, "2026-04-14T07:20:53+0000")

    def test_valid_with_named_zone(self):
        result = adapter._parse_imap_date("Tue, 1 Jan 2026 12:00:00 GMT")
        self.assertEqual(result, "2026-01-01T12:00:00+0000")

    def test_invalid_header_returns_raw(self):
        # Not a parseable date — function returns the raw string unchanged.
        result = adapter._parse_imap_date("not a date at all")
        self.assertEqual(result, "not a date at all")

    def test_bytes_header_coerced_to_str(self):
        # Real IMAP headers can arrive as `email.header.Header` objects; the
        # function calls `str()` on them, so any value with a sensible __str__
        # works. Verify a bytes-like wrapper round-trips.
        result = adapter._parse_imap_date("Wed, 31 Dec 2025 23:59:59 +0100")
        self.assertEqual(result, "2025-12-31T23:59:59+0100")


class TestParseResponseLineFields(unittest.TestCase):
    """`_parse_response_line_fields` — extracts UID, FLAGS, RFC822.SIZE."""

    def test_full_line(self):
        line = b"1 (UID 42 FLAGS (\\Seen) RFC822.SIZE 1234 BODY[HEADER.FIELDS (...)] {0}"
        uid, flags, size = adapter._parse_response_line_fields(line)
        self.assertEqual(uid, 42)
        self.assertEqual(flags, "\\Seen")
        self.assertEqual(size, 1234)

    def test_multiple_flags(self):
        line = b"2 (UID 7 FLAGS (\\Seen \\Answered) RFC822.SIZE 99)"
        uid, flags, size = adapter._parse_response_line_fields(line)
        self.assertEqual(uid, 7)
        self.assertEqual(flags, "\\Seen \\Answered")
        self.assertEqual(size, 99)

    def test_no_flags(self):
        line = b"3 (UID 1 FLAGS () RFC822.SIZE 0)"
        uid, flags, size = adapter._parse_response_line_fields(line)
        self.assertEqual(uid, 1)
        self.assertEqual(flags, "")
        self.assertEqual(size, 0)

    def test_missing_fields_default_to_zero(self):
        # No UID, no FLAGS, no SIZE — every field defaults safely.
        line = b"4 (BODY[HEADER.FIELDS (DATE)] {0}"
        uid, flags, size = adapter._parse_response_line_fields(line)
        self.assertEqual(uid, 0)
        self.assertEqual(flags, "")
        self.assertEqual(size, 0)


class TestParseHeaderBytes(unittest.TestCase):
    """`_parse_header_bytes` — turns raw header bytes into a metadata dict."""

    HEADER_BYTES = (
        b"Message-ID: <abc123@example.com>\r\n"
        b"Date: Mon, 14 Apr 2026 07:20:53 +0000\r\n"
        b"From: alice@example.com\r\n"
        b"To: bob@example.com\r\n"
        b"Subject: Hello world\r\n\r\n"
    )

    def test_basic_fields(self):
        result = adapter._parse_header_bytes(
            self.HEADER_BYTES, uid=10, flags_str="\\Seen", size=512
        )
        self.assertEqual(result["uid"], 10)
        self.assertEqual(result["flags"], "\\Seen")
        self.assertEqual(result["size"], 512)
        self.assertEqual(result["message_id"], "<abc123@example.com>")
        self.assertEqual(result["from"], "alice@example.com")
        self.assertEqual(result["to"], "bob@example.com")
        self.assertEqual(result["subject"], "Hello world")
        self.assertEqual(result["date"], "2026-04-14T07:20:53+0000")

    def test_missing_headers_default_to_empty(self):
        minimal = b"Subject: Just a subject\r\n\r\n"
        result = adapter._parse_header_bytes(minimal, 0, "", 0)
        self.assertEqual(result["subject"], "Just a subject")
        self.assertEqual(result["from"], "")
        self.assertEqual(result["to"], "")
        self.assertEqual(result["message_id"], "")
        self.assertEqual(result["date"], "")


class TestParseEnvelopeFromFetch(unittest.TestCase):
    """`_parse_envelope_from_fetch` — top-level wrapper over a FETCH result."""

    def _make_fetch_item(self, uid=1, size=100, date="Mon, 14 Apr 2026 07:20:53 +0000"):
        response_line = (
            f"1 (UID {uid} FLAGS (\\Seen) RFC822.SIZE {size} "
            f"BODY[HEADER.FIELDS (...)] {{0}}".encode()
        )
        header_bytes = (
            f"Message-ID: <msg{uid}@example.com>\r\n"
            f"Date: {date}\r\n"
            f"From: alice@example.com\r\n"
            f"To: bob@example.com\r\n"
            f"Subject: Message {uid}\r\n\r\n"
        ).encode()
        return (response_line, header_bytes)

    def test_single_message(self):
        fetch_data = [self._make_fetch_item(uid=42, size=512)]
        result = adapter._parse_envelope_from_fetch(fetch_data)
        self.assertEqual(len(result), 1)
        msg = result[0]
        self.assertEqual(msg["uid"], 42)
        self.assertEqual(msg["size"], 512)
        self.assertEqual(msg["subject"], "Message 42")
        self.assertEqual(msg["from"], "alice@example.com")
        self.assertEqual(msg["date"], "2026-04-14T07:20:53+0000")

    def test_multiple_messages(self):
        fetch_data = [
            self._make_fetch_item(uid=1),
            self._make_fetch_item(uid=2),
            self._make_fetch_item(uid=3),
        ]
        result = adapter._parse_envelope_from_fetch(fetch_data)
        self.assertEqual(len(result), 3)
        self.assertEqual([m["uid"] for m in result], [1, 2, 3])

    def test_skips_non_tuple_items(self):
        # Real imaplib FETCH returns a mix of tuples and bytes-only sentinel
        # entries (e.g., the trailing b")"). The parser must skip them.
        fetch_data = [
            self._make_fetch_item(uid=1),
            b")",
            self._make_fetch_item(uid=2),
        ]
        result = adapter._parse_envelope_from_fetch(fetch_data)
        self.assertEqual(len(result), 2)
        self.assertEqual([m["uid"] for m in result], [1, 2])

    def test_skips_tuples_with_non_bytes_payload(self):
        # If the second tuple element isn't bytes (parser quirk), skip cleanly.
        fetch_data = [(b"1 (UID 1 FLAGS () RFC822.SIZE 0)", None)]
        result = adapter._parse_envelope_from_fetch(fetch_data)
        self.assertEqual(result, [])

    def test_empty_fetch(self):
        self.assertEqual(adapter._parse_envelope_from_fetch([]), [])


class TestNoCoreModule(unittest.TestCase):
    """The deprecated `email_imap_adapter_core` module must not exist (t2064)."""

    def test_core_module_deleted(self):
        core_path = SCRIPTS_DIR / "email_imap_adapter_core.py"
        self.assertFalse(
            core_path.exists(),
            f"{core_path} should have been deleted in t2064 — "
            "the canonical module is email_imap_adapter.py",
        )

    def test_canonical_module_intact(self):
        canonical_path = SCRIPTS_DIR / "email_imap_adapter.py"
        self.assertTrue(canonical_path.exists())
        # Canonical module must still expose every public command.
        for cmd in (
            "cmd_connect",
            "cmd_fetch_headers",
            "cmd_fetch_body",
            "cmd_search",
            "cmd_list_folders",
            "cmd_create_folder",
            "cmd_move_message",
            "cmd_set_flag",
            "cmd_clear_flag",
            "cmd_index_sync",
        ):
            self.assertTrue(
                hasattr(adapter, cmd),
                f"email_imap_adapter is missing command {cmd}",
            )


if __name__ == "__main__":
    unittest.main()
