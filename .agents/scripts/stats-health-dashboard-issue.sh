#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Stats Health Dashboard — Issue Lifecycle Sub-Library
# =============================================================================
# Functions for finding, creating, resolving, deduplicating, pinning, and
# unpinning health dashboard issues on GitHub.
#
# Usage: source "${SCRIPT_DIR}/stats-health-dashboard-issue.sh"
#
# Dependencies:
#   - shared-constants.sh (gh_issue_list, gh_issue_view, gh_create_issue, print_error, etc.)
#   - stats-shared.sh (_get_runner_role, _file_mtime_epoch)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_STATS_HEALTH_DASHBOARD_ISSUE_LOADED:-}" ]] && return 0
_STATS_HEALTH_DASHBOARD_ISSUE_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# Role constant — avoids repeated-string-literal lint finding across functions
_ROLE_SUPERVISOR="supervisor"

# --- Functions ---

#######################################
# List open health issues matching a role + runner_user pair, filtered
# by title-prefix. Helper centralises the jq filter so `_find_health_issue`
# and `_periodic_health_issue_dedup` share one query definition.
#
# Arguments:
#   $1 - repo slug
#   $2 - role label (supervisor|contributor)
#   $3 - runner user
#   $4 - role display (Supervisor|Contributor)
# Output: JSON array sorted newest-first (by number desc).
# Returns: gh's exit code (non-zero on rate limit / network / API error).
#######################################
_list_health_issues_by_role_label() {
	local repo_slug="$1"
	local role_label="$2"
	local runner_user="$3"
	local role_display="$4"

	gh_issue_list --repo "$repo_slug" \
		--label "$role_label" --label "$runner_user" \
		--state open --json number,title \
		--jq "[.[] | select(.title | startswith(\"[${role_display}:\"))] | sort_by(.number) | reverse"
}

#######################################
# Validate a cached health-issue number: check it still exists and is OPEN.
# Returns (via stdout):
#   - the cached number if still valid
#   - empty if the cache entry points to a CLOSED issue (caller should re-resolve)
#   - $_HEALTH_QUERY_FAILED_SENTINEL if `gh issue view` failed (rate-limit/network)
# Side effects: removes the cache file on CLOSED state, unpins on CLOSED supervisor.
#######################################
_try_cached_health_issue_lookup() {
	local health_issue_file="$1"
	local repo_slug="$2"
	local runner_role="$3"

	[[ ! -f "$health_issue_file" ]] && return 0  # empty stdout

	local cached_number
	cached_number=$(cat "$health_issue_file" 2>/dev/null || echo "")
	[[ -z "$cached_number" ]] && return 0

	local issue_state rc=0
	issue_state=$(gh_issue_view "$cached_number" --repo "$repo_slug" --json state --jq '.state' 2>/dev/null) || rc=$?

	if [[ $rc -ne 0 ]]; then
		# Query failed (rate limit, network, API 5xx). Preserve cache and return
		# it — caller still points to a valid-as-far-as-we-know issue.
		echo "[stats] Health issue: cache validation failed for #${cached_number} in ${repo_slug} (rc=${rc}) — preserving cache" >>"${LOGFILE:-/dev/null}"
		echo "$cached_number"
		return 0
	fi

	if [[ "$issue_state" == "CLOSED" ]]; then
		[[ "$runner_role" == "$_ROLE_SUPERVISOR" ]] && _unpin_health_issue "$cached_number" "$repo_slug"
		rm -f "$health_issue_file" 2>/dev/null || true
		return 0  # empty → caller re-resolves
	fi

	if [[ "$issue_state" != "OPEN" ]]; then
		# Unexpected state (empty, unknown enum). Preserve cache defensively.
		echo "[stats] Health issue: unexpected state '${issue_state}' for #${cached_number} in ${repo_slug} — preserving cache" >>"${LOGFILE:-/dev/null}"
		echo "$cached_number"
		return 0
	fi

	echo "$cached_number"
	return 0
}

