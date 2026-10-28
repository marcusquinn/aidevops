"""Worker observation entry point without modifying PYTHONPATH."""

from worker_lifecycle.launch import main


if __name__ == "__main__":
    raise SystemExit(main())
