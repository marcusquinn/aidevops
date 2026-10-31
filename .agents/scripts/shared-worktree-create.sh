#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Native creation and initial ownership/lifetime registration for every producer.

# GH#35602: callers that loaded dispatch-stage-instrument.sh (worktree-helper
# pre-creation) record precreate.* sub-stages; every other producer runs plainly.
if ! declare -F _ds_substage_run >/dev/null 2>&1; then
	_ds_substage_start() { printf '0'; return 0; }
	_ds_substage_record() { return 0; }
	_ds_substage_run() {
		shift
		"$@"
		return $?
	}
fi

# Enroll only the newly created tree. Legacy records are not enrollment input.
# Schema 1 stays observe-only with an explicit gap until coordinated migration.
_worktree_enroll_generation() {
	local path="$1"
	local helper_dir="${BASH_SOURCE[0]%/*}"
	local state_dir="" python=""
	if [[ "${AIDEVOPS_PRIVATE_WORKLOAD:-0}" == 1 || "${AIDEVOPS_LIFECYCLE_DISABLED:-0}" == 1 ]]; then
		return 0
	fi
	# shellcheck source=worker-lifecycle-state.sh
	source "${helper_dir}/worker-lifecycle-state.sh" || return 1
	state_dir=$(worker_lifecycle_state_dir) || return 1
	[[ -n "$state_dir" ]] || return 1
	python=$(type -P python3) || return 1
	path=$(cd -- "$path" && pwd -P) || return 1
	local enrollment_result=""
	if ! enrollment_result=$("$python" -E -s -B "${helper_dir}/../worker-lifecycle/worker-registry.py" \
		--state-dir "$state_dir" enroll --initialize --allow-schema-1-observation --path "$path"); then
		printf 'Generation enrollment refused: %s\n' "$enrollment_result" >&2
		return 1
	fi
	return 0
}

# Arguments: repository, new path, commit-ish, then native Git add options.
# Caller-specific base selection, locks and cleanup remain with the caller.
# A registration failure preserves the tree and returns failure, never success
# with missing metadata or an unsafe compensating forced removal.
# A caller which exclusively reserved an empty directory may bind its exact
# path in AIDEVOPS_WORKTREE_CREATE_RESERVED_PATH. Git still rejects nonempty
# directories; existing paths and symlinks are otherwise refused.
worktree_create_registered() {
	local repo="$1"
	local path="$2"
	local ref="$3"
	shift 3
	local branch=""
	local creation_token=""
	local owner_pid="${AIDEVOPS_WORKTREE_CREATE_OWNER_PID:-}"
	local registry_helper="${BASH_SOURCE[0]%/*}/shared-worktree-registry.sh"
	local stage_t0=""
	if [[ -e "$path" || -L "$path" ]]; then
		[[ -d "$path" && ! -L "$path" && "${AIDEVOPS_WORKTREE_CREATE_RESERVED_PATH:-}" == "$path" ]] || return 1
	fi
	stage_t0=$(_ds_substage_start)
	# shellcheck source=shared-worktree-registry.sh
	source "$registry_helper" || return 1
	creation_token=$(python3 "${registry_helper%.sh}-owner.py" begin-create \
		"$WORKTREE_REGISTRY_DB" "$path") || return 1
	_ds_substage_record precreate.registry_begin_create "$stage_t0"
	_ds_substage_run precreate.git_worktree_add git -C "$repo" worktree add "$@" -- "$path" "$ref" || return 1
	branch=$(git -C "$path" symbolic-ref --quiet --short HEAD) || branch="HEAD"
	# Generic producers inside a managed run belong to its invocation leader,
	# not the user manager or an inherited interactive session. Observation still
	# verifies the live PID, cgroup and invocation before admitting completion.
	if [[ -z "$owner_pid" && -n "${AIDEVOPS_MANAGED_WORKTREE_RUN_UNIT:-}" ]]; then
		owner_pid="${SYSTEMD_EXEC_PID:-$$}"
	fi
	stage_t0=$(_ds_substage_start)
	if ! AIDEVOPS_WORKTREE_CREATING=1 AIDEVOPS_WORKTREE_CREATION_TOKEN="$creation_token" register_worktree "$path" "$branch" \
		--task "${AIDEVOPS_WORKTREE_CREATE_TASK:-}" \
		--owner-pid "$owner_pid" \
		--session "${AIDEVOPS_WORKTREE_CREATE_SESSION:-}"; then
		printf 'Worktree retained: creation metadata registration failed: %s\n' "$path" >&2
		return 1
	fi
	_ds_substage_record precreate.registry_register "$stage_t0"
	if ! _worktree_enroll_generation "$path"; then
		printf 'Worktree retained: generation enrollment failed: %s\n' "$path" >&2
		return 1
	fi
	return 0
}
