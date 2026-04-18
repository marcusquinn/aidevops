#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-full-loop-parent-task.sh — t2242 regression tests.
#
# Verifies that full-loop-helper.sh _build_pr_body() and the keyword-selection
# logic in cmd_commit_and_pr() correctly auto-swap "Resolves" to "For" when the
# linked issue has the parent-task label.
#
# Test cases:
#   Case 1: parent-task issue → PR body contains "For #NNN" (not Resolves)
#   Case 2: leaf issue → PR body contains "Resolves #NNN" (back-compat)
#   Case 3: parent-task issue + --allow-parent-close → "Resolves #NNN" (override)
#   Case 4: _issue_has_parent_task_label returns 0 for parent-task labelled issue
#   Case 5: _issue_has_parent_task_label returns 1 for leaf issue
#   Case 6: _issue_has_parent_task_label returns 2 on gh failure

# NOTE: not using `set -e` — negative assertions rely on non-zero exits.
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
	return 0
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
	return 0
}

# write_stub_gh_fail: stub gh that always fails.
write_stub_gh_fail() {
	cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
	chmod +x "${STUB_DIR}/gh"
	return 0
}

OLD_PATH="$PATH"
export PATH="${STUB_DIR}:${PATH}"

# Source the full-loop-helper to get access to internal functions.
# We need to bypass set -e and the main entrypoint — source only the functions.
# Stub out shared-constants.sh sourcing by defining what's needed.
_SOURCING_FOR_TEST=1

# Provide minimal stubs for shared-constants.sh symbols
if [[ -z "${NC+x}" ]]; then
	NC=$'\033[0m'
	RED=$'\033[0;31m'
	GREEN=$'\033[0;32m'
	YELLOW=$'\033[0;33m'
	BLUE=$'\033[0;34m'
	PURPLE=$'\033[0;35m'
	CYAN=$'\033[0;36m'
	WHITE=$'\033[0;37m'
	BOLD=$'\033[1m'
fi

# Stub the print functions that full-loop-helper.sh uses
print_info() { printf '[INFO] %s\n' "$*" >&2; return 0; }
print_error() { printf '[ERROR] %s\n' "$*" >&2; return 0; }
print_warning() { printf '[WARN] %s\n' "$*" >&2; return 0; }
print_success() { printf '[OK] %s\n' "$*" >&2; return 0; }

# We need to extract and eval just the functions we're testing.
# Source the functions by extracting them directly.

# Extract _issue_has_parent_task_label from the helper
eval "$(sed -n '/_issue_has_parent_task_label()/,/^}/p' "${TEST_SCRIPTS_DIR}/full-loop-helper.sh")"

# Extract _build_pr_body from the helper
eval "$(sed -n '/_build_pr_body()/,/^}/p' "${TEST_SCRIPTS_DIR}/full-loop-helper.sh")"

# =============================================================================
# Case 1 — parent-task issue → _build_pr_body with "For" keyword
# =============================================================================
pr_body=$(_build_pr_body "18458" "Test summary" "shellcheck clean" "file.sh" "" "For")
if printf '%s' "$pr_body" | grep -q 'For #18458'; then
	print_result "Parent-task issue → PR body contains 'For #18458'" 0
else
	print_result "Parent-task issue → PR body contains 'For #18458'" 1 \
		"(body did not contain 'For #18458')"
fi

# Confirm it does NOT contain "Resolves"
if printf '%s' "$pr_body" | grep -q 'Resolves #18458'; then
	print_result "Parent-task issue → PR body does NOT contain 'Resolves #18458'" 1 \
		"(body unexpectedly contained 'Resolves')"
else
	print_result "Parent-task issue → PR body does NOT contain 'Resolves #18458'" 0
fi

# =============================================================================
# Case 2 — leaf issue → _build_pr_body with default "Resolves" keyword
# =============================================================================
pr_body=$(_build_pr_body "99999" "Leaf impl" "tests pass" "leaf.sh" "" "Resolves")
if printf '%s' "$pr_body" | grep -q 'Resolves #99999'; then
	print_result "Leaf issue → PR body contains 'Resolves #99999' (back-compat)" 0
else
	print_result "Leaf issue → PR body contains 'Resolves #99999' (back-compat)" 1 \
		"(body did not contain 'Resolves #99999')"
fi

# =============================================================================
# Case 3 — parent-task + --allow-parent-close → "Resolves" override
# =============================================================================
# Simulates the final-phase case: even though issue is parent-task,
# --allow-parent-close forces "Resolves" keyword.
pr_body=$(_build_pr_body "18458" "Final phase" "all green" "final.sh" "" "Resolves")
if printf '%s' "$pr_body" | grep -q 'Resolves #18458'; then
	print_result "Parent-task + --allow-parent-close → 'Resolves #18458' (override)" 0
else
	print_result "Parent-task + --allow-parent-close → 'Resolves #18458' (override)" 1 \
		"(body did not contain 'Resolves #18458')"
fi

# =============================================================================
# Case 4 — _issue_has_parent_task_label → 0 for parent-task labelled issue
# =============================================================================
write_stub_gh_parent "18458"
if _issue_has_parent_task_label "18458" "owner/repo"; then
	print_result "_issue_has_parent_task_label returns 0 for parent-task issue" 0
else
	print_result "_issue_has_parent_task_label returns 0 for parent-task issue" 1 \
		"(returned non-zero)"
fi

# =============================================================================
# Case 5 — _issue_has_parent_task_label → 1 for leaf issue
# =============================================================================
write_stub_gh_leaf
_issue_has_parent_task_label "99999" "owner/repo"
label_rc=$?
if [[ "$label_rc" -eq 1 ]]; then
	print_result "_issue_has_parent_task_label returns 1 for leaf issue" 0
else
	print_result "_issue_has_parent_task_label returns 1 for leaf issue" 1 \
		"(rc=$label_rc, expected 1)"
fi

# =============================================================================
# Case 6 — _issue_has_parent_task_label → 2 on gh failure
# =============================================================================
write_stub_gh_fail
_issue_has_parent_task_label "18458" "owner/repo"
label_rc=$?
if [[ "$label_rc" -eq 2 ]]; then
	print_result "_issue_has_parent_task_label returns 2 on gh failure" 0
else
	print_result "_issue_has_parent_task_label returns 2 on gh failure" 1 \
		"(rc=$label_rc, expected 2)"
fi

# =============================================================================
# Case 7 — _build_pr_body defaults to "Resolves" when no keyword arg given
# =============================================================================
pr_body=$(_build_pr_body "55555" "Default test" "verified" "default.sh" "")
if printf '%s' "$pr_body" | grep -q 'Resolves #55555'; then
	print_result "_build_pr_body defaults to 'Resolves' when no 6th arg" 0
else
	print_result "_build_pr_body defaults to 'Resolves' when no 6th arg" 1 \
		"(body did not contain 'Resolves #55555')"
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
