#!/usr/bin/env python3
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
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import Optional


# ---------------------------------------------------------------------------
# Entity type mapping
# ---------------------------------------------------------------------------

# spaCy NER label -> our entity type
_SPACY_LABEL_MAP: dict[str, str] = {
    "PERSON": "people",
    "PER": "people",
    "ORG": "organisations",
    "GPE": "locations",       # geopolitical entities (cities, countries)
    "LOC": "locations",       # non-GPE locations
    "FAC": "locations",       # facilities (buildings, airports)
    "DATE": "dates",
    "TIME": "dates",
    "MONEY": "financial",
    "PRODUCT": "properties",  # products, objects
    "WORK_OF_ART": "properties",
    "EVENT": "events",
    "NORP": "organisations",  # nationalities, religious/political groups
}

# Entity types we extract (ordered for frontmatter output)
ENTITY_TYPES = ["people", "organisations", "properties", "locations", "dates"]


# ---------------------------------------------------------------------------
# Markdown body extraction (strip frontmatter)
# ---------------------------------------------------------------------------

def extract_body(content: str) -> str:
    """Extract the body text from a markdown file, stripping YAML frontmatter."""
    if content.startswith("---"):
        # Find closing ---
        end = content.find("\n---", 3)
        if end != -1:
            return content[end + 4:].strip()
    return content.strip()


def extract_frontmatter(content: str) -> tuple[str, str, str]:
    """Split content into (pre-frontmatter, frontmatter, body).

    Returns ('---\\n', frontmatter_content, body) or ('', '', content).
    """
    if not content.startswith("---"):
        return ("", "", content)

    end = content.find("\n---", 3)
    if end == -1:
        return ("", "", content)

    fm_content = content[4:end]  # between opening --- and closing ---
    body = content[end + 4:]
    return ("---\n", fm_content, body)


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

    # Try models in order of quality (largest first)
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

    # spaCy has a max length; chunk if needed
    max_length = nlp.max_length
    if len(text) > max_length:
        # Process in chunks, preserving sentence boundaries where possible
        chunks = [text[i:i + max_length] for i in range(0, len(text), max_length)]
    else:
        chunks = [text]

    entities: dict[str, set[str]] = defaultdict(set)

    for chunk in chunks:
        doc = nlp(chunk)
        for ent in doc.ents:
            entity_type = _SPACY_LABEL_MAP.get(ent.label_)
            if entity_type and entity_type in ENTITY_TYPES:
                # Clean up the entity text
                cleaned = _clean_entity(ent.text, entity_type)
                if cleaned:
                    entities[entity_type].add(cleaned)

    # Convert sets to sorted lists
    return {k: sorted(v) for k, v in entities.items() if v}


# ---------------------------------------------------------------------------
# Ollama LLM extraction (fallback)
# ---------------------------------------------------------------------------

