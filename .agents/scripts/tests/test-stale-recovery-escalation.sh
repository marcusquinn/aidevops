#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-stale-recovery-escalation.sh — t2008 regression guard.
#
# Asserts the stale-recovery escalation logic works end-to-end:
#
#   1. First recovery (0 prior ticks) → tick:1 posted, status:available added
#   2. Second recovery (1 prior tick) → tick:2 posted, status:available added
#   3. Third recovery (2 prior ticks = threshold) → STALE_ESCALATED emitted,
#      needs-maintainer-review applied, status:available NOT added
#   4. Reset path: when an open PR is detected, tick reset comment posted,
#      normal recovery proceeds (no escalation)
#   5. Above-threshold (3 prior ticks >= threshold=2) also escalates
#
# Tests use the `test-recover` subcommand added to dispatch-dedup-helper.sh
# (t2008) to expose _recover_stale_assignment without sourcing complications.
#
# Stubs use environment variables to control output, not heredoc jq calls.
#
# Failure history motivating this test: GH#18356 (t1962 Phase 3, observed
# stale-recovery looping twice without a PR and requiring manual intervention).
#
# NOTE: not using `set -e` — negative assertions rely on capturing non-zero
# exits. NOTE: SCRIPT_DIR NOT readonly to avoid readonly-collision pattern
# (same as test-parent-task-guard.sh).

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

# Sandbox HOME so sourcing is side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"
GH_CALLS_FILE="${TEST_ROOT}/gh_calls.log"

#######################################
# write_stub_gh: write a minimal gh stub that:
#   - Appends all calls to GH_CALLS_FILE
#   - Returns STUB_TICK_COUNT for 'gh api *comments --jq ...'
#     (simulates the count of stale-recovery-tick comments)
#   - Returns STUB_OPEN_PR for 'gh pr list --state open ...'
#     (simulates finding an open PR by number, or empty for none)
#   - Silently succeeds for all write calls (issue edit, issue comment)
#
# Called with env vars STUB_TICK_COUNT and STUB_OPEN_PR set.
#######################################
write_stub_gh() {
	local tick_count="${1:-0}"
	local open_pr="${2:-}"
	local transition_visible="${3:-1}"
	local open_pr_number="${open_pr%%|*}"
	local open_pr_kind="${open_pr#*|}"
	: >"$GH_CALLS_FILE"

	cat >"${STUB_DIR}/gh" <<STUBEOF
#!/usr/bin/env bash
# Stub gh for test-stale-recovery-escalation.sh
printf '%s\n' "\$*" >> "${GH_CALLS_FILE}"

# gh api .../comments --jq '... | length'
# Returns the pre-computed tick count directly (t2008 test shim)
if [[ "\$1" == "api" && "\$2" == *"/comments" ]]; then
	python3 - "${tick_count}" <<'PY'
import json
import sys

count = int(sys.argv[1])
comments = []
for index in range(1, count + 1):
    comments.append({"created_at": f"2026-01-01T00:00:{index:02d}Z", "body": f"<!-- stale-recovery-tick:{index} -->"})
comments.append({
    "created_at": "2026-01-01T00:01:00Z",
    "body": "DISPATCH_CLAIM nonce=test runner=stale-runner ts=2026-01-01T00:01:00Z max_age_s=1 lease_token=test device=test session=issue-99999 phase=prelaunch expires_at=1",
    "user": {"login": "stale-runner"},
    "author_association": "MEMBER",
})
print(json.dumps([comments]))
PY
	exit 0
fi

# gh pr list --state open ...
# Returns open PR number if configured, empty if not
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
	case "${open_pr_kind}" in
	ready) printf '%s\n' '[{"number":${open_pr_number},"isDraft":false,"labels":[{"name":"origin:worker"}],"statusCheckRollup":[]}]' ;;
	ready_failed) printf '%s\n' '[{"number":${open_pr_number},"isDraft":false,"labels":[{"name":"origin:worker"}],"statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]}]' ;;
	ready_review_infra) printf '%s\n' '[{"number":${open_pr_number},"isDraft":false,"labels":[{"name":"origin:worker"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"gate / review-bot-gate","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"StatusContext","context":"review-bot-gate","state":"SUCCESS"}]}]' ;;
	draft_checkpoint) printf '%s\n' '[{"number":${open_pr_number},"isDraft":true,"labels":[{"name":"origin:worker"}],"statusCheckRollup":[]}]' ;;
	protected_draft) printf '%s\n' '[{"number":${open_pr_number},"isDraft":true,"labels":[{"name":"origin:interactive"}],"statusCheckRollup":[]}]' ;;
	*) printf '%s\n' '[]' ;;
	esac
	exit 0
fi

