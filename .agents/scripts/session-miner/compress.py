#!/usr/bin/env python3
"""
Session Miner — Phase 2: Compress extracted chunks into analysis-ready summaries.

Takes the chunked extraction output and produces compact summaries that fit
within a single model context window for analysis.

Compression strategy:
1. Extract only user_text from steerage records (drop metadata noise)
2. Deduplicate near-identical texts
3. Strip file contents / diffs that were pasted (keep only the user's words)
4. Group by category with frequency counts
5. For errors: extract only the pattern (tool + error_category + recovery)

Target: <100KB total output that captures all unique signals.
"""

import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path


CHUNKS_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else (
    Path.home() / ".aidevops/.agent-workspace/work/session-miner"
)

if not CHUNKS_DIR.exists():
    print(f"Error: Chunks directory not found at {CHUNKS_DIR}", file=sys.stderr)
    sys.exit(1)

OUTPUT = CHUNKS_DIR.parent / "compressed_signals.json"


def strip_file_content(text: str) -> str:
    """Remove pasted file contents, diffs, and code blocks from user text.
    
    Keep only the user's actual words/instructions.
    """
    # Remove <file>...</file> blocks
    text = re.sub(r'<file>.*?</file>', '[file content]', text, flags=re.DOTALL)
    
    # Remove diff blocks — match from "diff --git" to the next "diff --git" header
    # or end of string, capturing the full block (index line, ---, +++, @@ hunks, etc.)
    text = re.sub(r'diff --git .*?(?=\ndiff --git |\Z)', '[diff]', text, flags=re.DOTALL)
    
    # Remove lines that are clearly file content (numbered lines like "00001| ...")
    text = re.sub(r'\n\d{5}\|.*', '', text)
    
    # Remove URL-heavy lines (SonarCloud links etc)
    text = re.sub(r'https?://\S{80,}', '[url]', text)
    
    # Remove code blocks
    text = re.sub(r'```.*?```', '[code]', text, flags=re.DOTALL)
    
    # Collapse whitespace
    text = re.sub(r'\n{3,}', '\n\n', text)
    
    return text.strip()


def is_automated_message(text: str) -> bool:
    """Detect automated/templated messages that aren't real user steerage."""
    automated_patterns = [
        r'^/full-loop\b',
        r'^"You are the supervisor',
        r'^Continue if you have next steps',
        r'^Review the following potential duplicate',
        r'^Analyze the changes made since',
        r'^<file>\n\d{5}\|',
        r'^diff --git',
    ]
    for pattern in automated_patterns:
        if re.match(pattern, text, re.MULTILINE):
            return True
    return False


def normalize_for_dedup(text: str) -> str:
    """Normalize text for deduplication."""
    t = text.lower().strip()
    t = re.sub(r'\s+', ' ', t)
    t = re.sub(r'[^\w\s]', '', t)
    return t[:200]  # First 200 chars for comparison


def _extract_steerage_signal(record: dict, seen: set):
    """Extract a cleaned, deduplicated signal from a steerage record.

    Returns a signal dict or None if the record should be skipped.
    """
    raw_text = record.get("user_text", "")
    if not raw_text or len(raw_text) < 25:
        return None

    if is_automated_message(raw_text):
        return None

    clean_text = strip_file_content(raw_text)
    if len(clean_text) < 20:
        return None

    norm = normalize_for_dedup(clean_text)
    if norm in seen:
        return None
    seen.add(norm)

    return {
        "text": clean_text[:1000],
        "context": record.get("preceding_context", "")[:200],
    }


