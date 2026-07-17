#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-linked-issue-guidance.sh — GH#23906 contributor guidance regression guard.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1

assert_contains() {
	local file="$1"
	local pattern="$2"
	local label="$3"
	if ! grep -Eq "$pattern" "${REPO_ROOT}/${file}"; then
		printf 'FAIL: %s missing expected pattern in %s\n' "$label" "$file" >&2
		return 1
	fi
	printf 'PASS: %s\n' "$label"
	return 0
}

assert_not_contains() {
	local file="$1"
	local pattern="$2"
	local label="$3"
	if grep -Eq "$pattern" "${REPO_ROOT}/${file}"; then
		printf 'FAIL: %s found unexpected pattern in %s\n' "$label" "$file" >&2
		return 1
	fi
	printf 'PASS: %s\n' "$label"
	return 0
}

assert_contains "CONTRIBUTING.md" 'Issue-first PRs' "CONTRIBUTING issue-first section"
assert_contains "CONTRIBUTING.md" 'Closes #NNN' "CONTRIBUTING closing keyword"
assert_contains "CONTRIBUTING.md" 'Ref #NNN' "CONTRIBUTING reference keyword"
assert_contains ".github/PULL_REQUEST_TEMPLATE.md" 'Linked issue' "PR template linked issue field"
assert_contains ".github/PULL_REQUEST_TEMPLATE.md" 'Closes #NNN' "PR template closing keyword"
assert_contains ".github/PULL_REQUEST_TEMPLATE.md" 'Ref #NNN' "PR template reference keyword"
assert_contains ".agents/scripts/commands/log-issue-aidevops.md" 'For #NNN.*Ref #NNN' "command log issue PR reference guidance"
assert_contains ".agents/workflows/log-issue-aidevops.md" 'For #NNN.*Ref #NNN' "workflow log issue PR reference guidance"
assert_contains ".github/workflows/linked-issue-check.yml" "publishStatus\('failure'" "linked issue status gate remains blocking"
assert_not_contains ".github/workflows/linked-issue-check.yml" 'core\.setFailed' "linked issue policy gate avoids workflow failure"
assert_contains ".github/workflows/linked-issue-check.yml" "state === 'success' && exhausted" "positive linked issue result tolerates exhausted API quota"
assert_contains ".github/workflows/linked-issue-check.yml" 'throw error' "negative linked issue result still fails closed"

assert_contains ".github/workflows/review-bot-gate-reusable.yml" 'classify-infra-rate-limit' "review gate classifies API exhaustion from immutable trust evidence"
assert_contains ".github/workflows/review-bot-gate-reusable.yml" 'RESULT.*PASS_ADVISORY' "trusted advisory default defers unavailable review API"
assert_contains ".github/workflows/review-bot-gate-reusable.yml" 'SKIP\|PASS_ADVISORY\|PASS_RATE_LIMITED' "external authors cannot use advisory review outcomes"
assert_contains ".github/workflows/review-bot-gate-reusable.yml" 'Unexpected review helper result' "malformed review helper output fails closed"
assert_contains ".github/workflows/review-bot-gate-reusable.yml" "result != 'INFRA_RATE_LIMITED'" "review gate avoids follow-up API label lookup during exhaustion"
assert_contains ".github/workflows/review-bot-gate-reusable.yml" 'skipping immediate status retry' "review gate avoids retry loop during exhaustion"
assert_contains ".github/workflows/review-bot-gate-reusable.yml" 'infrastructure wait — GitHub API quota exhausted' "review status reports infrastructure wait truthfully"
assert_not_contains ".github/workflows/review-bot-gate-reusable.yml" 'sleep 5 && gh api' "review gate removed blind status retry"

exit 0
