#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Regression tests for repo-layout-audit-helper.sh (GH#22367)
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
HELPER="${REPO_ROOT}/.agents/scripts/repo-layout-audit-helper.sh"

PASS=0
FAIL=0

pass() {
	local name="$1"
	printf '  PASS: %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf '  FAIL: %s\n' "$name"
	[[ -n "$detail" ]] && printf '        %s\n' "$detail"
	FAIL=$((FAIL + 1))
	return 0
}

assert_contains() {
	local name="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "missing: $needle"
	fi
	return 0
}

assert_not_contains() {
	local name="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "unexpected: $needle"
	fi
	return 0
}

assert_exit() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" -eq "$actual" ]]; then
		pass "$name"
	else
		fail "$name" "expected exit $expected, got $actual"
	fi
	return 0
}

make_fixture_repo() {
	local repo="$1"
	mkdir -p "$repo/allowed-dir" "$repo/rogue-dir" "$repo/_cases"
	printf 'ok\n' >"$repo/README.md"
	printf 'ok\n' >"$repo/allowed-dir/file.txt"
	printf 'ok\n' >"$repo/rogue.txt"
	printf 'ok\n' >"$repo/rogue-dir/file.txt"
	printf 'ok\n' >"$repo/_cases/case.txt"
	git -C "$repo" init -q
	git -C "$repo" add README.md allowed-dir rogue.txt rogue-dir _cases
	git -C "$repo" commit -q -m 'fixture' >/dev/null 2>&1
	return 0
}

make_policy() {
	local policy="$1"
	{
		printf '# path\tclass\trationale\n'
		printf 'README.md\tpublic-entrypoint\tPrimary docs.\n'
		printf 'allowed-dir\tframework-internal\tKnown framework fixture directory.\n'
		printf '_cases\trepo-data-plane\tIntentional repo-local data-plane exception.\n'
	} >"$policy"
	return 0
}

main() {
	if [[ ! -x "$HELPER" ]]; then
		printf 'helper not executable: %s\n' "$HELPER" >&2
		exit 1
	fi

	local tmp repo policy output status warn_output warn_status clean_repo clean_policy clean_output clean_status
	tmp=$(mktemp -d 2>/dev/null || mktemp -d -t repo-layout-audit)
	# shellcheck disable=SC2064  # capture the concrete temp path before local tmp goes out of scope
	trap "rm -rf '$tmp'" EXIT
	repo="${tmp}/repo"
	policy="${tmp}/policy.conf"
	clean_repo="${tmp}/clean-repo"
	clean_policy="${tmp}/clean-policy.conf"

	mkdir -p "$repo" "$clean_repo"
	make_fixture_repo "$repo"
	make_policy "$policy"

	printf '=== repo-layout-audit-helper tests ===\n\n'

	output=$(bash "$HELPER" --check --repo "$repo" --policy "$policy" 2>&1)
	status=$?
	assert_exit "unknown top-level paths fail --check" 1 "$status"
	assert_contains "known root file is allowed" "$output" $'ALLOW\tREADME.md'
	assert_contains "known root directory is allowed" "$output" $'ALLOW\tallowed-dir'
	assert_contains "intentional underscore data plane is allowed" "$output" $'ALLOW\t_cases'
	assert_contains "unknown top-level file is reported" "$output" $'UNKNOWN\trogue.txt'
	assert_contains "unknown top-level directory is reported" "$output" $'UNKNOWN\trogue-dir'
	assert_contains "unknown shell/file guidance mentions policy" "$output" '.agents/configs/repo-layout-policy.conf'

	warn_output=$(bash "$HELPER" --check --warn-only --repo "$repo" --policy "$policy" 2>&1)
	warn_status=$?
	assert_exit "warn-only mode reports drift without blocking" 0 "$warn_status"
	assert_contains "warn-only still reports unknown path" "$warn_output" $'UNKNOWN\trogue.txt'

	mkdir -p "$clean_repo/docs"
	printf 'ok\n' >"$clean_repo/README.md"
	printf 'ok\n' >"$clean_repo/docs/page.md"
	git -C "$clean_repo" init -q
	git -C "$clean_repo" add README.md docs
	git -C "$clean_repo" commit -q -m 'clean fixture' >/dev/null 2>&1
	{
		printf 'README.md\tpublic-entrypoint\tPrimary docs.\n'
		printf 'docs\tdocs-planning\tDocumentation.\n'
	} >"$clean_policy"
	clean_output=$(bash "$HELPER" --check --repo "$clean_repo" --policy "$clean_policy" 2>&1)
	clean_status=$?
	assert_exit "fully allowed fixture exits zero" 0 "$clean_status"
	assert_not_contains "fully allowed fixture has no unknown paths" "$clean_output" 'UNKNOWN'

	printf '\nTests passed: %d\nTests failed: %d\n' "$PASS" "$FAIL"
	if [[ "$FAIL" -gt 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
