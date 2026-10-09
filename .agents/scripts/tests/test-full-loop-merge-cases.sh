#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-full-loop-merge-cases.sh — Merge transport, readiness, and publication cases
#
# Verifies:
#   1. Admin fallback fires all three signaling artifacts (PR comment, audit log, label)
#   2. Explicit --admin caller does NOT trigger extra signaling (back-compat)
#   3. Non-branch-protection errors do NOT trigger fallback
#   4. GraphQL rate-limit errors fall back to REST pull merge after the gate
#   5. Review-gate failures prevent both CLI merge and REST fallback
#   6. Interactive --auto review-policy blocks fall through to --admin only
#      after PR readiness and maintainer-review gates pass
#   7. Post-merge verification retries cache-disabled reads without replaying
#      the irreversible merge mutation
#   8. Squash merges use the validated PR title as an explicit subject and
#      reject invalid titles before any merge mutation
#   9. timeout_sec's no-coreutils fallback passes stdin through, so the
#      prospective TODO guard materializes blobs without timeout/gtimeout
#
# Strategy: stub gh, audit-log-helper.sh, and gh-signature-helper.sh in a temp
# directory prepended to PATH, then source the merge sub-library.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Definitions only; test-full-loop-merge.sh owns setup and execution.
[[ -n "${_TEST_FULL_LOOP_MERGE_CASES_LOADED:-}" ]] && return 0
_TEST_FULL_LOOP_MERGE_CASES_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_merge_cases_path="${BASH_SOURCE[0]%/*}"
	[[ "$_merge_cases_path" == "${BASH_SOURCE[0]}" ]] && _merge_cases_path="."
	SCRIPT_DIR="$(cd "$_merge_cases_path" && pwd)"
	unset _merge_cases_path
fi

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
HANDOFF_ROOT=""
HANDOFF_REPO=""
HANDOFF_RECEIPT_DIR=""
HANDOFF_RECEIPT=""
HANDOFF_SOURCE_HEAD=""
HANDOFF_PUBLISHED_COMMIT=""

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
	mkdir -p "${TEST_ROOT}/logs"

	# Stub gh-signature-helper.sh
	cat >"${TEST_ROOT}/bin/gh-signature-helper.sh" <<'STUB'
#!/usr/bin/env bash
echo "---"
echo "test-signature-footer"
STUB
	chmod +x "${TEST_ROOT}/bin/gh-signature-helper.sh"

	# Stub audit-log-helper.sh — records invocations to a log file
	cat >"${TEST_ROOT}/bin/audit-log-helper.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "${TEST_ROOT}/logs/audit-log-calls.txt"
STUB
	chmod +x "${TEST_ROOT}/bin/audit-log-helper.sh"

	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

write_gh_stub_header() {
	local mode="$1"

	cat >"${TEST_ROOT}/bin/gh" <<GHSTUB
#!/usr/bin/env bash
# Log all gh calls
_gh_cmd="\$1"
_gh_sub="\$2"
echo "gh \$*" >> "${TEST_ROOT}/logs/gh-calls.txt"

_merge_count_file="${TEST_ROOT}/logs/merge-count.txt"

if [[ "\$_gh_cmd" == "pr" && "\$_gh_sub" == "merge" ]]; then
	if [[ "$mode" == "stale-cache-401" ]]; then
		_merge_count=0
		if [[ -f "\$_merge_count_file" ]]; then
			_merge_count=\$(cat "\$_merge_count_file")
		fi
		_merge_count=\$((_merge_count + 1))
		printf '%s\n' "\$_merge_count" >"\$_merge_count_file"
		if [[ "\$_merge_count" -eq 1 ]]; then
			echo 'non-200 OK status code: 401 Unauthorized body: "{ \"message\": \"Requires authentication\" }"' >&2
			exit 1
		fi
		echo "Merged PR after cache remediation"
		exit 0
	fi

	# Check if --admin flag is present
	_gh_has_admin=0
	for _gh_arg in "\$@"; do
		if [[ "\$_gh_arg" == "--admin" ]]; then
			_gh_has_admin=1
		fi
	done
	if [[ "$mode" == "primary-timeout-policy-open" ]]; then
		echo "base branch policy prohibits the merge" >&2
		exit 124
	fi
	if [[ "$mode" == "pending-policy" ]]; then
		echo "base branch policy prohibits the merge" >&2
		exit 1
	fi

	if [[ "$mode" == "fallback" || "$mode" == "fallback-nmr" || "$mode" == "fallback-native-review" ||
		"$mode" == "auto-review-required" || "$mode" == "auto-review-required-admin-block" ||
		"$mode" == "fallback-timeout-merged" || "$mode" == "fallback-timeout-open" ]]; then
		if [[ "\$_gh_has_admin" -eq 1 ]]; then
			if [[ "$mode" == "fallback-timeout-merged" || "$mode" == "fallback-timeout-open" ]]; then
				exit 124
			fi
			if [[ "$mode" == "fallback-native-review" || "$mode" == "auto-review-required-admin-block" ]]; then
				echo "At least 1 approving review is required" >&2
				exit 1
			fi
			echo "Merged PR"
			exit 0
		elif [[ "$mode" == "auto-review-required" || "$mode" == "auto-review-required-admin-block" ]]; then
			echo "At least 1 approving review is required; cannot approve your own pull request" >&2
			exit 1
		else
			echo "At least 1 approving review is required" >&2
			exit 1
		fi
	elif [[ "$mode" == "explicit-admin" ]]; then
		echo "Merged PR"
		exit 0
	elif [[ "$mode" == "other-error" ]]; then
		echo "Something completely different went wrong" >&2
		exit 1
	elif [[ "$mode" == "graphql-rate-limit" || "$mode" == "graphql-rate-limit-rest-fail" ]]; then
		echo "GraphQL: API rate limit already exceeded for user ID 12345. (rateLimitExceeded)" >&2
		exit 1
	fi
fi

if [[ "\$_gh_cmd" == "pr" && "\$_gh_sub" == "view" && "\$*" == *"--json state,mergedAt,mergeCommit"* ]]; then
	case "$mode" in
	fallback-timeout-merged) echo '{"state":"MERGED","mergedAt":"2026-08-24T00:00:00Z","mergeCommit":{"oid":"merged123sha"},"headRefOid":"abc123headsha"}'; exit 0 ;;
	fallback-timeout-open | primary-timeout-policy-open) echo '{"state":"OPEN","mergedAt":null,"mergeCommit":null,"headRefOid":"abc123headsha"}'; exit 0 ;;
	esac
fi
GHSTUB
	return 0
}

write_gh_stub_pr_issue_views() {
	local mode="$1"

	cat >>"${TEST_ROOT}/bin/gh" <<GHSTUB

	if [[ "\$_gh_cmd" == "pr" && "\$_gh_sub" == "view" ]]; then
	if [[ "\$*" == *"--json title,commits"* ]]; then
		case "$mode" in
		invalid-squash-title)
			echo '{"title":"Document recovery","commits":[{"messageHeadline":"fix: document recovery"}]}'
			;;
		gh-prefix-feature)
			echo '{"title":"GH#29530: Add a Buzz-scoped OpenCode Tabby workspace profile","commits":[{"messageHeadline":"feat: add Buzz Tabby workspace profile"}]}'
			;;
		gh-prefix-no-evidence)
			echo '{"title":"GH#29530: Add a Buzz-scoped OpenCode Tabby workspace profile","commits":[{"messageHeadline":"wip: add Buzz Tabby workspace profile"}]}'
			;;
		*)
			echo '{"title":"GH#28721: fix: preserve reviewed squash subject","commits":[{"messageHeadline":"wip: document recovery"}]}'
			;;
		esac
		exit 0
	fi
	if [[ "\$*" == *"--json state,isDraft,reviewDecision,headRefOid"* ]]; then
		_review_decision=""
		[[ "$mode" == "late-review-block" ]] && _review_decision="CHANGES_REQUESTED"
		printf '{"state":"OPEN","isDraft":false,"reviewDecision":"%s","headRefOid":"abc123headsha"}\n' "\$_review_decision"
		exit 0
	fi
	if [[ "\$*" == *"--json state,mergedAt,mergeCommit"* ]]; then
		_evidence_count=0
		if [[ -f "${TEST_ROOT}/logs/evidence-count.txt" ]]; then
			_evidence_count=\$(<"${TEST_ROOT}/logs/evidence-count.txt")
		fi
		_evidence_count=\$((_evidence_count + 1))
		printf '%s\n' "\$_evidence_count" >"${TEST_ROOT}/logs/evidence-count.txt"
		printf '%s\n' "\${AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE:-0}" >>"${TEST_ROOT}/logs/evidence-cache-control.txt"
		case "$mode" in
		post-merge-api-failure) exit 70 ;;
		post-merge-unmerged) echo '{"state":"OPEN","mergedAt":null,"mergeCommit":null}'; exit 0 ;;
		post-merge-stale)
			if [[ "\$_evidence_count" -eq 1 ]]; then
				echo '{"state":"OPEN","mergedAt":null,"mergeCommit":null}'
				exit 0
			fi
			;;
		esac
		echo '{"state":"MERGED","mergedAt":"2026-07-11T00:00:00Z","mergeCommit":{"oid":"merged123sha"}}'
		exit 0
	fi
	if [[ "\$*" == *"--json author,labels,isCrossRepository,headRefOid,closingIssuesReferences,body"* ]]; then
		if [[ "$mode" == "fallback-nmr" ]]; then
			echo '{"author":{"login":"tester"},"labels":[],"isCrossRepository":false,"headRefOid":"abc123headsha","closingIssuesReferences":[{"number":24354}],"body":"Resolves #22621"}'
		else
			echo '{"author":{"login":"tester"},"labels":[],"isCrossRepository":false,"headRefOid":"abc123headsha","closingIssuesReferences":[],"body":"Resolves #22621"}'
		fi
		exit 0
	fi
	if [[ "\$*" == *"--json isDraft,reviewDecision,statusCheckRollup"* ]]; then
		if [[ "$mode" == "auto-review-required" ]]; then
			echo '{"isDraft":false,"reviewDecision":"","statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS","status":"COMPLETED"}]}'
		else
			echo '{"isDraft":false,"reviewDecision":"","statusCheckRollup":[]}'
		fi
		exit 0
	fi
	if [[ "\$*" == *"--json closingIssuesReferences,body"* ]]; then
		if [[ "$mode" == "fallback-nmr" ]]; then
			echo '{"closingIssuesReferences":[{"number":24354}],"body":"Resolves #22621"}'
		else
			echo '{"closingIssuesReferences":[],"body":"Resolves #22621"}'
		fi
		exit 0
	fi
	if [[ "\$*" == *"--json closingIssuesReferences"* ]]; then
		if [[ "$mode" == "fallback-nmr" ]]; then
			echo '24354'
		else
			echo ''
		fi
		exit 0
	fi
	if [[ "\$*" == *"--json body"* ]]; then
		echo 'Resolves #22621'
		exit 0
	fi
	echo '{}'
	exit 0
