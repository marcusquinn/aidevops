#!/usr/bin/env python3
"""Temporary cleanup entrypoint for observation-era worktrees."""

from worker_lifecycle.legacy_cleanup import main

if __name__ == "__main__":
    raise SystemExit(main())
