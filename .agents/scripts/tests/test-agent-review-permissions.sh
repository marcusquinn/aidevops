#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Guard Agent Review's search instructions against its declared permissions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
AGENT_REVIEW="$REPO_ROOT/.agents/tools/build-agent/agent-review.md"

python3 - "$AGENT_REVIEW" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
content = path.read_text()
parts = content.split("---", 2)
assert len(parts) == 3, "Agent Review must retain YAML frontmatter"
frontmatter, body = parts[1], parts[2]

assert re.search(r"^\s+bash:\s+false\s*$", frontmatter, re.MULTILINE), \
    "Agent Review must keep Bash disabled"
assert re.search(r"^\s+grep:\s+true\s*$", frontmatter, re.MULTILINE), \
    "Agent Review must keep Grep enabled"
assert re.search(r"\*\*Duplicate detection\*\* \(Grep ", body), \
    "Duplicate detection must remain mandatory through Grep"

rg_lines = [line for line in body.splitlines() if re.search(r"`rg\b", line)]
assert rg_lines, "Document the optional rg equivalent for Bash-enabled agents"
assert all("when Bash is available" in line for line in rg_lines), \
    "Every rg instruction must be conditional on Bash availability"
PY

printf 'PASS Agent Review permission/instruction contract\n'
