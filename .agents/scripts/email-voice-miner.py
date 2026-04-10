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
import email
import email.errors
import email.policy
import email.utils
import imaplib
import json
import os
import re
import statistics
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional, Tuple


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_OUTPUT_DIR = Path.home() / ".aidevops" / ".agent-workspace" / "email-intelligence"
DEFAULT_SAMPLE_SIZE = 75
MAX_SAMPLE_SIZE = 200
DEFAULT_IMAP_PORT = 993

# Common sent folder names across providers
SENT_FOLDER_CANDIDATES = [
    "Sent",
    "Sent Items",
    "Sent Messages",
    "[Gmail]/Sent Mail",
    "INBOX.Sent",
    "Sent Mail",
]

# Regex patterns for greeting detection (case-insensitive)
GREETING_PATTERNS = [
    r"^(hi|hello|hey|dear|good morning|good afternoon|good evening|greetings|howdy)\b",
    r"^(hi there|hello there|hey there)\b",
    r"^(to whom it may concern)\b",
    r"^(hope (this|you|all)\b)",
    r"^(thanks for|thank you for)\b",
    r"^(following up|just following)\b",
    r"^(quick (question|note|update))\b",
    r"^(as (discussed|promised|requested|per))\b",
    r"^(i hope (this|you))\b",
    r"^(i wanted to|i'm reaching out|i am reaching out)\b",
]

# Regex patterns for closing detection (case-insensitive)
CLOSING_PATTERNS = [
    r"^(best|best regards|kind regards|warm regards|regards|warmly)\s*[,.]?\s*$",
    r"^(thanks|thank you|many thanks|thanks so much|thanks again)\s*[,.]?\s*$",
    r"^(cheers|all the best|take care|talk soon|speak soon)\s*[,.]?\s*$",
    r"^(sincerely|yours sincerely|yours truly|faithfully)\s*[,.]?\s*$",
    r"^(looking forward|looking forward to)\b",
    r"^(let me know|please let me know|feel free to)\b",
    r"^(don't hesitate to|please don't hesitate)\b",
    r"^(happy to (help|discuss|chat|answer))\b",
]

# Words/phrases to exclude from vocabulary analysis (stop words + noise)
STOP_WORDS = {
    "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for",
    "of", "with", "by", "from", "up", "about", "into", "through", "during",
    "is", "are", "was", "were", "be", "been", "being", "have", "has", "had",
    "do", "does", "did", "will", "would", "could", "should", "may", "might",
    "shall", "can", "need", "dare", "ought", "used", "it", "its", "this",
    "that", "these", "those", "i", "me", "my", "we", "our", "you", "your",
    "he", "she", "they", "them", "their", "what", "which", "who", "whom",
    "not", "no", "nor", "so", "yet", "both", "either", "neither", "each",
    "few", "more", "most", "other", "some", "such", "than", "too", "very",
    "just", "also", "as", "if", "then", "there", "when", "where", "while",
    "how", "all", "any", "every", "here", "now", "only",
    "own", "same", "well", "re", "ve", "ll", "d",
    "s", "t", "m",
}


# ---------------------------------------------------------------------------
# IMAP helpers
# ---------------------------------------------------------------------------

def connect_imap(host: str, port: int, user: str, password: str) -> imaplib.IMAP4_SSL:
    """Connect and authenticate to IMAP server via SSL."""
    try:
        conn = imaplib.IMAP4_SSL(host, port)
    except (OSError, imaplib.IMAP4.error) as exc:
        print(f"ERROR: Cannot connect to {host}:{port} — {exc}", file=sys.stderr)
        sys.exit(1)

    try:
        conn.login(user, password)
    except imaplib.IMAP4.error as exc:
        print(f"ERROR: IMAP login failed for {user} — {exc}", file=sys.stderr)
        sys.exit(1)

    return conn


