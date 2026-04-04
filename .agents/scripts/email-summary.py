#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Auto-summary generation for converted email markdown files (t1053.7).

Generates 1-2 sentence summaries for email bodies, stored in the frontmatter
`description:` field. Uses a word-count heuristic to decide the approach:
- Short emails (<=100 words): extractive heuristic (first meaningful sentence)
- Long emails (>100 words): LLM summarisation via Ollama

Usage:
    email-summary.py <markdown-file> [--method auto|heuristic|ollama]
    email-summary.py --update-frontmatter <markdown-file>

Part of aidevops framework: https://aidevops.sh
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Optional

from email_shared import (
    check_ollama,
    extract_body,
    extract_frontmatter,
    get_ollama_model,
    yaml_escape,
)


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
    # Common signature delimiters (ordered by specificity)
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
            # Strip signature if there's meaningful content before it (>20 chars)
            # and the signature isn't in the very first 20% of a long text
            # (which would indicate it's part of the content, not a sign-off)
            if len(before) >= 20 and (len(text) < 500 or match.start() > len(text) * 0.2):
                text = before
                break

    return text


def _clean_for_description(text: str) -> str:
    """Clean text for use as a YAML description value."""
    # Collapse all whitespace to single spaces
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
    """Extract the first N meaningful sentences from text.

    Skips greeting lines (Hi, Hello, Dear) and empty lines.
    Uses a sentence boundary detector that handles common
    abbreviations (Mr., Dr., etc.) and decimal numbers.
    """
    meaningful_lines = _filter_meaningful_lines(text)
    text_block = ' '.join(meaningful_lines)
    result_sentences = _split_sentences(text_block, max_sentences)
    result = ' '.join(result_sentences)
    return _truncate_to_limit(result, MAX_DESCRIPTION_LEN)


