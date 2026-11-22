#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Headless Runtime Failure - Rate-Limit Release Circuit (GH#35101)
# =============================================================================
# Per-issue transient rate-limit release circuit breaker, split from
# headless-runtime-failure.sh to keep that file under the 2000-line gate.
#
# Usage: sourced by headless-runtime-failure.sh (do not execute directly).
#
# Dependencies: shared-constants.sh (print_warning, print_info), gh CLI, jq,
#   bash 3.2+
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_HEADLESS_RUNTIME_FAILURE_RATELIMIT_LOADED:-}" ]] && return 0
readonly _HEADLESS_RUNTIME_FAILURE_RATELIMIT_LOADED=1

# Per-issue transient rate-limit release circuit breaker (t3570 / GH#23102).
# These defaults intentionally keep the first transient failures visible while
# suppressing repeated CLAIM_RELEASED storms during provider capacity outages.
: "${AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_THRESHOLD:=3}"
: "${AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_LOOKBACK_SECS:=86400}"
: "${AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_COOLDOWN_SECS:=1800}"

#######################################
# Convert an epoch to a UTC-ish human timestamp for audit comments.
#
# Args:
#   $1 = epoch seconds
#######################################
_hrff_epoch_to_utc() {
	local epoch="$1"
	date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
		date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
		printf 'epoch:%s' "$epoch"
	return 0
}

#######################################
# Return recent issue comments needed by the rate-limit release breaker.
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
#######################################
_hrff_rate_limit_release_comments_json() {
	local issue_number="$1"
	local repo_slug="$2"

	gh api "repos/${repo_slug}/issues/${issue_number}/comments?per_page=100" \
		--jq '[.[] | {created_at: .created_at, body: (.body // "")}]' 2>/dev/null || return 1
	return 0
}

#######################################
# Check whether the transient rate-limit release breaker is currently active.
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
#   $3 = now_epoch
#   $4 = comments_json
# Returns: 0 active, 1 inactive.
#######################################
_hrff_rate_limit_release_circuit_active() {
	local issue_number="$1"
	local repo_slug="$2"
	local now_epoch="$3"
	local comments_json="$4"

	if [[ "${AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_OVERRIDE:-0}" == "1" ]]; then
		return 1
	fi

	local latest_override=""
	latest_override=$(printf '%s' "$comments_json" | jq -r \
		'[.[] | select((.body // "") | test("rate-limit-release-circuit-breaker:override")) | .created_at] | max // ""' \
		2>/dev/null) || latest_override=""

	local marker_line=""
	marker_line=$(printf '%s' "$comments_json" | jq -r \
		'[.[] | select((.body // "") | contains("rate-limit-release-circuit-breaker")) | .body] | last // ""' \
		2>/dev/null | grep -oE '<!-- rate-limit-release-circuit-breaker[^>]*-->' | tail -1) || marker_line=""

	[[ -n "$marker_line" ]] || return 1

	local next_epoch=""
	next_epoch=$(printf '%s' "$marker_line" | grep -oE 'next_epoch=[0-9]+' | cut -d= -f2 || true)
	[[ "$next_epoch" =~ ^[0-9]+$ ]] || return 1

	if [[ -n "$latest_override" ]]; then
		local marker_created=""
		marker_created=$(printf '%s' "$comments_json" | jq -r --arg marker "$marker_line" \
			'[.[] | select((.body // "") | contains($marker)) | .created_at] | last // ""' \
			2>/dev/null) || marker_created=""
		if [[ -n "$marker_created" && "$latest_override" > "$marker_created" ]]; then
			return 1
		fi
	fi

	if [[ "$now_epoch" -lt "$next_epoch" ]]; then
		print_info "Transient rate-limit release circuit active for #${issue_number} (${repo_slug}); suppressing duplicate CLAIM_RELEASED until $(_hrff_epoch_to_utc "$next_epoch")"
		return 0
	fi

	return 1
}

