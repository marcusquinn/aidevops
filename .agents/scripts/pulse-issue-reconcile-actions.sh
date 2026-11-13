#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-issue-reconcile-actions.sh — Per-issue action helpers and predicates
# =============================================================================
# Extracted from pulse-issue-reconcile.sh (GH#21376) to keep the orchestrator
# file below the 2000-line file-size-debt gate. Mirrors the split precedent
# from pulse-issue-reconcile-stale.sh (t2375).
#
# Sourced by pulse-issue-reconcile.sh. Do NOT invoke directly — it relies on
# the orchestrator (pulse-wrapper.sh) having sourced shared-constants.sh and
# worker-lifecycle-common.sh and defined all PULSE_* configuration constants.
#
# Usage: source "${SCRIPT_DIR}/pulse-issue-reconcile-actions.sh"
#
# Exports — parent-task child detection helpers:
#   _fetch_subissue_numbers       — fetch child issue numbers via GraphQL
#   _extract_children_section     — extract ## Children / ## Sub-tasks section
#   _extract_children_from_prose  — extract children from narrow prose patterns
#   _fetch_children_from_trusted_roadmap_comments — extract trusted roadmap refs
#   _compute_parent_nudge_age_hours — compute age of decomposition nudge comment
#   _post_parent_phases_unfiled_nudge — nudge when declared phases > filed children
#   _try_close_parent_tracker     — close parent if all children are resolved
#
# Exports — single-pass stage predicates:
#   _should_reconcile_persistent_issue — stage 0a non-task predicate
#   _should_reconcile_external_issue_gate — stage 0 trust predicate
#   _should_reconcile_stranded_consolidated — stage 0c predicate
#   _should_ciw   — stage 1 predicate (status:available)
#   _should_rsd   — stage 2 predicate (status:done)
#   _should_oimp  — stage 3 predicate (not a parent-task)
#   _should_cpt   — stage 4 predicate (parent-task)
#   _should_lia   — stage 5 predicate (labelless aidevops-shaped)
#
# Exports — single-pass per-issue action helpers:
#   _action_reconcile_persistent_issue_labels — stage 0a label hygiene
#   _action_reconcile_external_issue_gate — stage 0 trust repair/block
#   _action_reconcile_stranded_consolidated — stage 0c consolidated hygiene
#   _action_ciw_single   — close issue with merged PR (stage 1)
#   _action_rsd_single   — reconcile stale-done issue (stage 2)
#   _action_oimp_single  — close open issue with merged PR (stage 3)
#   _action_cpt_single   — reconcile parent-task (stage 4)
#
# Note: _action_lia_single (stage 5) is over 100 lines and stays in
# pulse-issue-reconcile.sh to preserve its (file, fname) identity key.
# _post_parent_decomposition_nudge and _post_parent_decomposition_escalation
# are also over 100 lines and stay in the orchestrator.

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_ISSUE_RECONCILE_ACTIONS_LOADED:-}" ]] && return 0
_PULSE_ISSUE_RECONCILE_ACTIONS_LOADED=1


# SCRIPT_DIR fallback for direct/test sourcing
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_pira_path="${BASH_SOURCE[0]%/*}"
	[[ "$_pira_path" == "${BASH_SOURCE[0]}" ]] && _pira_path="."
	SCRIPT_DIR="$(cd "$_pira_path" && pwd)"
	unset _pira_path
fi

# shellcheck source=./pulse-issue-reconcile-actions-parent.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-issue-reconcile-actions-parent.sh"
# shellcheck source=./pulse-issue-reconcile-actions-repair.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-issue-reconcile-actions-repair.sh"
# shellcheck source=./dependency-supersession-lib.sh
# shellcheck disable=SC1091  # trusted "Superseded by #N" parser (GH#37600)
source "${SCRIPT_DIR}/dependency-supersession-lib.sh"


#######################################
# t2138 / t3544: extract per-parent close logic. Keeps
# reconcile_completed_parent_tasks under the 100-line shell-complexity
# threshold and makes the close decision independently testable.
#
# Returns 0 if the parent was closed, 1 if skipped (no known children,
# any child still open, incomplete close contract, or close call failed).
_try_close_parent_tracker() {
	local slug="$1" parent_num="$2" child_nums="$3" child_source="$4" parent_body="${5:-}"
	local child_summary="" child_count=0 live_parent_body=""
	local live_child_nums="" live_child_source=""
	local live_parent_revision=""

	if ! _pir_budget_allows_mutation; then
		echo "[pulse-wrapper] Reconcile parent-task: deferred: insufficient reconcile budget for parent close #${parent_num} in ${slug}" >>"${LOGFILE:-/dev/null}"
		return 1
	fi
	_pir_verify_parent_children_closed "$slug" "$child_nums" || return 1
	child_count="$_PIR_CPT_VERIFIED_CHILD_COUNT"
	child_summary="$_PIR_CPT_VERIFIED_CHILD_SUMMARY"

	# t3544: dropped the `child_count >= 2` heuristic that previously
	# short-circuited single-filed-child parents. Pre-union-extraction
	# (before GH#20872), a single ref was often a spurious mention rather
	# than a true child. The current union extractor (graph + body + prose)
	# only counts numeric IDs that survived `## Children` / `## Sub-tasks` /
	# sub-issue-graph filtering, so a single survivor is a legitimate child.
	# Filtering it out here meant single-child parents could never close
	# OR receive the declared-vs-filed nudge — they silently rotted (canonical:
	# #22371 / #22372 with one filed Phase 1 child closed for hours with
	# no action). The remaining gates (all_closed, child_count>0,
	# declared-vs-filed augmentation, gh issue close result) are sufficient.
	#
	# child_count > 0 is required: pre-t3544 the heuristic implicitly
	# guarded this, but with the heuristic gone, a parent whose only
	# refs are non-issue (PRs, external) would skip the per-child
	# accounting loop entirely (`continue` on `state == unknown`),
	# leave child_count=0, all_closed defaulting to "true" (no
	# child set it false), and produce the absurd close-comment
	# "All 0 filed child task(s) are resolved." Require at least
	# one real child issue (Gemini review of PR #22605, t3544).
	# The caller collected child evidence for this parent immediately before
	# this call, and every known child was verified terminal just above.
	if _parent_close_contract_incomplete "$parent_body" "$child_count" "$child_source" \
		"$_PIR_CPT_DECLARED_NUMS" "$_PIR_CPT_GRAPH_NUMS" 1; then
		_hold_parent_for_incomplete_close_contract "$slug" "$parent_num" "$child_count" cached
		return 1
	fi

	# Child reads and close-contract checks can span several API round-trips.
	# Re-read the parent at the final mutation boundary so an NMR/persistent hold
	# added during that interval cannot race the earlier caller-side gate.
	_pir_parent_mutation_is_allowed "$slug" "$parent_num" open "$_PIR_PARENT_MUTATION_CLOSE" || return 1
	if ! live_parent_body=$(_pir_parent_body_from_json "$_PIR_LIVE_PARENT_JSON"); then
		_PARENT_CLOSE_CONTRACT_REASON="$_PARENT_CLOSE_CONTRACT_LIVE_BODY_UNAVAILABLE"
		_PARENT_CLOSE_CONTRACT_DECLARED=0
		_PARENT_CLOSE_CONTRACT_UNFILED=""
		_hold_parent_for_incomplete_close_contract "$slug" "$parent_num" "$child_count" live
		return 1
	fi
	live_parent_revision=$(_pir_parent_revision_from_json "$_PIR_LIVE_PARENT_JSON") || return 1

	# Recollect the graph/body/comment union from the live parent, then re-read
	# every child. A child linked or reopened after the cached pass blocks close.
	_pir_collect_parent_child_evidence "$slug" "$parent_num" "$live_parent_body" || return 1
	child_nums="$_PIR_CPT_CHILD_NUMS"
	child_source="$_PIR_CPT_CHILD_SOURCE"
	live_child_nums="$child_nums"
	live_child_source="$child_source"
	_pir_verify_parent_children_closed "$slug" "$child_nums" || return 1
	child_count="$_PIR_CPT_VERIFIED_CHILD_COUNT"
	child_summary="$_PIR_CPT_VERIFIED_CHILD_SUMMARY"
	if _parent_close_contract_incomplete "$live_parent_body" "$child_count" "$child_source" \
		"$_PIR_CPT_DECLARED_NUMS" "$_PIR_CPT_GRAPH_NUMS" 1; then
		_hold_parent_for_incomplete_close_contract "$slug" "$parent_num" "$child_count" live
		return 1
	fi

	# Graph relations and trusted roadmap comments can change independently of
	# the body. Require a stable second snapshot and a final live parent fence.
	_pir_parent_close_snapshot_is_stable "$slug" "$parent_num" "$live_parent_body" \
		"$live_child_nums" "$live_child_source" "$live_parent_revision" || return 1
	child_nums="$_PIR_CPT_CHILD_NUMS"
	child_source="$_PIR_CPT_CHILD_SOURCE"
	child_count="$_PIR_CPT_VERIFIED_CHILD_COUNT"
	child_summary="$_PIR_CPT_VERIFIED_CHILD_SUMMARY"
	if ! _pir_parent_close_evidence_is_trusted "$child_source"; then
		echo "[pulse-wrapper] Reconcile parent-task: kept #${parent_num} open in ${slug} — stale-approved external parent lacks sub-issue graph children (source=${child_source})" >>"${LOGFILE:-/dev/null}"
		return 1
	fi
	local close_basis="$_PIR_PARENT_TRUST_BASIS"
	_pir_close_parent_with_postcondition "$slug" "$parent_num" "$live_parent_body" \
		"$child_nums" "$child_source" || return 1
	gh_issue_comment "$parent_num" --repo "$slug" \
		--body "## All declared child tasks completed — closing parent tracker

${child_summary}

All ${child_count} declared child issue(s) are resolved and the parent close contract is complete. Parent tracker closed automatically.

_Detected by reconcile_completed_parent_tasks (pulse-issue-reconcile.sh)._" \
		>/dev/null 2>&1 || true

	echo "[pulse-wrapper] Reconcile parent-task: closed #${parent_num} in ${slug} — all ${child_count} children closed (source=${child_source}, trust=${close_basis})" >>"$LOGFILE"
	return 0
}

