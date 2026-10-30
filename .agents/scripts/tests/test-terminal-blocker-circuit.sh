#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#30926 unchanged terminal-blocker suppression.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TESTS_RUN=0
TESTS_FAILED=0
TEST_DEPENDENCIES='{"nodes":[],"truncated":false}'
TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
export AIDEVOPS_WORKER_BLOCKER_LOG_FILE="${TEST_ROOT}/captured-blockers.jsonl"
# GH#35310: isolate the recovery queue before any helper is sourced. Circuit
# opens call _hrff_enqueue_blocker_recovery, which shells out to
# terminal-blocker-recovery-helper.sh and would otherwise write owner/repo#42
# into the live ~/.aidevops queue and consume the pulse recovery budget.
export AIDEVOPS_BLOCKER_RECOVERY_DIR="${TEST_ROOT}/default-recovery-queue"
# Never consult the runner's registry, including from spawned helper CLIs.
export REPOS_JSON="${TEST_ROOT}/repos.json"
printf '{"initialized_repos":[{"slug":"owner/repo"}]}\n' >"$REPOS_JSON"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

print_result() {
	local name="$1"
	local status="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# shellcheck source=../terminal-blocker-circuit.sh
source "${SCRIPT_DIR}/terminal-blocker-circuit.sh"
# shellcheck source=../headless-runtime-failure.sh
source "${SCRIPT_DIR}/headless-runtime-failure.sh"

_terminal_blocker_dependency_signature() {
	local repo_slug="$1"
	local issue_number="$2"
	[[ -n "$repo_slug" && "$issue_number" =~ ^[0-9]+$ ]] || return 1
	[[ "$TEST_DEPENDENCIES" != "unavailable" ]] || return 1
	printf '%s\n' "$TEST_DEPENDENCIES"
	return 0
}

_terminal_blocker_target_revision() {
	local repo_path="$1"
	[[ -n "$repo_path" && "$TEST_TARGET_REVISION" != "unavailable" ]] || return 1
	printf '%s\n' "$TEST_TARGET_REVISION"
	return 0
}

test_normalized_blocker_fingerprint() {
	local first_output="${TEST_ROOT}/first.ndjson"
	local second_output="${TEST_ROOT}/second.ndjson"
	gh() { printf '%s\n' '{"body":"## How\nFix the helper"}'; return 0; }
	export WORKER_ISSUE_NUMBER=42 DISPATCH_REPO_SLUG="owner/repo"
	printf '%s\n' '{"type":"text","text":"BLOCKED: Canonical Files Scope heading is absent. runner=alpha session=ses_123"}' >"$first_output"
	printf '%s\n' '{"type":"text","text":"BLOCKED: Cannot edit until the brief declares permitted files. runner=beta attempt=two"}' >"$second_output"
	terminal_blocker_capture_output "$first_output"
	local first_fingerprint="$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT"
	terminal_blocker_capture_output "$second_output"
	local second_fingerprint="$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT"
	local status=1
	if [[ "$(_terminal_blocker_reason "$first_fingerprint")" == "missing_files_scope" && "$first_fingerprint" == "$second_fingerprint" ]]; then
		status=0
	fi
	unset -f gh
	unset WORKER_ISSUE_NUMBER DISPATCH_REPO_SLUG AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	print_result "different prose and runner identities converge on verified missing scope" "$status"
	return 0
}

test_worker_contract_reason_protocol() {
	# Load the real producer in a subshell so its sourced libraries cannot alter
	# the release-path fixture overrides used by the remaining tests.
	local contract="" reason="" output="${TEST_ROOT}/contract.ndjson" status=0
	contract=$(
		# shellcheck source=../headless-runtime-lib.sh
		source "${SCRIPT_DIR}/headless-runtime-lib.sh"
		append_worker_headless_contract '/full-loop Fix the scoped helper'
	) || status=1
	reason=$(printf '%s\n' "$contract" | rg '^TERMINAL_BLOCKER_REASON=target_code_blocker$') || status=1
	[[ $(printf '%s\n' "$contract" | rg -c '^TERMINAL_BLOCKER_REASON=source_access_blocked$') == 1 ]] || status=1
	[[ "$contract" == *'TERMINAL_BLOCKER_REASON=missing_files_scope'* &&
		"$contract" == *'SAME final assistant text message'* &&
		"$contract" == *'unknown evidence stays retryable'* ]] || status=1
	jq -nc --arg text "BLOCKED: target defect cannot be repaired in scope
${reason}" '{type:"text",part:{text:$text}}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == target_code_blocker ]] || status=1
	local issue='{"title":"Fix helper","body":"### Files Scope\n- helper.sh"}'
	local revision="" changed="" comments=""
	revision=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT")
	comments=$(jq -nc --arg body "<!-- aidevops:terminal-blocker-circuit revision=${revision} blocker=${AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT} -->" \
		'[{body:$body,created_at:"2026-08-31T10:00:00Z",author_association:"MEMBER"}]')
	terminal_blocker_circuit_active "$comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || status=1
	TEST_TARGET_REVISION='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
	changed=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT")
	[[ "$changed" != "$revision" ]] || status=1
	terminal_blocker_circuit_active "$comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null && status=1
	TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	unset AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	print_result "injected contract reason reaches capture and code-sensitive hold re-arms on target change" "$status"
	return 0
}

test_task_revision_inputs() {
	local issue_json='{"title":"Fix scope","body":"Files Scope: a.sh"}'
	local first="" same="" changed_body="" changed_dependency="" changed_target=""
	first=$(terminal_blocker_task_revision "$issue_json" "owner/repo" 42 "$TEST_ROOT")
	same=$(terminal_blocker_task_revision "$issue_json" "owner/repo" 42 "$TEST_ROOT")
	changed_body=$(terminal_blocker_task_revision '{"title":"Fix scope","body":"Files Scope: b.sh"}' "owner/repo" 42 "$TEST_ROOT")
	TEST_DEPENDENCIES='{"nodes":[{"number":9,"state":"CLOSED"}],"truncated":false}'
	changed_dependency=$(terminal_blocker_task_revision "$issue_json" "owner/repo" 42 "$TEST_ROOT")
	TEST_DEPENDENCIES='{"nodes":[],"truncated":false}'
	TEST_TARGET_REVISION='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
	changed_target=$(terminal_blocker_task_revision "$issue_json" "owner/repo" 42 "$TEST_ROOT")
	TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	local status=1
	if [[ "$first" == "$same" && "$first" != "$changed_body" &&
		"$first" != "$changed_dependency" && "$first" != "$changed_target" ]]; then
		status=0
	fi
	print_result "task revision binds brief, dependency state, and target revision" "$status"
	return 0
}

test_release_modes_and_retry() {
	local revision='111111111111111111111111'
	local blocker=""
	blocker=$(_terminal_blocker_hash 'v2:target_code_blocker')
	local observation="<!-- aidevops:terminal-blocker-observation revision=${revision} blocker=${blocker} -->"
	local circuit="<!-- aidevops:terminal-blocker-circuit revision=${revision} blocker=${blocker} -->"
	local empty='[]'
	local observed="[{\"body\":\"${observation}\",\"created_at\":\"2026-08-31T10:00:00Z\"}]"
	local opened="[{\"body\":\"${observation}\",\"created_at\":\"2026-08-31T10:00:00Z\"},{\"body\":\"${circuit}\",\"created_at\":\"2026-08-31T10:05:00Z\"}]"
	local retried="[{\"body\":\"${observation}\",\"created_at\":\"2026-08-31T10:00:00Z\"},{\"body\":\"${circuit}\",\"created_at\":\"2026-08-31T10:05:00Z\"},{\"body\":\"terminal-blocker-circuit:retry\",\"created_at\":\"2026-08-31T10:10:00Z\",\"author_association\":\"OWNER\"}]"
	observed=$(printf '%s' "$observed" | jq -c 'map(.author_association="OWNER")')
	opened=$(printf '%s' "$opened" | jq -c 'map(.author_association="OWNER")')
	retried=$(printf '%s' "$retried" | jq -c 'map(.author_association="OWNER")')
	local status=1
	if [[ "$(terminal_blocker_release_mode "$empty" "$revision" "$blocker")" == "first" &&
	"$(terminal_blocker_release_mode "$observed" "$revision" "$blocker")" == "circuit" &&
	"$(terminal_blocker_release_mode "$opened" "$revision" "$blocker")" == "open" &&
	"$(terminal_blocker_release_mode "$retried" "$revision" "$blocker")" == "first" ]]; then
		status=0
	fi
	print_result "second identical blocker opens a durable hold and maintainer retry re-arms it" "$status"
	return 0
}

test_dispatch_hold_revalidates_revision() {
	local issue_json='{"title":"Fix scope","body":"Files Scope: a.sh"}'
	local revision=""
	revision=$(terminal_blocker_task_revision "$issue_json" "owner/repo" 42 "$TEST_ROOT")
	local blocker=""
	blocker=$(_terminal_blocker_hash 'v2:target_code_blocker')
	local comments="[{\"body\":\"<!-- aidevops:terminal-blocker-circuit revision=${revision} blocker=${blocker} -->\",\"created_at\":\"2026-08-31T10:05:00Z\",\"author_association\":\"MEMBER\"}]"
	local same_status=0 changed_status=0 ambiguous_status=0
	terminal_blocker_circuit_active "$comments" "$issue_json" "owner/repo" 42 "$TEST_ROOT" >/dev/null || same_status=$?
	terminal_blocker_circuit_active "$comments" '{"title":"Fix scope","body":"Files Scope: b.sh"}' \
		"owner/repo" 42 "$TEST_ROOT" >/dev/null && changed_status=1
	TEST_DEPENDENCIES="unavailable"
	terminal_blocker_circuit_active "$comments" "$issue_json" "owner/repo" 42 "$TEST_ROOT" >/dev/null && ambiguous_status=1
	TEST_DEPENDENCIES='{"nodes":[],"truncated":false}'
	local status=1
	if [[ "$same_status" -eq 0 && "$changed_status" -eq 0 && "$ambiguous_status" -eq 0 ]]; then
		status=0
	fi
	print_result "dispatch hold is cross-runner durable but fails open on changed or ambiguous identity" "$status"
	return 0
}

test_release_integration_bounds_comments() {
	local test_comments='[]'
	local posted_count=0 first_body="" second_body="" cleanup_count=0
	terminal_blocker_fetch_trusted_comments() {
		local issue_number="$1"
		local repo_slug="$2"
		[[ "$issue_number" == "42" && "$repo_slug" == "owner/repo" ]] || return 1
		printf '%s\n' "$test_comments"
		return 0
	}
	_hrff_release_repo_state_is_managed() { return 0; }
	_hrff_resolve_release_runner_login() {
		printf 'runner-one\n'
		return 0
	}
	clear_active_status_on_release() {
		cleanup_count=$((cleanup_count + 1))
		return 0
	}
	set_issue_status() {
		[[ "$3" == "blocked" ]] || return 1
		cleanup_count=$((cleanup_count + 1))
		return 0
	}
	_unlock_issue_after_dispatch_release() {
		cleanup_count=$((cleanup_count + 1))
		return 0
	}
	gh() {
		if [[ "$1" == "api" && "$2" == "repos/owner/repo/issues/42" ]]; then
			printf '%s\n' '{"title":"Fix scope","body":"Files Scope: a.sh"}'
			return 0
		fi
		return 1
	}
	_hrff_post_claim_released_comment() {
		local issue_number="$1"
		local repo_slug="$2"
		local body="$3"
		[[ "$issue_number" == "42" && "$repo_slug" == "owner/repo" ]] || return 1
		posted_count=$((posted_count + 1))
		if [[ "$posted_count" -eq 1 ]]; then
			first_body="$body"
		else
			second_body="$body"
		fi
		local created_at="2026-08-31T10:0${posted_count}:00Z"
		test_comments=$(printf '%s' "$test_comments" | jq -c \
			--arg body "$body" --arg created_at "$created_at" \
			'. + [{body: $body, created_at: $created_at, author_association: "MEMBER"}]')
		return 0
	}

	export DISPATCH_REPO_SLUG="owner/repo"
	export WORKER_ISSUE_NUMBER=42
	export AIDEVOPS_TERMINAL_BLOCKER_REPO_PATH="$TEST_ROOT"
	AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT=$(_terminal_blocker_hash 'v2:target_code_blocker')
	export AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	_release_dispatch_claim "issue-42" "blocked"
	_release_dispatch_claim "issue-42" "blocked"
	_release_dispatch_claim "issue-42" "blocked"

	local status=1
	if [[ "$posted_count" -eq 2 && "$first_body" == *"aidevops:terminal-blocker-observation"* &&
		"$second_body" == *"TERMINAL_BLOCKER_CIRCUIT active=true observations=2"* &&
		"$second_body" == *"CLAIM_RELEASED reason=blocked"* && "$cleanup_count" -eq 6 ]]; then
		status=0
	fi
	print_result "release path posts one observation and one circuit comment across repeated blockers" "$status"
	test_comments='[]'
	posted_count=0
	cleanup_count=0
	AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT=$(_terminal_blocker_hash 'v2:unknown')
	_release_dispatch_claim "issue-42" "blocked"
	_release_dispatch_claim "issue-42" "blocked"
	_release_dispatch_claim "issue-42" "blocked"
	status=1
	if [[ "$posted_count" -eq 3 && "$cleanup_count" -eq 6 &&
		"$first_body" == *'reason=unknown owner=worker-triage'* &&
		"$second_body" == *'CLAIM_RELEASED reason=blocked'* && "$second_body" != *'Next action:'* ]]; then
		status=0
	fi
	print_result "unknown repeat releases each claim without repeating recovery prose or holding dispatch" "$status"
	unset DISPATCH_REPO_SLUG WORKER_ISSUE_NUMBER AIDEVOPS_TERMINAL_BLOCKER_REPO_PATH \
		AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	return 0
}

test_brief_only_revision() {
	local issue='{"title":"Fix helper","body":"## How\nFix helper"}'
	local first="" changed="" blocker="" comments="" status=0
	blocker=$(_terminal_blocker_hash 'v2:missing_files_scope')
	first=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" missing_files_scope)
	TEST_TARGET_REVISION='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
	TEST_DEPENDENCIES='unavailable'
	changed=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" missing_files_scope)
	[[ "$first" == "$changed" ]] || status=1
	comments=$(jq -nc --arg body "<!-- aidevops:terminal-blocker-circuit revision=${first} blocker=${blocker} -->" \
		'[{body:$body,created_at:"2026-08-31T10:00:00Z",author_association:"MEMBER"}]')
	terminal_blocker_circuit_active "$comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || status=1
	terminal_blocker_circuit_active "$comments" '{"title":"Fix helper","body":"### Files Scope\n- helper.sh"}' \
		owner/repo 42 "$TEST_ROOT" >/dev/null && status=1
	comments=$(printf '%s' "$comments" | jq -c '. + [{body:"terminal-blocker-circuit:retry",created_at:"2026-08-31T11:00:00Z",author_association:"MEMBER"}]')
	terminal_blocker_circuit_active "$comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null && status=1
	TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	TEST_DEPENDENCIES='{"nodes":[],"truncated":false}'
	print_result "brief hold ignores target/dependency changes but corrected brief and trusted retry re-arm" "$status"
	return 0
}

test_external_trigger_pending_revision() {
	local issue='{"title":"Wait for model","body":"### Files Scope\n- model.sh\nRun only after the model ID is published."}'
	local output="${TEST_ROOT}/external.ndjson" fingerprint="" revision="" changed="" comments="" status=0
	local observation="" circuit=""
	printf '%s\n' '{"type":"text","text":"BLOCKED: the required model ID is not yet published\nTERMINAL_BLOCKER_REASON=external_trigger_pending"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	fingerprint="$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT"
	[[ "$(_terminal_blocker_reason "$fingerprint")" == external_trigger_pending ]] || status=1
	revision=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" external_trigger_pending) || status=1
	observation=$(jq -nc --arg body "<!-- aidevops:terminal-blocker-observation revision=${revision} blocker=${fingerprint} -->" \
		'[{body:$body,created_at:"2026-08-31T10:00:00Z",author_association:"MEMBER"}]')
	[[ "$(terminal_blocker_release_mode "$observation" "$revision" "$fingerprint")" == circuit ]] || status=1
	TEST_TARGET_REVISION='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
	changed=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" external_trigger_pending) || status=1
	[[ "$revision" == "$changed" ]] || status=1
	[[ "$(terminal_blocker_release_mode "$observation" "$changed" "$fingerprint")" == circuit ]] || status=1
	circuit=$(jq -nc --arg body "<!-- aidevops:terminal-blocker-circuit revision=${changed} blocker=${fingerprint} -->" \
		'[{body:$body,created_at:"2026-08-31T10:05:00Z",author_association:"MEMBER"}]')
	terminal_blocker_circuit_active "$circuit" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || status=1
	terminal_blocker_circuit_active "$circuit" '{"title":"Wait for model","body":"### Files Scope\n- model.sh\nModel ID published."}' \
		owner/repo 42 "$TEST_ROOT" >/dev/null && status=1
	TEST_DEPENDENCIES='{"nodes":[{"number":9,"state":"CLOSED"}],"truncated":false}'
	changed=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" external_trigger_pending) || status=1
	[[ "$revision" != "$changed" ]] || status=1
	TEST_DEPENDENCIES=unavailable
	terminal_blocker_circuit_active "$circuit" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null && status=1
	TEST_DEPENDENCIES='{"nodes":[],"truncated":false}'
	comments=$(printf '%s' "$circuit" | jq -c '. + [{body:"terminal-blocker-circuit:retry",created_at:"2026-08-31T11:00:00Z",author_association:"MEMBER"}]')
	terminal_blocker_circuit_active "$comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null && status=1
	TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	unset AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	print_result "external trigger opens after two observations across HEAD changes; brief, dependency and retry re-arm" "$status"
	return 0
}

# GH#34223: the source_access_blocked producer marker used to normalize to
# unknown, restoring availability after every unchanged HTTP 401 denial.
test_source_access_blocked_revision() {
	local issue='{"title":"Read official docs","body":"Use the official reference."}'
	local output="${TEST_ROOT}/source-access.ndjson" fingerprint="" revision="" changed="" status=0
	local observation="" circuit="" comments="" recovery=""
	printf '%s\n' '{"type":"text","text":"BLOCKED: six official HTTP 401 Security Verification responses\nTERMINAL_BLOCKER_REASON=source_access_blocked"}' >"$output"
	gh() { printf '%s\n' '{"body":"Use the official reference."}'; return 0; }
	export WORKER_ISSUE_NUMBER=42 DISPATCH_REPO_SLUG="owner/repo"
	terminal_blocker_capture_output "$output" || status=1
	unset -f gh
	unset WORKER_ISSUE_NUMBER DISPATCH_REPO_SLUG
	fingerprint="$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT"
	# A missing Files Scope heading must not mask the evidenced access denial.
	[[ "$(_terminal_blocker_reason "$fingerprint")" == source_access_blocked ]] || status=1
	recovery=$(_terminal_blocker_recovery "$fingerprint" circuit)
	[[ "$recovery" == *"reason=source_access_blocked owner=access-owner "* ]] || status=1
	[[ "$recovery" == *"Never bypass source verification"* ]] || status=1
	revision=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" source_access_blocked) || status=1
	observation=$(jq -nc --arg body "<!-- aidevops:terminal-blocker-observation revision=${revision} blocker=${fingerprint} -->" \
		'[{body:$body,created_at:"2026-08-31T10:00:00Z",author_association:"MEMBER"}]')
	[[ "$(terminal_blocker_release_mode "$observation" "$revision" "$fingerprint")" == circuit ]] || status=1
	terminal_blocker_circuit_comment "CLAIM_RELEASED reason=blocked" "$revision" "$fingerprint" >/dev/null || status=1
	TEST_TARGET_REVISION='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
	changed=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" source_access_blocked) || status=1
	[[ "$revision" == "$changed" ]] || status=1
	circuit=$(jq -nc --arg body "<!-- aidevops:terminal-blocker-circuit revision=${changed} blocker=${fingerprint} -->" \
		'[{body:$body,created_at:"2026-08-31T10:05:00Z",author_association:"MEMBER"}]')
	terminal_blocker_circuit_active "$circuit" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || status=1
	terminal_blocker_circuit_active "$circuit" '{"title":"Read official docs","body":"Official reference excerpt attached."}' \
		owner/repo 42 "$TEST_ROOT" >/dev/null && status=1
	TEST_DEPENDENCIES='{"nodes":[{"number":9,"state":"CLOSED"}],"truncated":false}'
	terminal_blocker_circuit_active "$circuit" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null && status=1
	TEST_DEPENDENCIES='{"nodes":[],"truncated":false}'
	comments=$(printf '%s' "$circuit" | jq -c '. + [{body:"terminal-blocker-circuit:retry",created_at:"2026-08-31T11:00:00Z",author_association:"MEMBER"}]')
	terminal_blocker_circuit_active "$comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null && status=1
	comments=$(printf '%s' "$circuit" | jq -c '. + [{body:"terminal-blocker-circuit:retry",created_at:"2026-08-31T11:00:00Z",author_association:"COLLABORATOR"}]')
	terminal_blocker_circuit_active "$comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || status=1
	TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	unset AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	print_result "source_access_blocked holds across unrelated HEAD changes; brief, dependency and trusted retry re-arm" "$status"
	return 0
}

# GH#35685: a missing Files Scope heading must not overwrite an explicit
# input_required owner or external trigger; malformed signals still infer scope.
test_explicit_blocker_survives_missing_scope() {
	local output="${TEST_ROOT}/explicit-no-scope.ndjson" status=0
	gh() { printf '%s\n' '{"body":"No scope heading here."}'; return 0; }
	export WORKER_ISSUE_NUMBER=42 DISPATCH_REPO_SLUG="owner/repo"
	printf '%s\n' '{"type":"text","text":"BLOCKED: duplicate rejected\nTERMINAL_BLOCKER_REASON=input_required\nTERMINAL_BLOCKER_INPUT_OWNER=admin"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == input_required ]] || status=1
	[[ "$(_terminal_blocker_input_owner "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == admin ]] || status=1
	printf '%s\n' '{"type":"text","text":"BLOCKED: waiting for model ID\nTERMINAL_BLOCKER_REASON=external_trigger_pending"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == external_trigger_pending ]] || status=1
	# Malformed owner fails closed to the structural missing-scope inference.
	printf '%s\n' '{"type":"text","text":"BLOCKED: unsure\nTERMINAL_BLOCKER_REASON=input_required\nTERMINAL_BLOCKER_INPUT_OWNER=human"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == missing_files_scope ]] || status=1
	# Absent signal likewise.
	printf '%s\n' '{"type":"text","text":"BLOCKED: stuck"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == missing_files_scope ]] || status=1
	unset -f gh
	unset WORKER_ISSUE_NUMBER DISPATCH_REPO_SLUG AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	print_result "explicit input_required/external_trigger_pending survive missing Files Scope; malformed signals infer scope" "$status"
	return 0
}

test_input_required_owner_class() {
	local issue='{"title":"Deploy check","body":"### Files Scope\n- deploy.sh"}'
	local output="${TEST_ROOT}/input.ndjson" fingerprint="" revision="" changed="" fragment="" observation="" status=0
	printf '%s\n' '{"type":"text","text":"BLOCKED: no authorized staging origin is recorded\nTERMINAL_BLOCKER_REASON=input_required\nTERMINAL_BLOCKER_INPUT_OWNER=maintainer"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	fingerprint="$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT"
	[[ "$(_terminal_blocker_reason "$fingerprint")" == input_required ]] || status=1
	[[ "$(_terminal_blocker_input_owner "$fingerprint")" == maintainer ]] || status=1
	fragment=$(terminal_blocker_observation_fragment 111111111111111111111111 "$fingerprint" first)
	[[ "$fragment" == *'reason=input_required owner=maintainer'* && "$fragment" == *'status:available'* ]] || status=1
	# One worker cannot hold alone: first observation keeps a verification attempt.
	revision=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" input_required) || status=1
	[[ "$(terminal_blocker_release_mode '[]' "$revision" "$fingerprint")" == first ]] || status=1
	observation=$(jq -nc --arg body "<!-- aidevops:terminal-blocker-observation revision=${revision} blocker=${fingerprint} -->" \
		'[{body:$body,created_at:"2026-08-31T10:00:00Z",author_association:"MEMBER"}]')
	[[ "$(terminal_blocker_release_mode "$observation" "$revision" "$fingerprint")" == circuit ]] || status=1
	TEST_TARGET_REVISION='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
	changed=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" input_required) || status=1
	[[ "$revision" == "$changed" ]] || status=1
	changed=$(terminal_blocker_task_revision '{"title":"Deploy check","body":"### Files Scope\n- deploy.sh\nStaging origin: supplied"}' \
		owner/repo 42 "$TEST_ROOT" input_required) || status=1
	[[ "$revision" != "$changed" ]] || status=1
	TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	# Missing, invalid or duplicated owners stay unclassified and retryable.
	printf '%s\n' '{"type":"text","text":"BLOCKED: unsure\nTERMINAL_BLOCKER_REASON=input_required"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == unknown ]] || status=1
	printf '%s\n' '{"type":"text","text":"BLOCKED: unsure\nTERMINAL_BLOCKER_REASON=input_required\nTERMINAL_BLOCKER_INPUT_OWNER=human"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == unknown ]] || status=1
	_terminal_blocker_input_owner "$(_terminal_blocker_hash 'v2:target_code_blocker')" >/dev/null && status=1
	unset AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	print_result "input_required names a user/contributor/maintainer/admin owner, needs two observations and re-arms on brief change" "$status"
	return 0
}

test_unknown_and_redaction() {
	local output="${TEST_ROOT}/unknown.ndjson" fingerprint="" fragment="" comments="" status=0
	printf '%s\n' '{"type":"text","text":"BLOCKED: private-token /private/runner/file.sh ambiguous failure"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	fingerprint="$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT"
	[[ "$(_terminal_blocker_reason "$fingerprint")" == unknown ]] || status=1
	fragment=$(WORKER_SESSION_KEY='/private/runner/private-token' terminal_blocker_observation_fragment 111111111111111111111111 "$fingerprint")
	[[ "$fragment" == *'reason=unknown owner=worker-triage'* && "$fragment" == *'Next action:'* &&
		"$fragment" != *'private-token'* && "$fragment" != *'/private/'* ]] || status=1
	comments=$(jq -nc --arg body "$fragment" '[{body:$body,created_at:"2026-08-31T10:00:00Z",author_association:"MEMBER"}]')
	[[ "$(terminal_blocker_release_mode "$comments" 111111111111111111111111 "$fingerprint")" == normal ]] || status=1
	terminal_blocker_circuit_comment release 111111111111111111111111 "$fingerprint" >/dev/null && status=1
	terminal_blocker_circuit_active "$comments" '{}' owner/repo 42 "$TEST_ROOT" >/dev/null && status=1
	printf '%s\n' '{"type":"tool","text":"BLOCKED: fake tool result"}' >"$output"
	terminal_blocker_capture_output "$output" && status=1
	[[ -z "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT" ]] || status=1
	print_result "unknown evidence is redacted, bounded, and never creates a global hold; tool text is ignored" "$status"
	return 0
}

test_excluded_scope_revision() {
	local issue='{"title":"Fix integration","body":"### Files Scope\n- helper.sh"}'
	local output="${TEST_ROOT}/scope.ndjson" first="" changed="" fragment="" status=0
	printf '%s\n' '{"type":"text","part":{"text":"BLOCKED: necessary adjacent integration excluded\nTERMINAL_BLOCKER_REASON=files_scope_excluded"}}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == files_scope_excluded ]] || status=1
	first=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" files_scope_excluded)
	TEST_TARGET_REVISION='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
	TEST_DEPENDENCIES='unavailable'
	changed=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" files_scope_excluded)
	[[ "$first" == "$changed" ]] || status=1
	changed=$(terminal_blocker_task_revision '{"title":"Fix integration","body":"### Files Scope\n- helper.sh\n- adjacent.sh"}' owner/repo 42 "$TEST_ROOT" files_scope_excluded)
	[[ "$first" != "$changed" ]] || status=1
	fragment=$(_terminal_blocker_recovery "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")
	[[ "$fragment" == *'AI brief owner'* && "$fragment" == *'do not retry an unchanged brief'* ]] || status=1
	TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	TEST_DEPENDENCIES='{"nodes":[],"truncated":false}'
	unset AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	print_result "excluded integration scope re-arms on brief correction, not unrelated code or API reads" "$status"
	return 0
}

test_final_dossier_and_structural_precedence() {
	local output="${TEST_ROOT}/final.ndjson" status=0
	printf '%s\n' '{"type":"text","text":"BLOCKED: defect\nTERMINAL_BLOCKER_REASON=target_code_blocker"}' \
		'{"type":"text","text":"The earlier blocker is resolved."}' >"$output"
	terminal_blocker_capture_output "$output" && status=1
	[[ -z "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT" ]] || status=1
	printf '%s\n' '{"type":"text","text":"BLOCKED: uncertain\nTERMINAL_BLOCKER_REASON=target_code_blocker\nTERMINAL_BLOCKER_REASON=unsupported"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == unknown ]] || status=1
	gh() { printf '%s\n' '{"body":"## How\nFix helper"}'; return 0; }
	export WORKER_ISSUE_NUMBER=42 DISPATCH_REPO_SLUG="owner/repo"
	printf '%s\n' '{"type":"text","text":"BLOCKED: defect\nTERMINAL_BLOCKER_REASON=target_code_blocker"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == missing_files_scope ]] || status=1
	unset -f gh
	unset WORKER_ISSUE_NUMBER DISPATCH_REPO_SLUG AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	print_result "resolved dossiers and mixed reasons cannot hold; verified missing scope takes precedence" "$status"
	return 0
}

# A classified BLOCKED exit must record evidence before any hold; an exit that
# records none stays dispatchable instead of an ownerless status:blocked.
test_unrecorded_blocked_exit_stays_dispatchable() {
	local status=0
	if ! (
		local output="${TEST_ROOT}/unrecorded.ndjson" posted="" edits="" projection=""
		# shellcheck source=../headless-runtime-model.sh
		source "${SCRIPT_DIR}/headless-runtime-model.sh" >/dev/null 2>&1 || exit 1
		printf '%s\n' '{"type":"text","text":"**BLOCKED — runtime policy denied the PR helper.**"}' >"$output"
		output_has_blocked_signal "$output" || exit 1
		terminal_blocker_capture_output "$output" false "$_HEADLESS_BLOCKED_LINE_PATTERN" || exit 1
		[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == unknown ]] || exit 1
		# Runtime-injected text is not the final model report.
		printf '%s\n' '{"type":"text","text":"BLOCKED: denied"}' \
			'{"type":"text","part":{"synthetic":true,"text":"Continue."}}' >"$output"
		terminal_blocker_capture_output "$output" || exit 1
		# Claude stream-json reports only through its final result event.
		printf '%s\n' '{"type":"system","subtype":"init"}' \
			'{"type":"result","subtype":"success","result":"Stopped.\n**BLOCKED — denied.**"}' >"$output"
		output_has_blocked_signal "$output" || exit 1
		terminal_blocker_capture_output "$output" false "$_HEADLESS_BLOCKED_LINE_PATTERN" || exit 1
		export DISPATCH_REPO_SLUG=owner/repo WORKER_ISSUE_NUMBER=42 AIDEVOPS_TERMINAL_BLOCKER_REPO_PATH="$TEST_ROOT"
		AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT=""
		gh_issue_edit_safe() { edits+="$*;"; return 0; }
		local persisted_comments="[]"
		terminal_blocker_fetch_trusted_comments() { printf '%s\n' "$persisted_comments"; return 0; }
		_hrff_release_repo_state_is_managed() { return 0; }
		_hrff_resolve_release_runner_login() { printf 'runner-one\n'; return 0; }
		_unlock_issue_after_dispatch_release() { return 0; }
		_hrff_post_claim_released_comment() { posted="$3"; return 0; }
		clear_active_status_on_release() { projection="$4"; return 0; }
		_release_dispatch_claim issue-42 blocked || exit 1
		[[ "$posted" == *'CLAIM_RELEASED reason=blocked '*' evidence=unrecorded'* &&
			"$posted" != *'terminal-blocker-observation'* ]] || exit 1
		[[ -z "$edits" && "$projection" == available ]] || exit 1
		# A retry after the receipt persisted keeps the receipt's projection.
		persisted_comments=$(jq -nc --arg body "$posted" '[
			{id:1,body:"DISPATCH_CLAIM nonce=a runner=runner-one",author:"runner-one",author_association:"COLLABORATOR",created_at:"2026-10-30T08:00:00Z"},
			{id:2,body:$body,author:"runner-one",author_association:"COLLABORATOR",created_at:"2026-10-30T08:01:00Z"}]') || exit 1
		posted="" projection=""
		_release_dispatch_claim issue-42 blocked || exit 1
		[[ -z "$posted" && -z "$edits" && "$projection" == available ]] || exit 1
	); then
		status=1
	fi
	print_result "classified blocked exits capture evidence; unrecorded ones stay dispatchable" "$status"
	return 0
}

