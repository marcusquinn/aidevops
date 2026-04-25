#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-dispatch-dedup-no-auto-dispatch-block.sh — t2832 regression guard.
#
# Asserts that `dispatch-dedup-helper.sh is-assigned` short-circuits to
# NO_AUTO_DISPATCH_BLOCKED for any issue labeled `no-auto-dispatch`,
# even when:
#   - the issue has no assignees
#   - the issue has the maintainer self-assigned with status:available
#     (the live failure mode observed on GH#20827, which the fix addresses)
#   - the issue is also labeled with another active blocker (parent-task wins,
#     but no-auto-dispatch must still block when alone)
#
# Failure history motivating this test: GH#20827 (t2821 policy issue) — the
# label was deliberately applied at issue creation to block dispatch, but
# the dispatch path didn't honour it, leading to 6 worker dispatches over
# 2 hours and ~30-50K opus tokens burned. Pre-fix, the label was honoured by
# enrichment / decomposition / backfill but NOT the dispatch-dedup guard.
#
# Pattern mirrored from `test-parent-task-guard.sh` (t1986).
#
# NOTE: not using `set -e` intentionally — negative assertions rely on
# capturing non-zero exits from is-assigned. Each assertion explicitly
# captures exit codes via `if ... ; then ... fi`.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# NOTE: NOT readonly — shared-constants.sh declares `readonly RED/GREEN/RESET`
# and the collision under set -e silently kills the test shell. Use plain vars.
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

# Sandbox HOME so sourcing is side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

# =============================================================================
# Stub the gh CLI so we can feed synthetic issue payloads into is_assigned
# =============================================================================
STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"

write_stub_gh() {
	local payload="$1"
	cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
# Stub for test-dispatch-dedup-no-auto-dispatch-block.sh
if [[ "\$1" == "issue" && "\$2" == "view" ]]; then
	cat <<'JSON'
${payload}
JSON
	exit 0
fi
exit 1
STUB
	chmod +x "${STUB_DIR}/gh"
	return 0
}

OLD_PATH="$PATH"
export PATH="${STUB_DIR}:${PATH}"

# run_is_assigned: invokes dispatch-dedup-helper.sh is-assigned, captures
# both stdout and exit code.
run_is_assigned() {
	local issue="$1" repo="$2" self="${3:-}"
	output=$("${TEST_SCRIPTS_DIR}/dispatch-dedup-helper.sh" is-assigned "$issue" "$repo" "$self" 2>/dev/null)
	rc=$?
	return 0
}

# =============================================================================
# Part 1 — no-auto-dispatch label short-circuits dispatch (THE FIX)
# =============================================================================

# Case A: no-auto-dispatch labeled issue with no assignees → must block
write_stub_gh '{"state":"OPEN","assignees":[],"labels":[{"name":"no-auto-dispatch"},{"name":"pulse"},{"name":"tier:standard"}]}'
run_is_assigned 99899 "owner/repo"
if [[ "$rc" -eq 0 && "$output" == *"NO_AUTO_DISPATCH_BLOCKED"* && "$output" == *"no-auto-dispatch"* ]]; then
	print_result "is-assigned blocks no-auto-dispatch labeled issue (NO_AUTO_DISPATCH_BLOCKED signal)" 0
else
	print_result "is-assigned blocks no-auto-dispatch labeled issue (NO_AUTO_DISPATCH_BLOCKED signal)" 1 \
		"(rc=$rc output='$output')"
fi

# Case B: no-auto-dispatch + maintainer self-assigned + status:available — the
# exact label combination from GH#20827 that pre-fix did NOT block dispatch.
# This is the regression case: must now block.
write_stub_gh '{"state":"OPEN","assignees":[{"login":"marcusquinn"}],"labels":[{"name":"no-auto-dispatch"},{"name":"origin:interactive"},{"name":"status:available"},{"name":"tier:standard"}]}'
run_is_assigned 99898 "owner/repo" "alex-solovyev"
if [[ "$rc" -eq 0 && "$output" == *"NO_AUTO_DISPATCH_BLOCKED"* ]]; then
	print_result "is-assigned blocks GH#20827 label combo from any runner (regression)" 0
else
	print_result "is-assigned blocks GH#20827 label combo from any runner (regression)" 1 \
		"(rc=$rc output='$output')"
fi