def summarise_heuristic(body: str) -> str:
    """Generate a summary using extractive heuristic (first meaningful sentences).

    Suitable for short emails where the first sentences capture the intent.
    Strategy:
    1. Strip email signature
    2. Strip markdown formatting
    3. Extract the first 1-2 sentences
    4. Truncate to MAX_DESCRIPTION_LEN if needed
    """
    if not body:
        return ""
    text = _strip_signature(body)
    cleaned = _strip_markdown(text)
    if not cleaned:
        return ""

    summary = _extract_first_sentences(cleaned, max_sentences=2)
    summary = _clean_for_description(summary)

    # Truncate if still too long
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
    # Remove any markdown formatting the LLM might add
    text = response.strip()

    # Remove quotes if the LLM wrapped the summary in them
    if text.startswith('"') and text.endswith('"'):
        text = text[1:-1]
    if text.startswith("'") and text.endswith("'"):
        text = text[1:-1]

    # Remove common LLM preambles
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

    # Remove markdown code blocks
    text = re.sub(r'```.*?```', '', text, flags=re.DOTALL)

    # Remove leading labels like "Summary:" or "Here is..."
    text = re.sub(r'^(?:summary|here\s+is|the\s+email)\s*[:]\s*',
                  '', text, flags=re.IGNORECASE)

    # Remove surrounding quotes
    text = text.strip('"\'')

    # Collapse whitespace
    text = re.sub(r'\s+', ' ', text).strip()

    # Truncate if too long
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
    Caller should fall back to heuristic if this returns empty.
    """
    model = _get_ollama_model()
    if model is None:
        return ""

    cleaned = _prepare_ollama_input(body)
    if not cleaned:
        return ""

    prompt = _OLLAMA_SUMMARY_PROMPT.format(text=cleaned)
    return _run_ollama(model, prompt)


# ---------------------------------------------------------------------------
# Main summarisation orchestrator
# ---------------------------------------------------------------------------

def _summarise_with_ollama_fallback(body: str, wc: int = 0) -> str:
    """Try Ollama summarisation, fall back to heuristic on failure."""
    summary = summarise_ollama(body)
    if summary:
        return summary
    if wc > 0:
        print(f"INFO: Using heuristic summary for {wc}-word email "
              f"(Ollama unavailable)", file=sys.stderr)
    return summarise_heuristic(body)


def _generate_auto_summary(body: str) -> str:
    """Auto-select summarisation method based on word count."""
    cleaned = _strip_markdown(body)
    wc = _word_count(cleaned)

    if wc <= WORD_COUNT_THRESHOLD:
        return summarise_heuristic(body)

    # Long email: try Ollama if available, fall back to heuristic
    if _check_ollama():
        return _summarise_with_ollama_fallback(body, wc)

    print(f"INFO: Using heuristic summary for {wc}-word email "
          f"(Ollama unavailable)", file=sys.stderr)
    return summarise_heuristic(body)


_SUMMARY_METHODS = {
    "heuristic": summarise_heuristic,
    "ollama": _summarise_with_ollama_fallback,
    "auto": _generate_auto_summary,
}


def generate_summary(body: str, method: str = "auto") -> str:
    """Generate a 1-2 sentence summary for an email body.

    Args:
        body: The email body text (markdown).
        method: 'auto' (word-count heuristic decides), 'heuristic', or 'ollama'.

    Returns:
        A 1-2 sentence summary string suitable for frontmatter description.
    """
    if not body or not body.strip():
        return ""

    handler = _SUMMARY_METHODS.get(method, _generate_auto_summary)
    return handler(body)


# ---------------------------------------------------------------------------
# YAML frontmatter helpers
# ---------------------------------------------------------------------------

# YAML escaping: delegated to email_shared
_yaml_escape = yaml_escape


def update_description(file_path: str, method: str = "auto") -> bool:
    """Update a markdown file's frontmatter description: field with auto-summary.

    Returns True if the file was modified.
    """
    path = Path(file_path)
    content = path.read_text(encoding="utf-8")

    opener, fm_content, body_with_newlines = extract_frontmatter(content)
    if not opener:
        print(f"WARNING: No YAML frontmatter in {file_path}", file=sys.stderr)
        return False

    body = extract_body(content)
    summary = generate_summary(body, method=method)

    if not summary:
        return False

    # Replace existing description: line in frontmatter
    fm_lines = fm_content.split("\n")
    new_fm_lines = []
    replaced = False
    for line in fm_lines:
        if line.startswith("description:"):
            # Escape for YAML
            escaped = _yaml_escape(summary)
            new_fm_lines.append(f"description: {escaped}")
            replaced = True
        else:
            new_fm_lines.append(line)

    if not replaced:
        # Add description after title if it exists, otherwise at the start
        insert_idx = 0
        for i, line in enumerate(new_fm_lines):
            if line.startswith("title:"):
                insert_idx = i + 1
                break
        escaped = _yaml_escape(summary)
        new_fm_lines.insert(insert_idx, f"description: {escaped}")

    # Rebuild the file
    new_fm = "\n".join(new_fm_lines)
    new_content = f"---\n{new_fm}\n---{body_with_newlines}"

    path.write_text(new_content, encoding="utf-8")
    return True


def update_frontmatter_description(file_path: str, description: str) -> bool:
    """Update a markdown file's YAML frontmatter description field.

    Replaces the existing `description:` value with the new summary.
    Returns True if the file was modified.
    """
    path = Path(file_path)
    content = path.read_text(encoding="utf-8")

    opener, fm_content, body = extract_frontmatter(content)
    if not opener:
        print(f"WARNING: No YAML frontmatter in {file_path}", file=sys.stderr)
        return False

    # Replace existing description line
    fm_lines = fm_content.split("\n")
    new_fm_lines = []
    replaced = False
    for line in fm_lines:
        if line.startswith("description:"):
            new_fm_lines.append(f"description: {_yaml_escape(description)}")
            replaced = True
        else:
            new_fm_lines.append(line)

    # If no description field existed, add it after title
    if not replaced:
        insert_idx = 0
        for i, line in enumerate(new_fm_lines):
            if line.startswith("title:"):
                insert_idx = i + 1
                break
        new_fm_lines.insert(insert_idx,
                            f"description: {_yaml_escape(description)}")

    # Rebuild the file
    new_fm = "\n".join(new_fm_lines)
    new_content = f"---\n{new_fm}\n---{body}"

    path.write_text(new_content, encoding="utf-8")
    return True


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _build_cli_parser() -> argparse.ArgumentParser:
    """Build the CLI argument parser."""
    parser = argparse.ArgumentParser(
        description="Generate auto-summaries for converted email markdown (t1053.7)"
    )
    parser.add_argument("input", help="Input markdown file (with YAML frontmatter)")
    parser.add_argument(
        "--method", choices=["auto", "heuristic", "ollama"],
        default="auto",
        help="Summarisation method (default: auto — word-count decides)"
    )
    parser.add_argument(
        "--update-frontmatter", action="store_true",
        help="Update the file's YAML frontmatter description field"
    )
    parser.add_argument(
        "--json", action="store_true",
        help="Output summary as JSON with metadata"
    )
    return parser


def _handle_update_frontmatter(
    summary: str, input_file: str, method: str, wc: int, method_used: str,
) -> int:
    """Handle --update-frontmatter output mode. Returns exit code."""
    if summary and update_description(input_file, method=method):
        print(f"Updated description in {input_file}")
        print(f"  Words: {wc}, Method: {method_used}")
        print(f"  Summary: {summary[:120]}{'...' if len(summary) > 120 else ''}")
        return 0
    if not summary:
        print(f"No summary generated for {input_file}", file=sys.stderr)
    else:
        print(f"Could not update frontmatter in {input_file}", file=sys.stderr)
    return 1


def _handle_json_output(summary: str, wc: int, method_used: str) -> None:
    """Handle --json output mode."""
    output = {
        "summary": summary,
        "word_count": wc,
        "method": method_used,
        "char_count": len(summary),
    }
    print(json.dumps(output, indent=2, ensure_ascii=False))


def main() -> int:
    """CLI entry point."""
    parser = _build_cli_parser()
    args = parser.parse_args()

    input_path = Path(args.input)
    if not input_path.is_file():
        print(f"ERROR: File not found: {args.input}", file=sys.stderr)
        return 1

    content = input_path.read_text(encoding="utf-8")
    body = extract_body(content)

    if not body.strip():
        print("WARNING: Empty body text, no summary to generate", file=sys.stderr)
        summary = ""
    else:
        summary = generate_summary(body, method=args.method)

    cleaned_body = _strip_markdown(body)
    wc = _word_count(cleaned_body)
    method_used = "heuristic" if wc <= WORD_COUNT_THRESHOLD else "ollama"

    if args.update_frontmatter:
        return _handle_update_frontmatter(summary, args.input, args.method, wc, method_used)
    if args.json:
        _handle_json_output(summary, wc, method_used)
    else:
        print(summary)

    return 0


if __name__ == "__main__":
    sys.exit(main())