def _decode_folder_entry(raw) -> str:
    """Decode a raw IMAP LIST folder entry to a string."""
    if isinstance(raw, (bytes, bytearray)):
        return raw.decode("utf-8", errors="replace")
    if isinstance(raw, (list, tuple)):
        return b"".join(
            p for p in raw if isinstance(p, (bytes, bytearray))
        ).decode("utf-8", errors="replace")
    return str(raw)


def _extract_folder_name(decoded: str) -> Optional[str]:
    """Extract folder name from a decoded IMAP LIST response line."""
    match = re.search(r'"([^"]+)"\s*$', decoded)
    if not match:
        match = re.search(r'(\S+)\s*$', decoded)
    return match.group(1) if match else None


def _list_imap_folders(folders) -> list:
    """Extract folder names from raw IMAP LIST response entries."""
    available = []
    for folder_raw in folders:
        if not folder_raw:
            continue
        decoded = _decode_folder_entry(folder_raw)
        name = _extract_folder_name(decoded)
        if name:
            available.append(name)
    return available


def _find_sent_by_special_use(folders) -> Optional[str]:
    """Return the first folder with the \\Sent special-use attribute, or None."""
    for folder_raw in folders:
        if not folder_raw:
            continue
        decoded = _decode_folder_entry(folder_raw)
        if r"\Sent" in decoded:
            name = _extract_folder_name(decoded)
            if name:
                return name
    return None


def _find_sent_by_name(available: list) -> Optional[str]:
    """Return the first folder matching a known sent-folder name, or None."""
    available_lower = {f.lower(): f for f in available}
    for candidate in SENT_FOLDER_CANDIDATES:
        if candidate.lower() in available_lower:
            return available_lower[candidate.lower()]
    return None


def detect_sent_folder(
    conn: imaplib.IMAP4_SSL, verbose: bool = False,
) -> Optional[str]:
    """Auto-detect the sent mail folder by listing IMAP folders."""
    status, folders = conn.list()
    if status != "OK":
        return None

    available = _list_imap_folders(folders)
    if verbose:
        print(f"  Available folders: {available}", file=sys.stderr)

    return _find_sent_by_special_use(folders) or _find_sent_by_name(available)


def _select_imap_folder(conn: imaplib.IMAP4_SSL, folder: str) -> None:
    """Select an IMAP folder, trying with and without quotes. Exits on failure."""
    status, _ = conn.select(f'"{folder}"', readonly=True)
    if status != "OK":
        status, _ = conn.select(folder, readonly=True)
        if status != "OK":
            print(f"ERROR: Cannot select folder '{folder}'", file=sys.stderr)
            sys.exit(1)


def _fetch_message_ids(conn: imaplib.IMAP4_SSL) -> list:
    """Search for all message IDs in the currently selected folder.

    Returns list of message ID byte strings, or empty list on failure.
    """
    status, data = conn.search(None, "ALL")
    if status != "OK" or not data or not data[0]:
        print("WARNING: No messages found in sent folder", file=sys.stderr)
        return []
    return data[0].split()


def _parse_fetched_message(msg_id, msg_data, verbose: bool):
    """Parse a single fetched RFC822 message. Returns Message or None."""
    if not msg_data or not msg_data[0]:
        return None
    raw = msg_data[0][1]
    if not isinstance(raw, bytes):
        return None
    try:
        return email.message_from_bytes(raw, policy=email.policy.default)
    except (ValueError, email.errors.MessageError) as exc:
        if verbose:
            print(f"  WARNING: Failed to parse message {msg_id}: {exc}", file=sys.stderr)
        return None


def fetch_sent_emails(
    conn: imaplib.IMAP4_SSL,
    folder: str,
    sample_size: int,
    verbose: bool = False,
) -> list:
    """Fetch the most recent `sample_size` emails from the sent folder.

    Returns a list of email.message.Message objects.
    """
    _select_imap_folder(conn, folder)

    all_ids = _fetch_message_ids(conn)
    if not all_ids:
        return []

    total = len(all_ids)
    if verbose:
        print(f"  Found {total} messages in '{folder}'", file=sys.stderr)

    sample_ids = all_ids[-sample_size:]
    if verbose:
        print(f"  Sampling {len(sample_ids)} most recent messages", file=sys.stderr)

    messages = []
    for msg_id in sample_ids:
        status, msg_data = conn.fetch(msg_id, "(RFC822)")
        if status != "OK":
            continue
        msg = _parse_fetched_message(msg_id, msg_data, verbose)
        if msg is not None:
            messages.append(msg)

    return messages


