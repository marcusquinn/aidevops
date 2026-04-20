#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-claim-task-id-wall-timeout.sh — Regression test for GH#20137
#
# Verifies:
#   1. Wall-clock timeout (CAS_WALL_TIMEOUT_S) caps total CAS loop duration
#   2. Two concurrent claim processes both complete in <10s total
#   3. Offline mode does not leave .task-counter dirty (commits locally)
#   4. Source code contains timeout wrappers on git fetch/push in CAS path
#
# Requires: bash 4+, git, timeout (coreutils)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CLAIM_SCRIPT="${SCRIPT_DIR}/../claim-task-id.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASS=0
FAIL=0
ERRORS=""

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
# Setup: create a local bare repo as the "remote" and a working clone
# ---------------------------------------------------------------------------
setup_test_repos() {
	local base_dir="$1"

	local bare_dir="${base_dir}/remote.git"
	git init --bare --initial-branch=main "$bare_dir" >/dev/null 2>&1 || {
		git init --bare "$bare_dir" >/dev/null 2>&1 || return 1
	}

	local work_dir="${base_dir}/work"
	git clone "$bare_dir" "$work_dir" >/dev/null 2>&1 || return 1

	git -C "$work_dir" config commit.gpgsign false >/dev/null 2>&1 || true
	git -C "$work_dir" config tag.gpgsign false >/dev/null 2>&1 || true
	git -C "$work_dir" config user.email "test@test.local" >/dev/null 2>&1 || true
	git -C "$work_dir" config user.name "Test" >/dev/null 2>&1 || true

	local seed_value=2000
	printf '%s\n' "$seed_value" >"${work_dir}/.task-counter"
	printf '# Tasks\n\n- [x] t1999 seed task\n' >"${work_dir}/TODO.md"

	git -C "$work_dir" checkout -b main >/dev/null 2>&1 || true
	git -C "$work_dir" add .task-counter TODO.md >/dev/null 2>&1
	git -C "$work_dir" commit -m "chore: seed counter at ${seed_value}" >/dev/null 2>&1 || return 1
	git -C "$work_dir" push origin main >/dev/null 2>&1 || return 1

	echo "$work_dir"
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: source check — CAS_WALL_TIMEOUT_S and CAS_GIT_CMD_TIMEOUT_S exist
# ---------------------------------------------------------------------------
test_timeout_constants_exist() {
	local name="source check: CAS_WALL_TIMEOUT_S and CAS_GIT_CMD_TIMEOUT_S constants defined"

	if ! grep -q 'CAS_WALL_TIMEOUT_S=' "$CLAIM_SCRIPT"; then
		fail "$name" "CAS_WALL_TIMEOUT_S not found in claim-task-id.sh"
		return 0
	fi

	if ! grep -q 'CAS_GIT_CMD_TIMEOUT_S=' "$CLAIM_SCRIPT"; then
		fail "$name" "CAS_GIT_CMD_TIMEOUT_S not found in claim-task-id.sh"
		return 0
	fi

	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: source check — git fetch/push in CAS path wrapped with timeout
# ---------------------------------------------------------------------------
test_git_commands_have_timeout() {
	local name="source check: git fetch/push in CAS path have http.lowSpeedTime configuration"

	local fetch_body
	fetch_body=$(sed -n '/^_cas_fetch_and_pin()/,/^}/p' "$CLAIM_SCRIPT")
	if [[ -z "$fetch_body" ]]; then
		fail "$name" "_cas_fetch_and_pin function not found"
		return 0
	fi

	if ! echo "$fetch_body" | grep -q 'http.lowSpeedTime'; then
		fail "$name" "git fetch in _cas_fetch_and_pin missing http.lowSpeedTime configuration"
		return 0
	fi

	local push_body
	push_body=$(sed -n '/^_cas_build_and_push()/,/^}/p' "$CLAIM_SCRIPT")
	if [[ -z "$push_body" ]]; then
		fail "$name" "_cas_build_and_push function not found"
		return 0
	fi

	if ! echo "$push_body" | grep -q 'http.lowSpeedTime'; then
		fail "$name" "git push in _cas_build_and_push missing http.lowSpeedTime configuration"
		return 0
	fi

	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: source check — allocate_online has wall-clock timeout
# ---------------------------------------------------------------------------
test_allocate_online_wall_clock() {
	local name="source check: allocate_online enforces wall-clock timeout"

	local online_body
	online_body=$(sed -n '/^allocate_online()/,/^}/p' "$CLAIM_SCRIPT")
	if [[ -z "$online_body" ]]; then
		fail "$name" "allocate_online function not found"
		return 0
	fi

	if ! echo "$online_body" | grep -q 'CAS_WALL_TIMEOUT_S'; then
		fail "$name" "allocate_online does not reference CAS_WALL_TIMEOUT_S"
		return 0
	fi

	if ! echo "$online_body" | grep -q 'wall.clock timeout'; then
		fail "$name" "allocate_online missing wall-clock timeout abort path"
		return 0
	fi

	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: source check — allocate_offline commits locally (no dirty state)
# ---------------------------------------------------------------------------
test_offline_commits_locally() {
	local name="source check: allocate_offline commits .task-counter locally"

	local offline_body
	offline_body=$(sed -n '/^allocate_offline()/,/^}/p' "$CLAIM_SCRIPT")
	if [[ -z "$offline_body" ]]; then
		fail "$name" "allocate_offline function not found"
		return 0
	fi

	if ! echo "$offline_body" | grep -q 'git commit'; then
		fail "$name" "allocate_offline does not commit .task-counter locally"
		return 0
	fi

	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: functional — two concurrent claims complete in <10s
# ---------------------------------------------------------------------------
test_concurrent_timing() {
	local name="functional: 2 concurrent claims complete in <10s"

	local tmpdir
	tmpdir=$(mktemp -d) || { fail "$name" "mktemp failed"; return 0; }
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local work_dir
	work_dir=$(setup_test_repos "$tmpdir") || { fail "$name" "repo setup failed"; return 0; }

	local results_dir="${tmpdir}/results"
	mkdir -p "$results_dir"

	local start_time
	start_time=$(date +%s)

	# Launch 2 concurrent claims
	local pids=()
	local i
	for ((i = 1; i <= 2; i++)); do
		(
			local output
			output=$("$CLAIM_SCRIPT" \
				--title "timing test $i" \
				--no-issue \
				--repo-path "$work_dir" \
				--counter-branch main 2>/dev/null) || true
			local task_id
			task_id=$(printf '%s' "$output" | grep '^task_id=' | head -1 | sed 's/^task_id=//')
			printf '%s\n' "$task_id" >"${results_dir}/result-${i}.txt"
		) &
		pids+=($!)
	done

	for pid in "${pids[@]}"; do
		wait "$pid" 2>/dev/null || true
	done

	local end_time elapsed
	end_time=$(date +%s)
	elapsed=$((end_time - start_time))

	if [[ $elapsed -ge 10 ]]; then
		fail "$name" "took ${elapsed}s (expected <10s)"
		return 0
	fi

	# Verify both got valid task IDs
	local count=0
	for ((i = 1; i <= 2; i++)); do
		local tid=""
		[[ -f "${results_dir}/result-${i}.txt" ]] && tid=$(tr -d '[:space:]' <"${results_dir}/result-${i}.txt")
		if [[ "$tid" =~ ^t[0-9]+ ]]; then
			count=$((count + 1))
		fi
	done

	if [[ $count -ne 2 ]]; then
		fail "$name" "expected 2 valid task IDs, got ${count} (elapsed=${elapsed}s)"
		return 0
	fi

	pass "$name (${elapsed}s)"
	return 0
}

# ---------------------------------------------------------------------------
# Test 6: functional — offline mode leaves clean working tree
# ---------------------------------------------------------------------------
test_offline_clean_state() {
	local name="functional: offline mode leaves clean working tree"

	local tmpdir
	tmpdir=$(mktemp -d) || { fail "$name" "mktemp failed"; return 0; }
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local work_dir
	work_dir=$(setup_test_repos "$tmpdir") || { fail "$name" "repo setup failed"; return 0; }

	# Run offline allocation
	"$CLAIM_SCRIPT" \
		--title "offline test" \
		--no-issue \
		--offline \
		--repo-path "$work_dir" \
		--counter-branch main >/dev/null 2>&1 || true

	# Check working tree is clean
	local dirty
	dirty=$(git -C "$work_dir" status --porcelain 2>/dev/null)
	if [[ -n "$dirty" ]]; then
		fail "$name" "working tree dirty after offline allocation: ${dirty}"
		return 0
	fi

	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 7: source check — backoff is capped at 2.0s
# ---------------------------------------------------------------------------
test_backoff_capped() {
	local name="source check: CAS backoff capped at 2.0s"

	local online_body
	online_body=$(sed -n '/^allocate_online()/,/^}/p' "$CLAIM_SCRIPT")

	if ! echo "$online_body" | grep -q '2\.0'; then
		fail "$name" "allocate_online backoff does not contain 2.0s cap"
		return 0
	fi

	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
main() {
	printf 'Running claim-task-id wall-clock timeout tests (GH#20137)...\n\n'

	test_timeout_constants_exist
	test_git_commands_have_timeout
	test_allocate_online_wall_clock
	test_offline_commits_locally
	test_backoff_capped
	test_concurrent_timing
	test_offline_clean_state

	printf '\n'
	printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
	if [[ "$FAIL" -gt 0 ]]; then
		printf '\nFailed tests:%b\n' "$ERRORS"
		return 1
	fi
	return 0
}

main "$@"
