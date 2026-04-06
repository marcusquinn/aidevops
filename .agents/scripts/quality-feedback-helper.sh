#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC1091
# quality-feedback-helper.sh - Retrieve code quality feedback via GitHub API
# Consolidates feedback from Codacy, CodeRabbit, SonarCloud, CodeFactor, etc.
#
# Usage:
#   quality-feedback-helper.sh [command] [options]
#
# Commands:
#   status       Show status of all quality checks for current commit/PR
#   failed       Show only failed checks with details
#   annotations  Get line-level annotations from all check runs
#   codacy       Get Codacy-specific feedback
#   coderabbit   Get CodeRabbit review comments
#   sonar        Get SonarCloud feedback
#   watch        Watch for check completion (polls every 30s)
#   scan-merged  Scan merged PRs for unactioned review feedback
#
# Examples:
#   quality-feedback-helper.sh status
#   quality-feedback-helper.sh failed --pr 4
#   quality-feedback-helper.sh annotations --commit abc123
#   quality-feedback-helper.sh watch --pr 4
#   quality-feedback-helper.sh scan-merged --repo owner/repo --batch 20
#   quality-feedback-helper.sh scan-merged --repo owner/repo --batch 20 --create-issues

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Common constants
# Get repository info
get_repo() {
	local repo
	repo="${GITHUB_REPOSITORY:-}"
	if [[ -z "$repo" ]]; then
		repo=$(gh repo view --json nameWithOwner -q .nameWithOwner) || {
			echo "Error: Not in a GitHub repository or gh CLI not configured" >&2
			exit 1
		}
	fi
	echo "$repo"
	return 0
}

# Get commit SHA (from PR or current HEAD)
get_sha() {
	local pr_number="${1:-}"
	if [[ -n "$pr_number" ]]; then
		gh pr view "$pr_number" --json headRefOid -q .headRefOid
	else
		git rev-parse HEAD
	fi
	return 0
}

# Resolve default branch for repo (cached per process)
_QF_DEFAULT_BRANCH=""
_QF_DEFAULT_BRANCH_REPO=""

_get_default_branch() {
	local repo_slug="$1"

	if [[ -n "$_QF_DEFAULT_BRANCH" && "$_QF_DEFAULT_BRANCH_REPO" == "$repo_slug" ]]; then
		echo "$_QF_DEFAULT_BRANCH"
		return 0
	fi

	local branch
	branch=$(gh api "repos/${repo_slug}" --jq '.default_branch' 2>/dev/null || echo "main")
	if [[ -z "$branch" || "$branch" == "null" ]]; then
		branch="main"
	fi

	_QF_DEFAULT_BRANCH="$branch"
	_QF_DEFAULT_BRANCH_REPO="$repo_slug"
	echo "$branch"
	return 0
}

_trim_whitespace() {
	local text="$1"
	text="${text#"${text%%[![:space:]]*}"}"
	text="${text%"${text##*[![:space:]]}"}"
	echo "$text"
	return 0
}

# =============================================================================
# Collaborator/maintainer permission check (cached per-process)
# =============================================================================
# Checks whether the authenticated gh user has write+ permission on the target
# repo. Used to gate --create-issues: non-collaborators can scan but not file
# issues (prevents noise from every aidevops user running a pulse against public
# repos they don't maintain). See GH#17523.
#
# Arguments: $1 - repo slug (owner/repo)
# Outputs: "true" if user has write/maintain/admin, "false" otherwise
# =============================================================================

_QF_PERMISSION_CHECKED=""
_QF_PERMISSION_REPO=""
_QF_HAS_WRITE=""

_check_write_permission() {
	local repo_slug="$1"

	# Return cached result if we already checked this repo
	if [[ -n "$_QF_PERMISSION_CHECKED" && "$_QF_PERMISSION_REPO" == "$repo_slug" ]]; then
		echo "$_QF_HAS_WRITE"
		return 0
	fi

	local user=""
	local permission=""
	user=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$user" ]]; then
		# Can't determine user — fail safe
		_QF_PERMISSION_CHECKED="true"
		_QF_PERMISSION_REPO="$repo_slug"
		_QF_HAS_WRITE="false"
		echo "false"
		return 0
	fi

	permission=$(gh api "repos/${repo_slug}/collaborators/${user}/permission" \
		--jq '.permission' 2>/dev/null || echo "none")

	_QF_PERMISSION_CHECKED="true"
	_QF_PERMISSION_REPO="$repo_slug"
	case "$permission" in
	admin | maintain | write)
		_QF_HAS_WRITE="true"
		;;
	*)
		_QF_HAS_WRITE="false"
		;;
	esac
	echo "$_QF_HAS_WRITE"
	return 0
}

# _extract_snippet_from_inline_code: fallback snippet extraction from
# blockquotes, indented code blocks, and inline backtick code.
# Arguments: $1=body_full
# Outputs first qualifying line to stdout; returns 0 on success, 1 if none found.
_extract_snippet_from_inline_code() {
	local body_full="$1"
	local line=""

	while IFS= read -r line; do
		case "$line" in
		'> '*)
			line="${line#> }"
			;;
		'    '* | '	'*)
			# indented code block (4 spaces or tab)
			line="${line#    }"
			line="${line#	}"
			;;
		'`'*)
			# inline backtick code — strip surrounding backticks
			line="${line//\`/}"
			;;
		*)
			continue
			;;
		esac
		line=$(_trim_whitespace "$line")
		if [[ -n "$line" && ${#line} -ge 12 ]]; then
			echo "$line"
			return 0
		fi
	done <<<"$body_full"

	return 1
}

_extract_verification_snippet() {
	local body_full="$1"
	local line=""
	local in_fence="false"
	local fence_type=""
	local candidate=""

	while IFS= read -r line; do
		if [[ "$line" =~ ^\`\`\` ]]; then
			if [[ "$in_fence" == "false" ]]; then
				in_fence="true"
				fence_type=""
				if [[ "$line" =~ ^\`\`\`([[:alnum:]_-]+) ]]; then
					# Bash 3.2 compat: no ${var,,} — use tr for case conversion
					fence_type=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
				fi
				continue
			fi
			break
		fi

		if [[ "$in_fence" == "true" ]]; then
			candidate=$(_trim_whitespace "$line")
			[[ -z "$candidate" ]] && continue

			if [[ "$fence_type" == "diff" ]]; then
				# diff fences: skip unified-diff markers and added/removed lines.
				# Lines starting with +/- are "add this" / "remove this" markers —
				# they do not represent the post-fix file content.
				[[ "$candidate" == "@@"* ]] && continue
				[[ "$candidate" == "diff --git"* ]] && continue
				[[ "$candidate" == "index "* ]] && continue
				[[ "$candidate" == "+++"* ]] && continue
				[[ "$candidate" == "---"* ]] && continue
				[[ "$candidate" == +* ]] && continue
				[[ "$candidate" == -* ]] && continue
			elif [[ "$fence_type" == "suggestion" ]]; then
				# suggestion fences: the entire content is the proposed replacement
				# text, verbatim.  Lines starting with '-' are literal content (e.g.
				# a markdown list item "- **Enhances:** t1393"), NOT diff removal
				# markers.  Do NOT skip them — they are the snippet we want to check
				# against HEAD to determine whether the suggestion was already applied.
				# Only skip unified-diff header lines that cannot appear in real code.
				[[ "$candidate" == "@@"* ]] && continue
				[[ "$candidate" == "diff --git"* ]] && continue
				[[ "$candidate" == "index "* ]] && continue
				[[ "$candidate" == "+++"* ]] && continue
				[[ "$candidate" == "---"* ]] && continue
			else
				# non-diff fences: lines starting with +/- are diff markers too —
				# skip them rather than stripping the prefix and using the content
				[[ "$candidate" == +* ]] && continue
				[[ "$candidate" == -* ]] && continue
			fi

			[[ "$candidate" == "Suggestion:"* ]] && continue
			[[ "$candidate" == "//"* ]] && continue
			[[ "$candidate" == "# "* ]] && continue
			[[ "$candidate" == "/*"* ]] && continue
			[[ "$candidate" == "*"* ]] && continue

			if [[ -n "$candidate" && ${#candidate} -ge 12 ]]; then
				echo "$candidate"
				return 0
			fi
		fi
	done <<<"$body_full"

	# Fallback: try blockquotes, indented blocks, and inline backtick code
	_extract_snippet_from_inline_code "$body_full"
	return $?
}

# _body_has_suggestion_fence: returns 0 (true) if body_full contains a
# ```suggestion fence, 1 (false) otherwise.
#
# Used by _finding_still_exists_on_main to determine snippet semantics:
# - suggestion fence → snippet is the proposed FIX text.  Finding is resolved
#   when the snippet IS present in HEAD (fix already applied).
# - all other sources → snippet is the PROBLEM text.  Finding is resolved
#   when the snippet is ABSENT from HEAD (problem was fixed).
_body_has_suggestion_fence() {
	local body_full="$1"
	if printf '%s\n' "$body_full" | grep -qE "^\`\`\`suggestion"; then
		return 0
	fi
	return 1
}

# _fetch_file_on_branch: fetch raw file content from GitHub API.
# Outputs file content to stdout.
# Returns 0 on success, 1 if file is missing (404), 2 on other API error.
_fetch_file_on_branch() {
	local repo_slug="$1"
	local file_path="$2"
	local branch="$3"

	local api_err
	api_err="$(mktemp)"
	local file_content
	if ! file_content=$(gh api -H "Accept: application/vnd.github.raw" \
		"repos/${repo_slug}/contents/${file_path}?ref=${branch}" 2>"$api_err"); then
		if grep -q "404" "$api_err"; then
			rm -f "$api_err"
			return 1
		fi
		rm -f "$api_err"
		return 2
	fi
	rm -f "$api_err"
	printf '%s' "$file_content"
	return 0
}

# _snippet_found_in_content: search for snippet in file_content, optionally
# anchored to a ±20-line window around line_num.
# Returns 0 if found, 1 if not found.
_snippet_found_in_content() {
	local file_content="$1"
	local snippet="$2"
	local line_num="$3"

	local found_in_window="false"
	if [[ "$line_num" =~ ^[0-9]+$ && "$line_num" -gt 0 ]]; then
		local total_lines
		total_lines=$(printf '%s\n' "$file_content" | wc -l | tr -d ' ')

		if [[ "$line_num" -le "$total_lines" ]]; then
			local start_line=$((line_num - 20))
			local end_line=$((line_num + 20))
			((start_line < 1)) && start_line=1
			((end_line > total_lines)) && end_line=$total_lines

			local current_line=0
			local file_line=""
			while IFS= read -r file_line; do
				current_line=$((current_line + 1))
				if [[ "$current_line" -ge "$start_line" && "$current_line" -le "$end_line" && "$file_line" == *"$snippet"* ]]; then
					found_in_window="true"
					break
				fi
			done <<<"$file_content"
		fi
	fi

	if [[ "$found_in_window" == "true" ]]; then
		return 0
	fi
	if printf '%s' "$file_content" | grep -Fq -e "$snippet"; then
		return 0
	fi
	return 1
}

# _emit_snippet_verdict: given snippet semantics and whether the snippet was
# found, emit the JSON result and return the appropriate exit code.
# Returns 0 if finding is still actionable, 1 if resolved.
_emit_snippet_verdict() {
	local is_suggestion_snippet="$1"
	local snippet_found="$2"
	local file_path="$3"
	local line_num="$4"
	local default_branch="$5"

	if [[ "$is_suggestion_snippet" == "true" ]]; then
		# Suggestion snippet: found in HEAD → fix already applied → resolved → skip
		if [[ "$snippet_found" == "true" ]]; then
			echo "[scan] Skipping resolved finding: ${file_path}:${line_num} - suggestion already applied on ${default_branch}" >&2
			echo '{"result":false,"status":"resolved"}'
			return 1
		fi
		# Suggestion not found in HEAD → fix not yet applied → still actionable → keep
		echo '{"result":true,"status":"verified"}'
		return 0
	else
		# Problem snippet: found in HEAD → problem still exists → keep
		if [[ "$snippet_found" == "true" ]]; then
			echo '{"result":true,"status":"verified"}'
			return 0
		fi
		# Problem snippet not found → problem was fixed → resolved → skip
		echo "[scan] Skipping resolved finding: ${file_path}:${line_num} - snippet not found on ${default_branch}" >&2
		echo '{"result":false,"status":"resolved"}'
		return 1
	fi
}

_finding_still_exists_on_main() {
	local repo_slug="$1"
	local file_path="$2"
	local line_num="$3"
	local body_full="$4"

	if [[ -z "$file_path" || "$file_path" == "null" ]]; then
		echo '{"result":true,"status":"unverifiable"}'
		return 0
	fi

	local default_branch
	default_branch=$(_get_default_branch "$repo_slug")

	local file_content
	local fetch_rc
	file_content=$(_fetch_file_on_branch "$repo_slug" "$file_path" "$default_branch") || fetch_rc=$?
	fetch_rc="${fetch_rc:-0}"

	if [[ "$fetch_rc" -eq 1 || -z "$file_content" ]]; then
		echo "[scan] Skipping resolved finding: ${file_path}:${line_num} - file missing on ${default_branch}" >&2
		echo '{"result":false,"status":"resolved"}'
		return 1
	fi
	if [[ "$fetch_rc" -eq 2 ]]; then
		echo "[scan] Keeping unverifiable finding: ${file_path}:${line_num} - failed to fetch ${default_branch}" >&2
		echo '{"result":true,"status":"unverifiable"}'
		return 0
	fi

	local snippet
	if ! snippet=$(_extract_verification_snippet "$body_full"); then
		echo "[scan] Keeping unverifiable finding: ${file_path}:${line_num} - no snippet extracted" >&2
		echo '{"result":true,"status":"unverifiable"}'
		return 0
	fi

	# Determine snippet semantics (GH#4874):
	# - suggestion fence → snippet is the proposed FIX text.
	#   Finding is resolved when the fix IS present in HEAD (suggestion applied).
	# - all other sources → snippet is the PROBLEM text.
	#   Finding is resolved when the problem is ABSENT from HEAD (problem fixed).
	local is_suggestion_snippet="false"
	if _body_has_suggestion_fence "$body_full"; then
		is_suggestion_snippet="true"
	fi

	local snippet_found="false"
	if _snippet_found_in_content "$file_content" "$snippet" "$line_num"; then
		snippet_found="true"
	fi

	_emit_snippet_verdict "$is_suggestion_snippet" "$snippet_found" \
		"$file_path" "$line_num" "$default_branch"
	return $?
}

# Show status of all checks
cmd_status() {
	local pr_number="${1:-}"
	local repo
	local sha

	repo=$(get_repo)
	sha=$(get_sha "$pr_number")

	echo -e "${BLUE}=== Quality Check Status ===${NC}"
	echo -e "Repository: ${repo}"
	echo -e "Commit: ${sha:0:8}"
	[[ -n "$pr_number" ]] && echo -e "PR: #${pr_number}"
	echo ""

	gh api "repos/${repo}/commits/${sha}/check-runs" \
		--jq '.check_runs[] | "\(.conclusion // .status)\t\(.name)"' |
		while IFS=$'\t' read -r conclusion name; do
			case "$conclusion" in
			success)
				echo -e "${GREEN}✓${NC} ${name}"
				;;
			failure | action_required)
				echo -e "${RED}✗${NC} ${name}"
				;;
			in_progress | queued | pending)
				echo -e "${YELLOW}○${NC} ${name} (${conclusion})"
				;;
			neutral | skipped)
				echo -e "${BLUE}–${NC} ${name} (${conclusion})"
				;;
			*)
				echo -e "? ${name} (${conclusion:-unknown})"
				;;
			esac
		done | sort
	return 0
}

