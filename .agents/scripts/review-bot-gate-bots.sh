#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Review Bot Gate -- Bot Comment and Status Classification
# =============================================================================
# Rate-limit/non-review notice classification, real-review detection and success-status contexts.
# Functions moved verbatim from review-bot-gate-helper.sh (GH#37011).
#
# Usage: source "${_RBG_SCRIPT_DIR}/review-bot-gate-bots.sh"
#
# Dependencies: constants and sibling functions defined by review-bot-gate-helper.sh
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_RBG_BOTS_LIB_LOADED:-}" ]] && return 0
_RBG_BOTS_LIB_LOADED=1

# t2799: Check if a comment body matches a rate-limit-specific pattern only
# (not the broader non-review set). Use when the caller cares specifically
# about capacity-constrained bots that may retry later.
is_rate_limit_only_comment() {
	local body="$1"

	for pattern in "${RATE_LIMIT_PATTERNS[@]}"; do
		if grep -qi "$pattern" <<<"$body"; then
			return 0
		fi
	done
	return 1
}

bot_body_base64_jq_filter() {
	local bot_login="$1"

	printf '%s%s%s\n' \
		'.[] | select(.user.login | ascii_downcase | test("' \
		"$bot_login" \
		'")) | (.body // "" | @base64)'
	return 0
}

bot_has_rate_limit_notice() {
	# Return success only when the bot posted a true rate-limit/quota notice.
	# Broader non-review states ("Review failed", "Review skipped", closed
	# during review) must keep blocking instead of entering PASS_RATE_LIMITED.
	local pr_number="$1"
	local repo="$2"
	local bot_login="$3"

	local jq_filter
	jq_filter=$(bot_body_base64_jq_filter "$bot_login")

	local sources=(reviews issue-comments review-comments)
	local source records encoded body
	for source in "${sources[@]}"; do
		records=$(_rbg_query_evidence_collection "$pr_number" "$repo" "$source" "$jq_filter" || echo "")
		[[ -z "$records" ]] && continue
		while IFS= read -r encoded; do
			[[ -z "$encoded" ]] && continue
			body=$(echo "$encoded" | base64 -d 2>/dev/null || echo "")
			[[ -z "$body" ]] && continue
			if is_rate_limit_only_comment "$body"; then
				return 0
			fi
		done <<<"$records"
	done
	return 1
}

bot_has_non_rate_limit_non_review_notice() {
	# Return success when the bot posted a known non-review notice that is not a
	# true rate-limit/quota notice. This takes precedence over older rate-limit
	# notices from the same bot so failed/skipped states keep blocking.
	local pr_number="$1"
	local repo="$2"
	local bot_login="$3"

	local jq_filter
	jq_filter=$(bot_body_base64_jq_filter "$bot_login")

	local sources=(reviews issue-comments review-comments)
	local source records encoded body
	for source in "${sources[@]}"; do
		records=$(_rbg_query_evidence_collection "$pr_number" "$repo" "$source" "$jq_filter" || echo "")
		[[ -z "$records" ]] && continue
		while IFS= read -r encoded; do
			[[ -z "$encoded" ]] && continue
			body=$(echo "$encoded" | base64 -d 2>/dev/null || echo "")
			[[ -z "$body" ]] && continue
			if is_non_review_comment "$body" && ! is_rate_limit_only_comment "$body"; then
				return 0
			fi
		done <<<"$records"
	done
	return 1
}

bot_get_notice_category() {
	# Classify a bot's non-review notice state in one pass over the three GitHub
	# comment sources. Non-rate-limit notices take precedence over rate-limit
	# notices from the same bot, even when an older rate-limit notice appears
	# first in another stream.
	local pr_number="$1"
	local repo="$2"
	local bot_login="$3"

	local jq_filter
	jq_filter=$(bot_body_base64_jq_filter "$bot_login")

	local category="none"
	local sources=(reviews issue-comments review-comments)
	local source records rc encoded body
	for source in "${sources[@]}"; do
		if records=$(_rbg_query_evidence_collection "$pr_number" "$repo" "$source" "$jq_filter"); then
			:
		else
			rc=$?
			return "$rc"
		fi
		[[ -z "$records" ]] && continue
		while IFS= read -r encoded; do
			[[ -z "$encoded" ]] && continue
			body=$(echo "$encoded" | base64 -d 2>/dev/null || echo "")
			[[ -z "$body" ]] && continue
			if is_non_review_comment "$body" && ! is_rate_limit_only_comment "$body"; then
				echo "non-rate-limit"
				return 0
			fi
			if is_rate_limit_only_comment "$body"; then
				category="rate-limit"
			fi
		done <<<"$records"
	done

	echo "$category"
	return 0
}