fi

if [[ "\$_gh_cmd" == "issue" && "\$_gh_sub" == "view" ]]; then
	if [[ "$mode" == "fallback-nmr" ]]; then
		echo 'needs-maintainer-review'
	else
		echo ''
	fi
	exit 0
fi
GHSTUB
	return 0
}

write_gh_stub_api() {
	local mode="$1"

	cat >>"${TEST_ROOT}/bin/gh" <<GHSTUB

if [[ "\$_gh_cmd" == "api" ]]; then
	echo "gh api \$*" >> "${TEST_ROOT}/logs/gh-api-calls.txt"
	# Headless merge authority checks linked issues for trusted PR-only scope.
	# Ordinary merge fixtures have an OWNER-authored brief without that marker.
	if [[ "\${2:-}" =~ ^repos/testorg/testrepo/issues/[1-9][0-9]*$ ]]; then
		echo '{"author_association":"OWNER","body":"Ordinary merge task"}'
		exit 0
	fi
	# The comment wrapper's public-write guard must know target visibility. Keep
	# this synthetic repository private so the signaling test exercises comment
	# transport without depending on the host's privacy cache or entity inventory.
	if [[ "\${2:-}" == "repos/testorg/testrepo" && "\$*" == *".private"* ]]; then
		echo 'true'
		exit 0
	fi
	if [[ "\$*" == "user" ]]; then
		echo '{"login":"tester"}'
		exit 0
	fi
	if [[ "\$*" == *"repos/testorg/testrepo/collaborators/tester/permission"* ]]; then
		if [[ "\$*" == *" -i "* ]]; then
			printf 'HTTP/2 200\ncontent-type: application/json\n\n{"permission":"write"}\n'
		else
			echo 'write'
		fi
		exit 0
	fi
	if [[ "\$*" == *"repos/testorg/testrepo/pulls/42/merge"* ]]; then
		if [[ "$mode" == "graphql-rate-limit-rest-fail" ]]; then
			echo "REST merge failed" >&2
			exit 1
		fi
		echo '{"merged":true,"message":"Pull Request successfully merged"}'
		exit 0
	fi
	if [[ "\$*" == *"repos/testorg/testrepo/pulls/42"* ]]; then
		if [[ "$mode" == "head-fetch-failure" ]]; then
			echo 'transient pull lookup failure' >&2
			exit 1
		fi
		echo 'abc123headsha'
		exit 0
	fi
	echo '{}'
	exit 0
fi
GHSTUB
	return 0
}

write_gh_stub_pr_mutations() {
	cat >>"${TEST_ROOT}/bin/gh" <<GHSTUB

if [[ "\$_gh_cmd" == "pr" && "\$_gh_sub" == "comment" ]]; then
	echo "pr comment \$*" >> "${TEST_ROOT}/logs/pr-comments.txt"
	exit 0
fi

if [[ "\$_gh_cmd" == "pr" && "\$_gh_sub" == "edit" ]]; then
	echo "pr edit \$*" >> "${TEST_ROOT}/logs/pr-edits.txt"
	exit 0
fi

# Default: succeed silently
exit 0
GHSTUB
	return 0
}

