#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-canonical-trash-guard.sh — t2559 regression guard.
#
# Production failure (2026-04-20 23:50:01, GH#20205):
#   `worktree-helper.sh clean` derived its "don't touch main" anchor via:
#     _porcelain=$(git worktree list --porcelain)
#     main_worktree_path="${_porcelain%%$'\n'*}"
#     main_worktree_path="${main_worktree_path#worktree }"
#   When $_porcelain was empty (git failed, or stdout bleed from a callee),
#   $main_worktree_path became "" and the downstream
#     [[ "$worktree_path" != "$main_wt_path" ]]
#   guard reduced to [[ "$worktree_path" != "" ]] — always true for real
#   paths — so the canonical repo at ~/Git/aidevops was trashed alongside
#   the orphan worktrees. Co-incident: ANSI-coloured stdout from the same
#   helper's banner bled into arithmetic in pulse-canonical-maintenance.sh.
#
# Fix (t2559): four defensive layers at every cleanup entry point:
#   L1: empty-derivation guard in cmd_clean refuses to proceed when
#       `git worktree list --porcelain` returns empty or non-absolute paths.
#   L2: is_registered_canonical check inside trash_path() and
#       pulse-cleanup.sh _trash_or_remove() — never trash a registered canonical.
#   L3: assert_git_available at cmd_clean, _cleanup_merged_prs_for_all_repos,
#       and _stale_worktree_sweep entry — refuse cleanup when git is missing.
#   L4: ANSI-bleed fix + defense-in-depth sanitisation in
#       _stale_worktree_sweep_single_repo and _stale_worktree_sweep.
#
# This test exercises the building blocks of all four layers.

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
TMP=$(mktemp -d -t t2559.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

FAKE_REPOS_JSON="${TMP}/repos.json"
FAKE_CANONICAL="${TMP}/fake-canonical"
FAKE_ORPHAN="${TMP}/fake-orphan"
mkdir -p "$FAKE_CANONICAL" "$FAKE_ORPHAN"

# Minimal repos.json registering FAKE_CANONICAL as an initialized repo.
cat >"$FAKE_REPOS_JSON" <<EOF
{
  "initialized_repos": [
    { "path": "${FAKE_CANONICAL}", "slug": "owner/fake-canonical", "pulse": true }
  ],
  "git_parent_dirs": []
}
EOF

export AIDEVOPS_REPOS_JSON="$FAKE_REPOS_JSON"

# =============================================================================
# Source the helper under test
# =============================================================================
# shellcheck source=../canonical-guard-helper.sh
source "${SCRIPTS_DIR}/canonical-guard-helper.sh"

printf '%sRunning canonical trash-guard tests (t2559)%s\n' \
	"$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Layer 2 — is_registered_canonical
# =============================================================================

# Test 1 — positive match
if is_registered_canonical "$FAKE_CANONICAL"; then
	pass "is_registered_canonical matches a registered path"
else
	fail "is_registered_canonical matches a registered path" \
		"expected return 0 for $FAKE_CANONICAL"
fi

# Test 2 — negative match
if ! is_registered_canonical "$FAKE_ORPHAN"; then
	pass "is_registered_canonical rejects an unregistered path"
else
	fail "is_registered_canonical rejects an unregistered path" \
		"expected return 1 for $FAKE_ORPHAN"
fi

# Test 3 — empty input → fail safe (treat as canonical)
if is_registered_canonical ""; then
	pass "is_registered_canonical fails safe on empty input"
else
	fail "is_registered_canonical fails safe on empty input" \
		"expected return 0 (canonical) for empty string"
fi

# Test 4 — trailing slash on candidate resolves to same canonical
if is_registered_canonical "${FAKE_CANONICAL}/"; then
	pass "is_registered_canonical normalises trailing slashes"
else
	fail "is_registered_canonical normalises trailing slashes" \
		"expected ${FAKE_CANONICAL}/ to match ${FAKE_CANONICAL}"
fi

# Test 5 — AIDEVOPS_CANONICAL_EXTRA_PATHS extension works
EXTRA_PATH="${TMP}/extra-canonical"
mkdir -p "$EXTRA_PATH"
if AIDEVOPS_CANONICAL_EXTRA_PATHS="$EXTRA_PATH" is_registered_canonical "$EXTRA_PATH"; then
	pass "AIDEVOPS_CANONICAL_EXTRA_PATHS adds to canonical set"
else
	fail "AIDEVOPS_CANONICAL_EXTRA_PATHS adds to canonical set" \
		"expected env-supplied $EXTRA_PATH to match"
fi

# =============================================================================
# Layer 3 — assert_main_worktree_sane
# =============================================================================

# Test 6 — empty string → refuse
if ! assert_main_worktree_sane "" 2>/dev/null; then
	pass "assert_main_worktree_sane refuses empty string"
else
	fail "assert_main_worktree_sane refuses empty string" \
		"expected non-zero return on empty input"
fi

# Test 7 — non-absolute path → refuse (would indicate parse corruption)
if ! assert_main_worktree_sane "relative/path" 2>/dev/null; then
	pass "assert_main_worktree_sane refuses non-absolute path"
else
	fail "assert_main_worktree_sane refuses non-absolute path" \
		"expected non-zero return on 'relative/path'"
fi

# Test 8 — valid absolute path → accept
if assert_main_worktree_sane "/Users/x/Git/myrepo" 2>/dev/null; then
	pass "assert_main_worktree_sane accepts absolute path"
else
	fail "assert_main_worktree_sane accepts absolute path" \
		"expected zero return on '/Users/x/Git/myrepo'"
fi

# =============================================================================
# Layer 3 — assert_git_available
# =============================================================================

# Test 9 — git in PATH → succeed
if assert_git_available 2>/dev/null; then
	pass "assert_git_available succeeds when git is in PATH"
else
	fail "assert_git_available succeeds when git is in PATH" \
		"expected zero return (git should be present on test host)"
fi

# Test 10 — git removed from PATH → refuse
# Use an empty directory as PATH so no commands resolve.
EMPTY_PATH_DIR="${TMP}/empty-path"
mkdir -p "$EMPTY_PATH_DIR"
if ! PATH="$EMPTY_PATH_DIR" assert_git_available 2>/dev/null; then
	pass "assert_git_available refuses when git is missing from PATH"
else
	fail "assert_git_available refuses when git is missing from PATH" \
		"expected non-zero return when PATH lacks git"
fi

# =============================================================================
# Layer 4 — ANSI-bleed sanitisation pattern
# =============================================================================
# This test demonstrates that the sanitisation pattern applied in
# _stale_worktree_sweep (`removed="${removed//[^0-9]/}"; removed="${removed:-0}"`)
# correctly defuses a poisoned captured value. This is the exact poisoning
# pattern observed in the 2026-04-20 incident where `worktree-helper.sh clean`
# stdout bled into arithmetic.

# Test 11 — pure ANSI poisoning → normalises to 0
sanitise_count() {
	local val="$1"
	val="${val//[^0-9]/}"
	val="${val:-0}"
	printf '%s' "$val"
}

poisoned=$'\033[1mChecking for worktrees...\033[0m\nRemoving foo\n'
sanitised=$(sanitise_count "$poisoned")
if [[ "$sanitised" =~ ^[0-9]+$ ]]; then
	# Arithmetic must succeed on the sanitised value.
	result=$((10 + sanitised))
	pass "ANSI-poisoned input normalises to arithmetic-safe integer ($result)"
else
	fail "ANSI-poisoned input normalises to arithmetic-safe integer" \
		"sanitised='$sanitised' is not numeric"
fi

# Test 12 — integer-with-ANSI-reset-suffix → arithmetic-safe (documented behaviour)
# The `[^0-9]/` sanitiser keeps all digit characters, including the `0` that
# appears inside the ANSI reset sequence `\033[0m`. So `5\033[0m` normalises to
# `50`. This is intentional: the sanitiser's ONLY job is to keep arithmetic
# from crashing the pulse with `set -e` when the primary stdout-redirect fix
# fails. Exact semantic accuracy is not required — a numerically-wrong but
# arithmetic-safe count is still better than a pulse crash.
poisoned2=$'5\033[0m'
sanitised2=$(sanitise_count "$poisoned2")
if [[ "$sanitised2" =~ ^[0-9]+$ ]]; then
	result2=$((sanitised2 + 0)) # arithmetic must not crash
	pass "ANSI-suffixed integer is arithmetic-safe (got $sanitised2, arithmetic yields $result2)"
else
	fail "ANSI-suffixed integer is arithmetic-safe" \
		"got sanitised2='$sanitised2' which is not numeric"
fi

# Test 13 — empty input → default 0
sanitised3=$(sanitise_count "")
if [[ "$sanitised3" == "0" ]]; then
	pass "Empty input defaults to 0"
else
	fail "Empty input defaults to 0" "got sanitised3='$sanitised3'"
fi

# Test 13a — multi-line banner with ANSI → still arithmetic-safe
poisoned_banner=$'\033[1mChecking for worktrees with merged branches...\033[0m\nRemoving orphan-1\nRemoving orphan-2\n'
sanitised_banner=$(sanitise_count "$poisoned_banner")
if [[ "$sanitised_banner" =~ ^[0-9]*$ ]]; then
	# Whatever number we got, arithmetic must succeed.
	result_banner=$((sanitised_banner + 0))
	pass "Multi-line banner bleed is arithmetic-safe (got '$sanitised_banner', arithmetic yields $result_banner)"
else
	fail "Multi-line banner bleed is arithmetic-safe" \
		"got sanitised_banner='$sanitised_banner'"
fi

# =============================================================================
# Layer 2 integration — trash_path() refuses canonical
# =============================================================================
# Source worktree-helper.sh in a way that exercises its trash_path() but
# does not trigger its main() path (we source without invoking main).
#
# worktree-helper.sh sources shared-constants.sh and canonical-guard-helper.sh.
# Because the file has `set -euo pipefail`, we need to be careful not to
# have unset-var faults during source.

# Test 14 — trash_path() refuses a registered canonical path
# We create a fresh "canonical" dir under TMP (registered above) and verify
# trash_path declines to remove it.
#
# Note: worktree-helper.sh contains `set -euo pipefail`, so sourcing it
# re-enables strict mode even after we `set +euo pipefail` in the subshell.
# The post-source `set +e` is CRITICAL — without it, trash_path's `return 1`
# (when it refuses) would trigger errexit and abort the subshell before we
# reach the refusal-assertion branch. This is exactly the foot-gun the test
# is guarding against in production: if callers forget `set +e`, trash_path
# aborts their script instead of allowing them to handle the refusal.
# shellcheck source=../worktree-helper.sh
if (
	source "${SCRIPTS_DIR}/worktree-helper.sh" >/dev/null 2>&1
	source "${SCRIPTS_DIR}/canonical-guard-helper.sh" >/dev/null 2>&1
	set +euo pipefail # MUST be AFTER source (source re-enables set -e)

	trash_path "$FAKE_CANONICAL" 2>/dev/null
	rc=$?

	[[ $rc -ne 0 && -d "$FAKE_CANONICAL" ]]
); then
	pass "trash_path() refuses a registered canonical path"
else
	fail "trash_path() refuses a registered canonical path" \
		"expected refusal + directory preserved"
fi

# Test 15 — trash_path() allows a non-canonical path (regression guard)
# Without this test, a buggy is_registered_canonical that returns 0 for every
# input would pass test 14 but break all legitimate cleanup.
if (
	source "${SCRIPTS_DIR}/worktree-helper.sh" >/dev/null 2>&1
	source "${SCRIPTS_DIR}/canonical-guard-helper.sh" >/dev/null 2>&1
	set +euo pipefail

	trash_path "$FAKE_ORPHAN" 2>/dev/null
	rc=$?

	# Non-canonical path should trash successfully (rc=0 AND dir gone).
	# If trash CLI isn't installed, the rm -rf fallback still removes it.
	[[ $rc -eq 0 && ! -d "$FAKE_ORPHAN" ]]
); then
	pass "trash_path() allows a non-canonical path (regression guard)"
else
	fail "trash_path() allows a non-canonical path (regression guard)" \
		"expected successful trash of non-registered path"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d of %d tests failed%s\n' \
		"$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
