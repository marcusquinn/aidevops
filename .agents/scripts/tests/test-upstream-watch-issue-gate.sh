#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#22495:
# - non-maintainer upstream-watch contexts write local reports instead of public
#   issues in marcusquinn/aidevops
# - maintainer-authorized contexts can still create issues
# - large scan batches coalesce into a single tracker issue

set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

PASS=0
FAIL=0

check() {
	local ok="$1"
	local name="$2"
	local detail="${3:-}"
	if [[ "$ok" == "1" ]]; then
		PASS=$((PASS + 1))
		printf 'PASS: %s\n' "$name"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL: %s\n' "$name"
		[[ -n "$detail" ]] && printf '      %s\n' "$detail"
	fi
	return 0
}

TMP="$(mktemp -d -t upstream-watch-gate.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

export HOME="${TMP}/home"
mkdir -p "${HOME}/.config/aidevops" "${HOME}/.aidevops/reports/upstream-watch"
cat >"${HOME}/.config/aidevops/repos.json" <<'JSON'
{
  "initialized_repos": [
    {"is_framework_dir": true, "slug": "marcusquinn/aidevops"}
  ]
}
JSON

export SCRIPT_DIR="$SCRIPTS_DIR"
export UPSTREAM_WATCH_LABEL="source:upstream-watch"
export YELLOW="" BLUE="" GREEN="" NC=""

GH_CREATE_CALLS="${TMP}/gh_create_calls.log"
GH_EDIT_CALLS="${TMP}/gh_edit_calls.log"
GH_ISSUE_LIST_CALLS="${TMP}/gh_issue_list_calls.log"
GH_WARNINGS="${TMP}/warnings.log"
: >"$GH_CREATE_CALLS"
: >"$GH_EDIT_CALLS"
: >"$GH_ISSUE_LIST_CALLS"
: >"$GH_WARNINGS"

_log_warn() { printf '%s\n' "$*" >>"$GH_WARNINGS"; return 0; }
_log_info() { return 0; }

gh() {
	if [[ "$1" == "auth" && "${2:-}" == "status" ]]; then
		return 0
	fi
	if [[ "$1" == "api" && "${2:-}" == "user" ]]; then
		printf 'test-login\n'
		return 0
	fi
	if [[ "$1" == "api" && "${2:-}" == repos/*/collaborators/*/permission ]]; then
		printf '%s\n' "${GH_PERMISSION:-read}"
		return 0
	fi
	if [[ "$1" == "issue" && "${2:-}" == "list" ]]; then
		printf '%s\n' "$*" >>"$GH_ISSUE_LIST_CALLS"
		return 0
	fi
	return 0
}

gh_create_issue() {
	printf '%s\n' "$*" >>"$GH_CREATE_CALLS"
	printf 'https://github.com/marcusquinn/aidevops/issues/9999\n'
	return 0
}

gh_issue_edit_safe() {
	printf '%s\n' "$*" >>"$GH_EDIT_CALLS"
	return 0
}

export -f _log_warn _log_info gh gh_create_issue gh_issue_edit_safe

# shellcheck source=../upstream-watch-helper-issues.sh
source "${SCRIPTS_DIR}/upstream-watch-helper-issues.sh"

entry_json='{"slug":"owner/repo","relevance":"test relevance","affects":[".agents/example.md"]}'

# Test 1: non-maintainer individual update writes local report and creates no issue.
export GH_PERMISSION="read"
: >"$GH_CREATE_CALLS"
_file_upstream_update_issue "owner/repo" "release" "v1" "v2" "$entry_json" >/dev/null
create_count=$(grep -c '^--repo ' "$GH_CREATE_CALLS" 2>/dev/null || true)
report_count=$(find "${HOME}/.aidevops/reports/upstream-watch" -type f | wc -l | tr -d '[:space:]')
[[ "$create_count" == "0" && "$report_count" == "1" ]] && ok=1 || ok=0
check "$ok" "non-maintainer writes local report instead of public issue" "create_count=${create_count} report_count=${report_count}"

# Test 2: maintainer-authorized individual update can create a public issue.
export GH_PERMISSION="write"
: >"$GH_CREATE_CALLS"
_file_upstream_update_issue "owner/repo" "release" "v2" "v3" "$entry_json" >/dev/null
create_count=$(grep -c '^--repo ' "$GH_CREATE_CALLS" 2>/dev/null || true)
[[ "$create_count" == "1" ]] && ok=1 || ok=0
check "$ok" "authorized context creates upstream-watch issue" "create_count=${create_count}"

# Test 3: five queued updates coalesce into one batch issue.
export GH_PERMISSION="write"
: >"$GH_CREATE_CALLS"
queue_file="${TMP}/queue.ndjson"
: >"$queue_file"
_UPSTREAM_WATCH_ISSUE_QUEUE_FILE="$queue_file"
for index in 1 2 3 4 5; do
	_queue_upstream_update_issue "owner/repo-${index}" "commit" "old${index}" "new${index}" "$entry_json"
done
unset _UPSTREAM_WATCH_ISSUE_QUEUE_FILE
_flush_upstream_update_issue_queue "$queue_file" >/dev/null
create_count=$(grep -c '^--repo ' "$GH_CREATE_CALLS" 2>/dev/null || true)
if [[ "$create_count" == "1" ]] && grep -q 'upstream: batch review adoption' "$GH_CREATE_CALLS"; then
	ok=1
else
	ok=0
fi
check "$ok" "five queued updates coalesce into one batch issue" "create_count=${create_count}"

# Test 4: unauthorized batch writes another local report and creates no issue.
export GH_PERMISSION="read"
: >"$GH_CREATE_CALLS"
before_reports=$(find "${HOME}/.aidevops/reports/upstream-watch" -type f | wc -l | tr -d '[:space:]')
queue_file_unauth="${TMP}/queue-unauth.ndjson"
: >"$queue_file_unauth"
_UPSTREAM_WATCH_ISSUE_QUEUE_FILE="$queue_file_unauth"
for index in 1 2 3 4 5; do
	_queue_upstream_update_issue "owner/unauth-${index}" "commit" "old${index}" "new${index}" "$entry_json"
done
unset _UPSTREAM_WATCH_ISSUE_QUEUE_FILE
_flush_upstream_update_issue_queue "$queue_file_unauth" >/dev/null
create_count=$(grep -c '^--repo ' "$GH_CREATE_CALLS" 2>/dev/null || true)
after_reports=$(find "${HOME}/.aidevops/reports/upstream-watch" -type f | wc -l | tr -d '[:space:]')
if [[ "$create_count" == "0" && "$after_reports" -gt "$before_reports" ]]; then
	ok=1
else
	ok=0
fi
check "$ok" "unauthorized batch writes local report without public issue" "create_count=${create_count} reports=${before_reports}->${after_reports}"

# Test 5: issue discovery uses gh's supported --limit flag, not unsupported --paginate.
if grep -q -- '--paginate' "$GH_ISSUE_LIST_CALLS"; then
	ok=0
else
	ok=1
fi
check "$ok" "upstream-watch issue list avoids unsupported gh --paginate flag" "calls=$(wc -l <"$GH_ISSUE_LIST_CALLS" | tr -d '[:space:]')"

if [[ "$FAIL" -gt 0 ]]; then
	printf '%s test(s) failed, %s passed\n' "$FAIL" "$PASS" >&2
	exit 1
fi

printf '%s test(s) passed\n' "$PASS"
