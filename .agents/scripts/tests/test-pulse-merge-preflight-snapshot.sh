#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=../pulse-merge-required-checks.sh
source "${SCRIPT_DIR}/../pulse-merge-required-checks.sh"

TEST_ROOT="$(mktemp -d -t pulse-preflight-snapshot.XXXXXX)"
LOGFILE="${TEST_ROOT}/pulse.log"
AIDEVOPS_REPOS_JSON="${TEST_ROOT}/repos.json"
export AIDEVOPS_REPOS_JSON AIDEVOPS_SKIP_GITHUB_ACTIONS_STATUS=1
write_default_repos_json() {
	cat >"$AIDEVOPS_REPOS_JSON" <<'EOF'
{"initialized_repos":[{"slug":"owner/repo","review_gate":{"advisory_check_contexts":["CodeFactor"]}}]}
EOF
	return 0
}
write_default_repos_json
PULSE_MERGE_QUIET_PERIOD_SECONDS=30
PULSE_MERGE_NOW_EPOCH="$(_pmrc_iso_to_epoch '2026-01-01T00:10:00Z')"
PULSE_MERGE_INFRA_RERUN_STATE_DIR="${TEST_ROOT}/infra-reruns"
PULSE_MERGE_CANCELLED_RERUN_STATE_DIR="${TEST_ROOT}/cancelled-reruns"
CANCELLED_RUN_SHA="sha-reviewed"
CANCELLED_RUN_ATTEMPT=1
SNAPSHOT_MODE="happy_advisory"
RERUN_CALLS=0
TESTS_RUN=0
TESTS_FAILED=0
EVIDENCE_LOG="${TEST_ROOT}/efficiency-evidence.log"
RULES_ATTRIBUTION_LOG="${TEST_ROOT}/rules-attribution.log"
SNAPSHOT_READ_COUNT_FILE="${TEST_ROOT}/snapshot-read-count"
SNAPSHOT_RETRY_QUEUE_LOG="${TEST_ROOT}/snapshot-retry-queue.log"
: >"$EVIDENCE_LOG"
: >"$RULES_ATTRIBUTION_LOG"
: >"$SNAPSHOT_RETRY_QUEUE_LOG"

gh_record_efficiency_evidence() {
	local name="$1"
	local value="$2"
	printf '%s=%s\n' "$name" "$value" >>"$EVIDENCE_LOG"
	return 0
}

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

_pmrc_gh_read() {
	local command="${1:-}"
	local subcommand="${2:-}"
	local endpoint="${3:-}"

	[[ "$command" == "gh" && "$subcommand" == "api" ]] || return 1
	case "${SNAPSHOT_MODE}:${endpoint}" in
	"check_runs_deferred:"*check-runs*)
		return 75
		;;
	"check_runs_timeout:"*check-runs*)
		return 124
		;;
	"check_runs_deferred_then_success:"*check-runs* | "check_runs_timeout_then_success:"*check-runs*)
		local read_count=0
		[[ -f "$SNAPSHOT_READ_COUNT_FILE" ]] && read_count=$(<"$SNAPSHOT_READ_COUNT_FILE")
		read_count=$((read_count + 1))
		printf '%s\n' "$read_count" >"$SNAPSHOT_READ_COUNT_FILE"
		if [[ "$read_count" -eq 1 ]]; then
			[[ "$SNAPSHOT_MODE" == "check_runs_deferred_then_success" ]] && return 75
			return 124
		fi
		;;
	"pr_fetch_error:repos/owner/repo/pulls/7" | "check_runs_error:"*check-runs* | \
		"status_error:"*commits/sha-reviewed/status* | "reviews_error:"*pulls/7/reviews* | \
		"issue_comments_error:"*issues/7/comments* | "inline_comments_error:"*pulls/7/comments*)
		return 1
		;;
	"pr_parse_error:repos/owner/repo/pulls/7" | "activity_parse_error:"*pulls/7/comments*)
		printf '%s\n' '{'
		return 0
		;;
	"pr_empty:repos/owner/repo/pulls/7")
		return 0
		;;
	esac
	"$@"
	return $?
}

_pulse_merge_queue_defer() {
	printf '%s/%s\n' "$1" "$2" >>"$SNAPSHOT_RETRY_QUEUE_LOG"
	printf 'queued\n'
	return 0
}

_required_contexts_for_default_branch() {
	local repo_slug="$1"
	[[ -n "$repo_slug" ]] || return 1
	[[ "$SNAPSHOT_MODE" == "required_contexts_error" ]] && return 1
	printf 'required-a\n'
	[[ "$SNAPSHOT_MODE" == "qlty_usage_pending_required" ]] && printf 'qlty usage\n'
	[[ "$SNAPSHOT_MODE" == "qlty_quota_exhausted_required" || "$SNAPSHOT_MODE" == "qlty_credits_required" ]] && printf 'qlty check\n'
	[[ "$SNAPSHOT_MODE" == "maintainer_alias_fail" || "$SNAPSHOT_MODE" == "maintainer_infra_fail" ]] && printf 'Maintainer Review & Assignee Gate\n'
	return 0
}

_ci_check_url_has_infra_failure_log() {
	local repo_slug="$1"
	local check_url="$2"
	[[ -n "$repo_slug" ]] || return 1
	[[ "$SNAPSHOT_MODE" == "infra_fail" && "$check_url" == "https://github.com/owner/repo/actions/runs/101/job/202" ||
		"$SNAPSHOT_MODE" == "required_infra_fail" && "$check_url" == "https://github.com/owner/repo/actions/runs/303/job/404" ||
		"$SNAPSHOT_MODE" == "maintainer_infra_fail" && "$check_url" == "https://github.com/owner/repo/actions/runs/505/job/606" ]]
	return $?
}

