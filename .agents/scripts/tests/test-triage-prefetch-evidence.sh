#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# t2886: Unit tests for evidence-verification prefetch sections added to
# pulse-ancillary-dispatch.sh (_triage_fetch_evidence_sections +
# the three new sections in _triage_write_prompt_file).
#
# What this guards:
#   - _triage_fetch_evidence_sections populates merged-PRs variable from
#     mocked gh pr list output.
#   - _triage_fetch_evidence_sections populates recent-commits variable
#     from mocked git log output.
#   - _triage_fetch_evidence_sections populates file-contents variable
#     from a fixture file at the cited line (±5-line window).
#   - _triage_write_prompt_file includes all three
#     <!-- prefetch:section=NAME --> markers in the output file.
#   - Empty repo_path is handled gracefully (fallback messages used).
#
# Harness style: mocked gh/git, isolated HOME, fixture files.
# Pattern from test-triage-output-shape.sh.

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"
LOGFILE=""

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
	LOGFILE="${HOME}/.aidevops/logs/pulse-wrapper.log"
	: >"$LOGFILE"
	return 0
}

teardown_test_env() {
	export HOME="${ORIGINAL_HOME}"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Load _triage_fetch_evidence_sections and _triage_write_prompt_file from
# the production file using awk extraction — same pattern as
# test-triage-output-shape.sh.
load_evidence_helpers() {
	local src
	local here
	here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	src="${AIDEVOPS_SOURCE:-${here}/../pulse-ancillary-dispatch.sh}"
	if [[ ! -f "$src" ]]; then
		printf 'ERROR: cannot locate pulse-ancillary-dispatch.sh (tried %s)\n' \
			"$src" >&2
		exit 2
	fi
	# Extract from _triage_fetch_evidence_sections through the end of
	# _triage_write_prompt_file, stopping before _build_triage_review_prompt.
	local tmp
	tmp=$(mktemp)
	awk '
	/^_triage_fetch_evidence_sections\(\) \{/{flag=1}
	flag{print}
	/^_build_triage_review_prompt\(\) \{/{flag=0}
	' "$src" |
		sed '/^_build_triage_review_prompt()/,$d' >"$tmp"
	# shellcheck disable=SC1090
	source "$tmp"
	rm -f "$tmp"
	return 0
}

# Stub gh_issue_list so _triage_write_prompt_file can fetch recent_closed
# without real network access.
# shellcheck disable=SC2317
gh_issue_list() { printf 'Stub closed issue 1\nStub closed issue 2\n'; return 0; }
export -f gh_issue_list

# ------------------------------ Tests ------------------------------

test_fetch_evidence_populates_merged_prs() {
	setup_test_env

	# Mock gh to return one merged PR matching the keyword search.
	gh() {
		case "${1:-}" in
		pr)
			case "${2:-}" in
			list)
				printf '#9001 fix: correct line count (merged: 2026-04-20T10:00:00Z)\n'
				return 0
				;;
			esac
			;;
		esac
		return 0
	}
	export -f gh

	# Mock git (not needed for this test but export to avoid command-not-found)
	git() { return 0; }
	export -f git

	load_evidence_helpers

	local issue_json
	issue_json='{"title":"fix line count logic","createdAt":"2026-04-01T00:00:00Z"}'
	local issue_body="See scripts/foo.sh:42 for the problem."

	local merged_prs="" recent_commits="" file_contents=""
	_triage_fetch_evidence_sections \
		"$issue_body" "$issue_json" "owner/repo" "" \
		"merged_prs" "recent_commits" "file_contents"

	if [[ "$merged_prs" == *"#9001"* && "$merged_prs" == *"fix: correct line count"* ]]; then
		print_result \
			"_triage_fetch_evidence_sections populates merged-PRs from gh output" 0
	else
		print_result \
			"_triage_fetch_evidence_sections populates merged-PRs from gh output" 1 \
			"merged_prs='$merged_prs'"
	fi
	teardown_test_env
}

test_fetch_evidence_populates_recent_commits() {
	setup_test_env

	gh() { return 0; }
	export -f gh

	# Create a fake repo directory with the fixture file
	local fake_repo="${TEST_ROOT}/repo"
	mkdir -p "${fake_repo}/scripts"
	printf 'line1\nline2\nline3\nline4\nline5\nline6\nline7\n' \
		>"${fake_repo}/scripts/foo.sh"

	# Mock git to return a recent commit for the cited file when called
	# as: git -C <repo_path> log --since=... --oneline -- <file>
	git() {
		case "${1:-}" in
		-C)
			shift  # -C
			shift  # <repo_path>
			if [[ "${1:-}" == "log" ]]; then
				printf 'abc1234 fix: update foo.sh logic\n'
				return 0
			fi
			;;
		esac
		return 0
	}
	export -f git

	load_evidence_helpers

	local issue_json
	issue_json='{"title":"update foo logic","createdAt":"2026-04-01T00:00:00Z"}'
	local issue_body="Issue at scripts/foo.sh:5"

	local merged_prs="" recent_commits="" file_contents=""
	_triage_fetch_evidence_sections \
		"$issue_body" "$issue_json" "owner/repo" "$fake_repo" \
		"merged_prs" "recent_commits" "file_contents"

	if [[ "$recent_commits" == *"abc1234"* ]]; then
		print_result \
			"_triage_fetch_evidence_sections populates recent-commits from git log" 0
	else
		print_result \
			"_triage_fetch_evidence_sections populates recent-commits from git log" 1 \
			"recent_commits='$recent_commits'"
	fi
	teardown_test_env
}

