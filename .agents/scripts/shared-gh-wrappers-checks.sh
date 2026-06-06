#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared GH Wrappers -- PR Check Status (REST check-suites/check-runs)
# =============================================================================
# REST-based PR check status helpers (GH#21799). Replaces the GraphQL
# `statusCheckRollup` field — the heaviest single field in the pulse's
# GraphQL payload — with per-PR REST calls that hit the separate REST
# budget pool (5000/hr, mostly unused) instead of the shared GraphQL pool.
#
# Why this exists:
#   - GraphQL `statusCheckRollup` is ~21KB per PR, ~230KB per pulse cycle
#     across 11 open PRs (cycle observed via `gh-api-instrument.sh report`).
#   - REST `/commits/{sha}/check-suites` is ~1.3KB per PR (~15x smaller),
#     uses a separate budget pool, and returns conclusion+status enough to
#     derive PASS/FAIL/PENDING.
#   - For consumers that need per-context names (required-status-checks
#     filtering, name-based check exclusions), `/commits/{sha}/check-runs`
#     is heavier (~111KB per PR) but still hits the separate REST pool —
#     and is only used in single-PR paths (merge gate, NMR recovery).
#
# Public API:
#   gh_pr_check_status_rest <slug> <sha>
#     → echoes "PASS" | "FAIL" | "PENDING" | "none"
#       Aggregate status derived from check-suites conclusions.
#       Use for any consumer that only needs the rolled-up state.
#
#   gh_pr_check_runs_rest <slug> <sha>
#     → echoes JSON array of check-runs ([{name,conclusion,status}, ...]).
#       Use when per-context filtering by name is required (e.g.
#       skip-by-name in NMR/merge-gate pipelines).
#
#   gh_pr_check_status_rest_batch <slug> <pr_json>
#     → echoes JSON array [{"number":N,"status":"..."},...].
#       Convenience for prefetch/capacity/governor consumers that fetch a
#       PR list (with .number and .headRefOid) and need each PR's
#       aggregated status.
#
# Usage: source "${SCRIPT_DIR}/shared-gh-wrappers-checks.sh"
#
# Dependencies:
#   - gh CLI (for `gh api`)
#   - jq
#   - bash 3.2+ (no associative arrays / nameref usage)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SHARED_GH_WRAPPERS_CHECKS_LIB_LOADED:-}" ]] && return 0
_SHARED_GH_WRAPPERS_CHECKS_LIB_LOADED=1

#######################################
# Internal: invoke a read-only `gh api` request with a wall-clock cap.
#
# Prefer the shared `_gh_with_timeout` wrapper when this sub-library is loaded
# through shared-gh-wrappers.sh. Keep a local fallback because some tests and
# single-purpose pulse helpers source shared-gh-wrappers-checks.sh directly.
#
# Args:
#   $1 - REST API endpoint
#   $@ - remaining gh api arguments
# Returns: passthrough command exit code (124 when coreutils timeout fires)
#######################################
_gh_checks_api_read() {
	local endpoint="$1"
	shift

	if declare -f _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read gh api "$endpoint" "$@"
		return $?
	fi

	local secs="${AIDEVOPS_GH_READ_TIMEOUT:-15}"
	if command -v timeout >/dev/null 2>&1; then
		timeout "$secs" gh api "$endpoint" "$@"
		return $?
	fi

	gh api "$endpoint" "$@"
	return $?
}