stub_review_threads() {
	if [[ "$SNAPSHOT_MODE" == "review_threads_paginated" ]]; then
		printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true},"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"gemini-code-assist[bot]"}}]}}]}}},"rateLimit":{"cost":1}}}'
	elif [[ "$SNAPSHOT_MODE" == "unresolved" ]]; then
		printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"gemini-code-assist[bot]"}}]}}]}}},"rateLimit":{"cost":1}}}'
	elif [[ "$SNAPSHOT_MODE" == human_* ]]; then
		printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"human-reviewer"}}]}}]}}},"rateLimit":{"cost":1}}}'
	elif [[ "$SNAPSHOT_MODE" == "review_threads_cost_changed" ]]; then
		printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}},"rateLimit":{"cost":2}}}'
	else
		printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}},"rateLimit":{"cost":1}}}'
	fi
	return 0
}

stub_effective_rules() {
	local endpoint="$1"
	if [[ "$SNAPSHOT_MODE" == "human_rules_error" ]]; then
		return 1
	elif [[ "$SNAPSHOT_MODE" == "human_rules_malformed" ]]; then
		printf '%s\n' '{"unexpected":"object"}'
	elif [[ "$SNAPSHOT_MODE" == "human_required_slash" && "$endpoint" != "repos/owner/repo/rules/branches/release%2F1.x" ]]; then
		return 1
	elif [[ "$SNAPSHOT_MODE" == "human_required" || "$SNAPSHOT_MODE" == "human_required_slash" ]]; then
		printf '%s\n' '[{"type":"pull_request","ruleset_source":"arbitrary-policy-name","parameters":{"required_review_thread_resolution":true}}]'
	else
		printf '%s\n' '[{"type":"pull_request","parameters":{"required_review_thread_resolution":false}}]'
	fi
	return 0
}

stub_inline_comments() {
	if [[ "$SNAPSHOT_MODE" == "stale_gate" || "$SNAPSHOT_MODE" == "unresolved" ]]; then
		printf '%s\n' '[[{"user":{"login":"gemini-code-assist[bot]"},"created_at":"2026-01-01T00:00:40Z","updated_at":"2026-01-01T00:00:40Z"}]]'
	elif [[ "$SNAPSHOT_MODE" == "large_bot_activity" ]]; then
		printf '[[{"user":{"login":"gemini-code-assist[bot]"},"created_at":"2026-01-01T00:00:40Z","body":"'
		dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\000' x
		printf '"}]]\n'
	elif [[ "$SNAPSHOT_MODE" == "activity_wrong_shape" ]]; then
		printf '%s\n' '[{}]'
	else
		printf '%s\n' '[[]]'
	fi
	return 0
}

stub_commit_status() {
	local gate_at="2026-01-01T00:01:10Z"
	[[ "$SNAPSHOT_MODE" == "stale_gate" ]] && gate_at="2026-01-01T00:00:20Z"
	if [[ "$SNAPSHOT_MODE" == "no_status_gate" || "$SNAPSHOT_MODE" == "review_alias_skipped" || "$SNAPSHOT_MODE" == "review_alias_neutral" ]]; then
		printf '%s\n' '{"statuses":[]}'
	elif [[ "$SNAPSHOT_MODE" == "review_stable_fail" ]]; then
		printf '{"statuses":[{"context":"review-bot-gate","state":"failure","updated_at":"%s"}]}\n' "$gate_at"
	elif [[ "$SNAPSHOT_MODE" == qlty_external_fail* ]]; then
		printf '{"statuses":[{"context":"review-bot-gate","state":"success","updated_at":"%s"},{"context":"qlty check","state":"failure","updated_at":"2026-01-01T00:01:05Z"}]}\n' "$gate_at"
	elif [[ "$SNAPSHOT_MODE" == qlty_quota_exhausted* ]]; then
		printf '{"statuses":[{"context":"review-bot-gate","state":"success","updated_at":"%s"},{"context":"qlty check","state":"error","description":"Qlty did not run because you are out of minutes.","updated_at":"2026-01-01T00:01:05Z"}]}\n' "$gate_at"
	elif [[ "$SNAPSHOT_MODE" == qlty_credits* ]]; then
		local context="qlty check" description="Qlty did not run because you are out of credits."
		[[ "$SNAPSHOT_MODE" == "qlty_credits_case" ]] && context="QLTY CHECK" && description="QLTY DID NOT RUN BECAUSE YOU ARE OUT OF CREDITS."
		printf '{"statuses":[{"context":"review-bot-gate","state":"success","updated_at":"%s"},{"context":"%s","state":"failure","description":"%s","updated_at":"2026-01-01T00:01:05Z"}]}\n' "$gate_at" "$context" "$description"
	elif [[ "$SNAPSHOT_MODE" == qlty_usage_pending* ]]; then
		printf '{"statuses":[{"context":"review-bot-gate","state":"success","updated_at":"%s"},{"context":"qlty usage","state":"pending","updated_at":"2026-01-01T00:01:05Z"}]}\n' "$gate_at"
	elif [[ "$SNAPSHOT_MODE" == "same_name_source_conflict" ]]; then
		printf '{"statuses":[{"context":"review-bot-gate","state":"success","updated_at":"%s"},{"context":"ProviderMirror","state":"failure","updated_at":"2026-01-01T00:01:03Z"}]}\n' "$gate_at"
	else
		printf '{"statuses":[{"context":"review-bot-gate","state":"success","updated_at":"%s"}]}\n' "$gate_at"
	fi
	return 0
}

stub_advisory_companion_check() {
	case "$SNAPSHOT_MODE" in
	"skipped_companion_rerun")
		printf '%s' ',{"name":"Qlty Smell Regression","status":"completed","conclusion":"skipped","completed_at":"2026-01-01T00:02:00Z"}'
		;;
	"qlty_external_fail_with_companion")
		printf '%s' ',{"name":"Qlty Regression Gate","status":"completed","conclusion":"success","completed_at":"2026-01-01T00:01:02Z"}'
		;;
	esac
	return 0
}

