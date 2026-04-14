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

from pageindex_helpers import extract_first_sentence, get_ollama_summary


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


def estimate_page_from_position(
    line_idx: int, total_lines: int, page_count: int
) -> int:
    """Estimate which PDF page a line corresponds to based on position ratio."""
    if page_count <= 0 or total_lines <= 0:
        return 0
    ratio = line_idx / total_lines
    page = int(ratio * page_count) + 1
    return min(page, page_count)


class TreeContext:
    """Shared context for tree-building operations."""

    def __init__(
        self,
        total_lines: int,
        page_count: int,
        use_ollama: bool,
        ollama_model: str,
    ) -> None:
        self.total_lines = total_lines
        self.page_count = page_count
        self.use_ollama = use_ollama
        self.ollama_model = ollama_model


def get_section_summary(section: Dict[str, Any], ctx: TreeContext) -> str:
    """Generate a summary for a section using Ollama or first-sentence extraction."""
    summary = ""
    if ctx.use_ollama and section['content']:
        summary = get_ollama_summary(section['content'], ctx.ollama_model) or ""
    if not summary and section['content']:
        summary = extract_first_sentence(section['content'])
    return summary


def get_section_page(section: Dict[str, Any], ctx: TreeContext) -> Optional[int]:
    """Estimate the PDF page for a section, or None if page_count is 0."""
    if ctx.page_count > 0:
        return estimate_page_from_position(
            section['line_idx'], ctx.total_lines, ctx.page_count
        )
    return None


def build_tree_recursive(
    sections_list: List[Dict[str, Any]],
    start_idx: int,
    parent_level: int,
    ctx: TreeContext,
) -> tuple:
    """Recursively build tree from sections starting at start_idx."""
    children = []
    i = start_idx

    while i < len(sections_list):
        section = sections_list[i]

        if section['level'] <= parent_level:
            break

        node: Dict[str, Any] = {
            "title": section['title'],
            "level": section['level'],
            "summary": get_section_summary(section, ctx),
            "page": get_section_page(section, ctx),
            "children": [],
        }

        child_children, next_i = build_tree_recursive(
            sections_list, i + 1, section['level'], ctx
        )
        node['children'] = child_children

        children.append(node)
        i = next_i

    return children, i


def parse_sections(content_lines: List[str]) -> List[Dict[str, Any]]:
    """Parse markdown headings into a flat list of section dicts."""
    sections: List[Dict[str, Any]] = []
    current_heading: Optional[Dict[str, Any]] = None
    current_content_lines: List[str] = []

    for i, line in enumerate(content_lines):
        heading_match = re.match(r'^(#{1,6})\s+(.+)$', line.strip())
        if heading_match:
            if current_heading is not None:
                sections.append({
                    'level': current_heading['level'],
                    'title': current_heading['title'],
                    'line_idx': current_heading['line_idx'],
                    'content': '\n'.join(current_content_lines).strip(),
                })
            current_heading = {
                'level': len(heading_match.group(1)),
                'title': heading_match.group(2).strip(),
                'line_idx': i,
            }
            current_content_lines = []
        else:
            current_content_lines.append(line)

    if current_heading is not None:
        sections.append({
            'level': current_heading['level'],
            'title': current_heading['title'],
            'line_idx': current_heading['line_idx'],
            'content': '\n'.join(current_content_lines).strip(),
        })

    return sections


def build_headingless_result(
    frontmatter: Dict[str, str],
    content_lines: List[str],
    ctx: TreeContext,
) -> Dict[str, Any]:
    """Build a single-node result when the document has no headings."""
    full_content = '\n'.join(content_lines).strip()
    title = frontmatter.get('title', 'Untitled')
    summary = ""
    if ctx.use_ollama and full_content:
        summary = get_ollama_summary(full_content, ctx.ollama_model) or ""
    if not summary and full_content:
        summary = extract_first_sentence(full_content)
    return {
        "version": "1.0",
        "generator": "aidevops/document-creation-helper",
        "source_file": frontmatter.get('source_file', ''),
        "content_hash": frontmatter.get('content_hash', ''),
        "page_count": ctx.page_count,
        "tree": {
            "title": title,
            "level": 1,
            "summary": summary,
            "page": 1 if ctx.page_count > 0 else None,
            "children": [],
        },
    }


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
    ctx = TreeContext(len(content_lines), page_count, use_ollama, ollama_model)

    sections = parse_sections(content_lines)

    if not sections:
        return build_headingless_result(frontmatter, content_lines, ctx)

    root_section = sections[0]
    root_summary = get_section_summary(root_section, ctx)
    root_children, _ = build_tree_recursive(sections, 1, root_section['level'], ctx)

    tree: Dict[str, Any] = {
        "title": root_section['title'],
        "level": root_section['level'],
        "summary": root_summary,
        "page": 1 if page_count > 0 else None,
        "children": root_children,
    }

    content_hash = frontmatter.get('content_hash', '')
    if not content_hash:
        content_hash = hashlib.sha256('\n'.join(lines).encode('utf-8')).hexdigest()

    return {
        "version": "1.0",
        "generator": "aidevops/document-creation-helper",
        "source_file": frontmatter.get('source_file', source_pdf if source_pdf else ''),
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
