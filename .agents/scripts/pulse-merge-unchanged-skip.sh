#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-merge-unchanged-skip.sh — Skip repeated no-op merge evaluations (GH#33569)
# =============================================================================
# A loaded runner spent ~560s per pulse cycle re-evaluating the same open PRs
# with merged=0, leaving dispatch below its per-candidate floor. Every complete
# per-repo evaluation that makes no progress records a fingerprint of the PR
# list (number, state, draft, head SHA, base, updatedAt, labels). A caller that
# opts in (PULSE_MERGE_UNCHANGED_SKIP=1, set by the in-cycle pulse pass) skips
# enrichment and per-PR evaluation while the fingerprint is unchanged, the
# no-op streak has reached the threshold and the last full evaluation is
# younger than the maximum age. Any progress, failure, list change, due retry
# target or paused cursor forces a full evaluation. The standalone merge
# routine keeps evaluating every pass, so CI transitions that do not change the
# list fingerprint are still merged there; the age bound covers runners
# without that routine.
#
# Usage: source "${SCRIPT_DIR}/pulse-merge-unchanged-skip.sh"
# Part of aidevops framework: https://aidevops.sh

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_MERGE_UNCHANGED_SKIP_LOADED:-}" ]] && return 0
_PULSE_MERGE_UNCHANGED_SKIP_LOADED=1

