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
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import Callable

# Add lib directory to path for shared utilities
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'lib'))
from entity_cleaners import (
    ENTITY_TYPES,
    SPACY_LABEL_MAP,
    clean_entity,
    parse_llm_response,
    extract_entities_regex,
)

from email_shared import (
    check_ollama,
    extract_body,
    extract_frontmatter,
    get_ollama_model,
    yaml_escape,
)


# ---------------------------------------------------------------------------
# spaCy NER extraction
# ---------------------------------------------------------------------------

def _check_spacy() -> bool:
    """Check if spaCy and a model are available."""
    try:
        import spacy  # noqa: F401
        return True
    except ImportError:
        return False


def _get_spacy_model():
    """Load the best available spaCy model."""
    import spacy

    for model_name in ["en_core_web_trf", "en_core_web_lg", "en_core_web_md", "en_core_web_sm"]:
        try:
            return spacy.load(model_name)
        except OSError:
            continue

    return None


def extract_entities_spacy(text: str) -> dict[str, list[str]]:
    """Extract entities using spaCy NER.

    Returns dict mapping entity type to list of unique entity strings.
    """
    nlp = _get_spacy_model()
    if nlp is None:
        raise RuntimeError("No spaCy model available. Install: python -m spacy download en_core_web_sm")

    max_length = nlp.max_length
    if len(text) > max_length:
        chunks = [text[i:i + max_length] for i in range(0, len(text), max_length)]
    else:
        chunks = [text]

    entities: dict[str, set[str]] = defaultdict(set)

    for chunk in chunks:
        doc = nlp(chunk)
        for ent in doc.ents:
            entity_type = SPACY_LABEL_MAP.get(ent.label_)
            if entity_type and entity_type in ENTITY_TYPES:
                cleaned = clean_entity(ent.text, entity_type)
                if cleaned:
                    entities[entity_type].add(cleaned)

    return {k: sorted(v) for k, v in entities.items() if v}


# ---------------------------------------------------------------------------
# Ollama LLM extraction (fallback)
# ---------------------------------------------------------------------------

_OLLAMA_PROMPT = """Extract named entities from the following email text. Return ONLY a JSON object with these keys:
- "people": list of person names
- "organisations": list of company/organisation names
- "properties": list of properties, products, or assets mentioned
- "locations": list of places, addresses, cities, countries
- "dates": list of dates mentioned (in original format)

Rules:
- Only include entities actually present in the text
- Deduplicate: if the same entity appears multiple times, include it once
- For people: use full names where available
- For dates: preserve the original format from the text
- Omit empty categories
- Return ONLY valid JSON, no explanation

Text:
{text}

JSON:"""


def extract_entities_ollama(text: str) -> dict[str, list[str]]:
    """Extract entities using Ollama LLM.

    Returns dict mapping entity type to list of unique entity strings.
    """
    model = get_ollama_model()
    if model is None:
        raise RuntimeError("No Ollama model available. Install: ollama pull llama3.2")

    max_chars = 8000
    if len(text) > max_chars:
        text = text[:max_chars] + "\n[... truncated for extraction ...]"

    prompt = _OLLAMA_PROMPT.format(text=text)

    try:
        result = subprocess.run(
            ["ollama", "run", model, prompt],
            capture_output=True, text=True, timeout=120
        )
        if result.returncode != 0:
            raise RuntimeError(f"Ollama failed: {result.stderr}")

        response = result.stdout.strip()
        return parse_llm_response(response)

    except subprocess.TimeoutExpired:
        raise RuntimeError("Ollama timed out (120s)")


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

def entities_to_yaml(entities: dict[str, list[str]], indent: int = 0) -> str:
    """Convert entities dict to YAML frontmatter fragment."""
    prefix = " " * indent
    if not entities:
        return f"{prefix}entities: {{}}"

    lines = [f"{prefix}entities:"]
    for entity_type in ENTITY_TYPES:
        if entity_type in entities and entities[entity_type]:
            lines.append(f"{prefix}  {entity_type}:")
            for entity in entities[entity_type]:
                escaped = yaml_escape(entity)
                lines.append(f"{prefix}    - {escaped}")

    return "\n".join(lines)


def update_frontmatter(file_path: str, entities: dict[str, list[str]]) -> bool:
    """Update a markdown file's YAML frontmatter with entities.

    Adds or replaces the `entities:` field in existing frontmatter.
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
    skip_block = False
    for line in fm_lines:
        if line.startswith("entities:"):
            skip_block = True
            continue
        if skip_block:
            if line.startswith("  ") or line.startswith("\t"):
                continue
            skip_block = False
        new_fm_lines.append(line)

    entities_yaml = entities_to_yaml(entities)
    new_fm_lines.append(entities_yaml)

    new_fm = "\n".join(new_fm_lines)
    new_content = f"---\n{new_fm}\n---{body}"

    path.write_text(new_content, encoding="utf-8")
    return True


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
