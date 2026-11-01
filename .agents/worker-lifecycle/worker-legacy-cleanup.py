#!/usr/bin/env python3
"""Temporary cleanup entrypoint for observation-era worktrees."""

import argparse
import json
from pathlib import Path
import sqlite3
import subprocess  # nosec B404 # exception classification only

from worker_lifecycle.legacy_cleanup import run
from worker_lifecycle.process import ObservationUnavailable
from worker_lifecycle.storage import LifecycleRegistry


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--repos-config", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--min-age-seconds", type=float, default=3600)
    parser.add_argument("--limit", type=int, default=25)
    parser.add_argument("--budget-seconds", type=float, default=120)
    args = parser.parse_args()
    try:
        result = run(
            LifecycleRegistry(args.state_dir), args.repos_config, args.output_root,
            apply=args.apply, min_age=args.min_age_seconds, limit=args.limit,
            budget=args.budget_seconds,
        )
    except (ValueError, OSError, sqlite3.Error, subprocess.SubprocessError,
            ObservationUnavailable) as error:
        reason = (str(error) if isinstance(error, (ValueError, ObservationUnavailable))
                  else type(error).__name__)
        print(json.dumps({"status": "unavailable", "reason": reason}))
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
