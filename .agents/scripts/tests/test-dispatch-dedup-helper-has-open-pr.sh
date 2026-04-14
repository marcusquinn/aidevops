#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SCRIPT="${SCRIPT_DIR}/../dispatch-dedup-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""
GH_FIXTURE_FILE=""
GH_PR_VIEW_FIXTURE_FILE=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# GH#18644: extracted from setup_test_env so the latter stays under the
# 100-line function complexity gate. The stub handles `gh pr list` (by
# repo/state/search key) and `gh pr view` (by PR number + json field).
_write_gh_stub() {
	local stub_path="$1"
	cat >"$stub_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# gh pr list — returns fixture JSON for (repo, state, search) lookup.
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
	local_repo=""
	local_state=""
	local_search=""
	shift 2
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo) local_repo="${2:-}"; shift 2 ;;
		--state) local_state="${2:-}"; shift 2 ;;
		--search) local_search="${2:-}"; shift 2 ;;
		*) shift ;;
		esac
	done
	if [[ -z "$local_repo" || -z "$local_state" || -z "$local_search" ]]; then
		printf '[]\n'
		exit 0
	fi
	compound_key="${local_repo}|${local_state}|${local_search}"
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		fixture_key="${line%|*}"
		fixture_payload="${line##*|}"
		if [[ "$fixture_key" == "$compound_key" ]]; then
			printf '%s\n' "$fixture_payload"
			exit 0
		fi
	done <"${GH_FIXTURE_FILE}"
	printf '[]\n'
	exit 0
fi

# gh pr view <number> --repo R --json body|title --jq '.body|.title'
# Fixture line format: "<pr_number>|<field>|<payload>". Payload may
# contain '|' — we split on the first two delimiters only.
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
	pr_num="${3:-}"
	field=""
	shift 3 2>/dev/null || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json) field="${2:-}"; shift 2 ;;
		--jq) shift 2 ;;
		--repo) shift 2 ;;
		*) shift ;;
		esac
	done
	[[ -z "$pr_num" || -z "$field" ]] && exit 1
	if [[ -f "${GH_PR_VIEW_FIXTURE_FILE}" ]]; then
		while IFS= read -r line; do
			[[ -n "$line" ]] || continue
			fixture_pr="${line%%|*}"
			rest="${line#*|}"
			fixture_field="${rest%%|*}"
			fixture_payload="${rest#*|}"
			if [[ "$fixture_pr" == "$pr_num" && "$fixture_field" == "$field" ]]; then
				printf '%s\n' "$fixture_payload"
				exit 0
			fi
		done <"${GH_PR_VIEW_FIXTURE_FILE}"
	fi
	printf '\n'
	exit 0
fi

printf 'unsupported gh invocation in test stub: %s\n' "$*" >&2
exit 1
EOF
	chmod +x "$stub_path"
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	GH_FIXTURE_FILE="${TEST_ROOT}/gh-pr-list-fixtures.txt"
	GH_PR_VIEW_FIXTURE_FILE="${TEST_ROOT}/gh-pr-view-fixtures.txt"

	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export GH_FIXTURE_FILE
	export GH_PR_VIEW_FIXTURE_FILE

	_write_gh_stub "${TEST_ROOT}/bin/gh"

	printf '' >"${GH_FIXTURE_FILE}"
	printf '' >"${GH_PR_VIEW_FIXTURE_FILE}"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

set_gh_fixtures() {
	local fixtures="$1"
	printf '%s\n' "$fixtures" >"${GH_FIXTURE_FILE}"
	return 0
}

set_gh_pr_view_fixtures() {
	local fixtures="$1"
	printf '%s\n' "$fixtures" >"${GH_PR_VIEW_FIXTURE_FILE}"
	return 0
}

test_has_open_pr_detects_closing_keyword() {
	set_gh_fixtures 'marcusquinn/aidevops|merged|closes #4527 in:body|[{"number":1145}]'
	# Check 2 (body search) requires the PR body to contain a real closing
	# keyword for the target issue — the helper re-fetches the body and
	# post-filters with a regex to avoid GitHub full-text false positives.
	set_gh_pr_view_fixtures '1145|body|Closes #4527. Implements the fix.'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 4527 marcusquinn/aidevops 't4527: prevent duplicate dispatch'); then
		case "$output" in
		*'merged PR #1145 references issue #4527 via "closes" keyword'*)
			print_result "has-open-pr detects merged PR via closing keyword" 0
			return 0
			;;
		esac
		print_result "has-open-pr detects merged PR via closing keyword" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "has-open-pr detects merged PR via closing keyword" 1 "Expected merged PR evidence for issue #4527"
	return 0
}

