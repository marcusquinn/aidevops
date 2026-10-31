#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Shared Pulse/manual launch vocabulary for managed worktree generations.

GH#35295: provenance is allowlisted launcher classification, never actor
identity or deletion authority. Reuse requires the exact recorded task, and a
sealed generation is never reopened. Absent evidence stays unknown/unrecorded.
"""

import os
import re
import time


# Values outside these allowlists are recorded as unknown, never as a human or
# scheduled trigger.
ENTRYPOINTS = ("pulse", "dispatch-single-issue")
TRIGGERS = ("scheduled", "manual")
TRIGGER_EVIDENCE = ("pulse-cycle", "interactive-terminal")
BACKEND = "systemd-user-service"
CLASSIFICATION = ("entrypoint", "trigger", "trigger_evidence")


class ReuseRefusal(ValueError):
    """Definitive reuse refusal with a stable CLI exit code."""

    exit_code = 1


class TaskMismatch(ReuseRefusal):
    """Enrolled generation belongs to a different repository task."""

    exit_code = 4


class SealedGeneration(ReuseRefusal):
    """Closed lifetime: never reopened, so it cannot be a reuse candidate."""

    exit_code = 5


def allowed(name, values, fallback="unknown"):
    value = os.environ.get(name, "")
    return value if value in values else fallback


def provenance():
    """Append-only launcher provenance; no actor, credential, prompt or host path."""
    evidence = allowed("AIDEVOPS_LAUNCH_TRIGGER_EVIDENCE", TRIGGER_EVIDENCE, "none")
    # A trigger without its evidence class is not attribution.
    trigger = "unknown" if evidence == "none" else allowed("AIDEVOPS_LAUNCH_TRIGGER", TRIGGERS)
    return {"entrypoint": allowed("AIDEVOPS_LAUNCH_ENTRYPOINT", ENTRYPOINTS), "trigger": trigger,
            "trigger_evidence": evidence}


def task_identity():
    issue = os.environ.get("AIDEVOPS_LAUNCH_TASK", "")
    if re.fullmatch(r"[1-9][0-9]{0,9}", issue) is None:
        return None
    repo = os.environ.get("AIDEVOPS_LAUNCH_REPO", "")
    valid_repo = re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo) is not None
    return {"issue": issue, "repo": repo if valid_repo else ""}


def check_generation(record):
    # The launcher selected one generation; a replacement must not inherit it.
    expected = os.environ.get("AIDEVOPS_EXPECTED_GENERATION", "")
    if expected and expected != record.get("generation"):
        raise ValueError("worktree generation replaced since selection")


def attempt(launches, unit, boot):
    """New attempt entry; numbering and retry links describe sequence, not trigger."""
    previous = launches[-1]["unit"] if launches else None
    return {"unit": unit, "boot_id": boot, "invocation": None, "attempt": len(launches) + 1,
            "backend": BACKEND, "retry_of": previous, "reserved_at": time.time(),
            "provenance": provenance()}


def match(record, extra):
    """Read-only reuse selection: `<generation> exact|unrecorded` or a refusal."""
    if len(extra) not in (1, 2):
        raise ValueError("issue and optional repository required")
    if record["state"] == "sealed":
        raise SealedGeneration("sealed generation awaits archive or cleanup")
    if record["state"] not in ("created", "running"):
        raise ValueError("worktree cannot be reused")
    task = record.get("task")
    if not task:
        return f"{record['generation']} unrecorded"  # Pre-contract record: branch-matched only.
    repo, recorded = (extra[1] if len(extra) == 2 else ""), task.get("repo") or ""
    if task.get("issue") != extra[0] or (repo and recorded and recorded != repo):
        raise TaskMismatch("enrolled generation belongs to a different task")
    return f"{record['generation']} exact"


def classified(value):
    value = value if isinstance(value, dict) else {}
    return {key: value[key] if isinstance(value.get(key), str) else "unrecorded" for key in CLASSIFICATION}


def summary(record):
    """Status view of recorded provenance; absent fields stay unrecorded."""
    launches = [launch for launch in record.get("launches") or [] if isinstance(launch, dict)]
    task = record.get("task") if isinstance(record.get("task"), dict) else {}
    last = classified(launches[-1].get("provenance")) if launches else None
    return {"generation": record.get("generation"), "created_by": classified(record.get("created_by")),
            "task_issue": task.get("issue"), "attempts": len(launches), "last_attempt_by": last,
            "evidence_class": evidence_class(record)}


def evidence_class(record):
    """Describe recorded contracts, not liveness or permission to delete.

    In particular, historical `running` owner observations are not managed
    executions. Keep their original state and receipts untouched; only the
    existing cleanup-ready/proof operations can validate completion.
    """
    launches = record.get("launches")
    if not isinstance(launches, list) or not launches:
        return "unrecorded"
    if not all(isinstance(launch, dict) for launch in launches):
        return "incomplete"
    completion_contract = True
    if record.get("manager") == "owner-cgroup":
        if all(launch.get("kind") == "owner-cgroup-v1" and
               not any(launch.get(key) for key in ("unit", "invocation", "completion_evidence", "quiescence"))
               for launch in launches):
            return "observation-only"
        completion_contract = all(launch.get("completion_evidence") == "systemd-cgroup-v1" for launch in launches)
    complete = completion_contract and all(launch.get("unit") and launch.get("boot_id") and
               (launch.get("invocation") or launch.get("admission_cancelled") is True) for launch in launches)
    return "managed-contract-recorded" if complete else "incomplete"
