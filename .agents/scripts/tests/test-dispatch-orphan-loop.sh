#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-dispatch-orphan-loop.sh — GH#22049 regression guard.
#
# Asserts that `dispatch-dedup-helper.sh is-assigned` short-circuits with
# ORPHAN_LOOP_BLOCKED when the same issue+branch has accumulated
# >= DISPATCH_ORPHAN_LOOP_THRESHOLD orphan recovery failures within
# DISPATCH_ORPHAN_LOOP_WINDOW_SECS (default: 3 events in 2h).
#
# Also asserts that a DIFFERENT branch or a DIFFERENT issue does NOT block,
# and that the feature gate (DISPATCH_ORPHAN_LOOP_THRESHOLD=0) suppresses
# the check entirely.
#
# Failure mode this guards against: the same issue+branch emitting
# WORKER_BRANCH_ORPHAN repeatedly (e.g., GH#21860 where PR #21876 already
# existed but search-lag caused repeated misclassification) without any
# dispatch backpressure until a human intervenes.
#
# Pattern mirrored from test-dispatch-cooldown.sh (t3197).
#
# NOTE: not using `set -e` intentionally — negative assertions rely on
# capturing non-zero exits from is-assigned.

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
# Stub the gh CLI — minimal payload that passes all guards above orphan check
# (no parent-task, no no-auto-dispatch, no assignees, no cooldown markers).
# =============================================================================
STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"

write_stub_gh() {
	local issue_payload="${1:-$PASSTHROUGH_ISSUE}"
	local comments_payload="${2:-[]}"
	cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "issue" && "\$2" == "view" ]]; then
	cat <<'JSON'
${issue_payload}
JSON
	exit 0
fi
if [[ "\$1" == "api" && "\$2" == repos/*/issues/*/comments ]]; then
	cat <<'JSON'
${comments_payload}
JSON
	exit 0
fi
exit 1
STUB
	chmod +x "${STUB_DIR}/gh"
	return 0
}

# Minimal issue payload — passes every guard above the orphan-loop check.
PASSTHROUGH_ISSUE='{"state":"OPEN","assignees":[],"labels":[{"name":"tier:standard"}],"createdAt":"2020-01-01T00:00:00Z"}'

OLD_PATH="$PATH"
export PATH="${STUB_DIR}:${PATH}"

# Initialise stub with no cooldown comments so that check is skipped.
write_stub_gh "$PASSTHROUGH_ISSUE" "[]"

run_is_assigned() {
	local issue="$1" repo="$2" self="${3:-}"
	output=$("${TEST_SCRIPTS_DIR}/dispatch-dedup-helper.sh" is-assigned "$issue" "$repo" "$self" 2>/dev/null)
	rc=$?
	return 0
}

# Helper: write the orphan-loop state file with N events for a given key.
# All timestamps are set to now so they fall within any reasonable window.
write_orphan_state() {
	local key="$1"
	local count="$2"
	local state_file="${HOME}/.aidevops/logs/orphan-loop-state.json"
	local now
	now=$(date +%s)
	local ts_array=""
	local i=1
	while [[ "$i" -le "$count" ]]; do
		ts_array="${ts_array:+$ts_array,}$now"
		i=$((i + 1))
	done
	printf '{"counters":{"%s":[%s]}}\n' "$key" "$ts_array" >"$state_file"
	return 0
}

# Helper: write state file with events for two keys (cross-issue isolation test).
write_orphan_state_two_keys() {
	local key1="$1" count1="$2"
	local key2="$3" count2="$4"
	local state_file="${HOME}/.aidevops/logs/orphan-loop-state.json"
	local now
	now=$(date +%s)
	local ts1="" ts2="" i=1
	while [[ "$i" -le "$count1" ]]; do
		ts1="${ts1:+$ts1,}$now"; i=$((i + 1))
	done
	i=1
	while [[ "$i" -le "$count2" ]]; do
		ts2="${ts2:+$ts2,}$now"; i=$((i + 1))
	done
	printf '{"counters":{"%s":[%s],"%s":[%s]}}\n' "$key1" "$ts1" "$key2" "$ts2" >"$state_file"
	return 0
}

# =============================================================================
# Part 1 — Threshold exceeded → ORPHAN_LOOP_BLOCKED
# =============================================================================

# Case A: exactly threshold (3) events for branch X on issue 88001 → must block.
REPO="owner/repo"
ISSUE="88001"
BRANCH="feature/auto-20260430-062441-gh88001"
KEY="${REPO}#${ISSUE}#${BRANCH}#worker_branch_orphan"
write_orphan_state "$KEY" 3
run_is_assigned "$ISSUE" "$REPO"
if [[ "$rc" -eq 0 && "$output" == *"ORPHAN_LOOP_BLOCKED"* && "$output" == *"$BRANCH"* ]]; then
	print_result "is-assigned blocks at threshold (3 events, same issue+branch)" 0
else
	print_result "is-assigned blocks at threshold (3 events, same issue+branch)" 1 \
		"(rc=$rc output='$output')"
fi

# Case B: more than threshold (5 events) → must block with count in message.
write_orphan_state "$KEY" 5
run_is_assigned "$ISSUE" "$REPO"
if [[ "$rc" -eq 0 && "$output" == *"ORPHAN_LOOP_BLOCKED"* && "$output" == *"count=5"* ]]; then
	print_result "is-assigned blocks above threshold (5 events) with count in message" 0
