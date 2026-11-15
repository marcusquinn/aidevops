#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge-pr-closeout.sh — Merged-PR closing comment build and upsert
#
# Sourced by pulse-merge.sh (GH#38257). Builds the deterministic closing
# comment for a merged PR and converges PR closeout comments to one
# marker-bearing comment. Functions resolve dependencies lazily through the
# orchestrator: _gh_with_timeout, gh, LOGFILE and PULSE_START_EPOCH.
# _pm_routing_feedback resolves routing-feedback.mjs relative to this file,
# which lives in the same directory as pulse-merge.sh.
# This library only defines functions and never posts comments at source time.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard — preserve definitions when sourced more than once.
[[ -n "${_PULSE_MERGE_PR_CLOSEOUT_LOADED:-}" ]] && return 0
_PULSE_MERGE_PR_CLOSEOUT_LOADED=1

#######################################
# Build provider-neutral routing feedback for a merged issue.
# Args: $1=repo slug, $2=linked issue
# Stdout: markdown section or empty
# Returns: 0 always
#######################################
_pm_routing_feedback() {
	local repo_slug="$1"
	local linked_issue="$2"
	[[ -n "$linked_issue" ]] || return 0
	command -v node >/dev/null 2>&1 || return 0
	local module_dir="${BASH_SOURCE[0]%/*}"
	local feedback_helper="${AIDEVOPS_ROUTING_FEEDBACK_HELPER:-${module_dir}/routing-feedback.mjs}"
	[[ -r "$feedback_helper" ]] || return 0
	node "$feedback_helper" --repo "$repo_slug" --issue "$linked_issue" \
		--format markdown --heading-level 3 2>/dev/null || true
	return 0
}

#######################################
# Build the closing comment body for a merged PR (with signature footer).
# Args: $1=pr_number, $2=repo_slug, $3=linked_issue, $4=merge_summary, $5=pr_base_ref_name (optional)
# Stdout: closing comment body
# Returns: 0 always
#######################################
_pm_build_closing_comment() {
	local pr_number="$1" repo_slug="$2" linked_issue="$3" merge_summary="$4"
	local pr_base_ref_name="${5:-main}"
	local body
	if [[ -n "$merge_summary" ]]; then
		body="${merge_summary}

---
Merged via PR #${pr_number} to ${pr_base_ref_name}.
_Merged by deterministic merge pass (pulse-wrapper.sh)._"
	else
		body="Completed via PR #${pr_number}, merged to ${pr_base_ref_name}.

_Merged by deterministic merge pass (pulse-wrapper.sh). Neither MERGE_SUMMARY comment nor PR body text was available._"
	fi
	local routing_feedback=""
	routing_feedback=$(_pm_routing_feedback "$repo_slug" "$linked_issue")
	if [[ -n "$routing_feedback" ]]; then
		body="${body}

${routing_feedback}"
	fi

	local elapsed issue_ref="" footer
	elapsed=$(($(date +%s) - PULSE_START_EPOCH))
	[[ -n "$linked_issue" ]] && issue_ref="${repo_slug}#${linked_issue}"
	local sig_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/gh-signature-helper.sh"
	footer=$("$sig_helper" footer \
		--body "$body" --no-session --tokens 0 \
		--time "$elapsed" --session-type routine \
		${issue_ref:+--issue "$issue_ref"} --solved 2>/dev/null || true)
	printf '%s%s' "$body" "$footer"
	return 0
}

