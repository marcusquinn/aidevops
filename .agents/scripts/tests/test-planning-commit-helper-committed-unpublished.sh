#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#37252: planning files WIP-committed on a feature
# branch must not be silently skipped by planning-commit-helper.sh.

set -u

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

git() {
	"${TEST_GIT_BINARY:-/usr/bin/git}" "$@"
	return $?
}

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR_TEST}/../planning-commit-helper.sh"
TMP=""

cleanup() {
	[[ -n "$TMP" ]] && rm -rf "$TMP"
	return 0
}

setup_fixture() {
	git init -q --bare --initial-branch=main "${TMP}/remote.git" || return 1
	git clone -q "${TMP}/remote.git" "${TMP}/work" || return 1
	cd "${TMP}/work" || return 1
	git config user.name Test
	git config user.email test@test.local
	git config commit.gpgsign false
	printf '# Tasks\n' >TODO.md
	git add TODO.md
	git commit -q -m seed || return 1
	git push -q origin HEAD:main || return 1
	git fetch -q origin
	git remote set-head origin main || return 1
	git checkout -q -b feature/x || return 1
	mkdir -p todo/tasks
	printf 'brief\n' >todo/tasks/t999-brief.md
	git add -A
	git commit -q -m "wip: brief" || return 1
	return 0
}

main() {
	TMP="$(mktemp -d)" || return 1
	trap cleanup EXIT
	setup_fixture || {
		printf 'FAIL fixture setup\n'
		return 1
	}
	local out="" rc=0
	out=$(bash "$HELPER" "plan: test" 2>&1) || rc=$?
	if [[ "$rc" -eq 1 && "$out" == *"todo/tasks/t999-brief.md"* ]]; then
		printf 'PASS committed-unpublished planning path refused and named\n'
		return 0
	fi
	printf 'FAIL rc=%s output=%s\n' "$rc" "$out"
	return 1
}

main "$@"
exit $?
