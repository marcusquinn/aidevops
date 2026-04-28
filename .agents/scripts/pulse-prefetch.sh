#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-prefetch.sh — Pre-flight state gathering — PR/issue cache + delta fetch, per-repo prefetch, parallel pid wait, FOSS scan, triage review status, needs-info replies, CI failures, hygiene checks, contribution watch, active workers, missions.
#
# Extracted from pulse-wrapper.sh in Phase 7 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module covers the entire pre-flight state-gathering pipeline that
# runs at the start of each pulse cycle before dispatch logic fires.
# Heavy use of parallel subshells; cache-based delta fetches; external
# integrations (gh API, git, foss scan, contribution watch).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* / PREFETCH_* / FOSS_* configuration
# constants in the bootstrap section.
#
# Functions in this module (in source order):
#   Sub-libraries (pulse-prefetch-infra.sh):
#     - _pulse_gh_err_is_rate_limit
#     - _pulse_verify_rate_limit_live
#     - _pulse_mark_rate_limited
#     - _prefetch_cached_label_count_is_zero
#     - _load_pulse_sweep_budget_config
#     - _compute_repo_state_fingerprint
#     - _verify_repo_state_unchanged
#     - prefetch_hygiene_anomalies
#     - _prefetch_detect_cache_hit
#     - _prefetch_cache_get
#     - _prefetch_cache_set
#     - _prefetch_needs_full_sweep
#   Sub-libraries (pulse-prefetch-fetch.sh):
#     - _prefetch_prs_try_delta
#     - _prefetch_prs_enrich_checks
#     - _prefetch_prs_format_output
#     - _prefetch_repo_prs
#     - _prefetch_repo_daily_cap
#     - _prefetch_issues_try_delta
#     - _prefetch_single_repo_idle_skip
#     - _prefetch_single_repo
#     - _wait_parallel_pids
#     - _assemble_state_file
#     - _run_prefetch_step
#     - _append_prefetch_sub_helpers
#     - check_repo_pulse_schedule
#   Sub-libraries (pulse-prefetch-secondary.sh):
#     - prefetch_active_workers
#     - prefetch_ci_failures
#     - prefetch_hygiene
#     - prefetch_contribution_watch
#     - _prefetch_ni_fetch_issues
#     - _prefetch_ni_get_label_date
#     - _prefetch_ni_check_author_replied
#     - prefetch_needs_info_replies
#     - prefetch_gh_failure_notifications
#   Orchestrator (this file — functions >100 lines kept for identity-key preservation):
#     - _prefetch_repo_issues        (112 lines)
#     - prefetch_state               (109 lines)
#     - prefetch_missions            (103 lines)
#     - prefetch_foss_scan           (108 lines)
#     - prefetch_triage_review_status (110 lines)
#
# Split from monolithic file in GH#19964 (t2398). Sub-libraries sourced below.
# Pure move from pulse-wrapper.sh. Byte-identical function bodies.
# Simplification deferred to Phase 12.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_PREFETCH_LOADED:-}" ]] && return 0
_PULSE_PREFETCH_LOADED=1

# SCRIPT_DIR fallback — pulse-wrapper.sh sets this before sourcing us, but
# guard against test harnesses that source this file directly.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_pp_path="${BASH_SOURCE[0]%/*}"
	[[ "$_pp_path" == "${BASH_SOURCE[0]}" ]] && _pp_path="."
	SCRIPT_DIR="$(cd "$_pp_path" && pwd)"
	unset _pp_path
fi

# Source sub-libraries in dependency order.
# shellcheck source=./pulse-prefetch-infra.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-prefetch-infra.sh"

# shellcheck source=./pulse-prefetch-fetch.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-prefetch-fetch.sh"

# shellcheck source=./pulse-prefetch-secondary.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-prefetch-secondary.sh"

# =============================================================================
# Functions kept in this orchestrator file for function-complexity identity-key
# preservation (reference/large-file-split.md §3). Moving >100-line functions
# to a new file re-registers them as new violations in the complexity scanner.
# These five functions exceed the 100-line threshold — they stay here.
# =============================================================================

