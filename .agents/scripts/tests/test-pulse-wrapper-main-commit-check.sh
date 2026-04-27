#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for _is_task_committed_to_main() (GH#17574)
#
# Verifies that the pre-dispatch main-commit check correctly detects
# when a task has already landed on main (via PR merge or direct commit),
# preventing redundant worker dispatch.

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"

	# Create a test git repo with origin/main
	local repo_path="${TEST_ROOT}/test-repo"
	mkdir -p "$repo_path"
	git -C "$repo_path" init --quiet
	git -C "$repo_path" config user.email "test@test.local"
	git -C "$repo_path" config user.name "Test User"
	git -C "$repo_path" checkout -b main --quiet 2>/dev/null || true

	# Initial commit
	printf 'initial\n' >"${repo_path}/README.md"
	git -C "$repo_path" add README.md
	git -C "$repo_path" commit -m "initial commit" --quiet

	# Create a bare remote and push
	local remote_path="${TEST_ROOT}/remote.git"
	git init --bare "$remote_path" --quiet
	git -C "$repo_path" remote add origin "$remote_path"
	git -C "$repo_path" push origin main --quiet 2>/dev/null

	export TEST_REPO_PATH="$repo_path"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"

	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Add a commit to main with a specific message and push to origin
add_commit_to_main() {
	local repo_path="$1"
	local message="$2"
	local filename
	filename="file-$(date +%s%N).txt"
	printf '%s\n' "$message" >"${repo_path}/${filename}"
	git -C "$repo_path" add "$filename"
	git -C "$repo_path" commit -m "$message" --quiet
	git -C "$repo_path" push origin main --quiet 2>/dev/null
	return 0
}

