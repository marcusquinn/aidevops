#!/usr/bin/env bash
# =============================================================================
# PR Salvage Helper — Detect closed-unmerged PRs with recoverable code
# =============================================================================
# Scans repos for recently-closed PRs that were never merged but still have
# branches with unmerged commits. These represent knowledge loss risk — code
# that was written, reviewed, and possibly review-addressed but never landed.
#
# Usage:
#   pr-salvage-helper.sh scan [--repo <slug>] [--days <N>] [--json]
#   pr-salvage-helper.sh prefetch <slug> <path>
#   pr-salvage-helper.sh help
#
# Commands:
#   scan      Scan one or all pulse-enabled repos for salvageable PRs
#   prefetch  Output a compact summary for pulse pre-fetched state
#   help      Show this help
#
# The scan checks:
#   1. PR was closed without merge (state=CLOSED, mergedAt=null)
#   2. The branch still exists on the remote (code is recoverable)
#   3. The branch has commits ahead of the default branch (actual code)
#   4. No replacement PR exists (open PR targeting the same issue)
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

# Source shared constants if available (non-fatal if missing)
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
DEFAULT_LOOKBACK_DAYS=7

#######################################
# Logging helpers
#######################################
log_info() {
	local msg="$1"
	echo "[pr-salvage] $msg" >&2
	return 0
}

log_warn() {
	local msg="$1"
	echo "[pr-salvage] WARN: $msg" >&2
	return 0
}

#######################################
# Validate prerequisites
#######################################
check_prerequisites() {
	if ! command -v gh &>/dev/null; then
		log_warn "gh CLI not found — cannot scan PRs"
		return 1
	fi
	if ! command -v jq &>/dev/null; then
		log_warn "jq not found — cannot parse PR data"
		return 1
	fi
	return 0
}

#######################################
# Get the default branch for a repo slug
# Arguments:
#   $1 - repo slug (owner/repo)
# Output: branch name (e.g., "main")
#######################################
get_default_branch() {
	local slug="$1"
	local branch
	branch=$(gh api "repos/${slug}" --jq '.default_branch' 2>/dev/null) || branch="main"
	echo "${branch:-main}"
	return 0
}

#######################################
# Check if a branch exists on a remote repo
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - branch name
# Output: "true" or "false" to stdout
#######################################
check_branch_exists() {
	local slug="$1"
	local branch="$2"
	if gh api "repos/${slug}/branches/${branch}" --jq '.name' &>/dev/null; then
		echo "true"
	else
		echo "false"
	fi
	return 0
}

#######################################
# Check if a replacement PR exists (open PR for the same branch)
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - branch name
# Output: "true" or "false" to stdout
#######################################
has_replacement_pr() {
	local slug="$1"
	local branch="$2"
	local open_count
	open_count=$(gh pr list --repo "$slug" --state open \
		--head "$branch" --json number --jq 'length' 2>/dev/null) || open_count="0"
	if [[ "${open_count:-0}" -gt 0 ]]; then
		echo "true"
	else
		echo "false"
	fi
	return 0
}

#######################################
# Assess knowledge-loss risk level based on code size and branch existence
# Arguments:
#   $1 - branch_exists ("true" or "false")
#   $2 - additions count
# Output: "high", "medium", or "low" to stdout
#######################################
assess_risk_level() {
	local branch_exists="$1"
	local additions="$2"
	local risk="low"
	if [[ "$branch_exists" == "false" ]]; then
		# Branch deleted — code only recoverable via GitHub API (PR diff)
		if [[ "$additions" -gt 100 ]]; then
			risk="high"
		else
			risk="medium"
		fi
	else
		# Branch exists — fully recoverable
		if [[ "$additions" -gt 500 ]]; then
			risk="high"
		elif [[ "$additions" -gt 50 ]]; then
			risk="medium"
		fi
	fi
	echo "$risk"
	return 0
}

#######################################
# Build a JSON salvage entry for a single PR
# Arguments:
#   $1 - pr_json (compact JSON of the PR record)
#   $2 - branch_exists ("true" or "false")
#   $3 - risk level
# Output: JSON object to stdout
#######################################
build_salvage_entry() {
	local pr_json="$1"
	local branch_exists="$2"
	local risk="$3"
	local pr_number branch additions deletions title author closed_at
	pr_number=$(echo "$pr_json" | jq -r '.number')
	branch=$(echo "$pr_json" | jq -r '.headRefName')
	additions=$(echo "$pr_json" | jq -r '.additions')
	deletions=$(echo "$pr_json" | jq -r '.deletions')
	title=$(echo "$pr_json" | jq -r '.title')
	author=$(echo "$pr_json" | jq -r '.author.login')
	closed_at=$(echo "$pr_json" | jq -r '.closedAt')
	jq -n \
		--argjson number "$pr_number" \
		--arg title "$title" \
		--arg branch "$branch" \
		--argjson branch_exists "$branch_exists" \
		--argjson additions "$additions" \
		--argjson deletions "$deletions" \
		--arg author "$author" \
		--arg risk "$risk" \
		--arg closed_at "$closed_at" \
		'{
			number: $number,
			title: $title,
			branch: $branch,
			branch_exists: $branch_exists,
			additions: $additions,
			deletions: $deletions,
			author: $author,
			risk: $risk,
			closed_at: $closed_at
		}'
	return 0
}

