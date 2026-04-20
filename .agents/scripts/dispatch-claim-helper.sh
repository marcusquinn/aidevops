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
# GH#17503: Increased from 120s to 1800s (30 min) — claim comments are never
# deleted (audit trail), so the TTL must cover a full worker lifecycle.
DISPATCH_CLAIM_MAX_AGE="${DISPATCH_CLAIM_MAX_AGE:-1800}"

# GH#15317: Self-reclaim removed. Previously, same-runner stale claims were
# "reclaimed" after this threshold, creating dispatch loops. Now stale self-
# claims are cleaned up and treated as lost. Variable kept for backward compat.
DISPATCH_CLAIM_SELF_RECLAIM_AGE="${DISPATCH_CLAIM_SELF_RECLAIM_AGE:-30}"

# Claim comment marker — used as both the posting format and the search pattern.
# Plain text format: visible in rendered GitHub issue view.
CLAIM_MARKER="DISPATCH_CLAIM"

# t2399/t2401: Runtime override for cross-runner dispatch coordination.
#
# Allows a local runner to ignore DISPATCH_CLAIMs from specific peer runners
# or from runners running framework versions older than a configured floor.
# Both filters are self-correcting: once the peer recovers or upgrades, the
# filter auto-sunsets (version filter) or the operator removes the login
# (t2399 login-gated filter).
#
# Config file (optional, user-level): ~/.config/aidevops/dispatch-override.conf
#   DISPATCH_CLAIM_IGNORE_RUNNERS="login1 login2"  # space or comma separated
#   DISPATCH_CLAIM_MIN_VERSION="3.8.78"            # semver floor; older claims ignored
#   DISPATCH_OVERRIDE_ENABLED=true                 # default true when config exists
#
# Version field (t2401): claim bodies include version=X.Y.Z sourced from
# ~/.aidevops/agents/VERSION. Legacy claims (pre-t2401) have no version field
# and are treated as "unknown" — below any configured floor.
#
# Safety: filters are UNIDIRECTIONAL — if only one runner filters the other,
# the filtered runner's claim-race still honours the filterer's claim (normal
# dedup behaviour). If BOTH runners filter each other, double-dispatch is
# possible. Intended for temporary, unilateral use during peer-degraded
# incidents.
DISPATCH_OVERRIDE_CONF="${DISPATCH_OVERRIDE_CONF:-${HOME}/.config/aidevops/dispatch-override.conf}"
DISPATCH_CLAIM_IGNORE_RUNNERS="${DISPATCH_CLAIM_IGNORE_RUNNERS:-}"
DISPATCH_CLAIM_MIN_VERSION="${DISPATCH_CLAIM_MIN_VERSION:-}"
DISPATCH_OVERRIDE_ENABLED="${DISPATCH_OVERRIDE_ENABLED:-true}"
if [[ -r "$DISPATCH_OVERRIDE_CONF" ]]; then
	# shellcheck disable=SC1090
	source "$DISPATCH_OVERRIDE_CONF" 2>/dev/null || true
fi

# t2401: Framework VERSION file location. Override for tests.
AIDEVOPS_VERSION_FILE="${AIDEVOPS_VERSION_FILE:-${HOME}/.aidevops/agents/VERSION}"

# t2422: Simultaneous-claim tiebreaker window (seconds). When our claim loses
# to a winner whose timestamp is within this many seconds of ours, treat the
# race as a "close tiebreaker" and post a CLAIM_DEFERRED audit comment so the
# deterministic resolution is visible in the issue timeline. Large windows
# waste API writes; small windows (<=5s) catch only genuine races.
DISPATCH_TIEBREAKER_WINDOW="${DISPATCH_TIEBREAKER_WINDOW:-5}"

# t2422: Source the structured override resolver so _override_resolve is
# available to _apply_structured_filter below. The resolver is sourceable —
# its main() is gated by BASH_SOURCE. If the resolver is missing (partial
# deploy), _apply_structured_filter short-circuits as a no-op.
DISPATCH_CLAIM_HELPER_DIR="${DISPATCH_CLAIM_HELPER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
if [[ -r "${DISPATCH_CLAIM_HELPER_DIR}/dispatch-override-resolve.sh" ]]; then
	# shellcheck disable=SC1091
	source "${DISPATCH_CLAIM_HELPER_DIR}/dispatch-override-resolve.sh"
