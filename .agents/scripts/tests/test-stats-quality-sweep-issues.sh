#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-stats-quality-sweep-issues.sh — t3074 regression guard.
#
# Guards the three changes in _ensure_quality_issue() that fix the
# cross-runner duplicate "Code Audit Routines" dashboard bug:
#
#   (a) label-search-fails-do-not-create:
#       When gh issue list exits nonzero, _ensure_quality_issue returns 1
#       and does NOT call gh_create_issue.
#
#   (b) title-prefix-fallback-finds-existing:
#       When label search returns empty (but succeeds), a title-prefix
#       search runs. If it finds an issue, no new issue is created.
#
#   (c) post-create-sweep-closes-siblings:
#       After a new dashboard is created, _quality_issue_close_duplicates
#       closes all open sibling issues except the new one.
#
# Stub strategy: define `gh`, `gh_create_issue`, `jq` as shell functions
# AFTER sourcing the library. Shell functions take precedence over PATH
# binaries. Each test case redefines the stubs to its scenario.
#
# Cross-references: GH#21830 / t3074 (fix), GH#10308 (prior class-fix).

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

# =============================================================================
# Sandbox setup
# =============================================================================
TMP=$(mktemp -d -t t3074.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

GH_CALLS="${TMP}/gh_calls.log"
CREATE_CALLS="${TMP}/create_calls.log"
CLOSE_CALLS="${TMP}/close_calls.log"
LOGFILE="${TMP}/test.log"
export LOGFILE

# =============================================================================
# Source the library with quiet stubs
# =============================================================================
print_info() { :; }
print_warning() { :; }
print_error() { :; }
print_success() { :; }
log_verbose() { :; }
export -f print_info print_warning print_error print_success log_verbose

# gh_create_issue is a wrapper defined in shared-constants.sh; stub it directly
gh_create_issue() {
	echo "gh_create_issue $*" >>"$CREATE_CALLS"
	# Simulate successful creation returning a URL with issue number
	printf 'https://github.com/test/repo/issues/999\n'
	return 0
}
export -f gh_create_issue

# gh_issue_edit_safe stub
gh_issue_edit_safe() { return 0; }
export -f gh_issue_edit_safe

# Suppress stats-quality-sweep-coverage.sh dependency functions
_compute_bot_coverage() { printf 'no coverage'; return 0; }
_compute_badge_indicator() { printf 'OK'; return 0; }
export -f _compute_bot_coverage _compute_badge_indicator

# shellcheck source=../stats-quality-sweep-issues.sh
source "${SCRIPTS_DIR}/stats-quality-sweep-issues.sh" 2>/dev/null || {
	printf '%sFATAL%s could not source stats-quality-sweep-issues.sh\n' "$TEST_RED" "$TEST_NC"
	exit 1
}

# =============================================================================
# Test (a): label search API failure → abort, no creation
# =============================================================================
printf '\n%s[a] label-search-fails-do-not-create%s\n' "$TEST_BLUE" "$TEST_NC"

# Clear logs
true >"$CREATE_CALLS"
true >"$GH_CALLS"

# Stub: gh issue list returns nonzero (simulates API error).
# No cache file — forces the function to go through the label search path.
gh() {
	echo "gh $*" >>"$GH_CALLS"
	case "$*" in
	*"issue list"*)
		# Simulate transient API failure
		printf 'error: API rate limit exceeded\n' >&2
		return 1
		;;
	*"label create"*)
		return 0
		;;
	esac
	return 0
}
export -f gh

jq() { command jq "$@"; return 0; }
export -f jq

# Override HOME so cache file is isolated; ensure no stale cache exists
_original_home="$HOME"
export HOME="$TMP"
mkdir -p "${TMP}/.aidevops/logs"
rm -f "${TMP}/.aidevops/logs/quality-issue-test-repo"

result=$(_ensure_quality_issue "test/repo" 2>/dev/null)
rc=$?
export HOME="$_original_home"

if [[ "$rc" -ne 0 ]]; then
	pass "label-search-fails-returns-1"
else
	fail "label-search-fails-returns-1" "expected return 1, got $rc"
fi

if [[ ! -s "$CREATE_CALLS" ]]; then
	pass "label-search-fails-no-create"
else
	fail "label-search-fails-no-create" "gh_create_issue was called: $(cat "$CREATE_CALLS")"
fi

# =============================================================================
# Test (b): title-prefix fallback finds existing issue → no creation
# =============================================================================
printf '\n%s[b] title-prefix-fallback-finds-existing%s\n' "$TEST_BLUE" "$TEST_NC"

