#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
pageindex-generator.py - Generate .pageindex.json from markdown heading hierarchy.

Part of aidevops document-creation-helper.sh (extracted for complexity reduction).

Phase 5 (t2972): lifts Markdoc tag attributes from source.md into per-node
``metadata`` so retrieval can filter and rank by tag attributes without
re-reading file bodies.  Citation tags produce a ``cross_references`` array
at the document root.

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
from markdoc_tag_extractor import (
    extract_tags_from_lines,
    classify_tag_scope,
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
    section_metadata: Optional[Dict[int, Dict[str, Any]]] = None,
) -> tuple:
    """Recursively build tree from sections starting at start_idx.

    ``section_metadata`` maps flat section index → metadata dict (tag_name →
    attrs) to inject into that node.  Passed through unchanged to all
    recursive calls so every level can look up its own index.
    """
    children = []
    i = start_idx
    sm = section_metadata or {}

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

        # Inject section-scope tag metadata when present for this section index
        if i in sm and sm[i]:
            node["metadata"] = sm[i]

        child_children, next_i = build_tree_recursive(
            sections_list, i + 1, section['level'], ctx, sm
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


# ---------------------------------------------------------------------------
# Tag metadata helpers (Phase 5 — t2972)
# ---------------------------------------------------------------------------

def _first_heading_line(content_lines: List[str]) -> Optional[int]:
    """Return the 0-indexed line of the first heading in content, or None."""
    for i, line in enumerate(content_lines):
        if re.match(r'^#{1,6}\s', line.strip()):
            return i
    return None


def _build_file_metadata(file_tags: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Return metadata dict keyed by tag name from file-scope tag entries.

    Only non-closing tags with at least one attribute are included.
    If the same tag name appears more than once, the last occurrence wins.
    """
    metadata: Dict[str, Any] = {}
    for entry in file_tags:
        attrs = entry.get('attrs', {})
        if not attrs:
            continue
        metadata[entry['tag']] = dict(attrs)
    return metadata


def _build_cross_references(
    all_citation_tags: List[Dict[str, Any]],
) -> List[Dict[str, Any]]:
    """Return a cross_references list from non-closing citation tag entries."""
    refs = []
    for entry in all_citation_tags:
        attrs = entry.get('attrs', {})
        if attrs:
            refs.append(dict(attrs))
    return refs


def _assign_tags_to_sections(
    section_tags: List[Dict[str, Any]],
    sections: List[Dict[str, Any]],
) -> Dict[int, Dict[str, Any]]:
    """Map section-scope tags to the flat section index they belong to.

    A tag at content line *L* belongs to section *I* when:
    ``sections[I].line_idx <= L < sections[I+1].line_idx``
    (for the last section the upper bound is infinity).

    Returns ``{section_idx: {tag_name: attrs}}``.  The same-tag-name
    last-wins rule applies within each section.
    """
    section_metadata: Dict[int, Dict[str, Any]] = {}
    if not sections or not section_tags:
        return section_metadata

    for entry in section_tags:
        tag_line = entry['line']
        attrs = entry.get('attrs', {})
        if not attrs:
            continue

        owning_idx: Optional[int] = None
        for i, sec in enumerate(sections):
            next_start: Any = (
                sections[i + 1]['line_idx'] if i + 1 < len(sections) else float('inf')
            )
            if sec['line_idx'] <= tag_line < next_start:
                owning_idx = i
                break

        if owning_idx is not None:
            if owning_idx not in section_metadata:
                section_metadata[owning_idx] = {}
            section_metadata[owning_idx][entry['tag']] = dict(attrs)

    return section_metadata


def _extract_and_classify_tags(
    content_lines: List[str],
    sections: List[Dict[str, Any]],
) -> tuple:
    """Extract Markdoc tags from content and classify them.

    Returns:
        file_metadata  — dict to inject into the root tree node ``metadata``
        section_metadata — {section_idx: {tag_name: attrs}} for subtree nodes
        cross_references — list of citation attrs for the root ``cross_references``
    """
    all_tags = extract_tags_from_lines(content_lines)
    first_heading = _first_heading_line(content_lines)

    file_tags: List[Dict[str, Any]] = []
    section_tags_raw: List[Dict[str, Any]] = []
    citation_tags: List[Dict[str, Any]] = []

    for tag in all_tags:
        # Skip closing tags — they are structural, not metadata carriers
        if tag.get('is_close'):
            continue

        if tag['tag'] == 'citation':
            citation_tags.append(tag)
            # Citations are always inline; do NOT add to file/section buckets
            continue

        scope = classify_tag_scope(tag, first_heading)
        if scope == 'file':
            file_tags.append(tag)
        elif scope == 'section':
            section_tags_raw.append(tag)
        # inline tags other than citation are not injected into node metadata

    file_metadata = _build_file_metadata(file_tags)
    section_metadata = _assign_tags_to_sections(section_tags_raw, sections)
    cross_references = _build_cross_references(citation_tags)

    return file_metadata, section_metadata, cross_references


# ---------------------------------------------------------------------------
# Tree result builders
# ---------------------------------------------------------------------------

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
    """Build a hierarchical PageIndex tree from markdown headings.

    Phase 5 extension (t2972): Markdoc tag attributes found in the source are
    lifted into per-node ``metadata`` fields so retrieval can filter by tag
    attributes without re-parsing the document body.  Citation tags produce a
    ``cross_references`` array at the document root.

    Node metadata shape::

        {
          "metadata": {
            "sensitivity": {"tier": "privileged", "scope": "file"},
            "provenance": {"source-id": "...", "extracted-at": "..."}
          }
        }

    Cross-references shape::

        {
          "cross_references": [
            {"source-id": "exhibit-A.pdf", "page": "p.4", "confidence": 1.0}
          ]
        }
    """
    frontmatter = extract_frontmatter(lines)
    content_start = get_frontmatter_end(lines)
    content_lines = lines[content_start:]
    ctx = TreeContext(len(content_lines), page_count, use_ollama, ollama_model)

    sections = parse_sections(content_lines)

    # --- Phase 5: extract and classify Markdoc tag metadata ---
    file_metadata, section_metadata, cross_references = _extract_and_classify_tags(
        content_lines, sections
    )

    content_hash = frontmatter.get('content_hash', '')
    if not content_hash:
        content_hash = hashlib.sha256('\n'.join(lines).encode('utf-8')).hexdigest()

    if not sections:
        result = build_headingless_result(frontmatter, content_lines, ctx)
        # Headingless doc: inject file-scope metadata and cross-references into root
        if file_metadata:
            result['tree']['metadata'] = file_metadata
        if cross_references:
            result['tree']['cross_references'] = cross_references
        return result

    root_section = sections[0]
    root_summary = get_section_summary(root_section, ctx)
    root_children, _ = build_tree_recursive(
        sections, 1, root_section['level'], ctx, section_metadata
    )

    tree: Dict[str, Any] = {
        "title": root_section['title'],
        "level": root_section['level'],
        "summary": root_summary,
        "page": 1 if page_count > 0 else None,
        "children": root_children,
    }

    # File-scope metadata goes on the root tree node (document-level).
    # Section-scope metadata for section index 0 (the root heading's own range)
    # is merged into file-scope metadata — root heading owns both.
    if file_metadata:
        tree["metadata"] = file_metadata
    elif 0 in section_metadata and section_metadata[0]:
        tree["metadata"] = section_metadata[0]

    if cross_references:
        tree["cross_references"] = cross_references

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
