#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-task-complete-move.sh — t2060 regression guard.
#
# Asserts that complete_task() extracts the matched task block from its
# current location and inserts it into ## Done instead of doing in-place
# [x] marking.
#
# Edge cases covered:
#   1. Task with no subtasks (single line)
#   2. Task with explicit subtask IDs (t123.1, t123.2) that move with parent
#   3. Task with indentation-based subtasks that move with parent
#   4. Task already in ## Done — should be a no-op (idempotent), exit 0
#   5. Task in ## In Progress — also moves to ## Done
#   6. ## Done header missing — error out clearly
#   7. Multiple consecutive entries — block boundary does not bleed into next
#
# Not using `set -e` intentionally — negative assertions rely on
# capturing non-zero exits. Each assertion explicitly captures exit codes.

set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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

# Create a sandbox git repo and TODO.md fixture for a test
# Args: $1 = test dir, $2 = TODO.md content
setup_fixture() {
	local test_dir="$1"
	local todo_content="$2"
	mkdir -p "$test_dir"
	git -C "$test_dir" init -q
	git -C "$test_dir" config user.email "test@test.com"
	git -C "$test_dir" config user.name "Test"
	printf '%s\n' "$todo_content" >"$test_dir/TODO.md"
	git -C "$test_dir" add TODO.md
	git -C "$test_dir" commit -q -m "init"
	return 0
}

# Run complete_task with --skip-merge-check --no-push and capture exit code
# Args: $1 = repo_path, $2 = task_id, $3 = proof_log_arg (e.g. "--verified 2026-01-01")
run_complete() {
	local repo_path="$1"
	local task_id="$2"
	local proof_arg="$3"
	# shellcheck disable=SC2086
	bash "${SCRIPTS_DIR}/task-complete-helper.sh" "$task_id" \
		$proof_arg \
		--skip-merge-check \
		--no-push \
		--repo-path "$repo_path" 2>/dev/null
	return $?
}

# =============================================================================
# Test setup
# =============================================================================
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

# =============================================================================
# Test 1: Single-line task (no subtasks) moves to ## Done
# =============================================================================
T1DIR="${TEST_ROOT}/t1"
setup_fixture "$T1DIR" "## Ready

- [ ] t100 My single-line task #tag ~1h ref:GH#1

## Done

- [x] t001 Old done task pr:#1 completed:2026-01-01
"

run_complete "$T1DIR" "t100" "--verified 2026-04-14" 2>/dev/null
rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result "test1: single-line task exits 0" 1 "(exit $rc)"
else
	# Task must no longer be in ## Ready
	in_ready=$(awk '/^## Ready$/{f=1;next} /^## /{f=0} f' "$T1DIR/TODO.md" | grep -c "t100" || true)
	# Task must appear in ## Done
	in_done=$(awk '/^## Done$/{f=1;next} /^## /{f=0} f' "$T1DIR/TODO.md" | grep -c "t100" || true)
	# Proof log must be appended
	has_proof=$(awk '/^## Done$/{f=1;next} /^## /{f=0} f' "$T1DIR/TODO.md" | grep -c "verified:2026-04-14" || true)
	# Must have [x] marker
	has_x=$(awk '/^## Done$/{f=1;next} /^## /{f=0} f' "$T1DIR/TODO.md" | grep -c "\[x\]" | grep -c "t100" 2>/dev/null ||
		awk '/^## Done$/{f=1;next} /^## /{f=0} f' "$T1DIR/TODO.md" | grep "t100" | grep -c "\[x\]" || true)
	if [[ "$in_ready" -eq 0 && "$in_done" -ge 1 && "$has_proof" -ge 1 ]]; then
		print_result "test1: single-line task moves to ## Done" 0
	else
		print_result "test1: single-line task moves to ## Done" 1 \
			"(in_ready=$in_ready in_done=$in_done has_proof=$has_proof)"
	fi
fi

# =============================================================================
# Test 2: Task with explicit subtask IDs (t200.1, t200.2) indented under parent
#         — parent + indented subtasks all move together to ## Done
# =============================================================================
T2DIR="${TEST_ROOT}/t2"
setup_fixture "$T2DIR" "## Backlog

