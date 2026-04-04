#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# backfill-origin-labels.sh — Retroactively apply origin:worker/origin:interactive
# labels to issues and PRs that were created before t1756 centralised labelling.
#
# Usage:
#   backfill-origin-labels.sh [--dry-run] [--repo SLUG] [--state open|closed|all] [--limit N]
#
# Heuristics (applied in order, first match wins):
#   1. Already labelled origin:worker or origin:interactive → skip
#   2. Has label: simplification-debt, source:quality-sweep, source:ci-failure-miner,
#      source:review-scanner, source:circuit-breaker, source:health-dashboard,
#      source:mission-validation, circuit-breaker → origin:worker
#   3. Has label: status:queued → origin:worker
#   4. Title starts with "simplification:", "recheck: simplification:",
#      "perf: simplification", "LLM complexity sweep" → origin:worker
#   5. Body contains "session-type: routine" or "session-type: headless" → origin:worker
#   6. Body contains "session-type: interactive" → origin:interactive
#   7. (PRs only) Merged by pulse/headless dispatch → origin:worker
#   8. Unmatched → skip (log as ambiguous)
#
# Rate limiting: 1 API call per item + ~0.5s sleep to stay under GitHub's
# secondary rate limit (80 mutations/min for label edits).
#
# t1756: https://github.com/marcusquinn/aidevops/issues/15640
set -euo pipefail

# shellcheck source=shared-constants.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

# ============================================================
# Defaults
# ============================================================
DRY_RUN=false
REPO_SLUG=""
STATE="open"
LIMIT=500
BATCH_SIZE=100

# Worker-indicative labels (any of these → origin:worker)
WORKER_LABELS=(
	"simplification-debt"
	"source:quality-sweep"
	"source:ci-failure-miner"
	"source:review-scanner"
	"source:circuit-breaker"
	"source:health-dashboard"
	"source:mission-validation"
	"circuit-breaker"
	"review-followup"
)

# Worker-indicative title prefixes (case-insensitive match)
WORKER_TITLE_PATTERNS=(
	"simplification:"
	"recheck: simplification:"
	"perf: simplification"
	"LLM complexity sweep"
	"Code Audit Routines"
	"Supervisor circuit breaker"
)

# ============================================================
# Helpers
# ============================================================
_log() { echo "[backfill] $*" >&2; }
_log_dry() { echo "[DRY-RUN] $*" >&2; }

_has_origin_label() {
	local labels="$1"
	case "$labels" in
	*origin:worker* | *origin:interactive*) return 0 ;;
	esac
	return 1
}

_match_worker_label() {
	local labels="$1"
	local wl
	for wl in "${WORKER_LABELS[@]}"; do
		case "$labels" in
		*"$wl"*) return 0 ;;
		esac
	done
	return 1
}

_match_worker_title() {
	local title="$1"
	local lower_title
	lower_title=$(echo "$title" | tr '[:upper:]' '[:lower:]')
	local pat
	for pat in "${WORKER_TITLE_PATTERNS[@]}"; do
		local lower_pat
		lower_pat=$(echo "$pat" | tr '[:upper:]' '[:lower:]')
		case "$lower_title" in
		"$lower_pat"*) return 0 ;;
		esac
	done
	return 1
}

_match_body_session_type() {
	local body="$1"
	# Match structured header: "session-type: routine/headless"
	if echo "$body" | grep -qiE 'session-type:\s*(routine|headless)'; then
		echo "worker"
		return 0
	fi
	if echo "$body" | grep -qiE 'session-type:\s*interactive'; then
		echo "interactive"
		return 0
	fi
	# Match natural-language signature footer from gh-signature-helper.sh:
	#   "...as a headless bash routine" / "...as a headless worker session"
	#   "...with the user in an interactive session"
	if echo "$body" | grep -qiE 'as a headless (bash routine|worker session)'; then
		echo "worker"
		return 0
	fi
	if echo "$body" | grep -qiE 'with the user in an interactive session'; then
		echo "interactive"
		return 0
	fi
	echo ""
	return 1
}

_apply_label() {
	local item_type="$1" # "issue" or "pr"
	local number="$2"
	local repo="$3"
	local label="$4"

	if [[ "$DRY_RUN" == true ]]; then
		_log_dry "Would add ${label} to ${item_type} #${number} in ${repo}"
		return 0
	fi

	if [[ "$item_type" == "pr" ]]; then
		gh pr edit "$number" --repo "$repo" --add-label "$label" >/dev/null 2>&1 || {
			_log "WARN: failed to label PR #${number}"
			return 1
		}
	else
		gh issue edit "$number" --repo "$repo" --add-label "$label" >/dev/null 2>&1 || {
			_log "WARN: failed to label issue #${number}"
			return 1
		}
	fi
	# Rate limit: stay under GitHub secondary rate limit
	sleep 0.5
	return 0
}

