#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-full-loop-project-validators-shell-only.sh — GH#22007 regression guard.
#
# Verifies commit-and-pr project validators skip Node validators for shell-only
# diffs, so missing local Node dependencies (for example no local tsc binary) do
# not block shell-only PR creation. Node/TypeScript diffs still run the configured
# typecheck and fail closed when that command reports an error.

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
		cat >package.json <<'EOF'
{"scripts":{"typecheck":"tsc --noEmit"}}
EOF
		git add package.json
		git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'initial'
	) || return 1
	return 0
}

# Case 1: shell-only change skips Node validators completely, even though a
# package.json typecheck script exists and npm would fail if invoked.
SHELL_REPO="${TEST_ROOT}/shell-only"
make_repo "$SHELL_REPO"
NPM_CALL_LOG="${TEST_ROOT}/npm-shell.log"
export NPM_CALL_LOG NPM_FAKE_RC=127
(
	cd "$SHELL_REPO" || exit 1
	mkdir -p .agents/scripts
	printf '%s\n' '#!/usr/bin/env bash' 'echo ok' >.agents/scripts/example.sh
	git add .agents/scripts/example.sh
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'shell-only change'
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
)
case1_rc=$?
if [[ "$case1_rc" -eq 0 && ! -s "$NPM_CALL_LOG" ]]; then
	print_result "shell-only diff skips Node validators" 0
else
	print_result "shell-only diff skips Node validators" 1 "rc=${case1_rc}, npm_log=$(wc -c <"$NPM_CALL_LOG" 2>/dev/null || printf 0)"
fi

# Case 2: TypeScript change still runs configured typecheck and fails closed
# when the command reports an error.
TS_REPO="${TEST_ROOT}/typescript-change"
make_repo "$TS_REPO"
NPM_CALL_LOG="${TEST_ROOT}/npm-ts.log"
export NPM_CALL_LOG NPM_FAKE_RC=2
(
	cd "$TS_REPO" || exit 1
	printf '%s\n' 'const answer: number = "wrong";' >index.ts
	git add index.ts
	git -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'typescript change'
	PATH="${FAKE_BIN}:$PATH" _run_project_validators 0
)
case2_rc=$?
if [[ "$case2_rc" -ne 0 && -s "$NPM_CALL_LOG" ]]; then
	print_result "TypeScript diff runs failing typecheck" 0
else
	print_result "TypeScript diff runs failing typecheck" 1 "rc=${case2_rc}, npm_log=$(wc -c <"$NPM_CALL_LOG" 2>/dev/null || printf 0)"
fi

# Case 3: if an auto-fix command removes the process' current subdirectory,
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
case3_rc=$?
case3_head_subject=$(git -C "$CWD_REPO" log -1 --format=%s 2>/dev/null || printf '')
case3_file=$(git -C "$CWD_REPO" show HEAD:tracked.txt 2>/dev/null || printf '')
if [[ "$case3_rc" -eq 0 && "$case3_head_subject" == "node project" && "$case3_file" == $'before\nfixed' ]]; then
	print_result "auto-fix restores repo root before amend when cwd disappears" 0
else
	print_result "auto-fix restores repo root before amend when cwd disappears" 1 "rc=${case3_rc}, subject=${case3_head_subject}, file=${case3_file}"
fi

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
