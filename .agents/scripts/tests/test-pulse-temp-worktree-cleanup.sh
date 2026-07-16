#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for stale detached fixture cleanup and stale local main.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULSE_CLEANUP="${SCRIPT_DIR}/../pulse-cleanup.sh"
TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

# Fixture repositories are intentionally isolated under TEST_ROOT. Use native
# Git so the production canonical-worktree shim does not block test setup.
git() {
	/usr/bin/git "$@"
	return $?
}

print_result() {
	local name="$1"
	local rc="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s %s\n' "$name" "$detail"
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

age_gitfile() {
	local gitfile="$1"
	local hours_ago="$2"
	if touch -d "${hours_ago} hours ago" "$gitfile" 2>/dev/null; then
		return 0
	fi
	local old_ts=""
	old_ts=$(date -v-"${hours_ago}"H +%Y%m%d%H%M 2>/dev/null \
		|| date -d "${hours_ago} hours ago" +%Y%m%d%H%M 2>/dev/null) || return 1
	touch -t "$old_ts" "$gitfile"
	return $?
}

setup_subject() {
	TEST_ROOT=$(mktemp -d) || return 1
	TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P) || return 1
	trap teardown EXIT
	export HOME="${TEST_ROOT}/home"
	export AIDEVOPS_LOG_DIR="${HOME}/.aidevops/logs"
	export AIDEVOPS_REPOS_JSON="${HOME}/.config/aidevops/repos.json"
	export AIDEVOPS_CLEANUP_LOG="${TEST_ROOT}/cleanup.log"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export TEMP_WORKTREE_GRACE_SECS=3600
	export TEMP_WORKTREE_MAX_REMOVALS_PER_RUN=10
	unset TEMP_WORKTREE_LOCK_STALE_SECS 2>/dev/null || true
	mkdir -p "$AIDEVOPS_LOG_DIR" "${HOME}/.config/aidevops" || return 1

	is_registered_canonical() { local wt_path="$1"; : "$wt_path"; return 1; }
	is_worktree_owned_by_others() { local wt_path="$1"; : "$wt_path"; return 1; }
	unregister_worktree() { local wt_path="$1"; : "$wt_path"; return 0; }
	gh_pr_list() { return 0; }
	recover_failed_launch_state() { return 0; }
	gh_issue_comment() { return 0; }

	unset _PULSE_CLEANUP_LOADED 2>/dev/null || true
	unset _PULSE_TEMP_WORKTREE_CLEANUP_LOADED 2>/dev/null || true
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../portable-stat.sh
	source "${SCRIPT_DIR}/../portable-stat.sh"
	# shellcheck source=../pulse-cleanup.sh
	source "$PULSE_CLEANUP"
	return 0
}

create_repo_with_remote() {
	local repo_path="$1"
	local remote_path="$2"
	git init -q --bare "$remote_path" || return 1
	git init -q -b main "$repo_path" || return 1
	git -C "$repo_path" config user.email test@example.invalid || return 1
	git -C "$repo_path" config user.name 'Aidevops Test' || return 1
	printf 'base\n' >"${repo_path}/README.md" || return 1
	printf '.fixture-cache\n' >"${repo_path}/.gitignore" || return 1
	git -C "$repo_path" add README.md .gitignore || return 1
	git -C "$repo_path" commit -q -m base || return 1
	git -C "$repo_path" remote add origin "$remote_path" || return 1
	git -C "$repo_path" push -q -u origin main || return 1
	git -C "$remote_path" symbolic-ref HEAD refs/heads/main || return 1
	printf '{"initialized_repos":[{"path":"%s","slug":"example/repo"}]}\n' \
		"$repo_path" >"$AIDEVOPS_REPOS_JSON" || return 1
	return 0
}

