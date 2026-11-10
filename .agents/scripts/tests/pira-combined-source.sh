#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Print the path of a concatenated copy of pulse-issue-reconcile-actions.sh and
# its split sub-libraries (GH#37574), for static source-text assertions that
# predate the split. Contents only; never source the output.
# With --module, print the real module path instead (for tests that execute
# it, so the sibling sub-library source wiring is exercised).
# =============================================================================

set -euo pipefail

_pira_dir="${BASH_SOURCE[0]%/*}/.."
_pira_dir="$(cd "$_pira_dir" && pwd)"

if [[ "${1:-}" == "--module" ]]; then
	printf '%s\n' "${_pira_dir}/pulse-issue-reconcile-actions.sh"
	exit 0
fi

_pira_out="$(mktemp "${TMPDIR:-/tmp}/aidevops-pira-combined.XXXXXX")"

cat "${_pira_dir}/pulse-issue-reconcile-actions.sh" \
	"${_pira_dir}/pulse-issue-reconcile-actions-parent.sh" \
	"${_pira_dir}/pulse-issue-reconcile-actions-repair.sh" >"$_pira_out"
printf '%s\n' "$_pira_out"
