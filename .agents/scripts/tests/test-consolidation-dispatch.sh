#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-consolidation-dispatch.sh — regression tests for t1982
#
# Covers the fix for the half-built consolidation flow:
#   1. _dispatch_issue_consolidation creates a self-contained child issue
#   2. Child body contains parent title, body, and substantive comments inline
#   3. Child body includes a @-mention cc line for all unique comment authors
#   4. Dedup: calling twice on the same parent does not create a second child
#   5. _issue_needs_consolidation returns 1 when a child already exists
#   6. _consolidation_child_exists correctly detects existing children
#
# Strategy: source pulse-triage.sh with a stubbed `gh` binary on PATH that
# records every invocation and returns canned responses driven by the test.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""

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

# Create a stubbed `gh` binary on PATH. Canned responses are driven by
# environment variables set per test:
#   GH_ISSUE_VIEW_TITLE — string returned by `gh issue view --json title --jq .title`
#   GH_ISSUE_VIEW_BODY — string for body
#   GH_ISSUE_VIEW_LABELS — CSV returned by `--json labels --jq '[.labels[].name] | join(",")'`
#   GH_API_COMMENTS_JSON — raw JSON returned by `gh api .../comments`
#   GH_ISSUE_LIST_CHILD_JSON — JSON array used for dedup lookups
#   GH_ISSUE_CREATE_URL — URL echoed by `gh issue create` on success
setup_gh_stub() {
	TEST_ROOT=$(mktemp -d -t t1982-consol.XXXXXX)
	GH_LOG="${TEST_ROOT}/gh.log"
	: >"$GH_LOG"
	mkdir -p "${TEST_ROOT}/bin"

	cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal `gh` stub for consolidation tests.
# Records the call line and returns canned output.
# bash 3.2 compatible — no ;;& fall-through.
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"

cmd1="${1:-}"
cmd2="${2:-}"

if [[ "$cmd1" == "issue" && "$cmd2" == "view" ]]; then
	shift 2
	local_json=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			local_json="$2"
			shift 2
			;;
		--jq)
			shift 2
			;;
		*) shift ;;
		esac
	done
	case "$local_json" in
	title) printf '%s\n' "${GH_ISSUE_VIEW_TITLE:-Parent Title}" ;;
	body) printf '%s\n' "${GH_ISSUE_VIEW_BODY:-Parent body}" ;;
	labels) printf '%s\n' "${GH_ISSUE_VIEW_LABELS:-bug,tier:standard}" ;;
	*) printf '\n' ;;
	esac
	exit 0
fi

if [[ "$cmd1" == "issue" && "$cmd2" == "list" ]]; then
	# Parse --jq filter if present, so the stub emulates real gh output.
	jq_filter=""
	for arg in "$@"; do
		if [[ "$prev_arg" == "--jq" ]]; then
			jq_filter="$arg"
		fi
		prev_arg="$arg"
	done
	if [[ -n "$jq_filter" ]]; then
		printf '%s\n' "${GH_ISSUE_LIST_CHILD_JSON:-[]}" | jq -r "$jq_filter"
	else
		printf '%s\n' "${GH_ISSUE_LIST_CHILD_JSON:-[]}"
	fi
	exit 0
fi

if [[ "$cmd1" == "issue" && "$cmd2" == "create" ]]; then
	printf '%s\n' "${GH_ISSUE_CREATE_URL:-https://github.com/owner/repo/issues/999}"
	exit 0
fi

if [[ "$cmd1" == "issue" && "$cmd2" == "edit" ]]; then
	exit 0
fi

if [[ "$cmd1" == "issue" && "$cmd2" == "comment" ]]; then
	exit 0
fi

if [[ "$cmd1" == "api" ]]; then
	# gh api repos/owner/repo/issues/N/comments ...
	printf '%s\n' "${GH_API_COMMENTS_JSON:-[]}"
	exit 0
fi

if [[ "$cmd1" == "label" && "$cmd2" == "create" ]]; then
	exit 0
fi

