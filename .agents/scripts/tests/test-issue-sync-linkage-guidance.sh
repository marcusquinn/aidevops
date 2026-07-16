#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#27908 issue-link guidance matching.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/issue-sync-reusable.yml"
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

expect_reference() {
	local body="$1"
	local description="$2"
	if printf '%s\n' "$body" | grep -qiE '(closes|fixes|resolves|for|ref)[[:space:]]+#[0-9]+'; then
		pass "$description"
	else
		fail "$description"
	fi
	return 0
}

expect_no_reference() {
	local body="$1"
	local description="$2"
	if printf '%s\n' "$body" | grep -qiE '(closes|fixes|resolves|for|ref)[[:space:]]+#[0-9]+'; then
		fail "$description"
	else
		pass "$description"
	fi
	return 0
}

resolve_task_issue() {
	local task_id="$1"
	local issues_json="$2"
	jq -r --arg prefix "${task_id}:" \
		'[.[] | select(.title | startswith($prefix))] | if length == 1 then .[0].number else empty end' \
		<<<"$issues_json"
	return 0
}

expect_task_issue() {
	local task_id="$1"
	local issues_json="$2"
	local expected="$3"
	local description="$4"
	local actual=""
	actual=$(resolve_task_issue "$task_id" "$issues_json")
	if [[ "$actual" == "$expected" ]]; then
		pass "$description"
	else
		fail "$description (expected '${expected}', got '${actual}')"
	fi
	return 0
}

expect_workflow_pattern() {
	local pattern="$1"
	local description="$2"
	if grep -Fq -- "$pattern" "$WORKFLOW_FILE"; then
		pass "$description"
	else
		fail "$description"
	fi
	return 0
}

expect_reference 'For #27908' 'For reference satisfies linkage guidance'
expect_reference 'ref #27908' 'Ref reference is case-insensitive'
expect_reference 'Resolves #27908' 'closing keyword still satisfies linkage guidance'
expect_no_reference 'Mentions issue 27908 without a supported reference' 'plain issue mention does not satisfy linkage guidance'

ISSUES='[{"number":27908,"title":"t2879: exact task"},{"number":27909,"title":"t28790: similar task"}]'
expect_task_issue 't2879' "$ISSUES" '27908' 'one exact task-title prefix resolves uniquely'
expect_task_issue 't2999' "$ISSUES" '' 'no exact task-title prefix does not resolve'

AMBIGUOUS='[{"number":27908,"title":"t2879: first"},{"number":27910,"title":"t2879: duplicate"}]'
expect_task_issue 't2879' "$AMBIGUOUS" '' 'ambiguous exact task-title prefixes do not resolve'

expect_workflow_pattern '(closes|fixes|resolves|for|ref)[[:space:]]+#[0-9]+' 'workflow recognizes closing and non-closing references'
expect_workflow_pattern '--json number,title' 'workflow fetches titles for exact identity filtering'
expect_workflow_pattern 'if length == 1 then .[0].number else empty end' 'workflow requires one exact task match'

printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
