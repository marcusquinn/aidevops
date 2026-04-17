#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-opencode-symlink-cleanup.sh — t2172 regression guard.
#
# Asserts that `agent-sources-helper.sh cleanup-broken-symlinks` removes
# dangling symlinks from the four OpenCode runtime directories
# (`command/`, `agent/`, `skills/`, `tool/`) without touching regular files
# or symlinks whose targets still resolve.
#
# Production failure (t2172):
#   When a user deletes or moves a private agent-source clone WITHOUT going
#   through `agent-sources-helper.sh remove`, the slash-command symlinks in
#   `~/.config/opencode/command/` become orphans. OpenCode parses that dir
#   at session start and fails on the first broken entry with "Failed to
#   parse command …", which blocks new sessions entirely.
#
# Fix (t2172): new `cleanup_broken_command_symlinks()` helper + the
# `cleanup-broken-symlinks` subcommand, wired into `cmd_sync`, `cmd_add`,
# `cmd_remove`, `aidevops update`, and `aidevops-update-check.sh`.
#
# Tests:
#   1. Broken symlink in `command/` is removed.
#   2. Broken symlink in nested `skills/<name>/SKILL.md` (depth 2) is removed.
#   3. Live symlink (target exists) is preserved.
#   4. Regular file (not a symlink) is preserved.
#   5. Missing runtime dirs do not cause an error.
#   6. Second run is idempotent and exits 0.
#   7. Symbolic count: removed exactly N broken entries, preserved all others.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/agent-sources-helper.sh"

if [[ ! -x "${HELPER}" ]]; then
	printf 'ERROR: helper not found or not executable: %s\n' "${HELPER}" >&2
	exit 1
