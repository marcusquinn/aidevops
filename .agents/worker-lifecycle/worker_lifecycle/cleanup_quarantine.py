"""Advisory backoff for admission-cleanup candidates whose archive keeps failing.

The state only delays attempts and never grants retirement authority. Unreadable
state degrades to "no quarantine", never to skipped safety checks.
"""

import json
import math
import os
from pathlib import Path
import tempfile
import time

from .filesystem import validate_private_path as _private

_BASE_SECONDS = 900
_MAX_SECONDS = 86400
_MAX_ENTRIES = 1000
_MAX_BYTES = 262144


def _finite_number(value: object) -> bool:
    """Return True for a finite non-boolean int or float."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    return math.isfinite(value)


def _valid(key: object, value: object) -> bool:
    """Return True when a quarantine entry has a string key and a well-formed value."""
    if not isinstance(key, str) or not isinstance(value, dict):
        return False
    return isinstance(value.get("count"), int) and _finite_number(value.get("until"))


class CleanupQuarantine:
    """Durable per-generation backoff, loaded once and saved once per pass."""

    def __init__(self, directory: Path):
        """Load quarantine entries from the given store directory."""
        self.directory = Path(directory)
        self.path = self.directory / "cleanup-quarantine"
        self.entries = self._load()
        self.changed = False

    def _load(self) -> dict:
        """Load valid entries from the private quarantine file, or an empty dict."""
        try:
            _private(self.path)
            if self.path.stat().st_size > _MAX_BYTES:
                return {}
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (FileNotFoundError, ValueError, OSError):
            return {}
        if not isinstance(data, dict):
            return {}
        return {key: value for key, value in data.items() if _valid(key, value)}

    def partition(self, rows: list) -> tuple[list, int]:
        """Drop candidates in backoff before the pass limit applies.

        A few recurring archive/verify-local failures then cannot occupy the
        front of every run and starve the remaining eligible generations.
        """
        now = time.time()
        ready = [row for row in rows
                 if self.entries.get(row["generation_id"], {}).get("until", 0) <= now]
        return ready, len(rows) - len(ready)

    def record(self, generation: str, result: dict, retry_later: bool = False) -> None:
        """Back off exponentially on archive failure or a caller-requested retry.

        Clear on any other outcome.
        """
        if not (result.get("archive_failure", False) or retry_later):
            self.changed |= self.entries.pop(generation, None) is not None
            return
        count = int(self.entries.get(generation, {}).get("count", 0)) + 1
        delay = min(_BASE_SECONDS * 2 ** min(count - 1, 10), _MAX_SECONDS)
        self.entries[generation] = {"count": count, "until": time.time() + delay}
        result.update(quarantined=True, quarantine_failures=count)
        self.changed = True

    def save(self, report: dict) -> None:
        """Persist changes; a write failure must not hide the pass report."""
        if not self.changed:
            return
        try:
            self._write()
        except OSError:
            report["quarantine_unavailable"] = True

    def _write(self) -> None:
        """Persist the retained entries atomically."""
        temporary = None
        # Keep the file bounded: retain the entries that expire last.
        kept = dict(sorted(self.entries.items(), key=lambda pair: pair[1]["until"])
                    [-_MAX_ENTRIES:])
        try:
            with tempfile.NamedTemporaryFile(
                mode="w", encoding="utf-8", dir=self.directory,
                prefix=".cleanup-quarantine-", delete=False,
            ) as stream:
                temporary = Path(stream.name)
                json.dump(kept, stream)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
