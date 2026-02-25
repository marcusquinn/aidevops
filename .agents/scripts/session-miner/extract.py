#!/usr/bin/env python3
"""
Session Miner — Phase 1: Extract high-signal data from coding assistant sessions.

Extracts two categories of learning signal from local session databases:
1. User steerage: corrections, preferences, guidance, workflow patterns
2. Model errors: tool failures with surrounding context (what failed, what fixed it)

Output format is tool-agnostic — works with OpenCode now, adaptable to
Claude Code, Cursor, or any tool that stores session data.

All data stays local. Output goes to ~/.aidevops/.agent-workspace/work/session-miner/

Usage:
    python3 extract.py                    # Extract from default OpenCode DB
    python3 extract.py --db /path/to.db   # Custom DB path
    python3 extract.py --format jsonl     # JSONL output (default)
    python3 extract.py --format chunks    # Pre-chunked for model analysis
    python3 extract.py --limit 100        # Limit sessions processed
"""

import argparse
import json
import os
import re
import sqlite3
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Any


# --- Configuration ---

DEFAULT_DB = Path.home() / ".local/share/opencode/opencode.db"
OUTPUT_DIR = Path.home() / ".aidevops/.agent-workspace/work/session-miner"

# Steerage detection patterns — things users say when correcting/guiding
STEERAGE_PATTERNS = {
    "correction": [
        r"\bno[,.]?\s+(don'?t|do not|never|stop)\b",
        r"\bthat'?s\s+(wrong|incorrect|not right|not what)\b",
        r"\bactually[,.]?\s",
        r"\binstead[,.]?\s",
        r"\bshould\s+(have|be|use|do)\b",
        r"\bwhy\s+(did you|are you|would you)\b",
    ],
    "preference": [
        r"\b(i\s+)?prefer\b",
        r"\balways\s+(use|do|check|run|make)\b",
        r"\bnever\s+(use|do|create|make|add|commit)\b",
        r"\bdon'?t\s+(ever|always|just)\b",
        r"\buse\s+\w+\s+instead\s+of\b",
    ],
    "guidance": [
        r"\bmake\s+sure\s+(to|that|you)\b",
        r"\bremember\s+(to|that)\b",
        r"\bimportant[:\s]",
        r"\bcritical[:\s]",
        r"\brule[:\s]",
        r"\bconvention[:\s]",
        r"\bstandard[:\s]",
    ],
    "workflow": [
        r"\bbefore\s+(you|doing|making|editing|committing)\b",
        r"\bafter\s+(you|doing|making|editing|committing)\b",
        r"\bfirst[,.]?\s+(check|read|run|verify)\b",
        r"\bthe\s+process\s+is\b",
        r"\bthe\s+workflow\s+is\b",
    ],
    "quality": [
        r"\btest(s|ing)?\s+(first|before|after)\b",
        r"\blint\b",
        r"\bverif(y|ied|ication)\b",
        r"\bclean\s+up\b",
        r"\bself-improvement\b",
        r"\btake\s+every\s+.+\s+opportunity\b",
    ],
}

# Compile patterns once
COMPILED_PATTERNS = {
    category: [re.compile(p, re.IGNORECASE) for p in patterns]
    for category, patterns in STEERAGE_PATTERNS.items()
}

# Error categories for tool failures
ERROR_CATEGORIES = {
    "file_not_found": re.compile(r"(file not found|no such file|ENOENT)", re.IGNORECASE),
    "edit_stale_read": re.compile(r"modified since.*(last read|was read)", re.IGNORECASE),
    "edit_mismatch": re.compile(r"(oldString|could not find).*in (the )?file", re.IGNORECASE),
    "edit_multiple": re.compile(r"(multiple matches|found multiple)", re.IGNORECASE),
    "permission": re.compile(r"permission denied", re.IGNORECASE),
    "timeout": re.compile(r"(timeout|timed out)", re.IGNORECASE),
    "exit_code": re.compile(r"(exit code|exited with|ShellError)", re.IGNORECASE),
    "not_read_first": re.compile(r"must.*read.*before|without.*prior.*read", re.IGNORECASE),
}


