#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Test task-complete-helper.sh: verify complete_task() moves entries to ## Done
# instead of doing in-place [x] marking (t2060, GH#18746).
#
# Edge cases covered:
#   1. Single-line task (no subtasks) → moves to ## Done
#   2. Task with indented subtask IDs (children move WITH parent)
#   3. Task with indented completed subtasks (children move WITH parent)
#   4. Task already in ## Done → idempotent warn+exit 0
#   5. Task in ## In Progress section → also moves to ## Done
#   6. ## Done header missing → errors out clearly, no invention
#   7. Multiple consecutive entries → block boundary doesn't bleed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SCRIPT="${SCRIPT_DIR}/../task-complete-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/repo/todo/tasks"

	# Stub git so commit works without real git config
	mkdir -p "${TEST_ROOT}/bin"
	cat >"${TEST_ROOT}/bin/git" <<'GITEOF'
#!/usr/bin/env bash
# Stub: succeed silently for add/commit, forward everything else to real git
if [[ "${1:-}" == "add" || "${1:-}" == "commit" ]]; then
	exit 0
fi
exec /usr/bin/git "$@"
GITEOF
	chmod +x "${TEST_ROOT}/bin/git"
	export PATH="${TEST_ROOT}/bin:${PATH}"

	# Initialise a real git repo (needed for git -C to work)
	/usr/bin/git init "${TEST_ROOT}/repo" -q
	/usr/bin/git -C "${TEST_ROOT}/repo" config user.email "test@test.com"
	/usr/bin/git -C "${TEST_ROOT}/repo" config user.name "Test"

	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Write a fixture TODO.md to the test repo and stage+commit it.
write_fixture() {
	local content="$1"
	printf '%s\n' "$content" >"${TEST_ROOT}/repo/TODO.md"
	/usr/bin/git -C "${TEST_ROOT}/repo" add TODO.md 2>/dev/null || true
	/usr/bin/git -C "${TEST_ROOT}/repo" commit -q -m "fixture" --allow-empty 2>/dev/null || true
	return 0
}

# Run the helper for a task and capture output + exit code.
run_helper() {
	local task_id="$1"
	shift
	"$HELPER_SCRIPT" "$task_id" \
		--verified "2026-01-01" \
		--skip-merge-check \
		--no-push \
		--repo-path "${TEST_ROOT}/repo" \
		"$@" 2>&1
	return $?
}

# Assert that the task appears in ## Done and NOT in the original section.
assert_in_done() {
	local task_id="$1"
	local todo_file="${TEST_ROOT}/repo/TODO.md"

	local in_done
	in_done=$(awk '/^## Done$/{f=1; next} /^## /{f=0} f' "$todo_file" |
		grep -cE "^[[:space:]]*- \[x\] ${task_id}( |$)" || true)

	if [[ "$in_done" -eq 0 ]]; then
		return 1
	fi
	return 0
}

