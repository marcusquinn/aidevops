#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for origin:interactive merge gates (t2411).
#
# Verifies the criteria that govern whether an origin:interactive PR is
# eligible for auto-merge in pulse-merge.sh:
#   Case 1: OWNER (admin perm) passes _is_owner_or_member_author
#   Case 2: COLLABORATOR (write perm) fails _is_owner_or_member_author
#   Case 3: plain interactive PR requires manual merge by default
#   Case 4: hold-for-review label blocks _check_interactive_pr_gates
#   Case 5: draft PR blocks _check_interactive_pr_gates
#   Case 6: explicit allow-auto-merge label opts in
#   Case 7: environment override opts in
#   Case 8: global config opts in
#   Case 9: per-repo repos.json override opts in
#   Case 10: environment false overrides repo/global preferences
#   Case 11: allow-auto-merge label remains a PR-specific opt-in
#   Case 12: stale interactive PR without active claim passes automation
#
# No real repository is touched. The gh binary is replaced with a mock stub
# that serves canned responses from TEST_ROOT fixture files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge-author-checks.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	GH_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_LOG"
	export TEST_ROOT GH_LOG

	# Default permission fixture: admin (OWNER)
	printf '{"permission": "admin"}' >"${TEST_ROOT}/perm.json"

	# Mock gh: logs every call and returns canned data from TEST_ROOT fixtures.
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"
_all_args=("$@")

# HEAD call for permission check (-i flag)
if [[ "$*" == *"-i"* && "$*" == *"permission"* ]]; then
	printf 'HTTP/2 200\n\n'
	cat "${TEST_ROOT}/perm.json"
	exit 0
fi

# Permission API
if [[ "$*" == *"collaborators"* && "$*" == *"permission"* ]]; then
	_jq_filter=""
	for _i in "${!_all_args[@]}"; do
		if [[ "${_all_args[$_i]}" == "--jq" ]]; then
			_jq_filter="${_all_args[$((_i + 1))]:-}"
			break
		fi
	done
	if [[ -n "$_jq_filter" ]]; then
		jq -r "$_jq_filter" <"${TEST_ROOT}/perm.json"
	else
		cat "${TEST_ROOT}/perm.json"
	fi
	exit 0
fi

# labels+isDraft fetch for interactive gate
if [[ "$*" == *"--json"*"labels,isDraft"* || "$*" == *"labels,isDraft"* ]]; then
	cat "${TEST_ROOT:-/tmp}/pr-info.json" 2>/dev/null \
		|| printf '{"labels":[],"isDraft":false}'
	exit 0
fi

exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"

	# Default PR info: not draft, no special labels
	printf '{"labels":[],"isDraft":false}' >"${TEST_ROOT}/pr-info.json"
	printf '{"initialized_repos":[]}' >"${TEST_ROOT}/repos.json"
	export REPOS_JSON="${TEST_ROOT}/repos.json"
	unset AIDEVOPS_INTERACTIVE_PR_AUTO_MERGE
	unset -f config_get 2>/dev/null || true
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	unset AIDEVOPS_INTERACTIVE_PR_AUTO_MERGE REPOS_JSON
	unset -f config_get 2>/dev/null || true
	return 0
}

define_helpers_under_test() {
	# Source the sub-library directly so helper dependencies added alongside
	# _check_interactive_pr_gates are exercised by the test.
	# shellcheck source=/dev/null
	source "$MERGE_SCRIPT"
	return 0
}

# =============================================================================
# Case 1: OWNER (admin permission) — _is_owner_or_member_author returns 0
# =============================================================================
test_case1_owner_admin_perm_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"permission": "admin"}' >"${TEST_ROOT}/perm.json"
	: >"$GH_LOG"

	local result=0
	_is_owner_or_member_author "owner-user" "owner/repo" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case 1: OWNER (admin) passes _is_owner_or_member_author" 1 \
			"Expected exit 0, got ${result}"
	else
		print_result "Case 1: OWNER (admin) passes _is_owner_or_member_author" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case 2: COLLABORATOR (write permission) — _is_owner_or_member_author returns 1
