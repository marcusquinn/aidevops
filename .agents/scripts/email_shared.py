#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
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

def yaml_escape(value: Optional[str]) -> str:
    """Escape a string value for safe YAML output.

    Handles special characters, newlines, and leading whitespace.
    Superset of both _yaml_escape (email-summary) and _yaml_escape_value
    (entity-extraction) — includes \\r handling from email-summary.
    Accepts None and returns empty-string YAML value.
    """
    if value is None:
        return '""'
    value = str(value)
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

    # Parse model names exactly (first column, strip :tag suffix) to avoid
    # substring false positives (e.g. "phi3" matching "dolphin-phi3-medium")
    available_models: list[str] = []
    for line in result.stdout.strip().split("\n")[1:]:  # Skip header line
        if line.strip():
            model_name = line.split()[0].split(":")[0].lower()
            available_models.append(model_name)

    for model in preferred_models:
        if model.lower() in available_models:
            return model

    # Fall back to first available model
    if available_models:
        return available_models[0]

    return None
