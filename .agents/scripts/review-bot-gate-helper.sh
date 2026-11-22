#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# review-bot-gate-helper.sh — Check if AI review bots have posted on a PR
#
# Usage:
#   review-bot-gate-helper.sh check         <PR_NUMBER> [REPO]
#   review-bot-gate-helper.sh event-check
#   review-bot-gate-helper.sh is-trusted-issue-sync-pr <PR_NUMBER> [REPO] [EXPECTED_HEAD_SHA]
#   review-bot-gate-helper.sh classify-infra-rate-limit <AUTHOR_ASSOCIATION> [REPO]
#   review-bot-gate-helper.sh wait          <PR_NUMBER> [REPO] [MAX_WAIT_SECONDS]
#   review-bot-gate-helper.sh list          <PR_NUMBER> [REPO]
#   review-bot-gate-helper.sh request-retry <PR_NUMBER> [REPO]
#   review-bot-gate-helper.sh status-json   <PR_NUMBER> [REPO]
#   review-bot-gate-helper.sh batch-retry   [REPO]
#   review-bot-gate-helper.sh reconcile-stale-coderabbit <PR_NUMBER> [REPO] [EXPECTED_HEAD_SHA]
#   review-bot-gate-helper.sh dismiss-coderabbit-nits <PR_NUMBER> [REPO]
#
# Commands:
#   check          — Check once, return PASS/PASS_ADVISORY/PASS_RATE_LIMITED/WAITING/SKIP
#   event-check    — Accept trusted bot review evidence from the Actions event
#   is-trusted-issue-sync-pr — Verify the exact generated TODO PR identity (Issue
#                     Sync or Pulse TODO handoff) and optional head
#   classify-infra-rate-limit — Classify API exhaustion from immutable event trust
#   wait           — Poll until a bot posts or timeout (default 600s)
#   list           — List all bot comments found on the PR
#   request-retry  — If bots were rate-limited and no real review exists,
#                     request a review retry (idempotent, safe to call every pulse)
#   status-json    — Machine-readable check result for automation
#   batch-retry    — Process all open PRs with 0 formal reviews, request retries
#                     for rate-limited ones. Staggers requests to avoid re-triggering
#                     rate limits. (GH#3932)
#   reconcile-stale-coderabbit — Dismiss only superseded CodeRabbit change
#                     requests after trusted clean exact-head evidence
#   dismiss-coderabbit-nits — Preserve the maintainer-labelled cosmetic override
#
# Output values for check/wait:
#   PASS              — At least one bot posted a real review
#   PASS_ADVISORY     — No completed review; default policy defers late feedback
#   PASS_RATE_LIMITED  — Bots are rate-limited but grace period exceeded (GH#3827)
#   WAITING           — Explicit strict/wait policy requires more review evidence
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
#   REVIEW_GATE_RATE_LIMIT_BEHAVIOR — Global default for rate-limited bots:
#                              "pass" (default, exit 0) or "wait" (keep polling).
#                              Override per-repo or per-tool in repos.json:
#                              { "review_gate": { "rate_limit_behavior": "pass",
#                                "tools": { "coderabbitai": { "rate_limit_behavior": "wait" } } } }
#   REVIEW_GATE_COMPLETION_BEHAVIOR — Global default for bot completion:
#                              "fast" (default, add-ons are advisory) or
#                              "strict" (require completed review evidence).
#                              Override per-repo or per-tool in repos.json:
#                              { "review_gate": { "completion_behavior": "strict",
#                                "tools": { "coderabbitai": { "completion_behavior": "fast" } } } }
#   REVIEW_GATE_EVIDENCE_SNAPSHOT_DISABLE — Set to 1 to disable per-check reuse
#                              of the three review/comment API collections.
#   REVIEW_GATE_AUTHOR_ASSOCIATION_RESOLVED — Set to true only when the caller
#                              already finalized immutable author trust evidence.
#
# t1382: https://github.com/marcusquinn/aidevops/issues/2735
# GH#3827: Rate-limit grace period — pass gate after timeout when bots are
#          rate-limited, preventing indefinite PR blockage.

set -euo pipefail

# t2393: source shared-constants.sh for the gh_pr_comment wrapper (sig footer).
# Non-fatal: if the file is missing (e.g. deployed layout drift), fall through
# to raw `gh pr comment`.
# GH#37011: a caller sourcing a relocated copy may preset _RBG_SCRIPT_DIR so the
# sibling review-bot-gate-*.sh modules still resolve.
_RBG_SCRIPT_DIR="${_RBG_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
# shellcheck source=/dev/null
[[ -r "${_RBG_SCRIPT_DIR}/shared-constants.sh" ]] && source "${_RBG_SCRIPT_DIR}/shared-constants.sh" || true

# Current review bot login patterns (lowercase, without [bot] suffix).
ACTIVE_BOTS=(
	"coderabbitai"
	"augment-code"
	"augmentcode"
	"copilot"
)
# Retired providers remain recognizable so historical reviews, comments, and
# unresolved threads are not reclassified as human activity. They are excluded
# from per-tool strict/wait policy so stale config cannot block new merges.
RBG_RETIRED_GEMINI_LOGIN="gemini-code-assist"
RETIRED_BOTS=("$RBG_RETIRED_GEMINI_LOGIN")
KNOWN_BOTS=("${ACTIVE_BOTS[@]}" "${RETIRED_BOTS[@]}")
REVIEW_GATE_STATUS_PASS="$(printf 'P%s' 'ASS')"
RBG_PASS_ADVISORY="PASS_ADVISORY"
RBG_PASS_RATE_LIMITED="PASS_RATE_LIMITED"
RBG_FALSE="false"
RBG_TRUE="true"
RBG_COMPLETION_STRICT="strict"
RBG_CODERABBIT_LOGIN="coderabbitai[bot]"
RBG_CODERABBIT_STATUS_CONTEXT="coderabbit"
RBG_CODERABBIT_ADDRESSED_MARKER='<!-- <review_comment_addressed> -->'
RBG_CODERABBIT_NITS_LABEL="coderabbit-nits-ok"
RBG_RECONCILE_MODE_NITS="nits"
RBG_RECONCILE_MODE_SUPERSEDED="superseded"
RBG_RECONCILE_MODE_ADVISORY="advisory"
RBG_AUTHOR_CLASS_TRUSTED="trusted"
RBG_GITHUB_ACTIONS_BOT_ID="41898282"
RBG_ISSUE_SYNC_PR_BRANCH="aidevops/issue-sync-todo"
RBG_ISSUE_SYNC_PR_MARKER="<!-- aidevops:issue-sync-todo-pr -->"
# Pulse protected-default TODO handoff (pulse-todo-publication.sh): the branch
# suffix is the first 16 hex characters of the snapshot-derived handoff ID.
RBG_PULSE_TODO_HANDOFF_BRANCH_PREFIX="aidevops/pulse-todo-"

