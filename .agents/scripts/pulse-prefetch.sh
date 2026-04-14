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
#   - _prefetch_cache_get
#   - _prefetch_cache_set
#   - _prefetch_needs_full_sweep
#   - _prefetch_prs_try_delta
#   - _prefetch_prs_enrich_checks
#   - _prefetch_prs_format_output
#   - _prefetch_repo_prs
#   - _prefetch_repo_daily_cap
#   - _prefetch_issues_try_delta
#   - _prefetch_repo_issues
#   - _prefetch_single_repo
#   - _wait_parallel_pids
#   - _assemble_state_file
#   - _run_prefetch_step
#   - _append_prefetch_sub_helpers
#   - check_repo_pulse_schedule
#   - prefetch_state
#   - prefetch_missions
#   - prefetch_active_workers
#   - prefetch_ci_failures
#   - prefetch_hygiene
#   - prefetch_contribution_watch
#   - prefetch_foss_scan
#   - prefetch_triage_review_status
#   - prefetch_needs_info_replies
#   - prefetch_gh_failure_notifications
#
# Pure move from pulse-wrapper.sh. Byte-identical function bodies.
# Simplification deferred to Phase 12.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_PREFETCH_LOADED:-}" ]] && return 0
_PULSE_PREFETCH_LOADED=1

# =============================================================================
# GH#18979 (t2097): Rate-limit detection helpers
#
# When GitHub's GraphQL budget is exhausted (5000/hr), `gh` commands return
# empty results with an error on stderr. The existing prefetch error handlers
# swallow this into a `"[]"` fallback, which makes the pulse run a full cycle
# on empty data while holding the instance lock ~3 min. These helpers detect
# rate-limit errors at each prefetch site, write a shared flag file, and let
# `_preflight_prefetch_and_scope` abort the cycle cleanly via its existing
# return-1 path.
#
# Non-rate-limit errors (network blips, 5xx) still fall back to `"[]"` and
# continue — only exhaustion, where empty data is indistinguishable from a
# quiet backlog, triggers the cycle abort.
# =============================================================================

#######################################
# Classify a gh CLI stderr blob as a rate-limit exhaustion error.
#
# gh surfaces GraphQL / REST budget exhaustion in several forms depending on
# which endpoint triggered it. This helper matches the common phrases
# case-insensitively. The list is intentionally narrow — false positives
# would turn transient network blips into cycle aborts.
#
# Arguments:
#   $1 - path to a stderr file captured from `gh` (typically via `2>"$err"`)
# Returns:
#   0 if stderr indicates rate-limit exhaustion
#   1 otherwise (file missing, empty, or unrelated error)
#######################################
_pulse_gh_err_is_rate_limit() {
	local err_file="$1"
	[[ -n "$err_file" && -s "$err_file" ]] || return 1
	grep -qiE 'API rate limit exceeded|rate limit exceeded for|was submitted too quickly|secondary rate limit|GraphQL: API rate limit|You have exceeded a secondary rate limit' "$err_file"
}

#######################################
# Mark the current cycle as rate-limited.
#
# Writes a timestamp + context line to the flag file. Idempotent — if the
# flag already exists from an earlier prefetch site in the same cycle,
# append the new context so postmortem logs show all affected sites.
# Also emits a loud, greppable log line at the site of detection.
#
# Arguments:
#   $1 - context string (function name + repo slug)
#######################################
_pulse_mark_rate_limited() {
	local context="$1"
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	mkdir -p "$(dirname "$PULSE_RATE_LIMIT_FLAG")" 2>/dev/null || true
	printf '%s %s\n' "$ts" "$context" >>"$PULSE_RATE_LIMIT_FLAG"
	echo "[pulse-wrapper] GraphQL RATE_LIMIT_EXHAUSTED during ${context}" >>"$LOGFILE"
	return 0
}

#######################################
# Check if a repo's cached issues contain any items with a given label.
# Used by NMR and needs-info scans to skip repos with 0 matching items.
#
# Arguments:
#   $1 - repo slug
#   $2 - label name to check for
# Returns:
#   0 if cached count > 0 or no cache available (proceed with live query)
#   1 if cached count == 0 (safe to skip)
#######################################
_prefetch_cached_label_count_is_zero() {
	local slug="$1"
	local label="$2"
	local cache_entry cached_count
	cache_entry=$(_prefetch_cache_get "$slug" 2>/dev/null) || cache_entry=""
	[[ -n "$cache_entry" ]] || return 0 # no cache = proceed
	cached_count=$(echo "$cache_entry" | jq --arg l "$label" \
		'[.issues // [] | .[] | select(.labels | map(.name) | index($l))] | length' 2>/dev/null) || return 0
	[[ "$cached_count" == "0" ]] && return 1
	return 0
}

# =============================================================================
# t2041: Budget-aware LLM sweep — state fingerprint, hygiene anomalies,
# cache-hit detection. See .agents/reference/pulse-llm-budget.md and
# .agents/configs/pulse-sweep-budget.json for the design contract.
# =============================================================================

# Default token budget values. These are the fallback when
# .agents/configs/pulse-sweep-budget.json is unavailable or missing
# keys — `_load_pulse_sweep_budget_config` overlays the JSON values.
: "${PULSE_SWEEP_TOKEN_BUDGET:=3000}"
: "${PULSE_SWEEP_MAX_EVENTS_PER_PASS:=50}"
: "${PULSE_SWEEP_DEFERRAL_PROMOTION_THRESHOLD:=3}"
: "${PULSE_SWEEP_VERIFICATION_QUERY_LIMIT:=5}"
: "${PULSE_SWEEP_CACHE_HIT_ENABLED:=true}"

