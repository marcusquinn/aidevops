#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-parent-task-guard.sh — t1986 regression guard.
#
# Asserts the parent-task dispatch protection works end-to-end across
# three layers:
#
#   1. _is_protected_label recognises `parent-task` and `meta` as
#      protected (so reconciliation will not strip them).
#   2. map_tags_to_labels converts `#parent` TODO tag to the canonical
#      `parent-task` label.
#   3. dispatch-dedup-helper.sh `is-assigned` short-circuits to
#      PARENT_TASK_BLOCKED for any issue labeled `parent-task` or
#      `meta`, even when the issue has no assignees.
#
# Failure history motivating this test: GH#18356 (t1962 Phase 3, ~20K
# opus tokens burned on a parent task) + GH#18399/GH#18400 (race
# reproduced on the very issues filed to fix it).

# NOTE: not using `set -e` intentionally — negative assertions rely on
# capturing non-zero exits from _is_protected_label and is-assigned. Each
# assertion explicitly captures exit codes via `if ... ; then ... fi`.
#
# NOTE: SCRIPT_DIR is NOT readonly — issue-sync-helper.sh reassigns it
# during sourcing, and a readonly collision under its `set -e` fires
# `|| exit` and silently kills the test shell. Use an unexported,
# non-readonly name.
set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# NOTE: NOT readonly — shared-constants.sh (transitively sourced by
# issue-sync-helper.sh) declares `readonly RED/GREEN/RESET` and the
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
}

# Sandbox HOME so sourcing is side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

# =============================================================================
# Part 1 — _is_protected_label survives reconciliation allow-list
# =============================================================================
# issue-sync-helper.sh has `main "$@"` at the bottom which defaults to `help`
# and cmd_help returns 0. Sourcing runs that main, and the file's own
# `set -euo pipefail` re-activates -e in our test shell — disable it after
# sourcing so negative tests (that intentionally check for non-zero exits)
# don't silently kill the test runner.
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/issue-sync-helper.sh" >/dev/null 2>&1
set +e

if _is_protected_label "parent-task"; then
	print_result "_is_protected_label accepts parent-task" 0
else
	print_result "_is_protected_label accepts parent-task" 1 "(expected return 0)"
fi

if _is_protected_label "meta"; then
	print_result "_is_protected_label accepts meta" 0
else
	print_result "_is_protected_label accepts meta" 1 "(expected return 0)"
fi

if ! _is_protected_label "not-a-framework-label"; then
	print_result "_is_protected_label rejects unrelated labels" 0
else
	print_result "_is_protected_label rejects unrelated labels" 1
fi

# Regression guards for the existing protected set (must not break)
for existing in persistent needs-maintainer-review not-planned duplicate wontfix already-fixed; do
	if _is_protected_label "$existing"; then
		print_result "_is_protected_label still accepts $existing" 0
	else
		print_result "_is_protected_label still accepts $existing" 1 "(regression — existing label no longer protected)"
	fi
done

# =============================================================================
# Part 2 — map_tags_to_labels converts #parent → parent-task
# =============================================================================
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/issue-sync-lib.sh"

result=$(map_tags_to_labels "parent")
if [[ "$result" == "parent-task" ]]; then
	print_result "map_tags_to_labels: parent → parent-task" 0
else
	print_result "map_tags_to_labels: parent → parent-task" 1 "(got: '$result')"
fi

result=$(map_tags_to_labels "meta")
if [[ "$result" == "parent-task" ]]; then
	print_result "map_tags_to_labels: meta → parent-task" 0
else
	print_result "map_tags_to_labels: meta → parent-task" 1 "(got: '$result')"
fi

result=$(map_tags_to_labels "parent-task")
if [[ "$result" == "parent-task" ]]; then
	print_result "map_tags_to_labels: parent-task idempotent" 0
else
	print_result "map_tags_to_labels: parent-task idempotent" 1 "(got: '$result')"
fi

# Multi-tag with parent
result=$(map_tags_to_labels "parent,simplification,pulse")
if [[ "$result" == *"parent-task"* && "$result" == *"simplification"* && "$result" == *"pulse"* ]]; then
	print_result "map_tags_to_labels: multi-tag preserves parent-task" 0
else
	print_result "map_tags_to_labels: multi-tag preserves parent-task" 1 "(got: '$result')"
fi

# Existing aliases must still work
result=$(map_tags_to_labels "bug")
if [[ "$result" == "bug" ]]; then
	print_result "map_tags_to_labels: bug alias unchanged" 0
else
	print_result "map_tags_to_labels: bug alias unchanged" 1 "(got: '$result')"
fi

result=$(map_tags_to_labels "interactive")
if [[ "$result" == "origin:interactive" ]]; then
	print_result "map_tags_to_labels: interactive alias unchanged" 0
else
	print_result "map_tags_to_labels: interactive alias unchanged" 1 "(got: '$result')"
fi

# =============================================================================
# Part 3 — dispatch-dedup-helper.sh is-assigned short-circuits on parent-task
# =============================================================================
# Stub the `gh` CLI so we can feed synthetic issue payloads into is_assigned.
STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"