# Rate-limit / quota notice patterns — entries that indicate the bot tried to
# review but was capacity-constrained. Used by grace-period logic
# (RATE_LIMIT_GRACE_SECONDS, _should_pass_rate_limited) where the semantic
# distinction matters: a rate-limited bot may recover and review later, while
# a "Review skipped" bot will not.
# t2799: restored to original rate-limit-only semantics after t2139 expansion.
RATE_LIMIT_PATTERNS=(
	"rate limit exceeded"
	"rate limited by coderabbit"
	"daily quota limit"
	"reached your daily quota"
	"Please wait up to 24 hours"
	"has exceeded the limit for the number of"
)

# Broader set: all patterns that indicate a comment is NOT a real review.
# Includes rate-limit notices (above) AND non-quota bot status messages
# ("Review failed", "Review skipped", placeholder edits after the PR was
# closed). Case-insensitive grep patterns — one per line.
# t2139 (GH#19251): expanded from rate-limit-only to include non-review
# notices, after CodeRabbit "Review failed/skipped/closed-during-review"
# messages were observed false-positive-classifying as real reviews.
# t2799: split from RATE_LIMIT_PATTERNS; built as union so the two stay
# consistent.
# GH#28481: Gemini Code Assist retirement notices are provider status, not
# review evidence.
NON_REVIEW_PATTERNS=(
	"${RATE_LIMIT_PATTERNS[@]}"
	"Review failed"
	"Review skipped"
	"closed or merged during review"
	"Auto reviews are limited"
	"code review activity has officially ceased"
)

# Bots that post a Phase 1 placeholder and later edit it with real review
# content. For these, age-derived settlement is unreliable — require
# edit-observed settlement (edit_delta > 0). All other bots preserve existing
# OR semantics (edit_delta >= min_lag OR age >= min_lag).
# GH#20550 / #20494 — two-phase bot list (Option A').
readonly TWO_PHASE_BOTS=("coderabbitai")

SKIP_LABEL="skip-review-gate"

# GH#3827: Grace period for rate-limited bots. If bots posted rate-limit
# notices (proving they're configured) but the PR has been open longer than
# this threshold, pass the gate with a warning. Default: 30 min (1800s).
# GH#17549: Reduced from 4h — workers produce PRs every 10 min and 4h
# grace blocked the entire merge pipeline when Gemini was rate-limited.
# Set RATE_LIMIT_GRACE_SECONDS=0 to disable (block indefinitely).
RATE_LIMIT_GRACE_SECONDS="${RATE_LIMIT_GRACE_SECONDS:-1800}"

# t2123: Global default for rate-limit behavior.
# Values: "pass" (exit 0 immediately, current default) or "wait" (return WAITING).
# Override per-repo or per-tool via repos.json review_gate config.
REVIEW_GATE_RATE_LIMIT_BEHAVIOR="${REVIEW_GATE_RATE_LIMIT_BEHAVIOR:-pass}"

# GH#23066: Global default for completion evidence behavior.
# Values: "fast" keeps add-on review advisory so required CI controls merge
# readiness; "strict" requires completed review evidence before merge and also
# requires bot-specific terminal success evidence for two-phase bots such as
# CodeRabbit. Override per-repo or per-tool via repos.json review_gate config.
REVIEW_GATE_COMPLETION_BEHAVIOR="${REVIEW_GATE_COMPLETION_BEHAVIOR:-fast}"

# t2139 (GH#19251): Minimum seconds a bot comment must have been "settled"
# (either edited via updated_at > created_at, or simply old enough since
# created_at) before it counts as a completed review. Defeats the two-phase
# placeholder pattern where a bot posts an initial stub at ~14s and edits it
# with the real review at ~90-120s. Default 30s — large enough to skip
# Phase 1 placeholders, small enough not to block fast-completing bots.
# Override per-repo or per-tool via repos.json review_gate config:
#   { "review_gate": { "min_edit_lag_seconds": 30,
#     "tools": { "coderabbitai": { "min_edit_lag_seconds": 60 } } } }
REVIEW_BOT_MIN_EDIT_LAG_SECONDS="${REVIEW_BOT_MIN_EDIT_LAG_SECONDS:-30}"

# One fresh snapshot per check avoids repeatedly downloading the same reviews,
# issue comments, and inline comments while classifying multiple bots. The
# snapshot never survives a new do_check invocation, so polling still observes
# newly posted or edited reviews without a TTL or cross-cycle stale window.
_RBG_EVIDENCE_SNAPSHOT_KEY=""
_RBG_EVIDENCE_REVIEWS_JSON="[]"
_RBG_EVIDENCE_ISSUE_COMMENTS_JSON="[]"
_RBG_EVIDENCE_REVIEW_COMMENTS_JSON="[]"
_RBG_EVIDENCE_SNAPSHOT_READY=0

# --- Functions ---

usage() {
	echo "Usage: $(basename "$0") {check|event-check|is-trusted-issue-sync-pr|classify-infra-rate-limit|wait|list|request-retry|status-json|batch-retry|reconcile-stale-coderabbit|dismiss-coderabbit-nits} <PR_NUMBER> [REPO] [EXTRA]"
	echo ""
	echo "Commands:"
	echo "  check          Check once for bot reviews (returns PASS/PASS_ADVISORY/PASS_RATE_LIMITED/WAITING/SKIP)"
	echo "  event-check    Check trusted bot review evidence from REVIEW_GATE_EVENT_* variables"
	echo "  is-trusted-issue-sync-pr  Return TRUSTED (0), UNTRUSTED (1), or API error (2) for Issue Sync or Pulse TODO handoff PRs from live PR metadata"
	echo "  classify-infra-rate-limit  Resolve trusted/default-advisory API exhaustion without another API call"
	echo "  wait           Poll until bot reviews appear or timeout"
	echo "  list           List all bot comments found"
	echo "  request-retry  Request review retry if bots were rate-limited (idempotent)"
	echo "  status-json    Print machine-readable gate status"
	echo "  batch-retry    Process all open PRs with 0 reviews, request retries (GH#3932)"
	echo "  reconcile-stale-coderabbit  Reconcile a stale CodeRabbit-only change request"
	echo "  dismiss-coderabbit-nits  Dismiss CodeRabbit-only reviews under the maintainer label"
	return 0
}