# ============================================================
# Core: classify and label one item
# ============================================================
_classify_item() {
	local item_type="$1"
	local number="$2"
	local title="$3"
	local labels="$4"
	local body="$5"
	local repo="$6"

	# 1. Already labelled → skip
	if _has_origin_label "$labels"; then
		return 0
	fi

	# 2. Worker-indicative labels
	if _match_worker_label "$labels"; then
		_apply_label "$item_type" "$number" "$repo" "origin:worker"
		echo "worker-label"
		return 0
	fi

	# 3. status:queued → worker
	case "$labels" in
	*status:queued*)
		_apply_label "$item_type" "$number" "$repo" "origin:worker"
		echo "worker-queued"
		return 0
		;;
	esac

	# 4. Worker title patterns
	if _match_worker_title "$title"; then
		_apply_label "$item_type" "$number" "$repo" "origin:worker"
		echo "worker-title"
		return 0
	fi

	# 5-6. Body session-type detection
	local body_origin
	body_origin=$(_match_body_session_type "$body") || true
	if [[ "$body_origin" == "worker" ]]; then
		_apply_label "$item_type" "$number" "$repo" "origin:worker"
		echo "worker-body"
		return 0
	fi
	if [[ "$body_origin" == "interactive" ]]; then
		_apply_label "$item_type" "$number" "$repo" "origin:interactive"
		echo "interactive-body"
		return 0
	fi

	# 7. Unmatched
	echo "ambiguous"
	return 0
}

# ============================================================
# Batch fetch and process
# ============================================================

# _resolve_graphql_params — set items_field and query_params for item_type+state
# Outputs two lines: "items_field=<value>" and "query_params=<value>"
_resolve_graphql_params() {
	local item_type="$1"
	local state="$2"

	if [[ "$item_type" == "pr" ]]; then
		local pr_params
		case "$state" in
		closed) pr_params="states: [CLOSED, MERGED]" ;;
		all) pr_params="states: [OPEN, CLOSED, MERGED]" ;;
		*) pr_params="states: [OPEN]" ;;
		esac
		echo "items_field=pullRequests"
		echo "query_params=${pr_params}"
	else
		local state_filter="OPEN"
		case "$state" in
		closed) state_filter="CLOSED" ;;
		all) state_filter="" ;;
		esac
		local issue_params=""
		[[ -n "$state_filter" ]] && issue_params="states: [${state_filter}]"
		echo "items_field=issues"
		echo "query_params=${issue_params}"
	fi
	return 0
}

# _fetch_page — execute one GraphQL page query; prints raw JSON to stdout
# Returns 1 on API failure.
_fetch_page() {
	local repo="$1"
	local items_field="$2"
	local page_size="$3"
	local after_clause="$4"
	local query_params="$5"

	local graphql_query
	graphql_query="query {
		repository(owner: \"${repo%%/*}\", name: \"${repo##*/}\") {
			${items_field}(first: ${page_size}${after_clause}, orderBy: {field: CREATED_AT, direction: DESC}, ${query_params}) {
				pageInfo { hasNextPage endCursor }
				nodes {
					number
					title
					body
					labels(first: 20) { nodes { name } }
				}
			}
		}
	}"

	gh api graphql -f query="$graphql_query" 2>/dev/null || return 1
	return 0
}

# _process_page_items — classify each node in a page result; updates counters via
# nameref-style globals passed by name (Bash 4.3+ not required — use indirect
# assignment via eval for Bash 3.2 compat).
# Args: item_type items_field result repo limit
# Outputs: "<fetched_delta> <worker_delta> <interactive_delta> <skipped_delta> <ambiguous_delta>"
_process_page_items() {
	local item_type="$1"
	local items_field="$2"
	local result="$3"
	local repo="$4"
	local limit="$5"
	local already_fetched="$6"

	local count
	count=$(echo "$result" | jq -r ".data.repository.${items_field}.nodes | length" 2>/dev/null) || count=0

	local d_fetched=0 d_worker=0 d_interactive=0 d_skipped=0 d_ambiguous=0
	local i
	for ((i = 0; i < count; i++)); do
		local number title labels_str body
		number=$(echo "$result" | jq -r ".data.repository.${items_field}.nodes[$i].number")
		title=$(echo "$result" | jq -r ".data.repository.${items_field}.nodes[$i].title")
		labels_str=$(echo "$result" | jq -r "[.data.repository.${items_field}.nodes[$i].labels.nodes[].name] | join(\",\")")
		body=$(echo "$result" | jq -r ".data.repository.${items_field}.nodes[$i].body // \"\"")

		local classification
		classification=$(_classify_item "$item_type" "$number" "$title" "$labels_str" "$body" "$repo")

		case "$classification" in
		"") d_skipped=$((d_skipped + 1)) ;;
		worker-*) d_worker=$((d_worker + 1)) ;;
		interactive-*) d_interactive=$((d_interactive + 1)) ;;
		ambiguous) d_ambiguous=$((d_ambiguous + 1)) ;;
		esac

		d_fetched=$((d_fetched + 1))
		[[ $((already_fetched + d_fetched)) -ge "$limit" ]] && break
	done

	echo "$d_fetched $d_worker $d_interactive $d_skipped $d_ambiguous"
	return 0
}