# ---------------------------------------------------------------------------
# Text extraction
# ---------------------------------------------------------------------------

def _safe_get_content(part) -> str:
    """Safely extract content from a MIME part, returning '' on decode errors."""
    try:
        return part.get_content()
    except (KeyError, LookupError, UnicodeDecodeError):
        return ""


def _get_plain_from_multipart(msg) -> str:
    """Find and return the first text/plain part in a multipart message."""
    for part in msg.walk():
        if part.get_content_type() == "text/plain":
            content = _safe_get_content(part)
            if content:
                return content
    return ""


def get_plain_body(msg) -> str:
    """Extract plain text body from an email message."""
    if msg.is_multipart():
        return _get_plain_from_multipart(msg)
    if msg.get_content_type() == "text/plain":
        return _safe_get_content(msg)
    return ""


_ATTRIBUTION_RE = re.compile(r"^On .+wrote:\s*$", re.DOTALL)
_ORIGINAL_MSG_RE = re.compile(r"^-{3,}\s*(Original|Forwarded)\s+(Message|message)\s*-{3,}")


def _is_quote_start(stripped: str) -> bool:
    """Return True if the line starts a quoted block."""
    if stripped.startswith(">"):
        return True
    if _ATTRIBUTION_RE.match(stripped):
        return True
    if _ORIGINAL_MSG_RE.match(stripped):
        return True
    return False


class _StripState:
    """Mutable state for the strip_quoted_content line processor."""
    __slots__ = ('in_signature', 'in_quoted_block')

    def __init__(self):
        self.in_signature = False
        self.in_quoted_block = False


def _process_strip_line(line: str, state: _StripState, result: list) -> None:
    """Process one line through the quote-stripping state machine."""
    stripped = line.strip()

    if stripped == "--":
        state.in_signature = True
        return
    if state.in_signature:
        return

    if _is_quote_start(stripped):
        state.in_quoted_block = True
        return

    if state.in_quoted_block and stripped:
        state.in_quoted_block = False

    if not state.in_quoted_block:
        result.append(line)


def strip_quoted_content(text: str) -> str:
    """Remove quoted reply content, leaving only the user's own words.

    Strips:
    - Lines starting with > (standard quoting)
    - "On ... wrote:" attribution lines
    - "-----Original Message-----" blocks
    - Signature blocks (after --)
    """
    state = _StripState()
    result = []
    for line in text.splitlines():
        _process_strip_line(line, state, result)
    return "\n".join(result)


def extract_greeting(body: str) -> Optional[str]:
    """Extract the greeting line from an email body."""
    lines = [line.strip() for line in body.splitlines() if line.strip()]
    if not lines:
        return None

    # Check first 3 lines for greeting patterns
    for line in lines[:3]:
        line_lower = line.lower()
        for pattern in GREETING_PATTERNS:
            if re.match(pattern, line_lower):
                # Return normalised (first word capitalised, rest as-is)
                return line
    return None


def extract_closing(body: str) -> Optional[str]:
    """Extract the closing line from an email body."""
    lines = [line.strip() for line in body.splitlines() if line.strip()]
    if not lines:
        return None

    # Check last 5 lines for closing patterns
    for line in reversed(lines[-5:]):
        line_lower = line.lower()
        for pattern in CLOSING_PATTERNS:
            if re.match(pattern, line_lower):
                return line
    return None


def count_sentences(text: str) -> int:
    """Count sentences in text using punctuation heuristic."""
    # Split on sentence-ending punctuation followed by space or end
    sentences = re.split(r"[.!?]+(?:\s|$)", text)
    return max(1, len([s for s in sentences if s.strip()]))


