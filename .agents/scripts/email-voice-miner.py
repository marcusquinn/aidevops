#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email-voice-miner.py - Extract user writing patterns from sent mail.

Analyzes the sent folder of an IMAP mailbox (50-100 emails by default) to
extract greeting/closing patterns, sentence structure, vocabulary, tone
distribution, and other stylistic signals. Outputs a condensed markdown
style guide stored at:

  ~/.aidevops/.agent-workspace/email-intelligence/voice-profile-{account}.md

The voice profile contains patterns only — never raw email content.
It is referenced by the composition helper (t1495) to personalise AI-composed
emails so they sound like the user, not like a generic AI.

Usage:
  python3 email-voice-miner.py --account <name> --imap-host <host> \\
      --imap-user <user> [--imap-port 993] [--sample-size 75] \\
      [--sent-folder "Sent"] [--output-dir ~/.aidevops/.agent-workspace/email-intelligence]

  # Password is read from IMAP_PASSWORD env var (never as CLI arg)
  IMAP_PASSWORD="..." python3 email-voice-miner.py --account work ...

  # Or use gopass:
  IMAP_PASSWORD=$(gopass show -o imap/work) python3 email-voice-miner.py ...

Options:
  --account       Account name used in output filename (required)
  --imap-host     IMAP server hostname (required)
  --imap-user     IMAP username / email address (required)
  --imap-port     IMAP port (default: 993, SSL)
  --sample-size   Number of sent emails to analyze (default: 75, max: 200)
  --sent-folder   IMAP folder name for sent mail (default: auto-detect)
  --output-dir    Directory for voice profile output (default: see above)
  --dry-run       Print analysis summary without writing profile file
  --verbose       Print progress to stderr

Privacy:
  The output profile contains extracted patterns (frequencies, examples
  stripped of personal details) — never raw email bodies, addresses, or
  subject lines. The script strips quoted replies before analysis so only
  the user's own words are processed.

Dependencies (all stdlib except anthropic):
  - imaplib, email, re, collections, statistics (stdlib)
  - anthropic (pip install anthropic) — for AI pattern synthesis
  - ANTHROPIC_API_KEY env var required for AI synthesis step

