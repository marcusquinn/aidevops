#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pulse-merge-todo-handoff.sh — GH#36112: supersede conflicting Pulse TODO
# handoff PRs instead of repairing or holding them.
#
# pulse-todo-publication.sh publishes a protected-default TODO projection as a
# PR on aidevops/pulse-todo-<id> whose body lists non-closing `Ref #N` lines.
# Once another TODO.md change lands, the handoff conflicts. Generic conflict
# handling then resolved `Ref #N` as the PR's work issue, held the PR when N
# was closed-completed, and the publisher deferred every later TODO sync
# behind the held PR (#34422, #35666, #36021).
#
# The handoff is regenerable: the publisher recomputes still-needed refs from
# the current default branch on its next cycle. A trusted conflicting handoff
# is therefore closed with its branch and never routed to an issue.
#
# Ownership labels are respected. hold-for-review counts as automation-applied
# only when a trusted closed-issue receipt binds it to this PR's exact head;
# runners on older versions keep writing that receipt until they update.
#
# Sourced by pulse-merge.sh. Uses _pulse_is_trusted_issue_sync_pr
# (pulse-merge-gates.sh) and, when loaded, _feedback_route_trusted_entries
# (pulse-merge-feedback-finalizer.sh); without it a hold stays preserved.

[[ -n "${_PULSE_MERGE_TODO_HANDOFF_LOADED:-}" ]] && return 0
_PULSE_MERGE_TODO_HANDOFF_LOADED=1

: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"

_PMTH_BRANCH_PREFIX="aidevops/pulse-todo-"
_PMTH_HOLD_LABEL="hold-for-review"
# Stage return codes shared with _pmp_stage_handle_conflict.
_PMTH_PROCEED=10
_PMTH_CLOSED=2
_PMTH_SKIP=1

_pmth_gh_write() {
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout write gh "$@"
		return $?
	fi
	gh "$@"
	return $?
}

