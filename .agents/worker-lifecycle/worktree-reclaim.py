"""Finished-worktree reclaim entry point without modifying PYTHONPATH."""

from worker_lifecycle.reclaim.sweep import main


if __name__ == "__main__":
    raise SystemExit(main())
