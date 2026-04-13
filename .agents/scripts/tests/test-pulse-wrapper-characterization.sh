#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Characterization tests for pulse-wrapper.sh (t1963 — Phase 0 of t1962).
#
# Purpose: lock in the *observable* surface of pulse-wrapper.sh so that the
# phased decomposition (todo/plans/pulse-wrapper-decomposition.md) can extract
# functions into sibling pulse-<cluster>.sh modules without regressing
# behaviour.
#
# Strategy:
#   1. Source pulse-wrapper.sh in a sandboxed $HOME. The existing
#      `_pulse_is_sourced` guard at the bottom of the wrapper (L13786)
#      prevents `main()` from running when the file is sourced.
#   2. Assert every currently-defined function (201 entries) is present
#      via `declare -F`. Any extraction PR that drops a function name
#      without re-sourcing it from a new module fails this check.
#   3. Exercise a focused set of PURE / deterministic functions with
#      known inputs and lock their outputs. These catch semantic drift
#      that `declare -F` cannot detect.
#
# Hotspots chosen (from plan §3.2) — only pure-ish functions are tested;
# functions that require `gh`, `git`, or live state are tested via the
# function-existence check only:
#
#   _ff_key                         — pure string join
#   normalize_count_output          — pure text normalization
#   _match_terminal_blocker_pattern — pure regex matching
#   _extract_frontmatter_field      — reads a tmp file (YAML frontmatter)
#   _extract_milestone_summary      — reads a tmp file (mission markdown)
#   _triage_content_hash            — pure (shasum)
#
# Non-goal: testing behaviour under real gh/git calls. Those are integration
# tests and live in the other test-pulse-wrapper-*.sh files. This harness is
# a fast safety net for the extraction refactor.

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_YELLOW='\033[0;33m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""
# NOTE: deliberately NOT named SCRIPT_DIR. pulse-wrapper.sh sets SCRIPT_DIR
# itself at L96 from its own BASH_SOURCE, and if we declared SCRIPT_DIR
# readonly here the wrapper's assignment would fail, triggering its
# `|| return` fallback and aborting the source before any functions are
# defined. Use PULSE_SCRIPTS_DIR to point to the tests-adjacent scripts
# directory without shadowing the wrapper's own variable.
PULSE_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly PULSE_SCRIPTS_DIR

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

setup_sandbox() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p \
		"${HOME}/.aidevops/logs" \
		"${HOME}/.aidevops/.agent-workspace/supervisor" \
		"${HOME}/.aidevops/.agent-workspace/tmp/triage-cache" \
		"${HOME}/.config/aidevops"

	# Disable jitter so tests are not delayed by up to 30 s.
	export PULSE_JITTER_MAX=0
	return 0
}

teardown_sandbox() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

