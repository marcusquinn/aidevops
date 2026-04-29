#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge.sh — Co-extracted pr-gates + merge clusters (2-cycle) — PR gate checks (external contributor, permission, workflow scope) and merge-ready PR processing + linked-issue extraction.
#
# Extracted from pulse-wrapper.sh in Phase 4 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# NOTE: This module contains TWO clusters (pr-gates + merge) that form a
# dependency cycle. They must be co-located in the same module so bash's
# lazy function name resolution can see both sides of the cycle after a
# single source. Splitting them would require defining stubs or ordering
# sources against call graphs — the plan chose co-extraction as simpler.
#
# GH#21301: further split — PR gate functions into pulse-merge-gates.sh,
# merge processing helpers into pulse-merge-process.sh. Functions over
# 100 lines stay here to preserve (file, fname) identity keys for the
# complexity scanners. Bash's lazy function resolution handles all
# cross-module calls at invocation time.
#
# In GH#19836 the module was further trimmed by extracting two downstream
# clusters that are called after the gate checks fire. They are sourced
# by pulse-wrapper.sh AFTER pulse-merge.sh so they can use shared merge
# helpers such as _extract_linked_issue, while Bash lazy resolution keeps
# the runtime cross-module calls safe. The dependency is one-way only
# (downstream → core); merge-core/pr-gates do not require the downstream
# modules at source time:
#   - pulse-merge-conflict.sh — conflict handling, interactive handover,
#     carry-forward diff, rebase nudges
#   - pulse-merge-feedback.sh — CI/conflict/review feedback routing to
#     linked issues with PR close
# Example cross-module call: _check_pr_merge_gates (merge-core) →
# _dispatch_pr_fix_worker (feedback) is resolved at invocation time.
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* configuration constants in the bootstrap
# section.
#
# Functions in this module (in source order):
#   - _pm_issue_api                          (module-level helper)
#   Functions delegated to sub-libraries:
#   - pulse-merge-gates.sh: check_external_contributor_pr, _external_pr_has_linked_issue,
#     _external_pr_linked_issue_crypto_approved, _pulse_merge_admin_safety_check,
#     check_permission_failure_pr, approve_collaborator_pr, check_pr_modifies_workflows,
#     check_gh_workflow_scope, check_workflow_merge_guard
#   - pulse-merge-process.sh: merge_ready_prs_all_repos, _merge_ready_prs_for_repo,
#     _attempt_pr_update_branch, _resolve_pr_mergeable_status,
#     _pulse_merge_dismiss_coderabbit_nits, _pr_required_checks_pass,
#     _attempt_pr_ci_rebase_retry, _route_pr_to_fix_worker,
#     _retarget_stacked_children, _attempt_worker_briefed_auto_merge,
#     _check_required_checks_passing
#   - pulse-merge-author-checks.sh: _is_collaborator_author,
#     _is_owner_or_member_author, _check_interactive_pr_gates
#   Functions kept here (>100 lines — identity-key preservation):
#   - _check_pr_merge_gates                  (166 lines)
#   - _handle_post_merge_actions             (107 lines)
#   - _process_single_ready_pr               (211 lines)
#   Extraction utilities (used by downstream modules):
#   - _extract_linked_issue
#   - _extract_merge_summary
#
# This was originally a pure move from pulse-wrapper.sh. Later additions
# (rebase nudges GH#18650/GH#18815, review-feedback routing t2093, the
# GH#19836 split, GH#21301 sub-library split) preserve that call site.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_MERGE_LOADED:-}" ]] && return 0
_PULSE_MERGE_LOADED=1

# t2863: Module-level variable defaults (set -u guards).
# When this module is sourced standalone (e.g. pulse-merge-routine.sh, test
# harnesses), the pulse-wrapper.sh bootstrap has NOT run. Guard each bare var
# used across this module's functions so set -u does not abort them.
# The :=default form sets the var only when unset or empty; pre-existing values
# from the orchestrator bootstrap are preserved.
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"
: "${STOP_FLAG:=${HOME}/.aidevops/logs/pulse-session.stop}"
: "${PULSE_MERGE_BATCH_LIMIT:=50}"
: "${PULSE_MERGE_CLOSE_CONFLICTING:=true}"

# Comma-delimited label pattern constant — avoids matching "origin:worker-takeover"
# when checking for "origin:worker" in comma-joined label strings. (t2449)
_OW_LABEL_PAT=",origin:worker,"

# Build issue API path from repo slug and issue number. Module-level helper
# avoids repeating the path literal across multiple function scopes.
_pm_issue_api() {
	local slug="$1"
	local issue_num="$2"
	printf 'repos/%s/issues/%s' "$slug" "$issue_num"
	return 0
}

# Source shared claim-lifecycle helpers (t2429). The _release_interactive_claim_on_merge
# function was extracted to shared-claim-lifecycle.sh so that both pulse-merge.sh and
# full-loop-helper.sh can call it after a successful PR merge. SCRIPT_DIR may not be set
# when this module is sourced by pulse-wrapper.sh; resolve from BASH_SOURCE.
_PULSE_MERGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_PULSE_MERGE_DIR}/shared-claim-lifecycle.sh"

