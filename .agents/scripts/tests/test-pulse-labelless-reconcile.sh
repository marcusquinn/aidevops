#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pulse-labelless-reconcile.sh — coverage for the t2112 labelless
# aidevops issue backfill pass in pulse-issue-reconcile.sh.
#
# Strategy: stub `gh` as a bash function (PATH-shadow won't work because the
# reconcile module runs with the pulse's prepended PATH) so we can intercept
# every call. Three fixture issues:
#   #500 — aidevops-shaped + labelless (MUST be processed)
#   #501 — non-aidevops shape (random bug title)  (MUST be ignored)
#   #502 — aidevops-shaped + already has origin:worker (MUST be ignored)
#
# Assertions:
#   - gh issue edit called with --add-label origin:worker AND tier:standard for #500
#   - body tag (#ai) from #500's body extracted as a label
#   - gh issue comment called once on #500 with the sentinel marker
#   - gh issue edit NOT called on #501 or #502
#   - gh issue comment NOT called on #501 or #502

set -u

# shellcheck disable=SC2155
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2155
readonly TEST_REPO_ROOT="$(cd "${TEST_DIR}/../../.." && pwd)"
readonly RECONCILE_SRC="${TEST_REPO_ROOT}/.agents/scripts/pulse-issue-reconcile.sh"

TEST_TMPDIR=$(mktemp -d /tmp/test-pulse-labelless.XXXXXX)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

TRACE_FILE="${TEST_TMPDIR}/gh-trace.log"
LOGFILE="${TEST_TMPDIR}/pulse-wrapper.log"
: >"$TRACE_FILE"
: >"$LOGFILE"
export TRACE_FILE LOGFILE

# -----------------------------------------------------------------------------
# Fake repos.json — one test/repo
# -----------------------------------------------------------------------------
REPOS_JSON="${TEST_TMPDIR}/repos.json"
cat >"$REPOS_JSON" <<'JSON'
{
  "initialized_repos": [
    {"slug": "test/repo", "pulse": true, "local_only": false}
  ],
  "git_parent_dirs": []
}
JSON
export REPOS_JSON

# -----------------------------------------------------------------------------
# Fixture issues for the gh stub
# -----------------------------------------------------------------------------
FIXTURE_ISSUES_JSON=$(
	cat <<'JSON'
[
  {
    "number": 500,
    "title": "t325.2: feat: types + anonymizer",
    "body": "Shared types and LLM-based text anonymization module.\n\nBrief: `todo/tasks/t325.2-brief.md`\nParent: t325\n\n## Tags inline: #ai #security\n",
    "labels": []
  },
  {
    "number": 501,
    "title": "Flaky test in anonymizer suite",
    "body": "Sometimes fails on CI. Not aidevops-shaped.",
    "labels": []
  },
  {
    "number": 502,
    "title": "t325.3: feat: analyzer module",
    "body": "Already-blessed issue.",
    "labels": [{"name": "origin:worker"}, {"name": "tier:standard"}]
  }
]
JSON
)
export FIXTURE_ISSUES_JSON

# -----------------------------------------------------------------------------
# Source the reconcile module. It has an include guard and expects certain
# functions from shared-constants.sh to exist (run_stage_with_timeout, etc.).
# For this unit test we don't need run_stage_with_timeout — we call the
# function directly. We do need a few stubs so the module sources cleanly.
# -----------------------------------------------------------------------------
# Minimal stubs for sourced module dependencies.
set_issue_status() { return 0; }
export -f set_issue_status

# shellcheck disable=SC1090
source "$RECONCILE_SRC"

