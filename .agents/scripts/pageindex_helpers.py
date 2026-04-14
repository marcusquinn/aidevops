#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
pageindex_helpers.py - Summary extraction helpers for pageindex-generator.py.

Extracted to reduce file-level complexity below the qlty maintainability threshold.
"""

import re
import json
from typing import Optional


def extract_first_sentence(text: str) -> str:
    """Extract the first meaningful sentence from text."""
    # Strip markdown formatting
    text = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', text)  # links
    text = re.sub(r'[*_`~]+', '', text)  # emphasis
    text = text.strip()

    if not text:
        return ""

    # Find first sentence boundary
    match = re.match(r'^(.+?[.!?])\s', text)
    if match:
        sentence = match.group(1).strip()
        if len(sentence) > 200:
            return sentence[:197] + '...'
        return sentence

    # No sentence boundary — use first line, capped
    first_line = text.split('\n')[0].strip()
    if len(first_line) > 200:
        return first_line[:197] + '...'
    return first_line


def get_ollama_summary(text: str, model: str) -> Optional[str]:
    """Get a one-sentence summary from Ollama. Returns None on failure."""
    import urllib.request
    import urllib.error

    if len(text) > 2000:
        text = text[:2000] + '...'

    prompt = (
        "Summarise the following section in exactly one concise sentence "
        "(max 150 characters). Return ONLY the summary sentence, nothing else.\n\n"
        + text
    )

    payload = json.dumps({
        "model": model,
        "prompt": prompt,
        "stream": False,
        "options": {"temperature": 0.1, "num_predict": 80},
    }).encode('utf-8')

    req = urllib.request.Request(
        'http://localhost:11434/api/generate',
        data=payload,
        headers={'Content-Type': 'application/json'},
    )

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read().decode('utf-8'))
            summary = result.get('response', '').strip()
            summary = summary.strip('"\'')
            match = re.match(r'^(.+?[.!?])', summary)
            if match:
                return match.group(1)
            return summary if summary else None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return None
