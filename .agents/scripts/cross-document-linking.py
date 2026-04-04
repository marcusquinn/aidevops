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
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Optional


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
    """Process a YAML value, returning the current_key if expecting list items.
    
    Returns the key to track for subsequent list items, or None if value was stored.
    """
    stripped = value.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        fm_dict[key] = _parse_inline_list(stripped)
        return None
    if stripped:
        fm_dict[key] = stripped
        return None
    # Empty value — keep key for potential list items
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
        # List item
        if line.strip().startswith("- "):
            if current_key:
                current_list.append(line.strip()[2:])
            continue
        
        # Key-value pair (handle both "key: value" and "key:")
        if ":" not in line or line.startswith(" "):
            continue
        
        # Save previous list if any
        if current_key and current_list:
            fm_dict[current_key] = current_list
            current_list = []
        
        key, value = _split_key_value(line)
        current_key = _process_yaml_value(fm_dict, key, value)
    
    # Save final list if any
    if current_key and current_list:
        fm_dict[current_key] = current_list
    
    return (fm_dict, fm_text, body)


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
# Document analysis
# ---------------------------------------------------------------------------

class Document:
    """Represents a markdown document with metadata."""
    
    def __init__(self, path: Path, frontmatter: dict, body: str):
        self.path = path
        self.frontmatter = frontmatter
        self.body = body
        self.related_docs: dict[str, list[str]] = defaultdict(list)
    
    @property
    def message_id(self) -> Optional[str]:
        return self.frontmatter.get("message_id")
    
    @property
    def in_reply_to(self) -> Optional[str]:
        return self.frontmatter.get("in_reply_to")
    
    @property
    def thread_id(self) -> Optional[str]:
        return self.frontmatter.get("thread_id")
    
    @property
    def attachments(self) -> list[str]:
        att = self.frontmatter.get("attachments", [])
        if isinstance(att, str):
            return [att]
        return att if isinstance(att, list) else []
    
    @property
    def entities(self) -> dict[str, list[str]]:
        """Get entities dict from frontmatter."""
        entities = {}
        
        # Check for entities field (could be nested)
        if "entities" in self.frontmatter:
            ent = self.frontmatter["entities"]
            if isinstance(ent, dict):
                return ent
        
        # Check for individual entity type fields
        for entity_type in ["people", "organisations", "properties", "locations", "dates"]:
            if entity_type in self.frontmatter:
                val = self.frontmatter[entity_type]
                if isinstance(val, list):
                    entities[entity_type] = val
                elif isinstance(val, str):
                    entities[entity_type] = [val]
        
        return entities
    
    def get_all_entities(self) -> set[str]:
        """Get flat set of all entity values."""
        all_entities = set()
        for entity_list in self.entities.values():
            all_entities.update(entity_list)
        return all_entities


def find_attachment_folder(doc_path: Path) -> Optional[Path]:
    """Find the attachment folder for a document.
    
    Convention: {YYYY-MM-DD-HHMMSS}-{subject}-{sender}/ folder
    matches {YYYY-MM-DD-HHMMSS}-{subject}-{sender}.md file.
    """
    # Remove .md extension to get base name
    base_name = doc_path.stem
    
    # Look for matching folder in same directory
    attachment_dir = doc_path.parent / base_name
    
    if attachment_dir.exists() and attachment_dir.is_dir():
        return attachment_dir
    
    return None


def find_attachment_documents(doc: Document) -> list[Path]:
    """Find converted markdown files in the attachment folder."""
    attachment_dir = find_attachment_folder(doc.path)
    if not attachment_dir:
        return []
    
    # Find all .md files in the attachment folder
    md_files = list(attachment_dir.glob("*.md"))
    
    # Exclude raw headers files
    return [f for f in md_files if not f.stem.endswith("-raw-headers")]


# ---------------------------------------------------------------------------
# Relationship building
# ---------------------------------------------------------------------------

def _find_thread_parent(doc: Document, by_message_id: dict) -> None:
    """Link doc to its parent via in_reply_to."""
    if not doc.in_reply_to or doc.in_reply_to not in by_message_id:
        return
    parent = by_message_id[doc.in_reply_to]
    rel_path = parent.path.relative_to(doc.path.parent)
    doc.related_docs["thread_parent"].append(str(rel_path))


def _find_thread_replies(doc: Document, documents: list[Document]) -> None:
    """Link doc to documents that reply to it."""
    if not doc.message_id:
        return
    for other in documents:
        if other.in_reply_to == doc.message_id and other.path != doc.path:
            rel_path = other.path.relative_to(doc.path.parent)
            doc.related_docs["thread_replies"].append(str(rel_path))


def _find_thread_siblings(doc: Document, by_thread_id: dict) -> None:
    """Link doc to sibling documents in the same thread."""
    if not doc.thread_id or doc.thread_id not in by_thread_id:
        return
    for sibling in by_thread_id[doc.thread_id]:
        if sibling.path != doc.path:
            rel_path = sibling.path.relative_to(doc.path.parent)
            doc.related_docs["thread_siblings"].append(str(rel_path))


def build_thread_relationships(documents: list[Document]) -> None:
    """Build thread relationships between documents."""
    # Index by message_id for quick lookup
    by_message_id = {doc.message_id: doc for doc in documents if doc.message_id}
    
    # Index by thread_id
    by_thread_id = defaultdict(list)
    for doc in documents:
        if doc.thread_id:
            by_thread_id[doc.thread_id].append(doc)
    
    for doc in documents:
        _find_thread_parent(doc, by_message_id)
        _find_thread_replies(doc, documents)
        _find_thread_siblings(doc, by_thread_id)