fi

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
# Sandbox setup — isolate HOME so we never touch the real ~/.config/opencode
# =============================================================================
TMP=$(mktemp -d -t t2172.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

FAKE_HOME="${TMP}/home"
OC_BASE="${FAKE_HOME}/.config/opencode"
mkdir -p "${OC_BASE}/command" "${OC_BASE}/agent" \
	"${OC_BASE}/skills/valid-skill" "${OC_BASE}/skills/broken-skill" \
	"${OC_BASE}/tool"

# Target that exists (for live symlinks)
LIVE_TARGET="${TMP}/live-target.md"
printf '# live\n' >"${LIVE_TARGET}"

# Target that does NOT exist (for broken symlinks)
MISSING_TARGET="${TMP}/does-not-exist.md"

# Regular file (not a symlink)
REGULAR_FILE="${OC_BASE}/command/real-file.md"
printf '# regular\n' >"${REGULAR_FILE}"

# Live symlink in command/
LIVE_SYMLINK="${OC_BASE}/command/live-command.md"
ln -s "${LIVE_TARGET}" "${LIVE_SYMLINK}"

# Broken symlink in command/ (the session-blocking case)
BROKEN_COMMAND="${OC_BASE}/command/broken-command.md"
ln -s "${MISSING_TARGET}" "${BROKEN_COMMAND}"

# Broken symlink in skills/ at depth 2 (matches real skills layout)
BROKEN_SKILL="${OC_BASE}/skills/broken-skill/SKILL.md"
ln -s "${MISSING_TARGET}" "${BROKEN_SKILL}"

# Live symlink in skills/ at depth 2 (should survive)
LIVE_SKILL="${OC_BASE}/skills/valid-skill/SKILL.md"
ln -s "${LIVE_TARGET}" "${LIVE_SKILL}"

# Broken symlink in agent/
BROKEN_AGENT="${OC_BASE}/agent/broken-agent.md"
ln -s "${MISSING_TARGET}" "${BROKEN_AGENT}"

printf '%s[SETUP]%s Sandbox: %s\n' "$TEST_BLUE" "$TEST_NC" "$FAKE_HOME"
printf '  live symlinks  : 2  (command/live-command.md, skills/valid-skill/SKILL.md)\n'
printf '  broken symlinks: 3  (command/broken-command.md, skills/broken-skill/SKILL.md, agent/broken-agent.md)\n'
printf '  regular files  : 1  (command/real-file.md)\n'
printf '\n'

# =============================================================================
# Test 1: First run removes broken symlinks
# =============================================================================
printf '%s[TEST 1]%s First run cleans broken symlinks\n' "$TEST_BLUE" "$TEST_NC"

HELPER_OUTPUT="${TMP}/helper-output.log"
if HOME="${FAKE_HOME}" "${HELPER}" cleanup-broken-symlinks >"${HELPER_OUTPUT}" 2>&1; then
	pass "helper exited 0"
else
	fail "helper exited non-zero" "see ${HELPER_OUTPUT}"
fi

# Broken ones should be gone
for link in "${BROKEN_COMMAND}" "${BROKEN_SKILL}" "${BROKEN_AGENT}"; do
	name="${link#"${OC_BASE}/"}"
	if [[ -L "${link}" ]]; then
		fail "broken symlink still present: ${name}"
	else
		pass "broken symlink removed: ${name}"
	fi
done

# Live ones should survive
for link in "${LIVE_SYMLINK}" "${LIVE_SKILL}"; do
	name="${link#"${OC_BASE}/"}"
	if [[ -L "${link}" && -e "${link}" ]]; then
		pass "live symlink preserved: ${name}"
	else
		fail "live symlink incorrectly affected: ${name}"
	fi
done

# Regular file should survive
if [[ -f "${REGULAR_FILE}" && ! -L "${REGULAR_FILE}" ]]; then
	pass "regular file preserved: command/real-file.md"
else
	fail "regular file incorrectly affected" "command/real-file.md missing or now a symlink"
fi

# Summary line should mention "3" in output
if grep -qE 'Removed 3 broken' "${HELPER_OUTPUT}"; then
	pass "summary reports correct removal count (3)"
else
	fail "summary did not report removal count" "output: $(cat "${HELPER_OUTPUT}")"
fi

printf '\n'

# =============================================================================
# Test 2: Second run is idempotent (no-op, exits 0)
# =============================================================================
printf '%s[TEST 2]%s Second run is idempotent\n' "$TEST_BLUE" "$TEST_NC"

HELPER_OUTPUT2="${TMP}/helper-output2.log"
if HOME="${FAKE_HOME}" "${HELPER}" cleanup-broken-symlinks >"${HELPER_OUTPUT2}" 2>&1; then
	pass "second run exits 0"
else
	fail "second run exited non-zero" "see ${HELPER_OUTPUT2}"
fi

if grep -qE 'Removed [1-9]' "${HELPER_OUTPUT2}"; then
	fail "second run reports removals (should be zero)" "output: $(cat "${HELPER_OUTPUT2}")"
else
	pass "second run removes nothing (idempotent)"
fi

printf '\n'

# =============================================================================
# Test 3: Missing runtime dirs are tolerated
# =============================================================================
printf '%s[TEST 3]%s Missing runtime dirs do not error\n' "$TEST_BLUE" "$TEST_NC"

CLEAN_HOME="${TMP}/clean-home"
mkdir -p "${CLEAN_HOME}/.config/opencode/command" # only one dir, other three missing

HELPER_OUTPUT3="${TMP}/helper-output3.log"
if HOME="${CLEAN_HOME}" "${HELPER}" cleanup-broken-symlinks >"${HELPER_OUTPUT3}" 2>&1; then
	pass "missing dirs tolerated (exit 0)"
else
	fail "missing dirs caused error" "see ${HELPER_OUTPUT3}"
fi

printf '\n'

# =============================================================================
# Test 4: Completely missing ~/.config/opencode is tolerated
# =============================================================================
printf '%s[TEST 4]%s Completely missing ~/.config/opencode is tolerated\n' "$TEST_BLUE" "$TEST_NC"

EMPTY_HOME="${TMP}/empty-home"
mkdir -p "${EMPTY_HOME}"

HELPER_OUTPUT4="${TMP}/helper-output4.log"
if HOME="${EMPTY_HOME}" "${HELPER}" cleanup-broken-symlinks >"${HELPER_OUTPUT4}" 2>&1; then
	pass "empty HOME tolerated (exit 0)"
else
	fail "empty HOME caused error" "see ${HELPER_OUTPUT4}"
fi

printf '\n'

# =============================================================================
# Summary
# =============================================================================
if [[ ${TESTS_FAILED} -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d of %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
