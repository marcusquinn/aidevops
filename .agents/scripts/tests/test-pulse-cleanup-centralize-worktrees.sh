#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULSE_CLEANUP="${SCRIPT_DIR}/../pulse-cleanup.sh"
GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"

TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

# Keep isolated fixture mutations on native Git. The repository-level canonical
# guard is under separate test and must not classify temporary main worktrees.
git() {
	"$GIT_BIN" "$@"
	return $?
}

print_result() {
	local name="$1"
	local rc="$2"
	local extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s %s\n' "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

teardown() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

setup_subject() {
	TEST_ROOT=$(mktemp -d)
	TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P) || return 1
	trap teardown EXIT
	export HOME="${TEST_ROOT}/home"
	export AIDEVOPS_REPOS_JSON="${HOME}/.config/aidevops/repos.json"
	export AIDEVOPS_WORKTREE_BASE_DIR="${TEST_ROOT}/Git/_worktrees"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export AIDEVOPS_CLEANUP_LOG="${TEST_ROOT}/cleanup.log"
	mkdir -p "${HOME}/.config/aidevops" "${HOME}/.aidevops/logs" "${TEST_ROOT}/Git"

	is_registered_canonical() { return 1; }
	unregister_worktree() { local wt_path="$1"; : "$wt_path"; return 0; }
	gh() { return 1; }
	gh_pr_list() { return 0; }
	recover_failed_launch_state() { return 0; }
	gh_issue_comment() { return 0; }

	unset _PULSE_CLEANUP_LOADED 2>/dev/null || true
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../portable-stat.sh
	source "${SCRIPT_DIR}/../portable-stat.sh"
	# shellcheck source=../pulse-cleanup.sh
	source "$PULSE_CLEANUP"
	return 0
}

test_registered_parent_worktree_moves_to_central_base() {
	setup_subject || return 1
	local repo_dir="${TEST_ROOT}/Git/example"
	local old_wt="${TEST_ROOT}/Git/example-feature-old-location"
	local new_wt="${TEST_ROOT}/Git/_worktrees/example-feature-old-location"
	local branch="feature/old-location"
	local rc=0 moved=""

	mkdir -p "$repo_dir" || rc=1
	git -C "$repo_dir" init -q -b main || rc=1
	git -C "$repo_dir" config user.email test@example.invalid || rc=1
	git -C "$repo_dir" config user.name 'Aidevops Test' || rc=1
	printf 'base\n' >"${repo_dir}/README.md" || rc=1
	git -C "$repo_dir" add README.md || rc=1
	git -C "$repo_dir" commit -q -m init || rc=1
	git -C "$repo_dir" worktree add -q -b "$branch" "$old_wt" main || rc=1
	printf '{"initialized_repos":[{"slug":"example/repo","path":"%s","local_only":false}],"worktree_base_dir":"%s"}\n' \
		"$repo_dir" "$AIDEVOPS_WORKTREE_BASE_DIR" >"$AIDEVOPS_REPOS_JSON" || rc=1

	moved=$(_pc_relocate_registered_worktrees "$AIDEVOPS_REPOS_JSON") || rc=1

	if grep -q 'cwd-visibility-degraded.*mode=recoverable-required' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null; then
		# A shared runner can hide same-UID /proc cwd entries. The removal
		# guard must fail closed rather than relocating without visibility.
		[[ "$moved" == "0" && -d "$old_wt" && ! -d "$new_wt" ]] || rc=1
	else
		[[ "$moved" == "1" && ! -d "$old_wt" && -d "$new_wt" ]] || rc=1
		git -C "$repo_dir" worktree list --porcelain | grep -q "worktree $new_wt" 2>/dev/null || rc=1
		grep -q 'worktree-removed.*centralized-worktree.*mode=moved' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	fi
	print_result "registered parent worktree moves to central base" "$rc" \
		"moved=$moved log=$(cat "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null)"
	return 0
}

test_current_worktree_is_not_moved() {
	teardown
	setup_subject || return 1
	local repo_dir="${TEST_ROOT}/Git/example-current"
	local old_wt="${TEST_ROOT}/Git/example-current-feature-active"
	local branch="feature/active"
	local rc=0 moved=""
	mkdir -p "$repo_dir" || rc=1
	git -C "$repo_dir" init -q -b main || rc=1
	git -C "$repo_dir" config user.email test@example.invalid || rc=1
	git -C "$repo_dir" config user.name 'Aidevops Test' || rc=1
	git -C "$repo_dir" commit -q --allow-empty -m init || rc=1
	git -C "$repo_dir" worktree add -q -b "$branch" "$old_wt" main || rc=1
	printf '{"initialized_repos":[{"slug":"example/current","path":"%s","local_only":false}],"worktree_base_dir":"%s"}\n' \
		"$repo_dir" "$AIDEVOPS_WORKTREE_BASE_DIR" >"$AIDEVOPS_REPOS_JSON" || rc=1

	(
		cd "$old_wt" || exit 1
		moved=$(_pc_relocate_registered_worktrees "$AIDEVOPS_REPOS_JSON") || exit 1
		[[ "$moved" == "0" ]] || exit 1
	) || rc=1
	[[ -d "$old_wt" ]] || rc=1
	grep -q 'worktree-skipped.*current-worktree.*mode=skipped' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	print_result "current worktree is not relocated" "$rc" \
		"log=$(cat "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null)"
	return 0
}

