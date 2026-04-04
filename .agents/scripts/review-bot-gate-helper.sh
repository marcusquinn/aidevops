#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# review-bot-gate-helper.sh — Check if AI review bots have posted on a PR
#
# Usage:
#   review-bot-gate-helper.sh check         <PR_NUMBER> [REPO]
#   review-bot-gate-helper.sh wait          <PR_NUMBER> [REPO] [MAX_WAIT_SECONDS]
#   review-bot-gate-helper.sh list          <PR_NUMBER> [REPO]
#   review-bot-gate-helper.sh request-retry <PR_NUMBER> [REPO]
#   review-bot-gate-helper.sh batch-retry   [REPO]
#
# Commands:
#   check          — Check once, return PASS/PASS_RATE_LIMITED/WAITING/SKIP
#   wait           — Poll until a bot posts or timeout (default 600s)
#   list           — List all bot comments found on the PR
#   request-retry  — If bots were rate-limited and no real review exists,
#                     request a review retry (idempotent, safe to call every pulse)
#   batch-retry    — Process all open PRs with 0 formal reviews, request retries
#                     for rate-limited ones. Staggers requests to avoid re-triggering
#                     rate limits. (GH#3932)
#
# Output values for check/wait:
#   PASS              — At least one bot posted a real review
#   PASS_RATE_LIMITED  — Bots are rate-limited but grace period exceeded (GH#3827)
#   WAITING           — No real reviews yet, still within grace period
#   SKIP              — PR has skip-review-gate label
#
# Exit codes:
#   0 — PASS/SKIP/REQUESTED/ALREADY_REQUESTED/NO_ACTION
#   1 — WAITING (no bots found yet)
#   2 — Error (missing args, gh auth failure)
#
# Environment:
#   REVIEW_BOT_WAIT_MAX  — Max seconds to wait in 'wait' mode (default: 600)
#   REVIEW_BOT_POLL_INTERVAL — Seconds between polls (default: 60)
#   RATE_LIMIT_GRACE_SECONDS — How long to wait before passing rate-limited PRs
#                              (default: 14400 = 4 hours). Set to 0 to disable.
#
# t1382: https://github.com/marcusquinn/aidevops/issues/2735
# GH#3827: Rate-limit grace period — pass gate after timeout when bots are
#          rate-limited, preventing indefinite PR blockage.

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

# GH#3827: Grace period for rate-limited bots. If bots posted rate-limit
# notices (proving they're configured) but the PR has been open longer than
# this threshold, pass the gate with a warning. Default: 4 hours (14400s).
# Set RATE_LIMIT_GRACE_SECONDS=0 to disable (block indefinitely).
RATE_LIMIT_GRACE_SECONDS="${RATE_LIMIT_GRACE_SECONDS:-14400}"

# --- Functions ---

usage() {
	echo "Usage: $(basename "$0") {check|wait|list|request-retry|batch-retry} <PR_NUMBER> [REPO] [MAX_WAIT]"
	echo ""
	echo "Commands:"
	echo "  check          Check once for bot reviews (returns PASS/PASS_RATE_LIMITED/WAITING/SKIP)"
	echo "  wait           Poll until bot reviews appear or timeout"
	echo "  list           List all bot comments found"
	echo "  request-retry  Request review retry if bots were rate-limited (idempotent)"
	echo "  batch-retry    Process all open PRs with 0 reviews, request retries (GH#3932)"
	return 0
}

get_pr_age_seconds() {
	# Return the age of a PR in seconds since creation.
	# Falls back to 0 if the creation time cannot be determined.
	# GH#4361: GraphQL (gh pr view --json) may be rate-limited independently
	# of the REST API. Try GraphQL first; fall back to REST on empty result.
	local pr_number="$1"
	local repo="$2"

	local created_at
	created_at=$(gh pr view "$pr_number" --repo "$repo" \
		--json createdAt -q '.createdAt' 2>/dev/null || echo "")
	if [[ -z "$created_at" ]]; then
		# GH#4361: GraphQL rate-limited — fall back to REST API which has a
		# separate rate limit and is typically available when GraphQL is exhausted.
		created_at=$(gh api "repos/${repo}/pulls/${pr_number}" \
			--jq '.created_at' 2>/dev/null || echo "")
	fi
	if [[ -z "$created_at" ]]; then
		echo "0"
		return 0
	fi

	local created_epoch now_epoch
	# macOS date vs GNU date
	created_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null ||
		date -d "$created_at" +%s 2>/dev/null ||
		echo "0")
	now_epoch=$(date +%s)
	echo $((now_epoch - created_epoch))
	return 0
}

