"""Selection and limits for the temporary legacy cleanup operation."""

from dataclasses import dataclass, field
import json
import math
import os
from pathlib import Path
import tempfile

from .cleanup_failure import failure_details
from .filesystem import validate_private_path as _private
from .process import ObservationUnavailable
from .pull_requests import PassPullRequests


def queue(store, items):
    """A private cursor gives bounded passes fair progress; it grants no authority."""
    cursor = store.directory / "legacy-cleanup-position"
    position = ""
    if os.path.lexists(cursor):
        _private(cursor)
        if cursor.stat().st_size > 8192:
            raise ValueError("invalid-legacy-cleanup-position")
        position = json.loads(cursor.read_text(encoding="utf-8"))
        if not isinstance(position, str):
            raise ValueError("invalid-legacy-cleanup-position")
    ordered = sorted(items, key=lambda item: item["path"])
    return ([item for item in ordered if item["path"] > position]
            + [item for item in ordered if item["path"] <= position])


def advance(store, path):
    """Atomically advance the persisted cleanup position."""
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8",
                                         dir=store.directory, delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(path, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, store.directory / "legacy-cleanup-position")
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def reconstructible_path(item, managed=False):
    """Bound the remote-recoverable class to owned, unpreserved managed paths.

    `managed` admits a modern-generation path only for the takeover of a worktree
    admission cleanup left stranded; every other guard here and in the caller applies.
    """
    path = Path(item["path"])
    base = Path(os.environ.get("AIDEVOPS_WORKTREE_BASE_DIR",
                               Path.home() / "Git" / "_worktrees")).expanduser()
    if not base.is_absolute() or base.resolve() != base:
        raise ValueError("outside-managed-worktree-base")
    if (path.resolve(strict=True) != path or not path.is_relative_to(base)
            or path == base):
        raise ValueError("outside-managed-worktree-base")
    patterns = ["preserved", "readonly", "recovery", "review"]
    patterns.extend(filter(None, os.environ.get(
        "AIDEVOPS_WORKTREE_PRESERVE_PATTERNS", "").lower().split(",")))
    if any(pattern in path.name.lower() for pattern in patterns):
        raise ValueError("preservation-name")
    if (item["modern"] and not managed) or path.stat().st_uid != os.geteuid():
        raise ValueError("managed-or-foreign-worktree")
    return path


def require_managed_takeover(check, *arguments, **keywords):
    """Run the takeover precheck without hiding its concrete retention reason."""
    return check(*arguments, **keywords)


def retained_outcome(item, error):
    """Report fields for a retained item: the concrete guard reason plus ownership."""
    fields = dict(status="retained", **failure_details(error))
    if item["modern"]:
        fields["ownership"] = "managed-by-current-cleanup"
    if isinstance(error, ObservationUnavailable):
        fields["reason"] = str(error)
    return fields


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
    """Validated options for one legacy cleanup pass."""
    root: Path
    apply: bool = False
    min_age: float = 3600
    limit: int = 25
    budget: float = 120
    confirmed_paths: tuple[str, ...] = ()
    # Per-pass lookup memo (GH#37181); grants no authority and is never compared.
    pull_requests: PassPullRequests = field(
        default_factory=PassPullRequests, compare=False, repr=False)

    def __post_init__(self):
        """Validate limits and confirmed paths."""
        if (not math.isfinite(self.min_age) or self.min_age < 0
                or not 1 <= self.limit <= 1000 or not 0 < self.budget <= 900):
            raise ValueError("invalid-cleanup-limits")
        if (len(self.confirmed_paths) > 1000
                or any(not isinstance(path, str) or not Path(path).is_absolute()
                       or str(Path(path).resolve()) != path
                       for path in self.confirmed_paths)):
            raise ValueError("canonical-confirmed-paths-required")

    def select(self, items):
        """Return the items selected by confirmed paths, or all items when none are confirmed."""
        if not self.confirmed_paths:
            return items
        by_path = {item["path"]: item for item in items}
        # Retain selected absent paths to resume interrupted private moves.
        # No other discovered path inherits the operator's confirmation.
        return [by_path.get(path, unrecorded(path))
                for path in sorted(set(self.confirmed_paths))]
