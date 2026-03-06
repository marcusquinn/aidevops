#!/usr/bin/env bash
# review-bot-gate-helper.sh — Check if AI review bots have posted on a PR
#
# Usage:
#   review-bot-gate-helper.sh check <PR_NUMBER> [REPO]
#   review-bot-gate-helper.sh wait  <PR_NUMBER> [REPO] [MAX_WAIT_SECONDS]
#   review-bot-gate-helper.sh list  <PR_NUMBER> [REPO]
#
# Commands:
#   check  — Check once, return PASS/WAITING/SKIP
#   wait   — Poll until a bot posts or timeout (default 600s)
#   list   — List all bot comments found on the PR
#
# Exit codes:
#   0 — PASS (at least one bot reviewed) or SKIP (label present)
#   1 — WAITING (no bots found yet)
#   2 — Error (missing args, gh auth failure)
#
# Environment:
#   REVIEW_BOT_WAIT_MAX  — Max seconds to wait in 'wait' mode (default: 600)
#   REVIEW_BOT_POLL_INTERVAL — Seconds between polls (default: 60)
#
# t1382: https://github.com/marcusquinn/aidevops/issues/2735

set -euo pipefail

# Known review bot login patterns (lowercase, without [bot] suffix for matching)
KNOWN_BOTS=(
	"coderabbitai"
	"gemini-code-assist"
	"augment-code"
	"augmentcode"
	"copilot"
)

# Patterns that indicate a rate-limit or quota notice (not a real review).
# Case-insensitive grep patterns — one per line.
RATE_LIMIT_PATTERNS=(
	"rate limit exceeded"
	"rate limited by coderabbit"
	"daily quota limit"
	"reached your daily quota"
	"Please wait up to 24 hours"
	"has exceeded the limit for the number of"
)

SKIP_LABEL="skip-review-gate"

# --- Functions ---

usage() {
	echo "Usage: $(basename "$0") {check|wait|list} <PR_NUMBER> [REPO] [MAX_WAIT]"
	echo ""
	echo "Commands:"
	echo "  check  Check once for bot reviews (returns PASS/WAITING/SKIP)"
	echo "  wait   Poll until bot reviews appear or timeout"
	echo "  list   List all bot comments found"
	return 0
}

get_all_bot_commenters() {
	local pr_number="$1"
	local repo="$2"

	# Collect reviewers from three sources:
	# 1. PR reviews (formal GitHub reviews)
	local reviews
	reviews=$(gh api "repos/${repo}/pulls/${pr_number}/reviews" \
		--paginate --jq '.[].user.login' 2>/dev/null || echo "")

	# 2. Issue comments (some bots post as comments, not reviews)
	local comments
	comments=$(gh api "repos/${repo}/issues/${pr_number}/comments" \
		--paginate --jq '.[].user.login' 2>/dev/null || echo "")

	# 3. Review comments (inline code comments)
	local review_comments
	review_comments=$(gh api "repos/${repo}/pulls/${pr_number}/comments" \
		--paginate --jq '.[].user.login' 2>/dev/null || echo "")

	# Combine, deduplicate, lowercase
	echo -e "${reviews}\n${comments}\n${review_comments}" |
		tr '[:upper:]' '[:lower:]' | sort -u | grep -v '^$' || true
}

is_rate_limit_comment() {
	# Check if a comment body matches any known rate-limit/quota pattern.
	# Returns 0 if the comment IS a rate-limit notice (not a real review).
	local body="$1"

	for pattern in "${RATE_LIMIT_PATTERNS[@]}"; do
		if echo "$body" | grep -qi "$pattern"; then
			return 0
		fi
	done
	return 1
}

bot_has_real_review() {
	# Check if a bot has posted at least one comment that is NOT a rate-limit
	# notice. Checks all three comment sources (reviews, issue comments,
	# review comments). Returns 0 if a real review exists, 1 otherwise.
	local pr_number="$1"
	local repo="$2"
	local bot_login="$3"

	# Build a jq filter that selects comments by this bot (case-insensitive)
	# and base64-encodes each body so multi-line content stays on one line.
	local jq_filter
	jq_filter=".[] | select(.user.login | ascii_downcase | test(\"${bot_login}\")) | .body | @base64"

	local api_endpoints=(
		"repos/${repo}/pulls/${pr_number}/reviews"
		"repos/${repo}/issues/${pr_number}/comments"
		"repos/${repo}/pulls/${pr_number}/comments"
	)

	local endpoint encoded_bodies body
	for endpoint in "${api_endpoints[@]}"; do
		encoded_bodies=$(gh api "$endpoint" --paginate --jq "$jq_filter" 2>/dev/null || echo "")
		if [[ -n "$encoded_bodies" ]]; then
			while IFS= read -r encoded; do
				[[ -z "$encoded" ]] && continue
				body=$(echo "$encoded" | base64 -d 2>/dev/null || echo "")
				[[ -z "$body" ]] && continue
				if ! is_rate_limit_comment "$body"; then
					return 0
				fi
			done <<<"$encoded_bodies"
		fi
	done

	# All comments from this bot were rate-limit notices (or empty)
	return 1
}

