"""Open pull-request evidence shared by every automatic worktree retirement path.

A failed or malformed API response never proves absence: callers must hold.
"""

from __future__ import annotations

import json
from pathlib import Path
import subprocess  # nosec B404 # fixed gh argv, validated slug

from .retirement import _git


def open_pull_requests(slug):
    """All pages or no authority; never infer absence from a failed API call."""
    result = subprocess.run(  # nosec B603 B607 # fixed gh argv, validated slug
        ["gh", "api", "--paginate", "--slurp",
         f"repos/{slug}/pulls?state=open&per_page=100"],
        check=True, capture_output=True, text=True, timeout=60,
    )
    pages = json.loads(result.stdout)
    if (not isinstance(pages, list) or not pages
            or any(not isinstance(page, list) for page in pages)):
        raise ValueError("invalid-open-pr-response")
    prs = [pr for page in pages for pr in page]
    for pr in prs:
        if (not isinstance(pr, dict) or not isinstance(pr.get("head"), dict)
                or not isinstance(pr["head"].get("ref"), str)
                or not isinstance(pr["head"].get("sha"), str)):
            raise ValueError("invalid-open-pr-response")
    return prs


def matches_open_pull_request(prs: list, head: str, branch: str) -> bool:
    """Match by exact head commit, or by branch name for an attached HEAD."""
    name = branch.removeprefix("refs/heads/") if branch.startswith("refs/heads/") else ""
    return any(pr["head"]["sha"] == head or bool(name and pr["head"]["ref"] == name)
               for pr in prs)


def worktree_identity(path: Path) -> tuple[str, str]:
    """Return the worktree HEAD commit and symbolic ref (``HEAD`` when detached)."""
    head = _git("-C", str(path), "rev-parse", "HEAD")
    branch = _git("-C", str(path), "rev-parse", "--symbolic-full-name", "HEAD")
    return head, branch


class OpenPullRequestCache:
    """One paginated lookup per repository slug per cleanup pass."""

    def __init__(self, lookup=None):
        # Resolve at construction so a patched module function is honoured.
        self.lookup = lookup or open_pull_requests
        self.results: dict[str, list | None] = {}

    def hold_reason(self, path: Path, slug: str) -> str | None:
        """Return a hold reason, or None when no open PR protects the tree.

        A checkout without configured remotes has no pushed branch to protect.
        """
        if not _git("-C", str(path), "remote"):
            return None
        head, branch = worktree_identity(path)
        if slug not in self.results:
            try:
                self.results[slug] = self.lookup(slug)
            except (OSError, ValueError, subprocess.SubprocessError):
                self.results[slug] = None
        prs = self.results[slug]
        if prs is None:
            return "pull-request-state-unavailable"
        if matches_open_pull_request(prs, head, branch):
            return "open-pull-request"
        return None