# =============================================================================
test_case2_collaborator_write_perm_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"permission": "write"}' >"${TEST_ROOT}/perm.json"
	: >"$GH_LOG"

	local result=0
	_is_owner_or_member_author "collab-user" "owner/repo" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case 2: COLLABORATOR (write) blocked by _is_owner_or_member_author" 1 \
			"Expected non-zero exit, got 0 (COLLABORATOR should not pass OWNER/MEMBER check)"
	else
		print_result "Case 2: COLLABORATOR (write) blocked by _is_owner_or_member_author" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case 3: plain interactive PR requires manual merge by default.
# =============================================================================
test_case3_plain_interactive_requires_manual_merge() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	: >"$GH_LOG"
	local labels="origin:interactive"
	local result=0
	_check_interactive_pr_gates "101" "owner/repo" "$labels" "false" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case 3: plain interactive PR requires manual merge" 1 \
			"Expected non-zero exit, got 0 (interactive PR should not auto-merge by default)"
	else
		if ! grep -q "requires manual merge" "$LOGFILE" 2>/dev/null; then
			print_result "Case 3: plain interactive PR requires manual merge" 1 \
				"Exit was non-zero but manual-merge log message missing from ${LOGFILE}"
		else
			print_result "Case 3: plain interactive PR requires manual merge" 0
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case 4: hold-for-review label → _check_interactive_pr_gates returns 1
# =============================================================================
test_case4_hold_for_review_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	: >"$GH_LOG"
	local labels="origin:interactive,hold-for-review"
	local result=0
	_check_interactive_pr_gates "102" "owner/repo" "$labels" "false" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case 4: hold-for-review label blocks _check_interactive_pr_gates" 1 \
			"Expected non-zero exit, got 0 (hold-for-review should block)"
	else
		# Verify the log message was written
		if ! grep -q "hold-for-review opt-out" "$LOGFILE" 2>/dev/null; then
			print_result "Case 4: hold-for-review label blocks _check_interactive_pr_gates" 1 \
				"Exit was non-zero but hold-for-review log message missing from ${LOGFILE}"
		else
			print_result "Case 4: hold-for-review label blocks _check_interactive_pr_gates" 0
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case 5: draft PR → _check_interactive_pr_gates returns 1
# =============================================================================
test_case5_draft_pr_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	: >"$GH_LOG"
	local labels="origin:interactive"
	local result=0
	_check_interactive_pr_gates "103" "owner/repo" "$labels" "true" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case 5: draft PR blocks _check_interactive_pr_gates" 1 \
			"Expected non-zero exit, got 0 (draft should block)"
	else
		if ! grep -q "draft PR not eligible" "$LOGFILE" 2>/dev/null; then
			print_result "Case 5: draft PR blocks _check_interactive_pr_gates" 1 \
				"Exit was non-zero but draft log message missing from ${LOGFILE}"
		else
			print_result "Case 5: draft PR blocks _check_interactive_pr_gates" 0
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case 13 (GH#39158): stale interactive draft → exactly one handover, still skipped
# Case 14: hold-for-review / no-takeover / fresh draft → no handover
# =============================================================================
test_case13_stale_draft_hands_over() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	local handovers=0
	_interactive_pr_is_stale() { return 0; }
	_interactive_pr_trigger_handover() { handovers=$((handovers + 1)); return 0; }

	local result=0
	_check_interactive_pr_gates "113" "owner/repo" "origin:interactive" "true" && result=0 || result=$?
	if [[ "$result" -ne 0 && "$handovers" -eq 1 ]]; then
		print_result "Case 13: stale interactive draft handed over once and not merged" 0
	else
		print_result "Case 13: stale interactive draft handed over once and not merged" 1 \
			"result=${result} handovers=${handovers}"
	fi
	unset -f _interactive_pr_is_stale _interactive_pr_trigger_handover
	teardown_test_env
	return 0
}

