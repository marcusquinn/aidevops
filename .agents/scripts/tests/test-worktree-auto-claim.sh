#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worktree-auto-claim.sh — GH#20102 regression guard.
#
# Asserts that _interactive_session_auto_claim in worktree-helper.sh
# fires (or correctly skips) under the five key scenarios:
#
#   1. tNNN branch with ref:GH#NNN in TODO.md → claim fires
#   2. gh<NNN>-* branch pattern (direct issue number) → claim fires
#   3. Unparseable branch prefix → no claim
#   4. Headless env var set (FULL_LOOP_HEADLESS or Claude_HEADLESS) → no claim
#   5. AIDEVOPS_SKIP_AUTO_CLAIM=1 → no claim
#
# Failure history: GH#20102 — worktree creation race window between
# worktree add and manual interactive-session-helper.sh claim call. The
# auto-claim was wired but the opt-out and Claude_HEADLESS check were
# missing, making scripted and headless paths unreliable.

# NOTE: not using `set -e` intentionally — negative assertions require
# capturing non-zero exits. Each assertion uses explicit if/then instead.
set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# NOTE: NOT readonly — shared-constants.sh (transitively sourced by
# worktree-helper.sh) declares `readonly RED/GREEN/RESET` and the
# collision under set -e silently kills the test shell. Use plain vars.
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
# Setup: sandbox HOME, fake git repo, claim record, stub helper
# =============================================================================
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" \
	"${HOME}/.aidevops/.agent-workspace/supervisor" \
	"${HOME}/.aidevops/.agent-workspace/interactive-claims" \
	"${HOME}/.aidevops/agents/scripts"

# Fake git repo: remote pointing to a resolvable GitHub slug + TODO.md with
# a task entry that maps t9901 → GH#42.
FAKE_REPO="${TEST_ROOT}/fake-repo"
git init "$FAKE_REPO" --quiet 2>/dev/null || git init "$FAKE_REPO"
git -C "$FAKE_REPO" config user.email "test@test.com"
git -C "$FAKE_REPO" config user.name "Test User"
git -C "$FAKE_REPO" remote add origin "git@github.com:testowner/testrepo.git"
git -C "$FAKE_REPO" commit --allow-empty --no-gpg-sign -m "init" --quiet

# Seed TODO.md: t9901 maps to GH#42
cat >"${FAKE_REPO}/TODO.md" <<'EOF'
- [ ] t9901 Test auto-claim task ref:GH#42 #auto-dispatch ~1h
EOF

# Claim record: each claim call appends the issue number here.
CLAIM_RECORD="${TEST_ROOT}/claim-record"
true >"${CLAIM_RECORD}"

# Stub interactive-session-helper.sh: records claimed issue number, returns 0.
# Preferred over SCRIPT_DIR copy because HOME is sandboxed to TEST_ROOT.
# ${CLAIM_RECORD} is expanded NOW (unquoted heredoc) so the path is embedded.
cat >"${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "claim" ]]; then
    echo "\${2:-}" >> "${CLAIM_RECORD}"
fi
exit 0
STUB
chmod +x "${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh"

# Source worktree-helper.sh to make _interactive_session_auto_claim available.
# main() defaults to "help" which prints usage — side-effect-free.
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/worktree-helper.sh" >/dev/null 2>&1
set +e

# Enter the fake repo so `git rev-parse --show-toplevel` returns FAKE_REPO.
pushd "$FAKE_REPO" >/dev/null || true

reset_record() { true >"${CLAIM_RECORD}"; return 0; }
last_claimed() { tail -1 "${CLAIM_RECORD}" 2>/dev/null || true; return 0; }

# Ensure no headless env vars are set for the positive tests.
# Workers run with AIDEVOPS_HEADLESS=true — this must be unset to simulate
# an interactive session in tests 1, 2, and 3.
_simulate_interactive() {
	unset FULL_LOOP_HEADLESS AIDEVOPS_HEADLESS OPENCODE_HEADLESS Claude_HEADLESS
	unset GITHUB_ACTIONS AIDEVOPS_SESSION_ORIGIN AIDEVOPS_SKIP_AUTO_CLAIM
	return 0
}

