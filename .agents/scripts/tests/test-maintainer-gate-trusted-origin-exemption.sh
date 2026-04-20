#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-maintainer-gate-trusted-origin-exemption.sh — t2451 regression guard.
#
# Structural assertions over `.github/workflows/maintainer-gate.yml`:
#
#   A. The file parses as valid YAML.
#   B. Job 1 Check 2 includes a HAS_TRUSTED_ORIGIN_LABEL computation
#      referencing both origin:worker and origin:interactive, with
#      explicit github-actions[bot]/REPO_OWNER issue-author gating.
#   C. The HAS_TRUSTED_ORIGIN_LABEL path includes the non-maintainer
#      comment defence-in-depth check (author_association == "NONE"
#      or "CONTRIBUTOR").
#   D. The exemption condition accepts HAS_TRUSTED_ORIGIN_LABEL
#      alongside the existing github-actions[bot] and HAS_AUTOMATION_LABEL
#      paths.
#   E. Job 3 (retrigger-pr-checks) mirrors the trusted-origin skip for
#      origin:worker PRs with OWNER/MEMBER author and a trusted issue author
#      with no non-maintainer comments.
#   F. REPO_OWNER env var is wired through both Job 1 and Job 3 steps.
#
# Workflow execution cannot be tested locally — this is a static shape
# check that prevents accidental regressions to the exemption logic
# during refactoring. CI is the authoritative runtime test.
#
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

# Resolve the workflow file relative to the test (tests live in .agents/scripts/tests/)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/maintainer-gate.yml"

if [[ ! -f "$WORKFLOW_FILE" ]]; then
	print_result "workflow file exists" 1 "not found: $WORKFLOW_FILE"
	printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	exit 1
fi
print_result "workflow file exists" 0

# -------------------------------------------------------------------
# Check A: YAML parses
# -------------------------------------------------------------------
if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$WORKFLOW_FILE" 2>/dev/null; then
	print_result "maintainer-gate.yml parses as valid YAML" 0
else
	print_result "maintainer-gate.yml parses as valid YAML" 1 "python3 yaml.safe_load failed"
fi

assert_contains() {
	local pattern="$1" label="$2"
	if grep -qE -- "$pattern" "$WORKFLOW_FILE" 2>/dev/null; then
		print_result "$label" 0
	else
		print_result "$label" 1 "pattern '${pattern}' not found"
	fi
	return 0
}

# -------------------------------------------------------------------
# Check B: HAS_TRUSTED_ORIGIN_LABEL computation exists
# -------------------------------------------------------------------
assert_contains "HAS_TRUSTED_ORIGIN_LABEL=false" \
	"initialises HAS_TRUSTED_ORIGIN_LABEL to false"
assert_contains "origin:worker" \
	"references origin:worker label"
assert_contains "origin:interactive" \
	"references origin:interactive label (existing + mirror)"
assert_contains "ISSUE_AUTHOR.*github-actions\[bot\]" \
	"gates trust on bot-authored issues"
# shellcheck disable=SC2016  # literal $REPO_OWNER is the search pattern
assert_contains 'ISSUE_AUTHOR.*\$REPO_OWNER' \
	"gates trust on owner-authored issues (REPO_OWNER check)"

# -------------------------------------------------------------------
# Check C: non-maintainer comment defence-in-depth
# -------------------------------------------------------------------
assert_contains "author_association.*NONE.*CONTRIBUTOR" \
	"filters non-maintainer comments on the trusted path (NONE, CONTRIBUTOR)"
assert_contains "NON_MAINT_COMMENTS" \
	"computes NON_MAINT_COMMENTS count on the trusted path"

# -------------------------------------------------------------------
# Check D: exemption condition accepts HAS_TRUSTED_ORIGIN_LABEL
# -------------------------------------------------------------------
assert_contains 'HAS_TRUSTED_ORIGIN_LABEL.*==.*"true"' \
	"exemption condition evaluates HAS_TRUSTED_ORIGIN_LABEL"
assert_contains 'HAS_AUTOMATION_LABEL.*==.*"true"' \
	"exemption condition still accepts HAS_AUTOMATION_LABEL (back-compat)"

# -------------------------------------------------------------------
# Check E: Job 3 mirror — origin:worker skip with trusted issue author
# -------------------------------------------------------------------
assert_contains "ISSUE_TRUSTED_J3" \
	"Job 3 computes ISSUE_TRUSTED_J3 for origin:worker PRs"
assert_contains "NON_MAINT_COMMENTS_J3" \
	"Job 3 checks non-maintainer comments on trusted path"
assert_contains "SKIP rerun.*origin:worker" \
	"Job 3 emits SKIP rerun message for origin:worker"

# -------------------------------------------------------------------
# Check F: REPO_OWNER env wired through both jobs
# -------------------------------------------------------------------
# Job 1 should have REPO_OWNER in env, and Job 3 too.
# Count occurrences: expect at least 2 REPO_OWNER env entries.
owner_env_count=$(grep -cE 'REPO_OWNER:[[:space:]]*\$\{\{[[:space:]]*github\.repository_owner' \
	"$WORKFLOW_FILE" 2>/dev/null || echo "0")
if [[ "$owner_env_count" -ge 2 ]]; then
	print_result "REPO_OWNER env in both Job 1 and Job 3 (found $owner_env_count entries)" 0
else
	print_result "REPO_OWNER env in both Job 1 and Job 3" 1 \
		"expected >=2 occurrences, found $owner_env_count"
fi

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
