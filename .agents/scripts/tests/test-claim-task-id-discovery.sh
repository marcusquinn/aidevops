#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-claim-task-id-discovery.sh — Unit tests for _pre_claim_discovery_pass (t2180)
#
# Validates the pre-claim discovery pass added to claim-task-id.sh that surfaces
# similar in-flight or recently-merged PRs before allocating a new task ID.
#
# Cases covered:
#   A: no PR hits → no warning, return 0 (normal claim)
#   B: hits + interactive TTY + user answers "n" → return 10 (claim aborted)
#   C: hits + interactive TTY + user answers "y" → return 0 (claim proceeds)
#   D: hits + non-interactive (worker/CI) → structured stderr warnings, return 0
#   E: gh unauthenticated/offline → fail-open, no warnings, return 0
#
# Mock strategy: a fake "gh" binary in a tmpdir is prepended to PATH.
# The fake reads from a fixture file whose path is exported as GH_MOCK_FIXTURE.
# _AIDEVOPS_CLAIM_TEST_IS_TTY and _AIDEVOPS_CLAIM_TEST_ANSWER override the
# TTY detection and user-prompt branches without requiring a real terminal.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CLAIM_SCRIPT="${SCRIPT_DIR}/../claim-task-id.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASS=0
FAIL=0
ERRORS=""

# ---------------------------------------------------------------------------
# Test framework helpers
# ---------------------------------------------------------------------------

pass() {
	local name="${1:-}"
	printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="${1:-}"
	local detail="${2:-}"
	printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$name"
	[[ -n "$detail" ]] && printf '       %s\n' "$detail"
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  - ${name}: ${detail}"
	return 0
}

# Source claim-task-id.sh to gain access to _pre_claim_discovery_pass.
# The BASH_SOURCE guard prevents main() from running on source.
_source_claim_script() {
	# shellcheck disable=SC1090
	if ! source "$CLAIM_SCRIPT" 2>/dev/null; then
		printf '%s[FATAL]%s Failed to source %s\n' "$RED" "$NC" "$CLAIM_SCRIPT" >&2
		exit 1
	fi
	return 0
}

# Create a mock "gh" binary in $1/gh that:
#   - Returns 0 for "gh auth status"
#   - Reads fixture JSON from $GH_MOCK_FIXTURE for "gh pr list"
#   - Returns 0 for anything else
_make_gh_mock() {
	local bindir="$1"
	local fixture_file="$2"
	local gh_bin="${bindir}/gh"

	cat >"$gh_bin" <<'MOCK_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
	exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
	cat "${GH_MOCK_FIXTURE}"
	exit 0
fi
exit 0
MOCK_EOF
	chmod +x "$gh_bin"
	export GH_MOCK_FIXTURE="$fixture_file"
	return 0
}

# Create a mock "gh" that returns 1 for auth status (simulates offline/unauthed)
_make_gh_mock_offline() {
	local bindir="$1"
	local gh_bin="${bindir}/gh"

	cat >"$gh_bin" <<'MOCK_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
	exit 1
fi
exit 0
MOCK_EOF
	chmod +x "$gh_bin"
	return 0
}

# Fixture JSON: two PRs with enough keyword overlap to be "relevant"
# to a title like "add video seo transcript schema agents"
# Keywords extracted: transcript(10), schema(6), agents(6), video(5)
# PR #19495: merged 2026-04-17 (within 14 days of test date 2026-04-18)
# PR #19494: open
_fixture_relevant_prs() {
	cat <<'JSON'
[
  {
    "number": 19495,
    "title": "t2167: add video-seo, transcript-seo, video-schema agents",
    "state": "MERGED",
    "mergedAt": "2026-04-17T10:00:00Z",
    "createdAt": "2026-04-16T08:00:00Z"
  },
  {
    "number": 19494,
    "title": "t2167: add video-schema, transcript agents (duplicate)",
    "state": "OPEN",
    "mergedAt": null,
    "createdAt": "2026-04-17T09:00:00Z"
  }
]
JSON
}

# ---------------------------------------------------------------------------
# Source once for all tests
# ---------------------------------------------------------------------------

_source_claim_script

# The title used in Cases A-D; chosen so keywords
# (transcript, schema, agents, video) overlap with the fixture PR titles.
_TEST_TITLE="add video seo transcript schema agents"
_TEST_SLUG="marcusquinn/aidevops"

# ---------------------------------------------------------------------------
# Case A: no hits → no warning, return 0
# ---------------------------------------------------------------------------