# Source shared phase-filing helpers (t2740). auto_file_next_phase is called
# from _handle_post_merge_actions to auto-file the next phase child issue
# when a phase child PR merges for a parent-task issue.
source "${_PULSE_MERGE_DIR}/shared-phase-filing.sh"

# Source author permission check helpers (GH#21426 — extracted to bring
# pulse-merge.sh below the 2000-line file-size-debt threshold).
# shellcheck source=./pulse-merge-author-checks.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _PULSE_MERGE_DIR
source "${_PULSE_MERGE_DIR}/pulse-merge-author-checks.sh"

# Source PR gate checking functions (GH#21301 — extracted to bring
# pulse-merge.sh below the 1500-line file-size-debt threshold).
# shellcheck source=./pulse-merge-gates.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _PULSE_MERGE_DIR
source "${_PULSE_MERGE_DIR}/pulse-merge-gates.sh"

# Source merge processing helpers (GH#21301 — extracted to bring
# pulse-merge.sh below the 1500-line file-size-debt threshold).
# shellcheck source=./pulse-merge-process.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _PULSE_MERGE_DIR
source "${_PULSE_MERGE_DIR}/pulse-merge-process.sh"

# _release_interactive_claim_on_merge is now provided by shared-claim-lifecycle.sh
# (sourced at the top of this module, t2429/GH#20067). The backward-compatible
# underscore-prefixed alias is defined there so all existing call sites
# (including _handle_post_merge_actions below) continue to work unchanged.

