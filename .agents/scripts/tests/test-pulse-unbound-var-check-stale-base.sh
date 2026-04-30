#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-unbound-var-check-stale-base.sh — Verifies the t3084 fix for
# pulse-unbound-var-check false positives on stale-base PRs.
#
# Background: when a PR branch lags origin/main by N commits, the original
# implementation `git diff $BASE_SHA $HEAD_SHA | grep '^+'` extracted ALL
# line additions in the diff — including lines added on main since the
# branch diverged. This trained the gate to fire on phantom violations
# (canonical: PR #21827, 45-commit-stale base, ~15 false positives).
#
# Fix: switch to `git merge-base` + `git log -p --first-parent
# MERGE_BASE..HEAD_SHA` so the extraction sees only commits authored by
# this branch, regardless of how stale the base reference is or whether
# the branch merged main into itself.
#
# Verifies (against a temp git repo simulating each scenario):
#   1. Stale-base scenario: branch behind main with no .sh changes does NOT
#      surface main-side additions as "branch additions".
#   2. True-positive scenario: branch with a real new violation DOES surface
#      it as a branch addition.
#   3. Merge-from-main scenario: branch that merged main into itself does
#      NOT surface main-side additions (--first-parent skips the merge side).
#   4. Up-to-date scenario: branch tip on top of current main works correctly
#      (regression check — fix must not break the common case).
#
# Tests are structural — no live GitHub API calls, no network access.

set -u

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
			git log -p --first-parent "${_merge_base}..${_head_sha}" -- "$_file" 2>/dev/null \
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

# ── main ─────────────────────────────────────────────────────────────

main() {
	test_stale_base_no_sh_changes
	test_real_violation_is_surfaced
	test_merge_from_main_no_phantoms
	test_up_to_date_branch_works

	printf '\n'
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		printf '%s%d/%d tests FAILED%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC" >&2
		return 1
	fi
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	return 0
}

main "$@"
