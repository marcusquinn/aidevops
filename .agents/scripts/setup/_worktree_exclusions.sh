#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Setup module: worktree exclusions (t2885, GH#20990).
#
# Worktrees are ephemeral working copies — persistent state lives on the git
# remote. Backing them up duplicates work the remote already does, and
# indexing them inflates fseventsd/mds/tracker/baloo load when workers cp
# node_modules. This module:
#
#   1. Runs `worktree-exclusions-helper.sh backfill` to apply exclusions to
#      every existing worktree across registered repos. Idempotent — fast
#      no-op when already applied.
#      macOS: Spotlight (.metadata_never_index) + Time Machine (tmutil).
#      Linux: tracker3 (gsettings + reset) + baloo (baloofilerc + restart).
#   2. macOS only: if Backblaze is detected, posts a one-time advisory
#      pointing to the `setup-backblaze` subcommand (root-owned config).
#
# Sourced by setup.sh — do not execute directly.
#
# Opt out:  AIDEVOPS_WORKTREE_EXCLUSIONS_INSTALL=false
# Skip backfill (apply only new worktrees via the helper hook):
#           AIDEVOPS_WORKTREE_EXCLUSIONS_BACKFILL=false

setup_worktree_exclusions() {
	local label="Worktree exclusions"
	if [[ "${AIDEVOPS_WORKTREE_EXCLUSIONS_INSTALL:-true}" == "false" ]]; then
		print_info "$label disabled via AIDEVOPS_WORKTREE_EXCLUSIONS_INSTALL=false"
		setup_track_skipped "$label" "opted out via env var"
		return 0
	fi

	# Locate the helper. Prefer in-repo (we're inside setup.sh, so the repo
	# copy is canonical here); fall back to deployed copy if running from a
	# bootstrap-light context.
	local helper=""
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 0
	if [[ -x "$script_dir/../worktree-exclusions-helper.sh" ]]; then
		helper="$script_dir/../worktree-exclusions-helper.sh"
	elif [[ -x "${HOME}/.aidevops/agents/scripts/worktree-exclusions-helper.sh" ]]; then
		helper="${HOME}/.aidevops/agents/scripts/worktree-exclusions-helper.sh"
	fi

	if [[ -z "$helper" ]]; then
		print_warning "worktree-exclusions-helper.sh not found — skipping"
		setup_track_skipped "$label" "helper not found"
		return 0
	fi

	# Backfill existing worktrees unless explicitly skipped. Backgrounded:
	# `tmutil addexclusion` takes ~11s per directory on cold start, which
	# would block `aidevops update` (every ~10 min) for several minutes on
	# machines with many worktrees. Once exclusions land, subsequent runs
	# short-circuit at ~0.13s/worktree via the `isexcluded` check.
	if [[ "${AIDEVOPS_WORKTREE_EXCLUSIONS_BACKFILL:-true}" != "false" ]]; then
		local log_dir="${HOME}/.aidevops/logs"
		mkdir -p "$log_dir" 2>/dev/null || true
		local log_file="${log_dir}/worktree-exclusions-backfill.log"
		# Guard the log-file redirection: if $log_dir was not created above
		# (e.g. unwritable parent directory), a bare >>"$log_file" would fail
		# and abort the caller (setup.sh runs with set -Eeuo pipefail +
		# inherit_errexit).  Probe writability; fall back to /dev/null so the
		# nohup launch is always best-effort regardless of disk/permission state.
		local log_dest="$log_file"
		{ true >> "$log_dest"; } 2>/dev/null || log_dest="/dev/null"
		print_info "Applying worktree exclusions in background → $log_dest"
		nohup "$helper" backfill >> "$log_dest" 2>&1 </dev/null &
		disown 2>/dev/null || true
	fi

	# One-time Backblaze advisory (cheap, foreground).
	_setup_worktree_exclusions_backblaze_advisory "$helper"

	setup_track_configured "$label"
	return 0
}

#######################################
# Post a one-time advisory if Backblaze is detected and the user has not yet
# dismissed it. Advisory file is written under ~/.aidevops/advisories/ per the
# existing pattern documented in prompts/build.txt "Security".
#######################################
_setup_worktree_exclusions_backblaze_advisory() {
	local helper="$1"
	# Detect first — cheap, prints to stdout. We only care about exit + lines.
	local detect_out=""
	detect_out=$("$helper" detect 2>&1 || true)
	if ! grep -q 'Backblaze: detected' <<<"$detect_out"; then
		return 0
	fi

	local advisory_dir="${HOME}/.aidevops/advisories"
	local advisory_file="${advisory_dir}/worktree-exclusions-backblaze.advisory"
	mkdir -p "$advisory_dir" 2>/dev/null || return 0

	# Already posted and not dismissed? Touch the timestamp and return.
	if [[ -f "$advisory_file" ]]; then
		return 0
	fi

	# Write the advisory body.
	cat >"$advisory_file" <<'EOF'
[advisory:worktree-exclusions-backblaze]
title: Backblaze worktree exclusion — check Time Machine inheritance setting
severity: info
action: run `worktree-exclusions-helper.sh setup-backblaze` to check whether
        your Backblaze is configured to inherit Time Machine exclusions. If
        enabled, worktrees are already covered. If not, the command will print
        GUI steps to enable it.
dismiss: aidevops security dismiss worktree-exclusions-backblaze
EOF
	print_info "Backblaze detected — wrote advisory to $advisory_file"
	print_info "Run 'worktree-exclusions-helper.sh setup-backblaze' for the manual step"
	return 0
}