test_has_open_pr_detects_task_id_fallback() {
	# Check 3 (task-id title match) now requires the merged PR body to
	# contain a closing-keyword reference to our specific issue number.
	# Bare "#NNN" body references are no longer sufficient (GH#18641).
	set_gh_fixtures 'marcusquinn/aidevops|merged|t063.1 in:title|[{"number":1059}]'
	set_gh_pr_view_fixtures '1059|body|Closes #9999. The awardsapp duplicate-dispatch guard.'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 9999 marcusquinn/aidevops 't063.1: fix awardsapp duplicate PR dispatch'); then
		case "$output" in
		*'merged PR #1059 found by task id t063.1 in title'*)
			print_result "has-open-pr detects merged PR via task-id fallback" 0
			return 0
			;;
		esac
		print_result "has-open-pr detects merged PR via task-id fallback" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "has-open-pr detects merged PR via task-id fallback" 1 "Expected merged PR evidence via task-id fallback"
	return 0
}

test_has_open_pr_returns_nonzero_without_match() {
	set_gh_fixtures ''
	set_gh_pr_view_fixtures ''

	if "$HELPER_SCRIPT" has-open-pr 7777 marcusquinn/aidevops 't7777: no merged pr yet'; then
		print_result "has-open-pr returns nonzero when no evidence exists" 1 "Expected nonzero exit when no merged PR evidence exists"
		return 0
	fi

	print_result "has-open-pr returns nonzero when no evidence exists" 0
	return 0
}

# GH#18641: planning-only PR bodies use `For #NNN` instead of `Closes #NNN`
# so the brief PR does NOT auto-close the real implementation issue. Check 3
# must NOT treat `For #NNN` as dispatch-blocking evidence, otherwise every
# brief PR permanently blocks dispatch on its own follow-up issue.
test_has_open_pr_ignores_planning_for_reference() {
	set_gh_fixtures 'marcusquinn/aidevops|merged|t2047 in:title|[{"number":18627}]'
	set_gh_pr_view_fixtures '18627|body|Files the brief for **t2047**. Pure planning, no code changes.

For #18624
For #18599'

	if "$HELPER_SCRIPT" has-open-pr 18624 marcusquinn/aidevops 't2047: task-id collision guard'; then
		print_result "has-open-pr ignores planning-only 'For #NNN' reference" 1 \
			"Expected exit 1: brief PR with 'For #18624' must not block dispatch"
		return 0
	fi

	print_result "has-open-pr ignores planning-only 'For #NNN' reference" 0
	return 0
}

# GH#18641: same convention with `Ref #NNN` phrasing must also be ignored.
test_has_open_pr_ignores_planning_ref_reference() {
	set_gh_fixtures 'marcusquinn/aidevops|merged|t2038 in:title|[{"number":18524}]'
	set_gh_pr_view_fixtures '18524|body|Research brief for t2038.

Ref #18521
Ref #18522'

	if "$HELPER_SCRIPT" has-open-pr 18522 marcusquinn/aidevops 't2038: research branch protection bypass'; then
		print_result "has-open-pr ignores planning-only 'Ref #NNN' reference" 1 \
			"Expected exit 1: research brief with 'Ref #18522' must not block dispatch"
		return 0
	fi

	print_result "has-open-pr ignores planning-only 'Ref #NNN' reference" 0
	return 0
}

# GH#18641: a PR whose body contains BOTH a closing keyword for a different
# issue AND a planning reference for ours must still NOT block dispatch on
# ours — the closing keyword must match OUR issue number specifically.
test_has_open_pr_requires_close_keyword_for_our_issue() {
	set_gh_fixtures 'marcusquinn/aidevops|merged|t2037 in:title|[{"number":18524}]'
	set_gh_pr_view_fixtures '18524|body|Files briefs.

Closes #18521
For #18522'

	if "$HELPER_SCRIPT" has-open-pr 18522 marcusquinn/aidevops 't2037: inline gate refactor'; then
		print_result "has-open-pr requires close keyword for OUR issue, not another" 1 \
			"Expected exit 1: 'Closes #18521' closes a different issue; 'For #18522' is planning-only for ours"
		return 0
	fi

	print_result "has-open-pr requires close keyword for OUR issue, not another" 0
	return 0
}

