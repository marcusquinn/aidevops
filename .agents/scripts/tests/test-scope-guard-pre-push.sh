#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-scope-guard-pre-push.sh — t2447 regression guard.
#
# Validates the scope-guard-pre-push.sh pre-push hook end-to-end:
#   1. In-scope-only push → allowed (exit 0)
#   2. Out-of-scope push (rebase-introduced creep) → blocked (exit 1)
#   3. SCOPE_GUARD_DISABLE=1 → bypass allowed (exit 0)
#   4. Missing brief → fail-open (exit 0)
#   5. Brief without ## Files Scope section → fail-closed (exit 1) — config error
#   6. Branch with no task ID → fail-open (exit 0)
#
# Root cause being guarded: GH#19808 / t2264 — rebasing introduced
# changes to 3 unrelated files that were pushed silently. The scope
# guard (t2445) prevents this; this test prevents the guard from
# regressing silently.
#
# Design:
#   Each test case creates its own temporary git repo (no side effects
#   on the real repo), creates a brief, commits files, then invokes
#   the hook directly via the git pre-push stdin protocol:
#     <local_ref> <local_sha> <remote_ref> <remote_sha>
#   Passing the initial commit SHA as remote_sha makes the hook diff
#   HEAD against that commit without needing an actual remote.
#
# Usage:
#   bash .agents/scripts/tests/test-scope-guard-pre-push.sh
# Exit code 0 = all tests pass, 1 = at least one failure.

# NOTE: not using `set -e` intentionally — test assertions call the hook
# in subshells and capture non-zero exits. A fail-fast shell would abort
# on the first expected non-zero before we can record the result.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")/../.." && pwd)/hooks"
HOOK="${HOOK_DIR}/scope-guard-pre-push.sh"

if [[ ! -f "$HOOK" ]]; then
	printf 'FAIL: hook not found at %s\n' "$HOOK" >&2
	exit 1
fi

# Colour helpers — plain vars (not readonly) to avoid collision with
# shared-constants.sh if the hook sources it transitively.
if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_RESET=$'\033[0m'
else
	TEST_GREEN=""
	TEST_RED=""
	TEST_RESET=""
fi

TESTS_RUN=0
TESTS_FAILED=0

_pass() {
	local _name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$_name"
	return 0
}

_fail() {
	local _name="$1"
	local _detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s%s\n' "$TEST_RED" "$TEST_RESET" "$_name" \
		"${_detail:+ — $_detail}"
	return 0
}

# ---------------------------------------------------------------------------
# repo_setup — create a self-contained temporary git repo for one test case.
#
# Returns (via stdout):
#   <repo_dir> <base_sha>
#
# The caller should then:
#   1. Add/commit the files relevant to the test case.
#   2. Capture HEAD sha via `git -C "$repo_dir" rev-parse HEAD`.
#   3. Invoke the hook with the pre-push stdin protocol.
# ---------------------------------------------------------------------------
repo_setup() {
	local _task_id="${1:-t9999}"
	local _repo
	# Create inside TEST_TMP so the EXIT trap `rm -rf "$TEST_TMP"` handles
	# cleanup on any exit path.  We intentionally do NOT use the
	# `_save_cleanup_scope` / `trap '_run_cleanups' RETURN` / `push_cleanup`
	# pattern here because repo_setup is a factory function: it returns the
	# path to the caller, which means the RETURN trap would delete the
	# directory before the caller can use it.  Placing repos inside TEST_TMP
	# achieves the same "cleanup on any exit path" goal without that race.
	_repo=$(mktemp -d "${TEST_TMP}/repo.XXXXXX")

	(
		cd "$_repo" || exit 1
		git init -q
		git config user.email 'test@aidevops.local'
		git config user.name 'Test Runner'
		git config commit.gpgsign false

		# Create initial commit as the "remote" base.
		printf 'initial\n' > README.md
		git add README.md
		git commit -q -m 'initial'
	)

	local _base_sha
	_base_sha=$(git -C "$_repo" rev-parse HEAD)

	# Check out a feature branch named so the hook extracts the task ID.
	git -C "$_repo" checkout -q -b "feature/${_task_id}-test-branch" 2>/dev/null

	printf '%s %s\n' "$_repo" "$_base_sha"
	return 0
}

