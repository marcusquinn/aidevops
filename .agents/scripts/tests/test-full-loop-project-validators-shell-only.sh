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

# Resolve native Git once from the system default PATH (portable to non-FHS
# hosts such as NixOS); fixtures must bypass the aidevops git wrapper.
TEST_NATIVE_GIT=$(command -p -v git) || {
	printf '%s\n' 'Native Git is unavailable on the system PATH' >&2
	exit 1
}
export TEST_NATIVE_GIT

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

GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-${TEST_NATIVE_GIT}}"
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
if [[ "$1" == ci ]]; then
	if [[ "${NPM_INSTALL_FAIL:-0}" == 1 ]]; then
		exit 42
	fi
	mkdir -p node_modules
	touch node_modules/.package-lock.json
fi
if [[ "${NPM_FAKE_ACTION:-}" == "mutate-other" ]]; then
	printf '%s\n' 'validator mutation' >>"${NPM_FIX_TARGET:?}"
fi
if [[ "$1" == run && -n "${NPM_FAKE_OUTPUT:-}" ]]; then
	cat "$NPM_FAKE_OUTPUT"
fi
exit "${NPM_FAKE_RC:-0}"
EOF
chmod +x "${FAKE_BIN}/npm"
cat >"${FAKE_BIN}/pnpm" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >>"${NPM_CALL_LOG:?}"
exit "${NPM_FAKE_RC:-0}"
EOF
chmod +x "${FAKE_BIN}/pnpm"

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
	local repo_dir="$1" workspace_kind="${2:-npm}"
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
		if [[ "$workspace_kind" == "pnpm" ]]; then
			cat >package.json <<'EOF'
{"private":true,"scripts":{"lint":"eslint ."}}
EOF
			cat >pnpm-workspace.yaml <<'EOF'
packages:
  - 'packages/*'
  - '!packages/excluded'
EOF
			printf '%s\n' 'lockfileVersion: 9.0' >pnpm-lock.yaml
		fi
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
if [[ "$case6_rc" -ne 0 ]] && grep -q 'TIMEOUT after' "${TEST_ROOT}/timeout-error.log" &&
	grep -q 'AIDEVOPS_VALIDATOR_TIMEOUT=<n> and rerun' "${TEST_ROOT}/timeout-error.log" &&
	grep -q "validator_timeout_seconds.*${TIMEOUT_REPO}/.aidevops.json" "${TEST_ROOT}/timeout-error.log"; then
	print_result "portable validator timeout is a distinct failure" 0
else
	print_result "portable validator timeout is a distinct failure" 1 "rc=${case6_rc}"
fi

# Project configuration wins over the environment; invalid values fail before
# invoking any package manager. The fallback is 300 when neither is specified.
printf '%s\n' '{"validator_timeout_seconds":1500}' >"$TIMEOUT_REPO/.aidevops.json"
(
	cd "$TIMEOUT_REPO" || exit 1
	timeout_sec() { [[ "$1" == 1500 ]] || return 1; shift; "$@"; }
	PATH="${FAKE_BIN}:$PATH" AIDEVOPS_VALIDATOR_TIMEOUT=60 _run_project_validators 0
) >/dev/null 2>"${TEST_ROOT}/config-error.log"
case_config_rc=$?
if [[ "$case_config_rc" -eq 0 ]]; then
	print_result "project timeout overrides environment" 0
else
	print_result "project timeout overrides environment" 1 "rc=${case_config_rc}"
fi
printf '%s\n' '{"validator_timeout_seconds":0}' >"$TIMEOUT_REPO/.aidevops.json"
(
	cd "$TIMEOUT_REPO" || exit 1
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
) >/dev/null 2>"${TEST_ROOT}/invalid-timeout.log"
case_invalid_rc=$?
if [[ "$case_invalid_rc" -ne 0 ]] && grep -q 'must be a positive integer' "${TEST_ROOT}/invalid-timeout.log"; then
	print_result "invalid project timeout fails clearly" 0
else
	print_result "invalid project timeout fails clearly" 1 "rc=${case_invalid_rc}"
fi
rm "$TIMEOUT_REPO/.aidevops.json"
(
	cd "$TIMEOUT_REPO" || exit 1
	timeout_sec() { [[ "$1" == 420 ]] || return 1; shift; "$@"; }
	PATH="${FAKE_BIN}:$PATH" AIDEVOPS_VALIDATOR_TIMEOUT=420 _run_project_validators 0
) >/dev/null 2>"${TEST_ROOT}/env-timeout.log"
case_env_rc=$?
(
	cd "$TIMEOUT_REPO" || exit 1
	timeout_sec() { [[ "$1" == 300 ]] || return 1; shift; "$@"; }
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
) >/dev/null 2>"${TEST_ROOT}/default-timeout.log"
case_default_rc=$?
if [[ "$case_env_rc" -eq 0 && "$case_default_rc" -eq 0 ]]; then
	print_result "environment timeout and 300-second fallback" 0