# t2085: Layer 4 dedup must detect OPEN PRs that put `Resolves #N` in the
# PR body (the framework convention via full-loop-helper.sh commit-and-pr).
# Without this check, the dedup helper is blind to every routine
# implementation PR — Check 1 matches commit subjects + PR title, neither
# of which carries the closing keyword under the framework convention.
# Trigger incident: cross-runner race on issue #18779 → PR #18906.
test_has_open_pr_detects_open_body_closing_keyword() {
	set_gh_fixtures 'marcusquinn/aidevops|open|resolves #18779 in:body|[{"number":18906}]'
	# Single-line body — the test gh stub reads fixtures line-by-line, so
	# multi-line bodies get truncated to the first line. Real PR bodies have
	# the closing keyword somewhere in the body; the post-filter regex
	# does not require it on the first line.
	set_gh_pr_view_fixtures '18906|body|Resolves #18779. Decompose four interconnected opencode plugin files.'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 18779 marcusquinn/aidevops 't2071: decompose opencode plugin cluster'); then
		case "$output" in
		*'open PR #18906 closes issue #18779 via "resolves" keyword in body'*)
			print_result "has-open-pr detects OPEN PR via body closing keyword (t2085)" 0
			return 0
			;;
		esac
		print_result "has-open-pr detects OPEN PR via body closing keyword (t2085)" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "has-open-pr detects OPEN PR via body closing keyword (t2085)" 1 "Expected open PR evidence for issue #18779"
	return 0
}

# t2085: planning-only OPEN PR bodies use `For #N` / `Ref #N` instead of a
# closing keyword. The new open-body check must NOT treat those as evidence,
# matching the existing planning-aware semantics already enforced by
# Check 3 for merged PRs (GH#18641).
test_has_open_pr_ignores_open_body_planning_for_reference() {
	# No keyword-search hits at all — the brief PR body uses "For #18779" not
	# any closing keyword, so the gh search-by-keyword stage finds nothing.
	# Verify that none of the keyword variants produce a positive match.
	set_gh_fixtures ''
	set_gh_pr_view_fixtures ''

	if "$HELPER_SCRIPT" has-open-pr 18779 marcusquinn/aidevops 't2071: planning brief'; then
		print_result "has-open-pr ignores OPEN PR with planning-only 'For #N' (t2085)" 1 \
			"Expected exit 1: a brief PR with only 'For #18779' must not block dispatch"
		return 0
	fi

	print_result "has-open-pr ignores OPEN PR with planning-only 'For #N' (t2085)" 0
	return 0
}

# t2085: a PR whose body contains a closing keyword for a DIFFERENT issue
# but mentions our issue without a closing keyword must NOT block dispatch
# on our issue. The post-filter regex must match OUR issue number
# specifically. (Mirrors GH#18641 semantics for the open-state code path.)
test_has_open_pr_requires_open_close_keyword_for_our_issue() {
	# GitHub full-text search may match the keyword on a PR that closes a
	# different issue. The fixture simulates a hit on the search but a body
	# that closes #18999 instead of #18779. The post-filter must reject it.
	set_gh_fixtures 'marcusquinn/aidevops|open|closes #18779 in:body|[{"number":18950}]'
	set_gh_pr_view_fixtures '18950|body|Closes #18999. This PR is unrelated to #18779; the search just full-text matched.'

	if "$HELPER_SCRIPT" has-open-pr 18779 marcusquinn/aidevops 't2071: opencode decomposition'; then
		print_result "has-open-pr requires open-PR close keyword for OUR issue (t2085)" 1 \
			"Expected exit 1: PR closes #18999, not #18779; full-text search hit must be filtered"
		return 0
	fi

	print_result "has-open-pr requires open-PR close keyword for OUR issue (t2085)" 0
	return 0
}

# Existing collision case (GH#18041 / t1957) must still allow dispatch:
# different task used the same ID, merged PR closes some unrelated issue.
test_has_open_pr_allows_dispatch_on_task_id_collision() {
	set_gh_fixtures 'marcusquinn/aidevops|merged|t500 in:title|[{"number":1200}]'
	set_gh_pr_view_fixtures '1200|body|Closes #555. Unrelated work that reused task ID t500.'

	if "$HELPER_SCRIPT" has-open-pr 9999 marcusquinn/aidevops 't500: different work for issue #9999'; then
		print_result "has-open-pr allows dispatch on task-id collision" 1 \
			"Expected exit 1: merged PR closes a different issue via task-id collision"
		return 0
	fi

	print_result "has-open-pr allows dispatch on task-id collision" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	test_has_open_pr_detects_closing_keyword
	test_has_open_pr_detects_task_id_fallback
	test_has_open_pr_returns_nonzero_without_match
	test_has_open_pr_ignores_planning_for_reference
	test_has_open_pr_ignores_planning_ref_reference
	test_has_open_pr_requires_close_keyword_for_our_issue
	test_has_open_pr_allows_dispatch_on_task_id_collision
	test_has_open_pr_detects_open_body_closing_keyword
	test_has_open_pr_ignores_open_body_planning_for_reference
	test_has_open_pr_requires_open_close_keyword_for_our_issue

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
