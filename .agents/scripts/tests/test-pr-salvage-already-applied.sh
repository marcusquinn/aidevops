#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#35799: a closed-unmerged PR whose whole diff is already present at one
# pinned default-branch commit is not a salvage candidate. Absent, newer,
# unreadable, renamed and trivial-only diffs remain candidates.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0
PINNED_SHA="0123456789abcdef0123456789abcdef01234567"

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

# Closed-unmerged dependency-bump PRs 90-96 with deleted branches.
_fixture_closed_prs() {
	jq -n '[range(90; 97) | {
		number: ., title: "Bump react \(.)", headRefName: "dependabot/react-\(.)",
		closedAt: "2026-10-27T00:00:00Z", mergedAt: null, additions: 1,
		deletions: 1, author: {login: "app/dependabot"}, labels: []
	}]'
	return 0
}

# 90: target present (suppress). 91: target absent. 92: main is newer.
# 93: files API fails. 94: renamed file. 95: trivial lines only.
# 96: contents API fails.
_fixture_files() {
	local pr="$1"
	local bump='@@ -1,3 +1,3 @@\n {\n-  \"react\": \"19.3.0\",\n+  \"react\": \"19.3.1\",\n }'
	case "$pr" in
	90 | 91 | 92 | 96) printf '[{"filename":"pkg%s/package.json","status":"modified","patch":"%s"}]' "$pr" "$bump" ;;
	93) return 1 ;;
	94) printf '[{"filename":"pkg94/package.json","status":"renamed","patch":"%s"}]' "$bump" ;;
	95) printf '[{"filename":"pkg95/package.json","status":"modified","patch":"@@ -1 +1 @@\\n-{\\n+}"}]' ;;
	*) return 1 ;;
	esac
	return 0
}

_fixture_content() {
	local path="$1"
	case "$path" in
	pkg90/package.json | pkg94/package.json) printf '{\n  "react": "19.3.1",\n}\n' ;;
	pkg91/package.json) printf '{\n  "react": "19.3.0",\n}\n' ;;
	pkg92/package.json) printf '{\n  "react": "19.3.2",\n}\n' ;;
	pkg95/package.json) printf '}\n' ;;
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
	[[ "$area" == "api" ]] || return 1
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
	*/contents/*)
		[[ "$path" == *"?ref=${PINNED_SHA}" ]] || return 1
		path="${path#*/contents/}"
		_fixture_content "${path%%\?*}"
		return $?
		;;
	*/pulls/*/files*)
		path="${path%/files*}"
		json=$(_fixture_files "${path##*/}") || return 1
		;;
	*/issues/*/comments*) json='[]' ;;
	*/commits/main) json="{\"sha\":\"${PINNED_SHA}\"}" ;;
	*/branches/*) return 1 ;;
	repos/owner/repo) json='{"default_branch":"main"}' ;;
	*) json='{}' ;;
	esac
	if [[ -n "$jq_expr" ]]; then
		printf '%s' "$json" | jq -r "$jq_expr"
	else
		printf '%s\n' "$json"
	fi
	return 0
}
export -f gh _fixture_closed_prs _fixture_files _fixture_content
export PINNED_SHA

# shellcheck source=../pr-salvage-helper.sh
source "${SCRIPTS_DIR}/pr-salvage-helper.sh" >/dev/null 2>&1 || {
	printf 'FATAL Could not source pr-salvage-helper.sh\n'
	exit 1
}

results=$(scan_repo "owner/repo" 7 2>/dev/null)
reported=$(printf '%s' "$results" | jq -c '[.[].number] | sort' 2>/dev/null)

if [[ "$reported" == "[91,92,93,94,95,96]" ]]; then
	pass "deleted-branch PR with target already present is suppressed"
else
	fail "deleted-branch PR with target already present is suppressed" "$reported"
fi
if [[ "$reported" == *"91"* && "$reported" == *"92"* ]]; then
	pass "absent or newer target on the pinned revision is retained"
else
	fail "absent or newer target on the pinned revision is retained" "$reported"
fi
if [[ "$reported" == *"93"* && "$reported" == *"96"* ]]; then
	pass "files or contents API failure is retained"
else
	fail "files or contents API failure is retained" "$reported"
fi
if [[ "$reported" == *"94"* && "$reported" == *"95"* ]]; then
	pass "renamed file and trivial-only diffs are retained"
else
	fail "renamed file and trivial-only diffs are retained" "$reported"
fi
if [[ "$(pr_diff_already_applied "owner/repo" 90 "")" == "false" ]]; then
	pass "unresolved pinned revision never suppresses"
else
	fail "unresolved pinned revision never suppresses"
fi

printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf 'All %d tests passed\n' "$TESTS_RUN"
	exit 0
fi
printf '%d / %d tests failed\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
