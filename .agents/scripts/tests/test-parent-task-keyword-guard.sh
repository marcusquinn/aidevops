#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-parent-task-keyword-guard.sh — t2046 PR keyword guard regression tests.
#
# Asserts that parent-task-keyword-guard.sh check-body correctly:
#   - Blocks (exit 2) PRs with Resolves/Closes/Fixes on parent-task issues (--strict)
#   - Allows (exit 0) PRs with For/Ref on parent-task issues
#   - Allows (exit 0) PRs with Resolves on a normal leaf issue
#   - Allows (exit 0) PRs with no closing keywords
#   - Allows (exit 0) with --allow-parent-close even when closing keyword used
#
# Test cases from Plan §3.3.2 closing list in
# todo/plans/parent-task-incident-hardening.md:
#   Case 1: parent issue + Resolves → block (strict), warn (non-strict)
#   Case 2: parent issue + For      → allow
#   Case 3: leaf issue  + Resolves  → allow
#   Case 4: no closing keyword      → allow
#   Case 5: parent + Closes + --allow-parent-close → allow (final-phase exemption)

# NOTE: not using `set -e` — negative assertions rely on non-zero exits.
# NOTE: SCRIPT_DIR is NOT readonly — collision avoidance.
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
}

# Sandbox HOME
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

# =============================================================================
# Stub infrastructure
# =============================================================================
STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"

# write_stub_gh_parent: stub gh that returns parent-task label for a given issue.
write_stub_gh_parent() {
	local parent_issue="$1"
	cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
# Stub: returns parent-task labels for issue ${parent_issue}
if [[ "\$1" == "issue" && "\$2" == "view" && "\$3" == "${parent_issue}" ]]; then
	printf '{"labels":[{"name":"parent-task"},{"name":"pulse"}]}\n'
	exit 0
fi
# All other issues are leaf issues (no parent-task label)
if [[ "\$1" == "issue" && "\$2" == "view" ]]; then
	printf '{"labels":[{"name":"pulse"},{"name":"tier:standard"}]}\n'
	exit 0
fi
exit 1
STUB
	chmod +x "${STUB_DIR}/gh"
}

# write_stub_gh_leaf: stub gh that never returns parent-task label.
write_stub_gh_leaf() {
	cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
# Stub: all issues are leaf (no parent-task label)
if [[ "$1" == "issue" && "$2" == "view" ]]; then
	printf '{"labels":[{"name":"pulse"},{"name":"tier:standard"}]}\n'
	exit 0
fi
exit 1
STUB
	chmod +x "${STUB_DIR}/gh"
}

OLD_PATH="$PATH"
export PATH="${STUB_DIR}:${PATH}"

GUARD="${TEST_SCRIPTS_DIR}/parent-task-keyword-guard.sh"

# run_check_body: runs check-body with a given PR body string and arguments.
# Sets $guard_rc and $guard_output.
run_check_body() {
	local body="$1"
	shift
	local tmp_body
	tmp_body=$(mktemp)
	printf '%s\n' "$body" >"$tmp_body"
	guard_output=$("$GUARD" check-body --body-file "$tmp_body" --repo "owner/repo" "$@" 2>&1)
	guard_rc=$?
	rm -f "$tmp_body"
	return 0
}

# =============================================================================
# Case 1 — parent issue + Resolves → block (exit 2 in --strict mode)
# =============================================================================
# Issue #18458 is the parent fixture (matches incident from plan §3.1)
write_stub_gh_parent "18458"
run_check_body "Resolves #18458

This PR files the Phase 0 plan." --strict

if [[ "$guard_rc" -eq 2 ]]; then
	print_result "Resolves on parent-task issue (--strict) → exit 2 (block)" 0
else
	print_result "Resolves on parent-task issue (--strict) → exit 2 (block)" 1 \
		"(rc=$guard_rc output='$guard_output')"
fi

# Same scenario without --strict should warn (exit 1) but not block (exit 2)
write_stub_gh_parent "18458"
run_check_body "Resolves #18458

This PR files the Phase 0 plan."

if [[ "$guard_rc" -eq 1 ]]; then
	print_result "Resolves on parent-task issue (non-strict) → exit 1 (warn, not block)" 0
else
	print_result "Resolves on parent-task issue (non-strict) → exit 1 (warn, not block)" 1 \
		"(rc=$guard_rc output='$guard_output')"
