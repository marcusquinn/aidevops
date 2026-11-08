"""Fail-closed, trash-backed cleanup of unused Buzz runtime anchors."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess  # nosec B404 - fixed argv, no shell
import sys

from _team_interface_buzz_runtime_anchor import PINNED_RUNTIME_MARKER
from _team_interface_buzz_runtime_io import (
    RuntimeError as BuzzRuntimeError,
    require_safe_directory_chain,
    valid_runtime_marker,
)
from _team_interface_buzz_runtime_references import harness_references

VALIDATION_TIMEOUT_SECONDS = 30


@contextmanager
def runtime_anchor_lock():
    """Serialize CLI installs and pruning across all runtime profiles."""
    root = require_safe_directory_chain(Path.home() / ".aidevops" / "buzz-runtimes")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(root / ".prune.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise BuzzRuntimeError("Buzz runtime cleanup lock is unsafe")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise BuzzRuntimeError("another Buzz runtime install or prune is active") from error
        yield
    finally:
        os.close(descriptor)


def anchor_is_running(root):
    """Fail closed unless pgrep proves no process command references this anchor."""
    pgrep = shutil.which("pgrep")
    if not pgrep:
        raise BuzzRuntimeError("pgrep is required to prove Buzz runtime anchors are unused")
    result = subprocess.run(  # nosec B603 -- resolved executable and escaped literal path
        [pgrep, "-f", re.escape(str(root))],
        check=False, capture_output=True, timeout=VALIDATION_TIMEOUT_SECONDS,
    )
    if result.returncode not in (0, 1):
        raise BuzzRuntimeError("Buzz runtime process check failed; pruning refused")
    return result.returncode == 0


def trash_runtime_anchor(root):
    """Use the repository's trash/gio pattern, never a permanent-delete fallback."""
    for executable, arguments in (("trash", []), ("gio", ["trash"])):
        tool = shutil.which(executable)
        if not tool:
            continue
        result = subprocess.run(  # nosec B603 -- resolved executable and validated anchor path
            [tool, *arguments, str(root)],
            check=False, capture_output=True, timeout=VALIDATION_TIMEOUT_SECONDS,
        )
        if result.returncode == 0:
            return
    raise BuzzRuntimeError("no working Trash command (trash or gio); anchor retained")


def recognized_runtime_anchor(root, profile):
    """Restrict cleanup to owned real directories with a matching anchor marker."""
    if not re.fullmatch(r"v[0-9]+-[0-9a-f]{16}-[0-9a-f]{16}", root.name):
        return False
    metadata = root.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid():
        return False
    require_safe_directory_chain(root)
    marker = root / PINNED_RUNTIME_MARKER
    if marker.is_symlink() or not marker.is_file() or marker.stat().st_size > 64 * 1024:
        return False
    value = json.loads(marker.read_text(encoding="utf-8"))
    return valid_runtime_marker(value, profile["id"], int(root.name.split("-")[0][1:]))


def anchor_is_in_use(root, references):
    """Protect literal decoded manifest paths and process command references."""
    return any(str(root) in reference for reference in references) or anchor_is_running(root)


def prune_runtime_anchors(profile, app_data_dirs, dry_run=False):
    """Trash only recognized, unreferenced, idle siblings while holding the CLI lock."""
    parent = require_safe_directory_chain(
        Path.home() / ".aidevops" / "buzz-runtimes" / profile["id"]
    )
    if not parent.exists():
        return
    # Read every manifest before moving anything. Unknown or unreadable references
    # must not turn a partial inventory into permission to prune.
    references = harness_references(app_data_dirs)
    candidates = []
    for root in sorted(parent.iterdir()):
        if not recognized_runtime_anchor(root, profile):
            continue
        if anchor_is_in_use(root, references):
            continue
        candidates.append(root)
    for root in candidates:
        if dry_run:
            print(f"Would trash unused Buzz runtime anchor: {root}")
        else:
            # Recheck immediately before the move; processes may start during inventory.
            references = harness_references(app_data_dirs)
            if anchor_is_in_use(root, references):
                continue
            trash_runtime_anchor(root)
            print(f"Trashed unused Buzz runtime anchor: {root}")


def configured_app_data_dirs(values):
    """Combine explicit and configured directories after validating absolute paths."""
    directories = [Path(os.path.expanduser(value)) for value in values]
    configured = os.environ.get("AIDEVOPS_BUZZ_APP_DATA_DIR")
    if configured:
        directories.append(Path(os.path.expanduser(configured)))
    if any(not directory.is_absolute() for directory in directories):
        raise BuzzRuntimeError("Buzz app-data directories must be absolute")
    return directories


def prune_command(args, profile):
    """Validate explicit app-data locations before standalone pruning."""
    directories = configured_app_data_dirs(args.app_data_dir)
    if sys.platform != "darwin" and not directories:
        raise BuzzRuntimeError("set AIDEVOPS_BUZZ_APP_DATA_DIR or pass --app-data-dir")
    with runtime_anchor_lock():
        prune_runtime_anchors(profile, directories, args.dry_run)
    return 0
