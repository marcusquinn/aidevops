#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Issue metadata, author trust and permission gates. Sourced by the main runner;
# depends on its production helper imports, mocks and assertion functions.
# shellcheck disable=SC2016

[[ -n "${_TEST_DSI_POLICY_LOADED:-}" ]] && return 0
_TEST_DSI_POLICY_LOADED=1

test_load_issue_meta_accepts_lowercase_open() {
	MOCK_GH_FAIL="0"
	MOCK_GH_ISSUE_STATE="open"

	local rc=0
	_dsi_load_issue_meta 123 owner/repo >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 0 && "$_DSI_ISSUE_TITLE" == "Mock issue" ]] && check=0
	print_result "load issue meta accepts lowercase open" "$check" \
		"expected rc=0 with title populated, got rc=$rc title=$_DSI_ISSUE_TITLE"

	return 0
}

test_agent_flag_parses_with_default() {
	reset_test_state

	local rc=0
	_dsi_parse_dispatch_args 12345 owner/repo >/dev/null 2>&1 || rc=$?
	local default_agent="$_DSI_ARG_AGENT"
	local check1=1
	[[ "$rc" -eq 0 && "$default_agent" == "Build+" ]] && check1=0
	print_result "default worker agent is Build+" "$check1" \
		"rc=$rc agent=$default_agent"

	rc=0
	_dsi_parse_dispatch_args 12345 owner/repo --agent CustomAgent >/dev/null 2>&1 || rc=$?
	local custom_agent="$_DSI_ARG_AGENT"
	local check2=1
	[[ "$rc" -eq 0 && "$custom_agent" == "CustomAgent" ]] && check2=0
	print_result "--agent overrides worker agent" "$check2" \
		"rc=$rc agent=$custom_agent"

	rc=0
	_dsi_parse_dispatch_args 12345 owner/repo --agent --dry-run >/dev/null 2>&1 || rc=$?
	local check3=1
	[[ "$rc" -eq 2 ]] && check3=0
	print_result "--agent requires a value" "$check3" "rc=$rc"

	return 0
}

test_load_issue_meta_blocks_lowercase_closed() {
	MOCK_GH_FAIL="0"
	MOCK_GH_ISSUE_STATE="closed"

	local rc=0
	_dsi_load_issue_meta 124 owner/repo >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 1 ]] && check=0
	print_result "load issue meta blocks lowercase closed" "$check" \
		"expected rc=1 for closed state, got rc=$rc"

	return 0
}

test_pr_target_guard_detects_pull_request() {
	MOCK_GH_FAIL="0"
	MOCK_GH_TARGET_IS_PR="1"

	local rc=0
	_dsi_target_is_pull_request 123 owner/repo >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 0 ]] && check=0
	print_result "PR target guard detects pull_request marker" "$check" \
		"expected rc=0 for PR-shaped issue, got rc=$rc"
	return 0
}

test_pr_target_guard_allows_plain_issue() {
	MOCK_GH_FAIL="0"
	MOCK_GH_TARGET_IS_PR="0"

	local rc=0
	_dsi_target_is_pull_request 123 owner/repo >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 1 ]] && check=0
	print_result "PR target guard allows plain issue" "$check" \
		"expected rc=1 for plain issue, got rc=$rc"
	return 0
}

test_pr_target_guard_fails_closed_on_api_error() {
	MOCK_GH_FAIL="0"
	MOCK_GH_TARGET_IS_PR="api_fail"

	local rc=0
	_dsi_target_is_pull_request 123 owner/repo >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 2 ]] && check=0
	print_result "PR target guard reports verification errors" "$check" \
		"expected rc=2 for API failure, got rc=$rc"
	return 0
}

test_interactive_hold_guard_blocks_review_label_without_handoff() {
	local rc=0
	_dsi_guard_no_interactive_hold "bug,status:in-review" >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 1 ]] && check=0
	print_result "interactive hold guard blocks status:in-review without handoff" "$check" "rc=$rc"
	return 0
}

test_interactive_hold_guard_blocks_origin_interactive_without_handoff() {
	local rc=0
	_dsi_guard_no_interactive_hold "bug,origin:interactive" >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 1 ]] && check=0
	print_result "interactive hold guard blocks origin:interactive without handoff" "$check" "rc=$rc"
	return 0
}

test_interactive_hold_guard_allows_auto_dispatch_handoff() {
	local rc=0
	_dsi_guard_no_interactive_hold "bug,origin:interactive,auto-dispatch" >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 0 ]] && check=0
	print_result "interactive hold guard allows auto-dispatch handoff" "$check" "rc=$rc"
	return 0
}

test_interactive_hold_guard_allows_auto_dispatch_review_handoff() {
	local rc=0
	_dsi_guard_no_interactive_hold "bug,status:in-review,auto-dispatch" >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 0 ]] && check=0
	print_result "interactive hold guard allows auto-dispatch review handoff" "$check" "rc=$rc"
	return 0
}

test_maintainer_review_guard_blocks_manual_dispatch() {
	local rc=0
	local out=""
	out=$(_dsi_guard_no_maintainer_review_required "bug,needs-maintainer-review" 24354 owner/repo 2>&1) || rc=$?

	local check=1
	[[ "$rc" -eq 1 && "$out" == *"requires maintainer review"* && "$out" == *"sudo aidevops approve issue 24354 owner/repo"* ]] && check=0
	print_result "maintainer-review guard blocks manual dispatch" "$check" "rc=$rc output=$out"
	return 0
}

