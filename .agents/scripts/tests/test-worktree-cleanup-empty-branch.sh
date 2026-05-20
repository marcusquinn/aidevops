#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worktree-cleanup-empty-branch.sh — t3545/GH#22606 regression guard.
#
# Asserts that worktree cleanup NEVER permanently removes a freshly-created
# branch with zero commits past the default. Such a branch IS pre-work, not
# merged work — `git branch --merged` matches it because HEAD == default's
# HEAD, but classifying that as "merged" routes the worktree through
# permanent removal (mode=permanent, no trash backing) and destroys any
# uncommitted edits. Branch is also deleted, so no checkout-recovery path.
#
# Tests cover:
#
#   1. should_skip_cleanup — zero commits ahead + clean → skip (empty-branch)
#   2. should_skip_cleanup — zero commits ahead + dirty → skip (empty-branch
#      check fires first; legacy zero-commit-dirty also covers this)
#   3. should_skip_cleanup — has commits ahead → empty-branch check does NOT
#      fire (existing behaviour preserved)
#   4. should_skip_cleanup — zero commits ahead + force_merged=true →
#      empty-branch check does NOT fire (operator opted into removal)
#   5. _clean_classify_worktree — zero-commit branch matched by
#      `git branch --merged` is NOT classified as merged (Check 1 guard)
#
# All tests stub helpers that worktree-clean-lib.sh expects from its
# orchestrator. No real git/gh calls are made; this is unit-level coverage
# of the safety logic.
#
# Usage:
#   bash .agents/scripts/tests/test-worktree-cleanup-empty-branch.sh

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLEAN_LIB_PATH="${TEST_SCRIPTS_DIR}/worktree-clean-lib.sh"

# NOT readonly — shared-constants.sh declares readonly RED/GREEN/RESET
# and the collision under `set -e` would silently kill the test shell.
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# Sandbox HOME so any audit-log writes land inside the temp root
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

# Build a minimal fake repo path so the worktree path argument resolves to
# something that exists on disk. We don't init git here — all git calls
# are stubbed at function level inside each subshell.
FAKE_REPO="${TEST_ROOT}/fake-worktree"
mkdir -p "$FAKE_REPO"
# Backdate so worktree_is_in_grace_period (stubbed below) and any other
# mtime-sensitive checks see an "old" path. Stubs cover this anyway, but
# this keeps the directory plausibly stale on inspection.
_old_ts=$(date -u -v-30H +%Y%m%d%H%M 2>/dev/null \
	|| date -u -d "30 hours ago" +%Y%m%d%H%M 2>/dev/null \
	|| echo "202601010000")
touch -t "$_old_ts" "$FAKE_REPO" 2>/dev/null || true

# Common stub block — used by every test subshell. Defined here so each
# test's body stays focused on the variable-under-test.
# shellcheck disable=SC2034  # FAKE_REPO is consumed in test subshells
_run_with_stubs() {
	local zero_commits="$1"     # "true" or "false"
	local has_changes="$2"      # "true" or "false"
	local force_merged="$3"     # "true" or "false"
	local fn_to_call="$4"       # should_skip_cleanup or _clean_classify_worktree
	shift 4
	local fn_args=("$@")

	(
		set +e
		# Stub deps that worktree-clean-lib.sh expects from its orchestrator.
		# Each one returns a determinate value so only the empty-branch path
		# can fire when we want it to.
		_branch_has_active_interactive_claim() { return 1; }  # no claim
		is_worktree_owned_by_others() { return 1; }           # no other owner
		check_worktree_owner() { echo ""; return 0; }
		worktree_is_in_grace_period() { return 1; }           # outside grace
		branch_was_pushed() { return 1; }
		_branch_exists_on_any_remote() { return 0; }
		log_worktree_removal_event() { :; }
		trash_path() { return 0; }
		get_default_branch() { echo "main"; }
		localdev_auto_branch_rm() { :; }
		assert_git_available() { return 0; }
		assert_main_worktree_sane() { return 0; }
		# git stub for _clean_classify_worktree Check 1 — pretend git
		# branch --merged matches the wt_branch arg. Other git calls fall
		# through to the real binary (none of those paths run in our tests).
		git() {
			if [[ "${1:-}" == "branch" && "${2:-}" == "--merged" ]]; then
				printf '  bugfix/t3545-empty\n'
				return 0
			fi
			command git "$@"
		}

		# Variables-under-test
		if [[ "$zero_commits" == "true" ]]; then
			branch_has_zero_commits_ahead() { return 0; }
		else
			branch_has_zero_commits_ahead() { return 1; }
		fi
		if [[ "$has_changes" == "true" ]]; then
			worktree_has_changes() { return 0; }
		else
			worktree_has_changes() { return 1; }
		fi

		# Fallback colour vars (silence set -u when shared-constants is
		# absent — the lib references RED/NC unconditionally in printf).
		: "${RED:=}" "${GREEN:=}" "${YELLOW:=}" "${BLUE:=}" "${BOLD:=}" "${NC:=}"
		_WTAR_REMOVED="${_WTAR_REMOVED:-removed}"
		_WTAR_SKIPPED="${_WTAR_SKIPPED:-skipped}"
		_WTAR_WH_CALLER="${_WTAR_WH_CALLER:-test}"
		export RED GREEN YELLOW BLUE BOLD NC
		export _WTAR_REMOVED _WTAR_SKIPPED _WTAR_WH_CALLER

		# Source the clean lib in this subshell.
		# shellcheck source=/dev/null
		source "$CLEAN_LIB_PATH" >/dev/null 2>&1 || exit 9

		# Overrides MUST come AFTER sourcing for any function the lib
		# itself defines (worktree_is_in_grace_period,
		# branch_has_zero_commits_ahead, _branch_has_active_interactive_claim).
		# worktree_has_changes lives in worktree-helper-add.sh which we don't
		# source — define it here so the lib can call it.
		_branch_has_active_interactive_claim() { return 1; }
		worktree_is_in_grace_period() { return 1; }
		# _file_mtime_epoch is referenced by the real
		# worktree_is_in_grace_period — stub for safety even though our
		# override short-circuits before it is called.
		_file_mtime_epoch() { echo 0; }
		if [[ "$zero_commits" == "true" ]]; then
			branch_has_zero_commits_ahead() { return 0; }
		else
			branch_has_zero_commits_ahead() { return 1; }
		fi
		if [[ "$has_changes" == "true" ]]; then
			worktree_has_changes() { return 0; }
		else
			worktree_has_changes() { return 1; }
		fi

		# Invoke the function under test
		"$fn_to_call" "${fn_args[@]}" >/dev/null 2>&1
		echo "$?"
	)
	return 0
}

