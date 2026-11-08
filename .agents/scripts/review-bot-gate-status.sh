#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Review Bot Gate -- Status JSON Snapshot and Bot State
# =============================================================================
# status-json PR snapshot helpers and per-bot state classification.
# Functions moved verbatim from review-bot-gate-helper.sh (GH#37011).
#
# Usage: source "${_RBG_SCRIPT_DIR}/review-bot-gate-status.sh"
#
# Dependencies: constants and sibling functions defined by review-bot-gate-helper.sh
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_RBG_STATUS_LIB_LOADED:-}" ]] && return 0
_RBG_STATUS_LIB_LOADED=1

# Fetch a genuine PR metadata snapshot and retry one locally deferred or timed
# out read. Never substitutes an earlier snapshot: exhausted retrieval remains
# unavailable so current-head authorization fails closed.
_rbg_status_pr_snapshot() {
	local pr_api="$1"
	local phase="$2"
	local response="" rc=0
	local retry_delay="${RBG_STATUS_SNAPSHOT_RETRY_DELAY_SECONDS:-1}"
	local retry_timeout="${RBG_STATUS_SNAPSHOT_RETRY_TIMEOUT_SECONDS:-10}"

	response=$(gh api "$pr_api" 2>/dev/null) || rc=$?
	if [[ "$rc" -eq 0 && -n "$response" ]]; then
		printf '%s\n' "$response"
		return 0
	fi

	# The governed gh transport reports local-admission deferral as 75 and
	# bounded read timeout as 124. A successful empty response is also not a
	# usable observation and receives the same single recovery attempt.
	if [[ "$rc" -ne 0 && "$rc" -ne 75 && "$rc" -ne 124 ]]; then
		printf '[review-bot-gate] %s PR snapshot transport failure (rc=%s); gate remains blocked\n' "$phase" "$rc" >&2
		return "$rc"
	fi
	[[ "$retry_delay" =~ ^[0-5]$ ]] || retry_delay=1
	[[ "$retry_timeout" =~ ^[0-9]+$ && "$retry_timeout" -ge 1 && "$retry_timeout" -le 30 ]] || retry_timeout=10
	printf '[review-bot-gate] %s PR snapshot unavailable (rc=%s); retrying once\n' "$phase" "$rc" >&2
	[[ "$retry_delay" -eq 0 ]] || sleep "$retry_delay"

	rc=0
	response=$(AIDEVOPS_GH_READ_TIMEOUT="$retry_timeout" gh api "$pr_api" 2>/dev/null) || rc=$?
	if [[ "$rc" -eq 0 && -n "$response" ]]; then
		printf '%s\n' "$response"
		return 0
	fi
	[[ "$rc" -ne 0 ]] || rc=75
	printf '[review-bot-gate] %s PR snapshot unavailable after bounded retry (rc=%s); gate remains blocked\n' "$phase" "$rc" >&2
	return "$rc"
}

_rbg_status_failure_reason() {
	local reason="$1"
	local permitted="$2"
	local snapshot_before_rc="$3"
	local snapshot_after_rc="$4"
	local head_sha_before="$5"
	local head_sha="$6"

	if [[ "$permitted" == "$RBG_TRUE" ]]; then
		printf '%s\n' "$reason"
	elif [[ "$snapshot_before_rc" -ne 0 || -z "$head_sha_before" ]]; then
		printf 'initial_snapshot_unavailable\n'
	elif [[ "$snapshot_after_rc" -ne 0 || -z "$head_sha" ]]; then
		printf 'post_decision_snapshot_unavailable\n'
	elif [[ "$head_sha_before" != "$head_sha" ]]; then
		printf 'head_changed_during_decision\n'
	else
		printf '%s\n' "$reason"
	fi
	return 0
}

_rbg_snapshot_author_association() {
	local pr_number="$1"
	local repo="$2"
	local pr_json="$3"
	[[ -n "$pr_json" ]] || return 0
	_resolve_pr_author_association "$pr_number" "$repo" "$pr_json"
	return 0
}

