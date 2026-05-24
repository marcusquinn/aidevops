#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR_TEST}/../shared-dispatch-label-cleanup.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_HOME="$HOME"

print_result() {
	local name="$1"
	local passed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export REPOS_JSON="${TEST_ROOT}/repos.json"
	export PULSE_STALE_DISPATCH_LABEL_SWEEP_FORCE=1
	export PULSE_STALE_DISPATCH_LABEL_SWEEP_LIMIT_PER_REPO=5
	mkdir -p "$HOME/.aidevops/logs"
	: >"$LOGFILE"
	: >"${TEST_ROOT}/gh.log"
	cat >"$REPOS_JSON" <<'JSON'
{"initialized_repos":[{"slug":"owner/repo","pulse":true,"local_only":false},{"slug":"owner/local","pulse":true,"local_only":true},{"slug":"owner/off","pulse":false,"local_only":false}]}
JSON
	return 0
}

teardown_env() {
	export HOME="$ORIGINAL_HOME"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

install_gh_stub() {
	gh() {
		printf '%s\n' "$*" >>"${TEST_ROOT}/gh.log"
		if [[ "$1" == "issue" && "$2" == "list" ]]; then
			printf '101\n102\n'
			return 0
		fi
		if [[ "$1" == "issue" && "$2" == "view" ]]; then
			printf 'auto-dispatch\nstatus:queued\n'
			return 0
		fi
		if [[ "${GH_STUB_FAIL_EDIT:-0}" == "1" && "$1" == "issue" && "$2" == "edit" ]]; then
			return 7
		fi
		return 0
	}
	return 0
}

test_clear_terminal_labels_removes_dispatch_labels() {
	setup_env
	install_gh_stub
	# shellcheck source=../shared-dispatch-label-cleanup.sh
	source "$HELPER"
	clear_terminal_issue_dispatch_labels 42 owner/repo test-context
	local log_line
	log_line=$(tr '\n' ' ' <"${TEST_ROOT}/gh.log")
	if [[ "$log_line" == *"issue view 42 --repo owner/repo"* \
		&& "$log_line" == *"issue edit 42 --repo owner/repo"* \
		&& "$log_line" == *"--remove-label auto-dispatch"* \
		&& "$log_line" == *"--remove-label status:queued"* \
		&& "$log_line" != *"--remove-label status:in-review"* ]]; then
		print_result "terminal label cleanup strips only labels currently present" 0
	else
		print_result "terminal label cleanup strips only labels currently present" 1
	fi
	teardown_env
	return 0
}

test_clear_terminal_labels_propagates_edit_failure() {
	setup_env
	install_gh_stub
	export GH_STUB_FAIL_EDIT=1
	# shellcheck source=../shared-dispatch-label-cleanup.sh
	source "$HELPER"
	local exit_code=0
	clear_terminal_issue_dispatch_labels 42 owner/repo test-context || exit_code=$?
	unset GH_STUB_FAIL_EDIT
	if [[ "$exit_code" == "7" ]]; then
		print_result "terminal label cleanup propagates edit failure" 0
	else
		print_result "terminal label cleanup propagates edit failure" 1
	fi
	teardown_env
	return 0
}

test_sweep_closed_auto_dispatch_issues_scopes_to_pulse_repos() {
	setup_env
	install_gh_stub
	# shellcheck source=../shared-dispatch-label-cleanup.sh
	source "$HELPER"
	sweep_closed_auto_dispatch_issues
	local edit_count list_count
	edit_count=$(grep -c 'issue edit' "${TEST_ROOT}/gh.log" || true)
	list_count=$(grep -c 'issue list' "${TEST_ROOT}/gh.log" || true)
	if [[ "$edit_count" == "2" && "$list_count" == "1" ]]; then
		print_result "closed auto-dispatch sweep strips bounded pulse repo issues" 0
	else
		print_result "closed auto-dispatch sweep strips bounded pulse repo issues" 1
	fi
	teardown_env
	return 0
}

test_clear_terminal_labels_removes_dispatch_labels
test_clear_terminal_labels_propagates_edit_failure
test_sweep_closed_auto_dispatch_issues_scopes_to_pulse_repos

printf 'Tests run: %s\n' "$TESTS_RUN"
printf 'Tests failed: %s\n' "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
