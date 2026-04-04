#!/usr/bin/env python3
"""
Session Miner — Phase 1: Extract high-signal data from coding assistant sessions.

Extracts four categories of learning signal from local session databases:
1. User steerage: corrections, preferences, guidance, workflow patterns
2. Model errors: tool failures with surrounding context (what failed, what fixed it)
3. Git correlation: cross-references sessions with git commit outcomes
4. Instruction candidates: persistent guidance/corrections that should be saved to
   instruction files (AGENTS.md, build.txt, style guides)

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


# --- Instruction candidate detection ---
#
# Design: high precision over recall. Better to miss a candidate than to flood
# with false positives. Only flag generalizable patterns, not task-specific
# directions that reference particular files, PRs, or one-off commands.

# Patterns that signal persistent/generalizable guidance
INSTRUCTION_SIGNAL_PATTERNS = [
    # Explicit save-to-instructions requests
    r"\badd\s+(this|that)\s+to\s+(AGENTS\.md|build\.txt|the\s+style\s+guide|the\s+instructions?|the\s+rules?)\b",
    r"\bupdate\s+(AGENTS\.md|build\.txt|the\s+style\s+guide|the\s+instructions?|the\s+rules?)\b",
    r"\bremember\s+(this|that)\s+(rule|convention|preference|pattern|going\s+forward)\b",
    # Persistent directive language
    r"\bfrom\s+now\s+on\b",
    r"\bgoing\s+forward\b",
    r"\bin\s+future\s+sessions?\b",
    r"\balways\s+(?:use|do|check|run|make|prefer|ensure|include|add|put|write|format|start|end|begin|avoid|skip|omit)\b",
    r"\bnever\s+(?:use|do|create|make|add|commit|include|put|write|format|start|end|begin|guess|assume|hardcode)\b",
    r"\bdon'?t\s+ever\s+\w+\b",
    # Convention/rule declarations
    r"\bthe\s+(?:rule|convention|standard|pattern|policy|practice)\s+is\b",
    r"\bour\s+(?:rule|convention|standard|pattern|policy|practice)\s+is\b",
    r"\bwe\s+(?:always|never|prefer|use|avoid)\b",
    r"\bprefer\s+\w+\s+over\b",
    r"\buse\s+\w+\s+instead\s+of\b",
]

# Patterns that indicate task-specific (non-generalizable) directions — these
# are strong disqualifiers. If any match, the candidate is suppressed.
TASK_SPECIFIC_DISQUALIFIERS = [
    # References to specific files by path
    r"(?:fix|edit|update|change|revert|delete|remove)\s+(?:the\s+)?(?:file\s+)?['\"]?[\w./\-]+\.\w{1,6}['\"]?",
    # References to specific PRs, issues, commits
    r"\b(?:PR|pull\s+request|issue|commit|branch)\s+#?\d+\b",
    r"\bGH#\d+\b",
    r"\bt\d{3,}\b",  # task IDs like t1876
    # Undo/revert commands (one-off, not persistent)
    r"\b(?:undo|revert|rollback|reset)\s+(?:that|this|the\s+last)\b",
    # References to "this" specific instance without generalizing
    r"\bthis\s+(?:specific|particular|one)\b",
    # Imperative commands about the current task only
    r"\bfor\s+(?:this|the\s+current)\s+(?:task|issue|PR|commit|session)\b",
]

# Compiled versions
_INSTRUCTION_COMPILED = [re.compile(p, re.IGNORECASE) for p in INSTRUCTION_SIGNAL_PATTERNS]
_DISQUALIFIER_COMPILED = [re.compile(p, re.IGNORECASE) for p in TASK_SPECIFIC_DISQUALIFIERS]

# Target file heuristics — map content keywords to likely instruction files
_TARGET_FILE_RULES: list[tuple[re.Pattern, str, str]] = [
    (re.compile(r"\b(?:shell|bash|script|\.sh|shellcheck|function|local\s+var)\b", re.IGNORECASE),
     ".agents/prompts/build.txt", "code_style"),
    (re.compile(r"\b(?:AGENTS\.md|agent|subagent|prompt|instruction|build\.txt)\b", re.IGNORECASE),
     ".agents/prompts/build.txt", "agent_instructions"),
    (re.compile(r"\b(?:git|commit|branch|PR|worktree|merge|push|pull)\b", re.IGNORECASE),
     ".agents/prompts/build.txt", "git_workflow"),
    (re.compile(r"\b(?:style|format|markdown|emoji|tone|concise|verbose)\b", re.IGNORECASE),
     ".agents/prompts/build.txt", "style"),
    (re.compile(r"\b(?:security|secret|credential|token|key|password)\b", re.IGNORECASE),
     ".agents/prompts/build.txt", "security"),
    (re.compile(r"\b(?:test|lint|quality|verify|check|validate)\b", re.IGNORECASE),
     ".agents/prompts/build.txt", "quality"),
    (re.compile(r"\b(?:AGENTS\.md|workflow|process|lifecycle|routine)\b", re.IGNORECASE),
     ".agents/AGENTS.md", "workflow"),
]
_TARGET_FILE_DEFAULT = (".agents/prompts/build.txt", "general")


def _infer_target_file(text: str) -> tuple[str, str]:
    """Infer the most likely instruction file and category for a candidate."""
    for pattern, target_file, category in _TARGET_FILE_RULES:
        if pattern.search(text):
            return target_file, category
    return _TARGET_FILE_DEFAULT


def _score_instruction_candidate(text: str) -> float:
    """Score a text for instruction-candidate confidence (0.0–1.0).

    Higher score = more likely to be a generalizable persistent instruction.
    Returns 0.0 if any disqualifier matches (task-specific direction).
    """
    # Hard disqualifiers — task-specific, not generalizable
    for pattern in _DISQUALIFIER_COMPILED:
        if pattern.search(text):
            return 0.0

    # Count signal pattern matches
    signal_count = sum(1 for p in _INSTRUCTION_COMPILED if p.search(text))
    if signal_count == 0:
        return 0.0

    # Boost for explicit save-to-instructions requests (first 2 patterns)
    explicit_save = any(p.search(text) for p in _INSTRUCTION_COMPILED[:2])
    base_score = min(0.5 + (signal_count * 0.15), 0.95)
    if explicit_save:
        base_score = min(base_score + 0.2, 0.99)

    return round(base_score, 2)


def classify_instruction_candidate(text: str) -> Optional[dict[str, Any]]:
    """Classify user text as a potential instruction candidate.

    Returns a dict with confidence and target_file, or None if not a candidate.
    Conservative: only returns results with confidence >= 0.5.
    """
    if not text or len(text) < 20:
        return None

    confidence = _score_instruction_candidate(text)
    if confidence < 0.5:
        return None

    target_file, category = _infer_target_file(text)
    return {
        "confidence": confidence,
        "target_file": target_file,
        "category": category,
    }


def extract_instruction_candidates(
    conn: sqlite3.Connection, limit: Optional[int] = None,
) -> list[dict]:
    """Extract instruction candidate signals from user messages.

    Identifies user utterances that appear to be persistent rules or conventions
    that should be captured in instruction files (AGENTS.md, build.txt, etc.).

    Conservative detection: high precision over recall. Task-specific directions
    (referencing particular files, PRs, or one-off commands) are filtered out.

    Returns:
        List of instruction candidate records with text, confidence, target_file,
        session context, and category.
    """
    print("Extracting instruction candidates...", file=sys.stderr)

    query = """
    SELECT
        s.id as session_id,
        s.title as session_title,
        s.directory as session_dir,
        m.id as message_id,
        m.time_created as msg_time,
        json_extract(m.data, '$.role') as role
    FROM message m
    JOIN session s ON m.session_id = s.id
    WHERE json_extract(m.data, '$.role') = 'user'
    ORDER BY m.time_created ASC
    """
    if limit:
        query += f" LIMIT {int(limit) * 10}"

    candidates: list[dict] = []
    seen_texts: set[int] = set()

    for row in conn.execute(query):
        for text in _fetch_text_parts(conn, row["message_id"]):
            if _is_automated_or_short(text):
                continue

            text_hash = hash(text[:200])
            if text_hash in seen_texts:
                continue
            seen_texts.add(text_hash)

            classification = classify_instruction_candidate(text)
            if classification is None:
                continue

            candidates.append({
                "type": "instruction_candidate",
                "session_id": row["session_id"],
                "session_title": row["session_title"] or "",
                "session_dir": _sanitize_path(row["session_dir"] or ""),
                "timestamp": row["msg_time"],
                "text": text[:2000],
                "confidence": classification["confidence"],
                "target_file": classification["target_file"],
                "category": classification["category"],
            })

            if limit and len(candidates) >= limit:
                candidates = candidates[:limit]
                break

    print(f"  Found {len(candidates)} instruction candidates", file=sys.stderr)
    return candidates


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


_AUTOMATED_PREFIXES = ("/full-loop", '"You are the supervisor')


def _is_automated_or_short(text: Optional[str]) -> bool:
    """Return True if *text* should be skipped (None, too short, or templated)."""
    if not text or len(text) < 20:
        return True
    return any(text.startswith(prefix) for prefix in _AUTOMATED_PREFIXES)


def _fetch_text_parts(conn: sqlite3.Connection, message_id: str) -> list[str]:
    """Return all text-part strings for a given message."""
    rows = conn.execute(
        """SELECT json_extract(data, '$.text') as text
           FROM part
           WHERE message_id = ? AND json_extract(data, '$.type') = 'text'""",
        (message_id,),
    ).fetchall()
    return [r["text"] for r in rows if r["text"]]


def _fetch_preceding_assistant_text(
    conn: sqlite3.Connection, session_id: str, before_time: Any,
) -> str:
    """Return the preceding assistant text (up to 500 chars), or ``""``."""
    prev = conn.execute(
        """SELECT json_extract(p.data, '$.text') as text
           FROM part p
           JOIN message m ON p.message_id = m.id
           WHERE m.session_id = ?
             AND m.time_created < ?
             AND json_extract(m.data, '$.role') = 'assistant'
             AND json_extract(p.data, '$.type') = 'text'
           ORDER BY m.time_created DESC
           LIMIT 1""",
        (session_id, before_time),
    ).fetchone()
    if not prev or not prev["text"]:
        return ""
    return prev["text"][:500]


def _classify_and_build_steerage(
    conn: sqlite3.Connection,
    row: sqlite3.Row,
    text: str,
) -> Optional[dict]:
    """Classify *text* and build a steerage record, or ``None`` if not steerage."""
    classifications = classify_steerage(text)
    if not classifications:
        return None

    return {
        "type": "steerage",
        "session_title": row["session_title"] or "",
        "session_dir": _sanitize_path(row["session_dir"] or ""),
        "timestamp": row["msg_time"],
        "user_text": text[:2000],
        "classifications": classifications,
        "preceding_context": _fetch_preceding_assistant_text(
            conn, row["session_id"], row["msg_time"],
        ),
    }


def _collect_steerage_from_message(
    conn: sqlite3.Connection,
    row: sqlite3.Row,
    seen_texts: set[int],
) -> list[dict]:
    """Return steerage records found in a single user message's text parts."""
    records = []
    for text in _fetch_text_parts(conn, row["message_id"]):
        if _is_automated_or_short(text):
            continue

        text_hash = hash(text[:200])
        if text_hash in seen_texts:
            continue
        seen_texts.add(text_hash)

        record = _classify_and_build_steerage(conn, row, text)
        if record:
            records.append(record)
    return records


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

    steerage_records: list[dict] = []
    seen_texts: set[int] = set()

    for row in conn.execute(query):
        new_records = _collect_steerage_from_message(conn, row, seen_texts)
        steerage_records.extend(new_records)

        if limit and len(steerage_records) >= limit:
            steerage_records = steerage_records[:limit]
            break

    print(f"  Found {len(steerage_records)} steerage signals", file=sys.stderr)
    return steerage_records


