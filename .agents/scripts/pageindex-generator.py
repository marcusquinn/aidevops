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

from pageindex_helpers import (
    extract_first_sentence,
    get_ollama_summary,
    extract_markdoc_tags,
)


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
    """Recursively build tree from sections starting at start_idx.

    Each node gains private ``_line_start`` / ``_line_end`` fields (relative
    to the content array, i.e. after frontmatter) used during tag injection.
    Call ``_strip_internal_fields`` to remove them before serialising.
    """
    children = []
    i = start_idx

    while i < len(sections_list):
        section = sections_list[i]

        if section['level'] <= parent_level:
            break

        child_children, next_i = build_tree_recursive(
            sections_list, i + 1, section['level'], ctx
        )

        # Line end: start of next sibling (or cousin at same/higher level) - 1.
        if next_i < len(sections_list):
            line_end = sections_list[next_i]['line_idx'] - 1
        else:
            line_end = ctx.total_lines - 1

        node: Dict[str, Any] = {
            "title": section['title'],
            "level": section['level'],
            "summary": get_section_summary(section, ctx),
            "page": get_section_page(section, ctx),
            "metadata": {},
            "_line_start": section['line_idx'],
            "_line_end": line_end,
            "children": child_children,
        }

        children.append(node)
        i = next_i

    return children, i


def _inject_tag_record(node: Dict[str, Any], tag_rec: Dict[str, Any]) -> bool:
    """Inject a tag record into the deepest tree node containing its line.

    Walks depth-first so the most specific (deepest) node wins.  Returns True
    if the tag was consumed by this node or one of its descendants.
    """
    line = tag_rec['line_num']
    if not (node.get('_line_start', 0) <= line <= node.get('_line_end', 0)):
        return False

    # Try children first — deepest match wins.
    for child in node.get('children', []):
        if _inject_tag_record(child, tag_rec):
            return True

    # No child claimed it — inject into this node.
    tag_name = tag_rec['tag']
    attrs = tag_rec['attrs']
    meta = node.setdefault('metadata', {})
    existing = meta.get(tag_name)
    if existing is None:
        meta[tag_name] = attrs
    elif isinstance(existing, list):
        existing.append(attrs)
    else:
        meta[tag_name] = [existing, attrs]
    return True


def _strip_internal_fields(node: Dict[str, Any]) -> None:
    """Remove private line-range fields from a node tree in-place (recursive)."""
    node.pop('_line_start', None)
    node.pop('_line_end', None)
    for child in node.get('children', []):
        _strip_internal_fields(child)


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
    """Build a single-node result when the document has no headings.

    The root node carries ``_line_start``/``_line_end`` so that callers can
    inject Markdoc tag metadata before stripping internal fields.
    """
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
            "metadata": {},
            "_line_start": 0,
            "_line_end": max(0, len(content_lines) - 1),
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
    """Build a hierarchical PageIndex tree from markdown headings.

    Markdoc tag attributes from the content are lifted into per-node
    ``metadata`` fields (t2972):

    - File-scope tags (before the first heading) → root node ``metadata``.
    - Section-scope tags → the deepest subtree node whose line range
      contains the tag's line.
    - Inline tags → same depth-first injection rule.

    ``{% citation ... %}`` tags are additionally aggregated into a top-level
    ``cross_references`` array for fast retrieval without full-corpus re-reads.
    """
    frontmatter = extract_frontmatter(lines)
    content_start = get_frontmatter_end(lines)
    content_lines = lines[content_start:]
    ctx = TreeContext(len(content_lines), page_count, use_ollama, ollama_model)

    # Extract Markdoc tags once; skip bare closing tags (no attrs to lift).
    all_tag_records = extract_markdoc_tags(content_lines)
    open_tags = [t for t in all_tag_records if not t['is_close']]
    citation_tags = [t for t in open_tags if t['tag'] == 'citation']

    sections = parse_sections(content_lines)

    if not sections:
        result = build_headingless_result(frontmatter, content_lines, ctx)
        root_node = result['tree']
        for tag_rec in open_tags:
            _inject_tag_record(root_node, tag_rec)
        _strip_internal_fields(root_node)
        if citation_tags:
            result['cross_references'] = [t['attrs'] for t in citation_tags]
        return result

    root_section = sections[0]
    root_summary = get_section_summary(root_section, ctx)
    root_children, _ = build_tree_recursive(sections, 1, root_section['level'], ctx)

    tree: Dict[str, Any] = {
        "title": root_section['title'],
        "level": root_section['level'],
        "summary": root_summary,
        "page": 1 if page_count > 0 else None,
        "metadata": {},
        # Root spans from line 0 so pre-heading tags are captured at root level.
        "_line_start": 0,
        "_line_end": max(0, len(content_lines) - 1),
        "children": root_children,
    }

    # Inject all open tags into the deepest containing node.
    for tag_rec in open_tags:
        _inject_tag_record(tree, tag_rec)

    # Remove line-range bookkeeping before serialising.
    _strip_internal_fields(tree)

    content_hash = frontmatter.get('content_hash', '')
    if not content_hash:
        content_hash = hashlib.sha256('\n'.join(lines).encode('utf-8')).hexdigest()

    result = {
        "version": "1.0",
        "generator": "aidevops/document-creation-helper",
        "source_file": frontmatter.get('source_file', source_pdf if source_pdf else ''),
        "content_hash": content_hash,
        "page_count": page_count,
        "tree": tree,
    }

    # Cross-reference index: all citation tags aggregated at document root.
    if citation_tags:
        result['cross_references'] = [t['attrs'] for t in citation_tags]

    return result


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