#######################################
# Run all merge-eligibility gate checks for a single PR.
# Returns 0 if all gates pass (PR may proceed to merge).
# Returns 1 if any gate fails (PR should be skipped).
# Args: $1=pr_number, $2=repo_slug, $3=pr_author, $4=pr_review, $5=linked_issue
#######################################
_check_pr_merge_gates() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="$3"
	local pr_review="$4"
	local linked_issue="$5"

	# Skip CHANGES_REQUESTED — needs a fix worker, not a merge.
	#
	# t2093: For worker-authored PRs with a linked issue, the "skip and hope"
	# path leaks stuck PRs indefinitely — no human owns worker PRs, the
	# dispatch-dedup guard blocks re-dispatch while the PR is open, and the
	# review-followup pipeline only fires on *merged* PRs. Route the review
	# feedback to the linked issue body and close the PR so the next pulse
	# cycle picks the issue up with fresh context. Interactive PRs are
	# always left alone (their humans own the feedback loop); external
	# contributors go through their own crypto-approval flow.
	#
	# t2179: coderabbit-nits-ok override — if the maintainer applied the
	# label and EVERY CHANGES_REQUESTED reviewer is coderabbitai[bot],
	# auto-dismiss those reviews and fall through to the next gate. If any
	# human reviewer is also blocking, the label is ignored.
	if [[ "$pr_review" == "CHANGES_REQUESTED" ]]; then
		# Fetch labels once — reused by both the nits-ok check and the
		# worker-routing block below.
		local _cr_pr_labels
		_cr_pr_labels=$(gh pr view "$pr_number" --repo "$repo_slug" \
			--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || _cr_pr_labels=""

		# t2179: coderabbit-nits-ok path.
		if [[ ",${_cr_pr_labels}," == *",coderabbit-nits-ok,"* ]]; then
			if _pulse_merge_dismiss_coderabbit_nits "$pr_number" "$repo_slug"; then
				echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — auto-dismissed CodeRabbit-only CHANGES_REQUESTED reviews (coderabbit-nits-ok label) (t2179)" >>"$LOGFILE"
				# Fall through to the next gate — do NOT return 1.
			else
				echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — coderabbit-nits-ok label present but human reviewer also blocking (t2179)" >>"$LOGFILE"
				return 1
			fi
		else
			# No coderabbit-nits-ok label — route worker-authored PRs for fix
			# dispatch and skip the merge (t2203: consolidated in helper).
			_route_pr_to_fix_worker "$pr_number" "$repo_slug" "$linked_issue" "review" "$_cr_pr_labels" || true
			echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — reviewDecision=CHANGES_REQUESTED" >>"$LOGFILE"
			return 1
		fi
	fi

	# Skip external contributor PRs (non-collaborator)
	if ! _is_collaborator_author "$pr_author" "$repo_slug"; then
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — author ${pr_author} is not a collaborator" >>"$LOGFILE"
		return 1
	fi

	# Skip PRs modifying workflow files when we lack the scope
	if check_pr_modifies_workflows "$pr_number" "$repo_slug" 2>/dev/null; then
		if ! check_gh_workflow_scope 2>/dev/null; then
			echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — modifies workflow files but token lacks workflow scope" >>"$LOGFILE"
			return 1
		fi
	fi

	# Maintainer-gate: skip if linked issue has needs-maintainer-review
	# UNLESS the issue also has the approval marker comment
	# (<!-- aidevops-signed-approval -->), which means the auto-approve
	# already ran and the NMR label is transient — the CI workflow
	# re-adds it within seconds of removal, creating a race with the
	# merge pass. The approval marker is the source of truth; NMR label
	# is the transient symptom of the CI workflow fighting the pulse.
	if [[ -n "$linked_issue" ]]; then
		local _li_api
		_li_api=$(_pm_issue_api "$repo_slug" "$linked_issue")
		local issue_labels
		issue_labels=$(gh api "${_li_api}" \
			--jq '[.labels[].name] | join(",")' 2>/dev/null) || issue_labels=""
		if [[ "$issue_labels" == *"needs-maintainer-review"* ]]; then
			# Check if approval marker exists — if so, NMR is transient
			local _has_approval_marker
			_has_approval_marker=$(gh api "${_li_api}/comments" \
				--jq '[.[].body | select(contains("aidevops-signed-approval"))] | length' \
				2>/dev/null) || _has_approval_marker=0
			if [[ "$_has_approval_marker" -gt 0 ]]; then
				echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} has NMR but also approval marker — proceeding (NMR is transient)" >>"$LOGFILE"
			else
				echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} has needs-maintainer-review (no approval marker)" >>"$LOGFILE"
				return 1
			fi
		fi
	fi

	# ── External contributor gate (t1958) ──
	# Requires linked issue + crypto approval (defence-in-depth after _is_collaborator_author).
	local pr_labels_for_ext
	pr_labels_for_ext=$(gh pr view "$pr_number" --repo "$repo_slug" --json labels \
		--jq '[.labels[].name] | join(",")' 2>/dev/null) || pr_labels_for_ext=""
	if [[ "$pr_labels_for_ext" == *"external-contributor"* ]]; then
		if ! _external_pr_has_linked_issue "$pr_number" "$repo_slug"; then
			echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — external-contributor PR has no linked issue (t1958)" >>"$LOGFILE"
			return 1
		fi
		if ! _external_pr_linked_issue_crypto_approved "$pr_number" "$repo_slug"; then
			local ext_linked_for_log
			ext_linked_for_log=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || ext_linked_for_log="unknown"
			echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — external-contributor PR linked issue #${ext_linked_for_log} lacks crypto approval (t1958)" >>"$LOGFILE"
			return 1
		fi
	fi

	# ── origin:interactive gates (t2411) ──
	# Draft and hold-for-review opt-out checks for interactive PRs. Applies
	# to all interactive PRs regardless of author role (OWNER, MEMBER, or
	# COLLABORATOR). COLLABORATORs that pass these checks still go through the
	# review bot gate and normal merge path without an ownership fast-path.
	local _oi_info_json _oi_labels_str _oi_is_draft
	_oi_info_json=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json labels,isDraft 2>/dev/null) || _oi_info_json=""
	_oi_labels_str=$(printf '%s' "$_oi_info_json" \
		| jq -r '[.labels[].name] | join(",")' 2>/dev/null) || _oi_labels_str=""
	_oi_is_draft=$(printf '%s' "$_oi_info_json" \
		| jq -r '.isDraft // false' 2>/dev/null) || _oi_is_draft="false"
	if [[ "$_oi_labels_str" == *"origin:interactive"* ]]; then
		if ! _check_interactive_pr_gates "$pr_number" "$repo_slug" "$_oi_labels_str" "$_oi_is_draft"; then
			return 1
		fi
	fi

	# ── origin:worker worker-briefed gates (t2449) ──
	# Symmetric to the origin:interactive auto-merge gate (t2411). When a
	# worker PR is backed by a maintainer-briefed issue (OWNER/MEMBER author),
	# the trust chain is equivalent to an interactive session. This gate
	# validates the additional criteria beyond the general gates.
	#
	# Uses comma-delimited matching: ",origin:worker," does NOT match
	# ",origin:worker-takeover," (substring-safe).
	if [[ ",${_oi_labels_str}," == *"${_OW_LABEL_PAT}"* ]]; then
		if ! _attempt_worker_briefed_auto_merge "$pr_number" "$repo_slug" "$_oi_labels_str" "$_oi_is_draft" "$linked_issue"; then
			return 1
		fi
	fi

	# ── Review bot gate (GH#17490) ──
	# --admin bypasses branch protection; enforce in code (see review-bot-gate-helper.sh).
	local rbg_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/review-bot-gate-helper.sh"
	if [[ -f "$rbg_helper" ]]; then
		local rbg_result="" rbg_status=""
		rbg_result=$(bash "$rbg_helper" check "$pr_number" "$repo_slug" 2>/dev/null) || rbg_result=""
		rbg_status=$(printf '%s' "$rbg_result" | grep -oE '^(PASS|SKIP|WAITING|PASS_RATE_LIMITED)' | head -1)
		case "$rbg_status" in
		PASS | SKIP | PASS_RATE_LIMITED)
			echo "[pulse-wrapper] Review bot gate: ${rbg_status} for PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
			;;
		*)
			echo "[pulse-wrapper] Review bot gate: ${rbg_status:-UNKNOWN} for PR #${pr_number} in ${repo_slug} — skipping merge" >>"$LOGFILE"
			return 1
			;;
		esac
	fi

	return 0
}

