"""Sanitize archive-helper failures without exposing command arguments or paths."""

from pathlib import Path
import re
import subprocess  # nosec B404 # classify exceptions, never execute error argv

from .filesystem import FilesystemValidationError, filesystem_error_details
from .refusal import failure_category


def failure_details(error: Exception) -> dict:
    """Report stable diagnostics, never raw argv, stdout or stderr."""
    if isinstance(error, FilesystemValidationError):
        details: dict = filesystem_error_details(error)
    else:
        details = {"reason": type(error).__name__}
    if isinstance(error, ValueError) and re.fullmatch(r"[a-z][a-z0-9:_-]{0,159}", str(error)):
        details["reason"] = str(error)
    if isinstance(error, OSError) and error.errno is not None:
        details["errno"] = error.errno
    category = failure_category(error)
    if category:
        details["category"] = category
    if isinstance(error, (subprocess.CalledProcessError, subprocess.TimeoutExpired)):
        details.update(command_failure(error))
    return details


def command_failure(
    error: "subprocess.CalledProcessError | subprocess.TimeoutExpired",
) -> dict:
    details: dict = {"operation": "subprocess"}
    if isinstance(error, subprocess.CalledProcessError):
        details["returncode"] = error.returncode
    else:
        details["timeout_seconds"] = error.timeout
    command = error.cmd
    if not isinstance(command, (list, tuple)) or len(command) < 3:
        return details
    if (not isinstance(command[1], str)
            or Path(command[1]).name != "worktree-archive-helper.sh"
            or command[2] not in {"archive", "verify-local", "source-matches"}):
        return details
    details.update(operation=command[2], archive_failure=True)
    # Only the helper's namespaced validation code is useful here. Drop paths,
    # descriptions and all other stderr (which may contain sensitive Git URLs).
    stderr = error.stderr or b""
    text = stderr[-8192:]
    if isinstance(text, bytes):
        text = text.decode("utf-8", errors="replace")
    match = re.search(r"(?m)^ValueError: ((?:merge|git_admin):[a-z_]{1,64})(?::[^\n]*)?$", text)
    if match:
        details["reason"] = match[1]
    return details
