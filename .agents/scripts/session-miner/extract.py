#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
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
import sqlite3
import subprocess
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Optional

from extract_chunking import ChunkConfig, build_chunks
from extract_errors import extract_error_stats, extract_errors
from extract_git import extract_git_correlation
from extract_instructions import (
    INSTRUCTION_REDACTION_PLACEHOLDER as INSTRUCTION_REDACTION_PLACEHOLDER,
    INSTRUCTION_SECRET_ADJACENT_PATTERN as INSTRUCTION_SECRET_ADJACENT_PATTERN,
    INSTRUCTION_SIGNAL_PATTERNS as INSTRUCTION_SIGNAL_PATTERNS,
    TASK_SPECIFIC_DISQUALIFIERS as TASK_SPECIFIC_DISQUALIFIERS,
    _build_instruction_candidate_query as _build_instruction_candidate_query,
    _build_instruction_candidate_record as _build_instruction_candidate_record,
    _extract_message_instruction_candidates as _extract_message_instruction_candidates,
    _infer_target_file as _infer_target_file,
    _mark_instruction_text_seen as _mark_instruction_text_seen,
    _score_instruction_candidate as _score_instruction_candidate,
    classify_instruction_candidate as classify_instruction_candidate,
    extract_instruction_candidates as extract_instruction_candidates,
    extract_instruction_windows as extract_instruction_windows,
    redact_instruction_candidate_text as redact_instruction_candidate_text,
)
from extract_steerage import STEERAGE_PATTERNS, extract_steerage


# --- Configuration ---

DEFAULT_DB = Path.home() / ".local/share/opencode/opencode.db"
OUTPUT_DIR = Path.home() / ".aidevops/.agent-workspace/work/session-miner"
SCRIPT_DIR = Path(__file__).resolve().parents[1]
VAULT_HISTORY_HELPER = SCRIPT_DIR / "vault-managed-session-history-helper.sh"


def connect_db(db_path: Path) -> sqlite3.Connection:
    """Connect to session database read-only."""
    if not db_path.exists():
        print(f"Error: Database not found at {db_path}", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def resolve_managed_history_db(db_path: Path) -> Path:
    """Return the Vault-gated OpenCode DB path when managed history is enabled."""
    if not VAULT_HISTORY_HELPER.exists():
        return db_path
    if "AIDEVOPS_VAULT_MANAGED_SESSION_HISTORY" not in __import__("os").environ:
        return db_path
    # The command is a repo-controlled helper path plus literal arguments; no
    # user input reaches the argv vector. Keep the explicit annotation so
    # external Bandit/CodeFactor B603 checks do not block safe Vault gating.
    result = subprocess.run(  # nosec B603
        [str(VAULT_HISTORY_HELPER), "require-read", "opencode"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        message = result.stderr.strip() or "VAULT_LOCKED: managed session/history read denied"
        print(message, file=sys.stderr)
        sys.exit(result.returncode)
    return Path(result.stdout.strip())


def write_output(
    data: list[dict], output_dir: Path, fmt: str = "jsonl",
    extraction_metadata: Optional[dict[str, Optional[int]]] = None,
) -> Path:
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
            "extraction_metadata": extraction_metadata or {},
        }
        with open(out_path / "manifest.json", "w", encoding="utf-8") as f:
            json.dump(manifest, f, indent=2)

    return out_path


def _nonnegative_epoch_ms(value: str) -> int:
    """Parse a nonnegative epoch timestamp, rejecting unsafe silent fallbacks."""
    try:
        parsed = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("--since-ms must be an integer epoch in milliseconds") from error
    if parsed < 0:
        raise argparse.ArgumentTypeError("--since-ms must be a nonnegative epoch in milliseconds")
    return parsed


def _extraction_metadata(
    since_ms: Optional[int], steerage: list[dict], errors: list[dict],
    instruction_candidates: list[dict], git_correlations: Optional[list[dict]],
) -> dict[str, Optional[int]]:
    """Return an additive run watermark without mutating any scheduler state."""
    timestamps = [
        record["timestamp"] for record in steerage + errors + instruction_candidates
        if record.get("timestamp") is not None
    ]
    if git_correlations:
        timestamps.extend(record["session_end"] for record in git_correlations if record.get("session_end") is not None)
    high_water = max(timestamps) if timestamps else None
    return {
        "window_start_ms": since_ms,
        "window_end_ms": high_water,
        "source_high_water_ms": high_water,
    }


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
    parser.add_argument("--repo-dir", type=str, default=None,
                        help="Only extract sessions whose directory is this repo or a subdirectory")
    parser.add_argument("--since-ms", type=_nonnegative_epoch_ms, default=None,
                        help="Only process records newer than this epoch timestamp in milliseconds")
    args = parser.parse_args()
    args.db = resolve_managed_history_db(args.db)

    print(f"Session Miner — Extracting from {args.db}", file=sys.stderr)
    if not args.db.exists():
        print(f"Error: Database not found at {args.db}", file=sys.stderr)
        sys.exit(1)
    print(f"  DB size: {args.db.stat().st_size / 1024 / 1024:.1f} MB", file=sys.stderr)
    if args.repo_dir:
        print(f"  Repo scope: {args.repo_dir}", file=sys.stderr)
    if args.since_ms is not None:
        print(f"  High-water start: {args.since_ms}", file=sys.stderr)

    conn = connect_db(args.db)

    try:
        # Phase 1a: Extract steerage
        steerage = extract_steerage(conn, limit=args.limit, repo_dir=args.repo_dir, since_ms=args.since_ms)

        # Phase 1b: Extract errors
        errors = extract_errors(conn, limit=args.limit, repo_dir=args.repo_dir, since_ms=args.since_ms)

        # Phase 1c: Aggregate stats
        stats = extract_error_stats(conn, repo_dir=args.repo_dir, since_ms=args.since_ms)

        # Phase 1d: Extract git correlation (unless disabled)
        git_correlations = None
        if not args.no_git:
            git_correlations = extract_git_correlation(
                conn, limit=args.limit, repo_dir=args.repo_dir, since_ms=args.since_ms,
            )

        # Phase 1e: Extract instruction candidates
        instruction_candidates = extract_instruction_candidates(
            conn, limit=args.limit, repo_dir=args.repo_dir, since_ms=args.since_ms,
        )
        extraction_metadata = _extraction_metadata(
            args.since_ms, steerage, errors, instruction_candidates, git_correlations,
        )
        stats["extraction_metadata"] = extraction_metadata

        # Phase 2: Build chunks for model analysis
        if args.format == "chunks":
            chunk_config = ChunkConfig(
                stats=stats,
                git_correlations=git_correlations,
                instruction_candidates=instruction_candidates,
            )
            chunks = build_chunks(steerage, errors, chunk_config)
            out_path = write_output(
                chunks, args.output, fmt="chunks", extraction_metadata=extraction_metadata,
            )
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
            out_path = write_output(
                all_records, args.output, fmt="jsonl", extraction_metadata=extraction_metadata,
            )
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
            "extraction_metadata": extraction_metadata,
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