test_central_unregistered_inventory() {
	teardown
	setup_subject || return 1
	local repo_dir="${TEST_ROOT}/Git/contribution"
	local wt="${AIDEVOPS_WORKTREE_BASE_DIR}/contribution-feature"
	local orphan="${AIDEVOPS_WORKTREE_BASE_DIR}/missing-canonical"
	local rc=0 removed=""
	mkdir -p "$repo_dir" "$AIDEVOPS_WORKTREE_BASE_DIR" "$orphan" || return 1
	git -C "$repo_dir" init -q -b main || return 1
	git -C "$repo_dir" config user.email test@example.invalid
	git -C "$repo_dir" config user.name 'Aidevops Test'
	git -C "$repo_dir" commit -q --allow-empty -m init || return 1
	git -C "$repo_dir" worktree add -q -b feature "$wt" main || return 1
	printf 'gitdir: %s/.git/worktrees/missing-canonical\n' "${TEST_ROOT}/Git/removed" >"$orphan/.git"
	printf '{"initialized_repos":[],"worktree_base_dir":"%s"}\n' "$AIDEVOPS_WORKTREE_BASE_DIR" >"$AIDEVOPS_REPOS_JSON"
	gh() { if [[ "$*" == 'api rate_limit --jq .resources.graphql.remaining' ]]; then printf '5000\n'; return 0; fi; return 1; }
	_pc_fixture_process_clear() { return 0; }
	_worktree_owner_alive() { return 1; }
	_pc_thirdparty_pr() { printf '{"number":11,"state":"OPEN"}\n'; return 0; }
	removed=$(_pc_cleanup_central_unregistered) || rc=1
	[[ "$removed" == 0 && -d "$wt" ]] || rc=1
	grep -q 'thirdparty.*decision=open-pr' "$LOGFILE" || rc=1
	grep -q 'thirdparty eligible=.*kept_open_pr=1' "$LOGFILE" || rc=1
	# A registered canonical must not be revisited by the extra pass.
	printf '{"initialized_repos":[{"path":"%s"}]}\n' "$repo_dir" >"$AIDEVOPS_REPOS_JSON"
	removed=$(_pc_cleanup_central_unregistered) || rc=1
	[[ "$removed" == 0 ]] || rc=1
	_pc_log_invalid_repo_path_once 'invalid/entry'
	_pc_log_invalid_repo_path_once 'invalid/entry'
	[[ "$(grep -c 'invalid repo path configured' "$LOGFILE")" == 1 ]] || rc=1
	print_result "central unregistered open PR preserved and registered repo excluded" "$rc"
	return 0
}

test_thirdparty_classification() {
	teardown
	setup_subject || return 1
	local repo="${TEST_ROOT}/Git/contribution" wt="${AIDEVOPS_WORKTREE_BASE_DIR}/contribution-feature" cache="${TEST_ROOT}/cache.json" rc=0 decision=""
	mkdir -p "$repo" "$AIDEVOPS_WORKTREE_BASE_DIR" || return 1
	git -C "$repo" init -q -b main || return 1
	git -C "$repo" config user.email test@example.invalid
	git -C "$repo" config user.name 'Aidevops Test'
	git -C "$repo" commit -q --allow-empty -m init || return 1
	git -C "$repo" worktree add -q -b feature "$wt" main || return 1
	_pc_fixture_process_clear() { return 0; }
	_worktree_owner_alive() { return 1; }
	_pc_thirdparty_pr() { printf '{"number":11,"state":"OPEN"}\n'; return 0; }
	decision=$(_pc_thirdparty_candidate "$wt" "$repo" "$cache" 0) || rc=1
	[[ "$decision" == open-pr && -d "$wt" ]] || rc=1
	printf 'unsent\n' >"$wt/unsent.txt"
	decision=$(_pc_thirdparty_candidate "$wt" "$repo" "$cache" 0) || rc=1
	[[ "$decision" == open-pr && -d "$wt" ]] || rc=1
	[[ "$(grep -c 'thirdparty-open-pr-unsent-work' "$LOGFILE")" == 1 ]] || rc=1
	_pc_thirdparty_pr() { printf '{"number":11,"state":"CLOSED"}\n'; return 0; }
	decision=$(_pc_thirdparty_candidate "$wt" "$repo" "$cache" 0) || rc=1
	[[ "$decision" == eligible && -d "$wt" ]] || rc=1
	_pc_thirdparty_pr() { printf 'null\n'; return 0; }
	_pc_unregistered_activity_epoch() { date +%s; return 0; }
	decision=$(_pc_thirdparty_candidate "$wt" "$repo" "$cache" 0) || rc=1
	[[ "$decision" == young ]] || rc=1
	_pc_unregistered_activity_epoch() { printf '100000\n'; return 0; }
	decision=$(_pc_thirdparty_candidate "$wt" "$repo" "$cache" 0) || rc=1
	[[ "$decision" == eligible ]] || rc=1
	print_result "thirdparty open, unsent, closed, young and old report-only" "$rc" "$decision"
	return 0
}

