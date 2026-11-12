"""Stable, path-safe lifecycle CLI failure diagnostics."""

from .filesystem import FilesystemValidationError, filesystem_error_details
from .process import ObservationUnavailable
from .protected_proc import ProcessCensusUnavailable
from .refusal import failure_category, refusal_code
from .storage import StoreCapacity, StoreConflict


def error_details(error: Exception, operation: str) -> dict:
    """Translate CLI failures without exposing arbitrary system error text."""
    reason = str(error) if isinstance(error, (ObservationUnavailable, StoreCapacity)) else type(error).__name__
    if operation in {
        "retire-worktree", "cleanup", "cleanup-worktree", "upgrade", "retire-enrolled-only",
        "relinquish-session",
    } and isinstance(error, StoreConflict):
        reason = str(error)
    retirement = ("retire-worktree", "cleanup", "cleanup-worktree", "retire-enrolled-only")
    mode = "retirement" if operation in retirement else "observe-only"
    detail = {"mode": mode, "status": "unavailable", "reason": reason,
              "cleanup_authorized": False}
    if isinstance(error, ProcessCensusUnavailable):
        detail["reason"] = "ValueError"  # Keep the existing refusal classification.
        detail["process_observation"] = error.observation
    if isinstance(error, FilesystemValidationError):
        detail.update(filesystem_error_details(error))
    # GH#36142: name the enrollment refusal; OSError text may carry paths.
    if operation in {"enroll", "compact", "raise-capacity"} and isinstance(error, ValueError):
        detail["detail"] = str(error)[:200]
    # GH#36370/GH#36494: creation and targeted-retirement refusals carry a
    # stable code; `reason` stays unchanged.
    category = failure_category(error)
    if category:
        detail["category"] = category
    code = refusal_code(error, operation)
    if code:
        detail.setdefault("detail", code)
    return detail