# =============================================================================
# Test 1 — zero commits + clean → skip (CANONICAL EMPTY-BRANCH CASE)
# =============================================================================
# This is THE bug from #22606: freshly-created worktree, model fetched files
# but hasn't started editing yet. Without this fix it would fall through
# every existing safety check (no claim, no other owner, past grace, no
# open PR, not zero-commit-dirty because clean) and be permanently removed.
test_zero_commits_clean_skipped() {
	local rc
	rc=$(_run_with_stubs "true" "false" "false" \
		should_skip_cleanup "$FAKE_REPO" "bugfix/t3545-empty" "main" "" "false")
	if [[ "$rc" == "0" ]]; then
		print_result "zero commits + clean → skip (empty-branch)" 0
	else
		print_result "zero commits + clean → skip (empty-branch)" 1 "(rc=$rc)"
	fi
	return 0
}
test_zero_commits_clean_skipped

# =============================================================================
# Test 2 — zero commits + dirty → skip (empty-branch fires first; legacy
#          zero-commit-dirty would also catch this case)
# =============================================================================
test_zero_commits_dirty_skipped() {
	local rc
	rc=$(_run_with_stubs "true" "true" "false" \
		should_skip_cleanup "$FAKE_REPO" "bugfix/t3545-empty" "main" "" "false")
	if [[ "$rc" == "0" ]]; then
		print_result "zero commits + dirty → skip" 0
	else
		print_result "zero commits + dirty → skip" 1 "(rc=$rc)"
	fi
	return 0
}
test_zero_commits_dirty_skipped

# =============================================================================
# Test 3 — has commits ahead → empty-branch does NOT fire
# =============================================================================
# A branch with real commits past origin/main can legitimately be merged
# (and removed). The new empty-branch check must NOT fire here, otherwise
# we'd preserve every merged worktree forever and leak disk.
test_has_commits_falls_through() {
	local rc
	rc=$(_run_with_stubs "false" "false" "false" \
		should_skip_cleanup "$FAKE_REPO" "feature/t3545-real" "main" "" "false")
	# rc=1 means "no skip — caller may proceed with removal". This is the
	# expected fall-through behaviour for a genuinely-merged branch.
	if [[ "$rc" == "1" ]]; then
		print_result "has commits ahead → empty-branch does NOT fire" 0
	else
		print_result "has commits ahead → empty-branch does NOT fire" 1 "(rc=$rc)"
	fi
	return 0
}
test_has_commits_falls_through

# =============================================================================
# Test 4 — zero commits + force_merged=true → empty-branch does NOT fire
# =============================================================================
# When the operator explicitly passes --force-merged they have opted into
# removing even questionable worktrees. We honour that intent — the
# empty-branch check is bypassed but the legacy zero-commit-dirty check
# (and dirty-skip) may still apply depending on file state.
#
# With clean state + force_merged=true, all safety checks fall through →
# rc=1 (proceed with removal). This is the only case where a zero-commit
# branch can be removed by cleanup, and it requires explicit operator opt-in.
test_force_merged_bypasses_empty_check() {
	local rc
	rc=$(_run_with_stubs "true" "false" "true" \
		should_skip_cleanup "$FAKE_REPO" "bugfix/t3545-force" "main" "" "true")
	if [[ "$rc" == "1" ]]; then
		print_result "zero commits + force_merged → no skip (operator opt-in)" 0
	else
		print_result "zero commits + force_merged → no skip (operator opt-in)" 1 "(rc=$rc)"
	fi
	return 0
}
test_force_merged_bypasses_empty_check

