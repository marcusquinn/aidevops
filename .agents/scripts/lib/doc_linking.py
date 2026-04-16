"""Document relationship building for cross-document linking.

Extracted from cross-document-linking.py as part of t2130 to reduce
file complexity. Provides the Document class and relationship builders
for email markdown collections.
"""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

from __future__ import annotations

from collections import defaultdict
from pathlib import Path
from typing import Optional


# ---------------------------------------------------------------------------
# Document model
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

        if "entities" in self.frontmatter:
            ent = self.frontmatter["entities"]
            if isinstance(ent, dict):
                return ent

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


# ---------------------------------------------------------------------------
# Attachment discovery
# ---------------------------------------------------------------------------

def find_attachment_folder(doc_path: Path) -> Optional[Path]:
    """Find the attachment folder for a document.

    Convention: {YYYY-MM-DD-HHMMSS}-{subject}-{sender}/ folder
    matches {YYYY-MM-DD-HHMMSS}-{subject}-{sender}.md file.
    """
    base_name = doc_path.stem
    attachment_dir = doc_path.parent / base_name

    if attachment_dir.exists() and attachment_dir.is_dir():
        return attachment_dir
    return None


def find_attachment_documents(doc: Document) -> list[Path]:
    """Find converted markdown files in the attachment folder."""
    attachment_dir = find_attachment_folder(doc.path)
    if not attachment_dir:
        return []

    md_files = list(attachment_dir.glob("*.md"))
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
    by_message_id = {doc.message_id: doc for doc in documents if doc.message_id}

    by_thread_id = defaultdict(list)
    for doc in documents:
        if doc.thread_id:
            by_thread_id[doc.thread_id].append(doc)

    for doc in documents:
        _find_thread_parent(doc, by_message_id)
        _find_thread_replies(doc, documents)
        _find_thread_siblings(doc, by_thread_id)


# Re-export entity relationships for backward compatibility
from entity_relationships import build_entity_relationships  # noqa: F401


def build_attachment_relationships(documents: list[Document]) -> None:
    """Build relationships to attachment documents."""
    for doc in documents:
        attachment_docs = find_attachment_documents(doc)

        for att_doc in attachment_docs:
            rel_path = att_doc.relative_to(doc.path.parent)
            doc.related_docs["attachments"].append(str(rel_path))
