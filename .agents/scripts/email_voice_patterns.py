#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_voice_patterns.py - Text extraction and pattern detection for voice mining.

Extracted from email-voice-miner.py to reduce file-level complexity.
Provides quote stripping, greeting/closing extraction, tone detection,
vocabulary analysis, and recipient classification.
"""

import email.utils
import re
from collections import Counter
from typing import List, Optional, Tuple


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Pattern extraction
# ---------------------------------------------------------------------------

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
    sentences = re.split(r"[.!?]+(?:\s|$)", text)
    return max(1, len([s for s in sentences if s.strip()]))


def count_words(text: str) -> int:
    """Count words in text."""
    return len(text.split())


def extract_vocabulary(text: str, top_n: int = 50) -> List[Tuple[str, int]]:
    """Extract meaningful word frequencies from text.

    Returns a list of (word, count) tuples sorted by frequency descending.
    """
    words = re.findall(r"\b[a-z]{3,}\b", text.lower())
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
