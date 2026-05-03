#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Regression test for t3458: stale non-empty node_modules restore lock dirs
# must not spin forever in _dlw_node_modules_restore_acquire_lock.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."

# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh"

# shellcheck source=../pulse-dispatch-worker-launch.sh
source "${SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh"

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/t3458-worker-launch-lock-XXXXXX")"

cleanup() {
	rm -rf "$TEST_TMP" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
}

lock_dir="${TEST_TMP}/worktree-node-modules-restore.lock.d"
mkdir -p "$lock_dir" || fail "failed to create lock dir"
printf '999999\n' >"${lock_dir}/pid" || fail "failed to create pid marker"

# Make the directory stale. macOS and GNU touch both support -t.
touch -t 200001010000 "$lock_dir" || fail "failed to age lock dir"

WORKTREE_NODE_MODULES_RESTORE_LOCK_TIMEOUT_S=1 \
	_dlw_node_modules_restore_acquire_lock "$lock_dir" || fail "lock acquire returned failure"

if [[ ! -f "${lock_dir}/pid" ]]; then
	fail "lock acquire did not recreate pid marker"
fi

_dlw_node_modules_restore_release_lock "$lock_dir"

if [[ -d "$lock_dir" ]]; then
	fail "lock release left lock dir behind"
fi

repo_dir="${TEST_TMP}/repo"
wt_dir="${TEST_TMP}/worktree"
mkdir -p "${repo_dir}/node_modules/example" "$wt_dir" || fail "failed to create restore fixture dirs"
printf '{}\n' >"${repo_dir}/package.json" || fail "failed to create repo package.json"
printf '{}\n' >"${wt_dir}/package.json" || fail "failed to create worktree package.json"
printf 'fixture\n' >"${repo_dir}/node_modules/example/file.txt" || fail "failed to create node_modules fixture"

LOGFILE="${TEST_TMP}/pulse.log" \
	AIDEVOPS_WORKSPACE_DIR="$TEST_TMP" \
	WORKTREE_NODE_MODULES_RESTORE_ENABLED=1 \
	WORKTREE_NODE_MODULES_RESTORE_ROOT_ENABLED=0 \
	WORKTREE_NODE_MODULES_RESTORE_LOCK_TIMEOUT_S=1 \
	_dlw_restore_worktree_deps "$wt_dir" "$repo_dir"

if [[ -d "${wt_dir}/node_modules" ]]; then
	fail "root node_modules restore was not skipped"
fi

printf 'PASS: stale non-empty node_modules restore lock is reclaimed\n'
printf 'PASS: root node_modules restore is skipped by default\n'
exit 0
