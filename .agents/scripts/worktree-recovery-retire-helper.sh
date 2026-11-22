#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Guarded manual and policy-bound automatic retirement entry points.

# Registry ownership for every path in one read-only connection (#38918).
# Prints one validated state per path, in order; any helper failure or
# malformed answer makes every path unavailable rather than clear.
_worktree_recovery_retirement_registry_states() {
	local output="" state="" count=0
	local -a states=()

	if command -v python3 >/dev/null 2>&1 &&
		output=$(python3 "$WORKTREE_RECOVERY_LIFECYCLE_DIR/worktree_recovery_registry.py" \
			"${WORKTREE_REGISTRY_DB:-}" "$@" 2>/dev/null); then
		while IFS= read -r state; do
			case "$state" in
			clear | active | busy) ;;
			*) state="$WORKTREE_RECOVERY_UNAVAILABLE" ;;
			esac
			states[count]="$state"
			count=$((count + 1))
		done <<<"$output"
	fi
	if [[ "$count" -ne $# ]]; then
		count=0
		while [[ "$count" -lt $# ]]; do
			states[count]="$WORKTREE_RECOVERY_UNAVAILABLE"
			count=$((count + 1))
		done
	fi
	[[ "$count" -eq 0 ]] || printf '%s\n' "${states[@]}"
	return 0
}

# Validate one identity, or an identity and its claimed relocation, with one
# claim check, one registry spawn, one worktree listing and one process
# snapshot. Verdicts are reported in the same order as the per-identity
# sequence: claim, then each identity's paths (registry, worktree reference)
# followed by that identity's process state.
_worktree_recovery_retirement_evidence() {
	local identity="$1"
	local operation="${2:-compact-then-retire}"
	local claimed="${3:-}"
	local git_identity="" candidate="" state="" pass="" common_path="" branch=""
	local listing="" listing_ok=true snapshot="" snapshot_rc=0 snapshot_taken=false
	local index=0 path_count=0
	local -a passes=() paths=() registry_states=()
	# The copied .git file deliberately remains unchanged after claiming. Query
	# the original common administration, not that now-relocated pointer. A
	# claimed identity differs only in bucket/archive paths, so its claim
	# evidence is identical.
	git_identity=$(printf '%s\n' "$identity" | jq -ce '.archive_path = .common_path') || return 1
	state=$(_worktree_recovery_plan_claim_state "$git_identity") || return 1
	case "$state" in
	clear | not-applicable) ;;
	*) printf 'claim-%s\n' "$state"; return 1 ;;
	esac
	passes[0]="$identity"
	if [[ -n "$claimed" ]]; then
		printf '%s\n' "$identity" "$claimed" | jq -se \
			'.[0].common_path == .[1].common_path and .[0].branch == .[1].branch and
			.[0].source_path == .[1].source_path' >/dev/null || return 1
		[[ "$claimed" == "$identity" ]] || passes[1]="$claimed"
	fi
	for pass in "${passes[@]}"; do
		for candidate in source_path bucket_path archive_path; do
			paths[path_count]=$(printf '%s\n' "$pass" | jq -r --arg key "$candidate" '.[$key]') || return 1
			path_count=$((path_count + 1))
		done
	done
	common_path=$(printf '%s\n' "$identity" | jq -r '.common_path') || return 1
	branch=$(printf '%s\n' "$identity" | jq -r '.branch') || return 1
	index=0
	while IFS= read -r state; do
		registry_states[index]="$state"
		index=$((index + 1))
	done < <(_worktree_recovery_retirement_registry_states "${paths[@]}")
	[[ "$index" -eq "$path_count" ]] || { printf 'registry-%s\n' "$WORKTREE_RECOVERY_UNAVAILABLE"; return 1; }
	listing=$(GIT_OPTIONAL_LOCKS=0 git -C "$common_path" worktree list --porcelain 2>/dev/null) ||
		listing_ok=false
	index=0
	for pass in "${passes[@]}"; do
		for candidate in 0 1 2; do
			state="${registry_states[index]}"
			[[ "$state" == "$WORKTREE_RECOVERY_PLAN_STATE_CLEAR" ]] || { printf 'registry-%s\n' "$state"; return 1; }
			if [[ "$listing_ok" == true ]]; then
				state=$(_worktree_recovery_plan_worktree_listing_state \
					"$listing" "${paths[index]}" "$branch") || return 1
			else
				state="$WORKTREE_RECOVERY_UNAVAILABLE"
			fi
			[[ "$state" == "$WORKTREE_RECOVERY_PLAN_STATE_CLEAR" ]] || { printf 'worktree-reference-%s\n' "$state"; return 1; }
			index=$((index + 1))
		done
		if [[ "$snapshot_taken" != true ]]; then
			if snapshot=$(capture_worktree_process_cwds); then
				snapshot_rc=0
			else
				snapshot_rc=$?
			fi
			snapshot_taken=true
		fi
		state=$(_worktree_recovery_plan_process_state \
			"$pass" "$operation" "$snapshot" "$snapshot_rc") || return 1
		[[ "$state" == "$WORKTREE_RECOVERY_PLAN_STATE_CLEAR" ]] || { printf 'process-%s\n' "$state"; return 1; }
	done
	return 0
}

_worktree_recovery_retirement_guard() {
	local target="$1"
	local operation="${2:-compact-then-retire}"
	local identity="" claimed=""
	local -x GIT_OPTIONAL_LOCKS=0
	local -x GIT_NO_LAZY_FETCH=1
	unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
	identity=$(jq -ce '.') || return 1
	if [[ "$operation" == "archive-migration" ]]; then
		printf '%s\n' "$identity" | python3 "$WORKTREE_RECOVERY_LIFECYCLE_DIR/worktree_recovery_legacy_policy.py" archive-migration || return 1
	fi
	claimed=$(printf '%s\n' "$identity" | jq -ce --arg target "$target" \
		'.bucket_path = $target | .archive_path = ($target + "/" + (.archive_path | split("/") | last))') || return 1
	_worktree_recovery_retirement_evidence "$identity" "$operation" "$claimed" || return 1
	return 0
}

_worktree_recovery_retire_cli() {
	local action="$1"
	local option="${2:-}" bucket="${3:-}" root="" root_real="" status=0
	[[ "$option" == "--bucket" && "$bucket" == /* ]] || return 1
	root=$(_worktree_recovery_store_root) || return 1
	[[ -d "$root" && ! -L "$root" && ! -L "$bucket" ]] || return 1
	root_real=$(cd "$root" && pwd -P) || return 1
	[[ "${bucket%/*}" == "$root_real" && "${bucket##*/}" == aidevops-worktree-cleanup-* ]] || return 1
	_worktree_recovery_acquire_producer_lock "$root_real" || {
		_worktree_recovery_compact_lock_failure "$root_real"
		return 1
	}
	python3 "$WORKTREE_RECOVERY_LIFECYCLE_DIR/worktree_recovery_retire.py" "$@" || status=$?
	_worktree_recovery_release_producer_lock || status=1
	return "$status"
}
