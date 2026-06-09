#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge-required-checks.sh — required-check terminal-state classifiers.

[[ -n "${_PULSE_MERGE_REQUIRED_CHECKS_LOADED:-}" ]] && return 0
_PULSE_MERGE_REQUIRED_CHECKS_LOADED=1

#######################################
# Fallback required-check verification for repositories where the classic branch
# protection endpoint and repository-rulesets endpoint expose no contexts, but
# GitHub still reports PR-level required checks (for example org-level rulesets).
#
# Args: $1=repo_slug, $2=pr_number
# Returns: 0=all reported required checks passing or none reported,
#          1=at least one reported required check is not passing,
#          2=API/parse error
#######################################
_check_required_pr_checks_passing_fallback() {
	local repo_slug="$1"
	local pr_number="$2"

	local checks_json=""
	local checks_exit=0
	checks_json=$(gh pr checks "$pr_number" --repo "$repo_slug" --required --json name,state,bucket 2>/dev/null)
	checks_exit=$?
	if [[ $checks_exit -ne 0 && -z "$checks_json" ]]; then
		return 2
	fi
	if [[ -z "$checks_json" || "$checks_json" == "null" || "$checks_json" == "[]" ]]; then
		if [[ $checks_exit -ne 0 ]]; then
			return 2
		fi
		printf '[]\n'
		return 0
	fi

	local nonpassing_count="" _pc_exit=0
	nonpassing_count=$(printf '%s' "$checks_json" \
		| jq '[.[]? | select((.bucket // "") != "pass")] | length' 2>/dev/null)
	_pc_exit=$?
	if [[ $_pc_exit -ne 0 || -z "$nonpassing_count" ]]; then
		return 2
	fi

	if [[ "$nonpassing_count" -gt 0 ]]; then
		return 1
	fi
	return 0
}

#######################################
# Resolve the maximum required approval count from active rulesets matching
# the repository default branch. This is separate from required status checks:
# GitHub stores ruleset approval requirements under pull_request rules, not as
# CI contexts, so an empty status context list is not enough to allow a merge.
#
# Args: $1=repo_slug, $2=default_branch
# Stdout: integer maximum required_approving_review_count (0 when none)
# Returns: 0=requirement resolved, 1=ruleset API/parse error
#######################################
_ruleset_required_review_count_for_default_branch() {
	local repo_slug="$1"
	local default_branch="$2"

	local rulesets_json=""
	rulesets_json=$(gh api "repos/${repo_slug}/rulesets" 2>/dev/null) || {
		echo "[pulse-merge] _ruleset_required_review_count_for_default_branch: rulesets list failed for ${repo_slug} — caller will fail closed (GH#24577)" >>"$LOGFILE"
		return 1
	}
	[[ -n "$rulesets_json" && "$rulesets_json" != "[]" && "$rulesets_json" != null ]] || {
		printf '0'
		return 0
	}

	local active_ids=""
	active_ids=$(printf '%s' "$rulesets_json" | jq -r '.[]? | select(.enforcement == "active") | .id // empty' 2>>"$LOGFILE") || {
		echo "[pulse-merge] _ruleset_required_review_count_for_default_branch: rulesets list parse failed for ${repo_slug} — caller will fail closed (GH#24577)" >>"$LOGFILE"
		return 1
	}
	[[ -n "$active_ids" ]] || {
		printf '0'
		return 0
	}

	local max_required=0
	local id="" detail="" include_patterns="" exclude_patterns="" pattern=""
	local matches_default=0 excluded_default=0 approval_count=""
	while IFS= read -r id; do
		[[ -n "$id" ]] || continue
		detail=$(gh api "repos/${repo_slug}/rulesets/${id}" 2>/dev/null) || {
			echo "[pulse-merge] _ruleset_required_review_count_for_default_branch: ruleset detail ${id} failed for ${repo_slug} — caller will fail closed (GH#24577)" >>"$LOGFILE"
			return 1
		}
		include_patterns=$(printf '%s' "$detail" | jq -r '.conditions?.ref_name?.include? // [] | .[]?' 2>>"$LOGFILE") || return 1
		exclude_patterns=$(printf '%s' "$detail" | jq -r '.conditions?.ref_name?.exclude? // [] | .[]?' 2>>"$LOGFILE") || return 1

		matches_default=0
		while IFS= read -r pattern; do
			[[ -n "$pattern" ]] || continue
			_ruleset_ref_matches_default_branch "$pattern" "$default_branch" || continue
			matches_default=1
			break
		done <<<"$include_patterns"
		[[ "$matches_default" -eq 1 ]] || continue

		excluded_default=0
		while IFS= read -r pattern; do
			[[ -n "$pattern" ]] || continue
			_ruleset_ref_matches_default_branch "$pattern" "$default_branch" || continue
			excluded_default=1
			break
		done <<<"$exclude_patterns"
		[[ "$excluded_default" -eq 0 ]] || continue

		approval_count=$(printf '%s' "$detail" | jq -r '[.rules[]? | select(.type == "pull_request") | (.parameters?.required_approving_review_count? // 0)] | max // 0' 2>>"$LOGFILE") || {
			echo "[pulse-merge] _ruleset_required_review_count_for_default_branch: pull-request rule parse failed for ruleset ${id} in ${repo_slug} — caller will fail closed (GH#24577)" >>"$LOGFILE"
			return 1
		}
		[[ "$approval_count" =~ ^[0-9]+$ ]] || approval_count=0
		[[ "$approval_count" -gt "$max_required" ]] && max_required="$approval_count"
	done <<<"$active_ids"

	printf '%s' "$max_required"
	return 0
}