# Load the budget config once per process. Called lazily from the t2041
# helpers. Reads `.agents/configs/pulse-sweep-budget.json` relative to
# the aidevops repo deploy. Per-repo overrides override default values;
# falls back to existing env vars on any read failure (fail-open).
_PULSE_SWEEP_BUDGET_LOADED="${_PULSE_SWEEP_BUDGET_LOADED:-false}"
_load_pulse_sweep_budget_config() {
	[[ "$_PULSE_SWEEP_BUDGET_LOADED" == "true" ]] && return 0
	_PULSE_SWEEP_BUDGET_LOADED=true

	local config_file=""
	# Prefer deployed path (runtime). Fall back to repo path (tests).
	if [[ -f "${HOME}/.aidevops/agents/configs/pulse-sweep-budget.json" ]]; then
		config_file="${HOME}/.aidevops/agents/configs/pulse-sweep-budget.json"
	elif [[ -n "${AIDEVOPS_REPO_ROOT:-}" && -f "${AIDEVOPS_REPO_ROOT}/.agents/configs/pulse-sweep-budget.json" ]]; then
		config_file="${AIDEVOPS_REPO_ROOT}/.agents/configs/pulse-sweep-budget.json"
	fi
	[[ -f "$config_file" ]] || return 0
	jq empty "$config_file" 2>/dev/null || return 0

	local _v
	_v=$(jq -r '.default.token_budget // empty' "$config_file" 2>/dev/null)
	[[ "$_v" =~ ^[0-9]+$ ]] && PULSE_SWEEP_TOKEN_BUDGET="$_v"
	_v=$(jq -r '.default.max_events_per_pass // empty' "$config_file" 2>/dev/null)
	[[ "$_v" =~ ^[0-9]+$ ]] && PULSE_SWEEP_MAX_EVENTS_PER_PASS="$_v"
	_v=$(jq -r '.default.deferral_promotion_threshold // empty' "$config_file" 2>/dev/null)
	[[ "$_v" =~ ^[0-9]+$ ]] && PULSE_SWEEP_DEFERRAL_PROMOTION_THRESHOLD="$_v"
	_v=$(jq -r '.default.verification_query_limit // empty' "$config_file" 2>/dev/null)
	[[ "$_v" =~ ^[0-9]+$ ]] && PULSE_SWEEP_VERIFICATION_QUERY_LIMIT="$_v"
	_v=$(jq -r '.default.state_fingerprint_cache_hit_enabled // empty' "$config_file" 2>/dev/null)
	[[ "$_v" == "true" || "$_v" == "false" ]] && PULSE_SWEEP_CACHE_HIT_ENABLED="$_v"

	return 0
}

