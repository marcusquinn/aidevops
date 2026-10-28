"""Worker entry point for opt-in launchers without modifying PYTHONPATH."""

from worker_lifecycle.launch import main


if __name__ == "__main__":
    raise SystemExit(main())