# =============================================================================
# Test 1: tNNN branch → resolve ref:GH#NNN from TODO.md → claim fires
# =============================================================================
reset_record
_simulate_interactive
_interactive_session_auto_claim "feature/t9901-something" "$FAKE_REPO" ""
_claimed="$(last_claimed)"
if [[ "$_claimed" == "42" ]]; then
	print_result "tNNN branch → ref:GH#42 resolved and claimed" 0
else
	print_result "tNNN branch → ref:GH#42 resolved and claimed" 1 \
		"(claimed: '${_claimed}', expected: 42)"
fi

# =============================================================================
# Test 2: gh<NNN>-* branch → direct issue number → claim fires
# =============================================================================
reset_record
_simulate_interactive
_interactive_session_auto_claim "feature/gh99-some-feature" "$FAKE_REPO" ""
_claimed="$(last_claimed)"
if [[ "$_claimed" == "99" ]]; then
	print_result "gh<NNN> branch → direct issue claimed" 0
else
	print_result "gh<NNN> branch → direct issue claimed" 1 \
		"(claimed: '${_claimed}', expected: 99)"
fi

# =============================================================================
# Test 3: unparseable branch → no claim
# =============================================================================
reset_record
_simulate_interactive
_interactive_session_auto_claim "feature/no-issue-ref" "$FAKE_REPO" ""
_claimed="$(last_claimed)"
if [[ -z "$_claimed" ]]; then
	print_result "unparseable branch → no claim" 0
else
	print_result "unparseable branch → no claim" 1 \
		"(claimed: '${_claimed}', expected empty)"
fi

# =============================================================================
# Test 4: headless env vars → no claim
# =============================================================================
# 4a FULL_LOOP_HEADLESS
reset_record
FULL_LOOP_HEADLESS=1
export FULL_LOOP_HEADLESS
_interactive_session_auto_claim "feature/gh99-some-feature" "$FAKE_REPO" ""
unset FULL_LOOP_HEADLESS
_claimed="$(last_claimed)"
if [[ -z "$_claimed" ]]; then
	print_result "FULL_LOOP_HEADLESS=1 → no claim" 0
else
	print_result "FULL_LOOP_HEADLESS=1 → no claim" 1 \
		"(claimed: '${_claimed}', expected empty)"
fi

# 4b Claude_HEADLESS (added in GH#20102)
reset_record
Claude_HEADLESS=1
export Claude_HEADLESS
_interactive_session_auto_claim "feature/gh99-some-feature" "$FAKE_REPO" ""
unset Claude_HEADLESS
_claimed="$(last_claimed)"
if [[ -z "$_claimed" ]]; then
	print_result "Claude_HEADLESS=1 → no claim" 0
else
	print_result "Claude_HEADLESS=1 → no claim" 1 \
		"(claimed: '${_claimed}', expected empty)"
fi

# =============================================================================
# Test 5: AIDEVOPS_SKIP_AUTO_CLAIM=1 → no claim (opt-out, GH#20102)
# =============================================================================
reset_record
AIDEVOPS_SKIP_AUTO_CLAIM=1
export AIDEVOPS_SKIP_AUTO_CLAIM
_interactive_session_auto_claim "feature/gh99-some-feature" "$FAKE_REPO" ""
unset AIDEVOPS_SKIP_AUTO_CLAIM
_claimed="$(last_claimed)"
if [[ -z "$_claimed" ]]; then
	print_result "AIDEVOPS_SKIP_AUTO_CLAIM=1 → no claim" 0
else
	print_result "AIDEVOPS_SKIP_AUTO_CLAIM=1 → no claim" 1 \
		"(claimed: '${_claimed}', expected empty)"
fi

popd >/dev/null || true

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "---"
printf '%d tests run, %d failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
