#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_summary_heuristic.py - Text cleaning, heuristic summariser, and Ollama interface.

Extracted from email-summary.py to reduce file-level complexity.
Provides markdown stripping, signature removal, sentence extraction,
and LLM-based summarisation via Ollama.
"""

from __future__ import annotations

import re
import subprocess
import sys
from typing import Optional

from email_shared import check_ollama, get_ollama_model


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Emails with this many words or fewer use the heuristic summariser
WORD_COUNT_THRESHOLD = 100

# Alias used by feature branch code
SHORT_EMAIL_THRESHOLD = WORD_COUNT_THRESHOLD

# Maximum description length in characters
MAX_DESCRIPTION_LEN = 300

# Maximum text sent to Ollama (chars) to avoid context overflow
OLLAMA_MAX_CHARS = 6000


# ---------------------------------------------------------------------------
# Text cleaning
# ---------------------------------------------------------------------------

def _strip_markdown(text: str) -> str:
    """Strip markdown formatting from text for summarisation input."""
    # Remove images
    text = re.sub(r'!\[([^\]]*)\]\([^)]*\)', r'\1', text)
    # Remove links but keep text
    text = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', text)
    # Remove emphasis markers
    text = re.sub(r'[*_]{1,3}', '', text)
    # Remove headings markers
    text = re.sub(r'^#{1,6}\s+', '', text, flags=re.MULTILINE)
    # Remove blockquote markers (email replies)
    text = re.sub(r'^>\s*', '', text, flags=re.MULTILINE)
    # Remove list items
    text = re.sub(r'^[-*+]\s+', '', text, flags=re.MULTILINE)
    # Remove ordered lists
    text = re.sub(r'^\d+\.\s+', '', text, flags=re.MULTILINE)
    # Remove inline code
    text = re.sub(r'`[^`]*`', '', text)
    # Remove code blocks
    text = re.sub(r'```[\s\S]*?```', '', text)
    # Remove horizontal rules
    text = re.sub(r'^[-*_]{3,}\s*$', '', text, flags=re.MULTILINE)
    # Collapse whitespace
    text = re.sub(r'\n{3,}', '\n\n', text)
    return text.strip()


def _strip_signature(text: str) -> str:
    """Remove email signature from text before summarising.

    Detects common signature markers and removes everything after them.
    """
    sig_patterns = [
        r'\n--\s*\n',                          # standard -- delimiter
        r'\n_{3,}\s*\n',                        # ___ underscores
        r'\n-{3,}\s*\n',                        # --- dashes
        r'\nBest regards[,.]?\s*\n',
        r'\nKind regards[,.]?\s*\n',
        r'\nRegards[,.]?\s*\n',
        r'\nThanks[,.]?\s*\n',
        r'\nThank you[,.]?\s*\n',
        r'\nCheers[,.]?\s*\n',
        r'\nSincerely[,.]?\s*\n',
        r'\nSent from my ',
        r'\nGet Outlook for ',
    ]

    for pattern in sig_patterns:
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            before = text[:match.start()].strip()
            if len(before) >= 20 and (len(text) < 500 or match.start() > len(text) * 0.2):
                text = before
                break

    return text


def _clean_for_description(text: str) -> str:
    """Clean text for use as a YAML description value."""
    text = re.sub(r'\s+', ' ', text).strip()
    return text


def _word_count(text: str) -> int:
    """Count words in text."""
    if not text:
        return 0
    return len(text.split())


# Public alias for compatibility
word_count = _word_count


# ---------------------------------------------------------------------------
# Heuristic summariser (short emails)
# ---------------------------------------------------------------------------

_GREETING_PATTERN = re.compile(
    r'^(hi|hello|hey|dear|good\s+(morning|afternoon|evening))\b',
    re.IGNORECASE,
)
_LIST_ITEM_PATTERN = re.compile(r'^(\d+[.)]\s+|[-*+]\s+)')
_SIGNATURE_PATTERN = re.compile(
    r'^(--|best\s+regards|kind\s+regards|regards|thanks|cheers|sincerely)',
    re.IGNORECASE,
)

_SENTENCE_END = re.compile(
    r'(?<!Mr)(?<!Mrs)(?<!Ms)(?<!Dr)(?<!Prof)(?<!Inc)(?<!Ltd)(?<!Corp)'
    r'(?<!Jr)(?<!Sr)(?<!vs)(?<!etc)(?<!e\.g)(?<!i\.e)'
    r'[.!?]\s+(?=[A-Z])',
    re.MULTILINE,
)


def _filter_meaningful_lines(text: str) -> list[str]:
    """Filter text lines to meaningful content, skipping greetings/lists/signatures."""
    meaningful = []
    for line in text.split('\n'):
        stripped = line.strip()
        if not stripped:
            continue
        if _GREETING_PATTERN.match(stripped):
            continue
        if _LIST_ITEM_PATTERN.match(stripped):
            continue
        if _SIGNATURE_PATTERN.match(stripped):
            break
        meaningful.append(stripped)
    return meaningful


def _split_sentences(text_block: str, max_sentences: int) -> list[str]:
    """Split text into sentences using abbreviation-aware boundary detection."""
    result_sentences = []
    start = 0
    for match in _SENTENCE_END.finditer(text_block):
        end = match.end()
        sentence = text_block[start:end].strip()
        if sentence:
            result_sentences.append(sentence)
        if len(result_sentences) >= max_sentences:
            break
        start = end

    if len(result_sentences) < max_sentences:
        remaining = text_block[start:].strip()
        if remaining:
            result_sentences.append(remaining)

    return result_sentences


def _truncate_to_limit(text: str, limit: int) -> str:
    """Truncate text at word boundary with ellipsis if over limit."""
    if len(text) <= limit:
        return text
    truncated = text[:limit].rsplit(' ', 1)[0]
    if not truncated.endswith(('.', '!', '?')):
        truncated += '...'
    return truncated


def _extract_first_sentences(text: str, max_sentences: int = 2) -> str:
    """Extract the first N meaningful sentences from text."""
    meaningful_lines = _filter_meaningful_lines(text)
    text_block = ' '.join(meaningful_lines)
    result_sentences = _split_sentences(text_block, max_sentences)
    result = ' '.join(result_sentences)
    return _truncate_to_limit(result, MAX_DESCRIPTION_LEN)


def summarise_heuristic(body: str) -> str:
    """Generate a summary using extractive heuristic (first meaningful sentences)."""
    if not body:
        return ""
    text = _strip_signature(body)
    cleaned = _strip_markdown(text)
    if not cleaned:
        return ""

    summary = _extract_first_sentences(cleaned, max_sentences=2)
    summary = _clean_for_description(summary)

    if len(summary) > MAX_DESCRIPTION_LEN:
        summary = summary[:MAX_DESCRIPTION_LEN].rsplit(' ', 1)[0] + '...'

    return summary


# ---------------------------------------------------------------------------
# Ollama LLM summariser (long emails)
# ---------------------------------------------------------------------------

_OLLAMA_SUMMARY_PROMPT = """Summarise the following email in 1-2 sentences. The summary should:
- Capture the main purpose/action of the email
- Be written in third person (e.g. "Sender requests..." not "I request...")
- Be concise (under 200 characters)
- Not include greetings, signatures, or pleasantries
- Not start with "This email" or "The email"