# Case C: no-auto-dispatch wins even when a non-self assignee is present
# (the short-circuit fires before assignee checks)
write_stub_gh '{"state":"OPEN","assignees":[{"login":"someone-else"}],"labels":[{"name":"no-auto-dispatch"}]}'
run_is_assigned 99897 "owner/repo" "marcusquinn"
if [[ "$rc" -eq 0 && "$output" == *"NO_AUTO_DISPATCH_BLOCKED"* ]]; then
	print_result "is-assigned prefers NO_AUTO_DISPATCH_BLOCKED over assignee signal" 0
else
	print_result "is-assigned prefers NO_AUTO_DISPATCH_BLOCKED over assignee signal" 1 \
		"(rc=$rc output='$output')"
fi

# Case D: parent-task AND no-auto-dispatch both present — parent-task fires
# first (it's checked before no-auto-dispatch), so output should reference
# parent-task. This documents the precedence and protects against accidental
# reordering.
write_stub_gh '{"state":"OPEN","assignees":[],"labels":[{"name":"parent-task"},{"name":"no-auto-dispatch"}]}'
run_is_assigned 99896 "owner/repo"
if [[ "$rc" -eq 0 && "$output" == *"PARENT_TASK_BLOCKED"* ]]; then
	print_result "is-assigned: parent-task wins over no-auto-dispatch (precedence)" 0
else
	print_result "is-assigned: parent-task wins over no-auto-dispatch (precedence)" 1 \
		"(rc=$rc output='$output')"
fi

# Case E: CLOSED issue with no-auto-dispatch — label check is upstream of
# state check, so the helper still blocks.
write_stub_gh '{"state":"CLOSED","assignees":[],"labels":[{"name":"no-auto-dispatch"}]}'
run_is_assigned 99895 "owner/repo"
if [[ "$rc" -eq 0 && "$output" == *"NO_AUTO_DISPATCH_BLOCKED"* ]]; then
	print_result "is-assigned blocks CLOSED no-auto-dispatch issue (label-first precedence)" 0
else
	print_result "is-assigned blocks CLOSED no-auto-dispatch issue (label-first precedence)" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Part 2 — Negative cases (must NOT trigger the new block)
# =============================================================================

# Case F: unrelated labels only (no `no-auto-dispatch`) → must NOT short-circuit
# on no-auto-dispatch. This case may still allow dispatch (rc=1) or block on
# other guards; we only assert the NO_AUTO_DISPATCH signal is absent.
write_stub_gh '{"state":"OPEN","assignees":[],"labels":[{"name":"pulse"},{"name":"tier:standard"}]}'
run_is_assigned 99894 "owner/repo"
if [[ "$output" != *"NO_AUTO_DISPATCH_BLOCKED"* ]]; then
	print_result "is-assigned does not emit NO_AUTO_DISPATCH_BLOCKED for unlabeled issue" 0
else
	print_result "is-assigned does not emit NO_AUTO_DISPATCH_BLOCKED for unlabeled issue" 1 \
		"(rc=$rc output='$output')"
fi

# Case G: substring-similar label (e.g. "auto-dispatch" alone) must NOT match.
# The check is exact equality against "no-auto-dispatch", not substring.
write_stub_gh '{"state":"OPEN","assignees":[],"labels":[{"name":"auto-dispatch"},{"name":"pulse"}]}'
run_is_assigned 99893 "owner/repo"
if [[ "$output" != *"NO_AUTO_DISPATCH_BLOCKED"* ]]; then
	print_result "is-assigned does not match 'auto-dispatch' as 'no-auto-dispatch'" 0
else
	print_result "is-assigned does not match 'auto-dispatch' as 'no-auto-dispatch'" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Part 3 — Fail-closed contract (jq error path — t2061)
# =============================================================================

# Case H: labels key is null — must not crash, must allow dispatch (no label
# = not blocked by this guard). Validates the `(.labels // [])` null-fallback.
write_stub_gh '{"state":"OPEN","assignees":[],"labels":null}'
run_is_assigned 99892 "owner/repo"
if [[ "$output" != *"NO_AUTO_DISPATCH_BLOCKED"* ]]; then
	print_result "is-assigned allows dispatch when labels key is null (null-fallback safety)" 0
else
	print_result "is-assigned allows dispatch when labels key is null (null-fallback safety)" 1 \
		"(rc=$rc output='$output')"
fi

# Case I: labels key absent entirely — same null-fallback safety.
write_stub_gh '{"state":"OPEN","assignees":[]}'
run_is_assigned 99891 "owner/repo"
if [[ "$output" != *"NO_AUTO_DISPATCH_BLOCKED"* ]]; then
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
