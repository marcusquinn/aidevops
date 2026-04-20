#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-parent-tag-sync.sh — t2436 regression guard.
#
# Asserts that the #parent TODO tag is applied as parent-task label
# SYNCHRONOUSLY at issue creation time across three code paths:
#
#   1. _scan_todo_labels_for_task() in claim-task-id.sh derives parent-task
#      from a TODO entry when the task ID is already in TODO.md.
#   2. _gh_wrapper_derive_todo_labels() in shared-gh-wrappers.sh derives
#      parent-task from a TODO entry with a task ID in --title.
#   3. _is_assigned_check_hydration_window() in dispatch-dedup-helper.sh
#      blocks dispatch on recently-created issues (age < window).
#
# Canonical failure: GH#20081 — peer runner dispatched 48s after issue
# creation because parent-task label was missing (label sync is async).
# All three fixes close different segments of the race window.

set -uo pipefail

# Not using `set -e` — negative assertions capture non-zero exits.

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

# Sandbox HOME to avoid side-effects on real config
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

# =============================================================================
# Part 1 — _scan_todo_labels_for_task() in claim-task-id.sh
# =============================================================================
# Source claim-task-id.sh to access its internal functions.
# BASH_SOURCE[0] != $0 when sourced, so main() is skipped.
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/claim-task-id.sh" >/dev/null 2>&1
set +e

# Create a temporary TODO.md fixture with a #parent-tagged task
FIXTURE_DIR=$(mktemp -d)
cat >"${FIXTURE_DIR}/TODO.md" <<'EOF'
# TODO

## Active

- [ ] t2430 Scanner rewrite #parent #tier:thinking ~8h
- [ ] t2431 Phase 1 implementation #auto-dispatch #tier:standard ~2h
EOF

# Scenario 1a: task ID with #parent → derives parent-task label
result=$(_scan_todo_labels_for_task "t2430" "${FIXTURE_DIR}" 2>/dev/null)
msg="1a: _scan_todo_labels_for_task: #parent tag → parent-task label"
if printf '%s' "$result" | grep -q "parent-task"; then
	print_result "$msg" 0
else
	print_result "$msg" 1 "(got: '${result}')"
fi

# Scenario 1b: task ID without #parent → no parent-task label
result=$(_scan_todo_labels_for_task "t2431" "${FIXTURE_DIR}" 2>/dev/null)
msg="1b: _scan_todo_labels_for_task: non-#parent task → no parent-task"
if ! printf '%s' "$result" | grep -q "parent-task"; then
	print_result "$msg" 0
else
	print_result "$msg" 1 "(got: '${result}')"
fi

# Scenario 1c: task ID not in TODO.md → empty (no spurious labels)
result=$(_scan_todo_labels_for_task "t9999" "${FIXTURE_DIR}" 2>/dev/null)
msg="1c: _scan_todo_labels_for_task: unknown ID → empty result"
if [[ -z "$result" ]]; then
	print_result "$msg" 0
else
	print_result "$msg" 1 "(got: '${result}')"
fi

# Scenario 1d: #parent alias maps to parent-task, not raw 'parent'
result=$(_scan_todo_labels_for_task "t2430" "${FIXTURE_DIR}" 2>/dev/null)
msg="1d: _scan_todo_labels_for_task: #parent → 'parent-task' (not 'parent')"
if printf '%s' "$result" | grep -qw "parent-task"; then
	print_result "$msg" 0
else
	print_result "$msg" 1 "(got: '${result}')"
fi

# Scenario 1e: parse_args label normalisation (#parent → parent-task via map_tags_to_labels)
msg_mta="1e: map_tags_to_labels: 'parent' alias → 'parent-task'"
msg_mtb="1e: map_tags_to_labels: 'meta' alias → 'parent-task'"
if [[ "$(type -t map_tags_to_labels 2>/dev/null)" == "function" ]]; then
	normalised=$(map_tags_to_labels "parent" 2>/dev/null)
	if [[ "$normalised" == "parent-task" ]]; then
		print_result "$msg_mta" 0
	else
		print_result "$msg_mta" 1 "(got: '${normalised}')"
	fi

	normalised=$(map_tags_to_labels "meta" 2>/dev/null)
	if [[ "$normalised" == "parent-task" ]]; then
		print_result "$msg_mtb" 0
	else
		print_result "$msg_mtb" 1 "(got: '${normalised}')"
	fi
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '%sFAIL%s %s\n' "$TEST_RED" "$TEST_RESET" \
		"map_tags_to_labels not loaded (issue-sync-lib.sh missing)"
fi

rm -rf "${FIXTURE_DIR}"

# =============================================================================
# Part 2 — _gh_wrapper_derive_todo_labels() in shared-gh-wrappers.sh
# =============================================================================
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/shared-gh-wrappers.sh" >/dev/null 2>&1
set +e

