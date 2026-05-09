#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge-duplicate-consolidation.sh — safe duplicate worker PR consolidation for the deterministic merge pass.
#
# Sourced by pulse-merge-process.sh. Do not execute directly.

[[ -n "${_PULSE_MERGE_DUPLICATE_CONSOLIDATION_LOADED:-}" ]] && return 0
_PULSE_MERGE_DUPLICATE_CONSOLIDATION_LOADED=1

: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"

#######################################
# Return comma-padded label CSV for a PR JSON object.
#
# Args: $1 = PR JSON object
# Output: ,label-a,label-b,
#######################################
_pmp_pr_label_csv() {
	local pr_obj="$1"
	local labels_csv
	labels_csv=$(printf '%s' "$pr_obj" | jq -r '[.labels[]?.name] | join(",")' 2>/dev/null) || labels_csv=""
	printf ',%s,' "$labels_csv"
	return 0
}

#######################################
# Determine whether pulse owns a PR strongly enough to auto-close it as a
# superseded duplicate. This intentionally excludes origin:interactive and
# external/untrusted PRs even if they are bot-authored.
#
# Args: $1 = PR JSON object
# Returns: 0 owned worker PR, 1 protected/unknown
#######################################
_pmp_pr_is_worker_owned_for_consolidation() {
	local pr_obj="$1"
	local labels_csv
	labels_csv=$(_pmp_pr_label_csv "$pr_obj")
	case "$labels_csv" in
	*,origin:interactive,* | *,needs-maintainer-review,*) return 1 ;;
	*,origin:worker,* | *,origin:worker-takeover,*) return 0 ;;
	esac
	return 1
}

#######################################
# Check issue labels that block duplicate-PR consolidation.
#
# Args: $1 = repo slug, $2 = issue number
# Returns: 0 blocked, 1 safe/unknown
#######################################
_pmp_issue_blocks_pr_consolidation() {
	local repo_slug="$1"
	local issue_number="$2"
	local issue_labels
	issue_labels=$(gh api "repos/${repo_slug}/issues/${issue_number}" \
		--jq '[.labels[]?.name] | join(",")' 2>/dev/null) || issue_labels=""
	case ",$issue_labels," in
	*,needs-maintainer-review,* | *,security,* | *,parent-task,* | *,research,* | *,research-task,*) return 0 ;;
	esac
	return 1
}

#######################################
# Compute a deterministic health score for candidate selection.
# Higher is better; createdAt is used by the caller as the newest tie-breaker.
#
# Args: $1 = repo slug, $2 = PR JSON object
# Output: numeric score
#######################################
_pmp_pr_consolidation_health_score() {
	local repo_slug="$1"
	local pr_obj="$2"
	local pr_number="" mergeable="UNKNOWN" review="NONE" is_draft="false" score=0
	{ IFS=$'\t' read -r pr_number mergeable review is_draft; } < <(
		printf '%s' "$pr_obj" | jq -r '[
			.number // "",
			.mergeable // "UNKNOWN",
			(if (.reviewDecision | length) == 0 then "NONE" else .reviewDecision end),
			(.isDraft // false | tostring)
		] | @tsv' 2>/dev/null
	)
	score=0
	if [[ "$pr_number" =~ ^[0-9]+$ ]] && declare -F _pr_required_checks_pass >/dev/null 2>&1; then
		if _pr_required_checks_pass "$pr_number" "$repo_slug"; then
			score=$((score + 400))
		fi
	fi
	if declare -F _pmp_normalize_mergeable_state_into >/dev/null 2>&1; then
		_pmp_normalize_mergeable_state_into mergeable "$mergeable"
	fi
	[[ "$mergeable" == "MERGEABLE" ]] && score=$((score + 200))
	[[ "$review" == "APPROVED" ]] && score=$((score + 100))
	[[ "$is_draft" != "true" ]] && score=$((score + 50))
	printf '%s' "$score"
	return 0
}

#######################################
# Close a superseded sibling PR after the winning candidate has been verified
# against the linked issue. Never closes the issue; this only reduces duplicate
# PR churn while preserving the verified candidate.
#
# Args: $1 = repo slug, $2 = issue number, $3 = superseded PR, $4 = candidate PR
# Returns: 0 always
#######################################
_pmp_close_superseded_sibling_pr() {
	local repo_slug="$1"
	local issue_number="$2"
	local superseded_pr="$3"
	local candidate_pr="$4"

	[[ "$superseded_pr" =~ ^[0-9]+$ && "$candidate_pr" =~ ^[0-9]+$ ]] || return 0
	[[ "$superseded_pr" != "$candidate_pr" ]] || return 0

	gh pr close "$superseded_pr" --repo "$repo_slug" \
		--comment "Closing as superseded by PR #${candidate_pr} for issue #${issue_number}.

Pulse selected PR #${candidate_pr} as the newest/healthiest verified worker-owned candidate for this duplicate PR group. Evidence required before this close: same linked issue (#${issue_number}), worker-owned origin labels on both PRs, no maintainer/security gate on the linked issue, and verify-issue-close-helper confirmation that PR #${candidate_pr} matches the issue scope.

_Closed by deterministic merge pass duplicate-PR consolidation (m-20260508-0e27c3 task 2.4)._" \
		2>/dev/null || true
	echo "[pulse-wrapper] Duplicate PR consolidation: closed PR #${superseded_pr} in ${repo_slug} as superseded by verified candidate PR #${candidate_pr} for issue #${issue_number}" >>"$LOGFILE"
	return 0
}

