#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# PR Salvage Helper — Detect closed-unmerged PRs with recoverable code
# =============================================================================
# Scans repos for recently-closed PRs that were never merged but still have
# branches with unmerged commits. These represent knowledge loss risk — code
# that was written, reviewed, and possibly review-addressed but never landed.
#
# Usage:
#   pr-salvage-helper.sh scan [--repo <slug>] [--days <N>] [--json] [PR_NUMBER...]
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
#   5. No closed recovery issue already documents completed salvage for the PR
#   6. No trusted (OWNER/MEMBER) closeout comment names a merged replacement PR
#   7. The PR's whole diff is not already present at one pinned default-branch
#      commit (e.g. a superseded dependency bump; GH#35799)
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
# Fetch closed issues that may document completed PR recovery.
#
# Arguments:
#   $1 - repo slug (owner/repo)
# Output: JSON array of matching closed issues
#######################################
fetch_completed_recovery_issues() {
	local slug="$1"
	local issues
	issues=$(gh issue list --repo "$slug" --state closed \
		--search "recover OR recovery OR salvage OR restore OR cherry-pick OR cherrypick" \
		--json number,title,body,state,closedAt --limit 100 2>/dev/null) || issues="[]"

	echo "$issues"
	return 0
}

#######################################
# Check if a closed issue already completed recovery for a closed PR.
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - PR number
#   $3 - optional pre-fetched closed recovery issues JSON array
# Output: "true" or "false" to stdout
#######################################
has_completed_recovery_issue() {
	local slug="$1"
	local pr_number="$2"
	local prefetched_issues="${3:-}"
	local issues
	if [[ -n "$prefetched_issues" ]]; then
		issues="$prefetched_issues"
	else
		issues=$(fetch_completed_recovery_issues "$slug")
	fi

	local match_count
	match_count=$(echo "$issues" | jq --arg pr "PR #${pr_number}" '
		[
			.[]
			| ((.title // "") + "\n" + (.body // "")) as $text
			| ($text | ascii_downcase) as $lower
			| select($text | test($pr + "\\b"))
			| select($lower | test("recover|recovery|salvage|restore|cherry-pick|cherrypick"))
		] | length
	') || match_count="0"

	if [[ "${match_count:-0}" -gt 0 ]]; then
		echo "true"
	else
		echo "false"
	fi
	return 0
}

#######################################
# Check whether a trusted closeout comment on a closed PR names a replacement
# PR that GitHub reports as merged (GH#33680). Only OWNER/MEMBER comments are
# authority; external comments, unreadable comments, and open, closed-unmerged
# or missing replacements never suppress salvage. Comment text is not logged.
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - closed source PR number
# Output: "true" or "false" to stdout
#######################################
has_merged_replacement_closeout() {
	local slug="$1"
	local pr_number="$2"
	local trusted_text="" refs="" ref="" merged_at=""
	local max_refs="${PR_SALVAGE_MAX_REPLACEMENT_REFS:-5}"
	[[ "$max_refs" =~ ^[1-9][0-9]*$ ]] || max_refs=5

	trusted_text=$(gh api --paginate "repos/${slug}/issues/${pr_number}/comments?per_page=100" \
		--jq '.[] | select(.author_association == "OWNER" or .author_association == "MEMBER") | .body' \
		2>/dev/null) || trusted_text=""
	[[ -n "$trusted_text" ]] || {
		echo "false"
		return 0
	}

	refs=$(printf '%s\n' "$trusted_text" |
		grep -oiE '(replac[a-z]*|supersed[a-z]*|landed|merged|contained|preserved|carried)[^#]{0,80}#[0-9]+' |
		grep -oE '[0-9]+$' | awk -v self="$pr_number" '$0 != self && !seen[$0]++' |
		head -n "$max_refs") || refs=""

	while IFS= read -r ref; do
		[[ "$ref" =~ ^[0-9]+$ ]] || continue
		merged_at=$(gh api "repos/${slug}/pulls/${ref}" --jq '.merged_at // ""' 2>/dev/null) || merged_at=""
		if [[ "$merged_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
			echo "true"
			return 0
		fi
	done <<<"$refs"
	echo "false"
	return 0
}

#######################################
# Resolve the default branch to one pinned commit SHA (GH#35799).
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - default branch name
# Output: 40-hex SHA, or nothing when it cannot be resolved
#######################################
get_default_branch_sha() {
	local slug="$1"
	local branch="$2"
	local sha=""
	sha=$(gh api "repos/${slug}/commits/${branch}" --jq '.sha' 2>/dev/null) || sha=""
	if [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
		echo "$sha"
	fi
	return 0
}

#######################################
# Compare one file patch with the pinned file content (GH#35799).
# Every significant added line must occur at least as often in the pinned
# file as in the patch, and no significant removed line that the patch does
# not re-add may remain. Lines shorter than 4 non-space characters (braces,
# commas) are ignored because they match anywhere.
# Arguments:
#   $1 - pinned file content path
#   $2 - patch path
# Output: significant added-line count when applied
# Returns: 0 when the patch is applied, 1 otherwise
#######################################
patch_applied_to_content() {
	local content_file="$1"
	local patch_file="$2"
	[[ -s "$content_file" ]] || return 1
	awk '
		FNR == NR { have[$0]++; next }
		{
			sign = substr($0, 1, 1)
			if (sign != "+" && sign != "-") next
			line = substr($0, 2)
			trimmed = line
			gsub(/[[:space:]]/, "", trimmed)
			if (length(trimmed) < 4) next
			if (sign == "+") { want[line]++; added++ } else { removed[line] = 1 }
		}
		END {
			for (l in want) if (have[l] < want[l]) exit 1
			for (l in removed) if (!(l in want) && (l in have)) exit 1
			print added + 0
		}
	' "$content_file" "$patch_file" 2>/dev/null || return 1
	return 0
}

#######################################
# Check whether a closed PR's whole diff is already present at one pinned
# default-branch commit (GH#35799). Evidence is the PR's own file patches
# against pinned file content; bot or author prose is never trusted. Any API
# failure, renamed/removed/binary file, missing patch, too many files or
# zero significant added lines keeps the salvage candidate.
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - closed PR number
#   $3 - pinned default-branch SHA (empty = unresolved)
# Output: "true" or "false" to stdout
#######################################
pr_diff_already_applied() {
	local slug="$1"
	local pr_number="$2"
	local pinned_sha="$3"
	local applied="false" files_json="" total_added=""

	if [[ "$pinned_sha" =~ ^[0-9a-f]{40}$ ]]; then
		files_json=$(fetch_applicable_pr_files "$slug" "$pr_number")
		if [[ -n "$files_json" ]] &&
			total_added=$(count_applied_additions "$slug" "$pinned_sha" "$files_json") &&
			[[ "$total_added" -gt 0 ]]; then
			applied="true"
		fi
	fi
	echo "$applied"
	return 0
}

#######################################
# Fetch a closed PR's file list when every file is comparable (GH#35799).
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - PR number
# Output: compact JSON array, or nothing when any file is not comparable
#######################################
fetch_applicable_pr_files() {
	local slug="$1"
	local pr_number="$2"
	local max_files="${PR_SALVAGE_MAX_APPLIED_FILES:-20}"
	local files_json=""
	[[ "$max_files" =~ ^[1-9][0-9]*$ ]] || max_files=20

	files_json=$(gh api "repos/${slug}/pulls/${pr_number}/files?per_page=100" 2>/dev/null) || files_json=""
	printf '%s' "$files_json" | jq -c --argjson max "$max_files" '
		if type == "array" and length > 0 and length <= $max
			and all(.[]; (.status == "modified" or .status == "added")
				and ((.filename // "") | type == "string" and length > 0)
				and ((.patch // "") | type == "string" and length > 0))
		then . else empty end' 2>/dev/null || true
	return 0
}

#######################################
# Count significant added lines across files whose patches are all present
# at the pinned revision (GH#35799). Stops at the first unreadable or
# unapplied file.
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - pinned default-branch SHA
#   $3 - compact JSON array from fetch_applicable_pr_files
# Output: total significant added lines
# Returns: 0 when every file is applied, 1 otherwise
#######################################
count_applied_additions() {
	local slug="$1"
	local pinned_sha="$2"
	local files_json="$3"
	local work_dir="" total_added=0 index=0 count=0 path="" encoded="" added="" status=0

	work_dir=$(mktemp -d "${TMPDIR:-/tmp}/pr-salvage-applied.XXXXXX") || return 1
	count=$(printf '%s' "$files_json" | jq 'length')
	while [[ "$index" -lt "$count" ]]; do
		path=$(printf '%s' "$files_json" | jq -r --argjson i "$index" '.[$i].filename')
		printf '%s' "$files_json" | jq -r --argjson i "$index" '.[$i].patch' >"${work_dir}/patch"
		encoded=$(jq -rn --arg p "$path" '$p | split("/") | map(@uri) | join("/")')
		if ! gh api -H "Accept: application/vnd.github.raw+json" \
			"repos/${slug}/contents/${encoded}?ref=${pinned_sha}" >"${work_dir}/content" 2>/dev/null; then
			status=1
			break
		fi
		if ! added=$(patch_applied_to_content "${work_dir}/content" "${work_dir}/patch") ||
			[[ ! "$added" =~ ^[0-9]+$ ]]; then
			status=1
			break
		fi
		total_added=$((total_added + added))
		index=$((index + 1))
	done
	rm -f "${work_dir}/patch" "${work_dir}/content"
	rmdir "$work_dir" 2>/dev/null || true

	[[ "$status" -eq 0 ]] || return 1
	echo "$total_added"
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
# Collect explicitly requested PR records for a repo
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - space-separated PR numbers
# Output: JSON array of PR records
#######################################
collect_explicit_pr_records() {
	local slug="$1"
	local pr_numbers="$2"
	local pr_records=()
	local pr_number
	local pr_record

	for pr_number in $pr_numbers; do
		pr_record=$(gh pr view "$pr_number" --repo "$slug" \
			--json number,title,headRefName,closedAt,mergedAt,additions,deletions,author,labels,state \
			2>/dev/null) || continue
		[[ -n "$pr_record" ]] && pr_records+=("$pr_record")
	done

	if [[ "${#pr_records[@]}" -eq 0 ]]; then
		echo "[]"
		return 0
	fi

	printf '%s\n' "${pr_records[@]}" | jq -s '.' || echo "[]"
	return 0
}

#######################################
# Fetch recently closed-unmerged PR records for a repo
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - lookback days
# Output: JSON array of PR records
#######################################
fetch_unmerged_pr_records() {
	local slug="$1"
	local lookback_days="$2"
	local cutoff_date

	# Fetch closed-unmerged PRs using GitHub search API (gh pr list --state closed
	# returns both merged and unmerged interleaved, so a small --limit misses most
	# unmerged PRs). The search query filters server-side for is:unmerged.
	cutoff_date=$(date -u -v-"${lookback_days}"d +%Y-%m-%d 2>/dev/null) ||
		cutoff_date=$(date -u -d "${lookback_days} days ago" +%Y-%m-%d 2>/dev/null) ||
		cutoff_date="1970-01-01"

	gh pr list --repo "$slug" --state closed \
		--search "is:unmerged closed:>=${cutoff_date}" \
		--json number,title,headRefName,closedAt,mergedAt,additions,deletions,author,labels,state \
		--limit 100 2>/dev/null || echo "[]"
	return 0
}

#######################################
# Keep only closed-unmerged PRs that contain recoverable additions
#
# Arguments:
#   $1 - PR records JSON array
# Output: JSON array of filtered PR records
#######################################
filter_salvage_candidate_records() {
	local candidate_records="$1"

	if [[ -z "$candidate_records" || "$candidate_records" == "[]" ]]; then
		printf '%s\n' "[]"
		return 0
	fi

	printf '%s\n' "$candidate_records" | jq '[.[] | select((.mergedAt == null) and (.additions > 0) and ((.state // "CLOSED") == "CLOSED"))]' || printf '%s\n' "[]"
	return 0
}

#######################################
# Build salvage entries from filtered PR records
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - filtered PR records JSON array
# Output: JSON array of salvage entries
#######################################
build_salvage_entries() {
	local slug="$1"
	local unmerged="$2"
	local salvageable="[]"
	local completed_recovery_issues
	local pr_json
	local pinned_sha="" pinned_resolved="false"

	completed_recovery_issues=$(fetch_completed_recovery_issues "$slug")
	while IFS= read -r pr_json; do
		local pr_number
		local branch
		local additions
		local branch_exists
		local risk
		local entry
		read -r pr_number branch additions < <(echo "$pr_json" | jq -r '[.number, .headRefName, .additions] | @tsv')

		# Skip PRs whose salvage has already been completed and documented in a closed issue.
		if [[ "$(has_completed_recovery_issue "$slug" "$pr_number" "$completed_recovery_issues")" == "true" ]]; then
			continue
		fi

		# Skip PRs that already have a replacement open
		if [[ "$(has_replacement_pr "$slug" "$branch")" == "true" ]]; then
			continue
		fi

		# GH#33680: skip PRs a trusted closeout preserved via a merged replacement.
		if [[ "$(has_merged_replacement_closeout "$slug" "$pr_number")" == "true" ]]; then
			continue
		fi

		# GH#35799: skip PRs whose whole diff is already on one pinned default-branch commit.
		if [[ "$pinned_resolved" == "false" ]]; then
			pinned_sha=$(get_default_branch_sha "$slug" "$(get_default_branch "$slug")")
			pinned_resolved="true"
		fi
		if [[ "$(pr_diff_already_applied "$slug" "$pr_number" "$pinned_sha")" == "true" ]]; then
			log_info "PR #${pr_number} diff already present at ${pinned_sha:0:12}; not salvageable"
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
# Scan a single repo for salvageable closed-unmerged PRs
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - lookback days (default: 7)
#   $3 - optional space-separated explicit PR numbers
# Output: JSON array of salvageable PRs
#######################################
scan_repo() {
	local slug="$1"
	local lookback_days="${2:-$DEFAULT_LOOKBACK_DAYS}"
	local pr_numbers="${3:-}"
	local unmerged

	if [[ -n "$pr_numbers" ]]; then
		unmerged=$(collect_explicit_pr_records "$slug" "$pr_numbers")
	else
		unmerged=$(fetch_unmerged_pr_records "$slug" "$lookback_days")
	fi

	# Safety filter: remove any that slipped through with mergedAt set or 0 additions
	unmerged=$(filter_salvage_candidate_records "$unmerged")
	if [[ -z "$unmerged" || "$unmerged" == "[]" ]]; then
		printf '%s\n' "[]"
		return 0
	fi

	build_salvage_entries "$slug" "$unmerged"
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
	repo_slugs=$(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$REPOS_JSON")

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
	local pr_numbers=""

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
			if [[ "$1" =~ ^#?[0-9]+$ ]]; then
				pr_numbers="${pr_numbers}${pr_numbers:+ }${1#\#}"
			fi
			shift
			;;
		esac
	done

	check_prerequisites || return 1

	local all_results="[]"

	if [[ -n "$target_repo" ]]; then
		local results
		results=$(scan_repo "$target_repo" "$lookback_days" "$pr_numbers")
		all_results=$(echo "$results" | jq --arg slug "$target_repo" '[.[] | . + {repo: $slug}]')
	else
		if [[ -n "$pr_numbers" ]]; then
			log_warn "explicit PR numbers require --repo <slug>"
			return 1
		fi
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
    pr-salvage-helper.sh scan [--repo <slug>] [--days <N>] [--json] [PR_NUMBER...]
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
    PR_NUMBER...    Optional explicit closed PR numbers to evaluate with --repo

RISK LEVELS:
    HIGH    Branch deleted + >100 lines, or branch exists + >500 lines
    MEDIUM  Branch deleted + <=100 lines, or branch exists + 50-500 lines
    LOW     Branch exists + <50 lines

INTEGRATION:
    # Pulse pre-fetch (called by pulse-wrapper.sh)
    pr-salvage-helper.sh prefetch marcusquinn/aidevops ~/Git/aidevops

    # Manual scan
    pr-salvage-helper.sh scan --repo marcusquinn/aidevops --days 14

    # Exact PR salvage triage
    pr-salvage-helper.sh scan --repo marcusquinn/aidevops 23745 23695 23682

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