# Stdout: per-repo state file path. Returns 1 for an unsafe slug.
_pmu_state_file() {
	local repo_slug="$1"
	local state_dir="${PULSE_MERGE_UNCHANGED_STATE_DIR:-${HOME}/.aidevops/logs/pulse-merge-unchanged}"
	[[ "$repo_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
	printf '%s/%s--%s\n' "$state_dir" "${repo_slug%%/*}" "${repo_slug##*/}"
	return 0
}

# Stdout: positive integer setting, or the default when unset/invalid.
# Args: $1=value, $2=default
_pmu_positive_int() {
	local value="$1"
	local default_value="$2"
	if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
		printf '%s' "$value"
	else
		printf '%s' "$default_value"
	fi
	return 0
}

# Stdout: stable fingerprint of the listed PR set. Returns 1 when the list is
# unusable or contains a due exact retry target (always fully evaluated).
_pmu_fingerprint() {
	local pr_json="$1"
	local canonical="" digest=""
	canonical=$(printf '%s' "$pr_json" | jq -cS '
		if type != "array" or length == 0 or any(.[]; (._pulseDeferredRetry // false) == true) then
			error("not fingerprintable")
		else
			sort_by(.number) | map({
				number, state, isDraft, headRefOid, baseRefName, updatedAt,
				labels: ([.labels[]? | (.name? // .)] | sort)
			})
		end' 2>/dev/null) || return 1
	[[ -n "$canonical" ]] || return 1
	if command -v sha256sum >/dev/null 2>&1; then
		digest=$(printf '%s' "$canonical" | sha256sum 2>/dev/null) || return 1
	elif command -v shasum >/dev/null 2>&1; then
		digest=$(printf '%s' "$canonical" | shasum -a 256 2>/dev/null) || return 1
	else
		digest=$(printf '%s' "$canonical" | cksum 2>/dev/null) || return 1
	fi
	digest="${digest%% *}"
	[[ "$digest" =~ ^[A-Za-z0-9]+$ ]] || return 1
	printf '%s' "$digest"
	return 0
}

# Returns 0 when a paused PR or enrichment cursor belongs to this repo (a full
# evaluation is in progress and must resume instead of being skipped).
_pmu_cursor_targets_repo() {
	local repo_slug="$1"
	local enrichment_cursor="" cursor_file="" cursor_repo="" cursor_rest=""
	if declare -F _pmp_merge_enrichment_cursor_file >/dev/null 2>&1; then
		enrichment_cursor=$(_pmp_merge_enrichment_cursor_file) || enrichment_cursor=""
	fi
	for cursor_file in "${PULSE_MERGE_PR_CURSOR_FILE:-}" "$enrichment_cursor"; do
		[[ -n "$cursor_file" && -f "$cursor_file" ]] || continue
		cursor_repo=""
		IFS='|' read -r cursor_repo cursor_rest <"$cursor_file" || true
		: "$cursor_rest"
		[[ "$cursor_repo" == "$repo_slug" ]] && return 0
	done
	return 1
}

#######################################
# Decide whether this pass may skip per-PR evaluation for an unchanged no-op
# PR set. Logs the skip decision.
# Args: $1=repo slug, $2=listed PR JSON (after due retry target expansion)
# Returns: 0 to skip, 1 to evaluate normally
#######################################
_pmu_should_skip_repo() {
	local repo_slug="$1"
	local pr_json="$2"
	local state_file="" fingerprint="" stored_fingerprint="" streak="" last_full="" now="" age=0
	local min_streak="" max_age=""

	[[ "${PULSE_MERGE_UNCHANGED_SKIP:-0}" == 1 ]] || return 1
	_pmu_cursor_targets_repo "$repo_slug" && return 1
	state_file=$(_pmu_state_file "$repo_slug") || return 1
	[[ -f "$state_file" && ! -L "$state_file" ]] || return 1
	IFS=$'\t' read -r stored_fingerprint streak last_full <"$state_file" || return 1
	[[ "$streak" =~ ^[0-9]+$ && "$last_full" =~ ^[0-9]+$ && -n "$stored_fingerprint" ]] || return 1
	min_streak=$(_pmu_positive_int "${PULSE_MERGE_UNCHANGED_SKIP_MIN_STREAK:-}" 2)
	max_age=$(_pmu_positive_int "${PULSE_MERGE_UNCHANGED_SKIP_MAX_AGE_SECONDS:-}" 1800)
	[[ "$streak" -ge "$min_streak" ]] || return 1
	now=$(_pmp_now_epoch)
	[[ "$now" =~ ^[0-9]+$ && "$now" -ge "$last_full" ]] || return 1
	age=$((now - last_full))
	[[ "$age" -lt "$max_age" ]] || return 1
	fingerprint=$(_pmu_fingerprint "$pr_json") || return 1
	[[ "$fingerprint" == "$stored_fingerprint" ]] || return 1
	echo "[pulse-wrapper] Merge pass: ${repo_slug} PR set unchanged after ${streak} no-op evaluations (last full ${age}s ago, max_age=${max_age}s); skipping enrichment and per-PR evaluation (GH#33569)" >>"${LOGFILE:-/dev/null}"
	return 0
}

#######################################
# Begin one per-repo evaluation: remember the listed PR set for evidence and
# reset the degraded flag, then decide whether the evaluation may be skipped.
# Args: $1=repo slug, $2=listed PR JSON, $3=list complete (1 = authoritative)
# Returns: 0 to skip, 1 to evaluate normally
#######################################
_pmu_skip_unchanged_repo() {
	local repo_slug="$1"
	local pr_json="$2"
	local list_complete="$3"

	_PMU_LISTED_PR_JSON="$pr_json"
	_PMU_EVALUATION_DEGRADED=0
	[[ "$list_complete" == 1 ]] || return 1
	_pmu_should_skip_repo "$repo_slug" "$pr_json" || return 1
	_PMU_LISTED_PR_JSON=""
	return 0
}

#######################################
# Record the outcome of one per-repo evaluation begun by
# _pmu_skip_unchanged_repo. Only a complete evaluation of the whole list from
# index 0 with no merge, close or eligible-unmerged result and no fail-closed
# enrichment (_PMU_EVALUATION_DEGRADED) extends the no-op streak; anything
# else clears it.
# Args: $1=repo slug, $2=merged, $3=closed, $4=failed,
#       $5=complete (1 = whole list evaluated authoritatively from index 0)
#######################################
_pmu_record_repo_evaluation() {
	local repo_slug="$1"
	local merged="$2"
	local closed="$3"
	local failed="$4"
	local complete="$5"
	local pr_json="${_PMU_LISTED_PR_JSON:-}"
	local state_file="" fingerprint="" stored_fingerprint="" streak=0 last_full="" tmp_file=""

	_PMU_LISTED_PR_JSON=""
	[[ "${_PMU_EVALUATION_DEGRADED:-0}" == 0 ]] || complete=0
	state_file=$(_pmu_state_file "$repo_slug") || return 0
	if [[ "$complete" != 1 || "$merged" != 0 || "$closed" != 0 || "$failed" != 0 ]] ||
		! fingerprint=$(_pmu_fingerprint "$pr_json"); then
		rm -f "$state_file" 2>/dev/null || true
		return 0
	fi
	if [[ -f "$state_file" && ! -L "$state_file" ]]; then
		IFS=$'\t' read -r stored_fingerprint streak last_full <"$state_file" || stored_fingerprint=""
	fi
	[[ "$streak" =~ ^[0-9]+$ ]] || streak=0
	if [[ "$stored_fingerprint" == "$fingerprint" ]]; then
		streak=$((streak + 1))
	else
		streak=1
	fi
	mkdir -p "${state_file%/*}" 2>/dev/null || return 0
	tmp_file=$(mktemp "${state_file}.XXXXXX" 2>/dev/null) || return 0
	if printf '%s\t%s\t%s\n' "$fingerprint" "$streak" "$(_pmp_now_epoch)" >"$tmp_file"; then
		mv -f "$tmp_file" "$state_file" 2>/dev/null || rm -f "$tmp_file"
	else
		rm -f "$tmp_file"
	fi
	return 0
}
