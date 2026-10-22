#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_thread.py — JWZ-style thread reconstruction over _knowledge/sources/ email meta.json files.
Part of aidevops framework: https://aidevops.sh

Reads source meta.json files for message_id, in_reply_to, references headers.
Writes thread index JSON to _knowledge/index/email-threads/<thread-id>.json.

Usage (module):
    from email_thread import build_threads, get_thread_for_message_id

Usage (CLI):
    python3 email_thread.py build   <knowledge-root> [--state <state-file>]
    python3 email_thread.py thread  <knowledge-root> <message-id>
"""

import json
import re
import sys
from pathlib import Path
from typing import Optional

# Keep graph exports available to existing module callers. The graph module has
# no filesystem dependencies; this module owns persistence and the CLI.
from email_thread_graph import (
    _RE_PREFIXES as _RE_PREFIXES,
    _normalise_subject as _normalise_subject,
    _parent_message_id as _parent_message_id,
    _thread_id_from_root as _thread_id_from_root,
    _build_index_and_links as _build_index_and_links,
    _merge_orphans_by_subject as _merge_orphans_by_subject,
    _traverse_tree as _traverse_tree,
    _make_thread_record as _make_thread_record,
    build_thread_graph as build_thread_graph,
)


# ---------------------------------------------------------------------------
# Source discovery
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Incremental state
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Index writer
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def build_threads(
    knowledge_root: str,
    state_file: Optional[str] = None,
    force: bool = False,
) -> dict:
    """Build (or rebuild) thread indexes for all email sources.

    Args:
        knowledge_root: path to _knowledge/ root directory
        state_file: path to incremental state JSON (default: knowledge_root/.email-thread-state.json)
        force: rebuild even if no sources changed

    Returns:
        {"threads": int, "sources": int, "written": int, "skipped": bool}
    """
    root = Path(knowledge_root)
    sources_dir = root / "sources"
    index_dir = root / "index" / "email-threads"

    if state_file is None:
        state_file = str(root / ".email-thread-state.json")

    state_path = Path(state_file)
    state = _load_state(state_path)

    sources = _load_email_sources(sources_dir)

    if not force and not _sources_changed_since(sources, state):
        return {"threads": 0, "sources": len(sources), "written": 0, "skipped": True}

    threads = build_thread_graph(sources)
    written = write_thread_indexes(threads, index_dir)
    _save_state(state_path, sources)

    return {
        "threads": len(threads),
        "sources": len(sources),
        "written": written,
        "skipped": False,
    }


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


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _cmd_build(args: list[str]) -> int:
    """build <knowledge-root> [--state <file>] [--force]"""
    if not args:
        print("Usage: email_thread.py build <knowledge-root> [--state <file>] [--force]",
              file=sys.stderr)
        return 1

    knowledge_root = args[0]
    state_file = None
    force = False
    i = 1
    while i < len(args):
        if args[i] == "--state" and i + 1 < len(args):
            state_file = args[i + 1]
            i += 2
        elif args[i] == "--force":
            force = True
            i += 1
        else:
            i += 1

    result = build_threads(knowledge_root, state_file=state_file, force=force)

    if result["skipped"]:
        print(f"No changes detected ({result['sources']} sources). Use --force to rebuild.")
    else:
        print(f"Processed {result['sources']} sources → {result['threads']} threads "
              f"({result['written']} index files written)")
    return 0


def _cmd_thread(args: list[str]) -> int:
    """thread <knowledge-root> <message-id-or-source-id>"""
    if len(args) < 2:
        print("Usage: email_thread.py thread <knowledge-root> <message-id>",
              file=sys.stderr)
        return 1

    knowledge_root = args[0]
    query = args[1].strip()

    # Try message-id first, then source-id
    thread = get_thread_for_message_id(knowledge_root, query)
    if thread is None:
        thread = get_thread_for_source_id(knowledge_root, query)

    if thread is None:
        print(f"No thread found for: {query}", file=sys.stderr)
        return 1

    print(json.dumps(thread, indent=2))
    return 0


def main() -> int:
    """CLI entry point."""
    args = sys.argv[1:]
    if not args:
        print(__doc__, file=sys.stderr)
        return 1

    cmd = args[0]
    rest = args[1:]

    if cmd == "build":
        return _cmd_build(rest)
    elif cmd == "thread":
        return _cmd_thread(rest)
    else:
        print(f"Unknown command: {cmd}. Use: build | thread", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
