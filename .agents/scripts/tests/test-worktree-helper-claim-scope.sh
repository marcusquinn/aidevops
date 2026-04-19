#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worktree-helper-claim-scope.sh — t2260 regression guard.
#
# Asserts that _interactive_session_auto_claim resolves the correct issue
# number via structured sources ONLY:
#
#   1. Explicit --issue NNN arg (highest precedence)
#   2. gh<NNN> from branch name (unambiguous)
#   3. t<NNN> from branch → ref:GH#NNN in TODO.md (structured field only)
#
# The greedy brief-body scanning that grabbed historical #NNN references
# from free-form text (root cause of the t2249 mis-claim on #15114) must
# never fire. This test creates a brief body containing a decoy issue
# reference and verifies it is NOT picked up.
#
# Assertions:
#   1. t<NNN> branch with ref:GH# in TODO.md → resolves correct issue
#   2. t<NNN> branch with decoy #99999 in brief body → does NOT claim 99999
#   3. gh<NNN> branch pattern → resolves correct issue
#   4. auto-*-gh<NNN> branch pattern → resolves correct issue
#   5. Explicit --issue arg overrides branch-derived issue
#   6. Branch with no matching pattern → no claim (silent skip)
#   7. t<NNN> branch with NO ref:GH# in TODO.md → no claim

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# =============================================================================
# Sandbox setup
# =============================================================================
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

# Create a mock interactive-session-helper.sh that records claim calls
MOCK_HELPER="${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh"
mkdir -p "$(dirname "$MOCK_HELPER")"
CLAIM_LOG="${TEST_ROOT}/claim-log.txt"
cat > "$MOCK_HELPER" <<'MOCK'
#!/usr/bin/env bash
# Mock interactive-session-helper.sh — records claim calls
if [[ "${1:-}" == "claim" ]]; then
    echo "CLAIM:${2:-}:${3:-}" >> "${CLAIM_LOG_PATH}"
fi
exit 0
MOCK
chmod +x "$MOCK_HELPER"

# Create a fake git repo to satisfy git rev-parse
FAKE_REPO="${TEST_ROOT}/repo"
mkdir -p "$FAKE_REPO"
git -C "$FAKE_REPO" init -q
git -C "$FAKE_REPO" remote add origin "https://github.com/testowner/testrepo.git"
# Need at least one commit for git to work
echo "init" > "$FAKE_REPO/README.md"
git -C "$FAKE_REPO" add . && git -C "$FAKE_REPO" commit -q -m "init"

# Create TODO.md with structured ref:GH#NNN entries
cat > "$FAKE_REPO/TODO.md" <<'TODO'
## Tasks

- [ ] t5000 Fix the widget alignment bug #bugfix ~2h ref:GH#12345 logged:2026-04-18
- [ ] t5001 Add new feature for dashboard #feature ~4h logged:2026-04-18
TODO

# Create a brief that contains a decoy issue reference
mkdir -p "$FAKE_REPO/todo/tasks"
cat > "$FAKE_REPO/todo/tasks/t5000-brief.md" <<'BRIEF'
# t5000: Fix the widget alignment bug

## Context

This was discovered during the investigation of #99999 (a historical issue
that has since been resolved). Also references GH#88888 from the original
design doc and PR #77777 which introduced the regression.

## What

Fix the widget alignment.

## How

Edit src/widget.ts:42-60
BRIEF

# =============================================================================
# Source the function under test
# =============================================================================

# Unset headless vars so the function thinks we're interactive
unset FULL_LOOP_HEADLESS AIDEVOPS_HEADLESS OPENCODE_HEADLESS GITHUB_ACTIONS
unset AIDEVOPS_SESSION_ORIGIN

# Source shared constants (for colors) — guard against readonly collisions
# by setting them before sourcing
BLUE=$'\033[0;34m'
NC=$'\033[0m'
BOLD=$'\033[1m'
RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
GREEN=$'\033[0;32m'

