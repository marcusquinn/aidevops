#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dispatch-claim-helper.sh — Cross-machine dispatch claim via GitHub comments (t1686)
#
# Implements optimistic locking for dispatch dedup across multiple runners.
# Before dispatching a worker for an issue, a runner posts a claim comment
# (plain text — visible in rendered view), waits a consensus window,
# then checks if its claim is the oldest. Only the first claimant proceeds;
# others back off.
#
# This closes the race window in the is_assigned check (GH#4947) where two
# runners can both read "unassigned" before either writes their assignment.
#
# Protocol:
#   1. Post claim: DISPATCH_CLAIM nonce=UUID runner=LOGIN ts=ISO max_age_s=SECONDS
#   2. Sleep consensus window (DISPATCH_CLAIM_WINDOW, default 8s)
#   3. Re-read comments, find all DISPATCH_CLAIM within the window
#   4. Oldest active claim wins — others back off and delete their claim
#
# Usage:
#   dispatch-claim-helper.sh claim <issue-number> <repo-slug> [runner-login]
#     Attempt to claim an issue for dispatch.
#     Exit 0 = claim won (safe to dispatch)
#     Exit 1 = claim lost (another runner was first — do NOT dispatch)
#     Exit 2 = error (fail-open — caller should proceed with dispatch)
#
#   dispatch-claim-helper.sh check <issue-number> <repo-slug>
#     Check if any active claim exists on this issue.
#     Exit 0 = active claim exists (do NOT dispatch)
#     Exit 1 = no active claim (safe to proceed to claim step)
#
#   dispatch-claim-helper.sh help
#     Show usage information.

set -euo pipefail

# Consensus window — how long to wait after posting a claim before checking
# who won. Must be long enough for GitHub API propagation across runners.
DISPATCH_CLAIM_WINDOW="${DISPATCH_CLAIM_WINDOW:-8}"

# Maximum age (seconds) of a claim comment to consider it active.
# Claims older than this are stale and ignored by the lock check.
DISPATCH_CLAIM_MAX_AGE="${DISPATCH_CLAIM_MAX_AGE:-120}"

# GH#15317: Self-reclaim removed. Previously, same-runner stale claims were
# "reclaimed" after this threshold, creating dispatch loops. Now stale self-
# claims are cleaned up and treated as lost. Variable kept for backward compat.
DISPATCH_CLAIM_SELF_RECLAIM_AGE="${DISPATCH_CLAIM_SELF_RECLAIM_AGE:-30}"

# Claim comment marker — used as both the posting format and the search pattern.
# Plain text format: visible in rendered GitHub issue view.
CLAIM_MARKER="DISPATCH_CLAIM"

#######################################
# Generate a unique nonce for this claim attempt.
# Uses /dev/urandom for uniqueness; falls back to date+PID.
# Returns: nonce string on stdout
#######################################
_generate_nonce() {
	if [[ -r /dev/urandom ]]; then
		head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
	else
		printf '%s-%s' "$(date -u '+%s%N' 2>/dev/null || date -u '+%s')" "$$"
	fi
	return 0
}

#######################################
# Get current UTC timestamp in ISO 8601 format
#######################################
_now_utc() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
	return 0
}

#######################################
# Get current epoch seconds
#######################################
_now_epoch() {
	date -u '+%s'
	return 0
}

#######################################
# Parse ISO 8601 timestamp to epoch seconds
# Args: $1 = ISO timestamp (YYYY-MM-DDTHH:MM:SSZ)
# Returns: epoch seconds via stdout
#######################################
_iso_to_epoch() {
	local ts="$1"
	# Try GNU date first (Linux), then BSD date (macOS)
	date -u -d "$ts" '+%s' 2>/dev/null ||
		TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%s' 2>/dev/null ||
		printf '%s' "0"
	return 0
}

#######################################
# Resolve the current runner's GitHub login.
# Args: $1 = optional override login
# Returns: login string on stdout
#######################################
_resolve_runner() {
	local override="${1:-}"
	if [[ -n "$override" ]]; then
		printf '%s' "$override"
		return 0
	fi
	# Try gh API, fall back to whoami
	gh api user --jq '.login' 2>/dev/null || whoami
	return 0
}