#######################################
# Strip the 'persistent' label from a health issue before closing it,
# preventing issue-sync.yml 'Reopen Persistent Issues' from reopening
# programmatic dedup closes (GH#20326). Idempotent: no-op if not present.
# Arguments:
#   $1 - issue number
#   $2 - repo slug
_strip_persistent_label_before_close() {
	local issue_number="$1"
	local repo_slug="$2"
	gh issue edit "$issue_number" --repo "$repo_slug" --remove-label persistent 2>/dev/null || true
	return 0
}

#######################################
# Close all duplicate health issues (all but the first) from a jq array.
# Arguments: label_results_json keep_number repo_slug runner_role
_close_health_issue_duplicates() {
	local label_results="$1" keep_number="$2" repo_slug="$3" runner_role="$4"

	local dup_count
	dup_count=$(printf '%s' "$label_results" | jq 'length' 2>/dev/null || echo "0")
	[[ "${dup_count:-0}" -le 1 ]] && return 0

	local dup_numbers
	dup_numbers=$(printf '%s' "$label_results" | jq -r '.[1:][].number' 2>/dev/null || echo "")
	while IFS= read -r dup_num; do
		[[ -z "$dup_num" ]] && continue
		[[ "$runner_role" == "$_ROLE_SUPERVISOR" ]] && _unpin_health_issue "$dup_num" "$repo_slug"
		_strip_persistent_label_before_close "$dup_num" "$repo_slug"
		gh issue close "$dup_num" --repo "$repo_slug" \
			--comment "Closing duplicate ${runner_role} health issue — superseded by #${keep_number}." 2>/dev/null || true
	done <<<"$dup_numbers"
	return 0
}

#######################################
# Title-based fallback lookup with label backfill.
# Returns issue number if found, empty if not, $_HEALTH_QUERY_FAILED_SENTINEL on failure.
_try_title_health_issue_fallback() {
	local runner_prefix="$1" repo_slug="$2" runner_user="$3" role_label="$4" role_display="$5"

	local title_result rc=0
	title_result=$(gh_issue_list --repo "$repo_slug" \
		--search "in:title ${runner_prefix}" \
		--state open --json number,title \
		--jq "[.[] | select(.title | startswith(\"${runner_prefix}\"))][0].number" 2>/dev/null) || rc=$?

	if [[ $rc -ne 0 ]]; then
		echo "[stats] Health issue: title lookup failed for ${runner_prefix} in ${repo_slug} (rc=${rc}) — abstaining this cycle" >>"${LOGFILE:-/dev/null}"
		echo "$_HEALTH_QUERY_FAILED_SENTINEL"
		return 0
	fi

	local health_issue_number="${title_result:-}"
	if [[ -n "$health_issue_number" ]]; then
		gh label create "$runner_user" --repo "$repo_slug" --color "0E8A16" \
			--description "${role_display} runner: ${runner_user}" --force 2>/dev/null || true
		gh issue edit "$health_issue_number" --repo "$repo_slug" \
			--add-label "$role_label" --add-label "$runner_user" 2>/dev/null || true
	fi
	echo "$health_issue_number"
	return 0
}