# Create a gh stub that simulates merge behavior.
# Args:
#   $1 = "fallback" — first merge fails with branch-protection error, --admin succeeds
#   $2 = "explicit-admin" — merge with --admin succeeds immediately (no fallback)
#   $3 = "other-error" — merge fails with non-branch-protection error
#   $4 = "graphql-rate-limit" — gh pr merge fails with GraphQL quota, REST succeeds
#   $5 = "graphql-rate-limit-rest-fail" — gh pr merge fails with GraphQL quota, REST fails
#   $6 = "fallback-nmr" — branch protection fails, but linked issue still needs maintainer review
#   $7 = "stale-cache-401" — first gh pr merge returns cached 401, live auth succeeds, retry succeeds
#   $8 = "auto-review-required" — --auto is blocked only by self-review policy; --admin succeeds
create_gh_stub() {
	local mode="$1"

	write_gh_stub_header "$mode"
	write_gh_stub_pr_issue_views "$mode"
	write_gh_stub_api "$mode"
	write_gh_stub_pr_mutations
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

# Run _merge_execute in an isolated subprocess.
# Sources the full-loop merge sub-library directly with shared constants loaded
# so we get merge functions without invoking the full-loop main entrypoint.
# Args: pr_number repo merge_method has_admin has_auto
run_merge_execute() {
	local pr_number="$1"
	local repo="$2"
	local merge_method="$3"
	local has_admin="$4"
	local has_auto="$5"

	local scripts_dir="${SCRIPT_DIR}/.."

	# Build a temporary script that sources the merge helper in isolation.
	# Using a temp file avoids heredoc/process-substitution escaping issues with $.
	local tmp_runner=""
	tmp_runner=$(mktemp)
	cat >"$tmp_runner" <<RUNNER_EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${scripts_dir}'
source '${scripts_dir}/shared-constants.sh'
source '${scripts_dir}/full-loop-helper-merge.sh'
_merge_guard_prospective_todo() { return 0; }
if [[ -n "\${MERGE_TEST_REQUIRED_CHECKS_RC:-}" ]]; then
	_merge_admin_fallback_required_checks_clear() { printf '%s\n' 'LIFECYCLE_STATE=CHECKS_PENDING'; return "\${MERGE_TEST_REQUIRED_CHECKS_RC}"; }
else
	_merge_admin_fallback_required_checks_clear() { return 0; }
fi
_merge_execute '$pr_number' '$repo' '$merge_method' '$has_admin' '$has_auto'
RUNNER_EOF
	chmod +x "$tmp_runner"

	# Run in a subprocess with our stubs on PATH
	local rc=0
	env PATH="${TEST_ROOT}/bin:${scripts_dir}:${PATH}" \
		HOME="${TEST_ROOT}/home" \
		FULL_LOOP_HEADLESS="${FULL_LOOP_HEADLESS:-}" \
		FULL_LOOP_VERIFIED_PR_HEAD_SHA="${FULL_LOOP_VERIFIED_PR_HEAD_SHA:-}" \
		AIDEVOPS_HEADLESS= \
		Claude_HEADLESS= \
		GITHUB_ACTIONS= \
		AIDEVOPS_MODEL="test-model" \
		bash "$tmp_runner" 2>&1 || rc=$?
	rm -f "$tmp_runner"
	return $rc
}

# Run cmd_merge in an isolated subprocess with a controlled review-bot gate.
# Args: pr_number repo gate_rc [gate_kind] [gate_detail]
run_cmd_merge_with_gate() {
	local pr_number="$1"
	local repo="$2"
	local gate_rc="$3"
	local gate_kind="${4:-review-bot}"
	local gate_detail="${5:-}"
	local scripts_dir="${SCRIPT_DIR}/.."
	local tmp_runner=""
	tmp_runner=$(mktemp)
	cat >"$tmp_runner" <<RUNNER_EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${scripts_dir}'
source '${scripts_dir}/shared-constants.sh'
source '${scripts_dir}/full-loop-helper-merge.sh'
cmd_pre_merge_gate() {
	FULL_LOOP_PRE_MERGE_BLOCKER_KIND='${gate_kind}'
	FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL='${gate_detail}'
	return '${gate_rc}'
}
_merge_guard_prospective_todo() { return 0; }
_retarget_stacked_children_interactive() { return 0; }
release_interactive_claim_on_merge() { return 0; }
auto_file_next_phase() { printf '%s %s\n' "\$1" "\$2" >> "${TEST_ROOT}/logs/phase-autofile.txt"; return 0; }
cmd_merge '$pr_number' '$repo'
RUNNER_EOF
	chmod +x "$tmp_runner"

	local rc=0
	env PATH="${TEST_ROOT}/bin:${scripts_dir}:${PATH}" \
		HOME="${TEST_ROOT}/home" \
		FULL_LOOP_HEADLESS="${FULL_LOOP_HEADLESS:-}" \
		AIDEVOPS_MODEL="test-model" \
		bash "$tmp_runner" 2>&1 || rc=$?
	rm -f "$tmp_runner"
	return $rc
}

# Run cmd_merge with a counted finalizer and bounded evidence retries.
# Args: pr_number repo
run_cmd_merge_for_evidence() {
	local pr_number="$1"
	local repo="$2"
	local scripts_dir="${SCRIPT_DIR}/.."
	local tmp_runner=""
	tmp_runner=$(mktemp)
	cat >"$tmp_runner" <<RUNNER_EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${scripts_dir}'
source '${scripts_dir}/shared-constants.sh'
source '${scripts_dir}/full-loop-helper-merge.sh'
cmd_pre_merge_gate() { return 0; }
_merge_guard_prospective_todo() { return 0; }
_retarget_stacked_children_interactive() { return 0; }
_merge_report_canonical_sync_state() { return 0; }
_merge_finalize_post_merge() {
	local count=0
	[[ -f '${TEST_ROOT}/logs/finalize-count.txt' ]] && count=\$(<'${TEST_ROOT}/logs/finalize-count.txt')
	count=\$((count + 1))
	printf '%s\n' "\$count" >'${TEST_ROOT}/logs/finalize-count.txt'
	return 0
}
cmd_merge '$pr_number' '$repo'
RUNNER_EOF
	chmod +x "$tmp_runner"

	local rc=0
	env PATH="${TEST_ROOT}/bin:${scripts_dir}:${PATH}" \
		HOME="${TEST_ROOT}/home" \
		FULL_LOOP_MERGED_EVIDENCE_ATTEMPTS=2 \
		FULL_LOOP_MERGED_EVIDENCE_DELAY_SECONDS=0 \
		AIDEVOPS_MODEL="test-model" \
		bash "$tmp_runner" 2>&1 || rc=$?
	rm -f "$tmp_runner"
	return $rc
}

# Test 1: Admin fallback fires and produces all three signaling artifacts
test_admin_fallback_signals() {
	# Clear logs
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "fallback"

	run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0" >/dev/null 2>&1 || true

	# (a) Check PR comment was posted
	local pr_comment_posted=0
	if [[ -f "${TEST_ROOT}/logs/pr-comments.txt" ]]; then
		if grep -q "pr comment" "${TEST_ROOT}/logs/pr-comments.txt"; then
			pr_comment_posted=1
		fi
	fi
	print_result "admin fallback: PR comment posted" "$((1 - pr_comment_posted))"

	# (b) Check audit log was called
	local audit_logged=0
	if [[ -f "${TEST_ROOT}/logs/audit-log-calls.txt" ]]; then
		if grep -q "merge-admin-fallback" "${TEST_ROOT}/logs/audit-log-calls.txt"; then
			audit_logged=1
		fi
	fi
	print_result "admin fallback: audit log entry written" "$((1 - audit_logged))"

	# (c) Check admin-merge label was applied
	local label_applied=0
	if [[ -f "${TEST_ROOT}/logs/pr-edits.txt" ]]; then
		if grep -q "admin-merge" "${TEST_ROOT}/logs/pr-edits.txt"; then
			label_applied=1
		fi
	fi
	print_result "admin fallback: admin-merge label applied" "$((1 - label_applied))"

	return 0
}

test_admin_fallback_native_review_handoff() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "fallback-native-review"

	local exit_code=0 output="" merge_calls=0 signaled=0
	output=$(run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0" 2>&1) || exit_code=$?
	merge_calls=$(grep -c '^gh pr merge' "${TEST_ROOT}/logs/gh-calls.txt" 2>/dev/null || true)
	[[ -f "${TEST_ROOT}/logs/pr-comments.txt" || -f "${TEST_ROOT}/logs/audit-log-calls.txt" ||
		-f "${TEST_ROOT}/logs/pr-edits.txt" ]] && signaled=1
	print_result "native review handoff: merge remains deferred" "$((exit_code == 0 ? 1 : 0))" "output=$output"
	print_result "native review handoff: plain and admin attempts are bounded" \
		"$((merge_calls == 2 ? 0 : 1))" "merge_calls=$merge_calls"
	print_result "native review handoff: reports Pulse handoff" \
		"$([[ "$output" == *"native approving review is required; hand off to Pulse"* ]] && printf '0' || printf '1')" \
		"output=$output"
	print_result "native review handoff: does not report maintainer authority failure" \
		"$([[ "$output" != *"maintainer gate or admin rights missing"* ]] && printf '0' || printf '1')" \
		"output=$output"
	print_result "native review handoff: emits no admin-merge success signals" "$signaled"

	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "fallback-native-review"
	exit_code=0
	output=$(FULL_LOOP_HEADLESS=true run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0" 2>&1) || exit_code=$?
	merge_calls=$(grep -c '^gh pr merge' "${TEST_ROOT}/logs/gh-calls.txt" 2>/dev/null || true)
	print_result "native review handoff headless: no merge bypass succeeds" "$((exit_code == 0 ? 1 : 0))"
	print_result "native review handoff headless: no mutation follows the admin rejection" \
		"$((merge_calls == 2 ? 0 : 1))" "merge_calls=$merge_calls"
	print_result "native review handoff headless: reports Pulse handoff" \
		"$([[ "$output" == *"native approving review is required; hand off to Pulse"* ]] && printf '0' || printf '1')" \
		"output=$output"
	return 0
}

test_admin_timeout_reconciles_without_replay() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "fallback-timeout-merged"

	local exit_code=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0" >/dev/null 2>&1 || exit_code=$?
	local merge_calls=0
	merge_calls=$(grep -c '^gh pr merge' "${TEST_ROOT}/logs/gh-calls.txt" 2>/dev/null || true)
	print_result "admin timeout: exact merged head reconciles as success" "$exit_code"
	print_result "admin timeout: merge mutation is not replayed" "$((merge_calls == 2 ? 0 : 1))" "merge_calls=$merge_calls"

	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "fallback-timeout-open"
	exit_code=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0" >/dev/null 2>&1 || exit_code=$?
	merge_calls=0
	merge_calls=$(grep -c '^gh pr merge' "${TEST_ROOT}/logs/gh-calls.txt" 2>/dev/null || true)
	print_result "admin timeout: unproven outcome fails closed" "$((exit_code == 0 ? 1 : 0))"
	print_result "admin timeout: unproven outcome is not replayed" "$((merge_calls == 2 ? 0 : 1))" "merge_calls=$merge_calls"

	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "primary-timeout-policy-open"
	exit_code=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0" >/dev/null 2>&1 || exit_code=$?
	merge_calls=0
	merge_calls=$(grep -c '^gh pr merge' "${TEST_ROOT}/logs/gh-calls.txt" 2>/dev/null || true)
	print_result "primary timeout: policy output cannot trigger admin replay" \
		"$([[ "$exit_code" -ne 0 && "$merge_calls" -eq 1 ]] && printf '0' || printf '1')" "merge_calls=$merge_calls"
	return 0
}

# Test 2b: Admin fallback refuses to bypass a linked issue still needing maintainer review.
test_admin_fallback_blocks_needs_maintainer_review_issue() {
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "fallback-nmr"

	local exit_code=0
	local out=""
	out=$(run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0" 2>&1) || exit_code=$?
	print_result "admin fallback: needs-maintainer-review blocks merge" "$((exit_code == 0 ? 1 : 0))" "output=$out"

	local admin_called=0
	if [[ -f "${TEST_ROOT}/logs/gh-calls.txt" ]] && grep -q -- '--admin' "${TEST_ROOT}/logs/gh-calls.txt"; then
		admin_called=1
	fi
	print_result "admin fallback: blocked before --admin retry" "$admin_called"

	local signaled=0
	if [[ -f "${TEST_ROOT}/logs/pr-comments.txt" ]] ||
		[[ -f "${TEST_ROOT}/logs/audit-log-calls.txt" ]] ||
		[[ -f "${TEST_ROOT}/logs/pr-edits.txt" ]]; then
		signaled=1
	fi
	print_result "admin fallback: no success signaling when maintainer gate blocks" "$signaled"

	return 0
}

test_admin_fallback_blocks_pending_required_checks() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "pending-policy"

	local exit_code=0 out="" merge_calls=0
	out=$(MERGE_TEST_REQUIRED_CHECKS_RC=8 run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0" 2>&1) || exit_code=$?
	merge_calls=$(grep -c '^gh pr merge' "${TEST_ROOT}/logs/gh-calls.txt" 2>/dev/null || true)
	print_result "pending checks: policy refusal remains non-zero" "$((exit_code == 0 ? 1 : 0))" "output=$out"
	print_result "pending checks: no admin retry occurs" "$((merge_calls == 1 ? 0 : 1))" "merge_calls=$merge_calls"
	print_result "pending checks: lifecycle state is explicit" \
		"$([[ "$out" == *"LIFECYCLE_STATE=CHECKS_PENDING"* ]] && printf '0' || printf '1')" "output=$out"
	return 0
}

# Test 2: Explicit --admin caller does NOT trigger extra signaling
test_explicit_admin_no_signaling() {
	# Clear logs
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "explicit-admin"

	run_merge_execute "42" "testorg/testrepo" "--squash" "1" "0" >/dev/null 2>&1 || true

	# PR comment should NOT have been posted (explicit --admin is not a fallback)
	local pr_comment_posted=0
	if [[ -f "${TEST_ROOT}/logs/pr-comments.txt" ]]; then
		if grep -q "pr comment" "${TEST_ROOT}/logs/pr-comments.txt"; then
			pr_comment_posted=1
		fi
	fi
	print_result "explicit --admin: no extra PR comment" "$pr_comment_posted"

	# Audit log should NOT have been called
	local audit_logged=0
	if [[ -f "${TEST_ROOT}/logs/audit-log-calls.txt" ]]; then
		if grep -q "merge-admin-fallback" "${TEST_ROOT}/logs/audit-log-calls.txt"; then
			audit_logged=1
		fi
	fi
	print_result "explicit --admin: no extra audit log" "$audit_logged"

	# Label should NOT have been applied
	local label_applied=0
	if [[ -f "${TEST_ROOT}/logs/pr-edits.txt" ]]; then
		if grep -q "admin-merge" "${TEST_ROOT}/logs/pr-edits.txt"; then
			label_applied=1
		fi
	fi
	print_result "explicit --admin: no admin-merge label" "$label_applied"

	return 0
}

# Test 3: Non-branch-protection errors do NOT trigger fallback at all
test_other_error_no_fallback() {
	# Clear logs
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "other-error"

	local exit_code=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0" >/dev/null 2>&1 || exit_code=$?

	# Should have failed (exit code != 0)
	print_result "other error: merge fails without fallback" "$((exit_code == 0 ? 1 : 0))"

	# No signaling should have fired
	local any_signaling=0
	if [[ -f "${TEST_ROOT}/logs/pr-comments.txt" ]] ||
		[[ -f "${TEST_ROOT}/logs/audit-log-calls.txt" ]] ||
		[[ -f "${TEST_ROOT}/logs/pr-edits.txt" ]]; then
		any_signaling=1
	fi
	print_result "other error: no signaling artifacts" "$any_signaling"

	return 0
}

test_late_review_blocks_every_merge_transport() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "late-review-block"

	local exit_code=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "1" "0" >/dev/null 2>&1 || exit_code=$?
	local merge_calls=0
	merge_calls=$(grep -c '^gh pr merge' "${TEST_ROOT}/logs/gh-calls.txt" 2>/dev/null || true)
	print_result "late review: live CHANGES_REQUESTED blocks merge" "$((exit_code == 0 ? 1 : 0))"
	print_result "late review: admin merge transport is never invoked" "$((merge_calls == 0 ? 0 : 1))" "merge_calls=$merge_calls"
	return 0
}

# Test 4: GraphQL rate-limit failures use the REST pull merge endpoint.
test_graphql_rate_limit_rest_fallback() {
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "graphql-rate-limit"

	local exit_code=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0" >/dev/null 2>&1 || exit_code=$?
	print_result "GraphQL rate-limit: REST fallback succeeds" "$exit_code"

	local rest_called=0
	if [[ -f "${TEST_ROOT}/logs/gh-api-calls.txt" ]] &&
		grep -q "repos/testorg/testrepo/pulls/42/merge" "${TEST_ROOT}/logs/gh-api-calls.txt" &&
		grep -q "sha=abc123headsha" "${TEST_ROOT}/logs/gh-api-calls.txt" &&
		grep -q "merge_method=squash" "${TEST_ROOT}/logs/gh-api-calls.txt" &&
		grep -q "commit_title=GH#28721: fix: preserve reviewed squash subject" "${TEST_ROOT}/logs/gh-api-calls.txt"; then
		rest_called=1
	fi
	print_result "GraphQL rate-limit: REST pull merge endpoint called with verified SHA" "$((1 - rest_called))"

	return 0
}

# Test 5: GraphQL REST fallback through cmd_merge triggers sequential phase auto-filing.
test_graphql_rate_limit_cmd_merge_phase_autofile() {
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "graphql-rate-limit"

	local exit_code=0
	run_cmd_merge_with_gate "42" "testorg/testrepo" "0" >/dev/null 2>&1 || exit_code=$?
	print_result "GraphQL rate-limit cmd_merge: REST fallback succeeds" "$exit_code"

	local phase_called=0
	if [[ -f "${TEST_ROOT}/logs/phase-autofile.txt" ]] &&
		grep -q "22621 testorg/testrepo" "${TEST_ROOT}/logs/phase-autofile.txt"; then
		phase_called=1
	fi
	print_result "GraphQL rate-limit cmd_merge: phase autofile called for linked issue" "$((1 - phase_called))"

	return 0
}

# Test 6: REST fallback is not used for --auto because it would merge immediately.
test_graphql_rate_limit_auto_no_rest_fallback() {
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "graphql-rate-limit"

	local exit_code=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "0" "1" >/dev/null 2>&1 || exit_code=$?
	print_result "GraphQL rate-limit with --auto: merge fails without immediate REST merge" "$((exit_code == 0 ? 1 : 0))"

	local rest_called=0
	if [[ -f "${TEST_ROOT}/logs/gh-api-calls.txt" ]] &&
		grep -q "repos/testorg/testrepo/pulls/42/merge" "${TEST_ROOT}/logs/gh-api-calls.txt"; then
		rest_called=1
	fi
	print_result "GraphQL rate-limit with --auto: REST fallback not called" "$rest_called"

	return 0
}

# Test 7: Review-bot gate failure prevents both gh pr merge and REST fallback.
test_review_gate_failure_blocks_rest_fallback() {
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "graphql-rate-limit"

	local exit_code=0
	run_cmd_merge_with_gate "42" "testorg/testrepo" "1" >/dev/null 2>&1 || exit_code=$?
	print_result "review gate failure: cmd_merge exits non-zero" "$((exit_code == 0 ? 1 : 0))"

	local merge_called=0
	if [[ -f "${TEST_ROOT}/logs/gh-calls.txt" ]] && grep -q "pr merge" "${TEST_ROOT}/logs/gh-calls.txt"; then
		merge_called=1
	fi
	print_result "review gate failure: gh pr merge not called" "$merge_called"

	local rest_called=0
	[[ -f "${TEST_ROOT}/logs/gh-api-calls.txt" ]] && rest_called=1
	print_result "review gate failure: REST fallback not called" "$rest_called"

	return 0
}

# Test 7a: A cooldown-classified gate failure reports the real blocker.
test_cooldown_gate_failure_reports_cooldown() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "graphql-rate-limit"

	local exit_code=0
	local output=""
	output=$(run_cmd_merge_with_gate "42" "testorg/testrepo" "1" \
		"github-api-cooldown" "1893456000" 2>&1) || exit_code=$?
	print_result "cooldown gate failure: cmd_merge exits non-zero" "$((exit_code == 0 ? 1 : 0))"
	print_result "cooldown gate failure: truthful expiry guidance" \
		"$([[ "$output" == *"Merge deferred: GitHub API cooldown is active; retry after epoch 1893456000."* ]] && printf '0' || printf '1')" \
		"output=$output"
	print_result "cooldown gate failure: no review-bot remediation" \
		"$([[ "$output" != *"Address bot findings"* ]] && printf '0' || printf '1')" \
		"output=$output"

	local merge_called=0
	if [[ -f "${TEST_ROOT}/logs/gh-calls.txt" ]] && grep -q "pr merge" "${TEST_ROOT}/logs/gh-calls.txt"; then
		merge_called=1
	fi
	print_result "cooldown gate failure: merge is not attempted" "$merge_called"
	return 0
}

