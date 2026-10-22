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
import sys
from pathlib import Path
from typing import Optional

# Keep graph and storage exports available to existing module callers. This
# module owns build ordering and the CLI; the graph has no filesystem dependencies.
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
from email_thread_store import (
    _load_email_sources as _load_email_sources,
    _load_state as _load_state,
    _save_state as _save_state,
    _sources_changed_since as _sources_changed_since,
    _thread_index_path as _thread_index_path,
    write_thread_indexes as write_thread_indexes,
    get_thread_for_message_id as get_thread_for_message_id,
    get_thread_for_source_id as get_thread_for_source_id,
)


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
