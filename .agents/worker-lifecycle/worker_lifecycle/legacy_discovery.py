"""Read-only discovery for the temporary cleanup; paths grant no authority."""

from functools import partial
import os
from pathlib import Path
import subprocess  # nosec B404 # exception classification only

from .enrollment import _git_directory
from .retirement import _git, _id


def same_tree(path, plan):
    admin = Path(plan["admin"])
    if (_id(path) != plan["directory"] or _git_directory(path) != admin
            or _id(admin) != plan["admin_identity"]):
        raise ValueError("worktree-replaced")


def _registered(common: str) -> list[str]:
    output = _git("--git-dir", common, "worktree", "list", "--porcelain", "-z")
    paths = [field.removeprefix("worktree ") for field in output.split("\0")
             if field.startswith("worktree ")]
    if not paths:
        raise ValueError("empty-git-worktree-inventory")
    # Git lists the main (or bare) checkout first; it is not a linked worktree.
    return paths[1:]


def _directories(root: Path) -> list[str]:
    if not root.is_absolute() or root.resolve() != root:
        raise ValueError("noncanonical-worktree-root")
    try:
        return [str(path) for path in root.iterdir()
                if path.is_symlink() or path.is_dir()]
    except FileNotFoundError:
        return []


_CONTAINERS = (".lifecycle-retire-", ".legacy-retire-")


def _retirement_container(path: str) -> bool:
    """True for a private retirement container or the tree inside it.

    Each belongs to an in-flight retirement that resumes through its own
    journal; as a discovered candidate it is only noise (GH#37326).
    """
    candidate = Path(path)
    return any(name.startswith(_CONTAINERS)
               for name in (candidate.name, candidate.parent.name))


def discover(items, repositories):
    """Union Git registrations, central directories and historical registry paths.

    Missing process records remain missing. Never manufacture generations, owners
    or admission events; the existing inspector decides whether a path is eligible.
    """
    paths = {item["path"]: item for item in items}
    errors = []
    default_root = Path.home() / "Git" / "_worktrees"
    root = Path(os.environ.get("AIDEVOPS_WORKTREE_BASE_DIR", default_root)).expanduser()
    sources = [(str(root), partial(_directories, root))]
    sources.extend((common, partial(_registered, common))
                   for common in sorted(repositories))
    for source, collect in sources:
        try:
            found = collect()
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            errors.append({"path": source, "reason": type(error).__name__})
            continue
        for path in filter(lambda found_path: not _retirement_container(found_path), found):
            paths.setdefault(path, {
                "path": path, "generations": set(), "runs": {}, "last_event": 0,
                "modern": False, "unbound": True,
            })
    return sorted(paths.values(), key=lambda item: (item["last_event"], item["path"])), errors