#######################################
# A stale-approved external parent may close only when its child set includes
# the sub-issue graph, which only write-authorized users can change. Untrusted
# body/prose references can add children that must also be closed, but can
# never be the sole evidence. Trusted parents are unaffected.
# Args: $1=child evidence source (e.g. graph+body)
# Returns: 0=evidence acceptable for the current trust basis, 1=insufficient
#######################################
_pir_parent_close_evidence_is_trusted() {
	local child_source="$1"
	[[ "$_PIR_PARENT_TRUST_BASIS" == "$_PIR_PARENT_TRUST_STALE_APPROVED_CLOSE" ]] || return 0
	case "+${child_source}+" in
	*+graph+*) return 0 ;;
	esac
	return 1
}

# Exact comma-delimited label membership without substring matches.
# Args: $1=labels CSV, $2=label
_pir_labels_csv_contains() {
	local labels_csv="$1"
	local label="$2"
	case ",${labels_csv}," in
	*,"$label",*) return 0 ;;
	esac
	return 1
}

# Stage 0a predicate: persistent issues are monitoring/tracking surfaces, not
# implementation tasks. They must bypass task lifecycle reconciliation.
# Args: $1=labels CSV
_should_reconcile_persistent_issue() {
	local labels_csv="$1"
	_pir_labels_csv_contains "$labels_csv" "$_PIR_PERSISTENT_LABEL" && return 0
	return 1
}

#######################################
# Remove stale triage-failure residue from a persistent non-task issue. An NMR
# label is deliberately preserved: persistent blocks dispatch, but it must not
# become a bypass for the cryptographically protected NMR removal boundary.
#
# Args: $1=slug, $2=issue number, $3=labels CSV
# Returns: 0=labels repaired, 1=no repair needed or write failed
#######################################
_action_reconcile_persistent_issue_labels() {
	local slug="$1"
	local issue_num="$2"
	local labels_csv="$3"
	local -a edit_args=()

	if _pir_labels_csv_contains "$labels_csv" "$_PIR_TRIAGE_FAILED_LABEL"; then
		edit_args+=("$_PIR_REMOVE_LABEL_FLAG" "$_PIR_TRIAGE_FAILED_LABEL")
	fi
	[[ "${#edit_args[@]}" -gt 0 ]] || return 1

	#aidevops:trust-boundary -- persistent blocks dispatch but never authorizes NMR removal.
	local edit_rc=0
	if declare -F gh_issue_edit_safe >/dev/null 2>&1; then
		gh_issue_edit_safe "$issue_num" --repo "$slug" "${edit_args[@]}" >/dev/null 2>&1 || edit_rc=$?
	else
		gh issue edit "$issue_num" --repo "$slug" "${edit_args[@]}" >/dev/null 2>&1 || edit_rc=$?
	fi
	if [[ "$edit_rc" -ne 0 ]]; then
		echo "[pulse-wrapper] Persistent issue reconcile: label repair failed for #${issue_num} in ${slug}" >>"$LOGFILE"
		return 1
	fi
	echo "[pulse-wrapper] Persistent issue reconcile: removed stale triage labels from #${issue_num} in ${slug}" >>"$LOGFILE"
	return 0
}

# Stage 0b predicate: cached metadata identifies a non-maintainer issue author,
# or metadata is unavailable and later lifecycle stages must remain blocked.
# Unknown rows are not relabeled because that could misclassify legacy trusted
# issues; live worker entry gates independently remain fail-closed.
# Args: $1=author association, $2=author type, $3=author is_bot boolean
_should_reconcile_external_issue_gate() {
	local author_association="$1"
	local author_type="$2"
	local author_is_bot="$3"
	if [[ "$author_type" == "Bot" || "$author_is_bot" == "true" ]]; then
		return 1
	fi
	case "$author_association" in
	OWNER | MEMBER) return 1 ;;
	esac
	return 0
}