#######################################
# Perform all post-merge actions for a successfully merged PR:
# build and post closing comment, close linked issue, unlock.
# Best-effort — failures are logged but do not propagate.
# Args: $1=pr_number, $2=repo_slug, $3=linked_issue, $4=merge_summary
#######################################
_handle_post_merge_actions() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local merge_summary="$4"

	# Build closing comment — use worker summary if available, fall back to generic
	local closing_comment
	if [[ -n "$merge_summary" ]]; then
		closing_comment="${merge_summary}

---
Merged via PR #${pr_number} to main.
_Merged by deterministic merge pass (pulse-wrapper.sh)._"
	else
		closing_comment="Completed via PR #${pr_number}, merged to main.

_Merged by deterministic merge pass (pulse-wrapper.sh). Neither MERGE_SUMMARY comment nor PR body text was available._"
	fi

	# Append signature footer (GH#15486) — no-session, routine type.
	local _merge_sig_footer="" _merge_elapsed="" _merge_issue_ref=""
	_merge_elapsed=$(($(date +%s) - PULSE_START_EPOCH))
	[[ -n "$linked_issue" ]] && _merge_issue_ref="${repo_slug}#${linked_issue}"
	local _sig_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/gh-signature-helper.sh"
	_merge_sig_footer=$("$_sig_helper" footer \
		--body "$closing_comment" --no-session --tokens 0 \
		--time "$_merge_elapsed" --session-type routine \
		${_merge_issue_ref:+--issue "$_merge_issue_ref"} --solved 2>/dev/null || true)
	closing_comment="${closing_comment}${_merge_sig_footer}"

	# Post closing comment on PR; unlock the merged PR (t1934)
	gh_pr_comment "$pr_number" --repo "$repo_slug" \
		--body "$closing_comment" 2>/dev/null || true
	unlock_issue_after_worker "$pr_number" "$repo_slug"

	# Close linked issue with the same closing comment
	if [[ -n "$linked_issue" ]]; then
		# t2099 / GH#19032: parent-task close guard. Parent roadmap issues must
		# stay open until ALL phase children merge (t2046). The PR-body keyword
		# guard prevents workers from writing Closes/Resolves/Fixes against a
		# parent, and they instead use "For #NNN" / "Ref #NNN". BUT
		# `_extract_linked_issue` also falls back to matching `GH#NNN:` in
		# the PR title — which is the canonical PR title format for
		# parent-task phase PRs. Without this check, every phase PR would
		# silently close its parent on merge.
		#
		# Behaviour:
		#   - Still post the closing comment (it doubles as a phase-merged
		#     status update on the parent).
		#   - SKIP the `gh issue close` call.
		#   - SKIP fast_fail_reset and unlock (both tied to closing).
		local _parent_task_guard=0
		local _pm_li_api
		_pm_li_api=$(_pm_issue_api "$repo_slug" "$linked_issue")
		local _linked_labels
		_linked_labels=$(gh api "${_pm_li_api}" \
			--jq '[.labels[].name] | join(",")' 2>/dev/null) || _linked_labels=""
		if [[ ",${_linked_labels}," == *",parent-task,"* ]]; then
			_parent_task_guard=1
			echo "[pulse-wrapper] Deterministic merge: skipping close of parent-task issue #${linked_issue} (PR #${pr_number} is a phase child; parent stays open until all phases merge) — t2099/GH#19032" >>"$LOGFILE"
		fi

		# Dedup guard: skip if closing comment for this PR already exists (GH#18098).
		local _dedup_count
		_dedup_count=$(gh api "${_pm_li_api}/comments" \
			2>/dev/null | jq --arg prnum "PR #${pr_number}" \
			'[.[] | select(.body | contains($prnum))] | length' 2>/dev/null) || _dedup_count=0
		[[ "$_dedup_count" =~ ^[0-9]+$ ]] || _dedup_count=0
		if [[ "$_dedup_count" -gt 0 ]]; then
			echo "[pulse-wrapper] Deterministic merge: skipped duplicate closing comment on #${linked_issue} — PR #${pr_number} already referenced in existing comment (GH#18098)" >>"$LOGFILE"
		else
			gh_issue_comment "$linked_issue" --repo "$repo_slug" \
				--body "$closing_comment" 2>/dev/null || true
		fi

		if [[ "$_parent_task_guard" -eq 0 ]]; then
			gh issue close "$linked_issue" --repo "$repo_slug" 2>/dev/null || true
			# Reset fast-fail counter now that the issue is resolved (GH#2076)
			fast_fail_reset "$linked_issue" "$repo_slug" || true
			# t1934: Unlock the issue (locked at dispatch time)
			unlock_issue_after_worker "$linked_issue" "$repo_slug"
		fi
	fi

	# Auto-release interactive claim if one exists for this issue (t2413).
	# Handles the "when a PR they opened merges" release trigger from AGENTS.md
	# so the agent does not have to remember to call release after every merge.
	_release_interactive_claim_on_merge "$pr_number" "$repo_slug" "$linked_issue"

	# Sequential phase auto-filing (t2740 — Gap C): when a phase child PR
	# merges and its linked child issue is closed, inspect the parent-task
	# issue's ## Phases section and auto-file the next phase. Only fires
	# when AIDEVOPS_SEQUENTIAL_PHASE_AUTOFILE=1. Best-effort — failures
	# are logged but do not block the merge completion path.
	if [[ -n "$linked_issue" && "${_parent_task_guard:-0}" -eq 0 ]]; then
		auto_file_next_phase "$linked_issue" "$repo_slug" || true
	fi
	declare -F invalidate_footprint_cache_for_issue >/dev/null 2>&1 && invalidate_footprint_cache_for_issue "${linked_issue:-}" || true
	return 0
}

