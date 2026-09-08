#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aidevops-repos-help.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
CONFIG_DIR="${HOME}/.config/aidevops"
REPOS_FILE="${CONFIG_DIR}/repos.json"
FIRST_REPO="${TEST_ROOT}/first"
SECOND_REPO="${TEST_ROOT}/second"
mkdir -p "$CONFIG_DIR" "$FIRST_REPO" "$SECOND_REPO"

write_fixture() {
	jq -n --arg first "$FIRST_REPO" --arg second "$SECOND_REPO" \
		'{initialized_repos: [{path: $first, custom: "preserved"}, {path: $second}]}' >"$REPOS_FILE"
}

fail() {
	printf 'FAIL %s\n' "$1"
	exit 1
}

for action in remove rm; do
	for help_arg in help -h --help; do
		write_fixture
		cp "$REPOS_FILE" "${REPOS_FILE}.before"
		output=$(bash "$REPO_ROOT/aidevops.sh" repos "$action" "$help_arg") || fail "$action $help_arg returned non-zero"
		[[ "$output" == *"Usage: aidevops repos remove"* ]] || fail "$action $help_arg omitted scoped usage"
		cmp -s "$REPOS_FILE" "${REPOS_FILE}.before" || fail "$action $help_arg changed the registry"
		[[ ! -e "${REPOS_FILE}.tmp" ]] || fail "$action $help_arg left a temporary registry"
	done
done

write_fixture
bash "$REPO_ROOT/aidevops.sh" repos remove "$FIRST_REPO" >/dev/null
[[ "$(jq '.initialized_repos | length' "$REPOS_FILE")" -eq 1 ]] || fail "valid removal changed the wrong number of entries"
[[ "$(jq -r '.initialized_repos[0].path' "$REPOS_FILE")" == "$SECOND_REPO" ]] || fail "valid removal did not preserve the unrelated entry"

cp "$REPOS_FILE" "${REPOS_FILE}.before"
if bash "$REPO_ROOT/aidevops.sh" repos remove "${TEST_ROOT}/missing" >/dev/null 2>&1; then
	fail "missing repository reported successful removal"
fi
cmp -s "$REPOS_FILE" "${REPOS_FILE}.before" || fail "missing repository changed the registry"
[[ ! -e "${REPOS_FILE}.tmp" ]] || fail "missing repository left a temporary registry"

printf 'PASS repos remove help is read-only and removals report truthful outcomes\n'
