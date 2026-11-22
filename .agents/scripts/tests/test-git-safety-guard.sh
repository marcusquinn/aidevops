#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-git-safety-guard.sh
# Tests for git_safety_guard.py covering GH#21814 changes:
#   - Structural canonical-versus-linked worktree detection
#   - Canonical protection independent of branch names
#   - environment variables cannot bypass canonical protection
#   - shared command-policy destructive checks (regression)
#
# Modelled on test-pre-edit-check.sh for structure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HOOK="${SCRIPT_DIR}/../../hooks/git_safety_guard.py"
POLICY_HELPER="${SCRIPT_DIR}/../canonical-write-policy-helper.py"
PRE_EDIT_CHECK="${SCRIPT_DIR}/../pre-edit-check.sh"
REAL_GIT=$(python3 -E -s -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from native_git import real_git; print(real_git())' "${SCRIPT_DIR}/..")

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

# Fixture construction must bypass the deployed guard shim. Hook assertions
# continue to exercise the shared command policy and canonical Git guard.
git() {
	"$REAL_GIT" "$@" || return 1
	return 0
}

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
	# The canonical fixture must be registered: unregistered temp marker repos
	# are intentionally exempt from the Git command guard.
	printf '{"initialized_repos":[{"path":"%s"}]}\n' "$TEST_ROOT" >"${TEST_ROOT}/repos.json"
	export AIDEVOPS_REPOS_FILE="${TEST_ROOT}/repos.json"
	export AIDEVOPS_LIFECYCLE_STATE_DIR="${TEST_ROOT}/lifecycle-state"
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
	printf '{}\n' >"${TEST_ROOT}/.aidevops.json"
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
	json=$(python3 -c 'import json,sys; value=json.loads(sys.argv[1]); value.setdefault("session_id", "fixture"); print(json.dumps(value))' "$json")
	(
		cd "$cwd" || exit 1
		if [[ $# -gt 0 ]]; then
			exec env "$@" python3 "$HOOK" <<<"$json"
		else
			exec python3 "$HOOK" <<<"$json"
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

	if hook_is_deny "$output" "canonical write policy" && hook_is_deny "$output" "read-only session mirrors"; then
		print_result "origin-default develop canonical checkout is read-only" 0
	else
		print_result "origin-default develop canonical checkout is read-only" 1 "output=${output}"
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

	if hook_is_deny "$output" "canonical write policy"; then
		print_result "off-default-branch in canonical workspace is denied structurally" 0
	else
		print_result "off-default-branch in canonical workspace is denied structurally" 1 "output=${output}"
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

	local tool_name=""
	local json=""
	local output=""
	local rc=0
	for tool_name in Edit Write functions.apply_patch apply_patch; do
		case "$tool_name" in
		*apply_patch)
			json=$(printf '{"tool_name":"%s","tool_input":{"patchText":"*** Begin Patch\\n*** Add File: %s/new-file.md\\n+safe\\n*** End Patch\\n"}}' "$tool_name" "$worktree_path")
			;;
		*)
			json=$(printf '{"tool_name":"%s","tool_input":{"filePath":"%s/src/foo.ts"}}' "$tool_name" "$worktree_path")
			;;
		esac
		output=$(run_hook "$worktree_path" "$json") || true
		[[ -z "$output" ]] || rc=1
	done
	print_result "all direct file mutation tools are allowed in linked worktrees" "$rc" "output=${output}"

	git -C "$TEST_ROOT" worktree remove "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
	git -C "$TEST_ROOT" branch -D feature/linked-test 2>/dev/null || true
	return 0
}

# =============================================================================
# Test 4: Planning files have no canonical write exception
# =============================================================================
test_default_branch_planning_paths_denied() {
	# Repo is on main (default branch)
	local passed=0

	for allowed_path in "README.md" "TODO.md" "todo/tasks.md"; do
		local json
		json=$(printf '{"tool_name":"Edit","tool_input":{"filePath":"%s/%s"}}' "$TEST_ROOT" "$allowed_path")

		local output=""
		output=$(run_hook "$TEST_ROOT" "$json") || true

		if ! hook_is_deny "$output" "canonical write policy"; then
			print_result "planning path '${allowed_path}' denied on canonical default branch" 1 "output=${output}"
			passed=1
		fi
	done

	if [[ "$passed" -eq 0 ]]; then
		print_result "planning paths (README.md, TODO.md, todo/*) require linked worktrees" 0
	fi
	return 0
}

# =============================================================================
# Test 5: Direct code and namespaced patch tools are denied canonically
# =============================================================================
test_default_branch_non_allowlisted_denied() {
	local json
	json=$(printf '{"tool_name":"Edit","tool_input":{"filePath":"%s/src/foo.ts"}}' "$TEST_ROOT")

	local output=""
	output=$(run_hook "$TEST_ROOT" "$json") || true

	if hook_is_deny "$output" "canonical write policy"; then
		print_result "code path denied in canonical default checkout" 0
	else
		print_result "code path denied in canonical default checkout" 1 "output=${output}"
	fi
	return 0
}

test_namespaced_apply_patch_denied_canonically() {
	local json='{"tool_name":"functions.apply_patch","tool_input":{"patchText":"test"}}'
	local output=""
	output=$(run_hook "$TEST_ROOT" "$json") || true
	if hook_is_deny "$output" "canonical write policy"; then
		print_result "namespaced functions.apply_patch is denied in canonical checkout" 0
	else
		print_result "namespaced functions.apply_patch is denied in canonical checkout" 1 "output=${output}"
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
	if ! hook_is_deny "$output" "filesystem.rm-recursive-force"; then
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
	if ! hook_is_deny "$output" "canonical worktree mutation"; then
		print_result "git checkout -b blocked in canonical workspace" 1 "output=${output}"
		passed=1
	fi

	json='{"tool_name":"Bash","tool_input":{"command":"git checkout --orphan gh-pages"}}'
	output=$(run_hook "$TEST_ROOT" "$json") || true
	if ! hook_is_deny "$output" "canonical worktree mutation"; then
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
# Test 7: Canonical branch switches are never authorized by prompt text
# =============================================================================
test_canonical_branch_switch_always_blocked() {
	git -C "$TEST_ROOT" checkout main >/dev/null 2>&1 || true
	git -C "$TEST_ROOT" branch feature/canonical-switch >/dev/null 2>&1 || true

	local json
	local output=""
	local passed=0

	json='{"tool_name":"Bash","tool_input":{"command":"git switch feature/canonical-switch"}}'
	output=$(run_hook "$TEST_ROOT" "$json") || true
	if ! hook_is_deny "$output" "canonical worktree mutation"; then
		print_result "canonical git switch feature/foo blocked without user request" 1 "output=${output}"
		passed=1
	fi

	json='{"tool_name":"Bash","tool_input":{"command":"git switch main"}}'
	output=$(run_hook "$TEST_ROOT" "$json") || true
	if ! hook_is_deny "$output" "canonical worktree mutation"; then
		print_result "canonical git switch main blocked without current-turn request" 1 "output=${output}"
		passed=1
	fi

	local transcript_path
	transcript_path=$(write_user_transcript "Please restore the canonical repo: git switch main")
	json=$(printf '{"tool_name":"Bash","transcript_path":"%s","tool_input":{"command":"git switch main"}}' "$transcript_path")
	output=$(run_hook "$TEST_ROOT" "$json") || true
	if ! hook_is_deny "$output" "canonical worktree mutation"; then
		print_result "canonical restoration remains blocked despite current-turn request" 1 "output=${output}"
		passed=1
	fi

	if [[ "$passed" -eq 0 ]]; then
		print_result "canonical branch switches cannot be authorized by prompt text" 0
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
# Test 9: Structural protection does not depend on origin/HEAD
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

	# On main without a remote, direct writes are still denied structurally.
	local json
	json=$(printf '{"tool_name":"Edit","tool_input":{"filePath":"%s/src/app.ts"}}' "$fresh_root")

	local output=""
	local exit_code=0
	output=$(run_hook "$fresh_root" "$json") || exit_code=$?

	if [[ "$exit_code" -eq 0 ]] && hook_is_deny "$output" "canonical write policy"; then
		print_result "no origin/HEAD: canonical checkout remains read-only" 0
	else
		print_result "no origin/HEAD: canonical checkout remains read-only" 1 "exit=${exit_code} output=${output}"
	fi

	rm -rf "$fresh_root"
	return 0
}

# =============================================================================
# Test 10: environment variables cannot bypass canonical protection
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

	# Former escape valve must remain denied.
	local output_skip=""
	output_skip=$(run_hook "$TEST_ROOT" "$json" "AIDEVOPS_SKIP_CANONICAL_GUARD=1") || true

	local passed=0

	if ! hook_is_deny "$output_default" "canonical write policy"; then
		print_result "canonical guard: off-default-branch denied without env override" 1 "output=${output_default}"
		passed=1
	fi
	if ! hook_is_deny "$output_headless" "canonical write policy"; then
		print_result "canonical guard: FULL_LOOP_HEADLESS=1 alone does NOT bypass deny" 1 "output=${output_headless}"
		passed=1
	fi
	if ! hook_is_deny "$output_skip" "canonical write policy"; then
		print_result "canonical guard: former skip variable does not bypass deny" 1 "output=${output_skip}"
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
# Test 11: worker Bash tools enforce shared network policy
# =============================================================================
test_worker_network_policy() {
	local json='{"tool_name":"Bash","tool_input":{"command":"curl --url HTTPS://requestbin.com/collect"}}'
	local output=""
	output=$(run_hook "$TEST_ROOT" "$json" "AIDEVOPS_HEADLESS=true" "AIDEVOPS_WORKER_ID=hook-test") || true
	if hook_is_deny "$output" "network.worker-policy"; then
		print_result "Claude worker Bash adapter blocks Tier 5 destination" 0
	else
		print_result "Claude worker Bash adapter blocks Tier 5 destination" 1 "output=${output}"
	fi

	json='{"tool_name":"Bash","tool_input":{"command":"printf '\''%s'\'' '\''curl https://requestbin.com/collect'\''"}}'
	output=$(run_hook "$TEST_ROOT" "$json" "AIDEVOPS_HEADLESS=true" "AIDEVOPS_WORKER_ID=hook-test") || true
	if [[ -z "$output" ]]; then
		print_result "Claude worker Bash adapter ignores printf network text" 0
	else
		print_result "Claude worker Bash adapter ignores printf network text" 1 "output=${output}"
	fi

	json='{"tool_name":"Bash","tool_input":{"command":"printf one\nprintf two"}}'
	output=$(run_hook "$TEST_ROOT" "$json") || true
	if hook_is_deny "$output" "command.parse-error"; then
		print_result "Claude Bash adapter rejects multiline command" 0
	else
		print_result "Claude Bash adapter rejects multiline command" 1 "output=${output}"
	fi
	return 0
}

test_controlled_worktree_creation() {
	local command json output headless
	for headless in false true; do
		for command in 'git worktree add ../example' 'git -C . worktree add -b feature/example ../example'; do
			json=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$command")
			output=$(run_hook "$TEST_ROOT" "$json" "AIDEVOPS_HEADLESS=$headless") || true
			if hook_is_deny "$output" "git.worktree-controlled-creation-required"; then
				print_result "raw worktree creation denied (headless=$headless): $command" 0
			else
				print_result "raw worktree creation denied (headless=$headless): $command" 1 "$output"
			fi
		done
	done
	for command in 'git worktree list --porcelain' 'worktree-helper.sh add feature/example' 'aidevops worktree add feature/example'; do
		json=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$command")
		output=$(run_hook "$TEST_ROOT" "$json") || true
		if [[ -z "$output" ]]; then
			print_result "controlled creation or listing allowed: $command" 0
		else
			print_result "controlled creation or listing allowed: $command" 1 "$output"
		fi
	done
	return 0
}

# =============================================================================
# Test 13: GH#39573 opt-in canonical writes for gitignored runtime output
# =============================================================================
setup_runtime_hub() {
	local hub="$1"
	mkdir -p "${hub}/logs" "${hub}/logs-secret" "${hub}/src"
	git -C "$hub" init -b main >/dev/null 2>&1 || return 1
	git -C "$hub" config user.name "Aidevops Test"
	git -C "$hub" config user.email "test@example.com"
	git -C "$hub" config commit.gpgsign false
	printf 'logs/\nlogs-secret/\n.aidevops.json\n' >"${hub}/.gitignore"
	printf 'code\n' >"${hub}/src/x.py"
	printf 'tracked\n' >"${hub}/logs/tracked.md"
	git -C "$hub" add .gitignore src/x.py
	git -C "$hub" add -f logs/tracked.md
	git -C "$hub" commit -m "test: seed hub" >/dev/null 2>&1 || return 1
	# Invalid entries ("./", "", "/", "..", globs) must never widen the list.
	printf '{"canonical_write_allow":["logs/","./","","/","../","lo*/",".git/"]}\n' >"${hub}/.aidevops.json"
	ln -s ../src "${hub}/logs/link"
	ln "${hub}/src/x.py" "${hub}/logs/hardlink.md"
	return 0
}

runtime_hub_expect() {
	local hub="$1"
	local expected="$2"
	local relative="$3"
	local label="$4"
	local json="" output=""
	json=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","tool_input":{"filePath":sys.argv[1]}}))' "${hub}/${relative}")
	local hook_rc=0
	output=$(run_hook "$hub" "$json") || hook_rc=$?
	local matched=1 exemption=""
	if [[ "$expected" == allow ]]; then
		# Empty output from a failed hook is not an allow; require a clean
		# exit and the shared policy's exemption as well.
		exemption=$(python3 "$POLICY_HELPER" check-write --cwd "$hub" \
			--path "${hub}/${relative}" --field canonical_runtime_allow) || exemption=""
		[[ "$hook_rc" -ne 0 || -n "$output" || "$exemption" != "allowlisted-ignored-runtime-path" ]] || matched=0
	elif hook_is_deny "$output" "read-only session mirrors"; then
		matched=0
	fi
	if [[ "$matched" -eq 0 ]]; then
		print_result "GH#39573 ${label}: ${relative} → ${expected}" 0
	else
		print_result "GH#39573 ${label}: ${relative} → ${expected}" 1 "output=${output}"
	fi
	return 0
}

test_canonical_runtime_allowlist() {
	local hub="${TEST_ROOT}/runtime-hub"
	if ! setup_runtime_hub "$hub"; then
		print_result "GH#39573 runtime hub fixture" 1 "fixture setup failed"
		return 0
	fi
	runtime_hub_expect "$hub" allow "logs/new.md" "allowlisted ignored path"
	runtime_hub_expect "$hub" allow "logs/2026-11-21/run.facts" "allowlisted nested ignored path"
	runtime_hub_expect "$hub" deny "logs/tracked.md" "tracked file under allowlisted prefix"
	runtime_hub_expect "$hub" deny "src/x.py" "not allowlisted"
	runtime_hub_expect "$hub" deny "logs-secret/x.md" "prefix boundary"
	runtime_hub_expect "$hub" deny "logs/link/x.py" "symlink escape"
	runtime_hub_expect "$hub" deny "logs/hardlink.md" "hard-linked tracked content"
	runtime_hub_expect "$hub" deny "logs/.gitignore" "reserved ignore rules"
	runtime_hub_expect "$hub" deny ".aidevops.json" "self-modifying allowlist"
	runtime_hub_expect "$hub" deny "logs/.GIT/config" "case-folded Git metadata"
	runtime_hub_expect "$hub" deny $'logs/.g\xe2\x80\x8cit/config' "HFS+ ignorable Git metadata alias"
	runtime_hub_expect "$hub" deny "logs/.git./config" "trailing-dot Git metadata alias"
	# Case alias of a tracked file: on case-insensitive storage it is the
	# tracked file; elsewhere the case-insensitive index match still denies.
	runtime_hub_expect "$hub" deny "logs/TRACKED.md" "case alias of a tracked file"
	# A symlink above the checkout still counts as a traversed symlink.
	ln -s "$hub" "${TEST_ROOT}/runtime-hub-alias"
	runtime_hub_expect "${TEST_ROOT}/runtime-hub-alias" deny "logs/new.md" "symlinked alias above the checkout"

	local pre_edit_rc=0
	(cd "$hub" && bash "$PRE_EDIT_CHECK" --file logs/new.md </dev/null >/dev/null 2>&1) || pre_edit_rc=$?
	print_result "GH#39573 pre-edit-check --file allowlisted runtime path exits 0" "$pre_edit_rc" "rc=${pre_edit_rc}"
	pre_edit_rc=0
	(cd "$hub" && bash "$PRE_EDIT_CHECK" --file src/x.py </dev/null >/dev/null 2>&1) || pre_edit_rc=$?
	if [[ "$pre_edit_rc" -ne 0 ]]; then
		print_result "GH#39573 pre-edit-check --file tracked canonical path stays blocked" 0
	else
		print_result "GH#39573 pre-edit-check --file tracked canonical path stays blocked" 1 "rc=0"
	fi

	local patch_json="" output=""
	patch_json=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"apply_patch","tool_input":{"patchText":"*** Begin Patch\n*** Add File: "+sys.argv[1]+"\n+x\n*** End Patch\n"}}))' "${hub}/logs/patched.md")
	local patch_rc=0
	output=$(run_hook "$hub" "$patch_json") || patch_rc=$?
	if [[ "$patch_rc" -eq 0 && -z "$output" ]]; then
		print_result "GH#39573 apply_patch to allowlisted ignored path → allow" 0
	else
		print_result "GH#39573 apply_patch to allowlisted ignored path → allow" 1 "output=${output}"
	fi

	# A tracked config is shared content, not a user-authored local opt-in.
	git -C "$hub" add -f .aidevops.json
	git -C "$hub" commit -m "test: track config" >/dev/null 2>&1
	runtime_hub_expect "$hub" deny "logs/new.md" "tracked config is ignored"
	return 0
}