test_thirdparty_apply_guards() {
	teardown
	setup_subject || return 1
	local repo="${TEST_ROOT}/Git/contribution" wt="${AIDEVOPS_WORKTREE_BASE_DIR}/contribution-feature" orphan="${AIDEVOPS_WORKTREE_BASE_DIR}/missing-canonical" rc=0 decision=""
	mkdir -p "$repo" "$AIDEVOPS_WORKTREE_BASE_DIR" "$orphan" || return 1
	git -C "$repo" init -q -b main || return 1
	git -C "$repo" config user.email test@example.invalid
	git -C "$repo" config user.name 'Aidevops Test'
	git -C "$repo" commit -q --allow-empty -m init || return 1
	git -C "$repo" remote add origin https://github.com/example/contribution.git
	git -C "$repo" worktree add -q -b feature "$wt" main || return 1
	printf 'dirty\n' >"$wt/dirty.txt"
	_pc_fixture_process_clear() { return 0; }
	_worktree_owner_alive() { return 1; }
	_pc_thirdparty_pr() { printf '{"number":11,"state":"CLOSED"}\n'; return 0; }
	_pc_compact_archive_policy_clear() { return 0; }
	_pc_archive_worktree_compactly() { return 1; }
	decision=$(_pc_thirdparty_candidate "$wt" "$repo" "${TEST_ROOT}/cache" 1) || decision=skipped
	[[ "$decision" == skipped && -d "$wt" ]] || rc=1
	_pc_archive_worktree_compactly() { printf '%s\n' "${TEST_ROOT}/verified-archive"; return 0; }
	worktree_removal_guard() { return 0; }
	decision=$(_pc_thirdparty_candidate "$wt" "$repo" "${TEST_ROOT}/cache" 1) || rc=1
	[[ "$decision" == archived-removed && ! -d "$wt" ]] || rc=1
	printf 'gitdir: %s/.git/worktrees/missing-canonical\n' "${TEST_ROOT}/Git/deleted" >"$orphan/.git"
	printf 'recovery\n' >"$orphan/evidence.txt"
	decision=$(_pc_thirdparty_candidate "$orphan" "" "${TEST_ROOT}/cache" 0) || rc=1
	[[ "$decision" == orphan-candidate && -d "$orphan" ]] || rc=1
	_pc_trash_orphan_dir() { mv "$1" "${TEST_ROOT}/trash"; return $?; }
	decision=$(_pc_thirdparty_candidate "$orphan" "" "${TEST_ROOT}/cache" 1) || rc=1
	[[ "$decision" == orphan-removed && -f "${TEST_ROOT}/trash/evidence.txt" ]] || rc=1
	print_result "closed dirty archive failure veto, verified removal, orphan recoverable trash" "$rc" "$decision"
	return 0
}

test_thirdparty_pr_cache_and_open_priority() {
	teardown
	setup_subject || return 1
	unset _PULSE_CLEANUP_WORKTREE_REMOVAL_LOADED
	# Restore the real PR lookup after earlier fixture overrides.
	source "${SCRIPT_DIR}/../pulse-cleanup-worktree-removal.sh"
	local repo="${TEST_ROOT}/Git/contribution" cache="${TEST_ROOT}/pr-cache.json" answer="" rc=0
	mkdir -p "$repo" || return 1
	git -C "$repo" init -q -b main || return 1
	git -C "$repo" remote add upstream https://github.com/example/upstream.git
	git -C "$repo" remote add origin https://github.com/example/fork.git
	gh() {
		printf '%s\n' '[[{"number":2,"state":"closed","merged_at":null,"head":{"ref":"feature"}},{"number":3,"state":"open","merged_at":null,"head":{"ref":"feature"}}]]'
		return 0
	}
	answer=$(_pc_thirdparty_pr "$repo" feature "$cache") || rc=1
	[[ "$(jq -r '.number' <<<"$answer")" == 3 ]] || rc=1
	gh() { return 1; }
	answer=$(_pc_thirdparty_pr "$repo" feature "$cache") || rc=1
	[[ "$(jq -r '.state' <<<"$answer")" == open ]] || rc=1
	print_result "upstream PR open priority and daily cache" "$rc" "answer=$answer cache=$cache"
	return 0
}

test_registered_parent_worktree_moves_to_central_base
test_current_worktree_is_not_moved
test_central_unregistered_inventory
test_thirdparty_classification
test_thirdparty_apply_guards
test_thirdparty_pr_cache_and_open_priority

printf '\n'
printf 'Results: %s/%s passed, %s failed.\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN" "$TESTS_FAILED"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
