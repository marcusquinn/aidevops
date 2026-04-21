#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-task-id-collision-guard-reuse.sh — Regression test for the
# reuse-without-claim gap (t2567 / GH#20001).
#
# Reproduces the t2377 incident pattern:
#   Session A legitimately claims t100 via claim-task-id.sh (chore: claim t100).
#   Session B hardcodes t100 in a commit on a different branch (no claim commit).
#   Phase 1 guard must reject Session B's commit and allow Session A's commit.
#
# Cases:
#   1. Reject — t-ID ≤ counter, no branch claim commit, no linked issues (reuse)
#   2. Allow  — t-ID ≤ counter, branch has matching single-ID claim commit
#   3. Allow  — t-ID ≤ counter, branch has range claim commit covering the ID
#   4. Allow  — t-ID ≤ counter, no branch claim, but linked issue title confirms
#   5. Reject — t-ID ≤ counter, no branch claim, linked issue title does NOT confirm
#   6. Allow  — TASK_ID_GUARD_DISABLE=1 bypasses without running any checks

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

# ---------------------------------------------------------------------------
# Build a throw-away git repo that simulates the t2377 incident scenario.
#
# Creates:
#   base_repo  — the "origin" repo. Starts at counter=99; after Session A's
#                CAS is applied directly, becomes counter=100.
#   SESSA_REPO — "Session A" branch. Clones when counter=99, then writes
#                counter=100 (real file diff) and commits the claim commit.
#   SESSB_REPO — "Session B" branch. Clones AFTER base_repo has counter=100
#                (simulates that Session A's claim is visible on origin/main).
#                Has NO claim commit for t100.
#
# Sets globals: TMPDIR_REUSE, SESSA_REPO, SESSB_REPO
# ---------------------------------------------------------------------------
_setup_t2377_scenario() {
	TMPDIR_REUSE=$(mktemp -d)

	local base_repo="${TMPDIR_REUSE}/base"
	mkdir -p "$base_repo"
	git -C "$base_repo" init -q
	git -C "$base_repo" config user.email "test@test.local"
	git -C "$base_repo" config user.name "Test"
	git -C "$base_repo" config commit.gpgsign false
	git -C "$base_repo" config tag.gpgsign false
	# Start at counter=99 so Session A's bump to 100 is a real file change.
	printf '99' >"${base_repo}/.task-counter"
	git -C "$base_repo" add .task-counter
	git -C "$base_repo" commit -q -m "init: counter=99"

	# Session A — clones when counter=99, creates sessA/foo branch, bumps to 100.
	# The real file diff (99→100) makes git commit succeed without --allow-empty.
	SESSA_REPO="${TMPDIR_REUSE}/sessA"
	git clone -q "$base_repo" "$SESSA_REPO" 2>/dev/null
	git -C "$SESSA_REPO" config user.email "test@test.local"
	git -C "$SESSA_REPO" config user.name "Test"
	git -C "$SESSA_REPO" config commit.gpgsign false
	git -C "$SESSA_REPO" config tag.gpgsign false
	git -C "$SESSA_REPO" checkout -q -b "sessA/foo"
	printf '100' >"${SESSA_REPO}/.task-counter"
	git -C "$SESSA_REPO" add .task-counter
	git -C "$SESSA_REPO" commit -q -m "chore: claim t100 [sessA_nonce]"

	# Simulate Session A pushing its CAS commit back to origin by updating
	# base_repo directly (git push to non-bare checked-out branch is not safe).
	printf '100' >"${base_repo}/.task-counter"
	git -C "$base_repo" add .task-counter
	git -C "$base_repo" commit -q -m "chore: claim t100 [sessA_nonce]"

	# Session B — clones AFTER origin has counter=100.
	# Session B knows about t100 (≤ counter) but has no claim commit on its branch.
	SESSB_REPO="${TMPDIR_REUSE}/sessB"
	git clone -q "$base_repo" "$SESSB_REPO" 2>/dev/null
	git -C "$SESSB_REPO" config user.email "test@test.local"
	git -C "$SESSB_REPO" config user.name "Test"
	git -C "$SESSB_REPO" config commit.gpgsign false
	git -C "$SESSB_REPO" config tag.gpgsign false
	git -C "$SESSB_REPO" checkout -q -b "sessB/bar"
	# Add a non-claim commit so HEAD diverges from merge-base (required for
	# _find_merge_base to produce a non-empty range for log inspection).
	printf 'wip' >"${SESSB_REPO}/wip.txt"
	git -C "$SESSB_REPO" add wip.txt
	git -C "$SESSB_REPO" commit -q -m "wip: some unrelated change"

	return 0
}