test_legacy_blocked_backoff() {
	local comments="" changed="" result="" status=0
	# No local metrics, fingerprints or task revision: reproduce legacy releases
	# by two runners, as seen on GH#31378. Exercise the actual dispatch gate.
	comments=$(jq -nc '[range(2) | {id:(. + 1), body:("<!-- ops:start -->\nCLAIM_RELEASED reason=blocked runner=runner-" + tostring + " ts=ignored\n<!-- ops:end -->"), author:("runner-" + tostring), author_association:"MEMBER", created_at:"2026-09-06T12:00:00Z"}]')
	result=$(TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_circuit_active "$comments" '{}' owner/repo 42 '') || status=1
	[[ "$result" == 'TERMINAL_BLOCKER_BACKOFF failures=2 retry_after=1788696900' ]] || status=1
	TERMINAL_BLOCKER_NOW_EPOCH=1788696900 terminal_blocker_backoff_active "$comments" >/dev/null && status=1
	changed=$(printf '%s' "$comments" | jq -c '.[0:1]')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed" >/dev/null && status=1
	changed=$(printf '%s' "$comments" | jq -c '. + [{body:"terminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-09-06T12:00:01Z"}]')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696002 terminal_blocker_backoff_active "$changed" >/dev/null && status=1
	changed=$(jq -nc '[range(400) | {body:"CLAIM_RELEASED reason=blocked runner=runner ts=ignored",author:"runner",author_association:"OWNER",created_at:"2026-09-06T12:00:00Z"}]')
	result=$(TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed") || status=1
	[[ "$result" == 'TERMINAL_BLOCKER_BACKOFF failures=400 retry_after=1788782400' ]] || status=1
	TERMINAL_BLOCKER_NOW_EPOCH=1788782400 terminal_blocker_backoff_active "$changed" >/dev/null && status=1
	print_result "legacy blocked releases impose cross-runner exponential backoff with expiry, cap and trusted retry" "$status"
	return 0
}

test_blocked_backoff_trust() {
	local comments="" changed="" association="" status=0
	comments=$(jq -nc '[range(2) | {body:"CLAIM_RELEASED reason=blocked runner=runner ts=ignored",author:"runner",author_association:"OWNER",created_at:"2026-09-06T12:00:00Z"}]')
	for association in COLLABORATOR CONTRIBUTOR NONE; do
		changed=$(printf '%s' "$comments" | jq -c --arg association "$association" 'map(.author_association=$association)')
		TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed" >/dev/null && status=1
	done
	changed=$(printf '%s' "$comments" | jq -c 'map(.author="impostor")')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed" >/dev/null && status=1
	changed=$(printf '%s' "$comments" | jq -c 'map(.body="> " + .body)')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed" >/dev/null && status=1
	TERMINAL_BLOCKER_NOW_EPOCH=1788695999 terminal_blocker_backoff_active "$comments" >/dev/null && status=1
	changed=$(printf '%s' "$comments" | jq -c 'map(.created_at="invalid")')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed" >/dev/null && status=1
	changed=$(printf '%s' "$comments" | jq -c '. + [{body:"terminal-blocker-circuit:retry",author_association:"COLLABORATOR",created_at:"2026-09-06T12:00:01Z"}]')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696002 terminal_blocker_backoff_active "$changed" >/dev/null || status=1
	changed=$(printf '%s' "$comments" | jq -c '. + [{body:"A maintainer can post terminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-09-06T12:00:01Z"}]')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696002 terminal_blocker_backoff_active "$changed" >/dev/null || status=1
	print_result "backoff rejects untrusted, forged, quoted, invalid and future evidence; recovery prose cannot reset it" "$status"
	return 0
}

test_permission_blocker_continuation() {
	local output="${TEST_ROOT}/permission.ndjson" status=0 fingerprint="" revision="" changed="" comments="" contract=""
	contract=$(
		# shellcheck source=../headless-runtime-lib.sh
		source "${SCRIPT_DIR}/headless-runtime-lib.sh"
		append_worker_headless_contract '/full-loop Resume after source denial'
	) || status=1
	[[ "$contract" == *'TERMINAL_BLOCKER_REASON=permission_required'* ]] || status=1
	[[ "$contract" == *'host-local lock or serialization guard'* ]] || status=1
	printf '%s\n' '{"type":"text","part":{"text":"BLOCKED: prior protected-source denial has no changed exact-context grant\nTERMINAL_BLOCKER_REASON=permission_required"}}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	fingerprint="$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT"
	[[ "$(_terminal_blocker_reason "$fingerprint")" == permission_required ]] || status=1
	revision=$(terminal_blocker_task_revision '{}' owner/repo 42 '') || status=1
	TEST_DEPENDENCIES=unavailable
	TEST_TARGET_REVISION=unavailable
	changed=$(terminal_blocker_task_revision '{"body":"changed brief"}' owner/repo 42 '') || status=1
	[[ "$revision" == "$changed" ]] || status=1
	comments=$(jq -nc --arg body "<!-- aidevops:terminal-blocker-circuit revision=${revision} blocker=${fingerprint} -->" '[{body:$body,created_at:"2026-09-06T12:00:00Z",author_association:"OWNER"}]')
	terminal_blocker_circuit_active "$comments" '{}' owner/repo 42 '' >/dev/null || status=1
	terminal_blocker_circuit_active "$comments" '{}' owner/repo 43 '' >/dev/null && status=1
	changed=$(printf '%s' "$comments" | jq -c 'map(.author_association="COLLABORATOR")')
	terminal_blocker_circuit_active "$changed" '{}' owner/repo 42 '' >/dev/null && status=1
	changed=$(printf '%s' "$comments" | jq -c '. + [.[0] | .author_association="COLLABORATOR" | .created_at="2026-09-06T12:00:30Z" | .body |= sub("revision=[a-f0-9]+"; "revision=aaaaaaaaaaaaaaaaaaaaaaaa")]')
	terminal_blocker_circuit_active "$changed" '{}' owner/repo 42 '' >/dev/null || status=1
	changed=$(printf '%s' "$comments" | jq -c '. + [{body:"terminal-blocker-circuit:retry",created_at:"2026-09-06T12:01:00Z",author_association:"COLLABORATOR"}]')
	terminal_blocker_circuit_active "$changed" '{}' owner/repo 42 '' >/dev/null || status=1
	changed=$(printf '%s' "$comments" | jq -c '. + [{body:"Please post terminal-blocker-circuit:retry",created_at:"2026-09-06T12:01:00Z",author_association:"OWNER"}]')
	terminal_blocker_circuit_active "$changed" '{}' owner/repo 42 '' >/dev/null || status=1
	local tied="" variant="" id=""
	tied=$(printf '%s' "$comments" | jq -c '.[0].id=10 | . + [{id:11,body:"terminal-blocker-circuit:retry",created_at:.[0].created_at,author_association:"OWNER"}]')
	terminal_blocker_circuit_active "$tied" '{}' owner/repo 42 '' >/dev/null && status=1
	[[ "$(terminal_blocker_release_mode "$tied" "$revision" "$fingerprint")" == first ]] || status=1
	variant=$(printf '%s' "$tied" | jq -c 'reverse')
	terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null && status=1
	variant=$(printf '%s' "$tied" | jq -c '.[0].id=12')
	terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null || status=1
	[[ "$(terminal_blocker_release_mode "$variant" "$revision" "$fingerprint")" == open ]] || status=1
	variant=$(printf '%s' "$tied" | jq -c '. + [.[0] | .id=12] | reverse')
	terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null || status=1
	variant=$(printf '%s' "$tied" | jq -c '. + [.[1] | .id=9] | reverse')
	terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null && status=1
	[[ "$(_terminal_blocker_latest_retry_at "$variant")" == '2026-09-06T12:00:00Z' ]] || status=1
	# Missing, malformed and equal IDs cannot prove that a tied retry is later.
	for id in null '"11"' -1 11.5 9007199254740992 10; do
		variant=$(printf '%s' "$tied" | jq -c --argjson id "$id" '.[1].id=$id')
		terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null || status=1
		[[ "$(terminal_blocker_release_mode "$variant" "$revision" "$fingerprint")" == open ]] || status=1
	done
	variant=$(printf '%s' "$tied" | jq -c 'del(.[0].id)')
	terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null || status=1
	variant=$(printf '%s' "$tied" | jq -c '.[1].author_association="COLLABORATOR"')
	terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null || status=1
	variant=$(printf '%s' "$tied" | jq -c '.[1].body="> terminal-blocker-circuit:retry"')
	terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null || status=1
	variant=$(printf '%s' "$tied" | jq -c '.[1].created_at="invalid"')
	terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null || status=1
	print_result "same-second permission retry ordering is conservative and independent of input order" "$status"
	comments=$(printf '%s' "$comments" | jq -c '. + [{body:"terminal-blocker-circuit:retry",created_at:"2026-09-06T12:01:00Z",author_association:"OWNER"}]')
	terminal_blocker_circuit_active "$comments" '{}' owner/repo 42 '' >/dev/null && status=1
	[[ "$(_terminal_blocker_recovery "$fingerprint")" == *'Retry is scheduling consent only'* ]] || status=1
	TEST_DEPENDENCIES='{"nodes":[],"truncated":false}'
	TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	unset AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	print_result "continued permission denial has a stable class; edits and API outages do not re-arm; retry grants nothing" "$status"
	return 0
}

test_permission_blocker_stays_in_generic_lifecycle() {
	local helper="${TEST_ROOT}/permission-helper-stub.sh"
	local helper_log="${TEST_ROOT}/permission-helper.log"
	local status=0
	cat >"$helper" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$AIDEVOPS_TEST_PERMISSION_HELPER_LOG"
SH
	chmod +x "$helper"
	AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT=$(_terminal_blocker_hash 'v2:permission_required')
	export AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	AIDEVOPS_WORKER_PERMISSION_HELPER="$helper" \
		AIDEVOPS_TEST_PERMISSION_HELPER_LOG="$helper_log" \
		_hrff_apply_terminal_permission_hold 42 owner/repo || status=1
	[[ ! -e "$helper_log" ]] || status=1
	AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT=$(_terminal_blocker_hash 'v2:target_code_blocker')
	AIDEVOPS_WORKER_PERMISSION_HELPER="$helper" \
		AIDEVOPS_TEST_PERMISSION_HELPER_LOG="$helper_log" \
		_hrff_apply_terminal_permission_hold 42 owner/repo || status=1
	[[ ! -e "$helper_log" ]] || status=1
	unset AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	print_result "terminal-only permission blockers do not impersonate scoped permission requests" "$status"
	return 0
}

test_same_second_release_ordering() {
	local comments="" changed="" marker="" selected="" fingerprint="" status=0
	fingerprint=$(_terminal_blocker_hash 'v2:target_code_blocker')
	marker="<!-- aidevops:terminal-blocker-observation revision=111111111111111111111111 blocker=${fingerprint} -->"
	comments=$(jq -nc --arg body "$marker" '[{id:10,body:$body,created_at:"2026-09-06T12:00:00Z",author_association:"MEMBER"}, {id:11,body:"terminal-blocker-circuit:retry",created_at:"2026-09-06T12:00:00Z",author_association:"OWNER"}]')
	[[ "$(terminal_blocker_release_mode "$comments" 111111111111111111111111 "$fingerprint")" == first ]] || status=1
	changed=$(printf '%s' "$comments" | jq -c '. + [.[0] | .id=12] | reverse')
	[[ "$(terminal_blocker_release_mode "$changed" 111111111111111111111111 "$fingerprint")" == circuit ]] || status=1
	selected=$(_terminal_blocker_latest_marker "$changed" "$marker" | jq -r '.id')
	[[ "$selected" == 12 ]] || status=1
	comments=$(jq -nc '[range(10;12) | {id:.,body:"CLAIM_RELEASED reason=blocked runner=runner ts=ignored",author:"runner",author_association:"OWNER",created_at:"2026-09-06T12:00:00Z"}] + [{id:12,body:"terminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-09-06T12:00:00Z"}]')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$comments" >/dev/null && status=1
	changed=$(printf '%s' "$comments" | jq -c '. + [.[0] | .id=13] | reverse')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed" >/dev/null && status=1
	changed=$(printf '%s' "$comments" | jq -c '. + [.[0] | .id=13] + [.[1] | .id=14] | reverse')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed" >/dev/null || status=1
	changed=$(printf '%s' "$comments" | jq -c 'map(del(.id))')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed" >/dev/null || status=1
	changed=$(printf '%s' "$comments" | jq -c '.[2].body += "\naidevops:terminal-blocker-circuit"')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$changed" >/dev/null || status=1
	print_result "same-second observations and post-retry releases survive reordered evidence; legacy ties retain bounded backoff" "$status"
	return 0
}

# GH#33025: a runner that GitHub reports as a bare COLLABORATOR (e.g. a bot
# account on a personal private repo) must still see its own observations,
# circuits and releases; otherwise every attempt posts a fresh observation and
# identical blockers redispatch forever. Other collaborators stay untrusted and
# only OWNER/MEMBER retries clear the hold.
test_self_authored_collaborator_evidence() {
	local status=0 fingerprint="" revision="" observation="" circuit="" comments="" changed="" diag=""
	fingerprint=$(_terminal_blocker_hash 'v2:permission_required')
	revision=$(terminal_blocker_task_revision '{}' owner/repo 42 '' permission_required) || status=1
	observation="<!-- aidevops:terminal-blocker-observation revision=${revision} blocker=${fingerprint} -->"
	circuit="<!-- aidevops:terminal-blocker-circuit revision=${revision} blocker=${fingerprint} -->"
	comments=$(jq -nc --arg body "$observation" '[{id:20,body:$body,author:"runner-bot",author_association:"COLLABORATOR",created_at:"2026-09-06T12:00:00Z"}]')
	[[ "$(terminal_blocker_release_mode "$comments" "$revision" "$fingerprint" 2>/dev/null)" == first ]] || status=1
	[[ "$(TERMINAL_BLOCKER_SELF_LOGIN=runner-bot terminal_blocker_release_mode "$comments" "$revision" "$fingerprint")" == circuit ]] || status=1
	[[ "$(TERMINAL_BLOCKER_SELF_LOGIN=other-bot terminal_blocker_release_mode "$comments" "$revision" "$fingerprint" 2>/dev/null)" == first ]] || status=1
	# Only plain logins are accepted as self identities.
	[[ "$(TERMINAL_BLOCKER_SELF_LOGIN='runner-bot"' terminal_blocker_release_mode "$comments" "$revision" "$fingerprint" 2>/dev/null)" == first ]] || status=1
	# GH#35569: extend the self/foreign trust matrix to app/private-org reads.
	local association="" variant=""
	for association in CONTRIBUTOR NONE; do
		variant=$(printf '%s' "$comments" | jq -c --arg a "$association" 'map(.author_association=$a)')
		[[ "$(TERMINAL_BLOCKER_SELF_LOGIN=runner-bot terminal_blocker_release_mode "$variant" "$revision" "$fingerprint")" == circuit ]] || status=1
		[[ "$(TERMINAL_BLOCKER_SELF_LOGIN=other-bot terminal_blocker_release_mode "$variant" "$revision" "$fingerprint" 2>/dev/null)" == first ]] || status=1
		variant=$(printf '%s' "$variant" | jq -c --arg body "$circuit" '.[0].body=$body')
		TERMINAL_BLOCKER_SELF_LOGIN=runner-bot terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null || status=1
		variant=$(printf '%s' "$variant" | jq -c --arg a "$association" '. + [{id:22,body:"terminal-blocker-circuit:retry",author:"runner-bot",author_association:$a,created_at:"2026-09-06T12:10:00Z"}]')
		TERMINAL_BLOCKER_SELF_LOGIN=runner-bot terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null || status=1
		variant=$(printf '%s' "$variant" | jq -c '.[1].author_association="OWNER"')
		TERMINAL_BLOCKER_SELF_LOGIN=runner-bot terminal_blocker_circuit_active "$variant" '{}' owner/repo 42 '' >/dev/null && status=1
	done
	comments=$(jq -nc --arg body "$circuit" '[{id:21,body:$body,author:"runner-bot",author_association:"COLLABORATOR",created_at:"2026-09-06T12:05:00Z"}]')
	terminal_blocker_circuit_active "$comments" '{}' owner/repo 42 '' >/dev/null 2>&1 && status=1
	TERMINAL_BLOCKER_SELF_LOGIN=runner-bot terminal_blocker_circuit_active "$comments" '{}' owner/repo 42 '' >/dev/null || status=1
	# A different collaborator cannot open a hold by copying the marker.
	changed=$(printf '%s' "$comments" | jq -c '.[0].author="other-collab"')
	TERMINAL_BLOCKER_SELF_LOGIN=runner-bot terminal_blocker_circuit_active "$changed" '{}' owner/repo 42 '' >/dev/null 2>&1 && status=1
	# Self or other collaborator retries cannot clear; OWNER/MEMBER retries can.
	changed=$(printf '%s' "$comments" | jq -c '. + [{id:22,body:"terminal-blocker-circuit:retry",author:"runner-bot",author_association:"COLLABORATOR",created_at:"2026-09-06T12:10:00Z"}]')
	TERMINAL_BLOCKER_SELF_LOGIN=runner-bot terminal_blocker_circuit_active "$changed" '{}' owner/repo 42 '' >/dev/null || status=1
	changed=$(printf '%s' "$comments" | jq -c '. + [{id:22,body:"terminal-blocker-circuit:retry",author:"repo-owner",author_association:"OWNER",created_at:"2026-09-06T12:10:00Z"}]')
	TERMINAL_BLOCKER_SELF_LOGIN=runner-bot terminal_blocker_circuit_active "$changed" '{}' owner/repo 42 '' >/dev/null && status=1
	# Backoff counts self-authored releases only when runner= matches the author.
	comments=$(jq -nc '[range(2) | {id:(30 + .),body:"CLAIM_RELEASED reason=blocked runner=runner-bot ts=ignored",author:"runner-bot",author_association:"COLLABORATOR",created_at:"2026-09-06T12:00:00Z"}]')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_backoff_active "$comments" >/dev/null && status=1
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 TERMINAL_BLOCKER_SELF_LOGIN=runner-bot terminal_blocker_backoff_active "$comments" >/dev/null || status=1
	changed=$(printf '%s' "$comments" | jq -c 'map(.author="other-collab")')
	TERMINAL_BLOCKER_NOW_EPOCH=1788696001 TERMINAL_BLOCKER_SELF_LOGIN=runner-bot terminal_blocker_backoff_active "$changed" >/dev/null && status=1
	# Dropped hold evidence is reported, never silently ignored.
	diag=$(TERMINAL_BLOCKER_NOW_EPOCH=1788696001 terminal_blocker_circuit_active "$comments" '{}' owner/repo 42 '' 2>&1 >/dev/null) || true
	[[ "$diag" == *'TERMINAL_BLOCKER_EVIDENCE_IGNORED count=2 reason=non_authoritative_author self_login=unset'* ]] || status=1
	diag=$(TERMINAL_BLOCKER_NOW_EPOCH=1788696001 TERMINAL_BLOCKER_SELF_LOGIN=runner-bot terminal_blocker_circuit_active "$comments" '{}' owner/repo 42 '' 2>&1 >/dev/null) || true
	[[ "$diag" != *'TERMINAL_BLOCKER_EVIDENCE_IGNORED'* ]] || status=1
	print_result "collaborator runner recognises only its own hold evidence; OWNER/MEMBER retry still required" "$status"
	return 0
}

# GH#33025 regression: repeated identical blockers from a collaborator runner
# post one observation and one circuit instead of an observation per attempt.
test_collaborator_runner_release_opens_circuit() {
	local test_comments='[]' posted_count=0 status=1 last_body=""
	terminal_blocker_fetch_trusted_comments() {
		printf '%s\n' "$test_comments"
		return 0
	}
	_hrff_release_repo_state_is_managed() { return 0; }
	_hrff_resolve_release_runner_login() {
		printf 'runner-bot\n'
		return 0
	}
	clear_active_status_on_release() { return 0; }
	set_issue_status() { return 0; }
	_unlock_issue_after_dispatch_release() { return 0; }
	gh() {
		if [[ "$1" == "api" && "$2" == "repos/owner/repo/issues/42" ]]; then
			printf '%s\n' '{"title":"Fix scope","body":"Files Scope: a.sh"}'
			return 0
		fi
		return 1
	}
	_hrff_post_claim_released_comment() {
		local body="$3"
		posted_count=$((posted_count + 1))
		last_body="$body"
		test_comments=$(printf '%s' "$test_comments" | jq -c --arg body "$body" \
			--arg created_at "2026-08-31T10:0${posted_count}:00Z" \
			'. + [{body: $body, created_at: $created_at, author: "runner-bot", author_association: "COLLABORATOR"}]')
		return 0
	}
	export DISPATCH_REPO_SLUG="owner/repo" WORKER_ISSUE_NUMBER=42
	export AIDEVOPS_TERMINAL_BLOCKER_REPO_PATH="$TEST_ROOT"
	AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT=$(_terminal_blocker_hash 'v2:permission_required')
	export AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	local attempt=0
	for attempt in 1 2 3 4; do
		_release_dispatch_claim "issue-42" "blocked" 2>/dev/null || true
	done
	if [[ "$posted_count" -eq 2 && "$last_body" == *"TERMINAL_BLOCKER_CIRCUIT active=true observations=2"* ]]; then
		status=0
	fi
	print_result "collaborator runner opens one circuit for repeated identical blockers (attempt=${attempt}, posts=${posted_count})" "$status"
	unset DISPATCH_REPO_SLUG WORKER_ISSUE_NUMBER AIDEVOPS_TERMINAL_BLOCKER_REPO_PATH \
		AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	return 0
}

test_circuit_hold_projects_blocked_and_releases() {
	local status=1 projected=""
	set_issue_status() {
		projected="${projected}${3};"
		return 0
	}
	_hrff_resolve_release_runner_login() {
		printf 'runner-one\n'
		return 0
	}
	_unlock_issue_after_dispatch_release() { return 0; }
	_hrff_hold_terminal_blocker_circuit 42 owner/repo
	[[ "$projected" == "blocked;" ]] || status=1
	[[ "$projected" == "blocked;" ]] && status=0
	print_result "open circuit projects status:blocked, never available" "$status"

	# shellcheck source=../terminal-blocker-recovery-helper.sh
	source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
	local circuit='[{"body":"TERMINAL_BLOCKER_CIRCUIT active=true observations=2"}]'
	projected=""
	_tbr_release_circuit_hold owner/repo 42 '{"body":"b","labels":[{"name":"status:blocked"}]}' "$circuit" || true
	status=1
	[[ -z "$projected" ]] && status=0
	print_result "bare circuit prose is not positive re-arm evidence" "$status"

	local label=""
	projected=""
	for label in needs-maintainer-permissions hold-for-review status:in-review; do
		_tbr_release_circuit_hold owner/repo 42 \
			"{\"body\":\"b\",\"labels\":[{\"name\":\"status:blocked\"},{\"name\":\"${label}\"}]}" "$circuit"
	done
	_tbr_release_circuit_hold owner/repo 42 '{"body":"b","labels":[{"name":"bug"}]}' "$circuit"
	_tbr_release_circuit_hold owner/repo 42 '{"body":"b","labels":[{"name":"status:blocked"}]}' '[{"body":"unrelated"}]' || true
	status=1
	[[ -z "$projected" ]] && status=0
	print_result "other holds and non-circuit blocks are never released" "$status"
	return 0
}

# GH#34846: a runtime-owned first files_scope_excluded observation projects
# status:blocked (and says so), is queued for the recovery owner, stays held
# for an unchanged brief and is released to status:available exactly once
# after a brief revision.
test_first_observation_scope_hold_releases_on_revision() {
	local status=0
	if ! (
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		# The fixture name must not shadow callee locals such as `comments`.
		local fingerprint="" issue_body="### Files Scope\n- helper.sh"
		local posted="" edits="" enqueued=0 projected="" tb_fixture_comments='[]' queue_file="" pending_out=""
		fingerprint=$(_terminal_blocker_hash 'v2:files_scope_excluded')
		export DISPATCH_REPO_SLUG=owner/repo WORKER_ISSUE_NUMBER=42
		export AIDEVOPS_TERMINAL_BLOCKER_REPO_PATH="$TEST_ROOT" AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT="$fingerprint"
		issue_json() {
			jq -nc --arg body "$(printf '%b' "$issue_body")" --arg labels "$1" \
				'{state:"open",title:"Fix integration",body:$body,assignees:[{login:"runner-one"}],
				  labels:($labels | split(",") | map({name:.}))}'
			return 0
		}
		gh() {
			[[ "$1" == api && "$2" == repos/owner/repo/issues/42 ]] || return 1
			issue_json "${TEST_ISSUE_LABELS:-status:in-progress}"
			return 0
		}
		gh_issue_edit_safe() { edits+="$*;"; return 0; }
		terminal_blocker_fetch_trusted_comments() { printf '%s\n' "$tb_fixture_comments"; return 0; }
		_hrff_release_repo_state_is_managed() { return 0; }
		_hrff_resolve_release_runner_login() { printf 'runner-one\n'; return 0; }
		_unlock_issue_after_dispatch_release() { return 0; }
		_hrff_enqueue_blocker_recovery() { enqueued=$((enqueued + 1)); return 0; }
		_hrff_post_claim_released_comment() {
			posted="$3"
			tb_fixture_comments=$(jq -nc --arg body "$3" '[{id:7,body:$body,author:"runner-one",author_association:"MEMBER",created_at:"2026-10-16T23:32:17Z"}]')
			return 0
		}
		# Release path: the projected state matches the label actually applied.
		_release_dispatch_claim issue-42 blocked || exit 1
		[[ "$posted" == *'reason=files_scope_excluded owner=brief-author'* &&
			"$posted" == *'Projected state: status:blocked.'* ]] || exit 1
		[[ "$edits" == *'--add-label status:blocked'* && "$edits" == *'--remove-label status:in-progress'* ]] || exit 1
		[[ "$enqueued" -eq 1 ]] || exit 1
		# Runner-local capability gaps stay available and are never queued.
		AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT=$(_terminal_blocker_hash 'v2:runner_capability_unmet') \
			_hrff_blocked_exit_holds && exit 1
		AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT=$(_terminal_blocker_hash 'v2:target_code_blocker') \
			_hrff_enqueue_observation_recovery 42 owner/repo
		# GH#35095: target_code_blocker first observations are queued too.
		[[ "$enqueued" -eq 2 ]] || exit 1
		# Seed backfill: any trusted runner's observation of a re-armed class.
		local raw="" target_raw=""
		raw=$(jq -nc --argjson c "$tb_fixture_comments" '[$c | map(. + {user:{login:.author}})]')
		[[ "$(_tbr_seed_reason "$raw" runner-one)" == files_scope_excluded ]] || exit 1
		[[ "$(_tbr_seed_reason "$raw" other-runner)" == files_scope_excluded ]] || exit 1
		# An untrusted foreign commenter never seeds.
		_tbr_seed_reason "$(printf '%s' "$raw" | jq -c '.[0][0].author_association = "NONE"')" other-runner >/dev/null && exit 1
		target_raw=$(printf '%s' "$raw" | jq -c '.[0][0].body |= sub("files_scope_excluded owner=brief-author"; "target_code_blocker owner=target-maintainer")')
		[[ "$(_tbr_seed_reason "$target_raw" runner-one)" == target_code_blocker ]] || exit 1
		# Classes outside the re-arm set stay unseeded.
		_tbr_seed_reason "$(printf '%s' "$raw" | jq -c '.[0][0].body |= sub("files_scope_excluded owner=brief-author"; "runner_capability_unmet owner=runner-recovery")')" \
			runner-one >/dev/null && exit 1
		# Recovery owner: unchanged brief stays held, revised brief releases once.
		TBR_ROOT="${TEST_ROOT}/recovery" TBR_EXCERPT_DIR="${TEST_ROOT}/no-excerpts" TBR_REPOS_JSON="${TEST_ROOT}/no-repos.json"
		printf '{"initialized_repos":[{"slug":"owner/repo"}]}\n' >"$TBR_REPOS_JSON"
		# GH#35569: own CONTRIBUTOR observations must reach the recovery owner.
		export TERMINAL_BLOCKER_SELF_LOGIN=runner-one
		tb_fixture_comments=$(printf '%s' "$tb_fixture_comments" | jq -c 'map(.author_association="CONTRIBUTOR")')
		set_issue_status() { projected+="${3};"; return 0; }
		_tbr_post_rearm_receipt() { return 0; }
		export TEST_ISSUE_LABELS=status:blocked
		tbr_enqueue owner/repo 42 files_scope_excluded || exit 1
		queue_file="${TBR_ROOT}/queue/owner--repo--42.json"
		terminal_blocker_observation_hold_active "$tb_fixture_comments" "$(issue_json status:blocked)" owner/repo 42 "" >/dev/null || exit 1
		pending_out=$(_tbr_check_entry "$queue_file") || exit 1
		[[ "$pending_out" == *'"reason":"files_scope_excluded"'* && -f "$queue_file" && -z "$projected" ]] || exit 1
		issue_body="### Files Scope\n- helper.sh\n- adjacent.sh"
		terminal_blocker_observation_hold_active "$tb_fixture_comments" "$(issue_json status:blocked)" owner/repo 42 "" >/dev/null && exit 1
		_tbr_check_entry "$queue_file" && exit 1
		[[ "$projected" == 'available;' && ! -f "$queue_file" ]] || exit 1
		date +%s >"${TBR_ROOT}/last_seed_epoch"
		tbr_pending >/dev/null || exit 1
		[[ "$projected" == 'available;' ]] || exit 1
		# A trusted retry after the observation also re-arms an unchanged brief.
		issue_body="### Files Scope\n- helper.sh"
		tb_fixture_comments=$(printf '%s' "$tb_fixture_comments" | jq -c '. + [{id:8,body:"terminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-10-16T23:40:00Z"}]')
		terminal_blocker_observation_hold_active "$tb_fixture_comments" "$(issue_json status:blocked)" owner/repo 42 "" >/dev/null && exit 1
		# Missing evidence retires intake instead of staying incomplete forever;
		# it must not project availability or write a release receipt.
		tb_fixture_comments='[]'
		tbr_enqueue owner/repo 42 files_scope_excluded || exit 1
		local retired_rc=0
		_tbr_check_entry "$queue_file" || retired_rc=$?
		[[ "$retired_rc" -eq 1 && ! -f "$queue_file" && "$projected" == 'available;' ]] || exit 1
		exit 0
	); then
		status=1
	fi
	print_result "first files_scope_excluded hold projects blocked and releases once on brief revision" "$status"
	return 0
}

# Exercise the actual label projection with public evidence shared by two runners.
test_cross_runner_rearm_receipt() {
	local status=0
	if ! (
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		local tb_comments='[]' tb_issue='' tb_original='' tb_revision='' tb_fingerprint=''
		local tb_projected=0 tb_receipts=0 tb_reason='' tb_rc=0 tb_fail_receipt=0
		terminal_blocker_fetch_trusted_comments() { printf '%s\n' "$tb_comments"; return 0; }
		set_issue_status() { tb_projected=$((tb_projected + 1)); return 0; }
		_tbr_post_rearm_receipt() {
			local marker="$3"
			[[ "$tb_fail_receipt" -eq 0 ]] || return 2
			tb_receipts=$((tb_receipts + 1))
			tb_comments=$(jq -nc --argjson c "$tb_comments" --arg body "$marker" '$c + [{id:30,body:$body,author:"runner-a",author_association:"MEMBER",created_at:"2026-10-23T20:30:00Z"}]')
			return 0
		}
		for tb_reason in input_required external_trigger_pending; do
			tb_projected=0 tb_receipts=0
			tb_issue='{"title":"Wait for input","body":"original","labels":[{"name":"status:blocked"}]}'
			tb_original="$tb_issue"
			if [[ "$tb_reason" == input_required ]]; then
				tb_fingerprint=$(_terminal_blocker_hash 'v2:input_required:maintainer')
			else
				tb_fingerprint=$(_terminal_blocker_hash "v2:${tb_reason}")
			fi
			tb_revision=$(terminal_blocker_task_revision "$tb_issue" owner/repo 42 "$TEST_ROOT" "$tb_reason") || exit 1
			tb_comments=$(jq -nc --arg r "$tb_revision" --arg f "$tb_fingerprint" '[{id:10,body:("<!-- aidevops:terminal-blocker-observation revision="+$r+" blocker="+$f+" -->"),author:"runner-b",author_association:"MEMBER",created_at:"2026-10-23T20:00:00Z"},{id:11,body:"CLAIM_RELEASED lease=changed",author_association:"MEMBER",created_at:"2026-10-23T20:01:00Z"}]')
			# Same revision and ops-only comments: no release.
			_tbr_release_circuit_hold owner/repo 42 "$tb_issue" "$tb_comments" && exit 1
			[[ "$tb_projected" -eq 0 ]] || exit 1
			# Foreign collaborator intake must not turn ignored evidence into release.
			tb_rc=0
			_tbr_release_circuit_hold owner/repo 42 "$tb_issue" "$(printf '%s' "$tb_comments" | jq -c 'map(.author_association="COLLABORATOR")')" || tb_rc=$?
			[[ "$tb_rc" -eq 1 ]] || exit 1
			[[ "$tb_projected" -eq 0 ]] || exit 1
			# A revision change releases once; an independent pass sees the receipt,
			# even when its issue-label snapshot still says blocked.
			tb_issue=$(printf '%s' "$tb_issue" | jq -c '.body="corrected"')
			_tbr_release_circuit_hold owner/repo 42 "$tb_issue" "$tb_comments" || exit 1
			_tbr_release_circuit_hold owner/repo 42 "$tb_issue" "$tb_comments" || exit 1
			[[ "$tb_projected" -eq 1 && "$tb_receipts" -eq 1 ]] || exit 1
			# Association/prose edits do not change the immutable receipt identity.
			tb_comments=$(printf '%s' "$tb_comments" | jq -c '.[0].author_association="OWNER" | .[0].body += "\nAudit prose changed"')
			_tbr_release_circuit_hold owner/repo 42 "$tb_issue" "$tb_comments" || exit 1
			[[ "$tb_projected" -eq 1 ]] || exit 1
			# A newer active circuit on B wins over an earlier retry on A.
			tb_comments=$(printf '%s' "$tb_comments" | jq -c --arg r "$tb_revision" --arg f "$tb_fingerprint" '. + [{id:31,body:"terminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-10-23T20:31:00Z"},{id:32,body:("<!-- aidevops:terminal-blocker-circuit revision="+$r+" blocker="+$f+" -->\nTERMINAL_BLOCKER_CIRCUIT active=true observations=2"),author:"runner-b",author_association:"MEMBER",created_at:"2026-10-23T20:32:00Z"}]')
			tb_rc=0
			_tbr_release_circuit_hold owner/repo 42 "$tb_original" "$tb_comments" || tb_rc=$?
			[[ "$tb_rc" -eq 2 && "$tb_projected" -eq 1 ]] || exit 1
			# Only a standalone trusted retry after that circuit permits release.
			tb_comments=$(printf '%s' "$tb_comments" | jq -c '. + [{id:33,body:"terminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-10-23T20:33:00Z"}]')
			_tbr_release_circuit_hold owner/repo 42 "$tb_original" "$tb_comments" || exit 1
			[[ "$tb_projected" -eq 2 ]] || exit 1
			# Receipt failure after projection remains repairable on an available
			# snapshot, without a second projection, then suppresses stale readers.
			tb_fail_receipt=1
			tb_rc=0
			_tbr_release_circuit_hold owner/repo 42 "$tb_issue" "$tb_comments" || tb_rc=$?
			[[ "$tb_rc" -eq 2 && "$tb_projected" -eq 3 ]] || exit 1
			tb_fail_receipt=0
			_tbr_release_circuit_hold owner/repo 42 "$(printf '%s' "$tb_issue" | jq -c '.labels=[{name:"status:available"}]')" "$tb_comments" || exit 1
			_tbr_release_circuit_hold owner/repo 42 "$tb_issue" "$tb_comments" || exit 1
			[[ "$tb_projected" -eq 3 ]] || exit 1
			# A revision/API failure at the circuit write guard is indeterminate.
			(
				terminal_blocker_task_revision() { return 1; }
				local failed_rc=0
				_tbr_circuit_blocks_release "$(_terminal_blocker_latest_marker "$tb_comments" "$_TBC_CIRCUIT_MARKER revision=")" '' "$tb_issue" owner/repo 42 "$TEST_ROOT" || failed_rc=$?
				[[ "$failed_rc" -eq 2 ]]
			) || exit 1
		done
		exit 0
	); then
		status=1
	fi
	print_result "cross-runner re-arm needs a revision or newer retry, honors active circuits and public receipts" "$status"
	return 0
}

# GH#35745: a held unknown first observation (projected status:blocked) gets
# the wake conditions of the other held classes. It is queued and seeded, holds
# for an unchanged brief across default-branch movement, and a standalone
# OWNER/MEMBER retry or a repaired brief releases it once. An unrecognised
# fingerprint (which also maps to unknown) is never released.
test_unknown_hold_rearms_on_trusted_retry() {
	local status=0
	if ! (
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		local tb_comments='[]' tb_issue='' tb_revision='' tb_fingerprint='' tb_observation='' tb_raw='' tb_other=''
		local tb_projected=0 tb_receipts=0 tb_rc=0 tb_enqueued=0
		terminal_blocker_fetch_trusted_comments() { printf '%s\n' "$tb_comments"; return 0; }
		set_issue_status() { tb_projected=$((tb_projected + 1)); return 0; }
		_tbr_post_rearm_receipt() {
			local marker="$3"
			tb_receipts=$((tb_receipts + 1))
			tb_comments=$(jq -nc --argjson c "$tb_comments" --arg body "$marker" '$c + [{id:30,body:$body,author:"runner-a",author_association:"MEMBER",created_at:"2026-10-26T12:30:00Z"}]')
			return 0
		}
		gh_issue_edit_safe() { return 0; }
		_hrff_enqueue_blocker_recovery() { tb_enqueued=$((tb_enqueued + 1)); return 0; }
		tb_fingerprint=$(_terminal_blocker_hash 'v2:unknown')
		tb_issue='{"title":"Award update","body":"original","labels":[{"name":"status:blocked"}]}'
		# The runtime revision (fingerprint only) equals the recovery revision
		# (explicit reason) and ignores default-branch HEAD.
		tb_revision=$(AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT="$tb_fingerprint" \
			terminal_blocker_task_revision "$tb_issue" owner/repo 42 "$TEST_ROOT") || exit 1
		[[ "$(terminal_blocker_task_revision "$tb_issue" owner/repo 42 "$TEST_ROOT" unknown)" == "$tb_revision" ]] || exit 1
		[[ "$(TEST_TARGET_REVISION=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
			terminal_blocker_task_revision "$tb_issue" owner/repo 42 "$TEST_ROOT" unknown)" == "$tb_revision" ]] || exit 1
		# The runtime queues the held observation for the recovery owner.
		_HRFF_TERMINAL_BLOCKER_FRAGMENT=observed AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT="$tb_fingerprint" \
			_hrff_enqueue_observation_recovery 42 owner/repo
		[[ "$tb_enqueued" -eq 1 ]] || exit 1
		tb_observation=$(jq -nc --arg r "$tb_revision" --arg f "$tb_fingerprint" '[{id:10,body:("CLAIM_RELEASED reason=blocked runner=runner-b ts=2026-10-26T11:36:17Z\n<!-- aidevops:terminal-blocker-observation revision="+$r+" blocker="+$f+" -->\n\nTerminal blocker: reason=unknown owner=worker-triage task=42 attempt=abc.\nProjected state: status:blocked."),author:"runner-b",author_association:"MEMBER",created_at:"2026-10-26T11:36:31Z"}]')
		tb_comments="$tb_observation"
		# Seed backfill picks up a stranded unknown hold from any trusted runner.
		tb_raw=$(jq -nc --argjson c "$tb_comments" '[$c | map(. + {user:{login:.author}})]')
		[[ "$(_tbr_seed_reason "$tb_raw" other-runner)" == unknown ]] || exit 1
		# Unchanged brief and no retry: held, never released.
		terminal_blocker_observation_hold_active "$tb_comments" "$tb_issue" owner/repo 42 "$TEST_ROOT" >/dev/null || exit 1
		_tbr_release_circuit_hold owner/repo 42 "$tb_issue" "$tb_comments" && exit 1
		[[ "$tb_projected" -eq 0 ]] || exit 1
		# A COLLABORATOR retry is not authority to clear the hold.
		tb_comments=$(printf '%s' "$tb_comments" | jq -c '. + [{id:11,body:"terminal-blocker-circuit:retry",author_association:"COLLABORATOR",created_at:"2026-10-26T11:45:36Z"}]')
		_tbr_release_circuit_hold owner/repo 42 "$tb_issue" "$tb_comments" && exit 1
		[[ "$tb_projected" -eq 0 ]] || exit 1
		# A standalone OWNER retry line (with leading prose) releases exactly once.
		tb_comments=$(printf '%s' "$tb_comments" | jq -c '. + [{id:12,body:"Award import queue: automatic retry 1 of 3.\n\nterminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-10-26T11:45:37Z"}]')
		terminal_blocker_observation_hold_active "$tb_comments" "$tb_issue" owner/repo 42 "$TEST_ROOT" >/dev/null && exit 1
		_tbr_release_circuit_hold owner/repo 42 "$tb_issue" "$tb_comments" || exit 1
		_tbr_release_circuit_hold owner/repo 42 "$tb_issue" "$tb_comments" || exit 1
		[[ "$tb_projected" -eq 1 && "$tb_receipts" -eq 1 ]] || exit 1
		# A repaired brief also re-arms without a retry.
		tb_projected=0 tb_receipts=0
		tb_comments="$tb_observation"
		_tbr_release_circuit_hold owner/repo 42 "$(printf '%s' "$tb_issue" | jq -c '.body="repaired"')" "$tb_comments" || exit 1
		[[ "$tb_projected" -eq 1 && "$tb_receipts" -eq 1 ]] || exit 1
		# An unrecognised fingerprint maps to unknown but is never released.
		tb_projected=0 tb_receipts=0
		tb_other=$(_terminal_blocker_hash 'v2:not-a-class')
		tb_comments=$(jq -nc --arg r "$tb_revision" --arg f "$tb_other" '[{id:20,body:("<!-- aidevops:terminal-blocker-observation revision="+$r+" blocker="+$f+" -->"),author:"runner-b",author_association:"MEMBER",created_at:"2026-10-26T11:36:31Z"},{id:21,body:"terminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-10-26T11:45:37Z"}]')
		_tbr_release_circuit_hold owner/repo 42 "$tb_issue" "$tb_comments" || tb_rc=$?
		[[ "$tb_rc" -eq 2 && "$tb_projected" -eq 0 ]] || exit 1
		exit 0
	); then
		status=1
	fi
	print_result "held unknown observation is queued and seeded; trusted retry or repaired brief releases it once" "$status"
	return 0
}

# GH#35925: retry-only classes must be seeded on every runner, including old
# timeout observations whose revision no longer matches the current task.
test_retry_only_observation_recovery() {
	local status=0
	if ! (
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		local reason="" association="" scenario="" tb_comments="" observation="" raw=""
		local issue='{"title":"Fix helper","body":"original","labels":[{"name":"status:blocked"}]}'
		local revision="" fingerprint="" body="" retry_at="" projected=0 receipts=0 rc=0 enqueued=0
		set_issue_status() {
			projected=$((projected + 1))
			return 0
		}
		_tbr_post_rearm_receipt() {
			local marker="$3"
			receipts=$((receipts + 1))
			tb_comments=$(jq -c --arg body "$marker" '. + [{id:30,body:$body,author_association:"MEMBER",created_at:"2026-10-29T04:00:00Z"}]' <<<"$tb_comments")
			return 0
		}
		gh_issue_edit_safe() { return 0; }
		_hrff_enqueue_blocker_recovery() {
			enqueued=$((enqueued + 1))
			return 0
		}
		# GH#36044: a runner-capability release is never queued.
		_HRFF_TERMINAL_BLOCKER_FRAGMENT=observed AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT=$(_terminal_blocker_hash 'v2:runner_capability_unmet') \
			_hrff_enqueue_observation_recovery 42 owner/repo
		[[ "$enqueued" -eq 0 ]] || exit 1
		for reason in permission_required push_policy_timeout network_policy_timeout; do
			terminal_blocker_rearms_on_revision "$reason" && exit 1
			terminal_blocker_observation_recoverable "$reason" || exit 1
			fingerprint=$(_terminal_blocker_hash "v2:${reason}")
			# GH#36044: the enqueue helper queues a held retry-only observation,
			# so a trusted retry does not wait for the seed. This checks the
			# helper directly; the blocked release call site is unchanged.
			enqueued=0
			_HRFF_TERMINAL_BLOCKER_FRAGMENT=observed AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT="$fingerprint" \
				_hrff_enqueue_observation_recovery 42 owner/repo
			[[ "$enqueued" -eq 1 ]] || exit 1
			revision=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" "$reason") || exit 1
			# A legacy revision mismatch must not implicitly release retry-only holds.
			[[ "$reason" == permission_required ]] || revision=cccccccccccccccccccccccc
			observation=$(jq -nc --arg r "$revision" --arg f "$fingerprint" --arg reason "$reason" \
				'[{id:10,body:("<!-- aidevops:terminal-blocker-observation revision="+$r+" blocker="+$f+" -->\nTerminal blocker: reason="+$reason+" owner=runner-recovery"),author:"runner-b",user:{login:"runner-b"},author_association:"MEMBER",created_at:"2026-10-29T02:00:00Z"}]')
			raw=$(jq -nc --argjson c "$observation" '[$c]')
			[[ "$(_tbr_seed_reason "$raw" other-runner)" == "$reason" ]] || exit 1
			for scenario in unchanged brief dependency merge collaborator quoted predating; do
				tb_comments="$observation" projected=0 receipts=0
				local changed="$issue"
				case "$scenario" in
				brief) changed=$(jq -c '.body="corrected"' <<<"$issue") ;;
				dependency) TEST_DEPENDENCIES='[{"number":99,"state":"closed"}]' ;;
				merge) TEST_TARGET_REVISION=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
				collaborator | quoted | predating)
					association=OWNER body=terminal-blocker-circuit:retry retry_at=2026-10-29T03:00:00Z
					[[ "$scenario" != collaborator ]] || association=COLLABORATOR
					[[ "$scenario" != quoted ]] || body='> terminal-blocker-circuit:retry'
					[[ "$scenario" != predating ]] || retry_at=2026-10-29T01:00:00Z
					tb_comments=$(jq -c --arg a "$association" --arg body "$body" --arg at "$retry_at" '. + [{id:11,body:$body,author_association:$a,created_at:$at}]' <<<"$tb_comments")
					;;
				esac
				terminal_blocker_observation_hold_active "$tb_comments" "$changed" owner/repo 42 "$TEST_ROOT" >/dev/null || exit 1
				_tbr_release_circuit_hold owner/repo 42 "$changed" "$tb_comments" && exit 1
				[[ "$projected" -eq 0 && "$receipts" -eq 0 ]] || exit 1
				TEST_DEPENDENCIES='[]'
				TEST_TARGET_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
			done
			for association in OWNER MEMBER; do
				projected=0 receipts=0
				tb_comments=$(jq -c --arg a "$association" '. + [{id:12,body:"terminal-blocker-circuit:retry",author_association:$a,created_at:"2026-10-29T03:00:00Z"}]' <<<"$observation")
				terminal_blocker_observation_hold_active "$tb_comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null && exit 1
				# Missing/foreign collaborator observation is never release authority.
				for raw in '[]' "$(jq -c '.[0].author_association="COLLABORATOR"' <<<"$tb_comments")"; do
					rc=0
					_tbr_release_circuit_hold owner/repo 42 "$issue" "$raw" || rc=$?
					[[ "$rc" -eq 1 && "$projected" -eq 0 ]] || exit 1
				done
				_tbr_release_circuit_hold owner/repo 42 "$issue" "$tb_comments" || exit 1
				_tbr_release_circuit_hold owner/repo 42 "$issue" "$tb_comments" || exit 1
				[[ "$projected" -eq 1 && "$receipts" -eq 1 ]] || exit 1
			done
		done
		exit 0
	); then
		status=1
	fi
	print_result "permission and policy timeout observations queue via the enqueue helper, seed across runners and release exactly once only on trusted retry" "$status"
	return 0
}