_find_health_issue() {
	local repo_slug="$1"
	local runner_user="$2"
	local runner_role="$3"
	local runner_prefix="$4"
	local role_label="$5"
	local role_display="$6"
	local health_issue_file="$7"

	local health_issue_number
	health_issue_number=$(_try_cached_health_issue_lookup "$health_issue_file" "$repo_slug" "$runner_role")

	# Sentinel from cache lookup is defensive only; current behaviour preserves
	# the cached number on error, but downstream checks still need it to pass
	# through. Short-circuit on sentinel.
	if [[ "$health_issue_number" == "$_HEALTH_QUERY_FAILED_SENTINEL" ]]; then
		echo "$_HEALTH_QUERY_FAILED_SENTINEL"
		return 0
	fi

	# Search by labels (more reliable than title search) if cache gave nothing.
	if [[ -z "$health_issue_number" ]]; then
		local label_results rc=0
		label_results=$(_list_health_issues_by_role_label \
			"$repo_slug" "$role_label" "$runner_user" "$role_display" 2>/dev/null) || rc=$?

		if [[ $rc -ne 0 ]]; then
			# Abstain this cycle. Emit sentinel so _resolve_health_issue_number
			# refuses to create a duplicate.
			echo "[stats] Health issue: label lookup failed for ${role_label}+${runner_user} in ${repo_slug} (rc=${rc}) — abstaining this cycle" >>"${LOGFILE:-/dev/null}"
			echo "$_HEALTH_QUERY_FAILED_SENTINEL"
			return 0
		fi

		label_results="${label_results:-[]}"
		health_issue_number=$(printf '%s' "$label_results" | jq -r '.[0].number // empty' 2>/dev/null || echo "")
		_close_health_issue_duplicates "$label_results" "$health_issue_number" "$repo_slug" "$runner_role"
	fi

	# Fallback: title-based search with label backfill.
	if [[ -z "$health_issue_number" ]]; then
		health_issue_number=$(_try_title_health_issue_fallback \
			"$runner_prefix" "$repo_slug" "$runner_user" "$role_label" "$role_display")
	fi

	echo "$health_issue_number"
	return 0
}

#######################################
# Create a new health issue for a runner+repo and optionally pin it.
#
# Arguments:
#   $1 - repo slug
#   $2 - runner user
#   $3 - runner role (supervisor|contributor)
#   $4 - runner prefix (e.g. "[Supervisor:user]")
#   $5 - role label (supervisor|contributor)
#   $6 - role label color
#   $7 - role label desc
#   $8 - role display (Supervisor|Contributor)
# Output: new issue number to stdout (empty on failure)
#######################################
_create_health_issue() {
	local repo_slug="$1"
	local runner_user="$2"
	local runner_role="$3"
	local runner_prefix="$4"
	local role_label="$5"
	local role_label_color="$6"
	local role_label_desc="$7"
	local role_display="$8"

	gh label create "$role_label" --repo "$repo_slug" --color "$role_label_color" \
		--description "$role_label_desc" --force 2>/dev/null || true
	gh label create "$runner_user" --repo "$repo_slug" --color "0E8A16" \
		--description "${role_display} runner: ${runner_user}" --force 2>/dev/null || true
	gh label create "source:health-dashboard" --repo "$repo_slug" --color "C2E0C6" \
		--description "Auto-created by stats-functions.sh health dashboard" --force 2>/dev/null || true
	# t1890: health dashboard issues are management issues that should never be
	# closed or dispatched. Add the "persistent" label for consistency with the
	# quality review issue, so the dispatch filter only needs one label check.
	gh label create "persistent" --repo "$repo_slug" --color "FBCA04" \
		--description "Persistent issue — do not close" --force 2>/dev/null || true

	local health_body="Live ${runner_role} status for **${runner_user}**. Updated each pulse. Pin this issue for at-a-glance monitoring."
	local sig_footer=""
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer --body "$health_body" 2>/dev/null || true)
	health_body="${health_body}${sig_footer}"

	# t2691/GH#20311: Health dashboard issues are always created by the
	# headless pulse context. Force AIDEVOPS_SESSION_ORIGIN=worker so
	# gh_create_issue applies origin:worker regardless of whether the
	# caller has AIDEVOPS_HEADLESS set (defense-in-depth; stats-wrapper.sh
	# already exports AIDEVOPS_HEADLESS=true, but this guards test contexts
	# and any future invocation path that bypasses that wrapper).
	local health_issue_number
	health_issue_number=$(AIDEVOPS_SESSION_ORIGIN=worker gh_create_issue --repo "$repo_slug" \
		--title "${runner_prefix} starting..." \
		--body "$health_body" \
		--label "$role_label" --label "$runner_user" --label "source:health-dashboard" --label "persistent" 2>/dev/null | grep -oE '[0-9]+$' || echo "")

	if [[ -z "$health_issue_number" ]]; then
		echo "[stats] Health issue: could not create for ${repo_slug}" >>"$LOGFILE"
		echo ""
		return 0
	fi

	# Pin only supervisor issues — contributor issues don't pin because
	# GitHub allows max 3 pinned issues per repo and those slots are
	# reserved for maintainer dashboards and the quality review issue.
	if [[ "$runner_role" == "$_ROLE_SUPERVISOR" ]]; then
		local node_id
		node_id=$(gh_issue_view "$health_issue_number" --repo "$repo_slug" --json id --jq '.id' 2>/dev/null || echo "")
		if [[ -n "$node_id" ]]; then
			gh api graphql -f query="
				mutation {
					pinIssue(input: {issueId: \"${node_id}\"}) {
						issue { number }
					}
				}" >/dev/null 2>&1 || true
		fi
	fi
	echo "[stats] Health issue: created #${health_issue_number} (${runner_role}) for ${runner_user} in ${repo_slug}" >>"$LOGFILE"

	echo "$health_issue_number"
	return 0
}

