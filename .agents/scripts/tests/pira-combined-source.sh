#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Print the path of a concatenated copy of pulse-issue-reconcile-actions.sh and
# its split sub-libraries (GH#37574), for static source-text assertions that
# predate the split. Contents only; never source the output.
# =============================================================================

set -euo pipefail

_pira_dir="${BASH_SOURCE[0]%/*}/.."
_pira_dir="$(cd "$_pira_dir" && pwd)"
_pira_out="${TMPDIR:-/tmp}/aidevops-pira-combined.sh"
_pira_tmp="${_pira_out}.$$"

cat "${_pira_dir}/pulse-issue-reconcile-actions.sh" \
	"${_pira_dir}/pulse-issue-reconcile-actions-parent.sh" \
	"${_pira_dir}/pulse-issue-reconcile-actions-repair.sh" >"$_pira_tmp"
mv -f "$_pira_tmp" "$_pira_out"
printf '%s\n' "$_pira_out"