#######################################
# Post a claim comment on a GitHub issue.
# The comment is plain text — visible in rendered view.
#
# Args:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   $3 = runner login
#   $4 = nonce
#   $5 = ISO timestamp
# Returns:
#   exit 0 + comment ID on stdout if posted
#   exit 1 on failure
#######################################
_post_claim() {
	local issue_number="$1"
	local repo_slug="$2"
	local runner="$3"
	local nonce="$4"
	local ts="$5"

	local body
	body="${CLAIM_MARKER} nonce=${nonce} runner=${runner} ts=${ts} max_age_s=${DISPATCH_CLAIM_MAX_AGE}"

	local comment_id
	comment_id=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--method POST \
		--field body="$body" \
		--jq '.id' 2>/dev/null) || {
		echo "Error: failed to post claim comment on #${issue_number} in ${repo_slug}" >&2
		return 1
	}

	if [[ -z "$comment_id" || "$comment_id" == "null" ]]; then
		echo "Error: claim comment posted but no ID returned" >&2
		return 1
	fi

	printf '%s' "$comment_id"
	return 0
}

#######################################
# Delete a comment by ID.
# Args:
#   $1 = repo slug
#   $2 = comment ID
# Returns: exit 0 on success, exit 1 on failure (non-fatal)
#######################################
_delete_comment() {
	local repo_slug="$1"
	local comment_id="$2"

	gh api "repos/${repo_slug}/issues/comments/${comment_id}" \
		--method DELETE 2>/dev/null || {
		echo "Warning: failed to delete comment ${comment_id} in ${repo_slug}" >&2
		return 1
	}
	return 0
}

#######################################
# Fetch recent claim comments on an issue.
# Returns JSON array of {id, nonce, runner, ts, ts_epoch} objects.
#
# Args:
#   $1 = issue number
#   $2 = repo slug
# Returns: JSON array on stdout, exit 0 on success, exit 1 on failure
#######################################
_fetch_claims() {
	local issue_number="$1"
	local repo_slug="$2"

	local now_epoch
	now_epoch=$(_now_epoch)

	# Fetch last 30 comments (more than enough for claim window)
	local comments_json
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--jq '[.[] | select(.body | test("'"${CLAIM_MARKER}"' nonce=")) | {id: .id, body: .body, created_at: .created_at}]' \
		2>/dev/null) || {
		echo "Error: failed to fetch comments for #${issue_number} in ${repo_slug}" >&2
		return 1
	}

	if [[ -z "$comments_json" || "$comments_json" == "null" || "$comments_json" == "[]" ]]; then
		printf '[]'
		return 0
	fi

	# Parse claim fields from comment bodies and filter by max age
	local parsed
	parsed=$(printf '%s' "$comments_json" | jq -c --argjson now "$now_epoch" --argjson max_age "$DISPATCH_CLAIM_MAX_AGE" '
		[.[] |
			(.body | capture("nonce=(?<nonce>[^ ]+) runner=(?<runner>[^ ]+) ts=(?<ts>[^ ]+)")) as $fields |
			{
				id: .id,
				nonce: $fields.nonce,
				runner: $fields.runner,
				ts: $fields.ts,
				created_at: .created_at,
				created_epoch: (.created_at | fromdateiso8601? // 0)
			}
		] |
		map(. + {age_seconds: ($now - .created_epoch)}) |
		map(select(.age_seconds >= 0 and .age_seconds <= $max_age)) |
		# Sort by created_at (GitHub timestamp) — chronological order
		sort_by(.created_at)
	' 2>/dev/null) || {
		echo "Error: failed to parse claim comments" >&2
		return 1
	}

	printf '%s' "$parsed"
	return 0
}