#######################################
# Aggregate PR check status via REST `/commits/{sha}/check-suites`.
#
# REST check-suites is ~15x smaller than GraphQL statusCheckRollup
# (~1.3KB vs ~21KB per PR) and uses the separate REST budget pool.
#
# Args:
#   $1 - repo slug (owner/repo)
#   $2 - commit SHA (PR's headRefOid)
#
# Output (stdout): one of "PASS", "FAIL", "PENDING", "none"
# Returns: 0 always (returns "none" on missing args / API error — fail-open
#          since callers treat "none" as "no checks recorded yet")
#######################################
gh_pr_check_status_rest() {
	local slug="$1"
	local sha="$2"

	if [[ -z "$slug" || -z "$sha" ]]; then
		echo "none"
		return 0
	fi

	# NOTE: variable is `_check_state` not `status` — zsh treats `status` as a
	# read-only special variable, which would silently fail under zsh-sourced
	# interactive use even though the script declares `#!/usr/bin/env bash`.
	local _check_state=""
	_check_state=$(_gh_checks_api_read "repos/${slug}/commits/${sha}/check-suites" --jq '
		if (.check_suites | length) == 0 then "none"
		elif (.check_suites | all(.conclusion == "success" or .conclusion == "skipped" or .conclusion == "neutral")) then "PASS"
		elif (.check_suites | any(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled")) then "FAIL"
		else "PENDING"
		end' 2>/dev/null) || _check_state=""

	_check_state="${_check_state:-none}"
	echo "$_check_state"
	return 0
}

#######################################
# Fetch all PR check states (check-runs + legacy status contexts) for a PR
# via REST `/commits/{sha}/check-runs` and `/commits/{sha}/status`.
#
# Heavier than check-suites (~111KB/PR) but returns per-context .name and
# .conclusion fields needed for name-based matching. Use ONLY in single-PR
# paths that need name-based filtering (required-status-check matching,
# named-check exclusions).
#
# Combines two endpoints because GitHub branch-protection required_status_checks
# can list either type:
#   - check-runs (GitHub Actions, Apps): `.name`, `.conclusion`, `.status`
#   - status contexts (legacy CI, repo statuses): `.context`, `.state`
# Status contexts are normalised to look like check-runs so consumers can
# match uniformly on `.name` and `.conclusion`.
#
# Args:
#   $1 - repo slug (owner/repo)
#   $2 - commit SHA
#
# Output (stdout): JSON array of normalised check entries:
#   [{"name":"...","conclusion":"success|failure|null","status":"..."}, ...]
#   Empty array "[]" on missing args / API error.
# Returns: 0 always
#######################################
gh_pr_check_runs_rest() {
	local slug="$1"
	local sha="$2"

	if [[ -z "$slug" || -z "$sha" ]]; then
		echo "[]"
		return 0
	fi

	# 1. Modern check-runs (GitHub Actions / GitHub Apps) — AUTHORITATIVE.
	# Almost all check signal in modern repos lives here. If this endpoint
	# fails, we emit empty so callers can fail-closed; /status alone is
	# insufficient signal for branch-protection gating.
	local runs=""
	runs=$(_gh_checks_api_read "repos/${slug}/commits/${sha}/check-runs" --paginate \
		--jq '[.check_runs[]? | {name, conclusion, status}]' 2>/dev/null) || runs=""

	if [[ -z "$runs" ]]; then
		# /check-runs unreachable or empty output — emit empty so callers
		# distinguish "fetch failed" from "no checks recorded".
		echo ""
		return 0
	fi

	# 2. Legacy combined status (third-party CI services, repo statuses) —
	# SUPPLEMENT only. Normalise each entry to the check-run shape so
	# consumers see a uniform `.name`/`.conclusion`/`.status` triple
	# regardless of source. state mapping: success→success,
	# failure/error→failure, pending→null + status="in_progress".
	local statuses=""
	# Normalise each status entry to the check-run shape.  jq variables
	# ($ok/$fail) avoid repeating "success"/"failure" literals three times
	# each across the file (string-literal ratchet gate).
	# shellcheck disable=SC2016  # $ok/$fail are jq variables, not bash expansions
	statuses=$(_gh_checks_api_read "repos/${slug}/commits/${sha}/status" \
		--jq '[.statuses[]? |
			"success" as $ok | "failure" as $fail |
			{
				name: .context,
				conclusion: (
					if .state == $ok
					then $ok
					elif .state == $fail or .state == "error"
					then $fail
					else null
					end
				),
				status: (
					if .state == "pending"
					then "in_progress"
					else "completed"
					end
				)
			}
		]' 2>/dev/null) || statuses=""

	# Concatenate possibly-multi-page check-runs output, then merge with
	# normalised statuses. `jq -s 'add'` flattens into a single array.
	# /status failure here is non-fatal: /check-runs already succeeded.
	local merged=""
	if [[ -n "$statuses" ]]; then
		merged=$(printf '%s\n%s' "$runs" "$statuses" | jq -s 'add // []' 2>/dev/null) || merged=""
	else
		merged=$(printf '%s' "$runs" | jq -s 'add // []' 2>/dev/null) || merged=""
	fi
	[[ -n "$merged" ]] || merged="[]"

	echo "$merged"
	return 0
}

#######################################
# Batch-enrich a PR list with aggregated REST check status.
#
# Loops `gh_pr_check_status_rest` over each PR in the input list and
# returns a JSON array of {number, status} pairs. Sequential per-PR calls
# are acceptable here because each REST call is ~1.3KB (much faster than
# the previous ~21KB GraphQL field per PR, and the REST pool is separate).
#
# Args:
#   $1 - repo slug (owner/repo)
#   $2 - JSON array of PR objects with at least .number and .headRefOid
#
# Output (stdout): JSON array `[{"number":N,"status":"PASS|FAIL|PENDING|none"}, ...]`
#   Empty array "[]" on missing args / empty input / parse error.
# Returns: 0 always
#######################################
gh_pr_check_status_rest_batch() {
	local slug="$1"
	local pr_json="$2"

	if [[ -z "$slug" || -z "$pr_json" || "$pr_json" == "null" || "$pr_json" == "[]" ]]; then
		echo "[]"
		return 0
	fi

	# Extract (number, sha) pairs as TSV; one PR per line.
	local pairs=""
	pairs=$(printf '%s' "$pr_json" | jq -r '.[] | select(.number and .headRefOid) | [.number, .headRefOid] | @tsv' 2>/dev/null) || pairs=""

	if [[ -z "$pairs" ]]; then
		echo "[]"
		return 0
	fi

	# Build result array. Use a tmpfile rather than a subshell-piped `while`
	# loop to avoid losing accumulated lines under bash 3.2 (subshell vars
	# don't propagate out of the pipe).
	local tmp
	tmp=$(mktemp)
	# NOTE: see gh_pr_check_status_rest above — `status` is read-only in zsh.
	local pr_num="" pr_sha="" _check_state=""
	while IFS=$'\t' read -r pr_num pr_sha; do
		[[ -n "$pr_num" && -n "$pr_sha" ]] || continue
		_check_state=$(gh_pr_check_status_rest "$slug" "$pr_sha")
		printf '{"number":%s,"status":"%s"}\n' "$pr_num" "$_check_state" >>"$tmp"
	done <<<"$pairs"

	local result=""
	result=$(jq -s '.' <"$tmp" 2>/dev/null) || result="[]"
	rm -f "$tmp"
	[[ -n "$result" && "$result" != "null" ]] || result="[]"

	echo "$result"
	return 0
}