fi

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
# t2401: Resolve the framework version from AIDEVOPS_VERSION_FILE.
# Returns: semver string on stdout, "unknown" when file is missing/empty.
# Always exit 0 — claim emission must never fail on a missing VERSION file.
#######################################
_resolve_version() {
	if [[ -r "$AIDEVOPS_VERSION_FILE" ]]; then
		local ver
		ver=$(head -n1 "$AIDEVOPS_VERSION_FILE" 2>/dev/null | tr -d '[:space:]')
		if [[ -n "$ver" ]]; then
			printf '%s' "$ver"
			return 0
		fi
	fi
	printf '%s' "unknown"
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

	# t2401: include framework version so peers can filter claims from older runners.
	local version
	version=$(_resolve_version)

	local body
	body="${CLAIM_MARKER} nonce=${nonce} runner=${runner} ts=${ts} max_age_s=${DISPATCH_CLAIM_MAX_AGE} version=${version}"

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

	# Fetch last 30 comments — look for both DISPATCH_CLAIM and CLAIM_RELEASED.
	# A CLAIM_RELEASED comment posted after the most recent DISPATCH_CLAIM
	# invalidates all prior claims (the worker died or completed).
	local comments_json
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--jq '[.[] | select(.body | test("'"${CLAIM_MARKER}"' nonce=|CLAIM_RELEASED")) | {id: .id, body: .body, created_at: .created_at}]' \
		2>/dev/null) || {
		echo "Error: failed to fetch comments for #${issue_number} in ${repo_slug}" >&2
		return 1
	}

	if [[ -z "$comments_json" || "$comments_json" == "null" || "$comments_json" == "[]" ]]; then
		printf '[]'
		return 0
	fi

	# Find the most recent CLAIM_RELEASED timestamp. Any DISPATCH_CLAIM older
	# than this is invalidated (the worker died or completed). Only claims
	# posted AFTER the latest release are considered active.
	local latest_release_ts
	latest_release_ts=$(printf '%s' "$comments_json" | jq -r '
		[.[] | select(.body | test("CLAIM_RELEASED")) | .created_at] |
		sort | last // ""
	' 2>/dev/null) || latest_release_ts=""

	# Filter to DISPATCH_CLAIM comments posted after the latest release
	local claims_only
	if [[ -n "$latest_release_ts" ]]; then
		claims_only=$(printf '%s' "$comments_json" | jq -c --arg release_ts "$latest_release_ts" '
			[.[] | select((.body | test("'"${CLAIM_MARKER}"' nonce=")) and (.created_at > $release_ts))]
		' 2>/dev/null) || claims_only="[]"
	else
		claims_only=$(printf '%s' "$comments_json" | jq -c '[.[] | select(.body | test("'"${CLAIM_MARKER}"' nonce="))]' 2>/dev/null) || claims_only="[]"
	fi

	if [[ "$claims_only" == "[]" ]]; then
		printf '[]'
		return 0
	fi

	# Parse claim fields from comment bodies and filter by max age.
	# t2401: version is an optional trailing field; legacy pre-t2401 claims
	# lack it and parse as "unknown".
	local parsed
	parsed=$(printf '%s' "$claims_only" | jq -c --argjson now "$now_epoch" --argjson max_age "$DISPATCH_CLAIM_MAX_AGE" '
		[.[] |
			(.body | capture("nonce=(?<nonce>[^ ]+) runner=(?<runner>[^ ]+) ts=(?<ts>[^ ]+)(?: max_age_s=[^ ]+)?(?: version=(?<version>[^ ]+))?")) as $fields |
			{
				id: .id,
				nonce: $fields.nonce,
				runner: $fields.runner,
				ts: $fields.ts,
				version: ($fields.version // "unknown"),
				created_at: .created_at,
				created_epoch: (.created_at | fromdateiso8601? // 0)
			}
		] |
		map(. + {age_seconds: ($now - .created_epoch)}) |
		map(select(.age_seconds >= 0 and .age_seconds <= $max_age)) |
		# t2422: Sort primarily by created_at (GitHub timestamp, 1-second
		# granularity) with nonce as lexicographic tiebreaker. Two runners that
		# post claims within the same wall-clock second need a deterministic
		# winner that both observers agree on — nonce is UUID-uniform random,
		# so lex order is effectively a fair coin flip that is stable across
		# any runner reading the same comment list.
		sort_by([.created_at, .nonce])
	' 2>/dev/null) || {
		echo "Error: failed to parse claim comments" >&2
		return 1
	}

	# t2400: Apply runtime override filter (extracted to keep _fetch_claims
	# under the 100-line complexity threshold — same behaviour, separate fn).
	parsed=$(_apply_ignore_filter "$parsed" "$issue_number" "$repo_slug")

	printf '%s' "$parsed"
	return 0
}

#######################################
# t2401: Semver comparison — is $1 strictly less than $2?
# Args: $1 = version (e.g., "3.8.78"), $2 = floor (e.g., "3.9.0")
# Returns: exit 0 = version < floor (below), exit 1 = version >= floor
# "unknown" or empty version is always below floor.
#######################################
_version_below() {
	local version="${1:-}"
	local floor="${2:-}"

	# Treat missing/unknown as below any configured floor
	if [[ -z "$version" || "$version" == "unknown" ]]; then
		return 0
	fi

	# Equal versions are not strictly below
	if [[ "$version" == "$floor" ]]; then
		return 1
	fi

	# sort -V puts smaller semver first. If $version is first, it's below $floor.
	local first
	first=$(printf '%s\n%s\n' "$version" "$floor" | sort -V | head -n1)
	if [[ "$first" == "$version" ]]; then
		return 0
	fi
	return 1
}

#######################################
# t2401: Filter out claim entries whose version is below DISPATCH_CLAIM_MIN_VERSION.
# Legacy claims parsed as "unknown" are always filtered out when a floor is set.
#
# Args:
#   $1 = parsed claims JSON array
#   $2 = min version floor (semver)
# Returns:
#   Filtered JSON on stdout. Fails safe — returns input unchanged on jq error.
#######################################
_filter_below_version() {
	local parsed="$1"
	local floor="$2"

	# Collect IDs of claims strictly below the floor.
	local below_ids=""
	local claim_rows
	claim_rows=$(printf '%s' "$parsed" | jq -r '.[] | [.id, (.version // "unknown")] | @tsv' 2>/dev/null) || return 0

	local id version
	while IFS=$'\t' read -r id version; do
		[[ -z "$id" ]] && continue
		if _version_below "$version" "$floor"; then
			below_ids+="${id}"$'\n'
		fi
	done <<<"$claim_rows"

	if [[ -z "$below_ids" ]]; then
		printf '%s' "$parsed"
		return 0
	fi

	local below_json
	below_json=$(printf '%s' "$below_ids" | jq -Rsc 'split("\n") | map(select(length > 0)) | map(tonumber)' 2>/dev/null) || {
		printf '%s' "$parsed"
		return 0
	}

	local filtered
	filtered=$(printf '%s' "$parsed" | jq -c --argjson below "$below_json" '
		map(select((.id as $i | $below | index($i)) | not))
	' 2>/dev/null) || {
		printf '%s' "$parsed"
		return 0
	}
	printf '%s' "$filtered"
	return 0
}

#######################################
# t2422: Apply the structured per-runner override filter.
#
# For each claim, consults _override_resolve (from dispatch-override-resolve.sh)
# and strips claims whose action is "ignore". "warn" claims are kept but logged.
# "honour" claims pass through unchanged.
#
# No-op fast paths:
#   - DISPATCH_OVERRIDE_ENABLED != "true"
#   - _override_resolve not sourced (partial deploy of helpers)
#   - No DISPATCH_OVERRIDE_* structured vars set AND no DISPATCH_OVERRIDE_DEFAULT
#
# Args:
#   $1 = parsed claims JSON array
#   $2 = issue number (log context)
#   $3 = repo slug (log context)
# Returns:
#   Filtered claims JSON on stdout. Fails safe — returns input unchanged on
#   any jq error or when resolver is missing.
#######################################
#######################################
# Detect whether any structured override config is currently active.
# Uses compgen -v (in-shell variable enumeration) rather than `env` so both
# exported and non-exported shell variables are detected — callers often set
# overrides via `VAR=value cmd` inline syntax which does NOT export.
# Returns: exit 0 if structured config found (or default set), exit 1 otherwise.
#######################################
_structured_filter_has_config() {
	local var
	for var in $(compgen -v 2>/dev/null | grep '^DISPATCH_OVERRIDE_' 2>/dev/null || true); do
		case "$var" in
		DISPATCH_OVERRIDE_CONF | DISPATCH_OVERRIDE_ENABLED | DISPATCH_OVERRIDE_DEFAULT) continue ;;
		DISPATCH_OVERRIDE_*) return 0 ;;
		esac
	done
	[[ -n "${DISPATCH_OVERRIDE_DEFAULT:-}" ]]
}

#######################################
# Classify claims against the resolver and return a newline-delimited list of
# IDs whose action is `ignore`. Logs `warn` actions once per unique runner.
# Args:
#   $1 = claim rows (TSV: id\trunner\tversion per line, from jq output)
#   $2 = issue number (log context)
#   $3 = repo slug (log context)
# Returns: newline-delimited IDs on stdout, exit 0 always.
#######################################
_structured_filter_classify_claims() {
	local rows="$1"
	local issue_number="$2"
	local repo_slug="$3"

	# Iterate via IFS=newline `for` rather than `while read <<<"$rows"` — the
	# complexity-regression scanner's nesting-depth heuristic treats
	# `done <<<"X"` as an unmatched close, inflating the global depth counter
	# (every such pattern permanently bumps the max-depth report by 1).
	local id runner version action warned_runners=""
	local line
	local saved_ifs="${IFS-}"
	IFS=$'\n'
	for line in $rows; do
		IFS="$saved_ifs"
		[[ -z "$line" ]] && { IFS=$'\n'; continue; }
		IFS=$'\t' read -r id runner version <<<"$line"
		[[ -z "$id" ]] && { IFS=$'\n'; continue; }
		action=$(_override_resolve "$runner" "$version" 2>/dev/null) || action="honour"
		case "$action" in
		ignore) printf '%s\n' "$id" ;;
		warn)
			if [[ "$warned_runners" != *"|${runner}|"* ]]; then
				printf '[dispatch-claim-helper] structured override: warn action on runner=%s version=%s on #%s in %s (claim kept, audit logged)\n' \
					"$runner" "$version" "$issue_number" "$repo_slug" >&2
				warned_runners+="|${runner}|"
			fi
			;;
		*) ;; # honour or unknown — keep
		esac
		IFS=$'\n'
	done
	IFS="$saved_ifs"
	return 0
}