# Test 7aa: A local read-admission deferral preserves its retry deadline at the
# production cmd_merge reporting boundary rather than collapsing to guidance.
test_local_admission_gate_failure_reports_retry_deadline() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "graphql-rate-limit"

	local exit_code=0
	local output=""
	output=$(run_cmd_merge_with_gate "42" "testorg/testrepo" "1" \
		"github-api-read-deferred" "1893456000" 2>&1) || exit_code=$?
	print_result "local admission gate failure: cmd_merge exits non-zero" "$((exit_code == 0 ? 1 : 0))"
	print_result "local admission gate failure: preserves numeric retry deadline" \
		"$([[ "$output" == *"Merge deferred by GitHub read admission; retry_at=1893456000."* ]] && printf '0' || printf '1')" \
		"output=$output"
	print_result "local admission gate failure: no review-bot remediation" \
		"$([[ "$output" != *"Address bot findings"* ]] && printf '0' || printf '1')" \
		"output=$output"

	local merge_called=0
	if [[ -f "${TEST_ROOT}/logs/gh-calls.txt" ]] && grep -q "pr merge" "${TEST_ROOT}/logs/gh-calls.txt"; then
		merge_called=1
	fi
	print_result "local admission gate failure: merge is not attempted" "$merge_called"
	return 0
}

