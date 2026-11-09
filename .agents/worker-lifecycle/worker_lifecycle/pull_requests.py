"""Open pull-request evidence shared by every automatic worktree retirement path.

A failed or malformed API response never proves absence: callers must hold.
"""

from __future__ import annotations

from collections.abc import Callable
import json
from pathlib import Path
import subprocess  # nosec B404 # fixed gh argv, validated slug

from .pull_requests_graphql import graphql_open_pull_requests
from .pull_requests_graphql import valid_slug as _valid_slug
from .retirement import _git


def pull_request_repositories(slug: str) -> list[str]:
    """Include the fork's parent and source, where upstream PRs are listed."""
    if not _valid_slug(slug):
        raise ValueError("invalid-repository-slug")
    result = subprocess.run(  # nosec B603 B607 # fixed gh argv, validated slug
        ["gh", "api", f"repos/{slug}"],
        check=True, capture_output=True, text=True, timeout=60,
    )
    metadata = json.loads(result.stdout)
    if not isinstance(metadata, dict) or not isinstance(metadata.get("fork"), bool):
        raise ValueError("invalid-repository-response")
    repositories = [slug]
    if metadata["fork"]:
        for key in ("parent", "source"):
            repository = metadata.get(key)
            name = repository.get("full_name") if isinstance(repository, dict) else None
            if not _valid_slug(name):
                raise ValueError("invalid-repository-response")
            if name.lower() not in {item.lower() for item in repositories}:
                repositories.append(name)
    return repositories


def _repository_pull_requests(slug: str) -> list:
    """Require all pages from one validated repository."""
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
        if not isinstance(pr, dict) or not isinstance(pr.get("head"), dict):
            raise ValueError("invalid-open-pr-response")
        for field in ("ref", "sha"):
            value = pr["head"].get(field)
            if not isinstance(value, str) or not value:
                raise ValueError("invalid-open-pr-response")
    return prs


def _rest_open_pull_requests(slug: str) -> list:
    """All fork/upstream REST pages for `slug`."""
    return [pr for repository in pull_request_repositories(slug)
            for pr in _repository_pull_requests(repository)]


def open_pull_requests(slug):
    """All fork/upstream pages or no authority; errors never prove absence.

    A failed REST call, including a `gh` governor deferral (exit 75) while the
    REST core pool is spent, retries with complete GraphQL evidence from its
    separate pool (GH#37385). Malformed REST evidence still holds, and a
    failed or malformed GraphQL fallback re-raises the REST error.
    """
    try:
        return _rest_open_pull_requests(slug)
    except (OSError, subprocess.SubprocessError) as rest_error:
        try:
            return graphql_open_pull_requests(slug)
        except (OSError, ValueError, subprocess.SubprocessError):
            raise rest_error from None


def matches_open_pull_request(prs: list, head: str, branch: str, slug: str) -> bool:
    """Match exact commits anywhere, or attached branches in the configured repo."""
    name = branch.removeprefix("refs/heads/") if branch.startswith("refs/heads/") else ""
    for pr in prs:
        if pr["head"]["sha"] == head:
            return True
        repository = pr["head"].get("repo")
        full_name = repository.get("full_name") if isinstance(repository, dict) else None
        if (name and pr["head"]["ref"] == name and isinstance(full_name, str)
                and full_name.lower() == slug.lower()):
            return True
    return False


def worktree_identity(path: Path) -> tuple[str, str]:
    """Return the worktree HEAD commit and symbolic ref (``HEAD`` when detached)."""
    head = _git("-C", str(path), "rev-parse", "HEAD")
    branch = _git("-C", str(path), "rev-parse", "--symbolic-full-name", "HEAD")
    return head, branch


class OpenPullRequestCache:
    """One complete fork/upstream lookup per configured slug per cleanup pass."""

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
        if matches_open_pull_request(prs, head, branch, slug):
            return "open-pull-request"
        return None


class PassPullRequests:
    """Per-pass open-PR memo for the observation-era cleanup (GH#37181).

    Prechecks and journaled plans reuse one lookup per slug; `refresh` always
    queries again for the check immediately before removal. A failed lookup,
    including a `gh` governor deferral (exit 75), is remembered for the rest of
    the pass so it is not retried per item. It never proves absence: callers
    see `pull-request-state-unavailable` and hold.
    """

    def __init__(self):
        """Start a new pass with no cached pull-request observations."""
        self.results: dict[str, list | Exception] = {}

    def get(self, slug: str, lookup: Callable[[str], list]) -> list:
        """Return the pass result for `slug`, looking it up once."""
        if slug not in self.results:
            return self.refresh(slug, lookup)
        return self._value(slug)

    def refresh(self, slug: str, lookup: Callable[[str], list]) -> list:
        """Look `slug` up again and remember the outcome for the pass."""
        try:
            self.results[slug] = lookup(slug)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            self.results[slug] = error
        return self._value(slug)

    def _value(self, slug: str) -> list:
        """Return the cached result or surface a cached lookup failure."""
        result = self.results[slug]
        if isinstance(result, Exception):
            raise ValueError("pull-request-state-unavailable") from result
        return result
