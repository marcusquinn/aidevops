#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-prefetch-fetch.sh — PR/issue fetch helpers + single-repo orchestration
# =============================================================================
# Sub-library extracted from pulse-prefetch.sh (GH#19964).
# Covers:
#   1. PR delta/full fetch, enrichment, and formatting
#   2. Issue delta fetch helper
#   3. Single-repo idle-skip replay and orchestration
#   4. Parallel pid wait
#   5. State assembly and sub-helper runner
#   6. Per-repo pulse schedule checking
#   7. Per-repo pulse interval throttle (GH#20660)
#   8. Per-repo activity tier skip (t2831) — hot/warm/cold cadence control
#
# Usage: source "${SCRIPT_DIR}/pulse-prefetch-fetch.sh"
#
# Dependencies:
#   - pulse-prefetch-infra.sh (cache helpers, rate-limit helpers)
#   - shared-constants.sh
#   - pulse-repo-tier.sh (t2831: tier-of command, optional — degrades gracefully)
#   - Environment vars: LOGFILE, PULSE_PREFETCH_PR_LIMIT, PULSE_PREFETCH_ISSUE_LIMIT,
#     DAILY_PR_CAP, STATE_FILE, TRIAGE_STATE_FILE, REPOS_JSON, FOSS_SCAN_TIMEOUT
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_PREFETCH_FETCH_LOADED:-}" ]] && return 0
_PULSE_PREFETCH_FETCH_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# PR Prefetch Helpers (GH#5627, GH#15286, GH#15060)
# =============================================================================