test_fast_temp_cleanup_guards() {
	setup_subject || return 1
	local repo_path="${TEST_ROOT}/repo"
	local remote_path="${TEST_ROOT}/remote.git"
	local old_clean="${TEST_ROOT}/tmp.old-clean"
	local old_dirty="${TEST_ROOT}/tmp.old-dirty"
	local old_ignored="${TEST_ROOT}/tmp.old-ignored"
	local old_unpushed="${TEST_ROOT}/tmp.old-unpushed"
	local old_active="${TEST_ROOT}/tmp.old-active"
	local fresh_clean="${TEST_ROOT}/tmp.fresh-clean"
	local snapshot_count_file="${TEST_ROOT}/snapshot-count"
	local removed=0
	local rc=0
	create_repo_with_remote "$repo_path" "$remote_path" || return 1

	git -C "$repo_path" worktree add -q --detach "$old_clean" origin/main || return 1
	git -C "$repo_path" worktree add -q --detach "$old_dirty" origin/main || return 1
	git -C "$repo_path" worktree add -q --detach "$old_ignored" origin/main || return 1
	git -C "$repo_path" worktree add -q --detach "$old_unpushed" origin/main || return 1
	git -C "$repo_path" worktree add -q --detach "$old_active" origin/main || return 1
	git -C "$repo_path" worktree add -q --detach "$fresh_clean" origin/main || return 1
	age_gitfile "$old_clean/.git" 2 || return 1
	age_gitfile "$old_dirty/.git" 2 || return 1
	age_gitfile "$old_ignored/.git" 2 || return 1
	age_gitfile "$old_unpushed/.git" 2 || return 1
	age_gitfile "$old_active/.git" 2 || return 1
	printf 'dirty fixture\n' >"${old_dirty}/dirty.txt" || return 1
	printf 'ignored fixture data\n' >"${old_ignored}/.fixture-cache" || return 1
	printf 'unique detached commit\n' >"${old_unpushed}/unique.txt" || return 1
	git -C "$old_unpushed" add unique.txt || return 1
	git -C "$old_unpushed" -c user.email=test@example.invalid -c user.name='Aidevops Test' \
		commit -q -m 'unique detached commit' || return 1
	capture_worktree_process_cwds() {
		local snapshot_count=0
		if [[ -f "$snapshot_count_file" ]]; then
			IFS= read -r snapshot_count <"$snapshot_count_file" || snapshot_count=0
		fi
		snapshot_count=$((snapshot_count + 1))
		printf '%s\n' "$snapshot_count" >"$snapshot_count_file"
		printf '%s\n' "$old_active"
		return 0
	}

	removed=$(cleanup_stale_temp_worktrees) || rc=1
	[[ "$removed" == "1" ]] || rc=1
	[[ ! -e "$old_clean" ]] || rc=1
	[[ -d "$old_dirty" && -f "$old_dirty/dirty.txt" ]] || rc=1
	[[ -d "$old_ignored" && -f "$old_ignored/.fixture-cache" ]] || rc=1
	[[ -d "$old_unpushed" && -f "$old_unpushed/unique.txt" ]] || rc=1
	[[ -d "$old_active" ]] || rc=1
	[[ -d "$fresh_clean" ]] || rc=1
	# Both otherwise-removable candidates get independent snapshots. The active
	# candidate is refused and the clean candidate is removed.
	[[ -f "$snapshot_count_file" ]] && [[ "$(<"$snapshot_count_file")" == "2" ]] || rc=1
	git -C "$repo_path" worktree list --porcelain | grep -Fq "worktree $old_clean" && rc=1
	grep -q 'stale-temp-fixture' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	print_result "fast cleanup removes only old clean remote-reachable detached fixtures" "$rc" \
		"removed=$removed"
	return 0
}