printf 'gh stub: unhandled: %s\n' "$*" >&2
exit 0
STUB
	chmod +x "${TEST_ROOT}/bin/gh"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export GH_LOG
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"

	# Minimal globals expected by pulse-triage.sh
	export TRIAGE_CACHE_DIR="${TEST_ROOT}/triage-cache"
	mkdir -p "$TRIAGE_CACHE_DIR"
	export ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS=50
	export ISSUE_CONSOLIDATION_COMMENT_THRESHOLD=2
	export REPOS_JSON="${TEST_ROOT}/repos.json"
	printf '{"initialized_repos": []}\n' >"$REPOS_JSON"

	# Source pulse-triage.sh in isolation — it's intended to be sourced
	# from pulse-wrapper.sh but the consolidation helpers are self-contained.
	# shellcheck disable=SC1091
	source "${REPO_ROOT}/.agents/scripts/pulse-triage.sh"
	return 0
}

teardown_gh_stub() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	TEST_ROOT=""
	GH_LOG=""
	unset GH_ISSUE_VIEW_TITLE GH_ISSUE_VIEW_BODY GH_ISSUE_VIEW_LABELS
	unset GH_API_COMMENTS_JSON GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_CREATE_URL
	return 0
}

fixture_two_substantive_comments() {
	# Two substantive comments from alice and bob plus one bot noise.
	# Each comment body is ~60 chars to clear min_chars=50.
	cat <<'JSON'
[
  {"user": {"login": "alice", "type": "User"}, "created_at": "2026-04-12T10:00:00Z", "body": "I think we need to add a third failure case for the offline path when the cache is cold."},
  {"user": {"login": "bob", "type": "User"}, "created_at": "2026-04-12T11:30:00Z", "body": "Agree with alice and also the retry policy should back off exponentially rather than linearly."},
  {"user": {"login": "github-actions", "type": "Bot"}, "created_at": "2026-04-12T12:00:00Z", "body": "Dispatching worker for issue #123 at 2026-04-12T12:00:00Z via /full-loop Implement it"}
]
JSON
}

test_dispatch_creates_child_issue() {
	setup_gh_stub
	GH_ISSUE_VIEW_TITLE="test: example parent issue"
	GH_ISSUE_VIEW_BODY="Original parent body describing the problem in detail."
	GH_ISSUE_VIEW_LABELS="bug,tier:standard"
	GH_API_COMMENTS_JSON=$(fixture_two_substantive_comments)
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_ISSUE_CREATE_URL="https://github.com/owner/repo/issues/9001"
	export GH_ISSUE_VIEW_TITLE GH_ISSUE_VIEW_BODY GH_ISSUE_VIEW_LABELS
	export GH_API_COMMENTS_JSON GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_CREATE_URL

	local rc=0
	_dispatch_issue_consolidation 123 "owner/repo" "/tmp/fake-path" || rc=$?

	if [[ "$rc" -eq 0 ]] && grep -q 'issue create' "$GH_LOG" 2>/dev/null; then
		print_result "dispatch creates consolidation-task child issue" 0
	elif [[ "$rc" -ne 0 ]]; then
		print_result "dispatch creates consolidation-task child issue" 1 \
			"_dispatch_issue_consolidation returned $rc"
	else
		print_result "dispatch creates consolidation-task child issue" 1 \
			"gh issue create was not invoked"
	fi

	teardown_gh_stub
	return 0
}

test_child_body_contains_parent_content_and_authors() {
	setup_gh_stub
	GH_ISSUE_VIEW_TITLE="test: parent title"
	GH_ISSUE_VIEW_BODY="VERBATIM_PARENT_BODY_MARKER"
	GH_ISSUE_VIEW_LABELS="bug"
	local fixture
	fixture=$(fixture_two_substantive_comments)
	local authors
	authors=$(printf '%s' "$fixture" | jq -r '[.[] | select(.user.type != "Bot") | .user.login] | unique | map("@" + .) | join(" ")')

	local body
	body=$(_compose_consolidation_child_body \
		123 "owner/repo" "test: parent title" "VERBATIM_PARENT_BODY_MARKER" \
		"$(printf '%s' "$fixture" | jq '[.[] | select(.user.type != "Bot") | {login: .user.login, created_at: .created_at, body: .body}]')" \
		"$authors" "bug")

	local failures=0
	local failmsg=""

	if ! printf '%s' "$body" | grep -q 'Consolidation target: #123'; then
		failures=$((failures + 1))
		failmsg="${failmsg} | missing consolidation-target marker"
	fi
	if ! printf '%s' "$body" | grep -q 'VERBATIM_PARENT_BODY_MARKER'; then
		failures=$((failures + 1))
		failmsg="${failmsg} | parent body not inlined verbatim"
	fi
	if ! printf '%s' "$body" | grep -q '@alice'; then
		failures=$((failures + 1))
		failmsg="${failmsg} | @alice not mentioned"
	fi
	if ! printf '%s' "$body" | grep -q '@bob'; then
		failures=$((failures + 1))
		failmsg="${failmsg} | @bob not mentioned"
	fi
	if ! printf '%s' "$body" | grep -q 'You do \*\*NOT\*\* need to read'; then
		failures=$((failures + 1))
		failmsg="${failmsg} | missing self-contained warning"
	fi
	if printf '%s' "$body" | grep -q 'github-actions'; then
		failures=$((failures + 1))
		failmsg="${failmsg} | bot comment leaked into child body"
	fi

	if [[ $failures -eq 0 ]]; then
		print_result "child body contains parent content + @-mentions + no bot leakage" 0
	else
		print_result "child body contains parent content + @-mentions + no bot leakage" 1 "$failmsg"
	fi

	teardown_gh_stub
	return 0
}

