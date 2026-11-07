#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Review Bot Gate -- Evidence Collection and CodeRabbit Reconciliation
# =============================================================================
# Evidence endpoint helpers, snapshot querying and stale CodeRabbit review reconciliation.
# Functions moved verbatim from review-bot-gate-helper.sh (GH#37011).
#
# Usage: source "${_RBG_SCRIPT_DIR}/review-bot-gate-evidence.sh"
#
# Dependencies: constants and sibling functions defined by review-bot-gate-helper.sh
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_RBG_EVIDENCE_LIB_LOADED:-}" ]] && return 0
_RBG_EVIDENCE_LIB_LOADED=1

_rbg_evidence_endpoint() {
	local pr_number="$1"
	local repo="$2"
	local source="$3"

	case "$source" in
	reviews) printf 'repos/%s/pulls/%s/reviews\n' "$repo" "$pr_number" ;;
	issue-comments) printf 'repos/%s/issues/%s/comments\n' "$repo" "$pr_number" ;;
	review-comments) printf 'repos/%s/pulls/%s/comments\n' "$repo" "$pr_number" ;;
	*) return 1 ;;
	esac
	return 0
}

_rbg_reset_evidence_snapshot() {
	_RBG_EVIDENCE_SNAPSHOT_KEY=""
	_RBG_EVIDENCE_REVIEWS_JSON="[]"
	_RBG_EVIDENCE_ISSUE_COMMENTS_JSON="[]"
	_RBG_EVIDENCE_REVIEW_COMMENTS_JSON="[]"
	_RBG_EVIDENCE_SNAPSHOT_READY=0
	return 0
}

_rbg_fetch_evidence_collection() {
	local pr_number="$1"
	local repo="$2"
	local source="$3"
	local endpoint=""
	local paginated_endpoint=""
	local records_json=""

	endpoint=$(_rbg_evidence_endpoint "$pr_number" "$repo" "$source") || return 1
	paginated_endpoint="${endpoint}?per_page=100"
	if ! records_json=$(gh api "$paginated_endpoint" --paginate | jq -sce \
		'[.[] | if type == "array" then .[] else error("review evidence page must be an array") end]'); then
		return 1
	fi
	printf '%s\n' "$records_json"
	return 0
}