#######################################
# Attempt delta PR fetch and merge into cached list (GH#15286).
# Sets PREFETCH_PR_SWEEP_MODE="full" on failure (caller falls through).
# Sets PREFETCH_PR_RESULT on success.
# Arguments: $1=slug, $2=cache_entry, $3=pr_err_file
#######################################
_prefetch_prs_try_delta() {
	local slug="$1"
	local cache_entry="$2"
	local pr_err="$3"

	local last_prefetch
	last_prefetch=$(echo "$cache_entry" | jq -r '.last_prefetch // ""' 2>/dev/null) || last_prefetch=""

	# No usable timestamp — fall back to full
	if [[ -z "$last_prefetch" ]]; then
		echo "[pulse-wrapper] _prefetch_repo_prs: delta fetch failed for ${slug} (falling back to full): no timestamp or fetch error" >>"$LOGFILE"
		PREFETCH_PR_SWEEP_MODE="full"
		return 0
	fi

	local delta_json=""
	delta_json=$(gh_pr_list --repo "$slug" --state open \
		--json number,title,reviewDecision,updatedAt,headRefName,createdAt,author \
		--search "updated:>=${last_prefetch}" \
		--limit "$PULSE_PREFETCH_PR_LIMIT" 2>"$pr_err") || delta_json=""

	if [[ -z "$delta_json" || "$delta_json" == "null" ]]; then
		local _delta_err_msg
		_delta_err_msg=$(cat "$pr_err" 2>/dev/null || echo "no timestamp or fetch error")
		echo "[pulse-wrapper] _prefetch_repo_prs: delta fetch failed for ${slug} (falling back to full): ${_delta_err_msg}" >>"$LOGFILE"
		PREFETCH_PR_SWEEP_MODE="full"
		return 0
	fi

	# Merge delta into cached full list: replace matching numbers, append new ones
	local cached_prs
	cached_prs=$(echo "$cache_entry" | jq '.prs // []' 2>/dev/null) || cached_prs="[]"
	local merged
	merged=$(echo "$cached_prs" | jq --argjson delta "$delta_json" '
		($delta | map(.number) | map(tostring) | map({(.) : true}) | add // {}) as $delta_nums |
		[.[] | select((.number | tostring) as $n | $delta_nums[$n] | not)] +
		$delta
	' 2>/dev/null) || merged=""

	if [[ -z "$merged" || "$merged" == "null" ]]; then
		echo "[pulse-wrapper] _prefetch_repo_prs: delta merge failed for ${slug} (falling back to full)" >>"$LOGFILE"
		PREFETCH_PR_SWEEP_MODE="full"
		return 0
	fi

	local delta_count
	delta_count=$(echo "$delta_json" | jq 'length' 2>/dev/null) || delta_count=0
	echo "[pulse-wrapper] _prefetch_repo_prs: delta for ${slug}: ${delta_count} changed PRs merged into cache" >>"$LOGFILE"
	PREFETCH_PR_RESULT="$merged"
	return 0
}

#######################################
# Fetch statusCheckRollup enrichment for open PRs (GH#15060).
# Non-fatal: returns empty string on failure.
# Arguments: $1=slug, $2=checks_limit
# Output: JSON array to stdout (or empty string)
#######################################
_prefetch_prs_enrich_checks() {
	local slug="$1"
	local checks_limit="$2"

	local checks_err
	checks_err=$(mktemp)
	local checks_json=""
	checks_json=$(gh_pr_list --repo "$slug" --state open \
		--json number,statusCheckRollup \
		--limit "$checks_limit" 2>"$checks_err") || checks_json=""

	if [[ -z "$checks_json" || "$checks_json" == "null" ]]; then
		local _checks_err_msg
		_checks_err_msg=$(cat "$checks_err" 2>/dev/null || echo "unknown error")
		echo "[pulse-wrapper] _prefetch_repo_prs: statusCheckRollup enrichment FAILED for ${slug} (non-fatal, PRs shown without check status): ${_checks_err_msg}" >>"$LOGFILE"
		checks_json=""
	fi
	rm -f "$checks_err"

	printf '%s' "$checks_json"
	return 0
}

#######################################
# Format PR list as markdown with optional check status enrichment.
# Arguments: $1=pr_json, $2=pr_count, $3=checks_json
# Output: markdown to stdout
#######################################
_prefetch_prs_format_output() {
	local pr_json="$1"
	local pr_count="$2"
	local checks_json="$3"

	if [[ "$pr_count" -le 0 ]]; then
		echo "### Open PRs (0)"
		echo "- None"
		return 0
	fi

	echo "### Open PRs ($pr_count)"
	if [[ -n "$checks_json" && "$checks_json" != "[]" ]]; then
		echo "$pr_json" | jq -r --argjson checks "${checks_json:-[]}" '
			($checks | map({(.number | tostring): .statusCheckRollup}) | add // {}) as $check_map |
			.[] |
			(.number | tostring) as $num |
			($check_map[$num] // null) as $rolls |
			"- PR #\(.number): \(.title) [checks: \(
				if $rolls == null or ($rolls | length) == 0 then "none"
				elif ($rolls | all((.conclusion // .state) == "SUCCESS")) then "PASS"
				elif ($rolls | any((.conclusion // .state) == "FAILURE")) then "FAIL"
				else "PENDING"
				end
			)] [review: \(
				if .reviewDecision == null or .reviewDecision == "" then "NONE"
				else .reviewDecision
				end
			)] [author: \(.author.login // "unknown")] [branch: \(.headRefName)] [updated: \(.updatedAt)]"
		'
	else
		echo "$pr_json" | jq -r '.[] | "- PR #\(.number): \(.title) [checks: unknown] [review: \(if .reviewDecision == null or .reviewDecision == "" then "NONE" else .reviewDecision end)] [author: \(.author.login // "unknown")] [branch: \(.headRefName)] [updated: \(.updatedAt)]"'
	fi
	return 0
}

_prefetch_repo_prs() {
	local slug="$1"
	local cache_entry="${2:-}"
	[[ -n "$cache_entry" ]] || cache_entry="{}"
	local sweep_mode="${3:-full}"

	# PRs (createdAt included for daily PR cap — GH#3821)
	# GH#15060: statusCheckRollup is the heaviest field in the GraphQL payload —
	# each PR's full check suite data can be kilobytes. With 100+ PRs, the
	# response exceeds GitHub's internal timeout and `gh` returns an error that
	# the `2>/dev/null || pr_json="[]"` pattern silently swallows, producing
	# "Open PRs (0)" when hundreds exist. This was the root cause of the pulse
	# seeing 0 PRs and never merging anything.
	#
	# Fix: fetch without statusCheckRollup first (fast, always works), then
	# enrich with check status in a separate lightweight call. If the enrichment
	# fails, the pulse still sees the PR list and can act on review status.
	#
	# GH#15286: Delta mode — fetch only PRs updated since last_prefetch, then
	# merge into cached full list. Full sweep replaces the cache entirely.
	local pr_json="" pr_err
	pr_err=$(mktemp)

	# GH#19963 L3: Check batch prefetch cache before per-repo API calls.
	# Execution order: idle skip (L2, handled by caller) → batch cache (L3) → delta/full (L4/L5)
	local _batch_helper="${SCRIPT_DIR}/pulse-batch-prefetch-helper.sh"
	local _used_batch_cache=false
	if [[ "${PULSE_BATCH_PREFETCH_ENABLED:-1}" == "1" && -x "$_batch_helper" ]]; then
		local _batch_prs
		_batch_prs=$("$_batch_helper" read-cache --kind prs --slug "$slug" 2>/dev/null) || _batch_prs=""
		if [[ -n "$_batch_prs" && "$_batch_prs" != "[]" && "$_batch_prs" != "null" ]]; then
			pr_json="$_batch_prs"
			_used_batch_cache=true
			echo "[pulse-wrapper] _prefetch_repo_prs: using batch cache for ${slug}" >>"$LOGFILE"
			_PULSE_HEALTH_BATCH_CACHE_HITS=$((_PULSE_HEALTH_BATCH_CACHE_HITS + 1))
		fi
	fi

	if [[ "$_used_batch_cache" == "false" ]]; then
		# Delta fetch: try merging recent changes into cache (GH#15286)
		PREFETCH_PR_SWEEP_MODE="$sweep_mode"
		PREFETCH_PR_RESULT=""
		if [[ "$sweep_mode" == "delta" ]]; then
			_prefetch_prs_try_delta "$slug" "$cache_entry" "$pr_err"
			sweep_mode="$PREFETCH_PR_SWEEP_MODE"
			pr_json="$PREFETCH_PR_RESULT"
		fi

		# Full fetch: either requested directly or delta fell back
		if [[ "$sweep_mode" == "full" ]]; then
			pr_json=$(gh_pr_list --repo "$slug" --state open \
				--json number,title,reviewDecision,updatedAt,headRefName,createdAt,author \
				--limit "$PULSE_PREFETCH_PR_LIMIT" 2>"$pr_err") || pr_json=""

			if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
				local err_msg
				err_msg=$(cat "$pr_err" 2>/dev/null || echo "unknown error")
				# GH#18979 (t2097): classify rate-limit errors and flag the cycle
				if _pulse_gh_err_is_rate_limit "$pr_err"; then
					_pulse_mark_rate_limited "_prefetch_repo_prs:${slug}"
				fi
				echo "[pulse-wrapper] _prefetch_repo_prs: gh_pr_list FAILED for ${slug}: ${err_msg}" >>"$LOGFILE"
				pr_json="[]"
			fi
		fi
	fi
	rm -f "$pr_err"

	# Export updated PR list for cache update by caller (Bash 3.2: no namerefs)
	PREFETCH_UPDATED_PRS="$pr_json"

	local pr_count
	pr_count=$(echo "$pr_json" | jq 'length' 2>/dev/null) || pr_count=0
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0

	# Enrichment: fetch statusCheckRollup separately (GH#15060)
	local checks_json=""
	if [[ "$pr_count" -gt 0 ]]; then
		checks_json=$(_prefetch_prs_enrich_checks "$slug" 50)
	fi

	_prefetch_prs_format_output "$pr_json" "$pr_count" "$checks_json"

	echo ""
	return 0
}

#######################################
# Print the Daily PR Cap section for a repo (GH#5627)
#
# Counts ALL PRs created today (open+merged+closed) to enforce the
# daily cap. Must use --state all — open-only undercounts (GH#3821,
# GH#4412). Emits a markdown section to stdout.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#######################################
_prefetch_repo_daily_cap() {
	local slug="$1"

	local today_utc
	today_utc=$(date -u +%Y-%m-%d)
	local daily_cap_json daily_cap_err
	daily_cap_err=$(mktemp)
	daily_cap_json=$(gh_pr_list --repo "$slug" --state all \
		--json createdAt --limit 200 2>"$daily_cap_err") || daily_cap_json="[]"
	if [[ -z "$daily_cap_json" || "$daily_cap_json" == "null" ]]; then
		local _daily_cap_err_msg
		_daily_cap_err_msg=$(cat "$daily_cap_err" 2>/dev/null || echo "unknown error")
		# GH#18979 (t2097): detect rate-limit exhaustion
		if _pulse_gh_err_is_rate_limit "$daily_cap_err"; then
			_pulse_mark_rate_limited "_prefetch_repo_daily_cap:${slug}"
		fi
		echo "[pulse-wrapper] _prefetch_repo_daily_cap: gh_pr_list FAILED for ${slug}: ${_daily_cap_err_msg}" >>"$LOGFILE"
		daily_cap_json="[]"
	fi
	rm -f "$daily_cap_err"
	local daily_pr_count
	daily_pr_count=$(echo "$daily_cap_json" | jq --arg today "$today_utc" \
		'[.[] | select((.createdAt // "") | startswith($today))] | length') || daily_pr_count=0
	[[ "$daily_pr_count" =~ ^[0-9]+$ ]] || daily_pr_count=0
	local daily_pr_remaining=$((DAILY_PR_CAP - daily_pr_count))
	if [[ "$daily_pr_remaining" -lt 0 ]]; then
		daily_pr_remaining=0
	fi

	echo "### Daily PR Cap"
	if [[ "$daily_pr_count" -ge "$DAILY_PR_CAP" ]]; then
		echo "- **DAILY PR CAP REACHED** — ${daily_pr_count}/${DAILY_PR_CAP} PRs created today (UTC)"
		echo "- **DO NOT dispatch new workers for this repo.** Wait for the next UTC day."
		echo "[pulse-wrapper] Daily PR cap reached for ${slug}: ${daily_pr_count}/${DAILY_PR_CAP}" >>"$LOGFILE"
	else
		echo "- PRs created today: ${daily_pr_count}/${DAILY_PR_CAP} (${daily_pr_remaining} remaining)"
	fi

	echo ""
	return 0
}

# =============================================================================
# Issue Delta Fetch Helper (GH#15286)
# =============================================================================

#######################################
# Attempt delta issue fetch and merge into cached list (GH#15286).
# Sets PREFETCH_ISSUE_SWEEP_MODE="full" on failure (caller falls through).
# Sets PREFETCH_ISSUE_RESULT on success.
# Arguments: $1=slug, $2=cache_entry, $3=issue_err_file
#######################################
_prefetch_issues_try_delta() {
	local slug="$1"
	local cache_entry="$2"
	local issue_err="$3"

	local last_prefetch
	last_prefetch=$(echo "$cache_entry" | jq -r '.last_prefetch // ""' 2>/dev/null) || last_prefetch=""

	# No usable timestamp — fall back to full
	if [[ -z "$last_prefetch" ]]; then
		echo "[pulse-wrapper] _prefetch_repo_issues: delta fetch failed for ${slug} (falling back to full): no timestamp or fetch error" >>"$LOGFILE"
		PREFETCH_ISSUE_SWEEP_MODE="full"
		return 0
	fi

	local delta_json=""
	delta_json=$(gh_issue_list --repo "$slug" --state open \
		--json number,title,labels,updatedAt,assignees,body \
		--search "updated:>=${last_prefetch}" \
		--limit "$PULSE_PREFETCH_ISSUE_LIMIT" 2>"$issue_err") || delta_json=""

	if [[ -z "$delta_json" || "$delta_json" == "null" ]]; then
		local _delta_issue_err
		_delta_issue_err=$(cat "$issue_err" 2>/dev/null || echo "no timestamp or fetch error")
		echo "[pulse-wrapper] _prefetch_repo_issues: delta fetch failed for ${slug} (falling back to full): ${_delta_issue_err}" >>"$LOGFILE"
		PREFETCH_ISSUE_SWEEP_MODE="full"
		return 0
	fi

	# Merge delta into cached full list
	local cached_issues
	cached_issues=$(echo "$cache_entry" | jq '.issues // []' 2>/dev/null) || cached_issues="[]"
	local merged
	merged=$(echo "$cached_issues" | jq --argjson delta "$delta_json" '
		($delta | map(.number) | map(tostring) | map({(.) : true}) | add // {}) as $delta_nums |
		[.[] | select((.number | tostring) as $n | $delta_nums[$n] | not)] +
		$delta
	' 2>/dev/null) || merged=""

	if [[ -z "$merged" || "$merged" == "null" ]]; then
		echo "[pulse-wrapper] _prefetch_repo_issues: delta merge failed for ${slug} (falling back to full)" >>"$LOGFILE"
		PREFETCH_ISSUE_SWEEP_MODE="full"
		return 0
	fi

	local delta_count
	delta_count=$(echo "$delta_json" | jq 'length' 2>/dev/null) || delta_count=0
	echo "[pulse-wrapper] _prefetch_repo_issues: delta for ${slug}: ${delta_count} changed issues merged into cache" >>"$LOGFILE"
	PREFETCH_ISSUE_RESULT="$merged"
	return 0
}

# =============================================================================
# Single-Repo Orchestration (GH#5627, GH#18984/t2098)
# =============================================================================

#######################################
# GH#18984 (t2098): Emit cached-data replay for an idle repo on cache-hit.
#
# On cache-hit, replays cached PR/issue sections from the cache entry
# instead of making 6 expensive gh API calls. The only live call is
# _prefetch_prs_enrich_checks for repos with cached PRs > 0 (catches
# reviewDecision changes that don't always update updatedAt).
#
# Writes markdown sections to stdout. Sets PREFETCH_UPDATED_PRS and
# PREFETCH_UPDATED_ISSUES for the cache-update path in the caller.
#
# Arguments:
#   $1 - repo slug
#   $2 - cache_entry JSON
#######################################
_prefetch_single_repo_idle_skip() {
	local slug="$1"
	local cache_entry="$2"

	local _cached_last
	_cached_last=$(echo "$cache_entry" | jq -r '.last_prefetch // "unknown"' 2>/dev/null) || _cached_last="unknown"
	echo "> **State cache hit** — fingerprint unchanged since \`${_cached_last}\`."
	echo "> No open issues or PRs have been updated since then."
	echo "> LLM may skip deep analysis of this repo this cycle."
	echo ""

	local _cached_prs _cached_issues _cached_pr_count _cached_issue_count
	_cached_prs=$(echo "$cache_entry" | jq -c '.prs // []' 2>/dev/null) || _cached_prs="[]"
	_cached_issues=$(echo "$cache_entry" | jq -c '.issues // []' 2>/dev/null) || _cached_issues="[]"
	_cached_pr_count=$(echo "$_cached_prs" | jq 'length' 2>/dev/null) || _cached_pr_count=0
	[[ "$_cached_pr_count" =~ ^[0-9]+$ ]] || _cached_pr_count=0
	_cached_issue_count=$(echo "$_cached_issues" | jq 'length' 2>/dev/null) || _cached_issue_count=0
	[[ "$_cached_issue_count" =~ ^[0-9]+$ ]] || _cached_issue_count=0

	# Replay cached PR section
	echo "### Open PRs (${_cached_pr_count}) [cached]"
	if [[ "$_cached_pr_count" -gt 0 ]]; then
		echo "$_cached_prs" | jq -r '.[] | "- PR #\(.number): \(.title) [review: \(.reviewDecision // "NONE")] [updated: \(.updatedAt)]"'
	else
		echo "- None"
	fi
	echo ""

	# Checks enrichment: always run for repos with cached PRs > 0
	if [[ "$_cached_pr_count" -gt 0 ]]; then
		local _checks_json=""
		_checks_json=$(_prefetch_prs_enrich_checks "$slug" 50)
		if [[ -n "$_checks_json" && "$_checks_json" != "[]" && "$_checks_json" != "null" ]]; then
			echo "### PR Check Status (live)"
			echo "$_checks_json" | jq -r '.[] | "- PR #\(.number): \(.statusCheckRollup // "unknown")"' 2>/dev/null || true
			echo ""
		fi
	fi

	# Skip daily cap — unchanged repos don't create PRs
	echo "### Daily PR Cap [cached]"
	echo "- Skipped (idle repo, no new PRs expected)"
	echo ""

	# Replay cached issue sections using same filter logic as _prefetch_repo_issues
	# GH#20048: shared helper replaces inline jq non-task filter
	local _filtered_cached _disp_json _sweep_json _disp_count _sweep_count
	_filtered_cached=$(echo "$_cached_issues" | _filter_non_task_issues)
	_disp_json=$(echo "$_filtered_cached" | jq -c '[.[] | select(.labels | map(.name) | (index("source:quality-sweep") or index("source:review-feedback")) | not)]' 2>/dev/null) || _disp_json="[]"
	_sweep_json=$(echo "$_filtered_cached" | jq -c '[.[] | select(.labels | map(.name) | (index("source:quality-sweep") or index("source:review-feedback")))]' 2>/dev/null) || _sweep_json="[]"
	_disp_count=$(echo "$_disp_json" | jq 'length' 2>/dev/null) || _disp_count=0
	_sweep_count=$(echo "$_sweep_json" | jq 'length' 2>/dev/null) || _sweep_count=0

	if [[ "$_disp_count" -gt 0 ]]; then
		echo "### Open Issues (${_disp_count}) [cached]"
		echo "$_disp_json" | jq -r '.[] | "- Issue #\(.number): \(.title) [labels: \(if (.labels | length) == 0 then "none" else (.labels | map(.name) | join(", ")) end)] [assignees: \(if (.assignees | length) == 0 then "none" else (.assignees | map(.login) | join(", ")) end)] [updated: \(.updatedAt)]"'
	else
		echo "### Open Issues (0) [cached]"
		echo "- None"
	fi
	echo ""
	if [[ "$_sweep_count" -gt 0 ]]; then
		echo "### Quality-Tracked Issues (${_sweep_count}) [cached]"
		echo "$_sweep_json" | jq -r '.[] | "- Issue #\(.number): \(.title)"'
		echo ""
	fi

	# Set shared vars for cache update — reuse cached data
	PREFETCH_UPDATED_PRS="$_cached_prs"
	PREFETCH_UPDATED_ISSUES="$_cached_issues"

	echo "[pulse-wrapper] _prefetch_single_repo: IDLE SKIP for ${slug} — reused cached data (${_cached_pr_count} PRs, ${_cached_issue_count} issues)" >>"$LOGFILE"
	_PULSE_HEALTH_IDLE_REPO_SKIPS=$((_PULSE_HEALTH_IDLE_REPO_SKIPS + 1))
	return 0
}

_prefetch_single_repo() {
	local slug="$1"
	local path="$2"
	local outfile="$3"

	# t2831 Tier-based skip (before ANY gh API calls):
	# Hot repos proceed every cycle; warm/cold repos skip when last check
	# is more recent than their tier interval. Falls back to "proceed" when
	# PULSE_TIER_CLASSIFICATION_ENABLED != 1 or the tier script is missing.
	if ! check_repo_tier_skip "$slug"; then
		# Tier skip: emit cached data so the state file still has an entry
		# for this repo, then return without making any gh API calls.
		local _tier_cache
		_tier_cache=$(_prefetch_cache_get "$slug")
		{
			echo "## ${slug} (${path})"
			echo ""
			echo "> **Tier skip** — this repo is below hot tier and was checked recently."
			echo "> Using cached state from last full prefetch."
			echo ""
			if [[ -n "$_tier_cache" && "$_tier_cache" != "null" ]]; then
				PREFETCH_UPDATED_PRS="[]"
				PREFETCH_UPDATED_ISSUES="[]"
				_prefetch_single_repo_idle_skip "$slug" "$_tier_cache"
			else
				echo "### Open PRs [tier-skipped, no cache]"
				echo "- None"
				echo ""
				echo "### Open Issues [tier-skipped, no cache]"
				echo "- None"
				echo ""
			fi
		} >"$outfile"
		echo "[pulse-wrapper] _prefetch_single_repo: TIER SKIP for ${slug} — cached data replayed" >>"$LOGFILE"
		_PULSE_HEALTH_IDLE_REPO_SKIPS=$((_PULSE_HEALTH_IDLE_REPO_SKIPS + 1))
		return 0
	fi

	# Record that we are doing a full prefetch for this repo (for tier interval tracking).
	update_repo_tier_check_timestamp "$slug"

	# GH#15286: Determine sweep mode from cache
	local cache_entry
	cache_entry=$(_prefetch_cache_get "$slug")
	local sweep_mode="delta"
	if _prefetch_needs_full_sweep "$cache_entry"; then
		sweep_mode="full"
		echo "[pulse-wrapper] _prefetch_single_repo: full sweep for ${slug}" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] _prefetch_single_repo: delta prefetch for ${slug}" >>"$LOGFILE"
	fi

	# Reset shared output vars (subshell-safe: each repo runs in its own subshell)
	PREFETCH_UPDATED_PRS="[]"
	PREFETCH_UPDATED_ISSUES="[]"

	# t2041 Layer 1: detect cache hit. When the current state fingerprint
	# matches the cached one AND the cheap verification query shows nothing
	# has changed since last_prefetch, emit a compact "cache hit" marker
	# the LLM can use to short-circuit deep analysis. We STILL write the
	# Open PRs / Queued Issues sections (so the LLM has recent state if it
	# decides to read deeper) but the LLM-facing summary leads with the
	# cache-hit signal so cheap cycles stay cheap.
	local cache_hit="false"
	if _prefetch_detect_cache_hit "$slug" "$cache_entry"; then
		cache_hit="true"
		echo "[pulse-wrapper] _prefetch_single_repo: STATE CACHE HIT for ${slug} (fingerprint=${PREFETCH_CURRENT_FINGERPRINT})" >>"$LOGFILE"
	fi

	{
		echo "## ${slug} (${path})"
		echo ""
		if [[ "$cache_hit" == "true" ]]; then
			_prefetch_single_repo_idle_skip "$slug" "$cache_entry"
		else
			_prefetch_repo_prs "$slug" "$cache_entry" "$sweep_mode"
			_prefetch_repo_daily_cap "$slug"
			_prefetch_repo_issues "$slug" "$cache_entry" "$sweep_mode"
		fi
	} >"$outfile"

	# GH#15286: Update cache with fresh data.
	# t2041: also persist the state_fingerprint for Layer 1 cache-hit
	# detection on the next cycle.
	local now_iso
	now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	# If the fingerprint wasn't already computed for cache-hit detection
	# (e.g. cache entry was empty), compute it now so the cache write is
	# consistent.
	if [[ -z "${PREFETCH_CURRENT_FINGERPRINT:-}" ]]; then
		PREFETCH_CURRENT_FINGERPRINT=$(_compute_repo_state_fingerprint "$slug")
	fi
	local fingerprint="${PREFETCH_CURRENT_FINGERPRINT:-}"
	local new_entry
	if [[ "$sweep_mode" == "full" ]]; then
		new_entry=$(jq -n \
			--arg now "$now_iso" \
			--arg fp "$fingerprint" \
			--argjson prs "${PREFETCH_UPDATED_PRS:-[]}" \
			--argjson issues "${PREFETCH_UPDATED_ISSUES:-[]}" \
			'{last_prefetch: $now, last_full_sweep: $now, state_fingerprint: $fp, prs: $prs, issues: $issues}')
	else
		local last_full_sweep
		last_full_sweep=$(echo "$cache_entry" | jq -r '.last_full_sweep // ""' 2>/dev/null) || last_full_sweep=""
		new_entry=$(jq -n \
			--arg now "$now_iso" \
			--arg lfs "$last_full_sweep" \
			--arg fp "$fingerprint" \
			--argjson prs "${PREFETCH_UPDATED_PRS:-[]}" \
			--argjson issues "${PREFETCH_UPDATED_ISSUES:-[]}" \
			'{last_prefetch: $now, last_full_sweep: $lfs, state_fingerprint: $fp, prs: $prs, issues: $issues}')
	fi
	_prefetch_cache_set "$slug" "$new_entry"

	return 0
}

# =============================================================================
# Parallel Wait + State Assembly (GH#5627)
# =============================================================================

#######################################
# Wait for parallel PIDs with a hard timeout (GH#5627)
#
# Poll-based approach (kill -0) instead of blocking wait — wait $pid
# blocks until the process exits, so a timeout check between waits is
# ineffective when a single wait hangs for minutes.
#
# Arguments:
#   $1 - timeout in seconds
#   $2..N - PIDs to wait for (passed as remaining args)
# Returns: 0 always (best-effort — kills stragglers on timeout)
#######################################
_wait_parallel_pids() {
	local timeout_secs="$1"
	shift
	local pids=("$@")

	local wait_elapsed=0
	local all_done=false
	while [[ "$all_done" != "true" ]] && [[ "$wait_elapsed" -lt "$timeout_secs" ]]; do
		all_done=true
		for pid in "${pids[@]}"; do
			if kill -0 "$pid" 2>/dev/null; then
				all_done=false
				break
			fi
		done
		if [[ "$all_done" != "true" ]]; then
			sleep 2
			wait_elapsed=$((wait_elapsed + 2))
		fi
	done
	if [[ "$all_done" != "true" ]]; then
		echo "[pulse-wrapper] Parallel gh fetch timeout after ${wait_elapsed}s — killing remaining fetches" >>"$LOGFILE"
		for pid in "${pids[@]}"; do
			if kill -0 "$pid" 2>/dev/null; then
				_kill_tree "$pid" || true
			fi
		done
		sleep 1
		# Force-kill any survivors
		for pid in "${pids[@]}"; do
			if kill -0 "$pid" 2>/dev/null; then
				_force_kill_tree "$pid" || true
			fi
		done
	fi
	# Reap all child processes (non-blocking since they're dead or killed)
	for pid in "${pids[@]}"; do
		wait "$pid" 2>/dev/null || true
	done
	return 0
}

#######################################
# Assemble state file from parallel fetch results (GH#5627)
#
# Concatenates numbered output files from tmpdir into STATE_FILE
# with a header timestamp.
#
# Arguments:
#   $1 - tmpdir containing numbered .txt files
#######################################
_assemble_state_file() {
	local tmpdir="$1"

	{
		echo "# Pre-fetched Repo State ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
		echo ""
		echo "This state was fetched by pulse-wrapper.sh BEFORE the pulse started."
		echo "Do NOT re-fetch — act on this data directly. See pulse.md Step 2."
		echo ""
		local i=0
		while [[ -f "${tmpdir}/${i}.txt" ]]; do
			cat "${tmpdir}/${i}.txt"
			i=$((i + 1))
		done
	} >"$STATE_FILE"
	return 0
}

#######################################
# Run a prefetch sub-command with timeout and append output to a target file.
# Encapsulates the repeated pattern: mktemp → run_cmd_with_timeout → cat → rm.
# Arguments:
#   $1 - timeout in seconds
#   $2 - target file to append output to
#   $3 - label for log messages
#   $4..N - command and arguments to run
#######################################
_run_prefetch_step() {
	local timeout="$1"
	local target_file="$2"
	local label="$3"
	shift 3

	local tmp_file
	tmp_file=$(mktemp)
	run_cmd_with_timeout "$timeout" "$@" >"$tmp_file" 2>/dev/null || {
		echo "[pulse-wrapper] ${label} timed out after ${timeout}s (non-fatal)" >>"$LOGFILE"
	}
	cat "$tmp_file" >>"$target_file"
	rm -f "$tmp_file"
	return 0
}

_append_prefetch_sub_helpers() {
	local repo_entries="$1"

	# t2041: Hygiene Anomalies — reads t2040's _normalize_label_invariants
	# counter file. Zero anomalies = one line of text, so this is cheap to
	# include every cycle. Nonzero triggers investigation.
	prefetch_hygiene_anomalies >>"$STATE_FILE"

	# Append mission state (reads local files — fast)
	prefetch_missions "$repo_entries" >>"$STATE_FILE"

	# Append active worker snapshot for orphaned PR detection (t216, local ps — fast)
	prefetch_active_workers >>"$STATE_FILE"

	# Append repo hygiene data for LLM triage (t1417)
	# Total prefetch budget: 60s (parallel) + 30s + 30s + 30s = 150s max,
	# well within the 600s stage timeout.
	_run_prefetch_step 30 "$STATE_FILE" "prefetch_hygiene" prefetch_hygiene

	# Append CI failure patterns from notification mining (GH#4480)
	_run_prefetch_step 30 "$STATE_FILE" "prefetch_ci_failures" prefetch_ci_failures

	# Append priority-class worker allocations (t1423, reads local file — fast)
	_append_priority_allocations >>"$STATE_FILE"

	# Append adaptive queue-governor guidance (t1455, local computation — fast)
	append_adaptive_queue_governor

	# Append external contribution watch summary (t1419, local state — fast)
	prefetch_contribution_watch >>"$STATE_FILE"

	# Append failed-notification systemic summary (t3960)
	_run_prefetch_step 30 "$STATE_FILE" "prefetch_gh_failure_notifications" prefetch_gh_failure_notifications

	# Write needs-maintainer-review triage status to a SEPARATE file (t1894).
	# This data is used only by the deterministic dispatch_triage_reviews()
	# function — it must NOT appear in the LLM's STATE_FILE. NMR issues are
	# a security gate; the LLM should never see or act on them.
	# Uses overwrite (>) not append (>>) — triage file is written once per cycle.
	TRIAGE_STATE_FILE="${STATE_FILE%.txt}-triage.txt"
	local triage_tmp
	triage_tmp=$(mktemp)
	run_cmd_with_timeout 30 prefetch_triage_review_status "$repo_entries" >"$triage_tmp" 2>/dev/null || {
		echo "[pulse-wrapper] prefetch_triage_review_status timed out after 30s (non-fatal)" >>"$LOGFILE"
	}
	cat "$triage_tmp" >"$TRIAGE_STATE_FILE"
	rm -f "$triage_tmp"

	# Append status:needs-info contributor reply status
	_run_prefetch_step 30 "$STATE_FILE" "prefetch_needs_info_replies" prefetch_needs_info_replies "$repo_entries"

	# Append FOSS contribution scan results (t1702)
	_run_prefetch_step "$FOSS_SCAN_TIMEOUT" "$STATE_FILE" "prefetch_foss_scan" prefetch_foss_scan

	return 0
}

# =============================================================================
# Per-Repo Pulse Schedule Check (GH#6510)
# =============================================================================

########################################
# Check per-repo pulse schedule constraints (GH#6510)
#
# Enforces two optional repos.json fields:
#   pulse_hours: {"start": N, "end": N}  — 24h local time window
#   pulse_expires: "YYYY-MM-DD"          — ISO date after which pulse stops
#
# When pulse_expires is past today, this function atomically sets
# pulse: false in repos.json (temp file + mv) and returns 1 (skip).
# When pulse_hours is set and the current hour is outside the window,
# returns 1 (skip). Overnight windows (start > end, e.g., 17→5) are
# supported. Repos without either field always return 0 (include).
#
# Bash 3.2 compatible: no associative arrays, no bash 4+ features.
# date +%H returns zero-padded strings — strip with 10# prefix for
# arithmetic to avoid octal interpretation (e.g., 08 → 10#08 = 8).
#
# Arguments:
#   $1 - slug (owner/repo, for log messages)
#   $2 - pulse_hours_start (integer 0-23, or "" if not set)
#   $3 - pulse_hours_end   (integer 0-23, or "" if not set)
#   $4 - pulse_expires     (YYYY-MM-DD string, or "" if not set)
#   $5 - repos_json        (path to repos.json, for expiry auto-disable)
#
# Exit codes:
#   0 - repo is in schedule window (include in this pulse)
#   1 - repo is outside window or expired (skip this pulse)
########################################
########################################
# Per-repo pulse interval throttle (GH#20660)
# State file path used by check_repo_pulse_interval and update_repo_pulse_timestamp.
########################################
PULSE_LAST_PER_REPO_FILE="${PULSE_LAST_PER_REPO_FILE:-${HOME}/.aidevops/logs/pulse-last-per-repo.json}"

########################################
# Check whether a per-repo pulse_interval has elapsed since the last poll.
#
# Mirrors the shape of check_repo_pulse_schedule: returns 0 to include the
# repo this cycle, 1 to skip. Backwards compatible: when pulse_interval is
# absent the repo is always included (no throttle).
#
# Arguments:
#   $1 - repo_slug (owner/repo)
#   $2 - pulse_interval (integer seconds from repos.json, or "" if not set)
#   $3 - state_file (optional; defaults to PULSE_LAST_PER_REPO_FILE)
#
# Exit codes:
#   0 - include this repo (interval elapsed or no interval set)
#   1 - skip this repo (interval not yet elapsed)
########################################
check_repo_pulse_interval() {
	local slug="$1"
	local interval="$2"
	local state_file="${3:-$PULSE_LAST_PER_REPO_FILE}"

	# No interval set: always include (backwards compatible)
	if [[ -z "$interval" ]]; then
		return 0
	fi

	# Must be a positive integer
	if [[ ! "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -eq 0 ]]; then
		echo "[pulse-wrapper] WARNING: pulse_interval for ${slug} is not a valid positive integer (got: '${interval}') — falling back to no throttle" >>"$LOGFILE"
		return 0
	fi

	# Enforce minimum 60s
	if [[ "$interval" -lt 60 ]]; then
		echo "[pulse-wrapper] WARNING: pulse_interval for ${slug} is below minimum 60s (got: ${interval}) — clamping to 60s" >>"$LOGFILE"
		interval=60
	fi

	# Read last-polled timestamp from state file
	local last_polled=0
	if [[ -f "$state_file" ]] && command -v jq &>/dev/null; then
		local val
		val=$(jq -r --arg slug "$slug" '.last_pulsed[$slug] // 0' "$state_file" 2>/dev/null)
		[[ "$val" =~ ^[0-9]+$ ]] && last_polled="$val"
	fi

	local now elapsed
	now=$(date +%s)
	elapsed=$((now - last_polled))

	if [[ "$elapsed" -lt "$interval" ]]; then
		echo "[pulse-wrapper] pulse_interval_skip repo=${slug} interval=${interval}s elapsed=${elapsed}s last_polled=${last_polled}" >>"$LOGFILE"
		return 1
	fi

	return 0
}

########################################
# Write the current epoch timestamp as the last-polled time for a repo.
#
# Uses atomic mktemp+mv so concurrent pulse runners cannot produce a torn
# read. Last-writer-wins is acceptable since timestamps are monotone.
#
# Arguments:
#   $1 - repo_slug (owner/repo)
#   $2 - state_file (optional; defaults to PULSE_LAST_PER_REPO_FILE)
#
# Returns: 0 always (non-fatal; failures are logged and silently ignored)
########################################
update_repo_pulse_timestamp() {
	local slug="$1"
	local state_file="${2:-$PULSE_LAST_PER_REPO_FILE}"

	command -v jq &>/dev/null || return 0

	local now
	now=$(date +%s)

	# Read existing state or start with an empty object
	local existing='{}'
	if [[ -f "$state_file" ]]; then
		existing=$(jq '.' "$state_file" 2>/dev/null) || existing='{}'
		[[ -n "$existing" ]] || existing='{}'
	fi

	# Ensure the logs directory exists
	local state_dir
	state_dir="${state_file%/*}"
	[[ -d "$state_dir" ]] || mkdir -p "$state_dir" 2>/dev/null || true

	local tmp_state
	# t2997: drop .json — XXXXXX must be at end for BSD mktemp.
	tmp_state=$(mktemp "${state_dir}/.pulse-last-per-repo-XXXXXX") || {
		echo "[pulse-wrapper] update_repo_pulse_timestamp: mktemp failed for ${slug} — skipping write" >>"$LOGFILE"
		return 0
	}

	if printf '%s' "$existing" | jq --arg slug "$slug" --argjson ts "$now" '
		if .last_pulsed then .last_pulsed[$slug] = $ts
		else .last_pulsed = {($slug): $ts} end
	' >"$tmp_state" 2>/dev/null && jq empty "$tmp_state" 2>/dev/null; then
		mv "$tmp_state" "$state_file"
	else
		rm -f "$tmp_state"
		echo "[pulse-wrapper] WARNING: update_repo_pulse_timestamp: jq produced invalid JSON for ${slug} — aborting write" >>"$LOGFILE"
	fi
	return 0
}

check_repo_pulse_schedule() {
	local slug="$1"
	local ph_start="$2"
	local ph_end="$3"
	local expires="$4"
	local repos_json="$5"

	# --- pulse_expires check ---
	if [[ -n "$expires" ]]; then
		local today_date
		today_date=$(date +%Y-%m-%d)
		# String comparison works for ISO dates (lexicographic == chronological)
		if [[ "$today_date" > "$expires" ]]; then
			echo "[pulse-wrapper] pulse_expires reached for ${slug} (expires=${expires}, today=${today_date}) — auto-disabling pulse" >>"$LOGFILE"
			# Atomic write: temp file + mv (POSIX-guaranteed atomic on local fs)
			# Last-writer-wins is acceptable since expiry is idempotent.
			if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
				local tmp_json
				tmp_json=$(mktemp)
				if jq --arg slug "$slug" '
					.initialized_repos |= map(
						if .slug == $slug then .pulse = false else . end
					)
				' "$repos_json" >"$tmp_json" 2>/dev/null && jq empty "$tmp_json" 2>/dev/null; then
					mv "$tmp_json" "$repos_json"
					echo "[pulse-wrapper] Set pulse:false for ${slug} in repos.json (expiry auto-disable)" >>"$LOGFILE"
				else
					rm -f "$tmp_json"
					echo "[pulse-wrapper] WARNING: jq produced invalid JSON for ${slug} expiry — aborting write (GH#16746)" >>"$LOGFILE"
				fi
			fi
			return 1
		fi
	fi

	# --- pulse_hours check ---
	if [[ -n "$ph_start" && -n "$ph_end" ]]; then
		# Strip leading zeros before arithmetic to avoid octal interpretation
		# (bash treats 08/09 as invalid octal without the 10# prefix)
		local current_hour
		current_hour=$(date +%H)
		local cur ph_s ph_e
		cur=$((10#${current_hour}))
		ph_s=$((10#${ph_start}))
		ph_e=$((10#${ph_end}))

		local in_window=false
		if [[ "$ph_s" -le "$ph_e" ]]; then
			# Normal window (e.g., 9→17): in window when cur >= start AND cur < end
			if [[ "$cur" -ge "$ph_s" && "$cur" -lt "$ph_e" ]]; then
				in_window=true
			fi
		else
			# Overnight window (e.g., 17→5): in window when cur >= start OR cur < end
			if [[ "$cur" -ge "$ph_s" || "$cur" -lt "$ph_e" ]]; then
				in_window=true
			fi
		fi

		if [[ "$in_window" != "true" ]]; then
			echo "[pulse-wrapper] pulse_hours window ${ph_s}→${ph_e} not active for ${slug} (current hour: ${cur}) — skipping" >>"$LOGFILE"
			return 1
		fi
	fi

	return 0
}

# =============================================================================
# Per-Repo Activity Tier Skip (t2831)
# =============================================================================
# Controls how often each repo is evaluated based on its activity tier.
# Hot repos: check every cycle (PULSE_TIER_HOT_INTERVAL=0, no skip).
# Warm repos: skip if last full check < PULSE_TIER_WARM_INTERVAL seconds ago.
# Cold repos: skip if last full check < PULSE_TIER_COLD_INTERVAL seconds ago.
#
# Tier assignment is performed hourly by pulse-repo-tier-classifier-routine.sh
# and cached at ~/.aidevops/cache/pulse-repo-tiers.json.
# The tier-of command reads from the cache and falls back to "warm" on miss.
#
# State file: PULSE_TIER_LAST_CHECK_FILE (separate from PULSE_LAST_PER_REPO_FILE
# so tier-based throttle is independent of repos.json pulse_interval).
# =============================================================================

########################################
# State file for per-repo tier-based last-check timestamps.
########################################
PULSE_TIER_LAST_CHECK_FILE="${PULSE_TIER_LAST_CHECK_FILE:-${HOME}/.aidevops/logs/pulse-tier-last-check.json}"

########################################
# Tier classifier script path.
########################################
PULSE_TIER_SCRIPT="${PULSE_TIER_SCRIPT:-${SCRIPT_DIR}/pulse-repo-tier.sh}"

########################################
# Check whether a repo should be skipped this cycle based on its activity tier.
#
# Reads the tier via pulse-repo-tier.sh tier-of (cache-backed, < 1ms typical).
# Compares elapsed time since last full prefetch against the tier interval.
#
# Hot:  PULSE_TIER_HOT_INTERVAL=0 — never skip (every cycle)
# Warm: skip if elapsed < PULSE_TIER_WARM_INTERVAL (default 180s)
# Cold: skip if elapsed < PULSE_TIER_COLD_INTERVAL (default 600s)
#
# Feature-flag: returns 0 (proceed) immediately when
# PULSE_TIER_CLASSIFICATION_ENABLED is unset or 0.
#
# Arguments:
#   $1 - repo_slug (owner/repo)
#   $2 - state_file (optional; defaults to PULSE_TIER_LAST_CHECK_FILE)
#
# Exit codes:
#   0 - proceed with this repo (not skipped)
#   1 - skip this repo (tier interval not elapsed)
########################################
check_repo_tier_skip() {
	local slug="$1"
	local state_file="${2:-$PULSE_TIER_LAST_CHECK_FILE}"

	# Feature flag — enabled by default (set to 0 to disable for rollback)
	if [[ "${PULSE_TIER_CLASSIFICATION_ENABLED:-1}" != "1" ]]; then
		return 0
	fi

	local warm_interval="${PULSE_TIER_WARM_INTERVAL:-180}"
	local cold_interval="${PULSE_TIER_COLD_INTERVAL:-600}"

	# Get tier from cache (fast — reads local JSON file); default to warm on error.
	local tier
	tier="warm"
	if [[ -x "$PULSE_TIER_SCRIPT" ]]; then
		local _t
		_t=$("$PULSE_TIER_SCRIPT" tier-of "$slug" 2>/dev/null) || true
		# Accept only known tier values; anything else stays at the default.
		case "$_t" in hot|warm|cold) tier="$_t" ;; esac
	fi

	# Hot repos always proceed (no skip)
	if [[ "$tier" == "hot" ]]; then
		return 0
	fi

	# Determine minimum interval for this tier
	local min_interval=0
	case "$tier" in
		warm) min_interval="$warm_interval" ;;
		cold) min_interval="$cold_interval" ;;
		*)    return 0 ;;
	esac

	if [[ "$min_interval" -le 0 ]]; then
		return 0
	fi

	# Read last full prefetch epoch from state file
	local last_check=0
	if [[ -f "$state_file" ]] && command -v jq &>/dev/null; then
		local val
		val=$(jq -r --arg slug "$slug" '.last_check[$slug] // 0' "$state_file" 2>/dev/null)
		[[ "$val" =~ ^[0-9]+$ ]] && last_check="$val"
	fi

	local now elapsed
	now=$(date +%s)
	elapsed=$((now - last_check))

	if [[ "$elapsed" -lt "$min_interval" ]]; then
		echo "[pulse-wrapper] tier_skip repo=${slug} tier=${tier} interval=${min_interval}s elapsed=${elapsed}s" >>"$LOGFILE"
		return 1
	fi

	return 0
}

########################################
# Record the current epoch as the last full prefetch time for a repo (tier tracking).
# Uses atomic mktemp+mv pattern (same as update_repo_pulse_timestamp).
#
# Arguments:
#   $1 - repo_slug (owner/repo)
#   $2 - state_file (optional; defaults to PULSE_TIER_LAST_CHECK_FILE)
#
# Returns: 0 always (non-fatal)
########################################
update_repo_tier_check_timestamp() {
	local slug="$1"
	local state_file="${2:-$PULSE_TIER_LAST_CHECK_FILE}"

	command -v jq &>/dev/null || return 0

	local now
	now=$(date +%s)

	local existing='{}'
	if [[ -f "$state_file" ]]; then
		existing=$(jq '.' "$state_file" 2>/dev/null) || existing='{}'
		[[ -n "$existing" ]] || existing='{}'
	fi

	local state_dir
	state_dir="${state_file%/*}"
	[[ -d "$state_dir" ]] || mkdir -p "$state_dir" 2>/dev/null || true

	local tmp_state
	# t2997: drop .json — XXXXXX must be at end for BSD mktemp. This was the
	# canonical 142-spam-lines/day offender in pulse-wrapper.log (GH#21408).
	tmp_state=$(mktemp "${state_dir}/.pulse-tier-last-check-XXXXXX") || {
		echo "[pulse-wrapper] update_repo_tier_check_timestamp: mktemp failed for ${slug}" >>"$LOGFILE"
		return 0
	}

	if printf '%s' "$existing" | jq --arg slug "$slug" --argjson ts "$now" '
		if .last_check then .last_check[$slug] = $ts
		else .last_check = {($slug): $ts} end
	' >"$tmp_state" 2>/dev/null && jq empty "$tmp_state" 2>/dev/null; then
		mv "$tmp_state" "$state_file"
	else
		rm -f "$tmp_state"
		echo "[pulse-wrapper] WARNING: update_repo_tier_check_timestamp: jq produced invalid JSON for ${slug}" >>"$LOGFILE"
	fi
	return 0
}