test_post_verification_read_admission_window() {
	local scripts_dir="" result=0
	scripts_dir="$(cd "${SCRIPT_DIR}/.." && pwd)"
	bash -c '
		source "$1/shared-constants.sh"
		source "$1/full-loop-helper-merge.sh"
		unset AIDEVOPS_GH_READ_TIMEOUT
		_gh_with_timeout() {
			# Temporary-file setup consumes part of the shared wall-clock budget.
			[[ "$AIDEVOPS_GH_READ_TIMEOUT" -gt 0 && "$AIDEVOPS_GH_READ_TIMEOUT" -le 60 && "$1" == read ]] || return 1
			printf "base\tbase-sha\thead-sha\ttestorg/testrepo\tclone-url\n"
			return 0
		}
		_merge_fetch_pr_refs_rest 42 testorg/testrepo >/dev/null || exit 1
		[[ -z "${AIDEVOPS_GH_READ_TIMEOUT+x}" ]] || exit 1
		_gh_collaborator_permission_lookup() {
			[[ "$AIDEVOPS_GH_READ_TIMEOUT" == 60 ]] || return 2
			printf -v "$3" "%s" write
			return 0
		}
		_merge_author_has_write_authority owner testorg/testrepo || exit 1
		_gh_with_timeout() {
			[[ "$AIDEVOPS_GH_READ_TIMEOUT" == 7 ]] || return 1
			return 0
		}
		AIDEVOPS_GH_READ_TIMEOUT=7 _flm_gh_read gh api repos/testorg/testrepo
	' _ "$scripts_dir" || result=$?
	print_result "post-verification reads: bounded admission window and caller override" "$result"
	return 0
}

test_bounded_local_admission_recovery() {
	local scripts_dir="" scenario="" result=0
	scripts_dir="$(cd "${SCRIPT_DIR}/.." && pwd)"
	for scenario in short fractional integral boundary expired moving overshoot long malformed cooldown review changed-review; do
		result=0
		bash -c '
			source "$1/shared-constants.sh"
			source "$1/full-loop-helper-merge.sh"
			unset AIDEVOPS_MERGE_ADMISSION_BUDGET_SECONDS
			scenario="$2" calls=0 waits=0 elapsed=0
			date() { printf "%s\n" "$((1000 + elapsed))"; return 0; }
			sleep() {
				local duration="$1"
				[[ "$scenario" != overshoot ]] || duration=61
				waits=$((waits + 1))
				elapsed=$((elapsed + duration))
				SECONDS=$((SECONDS + duration))
				return 0
			}
			cmd_pre_merge_gate() {
				calls=$((calls + 1))
				[[ "$1" == 42 && "$2" == testorg/testrepo ]] || return 1
				if [[ "$calls" -eq 2 && "$scenario" != moving && "$scenario" != changed-review ]]; then
					return 0
				fi
				FULL_LOOP_PRE_MERGE_BLOCKER_KIND=github-api-read-deferred
				case "$scenario" in
				short) FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL=1002 ;;
				fractional) FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL=1001.25 ;;
				integral) FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL=1002.000 ;;
				boundary) FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL=1060.000 ;;
				expired) FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL=999 ;;
				moving) FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL=$((1001 + elapsed)) ;;
				overshoot) FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL=1002 ;;
				long) FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL=1061 ;;
				malformed) FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL=retry-when-capacity-returns ;;
				cooldown) FULL_LOOP_PRE_MERGE_BLOCKER_KIND=github-api-cooldown ;;
				review) FULL_LOOP_PRE_MERGE_BLOCKER_KIND=review-bot ;;
				changed-review)
					FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL=1002
					[[ "$calls" -eq 1 ]] || FULL_LOOP_PRE_MERGE_BLOCKER_KIND=review-bot
					;;
				esac
				return 1
			}
			rc=0
			_merge_pre_merge_gate_with_admission_retry 42 testorg/testrepo || rc=$?
			case "$scenario" in
			short|integral) [[ "$rc" -eq 0 && "$calls" -eq 2 && "$elapsed" -eq 2 ]] ;;
			fractional) [[ "$rc" -eq 0 && "$calls" -eq 2 && "$elapsed" -eq 2 ]] ;;
			boundary) [[ "$rc" -eq 1 && "$calls" -eq 1 && "$elapsed" -eq 60 && "$FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL" == 1060.000 ]] ;;
			expired) [[ "$rc" -eq 0 && "$calls" -eq 2 && "$elapsed" -eq 1 ]] ;;
			moving) [[ "$rc" -eq 1 && "$calls" -eq 4 && "$waits" -eq 3 && "$elapsed" -eq 3 ]] ;;
			overshoot) [[ "$rc" -eq 1 && "$calls" -eq 1 && "$waits" -eq 1 ]] ;;
			changed-review) [[ "$rc" -eq 1 && "$calls" -eq 2 && "$waits" -eq 1 ]] ;;
			*) [[ "$rc" -eq 1 && "$calls" -eq 1 && "$waits" -eq 0 ]] ;;
			esac
		' _ "$scripts_dir" "$scenario" || result=$?
		print_result "bounded local admission recovery: $scenario" "$result"
	done
	return 0
}

