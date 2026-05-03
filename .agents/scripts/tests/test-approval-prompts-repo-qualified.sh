#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name"
	if [[ -n "$detail" ]]; then
		printf '     %s\n' "$detail"
	fi
	return 0
}

assert_contains() {
	local name="$1"
	local file="$2"
	local pattern="$3"
	if grep -Fq -- "$pattern" "$file"; then
		pass "$name"
		return 0
	fi
	fail "$name" "missing pattern in ${file}: ${pattern}"
	return 0
}

main() {
	assert_contains \
		"quality feedback approval prompt includes repo slug" \
		"${REPO_ROOT}/.agents/scripts/quality-feedback-issues-lib.sh" \
		"sudo aidevops approve issue \${issue_num} \${repo_slug}"
	assert_contains \
		"quality feedback issue body includes current repo slug" \
		"${REPO_ROOT}/.agents/scripts/quality-feedback-issues-lib.sh" \
		"sudo aidevops approve issue <number> \${repo_slug}"
	assert_contains \
		"pulse NMR circuit-breaker log includes repo slug" \
		"${REPO_ROOT}/.agents/scripts/pulse-nmr-approval.sh" \
		"sudo aidevops approve issue \${issue_num} \${slug}"
	assert_contains \
		"external contributor PR prompt includes repo slug" \
		"${REPO_ROOT}/.agents/scripts/pulse-merge-gates.sh" \
		"sudo aidevops approve issue NNN \${repo_slug}"
	assert_contains \
		"labelless external issue prompt includes concrete repo slug" \
		"${REPO_ROOT}/.agents/scripts/pulse-issue-reconcile.sh" \
		"sudo aidevops approve issue \${issue_num} \${slug}"
	assert_contains \
		"knowledge review template includes repo slug placeholder" \
		"${REPO_ROOT}/.agents/templates/knowledge-review-nmr-body.md" \
		'sudo aidevops approve issue <this-issue-number> {{REPO_SLUG}}'
	assert_contains \
		"knowledge review fallback includes repo slug" \
		"${REPO_ROOT}/.agents/scripts/knowledge-review-helper.sh" \
		"sudo aidevops approve issue <this-issue-number> \${repo_slug}"
	assert_contains \
		"approval setup output recommends explicit repo slug" \
		"${REPO_ROOT}/.agents/scripts/approval-helper.sh" \
		"sudo aidevops approve issue <number> <owner/repo>"

	printf '\n%d tests run, %d failures\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
