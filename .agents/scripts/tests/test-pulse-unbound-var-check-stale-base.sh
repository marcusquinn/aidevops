#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-unbound-var-check-stale-base.sh — Verifies the diff-extraction
# logic in `.github/workflows/pulse-unbound-var-check.yml` against every
# false-positive class the gate has shipped to date:
#
# Class 1 — Stale-base (t3084):
#   When a PR branch lags origin/main by N commits, the original
#   `git diff $BASE_SHA $HEAD_SHA | grep '^+'` extracted ALL line
#   additions — including lines added on main since divergence. Trained
#   the gate to fire on phantom violations (canonical: PR #21827,
#   45-commit-stale base, ~15 false positives). Fix: anchor the LHS of
#   the diff to `git merge-base(BASE, HEAD)` so we measure from the
#   actual divergence point, not whatever stale ref GitHub passed in.
#
# Class 2 — Intra-branch reversal (t3206):
#   When a branch introduces a violation in commit 1 and fixes it in
#   commit 2, the t3084 implementation (`git log -p --first-parent
#   MERGE_BASE..HEAD_SHA | grep '^+'`) extracted BOTH the bad lines from
#   commit 1 AND the corrected lines from commit 2 in the same `+`
#   stream. The scanner tripped on the bad lines even though they were
#   reverted within the branch. Forced contributors to squash + force-push
#   for a clean run (canonical: PR #21912 / t3194). Fix: use `git diff
#   MERGE_BASE HEAD` (NET tree delta) instead of accumulated commit
#   history — transient additions that were subsequently removed simply
#   don't appear in the extraction.
#
# Verifies (against a temp git repo simulating each scenario):
#   1. Stale-base scenario: branch behind main with no .sh changes does NOT
#      surface main-side additions as "branch additions".
#   2. True-positive scenario: branch with a real new violation DOES surface
#      it as a branch addition.
#   3. Merge-from-main scenario: branch that merged main into itself does
#      NOT surface main-side additions (the merge-base advances correctly,
#      so `git diff` only shows the branch's contribution).
#   4. Up-to-date scenario: branch tip on top of current main works correctly
#      (regression check — fix must not break the common case).
#   5. Intra-branch reversal scenario (t3206): branch introduces a violation
#      then fixes it within the same branch — the extraction must see only
#      the corrected (fixed) lines, NOT the transient bad ones.
#
# Tests are structural — no live GitHub API calls, no network access.

set -u

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_REPO_ROOT="$(cd "${TEST_SCRIPT_DIR}/../../.." && pwd)"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

# ── helpers ──────────────────────────────────────────────────────────

pass() {
	local _msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '%s[PASS]%s %s\n' "$TEST_GREEN" "$TEST_NC" "$_msg"
	return 0
}

fail() {
	local _msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '%s[FAIL]%s %s\n' "$TEST_RED" "$TEST_NC" "$_msg" >&2
	return 1
}

info() {
	local _msg="$1"
	printf '%s[INFO]%s %s\n' "$TEST_BLUE" "$TEST_NC" "$_msg"
	return 0
}

# Replicates the workflow's diff-extraction logic against a given repo,
# BASE_SHA, and HEAD_SHA. Returns the path to a tmp dir containing per-file
# diff output. Mirrors .github/workflows/pulse-unbound-var-check.yml exactly.
extract_diff_additions() {
	local _repo="$1"
	local _base_sha="$2"
	local _head_sha="$3"
	local _out_dir
	_out_dir=$(mktemp -d -t puv-test-extract-XXXXXX)

	(
		cd "$_repo" || exit 1

		local _merge_base
		_merge_base=$(git merge-base "$_base_sha" "$_head_sha" 2>/dev/null || true)
		if [[ -z "$_merge_base" ]]; then
			_merge_base="$_base_sha"
		fi

		local _changed
		_changed=$(git diff --name-only "$_merge_base" "$_head_sha" -- \
			'.agents/scripts/pulse-*.sh' 2>/dev/null || true)
		if [[ -z "$_changed" ]]; then
			return 0
		fi

		local _file _basename _diff_file
		while IFS= read -r _file; do
			[[ -n "$_file" ]] || continue
			_basename=$(basename "$_file")
			_diff_file="${_out_dir}/${_basename}"
			# t3206: use `git diff MERGE_BASE HEAD` (NET tree delta) instead of
			# `git log -p --first-parent` (accumulated commit history) so
			# transient additions that were later reverted within the branch
			# do not appear in the extraction. Mirrors the workflow exactly.
			git diff "${_merge_base}" "${_head_sha}" -- "$_file" 2>/dev/null \
				| grep '^+' | grep -v '^+++' | sed 's/^+//' \
				> "$_diff_file" || true
		done <<<"$_changed"
	)

	printf '%s\n' "$_out_dir"
	return 0
}