#######################################
# Verify active ruleset pull_request approval requirements for one PR.
#
# Args: $1=repo_slug, $2=pr_number, $3=pr_author
# Returns: 0=passes/no ruleset approval requirement, 1=missing/unverifiable
#######################################
_check_ruleset_required_reviews_passing() {
	local repo_slug="$1"
	local pr_number="$2"
	local pr_author="$3"

	local default_branch="" required_count=""
	default_branch=$(gh api "repos/${repo_slug}" --jq '.default_branch' 2>/dev/null) || default_branch=""
	if [[ -z "$default_branch" ]]; then
		echo "[pulse-merge] _check_ruleset_required_reviews_passing: failed to resolve default branch for ${repo_slug} — failing closed (GH#24577)" >>"$LOGFILE"
		return 1
	fi
	required_count=$(_ruleset_required_review_count_for_default_branch "$repo_slug" "$default_branch") || return 1
	[[ "$required_count" =~ ^[0-9]+$ ]] || required_count=0
	[[ "$required_count" -eq 0 ]] && return 0

	local reviews_json="" approved_count=""
	reviews_json=$(gh_pr_view "$pr_number" --repo "$repo_slug" --json reviews 2>/dev/null) || reviews_json=""
	if [[ -z "$reviews_json" || "$reviews_json" == null ]]; then
		echo "[pulse-merge] _check_ruleset_required_reviews_passing: review fetch failed for PR #${pr_number} in ${repo_slug} with ruleset requiring ${required_count} approval(s) — failing closed (GH#24577)" >>"$LOGFILE"
		return 1
	fi
	approved_count=$(jq -r --arg author "$pr_author" '
		[.reviews[]?] | sort_by(.submittedAt // "") | group_by(.author.login // "")
		| map(last) | map(select((.author.login // "") != $author))
		| map(select((.state // "" | ascii_upcase) == "APPROVED")) | length
	' <<<"$reviews_json" 2>/dev/null) || approved_count=""
	if [[ ! "$approved_count" =~ ^[0-9]+$ ]]; then
		echo "[pulse-merge] _check_ruleset_required_reviews_passing: review parse failed for PR #${pr_number} in ${repo_slug} — failing closed (GH#24577)" >>"$LOGFILE"
		return 1
	fi
	if [[ "$approved_count" -lt "$required_count" ]]; then
		echo "[pulse-merge] _check_ruleset_required_reviews_passing: PR #${pr_number} in ${repo_slug} has ${approved_count}/${required_count} ruleset-required approval(s) — deferring merge (GH#24577)" >>"$LOGFILE"
		return 1
	fi
	echo "[pulse-merge] _check_ruleset_required_reviews_passing: PR #${pr_number} in ${repo_slug} satisfies ${approved_count}/${required_count} ruleset-required approval(s) (GH#24577)" >>"$LOGFILE"
	return 0
}

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
		--json headRefOid --jq '.headRefOid // ""') || true
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
				| . == "failure" or . == "cancelled" or . == "timed_out") then true
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
