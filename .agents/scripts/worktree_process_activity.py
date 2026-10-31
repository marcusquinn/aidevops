#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Join process observations to Pulse provenance without authorizing deletion."""

import os
import re


def launch_group(launch):
    from worktree_lifetime_reconcile import valid_boot
    if not isinstance(launch, dict):
        raise ValueError("invalid launch")
    if launch.get("admission_cancelled") is True:
        return None
    group, unit, invocation = (launch.get(key) for key in ("cgroup", "unit", "invocation"))
    valid_invocation = isinstance(invocation, str) and re.fullmatch(r"[0-9a-f]{32}", invocation) is not None
    valid_unit = isinstance(unit, str) and re.fullmatch(r"aidevops-worker-[A-Za-z0-9_-]+(?:\.service)?", unit) is not None
    valid_group = (isinstance(group, str) and group.startswith("/")
                   and group == os.path.normpath("/" + group.lstrip("/")))
    if not all((valid_boot(launch.get("boot_id")), valid_invocation, valid_unit, valid_group)):
        raise ValueError("incomplete launch identity")
    return group, unit


def managed_matches(launches, snapshot):
    matched, pending = set(), False
    for launch in launches:
        try:
            identity = launch_group(launch)
            if identity is None or launch["boot_id"] != snapshot["boot_id"]:
                continue
            group, unit = identity
            if group.rsplit("/", 1)[-1] != unit.removesuffix(".service") + ".service":
                raise ValueError("launch group mismatch")
            for pid, process in snapshot["processes"].items():
                observed = process.get("cgroup")
                if observed and (observed == group or observed.startswith(group + "/")):
                    matched.add(pid)
        except ValueError:
            pending = True
    return matched, pending


def activity_reason(record, snapshot):
    if snapshot.get("status") != "available":
        return "process-snapshot-unavailable"
    identity = record.get("identity", {})
    if not isinstance(identity, dict):
        return "invalid-worktree-identity"
    path = identity.get("path")
    if path is not None and not isinstance(path, str):
        return "invalid-worktree-identity"
    return None


def pulse_reason(record, snapshot):
    from worktree_lifetime_reconcile import valid_boot
    if record.get("manager") != "pulse":
        return "pulse-management-unrecorded"
    creator = record.get("created_by") or {}
    if not isinstance(creator, dict) or creator.get("entrypoint") != "pulse":
        return "pulse-provenance-unrecorded"
    launches = record.get("launches") or []
    if not isinstance(launches, list) or not launches or not valid_boot(snapshot.get("boot_id")):
        return "worker-admission-pending"
    return None


def activity(record, snapshot):
    result = {"state": "unknown", "basis": "process-snapshot", "deletion_authorized": False,
              "scope": "registered-managed-launches"}
    reason = activity_reason(record, snapshot)
    if reason:
        return dict(result, reason=reason)
    path = (record.get("identity") or {}).get("path")
    explicit = [pid for pid, process in snapshot["processes"].items()
                if path and process.get("worker_worktree") == os.path.normpath(path)]
    if explicit:
        return dict(result, state="active", matching_processes=sorted(explicit),
                    reason="runtime-worker-directory-match")
    reason = pulse_reason(record, snapshot)
    if reason:
        return dict(result, reason=reason)
    matched, pending = managed_matches(record["launches"], snapshot)
    if matched:
        result.update(state="active", matching_processes=sorted(matched))
    elif any((pending, snapshot["uncertain_pids"], snapshot["membership_unavailable"],
              snapshot.get("runtime_inspection_unavailable"))):
        result["reason"] = "process-or-admission-evidence-unavailable"
    else:
        result.update(state="not-observed", reason="no-matching-worker-process")
    return result


def populate(result, sampled):
    import worktree_lifetime_reconcile as reconciliation
    from worktree_process_snapshot import capture, summary
    if result["status"] != "available" or not sampled:
        return
    snapshot = capture()
    result["process_snapshot"] = summary(snapshot)
    for entry, record in sampled:
        if entry.get("source") != "present":
            continue
        try:
            entry.update(reconciliation.observations(record, entry["source"], snapshot))
            entry["worker_activity"] = activity(record, snapshot)
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
            entry["worker_activity"] = {"state": "unknown", "reason": "invalid-lifecycle-evidence",
                                        "error": type(error).__name__, "deletion_authorized": False}