else
	print_result "environment timeout and 300-second fallback" 1 "env=${case_env_rc} default=${case_default_rc}"
fi

# GH#40303: a serialized plugin test phase gets a floor it can finish inside;
# parallel runs and a larger configured timeout keep the validator timeout.
PLUGIN_REPO="${TEST_ROOT}/plugin-serial-timeout"
make_repo "$PLUGIN_REPO"
NPM_CALL_LOG="${TEST_ROOT}/npm-plugin.log"
export NPM_CALL_LOG NPM_FAKE_ACTION='' NPM_FAKE_RC=0
(
	cd "$PLUGIN_REPO" || exit 1
	printf '%s\n' '{"name":"opencode-aidevops","scripts":{"test":"node --test tests/*.mjs"}}' >package.json
	printf '%s\n' 'export const answer = 42;' >index.mjs
	git add package.json index.mjs
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'plugin change'
)
run_plugin_validators() {
	local concurrency="$1" expected="$2" validator_timeout="$3"
	(
		cd "$PLUGIN_REPO" || exit 1
		export EXPECTED_TIMEOUT="$expected"
		timeout_sec() { [[ "$1" == "$EXPECTED_TIMEOUT" ]] || return 1; shift; "$@"; }
		PATH="${FAKE_BIN}:$PATH" AIDEVOPS_PLUGIN_TEST_CONCURRENCY="$concurrency" \
			AIDEVOPS_VALIDATOR_TIMEOUT="$validator_timeout" _run_project_validators 0
	)
	return $?
}
run_plugin_validators 1 2400 300 >"${TEST_ROOT}/plugin-serial.log" 2>&1
plugin_serial_rc=$?
run_plugin_validators 4 300 300 >"${TEST_ROOT}/plugin-parallel.log" 2>&1
plugin_parallel_rc=$?
run_plugin_validators 1 3000 3000 >"${TEST_ROOT}/plugin-serial-large.log" 2>&1
plugin_large_rc=$?
if [[ "$plugin_serial_rc" -eq 0 && "$plugin_parallel_rc" -eq 0 && "$plugin_large_rc" -eq 0 ]] &&
	grep -q 'serialized plugin tests: timeout 2400s (validator timeout 300s)' "${TEST_ROOT}/plugin-serial.log" &&
	! grep -q 'serialized plugin tests' "${TEST_ROOT}/plugin-parallel.log" "${TEST_ROOT}/plugin-serial-large.log"; then
	print_result "serialized plugin tests get a 2400-second floor; parallel and larger timeouts unchanged" 0
else
	print_result "serialized plugin tests get a 2400-second floor; parallel and larger timeouts unchanged" 1 \
		"serial=${plugin_serial_rc} parallel=${plugin_parallel_rc} large=${plugin_large_rc}"
fi
(
	cd "$PLUGIN_REPO" || exit 1
	timeout_sec() { return 124; }
	PATH="${FAKE_BIN}:$PATH" AIDEVOPS_PLUGIN_TEST_CONCURRENCY=1 _run_project_validators 0
) >/dev/null 2>"${TEST_ROOT}/plugin-serial-timeout.log"
plugin_timeout_rc=$?
if [[ "$plugin_timeout_rc" -ne 0 ]] && grep -q 'TIMEOUT after 2400s: npm run test' "${TEST_ROOT}/plugin-serial-timeout.log"; then
	print_result "serialized plugin timeout reports the effective budget" 0
else
	print_result "serialized plugin timeout reports the effective budget" 1 "rc=${plugin_timeout_rc}"
fi

# GH#40322: a failed plugin test is rerun serialized by name over its file and
# the files that import it. A pass is reported as flaky and does not block; a
# repeat failure, an empty name filter, or an unattributable failure blocks.
NODE_FAKE_BIN="${TEST_ROOT}/node-bin"
mkdir -p "$NODE_FAKE_BIN"
REAL_NODE=$(command -v node) || REAL_NODE=""
export REAL_NODE
cat >"${NODE_FAKE_BIN}/node" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --test && -n "${NODE_FAKE_OUTPUT:-}" ]]; then
	printf '%s\n' "$*" >>"${NODE_CALL_LOG:?}"
	cat "$NODE_FAKE_OUTPUT"
	exit "${NODE_FAKE_RC:-0}"
fi
[[ -n "${REAL_NODE:-}" ]] || exit 127
exec "$REAL_NODE" "$@"
EOF
chmod +x "${NODE_FAKE_BIN}/node"
(
	cd "$PLUGIN_REPO" || exit 1
	mkdir -p tests
	printf '%s\n' 'export function caseTests() {}' >tests/case.mjs
	printf '%s\n' 'import { caseTests } from "./case.mjs";' 'caseTests();' >tests/test-importer.mjs
	printf '%s\n' 'export const unrelated = true;' >tests/unrelated.mjs
	git add tests
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'plugin tests'
) || exit 1
FLAKY_NAME='drains a (slow) child [GH#1]'
SUITE_FAILURE="${TEST_ROOT}/suite-failure.txt"
printf '%s\n' '✔ passing test (1ms)' 'ℹ fail 1' '' '✖ failing tests:' '' 'test at tests/case.mjs:12:3' \
	"✖ ${FLAKY_NAME} (31643.4ms)" '  Error: operation did not reach a terminal state' >"$SUITE_FAILURE"
UNATTRIBUTED_FAILURE="${TEST_ROOT}/suite-crash.txt"
printf '%s\n' 'Error: Cannot find module' 'ℹ fail 1' >"$UNATTRIBUTED_FAILURE"
RERUN_PASS="${TEST_ROOT}/rerun-pass.txt"
printf '%s\n' '▶ suite' "  ✔ ${FLAKY_NAME} (12.5ms)" '✔ suite (13ms)' 'ℹ fail 0' >"$RERUN_PASS"
RERUN_EMPTY="${TEST_ROOT}/rerun-empty.txt"
printf '%s\n' '✔ tests/case.mjs (100ms)' 'ℹ tests 1' 'ℹ fail 0' >"$RERUN_EMPTY"
run_flaky_case() {
	local log_name="$1" suite_output="$2" rerun_output="$3" rerun_rc="$4"
	NODE_CALL_LOG="${TEST_ROOT}/node-${log_name}.log"
	: >"$NODE_CALL_LOG"
	(
		cd "$PLUGIN_REPO" || exit 1
		export NODE_CALL_LOG NPM_FAKE_RC=1 NPM_FAKE_OUTPUT="$suite_output" NODE_FAKE_OUTPUT="$rerun_output" NODE_FAKE_RC="$rerun_rc"
		PATH="${NODE_FAKE_BIN}:${FAKE_BIN}:$PATH" AIDEVOPS_PLUGIN_TEST_CONCURRENCY=1 _run_project_validators 0 || exit $?
		printf 'FLAKY=%s\n' "$FULL_LOOP_VALIDATOR_FLAKY"
	) >"${TEST_ROOT}/${log_name}.out" 2>"${TEST_ROOT}/${log_name}.err"
	return $?
}
run_flaky_case flaky-pass "$SUITE_FAILURE" "$RERUN_PASS" 0
flaky_pass_rc=$?
if [[ "$flaky_pass_rc" -eq 0 ]] &&
	grep -q -F "FLAKY=npm run test (repository root): ${FLAKY_NAME}" "${TEST_ROOT}/flaky-pass.out" &&
	grep -q -F 'FLAKY (not blocking): 1 plugin test(s) failed in the full suite and passed on serialized rerun 1' "${TEST_ROOT}/flaky-pass.err" &&
	grep -q -F -- '--test --test-concurrency=1 --test-reporter=spec --test-name-pattern=drains a \(slow\) child \[GH#1\] tests/case.mjs tests/test-importer.mjs' "${TEST_ROOT}/node-flaky-pass.log" &&
	! grep -q 'unrelated.mjs' "${TEST_ROOT}/node-flaky-pass.log"; then
	print_result "failed plugin test that passes on serialized rerun is reported as flaky" 0
else
	print_result "failed plugin test that passes on serialized rerun is reported as flaky" 1 "rc=${flaky_pass_rc}"
fi
run_flaky_case flaky-repeat "$SUITE_FAILURE" "$SUITE_FAILURE" 1
flaky_repeat_rc=$?
run_flaky_case flaky-empty "$SUITE_FAILURE" "$RERUN_EMPTY" 0
flaky_empty_rc=$?
run_flaky_case flaky-unattributed "$UNATTRIBUTED_FAILURE" "$RERUN_PASS" 0
flaky_unattributed_rc=$?
if [[ "$flaky_repeat_rc" -ne 0 && "$flaky_empty_rc" -ne 0 && "$flaky_unattributed_rc" -ne 0 ]] &&
	grep -q 'failed again on serialized rerun' "${TEST_ROOT}/flaky-repeat.err" &&
	grep -q 'CHECK FAILED (exit 1): npm run test' "${TEST_ROOT}/flaky-repeat.err" &&
	[[ "$(wc -l <"${TEST_ROOT}/node-flaky-repeat.log" | tr -d ' ')" == 2 ]] &&
	grep -q 'failed again on serialized rerun' "${TEST_ROOT}/flaky-empty.err" &&
	grep -q 'not attributable' "${TEST_ROOT}/flaky-unattributed.out" &&
	[[ ! -s "${TEST_ROOT}/node-flaky-unattributed.log" ]]; then
	print_result "repeat, empty-filter and unattributable plugin failures still block" 0
else
	print_result "repeat, empty-filter and unattributable plugin failures still block" 1 \
		"repeat=${flaky_repeat_rc} empty=${flaky_empty_rc} unattributed=${flaky_unattributed_rc}"
fi

# GH#34502: ignored canonical configuration survives linked-worktree creation.
# Use spaces in paths to exercise canonical configuration path handling.
CANONICAL_REPO="${TEST_ROOT}/canonical checkout"
LINKED_REPO="${TEST_ROOT}/linked checkout"
make_repo "$CANONICAL_REPO"
(
	cd "$CANONICAL_REPO" || exit 1
	printf '%s\n' '.aidevops.json' >.gitignore
	printf '%s\n' 'const answer = 42;' >index.ts
	git add .gitignore index.ts
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'typescript change'
	printf '%s\n' '{"validator_timeout_seconds":900}' >.aidevops.json
	git worktree add -qb feature/linked "$LINKED_REPO" || exit 1
)
linked_setup_rc=$?
NPM_CALL_LOG="${TEST_ROOT}/npm-linked.log"
export NPM_CALL_LOG NPM_FAKE_RC=0
(
	[[ "$linked_setup_rc" -eq 0 ]] || exit 1
	cd "$LINKED_REPO" || exit 1
	[[ ! -e .aidevops.json ]] || exit 1
	timeout_sec() {
		local seconds="$1"
		[[ "$seconds" == 900 ]] || return 1
		shift
		"$@"
		return $?
	}
	PATH="${FAKE_BIN}:$PATH" AIDEVOPS_VALIDATOR_TIMEOUT=60 _run_project_validators 0
) >/dev/null 2>"${TEST_ROOT}/canonical-timeout.log"
print_result "linked worktree inherits canonical 900-second timeout over environment" "$?"
(
	cd "$LINKED_REPO" || exit 1
	printf '%s\n' '{"validator_timeout_seconds":1500}' >.aidevops.json
	timeout_sec() {
		local seconds="$1"
		[[ "$seconds" == 1500 ]] || return 1
		shift
		"$@"
		return $?
	}
	PATH="${FAKE_BIN}:$PATH" AIDEVOPS_VALIDATOR_TIMEOUT=60 _run_project_validators 0
) >/dev/null 2>"${TEST_ROOT}/linked-local-timeout.log"
print_result "worktree-local timeout overrides canonical configuration and environment" "$?"
(
	cd "$LINKED_REPO" || exit 1
	printf '%s\n' '{}' >.aidevops.json
	timeout_sec() {
		local seconds="$1"
		[[ "$seconds" == 420 ]] || return 1
		shift
		"$@"
		return $?
	}
	PATH="${FAKE_BIN}:$PATH" AIDEVOPS_VALIDATOR_TIMEOUT=420 _run_project_validators 0
) >/dev/null 2>"${TEST_ROOT}/linked-empty-timeout.log"
print_result "local config without timeout uses environment rather than canonical timeout" "$?"
(
	cd "$LINKED_REPO" || exit 1
	rm .aidevops.json
	timeout_sec() { return 124; }
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
) >/dev/null 2>"${TEST_ROOT}/canonical-remedy.log"
canonical_remedy_rc=$?
if [[ "$canonical_remedy_rc" -ne 0 ]] &&
	grep -q 'TIMEOUT after 900s' "${TEST_ROOT}/canonical-remedy.log" &&
	grep -q 'aidevops project-config set validator_timeout_seconds <n>' "${TEST_ROOT}/canonical-remedy.log" &&
	grep -q "validator_timeout_seconds.*${CANONICAL_REPO}/.aidevops.json" "${TEST_ROOT}/canonical-remedy.log"; then
	print_result "timeout remedy identifies audited setter and canonical durable configuration" 0
else
	print_result "timeout remedy identifies audited setter and canonical durable configuration" 1
fi
printf '%s\n' '{"validator_timeout_seconds":0}' >"$CANONICAL_REPO/.aidevops.json"
(
	cd "$LINKED_REPO" || exit 1
	PATH="${FAKE_BIN}:$PATH" AIDEVOPS_VALIDATOR_TIMEOUT=60 _run_project_validators 0
) >/dev/null 2>"${TEST_ROOT}/canonical-invalid-timeout.log"
canonical_invalid_rc=$?
if [[ "$canonical_invalid_rc" -ne 0 ]] && grep -q 'must be a positive integer' "${TEST_ROOT}/canonical-invalid-timeout.log"; then
	print_result "invalid canonical timeout fails closed" 0
else
	print_result "invalid canonical timeout fails closed" 1
fi
printf '%s\n' 'not-json' >"$CANONICAL_REPO/.aidevops.json"
(
	cd "$LINKED_REPO" || exit 1
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
) >/dev/null 2>"${TEST_ROOT}/canonical-invalid-json.log"
canonical_json_rc=$?
if [[ "$canonical_json_rc" -ne 0 ]] && grep -q 'invalid .aidevops.json configuration' "${TEST_ROOT}/canonical-invalid-json.log"; then
	print_result "invalid canonical JSON fails closed" 0
else
	print_result "invalid canonical JSON fails closed" 1
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

# Case 9: a nested package with its own check-only test script remains a valid
# validation scope even when it is intentionally outside the root workspaces.
NESTED_PACKAGE_REPO="${TEST_ROOT}/nested-package"
make_workspace_repo "$NESTED_PACKAGE_REPO"
NPM_CALL_LOG="${TEST_ROOT}/npm-nested-package.log"
export NPM_CALL_LOG NPM_FAKE_ACTION='' NPM_FAKE_RC=0
(
	cd "$NESTED_PACKAGE_REPO" || exit 1
	mkdir -p .agents/plugins/example
	printf '%s\n' '{"scripts":{"test":"node --test tests/*.mjs"}}' >.agents/plugins/example/package.json
	printf '%s\n' 'export const example = true;' >.agents/plugins/example/index.mjs
	git add .agents/plugins/example
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'add nested package'
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
)
case9_rc=$?
if [[ "$case9_rc" -eq 0 && $(wc -l <"$NPM_CALL_LOG") -eq 1 ]] &&
	grep -q '/.agents/plugins/example|run test' "$NPM_CALL_LOG" && ! grep -q '/packages/' "$NPM_CALL_LOG"; then
	print_result "nested package test script defines a focused validation scope" 0
else
	print_result "nested package test script defines a focused validation scope" 1 "rc=${case9_rc}, calls=$(wc -l <"$NPM_CALL_LOG" 2>/dev/null || printf 0)"
fi

# Case 10: npm's generated failing test placeholder is not a scoped check.
PLACEHOLDER_REPO="${TEST_ROOT}/npm-placeholder"
make_repo "$PLACEHOLDER_REPO"
NPM_CALL_LOG="${TEST_ROOT}/npm-placeholder.log"
export NPM_CALL_LOG NPM_FAKE_ACTION='' NPM_FAKE_RC=0
(
	cd "$PLACEHOLDER_REPO" || exit 1
	printf '%s\n' '{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}' >package.json
	git add package.json
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'configure npm placeholder test'
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
) 2>"${TEST_ROOT}/npm-placeholder-error.log"
case10_rc=$?
if [[ "$case10_rc" -ne 0 && ! -s "$NPM_CALL_LOG" ]] && grep -q 'NO SCOPED CHECKS AVAILABLE' "${TEST_ROOT}/npm-placeholder-error.log"; then
	print_result "npm placeholder test fails with scoped-check guidance" 0
else
	print_result "npm placeholder test fails with scoped-check guidance" 1 "rc=${case10_rc}, calls=$(wc -l <"$NPM_CALL_LOG" 2>/dev/null || printf 0)"
fi

# Case 11: pnpm-only workspace declarations select changed packages on a
# non-main base while preserving an unrelated staged and unstaged edit.
PNPM_REPO="${TEST_ROOT}/pnpm-workspace"
make_workspace_repo "$PNPM_REPO" pnpm
NPM_CALL_LOG="${TEST_ROOT}/pnpm-workspace.log"
export NPM_CALL_LOG NPM_FAKE_ACTION='' NPM_FAKE_RC=0
(
	cd "$PNPM_REPO" || exit 1
	printf '%s\n' 'export const a = 2;' >packages/a/index.ts
	git add packages/a/index.ts
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'change package a'
	printf '%s\n' 'staged unrelated edit' >>packages/b/index.ts
	git add packages/b/index.ts
	printf '%s\n' 'unstaged unrelated edit' >>packages/b/index.ts
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
)
case11_rc=$?
case11_cached=$(git -C "$PNPM_REPO" diff --cached --name-only)
if [[ "$case11_rc" -eq 0 && "$case11_cached" == 'packages/b/index.ts' ]] &&
	[[ $(git -C "$PNPM_REPO" show :packages/b/index.ts) == *'staged unrelated edit'* ]] &&
	[[ $(git -C "$PNPM_REPO" diff -- packages/b/index.ts) == *'unstaged unrelated edit'* ]] &&
	[[ $(wc -l <"$NPM_CALL_LOG") -eq 2 ]] && grep -q '/packages/a|run lint' "$NPM_CALL_LOG" &&
	! grep -q '/packages/b|\|/pnpm-workspace|run' "$NPM_CALL_LOG"; then
	print_result "pnpm-only workspace selects affected package and preserves index" 0
else
	print_result "pnpm-only workspace selects affected package and preserves index" 1 "rc=${case11_rc}, cached=${case11_cached}"
fi

# Case 12: lockfile-only changes run root checks once, skipping scriptless groups
# and avoiding duplicate checks in their nested packages.
PNPM_ROOT_REPO="${TEST_ROOT}/pnpm-root"
make_workspace_repo "$PNPM_ROOT_REPO" pnpm
NPM_CALL_LOG="${TEST_ROOT}/pnpm-root.log"
export NPM_CALL_LOG NPM_FAKE_RC=0
(
	cd "$PNPM_ROOT_REPO" || exit 1
	mkdir -p packages/analytics/web
	printf '%s\n' '{"name":"analytics","private":true}' >packages/analytics/package.json
	printf '%s\n' '{"scripts":{"lint":"eslint ."}}' >packages/analytics/web/package.json
	printf '%s\n' '{"private":true,"scripts":{"lint":"turbo run lint","test":"turbo run test"}}' >package.json
	printf '%s\n' "  - 'packages/analytics/*'" >>pnpm-workspace.yaml
	git add package.json pnpm-workspace.yaml packages/analytics
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'add grouping workspace and root checks'
	git update-ref refs/remotes/origin/develop HEAD
	printf '%s\n' '# lockfile change' >>pnpm-lock.yaml
	git add pnpm-lock.yaml
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'change lockfile only'
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
)
case12_rc=$?
if [[ "$case12_rc" -eq 0 && $(wc -l <"$NPM_CALL_LOG") -eq 2 ]] &&
	grep -q '/pnpm-root|run lint' "$NPM_CALL_LOG" && grep -q '/pnpm-root|run test' "$NPM_CALL_LOG" &&
	! grep -q '/packages/' "$NPM_CALL_LOG"; then
	print_result "pnpm lockfile change runs root checks once despite scriptless groups" 0
else
	print_result "pnpm lockfile change runs root checks once despite scriptless groups" 1 "rc=${case12_rc}"
fi

# Case 13: a pnpm workspace validator failure remains a hard failure.
NPM_CALL_LOG="${TEST_ROOT}/pnpm-failure.log"
export NPM_CALL_LOG NPM_FAKE_RC=2
(
	cd "$PNPM_ROOT_REPO" || exit 1
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
)
case13_rc=$?
if [[ "$case13_rc" -ne 0 && -s "$NPM_CALL_LOG" ]]; then
	print_result "pnpm validator failure blocks publication" 0
else
	print_result "pnpm validator failure blocks publication" 1 "rc=${case13_rc}"
fi

# Case 14: docs-only branches never launch pnpm validation.
PNPM_DOCS_REPO="${TEST_ROOT}/pnpm-docs"
make_workspace_repo "$PNPM_DOCS_REPO" pnpm
NPM_CALL_LOG="${TEST_ROOT}/pnpm-docs.log"
export NPM_CALL_LOG NPM_FAKE_RC=2
(
	cd "$PNPM_DOCS_REPO" || exit 1
	printf '%s\n' '# Docs' >README.md
	git add README.md
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'docs only'
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
)
case14_rc=$?
if [[ "$case14_rc" -eq 0 && ! -s "$NPM_CALL_LOG" ]]; then
	print_result "pnpm docs-only branch skips project validators" 0
else
	print_result "pnpm docs-only branch skips project validators" 1 "rc=${case14_rc}"
fi