#######################################
# Print the Open Issues sections for a repo (GH#5627, GH#15286)
#
# Fetches open issues, filters managed labels, splits into dispatchable
# vs quality-sweep-tracked, and emits markdown sections to stdout.
# Called from _prefetch_single_repo inside a subshell redirect.
#
# Delta prefetch (GH#15286): on non-full-sweep cycles, fetches only issues
# updated since last_prefetch and merges into the cached full list.
# Falls back to full fetch if delta fails or cache is missing.
# Sets PREFETCH_UPDATED_ISSUES for cache update by caller.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - cache entry JSON (from _prefetch_cache_get)
#   $3 - "full" for full sweep, "delta" for delta fetch
#######################################
_prefetch_repo_issues() {
	local slug="$1"
	local cache_entry="${2:-}"
	[[ -n "$cache_entry" ]] || cache_entry="{}"
	local sweep_mode="${3:-full}"

	# Issues (include assignees for dispatch dedup)
	# Filter out supervisor/contributor/persistent/quality-review issues —
	# these are managed by pulse-wrapper.sh and must not be touched by the
	# pulse agent. Exposing them in pre-fetched state causes the LLM to
	# close them as "stale", creating churn (wrapper recreates on next cycle).
	# GH#15060: Log errors instead of silently swallowing them with 2>/dev/null.
	# GH#15286: Delta mode — fetch only recently-updated issues, merge into cache.
	local issue_json="" issue_err
	issue_err=$(mktemp)

	# GH#19963 L3: Check batch prefetch cache before per-repo API calls.
	# Execution order: idle skip (L2, handled by caller) → batch cache (L3) → delta/full (L4/L5)
	local _batch_helper="${SCRIPT_DIR}/pulse-batch-prefetch-helper.sh"
	local _used_batch_cache=false
	if [[ "${PULSE_BATCH_PREFETCH_ENABLED:-1}" == "1" && -x "$_batch_helper" ]]; then
		local _batch_issues
		_batch_issues=$("$_batch_helper" read-cache --kind issues --slug "$slug" 2>/dev/null) || _batch_issues=""
		if [[ -n "$_batch_issues" && "$_batch_issues" != "[]" && "$_batch_issues" != "null" ]]; then
			issue_json="$_batch_issues"
			_used_batch_cache=true
			echo "[pulse-wrapper] _prefetch_repo_issues: using batch cache for ${slug}" >>"$LOGFILE"
			_PULSE_HEALTH_BATCH_CACHE_HITS=$((_PULSE_HEALTH_BATCH_CACHE_HITS + 1))
		fi
	fi

	if [[ "$_used_batch_cache" == "false" ]]; then
		# Delta fetch: try merging recent changes into cache (GH#15286)
		PREFETCH_ISSUE_SWEEP_MODE="$sweep_mode"
		PREFETCH_ISSUE_RESULT=""
		if [[ "$sweep_mode" == "delta" ]]; then
			_prefetch_issues_try_delta "$slug" "$cache_entry" "$issue_err"
			sweep_mode="$PREFETCH_ISSUE_SWEEP_MODE"
			issue_json="$PREFETCH_ISSUE_RESULT"
		fi

		# Full fetch: either requested directly or delta fell back
		if [[ "$sweep_mode" == "full" ]]; then
		issue_json=$(gh_issue_list --repo "$slug" --state open \
			--json number,title,labels,updatedAt,assignees,body \
			--limit "$PULSE_PREFETCH_ISSUE_LIMIT" 2>"$issue_err") || issue_json=""

			if [[ -z "$issue_json" || "$issue_json" == "null" ]]; then
				local issue_err_msg
				issue_err_msg=$(cat "$issue_err" 2>/dev/null || echo "unknown error")
				# GH#18979 (t2097): detect rate-limit exhaustion
				if _pulse_gh_err_is_rate_limit "$issue_err"; then
					_pulse_mark_rate_limited "_prefetch_repo_issues:${slug}"
				fi
				echo "[pulse-wrapper] _prefetch_repo_issues: gh_issue_list FAILED for ${slug}: ${issue_err_msg}" >>"$LOGFILE"
				issue_json="[]"
			fi
		fi
	fi
	rm -f "$issue_err"

	# Export updated issue list for cache update by caller (Bash 3.2: no namerefs)
	PREFETCH_UPDATED_ISSUES="$issue_json"

	# Remove issues with non-dispatchable labels (GH#20048: shared helper)
	local filtered_json
	filtered_json=$(echo "$issue_json" | _filter_non_task_issues)

	# GH#10308: Split issues into dispatchable vs quality-sweep-tracked.
	local dispatchable_json sweep_tracked_json
	dispatchable_json=$(echo "$filtered_json" | jq '[.[] | select(.labels | map(.name) | (index("source:quality-sweep") or index("source:review-feedback")) | not)]')
	sweep_tracked_json=$(echo "$filtered_json" | jq '[.[] | select(.labels | map(.name) | (index("source:quality-sweep") or index("source:review-feedback")))]')

	local dispatchable_count sweep_tracked_count
	dispatchable_count=$(echo "$dispatchable_json" | jq 'length')
	sweep_tracked_count=$(echo "$sweep_tracked_json" | jq 'length')

	if [[ "$dispatchable_count" -gt 0 ]]; then
		echo "### Open Issues ($dispatchable_count)"
		echo "$dispatchable_json" | jq -r '.[] | "- Issue #\(.number): \(.title) [labels: \(if (.labels | length) == 0 then "none" else (.labels | map(.name) | join(", ")) end)] [assignees: \(if (.assignees | length) == 0 then "none" else (.assignees | map(.login) | join(", ")) end)] [updated: \(.updatedAt)]"'
	else
		echo "### Open Issues (0)"
		echo "- None"
	fi

	echo ""

	# GH#10308: Show quality-sweep-tracked issues so the LLM knows what's
	# already filed and avoids creating duplicates from sweep findings.
	if [[ "$sweep_tracked_count" -gt 0 ]]; then
		echo "### Already Tracked by Quality Sweep ($sweep_tracked_count)"
		echo "_These issues were auto-created by the quality sweep or review feedback pipeline._"
		echo "_DO NOT create new issues for findings already covered below. Dispatch these as normal quality-debt/file-size-debt/function-complexity-debt work._"
		echo "$sweep_tracked_json" | jq -r '.[] | "- Issue #\(.number): \(.title) [labels: \(if (.labels | length) == 0 then "none" else (.labels | map(.name) | join(", ")) end)] [assignees: \(if (.assignees | length) == 0 then "none" else (.assignees | map(.login) | join(", ")) end)]"'
		echo ""
	fi
	return 0
}