#######################################
# Count recent transient rate-limit release comments for an issue.
#
# Args:
#   $1 = comments_json
#   $2 = since_epoch
#######################################
_hrff_count_recent_rate_limit_releases() {
	local comments_json="$1"
	local since_epoch="$2"

	printf '%s' "$comments_json" | jq -r --argjson since "$since_epoch" '
		[.[]
		 | select((.body // "") | contains("CLAIM_RELEASED reason=rate_limit_transient"))
		 | select(((.created_at // "1970-01-01T00:00:00Z") | fromdateiso8601? // 0) >= $since)
		] | length' 2>/dev/null || printf '0'
	return 0
}

#######################################
# Post one consolidated audit comment once the threshold is crossed.
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
#   $3 = count_after_increment
#   $4 = next_epoch
#######################################
_hrff_post_rate_limit_release_circuit_comment() {
	local issue_number="$1"
	local repo_slug="$2"
	local count_after_increment="$3"
	local next_epoch="$4"

	local next_human=""
	next_human=$(_hrff_epoch_to_utc "$next_epoch")
	local cooldown_secs="$AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_COOLDOWN_SECS"
	local body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
<!-- rate-limit-release-circuit-breaker issue=${issue_number} count=${count_after_increment} next_epoch=${next_epoch} -->
RATE_LIMIT_RELEASE_CIRCUIT active=true count=${count_after_increment} cooldown=${cooldown_secs}s next=${next_human}

Repeated transient provider rate-limit releases for this issue reached the circuit-breaker threshold. Further duplicate \`CLAIM_RELEASED reason=rate_limit_transient\` audit comments are suppressed until ${next_human} to reduce comment storms and wasted dispatch cycles.

Dispatch resumes after the cooldown expires. Maintainers can override early by posting a comment containing \`rate-limit-release-circuit-breaker:override\`.
<!-- ops:end -->"

	gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--method POST \
		--field body="$body" \
		>/dev/null 2>&1 || print_warning "Failed to post rate-limit release circuit comment on #${issue_number} (non-fatal)"
	return 0
}

#######################################
# Evaluate the transient rate-limit release breaker before posting a release.
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
# Returns: 0 post normal release, 1 suppress duplicate release comment.
#######################################
_hrff_handle_rate_limit_release_circuit() {
	local issue_number="$1"
	local repo_slug="$2"

	local now_epoch=""
	now_epoch=$(date +%s 2>/dev/null) || now_epoch=0
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=0

	local comments_json=""
	comments_json=$(_hrff_rate_limit_release_comments_json "$issue_number" "$repo_slug") || comments_json=""
	[[ -n "$comments_json" ]] || return 0

	if _hrff_rate_limit_release_circuit_active "$issue_number" "$repo_slug" "$now_epoch" "$comments_json"; then
		return 1
	fi

	local threshold="$AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_THRESHOLD"
	local lookback="$AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_LOOKBACK_SECS"
	local cooldown="$AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_COOLDOWN_SECS"
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=3
	[[ "$lookback" =~ ^[0-9]+$ ]] || lookback=86400
	[[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=1800
	[[ "$threshold" -gt 0 ]] || return 0

	local since_epoch=$(( now_epoch - lookback ))
	[[ "$since_epoch" -lt 0 ]] && since_epoch=0
	local previous_count=""
	previous_count=$(_hrff_count_recent_rate_limit_releases "$comments_json" "$since_epoch") || previous_count=0
	[[ "$previous_count" =~ ^[0-9]+$ ]] || previous_count=0
	local count_after_increment=$(( previous_count + 1 ))

	if [[ "$count_after_increment" -ge "$threshold" ]]; then
		local next_epoch=$(( now_epoch + cooldown ))
		_hrff_post_rate_limit_release_circuit_comment "$issue_number" "$repo_slug" "$count_after_increment" "$next_epoch"
	fi

	return 0
}
