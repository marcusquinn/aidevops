#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Pure JWZ-style graph reconstruction for email source metadata.

Source discovery, incremental state, index persistence and CLI handling live in
email_thread.py. This module only transforms already-loaded source entries.
"""

import hashlib
import re
from collections import defaultdict
from typing import Optional


_RE_PREFIXES = re.compile(
    r"^(Re|RE|Fwd|FWD|Fw|AW|WG|SV|Vs|FYI|TR|Réf|Ref)[:\s]+",
    re.IGNORECASE,
)


def _normalise_subject(subject: str) -> str:
    """Strip Re:/Fwd: prefixes, lowercase, strip whitespace."""
    s = subject or ""
    prev = None
    while s != prev:
        prev = s
        s = _RE_PREFIXES.sub("", s).strip()
    return s.lower().strip()


def _parent_message_id(entry: dict, by_message_id: dict) -> Optional[str]:
    """Determine the parent message-id for JWZ threading.

    Priority:
      1. in_reply_to (if present and known)
      2. Last entry in References (if present and known)
    """
    irt = entry.get("in_reply_to", "").strip()
    if irt and irt in by_message_id:
        return irt

    refs = entry.get("references", "").strip()
    if refs:
        # References is space-separated list; last entry is closest parent
        ref_ids = refs.split()
        for ref in reversed(ref_ids):
            ref = ref.strip("<>")
            if ref in by_message_id:
                return ref
    return None


def _thread_id_from_root(root_entry: dict) -> str:
    """Generate a stable thread-id from the root message.

    Preference order: message_id → sha256(subject) → source_id
    """
    mid = root_entry.get("message_id", "").strip()
    if mid:
        # Sanitise message-id for use as filename
        safe = re.sub(r"[^\w@.\-]", "_", mid.strip("<>"))
        return safe

    subject = root_entry.get("subject", "").strip()
    if subject:
        h = hashlib.sha256(_normalise_subject(subject).encode()).hexdigest()[:16]
        return f"subj-{h}"

    return f"src-{root_entry['source_id']}"


def _build_index_and_links(
    sources: list[dict],
) -> tuple[dict, dict, dict]:
    """Build message-id index, parent-map, and children-map.

    Returns (by_message_id, parent_map, children_map).
    """
    by_message_id: dict[str, dict] = {
        e.get("message_id", "").strip(): e
        for e in sources
        if e.get("message_id", "").strip()
    }
    parent_map: dict[str, Optional[str]] = {}
    children_map: dict[str, list[str]] = defaultdict(list)
    for entry in sources:
        parent_mid = _parent_message_id(entry, by_message_id)
        parent_map[entry["source_id"]] = parent_mid
        if parent_mid:
            children_map[parent_mid].append(entry["source_id"])
    return by_message_id, parent_map, children_map


def _merge_orphans_by_subject(
    roots: list[dict],
    children_map: dict,
    parent_map: dict,
) -> list[dict]:
    """Group orphan roots by normalised subject; returns final true_roots list."""
    by_subject: dict[str, list[dict]] = defaultdict(list)
    true_roots: list[dict] = []
    for entry in roots:
        norm_subj = _normalise_subject(entry.get("subject", ""))
        if norm_subj:
            by_subject[norm_subj].append(entry)
        else:
            true_roots.append(entry)
    for _ns, group in by_subject.items():
        if len(group) == 1:
            true_roots.append(group[0])
            continue
        group_sorted = sorted(group, key=lambda e: e.get("date", ""))
        subj_root = group_sorted[0]
        true_roots.append(subj_root)
        if subj_root.get("message_id"):
            for sibling in group_sorted[1:]:
                children_map[subj_root["message_id"]].append(sibling["source_id"])
                parent_map[sibling["source_id"]] = subj_root["message_id"]
    return true_roots


def _traverse_tree(
    entry: dict,
    children_map: dict,
    by_source_id: dict,
) -> list[dict]:
    """DFS traversal returning ordered list of source entries."""
    result = [entry]
    kids = children_map.get(entry.get("message_id", ""), [])
    kids_sorted = sorted(
        [by_source_id[sid] for sid in kids if sid in by_source_id],
        key=lambda e: e.get("date", ""),
    )
    for child in kids_sorted:
        result.extend(_traverse_tree(child, children_map, by_source_id))
    return result


def _make_thread_record(thread_id: str, ordered: list[dict]) -> dict:
    """Build a thread record dict from an ordered list of source entries."""
    participants = list(dict.fromkeys(e["from"] for e in ordered if e.get("from")))
    root_subject = ordered[0].get("subject", "") if ordered else ""
    return {
        "thread_id": thread_id,
        "root_subject": root_subject,
        "participants": participants,
        "sources": [
            {
                "source_id": e["source_id"],
                "message_id": e.get("message_id", ""),
                "date": e.get("date", ""),
                "from": e.get("from", ""),
            }
            for e in ordered
        ],
    }


def build_thread_graph(sources: list[dict]) -> dict[str, dict]:
    """Build a thread graph using JWZ algorithm.

    Returns dict mapping thread_id → thread record:
    {
        "thread_id": str,
        "root_subject": str,
        "participants": [str],
        "sources": [{"source_id", "message_id", "date", "from"}, ...]  # chronological
    }
    """
    _by_mid, parent_map, children_map = _build_index_and_links(sources)
    roots = [e for e in sources if not parent_map.get(e["source_id"])]
    true_roots = _merge_orphans_by_subject(roots, children_map, parent_map)
    by_source_id: dict[str, dict] = {e["source_id"]: e for e in sources}

    threads: dict[str, dict] = {}
    for root in true_roots:
        ordered = _traverse_tree(root, children_map, by_source_id)
        thread_id = _thread_id_from_root(root)
        threads[thread_id] = _make_thread_record(thread_id, ordered)

    return threads