classify_infra_rate_limit() {
	local author_association="$1"
	local repo_slug="$2"
	local rate_limit_behavior completion_behavior repos_json strict_tool_override="$RBG_FALSE"

	# GH#36931: add-on review is advisory for every author. External-PR trust is
	# exact-head maintainer crypto approval (pulse + full-loop), not bot review.
	# The association argument is retained for CLI compatibility.
	: "$author_association"

	rate_limit_behavior=$(_get_rate_limit_behavior "$repo_slug" "")
	completion_behavior=$(_get_completion_behavior "$repo_slug" "")
	repos_json="${HOME}/.config/aidevops/repos.json"
	if [[ -f "$repos_json" ]] && command -v jq >/dev/null 2>&1; then
		strict_tool_override=$(jq -r --arg slug "$repo_slug" --arg strict "$RBG_COMPLETION_STRICT" --arg retired "$RBG_RETIRED_GEMINI_LOGIN" '
			[first(.initialized_repos[]? | select(.slug == $slug)).review_gate.tools // {} | to_entries[]?
			| select(.key != $retired)
			| select(.value.rate_limit_behavior == "wait" or .value.completion_behavior == $strict)]
			| if length > 0 then "true" else (false | tostring) end
		' "$repos_json" 2>/dev/null) || strict_tool_override="true"
	fi

	if [[ "$rate_limit_behavior" == "pass" && "$completion_behavior" == "fast" && "$strict_tool_override" != "true" ]]; then
		printf '%s\n' "$RBG_PASS_ADVISORY"
		return 0
	fi

	printf '%s\n' "INFRA_RATE_LIMITED"
	return 0
}

json_escape() {
	local value="$1"
	if command -v jq >/dev/null 2>&1; then
		jq -Rn --arg value "$value" '$value'
		return 0
	fi
	value=${value//\\/\\\\}
	value=${value//\"/\\\"}
	value=${value//$'\n'/\\n}
	printf '"%s"\n' "$value"
	return 0
}

_get_rate_limit_behavior() {
	# t2123: Resolve rate-limit behavior for a specific bot on a specific repo.
	# Resolution order: per-tool > per-repo default > global env > hardcoded "pass".
	#
	# repos.json schema:
	#   "review_gate": {
	#     "rate_limit_behavior": "pass",        // per-repo default
	#     "tools": {
	#       "coderabbitai": { "rate_limit_behavior": "wait" }
	#     }
	#   }
	local repo_slug="$1"
	local bot_login="$2"
	local repos_json="${HOME}/.config/aidevops/repos.json"

	# If repos.json doesn't exist, fall through to global default
	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		# Try per-tool or per-repo setting in a single jq pass.
		# first() guards against duplicate slug entries in repos.json.
		# stderr is not suppressed so JSON syntax errors surface during debugging.
		local behavior=""
		behavior=$(jq -r --arg slug "$repo_slug" --arg bot "$bot_login" --arg retired "$RBG_RETIRED_GEMINI_LOGIN" \
			'first(.initialized_repos[]? | select(.slug == $slug)) | (if $bot == $retired then .review_gate.rate_limit_behavior // empty else .review_gate.tools[$bot].rate_limit_behavior // .review_gate.rate_limit_behavior // empty end)' \
			"$repos_json") || behavior=""
		if [[ -n "$behavior" ]]; then
			printf '%s' "$behavior"
			return 0
		fi
	fi

	# Fall through to global env (which defaults to "pass")
	printf '%s' "$REVIEW_GATE_RATE_LIMIT_BEHAVIOR"
	return 0
}

_get_completion_behavior() {
	# GH#23066: Resolve completion behavior for a specific bot on a specific repo.
	# Resolution order: per-tool > per-repo default > global env > hardcoded "fast".
	#
	# repos.json schema:
	#   "review_gate": {
	#     "completion_behavior": "strict",        // per-repo default
	#     "tools": {
	#       "coderabbitai": { "completion_behavior": "fast" }
	#     }
	#   }
	local repo_slug="$1"
	local bot_login="$2"
	local repos_json="${HOME}/.config/aidevops/repos.json"

	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		local behavior=""
		behavior=$(jq -r --arg slug "$repo_slug" --arg bot "$bot_login" --arg retired "$RBG_RETIRED_GEMINI_LOGIN" \
			'first(.initialized_repos[]? | select(.slug == $slug)) | (if $bot == $retired then .review_gate.completion_behavior // empty else .review_gate.tools[$bot].completion_behavior // .review_gate.completion_behavior // empty end)' \
			"$repos_json" 2>/dev/null) || behavior=""
		if [[ -n "$behavior" ]]; then
			printf '%s' "$behavior"
			return 0
		fi
	fi

	printf '%s' "$REVIEW_GATE_COMPLETION_BEHAVIOR"
	return 0
}

_review_gate_requires_completed_review() {
	# Add-on review is advisory by default for every author (GH#36931): review
	# bots feed follow-up issues and never hold merge progress. Explicit strict
	# completion is the single opt-in that turns missing/incomplete provider
	# evidence into a merge wait. External-contributor trust (GH#17671) is
	# enforced by exact-head maintainer crypto approval in pulse and full-loop.
	local repo_slug="$1"
	local behavior=""
	local repos_json="${HOME}/.config/aidevops/repos.json"
	local strict_tool_override="$RBG_FALSE"

	behavior=$(_get_completion_behavior "$repo_slug" "")
	[[ "$behavior" == "$RBG_COMPLETION_STRICT" ]] && return 0

	if [[ -f "$repos_json" ]] && command -v jq >/dev/null 2>&1; then
		strict_tool_override=$(jq -r --arg slug "$repo_slug" --arg strict "$RBG_COMPLETION_STRICT" --arg retired "$RBG_RETIRED_GEMINI_LOGIN" '
			[first(.initialized_repos[]? | select(.slug == $slug)).review_gate.tools // {} | to_entries[]?
			| select(.key != $retired)
			| select(.value.completion_behavior == $strict)]
			| if length > 0 then "true" else (false | tostring) end
		' "$repos_json" 2>/dev/null) || strict_tool_override="true"
	fi
	[[ "$strict_tool_override" == "true" ]] && return 0
	return 1
}

_emit_advisory_or_wait() {
	local repo_slug="$1"
	local detail="$2"

	if _review_gate_requires_completed_review "$repo_slug"; then
		echo "WAITING"
		echo "${detail}" >&2
		echo "Review completion is required by explicit strict policy." >&2
		return 1
	fi

	echo "$RBG_PASS_ADVISORY"
	echo "${detail}" >&2
	echo "Advisory default: required CI controls merge readiness; late add-on feedback is handled by the post-merge sweep." >&2
	return 0
}

_requires_success_status_completion() {
	# GH#23066: Strict completion is opt-in so high-throughput repos keep the
	# existing fast path by default. Limit the stricter requirement to two-phase
	# bots because they are the observed comment-before-status race.
	local repo_slug="$1"
	local bot_login="$2"
	local behavior
	behavior=$(_get_completion_behavior "$repo_slug" "$bot_login")
	[[ "$behavior" != "$RBG_COMPLETION_STRICT" ]] && return 1
	_is_two_phase_bot "$bot_login" && return 0
	return 1
}

_get_min_edit_lag() {
	# t2139: Resolve minimum edit-lag seconds for a specific bot on a specific
	# repo. Resolution order: per-tool > per-repo default > global env > 30.
	# Mirrors _get_rate_limit_behavior — same repos.json schema, same precedence.
	local repo_slug="$1"
	local bot_login="$2"
	local repos_json="${HOME}/.config/aidevops/repos.json"

	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		local lag=""
		lag=$(jq -r --arg slug "$repo_slug" --arg bot "$bot_login" \
			'first(.initialized_repos[] | select(.slug == $slug)) | (.review_gate.tools[$bot].min_edit_lag_seconds // .review_gate.min_edit_lag_seconds // empty)' \
			"$repos_json" 2>/dev/null) || lag=""
		# Reject non-integer or negative values silently (fall through to env).
		if [[ -n "$lag" && "$lag" =~ ^[0-9]+$ ]]; then
			printf '%s' "$lag"
			return 0
		fi
	fi

	printf '%s' "$REVIEW_BOT_MIN_EDIT_LAG_SECONDS"
	return 0
}

_is_two_phase_bot() {
	# GH#20550: Return 0 if bot_login is in TWO_PHASE_BOTS; 1 otherwise.
	# These bots post a Phase 1 placeholder and later edit with real review content.
	# Age-derived settlement is unreliable for them — only edit_delta > 0 counts.
	local bot_login="$1"
	local b
	for b in "${TWO_PHASE_BOTS[@]}"; do
		[[ "$bot_login" == "$b" ]] && return 0
	done
	return 1
}

_to_epoch() {
	# Cross-platform ISO-8601 → epoch (macOS BSD date vs GNU date). Returns 0
	# on parse failure so callers can detect "unknown" and behave conservatively.
	local iso="$1"
	[[ -z "$iso" ]] && {
		echo "0"
		return 0
	}
	local epoch
	epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null ||
		date -d "$iso" +%s 2>/dev/null ||
		echo "0")
	echo "$epoch"
	return 0
}

_comment_is_settled() {
	# t2139: A comment is "settled" (final form, safe to classify as a real
	# review) if EITHER:
	#   (a) it has been edited (updated_at >= created_at + min_lag), OR
	#   (b) it is old enough that the bot would have edited by now
	#       (now - created_at >= min_lag).
	# If timestamps are missing/unparseable (older API responses, network
	# issues), be conservative: treat as settled — better to PASS the gate
	# than block forever on missing data.
	#
	# GH#20550: For two-phase bots (e.g. coderabbitai), age-derived settlement
	# is disabled. Only edit_delta > 0 counts — a Phase 1 placeholder that has
	# aged past min_lag is still NOT a real review for two-phase bots.
	# 4th param bot_login is optional (defaults to ""); omitting it preserves
	# old non-two-phase OR semantics for all callers that don't supply it.
	local created_at="$1"
	local updated_at="$2"
	local min_lag="$3"
	local bot_login="${4:-}"

	# Missing inputs → conservative pass.
	[[ -z "$created_at" ]] && return 0
	[[ -z "$min_lag" || ! "$min_lag" =~ ^[0-9]+$ ]] && min_lag=30

	local created_epoch updated_epoch now_epoch
	created_epoch=$(_to_epoch "$created_at")
	updated_epoch=$(_to_epoch "${updated_at:-$created_at}")
	now_epoch=$(date +%s)

	# Unparseable timestamps → conservative pass.
	[[ "$created_epoch" -eq 0 ]] && return 0

	local edit_delta=$((updated_epoch - created_epoch))
	local age=$((now_epoch - created_epoch))

	if _is_two_phase_bot "$bot_login"; then
		# Phase 2 edit is authoritative; Phase 1 placeholder is not a real review
		# regardless of age. Any positive edit_delta is the settlement signal.
		[[ "$edit_delta" -gt 0 ]] && return 0
		return 1
	fi

	# Non-two-phase bots: preserve existing OR semantics.
	if [[ "$edit_delta" -ge "$min_lag" ]] || [[ "$age" -ge "$min_lag" ]]; then
		return 0
	fi
	return 1
}

_should_pass_rate_limited() {
	# t2123: Check if ALL rate-limited bots should pass (behavior=pass).
	# If ANY bot is configured to "wait", return 1 (don't pass).
	# $1 = repo slug, $2 = space-separated list of rate-limited bot logins
	local repo_slug="$1"
	local rate_limited_bots_str="$2"
	local bot behavior

	for bot in $rate_limited_bots_str; do
		[[ -z "$bot" ]] && continue
		behavior=$(_get_rate_limit_behavior "$repo_slug" "$bot")
		if [[ "$behavior" == "wait" ]]; then
			echo "Bot '${bot}' configured to wait on rate limit (review_gate config)" >&2
			return 1
		fi
	done
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

# GH#37011: function groups live in sibling modules (reference/large-file-split.md).
# Functions resolve at call time, so sourcing here is safe after the constants above.
# shellcheck source=./review-bot-gate-evidence.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _RBG_SCRIPT_DIR
source "${_RBG_SCRIPT_DIR}/review-bot-gate-evidence.sh"
# shellcheck source=./review-bot-gate-bots.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _RBG_SCRIPT_DIR
source "${_RBG_SCRIPT_DIR}/review-bot-gate-bots.sh"
# shellcheck source=./review-bot-gate-trust.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _RBG_SCRIPT_DIR
source "${_RBG_SCRIPT_DIR}/review-bot-gate-trust.sh"
# shellcheck source=./review-bot-gate-status.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _RBG_SCRIPT_DIR
source "${_RBG_SCRIPT_DIR}/review-bot-gate-status.sh"

_rbg_pr_reconciliation_snapshot() {
	local pr_number="$1"
	local repo="$2"
	local pr_json=""
	local pull_endpoint=""

	printf -v pull_endpoint 'repos/%s/pulls/%s' "$repo" "$pr_number"
	pr_json=$(gh api "$pull_endpoint" 2>/dev/null) || return 1
	printf '%s\n' "$pr_json" | jq -ce '{
		head:(.head.sha // ""),
		state:(.state // ""),
		association:(.author_association // ""),
		labels:[.labels[]? | .name // empty],
		labels_valid: ((.labels | type) == "array" and all(.labels[]?; (.name | type) == "string"))
	}' || return 1
	return 0
}

_rbg_changes_requested_reviews() {
	local pr_number="$1"
	local repo="$2"
	local reviews_json=""

	reviews_json=$(_rbg_fetch_evidence_collection "$pr_number" "$repo" reviews) || return 1
	printf '%s\n' "$reviews_json" | jq -ce '
		def state_changing: .state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED";
		if any(.[]?; state_changing and (
			(.user | type) != "object"
			or (.user.login | type) != "string"
			or (.user.login | length) == 0
			or (.submitted_at | type) != "string"
			or (.submitted_at | length) == 0
			or (.id | type) != "number"
		)) then error("malformed state-changing review")
		else map(select(state_changing))
		| group_by(.user.login)
		| map(max_by([.submitted_at, .id]))
		| map(select(.state == "CHANGES_REQUESTED")
			| {id,login:.user.login,user_type:(.user.type // ""),commit_id:(.commit_id // ""),submitted_at})
		| sort_by(.id)
		end
	' || return 1
	return 0
}

get_all_bot_commenters() {
	local pr_number="$1"
	local repo="$2"

	# Collect reviewers from three sources:
	# 1. PR reviews (formal GitHub reviews)
	local reviews
	reviews=$(_rbg_query_evidence_collection "$pr_number" "$repo" reviews \
		'.[].user.login' || echo "")

	# 2. Issue comments (some bots post as comments, not reviews)
	local comments
	comments=$(_rbg_query_evidence_collection "$pr_number" "$repo" issue-comments \
		'.[].user.login' || echo "")

	# 3. Review comments (inline code comments)
	local review_comments
	review_comments=$(_rbg_query_evidence_collection "$pr_number" "$repo" review-comments \
		'.[].user.login' || echo "")

	# Combine, deduplicate, lowercase
	echo -e "${reviews}\n${comments}\n${review_comments}" |
		tr '[:upper:]' '[:lower:]' | sort -u | grep -v '^$' || true
	return 0
}

is_non_review_comment() {
	# t2139: Check if a comment body matches any known non-review pattern
	# (rate-limit/quota notices, "Review failed", "Review skipped", etc.).
	# Returns 0 if the comment IS a non-review notice. Renamed from
	# is_rate_limit_comment for accuracy — see NON_REVIEW_PATTERNS.
	local body="$1"

	for pattern in "${NON_REVIEW_PATTERNS[@]}"; do
		if grep -qi "$pattern" <<<"$body"; then
			return 0
		fi
	done
	return 1
}

is_known_review_bot() {
	local actor="$1"
	local known_bot=""
	actor=$(printf '%s' "$actor" | tr '[:upper:]' '[:lower:]')
	actor="${actor%"[bot]"}"

	for known_bot in "${KNOWN_BOTS[@]}"; do
		[[ "$actor" == "$known_bot" ]] && return 0
	done
	return 1
}

do_event_check() {
	local event_name="${REVIEW_GATE_EVENT_NAME:-}"
	local event_action="${REVIEW_GATE_EVENT_ACTION:-}"
	local event_actor="${REVIEW_GATE_EVENT_ACTOR:-}"
	local event_body="${REVIEW_GATE_EVENT_BODY:-}"
	local review_state="${REVIEW_GATE_REVIEW_STATE:-}"
	local evidence_head="${REVIEW_GATE_EVIDENCE_HEAD_SHA:-}"
	local expected_head="${REVIEW_GATE_EXPECTED_HEAD_SHA:-}"

	if ! is_known_review_bot "$event_actor"; then
		printf 'NOT_APPLICABLE\n'
		return 1
	fi
	if [[ -z "$evidence_head" || -z "$expected_head" || "$evidence_head" != "$expected_head" ]]; then
		printf 'NOT_APPLICABLE\n'
		return 1
	fi

	case "$event_name:$event_action" in
	pull_request_review_comment:created | pull_request_review_comment:edited)
		if [[ -n "$event_body" ]] && ! is_non_review_comment "$event_body"; then
			printf 'PASS\n'
			return 0
		fi
		;;
	pull_request_review:submitted | pull_request_review:edited)
		if [[ "$review_state" == "approved" || "$review_state" == "changes_requested" ]]; then
			printf 'PASS\n'
			return 0
		fi
		if [[ -n "$event_body" ]] && ! is_non_review_comment "$event_body"; then
			printf 'PASS\n'
			return 0
		fi
		;;
	esac

	printf 'NOT_APPLICABLE\n'
	return 1
}

_rbg_is_trusted_issue_sync_pr_metadata() {
	local repo="$1"
	local pr_metadata_json="$2"
	local expected_head_sha="${3:-}"

	[[ -n "$repo" && -n "$pr_metadata_json" ]] || return 1
	command -v jq >/dev/null 2>&1 || return 1

	# GitHub assigns its official Actions bot CONTRIBUTOR association on PRs it
	# creates. Normalize only the complete deterministic Issue Sync identity.
	# Every field comes from one live REST pull payload; any parse failure or
	# missing/mismatched value remains external.
	#aidevops:trust-boundary
	jq -e \
		--arg repo "$repo" \
		--argjson bot_id "$RBG_GITHUB_ACTIONS_BOT_ID" \
		--arg branch "$RBG_ISSUE_SYNC_PR_BRANCH" \
		--arg expected_head "$expected_head_sha" \
		--arg marker "$RBG_ISSUE_SYNC_PR_MARKER" '
		try (
			.user.login == "github-actions[bot]" and
			.user.id == $bot_id and
			.user.type == "Bot" and
			.head.repo.full_name == $repo and
			.base.repo.full_name == $repo and
			.head.ref == $branch and
			(($expected_head | length) == 0 or .head.sha == $expected_head) and
			(.body | contains($marker))
		) catch false
	' <<<"$pr_metadata_json" >/dev/null 2>&1
}

_rbg_is_account_issue_sync_pr_metadata() {
	local repo="$1"
	local pr_metadata_json="$2"
	local expected_head_sha="$3"

	[[ -n "$repo" && -n "$pr_metadata_json" && -n "$expected_head_sha" ]] || return 1
	command -v jq >/dev/null 2>&1 || return 1

	#aidevops:trust-boundary -- account-authored generated updates require the
	# same immutable PR shape and exact head as bot-authored updates. Live
	# permission and changed-file evidence are checked separately below.
	jq -e \
		--arg repo "$repo" \
		--arg branch "$RBG_ISSUE_SYNC_PR_BRANCH" \
		--arg expected_head "$expected_head_sha" \
		--arg marker "$RBG_ISSUE_SYNC_PR_MARKER" '
		try (
			(.user.login | type == "string" and length > 0) and
			.user.type == "User" and
			.head.repo.full_name == $repo and
			.base.repo.full_name == $repo and
			.head.ref == $branch and
			.head.sha == $expected_head and
			(.body | contains($marker))
		) catch false
	' <<<"$pr_metadata_json" >/dev/null 2>&1
}

_rbg_is_pulse_todo_handoff_pr_metadata() {
	local repo="$1"
	local pr_metadata_json="$2"
	local expected_head_sha="$3"

	[[ -n "$repo" && -n "$pr_metadata_json" && -n "$expected_head_sha" ]] || return 1
	command -v jq >/dev/null 2>&1 || return 1

	#aidevops:trust-boundary -- GH#33955: Pulse TODO handoff PRs are generated
	# by the runner account from a snapshot-derived handoff ID. Require one
	# exact handoff marker whose ID prefix equals the deterministic branch
	# suffix, a same-repository head, and the exact current head. Live
	# permission and changed-file evidence are checked separately below.
	jq -e \
		--arg repo "$repo" \
		--arg prefix "$RBG_PULSE_TODO_HANDOFF_BRANCH_PREFIX" \
		--arg expected_head "$expected_head_sha" '
		try (
			(.user.login | type == "string" and length > 0) and
			.user.type == "User" and
			.head.repo.full_name == $repo and
			.base.repo.full_name == $repo and
			.head.sha == $expected_head and
			(.head.ref | type == "string" and startswith($prefix)) and
			(
				(.head.ref | ltrimstr($prefix)) as $suffix |
				([.body | scan("<!-- aidevops:pulse-todo-handoff id=([0-9a-f]{40}) -->") | .[0]] | unique) as $ids |
				($suffix | test("^[0-9a-f]{16}$")) and
				($ids | length) == 1 and
				($ids[0][0:16] == $suffix)
			)
		) catch false
	' <<<"$pr_metadata_json" >/dev/null 2>&1
}

# Live evidence shared by account-authored generated TODO PRs: the author must
# hold maintainer-equivalent permission now, and the complete changed-file set
# must be exactly TODO.md. With allow_added_briefs=1 (Pulse handoff only), the
# set may also contain newly added todo/tasks/tNNN-brief.md captures written by
# stale-publication repair (GH#34149); edits, deletions, renames and any other
# path stay untrusted. Returns 0 trusted, 1 untrusted, 2 API failure.
do_is_trusted_issue_sync_pr() {
	local pr_number="$1"
	local repo="$2"
	local expected_head_sha="${3:-}"
	local pr_api=""
	local pr_metadata_json=""

	pr_api=$(printf 'repos/%s/pulls/%s' "$repo" "$pr_number")
	pr_metadata_json=$(gh api "$pr_api") || {
		echo "ERROR: Could not fetch live PR metadata for Issue Sync trust classification." >&2
		return 2
	}

	if _rbg_is_trusted_issue_sync_pr_metadata "$repo" "$pr_metadata_json" "$expected_head_sha"; then
		echo "TRUSTED"
		return 0
	fi
	local account_trust_rc=0
	_rbg_is_trusted_account_issue_sync_pr "$pr_number" "$repo" "$pr_metadata_json" "$expected_head_sha" || account_trust_rc=$?
	if [[ "$account_trust_rc" -eq 0 ]]; then
		echo "TRUSTED"
		return 0
	elif [[ "$account_trust_rc" -eq 2 ]]; then
		echo "ERROR: Could not establish live account permission or complete changed-file evidence for Issue Sync trust classification." >&2
		return 2
	fi
	# GH#33955: Pulse TODO handoff PRs carry a non-closing Ref and therefore
	# have no linked-issue authority; the same exact-head, write-permission,
	# TODO.md-only evidence is their authority instead.
	local handoff_trust_rc=0
	_rbg_is_trusted_pulse_todo_handoff_pr "$pr_number" "$repo" "$pr_metadata_json" "$expected_head_sha" || handoff_trust_rc=$?
	if [[ "$handoff_trust_rc" -eq 0 ]]; then
		echo "TRUSTED"
		return 0
	elif [[ "$handoff_trust_rc" -eq 2 ]]; then
		echo "ERROR: Could not establish live account permission or complete changed-file evidence for Pulse TODO handoff trust classification." >&2
		return 2
	fi
	echo "UNTRUSTED"
	return 1
}

_resolve_pr_author_association() {
	local pr_number="$1"
	local repo="$2"
	local pr_metadata_json="${3:-}"
	local association=""
	local association_filter='if type == "object" and (.author_association | type == "string") then .author_association else empty end'
	local pr_api=""

	# Internal callers can pass the live REST pull payload they already fetched.
	# The REST association remains authoritative except for the exact official
	# Issue Sync identity independently validated above. Login, labels, or runner
	# identity alone never establish trust.
	if [[ -n "$pr_metadata_json" ]]; then
		if _rbg_is_trusted_issue_sync_pr_metadata "$repo" "$pr_metadata_json"; then
			printf '%s\n' "COLLABORATOR"
			return 0
		fi
		association=$(jq -r "$association_filter" <<<"$pr_metadata_json" 2>/dev/null) || association=""
		if [[ -n "$association" ]]; then
			printf '%s\n' "$association"
			return 0
		fi
	fi

	# GitHub CLI does not export authorAssociation through `gh pr view --json`.
	# Reuse the canonical pull REST field and collapse all API/parse failures to
	# unknown so the trust checks below continue to fail closed.
	pr_api=$(printf 'repos/%s/pulls/%s' "$repo" "$pr_number")
	pr_metadata_json=$(gh api "$pr_api" 2>/dev/null) || pr_metadata_json=""
	if _rbg_is_trusted_issue_sync_pr_metadata "$repo" "$pr_metadata_json"; then
		printf '%s\n' "COLLABORATOR"
		return 0
	fi
	association=$(jq -r "$association_filter" <<<"$pr_metadata_json" 2>/dev/null) || association=""
	printf '%s\n' "$association"
	return 0
}

check_for_skip_label() {
	local pr_number="$1"
	local repo="$2"
	local pr_metadata_json="${3:-}"

	local labels=""
	if [[ -n "$pr_metadata_json" ]] &&
		labels=$(jq -r '.labels[]?.name // empty' <<<"$pr_metadata_json" 2>/dev/null); then
		:
	else
		labels=$(gh pr view "$pr_number" --repo "$repo" \
			--json labels -q '.labels[].name' || echo "")
	fi

	if grep -q "$SKIP_LABEL" <<<"$labels"; then
		return 0
	fi
	return 1
}

match_known_bots() {
	local all_commenters="$1"
	local found_bots=""
	local missing_bots=""

	for bot in "${KNOWN_BOTS[@]}"; do
		if grep -qi "$bot" <<<"$all_commenters"; then
			found_bots="${found_bots}${bot} "
		else
			missing_bots="${missing_bots}${bot} "
		fi
	done

	echo "found:${found_bots}"
	echo "missing:${missing_bots}"
}

_collect_review_gate_bot_states() {
	local pr_number="$1"
	local repo="$2"
	local all_commenters="$3"
	local prepared_status_contexts="$4"

	REVIEW_GATE_FOUND_BOTS=""
	REVIEW_GATE_RATE_LIMITED_BOTS=""
	REVIEW_GATE_NON_REVIEW_BOTS=""

	local bot notice_category notice_rc
	for bot in "${KNOWN_BOTS[@]}"; do
		if grep -qi "$bot" <<<"$all_commenters"; then
			# Bot commented — but is it a real review or a non-review notice?
			if bot_has_real_review "$pr_number" "$repo" "$bot" "$prepared_status_contexts" true; then
				REVIEW_GATE_FOUND_BOTS="${REVIEW_GATE_FOUND_BOTS}${bot} "
			else
				if notice_category=$(bot_get_notice_category "$pr_number" "$repo" "$bot"); then
					:
				else
					notice_rc=$?
					return "$notice_rc"
				fi
				case "$notice_category" in
				rate-limit)
					REVIEW_GATE_RATE_LIMITED_BOTS="${REVIEW_GATE_RATE_LIMITED_BOTS}${bot} "
					echo "rate-limit notice (not a real review): ${bot}" >&2
					;;
				non-rate-limit | none | *)
					REVIEW_GATE_NON_REVIEW_BOTS="${REVIEW_GATE_NON_REVIEW_BOTS}${bot} "
					echo "non-review state (not rate-limited, not a real review): ${bot}" >&2
					;;
				esac
			fi
		fi
	done
	return 0
}

_emit_review_gate_check_result() {
	local pr_number="$1"
	local repo="$2"
	local prepared_status_contexts="$3"
	local pass_result="$REVIEW_GATE_STATUS_PASS"

	if [[ -n "$REVIEW_GATE_FOUND_BOTS" ]]; then
		echo "$pass_result" # nice — at least one bot posted a real review
		echo "found: ${REVIEW_GATE_FOUND_BOTS}" >&2
		return 0
	elif [[ -n "$REVIEW_GATE_NON_REVIEW_BOTS" ]] && any_bot_has_success_status "$pr_number" "$repo" "$prepared_status_contexts" true; then
		# GH#22884: Some bots expose review completion only through a SUCCESS
		# commit status after leaving a placeholder/non-review issue comment. Do
		# not bridge to a raw skip; require the bot-authored success status before
		# treating the gate as reviewed.
		echo "$pass_result"
		echo "Status check fallback: bots posted non-review states but have SUCCESS status checks" >&2
		return 0
	elif [[ -n "$REVIEW_GATE_NON_REVIEW_BOTS" ]]; then
		# Failed/skipped/placeholder states are not real reviews. They remain
		# distinct from rate limits for diagnostics, but only explicit strict
		# completion turns their absence into a merge wait.
		_emit_advisory_or_wait "$repo" \
			"Bots posted non-review states that are not rate limits: ${REVIEW_GATE_NON_REVIEW_BOTS}"
		return $?
	elif [[ -n "$REVIEW_GATE_RATE_LIMITED_BOTS" ]] && any_bot_has_success_status "$pr_number" "$repo" "$prepared_status_contexts" true; then
		# GH#3005: All bots are rate-limited in comments, but at least one
		# posted a SUCCESS commit status check. Treat as reviewed.
		echo "$pass_result"
		echo "Status check fallback: bots rate-limited but have SUCCESS status checks" >&2
		return 0
	elif [[ -n "$REVIEW_GATE_RATE_LIMITED_BOTS" ]]; then
		# GH#17549 + t2123: Bot posted a rate-limit notice — it's configured, it
		# tried, but capacity is out of our control. Behavior is configurable:
		# "pass" (default) exits 0 immediately; "wait" returns WAITING so the
		# gate retry loop keeps polling. Note: bots do NOT review post-merge
		# (CodeRabbit posts "Review failed — The pull request is closed" and
		# stops). The daily quality sweep provides codebase-level coverage.
		# Configure per-tool or per-repo via repos.json review_gate, or globally
		# via REVIEW_GATE_RATE_LIMIT_BEHAVIOR env var.
		if _review_gate_requires_completed_review "$repo"; then
			echo "WAITING"
			echo "Bots are rate-limited and completed review evidence is explicitly required: ${REVIEW_GATE_RATE_LIMITED_BOTS}" >&2
			return 1
		elif _should_pass_rate_limited "$repo" "$REVIEW_GATE_RATE_LIMITED_BOTS"; then
			echo "$RBG_PASS_RATE_LIMITED"
			echo "Bots are rate-limited (tried but capacity-constrained): ${REVIEW_GATE_RATE_LIMITED_BOTS}" >&2
			echo "Passing gate — configured to pass on rate limit (review_gate.rate_limit_behavior=pass)." >&2
			return 0
		else
			echo "WAITING"
			echo "Bots are rate-limited but configured to wait: ${REVIEW_GATE_RATE_LIMITED_BOTS}" >&2
			echo "Gate will keep polling — set review_gate.rate_limit_behavior=pass to skip." >&2
			return 1
		fi
	else
		_emit_advisory_or_wait "$repo" "No review bots found yet. Known bots: ${KNOWN_BOTS[*]}"
		return $?
	fi
}

do_check() {
	local pr_number="$1"
	local repo="$2"
	local pr_metadata_json="${3:-}"
	local REVIEW_GATE_AUTHOR_ASSOCIATION="${REVIEW_GATE_AUTHOR_ASSOCIATION:-}"
	local result_rc=0
	# These caller-local accumulators are populated/read by helpers through Bash
	# dynamic scoping; keep targeted ShellCheck suppressions beside each local.
	# shellcheck disable=SC2034
	local REVIEW_GATE_FOUND_BOTS=""
	# shellcheck disable=SC2034
	local REVIEW_GATE_RATE_LIMITED_BOTS=""
	# shellcheck disable=SC2034
	local REVIEW_GATE_NON_REVIEW_BOTS=""
	_rbg_reset_evidence_snapshot

	if [[ "${REVIEW_GATE_AUTHOR_ASSOCIATION_RESOLVED:-false}" != "true" ]]; then
		case "$REVIEW_GATE_AUTHOR_ASSOCIATION" in
		OWNER | MEMBER | COLLABORATOR) ;;
		*)
			local resolved_author_association=""
			resolved_author_association=$(_resolve_pr_author_association \
				"$pr_number" "$repo" "$pr_metadata_json")
			[[ -n "$resolved_author_association" ]] &&
				REVIEW_GATE_AUTHOR_ASSOCIATION="$resolved_author_association"
			;;
		esac
	fi

	# #aidevops:trust-boundary — skip labels are an internal exception. Resolve
	# immutable author trust before honoring one so every caller, not only the
	# reusable workflow, fails closed for external or unknown authors.
	if check_for_skip_label "$pr_number" "$repo" "$pr_metadata_json"; then
		case "$REVIEW_GATE_AUTHOR_ASSOCIATION" in
		OWNER | MEMBER | COLLABORATOR)
			echo "SKIP"
			return 0
			;;
		esac
		echo "WAITING"
		echo "skip-review-gate denied for external or unknown author association." >&2
		return 1
	fi

	if [[ "${REVIEW_GATE_EVIDENCE_SNAPSHOT_DISABLE:-0}" != "1" ]]; then
		if ! _rbg_prepare_evidence_snapshot "$pr_number" "$repo"; then
			echo "Review evidence snapshot unavailable for PR #${pr_number}; falling back to direct endpoint queries." >&2
			_rbg_reset_evidence_snapshot
		fi
	fi

	local all_commenters
	all_commenters=$(get_all_bot_commenters "$pr_number" "$repo")

	local status_contexts
	status_contexts=$(_get_success_status_contexts "$pr_number" "$repo" || true)
	local prepared_status_contexts=""
	if [[ -n "$status_contexts" ]]; then
		prepared_status_contexts=$(_prepare_success_status_contexts "$status_contexts" || true)
	fi

	if _collect_review_gate_bot_states "$pr_number" "$repo" "$all_commenters" "$prepared_status_contexts"; then
		:
	else
		result_rc=$?
		_rbg_reset_evidence_snapshot
		return "$result_rc"
	fi
	_emit_review_gate_check_result "$pr_number" "$repo" "$prepared_status_contexts" || result_rc=$?
	_rbg_reset_evidence_snapshot
	return "$result_rc"
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

		if [[ "$result" == "$REVIEW_GATE_STATUS_PASS" || "$result" == "$RBG_PASS_ADVISORY" || "$result" == "$RBG_PASS_RATE_LIMITED" || "$result" == "SKIP" ]]; then
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

	# t2139: Show classification per bot — disambiguate "not-yet" (placeholder)
	# from "non-review-only" (rate-limit / failure / skip notice).
	local state
	for bot in "${KNOWN_BOTS[@]}"; do
		if grep -qi "$bot" <<<"$all_commenters"; then
			state=$(_classify_bot_state "$pr_number" "$repo" "$bot")
			case "$state" in
			real-review)
				echo "  ${bot}: real review"
				;;
			not-yet)
				echo "  ${bot}: not yet (placeholder — waiting for Phase 2 edit)"
				;;
			non-review-only)
				echo "  ${bot}: rate-limited / no-review notice (no real review)"
				;;
			no-comments)
				echo "  ${bot}: commented per index but body unavailable"
				;;
			esac
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
	# Superseded reviews must not suppress recovery for the current head.
	local pr_number="$1"
	local repo="$2"
	local head_sha="$3"

	# Emit matches rather than per-page counts: direct queries are paginated.
	local matching_reviews
	matching_reviews=$(_rbg_query_evidence_collection "$pr_number" "$repo" reviews \
		".[] | select(.commit_id == \"${head_sha}\") | .commit_id") || return 2
	if [[ -n "$matching_reviews" ]]; then
		return 0
	fi
	return 1
}