# We need SCRIPT_DIR for the helper fallback path
SCRIPT_DIR="${TEST_SCRIPTS_DIR}"

# Extract only the _interactive_session_auto_claim function from worktree-helper.sh
# to avoid sourcing the whole file (which has side effects)
eval "$(sed -n '/^_interactive_session_auto_claim()/,/^}/p' "${TEST_SCRIPTS_DIR}/worktree-helper.sh")"

# =============================================================================
# Test helpers
# =============================================================================
reset_claim_log() {
	true > "$CLAIM_LOG"
	export CLAIM_LOG_PATH="$CLAIM_LOG"
	return 0
}

get_claimed_issue() {
	if [[ -f "$CLAIM_LOG" && -s "$CLAIM_LOG" ]]; then
		head -1 "$CLAIM_LOG" | cut -d: -f2
	else
		echo ""
	fi
	return 0
}

# Run the function in the fake repo context
run_auto_claim() {
	local branch="$1"
	local worktree_path="$2"
	local explicit_issue="${3:-}"
	reset_claim_log
	# Run in the fake repo so git rev-parse works
	(cd "$FAKE_REPO" && _interactive_session_auto_claim "$branch" "$worktree_path" "$explicit_issue")
	return 0
}

# =============================================================================
# Tests
# =============================================================================

# Test 1: t<NNN> branch with ref:GH#NNN in TODO.md → resolves 12345
run_auto_claim "feature/t5000-fix-widget" "$FAKE_REPO" ""
claimed=$(get_claimed_issue)
rc=0
[[ "$claimed" == "12345" ]] || rc=1
print_result "t5000 branch resolves ref:GH#12345 from TODO.md" "$rc" "(got: '$claimed', expected: '12345')"

# Test 2: Decoy #99999 in brief body is NOT picked up
# (same call as Test 1 — if the old greedy grep were active, it would claim 99999)
rc=0
[[ "$claimed" != "99999" ]] || rc=1
print_result "brief-body decoy #99999 is NOT claimed" "$rc" "(claimed: '$claimed')"

# Test 3: gh<NNN> branch pattern → resolves 18700
run_auto_claim "bugfix/gh18700-login-fix" "$FAKE_REPO" ""
claimed=$(get_claimed_issue)
rc=0
[[ "$claimed" == "18700" ]] || rc=1
print_result "gh<NNN> branch resolves issue 18700" "$rc" "(got: '$claimed', expected: '18700')"

# Test 4: auto-*-gh<NNN> branch pattern → resolves 19803
run_auto_claim "feature/auto-20260419-061301-gh19803" "$FAKE_REPO" ""
claimed=$(get_claimed_issue)
rc=0
[[ "$claimed" == "19803" ]] || rc=1
print_result "auto-*-gh<NNN> branch resolves issue 19803" "$rc" "(got: '$claimed', expected: '19803')"

# Test 5: Explicit --issue arg overrides branch-derived issue
run_auto_claim "bugfix/gh18700-login-fix" "$FAKE_REPO" "42"
claimed=$(get_claimed_issue)
rc=0
[[ "$claimed" == "42" ]] || rc=1
print_result "explicit --issue 42 overrides branch gh18700" "$rc" "(got: '$claimed', expected: '42')"

# Test 6: Branch with no matching pattern → no claim
run_auto_claim "feature/random-stuff" "$FAKE_REPO" ""
claimed=$(get_claimed_issue)
rc=0
[[ -z "$claimed" ]] || rc=1
print_result "unrecognised branch pattern → no claim" "$rc" "(got: '$claimed', expected: '')"

# Test 7: t<NNN> branch with NO ref:GH# in TODO.md → no claim
run_auto_claim "feature/t5001-dashboard-feature" "$FAKE_REPO" ""
claimed=$(get_claimed_issue)
rc=0
[[ -z "$claimed" ]] || rc=1
print_result "t5001 branch (no ref:GH# in TODO) → no claim" "$rc" "(got: '$claimed', expected: '')"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "--- Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failures ---"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
