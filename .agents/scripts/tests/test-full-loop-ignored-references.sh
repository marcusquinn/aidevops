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

# GH#40019: dependency payloads and tracked basenames are not omitted sources.
mkdir -p vendor/bin vendor/package .cache .venv dist nested/vendor/package
printf 'vendor/\n.cache/\n.venv/\ndist/\n' >>.gitignore
printf 'tool\n' >vendor/bin/phpcs
printf 'readme\n' >vendor/package/README.md
printf 'readme\n' >nested/vendor/package/README.md
printf 'readme\n' >config/README.md
printf 'tool\n' >config/phpcs
printf 'tracked readme\n' >README.md
git add README.md
check_line 0 '// phpcs:ignore Example.Rule'
check_line 0 'See README.md and [documentation](README.md).'
check_line 0 'vendor/bin/phpcs vendor/package/README.md nested/vendor/package/README.md'
check_line 1 'config/README.md'
check_line 1 'config/phpcs'
check_line 1 'config/secrets.local.json: local configuration'
check_line 1 'prefixsecrets.local.json then secrets.local.json'
check_line 0 'prefixsecrets.local.jsonsecrets.local.json'
check_line 0 'secrets.local.json:annotation'
check_line 1 '+++ config/secrets.local.json'

# The changed-file header itself must never count as an added reference.
printf 'safe\n' >secrets.local.json
git add secrets.local.json
check_line 0 'Ordinary prose.'

# Acceptance-scale real filesystem fixture: 80k node modules, 3k vendor
# payloads, caches, and a >2 MB tracked bundle. Time only the production check.
for ((i = 0; i < 80000; i++)); do
	: >"node_modules/pkg/generated-$i.js"
done
for ((i = 0; i < 3000; i++)); do
	: >"vendor/package/generated-$i.php"
done
for ((i = 0; i < 664; i++)); do
	: >".cache/generated-$i.php"
done
: >.venv/payload.json
: >dist/payload.json
awk 'BEGIN { for (i=0; i<40000; i++) print "const bundled = 1234567890; // ordinary compiled output text" }' >bundle.js
git add bundle.js
started=$SECONDS
check_line 0 'README.md // phpcs:ignore .cache/generated-1.php .venv/payload.json dist/payload.json'
elapsed=$((SECONDS - started))
if ((elapsed >= 5)); then
	printf 'FAIL: acceptance-scale check took %ss (limit: <5s)\n' "$elapsed" >&2
	exit 1
fi
printf 'PASS: 83,664 ignored dependency/cache files and >2 MB diff in %ss\n' "$elapsed"
check_line 1 'config/secrets.local.json'

# Already committed WIP is part of the prospective PR, not just staged edits.
printf 'config/secrets.local.json\n' >committed.md
git add committed.md
git -c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false commit -qm reference
check_line 1 'Ordinary prose after the committed reference.'
FULL_LOOP_ALLOW_IGNORED_REFERENCES=1
check_line 0 'config/secrets.local.json'
printf 'PASS: %s ignored-reference checks\n' "$TESTS_RUN"