test_mechanical_rearm_pass() {
	local status=0
	if ! (
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		TBR_ROOT="${TEST_ROOT}/mechanical-rearm"
		TBR_REPOS_JSON="$REPOS_JSON"
		# Load shared runtime functions before installing write stubs: the first
		# budget initialization otherwise replaces set_issue_status.
		_tbr_start_budget || exit 1
		local tb_fixture_comments='[]' fixture_at=2026-10-30T01:00:00Z
		local revision="" fingerprint="" queue_file="" rc=0 projected=0 receipts=0
		local fixture_issue='{"state":"open","title":"Fix helper","body":"original","labels":[{"name":"status:blocked"}]}'
		export TERMINAL_BLOCKER_SELF_LOGIN=runner-one
		# Exercise the real queue/mode logic in process with the suite's existing
		# write stubs; bounded subprocess execution is covered by intake tests.
		_tbr_run_stage() { shift; "$@"; return $?; }
		tbr_seed() { exit 1; }
		_tbr_decision_active() { exit 1; }
		gh() {
			local args="$*"
			[[ "$args" == 'api repos/owner/repo/issues/42' ]] || return 1
			printf '%s\n' "$fixture_issue" | jq -c --arg at "$fixture_at" '. + {updated_at:$at}'
			return 0
		}
		terminal_blocker_fetch_trusted_comments() {
			printf 'read\n' >>"${TBR_ROOT}/comment-reads"
			printf '%s\n' "$tb_fixture_comments"
			return 0
		}
		set_issue_status() { projected=$((projected + 1)); return 0; }
		_tbr_post_rearm_receipt() { receipts=$((receipts + 1)); return 0; }
		revision=$(terminal_blocker_task_revision "$fixture_issue" owner/repo 42 "$TEST_ROOT" permission_required) || exit 1
		fingerprint=$(_terminal_blocker_hash v2:permission_required)
		tb_fixture_comments=$(jq -nc --arg r "$revision" --arg f "$fingerprint" \
			'[{id:10,body:("<!-- aidevops:terminal-blocker-observation revision="+$r+" blocker="+$f+" -->"),author_association:"MEMBER",created_at:"2026-10-30T00:00:00Z"}]')
		tbr_enqueue owner/repo 42 permission_required || exit 1
		queue_file="${TBR_ROOT}/queue/owner--repo--42.json"
		tbr_main rearm >"${TBR_ROOT}/out" || exit 1
		[[ -f "$queue_file" && "$projected" -eq 0 && "$receipts" -eq 0 && ! -s "${TBR_ROOT}/out" ]] || exit 1
		[[ "$(jq -r .rearm_checked_updated_at "$queue_file")" == "$fixture_at" ]] || exit 1
		tbr_main rearm >"${TBR_ROOT}/out" || exit 1
		[[ "$(wc -l <"${TBR_ROOT}/comment-reads")" -eq 1 && "$projected" -eq 0 ]] || exit 1
		# An incomplete fetch must not stamp the newer snapshot or lose intake.
		fixture_at=2026-10-30T02:00:00Z
		terminal_blocker_fetch_trusted_comments() { return 1; }
		tbr_main rearm >"${TBR_ROOT}/out" || rc=$?
		[[ "$rc" -eq 2 && "$(jq -r .rearm_checked_updated_at "$queue_file")" != "$fixture_at" ]] || exit 1
		terminal_blocker_fetch_trusted_comments() { printf '%s\n' "$tb_fixture_comments"; return 0; }
		tb_fixture_comments=$(jq -c '. + [{id:11,body:"terminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-10-30T01:30:00Z"}]' <<<"$tb_fixture_comments")
		tbr_main rearm >"${TBR_ROOT}/out" || exit 1
		[[ ! -f "$queue_file" && "$projected" -eq 1 && "$receipts" -eq 1 && ! -s "${TBR_ROOT}/out" ]] || exit 1
		[[ -f "${TBR_ROOT}/rearm_cursor" && ! -f "${TBR_ROOT}/pending_cursor" ]] || exit 1
		# Target movement must re-arm both first observations and circuits even
		# when the issue snapshot (including updated_at) has not changed.
		_tbr_repo_path() { printf '%s\n' "$TEST_ROOT"; return 0; }
		local marker=""
		for marker in observation circuit; do
			projected=0 receipts=0
			TEST_TARGET_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
			revision=$(terminal_blocker_task_revision "$fixture_issue" owner/repo 42 "$TEST_ROOT" target_code_blocker) || exit 1
			fingerprint=$(_terminal_blocker_hash v2:target_code_blocker)
			tb_fixture_comments=$(jq -nc --arg r "$revision" --arg f "$fingerprint" --arg m "$marker" \
				'[{id:10,body:("<!-- aidevops:terminal-blocker-"+$m+" revision="+$r+" blocker="+$f+" -->"),author_association:"MEMBER",created_at:"2026-10-30T00:00:00Z"}]')
			tbr_enqueue owner/repo 42 target_code_blocker || exit 1
			tbr_main rearm >"${TBR_ROOT}/out" || exit 1
			[[ -f "$queue_file" && "$projected" -eq 0 && "$(jq -r .rearm_checked_updated_at "$queue_file")" == "$fixture_at" ]] || exit 1
			TEST_TARGET_REVISION=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
			tbr_main rearm >"${TBR_ROOT}/out" || exit 1
			[[ ! -f "$queue_file" && "$projected" -eq 1 && "$receipts" -eq 1 && ! -s "${TBR_ROOT}/out" ]] || exit 1
		 done
		exit 0
	); then
		status=1
	fi
	print_result "mechanical rearm releases trusted retry without LLM work, skips unchanged comments and retries incomplete reads" "$status"
	return 0
}