#######################################
# Resolve (find or create) the health issue number for a runner+repo.
#
# Delegates to _find_health_issue then _create_health_issue if not found.
#
# Arguments:
#   $1 - repo slug
#   $2 - runner user
#   $3 - runner role (supervisor|contributor)
#   $4 - runner prefix (e.g. "[Supervisor:user]")
#   $5 - role label (supervisor|contributor)
#   $6 - role label color
#   $7 - role label desc
#   $8 - role display (Supervisor|Contributor)
#   $9 - cache file path
# Output: issue number to stdout (empty on failure)
#######################################
_resolve_health_issue_number() {
	local repo_slug="$1"
	local runner_user="$2"
	local runner_role="$3"
	local runner_prefix="$4"
	local role_label="$5"
	local role_label_color="$6"
	local role_label_desc="$7"
	local role_display="$8"
	local health_issue_file="$9"

	local health_issue_number
	health_issue_number=$(_find_health_issue \
		"$repo_slug" "$runner_user" "$runner_role" "$runner_prefix" \
		"$role_label" "$role_display" "$health_issue_file")

	# t2687: honour the query-failed sentinel from _find_health_issue.
	# When the API was unreachable for the dedup lookups, abstain from
	# creation this cycle — otherwise we create duplicates every time
	# GraphQL is exhausted (the root cause of GH#20301).
	if [[ "$health_issue_number" == "$_HEALTH_QUERY_FAILED_SENTINEL" ]]; then
		echo "[stats] Health issue: abstaining from create/update cycle for ${repo_slug} (runner=${runner_user}, role=${runner_role}) — dedup lookups failed" >>"${LOGFILE:-/dev/null}"
		echo ""
		return 0
	fi

	if [[ -z "$health_issue_number" ]]; then
		health_issue_number=$(_create_health_issue \
			"$repo_slug" "$runner_user" "$runner_role" "$runner_prefix" \
			"$role_label" "$role_label_color" "$role_label_desc" "$role_display")
	fi

	echo "$health_issue_number"
	return 0
}