def count_words(text: str) -> int:
    """Count words in text."""
    return len(text.split())


def extract_vocabulary(text: str, top_n: int = 50) -> List[Tuple[str, int]]:
    """Extract meaningful word frequencies from text.

    Returns a list of (word, count) tuples sorted by frequency descending.
    """
    # Lowercase, extract words only
    words = re.findall(r"\b[a-z]{3,}\b", text.lower())
    # Filter stop words
    meaningful = [w for w in words if w not in STOP_WORDS]
    return Counter(meaningful).most_common(top_n)


def detect_tone(text: str) -> str:
    """Classify email tone as formal, semi-formal, or casual.

    Heuristic based on:
    - Contractions (casual indicator)
    - Formal phrases
    - Sentence length
    - Punctuation density
    """
    text_lower = text.lower()
    word_count = max(1, count_words(text))

    # Casual indicators
    contractions = len(re.findall(
        r"\b(i'm|i've|i'll|i'd|you're|you've|you'll|don't|doesn't|can't|won't|"
        r"isn't|aren't|wasn't|weren't|haven't|hasn't|hadn't|wouldn't|couldn't|"
        r"shouldn't|let's|that's|it's|there's|here's|we're|they're|he's|she's)\b",
        text_lower
    ))
    casual_phrases = len(re.findall(
        r"\b(hey|hi there|cheers|thanks|yep|nope|yeah|sure|ok|okay|btw|fyi|asap|"
        r"quick|just wanted|just checking|just following|no worries|sounds good|"
        r"totally|absolutely|awesome|great|cool|perfect)\b",
        text_lower
    ))

    # Formal indicators
    formal_phrases = len(re.findall(
        r"\b(dear|sincerely|regards|herewith|pursuant|aforementioned|kindly|"
        r"please find|as per|in accordance|i am writing|i write to|"
        r"please do not hesitate|should you require|at your earliest convenience|"
        r"i trust this|i hope this finds you)\b",
        text_lower
    ))

    casual_score = (contractions + casual_phrases) / word_count * 100
    formal_score = formal_phrases / word_count * 100

    if formal_score > 1.5 and casual_score < 2.0:
        return "formal"
    if casual_score > 3.0 or (casual_score > 1.5 and formal_score < 0.5):
        return "casual"
    return "semi-formal"


def extract_recipient_type(to_header: str, cc_header: str) -> str:
    """Classify recipient type: individual, small-group, or broadcast."""
    to_addrs = [a for _, a in email.utils.getaddresses([to_header or ""])]
    cc_addrs = [a for _, a in email.utils.getaddresses([cc_header or ""])]
    total = len(to_addrs) + len(cc_addrs)

    if total == 1:
        return "individual"
    if total <= 4:
        return "small-group"
    return "broadcast"


# ---------------------------------------------------------------------------
# Analysis aggregation
# ---------------------------------------------------------------------------

def _normalise_phrase(text: str, max_words: int = 4) -> str:
    """Normalise a greeting/closing phrase to a lowercase key."""
    return " ".join(text.split()[:max_words]).rstrip(",.!").lower()


def _has_attachment(msg) -> bool:
    """Check whether an email message has file attachments."""
    if not msg.is_multipart():
        return False
    return any(
        part.get_content_disposition() == "attachment"
        for part in msg.walk()
    )


def _analyse_body(body: str, acc: dict) -> None:
    """Analyse a single email body and update accumulator counters."""
    greeting = extract_greeting(body)
    if greeting:
        acc["has_greeting"] += 1
        acc["greetings"][_normalise_phrase(greeting)] += 1

    closing = extract_closing(body)
    if closing:
        acc["has_closing"] += 1
        acc["closings"][_normalise_phrase(closing)] += 1

    acc["tones"][detect_tone(body)] += 1
    acc["sentence_counts"].append(count_sentences(body))
    acc["word_lengths"].append(count_words(body))
    acc["paragraph_counts"].append(
        max(1, len([p for p in body.split("\n\n") if p.strip()]))
    )

    for word, count in extract_vocabulary(body, top_n=30):
        acc["word_freq"][word] += count