true >"$CREATE_CALLS"
true >"$GH_CALLS"

# Stub: label search succeeds but returns empty; title search finds #456
gh() {
	echo "gh $*" >>"$GH_CALLS"
	case "$*" in
	*"issue view"*)
		printf 'OPEN\n'
		return 0
		;;
	*"issue list"*"quality-review"*)
		# Label search: returns empty (no labels found) — exit 0
		printf ''
		return 0
		;;
	*"issue list"*"Code Audit Routines"*)
		# Title-prefix fallback: finds existing issue 456
		printf '456\n'
		return 0
		;;
	*"label create"*)
		return 0
		;;
	esac
	return 0
}
export -f gh

jq() { command jq "$@"; return 0; }
export -f jq

export HOME="$TMP"
rm -f "${TMP}/.aidevops/logs/quality-issue-test-repo"

result=$(_ensure_quality_issue "test/repo" 2>/dev/null)
rc=$?
export HOME="$_original_home"

if [[ "$rc" -eq 0 && "$result" == "456" ]]; then
	pass "title-fallback-returns-existing-number"
else
	fail "title-fallback-returns-existing-number" "expected 0/456, got rc=$rc result='$result'"
fi

if [[ ! -s "$CREATE_CALLS" ]]; then
	pass "title-fallback-no-create"
else
	fail "title-fallback-no-create" "gh_create_issue was called: $(cat "$CREATE_CALLS")"
fi

# Verify title search was called (check gh log contains "Code Audit Routines")
if grep -q "Code Audit Routines" "$GH_CALLS" 2>/dev/null; then
	pass "title-search-was-invoked"
else
	fail "title-search-was-invoked" "title search not found in gh calls: $(cat "$GH_CALLS")"
fi

# =============================================================================
# Test (c): post-create defensive sweep closes siblings
# =============================================================================
printf '\n%s[c] post-create-sweep-closes-siblings%s\n' "$TEST_BLUE" "$TEST_NC"

true >"$CREATE_CALLS"
true >"$GH_CALLS"
true >"$CLOSE_CALLS"

# Track what gets closed
CLOSED_NUMS="${TMP}/closed_nums.log"
true >"$CLOSED_NUMS"

# Stub: both searches return empty → create fires; sibling search finds 2 extras
gh() {
	echo "gh $*" >>"$GH_CALLS"
	case "$*" in
	*"issue view"*"--json state"*)
		printf 'OPEN\n'
		return 0
		;;
	*"issue view"*"--json id"*)
		printf '{"id":"node_abc"}\n' | command jq -r '.id'
		return 0
		;;
	*"issue list"*"quality-review"*)
		# Label search: empty
		printf ''
		return 0
		;;
	*"issue list"*"Code Audit Routines"*".[0].number"*)
		# Title-prefix search (--jq '.[0].number // empty'): return empty
		# so the create path executes
		printf ''
		return 0
		;;
	*"issue list"*"Code Audit Routines"*"[.[].number]"*)
		# Sibling search in _quality_issue_close_duplicates (--jq '[.[].number]'):
		# return a JSON array containing the new issue (999) plus two siblings
		printf '[100,200,999]\n'
		return 0
		;;
	*"issue comment"*)
		local num
		num=$(printf '%s' "$*" | grep -oE '[0-9]+' | head -1)
		echo "comment:$num" >>"$CLOSE_CALLS"
		return 0
		;;
	*"issue close"*)
		local num
		num=$(printf '%s' "$*" | grep -oE '[0-9]+' | head -1)
		echo "close:$num" >>"$CLOSE_CALLS"
		return 0
		;;
	*"label create"*)
		return 0
		;;
	*"api graphql"*)
		return 0
		;;
	esac
	return 0
}
export -f gh

jq() {
	if [[ "${1:-}" == "-r" && "${2:-}" == ".[]" ]]; then
		# Parse the JSON array from siblings search
		command jq -r '.[]' 2>/dev/null || printf '100\n200\n999\n'
		return 0
	fi
	command jq "$@"
	return 0
}
export -f jq

export HOME="$TMP"
rm -f "${TMP}/.aidevops/logs/quality-issue-test-repo"
# Also clear the gh-signature-helper output
GH_SIG_CALLED="${TMP}/sig_called"
true >"$GH_SIG_CALLED"

# Stub gh-signature-helper.sh
# shellcheck disable=SC2034
_orig_home_sig="$HOME"

result=$(_ensure_quality_issue "test/repo" 2>/dev/null)
rc=$?
export HOME="$_original_home"