def connect_db(db_path: Path) -> sqlite3.Connection:
    """Connect to session database read-only."""
    if not db_path.exists():
        print(f"Error: Database not found at {db_path}", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def classify_steerage(text: str) -> list[dict[str, Any]]:
    """Classify user text into steerage categories with matched patterns."""
    if not text or len(text) < 15:
        return []

    matches = []
    for category, patterns in COMPILED_PATTERNS.items():
        for pattern in patterns:
            m = pattern.search(text)
            if m:
                matches.append({
                    "category": category,
                    "matched": m.group(0),
                    "position": m.start(),
                })
                break  # One match per category is enough

    return matches


def classify_error(error_text: str) -> str:
    """Classify a tool error into a category."""
    if not error_text:
        return "unknown"

    for category, pattern in ERROR_CATEGORIES.items():
        if pattern.search(error_text):
            return category

    return "other"


def extract_steerage(conn: sqlite3.Connection, limit: int | None = None) -> list[dict]:
    """Extract user steerage signals from sessions.

    Returns tool-agnostic records with:
    - session context (title, directory, timestamp)
    - user text
    - steerage classification
    - surrounding assistant context (what was the model doing when corrected)
    """
    print("Extracting user steerage signals...", file=sys.stderr)

    query = """
    SELECT
        s.id as session_id,
        s.title as session_title,
        s.directory as session_dir,
        m.id as message_id,
        m.time_created as msg_time,
        json_extract(m.data, '$.role') as role,
        json_extract(m.data, '$.modelID') as model
    FROM message m
    JOIN session s ON m.session_id = s.id
    WHERE json_extract(m.data, '$.role') = 'user'
    ORDER BY m.time_created ASC
    """
    if limit:
        query += f" LIMIT {int(limit) * 10}"  # Oversample, filter later

    steerage_records = []
    seen_texts = set()

    for row in conn.execute(query):
        # Get user text parts
        parts = conn.execute(
            """SELECT json_extract(data, '$.text') as text
               FROM part
               WHERE message_id = ? AND json_extract(data, '$.type') = 'text'""",
            (row["message_id"],),
        ).fetchall()

        for part in parts:
            text = part["text"]
            if not text or len(text) < 20:
                continue

            # Skip automated/templated messages
            if text.startswith("/full-loop") or text.startswith('"You are the supervisor'):
                continue

            # Skip exact duplicates (common with "Continue if you have next steps")
            text_hash = hash(text[:200])
            if text_hash in seen_texts:
                continue
            seen_texts.add(text_hash)

            classifications = classify_steerage(text)
            if not classifications:
                continue

            # Get preceding assistant message for context
            prev_assistant = conn.execute(
                """SELECT json_extract(p.data, '$.text') as text
                   FROM part p
                   JOIN message m ON p.message_id = m.id
                   WHERE m.session_id = ?
                     AND m.time_created < ?
                     AND json_extract(m.data, '$.role') = 'assistant'
                     AND json_extract(p.data, '$.type') = 'text'
                   ORDER BY m.time_created DESC
                   LIMIT 1""",
                (row["session_id"], row["msg_time"]),
            ).fetchone()

            # Sanitize: strip repo-specific paths, keep only basename
            sanitized_dir = _sanitize_path(row["session_dir"] or "")

            record = {
                "type": "steerage",
                "session_title": row["session_title"] or "",
                "session_dir": sanitized_dir,
                "timestamp": row["msg_time"],
                "user_text": text[:2000],  # Cap length
                "classifications": classifications,
                "preceding_context": (prev_assistant["text"][:500] if prev_assistant and prev_assistant["text"] else ""),
            }
            steerage_records.append(record)

            if limit and len(steerage_records) >= limit:
                break

        if limit and len(steerage_records) >= limit:
            break

    print(f"  Found {len(steerage_records)} steerage signals", file=sys.stderr)
    return steerage_records


def extract_errors(conn: sqlite3.Connection, limit: int | None = None) -> list[dict]:
    """Extract tool error sequences with surrounding context.

    For each error, captures:
    - What tool failed and how
    - What the model was trying to do (preceding assistant text)
    - What happened next (did the model recover? how?)
    - What the user said (if anything)
    """
    print("Extracting error sequences...", file=sys.stderr)

    query = """
    SELECT
        p.id as part_id,
        p.session_id,
        p.message_id,
        p.time_created,
        json_extract(p.data, '$.tool') as tool_name,
        json_extract(p.data, '$.state.error') as error_text,
        json_extract(p.data, '$.state.input') as tool_input_json,
        s.title as session_title,
        s.directory as session_dir
    FROM part p
    JOIN session s ON p.session_id = s.id
    WHERE json_extract(p.data, '$.type') = 'tool'
      AND json_extract(p.data, '$.state.status') = 'error'
    ORDER BY p.time_created DESC
    """
    if limit:
        query += f" LIMIT {int(limit)}"

    error_records = []

    for row in conn.execute(query):
        error_text = row["error_text"] or ""
        tool_name = row["tool_name"] or "unknown"
        error_category = classify_error(error_text)

        # Parse tool input for context
        tool_input = {}
        if row["tool_input_json"]:
            try:
                tool_input = json.loads(row["tool_input_json"]) if isinstance(row["tool_input_json"], str) else row["tool_input_json"]
            except (json.JSONDecodeError, TypeError):
                pass

        # Get what happened next — did the same tool succeed?
        next_tool = conn.execute(
            """SELECT
                json_extract(data, '$.tool') as tool,
                json_extract(data, '$.state.status') as status,
                json_extract(data, '$.state.input') as input_json
               FROM part
               WHERE session_id = ?
                 AND time_created > ?
                 AND json_extract(data, '$.type') = 'tool'
               ORDER BY time_created ASC
               LIMIT 3""",
            (row["session_id"], row["time_created"]),
        ).fetchall()

        recovery = None
        for nt in next_tool:
            if nt["tool"] == tool_name and nt["status"] == "completed":
                recovery_input = {}
                if nt["input_json"]:
                    try:
                        recovery_input = json.loads(nt["input_json"]) if isinstance(nt["input_json"], str) else nt["input_json"]
                    except (json.JSONDecodeError, TypeError):
                        pass
                recovery = {
                    "tool": nt["tool"],
                    "approach": _summarize_tool_input(nt["tool"], recovery_input),
                }
                break

        # Get user message after error (if any, within 3 messages)
        user_after = conn.execute(
            """SELECT json_extract(p2.data, '$.text') as text
               FROM part p2
               JOIN message m ON p2.message_id = m.id
               WHERE m.session_id = ?
                 AND m.time_created > ?
                 AND json_extract(m.data, '$.role') = 'user'
                 AND json_extract(p2.data, '$.type') = 'text'
               ORDER BY m.time_created ASC
               LIMIT 1""",
            (row["session_id"], row["time_created"]),
        ).fetchone()

        record = {
            "type": "error",
            "session_title": row["session_title"] or "",
            "session_dir": _sanitize_path(row["session_dir"] or ""),
            "timestamp": row["time_created"],
            "tool": tool_name,
            "error_category": error_category,
            "error_text": error_text[:500],
            "tool_input_summary": _summarize_tool_input(tool_name, tool_input),
            "recovery": recovery,
            "user_response": (user_after["text"][:500] if user_after and user_after["text"] else None),
        }
        error_records.append(record)

    print(f"  Found {len(error_records)} error sequences", file=sys.stderr)
    return error_records


def extract_error_stats(conn: sqlite3.Connection) -> dict:
    """Extract aggregate error statistics for the summary."""
    stats = {}

    # Error counts by tool
    rows = conn.execute("""
        SELECT
            json_extract(data, '$.tool') as tool,
            COUNT(*) as total,
            SUM(CASE WHEN json_extract(data, '$.state.status') = 'error' THEN 1 ELSE 0 END) as errors
        FROM part
        WHERE json_extract(data, '$.type') = 'tool'
        GROUP BY tool
        ORDER BY total DESC
    """).fetchall()

    stats["tool_error_rates"] = {
        row["tool"]: {
            "total": row["total"],
            "errors": row["errors"],
            "rate": round(row["errors"] / max(row["total"], 1), 4),
        }
        for row in rows
        if row["tool"]
    }

    # Error categories
    rows = conn.execute("""
        SELECT json_extract(data, '$.state.error') as err
        FROM part
        WHERE json_extract(data, '$.type') = 'tool'
          AND json_extract(data, '$.state.status') = 'error'
    """).fetchall()

    category_counts = defaultdict(int)
    for row in rows:
        cat = classify_error(row["err"] or "")
        category_counts[cat] += 1

    stats["error_categories"] = dict(sorted(category_counts.items(), key=lambda x: -x[1]))

    # Model usage
    rows = conn.execute("""
        SELECT json_extract(data, '$.modelID') as model, COUNT(*) as cnt
        FROM message
        WHERE json_extract(data, '$.role') = 'assistant'
        GROUP BY model
        ORDER BY cnt DESC
        LIMIT 10
    """).fetchall()

    stats["model_usage"] = {row["model"]: row["cnt"] for row in rows if row["model"]}

    # Session count and date range
    row = conn.execute("""
        SELECT COUNT(*) as cnt,
               MIN(time_created) as earliest,
               MAX(time_created) as latest
        FROM session
    """).fetchone()

    stats["sessions"] = {
        "total": row["cnt"],
        "earliest": row["earliest"],
        "latest": row["latest"],
    }

    return stats


def _sanitize_path(path: str) -> str:
    """Strip user-specific path components, keep only project-relevant parts."""
    if not path:
        return ""
    # ~/Git/reponame or ~/Git/reponame-worktree-name -> just the last component
    parts = Path(path).parts
    # Find the Git directory marker and take everything after
    for i, part in enumerate(parts):
        if part == "Git" and i + 1 < len(parts):
            return "/".join(parts[i + 1:])
    # Fallback: just the last 2 components
    return "/".join(parts[-2:]) if len(parts) >= 2 else path


def _summarize_tool_input(tool: str, tool_input: Any) -> str:
    """Create a brief summary of what a tool call was trying to do."""
    if not isinstance(tool_input, dict):
        return ""

    if tool == "edit":
        fp = tool_input.get("filePath", "")
        return f"edit {Path(fp).name}" if fp else "edit"
    elif tool == "read":
        fp = tool_input.get("filePath", "")
        return f"read {Path(fp).name}" if fp else "read"
    elif tool == "write":
        fp = tool_input.get("filePath", "")
        return f"write {Path(fp).name}" if fp else "write"
    elif tool == "bash":
        cmd = tool_input.get("command", "")
        # First 80 chars of command, strip newlines
        return f"bash: {cmd[:80].replace(chr(10), ' ')}" if cmd else "bash"
    elif tool == "glob":
        return f"glob: {tool_input.get('pattern', '')}"
    elif tool == "grep":
        return f"grep: {tool_input.get('pattern', '')}"
    elif tool == "webfetch":
        return f"fetch: {tool_input.get('url', '')[:80]}"

    return tool


def build_chunks(steerage: list[dict], errors: list[dict], stats: dict,
                 max_chunk_bytes: int = 80_000) -> list[dict]:
    """Build analysis-ready chunks that fit within model context.

    Each chunk is self-contained with:
    - A batch of steerage or error records
    - Enough context for the model to extract patterns
    - Metadata for deduplication
    """
    chunks = []

    # Chunk 0: Summary statistics (always first)
    chunks.append({
        "chunk_id": "stats",
        "chunk_type": "summary",
        "data": stats,
    })

    # Chunk steerage by category
    by_category = defaultdict(list)
    for record in steerage:
        for cls in record["classifications"]:
            by_category[cls["category"]].append(record)

    for category, records in by_category.items():
        current_chunk = []
        current_size = 0

        for record in records:
            record_json = json.dumps(record)
            record_size = len(record_json.encode("utf-8"))

            if current_size + record_size > max_chunk_bytes and current_chunk:
                chunks.append({
                    "chunk_id": f"steerage_{category}_{len(chunks)}",
                    "chunk_type": "steerage",
                    "category": category,
                    "record_count": len(current_chunk),
                    "records": current_chunk,
                })
                current_chunk = []
                current_size = 0

            current_chunk.append(record)
            current_size += record_size

        if current_chunk:
            chunks.append({
                "chunk_id": f"steerage_{category}_{len(chunks)}",
                "chunk_type": "steerage",
                "category": category,
                "record_count": len(current_chunk),
                "records": current_chunk,
            })

    # Chunk errors by category
    errors_by_cat = defaultdict(list)
    for record in errors:
        errors_by_cat[record["error_category"]].append(record)

    for category, records in errors_by_cat.items():
        current_chunk = []
        current_size = 0

        for record in records:
            record_json = json.dumps(record)
            record_size = len(record_json.encode("utf-8"))

            if current_size + record_size > max_chunk_bytes and current_chunk:
                chunks.append({
                    "chunk_id": f"error_{category}_{len(chunks)}",
                    "chunk_type": "error",
                    "category": category,
                    "record_count": len(current_chunk),
                    "records": current_chunk,
                })
                current_chunk = []
                current_size = 0

            current_chunk.append(record)
            current_size += record_size

        if current_chunk:
            chunks.append({
                "chunk_id": f"error_{category}_{len(chunks)}",
                "chunk_type": "error",
                "category": category,
                "record_count": len(current_chunk),
                "records": current_chunk,
            })

    return chunks


def write_output(data: list[dict], output_dir: Path, fmt: str = "jsonl") -> Path:
    """Write extracted data to output files."""
    output_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")

    out_path = output_dir / f"extraction_{timestamp}.jsonl"  # default

    if fmt == "jsonl":
        out_path = output_dir / f"extraction_{timestamp}.jsonl"
        with open(out_path, "w", encoding="utf-8") as f:
            for record in data:
                f.write(json.dumps(record, ensure_ascii=False) + "\n")
    elif fmt == "chunks":
        out_path = output_dir / f"chunks_{timestamp}"
        out_path.mkdir(parents=True, exist_ok=True)
        for i, chunk in enumerate(data):
            chunk_path = out_path / f"{chunk.get('chunk_id', f'chunk_{i}')}.json"
            with open(chunk_path, "w", encoding="utf-8") as f:
                json.dump(chunk, f, indent=2, ensure_ascii=False)
        # Also write a manifest
        manifest = {
            "chunk_count": len(data),
            "chunks": [
                {
                    "id": c.get("chunk_id"),
                    "type": c.get("chunk_type"),
                    "category": c.get("category", ""),
                    "records": c.get("record_count", 0),
                }
                for c in data
            ],
            "created": timestamp,
        }
        with open(out_path / "manifest.json", "w", encoding="utf-8") as f:
            json.dump(manifest, f, indent=2)

    return out_path


def main():
    parser = argparse.ArgumentParser(description="Extract learning signals from coding sessions")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB,
                        help=f"Path to session database (default: {DEFAULT_DB})")
    parser.add_argument("--format", choices=["jsonl", "chunks"], default="chunks",
                        help="Output format (default: chunks)")
    parser.add_argument("--limit", type=int, default=None,
                        help="Limit records extracted per category")
    parser.add_argument("--output", type=Path, default=OUTPUT_DIR,
                        help=f"Output directory (default: {OUTPUT_DIR})")
    args = parser.parse_args()

    print(f"Session Miner — Extracting from {args.db}", file=sys.stderr)
    print(f"  DB size: {args.db.stat().st_size / 1024 / 1024:.1f} MB", file=sys.stderr)

    conn = connect_db(args.db)

    try:
        # Phase 1a: Extract steerage
        steerage = extract_steerage(conn, limit=args.limit)

        # Phase 1b: Extract errors
        errors = extract_errors(conn, limit=args.limit)

        # Phase 1c: Aggregate stats
        stats = extract_error_stats(conn)

        # Phase 2: Build chunks for model analysis
        if args.format == "chunks":
            chunks = build_chunks(steerage, errors, stats)
            out_path = write_output(chunks, args.output, fmt="chunks")
            print(f"\nOutput: {out_path}/", file=sys.stderr)
            print(f"  {len(chunks)} chunks written", file=sys.stderr)
            print(f"  {len(steerage)} steerage signals", file=sys.stderr)
            print(f"  {len(errors)} error sequences", file=sys.stderr)
        else:
            all_records = [{"type": "stats", **stats}] + steerage + errors
            out_path = write_output(all_records, args.output, fmt="jsonl")
            print(f"\nOutput: {out_path}", file=sys.stderr)
            print(f"  {len(steerage)} steerage + {len(errors)} errors", file=sys.stderr)

        # Print summary to stdout
        print(json.dumps({
            "steerage_count": len(steerage),
            "error_count": len(errors),
            "steerage_categories": dict(
                sorted(
                    defaultdict(int, {
                        cat: sum(1 for s in steerage if any(c["category"] == cat for c in s["classifications"]))
                        for cat in STEERAGE_PATTERNS
                    }).items(),
                    key=lambda x: -x[1],
                )
            ),
            "error_categories": stats.get("error_categories", {}),
            "output": str(out_path),
        }, indent=2))

    finally:
        conn.close()


if __name__ == "__main__":
    main()