#######################################
# Process a single PR end-to-end: gate checks, merge attempt,
# conflict detection, and closing comment posting.
#
# Extracted from _merge_ready_prs_for_repo (t2002 / GH#18450, Phase 12).
# Decomposed into focused helpers (GH#18682): _resolve_pr_mergeable_status,
# _check_pr_merge_gates, _handle_post_merge_actions.
# Enables per-PR debugging and unit testing in isolation.
#
# Args:
#   $1 - repo slug
#   $2 - PR JSON object (single element from gh pr list --json output)
# Returns:
#   0 = merged successfully
#   1 = skipped (gate failure or non-mergeable)
#   2 = closed conflicting
#   3 = merge failed
#######################################
_process_single_ready_pr() {
	local repo_slug="$1"
	local pr_obj="$2"

	local pr_number pr_mergeable pr_review pr_author pr_title
	# Consolidate into a single jq pass to reduce process-spawn overhead.
	# CRITICAL: use non-whitespace delimiter (ASCII 0x1E record separator)
	# instead of \t. Bash read collapses consecutive IFS whitespace chars
	# (tab, space, newline) — if ANY field is empty the subsequent fields
	# shift left. reviewDecision is routinely "" (empty string, which jq //
	# does NOT catch — it only triggers on null/false). The field shift
	# caused pr_author to receive the PR title, breaking the collaborator
	# check and blocking ALL merges across every repo (observed downstream).
	local _RS=$'\x1e'
	IFS="$_RS" read -r pr_number pr_mergeable pr_review pr_author pr_title < <(
		printf '%s' "$pr_obj" | jq -r \
			'"\(.number // "")\u001e\(.mergeable // "")\u001e\(if (.reviewDecision | length) == 0 then "NONE" else .reviewDecision end)\u001e\(.author.login // "unknown")\u001e\(.title // "")"'
	)

	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 1

	# CONFLICTING handling (t2116): before closing, attempt to salvage the
	# PR via `gh pr update-branch` which fast-forwards the base branch into
	# the PR's branch when the conflict is purely due to base advancement
	# (common case: ratchet PRs on a file that other PRs also touched, docs
	# simplifications on adjacent sections). If update-branch succeeds, the
	# PR may now be MERGEABLE and we re-fetch its state so the normal merge
	# path can take over in the same cycle.
	#
	# This reorders the original flow: we now also check the maintainer gate
	# BEFORE closing, so PRs waiting on `needs-maintainer-review` are never
	# discarded as CONFLICTING during their wait (previous behaviour punished
	# maintainer review latency by throwing away worker work — see t2116
	# post-mortem for PR #18988, #19083).
	if [[ "$pr_mergeable" == "CONFLICTING" && "$PULSE_MERGE_CLOSE_CONFLICTING" == "true" ]]; then
		# Skip CONFLICTING-close entirely for PRs whose linked issue has
		# needs-maintainer-review — they are parked legitimately waiting for
		# a human and MUST NOT be auto-closed (t2116). Post the one-time
		# rebase nudge so the maintainer has a visible signal.
		local _t2116_linked_issue _t2116_issue_labels
		_t2116_linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug")
		if [[ -n "$_t2116_linked_issue" ]]; then
			_t2116_issue_labels=$(gh api "repos/${repo_slug}/issues/${_t2116_linked_issue}" \
				--jq '[.labels[].name] | join(",")' 2>/dev/null) || _t2116_issue_labels=""
			if [[ "$_t2116_issue_labels" == *"needs-maintainer-review"* ]]; then
				echo "[pulse-wrapper] Merge pass: skipping CONFLICTING-close of PR #${pr_number} in ${repo_slug} — linked issue #${_t2116_linked_issue} has needs-maintainer-review (t2116)" >>"$LOGFILE"
				_post_rebase_nudge_on_worker_conflicting "$pr_number" "$repo_slug" "" "" 2>/dev/null || true
				return 1
			fi
		fi

		# Attempt auto-rebase via gh pr update-branch. This is idempotent
		# and cheap: on success the branch is fast-forwarded and the next
		# mergeable re-fetch returns MERGEABLE; on failure (true semantic
		# conflict) we fall through to the close path.
		if _attempt_pr_update_branch "$pr_number" "$repo_slug"; then
			# Re-fetch mergeable state after update-branch; GitHub needs a
			# moment to recompute it. _resolve_pr_mergeable_status already
			# has a UNKNOWN-retry loop so we reuse it.
			local _refetched_mergeable
			_refetched_mergeable=$(gh pr view "$pr_number" --repo "$repo_slug" \
				--json mergeable --jq '.mergeable // "UNKNOWN"' 2>/dev/null) || _refetched_mergeable="UNKNOWN"
			pr_mergeable="$_refetched_mergeable"
			echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — update-branch succeeded, refetched mergeable=${pr_mergeable} (t2116)" >>"$LOGFILE"
			# If still CONFLICTING after a successful update-branch, the
			# conflict is semantic and unsalvageable. Fall through to close.
		fi

		if [[ "$pr_mergeable" == "CONFLICTING" ]]; then
			# Conflict resolution feedback: route worker PRs to fix worker
			# (t2203: consolidated in helper). If routed, return 2 to skip
			# the close path; otherwise fall through to _close_conflicting_pr.
			local _conf_linked_issue
			_conf_linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug")
			if _route_pr_to_fix_worker "$pr_number" "$repo_slug" "$_conf_linked_issue" "conflict" "" "$pr_title"; then
				return 2
			fi
			_close_conflicting_pr "$pr_number" "$repo_slug" "$pr_title"
			return 2
		fi
		# Otherwise pr_mergeable is now MERGEABLE/UNKNOWN — continue through
		# the normal merge path below.
	fi

	# Resolve UNKNOWN mergeable state with one retry; skip if not MERGEABLE
	if ! _resolve_pr_mergeable_status "$pr_number" "$repo_slug" "$pr_mergeable"; then
		return 1
	fi

	# CI failure fix-up: when required checks fail on a worker PR with a
	# linked issue, collect failing check details, append to issue body,
	# close the PR, and set the issue to status:available for re-dispatch.
	# The next worker sees the CI failure context and can fix it. t2189:
	# idle interactive PRs are handed over via origin:worker-takeover and
	# then routed through the same pipeline — human session must be gone
	# (no status, no claim stamp, >24h idle) for handover to fire.
	if ! _pr_required_checks_pass "$pr_number" "$repo_slug"; then
		# t2922: For origin:worker PRs, phantom-pending non-required checks
		# (CodeRabbit, qlty, linked-issue-check, url-allowlist, etc.) can
		# report null status indefinitely and cause _pr_required_checks_pass
		# to fail-closed via an API quirk. Cross-check with the branch
		# protection API (authoritative required-context list). If every
		# required-by-protection context is passing, bypass this block and
		# let the worker-briefed trust-chain gates run. Non-worker PRs
		# (external contributors, interactive sessions) take the normal
		# CI-failure routing path, preserving the contributor security gate.
		local _rcl_labels
		_rcl_labels=$(gh pr view "$pr_number" --repo "$repo_slug" \
			--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || _rcl_labels=""
		if [[ ",${_rcl_labels}," == *"${_OW_LABEL_PAT}"* ]] \
			&& _check_required_checks_passing "$repo_slug" "$pr_number"; then
			echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: _pr_required_checks_pass bypassed for origin:worker — branch-protection required contexts all pass (t2922)" >>"$LOGFILE"
			# Fall through to linked-issue fetch and merge gate checks
		else
			# t2805: try cheap rebase first if PR is behind base — pre-existing
			# failures in unrelated tests are often fixed by base advancement.
			# If rebase succeeds, skip fix-worker routing — next pulse cycle
			# will re-check CI on the rebased HEAD.
			if _attempt_pr_ci_rebase_retry "$pr_number" "$repo_slug"; then
				return 1
			fi
			# CI failure: route to fix worker if applicable (t2203: consolidated).
			local _ci_linked_issue
			_ci_linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug")
			_route_pr_to_fix_worker "$pr_number" "$repo_slug" "$_ci_linked_issue" "ci" || true
			return 1
		fi
	fi

	# Fetch linked issue once — used in gate checks and post-merge close
	local linked_issue
	linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug")

	# Run all skip-gate checks (review decision, collaborator, workflow scope,
	# maintainer gate, external-contributor gate, review bot gate)
	if ! _check_pr_merge_gates "$pr_number" "$repo_slug" "$pr_author" "$pr_review" "$linked_issue"; then
		return 1
	fi

	# Approve (satisfies REVIEW_REQUIRED for collaborator PRs)
	approve_collaborator_pr "$pr_number" "$repo_slug" "$pr_author" 2>/dev/null || true

	# Extract merge summary: MERGE_SUMMARY comment → PR body → generic fallback
	local merge_summary
	merge_summary=$(_extract_merge_summary "$pr_number" "$repo_slug")

	# Retarget any open PRs stacked on this branch before --delete-branch
	# kills their base. GitHub auto-closes children without warning when their
	# base branch disappears; retargeting to the default branch prevents this.
	# (t2412 / GH#20005)
	_retarget_stacked_children "$pr_number" "$repo_slug"

	# Defense-in-depth (t2934). Refuse `--admin` merge for external/fork PRs
	# without crypto approval, evaluated at the bypass call site so that any
	# future regression in upstream gate ordering, label-application timing,
	# or new code paths cannot re-open the threat addressed by PR #17868
	# (the 2026-04-07 incident: #17671, #17685, #3846 merged via Check 0
	# bypass). Returns 1 (skipped) — same semantics as a gate failure above.
	if ! _pulse_merge_admin_safety_check "$pr_number" "$repo_slug"; then
		return 1
	fi

	# Merge
	local merge_output _merge_exit
	merge_output=$(gh pr merge "$pr_number" --repo "$repo_slug" --squash --admin 2>&1)
	_merge_exit=$?

	# Rate-limit: 1 second between merges to avoid GitHub API abuse
	sleep 1

	if [[ $_merge_exit -eq 0 ]]; then
		echo "[pulse-wrapper] Deterministic merge: merged PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		# t2411: emit audit log for origin:interactive auto-merges
		local _ipr_labels
		_ipr_labels=$(gh pr view "$pr_number" --repo "$repo_slug" \
			--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || _ipr_labels=""
		if [[ "$_ipr_labels" == *"origin:interactive"* ]]; then
			local _ipr_role="collaborator"
			_is_owner_or_member_author "$pr_author" "$repo_slug" \
				&& _ipr_role="owner-or-member" || true
			echo "[pulse-merge] auto-merged origin:interactive PR #${pr_number} (author=${pr_author}, role=${_ipr_role})" >>"$LOGFILE"
		fi
		# t2449: emit audit log for origin:worker worker-briefed auto-merges
		if [[ ",${_ipr_labels}," == *"${_OW_LABEL_PAT}"* ]]; then
			echo "[pulse-merge] auto-merged origin:worker (worker-briefed) PR #${pr_number} (author=${pr_author}, linked_issue=#${linked_issue:-unknown})" >>"$LOGFILE"
		fi
		_handle_post_merge_actions "$pr_number" "$repo_slug" "$linked_issue" "$merge_summary"
		return 0
	else
		echo "[pulse-wrapper] Deterministic merge: FAILED PR #${pr_number} in ${repo_slug}: ${merge_output}" >>"$LOGFILE"
		return 3
	fi
}

#######################################
# Process a single PR by (slug, pr_number) tuple. Webhook entry point (t3038).
#
# Fetches the PR JSON for the given (slug, pr_number) and delegates to
# _process_single_ready_pr. Used by pulse-merge-webhook-receiver.sh to
# fire merge attempts immediately on GitHub webhook events
# (check_suite.completed, pull_request_review.submitted, pull_request.labeled)
# instead of waiting for the next pulse-merge-routine cycle.
#
# The 120s polling loop in pulse-merge-routine.sh remains as backstop —
# webhook-driven merges are an optimization, not a replacement.
#
# Args:
#   $1 - repo slug (owner/repo)
#   $2 - PR number
# Returns:
#   0 = merged successfully
#   1 = skipped (gate failure, non-mergeable, or PR not found)
#   2 = closed conflicting
#   3 = merge failed
#######################################
process_pr() {
	local repo_slug="$1"
	local pr_number="$2"

	if [[ -z "$repo_slug" || -z "$pr_number" ]]; then
		echo "[pulse-merge] process_pr: missing slug or PR number (slug='${repo_slug}', pr='${pr_number}')" >>"$LOGFILE"
		return 1
	fi
	if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
		echo "[pulse-merge] process_pr: invalid PR number '${pr_number}' for ${repo_slug}" >>"$LOGFILE"
		return 1
	fi

	# Fetch the PR JSON in the same shape _merge_ready_prs_for_repo uses
	# (number, mergeable, reviewDecision, author, title) and synthesize a
	# single-PR object. _process_single_ready_pr expects a compact JSON object.
	local pr_obj
	pr_obj=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json number,mergeable,reviewDecision,author,title 2>/dev/null) || pr_obj=""

	if [[ -z "$pr_obj" || "$pr_obj" == "null" ]]; then
		echo "[pulse-merge] process_pr: gh pr view failed for ${repo_slug}#${pr_number}" >>"$LOGFILE"
		return 1
	fi

	# Verify state is OPEN — closed/merged PRs should not be re-processed.
	local pr_state
	pr_state=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json state --jq '.state // ""' 2>/dev/null) || pr_state=""
	if [[ "$pr_state" != "OPEN" ]]; then
		echo "[pulse-merge] process_pr: PR ${repo_slug}#${pr_number} is not OPEN (state=${pr_state}) — skipping" >>"$LOGFILE"
		return 1
	fi

	echo "[pulse-merge] process_pr: webhook-triggered merge attempt for ${repo_slug}#${pr_number} (t3038)" >>"$LOGFILE"
	_process_single_ready_pr "$repo_slug" "$pr_obj"
	return $?
}