bot_has_real_review() {
	# t2139 (GH#19251): Check if a bot has posted at least one comment that
	# is BOTH (a) not a known non-review notice AND (b) "settled" — meaning
	# the comment has been edited (updated_at > created_at + min_lag) or is
	# old enough that the bot would have edited by now (now - created_at >=
	# min_lag). The age check is critical to defeat CodeRabbit's two-phase
	# posting pattern, where Phase 1 is a placeholder posted at ~14s and
	# Phase 2 is the edited final review at ~90-120s.
	#
	# Checks all three comment sources (reviews, issue comments, review
	# comments). Returns 0 if a real, settled review exists, 1 otherwise.
	local pr_number="$1"
	local repo="$2"
	local bot_login="$3"
	local success_status_contexts="${4-}"
	local success_status_contexts_prepared="${5:-false}"
	local expected_head_sha="${REVIEW_GATE_EXPECTED_HEAD_SHA:-}"
	local has_success_status_contexts="$RBG_FALSE"
	[[ $# -ge 4 ]] && has_success_status_contexts="$RBG_TRUE"

	local min_lag
	# repo here is "owner/name" — same shape as repos.json slug.
	min_lag=$(_get_min_edit_lag "$repo" "$bot_login")

	# Build a jq filter that selects comments by this bot (case-insensitive)
	# and emits a TSV record of created_at \t updated_at \t base64(body).
	# Reviews lack updated_at on some endpoints; default to created_at via //.
	local jq_filter
	jq_filter=".[] | select(.user.login | ascii_downcase | test(\"${bot_login}\"))"
	if [[ -n "$expected_head_sha" ]]; then
		# Typed merge evidence must identify the reviewed commit. Conversation
		# comments have no commit_id and therefore cannot prove current-head review.
		jq_filter="${jq_filter} | select((.commit_id // .original_commit_id // \"\") == \"${expected_head_sha}\")"
	fi
	jq_filter="${jq_filter} | [(.created_at // .submitted_at // \"\"), (.updated_at // .submitted_at // .created_at // \"\"), (.body // \"\" | @base64)] | @tsv"

	local sources=(reviews issue-comments review-comments)
	local source records created_at updated_at encoded body
	for source in "${sources[@]}"; do
		records=$(_rbg_query_evidence_collection "$pr_number" "$repo" "$source" "$jq_filter" || echo "")
		[[ -z "$records" ]] && continue
		while IFS=$'\t' read -r created_at updated_at encoded; do
			[[ -z "$encoded" ]] && continue
			body=$(echo "$encoded" | base64 -d 2>/dev/null || echo "")
			[[ -z "$body" ]] && continue
			# Phase 1: must not be a known non-review notice.
			if is_non_review_comment "$body"; then
				continue
			fi
			# Phase 2: must be settled. If not, this is likely a placeholder
			# (e.g., CodeRabbit Phase 1) — wait for it to settle before
			# classifying as a real review. Pass bot_login so two-phase bots
			# require edit-observed settlement (GH#20550).
			if ! _comment_is_settled "$created_at" "$updated_at" "$min_lag" "$bot_login"; then
				continue
			fi
			# GH#23066: Strict completion is an opt-in local/repo preference.
			# #aidevops:trust-boundary — a two-phase bot's edited comment is not
			# trusted as terminal completion unless the bot's own status/check has
			# reached success. Default fast mode intentionally preserves throughput.
			if _requires_success_status_completion "$repo" "$bot_login"; then
				if [[ "$has_success_status_contexts" == "$RBG_TRUE" ]]; then
					bot_has_success_status "$pr_number" "$repo" "$bot_login" "$success_status_contexts" "$success_status_contexts_prepared" || {
						echo "Strict completion: ${bot_login} settled comment lacks SUCCESS status/check" >&2
						continue
					}
				else
					bot_has_success_status "$pr_number" "$repo" "$bot_login" || {
						echo "Strict completion: ${bot_login} settled comment lacks SUCCESS status/check" >&2
						continue
					}
				fi
			fi
			return 0
		done <<<"$records"
	done

	# No comment from this bot passed both filters.
	return 1
}

_prepare_success_status_contexts() {
	# Normalize once for callers that match multiple bots against the same
	# status payload. Input shape: first line head SHA, remaining lines contexts.
	local status_contexts="$1"

	if [[ -z "$status_contexts" ]]; then
		return 1
	fi

	local head_sha statuses statuses_lower
	head_sha=$(printf '%s\n' "$status_contexts" | sed -n '1p')
	statuses=$(printf '%s\n' "$status_contexts" | sed '1d')
	if [[ -z "$head_sha" || -z "$statuses" ]]; then
		return 1
	fi

	statuses_lower=$(printf '%s\n' "$statuses" | tr '[:upper:]' '[:lower:]')
	printf '%s\n%s\n' "$head_sha" "$statuses_lower"
	return 0
}

_get_success_status_contexts() {
	# GH#3005: When bots are rate-limited in comments but still post a formal
	# GitHub status check, treat the PR as reviewed.
	# GH#3007: The status context name may differ from the bot login.
	local pr_number="$1"
	local repo="$2"

	# status-json already resolves and later revalidates the expected head. Reuse
	# that typed value instead of spending another GraphQL request on the same SHA.
	local head_sha="${REVIEW_GATE_EXPECTED_HEAD_SHA:-}"
	if [[ -z "$head_sha" ]]; then
		head_sha=$(gh pr view "$pr_number" --repo "$repo" \
			--json headRefOid -q '.headRefOid' 2>/dev/null || echo "")
	fi
	if [[ -z "$head_sha" ]]; then
		# GH#4361: GraphQL rate-limited — fall back to REST API.
		head_sha=$(gh api "repos/${repo}/pulls/${pr_number}" \
			--jq '.head.sha' 2>/dev/null || echo "")
	fi
	if [[ -z "$head_sha" ]]; then
		return 1
	fi

	# Get the combined status (singular endpoint = latest per-context state)
	# and check-runs unconditionally, then merge both streams.
	# GH#3007: /status (singular) returns the latest state per context,
	# avoiding stale-success matches from /statuses (plural, full history).
	# Pagination ensures we don't miss contexts when >30 statuses exist.
	local statuses check_runs
	statuses=$(gh api "repos/${repo}/commits/${head_sha}/status?per_page=100" \
		--paginate --jq '.statuses[] | select(.state == "success") | .context' ||
		echo "")
	check_runs=$(gh api "repos/${repo}/commits/${head_sha}/check-runs?per_page=100" \
		--paginate --jq '.check_runs[] | select(.conclusion == "success") | .name' ||
		echo "")
	statuses=$(printf '%s\n%s\n' "$statuses" "$check_runs" | grep -v '^$' || true)

	if [[ -z "$statuses" ]]; then
		return 1
	fi

	printf '%s\n' "${head_sha}" "$statuses"
	return 0
}

_status_contexts_match_bot() {
	# GH#3007: Match bidirectionally — the status context may be a prefix
	# of the bot login (e.g., "coderabbit" vs "coderabbitai") or vice versa.
	# Input shape: first line is head SHA, remaining lines are success contexts.
	local bot_login="$1"
	local status_contexts="$2"
	local contexts_are_prepared="${3:-false}"

	if [[ -z "$status_contexts" ]]; then
		return 1
	fi
	if [[ "$contexts_are_prepared" != "$RBG_TRUE" ]]; then
		status_contexts=$(_prepare_success_status_contexts "$status_contexts") || return 1
	fi

	local head_sha statuses
	head_sha=$(printf '%s\n' "$status_contexts" | sed -n '1p')
	statuses=$(printf '%s\n' "$status_contexts" | sed '1d')
	if [[ -z "$head_sha" || -z "$statuses" ]]; then
		return 1
	fi

	local bot_base ctx
	bot_base=$(printf '%s\n' "$bot_login" | tr '[:upper:]' '[:lower:]')
	while IFS= read -r ctx; do
		[[ -z "$ctx" ]] && continue
		# Bidirectional prefix match: either string starts with the other
		if [[ "$bot_base" == "$ctx"* ]] || [[ "$ctx" == "$bot_base"* ]]; then
			echo "Bot '${bot_login}' has SUCCESS status check on commit ${head_sha:0:8} (context: '${ctx}')" >&2
			return 0
		fi
	done <<<"$statuses"
	return 1
}

bot_has_success_status() {
	local pr_number="$1"
	local repo="$2"
	local bot_login="$3"
	local status_contexts="${4-}"
	local contexts_are_prepared="${5:-false}"

	if [[ $# -lt 4 ]]; then
		status_contexts=$(_get_success_status_contexts "$pr_number" "$repo") || return 1
		contexts_are_prepared="$RBG_FALSE"
	fi
	[[ -z "$status_contexts" ]] && return 1
	_status_contexts_match_bot "$bot_login" "$status_contexts" "$contexts_are_prepared" && return 0
	return 1
}

any_bot_has_success_status() {
	local pr_number="$1"
	local repo="$2"
	local status_contexts="${3-}"
	local contexts_are_prepared="${4:-false}"

	if [[ $# -lt 3 ]]; then
		status_contexts=$(_get_success_status_contexts "$pr_number" "$repo") || return 1
		contexts_are_prepared="$RBG_FALSE"
	fi
	[[ -z "$status_contexts" ]] && return 1

	local prepared_contexts
	if [[ "$contexts_are_prepared" == "$RBG_TRUE" ]]; then
		prepared_contexts="$status_contexts"
	else
		prepared_contexts=$(_prepare_success_status_contexts "$status_contexts") || return 1
	fi

	local bot
	for bot in "${KNOWN_BOTS[@]}"; do
		if _status_contexts_match_bot "$bot" "$prepared_contexts" true; then
			return 0
		fi
	done
	return 1
}