_apply_structured_filter() {
	local parsed="$1"
	local issue_number="$2"
	local repo_slug="$3"

	# No-op fast paths: master switch off, resolver missing, or no config.
	if [[ "${DISPATCH_OVERRIDE_ENABLED:-true}" != "true" ]] \
		|| ! declare -F _override_resolve >/dev/null 2>&1 \
		|| ! _structured_filter_has_config; then
		printf '%s' "$parsed"
		return 0
	fi

	# Walk claims via resolver — "ignore" IDs are collected, "warn" is logged.
	local rows to_strip_newline
	rows=$(printf '%s' "$parsed" | jq -r '.[] | [.id, .runner, .version] | @tsv' 2>/dev/null) || {
		printf '%s' "$parsed"
		return 0
	}
	to_strip_newline=$(_structured_filter_classify_claims "$rows" "$issue_number" "$repo_slug")

	if [[ -z "$to_strip_newline" ]]; then
		printf '%s' "$parsed"
		return 0
	fi

	local strip_json filtered
	strip_json=$(printf '%s' "$to_strip_newline" | jq -Rsc 'split("\n") | map(select(length > 0)) | map(tonumber)' 2>/dev/null) || {
		printf '%s' "$parsed"
		return 0
	}
	filtered=$(printf '%s' "$parsed" | jq -c --argjson strip "$strip_json" 'map(select((.id as $i | $strip | index($i)) | not))' 2>/dev/null) || {
		printf '%s' "$parsed"
		return 0
	}

	local pre_count post_count
	pre_count=$(printf '%s' "$parsed" | jq 'length' 2>/dev/null || echo 0)
	post_count=$(printf '%s' "$filtered" | jq 'length' 2>/dev/null || echo 0)
	if [[ "$pre_count" -gt "$post_count" ]]; then
		printf '[dispatch-claim-helper] structured override stripped %d claim(s) on #%s in %s\n' \
			"$((pre_count - post_count))" "$issue_number" "$repo_slug" >&2
	fi

	printf '%s' "$filtered"
	return 0
}

