#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-full-loop-merge-auto-release.sh — t2429 regression guard.
#
# Asserts that `release_interactive_claim_on_merge()` from
# shared-claim-lifecycle.sh fires correctly when called from the
# full-loop-helper.sh merge path. Tests the shared library directly
# (sourced, not inlined) to ensure extraction didn't break behaviour.
#
# Production motivation (GH#20067, t2429):
#   full-loop-helper.sh merge did NOT fire _release_interactive_claim_on_merge
#   after a successful gh pr merge. That function was only called from
#   pulse-merge.sh. Result: interactive sessions that merged via
#   full-loop-helper.sh left stale claim stamps and status:in-review labels.
#   The fix extracts the function to shared-claim-lifecycle.sh and calls it
#   from both merge paths.
#
# Tests:
#   1. Happy path: stamp exists + origin:interactive label → release called,
#      stamp removed by the mocked helper.
#   2. No-op: origin:worker label (not origin:interactive) → stamp untouched.
#   3. No-op: linked_issue empty → stamp untouched, no API calls.
#   4. No-op: stamp file absent → release NOT called.
#   5. Idempotency: calling release twice on same issue → second call is no-op.
#   6. Backward compat: underscore-prefixed alias works identically.
#
# Strategy:
#   Sources shared-claim-lifecycle.sh directly (the real extraction target).
#   Stubs replace `gh` and interactive-session-helper.sh. CLAIM_STAMP_DIR is
#   redirected to a temp directory.
#
# Cross-references: t2413 (original pulse-merge implementation),
#   t2429/GH#20067 (extraction + full-loop-helper parity),
#   test-pulse-merge-auto-release.sh (parallel test for the pulse-merge path).

