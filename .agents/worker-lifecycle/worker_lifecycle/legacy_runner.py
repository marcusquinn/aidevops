"""Bounded pass orchestration and reporting for temporary legacy cleanup."""

from collections import Counter
import time

from .archive_path import create_archive_root, validate_archive_path
from .cleanup import _repositories
from .legacy_cleanup import process_item, sweep_staging
from .legacy_discovery import discover
from .legacy_inventory import inventory
from .legacy_options import CleanupOptions, advance, queue
from .legacy_proc import collect_proc_observations
from .runtime import adapter_for, require_ready


def run(store, config, root, **arguments):
    options = CleanupOptions(root, **arguments)
    repositories = _repositories(config)
    adapter = adapter_for(store.installation_id())
    require_ready(adapter)
    # The budget bounds the whole pass, discovery included (GH#38158): items
    # start only before the deadline, so a pass ends within it plus one item.
    deadline = time.monotonic() + options.budget
    with store.connection() as connection:
        items = inventory(connection)
    items, discovery_errors = discover(items, repositories)
    items = options.select(items)
    staging = []
    if options.apply:
        if not root.is_absolute() or root.resolve() != root:
            raise ValueError("canonical-output-root-required")
        create_archive_root(root)
        validate_archive_path(root)
        items = queue(store, items)
        # Independent of the rotation above: private retirement containers are
        # enumerated from the filesystem and finished or reported (GH#40569).
        staging = sweep_staging(store, repositories, adapter, options)
    report: dict = {
        "status": "legacy-cleanup", "apply": options.apply, "paths": len(items),
        "generations": sum(len(i["generations"]) for i in items),
        "retired": 0, "eligible": 0, "attempted": 0, "results": [],
        "skipped_nondumpable": 0,
        "discovery_errors": discovery_errors,
        "operator_confirmed_paths": list(options.confirmed_paths),
        "staging": staging,
        "staging_completed": sum(
            result.get("status") in ("retired", "already-retired") for result in staging),
    }
    for item in items:
        if (time.monotonic() >= deadline
                or (options.apply and report["attempted"] >= options.limit)):
            break
        if options.apply:
            advance(store, item["path"])
        with collect_proc_observations() as observations:
            outcome, eligible, attempted = process_item(
                store, item, repositories, adapter, options,
            )
        report["skipped_nondumpable"] += observations["skipped_nondumpable"]
        report["eligible"] += eligible
        report["attempted"] += attempted
        report["retired"] += outcome["status"] == "retired"
        report["results"].append(outcome)
    report["examined"] = len(report["results"])
    # Terminal half-removals are escalated, not retried: report their count so a
    # residue host is visible without reading every result (GH#40569).
    report["needs_resume"] = sum(
        result.get("status") == "needs-resume" for result in report["results"]
    ) + sum(result.get("status") == "needs-resume" for result in staging)
    report["budget_exhausted"] = time.monotonic() >= deadline
    report["incomplete"] = bool(discovery_errors) or report["examined"] < len(items)
    report["archive_failed"] = sum(
        bool(result.get("archive_failure", False)) for result in report["results"]
    )
    report["counts"] = dict(Counter(
        result.get("reason", result["status"]) for result in report["results"]
    ))
    return report