test_issue_author_guard_blocks_missing_label_bypass() {
	local helper_dir="" helper="" original_helper="$_DSI_APPROVAL_HELPER"
	helper_dir=$(mktemp -d)
	helper="${helper_dir}/approval-helper.sh"
	printf '%s\n' '#!/usr/bin/env bash' 'printf "NO_APPROVAL\n"' >"$helper"
	chmod +x "$helper"
	_DSI_APPROVAL_HELPER="$helper"
	_DSI_TARGET_JSON='{"author_association":"CONTRIBUTOR","user":{"login":"reporter","type":"User"}}'
	local out="" rc=0
	out=$(_dsi_guard_issue_author_trust 28700 owner/repo 2>&1) || rc=$?
	local check=1
	[[ "$rc" -eq 1 && "$out" == *"no verified approval"* ]] && check=0
	print_result "issue-author guard blocks missing-label bypass" "$check" "rc=$rc output=$out"

	_DSI_TARGET_JSON='{"author_association":"NONE","user":{"login":"github-actions[bot]","type":"Bot"},"labels":[{"name":"external-contributor"}]}'
	rc=0
	out=$(_dsi_guard_issue_author_trust 28700 owner/repo 2>&1) || rc=$?
	check=1
	[[ "$rc" -eq 1 && "$out" == *"external_source=true"* ]] && check=0
	print_result "issue-author guard blocks external-origin bot without approval" "$check" "rc=$rc output=$out"

	printf '%s\n' '#!/usr/bin/env bash' 'printf "VERIFIED\n"' >"$helper"
	rc=0
	_dsi_guard_issue_author_trust 28700 owner/repo >/dev/null 2>&1 || rc=$?
	check=1
	[[ "$rc" -eq 0 ]] && check=0
	print_result "issue-author guard accepts verified approval" "$check" "rc=$rc"

	_DSI_TARGET_JSON='{"author_association":"OWNER","user":{"login":"owner","type":"User"}}'
	_DSI_APPROVAL_HELPER="/path/that/does/not/exist"
	rc=0
	_dsi_guard_issue_author_trust 28700 owner/repo >/dev/null 2>&1 || rc=$?
	check=1
	[[ "$rc" -eq 0 ]] && check=0
	print_result "issue-author guard accepts owner without approval helper" "$check" "rc=$rc"

	_DSI_APPROVAL_HELPER="$original_helper"
	_DSI_TARGET_JSON=""
	rm -rf "$helper_dir"
	return 0
}

test_maintainer_permission_guard_blocks_manual_dispatch() {
	local rc=0
	local out=""
	out=$(_dsi_guard_no_maintainer_permission_required "bug,needs-maintainer-permissions" 24354 owner/repo 2>&1) || rc=$?

	local check=1
	[[ "$rc" -eq 1 && "$out" == *"scoped maintainer permission grant"* && "$out" == *"--request perm-"* ]] && check=0
	print_result "maintainer-permission guard blocks manual dispatch" "$check" "rc=$rc output=$out"

	rc=0
	out=$(_dsi_guard_no_maintainer_permission_required "bug,status:blocked" 24354 owner/repo 2>&1) || rc=$?
	check=1
	[[ "$rc" -eq 0 && -z "$out" ]] && check=0
	print_result "generic blocker does not impersonate maintainer-permission hold" "$check" "rc=$rc output=$out"
	return 0
}

test_permission_history_guard_requires_current_grant() {
	local helper_dir helper original_helper out rc=0
	helper_dir=$(mktemp -d)
	helper="${helper_dir}/approval-helper.sh"
	printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "${MOCK_PERMISSION_VERIFICATION:-NO_APPROVAL}"' >"$helper"
	chmod +x "$helper"
	original_helper="$_DSI_APPROVAL_HELPER"
	_DSI_APPROVAL_HELPER="$helper"
	MOCK_GH_PERMISSION_EVENTS_JSON='[[{"event":"labeled","label":{"name":"needs-maintainer-permissions"}}]]'
	export MOCK_PERMISSION_VERIFICATION="NO_REQUEST"
	out=$(_dsi_guard_permission_history_verified 24354 owner/repo 2>&1) || rc=$?

	local check=1
	[[ "$rc" -eq 0 && -z "$out" ]] && check=0
	print_result "permission label history without a request does not block manual dispatch" "$check" "rc=$rc output=$out"

	rc=0
	export MOCK_PERMISSION_VERIFICATION="STALE_APPROVAL"
	out=$(_dsi_guard_permission_history_verified 24354 owner/repo 2>&1) || rc=$?

	check=1
	[[ "$rc" -eq 1 && "$out" == *"without a current matching signed grant (STALE_APPROVAL)"* ]] && check=0
	print_result "permission history guard blocks stale grant" "$check" "rc=$rc output=$out"

	rc=0
	export MOCK_PERMISSION_VERIFICATION="VERIFIED"
	out=$(_dsi_guard_permission_history_verified 24354 owner/repo 2>&1) || rc=$?
	check=1
	[[ "$rc" -eq 1 && "$out" == *"bound to its original worker session and worktree"* ]] && check=0
	print_result "permission history guard rejects new worker for bound grant" "$check" "rc=$rc output=$out"

	_DSI_APPROVAL_HELPER="$original_helper"
	MOCK_GH_PERMISSION_EVENTS_JSON='[[]]'
	unset MOCK_PERMISSION_VERIFICATION
	rm -rf "$helper_dir"
	return 0
}