#######################################
# Periodic label-based dedup scan (t2687, GH#20301).
#
# Even when the cached health issue is valid and returns quickly via
# _find_health_issue, the label-based dedup block inside that function
# is bypassed because the cache-hit path short-circuits before the
# label scan runs. That means duplicates that slipped in during past
# GraphQL rate-limit windows never get closed automatically — they
# require either a cache invalidation or manual intervention.
#
# This helper runs the same label-based dedup at most once per hour
# per repo-runner-role tuple, keyed by a timestamp state file. On
# query failure (rc != 0), the state file is NOT updated so the next
# pulse cycle retries — avoids starving the scan during an extended
# rate-limit window.
#
# Arguments:
#   $1 - repo slug
#   $2 - runner user
#   $3 - runner role (supervisor|contributor)
#   $4 - role label (supervisor|contributor)
#   $5 - role display (Supervisor|Contributor)
#   $6 - current (kept) health issue number
# Env:
#   HEALTH_DEDUP_INTERVAL - seconds between scans per (repo, runner, role).
#                           Default 3600 (1 hour).
# Returns: 0 always (best-effort, never breaks the pulse).
#######################################
_periodic_health_issue_dedup() {
	local repo_slug="$1"
	local runner_user="$2"
	local runner_role="$3"
	local role_label="$4"
	local role_display="$5"
	local current_issue="$6"

	[[ -z "$repo_slug" || -z "$runner_user" || -z "$role_label" || -z "$current_issue" ]] && return 0

	local slug_safe="${repo_slug//\//-}"
	local cache_dir="${HOME}/.aidevops/logs"
	local state_file="${cache_dir}/health-dedup-last-scan-${runner_user}-${role_label}-${slug_safe}"
	local interval="${HEALTH_DEDUP_INTERVAL:-3600}"

	# Throttle: skip if last scan was recent
	if [[ -f "$state_file" ]]; then
		local last_scan_epoch now_epoch elapsed
		last_scan_epoch=$(_file_mtime_epoch "$state_file")
		now_epoch=$(date +%s)
		elapsed=$((now_epoch - last_scan_epoch))
		if [[ $elapsed -lt $interval ]]; then
			return 0
		fi
	fi

	mkdir -p "$cache_dir" 2>/dev/null || true

	local label_results rc=0
	label_results=$(_list_health_issues_by_role_label \
		"$repo_slug" "$role_label" "$runner_user" "$role_display" 2>/dev/null) || rc=$?

	if [[ $rc -ne 0 ]]; then
		# Leave state_file alone — retry next pulse cycle.
		echo "[stats] Health issue: periodic dedup scan failed for ${repo_slug} (rc=${rc}) — will retry next cycle" >>"${LOGFILE:-/dev/null}"
		return 0
	fi

	label_results="${label_results:-[]}"

	local total_count
	total_count=$(printf '%s' "$label_results" | jq 'length' 2>/dev/null || echo "0")

	if [[ "${total_count:-0}" -gt 1 ]]; then
		local dup_numbers
		# Close every issue in the label-match set except the one we're
		# currently using. The cached/resolved issue is the canonical one
		# because its body+title are up-to-date with this pulse.
		dup_numbers=$(printf '%s' "$label_results" | jq -r --arg keep "$current_issue" \
			'.[] | select((.number | tostring) != $keep) | .number' 2>/dev/null || echo "")
		while IFS= read -r dup_num; do
			[[ -z "$dup_num" ]] && continue
			# _unpin_health_issue is already best-effort and a no-op for
			# unpinned (contributor) issues, so call unconditionally.
			# Duplicate supervisor issues CAN be pinned in pathological
			# cases (stale pin from a pre-rate-limit canonical).
			_unpin_health_issue "$dup_num" "$repo_slug"
			_strip_persistent_label_before_close "$dup_num" "$repo_slug"
			gh issue close "$dup_num" --repo "$repo_slug" \
				--comment "Closing duplicate ${runner_role} health issue — superseded by #${current_issue} (t2687 periodic dedup). Root cause likely a past GraphQL rate-limit window; see GH#20301." 2>/dev/null || true
			echo "[stats] Health issue: periodic dedup closed #${dup_num} in ${repo_slug} (kept #${current_issue})" >>"${LOGFILE:-/dev/null}"
		done <<<"$dup_numbers"
	fi

	# Update state file timestamp (even when no duplicates found) so we
	# don't re-query every cycle.
	touch "$state_file" 2>/dev/null || true

	return 0
}

#######################################
# Resolve role-specific config variables for a runner.
#
# Outputs pipe-delimited fields:
#   runner_prefix|role_label|role_label_color|role_label_desc|role_display
#
# Arguments:
#   $1 - runner_user
#   $2 - runner_role (supervisor|contributor)
#######################################
_resolve_runner_role_config() {
	local runner_user="$1"
	local runner_role="$2"

	local runner_prefix role_label role_label_color role_label_desc role_display
	if [[ "$runner_role" == "$_ROLE_SUPERVISOR" ]]; then
		runner_prefix="[Supervisor:${runner_user}]"
		role_label="$_ROLE_SUPERVISOR"
		role_label_color="1D76DB"
		role_label_desc="Supervisor health dashboard"
		role_display="Supervisor"
	else
		runner_prefix="[Contributor:${runner_user}]"
		role_label="contributor"
		role_label_color="A2EEEF"
		role_label_desc="Contributor health dashboard"
		role_display="Contributor"
	fi

	printf '%s|%s|%s|%s|%s' \
		"$runner_prefix" "$role_label" "$role_label_color" \
		"$role_label_desc" "$role_display"
	return 0
}

