"""Entity-based relationship building between documents.

Extracted from doc_linking.py as part of t2130 to keep file complexity
below thresholds. Provides entity overlap detection between Document objects.
"""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

from __future__ import annotations

from collections import defaultdict


def _count_shared_entities(doc, by_entity: dict) -> dict:
    """Count how many entities each other document shares with doc."""
    doc_entities = doc.get_all_entities()
    shared_counts: dict = defaultdict(int)
    for entity in doc_entities:
        for other in by_entity[entity]:
            if other.path != doc.path:
                shared_counts[other] += 1
    return shared_counts


def build_entity_relationships(documents, min_shared: int = 2) -> None:
    """Build relationships based on shared entities between documents."""
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