_rbg_coderabbit_status_is_terminal_success() {
	local repo="$1"
	local head_sha="$2"
	local status_json=""

	status_json=$(gh api "repos/${repo}/commits/${head_sha}/status?per_page=100" 2>/dev/null) || return 1
	#aidevops:trust-boundary — accept only the exact CodeRabbit context on this immutable head.
	printf '%s\n' "$status_json" | jq -e \
		--arg context "$RBG_CODERABBIT_STATUS_CONTEXT" \
		--arg login "$RBG_CODERABBIT_LOGIN" '
		[.statuses[]? | select(((.context // "") | ascii_downcase) == $context)] as $matches
		| ($matches | length) > 0
		and all($matches[];
			((.state // "") | ascii_downcase) == "success"
			and (.creator == null or (
				(.creator.login // "") == $login
				and (.creator.type // "") == "Bot"
			))
		)
	' >/dev/null 2>&1 || return 1
	return 0
}

_rbg_exact_head_clean_coderabbit_evidence() {
	local pr_number="$1"
	local repo="$2"
	local head_sha="$3"
	local reviews_json="$4"
	local comments_json=""
	local latest_stale_at=""
	local completion_marker=""
	local evidence_id=""

	latest_stale_at=$(printf '%s\n' "$reviews_json" | jq -er '[.[].submitted_at | select(. != "")] | max // empty') || return 1
	comments_json=$(_rbg_fetch_evidence_collection "$pr_number" "$repo" issue-comments) || return 1
	completion_marker="Re-review of exact head \`${head_sha}\` complete — **no blocking findings**."
	#aidevops:trust-boundary — prose is evidence only from the exact GitHub bot identity with both deterministic markers.
	evidence_id=$(printf '%s\n' "$comments_json" | jq -er \
		--arg login "$RBG_CODERABBIT_LOGIN" \
		--arg addressed "$RBG_CODERABBIT_ADDRESSED_MARKER" \
		--arg completion "$completion_marker" \
		--arg after "$latest_stale_at" '
		[.[] | select(
			(.user.login // "") == $login
			and (.user.type // "") == "Bot"
			and (.created_at // "") > $after
			and ((.body // "") | contains($addressed))
			and ((.body // "") | contains($completion))
		) | .id] | first // empty
	') || return 1
	[[ -n "$evidence_id" ]] || return 1
	printf '%s\n' "$evidence_id"
	return 0
}

_rbg_dismiss_coderabbit_reviews() {
	local mode="$1"
	local pr_number="$2"
	local repo="$3"
	local head_sha="$4"
	local reviews_json="$5"
	local records=""
	local review_id=""
	local stale_sha=""
	local snapshot=""
	local snapshot_head=""
	local snapshot_state=""
	local message=""
	local pull_endpoint=""

	printf -v pull_endpoint 'repos/%s/pulls/%s' "$repo" "$pr_number"
	records=$(printf '%s\n' "$reviews_json" | jq -er '.[] | [(.id | tostring),.commit_id] | @tsv') || return 1
	while IFS=$'\t' read -r review_id stale_sha; do
		[[ "$review_id" =~ ^[0-9]+$ ]] || return 1
		snapshot=$(_rbg_pr_reconciliation_snapshot "$pr_number" "$repo") || return 1
		snapshot_head=$(printf '%s\n' "$snapshot" | jq -r '.head')
		snapshot_state=$(printf '%s\n' "$snapshot" | jq -r '.state | ascii_downcase')
		[[ "$snapshot_state" == "open" && "$snapshot_head" == "$head_sha" ]] || {
			printf 'ERROR: PR #%s head drifted before CodeRabbit review %s dismissal\n' "$pr_number" "$review_id" >&2
			return 1
		}
		if [[ "$mode" == "$RBG_RECONCILE_MODE_NITS" ]]; then
			message="Auto-dismissed: coderabbit-nits-ok label applied by maintainer (PR #${pr_number})"
		elif [[ "$mode" == "$RBG_RECONCILE_MODE_ADVISORY" ]]; then
			#aidevops:trust-boundary — revalidate authorization on the final pre-write snapshot.
			_rbg_advisory_author_trusted "$snapshot" || return 1
			message="Auto-dismissed advisory CodeRabbit review on trusted-author PR #${pr_number}; findings remain available to the post-merge scanner."
		else
			message="Auto-dismissed superseded CodeRabbit review ${review_id}: stale head ${stale_sha}; clean exact-head re-review confirmed at ${head_sha}."
		fi
		gh api -X PUT "${pull_endpoint}/reviews/${review_id}/dismissals" \
			-f message="$message" >/dev/null 2>&1 || return 1
		printf 'dismissed CodeRabbit review %s: stale head %s; current head %s\n' "$review_id" "${stale_sha:-unknown}" "$head_sha" >&2
	done <<<"$records"
	return 0
}

_rbg_advisory_author_trusted() {
	local snapshot="$1"
	local association=""
	association=$(printf '%s\n' "$snapshot" | jq -er '.association | ascii_upcase') || return 1
	case "$association" in OWNER | MEMBER | COLLABORATOR) ;; *) return 1 ;; esac
	printf '%s\n' "$snapshot" | jq -e '.labels_valid == true and all(.labels[]; . != "external-contributor")' >/dev/null 2>&1 || return 1
	return 0
}

do_reconcile_coderabbit_reviews() {
	local mode="$1"
	local pr_number="$2"
	local repo="$3"
	local expected_head="${4:-}"
	local snapshot=""
	local head_sha=""
	local state=""
	local association=""
	local reviews_json=""
	local fresh_reviews_json=""
	local review_count=0
	local post_json=""

	[[ "$mode" == "$RBG_RECONCILE_MODE_SUPERSEDED" || "$mode" == "$RBG_RECONCILE_MODE_NITS" \
		|| "$mode" == "$RBG_RECONCILE_MODE_ADVISORY" ]] || return 2
	snapshot=$(_rbg_pr_reconciliation_snapshot "$pr_number" "$repo") || return 1
	head_sha=$(printf '%s\n' "$snapshot" | jq -r '.head')
	state=$(printf '%s\n' "$snapshot" | jq -r '.state | ascii_downcase')
	[[ "$state" == "open" && "$head_sha" =~ ^[0-9a-fA-F]{40}$ ]] || return 1
	[[ -z "$expected_head" || "$expected_head" == "$head_sha" ]] || return 1
	if [[ "$mode" == "$RBG_RECONCILE_MODE_NITS" ]]; then
		#aidevops:trust-boundary — the cosmetic override is inert without its explicit maintainer label.
		printf '%s\n' "$snapshot" | jq -e --arg label "$RBG_CODERABBIT_NITS_LABEL" \
			'any(.labels[]?; . == $label)' >/dev/null 2>&1 || return 1
	fi
	if [[ "$mode" == "$RBG_RECONCILE_MODE_SUPERSEDED" ]]; then
		association=$(printf '%s\n' "$snapshot" | jq -r '.association | ascii_upcase')
		case "$association" in OWNER | MEMBER | COLLABORATOR) ;; *) return 1 ;; esac
	fi
	if [[ "$mode" == "$RBG_RECONCILE_MODE_ADVISORY" ]]; then
		#aidevops:trust-boundary — automatic reconciliation is restricted to trusted PR authors.
		_rbg_advisory_author_trusted "$snapshot" || return 1
	fi

	reviews_json=$(_rbg_changes_requested_reviews "$pr_number" "$repo") || return 1
	review_count=$(printf '%s\n' "$reviews_json" | jq 'length') || return 1
	if [[ "$review_count" -eq 0 ]]; then
		[[ "$mode" == "$RBG_RECONCILE_MODE_NITS" ]] && return 0
		return 1
	fi
	#aidevops:trust-boundary — never dismiss a human, lookalike, or malformed reviewer identity.
	printf '%s\n' "$reviews_json" | jq -e --arg login "$RBG_CODERABBIT_LOGIN" '
		all(.[]; (.id | type) == "number" and .login == $login and .user_type == "Bot")
	' >/dev/null 2>&1 || return 1

	if [[ "$mode" == "$RBG_RECONCILE_MODE_SUPERSEDED" ]]; then
		printf '%s\n' "$reviews_json" | jq -e --arg head "$head_sha" '
			all(.[]; (.commit_id | test("^[0-9a-fA-F]{40}$")) and .commit_id != $head and .submitted_at != "")
		' >/dev/null 2>&1 || return 1
		_rbg_exact_head_clean_coderabbit_evidence "$pr_number" "$repo" "$head_sha" "$reviews_json" >/dev/null || return 1
		_rbg_coderabbit_status_is_terminal_success "$repo" "$head_sha" || return 1
	fi

	fresh_reviews_json=$(_rbg_changes_requested_reviews "$pr_number" "$repo") || return 1
	[[ "$(printf '%s\n' "$reviews_json" | jq -cS .)" == "$(printf '%s\n' "$fresh_reviews_json" | jq -cS .)" ]] || return 1
	_rbg_dismiss_coderabbit_reviews "$mode" "$pr_number" "$repo" "$head_sha" "$reviews_json" || return 1
	post_json=$(gh pr view "$pr_number" --repo "$repo" --json headRefOid,reviewDecision 2>/dev/null) || return 1
	printf '%s\n' "$post_json" | jq -e --arg head "$head_sha" '
		(.headRefOid // "") == $head and has("reviewDecision")
		and (.reviewDecision == null or .reviewDecision == "" or .reviewDecision == "APPROVED" or .reviewDecision == "REVIEW_REQUIRED")
	' >/dev/null 2>&1 || return 1
	printf 'RECONCILED_CODERABBIT_REVIEW head=%s reviews=%s mode=%s\n' "$head_sha" "$review_count" "$mode"
	return 0
}

_rbg_prepare_evidence_snapshot() {
	local pr_number="$1"
	local repo="$2"
	local reviews_json=""
	local issue_comments_json=""
	local review_comments_json=""

	reviews_json=$(_rbg_fetch_evidence_collection "$pr_number" "$repo" reviews) || return $?
	issue_comments_json=$(_rbg_fetch_evidence_collection "$pr_number" "$repo" issue-comments) || return $?
	review_comments_json=$(_rbg_fetch_evidence_collection "$pr_number" "$repo" review-comments) || return $?

	_RBG_EVIDENCE_REVIEWS_JSON="$reviews_json"
	_RBG_EVIDENCE_ISSUE_COMMENTS_JSON="$issue_comments_json"
	_RBG_EVIDENCE_REVIEW_COMMENTS_JSON="$review_comments_json"
	_RBG_EVIDENCE_SNAPSHOT_KEY="${repo}#${pr_number}"
	_RBG_EVIDENCE_SNAPSHOT_READY=1
	return 0
}

_rbg_evidence_snapshot_matches() {
	local pr_number="$1"
	local repo="$2"
	if [[ "$_RBG_EVIDENCE_SNAPSHOT_READY" == "1" && "$_RBG_EVIDENCE_SNAPSHOT_KEY" == "${repo}#${pr_number}" ]]; then
		return 0
	fi
	return 1
}

_rbg_query_evidence_collection() {
	local pr_number="$1"
	local repo="$2"
	local source="$3"
	local jq_filter="$4"
	local records_json=""
	local endpoint=""

	if [[ "${REVIEW_GATE_EVIDENCE_SNAPSHOT_DISABLE:-0}" != "1" ]] &&
		_rbg_evidence_snapshot_matches "$pr_number" "$repo"; then
		case "$source" in
		reviews) records_json="$_RBG_EVIDENCE_REVIEWS_JSON" ;;
		issue-comments) records_json="$_RBG_EVIDENCE_ISSUE_COMMENTS_JSON" ;;
		review-comments) records_json="$_RBG_EVIDENCE_REVIEW_COMMENTS_JSON" ;;
		*) return 1 ;;
		esac
		printf '%s\n' "$records_json" | jq -r "$jq_filter"
		return $?
	fi

	endpoint=$(_rbg_evidence_endpoint "$pr_number" "$repo" "$source") || return 1
	gh api "$endpoint" --paginate --jq "$jq_filter"
	return $?
}
