#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#33680: a trusted closeout comment naming a merged replacement PR
# suppresses the salvage finding; external comments, unreadable comments and
# open, closed-unmerged or missing replacements do not.

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

# Closed-unmerged source PRs 70-75, each with additions to salvage.
_fixture_closed_prs() {
	jq -n '[range(70; 76) | {
		number: ., title: "Dependency update \(.)", headRefName: "deps-\(.)",
		closedAt: "2026-10-01T00:00:00Z", mergedAt: null, additions: 12,
		deletions: 1, author: {login: "contributor"}, labels: []
	}]'
	return 0
}

# Comments per source PR. 70: trusted owner names merged #80. 71: external
# author names merged #80. 72/73/74: trusted owner names open #81, closed
# unmerged #82, missing #83. 75: comments endpoint fails.
_fixture_comments() {
	local pr="$1"
	case "$pr" in
	70) printf '[{"author_association":"OWNER","body":"Closing: superseded by exact-tree replacement #80."}]' ;;
	71) printf '[{"author_association":"NONE","body":"This was replaced by #80, please close."}]' ;;
	72) printf '[{"author_association":"MEMBER","body":"Replaced by #81."}]' ;;
	73) printf '[{"author_association":"OWNER","body":"Superseded by #82."}]' ;;
	74) printf '[{"author_association":"OWNER","body":"Landed in #83."}]' ;;
	75) return 1 ;;
	*) printf '[]' ;;
	esac
	return 0
}

_fixture_pull() {
	local pr="$1"
	case "$pr" in
	80) printf '{"number":80,"merged_at":"2026-10-02T00:00:00Z"}' ;;
	81 | 82) printf '{"number":%s,"merged_at":null}' "$pr" ;;
	*) return 1 ;;
	esac
	return 0
}

gh() {
	local area="${1:-}"
	local command="${2:-}"
	local args=" $* " path="" jq_expr="" json="" arg="" take_jq=0

	if [[ "$area" == "pr" && "$command" == "list" ]]; then
		if [[ "$args" == *" --state closed "* ]]; then
			_fixture_closed_prs
			return 0
		fi
		[[ "$args" == *" --state open "* ]] && printf '0\n' && return 0
		printf '[]\n'
		return 0
	fi
	if [[ "$area" == "issue" && "$command" == "list" ]]; then
		printf '[]\n'
		return 0
	fi
	if [[ "$area" == "api" ]]; then
		shift
		for arg in "$@"; do
			if [[ "$take_jq" -eq 1 ]]; then
				jq_expr="$arg"
				take_jq=0
			elif [[ "$arg" == "--jq" ]]; then
				take_jq=1
			elif [[ "$arg" == repos/* ]]; then
				path="$arg"
			fi
		done
		case "$path" in
		*/issues/*/comments*)
			path="${path%/comments*}"
			json=$(_fixture_comments "${path##*/}") || return 1
			;;
		*/pulls/*) json=$(_fixture_pull "${path##*/}") || return 1 ;;
		*/branches/*)
			printf '%s\n' "${path##*/}"
			return 0
			;;
		*) json='{}' ;;
		esac
		if [[ -n "$jq_expr" ]]; then
			printf '%s' "$json" | jq -r "$jq_expr"
		else
			printf '%s\n' "$json"
		fi
		return 0
	fi
	return 1
}
export -f gh _fixture_closed_prs _fixture_comments _fixture_pull

# shellcheck source=../pr-salvage-helper.sh
source "${SCRIPTS_DIR}/pr-salvage-helper.sh" >/dev/null 2>&1 || {
	printf 'FATAL Could not source pr-salvage-helper.sh\n'
	exit 1
}

results=$(scan_repo "owner/repo" 7)
reported=$(printf '%s' "$results" | jq -c '[.[].number] | sort' 2>/dev/null)

if [[ "$reported" == "[71,72,73,74,75]" ]]; then
	pass "trusted closeout naming a merged replacement suppresses salvage"
else
	fail "trusted closeout naming a merged replacement suppresses salvage" "$reported"
fi
if [[ "$reported" == *"71"* ]]; then
	pass "external comment naming a merged PR does not suppress salvage"
else
	fail "external comment naming a merged PR does not suppress salvage" "$reported"
fi
if [[ "$reported" == *"72"* && "$reported" == *"73"* && "$reported" == *"74"* ]]; then
	pass "open, closed-unmerged and missing replacements do not suppress salvage"
else
	fail "open, closed-unmerged and missing replacements do not suppress salvage" "$reported"
fi
if [[ "$reported" == *"75"* ]]; then
	pass "unreadable closeout comments do not suppress salvage"
else
	fail "unreadable closeout comments do not suppress salvage" "$reported"
fi

printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf 'All %d tests passed\n' "$TESTS_RUN"
	exit 0
fi
printf '%d / %d tests failed\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
