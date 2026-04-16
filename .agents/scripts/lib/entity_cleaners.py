"""Entity cleaning and LLM response parsing utilities.

Extracted from entity-extraction.py as part of t2130 to reduce file
complexity. Provides entity text cleaning, LLM JSON response parsing,
and regex-based extraction patterns.
"""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

from __future__ import annotations

import json
import re
from typing import Optional


# Entity types we extract (ordered for frontmatter output)
ENTITY_TYPES = ["people", "organisations", "properties", "locations", "dates"]

# spaCy NER label -> our entity type
SPACY_LABEL_MAP: dict[str, str] = {
    "PERSON": "people",
    "PER": "people",
    "ORG": "organisations",
    "GPE": "locations",
    "LOC": "locations",
    "FAC": "locations",
    "DATE": "dates",
    "TIME": "dates",
    "MONEY": "financial",
    "PRODUCT": "properties",
    "WORK_OF_ART": "properties",
    "EVENT": "events",
    "NORP": "organisations",
}

# False positives by entity type
_FALSE_POSITIVES = {
    "people": {"re", "fw", "fwd", "dear", "hi", "hello", "regards",
               "best", "thanks", "thank you", "sincerely", "cheers"},
    "organisations": {"re", "fw", "fwd", "http", "https", "www",
                      "gmail", "yahoo", "hotmail", "outlook"},
    "locations": {"re", "fw", "fwd", "http", "https"},
}


# ---------------------------------------------------------------------------
# Entity cleaning
# ---------------------------------------------------------------------------

def clean_entity(text: str, entity_type: str) -> str:
    """Clean and normalise an extracted entity string."""
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
    if text.lower() in _FALSE_POSITIVES.get(entity_type, set()):
        return ""

    return text


# ---------------------------------------------------------------------------
# LLM response parsing
# ---------------------------------------------------------------------------

def extract_json_from_response(response: str) -> Optional[dict]:
    """Extract and parse JSON from an LLM response string.

    Handles markdown code blocks, bare JSON, and single-quote issues.
    Returns parsed dict or None if parsing fails.
    """
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
        return json.loads(response)
    except json.JSONDecodeError:
        pass

    # Last resort: try to fix common issues (single quotes)
    response = response.replace("'", '"')
    try:
        return json.loads(response)
    except json.JSONDecodeError:
        return None


def validate_and_clean_entities(data: dict) -> dict[str, list[str]]:
    """Validate and clean entity lists from parsed LLM output."""
    entities: dict[str, list[str]] = {}
    for entity_type in ENTITY_TYPES:
        raw_list = data.get(entity_type)
        if not isinstance(raw_list, list):
            continue
        cleaned = []
        for item in raw_list:
            if not isinstance(item, str):
                continue
            c = clean_entity(item, entity_type)
            if c and c not in cleaned:
                cleaned.append(c)
        if cleaned:
            entities[entity_type] = cleaned
    return entities


def parse_llm_response(response: str) -> dict[str, list[str]]:
    """Parse LLM JSON response, handling common formatting issues."""
    data = extract_json_from_response(response)
    if data is None:
        return {}
    return validate_and_clean_entities(data)


# ---------------------------------------------------------------------------
# Regex-based extraction patterns
# ---------------------------------------------------------------------------

# Common date patterns
DATE_PATTERNS = [
    r'\b\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4}\b',
    r'\b\d{4}[/\-.]\d{1,2}[/\-.]\d{1,2}\b',
    r'\b\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{2,4}\b',
    r'\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{1,2},?\s+\d{2,4}\b',
    r'\b(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday),?\s+\d{1,2}\s+\w+\s+\d{4}\b',
]

# Email address pattern (to extract people from "Name <email>" patterns)
EMAIL_NAME_PATTERN = r'([A-Z][a-z]+(?:\s+[A-Z][a-z]+)+)\s*<[^>]+>'


def extract_entities_regex(text: str) -> dict[str, list[str]]:
    """Minimal regex-based entity extraction as last-resort fallback.

    Only extracts dates and email-header names reliably.
    """
    entities: dict[str, list[str]] = {}

    # Extract dates
    dates = set()
    for pattern in DATE_PATTERNS:
        for match in re.finditer(pattern, text, re.IGNORECASE):
            dates.add(match.group(0).strip())
    if dates:
        entities["dates"] = sorted(dates)

    # Extract names from email header patterns (Name <email>)
    people = set()
    for match in re.finditer(EMAIL_NAME_PATTERN, text):
        name = match.group(1).strip()
        if len(name) > 2 and name not in ("Re", "Fw", "Fwd"):
            people.add(name)
    if people:
        entities["people"] = sorted(people)

    return entities