def compress_steerage(chunks_dir: Path) -> dict:
    """Compress all steerage chunks into category-grouped unique signals."""
    categories = defaultdict(list)
    seen = set()

    for chunk_file in sorted(chunks_dir.glob("steerage_*.json")):
        try:
            chunk = json.loads(chunk_file.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue

        category = chunk.get("category", "unknown")

        for record in chunk.get("records", []):
            signal = _extract_steerage_signal(record, seen)
            if signal is not None:
                categories[category].append(signal)

    return dict(categories)


_SEVERITY_RANK = {
    "permission": "high",
    "not_read_first": "high",
    "edit_stale_read": "medium",
    "edit_mismatch": "medium",
    "edit_multiple": "medium",
    "file_not_found": "medium",
    "timeout": "low",
    "exit_code": "low",
    "other": "low",
}


def _accumulate_error_record(record: dict, pattern_counts, pattern_examples,
                             recovery_patterns, pattern_models):
    """Accumulate a single error record into the pattern aggregation structures."""
    tool = record.get("tool", "unknown")
    cat = record.get("error_category", "other")
    key = f"{tool}:{cat}"

    pattern_counts[key] += 1
    model_id = record.get("model") or "unknown"
    pattern_models[key].add(model_id)

    if len(pattern_examples[key]) < 3:
        example = {
            "error": record.get("error_text", "")[:200],
            "input": record.get("tool_input_summary", ""),
            "user_response": record.get("user_response", "")[:200] if record.get("user_response") else None,
        }
        pattern_examples[key].append(example)

    recovery = record.get("recovery")
    if recovery:
        recovery_desc = f"{recovery.get('tool', '')}: {recovery.get('approach', '')}"
        if recovery_desc not in recovery_patterns[key]:
            recovery_patterns[key].append(recovery_desc)


def _build_error_patterns(pattern_counts, pattern_examples, recovery_patterns, pattern_models):
    """Build the final compressed error summary from aggregated data."""
    error_patterns = []
    for key, count in pattern_counts.most_common():
        tool, cat = key.split(":", 1)
        models = sorted(pattern_models.get(key, set()))
        model_count = len(models)
        error_patterns.append({
            "tool": tool,
            "error_category": cat,
            "count": count,
            "models": models,
            "model_count": model_count,
            "cross_model": model_count >= 2,
            "severity": _SEVERITY_RANK.get(cat, "low"),
            "examples": pattern_examples[key],
            "recovery_patterns": recovery_patterns.get(key, [])[:3],
        })
    return error_patterns


def compress_errors(chunks_dir: Path) -> dict:
    """Compress error chunks into pattern summaries."""
    pattern_counts = Counter()
    pattern_examples = defaultdict(list)
    recovery_patterns = defaultdict(list)
    pattern_models = defaultdict(set)

    for chunk_file in sorted(chunks_dir.glob("error_*.json")):
        try:
            chunk = json.loads(chunk_file.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue

        for record in chunk.get("records", []):
            _accumulate_error_record(record, pattern_counts, pattern_examples,
                                     recovery_patterns, pattern_models)

    return {"patterns": _build_error_patterns(pattern_counts, pattern_examples,
                                               recovery_patterns, pattern_models)}


def compress_git_correlation(chunks_dir: Path) -> dict:
    """Compress git correlation chunks into productivity summaries.

    Groups sessions by project, computes per-project and overall productivity
    metrics, and identifies the most/least productive session patterns.
    """
    # Load summary chunk first
    summary_file = chunks_dir / "git_summary.json"
    summary = {}
    if summary_file.exists():
        try:
            chunk = json.loads(summary_file.read_text(encoding="utf-8"))
            summary = chunk.get("data", {})
        except (json.JSONDecodeError, OSError):
            pass

    # Collect all productive session records
    by_project = defaultdict(list)
    all_sessions = []

    for chunk_file in sorted(chunks_dir.glob("git_*.json")):
        if chunk_file.name == "git_summary.json":
            continue
        try:
            chunk = json.loads(chunk_file.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue

        for record in chunk.get("records", []):
            project = record.get("session_dir", "unknown")
            by_project[project].append(record)
            all_sessions.append(record)

    # Per-project productivity
    project_stats = {}
    for project, sessions in sorted(by_project.items(), key=lambda x: -len(x[1])):
        productive = [s for s in sessions if s.get("commits_count", 0) > 0]
        total_commits = sum(s.get("commits_count", 0) for s in sessions)
        total_insertions = sum(s.get("insertions", 0) for s in sessions)
        total_deletions = sum(s.get("deletions", 0) for s in sessions)
        project_stats[project] = {
            "sessions": len(sessions),
            "productive_sessions": len(productive),
            "total_commits": total_commits,
            "total_lines_changed": total_insertions + total_deletions,
            "avg_commits_per_message": round(
                sum(s.get("commits_per_message", 0) for s in productive)
                / max(len(productive), 1), 3,
            ),
        }

    # Top productive sessions (by commits_per_message, min 2 commits)
    top_productive = sorted(
        [s for s in all_sessions if s.get("commits_count", 0) >= 2],
        key=lambda s: s.get("commits_per_message", 0),
        reverse=True,
    )[:10]

    top_sessions = [
        {
            "title": s.get("session_title", "")[:100],
            "project": s.get("session_dir", ""),
            "commits": s.get("commits_count", 0),
            "messages": s.get("user_messages", 0),
            "ratio": s.get("commits_per_message", 0),
            "duration_min": s.get("duration_minutes", 0),
        }
        for s in top_productive
    ]

    return {
        "summary": summary,
        "project_stats": project_stats,
        "top_productive_sessions": top_sessions,
    }


def main():
    print(f"Compressing chunks from {CHUNKS_DIR}", file=sys.stderr)

    steerage = compress_steerage(CHUNKS_DIR)
    errors = compress_errors(CHUNKS_DIR)
    git_correlation = compress_git_correlation(CHUNKS_DIR)

    # Load stats
    stats_file = CHUNKS_DIR / "stats.json"
    stats = {}
    if stats_file.exists():
        try:
            stats = json.loads(stats_file.read_text(encoding="utf-8")).get("data", {})
        except json.JSONDecodeError:
            print(f"Warning: Could not parse {stats_file}, skipping stats.", file=sys.stderr)

    output = {
        "steerage": steerage,
        "steerage_counts": {k: len(v) for k, v in steerage.items()},
        "errors": errors,
        "stats": stats,
        "git_correlation": git_correlation,
    }

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(output, indent=2, ensure_ascii=False), encoding="utf-8")

    total_steerage = sum(len(v) for v in steerage.values())
    total_errors = len(errors.get("patterns", []))
    file_size = OUTPUT.stat().st_size

    print(f"Output: {OUTPUT}", file=sys.stderr)
    print(f"  {total_steerage} unique steerage signals", file=sys.stderr)
    print(f"  {total_errors} error patterns", file=sys.stderr)
    print(f"  {file_size / 1024:.1f} KB", file=sys.stderr)

    # Print category breakdown
    for cat, signals in sorted(steerage.items(), key=lambda x: -len(x[1])):
        print(f"  steerage/{cat}: {len(signals)} unique signals", file=sys.stderr)

    # Print git correlation summary
    git_summary = git_correlation.get("summary", {})
    if git_summary:
        print(
            f"  git: {git_summary.get('productive_sessions', 0)}"
            f"/{git_summary.get('total_sessions', 0)} productive sessions,"
            f" {git_summary.get('total_commits', 0)} commits",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