def _parse_json_safe(raw: Any) -> dict:
    """Parse a JSON string or pass through a dict; return ``{}`` on failure."""
    if not raw:
        return {}
    if isinstance(raw, dict):
        return raw
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return {}


def _find_recovery(
    conn: sqlite3.Connection, session_id: str, after_time: Any, tool_name: str,
) -> Optional[dict]:
    """Look at the next 3 tool calls; return recovery info if the same tool succeeded."""
    next_tools = conn.execute(
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
        (session_id, after_time),
    ).fetchall()

    for nt in next_tools:
        if nt["tool"] == tool_name and nt["status"] == "completed":
            recovery_input = _parse_json_safe(nt["input_json"])
            return {
                "tool": nt["tool"],
                "approach": _summarize_tool_input(nt["tool"], recovery_input),
            }
    return None


def _find_user_response_after(
    conn: sqlite3.Connection, session_id: str, after_time: Any,
) -> Optional[str]:
    """Return the first user text message after *after_time*, or ``None``."""
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
        (session_id, after_time),
    ).fetchone()
    if not user_after or not user_after["text"]:
        return None
    return user_after["text"][:500]


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
        json_extract(m.data, '$.modelID') as model_id,
        s.title as session_title,
        s.directory as session_dir
    FROM part p
    JOIN message m ON p.message_id = m.id
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
        tool_input = _parse_json_safe(row["tool_input_json"])

        record = {
            "type": "error",
            "session_title": row["session_title"] or "",
            "session_dir": _sanitize_path(row["session_dir"] or ""),
            "timestamp": row["time_created"],
            "model": row["model_id"] or "unknown",
            "tool": tool_name,
            "error_category": classify_error(error_text),
            "error_text": error_text[:500],
            "tool_input_summary": _summarize_tool_input(tool_name, tool_input),
            "recovery": _find_recovery(conn, row["session_id"], row["time_created"], tool_name),
            "user_response": _find_user_response_after(conn, row["session_id"], row["time_created"]),
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


def _parse_commit_lines(raw_output: str) -> list[dict]:
    """Parse ``git log --format=%H|%aI|%s`` output into commit dicts."""
    commits = []
    for line in raw_output.strip().split("\n"):
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
    return commits


def _resolve_diff_base(repo_path: str, oldest_commit: str) -> str:
    """Return the diff base ref: ``oldest~1`` or the empty-tree hash for root commits."""
    parent_check = subprocess.run(
        ["git", "-C", repo_path, "rev-parse", "--verify", "--quiet", f"{oldest_commit}^"],
        capture_output=True,
    )
    if parent_check.returncode == 0:
        return f"{oldest_commit}~1"
    # Root commit — diff from git's canonical empty tree object.
    return "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


def _attach_aggregate_diff_stats(repo_path: str, commits: list[dict]) -> None:
    """Compute aggregate diff stats for a commit range and attach to *commits[0]*."""
    oldest_commit = commits[-1]["hash"]
    newest_commit = commits[0]["hash"]
    from_commit = _resolve_diff_base(repo_path, oldest_commit)

    stat_result = subprocess.run(
        ["git", "-C", repo_path, "diff", "--shortstat", from_commit, newest_commit],
        capture_output=True, text=True, timeout=15,
    )
    if stat_result.returncode != 0 or not stat_result.stdout.strip():
        return

    stat_line = stat_result.stdout.strip()
    files_m = re.search(r"(\d+) files? changed", stat_line)
    ins_m = re.search(r"(\d+) insertions?", stat_line)
    del_m = re.search(r"(\d+) deletions?", stat_line)

    for commit in commits:
        commit["_aggregate"] = True
    commits[0]["diff_stats"] = {
        "files_changed": int(files_m.group(1)) if files_m else 0,
        "insertions": int(ins_m.group(1)) if ins_m else 0,
        "deletions": int(del_m.group(1)) if del_m else 0,
    }


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
    start_ts = datetime.fromtimestamp(start_epoch_ms / 1000).isoformat()
    end_ts = datetime.fromtimestamp(
        end_epoch_ms / 1000 + buffer_minutes * 60
    ).isoformat()

    try:
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

        commits = _parse_commit_lines(result.stdout)
        if not commits:
            return []

        _attach_aggregate_diff_stats(repo_path, commits)
        return commits

    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return []


def _extract_diff_stats(commits: list[dict]) -> tuple[int, int, int]:
    """Pull aggregate diff stats from the first commit (if present).

    Returns:
        (files_changed, insertions, deletions)
    """
    if not commits or "diff_stats" not in commits[0]:
        return 0, 0, 0
    stats = commits[0]["diff_stats"]
    return (
        stats.get("files_changed", 0),
        stats.get("insertions", 0),
        stats.get("deletions", 0),
    )


def _build_correlation_record(row: sqlite3.Row, commits: list[dict]) -> dict:
    """Build a single git-correlation record from a session row and its commits."""
    user_msg_count = row["user_messages"] or 0
    total_msg_count = row["total_messages"] or 0
    commits_count = len(commits)
    files_changed, insertions, deletions = _extract_diff_stats(commits)

    commits_per_message = (
        round(commits_count / user_msg_count, 3) if user_msg_count > 0 else 0
    )
    lines_per_message = (
        round((insertions + deletions) / user_msg_count, 1)
        if user_msg_count > 0 else 0
    )
    duration_min = round(
        (row["session_end"] - row["session_start"]) / 1000 / 60, 1,
    )

    return {
        "type": "git_correlation",
        "session_title": row["session_title"] or "",
        "session_dir": _sanitize_path(row["session_dir"] or ""),
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

        commits = _git_log_in_window(
            git_root, row["session_start"], row["session_end"],
        )
        correlations.append(_build_correlation_record(row, commits))

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


def _summarize_file_tool(tool: str, tool_input: dict) -> str:
    """Summarize a file-based tool call (edit/read/write)."""
    fp = tool_input.get("filePath", "")
    return f"{tool} {Path(fp).name}" if fp else tool


def _summarize_bash_tool(_tool: str, tool_input: dict) -> str:
    """Summarize a bash tool call."""
    cmd = tool_input.get("command", "")
    return f"bash: {cmd[:80].replace(chr(10), ' ')}" if cmd else "bash"


# Dispatch table for tool summarization — avoids a long if/elif chain.
_TOOL_SUMMARIZERS: dict[str, Any] = {
    "edit": _summarize_file_tool,
    "read": _summarize_file_tool,
    "write": _summarize_file_tool,
    "bash": _summarize_bash_tool,
    "glob": lambda _t, inp: f"glob: {inp.get('pattern', '')}",
    "grep": lambda _t, inp: f"grep: {inp.get('pattern', '')}",
    "webfetch": lambda _t, inp: f"fetch: {inp.get('url', '')[:80]}",
}


def _summarize_tool_input(tool: str, tool_input: Any) -> str:
    """Create a brief summary of what a tool call was trying to do."""
    if not isinstance(tool_input, dict):
        return ""

    summarizer = _TOOL_SUMMARIZERS.get(tool)
    if summarizer:
        return summarizer(tool, tool_input)

    return tool


def _chunk_records(
    records: list[dict],
    chunk_type: str,
    category: str,
    chunks: list[dict],
    max_chunk_bytes: int,
) -> None:
    """Split a list of records into size-bounded chunks, appending to *chunks*.

    Each emitted chunk contains:
    - chunk_id: ``{chunk_type}_{category}_{index}``
    - chunk_type, category, record_count, records
    """
    current_chunk: list[dict] = []
    current_size = 0

    for record in records:
        record_size = len(json.dumps(record).encode("utf-8"))

        if current_size + record_size > max_chunk_bytes and current_chunk:
            chunks.append({
                "chunk_id": f"{chunk_type}_{category}_{len(chunks)}",
                "chunk_type": chunk_type,
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
            "chunk_id": f"{chunk_type}_{category}_{len(chunks)}",
            "chunk_type": chunk_type,
            "category": category,
            "record_count": len(current_chunk),
            "records": current_chunk,
        })


def _build_git_summary_chunk(git_correlations: list[dict]) -> dict:
    """Build an aggregate summary chunk for git correlation data."""
    productive = [r for r in git_correlations if r["commits_count"] > 0]
    total_sessions = len(git_correlations)

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

    return {
        "chunk_id": "git_summary",
        "chunk_type": "git_correlation",
        "category": "summary",
        "data": {
            "total_sessions": total_sessions,
            "productive_sessions": len(productive),
            "unproductive_sessions": total_sessions - len(productive),
            "productivity_rate": round(len(productive) / max(total_sessions, 1), 3),
            "total_commits": sum(r["commits_count"] for r in git_correlations),
            "total_insertions": sum(r["insertions"] for r in git_correlations),
            "total_deletions": sum(r["deletions"] for r in git_correlations),
            "avg_session_duration_min": avg_duration,
            "avg_commits_per_message": avg_commits_per_msg,
        },
    }


def build_chunks(steerage: list[dict], errors: list[dict], stats: dict,
                 git_correlations: Optional[list[dict]] = None,
                 instruction_candidates: Optional[list[dict]] = None,
                 max_chunk_bytes: int = 80_000) -> list[dict]:
    """Build analysis-ready chunks that fit within model context.

    Each chunk is self-contained with:
    - A batch of steerage, error, or git correlation records
    - Enough context for the model to extract patterns
    - Metadata for deduplication
    """
    chunks: list[dict] = []

    # Chunk 0: Summary statistics (always first)
    chunks.append({
        "chunk_id": "stats",
        "chunk_type": "summary",
        "data": stats,
    })

    # Chunk steerage by category
    by_category: dict[str, list[dict]] = defaultdict(list)
    for record in steerage:
        for cls in record["classifications"]:
            by_category[cls["category"]].append(record)

    for category, records in by_category.items():
        _chunk_records(records, "steerage", category, chunks, max_chunk_bytes)

    # Chunk errors by category
    errors_by_cat: dict[str, list[dict]] = defaultdict(list)
    for record in errors:
        errors_by_cat[record["error_category"]].append(record)

    for category, records in errors_by_cat.items():
        _chunk_records(records, "error", category, chunks, max_chunk_bytes)

    # Chunk git correlations (split productive vs non-productive)
    if git_correlations:
        chunks.append(_build_git_summary_chunk(git_correlations))

        productive = [r for r in git_correlations if r["commits_count"] > 0]
        unproductive = [r for r in git_correlations if r["commits_count"] == 0]

        for batch_name, batch in [("productive", productive), ("unproductive", unproductive)]:
            _chunk_records(batch, "git", batch_name, chunks, max_chunk_bytes)

    # Chunk instruction candidates by target file
    if instruction_candidates:
        by_target: dict[str, list[dict]] = defaultdict(list)
        for record in instruction_candidates:
            by_target[record["target_file"]].append(record)
        for target, records in by_target.items():
            # Use a safe key: replace path separators with underscores
            safe_key = target.replace("/", "_").replace(".", "_")
            _chunk_records(records, "instruction_candidate", safe_key, chunks, max_chunk_bytes)

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
    if not args.db.exists():
        print(f"Error: Database not found at {args.db}", file=sys.stderr)
        sys.exit(1)
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

        # Phase 1e: Extract instruction candidates
        instruction_candidates = extract_instruction_candidates(conn, limit=args.limit)

        # Phase 2: Build chunks for model analysis
        if args.format == "chunks":
            chunks = build_chunks(steerage, errors, stats, git_correlations, instruction_candidates)
            out_path = write_output(chunks, args.output, fmt="chunks")
            print(f"\nOutput: {out_path}/", file=sys.stderr)
            print(f"  {len(chunks)} chunks written", file=sys.stderr)
            print(f"  {len(steerage)} steerage signals", file=sys.stderr)
            print(f"  {len(errors)} error sequences", file=sys.stderr)
            print(f"  {len(instruction_candidates)} instruction candidates", file=sys.stderr)
            if git_correlations is not None:
                productive = sum(1 for c in git_correlations if c["commits_count"] > 0)
                print(f"  {len(git_correlations)} git correlations ({productive} productive)", file=sys.stderr)
        else:
            all_records = [{"type": "stats", **stats}] + steerage + errors
            if git_correlations:
                all_records.extend(git_correlations)
            all_records.extend(instruction_candidates)
            out_path = write_output(all_records, args.output, fmt="jsonl")
            print(f"\nOutput: {out_path}", file=sys.stderr)
            print(f"  {len(steerage)} steerage + {len(errors)} errors + {len(instruction_candidates)} instruction candidates", file=sys.stderr)

        # Print summary to stdout
        summary = {
            "steerage_count": len(steerage),
            "error_count": len(errors),
            "instruction_candidates_count": len(instruction_candidates),
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
        if instruction_candidates:
            by_target: dict[str, int] = defaultdict(int)
            by_category: dict[str, int] = defaultdict(int)
            for c in instruction_candidates:
                by_target[c["target_file"]] += 1
                by_category[c["category"]] += 1
            summary["instruction_candidates"] = {
                "count": len(instruction_candidates),
                "by_target_file": dict(sorted(by_target.items(), key=lambda x: -x[1])),
                "by_category": dict(sorted(by_category.items(), key=lambda x: -x[1])),
                "avg_confidence": round(
                    sum(c["confidence"] for c in instruction_candidates) / len(instruction_candidates), 2,
                ),
            }
        print(json.dumps(summary, indent=2))

    finally:
        conn.close()


if __name__ == "__main__":
    main()