# Initialise a fresh repo with .agents/scripts/pulse-test.sh already populated
# at the initial commit. Returns the repo path on stdout.
init_test_repo() {
	local _repo
	_repo=$(mktemp -d -t puv-test-repo-XXXXXX)
	(
		cd "$_repo" || exit 1
		git init -q -b main
		git config user.email "test@example.com"
		git config user.name "Test User"
		mkdir -p .agents/scripts
		cat >.agents/scripts/pulse-test.sh <<'EOF'
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Initial state: clean function with proper var init.

initial_function() {
	local _foo="" _bar=""
	_foo="hello"
	_bar="world"
	printf '%s %s\n' "$_foo" "$_bar"
	return 0
}
EOF
		git add -A
		git commit -q -m "initial: pulse-test.sh"
	)
	printf '%s\n' "$_repo"
	return 0
}

# Append a clean commit (no violation) to the current branch.
add_clean_main_commit() {
	local _repo="$1"
	local _msg="$2"
	(
		cd "$_repo" || exit 1
		cat >>.agents/scripts/pulse-test.sh <<'EOF'

# Main-side addition (NOT a violation).
main_clean_function() {
	local _x="" _y=""
	_x="main"
	_y="side"
	return 0
}
EOF
		git add -A
		git commit -q -m "$_msg"
	)
	return 0
}

# Append a commit containing a multi-var-without-init violation.
add_violation_commit() {
	local _repo="$1"
	local _msg="$2"
	(
		cd "$_repo" || exit 1
		cat >>.agents/scripts/pulse-test.sh <<'EOF'

# This function contains the t2841 anti-pattern.
violation_function() {
	local _g_nums _b_nums _p_nums
	_g_nums="counted"
	return 0
}
EOF
		git add -A
		git commit -q -m "$_msg"
	)
	return 0
}

# Append a commit containing main-side multi-var-without-init violations.
# Used to simulate "main has accumulated violations the branch never touched".
add_main_violation_commit() {
	local _repo="$1"
	local _msg="$2"
	(
		cd "$_repo" || exit 1
		cat >>.agents/scripts/pulse-test.sh <<'EOF'

# Main-side violation (would fail the scanner if extracted).
main_violation_function() {
	local _a _b _c _d
	_a="oops"
	return 0
}
EOF
		git add -A
		git commit -q -m "$_msg"
	)
	return 0
}

# Append two commits that together model the t3206 intra-branch reversal:
#   - Commit 1: introduces a transient VIOLATION block PLUS a CLEAN block.
#   - Commit 2: removes ONLY the violation block; the clean block survives.
# NET tree delta: only the clean block (no violation). The clean block ensures
# `git diff --name-only MERGE_BASE HEAD` still surfaces the file (otherwise
# the workflow's first-pass file filter would skip extraction entirely and
# the test would not exercise the patch-extraction code path). The accumulated
# `git log -p` extraction would still surface the transient violation as a
# `+` line; the corrected `git diff` extraction must not.
add_violation_then_fix_commits() {
	local _repo="$1"
	local _intro_msg="$2"
	local _fix_msg="$3"
	(
		cd "$_repo" || exit 1
		# Commit 1: append the transient violation followed by a clean block.
		# We use a marker comment to delimit the violation block so commit 2
		# can remove it surgically while preserving the clean block.
		cat >>.agents/scripts/pulse-test.sh <<'EOF'

# >>> TRANSIENT VIOLATION (removed in next commit) >>>
transient_violation() {
	local _t1 _t2 _t3
	_t1="introduced"
	return 0
}
# <<< TRANSIENT VIOLATION <<<

# Clean block — survives both commits and forms the NET tree delta.
clean_branch_addition() {
	local _surviving=""
	_surviving="kept"
	return 0
}
EOF
		git add -A
		git commit -q -m "$_intro_msg"
		# Commit 2: remove the violation block, keep the clean block.
		# Use awk to drop the marker-delimited region in place.
		awk '
			/^# >>> TRANSIENT VIOLATION/ { skip=1; next }
			/^# <<< TRANSIENT VIOLATION/ { skip=0; next }
			skip { next }
			{ print }
		' .agents/scripts/pulse-test.sh >.agents/scripts/pulse-test.sh.tmp
		mv .agents/scripts/pulse-test.sh.tmp .agents/scripts/pulse-test.sh
		git add -A
		git commit -q -m "$_fix_msg"
	)
	return 0
}