# =============================================================================
# Test 5 — _clean_classify_worktree Check 1 guard
# =============================================================================
# Zero-commit branch matched by `git branch --merged` is NOT classified as
# merged. This is the upstream defense — even if all safety checks somehow
# fail open, the classifier itself refuses to call this "merged work".
#
# The function prints merge_type to stdout when merged. Empty stdout means
# not merged. We capture stdout and assert it's empty for a zero-commit branch.
test_classify_zero_commit_not_merged() {
	local stdout
	stdout=$(
		set +e
		_branch_has_active_interactive_claim() { return 1; }
		is_worktree_owned_by_others() { return 1; }
		check_worktree_owner() { echo ""; return 0; }
		worktree_is_in_grace_period() { return 1; }
		worktree_has_changes() { return 1; }
		branch_was_pushed() { return 1; }
		_branch_exists_on_any_remote() { return 0; }
		log_worktree_removal_event() { :; }
		trash_path() { return 0; }
		get_default_branch() { echo "main"; }
		localdev_auto_branch_rm() { :; }
		assert_git_available() { return 0; }
		assert_main_worktree_sane() { return 0; }
		# Pretend git branch --merged matches the test branch
		git() {
			if [[ "${1:-}" == "branch" && "${2:-}" == "--merged" ]]; then
				printf '  bugfix/t3545-empty\n'
				return 0
			fi
			command git "$@"
		}
		: "${RED:=}" "${GREEN:=}" "${YELLOW:=}" "${BLUE:=}" "${BOLD:=}" "${NC:=}"
		_WTAR_REMOVED="${_WTAR_REMOVED:-removed}"
		_WTAR_SKIPPED="${_WTAR_SKIPPED:-skipped}"
		_WTAR_WH_CALLER="${_WTAR_WH_CALLER:-test}"
		export RED GREEN YELLOW BLUE BOLD NC
		export _WTAR_REMOVED _WTAR_SKIPPED _WTAR_WH_CALLER

		# shellcheck source=/dev/null
		source "$CLEAN_LIB_PATH" >/dev/null 2>&1 || exit 9

		# After source, override functions defined inside the lib itself
		_branch_has_active_interactive_claim() { return 1; }
		worktree_is_in_grace_period() { return 1; }
		_file_mtime_epoch() { echo 0; }
		branch_has_zero_commits_ahead() { return 0; }
		worktree_has_changes() { return 1; }

		# Args: wt_path, wt_branch, default_br, remote_unknown,
		#       merged_prs, open_prs, force_merged, closed_prs
		_clean_classify_worktree "$FAKE_REPO" "bugfix/t3545-empty" "main" \
			"false" "" "" "false" "" 2>/dev/null
	)
	# Empty stdout → not classified as merged. Any non-empty merge_type
	# (e.g. "merged", "remote deleted", "squash-merged PR", "closed PR")
	# would trigger removal.
	if [[ -z "$stdout" ]]; then
		print_result "_clean_classify_worktree zero-commit → not merged" 0
	else
		print_result "_clean_classify_worktree zero-commit → not merged" 1 \
			"(unexpected merge_type='$stdout')"
	fi
	return 0
}
test_classify_zero_commit_not_merged

test_branch_list_exact_matching() {
	local stdout=""
	stdout=$(
		set +e
		: "${RED:=}" "${GREEN:=}" "${YELLOW:=}" "${BLUE:=}" "${BOLD:=}" "${NC:=}"
		_WTAR_REMOVED="${_WTAR_REMOVED:-removed}"
		_WTAR_SKIPPED="${_WTAR_SKIPPED:-skipped}"
		_WTAR_WH_CALLER="${_WTAR_WH_CALLER:-test}"
		export RED GREEN YELLOW BLUE BOLD NC
		export _WTAR_REMOVED _WTAR_SKIPPED _WTAR_WH_CALLER

		# shellcheck source=/dev/null
		source "$CLEAN_LIB_PATH" >/dev/null 2>&1 || exit 9

		if _clean_branch_list_contains_exact "feature/target" $'feature/target-extra\nfeature/target\nfeature/other' \
			&& ! _clean_branch_list_contains_exact "feature/target" $'feature/target-extra\nfeature/other'; then
			printf 'ok\n'
		else
			printf 'fail\n'
		fi
	)
	if [[ "$stdout" == "ok" ]]; then
		print_result "_clean_branch_list_contains_exact matches whole lines only" 0
	else
		print_result "_clean_branch_list_contains_exact matches whole lines only" 1 \
			"(unexpected result='$stdout')"
	fi
	return 0
}
test_branch_list_exact_matching

# =============================================================================
# Summary
# =============================================================================
printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%s%d/%d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi
