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
import sys
from pathlib import Path

from email_shared import (
    check_ollama,
    extract_body,
    extract_frontmatter,
    yaml_escape,
)

# Re-export public surface from decomposed module for backwards compatibility
from email_summary_heuristic import (  # noqa: F401
    WORD_COUNT_THRESHOLD,
    SHORT_EMAIL_THRESHOLD,
    MAX_DESCRIPTION_LEN,
    OLLAMA_MAX_CHARS,
    _strip_markdown,
    _strip_signature,
    _clean_for_description,
    _word_count,
    word_count,
    summarise_heuristic,
    summarise_ollama,
    _parse_summary_response,
    _clean_llm_summary,
)


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
    if check_ollama():
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
            escaped = _yaml_escape(summary)
            new_fm_lines.append(f"description: {escaped}")
            replaced = True
        else:
            new_fm_lines.append(line)

    if not replaced:
        insert_idx = 0
        for i, line in enumerate(new_fm_lines):
            if line.startswith("title:"):
                insert_idx = i + 1
                break
        escaped = _yaml_escape(summary)
        new_fm_lines.insert(insert_idx, f"description: {escaped}")

    new_fm = "\n".join(new_fm_lines)
    new_content = f"---\n{new_fm}\n---{body_with_newlines}"

    path.write_text(new_content, encoding="utf-8")
    return True


def update_frontmatter_description(file_path: str, description: str) -> bool:
    """Update a markdown file's YAML frontmatter description field.

    Returns True if the file was modified.
    """
    path = Path(file_path)
    content = path.read_text(encoding="utf-8")

    opener, fm_content, body = extract_frontmatter(content)
    if not opener:
        print(f"WARNING: No YAML frontmatter in {file_path}", file=sys.stderr)
        return False

    fm_lines = fm_content.split("\n")
    new_fm_lines = []
    replaced = False
    for line in fm_lines:
        if line.startswith("description:"):
            new_fm_lines.append(f"description: {_yaml_escape(description)}")
            replaced = True
        else:
            new_fm_lines.append(line)

    if not replaced:
        insert_idx = 0
        for i, line in enumerate(new_fm_lines):
            if line.startswith("title:"):
                insert_idx = i + 1
                break
        new_fm_lines.insert(insert_idx,
                            f"description: {_yaml_escape(description)}")

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
        help="Summarisation method (default: auto -- word-count decides)"
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