#######################################
# Ensure the active health issue is pinned (supervisor-only).
#
# Unpins closed/stale issues to free pin slots (max 3 per repo),
# then pins the active issue idempotently.
#
# Arguments:
#   $1 - health_issue_number
#   $2 - repo_slug
#   $3 - runner_user (for _cleanup_stale_pinned_issues)
#######################################
_ensure_health_issue_pinned() {
	local health_issue_number="$1"
	local repo_slug="$2"
	local runner_user="$3"

	_cleanup_stale_pinned_issues "$repo_slug" "$runner_user"

	local active_node_id
	active_node_id=$(gh_issue_view "$health_issue_number" --repo "$repo_slug" \
		--json id --jq '.id' 2>/dev/null || echo "")
	if [[ -n "$active_node_id" ]]; then
		gh api graphql -f query="
			mutation {
				pinIssue(input: {issueId: \"${active_node_id}\"}) {
					issue { number }
				}
			}" >/dev/null 2>&1 || true
	fi
	return 0
}

#######################################
# Unpin closed/stale supervisor issues to free pin slots
#
# GitHub allows max 3 pinned issues per repo. Old supervisor issues
# that were closed (manually or by dedup) may still be pinned, blocking
# the active health issue from being pinned. This function finds all
# pinned issues in the repo and unpins any that are closed.
#
# Arguments:
#   $1 - repo slug
#   $2 - runner user (for logging)
#######################################
_cleanup_stale_pinned_issues() {
	local repo_slug="$1"
	local runner_user="$2"
	local owner="${repo_slug%%/*}"
	local name="${repo_slug##*/}"

	# Query all pinned issues via GraphQL (parameterized to prevent injection)
	local pinned_json
	pinned_json=$(gh api graphql -F owner="$owner" -F name="$name" -f query="
		query(\$owner: String!, \$name: String!) {
			repository(owner: \$owner, name: \$name) {
				pinnedIssues(first: 10) {
					nodes {
						issue {
							id
							number
							state
							title
						}
					}
				}
			}
		}
		" 2>>"$LOGFILE" || echo "")

	[[ -z "$pinned_json" ]] && return 0

	# Unpin any closed issues
	local closed_pinned
	closed_pinned=$(echo "$pinned_json" | jq -r '.data.repository.pinnedIssues.nodes[] | select(.issue.state == "CLOSED") | "\(.issue.id)|\(.issue.number)"' 2>/dev/null || echo "")

	[[ -z "$closed_pinned" ]] && return 0

	while IFS='|' read -r node_id issue_num; do
		[[ -z "$node_id" ]] && continue
		gh api graphql -f query="
			mutation {
				unpinIssue(input: {issueId: \"${node_id}\"}) {
					issue { number }
				}
			}" >/dev/null 2>&1 || true
		echo "[stats] Health issue: unpinned closed issue #${issue_num} in ${repo_slug}" >>"$LOGFILE"
	done <<<"$closed_pinned"

	return 0
}

#######################################
# Unpin a health issue (best-effort)
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#######################################
_unpin_health_issue() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ -z "$issue_number" || -z "$repo_slug" ]] && return 0

	local issue_node_id
	issue_node_id=$(gh_issue_view "$issue_number" --repo "$repo_slug" --json id --jq '.id' 2>/dev/null || echo "")
	[[ -z "$issue_node_id" ]] && return 0

	gh api graphql -f query="
		mutation {
			unpinIssue(input: {issueId: \"${issue_node_id}\"}) {
				issue { number }
			}
		}" >/dev/null 2>&1 || true

	return 0
}
