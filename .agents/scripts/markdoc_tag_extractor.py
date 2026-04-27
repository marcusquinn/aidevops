#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""markdoc_tag_extractor.py - Extract Markdoc tags from knowledge source files.

Used by pageindex-generator.py to lift tag attributes into PageIndex tree node
metadata, enabling tag-filtered retrieval without re-reading document bodies.

Part of the t2874 knowledge plane Markdoc pipeline — Phase 5 (t2972).

Tag output shape (per entry):

  {
    "tag": str,            # tag name, e.g. "sensitivity"
    "attrs": dict,         # parsed attribute key-value pairs
    "line": int,           # 0-indexed line number within the lines list provided
    "is_close": bool,      # True if this is a closing tag {% /tag %}
    "is_self_close": bool  # True if this is a self-closing tag {% tag /%}
  }
"""

import re
from typing import Any, Dict, List, Optional, Tuple


def parse_markdoc_attrs(attrs_str: str) -> Dict[str, Any]:
    """Parse a Markdoc attribute string into a dict.

    Handles double-quoted, single-quoted, and unquoted values.
    Numeric values are coerced to int or float where unambiguous.

    Examples::

        >>> parse_markdoc_attrs('tier="privileged" scope="file"')
        {'tier': 'privileged', 'scope': 'file'}
        >>> parse_markdoc_attrs('source-id="doc.pdf" confidence=0.95')
        {'source-id': 'doc.pdf', 'confidence': 0.95}
    """
    attrs: Dict[str, Any] = {}
    # Match: name="value" | name='value' | name=bare_value
    pattern = re.compile(
        r'([\w-]+)\s*=\s*(?:"([^"]*)"|\'([^\']*)\'|([^\s\'"}{%]+))'
    )
    for m in pattern.finditer(attrs_str):
        key = m.group(1)
        # Prefer group 2 (double-quoted), then 3 (single-quoted), then 4 (unquoted)
        raw: str = (
            m.group(2)
            if m.group(2) is not None
            else (m.group(3) if m.group(3) is not None else (m.group(4) or ''))
        )
        # Numeric coercion — only for unquoted values (groups 4)
        if m.group(4) is not None:
            try:
                fval = float(raw)
                attrs[key] = int(fval) if fval == int(fval) else fval
            except (ValueError, TypeError):
                attrs[key] = raw
        else:
            attrs[key] = raw
    return attrs


def extract_tags_from_lines(lines: List[str]) -> List[Dict[str, Any]]:
    """Extract all Markdoc tag occurrences from a list of lines.

    Returns a list of tag dicts with keys: tag, attrs, line, is_close,
    is_self_close.  Ordering is document order (line ascending, then
    left-to-right within each line).

    Multi-line tags ({% ... spanning lines ... %}) are not supported and are
    silently skipped.
    """
    tags: List[Dict[str, Any]] = []
    tag_name_re = re.compile(r'^[a-zA-Z][a-zA-Z0-9_-]*$')

    for line_idx, raw_line in enumerate(lines):
        rest = raw_line
        while '{%' in rest:
            _, _, rest = rest.partition('{%')
            if '%}' not in rest:
                break  # no closing %} on this line — multi-line tag, skip

            inner, _, rest = rest.partition('%}')
            inner = inner.strip()

            is_close = inner.startswith('/')
            if is_close:
                inner = inner[1:].strip()

            is_self_close = inner.endswith('/')
            if is_self_close:
                inner = inner[:-1].strip()

            # Extract tag name (first whitespace-delimited token)
            name_and_attrs = inner.split(None, 1)
            if not name_and_attrs:
                continue
            tag_name = name_and_attrs[0]
            if not tag_name_re.match(tag_name):
                continue

            attrs_str = name_and_attrs[1] if len(name_and_attrs) > 1 else ''
            # Closing tags never carry meaningful attrs
            attrs = parse_markdoc_attrs(attrs_str) if attrs_str and not is_close else {}

            tags.append({
                'tag': tag_name,
                'attrs': attrs,
                'line': line_idx,
                'is_close': is_close,
                'is_self_close': is_self_close,
            })

    return tags


# Tag names that are always inline (per Markdoc schema scope_rules)
_INLINE_ONLY_TAGS = frozenset({'citation', 'link'})


def classify_tag_scope(
    tag_entry: Dict[str, Any],
    first_heading_line: Optional[int],
) -> str:
    """Return 'file', 'section', or 'inline' for a non-closing tag entry.

    Priority order:
    1. Citation / link tags → always 'inline'.
    2. Tags with an explicit ``scope`` attribute → honour it.
    3. Tags appearing before the first heading in content → 'file'.
    4. All others → 'section'.
    """
    tag = tag_entry['tag']
    attrs = tag_entry.get('attrs', {})
    line = tag_entry['line']

    if tag in _INLINE_ONLY_TAGS:
        return 'inline'

    explicit_scope = attrs.get('scope')
    if explicit_scope in ('file', 'section', 'inline'):
        return str(explicit_scope)

    # Positional heuristic: before the first heading → file-scope
    if first_heading_line is None or line < first_heading_line:
        return 'file'

    return 'section'


# ---------------------------------------------------------------------------
# Higher-level helpers — PageIndex metadata lifting (used by pageindex-generator.py)
# ---------------------------------------------------------------------------

def first_heading_line(content_lines: List[str]) -> Optional[int]:
    """Return the 0-indexed line of the first heading in content, or None."""
    for i, line in enumerate(content_lines):
        if re.match(r'^#{1,6}\s', line.strip()):
            return i
    return None


def build_file_metadata(file_tags: List[Dict[str, Any]]) -> Dict[str, Any]:
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


def build_cross_references(
    citation_tags: List[Dict[str, Any]],
) -> List[Dict[str, Any]]:
    """Return a cross_references list from non-closing citation tag entries."""
    return [dict(e['attrs']) for e in citation_tags if e.get('attrs')]


def assign_tags_to_sections(
    section_tags: List[Dict[str, Any]],
    sections: List[Dict[str, Any]],
) -> Dict[int, Dict[str, Any]]:
    """Map section-scope tags to the flat section index they belong to.

    A tag at content line *L* belongs to section *I* when:
    ``sections[I].line_idx <= L < sections[I+1].line_idx``
    (for the last section the upper bound is infinity).

    Returns ``{section_idx: {tag_name: attrs}}``.
    Same-tag-name last-wins within each section.
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


