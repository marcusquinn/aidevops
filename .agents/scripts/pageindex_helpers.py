#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
pageindex_helpers.py - Summary extraction and Markdoc tag helpers for pageindex-generator.py.

Extracted to reduce file-level complexity below the qlty maintainability threshold.
"""

import re
import json
from typing import Any, Dict, List, Optional


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

    # Ollama runs over HTTP on localhost by design — HTTPS is not supported.
    req = urllib.request.Request(  # nosec B105 nosemgrep: python.lang.security.audit.insecure-transport.urllib.insecure-request-object.insecure-request-object
        'http://localhost:11434/api/generate',
        data=payload,
        headers={'Content-Type': 'application/json'},
    )

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:  # nosec B310 nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected,python_urlopen_rule-urllib-urlopen
            result = json.loads(resp.read().decode('utf-8'))
            summary = result.get('response', '').strip()
            summary = summary.strip('"\'')
            match = re.match(r'^(.+?[.!?])', summary)
            if match:
                return match.group(1)
            return summary if summary else None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return None


def parse_tag_attrs(attrs_string: str) -> Dict[str, Any]:
    """Parse a Markdoc attribute string into a dict.

    Handles quoted strings, single-quoted strings, and bare values.
    Numeric bare values (integer or float) are coerced to Python numbers.

    Examples:
      'tier="privileged" scope="file"' → {'tier': 'privileged', 'scope': 'file'}
      'confidence=0.95'                → {'confidence': 0.95}
    """
    attrs: Dict[str, Any] = {}
    if not attrs_string:
        return attrs
    # Match: key="val"  key='val'  key=bare_val (no spaces/quotes/braces)
    for m in re.finditer(
        r'([\w-]+)\s*=\s*(?:"([^"]*)"|\'([^\']*)\'|([^\s"\'{}]+))',
        attrs_string,
    ):
        key = m.group(1)
        raw: Any
        if m.group(2) is not None:
            raw = m.group(2)
        elif m.group(3) is not None:
            raw = m.group(3)
        else:
            raw = m.group(4) or ''
        # Coerce bare numeric values
        try:
            if '.' in str(raw):
                raw = float(raw)
            else:
                raw = int(str(raw))
        except (ValueError, TypeError):
            pass
        attrs[key] = raw
    return attrs


def extract_markdoc_tags(lines: List[str]) -> List[Dict[str, Any]]:
    """Parse all Markdoc {%...%} tags from a list of lines (0-indexed).

    Returns one record per tag occurrence:
      {
        'tag':          str,   tag name
        'attrs':        dict,  parsed attribute key→value mapping
        'is_close':     bool,  True for {%  /tag %}
        'is_self_close': bool, True for {% tag /%}
        'line_num':     int,   0-indexed line number
      }

    Multi-line tags ({% ... across two lines ... %}) are not supported
    and are silently skipped.  Closing tags have empty attrs dicts.
    """
    records: List[Dict[str, Any]] = []
    for line_num, line in enumerate(lines):
        for inner in _iter_tag_bodies(line):
            record = _parse_tag_body(inner, line_num)
            if record is not None:
                records.append(record)
    return records


_TAG_NAME_RE = re.compile(r'^[a-zA-Z][a-zA-Z0-9_-]*$')


def _iter_tag_bodies(line: str):
    """Yield the text inside each single-line {% ... %} tag on a line."""
    rest = line
    while '{%' in rest:
        rest = rest[rest.index('{%') + 2:]
        if '%}' not in rest:
            return  # Multi-line tag — not supported
        yield rest[:rest.index('%}')]
        rest = rest[rest.index('%}') + 2:]


def _parse_tag_body(inner: str, line_num: int) -> Optional[Dict[str, Any]]:
    """Parse one tag body into a record, or None when it is not a valid tag."""
    inner = inner.strip()
    is_close = inner.startswith('/')
    if is_close:
        inner = inner[1:].strip()

    is_self_close = inner.endswith('/')
    if is_self_close:
        inner = inner[:-1].strip()

    parts = inner.split(None, 1)
    if not parts or not _TAG_NAME_RE.match(parts[0]):
        return None
    attrs_str = parts[1] if len(parts) > 1 else ''

    return {
        'tag': parts[0],
        'attrs': {} if is_close else parse_tag_attrs(attrs_str),
        'is_close': is_close,
        'is_self_close': is_self_close,
        'line_num': line_num,
    }
