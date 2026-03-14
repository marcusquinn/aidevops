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
		local token="$1"
		case "$1" in
		-H | --jq)
			shift 2
			;;
		repos/*)
			endpoint="$token"
			shift
			;;
		*)
			shift
			;;
		esac
	done

	# contents/* — file fetch used by _finding_still_exists_on_main
	# Route purely by env-var flags, not by endpoint URL, so tests are not
	# accidentally coupled to filenames that happen to contain "diff" or
	# "suggestion".  Priority: GH_DELETED > GH_RAW_CONTENT > GH_DIFF > GH_SUGGESTION
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

	# repos/* (no sub-path) — default-branch lookup
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
	# The finding body contains a ```diff fence.  The snippet extractor must
	# skip the +/- lines and extract the context line ("context stable
	# verification marker").  The file on main (GH_RAW_CONTENT) contains that
	# context line, so the finding is verified and an issue is created.
	# GH_RAW_CONTENT is used for the file payload; the diff fence is only in
	# body_full and does not affect which env var the mock returns.
	reset_mock_state
	GH_RAW_CONTENT=$'#!/usr/bin/env bash\ncontext stable verification marker\nreturn 0\n'

	local findings
	findings='[{"file":".agents/scripts/example.sh","line":2,"body_full":"```diff\n- return 1\n+ return 2\n context stable verification marker\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

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
	# The finding body contains a ```suggestion fence with comment lines.
	# The snippet extractor must skip comment-only lines (// and #) and extract
	# the first substantive code line ("this is stable suggestion code").
	# The file on main (GH_RAW_CONTENT) contains that line, so the finding is
	# verified and an issue is created.
	reset_mock_state
	GH_RAW_CONTENT=$'#!/usr/bin/env bash\nthis is stable suggestion code\n'

	local findings
	findings='[{"file":".agents/scripts/example.sh","line":2,"body_full":"```suggestion\n// reviewer note\n# inline comment\nthis is stable suggestion code\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

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

# Helper: run the approval-detection jq filter against a review body.
# Returns "skip" if the review would be skipped, "keep" if it would be kept.
# Mirrors the $approval_only + $actionable logic in _scan_single_pr.
_test_approval_filter() {
	local body="$1"
	local state="${2:-COMMENTED}"
	local reviewer="${3:-coderabbit}"

	# Replicate the jq filter from _scan_single_pr review_findings block
	local result
	result=$(jq -rn \
		--arg body "$body" \
		--arg state "$state" \
		--arg reviewer "$reviewer" '
		($body | test(
			"^[\\s\\n]*(lgtm|looks good( to me)?|ship it|shipit|:shipit:|:\\+1:|👍|" +
			"approved?|great (work|job|change|pr|patch)|nice (work|job|change|pr|patch)|" +
			"good (work|job|change|pr|patch|catch|call|stuff)|well done|" +
			"no (further |more )?(comments?|issues?|concerns?|feedback|changes? (needed|required))|" +
			"nothing (further|else|more) (to (add|comment|say|note))?|" +
			"(all |everything )?(looks?|seems?) (good|fine|correct|great|solid|clean)|" +
			"(this |the )?(pr|patch|change|diff|code) (looks?|seems?) (good|fine|correct|great|solid|clean)|" +
			"(i have )?no (objections?|issues?|concerns?|comments?)|" +
			"(thanks?|thank you)[,.]?\\s*(for the (pr|patch|fix|change|contribution))?[.!]?)[\\s\\n]*$"; "i")) as $approval_only |

		($body | test(
			"\\bno (further )?recommendations?\\b|" +
			"\\bno additional recommendations?\\b|" +
			"\\bnothing (further|more) to recommend\\b"; "i")) as $no_actionable_recommendation |

		($body | test(
			"\\bno suggestions? (at this time|for now|currently)?\\b|" +
			"\\bwithout suggestions?\\b|" +
			"\\bhas no suggestions?\\b"; "i")) as $no_actionable_suggestion |

		($body | test(
			"\\blgtm\\b|\\blooks good( to me)?\\b|\\bgood work\\b|" +
			"\\bno (further |more )?(comments?|issues?|concerns?|feedback)\\b|" +
			"\\beverything (looks?|seems?) (good|fine|correct|great|solid|clean)\\b"; "i")) as $no_actionable_sentiment |

		($body | test(
			"\\bsuccessfully addresses?\\b|\\beffectively\\b|\\bimproves?\\b|\\benhances?\\b|" +
			"\\bconsistent\\b|\\brobust(ness)?\\b|\\buser experience\\b|" +
			"\\breduces? (external )?requirements?\\b|\\bwell-implemented\\b"; "i")) as $summary_praise_only |

		($body | test(
			"\\bshould\\b|\\bconsider\\b|\\binstead\\b|\\bsuggest|\\brecommend(ed|ing)?\\b|" +
			"\\bwarning\\b|\\bcaution\\b|\\bavoid\\b|\\b(don ?'"'"'?t|do not)\\b|" +
			"\\bvulnerab|\\binsecure|\\binjection\\b|\\bxss\\b|\\bcsrf\\b|" +
			"\\bbug\\b|\\berror\\b|\\bproblem\\b|\\bfail\\b|\\bincorrect\\b|\\bwrong\\b|\\bmissing\\b|\\bbroken\\b|" +
			"\\bnit:|\\btodo:|\\bfixme|\\bhardcoded|\\bdeprecated|" +
			"\\brace.condition|\\bdeadlock|\\bleak|\\boverflow|" +
			"\\bworkaround\\b|\\bhack\\b|" +
			"```\\s*(suggestion|diff)"; "i")) as $actionable |

		# skip = explicit no-suggestions OR approval-only/no-recommendation/summary-praise with no actionable critique
		if ($no_actionable_suggestion or (($approval_only or $no_actionable_recommendation or $no_actionable_sentiment or $summary_praise_only) and ($actionable | not))) then "skip"
		else "keep"
		end
	')
	echo "$result"
	return 0
}

test_skips_lgtm_review() {
	local result
	result=$(_test_approval_filter "LGTM")
	if [[ "$result" == "skip" ]]; then
		print_result "skip LGTM review" 0
	else
		print_result "skip LGTM review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_no_further_comments_review() {
	local result
	result=$(_test_approval_filter "I've reviewed the changes and have no further comments. Good work.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'no further comments' review" 0
	else
		print_result "skip 'no further comments' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_looks_good_review() {
	local result
	result=$(_test_approval_filter "Looks good to me!")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'looks good to me' review" 0
	else
		print_result "skip 'looks good to me' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_good_work_review() {
	local result
	result=$(_test_approval_filter "Good work on this PR.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'good work' review" 0
	else
		print_result "skip 'good work' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_no_issues_review() {
	local result
	result=$(_test_approval_filter "No issues found. Everything looks good.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'no issues' review" 0
	else
		print_result "skip 'no issues' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_found_no_issues_long_review() {
	local result
	result=$(_test_approval_filter "This pull request enhances the AI supervisor's reasoning capabilities by introducing self-improvement and efficiency analysis. It adds two new action types, create_improvement and escalate_model, along with corresponding analysis frameworks and examples in the system prompt. The updates to the prompt are clear and consistent with the stated goals. I've reviewed the changes and found no issues. The new capabilities are a strong step toward a more intelligent supervisor.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip long summary review with 'found no issues'" 0
	else
		print_result "skip long summary review with 'found no issues'" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_no_further_recommendations_review() {
	local result
	result=$(_test_approval_filter "The pull request is well-documented and the fixes are implemented correctly. I have no further recommendations.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'no further recommendations' review" 0
	else
		print_result "skip 'no further recommendations' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_gemini_style_positive_summary_review() {
	local result
	result=$(_test_approval_filter "This pull request successfully addresses the issue by removing an external dependency and improves robustness. The addition of no-data messaging enhances user experience.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip Gemini-style positive summary review" 0
	else
		print_result "skip Gemini-style positive summary review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_no_suggestions_at_this_time_review() {
	local result
	result=$(_test_approval_filter "Review completed. No suggestions at this time.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'no suggestions at this time' review" 0
	else
		print_result "skip 'no suggestions at this time' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_keeps_actionable_approved_review() {
	# APPROVED review that also contains actionable critique — must be kept
	local result
	result=$(_test_approval_filter "Looks good overall, but you should consider adding error handling for the null case." "APPROVED")
	if [[ "$result" == "keep" ]]; then
		print_result "keep APPROVED review with actionable critique" 0
	else
		print_result "keep APPROVED review with actionable critique" 1 "expected keep, got ${result}"
	fi
	return 0
}

test_keeps_changes_requested_review() {
	# CHANGES_REQUESTED review — must always be kept
	local result
	result=$(_test_approval_filter "This looks wrong. The function is missing error handling." "CHANGES_REQUESTED")
	if [[ "$result" == "keep" ]]; then
		print_result "keep CHANGES_REQUESTED review with critique" 0
	else
		print_result "keep CHANGES_REQUESTED review with critique" 1 "expected keep, got ${result}"
	fi
	return 0
}

test_keeps_review_with_bug_report() {
	# Review mentioning a bug — must be kept even if it starts positively
	local result
	result=$(_test_approval_filter "Good work overall, but there's a bug in the error handler — it fails when input is null.")
	if [[ "$result" == "keep" ]]; then
		print_result "keep review with bug report despite positive opener" 0
	else
		print_result "keep review with bug report despite positive opener" 1 "expected keep, got ${result}"
	fi
	return 0
}

test_keeps_review_with_suggestion_fence() {
	# Review with a suggestion code fence — must be kept
	local result
	result=$(_test_approval_filter 'Looks good, but consider this change:
```suggestion
return nil, fmt.Errorf("invalid input: %w", err)
```')
	if [[ "$result" == "keep" ]]; then
		print_result "keep review with suggestion fence" 0
	else
		print_result "keep review with suggestion fence" 1 "expected keep, got ${result}"
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

	echo ""
	echo "Running approval/sentiment detection tests (GH#4604)"
	test_skips_lgtm_review
	test_skips_no_further_comments_review
	test_skips_looks_good_review
	test_skips_good_work_review
	test_skips_no_issues_review
	test_skips_found_no_issues_long_review
	test_skips_no_further_recommendations_review
	test_skips_gemini_style_positive_summary_review
	test_skips_no_suggestions_at_this_time_review
	test_keeps_actionable_approved_review
	test_keeps_changes_requested_review
	test_keeps_review_with_bug_report
	test_keeps_review_with_suggestion_fence

	echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