test_case14_opted_out_or_fresh_draft_not_handed_over() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	local handovers=0
	_interactive_pr_is_stale() { return 1; }
	_recover_interactive_pr_work_issue() { return 1; }
	_interactive_pr_trigger_handover() { handovers=$((handovers + 1)); return 0; }

	_check_interactive_pr_gates "114" "owner/repo" "origin:interactive" "true" || true
	_interactive_pr_is_stale() { return 0; }
	_check_interactive_pr_gates "115" "owner/repo" "origin:interactive,hold-for-review" "true" || true
	_check_interactive_pr_gates "116" "owner/repo" "origin:interactive,no-takeover" "true" || true
	if [[ "$handovers" -eq 0 ]]; then
		print_result "Case 14: fresh and opted-out drafts are not handed over" 0
	else
		print_result "Case 14: fresh and opted-out drafts are not handed over" 1 \
			"handovers=${handovers}"
	fi
	unset -f _interactive_pr_is_stale _recover_interactive_pr_work_issue _interactive_pr_trigger_handover
	teardown_test_env
	return 0
}

# Recovery must complete closing linkage before the same-pass stale recheck.
test_orphan_draft_recheck_and_refusal_memo() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	local linked=0 handovers=0 rc=0
	export AIDEVOPS_MERGE_VERDICT_DIR="${TEST_ROOT}/verdicts"
	_interactive_pr_is_stale() { [[ "$linked" -eq 1 ]]; return $?; }
	_recover_interactive_pr_work_issue() { linked=1; return 0; }
	_interactive_pr_trigger_handover() { handovers=$((handovers + 1)); return 0; }
	_interactive_draft_pr_try_handover 117 owner/repo origin:interactive || rc=1
	[[ "$handovers" -eq 1 ]] || rc=1
	_interactive_draft_handover_refused 118 owner/repo no-takeover || true
	# Subshells and repeated passes must share the rate limit without hiding
	# a different gate or a different PR.
	( _interactive_draft_handover_refused 118 owner/repo no-takeover ) || true
	_interactive_draft_handover_refused 118 owner/repo hold-for-review || true
	_interactive_draft_handover_refused 119 owner/repo no-takeover || true
	[[ "$(grep -c 'interactive-draft-handover: PR #118 refused: no-takeover' "$LOGFILE")" -eq 1 ]] || rc=1
	[[ "$(grep -c 'interactive-draft-handover:' "$LOGFILE")" -eq 3 ]] || rc=1
	AIDEVOPS_MERGE_VERDICT_TTL_S=0 _interactive_draft_handover_refused 118 owner/repo no-takeover || true
	[[ "$(grep -c 'interactive-draft-handover: PR #118 refused: no-takeover' "$LOGFILE")" -eq 2 ]] || rc=1
	print_result "orphan draft links and hands over in one pass; refusals are memoized per PR and gate" "$rc"
	unset -f _interactive_pr_is_stale _recover_interactive_pr_work_issue _interactive_pr_trigger_handover
	unset AIDEVOPS_MERGE_VERDICT_DIR
	teardown_test_env
	return 0
}

# =============================================================================
# Case 6: explicit allow-auto-merge label opts interactive PRs into automation.
# =============================================================================
test_case6_allow_auto_merge_opt_in_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	: >"$GH_LOG"
	local labels="origin:interactive,allow-auto-merge"
	local result=0
	_check_interactive_pr_gates "104" "owner/repo" "$labels" "false" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case 6: allow-auto-merge opt-in passes" 1 \
			"Expected exit 0, got ${result}"
	else
		print_result "Case 6: allow-auto-merge opt-in passes" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case 7: environment override opts interactive PRs into automation.
# =============================================================================
test_case7_env_override_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	: >"$GH_LOG"
	local labels="origin:interactive"
	local result=0
	AIDEVOPS_INTERACTIVE_PR_AUTO_MERGE=1 _check_interactive_pr_gates "105" "owner/repo" "$labels" "false" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case 7: env override passes" 1 \
			"Expected exit 0, got ${result}"
	else
		print_result "Case 7: env override passes" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case 8: global config opts interactive PRs into automation.
# =============================================================================
test_case8_global_config_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	config_get() {
		local dotpath="$1"
		local default="${2:-}"
		if [[ "$dotpath" == "orchestration.interactive_pr_auto_merge" ]]; then
			printf '%s\n' "true"
		else
			printf '%s\n' "$default"
		fi
		return 0
	}

	local labels="origin:interactive"
	local result=0
	_check_interactive_pr_gates "106" "owner/repo" "$labels" "false" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case 8: global config opt-in passes" 1 \
			"Expected exit 0, got ${result}"
	else
		print_result "Case 8: global config opt-in passes" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case 9: per-repo repos.json override opts this repo into automation.
