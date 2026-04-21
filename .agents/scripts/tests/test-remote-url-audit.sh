#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-remote-url-audit.sh — t2458 regression guard.
#
# Asserts that `secret-hygiene-helper.sh scan-remotes` (Layer 3 of t2458):
#   1. detects git remotes with embedded credentials and reports HIGH severity
#   2. reports the slug/path only — never the URL value
#   3. writes a persistent advisory file to $HOME/.aidevops/advisories/
#   4. reports "no findings" for clean remotes
#   5. handles missing repos.json gracefully

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR_TEST}/../../.." && pwd)" || exit 1
HELPER="${REPO_ROOT}/.agents/scripts/secret-hygiene-helper.sh"

if [[ ! -x "$HELPER" ]]; then
	printf 'helper not found or not executable: %s\n' "$HELPER" >&2
	exit 1
fi

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
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
	[[ -n "${2:-}" ]] && printf '       %s\n' "$2"
	return 0
}

# =============================================================================
# Sandbox setup: fake HOME with repos.json pointing at test repos
# =============================================================================
if ! command -v jq >/dev/null 2>&1; then
	printf 'jq not installed — skipping test\n' >&2
	exit 0
fi

TMP=$(mktemp -d -t t2458-audit.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# Test repos
DIRTY_REPO="${TMP}/dirty-repo"
CLEAN_REPO="${TMP}/clean-repo"

mkdir -p "$DIRTY_REPO" "$CLEAN_REPO"
git -C "$DIRTY_REPO" init -q
git -C "$DIRTY_REPO" remote add origin "https://gho_FAKE1234567890abcdef@github.com/fake-org/dirty-repo.git"

git -C "$CLEAN_REPO" init -q
git -C "$CLEAN_REPO" remote add origin "git@github.com:fake-org/clean-repo.git"

# Fake HOME with repos.json
mkdir -p "${TMP}/home/.config/aidevops"
cat >"${TMP}/home/.config/aidevops/repos.json" <<JSON
{
  "initialized_repos": [
    {"path": "${DIRTY_REPO}", "slug": "fake-org/dirty-repo"},
    {"path": "${CLEAN_REPO}", "slug": "fake-org/clean-repo"},
    {"path": "${TMP}/nonexistent", "slug": "n/a"}
  ]
}
JSON

# =============================================================================
# Test 1: dirty remote detected, clean remote not flagged
# =============================================================================
echo "[test] scan-remotes detects dirty remote"

output=$(HOME="${TMP}/home" bash "$HELPER" scan-remotes 2>&1 || true)

if [[ "$output" == *"[HIGH]"* ]]; then
	pass "HIGH severity reported"
else
	fail "no HIGH severity in output" "$output"
fi

if [[ "$output" == *"fake-org/dirty-repo"* ]]; then
	pass "dirty repo slug reported"
else
	fail "dirty repo slug NOT reported" "$output"
fi

# =============================================================================
# Test 2: the URL VALUE is never emitted
# =============================================================================
echo ""
echo "[test] URL value never leaked to output"

if [[ "$output" != *"gho_FAKE1234567890abcdef"* ]]; then
	pass "token value absent from output"
else
	fail "token VALUE leaked to output!" "$output"
fi

if [[ "$output" != *"gho_FAKE1234567890abcdef@github.com"* ]]; then
	pass "full credentialed URL absent from output"
else
	fail "full credentialed URL leaked!" "$output"
fi

# =============================================================================
# Test 3: clean repo is not flagged
# =============================================================================
echo ""
echo "[test] Clean remote (SSH form) is not flagged"

if [[ "$output" != *"fake-org/clean-repo"* ]]; then
	pass "clean repo not flagged"
else
	fail "clean repo falsely flagged" "$output"
fi

# =============================================================================
# Test 4: advisory file written
# =============================================================================
echo ""
echo "[test] Advisory file written on findings"

# Glob via shell (no ls) — expands to file list or stays literal if no match.
advisory_dir="${TMP}/home/.aidevops/advisories"
advisory_files=()
if [[ -d "$advisory_dir" ]]; then
	for _af in "$advisory_dir"/remote-credentials-*.advisory; do
		[[ -f "$_af" ]] && advisory_files+=("$_af")
	done
fi

if [[ "${#advisory_files[@]}" -gt 0 ]]; then
	pass "advisory file created"
	advisory_content=$(cat "${advisory_files[0]}")
	if [[ "$advisory_content" == *"fake-org/dirty-repo"* ]]; then
		pass "advisory mentions dirty slug"
	else
		fail "advisory does not mention dirty slug" "$advisory_content"
	fi
	if [[ "$advisory_content" != *"gho_FAKE1234567890abcdef"* ]]; then
		pass "advisory does not contain credential value"
	else
		fail "advisory LEAKS credential value!" "$advisory_content"
	fi
else
	fail "advisory file NOT created" "searched: ${advisory_dir}/remote-credentials-*.advisory"
fi

# =============================================================================
# Test 5: clean sandbox (no dirty repos) reports OK
# =============================================================================
echo ""
echo "[test] Clean-only sandbox reports [OK]"

rm -rf "${TMP}/home2"
mkdir -p "${TMP}/home2/.config/aidevops"
cat >"${TMP}/home2/.config/aidevops/repos.json" <<JSON
{
  "initialized_repos": [
    {"path": "${CLEAN_REPO}", "slug": "fake-org/clean-repo"}
  ]
}
JSON

clean_output=$(HOME="${TMP}/home2" bash "$HELPER" scan-remotes 2>&1 || true)
if [[ "$clean_output" == *"[OK]"* ]]; then
	pass "clean-only sandbox reports [OK]"
else
	fail "clean-only sandbox did not report [OK]" "$clean_output"
fi

# =============================================================================
# Test 6: missing repos.json handled gracefully
# =============================================================================
echo ""
echo "[test] Missing repos.json handled gracefully"

rm -rf "${TMP}/home3"
mkdir -p "${TMP}/home3"

missing_exit=$(HOME="${TMP}/home3" bash "$HELPER" scan-remotes >/dev/null 2>&1; echo $?)
if [[ "$missing_exit" -eq 0 ]]; then
	pass "missing repos.json exits 0 (skip, not error)"
else
	fail "missing repos.json exit=$missing_exit (expected 0)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
printf '%d test(s), %d failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