#######################################
# Return the preferred comment ID for a PR merge closeout upsert.
#
# Prefer an existing deterministic closeout marker. Otherwise reuse the
# worker's canonical MERGE_SUMMARY comment so post-merge handling transforms
# that singleton instead of appending a second completion summary.
#
# Args: $1=comments JSON (gh --paginate --slurp shape), $2=PR number
# Stdout: comment ID, or empty
# Returns: 0 always
#######################################
_pm_select_pr_closeout_comment_id() {
	local comments_json="$1"
	local pr_number="$2"
	local closeout_marker="<!-- PULSE_MERGE_CLOSEOUT:PR#${pr_number} -->"
	local legacy_merge_text="Merged via PR #${pr_number} to"
	local legacy_generic_text="Completed via PR #${pr_number}, merged to"

	printf '%s' "$comments_json" | jq -r \
		--arg array_type 'array' \
		--arg closeout_marker "$closeout_marker" \
		--arg legacy_generic_text "$legacy_generic_text" \
		--arg legacy_merge_text "$legacy_merge_text" \
		--arg merge_attribution 'Merged by deterministic merge pass (pulse-wrapper.sh).' \
		--arg summary_marker '<!-- MERGE_SUMMARY -->' '
		(if type == $array_type and (.[0]? | type) == $array_type then [.[][]]
		elif type == $array_type then .
		else [] end)
		| [ .[]
			| select(
				((.body // "") | contains($closeout_marker)) or
				((.body // "") | contains($summary_marker)) or
				(
					((.body // "") | contains($legacy_merge_text)) and
					((.body // "") | contains($merge_attribution))
				) or
				(
					((.body // "") | contains($legacy_generic_text)) and
					((.body // "") | contains($merge_attribution))
				)
			)
			| {
				id: .id,
				created_at: (.created_at // "")
			} ]
		| sort_by(.created_at, .id)
		| first
		| .id // empty
	' 2>/dev/null || true
	return 0
}

#######################################
# Converge deterministic PR closeout comments to one marker-bearing comment.
#
# Each concurrent runner performs reconciliation after its own write. The
# later writer therefore observes the earlier candidate, updates the same
# deterministic oldest winner, and removes every newer duplicate.
#
# Args: $1=PR number, $2=repo slug, $3=desired marked comment body
# Returns: 0 always (best-effort post-merge hygiene)
#######################################
_pm_reconcile_pr_closeout_comments() {
	local pr_number="$1"
	local repo_slug="$2"
	local marked_comment="$3"
	local comments_json="" closeout_ids="" keep_id="" previous_singleton_id="" comment_id=""
	local candidate_count=0 stable_observations=0 attempt=0 max_attempts=4
	local closeout_marker="<!-- PULSE_MERGE_CLOSEOUT:PR#${pr_number} -->"
	local legacy_merge_text="Merged via PR #${pr_number} to"
	local legacy_generic_text="Completed via PR #${pr_number}, merged to"

	while ((attempt < max_attempts)); do
		attempt=$((attempt + 1))
		comments_json=$(_gh_with_timeout read gh api "repos/${repo_slug}/issues/${pr_number}/comments?per_page=100" \
			--paginate --slurp 2>/dev/null) || comments_json=""
		if [[ -z "$comments_json" ]]; then
			((attempt < max_attempts)) && sleep 1
			continue
		fi

		closeout_ids=$(printf '%s' "$comments_json" | jq -r \
			--arg array_type 'array' \
			--arg closeout_marker "$closeout_marker" \
			--arg legacy_generic_text "$legacy_generic_text" \
			--arg legacy_merge_text "$legacy_merge_text" \
			--arg merge_attribution 'Merged by deterministic merge pass (pulse-wrapper.sh).' \
			--arg summary_marker '<!-- MERGE_SUMMARY -->' '
			(if type == $array_type and (.[0]? | type) == $array_type then [.[][]]
			elif type == $array_type then .
			else [] end)
			| [ .[]
				| select(
					((.body // "") | contains($closeout_marker)) or
					((.body // "") | contains($summary_marker)) or
					(
						((.body // "") | contains($legacy_merge_text)) and
						((.body // "") | contains($merge_attribution))
					) or
					(
						((.body // "") | contains($legacy_generic_text)) and
						((.body // "") | contains($merge_attribution))
					)
				)
				| {id: .id, created_at: (.created_at // "")} ]
			| sort_by(.created_at, .id)
			| .[].id
		' 2>/dev/null) || closeout_ids=""
		candidate_count=$(printf '%s\n' "$closeout_ids" | grep -c '.') || candidate_count=0
		if [[ "$candidate_count" -eq 0 ]]; then
			stable_observations=0
			previous_singleton_id=""
			((attempt < max_attempts)) && sleep 1
			continue
		fi

		keep_id=$(printf '%s\n' "$closeout_ids" | sed -n '1p')
		if gh api "repos/${repo_slug}/issues/comments/${keep_id}" \
			--method PATCH --field body="$marked_comment" >/dev/null 2>&1; then
			:
		else
			echo "[pulse-wrapper] Deterministic merge: failed to refresh canonical PR closeout comment ${keep_id} for ${repo_slug}#${pr_number} (attempt ${attempt}/${max_attempts}, GH#27502)" >>"$LOGFILE"
			stable_observations=0
			previous_singleton_id=""
			((attempt < max_attempts)) && sleep 1
			continue
		fi

		if [[ "$candidate_count" -eq 1 ]]; then
			if [[ "$keep_id" == "$previous_singleton_id" ]]; then
				stable_observations=$((stable_observations + 1))
			else
				stable_observations=1
				previous_singleton_id="$keep_id"
			fi
			if [[ "$stable_observations" -ge 2 ]]; then
				return 0
			fi
			((attempt < max_attempts)) && sleep 1
			continue
		fi
		stable_observations=0
		previous_singleton_id=""

		while IFS= read -r comment_id; do
			[[ -n "$comment_id" && "$comment_id" != "$keep_id" ]] || continue
			if gh api "repos/${repo_slug}/issues/comments/${comment_id}" \
				--method DELETE >/dev/null 2>&1; then
				echo "[pulse-wrapper] Deterministic merge: removed duplicate PR closeout comment ${comment_id} for ${repo_slug}#${pr_number} (GH#27502)" >>"$LOGFILE"
			else
				if [[ "$attempt" -lt "$max_attempts" ]]; then
					echo "[pulse-wrapper] Deterministic merge: failed to remove duplicate PR closeout comment ${comment_id} for ${repo_slug}#${pr_number}; retrying reconciliation (attempt ${attempt}/${max_attempts}, GH#27502)" >>"$LOGFILE"
				else
					echo "[pulse-wrapper] Deterministic merge: duplicate PR closeout comment ${comment_id} remains after ${max_attempts} reconciliation attempts for ${repo_slug}#${pr_number} (GH#27502)" >>"$LOGFILE"
				fi
			fi
		done <<<"$closeout_ids"
		((attempt < max_attempts)) && sleep 1
	done
	echo "[pulse-wrapper] Deterministic merge: PR closeout reconciliation did not reach two stable singleton observations for ${repo_slug}#${pr_number} after ${max_attempts} attempts (GH#27502)" >>"$LOGFILE"
	return 0
}

#######################################
# Upsert the deterministic PR merge closeout without duplicate summaries.
#
# The normal path patches the existing MERGE_SUMMARY comment. The fallback
# posts one marker-bearing comment, then reconciles concurrent fallback writes.
# This is cross-runner safe; local pulse locks only coordinate one machine.
#
# Args: $1=PR number, $2=repo slug, $3=closing comment body
# Returns: 0 always (best-effort post-merge hygiene)
#######################################
_pm_upsert_pr_closing_comment() {
	local pr_number="$1"
	local repo_slug="$2"
	local closing_comment="$3"
	local comments_json="" existing_comment_id="" created_comment_id="" marked_comment=""

	marked_comment="<!-- PULSE_MERGE_CLOSEOUT:PR#${pr_number} -->
${closing_comment}"
	comments_json=$(_gh_with_timeout read gh api "repos/${repo_slug}/issues/${pr_number}/comments?per_page=100" \
		--paginate --slurp 2>/dev/null) || comments_json=""
	if [[ -n "$comments_json" ]]; then
		existing_comment_id=$(_pm_select_pr_closeout_comment_id "$comments_json" "$pr_number")
	fi

	if [[ -n "$existing_comment_id" ]] && gh api \
		"repos/${repo_slug}/issues/comments/${existing_comment_id}" \
		--method PATCH --field body="$marked_comment" >/dev/null 2>&1; then
		echo "[pulse-wrapper] Deterministic merge: upserted PR closeout comment ${existing_comment_id} for ${repo_slug}#${pr_number} (GH#27502)" >>"$LOGFILE"
		_pm_reconcile_pr_closeout_comments "$pr_number" "$repo_slug" "$marked_comment"
		return 0
	fi

	created_comment_id=$(gh api "repos/${repo_slug}/issues/${pr_number}/comments" \
		--method POST --field body="$marked_comment" --jq '.id // empty' 2>/dev/null) || created_comment_id=""
	if [[ -z "$created_comment_id" ]]; then
		echo "[pulse-wrapper] Deterministic merge: failed to create PR closeout for merged ${repo_slug}#${pr_number}; post-merge publication ended without a canonical PR comment (GH#27502)" >>"$LOGFILE"
		return 0
	fi
	_pm_reconcile_pr_closeout_comments "$pr_number" "$repo_slug" "$marked_comment"
	return 0
}
