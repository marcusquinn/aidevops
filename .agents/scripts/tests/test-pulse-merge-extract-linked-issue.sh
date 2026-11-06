#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for t2108 / GH#19051: pulse-merge.sh _extract_linked_issue
# must treat a single same-repository PR-body closing target as AUTHORITATIVE.
# A project-specific GH#NNN title prefix is not GitHub issue identity.
#
# Root cause: every PR in this repo follows the canonical title format
# "GH#NNN: description". _extract_linked_issue fell back to that title
# prefix even when the body intentionally used "For #NNN" or "Ref #NNN"
# to avoid auto-close. The result: planning-only and multi-PR roadmap
# PRs silently closed their linked issues on merge.
#
# Discovered live on 2026-04-15 — the t2105 brief PR (#19043) hit this
# exact pattern 14 minutes after the t2099 parent-task label guard merged.
#
# Strategy: extract _extract_linked_issue from pulse-merge.sh, eval it,
# and exercise it against a mock `gh pr view` stub that returns canned
# title + body fixtures. Assert the four scenarios below.
#
# Scenarios:
#   1. "For #NNN" body (no closing keyword) + GH#NNN title → empty
#      (regression guard for the t2105 incident)
#   2. "Resolves #NNN" body + GH#NNN title → issue number
#      (normal leaf close path still works)
#   3. "Closes #99999" body + unrelated GH#19042 title → #99999
#      (the single native closing target is authoritative)
#   4. "Ref #NNN" body (no closing keyword) + tNNN title → empty
#      (tNNN: title format has no GH# — both gates fail)
#   5. Multiple distinct closing identities → empty
#   5b-d. Closing references to pull requests are ignored (GH#36704)
#   6. Cross-repository closing reference → empty
#   7. Failed body metadata read → empty; unavailable title metadata is irrelevant

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"
# shellcheck source=../gh-closing-reference-lib.sh
source "${SCRIPT_DIR}/../gh-closing-reference-lib.sh"

readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%sFAIL%s %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# Prepare a mock `gh` that:
#   - Returns TEST_PR_TITLE when queried for PR title JSON
#   - Returns TEST_PR_BODY when queried for PR body JSON
#   - Stays silent for everything else
setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export TEST_PR_TITLE=""
	export TEST_PR_BODY=""
	export TEST_FAIL_METADATA=""
	: >"$LOGFILE"

	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Mock gh for test-pulse-merge-extract-linked-issue.sh
# Serves canned PR title/body fixtures via environment variables.

# gh pr view NNN --repo SLUG --json title --jq '.title // empty'
if [[ "$1" == "pr" && "$2" == "view" && "$*" == *"--json title"* ]]; then
	[[ "${TEST_FAIL_METADATA:-}" == "title" ]] && exit 1
	printf '%s\n' "${TEST_PR_TITLE:-}"
	exit 0
fi

# gh pr view NNN --repo SLUG --json body --jq '.body // empty'
if [[ "$1" == "pr" && "$2" == "view" && "$*" == *"--json body"* ]]; then
	[[ "${TEST_FAIL_METADATA:-}" == "body" ]] && exit 1
	printf '%s\n' "${TEST_PR_BODY:-}"
	exit 0
fi

# gh api repos/SLUG/issues/NNN — numbers listed in TEST_PULL_NUMBERS are PRs.
if [[ "$1" == "api" && "$2" =~ ^repos/[^/]+/[^/]+/issues/([0-9]+)$ ]]; then
	number="${BASH_REMATCH[1]}"
	[[ "${TEST_FAIL_METADATA:-}" == "issue-api" ]] && exit 1
	if [[ " ${TEST_PULL_NUMBERS:-} " == *" ${number} "* ]]; then
		printf '{"number":%s,"pull_request":{"url":"x"}}\n' "$number"
	elif [[ -n "${TEST_PULL_NUMBERS:-}" ]]; then
		printf '{"number":%s}\n' "$number"
	fi
	exit 0
fi

# Everything else — silent success
exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

gh_pr_view() {
	gh pr view "$@"
	return $?
}