test_case_a_no_hits() {
	local name="A: no PR hits → no warning, return 0"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local fixture="${tmpdir}/fixture.json"
	printf '[]' >"$fixture"
	_make_gh_mock "$tmpdir" "$fixture"

	local saved_path="$PATH"
	PATH="${tmpdir}:${PATH}"

	# Clear test hooks
	unset _AIDEVOPS_CLAIM_TEST_IS_TTY _AIDEVOPS_CLAIM_TEST_ANSWER 2>/dev/null || true

	local stderr_output rc=0
	stderr_output=$(_pre_claim_discovery_pass "$_TEST_TITLE" "$_TEST_SLUG" 2>&1) \
		|| rc=$?

	PATH="$saved_path"

	if [[ $rc -eq 0 && -z "$stderr_output" ]]; then
		pass "$name"
	else
		fail "$name" "expected rc=0 empty stderr, got rc=${rc} stderr='${stderr_output}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case B: hits + interactive + user answers "n" → return 10
# ---------------------------------------------------------------------------

test_case_b_interactive_decline() {
	local name="B: hits + interactive + user 'n' → return 10 (claim aborted)"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local fixture="${tmpdir}/fixture.json"
	_fixture_relevant_prs >"$fixture"
	_make_gh_mock "$tmpdir" "$fixture"

	local saved_path="$PATH"
	PATH="${tmpdir}:${PATH}"

	export _AIDEVOPS_CLAIM_TEST_IS_TTY=1
	export _AIDEVOPS_CLAIM_TEST_ANSWER="n"

	local rc=0
	_pre_claim_discovery_pass "$_TEST_TITLE" "$_TEST_SLUG" 2>/dev/null || rc=$?

	unset _AIDEVOPS_CLAIM_TEST_IS_TTY _AIDEVOPS_CLAIM_TEST_ANSWER
	PATH="$saved_path"

	if [[ $rc -eq 10 ]]; then
		pass "$name"
	else
		fail "$name" "expected rc=10 (declined), got rc=${rc}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case C: hits + interactive + user answers "y" → return 0 (proceed)
# ---------------------------------------------------------------------------

test_case_c_interactive_confirm() {
	local name="C: hits + interactive + user 'y' → return 0 (claim proceeds)"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local fixture="${tmpdir}/fixture.json"
	_fixture_relevant_prs >"$fixture"
	_make_gh_mock "$tmpdir" "$fixture"

	local saved_path="$PATH"
	PATH="${tmpdir}:${PATH}"

	export _AIDEVOPS_CLAIM_TEST_IS_TTY=1
	export _AIDEVOPS_CLAIM_TEST_ANSWER="y"

	local rc=0
	_pre_claim_discovery_pass "$_TEST_TITLE" "$_TEST_SLUG" 2>/dev/null || rc=$?

	unset _AIDEVOPS_CLAIM_TEST_IS_TTY _AIDEVOPS_CLAIM_TEST_ANSWER
	PATH="$saved_path"

	if [[ $rc -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected rc=0 (confirmed), got rc=${rc}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case D: hits + non-interactive → structured stderr warnings, return 0
# ---------------------------------------------------------------------------

test_case_d_noninteractive_warns() {
	local name="D: hits + non-interactive → WARN lines to stderr, return 0"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local fixture="${tmpdir}/fixture.json"
	_fixture_relevant_prs >"$fixture"
	_make_gh_mock "$tmpdir" "$fixture"

	local saved_path="$PATH"
	PATH="${tmpdir}:${PATH}"

	# Ensure TTY hook is NOT set (simulates worker/CI environment)
	unset _AIDEVOPS_CLAIM_TEST_IS_TTY _AIDEVOPS_CLAIM_TEST_ANSWER 2>/dev/null || true
	export _AIDEVOPS_CLAIM_TEST_IS_TTY=0

	local stderr_output rc=0
	stderr_output=$(_pre_claim_discovery_pass "$_TEST_TITLE" "$_TEST_SLUG" 2>&1) \
		|| rc=$?

	unset _AIDEVOPS_CLAIM_TEST_IS_TTY
	PATH="$saved_path"

	local has_warn=false
	if printf '%s' "$stderr_output" | grep -q '\[claim-task-id\] WARN: similar PR found:'; then
		has_warn=true
	fi

	if [[ $rc -eq 0 && "$has_warn" == "true" ]]; then
		pass "$name"
	else
		fail "$name" "expected rc=0 with WARN lines, got rc=${rc} stderr='${stderr_output}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case E: gh unauthenticated/offline → fail-open, no warnings, return 0
# ---------------------------------------------------------------------------

test_case_e_gh_offline() {
	local name="E: gh auth fails (offline/unauthed) → fail-open, no warnings, return 0"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	_make_gh_mock_offline "$tmpdir"

	local saved_path="$PATH"
	PATH="${tmpdir}:${PATH}"

	unset _AIDEVOPS_CLAIM_TEST_IS_TTY _AIDEVOPS_CLAIM_TEST_ANSWER 2>/dev/null || true

	local stderr_output rc=0
	stderr_output=$(_pre_claim_discovery_pass "$_TEST_TITLE" "$_TEST_SLUG" 2>&1) \
		|| rc=$?

	PATH="$saved_path"

	if [[ $rc -eq 0 && -z "$stderr_output" ]]; then
		pass "$name"
	else
		fail "$name" "expected rc=0 empty stderr, got rc=${rc} stderr='${stderr_output}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

main() {
	printf 'Running claim-task-id pre-claim discovery pass tests (t2180)...\n\n'

	test_case_a_no_hits
	test_case_b_interactive_decline
	test_case_c_interactive_confirm
	test_case_d_noninteractive_warns
	test_case_e_gh_offline

	printf '\n'
	printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
	if [[ "$FAIL" -gt 0 ]]; then
		printf '\nFailed tests:%b\n' "$ERRORS"
		return 1
	fi
	return 0
}

main "$@"
