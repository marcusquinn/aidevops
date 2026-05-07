#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-git-safety-guard.sh
# Tests for git_safety_guard.py covering GH#21814 changes:
#   - Dynamic default-branch detection (replaces hardcoded "main"/"master")
#   - Off-default-branch canonical-workspace protection (t1990)
#   - AIDEVOPS_SKIP_CANONICAL_GUARD=1 escape valve
#   - Bash-matcher destructive-command checks (regression)
#
# Modelled on test-pre-edit-check.sh for structure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HOOK="${SCRIPT_DIR}/../../hooks/git_safety_guard.py"

if [[ ! -f "$HOOK" ]]; then
	printf 'ERROR: Hook not found at %s\n' "$HOOK" >&2
	exit 1
fi

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

setup_test_repo() {
	TEST_ROOT=$(mktemp -d)
	# Resolve symlinks so paths are consistent with what git returns
	# (macOS: mktemp returns /var/... which is a symlink to /private/var/...)
	TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
	git -C "$TEST_ROOT" init -b main >/dev/null 2>&1 || {
		git -C "$TEST_ROOT" init >/dev/null 2>&1
		git -C "$TEST_ROOT" checkout -b main >/dev/null 2>&1
	}
	git -C "$TEST_ROOT" config user.name "Aidevops Test"
	git -C "$TEST_ROOT" config user.email "test@example.com"
	# Disable commit signing for the test repo so commits don't prompt for a passphrase
	git -C "$TEST_ROOT" config commit.gpgsign false
	git -C "$TEST_ROOT" config tag.gpgsign false
	mkdir -p "${TEST_ROOT}/src" "${TEST_ROOT}/todo"
	printf 'readme\n' >"${TEST_ROOT}/README.md"
	printf '# TODO\n' >"${TEST_ROOT}/TODO.md"
	printf 'tasks\n' >"${TEST_ROOT}/todo/tasks.md"
	printf 'code\n' >"${TEST_ROOT}/src/foo.ts"
	git -C "$TEST_ROOT" add .
	git -C "$TEST_ROOT" commit -m "test: seed repo" >/dev/null 2>&1
	return 0
}