# Build a fake gh stub that always exits 1 (no network)
_make_no_gh_bin() {
	local dir="${1:-}"
	local fake_bin="${dir}/bin"
	mkdir -p "$fake_bin"
	printf '#!/usr/bin/env bash\nexit 1\n' >"${fake_bin}/gh"
	chmod +x "${fake_bin}/gh"
	printf '%s' "$fake_bin"
	return 0
}

# Build a fake gh stub that returns a specific issue title for a given issue number
_make_mock_gh_bin() {
	local dir="${1:-}"
	local issue_num="${2:-}"
	local issue_title="${3:-}"
	local fake_bin="${dir}/mock_bin"
	mkdir -p "$fake_bin"
	cat >"${fake_bin}/gh" <<GHEOF
#!/usr/bin/env bash
if [[ "\$1" == "issue" && "\$2" == "view" ]]; then
	for arg in "\$@"; do
		if [[ "\$arg" == "${issue_num}" ]]; then
			printf '%s\n' "${issue_title}"
			exit 0
		fi
	done
fi
exit 1
GHEOF
	chmod +x "${fake_bin}/gh"
	printf '%s' "$fake_bin"
	return 0
}

# ---------------------------------------------------------------------------
# Case 1: Reject — t-ID ≤ counter, no branch claim commit, no linked issues
# Reproduces exactly the t2377 Session B commit pattern.
# ---------------------------------------------------------------------------
test_rejects_reuse_without_claim() {
	local name="case-1: rejects t-ID ≤ counter on branch without claim commit (t2377 pattern)"

	_setup_t2377_scenario
	# shellcheck disable=SC2064
	trap "rm -rf '${TMPDIR_REUSE}'" RETURN

	local msg_file="${TMPDIR_REUSE}/COMMIT_EDITMSG"
	printf 't100: do something' >"$msg_file"

	local no_gh_bin
	no_gh_bin=$(_make_no_gh_bin "$TMPDIR_REUSE")

	local rc
	PATH="${no_gh_bin}:$PATH" \
		GIT_DIR="${SESSB_REPO}/.git" \
		bash "$GUARD" "$msg_file" 2>/dev/null
	rc=$?

	if [[ "$rc" -eq 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 1 (reuse without claim rejected), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 2: Allow — t-ID ≤ counter, branch has matching single-ID claim commit
# Session A legitimately claimed t100 via chore: claim t100 [...].
# ---------------------------------------------------------------------------
test_allows_with_claim_commit() {
	local name="case-2: allows t-ID ≤ counter when branch has matching single-ID claim commit"

	_setup_t2377_scenario
	# shellcheck disable=SC2064
	trap "rm -rf '${TMPDIR_REUSE}'" RETURN

	local msg_file="${TMPDIR_REUSE}/COMMIT_EDITMSG"
	printf 't100: do something' >"$msg_file"

	local no_gh_bin
	no_gh_bin=$(_make_no_gh_bin "$TMPDIR_REUSE")

	local rc
	PATH="${no_gh_bin}:$PATH" \
		GIT_DIR="${SESSA_REPO}/.git" \
		bash "$GUARD" "$msg_file" 2>/dev/null
	rc=$?

	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (branch claim commit found — allowed), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 3: Allow — t-ID ≤ counter, branch has range claim covering the ID
# Tests "chore: claim t98..t102 [nonce]" covers t100.
# ---------------------------------------------------------------------------
test_allows_with_range_claim_commit() {
	local name="case-3: allows t-ID ≤ counter when branch has range claim covering the ID"

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
	git -C "$base_repo" config tag.gpgsign false
	# Start at 200 — well above 102, so _resolve_current_counter returns 200
	# and t100 ≤ 200 enters the reuse-check path without any working-copy magic.
	printf '200' >"${base_repo}/.task-counter"
	git -C "$base_repo" add .task-counter
	git -C "$base_repo" commit -q -m "init: counter=200"

	local work_repo="${tmpdir}/work"
	git clone -q "$base_repo" "$work_repo" 2>/dev/null
	git -C "$work_repo" config user.email "test@test.local"
	git -C "$work_repo" config user.name "Test"
	git -C "$work_repo" config commit.gpgsign false
	git -C "$work_repo" config tag.gpgsign false
	git -C "$work_repo" checkout -q -b "feature/range-claim"

	# Range claim commit: add a separate file to ensure a unique tree hash.
	# We do NOT change .task-counter here — if both repos committed the same
	# tree (same .task-counter value) at the same second, git would produce
	# identical commit hashes, causing merge-base(HEAD, origin) == HEAD,
	# making the log range empty and the range detection fail.
	printf 'range-claim-marker' >"${work_repo}/claim-marker.txt"
	git -C "$work_repo" add claim-marker.txt
	git -C "$work_repo" commit -q -m "chore: claim t98..t102 [range_nonce]"

	local msg_file="${tmpdir}/COMMIT_EDITMSG"
	printf 't100: implement range-claimed feature' >"$msg_file"

	local no_gh_bin="${tmpdir}/bin"
	mkdir -p "$no_gh_bin"
	printf '#!/usr/bin/env bash\nexit 1\n' >"${no_gh_bin}/gh"
	chmod +x "${no_gh_bin}/gh"

	local rc
	PATH="${no_gh_bin}:$PATH" \
		GIT_DIR="${work_repo}/.git" \
		bash "$GUARD" "$msg_file" 2>/dev/null
	rc=$?

	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (range claim t98..t102 covers t100 — allowed), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 4: Allow — t-ID ≤ counter, no branch claim, but linked issue confirms
# A worker cross-references someone else's task via Resolves #NNN where the
# issue title contains the t-ID.
# ---------------------------------------------------------------------------
test_allows_via_linked_issue_when_no_branch_claim() {
	local name="case-4: allows t-ID ≤ counter with no branch claim when linked issue title confirms"

	_setup_t2377_scenario
	# shellcheck disable=SC2064
	trap "rm -rf '${TMPDIR_REUSE}'" RETURN

	local msg_file="${TMPDIR_REUSE}/COMMIT_EDITMSG"
	# Session B commit: no branch claim, but cross-references via Resolves
	printf 't100: some work\n\nResolves #42' >"$msg_file"

	# Mock gh returns issue #42 with a title containing t100
	local mock_bin
	mock_bin=$(_make_mock_gh_bin "$TMPDIR_REUSE" "42" "t100: legitimate claimed task title")

	local rc
	PATH="${mock_bin}:$PATH" \
		GIT_DIR="${SESSB_REPO}/.git" \
		bash "$GUARD" "$msg_file" 2>/dev/null
	rc=$?

	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (cross-ref via linked issue title confirmed — allowed), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 5: Reject — t-ID ≤ counter, no branch claim, linked issue title wrong
# Issue #42 exists but its title does NOT contain t100 → reuse violation.
# ---------------------------------------------------------------------------
test_rejects_when_linked_issue_title_does_not_match() {
	local name="case-5: rejects t-ID ≤ counter when linked issue title does NOT contain the t-ID"

	_setup_t2377_scenario
	# shellcheck disable=SC2064
	trap "rm -rf '${TMPDIR_REUSE}'" RETURN

	local msg_file="${TMPDIR_REUSE}/COMMIT_EDITMSG"
	printf 't100: some work\n\nResolves #42' >"$msg_file"

	# Mock gh returns issue #42 with an unrelated title (no t100)
	local mock_bin
	mock_bin=$(_make_mock_gh_bin "$TMPDIR_REUSE" "42" "chore: unrelated task with different ID")

	local rc
	PATH="${mock_bin}:$PATH" \
		GIT_DIR="${SESSB_REPO}/.git" \
		bash "$GUARD" "$msg_file" 2>/dev/null
	rc=$?

	if [[ "$rc" -eq 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 1 (linked issue title mismatch — reuse rejected), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 6: Allow — TASK_ID_GUARD_DISABLE=1 bypasses all checks
# Must exit 0 without running any branch-claim or linked-issue checks.
# ---------------------------------------------------------------------------
test_bypass_skips_reuse_check() {
	local name="case-6: TASK_ID_GUARD_DISABLE=1 bypasses reuse check"
	local msg_file
	msg_file=$(mktemp)
	printf 't100: something without any claim' >"$msg_file"
	local rc
	TASK_ID_GUARD_DISABLE=1 bash "$GUARD" "$msg_file" 2>/dev/null
	rc=$?
	rm -f "$msg_file"
	if [[ "$rc" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected exit 0 (bypass active — no checks run), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
main() {
	printf 'Running task-id-collision-guard reuse tests (t2567 / GH#20001)...\n\n'

	test_rejects_reuse_without_claim
	test_allows_with_claim_commit
	test_allows_with_range_claim_commit
	test_allows_via_linked_issue_when_no_branch_claim
	test_rejects_when_linked_issue_title_does_not_match
	test_bypass_skips_reuse_check

	printf '\n'
	printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
	if [[ "$FAIL" -gt 0 ]]; then
		printf '\nFailed tests:%b\n' "$ERRORS"
		return 1
	fi
	return 0
}

main "$@"