get_all_bot_commenters() {
	local pr_number="$1"
	local repo="$2"

	# Collect reviewers from three sources:
	# 1. PR reviews (formal GitHub reviews)
	local reviews
	reviews=$(gh api "repos/${repo}/pulls/${pr_number}/reviews" \
		--paginate --jq '.[].user.login' || echo "")

	# 2. Issue comments (some bots post as comments, not reviews)
	local comments
	comments=$(gh api "repos/${repo}/issues/${pr_number}/comments" \
		--paginate --jq '.[].user.login' || echo "")

	# 3. Review comments (inline code comments)
	local review_comments
	review_comments=$(gh api "repos/${repo}/pulls/${pr_number}/comments" \
		--paginate --jq '.[].user.login' || echo "")

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
		encoded_bodies=$(gh api "$endpoint" --paginate --jq "$jq_filter" || echo "")
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

any_bot_has_success_status() {
	# GH#3005: When bots are rate-limited in comments but still post a formal
	# GitHub status check, treat the PR as reviewed.
	# GH#3007: The status context name may differ from the bot login.
	# E.g., bot login "coderabbitai" but status context "CodeRabbit".
	# Match bidirectionally: bot_base starts with context OR context
	# starts with bot_base (case-insensitive).
	local pr_number="$1"
	local repo="$2"

	local head_sha
	head_sha=$(gh pr view "$pr_number" --repo "$repo" \
		--json headRefOid -q '.headRefOid' 2>/dev/null || echo "")
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

	local statuses_lower
	statuses_lower=$(echo "$statuses" | tr '[:upper:]' '[:lower:]')

	# GH#3007: Match bidirectionally — the status context may be a prefix
	# of the bot login (e.g., "coderabbit" vs "coderabbitai") or vice versa.
	local bot bot_base ctx
	for bot in "${KNOWN_BOTS[@]}"; do
		bot_base=$(echo "$bot" | tr '[:upper:]' '[:lower:]')
		while IFS= read -r ctx; do
			[[ -z "$ctx" ]] && continue
			# Bidirectional prefix match: either string starts with the other
			if [[ "$bot_base" == "$ctx"* ]] || [[ "$ctx" == "$bot_base"* ]]; then
				echo "Bot '${bot}' has SUCCESS status check on commit ${head_sha:0:8} (context: '${ctx}')" >&2
				return 0
			fi
		done <<<"$statuses_lower"
	done
	return 1
}

check_for_skip_label() {
	local pr_number="$1"
	local repo="$2"

	local labels
	labels=$(gh pr view "$pr_number" --repo "$repo" \
		--json labels -q '.labels[].name' || echo "")

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
	elif [[ -n "$rate_limited_bots" ]] && any_bot_has_success_status "$pr_number" "$repo"; then
		# GH#3005: All bots are rate-limited in comments, but at least one
		# posted a SUCCESS commit status check. Treat as reviewed.
		echo "PASS"
		echo "Status check fallback: bots rate-limited but have SUCCESS status checks" >&2
		return 0
	elif [[ -n "$rate_limited_bots" ]]; then
		# GH#3827: Rate-limit grace period. If bots posted rate-limit notices
		# (proving they're configured and aware of the PR) but the PR has been
		# open longer than RATE_LIMIT_GRACE_SECONDS, pass with a warning.
		# This prevents indefinite blockage when bots are systemically rate-limited.
		local pr_age
		pr_age=$(get_pr_age_seconds "$pr_number" "$repo")
		if [[ "$RATE_LIMIT_GRACE_SECONDS" -gt 0 ]] && [[ "$pr_age" -ge "$RATE_LIMIT_GRACE_SECONDS" ]]; then
			local grace_hours=$((RATE_LIMIT_GRACE_SECONDS / 3600))
			local age_hours=$((pr_age / 3600))
			echo "PASS_RATE_LIMITED"
			echo "Rate-limit grace period exceeded (PR is ${age_hours}h old, threshold: ${grace_hours}h)." >&2
			echo "Bots are rate-limited: ${rate_limited_bots}" >&2
			echo "Passing gate — bot reviews will be addressed post-merge if needed." >&2
			return 0
		fi
		echo "WAITING"
		echo "Bots posted rate-limit notices only (not real reviews): ${rate_limited_bots}" >&2
		echo "No SUCCESS status checks found as fallback." >&2
		if [[ "$RATE_LIMIT_GRACE_SECONDS" -gt 0 ]]; then
			local grace_hours=$((RATE_LIMIT_GRACE_SECONDS / 3600))
			local remaining=$(((RATE_LIMIT_GRACE_SECONDS - pr_age) / 60))
			echo "Rate-limit grace period: ${grace_hours}h (${remaining}min remaining)." >&2
		fi
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

	# Validate that max_wait and poll_interval are positive integers to prevent
	# command injection via arithmetic expansion (GH#3223).
	if ! [[ "$max_wait" =~ ^[0-9]+$ ]]; then
		echo "ERROR: max_wait must be a non-negative integer, got: '${max_wait}'" >&2
		return 2
	fi
	if ! [[ "$poll_interval" =~ ^[0-9]+$ ]]; then
		echo "ERROR: poll_interval must be a non-negative integer, got: '${poll_interval}'" >&2
		return 2
	fi

	echo "Waiting up to ${max_wait}s for review bots on PR #${pr_number}..." >&2

	while [[ "$elapsed" -lt "$max_wait" ]]; do
		local result
		result=$(do_check "$pr_number" "$repo") || true

		if [[ "$result" == "PASS" || "$result" == "PASS_RATE_LIMITED" || "$result" == "SKIP" ]]; then
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

	# Show status check fallback info
	echo ""
	echo "Status check fallback (GH#3005):"
	if any_bot_has_success_status "$pr_number" "$repo"; then
		echo "  At least one bot has a SUCCESS status check."
	else
		echo "  No bot SUCCESS status checks found."
	fi
	return 0
}

has_formal_reviews() {
	# Check if the PR has at least one formal GitHub review (any state).
	local pr_number="$1"
	local repo="$2"

	local count
	count=$(gh pr view "$pr_number" --repo "$repo" \
		--json reviews --jq '.reviews | length' || echo "0")
	if [[ "$count" -gt 0 ]]; then
		return 0
	fi
	return 1
}

has_retry_comment() {
	# Check if we already posted a review retry request on this PR.
	# Looks for our specific marker comment to ensure idempotency.
	local pr_number="$1"
	local repo="$2"

	local marker="<!-- review-bot-retry-requested -->"
	local comments
	comments=$(gh api "repos/${repo}/issues/${pr_number}/comments" \
		--paginate --jq '.[].body' || echo "")
	if echo "$comments" | grep -qF "$marker"; then
		return 0
	fi
	return 1
}

find_rate_limited_bots() {
	# Return space-separated list of bots that posted only rate-limit notices.
	# Empty string if no rate-limited bots found.
	local pr_number="$1"
	local repo="$2"

	local all_commenters
	all_commenters=$(get_all_bot_commenters "$pr_number" "$repo")

	local rate_limited=""
	local bot
	for bot in "${KNOWN_BOTS[@]}"; do
		if echo "$all_commenters" | grep -qi "$bot"; then
			if ! bot_has_real_review "$pr_number" "$repo" "$bot"; then
				rate_limited="${rate_limited}${bot} "
			fi
		fi
	done
	echo "$rate_limited"
	return 0
}

do_request_retry() {
	# Self-healing: if bots were rate-limited at PR creation and never came
	# back, request a review retry. Idempotent — checks for prior retry
	# comment before posting. Does NOT bypass the formal review gate.
	#
	# Returns: REQUESTED, ALREADY_REQUESTED, NO_ACTION, or HAS_REVIEWS
	local pr_number="$1"
	local repo="$2"

	# If formal reviews already exist, nothing to do
	if has_formal_reviews "$pr_number" "$repo"; then
		echo "HAS_REVIEWS"
		echo "PR already has formal reviews — no retry needed." >&2
		return 0
	fi

	# If we already requested a retry, don't spam
	if has_retry_comment "$pr_number" "$repo"; then
		echo "ALREADY_REQUESTED"
		echo "Retry already requested on PR #${pr_number} — waiting for bot response." >&2
		return 0
	fi

	# Check if any bots posted rate-limit notices
	local rate_limited_bots
	rate_limited_bots=$(find_rate_limited_bots "$pr_number" "$repo")

	if [[ -z "$rate_limited_bots" ]]; then
		echo "NO_ACTION"
		echo "No rate-limited bots found — nothing to retry." >&2
		return 0
	fi

	# Post retry request with idempotency marker
	local comment_body
	comment_body="<!-- review-bot-retry-requested -->
@coderabbitai review

Review bots were rate-limited when this PR was created (affected: ${rate_limited_bots% }). Requesting a review retry."

	if gh pr comment "$pr_number" --repo "$repo" --body "$comment_body" >/dev/null 2>&1; then
		echo "REQUESTED"
		echo "Requested review retry on PR #${pr_number} (rate-limited bots: ${rate_limited_bots% })." >&2
		return 0
	else
		echo "ERROR: Failed to post retry comment on PR #${pr_number}." >&2
		return 2
	fi
}

do_batch_retry() {
	# GH#3932: Process all open PRs with 0 formal reviews, request retries
	# for rate-limited ones. Staggers requests with a delay between each to
	# avoid re-triggering CodeRabbit's hourly rate limit.
	#
	# Returns summary: REQUESTED_N (where N is the count of retries requested)
	local repo="$1"
	local stagger_seconds="${BATCH_RETRY_STAGGER:-5}"

	echo "Scanning open PRs in ${repo} for rate-limited reviews..." >&2

	# Get all open PRs with 0 formal reviews
	local pr_numbers
	pr_numbers=$(gh pr list --repo "$repo" --state open --limit 100 \
		--json number,reviews \
		--jq '[.[] | select((.reviews | length) == 0)] | .[].number' || echo "")

	if [[ -z "$pr_numbers" ]]; then
		echo "NO_ACTION"
		echo "No open PRs with 0 formal reviews found." >&2
		return 0
	fi

	local total=0
	local requested=0
	local already=0
	local skipped=0
	local pr_num result

	while IFS= read -r pr_num; do
		[[ -z "$pr_num" ]] && continue
		total=$((total + 1))

		# Run request-retry for each PR (it handles idempotency internally)
		result=$(do_request_retry "$pr_num" "$repo") || true

		case "$result" in
		REQUESTED)
			requested=$((requested + 1))
			echo "  PR #${pr_num}: retry requested" >&2
			# Stagger to avoid re-triggering rate limits
			if [[ "$stagger_seconds" -gt 0 ]]; then
				sleep "$stagger_seconds"
			fi
			;;
		ALREADY_REQUESTED)
			already=$((already + 1))
			echo "  PR #${pr_num}: already requested" >&2
			;;
		HAS_REVIEWS)
			echo "  PR #${pr_num}: has formal reviews (skipped)" >&2
			;;
		NO_ACTION)
			skipped=$((skipped + 1))
			echo "  PR #${pr_num}: no rate-limited bots (skipped)" >&2
			;;
		*)
			skipped=$((skipped + 1))
			echo "  PR #${pr_num}: ${result:-error} (skipped)" >&2
			;;
		esac
	done <<<"$pr_numbers"

	echo "REQUESTED_${requested}"
	echo "Batch retry complete: ${total} PRs scanned, ${requested} retries requested, ${already} already requested, ${skipped} skipped." >&2
	return 0
}

# --- Main ---

main() {
	local command="${1:-}"
	local pr_number="${2:-}"
	local repo="${3:-}"
	local max_wait="${4:-}"

	# batch-retry only needs repo, not pr_number
	if [[ "$command" == "batch-retry" ]]; then
		local batch_repo="${2:-}"
		if [[ -z "$batch_repo" ]]; then
			batch_repo=$(gh repo view --json nameWithOwner -q .nameWithOwner || echo "")
			if [[ -z "$batch_repo" ]]; then
				echo "ERROR: Could not determine repo. Pass REPO as argument." >&2
				return 2
			fi
		fi
		do_batch_retry "$batch_repo"
		return $?
	fi

	if [[ -z "$command" || -z "$pr_number" ]]; then
		usage
		return 2
	fi

	# Default repo from current git context
	if [[ -z "$repo" ]]; then
		repo=$(gh repo view --json nameWithOwner -q .nameWithOwner || echo "")
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
	request-retry)
		do_request_retry "$pr_number" "$repo"
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
