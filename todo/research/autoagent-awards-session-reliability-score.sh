#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

runner=".agents/tools/autoagent/autoagent.md"
safety=".agents/tools/autoagent/autoagent/safety.md"
command_doc=".agents/scripts/commands/autoagent.md"
workflow_doc=".agents/workflows/autoagent.md"
passed=0
total=10

grep -q '## Signal Sources' "$runner" && passed=$((passed + 1)) || true
grep -q '## Hypothesis Types' "$runner" && passed=$((passed + 1)) || true
grep -q '## Safety' "$runner" && passed=$((passed + 1)) || true
grep -q '## Evaluation' "$runner" && passed=$((passed + 1)) || true
grep -q 'AIDEVOPS_WORKTREE_BASE_DIR' "$runner" && passed=$((passed + 1)) || true
# shellcheck disable=SC2016 # Match the literal documented variable expression.
grep -q 'RESULTS_FILE = "$WORKTREE_PATH/' "$runner" && passed=$((passed + 1)) || true
if ! grep -q 'git reset --hard' "$runner" "$safety"; then
	passed=$((passed + 1))
fi
grep -q -- '--body-file' "$runner" && passed=$((passed + 1)) || true
# shellcheck disable=SC2016 # Reject literal shell command substitution in docs.
if ! grep -q -- '--body "$(' "$runner"; then
	passed=$((passed + 1))
fi
cmp -s "$command_doc" "$workflow_doc" && passed=$((passed + 1)) || true

awk -v passed="$passed" -v total="$total" 'BEGIN { printf "%.4f\n", passed / total }'
