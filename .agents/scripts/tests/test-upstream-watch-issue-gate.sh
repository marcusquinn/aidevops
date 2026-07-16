#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#22495 and GH#27821: owner-only publication,
# exact-value repository-history deduplication, and post-filter batching.

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
GH_CLOSE_CALLS="${TMP}/gh_close_calls.log"
GH_ISSUE_LIST_CALLS="${TMP}/gh_issue_list_calls.log"
GH_WARNINGS="${TMP}/warnings.log"
: >"$GH_CREATE_CALLS"
: >"$GH_EDIT_CALLS"
: >"$GH_CLOSE_CALLS"
: >"$GH_ISSUE_LIST_CALLS"
: >"$GH_WARNINGS"

_log_warn() { printf '%s\n' "$*" >>"$GH_WARNINGS"; return 0; }
_log_info() { return 0; }

gh() {
	local command_name="${1:-}"
	local subcommand="${2:-}"
	if [[ "$command_name" == "auth" && "$subcommand" == "status" ]]; then
		return 0
	fi
	if [[ "$command_name" == "api" && "$subcommand" == "user" ]]; then
		printf '%s\n' "${GH_LOGIN:-test-login}"
		return 0
	fi
	if [[ "$command_name" == "api" && "$subcommand" == "-i" && "${3:-}" == */collaborators/*/permission ]]; then
		printf 'HTTP/2.0 200 OK\n\n{"permission":"%s"}\n' "${GH_PERMISSION:-read}"
		return 0
	fi
	if [[ "$command_name" == "api" && ( "$subcommand" == repos/*/collaborators/*/permission || "$subcommand" == /repos/*/collaborators/*/permission ) ]]; then
		printf '%s\n' "${GH_PERMISSION:-read}"
		return 0
	fi
	if [[ "$command_name" == "issue" && "$subcommand" == "list" ]]; then
		printf '%s\n' "$*" >>"$GH_ISSUE_LIST_CALLS"
		if [[ " $* " == *" --state all "* ]]; then
			[[ "${GH_HISTORY_FAIL:-0}" == "1" ]] && return 1
			printf '%s\n' "${GH_HISTORY_JSON:-[]}"
		else
			printf '%s\n' "${GH_OPEN_NUMBER:-}"
		fi
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

gh_issue_close_safe() {
	printf '%s\n' "$*" >>"$GH_CLOSE_CALLS"
	return 0
}

export -f _log_warn _log_info gh gh_create_issue gh_issue_edit_safe gh_issue_close_safe

# shellcheck source=../upstream-watch-helper-issues.sh
source "${SCRIPTS_DIR}/upstream-watch-helper-issues.sh"

entry_json='{"slug":"owner/repo","relevance":"test relevance","affects":[".agents/example.md"]}'

# Test 1: a write-capable non-owner still writes locally by default.
export GH_LOGIN="collaborator"
export GH_PERMISSION="write"
export GH_HISTORY_JSON='[]'
export GH_HISTORY_FAIL=0
: >"$GH_CREATE_CALLS"
_file_upstream_update_issue "owner/repo" "release" "v1" "v2" "$entry_json" >/dev/null
create_count=$(grep -c '^--repo ' "$GH_CREATE_CALLS" 2>/dev/null || true)
report_count=$(find "${HOME}/.aidevops/reports/upstream-watch" -type f | wc -l | tr -d '[:space:]')
[[ "$create_count" == "0" && "$report_count" == "1" ]] && ok=1 || ok=0
check "$ok" "write collaborator writes local report instead of public issue" "create_count=${create_count} report_count=${report_count}"

# Test 2: repository owner can create a genuinely new issue.
export GH_LOGIN="marcusquinn"
: >"$GH_CREATE_CALLS"
_file_upstream_update_issue "owner/repo" "release" "v2" "v3" "$entry_json" >/dev/null
create_count=$(grep -c '^--repo ' "$GH_CREATE_CALLS" 2>/dev/null || true)
[[ "$create_count" == "1" ]] && ok=1 || ok=0
check "$ok" "repository owner creates upstream-watch issue" "create_count=${create_count}"

# Test 3: explicit designated-publisher override authorizes a non-owner.
export GH_LOGIN="designated-publisher"
export AIDEVOPS_UPSTREAM_WATCH_ALLOW_PUBLIC_ISSUES=1
: >"$GH_CREATE_CALLS"
_file_upstream_update_issue "owner/repo" "release" "v3" "v4" "$entry_json" >/dev/null
unset AIDEVOPS_UPSTREAM_WATCH_ALLOW_PUBLIC_ISSUES
create_count=$(grep -c '^--repo ' "$GH_CREATE_CALLS" 2>/dev/null || true)
[[ "$create_count" == "1" ]] && ok=1 || ok=0
check "$ok" "designated publisher override creates upstream-watch issue" "create_count=${create_count}"

# Test 4: exact legacy title in open/closed history suppresses recreation.
export GH_LOGIN="marcusquinn"
export GH_HISTORY_JSON='[{"number":42,"title":"upstream: owner/repo release -> v5 (review adoption)","body":"legacy issue"}]'
: >"$GH_CREATE_CALLS"
_file_upstream_update_issue "owner/repo" "release" "v4" "v5" "$entry_json" >/dev/null
create_count=$(grep -c '^--repo ' "$GH_CREATE_CALLS" 2>/dev/null || true)
[[ "$create_count" == "0" ]] && ok=1 || ok=0
check "$ok" "exact legacy history title suppresses recreation" "create_count=${create_count}"

# Test 5: a different full value sharing the same displayed prefix still publishes.
handled_value="123456789012-old"
changed_value="123456789012-new"
handled_key=$(_upstream_watch_update_key "owner/repo" "commit" "$handled_value")
export GH_HISTORY_JSON="[{\"number\":43,\"title\":\"old tracker\",\"body\":\"<!-- upstream-watch:update-key=${handled_key} -->\"}]"
: >"$GH_CREATE_CALLS"
_file_upstream_update_issue "owner/repo" "commit" "previous" "$changed_value" "$entry_json" >/dev/null
create_count=$(grep -c '^--repo ' "$GH_CREATE_CALLS" 2>/dev/null || true)
[[ "$create_count" == "1" ]] && ok=1 || ok=0
check "$ok" "changed full value with same title prefix still publishes" "create_count=${create_count}"

# Test 6: history API failure fails closed into a local report.
export GH_HISTORY_FAIL=1
export GH_HISTORY_JSON='[]'
: >"$GH_CREATE_CALLS"
before_reports=$(find "${HOME}/.aidevops/reports/upstream-watch" -type f | wc -l | tr -d '[:space:]')
_file_upstream_update_issue "owner/repo" "release" "v5" "v6" "$entry_json" >/dev/null
after_reports=$(find "${HOME}/.aidevops/reports/upstream-watch" -type f | wc -l | tr -d '[:space:]')
create_count=$(grep -c '^--repo ' "$GH_CREATE_CALLS" 2>/dev/null || true)
[[ "$create_count" == "0" && "$after_reports" -gt "$before_reports" ]] && ok=1 || ok=0
check "$ok" "history lookup failure writes local report" "create_count=${create_count} reports=${before_reports}->${after_reports}"
export GH_HISTORY_FAIL=0

# Test 7: five genuinely new queued updates coalesce into one batch issue.
export GH_HISTORY_JSON='[]'
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
check "$ok" "five new queued updates coalesce into one batch issue" "create_count=${create_count}"

# Test 8: handled values are removed before threshold calculation.
export GH_HISTORY_JSON='[
 {"number":51,"title":"upstream: owner/filtered-1 commit -> new1 (review adoption)","body":""},
 {"number":52,"title":"upstream: owner/filtered-2 commit -> new2 (review adoption)","body":""}
]'
: >"$GH_CREATE_CALLS"
queue_filtered="${TMP}/queue-filtered.ndjson"
: >"$queue_filtered"
_UPSTREAM_WATCH_ISSUE_QUEUE_FILE="$queue_filtered"
for index in 1 2 3 4 5; do
	_queue_upstream_update_issue "owner/filtered-${index}" "commit" "old${index}" "new${index}" "$entry_json"
done
unset _UPSTREAM_WATCH_ISSUE_QUEUE_FILE
_flush_upstream_update_issue_queue "$queue_filtered" >/dev/null
create_count=$(grep -c '^--repo ' "$GH_CREATE_CALLS" 2>/dev/null || true)
if [[ "$create_count" == "3" ]] && ! grep -q 'upstream: batch review adoption' "$GH_CREATE_CALLS"; then ok=1; else ok=0; fi
check "$ok" "batch threshold applies after handled-value filtering" "create_count=${create_count}"

# Test 9: an entirely handled queue creates nothing.
export GH_HISTORY_JSON='[
 {"number":61,"title":"upstream: owner/done-1 release -> v2 (review adoption)","body":""},
 {"number":62,"title":"upstream: owner/done-2 release -> v2 (review adoption)","body":""}
]'
: >"$GH_CREATE_CALLS"
queue_done="${TMP}/queue-done.ndjson"
: >"$queue_done"
_UPSTREAM_WATCH_ISSUE_QUEUE_FILE="$queue_done"
_queue_upstream_update_issue "owner/done-1" "release" "v1" "v2" "$entry_json"
_queue_upstream_update_issue "owner/done-2" "release" "v1" "v2" "$entry_json"
unset _UPSTREAM_WATCH_ISSUE_QUEUE_FILE
_flush_upstream_update_issue_queue "$queue_done" >/dev/null
create_count=$(grep -c '^--repo ' "$GH_CREATE_CALLS" 2>/dev/null || true)
[[ "$create_count" == "0" && ! -s "$queue_done" ]] && ok=1 || ok=0
check "$ok" "entirely handled queue creates nothing" "create_count=${create_count}"

# Test 10: concurrent exact-key creation closes the higher-number duplicate.
race_key=$(_upstream_watch_update_key "owner/race" "release" "v9")
export GH_HISTORY_JSON="[
 {\"number\":70,\"title\":\"canonical\",\"body\":\"<!-- upstream-watch:update-key=${race_key} -->\"},
 {\"number\":71,\"title\":\"duplicate\",\"body\":\"<!-- upstream-watch:update-key=${race_key} -->\"}
]"
: >"$GH_CLOSE_CALLS"
_reconcile_upstream_update_issue "marcusquinn/aidevops" "owner/race" "release" "v9" "71"
close_count=$(grep -c '^71 --repo marcusquinn/aidevops --reason completed' "$GH_CLOSE_CALLS" 2>/dev/null || true)
[[ "$close_count" == "1" ]] && ok=1 || ok=0
check "$ok" "concurrent duplicate reconciliation closes newer tracker" "close_count=${close_count}"

# Test 11: issue discovery uses supported --state all/--limit, not --paginate.
if grep -q -- '--paginate' "$GH_ISSUE_LIST_CALLS"; then
	ok=0
else
	ok=1
fi
if ! grep -q -- '--state all' "$GH_ISSUE_LIST_CALLS"; then ok=0; fi
check "$ok" "upstream-watch history uses --state all without --paginate" "calls=$(wc -l <"$GH_ISSUE_LIST_CALLS" | tr -d '[:space:]')"

if [[ "$FAIL" -gt 0 ]]; then
	printf '%s test(s) failed, %s passed\n' "$FAIL" "$PASS" >&2
	exit 1
fi

printf '%s test(s) passed\n' "$PASS"