def _analyse_headers(msg, acc: dict) -> None:
    """Analyse email headers and update accumulator counters."""
    to_header = msg.get("To", "")
    cc_header = msg.get("Cc", "")

    acc["recipient_types"][extract_recipient_type(to_header, cc_header)] += 1

    if cc_header:
        acc["uses_cc"] += 1
    if msg.get("Bcc", ""):
        acc["uses_bcc"] += 1
    if msg.get("In-Reply-To", ""):
        acc["reply_count"] += 1
    if _has_attachment(msg):
        acc["has_attachment"] += 1


def _build_accumulator() -> dict:
    """Create a fresh analysis accumulator with zeroed counters."""
    return {
        "greetings": Counter(),
        "closings": Counter(),
        "tones": Counter(),
        "recipient_types": Counter(),
        "word_lengths": [],
        "sentence_counts": [],
        "paragraph_counts": [],
        "word_freq": Counter(),
        "has_greeting": 0,
        "has_closing": 0,
        "uses_cc": 0,
        "uses_bcc": 0,
        "has_attachment": 0,
        "reply_count": 0,
        "total_analysed": 0,
    }


def _compute_results(acc: dict) -> dict:
    """Compute final statistics from the accumulator."""
    total = acc["total_analysed"]
    wl = acc["word_lengths"]
    sc = acc["sentence_counts"]
    pc = acc["paragraph_counts"]

    return {
        "total_analysed": total,
        "greetings": dict(acc["greetings"].most_common(10)),
        "closings": dict(acc["closings"].most_common(10)),
        "has_greeting_pct": round(acc["has_greeting"] / total * 100),
        "has_closing_pct": round(acc["has_closing"] / total * 100),
        "tones": dict(acc["tones"]),
        "dominant_tone": (
            acc["tones"].most_common(1)[0][0] if acc["tones"] else "unknown"
        ),
        "recipient_types": dict(acc["recipient_types"]),
        "avg_words_per_email": round(statistics.mean(wl) if wl else 0),
        "median_words_per_email": round(statistics.median(wl) if wl else 0),
        "avg_sentences_per_email": round(
            statistics.mean(sc) if sc else 0, 1,
        ),
        "avg_paragraphs_per_email": round(
            statistics.mean(pc) if pc else 0, 1,
        ),
        "uses_cc_pct": round(acc["uses_cc"] / total * 100),
        "uses_bcc_pct": round(acc["uses_bcc"] / total * 100),
        "reply_pct": round(acc["reply_count"] / total * 100),
        "attachment_pct": round(acc["has_attachment"] / total * 100),
        "top_vocabulary": [w for w, _ in acc["word_freq"].most_common(40)],
    }


def analyse_emails(messages: list, verbose: bool = False) -> dict:
    """Analyse a list of email messages and return aggregated pattern data.

    Returns a dict with all extracted patterns. No raw email content is
    included — only frequencies, distributions, and anonymised examples.
    """
    acc = _build_accumulator()

    for msg in messages:
        body_raw = get_plain_body(msg)
        if not body_raw or len(body_raw.strip()) < 20:
            continue

        body = strip_quoted_content(body_raw)
        if not body.strip():
            continue

        acc["total_analysed"] += 1
        _analyse_body(body, acc)
        _analyse_headers(msg, acc)

        if verbose and acc["total_analysed"] % 10 == 0:
            print(
                f"  Analysed {acc['total_analysed']}/{len(messages)} emails...",
                file=sys.stderr,
            )

    if acc["total_analysed"] == 0:
        return {}

    return _compute_results(acc)


# ---------------------------------------------------------------------------
# AI synthesis (optional, uses anthropic SDK)
# ---------------------------------------------------------------------------