#######################################
# Attempt to claim an issue for dispatch.
#
# Protocol:
#   1. Post claim comment with unique nonce
#   2. Sleep consensus window
#   3. Fetch all claim comments
#   4. If this runner's claim is the oldest active claim → won
#   5. If another runner's claim is older → lost, delete own claim
#
# Args:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   $3 = runner login (optional, auto-detected)
# Returns:
#   exit 0 = claim won (safe to dispatch)
#   exit 1 = claim lost (do NOT dispatch)
#   exit 2 = error (fail-open — caller should proceed)
#######################################
cmd_claim() {
	local issue_number="${1:-}"
	local repo_slug="${2:-}"
	local runner_login="${3:-}"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		echo "Error: claim requires <issue-number> <repo-slug>" >&2
		return 2
	fi

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
		echo "Error: issue number must be numeric, got: ${issue_number}" >&2
		return 2
	fi

	local runner
	runner=$(_resolve_runner "$runner_login") || runner="unknown"

	local nonce
	nonce=$(_generate_nonce)

	local ts
	ts=$(_now_utc)

	# Step 1: Post claim
	local comment_id
	comment_id=$(_post_claim "$issue_number" "$repo_slug" "$runner" "$nonce" "$ts") || {
		echo "CLAIM_ERROR: failed to post claim — proceeding (fail-open)" >&2
		return 2
	}

	# Step 2: Wait consensus window
	sleep "$DISPATCH_CLAIM_WINDOW"

	# Step 3: Fetch all claims
	local claims
	claims=$(_fetch_claims "$issue_number" "$repo_slug") || {
		echo "CLAIM_ERROR: failed to fetch claims — proceeding (fail-open)" >&2
		return 2
	}

	local claim_count
	claim_count=$(printf '%s' "$claims" | jq 'length' 2>/dev/null) || claim_count=0

	if [[ "$claim_count" -eq 0 ]]; then
		# No claims found (including ours) — something went wrong, fail-open
		echo "CLAIM_ERROR: no claims found after posting — proceeding (fail-open)" >&2
		return 2
	fi

	# Step 4: Check if our claim is the oldest
	local oldest_nonce oldest_runner oldest_age_seconds
	oldest_nonce=$(printf '%s' "$claims" | jq -r '.[0].nonce // ""' 2>/dev/null) || oldest_nonce=""
	oldest_runner=$(printf '%s' "$claims" | jq -r '.[0].runner // "unknown"' 2>/dev/null) || oldest_runner="unknown"
	oldest_age_seconds=$(printf '%s' "$claims" | jq -r '.[0].age_seconds // 0' 2>/dev/null) || oldest_age_seconds=0

	if [[ "$oldest_nonce" == "$nonce" ]]; then
		# We won — our claim is the oldest
		printf 'CLAIM_WON: runner=%s nonce=%s issue=#%s comment_id=%s\n' \
			"$runner" "$nonce" "$issue_number" "$comment_id"
		return 0
	fi

	# GH#15317: Self-reclaim removed. Previously, if the oldest claim belonged to
	# the same runner and was >30s old, the runner would "reclaim" — allowing
	# re-dispatch. This created same-runner dispatch loops: claim → dispatch →
	# worker dies → 30s passes → self-reclaim → dispatch again. Evidence:
	# awardsapp #2051 had 25 claims from alex-solovyev over 6 hours.
	#
	# The dispatch_with_dedup() caller now posts a deterministic "Dispatching
	# worker" comment and cleans up claim comments after dispatch. If a worker
	# needs to be re-dispatched, the pulse must first post a kill/failure comment
	# and remove the dispatch comment — making the re-dispatch explicit, not
	# an implicit side effect of stale claims.
	#
	# If the oldest claim is from the same runner, treat as a lost claim (stale
	# from a previous cycle that wasn't cleaned up). Delete both claims.
	if [[ "$oldest_runner" == "$runner" && "$oldest_nonce" != "$nonce" ]]; then
		printf 'CLAIM_STALE_SELF: runner=%s found own stale claim on issue #%s (stale_age_s=%s) — cleaning up\n' \
			"$runner" "$issue_number" "$oldest_age_seconds"
		# Delete both the stale claim and the fresh one we just posted
		local stale_comment_id
		stale_comment_id=$(printf '%s' "$claims" | jq -r '.[0].id // ""' 2>/dev/null) || stale_comment_id=""
		if [[ -n "$stale_comment_id" ]]; then
			_delete_comment "$repo_slug" "$stale_comment_id" 2>/dev/null || true
		fi
		_delete_comment "$repo_slug" "$comment_id" 2>/dev/null || true
		return 1
	fi

	# Step 5: We lost — another runner's claim is older
	printf 'CLAIM_LOST: runner=%s lost to %s on issue #%s — backing off\n' \
		"$runner" "$oldest_runner" "$issue_number"

	# Clean up our losing claim
	_delete_comment "$repo_slug" "$comment_id" 2>/dev/null || true

	return 1
}