if [[ "$rc" -eq 0 ]]; then
	pass "post-create-sweep-create-succeeded"
else
	fail "post-create-sweep-create-succeeded" "expected rc=0, got $rc"
fi

# Check that close was called for siblings (100, 200) but NOT for survivor (999)
if grep -q "close:100" "$CLOSE_CALLS" 2>/dev/null; then
	pass "post-create-sweep-closed-sibling-100"
else
	fail "post-create-sweep-closed-sibling-100" "close:100 not found in: $(cat "$CLOSE_CALLS" 2>/dev/null)"
fi

if grep -q "close:200" "$CLOSE_CALLS" 2>/dev/null; then
	pass "post-create-sweep-closed-sibling-200"
else
	fail "post-create-sweep-closed-sibling-200" "close:200 not found in: $(cat "$CLOSE_CALLS" 2>/dev/null)"
fi

if ! grep -q "close:999" "$CLOSE_CALLS" 2>/dev/null; then
	pass "post-create-sweep-preserved-survivor"
else
	fail "post-create-sweep-preserved-survivor" "survivor 999 was incorrectly closed"
fi

# =============================================================================
# Test (d): Sonar gate blocker issue is created only for failing gates
# =============================================================================
printf '\n%s[d] sonar-gate-blocker-create-on-failure%s\n' "$TEST_BLUE" "$TEST_NC"

true >"$CREATE_CALLS"
true >"$GH_CALLS"

gh() {
	echo "gh $*" >>"$GH_CALLS"
	case "$*" in
	*"issue list"*"quality-gate-blocker"*)
		printf '0\n'
		return 0
		;;
	*"label create"*)
		return 0
		;;
	esac
	return 0
}
export -f gh

_ensure_sonar_gate_blocker_issue "test/repo" "ERROR" "### SonarCloud Quality Gate" 2>/dev/null

if grep -q "quality gate: resolve SonarCloud badge blockers" "$CREATE_CALLS" 2>/dev/null; then
	pass "sonar-gate-error-creates-issue"
else
	fail "sonar-gate-error-creates-issue" "gh_create_issue not called: $(cat "$CREATE_CALLS" 2>/dev/null)"
fi

if grep -q "quality-gate-blocker" "$CREATE_CALLS" 2>/dev/null; then
	pass "sonar-gate-error-applies-blocker-label"
else
	fail "sonar-gate-error-applies-blocker-label" "quality-gate-blocker label missing: $(cat "$CREATE_CALLS" 2>/dev/null)"
fi

printf '\n%s[e] sonar-gate-blocker-skip-on-ok%s\n' "$TEST_BLUE" "$TEST_NC"

true >"$CREATE_CALLS"

_ensure_sonar_gate_blocker_issue "test/repo" "OK" "### SonarCloud Quality Gate" 2>/dev/null

if [[ ! -s "$CREATE_CALLS" ]]; then
	pass "sonar-gate-ok-no-create"
else
	fail "sonar-gate-ok-no-create" "gh_create_issue was called: $(cat "$CREATE_CALLS")"
fi

# =============================================================================
# Test (f): multi-line bot coverage does not shift later dashboard fields
# GH#32730: newline-delimited transport rendered an empty badge row and the
# title "Simplified: | Metric | Count |".
# =============================================================================
printf '\n%s[f] quality-stats-multiline-transport%s\n' "$TEST_BLUE" "$TEST_NC"

_compute_debt_stats() { printf '1|2039|2040|99'; return 0; }
_compute_bot_coverage() { printf '### Bot Review Coverage\n\n| Metric | Count |\n| --- | --- |\n| Open PRs | 3 |\n'; return 0; }
_compute_badge_indicator() { printf 'GREEN (all badges passing)'; return 0; }

export HOME="$TMP"
stats_file="${TMP}/quality-stats.bin"
_gather_quality_issue_stats "test/repo" "OK" "A" >"$stats_file"
export HOME="$_original_home"
fields=()
while IFS= read -r -d '' field; do
	fields+=("$field")
done <"$stats_file"

if [[ "${#fields[@]}" -eq 9 && "${fields[7]}" == "GREEN (all badges passing)" && "${fields[8]}" == "0" && "${fields[6]}" == *"| Open PRs | 3 |"* ]]; then
	pass "multi-line-coverage-keeps-badge-and-simplified-fields"
else
	fail "multi-line-coverage-keeps-badge-and-simplified-fields" "count=${#fields[@]} badge='${fields[7]:-}' simplified='${fields[8]:-}'"
fi

