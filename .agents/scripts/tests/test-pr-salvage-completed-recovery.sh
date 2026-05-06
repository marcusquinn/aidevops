#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local message="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$message"
	return 0
}

fail() {
	local message="$1"
	local details="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$message"
	[[ -n "$details" ]] && printf '     %s\n' "$details"
	return 0
}

gh() {
	local area="${1:-}"
	local command="${2:-}"
	shift 2 || true

	if [[ "$area" == "pr" && "$command" == "list" ]]; then
		local args=" $* "
		if [[ "$args" == *" --state closed "* ]]; then
			cat <<'JSON'
[
  {
    "number": 53,
    "title": "Add buffalo logo favicon",
    "headRefName": "buffalo-logo-favicon",
    "closedAt": "2026-05-01T00:00:00Z",
    "mergedAt": null,
    "additions": 7,
    "deletions": 0,
    "author": {"login": "contributor"},
    "labels": []
  },
  {
    "number": 54,
    "title": "Add recoverable feature",
    "headRefName": "recoverable-feature",
    "closedAt": "2026-05-02T00:00:00Z",
    "mergedAt": null,
    "additions": 120,
    "deletions": 1,
    "author": {"login": "contributor"},
    "labels": []
  }
]
JSON
			return 0
		fi
		if [[ "$args" == *" --state open "* ]]; then
			printf '0\n'
			return 0
		fi
		printf '[]\n'
		return 0
	fi

	if [[ "$area" == "issue" && "$command" == "list" ]]; then
		local args=" $* "
		if [[ "$args" == *'"PR #53"'* ]]; then
			cat <<'JSON'
[
  {
    "number": 60,
    "title": "Recover buffalo logo favicon from closed PR #53",
    "body": "Worker completion audit trail: completed recovery.",
    "state": "CLOSED",
    "closedAt": "2026-05-03T00:00:00Z"
  }
]
JSON
			return 0
		fi
		printf '[]\n'
		return 0
	fi

	if [[ "$area" == "api" ]]; then
		printf '{"name":"%s"}\n' "${1##*/}"
		return 0
	fi

	return 1
}
export -f gh

# shellcheck source=../pr-salvage-helper.sh
source "${SCRIPTS_DIR}/pr-salvage-helper.sh" >/dev/null 2>&1 || {
	printf 'FATAL Could not source pr-salvage-helper.sh\n'
	exit 1
}

results=$(scan_repo "owner/repo" 7)
if printf '%s' "$results" | jq -e 'length == 1 and .[0].number == 54' >/dev/null; then
	pass "completed recovery issue suppresses matching closed PR"
else
	fail "completed recovery issue suppresses matching closed PR" "$results"
fi

prefetch_output=$(cmd_prefetch "owner/repo" "/tmp/repo")
if ! printf '%s' "$prefetch_output" | grep -q 'PR #53' \
	&& printf '%s' "$prefetch_output" | grep -q 'PR #54'; then
	pass "prefetch omits already completed recovery PRs"
else
	fail "prefetch omits already completed recovery PRs" "$prefetch_output"
fi

printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf 'All %d tests passed\n' "$TESTS_RUN"
	exit 0
fi
printf '%d / %d tests failed\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