# Exercise the production refs and release-lane reads, not just a mocked gate.
# State files preserve call counts across the production command substitutions.
test_shared_merge_read_admission_recovery() {
	local scripts_dir="" scenario="" result=0
	scripts_dir="$(cd "${SCRIPT_DIR}/.." && pwd)"
	for scenario in refs release persists long fractional quota http nested; do
		result=0
		bash -c '
			source "$1/shared-constants.sh"
			source "$1/full-loop-helper-merge.sh"
			unset AIDEVOPS_MERGE_ADMISSION_BUDGET_SECONDS AIDEVOPS_GH_READ_TIMEOUT
			scenario="$2" elapsed=0 out="" rc=0
			calls_file="$(mktemp)" waits_file="$(mktemp)"
			printf "0" >"$calls_file"
			printf "0" >"$waits_file"
			date() { printf "%s\n" "$((1000 + elapsed))"; return 0; }
			sleep() {
				local duration="$1"
				elapsed=$((elapsed + duration))
				SECONDS=$((SECONDS + duration))
				printf "%s" "$elapsed" >"$waits_file"
				return 0
			}
			_gh_with_timeout() {
				local calls=$(( $(<"$calls_file") + 1 )) retry_at=1002
				printf "%s" "$calls" >"$calls_file"
				case "$scenario" in
				quota) printf "HTTP 403: API rate limit exceeded\n" >&2; return 1 ;;
				http) printf "HTTP 502: Bad Gateway\n" >&2; return 1 ;;
				long) retry_at=1061 ;;
				fractional) retry_at=1001.25 ;;
				persists|nested) retry_at=$((1001 + elapsed)) ;;
				esac
				if [[ "$calls" -eq 1 || "$scenario" == persists || "$scenario" == nested ]]; then
					printf "[gh-transport] error_kind=github-api-read-deferred attempted=false deferred_by=local_admission retry_at=%s reason=pacing\n" "$retry_at" >&2
					return 75
				fi
				if [[ "$scenario" == release ]]; then
					printf "main\tbase-sha\n"
				else
					printf "main\tbase-sha\thead-sha\ttestorg/testrepo\tclone-url\n"
				fi
				return 0
			}
			if [[ "$scenario" == release ]]; then
				export AIDEVOPS_RELEASE_LANE_COORDINATED_REPO=testorg/testrepo
				_merge_pre_merge_gate_with_admission_retry() { return 0; }
				release_lane_merge_guard() { [[ "$3" == main && "$4" == base-sha ]] || exit 2; return 1; }
				out=$(cmd_merge 42 testorg/testrepo 2>&1) || rc=$?
			elif [[ "$scenario" == nested ]]; then
				out=$(_merge_with_admission_retry _merge_fetch_pr_refs_rest 42 testorg/testrepo 2>&1) || rc=$?
			else
				out=$(_merge_fetch_pr_refs_rest 42 testorg/testrepo 2>&1) || rc=$?
			fi
			calls=$(<"$calls_file") waited=$(<"$waits_file")
			rm -f "$calls_file" "$waits_file"
			case "$scenario" in
			refs|fractional) [[ "$rc" -eq 0 && "$calls" -eq 2 && "$waited" -eq 2 && "$out" == *head-sha* ]] ;;
			release) [[ "$rc" -eq 1 && "$calls" -eq 2 && "$waited" -eq 2 && "$out" == *"active exact-tip release lane"* && "$out" != *"cannot verify"* ]] ;;
			persists|nested) [[ "$rc" -eq 1 && "$calls" -eq 4 && "$waited" -eq 3 && "$out" == *"error_kind=github-api-read-deferred"* && "$out" == *"retry_at=1004"* ]] ;;
			long) [[ "$rc" -eq 1 && "$calls" -eq 1 && "$waited" -eq 0 && "$out" == *"retry_at=1061"* ]] ;;
			quota|http) [[ "$rc" -eq 1 && "$calls" -eq 1 && "$waited" -eq 0 && "$out" == *HTTP* ]] ;;
			esac
		' _ "$scripts_dir" "$scenario" || result=$?
		print_result "shared merge read admission recovery: $scenario" "$result"
	done
	return 0
}

test_final_head_sha_read_admission_recovery() {
	local scripts_dir="" scenario="" result=0
	scripts_dir="$(cd "${SCRIPT_DIR}/.." && pwd)"
	for scenario in recovers persists drift; do
		result=0
		bash -c '
			source "$1/shared-constants.sh"
			source "$1/full-loop-helper-merge.sh"
			source "$1/full-loop-helper-readiness.sh"
			scenario="$2" elapsed=0 out="" rc=0
			calls_file="$(mktemp)"
			printf "0" >"$calls_file"
			date() { printf "%s\n" "$((1000 + elapsed))"; return 0; }
			sleep() { elapsed=$((elapsed + $1)); SECONDS=$((SECONDS + $1)); return 0; }
			_merge_fetch_head_sha_rest() {
				# Runs in a command substitution; persist the call count in a file.
				local calls=$(( $(<"$calls_file") + 1 ))
				printf "%s" "$calls" >"$calls_file"
				if [[ "$scenario" == persists || "$calls" -eq 1 ]]; then
					printf "%s\n" "[gh-transport] error_kind=github-api-read-deferred attempted=false deferred_by=local_admission retry_at=1002 reason=pacing" >&2
					return 1
				fi
				[[ "$scenario" == drift ]] && printf "%s\n" other456 || printf "%s\n" verified123
				return 0
			}
			export FULL_LOOP_VERIFIED_PR_HEAD_SHA=verified123
			out=$(_merge_resolve_match_head 42 testorg/testrepo 2>&1) || rc=$?
			rm -f "$calls_file"
			case "$scenario" in
			recovers) [[ "$rc" -eq 0 && "$out" == *verified123 && "$out" == *"waiting 2s"* ]] ;;
			persists) [[ "$rc" -eq 1 && "$out" == *"retry_at=1002"* && "$out" != *"Could not retrieve"* ]] ;;
			drift) [[ "$rc" -eq 1 && "$out" == *"head changed after remote verification"* ]] ;;
			esac
		' _ "$scripts_dir" "$scenario" || result=$?
		print_result "final head SHA read admission recovery: $scenario" "$result"
	done
	return 0
}

# Test 7b: Interactive --auto review-required block uses admin fallback when safe.
test_auto_review_required_interactive_admin_fallback() {
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "auto-review-required"

	local exit_code=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "0" "1" >/dev/null 2>&1 || exit_code=$?
	print_result "auto review-required: interactive admin fallback succeeds" "$exit_code"

	local auto_called=0
	local admin_called=0
	if [[ -f "${TEST_ROOT}/logs/gh-calls.txt" ]]; then
		grep -q -- '--auto' "${TEST_ROOT}/logs/gh-calls.txt" && auto_called=1
		grep -q -- '--admin' "${TEST_ROOT}/logs/gh-calls.txt" && admin_called=1
	fi
	print_result "auto review-required: --auto attempted first" "$((1 - auto_called))"
	print_result "auto review-required: --admin fallback attempted" "$((1 - admin_called))"

	return 0
}

test_auto_review_required_admin_rejection_handoff() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "auto-review-required-admin-block"

	local exit_code=0 output="" merge_calls=0
	output=$(run_merge_execute "42" "testorg/testrepo" "--squash" "0" "1" 2>&1) || exit_code=$?
	merge_calls=$(grep -c '^gh pr merge' "${TEST_ROOT}/logs/gh-calls.txt" 2>/dev/null || true)
	print_result "auto native review handoff: merge remains deferred" "$((exit_code == 0 ? 1 : 0))" "output=$output"
	print_result "auto native review handoff: auto and admin attempts are bounded" \
		"$((merge_calls == 2 ? 0 : 1))" "merge_calls=$merge_calls"
	print_result "auto native review handoff: reports Pulse handoff" \
		"$([[ "$output" == *"native approving review is required; hand off to Pulse"* ]] && printf '0' || printf '1')" \
		"output=$output"
	print_result "auto native review handoff: does not report maintainer authority failure" \
		"$([[ "$output" != *"maintainer gate or admin rights missing"* ]] && printf '0' || printf '1')" \
		"output=$output"
	return 0
}

# Test 7c: Headless --auto review-required block does not admin-bypass.
test_auto_review_required_headless_no_admin_fallback() {
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "auto-review-required"

	local exit_code=0
	FULL_LOOP_HEADLESS=true run_merge_execute "42" "testorg/testrepo" "--squash" "0" "1" >/dev/null 2>&1 || exit_code=$?
	print_result "auto review-required headless: merge remains blocked" "$((exit_code == 0 ? 1 : 0))"

	local admin_called=0
	if [[ -f "${TEST_ROOT}/logs/gh-calls.txt" ]] && grep -q -- '--admin' "${TEST_ROOT}/logs/gh-calls.txt"; then
		admin_called=1
	fi
	print_result "auto review-required headless: --admin not attempted" "$admin_called"

	return 0
}

# Test 8: cached gh HTTP 401 is quarantined and gh pr merge is retried once.
test_stale_cache_401_retry() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	rm -rf "${TEST_ROOT:?}/home"
	mkdir -p "${TEST_ROOT}/home/.cache/gh/api" "${TEST_ROOT}/home/.cache/gh/graphql"
	cat >"${TEST_ROOT}/home/.cache/gh/graphql-401.cache" <<'CACHE'
HTTP/2.0 401 Unauthorized
X-Gh-Cache-Ttl: 24h0m0s
{"message":"Requires authentication","documentation_url":"https://docs.github.com/graphql"}
CACHE
	cat >"${TEST_ROOT}/home/.cache/gh/api/shared.cache" <<'CACHE'
HTTP/2.0 401 Unauthorized
X-Gh-Cache-Ttl: 24h0m0s
{"message":"Requires authentication","documentation_url":"https://docs.github.com/rest"}
CACHE
	cat >"${TEST_ROOT}/home/.cache/gh/graphql/shared.cache" <<'CACHE'
HTTP/2.0 401 Unauthorized
X-Gh-Cache-Ttl: 24h0m0s
{"message":"Requires authentication","documentation_url":"https://docs.github.com/graphql"}
CACHE
	cat >"${TEST_ROOT}/home/.cache/gh/healthy.cache" <<'CACHE'
