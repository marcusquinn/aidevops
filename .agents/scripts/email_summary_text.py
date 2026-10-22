# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Text preparation shared by heuristic and Ollama email summarisation."""

import re


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


word_count = _word_count
