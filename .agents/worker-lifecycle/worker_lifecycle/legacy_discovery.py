"""Read-only discovery for the temporary cleanup; paths grant no authority."""

import os
from pathlib import Path
import subprocess  # nosec B404 # exception classification only

from .retirement import _git


def _registered(common):
    output = _git("--git-dir", common, "worktree", "list", "--porcelain", "-z")
    paths = [field.removeprefix("worktree ") for field in output.split("\0")
             if field.startswith("worktree ")]
    if not paths:
        raise ValueError("empty-git-worktree-inventory")
    # Git lists the main (or bare) checkout first; it is not a linked worktree.
    return paths[1:]


def _directories(root):
    if not root.is_absolute() or root.resolve() != root:
        raise ValueError("noncanonical-worktree-root")
    try:
        return [str(path) for path in root.iterdir()
                if path.is_symlink() or path.is_dir()]
    except FileNotFoundError:
        return []


def discover(items, repositories):
    """Union Git registrations, central directories and historical registry paths.

    Missing process records remain missing. Never manufacture generations, owners
    or admission events; the existing inspector decides whether a path is eligible.
    """
    paths = {item["path"]: item for item in items}
    errors = []
    default_root = Path.home() / "Git" / "_worktrees"
    root = Path(os.environ.get("AIDEVOPS_WORKTREE_BASE_DIR", default_root)).expanduser()
    sources = [(str(root), lambda: _directories(root))]
    sources.extend((common, lambda common=common: _registered(common))
                   for common in sorted(repositories))
    for source, collect in sources:
        try:
            found = collect()
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            errors.append({"path": source, "reason": type(error).__name__})
            continue
        for path in found:
            paths.setdefault(path, {
                "path": path, "generations": set(), "runs": {}, "last_event": 0,
                "modern": False, "unbound": True,
            })
    return sorted(paths.values(), key=lambda item: (item["last_event"], item["path"])), errors
