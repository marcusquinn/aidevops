"""Resume of an interrupted reconstructible native removal (GH#38158)."""

from collections.abc import Callable
from dataclasses import dataclass
import os
from pathlib import Path
import shutil

from .directory_handle import DirectoryHandle
from .interrupted_removal import removal_started, require_deletion_only
from .interrupted_removal import restore_git_link
from .legacy_discovery import same_tree
from .legacy_inventory import inventory
from .legacy_probe import event_id, host_probe, interrupted_probe, operation_id, receipt
from .legacy_probe import prepare_reconstructible_probe, verify_reconstructible
from .legacy_proc import require_ended, require_idle_processes
from .legacy_takeover import require_managed_authority
from .retirement import _id, _lock

# Journaled start of a reconstructible native removal; distinct from finish()'s
# "removing" phase, which shares the operation id.
RECONSTRUCTIBLE_REMOVING = "reconstructible-removing"


def restore_link(target, plan):
    """Bind tree and administration to the plan before restoring a deleted `.git`."""
    admin = Path(plan["admin"])
    if _id(target) != plan["directory"] or _id(admin) != plan["admin_identity"]:
        raise ValueError("worktree-replaced")
    restore_git_link(target, admin)


def current_legacy_item(connection, item):
    """Return the current inventory row for an item, or the item itself."""
    return next((row for row in inventory(connection)
                 if row["path"] == item["path"]), item)


def remove_orphaned_admin(plan, source):
    """Remove only this plan's identity-checked administration once its tree is gone."""
    admin = Path(plan["admin"])
    if not os.path.lexists(admin):
        return
    link = admin / "gitdir"
    if (admin.is_symlink() or _id(admin) != plan["admin_identity"]
            or not link.is_file() or link.read_text().strip() != str(source / ".git")):
        raise ValueError("worktree-admin-replaced")
    shutil.rmtree(admin)


@dataclass(frozen=True)
class RemovalContext:
    """Dependencies and repository scope retained across an interrupted removal."""
    adapter: object
    remove: Callable
    git: Callable
    repositories: dict | None = None


def resume_reconstructible_removal(store, connection, item, context):
    """Finish a journaled non-forced removal that timed out or was interrupted.

    Removal authority was established when the start was journaled. Like
    `finish`, a remaining tree must keep its identity and an idle census, and
    only deletions may follow the validation boundary; then a forced removal
    completes what the non-forced one began. `context.remove` runs native removal.
    """
    operation = operation_id(store, item["path"])
    journaled = receipt(connection, operation, RECONSTRUCTIBLE_REMOVING)
    started = removal_started(connection, event_id(operation, RECONSTRUCTIBLE_REMOVING))
    if journaled is None or started is None:
        raise ValueError("interrupted-removal-time-unavailable")
    plan = journaled["plan"]
    source = Path(plan["source"])
    if context.repositories is not None and plan["common"] not in context.repositories:
        raise ValueError("repository-out-of-scope")
    if os.path.lexists(source):
        # Census before opening our own handle on the tree.
        require_idle_processes(source)
        with DirectoryHandle(source):
            restore_link(source, plan)
            same_tree(source, plan)
            if context.git("-C", str(source), "rev-parse", "HEAD").strip() != plan["head"]:
                raise ValueError("interrupted-removal-head-changed")
            # Forced removal discards the index, including index-only staged content.
            if context.git("-C", str(source), "diff", "--cached", "--name-only",
                           plan["head"]).strip():
                raise ValueError("interrupted-removal-index-changed")
            current = current_legacy_item(connection, item)
            require_ended(current, context.adapter, operator_confirmed=True)
            if item["modern"]:
                require_managed_authority(store, connection, current, plan)
            require_deletion_only(source, started, context.git)
            context.remove(connection, "--git-dir", plan["common"], "worktree", "remove",
                           "--force", str(source))
    else:
        remove_orphaned_admin(plan, source)
    return plan, bool(journaled.get("probe", False))


def recover_interrupted_probe(store, item, apply):
    """Recover an interrupted probe removal; preview reports verification pending."""
    host = host_probe(store)
    with store.connection() as connection:
        if not interrupted_probe(store, connection, item):
            return
    if not apply:
        raise ValueError("reconstructible-probe-verification-pending")
    with _lock(store, host), store.connection(write=True) as connection:
        if interrupted_probe(store, connection, item):
            prepare_reconstructible_probe(store, connection, host, None, verify_reconstructible)


def plan_reconstructible(store, connection, item, inspect_source, open_prs):
    """Refresh the inventory row, build its plan and require managed authority.

    The managed flag is read from the caller's item, never the refreshed row, so
    every recheck keeps the managed path guard, idle floor and authority evidence.
    """
    current = current_legacy_item(connection, item)
    plan = inspect_source(current, open_prs=open_prs)
    if item["modern"]:
        require_managed_authority(store, connection, current, plan)
    return plan
