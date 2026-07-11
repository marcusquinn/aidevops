#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#27120 PR-to-TODO task identity resolution.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../issue-sync-pr-identity-helper.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
TODO_FILE="${TMP_DIR}/TODO.md"
PASS=0
FAIL=0

pass() {
	local message="$1"
	PASS=$((PASS + 1))
	printf 'PASS: %s\n' "$message"
	return 0
}

fail() {
	local message="$1"
	FAIL=$((FAIL + 1))
	printf 'FAIL: %s\n' "$message"
	return 0
}

expect_task() {
	local title="$1"
	local body="$2"
	local expected="$3"
	local description="$4"
	local output=""
	local actual=""
	if output=$(bash "$HELPER" resolve "$title" "$body" "$TODO_FILE" 2>/dev/null); then
		actual=$(printf '%s\n' "$output" | sed -n 's/^task_id=//p')
		if [[ "$actual" == "$expected" ]]; then
			pass "$description"
			return 0
		fi
	fi
	fail "$description (expected $expected, got ${actual:-error})"
	return 0
}

expect_failure() {
	local title="$1"
	local body="$2"
	local description="$3"
	if bash "$HELPER" resolve "$title" "$body" "$TODO_FILE" >/dev/null 2>&1; then
		fail "$description"
	else
		pass "$description"
	fi
	return 0
}

cat >"$TODO_FILE" <<'EOF'
- [ ] t4001 canonical task ref:GH#101
- [ ] t4002 recovery task ref:GH#102
- [ ] t4003 conflict task ref:GH#103
EOF

expect_task "t4001: canonical completion" "Resolves #101" "t4001" "canonical title remains authoritative"
expect_task "GH#102: recovery completion" "Fixes #102" "t4002" "GH-prefixed title falls back to unique issue reference"
expect_task "auto-recover: completion" "Closes #102" "t4002" "recovery title falls back to unique issue reference"
expect_task "renamed descriptive title" "Resolved #102" "t4002" "renamed title falls back to unique issue reference"
expect_failure "t4001: wrong identity" "Resolves #103" "title and issue-reference conflict fails closed"
expect_failure "auto-recover: multiple" $'Resolves #101\nResolves #102' "multiple closing issues without title identity fail closed"

printf '%s\n' '- [ ] t4999 duplicate ref ref:GH#102' >>"$TODO_FILE"
expect_failure "GH#102: ambiguous" "Resolves #102" "duplicate issue-reference mappings fail closed"

printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
