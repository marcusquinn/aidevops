#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Entity extraction from markdown email bodies (t1044.6).

Extracts people, organisations, properties, locations, and dates from
converted markdown content. Uses spaCy NER when available, falls back
to LLM extraction via Ollama.

Usage:
    entity-extraction.py <markdown-file> [--method auto|spacy|ollama]
    entity-extraction.py --update-frontmatter <markdown-file>

Output: JSON dict of entities grouped by type, or updates the file's
YAML frontmatter with an `entities:` field.

Part of aidevops framework: https://aidevops.sh
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Callable

# Add lib directory to path for shared utilities
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'lib'))
from entity_cleaners import (  # noqa: E402,F401
    ENTITY_TYPES,
    SPACY_LABEL_MAP,
    clean_entity,
    extract_entities_regex,
    parse_llm_response,
)
from entity_backends import (  # noqa: E402,F401
    _check_spacy,
    _get_spacy_model,
    extract_entities_ollama,
    extract_entities_spacy,
)
from entity_frontmatter import entities_to_yaml, update_frontmatter  # noqa: E402,F401
from email_shared import (  # noqa: E402,F401
    check_ollama,
    extract_body,
    extract_frontmatter,
    get_ollama_model,
    yaml_escape,
)


# ---------------------------------------------------------------------------
# Main extraction orchestrator
# ---------------------------------------------------------------------------

def _try_auto_extraction(text: str) -> dict[str, list[str]]:
    """Try extraction methods in order of quality: spaCy, Ollama, regex."""
    if _check_spacy() and _get_spacy_model() is not None:
        try:
            result = extract_entities_spacy(text)
            if result:
                return result
        except Exception as e:
            print(f"spaCy extraction failed: {e}", file=sys.stderr)

    if check_ollama():
        try:
            result = extract_entities_ollama(text)
            if result:
                return result
        except Exception as e:
            print(f"Ollama extraction failed: {e}", file=sys.stderr)

    return extract_entities_regex(text)


# Direct method dispatch (excludes 'auto' which uses fallback logic)
_METHOD_DISPATCH: dict[str, Callable[[str], dict[str, list[str]]]] = {
    "spacy": extract_entities_spacy,
    "ollama": extract_entities_ollama,
    "regex": extract_entities_regex,
}


def extract_entities(text: str, method: str = "auto") -> dict[str, list[str]]:
    """Extract entities from text using the specified method."""
    extractor = _METHOD_DISPATCH.get(method)
    if extractor is not None:
        return extractor(text)
    return _try_auto_extraction(text)


# ---------------------------------------------------------------------------
# Frontmatter integration
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _build_arg_parser() -> argparse.ArgumentParser:
    """Build the CLI argument parser."""
    parser = argparse.ArgumentParser(
        description="Extract named entities from markdown email bodies (t1044.6)"
    )
    parser.add_argument("input", help="Input markdown file")
    parser.add_argument(
        "--method", choices=["auto", "spacy", "ollama", "regex"],
        default="auto",
        help="Extraction method (default: auto — tries spaCy, Ollama, regex)"
    )
    parser.add_argument(
        "--update-frontmatter", action="store_true",
        help="Update the file's YAML frontmatter with extracted entities"
    )
    parser.add_argument(
        "--json", action="store_true",
        help="Output entities as JSON (default when not updating frontmatter)"
    )
    return parser


def _format_entity_summary(entities: dict[str, list[str]]) -> str:
    """Format entities as a human-readable summary for logging."""
    if not entities:
        return "  (no entities found)"
    lines = []
    for etype, elist in entities.items():
        summary = ", ".join(elist[:5])
        suffix = f" (+{len(elist) - 5} more)" if len(elist) > 5 else ""
        lines.append(f"  {etype}: {summary}{suffix}")
    return "\n".join(lines)


def main() -> int:
    """CLI entry point."""
    args = _build_arg_parser().parse_args()

    input_path = Path(args.input)
    if not input_path.is_file():
        print(f"ERROR: File not found: {args.input}", file=sys.stderr)
        return 1

    content = input_path.read_text(encoding="utf-8")
    body = extract_body(content)

    if not body.strip():
        print("WARNING: Empty body text, no entities to extract", file=sys.stderr)
        entities: dict[str, list[str]] = {}
    else:
        entities = extract_entities(body, method=args.method)

    if not args.update_frontmatter:
        print(json.dumps(entities, indent=2, ensure_ascii=False))
        return 0

    if not update_frontmatter(args.input, entities):
        print(f"Could not update frontmatter in {args.input}", file=sys.stderr)
        return 1

    print(f"Updated frontmatter in {args.input}")
    print(_format_entity_summary(entities))
    return 0


if __name__ == "__main__":
    sys.exit(main())