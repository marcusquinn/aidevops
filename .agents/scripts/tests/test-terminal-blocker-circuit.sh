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

# GH#36126: the recovery helper loads pulse-dep-graph.sh only when this is
# undefined. Default to no declared dependency so release cases never reach
# native GraphQL; TEST_BLOCKED_BY=unresolved holds a re-armed release.
TEST_BLOCKED_BY=resolved
is_blocked_by_unresolved() {
	[[ "$TEST_BLOCKED_BY" == unresolved ]] && return 0
	return 1
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
	[[ "$contract" == *'brief precondition measured on this runner'* ]] || status=1
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

_legacy_recovery_check_gates() {
	local issue="$1" comments="$2" rc=0
	# Exercise the real backoff error code independently of evidence selection.
	(
		jq() {
			[[ "$*" != *'--argjson associations'* ]] || return 1
			command jq "$@"
			return $?
		}
		terminal_blocker_backoff_active "$comments" || rc=$?
		[[ "$rc" -eq 2 ]] || exit 1
		rc=0
		_tbr_release_legacy_hold owner/repo 42 "$issue" "$comments" "$(command jq -c '.[0]' <<<"$comments")" || rc=$?
		[[ "$rc" -eq 2 && "$projected" -eq 0 ]] || exit 1
	) || return 1
	(
		terminal_blocker_search_issues() {
			local query="$1"
			[[ "$query" != *'"CLAIM_RELEASED reason=blocked"'* ]] || printf '42\n'
			return 0
		}
		[[ "$(_tbr_seed_candidates owner/repo | tr -d '[:space:]')" == 42 ]] || exit 1
	) || return 1
	return 0
}

test_legacy_hold_requires_bound_retry() {
	local status=0
	if ! (
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		local issue='{"title":"Legacy hold","body":"updated brief","labels":[{"name":"status:blocked"}]}'
		local comments='' base='' legacy_events='' label_events='' scenario='' rc=0 projected=0 receipts=0
		local legacy_receipt=''
		local TERMINAL_BLOCKER_NOW_EPOCH=1793361600 # 2026-10-30T12:00:00Z
		local TERMINAL_BLOCKER_SELF_LOGIN=runner-a
		base=$(jq -nc '[{id:10,body:"<!-- ops:start -->\nCLAIM_RELEASED reason=blocked runner=runner-a ts=2026-10-30T10:00:00Z\n<!-- ops:end -->",user:{login:"runner-a"},author_association:"MEMBER",created_at:"2026-10-30T10:00:00Z"},
			{id:11,body:"terminal-blocker-circuit:retry",author_association:"MEMBER",created_at:"2026-10-30T11:00:00Z"}]')
		label_events='[[{"id":100,"event":"labeled","label":{"name":"status:blocked"},"created_at":"2026-10-30T10:00:09Z"}]]'
		gh() {
			[[ "$*" == *'/issues/42/events?per_page=100'* && "$legacy_events" != unavailable ]] || return 1
			printf '%s\n' "$legacy_events"
			return 0
		}
		set_issue_status() { projected=$((projected + 1)); return 0; }
		_tbr_post_rearm_receipt() {
			local marker="$3"
			receipts=$((receipts + 1))
			legacy_receipt="$marker"
			return 0
		}
		comments="$base" legacy_events="$label_events"
		[[ "$(_tbr_seed_reason "$comments" other-runner)" == unknown ]] || exit 1
		# Real producer prefix, different label actor, nine-second lag: releases once.
		_tbr_release_circuit_hold owner/repo 42 "$issue" "$comments" || exit 1
		comments=$(jq -c --arg body "$legacy_receipt" '. + [{id:30,body:$body,author_association:"MEMBER",created_at:"2026-10-30T11:30:00Z"}]' <<<"$comments")
		_tbr_release_circuit_hold owner/repo 42 "$issue" "$comments" || exit 1
		[[ "$projected" -eq 1 && "$receipts" -eq 1 ]] || exit 1
		local released="$comments" available='{"labels":[{"name":"status:available"}]}'
		_tbr_release_circuit_hold owner/repo 42 "$available" "$comments" || exit 1
		[[ "$projected" -eq 1 && "$receipts" -eq 1 ]] || exit 1
		comments=$(jq -c '.[-1].body |= "> " + .' <<<"$released")
		rc=0
		_tbr_release_circuit_hold owner/repo 42 "$available" "$comments" || rc=$?
		[[ "$rc" -eq 2 && "$projected" -eq 1 && "$receipts" -eq 1 ]] || exit 1
		# Each immutable identity participates in the receipt hash.
		for scenario in release label retry; do
			comments="$released" legacy_events="$label_events"
			case "$scenario" in
			release) comments=$(jq -c '.[0].id=12' <<<"$comments") ;;
			label) legacy_events=$(jq -c '.[0][0].id=101' <<<"$legacy_events") ;;
			retry) comments=$(jq -c '.[1].id=13' <<<"$comments") ;;
			esac
			_tbr_release_circuit_hold owner/repo 42 "$issue" "$comments" || exit 1
			[[ "$receipts" -eq "$projected" ]] || exit 1
			comments=$(jq -c --arg body "$legacy_receipt" '. + [{id:31,body:$body,author_association:"MEMBER",created_at:"2026-10-30T11:31:00Z"}]' <<<"$comments")
			_tbr_release_circuit_hold owner/repo 42 "$issue" "$comments" || exit 1
			[[ "$receipts" -eq "$projected" ]] || exit 1
		done
		[[ "$projected" -eq 4 ]] || exit 1
		for scenario in no_retry active expired untrusted_retry quoted_retry forged_release untrusted_release future_release future_retry old_retry newer_release newer_label same_second missing_event_id missing_release_id missing_retry_id unavailable malformed no_events unlabelled future_label structured permission absent; do
			comments="$base" legacy_events="$label_events" projected=0 receipts=0 rc=0
			case "$scenario" in
			no_retry) comments=$(jq -c '.[0:1]' <<<"$comments") ;;
			active) comments=$(jq -c '.[0:1] | .[0].created_at="2026-10-30T11:59:00Z" | . + [.[0] | .id=12 | .created_at="2026-10-30T11:59:01Z"]' <<<"$comments") ;;
			expired) comments=$(jq -c '.[0:1] | . + [.[0] | .id=9 | .created_at="2026-10-29T10:00:00Z"]' <<<"$comments") ;;
			untrusted_retry) comments=$(jq -c '.[1].author_association="COLLABORATOR"' <<<"$comments") ;;
			quoted_retry) comments=$(jq -c '.[1].body="> terminal-blocker-circuit:retry"' <<<"$comments") ;;
			forged_release) comments=$(jq -c '.[0].user.login="imposter"' <<<"$comments") ;;
			untrusted_release) comments=$(jq -c '.[0].user.login="runner-b" | .[0].author_association="NONE" | .[0].body |= sub("runner-a";"runner-b")' <<<"$comments") ;;
			future_release) comments=$(jq -c '.[0].created_at="2026-10-31T10:00:00Z"' <<<"$comments") ;;
			future_retry) comments=$(jq -c '.[1].created_at="2026-10-31T11:00:00Z"' <<<"$comments") ;;
			old_retry) comments=$(jq -c '.[1].created_at="2026-10-30T09:00:00Z"' <<<"$comments") ;;
			newer_release) comments=$(jq -c '. + [.[0] | .id=12 | .created_at="2026-10-30T11:30:00Z"]' <<<"$comments") ;;
			newer_label) legacy_events=$(jq -c '.[0] += [.[0][0] | .id=101 | .created_at="2026-10-30T11:30:00Z"]' <<<"$legacy_events") ;;
			same_second) comments=$(jq -c '.[1].created_at="2026-10-30T10:00:09Z"' <<<"$comments") ;;
			missing_event_id) legacy_events=$(jq -c '.[0][0] |= del(.id)' <<<"$legacy_events") ;;
			missing_release_id) comments=$(jq -c '.[0] |= del(.id)' <<<"$comments") ;;
			missing_retry_id) comments=$(jq -c '.[1] |= del(.id)' <<<"$comments") ;;
			unavailable) legacy_events=unavailable ;;
			malformed) legacy_events='{}' ;;
			no_events) legacy_events='[[]]' ;;
			unlabelled) legacy_events=$(jq -c '.[0][0].event="unlabeled"' <<<"$legacy_events") ;;
			future_label) legacy_events=$(jq -c '.[0][0].created_at="2026-10-31T10:00:00Z"' <<<"$legacy_events") ;;
			structured) comments=$(jq -c '. + [{id:8,body:"<!-- aidevops:terminal-blocker-observation revision=111111111111111111111111 blocker=222222222222222222222222 -->",author_association:"MEMBER",created_at:"2026-10-29T10:00:00Z"}]' <<<"$comments") ;;
			permission) comments=$(jq -c --arg f "$(_terminal_blocker_hash v2:permission_required)" '.[0:1] + [{id:8,body:("<!-- aidevops:terminal-blocker-observation revision=111111111111111111111111 blocker="+$f+" -->"),author_association:"MEMBER",created_at:"2026-10-29T10:00:00Z"}]' <<<"$comments") ;;
			absent) comments='[]' ;;
			esac
			_tbr_release_circuit_hold owner/repo 42 "$issue" "$comments" || rc=$?
			[[ "$rc" -ne 0 && "$projected" -eq 0 && "$receipts" -eq 0 ]] || { printf 'legacy scenario failed: %s\n' "$scenario" >&2; exit 1; }
		done
		comments="$base" legacy_events="$label_events"
		for scenario in hold-for-review needs-maintainer-permissions no-auto-dispatch parent-task needs-maintainer-review status:in-progress; do
			_tbr_release_circuit_hold owner/repo 42 "$(jq -c --arg hold "$scenario" '.labels += [{name:$hold}]' <<<"$issue")" "$comments" || exit 1
			[[ "$projected" -eq 0 ]] || exit 1
		done
		# The real backoff predicate must distinguish jq failure from expiry;
		# recovery must fail closed even though the trusted retry is otherwise valid.
		_legacy_recovery_check_gates "$issue" "$comments" || exit 1
		exit 0
	); then
		status=1
	fi
	print_result "legacy bare holds release only on a trusted retry after the current label event, once" "$status"
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
		# Discovery has its own coverage (test_owner_scoped_discovery).
		tbr_discover() { return 0; }
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