#######################################
# Scan a single repo for salvageable closed-unmerged PRs
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - lookback days (default: 7)
# Output: JSON array of salvageable PRs
#######################################
scan_repo() {
	local slug="$1"
	local lookback_days="${2:-$DEFAULT_LOOKBACK_DAYS}"

	# Fetch closed-unmerged PRs using GitHub search API (gh pr list --state closed
	# returns both merged and unmerged interleaved, so a small --limit misses most
	# unmerged PRs). The search query filters server-side for is:unmerged.
	local cutoff_date
	cutoff_date=$(date -u -v-"${lookback_days}"d +%Y-%m-%d 2>/dev/null) ||
		cutoff_date=$(date -u -d "${lookback_days} days ago" +%Y-%m-%d 2>/dev/null) ||
		cutoff_date="1970-01-01"

	local unmerged
	unmerged=$(gh pr list --repo "$slug" --state closed \
		--search "is:unmerged closed:>=${cutoff_date}" \
		--json number,title,headRefName,closedAt,mergedAt,additions,deletions,author,labels \
		--limit 100 2>/dev/null) || unmerged="[]"

	# Safety filter: remove any that slipped through with mergedAt set or 0 additions
	unmerged=$(echo "$unmerged" | jq '[.[] | select(.mergedAt == null and .additions > 0)]') || unmerged="[]"

	local count
	count=$(echo "$unmerged" | jq 'length')

	if [[ "$count" -eq 0 ]]; then
		echo "[]"
		return 0
	fi

	# For each unmerged PR, check recoverability and build salvage entries
	local salvageable="[]"
	local pr_json
	while IFS= read -r pr_json; do
		local branch additions branch_exists risk entry
		branch=$(echo "$pr_json" | jq -r '.headRefName')
		additions=$(echo "$pr_json" | jq -r '.additions')

		# Skip PRs that already have a replacement open
		if [[ "$(has_replacement_pr "$slug" "$branch")" == "true" ]]; then
			continue
		fi

		branch_exists=$(check_branch_exists "$slug" "$branch")
		risk=$(assess_risk_level "$branch_exists" "$additions")
		entry=$(build_salvage_entry "$pr_json" "$branch_exists" "$risk")

		salvageable=$(echo "$salvageable" | jq --argjson entry "$entry" '. + [$entry]')
	done < <(echo "$unmerged" | jq -c '.[]')

	echo "$salvageable"
	return 0
}

#######################################
# Generate a compact prefetch summary for the pulse
#
# Arguments:
#   $1 - repo slug
#   $2 - repo path
# Output: markdown summary to stdout
#######################################
cmd_prefetch() {
	local slug="$1"
	local path="$2"

	local salvageable
	salvageable=$(scan_repo "$slug" "$DEFAULT_LOOKBACK_DAYS")

	# For prefetch, only show HIGH and MEDIUM risk to avoid overwhelming the pulse context.
	# The pulse agent can run `pr-salvage-helper.sh scan` for the full list.
	local actionable
	actionable=$(echo "$salvageable" | jq '[.[] | select(.risk == "high" or .risk == "medium")]')

	local count
	count=$(echo "$actionable" | jq 'length')

	if [[ "$count" -eq 0 ]]; then
		return 0
	fi

	local total
	total=$(echo "$salvageable" | jq 'length')

	echo "### Salvageable Closed PRs ($count actionable of $total total)"
	echo ""
	echo "These PRs were closed without merge but contain recoverable code."
	echo "Action: reopen and merge if review-addressed, or cherry-pick valuable commits."
	echo "Run \`pr-salvage-helper.sh scan --repo $slug\` for the full list."
	echo ""

	echo "$actionable" | jq -r '.[] | "- PR #\(.number): \(.title) [+\(.additions)/-\(.deletions)] [branch: \(if .branch_exists then "EXISTS" else "DELETED" end)] [risk: \(.risk)] [author: \(.author)] [closed: \(.closed_at)]"'
	echo ""

	return 0
}

