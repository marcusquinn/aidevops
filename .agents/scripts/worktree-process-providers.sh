#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Read-only process evidence providers. Sourced by audit-worktree-removal-helper.sh.
# Providers report observations, never authorize removal or mutate worktrees.
# Keep the existing stdout/exit-status contract: 0 complete, 2 degraded, 1 unusable.
# Bash 3.2 compatible; platform adapters share the same consumer and safety checks.

_worktree_unprivileged_proc_scan() {
	local mode="$1"
	local status=0
	python3 "$(dirname "${BASH_SOURCE[0]}")/worktree_process_proc.py" "$mode" || status=$?
	case "$status" in
	0 | 2) return "$status" ;;
	esac
	return 1
}

_capture_worktree_proc_cwds() {
	local proc_root="$1"
	local cwd_link=""
	local cwd_target=""
	local captured_count=0
	local current_uid=""
	local visibility_degraded=0
	local proc_dir=""

	current_uid=$(id -u 2>/dev/null) || current_uid=""

	for cwd_link in "$proc_root"/[0-9]*/cwd; do
		[[ -L "$cwd_link" || -e "$cwd_link" ]] || continue
		if ! cwd_target=$(readlink "$cwd_link" 2>/dev/null); then
			# Vanished processes are harmless. Linux commonly denies cwd reads for
			# other users, so skip entries whose ownership proves they are foreign.
			# Same-UID metadata such as comm, cmdline, parent, or process start time
			# cannot prove that an unreadable process is unrelated to this worktree.
			# Preserve degraded visibility rather than adding daemon exemptions.
			[[ -L "$cwd_link" || -e "$cwd_link" ]] || continue
			proc_dir="${cwd_link%/cwd}"
			_worktree_proc_entry_is_zombie "$proc_dir" && continue
			_worktree_proc_entry_is_provably_foreign_uid "$proc_dir" "$current_uid" && continue
			# The optional inspector is governed separately from evidence collection.
			if cwd_target=$(_worktree_privileged_read_cwd "$proc_root" "$proc_dir"); then
				if [[ "$cwd_target" == /* && "$cwd_target" != *$'\n'* ]]; then
					printf '%s\n' "$cwd_target"
					captured_count=$((captured_count + 1))
					continue
				fi
			fi
			[[ -L "$cwd_link" || -e "$cwd_link" ]] || continue
			visibility_degraded=1
			continue
		fi
		if [[ -n "$cwd_target" ]]; then
			printf '%s\n' "$cwd_target"
			captured_count=$((captured_count + 1))
		fi
	done
	if [[ "$visibility_degraded" -eq 1 ]]; then
		return "$_WT_CWD_CAPTURE_DEGRADED_RC"
	fi
	[[ "$captured_count" -gt 0 ]] || return 1
	return 0
}

_capture_worktree_lsof_cwds() {
	local cwd_target=""
	local captured_count=0
	local lsof_line=""
	local lsof_output=""
	local lsof_status=0

	if lsof_output=$(lsof -n -F n -d cwd 2>/dev/null); then
		lsof_status=0
	else
		lsof_status=$?
	fi
	while IFS= read -r lsof_line; do
		case "$lsof_line" in
		n*)
			cwd_target="${lsof_line#n}"
			if [[ -n "$cwd_target" ]]; then
				printf '%s\n' "$cwd_target"
				captured_count=$((captured_count + 1))
			fi
			;;
		esac
	done <<<"$lsof_output"
	[[ "$captured_count" -gt 0 ]] || return 1
	if [[ "$lsof_status" -ne 0 ]]; then
		return "$_WT_CWD_CAPTURE_DEGRADED_RC"
	fi
	return 0
}

# Capture readable targets even when visibility is incomplete. Consumers must
# check the exit status as well as stdout; an empty match is not absence proof.
capture_worktree_process_cwds() {
	if [[ -d /proc ]]; then
		if [[ "$(worktree_process_platform)" == nixos ]]; then
			_worktree_unprivileged_proc_scan paths
			return $?
		fi
		_capture_worktree_proc_cwds /proc
		return $?
	fi

	if command -v lsof >/dev/null 2>&1; then
		# Preserve the macOS adapter: avoid recursive traversal of worktrees.
		_capture_worktree_lsof_cwds
		return $?
	fi
	return 1
}