HTTP/2.0 200 OK
{"data":{"viewer":{"login":"tester"}}}
CACHE

	create_gh_stub "stale-cache-401"

	local exit_code=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0" >/dev/null 2>&1 || exit_code=$?
	print_result "stale gh cache 401: retry succeeds" "$exit_code"

	local merge_count="0"
	[[ -f "${TEST_ROOT}/logs/merge-count.txt" ]] && merge_count=$(cat "${TEST_ROOT}/logs/merge-count.txt")
	print_result "stale gh cache 401: gh pr merge called exactly twice" "$((merge_count == 2 ? 0 : 1))" "merge_count=${merge_count}"

	local stale_quarantined=0
	if [[ ! -f "${TEST_ROOT}/home/.cache/gh/graphql-401.cache" ]] &&
		find "${TEST_ROOT}/home/.cache/gh" -path '*/aidevops-quarantine-*/graphql-401.cache' -type f | grep -q .; then
		stale_quarantined=1
	fi
	print_result "stale gh cache 401: top-level 401 cache quarantined" "$((1 - stale_quarantined))"

	local collision_paths_preserved=0
	if [[ ! -f "${TEST_ROOT}/home/.cache/gh/api/shared.cache" ]] &&
		[[ ! -f "${TEST_ROOT}/home/.cache/gh/graphql/shared.cache" ]] &&
		find "${TEST_ROOT}/home/.cache/gh" -path '*/aidevops-quarantine-*/api/shared.cache' -type f | grep -q . &&
		find "${TEST_ROOT}/home/.cache/gh" -path '*/aidevops-quarantine-*/graphql/shared.cache' -type f | grep -q .; then
		collision_paths_preserved=1
	fi
	print_result "stale gh cache 401: quarantine preserves relative paths" "$((1 - collision_paths_preserved))"

	local healthy_preserved=0
	[[ -f "${TEST_ROOT}/home/.cache/gh/healthy.cache" ]] && healthy_preserved=1
	print_result "stale gh cache 401: healthy cache preserved" "$((1 - healthy_preserved))"

	return 0
}

# Test 9: 401 detection only matches authentication-shaped merge errors.
test_auth_401_detection_avoids_numeric_false_positives() {
	source "${SCRIPT_DIR}/../gh-merge-cache-remediation-lib.sh"

	local false_positive=0
	gh_merge_output_is_auth_401 "Merged PR #401" && false_positive=1
	print_result "auth 401 detection: PR number 401 is not auth" "$false_positive"

	false_positive=0
	gh_merge_output_is_auth_401 "Merged commit a401b2c" && false_positive=1
	print_result "auth 401 detection: SHA fragment 401 is not auth" "$false_positive"

	local auth_detected=0
	gh_merge_output_is_auth_401 "HTTP/2.0 401 Unauthorized" && auth_detected=1
	print_result "auth 401 detection: HTTP 401 remains auth" "$((1 - auth_detected))"

	return 0
}

# Test 10: PR readiness accepts pre-fetched JSON and does not call gh again.
test_pr_ready_accepts_prefetched_json() {
	rm -f "${TEST_ROOT}/logs/"*.txt

	cat >"${TEST_ROOT}/bin/gh" <<GHSTUB
#!/usr/bin/env bash
echo "gh \$*" >> "${TEST_ROOT}/logs/gh-calls.txt"
exit 90
GHSTUB
	chmod +x "${TEST_ROOT}/bin/gh"

	local scripts_dir="${SCRIPT_DIR}/.."
	local tmp_runner=""
	tmp_runner=$(mktemp)
	cat >"$tmp_runner" <<RUNNER_EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${scripts_dir}'
source '${scripts_dir}/shared-constants.sh'
source '${scripts_dir}/full-loop-helper-merge.sh'
_merge_pr_ready_for_interactive_admin_bypass '42' 'testorg/testrepo' '{"isDraft":false,"reviewDecision":"","statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS","status":"COMPLETED"}]}'
RUNNER_EOF
	chmod +x "$tmp_runner"

	local rc=0
	env PATH="${TEST_ROOT}/bin:${scripts_dir}:${PATH}" bash "$tmp_runner" >/dev/null 2>&1 || rc=$?
	rm -f "$tmp_runner"

	print_result "PR readiness: prefetched passing JSON is accepted" "$rc"

	local gh_called=0
	[[ -f "${TEST_ROOT}/logs/gh-calls.txt" ]] && gh_called=1
	print_result "PR readiness: prefetched JSON skips gh pr view" "$gh_called"

	return 0
}

# Test 11: simplified passish check still blocks non-passing rollup entries.
test_pr_ready_blocks_nonpassing_rollup() {
	rm -f "${TEST_ROOT}/logs/"*.txt

	local scripts_dir="${SCRIPT_DIR}/.."
	local tmp_runner=""
	tmp_runner=$(mktemp)
	cat >"$tmp_runner" <<RUNNER_EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${scripts_dir}'
source '${scripts_dir}/shared-constants.sh'
source '${scripts_dir}/full-loop-helper-merge.sh'
_merge_pr_ready_for_interactive_admin_bypass '42' 'testorg/testrepo' '{"isDraft":false,"reviewDecision":"","statusCheckRollup":[{"name":"ci","conclusion":"","status":"IN_PROGRESS"}]}'
RUNNER_EOF
	chmod +x "$tmp_runner"

	local rc=0
	env PATH="${TEST_ROOT}/bin:${scripts_dir}:${PATH}" bash "$tmp_runner" >/dev/null 2>&1 || rc=$?
	rm -f "$tmp_runner"

	print_result "PR readiness: non-passing rollup remains blocked" "$((rc == 0 ? 1 : 0))"

	return 0
}

# Test 12: A failed head lookup is reported as unavailable evidence, not drift.
test_verified_head_lookup_failure_is_not_reported_as_drift() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "head-fetch-failure"

	local output=""
	local rc=0
	output=$(FULL_LOOP_VERIFIED_PR_HEAD_SHA="verified123" run_merge_execute \
		"42" "testorg/testrepo" "--squash" "0" "0") || rc=$?
	print_result "verified head lookup failure: merge remains blocked" "$((rc == 0 ? 1 : 0))"

	local reports_retrieval_failure=0
	[[ "$output" == *"Could not retrieve PR #42 head SHA for verification"* ]] && reports_retrieval_failure=1
	print_result "verified head lookup failure: retrieval error is explicit" "$((1 - reports_retrieval_failure))"

	local reports_false_drift=0
	[[ "$output" == *"head changed after remote verification"* ]] && reports_false_drift=1
	print_result "verified head lookup failure: no false drift diagnosis" "$reports_false_drift"
	return 0
}

# Test 13: stale post-merge evidence converges without replaying the mutation.
test_post_merge_stale_evidence_retries_fresh_read() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "post-merge-stale"

	local output=""
	local rc=0
	output=$(run_cmd_merge_for_evidence "42" "testorg/testrepo") || rc=$?
	print_result "post-merge evidence: stale first read converges" "$rc" "output=$output"

	local merge_calls=0 evidence_calls=0 cache_disabled_calls=0 finalize_count=0
	merge_calls=$(grep -c '^gh pr merge' "${TEST_ROOT}/logs/gh-calls.txt" || true)
	evidence_calls=$(<"${TEST_ROOT}/logs/evidence-count.txt")
	cache_disabled_calls=$(grep -c '^1$' "${TEST_ROOT}/logs/evidence-cache-control.txt" || true)
	[[ -f "${TEST_ROOT}/logs/finalize-count.txt" ]] && finalize_count=$(<"${TEST_ROOT}/logs/finalize-count.txt")
	print_result "post-merge evidence: mutation executes exactly once" "$((merge_calls == 1 ? 0 : 1))" "merge_calls=$merge_calls"
	print_result "post-merge evidence: retry reads are cache-disabled" "$((evidence_calls == 2 && cache_disabled_calls == 2 ? 0 : 1))" "evidence_calls=$evidence_calls cache_disabled_calls=$cache_disabled_calls"
	print_result "post-merge evidence: finalizer executes exactly once" "$((finalize_count == 1 ? 0 : 1))" "finalize_count=$finalize_count"
	print_result "post-merge evidence: lifecycle reports merge SHA" "$([[ "$output" == *"LIFECYCLE_STATE=MERGED merge_sha=merged123sha"* ]] && printf '0' || printf '1')" "output=$output"
	return 0
}

# Test 14: persistently unmerged evidence fails closed after bounded reads.
test_post_merge_unmerged_evidence_fails_closed() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "post-merge-unmerged"

	local rc=0
	run_cmd_merge_for_evidence "42" "testorg/testrepo" >/dev/null 2>&1 || rc=$?
	local merge_calls=0 evidence_calls=0 finalize_count=0
	merge_calls=$(grep -c '^gh pr merge' "${TEST_ROOT}/logs/gh-calls.txt" || true)
	evidence_calls=$(<"${TEST_ROOT}/logs/evidence-count.txt")
	[[ -f "${TEST_ROOT}/logs/finalize-count.txt" ]] && finalize_count=$(<"${TEST_ROOT}/logs/finalize-count.txt")
	print_result "post-merge evidence: persistent OPEN fails closed" "$((rc == 0 ? 1 : 0))"
	print_result "post-merge evidence: persistent OPEN does not replay merge" "$((merge_calls == 1 && evidence_calls == 2 ? 0 : 1))" "merge_calls=$merge_calls evidence_calls=$evidence_calls"
	print_result "post-merge evidence: persistent OPEN skips finalizer" "$((finalize_count == 0 ? 0 : 1))" "finalize_count=$finalize_count"
	return 0
}