test_mechanical_rearm_scheduler() {
	local status=0
	if ! (
		# shellcheck source=../pulse-dispatch-engine.sh
		source "${SCRIPT_DIR}/pulse-dispatch-engine.sh"
		local PULSE_DIR="${TEST_ROOT}/rearm-pulse" LOGFILE="${TEST_ROOT}/rearm-pulse.log"
		local _CIRCUIT_BREAKER_STATE_FILE="${TEST_ROOT}/rearm-circuit" calls=0 cooldown=0
		local PULSE_BLOCKER_REARM_INTERVAL=600
		mkdir -p "$PULSE_DIR"
		bash() { [[ "$*" == "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh rearm" ]] || return 1; calls=$((calls + 1)); return 0; }
		_gh_secondary_cooldown_active() { [[ "$cooldown" -eq 1 ]] && return 0; return 1; }
		_pulse_rearm_blocker_holds 1000 || exit 1
		_pulse_rearm_blocker_holds 1599 || exit 1
		[[ "$calls" -eq 1 ]] || exit 1
		cooldown=1
		_pulse_rearm_blocker_holds 1600 || exit 1
		[[ "$calls" -eq 1 && "$(<"${PULSE_DIR}/last_blocker_rearm_check_epoch")" == 1000 ]] || exit 1
		cooldown=0
		printf 'active\n' >"$_CIRCUIT_BREAKER_STATE_FILE"
		_pulse_rearm_blocker_holds 1600 || exit 1
		[[ "$calls" -eq 1 ]] || exit 1
		rm -f "$_CIRCUIT_BREAKER_STATE_FILE"
		_pulse_rearm_blocker_holds 1600 || exit 1
		[[ "$calls" -eq 2 && ! -f "${PULSE_DIR}/last_blocker_recovery_check_epoch" && ! -f "${PULSE_DIR}/llm_trigger_mode" ]] || exit 1
		PULSE_BLOCKER_REARM_INTERVAL=0
		_pulse_rearm_blocker_holds 3000 || exit 1
		[[ "$calls" -eq 2 && "$(declare -f _run_preflight_stages)" == *'_pulse_rearm_blocker_holds'* ]] || exit 1
		exit 0
	); then
		status=1
	fi
	print_result "mechanical rearm cadence is independent of LLM state and respects API cooldown and circuit state" "$status"
	return 0
}

