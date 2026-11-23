#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Real-Git regression coverage for GH#39939 and GH#39956.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../full-loop-helper-commit.sh
source "$SCRIPT_DIR/full-loop-helper-commit.sh"

print_error() {
	local message="$1"
	printf '%s\n' "$message" >&2
	return 0
}

print_warning() {
	local message="$1"
	printf '%s\n' "$message" >&2
	return 0
}

_resolve_pr_base_branch() {
	local remote="$1"
	[[ "$remote" == origin ]] || return 1
	printf 'main\n'
	return 0
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
git init -q "$TEST_ROOT"
cd "$TEST_ROOT"
git -c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false commit -qm base --allow-empty
git update-ref refs/remotes/origin/main HEAD
mkdir -p .husky/_ nested/.husky/_ config node_modules/pkg __pycache__
printf '.husky/_/\nnested/.husky/_/\nconfig/\nnode_modules/\n__pycache__/\n' >.gitignore
printf 'generated\n' >.husky/_/h
printf 'generated\n' >nested/.husky/_/hook
printf 'payload\n' >config/secrets.local.json
printf 'payload\n' >config/h
printf 'payload\n' >config/ab
printf 'payload\n' >'config/a+b[1].json'
printf 'payload\n' >node_modules/pkg/payload.json
printf 'payload\n' >__pycache__/cache.pyc
# Keep nounset array expansion safe on Bash 3.2 without excluding any fixture.
_full_loop_runtime_paths=(".test-runtime")
FULL_LOOP_ALLOW_IGNORED_REFERENCES=0
TESTS_RUN=0

check_line() {
	local expected="$1" text="$2" actual=0
	printf '%s\n' "$text" >document.md
	git add document.md
	_check_ignored_source_references >"$TEST_ROOT/output" 2>&1 || actual=$?
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL: expected %s, got %s for %s\n' "$expected" "$actual" "$text" >&2
		return 1
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	return 0
}

check_line 0 'The change has healthy prose with h and ab within it.'
check_line 0 'h ab'
check_line 0 '.husky/_/h nested/.husky/_/hook node_modules/pkg/payload.json cache.pyc'
check_line 0 'prefixsecrets.local.json secrets.local.json.backup secretsXlocalXjson'
check_line 0 'aab1.json prefixa+b[1].json'
check_line 1 'config/h'
check_line 1 "See \`config/ab\`."
check_line 1 'config/secrets.local.json'
check_line 1 'secrets.local.json'
check_line 1 'See "secrets.local.json", please.'
check_line 1 '[link](config/secrets.local.json)'
check_line 1 'file:secrets.local.json'
check_line 1 'other/secrets.local.json'
check_line 1 'a+b[1].json'
check_line 1 "See \`config/a+b[1].json\`."

# Already committed WIP is part of the prospective PR, not just staged edits.
printf 'config/secrets.local.json\n' >committed.md
git add committed.md
git -c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false commit -qm reference
check_line 1 'Ordinary prose after the committed reference.'
FULL_LOOP_ALLOW_IGNORED_REFERENCES=1
check_line 0 'config/secrets.local.json'
printf 'PASS: %s ignored-reference checks\n' "$TESTS_RUN"