cleanup_repo() {
	local _path="$1"
	if [[ -n "$_path" && -d "$_path" ]]; then
		rm -rf -- "$_path"
	fi
	return 0
}

# ── tests ────────────────────────────────────────────────────────────

# Test 1: Stale-base PR with no .sh changes — main has accumulated violations
# since the branch diverged. The fix must NOT surface those as branch additions.
test_stale_base_no_sh_changes() {
	info "test: stale-base PR with no .sh changes does not surface main violations"
	local _repo
	_repo=$(init_test_repo)

	(
		cd "$_repo" || exit 1
		# Branch off the initial commit — call this the divergence point.
		git checkout -q -b feature/stale-base
		# Add a non-sh change on the branch (simulates a docs-only PR).
		printf '# A docs change\n' >README.md
		git add -A
		git commit -q -m "branch: docs only"
		local _head_sha
		_head_sha=$(git rev-parse HEAD)
		# Now simulate main racing ahead with violations the branch never sees.
		git checkout -q main
		add_main_violation_commit "$_repo" "main: introduce violation 1"
		add_main_violation_commit "$_repo" "main: introduce violation 2"
		local _base_sha
		_base_sha=$(git rev-parse HEAD)

		# BASE_SHA is current main HEAD (45-commit-stale scenario simulated).
		# HEAD_SHA is the branch tip (no .sh changes).
		printf '%s\n' "$_base_sha" >/tmp/.puv-test-base-sha
		printf '%s\n' "$_head_sha" >/tmp/.puv-test-head-sha
	)

	local _base_sha _head_sha _out_dir
	_base_sha=$(cat /tmp/.puv-test-base-sha)
	_head_sha=$(cat /tmp/.puv-test-head-sha)
	_out_dir=$(extract_diff_additions "$_repo" "$_base_sha" "$_head_sha")

	# The extraction directory should be empty (no .sh files changed) OR the
	# pulse-test.sh file should have no extracted lines. Reproducing the
	# exact pre-fix bug requires GitHub's specific `pull_request.base.sha`
	# semantics on long-stale PRs, which a local-only test cannot fully
	# simulate. What we CAN verify is the post-fix invariant: the new
	# extraction must never surface main-side commits as branch additions,
	# regardless of the BASE_SHA passed in.
	local _diff_file="${_out_dir}/pulse-test.sh"
	if [[ -f "$_diff_file" ]] && [[ -s "$_diff_file" ]]; then
		fail "stale-base extraction surfaced phantom additions: $(wc -l <"$_diff_file") lines"
		printf '  Phantom content:\n'
		sed 's/^/    /' "$_diff_file"
	else
		pass "stale-base extraction is empty (no phantom additions)"
	fi

	cleanup_repo "$_repo"
	cleanup_repo "$_out_dir"
	rm -f /tmp/.puv-test-base-sha /tmp/.puv-test-head-sha
	return 0
}

# Test 2: True-positive — branch introduces a real violation, the fix
# MUST surface it.
test_real_violation_is_surfaced() {
	info "test: branch with real violation DOES surface it"
	local _repo
	_repo=$(init_test_repo)

	(
		cd "$_repo" || exit 1
		git checkout -q -b feature/real-violation
		add_violation_commit "$_repo" "branch: introduce violation"
		local _head_sha
		_head_sha=$(git rev-parse HEAD)
		git checkout -q main
		local _base_sha
		_base_sha=$(git rev-parse HEAD)
		printf '%s\n' "$_base_sha" >/tmp/.puv-test-base-sha
		printf '%s\n' "$_head_sha" >/tmp/.puv-test-head-sha
	)

	local _base_sha _head_sha _out_dir
	_base_sha=$(cat /tmp/.puv-test-base-sha)
	_head_sha=$(cat /tmp/.puv-test-head-sha)
	_out_dir=$(extract_diff_additions "$_repo" "$_base_sha" "$_head_sha")

	local _diff_file="${_out_dir}/pulse-test.sh"
	if [[ -f "$_diff_file" ]] && grep -q 'local _g_nums _b_nums _p_nums' "$_diff_file"; then
		pass "real violation IS surfaced by extraction"
	else
		fail "real violation was NOT surfaced — extraction may have over-filtered"
		[[ -f "$_diff_file" ]] && {
			printf '  Extracted content:\n'
			sed 's/^/    /' "$_diff_file"
		}
	fi

	cleanup_repo "$_repo"
	cleanup_repo "$_out_dir"
	rm -f /tmp/.puv-test-base-sha /tmp/.puv-test-head-sha
	return 0
}