# GH#36126: a re-armed hold whose declared blocked-by dependency is still open
# stays blocked without a receipt and keeps its queue entry, rechecking every
# pass even when the issue snapshot is unchanged, then releases once the
# dependency resolves.
test_rearm_waits_for_blocked_by_dependency() {
	local status=0
	if ! (
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		TBR_ROOT="${TEST_ROOT}/dependency-rearm"
		TBR_REPOS_JSON="$REPOS_JSON"
		# Load shared runtime functions before installing write stubs.
		_tbr_start_budget || exit 1
		# Fixture names must not collide with _tbr_check_entry locals (issue,
		# comments): stubs run under bash dynamic scoping.
		local dep_fixture_comments='[]' revision="" marker="" queue_file="" rc=0 projected=0 receipts=0 dep_checks=0
		local dep_fixture_issue='{"state":"open","title":"Publish logos","body":"original","labels":[{"name":"status:blocked"}],"updated_at":"2026-10-30T01:00:00Z"}'
		export TERMINAL_BLOCKER_SELF_LOGIN=runner-one
		_tbr_run_stage() { shift; "$@"; return $?; }
		tbr_seed() { exit 1; }
		_tbr_decision_active() { exit 1; }
		gh() {
			[[ "$*" == 'api repos/owner/repo/issues/42' ]] || return 1
			printf '%s\n' "$dep_fixture_issue"
			return 0
		}
		terminal_blocker_fetch_trusted_comments() { printf '%s\n' "$dep_fixture_comments"; return 0; }
		set_issue_status() { projected=$((projected + 1)); return 0; }
		_tbr_post_rearm_receipt() { receipts=$((receipts + 1)); return 0; }
		is_blocked_by_unresolved() {
			local repo_slug="$2"
			local issue_number="$3"
			dep_checks=$((dep_checks + 1))
			[[ "$repo_slug" == owner/repo && "$issue_number" == 42 ]] || exit 1
			[[ "$TEST_BLOCKED_BY" == unresolved ]] && return 0
			return 1
		}
		revision=$(terminal_blocker_task_revision "$dep_fixture_issue" owner/repo 42 "$TEST_ROOT" permission_required) || exit 1
		marker="<!-- ${_TBC_OBSERVATION_MARKER} revision=${revision} blocker=$(_terminal_blocker_hash v2:permission_required) -->"
		dep_fixture_comments=$(jq -nc --arg m "$marker" \
			'[{id:10,body:$m,author_association:"MEMBER",created_at:"2026-10-30T00:00:00Z"},
			  {id:11,body:"Maintainer recovery.\n\nterminal-blocker-circuit:retry",author_association:"OWNER",created_at:"2026-10-30T00:30:00Z"}]')
		# The release helper itself reports the dependency hold distinctly.
		TEST_BLOCKED_BY=unresolved
		_tbr_release_circuit_hold owner/repo 42 "$dep_fixture_issue" "$dep_fixture_comments" 2>"${TEST_ROOT}/dependency-rearm.err" || rc=$?
		[[ "$rc" -eq 3 && "$projected" -eq 0 && "$receipts" -eq 0 ]] || exit 1
		[[ "$(<"${TEST_ROOT}/dependency-rearm.err")" == *'reason=dependency_blocked'* ]] || exit 1
		tbr_enqueue owner/repo 42 permission_required || exit 1
		queue_file="${TBR_ROOT}/queue/owner--repo--42.json"
		# Two complete passes with an unchanged snapshot: held, never stamped.
		dep_checks=0
		tbr_main rearm >"${TBR_ROOT}/out" 2>/dev/null || exit 1
		tbr_main rearm >"${TBR_ROOT}/out" 2>/dev/null || exit 1
		[[ -f "$queue_file" && "$projected" -eq 0 && "$receipts" -eq 0 && "$dep_checks" -eq 2 && ! -s "${TBR_ROOT}/out" ]] || exit 1
		[[ -z "$(jq -r '.rearm_checked_updated_at // ""' "$queue_file")" ]] || exit 1
		# The blocker closes without touching this issue: the next pass releases.
		TEST_BLOCKED_BY=resolved
		tbr_main rearm >"${TBR_ROOT}/out" 2>/dev/null || exit 1
		[[ ! -f "$queue_file" && "$projected" -eq 1 && "$receipts" -eq 1 && ! -s "${TBR_ROOT}/out" ]] || exit 1
		exit 0
	); then
		status=1
	fi
	print_result "re-armed hold with an unresolved blocked-by dependency stays queued without a receipt and releases once it resolves" "$status"
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

# shellcheck source=test-terminal-blocker-circuit-capability.sh
source "${SCRIPT_DIR}/tests/test-terminal-blocker-circuit-capability.sh"
# shellcheck source=test-terminal-blocker-circuit-discovery.sh
source "${SCRIPT_DIR}/tests/test-terminal-blocker-circuit-discovery.sh"

main() {
	test_owner_scoped_discovery
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
	test_legacy_hold_requires_bound_retry
	test_unknown_hold_rearms_on_trusted_retry
	test_retry_only_observation_recovery
	test_mechanical_rearm_pass
	test_rearm_waits_for_blocked_by_dependency
	test_mechanical_rearm_scheduler
	test_blocked_backoff_cli
	printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
}

main "$@"
