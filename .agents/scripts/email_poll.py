#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_poll.py - IMAP polling script for the aidevops knowledge plane.

Polls configured IMAP mailboxes, fetches new messages since the last-seen UID,
and drops each message as an .eml file into _knowledge/inbox/.

Part of aidevops email-poll system (t2855).

Usage:
    python3 email_poll.py tick --config CONFIG --state STATE --inbox INBOX
    python3 email_poll.py backfill --config CONFIG --state STATE --inbox INBOX
                                   --mailbox-id ID --since 2026-01-01
    python3 email_poll.py test --config CONFIG --mailbox-id ID
    python3 email_poll.py list --config CONFIG [--state STATE]

Credentials: resolved via gopass or environment variable (see _resolve_password).
Config:      ~/.config/aidevops/mailboxes.json or _config/mailboxes.json
State:       _knowledge/.imap-state.json (per-mailbox high-watermark UIDs)
Inbox:       _knowledge/inbox/ (output .eml files)

Output: JSON summary to stdout. Errors to stderr.
"""

import argparse
import email as email_lib
import imaplib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path


# ---------------------------------------------------------------------------
# Poll configuration
# ---------------------------------------------------------------------------

@dataclass
class PollConfig:
    """Options controlling how a single mailbox poll run behaves.

    Bundling these into one object keeps poll_mailbox and _poll_folder
    at a low parameter count while remaining easy to extend.
    """

    inbox_dir: str = ""
    dry_run: bool = False
    rate_limit_per_min: int = 0
    max_messages: int = 0


# ---------------------------------------------------------------------------
# Credential resolution
# ---------------------------------------------------------------------------

def _resolve_password(password_ref: str) -> str:
    """Resolve a password reference to a plaintext password.

    Supports two forms:
      - Starts with 'gopass:' → calls `gopass show -o <path>` silently.
      - Anything else         → treated as an environment variable name.

    Never logs the resolved password value.
    """
    if not password_ref:
        raise ValueError("password_ref is empty")

    if password_ref.startswith("gopass:"):
        gopass_path = password_ref[len("gopass:"):]
        try:
            result = subprocess.run(
                ["gopass", "show", "-o", gopass_path],
                capture_output=True,
                text=True,
                check=True,
            )
            return result.stdout.strip()
        except subprocess.CalledProcessError as exc:
            raise RuntimeError(
                f"gopass show failed for path '{gopass_path}': {exc.stderr.strip()}"
            ) from exc
        except FileNotFoundError as exc:
            raise RuntimeError(
                "gopass is not installed or not in PATH"
            ) from exc

    # Treat as environment variable name
    value = os.environ.get(password_ref)
    if value is None:
        raise RuntimeError(
            f"Environment variable '{password_ref}' is not set"
        )
    return value


# ---------------------------------------------------------------------------
# Mailboxes config
# ---------------------------------------------------------------------------

def load_mailboxes_config(config_path: str) -> dict:
    """Load and validate mailboxes.json config."""
    path = Path(config_path)
    if not path.exists():
        raise FileNotFoundError(f"mailboxes config not found: {config_path}")
    with path.open() as f:
        data = json.load(f)
    if "mailboxes" not in data:
        raise ValueError("mailboxes config must have a 'mailboxes' key")
    return data


def get_mailbox_config(config: dict, mailbox_id: str) -> dict:
    """Return config entry for a specific mailbox ID."""
    for mb in config.get("mailboxes", []):
        if mb.get("id") == mailbox_id:
            return mb
    raise KeyError(f"Mailbox '{mailbox_id}' not found in config")


# ---------------------------------------------------------------------------
# State management
# ---------------------------------------------------------------------------

def load_state(state_path: str) -> dict:
    """Load per-mailbox IMAP polling state (last-seen UIDs)."""
    path = Path(state_path)
    if not path.exists():
        return {}
    with path.open() as f:
        return json.load(f)


def save_state(state_path: str, state: dict) -> None:
    """Persist per-mailbox IMAP polling state atomically."""
    path = Path(state_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(".tmp")
    with tmp_path.open("w") as f:
        json.dump(state, f, indent=2)
        f.write("\n")
    tmp_path.replace(path)


def _state_key(mailbox_id: str, folder: str) -> str:
    """Canonical state dictionary key for a mailbox+folder pair."""
    safe_folder = re.sub(r"[^a-zA-Z0-9_/-]", "_", folder)
    return f"{mailbox_id}/{safe_folder}"


# ---------------------------------------------------------------------------
# IMAP connection helpers
# ---------------------------------------------------------------------------

def _connect_imap(host: str, port: int, user: str, password: str) -> imaplib.IMAP4_SSL:
    """Open an IMAP4_SSL connection and authenticate."""
    conn = imaplib.IMAP4_SSL(host, port)
    conn.login(user, password)
    return conn


def _search_uids_since(
    conn: imaplib.IMAP4_SSL, folder: str, last_uid: int, max_uids: int = 0
) -> list[int]:
    """SELECT folder and return UIDs > last_uid, optionally capped at max_uids.

    Returns a plain list[int]. Raises RuntimeError on IMAP errors.
    """
    status, _ = conn.select(f'"{folder}"', readonly=True)
    if status != "OK":
        raise RuntimeError(f"SELECT '{folder}' failed: {status}")

    start_uid = last_uid + 1
    status, data = conn.uid("SEARCH", None, f"UID {start_uid}:*")  # type: ignore[arg-type]
    if status != "OK":
        raise RuntimeError(f"UID SEARCH failed: {status}")

    uid_list_raw = data[0]
    if not uid_list_raw:
        return []

    uid_strings = uid_list_raw.decode().split()
    if not uid_strings:
        return []

    # Filter: server may return * = UIDNEXT-1 when the range is empty
    valid_uids = [int(u) for u in uid_strings if int(u) > last_uid]
    if not valid_uids:
        return []

    if max_uids > 0:
        valid_uids = valid_uids[:max_uids]

    return valid_uids


def _parse_fetch_response(
    fetch_data: list, valid_uids: list, last_uid: int = 0
) -> list[tuple[int, bytes]]:
    """Parse an imaplib RFC822 FETCH response into (uid, raw_bytes) tuples.

    Returns list[tuple[int, bytes]], sorted by UID ascending.
    Only includes messages with UID > last_uid (use last_uid=0 for all).
    """
    messages = []
    i = 0
    while i < len(fetch_data):
        item = fetch_data[i]
        if isinstance(item, tuple):
            header_part = item[0]
            raw_msg = item[1]
            uid_match = re.search(rb"UID\s+(\d+)", header_part)
            if uid_match:
                uid = int(uid_match.group(1))
            else:
                # Fallback: infer from position in valid_uids
                uid = valid_uids[len(messages)] if len(messages) < len(valid_uids) else 0
            if uid > last_uid:
                messages.append((uid, raw_msg))
        i += 1

    messages.sort(key=lambda t: t[0])
    return messages


def _uid_fetch_since(
    conn: imaplib.IMAP4_SSL, folder: str, last_uid: int, max_uids: int = 0
) -> list[tuple[int, bytes]]:
    """Fetch messages with UID > last_uid in folder.

    Args:
        max_uids: If > 0, fetch at most this many messages (oldest first).
                  Used by cmd_test to avoid fetching entire mailboxes.

    Returns a list of (uid, raw_rfc822_bytes) tuples sorted by UID ascending.
    """
    valid_uids = _search_uids_since(conn, folder, last_uid, max_uids)
    if not valid_uids:
        return []

    uid_set = ",".join(str(u) for u in valid_uids)
    status, fetch_data = conn.uid("FETCH", uid_set, "(RFC822)")  # type: ignore[arg-type]
    if status != "OK":
        raise RuntimeError(f"UID FETCH failed: {status}")

    return _parse_fetch_response(fetch_data, valid_uids, last_uid)


def _uid_fetch_since_date(
    conn: imaplib.IMAP4_SSL, folder: str, since_date: str
) -> list[tuple[int, bytes]]:
    """Fetch all messages in folder with INTERNALDATE >= since_date.

    since_date: ISO date string, e.g. '2026-01-01'.
    Returns (uid, raw_rfc822) tuples sorted by UID ascending.
    """
    status, _ = conn.select(f'"{folder}"', readonly=True)
    if status != "OK":
        raise RuntimeError(f"SELECT '{folder}' failed: {status}")

    # IMAP SEARCH date format: DD-Mon-YYYY (e.g. 01-Jan-2026)
    dt = datetime.strptime(since_date, "%Y-%m-%d")
    imap_date = dt.strftime("%d-%b-%Y")

    status, data = conn.uid("SEARCH", None, f"SINCE {imap_date}")  # type: ignore[arg-type]
    if status != "OK":
        raise RuntimeError(f"UID SEARCH SINCE failed: {status}")

    uid_list_raw = data[0]
    if not uid_list_raw:
        return []

    uid_strings = uid_list_raw.decode().split()
    if not uid_strings:
        return []

    valid_uids = [int(u) for u in uid_strings]
    if not valid_uids:
        return []

    uid_set = ",".join(str(u) for u in valid_uids)
    status, fetch_data = conn.uid("FETCH", uid_set, "(RFC822)")  # type: ignore[arg-type]
    if status != "OK":
        raise RuntimeError(f"UID FETCH failed: {status}")

    # last_uid=0 → keep all messages (UIDs are always >= 1)
    return _parse_fetch_response(fetch_data, valid_uids, last_uid=0)


# ---------------------------------------------------------------------------
# .eml file output
# ---------------------------------------------------------------------------

def _write_eml(inbox_dir: str, mailbox_id: str, folder: str, uid: int, raw_msg: bytes) -> Path:
    """Write raw RFC-822 bytes to inbox_dir/email-<mailbox_id>-<folder>-<uid>.eml.

    Folder is included to prevent UID collisions across folders (UIDs are
    per-folder on IMAP servers, so the same UID can exist in multiple folders).
    """
    Path(inbox_dir).mkdir(parents=True, exist_ok=True)
    safe_id = re.sub(r"[^a-zA-Z0-9_-]", "_", mailbox_id)
    safe_folder = re.sub(r"[^a-zA-Z0-9_-]", "_", folder)
    filename = f"email-{safe_id}-{safe_folder}-{uid}.eml"
    out_path = Path(inbox_dir) / filename
    out_path.write_bytes(raw_msg)
    return out_path


# ---------------------------------------------------------------------------
# Folder-level polling helper
# ---------------------------------------------------------------------------

def _poll_folder(
    conn: imaplib.IMAP4_SSL,
    mb_id: str,
    folder: str,
    state: dict,
    config: PollConfig,
) -> dict:
    """Poll a single IMAP folder; update state in place.

    Returns a folder-result dict: {folder, fetched, new_high_uid, error}.
    Separated from poll_mailbox to keep cyclomatic complexity low.
    """
    import time  # noqa: PLC0415

    key = _state_key(mb_id, folder)
    last_uid = state.get(key, {}).get("last_uid_seen", 0)
    now_iso = datetime.now(timezone.utc).isoformat()
    folder_result: dict = {"folder": folder, "fetched": 0, "error": None}

    try:
        messages = _uid_fetch_since(conn, folder, last_uid, max_uids=config.max_messages)
    except Exception as exc:
        folder_result["error"] = str(exc)
        folder_result["new_high_uid"] = last_uid
        return folder_result

    new_high_uid = last_uid
    delay = (60.0 / config.rate_limit_per_min) if config.rate_limit_per_min > 0 else 0

    for uid, raw_msg in messages:
        if not config.dry_run:
            _write_eml(config.inbox_dir, mb_id, folder, uid, raw_msg)
        if uid > new_high_uid:
            new_high_uid = uid
        folder_result["fetched"] += 1
        if delay > 0:
            time.sleep(delay)

    if not config.dry_run and new_high_uid > last_uid:
        state[key] = {"last_uid_seen": new_high_uid, "last_polled_at": now_iso}

    folder_result["new_high_uid"] = new_high_uid
    return folder_result


# ---------------------------------------------------------------------------
# Core polling logic
# ---------------------------------------------------------------------------

def poll_mailbox(mb_config: dict, state: dict, config: "PollConfig | None" = None) -> dict:
    """Poll a single mailbox; return a per-mailbox result dict.

    Args:
        mb_config: Entry from mailboxes.json 'mailboxes' array.
        state:     Full state dict (mutated in place on success).
        config:    PollConfig with inbox_dir, dry_run, rate_limit_per_min,
                   max_messages.  Defaults to PollConfig() (empty inbox_dir,
                   no limits) when None.

    Returns:
        {mailbox_id, status, fetched_count, folders, error?}
    """
    if config is None:
        config = PollConfig()

    mb_id = mb_config["id"]
    host = mb_config["host"]
    port = int(mb_config.get("port", 993))
    user = mb_config["user"]
    password_ref = mb_config.get("password_ref", "")
    folders = mb_config.get("folders", ["INBOX"])
    now_iso = datetime.now(timezone.utc).isoformat()

    result: dict = {
        "mailbox_id": mb_id,
        "status": "ok",
        "fetched_count": 0,
        "folders": {},
    }

    try:
        password = _resolve_password(password_ref)
    except Exception as exc:
        result["status"] = "credential_error"
        result["error"] = str(exc)
        state.setdefault(mb_id, {})["last_error"] = str(exc)
        state[mb_id]["last_polled_at"] = now_iso
        return result

    try:
        conn = _connect_imap(host, port, user, password)
    except Exception as exc:
        result["status"] = "connection_error"
        result["error"] = str(exc)
        state.setdefault(mb_id, {})["last_error"] = str(exc)
        state[mb_id]["last_polled_at"] = now_iso
        return result

    total_fetched = 0
    try:
        for folder in folders:
            folder_result = _poll_folder(conn, mb_id, folder, state, config)
            if folder_result.get("error"):
                result["status"] = "partial_error"
            total_fetched += folder_result["fetched"]
            result["folders"][folder] = folder_result
    finally:
        try:
            conn.logout()
        except Exception:
            pass

    result["fetched_count"] = total_fetched
    if not config.dry_run:
        state.setdefault(mb_id, {})["last_polled_at"] = now_iso
        state[mb_id].pop("last_error", None)

    return result


def backfill_mailbox(
    mb_config: dict,
    state: dict,
    inbox_dir: str,
    since_date: str,
    rate_limit_per_min: int = 100,
) -> dict:
    """Back-fill a single mailbox from since_date (bypasses last-seen UID).

    Rate-limited to avoid IMAP-server abuse (default: 100 msgs/min).
    Does NOT update the high-watermark UID (backfill is additive, not a tick).
    """
    import time  # noqa: PLC0415

    mb_id = mb_config["id"]
    host = mb_config["host"]
    port = int(mb_config.get("port", 993))
    user = mb_config["user"]
    password_ref = mb_config.get("password_ref", "")
    folders = mb_config.get("folders", ["INBOX"])

    result: dict = {
        "mailbox_id": mb_id,
        "status": "ok",
        "fetched_count": 0,
        "since_date": since_date,
        "folders": {},
    }

    try:
        password = _resolve_password(password_ref)
    except Exception as exc:
        result["status"] = "credential_error"
        result["error"] = str(exc)
        return result

    try:
        conn = _connect_imap(host, port, user, password)
    except Exception as exc:
        result["status"] = "connection_error"
        result["error"] = str(exc)
        return result

    total_fetched = 0
    delay = (60.0 / rate_limit_per_min) if rate_limit_per_min > 0 else 0

    try:
        for folder in folders:
            folder_result = {"folder": folder, "fetched": 0, "error": None}
            try:
                messages = _uid_fetch_since_date(conn, folder, since_date)
            except Exception as exc:
                folder_result["error"] = str(exc)
                result["folders"][folder] = folder_result
                result["status"] = "partial_error"
                continue

            for uid, raw_msg in messages:
                _write_eml(inbox_dir, mb_id, folder, uid, raw_msg)
                total_fetched += 1
                folder_result["fetched"] += 1
                if delay > 0:
                    time.sleep(delay)

            folder_result["message_count"] = len(messages)
            result["folders"][folder] = folder_result
    finally:
        try:
            conn.logout()
        except Exception:
            pass

    result["fetched_count"] = total_fetched
    return result


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def cmd_tick(args: argparse.Namespace) -> int:
    """Tick: poll all mailboxes, write new messages to inbox."""
    config = load_mailboxes_config(args.config)
    state = load_state(args.state)
    poll_cfg = PollConfig(inbox_dir=args.inbox)
    results = []
    overall_ok = True

    for mb_config in config.get("mailboxes", []):
        try:
            res = poll_mailbox(mb_config, state, poll_cfg)
        except Exception as exc:  # noqa: BLE001
            res = {
                "mailbox_id": mb_config.get("id", "unknown"),
                "status": "exception",
                "error": str(exc),
                "fetched_count": 0,
            }
        results.append(res)
        if res["status"] not in ("ok",):
            overall_ok = False

    save_state(args.state, state)

    output = {
        "tick": datetime.now(timezone.utc).isoformat(),
        "results": results,
        "overall_status": "ok" if overall_ok else "partial_error",
    }
    print(json.dumps(output, indent=2))
    return 0 if overall_ok else 1


def cmd_backfill(args: argparse.Namespace) -> int:
    """Backfill a specific mailbox from a given date."""
    config = load_mailboxes_config(args.config)
    mb_config = get_mailbox_config(config, args.mailbox_id)
    state = load_state(args.state)

    res = backfill_mailbox(
        mb_config,
        state,
        args.inbox,
        args.since,
        rate_limit_per_min=args.rate_limit,
    )
    print(json.dumps(res, indent=2))
    return 0 if res["status"] == "ok" else 1


def cmd_test(args: argparse.Namespace) -> int:
    """Dry-run: fetch 1 message from each folder, do NOT write .eml or update state."""
    config = load_mailboxes_config(args.config)
    mb_config = get_mailbox_config(config, args.mailbox_id)
    state: dict = {}

    poll_cfg = PollConfig(inbox_dir="/dev/null", dry_run=True, max_messages=1)
    res = poll_mailbox(mb_config, state, poll_cfg)
    print(json.dumps(res, indent=2))
    return 0 if res["status"] in ("ok", "partial_error") else 1


def cmd_list(args: argparse.Namespace) -> int:
    """List configured mailboxes with last-polled-at and last-error."""
    config = load_mailboxes_config(args.config)
    state: dict = {}
    if args.state and Path(args.state).exists():
        state = load_state(args.state)

    rows = []
    for mb in config.get("mailboxes", []):
        mb_id = mb["id"]
        folders = mb.get("folders", ["INBOX"])
        folder_states = {}
        for f in folders:
            key = _state_key(mb_id, f)
            fs = state.get(key, {})
            folder_states[f] = {
                "last_uid_seen": fs.get("last_uid_seen", 0),
                "last_polled_at": fs.get("last_polled_at"),
            }
        mb_state = state.get(mb_id, {})
        rows.append({
            "id": mb_id,
            "provider": mb.get("provider"),
            "host": mb["host"],
            "user": mb["user"],
            "folders": folders,
            "last_polled_at": mb_state.get("last_polled_at"),
            "last_error": mb_state.get("last_error"),
            "folder_state": folder_states,
        })

    print(json.dumps({"mailboxes": rows}, indent=2))
    return 0


# ---------------------------------------------------------------------------
# Argument parsing and main
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="IMAP polling for aidevops knowledge plane (t2855)"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # tick
    p_tick = sub.add_parser("tick", help="Poll all mailboxes for new messages")
    p_tick.add_argument("--config", required=True, help="Path to mailboxes.json")
    p_tick.add_argument("--state", required=True, help="Path to .imap-state.json")
    p_tick.add_argument("--inbox", required=True, help="Directory to write .eml files")

    # backfill
    p_bf = sub.add_parser("backfill", help="Backfill a mailbox from a given date")
    p_bf.add_argument("--config", required=True)
    p_bf.add_argument("--state", required=True)
    p_bf.add_argument("--inbox", required=True)
    p_bf.add_argument("--mailbox-id", required=True, help="Mailbox ID to backfill")
    p_bf.add_argument("--since", required=True, help="ISO date, e.g. 2026-01-01")
    p_bf.add_argument(
        "--rate-limit", type=int, default=100,
        help="Max messages per minute (default: 100)"
    )

    # test
    p_test = sub.add_parser("test", help="Dry-run: connect + fetch without writing files")
    p_test.add_argument("--config", required=True)
    p_test.add_argument("--mailbox-id", required=True)

    # list
    p_list = sub.add_parser("list", help="List configured mailboxes and their state")
    p_list.add_argument("--config", required=True)
    p_list.add_argument("--state", default="", help="Optional path to .imap-state.json")

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    dispatch = {
        "tick": cmd_tick,
        "backfill": cmd_backfill,
        "test": cmd_test,
        "list": cmd_list,
    }

    handler = dispatch.get(args.command)
    if handler is None:
        print(f"Unknown command: {args.command}", file=sys.stderr)
        return 2

    try:
        return handler(args)
    except KeyboardInterrupt:
        return 130
    except Exception as exc:  # noqa: BLE001
        print(f"Fatal error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