# ---------------------------------------------------------------------------
# invoke_hook — run the hook for a repo, simulating a push of HEAD.
#
# Usage: invoke_hook <repo_dir> <base_sha> [env_overrides...]
#
# env_overrides are passed via env(1) prefix, e.g.:
#   invoke_hook "$repo" "$base" SCOPE_GUARD_DISABLE=1
# ---------------------------------------------------------------------------
invoke_hook() {
	local _repo="$1"
	local _base_sha="$2"
	shift 2
	local _env_overrides=("$@")

	local _head_sha
	_head_sha=$(git -C "$_repo" rev-parse HEAD)
	local _branch
	_branch=$(git -C "$_repo" rev-parse --abbrev-ref HEAD)

	# Pre-push stdin protocol: local_ref local_sha remote_ref remote_sha
	local _stdin_line="refs/heads/${_branch} ${_head_sha} refs/heads/${_branch} ${_base_sha}"

	if (
		cd "$_repo" || exit 1
		# Invoke with optional environment overrides.
		if [[ "${#_env_overrides[@]}" -gt 0 ]]; then
			env "${_env_overrides[@]}" bash "$HOOK" origin 'git@github.com:test/repo.git' \
				<<<"$_stdin_line" 2>/dev/null
		else
			bash "$HOOK" origin 'git@github.com:test/repo.git' \
				<<<"$_stdin_line" 2>/dev/null
		fi
	); then
		return 0
	else
		return 1
	fi
}

# ---------------------------------------------------------------------------
# write_brief — write a minimal brief with ## Files Scope.
#
# Usage: write_brief <repo_dir> <task_id> <scope_lines...>
#   scope_lines: one or more paths/globs for the ## Files Scope section.
# ---------------------------------------------------------------------------
write_brief() {
	local _repo="$1"
	local _task_id="$2"
	shift 2
	local _scope_lines=("$@")

	mkdir -p "${_repo}/todo/tasks"
	local _brief="${_repo}/todo/tasks/${_task_id}-brief.md"

	{
		printf '# %s brief\n\n' "$_task_id"
		printf '## What\n\nTest brief.\n\n'
		printf '## Files Scope\n\n'
		for _line in "${_scope_lines[@]}"; do
			# Use printf -- to prevent '-' in format string being parsed as an option flag
			# (bash builtin printf treats leading '-' in format string as an option on macOS).
			printf -- '- %s\n' "$_line"
		done
		printf '\n## Acceptance\n\nTest passes.\n'
	} > "$_brief"

	git -C "$_repo" add "$_brief"
	git -C "$_repo" commit -q -m "add brief"
	return 0
}

# ---------------------------------------------------------------------------
# Test scaffold — temp dir cleaned up on exit.
# ---------------------------------------------------------------------------
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

# ---------------------------------------------------------------------------
# Test 1: In-scope push → allowed (exit 0)
# ---------------------------------------------------------------------------
printf '\n[1] In-scope push → allowed\n'
{
	read -r repo base_sha <<< "$(repo_setup t9999)"
	write_brief "$repo" "t9999" ".agents/hooks/scope-guard-pre-push.sh" "todo/tasks/t9999-brief.md"

	# Commit a file that IS in scope.
	mkdir -p "${repo}/.agents/hooks"
	printf 'in-scope content\n' > "${repo}/.agents/hooks/scope-guard-pre-push.sh"
	git -C "$repo" add "${repo}/.agents/hooks/scope-guard-pre-push.sh"
	git -C "$repo" commit -q -m "add in-scope file"

	if invoke_hook "$repo" "$base_sha"; then
		_pass "in-scope file push is allowed"
	else
		_fail "in-scope file push is allowed" "hook unexpectedly blocked"
	fi
}

# ---------------------------------------------------------------------------
# Test 2: Out-of-scope push (rebase-introduced creep) → blocked (exit 1)
# ---------------------------------------------------------------------------
printf '\n[2] Out-of-scope push → blocked\n'
{
	read -r repo base_sha <<< "$(repo_setup t9999)"
	write_brief "$repo" "t9999" ".agents/hooks/scope-guard-pre-push.sh"

	# Commit files: one in-scope AND one out-of-scope (simulating rebase creep).
	mkdir -p "${repo}/.agents/hooks" "${repo}/unrelated"
	printf 'in-scope\n' > "${repo}/.agents/hooks/scope-guard-pre-push.sh"
	printf 'out-of-scope — rebase artefact\n' > "${repo}/unrelated/surprise.sh"
	git -C "$repo" add \
		"${repo}/.agents/hooks/scope-guard-pre-push.sh" \
		"${repo}/unrelated/surprise.sh"
	git -C "$repo" commit -q -m "add in-scope + rebase artefact"

	if ! invoke_hook "$repo" "$base_sha"; then
		_pass "out-of-scope file push is blocked"
	else
		_fail "out-of-scope file push is blocked" "hook should have exited 1"
	fi
}