_process_items() {
	local item_type="$1" # "issue" or "pr"
	local repo="$2"
	local state="$3"
	local limit="$4"

	_log "Processing ${item_type}s (state=${state}, limit=${limit}) in ${repo}..."

	# Ensure labels exist on repo first
	ensure_origin_labels_exist "$repo"

	local fetched=0
	local labelled_worker=0
	local labelled_interactive=0
	local skipped_existing=0
	local ambiguous=0
	local page_size=$BATCH_SIZE
	local endCursor=""
	local has_next=true

	# Resolve GraphQL field name and state params once
	local items_field query_params
	local _params
	_params=$(_resolve_graphql_params "$item_type" "$state")
	items_field=$(echo "$_params" | grep '^items_field=' | cut -d= -f2-)
	query_params=$(echo "$_params" | grep '^query_params=' | cut -d= -f2-)

	while [[ "$has_next" == "true" ]] && [[ "$fetched" -lt "$limit" ]]; do
		local remaining=$((limit - fetched))
		[[ "$remaining" -lt "$page_size" ]] && page_size="$remaining"

		local after_clause=""
		[[ -n "$endCursor" ]] && after_clause=", after: \"$endCursor\""

		local result
		result=$(_fetch_page "$repo" "$items_field" "$page_size" "$after_clause" "$query_params") || {
			_log "WARN: GraphQL query failed, stopping pagination"
			break
		}

		has_next=$(echo "$result" | jq -r ".data.repository.${items_field}.pageInfo.hasNextPage" 2>/dev/null) || has_next="false"
		endCursor=$(echo "$result" | jq -r ".data.repository.${items_field}.pageInfo.endCursor" 2>/dev/null) || endCursor=""

		local count
		count=$(echo "$result" | jq -r ".data.repository.${items_field}.nodes | length" 2>/dev/null) || count=0
		[[ "$count" -eq 0 ]] && break

		local page_counts
		page_counts=$(_process_page_items "$item_type" "$items_field" "$result" "$repo" "$limit" "$fetched")

		local d_fetched d_worker d_interactive d_skipped d_ambiguous
		read -r d_fetched d_worker d_interactive d_skipped d_ambiguous <<<"$page_counts"

		fetched=$((fetched + d_fetched))
		labelled_worker=$((labelled_worker + d_worker))
		labelled_interactive=$((labelled_interactive + d_interactive))
		skipped_existing=$((skipped_existing + d_skipped))
		ambiguous=$((ambiguous + d_ambiguous))

		_log "  ...processed ${fetched}/${limit} ${item_type}s (${labelled_worker}W/${labelled_interactive}I/${skipped_existing}skip/${ambiguous}ambig)"
	done

	_log "Done: ${item_type}s in ${repo}: ${labelled_worker} worker, ${labelled_interactive} interactive, ${skipped_existing} already labelled, ${ambiguous} ambiguous (${fetched} total)"
	return 0
}

# ============================================================
# CLI
# ============================================================
_usage() {
	echo "Usage: backfill-origin-labels.sh [OPTIONS]"
	echo ""
	echo "Options:"
	echo "  --dry-run         Show what would be done without making changes"
	echo "  --repo SLUG       Target repo (default: all pulse-enabled repos)"
	echo "  --state STATE     Issue/PR state: open, closed, all (default: open)"
	echo "  --limit N         Max items to process per type per repo (default: 500)"
	echo "  --help            Show this help"
	return 0
}

main() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--repo)
			REPO_SLUG="$2"
			shift 2
			;;
		--repo=*)
			REPO_SLUG="${1#--repo=}"
			shift
			;;
		--state)
			STATE="$2"
			shift 2
			;;
		--state=*)
			STATE="${1#--state=}"
			shift
			;;
		--limit)
			LIMIT="$2"
			shift 2
			;;
		--limit=*)
			LIMIT="${1#--limit=}"
			shift
			;;
		--help | -h)
			_usage
			return 0
			;;
		*)
			_log "Unknown option: $1"
			_usage
			return 1
			;;
		esac
	done

	local repos_json="${HOME}/.config/aidevops/repos.json"
	local slugs=()

	if [[ -n "$REPO_SLUG" ]]; then
		slugs=("$REPO_SLUG")
	elif [[ -f "$repos_json" ]]; then
		while IFS= read -r slug; do
			[[ -n "$slug" ]] && slugs+=("$slug")
		done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)
	fi

	if [[ ${#slugs[@]} -eq 0 ]]; then
		_log "No repos found. Use --repo SLUG or configure repos.json."
		return 1
	fi

	[[ "$DRY_RUN" == true ]] && _log "=== DRY RUN MODE ==="

	local slug
	for slug in "${slugs[@]}"; do
		_log "=== Repository: ${slug} ==="
		_process_items "issue" "$slug" "$STATE" "$LIMIT"
		_process_items "pr" "$slug" "$STATE" "$LIMIT"
	done

	_log "Backfill complete."
	return 0
}

main "$@"
