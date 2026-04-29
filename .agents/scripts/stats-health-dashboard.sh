#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Stats Health Dashboard — Orchestrator
# =============================================================================
# Per-repo pinned health issue dashboards.
#
# Extracted from stats-functions.sh via the phased decomposition plan:
#   todo/plans/stats-functions-decomposition.md  (Phase 3)
#
# This module is sourced by stats-functions.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all stats-* configuration constants in the bootstrap
# section of stats-functions.sh.
#
# Sub-libraries (sourced below):
#   - stats-health-dashboard-issue.sh  (issue lifecycle: find/create/resolve/dedup/pin)
#   - stats-health-dashboard-data.sh   (data gathering, body formatting, person stats)
#
# Dependencies on other stats modules:
#   - stats-shared.sh (calls _get_runner_role)
#
# Globals read:
#   - LOGFILE, REPOS_JSON, PERSON_STATS_INTERVAL, PERSON_STATS_LAST_RUN,
#     PERSON_STATS_CACHE_DIR, SESSION_COUNT_WARN
# Globals written:
#   - none (stats modules write only to disk under ~/.aidevops/logs/)

# Include guard — prevent double-sourcing
[[ -n "${_STATS_HEALTH_DASHBOARD_LOADED:-}" ]] && return 0
_STATS_HEALTH_DASHBOARD_LOADED=1

# t2687: sentinel returned by _find_health_issue when a gh query fails
# (rate limit, network, API 5xx). Callers treat this as "abstain this
# cycle" — never fall through to _create_health_issue, which would
# create a duplicate while the dedup lookups are silently unable to
# see existing ones.
readonly _HEALTH_QUERY_FAILED_SENTINEL="__QUERY_FAILED__"

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Source sub-libraries ---

# shellcheck source=./stats-health-dashboard-issue.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/stats-health-dashboard-issue.sh"

# shellcheck source=./stats-health-dashboard-data.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/stats-health-dashboard-data.sh"

# --- Orchestration functions ---

#######################################
# Activity guard — returns 0 to proceed, 1 to skip.
# Only runs when the cached health-issue file is absent (would create a new one).
#######################################
_check_health_issue_activity_guard() {
	local repo_slug="$1"
	local repo_path="$2"
	local runner_user="$3"
	local health_issue_file="$4"

	[[ -f "$health_issue_file" ]] && return 0

	local guard_pr_count guard_assigned_count guard_worker_count
	guard_pr_count=$(gh pr list --repo "$repo_slug" --state open \
		--json number --jq 'length' 2>/dev/null || echo "0")
	guard_assigned_count=$(gh_issue_list --repo "$repo_slug" \
		--assignee "$runner_user" --state open \
		--json number --jq 'length' 2>/dev/null || echo "0")

	local _guard_fields=()
	while IFS= read -r -d '' _gf; do
		_guard_fields+=("$_gf")
	done < <(_scan_active_workers "${repo_path:-}")
	guard_worker_count="${_guard_fields[1]:-0}"

	if [[ "${guard_pr_count:-0}" -eq 0 && "${guard_assigned_count:-0}" -eq 0 && "${guard_worker_count:-0}" -eq 0 ]]; then
		echo "[stats] Health issue: skipping creation for ${repo_slug} — no active PRs, issues, or workers" \
			>>"${LOGFILE:-/dev/null}"
		return 1
	fi
	return 0
}

