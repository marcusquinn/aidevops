"""Registry entry point without modifying PYTHONPATH."""

from worker_lifecycle.registry import main


if __name__ == "__main__":
    raise SystemExit(main())
