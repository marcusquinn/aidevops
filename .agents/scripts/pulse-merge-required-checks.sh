#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge-required-checks.sh — required-check terminal-state classifiers.

[[ -n "${_PULSE_MERGE_REQUIRED_CHECKS_LOADED:-}" ]] && return 0
_PULSE_MERGE_REQUIRED_CHECKS_LOADED=1

#######################################
# Return whether any branch-protection-required check on a PR is in a terminal
# failed state. Pending states are explicitly non-terminal: queued, pending,
# in_progress, waiting, skipped-by-dependency, expected, absent-from-rollup,
# and null conclusions must not trigger close/requeue/repair routing.
#
# Args: $1=repo_slug, $2=pr_number
# Returns: 0=terminal failure found, 1=no terminal failures, 2=API/parse error
#######################################
_check_required_checks_has_terminal_failure() {
	local repo_slug="$1"
	local pr_number="$2"

	local required_contexts=""
	required_contexts=$(_required_contexts_for_default_branch "$repo_slug") || return 2
	if [[ -z "$required_contexts" ]]; then
		echo "[pulse-merge] _check_required_checks_has_terminal_failure: no required contexts for ${repo_slug} — allowing (t3567)" >>"$LOGFILE"
		return 1
	fi

	local pr_sha=""
	pr_sha=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
		--json headRefOid --jq '.headRefOid' 2>/dev/null) || pr_sha=""
	if [[ -z "$pr_sha" ]]; then
		echo "[pulse-merge] _check_required_checks_has_terminal_failure: headRefOid fetch failed for PR #${pr_number} in ${repo_slug} — failing closed (t3567)" >>"$LOGFILE"
		return 2
	fi

	local rollup_json=""
	rollup_json=$(gh_pr_check_runs_rest "$repo_slug" "$pr_sha" 2>/dev/null) || rollup_json=""
	if [[ -z "$rollup_json" || "$rollup_json" == "null" ]]; then
		echo "[pulse-merge] _check_required_checks_has_terminal_failure: REST check-runs fetch failed for PR #${pr_number} in ${repo_slug} — failing closed (t3567)" >>"$LOGFILE"
		return 2
	fi

	local req_json
	req_json=$(printf '%s' "$required_contexts" \
		| jq -Rsc '[split("\n")[] | select(length > 0)]' 2>/dev/null) || req_json="[]"

	local failing_count="" _fc_exit=0
	failing_count=$(jq -n \
		--argjson req "$req_json" \
		--argjson checks "$rollup_json" \
		'$req | map(
			. as $ctx |
			($checks | map(select((.name // "") == $ctx)) | last) as $c |
			if $c == null then false
			elif (($c.conclusion // "" | ascii_downcase)
				| . == "failure" or . == "cancelled" or . == "timed_out" or . == "action_required") then true
			else false
			end
		) | map(select(.)) | length' 2>/dev/null)
	_fc_exit=$?

	if [[ $_fc_exit -ne 0 || -z "$failing_count" ]]; then
		echo "[pulse-merge] _check_required_checks_has_terminal_failure: jq evaluation failed for PR #${pr_number} in ${repo_slug} — failing closed (t3567)" >>"$LOGFILE"
		return 2
	fi

	if [[ "$failing_count" -gt 0 ]]; then
		echo "[pulse-merge] _check_required_checks_has_terminal_failure: ${failing_count} terminal failed required context(s) for PR #${pr_number} in ${repo_slug} (t3567)" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-merge] _check_required_checks_has_terminal_failure: no terminal failed required contexts for PR #${pr_number} in ${repo_slug} (t3567)" >>"$LOGFILE"
	return 1
}