- [ ] t200 Parent task #tag ~2h ref:GH#2
  - [x] t200.1 Subtask 1 completed:2026-01-01
  - [x] t200.2 Subtask 2 completed:2026-01-01
- [ ] t201 Next task #other ~1h ref:GH#3

## Done

- [x] t001 Old task pr:#1 completed:2026-01-01
"

run_complete "$T2DIR" "t200" "--verified 2026-04-14"
rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result "test2: task with indented subtask IDs exits 0" 1 "(exit $rc)"
else
	# t200 parent must not be in Backlog (exact match to avoid t200.1 false-positive)
	in_backlog=$(awk '/^## Backlog$/{f=1;next} /^## /{f=0} f' "$T2DIR/TODO.md" |
		grep -cE "^- \[.?\] t200 " || true)
	# t200 parent must be in ## Done as [x]
	in_done=$(awk '/^## Done$/{f=1;next} /^## /{f=0} f' "$T2DIR/TODO.md" |
		grep -cE "^- \[x\] t200 " || true)
	# t201 must still be in Backlog
	t201_in_backlog=$(awk '/^## Backlog$/{f=1;next} /^## /{f=0} f' "$T2DIR/TODO.md" |
		grep -c "t201" || true)
	if [[ "$in_backlog" -eq 0 && "$in_done" -ge 1 && "$t201_in_backlog" -ge 1 ]]; then
		print_result "test2: task with indented subtask IDs moves to ## Done (t201 stays)" 0
	else
		print_result "test2: task with indented subtask IDs moves to ## Done (t201 stays)" 1 \
			"(in_backlog=$in_backlog in_done=$in_done t201_backlog=$t201_in_backlog)"
	fi
fi

# =============================================================================
# Test 3: Task with indentation-based subtasks — subtasks move with parent
# =============================================================================
T3DIR="${TEST_ROOT}/t3"
setup_fixture "$T3DIR" "## Ready

- [ ] t300 Parent task with subtasks #tag ~3h ref:GH#3
  - [x] t300.1 Sub A completed:2026-01-01
  - [x] t300.2 Sub B completed:2026-01-01
- [ ] t301 Next task #other ~1h ref:GH#4

## Done

"

run_complete "$T3DIR" "t300" "--verified 2026-04-14"
rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result "test3: task with indented subtasks exits 0" 1 "(exit $rc)"
else
	# Parent and subtasks should be gone from ## Ready
	in_ready=$(awk '/^## Ready$/{f=1;next} /^## /{f=0} f' "$T3DIR/TODO.md" | grep -c "t300" || true)
	# Parent should be in ## Done
	in_done=$(awk '/^## Done$/{f=1;next} /^## /{f=0} f' "$T3DIR/TODO.md" | grep "t300 " | grep -c "\[x\]" || true)
	# t301 must still be in ## Ready
	t301_in_ready=$(awk '/^## Ready$/{f=1;next} /^## /{f=0} f' "$T3DIR/TODO.md" | grep -c "t301" || true)
	if [[ "$in_ready" -eq 0 && "$in_done" -ge 1 && "$t301_in_ready" -ge 1 ]]; then
		print_result "test3: task with indented subtasks moves to ## Done (t301 stays)" 0
	else
		print_result "test3: task with indented subtasks moves to ## Done (t301 stays)" 1 \
			"(in_ready=$in_ready in_done=$in_done t301_in_ready=$t301_in_ready)"
	fi
fi

# =============================================================================
# Test 4: Task already in ## Done — no-op (idempotent), exit 0
# =============================================================================
T4DIR="${TEST_ROOT}/t4"
setup_fixture "$T4DIR" "## Ready

- [ ] t401 Some open task #tag ~1h ref:GH#5

## Done

- [x] t400 Already done task pr:#99 completed:2026-01-01
"

run_complete "$T4DIR" "t400" "--verified 2026-04-14"
rc=$?
# Should exit 0 (idempotent)
if [[ "$rc" -eq 0 ]]; then
	# Should still be in ## Done and only once
	done_count=$(awk '/^## Done$/{f=1;next} /^## /{f=0} f' "$T4DIR/TODO.md" | grep -c "t400" || true)
	if [[ "$done_count" -eq 1 ]]; then
		print_result "test4: task already in ## Done is idempotent (exit 0, no duplicate)" 0
	else
		print_result "test4: task already in ## Done is idempotent (exit 0, no duplicate)" 1 \
			"(done_count=$done_count, expected 1)"
	fi
