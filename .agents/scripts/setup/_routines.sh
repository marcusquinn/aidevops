#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Setup module: routines repo scaffolding
# Sourced by setup.sh — do not execute directly.

# Source the helper if not already loaded
_load_init_routines_helper() {
	local helper_path
	helper_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../init-routines-helper.sh"
	if [[ -f "$helper_path" ]]; then
		# shellcheck disable=SC1090  # dynamic path, exists at runtime
		source "$helper_path"
	else
		print_warning "init-routines-helper.sh not found at: $helper_path"
		return 1
	fi
	return 0
}

# setup_routines — called from setup.sh in both interactive and non-interactive flows
# Non-interactive (update): scaffolds local repo + creates personal GH remote only
# Interactive: creates personal repo + prompts for org repos
# Falls back to local-only if gh CLI is unavailable (idempotent)
setup_routines() {
	print_info "Setting up routines repo..."

	if ! _load_init_routines_helper; then
		print_warning "Skipping routines setup — helper not available"
		setup_track_skipped "Routines repo" "init-routines-helper.sh not found"
		return 0
	fi

	local non_interactive="${NON_INTERACTIVE:-false}"

	# detect_and_create_all handles: personal repo + org repos (interactive only)
	if detect_and_create_all "$non_interactive"; then
		setup_track_configured "Routines repo"
	else
		setup_track_skipped "Routines repo" "gh CLI unavailable or not authenticated"
	fi

	return 0
}