def synthesise_with_ai(analysis: dict) -> Optional[str]:
    """Use Claude (sonnet) to synthesise analysis data into a narrative style guide.

    Returns the synthesised markdown string, or None if AI is unavailable.
    Requires ANTHROPIC_API_KEY env var.
    """
    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        return None

    try:
        import anthropic
    except ImportError:
        print("WARNING: anthropic package not installed. Skipping AI synthesis.", file=sys.stderr)
        print("  Install: pip install anthropic", file=sys.stderr)
        return None

    client = anthropic.Anthropic(api_key=api_key)

    prompt = f"""You are analysing writing pattern data extracted from a person's sent email folder.
Your task: synthesise this statistical data into a concise, actionable writing style guide.

The style guide will be used by an AI email composition assistant to write emails that sound
like this person — not generic AI. Focus on what makes their voice distinctive.

ANALYSIS DATA (from {analysis['total_analysed']} sent emails):

Greeting patterns (phrase: count):
{json.dumps(analysis.get('greetings', {}), indent=2)}
Uses greeting: {analysis.get('has_greeting_pct', 0)}% of emails

Closing patterns (phrase: count):
{json.dumps(analysis.get('closings', {}), indent=2)}
Uses closing: {analysis.get('has_closing_pct', 0)}% of emails

Tone distribution:
{json.dumps(analysis.get('tones', {}), indent=2)}
Dominant tone: {analysis.get('dominant_tone', 'unknown')}

Email length:
- Average words: {analysis.get('avg_words_per_email', 0)}
- Median words: {analysis.get('median_words_per_email', 0)}
- Average sentences: {analysis.get('avg_sentences_per_email', 0)}
- Average paragraphs: {analysis.get('avg_paragraphs_per_email', 0)}

Recipient patterns:
{json.dumps(analysis.get('recipient_types', {}), indent=2)}
Uses CC: {analysis.get('uses_cc_pct', 0)}% | Uses BCC: {analysis.get('uses_bcc_pct', 0)}%
Replies (vs new): {analysis.get('reply_pct', 0)}%
Includes attachments: {analysis.get('attachment_pct', 0)}%

Frequent vocabulary (distinctive words, stop words removed):
{', '.join(analysis.get('top_vocabulary', [])[:30])}

Write a concise markdown style guide with these sections:
1. **Voice Summary** (2-3 sentences capturing the overall writing style)
2. **Greetings** (how they open emails, with examples)
3. **Closings** (how they close emails, with examples)
4. **Tone & Register** (formal/casual balance, when each is used)
5. **Email Length** (typical length, paragraph structure)
6. **Vocabulary Preferences** (characteristic words/phrases to use and avoid)
7. **Structural Patterns** (CC habits, reply style, attachment patterns)
8. **Composition Rules** (5-7 specific rules for the AI to follow)

Keep it concise — this is a reference card, not an essay. Use bullet points.
Do NOT include any personal information, email addresses, or raw email content.
"""

    try:
        response = client.messages.create(
            model="claude-sonnet-4-5",
            max_tokens=2000,
            messages=[{"role": "user", "content": prompt}],
        )
        return response.content[0].text
    except (anthropic.APIError, anthropic.APIConnectionError, KeyError, IndexError) as exc:
        print(f"WARNING: AI synthesis failed: {exc}", file=sys.stderr)
        return None


# ---------------------------------------------------------------------------
# Profile generation
# ---------------------------------------------------------------------------

def _phrase_table(title: str, data: dict, pct_key: str, analysis: dict) -> List[str]:
    """Build a markdown table section for greeting/closing patterns."""
    lines = [
        f"### {title} Patterns",
        "",
        f"Uses {title.lower()}: **{analysis.get(pct_key, 0)}%** of emails",
        "",
    ]
    if data:
        header_label = title
        lines.append(f"| {header_label} | Count |")
        lines.append(f"|{'─' * (len(header_label) + 2)}|-------|")
        for phrase, count in sorted(data.items(), key=lambda x: -x[1]):
            lines.append(f"| {phrase} | {count} |")
    else:
        lines.append(f"*No consistent {title.lower()} pattern detected.*")
    lines.append("")
    return lines


