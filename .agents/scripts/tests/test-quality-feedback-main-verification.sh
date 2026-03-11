#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2016

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../quality-feedback-helper.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

GH_RAW_CONTENT=""
GH_ISSUE_CREATE_COUNT=0
GH_CREATE_LOG=""

print_result() {
	local test_name="$1"
	local result="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$result" -eq 0 ]]; then
		echo "PASS $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $test_name"
		[[ -n "$message" ]] && echo "  $message"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

reset_mock_state() {
	GH_RAW_CONTENT=""
	GH_ISSUE_CREATE_COUNT=0
	GH_CREATE_LOG=$(mktemp)
	_QF_DEFAULT_BRANCH=""
	_QF_DEFAULT_BRANCH_REPO=""
	return 0
}

gh() {
	local command="$1"
	shift

	case "$command" in
	api)
		_mock_gh_api "$@"
		return $?
		;;
	label)
		return 0
		;;
	issue)
		_mock_gh_issue "$@"
		return $?
		;;
	esac

	echo "unexpected gh call: ${command}" >&2
	return 1
}

_mock_gh_api() {
	local endpoint=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		-H | --jq)
			shift 2
			;;
		repos/*)
			endpoint="$1"
			shift
			;;
		*)
			shift
			;;
		esac
	done

	if [[ "$endpoint" == repos/*/contents/* ]]; then
		[[ -n "$GH_RAW_CONTENT" ]] || return 1
		printf '%s' "$GH_RAW_CONTENT"
		return 0
	fi

	if [[ "$endpoint" == repos/* ]]; then
		echo "main"
		return 0
	fi

	echo "[]"
	return 0
}

_mock_gh_issue() {
	local subcommand="$1"
	shift

	case "$subcommand" in
	list)
		echo "[]"
		return 0
		;;
	create)
		GH_ISSUE_CREATE_COUNT=$((GH_ISSUE_CREATE_COUNT + 1))
		if [[ -n "$GH_CREATE_LOG" ]]; then
			echo "create" >>"$GH_CREATE_LOG"
		fi
		echo "https://github.com/example/repo/issues/999"
		return 0
		;;
	comment | edit)
		return 0
		;;
	esac

	return 1
}

test_skips_resolved_finding_when_snippet_missing() {
	reset_mock_state
	GH_RAW_CONTENT=$'#!/usr/bin/env bash\nreturn 0\n'

	local findings
	findings='[{"file":".agents/scripts/example.sh","line":42,"body_full":"```bash\nreturn 1\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"

	if [[ "$created" == "0" && "$created_count" -eq 0 ]]; then
		print_result "skip resolved finding when snippet not on main" 0
	else
		print_result "skip resolved finding when snippet not on main" 1 "created=${created}, issues=${created_count}"
	fi
	return 0
}

test_creates_issue_when_snippet_still_exists() {
	reset_mock_state
	GH_RAW_CONTENT=$'#!/usr/bin/env bash\nreturn 1\n'

	local findings
	findings='[{"file":".agents/scripts/example.sh","line":42,"body_full":"```bash\nreturn 1\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"

	if [[ "$created" == "1" && "$created_count" -eq 1 ]]; then
		print_result "create issue when finding snippet exists on main" 0
	else
		print_result "create issue when finding snippet exists on main" 1 "created=${created}, issues=${created_count}"
	fi
	return 0
}

main() {
	source "$HELPER"

	echo "Running quality-feedback main-branch verification tests"
	test_skips_resolved_finding_when_snippet_missing
	test_creates_issue_when_snippet_still_exists

	echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
