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

# _write_gh_stub_binary: write the stubbed gh binary to TEST_ROOT/bin/gh.
# Requires TEST_ROOT to be set. Called by setup_gh_stub.
_write_gh_stub_binary() {
	if [[ -z "${TEST_ROOT:-}" ]]; then
		printf 'Error: TEST_ROOT is not set\n' >&2
		return 1
	fi
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
	# Parse --jq and --state so the stub emulates real gh behaviour.
	# t2144: added --state dispatch so tests can fixture open and closed
	# child lists independently (grace-window regression tests).
	jq_filter=""
	state_arg="open"
	prev_arg=""
	for arg in "$@"; do
		if [[ "$prev_arg" == "--jq" ]]; then
			jq_filter="$arg"
		fi
		if [[ "$prev_arg" == "--state" ]]; then
			state_arg="$arg"
		fi
		prev_arg="$arg"
	done
	list_json="${GH_ISSUE_LIST_CHILD_JSON:-[]}"
	if [[ "$state_arg" == "closed" ]]; then
		list_json="${GH_ISSUE_LIST_CHILD_CLOSED_JSON:-[]}"
	fi
	if [[ -n "$jq_filter" ]]; then
		printf '%s\n' "$list_json" | jq -r "$jq_filter"
	else
		printf '%s\n' "$list_json"
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
	return 0
}

# _setup_gh_stub_globals: export PATH and pulse-triage globals, then source the script.
# Requires TEST_ROOT and GH_LOG to be set. Called by setup_gh_stub.
_setup_gh_stub_globals() {
	if [[ -z "${TEST_ROOT:-}" ]]; then
		printf 'Error: TEST_ROOT is not set\n' >&2
		return 1
	fi
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

	# t2144: stub the gh_create_issue wrapper (defined in shared-constants.sh,
	# not sourced here) so _create_consolidation_child_issue actually reaches
	# the stubbed `gh issue create` on PATH. Without this, the wrapper is
	# undefined and the dispatch path silently fails — which has been a
	# pre-existing test flake since t2115 introduced the wrapper. Mirrors
	# the stub in tests/test-gh-wrapper-guard.sh.
	gh_create_issue() {
		gh issue create "$@"
	}
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
	_write_gh_stub_binary
	_setup_gh_stub_globals
	return 0
}

teardown_gh_stub() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	TEST_ROOT=""
	GH_LOG=""
	unset GH_ISSUE_VIEW_TITLE GH_ISSUE_VIEW_BODY GH_ISSUE_VIEW_LABELS
	unset GH_API_COMMENTS_JSON GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON GH_ISSUE_CREATE_URL
	unset CONSOLIDATION_RECENT_CLOSE_GRACE_MIN
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

# ----------------------------------------------------------------------
# t2144 regression tests — consolidation cascade fix
#
# Reference evidence: GH#19347 (investigation), cascades observed on
# 2026-04-16 where #19321 → #19341 + #19367 and #19275 → #19277 + #19359.
# ----------------------------------------------------------------------

# Fixture: two WORKER_SUPERSEDED comments of the exact length and shape
# seen in production (#19321). Before t2144 these passed the filter
# because the `^(\*\*)?Stale assignment recovered` anchor was a no-op —
# bodies start with the `<!-- WORKER_SUPERSEDED ...` HTML marker.
fixture_two_worker_superseded_comments() {
	local pad='x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x'
	local body1="<!-- WORKER_SUPERSEDED runners=marcusquinn ts=2026-04-16T17:06:24Z -->
**Stale assignment recovered** — prior worker exited without updating status. ${pad}"
	local body2="<!-- WORKER_SUPERSEDED runners=alex-solovyev ts=2026-04-16T17:35:29Z -->
**Stale assignment recovered** — prior worker exited without updating status. ${pad}"
	jq -n --arg b1 "$body1" --arg b2 "$body2" '
		[
			{"user": {"login": "marcusquinn", "type": "User"}, "created_at": "2026-04-16T17:06:25Z", "body": $b1},
			{"user": {"login": "marcusquinn", "type": "User"}, "created_at": "2026-04-16T17:35:30Z", "body": $b2}
		]
	'
}

# Fixture: one stale-recovery-tick comment (62 chars — under min_chars 500
# but we set min to 50 in the stub, so it would otherwise pass and count).
fixture_stale_recovery_tick_comment() {
	cat <<'JSON'
[
  {"user": {"login": "marcusquinn", "type": "User"}, "created_at": "2026-04-16T17:06:16Z", "body": "<!-- stale-recovery-tick:1 -->\nStale recovery tick 1/2 (t2008). This padding exists only so the body length clears the test-harness threshold of 50 chars without adding any real scope change."}
]
JSON
}