test_dedup_skips_when_child_exists() {
	setup_gh_stub
	GH_ISSUE_VIEW_TITLE="test: parent"
	GH_ISSUE_VIEW_BODY="body"
	GH_ISSUE_VIEW_LABELS="bug"
	GH_API_COMMENTS_JSON="[]"
	# Simulate dedup: child list returns one entry
	# shellcheck disable=SC2089
	GH_ISSUE_LIST_CHILD_JSON='[{"number": 9002}]'
	GH_ISSUE_CREATE_URL="https://github.com/owner/repo/issues/SHOULD_NOT_BE_CALLED"
	export GH_ISSUE_VIEW_TITLE GH_ISSUE_VIEW_BODY GH_ISSUE_VIEW_LABELS
	# shellcheck disable=SC2090
	export GH_API_COMMENTS_JSON GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_CREATE_URL

	_dispatch_issue_consolidation 123 "owner/repo" "/tmp/fake-path" || true

	if grep -q 'issue create' "$GH_LOG" 2>/dev/null; then
		print_result "dedup skips child creation when one already exists" 1 \
			"gh issue create was invoked despite existing child"
	else
		print_result "dedup skips child creation when one already exists" 0
	fi

	teardown_gh_stub
	return 0
}

test_consolidation_child_exists_detects_existing() {
	setup_gh_stub
	# shellcheck disable=SC2089
	GH_ISSUE_LIST_CHILD_JSON='[{"number": 9003}]'
	# shellcheck disable=SC2090
	export GH_ISSUE_LIST_CHILD_JSON

	if _consolidation_child_exists 123 "owner/repo"; then
		print_result "_consolidation_child_exists returns 0 when child present" 0
	else
		print_result "_consolidation_child_exists returns 0 when child present" 1 \
			"returned non-zero with non-empty child list"
	fi

	GH_ISSUE_LIST_CHILD_JSON="[]"
	export GH_ISSUE_LIST_CHILD_JSON
	if _consolidation_child_exists 123 "owner/repo"; then
		print_result "_consolidation_child_exists returns 1 when no child" 1 \
			"returned 0 with empty child list"
	else
		print_result "_consolidation_child_exists returns 1 when no child" 0
	fi

	teardown_gh_stub
	return 0
}

test_needs_consolidation_skips_with_child() {
	setup_gh_stub
	GH_ISSUE_VIEW_LABELS="bug,tier:standard"
	# Simulate: a consolidation-task child exists
	# shellcheck disable=SC2089
	GH_ISSUE_LIST_CHILD_JSON='[{"number": 9004}]'
	# shellcheck disable=SC2090
	export GH_ISSUE_VIEW_LABELS GH_ISSUE_LIST_CHILD_JSON

	# _issue_needs_consolidation returns 1 when child already exists.
	if _issue_needs_consolidation 123 "owner/repo"; then
		print_result "_issue_needs_consolidation skips when child exists" 1 \
			"returned 0 (consolidation needed) despite existing child"
	else
		print_result "_issue_needs_consolidation skips when child exists" 0
	fi

	teardown_gh_stub
	return 0
}

main() {
	test_dispatch_creates_child_issue
	test_child_body_contains_parent_content_and_authors
	test_dedup_skips_when_child_exists
	test_consolidation_child_exists_detects_existing
	test_needs_consolidation_skips_with_child

	echo
	echo "============================================"
	printf 'Tests run:    %d\n' "$TESTS_RUN"
	printf 'Tests failed: %d\n' "$TESTS_FAILED"
	echo "============================================"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
