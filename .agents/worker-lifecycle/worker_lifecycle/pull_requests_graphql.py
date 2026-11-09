"""GraphQL open pull-request evidence for when REST lookups fail (GH#37385).

GraphQL draws on a separate rate-limit pool, so complete evidence stays
available while the REST core pool is spent. Any error or gap raises: a
failed or malformed response never proves absence.
"""

from __future__ import annotations

import json
import re
import subprocess  # nosec B404 # fixed gh argv, validated slug
from typing import TypeGuard

# Bounds: 100 pages of 100 open PRs, and fork chains this deep.
_GRAPHQL_PAGE_LIMIT = 100
_FORK_DEPTH_LIMIT = 10
_OPEN_PULLS_QUERY = (
    "query($owner:String!,$name:String!,$cursor:String){"
    "repository(owner:$owner,name:$name){isFork parent{nameWithOwner}"
    "pullRequests(states:OPEN,first:100,after:$cursor){"
    "pageInfo{hasNextPage endCursor}"
    "nodes{headRefName headRefOid headRepository{nameWithOwner}}}}}"
)


def valid_slug(name: object) -> TypeGuard[str]:
    """Accept only `owner/name` with no path traversal components."""
    return (isinstance(name, str)
            and re.fullmatch(r"[\w.-]+/[\w.-]+", name, flags=re.ASCII) is not None
            and not any(part in (".", "..") for part in name.split("/")))


def _repository_page(slug: str, cursor: str | None) -> dict:
    """Fetch one page of open PRs; any error or gap is no evidence."""
    owner, name = slug.split("/", 1)
    argv = ["gh", "api", "graphql", "-f", f"query={_OPEN_PULLS_QUERY}",
            "-f", f"owner={owner}", "-f", f"name={name}"]
    if cursor is not None:
        argv += ["-f", f"cursor={cursor}"]
    result = subprocess.run(  # nosec B603 B607 # fixed gh argv, validated slug
        argv, check=True, capture_output=True, text=True, timeout=60,
    )
    payload = json.loads(result.stdout)
    if not isinstance(payload, dict) or payload.get("errors"):
        raise ValueError("invalid-graphql-response")
    data = payload.get("data")
    repository = data.get("repository") if isinstance(data, dict) else None
    if not isinstance(repository, dict):
        raise ValueError("invalid-graphql-response")
    return repository


def _parent(repository: dict) -> str | None:
    """Return the fork parent, or None for a repository that is not a fork."""
    fork = repository.get("isFork")
    if fork is False:
        return None
    parent = repository.get("parent")
    name = parent.get("nameWithOwner") if isinstance(parent, dict) else None
    if fork is not True or not valid_slug(name):
        raise ValueError("invalid-repository-response")
    return name


def _pull_request(node: object) -> dict:
    """Map a GraphQL node to the REST `head` shape with the same validation."""
    if not isinstance(node, dict):
        raise ValueError("invalid-open-pr-response")
    head_repository = node.get("headRepository")
    full_name = (head_repository.get("nameWithOwner")
                 if isinstance(head_repository, dict) else None)
    head = {"ref": node.get("headRefName"), "sha": node.get("headRefOid"),
            "repo": {"full_name": full_name} if isinstance(full_name, str) else None}
    for field in ("ref", "sha"):
        if not isinstance(head[field], str) or not head[field]:
            raise ValueError("invalid-open-pr-response")
    return {"head": head}


def _repository_pull_requests(slug: str) -> tuple[list, str | None]:
    """Require every page from one repository; return its PRs and fork parent."""
    prs: list = []
    cursor = None
    for _ in range(_GRAPHQL_PAGE_LIMIT):
        repository = _repository_page(slug, cursor)
        parent = _parent(repository)
        connection = repository.get("pullRequests")
        page_info = connection.get("pageInfo") if isinstance(connection, dict) else None
        nodes = connection.get("nodes") if isinstance(connection, dict) else None
        if not isinstance(page_info, dict) or not isinstance(nodes, list):
            raise ValueError("invalid-open-pr-response")
        prs.extend(_pull_request(node) for node in nodes)
        if page_info.get("hasNextPage") is False:
            return prs, parent
        next_cursor = page_info.get("endCursor")
        if (page_info.get("hasNextPage") is not True or not isinstance(next_cursor, str)
                or not next_cursor or next_cursor == cursor):
            raise ValueError("invalid-open-pr-response")
        cursor = next_cursor
    raise ValueError("open-pr-page-limit")


def graphql_open_pull_requests(slug: str) -> list:
    """Complete open PRs for the repository and its whole fork chain.

    The chain to the root covers REST's parent and source (a superset).
    """
    if not valid_slug(slug):
        raise ValueError("invalid-repository-slug")
    prs: list = []
    seen: set[str] = set()
    repository = slug
    for _ in range(_FORK_DEPTH_LIMIT):
        seen.add(repository.lower())
        repository_prs, parent = _repository_pull_requests(repository)
        prs.extend(repository_prs)
        if parent is None or parent.lower() in seen:
            return prs
        repository = parent
    raise ValueError("fork-chain-depth-limit")
