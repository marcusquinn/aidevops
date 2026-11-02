"""Selection and limits for the temporary legacy cleanup operation."""

from dataclasses import dataclass
import math
from pathlib import Path


def unrecorded(path):
    """An inventory observation, not a fabricated registry row or owner."""
    return {"path": path, "generations": set(), "runs": {}, "last_event": 0,
            "modern": False, "unbound": True}


def require_manual_confirmation(receipts, confirmed):
    """Interrupted manual work cannot acquire automatic execution authority."""
    if confirmed:
        return
    for previous in receipts:
        if previous and previous.get("operator_confirmed") is True:
            raise ValueError("operator-confirmation-required")


@dataclass(frozen=True)
class CleanupOptions:
    root: Path
    apply: bool = False
    min_age: float = 3600
    limit: int = 25
    budget: float = 120
    confirmed_paths: tuple[str, ...] = ()

    def __post_init__(self):
        if (not math.isfinite(self.min_age) or self.min_age < 0
                or not 1 <= self.limit <= 1000 or not 0 < self.budget <= 900):
            raise ValueError("invalid-cleanup-limits")
        if (len(self.confirmed_paths) > 1000
                or any(not isinstance(path, str) or not Path(path).is_absolute()
                       or str(Path(path).resolve()) != path
                       for path in self.confirmed_paths)):
            raise ValueError("canonical-confirmed-paths-required")

    def select(self, items):
        if not self.confirmed_paths:
            return items
        by_path = {item["path"]: item for item in items}
        # Retain selected absent paths to resume interrupted private moves.
        # No other discovered path inherits the operator's confirmation.
        return [by_path.get(path, unrecorded(path))
                for path in sorted(set(self.confirmed_paths))]
