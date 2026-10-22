# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Entity extraction backends (spaCy NER and Ollama LLM) for entity-extraction.py."""

from __future__ import annotations

import subprocess
from collections import defaultdict

from entity_cleaners import (
    ENTITY_TYPES,
    SPACY_LABEL_MAP,
    clean_entity,
    parse_llm_response,
)
from email_shared import get_ollama_model


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
