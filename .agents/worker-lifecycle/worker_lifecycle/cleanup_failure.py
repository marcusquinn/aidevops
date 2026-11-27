"""Sanitize archive-helper failures without exposing command arguments or paths."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess  # nosec B404 # classify exceptions, never execute error argv

from .filesystem import FilesystemValidationError, filesystem_error_details
from .interrupted_removal import UnresumableHalfState
from .protected_proc import ProcessCensusUnavailable
from .refusal import failure_category


def failure_details(error: Exception) -> dict:
    """Report stable diagnostics, never raw argv, stdout or stderr."""
    if isinstance(error, UnresumableHalfState):
        # A structural half-removal is terminal, never a retryable guard refusal.
        details: dict = {"reason": error.code, "classification": "terminal"}
    elif isinstance(error, FilesystemValidationError):
        details = filesystem_error_details(error)
    else:
        details = {"reason": type(error).__name__}
    if isinstance(error, ValueError) and re.fullmatch(r"[a-z][a-z0-9:_-]{0,159}", str(error)):
        details["reason"] = str(error)
    if isinstance(error, ProcessCensusUnavailable):
        details["process_observation"] = error.observation
    if isinstance(error, OSError) and error.errno is not None:
        details["errno"] = error.errno
    category = failure_category(error)
    if category:
        details["category"] = category
    if isinstance(error, (subprocess.CalledProcessError, subprocess.TimeoutExpired)):
        details.update(command_failure(error))
    return details


_ARCHIVE_CODE = re.compile(
    r"(?m)^ValueError: ((?:merge|git_admin):[a-z_]{1,64}|archive-local:[a-z_-]{1,64})"
    r"(?:[:;][^\n]*)?$",
)


def archive_failure_code(stderr_text: str) -> str | None:
    """Namespaced validation code from helper stderr; never free text (GH#38056)."""
    match = _ARCHIVE_CODE.search(stderr_text)
    return match[1] if match else None


_GIT_SUBCOMMANDS = frozenset({
    "worktree", "branch", "update-ref", "symbolic-ref", "rev-parse", "status", "fetch",
    "for-each-ref", "merge-base", "rev-list", "config", "checkout", "reset", "clean",
    "gc", "prune", "remote", "show-ref", "cat-file", "ls-files", "diff", "log",
})


def _git_subcommand(command: "list | tuple") -> str | None:
    """Allowlisted `git <sub> [worktree-sub]` name from argv, skipping -C/-c options."""
    if not command or not isinstance(command[0], str) or Path(command[0]).name != "git":
        return None
    args = [str(a) for a in command[1:]]
    index = 0
    while index < len(args) and args[index].startswith("-"):
        index += 2 if args[index] in {"-C", "-c", "--git-dir", "--work-tree"} else 1
    if index >= len(args) or args[index] not in _GIT_SUBCOMMANDS:
        return None
    name = args[index]
    if name == "worktree" and index + 1 < len(args) and re.fullmatch(
            r"add|move|remove|prune|repair|list|lock|unlock", args[index + 1]):
        name += " " + args[index + 1]
    return name


def command_failure(
    error: "subprocess.CalledProcessError | subprocess.TimeoutExpired",
) -> dict:
    """Convert a subprocess failure into bounded, non-sensitive details."""
    details: dict = {"operation": "subprocess"}
    if isinstance(error, subprocess.CalledProcessError):
        details["returncode"] = error.returncode
    else:
        details["timeout_seconds"] = error.timeout
    command = error.cmd
    if not isinstance(command, (list, tuple)) or not command:
        return details
    git_sub = _git_subcommand(command)
    if git_sub:
        # GH#38997: name the failing Git subcommand; never its arguments or paths.
        details.update(operation=git_sub, command="git " + git_sub)
    elif (len(command) < 3 or not isinstance(command[1], str)
            or Path(command[1]).name != "worktree-archive-helper.sh"
            or command[2] not in {"archive", "verify-local", "verify-local-recorded",
                                  "source-matches"}):
        return details
    else:
        details.update(operation=command[2], archive_failure=True,
                       command="worktree-archive-helper.sh " + command[2])
    # Only the helper's namespaced validation code and a fixed stderr class are
    # useful here. Drop paths, descriptions and all other stderr (which may
    # contain sensitive Git URLs); free text is never copied.
    stderr = error.stderr or b""
    text = stderr[-8192:]
    if isinstance(text, bytes):
        text = text.decode("utf-8", errors="replace")
    code = None if git_sub else archive_failure_code(text)
    if code:
        details["reason"] = code
    for label, pattern in _STDERR_CLASSES:
        if re.search(pattern, text, flags=re.IGNORECASE):
            details["stderr_class"] = label
            break
    return details


# Fixed vocabulary: the emitted label is allowlisted, never the matched text.
_STDERR_CLASSES = (
    ("no-space", r"no space left on device"),
    ("permission-denied", r"permission denied|operation not permitted"),
    ("not-a-git-repository", r"not a git repository|not a valid git"),
    ("remote-unreachable", r"could not resolve host|connection (?:refused|timed out)|network is unreachable"),
    ("remote-access-failed", r"unable to access|requested url returned error"),
    ("index-lock", r"index\.lock|unable to create '.*\.lock'"),
    ("unmerged-or-dirty", r"unmerged|uncommitted|dirty|untracked"),
    ("missing-object", r"bad object|missing (?:blob|tree|commit)|unable to read tree"),
    ("not-found", r"no such file or directory"),
)