#######################################
# GH#19963: Run batch prefetch via org-level gh search (L3 cache layer).
# Run BEFORE parallel per-repo fetches. Individual repos consult the
# batch cache and skip their own gh calls on cache hit.
# Called from prefetch_state.
#######################################
_prefetch_batch_refresh() {
	local _batch_helper="${SCRIPT_DIR}/pulse-batch-prefetch-helper.sh"
	if [[ "${PULSE_BATCH_PREFETCH_ENABLED:-1}" != "1" || ! -x "$_batch_helper" ]]; then
		return 0
	fi
	local _batch_output
	_batch_output=$("$_batch_helper" refresh 2>/dev/null) || true
	# Parse counters for health instrumentation (t2830: also parses tickle counters)
	local _batch_search_calls=0 _batch_cache_writes=0
	local _tickle_fresh=0 _tickle_stale=0
	if [[ -n "$_batch_output" ]]; then
		local _line
		while IFS= read -r _line; do
			case "$_line" in
			search_calls=*)         _batch_search_calls="${_line#search_calls=}" ;;
			cache_writes=*)         _batch_cache_writes="${_line#cache_writes=}" ;;
			events_tickle_fresh=*)  _tickle_fresh="${_line#events_tickle_fresh=}" ;;
			events_tickle_stale=*)  _tickle_stale="${_line#events_tickle_stale=}" ;;
			esac
		done <<<"$_batch_output"
	fi
	_PULSE_HEALTH_BATCH_SEARCH_CALLS=$((_PULSE_HEALTH_BATCH_SEARCH_CALLS + _batch_search_calls))
	_PULSE_HEALTH_BATCH_CACHE_HITS=$((_PULSE_HEALTH_BATCH_CACHE_HITS + _batch_cache_writes))
	_PULSE_HEALTH_EVENTS_TICKLE_FRESH=$((_PULSE_HEALTH_EVENTS_TICKLE_FRESH + _tickle_fresh))
	_PULSE_HEALTH_EVENTS_TICKLE_STALE=$((_PULSE_HEALTH_EVENTS_TICKLE_STALE + _tickle_stale))
	echo "[pulse-wrapper] Batch prefetch: search_calls=${_batch_search_calls} cache_writes=${_batch_cache_writes} tickle_fresh=${_tickle_fresh} tickle_stale=${_tickle_stale}" >>"$LOGFILE"

	# t3027 (GH#21584): Bridge counters across run_stage_with_timeout subshell.
	# prefetch_state runs inside a subshell created by run_stage_with_timeout
	# in _run_preflight_stages, so updates to _PULSE_HEALTH_* shell vars die
	# when the subshell exits. The pulse-wrapper.sh deterministic pipeline
	# reads this temp file after the subshell returns and accumulates the
	# counters into the cycle-scoped totals. Pattern mirrors the merge
	# counter bridge at pulse-wrapper.sh:996-1008 (GH#18571).
	#
	# Format: single line of 4 space-separated integers in fixed positional
	# order: search_calls cache_hits tickle_fresh tickle_stale. Cumulative
	# within this prefetch_state invocation (we accumulate here rather than
	# requiring the reader to sum across multiple files). The reader
	# `read -r` parses positionally — DO NOT change column order without
	# updating pulse-wrapper.sh::_pulse_drain_prefetch_counters.
	local _pf_counters_file="${TMPDIR:-/tmp}/pulse-health-prefetch-$$.tmp"
	printf '%d %d %d %d\n' \
		"$_PULSE_HEALTH_BATCH_SEARCH_CALLS" \
		"$_PULSE_HEALTH_BATCH_CACHE_HITS" \
		"$_PULSE_HEALTH_EVENTS_TICKLE_FRESH" \
		"$_PULSE_HEALTH_EVENTS_TICKLE_STALE" \
		>"$_pf_counters_file" 2>/dev/null || true
	return 0
}

