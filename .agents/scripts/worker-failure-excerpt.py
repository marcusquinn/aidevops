#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Write capped local failure evidence with a selected, redacted blocker."""

import json
import os
import re
import sys
from pathlib import Path

LIMIT = 65536
BLOCKER_LIMIT = 2048
MARKER = "[WORKER_BLOCKER_EVIDENCE] "


def scrub(text):
    """Redact before truncation, including JSON-escaped paths and credentials."""
    text = re.sub(r"-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----",
                  "[redacted-private-key]", text, flags=re.S)
    # Same token prefixes/boundary as shared-constants.sh::scrub_credentials.
    text = re.sub(r"(?<![\w-])(?:sk-|GOCSPX-|gh[pous]_|github_pat_|glpat-|xox[bp]-)[\w-]{10,}",
                  "[redacted-credential]", text)
    text = re.sub(r"(?i)\b(?:Bearer|Basic)\s+[^\s\"'\\,;]+", "[redacted-authorization]", text)
    text = re.sub(r"(?i)([\"']?(?:password|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|token)[\"']?\s*[:=]\s*)[^\s,;]+",
                  r"\1[redacted-credential]", text)
    text = re.sub(r"\beyJ[\w-]+\.[\w-]+\.[\w-]+", "[redacted-jwt]", text)
    text = re.sub(r"https?://[^\s\"'<>\\]+", "[redacted-url]", text)
    text = re.sub(r"(?<!\w)(?:/[\w.~/-]+|[A-Za-z]:[\\/][^\s\"'<>]+)", "[redacted-path]", text)
    return text


def blocker_text(raw):
    """Match the terminal assistant text boundary, never tool output."""
    final_text = ""
    structured = False
    for line in raw.splitlines():
        try:
            event = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(event, dict):
            continue
        structured = True
        if event.get("type") == "text":
            part = event.get("part")
            part = part if isinstance(part, dict) else {}
            value = event.get("text") or part.get("text")
            if isinstance(value, str) and value:
                final_text = value
    # OpenCode emits completed assistant text as type=text (no role field).
    # Tool output remains nested in other event types and is never selected.
    candidate = final_text if structured else raw
    match = re.search(r"(?:^|\n)\s*BLOCKED(?:\s*:|\s*$)", candidate, re.I)
    if match:
        return " ".join(scrub(candidate[match.start():]).split())
    return ""


def scrub_value(value):
    """Decode structured strings before redaction, including Unicode escapes."""
    if isinstance(value, str):
        return scrub(value)
    if isinstance(value, list):
        return [scrub_value(item) for item in value]
    if isinstance(value, dict):
        return {
            scrub(key): "[redacted-credential]" if re.search(
                r"(?i)password|secret|token|api[_-]?key|authorization", key
            ) else scrub_value(item)
            for key, item in value.items()
        }
    return value


def scrub_output(raw):
    lines = []
    for line in raw.splitlines(keepends=True):
        try:
            value = json.loads(line)
        except (ValueError, TypeError):
            lines.append(line)
        else:
            lines.append(json.dumps(scrub_value(value), ensure_ascii=False) + "\n")
    return scrub("".join(lines))


def write_excerpt(source, destination):
    raw = Path(source).read_text(errors="replace")
    blocker = blocker_text(raw)
    summary = ("\n" + MARKER + blocker).encode()[:BLOCKER_LIMIT] + b"\n" if blocker else b""
    # Redact the complete input before slicing, so a cut token cannot escape.
    tail = scrub_output(raw).encode()[-(LIMIT - len(summary)):]
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as output:
        output.write(tail + summary)


if __name__ == "__main__":
    try:
        write_excerpt(sys.argv[1], sys.argv[2])
    except (OSError, ValueError):
        sys.exit(1)
