#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-merge-auto-release.sh — t2413 regression guard.
#
# Asserts that `_release_interactive_claim_on_merge()` fires correctly on
# successful PR merge and short-circuits cleanly on all no-op paths.
#
# Production motivation (GH#20011, t2413):
#   After merging PR #19993 (origin:interactive, OWNER-authored), the linked
#   issue #19968 stamp had to be manually released via
#   `interactive-session-helper.sh release`. AGENTS.md already states
#   "Release is the agent's responsibility" and lists "when a PR they opened
#   merges" as a release trigger — but no code fired it automatically.
#
#   Adding `_release_interactive_claim_on_merge` to `_handle_post_merge_actions`
#   in pulse-merge.sh closes this gap. The function guards on:
#     (1) linked_issue present
#     (2) origin:interactive label on the PR
#     (3) claim stamp file exists for the issue
#   All three guards must pass before the release call fires.
#
# Tests:
#   1. Happy path: stamp exists + origin:interactive label → release called,
#      stamp removed by the mocked helper.
#   2. No-op: origin:interactive label absent → stamp untouched.
#   3. No-op: linked_issue empty → stamp untouched.
#   4. No-op: stamp file absent → release NOT called.
#
# Strategy:
#   The function is defined inline (not sourced from pulse-merge.sh) to avoid
#   the full pulse-wrapper dependency chain. Stubs replace `gh` and the
#   interactive-session-helper.sh path. CLAIM_STAMP_DIR is redirected to a
#   temp directory.
#
# Cross-references: GH#20011 / t2413 (fix), AGENTS.md "Interactive issue
# ownership", interactive-session-helper.sh::_isc_stamp_path.

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
TMP=$(mktemp -d -t t2413.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

LOGFILE="${TMP}/pulse.log"
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
# Stub for interactive-session-helper.sh used in test-pulse-merge-auto-release.sh
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
# Inline definition of _release_interactive_claim_on_merge
# (mirrors pulse-merge.sh implementation — update both if logic changes)
# =============================================================================
_release_interactive_claim_on_merge() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local pr_labels="${4:-}"

	# Guard 1: no linked issue → nothing to release
	[[ -z "$linked_issue" ]] && return 0

	# Guard 2: fetch labels if not provided by caller
	if [[ -z "$pr_labels" ]]; then
		pr_labels=$(gh pr view "$pr_number" --repo "$repo_slug" \
			--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || pr_labels=""
	fi

	# Guard 3: only fire for origin:interactive PRs
	[[ ",${pr_labels}," == *",origin:interactive,"* ]] || return 0

	# Guard 4: only fire when a claim stamp exists
	local _stamp_base="${CLAIM_STAMP_DIR:-${HOME}/.aidevops/.agent-workspace/interactive-claims}"
	local _stamp_file="${_stamp_base}/${repo_slug//\//-}-${linked_issue}.json"
	[[ -f "$_stamp_file" ]] || return 0

	echo "[pulse-wrapper] Merge pass: auto-releasing interactive claim on ${repo_slug}#${linked_issue} (PR #${pr_number} merged) — t2413" >>"$LOGFILE"
	local _isc_helper="${AGENTS_DIR:-${HOME}/.aidevops/agents}/scripts/interactive-session-helper.sh"
	if [[ -x "$_isc_helper" ]]; then
		"$_isc_helper" release "$linked_issue" "$repo_slug" >>"$LOGFILE" 2>&1 || \
			echo "[pulse-wrapper] Merge pass: interactive claim release failed for ${repo_slug}#${linked_issue} — non-fatal (t2413)" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Merge pass: interactive-session-helper.sh not found/not executable at ${_isc_helper} — skipping release for ${repo_slug}#${linked_issue} (t2413)" >>"$LOGFILE"
	fi
	return 0
}

printf '%sRunning _release_interactive_claim_on_merge tests (t2413)%s\n' \
	"$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 1 — Happy path: stamp exists + origin:interactive label → release fired
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-9901.json"
printf '{"pid":1234}\n' >"$STAMP"
GH_LABELS_RESPONSE="origin:interactive,tier:standard"

_release_interactive_claim_on_merge "42" "marcusquinn/aidevops" "9901"

if grep -q "release 9901 marcusquinn/aidevops" "$RELEASE_CALLS" 2>/dev/null; then
	pass "happy path: release called for origin:interactive PR with stamp"
else
	fail "happy path: release called for origin:interactive PR with stamp" \
		"expected 'release 9901 marcusquinn/aidevops' in release calls — got: $(cat "$RELEASE_CALLS" 2>/dev/null || printf '(empty)')"
fi

if [[ ! -f "$STAMP" ]]; then
	pass "happy path: stamp file removed by release"
else
	fail "happy path: stamp file removed by release" \
		"stamp file still exists: $STAMP"
fi

if grep -q "t2413" "$LOGFILE" 2>/dev/null; then
	pass "happy path: t2413 log line emitted"
else
	fail "happy path: t2413 log line emitted" \
		"expected t2413 in LOGFILE — got: $(cat "$LOGFILE" 2>/dev/null || printf '(empty)')"
fi

# =============================================================================
# Test 2 — No-op: origin:interactive label absent → stamp untouched
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-9902.json"
printf '{"pid":1234}\n' >"$STAMP"
GH_LABELS_RESPONSE="origin:worker,tier:standard"

_release_interactive_claim_on_merge "43" "marcusquinn/aidevops" "9902"

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
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-9903.json"
printf '{"pid":1234}\n' >"$STAMP"
GH_LABELS_RESPONSE="origin:interactive,tier:standard"

_release_interactive_claim_on_merge "44" "marcusquinn/aidevops" ""

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
# Ensure no stamp file exists for issue 9904
MISSING_STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-9904.json"
rm -f "$MISSING_STAMP"
GH_LABELS_RESPONSE="origin:interactive,tier:standard"

_release_interactive_claim_on_merge "45" "marcusquinn/aidevops" "9904"

if ! grep -q "release" "$RELEASE_CALLS" 2>/dev/null; then
	pass "no stamp file → release NOT called"
else
	fail "no stamp file → release NOT called" \
		"release was called when no stamp file existed"
fi

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
