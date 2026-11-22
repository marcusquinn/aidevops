"""Local process and rollback helpers for Buzz runtime installation."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

from datetime import datetime, timezone
import os
from pathlib import Path
import re
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


def repoint_stale_overrides(app_data_dir, runtime_id, pinned, store_backup):
    """Repoint only exact commands belonging to older anchors of this runtime."""
    from _team_interface_buzz_runtime_digest_refresh import read_store
    from _team_interface_buzz_runtime_io import canonical_payload

    path = app_data_dir / "agents" / "managed-agents.json"
    store = read_store(path)
    if store is None:
        return
    parent = Path.home() / ".aidevops" / "buzz-runtimes" / runtime_id
    command = str(pinned / "agents" / "bin" / "aidevops-buzz-acp-interactive")
    pattern = re.compile(
        re.escape(str(parent))
        + r"/(?:v2-)?[a-f0-9]{16}-[a-f0-9]{16}/agents/bin/aidevops-buzz-acp-interactive\Z"
    )
    changed = []
    for record in store:
        old = record.get("agent_command_override")
        if isinstance(old, str) and old != command and pattern.fullmatch(old):
            record["agent_command_override"] = command
            name = record.get("name")
            changed.append(name if isinstance(name, str) else "(unnamed)")
    if changed:
        if store_backup is None:
            store_backup = backup_existing(path, "managed-agents")
            print(f"Buzz managed agents backup: {store_backup}")
        atomic_write(path, canonical_payload(store))
    print(f"Buzz stale interactive overrides repointed: {len(changed)}")
    for name in changed:
        print(f"  {name}")


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
        store_backup = refresh_source_digests(app_data_dir, pinned / "agents")
        if store_backup is None and not unchanged:
            # Manifest replacement still needs a store snapshot for documented rollback.
            store_path = app_data_dir / "agents" / "managed-agents.json"
            if store_path.is_file() and not store_path.is_symlink():
                store_backup = backup_existing(store_path, "managed-agents")
                print(f"Buzz managed agents backup: {store_backup}")
        repoint_stale_overrides(app_data_dir, runtime_id, pinned, store_backup)
    if not unchanged:
        atomic_write(target, payload)
    return target, backup