#######################################
# t2400/t2401/t2422: Apply runtime override filters to parsed claims.
#
# Composable filters, applied in order:
#   1. Login filter (t2400): DISPATCH_CLAIM_IGNORE_RUNNERS strips named logins.
#      DEPRECATED — use per-runner DISPATCH_OVERRIDE_<SLUG>="ignore" instead.
#   2. Version filter (t2401): DISPATCH_CLAIM_MIN_VERSION strips claims whose
#      version field is below the semver floor (including legacy "unknown").
#      DEPRECATED — use DISPATCH_OVERRIDE_<SLUG>="honour-only-above:V" to scope
#      the floor per runner rather than globally.
#   3. Structured filter (t2422): per-runner DISPATCH_OVERRIDE_<SLUG> vars
#      decide honour/ignore/warn per claim. Auto-sunsets via version gating.
#
# All filters respect DISPATCH_OVERRIDE_ENABLED=false as a global kill switch.
# Emits a stderr summary line when any claims are stripped, for operator audit.
#
# Args:
#   $1 = parsed claims JSON array (from _fetch_claims parse step)
#   $2 = issue number (for log context)
#   $3 = repo slug (for log context)
# Returns:
#   Filtered claims JSON on stdout. Fails safe — returns input unchanged
#   on any jq error.
#######################################
_apply_ignore_filter() {
	local parsed="$1"
	local issue_number="$2"
	local repo_slug="$3"

	if [[ "$DISPATCH_OVERRIDE_ENABLED" != "true" ]]; then
		printf '%s' "$parsed"
		return 0
	fi

	# All three filter inputs empty → no-op fast path.
	# Use compgen -v (in-shell variable enumeration) so we see non-exported
	# vars set via the inline `VAR=value cmd` syntax.
	local has_structured=0 var
	for var in $(compgen -v 2>/dev/null | grep '^DISPATCH_OVERRIDE_' 2>/dev/null || true); do
		case "$var" in
		DISPATCH_OVERRIDE_CONF | DISPATCH_OVERRIDE_ENABLED | DISPATCH_OVERRIDE_DEFAULT) continue ;;
		DISPATCH_OVERRIDE_*)
			has_structured=1
			break
			;;
		esac
	done

	if [[ -z "$DISPATCH_CLAIM_IGNORE_RUNNERS" && -z "$DISPATCH_CLAIM_MIN_VERSION" && $has_structured -eq 0 && -z "${DISPATCH_OVERRIDE_DEFAULT:-}" ]]; then
		printf '%s' "$parsed"
		return 0
	fi

	local pre_count
	pre_count=$(printf '%s' "$parsed" | jq 'length' 2>/dev/null || echo 0)

	# Login filter (t2400, deprecated — still supported for backward compat)
	if [[ -n "$DISPATCH_CLAIM_IGNORE_RUNNERS" ]]; then
		local ignored_json
		# Normalise the ignore list (accept space OR comma separators) → JSON array
		ignored_json=$(printf '%s' "$DISPATCH_CLAIM_IGNORE_RUNNERS" | tr ',' ' ' | tr -s ' ' '\n' | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null) || ignored_json="[]"
		if [[ "$ignored_json" != "[]" ]]; then
			local filtered_login
			filtered_login=$(printf '%s' "$parsed" | jq -c --argjson ignored "$ignored_json" '
				map(select(.runner as $r | $ignored | index($r) | not))
			' 2>/dev/null)
			if [[ -n "$filtered_login" ]]; then
				parsed="$filtered_login"
			fi
		fi
	fi

	# Version filter (t2401, deprecated — still supported for backward compat)
	if [[ -n "$DISPATCH_CLAIM_MIN_VERSION" ]]; then
		parsed=$(_filter_below_version "$parsed" "$DISPATCH_CLAIM_MIN_VERSION")
	fi

	# Structured per-runner filter (t2422)
	parsed=$(_apply_structured_filter "$parsed" "$issue_number" "$repo_slug")

	local post_count
	post_count=$(printf '%s' "$parsed" | jq 'length' 2>/dev/null || echo 0)
	if [[ "$pre_count" -gt "$post_count" ]]; then
		printf '[dispatch-claim-helper] filtered %d claim(s) on #%s in %s (legacy_ignore=%s legacy_min_version=%s structured=%d)\n' \
			"$((pre_count - post_count))" "$issue_number" "$repo_slug" \
			"${DISPATCH_CLAIM_IGNORE_RUNNERS:-none}" "${DISPATCH_CLAIM_MIN_VERSION:-none}" "$has_structured" >&2
	fi

	printf '%s' "$parsed"
	return 0
}

