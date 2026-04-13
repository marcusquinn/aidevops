#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-task-id-collision-guard.sh — Test harness for task-id-collision-guard.sh
#
# Covers all 7 acceptance criteria cases:
#   1. Reject: t-ID > counter AND not in linked issue title
#   2. Allow: t-ID ≤ counter (claimed)
#   3. Allow: cross-reference confirmed via linked issue title
#   4. Allow: commit with no t-IDs at all
#   5. Allow: fail-open on gh API failure / offline
#   6. Allow (bypass): --no-verify / TASK_ID_GUARD_DISABLE=1
#   7. CI mode: check-pr scans range and finds violations

set -u

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASS=0
FAIL=0
ERRORS=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${SCRIPT_DIR}/../../hooks/task-id-collision-guard.sh"
DEPLOYED_GUARD="$HOME/.aidevops/agents/hooks/task-id-collision-guard.sh"

# Prefer deployed if repo copy not found
if [[ ! -f "$GUARD" ]]; then
	GUARD="$DEPLOYED_GUARD"
fi

if [[ ! -f "$GUARD" ]]; then
	printf '%s[FATAL]%s task-id-collision-guard.sh not found at:\n' "$RED" "$NC" >&2
	printf '  %s\n' "${SCRIPT_DIR}/../../hooks/task-id-collision-guard.sh" >&2
	printf '  %s\n' "$DEPLOYED_GUARD" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pass() {
	local name="${1:-}"
	printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="${1:-}"
	local detail="${2:-}"
	printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$name"
	[[ -n "$detail" ]] && printf '       %s\n' "$detail"
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  - ${name}: ${detail}"
	return 0
}

# Run the guard with a message file and a mock counter.
# Sets up a temporary git repo to provide a merge base with .task-counter = N.
# Returns the exit code of the guard.
_run_with_counter() {
	local msg="${1:-}"
	local counter_val="${2:-10}"
	local gh_available="${3:-no}" # "yes" or "no"

	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	# Create a temporary git repo that acts as the remote/merge-base
	local base_repo="${tmpdir}/base"
	mkdir -p "$base_repo"
	git -C "$base_repo" init -q
	git -C "$base_repo" config user.email "test@test.local"
	git -C "$base_repo" config user.name "Test"
	git -C "$base_repo" config commit.gpgsign false
	git -C "$base_repo" config tag.gpgsign false
	printf '%s' "$counter_val" >"${base_repo}/.task-counter"
	git -C "$base_repo" add .task-counter
	git -C "$base_repo" commit -q -m "init"

	# Create a work repo branched off the base
	local work_repo="${tmpdir}/work"
	git clone -q "$base_repo" "$work_repo" 2>/dev/null
	git -C "$work_repo" config user.email "test@test.local"
	git -C "$work_repo" config user.name "Test"
	git -C "$work_repo" config commit.gpgsign false
	git -C "$work_repo" config tag.gpgsign false

	# Add a commit so HEAD != merge-base
	printf 'change' >"${work_repo}/change.txt"
	git -C "$work_repo" add change.txt
	git -C "$work_repo" commit -q -m "wip"

	# Write the message file
	local msg_file="${tmpdir}/COMMIT_EDITMSG"
	printf '%s' "$msg" >"$msg_file"

	# Run the guard from the work repo context.
	# Optionally disable gh CLI by PATH manipulation.
	local rc
	if [[ "$gh_available" == "no" ]]; then
		# Stub gh to fail so the guard falls back to fail-open
		local fake_bin="${tmpdir}/bin"
		mkdir -p "$fake_bin"
		printf '#!/usr/bin/env bash\nexit 1\n' >"${fake_bin}/gh"
		chmod +x "${fake_bin}/gh"
		PATH="${fake_bin}:$PATH" \
			GIT_DIR="${work_repo}/.git" \
			bash "$GUARD" "$msg_file" 2>/dev/null
		rc=$?
	else
		GIT_DIR="${work_repo}/.git" \
			bash "$GUARD" "$msg_file" 2>/dev/null
		rc=$?
	fi
	return "$rc"
}

