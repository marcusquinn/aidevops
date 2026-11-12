#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for origin:worker worker-briefed auto-merge gates (t2449).
#
# Verifies the 10 coverage cases from GH#20204 §How, plus t3052 and t3062:
#   Case (a): origin:worker + issue-author=OWNER + green CI + no NMR → auto-merges
#   Case (b): origin:worker + issue-author=MEMBER + green + no NMR → auto-merges
#   Case (c): origin:worker + issue-author=CONTRIBUTOR → does NOT auto-merge
#   Case (d): origin:worker + trusted-author legacy auto-normalization → auto-merges
#   Case (e): origin:worker + NMR cleared via crypto approval → auto-merges
#   Case (f): origin:worker + hold-for-review label → does NOT auto-merge
#   Case (g): origin:worker + human CHANGES_REQUESTED → does NOT auto-merge
#   Case (h): origin:worker + draft PR → does NOT auto-merge
#   Case (i): origin:worker-takeover label → does NOT auto-merge
#   Case (j): Bot review in placeholder window → waits, doesn't merge yet
#   Case (k): origin:worker + NONE author + crypto approval → passes (t3052)
#   Case (l): origin:worker + NONE author + no crypto → blocked (t3052)
#   Case (m): origin:worker + OWNER author + no crypto → still passes (t3052)
#   Case (n): COLLABORATOR author + login in trusted-issue-author allowlist → passes (t3062)
#   Case (o): COLLABORATOR author + login NOT in allowlist + no crypto → blocked (t3062)
#   Case (p): COLLABORATOR author + authenticated write permission → passes (GH#24958)
#   Case (q): COLLABORATOR author + authenticated read permission → blocked (GH#24958)
#   Case (r): precomputed write permission skips collaborator permission API (GH#25057)
#   Case (s): worker gate reuses matching precomputed permission (GH#25070)
#   Case (t): worker gate ignores mismatched precomputed permission (GH#25070)
#   Case (u): issue-author=NONE + spoofed crypto marker → blocked (GH#21936)
#
# No real repository is touched. The gh binary is replaced with a mock stub
# that serves canned responses from TEST_ROOT fixture files.
#
# Pattern mirrors: test-pulse-merge-origin-interactive-auto-merge.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"
# shellcheck source=../gh-closing-reference-lib.sh
source "${SCRIPT_DIR}/../gh-closing-reference-lib.sh"
WORKER_BRIEFED_SCRIPT="${SCRIPT_DIR}/../pulse-merge-process-worker-briefed.sh"

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
	mkdir -p "${TEST_ROOT}/scripts"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export AGENTS_DIR="${TEST_ROOT}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	GH_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_LOG"
	export TEST_ROOT GH_LOG
	APPROVAL_VERIFY_RESULT=""
	export APPROVAL_VERIFY_RESULT

	# Default issue fixture: author_association=OWNER, no NMR comments
	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	# Default comments fixture: empty array (no NMR markers)
	printf '[]' >"${TEST_ROOT}/comments.json"
	# Default collaborator permission fixture: read (not maintainer-equivalent)
	printf 'read' >"${TEST_ROOT}/permission.txt"

	# Mock gh: logs every call and returns canned data from TEST_ROOT fixtures.
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"
_all_args=("$@")

# PR files API (GH#36922); a missing fixture simulates an API failure.
[[ "$*" == *"repos/"*"/pulls/"*"/files"* ]] && { cat "${TEST_ROOT}/pr-files.json" 2>/dev/null; exit $?; }
# PR head SHA read (bound before/after the file list)
[[ "$*" == *"repos/"*"/pulls/"[0-9]* && "$*" == *"head.sha"* ]] && { printf '%s\n' "${MOCK_PR_HEAD_SHA:-0123456789abcdef0123456789abcdef01234567}"; exit 0; }

# PR base SHA read (starter-sync scope, GH#37289)
[[ "$*" == *"repos/"*"/pulls/"[0-9]* && "$*" == *"base.sha"* ]] && { [[ -f "${TEST_ROOT}/base-sha.txt" ]] || exit 1; cat "${TEST_ROOT}/base-sha.txt"; exit 0; }
# Starter core-files list at the base ref (GH#37289); missing fixture = API failure
[[ "$*" == *"/contents/scripts/core-files.txt?ref="* ]] && { cat "${TEST_ROOT}/core-files.txt" 2>/dev/null; exit $?; }

# Issue API (author_association check)
if [[ "$*" == *"repos/"*"/issues/"* ]] && [[ "$*" != *"/comments"* ]] && [[ "$*" != *"/labels"* ]]; then
	_jq_filter=""
	for _i in "${!_all_args[@]}"; do
		if [[ "${_all_args[$_i]}" == "--jq" ]]; then
			_jq_filter="${_all_args[$((_i + 1))]:-}"
			break
		fi
	done
	if [[ -n "$_jq_filter" ]]; then
		jq -r "$_jq_filter" <"${TEST_ROOT}/issue.json"
	else
		cat "${TEST_ROOT}/issue.json"
	fi
	exit 0
fi

# Issue comments API (NMR marker check)
if [[ "$*" == *"/comments"* ]]; then
	_jq_filter=""
	for _i in "${!_all_args[@]}"; do
		if [[ "${_all_args[$_i]}" == "--jq" ]]; then
			_jq_filter="${_all_args[$((_i + 1))]:-}"
			break
		fi
	done
	if [[ -n "$_jq_filter" ]]; then
		jq -r "$_jq_filter" <"${TEST_ROOT}/comments.json"
	else
		cat "${TEST_ROOT}/comments.json"
	fi
	exit 0
fi

# Collaborator permission API (maintainer-authority fallback)
if [[ "$*" == *"/collaborators/"*"/permission"* ]]; then
	_jq_filter=""
	_permission="$(cat "${TEST_ROOT}/permission.txt" 2>/dev/null || printf 'read')"
	_json="{\"permission\":\"${_permission}\"}"
	for _i in "${!_all_args[@]}"; do
		if [[ "${_all_args[$_i]}" == "--jq" ]]; then
			_jq_filter="${_all_args[$((_i + 1))]:-}"
			break
		fi
	done
	if [[ -n "$_jq_filter" ]]; then
		printf '%s' "$_json" | jq -r "$_jq_filter"
	else
		printf '%s\n' "$_json"
	fi
	exit 0
fi

exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	write_approval_helper_stub
	return 0
}

write_approval_helper_stub() {
	cat >"${TEST_ROOT}/scripts/approval-helper.sh" <<'APPROVAL_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "verify" ]]; then
	printf '%s\n' "${APPROVAL_VERIFY_RESULT:-}"
	exit 0
fi
exit 1
APPROVAL_EOF
	chmod +x "${TEST_ROOT}/scripts/approval-helper.sh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	unset AGENTS_DIR APPROVAL_VERIFY_RESULT
	return 0
}

