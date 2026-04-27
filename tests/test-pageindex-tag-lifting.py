#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
tests/test-pageindex-tag-lifting.py — Unit tests for t2972 PageIndex tag lifting.

Verifies that Markdoc tag attributes are injected into the correct tree-node
``metadata`` fields and that citation tags produce a ``cross_references`` array
at the document root.

Usage:  python3 tests/test-pageindex-tag-lifting.py
Exit:   0 all pass, 1 any fail
"""

import sys
import os
import json

# Resolve the scripts directory so we can import the modules under test.
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_SCRIPTS_DIR = os.path.join(_REPO_ROOT, '.agents', 'scripts')
sys.path.insert(0, _SCRIPTS_DIR)

from pageindex_helpers import parse_tag_attrs, extract_markdoc_tags  # noqa: E402

# pageindex-generator.py uses a hyphen — load via importlib.
import importlib.util  # noqa: E402
_spec = importlib.util.spec_from_file_location(
    'pageindex_generator',
    os.path.join(_SCRIPTS_DIR, 'pageindex-generator.py'),
)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
build_pageindex_tree = _mod.build_pageindex_tree

PASS_COUNT = 0
FAIL_COUNT = 0


def _pass(desc: str) -> None:
    global PASS_COUNT
    PASS_COUNT += 1
    print(f"  PASS  {desc}")


def _fail(desc: str, reason: str = "") -> None:
    global FAIL_COUNT
    FAIL_COUNT += 1
    print(f"  FAIL  {desc}")
    if reason:
        print(f"        {reason}")


def assert_equal(actual, expected, desc: str) -> None:
    if actual == expected:
        _pass(desc)
    else:
        _fail(desc, f"expected {expected!r}, got {actual!r}")


def assert_in(key, container, desc: str) -> None:
    if key in container:
        _pass(desc)
    else:
        _fail(desc, f"{key!r} not in {container!r}")


def assert_not_in(key, container, desc: str) -> None:
    if key not in container:
        _pass(desc)
    else:
        _fail(desc, f"{key!r} unexpectedly in {container!r}")


# ---------------------------------------------------------------------------
# parse_tag_attrs
# ---------------------------------------------------------------------------

def test_parse_tag_attrs_double_quoted():
    attrs = parse_tag_attrs('tier="privileged" scope="file"')
    assert_equal(attrs.get('tier'), 'privileged', "parse_tag_attrs: double-quoted tier")
    assert_equal(attrs.get('scope'), 'file', "parse_tag_attrs: double-quoted scope")


def test_parse_tag_attrs_numeric():
    attrs = parse_tag_attrs('confidence=0.95')
    assert_equal(attrs.get('confidence'), 0.95, "parse_tag_attrs: float coercion")


def test_parse_tag_attrs_bare_int():
    attrs = parse_tag_attrs('page=42')
    assert_equal(attrs.get('page'), 42, "parse_tag_attrs: int coercion")


def test_parse_tag_attrs_empty():
    attrs = parse_tag_attrs('')
    assert_equal(attrs, {}, "parse_tag_attrs: empty string yields empty dict")


def test_parse_tag_attrs_hyphenated_key():
    attrs = parse_tag_attrs('source-id="exhibit-A"')
    assert_equal(attrs.get('source-id'), 'exhibit-A', "parse_tag_attrs: hyphenated key")


# ---------------------------------------------------------------------------
# extract_markdoc_tags
# ---------------------------------------------------------------------------

def test_extract_self_closing():
    lines = ['{% sensitivity tier="privileged" /%}']
    tags = extract_markdoc_tags(lines)
    assert_equal(len(tags), 1, "extract: one tag from one line")
    assert_equal(tags[0]['tag'], 'sensitivity', "extract: tag name")
    assert_equal(tags[0]['is_self_close'], True, "extract: is_self_close")
    assert_equal(tags[0]['is_close'], False, "extract: not is_close")
    assert_equal(tags[0]['attrs'].get('tier'), 'privileged', "extract: tier attr")


def test_extract_opening_and_closing():
    lines = ['{% sensitivity tier="internal" %}', 'content', '{% /sensitivity %}']
    tags = extract_markdoc_tags(lines)
    open_tags = [t for t in tags if not t['is_close']]
    close_tags = [t for t in tags if t['is_close']]
    assert_equal(len(open_tags), 1, "extract: one open tag")
    assert_equal(len(close_tags), 1, "extract: one close tag")
    assert_equal(close_tags[0]['attrs'], {}, "extract: close tag has empty attrs")


def test_extract_multiple_tags_on_one_line():
    lines = ['{% provenance source-id="a" extracted-at="2026-01-01" %} text {% /provenance %}']
    tags = extract_markdoc_tags(lines)
    assert_equal(len(tags), 2, "extract: two tags on one line")
    assert_equal(tags[0]['line_num'], 0, "extract: correct line_num")


def test_extract_no_tags():
    lines = ['# Heading', 'plain text']
    tags = extract_markdoc_tags(lines)
    assert_equal(tags, [], "extract: no tags in plain markdown")


# ---------------------------------------------------------------------------
# build_pageindex_tree — tag injection
# ---------------------------------------------------------------------------

def _make_source_md_lines(body: str) -> list:
    """Split a multi-line string into a list of lines (no trailing newline)."""
    return body.splitlines()


FILE_SCOPE_SOURCE = """\
{% sensitivity tier="privileged" scope="file" /%}
{% provenance source-id="contract-2026.pdf" extracted-at="2026-04-27" /%}

