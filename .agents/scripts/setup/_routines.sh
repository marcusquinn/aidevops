#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Setup module: routines repo scaffolding
# Sourced by setup.sh — do not execute directly.

# Source the helper if not already loaded.
#
# GH#18702: Wrap the source call with explicit error capture so a helper-level
# error (e.g., a new readonly variable collision) cannot propagate up through
# `set -Eeuo pipefail` and kill the entire setup.sh run. Before this fix, a
# single `GREEN: readonly variable` in init-routines-helper.sh had been
# blocking every auto-update deploy since 2026-04-09 (14+ failures logged),
# which in turn left workers running stale deployed scripts and caused the
# 18693/18702 stale-recovery cascade.
_load_init_routines_helper() {
	local helper_path
	helper_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../init-routines-helper.sh"
	if [[ ! -f "$helper_path" ]]; then
		print_warning "init-routines-helper.sh not found at: $helper_path"
		return 1
	fi

	# Isolate source errors: temporarily disable -e so a sourcing failure
	# returns here instead of exiting setup.sh. `set -e` is re-enabled after.
	local prev_errexit
	prev_errexit=$(set +o | grep errexit)
	set +e
	# shellcheck disable=SC1090  # dynamic path, exists at runtime
	source "$helper_path"
	local rc=$?
	eval "$prev_errexit"

	if [[ $rc -ne 0 ]]; then
		print_warning "init-routines-helper.sh failed to source (exit=$rc) — routines setup will be skipped"
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