_gh_with_timeout() {
	shift
	"$@"
	return $?
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Extract the function under test from pulse-merge.sh and eval it.
define_function_under_test() {
	local fn_src
	fn_src=$(awk '
		/^_extract_linked_issue\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$fn_src" ]]; then
		printf 'ERROR: could not extract _extract_linked_issue from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helper
	eval "$fn_src"
	fn_src=$(awk '/^_drop_closing_pull_request_refs\(\) \{/,/^}$/ { print }' "$MERGE_SCRIPT")
	[[ -n "$fn_src" ]] || return 1
	eval "$fn_src"
	fn_src=$(awk '/^_extract_pr_work_issue\(\) \{/,/^}$/ { print }' "$MERGE_SCRIPT")
	[[ -n "$fn_src" ]] || return 1
	eval "$fn_src"
	return 0
}

# Assert that the function returns (on stdout) the expected value.
assert_returns() {
	local expected="$1"
	local label="$2"
	local actual=""
	actual=$(_extract_linked_issue "1" "owner/repo") || actual=""
	if [[ "$actual" == "$expected" ]]; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected: '${expected}', got: '${actual}'"
	fi
	return 0
}

# Scenario 1: "For #NNN" body (no closing keyword) + GH#NNN title → empty
# This is the regression guard for the t2105 incident.
test_for_ref_body_no_close_returns_empty() {
	export TEST_PR_TITLE="GH#19042: plan t2105"
	export TEST_PR_BODY="For #19042

No closing keyword."
	assert_returns "" \
		"scenario1: For #NNN body with GH#NNN title returns empty (regression guard)"
	return 0
}

# Scenario 2: "Resolves #NNN" body + GH#NNN title → issue number
# The normal leaf-issue close path must still work after the fix.
test_resolves_body_returns_issue() {
	export TEST_PR_TITLE="GH#19042: fix bug"
	export TEST_PR_BODY="Resolves #19042
"
	assert_returns "19042" \
		"scenario2: Resolves #NNN body with GH#NNN title returns issue number"
	return 0
}

test_closing_keyword_accepts_tab_whitespace() {
	export TEST_PR_TITLE="GH#19042: fix bug"
	export TEST_PR_BODY="Resolves"$'\t'"#19042"
	assert_returns "19042" \
		"scenario2b: closing keyword with tab whitespace returns issue number"
	return 0
}

# Scenario 3: a project-specific GH# title cannot contradict the single native target.
test_unrelated_title_keeps_body_target() {
	export TEST_PR_TITLE="GH#19042: cross-issue"
	export TEST_PR_BODY="Closes #99999

Also references #19042."
	assert_returns "99999" \
		"scenario3: unrelated GH# title does not override native closing target"
	return 0
}

test_multiple_closing_issues_return_empty() {
	export TEST_PR_TITLE="GH#19042: cross-issue"
	export TEST_PR_BODY="Resolves #19042 and closes #99999"
	assert_returns "" \
		"scenario5: multiple closing issue identities return empty"
	return 0
}

# GH#36704: a closing keyword before a pull-request number links nothing on
# GitHub, so it must not make the real issue target ambiguous.
test_pull_request_closing_reference_is_ignored() {
	export TEST_PR_TITLE="GH#36583: bump types"
	export TEST_PR_BODY=$'Resolves #36583\n\nThen close #36582 as superseded.'
	export TEST_PULL_NUMBERS="36582"
	assert_returns "36583" \
		"scenario5b: closing reference to a pull request is ignored"
	export TEST_PULL_NUMBERS="36582 36583"
	assert_returns "" \
		"scenario5c: only pull-request closing references leave no target"
	export TEST_PULL_NUMBERS="36582"
	export TEST_FAIL_METADATA="issue-api"
	assert_returns "" \
		"scenario5d: issue lookup failure keeps the ambiguity (fail closed)"
	export TEST_FAIL_METADATA=""
	export TEST_PULL_NUMBERS=""
	return 0
}

test_cross_repo_closing_reference_returns_empty() {
	export TEST_PR_TITLE="GH#19042: external tracker identity"
	export TEST_PR_BODY="Resolves other/repo#19042"
	assert_returns "" \
		"scenario6: cross-repository closing reference is not a local issue target"
	return 0
}

test_metadata_failure_returns_empty() {
	export TEST_PR_TITLE="GH#19042: fix bug"
	export TEST_PR_BODY="Resolves #19042"
	export TEST_FAIL_METADATA="title"
	assert_returns "19042" "scenario7a: unavailable title metadata does not block body target"
	export TEST_FAIL_METADATA="body"
	assert_returns "" "scenario7b: failed body metadata read returns empty"
	export TEST_FAIL_METADATA=""
	return 0
}

# Scenario 4: "Ref #NNN" body + tNNN title → empty
# tNNN: title format has no GH# — title regex misses.
# "Ref #NNN" body has no closing keyword — body check also misses.
# Both gates fail → empty.
test_ref_body_tnnn_title_returns_empty() {
	export TEST_PR_TITLE="t2108: planning brief"
	export TEST_PR_BODY="Ref #19051
"
	assert_returns "" \
		"scenario4: Ref #NNN body with tNNN title (no GH#) returns empty"
	return 0
}

assert_association() {
	local expected="$1" expected_rc="$2" label="$3" repo="${4:-owner/repo}"
	local actual="" rc=0
	actual=$(_extract_pr_work_issue "1" "$repo" explicit) || rc=$?
	if [[ "$actual" == "$expected" && "$rc" == "$expected_rc" ]]; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected '${expected}' / rc=${expected_rc}, got '${actual}' / rc=${rc}"
	fi
	return 0
}

test_explicit_merge_association() {
	export TEST_PR_TITLE="t99999: title is not issue identity"
	export TEST_PR_BODY=$'## Summary\n\nFor #12303 — partial people-phase delivery; leave the issue open.\n\n## Remaining work\n\nFor #12643\n'
	assert_association "12303" 0 "partial delivery keeps primary task, not Remaining work"
	assert_returns "" "partial delivery still has no closing target"
	export TEST_PR_BODY=$'## Summary\n\nRef: #12254\n'
	assert_association "12254" 0 "non-closing Ref declaration associates a task"
	export TEST_PR_BODY=$'For #42\nRef #42'
	assert_association "42" 0 "repeated identical declarations are unambiguous"
	export TEST_PR_BODY=$'For #42\nRef #43'
	assert_association "" 1 "distinct explicit declarations fail closed"
	export TEST_PR_BODY='For #42 and Ref #43'
	assert_association "" 1 "multiple references on one declaration fail closed"
	export TEST_PR_BODY='For #101. Continuing the merged checkpoint from PR #99. Scope: data files only.'
	assert_association "101" 0 "context sentences after the declaration are not a second task"
	export TEST_PR_BODY='For #101. **Ready partial delivery; do not close the issue or tracker #90.**'
	assert_association "101" 0 "an emphasised tracker reference after the declaration is context"
	export TEST_PR_BODY='For #42, #43'
	assert_association "" 1 "a comma-separated target list fails closed"
	export TEST_PR_BODY='For #42 and #43. Partial delivery.'
	assert_association "" 1 "a conjunctive target list fails closed"
	export TEST_PR_BODY='For #42 (parent gate #41 / t018).'
	assert_association "" 1 "a parenthetical reference inside the declaration clause fails closed"
	export TEST_PR_BODY='For #42. Ref #43.'
	assert_association "" 1 "a second same-line declaration sentence fails closed"
	export TEST_PR_BODY='For #42; ref: #43'
	assert_association "" 1 "a declaration after a clause terminator fails closed"
	export TEST_PR_BODY='No issue declaration.'
	assert_association "" 0 "title-only task ID cannot supply merge association"
	export TEST_PR_BODY='For other/repo#42'
	assert_association "" 0 "cross-repository For reference cannot become local issue"
	export TEST_PR_BODY='Ref https://github.com/other/repo/issues/42'
	assert_association "" 0 "cross-repository URL cannot become local issue"
	export TEST_PR_BODY=$'See For #42 for context.\n> Ref #43\n```text\nFor #44\n```\n<!--\nFor #45\n-->\n    For #46\n## Remaining work\nRef #47'
	assert_association "" 0 "incidental, quoted, code, comment and follow-up references are not primary"
	export TEST_PR_BODY=$'```text\n~~~\nFor #42\n```'
	assert_association "" 0 "a different fence marker cannot expose a code example as a task"
	export TEST_PR_BODY=$'````text\n```\nFor #42\n````\nFor #43'
	assert_association "43" 0 "a shorter fence cannot close a longer code block"
	export TEST_PR_BODY=$'~~~text\n~~~example\nRef #42\n~~~\nRef #43'
	assert_association "43" 0 "fence-like content with trailing text cannot close a code block"
	export TEST_PR_BODY=$'## Remaining work\n### Portrait recovery\nFor #12643'
	assert_association "" 0 "nested follow-up headings cannot reset the primary-task boundary"
	export TEST_PR_BODY='For #42suffix'
	assert_association "" 0 "malformed issue token does not supply identity"
	export TEST_PR_BODY='Resolves #42'
	assert_association "42" 0 "existing closing target still associates a task"
	export TEST_PR_BODY=$'Closes #42\nFixes #43\nFor #44'
	assert_association "" 1 "ambiguous closing targets cannot fall back to For"
	export TEST_PR_BODY='For #42'
	assert_association "" 1 "invalid repository scope fails closed" "owner/repo/extra"
	export TEST_FAIL_METADATA="body"
	assert_association "" 1 "unavailable body metadata fails closed"
	export TEST_FAIL_METADATA="title"
	assert_association "42" 0 "merge association never needs title metadata"
	export TEST_FAIL_METADATA=""
	return 0
}

test_merge_gate_association_is_not_closure() {
	local fn_src="" result=0 linked_issue="" gate_issue="" gate_repo="" author_rc=0 review_rc=0
	fn_src=$(awk '/^_check_pr_merge_gates\(\) \{/,/^}$/ { print }' "$MERGE_SCRIPT")
	eval "$fn_src"
	# Closure validation has its own merge-contradiction harness.
	_gh_pr_merge_closure_check() { return 0; }
	_interactive_claim_fence_blocks_merge() { return 1; }
	_pm_gate_review_mode() { return 0; }
	_pm_gate_author_trust() { return "$author_rc"; }
	_pm_gate_repository_and_issue() {
		gate_issue="$3"
		gate_repo="$2"
		return 0
	}
	_pm_gate_origin_authority() {
		[[ "$3" == "12303" ]] || return 1
		return 0
	}
	_pm_gate_review_bot() { return "$review_rc"; }
	export TEST_PR_BODY=$'## Summary\nFor #12303 — partial delivery.\n## Remaining work\nRef #12643'
	_check_pr_merge_gates "12641" "owner/repo" "trusted" "NONE" "$linked_issue" "origin:worker" "head" || result=$?
	if [[ "$result" == "0" && "$gate_issue" == "12303" && "$gate_repo" == "owner/repo" && -z "$linked_issue" ]]; then
		print_result "merge gates receive scoped partial association without leaking closure authority" 0
	else
		print_result "merge gates receive scoped partial association without leaking closure authority" 1
	fi
	author_rc=1
	result=0
	_check_pr_merge_gates "12641" "owner/repo" "untrusted" "NONE" "" "origin:worker" "head" || result=$?
	print_result "valid partial association still requires author trust" "$((1 - result))"
	author_rc=0
	review_rc=1
	result=0
	_check_pr_merge_gates "12641" "owner/repo" "trusted" "NONE" "" "origin:worker" "head" || result=$?
	print_result "valid partial association still requires review gate" "$((1 - result))"
	return 0
}

test_worker_write_identity() {
	local _GH_PR_IDENTITY_ORIGIN="origin:worker" body="" rc=0
	local _GH_EDIT_REJECTION_REASON=""
	for body in $'For #42\nFor #43' 'For #42. For #43.' 'For #42. Ref #43 and #44.' 'Checkpoint For #42; do not close the issue.' 'No linked issue.'; do
		rc=0
		_gh_validate_pr_closing_keywords --body "$body" 2>"${TEST_ROOT}/rejection" || rc=$?
		# shellcheck disable=SC2016 # Match literal Markdown code spans.
		if [[ "$rc" == 1 ]] && grep -Fq 'keep one standalone `For #N` line; move other references under `## Related`' "${TEST_ROOT}/rejection"; then
			print_result "worker write rejects ${body}" 0
		else
			print_result "worker write rejects ${body}" 1
		fi
	done
	for body in $'For #42\n\n## Related\nRef #43\nRef #44' $'Ref: #42\n## Remaining work\nFor #43'; do
		rc=0
		_gh_validate_pr_closing_keywords --body "$body" || rc=$?
		print_result "worker write accepts secondary references" "$rc"
		export TEST_PR_BODY="$body"
		assert_association "42" 0 "accepted worker body has exactly one explicit merge identity"
	done
	rc=0
	_gh_validate_pr_closing_keywords --body 'Resolves #42' || rc=$?
	print_result "worker write preserves native closing declarations" "$rc"
	_GH_PR_IDENTITY_ORIGIN="origin:interactive"
	rc=0
	_gh_validate_pr_closing_keywords --body $'For #42\nFor #43' || rc=$?
	print_result "interactive bodies retain existing behavior" "$rc"
	return 0
}

test_worker_write_wrappers() {
	local result=0
	# Isolate the real write entrypoints and their normal body-file processing.
	# Only external metadata, signatures, audit storage and transport are stubbed.
	(
		# shellcheck source=../shared-constants.sh
		source "${SCRIPT_DIR}/../shared-constants.sh"
		gh_record_call() { return 0; }
		_gh_edit_audit_rejection() { return 0; }
		_ensure_origin_labels_for_args() { return 0; }
		_gh_guard_public_write_args() { return 0; }
		_gh_wrapper_auto_sig() { _GH_WRAPPER_SIG_MODIFIED_ARGS=("$@"); return 0; }
		_gh_create_pr_enforce_origin_postcondition() { return 0; }
		_gh_audit_fetch_pr_state_json() { return 0; }
		_gh_audit_record_op() { return 0; }
		session_origin_label() { printf 'origin:worker'; return 0; }
		local fixture_labels='["origin:worker"]' fail_labels=0 writes=0 body="" rc=0
		gh_pr_view() {
			[[ "$fail_labels" -eq 0 ]] || return 1
			printf '%s' "$fixture_labels"
			return 0
		}
		gh() {
			local resource="$1" operation="$2"
			if [[ "$resource" == "pr" && ( "$operation" == "create" || "$operation" == "edit" ) ]]; then
				printf '%s\n' "$operation" >>"${TEST_ROOT}/writes"
			fi
			return 0
		}
		: >"${TEST_ROOT}/writes"
		for body in $'For #42\nFor #43' 'For #42. For #43.' 'For #42. Ref #43 and #44.' 'Checkpoint For #42; do not close the issue.'; do
			printf '%s\n' "$body" >"${TEST_ROOT}/worker-body"
			rc=0
			gh_create_pr --repo owner/repo --title 'Checkpoint identity' --body-file "${TEST_ROOT}/worker-body" >/dev/null 2>&1 || rc=$?
			[[ "$rc" -eq 1 ]] || exit 1
			rc=0
			gh_pr_edit_safe --repo owner/repo 1 --body-file "${TEST_ROOT}/worker-body" >/dev/null 2>&1 || rc=$?
			[[ "$rc" -eq 1 ]] || exit 1
		done
		[[ ! -s "${TEST_ROOT}/writes" ]] || exit 1
		printf '%s\n' 'For #42' '' '## Related' 'Ref #43' >"${TEST_ROOT}/worker-body"
		gh_create_pr --repo owner/repo --title 'Checkpoint identity' --body-file "${TEST_ROOT}/worker-body" >/dev/null || exit 1
		gh_pr_edit_safe 1 --repo owner/repo --body-file "${TEST_ROOT}/worker-body" || exit 1
		writes=$(wc -l <"${TEST_ROOT}/writes")
		[[ "$writes" -eq 2 ]] || exit 1
		fail_labels=1
		rc=0
		gh_pr_edit_safe 1 --repo owner/repo --body 'For #42' >/dev/null 2>&1 || rc=$?
		[[ "$rc" -eq 1 ]] || exit 1
		# Metadata-only edits do not need body identity or a new label read.
		gh_pr_edit_safe 1 --repo owner/repo --title 'Updated checkpoint' || exit 1
		fail_labels=0
		fixture_labels='["origin:interactive"]'
		gh_pr_edit_safe 1 --repo owner/repo --body 'Checkpoint For #42' || exit 1
		rc=0
		gh_pr_edit_safe 1 --repo owner/repo --add-label origin:worker --body 'Checkpoint For #42' >/dev/null 2>&1 || rc=$?
		[[ "$rc" -eq 1 ]] || exit 1
		exit 0
	) || result=$?
	print_result "real create/edit wrappers enforce worker identity before writes and preserve metadata/interactive edits" "$result"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_function_under_test; then
		printf 'FATAL: function extraction failed\n' >&2
		return 1
	fi

	test_for_ref_body_no_close_returns_empty
	test_resolves_body_returns_issue
	test_closing_keyword_accepts_tab_whitespace
	test_unrelated_title_keeps_body_target
	test_ref_body_tnnn_title_returns_empty
	test_multiple_closing_issues_return_empty
	test_pull_request_closing_reference_is_ignored
	test_cross_repo_closing_reference_returns_empty
	test_metadata_failure_returns_empty
	test_explicit_merge_association
	test_worker_write_identity
	test_worker_write_wrappers
	test_merge_gate_association_is_not_closure

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
