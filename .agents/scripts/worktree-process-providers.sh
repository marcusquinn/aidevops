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

# One python pass replaces a readlink fork per process (about 400 per scan).
# Readable entries are final; every unreadable one is returned as `F pid` so the
# shell loop below still applies its denial handling. A shell-level readlink
# override is honoured by using the per-process loop instead.
_worktree_proc_cwd_map() {
	local proc_root="$1"
	[[ "$(type -t readlink)" == file ]] || return 1
	command -v python3 >/dev/null 2>&1 || return 1
	python3 "$(dirname "${BASH_SOURCE[0]}")/worktree_process_proc.py" cwdmap "$proc_root" 2>/dev/null
}

# Read one cwd link. Prints the target and returns 0 when captured, 1 when the
# entry is harmless to skip, or 2 when visibility is degraded.
_worktree_read_proc_cwd_link() {
	local proc_root="$1"
	local cwd_link="$2"
	local current_uid="$3"
	local cwd_target=""
	local proc_dir=""

	[[ -L "$cwd_link" || -e "$cwd_link" ]] || return 1
	if cwd_target=$(readlink "$cwd_link" 2>/dev/null); then
		[[ -n "$cwd_target" ]] || return 1
		printf '%s\n' "$cwd_target"
		return 0
	fi
	# Vanished processes are harmless. Linux commonly denies cwd reads for
	# other users, so skip entries whose ownership proves they are foreign.
	# Same-UID metadata such as comm, cmdline, parent, or process start time
	# cannot prove that an unreadable process is unrelated to this worktree.
	# Preserve degraded visibility rather than adding daemon exemptions.
	[[ -L "$cwd_link" || -e "$cwd_link" ]] || return 1
	proc_dir="${cwd_link%/cwd}"
	_worktree_proc_entry_is_zombie "$proc_dir" && return 1
	_worktree_proc_entry_is_provably_foreign_uid "$proc_dir" "$current_uid" && return 1
	# The optional inspector is governed separately from evidence collection.
	if cwd_target=$(_worktree_privileged_read_cwd "$proc_root" "$proc_dir"); then
		if [[ "$cwd_target" == /* && "$cwd_target" != *$'\n'* ]]; then
			printf '%s\n' "$cwd_target"
			return 0
		fi
	fi
	[[ -L "$cwd_link" || -e "$cwd_link" ]] || return 1
	return 2
}

# One platform lookup per pass; cleared on every exit so no verdict outlives it.
_capture_worktree_proc_cwds() {
	local proc_root="$1"
	local rc=0
	_WT_PASS_PLATFORM=$(worktree_process_platform)
	_capture_worktree_proc_cwds_pass "$proc_root" || rc=$?
	_WT_PASS_PLATFORM=""
	return "$rc"
}

_capture_worktree_proc_cwds_pass() {
	local proc_root="$1"
	local cwd_link=""
	local captured_count=0
	local current_uid=""
	local visibility_degraded=0
	local rc=0
	local cwd_map="" map_kind="" map_pid="" map_target=""
	local -a cwd_links=()

	current_uid=$(id -u 2>/dev/null) || current_uid=""

	if cwd_map=$(_worktree_proc_cwd_map "$proc_root"); then
		while IFS=$'\t' read -r map_kind map_pid map_target; do
			if [[ "$map_kind" == R ]]; then
				printf '%s\n' "$map_target"
				captured_count=$((captured_count + 1))
			elif [[ "$map_kind" == F ]]; then
				cwd_links+=("$proc_root/$map_pid/cwd")
			fi
		done <<<"$cwd_map"
	else
		cwd_links=("$proc_root"/[0-9]*/cwd)
	fi

	for cwd_link in ${cwd_links[@]+"${cwd_links[@]}"}; do
		rc=0
		_worktree_read_proc_cwd_link "$proc_root" "$cwd_link" "$current_uid" || rc=$?
		case "$rc" in
		0) captured_count=$((captured_count + 1)) ;;
		2) visibility_degraded=1 ;;
		esac
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
