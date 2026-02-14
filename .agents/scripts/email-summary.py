#!/usr/bin/env python3
"""Auto-summary generation for converted email markdown files (t1052.7).

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


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Emails with this many words or fewer use the heuristic summariser
WORD_COUNT_THRESHOLD = 100

# Maximum description length in characters
MAX_DESCRIPTION_LEN = 300

# Maximum text sent to Ollama (chars) to avoid context overflow
OLLAMA_MAX_CHARS = 6000


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
    # Remove horizontal rules
    text = re.sub(r'^[-*_]{3,}\s*$', '', text, flags=re.MULTILINE)
    # Collapse whitespace
    text = re.sub(r'\n{3,}', '\n\n', text)
    return text.strip()


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


# ---------------------------------------------------------------------------
# Heuristic summariser (short emails)
# ---------------------------------------------------------------------------

def _extract_first_sentences(text: str, max_sentences: int = 2) -> str:
    """Extract the first N meaningful sentences from text.

    Skips greeting lines (Hi, Hello, Dear) and empty lines.
    """
    # Split into lines first to skip greetings
    lines = text.split('\n')
    meaningful_lines = []
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        # Skip common email greetings
        if re.match(r'^(hi|hello|hey|dear|good\s+(morning|afternoon|evening))\b',
                     stripped, re.IGNORECASE):
            continue
        # Skip signature indicators
        if re.match(r'^(--|best\s+regards|kind\s+regards|regards|thanks|cheers|sincerely)',
                     stripped, re.IGNORECASE):
            break
        meaningful_lines.append(stripped)

    # Rejoin and split into sentences
    text_block = ' '.join(meaningful_lines)
    # Split on sentence boundaries (period/exclamation/question followed by space or end)
    sentences = re.split(r'(?<=[.!?])\s+', text_block)

    result_sentences = []
    for sent in sentences:
        sent = sent.strip()
        if not sent:
            continue
        result_sentences.append(sent)
        if len(result_sentences) >= max_sentences:
            break

    return ' '.join(result_sentences)


def summarise_heuristic(body: str) -> str:
    """Generate a summary using extractive heuristic (first meaningful sentences).

    Suitable for short emails where the first sentences capture the intent.
    """
    cleaned = _strip_markdown(body)
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
    """Find the best available Ollama model for summarisation."""
    try:
        result = subprocess.run(
            ["ollama", "list"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            return None

        available = result.stdout.lower()
        # Prefer models good at summarisation
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


_OLLAMA_SUMMARY_PROMPT = """Summarise the following email in exactly 1-2 sentences. The summary should capture the main purpose or action of the email. Be concise and factual. Do not include greetings, sign-offs, or metadata.

Return ONLY the summary text, no quotes, no labels, no explanation.

Email:
{text}

Summary:"""


def summarise_ollama(body: str) -> str:
    """Generate a summary using Ollama LLM.

    Returns a 1-2 sentence summary string, or empty string on failure.
    """
    model = _get_ollama_model()
    if model is None:
        return ""

    cleaned = _strip_markdown(body)
    if not cleaned:
        return ""

    # Truncate very long texts
    if len(cleaned) > OLLAMA_MAX_CHARS:
        cleaned = cleaned[:OLLAMA_MAX_CHARS] + "\n[... truncated ...]"

    prompt = _OLLAMA_SUMMARY_PROMPT.format(text=cleaned)

    try:
        result = subprocess.run(
            ["ollama", "run", model, prompt],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0:
            print(f"WARNING: Ollama summarisation failed: {result.stderr}",
                  file=sys.stderr)
            return ""

        summary = result.stdout.strip()
        # Clean up common LLM artifacts
        summary = _clean_llm_summary(summary)
        return summary

    except subprocess.TimeoutExpired:
        print("WARNING: Ollama summarisation timed out (60s)", file=sys.stderr)
        return ""


def _clean_llm_summary(summary: str) -> str:
    """Clean up common LLM output artifacts from a summary."""
    if not summary:
        return ""

    # Remove markdown code blocks
    summary = re.sub(r'```.*?```', '', summary, flags=re.DOTALL)

    # Remove leading labels like "Summary:" or "Here is..."
    summary = re.sub(r'^(?:summary|here\s+is|the\s+email)\s*[:]\s*',
                     '', summary, flags=re.IGNORECASE)

    # Remove surrounding quotes
    summary = summary.strip('"\'')

    # Collapse whitespace
    summary = _clean_for_description(summary)

    # Truncate if too long
    if len(summary) > MAX_DESCRIPTION_LEN:
        summary = summary[:MAX_DESCRIPTION_LEN].rsplit(' ', 1)[0] + '...'

    return summary


# ---------------------------------------------------------------------------
# Main summarisation orchestrator
# ---------------------------------------------------------------------------

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

    cleaned = _strip_markdown(body)
    word_count = _word_count(cleaned)

    if method == "heuristic":
        return summarise_heuristic(body)

    if method == "ollama":
        summary = summarise_ollama(body)
        if summary:
            return summary
        # Fall back to heuristic if Ollama fails
        return summarise_heuristic(body)

    # Auto mode: use word count to decide
    if word_count <= WORD_COUNT_THRESHOLD:
        return summarise_heuristic(body)

    # Long email: try Ollama, fall back to heuristic
    if _check_ollama():
        summary = summarise_ollama(body)
        if summary:
            return summary

    # Ollama unavailable or failed — use heuristic as fallback
    print(f"INFO: Using heuristic summary for {word_count}-word email "
          f"(Ollama unavailable)", file=sys.stderr)
    return summarise_heuristic(body)


# ---------------------------------------------------------------------------
# YAML frontmatter helpers
# ---------------------------------------------------------------------------

def _yaml_escape(value: str) -> str:
    """Escape a string value for safe YAML output."""
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

def main() -> int:
    """CLI entry point."""
    parser = argparse.ArgumentParser(
        description="Generate auto-summaries for converted email markdown (t1052.7)"
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
    word_count = _word_count(cleaned_body)
    method_used = "heuristic" if word_count <= WORD_COUNT_THRESHOLD else "ollama"

    if args.update_frontmatter:
        if summary and update_frontmatter_description(args.input, summary):
            print(f"Updated description in {args.input}")
            print(f"  Words: {word_count}, Method: {method_used}")
            print(f"  Summary: {summary[:120]}{'...' if len(summary) > 120 else ''}")
        else:
            if not summary:
                print(f"No summary generated for {args.input}", file=sys.stderr)
            else:
                print(f"Could not update frontmatter in {args.input}",
                      file=sys.stderr)
            return 1
    elif args.json:
        output = {
            "summary": summary,
            "word_count": word_count,
            "method": method_used,
            "char_count": len(summary),
        }
        print(json.dumps(output, indent=2, ensure_ascii=False))
    else:
        print(summary)

    return 0


if __name__ == "__main__":
    sys.exit(main())
