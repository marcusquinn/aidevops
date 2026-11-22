#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

# Completion evidence only: this helper never removes worktrees or forges logs.
full_loop_verify_cleanup_evidence() {
	local receipt_path="$1"
	local worktree="$2"
	local cleanup_log="$3"
	local scripts_dir="${BASH_SOURCE[0]%/*}"
	local state_dir="" repo="" branch="" created_at="" result=""
	local identity=""

	[[ -f "$receipt_path" && -n "$worktree" && ! -e "$worktree" && ! -L "$worktree" ]] || return 1
	jq -e --arg worktree "$worktree" '.worktree == $worktree' "$receipt_path" >/dev/null 2>&1 || return 1
	# Retain compatibility with existing audited removals. Registry retirement
	# supplies a separate, identity-bound proof when this legacy log is absent.
	if [[ -f "$cleanup_log" ]] && grep -Fq "worktree-removed: ${worktree} —" "$cleanup_log"; then
		return 0
	fi
	# shellcheck source=./worker-lifecycle-state.sh
	source "${scripts_dir}/worker-lifecycle-state.sh" || return 1
	state_dir=$(worker_lifecycle_state_dir) || return 1
	[[ -n "$state_dir" && -d "$state_dir" ]] || return 1
	identity=$(jq -er '[.repository, .branch, .created_at] |
		select(all(.[]; type == "string" and length > 0)) | @tsv' "$receipt_path") || return 1
	IFS=$'\t' read -r repo branch created_at <<<"$identity" || return 1
	result=$(python3 -E -s -B "${scripts_dir}/../worker-lifecycle/worker-registry.py" \
		--state-dir "$state_dir" verify-retirement --path "$worktree" \
		--repo "$repo" --branch "$branch" --receipt-created-at "$created_at") || return 1
	jq -e '.status == "retirement-verified" and .cleanup_authorized == false' <<<"$result" >/dev/null || return 1
	return 0
}
