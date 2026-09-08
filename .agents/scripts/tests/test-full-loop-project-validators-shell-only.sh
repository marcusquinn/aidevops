#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-full-loop-project-validators-shell-only.sh — GH#22007 regression guard.
#
# Verifies commit-and-pr classifies the complete branch range after docs-only
# lifecycle commits. Shell-only diffs skip Node validators, while Node/TypeScript
# diffs still run the configured typecheck and genuinely docs-only branches skip.

# NOTE: not using `set -e` — assertions capture non-zero exits.
set -uo pipefail

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

print_info() {
	local message="$1"
	printf 'INFO %s\n' "$message"
	return 0
}

print_warning() {
	local message="$1"
	printf 'WARN %s\n' "$message" >&2
	return 0
}

print_error() {
	local message="$1"
	printf 'ERROR %s\n' "$message" >&2
	return 0
}

# Production callers inherit the portable implementation from shared-constants.
# This focused source-level fixture supplies the same command contract.
timeout_sec() {
	local _seconds="$1"
	shift
	"$@"
	return $?
}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../full-loop-helper-commit.sh
source "${SCRIPT_DIR}/full-loop-helper-commit.sh"

GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"
git() {
	"$GIT_BIN" "$@"
	return $?
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_BIN="${TEST_ROOT}/bin"
mkdir -p "$FAKE_BIN"
cat >"${FAKE_BIN}/npm" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >>"${NPM_CALL_LOG:?}"
if [[ "${NPM_FAKE_ACTION:-}" == "mutate-other" ]]; then
	printf '%s\n' 'validator mutation' >>"${NPM_FIX_TARGET:?}"
fi
exit "${NPM_FAKE_RC:-0}"
EOF
chmod +x "${FAKE_BIN}/npm"

make_repo() {
	local repo_dir="$1"
	mkdir -p "$repo_dir"
	(
		cd "$repo_dir" || exit 1
		git init -q
		git config commit.gpgsign false
		git config tag.gpgsign false
		git branch -M main
		cat >package.json <<'EOF'
{"scripts":{"typecheck":"tsc --noEmit"}}
EOF
		git add package.json
		git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'initial'
		git remote add origin .
		git update-ref refs/remotes/origin/main HEAD
		git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
		git switch -qc feature/test
	) || return 1
	return 0
}

# Case 1: a finalized shell change followed by a docs-only lifecycle commit
# remains eligible for project validators without invoking Node validators.
SHELL_REPO="${TEST_ROOT}/shell-only"
make_repo "$SHELL_REPO"
NPM_CALL_LOG="${TEST_ROOT}/npm-shell.log"
export NPM_CALL_LOG NPM_FAKE_RC=127
(
	cd "$SHELL_REPO" || exit 1
	mkdir -p .agents/scripts
	printf '%s\n' '#!/usr/bin/env bash' 'echo ok' >.agents/scripts/example.sh
	git add .agents/scripts/example.sh
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'wip: shell-only change'
	_finalize_wip_history 'fix: shell-only change' >/dev/null || exit 1
	printf '%s\n' 'lifecycle sync' >TODO.md
	git add TODO.md
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'chore: sync lifecycle'
	_validators_should_run 0 || exit 1
	if _commit_touches_node_files; then
		exit 1
	fi
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
)
case1_rc=$?
if [[ "$case1_rc" -eq 0 && ! -s "$NPM_CALL_LOG" ]]; then
	print_result "shell-only diff skips Node validators" 0
else
	print_result "shell-only diff skips Node validators" 1 "rc=${case1_rc}, npm_log=$(wc -c <"$NPM_CALL_LOG" 2>/dev/null || printf 0)"
fi

# Case 2: a TypeScript change beneath a docs-only lifecycle commit still runs
# configured typecheck and fails closed when the command reports an error.
TS_REPO="${TEST_ROOT}/typescript-change"
make_repo "$TS_REPO"
NPM_CALL_LOG="${TEST_ROOT}/npm-ts.log"
export NPM_CALL_LOG NPM_FAKE_RC=2
(
	cd "$TS_REPO" || exit 1
	printf '%s\n' 'const answer: number = "wrong";' >index.ts
	git add index.ts
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'typescript change'
	printf '%s\n' 'lifecycle sync' >TODO.md
	git add TODO.md
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'chore: sync lifecycle'
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
)
case2_rc=$?
if [[ "$case2_rc" -ne 0 && -s "$NPM_CALL_LOG" ]]; then
	print_result "TypeScript diff runs failing typecheck" 0
else
	print_result "TypeScript diff runs failing typecheck" 1 "rc=${case2_rc}, npm_log=$(wc -c <"$NPM_CALL_LOG" 2>/dev/null || printf 0)"
fi

# Case 3: a genuinely docs-only branch remains bypassed.
DOCS_REPO="${TEST_ROOT}/docs-only"
make_repo "$DOCS_REPO"
NPM_CALL_LOG="${TEST_ROOT}/npm-docs.log"
export NPM_CALL_LOG NPM_FAKE_RC=127
(
	cd "$DOCS_REPO" || exit 1
	printf '%s\n' '# Documentation' >README.md
	git add README.md
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'docs: add readme'
	if _validators_should_run 0; then
		exit 1
	fi
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
)
case3_rc=$?
if [[ "$case3_rc" -eq 0 && ! -s "$NPM_CALL_LOG" ]]; then
	print_result "docs-only branch skips project validators" 0
else
	print_result "docs-only branch skips project validators" 1 "rc=${case3_rc}, npm_log=$(wc -c <"$NPM_CALL_LOG" 2>/dev/null || printf 0)"
fi

make_workspace_repo() {
	local repo_dir="$1"
	mkdir -p "$repo_dir/packages/a" "$repo_dir/packages/b"
	(
		cd "$repo_dir" || exit 1
		git init -q
		git config commit.gpgsign false
		git config tag.gpgsign false
		git branch -M develop
		cat >package.json <<'EOF'
{"private":true,"workspaces":["packages/*"],"scripts":{"lint:fix":"unsafe-root-fixer"}}
EOF
		printf '%s\n' '{"scripts":{"lint":"eslint .","typecheck":"tsc --noEmit"}}' >packages/a/package.json
		printf '%s\n' '{"scripts":{"lint":"eslint ."}}' >packages/b/package.json
		printf '%s\n' 'export const a = 1;' >packages/a/index.ts
		printf '%s\n' 'export const b = 1;' >packages/b/index.ts
		git add .
		git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'initial workspace'
		git remote add origin .
		git update-ref refs/remotes/origin/develop HEAD
		git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
		git switch -qc feature/test
	) || return 1
	return 0
}

# Case 4: a package-A-only change runs only package A checks. Pre-existing
# staged and unstaged edits in package B retain their bytes and index state.
WORKSPACE_REPO="${TEST_ROOT}/workspace-scope"
make_workspace_repo "$WORKSPACE_REPO"
NPM_CALL_LOG="${TEST_ROOT}/npm-workspace.log"
export NPM_CALL_LOG NPM_FAKE_ACTION='' NPM_FAKE_RC=0
(
	cd "$WORKSPACE_REPO" || exit 1
	printf '%s\n' 'export const a = 2;' >packages/a/index.ts
	git add packages/a/index.ts
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'change package a'
	printf '%s\n' 'pre-existing staged package b edit' >>packages/b/index.ts
	git add packages/b/index.ts
	printf '%s\n' 'pre-existing unstaged package b edit' >>packages/b/index.ts
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
)
case4_rc=$?
case4_b=$(git -C "$WORKSPACE_REPO" diff -- packages/b/index.ts)
case4_cached=$(git -C "$WORKSPACE_REPO" diff --cached --name-only)
case4_index_b=$(git -C "$WORKSPACE_REPO" show :packages/b/index.ts)
if [[ "$case4_rc" -eq 0 && "$case4_b" == *"pre-existing unstaged package b edit"* && "$case4_cached" == "packages/b/index.ts" && "$case4_index_b" == *"pre-existing staged package b edit"* ]] &&
	[[ $(wc -l <"$NPM_CALL_LOG") -eq 2 ]] && ! grep -q '/packages/b|' "$NPM_CALL_LOG" && ! grep -q 'unsafe-root-fixer' "$NPM_CALL_LOG"; then
	print_result "affected workspace checks preserve unrelated tracked edits" 0
else
	print_result "affected workspace checks preserve unrelated tracked edits" 1 "rc=${case4_rc}, cached=${case4_cached}"
fi

# Case 5: a nominally check-only script that mutates package B fails closed.
MUTATION_REPO="${TEST_ROOT}/workspace-mutation"
make_workspace_repo "$MUTATION_REPO"
NPM_CALL_LOG="${TEST_ROOT}/npm-mutation.log"
NPM_FIX_TARGET="${MUTATION_REPO}/packages/b/index.ts"
export NPM_CALL_LOG NPM_FIX_TARGET NPM_FAKE_ACTION=mutate-other NPM_FAKE_RC=0
(
	cd "$MUTATION_REPO" || exit 1
	printf '%s\n' 'export const a = 2;' >packages/a/index.ts
	git add packages/a/index.ts
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'change package a'
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
)
case5_rc=$?
case5_head=$(git -C "$MUTATION_REPO" show HEAD:packages/b/index.ts)
case5_worktree=$(git -C "$MUTATION_REPO" diff -- packages/b/index.ts)
case5_cached=$(git -C "$MUTATION_REPO" diff --cached --name-only)
if [[ "$case5_rc" -ne 0 && "$case5_head" == 'export const b = 1;' && "$case5_worktree" == *"validator mutation"* && -z "$case5_cached" ]]; then
	print_result "out-of-scope validator mutation fails without staging or amend" 0
else
	print_result "out-of-scope validator mutation fails without staging or amend" 1 "rc=${case5_rc}, cached=${case5_cached}"
fi

# Case 6: portable timeout status is distinct from a validator check failure.
TIMEOUT_REPO="${TEST_ROOT}/validator-timeout"
make_repo "$TIMEOUT_REPO"
NPM_CALL_LOG="${TEST_ROOT}/npm-timeout.log"
export NPM_CALL_LOG NPM_FAKE_ACTION='' NPM_FAKE_RC=0
(
	cd "$TIMEOUT_REPO" || exit 1
	printf '%s\n' 'const answer: number = 42;' >index.ts
	git add index.ts
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'typescript change'
	timeout_sec() { return 124; }
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
) 2>"${TEST_ROOT}/timeout-error.log"
case6_rc=$?
if [[ "$case6_rc" -ne 0 ]] && grep -q 'TIMEOUT after' "${TEST_ROOT}/timeout-error.log"; then
	print_result "portable validator timeout is a distinct failure" 0
else
	print_result "portable validator timeout is a distinct failure" 1 "rc=${case6_rc}"
fi

# Case 7: a root/shared Node change visibly broadens to every declared workspace
# without invoking the root's mutating-only lint:fix script.
ROOT_SCOPE_REPO="${TEST_ROOT}/root-shared-scope"
make_workspace_repo "$ROOT_SCOPE_REPO"
NPM_CALL_LOG="${TEST_ROOT}/npm-root-scope.log"
export NPM_CALL_LOG NPM_FAKE_ACTION='' NPM_FAKE_RC=0
(
	cd "$ROOT_SCOPE_REPO" || exit 1
	cat >package.json <<'EOF'
{"private":true,"workspaces":["packages/*"],"engines":{"node":">=20"},"scripts":{"lint:fix":"unsafe-root-fixer"}}
EOF
	git add package.json
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'change shared node contract'
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
)
case7_rc=$?
if [[ "$case7_rc" -eq 0 && $(wc -l <"$NPM_CALL_LOG") -eq 3 ]] &&
	grep -q '/packages/a|' "$NPM_CALL_LOG" && grep -q '/packages/b|' "$NPM_CALL_LOG" && ! grep -q 'unsafe-root-fixer' "$NPM_CALL_LOG"; then
	print_result "root shared changes broaden to check-only workspace validation" 0
else
	print_result "root shared changes broaden to check-only workspace validation" 1 "rc=${case7_rc}, calls=$(wc -l <"$NPM_CALL_LOG")"
fi

# Case 8: mutating-only root scripts are never executed and cannot create a
# false green; publication fails with check-only configuration guidance.
UNSCOPED_REPO="${TEST_ROOT}/mutating-only"
make_repo "$UNSCOPED_REPO"
NPM_CALL_LOG="${TEST_ROOT}/npm-mutating-only.log"
export NPM_CALL_LOG NPM_FAKE_ACTION='' NPM_FAKE_RC=0
(
	cd "$UNSCOPED_REPO" || exit 1
	printf '%s\n' '{"scripts":{"format:fix":"prettier --write ."}}' >package.json
	git add package.json
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'configure mutating-only formatter'
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
) 2>"${TEST_ROOT}/unscoped-error.log"
case8_rc=$?
if [[ "$case8_rc" -ne 0 && ! -s "$NPM_CALL_LOG" ]] && grep -q 'NO SCOPED CHECKS AVAILABLE' "${TEST_ROOT}/unscoped-error.log"; then
	print_result "mutating-only scripts fail with scoped-check guidance" 0
else
	print_result "mutating-only scripts fail with scoped-check guidance" 1 "rc=${case8_rc}, calls=$(wc -l <"$NPM_CALL_LOG" 2>/dev/null || printf 0)"
fi

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