test_blocked_backoff_cli() {
	local result="" status=0
	result=$(
		gh() {
			[[ "$1" == api && "$2" == 'repos/owner/repo/issues/42/comments?per_page=100' ]] || return 1
			# Deliberately reverse pages: the retry is older by ID, not timestamp.
			jq -nc '[[range(13;15) | {id:.,body:"CLAIM_RELEASED reason=blocked runner=runner ts=ignored",user:{login:"runner"},author_association:"OWNER",created_at:"2026-09-06T12:00:00Z"}], [{id:12,body:"terminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-09-06T12:00:00Z"}]]'
			return 0
		}
		export -f gh
		local fetched=""
		# Restore the real fetcher after the earlier release integration stub.
		unset _TERMINAL_BLOCKER_CIRCUIT_LOADED
		# shellcheck source=../terminal-blocker-circuit.sh
		source "${SCRIPT_DIR}/terminal-blocker-circuit.sh"
		fetched=$(terminal_blocker_fetch_trusted_comments 42 owner/repo) || exit 1
		[[ "$(printf '%s' "$fetched" | jq -c 'map(.id)')" == '[13,14,12]' ]] || exit 1
		TERMINAL_BLOCKER_NOW_EPOCH=1788696001 bash "${SCRIPT_DIR}/dispatch-dedup-helper.sh" has-dispatch-comment 42 owner/repo runner
	) || status=1
	[[ "$result" == 'TERMINAL_BLOCKER_BACKOFF failures=2 retry_after=1788696900' ]] || status=1
	# GH#33025: the dispatcher's own collaborator login flows through the CLI.
	result=$(
		gh() {
			[[ "$1" == api && "$2" == 'repos/owner/repo/issues/42/comments?per_page=100' ]] || return 1
			jq -nc '[[range(13;15) | {id:.,body:"CLAIM_RELEASED reason=blocked runner=runner-bot ts=ignored",user:{login:"runner-bot"},author_association:"COLLABORATOR",created_at:"2026-09-06T12:00:00Z"}]]'
			return 0
		}
		export -f gh
		TERMINAL_BLOCKER_NOW_EPOCH=1788696001 bash "${SCRIPT_DIR}/dispatch-dedup-helper.sh" has-dispatch-comment 42 owner/repo runner-bot 2>/dev/null
	) || status=1
	[[ "$result" == 'TERMINAL_BLOCKER_BACKOFF failures=2 retry_after=1788696900' ]] || status=1
	print_result "production dispatch CLI preserves paginated API authors and blocks legacy repeated releases" "$status"
	return 0
}

