#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2016

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../quality-feedback-helper.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

GH_RAW_CONTENT=""
GH_DIFF=""
GH_SUGGESTION=""
GH_DELETED=""
GH_LAST_CONTENT_ENDPOINT=""
GH_ISSUE_CREATE_COUNT=0
GH_CREATE_LOG=""
GH_API_LOG=""

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
	GH_DIFF=""
	GH_SUGGESTION=""
	GH_DELETED=""
	GH_LAST_CONTENT_ENDPOINT=""
	GH_ISSUE_CREATE_COUNT=0
	GH_CREATE_LOG=$(mktemp)
	GH_API_LOG=$(mktemp)
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
		GH_LAST_CONTENT_ENDPOINT="$endpoint"
		[[ -n "$GH_API_LOG" ]] && printf '%s\n' "$endpoint" >>"$GH_API_LOG"

		if [[ "$GH_DELETED" == "1" ]]; then
			# Simulate a 404 — write "404" to stderr so the caller can detect it
			echo "404 Not Found" >&2
			return 1
		fi

		if [[ "$GH_DELETED" == "transient" ]]; then
			# Simulate a transient API error (non-404) — no "404" in stderr
			echo "500 Internal Server Error" >&2
			return 1
		fi

		if [[ "$endpoint" == *"diff"* && -n "$GH_DIFF" ]]; then
			printf '%s' "$GH_DIFF"
			return 0
		fi

		if [[ "$endpoint" == *"suggestion"* && -n "$GH_SUGGESTION" ]]; then
			printf '%s' "$GH_SUGGESTION"
			return 0
		fi

		if [[ -n "$GH_RAW_CONTENT" ]]; then
			printf '%s' "$GH_RAW_CONTENT"
			return 0
		fi

		if [[ -n "$GH_DIFF" ]]; then
			printf '%s' "$GH_DIFF"
			return 0
		fi

		if [[ -n "$GH_SUGGESTION" ]]; then
			printf '%s' "$GH_SUGGESTION"
			return 0
		fi

		return 1
	fi

	if [[ "$endpoint" == repos/*/pulls/*/files ]]; then
		if [[ -n "$GH_DIFF" ]]; then
			printf '%s' "$GH_DIFF"
			return 0
		fi

		if [[ -n "$GH_SUGGESTION" ]]; then
			printf '%s' "$GH_SUGGESTION"
			return 0
		fi

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
	GH_RAW_CONTENT=$'#!/usr/bin/env bash\nverification marker present\nreturn 0\n'

	local findings
	findings='[{"file":".agents/scripts/example.sh","line":42,"body_full":"```bash\nverification marker missing\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"
	rm -f "$GH_API_LOG"

	if [[ "$created" == "0" && "$created_count" -eq 0 ]]; then
		print_result "skip resolved finding when snippet not on main" 0
	else
		print_result "skip resolved finding when snippet not on main" 1 "created=${created}, issues=${created_count}"
	fi
	return 0
}

test_creates_issue_when_snippet_still_exists() {
	reset_mock_state
	GH_RAW_CONTENT=$'#!/usr/bin/env bash\nverification marker present\nreturn 1\n'

	local findings
	findings='[{"file":".agents/scripts/example.sh","line":42,"body_full":"```bash\nverification marker present\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"
	rm -f "$GH_API_LOG"

	if [[ "$created" == "1" && "$created_count" -eq 1 ]]; then
		print_result "create issue when finding snippet exists on main" 0
	else
		print_result "create issue when finding snippet exists on main" 1 "created=${created}, issues=${created_count}"
	fi
	return 0
}

test_skips_deleted_file() {
	reset_mock_state
	GH_DELETED="1"

	local findings
	findings='[{"file":".agents/scripts/deleted.sh","line":42,"body_full":"```bash\nreturn 1\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"
	rm -f "$GH_API_LOG"

	if [[ "$created" == "0" && "$created_count" -eq 0 ]]; then
		print_result "skip finding when file deleted on main" 0
	else
		print_result "skip finding when file deleted on main" 1 "created=${created}, issues=${created_count}"
	fi
	return 0
}

test_handles_diff_fence_without_false_positive() {
	reset_mock_state
	GH_DIFF=$'#!/usr/bin/env bash\ncontext stable verification marker\nreturn 0\n'

	local findings
	findings='[{"file":".agents/scripts/diff-example.sh","line":2,"body_full":"```diff\n- return 1\n+ return 2\n context stable verification marker\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"
	rm -f "$GH_API_LOG"

	if [[ "$created" == "1" && "$created_count" -eq 1 ]]; then
		print_result "diff fences verify using substantive context line" 0
	else
		print_result "diff fences verify using substantive context line" 1 "created=${created}, issues=${created_count}"
	fi
	return 0
}