FIXTURE2_DIR=$(mktemp -d)
cat >"${FIXTURE2_DIR}/TODO.md" <<'EOF'
# TODO

## Active

- [ ] t2430 Scanner rewrite #parent #tier:thinking ~8h
- [ ] t2432 Decomposed phase 1 #auto-dispatch ~2h
EOF

# Scenario 2a: derive labels from TODO.md via task ID in title
pushd "${FIXTURE2_DIR}" >/dev/null 2>&1 || true
result=$(_gh_wrapper_derive_todo_labels "t2430" 2>/dev/null)
msg="2a: _gh_wrapper_derive_todo_labels: derives parent-task from TODO.md"
if printf '%s' "$result" | grep -q "parent-task"; then
	print_result "$msg" 0
else
	print_result "$msg" 1 "(got: '${result}')"
fi
popd >/dev/null 2>&1 || true

# Scenario 2b: extract task ID from --title "tNNN: ..." arg
task_id_result=$(_gh_wrapper_extract_task_id_from_title \
	--repo "owner/repo" --title "t2430: Scanner rewrite" --label "framework" 2>/dev/null)
msg="2b: _gh_wrapper_extract_task_id_from_title: extracts t2430 from --title"
if [[ "$task_id_result" == "t2430" ]]; then
	print_result "$msg" 0
else
	print_result "$msg" 1 "(got: '${task_id_result}')"
fi

# Scenario 2c: explicit --todo-task-id wins over --title auto-detection
task_id_result=$(_gh_wrapper_extract_task_id_from_title \
	--title "t9999: Wrong task" --todo-task-id "t2430" 2>/dev/null)
msg="2c: _gh_wrapper_extract_task_id_from_title: --todo-task-id overrides --title"
if [[ "$task_id_result" == "t2430" ]]; then
	print_result "$msg" 0
else
	print_result "$msg" 1 "(got: '${task_id_result}')"
fi

rm -rf "${FIXTURE2_DIR}"

# =============================================================================
# Part 3 — _is_assigned_check_hydration_window() in dispatch-dedup-helper.sh
# =============================================================================
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/dispatch-dedup-helper.sh" >/dev/null 2>&1
set +e

# Scenario 3a: issue created NOW → should be blocked (window=30s)
NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
msg_3a="3a: hydration_window: blocks young issue (age<30s)"
if [[ -n "$NOW" ]]; then
	YOUNG_META=$(printf '{"createdAt":"%s","assignees":[],"labels":[]}' "$NOW")
	signal=$(DISPATCH_HYDRATION_WINDOW_S=30 \
		_is_assigned_check_hydration_window "$YOUNG_META" "9999" "owner/repo" 2>/dev/null)
	rc=$?
	if [[ "$rc" -eq 0 && "$signal" == *"HYDRATION_WINDOW"* ]]; then
		print_result "$msg_3a" 0
	else
		print_result "$msg_3a" 1 "(rc=${rc}, signal='${signal}')"
	fi
else
	print_result "$msg_3a (date unavailable — skip)" 0
fi

# Scenario 3b: DISPATCH_HYDRATION_WINDOW_S=0 disables the check → fail-open
OLD_META='{"createdAt":"2020-01-01T00:00:00Z","assignees":[],"labels":[]}'
msg_3b="3b: hydration_window: disabled when window=0"
signal=$(DISPATCH_HYDRATION_WINDOW_S=0 \
	_is_assigned_check_hydration_window "$OLD_META" "9999" "owner/repo" 2>/dev/null)
rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result "$msg_3b" 0
else
	print_result "$msg_3b" 1 "(expected rc=1, got rc=${rc})"
fi

# Scenario 3c: old issue (2020) → not blocked even with window=30
msg_3c="3c: hydration_window: allows old issue through"
signal=$(DISPATCH_HYDRATION_WINDOW_S=30 \
	_is_assigned_check_hydration_window "$OLD_META" "9999" "owner/repo" 2>/dev/null)
rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result "$msg_3c" 0
else
	print_result "$msg_3c" 1 "(expected rc=1, got rc=${rc}; signal='${signal}')"
fi

# Scenario 3d: missing createdAt field → fail-open (return 1)
NO_DATE_META='{"assignees":[],"labels":[]}'
msg_3d="3d: hydration_window: fails open on missing createdAt"
signal=$(DISPATCH_HYDRATION_WINDOW_S=30 \
	_is_assigned_check_hydration_window "$NO_DATE_META" "9999" "owner/repo" 2>/dev/null)
rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result "$msg_3d" 0
else
	print_result "$msg_3d" 1 "(expected rc=1, got rc=${rc})"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll tests passed%s\n' "$TEST_GREEN" "$TEST_RESET"
	exit 0
else
	exit 1
fi