#######################################
# Update pinned health issue for a single repo
#
# Creates or updates a pinned GitHub issue with live status:
#   - Open PRs and issues counts
#   - Active headless workers (from ps)
#   - System resources (CPU, RAM)
#   - Last pulse timestamp
#
# One issue per runner (GitHub user) per repo. Uses labels
# "supervisor" or "contributor" + "$runner_user" for dedup.
# Issue number cached in ~/.aidevops/logs/ to avoid repeated lookups.
#
# Maintainers get [Supervisor:user] issues; non-maintainers get
# [Contributor:user] issues. Role determined by _get_runner_role().
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - repo path (local filesystem)
#   $3 - cross-repo activity markdown (pre-computed by update_health_issues)
#   $4 - cross-repo session time markdown (pre-computed by update_health_issues)
#   $5 - cross-repo person stats markdown (pre-computed by update_health_issues)
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
_update_health_issue_for_repo() {
	local repo_slug="$1"
	local repo_path="$2"
	local cross_repo_md="${3:-}"
	local cross_repo_session_time_md="${4:-}"
	local cross_repo_person_stats_md="${5:-}"

	[[ -z "$repo_slug" ]] && return 0

	local runner_user
	runner_user=$(gh api user --jq '.login' || whoami)

	local runner_role
	runner_role=$(_get_runner_role "$runner_user" "$repo_slug")

	local role_config runner_prefix role_label role_label_color role_label_desc role_display
	role_config=$(_resolve_runner_role_config "$runner_user" "$runner_role")
	IFS='|' read -r runner_prefix role_label role_label_color role_label_desc role_display \
		<<<"$role_config"

	local slug_safe="${repo_slug//\//-}"
	local cache_dir="${HOME}/.aidevops/logs"
	local health_issue_file="${cache_dir}/health-issue-${runner_user}-${role_label}-${slug_safe}"
	mkdir -p "$cache_dir"

	_check_health_issue_activity_guard \
		"$repo_slug" "$repo_path" "$runner_user" "$health_issue_file" || return 0

	local health_issue_number
	health_issue_number=$(_resolve_health_issue_number \
		"$repo_slug" "$runner_user" "$runner_role" "$runner_prefix" \
		"$role_label" "$role_label_color" "$role_label_desc" \
		"$role_display" "$health_issue_file")
	[[ -z "$health_issue_number" ]] && return 0

	# t2687: periodic dedup scan (at most once per HEALTH_DEDUP_INTERVAL
	# seconds per repo+runner+role, default 1h). Closes duplicates that
	# slipped in during past GraphQL rate-limit windows when the cache
	# was valid so the label-scan inside _find_health_issue never ran.
	_periodic_health_issue_dedup \
		"$repo_slug" "$runner_user" "$runner_role" \
		"$role_label" "$role_display" "$health_issue_number"

	if [[ "$runner_role" == "supervisor" ]]; then
		_ensure_health_issue_pinned "$health_issue_number" "$repo_slug" "$runner_user"
	fi

	echo "$health_issue_number" >"$health_issue_file"

	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	local body
	body=$(_assemble_health_issue_body \
		"$repo_slug" "$repo_path" "$runner_user" "$slug_safe" \
		"$now_iso" "$role_display" "$runner_role" \
		"$cross_repo_md" "$cross_repo_session_time_md" "$cross_repo_person_stats_md")

	local body_edit_stderr
	body_edit_stderr=$(gh issue edit "$health_issue_number" --repo "$repo_slug" \
		--body "$body" 2>&1 >/dev/null) || {
		echo "[stats] Health issue: failed to update body for #${health_issue_number}: ${body_edit_stderr}" \
			>>"$LOGFILE"
		return 0
	}

	# Re-extract headline counts from the rendered body to build the title.
	# Avoids relying on function-local variables from _assemble_health_issue_body.
	local counts_raw pr_count assigned_issue_count worker_count
	counts_raw=$(_extract_body_counts "$body")
	IFS='|' read -r pr_count assigned_issue_count worker_count <<<"$counts_raw"

	local pr_label="PRs"
	[[ "$pr_count" -eq 1 ]] && pr_label="PR"
	local worker_label="workers"
	[[ "$worker_count" -eq 1 ]] && worker_label="worker"

	_update_health_issue_title \
		"$health_issue_number" "$repo_slug" "$runner_prefix" \
		"$pr_count" "$pr_label" "$assigned_issue_count" \
		"$worker_count" "$worker_label"

	return 0
}

#######################################
# Update health issues for ALL pulse-enabled repos
#
# Iterates repos.json and calls _update_health_issue_for_repo for each
# non-local-only repo with a slug. Runs sequentially to avoid gh API
# rate limiting. Best-effort — failures in one repo don't block others.
#######################################
update_health_issues() {
	# t2044 Phase 0: dry-run sentinel. When STATS_DRY_RUN=1, return immediately
	# to exercise the call graph without making gh/git API calls. Temporary
	# scaffolding — removed after Phase 3 merges.
	if [[ "${STATS_DRY_RUN:-}" == "1" ]]; then
		echo "[stats] update_health_issues: dry-run, skipping" >>"$LOGFILE"
		return 0
	fi
	command -v gh &>/dev/null || return 0
	gh auth status &>/dev/null 2>&1 || return 0

	local repos_json="$REPOS_JSON"
	if [[ ! -f "$repos_json" ]]; then
		return 0
	fi

	local repo_entries
	repo_entries=$(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null || echo "")

	if [[ -z "$repo_entries" ]]; then
		return 0
	fi

	# Refresh person-stats cache if stale (t1426: hourly, not every pulse)
	_refresh_person_stats_cache || true

	# Pre-compute cross-repo summaries ONCE for all health issues.
	# This avoids N×N git log walks (one cross-repo scan per repo dashboard)
	# and redundant DB queries for session time.
	# Person stats read from cache (refreshed hourly by _refresh_person_stats_cache).
	local cross_repo_md=""
	local cross_repo_session_time_md=""
	local cross_repo_person_stats_md=""
	local activity_helper="${HOME}/.aidevops/agents/scripts/contributor-activity-helper.sh"
	if [[ -x "$activity_helper" ]]; then
		local all_repo_paths
		all_repo_paths=$(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false) | .path' "$repos_json" || echo "")
		if [[ -n "$all_repo_paths" ]]; then
			local -a cross_args=()
			while IFS= read -r rp; do
				[[ -n "$rp" ]] && cross_args+=("$rp")
			done <<<"$all_repo_paths"
			if [[ ${#cross_args[@]} -gt 1 ]]; then
				cross_repo_md=$(bash "$activity_helper" cross-repo-summary "${cross_args[@]}" --period month --format markdown || echo "_Cross-repo data unavailable._")
				cross_repo_session_time_md=$(bash "$activity_helper" cross-repo-session-time "${cross_args[@]}" --period all --format markdown || echo "_Cross-repo session data unavailable._")
			fi
		fi
	fi
	local cross_repo_cache="${PERSON_STATS_CACHE_DIR}/person-stats-cache-cross-repo.md"
	if [[ -f "$cross_repo_cache" ]]; then
		cross_repo_person_stats_md=$(cat "$cross_repo_cache")
	fi

	local updated=0
	while IFS='|' read -r slug path; do
		[[ -z "$slug" ]] && continue
		_update_health_issue_for_repo "$slug" "$path" "$cross_repo_md" "$cross_repo_session_time_md" "$cross_repo_person_stats_md" || true
		updated=$((updated + 1))
	done <<<"$repo_entries"

	if [[ "$updated" -gt 0 ]]; then
		echo "[stats] Health issues: updated $updated repo(s)" >>"$LOGFILE"
	fi
	return 0
}