test_handles_suggestion_fence_and_comments() {
	reset_mock_state
	GH_SUGGESTION=$'#!/usr/bin/env bash\nthis is stable suggestion code\n'

	local findings
	findings='[{"file":".agents/scripts/suggestion-example.sh","line":2,"body_full":"```suggestion\n// reviewer note\n# inline comment\nthis is stable suggestion code\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"
	rm -f "$GH_API_LOG"

	if [[ "$created" == "1" && "$created_count" -eq 1 ]]; then
		print_result "suggestion fences skip comments and keep code" 0
	else
		print_result "suggestion fences skip comments and keep code" 1 "created=${created}, issues=${created_count}"
	fi
	return 0
}

test_keeps_unverifiable_finding() {
	reset_mock_state
	GH_RAW_CONTENT=$'#!/usr/bin/env bash\nreturn 0\n'

	local findings
	findings='[{"file":".agents/scripts/example.sh","line":2,"body_full":"tiny\n- short\n> mini","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"
	rm -f "$GH_API_LOG"

	if [[ "$created" == "1" && "$created_count" -eq 1 ]]; then
		print_result "keep unverifiable findings for manual review" 0
	else
		print_result "keep unverifiable findings for manual review" 1 "created=${created}, issues=${created_count}"
	fi
	return 0
}

test_transient_api_error_keeps_finding_as_unverifiable() {
	reset_mock_state
	GH_DELETED="transient"

	local findings
	findings='[{"file":".agents/scripts/example.sh","line":42,"body_full":"```bash\nsome code snippet here\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"
	rm -f "$GH_API_LOG"

	# Transient API error should keep finding as unverifiable → issue created
	if [[ "$created" == "1" && "$created_count" -eq 1 ]]; then
		print_result "transient API error keeps finding as unverifiable" 0
	else
		print_result "transient API error keeps finding as unverifiable" 1 "created=${created}, issues=${created_count}"
	fi
	return 0
}

test_uses_default_branch_ref_for_contents_lookup() {
	reset_mock_state
	GH_RAW_CONTENT=$'#!/usr/bin/env bash\nverification marker present\nreturn 0\n'

	local findings
	findings='[{"file":".agents/scripts/ref-check.sh","line":2,"body_full":"```bash\nverification marker present\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	rm -f "$out_file"

	rm -f "$GH_CREATE_LOG"

	if [[ -f "$GH_API_LOG" ]] && grep -Fq '?ref=main' "$GH_API_LOG"; then
		print_result "contents lookup uses default-branch ref" 0
	else
		print_result "contents lookup uses default-branch ref" 1 "endpoint=${GH_LAST_CONTENT_ENDPOINT}"
	fi
	rm -f "$GH_API_LOG"
	return 0
}

test_plain_fence_skips_diff_marker_lines() {
	# Regression: a plain ```bash fence whose first line starts with '+' or '-'
	# must NOT strip the marker and use the remainder as a snippet.  The old code
	# did `candidate="${candidate:1}"` which turned "+ new code" into "new code"
	# and then matched it against the file, producing a false "verified" result.
	# The fix skips +/- lines in non-diff fences entirely, so the snippet falls
	# through to the fallback extractor (or returns unverifiable if nothing else
	# matches), preventing the false positive.
	reset_mock_state
	# File contains "new code" — the stripped version of "+ new code"
	GH_RAW_CONTENT=$'#!/usr/bin/env bash\nnew code\nreturn 0\n'

	local findings
	# Body has a plain bash fence whose only substantive line is "+ new code".
	# With the old strip logic this would extract "new code", find it in the file,
	# and mark the finding verified.  With the fix it skips the +/- line and falls
	# through to unverifiable (no other qualifying line), so the issue is still
	# created (unverifiable → kept), but the snippet is NOT "new code".
	findings='[{"file":".agents/scripts/example.sh","line":2,"body_full":"```bash\n+ new code\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"
	rm -f "$GH_API_LOG"

	# Finding must be kept (unverifiable — no snippet extracted from +/- only fence)
	# rather than falsely resolved by matching the stripped "new code" in the file.
	if [[ "$created" == "1" && "$created_count" -eq 1 ]]; then
		print_result "plain fence skips +/- lines instead of stripping prefix" 0
	else
		print_result "plain fence skips +/- lines instead of stripping prefix" 1 "created=${created}, issues=${created_count}"
	fi
	return 0
}

main() {
	source "$HELPER"

	echo "Running quality-feedback main-branch verification tests"
	test_skips_resolved_finding_when_snippet_missing
	test_creates_issue_when_snippet_still_exists
	test_skips_deleted_file
	test_handles_diff_fence_without_false_positive
	test_handles_suggestion_fence_and_comments
	test_keeps_unverifiable_finding
	test_transient_api_error_keeps_finding_as_unverifiable
	test_uses_default_branch_ref_for_contents_lookup
	test_plain_fence_skips_diff_marker_lines

	echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