# Show only failed checks with details
cmd_failed() {
	local pr_number="${1:-}"
	local repo
	local sha

	repo=$(get_repo)
	sha=$(get_sha "$pr_number")

	echo -e "${RED}=== Failed Quality Checks ===${NC}"
	echo -e "Commit: ${sha:0:8}"
	echo ""

	local failed_count=0

	while IFS=$'\t' read -r name summary url; do
		((++failed_count))
		echo -e "${RED}✗ ${name}${NC}"
		[[ -n "$summary" && "$summary" != "null" ]] && echo "  Summary: ${summary}"
		[[ -n "$url" && "$url" != "null" ]] && echo "  Details: ${url}"
		echo ""
	done < <(gh api "repos/${repo}/commits/${sha}/check-runs" \
		--jq '.check_runs[] | select(.conclusion == "failure" or .conclusion == "action_required") | "\(.name)\t\(.output.summary)\t\(.html_url)"')

	if [[ $failed_count -eq 0 ]]; then
		echo -e "${GREEN}No failed checks!${NC}"
	else
		echo -e "${RED}Total failed: ${failed_count}${NC}"
	fi
	return 0
}

# Get line-level annotations from all check runs
cmd_annotations() {
	local pr_number="${1:-}"
	local repo
	local sha

	repo=$(get_repo)
	sha=$(get_sha "$pr_number")

	echo -e "${BLUE}=== Annotations (Line-Level Issues) ===${NC}"
	echo -e "Commit: ${sha:0:8}"
	echo ""

	# Get all check run IDs
	local check_ids
	check_ids=$(gh api "repos/${repo}/commits/${sha}/check-runs" --jq '.check_runs[].id')

	local total_annotations=0

	for check_id in $check_ids; do
		local check_name
		check_name=$(gh api "repos/${repo}/check-runs/${check_id}" --jq '.name')

		local annotations
		annotations=$(gh api "repos/${repo}/check-runs/${check_id}/annotations" || echo "[]")

		local count
		count=$(echo "$annotations" | jq 'length')

		if [[ "$count" -gt 0 ]]; then
			echo -e "${YELLOW}--- ${check_name} (${count} annotations) ---${NC}"
			echo "$annotations" | jq -r '.[] | "  \(.path):\(.start_line) [\(.annotation_level)] \(.message)"'
			echo ""
			total_annotations=$((total_annotations + count))
		fi
	done

	if [[ $total_annotations -eq 0 ]]; then
		echo "No annotations found."
	else
		echo -e "${YELLOW}Total annotations: ${total_annotations}${NC}"
	fi
	return 0
}

# Get Codacy-specific feedback
cmd_codacy() {
	local pr_number="${1:-}"
	local repo
	local sha

	repo=$(get_repo)
	sha=$(get_sha "$pr_number")

	echo -e "${BLUE}=== Codacy Feedback ===${NC}"

	local codacy_check
	codacy_check=$(gh api "repos/${repo}/commits/${sha}/check-runs" \
		--jq '.check_runs[] | select(.app.slug == "codacy-production" or .name | contains("Codacy"))')

	if [[ -z "$codacy_check" ]]; then
		echo "No Codacy check found for this commit."
		return
	fi

	local conclusion
	local summary
	local url
	local check_id

	conclusion=$(echo "$codacy_check" | jq -r '.conclusion // .status')
	summary=$(echo "$codacy_check" | jq -r '.output.summary // "No summary"')
	url=$(echo "$codacy_check" | jq -r '.html_url')
	check_id=$(echo "$codacy_check" | jq -r '.id')

	echo "Status: ${conclusion}"
	echo "Summary: ${summary}"
	echo "Details: ${url}"
	echo ""

	# Get annotations if available
	local annotations
	annotations=$(gh api "repos/${repo}/check-runs/${check_id}/annotations" || echo "[]")
	local count
	count=$(echo "$annotations" | jq 'length')

	if [[ "$count" -gt 0 ]]; then
		echo -e "${YELLOW}Issues found:${NC}"
		echo "$annotations" | jq -r '.[] | "  \(.path):\(.start_line) [\(.annotation_level)] \(.message)"'
	fi
	return 0
}

# Get CodeRabbit review comments
cmd_coderabbit() {
	local pr_number="${1:-}"
	local repo

	repo=$(get_repo)

	if [[ -z "$pr_number" ]]; then
		pr_number=$(gh pr view --json number -q .number) || {
			echo "Error: Please specify a PR number with --pr" >&2
			exit 1
		}
	fi

	echo -e "${BLUE}=== CodeRabbit Review Comments ===${NC}"
	echo -e "PR: #${pr_number}"
	echo ""

	# Get review comments from CodeRabbit
	local comments
	comments=$(gh api "repos/${repo}/pulls/${pr_number}/comments" \
		--jq '[.[] | select(.user.login | contains("coderabbit"))]' || echo "[]")

	local count
	count=$(printf '%s' "$comments" | jq 'length')

	if [[ "$count" -eq 0 ]]; then
		echo "No CodeRabbit comments found."

		# Check for review body
		local reviews
		reviews=$(gh api "repos/${repo}/pulls/${pr_number}/reviews" \
			--jq '[.[] | select(.user.login | contains("coderabbit"))]' || echo "[]")

		local review_count
		review_count=$(echo "$reviews" | jq 'length')

		if [[ "$review_count" -gt 0 ]]; then
			echo ""
			echo -e "${YELLOW}CodeRabbit Reviews:${NC}"
			echo "$reviews" | jq -r '.[] | "State: \(.state)\n\(.body)\n---"'
		fi
	else
		echo -e "${YELLOW}Inline Comments (${count}):${NC}"
		echo "$comments" | jq -r '.[] | "\(.path):\(.line // .original_line)\n  \(.body)\n"'
	fi
	return 0
}

