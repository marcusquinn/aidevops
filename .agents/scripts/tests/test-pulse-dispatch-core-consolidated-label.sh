#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for _has_consolidated_label() (GH#23187).
#
# Consolidated source issues are archival records, while marked successor specs
# with an explicit auto-dispatch handoff are implementation tasks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
CORE_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-commit-gates.sh"
_PULSE_DISPATCH_AUTO_LABEL="auto-dispatch"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

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

define_helper_under_test() {
	local helper_src
	helper_src=$(awk '
		/^_has_consolidated_label\(\) \{/,/^}$/ { print }
	' "$CORE_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract _has_consolidated_label from %s\n' "$CORE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helper
	eval "$helper_src"
	return 0
}

test_detects_consolidated_label() {
	local meta='{"number":23187,"labels":[{"name":"status:queued"},{"name":"origin:worker"},{"name":"consolidated"}]}'
	if _has_consolidated_label "$meta"; then
		print_result "detects consolidated label among dispatch labels" 0
		return 0
	fi
	print_result "detects consolidated label among dispatch labels" 1 \
		"Expected exit 0 when consolidated is present"
	return 0
}

test_absent_label_returns_nonzero() {
	local meta='{"number":23188,"labels":[{"name":"status:queued"},{"name":"origin:worker"},{"name":"tier:standard"}]}'
	if _has_consolidated_label "$meta"; then
		print_result "absent consolidated label returns exit 1" 1 \
			"Expected exit 1 when consolidated is absent"
		return 0
	fi
	print_result "absent consolidated label returns exit 1" 0
	return 0
}

test_review_feedback_consolidated_is_dispatchable() {
	local meta='{"number":4648,"labels":[{"name":"status:available"},{"name":"origin:worker"},{"name":"consolidated"},{"name":"quality-debt"},{"name":"source:review-feedback"}]}'
	if _has_consolidated_label "$meta"; then
		print_result "review-feedback consolidated issues are dispatchable" 1 \
			"Expected exit 1 for consolidated review-feedback implementation specs"
		return 0
	fi
	print_result "review-feedback consolidated issues are dispatchable" 0
	return 0
}

test_ci_feedback_consolidated_is_dispatchable() {
	local meta='{"number":4649,"labels":[{"name":"status:available"},{"name":"origin:worker"},{"name":"consolidated"},{"name":"source:ci-feedback"}]}'
	if _has_consolidated_label "$meta"; then
		print_result "CI-feedback consolidated issues are dispatchable" 1 \
			"Expected exit 1 for consolidated CI-feedback implementation specs"
		return 0
	fi
	print_result "CI-feedback consolidated issues are dispatchable" 0
	return 0
}

test_marked_auto_dispatch_successor_is_dispatchable() {
	local meta='{"number":27903,"body":"_Supersedes #27896 — this issue is the consolidated spec._\n\n## What\nImplement the fix.","labels":[{"name":"status:available"},{"name":"origin:worker"},{"name":"consolidated"},{"name":"auto-dispatch"}]}'
	if _has_consolidated_label "$meta"; then
		print_result "marked auto-dispatch successor is dispatchable" 1 \
			"Expected exit 1 for a canonical consolidated successor spec"
		return 0
	fi
	print_result "marked auto-dispatch successor is dispatchable" 0
	return 0
}

test_auto_dispatch_parent_without_marker_remains_blocked() {
	local meta='{"number":27896,"body":"Original issue body.","labels":[{"name":"status:available"},{"name":"origin:worker"},{"name":"consolidated"},{"name":"auto-dispatch"}]}'
	if _has_consolidated_label "$meta"; then
		print_result "auto-dispatch parent without marker remains blocked" 0
		return 0
	fi
	print_result "auto-dispatch parent without marker remains blocked" 1 \
		"Expected exit 0 when auto-dispatch lacks the successor marker"
	return 0
}

test_marker_without_auto_dispatch_remains_blocked() {
	local meta='{"number":27903,"body":"_Supersedes #27896 — this issue is the consolidated spec._","labels":[{"name":"status:available"},{"name":"origin:worker"},{"name":"consolidated"}]}'
	if _has_consolidated_label "$meta"; then
		print_result "marker without auto-dispatch remains blocked" 0
		return 0
	fi
	print_result "marker without auto-dispatch remains blocked" 1 \
		"Expected exit 0 when the successor lacks an explicit handoff"
	return 0
}

test_instructional_marker_text_does_not_bypass() {
	# shellcheck disable=SC2016 # Literal backticks are part of the body fixture.
	local meta='{"number":27848,"body":"Start the body with: `_Supersedes #27799 — this issue is the consolidated spec._`","labels":[{"name":"status:available"},{"name":"origin:worker"},{"name":"consolidated"},{"name":"auto-dispatch"}]}'
	if _has_consolidated_label "$meta"; then
		print_result "instructional marker text does not bypass" 0
		return 0
	fi
	print_result "instructional marker text does not bypass" 1 \
		"Expected exit 0 for a marker embedded in instructional prose"
	return 0
}

test_partial_label_name_does_not_match() {
	local meta='{"number":23189,"labels":[{"name":"needs-consolidation"},{"name":"consolidation-task"}]}'
	if _has_consolidated_label "$meta"; then
		print_result "partial consolidation labels do not match" 1 \
			"Expected exit 1 for needs-consolidation/consolidation-task"
		return 0
	fi
	print_result "partial consolidation labels do not match" 0
	return 0
}

test_empty_or_invalid_meta_returns_nonzero() {
	if _has_consolidated_label "" || _has_consolidated_label "not json"; then
		print_result "empty or invalid meta_json returns exit 1" 1 \
			"Expected exit 1 for empty/invalid metadata"
		return 0
	fi
	print_result "empty or invalid meta_json returns exit 1" 0
	return 0
}

test_string_label_candidates_use_same_predicate() {
	local blocked='{"number":1,"labels":["status:available","consolidated"]}'
	local spec='{"number":2,"body":"_Supersedes #1 — this issue is the consolidated spec._","labels":["consolidated","auto-dispatch"]}'
	if _has_consolidated_label "$blocked" && ! _has_consolidated_label "$spec"; then
		print_result "normalized string labels use the same predicate" 0
		return 0
	fi
	print_result "normalized string labels use the same predicate" 1 \
		"Expected candidate-shaped string labels to match object-label results"
	return 0
}

# GH#35038: the candidate projection keeps consolidated bodies, and the
# pre-ranking filter drops exactly what dispatch_with_dedup would reject,
# surfacing a stranded draft checkpoint once without relabelling.
test_projection_and_prerank_filter_match_gate() {
	local test_root="" status=0
	test_root=$(mktemp -d) || {
		print_result "projection and pre-ranking filter match the dispatch gate" 1 "mktemp failed"
		return 0
	}
	(
		set +e
		SCRIPT_DIR="${SCRIPT_DIR}/.."
		# shellcheck source=../pulse-repo-meta.sh
		source "${SCRIPT_DIR}/pulse-repo-meta.sh"
		# shellcheck source=../pulse-dispatch-commit-gates.sh
		source "${SCRIPT_DIR}/pulse-dispatch-commit-gates.sh"
		# shellcheck source=../pulse-dispatch-lib-candidates.sh
		source "${SCRIPT_DIR}/pulse-dispatch-lib-candidates.sh"
		HOME="${test_root}/home"
		LOGFILE="${test_root}/pulse.log"
		GH_CALLS="${test_root}/gh-calls.log"
		: >"$LOGFILE"
		: >"$GH_CALLS"
		_dispatch_stats_increment() { return 0; }
		gh() {
			printf '%s\n' "$*" >>"$GH_CALLS"
			case "$*" in
			"api repos/owner/repo/issues/106 --jq"*)
				printf '%s\n' '_Supersedes #99 — this issue is the consolidated spec._'
				;;
			"pr list"*)
				printf '%s\n' '[{"number":501,"title":"t18726: draft","body":"For #101","isDraft":true,"headRefOid":"0123456789abcdef0123456789abcdef01234567"}]'
				;;
			"api --paginate"*) printf '[]\n' ;;
			"api repos/owner/repo/issues/101/comments --method POST"*) printf '{}\n' ;;
			*) return 1 ;;
			esac
			return 0
		}
		local spec='_Supersedes #99 — this issue is the consolidated spec._'
		local raw="" projected="" filtered="" second="" plain="" number=""
		raw=$(jq -nc --arg spec "$spec" '[
			{number:101,title:"stranded",url:"u",body:$spec,labels:[{name:"status:available"},{name:"consolidated"}],assignees:[]},
			{number:102,title:"spec",url:"u",body:$spec,labels:[{name:"consolidated"},{name:"auto-dispatch"}],assignees:[]},
			{number:103,title:"no marker",url:"u",body:"Hand-written body.",labels:[{name:"consolidated"},{name:"auto-dispatch"}],assignees:[]},
			{number:104,title:"plain",url:"u",body:"Plain body.",labels:[{name:"auto-dispatch"}],assignees:[]},
			{number:105,title:"feedback",url:"u",body:"x",labels:[{name:"consolidated"},{name:"source:review-feedback"}],assignees:[]},
			{number:106,title:"live shape",url:"u",labels:[{name:"consolidated"},{name:"auto-dispatch"}],assignees:[]}
		]')
		projected=$(_filter_dispatchable_issue_candidates_json "$raw") || exit 2
		jq -e 'map(select(.number == 102))[0].body | test("consolidated spec")' <<<"$projected" >/dev/null || exit 3
		jq -e 'map(select(.number == 104))[0] | has("body") | not' <<<"$projected" >/dev/null || exit 4
		# Every excluded candidate is one the dispatch-time gate rejects.
		for number in 101 103; do
			_has_consolidated_label "$(jq -c --argjson n "$number" '.[] | select(.number == $n)' <<<"$raw")" || exit 5
		done
		filtered=$(_dispatch_filter_consolidated_candidates owner/repo "$projected")
		[[ "$(jq -c 'map(.number)' <<<"$filtered")" == '[102,104,105,106]' ]] || exit 6
		jq -e 'all(.[]; has("body") | not)' <<<"$filtered" >/dev/null || exit 7
		[[ "$(grep -c 'consolidated management-label gate skipped #101 #103' "$LOGFILE")" == 1 ]] || exit 8
		grep -q 'CONSOLIDATED_CHECKPOINT_ATTENTION_POSTED #101 (owner/repo) draft PR #501' "$LOGFILE" || exit 9
		[[ "$(grep -c -- '--method POST' "$GH_CALLS")" == 1 ]] || exit 10
		grep -q 'issues/101/comments --method POST' "$GH_CALLS" || exit 11
		# Attention never relabels (auto-dispatch is not re-added) or edits state.
		grep -qE '^(issue|pr) (edit|close)|/labels|--method (PATCH|PUT|DELETE)' "$GH_CALLS" && exit 12
		# A fresh attention stamp suppresses repeat PR/comment lookups.
		: >"$GH_CALLS"
		second=$(_dispatch_filter_consolidated_candidates owner/repo "$projected")
		[[ "$second" == "$filtered" ]] || exit 13
		grep -q 'pr list' "$GH_CALLS" && exit 14
		# Without consolidated candidates the input passes through unchanged.
		plain='[{"number":7,"labels":["auto-dispatch"]}]'
		[[ "$(_dispatch_filter_consolidated_candidates owner/repo "$plain")" == "$plain" ]] || exit 15
		exit 0
	) || status=$?
	rm -rf "$test_root"
	print_result "projection and pre-ranking filter match the dispatch gate" "$status" \
		"Assertion ${status} failed: expected #101/#103 filtered, #102/#104/#105/#106 kept and one attention post"
	return 0
}