set -uo pipefail

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
TMP=$(mktemp -d -t t2429.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

LOGFILE="${TMP}/merge.log"
export LOGFILE

CLAIM_STAMP_DIR="${TMP}/interactive-claims"
mkdir -p "$CLAIM_STAMP_DIR"
export CLAIM_STAMP_DIR

# Track release calls — must be exported so the fake helper subprocess can append to it
RELEASE_CALLS="${TMP}/release_calls.log"
export RELEASE_CALLS

# Fake interactive-session-helper.sh that records calls and removes stamp file
FAKE_ISC="${TMP}/interactive-session-helper.sh"
cat >"$FAKE_ISC" <<'FAKE_EOF'
#!/usr/bin/env bash
# Stub for interactive-session-helper.sh used in test-full-loop-merge-auto-release.sh
action="$1"
issue="$2"
slug="$3"
printf '%s %s %s\n' "$action" "$issue" "$slug" >>"${RELEASE_CALLS}"
if [[ "$action" == "release" ]]; then
	stamp="${CLAIM_STAMP_DIR}/${slug//\//-}-${issue}.json"
	rm -f "$stamp"
fi
exit 0
FAKE_EOF
chmod +x "$FAKE_ISC"

AGENTS_DIR="${TMP}/agents"
mkdir -p "${AGENTS_DIR}/scripts"
cp "$FAKE_ISC" "${AGENTS_DIR}/scripts/interactive-session-helper.sh"
export AGENTS_DIR

# =============================================================================
# gh stub — returns controlled label output for pr view --json labels
# =============================================================================
GH_CALLS="${TMP}/gh_calls.log"
# The labels variable is set per-test to control what labels are returned.
GH_LABELS_RESPONSE=""

gh() {
	printf '%s\n' "$*" >>"${GH_CALLS}"
	if [[ "$1" == "pr" && "$2" == "view" ]]; then
		# Return labels for --json labels --jq ... query
		printf '%s\n' "$GH_LABELS_RESPONSE"
		return 0
	fi
	return 0
}
export -f gh

# =============================================================================
# Source the REAL shared-claim-lifecycle.sh (the extraction target)
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/shared-claim-lifecycle.sh"

printf '%sRunning shared-claim-lifecycle / full-loop merge auto-release tests (t2429)%s\n' \
	"$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 1 — Happy path: stamp exists + origin:interactive label → release fired
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-8801.json"
printf '{"pid":1234}\n' >"$STAMP"
GH_LABELS_RESPONSE="origin:interactive,tier:standard"

release_interactive_claim_on_merge "50" "marcusquinn/aidevops" "8801"

if grep -q "release 8801 marcusquinn/aidevops" "$RELEASE_CALLS" 2>/dev/null; then
	pass "happy path: release called for origin:interactive PR with stamp"
else
	fail "happy path: release called for origin:interactive PR with stamp" \
		"expected 'release 8801 marcusquinn/aidevops' in release calls — got: $(cat "$RELEASE_CALLS" 2>/dev/null || printf '(empty)')"
fi

if [[ ! -f "$STAMP" ]]; then
	pass "happy path: stamp file removed by release"
else
	fail "happy path: stamp file removed by release" \
		"stamp file still exists: $STAMP"
fi

if grep -q "t2413/t2429" "$LOGFILE" 2>/dev/null; then
	pass "happy path: t2413/t2429 log line emitted"
else
	fail "happy path: t2413/t2429 log line emitted" \
		"expected t2413/t2429 in LOGFILE — got: $(cat "$LOGFILE" 2>/dev/null || printf '(empty)')"
fi

# =============================================================================
# Test 2 — No-op: origin:worker label (not origin:interactive) → stamp untouched
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-8802.json"
printf '{"pid":1234}\n' >"$STAMP"
GH_LABELS_RESPONSE="origin:worker,tier:standard"

release_interactive_claim_on_merge "51" "marcusquinn/aidevops" "8802"

if [[ -f "$STAMP" ]]; then
	pass "no origin:interactive label → stamp untouched"
else
	fail "no origin:interactive label → stamp untouched" \
		"stamp was removed when origin:interactive label was absent"
fi

if ! grep -q "release" "$RELEASE_CALLS" 2>/dev/null; then
	pass "no origin:interactive label → release NOT called"
else
	fail "no origin:interactive label → release NOT called" \
		"release was called when origin:interactive label was absent"
fi

# =============================================================================
# Test 3 — No-op: linked_issue empty → stamp untouched, no API calls
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-8803.json"
printf '{"pid":1234}\n' >"$STAMP"
GH_LABELS_RESPONSE="origin:interactive,tier:standard"

release_interactive_claim_on_merge "52" "marcusquinn/aidevops" ""

if [[ -f "$STAMP" ]]; then
	pass "empty linked_issue → stamp untouched"
else
	fail "empty linked_issue → stamp untouched" \
		"stamp was removed when linked_issue was empty"
fi

if [[ ! -s "$GH_CALLS" ]]; then
	pass "empty linked_issue → no gh API calls made"
else
	fail "empty linked_issue → no gh API calls made" \
		"gh was called when linked_issue was empty: $(cat "$GH_CALLS" 2>/dev/null)"
fi

# =============================================================================
# Test 4 — No-op: stamp file absent → release NOT called
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
MISSING_STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-8804.json"
rm -f "$MISSING_STAMP"
GH_LABELS_RESPONSE="origin:interactive,tier:standard"

release_interactive_claim_on_merge "53" "marcusquinn/aidevops" "8804"

if ! grep -q "release" "$RELEASE_CALLS" 2>/dev/null; then
	pass "no stamp file → release NOT called"
else
	fail "no stamp file → release NOT called" \
		"release was called when no stamp file existed"
fi

# =============================================================================
# Test 5 — Idempotency: calling release twice → second call is no-op
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-8805.json"
printf '{"pid":1234}\n' >"$STAMP"
GH_LABELS_RESPONSE="origin:interactive,tier:standard"

release_interactive_claim_on_merge "54" "marcusquinn/aidevops" "8805"
release_interactive_claim_on_merge "54" "marcusquinn/aidevops" "8805"

# Count release calls — should be exactly 1 (second call short-circuits on missing stamp)
CALL_COUNT=$(grep -c "release 8805" "$RELEASE_CALLS" 2>/dev/null || printf '0')
if [[ "$CALL_COUNT" -eq 1 ]]; then
	pass "idempotency: release called exactly once on double invocation"
else
	fail "idempotency: release called exactly once on double invocation" \
		"expected 1 release call, got $CALL_COUNT"
fi

# =============================================================================
# Test 6 — Backward compat: underscore-prefixed alias works identically
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-8806.json"
printf '{"pid":1234}\n' >"$STAMP"
GH_LABELS_RESPONSE="origin:interactive,tier:standard"

_release_interactive_claim_on_merge "55" "marcusquinn/aidevops" "8806"

if grep -q "release 8806 marcusquinn/aidevops" "$RELEASE_CALLS" 2>/dev/null; then
	pass "backward compat: underscore-prefixed alias fires release"
else
	fail "backward compat: underscore-prefixed alias fires release" \
		"expected 'release 8806 marcusquinn/aidevops' in release calls — got: $(cat "$RELEASE_CALLS" 2>/dev/null || printf '(empty)')"
fi

if [[ ! -f "$STAMP" ]]; then
	pass "backward compat: stamp file removed by underscore-prefixed alias"
else
	fail "backward compat: stamp file removed by underscore-prefixed alias" \
		"stamp file still exists: $STAMP"
fi

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d of %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