test_fetch_evidence_populates_file_contents() {
	setup_test_env

	gh() { return 0; }
	git() { return 0; }
	export -f gh git

	# Create a fake repo with a fixture file containing known content at
	# line 5 ("epsilon") for verification
	local fake_repo="${TEST_ROOT}/repo"
	mkdir -p "${fake_repo}/scripts"
	printf 'alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\niota\nkappa\n' \
		>"${fake_repo}/scripts/fixture.sh"

	load_evidence_helpers

	local issue_json
	issue_json='{"title":"check fixture content","createdAt":"2026-04-01T00:00:00Z"}'
	local issue_body="Problem at scripts/fixture.sh:5"

	local merged_prs="" recent_commits="" file_contents=""
	_triage_fetch_evidence_sections \
		"$issue_body" "$issue_json" "owner/repo" "$fake_repo" \
		"merged_prs" "recent_commits" "file_contents"

	# Line 5 is "epsilon"; the ±5 window (lines 1-10) should include it.
	if [[ "$file_contents" == *"epsilon"* && \
		"$file_contents" == *"scripts/fixture.sh"* ]]; then
		print_result \
			"_triage_fetch_evidence_sections populates file-contents from fixture" 0
	else
		print_result \
			"_triage_fetch_evidence_sections populates file-contents from fixture" 1 \
			"file_contents='$file_contents'"
	fi
	teardown_test_env
}

test_prompt_file_contains_prefetch_markers() {
	setup_test_env

	# Stub all external calls needed by _triage_write_prompt_file
	gh() { return 0; }
	git() { return 0; }
	export -f gh git

	load_evidence_helpers

	local issue_json
	issue_json='{"title":"test markers","createdAt":"2026-04-01T00:00:00Z","number":1}'
	local issue_body="Test issue body with no file refs."

	local prompt_file
	prompt_file=$(_triage_write_prompt_file \
		"1" "owner/repo" "" "$issue_json" "$issue_body" "[]" "" "[]" "")

	local ok=0
	grep -q '<!-- prefetch:section=recent-merged-prs -->' \
		"$prompt_file" || ok=1
	grep -q '<!-- prefetch:section=recent-commits-on-cited-files -->' \
		"$prompt_file" || ok=1
	grep -q '<!-- prefetch:section=cited-file-contents -->' \
		"$prompt_file" || ok=1

	rm -f "$prompt_file"

	if [[ "$ok" -eq 0 ]]; then
		print_result \
			"_triage_write_prompt_file includes all three prefetch section markers" 0
	else
		print_result \
			"_triage_write_prompt_file includes all three prefetch section markers" 1 \
			"one or more <!-- prefetch:section=NAME --> markers missing from prompt file"
	fi
	teardown_test_env
}

test_fetch_evidence_no_repo_path_graceful() {
	setup_test_env

	gh() { return 0; }
	export -f gh

	load_evidence_helpers

	local issue_json
	issue_json='{"title":"no repo path test","createdAt":"2026-04-01T00:00:00Z"}'
	local issue_body="See scripts/foo.sh:10 for details."

	local merged_prs="" recent_commits="" file_contents=""
	# repo_path is empty — git and file operations must be skipped gracefully
	_triage_fetch_evidence_sections \
		"$issue_body" "$issue_json" "owner/repo" "" \
		"merged_prs" "recent_commits" "file_contents"

	if [[ "$recent_commits" == *"No recent commits"* && \
		"$file_contents" == *"not available locally"* ]]; then
		print_result \
			"_triage_fetch_evidence_sections handles empty repo_path gracefully" 0
	else
		print_result \
			"_triage_fetch_evidence_sections handles empty repo_path gracefully" 1 \
			"recent_commits='$recent_commits' file_contents='$file_contents'"
	fi
	teardown_test_env
}

# ------------------------------ Main ------------------------------

main() {
	test_fetch_evidence_populates_merged_prs
	test_fetch_evidence_populates_recent_commits
	test_fetch_evidence_populates_file_contents
	test_prompt_file_contains_prefetch_markers
	test_fetch_evidence_no_repo_path_graceful

	echo ""
	echo "Results: ${TESTS_RUN} tests, $((TESTS_RUN - TESTS_FAILED)) passed, ${TESTS_FAILED} failed"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