stub_pull_head() {
	if [[ "$SNAPSHOT_MODE" == "new_head" ]]; then
		printf '%s\n' '{"head":{"sha":"sha-new"},"base":{"ref":"main"}}'
	elif [[ "$SNAPSHOT_MODE" == "human_required_slash" ]]; then
		printf '%s\n' '{"head":{"sha":"sha-reviewed"},"base":{"ref":"release/1.x"}}'
	else
		printf '%s\n' '{"head":{"sha":"sha-reviewed"},"base":{"ref":"main"}}'
	fi
	return 0
}

gh() {
	local command="$1"
	local endpoint="${2:-}"
	if [[ "$command" == "run" && "$endpoint" == "rerun" ]]; then
		RERUN_CALLS=$((RERUN_CALLS + 1))
		return 0
	fi
	[[ "$command" == "api" ]] || return 1

	if [[ "$endpoint" == "graphql" ]]; then
		stub_review_threads
		return $?
	fi

	case "$endpoint" in
	repos/owner/repo)
		case "$SNAPSHOT_MODE" in
		qlty_credits_public) printf '%s\n' '{"private":false,"owner":{"type":"User"}}' ;;
		qlty_credits_org) printf '%s\n' '{"private":false,"owner":{"type":"Organization"}}' ;;
		qlty_credits_unknown) return 1 ;;
		qlty_credits_malformed) printf '%s\n' '{"private":"true","owner":{"type":"User"}}' ;;
		*) printf '%s\n' '{"private":true,"owner":{"type":"User"}}' ;;
		esac
		;;
	repos/owner/repo/actions/runs/707)
		printf '{"head_sha":"%s","status":"completed","conclusion":"%s","run_attempt":%s}\n' "$CANCELLED_RUN_SHA" "${CANCELLED_RUN_CONCLUSION:-cancelled}" "$CANCELLED_RUN_ATTEMPT"
		;;
	repos/owner/repo/pulls/7)
		stub_pull_head
		return $?
		;;
	repos/owner/repo/rules/branches/*)
		printf '%s|%s|%s\n' "${AIDEVOPS_GH_QUOTA_COST:-}" \
			"${AIDEVOPS_GH_ROUTE_DECISION:-}" "$endpoint" >>"$RULES_ATTRIBUTION_LOG"
		stub_effective_rules "$endpoint"
		return $?
		;;
	*check-runs*)
		if [[ "$SNAPSHOT_MODE" == "large_payload" ]]; then
			printf '[{"padding":"'
			dd if=/dev/zero bs=1024 count=512 2>/dev/null | tr '\000' x
			printf '","check_runs":[{"name":"required-a","status":"completed","conclusion":"success","completed_at":"2026-01-01T00:01:00Z"}]}]\n'
			return 0
		fi
		[[ "$SNAPSHOT_MODE" == "empty_check_runs" ]] && return 0
		local required_conclusion="success" required_url="" broad_status="completed" broad_conclusion="success"
		local broad_completed_at="2026-01-01T00:01:00Z" extra_check=""
		extra_check=$(stub_advisory_companion_check)
		[[ "$SNAPSHOT_MODE" == "required_fail" ]] && required_conclusion="failure"
		if [[ "$SNAPSHOT_MODE" == "required_infra_fail" ]]; then
			required_conclusion="failure"
			required_url=',"details_url":"https://github.com/owner/repo/actions/runs/303/job/404"'
		fi
		if [[ "$SNAPSHOT_MODE" == "pending" ]]; then
			broad_status="in_progress"
			broad_conclusion="null"
		fi
		[[ "$SNAPSHOT_MODE" == "recent" ]] && broad_completed_at="2026-01-01T00:09:50Z"
		if [[ "$SNAPSHOT_MODE" == "unclassified_fail" ]]; then
			extra_check=',{"name":"CodeFactor","status":"completed","conclusion":"failure","details_url":"https://github.com/owner/repo/runs/99","completed_at":"2026-01-01T00:01:00Z"}'
		elif [[ "$SNAPSHOT_MODE" == "infra_fail" ]]; then
			extra_check=',{"name":"sync / Record ordered forge event","status":"completed","conclusion":"failure","details_url":"https://github.com/owner/repo/actions/runs/101/job/202","completed_at":"2026-01-01T00:01:00Z"}'
		elif [[ "$SNAPSHOT_MODE" == "cancelled_workflow" ]]; then
			extra_check=',{"name":"Cancelled scan","status":"completed","conclusion":"cancelled","details_url":"https://github.com/owner/repo/actions/runs/707/job/808","completed_at":"2026-01-01T00:01:00Z"},{"name":"Cancelled lint","status":"completed","conclusion":"cancelled","details_url":"https://github.com/owner/repo/actions/runs/707/job/809","completed_at":"2026-01-01T00:01:00Z"}'
		elif [[ "$SNAPSHOT_MODE" == "configured_fail" ]]; then
			extra_check=',{"name":"CodeFactor","status":"completed","conclusion":"failure","completed_at":"2026-01-01T00:01:00Z"}'
		elif [[ "$SNAPSHOT_MODE" == "review_alias_cancelled" ]]; then
			extra_check=',{"name":"gate / review-bot-gate","status":"completed","conclusion":"cancelled","completed_at":"2026-01-01T00:01:02Z"}'
		elif [[ "$SNAPSHOT_MODE" == "review_alias_skipped" ]]; then
			extra_check=',{"name":"gate / review-bot-gate","status":"completed","conclusion":"skipped","completed_at":"2026-01-01T00:01:02Z"}'
		elif [[ "$SNAPSHOT_MODE" == "review_alias_neutral" ]]; then
			extra_check=',{"name":"gate / review-bot-gate","status":"completed","conclusion":"neutral","completed_at":"2026-01-01T00:01:02Z"}'
		elif [[ "$SNAPSHOT_MODE" == "review_stable_fail" ]]; then
			extra_check=',{"name":"gate / review-bot-gate","status":"completed","conclusion":"success","completed_at":"2026-01-01T00:01:02Z"}'
		elif [[ "$SNAPSHOT_MODE" == "maintainer_alias_fail" ]]; then
			extra_check=',{"name":"maintainer-gate","status":"completed","conclusion":"success","completed_at":"2026-01-01T00:01:00Z"},{"name":"Maintainer Review & Assignee Gate","status":"completed","conclusion":"failure","completed_at":"2026-01-01T00:01:01Z"},{"name":"gate / Maintainer Review & Assignee Gate","status":"completed","conclusion":"success","completed_at":"2026-01-01T00:01:02Z"}'
		elif [[ "$SNAPSHOT_MODE" == "maintainer_infra_fail" ]]; then
			extra_check=',{"name":"gate / Maintainer Review & Assignee Gate","status":"completed","conclusion":"failure","details_url":"https://github.com/owner/repo/actions/runs/505/job/606","completed_at":"2026-01-01T00:01:02Z"}'
		elif [[ "$SNAPSHOT_MODE" == "maintainer_stable_fail" ]]; then
			extra_check=',{"name":"maintainer-gate","status":"completed","conclusion":"failure","completed_at":"2026-01-01T00:01:02Z"},{"name":"gate / Maintainer Review & Assignee Gate","status":"completed","conclusion":"success","completed_at":"2026-01-01T00:01:01Z"}'
		elif [[ "$SNAPSHOT_MODE" == "maintainer_legacy_fail" ]]; then
			extra_check=',{"name":"Maintainer Review & Assignee Gate","status":"completed","conclusion":"failure","completed_at":"2026-01-01T00:01:01Z"},{"name":"gate / Maintainer Review & Assignee Gate","status":"completed","conclusion":"failure","completed_at":"2026-01-01T00:01:02Z"}'
		elif [[ "$SNAPSHOT_MODE" == "same_name_source_conflict" ]]; then
			extra_check=',{"name":"ProviderMirror","status":"completed","conclusion":"success","completed_at":"2026-01-01T00:01:02Z"}'
		fi
		printf '[{"check_runs":[{"name":"required-a","status":"completed","conclusion":"%s"%s,"completed_at":"2026-01-01T00:01:00Z"},{"name":"Framework Validation","status":"%s","conclusion":%s,"completed_at":"%s"},{"name":"Qlty Smell Regression","status":"completed","conclusion":"success","completed_at":"2026-01-01T00:01:00Z"},{"name":"Qlty Smell Threshold","status":"completed","conclusion":"failure","completed_at":"2026-01-01T00:01:00Z"}%s]}]\n' \
			"$required_conclusion" "$required_url" "$broad_status" "$([[ "$broad_conclusion" == "null" ]] && printf 'null' || printf '"%s"' "$broad_conclusion")" "$broad_completed_at" "$extra_check"
		;;
	*commits/sha-reviewed/status*)
		stub_commit_status
		return $?
		;;
	*pulls/7/reviews*)
		printf '%s\n' '[[{"user":{"login":"gemini-code-assist[bot]"},"submitted_at":"2026-01-01T00:00:30Z"}]]'
		;;
	*issues/7/comments*)
		printf '%s\n' '[[]]'
		;;
	*pulls/7/comments*)
		stub_inline_comments
		return $?
		;;
	*)
		printf 'Unhandled gh endpoint: %s\n' "$endpoint" >&2
		return 1
		;;
	esac
	return 0
}

assert_gate() {
	local description="$1"
	local mode="$2"
	local expected_rc="$3"
	local rc=0
	SNAPSHOT_MODE="$mode"
	: >"$LOGFILE"
	: >"$SNAPSHOT_READ_COUNT_FILE"
	: >"$SNAPSHOT_RETRY_QUEUE_LOG"
	_pulse_merge_preflight_snapshot_gate owner/repo 7 sha-reviewed || rc=$?
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq "$expected_rc" ]]; then
		printf 'PASS %s\n' "$description"
		return 0
	fi
	printf 'FAIL %s (expected rc=%s, actual rc=%s)\n' "$description" "$expected_rc" "$rc"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_cancelled_workflow_recovery() {
	local before="$RERUN_CALLS" rc=0
	local url="https://github.com/owner/repo/actions/runs/707/job/808"
	assert_gate "cancelled jobs keep merge blocked and rerun their shared workflow once" cancelled_workflow 1
	assert_gate "unchanged cancelled snapshot cannot rerun again" cancelled_workflow 1
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$RERUN_CALLS" -eq $((before + 1)) && "$_PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON" == "[]" ]]; then
		printf 'PASS cancelled jobs deduplicate workflow reruns without code repair\n'
	else
		printf 'FAIL cancelled workflow rerun deduplication or repair evidence\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	CANCELLED_RUN_ATTEMPT=2
	assert_gate "cancelled rerun remains blocking" cancelled_workflow 1
	_pmrc_rerun_cancelled_check owner/repo 7 sha-reviewed "$url"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$RERUN_CALLS" -eq $((before + 1)) ]] &&
		[[ "$(grep -c 'cancelled workflow recovery escalated' "$LOGFILE")" -eq 1 ]]; then
		printf 'PASS repeated cancellation escalates once without rerun amplification\n'
	else
		printf 'FAIL repeated cancellation escalation\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	# Old URLs, dry-run and foreign URLs cannot start another run.
	_pmrc_rerun_cancelled_check owner/repo 7 sha-new "$url" || rc=$?
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 1 ]]; then
		printf 'PASS stale run SHA cannot trigger recovery\n'
	else
		printf 'FAIL stale run SHA triggered recovery\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	CANCELLED_RUN_SHA=sha-new
	DRY_RUN=1
	_pmrc_rerun_cancelled_check owner/repo 7 sha-new "$url" || true
	DRY_RUN=0
	_pmrc_rerun_cancelled_check owner/repo 7 sha-new "https://github.com/other/repo/actions/runs/707" || true
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$RERUN_CALLS" -eq $((before + 1)) ]]; then
		printf 'PASS dry-run and foreign URL suppress writes\n'
	else
		printf 'FAIL dry-run or foreign URL allowed writes\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	CANCELLED_RUN_CONCLUSION=failure
	_pmrc_rerun_cancelled_check owner/repo 7 sha-new "$url"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$RERUN_CALLS" -eq $((before + 2)) ]]; then
		printf 'PASS changed head permits bounded recovery for a mixed failed/cancelled workflow\n'
	else
		printf 'FAIL changed head did not permit recovery\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	# Simulate a crash after reserving an attempt, before a submission receipt.
	CANCELLED_RUN_SHA=sha-interrupted
	mkdir "$PULSE_MERGE_CANCELLED_RERUN_STATE_DIR/owner-repo-7-sha-interrupted-707"
	: >"$LOGFILE"
	_pmrc_rerun_cancelled_check owner/repo 7 sha-interrupted "$url" || true
	_pmrc_rerun_cancelled_check owner/repo 7 sha-interrupted "$url" || true
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$RERUN_CALLS" -eq $((before + 2)) ]] &&
		[[ "$(grep -c 'incomplete submission receipt' "$LOGFILE")" -eq 1 ]]; then
		printf 'PASS interrupted recovery escalates once without replaying an ambiguous request\n'
	else
		printf 'FAIL interrupted recovery was replayed or not escalated once\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	assert_gate "fresh successful snapshot clears cancelled blockers" happy_advisory 0
	return 0
}

assert_snapshot_transient_retry_cases() {
	local read_count=""
	AIDEVOPS_PULSE_MERGE_SNAPSHOT_RETRY_DELAY_SECONDS=0
	export AIDEVOPS_PULSE_MERGE_SNAPSHOT_RETRY_DELAY_SECONDS
	_PMP_MERGE_PASS_DEADLINE_EPOCH=$(($(date +%s) + 30))

	assert_gate "admission-deferred exact-head snapshot recovers on one bounded retry" \
		check_runs_deferred_then_success 0
	read_count=$(<"$SNAPSHOT_READ_COUNT_FILE")
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$read_count" -eq 2 ]] && grep -qF "retrying once" "$LOGFILE"; then
		printf 'PASS admission deferral used exactly one audited retry\n'
	else
		printf 'FAIL admission deferral retry count/log (count=%s)\n' "$read_count"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi

	assert_gate "timed-out exact-head snapshot recovers on one bounded retry" \
		check_runs_timeout_then_success 0

	assert_gate_blocker "repeated transient snapshot failure keeps merge blocked" \
		check_runs_deferred 1 "$PMRC_BLOCKER_SNAPSHOT_UNAVAILABLE"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$(grep -cF 'owner/repo/7' "$SNAPSHOT_RETRY_QUEUE_LOG" || true)" -eq 1 ]] &&
		grep -qF "next-cycle priority is preserved" "$LOGFILE"; then
		printf 'PASS exhausted transient retry preserves next-cycle priority\n'
	else
		printf 'FAIL exhausted transient retry did not preserve next-cycle priority\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi

	_PMP_MERGE_PASS_DEADLINE_EPOCH=$(date +%s)
	assert_gate_blocker "expired merge-pass deadline suppresses same-cycle retry" \
		check_runs_timeout_then_success 1 "$PMRC_BLOCKER_SNAPSHOT_UNAVAILABLE"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$(<"$SNAPSHOT_READ_COUNT_FILE")" -eq 1 ]] &&
		[[ "$(grep -cF 'owner/repo/7' "$SNAPSHOT_RETRY_QUEUE_LOG" || true)" -eq 1 ]]; then
		printf 'PASS deadline exhaustion blocks retry and preserves next-cycle priority\n'
	else
		printf 'FAIL deadline exhaustion retried or lost next-cycle priority\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi

	unset _PMP_MERGE_PASS_DEADLINE_EPOCH AIDEVOPS_PULSE_MERGE_SNAPSHOT_RETRY_DELAY_SECONDS
	return 0
}

assert_gate_blocker() {
	local description="$1"
	local mode="$2"
	local expected_rc="$3"
	local expected_blocker="$4"

	assert_gate "$description" "$mode" "$expected_rc"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "${_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND:-}" == "$expected_blocker" ]]; then
		printf 'PASS %s exports blocker %s\n' "$description" "${expected_blocker:-<none>}"
		return 0
	fi
	printf 'FAIL %s exported blocker %s (expected %s)\n' \
		"$description" "${_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND:-<none>}" "${expected_blocker:-<none>}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_gate_logged() {
	local description="$1"
	local mode="$2"
	local expected_log="$3"

	assert_gate "$description" "$mode" 1
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -q "$expected_log" "$LOGFILE"; then
		printf 'PASS %s is audited\n' "$description"
		return 0
	fi
	printf 'FAIL %s did not log: %s\n' "$description" "$expected_log"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_snapshot_acquisition_failures_are_audited() {
	assert_gate_logged "pull-request fetch failure" pr_fetch_error "pull-request fetch failed"
	assert_gate_logged "empty pull-request response" pr_empty "pull-request parse failed"
	assert_gate_logged "pull-request parse failure" pr_parse_error "pull-request parse failed"
	assert_gate_logged "required-context lookup failure" required_contexts_error "required-context lookup failed"
	assert_gate_logged "check-runs fetch failure" check_runs_error "check-runs fetch failed"
	assert_gate_logged "commit-status fetch failure" status_error "commit-status fetch failed"
	assert_gate_logged "check-set parse failure" empty_check_runs "check-set parse failed"
	assert_gate_logged "reviews fetch failure" reviews_error "reviews fetch failed"
	assert_gate_logged "issue-comments fetch failure" issue_comments_error "issue-comments fetch failed"
	assert_gate_logged "inline-comments fetch failure" inline_comments_error "inline-comments fetch failed"
	assert_gate_logged "bot-activity parse failure" activity_parse_error "bot-activity parse failed"
	assert_gate_logged "wrong-shaped bot-activity response" activity_wrong_shape "bot-activity parse failed"
	return 0
}

assert_large_bot_activity_streams() {
	local activity=""
	local rc=0
	SNAPSHOT_MODE="large_bot_activity"
	: >"$LOGFILE"
	activity=$(_pmrc_snapshot_bot_activity_json owner/repo 7) || rc=$?
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]] && jq -e \
		'.count == 2 and .latest_at == "2026-01-01T00:00:40Z"' \
		<<<"$activity" >/dev/null; then
		printf 'PASS oversized inline-comment payload contributes bot activity\n'
		return 0
	fi
	printf 'FAIL oversized inline-comment payload did not produce expected activity (rc=%s, output=%s)\n' \
		"$rc" "$activity"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_human_review_thread_rules() {
	assert_gate_blocker "unresolved human thread blocks when effective rules require resolution" \
		human_required 1 "$PMRC_BLOCKER_REQUIRED_REVIEW_THREADS"
	if grep -q "requires thread resolution" "$LOGFILE"; then
		printf 'PASS required human thread blocker is audited\n'
	else
		printf 'FAIL required human thread blocker is audited\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_gate_blocker "unresolved human thread passes when effective rules do not require resolution" human_not_required 0 ""
	assert_gate_blocker "required human thread supports slash-containing base branches" \
		human_required_slash 1 "$PMRC_BLOCKER_REQUIRED_REVIEW_THREADS"
	assert_gate_blocker "effective-rules API failure with unresolved human thread fails closed" \
		human_rules_error 1 "$PMRC_BLOCKER_SNAPSHOT_UNAVAILABLE"
	assert_gate_blocker "malformed effective-rules response with unresolved human thread fails closed" \
		human_rules_malformed 1 "$PMRC_BLOCKER_SNAPSHOT_UNAVAILABLE"
	return 0
}

assert_effective_rules_have_exact_rest_cost() {
	local rc=0
	SNAPSHOT_MODE="human_rules_error"
	: >"$RULES_ATTRIBUTION_LOG"
	_pmrc_review_thread_resolution_required "owner/repo" "main" >/dev/null 2>&1 || rc=$?
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 1 ]] &&
		grep -qF '1|pulse-effective-rules-rest|repos/owner/repo/rules/branches/main' \
			"$RULES_ATTRIBUTION_LOG"; then
		printf 'PASS failed effective-rules reads retain exact REST cost\n'
		return 0
	fi
	printf 'FAIL failed effective-rules read lacked exact REST cost (rc=%s)\n' "$rc"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_configured_advisory_contexts_are_null_safe() {
	local contexts="" rc=0
	cat >"$AIDEVOPS_REPOS_JSON" <<'EOF'
{"initialized_repos":[{"slug":null},{"slug":"owner/repo","review_gate":{"advisory_check_contexts":["CodeFactor"]}}]}
EOF
	contexts=$(_pmrc_configured_advisory_contexts_json "OWNER/REPO") || rc=$?
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 && "$contexts" == '["CodeFactor"]' ]]; then
		printf 'PASS null repository slug does not poison a later advisory-context match\n'
	else
		printf 'FAIL null repository slug lookup (rc=%s, output=%s)\n' "$rc" "$contexts"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi

	contexts=""
	rc=0
	contexts=$(_pmrc_configured_advisory_contexts_json "other/repo") || rc=$?
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 && "$contexts" == '[]' ]]; then
		printf 'PASS unmatched repository slug returns an empty advisory-context array\n'
	else
		printf 'FAIL unmatched repository slug lookup (rc=%s, output=%s)\n' "$rc" "$contexts"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi

	write_default_repos_json
	return 0
}

assert_malformed_advisory_contexts_fail_closed_once() {
	local failure_count=0
	cat >"$AIDEVOPS_REPOS_JSON" <<'EOF'
{"initialized_repos":[{"slug":"owner/repo","review_gate":{"advisory_check_contexts":{"private-sentinel":true}}}]}
EOF
	assert_gate_blocker "malformed advisory contexts fail closed" \
		happy_advisory 1 "$PMRC_BLOCKER_SNAPSHOT_UNAVAILABLE"
	failure_count=$(grep -cF \
		"configured advisory-context lookup failed for PR #7 in owner/repo" \
		"$LOGFILE" || true)
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$failure_count" -eq 1 ]] &&
		! grep -qF "private-sentinel" "$LOGFILE" &&
		! grep -qF "$AIDEVOPS_REPOS_JSON" "$LOGFILE"; then
		printf 'PASS malformed advisory contexts emit one privacy-safe failure log\n'
	else
		printf 'FAIL malformed advisory-context logging was duplicated or exposed input details\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi

	write_default_repos_json
	return 0
}

set_live_evidence() {
	local status="$1"
	local head_sha="${2:-sha-reviewed}"
	local author_class="${3:-trusted}"
	local permitted="${4:-true}"
	local observed_at="${5:-2026-01-01T00:10:00Z}"
	_PULSE_REVIEW_GATE_EVIDENCE=$(jq -nc --arg status "$status" --arg head "$head_sha" --arg class "$author_class" --arg observed_at "$observed_at" --argjson permitted "$permitted" '
		{schema:"aidevops.review-gate-evidence/v1",repo:"owner/repo",pr:"7",head_sha:$head,status:$status,author:{login:"reviewer",association:(if $class == "trusted" then "MEMBER" else "CONTRIBUTOR" end),class:$class},permitted:$permitted,reason:"test",state:(if $permitted then "pass" else "waiting" end),merge_gate:(if $permitted then "clear" else "blocked" end),exit_code:0,observed_at:$observed_at}
	')
	return 0
}

assert_infrastructure_rerun_unset_defaults_safe() {
	local output="" rc=0
	output=$(
		unset LOGFILE HOME AIDEVOPS_TEMP_DIR PULSE_MERGE_INFRA_RERUN_STATE_DIR
		_pmrc_rerun_infrastructure_check owner/repo 7 required-a \
			"https://github.com/owner/repo/actions/runs/707/job/808"
	) 2>&1 || rc=$?
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 1 && -z "$output" ]]; then
		printf 'PASS unset HOME fails closed without resolving a root-level state directory\n'
		return 0
	fi
	printf 'FAIL unset HOME was not handled safely (rc=%s, output=%s)\n' "$rc" "$output"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_infrastructure_rerun_unset_logfile_safe() {
	local output="" rc=0 stderr_file="${TEST_ROOT}/unset-log-stderr"
	(
		unset LOGFILE HOME AIDEVOPS_TEMP_DIR
		PULSE_MERGE_INFRA_RERUN_STATE_DIR="${TEST_ROOT}/unset-log-reruns"
		_pmrc_rerun_infrastructure_check owner/repo 7 required-a \
			"https://github.com/owner/repo/actions/runs/909/job/1001"
	) 2>"$stderr_file" || rc=$?
	output=$(<"$stderr_file")
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 && "$output" == *"requested infrastructure rerun"* ]]; then
		printf 'PASS unset LOGFILE falls back to stderr under set -u\n'
		return 0
	fi
	printf 'FAIL unset LOGFILE was not handled safely (rc=%s, output=%s)\n' "$rc" "$output"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_actions_incident_suppresses_infrastructure_rerun() {
	local helper="${TEST_ROOT}/gh-status-incident" rc=0
	cat >"$helper" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
	chmod +x "$helper"
	RERUN_CALLS=0
	AIDEVOPS_SKIP_GITHUB_ACTIONS_STATUS=0 AIDEVOPS_GH_STATUS_HELPER="$helper" \
		_pmrc_rerun_infrastructure_check owner/repo 7 required-a \
		"https://github.com/owner/repo/actions/runs/111/job/222" || rc=$?
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 && "$RERUN_CALLS" -eq 0 ]] &&
		grep -qF "retry amplification suppressed" "$LOGFILE"; then
		printf 'PASS active Actions incident suppresses infrastructure rerun\n'
	else
		printf 'FAIL active Actions incident did not suppress rerun (rc=%s, calls=%s)\n' "$rc" "$RERUN_CALLS"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

assert_check_run_app_slug_survives_normalization() {
	local snapshot=""
	snapshot=$(printf '%s\n%s\n' \
		'[{"check_runs":[{"name":"Build","status":"queued","conclusion":null,"app":{"slug":"github-actions"}}]}]' \
		'{"statuses":[]}' |
		_pmrc_normalize_snapshot_checks_json owner/repo sha-reviewed)
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$snapshot" | jq -e \
		'length == 1 and .[0].name == "Build" and .[0].app_slug == "github-actions"' >/dev/null; then
		printf 'PASS check-run app slug survives current-head normalization\n'
	else
		printf 'FAIL check-run app slug was lost during current-head normalization\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

assert_review_and_head_snapshot_cases() {
	assert_gate "same-name check-run and status retain independent source failures" same_name_source_conflict 1
	set_live_evidence PASS
	assert_gate "configured non-required provider failure passes with typed current-head evidence" configured_fail 0
	set_live_evidence PASS_ADVISORY
	assert_gate "configured provider failure passes with trusted advisory-default evidence" configured_fail 0
	set_live_evidence PASS_ADVISORY sha-reviewed external false
	assert_gate "configured provider failure blocks external advisory evidence" configured_fail 1
	set_live_evidence PASS_RATE_LIMITED sha-reviewed external false
	assert_gate "configured provider failure blocks external rate-limit evidence" configured_fail 1
	_PULSE_REVIEW_GATE_EVIDENCE=""
	assert_gate "stable review-bot status supersedes a cancelled caller alias" review_alias_cancelled 0
	assert_gate_blocker "failed stable review-bot status overrides a successful caller alias" \
		review_stable_fail 1 "$PMRC_BLOCKER_REVIEW_GATE"
	assert_gate_blocker "alias-only skipped review gate fails closed" \
		review_alias_skipped 1 "$PMRC_BLOCKER_REVIEW_GATE"
	assert_gate_blocker "alias-only neutral review gate fails closed" \
		review_alias_neutral 1 "$PMRC_BLOCKER_REVIEW_GATE"
	assert_gate "stable maintainer-gate success supersedes stale alias failures" maintainer_alias_fail 0
	assert_gate "stable maintainer-gate failure remains one logical blocker" maintainer_stable_fail 1
	if [[ "$(grep -c "maintainer-gate family is terminal-failure" "$LOGFILE" || true)" -eq 1 ]]; then
		printf 'PASS maintainer-gate aliases emit one audited blocker\n'
	else
		printf 'FAIL maintainer-gate aliases did not emit exactly one blocker\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_gate "legacy maintainer aliases fail closed without stable context" maintainer_legacy_fail 1
	assert_gate "infrastructure-failed maintainer gate requests rerun and stays blocked" maintainer_infra_fail 1
	if [[ "$RERUN_CALLS" -eq 2 ]] && grep -q "maintainer-gate family has a proven infrastructure failure" "$LOGFILE"; then
		printf 'PASS infrastructure-failed maintainer gate requests audited rerun\n'
	else
		printf 'FAIL infrastructure-failed maintainer gate rerun was not requested\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_gate_blocker "unresolved late inline finding blocks merge" unresolved 1 "$PMRC_BLOCKER_REVIEW_BOT_THREADS"
	assert_gate_blocker "paginated review-thread snapshot fails closed without actionable remediation" \
		review_threads_paginated 1 "$PMRC_BLOCKER_SNAPSHOT_UNAVAILABLE"
	assert_gate_logged "review-thread quota-cost contract drift" \
		review_threads_cost_changed "GraphQL cost contract changed"
	assert_human_review_thread_rules
	assert_gate "late review activity invalidates stale gate success" stale_gate 1
	set_live_evidence PASS sha-reviewed trusted true 2026-01-01T00:00:50Z
	assert_gate "newer typed live evidence supersedes a stale status context" stale_gate 0
	set_live_evidence PASS sha-reviewed trusted true 2026-01-01T00:00:35Z
	assert_gate "typed live evidence predating late activity fails closed" stale_gate 1
	_PULSE_REVIEW_GATE_EVIDENCE=""
	assert_gate "missing status gate fails closed without live evidence" no_status_gate 1
	set_live_evidence PASS_ADVISORY
	_PULSE_REVIEW_GATE_EVIDENCE=$(jq -c 'del(.observed_at)' <<<"$_PULSE_REVIEW_GATE_EVIDENCE")
	assert_gate "live evidence without an observation timestamp fails closed" no_status_gate 1
	set_live_evidence PASS_ADVISORY
	assert_gate "trusted advisory evidence permits repositories without a status context" no_status_gate 0
	set_live_evidence PASS sha-other
	assert_gate "live gate evidence for another head fails closed" no_status_gate 1
	_PULSE_REVIEW_GATE_EVIDENCE=""
	assert_gate "new commit invalidates reviewed head" new_head 1
	assert_gate "bounded quiet period blocks recent check completion" recent 1
	return 0
}

main() {
	assert_infrastructure_rerun_unset_defaults_safe
	assert_infrastructure_rerun_unset_logfile_safe
	assert_actions_incident_suppresses_infrastructure_rerun
	assert_check_run_app_slug_survives_normalization
	assert_effective_rules_have_exact_rest_cost
	assert_configured_advisory_contexts_are_null_safe
	assert_malformed_advisory_contexts_fail_closed_once
	assert_snapshot_acquisition_failures_are_audited
	assert_snapshot_transient_retry_cases
	assert_gate "large paginated check payload streams without argument overflow" large_payload 0
	assert_large_bot_activity_streams
	assert_gate "large inline-comment payload streams through preflight" large_bot_activity 0
	assert_gate "terminal checks with explicit baseline advisory pass" happy_advisory 0
	if grep -q "IGNORED non-required baseline advisory failure 'Qlty Smell Threshold'" "$LOGFILE"; then
		printf 'PASS ignored advisory failure is audited\n'
	else
		printf 'FAIL ignored advisory failure is audited\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_gate "skipped rerun preserves successful baseline companion" skipped_companion_rerun 0
	: >"$EVIDENCE_LOG"
	assert_gate "active broad check blocks merge" pending 1
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$(grep -c '^guardrails.required_check_merge_preflight_mismatches=1$' "$EVIDENCE_LOG")" == "1" &&
	"$(grep -c '^guardrails.stale_positive_decisions=1$' "$EVIDENCE_LOG")" == "1" ]]; then
		printf 'PASS live preflight mismatch emits typed guardrail and stale-positive evidence\n'
	else
		printf 'FAIL live preflight mismatch did not emit both guardrail events\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	assert_gate "terminal failed required check blocks merge" required_fail 1
	assert_gate "external qlty failure is advisory when the regression gate passes" qlty_external_fail_with_companion 0
	assert_gate "external qlty failure blocks without a successful regression gate" qlty_external_fail_without_companion 1
	assert_gate "non-required never-terminal qlty usage status does not block merge" qlty_usage_pending 0
	assert_gate "required qlty usage status still blocks while pending" qlty_usage_pending_required 1
	assert_gate "non-required qlty check that ran out of minutes does not block merge" qlty_quota_exhausted 0
	assert_gate "required qlty check that ran out of minutes still blocks" qlty_quota_exhausted_required 1
	if [[ "$_PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON" == "[]" ]]; then
		printf 'PASS required quota-only status does not become code repair evidence\n'
	else
		printf 'FAIL required quota-only status became code repair evidence\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_gate "private qlty credits failure is advisory" qlty_credits_private 0
	assert_gate "organisation qlty credits failure is advisory" qlty_credits_org 0
	assert_gate "case variants of qlty credits failure are advisory" qlty_credits_case 0
	assert_gate "public personal qlty credits failure remains blocking" qlty_credits_public 1
	assert_gate "unknown qlty credit metadata remains blocking" qlty_credits_unknown 1
	assert_gate "malformed qlty credit metadata remains blocking" qlty_credits_malformed 1
	assert_gate "required qlty credits failure still blocks native merge" qlty_credits_required 1
	if [[ "$_PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON" == "[]" ]]; then
		printf 'PASS required credit-only status does not become code repair evidence\n'
	else
		printf 'FAIL required credit-only status became code repair evidence\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_gate "infrastructure-failed required check requests rerun and stays blocked" required_infra_fail 1
	if [[ "$RERUN_CALLS" -eq 1 ]] && grep -q "requested infrastructure rerun.*run=303" "$LOGFILE"; then
		printf 'PASS infrastructure-failed required check requests one audited rerun\n'
	else
		printf 'FAIL infrastructure-failed required check rerun was not requested once\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_gate "infrastructure rerun cooldown keeps merge blocked without duplicate write" required_infra_fail 1
	if [[ "$RERUN_CALLS" -eq 1 ]] && grep -q "infrastructure rerun cooldown active.*run=303" "$LOGFILE"; then
		printf 'PASS infrastructure rerun cooldown suppresses duplicate write\n'
	else
		printf 'FAIL infrastructure rerun cooldown did not suppress duplicate write\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_gate "unclassified non-required failure blocks merge" unclassified_fail 1
	if jq -e 'length == 1 and .[0].name == "CodeFactor" and .[0].bucket == "fail" and .[0].conclusion == "failure" and .[0].link == "https://github.com/owner/repo/runs/99"' \
		<<<"$_PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON" >/dev/null; then
		printf 'PASS terminal blocker evidence is exported for CI repair\n'
	else
		printf 'FAIL terminal blocker evidence is exported for CI repair: %s\n' "$_PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_gate "classified non-required infrastructure failure does not block merge" infra_fail 0
	if grep -q "IGNORED non-required infrastructure failure 'sync / Record ordered forge event'" "$LOGFILE"; then
		printf 'PASS ignored infrastructure failure is audited\n'
	else
		printf 'FAIL ignored infrastructure failure is audited\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_gate "later accepted snapshot resets prior blocker evidence" happy_advisory 0
	if [[ "$_PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON" == "[]" ]]; then
		printf 'PASS accepted snapshot clears prior blocker evidence\n'
	else
		printf 'FAIL accepted snapshot clears prior blocker evidence: %s\n' "$_PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_review_and_head_snapshot_cases
	assert_cancelled_workflow_recovery
	printf '\nTests run: %d\nTests failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