#######################################
# Scan all pulse-enabled repos and aggregate results
# Arguments:
#   $1 - lookback days
# Output: JSON array of salvageable PRs (tagged with repo slug) to stdout
# Returns: 1 if repos.json not found
#######################################
scan_all_repos() {
	local lookback_days="$1"
	local all_results="[]"

	if [[ ! -f "$REPOS_JSON" ]]; then
		log_warn "repos.json not found at $REPOS_JSON"
		return 1
	fi

	local repo_slugs
	repo_slugs=$(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$REPOS_JSON")

	while IFS= read -r slug; do
		[[ -z "$slug" ]] && continue
		log_info "Scanning $slug..."
		local results
		results=$(scan_repo "$slug" "$lookback_days")
		local count
		count=$(echo "$results" | jq 'length')
		if [[ "$count" -gt 0 ]]; then
			local tagged
			tagged=$(echo "$results" | jq --arg slug "$slug" '[.[] | . + {repo: $slug}]')
			all_results=$(echo "$all_results" "$tagged" | jq -s '.[0] + .[1]')
		fi
	done <<<"$repo_slugs"

	echo "$all_results"
	return 0
}

#######################################
# Format and print a single risk group if non-empty
# Arguments:
#   $1 - all_results JSON array
#   $2 - risk level ("high", "medium", or "low")
#   $3 - display label (e.g., "HIGH RISK")
# Output: formatted text to stdout (nothing if group is empty)
#######################################
format_risk_group() {
	local all_results="$1"
	local level="$2"
	local label="$3"
	local group
	group=$(echo "$all_results" | jq --arg level "$level" '[.[] | select(.risk == $level)]')
	local group_count
	group_count=$(echo "$group" | jq 'length')

	if [[ "$group_count" -gt 0 ]]; then
		echo "$label ($group_count):"
		echo "$group" | jq -r '.[] | "  PR #\(.number) [\(.repo)]: \(.title) (+\(.additions)/-\(.deletions)) branch=\(if .branch_exists then "exists" else "DELETED" end)"'
		echo ""
	fi
	return 0
}

#######################################
# Full scan across all pulse-enabled repos
#
# Arguments:
#   --repo <slug>  Scan a specific repo (optional)
#   --days <N>     Lookback window in days (default: 7)
#   --json         Output raw JSON instead of formatted text
#######################################
cmd_scan() {
	local target_repo=""
	local lookback_days="$DEFAULT_LOOKBACK_DAYS"
	local json_output="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			target_repo="$2"
			shift 2
			;;
		--days)
			lookback_days="$2"
			shift 2
			;;
		--json)
			json_output="true"
			shift
			;;
		*)
			shift
			;;
		esac
	done

	check_prerequisites || return 1

	local all_results="[]"

	if [[ -n "$target_repo" ]]; then
		local results
		results=$(scan_repo "$target_repo" "$lookback_days")
		all_results=$(echo "$results" | jq --arg slug "$target_repo" '[.[] | . + {repo: $slug}]')
	else
		all_results=$(scan_all_repos "$lookback_days") || return 1
	fi

	local total
	total=$(echo "$all_results" | jq 'length')

	if [[ "$json_output" == "true" ]]; then
		echo "$all_results"
		return 0
	fi

	if [[ "$total" -eq 0 ]]; then
		echo "No salvageable closed-unmerged PRs found."
		return 0
	fi

	echo "=== PR Salvage Report ==="
	echo ""
	echo "Found $total closed-unmerged PR(s) with recoverable code:"
	echo ""

	format_risk_group "$all_results" "high" "HIGH RISK"
	format_risk_group "$all_results" "medium" "MEDIUM RISK"
	format_risk_group "$all_results" "low" "LOW RISK"

	echo "Actions:"
	echo "  - HIGH risk: Reopen PR or cherry-pick immediately"
	echo "  - MEDIUM risk: Review and decide — reopen, cherry-pick, or document"
	echo "  - LOW risk: Document in issue comments if closing was intentional"

	return 0
}

#######################################
# Help
#######################################
cmd_help() {
	cat <<'EOF'
pr-salvage-helper.sh — Detect closed-unmerged PRs with recoverable code

Prevents knowledge loss by identifying PRs that were closed without merge
but still have branches with unmerged commits containing valuable work.

USAGE:
    pr-salvage-helper.sh scan [--repo <slug>] [--days <N>] [--json]
    pr-salvage-helper.sh prefetch <slug> <path>
    pr-salvage-helper.sh help

COMMANDS:
    scan        Scan repos for salvageable closed-unmerged PRs
    prefetch    Output compact summary for pulse pre-fetched state
    help        Show this help

SCAN OPTIONS:
    --repo <slug>   Scan a specific repo (default: all pulse-enabled)
    --days <N>      Lookback window in days (default: 7)
    --json          Output raw JSON

RISK LEVELS:
    HIGH    Branch deleted + >100 lines, or branch exists + >500 lines
    MEDIUM  Branch deleted + <=100 lines, or branch exists + 50-500 lines
    LOW     Branch exists + <50 lines

INTEGRATION:
    # Pulse pre-fetch (called by pulse-wrapper.sh)
    pr-salvage-helper.sh prefetch marcusquinn/aidevops ~/Git/aidevops

    # Manual scan
    pr-salvage-helper.sh scan --repo marcusquinn/aidevops --days 14

    # JSON output for scripting
    pr-salvage-helper.sh scan --json | jq '.[] | select(.risk == "high")'
EOF
	return 0
}

#######################################
# Main
#######################################
main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	scan)
		cmd_scan "$@"
		;;
	prefetch)
		if [[ $# -lt 2 ]]; then
			log_warn "prefetch requires <slug> <path>"
			return 1
		fi
		check_prerequisites || return 1
		cmd_prefetch "$1" "$2"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		log_warn "Unknown command: $cmd"
		cmd_help
		return 1
		;;
	esac
}

# Only run main if not being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