has_retry_comment() {
	# Legacy PR-wide markers cannot identify the head they requested.
	local pr_number="$1"
	local repo="$2"
	local head_sha="$3"

	local marker="<!-- review-bot-retry-requested head=${head_sha} -->"
	local comments
	comments=$(_rbg_query_evidence_collection "$pr_number" "$repo" issue-comments \
		'.[].body') || return 2
	if grep -qF "$marker" <<<"$comments"; then
		return 0
	fi
	return 1
}

find_rate_limited_bots() {
	# Return space-separated list of bots that posted only non-review notices
	# (rate-limit, "Review failed", "Review skipped", etc.).
	# t2799: name is a legacy holdover — covers all non-review states, not
	# just rate-limited. Kept for backwards compat with callers and the
	# request-retry flow.
	local pr_number="$1"
	local repo="$2"

	local all_commenters
	all_commenters=$(get_all_bot_commenters "$pr_number" "$repo")

	local rate_limited=""
	local bot
	for bot in "${KNOWN_BOTS[@]}"; do
		if grep -qi "$bot" <<<"$all_commenters"; then
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

	# Always resolve the live head, not a caller's possibly stale expected head.
	local head_sha
	head_sha=$(gh pr view "$pr_number" --repo "$repo" --json headRefOid --jq '.headRefOid' 2>/dev/null) || return 2
	if [[ ! "$head_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
		echo "ERROR: Cannot resolve current PR head for retry." >&2
		return 2
	fi
	local REVIEW_GATE_EXPECTED_HEAD_SHA="$head_sha"
	local evidence_rc=0

	# Only formal reviews of this exact head suppress a retry.
	if has_formal_reviews "$pr_number" "$repo" "$head_sha"; then
		echo "HAS_REVIEWS"
		echo "PR current head already has formal reviews — no retry needed." >&2
		return 0
	else
		evidence_rc=$?
		[[ "$evidence_rc" -eq 1 ]] || return 2
	fi

	# If we already requested a retry, don't spam
	if has_retry_comment "$pr_number" "$repo" "$head_sha"; then
		echo "ALREADY_REQUESTED"
		echo "Retry already requested on PR #${pr_number} head ${head_sha} — waiting for bot response." >&2
		return 0
	else
		evidence_rc=$?
		[[ "$evidence_rc" -eq 1 ]] || return 2
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
	comment_body="<!-- review-bot-retry-requested head=${head_sha} -->
@coderabbitai review

Review bots were rate-limited when this PR was created (affected: ${rate_limited_bots% }). Requesting a review retry."

	# go for it — safe to request retry since we already checked idempotency
	if gh_pr_comment "$pr_number" --repo "$repo" --body "$comment_body" >/dev/null 2>&1; then
		echo "REQUESTED"
		echo "Requested review retry on PR #${pr_number} (rate-limited bots: ${rate_limited_bots% })." >&2
		return 0
	else
		echo "ERROR: Failed to post retry comment on PR #${pr_number}." >&2
		return 2
	fi
}

do_batch_retry() {
	# GH#3932: Process open PRs lacking current-head reviews, request retries
	# for rate-limited ones. Staggers requests with a delay between each to
	# avoid re-triggering CodeRabbit's hourly rate limit.
	#
	# Returns summary: REQUESTED_N (where N is the count of retries requested)
	local repo="$1"
	local stagger_seconds="${BATCH_RETRY_STAGGER:-5}"

	echo "Scanning open PRs in ${repo} for rate-limited reviews..." >&2

	# Historical reviews must not exclude a PR; request-retry checks its live head.
	local pr_numbers
	pr_numbers=$(gh pr list --repo "$repo" --state open --limit 100 \
		--json number --jq '.[].number' || echo "")

	if [[ -z "$pr_numbers" ]]; then
		echo "NO_ACTION"
		echo "No open PRs found." >&2
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

	if [[ "$command" == "event-check" ]]; then
		do_event_check
		return $?
	fi

	if [[ "$command" == "classify-infra-rate-limit" ]]; then
		local author_association="${2:-}"
		local infra_repo="${3:-}"
		if [[ -z "$author_association" || -z "$infra_repo" ]]; then
			echo "ERROR: classify-infra-rate-limit requires AUTHOR_ASSOCIATION and REPO." >&2
			return 2
		fi
		classify_infra_rate_limit "$author_association" "$infra_repo"
		return $?
	fi

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
	is-trusted-issue-sync-pr)
		do_is_trusted_issue_sync_pr "$pr_number" "$repo" "$max_wait"
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
	status-json)
		do_status_json "$pr_number" "$repo"
		;;
	reconcile-stale-coderabbit)
		do_reconcile_coderabbit_reviews "$RBG_RECONCILE_MODE_SUPERSEDED" "$pr_number" "$repo" "$max_wait"
		;;
	dismiss-coderabbit-nits)
		do_reconcile_coderabbit_reviews "$RBG_RECONCILE_MODE_NITS" "$pr_number" "$repo"
		;;
	dismiss-advisory-coderabbit)
		do_reconcile_coderabbit_reviews "$RBG_RECONCILE_MODE_ADVISORY" "$pr_number" "$repo"
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