# Test 15: API-indeterminate evidence fails closed without replaying the mutation.
test_post_merge_api_indeterminate_fails_closed() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "post-merge-api-failure"

	local rc=0
	run_cmd_merge_for_evidence "42" "testorg/testrepo" >/dev/null 2>&1 || rc=$?
	local merge_calls=0 evidence_calls=0 finalize_count=0
	merge_calls=$(grep -c '^gh pr merge' "${TEST_ROOT}/logs/gh-calls.txt" || true)
	evidence_calls=$(<"${TEST_ROOT}/logs/evidence-count.txt")
	[[ -f "${TEST_ROOT}/logs/finalize-count.txt" ]] && finalize_count=$(<"${TEST_ROOT}/logs/finalize-count.txt")
	print_result "post-merge evidence: API-indeterminate state fails closed" "$((rc == 0 ? 1 : 0))"
	print_result "post-merge evidence: API failure does not replay merge" "$((merge_calls == 1 && evidence_calls == 2 ? 0 : 1))" "merge_calls=$merge_calls evidence_calls=$evidence_calls"
	print_result "post-merge evidence: API failure skips finalizer" "$((finalize_count == 0 ? 0 : 1))" "finalize_count=$finalize_count"
	return 0
}

test_wip_draft_takeover_uses_reviewed_pr_title() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	# The source branch's sole inherited commit is "wip: document recovery".
	# The merge wrapper must ignore that GitHub default and bind the squash
	# commit to the separately reviewed, compliant PR title from the stub.
	create_gh_stub "explicit-admin"

	local rc=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "1" "0" >/dev/null 2>&1 || rc=$?
	local subject_present=0
	if grep -q -- '--subject GH#28721: fix: preserve reviewed squash subject' "${TEST_ROOT}/logs/gh-calls.txt"; then
		subject_present=1
	fi
	print_result "wip draft takeover: reviewed PR title is explicit" "$((rc == 0 && subject_present == 1 ? 0 : 1))"
	return 0
}

test_gh_prefixed_feature_inherits_commit_category() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	# PR #29531 had a required GH# prefix in its reviewed title while its sole
	# reviewed commit retained the authoritative conventional feature type.
	create_gh_stub "gh-prefix-feature"

	local rc=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "1" "0" >/dev/null 2>&1 || rc=$?
	local expected_subject='--subject GH#29530: feat: Add a Buzz-scoped OpenCode Tabby workspace profile'
	local subject_present=0
	grep -q -- "$expected_subject" "${TEST_ROOT}/logs/gh-calls.txt" && subject_present=1
	print_result "squash subject: GH-prefixed feature retains conventional category" "$((rc == 0 && subject_present == 1 ? 0 : 1))"
	return 0
}

test_gh_prefixed_prose_without_evidence_is_not_guessed() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "gh-prefix-no-evidence"

	local rc=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "1" "0" >/dev/null 2>&1 || rc=$?
	local bare_subject='--subject GH#29530: Add a Buzz-scoped OpenCode Tabby workspace profile'
	local bare_present=0 guessed_present=0
	grep -q -- "$bare_subject" "${TEST_ROOT}/logs/gh-calls.txt" && bare_present=1
	grep -q -- '--subject GH#29530: feat:' "${TEST_ROOT}/logs/gh-calls.txt" && guessed_present=1
	print_result "squash subject: bare GH prose is not guessed without conventional evidence" "$((rc == 0 && bare_present == 1 && guessed_present == 0 ? 0 : 1))"
	return 0
}

test_invalid_squash_title_blocks_before_merge() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "invalid-squash-title"

	local rc=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0" >/dev/null 2>&1 || rc=$?
	local merge_calls=0
	merge_calls=$(grep -c '^gh pr merge' "${TEST_ROOT}/logs/gh-calls.txt" 2>/dev/null || true)
	print_result "squash subject: invalid title fails closed" "$((rc == 0 ? 1 : 0))"
	print_result "squash subject: invalid title blocks before mutation" "$((merge_calls == 0 ? 0 : 1))" "merge_calls=$merge_calls"
	return 0
}

test_non_squash_skips_subject_override() {
	rm -f "${TEST_ROOT}/logs/"*.txt
	create_gh_stub "explicit-admin"

	local rc=0
	run_merge_execute "42" "testorg/testrepo" "--merge" "1" "0" >/dev/null 2>&1 || rc=$?
	local subject_present=0 title_reads=0
	grep -q -- '--subject' "${TEST_ROOT}/logs/gh-calls.txt" && subject_present=1
	title_reads=$(grep -c -- '--json title' "${TEST_ROOT}/logs/gh-calls.txt" 2>/dev/null || true)
	print_result "non-squash: existing merge behavior is preserved" "$((rc == 0 && subject_present == 0 && title_reads == 0 ? 0 : 1))"
	return 0
}

test_local_deferral_survives_context_resolution() {
	local result=0
	(
		local scripts_dir="${SCRIPT_DIR}/.." attempt="" rc=0
		# shellcheck source=/dev/null
		source "$scripts_dir/shared-constants.sh"
		# shellcheck source=/dev/null
		source "$scripts_dir/pulse-merge-required-checks.sh"
		# shellcheck source=/dev/null
		source "$scripts_dir/full-loop-helper-commit.sh"
		aidevops_log_line() { return 0; }
		_pmrc_gh_read() {
			case "$3" in
			repos/testorg/testrepo) printf 'main\n' ;;
			*/protection/required_status_checks) printf '{"contexts":[]}\n' ;;
			*/rulesets)
				printf '[gh-transport] error_kind=github-api-read-deferred attempted=false deferred_by=local_admission retry_at=1893456000 reason="fixture quota wait"\n' >&2
				return 75
				;;
			*) return 1 ;;
			esac
			return 0
		}
		gh_pr_checks_exact_json() {
			touch "$TEST_ROOT/unexpected-exact-read"
			return 0
		}
		export AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR="$TEST_ROOT/deferral-context-cache"
		mkdir -p "$AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR"
		for attempt in first cached; do
			rc=0
			_full_loop_query_required_checks 42 testorg/testrepo feature/test || rc=$?
			[[ "$rc" -eq 1 && "$FULL_LOOP_PRE_MERGE_BLOCKER_KIND" == github-api-read-deferred ]] || return 1
			[[ "$FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL" == 1893456000 ]] || return 1
			[[ "$FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL" == *'reason="fixture quota wait"'* ]] || return 1
			[[ ! -e "$TEST_ROOT/unexpected-exact-read" ]] || return 1
		done
	) || result=1
	print_result "local deferral survives ruleset resolution and cache without a fallback check read" "$result"
	return 0
}

test_exact_check_deferral_preserves_retry_deadline() {
	local result=0 output=""
	output=$(
		(
			local scripts_dir="${SCRIPT_DIR}/.." rc=0
			SCRIPT_DIR="$scripts_dir"
			# shellcheck source=/dev/null
			source "$scripts_dir/shared-constants.sh"
			# shellcheck source=/dev/null
			source "$scripts_dir/full-loop-helper-commit.sh"
			# shellcheck source=/dev/null
			source "$scripts_dir/full-loop-helper-merge.sh"
			aidevops_log_line() { return 0; }
			_required_contexts_for_default_branch() { printf '["required-ci"]\n'; }
			gh_pr_checks_exact_json() {
				printf '%s\n' 'gh_pr_checks_exact_json: [gh-transport] error_kind=github-api-read-deferred attempted=false deferred_by=local_admission retry_at=1893456000 reason="fixture exact-check wait" operation=required-check-rollup-read' >&2
				return 2
			}
			_full_loop_query_required_checks 42 testorg/testrepo feature/test || rc=$?
			[[ "$rc" -eq 1 ]] || return 1
			[[ "$FULL_LOOP_PRE_MERGE_BLOCKER_KIND" == github-api-read-deferred ]] || return 1
			[[ "$FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL" == 1893456000 ]] || return 1
			[[ "$FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL" == *'reason="fixture exact-check wait"'* ]] || return 1
			_merge_report_pre_merge_gate_failure
		) 2>&1
	) || result=1
	[[ "$output" == *'Merge deferred by GitHub read admission; retry_at=1893456000.'* ]] || result=1
	[[ "$output" == *'operation=required-check-rollup-read'* ]] || result=1
	print_result "exact-check deferral preserves its deadline through merge reporting" "$result" "output=$output"
	return 0
}