# GH#39582: run the hook from a linked worktree and expect a Git-metadata
# deny, or a clean silent allow.
git_metadata_expect() {
	local cwd="$1"
	local expected="$2"
	local target="$3"
	local label="$4"
	local json="" output="" hook_rc=0 matched=1
	json=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","tool_input":{"filePath":sys.argv[1]}}))' "$target")
	output=$(run_hook "$cwd" "$json") || hook_rc=$?
	if [[ "$expected" == allow ]]; then
		[[ "$hook_rc" -ne 0 || -n "$output" ]] || matched=0
	elif hook_is_deny "$output" "Git metadata"; then
		matched=0
	fi
	print_result "GH#39582 ${label} → ${expected}" "$matched" "rc=${hook_rc} output=${output}"
	return 0
}

test_git_metadata_writes_denied() {
	local hub="${TEST_ROOT}/metadata-hub"
	local linked="${TEST_ROOT}/metadata-linked"
	# TEST_ROOT is itself a repository, so the non-Git target lives apart.
	local plain=""
	plain=$(mktemp -d) && plain=$(cd "$plain" && pwd -P) || plain=""
	# CI runners have no global identity; give the seed commit its own.
	if [[ -z "$plain" ]] || ! git init -q -b main "$hub" ||
		! git -C "$hub" -c user.name="Aidevops Test" -c user.email="test@example.com" \
			-c commit.gpgsign=false commit -q --allow-empty -m init ||
		! git -C "$hub" worktree add -q "$linked" -b feature; then
		print_result "GH#39582 metadata fixture" 1 "fixture setup failed"
		return 0
	fi
	git_metadata_expect "$linked" deny "${hub}/.git/hooks/pre-commit" "canonical hook"
	git_metadata_expect "$linked" deny "${hub}/.git/config" "canonical config"
	git_metadata_expect "$linked" deny "${hub}/.git/worktrees/metadata-linked/HEAD" "linked worktree private git dir"
	git_metadata_expect "$linked" deny "${linked}/.git" "linked worktree gitfile"
	git_metadata_expect "$linked" deny "${linked}/sub/.git/config" "nested Git directory in a linked worktree"
	if [[ -e "${hub}/.GIT" ]]; then
		git_metadata_expect "$linked" deny "${hub}/.GIT/hooks/x" "case-folded Git directory"
	fi
	git_metadata_expect "$linked" allow "${linked}/src/x.py" "linked worktree source"
	git_metadata_expect "$linked" allow "${plain}/x.md" "path outside any repository"
	rm -rf "$plain"
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
	test_default_branch_planning_paths_denied
	test_default_branch_non_allowlisted_denied
	test_namespaced_apply_patch_denied_canonically
	test_bash_destructive_commands_blocked
	test_canonical_branch_switch_always_blocked
	test_linked_worktree_branch_switch_allowed
	test_no_origin_head_falls_back_to_main
	test_canonical_guard_skip_env_var
	test_worker_network_policy
	test_controlled_worktree_creation
	test_canonical_runtime_allowlist
	test_git_metadata_writes_denied

	teardown_test_repo

	printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
