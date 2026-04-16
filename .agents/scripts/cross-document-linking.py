#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Cross-document linking for email markdown collections (t1049.11).

Adds `related_docs:` frontmatter field with references to:
- Attachments (files in the same-named attachment folder)
- Thread siblings (emails with matching thread_id or message_id chains)
- Documents mentioning the same entities

Also adds navigation links at the bottom of each markdown file.

Usage:
    cross-document-linking.py <directory> [--dry-run] [--min-shared-entities N]

Part of aidevops framework: https://aidevops.sh
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Optional

# Add lib directory to path for shared utilities
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'lib'))
from doc_linking import (
    Document,
    build_thread_relationships,
    build_entity_relationships,
    build_attachment_relationships,
)


# ---------------------------------------------------------------------------
# Frontmatter parsing
# ---------------------------------------------------------------------------

def _parse_inline_list(value: str) -> list[str]:
    """Parse a YAML inline list like [item1, item2, item3]."""
    items = value.strip()[1:-1].split(",")
    return [item.strip() for item in items if item.strip()]


def _split_key_value(line: str) -> tuple[str, str]:
    """Split a YAML line into key and value parts."""
    if ": " in line:
        key, value = line.split(": ", 1)
    else:
        key = line.rstrip(":")
        value = ""
    return key.strip(), value


def _process_yaml_value(fm_dict: dict, key: str, value: str) -> Optional[str]:
    """Process a YAML value, returning the current_key if expecting list items."""
    stripped = value.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        fm_dict[key] = _parse_inline_list(stripped)
        return None
    if stripped:
        fm_dict[key] = stripped
        return None
    return key


def parse_frontmatter(content: str) -> tuple[dict, str, str]:
    """Parse YAML frontmatter from markdown content.

    Returns (frontmatter_dict, frontmatter_text, body).
    """
    if not content.startswith("---"):
        return ({}, "", content)

    end = content.find("\n---", 3)
    if end == -1:
        return ({}, "", content)

    fm_text = content[4:end]
    body = content[end + 4:].lstrip()

    fm_dict: dict = {}
    current_key: Optional[str] = None
    current_list: list[str] = []

    for line in fm_text.split("\n"):
        if line.strip().startswith("- "):
            if current_key:
                current_list.append(line.strip()[2:])
            continue

        if ":" not in line or line.startswith(" "):
            continue

        if current_key and current_list:
            fm_dict[current_key] = current_list
            current_list = []

        key, value = _split_key_value(line)
        current_key = _process_yaml_value(fm_dict, key, value)

    if current_key and current_list:
        fm_dict[current_key] = current_list

    return (fm_dict, fm_text, body)


# ---------------------------------------------------------------------------
# Frontmatter serialization
# ---------------------------------------------------------------------------

def _serialize_nested_dict(key: str, value: dict) -> list[str]:
    """Serialize a nested dict (like related_docs) to YAML lines."""
    lines = [f"{key}:"]
    for subkey, subvalue in value.items():
        if isinstance(subvalue, list):
            if not subvalue:
                continue
            lines.append(f"  {subkey}:")
            for item in subvalue:
                lines.append(f"    - {item}")
        else:
            lines.append(f"  {subkey}: {subvalue}")
    return lines


def _serialize_list(key: str, value: list) -> list[str]:
    """Serialize a list value to YAML lines."""
    if not value:
        return []
    lines = [f"{key}:"]
    for item in value:
        lines.append(f"  - {item}")
    return lines


def serialize_frontmatter(fm_dict: dict) -> str:
    """Convert frontmatter dict back to YAML text."""
    lines: list[str] = []

    for key, value in fm_dict.items():
        if isinstance(value, dict):
            lines.extend(_serialize_nested_dict(key, value))
        elif isinstance(value, list):
            lines.extend(_serialize_list(key, value))
        else:
            lines.append(f"{key}: {value}")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Navigation link generation
# ---------------------------------------------------------------------------

def generate_navigation_links(doc: Document) -> str:
    """Generate navigation links section for document footer."""
    if not doc.related_docs:
        return ""

    lines = ["\n---\n", "## Related Documents\n"]

    _NAV_SECTIONS = [
        ("thread_parent", "Thread Parent"),
        ("thread_replies", "Thread Replies"),
        ("thread_siblings", "Thread Siblings"),
        ("attachments", "Attachments"),
        ("shared_entities", "Related by Entities"),
    ]

    for key, heading in _NAV_SECTIONS:
        links = doc.related_docs.get(key)
        if links:
            lines.append(f"\n**{heading}:**\n")
            for link in links:
                lines.append(f"- [{Path(link).stem}]({link})\n")

    return "".join(lines)