# Live collaborator-permission fallback for private org members, whom the REST
# author_association reports as CONTRIBUTOR (GH#37009; siblings GH#34644,
# GH#35622). Returns 0 (trusted) only for admin|maintain|write; any lookup
# failure, unknown permission or missing argument fails closed.
# #aidevops:trust-boundary — login/labels/runner identity never grant trust;
# only the live permission API does.
_rbg_author_has_write_permission() {
	local repo="$1"
	local author_login="$2"
	local perm=""
	[[ -n "$repo" && -n "$author_login" ]] || return 1
	if ! declare -F _gh_collaborator_permission_lookup >/dev/null 2>&1; then
		local lib_dir="${_RBG_SCRIPT_DIR:-${BASH_SOURCE[0]%/*}}"
		local lib=""
		for lib in github-app-auth-helper.sh shared-gh-wrappers-rest-fallback.sh shared-gh-collaborator-permission.sh; do
			# shellcheck disable=SC1090  # resolved at runtime
			[[ -f "${lib_dir}/${lib}" ]] && source "${lib_dir}/${lib}"
		done
	fi
	if ! declare -F _gh_collaborator_permission_lookup >/dev/null 2>&1; then
		printf '[review-bot-gate] collaborator permission helper unavailable; author treated as external\n' >&2
		return 1
	fi
	if ! _gh_collaborator_permission_lookup "$repo" "$author_login" perm 2>/dev/null; then
		printf '[review-bot-gate] collaborator permission lookup failed (reason=%s); author treated as external\n' "${AIDEVOPS_GH_COLLAB_PERMISSION_REASON:-unknown}" >&2
		return 1
	fi
	case "$perm" in
	admin | maintain | write) return 0 ;;
	esac
	return 1
}

# Print the author class: REST association first, then live permission lookup.
# #aidevops:trust-boundary — private org members appear as CONTRIBUTOR.
_rbg_author_class() {
	local repo="$1"
	local author_login="$2"
	local author_association="$3"
	case "$author_association" in
	OWNER | MEMBER | COLLABORATOR)
		printf '%s\n' "$RBG_AUTHOR_CLASS_TRUSTED"
		return 0
		;;
	esac
	if [[ -n "$author_login" ]] && _rbg_author_has_write_permission "$repo" "$author_login"; then
		printf '%s\n' "$RBG_AUTHOR_CLASS_TRUSTED"
		return 0
	fi
	printf 'external\n'
	return 0
}

do_status_json() {
	local pr_number="$1"
	local repo="$2"
	local output="" rc=0 state="waiting" blocked_prefix="bloc" status_pass="" pr_api=""
	local merge_gate="" snapshot_before_rc=0 snapshot_after_rc=0
	local pr_json_before="" pr_json="" head_sha_before="" head_sha="" author_login="" author_association_before="" author_association="" author_class="external"
	local head_stable="$RBG_FALSE" skip_label_present_after="$RBG_FALSE" permitted="$RBG_FALSE" reason="outcome_not_permitted"
	merge_gate="${blocked_prefix}ked"
	status_pass=$(printf 'P%s' 'ASS')

	pr_api=$(printf 'repos/%s/pulls/%s' "$repo" "$pr_number")
	pr_json_before=$(_rbg_status_pr_snapshot "$pr_api" "initial") || snapshot_before_rc=$?
	head_sha_before=$(jq -r '.head.sha // ""' <<<"$pr_json_before" 2>/dev/null) || head_sha_before=""
	author_association_before=$(_rbg_snapshot_author_association "$pr_number" "$repo" "$pr_json_before")
	output=$(REVIEW_GATE_EXPECTED_HEAD_SHA="$head_sha_before" REVIEW_GATE_AUTHOR_ASSOCIATION="$author_association_before" do_check "$pr_number" "$repo" "$pr_json_before" 2>/dev/null) || rc=$?
	pr_json=$(_rbg_status_pr_snapshot "$pr_api" "post-decision") || snapshot_after_rc=$?
	if [[ -n "$pr_json" ]]; then
		head_sha=$(jq -r '.head.sha // ""' <<<"$pr_json" 2>/dev/null) || head_sha=""
		author_login=$(jq -r '.user.login // ""' <<<"$pr_json" 2>/dev/null) || author_login=""
	fi
	author_association=$(_rbg_snapshot_author_association "$pr_number" "$repo" "$pr_json")
	if [[ -n "$head_sha_before" && "$head_sha_before" == "$head_sha" ]]; then
		head_stable="$RBG_TRUE"
	fi
	jq -e --arg label "$SKIP_LABEL" '[.labels[]?.name] | index($label) != null' <<<"$pr_json" >/dev/null 2>&1 && skip_label_present_after="$RBG_TRUE"
	author_class=$(_rbg_author_class "$repo" "$author_login" "$author_association")

	# #aidevops:trust-boundary — SKIP is a trusted-author label outcome. Advisory
	# completion and rate-limit grace apply to every author (GH#36931): external
	# merge authority is exact-head maintainer crypto approval, enforced outside
	# this gate. Malformed or metadata-less evidence never authorizes a decision.
	case "$output" in
	"$status_pass")
		if [[ "$head_stable" == "$RBG_TRUE" && -n "$author_login" ]]; then
			permitted="$RBG_TRUE"
			reason="live_review_pass"
		fi
		;;
	SKIP)
		if [[ "$author_class" == "$RBG_AUTHOR_CLASS_TRUSTED" && "$head_stable" == "$RBG_TRUE" && "$skip_label_present_after" == "$RBG_TRUE" ]]; then
			permitted="$RBG_TRUE"
			reason="trusted_skip"
		else
			reason="external_skip_denied"
		fi
		;;
	P[A]SS_RATE_LIMITED)
		if [[ "$head_stable" == "$RBG_TRUE" ]]; then
			permitted="$RBG_TRUE"
			reason="${author_class}_rate_limit_grace"
		fi
		;;
	P[A]SS_ADVISORY)
		if [[ "$head_stable" == "$RBG_TRUE" ]]; then
			permitted="$RBG_TRUE"
			reason="${author_class}_advisory_default"
		fi
		;;
	esac

	# Policy outcomes cannot override missing or changed current-head evidence.
	reason=$(_rbg_status_failure_reason "$reason" "$permitted" "$snapshot_before_rc" "$snapshot_after_rc" "$head_sha_before" "$head_sha")

	case "$output:$permitted" in
	"$status_pass:true" | P[A]SS_ADVISORY:true | P[A]SS_RATE_LIMITED:true | SKIP:true)
		state="pass"
		merge_gate="clear"
		;;
	WAITING:*)
		state="waiting"
		merge_gate="${blocked_prefix}ked"
		;;
	*)
		state="err""or"
		merge_gate="${blocked_prefix}ked"
		[[ "$rc" -eq 0 ]] && rc=2
		;;
	esac

	jq -nc \
		--arg pr "$pr_number" \
		--arg repo "$repo" \
		--arg status "${output:-ERROR}" \
		--arg head_sha "$head_sha" \
		--arg author_login "$author_login" \
		--arg author_association "$author_association" \
		--arg author_class "$author_class" \
		--argjson permitted "$permitted" \
		--arg reason "$reason" \
		--arg state "$state" \
		--arg merge_gate "$merge_gate" \
		--argjson exit_code "$rc" \
		'{schema:"aidevops.review-gate-evidence/v1",pr:$pr,repo:$repo,head_sha:$head_sha,status:$status,author:{login:$author_login,association:$author_association,class:$author_class},permitted:$permitted,reason:$reason,state:$state,merge_gate:$merge_gate,exit_code:$exit_code}'
	return 0
}