#######################################
# Extract linked issue number from PR title or body.
# Looks for: GitHub-native close keywords in PR body, "GH#NNN:" prefix in title.
#
# Close keyword matching (GH#18098): only GitHub-native keywords trigger auto-close —
# bare GH#NNN references in "Related" sections do NOT.  GitHub's full keyword list:
# close, closes, closed, fix, fixes, fixed, resolve, resolves, resolved (case-insensitive).
# GH#NNN matching is restricted to the PR title to avoid treating informational body
# references as closing keywords.
#
# Args: $1=PR number, $2=repo slug
# Returns: issue number on stdout, or empty if none found
#######################################
_extract_linked_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_title pr_body
	pr_title=$(gh pr view "$pr_number" --repo "$repo_slug" --json title --jq '.title // empty' 2>/dev/null) || pr_title=""
	pr_body=$(gh pr view "$pr_number" --repo "$repo_slug" --json body --jq '.body // empty' 2>/dev/null) || pr_body=""

	# Match GitHub-native close keywords in the PR body only (case-insensitive).
	# Matches: close/closes/closed, fix/fixes/fixed, resolve/resolves/resolved.
	# Does NOT match bare GH#NNN, "Related #NNN", "For #NNN", "Ref #NNN", or other
	# non-closing references. (GH#18098 + t2108)
	#
	# The body keyword is AUTHORITATIVE. The title fallback below only fires when
	# the body has a closing keyword AND the title also names a number — it picks
	# WHICH issue from the body matches when there are multiple. It is NEVER an
	# override that creates a match where the body intentionally has none. (t2108)
	local body_issue title_issue
	body_issue=$(printf '%s' "$pr_body" | grep -ioE '(close[ds]?|fix(es|ed)?|resolve[ds]?)\s+#[0-9]+' | head -1 | grep -oE '[0-9]+')
	title_issue=$(printf '%s' "$pr_title" | grep -oE 'GH#[0-9]+' | head -1 | grep -oE '[0-9]+')

	# No closing keyword in the body → return empty. The PR is intentionally
	# not closing any issue (planning-only PR, multi-PR roadmap, "For #NNN"
	# reference, etc.). _handle_post_merge_actions will skip the close path
	# when this returns empty. (t2108)
	if [[ -z "$body_issue" ]]; then
		return 0
	fi

	# Body has a closing keyword. If the title also names a number, prefer the
	# title-named issue when it differs from body_issue (matches the historical
	# behaviour where the GH#NNN: title prefix is the primary identifier and
	# the body may reference additional issues). When they match or the title
	# has no number, return body_issue. (t2108)
	if [[ -n "$title_issue" ]]; then
		printf '%s' "$title_issue"
		return 0
	fi
	printf '%s' "$body_issue"
	return 0
}