title=$(_build_quality_issue_title "1" "2039" "C" "82" "OK")
if [[ "$title" == "Code Audit Routines — Qlty C (82 smells) · Sonar OK · quality debt: 1 open, 2039 closed" ]]; then
	pass "quality-title-carries-grade-gate-and-backlog"
else
	fail "quality-title-carries-grade-gate-and-backlog" "title='${title}'"
fi

title=$(_build_quality_issue_title "0" "0" "UNKNOWN" "0" "UNKNOWN")
if [[ "$title" == "Code Audit Routines — quality debt: 0 open, 0 closed" ]]; then
	pass "quality-title-omits-unknown-signals"
else
	fail "quality-title-omits-unknown-signals" "title='${title}'"
fi

# =============================================================================
# Test (g): superseded automation comments are selected; humans are not
# =============================================================================
printf '\n%s[g] superseded-dashboard-comment-selection%s\n' "$TEST_BLUE" "$TEST_NC"

comments_json='[
 {"id":"legacy","isMinimized":false,"createdAt":"2026-06-01T00:00:00Z","body":"## Daily Code Quality Sweep\nold"},
 {"id":"sweep-old","isMinimized":false,"createdAt":"2026-07-01T00:00:00Z","body":"<!-- quality-sweep-latest -->\n## Daily Code Quality Sweep"},
 {"id":"sweep-new","isMinimized":false,"createdAt":"2026-08-01T00:00:00Z","body":"<!-- quality-sweep-latest -->\n## Daily Code Quality Sweep"},
 {"id":"nmr","isMinimized":false,"createdAt":"2026-07-02T00:00:00Z","body":"<!-- nmr-decision-packet reason=authority -->\n## Maintainer decision required"},
 {"id":"ops","isMinimized":false,"createdAt":"2026-07-03T00:00:00Z","body":"<!-- ops:start — workers: skip -->\nDISPATCH_CLAIM"},
 {"id":"hidden","isMinimized":true,"createdAt":"2026-07-04T00:00:00Z","body":"<!-- nmr-decision-packet reason=secret -->"},
 {"id":"human","isMinimized":false,"createdAt":"2026-07-05T00:00:00Z","body":"Thanks, looks good."},
 {"id":"approval","isMinimized":false,"createdAt":"2026-07-06T00:00:00Z","body":"<!-- aidevops-signed-approval -->\napproved"}
]'
selected=$(_select_superseded_dashboard_comments "$comments_json" | sort | tr '\n' ' ')
if [[ "$selected" == "legacy nmr ops sweep-old " ]]; then
	pass "selects-superseded-automation-only"
else
	fail "selects-superseded-automation-only" "selected='${selected}'"
fi

# =============================================================================
# Test (h): large comment bodies do not abort hygiene (GH#32752)
# 150 automation comments x 20 KB bodies exceed the argument-size limit when
# full bodies are merged through jq --argjson.
# =============================================================================
printf '\n%s[h] large-thread-comment-hygiene%s\n' "$TEST_BLUE" "$TEST_NC"

LARGE_PAGE="${TMP}/large-page.json"
MINIMIZED="${TMP}/minimized.log"
true >"$MINIMIZED"
command jq -n '{data:{repository:{issue:{comments:{
	pageInfo:{hasNextPage:false,endCursor:null},
	nodes:[range(0;150) | {id:"c\(.)", isMinimized:false, createdAt:"2026-07-01T00:00:00Z",
		body:("<!-- nmr-decision-packet reason=authority -->\n" + ("x" * 20000))}]
}}}}}' >"$LARGE_PAGE"

gh() {
	case "$*" in
	*"minimizeComment"*)
		printf '%s\n' "$*" >>"$MINIMIZED"
		printf '{"data":{"minimizeComment":{"clientMutationId":null}}}\n'
		return 0
		;;
	*"api graphql"*)
		cat "$LARGE_PAGE"
		return 0
		;;
	esac
	return 0
}
export -f gh
jq() { command jq "$@"; }
export -f jq

QUALITY_DASHBOARD_MINIMIZE_MAX=200 _minimize_superseded_dashboard_comments 24670 "test/repo"
minimized_count=$(grep -c 'minimizeComment(input' "$MINIMIZED")
if [[ "$minimized_count" == "150" ]]; then
	pass "large-thread-minimizes-all-superseded-comments"
else
	fail "large-thread-minimizes-all-superseded-comments" "minimized=${minimized_count}; log=$(tail -3 "$LOGFILE" 2>/dev/null)"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed.%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d of %d tests FAILED.%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