# Helper: write a stub gh that returns a given JSON body for issue view
write_stub_gh() {
	local payload="$1"
	cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
# Stub for test-parent-task-guard.sh
if [[ "\$1" == "issue" && "\$2" == "view" ]]; then
	cat <<'JSON'
${payload}
JSON
	exit 0
fi
exit 1
STUB
	chmod +x "${STUB_DIR}/gh"
}

OLD_PATH="$PATH"
export PATH="${STUB_DIR}:${PATH}"

# run_is_assigned: invokes dispatch-dedup-helper.sh is-assigned, captures
# both stdout and exit code. The `|| true` pattern from earlier swallowed
# the real exit code; this helper preserves it.
run_is_assigned() {
	local issue="$1" repo="$2" self="${3:-}"
	output=$("${TEST_SCRIPTS_DIR}/dispatch-dedup-helper.sh" is-assigned "$issue" "$repo" "$self" 2>/dev/null)
	rc=$?
	return 0
}

# Case A: parent-task labeled issue with no assignees → must block
write_stub_gh '{"state":"OPEN","assignees":[],"labels":[{"name":"parent-task"},{"name":"pulse"},{"name":"tier:thinking"}]}'
run_is_assigned 99999 "owner/repo"
if [[ "$rc" -eq 0 && "$output" == *"PARENT_TASK_BLOCKED"* && "$output" == *"parent-task"* ]]; then
	print_result "is-assigned blocks parent-task labeled issue (PARENT_TASK_BLOCKED signal)" 0
else
	print_result "is-assigned blocks parent-task labeled issue (PARENT_TASK_BLOCKED signal)" 1 \
		"(rc=$rc output='$output')"
fi

# Case B: meta labeled issue → must also block
write_stub_gh '{"state":"OPEN","assignees":[],"labels":[{"name":"meta"},{"name":"pulse"}]}'
run_is_assigned 99998 "owner/repo"
if [[ "$rc" -eq 0 && "$output" == *"PARENT_TASK_BLOCKED"* && "$output" == *"meta"* ]]; then
	print_result "is-assigned blocks meta labeled issue" 0
else
	print_result "is-assigned blocks meta labeled issue" 1 "(rc=$rc output='$output')"
fi

# Case C: unlabeled issue with no assignees → must NOT short-circuit
write_stub_gh '{"state":"OPEN","assignees":[],"labels":[{"name":"pulse"},{"name":"tier:standard"}]}'
run_is_assigned 99997 "owner/repo"
if [[ "$rc" -eq 1 ]]; then
	print_result "is-assigned allows normal issue with no assignees" 0
else
	print_result "is-assigned allows normal issue with no assignees" 1 "(rc=$rc output='$output')"
fi

# Case D: parent-task label wins even when there's a blocking assignee
# (the short-circuit fires before assignee checks, avoiding wasted jq work)
write_stub_gh '{"state":"OPEN","assignees":[{"login":"someone-else"}],"labels":[{"name":"parent-task"}]}'
run_is_assigned 99996 "owner/repo" "marcusquinn"
if [[ "$rc" -eq 0 && "$output" == *"PARENT_TASK_BLOCKED"* ]]; then
	print_result "is-assigned prefers PARENT_TASK_BLOCKED over assignee signal" 0
else
	print_result "is-assigned prefers PARENT_TASK_BLOCKED over assignee signal" 1 "(rc=$rc output='$output')"
fi

# Case E: issue labeled parent-task but closed — label check is first, so
# the helper still emits PARENT_TASK_BLOCKED regardless of state.
write_stub_gh '{"state":"CLOSED","assignees":[],"labels":[{"name":"parent-task"}]}'
run_is_assigned 99995 "owner/repo"
if [[ "$rc" -eq 0 && "$output" == *"PARENT_TASK_BLOCKED"* ]]; then
	print_result "is-assigned blocks CLOSED parent-task issue (label-first precedence)" 0
else
	print_result "is-assigned blocks CLOSED parent-task issue (label-first precedence)" 1 "(rc=$rc output='$output')"
fi

# Case F: labels key is null (missing from response) — must not error, must
# allow dispatch (no parent-task label = not blocked). Validates the
# `(.labels // [])` null-fallback fix from GH#18537.
write_stub_gh '{"state":"OPEN","assignees":[],"labels":null}'
run_is_assigned 99994 "owner/repo"
if [[ "$rc" -eq 1 && "$output" != *"PARENT_TASK_BLOCKED"* ]]; then
	print_result "is-assigned allows dispatch when labels key is null (null-fallback safety)" 0
else
	print_result "is-assigned allows dispatch when labels key is null (null-fallback safety)" 1 \
		"(rc=$rc output='$output')"
fi

# Case G: labels key absent entirely — must not error, must allow dispatch.
write_stub_gh '{"state":"OPEN","assignees":[]}'
run_is_assigned 99993 "owner/repo"
if [[ "$rc" -eq 1 && "$output" != *"PARENT_TASK_BLOCKED"* ]]; then
	print_result "is-assigned allows dispatch when labels key is absent (null-fallback safety)" 0
else
	print_result "is-assigned allows dispatch when labels key is absent (null-fallback safety)" 1 \
		"(rc=$rc output='$output')"
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