else
	print_result "test4: task already in ## Done is idempotent (exit 0, no duplicate)" 1 \
		"(exit $rc, expected 0)"
fi

# =============================================================================
# Test 5: Task in ## In Progress — also moves to ## Done
# =============================================================================
T5DIR="${TEST_ROOT}/t5"
setup_fixture "$T5DIR" "## In Progress

- [ ] t500 In-progress task #tag ~2h ref:GH#6

## Done

- [x] t001 Old done pr:#1 completed:2026-01-01
"

run_complete "$T5DIR" "t500" "--verified 2026-04-14"
rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result "test5: task in ## In Progress exits 0" 1 "(exit $rc)"
else
	in_progress=$(awk '/^## In Progress$/{f=1;next} /^## /{f=0} f' "$T5DIR/TODO.md" | grep -c "t500" || true)
	in_done=$(awk '/^## Done$/{f=1;next} /^## /{f=0} f' "$T5DIR/TODO.md" | grep "t500" | grep -c "\[x\]" || true)
	if [[ "$in_progress" -eq 0 && "$in_done" -ge 1 ]]; then
		print_result "test5: task in ## In Progress moves to ## Done" 0
	else
		print_result "test5: task in ## In Progress moves to ## Done" 1 \
			"(in_progress=$in_progress in_done=$in_done)"
	fi
fi

# =============================================================================
# Test 6: ## Done header missing — should error out, exit non-zero
# =============================================================================
T6DIR="${TEST_ROOT}/t6"
setup_fixture "$T6DIR" "## Ready

- [ ] t600 My task #tag ~1h ref:GH#7

## Declined
"

run_complete "$T6DIR" "t600" "--verified 2026-04-14"
rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result "test6: missing ## Done header causes non-zero exit" 0
else
	print_result "test6: missing ## Done header causes non-zero exit" 1 \
		"(exit $rc, expected non-zero)"
fi

# =============================================================================
# Test 7: Multiple consecutive entries — block boundary does not bleed into next
# =============================================================================
T7DIR="${TEST_ROOT}/t7"
setup_fixture "$T7DIR" "## Backlog

- [ ] t700 First task #tag ~1h ref:GH#8
- [ ] t701 Second task #other ~2h ref:GH#9
- [ ] t702 Third task #more ~3h ref:GH#10

## Done

"

run_complete "$T7DIR" "t701" "--verified 2026-04-14"
rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result "test7: middle task from consecutive list exits 0" 1 "(exit $rc)"
else
	# t700 and t702 must still be in ## Backlog
	t700_in_backlog=$(awk '/^## Backlog$/{f=1;next} /^## /{f=0} f' "$T7DIR/TODO.md" | grep -c "t700" || true)
	t702_in_backlog=$(awk '/^## Backlog$/{f=1;next} /^## /{f=0} f' "$T7DIR/TODO.md" | grep -c "t702" || true)
	# t701 must be in ## Done
	t701_in_done=$(awk '/^## Done$/{f=1;next} /^## /{f=0} f' "$T7DIR/TODO.md" | grep "t701" | grep -c "\[x\]" || true)
	# t701 must NOT be in ## Backlog
	t701_in_backlog=$(awk '/^## Backlog$/{f=1;next} /^## /{f=0} f' "$T7DIR/TODO.md" | grep -c "t701" || true)
	if [[ "$t700_in_backlog" -ge 1 && "$t702_in_backlog" -ge 1 &&
		"$t701_in_done" -ge 1 && "$t701_in_backlog" -eq 0 ]]; then
		print_result "test7: middle task moves to ## Done, neighbors remain" 0
	else
		print_result "test7: middle task moves to ## Done, neighbors remain" 1 \
			"(t700_backlog=$t700_in_backlog t702_backlog=$t702_in_backlog t701_done=$t701_in_done t701_backlog=$t701_in_backlog)"
	fi
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "Results: $((TESTS_RUN - TESTS_FAILED))/$TESTS_RUN passed"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