test_push_policy_timeout_checkpoint() {
	local output="${TEST_ROOT}/push-timeout.ndjson"
	local status=0 fingerprint="" release="" head=""
	printf '%s\n' '{"type":"text","text":"BLOCKED: command policy timed out under host load\nTERMINAL_BLOCKER_REASON=push_policy_timeout"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	fingerprint="$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT"
	[[ "$(_terminal_blocker_reason "$fingerprint")" == push_policy_timeout ]] || status=1
	[[ "$(_terminal_blocker_recovery "$fingerprint")" == *'owner=runner-recovery'* ]] || status=1
	# Even repeated observations must not create a permanent task-revision hold.
	local comments='[{"id":1,"body":"observation","author_association":"OWNER","created_at":"2026-10-01T00:00:00Z"}]'
	[[ "$(terminal_blocker_release_mode "$comments" 111111111111111111111111 "$fingerprint")" == first ]] || status=1
	local repo="${TEST_ROOT}/push-checkpoint"
	command -p git clone -q --shared --bare "${SCRIPT_DIR}/../.." "$repo"
	command -p git -C "$repo" branch feature/push-checkpoint
	command -p git -C "$repo" symbolic-ref HEAD refs/heads/feature/push-checkpoint
	head=$(command -p git -C "$repo" rev-parse HEAD)
	release=$(AIDEVOPS_TERMINAL_BLOCKER_REPO_PATH="$repo" _hrff_build_claim_released_line push_policy_timeout fixture 0 1)
	[[ "$release" == *'reason=push_policy_timeout'* && "$release" == *"branch=feature/push-checkpoint head=${head}"* ]] || status=1
	[[ "$release" != *"$repo"* ]] || status=1
	if ! (
		# Use the existing classifier-fixture pattern from test-integration-recovery.
		# shellcheck source=../headless-runtime-result.sh
		source "${SCRIPT_DIR}/headless-runtime-result.sh"
		_headless_private_workload_enabled() { return 1; }
		output_has_completion_signal() { return 0; }
		output_has_blocked_signal() { return 0; }
		output_has_post_pr_handoff_signal() { return 1; }
		output_has_missing_context_blocked_signal() { return 1; }
		output_has_capability_blocked_signal() { return 1; }
		print_warning() { return 0; }
		# shellcheck disable=SC2034
		role=worker session_key=issue-42 discovered_session="" selected_model=fixture work_dir="$repo"
		output_file="$output"
		result_rc=0
		_run_failure_reason=""
		_handle_run_result_success_output || result_rc=$?
		[[ "$result_rc" == 83 && "$_run_failure_reason" == push_policy_timeout ]]
	); then
		status=1
	fi
	print_result "push policy timeout stays transient and releases exact branch/HEAD without paths" "$status"
	return 0
}

test_affected_host_reproduction_alias() {
	local output="${TEST_ROOT}/affected-host.ndjson" status=0 fingerprint="" revision="" changed="" comments=""
	local issue='{"title":"Reproduce before fixing","body":"### Files Scope\n- helper.sh"}'
	printf '%s\n' '{"type":"text","text":"BLOCKED: missing affected-runner reproduction target\nTERMINAL_BLOCKER_REASON=affected_host_reproduction_unavailable"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	fingerprint="$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT"
	[[ "$fingerprint" == "$(_terminal_blocker_hash 'v2:input_required:maintainer')" ]] || status=1
	[[ "$(_terminal_blocker_recovery "$fingerprint")" == *'owner=maintainer'* ]] || status=1
	revision=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT") || status=1
	comments=$(jq -nc --arg body "<!-- aidevops:terminal-blocker-observation revision=${revision} blocker=${fingerprint} -->" \
		'[{body:$body,created_at:"2026-08-31T10:00:00Z",author_association:"MEMBER"}]')
	[[ "$(terminal_blocker_release_mode "$comments" "$revision" "$fingerprint")" == circuit ]] || status=1
	comments=$(jq -nc --arg body "<!-- aidevops:terminal-blocker-circuit revision=${revision} blocker=${fingerprint} -->" \
		'[{body:$body,created_at:"2026-08-31T10:05:00Z",author_association:"MEMBER"}]')
	TEST_TARGET_REVISION='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
	changed=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT") || status=1
	[[ "$changed" == "$revision" ]] || status=1
	terminal_blocker_circuit_active "$comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || status=1
	TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	changed=$(terminal_blocker_task_revision '{"title":"Reproduce before fixing","body":"### Files Scope\n- helper.sh\nAffected-runner target supplied"}' owner/repo 42 "$TEST_ROOT") || status=1
	[[ "$changed" != "$revision" ]] || status=1
	# Only the exact legacy marker is an alias; ambiguous/unknown output stays
	# retryable, and tool evidence cannot override the final assistant dossier.
	printf '%s\n' '{"type":"tool_result","text":"BLOCKED: old evidence\nTERMINAL_BLOCKER_REASON=affected_host_reproduction_unavailable"}' \
		'{"type":"text","text":"BLOCKED: unclassified\nTERMINAL_BLOCKER_REASON=not_a_supported_reason"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == unknown ]] || status=1
	unset AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT
	print_result "affected-host legacy marker shares maintainer-input hold and ignores unrelated merges" "$status"
	return 0
}

test_unknown_blocker_ready_pr_replay() {
	local status=0 scenario=""
	for scenario in pending passed failed unreadable unverified explicit unsupported dirty; do
		if ! (
			# shellcheck source=../headless-runtime-result.sh
			source "${SCRIPT_DIR}/headless-runtime-result.sh"
			_headless_private_workload_enabled() { return 1; }
			output_has_blocked_signal() { return 0; }
			output_has_post_pr_handoff_signal() { return 1; }
			output_has_missing_context_blocked_signal() { return 1; }
			output_has_capability_blocked_signal() { return 1; }
			print_warning() { return 0; }
			_worker_post_pr_handoff_confirmed() { [[ "$scenario" != unverified ]]; return $?; }
			_pr_handoff_state_for_branch_or_issue() { printf 'ready|123'; return 0; }
			gh_pr_checks_observed_json() {
				case "$scenario" in
				failed) return 1 ;;
				unreadable) return 2 ;;
				pending) return 8 ;;
				esac
				return 0
			}
			git() {
				case "$*" in
				*status*) [[ "$scenario" != dirty ]] || printf ' M helper.sh' ;;
				*branch*) printf 'feature/replay' ;;
				*) printf '%040d' 1 ;;
				esac
				return 0
			}
			gh() { printf '%s\n' '{"body":"### Files Scope\n- helper.sh"}'; return 0; }
			export WORKER_ISSUE_NUMBER=42 DISPATCH_REPO_SLUG=owner/repo WORKER_SESSION_KEY=issue-42
			# shellcheck disable=SC2034
			role=worker session_key=issue-42 discovered_session="" selected_model=fixture work_dir="$TEST_ROOT"
			output_file="${TEST_ROOT}/replay-${scenario}.ndjson"
			local text="BLOCKED: PR is waiting on review"
			[[ "$scenario" != explicit ]] || text+=$'\nTERMINAL_BLOCKER_REASON=permission_required'
			[[ "$scenario" != unsupported ]] || text+=$'\nTERMINAL_BLOCKER_REASON=unsupported'
			jq -nc --arg text "$text" '{type:"text",text:$text}' >"$output_file"
			local rc=0
			_run_result_label=""
			_run_failure_reason=""
			_handle_run_result_success_output || rc=$?
			if [[ "$scenario" == pending || "$scenario" == passed ]]; then
				[[ "$rc" == 0 && "$_run_result_label" == post_pr_handoff && -z "$_run_failure_reason" ]]
			else
				[[ "$rc" == 83 && "$_run_result_label" == blocked ]]
			fi
		); then
			status=1
			printf 'Replay failed: %s\n' "$scenario"
		fi
	done
	print_result "unknown prose blocker becomes handoff only for verified clean PR with nonfailing checks" "$status"
	return 0
}

test_terminal_evidence_retention() {
	local status=0 output="${TEST_ROOT}/retained.ndjson"
	local log="${TEST_ROOT}/retention.jsonl"
	jq -nc --arg text 'BLOCKED: waiting token=fixture-secret-value' '{type:"text",text:$text}' >"$output"
	AIDEVOPS_WORKER_BLOCKER_LOG_FILE="$log" terminal_blocker_capture_output "$output" || status=1
	jq -e '.event == "terminal_blocker_captured" and .blocking == false and
		(.blocker_fingerprint | test("^[a-f0-9]{24}$")) and
		(.detail | contains("[REDACTED]")) and (.detail | contains("fixture-secret-value") | not)' "$log" >/dev/null || status=1
	[[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$log")" == 0o600 ]] || status=1
	printf '%s\n' '{"type":"tool","text":"BLOCKED: forged tool evidence"}' >"$output"
	AIDEVOPS_WORKER_BLOCKER_LOG_FILE="$log" terminal_blocker_capture_output "$output" && status=1
	[[ "$(wc -l <"$log" | tr -d ' ')" == 1 ]] || status=1
	print_result "terminal evidence is redacted private bounded-log data and never tool output" "$status"
	return 0
}

test_runner_capability_class() {
	local status=0 output="$TEST_ROOT/capability-output.jsonl" fingerprint="" revision="" fragment="" comments=""
	printf '%s\n' '{"type":"text","text":"BLOCKED: staging secret cannot resolve\nTERMINAL_BLOCKER_REASON=runner_capability_unmet"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	fingerprint="$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT"
	[[ "$(_terminal_blocker_reason "$fingerprint")" == runner_capability_unmet ]] || status=1
	revision=$(terminal_blocker_task_revision '{}' owner/repo 42 '' runner_capability_unmet) || status=1
	[[ "$(terminal_blocker_release_mode '[]' "$revision" "$fingerprint")" == first ]] || status=1
	fragment=$(terminal_blocker_observation_fragment "$revision" "$fingerprint" first) || status=1
	[[ "$fragment" == *'reason=runner_capability_unmet'* && "$fragment" == *'status:available'* ]] || status=1
	terminal_blocker_circuit_comment release "$revision" "$fingerprint" >/dev/null && status=1
	comments=$(jq -nc --arg body "CLAIM_RELEASED reason=blocked runner=maintainer ts=2026-01-01T00:00:00Z
$fragment" '[{author_association:"OWNER",author:"maintainer",body:$body,created_at:"2026-01-01T00:00:00Z"},{author_association:"OWNER",author:"maintainer",body:$body,created_at:"2026-01-01T00:00:01Z"}]')
	TERMINAL_BLOCKER_NOW_EPOCH=1767225660 terminal_blocker_backoff_active "$comments" >/dev/null && status=1
	print_result "runner capability is known and never opens a shared circuit or backoff" "$status"
	return 0
}

# GH#35090 replay: a later lease/label write bumps updatedAt, and App-routed
# private-org reads report the runner's own comments as CONTRIBUTOR/NONE. The
# live gate must re-import its own observation; another login's comment cools
# nobody else. Runs inside test_worker_capability_cooldown's subshell and uses
# its candidate, fixture_comments, login and gh stub through dynamic scope.
_capability_cooldown_own_contributor_replay() {
	local trusted_comments="$fixture_comments" bumped="" association="" before="" after=""
	bumped=$(jq -c '.updatedAt = "2026-10-18T12:05:00Z"' <<<"$candidate") || return 1
	for association in CONTRIBUTOR NONE; do
		fixture_comments=$(jq -c --arg a "$association" 'map(.author_association = $a)' <<<"$trusted_comments")
		rm -f "$HOME/.aidevops/logs/dispatch-capability-cooldown/owner--repo--42"
		before=$(rg -c 'runner_capability_unmet cooldown active' "$LOGFILE" || true)
		_dispatch_skip_for_capability_cooldown "$bumped" 42 owner/repo '' || return 1
		after=$(rg -c 'runner_capability_unmet cooldown active' "$LOGFILE" || true)
		((${after:-0} == ${before:-0} + 1)) || return 1
		[[ "$(_dispatch_filter_capability_cooled_candidates owner/repo '' "[$bumped]")" == '[]' ]] || return 1
		login=runner-two
		_dispatch_skip_for_capability_cooldown "$bumped" 42 owner/repo '' && return 1
		login=runner-one
	done
	fixture_comments="$trusted_comments"
	return 0
}

test_worker_capability_cooldown() {
	local status=0
	if ! (
		# shellcheck source=../pulse-dispatch-lib-candidates.sh
		source "${SCRIPT_DIR}/pulse-dispatch-lib-candidates.sh"
		HOME="$TEST_ROOT/capability-home"
		LOGFILE="$TEST_ROOT/capability-pulse.log"
		_DISPATCH_ELIGIBILITY_INELIGIBLE=ineligible
		_DISPATCH_VALUE_UNKNOWN=unknown
		_DISPATCH_CAPABILITY_COOLDOWN_TTL_SECONDS=21600
		_dispatch_stats_increment() { return 0; }
		local fixture_issue='{"title":"Fix native test","body":"### Files Scope\n- helper.sh"}'
		local candidate='{"number":42,"repo_slug":"owner/repo","repo_path":"","updatedAt":"2026-10-18T12:00:00Z","labels":[]}'
		local revision="" fingerprint="" fragment="" fixture_comments="" login=runner-one now="" filtered="" changed=""
		local fixture_reads=true
		now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
		revision=$(terminal_blocker_task_revision "$fixture_issue" owner/repo 42 '' runner_capability_unmet)
		fingerprint=$(_terminal_blocker_hash v2:runner_capability_unmet)
		fragment=$(terminal_blocker_observation_fragment "$revision" "$fingerprint" first)
		fixture_comments=$(jq -nc --arg body "$fragment" --arg now "$now" \
			'[{id:1,user:{login:"runner-one"},author_association:"COLLABORATOR",body:$body,created_at:$now}]')
		gh() {
			local operation="$1" endpoint="$2"
			[[ "$operation" == api ]] || return 1
			[[ "$endpoint" == user || "$fixture_reads" == true ]] || return 1
			case "$endpoint" in
			user) printf '%s\n' "$login" ;;
			repos/owner/repo/issues/42) printf '%s\n' "$fixture_issue" ;;
			repos/owner/repo/issues/42/comments*) printf '%s\n' "$fixture_comments" ;;
			*) return 1 ;;
			esac
			return 0
		}
		_dispatch_skip_for_capability_cooldown "$candidate" 42 owner/repo '' || exit 1
		filtered=$(_dispatch_filter_capability_cooled_candidates owner/repo '' "[$candidate]")
		[[ "$filtered" == '[]' ]] || exit 1
		rg -q 'runner_capability_unmet cooldown recorded signal=worker_observation' "$LOGFILE" || exit 1
		# Cached passes only verify the login, not refetch issues/comments or
		# refresh the observation TTL.
		local original="" retained=""
		original=$(<"$HOME/.aidevops/logs/dispatch-capability-cooldown/owner--repo--42")
		fixture_reads=false
		_dispatch_skip_for_capability_cooldown "$candidate" 42 owner/repo '' || exit 1
		retained=$(<"$HOME/.aidevops/logs/dispatch-capability-cooldown/owner--repo--42")
		[[ "$original" == "$retained" ]] || exit 1
		login=runner-two
		[[ "$(_dispatch_filter_capability_cooled_candidates owner/repo '' "[$candidate]")" == "[$candidate]" ]] || exit 1
		_dispatch_skip_for_capability_cooldown "$candidate" 42 owner/repo '' && exit 1
		login=runner-one
		fixture_reads=true
		_capability_cooldown_own_contributor_replay || exit 1
		# Selection rejects a different runner, edited brief, later different
		# blocker, and explicit retry without a global hold; it accepts the
		# runner's own comment whatever association GitHub reports.
		fixture_comments=$(jq -c 'map(.author = .user.login)' <<<"$fixture_comments")
		TERMINAL_BLOCKER_SELF_LOGIN=runner-two terminal_blocker_runner_capability_observation_epoch \
			"$fixture_comments" "$fixture_issue" owner/repo 42 && exit 1
		changed=$(jq -c 'map(.author_association="CONTRIBUTOR")' <<<"$fixture_comments")
		TERMINAL_BLOCKER_SELF_LOGIN=runner-one terminal_blocker_runner_capability_observation_epoch \
			"$changed" "$fixture_issue" owner/repo 42 >/dev/null || exit 1
		changed=$(jq -c 'map(.author_association="CONTRIBUTOR" | .author="runner-two")' <<<"$fixture_comments")
		TERMINAL_BLOCKER_SELF_LOGIN=runner-one terminal_blocker_runner_capability_observation_epoch \
			"$changed" "$fixture_issue" owner/repo 42 && exit 1
		TERMINAL_BLOCKER_SELF_LOGIN=runner-one terminal_blocker_runner_capability_observation_epoch \
			"$fixture_comments" '{"title":"Fix native test","body":"changed"}' owner/repo 42 && exit 1
		changed=$(jq -c --arg blocker "$(_terminal_blocker_hash v2:target_code_blocker)" \
			'. + [ (.[0] | .id=2 | .body |= sub("blocker=[a-f0-9]{24}"; "blocker=" + $blocker)) ]' <<<"$fixture_comments")
		TERMINAL_BLOCKER_SELF_LOGIN=runner-one terminal_blocker_runner_capability_observation_epoch \
			"$changed" "$fixture_issue" owner/repo 42 && exit 1
		changed=$(jq -c '. + [{id:2,author:"maintainer",author_association:"OWNER",created_at:.[0].created_at,body:"terminal-blocker-circuit:retry"}]' <<<"$fixture_comments")
		TERMINAL_BLOCKER_SELF_LOGIN=runner-one terminal_blocker_runner_capability_observation_epoch \
			"$changed" "$fixture_issue" owner/repo 42 && exit 1
		changed=$(jq -c '. + [(.[0] | .id=2 | .author="runner-two" | .author_association="OWNER")]' <<<"$fixture_comments")
		TERMINAL_BLOCKER_SELF_LOGIN=runner-one terminal_blocker_runner_capability_observation_epoch \
			"$changed" "$fixture_issue" owner/repo 42 >/dev/null || exit 1
		HOME="$TEST_ROOT/other-runner"
		[[ "$(_dispatch_filter_capability_cooled_candidates owner/repo '' "[$candidate]")" == "[$candidate]" ]] || exit 1
		fixture_comments=$(jq -c 'map(.created_at="2020-01-01T00:00:00Z")' <<<"$fixture_comments")
		_dispatch_skip_for_capability_cooldown "$candidate" 42 owner/repo '' && exit 1
		fixture_comments=$(jq -c 'map(.created_at="2999-01-01T00:00:00Z")' <<<"$fixture_comments")
		_dispatch_skip_for_capability_cooldown "$candidate" 42 owner/repo '' && exit 1
		exit 0
	); then
		status=1
	fi
	print_result "worker observation cools only its own runner and enumeration reuses bounded trusted evidence" "$status"
	return 0
}

