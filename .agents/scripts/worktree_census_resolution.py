#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Resolve and explain worktree path-census uncertainty (GH#38428).

The opt-in root census may replace unresolved same-UID uncertainty but never
hides a reference. Refusal detail carries status, counts and classes only.
"""

from collections import Counter
from pathlib import Path
import sys


def apply_privileged_census(path, result):
    """Replace unresolved uncertainty with the opt-in root census of the same UID."""
    if result["references"] or not result["uncertain"]:
        return
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "worker-lifecycle"))
    try:
        from worker_lifecycle.protected_proc import ProcessCensusUnavailable, privileged_path_census
    except ImportError:
        result["privileged_census"] = "unavailable"
        return
    finally:
        sys.path.pop(0)
    try:
        report = privileged_path_census(Path(path))
    except ProcessCensusUnavailable as unavailable:
        result["privileged_census"] = unavailable.observation["cause"]
        return
    result["privileged_census"] = "held" if report["references"] else "clear"
    result["privileged_resolved"] = result["uncertain"]
    result["references"] = report["references"]
    result["uncertain"] = report["uncertain"]
    result["uncertain_classes"] = Counter({"privileged": report["uncertain"]} if report["uncertain"] else {})


def describe_census(sample):
    """Path- and name-free refusal detail: status, counts and classes only."""
    if not isinstance(sample, dict):
        return "census unavailable"
    parts = [f"status={sample.get('status')}"]
    for key in ("references", "uncertain", "excluded_nondumpable"):
        classes = sample.get(f"{key}_classes") or {}
        detail = ",".join(f"{kind}={count}" for kind, count in sorted(classes.items()) if count)
        parts.append(f"{key}={sample.get(key)}" + (f"({detail})" if detail else ""))
    if sample.get("privileged_census"):
        parts.append(f"privileged_census={sample['privileged_census']}")
    return " ".join(parts)
