"""Writer-release and open-PR lookup helpers for legacy cleanup."""

from contextlib import contextmanager
from functools import partial

from .pull_requests import open_pull_requests


@contextmanager
def writer_released(connection):
    """Release the global writer for archive, network or journaled removal work.

    The caller retains its operation lock and must revalidate registry writers
    after reacquisition. Native source move never runs in this scope; native
    removal runs here only through `remove_released`, after its start is
    journaled. Body failures propagate unchanged through the outer transaction's
    rollback. Only successful work reacquires the writer; failure to reacquire
    still aborts the next phase.
    """
    connection.commit()
    yield
    connection.execute("BEGIN IMMEDIATE")


def pass_pull_requests(options):
    """Pass-memoised open-PR lookup for prechecks and journaled plans (GH#37181)."""
    return partial(options.pull_requests.get, lookup=open_pull_requests)


def released_pull_requests(connection, options, slug):
    """Open-PR lookup that never holds the registry writer across the network.

    GitHub state is not serialized by the registry. A plan built with this
    lookup is only journaled; removal requires a refreshed plan whose local,
    registry and /proc checks all run under the reacquired writer (GH#36921).
    """
    with writer_released(connection):
        return pass_pull_requests(options)(slug)


def prefetched_pull_requests(connection, options, slug):
    """Freshly fetch the journaled plan's slug without the writer; serve only that.

    `plan["repo"]` is part of the compared plan, so a refreshed plan for any other
    repository never equals the journaled plan and removal is refused. This lookup
    is never served from the pass memo, so removal rests on current GitHub state.
    """
    with writer_released(connection):
        prs = options.pull_requests.refresh(slug, open_pull_requests)
    return lambda _requested: prs