# Get SonarCloud feedback
cmd_sonar() {
	local pr_number="${1:-}"
	local repo
	local sha

	repo=$(get_repo)
	sha=$(get_sha "$pr_number")

	echo -e "${BLUE}=== SonarCloud Feedback ===${NC}"

	local sonar_check
	sonar_check=$(gh api "repos/${repo}/commits/${sha}/check-runs" \
		--jq '.check_runs[] | select(.name | contains("SonarCloud") or .name | contains("sonar"))')

	if [[ -z "$sonar_check" ]]; then
		echo "No SonarCloud check found for this commit."
		return
	fi

	local conclusion
	local summary
	local details_url

	conclusion=$(echo "$sonar_check" | jq -r '.conclusion // .status')
	summary=$(echo "$sonar_check" | jq -r '.output.summary // "No summary"')
	details_url=$(echo "$sonar_check" | jq -r '.details_url // .html_url')

	echo "Status: ${conclusion}"
	echo "Summary: ${summary}"
	echo "Dashboard: ${details_url}"
	return 0
}

# Watch for check completion
cmd_watch() {
	local pr_number="${1:-}"
	local repo
	local sha
	local interval="${2:-30}"

	repo=$(get_repo)
	sha=$(get_sha "$pr_number")

	echo -e "${BLUE}=== Watching Quality Checks ===${NC}"
	echo -e "Commit: ${sha:0:8}"
	echo -e "Polling every ${interval} seconds..."
	echo ""

	while true; do
		local pending
		pending=$(gh api "repos/${repo}/commits/${sha}/check-runs" \
			--jq '[.check_runs[] | select(.status == "in_progress" or .status == "queued" or .status == "pending")] | length')

		local failed
		failed=$(gh api "repos/${repo}/commits/${sha}/check-runs" \
			--jq '[.check_runs[] | select(.conclusion == "failure")] | length')

		local total
		total=$(gh api "repos/${repo}/commits/${sha}/check-runs" --jq '.check_runs | length')

		local completed
		completed=$((total - pending))

		echo -e "[$(date '+%H:%M:%S')] Completed: ${completed}/${total}, Pending: ${pending}, Failed: ${failed}"

		if [[ "$pending" -eq 0 ]]; then
			echo ""
			if [[ "$failed" -eq 0 ]]; then
				echo -e "${GREEN}All checks passed!${NC}"
			else
				echo -e "${RED}${failed} check(s) failed.${NC}"
				cmd_failed "$pr_number"
			fi
			break
		fi

		sleep "$interval"
	done
	return 0
}

#######################################
# Scan merged PRs for unactioned review feedback
#
# Fetches recently merged PRs, extracts review comments and review
# bodies from bots (CodeRabbit, Gemini Code Assist) and humans,
# filters by severity, checks if affected files still exist on HEAD,
# and optionally creates GitHub issues with label "quality-debt".
#
# State tracking: scanned PR numbers are stored in a JSON state file
# so subsequent runs skip already-processed PRs.
#
# Arguments (parsed from flags):
#   --repo SLUG       Repository slug (owner/repo). Default: auto-detect.
#   --batch N         Max PRs to scan per run (default: 20)
#   --create-issues   Actually create GitHub issues for findings
#   --min-severity    Minimum severity to report: critical|high|medium (default: medium)
#   --json            Output findings as JSON instead of human-readable
#   --dry-run         Scan and report findings without creating issues or marking
#                     PRs as scanned. Useful for identifying false-positive issues.
#   --include-positive  Bypass positive-review filters for debugging. Use with
#                     --dry-run to audit which reviews are being suppressed.
#
# Returns: 0 on success, 1 on error
#######################################
# _parse_scan_merged_flags: parse cmd_scan_merged CLI flags.
# Outputs newline-separated key=value pairs for each option.
# Returns 0 on success, 1 on unknown flag.
_parse_scan_merged_flags() {
	local repo_slug=""
	local batch_size=20
	local create_issues=false
	local min_severity="medium"
	local json_output=false
	local backfill=false
	local tag_actioned=false
	local dry_run=false
	local include_positive=false

	while [[ $# -gt 0 ]]; do
		local flag="$1"
		case "$1" in
		--repo)
			repo_slug="${2:-}"
			shift 2
			;;
		--batch)
			batch_size="${2:-20}"
			shift 2
			;;
		--create-issues)
			create_issues=true
			shift
			;;
		--min-severity)
			min_severity="${2:-medium}"
			shift 2
			;;
		--json)
			json_output=true
			shift
			;;
		--backfill)
			backfill=true
			shift
			;;
		--tag-actioned)
			tag_actioned=true
			shift
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		--include-positive)
			include_positive=true
			shift
			;;
		*)
			echo "Unknown option for scan-merged: ${flag}" >&2
			return 1
			;;
		esac
	done

	printf 'repo_slug=%s\n' "$repo_slug"
	printf 'batch_size=%s\n' "$batch_size"
	printf 'create_issues=%s\n' "$create_issues"
	printf 'min_severity=%s\n' "$min_severity"
	printf 'json_output=%s\n' "$json_output"
	printf 'backfill=%s\n' "$backfill"
	printf 'tag_actioned=%s\n' "$tag_actioned"
	printf 'dry_run=%s\n' "$dry_run"
	printf 'include_positive=%s\n' "$include_positive"
	return 0
}

# _fetch_merged_prs_list: fetch merged PRs from GitHub.
# Outputs one "number|scanned_label" record per line.
# Returns 0 on success, 1 on API error.
_fetch_merged_prs_list() {
	local repo_slug="$1"
	local batch_size="$2"
	local backfill="$3"

	if [[ "$backfill" == true ]]; then
		echo "Backfill mode: fetching ALL merged PRs for ${repo_slug}..." >&2
		gh api "repos/${repo_slug}/pulls?state=closed&per_page=100&sort=updated&direction=desc" \
			--paginate --jq '.[] | select(.merged_at != null) | "\(.number)|\(((.labels // []) | map(.name) | index("review-feedback-scanned")) != null)"' || {
			echo "Error: Failed to fetch merged PRs from ${repo_slug}" >&2
			return 1
		}
	else
		gh pr list --repo "$repo_slug" --state merged \
			--limit "$((batch_size * 2))" \
			--json number,mergedAt,labels \
			--jq 'sort_by(.mergedAt) | reverse | .[] | "\(.number)|\(([.labels[].name] | index("review-feedback-scanned")) != null)"' || {
			echo "Error: Failed to fetch merged PRs from ${repo_slug}" >&2
			return 1
		}
	fi
	return 0
}

# _save_scan_state: persist newly scanned PR numbers to the state file.
# Arguments: state_file, newly_scanned_array_elements..., issues_created
# (Pass array elements as positional args; last arg is issues_created count.)
_save_scan_state() {
	local state_file="$1"
	local issues_created="$2"
	shift 2
	# Remaining args are the newly scanned PR numbers
	local new_scanned_json
	new_scanned_json=$(printf '%s\n' "$@" | jq -R 'tonumber' | jq -s '.')
	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	jq --argjson new_prs "$new_scanned_json" \
		--arg last_run "$now_iso" \
		--argjson created "$issues_created" \
		'.scanned_prs = (.scanned_prs + $new_prs | unique) | .last_run = $last_run | .issues_created = (.issues_created + $created)' \
		"$state_file" >"${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
	return 0
}

