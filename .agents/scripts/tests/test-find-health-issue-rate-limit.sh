#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-find-health-issue-rate-limit.sh — t2687 / GH#20301 regression guard.
#
# Asserts that _find_health_issue and _resolve_health_issue_number in
# stats-health-dashboard.sh refuse to create duplicates when `gh` query
# commands fail (rate limit, network, API 5xx).
#
# Production failure (2026-04-21 UTC on marcusquinn/aidevops and fleet):
#   GraphQL rate-limit window left 19 orphaned duplicate [Supervisor:*]
#   health issues across 7 repos. The t2574 REST fallback for CREATE
#   paths made CREATE succeed under rate limit, but READ paths (gh issue
#   view, gh issue list) had no fallback and silently returned empty —
#   so the dedup lookups treated success-with-empty identically to
#   confirmed-not-found and fell through to _create_health_issue.
#
# Fix (t2687): _find_health_issue classifies gh failure (rc != 0) as
# query-failure and emits the __QUERY_FAILED__ sentinel on the lookup
# paths; _resolve_health_issue_number treats the sentinel as abstain
# (echoes empty, returns without calling _create_health_issue); and
# _update_health_issue_for_repo runs a periodic label-based dedup scan
# at most once per HEALTH_DEDUP_INTERVAL seconds (default 1h) to close
# duplicates that slipped in during past rate-limit windows.
#
# Test scenarios:
#   1. cache-hit + gh issue view fails (rc=4)     → cache preserved, cached number echoed
#   2. cache-hit + gh issue view returns CLOSED   → cache cleared, fall through
#   3. no cache + gh issue list label fails (rc=4) → sentinel emitted
#   4. no cache + gh issue list title fails (rc=4) → sentinel emitted
#   5. no cache + two issues via label search      → older closed, newer returned
#   6. _resolve_health_issue_number sees sentinel  → echo empty, no _create_health_issue call
#   7. _resolve_health_issue_number sees empty     → _create_health_issue invoked
#   8. _periodic_health_issue_dedup within interval → no-op (skips gh calls)
#   9. _periodic_health_issue_dedup past interval + failing list → state file NOT updated
#  10. _periodic_health_issue_dedup past interval + two issues    → older closed
#
# Stub strategy: define `gh` as a shell function. Shell functions take
# precedence over PATH binaries. Per-call responses are sequenced via
# STUB_GH_* arrays that the test sets before invoking the function
# under test.

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

section() {
	printf '\n%s== %s ==%s\n' "$TEST_BLUE" "$1" "$TEST_NC"
	return 0
}