# Test 3: Merge-from-main — branch merged main into itself. Fix must NOT
# surface main-side additions brought in by the merge.
test_merge_from_main_no_phantoms() {
	info "test: branch with merge-from-main does not surface main violations"
	local _repo
	_repo=$(init_test_repo)

	(
		cd "$_repo" || exit 1
		git checkout -q -b feature/merge-from-main
		# Branch makes a clean change.
		printf '# Branch readme\n' >>README.md
		git add -A
		git commit -q -m "branch: docs"
		# Main accumulates violations.
		git checkout -q main
		add_main_violation_commit "$_repo" "main: violation"
		# Branch merges main into itself.
		git checkout -q feature/merge-from-main
		git merge -q --no-edit main
		local _head_sha
		_head_sha=$(git rev-parse HEAD)
		git checkout -q main
		local _base_sha
		_base_sha=$(git rev-parse HEAD)
		printf '%s\n' "$_base_sha" >/tmp/.puv-test-base-sha
		printf '%s\n' "$_head_sha" >/tmp/.puv-test-head-sha
	)

	local _base_sha _head_sha _out_dir
	_base_sha=$(cat /tmp/.puv-test-base-sha)
	_head_sha=$(cat /tmp/.puv-test-head-sha)
	_out_dir=$(extract_diff_additions "$_repo" "$_base_sha" "$_head_sha")

	local _diff_file="${_out_dir}/pulse-test.sh"
	# --first-parent should skip the merge-side commits, so main_violation
	# should NOT appear in the extraction.
	if [[ -f "$_diff_file" ]] && grep -q 'local _a _b _c _d' "$_diff_file"; then
		fail "merge-from-main extraction surfaced main-side violation (--first-parent failed?)"
		printf '  Phantom content:\n'
		sed 's/^/    /' "$_diff_file"
	else
		pass "merge-from-main extraction does not surface main-side violations"
	fi

	cleanup_repo "$_repo"
	cleanup_repo "$_out_dir"
	rm -f /tmp/.puv-test-base-sha /tmp/.puv-test-head-sha
	return 0
}

# Test 4: Regression — common case where branch tip is fresh on top of main.
# Fix must not break this path.
test_up_to_date_branch_works() {
	info "test: up-to-date branch surfaces real violations correctly"
	local _repo
	_repo=$(init_test_repo)

	(
		cd "$_repo" || exit 1
		# Add some main commits first.
		add_clean_main_commit "$_repo" "main: clean commit 1"
		add_clean_main_commit "$_repo" "main: clean commit 2"
		# Branch off latest main and add a violation.
		git checkout -q -b feature/up-to-date
		add_violation_commit "$_repo" "branch: introduce violation"
		local _head_sha
		_head_sha=$(git rev-parse HEAD)
		git checkout -q main
		local _base_sha
		_base_sha=$(git rev-parse HEAD)
		printf '%s\n' "$_base_sha" >/tmp/.puv-test-base-sha
		printf '%s\n' "$_head_sha" >/tmp/.puv-test-head-sha
	)

	local _base_sha _head_sha _out_dir
	_base_sha=$(cat /tmp/.puv-test-base-sha)
	_head_sha=$(cat /tmp/.puv-test-head-sha)
	_out_dir=$(extract_diff_additions "$_repo" "$_base_sha" "$_head_sha")

	local _diff_file="${_out_dir}/pulse-test.sh"
	if [[ -f "$_diff_file" ]] && grep -q 'local _g_nums _b_nums _p_nums' "$_diff_file"; then
		pass "up-to-date branch real violation IS surfaced"
	else
		fail "up-to-date branch real violation was NOT surfaced"
		[[ -f "$_diff_file" ]] && {
			printf '  Extracted content:\n'
			sed 's/^/    /' "$_diff_file"
		}
	fi

	cleanup_repo "$_repo"
	cleanup_repo "$_out_dir"
	rm -f /tmp/.puv-test-base-sha /tmp/.puv-test-head-sha
	return 0
}

