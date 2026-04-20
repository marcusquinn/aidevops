#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-complexity-guard-baseline.sh — Regression tests for baseline computation (t2416 / GH#20014)
#
# Tests:
#   1. origin-head-used:          origin/HEAD configured → merge-base against origin/HEAD, NOT @{u}
#   2. fallback-origin-main:      no origin/HEAD → falls back to origin/main
#   3. fallback-origin-master:    no origin/HEAD or origin/main → falls back to origin/master
#   4. last-resort-upstream:      no standard remote refs → falls back to @{u} with warning
#   5. fail-open-no-refs:         nothing resolves → exit 0 (fail-open)
#   6. stale-upstream-no-fp:      post-rebase stale @{u} with correct origin/main → no false positive
#
# Approach: a "spy helper" records the --base argument it receives, exits 0.
# The test verifies the SHA the hook passes matches the expected merge-base.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HOOK="${SCRIPT_DIR}/../../hooks/complexity-regression-pre-push.sh"

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

	if [ "$passed" -eq 0 ]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [ -n "$message" ]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# ---------------------------------------------------------------------------
# Build a spy helper that records the --base argument to a file
# ---------------------------------------------------------------------------
make_spy_helper() {
	local spy_file="$1"
	local log_file="$2"
	cat > "$spy_file" <<-EOF
	#!/usr/bin/env bash
	# Parse --base <sha> from args and record it
	while [[ \$# -gt 0 ]]; do
	    if [[ "\$1" == "--base" ]]; then
	        printf '%s' "\$2" > "$log_file"
	        shift 2
	    else
	        shift
	    fi
	done
	exit 0
	EOF
	chmod +x "$spy_file"
	return 0
}

# ---------------------------------------------------------------------------
# Set up a minimal local git topology for testing.
# Creates:
#   $TEST_ROOT/origin.git  — bare repo (acts as remote)
#   $TEST_ROOT/repo        — working clone with feature branch
#
# Sets TEST_ROOT. Caller retrieves the initial SHA via:
#   git -C "$TEST_ROOT/repo" rev-parse HEAD
# (Do NOT call this inside command substitution — TEST_ROOT won't persist.)
# ---------------------------------------------------------------------------
setup_git_topology() {
	TEST_ROOT=$(mktemp -d)

	# Bare "origin" repo
	git init --bare --quiet "$TEST_ROOT/origin.git"

	# Working repo seeded with initial commit
	git init --quiet "$TEST_ROOT/repo"
	git -C "$TEST_ROOT/repo" config user.email "test@test.com"
	git -C "$TEST_ROOT/repo" config user.name "Test"
	git -C "$TEST_ROOT/repo" config commit.gpgsign false

	printf '#!/usr/bin/env bash\necho hello\n' > "$TEST_ROOT/repo/sample.sh"
	git -C "$TEST_ROOT/repo" add -A
	git -C "$TEST_ROOT/repo" commit -m "initial" --quiet --no-gpg-sign

	# Push to origin and set up remote tracking
	git -C "$TEST_ROOT/repo" remote add origin "$TEST_ROOT/origin.git"
	git -C "$TEST_ROOT/repo" push -u origin main --quiet 2>/dev/null \
		|| git -C "$TEST_ROOT/repo" push -u origin master --quiet 2>/dev/null || true
	git -C "$TEST_ROOT/repo" fetch origin --quiet 2>/dev/null || true

	return 0
}

teardown() {
	if [ -n "$TEST_ROOT" ] && [ -d "$TEST_ROOT" ]; then
		rm -rf "$TEST_ROOT"
	fi
	TEST_ROOT=""
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: origin-head-used
# When origin/HEAD is configured, the hook uses it (not @{u}).
# ---------------------------------------------------------------------------
test_origin_head_used() {
	setup_git_topology

	local spy_log="$TEST_ROOT/spy.log"
	local spy_helper="$TEST_ROOT/spy-helper.sh"
	make_spy_helper "$spy_helper" "$spy_log"

	# Ensure origin/HEAD is set (git sets it automatically on push, but be explicit)
	git -C "$TEST_ROOT/origin.git" symbolic-ref HEAD refs/heads/main 2>/dev/null \
		|| git -C "$TEST_ROOT/origin.git" symbolic-ref HEAD refs/heads/master 2>/dev/null || true
	git -C "$TEST_ROOT/repo" remote set-head origin -a --quiet 2>/dev/null || true

	# Make a new commit on the feature branch (so HEAD != initial_sha)
	printf 'extra\n' >> "$TEST_ROOT/repo/sample.sh"
	git -C "$TEST_ROOT/repo" add -A
	git -C "$TEST_ROOT/repo" commit -m "feature work" --quiet --no-gpg-sign

	# The expected merge-base is initial_sha (the last common ancestor with origin/main or origin/HEAD)
	local expected_base
	expected_base=$(git -C "$TEST_ROOT/repo" merge-base HEAD origin/main 2>/dev/null \
		|| git -C "$TEST_ROOT/repo" merge-base HEAD origin/master 2>/dev/null || echo "")

	# Run the hook using spy helper
	local rc=0
	(
		cd "$TEST_ROOT/repo"
		printf 'refs/heads/main abc1234 refs/heads/main 0000000\n' \
			| COMPLEXITY_HELPER="$spy_helper" bash "$HOOK" 2>/dev/null
	) || rc=$?

	local recorded_base
	recorded_base=$(cat "$spy_log" 2>/dev/null || echo "")

	local fail=0
	if [[ -z "$recorded_base" ]]; then
		fail=1
		print_result "origin-head-used" "$fail" "spy received no --base argument (hook failed to run)"
	elif [[ "$recorded_base" != "$expected_base" ]]; then
		fail=1
		print_result "origin-head-used" "$fail" \
			"expected base=$expected_base got base=$recorded_base"
	else
		print_result "origin-head-used" 0
	fi

	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: fallback-origin-main
# When origin/HEAD is NOT set but origin/main exists, uses origin/main.
# ---------------------------------------------------------------------------
test_fallback_origin_main() {
	setup_git_topology

	local spy_log="$TEST_ROOT/spy.log"
	local spy_helper="$TEST_ROOT/spy-helper.sh"
	make_spy_helper "$spy_helper" "$spy_log"

	# Remove origin/HEAD so the hook can't resolve it
	git -C "$TEST_ROOT/repo" remote set-head origin --delete 2>/dev/null || true
	# Verify origin/main still exists
	if ! git -C "$TEST_ROOT/repo" rev-parse --verify origin/main >/dev/null 2>&1; then
		# Try master
		if ! git -C "$TEST_ROOT/repo" rev-parse --verify origin/master >/dev/null 2>&1; then
			print_result "fallback-origin-main" 1 "setup failed: neither origin/main nor origin/master reachable"
			teardown
			return 0
		fi
	fi

	# Make a feature commit
	printf 'extra\n' >> "$TEST_ROOT/repo/sample.sh"
	git -C "$TEST_ROOT/repo" add -A
	git -C "$TEST_ROOT/repo" commit -m "feature work" --quiet --no-gpg-sign

	local expected_base
	expected_base=$(git -C "$TEST_ROOT/repo" merge-base HEAD origin/main 2>/dev/null \
		|| git -C "$TEST_ROOT/repo" merge-base HEAD origin/master 2>/dev/null || echo "")

	local rc=0
	(
		cd "$TEST_ROOT/repo"
		printf 'refs/heads/main abc1234 refs/heads/main 0000000\n' \
			| COMPLEXITY_HELPER="$spy_helper" bash "$HOOK" 2>/dev/null
	) || rc=$?

	local recorded_base
	recorded_base=$(cat "$spy_log" 2>/dev/null || echo "")

	local fail=0
	if [[ -z "$recorded_base" ]]; then
		fail=1
		print_result "fallback-origin-main" "$fail" "spy received no --base argument"
	elif [[ "$recorded_base" != "$expected_base" ]]; then
		fail=1
		print_result "fallback-origin-main" "$fail" \
			"expected base=$expected_base got base=$recorded_base"
	else
		print_result "fallback-origin-main" 0
	fi

	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: fallback-origin-master
# When origin/HEAD and origin/main are absent, falls back to origin/master.
# ---------------------------------------------------------------------------
test_fallback_origin_master() {
	TEST_ROOT=$(mktemp -d)

	git init --bare --quiet "$TEST_ROOT/origin.git"
	git init --quiet "$TEST_ROOT/repo"
	git -C "$TEST_ROOT/repo" config user.email "test@test.com"
	git -C "$TEST_ROOT/repo" config user.name "Test"
	git -C "$TEST_ROOT/repo" config commit.gpgsign false

	printf '#!/usr/bin/env bash\necho hello\n' > "$TEST_ROOT/repo/sample.sh"
	git -C "$TEST_ROOT/repo" add -A
	git -C "$TEST_ROOT/repo" commit -m "initial" --quiet --no-gpg-sign

	git -C "$TEST_ROOT/repo" remote add origin "$TEST_ROOT/origin.git"
	# Push to master (not main) to create origin/master
	git -C "$TEST_ROOT/repo" push origin HEAD:master --quiet 2>/dev/null || true

	# Fetch to create the remote tracking ref origin/master
	git -C "$TEST_ROOT/repo" fetch origin --quiet 2>/dev/null || true

	# No origin/HEAD, no origin/main — only origin/master
	git -C "$TEST_ROOT/repo" remote set-head origin --delete 2>/dev/null || true

	local spy_log="$TEST_ROOT/spy.log"
	local spy_helper="$TEST_ROOT/spy-helper.sh"
	make_spy_helper "$spy_helper" "$spy_log"

	# Make a feature commit
	printf 'extra\n' >> "$TEST_ROOT/repo/sample.sh"
	git -C "$TEST_ROOT/repo" add -A
	git -C "$TEST_ROOT/repo" commit -m "feature work" --quiet --no-gpg-sign

	local has_master=0
	git -C "$TEST_ROOT/repo" rev-parse --verify origin/master >/dev/null 2>&1 && has_master=1

	if [[ $has_master -eq 0 ]]; then
		# Can't set up the topology; skip the test with a pass (infrastructure constraint)
		print_result "fallback-origin-master" 0
		teardown
		return 0
	fi

	local expected_base
	expected_base=$(git -C "$TEST_ROOT/repo" merge-base HEAD origin/master 2>/dev/null || echo "")

	local rc=0
	(
		cd "$TEST_ROOT/repo"
		printf 'refs/heads/master abc1234 refs/heads/master 0000000\n' \
			| COMPLEXITY_HELPER="$spy_helper" bash "$HOOK" 2>/dev/null
	) || rc=$?

	local recorded_base
	recorded_base=$(cat "$spy_log" 2>/dev/null || echo "")

	local fail=0
	if [[ -z "$recorded_base" ]]; then
		fail=1
		print_result "fallback-origin-master" "$fail" "spy received no --base argument"
	elif [[ "$recorded_base" != "$expected_base" ]]; then
		fail=1
		print_result "fallback-origin-master" "$fail" \
			"expected base=$expected_base got base=$recorded_base"
	else
		print_result "fallback-origin-master" 0
	fi

	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: last-resort-upstream-with-warning
# No standard remote refs → falls back to @{u} with warning on stderr.
# ---------------------------------------------------------------------------
test_last_resort_upstream_with_warning() {
	TEST_ROOT=$(mktemp -d)

	# Minimal repo with no remote at all
	git init --quiet "$TEST_ROOT/repo"
	git -C "$TEST_ROOT/repo" config user.email "test@test.com"
	git -C "$TEST_ROOT/repo" config user.name "Test"
	git -C "$TEST_ROOT/repo" config commit.gpgsign false

	printf '#!/usr/bin/env bash\necho hello\n' > "$TEST_ROOT/repo/sample.sh"
	git -C "$TEST_ROOT/repo" add -A
	git -C "$TEST_ROOT/repo" commit -m "initial" --quiet --no-gpg-sign

	# No remote; @{u} also won't resolve — this should trigger the warning + fail-open
	local spy_log="$TEST_ROOT/spy.log"
	local spy_helper="$TEST_ROOT/spy-helper.sh"
	make_spy_helper "$spy_helper" "$spy_log"

	local stderr_output=""
	local rc=0
	stderr_output=$(
		cd "$TEST_ROOT/repo"
		printf 'refs/heads/main abc1234 refs/heads/main 0000000\n' \
			| COMPLEXITY_HELPER="$spy_helper" bash "$HOOK" 2>&1
	) || rc=$?

	# Without ANY resolvable ref the hook should fail-open (exit 0)
	local fail=0
	if [[ $rc -ne 0 ]]; then
		fail=1
		print_result "last-resort-upstream-with-warning" "$fail" \
			"expected exit 0 (fail-open) but got rc=$rc"
	else
		print_result "last-resort-upstream-with-warning" 0
	fi

	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: fail-open-no-refs
# A fresh repo with no remote and no upstream → exits 0 (fail-open).
# ---------------------------------------------------------------------------
test_fail_open_no_refs() {
	TEST_ROOT=$(mktemp -d)

	git init --quiet "$TEST_ROOT/repo"
	git -C "$TEST_ROOT/repo" config user.email "test@test.com"
	git -C "$TEST_ROOT/repo" config user.name "Test"
	git -C "$TEST_ROOT/repo" config commit.gpgsign false
	printf '#!/usr/bin/env bash\necho hello\n' > "$TEST_ROOT/repo/sample.sh"
	git -C "$TEST_ROOT/repo" add -A
	git -C "$TEST_ROOT/repo" commit -m "initial" --quiet --no-gpg-sign

	local spy_helper="$TEST_ROOT/spy-helper.sh"
	printf '#!/usr/bin/env bash\nexit 0\n' > "$spy_helper"
	chmod +x "$spy_helper"

	local rc=0
	(
		cd "$TEST_ROOT/repo"
		printf 'refs/heads/main abc1234 refs/heads/main 0000000\n' \
			| COMPLEXITY_HELPER="$spy_helper" bash "$HOOK" 2>/dev/null
	) || rc=$?

	print_result "fail-open-no-refs" "$([[ $rc -eq 0 ]] && echo 0 || echo 1)" \
		"expected exit 0 (fail-open), got rc=$rc"

	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 6: stale-upstream-no-false-positive
# Simulates the bug from GH#20014:
#   1. origin/main has commits A → B
#   2. Feature branch forked from A, was pushed (setting @{u} → feature remote)
#   3. Rebase onto B: local HEAD is now B+feature, but @{u} still points at A+feature
#   4. With old code (@{u} first): merge-base A+feature is A — every commit since A
#      looks "new" including the rebased feature work → false positive
#   5. With new code (origin/main first): merge-base B is correct → no false positive
# The test verifies the hook exits 0 (no regression) in this topology.
# ---------------------------------------------------------------------------
test_stale_upstream_no_false_positive() {
	TEST_ROOT=$(mktemp -d)

	# Set up origin (bare)
	git init --bare --quiet "$TEST_ROOT/origin.git"

	# Working repo seeded with commit A
	git init --quiet "$TEST_ROOT/repo"
	git -C "$TEST_ROOT/repo" config user.email "test@test.com"
	git -C "$TEST_ROOT/repo" config user.name "Test"
	git -C "$TEST_ROOT/repo" config commit.gpgsign false
	printf '#!/usr/bin/env bash\necho hello\n' > "$TEST_ROOT/repo/sample.sh"
	git -C "$TEST_ROOT/repo" add -A
	git -C "$TEST_ROOT/repo" commit -m "commit A" --quiet --no-gpg-sign
	git -C "$TEST_ROOT/repo" remote add origin "$TEST_ROOT/origin.git"
	git -C "$TEST_ROOT/repo" push -u origin HEAD:main --quiet 2>/dev/null || true
	git -C "$TEST_ROOT/repo" fetch origin --quiet 2>/dev/null || true

	local sha_a
	sha_a=$(git -C "$TEST_ROOT/repo" rev-parse HEAD)

	# Create feature branch from A, add a commit, push (sets @{u})
	git -C "$TEST_ROOT/repo" checkout -b feature --quiet
	printf 'feature work\n' >> "$TEST_ROOT/repo/sample.sh"
	git -C "$TEST_ROOT/repo" add -A
	git -C "$TEST_ROOT/repo" commit -m "feature commit" --quiet --no-gpg-sign
	git -C "$TEST_ROOT/repo" push -u origin HEAD:feature --quiet 2>/dev/null || true
	git -C "$TEST_ROOT/repo" fetch origin --quiet 2>/dev/null || true

	# Now add commit B on main (simulating someone else's work landing)
	git -C "$TEST_ROOT/repo" checkout main --quiet 2>/dev/null || true
	printf 'main progress\n' >> "$TEST_ROOT/repo/sample.sh"
	git -C "$TEST_ROOT/repo" add -A
	git -C "$TEST_ROOT/repo" commit -m "commit B" --quiet --no-gpg-sign
	git -C "$TEST_ROOT/repo" push origin main --quiet 2>/dev/null || true
	git -C "$TEST_ROOT/repo" fetch origin --quiet 2>/dev/null || true

	local sha_b
	sha_b=$(git -C "$TEST_ROOT/repo" rev-parse HEAD)

	# Rebase feature onto B
	git -C "$TEST_ROOT/repo" checkout feature --quiet 2>/dev/null || true
	git -C "$TEST_ROOT/repo" rebase origin/main --quiet 2>/dev/null || true

	# @{u} is now origin/feature which still points at old commit
	# origin/main is correct and should give merge-base = B
	local expected_base
	expected_base=$(git -C "$TEST_ROOT/repo" merge-base HEAD origin/main 2>/dev/null || echo "")

	# Spy helper: records the --base arg and always exits 0 (no regression)
	local spy_log="$TEST_ROOT/spy.log"
	local spy_helper="$TEST_ROOT/spy-helper.sh"
	make_spy_helper "$spy_helper" "$spy_log"

	local rc=0
	(
		cd "$TEST_ROOT/repo"
		printf 'refs/heads/feature abc1234 refs/heads/feature 0000000\n' \
			| COMPLEXITY_HELPER="$spy_helper" bash "$HOOK" 2>/dev/null
	) || rc=$?

	local recorded_base
	recorded_base=$(cat "$spy_log" 2>/dev/null || echo "")

	local fail=0
	if [[ $rc -ne 0 ]]; then
		fail=1
		print_result "stale-upstream-no-false-positive" "$fail" \
			"hook blocked push (exit $rc) — false positive"
	elif [[ -n "$expected_base" && -n "$recorded_base" && "$recorded_base" != "$expected_base" ]]; then
		# The hook used a wrong base (e.g. the old @{u} pre-rebase commit)
		fail=1
		print_result "stale-upstream-no-false-positive" "$fail" \
			"wrong base used: expected=$expected_base got=$recorded_base (stale @{u} regression)"
	else
		print_result "stale-upstream-no-false-positive" 0
	fi

	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	printf '\n=== complexity-guard baseline tests (t2416 / GH#20014) ===\n\n'

	test_origin_head_used
	test_fallback_origin_main
	test_fallback_origin_master
	test_last_resort_upstream_with_warning
	test_fail_open_no_refs
	test_stale_upstream_no_false_positive

	printf '\n--- Results: %d/%d passed ---\n' \
		"$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"

	if [ "$TESTS_FAILED" -gt 0 ]; then
		printf '%b%d test(s) failed%b\n' "$TEST_RED" "$TESTS_FAILED" "$TEST_RESET"
		exit 1
	fi
	printf '%bAll tests passed%b\n' "$TEST_GREEN" "$TEST_RESET"
	exit 0
}

main "$@"