teardown_test_repo() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Run the hook from a given cwd with JSON on stdin.
# Additional args are passed as env vars via 'env KEY=VALUE ...'.
run_hook() {
	local cwd="$1"
	local json="$2"
	shift 2
	(
		cd "$cwd" || exit 1
		if [[ $# -gt 0 ]]; then
			env "$@" python3 "$HOOK" <<<"$json"
		else
			python3 "$HOOK" <<<"$json"
		fi
	)
	return $?
}

write_user_transcript() {
	local message="$1"
	local transcript_path="${TEST_ROOT}/current-turn.jsonl"
	python3 - "$transcript_path" "$message" <<'PYEOF'
import json
import sys

path = sys.argv[1]
message = sys.argv[2]
with open(path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps({"message": {"role": "user", "content": message}}) + "\n")
PYEOF
	printf '%s' "$transcript_path"
	return 0
}

# Helper: assert output contains permissionDecision=deny and an optional keyword in reason.
output_is_deny() {
	local output="$1"
	local keyword="${2:-}"
	python3 -c "
import json, sys
if not '$output'.strip():
    sys.exit(1)
try:
    d = json.loads('$output'.replace(\"'\", '\"'))
    h = d.get('hookSpecificOutput', {})
except Exception:
    sys.exit(1)
if h.get('permissionDecision') != 'deny':
    sys.exit(1)
if '$keyword' and '$keyword' not in h.get('permissionDecisionReason', ''):
    sys.exit(1)
sys.exit(0)
" 2>/dev/null
}

# Helper: pass JSON output through Python for reliable field extraction.
hook_is_deny() {
	local output="$1"
	local keyword="${2:-}"
	[[ -n "$output" ]] || return 1
	python3 - "$output" "$keyword" <<'PYEOF' 2>/dev/null
import json, sys
raw = sys.argv[1]
keyword = sys.argv[2]
try:
    d = json.loads(raw)
except Exception:
    sys.exit(1)
h = d.get('hookSpecificOutput', {})
if h.get('permissionDecision') != 'deny':
    sys.exit(1)
if keyword and keyword not in h.get('permissionDecisionReason', ''):
    sys.exit(1)
sys.exit(0)
PYEOF
}

# =============================================================================
# Test 1: Default-branch detection from origin/HEAD → origin/develop
# =============================================================================
test_default_branch_detection_from_origin_head() {
	# Create a 'develop' branch and set origin/HEAD to point to it
	git -C "$TEST_ROOT" checkout -b develop >/dev/null 2>&1
	git -C "$TEST_ROOT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop 2>/dev/null || true

	# On the 'develop' branch (now the default), edit a non-allowlisted file
	local json
	json=$(printf '{"tool_name":"Edit","tool_input":{"filePath":"%s/src/foo.ts"}}' "$TEST_ROOT")

	local output=""
	output=$(run_hook "$TEST_ROOT" "$json") || true

	if hook_is_deny "$output" "t1712" && hook_is_deny "$output" "develop"; then
		print_result "default-branch detection from origin/HEAD (develop denied with t1712)" 0
	else
		print_result "default-branch detection from origin/HEAD (develop denied with t1712)" 1 "output=${output}"
	fi

	# Cleanup: back to main
	git -C "$TEST_ROOT" checkout main >/dev/null 2>&1 || true
	git -C "$TEST_ROOT" branch -D develop >/dev/null 2>&1 || true
	git -C "$TEST_ROOT" symbolic-ref --delete refs/remotes/origin/HEAD 2>/dev/null || true
	return 0
}

# =============================================================================
# Test 2: Off-default-branch in canonical workspace → denied with t1990 reason
# =============================================================================
test_off_default_branch_canonical_denied() {
	git -C "$TEST_ROOT" checkout -b feature/test-off-default >/dev/null 2>&1

	local json
	json=$(printf '{"tool_name":"Edit","tool_input":{"filePath":"%s/src/foo.ts"}}' "$TEST_ROOT")

	local output=""
	output=$(run_hook "$TEST_ROOT" "$json") || true

	if hook_is_deny "$output" "t1990" && hook_is_deny "$output" "feature/test-off-default"; then
		print_result "off-default-branch in canonical workspace is denied (t1990)" 0
	else
		print_result "off-default-branch in canonical workspace is denied (t1990)" 1 "output=${output}"
	fi

	git -C "$TEST_ROOT" checkout main >/dev/null 2>&1 || true
	git -C "$TEST_ROOT" branch -D feature/test-off-default >/dev/null 2>&1 || true
	return 0
}

# =============================================================================
# Test 3: Off-default-branch in linked worktree → allowed
# =============================================================================
test_off_default_branch_in_linked_worktree_allowed() {
	local worktree_path="${TEST_ROOT}/linked-wt"
	git -C "$TEST_ROOT" worktree add "$worktree_path" -b feature/linked-test >/dev/null 2>&1

	local json
	json=$(printf '{"tool_name":"Edit","tool_input":{"filePath":"%s/src/foo.ts"}}' "$worktree_path")

	local output=""
	output=$(run_hook "$worktree_path" "$json") || true

	if [[ -z "$output" ]]; then
		print_result "off-default-branch edit in linked worktree is allowed (no output)" 0
	else
		print_result "off-default-branch edit in linked worktree is allowed (no output)" 1 "output=${output}"
	fi

	git -C "$TEST_ROOT" worktree remove "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
	git -C "$TEST_ROOT" branch -D feature/linked-test 2>/dev/null || true
	return 0
}

# =============================================================================
# Test 4: Default-branch allowlist preserved (README.md, TODO.md, todo/*)
# =============================================================================
test_default_branch_allowlisted_paths_allowed() {
	# Repo is on main (default branch)
	local passed=0

	for allowed_path in "README.md" "TODO.md" "todo/tasks.md"; do
		local json
		json=$(printf '{"tool_name":"Edit","tool_input":{"filePath":"%s/%s"}}' "$TEST_ROOT" "$allowed_path")

		local output=""
		output=$(run_hook "$TEST_ROOT" "$json") || true

		if [[ -n "$output" ]]; then
			print_result "allowlisted path '${allowed_path}' allowed on default branch" 1 "output=${output}"
			passed=1
		fi
	done

	if [[ "$passed" -eq 0 ]]; then
		print_result "allowlisted paths (README.md, TODO.md, todo/*) allowed on default branch" 0
	fi
	return 0
}

# =============================================================================
# Test 5: Default-branch non-allowlisted path → denied with t1712 reason
# =============================================================================
test_default_branch_non_allowlisted_denied() {
	local json
	json=$(printf '{"tool_name":"Edit","tool_input":{"filePath":"%s/src/foo.ts"}}' "$TEST_ROOT")

	local output=""
	output=$(run_hook "$TEST_ROOT" "$json") || true

	if hook_is_deny "$output" "t1712"; then
		print_result "non-allowlisted path denied on default branch (t1712)" 0
	else
		print_result "non-allowlisted path denied on default branch (t1712)" 1 "output=${output}"
	fi
	return 0
}

# =============================================================================
# Test 6: Bash matcher — destructive commands still blocked; safe ones allowed
# =============================================================================
test_bash_destructive_commands_blocked() {
	local passed=0

	# rm -rf on non-temp path should be denied
	local json
	json='{"tool_name":"Bash","tool_input":{"command":"rm -rf /some/path"}}'
	local output=""
	output=$(run_hook "$TEST_ROOT" "$json") || true
	if ! hook_is_deny "$output" "rm -rf"; then
		print_result "rm -rf blocked by Bash matcher" 1 "output=${output}"
		passed=1
	fi

	# git reset --hard should be denied
	json='{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD"}}'
	output=$(run_hook "$TEST_ROOT" "$json") || true
	if ! hook_is_deny "$output" ""; then
		print_result "git reset --hard blocked by Bash matcher" 1 "output=${output}"
		passed=1
	fi

	# Branch creation in the canonical workspace should be denied; branch work
	# must happen in a linked worktree.
	json='{"tool_name":"Bash","tool_input":{"command":"git checkout -b feature/new-branch"}}'
	output=$(run_hook "$TEST_ROOT" "$json") || true
	if ! hook_is_deny "$output" "Canonical workspace cannot switch"; then
		print_result "git checkout -b blocked in canonical workspace" 1 "output=${output}"
		passed=1
	fi

	json='{"tool_name":"Bash","tool_input":{"command":"git checkout --orphan gh-pages"}}'
	output=$(run_hook "$TEST_ROOT" "$json") || true
	if ! hook_is_deny "$output" "Canonical workspace cannot switch"; then
		print_result "git checkout --orphan blocked in canonical workspace" 1 "output=${output}"
		passed=1
	fi

	local worktree_path="${TEST_ROOT}/bash-linked-wt"
	git -C "$TEST_ROOT" worktree add "$worktree_path" -b feature/bash-linked-base >/dev/null 2>&1
	json='{"tool_name":"Bash","tool_input":{"command":"git checkout -b feature/new-branch"}}'
	output=$(run_hook "$worktree_path" "$json") || true
	if [[ -n "$output" ]]; then
		print_result "git checkout -b allowed inside linked worktree" 1 "output=${output}"
		passed=1
	fi

	json='{"tool_name":"Bash","tool_input":{"command":"git checkout --orphan gh-pages"}}'
	output=$(run_hook "$worktree_path" "$json") || true
	if [[ -n "$output" ]]; then
		print_result "git checkout --orphan allowed inside linked worktree" 1 "output=${output}"
		passed=1
	fi
	git -C "$TEST_ROOT" worktree remove "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
	git -C "$TEST_ROOT" branch -D feature/bash-linked-base 2>/dev/null || true

	if [[ "$passed" -eq 0 ]]; then
		print_result "Bash matcher: destructive blocked and branch creation requires worktree" 0
	fi
	return 0
}

# =============================================================================
# Test 7: Canonical branch switches require an exact current-turn user request
# =============================================================================
test_canonical_branch_switch_requires_current_turn_request() {
	git -C "$TEST_ROOT" checkout main >/dev/null 2>&1 || true
	git -C "$TEST_ROOT" branch feature/canonical-switch >/dev/null 2>&1 || true

	local json
	local output=""
	local passed=0

	json='{"tool_name":"Bash","tool_input":{"command":"git switch feature/canonical-switch"}}'
	output=$(run_hook "$TEST_ROOT" "$json") || true
	if ! hook_is_deny "$output" "Canonical workspace cannot switch"; then
		print_result "canonical git switch feature/foo blocked without user request" 1 "output=${output}"
		passed=1
	fi

	json='{"tool_name":"Bash","tool_input":{"command":"git switch main"}}'
	output=$(run_hook "$TEST_ROOT" "$json") || true
	if ! hook_is_deny "$output" "current turn"; then
		print_result "canonical git switch main blocked without current-turn request" 1 "output=${output}"
		passed=1
	fi

	local transcript_path
	transcript_path=$(write_user_transcript "Please restore the canonical repo: git switch main")
	json=$(printf '{"tool_name":"Bash","transcript_path":"%s","tool_input":{"command":"git switch main"}}' "$transcript_path")
	output=$(run_hook "$TEST_ROOT" "$json") || true
	if [[ -n "$output" ]]; then
		print_result "canonical restoration allowed with exact current-turn request" 1 "output=${output}"
		passed=1
	fi

	if [[ "$passed" -eq 0 ]]; then
		print_result "canonical branch switches require exact current-turn user request" 0
	fi

	git -C "$TEST_ROOT" branch -D feature/canonical-switch >/dev/null 2>&1 || true
	return 0
}

# =============================================================================
# Test 8: Linked-worktree branch operations remain allowed
# =============================================================================
test_linked_worktree_branch_switch_allowed() {
	git -C "$TEST_ROOT" checkout main >/dev/null 2>&1 || true
	git -C "$TEST_ROOT" branch feature/linked-switch-target >/dev/null 2>&1 || true

	local worktree_path="${TEST_ROOT}/linked-switch-wt"
	git -C "$TEST_ROOT" worktree add "$worktree_path" -b feature/linked-switch-base >/dev/null 2>&1

	local json
	json='{"tool_name":"Bash","tool_input":{"command":"git switch feature/linked-switch-target"}}'

	local output=""
	output=$(run_hook "$worktree_path" "$json") || true

	if [[ -z "$output" ]]; then
		print_result "git switch allowed inside linked worktree" 0
	else
		print_result "git switch allowed inside linked worktree" 1 "output=${output}"
	fi

	git -C "$TEST_ROOT" worktree remove "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
	git -C "$TEST_ROOT" branch -D feature/linked-switch-base 2>/dev/null || true
	git -C "$TEST_ROOT" branch -D feature/linked-switch-target 2>/dev/null || true
	return 0
}

# =============================================================================
# Test 9: Repo without origin/HEAD → fallback to init.defaultBranch then "main"
# =============================================================================
test_no_origin_head_falls_back_to_main() {
	# Fresh temp repo with no remotes — falls back to "main"
	local fresh_root
	fresh_root=$(mktemp -d)
	fresh_root=$(cd "$fresh_root" && pwd -P)
	git -C "$fresh_root" init -b main >/dev/null 2>&1 || {
		git -C "$fresh_root" init >/dev/null 2>&1
		git -C "$fresh_root" checkout -b main >/dev/null 2>&1
	}
	git -C "$fresh_root" config user.name "Test"
	git -C "$fresh_root" config user.email "test@example.com"
	git -C "$fresh_root" config commit.gpgsign false
	git -C "$fresh_root" config tag.gpgsign false
	mkdir -p "${fresh_root}/src"
	printf 'code\n' >"${fresh_root}/src/app.ts"
	git -C "$fresh_root" add .
	git -C "$fresh_root" commit -m "test: seed" >/dev/null 2>&1

	# On main (default), edit a non-allowlisted file — should get t1712 deny (not crash)
	local json
	json=$(printf '{"tool_name":"Edit","tool_input":{"filePath":"%s/src/app.ts"}}' "$fresh_root")

	local output=""
	local exit_code=0
	output=$(run_hook "$fresh_root" "$json") || exit_code=$?

	if [[ "$exit_code" -eq 0 ]] && hook_is_deny "$output" "t1712"; then
		print_result "no origin/HEAD: falls back cleanly, enforces t1712 on main" 0
	else
		print_result "no origin/HEAD: falls back cleanly, enforces t1712 on main" 1 "exit=${exit_code} output=${output}"
	fi

	rm -rf "$fresh_root"
	return 0
}

# =============================================================================
# Test 10: AIDEVOPS_SKIP_CANONICAL_GUARD=1 bypasses off-default-branch deny;
#          FULL_LOOP_HEADLESS=1 alone does NOT bypass (workers use worktrees)
# =============================================================================
test_canonical_guard_skip_env_var() {
	git -C "$TEST_ROOT" checkout -b feature/guard-skip-test >/dev/null 2>&1

	local json
	json=$(printf '{"tool_name":"Edit","tool_input":{"filePath":"%s/src/foo.ts"}}' "$TEST_ROOT")

	# Without env var: should be denied
	local output_default=""
	output_default=$(run_hook "$TEST_ROOT" "$json") || true

	# With FULL_LOOP_HEADLESS=1 alone: still denied (workers should use worktrees)
	local output_headless=""
	output_headless=$(run_hook "$TEST_ROOT" "$json" "FULL_LOOP_HEADLESS=1") || true

	# With AIDEVOPS_SKIP_CANONICAL_GUARD=1: allowed (explicit escape valve)
	local output_skip=""
	output_skip=$(run_hook "$TEST_ROOT" "$json" "AIDEVOPS_SKIP_CANONICAL_GUARD=1") || true

	local passed=0

	if ! hook_is_deny "$output_default" "t1990"; then
		print_result "canonical guard: off-default-branch denied without env override" 1 "output=${output_default}"
		passed=1
	fi
	if ! hook_is_deny "$output_headless" "t1990"; then
		print_result "canonical guard: FULL_LOOP_HEADLESS=1 alone does NOT bypass deny" 1 "output=${output_headless}"
		passed=1
	fi
	if [[ -n "$output_skip" ]]; then
		print_result "canonical guard: AIDEVOPS_SKIP_CANONICAL_GUARD=1 bypasses deny (allow)" 1 "output=${output_skip}"
		passed=1
	fi

	if [[ "$passed" -eq 0 ]]; then
		print_result "canonical guard: env-var bypass behaviour correct" 0
	fi

	git -C "$TEST_ROOT" checkout main >/dev/null 2>&1 || true
	git -C "$TEST_ROOT" branch -D feature/guard-skip-test >/dev/null 2>&1 || true
	return 0
}

# =============================================================================
# Main
# =============================================================================
main() {
	setup_test_repo

	test_default_branch_detection_from_origin_head
	test_off_default_branch_canonical_denied
	test_off_default_branch_in_linked_worktree_allowed
	test_default_branch_allowlisted_paths_allowed
	test_default_branch_non_allowlisted_denied
	test_bash_destructive_commands_blocked
	test_canonical_branch_switch_requires_current_turn_request
	test_linked_worktree_branch_switch_allowed
	test_no_origin_head_falls_back_to_main
	test_canonical_guard_skip_env_var

	teardown_test_repo

	printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
