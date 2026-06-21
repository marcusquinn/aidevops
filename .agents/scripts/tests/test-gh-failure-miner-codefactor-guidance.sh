#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#25329: gh-failure-miner CodeFactor clusters must
# render worker-ready guidance instead of generic workflow/toolchain advice.

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

assert_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  expected to find: %s\n' "$(printf '%q' "$needle")"
		printf '  in output:        %s\n' "$(printf '%q' "${haystack:0:300}")"
	fi
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
HELPER="$SCRIPT_DIR/gh-failure-miner-helper.sh"

if [[ ! -f "$HELPER" ]]; then
	printf '%sFATAL%s: %s not found\n' "$TEST_RED" "$TEST_NC" "$HELPER" >&2
	exit 1
fi

# Source with a harmless command so helper functions remain available without
# making live GitHub API calls.
set -- help
# shellcheck source=/dev/null
source "$HELPER" >/dev/null

cluster_json=$(cat <<'JSON'
{
  "repo": "marcusquinn/aidevops",
  "check_name": "CodeFactor",
  "signature": "failure:codefactor.io",
  "count": 3,
  "is_infra": false,
  "sources": ["pr:#25324", "pr:#25319", "pr:#25305"],
  "examples": [
    {
      "source_kind": "pr",
      "source_ref": "#25324",
      "source_url": "https://github.com/marcusquinn/aidevops/pull/25324",
      "run_url": "https://github.com/marcusquinn/aidevops/runs/82536587204",
      "details_url": "https://www.codefactor.io/repository/github/marcusquinn/aidevops/pull/25324",
      "conclusion": "failure"
    }
  ]
}
JSON
)

events_json=$(printf '[%s]\n' "$cluster_json")

body=$(build_issue_body "$cluster_json" "46250abc5695" "2" "false")
legacy_body=$(render_issue_body_markdown "$events_json" "2")

assert_contains "build_issue_body includes Worker Guidance" "## Worker Guidance" "$body"
assert_contains "build_issue_body directs workers to CodeFactor details" "Open the CodeFactor details URL from Evidence first" "$body"
assert_contains "build_issue_body preserves failure signature context" "failure:codefactor.io" "$body"
assert_contains "build_issue_body asks for focused regression guard" "focused regression guard" "$body"
assert_contains "render_issue_body_markdown includes Worker Guidance" "## Worker Guidance" "$legacy_body"
assert_contains "render_issue_body_markdown directs workers to provider details" "details URL" "$legacy_body"

printf '\nTests run: %s\n' "$TESTS_RUN"
if [[ "$TESTS_FAILED" -ne 0 ]]; then
	printf 'Tests failed: %s\n' "$TESTS_FAILED" >&2
	exit 1
fi

printf '%sAll tests passed%s\n' "$TEST_GREEN" "$TEST_NC"
exit 0
