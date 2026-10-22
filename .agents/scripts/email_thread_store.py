#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Source metadata, incremental state and JSON indexes for email threads.

Graph reconstruction is deliberately separate from filesystem operations.
email_thread.py owns build ordering and the supported CLI.
"""

import json
import re
from pathlib import Path
from typing import Optional


def _load_email_sources(sources_dir: Path) -> list[dict]:
    """Load all email meta.json files from sources_dir recursively.

    Returns a list of dicts with at least: source_id, message_id, in_reply_to,
    references, subject, from, date, _meta_path, _mtime.
    """
    sources = []
    for meta_file in sources_dir.rglob("meta.json"):
        try:
            with open(meta_file, encoding="utf-8") as f:
                meta = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue

        if meta.get("kind") not in ("email", "email-export", None):
            # Only process email kinds; skip documents, datasets, etc.
            # kind=None: assume email when message_id present
            if meta.get("kind") is not None and not meta.get("message_id"):
                continue

        source_id = meta.get("id") or meta_file.parent.name
        entry = {
            "source_id": source_id,
            "message_id": (meta.get("message_id") or "").strip(),
            "in_reply_to": (meta.get("in_reply_to") or "").strip(),
            "references": (meta.get("references") or "").strip(),
            "subject": (meta.get("subject") or meta.get("title") or "").strip(),
            "from": (meta.get("from") or meta.get("sender") or "").strip(),
            "date": (meta.get("date") or meta.get("ingested_at") or "").strip(),
            "_meta_path": str(meta_file),
            "_mtime": meta_file.stat().st_mtime,
        }
        sources.append(entry)
    return sources


def _load_state(state_file: Path) -> dict:
    """Load build state: {source_id: mtime}."""
    if state_file.exists():
        try:
            with open(state_file, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, json.JSONDecodeError):
            pass
    return {}


def _save_state(state_file: Path, sources: list[dict]) -> None:
    """Save current mtime state for each processed source."""
    state = {e["source_id"]: e["_mtime"] for e in sources}
    state_file.parent.mkdir(parents=True, exist_ok=True)
    with open(state_file, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)


def _sources_changed_since(
    sources: list[dict], state: dict
) -> bool:
    """Return True if any source has changed since last build."""
    for entry in sources:
        sid = entry["source_id"]
        if sid not in state:
            return True
        if abs(entry["_mtime"] - state[sid]) > 0.01:
            return True
    if len(sources) != len(state):
        return True
    return False


def _thread_index_path(index_dir: Path, thread_id: str) -> Path:
    """Return the JSON index path for a given thread_id."""
    safe_id = re.sub(r"[^\w@.\-]", "_", thread_id)[:200]
    return index_dir / f"{safe_id}.json"


def write_thread_indexes(threads: dict[str, dict], index_dir: Path) -> int:
    """Write one JSON file per thread to index_dir. Returns count written."""
    index_dir.mkdir(parents=True, exist_ok=True)
    written = 0
    for thread_id, thread_data in threads.items():
        path = _thread_index_path(index_dir, thread_id)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(thread_data, f, indent=2)
        written += 1
    return written


def get_thread_for_message_id(
    knowledge_root: str,
    message_id: str,
) -> Optional[dict]:
    """Look up a thread by message-id.

    Searches all thread index files for the given message_id.
    Returns the thread record or None.
    """
    root = Path(knowledge_root)
    index_dir = root / "index" / "email-threads"

    if not index_dir.exists():
        return None

    for idx_file in index_dir.glob("*.json"):
        try:
            with open(idx_file, encoding="utf-8") as f:
                thread = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue

        for source in thread.get("sources", []):
            if source.get("message_id", "").strip() == message_id.strip():
                return thread

    return None


def get_thread_for_source_id(
    knowledge_root: str,
    source_id: str,
) -> Optional[dict]:
    """Look up a thread by source_id."""
    root = Path(knowledge_root)
    index_dir = root / "index" / "email-threads"

    if not index_dir.exists():
        return None

    for idx_file in index_dir.glob("*.json"):
        try:
            with open(idx_file, encoding="utf-8") as f:
                thread = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue

        for source in thread.get("sources", []):
            if source.get("source_id", "") == source_id:
                return thread

    return None