# GH#35623: Consolidation rewrites an issue body, not its quoted source files.
test_consolidation_large_file_exemption() {
	local test_root="" status=0
	test_root=$(mktemp -d) || return 1
	(
		set +e
		# shellcheck source=../pulse-dispatch-large-file-gate.sh
		source "${SCRIPT_DIR}/../pulse-dispatch-large-file-gate.sh"
		LOGFILE="${test_root}/pulse.log"
		local labels="consolidation-task" gh_calls="" removal_rc=0 rc=0
		local body='EDIT: .agents/scripts/large.sh'
		mkdir -p "${test_root}/.agents/scripts"
		local line=0
		while [[ "$line" -le 2000 ]]; do
			printf '# fixture line\n'
			line=$((line + 1))
		done >"${test_root}/.agents/scripts/large.sh"
		_large_file_gate_issue_labels() { printf '%s' "$labels"; return 0; }
		gh() {
			gh_calls+="$*;"
			return "$removal_rc"
		}
		# Keep measurement and debt filing local; exercise real orchestration,
		# extraction and label precheck against the same >2000-line fixture.
		_large_file_gate_issue_title() { printf 'ordinary fix'; return 0; }
		_large_file_gate_measure_verified_targets() {
			local paths="$1" repo_path="$2"
			[[ "$paths" == ".agents/scripts/large.sh" ]] || return 1
			[[ $(wc -l <"${repo_path}/${paths}") -gt 2000 ]] || return 1
			_LFG_FOUND_LARGE=true
			_LFG_LARGE_FILES="large.sh (2001 lines)"
			_LFG_LARGE_FILE_PATHS="$paths"
			return 0
		}
		_large_file_gate_apply() { gh_calls+="APPLIED;"; return 0; }
		_issue_targets_large_files 1 owner/repo "$body" "$test_root" || rc=$?
		[[ "$rc" -eq 1 && -z "$gh_calls" ]] || exit 1
		labels="needs-simplification,consolidation-task,auto-dispatch"
		rc=0
		_issue_targets_large_files 1 owner/repo "$body" "$test_root" || rc=$?
		[[ "$rc" -eq 1 && "$gh_calls" == 'issue edit 1 --repo owner/repo --remove-label needs-simplification;' ]] || exit 2
		grep -q 'auto-cleared.*consolidation-task' "$LOGFILE" || exit 3
		gh_calls=""
		removal_rc=1
		rc=0
		_issue_targets_large_files 1 owner/repo "$body" "$test_root" true || rc=$?
		[[ "$rc" -eq 1 && "$gh_calls" != *APPLIED* ]] || exit 4
		grep -q 'WARN: failed to remove needs-simplification' "$LOGFILE" || exit 5
		# Similar labels and ordinary implementation work must still be gated.
		for labels in auto-dispatch needs-consolidation consolidation-task-extra; do
			gh_calls=""
			rc=0
			_issue_targets_large_files 1 owner/repo "$body" "$test_root" || rc=$?
			[[ "$rc" -eq 0 && "$gh_calls" == 'APPLIED;' ]] || exit 6
		done
		exit 0
	) || status=$?
	rm -rf "$test_root"
	print_result "consolidation bypasses large-file gate and clears stale labels; ordinary work stays gated" "$status" \
		"Assertion ${status} failed in consolidation large-file regression"
	return 0
}

main() {
	if ! define_helper_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_detects_consolidated_label
	test_absent_label_returns_nonzero
	test_review_feedback_consolidated_is_dispatchable
	test_ci_feedback_consolidated_is_dispatchable
	test_marked_auto_dispatch_successor_is_dispatchable
	test_auto_dispatch_parent_without_marker_remains_blocked
	test_marker_without_auto_dispatch_remains_blocked
	test_instructional_marker_text_does_not_bypass
	test_partial_label_name_does_not_match
	test_empty_or_invalid_meta_returns_nonzero
	test_string_label_candidates_use_same_predicate
	test_projection_and_prerank_filter_match_gate
	test_consolidation_large_file_exemption

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
