#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-prefetch-repo.sh — Per-repo prefetch orchestration helpers
# =============================================================================
# Pure-move sub-library split from pulse-prefetch-fetch.sh for GH#18400/t1987.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_PREFETCH_REPO_LOADED:-}" ]] && return 0
_PULSE_PREFETCH_REPO_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_PREFETCH_BOOL_TRUE=true
_PREFETCH_JSON_NULL=null
_PREFETCH_NONE_LINE="- None"

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

	local _cached_prs="" _cached_issues="" _cached_pr_count=0 _cached_issue_count=0
	_cached_prs=$(echo "$cache_entry" | jq -c '.prs // []' 2>/dev/null) || _cached_prs="[]"
	_cached_issues=$(echo "$cache_entry" | jq -c '.issues // []' 2>/dev/null) || _cached_issues="[]"
	_cached_pr_count=$(echo "$_cached_prs" | jq 'length' 2>/dev/null) || _cached_pr_count=0
	[[ "$_cached_pr_count" =~ ^[0-9]+$ ]] || _cached_pr_count=0
	_cached_issues=$(echo "$_cached_issues" | _prefetch_open_issues_only)
	_cached_issue_count=$(echo "$_cached_issues" | jq 'length' 2>/dev/null) || _cached_issue_count=0
	[[ "$_cached_issue_count" =~ ^[0-9]+$ ]] || _cached_issue_count=0

	# Replay cached PR section
	echo "### Open PRs (${_cached_pr_count}) [cached]"
	if [[ "$_cached_pr_count" -gt 0 ]]; then
		echo "$_cached_prs" | jq -r '.[] | "- PR #\(.number): \(.title) [review: \(.reviewDecision // "NONE")] [updated: \(.updatedAt)]"'
	else
		echo "$_PREFETCH_NONE_LINE"
	fi
	echo ""

	# Checks enrichment: always run for repos with cached PRs > 0.
	# Cached PRs may be from a pre-GH#21799 cache that lacks .headRefOid;
	# the REST batch helper returns "[]" gracefully in that case, and the
	# next full sweep will repopulate with .headRefOid included.
	if [[ "$_cached_pr_count" -gt 0 ]]; then
		local _checks_json=""
		_checks_json=$(_prefetch_prs_enrich_checks "$slug" "$_cached_prs")
		if [[ -n "$_checks_json" && "$_checks_json" != "[]" && "$_checks_json" != "$_PREFETCH_JSON_NULL" ]]; then
			echo "### PR Check Status (live)"
			echo "$_checks_json" | jq -r '.[] | "- PR #\(.number): \(.status // "unknown")"' 2>/dev/null || true
			echo ""
		fi
	fi

	# Skip daily cap — unchanged repos don't create PRs
	echo "### Daily PR Cap [cached]"
	echo "- Skipped (idle repo, no new PRs expected)"
	echo ""

	# Replay cached issue sections using same filter logic as _prefetch_repo_issues
	# GH#20048: shared helper replaces inline jq non-task filter
	local _filtered_cached="" _disp_json="" _sweep_json="" _disp_count=0 _sweep_count=0
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
		echo "$_PREFETCH_NONE_LINE"
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

