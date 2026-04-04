#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SCRIPT="${SCRIPT_DIR}/../dispatch-dedup-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""
GH_FIXTURE_FILE=""

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
	GH_FIXTURE_FILE="${TEST_ROOT}/gh-pr-list-fixtures.txt"

	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export GH_FIXTURE_FILE

	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
	local_repo=""
	local_state=""
	local_search=""
	shift 2

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			local_repo="${2:-}"
			shift 2
			;;
		--state)
			local_state="${2:-}"
			shift 2
			;;
		--search)
			local_search="${2:-}"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$local_repo" || -z "$local_state" || -z "$local_search" ]]; then
		printf '[]\n'
		exit 0
	fi

	compound_key="${local_repo}|${local_state}|${local_search}"
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		fixture_key="${line%|*}"
		fixture_payload="${line##*|}"
		if [[ "$fixture_key" == "$compound_key" ]]; then
			printf '%s\n' "$fixture_payload"
			exit 0
		fi
	done <"${GH_FIXTURE_FILE}"

	printf '[]\n'
	exit 0
fi

printf 'unsupported gh invocation in test stub\n' >&2
exit 1
EOF

	chmod +x "${TEST_ROOT}/bin/gh"
	printf '' >"${GH_FIXTURE_FILE}"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

set_gh_fixtures() {
	local fixtures="$1"
	printf '%s\n' "$fixtures" >"${GH_FIXTURE_FILE}"
	return 0
}

test_has_open_pr_detects_closing_keyword() {
	set_gh_fixtures 'marcusquinn/aidevops|merged|closes #4527 in:body|[{"number":1145}]'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 4527 marcusquinn/aidevops 't4527: prevent duplicate dispatch'); then
		case "$output" in
		*'merged PR #1145 references issue #4527 via "closes" keyword'*)
			print_result "has-open-pr detects merged PR via closing keyword" 0
			return 0
			;;
		esac
		print_result "has-open-pr detects merged PR via closing keyword" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "has-open-pr detects merged PR via closing keyword" 1 "Expected merged PR evidence for issue #4527"
	return 0
}

test_has_open_pr_detects_task_id_fallback() {
	set_gh_fixtures 'marcusquinn/aidevops|merged|t063.1 in:title|[{"number":1059}]'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 9999 marcusquinn/aidevops 't063.1: fix awardsapp duplicate PR dispatch'); then
		case "$output" in
		*'merged PR #1059 found by task id t063.1 in title'*)
			print_result "has-open-pr detects merged PR via task-id fallback" 0
			return 0
			;;
		esac
		print_result "has-open-pr detects merged PR via task-id fallback" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "has-open-pr detects merged PR via task-id fallback" 1 "Expected merged PR evidence via task-id fallback"
	return 0
}

test_has_open_pr_returns_nonzero_without_match() {
	set_gh_fixtures ''

	if "$HELPER_SCRIPT" has-open-pr 7777 marcusquinn/aidevops 't7777: no merged pr yet'; then
		print_result "has-open-pr returns nonzero when no evidence exists" 1 "Expected nonzero exit when no merged PR evidence exists"
		return 0
	fi

	print_result "has-open-pr returns nonzero when no evidence exists" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	test_has_open_pr_detects_closing_keyword
	test_has_open_pr_detects_task_id_fallback
	test_has_open_pr_returns_nonzero_without_match

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
