#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-task-id-collision-guard.sh — Test harness for task-id-collision-guard.sh
#
# Covers all 12 acceptance criteria cases:
#   1. Reject: t-ID > counter AND not in linked issue title
#   2. Allow: t-ID ≤ counter (claimed)
#   3. Allow: cross-reference confirmed via linked issue title
#   4. Allow: commit with no t-IDs at all
#   5. Allow: fail-open on gh API failure / offline
#   6. Allow (bypass): --no-verify / TASK_ID_GUARD_DISABLE=1
#   7. CI mode: check-pr scans range and finds violations
#   8. Allow: stale-worktree — t-IDs claimed after worktree creation (GH#19054)
#   9. Allow: leading-zero .task-counter doesn't trigger octal crash (GH#19667)
#  10. Allow: Ref #NNN where linked issue title contains the t-ID (GH#19783)
#  11. Allow: For #NNN where linked issue title contains the t-ID (GH#19783)
#  12. Reject: Ref #NNN where linked issue title does NOT contain the t-ID (GH#19783)

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
# Case 4: Allow — fail-open when gh API fails (closing issue present, gh errors)
# This validates acceptance criterion: "fail-safe on gh API failure or offline state"
# ---------------------------------------------------------------------------
test_failopen_on_gh_failure() {
	local name="case-4: fail-open when gh API fails with closing issue present"
	# Message has t99999 (> counter) AND a Resolves footer, but gh fails
	local msg
	msg=$(printf 'feat(foo): invented id (t99999)\n\nResolves #123\n')
	local rc
	# Pass gh_available=no — stubs gh to exit 1 (API/offline failure)
	_run_with_counter "$msg" "100" "no"
	rc=$?
	# Fail-open = exit 0 (guard cannot verify cross-ref, CI will catch on push)
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (fail-open on gh failure), got $rc"
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
# Case 8: Allow — stale-worktree scenario (GH#19054)
#
# Simulates the observed failure:
#   1. Worktree created at main tip X (counter=10)
#   2. Two more claims pushed to origin/main → counter=12
#   3. Commit in the worktree references t11 and t12
#
# With the OLD guard: merge-base=X → counter=10 → t11,t12 > 10 → BLOCK (wrong)
# With the NEW guard: _resolve_current_counter reads origin/main → 12 → ALLOW (correct)
# ---------------------------------------------------------------------------
test_stale_worktree_scenario() {
	local name="case-8: allows t-IDs claimed after worktree creation (stale-worktree)"

	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	# Create the "origin" repo with counter=10 on main
	local base_repo="${tmpdir}/base"
	mkdir -p "$base_repo"
	git -C "$base_repo" init -q
	git -C "$base_repo" config user.email "test@test.local"
	git -C "$base_repo" config user.name "Test"
	git -C "$base_repo" config commit.gpgsign false
	git -C "$base_repo" config tag.gpgsign false
	printf '10' >"${base_repo}/.task-counter"
	git -C "$base_repo" add .task-counter
	git -C "$base_repo" commit -q -m "init: counter=10"

	# Clone to simulate a worktree created at counter=10
	local work_repo="${tmpdir}/work"
	git clone -q "$base_repo" "$work_repo" 2>/dev/null
	git -C "$work_repo" config user.email "test@test.local"
	git -C "$work_repo" config user.name "Test"
	git -C "$work_repo" config commit.gpgsign false
	git -C "$work_repo" config tag.gpgsign false

	# Add a WIP commit to work_repo so HEAD diverges from origin/main
	printf 'impl' >"${work_repo}/impl.txt"
	git -C "$work_repo" add impl.txt
	git -C "$work_repo" commit -q -m "wip: implementation placeholder"

	# Simulate two more claim-task-id.sh runs on origin/main (counter → 11 → 12)
	printf '11' >"${base_repo}/.task-counter"
	git -C "$base_repo" add .task-counter
	git -C "$base_repo" commit -q -m "chore: claim t11 — counter=11"
	printf '12' >"${base_repo}/.task-counter"
	git -C "$base_repo" add .task-counter
	git -C "$base_repo" commit -q -m "chore: claim t12 — counter=12"

	# Fetch so work_repo's origin/main reflects counter=12
	git -C "$work_repo" fetch -q origin 2>/dev/null

	# Write a commit message referencing t11 and t12 (both legitimately claimed)
	local msg="feat(t2109): implement stale-worktree fix t11 t12"
	local msg_file="${tmpdir}/COMMIT_EDITMSG"
	printf '%s' "$msg" >"$msg_file"

	# Stub gh to fail — guard must rely on counter comparison alone
	local fake_bin="${tmpdir}/bin"
	mkdir -p "$fake_bin"
	printf '#!/usr/bin/env bash\nexit 1\n' >"${fake_bin}/gh"
	chmod +x "${fake_bin}/gh"

	local rc
	PATH="${fake_bin}:$PATH" \
		GIT_DIR="${work_repo}/.git" \
		bash "$GUARD" "$msg_file" 2>/dev/null
	rc=$?

	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (t11,t12 ≤ origin/main counter 12), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 9: Allow — leading-zero .task-counter doesn't trigger octal crash
# (GH#19667: _resolve_current_counter octal-trap symmetry fix)
# ---------------------------------------------------------------------------
test_octal_trap_leading_zero_counter() {
	local name="case-9: allows t-ID ≤ leading-zero counter (octal-trap in _resolve_current_counter)"
	# Counter written as "09" — was read by _resolve_current_counter via
	# [[ "$val" -gt "$best" ]] which triggers bash's octal parser on the
	# second comparison iteration (when $best is already "09").
	# After the fix: ((10#$val > 10#$best)) forces decimal, so 9 ≤ 9 → allowed.
	local msg="feat: implement GH#19667 t9"
	local rc
	_run_with_counter "$msg" "09"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (t9 ≤ counter 09 in base-10), got $rc (likely octal crash)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Helper: run the guard with a mocked gh CLI that returns a known issue title.
# Args:
#   msg         = commit message text
#   counter_val = .task-counter value
#   issue_num   = issue number the mock gh should respond to
#   issue_title = title the mock gh returns for that issue
# ---------------------------------------------------------------------------
_run_with_mock_gh_title() {
	local msg="${1:-}"
	local counter_val="${2:-10}"
	local issue_num="${3:-}"
	local issue_title="${4:-}"

	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	# Create base git repo
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

	local work_repo="${tmpdir}/work"
	git clone -q "$base_repo" "$work_repo" 2>/dev/null
	git -C "$work_repo" config user.email "test@test.local"
	git -C "$work_repo" config user.name "Test"
	git -C "$work_repo" config commit.gpgsign false
	git -C "$work_repo" config tag.gpgsign false

	printf 'change' >"${work_repo}/change.txt"
	git -C "$work_repo" add change.txt
	git -C "$work_repo" commit -q -m "wip"

	local msg_file="${tmpdir}/COMMIT_EDITMSG"
	printf '%s' "$msg" >"$msg_file"

	# Mock gh: return the supplied title as JSON when queried for the given issue_num
	local fake_bin="${tmpdir}/bin"
	mkdir -p "$fake_bin"
	cat >"${fake_bin}/gh" <<GHEOF
#!/usr/bin/env bash
# Mock gh for test: responds to "gh issue view <N> --json title --jq .title"
# Scan all arguments for a numeric token matching the expected issue number.
found=0
for arg in "\$@"; do
    if [[ "\$arg" == "${issue_num}" ]]; then
        found=1
        break
    fi
done
if [[ "\$found" == "1" ]]; then
    printf '%s\n' "${issue_title}"
    exit 0
fi
exit 1
GHEOF
	chmod +x "${fake_bin}/gh"

	local rc
	PATH="${fake_bin}:$PATH" \
		GIT_DIR="${work_repo}/.git" \
		bash "$GUARD" "$msg_file" 2>/dev/null
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		return 0
	fi
	return 1
}

# ---------------------------------------------------------------------------
# Case 10: Allow — Ref #NNN where issue title contains the t-ID
# (AC1 from issue #19783)
# ---------------------------------------------------------------------------
test_ref_keyword_with_matching_title() {
	local name="case-10: allows Ref #NNN when linked issue title contains the t-ID"
	# Counter = 100; t99999 > counter; but Ref footer links to issue 42 whose
	# title contains t99999, confirming the ID was legitimately claimed.
	local msg
	msg=$(printf 't99999: brief for self-healing improvement\n\nRef #42')
	local rc
	_run_with_mock_gh_title "$msg" "100" "42" "t99999: feat(issue-sync): detect umbrella-style parent-tasks"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (Ref #NNN confirmed via issue title), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 11: Allow — For #NNN where issue title contains the t-ID
# (AC2 from issue #19783)
# ---------------------------------------------------------------------------
test_for_keyword_with_matching_title() {
	local name="case-11: allows For #NNN when linked issue title contains the t-ID"
	local msg
	msg=$(printf 't99999: add brief for parent-task phase\n\nFor #42')
	local rc
	_run_with_mock_gh_title "$msg" "100" "42" "t99999: parent-task phase-1 planning"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (For #NNN confirmed via issue title), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 12: Reject — Ref #NNN where issue title does NOT contain the t-ID
# (AC3 from issue #19783 — regression guard)
# ---------------------------------------------------------------------------
test_ref_keyword_without_matching_title() {
	local name="case-12: rejects Ref #NNN when linked issue title does NOT contain the t-ID"
	# t99999 > counter; Ref footer points to issue 42 whose title is unrelated
	local msg
	msg=$(printf 't99999: some commit\n\nRef #42')
	local rc
	_run_with_mock_gh_title "$msg" "100" "42" "chore: unrelated task with no matching ID"
	rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 1 (Ref with non-matching title still blocked), got $rc"
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
	test_stale_worktree_scenario
	test_octal_trap_leading_zero_counter
	test_ref_keyword_with_matching_title
	test_for_keyword_with_matching_title
	test_ref_keyword_without_matching_title

	printf '\n'
	printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
	if [[ "$FAIL" -gt 0 ]]; then
		printf '\nFailed tests:%b\n' "$ERRORS"
		return 1
	fi
	return 0
}

main "$@"