fi

# =============================================================================
# Case 2 — parent issue + For #NNN → allow (exit 0)
# =============================================================================
write_stub_gh_parent "18458"
run_check_body "For #18458

This PR files the Phase 0 plan." --strict

if [[ "$guard_rc" -eq 0 ]]; then
	print_result "For on parent-task issue → exit 0 (allow)" 0
else
	print_result "For on parent-task issue → exit 0 (allow)" 1 \
		"(rc=$guard_rc output='$guard_output')"
fi

# =============================================================================
# Case 3 — leaf issue + Resolves → allow (exit 0)
# =============================================================================
write_stub_gh_leaf
run_check_body "Resolves #99999

Implements the feature." --strict

if [[ "$guard_rc" -eq 0 ]]; then
	print_result "Resolves on leaf issue → exit 0 (allow, not a parent-task)" 0
else
	print_result "Resolves on leaf issue → exit 0 (allow, not a parent-task)" 1 \
		"(rc=$guard_rc output='$guard_output')"
fi

# =============================================================================
# Case 4 — no closing keyword → allow (exit 0)
# =============================================================================
write_stub_gh_parent "18458"
run_check_body "For #18458

Related work in PR #18579.
See also: issue #18400" --strict

if [[ "$guard_rc" -eq 0 ]]; then
	print_result "No closing keyword (only For/Ref) → exit 0 (allow)" 0
else
	print_result "No closing keyword (only For/Ref) → exit 0 (allow)" 1 \
		"(rc=$guard_rc output='$guard_output')"
fi

# =============================================================================
# Case 5 — parent + Closes + --allow-parent-close → allow (exit 0)
# =============================================================================
# Final-phase PR exemption: the last child merges and intentionally closes parent.
write_stub_gh_parent "18458"
run_check_body "Closes #18458

This is the final phase PR — all children have merged." --strict --allow-parent-close

if [[ "$guard_rc" -eq 0 ]]; then
	print_result "Closes on parent + --allow-parent-close → exit 0 (final-phase exemption)" 0
else
	print_result "Closes on parent + --allow-parent-close → exit 0 (final-phase exemption)" 1 \
		"(rc=$guard_rc output='$guard_output')"
fi

# =============================================================================
# Case 6 — inline code span with Resolves → ignore (exit 0, no false positive)
# =============================================================================
# Covers t2243: retrospective prose like "helper refused `Resolves #123` per rule"
# must NOT trigger the guard. The keyword is inside backticks — GitHub itself
# would not auto-close on merge.
write_stub_gh_parent "18458"
# shellcheck disable=SC2016
# SC2016: single quotes intentional — backticks are literal test fixture chars.
run_check_body 'prose `Resolves #18458` more prose — this is retrospective text.' --strict

if [[ "$guard_rc" -eq 0 ]]; then
	print_result "Resolves in inline code span → exit 0 (no false positive)" 0
else
	print_result "Resolves in inline code span → exit 0 (no false positive)" 1 \
		"(rc=$guard_rc output='$guard_output')"
fi

# =============================================================================
# Case 7 — fenced code block with Resolves → ignore (exit 0, no false positive)
# =============================================================================
write_stub_gh_parent "18458"
# shellcheck disable=SC2016
# SC2016: single quotes inside printf intentional — backticks are literal fixture chars.
run_check_body "$(printf 'Some prose.\n\n```\nResolves #18458\n```\n\nMore prose.')" --strict

if [[ "$guard_rc" -eq 0 ]]; then
	print_result "Resolves in fenced code block → exit 0 (no false positive)" 0
else
	print_result "Resolves in fenced code block → exit 0 (no false positive)" 1 \
		"(rc=$guard_rc output='$guard_output')"
fi

# =============================================================================
# Case 8 — plain-text Resolves on parent still detected (regression guard)
# =============================================================================
# Ensure that stripping code spans does not accidentally suppress a real keyword.
write_stub_gh_parent "18458"
run_check_body "Resolves #18458

This is a plain-text closing keyword and MUST still be flagged." --strict

if [[ "$guard_rc" -eq 2 ]]; then
	print_result "Plain-text Resolves on parent still blocked after strip (regression)" 0
else
	print_result "Plain-text Resolves on parent still blocked after strip (regression)" 1 \
		"(rc=$guard_rc output='$guard_output')"
fi

export PATH="$OLD_PATH"

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi
