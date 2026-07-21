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
printf '%s\n' "npm should not run for shell-only diffs" >>"${NPM_CALL_LOG:?}"
if [[ "${NPM_FAKE_ACTION:-}" == "delete-cwd-after-edit" ]]; then
	printf '%s\n' 'fixed' >>"${NPM_FIX_TARGET:?}"
	if [[ -n "${NPM_DELETE_DIR:-}" ]]; then
		rm -rf "$NPM_DELETE_DIR"
	fi
	exit 0
fi
exit "${NPM_FAKE_RC:-2}"
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

# Case 4: if an auto-fix command removes the process' current subdirectory,
# the validator restores the repository root before running git diff/add/amend.
# This guards the GH#22526 failure class where amend hit getcwd() from a stale
# cwd and reported: fatal: Unable to read current working directory.
CWD_REPO="${TEST_ROOT}/cwd-restore"
make_repo "$CWD_REPO"
mkdir -p "${CWD_REPO}/vanishing"
(
	cd "$CWD_REPO" || exit 1
	cat >package.json <<'EOF'
{"scripts":{"format:fix":"node scripts/fix.js"}}
EOF
	printf '%s\n' 'before' >tracked.txt
	git add package.json tracked.txt
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'node project'
)
NPM_CALL_LOG="${TEST_ROOT}/npm-cwd.log"
NPM_FIX_TARGET="${CWD_REPO}/tracked.txt"
NPM_DELETE_DIR="${CWD_REPO}/vanishing"
export NPM_CALL_LOG NPM_FIX_TARGET NPM_DELETE_DIR NPM_FAKE_ACTION=delete-cwd-after-edit NPM_FAKE_RC=0
(
	cd "${CWD_REPO}/vanishing" || exit 1
	PATH="${FAKE_BIN}:$PATH" fix_changes=0 _run_node_auto_fix npm 30 0
)
case4_rc=$?
case4_head_subject=$(git -C "$CWD_REPO" log -1 --format=%s 2>/dev/null || printf '')
case4_file=$(git -C "$CWD_REPO" show HEAD:tracked.txt 2>/dev/null || printf '')
if [[ "$case4_rc" -eq 0 && "$case4_head_subject" == "node project" && "$case4_file" == $'before\nfixed' ]]; then
	print_result "auto-fix restores repo root before amend when cwd disappears" 0
else
	print_result "auto-fix restores repo root before amend when cwd disappears" 1 "rc=${case4_rc}, subject=${case4_head_subject}, file=${case4_file}"
fi

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