# Override `gh` as a shell function AFTER sourcing.
# shellcheck disable=SC2317
gh() {
	printf 'gh %s\n' "$*" >>"$TRACE_FILE"

	local cmd="${1:-}" sub="${2:-}"

	# gh issue list --repo test/repo --state open --json number,title,body,labels --limit 50
	if [[ "$cmd" == "issue" && "$sub" == "list" ]]; then
		printf '%s' "$FIXTURE_ISSUES_JSON"
		return 0
	fi

	# gh issue view N --json comments --jq ...
	if [[ "$cmd" == "issue" && "$sub" == "view" ]]; then
		# Return empty comments — no sentinel present → backfill proceeds
		printf '[]'
		return 0
	fi

	# gh issue edit / comment / label create — record and return success
	if [[ "$cmd" == "issue" && ("$sub" == "edit" || "$sub" == "comment") ]]; then
		return 0
	fi
	if [[ "$cmd" == "label" && "$sub" == "create" ]]; then
		return 0
	fi

	return 0
}
export -f gh

# -----------------------------------------------------------------------------
# Run the function under test
# -----------------------------------------------------------------------------
if ! reconcile_labelless_aidevops_issues >"${TEST_TMPDIR}/cmd.out" 2>&1; then
	printf 'FAIL: reconcile_labelless_aidevops_issues exited non-zero\n'
	cat "${TEST_TMPDIR}/cmd.out"
	exit 1
fi

# -----------------------------------------------------------------------------
# Assertions
# -----------------------------------------------------------------------------
failed=0

# The function should have scanned #500, applied labels, posted a comment.
# Extract gh issue edit and comment calls targeted at each number.
edit_500=$(grep -c '^gh issue edit 500 --repo test/repo' "$TRACE_FILE" || true)
edit_501=$(grep -c '^gh issue edit 501 --repo test/repo' "$TRACE_FILE" || true)
edit_502=$(grep -c '^gh issue edit 502 --repo test/repo' "$TRACE_FILE" || true)
comment_500=$(grep -c '^gh issue comment 500 --repo test/repo' "$TRACE_FILE" || true)
comment_501=$(grep -c '^gh issue comment 501 --repo test/repo' "$TRACE_FILE" || true)

# #500 MUST be edited at least once
if [[ "$edit_500" -lt 1 ]]; then
	printf 'FAIL: expected gh issue edit on #500, got %d\n' "$edit_500"
	failed=1
fi
# Extract the edit line for #500 and check each required label substring.
edit_line=$(grep '^gh issue edit 500 --repo test/repo' "$TRACE_FILE" | head -1)
if [[ -z "$edit_line" ]]; then
	printf 'FAIL: no gh issue edit 500 line in trace\n'
	failed=1
else
	for required in "origin:worker" "tier:standard" "ai" "security"; do
		if [[ "$edit_line" != *"--add-label $required"* ]]; then
			printf 'FAIL: #500 edit missing --add-label %s\n' "$required"
			printf '  got: %s\n' "$edit_line"
			failed=1
		fi
	done
fi

# #500 MUST get a comment (exactly one)
if [[ "$comment_500" -ne 1 ]]; then
	printf 'FAIL: expected exactly 1 gh issue comment on #500, got %d\n' "$comment_500"
	failed=1
fi

# #501 must NOT be edited or commented — it's not aidevops-shaped
if [[ "$edit_501" -ne 0 ]]; then
	printf 'FAIL: #501 should not be edited (non-aidevops shape), got %d edits\n' "$edit_501"
	failed=1
fi
if [[ "$comment_501" -ne 0 ]]; then
	printf 'FAIL: #501 should not be commented, got %d comments\n' "$comment_501"
	failed=1
fi

# #502 must NOT be edited — it already has origin + tier labels
if [[ "$edit_502" -ne 0 ]]; then
	printf 'FAIL: #502 should not be edited (already blessed), got %d edits\n' "$edit_502"
	failed=1
fi

if [[ "$failed" -eq 0 ]]; then
	printf 'PASS: test-pulse-labelless-reconcile — all assertions green\n'
	exit 0
fi
printf '\nFAIL: test-pulse-labelless-reconcile — see diagnostics above\n'
printf '\n--- gh trace ---\n'
cat "$TRACE_FILE"
printf '\n--- cmd out ---\n'
cat "${TEST_TMPDIR}/cmd.out"
exit 1