#######################################
# The authoritative 201-function list for pulse-wrapper.sh as of the Phase 0
# safety net. Regenerate with:
#   awk '/^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ {gsub(/\(\)/,""); print "\t\"" $1 "\""}' \
#       .agents/scripts/pulse-wrapper.sh
# Any extraction PR that moves a function into pulse-<cluster>.sh must ensure
# the new module is sourced by pulse-wrapper.sh BEFORE this test is run, so
# `declare -F` still finds the function.
#
# When a function is legitimately removed (not just moved), this list must be
# updated in the same PR. Reviewers: verify the removal is intentional.
#######################################
readonly -a EXPECTED_FUNCTIONS=(
	"resolve_dispatch_model_for_labels"
	"acquire_instance_lock"
	"release_instance_lock"
	"_handle_setup_sentinel"
	"_handle_running_pulse_pid"
	"check_dedup"
	"_prefetch_cache_get"
	"_prefetch_cache_set"
	"_prefetch_needs_full_sweep"
	"_prefetch_prs_try_delta"
	"_prefetch_prs_enrich_checks"
	"_prefetch_prs_format_output"
	"_prefetch_repo_prs"
	"_prefetch_repo_daily_cap"
	"_prefetch_issues_try_delta"
	"_prefetch_repo_issues"
	"_prefetch_single_repo"
	"_wait_parallel_pids"
	"_assemble_state_file"
	"_run_prefetch_step"
	"_append_prefetch_sub_helpers"
	"check_repo_pulse_schedule"
	"prefetch_state"
	"prefetch_missions"
	"_extract_frontmatter_field"
	"_extract_milestone_summary"
	"check_external_contributor_pr"
	"_external_pr_has_linked_issue"
	"_external_pr_linked_issue_crypto_approved"
	"check_permission_failure_pr"
	"approve_collaborator_pr"
	"check_pr_modifies_workflows"
	"check_gh_workflow_scope"
	"check_workflow_merge_guard"
	"prefetch_active_workers"
	"prefetch_ci_failures"
	"_append_priority_allocations"
	"_check_repo_hygiene"
	"_scan_pr_salvage"
	"prefetch_hygiene"
	"guard_child_processes"
	"run_cmd_with_timeout"
	"run_stage_with_timeout"
	"_watchdog_check_progress"
	"_watchdog_check_idle"
	"_check_watchdog_conditions"
	"_run_pulse_watchdog"
	"run_pulse"
	"cleanup_worktrees"
	"cleanup_stashes"
	"check_session_gate"
	"prefetch_contribution_watch"
	"prefetch_foss_scan"
	"prefetch_triage_review_status"
	"prefetch_needs_info_replies"
	"normalize_active_issue_assignments"
	"close_issues_with_merged_prs"
	"reconcile_stale_done_issues"
	"_ever_nmr_cache_key"
	"_ever_nmr_cache_load"
	"_ever_nmr_cache_with_lock"
	"_ever_nmr_cache_get"
	"_ever_nmr_cache_set_locked"
	"_ever_nmr_cache_set"
	"issue_was_ever_nmr"
	"issue_has_required_approval"
	"_nmr_applied_by_maintainer"
	"auto_approve_maintainer_issues"
	"_complexity_scan_check_interval"
	"_coderabbit_review_check_interval"
	"run_daily_codebase_review"
	"_run_post_merge_review_scanner"
	"_complexity_scan_tree_hash"
	"_complexity_scan_tree_changed"
	"_complexity_llm_sweep_due"
	"_complexity_run_llm_sweep"
	"_complexity_scan_find_repo"
	"_complexity_scan_collect_violations"
	"_complexity_scan_should_open_md_issue"
	"_complexity_scan_collect_md_violations"
	"_complexity_scan_extract_md_topic_label"
	"_simplification_state_check"
	"_simplification_state_record"
	"_simplification_state_refresh"
	"_simplification_state_prune"
	"_simplification_state_push"
	"_create_requeue_issue"
	"_simplification_state_backfill_closed"
	"_complexity_scan_has_existing_issue"
	"_complexity_scan_close_duplicate_issues_by_title"
	"_complexity_scan_build_md_issue_body"
	"_complexity_scan_check_open_cap"
	"_complexity_scan_process_single_md_file"
	"_complexity_scan_create_md_issues"
	"_complexity_scan_create_issues"
	"run_simplification_dedup_cleanup"
	"_check_ci_nesting_threshold_proximity"
	"run_weekly_complexity_scan"
	"prefetch_gh_failure_notifications"
	"reap_zombie_workers"
	"get_repo_path_by_slug"
	"get_repo_owner_by_slug"
	"get_repo_maintainer_by_slug"
	"get_repo_priority_by_slug"
	"list_dispatchable_issue_candidates_json"
	"list_dispatchable_issue_candidates"
	"has_worker_for_repo_issue"
	"check_dispatch_dedup"
	"lock_issue_for_worker"
	"_lock_linked_prs"
	"unlock_issue_after_worker"
	"_unlock_linked_prs"
	"_triage_content_hash"
	"_triage_is_cached"
	"_triage_update_cache"
	"_triage_increment_failure"
	"_triage_awaiting_contributor_reply"
	"_count_impl_commits"
	"_is_task_committed_to_main"
	"_gh_idempotent_comment"
	"_issue_needs_consolidation"
	"_reevaluate_consolidation_labels"
	"_reevaluate_simplification_labels"
	"_consolidation_child_exists"
	"_consolidation_substantive_comments"
	"_compose_consolidation_child_body"
	"_dispatch_issue_consolidation"
	"_backfill_stale_consolidation_labels"
	"_issue_targets_large_files"
	"dispatch_with_dedup"
	"_match_terminal_blocker_pattern"
	"_apply_terminal_blocker"
	"check_terminal_blockers"
	"_fetch_queue_metrics"
	"_load_queue_metrics_history"
	"_compute_queue_deltas"
	"_compute_queue_mode"
	"_emit_queue_governor_state"
	"_compute_queue_governor_guidance"
	"append_adaptive_queue_governor"
	"get_max_workers_target"
	"count_runnable_candidates"
	"count_queued_without_worker"
	"pulse_count_debug_log"
	"normalize_count_output"
	"recover_failed_launch_state"
	"_ff_key"
	"_ff_load"
	"_ff_query_pool_retry_seconds"
	"_ff_with_lock"
	"_ff_save"
	"fast_fail_record"
	"_fast_fail_record_locked"
	"fast_fail_reset"
	"_fast_fail_reset_locked"
	"fast_fail_is_skipped"
	"fast_fail_prune_expired"
	"_fast_fail_prune_expired_locked"
	"build_dependency_graph_cache"
	"refresh_blocked_status_from_graph"
	"is_blocked_by_unresolved"
	"check_worker_launch"
	"build_ranked_dispatch_candidates_json"
	"dispatch_deterministic_fill_floor"
	"merge_ready_prs_all_repos"
	"_merge_ready_prs_for_repo"
	"_is_collaborator_author"
	"_extract_linked_issue"
	"_extract_merge_summary"
	"_close_conflicting_pr"
	"_should_run_llm_supervisor"
	"_update_backlog_snapshot"
	"_adaptive_launch_settle_wait"
	"apply_deterministic_fill_floor"
	"enforce_utilization_invariants"
	"run_underfill_worker_recycler"
	"maybe_refill_underfilled_pool_during_active_pulse"
	"_run_preflight_stages"
	"_compute_initial_underfill"
	"_run_early_exit_recycle_loop"
	"rotate_pulse_log"
	"append_cycle_index"
	"_routine_last_run_epoch"
	"_routine_update_state"
	"_routine_execute"
	"evaluate_routines"
	"main"
	"write_pulse_health_file"
	"cleanup_stalled_workers"
	"cleanup_orphans"
	"cleanup_stale_opencode"
	"apply_peak_hours_cap"
	"calculate_max_workers"
	"calculate_priority_allocations"
	"count_debt_workers"
	"check_repo_worker_cap"
	"create_quality_debt_worktree"
	"close_stale_quality_debt_prs"
	"dispatch_enrichment_workers"
	"_ff_mark_enrichment_done"
	"dispatch_triage_reviews"
	"relabel_needs_info_replies"
	"dispatch_routine_comment_responses"
	"dispatch_foss_workers"
	"sync_todo_refs_for_repo"
	"_pulse_is_sourced"
)