# t2144 A1 regression: WORKER_SUPERSEDED comments must NOT count as substantive.
test_worker_superseded_comments_are_filtered() {
	setup_gh_stub
	# Restore production-realistic thresholds for this test. The default
	# stub sets min_chars=50; WORKER_SUPERSEDED comments are ~530 chars so
	# they'd pass the length gate at either setting. Threshold stays at 2.
	export ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS=200
	GH_ISSUE_VIEW_LABELS="bug,tier:standard"
	GH_API_COMMENTS_JSON=$(fixture_two_worker_superseded_comments)
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	export GH_ISSUE_VIEW_LABELS GH_API_COMMENTS_JSON
	export GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON

	# Before t2144 this returned 0 (needs consolidation) because two 530-char
	# recovery comments passed the filter. After t2144 the ^<!-- WORKER_SUPERSEDED
	# pattern filters them out, substantive_count drops to 0, and the helper
	# returns 1 (no dispatch).
	if _issue_needs_consolidation 19321 "marcusquinn/aidevops"; then
		print_result "t2144: WORKER_SUPERSEDED comments are filtered (no false consolidation)" 1 \
			"_issue_needs_consolidation returned 0 despite only WORKER_SUPERSEDED noise"
	else
		print_result "t2144: WORKER_SUPERSEDED comments are filtered (no false consolidation)" 0
	fi

	teardown_gh_stub
	return 0
}

# t2144 A1 regression: stale-recovery-tick comments must NOT count.
test_stale_recovery_tick_comments_are_filtered() {
	setup_gh_stub
	GH_ISSUE_VIEW_LABELS="bug,tier:standard"
	GH_API_COMMENTS_JSON=$(fixture_stale_recovery_tick_comment)
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	export GH_ISSUE_VIEW_LABELS GH_API_COMMENTS_JSON
	export GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON

	if _issue_needs_consolidation 19999 "marcusquinn/aidevops"; then
		print_result "t2144: stale-recovery-tick comments are filtered" 1 \
			"_issue_needs_consolidation returned 0 despite only stale-recovery-tick noise"
	else
		print_result "t2144: stale-recovery-tick comments are filtered" 0
	fi

	teardown_gh_stub
	return 0
}

# t2144 A4 regression: a recently-closed child within the grace window
# still "owns" the parent — _consolidation_child_exists must return 0.
test_recently_closed_child_blocks_redispatch_within_grace() {
	setup_gh_stub
	# Child closed "now" — well inside the 30-min default window.
	export GH_ISSUE_LIST_CHILD_JSON="[]"
	export GH_ISSUE_LIST_CHILD_CLOSED_JSON='[{"number": 19341}]'

	if _consolidation_child_exists 19321 "marcusquinn/aidevops"; then
		print_result "t2144: recently-closed child blocks re-dispatch within grace window" 0
	else
		print_result "t2144: recently-closed child blocks re-dispatch within grace window" 1 \
			"_consolidation_child_exists returned 1 despite recently-closed child"
	fi

	teardown_gh_stub
	return 0
}

# t2144 A4 regression: grace_minutes=0 disables the window — backward-compat
# check that the legacy open-only semantics are reachable (no breakage for
# callers that don't want the grace window).
test_grace_zero_restores_open_only_semantics() {
	setup_gh_stub
	export GH_ISSUE_LIST_CHILD_JSON="[]"
	export GH_ISSUE_LIST_CHILD_CLOSED_JSON='[{"number": 19341}]'

	# Third arg 0 disables grace — closed child must not count.
	if _consolidation_child_exists 19321 "marcusquinn/aidevops" 0; then
		print_result "t2144: grace_minutes=0 ignores closed children" 1 \
			"_consolidation_child_exists returned 0 with grace=0 despite only-closed child"
	else
		print_result "t2144: grace_minutes=0 ignores closed children" 0
	fi

	teardown_gh_stub
	return 0
}

# t2144 A3 regression: backfill auto-clears `needs-consolidation` when the
# parent also carries `consolidated` (race artefact) and does NOT dispatch.
test_backfill_clears_stale_label_on_consolidated_parent() {
	setup_gh_stub
	# Open issue list returns one labelled parent that ALSO has consolidated.
	export GH_ISSUE_LIST_CHILD_JSON='[{"number": 19321, "labels": [{"name": "needs-consolidation"}, {"name": "consolidated"}]}]'
	export GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"

	# repos.json with a single pulse-enabled repo pointing at our stub slug.
	cat >"${TEST_ROOT}/repos.json" <<'JSON'
{
  "initialized_repos": [
    {"slug": "marcusquinn/aidevops", "path": "/tmp/fake-path", "pulse": true}
  ]
}
JSON
	export REPOS_JSON="${TEST_ROOT}/repos.json"

	_backfill_stale_consolidation_labels || true

	# Verify: no `gh issue create` (no child dispatched).
	if grep -q 'issue create' "$GH_LOG" 2>/dev/null; then
		print_result "t2144: backfill skips dispatch on consolidated parent" 1 \
			"gh issue create was invoked despite consolidated label"
	else
		print_result "t2144: backfill skips dispatch on consolidated parent" 0
	fi

	# Verify: `gh issue edit --remove-label needs-consolidation` was called.
	if grep -qE 'issue edit .* --remove-label needs-consolidation' "$GH_LOG" 2>/dev/null; then
		print_result "t2144: backfill auto-clears stale needs-consolidation label" 0
	else
		print_result "t2144: backfill auto-clears stale needs-consolidation label" 1 \
			"expected remove-label call not found in gh log"
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

	# t2144 regression suite
	test_worker_superseded_comments_are_filtered
	test_stale_recovery_tick_comments_are_filtered
	test_recently_closed_child_blocks_redispatch_within_grace
	test_grace_zero_restores_open_only_semantics
	test_backfill_clears_stale_label_on_consolidated_parent

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