#######################################
# Prove a hold-for-review came from the closed-issue feedback guard.
# Args: $1=pr_number $2=repo_slug $3=exact head SHA
# Returns: 0 when a verified repository writer posted the closed-issue receipt
#          for this PR and exact head; 1 otherwise, including any read failure.
#######################################
_pmth_hold_is_closed_issue_receipt() {
	local pr_number="$1"
	local repo_slug="$2"
	local head_sha="$3"
	local comments="" candidates="" trusted="" count=""

	[[ "$pr_number" =~ ^[0-9]+$ && "$head_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
	declare -F _feedback_route_trusted_entries >/dev/null 2>&1 || return 1
	comments=$(gh api "repos/${repo_slug}/issues/${pr_number}/comments?per_page=100" \
		--paginate --slurp 2>/dev/null) || return 1
	#aidevops:trust-boundary — the receipt marker opens the comment and binds the
	# PR number and exact head; only verified repository writers count.
	candidates=$(printf '%s' "$comments" | jq -c --arg pr "$pr_number" --arg head "$head_sha" '
		(if (.[0]? | type) == "array" then add else . end)
		| [.[]?
			| select((.body // "") | test("^<!-- feedback-route:closed-issue:PR" + $pr
				+ ":ISSUE[0-9]+:SHA" + $head + "(:RUNNER[A-Za-z0-9_-]+)? -->"))
			| {login: (.user.login // ""), association: (.author_association // "")}]' 2>/dev/null) || return 1
	trusted=$(_feedback_route_trusted_entries "$repo_slug" <<<"$candidates") || return 1
	count=$(printf '%s' "$trusted" | jq 'length' 2>/dev/null) || return 1
	[[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || return 1
	return 0
}

#######################################
# Args: $1=pr_number $2=repo_slug $3=exact head SHA $4=labels CSV
# Returns: 0 when automatic supersession is allowed, 1 when a hold is preserved.
#######################################
_pmth_labels_allow_supersede() {
	local pr_number="$1"
	local repo_slug="$2"
	local head_sha="$3"
	local labels="$4"

	case ",${labels}," in
	*,no-takeover,* | *,needs-maintainer-review,* | *,external-contributor,*) return 1 ;;
	esac
	[[ ",${labels}," == *",${_PMTH_HOLD_LABEL},"* ]] || return 0
	_pmth_hold_is_closed_issue_receipt "$pr_number" "$repo_slug" "$head_sha" || return 1
	return 0
}

#######################################
# Conflict-stage hook: supersede a trusted conflicting Pulse TODO handoff.
# Args: $1=pr_number $2=repo_slug $3=head ref name $4=exact head SHA $5=labels CSV
# Returns: 10 = not a trusted handoff; continue generic conflict handling
#           2 = superseded and closed
#           1 = handoff left untouched this cycle (hold, unverifiable, close failed)
#######################################
_pmth_handle_conflicting_handoff() {
	local pr_number="$1"
	local repo_slug="$2"
	local head_ref_name="$3"
	local head_sha="$4"
	local labels="$5"
	local trust_rc=0 close_rc=0

	[[ "$head_ref_name" == "${_PMTH_BRANCH_PREFIX}"* ]] || return "$_PMTH_PROCEED"
	[[ -n "$head_sha" ]] || return "$_PMTH_SKIP"
	#aidevops:trust-boundary — exact head, same repository, write-permission
	# author and TODO-only files (shared review-bot-gate predicate). Lookalikes
	# fall through to generic handling; unavailable evidence touches nothing.
	if declare -F _pulse_is_trusted_issue_sync_pr >/dev/null 2>&1; then
		_pulse_is_trusted_issue_sync_pr "$pr_number" "$repo_slug" "$head_sha" || trust_rc=$?
	else
		trust_rc=2
	fi
	case "$trust_rc" in
	0) ;;
	1) return "$_PMTH_PROCEED" ;;
	*)
		echo "[pulse-wrapper] Merge pass: Pulse TODO handoff PR #${pr_number} in ${repo_slug} is CONFLICTING but trust evidence is unavailable — retrying next cycle (GH#36112)" >>"$LOGFILE"
		return "$_PMTH_SKIP"
		;;
	esac
	if ! _pmth_labels_allow_supersede "$pr_number" "$repo_slug" "$head_sha" "$labels"; then
		echo "[pulse-wrapper] Merge pass: conflicting Pulse TODO handoff PR #${pr_number} in ${repo_slug} carries an ownership hold — not superseding or routing (GH#36112)" >>"$LOGFILE"
		return "$_PMTH_SKIP"
	fi
	_pmth_gh_write pr close "$pr_number" --repo "$repo_slug" --delete-branch \
		--comment "Superseded: this Pulse TODO handoff conflicts with the default branch. It is a generated projection of GitHub issue state, so the next Pulse TODO sync regenerates any still-needed refs from the current default branch. No repair worker is dispatched and no referenced issue is changed.

_Closed by deterministic merge pass (GH#36112)._" >/dev/null 2>&1 || close_rc=$?
	if declare -F _pulse_merge_invalidate_pr_list_cache >/dev/null 2>&1; then
		_pulse_merge_invalidate_pr_list_cache "$repo_slug" "superseded Pulse TODO handoff PR #${pr_number}"
	fi
	if [[ "$close_rc" -ne 0 ]]; then
		echo "[pulse-wrapper] Merge pass: closing superseded Pulse TODO handoff PR #${pr_number} in ${repo_slug} failed (rc=${close_rc}) — retrying next cycle (GH#36112)" >>"$LOGFILE"
		return "$_PMTH_SKIP"
	fi
	echo "[pulse-wrapper] Merge pass: superseded conflicting Pulse TODO handoff PR #${pr_number} in ${repo_slug}; TODO sync regenerates from the current default branch (GH#36112)" >>"$LOGFILE"
	return "$_PMTH_CLOSED"
}