#######################################
# t2041 Layer 1: Compute a short deterministic fingerprint of a repo's
# LLM-observable state.
#
# The fingerprint is a SHA-256 of the canonicalized set of:
#   - issues: (number, labels_sorted, assignees_sorted, updatedAt)
#   - PRs:    (number, labels_sorted, assignees_sorted, reviewDecision,
#              mergeable, updatedAt)
# across all open issues and PRs. PR state must be in the fingerprint so
# PR churn (review rotation, CI status change, labels) invalidates the
# cache — if PRs were excluded, the cache would say "clean" even when
# a PR was ready to merge (CodeRabbit review on PR #18546).
#
# Arguments:
#   $1 - repo slug (owner/repo)
# Outputs:
#   16-char hex fingerprint on stdout, empty string on error
# Returns: 0 always (fail-open)
#######################################
_compute_repo_state_fingerprint() {
	local slug="$1"
	[[ -n "$slug" ]] || {
		echo ""
		return 0
	}

	local limit="${PULSE_QUEUED_SCAN_LIMIT:-200}"

	local issues_json prs_json
	local issues_ok=false prs_ok=false
	issues_json=$(gh issue list --repo "$slug" --state open \
		--json number,labels,assignees,updatedAt \
		--limit "$limit" 2>/dev/null) && issues_ok=true
	prs_json=$(gh pr list --repo "$slug" --state open \
		--json number,labels,assignees,reviewDecision,mergeable,updatedAt \
		--limit "$limit" 2>/dev/null) && prs_ok=true

	# Fail-open: if BOTH fetches failed entirely (not just returned empty
	# lists from successful fetches), return an empty fingerprint so the
	# caller falls through to the existing Layer 2 delta prefetch. A
	# single-side failure still produces a usable fingerprint because
	# t2041's verification query is a second check — worst case we miss
	# one churn cycle, never worse than today's behaviour.
	if [[ "$issues_ok" != "true" && "$prs_ok" != "true" ]]; then
		echo ""
		return 0
	fi

	[[ -n "$issues_json" && "$issues_json" != "null" ]] || issues_json="[]"
	[[ -n "$prs_json" && "$prs_json" != "null" ]] || prs_json="[]"

	# Canonicalize both lists. jq --argjson merges the PR list into the
	# top-level object so the hash covers both.
	local canon
	canon=$(jq -cSn \
		--argjson issues "$issues_json" \
		--argjson prs "$prs_json" '
		{
			issues: ($issues | sort_by(.number) | map({
				n: .number,
				l: ([.labels[].name] | sort),
				a: ([.assignees[].login] | sort),
				u: .updatedAt
			})),
			prs: ($prs | sort_by(.number) | map({
				n: .number,
				l: ([.labels[].name] | sort),
				a: ([.assignees[].login] | sort),
				r: .reviewDecision,
				m: .mergeable,
				u: .updatedAt
			}))
		}
	' 2>/dev/null) || canon=""
	[[ -n "$canon" ]] || {
		echo ""
		return 0
	}

	# SHA-256 truncated to 16 chars.
	local hash
	if command -v shasum >/dev/null 2>&1; then
		hash=$(printf '%s' "$canon" | shasum -a 256 2>/dev/null | awk '{print substr($1,1,16)}')
	elif command -v sha256sum >/dev/null 2>&1; then
		hash=$(printf '%s' "$canon" | sha256sum 2>/dev/null | awk '{print substr($1,1,16)}')
	else
		hash=""
	fi
	echo "$hash"
	return 0
}

#######################################
# t2041 Layer 1: Run the cheap verification queries.
#
# Returns 0 (unchanged) only if BOTH `gh issue list --search "updated:>ISO"`
# AND `gh pr list --search "updated:>ISO"` return empty results. Returns 1
# if anything has changed since ISO or any query fails (fail-closed — force
# fresh fetch on any doubt).
#
# The PR-side verification is critical: without it, cache-hit cycles
# would continue serving stale PR state even when a PR was ready for
# merge (CodeRabbit review on PR #18546).
#
# Arguments:
#   $1 - repo slug
#   $2 - last_pass_iso (from cache)
#######################################
_verify_repo_state_unchanged() {
	local slug="$1"
	local last_pass_iso="$2"
	[[ -n "$slug" && -n "$last_pass_iso" && "$last_pass_iso" != "null" ]] || return 1
	_load_pulse_sweep_budget_config
	local verif_limit="${PULSE_SWEEP_VERIFICATION_QUERY_LIMIT:-5}"

	# Issue-side verification
	local changed_json count
	changed_json=$(gh issue list --repo "$slug" --state open \
		--search "updated:>${last_pass_iso}" \
		--json number --limit "$verif_limit" 2>/dev/null) || return 1
	[[ -n "$changed_json" && "$changed_json" != "null" ]] || return 1
	count=$(printf '%s' "$changed_json" | jq 'length' 2>/dev/null) || count=""
	[[ "$count" =~ ^[0-9]+$ ]] || return 1
	[[ "$count" -eq 0 ]] || return 1

	# PR-side verification — same bound, same fail-closed semantics
	changed_json=$(gh pr list --repo "$slug" --state open \
		--search "updated:>${last_pass_iso}" \
		--json number --limit "$verif_limit" 2>/dev/null) || return 1
	[[ -n "$changed_json" && "$changed_json" != "null" ]] || return 1
	count=$(printf '%s' "$changed_json" | jq 'length' 2>/dev/null) || count=""
	[[ "$count" =~ ^[0-9]+$ ]] || return 1
	[[ "$count" -eq 0 ]] || return 1

	return 0
}

#######################################
# t2041: Emit the Hygiene Anomalies section to stdout.
#
# Reads the counter file written by _normalize_label_invariants (t2040)
# in pulse-issue-reconcile.sh. Zero anomalies = one line (literal
# "## Hygiene Anomalies\n\nNone — label invariants clean.\n"). Nonzero
# anomalies emit a call-to-action with the counts.
#
# No arguments. Output: markdown section on stdout.
#######################################
prefetch_hygiene_anomalies() {
	local hostname_short
	hostname_short=$(hostname -s 2>/dev/null || echo unknown)
	local counters_file="${HOME}/.aidevops/cache/pulse-label-invariants.${hostname_short}.json"

	echo "## Hygiene Anomalies"
	echo ""

	if [[ ! -f "$counters_file" ]]; then
		echo "Counter file not yet written — first cycle after t2040 deploy."
		echo ""
		return 0
	fi

	local status_fixed tier_fixed triage_missing ts checked
	status_fixed=$(jq -r '.status_fixed // 0' "$counters_file" 2>/dev/null) || status_fixed=0
	tier_fixed=$(jq -r '.tier_fixed // 0' "$counters_file" 2>/dev/null) || tier_fixed=0
	triage_missing=$(jq -r '.triage_missing // 0' "$counters_file" 2>/dev/null) || triage_missing=0
	ts=$(jq -r '.timestamp // ""' "$counters_file" 2>/dev/null) || ts=""
	checked=$(jq -r '.checked // 0' "$counters_file" 2>/dev/null) || checked=0

	if [[ "$status_fixed" -eq 0 && "$tier_fixed" -eq 0 && "$triage_missing" -eq 0 ]]; then
		echo "None — label invariants clean (checked=${checked} at ${ts})."
		echo ""
		return 0
	fi

	echo "Label invariant reconciler detected anomalies on last pass (${ts}):"
	echo ""
	if [[ "$status_fixed" -gt 0 ]]; then
		echo "- **${status_fixed} issues** had multiple \`status:*\` labels (reconciled via precedence)"
	fi
	if [[ "$tier_fixed" -gt 0 ]]; then
		echo "- **${tier_fixed} issues** had multiple \`tier:*\` labels (reconciled via rank)"
	fi
	if [[ "$triage_missing" -gt 0 ]]; then
		echo "- **${triage_missing} issues** marked \`origin:interactive\` but missing tier/auto-dispatch/status (need maintainer triage)"
	fi
	echo ""
	echo "If non-zero on consecutive cycles, investigate the source of the pollution —"
	echo "a write path is not using \`set_issue_status\` or is concatenating tier labels."
	echo ""
	return 0
}

#######################################
# t2041 Layer 1: Detect cache hit for a repo.
#
# Returns 0 (hit — LLM can skip deep analysis) if:
#   1. Cache entry has a state_fingerprint field
#   2. Current fingerprint equals cached fingerprint
#   3. Verification query confirms no changes since last_prefetch
# Returns 1 (miss — run full analysis) otherwise.
#
# Arguments:
#   $1 - repo slug
#   $2 - cache entry JSON (from _prefetch_cache_get)
#   $3 - output variable name: caller reads PREFETCH_CURRENT_FINGERPRINT
#        after return (bash 3.2 — no namerefs)
#######################################
_prefetch_detect_cache_hit() {
	local slug="$1"
	local cache_entry="$2"

	PREFETCH_CURRENT_FINGERPRINT=""

	# Compute the current fingerprint unconditionally — we need it for
	# the cache write at end-of-pass even on a miss.
	PREFETCH_CURRENT_FINGERPRINT=$(_compute_repo_state_fingerprint "$slug")
	[[ -n "$PREFETCH_CURRENT_FINGERPRINT" ]] || return 1

	local cached_fp
	cached_fp=$(echo "$cache_entry" | jq -r '.state_fingerprint // ""' 2>/dev/null) || cached_fp=""
	[[ -n "$cached_fp" && "$cached_fp" != "null" ]] || return 1
	[[ "$cached_fp" == "$PREFETCH_CURRENT_FINGERPRINT" ]] || return 1

	local last_prefetch
	last_prefetch=$(echo "$cache_entry" | jq -r '.last_prefetch // ""' 2>/dev/null) || last_prefetch=""
	_verify_repo_state_unchanged "$slug" "$last_prefetch" || return 1

	return 0
}

#######################################
# Load the prefetch cache for a single repo slug.
#
# Outputs the JSON object for the slug, or "{}" if not found/corrupt.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#######################################
_prefetch_cache_get() {
	local slug="$1"
	local cache_file="$PULSE_PREFETCH_CACHE_FILE"
	if [[ ! -f "$cache_file" ]]; then
		echo "{}"
		return 0
	fi
	local entry
	entry=$(jq -r --arg slug "$slug" '.[$slug] // {}' "$cache_file" 2>/dev/null) || entry="{}"
	[[ -n "$entry" ]] || entry="{}"
	echo "$entry"
	return 0
}

#######################################
# Write updated cache entry for a repo slug.
#
# Merges the new entry into the cache file atomically (write to tmp, mv).
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - JSON object to store for this slug
#######################################
_prefetch_cache_set() {
	local slug="$1"
	local entry="$2"
	local cache_file="$PULSE_PREFETCH_CACHE_FILE"
	local cache_dir
	cache_dir=$(dirname "$cache_file")
	mkdir -p "$cache_dir" 2>/dev/null || true

	local existing="{}"
	if [[ -f "$cache_file" ]]; then
		existing=$(cat "$cache_file" 2>/dev/null) || existing="{}"
		# Validate JSON; reset if corrupt
		echo "$existing" | jq empty 2>/dev/null || existing="{}"
	fi

	local tmp_file
	tmp_file=$(mktemp "${cache_dir}/.pulse-prefetch-cache.XXXXXX")
	echo "$existing" | jq --arg slug "$slug" --argjson entry "$entry" \
		'.[$slug] = $entry' >"$tmp_file" 2>/dev/null && mv "$tmp_file" "$cache_file" || {
		rm -f "$tmp_file"
		echo "[pulse-wrapper] _prefetch_cache_set: failed to write cache for ${slug}" >>"$LOGFILE"
	}
	return 0
}

#######################################
# Determine whether a full sweep is needed for a repo.
#
# Returns 0 (true) if:
#   - Cache entry missing or has no last_full_sweep
#   - last_full_sweep is older than PULSE_PREFETCH_FULL_SWEEP_INTERVAL seconds
#
# Arguments:
#   $1 - cache entry JSON (from _prefetch_cache_get)
#######################################
_prefetch_needs_full_sweep() {
	local entry="$1"
	local last_full_sweep
	last_full_sweep=$(echo "$entry" | jq -r '.last_full_sweep // ""' 2>/dev/null) || last_full_sweep=""
	if [[ -z "$last_full_sweep" ]]; then
		return 0 # No prior full sweep — must do one
	fi

	# Convert ISO timestamp to epoch — cross-platform (macOS/Linux)
	local last_epoch now_epoch
	# GH#17699: TZ=UTC required — macOS date interprets input as local time
	if [[ "$(uname)" == "Darwin" ]]; then
		last_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_full_sweep" "+%s" 2>/dev/null) || last_epoch=0
	else
		last_epoch=$(date -u -d "$last_full_sweep" +%s 2>/dev/null) || last_epoch=0
	fi
	now_epoch=$(date -u +%s)
	local age=$((now_epoch - last_epoch))
	if [[ "$age" -ge "$PULSE_PREFETCH_FULL_SWEEP_INTERVAL" ]]; then
		return 0 # Sweep interval elapsed
	fi
	return 1 # Delta is sufficient
}

#######################################
# Print the Open PRs section for a repo (GH#5627, GH#15286)
#
# Fetches open PRs and emits a markdown section to stdout.
# Called from _prefetch_single_repo inside a subshell redirect.
#
# Delta prefetch (GH#15286): on non-full-sweep cycles, fetches only PRs
# updated since last_prefetch and merges into the cached full list.
# Falls back to full fetch if delta fails or cache is missing.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - cache entry JSON (from _prefetch_cache_get)
#   $3 - "full" for full sweep, "delta" for delta fetch
#   $4 - output variable name for updated prs JSON (nameref not available in bash 3.2;
#        caller reads PREFETCH_UPDATED_PRS after return)
#######################################
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
	delta_json=$(gh pr list --repo "$slug" --state open \
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
	checks_json=$(gh pr list --repo "$slug" --state open \
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
	local cache_entry="${2:-{}}"
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
		pr_json=$(gh pr list --repo "$slug" --state open \
			--json number,title,reviewDecision,updatedAt,headRefName,createdAt,author \
			--limit "$PULSE_PREFETCH_PR_LIMIT" 2>"$pr_err") || pr_json=""

		if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
			local err_msg
			err_msg=$(cat "$pr_err" 2>/dev/null || echo "unknown error")
			# GH#18979 (t2097): classify rate-limit errors and flag the cycle
			if _pulse_gh_err_is_rate_limit "$pr_err"; then
				_pulse_mark_rate_limited "_prefetch_repo_prs:${slug}"
			fi
			echo "[pulse-wrapper] _prefetch_repo_prs: gh pr list FAILED for ${slug}: ${err_msg}" >>"$LOGFILE"
			pr_json="[]"
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
	daily_cap_json=$(gh pr list --repo "$slug" --state all \
		--json createdAt --limit 200 2>"$daily_cap_err") || daily_cap_json="[]"
	if [[ -z "$daily_cap_json" || "$daily_cap_json" == "null" ]]; then
		local _daily_cap_err_msg
		_daily_cap_err_msg=$(cat "$daily_cap_err" 2>/dev/null || echo "unknown error")
		# GH#18979 (t2097): detect rate-limit exhaustion
		if _pulse_gh_err_is_rate_limit "$daily_cap_err"; then
			_pulse_mark_rate_limited "_prefetch_repo_daily_cap:${slug}"
		fi
		echo "[pulse-wrapper] _prefetch_repo_daily_cap: gh pr list FAILED for ${slug}: ${_daily_cap_err_msg}" >>"$LOGFILE"
		daily_cap_json="[]"
	fi
	rm -f "$daily_cap_err"
	local daily_pr_count
	daily_pr_count=$(echo "$daily_cap_json" | jq --arg today "$today_utc" \
		'[.[] | select(.createdAt | startswith($today))] | length') || daily_pr_count=0
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
	delta_json=$(gh issue list --repo "$slug" --state open \
		--json number,title,labels,updatedAt,assignees \
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

_prefetch_repo_issues() {
	local slug="$1"
	local cache_entry="${2:-{}}"
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
		issue_json=$(gh issue list --repo "$slug" --state open \
			--json number,title,labels,updatedAt,assignees \
			--limit "$PULSE_PREFETCH_ISSUE_LIMIT" 2>"$issue_err") || issue_json=""

		if [[ -z "$issue_json" || "$issue_json" == "null" ]]; then
			local issue_err_msg
			issue_err_msg=$(cat "$issue_err" 2>/dev/null || echo "unknown error")
			# GH#18979 (t2097): detect rate-limit exhaustion
			if _pulse_gh_err_is_rate_limit "$issue_err"; then
				_pulse_mark_rate_limited "_prefetch_repo_issues:${slug}"
			fi
			echo "[pulse-wrapper] _prefetch_repo_issues: gh issue list FAILED for ${slug}: ${issue_err_msg}" >>"$LOGFILE"
			issue_json="[]"
		fi
	fi
	rm -f "$issue_err"

	# Export updated issue list for cache update by caller (Bash 3.2: no namerefs)
	PREFETCH_UPDATED_ISSUES="$issue_json"

	# Remove issues with non-dispatchable labels (supervisor, tracking, review gates)
	local filtered_json
	filtered_json=$(echo "$issue_json" | jq '[.[] | select(.labels | map(.name) | (index("supervisor") or index("contributor") or index("persistent") or index("quality-review") or index("needs-maintainer-review") or index("routine-tracking") or index("on hold") or index("blocked")) | not)]')

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
		echo "_DO NOT create new issues for findings already covered below. Dispatch these as normal quality-debt/simplification-debt work._"
		echo "$sweep_tracked_json" | jq -r '.[] | "- Issue #\(.number): \(.title) [labels: \(if (.labels | length) == 0 then "none" else (.labels | map(.name) | join(", ")) end)] [assignees: \(if (.assignees | length) == 0 then "none" else (.assignees | map(.login) | join(", ")) end)]"'
		echo ""
	fi
	return 0
}

#######################################
# Fetch PR, issue, and daily-cap data for a single repo (GH#5627, GH#15286)
#
# Runs inside a subshell (called from prefetch_state parallel loop).
# Writes a compact markdown summary to the specified output file.
# Delegates to focused helpers for each data section.
#
# Delta prefetch (GH#15286): determines sweep mode from cache, calls helpers
# with cache entry, then updates the cache file with fresh data.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - repo path
#   $3 - output file path
#######################################

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
	local _disp_json _sweep_json _disp_count _sweep_count
	_disp_json=$(echo "$_cached_issues" | jq -c '[.[] | select(.labels | map(.name) | (index("supervisor") or index("contributor") or index("persistent") or index("quality-review") or index("needs-maintainer-review") or index("routine-tracking") or index("on hold") or index("blocked")) | not) | select(.labels | map(.name) | (index("source:quality-sweep") or index("source:review-feedback")) | not)]' 2>/dev/null) || _disp_json="[]"
	_sweep_json=$(echo "$_cached_issues" | jq -c '[.[] | select(.labels | map(.name) | (index("supervisor") or index("contributor") or index("persistent") or index("quality-review") or index("needs-maintainer-review") or index("routine-tracking") or index("on hold") or index("blocked")) | not) | select(.labels | map(.name) | (index("source:quality-sweep") or index("source:review-feedback")))]' 2>/dev/null) || _sweep_json="[]"
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
# Append sub-helper data sections to STATE_FILE (GH#5627)
#
# Runs each sub-helper with individual timeouts. If a helper times out,
# the pulse proceeds without that section — degraded but functional.
# Shell functions that only read local state run directly (instant).
#
# Arguments:
#   $1 - repo_entries (slug|path pairs, one per line)
#######################################
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
#######################################
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
# Pre-fetch active worker processes (t216, t1367)
#
# Captures a snapshot of running worker processes so the pulse agent
# can cross-reference open PRs with active workers. This is the
# deterministic data-fetch part — the intelligence about which PRs
# are orphaned stays in pulse.md.
#
# t1367: Also computes struggle_ratio for each worker with a worktree.
# High ratio = active but unproductive (thrashing). Informational only.
#
# Output: worker summary to stdout (appended to STATE_FILE by caller)
#######################################
# list_active_worker_processes: now provided by worker-lifecycle-common.sh (sourced above).
# Removed from pulse-wrapper.sh to eliminate divergence with stats-functions.sh.
# See worker-lifecycle-common.sh for the canonical implementation with:
#   - process chain deduplication (t5072)
#   - headless-runtime-helper.sh wrapper support (GH#12361, GH#14944)
#   - zombie/stopped process filtering (GH#6413)

prefetch_active_workers() {
	local worker_lines
	worker_lines=$(list_active_worker_processes || true)

	echo ""
	echo "# Active Workers"
	echo ""
	echo "Snapshot of running worker processes at $(date -u +%Y-%m-%dT%H:%M:%SZ)."
	echo "Use this to determine whether a PR has an active worker (not orphaned)."
	echo "Struggle ratio: messages/max(1,commits) — high ratio + time = thrashing. See pulse.md."
	echo ""

	if [[ -z "$worker_lines" ]]; then
		echo "- No active workers"
	else
		local count
		count=$(echo "$worker_lines" | wc -l | tr -d ' ')
		echo "### Running Workers ($count)"
		echo ""
		echo "$worker_lines" | while IFS= read -r line; do
			local pid etime cmd
			read -r pid etime cmd <<<"$line"

			# Compute elapsed seconds for struggle ratio.
			# This is the AUTHORITATIVE process age — use it for kill comments.
			# Do NOT compute duration from dispatch comment timestamps or
			# branch/worktree creation times, which may reflect prior attempts.
			local elapsed_seconds
			elapsed_seconds=$(_get_process_age "$pid")
			local formatted_duration
			formatted_duration=$(_format_duration "$elapsed_seconds")

			# Compute struggle ratio (t1367)
			local sr_result
			sr_result=$(_compute_struggle_ratio "$pid" "$elapsed_seconds" "$cmd")
			local sr_ratio sr_commits sr_messages sr_flag
			IFS='|' read -r sr_ratio sr_commits sr_messages sr_flag <<<"$sr_result"

			local sr_display=""
			if [[ "$sr_ratio" != "n/a" ]]; then
				sr_display=" [struggle_ratio: ${sr_ratio} (${sr_messages}msgs/${sr_commits}commits)"
				if [[ -n "$sr_flag" ]]; then
					sr_display="${sr_display} **${sr_flag}**"
				fi
				sr_display="${sr_display}]"
			fi

			echo "- PID $pid (process_uptime: ${formatted_duration}, elapsed_seconds: ${elapsed_seconds}): $cmd${sr_display}"
		done
	fi

	echo ""
	return 0
}

#######################################
# Pre-fetch CI failure patterns from notification mining (GH#4480)
#
# Runs gh-failure-miner-helper.sh prefetch to detect systemic CI
# failures across managed repos. The prefetch command mines ci_activity
# notifications (which contribution-watch-helper.sh explicitly excludes)
# and identifies checks that fail on multiple PRs — indicating workflow
# bugs rather than per-PR code issues.
#
# Previously used the removed 'scan' command (GH#4586). Now uses
# 'prefetch' which is the correct supported command.
#
# Output: CI failure summary to stdout (appended to STATE_FILE by caller)
#######################################
prefetch_ci_failures() {
	local miner_script="${SCRIPT_DIR}/gh-failure-miner-helper.sh"

	if [[ ! -x "$miner_script" ]]; then
		echo ""
		echo "# CI Failure Patterns: miner script not found"
		echo ""
		return 0
	fi

	# Guard: verify the helper supports the 'prefetch' command before calling.
	# If the contract drifts again, this produces a clear compatibility warning
	# rather than a silent [ERROR] Unknown command in the log.
	if ! "$miner_script" --help 2>&1 | grep -q 'prefetch'; then
		echo "[pulse-wrapper] gh-failure-miner-helper.sh does not support 'prefetch' command — skipping CI failure prefetch (compatibility warning)" >>"$LOGFILE"
		echo ""
		echo "# CI Failure Patterns: helper command contract mismatch (see pulse.log)"
		echo ""
		return 0
	fi

	# Run prefetch — outputs compact pulse-ready summary to stdout
	"$miner_script" prefetch \
		--pulse-repos \
		--since-hours "$GH_FAILURE_PREFETCH_HOURS" \
		--limit "$GH_FAILURE_PREFETCH_LIMIT" \
		--systemic-threshold "$GH_FAILURE_SYSTEMIC_THRESHOLD" \
		--max-run-logs "$GH_FAILURE_MAX_RUN_LOGS" 2>/dev/null || {
		echo ""
		echo "# CI Failure Patterns: prefetch failed (non-fatal)"
		echo ""
	}

	return 0
}

prefetch_hygiene() {
	local repos_json="${HOME}/.config/aidevops/repos.json"

	echo ""
	echo "# Repo Hygiene"
	echo ""
	echo "Non-deterministic cleanup candidates requiring LLM assessment."
	echo "Merged-PR worktrees and safe-to-drop stashes were already cleaned by the shell layer."
	echo ""

	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo "- repos.json not available — skipping hygiene prefetch"
		echo ""
		return 0
	fi

	local repo_paths
	repo_paths=$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | .path' "$repos_json" || echo "")

	local found_any=false

	local repo_path
	while IFS= read -r repo_path; do
		[[ -z "$repo_path" ]] && continue
		[[ ! -d "$repo_path/.git" ]] && continue

		local repo_name
		repo_name=$(basename "$repo_path")

		local repo_issues
		repo_issues=$(_check_repo_hygiene "$repo_path" "$repos_json")

		# Output repo section if any issues found
		if [[ -n "$repo_issues" ]]; then
			found_any=true
			echo "### ${repo_name}"
			echo -e "$repo_issues"
		fi
	done <<<"$repo_paths"

	if [[ "$found_any" == "false" ]]; then
		echo "- All repos clean — no hygiene issues detected"
		echo ""
	fi

	_scan_pr_salvage "$repos_json"

	return 0
}

#######################################
# Pre-fetch contribution watch scan results (t1419)
#
# Runs contribution-watch-helper.sh scan and appends a count-only
# summary to STATE_FILE. This is deterministic — only timestamps
# and authorship are checked, never comment bodies. The pulse agent
# sees "N external items need attention" without any untrusted content.
#
# Output: appends to STATE_FILE (called before prefetch_state writes it)
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
prefetch_contribution_watch() {
	local helper="${SCRIPT_DIR}/contribution-watch-helper.sh"
	if [[ ! -x "$helper" ]]; then
		return 0
	fi

	# Only run if state file exists (user has run 'seed' at least once)
	local cw_state="${HOME}/.aidevops/cache/contribution-watch.json"
	if [[ ! -f "$cw_state" ]]; then
		return 0
	fi

	local scan_output
	scan_output=$(bash "$helper" scan 2>/dev/null) || scan_output=""

	# Extract the machine-readable count
	local cw_count=0
	if [[ "$scan_output" =~ CONTRIBUTION_WATCH_COUNT=([0-9]+) ]]; then
		cw_count="${BASH_REMATCH[1]}"
	fi

	# Append to state file for the pulse agent (count only — no comment bodies)
	if [[ "$cw_count" -gt 0 ]]; then
		{
			echo ""
			echo "# External Contributions (t1419)"
			echo ""
			echo "${cw_count} external contribution(s) need your reply."
			echo "Run \`contribution-watch-helper.sh status\` in an interactive session for details."
			echo "**Do NOT fetch or process comment bodies in this pulse context.**"
			echo ""
		}
		echo "[pulse-wrapper] Contribution watch: ${cw_count} items need attention" >>"$LOGFILE"
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
		nmr_json=$(gh issue list --repo "$slug" --label "needs-maintainer-review" \
			--state open --json number,title,createdAt,updatedAt \
			--limit 50 2>"$nmr_err") || nmr_json="[]"
		if [[ -z "$nmr_json" || "$nmr_json" == "null" ]]; then
			local _nmr_err_msg
			_nmr_err_msg=$(cat "$nmr_err" 2>/dev/null || echo "unknown error")
			# GH#18979 (t2097): detect rate-limit exhaustion
			if _pulse_gh_err_is_rate_limit "$nmr_err"; then
				_pulse_mark_rate_limited "prefetch_triage_review_status:${slug}"
			fi
			echo "[pulse-wrapper] prefetch_triage_review_status: gh issue list FAILED for ${slug}: ${_nmr_err_msg}" >>"$LOGFILE"
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

#######################################
# Fetch status:needs-info issues for a single repo via gh issue list.
# Outputs JSON array to stdout; emits "[]" on any failure.
# Handles rate-limit detection and logs errors to LOGFILE.
#
# Arguments:
#   $1 - slug (owner/repo)
# Output: JSON array of issue objects
# Returns: 0 always (best-effort)
#######################################
_prefetch_ni_fetch_issues() {
	local slug="$1"
	local ni_err ni_json
	ni_err=$(mktemp)
	ni_json=$(gh issue list --repo "$slug" --label "status:needs-info" \
		--state open --json number,title,author,createdAt,updatedAt \
		--limit 50 2>"$ni_err") || ni_json="[]"
	if [[ -z "$ni_json" || "$ni_json" == "null" ]]; then
		local _ni_err_msg
		_ni_err_msg=$(cat "$ni_err" 2>/dev/null || echo "unknown error")
		# GH#18979 (t2097): detect rate-limit exhaustion
		if _pulse_gh_err_is_rate_limit "$ni_err"; then
			_pulse_mark_rate_limited "prefetch_needs_info_replies:${slug}"
		fi
		echo "[pulse-wrapper] prefetch_needs_info_replies: gh issue list FAILED for ${slug}: ${_ni_err_msg}" >>"$LOGFILE"
		ni_json="[]"
	fi
	rm -f "$ni_err"
	echo "$ni_json"
	return 0
}

#######################################
# Resolve the timestamp when status:needs-info was applied to an issue.
# Uses the GitHub timeline API; falls back to the issue's updatedAt field
# when the timeline call fails or returns null.
#
# Arguments:
#   $1 - slug     (owner/repo)
#   $2 - number   (issue number)
#   $3 - ni_json  (full issues JSON array)
#   $4 - i        (index into ni_json for this issue)
# Output: ISO-8601 date string
# Returns: 0 always
#######################################
_prefetch_ni_get_label_date() {
	local slug="$1"
	local number="$2"
	local ni_json="$3"
	local i="$4"
	local label_date api_ok=true
	label_date=$(gh api "repos/${slug}/issues/${number}/timeline" --paginate \
		--jq '[.[] | select(.event == "labeled" and .label.name == "status:needs-info")] | last | .created_at' \
		2>/dev/null) || api_ok=false
	if [[ "$api_ok" != true || -z "$label_date" || "$label_date" == "null" ]]; then
		# Fall back: use issue updatedAt as approximate label time
		label_date=$(echo "$ni_json" | jq -r ".[$i].updatedAt")
	fi
	echo "$label_date"
	return 0
}

#######################################
# Determine whether the issue author replied after status:needs-info was applied.
# Fetches all issue comments and compares the latest author comment date
# against the label application timestamp.
#
# GH#18554: uses --arg to safely pass $author into jq (avoids injection if
# login contains special chars).
#
# Arguments:
#   $1 - slug       (owner/repo)
#   $2 - number     (issue number)
#   $3 - author     (GitHub login of the issue author)
#   $4 - label_date (ISO-8601 timestamp when needs-info was applied)
# Output: "true" if author replied after label date, "false" otherwise
# Returns: 0 always
#######################################
_prefetch_ni_check_author_replied() {
	local slug="$1"
	local number="$2"
	local author="$3"
	local label_date="$4"
	local latest_author_comment_date=""
	latest_author_comment_date=$(gh api "repos/${slug}/issues/${number}/comments" --paginate 2>/dev/null |
		jq -r --arg author "$author" '.[] | select(.user.login == $author) | .created_at' \
			2>/dev/null | tail -n 1) || latest_author_comment_date=""
	if [[ -n "$latest_author_comment_date" && "$latest_author_comment_date" != "null" &&
		"$latest_author_comment_date" > "$label_date" ]]; then
		echo "true"
	else
		echo "false"
	fi
	return 0
}

#######################################
# Pre-fetch contributor reply status for status:needs-info issues
#
# For each pulse-enabled repo, finds issues with the status:needs-info
# label and checks whether the original issue author has commented since
# the label was applied. This enables the pulse to relabel issues back
# to needs-maintainer-review when the contributor provides the requested
# information.
#
# Arguments:
#   $1 - repo_entries (slug|path pairs, one per line)
# Output: needs-info reply status section to stdout
#######################################
prefetch_needs_info_replies() {
	local repo_entries="$1"
	local found_any=false
	local total_replied=0

	while IFS='|' read -r slug path; do
		[[ -n "$slug" ]] || continue

		# GH#18984 (t2098): skip repos with 0 cached needs-info issues
		if _prefetch_cached_label_count_is_zero "$slug" "status:needs-info"; then
			echo "[pulse-wrapper] prefetch_needs_info_replies: SKIP ${slug} — 0 needs-info issues in cache" >>"$LOGFILE"
			continue
		fi

		local ni_json ni_count
		ni_json=$(_prefetch_ni_fetch_issues "$slug")
		ni_count=$(echo "$ni_json" | jq 'length')
		[[ "$ni_count" -gt 0 ]] || continue

		if [[ "$found_any" == false ]]; then
			echo ""
			echo "# Needs Info — Contributor Reply Status"
			echo ""
			echo "Issues with \`status:needs-info\` label. For items marked **replied**, relabel to"
			echo "\`needs-maintainer-review\` so the triage pipeline re-evaluates with the new information."
			echo ""
			found_any=true
		fi

		echo "## ${slug}"
		echo ""

		local i=0
		while [[ "$i" -lt "$ni_count" ]]; do
			local number title author label_date author_replied status_label
			number=$(echo "$ni_json" | jq -r ".[$i].number")
			title=$(echo "$ni_json" | jq -r ".[$i].title")
			author=$(echo "$ni_json" | jq -r ".[$i].author.login")

			label_date=$(_prefetch_ni_get_label_date "$slug" "$number" "$ni_json" "$i")
			author_replied=$(_prefetch_ni_check_author_replied "$slug" "$number" "$author" "$label_date")

			if [[ "$author_replied" == true ]]; then
				status_label="replied"
				total_replied=$((total_replied + 1))
			else
				status_label="waiting"
			fi

			echo "- Issue #${number}: ${title} [author: @${author}] [status: **${status_label}**] [labeled: ${label_date}]"
			i=$((i + 1))
		done

		echo ""
	done <<<"$repo_entries"

	if [[ "$found_any" == true ]]; then
		echo "**Total contributor replies pending action: ${total_replied}**"
		echo ""
		echo "[pulse-wrapper] Needs-info reply status: ${total_replied} issues with contributor replies" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Pre-fetch failed notification summary (t3960)
#
# Uses gh-failure-miner-helper.sh to mine ci_activity notifications,
# cluster recurring failures, and append a compact summary to STATE_FILE.
# This gives the pulse early signal on systemic CI breakages.
#
# Returns: 0 always (best-effort)
#######################################
prefetch_gh_failure_notifications() {
	local helper="${SCRIPT_DIR}/gh-failure-miner-helper.sh"
	if [[ ! -x "$helper" ]]; then
		return 0
	fi

	local summary
	summary=$(bash "$helper" prefetch \
		--pulse-repos \
		--since-hours "$GH_FAILURE_PREFETCH_HOURS" \
		--limit "$GH_FAILURE_PREFETCH_LIMIT" \
		--systemic-threshold "$GH_FAILURE_SYSTEMIC_THRESHOLD" \
		--max-run-logs "$GH_FAILURE_MAX_RUN_LOGS" 2>/dev/null || true)

	if [[ -z "$summary" ]]; then
		return 0
	fi

	echo ""
	echo "$summary"
	echo "- action: for systemic clusters, create/update one bug+auto-dispatch issue per affected repo"
	echo ""
	echo "[pulse-wrapper] Failed-notification summary appended (hours=${GH_FAILURE_PREFETCH_HOURS}, threshold=${GH_FAILURE_SYSTEMIC_THRESHOLD})" >>"$LOGFILE"
	return 0
}