def _tone_section(analysis: dict) -> List[str]:
    """Build the tone distribution section."""
    lines = ["### Tone Distribution", ""]
    tones = analysis.get("tones", {})
    total = sum(tones.values()) or 1
    for tone, count in sorted(tones.items(), key=lambda x: -x[1]):
        pct = round(count / total * 100)
        lines.append(f"- **{tone.title()}**: {pct}% ({count} emails)")
    lines.append("")
    return lines


def _length_section(analysis: dict) -> List[str]:
    """Build the email length statistics section."""
    return [
        "### Email Length",
        "",
        f"- Average words: **{analysis.get('avg_words_per_email', 0)}**",
        f"- Median words: **{analysis.get('median_words_per_email', 0)}**",
        f"- Average sentences: **{analysis.get('avg_sentences_per_email', 0)}**",
        f"- Average paragraphs: **{analysis.get('avg_paragraphs_per_email', 0)}**",
        "",
    ]


def _recipient_section(analysis: dict) -> List[str]:
    """Build the recipient and structural patterns section."""
    lines = ["### Recipient & Structural Patterns", ""]
    rtypes = analysis.get("recipient_types", {})
    rtotal = sum(rtypes.values()) or 1
    for rtype, count in sorted(rtypes.items(), key=lambda x: -x[1]):
        pct = round(count / rtotal * 100)
        lines.append(f"- **{rtype.title()}** recipients: {pct}%")
    lines.extend([
        f"- Uses CC: **{analysis.get('uses_cc_pct', 0)}%**",
        f"- Uses BCC: **{analysis.get('uses_bcc_pct', 0)}%**",
        f"- Replies (vs new threads): **{analysis.get('reply_pct', 0)}%**",
        f"- Includes attachments: **{analysis.get('attachment_pct', 0)}%**",
        "",
    ])
    return lines


def _vocabulary_section(analysis: dict) -> List[str]:
    """Build the vocabulary preferences section."""
    lines = ["### Vocabulary Preferences", ""]
    vocab = analysis.get("top_vocabulary", [])
    if vocab:
        lines.append("Frequently used distinctive words:")
        lines.append("")
        lines.append(", ".join(f"`{w}`" for w in vocab[:30]))
    else:
        lines.append("*No distinctive vocabulary patterns detected.*")
    lines.append("")
    return lines


def generate_profile_markdown(
    analysis: dict, account: str, ai_synthesis: Optional[str],
) -> str:
    """Generate the voice profile markdown document."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    total_emails = analysis.get("total_analysed", 0)

    lines = [
        f"# Voice Profile: {account}",
        "",
        f"*Generated: {now} | Analysed: {total_emails} sent emails*",
        "",
        "> **Privacy note**: This profile contains extracted patterns only.",
        "> No raw email content, addresses, or subject lines are stored here.",
        "",
        "---",
        "",
    ]

    if ai_synthesis:
        lines.extend([
            "## AI-Synthesised Style Guide", "",
            ai_synthesis, "",
            "---", "",
            "## Raw Pattern Data", "",
            "*Source data used for the style guide above.*", "",
        ])
    else:
        lines.extend([
            "## Writing Patterns", "",
            "> AI synthesis unavailable (set ANTHROPIC_API_KEY to enable). "
            "Raw pattern data below.", "",
        ])

    lines.extend(_phrase_table(
        "Greeting", analysis.get("greetings", {}),
        "has_greeting_pct", analysis,
    ))
    lines.extend(_phrase_table(
        "Closing", analysis.get("closings", {}),
        "has_closing_pct", analysis,
    ))
    lines.extend(_tone_section(analysis))
    lines.extend(_length_section(analysis))
    lines.extend(_recipient_section(analysis))
    lines.extend(_vocabulary_section(analysis))

    return "\n".join(lines)


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
