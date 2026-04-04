#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Update simplification-state.json with tier_minimum results."""
import json
import sys

with open(sys.argv[1]) as f:
    results = json.load(f)

with open(sys.argv[2]) as f:
    state = json.load(f)

updated = 0
for r in results.get("results", []):
    file_path = r.get("file", "")
    tier = r.get("actual_tier", "")
    if file_path and tier and file_path in state.get("files", {}):
        state["files"][file_path]["tier_minimum"] = tier
        updated += 1

with open(sys.argv[2], "w") as f:
    json.dump(state, f, indent=2)
    f.write("\n")

print(f"Updated {updated} entries in simplification-state.json")