# gh issue view returns the verified post-transition state; edits/comments
# remain silent successes.
if [[ "\$1" == "issue" ]]; then
	if [[ "\$2" == "view" && "\$*" == *"--json state,labels,assignees"* ]]; then
		if [[ "${open_pr}" == *"draft_checkpoint"* || "${open_pr}" == *"ready_failed"* ]]; then
			if [[ "${transition_visible}" == "1" ]]; then
				printf '%s\n' '{"state":"OPEN","labels":[{"name":"needs-maintainer-review"}],"assignees":[]}'
			else
				printf '%s\n' '{"state":"OPEN","labels":[],"assignees":[{"login":"stale-runner"}]}'
			fi
		else
			printf '%s\n' '{"state":"OPEN","labels":[{"name":"status:available"}],"assignees":[]}'
		fi
	fi
	exit 0
fi

exit 0
STUBEOF
	chmod +x "${STUB_DIR}/gh"
	return 0
}

OLD_PATH="$PATH"
export PATH="${STUB_DIR}:${OLD_PATH}"

#######################################
# run_recover: invoke dispatch-dedup-helper.sh test-recover with given
# tick count and open PR state. Captures output and exit code in globals
# $output and $rc.
#######################################
output=""
rc=0

run_recover() {
	local tick_count="${1:-0}"
	local open_pr="${2:-}"
	local transition_visible="${3:-1}"
	write_stub_gh "$tick_count" "$open_pr" "$transition_visible"
	set +e
	output=$(
		STALE_ASSIGNMENT_THRESHOLD_SECONDS=0
		STALE_RECOVERY_THRESHOLD=2
		export STALE_ASSIGNMENT_THRESHOLD_SECONDS STALE_RECOVERY_THRESHOLD
		"${TEST_SCRIPTS_DIR}/dispatch-dedup-helper.sh" test-recover \
			"99999" "owner/repo" "stale-runner" "test reason" 2>/dev/null
	)
	rc=$?
	set -e
	return 0
}

# =============================================================================
# Test 1 — First recovery (0 prior ticks → tick:1 comment, STALE_RECOVERED)
# =============================================================================

run_recover 0 ""

if echo "$output" | grep -q "STALE_RECOVERED"; then
	print_result "Tick 1 (0 prior ticks): STALE_RECOVERED emitted, not escalated" 0
else
	print_result "Tick 1 (0 prior ticks): STALE_RECOVERED emitted, not escalated" 1 "(got: '$output')"
fi

# gh issue comment should have been called (tick:1 posted)
if grep -q "^issue comment" "$GH_CALLS_FILE" 2>/dev/null; then
	print_result "Tick 1: tick comment call posted" 0
else
	print_result "Tick 1: tick comment call posted" 1 "(gh calls: $(head -5 "$GH_CALLS_FILE" 2>/dev/null))"
fi

# =============================================================================
# Test 2 — Second recovery reaches the global threshold and escalates
# =============================================================================

run_recover 1 ""

if echo "$output" | grep -q "STALE_ESCALATED"; then
	print_result "Tick 2 (1 prior tick): STALE_ESCALATED emitted" 0
else
	print_result "Tick 2 (1 prior tick): STALE_ESCALATED emitted" 1 "(got: '$output')"
fi

# =============================================================================
# Test 3 — Third recovery (2 prior ticks = threshold → STALE_ESCALATED)
# =============================================================================

run_recover 2 ""

if echo "$output" | grep -q "STALE_ESCALATED"; then
	print_result "Escalation (2 prior ticks >= threshold 2): STALE_ESCALATED emitted" 0
else
	print_result "Escalation (2 prior ticks >= threshold 2): STALE_ESCALATED emitted" 1 "(got: '$output')"
fi

# STALE_RECOVERED must NOT be emitted in escalation path (no re-dispatch)
if ! echo "$output" | grep -q "STALE_RECOVERED"; then
	print_result "Escalation: STALE_RECOVERED NOT emitted (no re-dispatch loop)" 0
else
	print_result "Escalation: STALE_RECOVERED NOT emitted (no re-dispatch loop)" 1 "(got: '$output')"
fi

# needs-maintainer-review must be applied (check gh issue edit call in log)
if grep -q "needs-maintainer-review" "$GH_CALLS_FILE" 2>/dev/null; then
	print_result "Escalation: needs-maintainer-review label applied" 0
else
	print_result "Escalation: needs-maintainer-review label applied" 1 "(gh calls: $(head -10 "$GH_CALLS_FILE" 2>/dev/null))"
fi

# status:available must NOT be --add-label'd in escalation path
# (it's OK to appear as --remove-label; we just must not reset to available)
if ! grep -q "add-label status:available" "$GH_CALLS_FILE" 2>/dev/null; then
	print_result "Escalation: status:available NOT added (correct; only removed if present)" 0
