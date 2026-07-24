#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d)"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message" >&2
	return 1
}

_prefetch_open_issues_only() {
	jq -c '[.[] | select((.state // "open") == "open")]'
	return 0
}

_filter_non_task_issues() {
	jq -c '.'
	return 0
}

_prefetch_prs_enrich_checks() {
	printf '[]\n'
	return 0
}

main() {
	local cache_entry='{"last_prefetch":"2026-07-18T10:00:00Z","prs":[{"number":9,"title":"C:\temp","updatedAt":"2026-07-18T09:00:00Z"}],"issues":[]}'
	local output_file="$TEST_ROOT/output.txt"
	local stderr_file="$TEST_ROOT/stderr.txt"
	local xpg_echo_was_set=false
	local LOGFILE="$TEST_ROOT/pulse.log"
	local _PULSE_HEALTH_IDLE_REPO_SKIPS=0

	# shellcheck source=../pulse-prefetch-repo.sh
	source "$SCRIPTS_DIR/pulse-prefetch-repo.sh"

	if shopt -q xpg_echo; then
		xpg_echo_was_set=true
	fi
	shopt -s xpg_echo
	_prefetch_single_repo_idle_skip owner/repo "$cache_entry" "" "" >"$output_file" 2>"$stderr_file" ||
		fail "valid idle-skip JSON could not be rendered"
	if [[ "$xpg_echo_was_set" == false ]]; then
		shopt -u xpg_echo
	fi
	grep -q 'PR #9' "$output_file" || fail "idle-skip JSON changed under xpg_echo semantics"
	[[ ! -s "$stderr_file" ]] || fail "valid idle-skip JSON produced jq errors"

	_prefetch_single_repo_idle_skip owner/repo "" "" "" >"$output_file" 2>"$stderr_file" ||
		fail "empty idle-skip input could not be rendered"
	grep -q 'Open PRs (0)' "$output_file" || fail "empty PR input did not become an empty array"
	grep -q 'Open Issues (0)' "$output_file" || fail "empty issue input did not become an empty array"
	[[ ! -s "$stderr_file" ]] || fail "empty idle-skip input produced jq errors"

	_prefetch_single_repo_idle_skip owner/repo '{malformed' "" "" >"$output_file" 2>"$stderr_file" ||
		fail "malformed cache fallback could not be rendered"
	grep -q 'Open PRs (0)' "$output_file" || fail "malformed cache did not fall back safely"
	[[ -s "$stderr_file" ]] || fail "malformed non-empty JSON error was suppressed"

	printf 'PASS idle-skip JSON uses printf, handles empty input, and exposes malformed input\n'
	return 0
}

trap cleanup EXIT
main "$@"