# Test 5: Intra-branch reversal (t3206) — branch introduces a violation in
# commit N alongside a clean change, then removes only the violation in
# commit N+1. The NET tree delta is the clean change; the violation is gone.
# Extraction must surface the clean lines but NOT the transient violation
# lines. Reproduces the GH#21921 false-positive that the `git log -p`
# extraction produced even after t3084 — `git log -p` walks both commits'
# patches and emits the bad `+` lines from commit N regardless of whether
# they survive in HEAD's tree.
test_intra_branch_fix_no_phantom() {
	info "test: intra-branch violation→fix does not surface phantom additions"
	local _repo
	_repo=$(init_test_repo)

	(
		cd "$_repo" || exit 1
		git checkout -q -b feature/intra-branch-fix
		add_violation_then_fix_commits "$_repo" \
			"branch: introduce transient violation" \
			"branch: fix transient violation"
		local _head_sha
		_head_sha=$(git rev-parse HEAD)
		git checkout -q main
		local _base_sha
		_base_sha=$(git rev-parse HEAD)
		printf '%s\n' "$_base_sha" >/tmp/.puv-test-base-sha
		printf '%s\n' "$_head_sha" >/tmp/.puv-test-head-sha
	)

	local _base_sha _head_sha _out_dir
	_base_sha=$(cat /tmp/.puv-test-base-sha)
	_head_sha=$(cat /tmp/.puv-test-head-sha)
	_out_dir=$(extract_diff_additions "$_repo" "$_base_sha" "$_head_sha")

	# The NET tree delta is the clean block (`clean_branch_addition`); the
	# transient violation block is reverted. The extraction file may exist
	# and contain the clean block, but it MUST NOT contain the violation
	# pattern (`local _t1 _t2 _t3`). The clean-block check (positive
	# assertion) is implicit — test_real_violation_is_surfaced and
	# test_up_to_date_branch_works already prove the extraction surfaces
	# real branch additions; this test isolates the negative assertion.
	local _diff_file="${_out_dir}/pulse-test.sh"
	if [[ -f "$_diff_file" ]] && grep -q 'local _t1 _t2 _t3' "$_diff_file"; then
		fail "intra-branch fix extraction surfaced phantom transient violation"
		printf '  Phantom content:\n'
		sed 's/^/    /' "$_diff_file"
	else
		pass "intra-branch fix extraction does not surface transient violation"
	fi

	cleanup_repo "$_repo"
	cleanup_repo "$_out_dir"
	rm -f /tmp/.puv-test-base-sha /tmp/.puv-test-head-sha
	return 0
}

# Test 6: GH#26756 regression — the canonical prefetch scripts reported by
# the systemic CI issue remain clean when scanned directly. This catches any
# future reintroduction of multi-var local declarations without explicit
# initialisers in the exact files that triggered PR #26743/#26744 comments.
test_current_prefetch_files_scan_clean() {
	info "test: GH#26756 prefetch files scan clean"
	local _scanner="${TEST_REPO_ROOT}/.agents/scripts/pulse-unbound-var-check.sh"
	local _orchestration="${TEST_REPO_ROOT}/.agents/scripts/pulse-prefetch-orchestration.sh"
	local _repo_prefetch="${TEST_REPO_ROOT}/.agents/scripts/pulse-prefetch-repo.sh"
	local _scan_output=""

	if _scan_output=$("$_scanner" --scan-files "$_orchestration" "$_repo_prefetch" 2>&1); then
		pass "GH#26756 prefetch files have no unbound-var violations"
	else
		fail "GH#26756 prefetch files reported unbound-var violations"
		printf '%s\n' "$_scan_output" | sed 's/^/    /'
	fi

	return 0
}

# ── main ─────────────────────────────────────────────────────────────

main() {
	test_stale_base_no_sh_changes
	test_real_violation_is_surfaced
	test_merge_from_main_no_phantoms
	test_up_to_date_branch_works
	test_intra_branch_fix_no_phantom
	test_current_prefetch_files_scan_clean

	printf '\n'
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		printf '%s%d/%d tests FAILED%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC" >&2
		return 1
	fi
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	return 0
}

main "$@"