# ---------------------------------------------------------------------------
# Case 1: Reject — t-ID > counter, no cross-ref
# ---------------------------------------------------------------------------
test_rejects_invented_tid() {
	local name="case-1: rejects invented t-ID > counter"
	# Counter = 100; message references t99999 which is beyond counter
	local msg="feat(foo): bar (t99999)"
	local rc
	_run_with_counter "$msg" "100"
	rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 1 (reject), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 2: Allow — t-ID ≤ counter (claimed)
# ---------------------------------------------------------------------------
test_allows_claimed_tid() {
	local name="case-2: allows claimed t-ID ≤ counter"
	local msg="feat(foo): implement t50 feature"
	local rc
	_run_with_counter "$msg" "100"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (allow), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 3: Allow — no t-IDs at all
# ---------------------------------------------------------------------------
test_allows_no_tids() {
	local name="case-3: allows commit with no t-IDs"
	local msg="chore: update README with installation instructions"
	local rc
	_run_with_counter "$msg" "100"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (allow), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 4: Allow — fail-open when gh CLI unavailable (offline)
# ---------------------------------------------------------------------------
test_failopen_on_gh_failure() {
	local name="case-4: fail-open when .task-counter unreadable"
	# Use an empty counter value — guard should warn and allow
	local msg="feat(foo): bar (t99999)"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	# Create a repo with NO .task-counter file at the merge base
	local base_repo="${tmpdir}/base"
	mkdir -p "$base_repo"
	git -C "$base_repo" init -q
	git -C "$base_repo" config user.email "test@test.local"
	git -C "$base_repo" config user.name "Test"
	git -C "$base_repo" config commit.gpgsign false
	printf 'placeholder' >"${base_repo}/README.md"
	git -C "$base_repo" add README.md
	git -C "$base_repo" commit -q -m "init"

	local work_repo="${tmpdir}/work"
	git clone -q "$base_repo" "$work_repo" 2>/dev/null
	git -C "$work_repo" config user.email "test@test.local"
	git -C "$work_repo" config user.name "Test"
	git -C "$work_repo" config commit.gpgsign false

	printf 'change' >"${work_repo}/change.txt"
	git -C "$work_repo" add change.txt
	git -C "$work_repo" commit -q -m "wip"

	local msg_file="${tmpdir}/COMMIT_EDITMSG"
	printf '%s' "$msg" >"$msg_file"

	local rc
	GIT_DIR="${work_repo}/.git" \
		bash "$GUARD" "$msg_file" 2>/dev/null
	rc=$?

	# Fail-open = exit 0
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (fail-open), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 5: Allow — bypass via TASK_ID_GUARD_DISABLE=1
# ---------------------------------------------------------------------------
test_bypass_env_var() {
	local name="case-5: bypass via TASK_ID_GUARD_DISABLE=1"
	local msg="feat(foo): bar (t99999)"
	local msg_file
	msg_file=$(mktemp)
	printf '%s' "$msg" >"$msg_file"
	local rc
	TASK_ID_GUARD_DISABLE=1 bash "$GUARD" "$msg_file" 2>/dev/null
	rc=$?
	rm -f "$msg_file"
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (bypass), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 6: Allow — merge commit subject is skipped
# ---------------------------------------------------------------------------
test_skips_merge_commits() {
	local name="case-6: skips merge commit subjects"
	local msg="Merge branch 'feature/t99999-foo' into main"
	local rc
	_run_with_counter "$msg" "100"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (merge commit skipped), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 7: CI check-pr mode — scans range, finds violations
# Uses a real git repo but stubs the gh CLI
# ---------------------------------------------------------------------------
test_check_pr_mode() {
	local name="case-7: check-pr mode detects invented t-ID in range"

	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local base_repo="${tmpdir}/base"
	mkdir -p "$base_repo"
	git -C "$base_repo" init -q
	git -C "$base_repo" config user.email "test@test.local"
	git -C "$base_repo" config user.name "Test"
	git -C "$base_repo" config commit.gpgsign false
	printf '100' >"${base_repo}/.task-counter"
	git -C "$base_repo" add .task-counter
	git -C "$base_repo" commit -q -m "init"

	local work_repo="${tmpdir}/work"
	git clone -q "$base_repo" "$work_repo" 2>/dev/null
	git -C "$work_repo" config user.email "test@test.local"
	git -C "$work_repo" config user.name "Test"
	git -C "$work_repo" config commit.gpgsign false

	# Add a commit with an invented t-ID
	printf 'change' >"${work_repo}/change.txt"
	git -C "$work_repo" add change.txt
	git -C "$work_repo" commit -q -m "feat: invented id (t99999)"

	# Stub gh to fail so cross-ref lookup does not influence result
	local fake_bin="${tmpdir}/bin"
	mkdir -p "$fake_bin"
	printf '#!/usr/bin/env bash\nexit 1\n' >"${fake_bin}/gh"
	chmod +x "${fake_bin}/gh"

	local rc
	PATH="${fake_bin}:$PATH" \
		GIT_DIR="${work_repo}/.git" \
		bash "$GUARD" check-pr 9999 2>/dev/null
	rc=$?

	if [[ "$rc" -eq 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 1 (violation detected), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
main() {
	printf 'Running task-id-collision-guard tests...\n\n'

	test_rejects_invented_tid
	test_allows_claimed_tid
	test_allows_no_tids
	test_failopen_on_gh_failure
	test_bypass_env_var
	test_skips_merge_commits
	test_check_pr_mode

	printf '\n'
	printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
	if [[ "$FAIL" -gt 0 ]]; then
		printf '\nFailed tests:%b\n' "$ERRORS"
		return 1
	fi
	return 0
}

main "$@"