# ---------------------------------------------------------------------------
# Test 3: SCOPE_GUARD_DISABLE=1 → bypass (exit 0) even with out-of-scope files
# ---------------------------------------------------------------------------
printf '\n[3] SCOPE_GUARD_DISABLE=1 bypass\n'
{
	read -r repo base_sha <<< "$(repo_setup t9999)"
	write_brief "$repo" "t9999" ".agents/hooks/scope-guard-pre-push.sh"

	# Commit an out-of-scope file.
	mkdir -p "${repo}/unrelated"
	printf 'out-of-scope\n' > "${repo}/unrelated/artefact.sh"
	git -C "$repo" add "${repo}/unrelated/artefact.sh"
	git -C "$repo" commit -q -m "out-of-scope commit"

	if invoke_hook "$repo" "$base_sha" "SCOPE_GUARD_DISABLE=1"; then
		_pass "SCOPE_GUARD_DISABLE=1 bypasses the guard"
	else
		_fail "SCOPE_GUARD_DISABLE=1 bypasses the guard" "hook blocked despite disable flag"
	fi
}

# ---------------------------------------------------------------------------
# Test 4: Missing brief → fail-open (exit 0)
# ---------------------------------------------------------------------------
printf '\n[4] Missing brief → fail-open\n'
{
	read -r repo base_sha <<< "$(repo_setup t9999)"
	# No brief created — todo/tasks/t9999-brief.md does not exist.

	# Commit some files.
	printf 'any file\n' > "${repo}/some-file.sh"
	git -C "$repo" add "${repo}/some-file.sh"
	git -C "$repo" commit -q -m "add file without brief"

	if invoke_hook "$repo" "$base_sha"; then
		_pass "missing brief → fail-open (exit 0)"
	else
		_fail "missing brief → fail-open (exit 0)" "hook blocked when it should fail-open"
	fi
}

# ---------------------------------------------------------------------------
# Test 5: Brief without ## Files Scope section → fail-closed (exit 1)
#
# Design note: a brief without a ## Files Scope section is a configuration
# error, not a missing-brief case.  The hook treats it as fail-closed so that
# partial briefs don't silently bypass the scope guard.  Contrast with the
# missing-brief case (Test 4), which fails open.
# ---------------------------------------------------------------------------
printf '\n[5] Brief without ## Files Scope → fail-closed (config error)\n'
{
	read -r repo base_sha <<< "$(repo_setup t9999)"

	# Create a brief without any ## Files Scope section.
	mkdir -p "${repo}/todo/tasks"
	printf '# t9999 brief\n\n## What\n\nNo scope section.\n' \
		> "${repo}/todo/tasks/t9999-brief.md"
	git -C "$repo" add "${repo}/todo/tasks/t9999-brief.md"
	git -C "$repo" commit -q -m "brief without Files Scope"

	# Commit any file — hook should block because brief is misconfigured.
	printf 'any file\n' > "${repo}/anywhere.sh"
	git -C "$repo" add "${repo}/anywhere.sh"
	git -C "$repo" commit -q -m "add file"

	if ! invoke_hook "$repo" "$base_sha"; then
		_pass "brief without ## Files Scope → fail-closed (exit 1)"
	else
		_fail "brief without ## Files Scope → fail-closed (exit 1)" \
			"hook should have blocked (configuration error — missing scope declaration)"
	fi
}

# ---------------------------------------------------------------------------
# Test 6: Branch with no task ID → fail-open (exit 0)
# ---------------------------------------------------------------------------
printf '\n[6] Branch with no task ID → fail-open\n'
{
	# Use repo_setup but then rename the branch to remove the task ID.
	read -r repo base_sha <<< "$(repo_setup t9999)"
	git -C "$repo" branch -m "no-task-id-branch" 2>/dev/null

	# Add a brief (but branch name won't match any task ID).
	write_brief "$repo" "t9999" ".agents/hooks/scope-guard-pre-push.sh"

	mkdir -p "${repo}/unrelated"
	printf 'some content\n' > "${repo}/unrelated/file.sh"
	git -C "$repo" add "${repo}/unrelated/file.sh"
	git -C "$repo" commit -q -m "unrelated file on no-task-id branch"

	# Hook should fail-open because branch encodes no task ID.
	local_head=$(git -C "$repo" rev-parse HEAD)
	local_branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
	stdin_line="refs/heads/${local_branch} ${local_head} refs/heads/${local_branch} ${base_sha}"

	rc=0
	(cd "$repo" && bash "$HOOK" origin 'git@github.com:test/repo.git' \
		<<<"$stdin_line" 2>/dev/null) || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		_pass "no task ID in branch → fail-open (exit 0)"
	else
		_fail "no task ID in branch → fail-open (exit 0)" "hook blocked with rc=$rc"
	fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