# =============================================================================
test_case9_repo_override_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"initialized_repos":[{"slug":"owner/repo","interactive_pr_auto_merge":true}]}' >"$REPOS_JSON"
	local labels="origin:interactive"
	local result=0
	_check_interactive_pr_gates "107" "owner/repo" "$labels" "false" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case 9: repo override opt-in passes" 1 \
			"Expected exit 0, got ${result}"
	else
		print_result "Case 9: repo override opt-in passes" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case 10: environment false overrides repo/global preferences.
# =============================================================================
test_case10_env_false_blocks_preferences() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"initialized_repos":[{"slug":"owner/repo","interactive_pr_auto_merge":true}]}' >"$REPOS_JSON"
	config_get() {
		local dotpath="$1"
		local default="${2:-}"
		if [[ "$dotpath" == "orchestration.interactive_pr_auto_merge" ]]; then
			printf '%s\n' "true"
		else
			printf '%s\n' "$default"
		fi
		return 0
	}

	local labels="origin:interactive"
	local result=0
	AIDEVOPS_INTERACTIVE_PR_AUTO_MERGE=0 _check_interactive_pr_gates "108" "owner/repo" "$labels" "false" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case 10: env false blocks preferences" 1 \
			"Expected non-zero exit, got 0"
	else
		print_result "Case 10: env false blocks preferences" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case 11: allow-auto-merge label remains PR-specific opt-in.
# =============================================================================
test_case11_label_overrides_env_false() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	local labels="origin:interactive,allow-auto-merge"
	local result=0
	AIDEVOPS_INTERACTIVE_PR_AUTO_MERGE=0 _check_interactive_pr_gates "109" "owner/repo" "$labels" "false" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case 11: allow-auto-merge label opt-in passes even with env false" 1 \
			"Expected exit 0, got ${result}"
	else
		print_result "Case 11: allow-auto-merge label opt-in passes even with env false" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case 12: stale interactive PR without active claim passes automation.
# =============================================================================
test_case12_stale_interactive_without_claim_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	_interactive_pr_is_stale() {
		local pr_number="$1"
		local repo_slug="$2"
		[[ "$pr_number" == "110" && "$repo_slug" == "owner/repo" ]]
		return $?
	}

	local labels="origin:interactive"
	local result=0
	_check_interactive_pr_gates "110" "owner/repo" "$labels" "false" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case 12: stale interactive PR without active claim passes" 1 \
			"Expected exit 0, got ${result}"
	elif ! grep -q "stale origin:interactive PR has no active claim" "$LOGFILE" 2>/dev/null; then
		print_result "Case 12: stale interactive PR without active claim passes" 1 \
			"Expected stale handover merge log in ${LOGFILE}"
	else
		print_result "Case 12: stale interactive PR without active claim passes" 0
	fi
	unset -f _interactive_pr_is_stale
	teardown_test_env
	return 0
}

# =============================================================================
# Run all cases
# =============================================================================
main() {
	if [[ ! -f "$MERGE_SCRIPT" ]]; then
		printf 'ERROR: merge script not found: %s\n' "$MERGE_SCRIPT" >&2
		exit 1
	fi

	test_case1_owner_admin_perm_passes
	test_case2_collaborator_write_perm_blocked
	test_case3_plain_interactive_requires_manual_merge
	test_case4_hold_for_review_blocked
	test_case5_draft_pr_blocked
	test_case6_allow_auto_merge_opt_in_passes
	test_case7_env_override_passes
	test_case8_global_config_passes
	test_case9_repo_override_passes
	test_case10_env_false_blocks_preferences
	test_case11_label_overrides_env_false
	test_case12_stale_interactive_without_claim_passes
	test_case13_stale_draft_hands_over
	test_case14_opted_out_or_fresh_draft_not_handed_over
	test_orphan_draft_recheck_and_refusal_memo

	echo ""
	printf 'Results: %d/%d passed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
	[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
	return 0
}

main "$@"
