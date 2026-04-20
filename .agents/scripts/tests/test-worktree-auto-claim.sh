#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worktree-auto-claim.sh — GH#20102 regression guard.
#
# Asserts the AIDEVOPS_SKIP_AUTO_CLAIM opt-out and headless-env guards
# in _interactive_session_auto_claim (worktree-helper.sh) work correctly.
#
# Assertions:
#   1. gh-<N> branch → claim fires (baseline: auto-claim path active)
#   2. t<NNN> branch with ref:GH# in TODO.md → claim fires
#   3. Unrecognised branch prefix → no claim (non-fatal silent skip)
#   4. FULL_LOOP_HEADLESS=1 → no claim (headless guard)
#   5. AIDEVOPS_HEADLESS=1 → no claim (headless guard)
#   6. Claude_HEADLESS=1 → no claim (headless guard, GH#20102)
#   7. AIDEVOPS_SKIP_AUTO_CLAIM=1 → no claim (opt-out guard, GH#20102)

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

# Create TODO.md with a structured ref:GH#NNN entry for t7777
cat > "$FAKE_REPO/TODO.md" <<'TODO'
## Tasks

- [ ] t7777 Auto-claim worktree test fixture #framework ~1h ref:GH#20102 logged:2026-04-20
TODO

# =============================================================================
# Source the function under test
# =============================================================================

# Unset all headless and opt-out vars so we start in interactive mode
unset FULL_LOOP_HEADLESS AIDEVOPS_HEADLESS Claude_HEADLESS OPENCODE_HEADLESS GITHUB_ACTIONS
unset AIDEVOPS_SESSION_ORIGIN AIDEVOPS_SKIP_AUTO_CLAIM

# Provide colour stubs (avoid sourcing entire shared-constants.sh with side
# effects; the function only needs BLUE and NC for its echo-e output).
BLUE=$'\033[0;34m'
NC=$'\033[0m'
BOLD=$'\033[1m'
RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
GREEN=$'\033[0;32m'

# SCRIPT_DIR is used by the helper-fallback path in the function
SCRIPT_DIR="${TEST_SCRIPTS_DIR}"

# Extract the _interactive_session_auto_claim function from worktree-helper.sh
# to avoid running the script's main body (which parses $@ and has side effects).
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

# Run the function in the fake repo context with current env
run_auto_claim() {
	local branch="$1"
	local worktree_path="$2"
	local explicit_issue="${3:-}"
	reset_claim_log
	(cd "$FAKE_REPO" && _interactive_session_auto_claim "$branch" "$worktree_path" "$explicit_issue")
	return 0
}

# =============================================================================
# Ensure we start in interactive mode (no headless vars, no opt-out)
# =============================================================================
unset FULL_LOOP_HEADLESS AIDEVOPS_HEADLESS Claude_HEADLESS OPENCODE_HEADLESS GITHUB_ACTIONS
unset AIDEVOPS_SESSION_ORIGIN AIDEVOPS_SKIP_AUTO_CLAIM

# Test 1: gh-<N> branch → claim fires (baseline)
run_auto_claim "feature/gh20102-auto-claim-worktree" "$FAKE_REPO"
claimed=$(get_claimed_issue)
rc=0
[[ "$claimed" == "20102" ]] || rc=1
print_result "gh-<N> branch fires auto-claim (baseline)" "$rc" "(got: '$claimed', expected: '20102')"

# Test 2: t<NNN> branch with ref:GH# in TODO.md → claim fires
run_auto_claim "feature/t7777-auto-claim-test" "$FAKE_REPO"
claimed=$(get_claimed_issue)
rc=0
[[ "$claimed" == "20102" ]] || rc=1
print_result "t7777 branch resolves ref:GH#20102 from TODO.md" "$rc" "(got: '$claimed', expected: '20102')"

# Test 3: Unrecognised branch prefix → no claim
run_auto_claim "feature/random-work-no-issue" "$FAKE_REPO"
claimed=$(get_claimed_issue)
rc=0
[[ -z "$claimed" ]] || rc=1
print_result "unrecognised branch → no claim (silent skip)" "$rc" "(got: '$claimed', expected: '')"

# Test 4: FULL_LOOP_HEADLESS=1 → no claim
export FULL_LOOP_HEADLESS=1
run_auto_claim "feature/gh20102-auto-claim-worktree" "$FAKE_REPO"
claimed=$(get_claimed_issue)
rc=0
[[ -z "$claimed" ]] || rc=1
print_result "FULL_LOOP_HEADLESS=1 → no claim" "$rc" "(got: '$claimed', expected: '')"
unset FULL_LOOP_HEADLESS

# Test 5: AIDEVOPS_HEADLESS=1 → no claim
export AIDEVOPS_HEADLESS=1
run_auto_claim "feature/gh20102-auto-claim-worktree" "$FAKE_REPO"
claimed=$(get_claimed_issue)
rc=0
[[ -z "$claimed" ]] || rc=1
print_result "AIDEVOPS_HEADLESS=1 → no claim" "$rc" "(got: '$claimed', expected: '')"
unset AIDEVOPS_HEADLESS

# Test 6: Claude_HEADLESS=1 → no claim (GH#20102 — new guard)
export Claude_HEADLESS=1
run_auto_claim "feature/gh20102-auto-claim-worktree" "$FAKE_REPO"
claimed=$(get_claimed_issue)
rc=0
[[ -z "$claimed" ]] || rc=1
print_result "Claude_HEADLESS=1 → no claim (GH#20102)" "$rc" "(got: '$claimed', expected: '')"
unset Claude_HEADLESS

# Test 7: AIDEVOPS_SKIP_AUTO_CLAIM=1 → no claim (GH#20102 — new opt-out)
export AIDEVOPS_SKIP_AUTO_CLAIM=1
run_auto_claim "feature/gh20102-auto-claim-worktree" "$FAKE_REPO"
claimed=$(get_claimed_issue)
rc=0
[[ -z "$claimed" ]] || rc=1
print_result "AIDEVOPS_SKIP_AUTO_CLAIM=1 → no claim (GH#20102)" "$rc" "(got: '$claimed', expected: '')"
unset AIDEVOPS_SKIP_AUTO_CLAIM

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "--- Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failures ---"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
