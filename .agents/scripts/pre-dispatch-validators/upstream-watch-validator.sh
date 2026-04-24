#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# upstream-watch-validator.sh — Pre-dispatch validator for upstream-watch issues (t2810)
#
# Checks whether the upstream slug still has updates_pending > 0 in the
# state file. If the user has already acked (updates_pending == 0), the
# premise is falsified and the issue should be closed.
#
# This script is a standalone reference for the validator logic. The
# actual validator is registered inline in pre-dispatch-validator-helper.sh
# as _validator_upstream_watch(). This file documents the expected
# behaviour and can be used for testing.
#
# Exit codes:
#   0  — premise holds (updates_pending > 0, dispatch proceeds)
#   10 — premise falsified (updates_pending == 0, close the issue)
#   20 — validator error (state file missing, etc.)
#
# Environment:
#   AIDEVOPS_UPSTREAM_WATCH_STATE — override state file path (for testing)
#
# Arguments:
#   $1 - upstream_slug (the upstream repo slug or non-GitHub name)

set -euo pipefail

main() {
	local upstream_slug="${1:-}"

	if [[ -z "$upstream_slug" ]]; then
		echo "Usage: upstream-watch-validator.sh <upstream_slug>" >&2
		return 20
	fi

	local state_file="${AIDEVOPS_UPSTREAM_WATCH_STATE:-${HOME}/.aidevops/cache/upstream-watch-state.json}"
	if [[ ! -f "$state_file" ]]; then
		echo "[upstream-watch-validator] state file not found: ${state_file}" >&2
		return 20
	fi

	# Check updates_pending for both GitHub repos and non-GitHub upstreams
	local pending_github pending_nongithub
	pending_github=$(jq -r --arg name "$upstream_slug" '.repos[$name].updates_pending // -1' "$state_file" 2>/dev/null) || pending_github="-1"
	pending_nongithub=$(jq -r --arg name "$upstream_slug" '.non_github[$name].updates_pending // -1' "$state_file" 2>/dev/null) || pending_nongithub="-1"

	local pending="-1"
	if [[ "$pending_github" != "-1" ]]; then
		pending="$pending_github"
	elif [[ "$pending_nongithub" != "-1" ]]; then
		pending="$pending_nongithub"
	fi

	if [[ "$pending" == "0" ]]; then
		echo "[upstream-watch-validator] ${upstream_slug}: updates_pending=0 (already acked) — premise falsified" >&2
		return 10
	fi

	if [[ "$pending" == "-1" ]]; then
		echo "[upstream-watch-validator] ${upstream_slug}: not found in state file — validator error" >&2
		return 20
	fi

	echo "[upstream-watch-validator] ${upstream_slug}: updates_pending=${pending} — premise holds" >&2
	return 0
}

main "$@"