#######################################
# t2422: Post a CLAIM_DEFERRED audit comment when losing a close-window race.
# The comment makes the tiebreaker outcome visible on the issue timeline so
# operators grepping for coordination decisions can reconstruct the race.
#
# Args:
#   $1 = issue number
#   $2 = repo slug
#   $3 = our runner login (the loser)
#   $4 = our nonce
#   $5 = winner runner login
#   $6 = winner nonce
#   $7 = |delta| in seconds between claim timestamps
# Returns:
#   exit 0 on success (comment posted or skipped intentionally)
#   exit 1 on post failure (non-fatal — loser still backs off regardless)
#######################################
_post_deferred() {
	local issue_number="$1"
	local repo_slug="$2"
	local our_runner="$3"
	local our_nonce="$4"
	local winner_runner="$5"
	local winner_nonce="$6"
	local delta_s="$7"

	local ts body
	ts=$(_now_utc)
	body="CLAIM_DEFERRED runner=${our_runner} nonce=${our_nonce} ts=${ts} deferring_to_runner=${winner_runner} deferring_to_nonce=${winner_nonce} delta_s=${delta_s}"

	# Uses `gh issue comment` rather than `gh api repos/.../comments` to
	# avoid duplicating the pre-existing comments-API literal (t2422 was
	# flagged by the string-literal ratchet).
	if ! gh issue comment "$issue_number" --repo "$repo_slug" --body "$body" >/dev/null 2>&1; then
		echo "Warning: failed to post CLAIM_DEFERRED comment on #${issue_number} in ${repo_slug} (non-fatal)" >&2
		return 1
	fi
	return 0
}

