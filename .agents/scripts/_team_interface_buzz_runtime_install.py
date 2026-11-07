"""Local process and rollback helpers for Buzz runtime installation."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

from datetime import datetime, timezone
import os
from pathlib import Path
import subprocess
import sys

from _team_interface_buzz_runtime_io import RuntimeError, atomic_write


def default_app_data_dir():
    """Return the supported local Buzz app-data directory."""
    configured = os.environ.get("AIDEVOPS_BUZZ_APP_DATA_DIR")
    if configured:
        candidate = Path(os.path.expanduser(configured))
        if not candidate.is_absolute():
            raise RuntimeError("AIDEVOPS_BUZZ_APP_DATA_DIR must be absolute")
        return candidate
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "xyz.block.buzz.app"
    raise RuntimeError("set AIDEVOPS_BUZZ_APP_DATA_DIR on this platform")


def buzz_is_running():
    """Return whether Buzz is running, with a deterministic test override."""
    override = os.environ.get("AIDEVOPS_BUZZ_RUNNING_OVERRIDE")
    if override in {"true", "1"}:
        return True
    if override in {"false", "0"} or sys.platform != "darwin":
        return False
    # Buzz Desktop 0.5.x runs as buzz-desktop; development bundles run as Buzz.
    # Mirrors _buzz_is_running in buzz-desktop-helper.sh.
    for process_name in ("Buzz", "buzz-desktop"):
        result = subprocess.run(  # nosec B603 -- absolute executable and fixed argv
            ["/usr/bin/pgrep", "-x", process_name],
            check=False,
            capture_output=True,
            timeout=5,
        )
        if result.returncode == 0:
            return True
    return False


def backup_existing(path, runtime_id):
    """Copy an existing manifest or agent store into private rollback storage."""
    if not path.exists():
        return None
    backup_dir = Path.home() / ".aidevops" / "buzz-backups"
    if backup_dir.is_symlink():
        raise RuntimeError("backup directory must not be a symbolic link")
    backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if backup_dir.is_symlink() or not backup_dir.is_dir():
        raise RuntimeError("backup directory is unsafe")
    os.chmod(backup_dir, 0o700)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup = backup_dir / f"{runtime_id}.{timestamp}.json"
    atomic_write(backup, path.read_bytes())
    return backup


def install_payload(app_data_dir, runtime_id, payload, replace, pinned):
    """Refresh eligible pointers before replacing a stopped Buzz runtime manifest."""
    # Imported lazily because digest refresh reuses this module's backup primitive.
    from _team_interface_buzz_runtime_digest_refresh import refresh_source_digests

    target = app_data_dir / "custom_harnesses" / f"{runtime_id}.json"
    backup = None
    unchanged = False
    if target.exists() or target.is_symlink():
        if target.is_symlink() or not target.is_file():
            raise RuntimeError("existing Buzz runtime path is not a regular file")
        unchanged = target.read_bytes() == payload
        if not unchanged and not replace:
            raise RuntimeError("Buzz runtime already exists with different content; inspect it or pass --replace")
        if not unchanged:
            backup = backup_existing(target, runtime_id)
    if pinned is not None:
        refresh_source_digests(app_data_dir, pinned / "agents")
    if not unchanged:
        atomic_write(target, payload)
    return target, backup