_classify_bot_state() {
	# t2139: Distinguish "placeholder/not-yet-settled" from "rate-limited"
	# vs "real-review". Returns one of:
	#   real-review         — bot has a real, settled review
	#   not-yet             — bot has comment(s) that are not non-review notices
	#                         but are still in the placeholder window (Phase 1)
	#   non-review-only     — every bot comment matched a NON_REVIEW_PATTERNS entry
	#                         (rate-limited, "Review failed", "Review skipped", etc.)
	#   no-comments         — bot has commented per get_all_bot_commenters but
	#                         no comments are visible via the typed endpoints
	#                         (rare race; treat as non-review-only)
	local pr_number="$1"
	local repo="$2"
	local bot_login="$3"

	local min_lag
	min_lag=$(_get_min_edit_lag "$repo" "$bot_login")

	local jq_filter
	jq_filter=".[] | select(.user.login | ascii_downcase | test(\"${bot_login}\")) | [(.created_at // .submitted_at // \"\"), (.updated_at // .submitted_at // .created_at // \"\"), (.body // \"\" | @base64)] | @tsv"

	local saw_any=0 saw_non_review=0 saw_placeholder=0
	local sources=(reviews issue-comments review-comments)
	local source records created_at updated_at encoded body
	for source in "${sources[@]}"; do
		records=$(_rbg_query_evidence_collection "$pr_number" "$repo" "$source" "$jq_filter" || echo "")
		[[ -z "$records" ]] && continue
		while IFS=$'\t' read -r created_at updated_at encoded; do
			[[ -z "$encoded" ]] && continue
			body=$(echo "$encoded" | base64 -d 2>/dev/null || echo "")
			[[ -z "$body" ]] && continue
			saw_any=1
			if is_non_review_comment "$body"; then
				saw_non_review=1
				continue
			fi
			# Pass bot_login so two-phase bots require edit-observed settlement
			# (GH#20550 — age alone is not sufficient for coderabbitai etc.).
			if _comment_is_settled "$created_at" "$updated_at" "$min_lag" "$bot_login"; then
				echo "real-review"
				return 0
			fi
			saw_placeholder=1
		done <<<"$records"
	done

	if [[ "$saw_placeholder" -eq 1 ]]; then
		echo "not-yet"
	elif [[ "$saw_non_review" -eq 1 ]]; then
		echo "non-review-only"
	elif [[ "$saw_any" -eq 0 ]]; then
		echo "no-comments"
	else
		echo "non-review-only"
	fi
	return 0
}