#######################################
# Recover missing legacy-cache author metadata with one bounded REST lookup.
# The caller keeps the issue fail-closed when the lookup cannot establish an
# association. Output is returned via _PIR_EXTERNAL_FALLBACK_* globals.
#
# Args: $1=slug, $2=issue number
# Returns: 0=author metadata recovered, 1=unavailable or fallback budget spent
#######################################
_pir_recover_external_issue_author_metadata() {
	local slug="$1"
	local issue_num="$2"
	local fallback_max="${PULSE_EXTERNAL_TRUST_FALLBACK_MAX:-25}"
	local fallback_used="${_PIR_EXTERNAL_TRUST_FALLBACKS_USED:-0}"
	local live_issue_json="" live_author_row=""

	_PIR_EXTERNAL_FALLBACK_REASON=""
	_PIR_EXTERNAL_FALLBACK_ASSOCIATION=""
	_PIR_EXTERNAL_FALLBACK_LOGIN=""
	_PIR_EXTERNAL_FALLBACK_TYPE=""
	_PIR_EXTERNAL_FALLBACK_IS_BOT="false"
	[[ "$slug" == */* && "$issue_num" =~ ^[1-9][0-9]*$ ]] || {
		_PIR_EXTERNAL_FALLBACK_REASON="invalid issue identity"
		return 1
	}
	[[ "$fallback_max" =~ ^[0-9]+$ ]] || fallback_max=25
	[[ "$fallback_used" =~ ^[0-9]+$ ]] || fallback_used=0
	if [[ "$fallback_used" -ge "$fallback_max" ]]; then
		_PIR_EXTERNAL_FALLBACK_REASON="budget exhausted (${fallback_used}/${fallback_max})"
		return 1
	fi

	_PIR_EXTERNAL_TRUST_FALLBACKS_USED=$((fallback_used + 1))
	live_issue_json=$(gh api "repos/${slug}/issues/${issue_num}" 2>/dev/null) || {
		_PIR_EXTERNAL_FALLBACK_REASON="request failed"
		return 1
	}
	live_author_row=$(printf '%s' "$live_issue_json" | jq -r '[
		(.author_association // .authorAssociation // ""),
		(.user.login // .author.login // ""),
		(.user.type // .author.type // ""),
		(if ((.user.type // .author.type // "") == "Bot") then "true" else "false" end)
	] | join("|")' 2>/dev/null) || {
		_PIR_EXTERNAL_FALLBACK_REASON="response parse failed"
		return 1
	}
	IFS='|' read -r _PIR_EXTERNAL_FALLBACK_ASSOCIATION _PIR_EXTERNAL_FALLBACK_LOGIN \
		_PIR_EXTERNAL_FALLBACK_TYPE _PIR_EXTERNAL_FALLBACK_IS_BOT <<<"$live_author_row"
	if [[ -z "$_PIR_EXTERNAL_FALLBACK_ASSOCIATION" ]]; then
		_PIR_EXTERNAL_FALLBACK_REASON="response lacked author association"
		return 1
	fi
	return 0
}

#######################################
# Write at most one cache/fallback diagnostic per repository per reconcile
# process. Repeated legacy rows are expected together and must not flood pulse.
#
# Args: $1=slug, $2=source reason
#######################################
_pir_log_external_issue_author_metadata_miss() {
	local slug="$1"
	local reason="$2"
	local logged_slugs="${_PIR_EXTERNAL_TRUST_FALLBACK_DIAGNOSTIC_SLUGS:-}"
	if [[ ",${logged_slugs}," == *",${slug},"* ]]; then
		return 0
	fi
	_PIR_EXTERNAL_TRUST_FALLBACK_DIAGNOSTIC_SLUGS="${logged_slugs:+${logged_slugs},}${slug}"
	echo "[pulse-wrapper] External issue trust reconcile: ${slug} cache author metadata missing; bounded live fallback ${reason}; failing closed (further misses this cycle suppressed)" >>"$LOGFILE"
	return 0
}

#######################################
# Stage 0 helper (GH#36905): an issue that already carries NMR (for example
# from an issue form template) but lacks external-contributor would otherwise
# never get the provenance label, because stage 0b returns before the authority
# check and blocks stage 5. Apply it when the authority check returns 1, the
# same rule stage 5 uses. Unknown association or lookup failure changes nothing.
#
# Args: $1=slug, $2=issue number, $3=labels CSV, $4=association, $5=login
# Returns: 0 always (stage 0b still blocks the remaining stages)
#######################################
_pir_backfill_external_contributor_label() {
	local slug="$1"
	local issue_num="$2"
	local labels_csv="$3"
	local author_association="$4"
	local author_login="$5"

	local ext_label="$_PIR_EXTERNAL_CONTRIBUTOR_LABEL"
	if _pir_labels_csv_contains "$labels_csv" "$ext_label"; then
		return 0
	fi
	[[ -n "$author_association" && -n "$author_login" ]] || return 0
	declare -F _gh_actor_has_repo_write_authority >/dev/null 2>&1 || return 0
	local authority_rc=0
	_gh_actor_has_repo_write_authority "$slug" "$author_login" "$author_association" || authority_rc=$?
	[[ "$authority_rc" -eq 1 ]] || return 0

	local edit_rc=0
	# shellcheck source=protected-label-guard.sh
	source "$(dirname "${BASH_SOURCE[0]}")/protected-label-guard.sh"
	protected_label_edit "$issue_num" "$slug" \
		"provenance; association=${author_association}; authority=${AIDEVOPS_GH_ACTOR_AUTHORITY_REASON:-unknown}" \
		"$_PIR_ADD_LABEL_FLAG" "$ext_label" >/dev/null || edit_rc=$?
	if [[ "$edit_rc" -eq 0 ]]; then
		_PIR_EXTERNAL_GATE_MUTATED=1
		echo "[pulse-wrapper] External issue trust reconcile: applied ${ext_label} to #${issue_num} in ${slug}" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] External issue trust reconcile: ${ext_label} backfill failed for #${issue_num} in ${slug}" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Stage 0 action: repair a missing NMR gate from cached author metadata and
# prevent later reconciliation stages from acting on unapproved external input.
# Verified approvals and write-authorized collaborators continue normally.
#
# Args: $1=slug, $2=issue number, $3=labels CSV, $4=association, $5=login
# Returns: 0=block remaining stages, 1=trusted/approved and may continue
#######################################
_action_reconcile_external_issue_gate() {
	local slug="$1"
	local issue_num="$2"
	local labels_csv="$3"
	local author_association="$4"
	local author_login="$5"
	_PIR_EXTERNAL_GATE_MUTATED=0
	_PIR_EXTERNAL_GATE_VERIFICATION=""

	if _pir_labels_csv_contains "$labels_csv" "$_PIR_NMR_LABEL"; then
		_pir_backfill_external_contributor_label "$slug" "$issue_num" "$labels_csv" \
			"$author_association" "$author_login"
		return 0
	fi
	if [[ -z "$author_association" ]]; then
		if _pir_recover_external_issue_author_metadata "$slug" "$issue_num"; then
			author_association="$_PIR_EXTERNAL_FALLBACK_ASSOCIATION"
			author_login="$_PIR_EXTERNAL_FALLBACK_LOGIN"
			if ! _should_reconcile_external_issue_gate "$author_association" \
				"$_PIR_EXTERNAL_FALLBACK_TYPE" "$_PIR_EXTERNAL_FALLBACK_IS_BOT"; then
				return 1
			fi
		else
			# Count blocked rows, not just the aggregated per-repository warning.
			# #aidevops:trust-boundary — missing metadata still fails closed.
			_PIR_MISSING_AUTHOR_METADATA_BLOCKED=$((${_PIR_MISSING_AUTHOR_METADATA_BLOCKED:-0} + 1))
			_pir_log_external_issue_author_metadata_miss "$slug" "${_PIR_EXTERNAL_FALLBACK_REASON:-unavailable}"
			return 0
		fi
	fi

	local authority_rc=0
	if declare -F _gh_actor_has_repo_write_authority >/dev/null 2>&1; then
		_gh_actor_has_repo_write_authority "$slug" "$author_login" "$author_association" || authority_rc=$?
	else
		authority_rc=2
	fi
	if [[ "$authority_rc" -eq 0 ]]; then
		return 1
	fi
	if [[ "$authority_rc" -ne 1 ]]; then
		echo "[pulse-wrapper] External issue trust reconcile: blocked #${issue_num} in ${slug}; author authority lookup unavailable, labels unchanged" >>"$LOGFILE"
		return 0
	fi

	local approval_helper="${_PIR_SCRIPT_DIR}/approval-helper.sh"
	local verification=""
	if [[ ! -x "$approval_helper" ]]; then
		echo "[pulse-wrapper] External issue trust reconcile: blocked #${issue_num} in ${slug}; approval helper unavailable, labels unchanged" >>"$LOGFILE"
		return 0
	fi
	verification=$("$approval_helper" verify "$issue_num" "$slug" 2>/dev/null) || true
	_PIR_EXTERNAL_GATE_VERIFICATION="$verification"
	if [[ "$verification" == "VERIFIED" ]]; then
		return 1
	fi
	# An empty/error response is not evidence that approval is absent.
	if [[ "$verification" != "NO_APPROVAL" ]]; then
		echo "[pulse-wrapper] External issue trust reconcile: blocked #${issue_num} in ${slug}; approval verification=${verification}, labels unchanged" >>"$LOGFILE"
		return 0
	fi

	local -a edit_args=("$_PIR_ADD_LABEL_FLAG" "$_PIR_NMR_LABEL")
	if ! _pir_labels_csv_contains "$labels_csv" "$_PIR_EXTERNAL_CONTRIBUTOR_LABEL"; then
		edit_args+=("$_PIR_ADD_LABEL_FLAG" "$_PIR_EXTERNAL_CONTRIBUTOR_LABEL")
	fi
	if _pir_labels_csv_contains "$labels_csv" "$_PIR_AUTO_DISPATCH_LABEL"; then
		edit_args+=("$_PIR_REMOVE_LABEL_FLAG" "$_PIR_AUTO_DISPATCH_LABEL")
	fi
	if _pir_labels_csv_contains "$labels_csv" "$_PIR_STATUS_AVAILABLE"; then
		edit_args+=("$_PIR_REMOVE_LABEL_FLAG" "$_PIR_STATUS_AVAILABLE")
	fi

	#aidevops:trust-boundary -- cached metadata repairs labels; live gates remain authoritative.
	local edit_rc=0
	# shellcheck source=protected-label-guard.sh
	source "$(dirname "${BASH_SOURCE[0]}")/protected-label-guard.sh"
	protected_label_edit "$issue_num" "$slug" \
		"containment; association=${author_association}; authority=${AIDEVOPS_GH_ACTOR_AUTHORITY_REASON:-unknown}" \
		"${edit_args[@]}" >/dev/null || edit_rc=$?
	if [[ "$edit_rc" -eq 0 ]]; then
		_PIR_EXTERNAL_GATE_MUTATED=1
		echo "[pulse-wrapper] External issue trust reconcile: applied ${_PIR_NMR_LABEL} to #${issue_num} in ${slug}" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] External issue trust reconcile: label repair failed for #${issue_num} in ${slug}; remaining stages blocked" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Stage 0 routing predicate (GH#34281): after the external gate blocked an
# issue, decide whether it may still enter stage 4 (parent reconcile) — never
# stages 1-3. Only an unmutated parent-task whose approval verified STALE
# qualifies; stage 4 re-reads live state per mutation and admits only the
# terminal close (graph-backed) and its compensating reopen.
# Without this route the stale-approved close basis is unreachable in the
# single-pass loop because stage 0 consumes the issue first.
# Args: $1=labels CSV (cached)
# Returns: 0=route to stage 4, 1=stay blocked
#######################################
_pir_stale_approved_parent_may_reconcile() {
	local labels_csv="$1"
	#aidevops:trust-boundary -- STALE (signature valid) only; NO_APPROVAL/INVALID stay blocked.
	[[ "${_PIR_EXTERNAL_GATE_MUTATED:-0}" -eq 0 ]] || return 1
	[[ "${_PIR_EXTERNAL_GATE_VERIFICATION:-}" == "$_PIR_APPROVAL_STALE" ]] || return 1
	_should_cpt "$labels_csv" || return 1
	return 0
}

# Stage 1 predicate: issue has status:available (candidate for close-via-merged-PR).
# Args: $1 = labels_csv (comma-separated label names from pre-fetched JSON)
# Note: unquoted case patterns avoid adding to the string-literal ratchet count.
_should_ciw() {
	local labels_csv="$1"
	case "$labels_csv" in
	*status:available*) return 0 ;;
	esac
	return 1
}

# Stage 2 predicate: issue has status:done (candidate for stale-done reconcile).
# Args: $1 = labels_csv
_should_rsd() {
	local labels_csv="$1"
	case "$labels_csv" in
	*status:done*) return 0 ;;
	esac
	return 1
}

# Stage 3 predicate: issue is NOT a parent-task (candidate for open-with-merged-PR check).
# Issues handled by stages 1+2 via short-circuit never reach this predicate.
# Args:
#   $1 = issue_num
#   $2 = parent_task_nums (newline-delimited list of parent-task issue numbers)
_should_oimp() {
	local issue_num="$1"
	local parent_task_nums="$2"
	if [[ -n "$parent_task_nums" ]] && printf '%s\n' "$parent_task_nums" | grep -x "$issue_num" >/dev/null; then
		return 1
	fi
	return 0
}

# Stage 4 predicate: issue carries the parent-task label without an automation
# hold. NMR and persistent labels are maintainer-owned barriers, not lifecycle
# states that parent automation may clear or work around.
# Args: $1 = labels_csv
_should_cpt() {
	local labels_csv="$1"
	local nmr_label="${_PIR_NMR_LABEL:-needs-maintainer-review}"
	local parent_label="${_PIR_PT_LABEL:-parent-task}"
	local persistent_label="${_PIR_PERSISTENT_LABEL:-persistent}"
	case ",${labels_csv}," in
	*,"${nmr_label}",* | *,"${persistent_label}",*) return 1 ;;
	*,"${parent_label}",*) return 0 ;;
	esac
	return 1
}

# Stage 5 predicate: issue is an aidevops-shaped labelless candidate.
# A task-shaped title or an aidevops origin marker qualifies, provided no
# origin:/tier:/status: label has already established provenance/lifecycle.
# Args: $1 = issue_title, $2 = labels_csv, $3 = issue_body
_should_lia() {
	local issue_title="$1"
	local labels_csv="$2"
	local issue_body="${3:-}"
	if ! printf '%s' "$issue_title" | grep -E '^(t[0-9]+(\.[0-9]+)*|GH#[0-9]+): ' >/dev/null &&
		! printf '%s\n' "$issue_body" | grep -E '^<!-- aidevops:origin:(interactive|worker) -->$' >/dev/null; then
		return 1
	fi
	# Must have no origin:/tier:/status: labels (unquoted patterns avoid ratchet)
	case "$labels_csv" in
	*origin:* | *tier:* | *status:*) return 1 ;;
	esac
	return 0
}

#######################################
# Extract issue numbers from canonical consolidated-spec markers.
#
# Kept narrow on purpose: arbitrary prose and inlined consolidation
# instructions are not terminal evidence.
#
# Args: $1 = issue body
# Stdout: newline-delimited issue numbers, deduplicated
#######################################
_pir_extract_superseded_issue_nums() {
	local issue_body="$1"
	local line="" ref=""
	local marker_regex='^_Supersedes #([0-9]+) (—|-) this issue is the consolidated spec\._$'
	[[ -n "$issue_body" ]] || return 0

	while IFS= read -r line; do
		line="${line%$'\r'}"
		if [[ "$line" =~ $marker_regex ]]; then
			ref="${BASH_REMATCH[1]:-}"
			printf '%s\n' "$ref"
		fi
	done <<<"$issue_body" | sort -un
	return 0
}

#######################################
# Check whether a consolidated successor has no independent implementation
# scope beyond canonical source markers and generated aidevops metadata.
# Args: $1 = issue body
# Returns: 0 when all substantive scope is inherited, 1 otherwise
#######################################
_pir_successor_scope_is_fully_inherited() {
	local issue_body="$1"
	local line="" in_signature=0
	local marker_regex='^_Supersedes #([0-9]+) (—|-) this issue is the consolidated spec\._$'
	local origin_regex='^<!--[[:space:]]+aidevops:origin:(interactive|worker)[[:space:]]+-->$'
	local footer_regex='^\[aidevops\.sh\]\(https://aidevops\.sh\)[[:space:]]'

	while IFS= read -r line; do
		line="${line%$'\r'}"
		[[ -z "${line//[[:space:]]/}" ]] && continue
		if [[ "$in_signature" -eq 1 ]]; then
			[[ "$line" == "---" ]] && continue
			[[ "$line" =~ $footer_regex ]] && continue
			return 1
		fi
		[[ "$line" =~ $marker_regex ]] && continue
		[[ "$line" =~ $origin_regex ]] && continue
		if [[ "$line" == "<!-- aidevops:sig -->" ]]; then
			in_signature=1
			continue
		fi
		return 1
	done <<<"$issue_body"
	return 0
}

#######################################
# GH#37600: stranded consolidated issues (stage 0c).
#
# An open `consolidated` issue that the dispatch management-label gate
# (_has_consolidated_label) always rejects is either a superseded original
# whose consolidation task never closed it, or a legacy successor whose body
# predates the canonical marker line. The dispatch candidate filter already
# keeps both out of worker launches; this stage repairs their lifecycle:
#   1. trusted "Superseded by #N" comment and an existing successor issue:
#      close the original as not planned, link the successor, repoint
#      dependants (dependency-supersession-repoint-helper.sh);
#   2. exactly one legacy "Supersedes #N" body line and a closed predecessor:
#      rewrite only that line to the canonical marker;
#   3. otherwise one deduplicated hygiene anomaly and no mutation.
# Hold/recovery labels, untrusted body authors, a reopen after the
# supersession comment and unreadable evidence never mutate. A runner-local
# stamp bounds lookups to one per issue per TTL and deduplicates anomalies
# per label/body revision.
#######################################
_PIR_STRANDED_TTL_SECONDS="${AIDEVOPS_RECONCILE_STRANDED_CONSOLIDATED_TTL_SECONDS:-3600}"
[[ "$_PIR_STRANDED_TTL_SECONDS" =~ ^[0-9]+$ ]] || _PIR_STRANDED_TTL_SECONDS=3600
_PIR_STRANDED_HOLD_LABELS=",status:blocked,status:in-progress,status:queued,status:claimed,status:in-review,needs-maintainer-review,needs-maintainer-permissions,hold-for-review,persistent,parent-task,consolidation-in-progress,"
_PIR_STRANDED_TRUSTED_ASSOCIATIONS=",OWNER,MEMBER,COLLABORATOR,"
_PIR_STRANDED_DEFERRED="deferred"
_PIR_STRANDED_CLOSED_ISSUE="false closed"
_PIR_STRANDED_LOOKUP_USED=0
_PIR_STRANDED_REASON=""

# Stage 0c predicate: consolidated label present and the shared dispatch gate
# rejects the issue. Fails closed (no action) when the shared gate is absent.
# Args: $1=labels CSV, $2=issue body
_should_reconcile_stranded_consolidated() {
	local labels_csv="$1"
	local issue_body="${2:-}"
	local meta=""
	_pir_labels_csv_contains "$labels_csv" consolidated || return 1
	declare -F _has_consolidated_label >/dev/null 2>&1 || return 1
	meta=$(printf '%s' "$issue_body" | jq -Rsc --arg labels "$labels_csv" \
		'{labels: ($labels | split(",")), body: .}' 2>/dev/null) || return 1
	_has_consolidated_label "$meta" || return 1
	return 0
}

_pir_stranded_stamp_path() {
	local slug="$1"
	local issue_num="$2"
	printf '%s/.aidevops/logs/reconcile-stranded-consolidated/%s--%s--%s\n' \
		"$HOME" "${slug%%/*}" "${slug##*/}" "$issue_num"
	return 0
}

# Fingerprint of the cached labels and body; any change re-arms lookups.
_pir_stranded_fingerprint() {
	local labels_csv="$1"
	local issue_body="$2"
	local sum=""
	sum=$(printf '%s\n%s' "$labels_csv" "$issue_body" | cksum 2>/dev/null) || sum=""
	printf '%s\n' "${sum%% *}"
	return 0
}

# Returns 0 while this fingerprint's stamp is younger than the TTL (skip).
_pir_stranded_stamp_fresh() {
	local slug="$1"
	local issue_num="$2"
	local fingerprint="$3"
	local stamp_file="" stamp_ts="" stamp_fp="" stamp_reason="" now=""
	[[ "$_PIR_STRANDED_TTL_SECONDS" -gt 0 ]] || return 1
	stamp_file=$(_pir_stranded_stamp_path "$slug" "$issue_num")
	[[ -f "$stamp_file" && ! -L "$stamp_file" ]] || return 1
	read -r stamp_ts stamp_fp stamp_reason <"$stamp_file" || return 1
	[[ "$stamp_ts" =~ ^[0-9]+$ && -n "$stamp_reason" && "$stamp_fp" == "$fingerprint" ]] || return 1
	now=$(date +%s)
	((now >= stamp_ts && now - stamp_ts < _PIR_STRANDED_TTL_SECONDS)) || return 1
	return 0
}

#######################################
# Stamp a stage 0c outcome. An anomaly is logged and counted once per
# fingerprint and reason; TTL re-checks of an unchanged issue stay silent.
# Args: $1=slug, $2=issue, $3=fingerprint, $4=anomaly reason or "ok"
#######################################
_pir_stranded_record() {
	local slug="$1"
	local issue_num="$2"
	local fingerprint="$3"
	local reason="$4"
	local stamp_file="" prev_ts="" prev_fp="" prev_reason=""
	stamp_file=$(_pir_stranded_stamp_path "$slug" "$issue_num")
	[[ -L "$stamp_file" ]] && return 0
	if [[ -f "$stamp_file" ]]; then
		read -r prev_ts prev_fp prev_reason <"$stamp_file" || true
	fi
	if [[ "$reason" != "ok" && ! ("$prev_fp" == "$fingerprint" && "$prev_reason" == "$reason") ]]; then
		echo "[pulse-wrapper] CONSOLIDATED_HYGIENE_ANOMALY #${issue_num} (${slug}) reason=${reason} — open consolidated issue has no safe automatic lineage repair; the dispatch candidate filter keeps it out of worker launches until its brief owner closes it or restores the canonical marker (GH#37600)" >>"$LOGFILE"
		if declare -F pulse_stats_increment >/dev/null 2>&1; then
			pulse_stats_increment "reconcile_consolidated_hygiene_anomaly" 2>/dev/null || true
		fi
	fi
	mkdir -p "${stamp_file%/*}" 2>/dev/null || return 0
	printf '%s %s %s\n' "$(date +%s)" "$fingerprint" "$reason" >"$stamp_file" 2>/dev/null || true
	return 0
}

# Returns 0 when any label is a review, recovery, lifecycle or lock hold.
_pir_stranded_hold_label() {
	local labels_csv="$1"
	local label=""
	local -a labels=()
	IFS=',' read -r -a labels <<<"$labels_csv"
	for label in ${labels[@]+"${labels[@]}"}; do
		[[ -n "$label" && "$_PIR_STRANDED_HOLD_LABELS" == *",${label},"* ]] && return 0
	done
	return 1
}

# Prints "<is_pull_request> <state>" for an issue number, e.g. "false closed".
_pir_stranded_issue_kind_state() {
	local slug="$1"
	local number="$2"
	gh api "repos/${slug}/issues/${number}" \
		--jq '[(has("pull_request") | tostring), (.state // "")] | join(" ")' 2>/dev/null || return 1
	return 0
}

# Prints the live body of an issue (empty string when the body is null).
_pir_stranded_live_body() {
	local slug="$1"
	local number="$2"
	gh api "repos/${slug}/issues/${number}" --jq '.body // ""' 2>/dev/null || return 1
	return 0
}

#######################################
# Newest trusted comment time whose first non-blank line names the successor.
# aidevops:trust-boundary — same author/first-line rule as _dep_supersession_fetch.
# Args: $1=slug, $2=issue, $3=successor
# Stdout: ISO-8601 UTC time, or empty when no such comment is visible
# Returns: 0 on a complete read, 1 when comments are unavailable
#######################################
_pir_stranded_supersession_at() {
	local slug="$1"
	local issue_num="$2"
	local successor="$3"
	local comments="" latest=""
	comments=$(gh api --paginate "repos/${slug}/issues/${issue_num}/comments?per_page=100" 2>/dev/null) || return 1
	latest=$(printf '%s' "$comments" | jq -rs --arg n "$successor" '
		[flatten[] | select(type == "object")
			| select((.author_association // "") | IN("OWNER", "MEMBER", "COLLABORATOR"))
			| select((.body // "") | gsub("\r"; "") | split("\n") | map(select(test("\\S"))) | (.[0] // "")
				| test("^\\s*Superseded by #" + $n + "\\b"; "i"))
			| (.created_at // empty)] | max // ""' 2>/dev/null) || return 1
	printf '%s\n' "$latest"
	return 0
}

#######################################
# Close a superseded original whose trusted successor issue exists, then
# verify the close and repoint dependants. Sets _PIR_STRANDED_REASON when
# nothing was closed ("deferred" means retry without an anomaly).
# Args: $1=slug, $2=issue, $3=successor
# Returns: 0 when the original is verified closed, 1 otherwise
#######################################
_pir_stranded_close_superseded() {
	local slug="$1"
	local issue_num="$2"
	local successor="$3"
	local successor_info="" reopen_at="" superseded_at="" state="" helper=""
	_PIR_STRANDED_REASON=""
	if [[ "$successor" == "$issue_num" ]]; then
		_PIR_STRANDED_REASON="self_supersession"
		return 1
	fi
	if ! successor_info=$(_pir_stranded_issue_kind_state "$slug" "$successor"); then
		_PIR_STRANDED_REASON="successor_unverified"
		return 1
	fi
	if [[ "$successor_info" != "false open" && "$successor_info" != "$_PIR_STRANDED_CLOSED_ISSUE" ]]; then
		_PIR_STRANDED_REASON="successor_not_issue"
		return 1
	fi
	# A reopen after the supersession comment is a deliberate new lifecycle.
	if ! reopen_at=$(_pir_latest_reopen_at "$slug" "$issue_num"); then
		_PIR_STRANDED_REASON="$_PIR_STRANDED_DEFERRED"
		return 1
	fi
	if [[ -n "$reopen_at" ]]; then
		if ! superseded_at=$(_pir_stranded_supersession_at "$slug" "$issue_num" "$successor"); then
			_PIR_STRANDED_REASON="$_PIR_STRANDED_DEFERRED"
			return 1
		fi
		if [[ ! "$superseded_at" =~ $_PIR_ISO_UTC_RE || "$superseded_at" < "$reopen_at" ]]; then
			_PIR_STRANDED_REASON="reopened_after_supersession"
			return 1
		fi
	fi
	if ! gh issue close "$issue_num" --repo "$slug" --reason "not planned" \
		--comment "Closing as not planned: this \`consolidated\` issue was superseded by #${successor} (trusted supersession comment), but its consolidation handoff left it open. Continue on #${successor}. Detected by reconcile pass (GH#37600)." \
		>/dev/null 2>&1; then
		echo "[pulse-wrapper] Reconcile consolidated: deferred close #${issue_num} in ${slug} — close call failed (GH#37600)" >>"$LOGFILE"
		_PIR_STRANDED_REASON="$_PIR_STRANDED_DEFERRED"
		return 1
	fi
	state=$(_pir_stranded_issue_kind_state "$slug" "$issue_num") || state=""
	if [[ "$state" != "$_PIR_STRANDED_CLOSED_ISSUE" ]]; then
		echo "[pulse-wrapper] Reconcile consolidated: close of #${issue_num} in ${slug} not verified (state='${state}') (GH#37600)" >>"$LOGFILE"
		_PIR_STRANDED_REASON="close_unverified"
		return 1
	fi
	helper="${SCRIPT_DIR}/dependency-supersession-repoint-helper.sh"
	if [[ -f "$helper" ]] && bash "$helper" repoint "$slug" "$issue_num" "$successor" >>"$LOGFILE" 2>&1; then
		echo "[pulse-wrapper] Reconcile consolidated: closed #${issue_num} in ${slug} as not planned — superseded by #${successor}; dependants repointed (GH#37600)" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Reconcile consolidated: closed #${issue_num} in ${slug} as not planned — superseded by #${successor}; WARN dependant repoint failed, readiness still follows the supersession chain (GH#34341/GH#37600)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Replace one legacy marker line with the canonical marker, keeping any
# trailing lineage prose on the following line and every other line intact.
# Args: $1=issue body, $2=legacy line (CR stripped), $3=predecessor
# Stdout: rewritten body
#######################################
_pir_stranded_rewrite_legacy_line() {
	local issue_body="$1"
	local legacy_line="$2"
	local predecessor="$3"
	local marker="_Supersedes #${predecessor} — this issue is the consolidated spec._"
	local line="" rest="" previous="" italic="" out="" replaced=0
	[[ "$legacy_line" == _* ]] && italic="_"
	rest="${legacy_line#*"#${predecessor}"}"
	[[ -n "$italic" ]] && rest="${rest%_}"
	while [[ "$rest" != "$previous" ]]; do
		previous="$rest"
		rest="${rest#[[:space:].,:;-]}"
		rest="${rest#—}"
		rest="${rest#–}"
	done
	rest="${rest%"${rest##*[![:space:]]}"}"
	while IFS= read -r line; do
		if [[ "$replaced" -eq 0 && "${line%$'\r'}" == "$legacy_line" ]]; then
			replaced=1
			out+="${marker}"$'\n'
			[[ -n "$rest" ]] && out+="${italic}${rest}${italic}"$'\n'
			continue
		fi
		out+="${line}"$'\n'
	done <<<"$issue_body"
	printf '%s' "${out%$'\n'}"
	return 0
}

#######################################
# Normalise exactly one legacy "Supersedes #N" line when the trusted body
# names a closed predecessor issue. Sets _PIR_STRANDED_REASON on refusal.
# Args: $1=slug, $2=issue, $3=cached body, $4=cached author association
# Returns: 0 when the canonical marker is verified live, 1 otherwise
#######################################
_pir_stranded_normalize_legacy_marker() {
	local slug="$1"
	local issue_num="$2"
	local issue_body="$3"
	local author_association="$4"
	local legacy_regex='^_?Supersedes #([0-9]+)([^0-9].*)?$'
	local line="" legacy_line="" predecessor="" predecessor_info="" live_body=""
	local new_body="" body_file="" edit_rc=0 legacy_count=0
	_PIR_STRANDED_REASON=""
	while IFS= read -r line; do
		line="${line%$'\r'}"
		[[ "$line" =~ $legacy_regex ]] || continue
		legacy_count=$((legacy_count + 1))
		legacy_line="$line"
		predecessor="${BASH_REMATCH[1]}"
	done <<<"$issue_body"
	if [[ "$legacy_count" -ne 1 ]]; then
		_PIR_STRANDED_REASON="no_verifiable_lineage"
		[[ "$legacy_count" -gt 1 ]] && _PIR_STRANDED_REASON="ambiguous_legacy_marker"
		return 1
	fi
	#aidevops:trust-boundary -- only a write-authorized body author can assert lineage.
	if [[ "$_PIR_STRANDED_TRUSTED_ASSOCIATIONS" != *",${author_association:-NONE},"* ]]; then
		_PIR_STRANDED_REASON="untrusted_body_author"
		return 1
	fi
	if [[ "$predecessor" == "$issue_num" ]]; then
		_PIR_STRANDED_REASON="self_supersession"
		return 1
	fi
	if ! predecessor_info=$(_pir_stranded_issue_kind_state "$slug" "$predecessor"); then
		_PIR_STRANDED_REASON="predecessor_unverified"
		return 1
	fi
	if [[ "$predecessor_info" != "$_PIR_STRANDED_CLOSED_ISSUE" ]]; then
		_PIR_STRANDED_REASON="predecessor_not_closed"
		return 1
	fi
	# Compare-and-swap against the cached body so a concurrent edit is kept.
	_PIR_STRANDED_REASON="$_PIR_STRANDED_DEFERRED"
	live_body=$(_pir_stranded_live_body "$slug" "$issue_num") || return 1
	[[ "$live_body" == "$issue_body" ]] || return 1
	new_body=$(_pir_stranded_rewrite_legacy_line "$issue_body" "$legacy_line" "$predecessor")
	[[ -n "$new_body" && "$new_body" != "$issue_body" ]] || return 1
	# Body edits go only through the validating, audited wrapper.
	declare -F gh_issue_edit_safe >/dev/null 2>&1 || return 1
	body_file=$(mktemp -t pir-consolidated-body.XXXXXX) || return 1
	printf '%s\n' "$new_body" >"$body_file"
	gh_issue_edit_safe "$issue_num" --repo "$slug" --body-file "$body_file" >/dev/null 2>&1 || edit_rc=$?
	rm -f "$body_file"
	if [[ "$edit_rc" -ne 0 ]]; then
		echo "[pulse-wrapper] Reconcile consolidated: legacy marker repair failed for #${issue_num} in ${slug} (GH#37600)" >>"$LOGFILE"
		return 1
	fi
	live_body=$(_pir_stranded_live_body "$slug" "$issue_num") || live_body=""
	local verified_nums=""
	verified_nums=$(_pir_extract_superseded_issue_nums "$live_body") || verified_nums=""
	if ! grep -qx "$predecessor" <<<"$verified_nums"; then
		echo "[pulse-wrapper] Reconcile consolidated: legacy marker repair for #${issue_num} in ${slug} not verified (GH#37600)" >>"$LOGFILE"
		_PIR_STRANDED_REASON="marker_repair_unverified"
		return 1
	fi
	echo "[pulse-wrapper] Reconcile consolidated: normalised legacy marker on #${issue_num} in ${slug} to canonical _Supersedes #${predecessor}_ (closed predecessor) (GH#37600)" >>"$LOGFILE"
	_PIR_STRANDED_REASON=""
	return 0
}

#######################################
# Stage 0c action: reconcile one stranded consolidated issue.
# Args: $1=slug, $2=issue, $3=labels CSV, $4=cached body,
#       $5=cached author association
# Sets: _PIR_STRANDED_LOOKUP_USED=1 when GitHub lookups ran (caller's cap)
# Returns: 0=original closed (terminal), 2=legacy marker normalised,
#          1=no mutation (fresh stamp, hold, anomaly or deferral)
#######################################
_action_reconcile_stranded_consolidated() {
	local slug="$1"
	local issue_num="$2"
	local labels_csv="$3"
	local issue_body="$4"
	local author_association="${5:-}"
	local fingerprint="" row="" state="" successor=""
	_PIR_STRANDED_LOOKUP_USED=0
	_PIR_STRANDED_REASON=""
	[[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$issue_num" =~ ^[1-9][0-9]*$ ]] || return 1
	fingerprint=$(_pir_stranded_fingerprint "$labels_csv" "$issue_body")
	_pir_stranded_stamp_fresh "$slug" "$issue_num" "$fingerprint" && return 1
	#aidevops:trust-boundary -- review, recovery, lifecycle and lock holds stay mutation-free.
	if _pir_stranded_hold_label "$labels_csv"; then
		_pir_stranded_record "$slug" "$issue_num" "$fingerprint" "hold_label_present"
		return 1
	fi
	_pir_budget_allows_mutation || return 1
	_PIR_STRANDED_LOOKUP_USED=1
	if ! row=$(_dep_supersession_fetch "$slug" "$issue_num"); then
		echo "[pulse-wrapper] Reconcile consolidated: deferred #${issue_num} in ${slug} — supersession lookup unavailable (GH#37600)" >>"$LOGFILE"
		return 1
	fi
	IFS='|' read -r state _ successor <<<"$row"
	[[ "$state" == "OPEN" ]] || return 1
	if [[ "$successor" =~ ^[1-9][0-9]*$ ]]; then
		_pir_stranded_close_superseded "$slug" "$issue_num" "$successor" && return 0
	elif [[ -n "$(_pir_extract_superseded_issue_nums "$issue_body")" ]]; then
		# A canonical successor without the auto-dispatch handoff is an explicit
		# owner hold; stranded draft checkpoints get their own attention record.
		_pir_stranded_record "$slug" "$issue_num" "$fingerprint" "ok"
		return 1
	else
		_pir_stranded_normalize_legacy_marker "$slug" "$issue_num" "$issue_body" \
			"$author_association" && return 2
	fi
	[[ "$_PIR_STRANDED_REASON" == "$_PIR_STRANDED_DEFERRED" ]] && return 1
	_pir_stranded_record "$slug" "$issue_num" "$fingerprint" "${_PIR_STRANDED_REASON:-no_verifiable_lineage}"
	return 1
}

#######################################
# Lookup the merged PR number for an issue in the OIMP lookup string.
# Args: $1 = issue number, $2 = oimp lookup string
# Stdout: first matching PR number or empty
#######################################
_pir_lookup_oimp_pr_for_issue() {
	local issue_num="$1"
	local oimp_lookup="$2"
	[[ "$issue_num" =~ ^[0-9]+$ && -n "$oimp_lookup" ]] || return 0

	printf '%s' "$oimp_lookup" |
		grep -oE "\|${issue_num}=[0-9]+" 2>/dev/null |
		head -1 |
		cut -d= -f2
	return 0
}

#######################################
# Lookup every merged PR number for an issue in the OIMP lookup string.
# Args: $1 = issue number, $2 = oimp lookup string
# Stdout: matching PR numbers, one per line, lookup order, deduplicated
#######################################
_pir_lookup_oimp_prs_for_issue() {
	local issue_num="$1"
	local oimp_lookup="$2"
	[[ "$issue_num" =~ ^[0-9]+$ && -n "$oimp_lookup" ]] || return 0

	printf '%s' "$oimp_lookup" |
		grep -oE "\|${issue_num}=[0-9]+" 2>/dev/null |
		cut -d= -f2 |
		awk '!seen[$0]++'
	return 0
}

_PIR_ISO_UTC_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

#######################################
# Latest `reopened` event time for an issue (GH#33687). Same evidence as
# dispatch-dedup-pr.sh _ddpr_latest_reopen_at (GH#33071), but close authority
# needs complete evidence: an API failure or any malformed/missing reopen
# timestamp fails the read instead of being dropped.
# Args: $1=slug, $2=issue_num
# Stdout: ISO-8601 UTC timestamp, or empty when the issue was never reopened
# Returns: 0 on complete evidence, 1 when evidence is unavailable
#######################################
_pir_latest_reopen_at() {
	local slug="$1" issue_num="$2"
	local events="" event_at="" latest=""
	events=$(gh api --paginate "repos/${slug}/issues/${issue_num}/events?per_page=100" \
		--jq '.[] | select(.event == "reopened") | (.created_at // "missing")' \
		2>/dev/null) || return 1
	while IFS= read -r event_at; do
		[[ -n "$event_at" ]] || continue
		[[ "$event_at" =~ $_PIR_ISO_UTC_RE ]] || return 1
		if [[ -z "$latest" || "$event_at" > "$latest" ]]; then
			latest="$event_at"
		fi
	done <<<"$events"
	printf '%s\n' "$latest"
	return 0
}

#######################################
# From candidate merged PRs, print the first whose authoritative merge time is
# at or after the issue's latest reopen (GH#33687). A merge that predates the
# reopen belongs to an earlier lifecycle and cannot justify closing again.
# Args: $1=slug, $2=reopen_at (ISO-8601 UTC, non-empty), $3=newline PR list
# Stdout: qualifying PR number, or empty when every candidate predates reopen
# Returns: 0 on a complete decision, 1 when any merge time is unavailable
#######################################
_pir_select_pr_merged_after() {
	local slug="$1" reopen_at="$2" candidates="$3"
	local pr_num="" merged_at=""
	[[ "$reopen_at" =~ $_PIR_ISO_UTC_RE ]] || return 1
	while IFS= read -r pr_num; do
		[[ "$pr_num" =~ ^[0-9]+$ ]] || continue
		merged_at=$(gh api "repos/${slug}/pulls/${pr_num}" --jq '.merged_at // ""' 2>/dev/null) || return 1
		[[ "$merged_at" =~ $_PIR_ISO_UTC_RE ]] || return 1
		if [[ "$merged_at" == "$reopen_at" || "$merged_at" > "$reopen_at" ]]; then
			printf '%s\n' "$pr_num"
			return 0
		fi
	done <<<"$candidates"
	return 0
}

#######################################
# Restrict OIMP close evidence to merges from the reopened issue's current
# lifecycle (GH#33687). Direct evidence considers every merged PR linked to the
# issue; successor evidence requires each superseded source to have such a PR.
# Args: $1=slug, $2=issue_num, $3=oimp_lookup, $4=reopen_at, $5=direct (0|1),
#       $6=superseded coverage lines (source=pr)
# Sets: _PIR_OIMP_FENCED_PR, _PIR_OIMP_FENCED_COVERAGE
# Returns: 0 when current-lifecycle evidence exists, 1 to skip/defer
#######################################
_pir_oimp_fence_to_current_lifecycle() {
	local slug="$1" issue_num="$2" oimp_lookup="$3" reopen_at="$4"
	local direct="$5" coverage="$6"
	local candidates="" selected="" line="" source_num="" fenced=""
	_PIR_OIMP_FENCED_PR=""
	_PIR_OIMP_FENCED_COVERAGE=""

	if [[ "$direct" -eq 1 ]]; then
		candidates=$(_pir_lookup_oimp_prs_for_issue "$issue_num" "$oimp_lookup")
		selected=$(_pir_select_pr_merged_after "$slug" "$reopen_at" "$candidates") || {
			echo "[pulse-wrapper] Reconcile merged-PR: deferred close #${issue_num} in ${slug} — merge time unavailable (GH#33687)" >>"$LOGFILE"
			return 1
		}
		if [[ -z "$selected" ]]; then
			echo "[pulse-wrapper] Reconcile merged-PR: skipped close #${issue_num} in ${slug} — every linked merge predates reopen at ${reopen_at} (GH#33687)" >>"$LOGFILE"
			return 1
		fi
		_PIR_OIMP_FENCED_PR="$selected"
		return 0
	fi

	while IFS= read -r line; do
		[[ "$line" == *=* ]] || continue
		source_num="${line%%=*}"
		candidates=$(_pir_lookup_oimp_prs_for_issue "$source_num" "$oimp_lookup")
		selected=$(_pir_select_pr_merged_after "$slug" "$reopen_at" "$candidates") || {
			echo "[pulse-wrapper] Reconcile merged-PR: deferred close #${issue_num} in ${slug} — merge time unavailable for superseded #${source_num} (GH#33687)" >>"$LOGFILE"
			return 1
		}
		if [[ -z "$selected" ]]; then
			echo "[pulse-wrapper] Reconcile merged-PR: skipped close #${issue_num} in ${slug} — superseded #${source_num} merge predates reopen at ${reopen_at} (GH#33687)" >>"$LOGFILE"
			return 1
		fi
		[[ -n "$_PIR_OIMP_FENCED_PR" ]] || _PIR_OIMP_FENCED_PR="$selected"
		fenced="${fenced}${source_num}=${selected}"$'\n'
	done <<<"$coverage"
	[[ -n "$_PIR_OIMP_FENCED_PR" ]] || return 1
	_PIR_OIMP_FENCED_COVERAGE="$fenced"
	return 0
}

#######################################
# Build the OIMP close comment from the final (fenced) evidence.
# Args: $1=direct (0|1), $2=merged_pr_num, $3=coverage_count, $4=coverage lines
#######################################
_pir_oimp_close_comment() {
	local direct="$1" merged_pr_num="$2" coverage_count="$3" coverage="$4"
	if [[ "$direct" -eq 1 ]]; then
		printf 'Closing: linked PR #%s was already merged. Detected by reconcile pass.\n' "$merged_pr_num"
	elif [[ "$coverage_count" -eq 1 ]]; then
		printf 'Closing: this consolidated issue supersedes #%s, and merged PR #%s already fixed that superseded issue. Detected by reconcile pass.\n' \
			"${coverage%%=*}" "$merged_pr_num"
	else
		printf 'Closing: merged PR evidence completely covers all %s superseded sources for this scope-inheriting consolidated issue. Detected by reconcile pass.\n' \
			"$coverage_count"
	fi
	return 0
}

#######################################
# Final pre-close fence (GH#33687): the latest reopen must be unchanged since
# evidence selection. Fails closed when the re-read is unavailable.
# Args: $1=slug, $2=issue_num, $3=reopen_at observed earlier (may be empty)
#######################################
_pir_reopen_evidence_unchanged() {
	local slug="$1" issue_num="$2" expected="$3" current=""
	current=$(_pir_latest_reopen_at "$slug" "$issue_num") || return 1
	[[ "$current" == "$expected" ]] || return 1
	return 0
}

#######################################
# Stage-1 close fence (GH#33687): with no reopen any merge is current; after a
# reopen the merge time must be known and at or after the latest reopen.
# Args: $1=slug, $2=issue_num, $3=merged_at (may be empty when unknown)
# Returns: 0 when closing is lifecycle-safe, 1 to skip/defer
#######################################
_pir_merge_is_current_lifecycle() {
	local slug="$1" issue_num="$2" merged_at="$3" reopen_at=""
	reopen_at=$(_pir_latest_reopen_at "$slug" "$issue_num") || return 1
	[[ -n "$reopen_at" ]] || return 0
	[[ "$merged_at" =~ $_PIR_ISO_UTC_RE ]] || return 1
	[[ "$merged_at" == "$reopen_at" || "$merged_at" > "$reopen_at" ]] || return 1
	return 0
}

##############################################
# t2776: Per-issue action helpers for reconcile_issues_single_pass.
# Each helper encapsulates the action logic for one reconcile sub-stage.
# Called once per qualifying issue; the outer loop and issue fetch live in
# reconcile_issues_single_pass — not here.
#
# Return conventions (consistent across helpers):
#   0 = action taken (issue closed / fixed / nudged / escalated)
#   1 = no action taken (skipped, guard fired, API failure, etc.)
#   2 = reset action taken (used by _action_rsd_single: reset to available)
##############################################

_pir_pr_lookup_uncertain() {
	local dedup_output="$1"
	[[ "$dedup_output" == *"PR_LOOKUP_RESULT=uncertain"* ]] || return 1
	return 0
}

#######################################
# Stage 1 action: close an issue whose work is done via a merged PR.
# (Per-issue body of close_issues_with_merged_prs — no slug loop.)
#
# Args: $1=slug, $2=issue_num, $3=issue_title, $4=dedup_helper, $5=verify_helper,
#       $6=issue_body (optional; enables the recurrent file-size-debt gate)
# Returns: 0 if issue was closed, 1 otherwise
#######################################
_action_ciw_single() {
	local slug="$1" issue_num="$2" issue_title="$3"
	local dedup_helper="$4" verify_helper="$5"
	local issue_body="${6:-}"

	# GH#32640: checked before any API call — regrown debt is never closed on
	# historical merged-PR evidence, and an unmeasurable outcome defers.
	_pir_file_size_debt_close_gate "$slug" "$issue_num" "$issue_body" "Auto-close" || return 1

	local dedup_output=""
	dedup_output=$("$dedup_helper" has-open-pr "$issue_num" "$slug" "$issue_title" 2>/dev/null) || return 1
	if _pir_pr_lookup_uncertain "$dedup_output"; then
		echo "[pulse-wrapper] Deferred auto-close #${issue_num} in ${slug} — PR lookup uncertain" >>"$LOGFILE"
		return 1
	fi

	local pr_ref="" pr_num="" merged_at=""
	pr_ref=$(printf '%s' "$dedup_output" | grep -o '#[0-9]*' | sed -n '1p') || pr_ref=""
	pr_num=$(printf '%s' "$pr_ref" | tr -d '#')
	merged_at=""

	if [[ -n "$pr_num" ]]; then
		merged_at=$(_pir_pr_merged_at "$pr_num" "$slug") || merged_at=""
		if [[ -z "$merged_at" ]]; then
			echo "[pulse-wrapper] Skipped auto-close #${issue_num} in ${slug} — PR #${pr_num} is NOT merged (GH#17871 guard)" >>"$LOGFILE"
			return 1
		fi
	fi

	if [[ -n "$pr_num" ]] && [[ -x "$verify_helper" ]]; then
		if ! "$verify_helper" check "$issue_num" "$pr_num" "$slug" >/dev/null 2>&1; then
			echo "[pulse-wrapper] Skipped auto-close #${issue_num} in ${slug} — PR #${pr_num} does not touch files from issue (GH#17372 guard)" >>"$LOGFILE"
			return 1
		fi
	fi

	# GH#33687: complete-evidence lifecycle fence immediately before close.
	# The dedup lookup drops malformed reopen times and can race a reopen.
	_pir_merge_is_current_lifecycle "$slug" "$issue_num" "$merged_at" || {
		echo "[pulse-wrapper] Deferred auto-close #${issue_num} in ${slug} — merge not proven after latest reopen (GH#33687)" >>"$LOGFILE"
		return 1
	}

	gh issue close "$issue_num" --repo "$slug" \
		--comment "Closing: work completed via merged PR ${pr_ref:-"(detected by dedup helper)"} (merged at ${merged_at:-unknown}). Issue was open but dedup guard was blocking re-dispatch." \
		>/dev/null 2>&1 || return 1
	[[ "$pr_num" =~ ^[0-9]+$ ]] && set_solved_label_from_merged_pr "$issue_num" "$slug" "$pr_num" || true

	fast_fail_reset "$issue_num" "$slug" || true
	unlock_issue_after_worker "$issue_num" "$slug"
	echo "[pulse-wrapper] Auto-closed #${issue_num} in ${slug} — merged PR evidence: ${dedup_output:-"found"}" >>"$LOGFILE"
	return 0
}

#######################################
# Stage 2 action: reconcile a status:done issue.
# (Per-issue body of reconcile_stale_done_issues — no slug loop.)
#
# Args: $1=slug, $2=issue_num, $3=issue_title, $4=dedup_helper, $5=verify_helper,
#       $6=issue_body (optional; enables the recurrent file-size-debt gate)
# Returns: 2 if healed to a non-terminal status, 1 if no action taken
#######################################
_action_rsd_single() {
	local slug="$1" issue_num="$2" issue_title="$3"
	local issue_json="" comments_json="" restored_status="available" issue_api=""
	printf -v issue_api 'repos/%s/issues/%s' "$slug" "$issue_num"
	# GH#33374: open + done is invalid, not permission to close. Closing-intent
	# reconciliation remains in stage 3; this stage only repairs the projection.
	issue_json=$(gh api "$issue_api" 2>/dev/null) || return 1
	printf '%s' "$issue_json" | jq -e '
		.state == "open" and any(.labels[]; .name == "status:done")' >/dev/null 2>&1 || return 1
	comments_json=$(gh api --paginate --slurp "${issue_api}/comments?per_page=100" 2>/dev/null) || return 1
	restored_status=$(printf '%s' "$comments_json" | jq -er '
		[.[][] | select(.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR")
			| select((.body // "") | test("^(<!-- ops:start[^\\n]*\\n)?(CLAIM_RELEASED|CLAIM_RENEWED|CLAIM_ACQUIRED)([[:space:]]|$)") | not)]
		| sort_by(.updated_at // .created_at) | last
		| if ((.body // "") | test("(^|\\n)(\\*\\*)?BLOCKED\\b|TERMINAL_BLOCKER_REASON=|status:blocked"; "i")) then "blocked" else "available" end' 2>/dev/null) || return 1
	if printf '%s' "$issue_json" | jq -e 'any(.labels[]; .name == "status:blocked")' >/dev/null 2>&1; then
		restored_status="blocked"
	fi
	set_issue_status "$issue_num" "$slug" "$restored_status" >/dev/null 2>&1 || return 1
	printf '[pulse-wrapper] Reconcile done: healed open + status:done #%s in %s to status:%s (%s)\n' \
		"$issue_num" "$slug" "$restored_status" "$issue_title" >>"$LOGFILE"
	return 2
}

#######################################
# Check whether a generated file-size-debt issue still describes current debt.
# Historical merged-PR evidence is not sufficient to close a recurrent issue
# while its exact cited file is again at or above the recorded threshold.
#
# Args: $1=repo slug, $2=issue body
# Returns: 0=current debt exists, 1=not generated debt or debt is resolved,
#          2=current outcome could not be measured (caller must fail safe)
#######################################
_pir_file_size_debt_current_outcome() {
	local slug="$1"
	local issue_body="$2"
	local marker="" cited_file="" threshold="" repo_path="" full_path=""
	local line_count=0 repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"

	marker=$(printf '%s\n' "$issue_body" | grep '<!-- aidevops:generator=large-file-simplification-gate cited_file=.* threshold=[0-9][0-9]* -->' 2>/dev/null | sed -n '1p') || marker=""
	[[ -n "$marker" ]] || return 1
	cited_file="${marker#* cited_file=}"
	cited_file="${cited_file% threshold=*}"
	threshold="${marker##* threshold=}"
	threshold="${threshold%% *}"
	[[ -n "$cited_file" && "$threshold" =~ ^[0-9]+$ && "$threshold" -gt 0 ]] || return 2

	[[ -f "$repos_json" ]] || return 2
	repo_path=$(jq -r --arg slug "$slug" '.initialized_repos[] | select(.slug == $slug) | .path // empty' "$repos_json" 2>/dev/null | sed -n '1p') || repo_path=""
	[[ -n "$repo_path" && -d "$repo_path" ]] || return 2

	for full_path in "${repo_path}/${cited_file}" "${repo_path}/.agents/${cited_file}" "${repo_path}/.${cited_file}"; do
		[[ -f "$full_path" ]] && break
		full_path=""
	done
	[[ -n "$full_path" ]] || return 2

	line_count=$(wc -l <"$full_path" 2>/dev/null | tr -d ' ') || line_count=0
	[[ "$line_count" =~ ^[0-9]+$ ]] || return 2
	if [[ "$line_count" -ge "$threshold" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Shared merged-PR close gate for recurrent file-size debt (GH#27444, GH#32640).
# Every reconcile stage that closes on merged-PR evidence must consult this
# before closing, so historical evidence cannot close regrown debt.
#
# Args: $1=slug, $2=issue_num, $3=issue body, $4=log label (stage name)
# Returns: 0=close may proceed, 1=debt still current (keep open),
#          2=current outcome unmeasurable (defer; caller must not close)
#######################################
_pir_file_size_debt_close_gate() {
	local slug="$1" issue_num="$2" issue_body="$3" stage_label="$4"
	local current_outcome_rc=0
	_pir_file_size_debt_current_outcome "$slug" "$issue_body" || current_outcome_rc=$?
	case "$current_outcome_rc" in
	0)
		echo "[pulse-wrapper] ${stage_label}: skipped close #${issue_num} in ${slug} — recurrent file-size debt still exceeds its threshold" >>"$LOGFILE"
		return 1
		;;
	2)
		echo "[pulse-wrapper] ${stage_label}: deferred close #${issue_num} in ${slug} — recurrent file-size debt outcome unavailable" >>"$LOGFILE"
		return 2
		;;
	esac
	return 0
}

#######################################
# Stage 3 action: close an open issue whose linked PR has already merged.
# (Per-issue body of reconcile_open_issues_with_merged_prs — no slug loop.)
#
# t2985: looks up the merged PR via the per-repo prefetched lookup string
# (built once by _build_oimp_lookup_for_slug). Replaces the previous
# per-issue gh search + gh pr view body-recheck pair, which was the
# dominant cost driver in reconcile_issues_single_pass (~600s/cycle at
# steady-state, the t2984 budget threshold). Body-keyword filtering is
# built into the lookup builder itself, so the redundant body-grep is
# also gone.
#
# Args:
#   $1 = slug
#   $2 = issue_num
#   $3 = verify_helper (path to verify-issue-close-helper.sh)
#   $4 = oimp_lookup (pipe-delimited |num=pr|...| string from
#        _build_oimp_lookup_for_slug; may be empty if prefetch failed)
#   $5 = issue_body (optional; used to close consolidated successors whose
#        body declares `Supersedes #N` and PR lookup shows #N was fixed)
# Returns: 0 if closed, 1 otherwise
#######################################
_action_oimp_single() {
	local slug="$1" issue_num="$2" verify_helper="$3"
	local oimp_lookup="${4:-}"
	local issue_body="${5:-}"

	# t2985: lookup PR number locally instead of `gh pr list --search`.
	# Empty lookup → no merged PR found → return 1 (next-cycle retry).
	local merged_pr_num="" close_comment="" direct_issue_evidence=0
	local superseded_coverage="" coverage_count=0 reopen_at=""
	merged_pr_num=$(_pir_lookup_oimp_pr_for_issue "$issue_num" "$oimp_lookup") || merged_pr_num=""
	if [[ -n "$merged_pr_num" && "$merged_pr_num" =~ ^[0-9]+$ ]]; then
		direct_issue_evidence=1
	else
		_pir_successor_scope_is_fully_inherited "$issue_body" || return 1
		local superseded_refs="" superseded_num="" component_pr=""
		superseded_refs=$(_pir_extract_superseded_issue_nums "$issue_body")
		[[ -n "$superseded_refs" ]] || return 1
		while IFS= read -r superseded_num; do
			[[ "$superseded_num" =~ ^[0-9]+$ ]] || continue
			[[ "$superseded_num" != "$issue_num" ]] || return 1
			component_pr=$(_pir_lookup_oimp_pr_for_issue "$superseded_num" "$oimp_lookup") || component_pr=""
			[[ -n "$component_pr" && "$component_pr" =~ ^[0-9]+$ ]] || return 1
			coverage_count=$((coverage_count + 1))
			[[ -n "$merged_pr_num" ]] || merged_pr_num="$component_pr"
			superseded_coverage="${superseded_coverage}${superseded_num}=${component_pr}"$'\n'
		done <<<"$superseded_refs"
		[[ "$coverage_count" -gt 0 ]] || return 1
	fi
	[[ -n "$merged_pr_num" && "$merged_pr_num" =~ ^[0-9]+$ ]] || return 1

	# GH#33687: merged-PR evidence must belong to the issue's current lifecycle.
	# A merge that predates the latest reopen cannot close the issue again;
	# unavailable lifecycle evidence defers every mutation to a later cycle.
	reopen_at=$(_pir_latest_reopen_at "$slug" "$issue_num") || {
		echo "[pulse-wrapper] Reconcile merged-PR: deferred close #${issue_num} in ${slug} — reopen lifecycle evidence unavailable (GH#33687)" >>"$LOGFILE"
		return 1
	}
	if [[ -n "$reopen_at" ]]; then
		_pir_oimp_fence_to_current_lifecycle "$slug" "$issue_num" "$oimp_lookup" \
			"$reopen_at" "$direct_issue_evidence" "$superseded_coverage" || return 1
		merged_pr_num="$_PIR_OIMP_FENCED_PR"
		superseded_coverage="$_PIR_OIMP_FENCED_COVERAGE"
	fi
	close_comment=$(_pir_oimp_close_comment "$direct_issue_evidence" "$merged_pr_num" \
		"$coverage_count" "$superseded_coverage")

	_pir_file_size_debt_close_gate "$slug" "$issue_num" "$issue_body" "Reconcile merged-PR" || return 1

	# Body keyword check is built into the lookup builder — the jq scan
	# only emits pairs from PR bodies actually containing
	# Resolves|Closes|Fixes #N. The previous `gh pr view ... body` re-grep
	# is now redundant and removed (t2985).

	if [[ -x "$verify_helper" ]]; then
		if [[ "$direct_issue_evidence" -eq 1 ]]; then
			if ! "$verify_helper" check "$issue_num" "$merged_pr_num" "$slug" >/dev/null 2>&1; then
				echo "[pulse-wrapper] Reconcile merged-PR: skipped close #${issue_num} in ${slug} — PR #${merged_pr_num} does not touch issue files (GH#17372)" >>"$LOGFILE"
				return 1
			fi
		else
			local coverage_line="" coverage_issue="" coverage_pr=""
			while IFS= read -r coverage_line; do
				[[ "$coverage_line" == *=* ]] || continue
				coverage_issue="${coverage_line%%=*}"
				coverage_pr="${coverage_line#*=}"
				if ! "$verify_helper" check "$coverage_issue" "$coverage_pr" "$slug" >/dev/null 2>&1; then
					echo "[pulse-wrapper] Reconcile merged-PR: skipped close #${issue_num} in ${slug} — PR #${coverage_pr} does not verify superseded source #${coverage_issue} (GH#32213)" >>"$LOGFILE"
					return 1
				fi
			done <<<"$superseded_coverage"
		fi
	fi

	# GH#33687: fence a reopen that raced cached discovery or the checks above.
	_pir_reopen_evidence_unchanged "$slug" "$issue_num" "$reopen_at" || {
		echo "[pulse-wrapper] Reconcile merged-PR: deferred close #${issue_num} in ${slug} — reopen lifecycle changed or unavailable before close (GH#33687)" >>"$LOGFILE"
		return 1
	}

	gh issue close "$issue_num" --repo "$slug" \
		--comment "$close_comment" \
		>/dev/null 2>&1 || return 1
	set_solved_label_from_merged_pr "$issue_num" "$slug" "$merged_pr_num" || true

	if declare -F fast_fail_reset >/dev/null 2>&1; then
		fast_fail_reset "$issue_num" "$slug" || true
	fi
	if declare -F unlock_issue_after_worker >/dev/null 2>&1; then
		unlock_issue_after_worker "$issue_num" "$slug"
	fi
	echo "[pulse-wrapper] Reconcile merged-PR: closed #${issue_num} in ${slug} — merged PR #${merged_pr_num}" >>"$LOGFILE"
	return 0
}

# t2776: globals set by _action_cpt_single to communicate multi-outcome results.
# Initialized to 0 before each call; set to 1 when the respective action fires.
_SP_CPT_CLOSED=0
_SP_CPT_NUDGED=0
_SP_CPT_ESCALATED=0
_SP_CPT_REOPENED=0
_PIR_CPT_CHILD_NUMS=""
_PIR_CPT_CHILD_SOURCE="none"
_PIR_CPT_KNOWN_CHILD_COUNT=0
_PIR_CPT_DECLARED_NUMS=""
_PIR_CPT_GRAPH_NUMS=""


#######################################
# Stage 4 action: reconcile a parent-task issue (close/nudge/escalate).
# (Per-issue body of reconcile_completed_parent_tasks — no slug loop.)
#
# Sets _SP_CPT_CLOSED / _SP_CPT_NUDGED / _SP_CPT_ESCALATED /
# _SP_CPT_REOPENED globals (each 0|1)
# to communicate which actions were taken. Caller reads and resets these.
#
# Args:
#   $1=slug, $2=issue_num, $3=issue_title, $4=issue_body
#   $5=can_close (1|0), $6=can_nudge (1|0), $7=can_escalate (1|0)
#   $8=escalation_threshold_hours, $9=issue_state (OPEN|CLOSED), $10=labels CSV
# Returns: 0 always (action outcomes via globals)
#######################################
_action_cpt_single() {
	local slug="$1" issue_num="$2" issue_title="$3" issue_body="$4"
	local can_close="${5:-0}" can_nudge="${6:-0}" can_escalate="${7:-0}"
	local escalation_threshold_hours="${8:-168}"
	local issue_state="${9:-OPEN}"
	local labels_csv="${10:-}"
	_SP_CPT_CLOSED=0
	_SP_CPT_NUDGED=0
	_SP_CPT_ESCALATED=0
	_SP_CPT_REOPENED=0
	if _pir_labels_csv_contains "$labels_csv" "${_PIR_NMR_LABEL:-needs-maintainer-review}" ||
		_pir_labels_csv_contains "$labels_csv" "${_PIR_PERSISTENT_LABEL:-persistent}"; then
		return 0
	fi

	# Closed rows are discovery hints only. Repair rebuilds and stabilizes all
	# child/body/revision evidence from complete live reads before reopening.
	if [[ "$issue_state" == "CLOSED" || "$issue_state" == "closed" ]]; then
		_repair_recently_closed_parent "$slug" "$issue_num" "$issue_state" || true
		return 0
	fi

	# Child evidence is the union of graph, body, prose, and trusted roadmap
	# comments; no single incomplete source may mask another.
	_pir_collect_parent_child_evidence "$slug" "$issue_num" "$issue_body" || return 0
	local child_nums="$_PIR_CPT_CHILD_NUMS"
	local child_source="$_PIR_CPT_CHILD_SOURCE"

	if [[ -z "$child_nums" ]]; then
		# No children — try phase extractor, then nudge/escalate (t2771/t2388/t2442)
		local _phase_extractor="${_PIR_SCRIPT_DIR}/parent-task-phase-extractor.sh"
		if [[ -x "$_phase_extractor" ]]; then
			_pir_parent_mutation_is_allowed "$slug" "$issue_num" || return 0
			if PHASE_EXTRACTOR_DRY_RUN="${PHASE_EXTRACTOR_DRY_RUN:-0}" \
				"$_phase_extractor" run "$issue_num" "$slug" >>"${LOGFILE:-/dev/null}" 2>&1; then
				echo "[pulse-wrapper] Reconcile parent-task: phase-extractor filed children for #${issue_num} in ${slug} (t2771)" >>"${LOGFILE:-/dev/null}"
				return 0
			fi
		fi
		if declare -F auto_file_next_unfiled_parent_phase >/dev/null 2>&1; then
			_pir_parent_mutation_is_allowed "$slug" "$issue_num" || return 0
			if auto_file_next_unfiled_parent_phase "$issue_num" "$slug" >>"${LOGFILE:-/dev/null}" 2>&1; then
				echo "[pulse-wrapper] Reconcile parent-task: phase bootstrap filed next child for #${issue_num} in ${slug} (GH#22534)" >>"${LOGFILE:-/dev/null}"
				return 0
			fi
		fi
		if [[ "$can_nudge" == "1" ]]; then
			_pir_parent_mutation_is_allowed "$slug" "$issue_num" || return 0
			if _post_parent_decomposition_nudge "$slug" "$issue_num" "$issue_title"; then
				_SP_CPT_NUDGED=1
			fi
		fi
		if [[ "$can_escalate" == "1" ]]; then
			local _nudge_age_hours
			_nudge_age_hours=$(_compute_parent_nudge_age_hours "$slug" "$issue_num")
			if [[ "$_nudge_age_hours" =~ ^[0-9]+$ ]] &&
				[[ "$_nudge_age_hours" -ge "$escalation_threshold_hours" ]]; then
				_pir_parent_mutation_is_allowed "$slug" "$issue_num" || return 0
				if _post_parent_decomposition_escalation "$slug" "$issue_num" "$issue_title"; then
					_SP_CPT_ESCALATED=1
				fi
			fi
		fi
		return 0
	fi

	if [[ "$can_close" == "1" ]]; then
		_pir_parent_mutation_is_allowed "$slug" "$issue_num" "" "$_PIR_PARENT_MUTATION_CLOSE" || return 0
		if _try_close_parent_tracker "$slug" "$issue_num" "$child_nums" "$child_source" "$issue_body"; then
			_SP_CPT_CLOSED=1
		fi
	fi
	return 0
}