def extract_and_classify_tags(
    content_lines: List[str],
    sections: List[Dict[str, Any]],
) -> Tuple[Dict[str, Any], Dict[int, Dict[str, Any]], List[Dict[str, Any]]]:
    """Extract Markdoc tags and classify them for PageIndex metadata injection.

    Returns a 3-tuple:
      file_metadata     — dict to inject into the root tree node ``metadata``
      section_metadata  — {section_idx: {tag_name: attrs}} for subtree nodes
      cross_references  — list of citation attrs for the root ``cross_references``
    """
    all_tags = extract_tags_from_lines(content_lines)
    first_hdg = first_heading_line(content_lines)

    file_tags: List[Dict[str, Any]] = []
    section_tags_raw: List[Dict[str, Any]] = []
    citation_tags: List[Dict[str, Any]] = []

    for tag in all_tags:
        # Skip closing tags — structural, not metadata carriers
        if tag.get('is_close'):
            continue
        if tag['tag'] == 'citation':
            citation_tags.append(tag)
            continue  # citations are always inline; skip file/section buckets
        scope = classify_tag_scope(tag, first_hdg)
        if scope == 'file':
            file_tags.append(tag)
        elif scope == 'section':
            section_tags_raw.append(tag)

    return (
        build_file_metadata(file_tags),
        assign_tags_to_sections(section_tags_raw, sections),
        build_cross_references(citation_tags),
    )
