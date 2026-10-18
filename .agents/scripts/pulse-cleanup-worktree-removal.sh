#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Cleanup Worktree Removal Library
# =============================================================================
# Stable entry point for pulse-cleanup.sh. Dependencies and configuration are
# provided by the pulse-wrapper orchestrator; sourcing this file only loads APIs.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_CLEANUP_WORKTREE_REMOVAL_LOADED:-}" ]] && return 0
_PULSE_CLEANUP_WORKTREE_REMOVAL_LOADED=1

# Keep the cleanup-specific directory: callers may use SCRIPT_DIR themselves.
if [[ -z "${_PULSE_CLEANUP_SCRIPT_DIR:-}" ]]; then
	_pulse_cleanup_worktree_removal_path="${BASH_SOURCE[0]%/*}"
	[[ "$_pulse_cleanup_worktree_removal_path" == "${BASH_SOURCE[0]}" ]] && _pulse_cleanup_worktree_removal_path="."
	_PULSE_CLEANUP_SCRIPT_DIR="$(cd "$_pulse_cleanup_worktree_removal_path" && pwd)"
	unset _pulse_cleanup_worktree_removal_path
fi

# Explicitly clearing the public guard has historically reloaded every function
# and reset library state (including fixture overrides). Keep that contract;
# ordinary repeated sourcing still returns at the public guard above.
unset _PULSE_CLEANUP_WORKTREE_REMOVAL_LIFECYCLE_LOADED \
	_PULSE_CLEANUP_WORKTREE_REMOVAL_CENTRAL_LOADED \
	_PULSE_CLEANUP_WORKTREE_REMOVAL_PROFILE_LOADED

# Lifecycle operations initialize the shared removal/archive constants first.
# shellcheck source=./pulse-cleanup-worktree-removal-lifecycle.sh
# shellcheck disable=SC1091 # Sibling library resolved at runtime
source "${_PULSE_CLEANUP_SCRIPT_DIR}/pulse-cleanup-worktree-removal-lifecycle.sh"

# shellcheck source=./pulse-cleanup-worktree-removal-central.sh
# shellcheck disable=SC1091 # Sibling library resolved at runtime
source "${_PULSE_CLEANUP_SCRIPT_DIR}/pulse-cleanup-worktree-removal-central.sh"

# shellcheck source=./pulse-cleanup-worktree-removal-profile.sh
# shellcheck disable=SC1091 # Sibling library resolved at runtime
source "${_PULSE_CLEANUP_SCRIPT_DIR}/pulse-cleanup-worktree-removal-profile.sh"
