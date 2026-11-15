#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Restore gitignored node_modules into pre-created worker worktrees.
# Sourced by pulse-dispatch-worker-launch.sh; uses LOGFILE and _file_mtime_epoch from the caller.
# Function bodies remain unchanged from the launch orchestrator (GH#28839).

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_DISPATCH_WORKER_DEPS_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_WORKER_DEPS_LOADED=1

###############################################################################
# Restore gitignored dependencies (node_modules) in a worktree.
#
# Git worktrees only contain tracked files. Directories like node_modules/
# are gitignored, so they never appear in worktrees — even when the
# canonical repo has them installed. If a project tool (e.g. .opencode/
# tool/session-rename.ts) imports from node_modules, the runtime crashes
# on startup: "Cannot find module '@opencode-ai/plugin'".
#
# This caused 100% worker failure rate: 15 of 27 open issues stuck in
# dispatch-fail loops, 9 falsely escalated to tier:thinking. Workers
# exited 0 with zero model activity because the tool-loading error
# prevented the session from starting.
#
# Fix: after creating or resetting a worktree, copy scoped node_modules from
# the canonical repo for package directories that have package.json tracked
# in git. Root node_modules can be multi-GB and block the pulse before worker
# spawn, so headless dispatch skips it by default unless explicitly enabled
# with WORKTREE_NODE_MODULES_RESTORE_ROOT_ENABLED=1.
#
# Arguments: worktree_path, repo_path
###############################################################################
_dlw_node_modules_restore_lock_dir() {
	local workspace_dir="${AIDEVOPS_WORKSPACE_DIR:-${HOME}/.aidevops/.agent-workspace}"
	printf '%s\n' "${workspace_dir}/tmp/worktree-node-modules-restore.lock.d"
	return 0
}

_dlw_node_modules_restore_acquire_lock() {
	local lock_dir="$1"
	local timeout_s="${WORKTREE_NODE_MODULES_RESTORE_LOCK_TIMEOUT_S:-2}"
	local elapsed=0
	[[ "$timeout_s" =~ ^[0-9]+$ ]] || timeout_s=2
	mkdir -p "${lock_dir%/*}" 2>/dev/null || return 1
	while ! mkdir "$lock_dir" 2>/dev/null; do
		if [[ -d "$lock_dir" ]]; then
			local lock_mtime="" now_epoch="" age_s=""
			lock_mtime=$(_file_mtime_epoch "$lock_dir")
			now_epoch=$(date +%s)
			age_s=$((now_epoch - lock_mtime))
			if ((age_s > 60)); then
				# Stale lock dirs contain a pid marker. rmdir fails on that
				# non-empty directory; retrying immediately without changing
				# state spins pulse-wrapper children before worker_spawn.
				rm -rf "$lock_dir" 2>/dev/null || true
				continue
			fi
		fi
		if ((elapsed >= timeout_s * 10)); then
			return 1
		fi
		sleep 0.1
		elapsed=$((elapsed + 1))
	done
	printf '%s\n' "$$" >"${lock_dir}/pid" 2>/dev/null || true
	return 0
}

_dlw_node_modules_restore_release_lock() {
	local lock_dir="$1"
	rm -f "${lock_dir}/pid" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || true
	return 0
}

_dlw_remove_generated_root_node_tool_link() {
	local worktree_path="$1"
	local repo_path="$2"
	local _src_bin="${repo_path}/node_modules/.bin"
	local _dst_bin="${worktree_path}/node_modules/.bin"
	local _link_target=""
	[[ -L "$_dst_bin" ]] || return 0
	_link_target=$(readlink "$_dst_bin" 2>/dev/null) || return 0
	[[ "$_link_target" == "$_src_bin" ]] || return 0
	rm -f "$_dst_bin" 2>/dev/null || return 0
	echo "[dispatch_with_dedup] Removed generated cross-boundary node_modules/.bin link from ${worktree_path}" >>"$LOGFILE"
	return 0
}

