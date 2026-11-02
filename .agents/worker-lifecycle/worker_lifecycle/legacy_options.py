"""Selection and limits for the temporary legacy cleanup operation."""

from dataclasses import dataclass
import math
from pathlib import Path


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
