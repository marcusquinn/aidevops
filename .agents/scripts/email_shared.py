#!/usr/bin/env python3
"""Shared utilities for email processing scripts (t1863).

Provides common functions used by email-summary.py and entity-extraction.py:
- Markdown frontmatter parsing (extract_body, extract_frontmatter)
- YAML value escaping (yaml_escape)
- Ollama availability checks (check_ollama, get_ollama_model)

Part of aidevops framework: https://aidevops.sh
"""

from __future__ import annotations

import subprocess
from typing import Optional


# ---------------------------------------------------------------------------
# Markdown body extraction (strip frontmatter)
# ---------------------------------------------------------------------------

def extract_body(content: str) -> str:
    """Extract the body text from a markdown file, stripping YAML frontmatter."""
    if content.startswith("---"):
        end = content.find("\n---", 3)
        if end != -1:
            return content[end + 4:].strip()
    return content.strip()


def extract_frontmatter(content: str) -> tuple[str, str, str]:
    """Split content into (opener, frontmatter_content, body).

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
# YAML escaping
# ---------------------------------------------------------------------------

def yaml_escape(value: str) -> str:
    """Escape a string value for safe YAML output.

    Handles special characters, newlines, and leading whitespace.
    Superset of both _yaml_escape (email-summary) and _yaml_escape_value
    (entity-extraction) — includes \\r handling from email-summary.
    """
    if not value:
        return '""'
    needs_quoting = any(c in value for c in [
        ':', '#', '{', '}', '[', ']', ',', '&', '*', '?', '|',
        '-', '<', '>', '=', '!', '%', '@', '`', '\n', '\r', '"', "'"
    ])
    needs_quoting = needs_quoting or value.startswith((' ', '\t'))
    if needs_quoting:
        value = value.replace('\\', '\\\\').replace('"', '\\"')
        value = value.replace('\n', ' ').replace('\r', '')
        return f'"{value}"'
    return value


# ---------------------------------------------------------------------------
# Ollama availability helpers
# ---------------------------------------------------------------------------

def run_ollama_list() -> Optional[subprocess.CompletedProcess]:
    """Run 'ollama list' and return the result, or None on failure."""
    try:
        result = subprocess.run(
            ["ollama", "list"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            return result
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return None


def check_ollama() -> bool:
    """Check if Ollama is running and accessible."""
    return run_ollama_list() is not None


def get_ollama_model(preferred_models: Optional[list[str]] = None) -> Optional[str]:
    """Find the best available Ollama model.

    Args:
        preferred_models: Ordered list of model names to prefer.
            Defaults to a general-purpose list suitable for both
            summarisation and structured extraction.

    Returns:
        Model name string, or None if Ollama is unavailable.
    """
    result = run_ollama_list()
    if result is None:
        return None

    if preferred_models is None:
        preferred_models = ["llama3.2", "llama3.1", "llama3", "mistral", "gemma2", "phi3"]

    available = result.stdout.lower()
    for model in preferred_models:
        if model in available:
            return model

    # Fall back to first available model
    lines = result.stdout.strip().split("\n")
    if len(lines) > 1:  # Skip header line
        first_model = lines[1].split()[0]
        return first_model.split(":")[0]

    return None