# =============================================================================
# Sandbox
# =============================================================================
TMP=$(mktemp -d -t t2687.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

GH_CALLS="${TMP}/gh_calls.log"
export HOME="${TMP}/home"
mkdir -p "${HOME}/.aidevops/logs"

export LOGFILE="${TMP}/logfile.log"
: >"$LOGFILE"

# =============================================================================
# Stub controls
# =============================================================================
# Arrays pair patterns (matched as substrings of "$*") with payloads + rc.
# First pattern that matches a call wins. Default (no match) = rc 0, empty.
declare -a STUB_GH_PATTERNS=()
declare -a STUB_GH_RESPONSES=()
declare -a STUB_GH_RCS=()

reset_stubs() {
	STUB_GH_PATTERNS=()
	STUB_GH_RESPONSES=()
	STUB_GH_RCS=()
	: >"$GH_CALLS"
	return 0
}

stub_gh_for() {
	# $1 substring pattern, $2 response payload, $3 rc (default 0)
	STUB_GH_PATTERNS+=("$1")
	STUB_GH_RESPONSES+=("$2")
	STUB_GH_RCS+=("${3:-0}")
	return 0
}

# shellcheck disable=SC2317  # invoked via command-name resolution in tested function
gh() {
	local call="$*"
	printf '%s\n' "$call" >>"$GH_CALLS"
	local i
	for i in "${!STUB_GH_PATTERNS[@]}"; do
		if [[ "$call" == *"${STUB_GH_PATTERNS[$i]}"* ]]; then
			if [[ -n "${STUB_GH_RESPONSES[$i]}" ]]; then
				printf '%s' "${STUB_GH_RESPONSES[$i]}"
			fi
			return "${STUB_GH_RCS[$i]}"
		fi
	done
	# Default: success with no output
	return 0
}

# Stub _unpin_health_issue and _create_health_issue so we can assert on
# call counts without hitting the GitHub API. Placed before sourcing so
# the sourced file sees them as pre-defined; the include guard prevents
# the module from redefining them after source (no — the module DOES
# redefine them). So we must override AFTER source.
# Track invocations via counter files in $TMP.

# =============================================================================
# Source the unit under test
# =============================================================================
# The stats-health-dashboard.sh module has an include guard and is intended
# to be sourced by stats-functions.sh. We source it directly — it doesn't
# actually exercise the orchestrator's bootstrap constants at parse time.
# shellcheck source=../stats-health-dashboard.sh
source "${SCRIPTS_DIR}/stats-health-dashboard.sh"

# Override _unpin_health_issue and _create_health_issue after source —
# the module defines them, and we want to observe rather than execute.
CREATE_CALLS="${TMP}/create_calls.log"
UNPIN_CALLS="${TMP}/unpin_calls.log"
: >"$CREATE_CALLS"
: >"$UNPIN_CALLS"

# shellcheck disable=SC2317
_unpin_health_issue() {
	printf '%s\n' "$*" >>"$UNPIN_CALLS"
	return 0
}

# shellcheck disable=SC2317
_create_health_issue() {
	printf '%s\n' "$*" >>"$CREATE_CALLS"
	echo "99999"
	return 0
}

# =============================================================================
# Helpers
# =============================================================================
create_count() { wc -l <"$CREATE_CALLS" | tr -d ' '; return 0; }
gh_call_count() { wc -l <"$GH_CALLS" | tr -d ' '; return 0; }

# Fixed fixture args
REPO="owner/repo"
RUNNER_USER="alice"
RUNNER_ROLE="supervisor"
RUNNER_PREFIX="[Supervisor:alice]"
ROLE_LABEL="supervisor"
ROLE_COLOR="0E8A16"
ROLE_DESC="Supervisor runner"
ROLE_DISPLAY="Supervisor"
CACHE_FILE="${HOME}/.aidevops/logs/health-issue-alice-supervisor-owner-repo"

setup_cache() { echo "$1" >"$CACHE_FILE"; return 0; }
clear_cache() { rm -f "$CACHE_FILE"; return 0; }

# =============================================================================
# Scenarios
# =============================================================================
section "Scenario 1: cache-hit + gh view fails (rc=4) → cache preserved"
reset_stubs
setup_cache "42"
stub_gh_for "issue view 42" "" 4
result=$(_find_health_issue "$REPO" "$RUNNER_USER" "$RUNNER_ROLE" "$RUNNER_PREFIX" "$ROLE_LABEL" "$ROLE_DISPLAY" "$CACHE_FILE")
if [[ "$result" == "42" ]]; then
	pass "echoes cached number when view fails"
else
	fail "echoes cached number when view fails" "got '$result'"
fi
if [[ -f "$CACHE_FILE" ]] && [[ "$(cat "$CACHE_FILE")" == "42" ]]; then
	pass "cache file preserved after view failure"
else
	fail "cache file preserved after view failure" "file missing or content changed"
fi
if ! grep -q "issue list" "$GH_CALLS"; then
	pass "skips label/title dedup scans when cache-view fails (reduces API load)"
else
	fail "skips label/title dedup scans when cache-view fails" "saw list call: $(grep 'issue list' "$GH_CALLS")"
fi

section "Scenario 2: cache-hit + gh view returns CLOSED → cache cleared, falls through"
reset_stubs
setup_cache "42"
stub_gh_for "issue view 42" "CLOSED" 0
stub_gh_for "issue list --repo ${REPO} --label supervisor --label alice" "[]" 0
stub_gh_for "issue list --repo ${REPO} --search" "" 0
result=$(_find_health_issue "$REPO" "$RUNNER_USER" "$RUNNER_ROLE" "$RUNNER_PREFIX" "$ROLE_LABEL" "$ROLE_DISPLAY" "$CACHE_FILE")
if [[ "$result" == "" ]]; then
	pass "echoes empty after CLOSED cached issue clears"
else
	fail "echoes empty after CLOSED cached issue clears" "got '$result'"
fi
if [[ ! -f "$CACHE_FILE" ]]; then
	pass "cache file removed when issue is CLOSED"
else
	fail "cache file removed when issue is CLOSED" "file still exists"
fi

section "Scenario 3: no cache + label list fails (rc=4) → __QUERY_FAILED__ sentinel"
reset_stubs
clear_cache
stub_gh_for "issue list --repo ${REPO} --label supervisor --label alice" "" 4
result=$(_find_health_issue "$REPO" "$RUNNER_USER" "$RUNNER_ROLE" "$RUNNER_PREFIX" "$ROLE_LABEL" "$ROLE_DISPLAY" "$CACHE_FILE")
if [[ "$result" == "__QUERY_FAILED__" ]]; then
	pass "emits __QUERY_FAILED__ sentinel when label lookup fails"
else
	fail "emits __QUERY_FAILED__ sentinel when label lookup fails" "got '$result'"
fi
if ! grep -q "issue list --repo ${REPO} --search" "$GH_CALLS"; then
	pass "skips title search after label lookup fails (reduces API load)"
else
	fail "skips title search after label lookup fails" "saw title search"
fi

section "Scenario 4: no cache + label empty + title fails (rc=4) → sentinel"
reset_stubs
clear_cache
stub_gh_for "issue list --repo ${REPO} --label supervisor --label alice" "[]" 0
stub_gh_for "issue list --repo ${REPO} --search" "" 4
result=$(_find_health_issue "$REPO" "$RUNNER_USER" "$RUNNER_ROLE" "$RUNNER_PREFIX" "$ROLE_LABEL" "$ROLE_DISPLAY" "$CACHE_FILE")
if [[ "$result" == "__QUERY_FAILED__" ]]; then
	pass "emits __QUERY_FAILED__ when title lookup fails"
else
	fail "emits __QUERY_FAILED__ when title lookup fails" "got '$result'"
fi

section "Scenario 5: no cache + label returns two issues → older closed, newer returned"
reset_stubs
clear_cache
two_issues='[{"number":50,"title":"[Supervisor:alice] foo"},{"number":42,"title":"[Supervisor:alice] bar"}]'
stub_gh_for "issue list --repo ${REPO} --label supervisor --label alice" "$two_issues" 0
result=$(_find_health_issue "$REPO" "$RUNNER_USER" "$RUNNER_ROLE" "$RUNNER_PREFIX" "$ROLE_LABEL" "$ROLE_DISPLAY" "$CACHE_FILE")
if [[ "$result" == "50" ]]; then
	pass "returns newest (highest number) issue"
else
	fail "returns newest (highest number) issue" "got '$result'"
fi
if grep -q "issue close 42" "$GH_CALLS"; then
	pass "closes older duplicate #42"
else
	fail "closes older duplicate #42" "no close call for 42 in: $(cat "$GH_CALLS")"
fi

section "Scenario 6: _resolve_health_issue_number sees __QUERY_FAILED__ → no create"
reset_stubs
clear_cache
stub_gh_for "issue list --repo ${REPO} --label supervisor --label alice" "" 4
result=$(_resolve_health_issue_number "$REPO" "$RUNNER_USER" "$RUNNER_ROLE" "$RUNNER_PREFIX" \
	"$ROLE_LABEL" "$ROLE_COLOR" "$ROLE_DESC" "$ROLE_DISPLAY" "$CACHE_FILE")
if [[ -z "$result" ]]; then
	pass "returns empty on sentinel (caller skips update)"
else
	fail "returns empty on sentinel" "got '$result'"
fi
if [[ "$(create_count)" == "0" ]]; then
	pass "does NOT call _create_health_issue under query failure"
else
	fail "does NOT call _create_health_issue under query failure" "_create_health_issue was called"
fi

section "Scenario 7: _resolve_health_issue_number empty-not-failed → create"
reset_stubs
clear_cache
stub_gh_for "issue list --repo ${REPO} --label supervisor --label alice" "[]" 0
stub_gh_for "issue list --repo ${REPO} --search" "" 0
: >"$CREATE_CALLS"
result=$(_resolve_health_issue_number "$REPO" "$RUNNER_USER" "$RUNNER_ROLE" "$RUNNER_PREFIX" \
	"$ROLE_LABEL" "$ROLE_COLOR" "$ROLE_DESC" "$ROLE_DISPLAY" "$CACHE_FILE")
if [[ "$result" == "99999" ]]; then
	pass "returns new issue number from _create_health_issue stub"
else
	fail "returns new issue number from _create_health_issue stub" "got '$result'"
fi
if [[ "$(create_count)" == "1" ]]; then
	pass "calls _create_health_issue exactly once when confirmed-not-found"
else
	fail "calls _create_health_issue exactly once" "call count=$(create_count)"
fi

section "Scenario 8: _periodic_health_issue_dedup within interval → no-op"
reset_stubs
state_file="${HOME}/.aidevops/logs/health-dedup-last-scan-alice-supervisor-owner-repo"
touch "$state_file"  # just-scanned
_periodic_health_issue_dedup "$REPO" "$RUNNER_USER" "$RUNNER_ROLE" "$ROLE_LABEL" "$ROLE_DISPLAY" "42"
if [[ "$(gh_call_count)" == "0" ]]; then
	pass "makes zero gh calls when within HEALTH_DEDUP_INTERVAL"
else
	fail "makes zero gh calls when within HEALTH_DEDUP_INTERVAL" "saw $(gh_call_count) calls"
fi

section "Scenario 9: periodic dedup past interval + list fails → state file NOT updated"
reset_stubs
state_file="${HOME}/.aidevops/logs/health-dedup-last-scan-alice-supervisor-owner-repo"
touch -t 202001010000 "$state_file"  # stale
stub_gh_for "issue list --repo ${REPO} --label supervisor --label alice" "" 4
orig_mtime=$(stat -c %Y "$state_file" 2>/dev/null || stat -f %m "$state_file" 2>/dev/null)
_periodic_health_issue_dedup "$REPO" "$RUNNER_USER" "$RUNNER_ROLE" "$ROLE_LABEL" "$ROLE_DISPLAY" "42"
new_mtime=$(stat -c %Y "$state_file" 2>/dev/null || stat -f %m "$state_file" 2>/dev/null)
if [[ "$orig_mtime" == "$new_mtime" ]]; then
	pass "state file mtime unchanged after list failure (retry next cycle)"
else
	fail "state file mtime unchanged after list failure" "orig=$orig_mtime new=$new_mtime"
fi

section "Scenario 10: periodic dedup past interval + two issues → older closed, state updated"
reset_stubs
state_file="${HOME}/.aidevops/logs/health-dedup-last-scan-alice-supervisor-owner-repo"
touch -t 202001010000 "$state_file"  # stale
two_issues='[{"number":50,"title":"[Supervisor:alice] foo"},{"number":42,"title":"[Supervisor:alice] bar"}]'
stub_gh_for "issue list --repo ${REPO} --label supervisor --label alice" "$two_issues" 0
_periodic_health_issue_dedup "$REPO" "$RUNNER_USER" "$RUNNER_ROLE" "$ROLE_LABEL" "$ROLE_DISPLAY" "50"
if grep -q "issue close 42" "$GH_CALLS"; then
	pass "periodic dedup closes older duplicate (kept #50)"
else
	fail "periodic dedup closes older duplicate" "no close for 42 in: $(cat "$GH_CALLS")"
fi
# State file should be touched to "now" — verify it's newer than the stale mtime
new_mtime=$(stat -c %Y "$state_file" 2>/dev/null || stat -f %m "$state_file" 2>/dev/null)
now=$(date +%s)
if ((now - new_mtime < 60)); then
	pass "state file touched after successful dedup (within last 60s)"
else
	fail "state file touched after successful dedup" "new_mtime=$new_mtime now=$now"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n%s== Summary ==%s\n' "$TEST_BLUE" "$TEST_NC"
if ((TESTS_FAILED > 0)); then
	printf '  %s%d failed%s of %d tests\n' "$TEST_RED" "$TESTS_FAILED" "$TEST_NC" "$TESTS_RUN"
	exit 1
fi
printf '  %sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
exit 0