# Contract Review

This section covers the main contract.

## Delivery Terms

Delivery is expected by Q3 {% citation source-id="contract-2026.pdf" page="p.4" confidence=1.0 /%}.
"""

SECTION_SCOPE_SOURCE = """\
# Document Root

Intro paragraph.

## Section A

{% sensitivity tier="confidential" scope="section" %}
Confidential content here.
{% /sensitivity %}

## Section B

Public content.
"""

HEADINGLESS_SOURCE = """\
{% sensitivity tier="internal" /%}
{% provenance source-id="memo-001.txt" extracted-at="2026-04-01" /%}

This is a flat document with no headings at all.
"""


def test_file_scope_tag_on_root_node():
    """File-scope sensitivity tag must appear in root node metadata."""
    lines = _make_source_md_lines(FILE_SCOPE_SOURCE)
    result = build_pageindex_tree(lines, False, 'llama3.2:1b', '', 0)
    tree = result['tree']
    assert_in('metadata', tree, "file-scope: root node has metadata")
    meta = tree['metadata']
    assert_in('sensitivity', meta, "file-scope: sensitivity in root metadata")
    assert_equal(
        meta['sensitivity'].get('tier'), 'privileged',
        "file-scope: sensitivity.tier == 'privileged'"
    )


def test_file_scope_provenance_on_root_node():
    """File-scope provenance tag must appear in root node metadata."""
    lines = _make_source_md_lines(FILE_SCOPE_SOURCE)
    result = build_pageindex_tree(lines, False, 'llama3.2:1b', '', 0)
    meta = result['tree']['metadata']
    assert_in('provenance', meta, "provenance in root metadata")
    assert_equal(
        meta['provenance'].get('source-id'), 'contract-2026.pdf',
        "provenance source-id correct"
    )


def test_section_scope_tag_on_child_not_root():
    """Section-scope tag must appear on the child node, not the root."""
    lines = _make_source_md_lines(SECTION_SCOPE_SOURCE)
    result = build_pageindex_tree(lines, False, 'llama3.2:1b', '', 0)
    tree = result['tree']
    # Root metadata must NOT contain sensitivity
    root_meta = tree.get('metadata', {})
    assert_not_in('sensitivity', root_meta, "section-scope: sensitivity NOT on root")
    # Find child node titled "Section A"
    section_a = next(
        (c for c in tree.get('children', []) if c['title'] == 'Section A'),
        None
    )
    if section_a is None:
        _fail("section-scope: Section A node found", "Section A child missing from tree")
        return
    child_meta = section_a.get('metadata', {})
    assert_in('sensitivity', child_meta, "section-scope: sensitivity on Section A node")
    assert_equal(
        child_meta['sensitivity'].get('tier'), 'confidential',
        "section-scope: sensitivity.tier == 'confidential'"
    )


def test_citation_produces_cross_references():
    """Citation tags must produce a cross_references array at document root."""
    lines = _make_source_md_lines(FILE_SCOPE_SOURCE)
    result = build_pageindex_tree(lines, False, 'llama3.2:1b', '', 0)
    assert_in('cross_references', result, "cross_references key present at document root")
    refs = result['cross_references']
    assert_equal(len(refs), 1, "cross_references has one entry")
    assert_equal(refs[0].get('source-id'), 'contract-2026.pdf', "citation source-id correct")
    assert_equal(refs[0].get('page'), 'p.4', "citation page correct")
    assert_equal(refs[0].get('confidence'), 1.0, "citation confidence correct")


def test_no_cross_references_when_no_citations():
    """Document with no citation tags must not have a cross_references key."""
    lines = _make_source_md_lines(SECTION_SCOPE_SOURCE)
    result = build_pageindex_tree(lines, False, 'llama3.2:1b', '', 0)
    assert_not_in('cross_references', result, "no cross_references when no citation tags")


def test_headingless_document_tag_on_root():
    """Tags in a headingless document must appear on the single root node."""
    lines = _make_source_md_lines(HEADINGLESS_SOURCE)
    result = build_pageindex_tree(lines, False, 'llama3.2:1b', '', 0)
    tree = result['tree']
    meta = tree.get('metadata', {})
    assert_in('sensitivity', meta, "headingless: sensitivity on root node")
    assert_equal(meta['sensitivity'].get('tier'), 'internal', "headingless: tier == 'internal'")
    assert_in('provenance', meta, "headingless: provenance on root node")


def test_no_internal_line_fields_in_output():
    """_line_start / _line_end must not appear in the final JSON output."""
    lines = _make_source_md_lines(FILE_SCOPE_SOURCE)
    result = build_pageindex_tree(lines, False, 'llama3.2:1b', '', 0)
    serialised = json.dumps(result)
    assert_not_in('_line_start', serialised, "no _line_start in serialised output")
    assert_not_in('_line_end', serialised, "no _line_end in serialised output")


def test_plain_document_has_empty_metadata():
    """A document with no Markdoc tags must have an empty metadata dict (not absent)."""
    lines = _make_source_md_lines("# My Doc\n\nNo tags here.\n")
    result = build_pageindex_tree(lines, False, 'llama3.2:1b', '', 0)
    tree = result['tree']
    assert_in('metadata', tree, "plain doc: metadata key present")
    assert_equal(tree['metadata'], {}, "plain doc: metadata is empty dict")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    print("=== pageindex tag-lifting tests (t2972) ===")

    test_parse_tag_attrs_double_quoted()
    test_parse_tag_attrs_numeric()
    test_parse_tag_attrs_bare_int()
    test_parse_tag_attrs_empty()
    test_parse_tag_attrs_hyphenated_key()

    test_extract_self_closing()
    test_extract_opening_and_closing()
    test_extract_multiple_tags_on_one_line()
    test_extract_no_tags()

    test_file_scope_tag_on_root_node()
    test_file_scope_provenance_on_root_node()
    test_section_scope_tag_on_child_not_root()
    test_citation_produces_cross_references()
    test_no_cross_references_when_no_citations()
    test_headingless_document_tag_on_root()
    test_no_internal_line_fields_in_output()
    test_plain_document_has_empty_metadata()

    print(f"\n{PASS_COUNT} passed, {FAIL_COUNT} failed")
    return 0 if FAIL_COUNT == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
