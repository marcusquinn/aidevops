#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop State -- lifecycle state module orchestrator
# =============================================================================
# Stable source entrypoint for full-loop-helper.sh. Lifecycle state and release
# persistence live in focused sub-libraries so callers retain the original API.
#
# Sub-libraries:
#   - full-loop-helper-state-lifecycle.sh -- state, phases, gates, and commands
#   - full-loop-helper-state-release.sh   -- release authorization and receipts
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-state.sh"
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_STATE_ORCHESTRATOR_LOADED:-}" ]] && return 0
_FULL_LOOP_STATE_ORCHESTRATOR_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# shellcheck source=./full-loop-helper-state-lifecycle.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via SCRIPT_DIR
source "${SCRIPT_DIR}/full-loop-helper-state-lifecycle.sh"
