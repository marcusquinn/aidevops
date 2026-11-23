#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Pulse wrapper self-check: expected function and module-guard inventory.
# Sourced by pulse-wrapper.sh before the dispatch gates (GH#38106).
# Dependencies: none at source time; _pulse_execute_self_check runs after all modules load.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PULSE_WRAPPER_SELF_CHECK_LOADED:-}" ]] && return 0
_PULSE_WRAPPER_SELF_CHECK_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# ---------------------------------------------------------------------------
# _pulse_self_check_expected_fns
#
# Populate the caller's _sc_expected_fns array for _pulse_execute_self_check.
# Split out (GH#37476) to keep the self-check under the 100-line function
# threshold. Assigns through bash dynamic scoping into the array the caller
# declared local — no subshell, so the caller sees the full list.
# ---------------------------------------------------------------------------
_pulse_self_check_expected_fns() {
	_sc_expected_fns=(
		resolve_dispatch_model_for_labels
		acquire_instance_lock
		_pulse_exit_cleanup
		check_dedup
		prefetch_state
		_extract_frontmatter_field
		check_external_contributor_pr
		run_cmd_with_timeout
		run_pulse
		cleanup_worktrees
		normalize_active_issue_assignments
		issue_has_required_approval
		run_weekly_complexity_scan
		get_repo_path_by_slug
		get_repo_role_by_slug
		dispatch_with_dedup
		_triage_content_hash
		normalize_count_output
		_ff_key
		build_dependency_graph_cache
		dependabot_alert_monitor_scan_repos
		dispatch_max
		pulse_dispatch_breakers_allow
		merge_ready_prs_all_repos
		rotate_pulse_log
		evaluate_routines
		evaluate_routines_locked
		_pulse_run_routines_while_busy
		main
		write_pulse_health_file
		calculate_max_workers
		dispatch_enrichment_workers
		dispatch_triage_reviews
		sync_todo_refs_for_repo
		sync_todo_refs_all_repos
		_pulse_execute_self_check
		_pulse_handle_self_check
		_pulse_setup_dry_run_mode
		_pulse_run_deterministic_pipeline
		_pulse_maybe_run_llm_supervisor
		_pulse_set_graphql_budget_priority
		_pulse_set_rest_core_budget_priority
		_pulse_stage_priority_class
		_pulse_run_budget_priority_stage
		_pulse_run_budget_priority_stage_with_timeout
		_pulse_run_optional_stage
		_pulse_run_optional_stage_with_timeout
		_carry_forward_pr_diff
		_dispatch_pr_fix_worker
		_close_conflicting_pr
		_interactive_pr_is_stale
		_interactive_pr_trigger_handover
		_dispatch_ci_fix_worker
		_dispatch_conflict_fix_worker
		run_canonical_maintenance
		dirty_pr_sweep_all_repos
		redirect_spam_sweep_all_repos
		_pulse_refresh_repo
		pulse_canonical_recover
		check_dispatch_backoff
	)
	return 0
}