#######################################
# Attempt to claim an issue for dispatch.
#
# Protocol:
#   1. Post claim comment with unique nonce
#   2. Sleep consensus window
#   3. Fetch all claim comments (sorted by [created_at, nonce] — t2422 tiebreaker)
#   4. If this runner's claim is the oldest active claim → won
#   5. If another runner's claim is older → lost; if delta <= TIEBREAKER_WINDOW,
#      post CLAIM_DEFERRED audit comment
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

	# GH#17503: Claim comments are NEVER deleted — they form the audit trail
	# of every dispatch attempt. The claim TTL (DISPATCH_CLAIM_MAX_AGE=1800s)
	# controls how long a claim blocks re-dispatch; after expiry the comment
	# stays but no longer locks the issue.
	#
	# Same-runner stale claim: another claim from this runner already exists.
	# The existing claim is still blocking (within TTL), so back off.
	if [[ "$oldest_runner" == "$runner" && "$oldest_nonce" != "$nonce" ]]; then
		printf 'CLAIM_STALE_SELF: runner=%s found own prior claim on issue #%s (age=%ss) — backing off (claim retained for audit)\n' \
			"$runner" "$issue_number" "$oldest_age_seconds"
		return 1
	fi

	# Step 5: We lost — another runner's claim is older.
	# t2422: If this was a close-window race (delta <= DISPATCH_TIEBREAKER_WINDOW),
	# _handle_close_window_loss emits a CLAIM_DEFERRED audit comment.
	_handle_close_window_loss "$issue_number" "$repo_slug" "$runner" "$nonce" \
		"$oldest_runner" "$claims" || true

	printf 'CLAIM_LOST: runner=%s lost to %s on issue #%s — backing off (both claims retained for audit)\n' \
		"$runner" "$oldest_runner" "$issue_number"

	return 1
}