#######################################
# Process one duplicate sibling PR group for a linked issue.
#
# Args: $1 = repo slug, $2 = issue number, $3 = group file
# Returns: 0 always
#######################################
_pmp_consolidate_duplicate_pr_group() {
	local repo_slug="$1"
	local issue_number="$2"
	local group_file="$3"
	local group_count=0 candidate_line="" candidate_pr=""
	group_count=$(grep -c "^${issue_number}|" "$group_file" 2>/dev/null || true)
	[[ "$group_count" =~ ^[0-9]+$ ]] || group_count=0
	[[ "$group_count" -gt 1 ]] || return 0

	if _pmp_issue_blocks_pr_consolidation "$repo_slug" "$issue_number"; then
		echo "[pulse-wrapper] Duplicate PR consolidation: skipping issue #${issue_number} in ${repo_slug} because labels require maintainer/security/research handling" >>"$LOGFILE"
		return 0
	fi

	candidate_line=$(grep "^${issue_number}|" "$group_file" | sort -t'|' -k3,3nr -k4,4r | head -1) || candidate_line=""
	candidate_pr=$(printf '%s' "$candidate_line" | cut -d'|' -f2)
	[[ "$candidate_pr" =~ ^[0-9]+$ ]] || return 0
	if ! _verify_superseding_pr_for_issue "$issue_number" "$candidate_pr" "$repo_slug"; then
		echo "[pulse-wrapper] Duplicate PR consolidation: candidate PR #${candidate_pr} for issue #${issue_number} failed verification — leaving sibling PRs open" >>"$LOGFILE"
		return 0
	fi

	while IFS='|' read -r _issue pr_number _score _created; do
		[[ "$pr_number" =~ ^[0-9]+$ ]] || continue
		[[ "$pr_number" != "$candidate_pr" ]] || continue
		_pmp_close_superseded_sibling_pr "$repo_slug" "$issue_number" "$pr_number" "$candidate_pr"
	done < <(grep "^${issue_number}|" "$group_file")
	return 0
}

#######################################
# Safely consolidate duplicate worker-owned PR groups before merge iteration.
# The function is no-op unless at least two open worker-owned PRs resolve the
# same linked issue and the selected candidate has independent verification.
#
# Args: $1 = repo slug, $2 = open PR JSON array
# Returns: 0 always
#######################################
_pmp_consolidate_duplicate_pr_groups() {
	local repo_slug="$1"
	local pr_json="$2"
	local pr_count
	pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null) || pr_count=0
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0
	[[ "$pr_count" -gt 1 ]] || return 0
	[[ "${PULSE_MERGE_CONSOLIDATE_DUPLICATE_PRS:-true}" == "true" ]] || return 0

	local group_file
	group_file=$(mktemp 2>/dev/null) || group_file="${TMPDIR:-/tmp}/pulse-duplicate-pr-groups-$$.tmp"
	: >"$group_file"

	local pr_number="" created_at="" pr_obj="" linked_issue="" score=0
	while IFS=$'\t' read -r pr_number created_at pr_obj; do
		linked_issue=""
		score=0
		[[ -n "$pr_obj" ]] || continue
		_pmp_pr_is_worker_owned_for_consolidation "$pr_obj" || continue
		[[ "$pr_number" =~ ^[0-9]+$ ]] || continue
		linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || linked_issue=""
		[[ "$linked_issue" =~ ^[0-9]+$ ]] || continue
		score=$(_pmp_pr_consolidation_health_score "$repo_slug" "$pr_obj") || score=0
		printf '%s|%s|%s|%s\n' "$linked_issue" "$pr_number" "$score" "$created_at" >>"$group_file"
	done < <(printf '%s' "$pr_json" | jq -r '.[] | [(.number // "" | tostring), (.createdAt // ""), (. | tojson)] | @tsv' 2>/dev/null)

	local issue_number
	while IFS= read -r issue_number; do
		[[ "$issue_number" =~ ^[0-9]+$ ]] || continue
		_pmp_consolidate_duplicate_pr_group "$repo_slug" "$issue_number" "$group_file"
	done < <(cut -d'|' -f1 "$group_file" | sort -u)

	rm -f "$group_file" 2>/dev/null || true
	return 0
}