assert_not_in_section() {
	local task_id="$1"
	local section="$2"
	local todo_file="${TEST_ROOT}/repo/TODO.md"

	local count
	count=$(awk "/^## ${section}\$/{f=1; next} /^## /{f=0} f" "$todo_file" |
		grep -cE "^[[:space:]]*- \[.?\] ${task_id}( |$)" || true)

	if [[ "$count" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# ------------------------------------------------------------------
# Test 1: single-line task with no subtasks moves to ## Done
# ------------------------------------------------------------------
test_single_line_task() {
	write_fixture "## Ready

- [ ] t001 simple task description

## Done

- [x] t999 existing done task verified:2026-01-01
"

	if ! run_helper t001 >/dev/null 2>&1; then
		print_result "single-line task: helper exits 0" 1 "helper returned non-zero"
		return 0
	fi

	if ! assert_in_done "t001"; then
		print_result "single-line task: t001 in ## Done" 1 "t001 not found in ## Done"
		return 0
	fi

	if ! assert_not_in_section "t001" "Ready"; then
		print_result "single-line task: t001 removed from ## Ready" 1 "t001 still in ## Ready"
		return 0
	fi

	# Existing Done entry preserved
	local still_done
	still_done=$(grep -c 't999' "${TEST_ROOT}/repo/TODO.md" || true)
	if [[ "$still_done" -eq 0 ]]; then
		print_result "single-line task: t999 preserved in ## Done" 1 "t999 disappeared"
		return 0
	fi

	print_result "single-line task: no subtasks, moves to Done" 0
	return 0
}

# ------------------------------------------------------------------
# Test 2: task with indented subtask IDs — children move WITH parent
# ------------------------------------------------------------------
test_task_with_indented_subtasks() {
	write_fixture "## Ready

- [ ] t002 parent task description
  - [x] t002.1 first subtask completed:2026-01-01
  - [x] t002.2 second subtask completed:2026-01-01

- [ ] t003 next open task

## Done

"

	if ! run_helper t002 >/dev/null 2>&1; then
		print_result "task with indented subtasks: helper exits 0" 1 "helper returned non-zero"
		return 0
	fi

	if ! assert_in_done "t002"; then
		print_result "task with indented subtasks: t002 in ## Done" 1 "parent not in ## Done"
		return 0
	fi

	# Subtasks should also be in Done section (they moved with parent)
	local subtasks_in_done
	subtasks_in_done=$(awk '/^## Done$/{f=1; next} /^## /{f=0} f' "${TEST_ROOT}/repo/TODO.md" |
		grep -c 't002\.' || true)
	if [[ "$subtasks_in_done" -lt 2 ]]; then
		print_result "task with indented subtasks: children moved with parent" 1 \
			"expected 2 subtasks in Done, found $subtasks_in_done"
		return 0
	fi

	if ! assert_not_in_section "t002" "Ready"; then
		print_result "task with indented subtasks: parent removed from Ready" 1 \
			"t002 still in ## Ready"
		return 0
	fi

	# t003 should stay open in Ready
	local t003_open
	t003_open=$(awk '/^## Ready$/{f=1; next} /^## /{f=0} f' "${TEST_ROOT}/repo/TODO.md" |
		grep -c 't003' || true)
	if [[ "$t003_open" -eq 0 ]]; then
		print_result "task with indented subtasks: t003 stays in Ready" 1 \
			"t003 disappeared from Ready"
		return 0
	fi

	print_result "task with indented subtasks: parent + children move to Done" 0
	return 0
}

# ------------------------------------------------------------------
# Test 3: task with explicit open subtasks — blocked (cannot mark complete)
# ------------------------------------------------------------------
test_task_blocked_by_open_subtasks() {
	write_fixture "## Ready

- [ ] t010 parent with open child
  - [ ] t010.1 open subtask

## Done

"

	local output
	output=$(run_helper t010 2>&1 || true)

	if echo "$output" | grep -q "open subtask"; then
		print_result "blocked by open subtasks: error reported" 0
	else
		print_result "blocked by open subtasks: error reported" 1 \
			"expected 'open subtask' in error output"
	fi

	# Task must still be open in Ready
	local still_open
	still_open=$(grep -c '\[ \] t010 ' "${TEST_ROOT}/repo/TODO.md" || true)
	if [[ "$still_open" -eq 0 ]]; then
		print_result "blocked by open subtasks: parent stays open" 1 \
			"t010 was modified despite open subtask"
		return 0
	fi

	print_result "blocked by open subtasks: parent stays open" 0
	return 0
}

# ------------------------------------------------------------------
# Test 4: task already in ## Done — idempotent warn+exit 0
# ------------------------------------------------------------------
test_idempotent_already_done() {
	write_fixture "## Ready

- [ ] t020 some open task

## Done

- [x] t030 already complete verified:2026-01-01
"

	local output
	output=$(run_helper t030 2>&1)
	local rc=$?

	if [[ "$rc" -ne 0 ]]; then
		print_result "idempotent: already-done task exits 0" 1 \
			"expected exit 0, got $rc"
		return 0
	fi

	if ! echo "$output" | grep -qi "already"; then
		print_result "idempotent: warns about already-complete" 1 \
			"expected 'already' in output"
		return 0
	fi

	print_result "idempotent: already-done task warns and exits 0" 0
	return 0
}

# ------------------------------------------------------------------
# Test 5: task in ## In Progress also moves to ## Done
# ------------------------------------------------------------------
test_task_in_progress_moves_to_done() {
	write_fixture "## Ready

## In Progress

- [ ] t040 in-progress task description

## Done

"

	if ! run_helper t040 >/dev/null 2>&1; then
		print_result "in-progress task: helper exits 0" 1 "helper returned non-zero"
		return 0
	fi

	if ! assert_in_done "t040"; then
		print_result "in-progress task: t040 in ## Done" 1 "t040 not found in ## Done"
		return 0
	fi

	if ! assert_not_in_section "t040" "In Progress"; then
		print_result "in-progress task: t040 removed from In Progress" 1 \
			"t040 still in ## In Progress"
		return 0
	fi

	print_result "in-progress task: moves to ## Done" 0
	return 0
}

# ------------------------------------------------------------------
# Test 6: ## Done header missing — errors out, does not invent it
# ------------------------------------------------------------------
test_missing_done_section() {
	write_fixture "## Ready

- [ ] t050 task without done section

## Declined

"

	local output
	output=$(run_helper t050 2>&1 || true)

	if echo "$output" | grep -qi "Done.*not found\|not found.*Done\|cannot move"; then
		print_result "missing Done section: error reported" 0
	else
		print_result "missing Done section: error reported" 1 \
			"expected error about missing ## Done section"
	fi

	# File must be unchanged (t050 still open, no ## Done invented)
	if grep -q "^## Done$" "${TEST_ROOT}/repo/TODO.md"; then
		print_result "missing Done section: ## Done not invented" 1 \
			"## Done was invented in file"
		return 0
	fi

	if ! grep -q '\[ \] t050' "${TEST_ROOT}/repo/TODO.md"; then
		print_result "missing Done section: t050 unchanged after error" 1 \
			"t050 was modified despite missing ## Done"
		return 0
	fi

	print_result "missing Done section: errors out, file unchanged" 0
	return 0
}

# ------------------------------------------------------------------
# Test 7: multiple consecutive entries — block boundary doesn't bleed
# ------------------------------------------------------------------
test_consecutive_entries_no_bleed() {
	write_fixture "## Ready

- [ ] t060 first consecutive task
- [ ] t061 second consecutive task  description
- [ ] t062 third consecutive task

## Done

"

	if ! run_helper t060 >/dev/null 2>&1; then
		print_result "consecutive entries: t060 completes successfully" 1 \
			"helper returned non-zero for t060"
		return 0
	fi

	if ! assert_in_done "t060"; then
		print_result "consecutive entries: t060 in ## Done" 1 "t060 not in ## Done"
		return 0
	fi

	# t061 and t062 must still be open in Ready
	local t061_open
	t061_open=$(awk '/^## Ready$/{f=1; next} /^## /{f=0} f' "${TEST_ROOT}/repo/TODO.md" |
		grep -c '\[ \] t061' || true)
	if [[ "$t061_open" -eq 0 ]]; then
		print_result "consecutive entries: t061 stays in Ready" 1 \
			"t061 disappeared (block bled into t061)"
		return 0
	fi

	local t062_open
	t062_open=$(awk '/^## Ready$/{f=1; next} /^## /{f=0} f' "${TEST_ROOT}/repo/TODO.md" |
		grep -c '\[ \] t062' || true)
	if [[ "$t062_open" -eq 0 ]]; then
		print_result "consecutive entries: t062 stays in Ready" 1 \
			"t062 disappeared (block bled into t062)"
		return 0
	fi

	print_result "consecutive entries: only t060 moves, t061/t062 stay" 0
	return 0
}

# ------------------------------------------------------------------
# Test: proof-log + completed:date correctly appended to moved entry
# ------------------------------------------------------------------
test_proof_log_on_moved_entry() {
	write_fixture "## Ready

- [ ] t070 task for proof-log check

## Done

"

	if ! run_helper t070 >/dev/null 2>&1; then
		print_result "proof-log: helper exits 0" 1 "helper returned non-zero"
		return 0
	fi

	# Entry in Done must have verified:DATE and completed:DATE
	local done_line
	done_line=$(awk '/^## Done$/{f=1; next} /^## /{f=0} f' "${TEST_ROOT}/repo/TODO.md" |
		grep 't070' || true)

	if ! echo "$done_line" | grep -qE "verified:[0-9]{4}-[0-9]{2}-[0-9]{2}"; then
		print_result "proof-log: verified:DATE in moved entry" 1 \
			"verified date not found in: $done_line"
		return 0
	fi

	if ! echo "$done_line" | grep -qE "completed:[0-9]{4}-[0-9]{2}-[0-9]{2}"; then
		print_result "proof-log: completed:DATE in moved entry" 1 \
			"completed date not found in: $done_line"
		return 0
	fi

	if ! echo "$done_line" | grep -q "\[x\]"; then
		print_result "proof-log: checkbox is [x] in moved entry" 1 \
			"[x] marker not found in: $done_line"
		return 0
	fi

	print_result "proof-log: verified + completed dates on moved entry" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	test_single_line_task
	test_task_with_indented_subtasks
	test_task_blocked_by_open_subtasks
	test_idempotent_already_done
	test_task_in_progress_moves_to_done
	test_missing_done_section
	test_consecutive_entries_no_bleed
	test_proof_log_on_moved_entry

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