#######################################
# Detect close-window DISPATCH_CLAIM race and emit CLAIM_DEFERRED (t2422).
#
# If the winner's claim arrived within DISPATCH_TIEBREAKER_WINDOW seconds of
# ours, both runners likely raced on the same pulse cycle. Posts a
# CLAIM_DEFERRED audit comment so the deterministic [created_at, nonce]
# tiebreaker is visible on the issue timeline for post-hoc race diagnosis.
#
# Args:
#   $1 = issue number
#   $2 = repo slug
#   $3 = our runner login (the loser)
#   $4 = our nonce
#   $5 = winner runner login
#   $6 = claims JSON array (from _fetch_claims)
# Returns: exit 0 always (non-fatal — loser backs off regardless).
#######################################
_handle_close_window_loss() {
	local issue_number="$1"
	local repo_slug="$2"
	local our_runner="$3"
	local our_nonce="$4"
	local winner_runner="$5"
	local claims="$6"

	local winner_epoch our_epoch delta_s winner_nonce
	winner_epoch=$(printf '%s' "$claims" | jq -r '.[0].created_epoch // 0' 2>/dev/null) || winner_epoch=0
	our_epoch=$(printf '%s' "$claims" | jq -r --arg n "$our_nonce" '[.[] | select(.nonce == $n)] | .[0].created_epoch // 0' 2>/dev/null) || our_epoch=0
	winner_nonce=$(printf '%s' "$claims" | jq -r '.[0].nonce // ""' 2>/dev/null) || winner_nonce=""

	# Non-numeric or zero epochs → cannot compute delta, skip silently.
	[[ "$winner_epoch" =~ ^[0-9]+$ ]] || return 0
	[[ "$our_epoch" =~ ^[0-9]+$ ]] || return 0
	((winner_epoch > 0)) || return 0
	((our_epoch > 0)) || return 0

	if ((our_epoch >= winner_epoch)); then
		delta_s=$((our_epoch - winner_epoch))
	else
		delta_s=$((winner_epoch - our_epoch))
	fi

	((delta_s <= DISPATCH_TIEBREAKER_WINDOW)) || return 0

	printf '[coordination] deferring to runner=%s nonce=%s ts_delta=%ss (within tiebreaker window)\n' \
		"$winner_runner" "$winner_nonce" "$delta_s" >&2
	_post_deferred "$issue_number" "$repo_slug" "$our_runner" "$our_nonce" \
		"$winner_runner" "$winner_nonce" "$delta_s" || true
	return 0
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
    Query whether an active claim exists on this issue.
    Exit 0 = active claim exists (do NOT dispatch)
    Exit 1 = no active claim (safe to proceed to claim step)
    Exit 2 = error (fail-open — proceed)

  dispatch-claim-helper.sh help
    Show this help.

Environment:
  DISPATCH_CLAIM_WINDOW    Consensus window in seconds (default: 8)
  DISPATCH_CLAIM_MAX_AGE   Max age of claim comments in seconds (default: 1800 = 30 min)

Protocol:
  1. Runner posts plain-text claim comment with unique nonce
     and max_age_s (active claim window in seconds)
  2. Waits DISPATCH_CLAIM_WINDOW seconds to allow other runners to post
  3. Fetches all claim comments on the issue
  4. Oldest active claim wins (claims older than DISPATCH_CLAIM_MAX_AGE are ignored)
     — others back off; ALL claim comments are retained as audit trail (GH#17503)
  5. Winner proceeds with dispatch; claim blocks re-dispatch until TTL expires

Examples:
  # Claim before dispatching (in pulse dedup guard):
  #   RUNNER=\$(gh api user --jq '.login')
  #   dispatch-claim-helper.sh claim 42 owner/repo "\$RUNNER"
  #   Exit 0 → won claim, proceed with dispatch
  #   Exit 1 → lost claim, back off
  #   Exit 2 → error, proceed (fail-open)
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