_dlw_restore_worktree_deps() {
	local worktree_path="$1"
	local repo_path="$2"

	[[ -z "$worktree_path" || -z "$repo_path" ]] && return 0
	[[ ! -d "$worktree_path" || ! -d "$repo_path" ]] && return 0
	[[ "${WORKTREE_NODE_MODULES_RESTORE_ENABLED:-1}" == "1" ]] || return 0

	local _lock_dir=""
	_lock_dir=$(_dlw_node_modules_restore_lock_dir)
	if ! _dlw_node_modules_restore_acquire_lock "$_lock_dir"; then
		echo "[dispatch_with_dedup] Skipping node_modules restore for ${worktree_path}: another restore is active" >>"$LOGFILE"
		return 0
	fi

	# Find directories in the worktree that have a package.json but are
	# missing node_modules. Only check top-level and one level deep —
	# deeper nesting is unlikely and find is expensive.
	local _pkg_dir=""
	local _attempted=0
	local _max_dirs="${WORKTREE_NODE_MODULES_RESTORE_MAX_DIRS:-2}"
	local _restore_root="${WORKTREE_NODE_MODULES_RESTORE_ROOT_ENABLED:-auto}"
	# Share the controller's bounded, identity-checked copy implementation.
	if ! declare -F _provision_worktree_node_modules >/dev/null 2>&1; then
		local SCRIPT_DIR=""
		SCRIPT_DIR=$(dirname "${BASH_SOURCE[0]}")
		# shellcheck source=worktree-helper-add.sh
		if ! source "${SCRIPT_DIR}/worktree-helper-add.sh"; then
			_dlw_node_modules_restore_release_lock "$_lock_dir"
			return 0
		fi
	fi
	[[ "$_max_dirs" =~ ^[0-9]+$ ]] || _max_dirs=2
	while IFS= read -r _pkg_dir; do
		if ((_attempted >= _max_dirs)); then
			break
		fi
		local _dir=""
		_dir=$(dirname "$_pkg_dir") || continue
		local _rel_dir=""
		_rel_dir="${_dir#"$worktree_path"}" || continue
		# _rel_dir is now e.g. "/.opencode" or "" (for root package.json)
		if [[ -z "$_rel_dir" && "$_restore_root" != "1" && "$_restore_root" != "auto" ]]; then
			_dlw_remove_generated_root_node_tool_link "$worktree_path" "$repo_path"
			echo "[dispatch_with_dedup] Skipping root node_modules restore for ${worktree_path} (set WORKTREE_NODE_MODULES_RESTORE_ROOT_ENABLED=1 to enable)" >>"$LOGFILE"
			continue
		fi
		local _src_nm="${repo_path}${_rel_dir}/node_modules"
		local _dst_nm="${worktree_path}${_rel_dir}/node_modules"
		# The validator accepts only a package-local package-lock.json or
		# pnpm-lock.yaml (not bun.lock, nor a workspace member whose lock is at
		# the root); skip guaranteed rejections before they spend the budget.
		if [[ -d "$_src_nm" && ! -d "$_dst_nm" ]] &&
			[[ -f "${_dir}/package-lock.json" || -f "${_dir}/pnpm-lock.yaml" ]]; then
			# Rejections also spend preparation time and must not exhaust the
			# prelaunch lease by retrying every package in a large worktree.
			_attempted=$((_attempted + 1))
			if ! _provision_worktree_node_modules "$worktree_path" "$repo_path" "${_rel_dir#/}" >>"$LOGFILE" 2>&1; then
				echo "[dispatch_with_dedup] Dependency provisioning unavailable; no external permission granted" >>"$LOGFILE"
			fi
		fi
	done < <(find "$worktree_path" -maxdepth 3 -name "package.json" -not -path "*/node_modules/*" 2>/dev/null)
	_dlw_node_modules_restore_release_lock "$_lock_dir"

	return 0
}