test_verification_environment_alias() {
	local output="$TEST_ROOT/environment-alias.jsonl" status=0
	printf '%s\n' '{"type":"text","text":"BLOCKED: native test binary absent\nTERMINAL_BLOCKER_REASON=verification_environment_missing_prerequisites"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == runner_capability_unmet ]] || status=1
	printf '%s\n' '{"type":"text","text":"BLOCKED: unknown\nTERMINAL_BLOCKER_REASON=some_other_environment_problem"}' >"$output"
	terminal_blocker_capture_output "$output" || status=1
	[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == unknown ]] || status=1
	print_result "only exact allowlisted environment alias becomes runner capability" "$status"
	return 0
}

test_target_code_blocker_observation_rearms() {
	local status=0 issue='{"title":"Fix helper","body":"### Files Scope\n- helper.sh"}'
	local fingerprint="" revision="" comments="" held=0
	fingerprint=$(_terminal_blocker_hash 'v2:target_code_blocker')
	revision=$(terminal_blocker_task_revision "$issue" owner/repo 42 "$TEST_ROOT" target_code_blocker) || status=1
	comments=$(jq -nc --arg body "Terminal blocker: reason=target_code_blocker owner=target-maintainer
<!-- aidevops:terminal-blocker-observation revision=${revision} blocker=${fingerprint} -->" \
		'[{id:5,body:$body,author_association:"MEMBER",created_at:"2026-10-16T23:00:00Z"}]')
	# Same target revision: still held.
	terminal_blocker_observation_hold_active "$comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || status=1
	# Target code changed: re-armed.
	TEST_TARGET_REVISION='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
	terminal_blocker_observation_hold_active "$comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null && status=1
	TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	# Trusted OWNER retry after the observation re-arms an unchanged revision.
	terminal_blocker_observation_hold_active "$(jq -c '. + [{id:6,body:"terminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-10-16T23:30:00Z"}]' <<<"$comments")" \
		"$issue" owner/repo 42 "$TEST_ROOT" >/dev/null && status=1
	# An unreadable target revision fails closed (rc 2), never releases.
	TEST_TARGET_REVISION=unavailable
	terminal_blocker_observation_hold_active "$comments" "$issue" owner/repo 42 "$TEST_ROOT" >/dev/null || held=$?
	TEST_TARGET_REVISION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	[[ "$held" -eq 2 ]] || status=1
	# Other hold labels keep the release helper from touching the issue.
	(
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		local touched=""
		set_issue_status() { touched="x"; return 0; }
		_tbr_release_circuit_hold owner/repo 42 '{"labels":[{"name":"status:blocked"},{"name":"needs-maintainer-review"}]}' "$comments"
		_tbr_release_circuit_hold owner/repo 42 '{"labels":[{"name":"status:blocked"},{"name":"needs-maintainer-permissions"}]}' "$comments"
		[[ -z "$touched" ]]
	) || status=1
	print_result "target_code_blocker first observation holds at same revision, re-arms on target change or retry" "$status"
	return 0
}

# GH#35290: exercise the real CLI and timeout boundary with inherited GitHub
# fixtures, not a replacement pending implementation. No live queue is touched.
_bounded_seed_resume_checks() {
	local rc=0
	# Seed resumes after a slow candidate; newly seeded entries cannot
	# masquerade as empty intake. Reuse the caller's isolated GitHub fixture.
	export TB_SEED=1 BLOCKER_RECOVERY_STAGE_SECONDS=2 BLOCKER_RECOVERY_BUDGET_SECONDS=6
	rm -f "${TBR_ROOT}/queue/owner--repo--42.json"
	bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" pending >"${TBR_ROOT}/out" 2>"${TBR_ROOT}/err" || rc=$?
	[[ "$rc" -eq 2 && "$(<"${TBR_ROOT}/seed-owner--repo.cursor")" == 1 ]] || return 1
	rc=0
	bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" pending >"${TBR_ROOT}/out" 2>"${TBR_ROOT}/err" || rc=$?
	[[ "$rc" -eq 2 && -f "${TBR_ROOT}/queue/owner--repo--42.json" ]] || return 1
	[[ "$(<"${TBR_ROOT}/err")" == *'reason=unobserved_entries'* && ! -f "${TBR_ROOT}/last_seed_epoch" ]] || return 1
	export TB_SEED_FAST=1
	bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" seed >"${TBR_ROOT}/out" 2>"${TBR_ROOT}/err" || return 1
	[[ -f "${TBR_ROOT}/last_seed_epoch" ]] || return 1
	# A failed remote-policy observation is not permission to retire evidence.
	(
		_tbr_policy_enabled() { return 2; }
		tbr_enqueue owner/repo 42 files_scope_excluded policy_remote || exit 1
		rc=0
		_tbr_check_entry "${TBR_ROOT}/queue/owner--repo--42.json" >/dev/null || rc=$?
		[[ "$rc" -eq 2 && -f "${TBR_ROOT}/queue/owner--repo--42.json" && -f "${TBR_ROOT}/decisions/owner--repo--42.json" ]]
	) || return 1
	return 0
}

test_bounded_recovery_intake() {
	local status=0
	if ! (
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		TBR_ROOT="${TEST_ROOT}/bounded-intake"
		TBR_REPOS_JSON="${TEST_ROOT}/bounded-repos.json"
		export TB_INTAKE_FIXTURE="$TBR_ROOT" WORKER_GITHUB_LOGIN=runner-one TERMINAL_BLOCKER_SELF_LOGIN=runner-one
		export AIDEVOPS_BLOCKER_RECOVERY_DIR="$TBR_ROOT" REPOS_JSON="$TBR_REPOS_JSON"
		export BLOCKER_RECOVERY_STAGE_SECONDS=1 BLOCKER_RECOVERY_BUDGET_SECONDS=1
		_tbr_init_dirs || exit 1
		printf '{"initialized_repos":[{"slug":"owner/repo"}]}\n' >"$TBR_REPOS_JSON"
		date +%s >"${TBR_ROOT}/last_seed_epoch"
		local fixture_brief='{"title":"Held integration","body":"### Files Scope\n- helper.sh"}' revision=""
		revision=$(terminal_blocker_task_revision "$fixture_brief" owner/repo 42 "" files_scope_excluded) || exit 1
		jq -nc --argjson brief "$fixture_brief" '$brief + {state:"open",labels:[{name:"status:blocked"}]}' >"${TBR_ROOT}/issue.json"
		jq -nc --arg body "Terminal blocker: reason=files_scope_excluded owner=brief-author
<!-- aidevops:terminal-blocker-observation revision=${revision} blocker=$(_terminal_blocker_hash 'v2:files_scope_excluded') -->" \
			'[[{id:7,body:$body,user:{login:"runner-one"},author_association:"MEMBER",created_at:"2026-10-16T23:32:17Z"}]]' >"${TBR_ROOT}/comments.json"
		gh() {
			local args="$*"
			printf '%s\n' "$args" >>"${TB_INTAKE_FIXTURE}/requests"
			case "$args" in
			"api repos/owner/repo/issues/1" | "api repos/owner/repo/issues/1/comments?per_page=100 --paginate --slurp")
				[[ "${TB_SEED_FAST:-0}" -eq 0 ]] || { printf '[]\n'; return 0; }
				sleep 5
				return 1
				;;
			"api repos/owner/repo/issues/2") printf '{"state":"closed"}\n' ;;
			"api repos/owner/repo/issues/42") jq -c . "${TB_INTAKE_FIXTURE}/issue.json" ;;
			"api repos/owner/repo/issues/42/comments?per_page=100 --paginate --slurp") jq -c . "${TB_INTAKE_FIXTURE}/comments.json" ;;
			"api repos/owner/repo")
				[[ "${TB_SEED:-0}" -eq 1 ]] || return 1
				printf '{"permissions":{"push":true},"default_branch":"main"}\n'
				;;
			"api -X GET repos/owner/repo/commits"*) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
			"api -X GET repos/owner/repo/contents/.aidevops.json"*) printf 'HTTP 404\n' >&2; return 1 ;;
			"api -X GET search/issues"*)
				[[ "${TB_SEED:-0}" -eq 1 ]] || return 1
				printf '1\n42\n'
				;;
			*) return 1 ;;
			esac
			return 0
		}
		export -f gh
		tbr_enqueue owner/repo 1 permission_required || exit 1
		tbr_enqueue owner/repo 2 permission_required || exit 1
		tbr_enqueue owner/repo 42 files_scope_excluded || exit 1
		printf '{"wake":"brief_revision","next_action":"hold unchanged brief","evidence":"fixture"}\n' |
			tbr_record owner/repo 42 || exit 1
		local rc=0 started="$SECONDS" decision=""
		decision=$(jq -c . "${TBR_ROOT}/decisions/owner--repo--42.json")
		bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" pending >"${TBR_ROOT}/out" 2>"${TBR_ROOT}/err" || rc=$?
		[[ "$rc" -eq 2 && $((SECONDS - started)) -le 3 && ! -s "${TBR_ROOT}/out" ]] || exit 1
		[[ "$(<"${TBR_ROOT}/err")" == *'incomplete stage=entry'* && "$(<"${TBR_ROOT}/err")" == *'stage=entry_issue'* ]] || exit 1
		[[ "$(<"${TBR_ROOT}/pending_cursor")" == owner--repo--1.json && -f "${TBR_ROOT}/queue/owner--repo--1.json" ]] || exit 1
		# Resume past the stalled entry: retire closed entries and suppress an
		# unchanged held decision, then wrap and retry (not delete) the slow one.
		export BLOCKER_RECOVERY_BUDGET_SECONDS=4
		rc=0
		bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" pending --count >"${TBR_ROOT}/out" 2>"${TBR_ROOT}/err" || rc=$?
		[[ "$rc" -eq 2 && "$(<"${TBR_ROOT}/out")" == 0 ]] || exit 1
		[[ ! -f "${TBR_ROOT}/queue/owner--repo--2.json" && -f "${TBR_ROOT}/queue/owner--repo--42.json" ]] || exit 1
		[[ "$(jq -c . "${TBR_ROOT}/decisions/owner--repo--42.json")" == "$decision" ]] || exit 1
		# With only the unchanged held entry, observation is complete and empty.
		rm -f "${TBR_ROOT}/queue/owner--repo--1.json"
		bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" pending >"${TBR_ROOT}/out" 2>"${TBR_ROOT}/err" || exit 1
		[[ ! -s "${TBR_ROOT}/out" ]] || exit 1
		# Seed failures are explicit too, and never stamp an incomplete scan.
		rm -f "${TBR_ROOT}/last_seed_epoch"
		printf '{"initialized_repos":[{"slug":"owner/repo","pulse":true}]}\n' >"$TBR_REPOS_JSON"
		rc=0
		bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" pending >"${TBR_ROOT}/out" 2>"${TBR_ROOT}/err" || rc=$?
		[[ "$rc" -eq 2 && ! -f "${TBR_ROOT}/last_seed_epoch" ]] || exit 1
		[[ "$(<"${TBR_ROOT}/err")" == *'incomplete stage=seed'* ]] || exit 1
		_bounded_seed_resume_checks || exit 1
		_default_budget_progress_checks || exit 1
		exit 0
	); then
		status=1
	fi
	print_result "bounded intake resumes past stalled reads, preserves held decisions, and distinguishes incomplete from empty" "$status"
	return 0
}

# Exercise two real default-budget CLI calls with 25 entries, not a substituted
# pending loop. Slow closed entries consume the first pass; the cursor must let
# the next pass reach actionable entries beyond the first ten.
_default_budget_progress_checks() {
	local issue=0 rc=0
	TBR_ROOT="${TEST_ROOT}/default-budget"
	export AIDEVOPS_BLOCKER_RECOVERY_DIR="$TBR_ROOT"
	unset BLOCKER_RECOVERY_BUDGET_SECONDS BLOCKER_RECOVERY_STAGE_SECONDS
	_tbr_init_dirs || return 1
	date +%s >"${TBR_ROOT}/last_seed_epoch"
	for issue in {100..124}; do
		tbr_enqueue owner/repo "$issue" files_scope_excluded || return 1
	done
	gh() {
		local args="$*" issue=""
		case "$args" in
		"api repos/owner/repo/issues/"*"/comments?per_page=100 --paginate --slurp")
			jq -c . "${TB_INTAKE_FIXTURE}/comments.json" ;;
		"api repos/owner/repo/issues/"*)
			issue="${args##*/}"
			if [[ "$issue" -le 109 ]]; then
				if [[ "$issue" -eq 100 ]]; then sleep 9; else sleep 4; fi
				printf '{"state":"closed"}\n'
			else
				jq -c . "${TB_INTAKE_FIXTURE}/issue.json"
			fi ;;
		"api -X GET repos/owner/repo/commits"*) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
		*) return 1 ;;
		esac
		return 0
	}
	export -f gh
	# A legacy fixture must be retired even when it sorts beyond the budget.
	printf '{"repo":"zz-fixture/repo","issue":42}\n' >"${TBR_ROOT}/queue/zz-fixture--repo--42.json"
	printf '{}\n' >"${TBR_ROOT}/decisions/zz-fixture--repo--42.json"
	tbr_enqueue zz-fixture/repo 42 && return 1
	bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" pending >"${TBR_ROOT}/first" 2>"${TBR_ROOT}/err" || rc=$?
	[[ "$rc" -eq 2 && -s "${TBR_ROOT}/pending_cursor" ]] || return 1
	# A legitimate nine-second entry must finish rather than time out at eight.
	[[ ! -f "${TBR_ROOT}/queue/owner--repo--100.json" ]] || return 1
	[[ ! -f "${TBR_ROOT}/queue/zz-fixture--repo--42.json" && ! -f "${TBR_ROOT}/decisions/zz-fixture--repo--42.json" ]] || return 1
	rc=0
	bash "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" pending >"${TBR_ROOT}/second" 2>"${TBR_ROOT}/err" || rc=$?
	[[ "$rc" -eq 0 || "$rc" -eq 2 ]] || return 1
	jq -es 'any(.[]; .issue > 109 and .repo == "owner/repo")' "${TBR_ROOT}/first" "${TBR_ROOT}/second" >/dev/null || return 1
	# Missing registry preserves queued evidence instead of treating it as stale.
	TBR_REPOS_JSON="${TEST_ROOT}/missing-registry.json"
	rc=0
	_tbr_check_entry "${TBR_ROOT}/queue/owner--repo--111.json" >/dev/null || rc=$?
	[[ "$rc" -eq 2 && -f "${TBR_ROOT}/queue/owner--repo--111.json" ]] || return 1
	return 0
}