# ---------------------------------------------------------------------------
# _pulse_self_check_expected_guards
#
# Populate the caller's _sc_expected_guards array for _pulse_execute_self_check
# (GH#37476 split; same dynamic-scoping contract as the function list above).
# ---------------------------------------------------------------------------
_pulse_self_check_expected_guards() {
	# Module include guards. Appended as each phase lands.
	# Phase 1 (t1966, GH#18364): 5 leaf modules
	# Phase 2 (t1967, GH#18367): 4 leaves with fan-in
	# Phase 3 (t1971, GH#18372): 4 operational plumbing clusters
	# Phase 4 (t1972, GH#18378): pr-gates + merge cycle co-extracted
	# Phase 5 (t1973, GH#18380): cleanup + issue-reconcile extracted
	# Phase 6 (t1974, GH#18382): simplification cluster (29 fns, largest)
	# Phase 7 (t1975, GH#18385): prefetch cluster (26 fns)
	# Phase 8 (t1976, GH#18387): triage cluster (10 fns)
	# Phase 9 (t1977, GH#18389): dispatch-core + dispatch-engine (26 fns)
	# Phase 10 (t1978, GH#18391): quality-debt + ancillary-dispatch (FINAL — clears 2K gate)
	# GH#19836: pulse-merge.sh further split into three modules (conflict + feedback extracted).
	# GH#20781: config block extracted to pulse-wrapper-config.sh.
	_sc_expected_guards=(
		_PULSE_BUDGET_PRIORITY_LOADED
		_PULSE_WRAPPER_CONFIG_LOADED
		_PULSE_WRAPPER_ADMISSION_LOADED
		_PULSE_MODEL_ROUTING_LOADED
		_PULSE_INSTANCE_LOCK_LOADED
		_PULSE_META_PARSE_LOADED
		_PULSE_REPO_META_LOADED
		_PULSE_ROUTINES_LOADED
		_PULSE_QUEUE_GOVERNOR_LOADED
		_PULSE_NMR_APPROVAL_LOADED
		_PULSE_DEP_GRAPH_LOADED
		_PULSE_FAST_FAIL_LOADED
		_PULSE_CAPACITY_LOADED
		_PULSE_LOGGING_LOADED
		_PULSE_WATCHDOG_LOADED
		_PULSE_CAPACITY_ALLOC_LOADED
		_PULSE_MERGE_LOADED
		_PULSE_MERGE_CONFLICT_LOADED
		_PULSE_MERGE_FEEDBACK_LOADED
		_PULSE_CLEANUP_LOADED
		_PULSE_ISSUE_RECONCILE_LOADED
		_PULSE_SIMPLIFICATION_LOADED
		_PULSE_SIMPLIFICATION_STATE_LOADED
		_PULSE_PREFETCH_LOADED
		_PULSE_PREFETCH_INFRA_LOADED
		_PULSE_PREFETCH_FETCH_LOADED
		_PULSE_PREFETCH_REPO_LOADED
		_PULSE_PREFETCH_ORCHESTRATION_LOADED
		_PULSE_PREFETCH_SECONDARY_LOADED
		_PULSE_PREFETCH_WORKERS_LOADED
		_PULSE_TRIAGE_LOADED
		_PULSE_DISPATCH_CORE_LOADED
		_PULSE_DISPATCH_ENGINE_LOADED
		_PULSE_QUALITY_DEBT_LOADED
		_PULSE_ANCILLARY_DISPATCH_LOADED
		_PULSE_CANONICAL_MAINTENANCE_LOADED
		_PULSE_DIRTY_PR_SWEEP_LOADED
		_PULSE_CANONICAL_RECOVERY_LOADED
	)
	return 0
}

# ---------------------------------------------------------------------------
# _pulse_execute_self_check
#
# Phase 0 (t1963, GH#18357): validate that all expected functions and module
# include-guards are present. Extracted from main() (GH#18689) to reduce
# cyclomatic complexity — the self-check body was ~100 lines inside main().
# GH#37476: the expected-symbol lists live in the two helpers above.
#
# Exit 0: all functions and guards present.
# Exit 1: at least one expected symbol is missing (names printed to stderr).
# ---------------------------------------------------------------------------
_pulse_execute_self_check() {
	local _sc_missing=()
	local _sc_fn
	local _sc_expected_fns=()
	_pulse_self_check_expected_fns
	for _sc_fn in "${_sc_expected_fns[@]}"; do
		if ! declare -F "$_sc_fn" >/dev/null 2>&1; then
			_sc_missing+=("$_sc_fn")
		fi
	done
	local _sc_expected_guards=()
	_pulse_self_check_expected_guards
	local _sc_guard="" _sc_val=""
	# The `${array[@]+"${array[@]}"}` pattern is safe under `set -u`
	# when the array is empty — required in Phase 0 where no module
	# guards exist yet.
	# GH#18614: all guard names in _sc_expected_guards are simple scalar
	# variables (e.g. _PULSE_MODEL_ROUTING_LOADED="1"). The indirect
	# expansion ${!_sc_guard:-} is therefore safe — it will never silently
	# read only the first element of an array. Never add array names to
	# _sc_expected_guards; use a dedicated scalar for each module.
	for _sc_guard in ${_sc_expected_guards[@]+"${_sc_expected_guards[@]}"}; do
		_sc_val="${!_sc_guard:-}"
		if [[ -z "$_sc_val" ]]; then
			_sc_missing+=("${_sc_guard} (module not loaded)")
		fi
	done
	if [[ ${#_sc_missing[@]} -eq 0 ]]; then
		printf 'self-check: ok (%d canonical functions defined, %d module guards verified)\n' \
			"${#_sc_expected_fns[@]}" "${#_sc_expected_guards[@]}"
		return 0
	fi
	printf 'self-check: FAIL: %d missing:\n' "${#_sc_missing[@]}" >&2
	local _sc_item
	for _sc_item in "${_sc_missing[@]}"; do
		printf '  - %s\n' "$_sc_item" >&2
	done
	return 1
}