def _check_ollama() -> bool:
    """Check if Ollama is running and accessible."""
    try:
        result = subprocess.run(
            ["ollama", "list"],
            capture_output=True, text=True, timeout=5
        )
        return result.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def _get_ollama_model() -> Optional[str]:
    """Find the best available Ollama model for NER."""
    try:
        result = subprocess.run(
            ["ollama", "list"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            return None

        available = result.stdout.lower()
        # Prefer models good at structured extraction
        for model in ["llama3.2", "llama3.1", "llama3", "mistral", "gemma2", "phi3"]:
            if model in available:
                return model

        # Fall back to first available model
        lines = result.stdout.strip().split("\n")
        if len(lines) > 1:  # Skip header line
            first_model = lines[1].split()[0]
            return first_model.split(":")[0]

    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    return None


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
    model = _get_ollama_model()
    if model is None:
        raise RuntimeError("No Ollama model available. Install: ollama pull llama3.2")

    # Truncate very long texts to avoid context overflow
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
        return _parse_llm_response(response)

    except subprocess.TimeoutExpired:
        raise RuntimeError("Ollama timed out (120s)")


def _parse_llm_response(response: str) -> dict[str, list[str]]:
    """Parse LLM JSON response, handling common formatting issues."""
    # Try to extract JSON from the response
    # LLMs sometimes wrap JSON in markdown code blocks
    json_match = re.search(r'```(?:json)?\s*\n?(.*?)\n?```', response, re.DOTALL)
    if json_match:
        response = json_match.group(1)

    # Try to find JSON object boundaries
    brace_start = response.find("{")
    brace_end = response.rfind("}")
    if brace_start != -1 and brace_end != -1:
        response = response[brace_start:brace_end + 1]

    try:
        data = json.loads(response)
    except json.JSONDecodeError:
        # Last resort: try to fix common issues
        response = response.replace("'", '"')
        try:
            data = json.loads(response)
        except json.JSONDecodeError:
            return {}

    # Validate and clean the response
    entities: dict[str, list[str]] = {}
    for entity_type in ENTITY_TYPES:
        if entity_type in data and isinstance(data[entity_type], list):
            cleaned = []
            for item in data[entity_type]:
                if isinstance(item, str):
                    c = _clean_entity(item, entity_type)
                    if c and c not in cleaned:
                        cleaned.append(c)
            if cleaned:
                entities[entity_type] = cleaned

    return entities


# ---------------------------------------------------------------------------
# Regex-based extraction (minimal fallback)
# ---------------------------------------------------------------------------

# Common date patterns
_DATE_PATTERNS = [
    r'\b\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4}\b',           # DD/MM/YYYY, MM-DD-YY
    r'\b\d{4}[/\-.]\d{1,2}[/\-.]\d{1,2}\b',              # YYYY-MM-DD
    r'\b\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{2,4}\b',  # 14 Feb 2026
    r'\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{1,2},?\s+\d{2,4}\b',  # Feb 14, 2026
    r'\b(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday),?\s+\d{1,2}\s+\w+\s+\d{4}\b',  # Monday, 14 February 2026
]

# Email address pattern (to extract people from "Name <email>" patterns)
_EMAIL_NAME_PATTERN = r'([A-Z][a-z]+(?:\s+[A-Z][a-z]+)+)\s*<[^>]+>'


def extract_entities_regex(text: str) -> dict[str, list[str]]:
    """Minimal regex-based entity extraction as last-resort fallback.

    Only extracts dates and email-header names reliably.
    """
    entities: dict[str, list[str]] = {}

    # Extract dates
    dates = set()
    for pattern in _DATE_PATTERNS:
        for match in re.finditer(pattern, text, re.IGNORECASE):
            dates.add(match.group(0).strip())
    if dates:
        entities["dates"] = sorted(dates)

    # Extract names from email header patterns (Name <email>)
    people = set()
    for match in re.finditer(_EMAIL_NAME_PATTERN, text):
        name = match.group(1).strip()
        if len(name) > 2 and name not in ("Re", "Fw", "Fwd"):
            people.add(name)
    if people:
        entities["people"] = sorted(people)

    return entities


# ---------------------------------------------------------------------------
# Entity cleaning
# ---------------------------------------------------------------------------

def _clean_entity(text: str, entity_type: str) -> str:
    """Clean and normalise an extracted entity string."""
    # Strip whitespace and common artifacts
    text = text.strip()
    text = re.sub(r'\s+', ' ', text)

    # Remove markdown formatting
    text = re.sub(r'[*_`~]', '', text)

    # Remove leading/trailing punctuation (except for dates)
    if entity_type != "dates":
        text = text.strip('.,;:!?()[]{}"\'-')

    # Skip very short or very long entities
    if len(text) < 2 or len(text) > 200:
        return ""

    # Skip common false positives
    _false_positives = {
        "people": {"re", "fw", "fwd", "dear", "hi", "hello", "regards",
                   "best", "thanks", "thank you", "sincerely", "cheers"},
        "organisations": {"re", "fw", "fwd", "http", "https", "www",
                         "gmail", "yahoo", "hotmail", "outlook"},
        "locations": {"re", "fw", "fwd", "http", "https"},
    }
    if text.lower() in _false_positives.get(entity_type, set()):
        return ""

    return text


# ---------------------------------------------------------------------------
# Main extraction orchestrator
# ---------------------------------------------------------------------------

def extract_entities(text: str, method: str = "auto") -> dict[str, list[str]]:
    """Extract entities from text using the specified method.

    Args:
        text: The text to extract entities from.
        method: 'auto' (try spaCy, then Ollama, then regex),
                'spacy', 'ollama', or 'regex'.

    Returns:
        Dict mapping entity type to list of entity strings.
    """
    if method == "spacy":
        return extract_entities_spacy(text)

    if method == "ollama":
        return extract_entities_ollama(text)

    if method == "regex":
        return extract_entities_regex(text)

    # Auto: try methods in order of quality
    # 1. spaCy (best quality, local, fast)
    if _check_spacy():
        try:
            nlp = _get_spacy_model()
            if nlp is not None:
                result = extract_entities_spacy(text)
                if result:
                    return result
        except Exception as e:
            print(f"spaCy extraction failed: {e}", file=sys.stderr)

    # 2. Ollama (good quality, local, slower)
    if _check_ollama():
        try:
            result = extract_entities_ollama(text)
            if result:
                return result
        except Exception as e:
            print(f"Ollama extraction failed: {e}", file=sys.stderr)

    # 3. Regex (minimal, always available)
    return extract_entities_regex(text)


# ---------------------------------------------------------------------------
# Frontmatter integration
# ---------------------------------------------------------------------------

def entities_to_yaml(entities: dict[str, list[str]], indent: int = 0) -> str:
    """Convert entities dict to YAML frontmatter fragment.

    Output format:
        entities:
          people:
            - "John Smith"
            - "Jane Doe"
          organisations:
            - "Acme Corp"
          locations:
            - "London"
    """
    prefix = " " * indent
    if not entities:
        return f"{prefix}entities: {{}}"

    lines = [f"{prefix}entities:"]
    for entity_type in ENTITY_TYPES:
        if entity_type in entities and entities[entity_type]:
            lines.append(f"{prefix}  {entity_type}:")
            for entity in entities[entity_type]:
                # YAML-escape the value
                escaped = _yaml_escape_value(entity)
                lines.append(f"{prefix}    - {escaped}")

    return "\n".join(lines)


def _yaml_escape_value(value: str) -> str:
    """Escape a string for safe YAML output."""
    if not value:
        return '""'
    needs_quoting = any(c in value for c in [':', '#', '{', '}', '[', ']', ',',
                                              '&', '*', '?', '|', '-', '<', '>',
                                              '=', '!', '%', '@', '`', '\n', '"', "'"])
    needs_quoting = needs_quoting or value.startswith((' ', '\t'))
    if needs_quoting:
        value = value.replace('\\', '\\\\').replace('"', '\\"')
        return f'"{value}"'
    return value


def update_frontmatter(file_path: str, entities: dict[str, list[str]]) -> bool:
    """Update a markdown file's YAML frontmatter with entities.

    Adds or replaces the `entities:` field in existing frontmatter.
    Returns True if the file was modified.
    """
    path = Path(file_path)
    content = path.read_text(encoding="utf-8")

    opener, fm_content, body = extract_frontmatter(content)
    if not opener:
        # No frontmatter — can't add entities without it
        print(f"WARNING: No YAML frontmatter in {file_path}", file=sys.stderr)
        return False

    # Remove existing entities: block from frontmatter
    fm_lines = fm_content.split("\n")
    new_fm_lines = []
    skip_block = False
    for line in fm_lines:
        if line.startswith("entities:"):
            skip_block = True
            continue
        if skip_block:
            # Check if this line is still part of the entities block (indented)
            if line.startswith("  ") or line.startswith("\t"):
                continue
            skip_block = False
        new_fm_lines.append(line)

    # Add entities block
    entities_yaml = entities_to_yaml(entities)
    new_fm_lines.append(entities_yaml)

    # Rebuild the file
    new_fm = "\n".join(new_fm_lines)
    new_content = f"---\n{new_fm}\n---{body}"

    path.write_text(new_content, encoding="utf-8")
    return True


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> int:
    """CLI entry point."""
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

    args = parser.parse_args()

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

    if args.update_frontmatter:
        if update_frontmatter(args.input, entities):
            print(f"Updated frontmatter in {args.input}")
            # Also print the entities for logging
            if entities:
                for etype, elist in entities.items():
                    print(f"  {etype}: {', '.join(elist[:5])}"
                          + (f" (+{len(elist) - 5} more)" if len(elist) > 5 else ""))
            else:
                print("  (no entities found)")
        else:
            print(f"Could not update frontmatter in {args.input}", file=sys.stderr)
            return 1
    else:
        # Output JSON
        print(json.dumps(entities, indent=2, ensure_ascii=False))

    return 0


if __name__ == "__main__":
    sys.exit(main())