def _count_shared_entities(doc: Document, by_entity: dict) -> dict:
    """Count how many entities each other document shares with doc."""
    doc_entities = doc.get_all_entities()
    shared_counts: dict = defaultdict(int)
    for entity in doc_entities:
        for other in by_entity[entity]:
            if other.path != doc.path:
                shared_counts[other] += 1
    return shared_counts


def build_entity_relationships(documents: list[Document], min_shared: int = 2) -> None:
    """Build relationships based on shared entities."""
    # Index documents by entity
    by_entity: dict = defaultdict(list)
    
    for doc in documents:
        for entity in doc.get_all_entities():
            by_entity[entity].append(doc)
    
    for doc in documents:
        if not doc.get_all_entities():
            continue
        
        shared_counts = _count_shared_entities(doc, by_entity)
        
        for other, count in shared_counts.items():
            if count >= min_shared:
                rel_path = other.path.relative_to(doc.path.parent)
                doc.related_docs["shared_entities"].append(str(rel_path))


def build_attachment_relationships(documents: list[Document]) -> None:
    """Build relationships to attachment documents."""
    for doc in documents:
        attachment_docs = find_attachment_documents(doc)
        
        for att_doc in attachment_docs:
            rel_path = att_doc.relative_to(doc.path.parent)
            doc.related_docs["attachments"].append(str(rel_path))


# ---------------------------------------------------------------------------
# Document updating
# ---------------------------------------------------------------------------

def generate_navigation_links(doc: Document) -> str:
    """Generate navigation links section for document footer."""
    if not doc.related_docs:
        return ""
    
    lines = ["\n---\n", "## Related Documents\n"]
    
    # Thread navigation
    if doc.related_docs.get("thread_parent"):
        lines.append("\n**Thread Parent:**\n")
        for link in doc.related_docs["thread_parent"]:
            lines.append(f"- [{Path(link).stem}]({link})\n")
    
    if doc.related_docs.get("thread_replies"):
        lines.append("\n**Thread Replies:**\n")
        for link in doc.related_docs["thread_replies"]:
            lines.append(f"- [{Path(link).stem}]({link})\n")
    
    if doc.related_docs.get("thread_siblings"):
        lines.append("\n**Thread Siblings:**\n")
        for link in doc.related_docs["thread_siblings"]:
            lines.append(f"- [{Path(link).stem}]({link})\n")
    
    # Attachments
    if doc.related_docs.get("attachments"):
        lines.append("\n**Attachments:**\n")
        for link in doc.related_docs["attachments"]:
            lines.append(f"- [{Path(link).stem}]({link})\n")
    
    # Shared entities
    if doc.related_docs.get("shared_entities"):
        lines.append("\n**Related by Entities:**\n")
        for link in doc.related_docs["shared_entities"]:
            lines.append(f"- [{Path(link).stem}]({link})\n")
    
    return "".join(lines)


def update_document(doc: Document, dry_run: bool = False) -> bool:
    """Update document with related_docs frontmatter and navigation links.
    
    Returns True if document was modified.
    """
    if not doc.related_docs:
        return False
    
    # Read current content
    content = doc.path.read_text()
    fm_dict, fm_text, body = parse_frontmatter(content)
    
    # Update frontmatter with related_docs
    fm_dict["related_docs"] = {}
    for rel_type, links in doc.related_docs.items():
        if links:
            fm_dict["related_docs"][rel_type] = sorted(set(links))
    
    # Remove existing navigation section if present
    nav_marker = "\n---\n## Related Documents\n"
    if nav_marker in body:
        body = body.split(nav_marker)[0].rstrip()
    
    # Generate new navigation links
    nav_links = generate_navigation_links(doc)
    
    # Reconstruct document
    new_fm = serialize_frontmatter(fm_dict)
    new_content = f"---\n{new_fm}\n---\n\n{body}{nav_links}"
    
    if dry_run:
        print(f"Would update: {doc.path}")
        return True
    
    # Write updated content
    doc.path.write_text(new_content)
    print(f"Updated: {doc.path}")
    return True


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
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
    
    args = parser.parse_args()
    
    if not args.directory.exists():
        print(f"ERROR: Directory not found: {args.directory}", file=sys.stderr)
        return 1
    
    if not args.directory.is_dir():
        print(f"ERROR: Not a directory: {args.directory}", file=sys.stderr)
        return 1
    
    # Find all markdown files (excluding attachment folders)
    md_files = []
    for md_file in args.directory.glob("*.md"):
        # Skip raw headers files
        if md_file.stem.endswith("-raw-headers"):
            continue
        md_files.append(md_file)
    
    if not md_files:
        print(f"No markdown files found in {args.directory}")
        return 0
    
    print(f"Found {len(md_files)} markdown files")
    
    # Parse all documents
    documents = []
    for md_file in md_files:
        try:
            content = md_file.read_text()
            fm_dict, fm_text, body = parse_frontmatter(content)
            doc = Document(md_file, fm_dict, body)
            documents.append(doc)
        except Exception as e:
            print(f"WARNING: Failed to parse {md_file}: {e}", file=sys.stderr)
            continue
    
    print(f"Parsed {len(documents)} documents")
    
    # Build relationships
    print("Building thread relationships...")
    build_thread_relationships(documents)
    
    print("Building attachment relationships...")
    build_attachment_relationships(documents)
    
    print(f"Building entity relationships (min shared: {args.min_shared_entities})...")
    build_entity_relationships(documents, args.min_shared_entities)
    
    # Update documents
    updated_count = 0
    for doc in documents:
        if update_document(doc, dry_run=args.dry_run):
            updated_count += 1
    
    print(f"\n{'Would update' if args.dry_run else 'Updated'} {updated_count} documents")
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
