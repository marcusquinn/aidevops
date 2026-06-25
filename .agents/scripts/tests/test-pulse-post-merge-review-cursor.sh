#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

PASS=0
FAIL=0

assert_contains() {
	local test_name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		printf 'PASS %s\n' "$test_name"
		PASS=$((PASS + 1))
		return 0
	fi
	printf 'FAIL %s\n  expected: %s\n  actual: %s\n' "$test_name" "$needle" "$haystack"
	FAIL=$((FAIL + 1))
	return 0
}

TEST_ROOT=$(mktemp -d -t pulse-post-merge-cursor.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

REAL_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PULSE_REVIEW_SCRIPT="${REAL_SCRIPTS_DIR}/pulse-simplification-review.sh"

get_repo_role_by_slug() {
	local slug="$1"
	printf 'maintainer\n'
	return 0
}

_pulse_enabled_repo_slugs() {
	local repos_json="$1"
	printf 'enabled/repo\n'
	return 0
}

# shellcheck source=../pulse-simplification-review.sh
# shellcheck disable=SC1091
source "$PULSE_REVIEW_SCRIPT"

test_home_unset_does_not_abort() {
	local stub_scripts_dir="${TEST_ROOT}/home-unset-scripts"
	mkdir -p "$stub_scripts_dir"
	SCRIPT_DIR="$stub_scripts_dir"
	LOGFILE="${TEST_ROOT}/home-unset.log"
	POST_MERGE_SCANNER_LAST_RUN="${TEST_ROOT}/home-unset.last"
	POST_MERGE_SCANNER_INTERVAL=0
	REPOS_JSON="${TEST_ROOT}/home-unset-repos.json"
	printf '{}\n' >"$REPOS_JSON"
	unset HOME

	_run_post_merge_review_scanner
	printf 'PASS HOME unset does not abort post-merge scanner setup\n'
	PASS=$((PASS + 1))
	return 0
}

test_stale_repo_cursor_resets_to_enabled_repos() {
	local stub_scripts_dir="${TEST_ROOT}/scripts"
	local cursor_dir="${TEST_ROOT}/cursor"
	local log_file="${TEST_ROOT}/scanner.log"
	mkdir -p "$stub_scripts_dir" "$cursor_dir"
	cat >"${stub_scripts_dir}/post-merge-review-scanner.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'STUB scan %s\n' "${2:-}" >>"${LOGFILE:?}"
STUB
	chmod +x "${stub_scripts_dir}/post-merge-review-scanner.sh"
	printf 'removed/repo\n' >"${cursor_dir}/repo.cursor"
	printf '{}\n' >"${TEST_ROOT}/repos.json"

	SCRIPT_DIR="$stub_scripts_dir"
	LOGFILE="$log_file"
	export LOGFILE
	POST_MERGE_SCANNER_LAST_RUN="${TEST_ROOT}/last-run"
	POST_MERGE_SCANNER_INTERVAL=0
	REPOS_JSON="${TEST_ROOT}/repos.json"
	AIDEVOPS_POST_MERGE_SCANNER_CURSOR_DIR="$cursor_dir"
	AIDEVOPS_POST_MERGE_SCANNER_STAGE_BUDGET_SECONDS=60
	AIDEVOPS_POST_MERGE_SCANNER_STAGE_RESERVE_SECONDS=1

	_run_post_merge_review_scanner
	local output=""
	output=$(<"$log_file")
	assert_contains "stale cursor is logged" "resume cursor repo removed/repo is no longer enabled" "$output"
	assert_contains "enabled repo still scans after stale cursor" "STUB scan enabled/repo" "$output"
	return 0
}

test_home_unset_does_not_abort
test_stale_repo_cursor_resets_to_enabled_repos

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
