#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Deterministic check: compare model output against expected behavior."""
import sys
import json

output = sys.argv[1]
expected = json.loads(sys.argv[2])
output_lower = output.lower()

results = {"pass": True, "checks": [], "ambiguous": False}

for kw in expected.get("contains", []):
    found = kw.lower() in output_lower
    results["checks"].append({"type": "contains", "value": kw, "passed": found})
    if not found:
        results["pass"] = False

for kw in expected.get("not_contains", []):
    found = kw.lower() in output_lower
    results["checks"].append({"type": "not_contains", "value": kw, "passed": not found})
    if found:
        results["pass"] = False

for act in expected.get("action", []):
    found = act.lower() in output_lower
    results["checks"].append({"type": "action", "value": act, "passed": found})
    if not found:
        results["ambiguous"] = True

min_len = expected.get("min_length", 0)
max_len = expected.get("max_length", 999999)
actual_len = len(output)

if min_len > 0:
    passed = actual_len >= min_len
    results["checks"].append({"type": "min_length", "value": min_len, "actual": actual_len, "passed": passed})
    if not passed:
        results["pass"] = False

if max_len < 999999:
    passed = actual_len <= max_len
    results["checks"].append({"type": "max_length", "value": max_len, "actual": actual_len, "passed": passed})
    if not passed:
        results["pass"] = False

print(json.dumps(results))
