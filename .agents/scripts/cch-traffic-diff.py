#!/usr/bin/env python3
"""Compare two CCH traffic capture baselines and report protocol changes.

Used by cch-traffic-monitor.sh diff command.
Usage: cch-traffic-diff.py <baseline.json> <current.json>
Exit 0 = no changes, Exit 1 = changes detected.
"""
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import json
import sys


def load_first_request(path):
    """Load the first request from a capture file."""
    with open(path) as f:
        data = json.load(f)
    return data["requests"][0] if data["requests"] else {}


def compare_headers(base_req, curr_req):
    """Compare header sets between baseline and current."""
    changes = []
    base_headers = set(base_req.get("headers", {}).keys())
    curr_headers = set(curr_req.get("headers", {}).keys())

    new_headers = curr_headers - base_headers
    removed_headers = base_headers - curr_headers
    if new_headers:
        changes.append(f"NEW HEADERS: {sorted(new_headers)}")
    if removed_headers:
        changes.append(f"REMOVED HEADERS: {sorted(removed_headers)}")

    for h in base_headers & curr_headers:
        if h.lower() == "authorization":
            continue  # always redacted
        bv = base_req["headers"].get(h, "")
        cv = curr_req["headers"].get(h, "")
        if bv != cv:
            changes.append(f"CHANGED HEADER {h}: {bv!r} -> {cv!r}")

    return changes


def compare_billing(base_req, curr_req):
    """Compare billing headers."""
    bb = base_req.get("billing_header", "")
    cb = curr_req.get("billing_header", "")
    if bb == cb:
        return []
    return [
        "BILLING HEADER CHANGED:",
        f"  OLD: {bb}",
        f"  NEW: {cb}",
    ]


def compare_body(base_req, curr_req):
    """Compare body structure and betas."""
    changes = []
    base_body = base_req.get("body", {}) or {}
    curr_body = curr_req.get("body", {}) or {}

    base_keys = set(base_body.get("body_keys", []))
    curr_keys = set(curr_body.get("body_keys", []))
    new_keys = curr_keys - base_keys
    removed_keys = base_keys - curr_keys
    if new_keys:
        changes.append(f"NEW BODY KEYS: {sorted(new_keys)}")
    if removed_keys:
        changes.append(f"REMOVED BODY KEYS: {sorted(removed_keys)}")

    base_betas = set(base_body.get("betas") or [])
    curr_betas = set(curr_body.get("betas") or [])
    new_betas = curr_betas - base_betas
    removed_betas = base_betas - curr_betas
    if new_betas:
        changes.append(f"NEW BETAS: {sorted(new_betas)}")
    if removed_betas:
        changes.append(f"REMOVED BETAS: {sorted(removed_betas)}")

    return changes


def compare_system_blocks(base_req, curr_req):
    """Compare system block counts."""
    base_sys = base_req.get("system_blocks", []) or []
    curr_sys = curr_req.get("system_blocks", []) or []
    if len(base_sys) != len(curr_sys):
        return [f"SYSTEM BLOCK COUNT: {len(base_sys)} -> {len(curr_sys)}"]
    return []


def main():
    if len(sys.argv) < 3:
        print("Usage: cch-traffic-diff.py <baseline.json> <current.json>", file=sys.stderr)
        sys.exit(2)

    base_req = load_first_request(sys.argv[1])
    curr_req = load_first_request(sys.argv[2])

    changes = []
    changes.extend(compare_headers(base_req, curr_req))
    changes.extend(compare_billing(base_req, curr_req))
    changes.extend(compare_body(base_req, curr_req))
    changes.extend(compare_system_blocks(base_req, curr_req))

    if changes:
        print("## Protocol Changes Detected\n")
        for c in changes:
            print(f"- {c}")
        sys.exit(1)

    print("No protocol changes detected.")
    sys.exit(0)


if __name__ == "__main__":
    main()