# Case 15: a workspace manifest change broadens validation even if root has
# no scripts or package.json workspaces; the manifest is a shared contract.
PNPM_MANIFEST_REPO="${TEST_ROOT}/pnpm-manifest"
make_workspace_repo "$PNPM_MANIFEST_REPO" pnpm
NPM_CALL_LOG="${TEST_ROOT}/pnpm-manifest.log"
export NPM_CALL_LOG NPM_FAKE_RC=0
(
	cd "$PNPM_MANIFEST_REPO" || exit 1
	mkdir -p packages/analytics/web
	printf '%s\n' '{"name":"analytics","private":true}' >packages/analytics/package.json
	printf '%s\n' '{"scripts":{"test":"node --test"}}' >packages/analytics/web/package.json
	printf '%s\n' "  - 'packages/analytics/*'" >>pnpm-workspace.yaml
	printf '%s\n' '{"private":true}' >package.json
	git add package.json pnpm-workspace.yaml packages/analytics
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'remove root check'
	git update-ref refs/remotes/origin/develop HEAD
	printf '%s\n' '# shared workspace change' >>pnpm-workspace.yaml
	git add pnpm-workspace.yaml
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'change workspace declaration'
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
)
case15_rc=$?
if [[ "$case15_rc" -eq 0 && $(wc -l <"$NPM_CALL_LOG") -eq 4 ]] &&
	grep -q '/packages/a|run lint' "$NPM_CALL_LOG" && grep -q '/packages/b|run lint' "$NPM_CALL_LOG" &&
	grep -q '/packages/analytics/web|run test' "$NPM_CALL_LOG" &&
	! grep -q '/packages/analytics|run' "$NPM_CALL_LOG" &&
	! grep -q '/pnpm-manifest|run' "$NPM_CALL_LOG"; then
	print_result "pnpm manifest alone triggers shared package checks" 0
else
	print_result "pnpm manifest alone triggers shared package checks" 1 "rc=${case15_rc}"
fi

# Shared changes still fail closed if neither root nor any workspace has checks.
NPM_CALL_LOG="${TEST_ROOT}/pnpm-no-checks.log"
export NPM_CALL_LOG
(
	cd "$PNPM_MANIFEST_REPO" || exit 1
	for manifest in packages/a/package.json packages/b/package.json packages/analytics/web/package.json; do
		printf '%s\n' '{"private":true}' >"$manifest"
	done
	git add packages
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'remove workspace checks'
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
)
no_checks_rc=$?
if [[ "$no_checks_rc" -ne 0 && ! -s "$NPM_CALL_LOG" ]]; then
	print_result "shared changes without check-capable scopes fail closed" 0
else
	print_result "shared changes without check-capable scopes fail closed" 1 "rc=${no_checks_rc}"
fi

# A locked workspace in a fresh worktree installs once, then reuses its
# installed lock marker. Install failures are environment failures, not tests.
LOCK_REPO="${TEST_ROOT}/locked-workspace"
make_repo "$LOCK_REPO"
NPM_CALL_LOG="${TEST_ROOT}/npm-locked.log"
export NPM_CALL_LOG NPM_FAKE_RC=0 NPM_INSTALL_FAIL=0
(
	cd "$LOCK_REPO" || exit 1
	printf '%s\n' '{"lockfileVersion":3}' >package-lock.json
	git add package-lock.json
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'add lockfile'
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0 || exit 1
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
)
locked_rc=$?
if [[ "$locked_rc" -eq 0 && $(grep -c '|ci --ignore-scripts --no-audit --no-fund' "$NPM_CALL_LOG") -eq 1 &&
	$(grep -c '|run typecheck' "$NPM_CALL_LOG") -eq 2 ]]; then
	print_result "locked worktree installs once before checks" 0
else
	print_result "locked worktree installs once before checks" 1 "rc=${locked_rc}"
fi
rm -rf "$LOCK_REPO/node_modules"
NPM_CALL_LOG="${TEST_ROOT}/npm-install-failure.log"
export NPM_CALL_LOG NPM_INSTALL_FAIL=1
(
	cd "$LOCK_REPO" || exit 1
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
) 2>"${TEST_ROOT}/install-error.log"
install_rc=$?
if [[ "$install_rc" -ne 0 && $(wc -l <"$NPM_CALL_LOG") -eq 1 ]] &&
	grep -q 'ENVIRONMENT FAILURE (exit 42): npm ci' "${TEST_ROOT}/install-error.log"; then
	print_result "install failure is classified as environment failure" 0
else
	print_result "install failure is classified as environment failure" 1 "rc=${install_rc}"
fi