else
	print_result "Escalation: status:available NOT added (correct; only removed if present)" 1 "(gh calls: $(cat "$GH_CALLS_FILE" 2>/dev/null))"
fi

# auto-dispatch must be removed in the same escalation mutation so a later
# status recovery cannot make this NMR-held issue appear runnable.
if grep -q -- "--remove-label auto-dispatch" "$GH_CALLS_FILE" 2>/dev/null; then
	print_result "Escalation: auto-dispatch removed with NMR hold" 0
else
	print_result "Escalation: auto-dispatch removed with NMR hold" 1 "(gh calls: $(cat "$GH_CALLS_FILE" 2>/dev/null))"
fi

# =============================================================================
# Test 4 — Reset path: open PR detected → counter reset, STALE_RECOVERED
# =============================================================================

# 2 prior ticks, but open PR #42 is durable progress and must be preserved
run_recover 2 "42|ready"

if echo "$output" | grep -q "STALE_PROGRESS_PRESERVED"; then
	print_result "Open PR path preserves durable progress without stale recovery" 0
else
	print_result "Open PR path preserves durable progress without stale recovery" 1 "(got: '$output')"
fi

if ! echo "$output" | grep -q "STALE_ESCALATED"; then
	print_result "Reset path: STALE_ESCALATED NOT emitted" 0
else
	print_result "Reset path: STALE_ESCALATED NOT emitted" 1 "(got: '$output')"
fi

# Durable PR activity replaces synthetic reset comments.
if ! grep -q "^issue comment" "$GH_CALLS_FILE" 2>/dev/null; then
	print_result "Open PR path posts no synthetic reset comment" 0
else
	print_result "Open PR path posts no synthetic reset comment" 1 "(gh calls: $(head -5 "$GH_CALLS_FILE" 2>/dev/null))"
fi

# =============================================================================
# Test 5 — Above-threshold (3 prior ticks >= threshold=2 → STALE_ESCALATED)
# =============================================================================

run_recover 3 ""

if echo "$output" | grep -q "STALE_ESCALATED"; then
	print_result "Above-threshold (3 prior ticks >= threshold 2): STALE_ESCALATED emitted" 0
else
	print_result "Above-threshold (3 prior ticks >= threshold 2): STALE_ESCALATED emitted" 1 "(got: '$output')"
fi

# =============================================================================
# Test 6 — Worker draft escalates only after verified blocking transition
# =============================================================================

run_recover 0 "77|draft_checkpoint" 1
if echo "$output" | grep -q "STALE_DRAFT_ESCALATED" && grep -q "needs-maintainer-review" "$GH_CALLS_FILE"; then
	print_result "Worker draft checkpoint escalates after verified NMR read-back" 0
else
	print_result "Worker draft checkpoint escalates after verified NMR read-back" 1 "(got: '$output')"
fi

run_recover 0 "77|draft_checkpoint" 0
if [[ "$rc" -ne 0 ]] && echo "$output" | grep -q "STALE_PR_ESCALATION_FAILED"; then
	print_result "Worker draft retains ownership when NMR transition is invisible" 0
else
	print_result "Worker draft retains ownership when NMR transition is invisible" 1 "(rc=$rc got: '$output')"
fi

# =============================================================================
# Test 7 — Protected drafts are never mutated
# =============================================================================

run_recover 0 "78|protected_draft"
if echo "$output" | grep -q "STALE_DRAFT_PROTECTED" && ! grep -q "^issue edit" "$GH_CALLS_FILE"; then
	print_result "Protected draft blocks recovery without automated mutation" 0
else
	print_result "Protected draft blocks recovery without automated mutation" 1 "(got: '$output')"
fi

# =============================================================================
# Test 8 — Terminally failed ready PR escalates explicitly
# =============================================================================

run_recover 0 "79|ready_failed" 1
if echo "$output" | grep -q "STALE_READY_FAILED_ESCALATED"; then
	print_result "Ready PR with terminal failed checks escalates explicitly" 0
else
	print_result "Ready PR with terminal failed checks escalates explicitly" 1 "(got: '$output')"
fi

# A later review-event workflow can exhaust its API quota after the exact-head
# commit status already passed. That infrastructure-only rerun is not a failed
# implementation checkpoint and must not trigger maintainer escalation.
run_recover 0 "80|ready_review_infra" 1
if echo "$output" | grep -q "STALE_PROGRESS_PRESERVED" && ! grep -q "needs-maintainer-review" "$GH_CALLS_FILE"; then
	print_result "Successful review status suppresses terminal infra rerun escalation" 0
else
	print_result "Successful review status suppresses terminal infra rerun escalation" 1 "(got: '$output')"
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