#######################################
# Check if any active claim exists on an issue.
# Used as a quick pre-check before entering the full claim protocol.
#
# Args:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
# Returns:
#   exit 0 = active claim exists (do NOT dispatch — someone is already claiming)
#   exit 1 = no active claim (safe to proceed to claim step)
#   exit 2 = error (fail-open — proceed)
#######################################
cmd_check() {
	local issue_number="${1:-}"
	local repo_slug="${2:-}"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		echo "Error: check requires <issue-number> <repo-slug>" >&2
		return 2
	fi

	local claims
	claims=$(_fetch_claims "$issue_number" "$repo_slug") || {
		# Fail-open on API error
		return 2
	}

	local claim_count
	claim_count=$(printf '%s' "$claims" | jq 'length' 2>/dev/null) || claim_count=0

	if [[ "$claim_count" -gt 0 ]]; then
		local oldest_runner oldest_ts
		oldest_runner=$(printf '%s' "$claims" | jq -r '.[0].runner // "unknown"' 2>/dev/null) || oldest_runner="unknown"
		oldest_ts=$(printf '%s' "$claims" | jq -r '.[0].ts // ""' 2>/dev/null) || oldest_ts=""
		printf 'ACTIVE_CLAIM: runner=%s ts=%s on issue #%s (%d total claims)\n' \
			"$oldest_runner" "$oldest_ts" "$issue_number" "$claim_count"
		return 0
	fi

	return 1
}

#######################################
# Show help
#######################################
show_help() {
	cat <<'HELP'
dispatch-claim-helper.sh — Cross-machine dispatch claim via GitHub comments (t1686)

Implements optimistic locking to prevent multiple runners from dispatching
workers for the same issue. Uses plain-text comments as a distributed lock
mechanism via GitHub's append-only comment timeline.

Usage:
  dispatch-claim-helper.sh claim <issue-number> <repo-slug> [runner-login]
    Attempt to claim an issue for dispatch.
    Exit 0 = claim won (safe to dispatch)
    Exit 1 = claim lost (do NOT dispatch)
    Exit 2 = error (fail-open — proceed with dispatch)

  dispatch-claim-helper.sh check <issue-number> <repo-slug>
    Check if any active claim exists on this issue.
    Exit 0 = active claim exists (do NOT dispatch)
    Exit 1 = no active claim (safe to proceed to claim step)
    Exit 2 = error (fail-open — proceed)

  dispatch-claim-helper.sh help
    Show this help.

Environment:
  DISPATCH_CLAIM_WINDOW    Consensus window in seconds (default: 8)
  DISPATCH_CLAIM_MAX_AGE   Max age of claim comments in seconds (default: 120)
  DISPATCH_CLAIM_SELF_RECLAIM_AGE
                           Same-runner stale-claim reclaim threshold in
                           seconds (default: 30)

Protocol:
  1. Runner posts plain-text claim comment with unique nonce
     and max_age_s (active claim window in seconds)
  2. Waits DISPATCH_CLAIM_WINDOW seconds for other runners
  3. Fetches all claim comments on the issue
  4. Oldest active claim wins (claims older than DISPATCH_CLAIM_MAX_AGE are ignored)
     — others back off and delete their claims
  5. Winner proceeds with dispatch; claim comment persists as audit trail

Examples:
  # Claim before dispatching (in pulse dedup guard)
  RUNNER=$(gh api user --jq '.login')
  if dispatch-claim-helper.sh claim 42 owner/repo "$RUNNER"; then
    # Won the claim — dispatch worker
    headless-runtime-helper.sh run --session-key "issue-42" ...
  else
    exit_code=$?
    if [[ $exit_code -eq 1 ]]; then
      echo "Lost claim — another runner is dispatching"
    else
      echo "Claim error — proceeding (fail-open)"
      # dispatch anyway
    fi
  fi
HELP
	return 0
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	claim)
		cmd_claim "$@"
		;;
	check)
		cmd_check "$@"
		;;
	help | --help | -h)
		show_help
		;;
	*)
		echo "Error: Unknown command: $command" >&2
		show_help
		return 1
		;;
	esac
}

main "$@"