test_fleet_capability_hold() {
	local status=0
	if ! (
		local brief='{"title":"Check tools","body":"### Files Scope\n- tool.sh"}'
		local revision="" fingerprint="" comments="" changed="" ready=1 updates=0
		revision=$(terminal_blocker_task_revision "$brief" owner/repo 42 "$TEST_ROOT" runner_capability_unmet)
		fingerprint=$(_terminal_blocker_hash 'v2:runner_capability_unmet')
		comments=$(jq -nc --arg r "$revision" --arg f "$fingerprint" '
			["alpha","beta"] | to_entries | map({id:(.key+1),author:.value,author_association:"MEMBER",
			created_at:"2026-10-27T10:00:00Z",body:("CLAIM_RELEASED reason=blocked runner="+.value+" ts=now\n<!-- aidevops:terminal-blocker-observation revision="+$r+" blocker="+$f+" -->")})')
		_terminal_blocker_fleet_ready() { return "$ready"; }
		_terminal_blocker_fleet_dashboard() { printf '99\n'; return 0; }
		terminal_blocker_fetch_trusted_comments() { printf '[]\n'; return 0; }
		gh() { return 1; }
		_terminal_blocker_fleet_update() { updates=$((updates + 1)); return 0; }
		terminal_blocker_fleet_hold_active "$comments" "$brief" owner/repo 42 "$TEST_ROOT" >/dev/null || exit 1
		[[ "$updates" -eq 1 ]] || exit 1
		# Same author twice, spoofed runner field, outsider and old revision do not hold.
		changed=$(jq -c '.[1].author="alpha" | .[1].body=.[0].body' <<<"$comments")
		terminal_blocker_fleet_hold_active "$changed" "$brief" owner/repo 42 "$TEST_ROOT" >/dev/null && exit 1
		changed=$(jq -c '.[1].author="mallory"' <<<"$comments")
		terminal_blocker_fleet_hold_active "$changed" "$brief" owner/repo 42 "$TEST_ROOT" >/dev/null && exit 1
		changed=$(jq -c '.[1].author_association="CONTRIBUTOR"' <<<"$comments")
		terminal_blocker_fleet_hold_active "$changed" "$brief" owner/repo 42 "$TEST_ROOT" >/dev/null && exit 1
		terminal_blocker_fleet_hold_active "$comments" '{"title":"Changed","body":"new brief"}' owner/repo 42 "$TEST_ROOT" >/dev/null && exit 1
		ready=0
		terminal_blocker_fleet_hold_active "$comments" "$brief" owner/repo 42 "$TEST_ROOT" >/dev/null && exit 1
		[[ "$updates" -eq 2 ]] || exit 1
		# A receipt wakes only its exact observed checkpoint; a new failure,
		# even in the same second, must be probed again.
		local checkpoint="" receipt=""
		checkpoint=$(_terminal_blocker_hash "${revision}:$(_terminal_blocker_fleet_observations "$comments" "$revision" "$fingerprint")")
		receipt=$(jq -nc --arg key "$checkpoint" '{id:123,body:("Ready checkpoints: "+$key)}')
		_terminal_blocker_fleet_existing() { printf '%s\n' "$receipt"; return 0; }
		ready=1
		terminal_blocker_fleet_hold_active "$comments" "$brief" owner/repo 42 "$TEST_ROOT" >/dev/null && exit 1
		changed=$(jq -c '.[1].id=3' <<<"$comments")
		terminal_blocker_fleet_hold_active "$changed" "$brief" owner/repo 42 "$TEST_ROOT" >/dev/null || exit 1
		[[ "$updates" -eq 3 ]] || exit 1
		exit 0
	); then status=1; fi
	print_result "fleet hold requires distinct authenticated runners and a current revision; readiness wakes it" "$status"
	return 0
}

test_fleet_escalation_upsert() {
	local status=0
	if ! (
		local existing='{}' calls="${TEST_ROOT}/fleet-calls" captured_body="" fingerprint=""
		local fixture_comments='[]' reconciled=""
		fingerprint=$(_terminal_blocker_hash 'v2:runner_capability_unmet')
		gh() {
			local endpoint="$2" method="$4" payload="${6:-}"
			printf '%s --method %s\n' "$endpoint" "$method" >>"$calls"
			captured_body="${payload#body=}"
			if [[ "$method" == PATCH ]]; then
				fixture_comments=$(jq -c --arg body "$captured_body" 'map(if .id == 123 then .body=$body else . end)' <<<"$fixture_comments")
			elif [[ "$method" == DELETE ]]; then
				fixture_comments=$(jq -c 'map(select(.id != 124))' <<<"$fixture_comments")
			fi
			return 0
		}
		_terminal_blocker_fleet_update owner/repo 99 "$fingerprint" 42 held "$existing" || exit 1
		[[ "$captured_body" == *'Held issues: 42'* && "$captured_body" == *'approve <worktree>'* ]] || exit 1
		existing=$(jq -nc --arg body "$captured_body" '{id:123,body:$body}')
		_terminal_blocker_fleet_update owner/repo 99 "$fingerprint" 43 held "$existing" || exit 1
		[[ "$captured_body" == *'Held issues: 42,43'* ]] || exit 1
		existing=$(jq -nc --arg body "$captured_body" '{id:123,body:$body}')
		_terminal_blocker_fleet_update owner/repo 99 "$fingerprint" 43 held "$existing" || exit 1
		[[ "$(wc -l <"$calls" | tr -d ' ')" -eq 2 ]] || exit 1
		rg -q 'comments/123 --method PATCH' "$calls" || exit 1
		# Two simultaneous creators converge without losing either issue list
		# or exact-checkpoint readiness evidence.
		fixture_comments=$(jq -nc --arg marker "<!-- ${_TBC_FLEET_MARKER}${fingerprint} -->" '
			[{id:123,author_association:"MEMBER",body:($marker+"\nHeld issues: 42\nReady checkpoints: aaaaaaaaaaaaaaaaaaaaaaaa")},
			 {id:124,author_association:"MEMBER",body:($marker+"\nHeld issues: 43\nReady checkpoints: bbbbbbbbbbbbbbbbbbbbbbbb")}]')
		terminal_blocker_fetch_trusted_comments() { printf '%s\n' "$fixture_comments"; return 0; }
		reconciled=$(_terminal_blocker_fleet_existing owner/repo 99 "$fingerprint") || exit 1
		[[ "$reconciled" == *'Held issues: 42,43'* && "$reconciled" == *'aaaaaaaaaaaaaaaaaaaaaaaa,bbbbbbbbbbbbbbbbbbbbbbbb'* ]] || exit 1
		rg -q 'comments/124 --method DELETE' "$calls" || exit 1
		exit 0
	); then status=1; fi
	print_result "fleet escalation creates once, edits the held issue list and skips unchanged writes" "$status"
	return 0
}

test_capability_checkpoint_attention() {
	local status=0
	if ! (
		# shellcheck source=../pr-checkpoint-continuation-helper.sh
		source "${SCRIPT_DIR}/pr-checkpoint-continuation-helper.sh"
		local attention_body="" fixture_reason="runner_capability_unmet"
		# GH#35932: production `gh api --paginate --slurp` returns an array of
		# pages; a flat fixture hid a capability check that never matched.
		_pcc_issue_comments() {
			jq -nc --arg reason "$fixture_reason" '[[{id:10,body:("Terminal blocker: reason="+$reason+" owner=runner-recovery")}]]'
			return 0
		}
		_pr_checkpoint_trusted_logins() { printf '["runner"]\n'; return 0; }
		_pcc_blocked_release_evidence() { printf '10\tattempt:x\tfalse\t-\n'; return 0; }
		gh() {
			local kind="$1" endpoint="${2:-}" payload="${6:-}"
			if [[ "$kind" == pr ]]; then
				printf '{"state":"OPEN","isDraft":true,"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","author":{"login":"runner"}}\n'
			elif [[ "$kind" == api && "$endpoint" == */comments ]]; then
				attention_body="${payload#body=}"
			else return 1; fi
			return 0
		}
		_pcc_blocked_attention owner/repo 42 100 >/dev/null || exit 1
		[[ "$attention_body" == *'No brief change'* && "$attention_body" == *'approve <worktree>'* &&
			"$attention_body" != *'Next action for the brief owner'* && "$attention_body" != *'approval-template'* ]] || exit 1
		fixture_reason=files_scope_excluded
		_pcc_blocked_attention owner/repo 42 100 >/dev/null || exit 1
		[[ "$attention_body" == *'approval-template'* ]] || exit 1
		exit 0
	); then status=1; fi
	print_result "capability checkpoint attention names runner remediation, not a brief revision" "$status"
	return 0
}

test_recovery_graphql_fallback() {
	local status=0
	if ! (
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		local api_mode=rest graphql_reply='' result='' rc=0 valid_comments='' id=''
		local calls="${TEST_ROOT}/fallback-calls" entry="${TEST_ROOT}/fallback-entry.json"
		gh() {
			local kind="$1" endpoint="${2:-}"
			printf '%s\n' "$*" >>"$calls"
			[[ "$kind" == api ]] || return 1
			if [[ "$api_mode" == rest ]]; then
				[[ "$endpoint" != graphql ]] || return 1
				printf '[[{"id":7,"user":{"login":"runner"},"author_association":"NONE","body":"hold","created_at":"2026-10-30T01:00:00Z"}]]\n'
			elif [[ "$api_mode" == failed || "$endpoint" != graphql ]]; then
				return 1
			else
				printf '%s\n' "$graphql_reply"
			fi
			return 0
		}
		result=$(terminal_blocker_fetch_trusted_comments 42 owner/repo runner) || exit 1
		[[ "$(jq -r '.[0].id' <<<"$result")" == 7 ]] || exit 1
		! rg -q graphql "$calls" || exit 1
		api_mode=graphql
		# Two pages include same-second IDs, an untrusted comment and this
		# runner's own NONE comment. REST-shaped trust filtering stays intact.
		graphql_reply=$(jq -nc '[
			{data:{repository:{issue:{comments:{nodes:[
				{fullDatabaseId:"8",author:{login:"owner"},authorAssociation:"OWNER",body:"retry",createdAt:"2026-10-30T01:00:00Z"},
				{fullDatabaseId:"9",author:{login:"outsider"},authorAssociation:"NONE",body:"spoof",createdAt:"2026-10-30T01:00:00Z"}],
				pageInfo:{hasNextPage:true,endCursor:"next"}}}}}},
			{data:{repository:{issue:{comments:{nodes:[
				{fullDatabaseId:"10",author:{login:"runner"},authorAssociation:"NONE",body:"hold",createdAt:"2026-10-30T01:00:00Z"}],
				pageInfo:{hasNextPage:false,endCursor:null}}}}}}]')
		result=$(terminal_blocker_fetch_trusted_comments 42 owner/repo runner) || exit 1
		[[ "$(jq -c 'map(.id)' <<<"$result")" == '[8,10]' ]] || exit 1
		[[ "$(jq -r '.[1].created_at' <<<"$result")" == '2026-10-30T01:00:00Z' ]] || exit 1
		rg -q -- '--paginate --slurp.*endCursor' "$calls" || exit 1
		rg -q -- 'nodes\{fullDatabaseId ' "$calls" || exit 1
		valid_comments="$graphql_reply"
		for id in '"9007199254740991"' 9007199254740991; do
			graphql_reply=$(printf '%s' "$valid_comments" | jq -c --argjson id "$id" '.[-1].data.repository.issue.comments.nodes[0].fullDatabaseId=$id')
			result=$(terminal_blocker_fetch_comments owner/repo 42) || exit 1
			[[ "$(printf '%s' "$result" | jq -r '.[-1].id')" == 9007199254740991 ]] || exit 1
		done
		# Invalid IDs on a later page invalidate all evidence, not just that node.
		for id in null true '{}' '[]' '"bad"' '""' 0 -1 1.5 '"1.5"' '"1e2"' '"9007199254740992"' 9007199254740992 '"90071992547409910"'; do
			graphql_reply=$(printf '%s' "$valid_comments" | jq -c --argjson id "$id" '.[-1].data.repository.issue.comments.nodes[0].fullDatabaseId=$id')
			result=$(terminal_blocker_fetch_comments owner/repo 42) && exit 1
			[[ -z "$result" ]] || exit 1
		done
		graphql_reply=$(printf '%s' "$valid_comments" | jq -c 'del(.[-1].data.repository.issue.comments.nodes[0].fullDatabaseId)')
		result=$(terminal_blocker_fetch_comments owner/repo 42) && exit 1
		[[ -z "$result" ]] || exit 1
		graphql_reply="$valid_comments"
		# Truncated, null and partial-error responses are not empty evidence.
		graphql_reply=$(jq -c '.[-1].data.repository.issue.comments.pageInfo.hasNextPage=true' <<<"$graphql_reply")
		terminal_blocker_fetch_comments owner/repo 42 >/dev/null && exit 1
		graphql_reply='[{"data":{"repository":{"issue":null}}}]'
		terminal_blocker_fetch_comments owner/repo 42 >/dev/null && exit 1
		graphql_reply='[{"errors":[{"message":"unavailable"}],"data":{"repository":{"issue":{"comments":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}}]'
		terminal_blocker_fetch_comments owner/repo 42 >/dev/null && exit 1
		graphql_reply='{"data":{"repository":{"issue":{"number":42,"title":"Brief","body":"scope","state":"OPEN","updatedAt":"now","labels":{"nodes":[{"name":"status:blocked"}],"pageInfo":{"hasNextPage":false}}}}}}'
		result=$(terminal_blocker_fetch_issue owner/repo 42) || exit 1
		jq -e '.state == "open" and .updated_at == "now" and .labels[0].name == "status:blocked"' <<<"$result" >/dev/null || exit 1
		graphql_reply=$(jq -c '.data.repository.issue.labels.pageInfo.hasNextPage=true' <<<"$graphql_reply")
		terminal_blocker_fetch_issue owner/repo 42 >/dev/null && exit 1
		graphql_reply='[{"data":{"search":{"nodes":[{"number":42}],"pageInfo":{"hasNextPage":false}}}}]'
		[[ "$(_tbr_seed_candidates owner/repo)" == 42 ]] || exit 1
		graphql_reply='[{"data":{"search":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}]'
		[[ -z "$(_tbr_seed_candidates owner/repo)" ]] || exit 1
		unset WORKER_GITHUB_LOGIN AIDEVOPS_WORKER_GITHUB_LOGIN
		graphql_reply=runner
		[[ "$(_tbr_self_login)" == runner ]] || exit 1
		api_mode=failed
		_tbr_self_login >/dev/null && exit 1
		terminal_blocker_fetch_trusted_comments 42 owner/repo runner >/dev/null && exit 1
		terminal_blocker_search_issues 'repo:owner/repo is:issue' >/dev/null && exit 1
		printf '{"repo":"owner/repo","issue":42,"reason":"unknown"}\n' >"$entry"
		_tbr_check_entry "$entry" rearm >/dev/null 2>&1 || rc=$?
		[[ "$rc" -eq 2 && -f "$entry" ]] || exit 1
		exit 0
	); then status=1; fi
	print_result "recovery falls back to paginated GraphQL without weakening trust or retiring incomplete evidence" "$status"
	return 0
}

main() {
	test_recovery_graphql_fallback
	test_fleet_capability_hold
	test_fleet_escalation_upsert
	test_capability_checkpoint_attention
	test_bounded_recovery_intake
	test_target_code_blocker_observation_rearms
	test_worker_capability_cooldown
	test_verification_environment_alias
	test_unknown_blocker_ready_pr_replay
	test_terminal_evidence_retention
	test_affected_host_reproduction_alias
	test_runner_capability_class
	test_push_policy_timeout_checkpoint
	test_normalized_blocker_fingerprint
	test_worker_contract_reason_protocol
	test_task_revision_inputs
	test_release_modes_and_retry
	test_dispatch_hold_revalidates_revision
	test_brief_only_revision
	test_external_trigger_pending_revision
	test_source_access_blocked_revision
	test_explicit_blocker_survives_missing_scope
	test_input_required_owner_class
	test_excluded_scope_revision
	test_unknown_and_redaction
	test_final_dossier_and_structural_precedence
	test_unrecorded_blocked_exit_stays_dispatchable
	test_release_integration_bounds_comments
	test_legacy_blocked_backoff
	test_blocked_backoff_trust
	test_permission_blocker_continuation
	test_permission_blocker_stays_in_generic_lifecycle
	test_same_second_release_ordering
	test_self_authored_collaborator_evidence
	test_collaborator_runner_release_opens_circuit
	test_circuit_hold_projects_blocked_and_releases
	test_first_observation_scope_hold_releases_on_revision
	test_cross_runner_rearm_receipt
	test_unknown_hold_rearms_on_trusted_retry
	test_retry_only_observation_recovery
	test_mechanical_rearm_pass
	test_mechanical_rearm_scheduler
	test_blocked_backoff_cli
	printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
}

main "$@"