#######################################
# Assertion helpers
#######################################

assert_equals() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		print_result "$test_name" 0
		return 0
	fi
	print_result "$test_name" 1 "expected='${expected}' actual='${actual}'"
	return 0
}

assert_function_defined() {
	local fn_name="$1"
	declare -F "$fn_name" >/dev/null
}

#######################################
# Test 1: source pulse-wrapper.sh in sandbox, assert every expected function
# is defined via `declare -F`. This is the core safety net for extraction.
#######################################
test_source_and_function_existence() {
	setup_sandbox

	# Source the wrapper. The _pulse_is_sourced guard at L13786 prevents
	# main() from running. Suppress config-helper noise that appears only
	# when $HOME is sandboxed and the configs dir is absent.
	# shellcheck source=/dev/null
	source "${PULSE_SCRIPTS_DIR}/pulse-wrapper.sh" 2>/dev/null

	local missing=()
	local fn
	for fn in "${EXPECTED_FUNCTIONS[@]}"; do
		if ! assert_function_defined "$fn"; then
			missing+=("$fn")
		fi
	done

	if [[ ${#missing[@]} -eq 0 ]]; then
		print_result "all ${#EXPECTED_FUNCTIONS[@]} pulse-wrapper functions defined after sourcing" 0
	else
		local msg="${#missing[@]} missing: ${missing[*]:0:5}"
		if [[ ${#missing[@]} -gt 5 ]]; then
			msg="${msg} ..."
		fi
		print_result "all ${#EXPECTED_FUNCTIONS[@]} pulse-wrapper functions defined after sourcing" 1 "$msg"
	fi

	return 0
}

#######################################
# Test 2: _ff_key — pure string join for fast-fail state keys.
# Current shape: "owner/repo/123" (slug + / + issue number).
# Lock the format so extracted pulse-fast-fail.sh cannot silently change it
# and invalidate persisted state files.
#######################################
test_ff_key_format() {
	local actual
	actual=$(_ff_key "123" "marcusquinn/aidevops")
	assert_equals "_ff_key simple slug" "marcusquinn/aidevops/123" "$actual"

	actual=$(_ff_key "4567" "some-org/my-cool-repo")
	assert_equals "_ff_key hyphenated slug" "some-org/my-cool-repo/4567" "$actual"
	return 0
}

#######################################
# Test 3: normalize_count_output — pure: extract last line that is
# whitespace-padded digits, return "0" if none match.
#######################################
test_normalize_count_output() {
	assert_equals "normalize_count_output simple number" \
		"42" "$(normalize_count_output "42")"

	assert_equals "normalize_count_output trailing newline" \
		"42" "$(normalize_count_output "42
")"

	assert_equals "normalize_count_output padded" \
		"42" "$(normalize_count_output "  42  ")"

	assert_equals "normalize_count_output multiple lines picks last numeric" \
		"7" "$(normalize_count_output "debug: running
info: done
7")"

	assert_equals "normalize_count_output noise returns 0" \
		"0" "$(normalize_count_output "not-a-number")"

	assert_equals "normalize_count_output empty returns 0" \
		"0" "$(normalize_count_output "")"
	return 0
}

#######################################
# Test 4: _match_terminal_blocker_pattern — pure regex scan for terminal
# blocker reasons in concatenated issue/comment bodies. Returns 0 when a
# pattern matches (printing reason + user action on two lines), 1 when no
# pattern matches.
#######################################
test_match_terminal_blocker_pattern() {
	# Pattern 1: workflow scope
	local output rc
	output=$(_match_terminal_blocker_pattern "error: refusing to allow an OAuth App to create or update workflow" 2>/dev/null) && rc=0 || rc=$?
	if [[ "$rc" -eq 0 ]] && printf '%s' "$output" | grep -q "workflow.*scope"; then
		print_result "_match_terminal_blocker_pattern workflow scope" 0
	else
		print_result "_match_terminal_blocker_pattern workflow scope" 1 "rc=$rc output='${output}'"
	fi

	# Pattern 3: ACTION REQUIRED supervisor marker
	output=$(_match_terminal_blocker_pattern "ACTION REQUIRED: user must refresh token" 2>/dev/null) && rc=0 || rc=$?
	if [[ "$rc" -eq 0 ]] && printf '%s' "$output" | grep -q "ACTION REQUIRED\|supervisor comment"; then
		print_result "_match_terminal_blocker_pattern ACTION REQUIRED" 0
	else
		print_result "_match_terminal_blocker_pattern ACTION REQUIRED" 1 "rc=$rc output='${output}'"
	fi

	# No match — should return 1
	output=$(_match_terminal_blocker_pattern "nothing interesting here" 2>/dev/null) && rc=0 || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		print_result "_match_terminal_blocker_pattern no match returns 1" 0
	else
		print_result "_match_terminal_blocker_pattern no match returns 1" 1 "rc=$rc output='${output}'"
	fi
	return 0
}

#######################################
# Test 5: _extract_frontmatter_field — reads a markdown file, extracts a
# named field from YAML frontmatter. Used by prefetch_missions.
#######################################
test_extract_frontmatter_field() {
	local tmpfile="${TEST_ROOT}/front.md"
	cat >"$tmpfile" <<'MDEOF'
---
title: "Example Mission"
mode: subagent # inline comment
status: active
---

Body goes here.
MDEOF

	assert_equals "_extract_frontmatter_field title" \
		"Example Mission" "$(_extract_frontmatter_field "$tmpfile" title)"
	assert_equals "_extract_frontmatter_field mode (strips inline comment)" \
		"subagent" "$(_extract_frontmatter_field "$tmpfile" mode)"
	assert_equals "_extract_frontmatter_field status" \
		"active" "$(_extract_frontmatter_field "$tmpfile" status)"
	assert_equals "_extract_frontmatter_field missing field" \
		"" "$(_extract_frontmatter_field "$tmpfile" nonexistent)"
	return 0
}

#######################################
# Test 6: _extract_milestone_summary — reads a mission.md-style file and
# emits a compact summary of milestones and their feature rows.
#
# Known current behaviour (locked in by this test — extraction must preserve):
#   - Milestone headers `### Milestone N: Name` + `**Status:** value` are captured
#   - Milestone status value may contain hyphens (e.g. `in-progress`)
#   - Feature rows are captured ONLY when the status column matches `[a-z]+`
#     (i.e. plain lowercase letters, no hyphens, no digits, no whitespace)
#
# The `[a-z]+` restriction on feature status is a real limitation of the
# current regex (L1906). This test deliberately includes both a matching and
# a non-matching feature row to lock in the current behaviour. If a future
# simplification pass wants to widen the status regex, it will have to update
# this test in the same PR.
#######################################
test_extract_milestone_summary() {
	local tmpfile="${TEST_ROOT}/mission.md"
	cat >"$tmpfile" <<'MDEOF'
# Mission

### Milestone 1: Discovery

**Status:** complete

| 1.1 | Research competitors | t100 | done | — |
| 1.2 | Interview users      | t101 | done | — |

### Milestone 2: Build

**Status:** in-progress

| 2.1 | API spec             | t200 | inprogress  | — |
| 2.2 | Ship beta            | t201 | in-progress | — |
MDEOF

	local output
	output=$(_extract_milestone_summary "$tmpfile")

	# Lock: both milestone headers and statuses captured
	if printf '%s' "$output" | grep -q "Milestone 1: Discovery" &&
		printf '%s' "$output" | grep -q "Milestone 2: Build" &&
		printf '%s' "$output" | grep -q "complete" &&
		printf '%s' "$output" | grep -q "in-progress"; then
		print_result "_extract_milestone_summary captures milestone headers + hyphenated status" 0
	else
		print_result "_extract_milestone_summary captures milestone headers + hyphenated status" 1 "output=${output}"
	fi

	# Lock: feature rows with plain-lowercase status ARE captured
	if printf '%s' "$output" | grep -q "F1.1: Research competitors (t100)" &&
		printf '%s' "$output" | grep -q "F1.2: Interview users (t101)" &&
		printf '%s' "$output" | grep -q "F2.1: API spec (t200)"; then
		print_result "_extract_milestone_summary captures feature rows with [a-z]+ status" 0
	else
		print_result "_extract_milestone_summary captures feature rows with [a-z]+ status" 1 "output=${output}"
	fi

	# Lock: feature rows with hyphenated status are NOT captured (current
	# regex limitation). If extraction accidentally widens the regex, this
	# test catches it and forces an explicit decision.
	if ! printf '%s' "$output" | grep -q "F2.2:"; then
		print_result "_extract_milestone_summary skips feature rows with hyphenated status (known limit)" 0
	else
		print_result "_extract_milestone_summary skips feature rows with hyphenated status (known limit)" 1 \
			"unexpected F2.2 capture: ${output}"
	fi
	return 0
}

#######################################
# Test 7: _triage_content_hash — computes a stable SHA-256 of an issue body
# plus human-comment subset. Extraction of the triage cluster must preserve
# the filter rules (exclude github-actions bot; exclude "## *Review*" bot
# reviews) or cached hashes become invalid and triage loops run every pulse.
#######################################
test_triage_content_hash() {
	local body="Issue body text"
	local comments_json='[
      {"author":"alice","body":"A human comment"},
      {"author":"github-actions[bot]","body":"Automated comment"},
      {"author":"bob","body":"## Automated Review\n- finding"}
    ]'

	local hash1 hash2
	hash1=$(_triage_content_hash "123" "owner/repo" "$body" "$comments_json")

	# Same inputs -> identical hash
	hash2=$(_triage_content_hash "123" "owner/repo" "$body" "$comments_json")
	assert_equals "_triage_content_hash deterministic" "$hash1" "$hash2"

	# Bot-only comments should not contribute -> same hash
	local bot_only_json='[
      {"author":"github-actions[bot]","body":"Different bot comment"},
      {"author":"alice","body":"A human comment"},
      {"author":"bob","body":"## Automated Review\n- different finding"}
    ]'
	hash2=$(_triage_content_hash "123" "owner/repo" "$body" "$bot_only_json")
	assert_equals "_triage_content_hash ignores bot comments" "$hash1" "$hash2"

	# Changing the body must change the hash
	hash2=$(_triage_content_hash "123" "owner/repo" "DIFFERENT BODY" "$comments_json")
	if [[ "$hash1" != "$hash2" ]]; then
		print_result "_triage_content_hash sensitive to body" 0
	else
		print_result "_triage_content_hash sensitive to body" 1 "both hashes=${hash1}"
	fi

	# Hash must be 64 hex chars (SHA-256)
	if [[ "$hash1" =~ ^[0-9a-f]{64}$ ]]; then
		print_result "_triage_content_hash format (64 hex)" 0
	else
		print_result "_triage_content_hash format (64 hex)" 1 "hash=${hash1}"
	fi
	return 0
}

#######################################
# Test 8: structural integrity — sourcing the wrapper must be idempotent.
# Decomposition will add `source pulse-<cluster>.sh` lines; each module has
# an include guard, so a second source must not error or redefine anything
# destructively.
#######################################
test_sourcing_idempotency() {
	# We already sourced in test 1 — source again and verify no errors and
	# function count is stable.
	local before_count
	before_count=$(declare -F | wc -l | tr -d ' ')

	local rc=0
	# shellcheck source=/dev/null
	source "${PULSE_SCRIPTS_DIR}/pulse-wrapper.sh" 2>/dev/null || rc=$?

	local after_count
	after_count=$(declare -F | wc -l | tr -d ' ')

	if [[ "$rc" -eq 0 ]]; then
		print_result "sourcing pulse-wrapper.sh is idempotent (exit 0)" 0
	else
		print_result "sourcing pulse-wrapper.sh is idempotent (exit 0)" 1 "rc=$rc"
	fi

	assert_equals "function count unchanged after re-source" "$before_count" "$after_count"
	return 0
}

#######################################
# Test 9: _pulse_is_sourced returns success when sourced from bash.
# Every test above relies on this guard at L13786 preventing main() from
# running. Verify it works as documented.
#######################################
test_pulse_is_sourced_guard() {
	# When invoked from bash via source, BASH_SOURCE[0] is set to the
	# wrapper path and $0 is the interpreter (bash / test harness).
	# We cannot call _pulse_is_sourced directly and expect a meaningful
	# result because BASH_SOURCE[0] at call time is *this test file*.
	# Instead, verify the function exists and prove the behavioural
	# outcome: after sourcing, main() was NOT invoked (no PIDFILE).
	if [[ ! -f "${HOME}/.aidevops/logs/pulse.pid" ]]; then
		print_result "_pulse_is_sourced prevented main() from running" 0
	else
		print_result "_pulse_is_sourced prevented main() from running" 1 \
			"unexpected PIDFILE at ${HOME}/.aidevops/logs/pulse.pid"
	fi
	return 0
}

#######################################
# Main
#######################################
main() {
	printf '%b==> pulse-wrapper.sh characterization tests%b\n' "$TEST_YELLOW" "$TEST_RESET"
	printf '    PULSE_SCRIPTS_DIR=%s\n' "$PULSE_SCRIPTS_DIR"

	test_source_and_function_existence
	test_ff_key_format
	test_normalize_count_output
	test_match_terminal_blocker_pattern
	test_extract_frontmatter_field
	test_extract_milestone_summary
	test_triage_content_hash
	test_sourcing_idempotency
	test_pulse_is_sourced_guard

	teardown_sandbox

	printf '\n'
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		printf '%bAll %d tests passed%b\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
		return 0
	fi
	printf '%b%d of %d tests failed%b\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	return 1
}

main "$@"