# ---------------------------------------------------------------------------
# Document updating
# ---------------------------------------------------------------------------

def update_document(doc: Document, dry_run: bool = False) -> bool:
    """Update document with related_docs frontmatter and navigation links.

    Returns True if document was modified.
    """
    if not doc.related_docs:
        return False

    content = doc.path.read_text()
    fm_dict, fm_text, body = parse_frontmatter(content)

    fm_dict["related_docs"] = {}
    for rel_type, links in doc.related_docs.items():
        if links:
            fm_dict["related_docs"][rel_type] = sorted(set(links))

    nav_marker = "\n---\n## Related Documents\n"
    if nav_marker in body:
        body = body.split(nav_marker)[0].rstrip()

    nav_links = generate_navigation_links(doc)

    new_fm = serialize_frontmatter(fm_dict)
    new_content = f"---\n{new_fm}\n---\n\n{body}{nav_links}"

    if dry_run:
        print(f"Would update: {doc.path}")
        return True

    doc.path.write_text(new_content)
    print(f"Updated: {doc.path}")
    return True


# ---------------------------------------------------------------------------
# Main phases
# ---------------------------------------------------------------------------

def _build_arg_parser() -> argparse.ArgumentParser:
    """Build the CLI argument parser."""
    parser = argparse.ArgumentParser(
        description="Add cross-document links to email markdown collection"
    )
    parser.add_argument(
        "directory",
        type=Path,
        help="Directory containing converted markdown files"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be done without modifying files"
    )
    parser.add_argument(
        "--min-shared-entities",
        type=int,
        default=2,
        help="Minimum shared entities to create relationship (default: 2)"
    )
    return parser


def _validate_directory(directory: Path) -> int:
    """Validate that directory exists and is a directory. Returns 0 on success."""
    if not directory.exists():
        print(f"ERROR: Directory not found: {directory}", file=sys.stderr)
        return 1
    if not directory.is_dir():
        print(f"ERROR: Not a directory: {directory}", file=sys.stderr)
        return 1
    return 0


def _discover_markdown_files(directory: Path) -> list[Path]:
    """Discover markdown files in directory, excluding raw-headers files."""
    return [
        md_file for md_file in directory.glob("*.md")
        if not md_file.stem.endswith("-raw-headers")
    ]


def _parse_documents(md_files: list[Path]) -> list[Document]:
    """Parse markdown files into Document objects, skipping unparseable files."""
    documents = []
    for md_file in md_files:
        try:
            content = md_file.read_text()
            fm_dict, _fm_text, body = parse_frontmatter(content)
            documents.append(Document(md_file, fm_dict, body))
        except Exception as e:
            print(f"WARNING: Failed to parse {md_file}: {e}", file=sys.stderr)
    return documents


def _build_all_relationships(documents: list[Document], min_shared_entities: int) -> None:
    """Build all relationship types between documents."""
    print("Building thread relationships...")
    build_thread_relationships(documents)

    print("Building attachment relationships...")
    build_attachment_relationships(documents)

    print(f"Building entity relationships (min shared: {min_shared_entities})...")
    build_entity_relationships(documents, min_shared_entities)


def _update_all_documents(documents: list[Document], dry_run: bool) -> int:
    """Update all documents with relationship links. Returns count of updated."""
    updated_count = 0
    for doc in documents:
        if update_document(doc, dry_run=dry_run):
            updated_count += 1
    return updated_count


def main() -> int:
    """Link-discovery, link-validation, and link-insertion pipeline coordinator."""
    args = _build_arg_parser().parse_args()

    if _validate_directory(args.directory) != 0:
        return 1

    md_files = _discover_markdown_files(args.directory)
    if not md_files:
        print(f"No markdown files found in {args.directory}")
        return 0

    print(f"Found {len(md_files)} markdown files")

    documents = _parse_documents(md_files)
    print(f"Parsed {len(documents)} documents")

    _build_all_relationships(documents, args.min_shared_entities)

    updated_count = _update_all_documents(documents, args.dry_run)
    print(f"\n{'Would update' if args.dry_run else 'Updated'} {updated_count} documents")

    return 0


if __name__ == "__main__":
    sys.exit(main())