check_for_skip_label() {
	local pr_number="$1"
	local repo="$2"

	local labels
	labels=$(gh pr view "$pr_number" --repo "$repo" \
		--json labels -q '.labels[].name' 2>/dev/null || echo "")

	if echo "$labels" | grep -q "$SKIP_LABEL"; then
		return 0
	fi
	return 1
}

match_known_bots() {
	local all_commenters="$1"
	local found_bots=""
	local missing_bots=""

	for bot in "${KNOWN_BOTS[@]}"; do
		if echo "$all_commenters" | grep -qi "$bot"; then
			found_bots="${found_bots}${bot} "
		else
			missing_bots="${missing_bots}${bot} "
		fi
	done

	echo "found:${found_bots}"
	echo "missing:${missing_bots}"
}

do_check() {
	local pr_number="$1"
	local repo="$2"

	# Check skip label first
	if check_for_skip_label "$pr_number" "$repo"; then
		echo "SKIP"
		return 0
	fi

	local all_commenters
	all_commenters=$(get_all_bot_commenters "$pr_number" "$repo")

	local found_bots=""
	local rate_limited_bots=""
	for bot in "${KNOWN_BOTS[@]}"; do
		if echo "$all_commenters" | grep -qi "$bot"; then
			# Bot commented — but is it a real review or a rate-limit notice?
			if bot_has_real_review "$pr_number" "$repo" "$bot"; then
				found_bots="${found_bots}${bot} "
			else
				rate_limited_bots="${rate_limited_bots}${bot} "
				echo "rate-limited (not a real review): ${bot}" >&2
			fi
		fi
	done

	if [[ -n "$found_bots" ]]; then
		echo "PASS"
		echo "found: ${found_bots}" >&2
		return 0
	elif [[ -n "$rate_limited_bots" ]]; then
		echo "WAITING"
		echo "Bots posted rate-limit notices only (not real reviews): ${rate_limited_bots}" >&2
		return 1
	else
		echo "WAITING"
		echo "No review bots found yet. Known bots: ${KNOWN_BOTS[*]}" >&2
		return 1
	fi
}

do_wait() {
	local pr_number="$1"
	local repo="$2"
	local max_wait="${3:-${REVIEW_BOT_WAIT_MAX:-600}}"
	local poll_interval="${REVIEW_BOT_POLL_INTERVAL:-60}"
	local elapsed=0

	echo "Waiting up to ${max_wait}s for review bots on PR #${pr_number}..." >&2

	while [[ "$elapsed" -lt "$max_wait" ]]; do
		local result
		result=$(do_check "$pr_number" "$repo" 2>/dev/null) || true

		if [[ "$result" == "PASS" || "$result" == "SKIP" ]]; then
			echo "$result"
			return 0
		fi

		echo "[${elapsed}s/${max_wait}s] Still waiting for review bots..." >&2
		sleep "$poll_interval"
		elapsed=$((elapsed + poll_interval))
	done

	echo "WAITING"
	echo "Timeout after ${max_wait}s — no review bots posted." >&2
	return 1
}

do_list() {
	local pr_number="$1"
	local repo="$2"

	local all_commenters
	all_commenters=$(get_all_bot_commenters "$pr_number" "$repo")

	echo "All commenters on PR #${pr_number}:"
	echo "$all_commenters" | sed 's/^/  /'
	echo ""

	local result
	result=$(match_known_bots "$all_commenters")
	echo "$result"
	echo ""

	# Show rate-limit status for each found bot
	for bot in "${KNOWN_BOTS[@]}"; do
		if echo "$all_commenters" | grep -qi "$bot"; then
			if bot_has_real_review "$pr_number" "$repo" "$bot"; then
				echo "  ${bot}: real review"
			else
				echo "  ${bot}: rate-limited (no real review)"
			fi
		fi
	done
	return 0
}

# --- Main ---

main() {
	local command="${1:-}"
	local pr_number="${2:-}"
	local repo="${3:-}"
	local max_wait="${4:-}"

	if [[ -z "$command" || -z "$pr_number" ]]; then
		usage
		return 2
	fi

	# Default repo from current git context
	if [[ -z "$repo" ]]; then
		repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
		if [[ -z "$repo" ]]; then
			echo "ERROR: Could not determine repo. Pass REPO as third argument." >&2
			return 2
		fi
	fi

	case "$command" in
	check)
		do_check "$pr_number" "$repo"
		;;
	wait)
		do_wait "$pr_number" "$repo" "$max_wait"
		;;
	list)
		do_list "$pr_number" "$repo"
		;;
	-h | --help | help)
		usage
		;;
	*)
		echo "ERROR: Unknown command '$command'" >&2
		usage
		return 2
		;;
	esac
}

main "$@"