Return ONLY the summary text, no quotes, no labels, no explanation.

Email:
{text}

Summary:"""


# Ollama availability: delegated to email_shared
_check_ollama = check_ollama
_get_ollama_model = get_ollama_model


def _parse_summary_response(response: str) -> str:
    """Clean up LLM summary response."""
    text = response.strip()

    if text.startswith('"') and text.endswith('"'):
        text = text[1:-1]
    if text.startswith("'") and text.endswith("'"):
        text = text[1:-1]

    preambles = [
        "Here is a summary:",
        "Here's a summary:",
        "Summary:",
        "Here is the summary:",
        "Here's the summary:",
    ]
    for preamble in preambles:
        if text.lower().startswith(preamble.lower()):
            text = text[len(preamble):].strip()

    text = re.sub(r'```.*?```', '', text, flags=re.DOTALL)
    text = re.sub(r'^(?:summary|here\s+is|the\s+email)\s*[:]\s*',
                  '', text, flags=re.IGNORECASE)
    text = text.strip('"\'')
    text = re.sub(r'\s+', ' ', text).strip()

    if len(text) > MAX_DESCRIPTION_LEN:
        text = text[:MAX_DESCRIPTION_LEN].rsplit(' ', 1)[0]
        if not text.endswith(('.', '!', '?')):
            text += '...'

    return text


# Keep legacy alias
_clean_llm_summary = _parse_summary_response


def _prepare_ollama_input(body: str) -> Optional[str]:
    """Prepare cleaned and truncated text for Ollama. Returns None if empty."""
    text = _strip_signature(body)
    cleaned = _strip_markdown(text)
    if not cleaned:
        return None
    if len(cleaned) > OLLAMA_MAX_CHARS:
        cleaned = cleaned[:OLLAMA_MAX_CHARS] + "\n[... truncated ...]"
    return cleaned


def _run_ollama(model: str, prompt: str) -> str:
    """Run Ollama and return parsed response, or empty string on failure."""
    try:
        result = subprocess.run(
            ["ollama", "run", model, prompt],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0:
            print(f"WARNING: Ollama summarisation failed: {result.stderr}",
                  file=sys.stderr)
            return ""
        return _parse_summary_response(result.stdout)
    except subprocess.TimeoutExpired:
        print("WARNING: Ollama summarisation timed out (60s)", file=sys.stderr)
        return ""
    except FileNotFoundError:
        return ""


def summarise_ollama(body: str) -> str:
    """Generate a summary using Ollama LLM.

    Returns a 1-2 sentence summary string, or empty string on failure.
    """
    model = _get_ollama_model()
    if model is None:
        return ""

    cleaned = _prepare_ollama_input(body)
    if not cleaned:
        return ""

    prompt = _OLLAMA_SUMMARY_PROMPT.format(text=cleaned)
    return _run_ollama(model, prompt)