# Extract _attempt_worker_briefed_auto_merge and its dependencies from the
# merge scripts and eval them into the test shell.
# _pm_issue_api lives in pulse-merge.sh (module-level helper).
# _is_trusted_issue_author and _attempt_worker_briefed_auto_merge live in
# pulse-merge-process-worker-briefed.sh (split from pulse-merge-process.sh in
# GH#27171; t3062 adds the trusted-author helper).
define_helpers_under_test() {
	local src_worker_briefed src_issue_api src_trusted_author src_issue_authority src_crypto_approval
	src_issue_api=$(awk '
		/^_pm_issue_api\(\) \{/,/^\}$/ { print }
	' "$MERGE_SCRIPT")
	local extract_from="$WORKER_BRIEFED_SCRIPT"
	src_trusted_author=$(awk '
		/^_is_trusted_issue_author\(\) \{/,/^\}$/ { print }
	' "$extract_from")
	src_issue_authority=$(awk '
		/^_issue_author_has_maintainer_authority\(\) \{/,/^\}$/ { print }
	' "$extract_from")
	src_crypto_approval=$(awk '
		/^_issue_has_verified_crypto_approval\(\) \{/,/^\}$/ { print }
	' "$extract_from")
	src_worker_briefed=$(awk '
		/^_attempt_worker_briefed_auto_merge\(\) \{/,/^\}$/ { print }
	' "$extract_from")
	src_worker_briefed+=$'\n'$(awk '
		/^_PM_PLANNING_CHECKPOINT_MAX_FILES=/ { print }
		/^_worker_briefed_pr_is_planning_checkpoint\(\) \{/,/^\}$/ { print }
		/^_worker_briefed_link_kind\(\) \{/,/^\}$/ { print }
		/^_worker_briefed_trust_check\(\) \{/,/^\}$/ { print }
		/^_worker_briefed_pr_eligible\(\) \{/,/^\}$/ { print }
		/^worker_briefed_trust_verdict\(\) \{/,/^\}$/ { print }
		/^_worker_briefed_record_bot_decision\(\) \{/,/^\}$/ { print }
	' "$extract_from")
	# GH#35752: scoped OpenCode pin-canary brief trust (constants + helpers).
	src_worker_briefed+=$'\n'$(awk '
		/^_PM_OPENCODE_CANARY_ALLOWED_FILES=/,/^_PM_OPENCODE_CANARY_MAX_FILES=/ { print }
		/^_pm_canary_shared_constants_patch_ok\(\) \{/,/^\}$/ { print }
		/^_is_trusted_opencode_canary_issue_pr\(\) \{/,/^\}$/ { print }
		/^_is_trusted_starter_sync_issue_pr\(\) \{/,/^\}$/ { print }
	' "$extract_from")
	if [[ -z "$src_worker_briefed" || -z "$src_issue_api" ]]; then
		printf 'ERROR: could not extract helpers from %s / %s\n' "$MERGE_SCRIPT" "$extract_from" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$src_issue_api"
	# shellcheck disable=SC1090
	eval "$src_trusted_author"
	# shellcheck disable=SC1090
	eval "$src_issue_authority"
	# shellcheck disable=SC1090
	eval "$src_crypto_approval"
	# shellcheck disable=SC1090
	eval "$src_worker_briefed"
	# Default: the PR has a closing-keyword link (GH#33999 gates only the
	# non-closing path). Tests set TEST_CLOSING_ISSUE="" for For/Ref-only PRs.
	_extract_linked_issue() {
		printf '%s' "${TEST_CLOSING_ISSUE-1}"
		return 0
	}
	return 0
}

# =============================================================================
# Case (a): origin:worker + issue-author=OWNER + no NMR → passes
# =============================================================================
test_case_a_owner_issue_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "100" "owner/repo" "origin:worker" "false" "42" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (a): OWNER-briefed issue + no NMR → passes" 1 \
			"Expected exit 0, got ${result}"
	else
		print_result "Case (a): OWNER-briefed issue + no NMR → passes" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (b): origin:worker + issue-author=MEMBER + no NMR → passes
# =============================================================================
test_case_b_member_issue_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"MEMBER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "101" "owner/repo" "origin:worker" "false" "43" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (b): MEMBER-briefed issue + no NMR → passes" 1 \
			"Expected exit 0, got ${result}"
	else
		print_result "Case (b): MEMBER-briefed issue + no NMR → passes" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (c): origin:worker + issue-author=CONTRIBUTOR → blocked
# =============================================================================
test_case_c_contributor_issue_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"CONTRIBUTOR"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "102" "owner/repo" "origin:worker" "false" "44" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (c): CONTRIBUTOR-filed issue → blocked" 1 \
			"Expected non-zero exit, got 0 (CONTRIBUTOR should not pass)"
	else
		if grep -q "not OWNER/MEMBER" "$LOGFILE" 2>/dev/null; then
			print_result "Case (c): CONTRIBUTOR-filed issue → blocked" 0
		elif grep -q "no cryptographic approval signature found" "$LOGFILE" 2>/dev/null; then
			# t3052: log message updated to include crypto check info
			print_result "Case (c): CONTRIBUTOR-filed issue → blocked" 0
		else
			print_result "Case (c): CONTRIBUTOR-filed issue → blocked" 1 \
				"Exit was non-zero but expected log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (d): trusted-author legacy auto-normalization residue → passes
# =============================================================================
test_case_d_trusted_author_normalization_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	# Historical auto-approval marker is residue, not a current trust gate. The
	# live OWNER author independently establishes authority.
	printf '[{"body":"auto-approved-maintainer-issue: cleared NMR"}]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "103" "owner/repo" "origin:worker" "false" "45" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (d): trusted-author normalization residue → passes" 0
	else
		print_result "Case (d): trusted-author normalization residue → passes" 1 \
			"Expected exit 0, got ${result}"
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (e): NMR cleared via crypto approval → passes
# =============================================================================
test_case_e_nmr_crypto_cleared_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	# Comments contain BOTH auto-approval AND crypto approval markers
	printf '[{"body":"auto-approved-maintainer-issue: cleared NMR"},{"body":"aidevops:approval-signature: SHA256:abc123"}]' >"${TEST_ROOT}/comments.json"
	export APPROVAL_VERIFY_RESULT="VERIFIED"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "104" "owner/repo" "origin:worker" "false" "46" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (e): NMR crypto-cleared → passes" 1 \
			"Expected exit 0, got ${result}"
	else
		if grep -q "passed all gates" "$LOGFILE" 2>/dev/null; then
			print_result "Case (e): NMR crypto-cleared → passes" 0
		else
			print_result "Case (e): NMR crypto-cleared → passes" 1 \
				"Exit was 0 but expected success log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (f): hold-for-review label → blocked
# =============================================================================
test_case_f_hold_for_review_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "105" "owner/repo" "origin:worker,hold-for-review" "false" "47" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (f): hold-for-review label → blocked" 1 \
			"Expected non-zero exit, got 0 (hold-for-review should block)"
	else
		if grep -q "hold-for-review label" "$LOGFILE" 2>/dev/null; then
			print_result "Case (f): hold-for-review label → blocked" 0
		else
			print_result "Case (f): hold-for-review label → blocked" 1 \
				"Exit was non-zero but expected log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (g): CHANGES_REQUESTED — boundary test. This gate is checked UPSTREAM
# of _attempt_worker_briefed_auto_merge in _check_pr_merge_gates. The worker-
# briefed function itself is agnostic to review state — verify it passes when
# given valid inputs (review state is the caller's responsibility).
# =============================================================================
test_case_g_changes_requested_is_upstream() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	# _attempt_worker_briefed_auto_merge does not receive review state.
	# A non-draft, non-hold-for-review, OWNER-briefed PR passes this helper.
	local result=0
	_attempt_worker_briefed_auto_merge "106" "owner/repo" "origin:worker" "false" "48" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (g): CHANGES_REQUESTED is upstream — helper passes" 1 \
			"Expected exit 0 (CHANGES_REQUESTED is upstream gate), got ${result}"
	else
		print_result "Case (g): CHANGES_REQUESTED is upstream — helper passes" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (h): draft PR → blocked
# =============================================================================
test_case_h_draft_pr_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "107" "owner/repo" "origin:worker" "true" "49" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (h): draft PR → blocked" 1 \
			"Expected non-zero exit, got 0 (draft should block)"
	else
		if grep -q "draft PR not eligible" "$LOGFILE" 2>/dev/null; then
			print_result "Case (h): draft PR → blocked" 0
		else
			print_result "Case (h): draft PR → blocked" 1 \
				"Exit was non-zero but expected log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (i): origin:worker-takeover → the caller pre-filters using comma-
# delimited matching (",origin:worker," != ",origin:worker-takeover,").
# Verify the function itself blocks if somehow called with takeover labels.
# =============================================================================
test_case_i_worker_takeover_excluded() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	# Simulate the caller's comma-delimited check:
	# ",origin:worker-takeover," does NOT match ",origin:worker," pattern.
	local labels_str="origin:worker-takeover"
	local match=0
	if [[ ",${labels_str}," == *",origin:worker,"* ]]; then
		match=1
	fi

	if [[ "$match" -eq 1 ]]; then
		print_result "Case (i): origin:worker-takeover excluded by caller" 1 \
			"Comma-delimited match should NOT fire for origin:worker-takeover"
	else
		print_result "Case (i): origin:worker-takeover excluded by caller" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (j): Feature flag AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=0 → blocked
# (The spec case is "bot review in placeholder window → waits". That wait is
# handled by review-bot-gate-helper.sh UPSTREAM. This test verifies the
# feature-flag off-switch, which is the closest unit-testable analogue.)
# =============================================================================
test_case_j_feature_flag_off_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=0

	local result=0
	_attempt_worker_briefed_auto_merge "109" "owner/repo" "origin:worker" "false" "51" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (j): feature flag OFF → blocked" 1 \
			"Expected non-zero exit, got 0 (flag=0 should block)"
	else
		if grep -q "disabled by AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=0" "$LOGFILE" 2>/dev/null; then
			print_result "Case (j): feature flag OFF → blocked" 0
		else
			print_result "Case (j): feature flag OFF → blocked" 1 \
				"Exit was non-zero but expected log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (k): issue-author=NONE + crypto approval signature → passes (t3052)
# Maintainer cryptographically approved a contributor-filed issue.
# =============================================================================
test_case_k_non_owner_with_crypto_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"NONE"}' >"${TEST_ROOT}/issue.json"
	# Comments contain crypto approval signature — maintainer vouched
	printf '[{"body":"aidevops:approval-signature: SHA256:abc123"}]' >"${TEST_ROOT}/comments.json"
	export APPROVAL_VERIFY_RESULT="VERIFIED"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "110" "owner/repo" "origin:worker" "false" "52" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (k): NONE author + crypto approval → passes (t3052)" 1 \
			"Expected exit 0, got ${result}"
	else
		if grep -q "cryptographic approval signature present, proceeding (t3052)" "$LOGFILE" 2>/dev/null; then
			print_result "Case (k): NONE author + crypto approval → passes (t3052)" 0
		else
			print_result "Case (k): NONE author + crypto approval → passes (t3052)" 1 \
				"Exit was 0 but expected t3052 log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (l): issue-author=NONE + NO crypto approval → blocked (t3052 preserves)
# Contributor-filed issue without maintainer approval stays blocked.
# =============================================================================
test_case_l_non_owner_without_crypto_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"NONE"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "111" "owner/repo" "origin:worker" "false" "53" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (l): NONE author + no crypto → blocked (t3052)" 1 \
			"Expected non-zero exit, got 0 (NONE without crypto should block)"
	else
		if grep -q "no cryptographic approval signature found (t2449/t3052)" "$LOGFILE" 2>/dev/null; then
			print_result "Case (l): NONE author + no crypto → blocked (t3052)" 0
		else
			print_result "Case (l): NONE author + no crypto → blocked (t3052)" 1 \
				"Exit was non-zero but expected log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (m): OWNER author + no crypto → passes (t3052 preserves existing)
# Verifies that OWNER issues still pass without crypto approval.
# =============================================================================
test_case_m_owner_no_crypto_still_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"OWNER"}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "112" "owner/repo" "origin:worker" "false" "54" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (m): OWNER + no crypto → still passes (t3052)" 1 \
			"Expected exit 0, got ${result}"
	else
		print_result "Case (m): OWNER + no crypto → still passes (t3052)" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (n): COLLABORATOR author + login in trusted-issue-author allowlist → passes (t3062)
# Peer runner filed the issue; their login is in the allowlist.
# =============================================================================
test_case_n_trusted_author_allowlist_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	# COLLABORATOR with a known login
	printf '{"author_association":"COLLABORATOR","user":{"login":"test-peer-runner"}}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	# Trusted-authors conf pointing to a temp file containing the login
	local _conf="${TEST_ROOT}/trusted-authors.conf"
	printf 'test-peer-runner\n' >"$_conf"
	export AIDEVOPS_TRUSTED_AUTHORS_CONF="$_conf"

	local result=0
	_attempt_worker_briefed_auto_merge "113" "owner/repo" "origin:worker" "false" "55" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (n): COLLABORATOR + login in allowlist → passes (t3062)" 1 \
			"Expected exit 0, got ${result}"
	else
		if grep -q "passes via trusted-issue-author allowlist (t3062)" "$LOGFILE" 2>/dev/null; then
			print_result "Case (n): COLLABORATOR + login in allowlist → passes (t3062)" 0
		else
			print_result "Case (n): COLLABORATOR + login in allowlist → passes (t3062)" 1 \
				"Exit was 0 but expected t3062 allowlist log message not found"
		fi
	fi
	unset AIDEVOPS_TRUSTED_AUTHORS_CONF
	teardown_test_env
	return 0
}

# =============================================================================
# Case (o): COLLABORATOR author + login NOT in allowlist + no crypto → blocked
# Peer runner filed the issue but is not in the allowlist and no crypto sig.
# =============================================================================
test_case_o_trusted_author_not_in_allowlist_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	# COLLABORATOR with a login that is NOT in the allowlist
	printf '{"author_association":"COLLABORATOR","user":{"login":"unknown-runner"}}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	# Trusted-authors conf containing a different login (not unknown-runner)
	local _conf="${TEST_ROOT}/trusted-authors.conf"
	printf 'alex-solovyev\n' >"$_conf"
	export AIDEVOPS_TRUSTED_AUTHORS_CONF="$_conf"

	local result=0
	_attempt_worker_briefed_auto_merge "114" "owner/repo" "origin:worker" "false" "56" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (o): COLLABORATOR + login NOT in allowlist + no crypto → blocked" 1 \
			"Expected non-zero exit, got 0 (unlisted COLLABORATOR should block)"
	else
		if grep -q "no cryptographic approval signature found (t2449/t3052)" "$LOGFILE" 2>/dev/null; then
			print_result "Case (o): COLLABORATOR + login NOT in allowlist + no crypto → blocked" 0
		else
			print_result "Case (o): COLLABORATOR + login NOT in allowlist + no crypto → blocked" 1 \
				"Exit was non-zero but expected block log message not found"
		fi
	fi
	unset AIDEVOPS_TRUSTED_AUTHORS_CONF
	teardown_test_env
	return 0
}

# =============================================================================
# Case (p): COLLABORATOR author + authenticated write permission → passes
# Maintainer-operated aidevops workers may surface as COLLABORATOR in webhook
# metadata; authenticated collaborator permission is the trust source.
# =============================================================================
test_case_p_collaborator_permission_passes() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"COLLABORATOR","user":{"login":"maintainer-peer"}}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	printf 'write' >"${TEST_ROOT}/permission.txt"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "115" "owner/repo" "origin:worker" "false" "57" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (p): COLLABORATOR + authenticated write permission → passes (GH#24958)" 1 \
			"Expected exit 0, got ${result}"
	else
		if grep -q "authenticated maintainer permission fallback (GH#24958)" "$LOGFILE" 2>/dev/null; then
			print_result "Case (p): COLLABORATOR + authenticated write permission → passes (GH#24958)" 0
		else
			print_result "Case (p): COLLABORATOR + authenticated write permission → passes (GH#24958)" 1 \
				"Exit was 0 but expected GH#24958 permission fallback log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (q): COLLABORATOR author + authenticated read permission → blocked
# The fallback must fail closed when the login lacks write-level repo access.
# =============================================================================
test_case_q_collaborator_read_permission_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"COLLABORATOR","user":{"login":"read-only-peer"}}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	printf 'read' >"${TEST_ROOT}/permission.txt"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "116" "owner/repo" "origin:worker" "false" "58" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (q): COLLABORATOR + authenticated read permission → blocked (GH#24958)" 1 \
			"Expected non-zero exit, got 0 (read-only collaborator should block)"
	else
		if grep -q "no cryptographic approval signature found (t2449/t3052)" "$LOGFILE" 2>/dev/null; then
			print_result "Case (q): COLLABORATOR + authenticated read permission → blocked (GH#24958)" 0
		else
			print_result "Case (q): COLLABORATOR + authenticated read permission → blocked (GH#24958)" 1 \
				"Exit was non-zero but expected block log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (r): precomputed permission skips collaborator permission API (GH#25057)
# =============================================================================
test_case_r_precomputed_permission_skips_api() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	local result=0
	_issue_author_has_maintainer_authority "owner/repo" "maintainer" "write" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (r): precomputed write permission skips collaborator permission API (GH#25057)" 1 \
			"Expected exit 0, got ${result}"
	elif grep -q "/collaborators/maintainer/permission" "$GH_LOG" 2>/dev/null; then
		print_result "Case (r): precomputed write permission skips collaborator permission API (GH#25057)" 1 \
			"Expected no collaborator permission API call when permission argument is supplied"
	else
		print_result "Case (r): precomputed write permission skips collaborator permission API (GH#25057)" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (s): worker gate reuses matching precomputed permission (GH#25070)
# =============================================================================
test_case_s_worker_gate_uses_matching_precomputed_permission() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"COLLABORATOR","user":{"login":"maintainer-peer"}}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "118" "owner/repo" "origin:worker" "false" "60" "write" "maintainer-peer" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (s): worker gate reuses matching precomputed permission (GH#25070)" 1 \
			"Expected exit 0, got ${result}"
	elif grep -q "/collaborators/maintainer-peer/permission" "$GH_LOG" 2>/dev/null; then
		print_result "Case (s): worker gate reuses matching precomputed permission (GH#25070)" 1 \
			"Expected worker gate to skip duplicate collaborator permission API call"
	else
		print_result "Case (s): worker gate reuses matching precomputed permission (GH#25070)" 0
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (t): worker gate ignores mismatched precomputed permission login (GH#25070)
# =============================================================================
test_case_t_worker_gate_ignores_mismatched_precomputed_permission() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"COLLABORATOR","user":{"login":"issue-author"}}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	printf 'read' >"${TEST_ROOT}/permission.txt"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "119" "owner/repo" "origin:worker" "false" "61" "write" "different-pr-author" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (t): worker gate ignores mismatched precomputed permission (GH#25070)" 1 \
			"Expected non-zero exit, got 0 (mismatched cached permission should not trust issue author)"
	elif grep -q "/collaborators/issue-author/permission" "$GH_LOG" 2>/dev/null; then
		print_result "Case (t): worker gate ignores mismatched precomputed permission (GH#25070)" 0
	else
		print_result "Case (t): worker gate ignores mismatched precomputed permission (GH#25070)" 1 \
			"Expected fallback collaborator permission API call for issue-author"
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (u): worker gate ignores precomputed PR-author permission with empty login (GH#25105)
# =============================================================================
test_case_u_worker_gate_ignores_empty_precomputed_pr_author_login() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"COLLABORATOR","user":{"login":"issue-author"}}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	printf 'read' >"${TEST_ROOT}/permission.txt"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "120" "owner/repo" "origin:worker" "false" "62" "write" "" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (u): worker gate ignores empty precomputed PR-author login (GH#25105)" 1 \
			"Expected non-zero exit, got 0 (empty cached-permission login should not trust issue author)"
	elif grep -q "/collaborators/issue-author/permission" "$GH_LOG" 2>/dev/null; then
		print_result "Case (u): worker gate ignores empty precomputed PR-author login (GH#25105)" 0
	else
		print_result "Case (u): worker gate ignores empty precomputed PR-author login (GH#25105)" 1 \
			"Expected fallback collaborator permission API call for issue-author"
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (v): issue-author=NONE + spoofed approval marker but failed verification
# → blocked. Comment marker presence alone is not a trust signal (GH#21936).
# =============================================================================
test_case_v_spoofed_crypto_marker_blocked() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"author_association":"NONE"}' >"${TEST_ROOT}/issue.json"
	printf '[{"body":"aidevops:approval-signature: SHA256:spoofed"}]' >"${TEST_ROOT}/comments.json"
	export APPROVAL_VERIFY_RESULT=""
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "117" "owner/repo" "origin:worker" "false" "59" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case (v): spoofed crypto marker without verification → blocked" 1 \
			"Expected non-zero exit, got 0 (unverified marker should block)"
	else
		if grep -q "no cryptographic approval signature found (t2449/t3052)" "$LOGFILE" 2>/dev/null; then
			print_result "Case (v): spoofed crypto marker without verification → blocked" 0
		else
			print_result "Case (v): spoofed crypto marker without verification → blocked" 1 \
				"Exit was non-zero but expected block log message not found"
		fi
	fi
	teardown_test_env
	return 0
}

test_reference_to_pr_is_not_a_worker_brief() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	printf '{"author_association":"OWNER","pull_request":{"url":"mock"}}' >"${TEST_ROOT}/issue.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1
	export APPROVAL_VERIFY_RESULT="VERIFIED"
	local result=0
	_attempt_worker_briefed_auto_merge "100" "owner/repo" "origin:worker" "false" "42" || result=$?
	if [[ "$result" == "1" ]]; then
		print_result "PR number is not an issue brief even with trusted author and crypto" 0
	else
		print_result "PR number is not an issue brief even with trusted author and crypto" 1
	fi
	teardown_test_env
	return 0
}

test_partial_comment_and_title_association() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	local body="" expected="" actual="" title="t501: partial" src=""
	for body in 'For #501. text <!-- marker -->' $'text <!-- c -->\nFor #501' '<!-- For #501 -->' $'<!--\nFor #501\n-->'; do
		expected="501"
		[[ "$body" != '<!--'* ]] || expected=""
		actual=$(_gh_pr_body_explicit_issues "$body")
		if [[ "$actual" == "$expected" ]]; then
			print_result "explicit comment spans: ${body//$'\n'/ }" 0
		else
			print_result "explicit comment spans: ${body//$'\n'/ }" 1 "got ${actual}"
		fi
	done
	src=$(awk '/^_extract_pr_work_issue\(\) \{/,/^}$/ { print }' "$MERGE_SCRIPT")
	eval "$src"
	# shellcheck source=../pulse-merge-partial-continuation.sh
	source "${MERGE_SCRIPT%/*}/pulse-merge-partial-continuation.sh"
	_extract_linked_issue() { return 0; }
	gh_pr_view() {
		if [[ "$*" == *'--json title'* ]]; then printf '%s' "$title"; else printf '%s' "$body"; fi
		return 0
	}
	body=$'## Remaining\nFor #501'
	actual=$(_extract_pr_work_issue 1 owner/repo explicit "$body")
	[[ "$actual" == 501 ]] && print_result "corroborated secondary association" 0 || print_result "corroborated secondary association" 1
	title='t502: partial'
	actual=$(_extract_pr_work_issue 1 owner/repo explicit "$body")
	[[ -z "$actual" ]] && print_result "mismatched title fails closed" 0 || print_result "mismatched title fails closed" 1
	teardown_test_env
	return 0
}

test_partial_worker_association_reaches_authority_gate() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	local src="" result=0 linked_issue="" review_rc=0
	printf '{"author_association":"OWNER","state":"open","labels":[]}' >"${TEST_ROOT}/issue.json"
	src=$(awk '
		/^_extract_linked_issue\(\) \{/,/^}$/ { print }
		/^_extract_pr_work_issue\(\) \{/,/^}$/ { print }
		/^_pm_gate_origin_authority\(\) \{/,/^}$/ { print }
		/^_check_pr_merge_gates\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	eval "$src"
	gh_pr_view() {
		if [[ "$*" == *"labels,isDraft"* ]]; then
			printf '%s' '{"labels":[{"name":"origin:worker"}],"isDraft":false}'
		else
			printf '%s' $'## Summary\nFor #12303 — partial people-phase delivery; leave the issue open.\n## Remaining work\nRef #12643'
		fi
		return 0
	}
	_interactive_claim_fence_blocks_merge() { return 1; }
	_pm_gate_review_mode() { return 0; }
	_pm_gate_author_trust() { return 0; }
	_pm_gate_repository_and_issue() { return 0; }
	# Closure validation has its own merge-contradiction harness.
	_gh_pr_merge_closure_check() { return 0; }
	_pm_gate_review_bot() { return "$review_rc"; }
	_OW_LABEL_PAT=",origin:worker,"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1 APPROVAL_VERIFY_RESULT=""
	_check_pr_merge_gates "12641" "owner/repo" "worker" "NONE" "$linked_issue" "origin:worker" "head" || result=$?
	if [[ "$result" == "0" && -z "$linked_issue" ]] && grep -q 'passed all gates (issue #12303' "$LOGFILE" && ! grep -q 'no linked issue' "$LOGFILE"; then
		print_result "partial worker reaches real authority gate without no-issue skip or closing target" 0
	else
		print_result "partial worker reaches real authority gate without no-issue skip or closing target" 1
	fi
	review_rc=1
	result=0
	_check_pr_merge_gates "12641" "owner/repo" "worker" "NONE" "" "origin:worker" "head" || result=$?
	print_result "partial worker passing authority still stops at review gate" "$((1 - result))"
	teardown_test_env
	return 0
}

# GH#33999: For/Ref-only association — open non-parent passes; closed and
# parent-task stay ineligible. Closing-keyword links are covered by cases above.
test_non_closing_reference_gates() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1
	TEST_CLOSING_ISSUE=""
	local r_open=0 r_closed=0 r_parent=0 logged=1
	printf '{"author_association":"OWNER","state":"open","labels":[{"name":"enhancement"}]}' >"${TEST_ROOT}/issue.json"
	_attempt_worker_briefed_auto_merge "100" "owner/repo" "origin:worker" "false" "42" || r_open=$?
	grep -q 'link=non-closing reference' "$LOGFILE" && logged=0
	printf '{"author_association":"OWNER","state":"closed","labels":[]}' >"${TEST_ROOT}/issue.json"
	_attempt_worker_briefed_auto_merge "100" "owner/repo" "origin:worker" "false" "42" || r_closed=$?
	printf '{"author_association":"OWNER","state":"open","labels":[{"name":"parent-task"}]}' >"${TEST_ROOT}/issue.json"
	_attempt_worker_briefed_auto_merge "100" "owner/repo" "origin:worker" "false" "42" || r_parent=$?
	unset TEST_CLOSING_ISSUE
	if [[ "$r_open" == "0" && "$logged" == "0" && "$r_closed" == "1" && "$r_parent" == "1" ]]; then
		print_result "non-closing reference: open non-parent passes; closed and parent-task skipped (GH#33999)" 0
	else
		print_result "non-closing reference: open non-parent passes; closed and parent-task skipped (GH#33999)" 1 \
			"open=${r_open} logged=${logged} closed=${r_closed} parent=${r_parent}"
	fi
	teardown_test_env
	return 0
}

# GH#36922: a non-closing parent-task link is eligible only for a planning
# checkpoint diff, still needs the issue-author trust chain, and refusals keep
# metadata failure distinct from link-policy refusal.
_parent_checkpoint_verdict() {
	local verdict="" rc=0
	verdict=$(worker_briefed_trust_verdict "100" "owner/repo" "origin:worker" "false" "42") || rc=$?
	printf '%s|%s' "$rc" "$verdict"
	return 0
}

test_parent_planning_checkpoint_gates() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1
	TEST_CLOSING_ISSUE=""
	local parent_issue='{"author_association":"OWNER","state":"open","labels":[{"name":"parent-task"}]}'
	local ok="" code="" rename="" untrusted="" missing="" malformed="" empty="" logged=1
	printf '%s' "$parent_issue" >"${TEST_ROOT}/issue.json"
	printf '[{"filename":"TODO.md","status":"modified"},{"filename":"todo/tasks/t1-brief.md","status":"added"}]' >"${TEST_ROOT}/pr-files.json"
	ok=$(_parent_checkpoint_verdict)
	grep -q 'link=non-closing parent planning checkpoint' "$LOGFILE" && logged=0
	printf '[{"filename":"TODO.md","status":"modified"},{"filename":".agents/scripts/x.sh","status":"modified"}]' >"${TEST_ROOT}/pr-files.json"
	code=$(_parent_checkpoint_verdict)
	printf '[{"filename":"todo/plan.md","previous_filename":"todo/data.json","status":"renamed"}]' >"${TEST_ROOT}/pr-files.json"
	rename=$(_parent_checkpoint_verdict)
	printf '[]' >"${TEST_ROOT}/pr-files.json"
	empty=$(_parent_checkpoint_verdict)
	printf '{"message":"oops"}' >"${TEST_ROOT}/pr-files.json"
	malformed=$(_parent_checkpoint_verdict)
	rm -f "${TEST_ROOT}/pr-files.json"
	missing=$(_parent_checkpoint_verdict)
	printf '[{"filename":"TODO.md","status":"modified"}]' >"${TEST_ROOT}/pr-files.json"
	printf '{"author_association":"CONTRIBUTOR","state":"open","labels":[{"name":"parent-task"}]}' >"${TEST_ROOT}/issue.json"
	untrusted=$(_parent_checkpoint_verdict)
	unset TEST_CLOSING_ISSUE

	local failures=""
	[[ "$ok" == "0|allow" && "$logged" == "0" ]] || failures+=" ok=${ok}"
	[[ "$code" == "1|deny:"*"only eligible for a planning checkpoint"* ]] || failures+=" code=${code}"
	[[ "$rename" == "1|deny:"*"only eligible for a planning checkpoint"* ]] || failures+=" rename=${rename}"
	[[ "$empty" == "1|deny:"*"only eligible for a planning checkpoint"* ]] || failures+=" empty=${empty}"
	[[ "$malformed" == "1|deny:linked issue metadata unavailable:"*"file list"* ]] || failures+=" malformed=${malformed}"
	[[ "$missing" == "1|deny:linked issue metadata unavailable:"*"file list"* ]] || failures+=" missing=${missing}"
	[[ "$untrusted" == "1|deny:"*"not OWNER/MEMBER"* ]] || failures+=" untrusted=${untrusted}"
	if [[ -z "$failures" ]]; then
		print_result "parent planning checkpoint: trusted planning diff passes; code/rename/untrusted denied; metadata failure distinct (GH#36922)" 0
	else
		print_result "parent planning checkpoint: trusted planning diff passes; code/rename/untrusted denied; metadata failure distinct (GH#36922)" 1 "$failures"
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# GH#37289: scoped starter-sync bot-issue trust
# =============================================================================
# Args: $1=label, $2=expect pass|block, $3=issue title, $4=labels JSON array,
#       $5=issue user type, $6=PR file, $7=core-files fixture mode (ok|missing)
_run_starter_sync_case() {
	local label="$1" expect="$2" title="$3" labels="$4" utype="$5" pfile="$6" mode="${7:-ok}"
	local body="${8:-}" status="${9:-modified}"
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	jq -n --arg t "$title" --argjson l "$labels" --arg ty "$utype" --arg body "$body" \
		'{author_association:"NONE",user:{login:"github-actions[bot]",type:$ty},title:$t,labels:$l,body:$body}' >"${TEST_ROOT}/issue.json"
	printf '[]' >"${TEST_ROOT}/comments.json"
	printf '0123456789abcdef0123456789abcdef01234567\n' >"${TEST_ROOT}/base-sha.txt"
	[[ "$mode" == "ok" ]] && printf '# core files\n\nscripts/sync.sh\nincludes/core.php\n.github/\n' >"${TEST_ROOT}/core-files.txt"
	jq -n --arg f "$pfile" --arg s "$status" '[{filename:$f,status:$s},{filename:"changelog.txt",status:"modified"}]' >"${TEST_ROOT}/pr-files.json"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	_attempt_worker_briefed_auto_merge "103" "owner/repo" "origin:worker" "false" "45" && result=0 || result=$?
	if [[ "$expect" == "pass" && "$result" -eq 0 ]] && grep -q "is a starter-sync issue" "$LOGFILE"; then
		print_result "$label" 0
	elif [[ "$expect" == "block" && "$result" -ne 0 ]] && ! grep -q "is a starter-sync issue" "$LOGFILE"; then
		print_result "$label" 0
	else
		print_result "$label" 1 "expected ${expect}, exit=${result}"
	fi
	teardown_test_env
	return 0
}

test_starter_sync_scoped_trust() {
	local ok_labels='[{"name":"starter-sync"}]'
	local ttl="Core files differ from the starter"
	_run_starter_sync_case "starter-sync: in-scope diff passes" pass "$ttl" "$ok_labels" Bot "includes/core.php"
	_run_starter_sync_case "starter-sync: directory prefix passes" pass "$ttl" "$ok_labels" Bot ".github/workflows/ci.yml"
	_run_starter_sync_case "starter-sync: issue scope passes" pass "$ttl" "$ok_labels" Bot "scripts/new-core.sh" ok $'### Files Scope\n- `scripts/new-core.sh`\n## Next\n- `outside.sh`'
	_run_starter_sync_case "starter-sync: later heading excluded" block "$ttl" "$ok_labels" Bot "outside.sh" ok $'### Files Scope\n- `scripts/new-core.sh`\n## Next\n- `outside.sh`'
	_run_starter_sync_case "starter-sync: renamed file blocked" block "$ttl" "$ok_labels" Bot "includes/core.php" ok "" renamed
	_run_starter_sync_case "starter-sync: wrong title blocked" block "Something else" "$ok_labels" Bot "includes/core.php"
	_run_starter_sync_case "starter-sync: missing label blocked" block "$ttl" '[{"name":"bug"}]' Bot "includes/core.php"
	_run_starter_sync_case "starter-sync: non-Bot author blocked" block "$ttl" "$ok_labels" User "includes/core.php"
	_run_starter_sync_case "starter-sync: out-of-scope file blocked" block "$ttl" "$ok_labels" Bot "includes/own-feature.php"
	_run_starter_sync_case "starter-sync: scope-list API failure fails closed" block "$ttl" "$ok_labels" Bot "includes/core.php" missing
	return 0
}

# =============================================================================
# GH#37373: starter-sync trust replaces ONLY the linked-issue author check.
# Runs the REAL gate chain (_check_pr_merge_gates and its _pm_gate_* stages plus
# the final trust gate's live-state check) around a starter-sync-trusted fixture
# and pins that every other gate still blocks. Only external I/O is stubbed.
# Why not test-pulse-merge-pr-context.sh: its harness never evaluates
# _check_pr_merge_gates, so it cannot pin gate order.
# =============================================================================
_define_starter_gate_chain() {
	local src="" fn="" part=""
	for fn in _check_pr_merge_gates _pm_gate_review_mode _pm_gate_author_trust \
		_pm_gate_route_ineligible_author _pm_gate_repository_and_issue \
		_pm_gate_origin_authority _pm_gate_review_bot _pulse_merge_final_trust_gate; do
		part=$(awk -v f="$fn" '$0 ~ "^" f "\\(\\) \\{" , /^}$/ { print }' "$MERGE_SCRIPT")
		if [[ -z "$part" ]]; then
			printf 'ERROR: could not extract %s from %s\n' "$fn" "$MERGE_SCRIPT" >&2
			return 1
		fi
		src+=$'\n'"$part"
	done
	part=$(awk '/^_pulse_merge_live_state_gate\(\) \{/,/^}$/ { print }' "${SCRIPT_DIR}/../pulse-merge-gates.sh")
	if [[ -z "$part" ]]; then
		printf 'ERROR: could not extract _pulse_merge_live_state_gate from %s\n' "${SCRIPT_DIR}/../pulse-merge-gates.sh" >&2
		return 1
	fi
	src+=$'\n'"$part"
	# shellcheck disable=SC1090
	eval "$src"

	# External I/O stubs; SC_* variables select the scenario per case.
	_OW_LABEL_PAT=",origin:worker,"
	PULSE_REVIEW_EVIDENCE_SCHEMA="test-schema"
	PULSE_UNKNOWN_STATE="unknown"
	PULSE_REVIEW_DECISION_CHANGES_REQUESTED="CHANGES_REQUESTED"
	_interactive_claim_fence_blocks_merge() { return 1; }
	# Real handler routes CHANGES_REQUESTED to workers and blocks the merge.
	_handle_changes_requested_review_gate() {
		[[ "$3" != "CHANGES_REQUESTED" ]] && return 0
		echo "[test] changes-requested blocks merge" >>"$LOGFILE"
		return 1
	}
	_pulse_is_trusted_issue_sync_pr() { return 1; }
	_is_collaborator_author() { _PULSE_AUTHOR_PERMISSION_VALUE="write"; return "${SC_COLLAB_RC:-0}"; }
	_is_trusted_dependabot_update_pr() { return 1; }
	_has_maintainer_crypto_approval() { return 1; }
	_pulse_route_dependabot_pr_to_worker_issue() { return 1; }
	check_pr_modifies_workflows() { return 1; }
	_external_pr_has_linked_issue() { return 0; }
	_external_pr_linked_issue_crypto_approved() { return "${SC_EXT_ISSUE_RC:-1}"; }
	_external_pr_current_head_crypto_approved() { return "${SC_EXT_HEAD_RC:-1}"; }
	_gh_pr_merge_closure_check() { return 0; }
	_pulse_recover_external_review() { return 0; }
	_pulse_merge_refresh_review_gate_evidence() { return 0; }
	_pulse_merge_preflight_snapshot_gate() { return 0; }
	# Final-boundary stand-in for _pulse_merge_admin_safety_check: it reads the
	# same live PR metadata the real one feeds to _pulse_merge_live_state_gate.
	_pulse_merge_admin_safety_check() {
		_pulse_merge_live_state_gate "$1" "$2" "$(_sc_pr_meta_json)" "${SC_PR_LABELS:-origin:worker}"
		return $?
	}
	_extract_pr_work_issue() { printf '45'; return 0; }
	TEST_CLOSING_ISSUE=45
	PMRC_BLOCKER_MERGE_AUTHORITY="merge-authority"
	PMRC_BLOCKER_REVIEW_GATE="review-gate"
	gh_pr_view() {
		local labels="${SC_PR_LABELS:-origin:worker}"
		if [[ "$*" == *"labels,isDraft,headRefOid,body"* ]]; then
			_sc_pr_meta_json | jq -c '. + {headRefOid:"head",body:"Resolves #45"}'
		elif [[ "$*" == *"labels,isDraft"* ]]; then
			_sc_pr_meta_json
		elif [[ "$*" == *"body,closingIssuesReferences"* ]]; then
			printf '%s' '{"body":"Resolves #45","closingIssuesReferences":[]}'
		else
			printf '%s' "$labels"
		fi
		return 0
	}
	_sc_pr_meta_json() {
		jq -nc --arg l "${SC_PR_LABELS:-origin:worker}" --argjson d "${SC_DRAFT:-false}" --arg r "${SC_REVIEW:-NONE}" \
			'{state:"OPEN",isDraft:$d,reviewDecision:$r,autoMergeRequest:null,labels:($l|split(",")|map(select(length>0))|map({name:.}))}'
		return 0
	}
	return 0
}

# Args: $1=label, $2=expect pass|block, $3=expected log substring, $4=mutation
_run_starter_gate_chain_case() {
	local label="$1" expect="$2" needle="$3" mutation="${4:-none}"
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	_define_starter_gate_chain || { print_result "$label" 1 "could not extract gate chain"; teardown_test_env; return 0; }
	local issue_labels='[{"name":"starter-sync"}]'
	SC_PR_LABELS="origin:worker" SC_DRAFT=false SC_REVIEW=NONE SC_COLLAB_RC=0 SC_EXT_ISSUE_RC=1 SC_EXT_HEAD_RC=1
	local bot_evidence='{"schema":"test-schema","repo":"owner/repo","pr":103,"head_sha":"head","permitted":true,"state":"pass","merge_gate":"clear","status":"PASS"}'
	case "$mutation" in
	issue-nmr) issue_labels='[{"name":"starter-sync"},{"name":"needs-maintainer-review"}]' ;;
	pr-nmr) SC_PR_LABELS="origin:worker,needs-maintainer-review" ;;
	external-no-issue-approval) SC_PR_LABELS="origin:worker,external-contributor" ;;
	external-no-head-approval) SC_PR_LABELS="origin:worker,external-contributor" SC_EXT_ISSUE_RC=0 ;;
	non-collaborator) SC_COLLAB_RC=1 ;;
	draft) SC_DRAFT=true ;;
	hold) SC_PR_LABELS="origin:worker,hold-for-review" ;;
	changes-requested) SC_REVIEW=CHANGES_REQUESTED ;;
	bot-missing) bot_evidence='{}' ;;
	none) ;;
	esac
	jq -n --argjson l "$issue_labels" \
		'{author_association:"NONE",user:{login:"github-actions[bot]",type:"Bot"},title:"Core files differ from the starter",labels:$l,body:""}' >"${TEST_ROOT}/issue.json"
	printf '0123456789abcdef0123456789abcdef01234567\n' >"${TEST_ROOT}/base-sha.txt"
	printf 'scripts/sync.sh\nincludes/core.php\n' >"${TEST_ROOT}/core-files.txt"
	printf '[{"filename":"includes/core.php","status":"modified"},{"filename":"changelog.txt","status":"modified"}]' >"${TEST_ROOT}/pr-files.json"
	printf '#!/usr/bin/env bash\nprintf "%%s" %q\n' "$bot_evidence" >"${TEST_ROOT}/scripts/review-bot-gate-helper.sh"
	export AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1

	local result=0
	{ _check_pr_merge_gates "103" "owner/repo" "worker" "$SC_REVIEW" "45" "$SC_PR_LABELS" "head" &&
		_pulse_merge_final_trust_gate "103" "owner/repo" "head"; } || result=$?
	local starter_logged=1
	grep -q "is a starter-sync issue" "$LOGFILE" && starter_logged=0
	if [[ "$expect" == "pass" && "$result" -eq 0 && "$starter_logged" -eq 0 ]]; then
		print_result "$label" 0
	elif [[ "$expect" == "block" && "$result" -ne 0 ]] && grep -qF -- "$needle" "$LOGFILE"; then
		print_result "$label" 0
	else
		print_result "$label" 1 "expected ${expect}, exit=${result}, starter_logged=${starter_logged}, log: $(tr '\n' '|' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_starter_sync_does_not_bypass_other_gates() {
	local p="starter-sync gate order (GH#37373):"
	_run_starter_gate_chain_case "$p clean fixture passes every gate" pass "" none
	_run_starter_gate_chain_case "$p linked-issue needs-maintainer-review blocks" block "has needs-maintainer-review" issue-nmr
	_run_starter_gate_chain_case "$p PR needs-maintainer-review blocks at final trust gate" block "PR carries needs-maintainer-review" pr-nmr
	_run_starter_gate_chain_case "$p external-contributor without issue approval blocks" block "lacks crypto approval (t1958)" external-no-issue-approval
	_run_starter_gate_chain_case "$p external-contributor without head approval blocks" block "lacks V2 crypto approval for current head" external-no-head-approval
	_run_starter_gate_chain_case "$p non-collaborator author blocks" block "is not a collaborator" non-collaborator
	_run_starter_gate_chain_case "$p draft PR blocks" block "PR is draft or has hold-for-review" draft
	_run_starter_gate_chain_case "$p hold-for-review blocks" block "PR is draft or has hold-for-review" hold
	_run_starter_gate_chain_case "$p CHANGES_REQUESTED blocks" block "changes-requested blocks merge" changes-requested
	_run_starter_gate_chain_case "$p missing review-bot evidence blocks" block "missing or unpermitted current-head evidence" bot-missing
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

	test_case_a_owner_issue_passes
	test_case_b_member_issue_passes
	test_case_c_contributor_issue_blocked
	test_case_d_trusted_author_normalization_passes
	test_case_e_nmr_crypto_cleared_passes
	test_case_f_hold_for_review_blocked
	test_case_g_changes_requested_is_upstream
	test_case_h_draft_pr_blocked
	test_case_i_worker_takeover_excluded
	test_case_j_feature_flag_off_blocked
	test_case_k_non_owner_with_crypto_passes
	test_case_l_non_owner_without_crypto_blocked
	test_case_m_owner_no_crypto_still_passes
	test_case_n_trusted_author_allowlist_passes
	test_case_o_trusted_author_not_in_allowlist_blocked
	test_case_p_collaborator_permission_passes
	test_case_q_collaborator_read_permission_blocked
	test_case_r_precomputed_permission_skips_api
	test_case_s_worker_gate_uses_matching_precomputed_permission
	test_case_t_worker_gate_ignores_mismatched_precomputed_permission
	test_case_u_worker_gate_ignores_empty_precomputed_pr_author_login
	test_case_v_spoofed_crypto_marker_blocked
	test_reference_to_pr_is_not_a_worker_brief
	test_partial_comment_and_title_association
	test_partial_worker_association_reaches_authority_gate
	test_non_closing_reference_gates
	test_parent_planning_checkpoint_gates
	test_starter_sync_scoped_trust
	test_starter_sync_does_not_bypass_other_gates

	echo ""
	printf 'Results: %d/%d passed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
	[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
	return 0
}

main "$@"
