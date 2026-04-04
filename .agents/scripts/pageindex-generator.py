#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
pageindex-generator.py - Generate .pageindex.json from markdown heading hierarchy.

Part of aidevops document-creation-helper.sh (extracted for complexity reduction).

Usage: pageindex-generator.py <input_file> <output_file> [use_ollama] [ollama_model]
                               [source_pdf] [page_count]
  use_ollama:   'true' or 'false' (default: false)
  ollama_model: model name (default: llama3.2:1b)
  source_pdf:   path to source PDF for page estimation (default: '')
  page_count:   integer page count (default: 0)
"""

import sys
import re
import json
import hashlib
from typing import Any, Dict, List, Optional


def extract_frontmatter(lines: List[str]) -> Dict[str, str]:
    """Extract YAML frontmatter fields from markdown."""
    frontmatter: Dict[str, str] = {}
    if not lines or lines[0].strip() != '---':
        return frontmatter

    for i, line in enumerate(lines[1:], 1):
        if line.strip() == '---':
            break
        if ':' in line:
            key, _, value = line.partition(':')
            frontmatter[key.strip()] = value.strip()

    return frontmatter


def get_frontmatter_end(lines: List[str]) -> int:
    """Return the line index after the closing --- of frontmatter, or 0."""
    if not lines or lines[0].strip() != '---':
        return 0
    for i, line in enumerate(lines[1:], 1):
        if line.strip() == '---':
            return i + 1
    return 0


def extract_first_sentence(text: str) -> str:
    """Extract the first meaningful sentence from text."""
    # Strip markdown formatting
    text = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', text)  # links
    text = re.sub(r'[*_`~]+', '', text)  # emphasis
    text = text.strip()

    if not text:
        return ""

    # Find first sentence boundary
    match = re.match(r'^(.+?[.!?])\s', text)
    if match:
        sentence = match.group(1).strip()
        # Cap at 200 chars
        if len(sentence) > 200:
            return sentence[:197] + '...'
        return sentence

    # No sentence boundary — use first line, capped
    first_line = text.split('\n')[0].strip()
    if len(first_line) > 200:
        return first_line[:197] + '...'
    return first_line


def get_ollama_summary(text: str, model: str) -> Optional[str]:
    """Get a one-sentence summary from Ollama. Returns None on failure."""
    import urllib.request
    import urllib.error

    # Truncate input to avoid overwhelming small models
    if len(text) > 2000:
        text = text[:2000] + '...'

    prompt = (
        "Summarise the following section in exactly one concise sentence "
        "(max 150 characters). Return ONLY the summary sentence, nothing else.\n\n"
        + text
    )

    payload = json.dumps({
        "model": model,
        "prompt": prompt,
        "stream": False,
        "options": {"temperature": 0.1, "num_predict": 80},
    }).encode('utf-8')

    req = urllib.request.Request(
        'http://localhost:11434/api/generate',
        data=payload,
        headers={'Content-Type': 'application/json'},
    )

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read().decode('utf-8'))
            summary = result.get('response', '').strip()
            # Clean up: remove quotes, ensure single sentence
            summary = summary.strip('"\'')
            # Take only first sentence if model returned multiple
            match = re.match(r'^(.+?[.!?])', summary)
            if match:
                return match.group(1)
            return summary if summary else None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return None


def estimate_page_from_position(
    line_idx: int, total_lines: int, page_count: int
) -> int:
    """Estimate which PDF page a line corresponds to based on position ratio."""
    if page_count <= 0 or total_lines <= 0:
        return 0
    ratio = line_idx / total_lines
    page = int(ratio * page_count) + 1
    return min(page, page_count)


def build_tree_recursive(
    sections_list: List[Dict[str, Any]],
    start_idx: int,
    parent_level: int,
    total_lines: int,
    page_count: int,
    use_ollama: bool,
    ollama_model: str,
) -> tuple:
    """Recursively build tree from sections starting at start_idx."""
    children = []
    i = start_idx

    while i < len(sections_list):
        section = sections_list[i]

        if section['level'] <= parent_level:
            # This section is at or above parent level — stop
            break

        # Generate summary
        summary = ""
        if use_ollama and section['content']:
            summary = get_ollama_summary(section['content'], ollama_model) or ""
        if not summary and section['content']:
            summary = extract_first_sentence(section['content'])

        # Estimate page reference
        page_ref = None
        if page_count > 0:
            page_ref = estimate_page_from_position(
                section['line_idx'], total_lines, page_count
            )

        node: Dict[str, Any] = {
            "title": section['title'],
            "level": section['level'],
            "summary": summary,
            "page": page_ref,
            "children": [],
        }

        # Find children (sections with higher level numbers before next sibling)
        child_children, next_i = build_tree_recursive(
            sections_list,
            i + 1,
            section['level'],
            total_lines,
            page_count,
            use_ollama,
            ollama_model,
        )
        node['children'] = child_children

        children.append(node)
        i = next_i

    return children, i


def build_pageindex_tree(
    lines: List[str],
    use_ollama: bool,
    ollama_model: str,
    source_pdf: str,
    page_count: int,
) -> Dict[str, Any]:
    """Build a hierarchical PageIndex tree from markdown headings."""
    frontmatter = extract_frontmatter(lines)
    content_start = get_frontmatter_end(lines)
    content_lines = lines[content_start:]
    total_lines = len(content_lines)

    # Parse headings and their content
    sections: List[Dict[str, Any]] = []
    current_heading: Optional[Dict[str, Any]] = None
    current_content_lines: List[str] = []

    for i, line in enumerate(content_lines):
        stripped = line.strip()
        heading_match = re.match(r'^(#{1,6})\s+(.+)$', stripped)

        if heading_match:
            # Save previous section
            if current_heading is not None:
                sections.append({
                    'level': current_heading['level'],
                    'title': current_heading['title'],
                    'line_idx': current_heading['line_idx'],
                    'content': '\n'.join(current_content_lines).strip(),
                })

            level = len(heading_match.group(1))
            title = heading_match.group(2).strip()
            current_heading = {
                'level': level,
                'title': title,
                'line_idx': i,
            }
            current_content_lines = []
        else:
            current_content_lines.append(line)

    # Save last section
    if current_heading is not None:
        sections.append({
            'level': current_heading['level'],
            'title': current_heading['title'],
            'line_idx': current_heading['line_idx'],
            'content': '\n'.join(current_content_lines).strip(),
        })

    if not sections:
        # No headings found — create a single root node from the whole content
        full_content = '\n'.join(content_lines).strip()
        title = frontmatter.get('title', 'Untitled')
        summary = ""
        if use_ollama and full_content:
            summary = get_ollama_summary(full_content, ollama_model) or ""
        if not summary and full_content:
            summary = extract_first_sentence(full_content)

        return {
            "version": "1.0",
            "generator": "aidevops/document-creation-helper",
            "source_file": frontmatter.get('source_file', ''),
            "content_hash": frontmatter.get('content_hash', ''),
            "page_count": page_count,
            "tree": {
                "title": title,
                "level": 1,
                "summary": summary,
                "page": 1 if page_count > 0 else None,
                "children": [],
            },
        }

    # Build hierarchical tree from flat section list
    root_section = sections[0]
    root_summary = ""
    if use_ollama and root_section['content']:
        root_summary = get_ollama_summary(root_section['content'], ollama_model) or ""
    if not root_summary and root_section['content']:
        root_summary = extract_first_sentence(root_section['content'])

    root_page = 1 if page_count > 0 else None

    root_children, _ = build_tree_recursive(
        sections, 1, root_section['level'], total_lines, page_count,
        use_ollama, ollama_model,
    )

    tree: Dict[str, Any] = {
        "title": root_section['title'],
        "level": root_section['level'],
        "summary": root_summary,
        "page": root_page,
        "children": root_children,
    }

    # Compute content hash if not in frontmatter
    content_hash = frontmatter.get('content_hash', '')
    if not content_hash:
        full_text = '\n'.join(lines)
        content_hash = hashlib.sha256(full_text.encode('utf-8')).hexdigest()

    return {
        "version": "1.0",
        "generator": "aidevops/document-creation-helper",
        "source_file": frontmatter.get(
            'source_file', source_pdf if source_pdf else ''
        ),
        "content_hash": content_hash,
        "page_count": page_count,
        "tree": tree,
    }


def main() -> None:
    if len(sys.argv) < 3:
        print(
            "Usage: pageindex-generator.py <input_file> <output_file> "
            "[use_ollama] [ollama_model] [source_pdf] [page_count]",
            file=sys.stderr,
        )
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2]
    use_ollama = sys.argv[3].lower() == 'true' if len(sys.argv) > 3 else False
    ollama_model = sys.argv[4] if len(sys.argv) > 4 else 'llama3.2:1b'
    source_pdf = sys.argv[5] if len(sys.argv) > 5 else ''
    page_count = (
        int(sys.argv[6])
        if len(sys.argv) > 6 and sys.argv[6].isdigit()
        else 0
    )

    with open(input_file, 'r', encoding='utf-8') as f:
        lines = f.read().splitlines()

    pageindex = build_pageindex_tree(
        lines, use_ollama, ollama_model, source_pdf, page_count
    )

    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(pageindex, f, indent=2, ensure_ascii=False)
        f.write('\n')


if __name__ == '__main__':
    main()