#######################################
# Build a per-repo prefetch cache entry without passing large JSON via argv.
#
# Large PR/issue arrays can exceed Linux MAX_ARG_STRLEN when passed through
# jq --argjson. Store them in temp files and load with --slurpfile instead.
#
# Arguments:
#   $1 - last_prefetch ISO timestamp
#   $2 - last_full_sweep ISO timestamp
#   $3 - state fingerprint
#   $4 - PR JSON array
#   $5 - issue JSON array
# Outputs: JSON cache entry object
#######################################
_prefetch_build_cache_entry() {
	local now_iso="$1"
	local last_full_sweep="$2"
	local fingerprint="$3"
	local prs_json="$4"
	local issues_json="$5"

	[[ -n "$prs_json" && "$prs_json" != "$_PREFETCH_JSON_NULL" ]] || prs_json="[]"
	[[ -n "$issues_json" && "$issues_json" != "$_PREFETCH_JSON_NULL" ]] || issues_json="[]"

	local prs_file="" issues_file=""
	prs_file=$(mktemp) || return 1
	issues_file=$(mktemp) || {
		rm -f "$prs_file"
		return 1
	}

	if ! printf '%s' "$prs_json" >"$prs_file"; then
		rm -f "$prs_file" "$issues_file"
		return 1
	fi
	if ! printf '%s' "$issues_json" >"$issues_file"; then
		rm -f "$prs_file" "$issues_file"
		return 1
	fi

	local jq_output="" jq_status=0
	jq_output=$(jq -n \
		--arg now "$now_iso" \
		--arg lfs "$last_full_sweep" \
		--arg fp "$fingerprint" \
		--slurpfile prs "$prs_file" \
		--slurpfile issues "$issues_file" \
		'{last_prefetch: $now, last_full_sweep: $lfs, state_fingerprint: $fp, prs: ($prs[0] // []), issues: ($issues[0] // [])}') || jq_status=$?
	rm -f "$prs_file" "$issues_file"
	[[ "$jq_status" -eq 0 ]] || return "$jq_status"
	printf '%s\n' "$jq_output"
	return 0
}

#######################################
# Emit cached repo output for tier-skipped repos without making GitHub API calls.
# Arguments: $1=slug, $2=path, $3=outfile
#######################################
_prefetch_single_repo_tier_skip() {
	local slug="$1"
	local path="$2"
	local outfile="$3"

	# Tier skip: emit cached data so the state file still has an entry for this
	# repo, then return without making any gh API calls.
	local _tier_cache
	_tier_cache=$(_prefetch_cache_get "$slug")
	{
		echo "## ${slug} (${path})"
		echo ""
		echo "> **Tier skip** — this repo is below hot tier and was checked recently."
		echo "> Using cached state from last full prefetch."
		echo ""
		if [[ -n "$_tier_cache" ]]; then
			_prefetch_single_repo_idle_skip "$slug" "$_tier_cache"
		else
			echo "### Open PRs [tier-skipped, no cache]"
			echo "$_PREFETCH_NONE_LINE"
			echo ""
			echo "### Open Issues [tier-skipped, no cache]"
			echo "$_PREFETCH_NONE_LINE"
			echo ""
		fi
	} >"$outfile"
	echo "[pulse-wrapper] _prefetch_single_repo: TIER SKIP for ${slug} — cached data replayed" >>"$LOGFILE"
	_PULSE_HEALTH_IDLE_REPO_SKIPS=$((_PULSE_HEALTH_IDLE_REPO_SKIPS + 1))
	return 0
}

#######################################
# Determine delta/full sweep mode for one repo.
# Arguments: $1=slug, $2=cache_entry
# Sets: PREFETCH_SWEEP_MODE
#######################################
_prefetch_single_repo_sweep_mode() {
	local slug="$1"
	local cache_entry="$2"

	PREFETCH_SWEEP_MODE="delta"
	if _prefetch_needs_full_sweep "$cache_entry"; then
		PREFETCH_SWEEP_MODE="$_PREFETCH_ISSUE_SWEEP_FULL"
		echo "[pulse-wrapper] _prefetch_single_repo: full sweep for ${slug}" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] _prefetch_single_repo: delta prefetch for ${slug}" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Detect whether cached repo state can be replayed.