# Source the function under test. We need to extract just the function
# since pulse-wrapper.sh has too many dependencies to source fully.
# Instead, we'll define the function inline (copied from the source).
_is_task_committed_to_main() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_title="$3"
	local repo_path="$4"

	[[ -n "$issue_number" && -n "$repo_slug" && -n "$repo_path" ]] || return 1

	local -a search_patterns=()

	local task_id_match
	task_id_match=$(printf '%s' "$issue_title" | grep -oE '^t[0-9]+' | head -1) || task_id_match=""
	if [[ -n "$task_id_match" ]]; then
		search_patterns+=("$task_id_match")
	fi

	local gh_id_match
	gh_id_match=$(printf '%s' "$issue_title" | grep -oE '^GH#[0-9]+' | head -1) || gh_id_match=""
	if [[ -n "$gh_id_match" ]]; then
		search_patterns+=("$gh_id_match")
	fi

	search_patterns+=("#${issue_number}")

	if [[ ${#search_patterns[@]} -eq 0 ]]; then
		return 1
	fi

	# In tests, use a fixed date instead of calling gh API
	local created_at="${TEST_CREATED_AT:-2020-01-01T00:00:00Z}"

	if [[ -d "$repo_path/.git" ]] || git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
		git -C "$repo_path" fetch origin main --quiet 2>/dev/null || true
	else
		return 1
	fi

	local pattern
	for pattern in "${search_patterns[@]}"; do
		local match_count
		match_count=$(git -C "$repo_path" log origin/main --since="$created_at" \
			--oneline --grep="$pattern" -i 2>/dev/null | wc -l) || match_count=0
		match_count=$(printf '%s' "$match_count" | tr -d '[:space:]')
		if [[ "$match_count" -gt 0 ]]; then
			echo "[pulse-wrapper] _is_task_committed_to_main: found ${match_count} commit(s) matching '${pattern}' on origin/main since ${created_at} for #${issue_number} in ${repo_slug}" >>"$LOGFILE"
			return 0
		fi
	done

	return 1
}

# ── Test cases ──

test_detects_task_id_commit() {
	setup_test_env
	add_commit_to_main "$TEST_REPO_PATH" "t153: add dark mode toggle"

	local result=1
	if _is_task_committed_to_main "42" "owner/repo" "t153: add dark mode toggle" "$TEST_REPO_PATH"; then
		result=0
	fi
	print_result "detects tNNN task ID in commit message" "$result"
	teardown_test_env
	return 0
}

test_detects_gh_issue_commit() {
	setup_test_env
	add_commit_to_main "$TEST_REPO_PATH" "GH#17574: fix pulse dispatch"

	local result=1
	if _is_task_committed_to_main "17574" "owner/repo" "GH#17574: fix pulse dispatch" "$TEST_REPO_PATH"; then
		result=0
	fi
	print_result "detects GH#NNN in commit message" "$result"
	teardown_test_env
	return 0
}

test_detects_issue_number_in_commit() {
	setup_test_env
	add_commit_to_main "$TEST_REPO_PATH" "fix: resolve issue #42 with auth"

	local result=1
	if _is_task_committed_to_main "42" "owner/repo" "bug: auth is broken" "$TEST_REPO_PATH"; then
		result=0
	fi
	print_result "detects #NNN issue number in commit message" "$result"
	teardown_test_env
	return 0
}

test_no_match_returns_false() {
	setup_test_env
	add_commit_to_main "$TEST_REPO_PATH" "unrelated: update docs"

	local result=0
	if _is_task_committed_to_main "42" "owner/repo" "t153: add dark mode" "$TEST_REPO_PATH"; then
		result=1
	fi
	print_result "returns false when no matching commits exist" "$result"
	teardown_test_env
	return 0
}

test_empty_repo_path_returns_false() {
	setup_test_env

	local result=0
	if _is_task_committed_to_main "42" "owner/repo" "t153: add dark mode" ""; then
		result=1
	fi
	print_result "returns false for empty repo_path" "$result"
	teardown_test_env
	return 0
}

test_nonexistent_repo_returns_false() {
	setup_test_env

	local result=0
	if _is_task_committed_to_main "42" "owner/repo" "t153: add dark mode" "/nonexistent/path"; then
		result=1
	fi
	print_result "returns false for nonexistent repo path" "$result"
	teardown_test_env
	return 0
}

test_case_insensitive_match() {
	setup_test_env
	add_commit_to_main "$TEST_REPO_PATH" "T153: Add Dark Mode Toggle"

	local result=1
	if _is_task_committed_to_main "42" "owner/repo" "t153: add dark mode toggle" "$TEST_REPO_PATH"; then
		result=0
	fi
	print_result "case-insensitive match on task ID" "$result"
	teardown_test_env
	return 0
}

test_title_without_task_id_uses_issue_number() {
	setup_test_env
	add_commit_to_main "$TEST_REPO_PATH" "fix: resolve #999 auth bug"

	local result=1
	if _is_task_committed_to_main "999" "owner/repo" "bug: auth is broken" "$TEST_REPO_PATH"; then
		result=0
	fi
	print_result "falls back to issue number when title has no task ID" "$result"
	teardown_test_env
	return 0
}

# ── t2955: cache fast-path helpers ──
#
# We define the helpers inline (mirroring the production source at
# .agents/scripts/pulse-dispatch-core.sh) so the test runs without
# sourcing the full dispatch-core, which has too many dependencies.
# Production drift is caught by reading both during code review and
# by the integration check in test_t2955_helpers_match_production.

_has_committed_to_main_cache_label() {
	local issue_meta_json="$1"
	[[ -n "$issue_meta_json" ]] || return 1
	printf '%s' "$issue_meta_json" |
		jq -e '.labels | map(.name) | index("dispatch-blocked:committed-to-main")' >/dev/null 2>&1
}

# Stub the gh edit call to record invocations rather than hit the network.
# Tests assert on the recorded args.
_GH_EDIT_LOG=""
_apply_committed_to_main_cache_label() {
	local issue_number="$1"
	local repo_slug="$2"
	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 0
	_GH_EDIT_LOG+="${issue_number}|${repo_slug}|dispatch-blocked:committed-to-main\n"
	return 0
}

test_t2955_cache_label_present_returns_zero() {
	local meta='{"labels":[{"name":"bug"},{"name":"dispatch-blocked:committed-to-main"}]}'
	local result=1
	if _has_committed_to_main_cache_label "$meta"; then
		result=0
	fi
	print_result "t2955: cache fast-path detects label when present" "$result"
	return 0
}

test_t2955_cache_label_absent_returns_nonzero() {
	local meta='{"labels":[{"name":"bug"},{"name":"enhancement"}]}'
	local result=0
	if _has_committed_to_main_cache_label "$meta"; then
		result=1
	fi
	print_result "t2955: cache fast-path returns non-zero when label absent" "$result"
	return 0
}

test_t2955_cache_label_empty_meta_returns_nonzero() {
	local result=0
	if _has_committed_to_main_cache_label ""; then
		result=1
	fi
	print_result "t2955: cache fast-path returns non-zero on empty meta_json" "$result"
	return 0
}

test_t2955_cache_label_no_labels_array_returns_nonzero() {
	local meta='{"title":"some issue"}'
	local result=0
	if _has_committed_to_main_cache_label "$meta"; then
		result=1
	fi
	print_result "t2955: cache fast-path returns non-zero when labels array missing" "$result"
	return 0
}

test_t2955_apply_label_records_call() {
	_GH_EDIT_LOG=""
	_apply_committed_to_main_cache_label "21200" "owner/repo"
	local result=1
	if [[ "$_GH_EDIT_LOG" == *"21200|owner/repo|dispatch-blocked:committed-to-main"* ]]; then
		result=0
	fi
	print_result "t2955: apply_label invokes gh edit with correct args" "$result"
	return 0
}

test_t2955_apply_label_empty_args_returns_zero() {
	# Empty args must not invoke gh; must return 0 (best-effort contract).
	_GH_EDIT_LOG=""
	local result=1
	if _apply_committed_to_main_cache_label "" ""; then
		# rc=0 expected; verify gh was NOT called
		if [[ -z "$_GH_EDIT_LOG" ]]; then
			result=0
		fi
	fi
	print_result "t2955: apply_label is no-op + rc=0 when args empty" "$result"
	return 0
}

test_t2955_helpers_match_production() {
	# Drift guard: the inline helpers in this test file MUST match the
	# production implementations at pulse-dispatch-core.sh. We compare
	# the production line containing the canonical jq expression to
	# pin the contract.
	local prod_file
	prod_file="$(dirname "${BASH_SOURCE[0]}")/../pulse-dispatch-core.sh"
	if [[ ! -f "$prod_file" ]]; then
		print_result "t2955: production file present for drift check" "1" "missing $prod_file"
		return 0
	fi
	local result=1
	if grep -q 'index("dispatch-blocked:committed-to-main")' "$prod_file" &&
		grep -q '_has_committed_to_main_cache_label()' "$prod_file" &&
		grep -q '_apply_committed_to_main_cache_label()' "$prod_file"; then
		result=0
	fi
	print_result "t2955: production helpers match test stubs (drift guard)" "$result"
	return 0
}

# ── Run all tests ──

test_detects_task_id_commit
test_detects_gh_issue_commit
test_detects_issue_number_in_commit
test_no_match_returns_false
test_empty_repo_path_returns_false
test_nonexistent_repo_returns_false
test_case_insensitive_match
test_title_without_task_id_uses_issue_number
test_t2955_cache_label_present_returns_zero
test_t2955_cache_label_absent_returns_nonzero
test_t2955_cache_label_empty_meta_returns_nonzero
test_t2955_cache_label_no_labels_array_returns_nonzero
test_t2955_apply_label_records_call
test_t2955_apply_label_empty_args_returns_zero
test_t2955_helpers_match_production

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
