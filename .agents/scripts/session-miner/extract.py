#!/usr/bin/env python3
"""
Session Miner — Phase 1: Extract high-signal data from coding assistant sessions.

Extracts three categories of learning signal from local session databases:
1. User steerage: corrections, preferences, guidance, workflow patterns
2. Model errors: tool failures with surrounding context (what failed, what fixed it)
3. Git correlation: cross-references sessions with git commit outcomes

Output format is tool-agnostic — works with OpenCode now, adaptable to
Claude Code, Cursor, or any tool that stores session data.

All data stays local. Output goes to ~/.aidevops/.agent-workspace/work/session-miner/

Usage:
    python3 extract.py                    # Extract from default OpenCode DB
    python3 extract.py --db /path/to.db   # Custom DB path
    python3 extract.py --format jsonl     # JSONL output (default)
    python3 extract.py --format chunks    # Pre-chunked for model analysis
    python3 extract.py --limit 100        # Limit sessions processed
    python3 extract.py --no-git           # Skip git correlation extraction
"""

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Any, Optional


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


def extract_steerage(conn: sqlite3.Connection, limit: Optional[int] = None) -> list[dict]:
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


def extract_errors(conn: sqlite3.Connection, limit: Optional[int] = None) -> list[dict]:
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


def _find_git_root(directory: str) -> Optional[str]:
    """Find the git root for a directory, or None if not a git repo."""
    try:
        result = subprocess.run(
            ["git", "-C", directory, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    return None


def _git_log_in_window(
    repo_path: str, start_epoch_ms: int, end_epoch_ms: int, buffer_minutes: int = 60,
) -> list[dict]:
    """Query git log for commits within a time window.

    Args:
        repo_path: Path to git repository root.
        start_epoch_ms: Session start time (epoch milliseconds).
        end_epoch_ms: Session end time (epoch milliseconds).
        buffer_minutes: Extra minutes after session end to capture delayed commits.

    Returns:
        List of commit dicts with hash, timestamp, subject, and diff stats.
    """
    # Convert ms to seconds for git --after/--before (ISO 8601)
    start_ts = datetime.fromtimestamp(start_epoch_ms / 1000).isoformat()
    end_ts = datetime.fromtimestamp(
        end_epoch_ms / 1000 + buffer_minutes * 60
    ).isoformat()

    try:
        # Get commit metadata
        result = subprocess.run(
            [
                "git", "-C", repo_path, "log",
                f"--after={start_ts}", f"--before={end_ts}",
                "--format=%H|%aI|%s",
            ],
            capture_output=True, text=True, timeout=15,
        )
        if result.returncode != 0 or not result.stdout.strip():
            return []

        commits = []
        for line in result.stdout.strip().split("\n"):
            if not line:
                continue
            parts = line.split("|", 2)
            if len(parts) < 3:
                continue
            commit_hash, timestamp, subject = parts
            commits.append({
                "hash": commit_hash[:12],
                "timestamp": timestamp,
                "subject": subject[:200],
            })

        if not commits:
            return []

        # Get aggregate diff stats for the commit range
        hash_list = [c["hash"] for c in commits]
        stat_result = subprocess.run(
            [
                "git", "-C", repo_path, "diff", "--shortstat",
                f"{hash_list[-1]}~1..{hash_list[0]}",
            ],
            capture_output=True, text=True, timeout=15,
        )
        if stat_result.returncode == 0 and stat_result.stdout.strip():
            stat_line = stat_result.stdout.strip()
            # Parse "N files changed, N insertions(+), N deletions(-)"
            files_m = re.search(r"(\d+) files? changed", stat_line)
            ins_m = re.search(r"(\d+) insertions?", stat_line)
            del_m = re.search(r"(\d+) deletions?", stat_line)
            for commit in commits:
                commit["_aggregate"] = True  # Mark: stats are aggregate, not per-commit
            if commits:
                commits[0]["diff_stats"] = {
                    "files_changed": int(files_m.group(1)) if files_m else 0,
                    "insertions": int(ins_m.group(1)) if ins_m else 0,
                    "deletions": int(del_m.group(1)) if del_m else 0,
                }

        return commits

    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return []


def extract_git_correlation(
    conn: sqlite3.Connection, limit: Optional[int] = None,
) -> list[dict]:
    """Extract git-commit correlation data for sessions.

    For each session with a project directory, finds commits produced during
    (or shortly after) the session and computes productivity metrics.

    Returns:
        List of per-session git correlation records.
    """
    print("Extracting git correlation data...", file=sys.stderr)

    query = """
    SELECT
        s.id as session_id,
        s.title as session_title,
        s.directory as session_dir,
        s.time_created as session_start,
        s.time_updated as session_end,
        COUNT(DISTINCT m.id) as total_messages,
        SUM(CASE WHEN json_extract(m.data, '$.role') = 'user' THEN 1 ELSE 0 END) as user_messages
    FROM session s
    LEFT JOIN message m ON m.session_id = s.id
    WHERE s.directory IS NOT NULL AND s.directory != ''
    GROUP BY s.id
    ORDER BY s.time_created DESC
    """
    if limit:
        query += f" LIMIT {int(limit)}"

    # Cache git root lookups to avoid repeated subprocess calls
    git_root_cache: dict[str, Optional[str]] = {}
    correlations = []
    skipped = 0

    for row in conn.execute(query):
        session_dir = row["session_dir"]
        if not session_dir or not os.path.isdir(session_dir):
            skipped += 1
            continue

        # Resolve git root (cached)
        if session_dir not in git_root_cache:
            git_root_cache[session_dir] = _find_git_root(session_dir)
        git_root = git_root_cache[session_dir]

        if not git_root:
            skipped += 1
            continue

        # Query git log for the session window
        commits = _git_log_in_window(
            git_root, row["session_start"], row["session_end"],
        )

        user_msg_count = row["user_messages"] or 0
        total_msg_count = row["total_messages"] or 0
        commits_count = len(commits)

        # Compute diff stats from the first commit (which has aggregate stats)
        files_changed = 0
        insertions = 0
        deletions = 0
        if commits and "diff_stats" in commits[0]:
            stats = commits[0]["diff_stats"]
            files_changed = stats.get("files_changed", 0)
            insertions = stats.get("insertions", 0)
            deletions = stats.get("deletions", 0)

        # Productivity ratios (avoid division by zero)
        commits_per_message = (
            round(commits_count / user_msg_count, 3) if user_msg_count > 0 else 0
        )
        lines_per_message = (
            round((insertions + deletions) / user_msg_count, 1)
            if user_msg_count > 0 else 0
        )

        # Session duration in minutes
        duration_min = round(
            (row["session_end"] - row["session_start"]) / 1000 / 60, 1,
        )

        record = {
            "type": "git_correlation",
            "session_title": row["session_title"] or "",
            "session_dir": _sanitize_path(session_dir),
            "session_start": row["session_start"],
            "session_end": row["session_end"],
            "duration_minutes": duration_min,
            "user_messages": user_msg_count,
            "total_messages": total_msg_count,
            "commits_count": commits_count,
            "files_changed": files_changed,
            "insertions": insertions,
            "deletions": deletions,
            "commits_per_message": commits_per_message,
            "lines_per_message": lines_per_message,
            "commits": [
                {"hash": c["hash"], "subject": c["subject"]}
                for c in commits
            ] if commits else [],
        }
        correlations.append(record)

    print(
        f"  Found {len(correlations)} sessions with git data "
        f"({skipped} skipped — no git repo or dir missing)",
        file=sys.stderr,
    )
    productive = sum(1 for c in correlations if c["commits_count"] > 0)
    print(f"  {productive} sessions produced commits", file=sys.stderr)

    return correlations


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
                 git_correlations: Optional[list[dict]] = None,
                 max_chunk_bytes: int = 80_000) -> list[dict]:
    """Build analysis-ready chunks that fit within model context.

    Each chunk is self-contained with:
    - A batch of steerage, error, or git correlation records
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

    # Chunk git correlations (split productive vs non-productive)
    if git_correlations:
        productive = [r for r in git_correlations if r["commits_count"] > 0]
        unproductive = [r for r in git_correlations if r["commits_count"] == 0]

        # Productivity summary (always included, small)
        total_sessions = len(git_correlations)
        total_commits = sum(r["commits_count"] for r in git_correlations)
        total_insertions = sum(r["insertions"] for r in git_correlations)
        total_deletions = sum(r["deletions"] for r in git_correlations)
        avg_duration = (
            round(sum(r["duration_minutes"] for r in git_correlations) / total_sessions, 1)
            if total_sessions > 0 else 0
        )
        avg_commits_per_msg = (
            round(
                sum(r["commits_per_message"] for r in productive) / len(productive), 3,
            )
            if productive else 0
        )

        chunks.append({
            "chunk_id": "git_summary",
            "chunk_type": "git_correlation",
            "category": "summary",
            "data": {
                "total_sessions": total_sessions,
                "productive_sessions": len(productive),
                "unproductive_sessions": len(unproductive),
                "productivity_rate": round(len(productive) / max(total_sessions, 1), 3),
                "total_commits": total_commits,
                "total_insertions": total_insertions,
                "total_deletions": total_deletions,
                "avg_session_duration_min": avg_duration,
                "avg_commits_per_message": avg_commits_per_msg,
            },
        })

        # Chunk productive sessions (these have the interesting data)
        for batch_name, batch in [("productive", productive), ("unproductive", unproductive)]:
            current_chunk = []
            current_size = 0

            for record in batch:
                record_json = json.dumps(record)
                record_size = len(record_json.encode("utf-8"))

                if current_size + record_size > max_chunk_bytes and current_chunk:
                    chunks.append({
                        "chunk_id": f"git_{batch_name}_{len(chunks)}",
                        "chunk_type": "git_correlation",
                        "category": batch_name,
                        "record_count": len(current_chunk),
                        "records": current_chunk,
                    })
                    current_chunk = []
                    current_size = 0

                current_chunk.append(record)
                current_size += record_size

            if current_chunk:
                chunks.append({
                    "chunk_id": f"git_{batch_name}_{len(chunks)}",
                    "chunk_type": "git_correlation",
                    "category": batch_name,
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
    parser.add_argument("--no-git", action="store_true",
                        help="Skip git correlation extraction")
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

        # Phase 1d: Extract git correlation (unless disabled)
        git_correlations = None
        if not args.no_git:
            git_correlations = extract_git_correlation(conn, limit=args.limit)

        # Phase 2: Build chunks for model analysis
        if args.format == "chunks":
            chunks = build_chunks(steerage, errors, stats, git_correlations)
            out_path = write_output(chunks, args.output, fmt="chunks")
            print(f"\nOutput: {out_path}/", file=sys.stderr)
            print(f"  {len(chunks)} chunks written", file=sys.stderr)
            print(f"  {len(steerage)} steerage signals", file=sys.stderr)
            print(f"  {len(errors)} error sequences", file=sys.stderr)
            if git_correlations is not None:
                productive = sum(1 for c in git_correlations if c["commits_count"] > 0)
                print(f"  {len(git_correlations)} git correlations ({productive} productive)", file=sys.stderr)
        else:
            all_records = [{"type": "stats", **stats}] + steerage + errors
            if git_correlations:
                all_records.extend(git_correlations)
            out_path = write_output(all_records, args.output, fmt="jsonl")
            print(f"\nOutput: {out_path}", file=sys.stderr)
            print(f"  {len(steerage)} steerage + {len(errors)} errors", file=sys.stderr)

        # Print summary to stdout
        summary = {
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
        }
        if git_correlations is not None:
            productive = [c for c in git_correlations if c["commits_count"] > 0]
            summary["git_correlation"] = {
                "total_sessions": len(git_correlations),
                "productive_sessions": len(productive),
                "total_commits": sum(c["commits_count"] for c in git_correlations),
                "avg_commits_per_message": round(
                    sum(c["commits_per_message"] for c in productive) / max(len(productive), 1), 3,
                ),
            }
        print(json.dumps(summary, indent=2))

    finally:
        conn.close()


if __name__ == "__main__":
    main()