# Arguments: $1=slug, $2=cache_entry, $3=sweep_mode
# Sets: PREFETCH_CACHE_HIT, PREFETCH_SWEEP_MODE
#######################################
_prefetch_single_repo_cache_decision() {
	local slug="$1"
	local cache_entry="$2"
	local sweep_mode="$3"
	PREFETCH_SWEEP_MODE="$sweep_mode"

	PREFETCH_CACHE_HIT="false"
	if _prefetch_detect_cache_hit "$slug" "$cache_entry"; then
		PREFETCH_CACHE_HIT="true"
		echo "[pulse-wrapper] _prefetch_single_repo: STATE CACHE HIT for ${slug} (fingerprint=${PREFETCH_CURRENT_FINGERPRINT})" >>"$LOGFILE"
	fi
	if [[ "$PREFETCH_CACHE_HIT" == "$_PREFETCH_BOOL_TRUE" ]] && echo "$cache_entry" | _prefetch_cache_entry_issues_lack_state; then
		PREFETCH_CACHE_HIT="false"
		PREFETCH_SWEEP_MODE="$_PREFETCH_ISSUE_SWEEP_FULL"
		echo "[pulse-wrapper] _prefetch_single_repo: ignoring issue cache hit for ${slug} because cached issue schema lacks state" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Render one repo prefetch block to its output file.
# Arguments: $1=slug, $2=path, $3=outfile, $4=cache_entry, $5=sweep_mode, $6=cache_hit
#######################################
_prefetch_single_repo_write_output() {
	local slug="$1"
	local path="$2"
	local outfile="$3"
	local cache_entry="$4"
	local sweep_mode="$5"
	local cache_hit="$6"

	{
		echo "## ${slug} (${path})"
		echo ""
		if [[ "$cache_hit" == "$_PREFETCH_BOOL_TRUE" ]]; then
			_prefetch_single_repo_idle_skip "$slug" "$cache_entry"
		else
			_prefetch_repo_prs "$slug" "$cache_entry" "$sweep_mode"
			_prefetch_repo_daily_cap "$slug"
			_prefetch_repo_issues "$slug" "$cache_entry" "$sweep_mode"
		fi
	} >"$outfile"
	return 0
}

#######################################
# Persist fresh cache entry for one repo after prefetch output is generated.
# Arguments: $1=slug, $2=cache_entry, $3=sweep_mode
#######################################
_prefetch_single_repo_update_cache() {
	local slug="$1"
	local cache_entry="$2"
	local sweep_mode="$3"

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
	if [[ "$sweep_mode" == "$_PREFETCH_ISSUE_SWEEP_FULL" ]]; then
		new_entry=$(_prefetch_build_cache_entry \
			"$now_iso" "$now_iso" "$fingerprint" \
			"${PREFETCH_UPDATED_PRS:-[]}" "${PREFETCH_UPDATED_ISSUES:-[]}") || new_entry=""
	else
		local last_full_sweep
		last_full_sweep=$(printf '%s\n' "$cache_entry" | jq -r '.last_full_sweep // ""') || last_full_sweep=""
		new_entry=$(_prefetch_build_cache_entry \
			"$now_iso" "$last_full_sweep" "$fingerprint" \
			"${PREFETCH_UPDATED_PRS:-[]}" "${PREFETCH_UPDATED_ISSUES:-[]}") || new_entry=""
	fi
	if [[ -n "$new_entry" && "$new_entry" != "$_PREFETCH_JSON_NULL" ]]; then
		_prefetch_cache_set "$slug" "$new_entry"
	else
		echo "[pulse-wrapper] _prefetch_single_repo: failed to build cache entry for ${slug}" >>"$LOGFILE"
	fi
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
		_prefetch_single_repo_tier_skip "$slug" "$path" "$outfile"
		return 0
	fi

	# Record that we are doing a full prefetch for this repo (for tier interval tracking).
	update_repo_tier_check_timestamp "$slug"

	# GH#15286: Determine sweep mode from cache
	local cache_entry
	cache_entry=$(_prefetch_cache_get "$slug")
	_prefetch_single_repo_sweep_mode "$slug" "$cache_entry"
	local sweep_mode="$PREFETCH_SWEEP_MODE"

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
	_prefetch_single_repo_cache_decision "$slug" "$cache_entry" "$sweep_mode"
	local cache_hit="$PREFETCH_CACHE_HIT"
	sweep_mode="$PREFETCH_SWEEP_MODE"

	_prefetch_single_repo_write_output "$slug" "$path" "$outfile" "$cache_entry" "$sweep_mode" "$cache_hit"
	_prefetch_single_repo_update_cache "$slug" "$cache_entry" "$sweep_mode"

	return 0
}