# _process_pr_scan_loop: iterate over prs_to_scan, scan each PR, collect findings.
# Modifies caller's total_findings, total_issues_created, all_findings_json,
# newly_scanned, batch_count via nameref-style side effects through a temp file.
# Outputs results as a single JSON line: {"findings":N,"issues":N,"scanned":N}
_process_pr_scan_loop() {
	local repo_slug="$1"
	local min_severity="$2"
	local include_positive="$3"
	local create_issues="$4"
	local dry_run="$5"
	local backfill="$6"
	local batch_size="$7"
	local json_output="$8"
	local state_file="$9"
	shift 9
	# Remaining args are the PR numbers to scan
	local prs_to_scan=("$@")

	local total_to_scan=${#prs_to_scan[@]}
	local total_findings=0
	local total_issues_created=0
	local all_findings_json="[]"
	local newly_scanned=()
	local batch_count=0

	for pr_num in "${prs_to_scan[@]}"; do
		# Rate limiting: sleep between batches to stay within GitHub API limits
		# ~3 API calls per PR (comments, reviews, tree). At batch_size=20,
		# that's ~60 calls per batch. GitHub allows 5,000/hour.
		# Sleep 5s every batch_size PRs to spread the load.
		if [[ "$backfill" == true ]] && [[ "$batch_count" -gt 0 ]] && [[ $((batch_count % batch_size)) -eq 0 ]]; then
			echo "  Rate limit pause (${batch_count}/${total_to_scan} scanned, sleeping 5s)..." >&2
			sleep 5
			# Save progress incrementally so we don't lose work on interruption
			if [[ ${#newly_scanned[@]} -gt 0 ]]; then
				_save_scan_state "$state_file" "$total_issues_created" "${newly_scanned[@]}"
				newly_scanned=()
			fi
		fi

		local findings
		findings=$(_scan_single_pr "$repo_slug" "$pr_num" "$min_severity" "$include_positive") || {
			# In dry-run mode, don't mark PRs as scanned so they can be re-scanned
			if [[ "$dry_run" != true ]]; then
				gh pr edit "$pr_num" --repo "$repo_slug" --add-label "review-feedback-scanned" >/dev/null 2>&1 || true
				newly_scanned+=("$pr_num")
			fi
			batch_count=$((batch_count + 1))
			continue
		}
		if [[ "$dry_run" != true ]]; then
			gh pr edit "$pr_num" --repo "$repo_slug" --add-label "review-feedback-scanned" >/dev/null 2>&1 || true
			newly_scanned+=("$pr_num")
		fi
		batch_count=$((batch_count + 1))

		local finding_count
		finding_count=$(printf '%s' "$findings" | jq 'length' || echo "0")

		if [[ "$finding_count" -eq 0 || "$finding_count" == "0" ]]; then
			continue
		fi

		total_findings=$((total_findings + finding_count))

		# Merge into all_findings_json (skip in backfill to save memory, unless dry-run)
		if [[ "$backfill" != true || "$dry_run" == true ]]; then
			all_findings_json=$(echo "$all_findings_json" "$findings" | jq -s '.[0] + .[1]')
		fi

		# Create issues if requested (never in dry-run mode)
		if [[ "$create_issues" == "true" && "$dry_run" != true ]]; then
			local created
			created=$(_create_quality_debt_issues "$repo_slug" "$pr_num" "$findings")
			total_issues_created=$((total_issues_created + created))
		elif [[ "$dry_run" == true && "$json_output" != "true" ]]; then
			# In dry-run mode, print what would be created
			printf '%s' "$findings" | jq -r '.[] | "  [dry-run] PR #\(.pr) \(.reviewer) (\(.severity)): \(.body | .[0:120])"'
		fi
	done

	# Final state save — skipped in dry-run
	if [[ "$dry_run" != true && ${#newly_scanned[@]} -gt 0 ]]; then
		_save_scan_state "$state_file" "$total_issues_created" "${newly_scanned[@]}"
	fi

	# Return results as JSON for caller to consume
	printf '%s' "$all_findings_json" >"${state_file}.findings_tmp"
	printf '%d %d %d\n' "$total_findings" "$total_issues_created" "$batch_count"
	return 0
}

# _filter_unscanned_prs: from a newline-separated "number|scanned_label" list,
# return the PR numbers that have not yet been scanned, up to batch_size.
# In backfill mode, returns all unscanned PRs.
# Arguments: $1=merged_prs_text $2=state_file $3=batch_size $4=backfill
# Outputs one PR number per line.
_filter_unscanned_prs() {
	local merged_prs="$1"
	local state_file="$2"
	local batch_size="$3"
	local backfill="$4"

	local count=0
	while IFS= read -r pr_record; do
		local pr_num="${pr_record%%|*}"
		local scanned_label="${pr_record#*|}"
		[[ -z "$pr_num" ]] && continue

		# Global dedup: if PR already marked scanned on GitHub, skip.
		# This protects against duplicate scans across different HOME/state files.
		if [[ "$scanned_label" == "true" ]]; then
			continue
		fi

		# Skip if already scanned (use jq for reliable lookup)
		if jq -e --argjson pr "$pr_num" '.scanned_prs | index($pr) != null' "$state_file" >/dev/null 2>&1; then
			continue
		fi
		echo "$pr_num"
		count=$((count + 1))
		# In normal mode, cap at batch_size. In backfill mode, collect all.
		if [[ "$backfill" != true ]] && [[ "$count" -ge "$batch_size" ]]; then
			break
		fi
	done <<<"$merged_prs"
	return 0
}

# _print_scan_summary: emit the final scan summary to stdout.
# Arguments: $1=json_output $2=backfill $3=dry_run $4=all_findings_json
#            $5=batch_count $6=total_findings $7=total_issues_created
_print_scan_summary() {
	local json_output="$1"
	local backfill="$2"
	local dry_run="$3"
	local all_findings_json="$4"
	local batch_count="$5"
	local total_findings="$6"
	local total_issues_created="$7"

	if [[ "$json_output" == "true" ]]; then
		local details_json="$all_findings_json"
		[[ "$backfill" == true && "$dry_run" != true ]] && details_json="[]"
		jq -n \
			--argjson scanned "$batch_count" \
			--argjson findings "$total_findings" \
			--argjson issues_created "$total_issues_created" \
			--argjson details "$details_json" \
			--argjson dry_run "$([[ "$dry_run" == true ]] && echo 'true' || echo 'false')" \
			'{scanned: $scanned, findings: $findings, issues_created: $issues_created, details: $details, dry_run: $dry_run}'
	else
		echo ""
		echo -e "${BLUE:-}=== Scan Summary ===${NC:-}"
		echo "PRs scanned: ${batch_count}"
		echo "Findings: ${total_findings}"
		if [[ "$dry_run" == true ]]; then
			echo "Issues that would be created: ${total_findings} (dry-run — none created)"
		else
			echo "Issues created: ${total_issues_created}"
		fi
	fi
	return 0
}

# _resolve_scan_state_file: ensure the scan state file exists and return its path.
# Also creates the "review-feedback-scanned" label on the repo.
# Arguments: $1=repo_slug
# Outputs the state file path to stdout.
_resolve_scan_state_file() {
	local repo_slug="$1"

	gh label create "review-feedback-scanned" --repo "$repo_slug" --color "5319E7" \
		--description "Merged PR already scanned for quality feedback" --force 2>/dev/null || true

	local state_dir="${HOME}/.aidevops/logs"
	mkdir -p "$state_dir"
	local slug_safe="${repo_slug//\//-}"
	local state_file="${state_dir}/review-scan-state-${slug_safe}.json"
	if [[ ! -f "$state_file" ]]; then
		echo '{"scanned_prs":[],"last_run":"","issues_created":0}' >"$state_file"
	fi
	echo "$state_file"
	return 0
}

cmd_scan_merged() {
	# Parse flags via helper (keeps flag parsing isolated)
	local parsed_flags
	parsed_flags=$(_parse_scan_merged_flags "$@") || return 1

	local repo_slug batch_size create_issues min_severity
	local json_output backfill tag_actioned dry_run include_positive
	while IFS='=' read -r key val; do
		case "$key" in
		repo_slug) repo_slug="$val" ;;
		batch_size) batch_size="$val" ;;
		create_issues) create_issues="$val" ;;
		min_severity) min_severity="$val" ;;
		json_output) json_output="$val" ;;
		backfill) backfill="$val" ;;
		tag_actioned) tag_actioned="$val" ;;
		dry_run) dry_run="$val" ;;
		include_positive) include_positive="$val" ;;
		esac
	done <<<"$parsed_flags"

	# Validate batch_size is a positive integer (prevents command injection via arithmetic)
	if ! [[ "$batch_size" =~ ^[0-9]+$ ]] || [[ "$batch_size" -eq 0 ]]; then
		echo "Error: --batch must be a positive integer, got: ${batch_size}" >&2
		return 1
	fi

	# Auto-detect repo if not specified
	[[ -z "$repo_slug" ]] && { repo_slug=$(get_repo) || return 1; }

	# Collaborator gate (GH#17523): non-collaborators may scan but not create
	# issues. Prevents noise from every aidevops user filing quality-debt on
	# public repos they don't maintain. Downgrades to dry-run with warning.
	if [[ "$create_issues" == "true" && "$dry_run" != "true" ]]; then
		local has_write=""
		has_write=$(_check_write_permission "$repo_slug")
		if [[ "$has_write" != "true" ]]; then
			echo "Warning: authenticated user is not a collaborator on ${repo_slug}" >&2
			echo "  --create-issues requires write permission. Downgrading to --dry-run." >&2
			echo "  To create issues, ask a repo maintainer to add you as a collaborator." >&2
			dry_run=true
		fi
	fi

	local state_file
	state_file=$(_resolve_scan_state_file "$repo_slug")

	# Fetch and filter merged PRs
	local merged_prs
	merged_prs=$(_fetch_merged_prs_list "$repo_slug" "$batch_size" "$backfill") || return 1

	if [[ -z "$merged_prs" ]]; then
		[[ "$json_output" == "true" ]] &&
			echo '{"scanned":0,"findings":0,"issues_created":0,"details":[]}' ||
			echo "No merged PRs found in ${repo_slug}."
		return 0
	fi

	local prs_to_scan=()
	while IFS= read -r pr_num; do
		[[ -z "$pr_num" ]] && continue
		prs_to_scan+=("$pr_num")
	done < <(_filter_unscanned_prs "$merged_prs" "$state_file" "$batch_size" "$backfill")

	if [[ ${#prs_to_scan[@]} -eq 0 ]]; then
		[[ "$json_output" == "true" ]] &&
			echo '{"scanned":0,"findings":0,"issues_created":0,"details":[]}' ||
			echo "All merged PRs already scanned for ${repo_slug}."
		[[ "$tag_actioned" == true ]] && _tag_actioned_prs "$repo_slug" "$state_file"
		return 0
	fi

	local total_to_scan=${#prs_to_scan[@]}
	if [[ "$json_output" != "true" ]]; then
		echo -e "${BLUE:-}=== Scanning ${total_to_scan} merged PRs for unactioned review feedback ===${NC:-}"
		echo "Repository: ${repo_slug}"
		[[ "$dry_run" == true ]] &&
			echo "Mode: dry-run (no issues will be created, PRs will not be marked scanned)"
		[[ "$backfill" == true && "$dry_run" != true ]] &&
			echo "Mode: backfill (processing in batches of ${batch_size} with rate limiting)"
		echo ""
	fi

	local loop_result
	loop_result=$(_process_pr_scan_loop \
		"$repo_slug" "$min_severity" "$include_positive" \
		"$create_issues" "$dry_run" "$backfill" "$batch_size" \
		"$json_output" "$state_file" \
		"${prs_to_scan[@]}")

	local total_findings total_issues_created batch_count
	read -r total_findings total_issues_created batch_count <<<"$loop_result"

	local all_findings_json="[]"
	if [[ -f "${state_file}.findings_tmp" ]]; then
		all_findings_json=$(cat "${state_file}.findings_tmp")
		rm -f "${state_file}.findings_tmp"
	fi

	[[ "$tag_actioned" == true ]] && _tag_actioned_prs "$repo_slug" "$state_file"

	_print_scan_summary "$json_output" "$backfill" "$dry_run" \
		"$all_findings_json" "$batch_count" "$total_findings" "$total_issues_created"
	return 0
}

# _build_inline_findings: extract actionable inline review comments from a
# JSON array of PR comments. Outputs a JSON array of finding objects.
# Arguments: $1=comments_json $2=pr_num $3=min_severity
_build_inline_findings() {
	local comments="$1"
	local pr_num="$2"
	local min_severity="$3"

	echo "$comments" | jq --arg pr "$pr_num" --arg min_sev "$min_severity" '
		[.[] |
		# Determine reviewer type
		(.user.login) as $login |
		(if ($login | test("coderabbit"; "i")) then "coderabbit"
		 elif ($login | test("gemini|google"; "i")) then "gemini"
		 elif ($login | test("augment"; "i")) then "augment"
		 elif ($login | test("codacy"; "i")) then "codacy"
		 elif ($login | test("sonar"; "i")) then "sonarcloud"
		 else "human"
		 end) as $reviewer |

		# Extract severity from body
		(.body) as $body |
		(if ($body | test("security-critical\\.svg|🔴.*critical|CRITICAL"; "i")) then "critical"
		 elif ($body | test("critical\\.svg|severity:.*critical"; "i")) then "critical"
		 elif ($body | test("high-priority\\.svg|severity:.*high|HIGH"; "i")) then "high"
		 elif ($body | test("medium-priority\\.svg|severity:.*medium|MEDIUM"; "i")) then "medium"
		 elif ($body | test("low-priority\\.svg|severity:.*low|LOW|nit"; "i")) then "low"
		 else "medium"
		 end) as $severity |

		# Severity filter
		({"critical":4,"high":3,"medium":2,"low":1}[$severity] // 2) as $sev_num |
		({"critical":4,"high":3,"medium":2,"low":1}[$min_sev] // 2) as $min_num |

		select($sev_num >= $min_num) |

		# Skip resolved/outdated comments
		select(.position != null or .line != null or .original_line != null) |

		{
			pr: ($pr | tonumber),
			type: "inline",
			reviewer: $reviewer,
			reviewer_login: $login,
			severity: $severity,
			file: .path,
			line: (.line // .original_line),
			body: (.body | split("\n") | map(select(length > 0)) | first // .body),
			body_full: .body,
			url: .html_url,
			created_at: .created_at
		}]
	' || echo "[]"
	return 0
}

# _prefilter_reviews: first-pass filter on review bodies.
# Adds reviewer, severity fields; removes summary-only bot reviews and
# reviews below min_severity. Outputs an intermediate JSON array.
# Arguments: $1=reviews_json $2=min_severity $3=inline_counts_json
#            $4=include_positive (true|false)
_prefilter_reviews() {
	local reviews="$1"
	local min_severity="$2"
	local inline_counts_json="$3"
	local include_positive="$4"

	printf '%s' "$reviews" | jq \
		--arg min_sev "$min_severity" \
		--argjson inline_counts "$inline_counts_json" \
		--argjson include_positive "$([[ "$include_positive" == "true" ]] && echo 'true' || echo 'false')" '
		[.[] |
		select(.body != null and .body != "" and (.body | length) > 50) |

		(.user.login) as $login |
		(if ($login | test("coderabbit"; "i")) then "coderabbit"
		 elif ($login | test("gemini|google"; "i")) then "gemini"
		 elif ($login | test("augment"; "i")) then "augment"
		 elif ($login | test("codacy"; "i")) then "codacy"
		 else "human"
		 end) as $reviewer |

		# Skip summary-only bot reviews: state=COMMENTED with no inline comments.
		# Gemini Code Assist (and similar bots) post a high-level PR walkthrough as
		# a COMMENTED review with zero inline file comments. These are descriptive
		# summaries, not actionable findings — capturing them creates false-positive
		# quality-debt issues (see GH#4528, incident: issue #3744 / PR #1121).
		# Humans and CHANGES_REQUESTED reviews are never skipped by this rule.
		# When --include-positive is set, this filter is bypassed for debugging.
		(($inline_counts[$login] // 0) == 0 and .state == "COMMENTED" and $reviewer != "human" and ($include_positive | not)) as $summary_only |
		select($summary_only | not) |

		(.body) as $body |
		(if ($body | test("security-critical\\.svg|🔴.*critical|CRITICAL"; "i")) then "critical"
		 elif ($body | test("critical\\.svg|severity:.*critical"; "i")) then "critical"
		 elif ($body | test("high-priority\\.svg|severity:.*high|HIGH"; "i")) then "high"
		 elif ($body | test("medium-priority\\.svg|severity:.*medium|MEDIUM"; "i")) then "medium"
		 elif ($body | test("low-priority\\.svg|severity:.*low|LOW|nit"; "i")) then "low"
		 else "medium"
		 end) as $severity |

		({"critical":4,"high":3,"medium":2,"low":1}[$severity] // 2) as $sev_num |
		({"critical":4,"high":3,"medium":2,"low":1}[$min_sev] // 2) as $min_num |

		select($sev_num >= $min_num) |

		# Annotate with derived fields for second-pass filtering
		. + {_reviewer: $reviewer, _severity: $severity}]
	' || echo "[]"
	return 0
}

# _build_review_findings: extract actionable top-level review bodies.
# Outputs a JSON array of finding objects.
# Arguments: $1=reviews_json $2=pr_num $3=min_severity
#            $4=inline_counts_json $5=include_positive (true|false)
# _apply_positive_filter: second-pass filter — removes purely positive/approving
# reviews and annotates each item with _actionable flag for output shaping.
# Arguments: $1=prefiltered_json $2=include_positive (true|false)
_apply_positive_filter() {
	local prefiltered="$1"
	local include_positive="$2"

	printf '%s' "$prefiltered" | jq \
		--argjson include_positive "$([[ "$include_positive" == "true" ]] && echo 'true' || echo 'false')" '
		[.[] |
		(._reviewer) as $reviewer |
		(.body) as $body |

		# Detect purely positive/approving reviews with no actionable critique.
		# These are false positives — filing quality-debt issues for "LGTM" or
		# "no further comments" wastes worker time (GH#4604, incident: issue #3704 / PR #1484).
		# Applies to all reviewer types including humans.
		# When --include-positive is set, these filters are bypassed for debugging.
		($body | test(
			"^[\\s\\n]*(lgtm|looks good( to me)?|ship it|shipit|:shipit:|:\\+1:|👍|" +
			"approved?|great (work|job|change|pr|patch)|nice (work|job|change|pr|patch)|" +
			"good (work|job|change|pr|patch|catch|call|stuff)|well done|" +
			"no (further |more )?(comments?|issues?|concerns?|feedback|changes? (needed|required))|" +
			"nothing (further|else|more) (to (add|comment|say|note))?|" +
			"(all |everything )?(looks?|seems?) (good|fine|correct|great|solid|clean)|" +
			"(this |the )?(pr|patch|change|diff|code) (looks?|seems?) (good|fine|correct|great|solid|clean)|" +
			"(i have )?no (objections?|issues?|concerns?|comments?)|" +
			"(thanks?|thank you)[,.]?\\s*(for the (pr|patch|fix|change|contribution))?[.!]?)[\\s\\n]*$"; "i")) as $approval_only |

		($body | test(
			"\\bno (further )?recommendations?\\b|" +
			"\\bno additional recommendations?\\b|" +
			"\\bnothing (further|more) to recommend\\b"; "i")) as $no_actionable_recommendation |

		($body | test(
			"\\bno (further |more )?suggestions?\\b|" +
			"\\bno additional suggestions?\\b|" +
			"\\bno suggestions? (at this time|for now|currently|for improvement)?\\b|" +
			"\\bwithout suggestions?\\b|" +
			"\\bhas no suggestions?\\b"; "i")) as $no_actionable_suggestions |

		($body | test(
			"\\blgtm\\b|\\blooks good( to me)?\\b|\\bgood work\\b|" +
			"\\bno (further |more )?(comments?|issues?|concerns?|feedback)\\b|" +
			"\\bfound no (issues?|problems?|concerns?)\\b|" +
			"\\bno (issues?|problems?|concerns?) (found|detected)\\b|" +
			"\\b(found|detected) nothing (to )?(fix|change|address)\\b|" +
			"\\beverything (looks?|seems?) (good|fine|correct|great|solid|clean)\\b"; "i")) as $no_actionable_sentiment |

		($body | test(
			"\\bsuccessfully addresses?\\b|\\beffectively\\b|\\bimproves?\\b|\\benhances?\\b|" +
			"\\bcorrectly (removes?|implements?|fixes?|handles?|addresses?)\\b|\\bvaluable change\\b|" +
			"\\bconsistent\\b|\\brobust(ness)?\\b|\\buser experience\\b|" +
			"\\breduces? (external )?requirements?\\b|\\bwell-implemented\\b"; "i")) as $summary_praise_only |

		($body | test(
			"\\bshould\\b|\\bconsider\\b|\\binstead\\b|\\bsuggest|\\brecommend(ed|ing)?\\b|" +
			"\\bwarning\\b|\\bcaution\\b|\\bavoid\\b|\\b(don ?'"'"'?t|do not)\\b|" +
			"\\bvulnerab|\\binsecure|\\binjection\\b|\\bxss\\b|\\bcsrf\\b|" +
			"\\bbug\\b|\\berror\\b|\\bproblem\\b|\\bfail\\b|\\bincorrect\\b|\\bwrong\\b|\\bmissing\\b|\\bbroken\\b|" +
			"\\bnit:|\\btodo:|\\bfixme|\\bhardcoded|\\bdeprecated|" +
			"\\brace.condition|\\bdeadlock|\\bleak|\\boverflow|" +
			"\\bworkaround\\b|\\bhack\\b|" +
			"```\\s*(suggestion|diff)"; "i")) as $actionable_raw |

		($actionable_raw and ($no_actionable_recommendation | not) and ($no_actionable_suggestions | not)) as $actionable |

		($body | test(
			"\\bmerging\\.?$|\\bmerge (this|the) pr\\b|" +
			"\\bci (checks? )?(green|pass(ed)?|ok)\\b|" +
			"\\ball (checks?|tests?) (green|pass(ed)?|ok)\\b|" +
			"\\breview.bot.gate (pass|ok)\\b|" +
			"\\bpulse supervisor\\b"; "i")) as $merge_status_only |

		select($include_positive or (((($approval_only or $no_actionable_recommendation or $no_actionable_suggestions or $no_actionable_sentiment or $summary_praise_only or $merge_status_only) and ($actionable | not))) | not)) |

		. + {_actionable: $actionable}]
	' || echo "[]"
	return 0
}

# _shape_review_findings: final-pass — apply reviewer-type select and shape output objects.
# Arguments: $1=filtered_json $2=pr_num $3=include_positive (true|false)
_shape_review_findings() {
	local filtered="$1"
	local pr_num="$2"
	local include_positive="$3"

	printf '%s' "$filtered" | jq \
		--arg pr "$pr_num" \
		--argjson include_positive "$([[ "$include_positive" == "true" ]] && echo 'true' || echo 'false')" '
		[.[] |
		(._reviewer) as $reviewer |
		(._severity) as $severity |
		(._actionable) as $actionable |
		(.body) as $body |

		# Detect merge/CI-status comments (GH#5668)
		($body | test(
			"\\bmerging\\.?$|\\bmerge (this|the) pr\\b|" +
			"\\bci (checks? )?(green|pass(ed)?|ok)\\b|" +
			"\\ball (checks?|tests?) (green|pass(ed)?|ok)\\b|" +
			"\\breview.bot.gate (pass|ok)\\b|" +
			"\\bpulse supervisor\\b"; "i")) as $merge_status_only |

		select(
			if $include_positive then true
			elif .state == "CHANGES_REQUESTED" then true
			elif $reviewer == "human" then $actionable
			elif .state == "APPROVED" then $actionable
			else
				($actionable and ($body | test(
					"\\*\\*File\\*\\*|```\\s*(suggestion|diff)|" +
					"\\bline\\s+[0-9]+\\b|\\bL[0-9]+\\b"; "i")))
			end
		) |

		select($include_positive or ($merge_status_only | not)) |

		{
			pr: ($pr | tonumber),
			type: "review_body",
			reviewer: $reviewer,
			reviewer_login: .user.login,
			severity: $severity,
			file: null,
			line: null,
			body: (.body | split("\n") | map(select(length > 0)) | first // .body),
			body_full: .body,
			url: .html_url,
			created_at: .submitted_at
		}]
	' || echo "[]"
	return 0
}

# _build_review_findings: extract actionable top-level review bodies.
# Outputs a JSON array of finding objects.
# Arguments: $1=reviews_json $2=pr_num $3=min_severity
#            $4=inline_counts_json $5=include_positive (true|false)
_build_review_findings() {
	local reviews="$1"
	local pr_num="$2"
	local min_severity="$3"
	local inline_counts_json="$4"
	local include_positive="$5"

	# Pass 1: severity + summary-only filtering
	local prefiltered
	prefiltered=$(_prefilter_reviews "$reviews" "$min_severity" "$inline_counts_json" "$include_positive") || prefiltered="[]"

	# Pass 2: positive-filter detection
	local pos_filtered
	pos_filtered=$(_apply_positive_filter "$prefiltered" "$include_positive") || pos_filtered="[]"

	# Pass 3: reviewer-type select + output shaping
	_shape_review_findings "$pos_filtered" "$pr_num" "$include_positive"
	return $?
}

# _filter_findings_by_head_files: remove findings whose file no longer exists
# at HEAD. Findings with null file (review bodies) are always kept.
# Arguments: $1=repo_slug $2=findings_json
# Outputs filtered JSON array.
_filter_findings_by_head_files() {
	local repo_slug="$1"
	local findings="$2"

	local item_count
	item_count=$(printf '%s' "$findings" | jq 'length' || echo "0")

	if [[ "$item_count" -eq 0 ]]; then
		echo "[]"
		return 0
	fi

	local head_files
	head_files=$(gh api "repos/${repo_slug}/git/trees/HEAD?recursive=1" \
		--jq '[.tree[].path]') || head_files="[]"

	echo "$findings" | jq --argjson head_files "$head_files" '
		[.[] |
		if .file == null then .  # review bodies without file refs — keep
		elif (.file as $f | $head_files | any(. == $f)) then .  # file still exists
		else empty  # file was removed/renamed — skip
		end]
	'
	return 0
}

#######################################
# Scan a single merged PR for review feedback
#
# Fetches both inline review comments and review bodies from all
# reviewers (bots and humans). Extracts severity from known patterns
# (Gemini SVG markers, CodeRabbit labels). Checks if affected files
# still exist on HEAD.
#
# Arguments:
#   $1 - repo slug
#   $2 - PR number
#   $3 - minimum severity (critical|high|medium)
#   $4 - include_positive (true|false) — when true, skip positive-review filters
#        (summary-only, approval-only, no-actionable-sentiment). Useful for
#        debugging false-positive suppression. Default: false.
# Output: JSON array of findings to stdout
# Returns: 0 on success
#######################################
_scan_single_pr() {
	local repo_slug="$1"
	local pr_num="$2"
	local min_severity="$3"
	local include_positive="${4:-false}"

	echo -e "  Scanning PR #${pr_num}..." >&2

	# --- Fetch inline review comments (file-level) ---
	local comments
	comments=$(gh api "repos/${repo_slug}/pulls/${pr_num}/comments" \
		--paginate --jq '.' | jq -s 'add // []') || comments="[]"

	# --- Fetch review bodies (top-level reviews) ---
	local reviews
	reviews=$(gh api "repos/${repo_slug}/pulls/${pr_num}/reviews" \
		--paginate --jq '.' | jq -s 'add // []') || reviews="[]"

	# Process inline comments
	local inline_findings
	inline_findings=$(_build_inline_findings "$comments" "$pr_num" "$min_severity") || inline_findings="[]"

	# Build a per-reviewer inline comment count map from the already-fetched comments.
	# Used below to detect summary-only reviews (state=COMMENTED, no inline comments).
	local inline_counts_json
	inline_counts_json=$(printf '%s' "$comments" | jq '
		group_by(.user.login) |
		map({key: .[0].user.login, value: length}) |
		from_entries
	') || inline_counts_json="{}"

	# Process review bodies (for substantive reviews with body content)
	local review_findings
	review_findings=$(_build_review_findings \
		"$reviews" "$pr_num" "$min_severity" \
		"$inline_counts_json" "$include_positive") || review_findings="[]"

	# Log skipped summary-only reviews at DEBUG level for traceability
	if [[ "${AIDEVOPS_DEBUG:-}" == "1" ]]; then
		local skipped_summaries
		skipped_summaries=$(printf '%s' "$reviews" | jq \
			--argjson inline_counts "$inline_counts_json" '
			[.[] |
			select(.body != null and .body != "" and (.body | length) > 50) |
			(.user.login) as $login |
			select(
				($inline_counts[$login] // 0) == 0 and
				.state == "COMMENTED" and
				($login | test("coderabbit|gemini|google|codacy|augment"; "i"))
			) |
			"[DEBUG] Skipped summary-only review: id=\(.id) login=\(.login // .user.login) state=\(.state) body_len=\(.body | length)"
			] | .[]
		' -r 2>/dev/null || true)
		[[ -n "$skipped_summaries" ]] && printf '%s\n' "$skipped_summaries" >&2
	fi

	# Merge and deduplicate
	local findings
	findings=$(printf '%s\n%s' "$inline_findings" "$review_findings" | jq -s '.[0] + .[1]')

	# Filter: check if affected files still exist on HEAD
	_filter_findings_by_head_files "$repo_slug" "$findings"
	return 0
}

#######################################
# Tag scanned PRs where all review feedback has been actioned (t1413)
#
# For each scanned PR, checks if any quality-debt issues reference it.
# If all such issues are closed (or none were created because the PR
# had no actionable findings), labels the PR as "code-reviews-actioned".
#
# This provides a clear signal of which PRs have been fully reviewed
# and resolved, vs which still have outstanding feedback.
#
# Arguments:
#   $1 - repo slug
#   $2 - state file path
# Returns: 0 on success
#######################################
_tag_actioned_prs() {
	local repo_slug="$1"
	local state_file="$2"

	echo "Tagging actioned PRs for ${repo_slug}..." >&2

	# Ensure label exists
	gh label create "code-reviews-actioned" --repo "$repo_slug" --color "0E8A16" \
		--description "All review feedback has been actioned" --force || true

	# Get all scanned PR numbers
	local scanned_prs
	scanned_prs=$(jq -r '.scanned_prs[]' "$state_file") || return 0

	# Get all OPEN quality-debt issues with their titles (to extract PR numbers)
	local open_debt_titles
	open_debt_titles=$(gh issue list --repo "$repo_slug" \
		--label "quality-debt" --state open --limit 500 \
		--json title --jq '.[].title' || echo "")

	# Get PRs that already have the label (avoid redundant API calls)
	local already_tagged
	already_tagged=$(gh pr list --repo "$repo_slug" --state merged \
		--label "code-reviews-actioned" --limit 500 \
		--json number --jq '.[].number' || echo "")

	local tagged_count=0
	local batch_count=0

	while IFS= read -r pr_num; do
		[[ -z "$pr_num" ]] && continue

		# Skip if already tagged
		if printf '%s' "$already_tagged" | grep -qx "$pr_num"; then
			continue
		fi

		# Check if this PR has any OPEN quality-debt issues
		# Quality-debt issue titles contain "PR #NNN" — check for open ones
		local has_open_debt=false
		if [[ -n "$open_debt_titles" ]]; then
			if printf '%s' "$open_debt_titles" | grep -qF "PR #${pr_num}"; then
				has_open_debt=true
			fi
		fi

		if [[ "$has_open_debt" == false ]]; then
			# No open debt for this PR — tag it as actioned
			gh pr edit "$pr_num" --repo "$repo_slug" \
				--add-label "code-reviews-actioned" || true
			tagged_count=$((tagged_count + 1))
		fi

		# Rate limiting: sleep every 50 labels to avoid API abuse
		batch_count=$((batch_count + 1))
		if [[ $((batch_count % 50)) -eq 0 ]]; then
			echo "  Tagged ${tagged_count} PRs so far (${batch_count} checked), sleeping 3s..." >&2
			sleep 3
		fi
	done <<<"$scanned_prs"

	echo "  Tagged ${tagged_count} PRs as code-reviews-actioned" >&2

	# Backfill priority labels on existing open quality-debt issues (t1413)
	# Issues created before the priority label feature won't have them.
	# Parse severity from the title "(critical)", "(high)", "(medium)" and add
	# the corresponding priority:* label if missing.
	_backfill_priority_labels "$repo_slug"

	return 0
}

#######################################
# Backfill priority labels on open quality-debt issues (t1413)
#
# Parses severity from issue titles and adds priority:critical,
# priority:high, or priority:medium labels to issues that don't
# have them yet. Enables the supervisor to sort quality-debt
# issues by severity when deciding dispatch order.
#
# Arguments:
#   $1 - repo slug
# Returns: 0 on success
#######################################
_backfill_priority_labels() {
	local repo_slug="$1"

	# Ensure priority labels exist on the repo
	gh label create "priority:critical" --repo "$repo_slug" --color "B60205" \
		--description "Critical severity — security or data loss risk" --force || true
	gh label create "priority:high" --repo "$repo_slug" --color "D93F0B" \
		--description "High severity — significant quality issue" --force || true
	gh label create "priority:medium" --repo "$repo_slug" --color "FBCA04" \
		--description "Medium severity — moderate quality issue" --force || true

	# Get open quality-debt issues — extract number, title, and whether
	# a priority label already exists, in a single jq pass
	local issues_to_label
	issues_to_label=$(gh issue list --repo "$repo_slug" \
		--label "quality-debt" --state open --limit 500 \
		--json number,title,labels \
		--jq '.[] | select([.labels[].name] | any(startswith("priority:")) | not) | "\(.number)|\(.title)"' ||
		echo "")

	[[ -z "$issues_to_label" ]] && return 0

	local labelled_count=0

	while IFS='|' read -r issue_num title; do
		[[ -z "$issue_num" ]] && continue

		# Extract severity from title: "(critical)", "(high)", "(medium)"
		local severity=""
		case "$title" in
		*"(critical)"*) severity="critical" ;;
		*"(high)"*) severity="high" ;;
		*"(medium)"*) severity="medium" ;;
		esac

		if [[ -n "$severity" ]]; then
			gh issue edit "$issue_num" --repo "$repo_slug" \
				--add-label "priority:${severity}" || true
			labelled_count=$((labelled_count + 1))
		fi
	done <<<"$issues_to_label"

	[[ "$labelled_count" -gt 0 ]] && echo "  Added priority labels to ${labelled_count} quality-debt issues" >&2
	return 0
}

#######################################
# Create GitHub issues for quality-debt findings
#
# Groups findings by file, creates one issue per file (or per PR
# if findings span many files). Labels with "quality-debt" and
# the severity level.
#
# Arguments:
#   $1 - repo slug
#   $2 - PR number
#   $3 - JSON array of findings
# Output: number of issues created (integer) to stdout
# Returns: 0 on success
#######################################
# _verify_findings_against_main: filter a JSON findings array to only those
# that still exist on the default branch. Annotates each with verification_status.
# Arguments: $1=repo_slug $2=findings_json
# Outputs filtered JSON array to stdout.
_verify_findings_against_main() {
	local repo_slug="$1"
	local findings="$2"
	local verified_findings_stream=""

	while IFS= read -r finding; do
		[[ -z "$finding" ]] && continue

		local file_path=""
		local line_num=""
		local body_full=""
		local verification_json=""
		local verification_result=""
		local verification_status=""
		local finding_fields=""
		local finding_with_status=""

		# Single jq call to extract all three fields (body_full base64-encoded to preserve newlines)
		finding_fields=$(printf '%s' "$finding" | jq -r '"\(.file // "")\t\(.line // "?")\t\(.body_full // .body // "" | @base64)"')
		IFS=$'\t' read -r file_path line_num body_full <<<"$finding_fields"
		body_full=$(printf '%s' "$body_full" | base64 -d)

		verification_json=$(_finding_still_exists_on_main "$repo_slug" "$file_path" "$line_num" "$body_full" || true)

		# Parse fixed-format JSON without jq — format is {"result":bool,"status":"str"}
		verification_result="false"
		verification_status="verified"
		if [[ "$verification_json" == *'"result":true'* ]]; then
			verification_result="true"
		fi
		if [[ "$verification_json" == *'"status":"unverifiable"'* ]]; then
			verification_status="unverifiable"
		elif [[ "$verification_json" == *'"status":"resolved"'* ]]; then
			verification_status="resolved"
		fi

		if [[ "$verification_result" == "true" ]]; then
			finding_with_status=$(printf '%s' "$finding" | jq --arg status "$verification_status" '. + {verification_status: $status}')
			verified_findings_stream+="${finding_with_status}"$'\n'
		fi
	done < <(printf '%s' "$findings" | jq -c '.[]')

	if [[ -n "$verified_findings_stream" ]]; then
		printf '%s' "$verified_findings_stream" | jq -s '.'
	else
		echo "[]"
	fi
	return 0
}

# _ensure_quality_debt_labels: create quality-debt labels on the repo if missing.
# Arguments: $1=repo_slug
_ensure_quality_debt_labels() {
	local repo_slug="$1"
	gh label create "quality-debt" --repo "$repo_slug" --color "D93F0B" \
		--description "Unactioned review feedback from merged PRs" --force || true
	gh label create "source:review-feedback" --repo "$repo_slug" --color "C2E0C6" \
		--description "Auto-created by quality-feedback-helper.sh" --force || true
	gh label create "priority:critical" --repo "$repo_slug" --color "B60205" \
		--description "Critical severity — security or data loss risk" --force || true
	gh label create "priority:high" --repo "$repo_slug" --color "D93F0B" \
		--description "High severity — significant quality issue" --force || true
	gh label create "priority:medium" --repo "$repo_slug" --color "FBCA04" \
		--description "Medium severity — moderate quality issue" --force || true
	return 0
}

# _create_new_quality_debt_issue: create a new GitHub issue for a file's findings.
# Arguments: $1=repo_slug $2=pr_num $3=file $4=issue_title $5=max_severity
#            $6=reviewers $7=file_finding_count $8=finding_details
# Outputs "1" if created, "0" otherwise.
_create_new_quality_debt_issue() {
	local repo_slug="$1"
	local pr_num="$2"
	local file="$3"
	local issue_title="$4"
	local max_severity="$5"
	local reviewers="$6"
	local file_finding_count="$7"
	local finding_details="$8"

	local issue_body
	issue_body="## Unactioned Review Feedback

**Source PR**: #${pr_num}
**File**: \`${file}\`
**Reviewers**: ${reviewers}
**Findings**: ${file_finding_count}
**Max severity**: ${max_severity}

---

${finding_details}

---
_Auto-generated by \`quality-feedback-helper.sh scan-merged\`. Review each finding and either fix the code or dismiss with a reason._

---
**To approve or decline**, use one of:
- \`sudo aidevops approve issue <number>\` -- cryptographically signs approval for automated dispatch
- Comment \`declined: <reason>\` -- closes this issue (include your reason after the colon)"

	# Map severity to priority label for dispatch ordering (t1413)
	local priority_label=""
	case "$max_severity" in
	critical) priority_label="priority:critical" ;;
	high) priority_label="priority:high" ;;
	medium) priority_label="priority:medium" ;;
	*) priority_label="" ;;
	esac

	# Create the issue with severity-based priority label and source provenance.
	# Keep the issue unassigned and explicitly dispatchable. The worker claim
	# adds the real assignee at launch time; pre-assigning the repo owner here
	# collapses backlog ownership and execution claim into the same field,
	# which makes the pulse skip fresh quality-debt work.
	local label_args="quality-debt,source:review-feedback,status:available"
	[[ -n "$priority_label" ]] && label_args="${label_args},${priority_label}"

	# Append signature footer with model/session context from env vars
	# (AIDEVOPS_SIG_MODEL, AIDEVOPS_SIG_CLI, etc. set by calling LLM session).
	# Pass --session-type routine since scan-merged is a bash routine (GH#17523).
	local qf_sig=""
	local sig_args=(footer --body "$issue_body" --session-type routine)
	# Pass model from env if available (set by the LLM session calling us)
	if [[ -n "${AIDEVOPS_SIG_MODEL:-}" ]]; then
		sig_args+=(--model "$AIDEVOPS_SIG_MODEL")
	fi
	qf_sig=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" "${sig_args[@]}" 2>/dev/null || true)
	issue_body="${issue_body}${qf_sig}"

	local new_issue
	new_issue=$(gh_create_issue --repo "$repo_slug" \
		--title "$issue_title" \
		--body "$issue_body" \
		--label "$label_args" | grep -oE '[0-9]+$' || echo "")

	if [[ -n "$new_issue" ]]; then
		# Post approval instructions comment as audit trail (GH#17523).
		# This is the authoritative record of how to approve the issue for
		# automated dispatch — separate from the triage gate's generic comment.
		gh issue comment "$new_issue" --repo "$repo_slug" \
			--body "This quality-debt issue was auto-generated by \`quality-feedback-helper.sh scan-merged\` from review feedback on PR #${pr_num}.

**To approve for automated dispatch:**
\`\`\`
sudo aidevops approve issue ${new_issue}
\`\`\`

**To decline:** comment \`declined: <reason>\` to close this issue.

Approval requires cryptographic signing via the maintainer's root-protected key. Without approval, this issue will not enter the dispatch pipeline.

<details>
<summary>First-time setup</summary>

If you haven't set up approval signing yet, run the one-time key generation first:
\`\`\`
sudo aidevops approve setup
\`\`\`
This creates a root-protected ED25519 signing key. Check status anytime with \`aidevops approve status\`.
</details>" >/dev/null 2>&1 || true
		echo "  Created issue #${new_issue}: ${issue_title}" >&2
		echo "1"
		return 0
	fi
	echo "0"
	return 0
}

# _append_findings_to_issue: append findings as a comment on an existing issue.
# Arguments: $1=repo_slug $2=issue_num $3=pr_num $4=file $5=reviewers
#            $6=file_finding_count $7=max_severity $8=finding_details
_append_findings_to_issue() {
	local repo_slug="$1"
	local issue_num="$2"
	local pr_num="$3"
	local file="$4"
	local reviewers="$5"
	local file_finding_count="$6"
	local max_severity="$7"
	local finding_details="$8"

	local comment_body="## Additional Review Feedback (PR #${pr_num})

**Reviewers**: ${reviewers}
**Findings**: ${file_finding_count}
**Max severity**: ${max_severity}

---

${finding_details}

---
_Appended by \`quality-feedback-helper.sh scan-merged\` (cross-PR file dedup, t1411)._"

	# Append signature footer with session-type and model context (GH#17523)
	local append_sig=""
	local append_sig_args=(footer --body "$comment_body" --session-type routine)
	if [[ -n "${AIDEVOPS_SIG_MODEL:-}" ]]; then
		append_sig_args+=(--model "$AIDEVOPS_SIG_MODEL")
	fi
	append_sig=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" "${append_sig_args[@]}" 2>/dev/null || true)
	comment_body="${comment_body}${append_sig}"

	gh issue comment "$issue_num" --repo "$repo_slug" \
		--body "$comment_body" >/dev/null || true
	echo "  Appended to existing #${issue_num} for ${file} (PR #${pr_num})" >&2
	return 0
}

# _create_or_append_file_issue: for a single file's findings, either create a
# new quality-debt issue or append to an existing one (cross-PR dedup, t1411).
# Arguments: $1=repo_slug $2=pr_num $3=file $4=file_findings_json
#            $5=existing_issues_json $6=existing_open_issues_json
# Outputs "1" if a new issue was created, "0" otherwise.
_create_or_append_file_issue() {
	local repo_slug="$1"
	local pr_num="$2"
	local file="$3"
	local file_findings="$4"
	local existing_issues_json="$5"
	local existing_open_issues_json="$6"

	local file_finding_count
	file_finding_count=$(echo "$file_findings" | jq 'length')
	[[ "$file_finding_count" -eq 0 ]] && echo "0" && return 0

	# Get highest severity for this file
	local max_severity
	max_severity=$(echo "$file_findings" | jq -r '
		[.[].severity] |
		if any(. == "critical") then "critical"
		elif any(. == "high") then "high"
		elif any(. == "medium") then "medium"
		else "low"
		end
	')

	# Build issue title
	local issue_title
	if [[ "$file" == "general" ]]; then
		issue_title="quality-debt: PR #${pr_num} review feedback (${max_severity})"
	else
		issue_title="quality-debt: ${file} — PR #${pr_num} review feedback (${max_severity})"
	fi

	# Build finding details (shared between new issue and comment append)
	local reviewers
	reviewers=$(echo "$file_findings" | jq -r '[.[].reviewer] | unique | join(", ")')

	local finding_details
	finding_details=$(echo "$file_findings" | jq -r '.[] |
		"### \(.severity | ascii_upcase): \(.reviewer) (\(.reviewer_login))\n" +
		(if .file != null and .line != null then "**File**: `\(.file):\(.line)`\n" else "" end) +
		(if .verification_status == "unverifiable" then "**Verification**: kept as unverifiable (no stable snippet extracted)\n" else "" end) +
		"\(.body_full)\n\n" +
		(if .url != null then "[View comment](\(.url))\n" else "" end) +
		"---\n"
	')

	# Skip if exact duplicate (same PR + file combination), including closed history.
	# This prevents re-creating previously resolved issues when backfill/scan state resets.
	local exact_title_match
	local exact_title_state
	exact_title_match=$(echo "$existing_issues_json" | jq -r --arg t "$issue_title" \
		'[.[] | select(.title == $t)][0].number // empty' 2>/dev/null || echo "")
	exact_title_state=$(echo "$existing_issues_json" | jq -r --arg t "$issue_title" \
		'[.[] | select(.title == $t)][0].state // empty' 2>/dev/null || echo "")
	if [[ -n "$exact_title_match" ]]; then
		if [[ "$exact_title_state" == "CLOSED" ]]; then
			echo "  Skipping previously closed quality-debt issue #${exact_title_match}: ${issue_title}" >&2
		else
			echo "  Skipping duplicate: ${issue_title}" >&2
		fi
		echo "0"
		return 0
	fi

	# Cross-PR file dedup (t1411): check if there's an existing open
	# quality-debt issue for the same FILE from a different PR. If so,
	# append findings as a comment instead of creating a new issue.
	local existing_file_issue=""
	if [[ "$file" != "general" ]]; then
		existing_file_issue=$(echo "$existing_open_issues_json" | jq -r --arg f "$file" \
			'[.[] | select(.title | startswith("quality-debt: \($f) —"))] | .[0].number // empty' ||
			echo "")
	fi

	if [[ -n "$existing_file_issue" ]]; then
		_append_findings_to_issue "$repo_slug" "$existing_file_issue" "$pr_num" "$file" \
			"$reviewers" "$file_finding_count" "$max_severity" "$finding_details"
		echo "0"
		return 0
	fi

	# No existing issue for this file — delegate to creation helper
	_create_new_quality_debt_issue \
		"$repo_slug" "$pr_num" "$file" "$issue_title" "$max_severity" \
		"$reviewers" "$file_finding_count" "$finding_details"
	return $?
}

_create_quality_debt_issues() {
	local repo_slug="$1"
	local pr_num="$2"
	local findings="$3"

	# Verify findings still exist on main branch
	findings=$(_verify_findings_against_main "$repo_slug" "$findings")

	local finding_count
	finding_count=$(printf '%s' "$findings" | jq 'length' || echo "0")

	if [[ "$finding_count" -eq 0 ]]; then
		echo "0"
		return 0
	fi

	# Ensure labels exist (quality-debt + source + priority labels for dispatch ordering, t1413)
	_ensure_quality_debt_labels "$repo_slug"

	# Check existing quality-debt issues to avoid duplicates.
	# Fetch title/number/state so we can dedupe against both open and closed history.
	local existing_issues_json
	existing_issues_json=$(gh issue list --repo "$repo_slug" \
		--label "quality-debt" --state all --limit 1000 \
		--json title,number,state || echo "[]")

	local existing_open_issues_json
	existing_open_issues_json=$(echo "$existing_issues_json" | jq '[.[] | select(.state == "OPEN")]' 2>/dev/null || echo "[]")

	# Group findings by file (null files grouped as "general")
	local files
	files=$(echo "$findings" | jq -r '[.[].file // "general"] | unique | .[]')

	local created=0

	while IFS= read -r file; do
		[[ -z "$file" ]] && continue

		# Get findings for this file
		local file_findings
		if [[ "$file" == "general" ]]; then
			file_findings=$(echo "$findings" | jq '[.[] | select(.file == null)]')
		else
			file_findings=$(echo "$findings" | jq --arg f "$file" '[.[] | select(.file == $f)]')
		fi

		local issue_created
		issue_created=$(_create_or_append_file_issue \
			"$repo_slug" "$pr_num" "$file" "$file_findings" \
			"$existing_issues_json" "$existing_open_issues_json")
		created=$((created + issue_created))
	done <<<"$files"

	echo "$created"
	return 0
}

# Show help
show_help() {
	cat <<'EOF'
Quality Feedback Helper - Retrieve code quality feedback via GitHub API

Usage: quality-feedback-helper.sh [command] [options]

Commands:
  status         Show status of all quality checks
  failed         Show only failed checks with details
  annotations    Get line-level annotations from all check runs
  codacy         Get Codacy-specific feedback
  coderabbit     Get CodeRabbit review comments
  sonar          Get SonarCloud feedback
  watch          Watch for check completion (polls every 30s)
  scan-merged    Scan merged PRs for unactioned review feedback
  help           Show this help message

Options:
  --pr NUMBER    Specify PR number (otherwise uses current commit)
  --commit SHA   Specify commit SHA (otherwise uses HEAD)

scan-merged options:
  --repo SLUG       Repository slug (owner/repo). Default: auto-detect.
  --batch N         Max PRs to scan per run (default: 20)
  --create-issues   Create GitHub issues for findings (label: quality-debt)
  --min-severity    Minimum severity: critical|high|medium (default: medium)
  --json            Output findings as JSON
  --backfill        Scan ALL merged PRs (paginated), not just recent ones.
                    Processes in batches with rate limiting. Saves progress
                    incrementally so interrupted runs can resume.
  --tag-actioned    Label scanned PRs as "code-reviews-actioned" when all
                    quality-debt issues for that PR are closed (or none exist).
  --dry-run         Scan and report findings without creating issues or marking
                    PRs as scanned. Use to identify false-positive issues before
                    committing to issue creation.
  --include-positive  Bypass positive-review filters (summary-only, approval-only,
                    no-actionable-sentiment). Use with --dry-run to audit which
                    reviews are being suppressed and verify the filters are correct.
                    Not recommended for --create-issues runs — will generate
                    quality-debt issues for purely positive reviews.

Examples:
  quality-feedback-helper.sh status
  quality-feedback-helper.sh failed --pr 4
  quality-feedback-helper.sh annotations
  quality-feedback-helper.sh coderabbit --pr 4
  quality-feedback-helper.sh watch --pr 4
  quality-feedback-helper.sh scan-merged --repo owner/repo --batch 20
  quality-feedback-helper.sh scan-merged --repo owner/repo --create-issues
  quality-feedback-helper.sh scan-merged --repo owner/repo --backfill --create-issues --tag-actioned
  quality-feedback-helper.sh scan-merged --repo owner/repo --dry-run
  quality-feedback-helper.sh scan-merged --repo owner/repo --dry-run --include-positive

Requirements:
  - GitHub CLI (gh) installed and authenticated
  - jq for JSON parsing
  - Inside a Git repository linked to GitHub
EOF
	return 0
}

# Parse arguments
main() {
	local command="${1:-status}"
	shift || true

	# scan-merged handles its own flags — pass remaining args through
	if [[ "$command" == "scan-merged" ]]; then
		if cmd_scan_merged "$@"; then
			return 0
		fi
		return 1
	fi

	local pr_number=""
	local commit_sha=""

	while [[ $# -gt 0 ]]; do
		local flag="$1"
		case "$1" in
		--pr)
			pr_number="${2:-}"
			shift 2
			;;
		--commit)
			commit_sha="${2:-}"
			shift 2
			;;
		--help | -h)
			show_help
			exit 0
			;;
		*)
			echo "Unknown option: ${flag}" >&2
			show_help
			exit 1
			;;
		esac
	done

	# If commit SHA provided, use it directly
	if [[ -n "$commit_sha" ]]; then
		get_sha() {
			echo "$commit_sha"
			return 0
		}
	fi

	case "$command" in
	status)
		cmd_status "$pr_number"
		;;
	failed)
		cmd_failed "$pr_number"
		;;
	annotations)
		cmd_annotations "$pr_number"
		;;
	codacy)
		cmd_codacy "$pr_number"
		;;
	coderabbit)
		cmd_coderabbit "$pr_number"
		;;
	sonar)
		cmd_sonar "$pr_number"
		;;
	watch)
		cmd_watch "$pr_number"
		;;
	help | --help | -h)
		show_help
		;;
	*)
		echo "$ERROR_UNKNOWN_COMMAND $command" >&2
		show_help
		exit 1
		;;
	esac
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
