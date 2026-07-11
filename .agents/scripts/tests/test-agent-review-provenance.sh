#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Guard intentional safety reinforcement against count-driven consolidation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
AGENT_REVIEW="$REPO_ROOT/.agents/tools/build-agent/agent-review.md"

python3 - "$AGENT_REVIEW" <<'PY'
import sys
from pathlib import Path

content = Path(sys.argv[1]).read_text()

# The invariant is intentionally repeated because each copy protects a distinct
# decision point. A review must not classify this fixture by text similarity alone.
fixture = [
    ("before-write", "Never expose credentials in generated files."),
    ("before-push", "Never expose credentials in public changes."),
]
assert len({text.split(" in ")[0] for _, text in fixture}) == 1
assert len({boundary for boundary, _ in fixture}) == 2

required = [
    "counts are heuristics, never standalone removal evidence",
    "recent file history",
    "exact duplication from reinforcement at another decision boundary",
    "runtime-specific variants",
    "similar-but-different hazards",
    "reliable trigger that delivers the lesson at its decision point",
    "obsolete or fully superseded",
    "**Provenance**",
    "**Boundary Analysis**",
    "**Verification**",
]
missing = [phrase for phrase in required if phrase not in content]
assert not missing, f"Agent Review lost provenance safeguards: {missing}"
PY

printf 'PASS Agent Review directive provenance contract\n'