# GH#40064: a lint TIMEOUT defers to a required base-branch check that names
# the same phase; later CI-required phases are left to CI, unrequired phases
# still run locally, and unreadable or non-matching requirements still block.
cat >"${FAKE_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_CALL_LOG:?}"
[[ "${GH_FAKE_FAIL:-0}" == 1 ]] && exit 1
case "$*" in
*rules/branches/*) [[ -n "${GH_FAKE_RULES:-}" ]] && printf '%s\n' "$GH_FAKE_RULES" ;;
*/branches/*) [[ -n "${GH_FAKE_CLASSIC:-}" ]] && printf '%s\n' "$GH_FAKE_CLASSIC" ;;
esac
exit 0
EOF
chmod +x "${FAKE_BIN}/gh"
DEFER_REPO="${TEST_ROOT}/validator-ci-deferral"
make_repo "$DEFER_REPO"
(
	cd "$DEFER_REPO" || exit 1
	printf '%s\n' '{"scripts":{"lint":"eslint","typecheck":"tsc --noEmit","test":"vitest run"}}' >package.json
	printf '%s\n' 'const answer: number = 42;' >index.ts
	git add package.json index.ts
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'typescript change'
) || exit 1
GH_CALL_LOG="${TEST_ROOT}/gh-defer.log"
export GH_CALL_LOG NPM_INSTALL_FAIL=0 NPM_FAKE_RC=0 GH_FAKE_FAIL=0 GH_FAKE_CLASSIC=''
run_defer_case() {
	local log_name="$1"
	NPM_CALL_LOG="${TEST_ROOT}/npm-${log_name}.log"
	export NPM_CALL_LOG
	: >"$NPM_CALL_LOG"
	(
		cd "$DEFER_REPO" || exit 1
		repo="owner/app"
		timeout_sec() {
			local _seconds="$1"
			shift
			[[ "$*" == *"run lint" ]] && return 124
			"$@"
			return $?
		}
		PATH="${FAKE_BIN}:$PATH" _run_project_validators 0 || exit $?
		printf 'DEFERRALS=%s\n' "$FULL_LOOP_VALIDATOR_DEFERRALS"
	) >"${TEST_ROOT}/${log_name}.out" 2>"${TEST_ROOT}/${log_name}.err"
	return $?
}
GH_FAKE_RULES=$'Format\nLint\nTypecheck\nUnit Tests'
export GH_FAKE_RULES
run_defer_case defer-all
defer_all_rc=$?
# The timeout stub never invokes npm for lint; deferred phases never run npm.
if [[ "$defer_all_rc" -eq 0 ]] && ! grep -q '|run ' "${TEST_ROOT}/npm-defer-all.log" &&
	grep -q "DEFERRED npm run lint (repository root): local TIMEOUT after 300s; required CI check 'Lint' on main" "${TEST_ROOT}/defer-all.err" &&
	grep -q "DEFERRALS=npm run lint (repository root) → Lint; npm run typecheck (repository root) → Typecheck; npm run test (repository root) → Unit Tests" "${TEST_ROOT}/defer-all.out" &&
	grep -q 'repos/owner/app/rules/branches/main' "$GH_CALL_LOG"; then
	print_result "lint timeout defers to matching required CI checks and records each deferral" 0
else
	print_result "lint timeout defers to matching required CI checks and records each deferral" 1 "rc=${defer_all_rc}"
fi
GH_FAKE_RULES='Lint'
GH_FAKE_CLASSIC=''
export GH_FAKE_RULES GH_FAKE_CLASSIC
run_defer_case defer-partial
defer_partial_rc=$?
if [[ "$defer_partial_rc" -eq 0 ]] && grep -q '|run typecheck' "${TEST_ROOT}/npm-defer-partial.log" &&
	grep -q '|run test' "${TEST_ROOT}/npm-defer-partial.log" &&
	grep -q 'DEFERRALS=npm run lint (repository root) → Lint$' "${TEST_ROOT}/defer-partial.out"; then
	print_result "phases CI does not require still run locally after a deferral" 0
else
	print_result "phases CI does not require still run locally after a deferral" 1 "rc=${defer_partial_rc}"
fi
GH_FAKE_RULES='Markdown Lint'
export GH_FAKE_RULES
run_defer_case defer-nomatch
defer_nomatch_rc=$?
if [[ "$defer_nomatch_rc" -ne 0 ]] && grep -q 'TIMEOUT after 300s: npm run lint' "${TEST_ROOT}/defer-nomatch.err" &&
	! grep -q 'DEFERRED' "${TEST_ROOT}/defer-nomatch.err"; then
	print_result "timeout without a matching required check still blocks" 0
else
	print_result "timeout without a matching required check still blocks" 1 "rc=${defer_nomatch_rc}"
fi
GH_FAKE_FAIL=1
export GH_FAKE_FAIL
run_defer_case defer-lookup-failed
defer_failed_rc=$?
if [[ "$defer_failed_rc" -ne 0 ]] && grep -q 'TIMEOUT after 300s: npm run lint' "${TEST_ROOT}/defer-lookup-failed.err" &&
	! grep -q 'DEFERRED' "${TEST_ROOT}/defer-lookup-failed.err"; then
	print_result "unreadable required checks fail closed to the blocking timeout" 0
else
	print_result "unreadable required checks fail closed to the blocking timeout" 1 "rc=${defer_failed_rc}"
fi
export GH_FAKE_FAIL=0

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