#######################################
# Pre-fetch state for ALL pulse-enabled repos
#
# Runs gh pr list + gh issue list for each repo in parallel, formats
# a compact summary, and writes it to STATE_FILE. This is injected
# into the pulse prompt so the agent sees all repos from the start —
# preventing the "only processes first repo" problem.
#
# This is a deterministic data-fetch utility. The intelligence about
# what to DO with this data stays in pulse.md.
#
# -----------------------------------------------------------------------------
# Architectural rationale (t2905, audit #21051) — DO NOT REMOVE THIS STAGE
# -----------------------------------------------------------------------------
# Measured cost: ~170s avg (156s-224s range, 30-cycle sample, Apr 2026).
# Naive view: "184s of housekeeping per pulse, can we drop it?" — NO.
#
# prefetch_state is NOT a downstream-call amortisation optimisation. It is
# the ONLY mechanism that produces three outputs the dispatch pipeline
# cannot operate without:
#
# 1. STATE_FILE (cross-repo PR/issue/missions/FOSS/contribution-watch
#    summary). This is INJECTED into the pulse agent's prompt at
#    pulse-wrapper.sh:428-434 — the LLM reads it via Read tool because
#    the payload routinely exceeds Linux execve() MAX_ARG_STRLEN (#4257).
#    Without STATE_FILE the LLM has zero cross-repo visibility and the
#    cycle is useless.
#
# 2. PULSE_SCOPE_REPOS export (line ~350) + SCOPE_FILE persistence.
#    Every worker checks PULSE_SCOPE_REPOS to gate branch/PR creation
#    (t1405, GH#2928). Without it, workers either dispatch with no scope
#    (all repos allowed = security regression) or refuse to dispatch.
#
# 3. STATE_FILE is also read directly by shell-stage consumers:
#      - prefetch_foss_scan / FOSS dispatch (pulse-wrapper.sh:1726).
#      - dispatch_foss_workers reads pre-fetched FOSS data from STATE_FILE.
#    Removing prefetch_state would force these stages to fetch on demand
#    or skip silently.
#
# What ALREADY makes this stage cheap:
#   - L3 batch prefetch via gh search (GH#19963) — _prefetch_batch_refresh
#     consolidates per-repo fetches when the org search cache hits.
#   - Idle-repo skip (t2098) — repos with no recent activity bypass the
#     full per-repo gh sweep.
#   - Read-side REST fallback (t2689) — when GraphQL is constrained,
#     individual sub-fetches route via the separate 5000/hr REST pool
#     instead of failing.
#   - Per-repo schedule check (pulse_hours / pulse_expires) — repos
#     outside their schedule window contribute zero gh calls.
#   - Hard timeout (120s for parallel pids, t1482, GH#15060) — bounded
#     worst case even when GraphQL is slow.
#
# Hypothesis ruled out (audit #21051): the issue body framed prefetch_state
# as cost-amortisation across "downstream stages" and asked whether those
# stages still benefit. The framing was wrong — the primary downstream
# consumer is the LLM agent (output 1 above), not subsequent shell stages.
# REST-fallback and dispatch-dedup REST routing (t2689, #20991) reduce the
# cost of OTHER gh paths but do not displace this stage's role.
#
# If you find yourself auditing this stage again because the cycle is slow:
#   - Look at preflight_ownership_reconcile (~600s, see t2904 — separate
#     audit).
#   - Look at complexity_scan (~470s, moved to standalone plist in t2903).
#   - Move the pulse interval up (180s -> 600s in settings.json) instead
#     of removing structurally-required stages. The cycle is naturally
#     long because it is a cross-repo state observer; running it more
#     often does not produce better outcomes.
#######################################
prefetch_state() {
	local repos_json="$REPOS_JSON"

	if [[ ! -f "$repos_json" ]]; then
		echo "[pulse-wrapper] repos.json not found at $repos_json — skipping prefetch" >>"$LOGFILE"
		echo "ERROR: repos.json not found" >"$STATE_FILE"
		return 1
	fi

	echo "[pulse-wrapper] Pre-fetching state for all pulse-enabled repos..." >>"$LOGFILE"

	# Extract pulse-enabled, non-local-only repos as slug|path|ph_start|ph_end|expires
	# pulse_hours fields default to "" when absent; pulse_expires defaults to "".
	# Bash 3.2: no associative arrays — use pipe-delimited fields.
	local repo_entries_raw
	repo_entries_raw=$(jq -r '.initialized_repos[] |
		select(.pulse == true and (.local_only // false) == false and .slug != "") |
		[
			.slug,
			.path,
			(if .pulse_hours then (.pulse_hours.start | tostring) else "" end),
			(if .pulse_hours then (.pulse_hours.end   | tostring) else "" end),
			(.pulse_expires // "")
		] | join("|")
	' "$repos_json")

	# Filter repos through schedule check; build slug|path pairs for downstream use
	local repo_entries=""
	while IFS='|' read -r slug path ph_start ph_end expires; do
		[[ -n "$slug" ]] || continue
		if check_repo_pulse_schedule "$slug" "$ph_start" "$ph_end" "$expires" "$repos_json"; then
			if [[ -z "$repo_entries" ]]; then
				repo_entries="${slug}|${path}"
			else
				repo_entries="${repo_entries}"$'\n'"${slug}|${path}"
			fi
		fi
	done <<<"$repo_entries_raw"

	if [[ -z "$repo_entries" ]]; then
		echo "[pulse-wrapper] No pulse-enabled repos in schedule window" >>"$LOGFILE"
		echo "No pulse-enabled repos in schedule window in repos.json" >"$STATE_FILE"
		return 1
	fi

	# GH#19963: Batch prefetch via org-level gh search (L3 cache layer).
	_prefetch_batch_refresh

	# Temp dir for parallel fetches
	local tmpdir
	tmpdir=$(mktemp -d)

	# Launch parallel gh fetches for each repo
	local pids=()
	local idx=0
	while IFS='|' read -r slug path; do
		(
			_prefetch_single_repo "$slug" "$path" "${tmpdir}/${idx}.txt"
		) &
		pids+=($!)
		idx=$((idx + 1))
	done <<<"$repo_entries"

	# Wait for all parallel fetches with a hard timeout (t1482).
	# Each repo does 3 gh API calls (pr list, pr list --state all, issue list).
	# GH#15060: Raised from 60s to 120s. With 13 repos and repos having 100+ PRs,
	# the GraphQL responses are large and rate limiting serializes parallel calls.
	# 60s caused silent timeouts producing "Open PRs (0)" on large backlogs.
	_wait_parallel_pids 120 "${pids[@]}"

	# Assemble state file in repo order
	_assemble_state_file "$tmpdir"

	# Clean up
	rm -rf "$tmpdir"

	# t1482: Sub-helpers that call external scripts (gh API, pr-salvage,
	# gh-failure-miner) get individual timeouts via run_cmd_with_timeout.
	# If a helper times out, the pulse proceeds without that section —
	# degraded but functional. Shell functions that only read local state
	# (priority allocations, queue governor, contribution watch) run
	# directly since they complete instantly.
	_append_prefetch_sub_helpers "$repo_entries"

	# Export PULSE_SCOPE_REPOS — comma-separated list of repo slugs that
	# workers are allowed to create PRs/branches on (t1405, GH#2928).
	# Workers CAN file issues on any repo (cross-repo self-improvement),
	# but code changes (branches, PRs) are restricted to this list.
	local scope_slugs
	scope_slugs=$(echo "$repo_entries" | cut -d'|' -f1 | grep . | paste -sd ',' -)
	export PULSE_SCOPE_REPOS="$scope_slugs"
	echo "$scope_slugs" >"$SCOPE_FILE"
	echo "[pulse-wrapper] PULSE_SCOPE_REPOS=${scope_slugs}" >>"$LOGFILE"

	local repo_count
	repo_count=$(echo "$repo_entries" | wc -l | tr -d ' ')
	echo "[pulse-wrapper] Pre-fetched state for $repo_count repos → $STATE_FILE" >>"$LOGFILE"
	return 0
}

#######################################
# Pre-fetch active mission state files
#
# Scans todo/missions/ and ~/.aidevops/missions/ for mission.md files
# with status: active|paused|blocked|validating. Extracts a compact
# summary (id, status, current milestone, pending features) so the
# pulse agent can act on missions without reading full state files.
#
# Arguments:
#   $1 - repo_entries (slug|path pairs, one per line)
# Output: mission summary to stdout (appended to STATE_FILE by caller)
#######################################
prefetch_missions() {
	local repo_entries="$1"
	local found_any=false

	# Collect mission files from repo-attached locations
	local mission_files=()
	while IFS='|' read -r slug path; do
		local missions_dir="${path}/todo/missions"
		if [[ -d "$missions_dir" ]]; then
			while IFS= read -r mfile; do
				[[ -n "$mfile" ]] && mission_files+=("${slug}|${path}|${mfile}")
			done < <(find "$missions_dir" -name "mission.md" -type f 2>/dev/null || true)
		fi
	done <<<"$repo_entries"

	# Also check homeless missions
	local homeless_dir="${HOME}/.aidevops/missions"
	if [[ -d "$homeless_dir" ]]; then
		while IFS= read -r mfile; do
			[[ -n "$mfile" ]] && mission_files+=("|homeless|${mfile}")
		done < <(find "$homeless_dir" -name "mission.md" -type f 2>/dev/null || true)
	fi

	if [[ ${#mission_files[@]} -eq 0 ]]; then
		return 0
	fi

	local active_count=0

	for entry in "${mission_files[@]}"; do
		local slug path mfile
		IFS='|' read -r slug path mfile <<<"$entry"

		# Extract frontmatter status — look for status: in YAML frontmatter
		local status
		status=$(_extract_frontmatter_field "$mfile" "status")

		# Only include active/paused/blocked/validating missions
		case "$status" in
		active | paused | blocked | validating) ;;
		*) continue ;;
		esac

		if [[ "$found_any" == false ]]; then
			echo ""
			echo "# Active Missions"
			echo ""
			echo "Mission state files detected by pulse-wrapper.sh. See pulse.md Step 3.5."
			echo ""
			found_any=true
		fi

		local mission_id
		mission_id=$(_extract_frontmatter_field "$mfile" "id")
		local title
		title=$(_extract_frontmatter_field "$mfile" "title")
		local mode
		mode=$(_extract_frontmatter_field "$mfile" "mode")
		local mission_dir
		mission_dir=$(dirname "$mfile")

		echo "## Mission: ${mission_id} — ${title}"
		echo ""
		echo "- **Status:** ${status}"
		echo "- **Mode:** ${mode}"
		echo "- **Repo:** ${slug:-homeless}"
		echo "- **Path:** ${mfile}"
		echo ""

		# Extract milestone summaries — find lines matching "### Milestone N:"
		# and their status lines
		_extract_milestone_summary "$mfile"

		echo ""
		active_count=$((active_count + 1))
	done

	if [[ "$active_count" -gt 0 ]]; then
		echo "[pulse-wrapper] Found $active_count active mission(s)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Pre-fetch FOSS contribution scan results (t1702)
#
# Runs foss-contribution-helper.sh scan --dry-run and appends a compact
# summary to STATE_FILE. This gives the pulse agent visibility into
# eligible FOSS repos so it can dispatch contribution workers when idle
# capacity exists.
#
# The scan checks: foss.enabled globally, per-repo foss:true, blocklist,
# daily token budget, and weekly PR rate limits. Only repos passing all
# gates appear as eligible.
#
# Output: FOSS scan summary to stdout (appended to STATE_FILE by caller)
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
prefetch_foss_scan() {
	local helper="${SCRIPT_DIR}/foss-contribution-helper.sh"
	if [[ ! -x "$helper" ]]; then
		return 0
	fi

	# Quick check: is FOSS globally enabled? Skip the scan entirely if not.
	local foss_enabled="false"
	local config_jsonc="${HOME}/.config/aidevops/config.jsonc"
	if [[ -f "$config_jsonc" ]] && command -v jq &>/dev/null; then
		foss_enabled=$(sed 's|//.*||g; s|/\*.*\*/||g' "$config_jsonc" 2>/dev/null |
			jq -r '.foss.enabled // "false"' 2>/dev/null) || foss_enabled="false"
	fi
	if [[ "$foss_enabled" != "true" ]]; then
		return 0
	fi

	# Check if any foss:true repos exist in repos.json
	local foss_repo_count=0
	if [[ -f "$REPOS_JSON" ]] && command -v jq &>/dev/null; then
		foss_repo_count=$(jq '[.initialized_repos[] | select(.foss == true)] | length' "$REPOS_JSON" 2>/dev/null) || foss_repo_count=0
	fi
	if [[ "${foss_repo_count:-0}" -eq 0 ]]; then
		return 0
	fi

	local scan_output
	scan_output=$(bash "$helper" scan --dry-run 2>/dev/null) || scan_output=""

	if [[ -z "$scan_output" ]]; then
		return 0
	fi

	# Extract eligible and skipped counts from the summary line
	local eligible_count=0
	local skipped_count=0
	if [[ "$scan_output" =~ ([0-9]+)\ eligible ]]; then
		eligible_count="${BASH_REMATCH[1]}"
	fi
	if [[ "$scan_output" =~ ([0-9]+)\ skipped ]]; then
		skipped_count="${BASH_REMATCH[1]}"
	fi

	# Get budget info
	local budget_output
	budget_output=$(bash "$helper" budget 2>/dev/null) || budget_output=""
	local daily_used=0
	local daily_max=200000
	local daily_remaining=0
	if [[ "$budget_output" =~ Used\ today:\ +([0-9]+) ]]; then
		daily_used="${BASH_REMATCH[1]}"
	fi
	if [[ "$budget_output" =~ Max\ daily\ tokens:\ +([0-9]+) ]]; then
		daily_max="${BASH_REMATCH[1]}"
	fi
	daily_remaining=$((daily_max - daily_used))
	if [[ "$daily_remaining" -lt 0 ]]; then
		daily_remaining=0
	fi

	# Extract per-repo eligible details (lines matching ELIGIBLE)
	local eligible_details
	eligible_details=$(echo "$scan_output" | grep -i 'ELIGIBLE' | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^[[:space:]]*/  - /' || true)

	{
		echo ""
		echo "# FOSS Contribution Scan (t1702)"
		echo ""
		echo "FOSS contributions are **enabled**. Scan results from \`foss-contribution-helper.sh scan --dry-run\`."
		echo ""
		echo "- Eligible repos: **${eligible_count}**"
		echo "- Skipped repos: ${skipped_count} (blocklisted, budget exceeded, or rate limited)"
		echo "- Daily token budget: ${daily_used}/${daily_max} used (${daily_remaining} remaining)"
		echo "- Max FOSS dispatches per cycle: ${FOSS_MAX_DISPATCH_PER_CYCLE}"
		echo ""
		if [[ -n "$eligible_details" && "$eligible_count" -gt 0 ]]; then
			echo "### Eligible FOSS Repos"
			echo ""
			echo "$eligible_details"
			echo ""
		fi
		echo "**Dispatch rule:** When idle worker capacity exists (all managed repo issues dispatched"
		echo "and worker slots remain), dispatch contribution workers for eligible FOSS repos."
		echo "Max ${FOSS_MAX_DISPATCH_PER_CYCLE} FOSS dispatches per pulse cycle. Use \`foss-contribution-helper.sh check <slug>\`"
		echo "before each dispatch. Record token usage after completion with \`foss-contribution-helper.sh record <slug> <tokens>\`."
		echo ""
	}

	echo "[pulse-wrapper] FOSS scan: ${eligible_count} eligible, ${skipped_count} skipped, budget ${daily_used}/${daily_max}" >>"$LOGFILE"
	return 0
}

#######################################
# Pre-fetch triage review status for needs-maintainer-review issues
#
# For each pulse-enabled repo, finds issues with the needs-maintainer-review
# label and checks whether an agent triage review comment already exists.
# This data enables the pulse to dispatch opus-tier review workers only
# for issues that haven't been reviewed yet.
#
# Detection: an agent review comment contains "## Review:" or
# "## Issue/PR Review:" in the body (the structured output format
# from review-issue-pr.md).
#
# Arguments:
#   $1 - repo_entries (slug|path pairs, one per line)
# Output: triage review status section to stdout
#######################################
prefetch_triage_review_status() {
	local repo_entries="$1"
	local found_any=false
	local total_pending=0

	while IFS='|' read -r slug path; do
		[[ -n "$slug" ]] || continue

		# GH#18984 (t2098): skip repos with 0 cached NMR issues
		if _prefetch_cached_label_count_is_zero "$slug" "needs-maintainer-review"; then
			echo "[pulse-wrapper] prefetch_triage_review_status: SKIP ${slug} — 0 NMR issues in cache" >>"$LOGFILE"
			continue
		fi

		# Get needs-maintainer-review issues for this repo
		local nmr_json nmr_err
		nmr_err=$(mktemp)
		nmr_json=$(gh_issue_list --repo "$slug" --label "needs-maintainer-review" \
			--state open --json number,title,createdAt,updatedAt \
			--limit 50 2>"$nmr_err") || nmr_json="[]"
		if [[ -z "$nmr_json" || "$nmr_json" == "null" ]]; then
			local _nmr_err_msg
			_nmr_err_msg=$(cat "$nmr_err" 2>/dev/null || echo "unknown error")
			# GH#18979 (t2097): detect rate-limit exhaustion
			if _pulse_gh_err_is_rate_limit "$nmr_err"; then
				_pulse_mark_rate_limited "prefetch_triage_review_status:${slug}"
			fi
			echo "[pulse-wrapper] prefetch_triage_review_status: gh_issue_list FAILED for ${slug}: ${_nmr_err_msg}" >>"$LOGFILE"
			nmr_json="[]"
		fi
		rm -f "$nmr_err"

		local nmr_count
		nmr_count=$(echo "$nmr_json" | jq 'length')
		[[ "$nmr_count" -gt 0 ]] || continue

		if [[ "$found_any" == false ]]; then
			echo ""
			echo "# Needs Maintainer Review — Triage Status"
			echo ""
			echo "Issues with \`needs-maintainer-review\` label and their automated triage review status."
			echo "Dispatch an opus-tier \`/review-issue-pr\` worker for items marked **needs-review**."
			echo "Max 2 triage review dispatches per pulse cycle."
			echo ""
			found_any=true
		fi

		echo "## ${slug}"
		echo ""

		# Check each issue for an existing agent review comment
		local i=0
		while [[ "$i" -lt "$nmr_count" ]]; do
			local number title created_at
			number=$(echo "$nmr_json" | jq -r ".[$i].number")
			title=$(echo "$nmr_json" | jq -r ".[$i].title")
			created_at=$(echo "$nmr_json" | jq -r ".[$i].createdAt")

			# Check for agent review comment (contains "## Review:" or "## Issue/PR Review:")
			# Use --paginate to handle issues with many comments (default page size is 30).
			# On API failure, mark as "unknown" rather than falsely reporting "needs-review".
			local review_response=""
			local review_exists=0
			local api_ok=true
			review_response=$(gh api "repos/${slug}/issues/${number}/comments" --paginate \
				--jq '[.[] | select(.body | test("## (Issue/PR )?Review:"))] | length' 2>/dev/null) || api_ok=false

			if [[ "$api_ok" == true ]]; then
				review_exists="$review_response"
				[[ "$review_exists" =~ ^[0-9]+$ ]] || review_exists=0
			fi

			local status_label
			if [[ "$api_ok" != true ]]; then
				status_label="unknown"
				echo "[pulse-wrapper] API error checking review status for ${slug}#${number}" >>"$LOGFILE"
			elif [[ "$review_exists" -gt 0 ]]; then
				status_label="reviewed"
			else
				status_label="needs-review"
				total_pending=$((total_pending + 1))
			fi

			echo "- Issue #${number}: ${title} [status: **${status_label}**] [created: ${created_at}]"

			i=$((i + 1))
		done

		echo ""
	done <<<"$repo_entries"

	if [[ "$found_any" == true ]]; then
		echo "**Total pending triage reviews: ${total_pending}**"
		echo ""
		echo "[pulse-wrapper] Triage review status: ${total_pending} issues pending review" >>"$LOGFILE"
	fi

	return 0
}