else
	print_result "is-assigned blocks above threshold (5 events) with count in message" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Part 2 — Under threshold → no block
# =============================================================================

# Case C: 2 events (below default threshold of 3) → must not block.
write_orphan_state "$KEY" 2
run_is_assigned "$ISSUE" "$REPO"
if [[ "$output" != *"ORPHAN_LOOP_BLOCKED"* ]]; then
	print_result "is-assigned does not block below threshold (2 events < 3)" 0
else
	print_result "is-assigned does not block below threshold (2 events < 3)" 1 \
		"(rc=$rc output='$output')"
fi

# Case D: 0 events → must not block.
state_file="${HOME}/.aidevops/logs/orphan-loop-state.json"
rm -f "$state_file" 2>/dev/null || true
run_is_assigned "$ISSUE" "$REPO"
if [[ "$output" != *"ORPHAN_LOOP_BLOCKED"* ]]; then
	print_result "is-assigned does not block with no orphan state file" 0
else
	print_result "is-assigned does not block with no orphan state file" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Part 3 — Isolation: different branch / different issue must not block
# =============================================================================

# Case E: 3 events on issue 88001/branch-A; query is for issue 88001/different-branch.
# Different branch → not blocked (branch-A has history, branch-B is fresh).
BRANCH_A="feature/auto-20260430-000000-gh88001"
BRANCH_B="feature/auto-20260501-120000-gh88001"
KEY_A="${REPO}#${ISSUE}#${BRANCH_A}#worker_branch_orphan"
write_orphan_state "$KEY_A" 3
# is-assigned checks issue-level: any branch for issue 88001 with ≥ threshold → block.
# This is intentional — if the issue has a stuck branch, we block re-dispatch for all
# branches until the window expires or a human intervenes.
run_is_assigned "$ISSUE" "$REPO"
if [[ "$rc" -eq 0 && "$output" == *"ORPHAN_LOOP_BLOCKED"* ]]; then
	print_result "is-assigned blocks when any branch for the issue has hit threshold (issue-level check)" 0
else
	print_result "is-assigned blocks when any branch for the issue has hit threshold (issue-level check)" 1 \
		"(rc=$rc output='$output')"
fi

# Case F: 3 events on issue 88002 (different issue); query for issue 88001 → not blocked.
ISSUE_OTHER="88002"
KEY_OTHER="${REPO}#${ISSUE_OTHER}#${BRANCH}#worker_branch_orphan"
write_orphan_state "$KEY_OTHER" 3
# Remove state for the original issue to isolate the cross-issue test.
printf '{"counters":{"%s":[1,2,3]}}\n' "$KEY_OTHER" >"$state_file"
run_is_assigned "$ISSUE" "$REPO"
if [[ "$output" != *"ORPHAN_LOOP_BLOCKED"* ]]; then
	print_result "is-assigned does not block for a different issue (cross-issue isolation)" 0
else
	print_result "is-assigned does not block for a different issue (cross-issue isolation)" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Part 4 — Time window expiry: old events outside window must not block
# =============================================================================

# Case G: 5 events all 3 hours ago (outside default 2h window) → must not block.
PAST_TS=$(( $(date +%s) - 10800 ))  # 3h ago
printf '{"counters":{"%s":[%s,%s,%s,%s,%s]}}\n' \
	"$KEY" "$PAST_TS" "$PAST_TS" "$PAST_TS" "$PAST_TS" "$PAST_TS" >"$state_file"
run_is_assigned "$ISSUE" "$REPO"
if [[ "$output" != *"ORPHAN_LOOP_BLOCKED"* ]]; then
	print_result "is-assigned does not block on events outside time window (3h ago > 2h window)" 0
else
	print_result "is-assigned does not block on events outside time window (3h ago > 2h window)" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Part 5 — Feature gate (DISPATCH_ORPHAN_LOOP_THRESHOLD=0 disables)
# =============================================================================

# Case H: 5 fresh events but feature gate=0 → must not block.
write_orphan_state "$KEY" 5
output=$(DISPATCH_ORPHAN_LOOP_THRESHOLD=0 \
	"${TEST_SCRIPTS_DIR}/dispatch-dedup-helper.sh" is-assigned "$ISSUE" "$REPO" 2>/dev/null)
rc=$?
if [[ "$output" != *"ORPHAN_LOOP_BLOCKED"* ]]; then
	print_result "is-assigned skips orphan-loop check when DISPATCH_ORPHAN_LOOP_THRESHOLD=0" 0
else
	print_result "is-assigned skips orphan-loop check when DISPATCH_ORPHAN_LOOP_THRESHOLD=0" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Part 6 — Custom threshold via env var
# =============================================================================

# Case I: threshold=2, 2 events → must block.
write_orphan_state "$KEY" 2
output=$(DISPATCH_ORPHAN_LOOP_THRESHOLD=2 \
	"${TEST_SCRIPTS_DIR}/dispatch-dedup-helper.sh" is-assigned "$ISSUE" "$REPO" 2>/dev/null)
rc=$?
if [[ "$rc" -eq 0 && "$output" == *"ORPHAN_LOOP_BLOCKED"* ]]; then
	print_result "is-assigned respects custom DISPATCH_ORPHAN_LOOP_THRESHOLD=2" 0
else
	print_result "is-assigned respects custom DISPATCH_ORPHAN_LOOP_THRESHOLD=2" 1 \
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