test_local_only_repo_is_excluded() {
	teardown
	setup_subject || return 1
	local repo_path="${TEST_ROOT}/repo-local"
	local remote_path="${TEST_ROOT}/remote-local.git"
	local wt_path="${TEST_ROOT}/tmp.local-only"
	local capture_marker="${TEST_ROOT}/capture-called"
	local removed=0
	local rc=0
	create_repo_with_remote "$repo_path" "$remote_path" || return 1
	git -C "$repo_path" worktree add -q --detach "$wt_path" origin/main || return 1
	age_gitfile "$wt_path/.git" 2 || return 1
	printf '{"initialized_repos":[{"path":"%s","slug":"example/local","local_only":true}]}\n' \
		"$repo_path" >"$AIDEVOPS_REPOS_JSON" || return 1
	capture_worktree_process_cwds() {
		: >"$capture_marker"
		return 0
	}

	removed=$(cleanup_stale_temp_worktrees) || rc=1
	[[ "$removed" == "0" ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	[[ ! -e "$capture_marker" ]] || rc=1
	print_result "fast cleanup excludes local-only repositories" "$rc" "removed=$removed"
	return 0
}

test_cleanup_bounds_fresh_snapshots() {
	teardown
	setup_subject || return 1
	local repo_path="${TEST_ROOT}/repo-bounded"
	local remote_path="${TEST_ROOT}/remote-bounded.git"
	local wt_one="${TEST_ROOT}/tmp.bound-one"
	local wt_two="${TEST_ROOT}/tmp.bound-two"
	local snapshot_count_file="${TEST_ROOT}/bounded-snapshot-count"
	local remaining=0
	local removed=0
	local rc=0
	create_repo_with_remote "$repo_path" "$remote_path" || return 1
	git -C "$repo_path" worktree add -q --detach "$wt_one" origin/main || return 1
	git -C "$repo_path" worktree add -q --detach "$wt_two" origin/main || return 1
	age_gitfile "$wt_one/.git" 2 || return 1
	age_gitfile "$wt_two/.git" 2 || return 1
	export TEMP_WORKTREE_MAX_REMOVALS_PER_RUN=1
	capture_worktree_process_cwds() {
		local snapshot_count=0
		if [[ -f "$snapshot_count_file" ]]; then
			IFS= read -r snapshot_count <"$snapshot_count_file" || snapshot_count=0
		fi
		snapshot_count=$((snapshot_count + 1))
		printf '%s\n' "$snapshot_count" >"$snapshot_count_file"
		return 0
	}

	removed=$(cleanup_stale_temp_worktrees) || rc=1
	[[ "$removed" == "1" ]] || rc=1
	[[ "$(<"$snapshot_count_file")" == "1" ]] || rc=1
	[[ -d "$wt_one" ]] && remaining=$((remaining + 1))
	[[ -d "$wt_two" ]] && remaining=$((remaining + 1))
	[[ "$remaining" -eq 1 ]] || rc=1
	print_result "fast cleanup bounds removals and captures one fresh snapshot per removal" "$rc" \
		"removed=$removed remaining=$remaining"
	return 0
}

test_cleanup_lock_race_guards() {
	teardown
	setup_subject || return 1
	local lock_dir="${AIDEVOPS_LOG_DIR}/cleanup_temp_worktrees.lock"
	local reclaim_guard="${lock_dir}.reclaim.lock"
	local live_start=""
	local rc=0

	# A freshly-created lock without its PID is an owner publication window, not
	# stale state. A contender must preserve it.
	mkdir "$lock_dir" || return 1
	if _ptwc_lock_acquire; then
		rc=1
	fi
	[[ -d "$lock_dir" ]] || rc=1
	rm -rf "$lock_dir"

	# PID liveness alone is not ownership: the stored process-start fingerprint
	# must match so a recycled PID cannot preserve an abandoned lock.
	live_start=$(_ptwc_process_start_fingerprint "$$") || return 1
	mkdir "$lock_dir" || return 1
	printf '%s\n' "$$" >"${lock_dir}/pid" || return 1
	printf '%s\n' "$live_start" >"${lock_dir}/start" || return 1
	if _ptwc_lock_acquire; then
		rc=1
	fi
	[[ -d "$lock_dir" ]] || rc=1
	printf 'recycled-process-start\n' >"${lock_dir}/start" || return 1
	_ptwc_lock_acquire || rc=1
	[[ -n "$_PTWC_LOCK_OWNER_PID" && -n "$_PTWC_LOCK_OWNER_START" ]] || rc=1
	_ptwc_lock_release "$lock_dir"
	[[ ! -e "$lock_dir" ]] || rc=1

	# A single reclaim guard serialises dead-owner recovery. The blocked
	# contender must not move or delete the lock it inspected.
	mkdir "$lock_dir" "$reclaim_guard" || return 1
	printf '99999999\n' >"${lock_dir}/pid" || return 1
	printf 'dead-process-start\n' >"${lock_dir}/start" || return 1
	if _ptwc_lock_acquire; then
		rc=1
	fi
	[[ -f "${lock_dir}/pid" ]] || rc=1
	rmdir "$reclaim_guard" || return 1
	_ptwc_lock_acquire || rc=1
	[[ -n "$_PTWC_LOCK_OWNER_PID" ]] || rc=1

	# Release must not delete a successor lock whose process identity no longer
	# matches this caller's ownership token, even if the PID is unchanged.
	printf '%s\n' "$_PTWC_LOCK_OWNER_PID" >"${lock_dir}/pid" || return 1
	printf 'successor-process-start\n' >"${lock_dir}/start" || return 1
	_ptwc_lock_release "$lock_dir"
	[[ -d "$lock_dir" ]] || rc=1
	[[ -z "$_PTWC_LOCK_DIR" && -z "$_PTWC_LOCK_OWNER_PID" && \
		-z "$_PTWC_LOCK_OWNER_START" ]] || rc=1
	rm -rf "$lock_dir"
	print_result "cleanup lock preserves publication windows and successor owners" "$rc"
	return 0
}

test_stale_local_main_uses_remote_default() {
	teardown
	setup_subject || return 1
	local repo_path="${TEST_ROOT}/repo-stale-main"
	local remote_path="${TEST_ROOT}/remote-stale-main.git"
	local wt_path="${TEST_ROOT}/tmp.remote-tip"
	local base_sha=""
	local now_epoch=0
	local cleanup_rc=0
	local rc=0
	create_repo_with_remote "$repo_path" "$remote_path" || return 1
	base_sha=$(git -C "$repo_path" rev-parse HEAD) || return 1
	printf 'remote tip\n' >"${repo_path}/remote-tip.txt" || return 1
	git -C "$repo_path" add remote-tip.txt || return 1
	git -C "$repo_path" commit -q -m 'remote tip' || return 1
	git -C "$repo_path" push -q origin main || return 1
	git -C "$repo_path" worktree add -q --detach "$wt_path" origin/main || return 1
	git -C "$repo_path" reset -q --hard "$base_sha" || return 1
	age_gitfile "$wt_path/.git" 2 || return 1
	now_epoch=$(date +%s)

	_cleanup_single_worktree "$repo_path" "$wt_path" "" "$now_epoch" "example/repo" "main" >/dev/null 2>&1
	cleanup_rc=$?
	[[ "$cleanup_rc" -eq 0 ]] || rc=1
	[[ ! -e "$wt_path" ]] || rc=1
	print_result "orphan cleanup compares against origin/main when local main is stale" "$rc" \
		"cleanup_rc=$cleanup_rc"
	return 0
}

test_path_classifier_rejects_normal_linked_worktree() {
	local rc=0
	_ptwc_is_temp_fixture_path "/home/example/Git/_worktrees/repo-feature" && rc=1
	_ptwc_is_temp_fixture_path "/private/var/folders/aa/bb/T/tmp.fixture/base-worktree" || rc=1
	print_result "temp cleanup path classifier is narrowly scoped" "$rc"
	return 0
}

run_test() {
	local test_function="$1"
	local tests_before="$TESTS_RUN"
	local test_rc=0
	if "$test_function"; then
		test_rc=0
	else
		test_rc=$?
	fi
	if [[ "$TESTS_RUN" -eq "$tests_before" ]]; then
		print_result "$test_function" 1 "aborted before reporting a result (rc=$test_rc)"
	fi
	return 0
}

run_test test_fast_temp_cleanup_guards
run_test test_local_only_repo_is_excluded
run_test test_cleanup_bounds_fresh_snapshots
run_test test_cleanup_lock_race_guards
run_test test_stale_local_main_uses_remote_default
run_test test_path_classifier_rejects_normal_linked_worktree

printf '\nResults: %s/%s passed, %s failed.\n' \
	"$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