Part of aidevops email intelligence system (t1501).
"""

import argparse
import imaplib
import os
import sys
from pathlib import Path
from typing import Optional

# Re-export public surface for backwards compatibility
from email_voice_imap import (
    SENT_FOLDER_CANDIDATES as SENT_FOLDER_CANDIDATES,
    connect_imap as connect_imap,
    detect_sent_folder as detect_sent_folder,
    fetch_sent_emails as fetch_sent_emails,
    _decode_folder_entry as _decode_folder_entry,
    _extract_folder_name as _extract_folder_name,
    _list_imap_folders as _list_imap_folders,
    _find_sent_by_special_use as _find_sent_by_special_use,
    _find_sent_by_name as _find_sent_by_name,
    _select_imap_folder as _select_imap_folder,
    _fetch_message_ids as _fetch_message_ids,
    _parse_fetched_message as _parse_fetched_message,
)
from email_voice_patterns import (  # noqa: F401
    GREETING_PATTERNS,
    CLOSING_PATTERNS,
    STOP_WORDS,
    get_plain_body,
    strip_quoted_content,
    extract_greeting,
    extract_closing,
    count_sentences,
    count_words,
    extract_vocabulary,
    detect_tone,
    extract_recipient_type,
)
from email_voice_analyzer import (  # noqa: F401
    analyse_emails,
    synthesise_with_ai,
    generate_profile_markdown,
)


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_OUTPUT_DIR = Path.home() / ".aidevops" / ".agent-workspace" / "email-intelligence"
DEFAULT_SAMPLE_SIZE = 75
MAX_SAMPLE_SIZE = 200
DEFAULT_IMAP_PORT = 993

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Extract user writing patterns from sent mail folder",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--account", required=True,
                        help="Account name for output filename (e.g. 'work', 'personal')")
    parser.add_argument("--imap-host", required=True,
                        help="IMAP server hostname")
    parser.add_argument("--imap-user", required=True,
                        help="IMAP username / email address")
    parser.add_argument("--imap-port", type=int, default=DEFAULT_IMAP_PORT,
                        help=f"IMAP port (default: {DEFAULT_IMAP_PORT})")
    parser.add_argument(
        "--sample-size", type=int, default=DEFAULT_SAMPLE_SIZE,
        help=(
            f"Number of sent emails to analyse "
            f"(default: {DEFAULT_SAMPLE_SIZE}, max: {MAX_SAMPLE_SIZE})"
        ),
    )
    parser.add_argument("--sent-folder", default=None,
                        help="IMAP folder name for sent mail (default: auto-detect)")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR,
                        help=f"Output directory for voice profile (default: {DEFAULT_OUTPUT_DIR})")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print analysis summary without writing profile file")
    parser.add_argument("--verbose", action="store_true",
                        help="Print progress to stderr")
    return parser.parse_args()


def _log(verbose: bool, msg: str) -> None:
    """Print a progress message to stderr if verbose mode is enabled."""
    if verbose:
        print(msg, file=sys.stderr)


def _get_imap_password() -> Optional[str]:
    """Read IMAP password from environment. Returns None if unset."""
    password = os.environ.get("IMAP_PASSWORD", "")
    if not password:
        print(
            "ERROR: IMAP_PASSWORD environment variable is required\n"
            "  Set it before running: "
            "IMAP_PASSWORD='...' python3 email-voice-miner.py ...\n"
            "  Or use gopass: "
            "IMAP_PASSWORD=$(gopass show -o imap/account) python3 ...",
            file=sys.stderr,
        )
        return None
    return password


def _resolve_sent_folder(
    conn: imaplib.IMAP4_SSL,
    explicit_folder: Optional[str],
    verbose: bool,
) -> Optional[str]:
    """Return the sent folder name, auto-detecting if not specified."""
    if explicit_folder:
        return explicit_folder
    _log(verbose, "Auto-detecting sent folder...")
    folder = detect_sent_folder(conn, verbose=verbose)
    if not folder:
        print(
            "ERROR: Could not auto-detect sent folder.\n"
            "  Use --sent-folder to specify it explicitly.",
            file=sys.stderr,
        )
    else:
        _log(verbose, f"  Detected sent folder: '{folder}'")
    return folder


def _write_profile(
    profile_md: str, output_dir: Path, account: str,
) -> None:
    """Write the voice profile to disk with secure permissions."""
    output_dir.mkdir(parents=True, exist_ok=True)
    output_dir.chmod(0o700)

    output_file = output_dir / f"voice-profile-{account}.md"
    output_file.write_text(profile_md, encoding="utf-8")
    output_file.chmod(0o600)

    print(f"Voice profile written to: {output_file}")


def _fetch_messages(args, sample_size: int):
    """Connect to IMAP and fetch sent messages. Returns (messages, error_code).

    Returns (None, 1) on connection or folder errors.
    """
    password = _get_imap_password()
    if not password:
        return None, 1

    _log(args.verbose, f"Connecting to {args.imap_host}:{args.imap_port}...")
    conn = connect_imap(args.imap_host, args.imap_port, args.imap_user, password)

    sent_folder = _resolve_sent_folder(conn, args.sent_folder, args.verbose)
    if not sent_folder:
        conn.logout()
        return None, 1

    _log(args.verbose, f"Fetching up to {sample_size} emails from '{sent_folder}'...")
    messages = fetch_sent_emails(conn, sent_folder, sample_size, verbose=args.verbose)
    conn.logout()
    return messages, 0


def _build_profile(args, messages) -> str:
    """Analyse messages and synthesise voice profile markdown.

    Returns the profile markdown string, or None on analysis failure.
    """
    _log(args.verbose, f"Fetched {len(messages)} emails. Analysing...")
    analysis = analyse_emails(messages, verbose=args.verbose)
    if not analysis:
        print(
            "ERROR: Analysis produced no results "
            "(emails may be empty or unreadable)",
            file=sys.stderr,
        )
        return None

    _log(args.verbose, f"Analysis complete. {analysis['total_analysed']} emails processed.")

    ai_synthesis = None
    if not args.dry_run:
        _log(args.verbose, "Running AI synthesis (requires ANTHROPIC_API_KEY)...")
        ai_synthesis = synthesise_with_ai(analysis)
        if ai_synthesis:
            _log(args.verbose, "AI synthesis complete.")

    return generate_profile_markdown(analysis, args.account, ai_synthesis), analysis


def main() -> int:
    """Main entry point. Returns exit code."""
    args = parse_args()
    sample_size = min(args.sample_size, MAX_SAMPLE_SIZE)
    if sample_size < 10:
        print(
            "WARNING: Sample size < 10 may produce unreliable patterns",
            file=sys.stderr,
        )

    messages, err = _fetch_messages(args, sample_size)
    if err:
        return err

    if not messages:
        print("ERROR: No emails fetched from sent folder", file=sys.stderr)
        return 1

    result = _build_profile(args, messages)
    if result is None:
        return 1

    profile_md, analysis = result

    if args.dry_run:
        print(profile_md)
        return 0

    _write_profile(profile_md, args.output_dir, args.account)
    print(f"Analysed: {analysis['total_analysed']} emails")
    print(f"Dominant tone: {analysis.get('dominant_tone', 'unknown')}")
    print(f"Avg email length: {analysis.get('avg_words_per_email', 0)} words")

    return 0


if __name__ == "__main__":
    sys.exit(main())