#######################################
# Extract the worker's merge summary from PR comments.
#
# Workers post a structured comment tagged with <!-- MERGE_SUMMARY -->
# on the PR at creation time (full-loop.md step 4.2.1). This function
# finds the most recent such comment and returns its body (without the
# HTML tag) for use in closing comments.
#
# Args: $1=PR number, $2=repo slug
# Output: merge summary text on stdout (empty if none found)
#######################################
_extract_merge_summary() {
	local pr_number="$1"
	local repo_slug="$2"

	# Strategy 1: Look for explicit MERGE_SUMMARY tagged comment (richest content)
	local summary
	summary=$(gh api "repos/${repo_slug}/issues/${pr_number}/comments" \
		--jq '[.[] | select(.body | test("<!-- MERGE_SUMMARY -->"))] | last | .body // empty' \
		2>/dev/null) || summary=""

	if [[ -n "$summary" ]]; then
		# Strip the HTML marker tag
		summary=$(printf '%s' "$summary" | sed 's/<!-- MERGE_SUMMARY -->//')
		# Strip the worker's "written at PR creation time" note if present
		summary=$(printf '%s' "$summary" | sed '/written by the worker at PR creation time/d')
		printf '%s' "$summary"
		return 0
	fi

	# Strategy 2: Extract from PR body (always present, created atomically with PR).
	# Workers skip the MERGE_SUMMARY comment ~65% of the time, but the PR body
	# always contains a useful description of what was done (GH#17503).
	local pr_body
	pr_body=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json body --jq '.body // empty' 2>/dev/null) || pr_body=""

	if [[ -z "$pr_body" ]]; then
		return 0
	fi

	# Strip auto-generated bot content (CodeRabbit, SonarCloud, Codacy, etc.)
	# These start with <!-- This is an auto-generated comment or similar markers
	pr_body=$(printf '%s\n' "$pr_body" | sed '/<!-- This is an auto-generated comment/,$d')

	# Strip Closes/Fixes/Resolves #NNN (the closing comment adds its own PR reference)
	pr_body=$(printf '%s\n' "$pr_body" | sed -E 's/(Closes|Fixes|Resolves) #[0-9]+[[:space:]]*//')

	# Trim leading/trailing blank lines (BSD sed compatible)
	pr_body=$(printf '%s\n' "$pr_body" | sed '/./,$!d' | sed -E '/^[[:space:]]*$/{ N; }' | sed -E '/^[[:space:]]*$/d')

	# Only use if there's meaningful content left (more than just whitespace)
	if [[ -n "$pr_body" ]] && [[ "$(printf '%s' "$pr_body" | tr -d '[:space:]')" != "" ]]; then
		printf '%s' "$pr_body"
	fi

	return 0
}
